const std = @import("std");

const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const AtomicSlotMap = @import("atomic_slot_map.zig").AtomicSlotMap;

/// The bare-word names a body's nested quotation literals call, transitively.
///
/// Boxed so the map's atomic slot holds one pointer.
pub const NestedNameSet = struct {
    names: []const []const u8,
};

/// Process-shared map from a body's instruction-slice pointer to the bare-word names its nested
/// quotation literals call.
///
/// The capture gate has to know whether a body closes over a live lexical binding, and a nested
/// quotation counts: the frame the nested body would read can be popped by a module-changing tail
/// call before that body's own push ever runs. Answering it by walking the nested bodies at every
/// push would put a recursive scan on the per-push capture path, which has twice been measured
/// into a regression. The walk therefore runs once, at parse time.
///
/// A body's own top-level names are not here. The gate scans those directly off the instruction
/// array it already holds.
///
/// Absence does not mean "no nested names". Only a body the parser finished on the root arena is
/// filled, so a body built at runtime or decoded from an image has no entry and the gate falls back
/// to the walk. That keeps a missing entry slow rather than wrong.
///
/// Entries are permanent, so only process-lifetime keys may enter: a body parsed onto a task or
/// scoped-eval arena dies with it and would leave a key that a later unrelated allocation at the
/// same address falsely matches. `Context.cacheQuotationBodyNestedNames` applies that gate.
///
/// The cache is allocated by the root context, aliased by pointer into every child, and freed only
/// by the root.
///
/// Reads take no lock. Writers serialize on `write_mu` and apply first-fill-wins, which is what a
/// repeated parse of the same slice would write anyway.
pub const NestedNameCache = struct {
    /// Key `0` marks an empty slot in the map and is never a real key: `fill` skips zero-length
    /// instruction slices, which are the only bodies whose `.ptr` could be a shared sentinel.
    map: AtomicSlotMap(?*const NestedNameSet),

    /// Owns every published name list and its box. The names inside a list alias the body they were
    /// read from, so the arena holds the spine and not the text. Entries are never removed, so the
    /// whole arena is released at `destroy`. Only valid under `write_mu`: an arena is not
    /// thread-safe.
    arena: std.heap.ArenaAllocator,

    write_mu: std.Thread.Mutex = .{},

    /// Shared by every body with no nested names, which is the overwhelming majority. Only its
    /// address is published, so an empty entry costs a map slot and no allocation.
    const empty: NestedNameSet = .{ .names = &.{} };

    /// Every parsed body takes a slot, matching `QuotationSourceStore`. The prelude alone
    /// contributes one per quotation plus one per top-level statement, which is upwards of a
    /// thousand before a program parses a line of its own. Sizing for that keeps growth, whose
    /// displaced tables stay allocated until teardown, off the common path.
    const initial_capacity: usize = 4096;

    pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*NestedNameCache {
        var map = try AtomicSlotMap(?*const NestedNameSet).init(allocator, initial_capacity);
        errdefer map.deinit();

        const self = try allocator.create(NestedNameCache);
        self.* = .{
            .map = map,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        return self;
    }

    pub fn destroy(self: *NestedNameCache) void {
        const allocator = self.map.allocator;
        self.map.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    /// The nested names of the body at `key`, or null when the body was never filled.
    ///
    /// One acquire load plus one probe, no lock. This runs on every quotation-literal push, so it
    /// must stay cheap.
    pub fn lookup(self: *const NestedNameCache, key: usize) ?[]const []const u8 {
        const set = self.map.lookup(key) orelse return null;
        return set.names;
    }

    /// Collect `instructions`' nested names and record them at `key`, unless the body is already
    /// filled.
    ///
    /// The name slices are aliased, not copied. Only a caller that has established `instructions`
    /// lives for the process may fill, and the names live in that same body.
    pub fn fill(self: *NestedNameCache, key: usize, instructions: []const Instruction) error{OutOfMemory}!void {
        std.debug.assert(key != 0);

        self.write_mu.lock();
        defer self.write_mu.unlock();

        if (self.map.lookup(key) != null) return;

        // The walk's dedup scratch is collected on a caller-owned allocator, not the cache arena.
        // An arena reclaims only its most recent allocation, and the name list outlives the scratch
        // map, so a scratch map placed there would be stranded for the life of the process.
        const scratch = self.map.allocator;
        const names = try collectNestedNames(scratch, instructions);
        defer scratch.free(names);

        if (names.len == 0) {
            _ = try self.map.insert(key, &empty);
            return;
        }

        // Only the spine is copied onto the arena. The names themselves alias `instructions`.
        const owned = try self.arena.allocator().dupe([]const u8, names);
        const set = try self.arena.allocator().create(NestedNameSet);
        set.* = .{ .names = owned };
        _ = try self.map.insert(key, set);
    }

    /// Occupied slot count. Diagnostics and tests.
    pub fn count(self: *NestedNameCache) usize {
        self.write_mu.lock();
        defer self.write_mu.unlock();
        return self.map.count();
    }

    /// Published table capacity. Diagnostics and tests; racy against a concurrent growth.
    pub fn capacity(self: *const NestedNameCache) usize {
        return self.map.capacity();
    }
};

/// The deduplicated bare-word names every quotation literal nested inside `instructions` calls, at
/// any depth. `instructions`' own top-level names are excluded.
///
/// Only `.call_word` and `.call_word_module` names are collected. `preResolveCallTarget` emits
/// `.call_word_direct` only for a name it proved no frame can bind, and `executeInstructions` never
/// consults a captured scope on that arm, so such a name can never resolve to a lexical local and
/// can never justify a capture.
///
/// The descent follows a `push_literal` only into a bare `.quotation`, which is exactly what
/// `Context.quotationPushValue` acts on. A quotation reached through a container literal is pushed
/// as part of its container and never runs the capture gate on its own.
///
/// The returned slice is allocated on `alloc`; the name slices inside it alias `instructions`.
pub fn collectNestedNames(alloc: std.mem.Allocator, instructions: []const Instruction) error{OutOfMemory}![]const []const u8 {
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(alloc);

    var names: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer names.deinit(alloc);

    for (instructions) |instr| {
        switch (instr.op) {
            .push_literal => |val| if (val == .quotation)
                try collectBodyNames(alloc, val.quotation.instructions, &seen, &names),
            else => {},
        }
    }

    return names.toOwnedSlice(alloc);
}

/// Add `instructions`' own call names, then descend into its nested quotation literals.
fn collectBodyNames(
    alloc: std.mem.Allocator,
    instructions: []const Instruction,
    seen: *std.StringHashMapUnmanaged(void),
    names: *std.ArrayListUnmanaged([]const u8),
) error{OutOfMemory}!void {
    for (instructions) |instr| {
        switch (instr.op) {
            .call_word => |name| try addName(alloc, name, seen, names),
            .call_word_module => |slot| try addName(alloc, slot.name, seen, names),
            .push_literal => |val| if (val == .quotation)
                try collectBodyNames(alloc, val.quotation.instructions, seen, names),
            .call_word_direct => {},
        }
    }
}

fn addName(
    alloc: std.mem.Allocator,
    name: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    names: *std.ArrayListUnmanaged([]const u8),
) error{OutOfMemory}!void {
    const gop = try seen.getOrPut(alloc, name);
    if (gop.found_existing) return;
    try names.append(alloc, name);
}

const testing = std.testing;

fn callWord(name: []const u8) Instruction {
    return .{ .op = .{ .call_word = name }, .line = 0 };
}

fn pushQuotation(body: []const Instruction) Instruction {
    return .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = body } } }, .line = 0 };
}

