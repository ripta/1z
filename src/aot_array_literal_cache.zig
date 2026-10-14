const std = @import("std");

const value_mod = @import("value.zig");
const Value = value_mod.Value;
const container_backing = @import("container_backing.zig");

/// One decoded by-value container literal per compiled push site, shared by every execution of
/// that site in every context.
///
/// A compiled `{ }`, `H{ }`, or value-map literal decodes from static bytes. Decoding it afresh on
/// each push would put the result on the executing context's arena, which a task frees when it is
/// reaped. The cache instead holds one owned, refcounted value per site on the root's long-lived
/// allocator, as the interpreter shares one parsed literal. A push retains it.
///
/// Sites are the dense literal ids the emitter assigns, so a slot is an index, not a key. Slots
/// publish by compare-and-swap and take no lock, which keeps the cache outside the lock hierarchy.
///
/// The root context owns the cache and destroys it after all other release traffic. Task contexts
/// reach it through `rootContext`.
pub const AotArrayLiteralCache = struct {
    allocator: std.mem.Allocator,
    slots: []std.atomic.Value(?*Entry),

    /// A decoded literal and the storage its non-refcounted parts live on.
    pub const Entry = struct {
        /// Holds the cache's own reference. Its refcounted parts live on the root allocator.
        value: Value,
        /// Quotation bodies and stack effects nested in the literal. They have no refcounted
        /// form, so they live as long as the entry does.
        bodies: std.heap.ArenaAllocator,

        /// Drop the entry's reference and free what only the entry owns.
        pub fn destroy(self: *Entry, allocator: std.mem.Allocator) void {
            container_backing.releaseValue(self.value);
            self.bodies.deinit();
            allocator.destroy(self);
        }
    };

    pub fn create(allocator: std.mem.Allocator, site_count: usize) error{OutOfMemory}!*AotArrayLiteralCache {
        const slots = try allocator.alloc(std.atomic.Value(?*Entry), site_count);
        errdefer allocator.free(slots);
        for (slots) |*slot| slot.* = std.atomic.Value(?*Entry).init(null);

        const self = try allocator.create(AotArrayLiteralCache);
        self.* = .{ .allocator = allocator, .slots = slots };
        return self;
    }

    /// Release every published entry. Runs after every other holder of a cached value has had
    /// the chance to release it, since the entry's arena holds quotation bodies those values
    /// point into.
    pub fn destroy(self: *AotArrayLiteralCache) void {
        for (self.slots) |*slot| {
            if (slot.load(.acquire)) |entry| entry.destroy(self.allocator);
        }
        self.allocator.free(self.slots);
        self.allocator.destroy(self);
    }

    /// The entry published at `site`, or null when no context has decoded it yet.
    pub fn lookup(self: *const AotArrayLiteralCache, site: usize) ?*Entry {
        return self.slots[site].load(.acquire);
    }

    /// Publish `entry` at `site` and return the entry the site holds afterwards.
    ///
    /// Two contexts can decode the same site at once. The first swap wins. A loser destroys its
    /// own entry and uses the winner's, so every push of a site sees one value.
    ///
    /// A successful swap releases and a failed one acquires, so a reader that sees the pointer
    /// also sees the fully built value behind it.
    pub fn publish(self: *AotArrayLiteralCache, site: usize, entry: *Entry) *Entry {
        const current = self.slots[site].cmpxchgStrong(null, entry, .acq_rel, .acquire) orelse return entry;
        entry.destroy(self.allocator);

        // A failed swap against null saw a published entry, and a slot is never cleared.
        return current.?;
    }
};
