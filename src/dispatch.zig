const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("context.zig").Context;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const TypeDescriptor = value_mod.TypeDescriptor;
const Instruction = value_mod.Instruction;
const dictionary_mod = @import("dictionary.zig");
const NativeFn = dictionary_mod.NativeFn;
const HostCallback = dictionary_mod.HostCallback;

/// Returns the dispatch type name for a value. Also used by `type-of`.
pub fn dispatchTypeName(val: Value) []const u8 {
    return switch (val) {
        .tagged => |t| t.tag.name,
        .struct_instance => |si| si.struct_type.name,
        .fixnum => "fixnum",
        .float => "float",
        .bignum => "bignum",
        .boolean => "boolean",
        .string => "string",
        .symbol => "symbol",
        .array => "array",
        .quotation => "quotation",
        // A closure is the compiled form of a curry/compose result; it presents
        // as a quotation to user code and dispatch.
        .closure => "quotation",
        .hash => "hash",
        .vector => "vector",
        .byte_array => "byte-array",
        .set => "set",
        .mutable_map => "mutable-map",
        .stream => "stream",
        .resource => |r| r.type_name,
        .parameter => "parameter",
        .module => "module",
        .marker => "marker",
        .struct_type => "struct-type",
        .template => "template",
        .stack_effect => "stack-effect",
        .error_value => "error",
        .task => "task",
        .channel => "channel",
        .iterator => "iterator",
        .doc_string => "doc-string",
        .type_val => "type",
        .type_descriptor => "type-descriptor",
        .protocol_descriptor => "constraint",
        .constraint_combinator => "constraint",
        .sandbox_spec => "sandbox-spec",
        .unit => "unit",
    };
}

/// Returns the dispatch TypeValue for a value. Requires a Context for the
/// builtin_type_array and resource type lookup. For tagged values and struct
/// instances, returns the specific type's TypeValue when available, falling
/// back to the discriminant-level builtin TypeValue.
pub fn dispatchTypeValue(val: Value, ctx: *Context) *value_mod.TypeValue {
    return switch (val) {
        .tagged => |t| t.tag.type_val orelse ctx.lookupBuiltinTypeValueByTag(.tagged).?,
        .struct_instance => |si| si.struct_type.type_val orelse ctx.lookupBuiltinTypeValueByTag(.struct_instance).?,
        .resource => |r| ctx.getOrCreateResourceTypeValue(r.type_name) catch
            ctx.lookupBuiltinTypeValueByTag(.resource).?,
        inline else => |_, tag| ctx.lookupBuiltinTypeValueByTag(tag).?,
    };
}

/// Returns the dispatch descriptor for a value. Requires a Context for the
/// builtin type lookup and resource type creation path.
pub fn dispatchDescriptor(val: Value, ctx: *Context) *const TypeDescriptor {
    const tv = dispatchTypeValue(val, ctx);
    return tv.descriptor orelse unreachable;
}

/// Returns the canonical type name for a Value discriminant tag.
/// For the three dynamic variants (.tagged, .struct_instance, .resource),
/// returns the base type name used in the prelude's descriptor-driven
/// `define-builtin-type` entries.
pub fn builtinTypeName(comptime tag: std.meta.Tag(Value)) []const u8 {
    return switch (tag) {
        .fixnum => "fixnum",
        .float => "float",
        .bignum => "bignum",
        .boolean => "boolean",
        .string => "string",
        .symbol => "symbol",
        .array => "array",
        .quotation => "quotation",
        // Umbrella: a closure reuses the `quotation` builtin TypeValue (see
        // initBuiltinTypeValues), so it dispatches identically to a quotation.
        .closure => "quotation",
        .hash => "hash",
        .vector => "vector",
        .byte_array => "byte-array",
        .set => "set",
        .mutable_map => "mutable-map",
        .stream => "stream",
        .resource => "resource",
        .parameter => "parameter",
        .module => "module",
        .marker => "marker",
        .struct_type => "struct-type",
        .struct_instance => "struct-instance",
        .tagged => "tagged",
        .template => "template",
        .stack_effect => "stack-effect",
        .error_value => "error",
        .task => "task",
        .channel => "channel",
        .iterator => "iterator",
        .doc_string => "doc-string",
        .type_val => "type",
        .type_descriptor => "type-descriptor",
        .protocol_descriptor => "constraint",
        .constraint_combinator => "constraint",
        .sandbox_spec => "sandbox-spec",
        .unit => "unit",
    };
}

/// Returns the enum TypeValue for a tagged value that is an enum variant,
/// or null for everything else.
pub fn dispatchEnumTypeValue(val: Value) ?*const value_mod.TypeValue {
    return switch (val) {
        .tagged => |t| t.tag.parent_type,
        else => null,
    };
}

/// Returns the base TypeValue for a parameterized tagged value,
/// or null for everything else.
pub fn dispatchBaseTypeValue(val: Value) ?*const value_mod.TypeValue {
    return switch (val) {
        .tagged => |t| t.tag.base_type,
        else => null,
    };
}

/// If a value is a tagged parameterized type with a base_type, unwrap to
/// the inner value so operations can work on the raw container.
pub fn unwrapBaseType(val: Value) Value {
    if (val == .tagged) {
        if (val.tagged.tag.base_type != null) {
            return val.tagged.inner.*;
        }
    }
    return val;
}

/// Key for dispatch table lookups: (dispatch_id, type_a, type_b).
/// For unary dispatch, type_b is `&unary_sentinel`.
pub const DispatchKey = struct {
    dispatch_id: u32,
    type_a: *const TypeDescriptor,
    type_b: *const TypeDescriptor,
};