fn expectNames(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

test "collectNestedNames: collects a name at every nesting depth" {
    const inner = [_]Instruction{callWord("deep")};
    const middle = [_]Instruction{ callWord("mid"), pushQuotation(&inner) };
    const outer = [_]Instruction{ callWord("top"), pushQuotation(&middle) };

    const names = try collectNestedNames(testing.allocator, &outer);
    defer testing.allocator.free(names);

    try expectNames(&.{ "mid", "deep" }, names);
}

test "collectNestedNames: an empty body has no nested names" {
    const names = try collectNestedNames(testing.allocator, &.{});
    defer testing.allocator.free(names);

    try testing.expectEqual(@as(usize, 0), names.len);
}

test "collectNestedNames: a body with no nested literal has no nested names" {
    const body = [_]Instruction{ callWord("a"), callWord("b") };

    const names = try collectNestedNames(testing.allocator, &body);
    defer testing.allocator.free(names);

    try testing.expectEqual(@as(usize, 0), names.len);
}

test "collectNestedNames: a name repeated across two depths appears once" {
    const first = [_]Instruction{ callWord("shared"), callWord("only-inner") };
    const second = [_]Instruction{callWord("shared")};
    const outer = [_]Instruction{ pushQuotation(&first), pushQuotation(&second) };

    const names = try collectNestedNames(testing.allocator, &outer);
    defer testing.allocator.free(names);

    try expectNames(&.{ "shared", "only-inner" }, names);
}

test "collectNestedNames: call_word_module is collected and call_word_direct is not" {
    const WordSlot = @import("word_slot.zig").WordSlot;
    var module_slot: WordSlot = .{ .name = "from-module", .definition = undefined };
    var direct_slot: WordSlot = .{ .name = "pre-resolved", .definition = undefined };

    const inner = [_]Instruction{
        .{ .op = .{ .call_word_module = &module_slot }, .line = 0 },
        .{ .op = .{ .call_word_direct = &direct_slot }, .line = 0 },
    };
    const outer = [_]Instruction{pushQuotation(&inner)};

    const names = try collectNestedNames(testing.allocator, &outer);
    defer testing.allocator.free(names);

    try expectNames(&.{"from-module"}, names);
}

test "NestedNameCache: an unfilled body misses and a filled one resolves" {
    const cache = try NestedNameCache.create(testing.allocator);
    defer cache.destroy();

    const inner = [_]Instruction{callWord("nested")};
    const outer = [_]Instruction{pushQuotation(&inner)};

    try testing.expect(cache.lookup(0x1000) == null);

    try cache.fill(0x1000, &outer);

    try expectNames(&.{"nested"}, cache.lookup(0x1000).?);
    try testing.expect(cache.lookup(0x2000) == null);
    try testing.expect(cache.lookup(0) == null);
    try testing.expectEqual(@as(usize, 1), cache.count());
}

test "NestedNameCache: a body with no nested names fills as an empty set, not a miss" {
    const cache = try NestedNameCache.create(testing.allocator);
    defer cache.destroy();

    const body = [_]Instruction{callWord("a")};
    try cache.fill(0x1000, &body);

    const names = cache.lookup(0x1000) orelse return error.TestExpectedEntry;
    try testing.expectEqual(@as(usize, 0), names.len);
}

test "NestedNameCache: the first fill wins" {
    const cache = try NestedNameCache.create(testing.allocator);
    defer cache.destroy();

    const first = [_]Instruction{pushQuotation(&[_]Instruction{callWord("first")})};
    const second = [_]Instruction{pushQuotation(&[_]Instruction{callWord("second")})};

    try cache.fill(0x1000, &first);
    try cache.fill(0x1000, &second);

    try expectNames(&.{"first"}, cache.lookup(0x1000).?);
    try testing.expectEqual(@as(usize, 1), cache.count());
}

test "NestedNameCache: growth preserves every entry" {
    const cache = try NestedNameCache.create(testing.allocator);
    defer cache.destroy();

    const even = [_]Instruction{pushQuotation(&[_]Instruction{callWord("even")})};
    const odd = [_]Instruction{pushQuotation(&[_]Instruction{callWord("odd")})};

    const entries: usize = 8000;
    var key: usize = 1;
    while (key <= entries) : (key += 1) {
        try cache.fill(key * 8, if (key % 2 == 0) &even else &odd);
    }

    key = 1;
    while (key <= entries) : (key += 1) {
        const expected: []const u8 = if (key % 2 == 0) "even" else "odd";
        try expectNames(&.{expected}, cache.lookup(key * 8).?);
    }

    try testing.expectEqual(entries, cache.count());
    try testing.expect(cache.capacity() > NestedNameCache.initial_capacity);

    // A missing key walks its collision run and falls off the end rather than looping, which is
    // what the load factor's spare slots buy.
    try testing.expect(cache.lookup(0x7fff_ffff) == null);
}
