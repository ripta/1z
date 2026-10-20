const std = @import("std");

const QuotationStampStore = @import("quotation_stamp_store.zig").QuotationStampStore;
const QuotationSourceStore = @import("quotation_source_store.zig").QuotationSourceStore;
const CarryableScopeGate = @import("carryable_scope_gate.zig").CarryableScopeGate;
const NestedNameCache = @import("nested_name_cache.zig").NestedNameCache;
const LexicalParentMap = @import("lexical_parent_map.zig").LexicalParentMap;
const InlineRegionTable = @import("inline_region_table.zig").InlineRegionTable;
const arena_origin = @import("arena_origin.zig");

/// The six stores keyed by the address of a parsed body, as one layer.
///
/// Each store is write-once and lock-free to read. An entry is never removed, so a key must outlive
/// the layer that holds it. The root's layer lives for the process. A context that owns its loads
/// has a layer of its own, linked to its parent's, and the layer dies with that context. A body
/// that context parses lands in its layer, so no key of its arena can reach a layer that outlives
/// it. Every other context aliases the set of its nearest load owner.
///
/// A reader probes its own layer and then each parent's. A writer checks the whole chain before it
/// inserts, so the first write for a key wins across layers.
///
/// A context must not outlive the layer it aliases. Every task under a load owner is reaped before
/// the owner's teardown.
pub const BodyKeyedStores = struct {
    allocator: std.mem.Allocator,
    parent: ?*const BodyKeyedStores,

    /// The module a body was written in. A spawned task runs in a fresh context and still resolves
    /// a stored quotation against its own defining module. The per-execution captured scope stays
    /// in `Context.quotation_scope_info`.
    quotation_stamp_store: QuotationStampStore,

    /// The file a body was parsed from. A call frame names the body's file, not the innermost
    /// executing word's.
    quotation_source_store: QuotationSourceStore,

    /// The bodies that have ever had a carryable captured scope installed. An absent body lets a
    /// body entry skip the ancestor walk.
    carryable_scope_gate: CarryableScopeGate,

    /// The bare-word names a body's nested quotation literals call, so the capture gate does not
    /// walk them on every push.
    nested_name_cache: NestedNameCache,

    /// The body that syntactically encloses each parsed quotation literal. Lexical admission reads
    /// it. See `LexicalParentMap`.
    lexical_parents: LexicalParentMap,

    /// The inlined runs of expanded bodies, read on the error path to put an erased frame back.
    inline_regions: InlineRegionTable,

    /// A set linked under `parent`, or the base set when `parent` is null. `parent` must outlive
    /// the set.
    pub fn create(allocator: std.mem.Allocator, parent: ?*const BodyKeyedStores) error{OutOfMemory}!*BodyKeyedStores {
        const self = try allocator.create(BodyKeyedStores);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.parent = parent;

        self.quotation_stamp_store = try QuotationStampStore.init(
            allocator,
            if (parent) |p| &p.quotation_stamp_store else null,
        );
        errdefer self.quotation_stamp_store.deinit();

        self.quotation_source_store = try QuotationSourceStore.init(
            allocator,
            if (parent) |p| &p.quotation_source_store else null,
        );
        errdefer self.quotation_source_store.deinit();

        self.carryable_scope_gate = try CarryableScopeGate.init(
            allocator,
            if (parent) |p| &p.carryable_scope_gate else null,
        );
        errdefer self.carryable_scope_gate.deinit();

        self.nested_name_cache = try NestedNameCache.init(
            allocator,
            if (parent) |p| &p.nested_name_cache else null,
        );
        errdefer self.nested_name_cache.deinit();

        self.lexical_parents = try LexicalParentMap.init(
            allocator,
            if (parent) |p| &p.lexical_parents else null,
        );
        errdefer self.lexical_parents.deinit();

        self.inline_regions = try InlineRegionTable.init(
            allocator,
            if (parent) |p| &p.inline_regions else null,
        );

        return self;
    }

    pub fn destroy(self: *BodyKeyedStores) void {
        const allocator = self.allocator;

        self.inline_regions.deinit();
        self.lexical_parents.deinit();
        self.nested_name_cache.deinit();
        self.carryable_scope_gate.deinit();
        self.quotation_source_store.deinit();
        self.quotation_stamp_store.deinit();

        allocator.destroy(self);
    }

    /// Whether any key in this layer, parents excluded, lies inside `arena`. Diagnostics and tests.
    ///
    /// A key of an arena that has been freed would name freed memory, so this is how a test shows
    /// that a layer which outlives an arena holds nothing from it.
    pub fn anyKeyOnArena(self: *const BodyKeyedStores, arena: *const std.heap.ArenaAllocator) bool {
        const Probe = struct {
            fn on(a: *const std.heap.ArenaAllocator, key: usize) bool {
                return arena_origin.contains(a, key);
            }
        };

        return self.quotation_stamp_store.map.anyKey(arena, Probe.on) or
            self.quotation_source_store.map.anyKey(arena, Probe.on) or
            self.carryable_scope_gate.map.anyKey(arena, Probe.on) or
            self.nested_name_cache.map.anyKey(arena, Probe.on) or
            self.lexical_parents.parents.anyKey(arena, Probe.on) or
            self.lexical_parents.aliases.anyKey(arena, Probe.on) or
            self.lexical_parents.roots.anyKey(arena, Probe.on) or
            self.inline_regions.map.anyKey(arena, Probe.on);
    }
};