/// HashMap context for DispatchKey: hashes dispatch_id as u32, type_a/type_b as pointers.
pub const DispatchKeyContext = struct {
    pub fn hash(_: @This(), key: DispatchKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&key.dispatch_id));
        h.update(std.mem.asBytes(&@intFromPtr(key.type_a)));
        h.update(std.mem.asBytes(&@intFromPtr(key.type_b)));
        return h.final();
    }

    pub fn eql(_: @This(), a: DispatchKey, b: DispatchKey) bool {
        return a.dispatch_id == b.dispatch_id and
            a.type_a == b.type_a and
            a.type_b == b.type_b;
    }
};

/// The natives that carry their own dispatch identity.
///
/// A generic native's entries are keyed by the dispatch id of its own word definition. Resolving
/// that id by name at call time would let any visible binding of the name answer in the native's
/// place, so each of these natives instead reads the id its entries were registered under from
/// per-Context storage that `captureNativeDispatchIds` fills once at init. The storage is
/// per-Context rather than a comptime global because `next_dispatch_id` is per-root-context and an
/// embedding can hold more than one.
///
/// Every value here has to name a word in some module's `primitives` array, since the capture
/// resolves it through `lookupWord`, which never reaches the `native.*` registry entries.
pub const NativeDispatchWord = enum {
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    lt,
    gt,
    to_float,
    to_integer,
    abs,

    bitand,
    bitor,
    bitxor,
    bitnot,
    shift_left,
    shift_right,
    ushift_right,
    shift,

    len,
    nth,
    first,
    last,
    in,
    index_of,
    to_array,
    to_hash,
    push,
    pop,
    nth_mut,
    append_mut,
    push_mut,
    pop_mut,
    unshift_mut,
    shift_mut,
    peek,
    poke_mut,

    at_get,
    at_has,
    at_set,
    at_keys,
    at_values,
    at_set_mut,
    at_remove_mut,

    inspect,
    to_string,
    to_symbol,

    freeze,
    freeze_bang,

    pub fn wordName(self: NativeDispatchWord) []const u8 {
        return switch (self) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .eq => "=",
            .lt => "<",
            .gt => ">",
            .to_float => ">float",
            .to_integer => ">integer",
            .abs => "abs",

            .bitand => "bitand",
            .bitor => "bitor",
            .bitxor => "bitxor",
            .bitnot => "bitnot",
            .shift_left => "shift-left",
            .shift_right => "shift-right",
            .ushift_right => "ushift-right",
            .shift => "shift",

            .len => "#len",
            .nth => "#nth",
            .first => "#first",
            .last => "#last",
            .in => "#in?",
            .index_of => "#index-of",
            .to_array => ">array",
            .to_hash => ">hash",
            .push => "#push",
            .pop => "#pop",
            .nth_mut => "#nth!",
            .append_mut => "#append!",
            .push_mut => "#push!",
            .pop_mut => "#pop!",
            .unshift_mut => "#unshift!",
            .shift_mut => "#shift!",
            .peek => "#peek",
            .poke_mut => "#poke!",

            .at_get => "@get",
            .at_has => "@has?",
            .at_set => "@set",
            .at_keys => "@keys",
            .at_values => "@values",
            .at_set_mut => "@set!",
            .at_remove_mut => "@remove!",

            .inspect => "inspect",
            .to_string => ">string",
            .to_symbol => ">symbol",

            .freeze => "freeze",
            .freeze_bang => "freeze!",
        };
    }
};

/// Provenance metadata for a dispatch entry: which generator created it and why.
pub const DispatchProvenance = struct {
    generator: []const u8,
    parent: []const u8,
    role: []const u8,
    field: []const u8,
};

/// Tagged union for dispatch entry bodies: either a user-defined quotation
/// or a native function pointer.
///
/// The `quotation` body carries a full `Quotation` rather than a bare
/// instruction slice so an AOT-replayed method body can ride its compiled
/// `code_ptr` through dispatch. Interpreter-registered methods leave
/// `code_ptr` null and run their instructions; AOT replay attaches the
/// compiled function pointer with an empty instruction slice.
pub const DispatchBody = union(enum) {
    quotation: value_mod.Quotation,
    native_fn: NativeFn,
    host_callback: HostCallback,
};

/// A registered method body for a dispatch entry.
pub const DispatchEntry = struct {
    body: DispatchBody,
    provenance: ?DispatchProvenance = null,
    /// The module whose source the body was written in. Borrowed; valid for
    /// the life of the dispatch table because modules are arena-allocated and
    /// live for the whole Context. Null for native and host-callback bodies,
    /// and for methods registered outside any module load.
    source_module: ?*const value_mod.Module = null,
    /// Registration order within the base table, stamped by `DispatchTable.register`. An
    /// overwriting re-registration keeps the original entry's sequence, so priority is a property
    /// of the key and a replaced body does not reshuffle order-sensitive consumers.
    ///
    /// Dispatch-frame entries bypass `register`, so a frame entry carries no meaningful sequence.
    sequence: u64 = 0,
};

