const std = @import("std");

const value_mod = @import("value.zig");
const StackEffect = @import("stack_effect.zig").StackEffect;
const AtomicSlotMap = @import("atomic_slot_map.zig").AtomicSlotMap;

/// Process-shared cache of decoded reified-quotation bodies, keyed by the static bytecode
/// pointer compiled code hands to `jitPushQuotation`.
///
/// The decoded body of a static image literal is process-lifetime data. Per-context decodes put
/// it on the executing context's arena, where a task's copy died at task teardown -- and a
/// defining-module stamp for such a slice would outlive the memory it names, since
/// `QuotationStampStore` entries are permanent. Slices here live on the cache's own arena, owned
/// by the root context, so every key the decode path hands the stamp store is process-lifetime,
/// and one decode per push site serves every context.
///
/// Reads take no lock. `decode_mu` serializes decodes and map inserts, and is held across the
/// whole miss path so the defining-module stamp is written before the slice is published: no
/// reader can obtain a body the store cannot resolve. `decode_mu` may acquire the stamp store's
/// `write_mu` through that stamp; never the reverse. Both sit outside `LockOrderTracker`.
///
/// The cache is allocated by the root context, aliased by pointer into every child, and freed
/// only by the root, after all release traffic: pushed literals retain container backings that
/// live on this arena, and their releases must complete before the arena dies.
pub const ReifiedDecodeCache = struct {
    /// Keyed by the static data pointer, which is never zero.
    map: AtomicSlotMap(?*const Entry),
    decode_mu: std.Thread.Mutex = .{},
    arena: std.heap.ArenaAllocator,

    /// Boxes the decoded body so the map's atomic slot holds one pointer.
    pub const Entry = struct {
        instructions: []const value_mod.Instruction,
        /// The declared stack effect recovered from the stream's effect slot, null when the
        /// literal declared none. Lives on the cache arena like the instructions.
        effect: ?*const StackEffect,
    };

    const initial_capacity: usize = 64;

    pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*ReifiedDecodeCache {
        var map = try AtomicSlotMap(?*const Entry).init(allocator, initial_capacity);
        errdefer map.deinit();

        const self = try allocator.create(ReifiedDecodeCache);
        self.* = .{
            .map = map,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        return self;
    }

    pub fn destroy(self: *ReifiedDecodeCache) void {
        const allocator = self.map.allocator;
        self.map.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    /// The decoded body for `data_ptr`, or null when no context has decoded it yet. One acquire
    /// load plus one probe, no lock; this is the compiled push's steady-state path.
    pub fn lookup(self: *const ReifiedDecodeCache, data_ptr: usize) ?*const Entry {
        return self.map.lookup(data_ptr);
    }

    /// Allocator for decoded instructions. Only valid while holding `decode_mu`: the arena is
    /// not thread-safe, and the mutex is what serializes all allocation through it.
    pub fn decodeAllocator(self: *ReifiedDecodeCache) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Publish a decoded body. The caller holds `decode_mu` and has re-checked `lookup` after
    /// acquiring it, so the key cannot already be present.
    pub fn insertAssumeLocked(self: *ReifiedDecodeCache, data_ptr: usize, instructions: []const value_mod.Instruction, effect: ?*const StackEffect) error{OutOfMemory}!void {
        const entry = try self.arena.allocator().create(Entry);
        entry.* = .{ .instructions = instructions, .effect = effect };
        const inserted = try self.map.insert(data_ptr, entry);
        std.debug.assert(inserted);
    }
};

const testing = std.testing;

test "ReifiedDecodeCache: a published body is returned by pointer identity" {
    const cache = try ReifiedDecodeCache.create(testing.allocator);
    defer cache.destroy();

    cache.decode_mu.lock();
    const instrs = try cache.decodeAllocator().alloc(value_mod.Instruction, 1);
    instrs[0] = .{ .op = .{ .call_word = "probe" }, .line = 1 };
    const effect = try cache.decodeAllocator().create(StackEffect);
    effect.* = .{ .inputs = &.{}, .outputs = &.{} };
    try cache.insertAssumeLocked(0x4000, instrs, effect);
    cache.decode_mu.unlock();

    const found = cache.lookup(0x4000) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(instrs.ptr, found.instructions.ptr);
    try testing.expectEqual(instrs.len, found.instructions.len);
    try testing.expectEqual(@as(?*const StackEffect, effect), found.effect);
}

test "ReifiedDecodeCache: an unknown data pointer misses" {
    const cache = try ReifiedDecodeCache.create(testing.allocator);
    defer cache.destroy();

    try testing.expect(cache.lookup(0x4000) == null);
}