const testing = std.testing;

test "BodyKeyedStores: a layer reads through its parent and writes only its own table" {
    const base = try BodyKeyedStores.create(testing.allocator, null);
    defer base.destroy();

    const layer = try BodyKeyedStores.create(testing.allocator, base);
    defer layer.destroy();

    try base.quotation_source_store.stamp(0x1000, "base.1z");
    try layer.quotation_source_store.stamp(0x2000, "layer.1z");

    try testing.expectEqualStrings("base.1z", layer.quotation_source_store.lookup(0x1000).?);
    try testing.expectEqualStrings("layer.1z", layer.quotation_source_store.lookup(0x2000).?);
    try testing.expect(base.quotation_source_store.lookup(0x2000) == null);

    _ = try base.carryable_scope_gate.mark(0x3000);
    _ = try layer.carryable_scope_gate.mark(0x4000);
    try testing.expect(layer.carryable_scope_gate.isMarked(0x3000));
    try testing.expect(layer.carryable_scope_gate.isMarked(0x4000));
    try testing.expect(!base.carryable_scope_gate.isMarked(0x4000));
}

test "BodyKeyedStores: a layer refuses a key its parent already holds" {
    const base = try BodyKeyedStores.create(testing.allocator, null);
    defer base.destroy();

    const layer = try BodyKeyedStores.create(testing.allocator, base);
    defer layer.destroy();

    try base.quotation_source_store.stamp(0x1000, "first.1z");
    try layer.quotation_source_store.stamp(0x1000, "second.1z");

    try testing.expectEqualStrings("first.1z", layer.quotation_source_store.lookup(0x1000).?);
    try testing.expectEqual(@as(usize, 0), layer.quotation_source_store.count());

    _ = try base.carryable_scope_gate.mark(0x2000);
    try testing.expect(!try layer.carryable_scope_gate.mark(0x2000));
    try testing.expectEqual(@as(usize, 0), layer.carryable_scope_gate.count());
}

test "BodyKeyedStores: the lexical map answers across layers" {
    const base = try BodyKeyedStores.create(testing.allocator, null);
    defer base.destroy();

    const layer = try BodyKeyedStores.create(testing.allocator, base);
    defer layer.destroy();

    const Instruction = @import("value.zig").Instruction;

    const inner = [_]Instruction{.{ .op = .{ .call_word = "inner" }, .line = 1 }};
    const outer = [_]Instruction{.{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &inner } } }, .line = 1 }};
    const statement = [_]Instruction{.{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &outer } } }, .line = 2 }};

    try base.lexical_parents.recordChildren(&statement);
    try layer.lexical_parents.recordChildren(&outer);
    try layer.lexical_parents.recordRoot(&statement);

    try testing.expectEqual(@as(?usize, @intFromPtr(&outer)), layer.lexical_parents.parentOf(@intFromPtr(&inner)));
    try testing.expectEqual(@as(?usize, @intFromPtr(&statement)), layer.lexical_parents.parentOf(@intFromPtr(&outer)));
    try testing.expect(layer.lexical_parents.isKnown(@intFromPtr(&inner)));
    try testing.expect(!base.lexical_parents.isKnown(@intFromPtr(&inner)));
}