/// Dispatch table mapping (dispatch_id, type_a, type_b) to method bodies.
pub const DispatchTable = struct {
    entries: std.HashMapUnmanaged(DispatchKey, DispatchEntry, DispatchKeyContext, 80),
    native_entries: std.HashMapUnmanaged(DispatchKey, DispatchEntry, DispatchKeyContext, 80),
    allocator: Allocator,
    /// Incremented on every method registration, used for PIC invalidation.
    generation: u32 = 0,
    /// Next value for `DispatchEntry.sequence`, consumed by `register` when
    /// a key is first inserted.
    next_sequence: u64 = 0,

    pub fn init(allocator: Allocator) DispatchTable {
        return .{
            .entries = .{},
            .native_entries = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DispatchTable) void {
        self.entries.deinit(self.allocator);
        self.native_entries.deinit(self.allocator);
    }

    /// Register a method. Returns error.DuplicateMethod if the key exists
    /// and allow_overwrite is false.
    pub fn register(self: *DispatchTable, key: DispatchKey, entry: DispatchEntry, allow_overwrite: bool) !void {
        const gop = try self.entries.getOrPut(self.allocator, key);
        if (gop.found_existing and !allow_overwrite) {
            return error.DuplicateMethod;
        }

        var stamped = entry;
        if (gop.found_existing) {
            stamped.sequence = gop.value_ptr.sequence;
        } else {
            stamped.sequence = self.next_sequence;
            self.next_sequence += 1;
        }

        gop.value_ptr.* = stamped;
        self.generation +%= 1;
    }

    /// Look up a binary dispatch entry. Tries in precedence order:
    ///
    /// 1. (word, type_a, type_b) exact
    /// 2. (word, type_a, "*") wildcard on second
    /// 3. (word, "*", type_b) wildcard on first
    /// 4. (word, "*", "*") both wildcards
    pub fn lookupBinary(
        self: *const DispatchTable,
        dispatch_id: u32,
        type_a: *const TypeDescriptor,
        type_b: *const TypeDescriptor,
        any_sentinel: *const TypeDescriptor,
    ) ?DispatchEntry {
        if (self.entries.get(.{ .dispatch_id = dispatch_id, .type_a = type_a, .type_b = type_b })) |entry| {
            return entry;
        }
        if (self.entries.get(.{ .dispatch_id = dispatch_id, .type_a = type_a, .type_b = any_sentinel })) |entry| {
            return entry;
        }
        if (self.entries.get(.{ .dispatch_id = dispatch_id, .type_a = any_sentinel, .type_b = type_b })) |entry| {
            return entry;
        }
        if (self.entries.get(.{ .dispatch_id = dispatch_id, .type_a = any_sentinel, .type_b = any_sentinel })) |entry| {
            return entry;
        }
        return null;
    }

    /// Look up a unary dispatch entry. Tries:
    ///
    /// 1. (word, type_a, "") exact
    /// 2. (word, "*", "") wildcard
    pub fn lookupUnary(
        self: *const DispatchTable,
        dispatch_id: u32,
        type_a: *const TypeDescriptor,
        any_sentinel: *const TypeDescriptor,
        unary_sentinel: *const TypeDescriptor,
    ) ?DispatchEntry {
        if (self.entries.get(.{ .dispatch_id = dispatch_id, .type_a = type_a, .type_b = unary_sentinel })) |entry| {
            return entry;
        }
        if (self.entries.get(.{ .dispatch_id = dispatch_id, .type_a = any_sentinel, .type_b = unary_sentinel })) |entry| {
            return entry;
        }
        return null;
    }

    /// Collect all dispatch keys registered for a given dispatch ID.
    /// Caller owns the returned slice.
    pub fn keysForDispatchId(self: *const DispatchTable, dispatch_id: u32, alloc: Allocator) ![]DispatchKey {
        var results: std.ArrayListUnmanaged(DispatchKey) = .{};
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.key_ptr.dispatch_id == dispatch_id) {
                try results.append(alloc, entry.key_ptr.*);
            }
        }
        return results.toOwnedSlice(alloc);
    }

    pub const KeyEntryPair = struct {
        key: DispatchKey,
        entry: DispatchEntry,
    };

    fn coerceDescriptor(ptr: anytype) *const TypeDescriptor {
        const T = @TypeOf(ptr);
        switch (@typeInfo(T)) {
            .pointer => |info| {
                if (info.child == TypeDescriptor) return ptr;
                if (info.child == value_mod.TypeValue) return ptr.descriptor.?;
            },
            else => {},
        }
        @compileError("expected *const TypeDescriptor or *const TypeValue");
    }

    /// Register a native function dispatch entry with "native" provenance.
    pub fn registerNative(
        self: *DispatchTable,
        dispatch_id: u32,
        type_a: anytype,
        type_b: anytype,
        func: NativeFn,
    ) !void {
        const key = DispatchKey{
            .dispatch_id = dispatch_id,
            .type_a = coerceDescriptor(type_a),
            .type_b = coerceDescriptor(type_b),
        };
        const entry = DispatchEntry{
            .body = .{ .native_fn = func },
            .provenance = .{ .generator = "native", .parent = "", .role = "", .field = "" },
        };
        try self.register(key, entry, false);
        try self.native_entries.put(self.allocator, key, self.entries.get(key).?);
    }

    /// Look up a binary dispatch entry in the native-only shadow table.
    pub fn lookupNativeBinary(
        self: *const DispatchTable,
        dispatch_id: u32,
        type_a: *const TypeDescriptor,
        type_b: *const TypeDescriptor,
        any_sentinel: *const TypeDescriptor,
    ) ?DispatchEntry {
        if (self.native_entries.get(.{ .dispatch_id = dispatch_id, .type_a = type_a, .type_b = type_b })) |entry| {
            return entry;
        }
        if (self.native_entries.get(.{ .dispatch_id = dispatch_id, .type_a = type_a, .type_b = any_sentinel })) |entry| {
            return entry;
        }
        if (self.native_entries.get(.{ .dispatch_id = dispatch_id, .type_a = any_sentinel, .type_b = type_b })) |entry| {
            return entry;
        }
        if (self.native_entries.get(.{ .dispatch_id = dispatch_id, .type_a = any_sentinel, .type_b = any_sentinel })) |entry| {
            return entry;
        }
        return null;
    }

    /// Look up a unary dispatch entry in the native-only shadow table.
    pub fn lookupNativeUnary(
        self: *const DispatchTable,
        dispatch_id: u32,
        type_a: *const TypeDescriptor,
        any_sentinel: *const TypeDescriptor,
        unary_sentinel: *const TypeDescriptor,
    ) ?DispatchEntry {
        if (self.native_entries.get(.{ .dispatch_id = dispatch_id, .type_a = type_a, .type_b = unary_sentinel })) |entry| {
            return entry;
        }
        if (self.native_entries.get(.{ .dispatch_id = dispatch_id, .type_a = any_sentinel, .type_b = unary_sentinel })) |entry| {
            return entry;
        }
        return null;
    }

    /// Collect all dispatch keys and entries registered for a given dispatch ID, sorted by
    /// registration sequence. The map itself iterates in pointer-hash order, which differs run to
    /// run. Caller owns the returned slice.
    pub fn entriesForDispatchId(self: *const DispatchTable, dispatch_id: u32, alloc: Allocator) ![]KeyEntryPair {
        var results: std.ArrayListUnmanaged(KeyEntryPair) = .{};
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.key_ptr.dispatch_id == dispatch_id) {
                try results.append(alloc, .{ .key = entry.key_ptr.*, .entry = entry.value_ptr.* });
            }
        }
        std.mem.sortUnstable(KeyEntryPair, results.items, {}, lessThanBySequence);
        return results.toOwnedSlice(alloc);
    }

    /// Collect every entry in the base table, sorted by registration sequence. The map itself
    /// iterates in pointer-hash order, which differs run to run. Caller owns the returned slice.
    ///
    /// The order is total only because every base-table write path goes through `register`, which
    /// stamps a unique sequence. A direct `entries.put` leaves sequence 0, and tied entries sort
    /// in map order.
    pub fn allEntriesSorted(self: *const DispatchTable, alloc: Allocator) Allocator.Error![]KeyEntryPair {
        var results: std.ArrayListUnmanaged(KeyEntryPair) = .{};
        errdefer results.deinit(alloc);
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            try results.append(alloc, .{ .key = entry.key_ptr.*, .entry = entry.value_ptr.* });
        }
        std.mem.sortUnstable(KeyEntryPair, results.items, {}, lessThanBySequence);
        return results.toOwnedSlice(alloc);
    }

    fn lessThanBySequence(_: void, a: KeyEntryPair, b: KeyEntryPair) bool {
        return a.entry.sequence < b.entry.sequence;
    }
};

/// A scoped frame of dispatch entries, used by `with-isolation` to layer
/// registrations that can be discarded on scope exit.
pub const DispatchFrame = struct {
    entries: std.HashMapUnmanaged(DispatchKey, DispatchEntry, DispatchKeyContext, 80) = .{},

    pub fn deinit(self: *DispatchFrame, allocator: Allocator) void {
        self.entries.deinit(allocator);
    }
};

const EntriesMap = std.HashMapUnmanaged(DispatchKey, DispatchEntry, DispatchKeyContext, 80);

/// Look up a binary dispatch entry in a single entries map, following the
/// 4-step precedence: exact, wildcard-b, wildcard-a, both-wildcards.
pub fn lookupBinaryInEntries(
    entries: *const EntriesMap,
    dispatch_id: u32,
    type_a: *const TypeDescriptor,
    type_b: *const TypeDescriptor,
    any_sentinel: *const TypeDescriptor,
) ?DispatchEntry {
    if (entries.get(.{ .dispatch_id = dispatch_id, .type_a = type_a, .type_b = type_b })) |entry| {
        return entry;
    }
    if (entries.get(.{ .dispatch_id = dispatch_id, .type_a = type_a, .type_b = any_sentinel })) |entry| {
        return entry;
    }
    if (entries.get(.{ .dispatch_id = dispatch_id, .type_a = any_sentinel, .type_b = type_b })) |entry| {
        return entry;
    }
    if (entries.get(.{ .dispatch_id = dispatch_id, .type_a = any_sentinel, .type_b = any_sentinel })) |entry| {
        return entry;
    }
    return null;
}

/// Look up a unary dispatch entry in a single entries map, following the
/// 2-step precedence: exact, wildcard.
pub fn lookupUnaryInEntries(
    entries: *const EntriesMap,
    dispatch_id: u32,
    type_a: *const TypeDescriptor,
    any_sentinel: *const TypeDescriptor,
    unary_sentinel: *const TypeDescriptor,
) ?DispatchEntry {
    if (entries.get(.{ .dispatch_id = dispatch_id, .type_a = type_a, .type_b = unary_sentinel })) |entry| {
        return entry;
    }
    if (entries.get(.{ .dispatch_id = dispatch_id, .type_a = any_sentinel, .type_b = unary_sentinel })) |entry| {
        return entry;
    }
    return null;
}

/// Collect dispatch keys from an entries map for a given dispatch ID, appending to results.
pub fn collectKeysForDispatchId(entries: *const EntriesMap, dispatch_id: u32, results: *std.ArrayListUnmanaged(DispatchKey), alloc: Allocator) !void {
    var iter = entries.iterator();
    while (iter.next()) |entry| {
        if (entry.key_ptr.dispatch_id == dispatch_id) {
            try results.append(alloc, entry.key_ptr.*);
        }
    }
}

/// Collect dispatch key-entry pairs from an entries map for a given dispatch ID, appending to results.
pub fn collectEntriesForDispatchId(entries: *const EntriesMap, dispatch_id: u32, results: *std.ArrayListUnmanaged(DispatchTable.KeyEntryPair), alloc: Allocator) !void {
    var iter = entries.iterator();
    while (iter.next()) |entry| {
        if (entry.key_ptr.dispatch_id == dispatch_id) {
            try results.append(alloc, .{ .key = entry.key_ptr.*, .entry = entry.value_ptr.* });
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

fn dummyNativeFn(_: *Context) anyerror!void {}

fn testDescriptor(_: []const u8) !*value_mod.TypeDescriptor {
    // Tests rely on pointer identity, not the descriptor's contents.
    return try value_mod.createBuiltinTypeDescriptor(std.testing.allocator, .{});
}

test "dispatchTypeName returns correct name for native types" {
    try std.testing.expectEqualStrings("fixnum", dispatchTypeName(.{ .fixnum = 42 }));
    try std.testing.expectEqualStrings("boolean", dispatchTypeName(.{ .boolean = true }));
    try std.testing.expectEqualStrings("string", dispatchTypeName(value_mod.stringValue("hello")));
    try std.testing.expectEqualStrings("symbol", dispatchTypeName(value_mod.symbolValue("foo")));
    var empty_arr = value_mod.Array{ .header = undefined, .items = &.{}, .storage = .static };
    try std.testing.expectEqualStrings("array", dispatchTypeName(.{ .array = &empty_arr }));
}

test "dispatchTypeName returns virtual type name for tagged values" {
    const vt = value_mod.VirtualType{ .name = "duration", .inner_type = "fixnum" };
    const inner = Value{ .fixnum = 42 };
    const tagged = Value{ .tagged = .{ .tag = &vt, .inner = &inner } };
    try std.testing.expectEqualStrings("duration", dispatchTypeName(tagged));
}

test "dispatchTypeName returns struct type name for struct instances" {
    const st = value_mod.StructType{ .name = "point", .fields = &.{ "x", "y" } };
    var si = value_mod.StructInstance{ .struct_type = &st, .fields = &.{} };
    try std.testing.expectEqualStrings("point", dispatchTypeName(.{ .struct_instance = &si }));
}

test "register and lookupBinary exact match" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const duration_desc = try testDescriptor("duration");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, duration_desc);
    const any_desc = try testDescriptor("*");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, any_desc);

    const body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 99 } }, .line = 0 }};
    try table.register(
        .{ .dispatch_id = 1, .type_a = duration_desc, .type_b = duration_desc },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    const result = table.lookupBinary(1, duration_desc, duration_desc, any_desc);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.body.quotation.instructions.len);
}

test "lookupBinary returns null when no match" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const duration_desc = try testDescriptor("duration");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, duration_desc);
    const any_desc = try testDescriptor("*");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, any_desc);

    const result = table.lookupBinary(1, duration_desc, duration_desc, any_desc);
    try std.testing.expect(result == null);
}

test "lookupBinary wildcard precedence" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const duration_desc = try testDescriptor("duration");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, duration_desc);
    const fixnum_desc = try testDescriptor("fixnum");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, fixnum_desc);
    const string_desc = try testDescriptor("string");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, string_desc);
    const any_desc = try testDescriptor("*");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, any_desc);

    const exact_body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 }};
    const wild_b_body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 0 }};
    const wild_a_body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 0 }};
    const wild_both_body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 4 } }, .line = 0 }};

    // Register in reverse precedence order to ensure lookup logic is correct
    try table.register(
        .{ .dispatch_id = 1, .type_a = any_desc, .type_b = any_desc },
        .{ .body = .{ .quotation = .{ .instructions = wild_both_body } } },
        false,
    );
    try table.register(
        .{ .dispatch_id = 1, .type_a = any_desc, .type_b = fixnum_desc },
        .{ .body = .{ .quotation = .{ .instructions = wild_a_body } } },
        false,
    );
    try table.register(
        .{ .dispatch_id = 1, .type_a = duration_desc, .type_b = any_desc },
        .{ .body = .{ .quotation = .{ .instructions = wild_b_body } } },
        false,
    );
    try table.register(
        .{ .dispatch_id = 1, .type_a = duration_desc, .type_b = duration_desc },
        .{ .body = .{ .quotation = .{ .instructions = exact_body } } },
        false,
    );

    // Exact match should win
    const r1 = table.lookupBinary(1, duration_desc, duration_desc, any_desc).?;
    try std.testing.expectEqual(@as(i64, 1), r1.body.quotation.instructions[0].op.push_literal.fixnum);

    // Wildcard on second: (duration, fixnum) matches (duration, *)
    const r2 = table.lookupBinary(1, duration_desc, fixnum_desc, any_desc).?;
    try std.testing.expectEqual(@as(i64, 2), r2.body.quotation.instructions[0].op.push_literal.fixnum);

    // Wildcard on first: (string, fixnum) matches (*, fixnum)
    const r3 = table.lookupBinary(1, string_desc, fixnum_desc, any_desc).?;
    try std.testing.expectEqual(@as(i64, 3), r3.body.quotation.instructions[0].op.push_literal.fixnum);

    // Both wildcards: (string, string) matches (*, *)
    const r4 = table.lookupBinary(1, string_desc, string_desc, any_desc).?;
    try std.testing.expectEqual(@as(i64, 4), r4.body.quotation.instructions[0].op.push_literal.fixnum);
}

test "lookupUnary exact and wildcard" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const duration_desc = try testDescriptor("duration");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, duration_desc);
    const point_desc = try testDescriptor("point");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, point_desc);
    const any_desc = try testDescriptor("*");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, any_desc);
    const unary_desc = try testDescriptor("");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, unary_desc);

    const exact_body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 10 } }, .line = 0 }};
    const wild_body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 20 } }, .line = 0 }};

    try table.register(
        .{ .dispatch_id = 2, .type_a = duration_desc, .type_b = unary_desc },
        .{ .body = .{ .quotation = .{ .instructions = exact_body } } },
        false,
    );
    try table.register(
        .{ .dispatch_id = 2, .type_a = any_desc, .type_b = unary_desc },
        .{ .body = .{ .quotation = .{ .instructions = wild_body } } },
        false,
    );

    // Exact match
    const r1 = table.lookupUnary(2, duration_desc, any_desc, unary_desc).?;
    try std.testing.expectEqual(@as(i64, 10), r1.body.quotation.instructions[0].op.push_literal.fixnum);

    // Wildcard fallback
    const r2 = table.lookupUnary(2, point_desc, any_desc, unary_desc).?;
    try std.testing.expectEqual(@as(i64, 20), r2.body.quotation.instructions[0].op.push_literal.fixnum);

    // No match for different word
    try std.testing.expect(table.lookupUnary(99, duration_desc, any_desc, unary_desc) == null);
}

test "register duplicate key errors without allow_overwrite" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const duration_desc = try testDescriptor("duration");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, duration_desc);

    const body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 }};
    try table.register(
        .{ .dispatch_id = 1, .type_a = duration_desc, .type_b = duration_desc },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    const result = table.register(
        .{ .dispatch_id = 1, .type_a = duration_desc, .type_b = duration_desc },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );
    try std.testing.expectError(error.DuplicateMethod, result);
}

test "register duplicate key succeeds with allow_overwrite" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const duration_desc = try testDescriptor("duration");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, duration_desc);
    const any_desc = try testDescriptor("*");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, any_desc);

    const body1 = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 }};
    const body2 = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 0 }};

    try table.register(
        .{ .dispatch_id = 1, .type_a = duration_desc, .type_b = duration_desc },
        .{ .body = .{ .quotation = .{ .instructions = body1 } } },
        false,
    );
    try table.register(
        .{ .dispatch_id = 1, .type_a = duration_desc, .type_b = duration_desc },
        .{ .body = .{ .quotation = .{ .instructions = body2 } } },
        true,
    );

    // Shoulda gotten the overwritten body
    const result = table.lookupBinary(1, duration_desc, duration_desc, any_desc).?;
    try std.testing.expectEqual(@as(i64, 2), result.body.quotation.instructions[0].op.push_literal.fixnum);
}

test "registerNative creates retrievable entry with native_fn body" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const fixnum_desc = try testDescriptor("fixnum");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, fixnum_desc);
    const any_desc = try testDescriptor("*");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, any_desc);

    try table.registerNative(1, fixnum_desc, fixnum_desc, dummyNativeFn);

    const result = table.lookupBinary(1, fixnum_desc, fixnum_desc, any_desc);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.body == .native_fn);
    try std.testing.expectEqualStrings("native", result.?.provenance.?.generator);
}

test "registerNative unary entry is retrievable via lookupUnary" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const fixnum_desc = try testDescriptor("fixnum");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, fixnum_desc);
    const any_desc = try testDescriptor("*");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, any_desc);
    const unary_desc = try testDescriptor("");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, unary_desc);

    try table.registerNative(3, fixnum_desc, unary_desc, dummyNativeFn);

    const result = table.lookupUnary(3, fixnum_desc, any_desc, unary_desc);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.body == .native_fn);
}

test "registerNative duplicate returns DuplicateMethod" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const fixnum_desc = try testDescriptor("fixnum");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, fixnum_desc);

    try table.registerNative(1, fixnum_desc, fixnum_desc, dummyNativeFn);
    const result = table.registerNative(1, fixnum_desc, fixnum_desc, dummyNativeFn);
    try std.testing.expectError(error.DuplicateMethod, result);
}

test "register increments generation counter" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const fixnum_desc = try testDescriptor("fixnum");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, fixnum_desc);

    try std.testing.expectEqual(@as(u32, 0), table.generation);

    const body = &[_]value_mod.Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 }};
    try table.register(
        .{ .dispatch_id = 1, .type_a = fixnum_desc, .type_b = fixnum_desc },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );
    try std.testing.expectEqual(@as(u32, 1), table.generation);

    try table.register(
        .{ .dispatch_id = 1, .type_a = fixnum_desc, .type_b = fixnum_desc },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        true,
    );
    try std.testing.expectEqual(@as(u32, 2), table.generation);
}

test "register stamps monotonically increasing sequence" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const fixnum_desc = try testDescriptor("fixnum");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, fixnum_desc);
    const string_desc = try testDescriptor("string");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, string_desc);
    const any_desc = try testDescriptor("*");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, any_desc);

    const body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 }};
    try table.register(
        .{ .dispatch_id = 1, .type_a = fixnum_desc, .type_b = fixnum_desc },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );
    try table.register(
        .{ .dispatch_id = 1, .type_a = string_desc, .type_b = string_desc },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );
    try table.register(
        .{ .dispatch_id = 2, .type_a = fixnum_desc, .type_b = fixnum_desc },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    const first = table.lookupBinary(1, fixnum_desc, fixnum_desc, any_desc).?;
    const second = table.lookupBinary(1, string_desc, string_desc, any_desc).?;
    const third = table.lookupBinary(2, fixnum_desc, fixnum_desc, any_desc).?;
    try std.testing.expectEqual(@as(u64, 0), first.sequence);
    try std.testing.expectEqual(@as(u64, 1), second.sequence);
    try std.testing.expectEqual(@as(u64, 2), third.sequence);
}

test "overwriting re-registration keeps the original sequence" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const fixnum_desc = try testDescriptor("fixnum");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, fixnum_desc);
    const string_desc = try testDescriptor("string");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, string_desc);
    const any_desc = try testDescriptor("*");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, any_desc);

    const body1 = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 }};
    const body2 = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 0 }};

    try table.register(
        .{ .dispatch_id = 1, .type_a = fixnum_desc, .type_b = fixnum_desc },
        .{ .body = .{ .quotation = .{ .instructions = body1 } } },
        false,
    );
    try table.register(
        .{ .dispatch_id = 1, .type_a = string_desc, .type_b = string_desc },
        .{ .body = .{ .quotation = .{ .instructions = body1 } } },
        false,
    );
    try table.register(
        .{ .dispatch_id = 1, .type_a = fixnum_desc, .type_b = fixnum_desc },
        .{ .body = .{ .quotation = .{ .instructions = body2 } } },
        true,
    );

    const overwritten = table.lookupBinary(1, fixnum_desc, fixnum_desc, any_desc).?;
    try std.testing.expectEqual(@as(u64, 0), overwritten.sequence);
    try std.testing.expectEqual(@as(i64, 2), overwritten.body.quotation.instructions[0].op.push_literal.fixnum);

    // A later fresh insert still draws from the advanced counter.
    const body3 = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 0 }};
    try table.register(
        .{ .dispatch_id = 2, .type_a = fixnum_desc, .type_b = fixnum_desc },
        .{ .body = .{ .quotation = .{ .instructions = body3 } } },
        false,
    );
    const fresh = table.lookupBinary(2, fixnum_desc, fixnum_desc, any_desc).?;
    try std.testing.expectEqual(@as(u64, 2), fresh.sequence);
}

test "registerNative stamps the native_entries copy with the same sequence" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    const fixnum_desc = try testDescriptor("fixnum");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, fixnum_desc);
    const string_desc = try testDescriptor("string");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, string_desc);
    const any_desc = try testDescriptor("*");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, any_desc);

    try table.registerNative(1, fixnum_desc, fixnum_desc, dummyNativeFn);
    try table.registerNative(1, string_desc, string_desc, dummyNativeFn);

    const entry = table.lookupBinary(1, string_desc, string_desc, any_desc).?;
    const shadow = table.lookupNativeBinary(1, string_desc, string_desc, any_desc).?;
    try std.testing.expectEqual(@as(u64, 1), entry.sequence);
    try std.testing.expectEqual(entry.sequence, shadow.sequence);
}

test "entriesForDispatchId returns entries in registration order" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    var descs: [24]*value_mod.TypeDescriptor = undefined;
    for (&descs) |*d| d.* = try testDescriptor("t");
    defer for (descs) |d| value_mod.destroyTypeDescriptor(std.testing.allocator, d);

    for (descs, 0..) |d, i| {
        const dispatch_id: u32 = if (i % 2 == 0) 1 else 9;
        try table.register(
            .{ .dispatch_id = dispatch_id, .type_a = d, .type_b = d },
            .{ .body = .{ .native_fn = dummyNativeFn } },
            false,
        );
    }

    const pairs = try table.entriesForDispatchId(1, std.testing.allocator);
    defer std.testing.allocator.free(pairs);

    try std.testing.expectEqual(@as(usize, 12), pairs.len);
    for (pairs, 0..) |pair, i| {
        try std.testing.expectEqual(descs[i * 2], @constCast(pair.key.type_a));
        try std.testing.expectEqual(@as(u64, i * 2), pair.entry.sequence);
    }
}

test "allEntriesSorted returns every entry in registration order" {
    var table = DispatchTable.init(std.testing.allocator);
    defer table.deinit();

    var descs: [24]*value_mod.TypeDescriptor = undefined;
    for (&descs) |*d| d.* = try testDescriptor("t");
    defer for (descs) |d| value_mod.destroyTypeDescriptor(std.testing.allocator, d);

    for (descs, 0..) |d, i| {
        const dispatch_id: u32 = if (i % 2 == 0) 1 else 9;
        try table.register(
            .{ .dispatch_id = dispatch_id, .type_a = d, .type_b = d },
            .{ .body = .{ .native_fn = dummyNativeFn } },
            false,
        );
    }

    const pairs = try table.allEntriesSorted(std.testing.allocator);
    defer std.testing.allocator.free(pairs);

    try std.testing.expectEqual(descs.len, pairs.len);
    for (pairs, 0..) |pair, i| {
        try std.testing.expectEqual(descs[i], @constCast(pair.key.type_a));
        try std.testing.expectEqual(@as(u64, i), pair.entry.sequence);
    }
}

test "builtinTypeName matches dispatchTypeName for static variants" {
    // Verify all non-dynamic variants produce the same name via both functions.
    var empty_arr = value_mod.Array{ .header = undefined, .items = &.{}, .storage = .static };
    const num_variants = comptime @typeInfo(Value).@"union".fields.len;
    inline for (0..num_variants) |i| {
        const tag: std.meta.Tag(Value) = @enumFromInt(i);
        const comptime_name = builtinTypeName(tag);

        // Skip dynamic variants where dispatchTypeName reads from the value.
        if (tag == .tagged or tag == .struct_instance or tag == .resource) continue;

        // Construct a zero-initialized value with this discriminant.
        const val: Value = switch (tag) {
            .fixnum => .{ .fixnum = 0 },
            .float => .{ .float = 0.0 },
            .boolean => .{ .boolean = false },
            .string => value_mod.stringValue(""),
            .symbol => value_mod.symbolValue(""),
            .array => .{ .array = &empty_arr },
            .doc_string => .{ .doc_string = "" },
            .unit => .{ .unit = {} },
            // For pointer-based variants, skip runtime check (would need valid allocations).
            // The comptime name matching is sufficient for these.
            else => continue,
        };

        const runtime_name = dispatchTypeName(val);
        try std.testing.expectEqualStrings(comptime_name, runtime_name);
    }
}

test "dispatchDescriptor returns correct descriptor for builtin types" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_desc = dispatchDescriptor(.{ .fixnum = 42 }, &ctx);
    try std.testing.expectEqual(fixnum_desc, ctx.lookupBuiltinTypeValue("fixnum").?.descriptor.?);

    const bool_desc = dispatchDescriptor(.{ .boolean = true }, &ctx);
    try std.testing.expectEqual(bool_desc, ctx.lookupBuiltinTypeValue("boolean").?.descriptor.?);

    const string_desc = dispatchDescriptor(value_mod.stringValue("hello"), &ctx);
    try std.testing.expectEqual(string_desc, ctx.lookupBuiltinTypeValue("string").?.descriptor.?);

    const symbol_desc = dispatchDescriptor(value_mod.symbolValue("foo"), &ctx);
    try std.testing.expectEqual(symbol_desc, ctx.lookupBuiltinTypeValue("symbol").?.descriptor.?);

    const unit_desc = dispatchDescriptor(.{ .unit = {} }, &ctx);
    try std.testing.expectEqual(unit_desc, ctx.lookupBuiltinTypeValue("unit").?.descriptor.?);
}

test "dispatchDescriptor returns VirtualType descriptor for tagged values" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const desc = try testDescriptor("duration");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, desc);
    var tv = value_mod.TypeValue{ .name = "duration", .descriptor = desc };
    const vt = value_mod.VirtualType{ .name = "duration", .inner_type = "fixnum", .type_val = &tv };
    const inner = Value{ .fixnum = 42 };
    const tagged = Value{ .tagged = .{ .tag = &vt, .inner = &inner } };

    const result = dispatchDescriptor(tagged, &ctx);
    try std.testing.expectEqual(desc, result);
}

test "dispatchDescriptor falls back to builtin for tagged without type_val" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const vt = value_mod.VirtualType{ .name = "legacy", .inner_type = "fixnum" };
    const inner = Value{ .fixnum = 42 };
    const tagged = Value{ .tagged = .{ .tag = &vt, .inner = &inner } };

    const result = dispatchDescriptor(tagged, &ctx);
    try std.testing.expectEqual(result, ctx.lookupBuiltinTypeValue("tagged").?.descriptor.?);
}

test "dispatchDescriptor returns StructType descriptor for struct instances" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const desc = try testDescriptor("point");
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, desc);
    var tv = value_mod.TypeValue{ .name = "point", .descriptor = desc };
    const st = value_mod.StructType{ .name = "point", .fields = &.{ "x", "y" }, .type_val = &tv };
    var si = value_mod.StructInstance{ .struct_type = &st, .fields = &.{} };

    const result = dispatchDescriptor(.{ .struct_instance = &si }, &ctx);
    try std.testing.expectEqual(desc, result);
}

test "dispatchDescriptor creates resource descriptor" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var r = value_mod.Resource{ .type_name = "sqlite-db" };
    const result = dispatchDescriptor(.{ .resource = &r }, &ctx);
    try std.testing.expectEqualStrings("sqlite-db", ctx.lookupResourceTypeValue("sqlite-db").?.name);

    // Second call returns the same pointer (cached).
    const result2 = dispatchDescriptor(.{ .resource = &r }, &ctx);
    try std.testing.expectEqual(result, result2);
}

test "dispatchDescriptor matches builtin type descriptors" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var empty_arr = value_mod.Array{ .header = undefined, .items = &.{}, .storage = .static };
    const num_variants = comptime @typeInfo(Value).@"union".fields.len;
    inline for (0..num_variants) |i| {
        const tag: std.meta.Tag(Value) = @enumFromInt(i);

        if (tag == .tagged or tag == .struct_instance or tag == .resource) continue;

        const val: Value = switch (tag) {
            .fixnum => .{ .fixnum = 0 },
            .float => .{ .float = 0.0 },
            .boolean => .{ .boolean = false },
            .string => value_mod.stringValue(""),
            .symbol => value_mod.symbolValue(""),
            .array => .{ .array = &empty_arr },
            .doc_string => .{ .doc_string = "" },
            .unit => .{ .unit = {} },
            else => continue,
        };

        const desc = dispatchDescriptor(val, &ctx);
        const name = dispatchTypeName(val);
        try std.testing.expectEqual(desc, ctx.lookupBuiltinTypeValue(name).?.descriptor.?);
    }
}
