const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Vector = value_mod.Vector;
const ByteArray = value_mod.ByteArray;
const HashTable = value_mod.HashTable;

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;
const helpers = @import("helpers.zig");
const dispatch_helpers = @import("dispatch_helpers.zig");
const dispatch_mod = @import("../dispatch.zig");
const DispatchTable = dispatch_mod.DispatchTable;
const markers_mod = @import("markers.zig");
const sequence = @import("sequence.zig");
const Iterator = @import("../iterator.zig").Iterator;
const tasks = @import("tasks.zig");

const simd = @import("../simd.zig");

const popFixnum = helpers.popFixnum;
const popBoolean = helpers.popBoolean;
const popQuotation = helpers.popQuotation;
const popVector = helpers.popVector;
const popByteArray = helpers.popByteArray;
const setErrorContext = helpers.setErrorContext;
const valueTypeName = helpers.valueTypeName;

const builtin = @import("builtin");
const BigIntManaged = value_mod.BigIntManaged;
const Allocator = std.mem.Allocator;
const TaggedPayload = std.meta.TagPayload(Value, .tagged);

const unwrapBaseType = dispatch_mod.unwrapBaseType;

/// Convert a sequence value to an ArrayIter. Returns null if the value is not
/// a recognized sequence type. For arrays, wraps directly; for other types
/// (string, vector, byte-array, set), materializes to a values array first.
fn seqToArrayIter(seq: Value, alloc: Allocator) !?*Iterator {
    const s = unwrapBaseType(seq);
    const items: []const Value = switch (s) {
        .array => |arr| arr,
        .string, .vector, .byte_array, .set => try sequenceToValues(s, alloc),
        else => return null,
    };
    const iter = try alloc.create(Iterator);
    iter.* = .{ .kind = .{ .array = .{ .items = items, .index = 0 } } };
    return iter;
}

const arithmetic = @import("arithmetic.zig");

/// Materialize any iterable to a mutable []Value for in-place sorting.
fn collectToMutableArray(in_seq: Value, ctx: *Context, alloc: Allocator) ![]Value {
    const seq = unwrapBaseType(in_seq);
    switch (seq) {
        .array => |arr| {
            const result = alloc.alloc(Value, arr.len) catch return error.OutOfMemory;
            @memcpy(result, arr);
            return result;
        },
        .iterator => |iter| {
            var list = std.ArrayListUnmanaged(Value){};
            while (try iter.next(ctx)) |elem| {
                list.append(alloc, elem) catch return error.OutOfMemory;
            }
            return list.items;
        },
        .string, .vector, .byte_array, .set => return try sequenceToValues(seq, alloc),
        else => {
            setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
            return error.TypeMismatch;
        },
    }
}

const SortContext = struct {
    ctx: *Context,
    quotation: value_mod.Quotation,
    err: ?anyerror,
};

fn sortCompareFn(sort_ctx: *SortContext, a: Value, b: Value) bool {
    if (sort_ctx.err != null) return false;
    sort_ctx.ctx.stack.push(a) catch |e| {
        sort_ctx.err = e;
        return false;
    };
    sort_ctx.ctx.stack.push(b) catch |e| {
        sort_ctx.err = e;
        return false;
    };
    sort_ctx.ctx.executeQuotationWithFrame(sort_ctx.quotation) catch |e| {
        sort_ctx.err = e;
        return false;
    };
    const result = popBoolean(sort_ctx.ctx) catch |e| {
        sort_ctx.err = e;
        return false;
    };
    return result;
}

fn nativeSort(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    const items = try collectToMutableArray(seq, ctx, alloc);
    if (items.len <= 1) {
        try ctx.stack.push(.{ .array = items });
        return;
    }

    var sort_ctx = SortContext{
        .ctx = ctx,
        .quotation = quot,
        .err = null,
    };
    std.mem.sort(Value, items, &sort_ctx, sortCompareFn);
    if (sort_ctx.err) |e| return e;
    try ctx.stack.push(.{ .array = items });
}

const SortByContext = struct {
    ctx: *Context,
    keys: []const Value,
    err: ?anyerror,
};

fn sortByKeyCompareFn(sort_ctx: *SortByContext, a_idx: usize, b_idx: usize) bool {
    if (sort_ctx.err != null) return false;
    const a_key = sort_ctx.keys[a_idx];
    const b_key = sort_ctx.keys[b_idx];

    switch (a_key) {
        .fixnum => |av| switch (b_key) {
            .fixnum => |bv| return av < bv,
            else => {},
        },
        .float => |av| switch (b_key) {
            .float => |bv| return av < bv,
            else => {},
        },
        .string => |av| switch (b_key) {
            .string => |bv| return std.mem.order(u8, av, bv) == .lt,
            else => {},
        },
        else => {},
    }

    sort_ctx.ctx.stack.push(a_key) catch |e| {
        sort_ctx.err = e;
        return false;
    };
    sort_ctx.ctx.stack.push(b_key) catch |e| {
        sort_ctx.err = e;
        return false;
    };
    arithmetic.nativeLt(sort_ctx.ctx) catch |e| {
        if (e == error.TypeMismatch) {
            sort_ctx.err = error.NotComparable;
        } else {
            sort_ctx.err = e;
        }
        return false;
    };
    const result = popBoolean(sort_ctx.ctx) catch |e| {
        sort_ctx.err = e;
        return false;
    };
    return result;
}

fn nativeSortBy(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    const items = try collectToMutableArray(seq, ctx, alloc);
    if (items.len == 0) {
        try ctx.stack.push(.{ .array = items });
        return;
    }

    const keys = alloc.alloc(Value, items.len) catch return error.OutOfMemory;
    for (items, 0..) |item, i| {
        try ctx.stack.push(item);
        try ctx.executeQuotationWithFrame(quot);
        keys[i] = try ctx.stack.pop();
    }

    const indices = alloc.alloc(usize, items.len) catch return error.OutOfMemory;
    for (indices, 0..) |*idx, i| {
        idx.* = i;
    }

    var sort_ctx = SortByContext{
        .ctx = ctx,
        .keys = keys,
        .err = null,
    };
    std.mem.sort(usize, indices, &sort_ctx, sortByKeyCompareFn);
    if (sort_ctx.err) |e| {
        if (e == error.NotComparable) {
            setErrorContext(ctx, "keys are not comparable", .{});
        }
        return e;
    }

    const result = alloc.alloc(Value, items.len) catch return error.OutOfMemory;
    for (indices, 0..) |src_idx, dst_idx| {
        result[dst_idx] = items[src_idx];
    }
    try ctx.stack.push(.{ .array = result });
}

const SequenceIterator = sequence.SequenceIterator;
const SequenceBuilder = sequence.SequenceBuilder;
const SequenceKind = sequence.SequenceKind;
const sequenceLength = sequence.sequenceLength;
const classifySequence = sequence.classifySequence;
const sequenceToValues = sequence.sequenceToValues;
const utf8NthCodepoint = sequence.utf8NthCodepoint;
const utf8CodepointCount = sequence.utf8CodepointCount;
const utf8SliceByCodepoints = sequence.utf8SliceByCodepoints;

// =============================================================================
// Native dispatch entry functions
// =============================================================================

fn nativeLenString(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    try ctx.stack.push(.{ .fixnum = @intCast(utf8CodepointCount(val.string)) });
}

fn nativeLenArray(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    try ctx.stack.push(.{ .fixnum = @intCast(val.array.len) });
}

fn nativeLenVector(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    try ctx.stack.push(.{ .fixnum = @intCast(val.vector.items.len) });
}

fn nativeLenByteArray(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    try ctx.stack.push(.{ .fixnum = @intCast(val.byte_array.slice().len) });
}

fn nativeLenSet(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    try ctx.stack.push(.{ .fixnum = @intCast(val.set.count()) });
}

fn nativeLenHash(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    try ctx.stack.push(.{ .fixnum = @intCast(val.hash.count()) });
}

fn nativeLenMutableMap(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    try ctx.stack.push(.{ .fixnum = @intCast(val.mutable_map.count()) });
}

fn nativeLenModule(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    try ctx.stack.push(.{ .fixnum = @intCast(val.module.words.count()) });
}

fn nativeNthString(ctx: *Context) anyerror!void {
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    const index = b.fixnum;
    if (index < 0) {
        setErrorContext(ctx, "negative index {d}", .{index});
        return error.IndexOutOfBounds;
    }
    const idx: usize = @intCast(index);
    const s = a.string;
    const cp_slice = utf8NthCodepoint(s, idx) orelse {
        const slen = std.unicode.utf8CountCodepoints(s) catch s.len;
        setErrorContext(ctx, "index {d} out of bounds for string of length {d}", .{ idx, slen });
        return error.IndexOutOfBounds;
    };
    const result = ctx.quotationAllocator().dupe(u8, cp_slice) catch return error.OutOfMemory;
    try ctx.stack.push(.{ .string = result });
}

fn nativeNthArray(ctx: *Context) anyerror!void {
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    const index = b.fixnum;
    if (index < 0) {
        setErrorContext(ctx, "negative index {d}", .{index});
        return error.IndexOutOfBounds;
    }
    const idx: usize = @intCast(index);
    const arr = a.array;
    if (idx >= arr.len) {
        setErrorContext(ctx, "index {d} out of bounds for array of length {d}", .{ idx, arr.len });
        return error.IndexOutOfBounds;
    }
    try ctx.stack.push(arr[idx]);
}

fn nativeNthVector(ctx: *Context) anyerror!void {
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    const index = b.fixnum;
    if (index < 0) {
        setErrorContext(ctx, "negative index {d}", .{index});
        return error.IndexOutOfBounds;
    }
    const idx: usize = @intCast(index);
    const v = a.vector;
    if (idx >= v.items.len) {
        setErrorContext(ctx, "index {d} out of bounds for vector of length {d}", .{ idx, v.items.len });
        return error.IndexOutOfBounds;
    }
    try ctx.stack.push(v.items[idx]);
}

fn nativeNthByteArray(ctx: *Context) anyerror!void {
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    const index = b.fixnum;
    if (index < 0) {
        setErrorContext(ctx, "negative index {d}", .{index});
        return error.IndexOutOfBounds;
    }
    const idx: usize = @intCast(index);
    const ba = a.byte_array;
    const bytes = ba.slice();
    if (idx >= bytes.len) {
        setErrorContext(ctx, "index {d} out of bounds for byte-array of length {d}", .{ idx, bytes.len });
        return error.IndexOutOfBounds;
    }
    try ctx.stack.push(.{ .fixnum = bytes[idx] });
}

fn nativeFirstString(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();
    var iter = SequenceIterator.init(val, alloc) orelse unreachable;
    const first = try iter.next() orelse {
        setErrorContext(ctx, "empty string", .{});
        return error.EmptySequence;
    };
    try ctx.stack.push(first);
}

fn nativeFirstArray(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const a = val.array;
    if (a.len == 0) {
        setErrorContext(ctx, "empty array", .{});
        return error.EmptySequence;
    }
    try ctx.stack.push(a[0]);
}

fn nativeFirstVector(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const v = val.vector;
    if (v.items.len == 0) {
        setErrorContext(ctx, "empty vector", .{});
        return error.EmptySequence;
    }
    try ctx.stack.push(v.items[0]);
}

fn nativeFirstByteArray(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const b = val.byte_array;
    const bytes = b.slice();
    if (bytes.len == 0) {
        setErrorContext(ctx, "empty byte-array", .{});
        return error.EmptySequence;
    }
    try ctx.stack.push(.{ .fixnum = bytes[0] });
}

fn nativeLastString(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();
    var iter = SequenceIterator.init(val, alloc) orelse unreachable;
    var last: ?Value = null;
    while (try iter.next()) |elem| {
        last = elem;
    }
    try ctx.stack.push(last orelse {
        setErrorContext(ctx, "empty string", .{});
        return error.EmptySequence;
    });
}

fn nativeLastArray(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const a = val.array;
    if (a.len == 0) {
        setErrorContext(ctx, "empty array", .{});
        return error.EmptySequence;
    }
    try ctx.stack.push(a[a.len - 1]);
}

fn nativeLastVector(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const v = val.vector;
    if (v.items.len == 0) {
        setErrorContext(ctx, "empty vector", .{});
        return error.EmptySequence;
    }
    try ctx.stack.push(v.items[v.items.len - 1]);
}

fn nativeLastByteArray(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const b = val.byte_array;
    const bytes = b.slice();
    if (bytes.len == 0) {
        setErrorContext(ctx, "empty byte-array", .{});
        return error.EmptySequence;
    }
    try ctx.stack.push(.{ .fixnum = bytes[bytes.len - 1] });
}

// =============================================================================
// Registration of all native dispatch entries
// =============================================================================

pub fn registerNativeDispatch(dispatch: *DispatchTable, ctx: *Context) !void {
    const unary = ctx.getDispatchUnarySentinel();
    const tv = struct {
        fn get(c: *Context, name: []const u8) *const value_mod.TypeValue {
            return c.lookupBuiltinTypeValue(name).?;
        }
    }.get;

    const string = tv(ctx, "string");
    const array = tv(ctx, "array");
    const vector = tv(ctx, "vector");
    const byte_array = tv(ctx, "byte-array");
    const set = tv(ctx, "set");
    const hash = tv(ctx, "hash");
    const mutable_map = tv(ctx, "mutable-map");
    const module = tv(ctx, "module");
    const fixnum = tv(ctx, "fixnum");

    // #len : unary entries
    const len_did = ctx.resolveDispatchId("#len").?;
    try dispatch.registerNative(len_did, string, unary, nativeLenString);
    try dispatch.registerNative(len_did, array, unary, nativeLenArray);
    try dispatch.registerNative(len_did, vector, unary, nativeLenVector);
    try dispatch.registerNative(len_did, byte_array, unary, nativeLenByteArray);
    try dispatch.registerNative(len_did, set, unary, nativeLenSet);
    try dispatch.registerNative(len_did, hash, unary, nativeLenHash);
    try dispatch.registerNative(len_did, mutable_map, unary, nativeLenMutableMap);
    try dispatch.registerNative(len_did, module, unary, nativeLenModule);

    // #nth : binary entries (all with type_b = fixnum)
    const nth_did = ctx.resolveDispatchId("#nth").?;
    try dispatch.registerNative(nth_did, string, fixnum, nativeNthString);
    try dispatch.registerNative(nth_did, array, fixnum, nativeNthArray);
    try dispatch.registerNative(nth_did, vector, fixnum, nativeNthVector);
    try dispatch.registerNative(nth_did, byte_array, fixnum, nativeNthByteArray);

    // #first : unary entries
    const first_did = ctx.resolveDispatchId("#first").?;
    try dispatch.registerNative(first_did, string, unary, nativeFirstString);
    try dispatch.registerNative(first_did, array, unary, nativeFirstArray);
    try dispatch.registerNative(first_did, vector, unary, nativeFirstVector);
    try dispatch.registerNative(first_did, byte_array, unary, nativeFirstByteArray);

    // #last : unary entries
    const last_did = ctx.resolveDispatchId("#last").?;
    try dispatch.registerNative(last_did, string, unary, nativeLastString);
    try dispatch.registerNative(last_did, array, unary, nativeLastArray);
    try dispatch.registerNative(last_did, vector, unary, nativeLastVector);
    try dispatch.registerNative(last_did, byte_array, unary, nativeLastByteArray);

    // >array : unary entries
    const to_array_did = ctx.resolveDispatchId(">array").?;
    try dispatch.registerNative(to_array_did, vector, unary, nativeToArrayVector);
    try dispatch.registerNative(to_array_did, byte_array, unary, nativeToArrayByteArray);
    try dispatch.registerNative(to_array_did, set, unary, nativeToArraySet);
    try dispatch.registerNative(to_array_did, array, unary, nativeToArrayArray);

    // >hash : unary entries
    const to_hash_did = ctx.resolveDispatchId(">hash").?;
    try dispatch.registerNative(to_hash_did, mutable_map, unary, nativeToHashMutableMap);
    try dispatch.registerNative(to_hash_did, hash, unary, nativeToHashHash);

    // #peek / #poke! : byte-level access
    try dispatch.registerNative(ctx.resolveDispatchId("#peek").?, byte_array, unary, nativePeekByteArray);
    try dispatch.registerNative(ctx.resolveDispatchId("#poke!").?, byte_array, unary, nativePokeByteArray);
}

pub const primitives = [_]Primitive{
    // Sequence length
    .{
        .name = "#len",
        .stack_effect = "seq -- n",
        .doc = "Get length of sequence. O(1) and non-destructive; does not work on iterators (use #count instead).",
        .func = nativeLen,
        .markers = &.{@constCast(&markers_mod.generic_marker)},
    },
    // Sequence element access
    .{ .name = "#nth", .stack_effect = "seq n -- elem", .doc = "Get element at index.", .func = nativeNth, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = "#first", .stack_effect = "seq -- elem", .doc = "Get first element of sequence.", .func = nativeFirst, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = "#last", .stack_effect = "seq -- elem", .doc = "Get last element of sequence.", .func = nativeLast, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    // Sequence transformations
    .{ .name = "#each", .stack_effect = "seq quot: ( elem -- ) --", .doc = "Execute quotation for each element of sequence.", .func = nativeEach },
    .{ .name = "#each-index", .stack_effect = "seq quot: ( elem idx -- ) --", .doc = "Execute quotation for each element of sequence with its zero-based index.", .func = nativeEachIndex },
    .{ .name = "#map", .stack_effect = "seq quot: ( elem -- elem' ) -- seq'", .doc = "Transform each element of sequence using quotation.", .func = nativeMap },
    .{ .name = "#filter", .stack_effect = "seq quot: ( elem -- ? ) -- seq'", .doc = "Keep elements where quotation returns true.", .func = nativeFilter },
    .{ .name = "#reduce", .stack_effect = "seq init quot: ( acc elem -- acc' ) -- value", .doc = "Fold sequence with accumulator.", .func = nativeReduce },
    .{ .name = "#reduce-index", .stack_effect = "seq init quot: ( acc elem idx -- acc' ) -- value", .doc = "Fold sequence with accumulator and zero-based index.", .func = nativeReduceIndex },
    .{ .name = "#slice", .stack_effect = "seq start end -- subseq", .doc = "Extract subsequence from start (inclusive) to end (exclusive).", .func = nativeSlice },
    .{ .name = "#take", .stack_effect = "seq n -- seq'", .doc = "Take first n elements of sequence.", .func = nativeTake },
    .{ .name = "#drop", .stack_effect = "seq n -- seq'", .doc = "Drop first n elements of sequence.", .func = nativeDrop },
    .{ .name = "#sort", .stack_effect = "seq quot: ( a b -- ? ) -- array", .doc = "Sort sequence using comparator quotation. Returns a new sorted array.", .func = nativeSort },
    .{ .name = "#sort-by", .stack_effect = "seq quot: ( elem -- key ) -- array", .doc = "Sort sequence by keys extracted via quotation. Keys compared with natural ordering.", .func = nativeSortBy },
    // Sequence concatenation
    .{ .name = "#append", .stack_effect = "seq1 seq2 -- seq", .doc = "Concatenate seq2 to seq1, returning new sequence of seq1's type.", .func = nativeAppend },
    .{ .name = "#append!", .stack_effect = "vec seq -- vec", .doc = "Mutably append sequence elements to vector.", .func = nativeAppendMut },
    .{ .name = "#prepend", .stack_effect = "seq1 seq2 -- seq", .doc = "Prepend seq2's elements before seq1, returning new sequence of seq1's type.", .func = nativePrepend },
    // Sequence element addition/removal
    .{ .name = "#push", .stack_effect = "seq elem -- seq'", .doc = "Add element to end of sequence, returns new sequence.", .func = nativePush },
    .{ .name = "#pop", .stack_effect = "seq -- seq' elem", .doc = "Remove last element, return both sequence and element.", .func = nativePop },
    .{ .name = "#unshift", .stack_effect = "seq elem -- seq'", .doc = "Add element to start of sequence, returns new sequence.", .func = nativeUnshift },
    .{ .name = "#shift", .stack_effect = "seq -- seq' elem", .doc = "Remove first element, return both truncated sequence and element.", .func = nativeShift },
    .{ .name = "#nth!", .stack_effect = "seq n value -- seq", .doc = "Set element at index in mutable sequence.", .func = nativeNthMut },
    .{ .name = "#push!", .stack_effect = "vec elem -- vec", .doc = "Mutably add element to end of vector.", .func = nativePushMut },
    .{ .name = "#pop!", .stack_effect = "vec -- vec elem", .doc = "Mutably remove last element from vector.", .func = nativePopMut },
    .{ .name = "#unshift!", .stack_effect = "vec elem -- vec", .doc = "Mutably add element to start of vector.", .func = nativeUnshiftMut },
    .{ .name = "#shift!", .stack_effect = "vec -- vec elem", .doc = "Mutably remove first element from vector.", .func = nativeShiftMut },
    // Sequence predicates
    .{ .name = "#empty?", .stack_effect = "seq -- ?", .doc = "Test if sequence is empty.", .func = nativeEmpty },
    .{ .name = "#starts-with?", .stack_effect = "seq prefix -- ?", .doc = "Test if sequence starts with prefix.", .func = nativeStartsWith },
    .{ .name = "#ends-with?", .stack_effect = "seq suffix -- ?", .doc = "Test if sequence ends with suffix.", .func = nativeEndsWith },
    .{ .name = "#in?", .stack_effect = "seq elem -- ?", .doc = "Test if sequence contains element (substring test for strings).", .func = nativeIn },
    .{ .name = "#index-of", .stack_effect = "seq elem -- n/f", .doc = "Find index of element, or f if not found.", .func = nativeIndexOf },
    // Freeze
    .{ .name = "freeze", .stack_effect = "vector -- array", .doc = "Convert a vector to an array (copy semantics).", .func = nativeFreeze, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    // Container conversion
    .{ .name = ">array", .stack_effect = "container -- array", .doc = "Convert vector, byte-array, set, or array to an immutable array. Copy semantics; original unchanged.", .func = nativeToArray, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = ">byte-array", .stack_effect = "value -- value", .doc = "Convert a byte-array or packed value to owned byte-array storage. Owned inputs are returned unchanged; borrowed inputs are copied.", .func = nativeToByteArray, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = ">hash", .stack_effect = "container -- hash", .doc = "Convert mutable-map or hash to an immutable hash. Mutable-map uses copy semantics; original unchanged.", .func = nativeToHash, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    // Byte-level access
    .{ .name = "#peek", .stack_effect = "byte-array offset width -- fixnum", .doc = "Read width bytes (1/2/4/8) at offset from byte-array as unsigned fixnum.", .func = nativePeek, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = "#poke!", .stack_effect = "byte-array offset value width -- byte-array", .doc = "Write value as width bytes (1/2/4/8) at offset in byte-array.", .func = nativePoke, .markers = &.{@constCast(&markers_mod.generic_marker)} },
};

/// #len ( seq -- n ) - Get length of sequence
pub fn nativeLen(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, "#len")) return;
    const val = try ctx.stack.pop();
    setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(val)});
    return error.TypeMismatch;
}

/// #nth ( seq n -- elem ) - Get element at index
pub fn nativeNth(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchBinary(ctx, "#nth")) return;
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    _ = b;
    setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(a)});
    return error.TypeMismatch;
}

/// #nth! ( seq n value -- seq ) - Set element at index in mutable sequence
fn nativeNthMut(ctx: *Context) anyerror!void {
    // dispatch: seq is at position 2, below n and value
    if (ctx.stack.depth() >= 3) {
        const seq_peek = try ctx.stack.peekN(2);
        const a_type = dispatch_mod.dispatchDescriptor(seq_peek, ctx);
        if (ctx.resolveDispatchId("#nth!")) |did| {
            if (ctx.lookupUnaryDispatch(did, a_type)) |entry| {
                try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                return;
            }
            if (dispatch_mod.dispatchEnumTypeValue(seq_peek)) |ae| {
                if (ctx.lookupUnaryDispatch(did, ae.descriptor.?)) |entry| {
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
            if (dispatch_mod.dispatchBaseTypeValue(seq_peek)) |bt| {
                if (ctx.lookupUnaryDispatch(did, bt.descriptor.?)) |entry| {
                    const len = ctx.stack.items.items.len;
                    ctx.stack.items.items[len - 3] = seq_peek.tagged.inner.*;
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
        }
    }

    var value = try ctx.stack.pop();
    const index = try popFixnum(ctx);
    const seq = try ctx.stack.pop();

    if (index < 0) {
        setErrorContext(ctx, "negative index {d}", .{index});
        return error.IndexOutOfBounds;
    }
    const idx: usize = @intCast(index);

    switch (seq) {
        .vector => |v| {
            if (idx >= v.items.len) {
                setErrorContext(ctx, "index {d} out of bounds for vector of length {d}", .{ idx, v.items.len });
                return error.IndexOutOfBounds;
            }
            if (ctx.parent_context != null) value = tasks.deepCopyValue(value, ctx.containerAllocator()) catch return error.OutOfMemory;
            v.items[idx] = value;
            try ctx.stack.push(.{ .vector = v });
        },
        .byte_array => |b| {
            const bytes = b.slice();
            if (idx >= bytes.len) {
                setErrorContext(ctx, "index {d} out of bounds for byte-array of length {d}", .{ idx, bytes.len });
                return error.IndexOutOfBounds;
            }
            const byte_val: u8 = switch (value) {
                .fixnum => |i| blk: {
                    if (i < 0 or i > 255) {
                        setErrorContext(ctx, "#nth! byte value {d} out of range 0-255", .{i});
                        return error.FixnumOverflow;
                    }
                    break :blk @intCast(i);
                },
                else => {
                    setErrorContext(ctx, "#nth! on byte-array requires fixnum value 0-255, got {s}", .{valueTypeName(value)});
                    return error.TypeMismatch;
                },
            };
            bytes[idx] = byte_val;
            try ctx.stack.push(.{ .byte_array = b });
        },
        .array, .string => {
            setErrorContext(ctx, "cannot mutate immutable {s}", .{valueTypeName(seq)});
            return error.TypeMismatch;
        },
        else => {
            setErrorContext(ctx, "expected mutable sequence, got {s}", .{valueTypeName(seq)});
            return error.TypeMismatch;
        },
    }
}

/// #first ( seq -- elem ) - Get first element
pub fn nativeFirst(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, "#first")) return;
    const val = try ctx.stack.pop();
    if (val == .set) {
        setErrorContext(ctx, "sets do not support positional access", .{});
    } else {
        setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(val)});
    }
    return error.TypeMismatch;
}

/// #last ( seq -- elem ) - Get last element
pub fn nativeLast(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, "#last")) return;
    const val = try ctx.stack.pop();
    if (val == .set) {
        setErrorContext(ctx, "sets do not support positional access", .{});
    } else {
        setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(val)});
    }
    return error.TypeMismatch;
}

/// #each ( seq quot -- ) - Execute quotation for each element of sequence
pub fn nativeEach(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const raw_seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();
    const seq = unwrapBaseType(raw_seq);

    if (seq == .iterator) {
        while (try seq.iterator.next(ctx)) |elem| {
            try ctx.stack.push(elem);
            try ctx.executeQuotationWithFrame(quot);
        }
        return;
    }

    var iter = SequenceIterator.init(seq, alloc) orelse {
        setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(raw_seq)});
        return error.TypeMismatch;
    };
    while (try iter.next()) |elem| {
        try ctx.stack.push(elem);
        try ctx.executeQuotationWithFrame(quot);
    }
}

/// #each-index ( seq quot -- ) - Execute quotation for each element with zero-based index
pub fn nativeEachIndex(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const raw_seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();
    const seq = unwrapBaseType(raw_seq);
    var idx: i64 = 0;

    if (seq == .iterator) {
        while (try seq.iterator.next(ctx)) |elem| {
            try ctx.stack.push(elem);
            try ctx.stack.push(.{ .fixnum = idx });
            try ctx.executeQuotationWithFrame(quot);
            idx += 1;
        }
        return;
    }

    var iter = SequenceIterator.init(seq, alloc) orelse {
        setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(raw_seq)});
        return error.TypeMismatch;
    };
    while (try iter.next()) |elem| {
        try ctx.stack.push(elem);
        try ctx.stack.push(.{ .fixnum = idx });
        try ctx.executeQuotationWithFrame(quot);
        idx += 1;
    }
}

/// #map ( seq quot -- iterator ) - Lazily transform each element of sequence
///
/// Always returns a lazy iterator, regardless of input type. Use #collect
/// to materialize the result into an array.
pub fn nativeMap(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    const inner = if (seq == .iterator)
        seq.iterator
    else
        try seqToArrayIter(seq, alloc) orelse {
            setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
            return error.TypeMismatch;
        };

    const iter = alloc.create(Iterator) catch return error.OutOfMemory;
    iter.* = .{ .kind = .{ .map = .{ .inner = inner, .quotation = quot } } };
    try ctx.stack.push(.{ .iterator = iter });
}

/// #filter ( seq quot -- iterator ) - Lazily keep elements where quotation returns true
///
/// Always returns a lazy iterator, regardless of input type. Use #collect
/// to materialize the result into an array.
pub fn nativeFilter(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    const inner = if (seq == .iterator)
        seq.iterator
    else
        try seqToArrayIter(seq, alloc) orelse {
            setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
            return error.TypeMismatch;
        };

    const iter = alloc.create(Iterator) catch return error.OutOfMemory;
    iter.* = .{ .kind = .{ .filter = .{ .inner = inner, .quotation = quot } } };
    try ctx.stack.push(.{ .iterator = iter });
}

/// #reduce ( seq init quot -- result ) - Fold sequence with accumulator
pub fn nativeReduce(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    var acc = try ctx.stack.pop(); // initial accumulator
    const raw_seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();
    const seq = unwrapBaseType(raw_seq);

    if (seq == .iterator) {
        while (try seq.iterator.next(ctx)) |elem| {
            try ctx.stack.push(acc);
            try ctx.stack.push(elem);
            try ctx.executeQuotationWithFrame(quot);
            acc = try ctx.stack.pop();
        }
        try ctx.stack.push(acc);
        return;
    }

    var iter = SequenceIterator.init(seq, alloc) orelse {
        setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
        return error.TypeMismatch;
    };
    while (try iter.next()) |elem| {
        try ctx.stack.push(acc);
        try ctx.stack.push(elem);
        try ctx.executeQuotationWithFrame(quot);
        acc = try ctx.stack.pop();
    }
    try ctx.stack.push(acc);
}

/// #reduce-index ( seq init quot -- result ) - Fold sequence with accumulator and zero-based index
pub fn nativeReduceIndex(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    var acc = try ctx.stack.pop();
    const raw_seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();
    const seq = unwrapBaseType(raw_seq);
    var idx: i64 = 0;

    if (seq == .iterator) {
        while (try seq.iterator.next(ctx)) |elem| {
            try ctx.stack.push(acc);
            try ctx.stack.push(elem);
            try ctx.stack.push(.{ .fixnum = idx });
            try ctx.executeQuotationWithFrame(quot);
            acc = try ctx.stack.pop();
            idx += 1;
        }
        try ctx.stack.push(acc);
        return;
    }

    var iter = SequenceIterator.init(seq, alloc) orelse {
        setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(raw_seq)});
        return error.TypeMismatch;
    };
    while (try iter.next()) |elem| {
        try ctx.stack.push(acc);
        try ctx.stack.push(elem);
        try ctx.stack.push(.{ .fixnum = idx });
        try ctx.executeQuotationWithFrame(quot);
        acc = try ctx.stack.pop();
        idx += 1;
    }
    try ctx.stack.push(acc);
}

/// #slice ( seq start end -- subseq ) - Extract subsequence [start, end)
pub fn nativeSlice(ctx: *Context) anyerror!void {
    const end_val = try popFixnum(ctx);
    const start_val = try popFixnum(ctx);
    const seq = try ctx.stack.pop();

    if (start_val < 0) {
        setErrorContext(ctx, "negative start index {d}", .{start_val});
        return error.IndexOutOfBounds;
    }
    if (end_val < 0) {
        setErrorContext(ctx, "negative end index {d}", .{end_val});
        return error.IndexOutOfBounds;
    }
    if (start_val > end_val) {
        setErrorContext(ctx, "start {d} > end {d}", .{ start_val, end_val });
        return error.IndexOutOfBounds;
    }

    const start: usize = @intCast(start_val);
    const end: usize = @intCast(end_val);

    const alloc = ctx.quotationAllocator();

    switch (seq) {
        .array => |arr| {
            if (end > arr.len) {
                setErrorContext(ctx, "slice [{}:{}] out of bounds for array of length {}", .{ start, end, arr.len });
                return error.IndexOutOfBounds;
            }
            const slice_len = end - start;
            const result = alloc.alloc(Value, slice_len) catch return error.OutOfMemory;
            @memcpy(result, arr[start..end]);
            try ctx.stack.push(.{ .array = result });
        },
        .string => |s| {
            const bounds = utf8SliceByCodepoints(s, start, end) orelse {
                const slen = std.unicode.utf8CountCodepoints(s) catch s.len;
                setErrorContext(ctx, "slice [{}:{}] out of bounds for string of length {}", .{ start, end, slen });
                return error.IndexOutOfBounds;
            };
            const result = alloc.dupe(u8, s[bounds.start_byte..bounds.end_byte]) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .string = result });
        },
        .vector => |v| {
            if (end > v.items.len) {
                setErrorContext(ctx, "slice [{}:{}] out of bounds for vector of length {}", .{ start, end, v.items.len });
                return error.IndexOutOfBounds;
            }
            const slice_len = end - start;
            const result_vec = alloc.create(Vector) catch return error.OutOfMemory;
            result_vec.* = Vector{};
            result_vec.ensureTotalCapacity(alloc, slice_len) catch return error.OutOfMemory;
            for (v.items[start..end]) |elem| {
                result_vec.appendAssumeCapacity(elem);
            }
            try ctx.stack.push(.{ .vector = result_vec });
        },
        .byte_array => |b| {
            const bytes = b.slice();
            if (end > bytes.len) {
                setErrorContext(ctx, "slice [{}:{}] out of bounds for byte-array of length {}", .{ start, end, bytes.len });
                return error.IndexOutOfBounds;
            }
            const slice_len = end - start;
            const result_ba = alloc.create(ByteArray) catch return error.OutOfMemory;
            result_ba.* = ByteArray{};
            result_ba.ensureTotalCapacity(alloc, slice_len) catch return error.OutOfMemory;
            for (bytes[start..end]) |byte| {
                result_ba.appendAssumeCapacity(byte);
            }
            try ctx.stack.push(.{ .byte_array = result_ba });
        },
        else => {
            setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
            return error.TypeMismatch;
        },
    }
}

/// #append ( seq1 seq2 -- seq ) - Concatenate seq2 to seq1, returns new sequence of type seq1
///
/// seq1 determines the result type. seq2 elements are converted/iterated into seq1's type.
pub fn nativeAppend(ctx: *Context) anyerror!void {
    const seq2 = try ctx.stack.pop();
    const seq1 = try ctx.stack.pop();

    const alloc = ctx.quotationAllocator();

    switch (seq1) {
        .array => |arr1| {
            const items2 = try sequenceToValues(seq2, alloc);
            const result = alloc.alloc(Value, arr1.len + items2.len) catch return error.OutOfMemory;
            @memcpy(result[0..arr1.len], arr1);
            @memcpy(result[arr1.len..], items2);
            try ctx.stack.push(.{ .array = result });
        },
        .vector => |vec1| {
            const items2 = try sequenceToValues(seq2, alloc);
            const new_vec = alloc.create(Vector) catch return error.OutOfMemory;
            new_vec.* = Vector{};
            new_vec.ensureTotalCapacity(alloc, vec1.items.len + items2.len) catch return error.OutOfMemory;
            for (vec1.items) |item| {
                new_vec.appendAssumeCapacity(item);
            }
            for (items2) |item| {
                new_vec.appendAssumeCapacity(item);
            }
            try ctx.stack.push(.{ .vector = new_vec });
        },
        .string => |s1| {
            // For strings, convert seq2 elements to strings and concatenate
            // Accept both strings (codepoints) and integers 0-255 (single bytes)
            const items2 = try sequenceToValues(seq2, alloc);
            var total_len: usize = s1.len;
            for (items2) |item| {
                switch (item) {
                    .string => |s| total_len += s.len,
                    .fixnum => |i| {
                        if (i < 0 or i > 255) {
                            setErrorContext(ctx, "byte value {d} out of range 0-255", .{i});
                            return error.FixnumOverflow;
                        }
                        total_len += 1;
                    },
                    else => {
                        setErrorContext(ctx, "cannot append {s} to string", .{valueTypeName(item)});
                        return error.TypeMismatch;
                    },
                }
            }
            const result = alloc.alloc(u8, total_len) catch return error.OutOfMemory;
            @memcpy(result[0..s1.len], s1);
            var pos: usize = s1.len;
            for (items2) |item| {
                switch (item) {
                    .string => |s| {
                        @memcpy(result[pos..][0..s.len], s);
                        pos += s.len;
                    },
                    .fixnum => |i| {
                        result[pos] = @intCast(i);
                        pos += 1;
                    },
                    else => unreachable,
                }
            }
            try ctx.stack.push(.{ .string = result });
        },
        .byte_array => |b1| {
            // For byte arrays, accept integers 0-255 and strings (as UTF-8 bytes)
            const items2 = try sequenceToValues(seq2, alloc);

            var extra_len: usize = 0;
            for (items2) |item| {
                switch (item) {
                    .fixnum => |i| {
                        if (i < 0 or i > 255) {
                            setErrorContext(ctx, "byte value {d} out of range 0-255", .{i});
                            return error.FixnumOverflow;
                        }
                        extra_len += 1;
                    },
                    .string => |s| extra_len += s.len,
                    else => {
                        setErrorContext(ctx, "cannot append {s} to byte-array", .{valueTypeName(item)});
                        return error.TypeMismatch;
                    },
                }
            }
            const result_ba = alloc.create(ByteArray) catch return error.OutOfMemory;
            result_ba.* = ByteArray{};
            const bytes1 = b1.slice();
            result_ba.ensureTotalCapacity(alloc, bytes1.len + extra_len) catch return error.OutOfMemory;
            for (bytes1) |byte| {
                result_ba.appendAssumeCapacity(byte);
            }
            for (items2) |item| {
                switch (item) {
                    .fixnum => |i| {
                        result_ba.appendAssumeCapacity(@intCast(i));
                    },
                    .string => |s| {
                        for (s) |byte| {
                            result_ba.appendAssumeCapacity(byte);
                        }
                    },
                    else => unreachable,
                }
            }
            try ctx.stack.push(.{ .byte_array = result_ba });
        },
        else => {
            setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq1)});
            return error.TypeMismatch;
        },
    }
}

/// #append! ( vec seq -- vec ) - Mutably append sequence elements to vector
pub fn nativeAppendMut(ctx: *Context) anyerror!void {
    // dispatch: vec is at position 1, below seq
    if (ctx.stack.depth() >= 2) {
        const seq_peek = try ctx.stack.peekN(1);
        const a_type = dispatch_mod.dispatchDescriptor(seq_peek, ctx);
        if (ctx.resolveDispatchId("#append!")) |did| {
            if (ctx.lookupUnaryDispatch(did, a_type)) |entry| {
                try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                return;
            }
            if (dispatch_mod.dispatchEnumTypeValue(seq_peek)) |ae| {
                if (ctx.lookupUnaryDispatch(did, ae.descriptor.?)) |entry| {
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
            if (dispatch_mod.dispatchBaseTypeValue(seq_peek)) |bt| {
                if (ctx.lookupUnaryDispatch(did, bt.descriptor.?)) |entry| {
                    const len = ctx.stack.items.items.len;
                    ctx.stack.items.items[len - 2] = seq_peek.tagged.inner.*;
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
        }
    }

    const seq = try ctx.stack.pop();
    const vec = try popVector(ctx);
    const alloc = ctx.containerAllocator();
    const in_task = ctx.parent_context != null;

    const items = try sequenceToValues(seq, alloc);
    for (items) |elem| {
        const stored = if (in_task) tasks.deepCopyValue(elem, alloc) catch return error.OutOfMemory else elem;
        vec.append(alloc, stored) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .vector = vec });
}

/// #prepend ( seq1 seq2 -- seq ) - Prepend seq2's elements to seq1, returns new sequence of type seq1
///
/// Result contains seq2's elements followed by seq1's elements, with type of seq1.
pub fn nativePrepend(ctx: *Context) anyerror!void {
    const seq2 = try ctx.stack.pop();
    const seq1 = try ctx.stack.pop();

    const alloc = ctx.quotationAllocator();

    switch (seq1) {
        .array => |arr1| {
            const items2 = try sequenceToValues(seq2, alloc);
            const result = alloc.alloc(Value, items2.len + arr1.len) catch return error.OutOfMemory;
            @memcpy(result[0..items2.len], items2);
            @memcpy(result[items2.len..], arr1);
            try ctx.stack.push(.{ .array = result });
        },
        .vector => |vec1| {
            const items2 = try sequenceToValues(seq2, alloc);
            const new_vec = alloc.create(Vector) catch return error.OutOfMemory;
            new_vec.* = Vector{};
            new_vec.ensureTotalCapacity(alloc, items2.len + vec1.items.len) catch return error.OutOfMemory;
            for (items2) |item| {
                new_vec.appendAssumeCapacity(item);
            }
            for (vec1.items) |item| {
                new_vec.appendAssumeCapacity(item);
            }
            try ctx.stack.push(.{ .vector = new_vec });
        },
        .string => |s1| {
            // For strings, convert seq2 elements to strings and prepend
            // Accept both strings (codepoints) and integers 0-255 (single bytes)
            const items2 = try sequenceToValues(seq2, alloc);
            var total_len: usize = s1.len;
            for (items2) |item| {
                switch (item) {
                    .string => |s| total_len += s.len,
                    .fixnum => |i| {
                        if (i < 0 or i > 255) {
                            setErrorContext(ctx, "byte value {d} out of range 0-255", .{i});
                            return error.FixnumOverflow;
                        }
                        total_len += 1; // single byte
                    },
                    else => {
                        setErrorContext(ctx, "cannot prepend {s} to string", .{valueTypeName(item)});
                        return error.TypeMismatch;
                    },
                }
            }

            const result = alloc.alloc(u8, total_len) catch return error.OutOfMemory;
            var pos: usize = 0;
            for (items2) |item| {
                switch (item) {
                    .string => |s| {
                        @memcpy(result[pos..][0..s.len], s);
                        pos += s.len;
                    },
                    .fixnum => |i| {
                        result[pos] = @intCast(i);
                        pos += 1;
                    },
                    else => unreachable,
                }
            }

            @memcpy(result[pos..], s1);
            try ctx.stack.push(.{ .string = result });
        },
        .byte_array => |b1| {
            // For byte arrays, accept integers 0-255 and strings (as UTF-8 bytes)
            const items2 = try sequenceToValues(seq2, alloc);

            var extra_len: usize = 0;
            for (items2) |item| {
                switch (item) {
                    .fixnum => |i| {
                        if (i < 0 or i > 255) {
                            setErrorContext(ctx, "byte value {d} out of range 0-255", .{i});
                            return error.FixnumOverflow;
                        }
                        extra_len += 1;
                    },
                    .string => |s| extra_len += s.len,
                    else => {
                        setErrorContext(ctx, "cannot prepend {s} to byte-array", .{valueTypeName(item)});
                        return error.TypeMismatch;
                    },
                }
            }

            const result_ba = alloc.create(ByteArray) catch return error.OutOfMemory;
            result_ba.* = ByteArray{};
            const bytes1 = b1.slice();
            result_ba.ensureTotalCapacity(alloc, extra_len + bytes1.len) catch return error.OutOfMemory;
            for (items2) |item| {
                switch (item) {
                    .fixnum => |i| {
                        result_ba.appendAssumeCapacity(@intCast(i));
                    },
                    .string => |s| {
                        for (s) |byte| {
                            result_ba.appendAssumeCapacity(byte);
                        }
                    },
                    else => unreachable,
                }
            }

            for (bytes1) |byte| {
                result_ba.appendAssumeCapacity(byte);
            }

            try ctx.stack.push(.{ .byte_array = result_ba });
        },
        else => {
            setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq1)});
            return error.TypeMismatch;
        },
    }
}

/// #push ( seq elem -- seq' ) - Add element to end of sequence, returns new sequence of type seq
fn nativePush(ctx: *Context) anyerror!void {
    const elem = try ctx.stack.pop();
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    switch (seq) {
        .array => |arr| {
            const result = alloc.alloc(Value, arr.len + 1) catch return error.OutOfMemory;
            @memcpy(result[0..arr.len], arr);
            result[arr.len] = elem;
            try ctx.stack.push(.{ .array = result });
        },
        .vector => |vec| {
            const new_vec = alloc.create(Vector) catch return error.OutOfMemory;
            new_vec.* = Vector{};
            new_vec.ensureTotalCapacity(alloc, vec.items.len + 1) catch return error.OutOfMemory;
            for (vec.items) |item| {
                new_vec.appendAssumeCapacity(item);
            }
            new_vec.appendAssumeCapacity(elem);
            try ctx.stack.push(.{ .vector = new_vec });
        },
        .string => |s| {
            // Element must be a string
            const elem_str = switch (elem) {
                .string => |es| es,
                else => {
                    setErrorContext(ctx, "#push on string requires string element, got {s}", .{valueTypeName(elem)});
                    return error.TypeMismatch;
                },
            };
            const result = alloc.alloc(u8, s.len + elem_str.len) catch return error.OutOfMemory;
            @memcpy(result[0..s.len], s);
            @memcpy(result[s.len..], elem_str);
            try ctx.stack.push(.{ .string = result });
        },
        .byte_array => |b| {
            // Element must be a fixnum 0-255
            const byte_val: u8 = switch (elem) {
                .fixnum => |i| blk: {
                    if (i < 0 or i > 255) {
                        setErrorContext(ctx, "byte value {d} out of range 0-255", .{i});
                        return error.FixnumOverflow;
                    }
                    break :blk @intCast(i);
                },
                else => {
                    setErrorContext(ctx, "#push on byte-array requires fixnum element, got {s}", .{valueTypeName(elem)});
                    return error.TypeMismatch;
                },
            };
            const result_ba = alloc.create(ByteArray) catch return error.OutOfMemory;
            result_ba.* = ByteArray{};
            const bytes = b.slice();
            result_ba.ensureTotalCapacity(alloc, bytes.len + 1) catch return error.OutOfMemory;
            for (bytes) |byte| {
                result_ba.appendAssumeCapacity(byte);
            }
            result_ba.appendAssumeCapacity(byte_val);
            try ctx.stack.push(.{ .byte_array = result_ba });
        },
        else => {
            setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
            return error.TypeMismatch;
        },
    }
}

/// #pop ( seq -- seq' elem ) - Remove last element, return both sequence and element
fn nativePop(ctx: *Context) anyerror!void {
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    switch (seq) {
        .array => |arr| {
            if (arr.len == 0) {
                setErrorContext(ctx, "cannot #pop from empty array", .{});
                return error.EmptySequence;
            }
            const result = alloc.alloc(Value, arr.len - 1) catch return error.OutOfMemory;
            @memcpy(result, arr[0 .. arr.len - 1]);
            try ctx.stack.push(.{ .array = result });
            try ctx.stack.push(arr[arr.len - 1]);
        },
        .vector => |vec| {
            if (vec.items.len == 0) {
                setErrorContext(ctx, "cannot #pop from empty vector", .{});
                return error.EmptySequence;
            }
            const new_vec = alloc.create(Vector) catch return error.OutOfMemory;
            new_vec.* = Vector{};
            new_vec.ensureTotalCapacity(alloc, vec.items.len - 1) catch return error.OutOfMemory;
            for (vec.items[0 .. vec.items.len - 1]) |item| {
                new_vec.appendAssumeCapacity(item);
            }
            try ctx.stack.push(.{ .vector = new_vec });
            try ctx.stack.push(vec.items[vec.items.len - 1]);
        },
        .string => |s| {
            const cp_count = std.unicode.utf8CountCodepoints(s) catch {
                setErrorContext(ctx, "invalid UTF-8 in string", .{});
                return error.InvalidUtf8;
            };
            if (cp_count == 0) {
                setErrorContext(ctx, "cannot #pop from empty string", .{});
                return error.EmptySequence;
            }
            const bounds = utf8SliceByCodepoints(s, cp_count - 1, cp_count) orelse {
                setErrorContext(ctx, "internal error getting last codepoint", .{});
                return error.InvalidUtf8;
            };
            const rest = alloc.dupe(u8, s[0..bounds.start_byte]) catch return error.OutOfMemory;
            const last = alloc.dupe(u8, s[bounds.start_byte..bounds.end_byte]) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .string = rest });
            try ctx.stack.push(.{ .string = last });
        },
        .byte_array => |b| {
            const bytes = b.slice();
            if (bytes.len == 0) {
                setErrorContext(ctx, "cannot #pop from empty byte-array", .{});
                return error.EmptySequence;
            }
            const last_byte = bytes[bytes.len - 1];
            const result_ba = alloc.create(ByteArray) catch return error.OutOfMemory;
            result_ba.* = ByteArray{};
            result_ba.ensureTotalCapacity(alloc, bytes.len - 1) catch return error.OutOfMemory;
            for (bytes[0 .. bytes.len - 1]) |byte| {
                result_ba.appendAssumeCapacity(byte);
            }
            try ctx.stack.push(.{ .byte_array = result_ba });
            try ctx.stack.push(.{ .fixnum = last_byte });
        },
        else => {
            setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
            return error.TypeMismatch;
        },
    }
}

/// #unshift ( seq elem -- seq' ) - Add element to start of sequence, returns new sequence of type seq
fn nativeUnshift(ctx: *Context) anyerror!void {
    const elem = try ctx.stack.pop();
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    switch (seq) {
        .array => |arr| {
            const result = alloc.alloc(Value, arr.len + 1) catch return error.OutOfMemory;
            result[0] = elem;
            @memcpy(result[1..], arr);
            try ctx.stack.push(.{ .array = result });
        },
        .vector => |vec| {
            const new_vec = alloc.create(Vector) catch return error.OutOfMemory;
            new_vec.* = Vector{};
            new_vec.ensureTotalCapacity(alloc, vec.items.len + 1) catch return error.OutOfMemory;
            new_vec.appendAssumeCapacity(elem);
            for (vec.items) |item| {
                new_vec.appendAssumeCapacity(item);
            }
            try ctx.stack.push(.{ .vector = new_vec });
        },
        .string => |s| {
            const elem_str = switch (elem) {
                .string => |es| es,
                else => {
                    setErrorContext(ctx, "#unshift on string requires string element, got {s}", .{valueTypeName(elem)});
                    return error.TypeMismatch;
                },
            };
            const result = alloc.alloc(u8, elem_str.len + s.len) catch return error.OutOfMemory;
            @memcpy(result[0..elem_str.len], elem_str);
            @memcpy(result[elem_str.len..], s);
            try ctx.stack.push(.{ .string = result });
        },
        .byte_array => |b| {
            const byte_val: u8 = switch (elem) {
                .fixnum => |i| blk: {
                    if (i < 0 or i > 255) {
                        setErrorContext(ctx, "byte value {d} out of range 0-255", .{i});
                        return error.FixnumOverflow;
                    }
                    break :blk @intCast(i);
                },
                else => {
                    setErrorContext(ctx, "#unshift on byte-array requires fixnum element, got {s}", .{valueTypeName(elem)});
                    return error.TypeMismatch;
                },
            };
            const result_ba = alloc.create(ByteArray) catch return error.OutOfMemory;
            result_ba.* = ByteArray{};
            const bytes = b.slice();
            result_ba.ensureTotalCapacity(alloc, bytes.len + 1) catch return error.OutOfMemory;
            result_ba.appendAssumeCapacity(byte_val);
            for (bytes) |byte| {
                result_ba.appendAssumeCapacity(byte);
            }
            try ctx.stack.push(.{ .byte_array = result_ba });
        },
        else => {
            setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
            return error.TypeMismatch;
        },
    }
}

/// #shift ( seq -- seq' elem ) - Remove first element, return both truncated sequence and element
fn nativeShift(ctx: *Context) anyerror!void {
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    switch (seq) {
        .array => |arr| {
            if (arr.len == 0) {
                setErrorContext(ctx, "cannot #shift from empty array", .{});
                return error.EmptySequence;
            }
            const result = alloc.alloc(Value, arr.len - 1) catch return error.OutOfMemory;
            @memcpy(result, arr[1..]);
            try ctx.stack.push(.{ .array = result });
            try ctx.stack.push(arr[0]);
        },
        .vector => |vec| {
            if (vec.items.len == 0) {
                setErrorContext(ctx, "cannot #shift from empty vector", .{});
                return error.EmptySequence;
            }
            const new_vec = alloc.create(Vector) catch return error.OutOfMemory;
            new_vec.* = Vector{};
            new_vec.ensureTotalCapacity(alloc, vec.items.len - 1) catch return error.OutOfMemory;
            for (vec.items[1..]) |item| {
                new_vec.appendAssumeCapacity(item);
            }
            try ctx.stack.push(.{ .vector = new_vec });
            try ctx.stack.push(vec.items[0]);
        },
        .string => |s| {
            const cp_count = std.unicode.utf8CountCodepoints(s) catch {
                setErrorContext(ctx, "invalid UTF-8 in string", .{});
                return error.InvalidUtf8;
            };
            if (cp_count == 0) {
                setErrorContext(ctx, "cannot #shift from empty string", .{});
                return error.EmptySequence;
            }
            const bounds = utf8SliceByCodepoints(s, 0, 1) orelse {
                setErrorContext(ctx, "internal error getting first codepoint", .{});
                return error.InvalidUtf8;
            };
            const first = alloc.dupe(u8, s[0..bounds.end_byte]) catch return error.OutOfMemory;
            const rest = alloc.dupe(u8, s[bounds.end_byte..]) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .string = rest });
            try ctx.stack.push(.{ .string = first });
        },
        .byte_array => |b| {
            const bytes = b.slice();
            if (bytes.len == 0) {
                setErrorContext(ctx, "cannot #shift from empty byte-array", .{});
                return error.EmptySequence;
            }
            const first_byte = bytes[0];
            const result_ba = alloc.create(ByteArray) catch return error.OutOfMemory;
            result_ba.* = ByteArray{};
            result_ba.ensureTotalCapacity(alloc, bytes.len - 1) catch return error.OutOfMemory;
            for (bytes[1..]) |byte| {
                result_ba.appendAssumeCapacity(byte);
            }
            try ctx.stack.push(.{ .byte_array = result_ba });
            try ctx.stack.push(.{ .fixnum = first_byte });
        },
        else => {
            setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
            return error.TypeMismatch;
        },
    }
}

/// #push! ( vec elem -- vec ) - Mutate vec to add element to end
fn nativePushMut(ctx: *Context) anyerror!void {
    // dispatch: vec is at position 1, below elem
    if (ctx.stack.depth() >= 2) {
        const seq_peek = try ctx.stack.peekN(1);
        const a_type = dispatch_mod.dispatchDescriptor(seq_peek, ctx);
        if (ctx.resolveDispatchId("#push!")) |did| {
            if (ctx.lookupUnaryDispatch(did, a_type)) |entry| {
                try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                return;
            }
            if (dispatch_mod.dispatchEnumTypeValue(seq_peek)) |ae| {
                if (ctx.lookupUnaryDispatch(did, ae.descriptor.?)) |entry| {
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
            if (dispatch_mod.dispatchBaseTypeValue(seq_peek)) |bt| {
                if (ctx.lookupUnaryDispatch(did, bt.descriptor.?)) |entry| {
                    const len = ctx.stack.items.items.len;
                    ctx.stack.items.items[len - 2] = seq_peek.tagged.inner.*;
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
        }
    }

    var elem = try ctx.stack.pop();
    const vec = try popVector(ctx);

    const alloc = ctx.containerAllocator();
    if (ctx.parent_context != null) elem = tasks.deepCopyValue(elem, alloc) catch return error.OutOfMemory;
    vec.append(alloc, elem) catch return error.OutOfMemory;
    try ctx.stack.push(.{ .vector = vec });
}

/// #pop! ( vec -- vec elem ) - Mutate vec to remove last element from vector
fn nativePopMut(ctx: *Context) anyerror!void {
    // dispatch: vec is at position 0
    if (ctx.stack.depth() >= 1) {
        const seq_peek = try ctx.stack.peek();
        const a_type = dispatch_mod.dispatchDescriptor(seq_peek, ctx);
        if (ctx.resolveDispatchId("#pop!")) |did| {
            if (ctx.lookupUnaryDispatch(did, a_type)) |entry| {
                try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                return;
            }
            if (dispatch_mod.dispatchEnumTypeValue(seq_peek)) |ae| {
                if (ctx.lookupUnaryDispatch(did, ae.descriptor.?)) |entry| {
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
            if (dispatch_mod.dispatchBaseTypeValue(seq_peek)) |bt| {
                if (ctx.lookupUnaryDispatch(did, bt.descriptor.?)) |entry| {
                    const len = ctx.stack.items.items.len;
                    ctx.stack.items.items[len - 1] = seq_peek.tagged.inner.*;
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
        }
    }

    const vec = try popVector(ctx);
    if (vec.items.len == 0) {
        setErrorContext(ctx, "cannot #pop! from empty vector", .{});
        return error.EmptySequence;
    }

    const elem = vec.pop().?;
    try ctx.stack.push(.{ .vector = vec });
    try ctx.stack.push(elem);
}

/// #unshift! ( vec elem -- vec ) - Mutate vec to add element to start of vector
fn nativeUnshiftMut(ctx: *Context) anyerror!void {
    // dispatch: vec is at position 1, below elem
    if (ctx.stack.depth() >= 2) {
        const seq_peek = try ctx.stack.peekN(1);
        const a_type = dispatch_mod.dispatchDescriptor(seq_peek, ctx);
        if (ctx.resolveDispatchId("#unshift!")) |did| {
            if (ctx.lookupUnaryDispatch(did, a_type)) |entry| {
                try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                return;
            }
            if (dispatch_mod.dispatchEnumTypeValue(seq_peek)) |ae| {
                if (ctx.lookupUnaryDispatch(did, ae.descriptor.?)) |entry| {
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
            if (dispatch_mod.dispatchBaseTypeValue(seq_peek)) |bt| {
                if (ctx.lookupUnaryDispatch(did, bt.descriptor.?)) |entry| {
                    const len = ctx.stack.items.items.len;
                    ctx.stack.items.items[len - 2] = seq_peek.tagged.inner.*;
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
        }
    }

    var elem = try ctx.stack.pop();
    const vec = try popVector(ctx);
    const alloc = ctx.containerAllocator();

    if (ctx.parent_context != null) elem = tasks.deepCopyValue(elem, alloc) catch return error.OutOfMemory;
    vec.insert(alloc, 0, elem) catch return error.OutOfMemory;
    try ctx.stack.push(.{ .vector = vec });
}

/// #shift! ( vec -- vec elem ) - Mutate vec to remove first element
fn nativeShiftMut(ctx: *Context) anyerror!void {
    // dispatch: vec is at position 0
    if (ctx.stack.depth() >= 1) {
        const seq_peek = try ctx.stack.peek();
        const a_type = dispatch_mod.dispatchDescriptor(seq_peek, ctx);
        if (ctx.resolveDispatchId("#shift!")) |did| {
            if (ctx.lookupUnaryDispatch(did, a_type)) |entry| {
                try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                return;
            }
            if (dispatch_mod.dispatchEnumTypeValue(seq_peek)) |ae| {
                if (ctx.lookupUnaryDispatch(did, ae.descriptor.?)) |entry| {
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
            if (dispatch_mod.dispatchBaseTypeValue(seq_peek)) |bt| {
                if (ctx.lookupUnaryDispatch(did, bt.descriptor.?)) |entry| {
                    const len = ctx.stack.items.items.len;
                    ctx.stack.items.items[len - 1] = seq_peek.tagged.inner.*;
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
        }
    }

    const vec = try popVector(ctx);
    if (vec.items.len == 0) {
        setErrorContext(ctx, "cannot #shift! from empty vector", .{});
        return error.EmptySequence;
    }

    const elem = vec.orderedRemove(0);
    try ctx.stack.push(.{ .vector = vec });
    try ctx.stack.push(elem);
}

/// #empty? ( seq -- ? ) - Is sequence empty?
fn nativeEmpty(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const len = sequenceLength(val) orelse {
        setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(val)});
        return error.TypeMismatch;
    };
    try ctx.stack.push(.{ .boolean = len == 0 });
}

/// #starts-with? ( seq prefix -- ? ) - Does seq start with prefix?
fn nativeStartsWith(ctx: *Context) anyerror!void {
    const prefix = try ctx.stack.pop();
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    switch (seq) {
        .string => |s| {
            const prefix_str = switch (prefix) {
                .string => |ps| ps,
                else => {
                    setErrorContext(ctx, "#starts-with? on string requires string prefix, got {s}", .{valueTypeName(prefix)});
                    return error.TypeMismatch;
                },
            };
            try ctx.stack.push(.{ .boolean = std.mem.startsWith(u8, s, prefix_str) });
        },
        .array => |arr| {
            const prefix_items = try sequenceToValues(prefix, alloc);
            if (prefix_items.len > arr.len) {
                try ctx.stack.push(.{ .boolean = false });
                return;
            }
            for (prefix_items, 0..) |p, i| {
                if (!arr[i].eql(p)) {
                    try ctx.stack.push(.{ .boolean = false });
                    return;
                }
            }
            try ctx.stack.push(.{ .boolean = true });
        },
        .vector => |vec| {
            const prefix_items = try sequenceToValues(prefix, alloc);
            if (prefix_items.len > vec.items.len) {
                try ctx.stack.push(.{ .boolean = false });
                return;
            }
            for (prefix_items, 0..) |p, i| {
                if (!vec.items[i].eql(p)) {
                    try ctx.stack.push(.{ .boolean = false });
                    return;
                }
            }
            try ctx.stack.push(.{ .boolean = true });
        },
        .byte_array => |b| {
            const prefix_items = try sequenceToValues(prefix, alloc);
            const bytes = b.slice();
            if (prefix_items.len > bytes.len) {
                try ctx.stack.push(.{ .boolean = false });
                return;
            }
            for (prefix_items, 0..) |p, i| {
                if (p != .fixnum or p.fixnum < 0 or p.fixnum > 255) {
                    setErrorContext(ctx, "#starts-with? on byte-array requires fixnum elements 0-255", .{});
                    return error.TypeMismatch;
                }
                if (bytes[i] != @as(u8, @intCast(p.fixnum))) {
                    try ctx.stack.push(.{ .boolean = false });
                    return;
                }
            }
            try ctx.stack.push(.{ .boolean = true });
        },
        else => {
            setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
            return error.TypeMismatch;
        },
    }
}

/// #ends-with? ( seq suffix -- ? ) - Does seq end with suffix?
fn nativeEndsWith(ctx: *Context) anyerror!void {
    const suffix = try ctx.stack.pop();
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    switch (seq) {
        .string => |s| {
            const suffix_str = switch (suffix) {
                .string => |ss| ss,
                else => {
                    setErrorContext(ctx, "#ends-with? on string requires string suffix, got {s}", .{valueTypeName(suffix)});
                    return error.TypeMismatch;
                },
            };
            try ctx.stack.push(.{ .boolean = std.mem.endsWith(u8, s, suffix_str) });
        },
        .array => |arr| {
            const suffix_items = try sequenceToValues(suffix, alloc);
            if (suffix_items.len > arr.len) {
                try ctx.stack.push(.{ .boolean = false });
                return;
            }
            const start = arr.len - suffix_items.len;
            for (suffix_items, 0..) |s, i| {
                if (!arr[start + i].eql(s)) {
                    try ctx.stack.push(.{ .boolean = false });
                    return;
                }
            }
            try ctx.stack.push(.{ .boolean = true });
        },
        .vector => |vec| {
            const suffix_items = try sequenceToValues(suffix, alloc);
            if (suffix_items.len > vec.items.len) {
                try ctx.stack.push(.{ .boolean = false });
                return;
            }
            const start = vec.items.len - suffix_items.len;
            for (suffix_items, 0..) |s, i| {
                if (!vec.items[start + i].eql(s)) {
                    try ctx.stack.push(.{ .boolean = false });
                    return;
                }
            }
            try ctx.stack.push(.{ .boolean = true });
        },
        .byte_array => |b| {
            const suffix_items = try sequenceToValues(suffix, alloc);
            const bytes = b.slice();
            if (suffix_items.len > bytes.len) {
                try ctx.stack.push(.{ .boolean = false });
                return;
            }
            const start = bytes.len - suffix_items.len;
            for (suffix_items, 0..) |s, i| {
                if (s != .fixnum or s.fixnum < 0 or s.fixnum > 255) {
                    setErrorContext(ctx, "#ends-with? on byte-array requires fixnum elements 0-255", .{});
                    return error.TypeMismatch;
                }
                if (bytes[start + i] != @as(u8, @intCast(s.fixnum))) {
                    try ctx.stack.push(.{ .boolean = false });
                    return;
                }
            }
            try ctx.stack.push(.{ .boolean = true });
        },
        else => {
            setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
            return error.TypeMismatch;
        },
    }
}

/// #in? ( seq elem -- ? ) - Does seq contain element? (substring for strings)
fn nativeIn(ctx: *Context) anyerror!void {
    const elem = try ctx.stack.pop();
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    switch (seq) {
        .string => |s| {
            const needle = switch (elem) {
                .string => |es| es,
                else => {
                    setErrorContext(ctx, "#in? on string requires string element, got {s}", .{valueTypeName(elem)});
                    return error.TypeMismatch;
                },
            };

            const found = std.mem.indexOf(u8, s, needle) != null;
            try ctx.stack.push(.{ .boolean = found });
        },
        .array => |arr| {
            for (arr) |item| {
                if (item.eql(elem)) {
                    try ctx.stack.push(.{ .boolean = true });
                    return;
                }
            }
            try ctx.stack.push(.{ .boolean = false });
        },
        .vector => |vec| {
            for (vec.items) |item| {
                if (item.eql(elem)) {
                    try ctx.stack.push(.{ .boolean = true });
                    return;
                }
            }
            try ctx.stack.push(.{ .boolean = false });
        },
        .byte_array => |b| {
            const byte_val: u8 = switch (elem) {
                .fixnum => |i| blk: {
                    if (i < 0 or i > 255) {
                        setErrorContext(ctx, "byte value {d} out of range 0-255", .{i});
                        return error.FixnumOverflow;
                    }
                    break :blk @intCast(i);
                },
                else => {
                    setErrorContext(ctx, "#in? on byte-array requires fixnum element, got {s}", .{valueTypeName(elem)});
                    return error.TypeMismatch;
                },
            };
            const found = std.mem.indexOfScalar(u8, b.slice(), byte_val) != null;
            try ctx.stack.push(.{ .boolean = found });
        },
        .set => |set| {
            const found = set.contains(elem);
            try ctx.stack.push(.{ .boolean = found });
        },
        else => {
            var iter = SequenceIterator.init(seq, alloc) orelse {
                setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
                return error.TypeMismatch;
            };

            while (try iter.next()) |item| {
                if (item.eql(elem)) {
                    try ctx.stack.push(.{ .boolean = true });
                    return;
                }
            }

            try ctx.stack.push(.{ .boolean = false });
        },
    }
}

/// #index-of ( seq elem -- n/f ) - Index of element, or f if not found
fn nativeIndexOf(ctx: *Context) anyerror!void {
    const elem = try ctx.stack.pop();
    const seq = try ctx.stack.pop();

    switch (seq) {
        .string => |s| {
            const needle = switch (elem) {
                .string => |es| es,
                else => {
                    setErrorContext(ctx, "#index-of on string requires string element, got {s}", .{valueTypeName(elem)});
                    return error.TypeMismatch;
                },
            };
            if (std.mem.indexOf(u8, s, needle)) |byte_idx| {
                const cp_idx = sequence.utf8CodepointCount(s[0..byte_idx]);
                try ctx.stack.push(.{ .fixnum = @intCast(cp_idx) });
            } else {
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        .array => |arr| {
            for (arr, 0..) |item, idx| {
                if (item.eql(elem)) {
                    try ctx.stack.push(.{ .fixnum = @intCast(idx) });
                    return;
                }
            }
            try ctx.stack.push(.{ .boolean = false });
        },
        .vector => |vec| {
            for (vec.items, 0..) |item, idx| {
                if (item.eql(elem)) {
                    try ctx.stack.push(.{ .fixnum = @intCast(idx) });
                    return;
                }
            }
            try ctx.stack.push(.{ .boolean = false });
        },
        .byte_array => |b| {
            const byte_val: u8 = switch (elem) {
                .fixnum => |i| blk: {
                    if (i < 0 or i > 255) {
                        setErrorContext(ctx, "byte value {d} out of range 0-255", .{i});
                        return error.FixnumOverflow;
                    }
                    break :blk @intCast(i);
                },
                else => {
                    setErrorContext(ctx, "#index-of on byte-array requires fixnum element, got {s}", .{valueTypeName(elem)});
                    return error.TypeMismatch;
                },
            };
            if (simd.indexOfScalar(b.slice(), byte_val)) |idx| {
                try ctx.stack.push(.{ .fixnum = @intCast(idx) });
            } else {
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        else => {
            setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
            return error.TypeMismatch;
        },
    }
}

/// #take ( seq n -- seq' ) - First n elements
pub fn nativeTake(ctx: *Context) anyerror!void {
    const n_val = try popFixnum(ctx);
    const seq = try ctx.stack.pop();

    if (n_val < 0) {
        setErrorContext(ctx, "negative count {d}", .{n_val});
        return error.IndexOutOfBounds;
    }
    const n: usize = @intCast(n_val);
    const alloc = ctx.quotationAllocator();

    if (seq == .iterator) {
        const iter = alloc.create(Iterator) catch return error.OutOfMemory;
        iter.* = .{ .kind = .{ .take = .{ .inner = seq.iterator, .remaining = n } } };
        try ctx.stack.push(.{ .iterator = iter });
        return;
    }

    switch (seq) {
        .string => |s| {
            const cp_count = sequence.utf8CodepointCount(s);
            const take_count = @min(n, cp_count);
            if (take_count == 0) {
                try ctx.stack.push(.{ .string = "" });
                return;
            }
            const bounds = utf8SliceByCodepoints(s, 0, take_count) orelse {
                try ctx.stack.push(.{ .string = "" });
                return;
            };
            const result = alloc.dupe(u8, s[0..bounds.end_byte]) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .string = result });
        },
        .array => |arr| {
            const take_count = @min(n, arr.len);
            const result = alloc.alloc(Value, take_count) catch return error.OutOfMemory;
            @memcpy(result, arr[0..take_count]);
            try ctx.stack.push(.{ .array = result });
        },
        .vector => |vec| {
            const take_count = @min(n, vec.items.len);
            const new_vec = alloc.create(Vector) catch return error.OutOfMemory;
            new_vec.* = Vector{};
            new_vec.ensureTotalCapacity(alloc, take_count) catch return error.OutOfMemory;
            for (vec.items[0..take_count]) |item| {
                new_vec.appendAssumeCapacity(item);
            }
            try ctx.stack.push(.{ .vector = new_vec });
        },
        .byte_array => |b| {
            const bytes = b.slice();
            const take_count = @min(n, bytes.len);
            const result_ba = alloc.create(ByteArray) catch return error.OutOfMemory;
            result_ba.* = ByteArray{};
            result_ba.ensureTotalCapacity(alloc, take_count) catch return error.OutOfMemory;
            for (bytes[0..take_count]) |byte| {
                result_ba.appendAssumeCapacity(byte);
            }
            try ctx.stack.push(.{ .byte_array = result_ba });
        },
        else => {
            setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
            return error.TypeMismatch;
        },
    }
}

/// #drop ( seq n -- seq' ) - All but first n elements
pub fn nativeDrop(ctx: *Context) anyerror!void {
    const n_val = try popFixnum(ctx);
    const seq = try ctx.stack.pop();

    if (n_val < 0) {
        setErrorContext(ctx, "negative count {d}", .{n_val});
        return error.IndexOutOfBounds;
    }
    const n: usize = @intCast(n_val);
    const alloc = ctx.quotationAllocator();

    if (seq == .iterator) {
        const iter = alloc.create(Iterator) catch return error.OutOfMemory;
        iter.* = .{ .kind = .{ .drop = .{ .inner = seq.iterator, .to_skip = n } } };
        try ctx.stack.push(.{ .iterator = iter });
        return;
    }

    switch (seq) {
        .string => |s| {
            const cp_count = sequence.utf8CodepointCount(s);
            if (n >= cp_count) {
                try ctx.stack.push(.{ .string = "" });
                return;
            }
            const bounds = utf8SliceByCodepoints(s, n, cp_count) orelse {
                try ctx.stack.push(.{ .string = "" });
                return;
            };
            const result = alloc.dupe(u8, s[bounds.start_byte..bounds.end_byte]) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .string = result });
        },
        .array => |arr| {
            if (n >= arr.len) {
                try ctx.stack.push(.{ .array = &[_]Value{} });
                return;
            }
            const result = alloc.alloc(Value, arr.len - n) catch return error.OutOfMemory;
            @memcpy(result, arr[n..]);
            try ctx.stack.push(.{ .array = result });
        },
        .vector => |vec| {
            if (n >= vec.items.len) {
                const new_vec = alloc.create(Vector) catch return error.OutOfMemory;
                new_vec.* = Vector{};
                try ctx.stack.push(.{ .vector = new_vec });
                return;
            }
            const new_vec = alloc.create(Vector) catch return error.OutOfMemory;
            new_vec.* = Vector{};
            new_vec.ensureTotalCapacity(alloc, vec.items.len - n) catch return error.OutOfMemory;
            for (vec.items[n..]) |item| {
                new_vec.appendAssumeCapacity(item);
            }
            try ctx.stack.push(.{ .vector = new_vec });
        },
        .byte_array => |b| {
            const bytes = b.slice();
            if (n >= bytes.len) {
                const result_ba = alloc.create(ByteArray) catch return error.OutOfMemory;
                result_ba.* = ByteArray{};
                try ctx.stack.push(.{ .byte_array = result_ba });
                return;
            }
            const result_ba = alloc.create(ByteArray) catch return error.OutOfMemory;
            result_ba.* = ByteArray{};
            result_ba.ensureTotalCapacity(alloc, bytes.len - n) catch return error.OutOfMemory;
            for (bytes[n..]) |byte| {
                result_ba.appendAssumeCapacity(byte);
            }
            try ctx.stack.push(.{ .byte_array = result_ba });
        },
        else => {
            setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
            return error.TypeMismatch;
        },
    }
}

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "bytes-alloc", .func = nativeBytesAlloc },
    .{ .name = "#shrink!", .func = nativeShrinkMut },
    .{ .name = "#grow!", .func = nativeGrowMut },
    .{ .name = "each-index", .func = nativeEachIndex },
    .{ .name = "reduce-index", .func = nativeReduceIndex },
};

/// bytes-alloc ( n -- byte-array ) - Create a fresh zero-filled byte array of size n.
fn nativeBytesAlloc(ctx: *Context) anyerror!void {
    const n_val = try popFixnum(ctx);
    if (n_val < 0) {
        setErrorContext(ctx, "bytes-alloc size must be non-negative, got {d}", .{n_val});
        return error.IndexOutOfBounds;
    }
    const n: usize = @intCast(n_val);
    const alloc = ctx.containerAllocator();
    const ba = alloc.create(ByteArray) catch return error.OutOfMemory;
    ba.* = ByteArray{};
    if (n > 0) {
        ba.ensureTotalCapacity(alloc, n) catch return error.OutOfMemory;
        ba.items.len = n;
        @memset(ba.items[0..n], 0);
    }
    try ctx.stack.push(.{ .byte_array = ba });
}

/// #shrink! ( seq n -- seq ) - Truncate a mutable sequence to n elements.
///
/// Polymorphic on byte-array and vector.
fn nativeShrinkMut(ctx: *Context) anyerror!void {
    const n_val = try popFixnum(ctx);
    const seq = try ctx.stack.pop();

    if (n_val < 0) {
        setErrorContext(ctx, "#shrink! count must be non-negative, got {d}", .{n_val});
        return error.IndexOutOfBounds;
    }
    const n: usize = @intCast(n_val);

    switch (seq) {
        .byte_array => |ba| {
            const bytes = ba.slice();
            if (n > bytes.len) {
                setErrorContext(ctx, "#shrink! count {d} exceeds byte-array length {d}", .{ n_val, bytes.len });
                return error.IndexOutOfBounds;
            }
            switch (ba.storage) {
                .owned => {
                    ba.items.len = n;
                    ba.syncOwnedView();
                },
                .borrowed => {
                    setErrorContext(ctx, "#shrink! cannot resize borrowed byte-array", .{});
                    return error.InvalidArgument;
                },
            }
            try ctx.stack.push(.{ .byte_array = ba });
        },
        .vector => |vec| {
            if (n > vec.items.len) {
                setErrorContext(ctx, "#shrink! count {d} exceeds vector length {d}", .{ n_val, vec.items.len });
                return error.IndexOutOfBounds;
            }
            vec.items.len = n;
            try ctx.stack.push(.{ .vector = vec });
        },
        else => {
            setErrorContext(ctx, "#shrink! expected byte-array or vector, got {s}", .{valueTypeName(seq)});
            return error.TypeMismatch;
        },
    }
}

/// #grow! ( seq n fill -- seq ) - Extend a mutable sequence to n elements, filling new slots.
///
/// Polymorphic on byte-array and vector.
fn nativeGrowMut(ctx: *Context) anyerror!void {
    const fill = try ctx.stack.pop();
    const n_val = try popFixnum(ctx);
    const seq = try ctx.stack.pop();

    if (n_val < 0) {
        setErrorContext(ctx, "#grow! count must be non-negative, got {d}", .{n_val});
        return error.IndexOutOfBounds;
    }
    const n: usize = @intCast(n_val);

    switch (seq) {
        .byte_array => |ba| {
            const bytes = ba.slice();
            if (n < bytes.len) {
                setErrorContext(ctx, "#grow! count {d} is less than byte-array length {d}", .{ n_val, bytes.len });
                return error.IndexOutOfBounds;
            }
            const fill_byte: u8 = switch (fill) {
                .fixnum => |i| blk: {
                    if (i < 0 or i > 255) {
                        setErrorContext(ctx, "#grow! fill byte {d} out of range 0-255", .{i});
                        return error.FixnumOverflow;
                    }
                    break :blk @intCast(i);
                },
                else => {
                    setErrorContext(ctx, "#grow! on byte-array requires fixnum fill, got {s}", .{valueTypeName(fill)});
                    return error.TypeMismatch;
                },
            };
            switch (ba.storage) {
                .owned => {
                    const alloc = ctx.containerAllocator();
                    const old_len = ba.items.len;
                    ba.ensureTotalCapacity(alloc, n) catch return error.OutOfMemory;
                    ba.items.len = n;
                    ba.syncOwnedView();
                    @memset(ba.items[old_len..n], fill_byte);
                },
                .borrowed => {
                    setErrorContext(ctx, "#grow! cannot resize borrowed byte-array", .{});
                    return error.InvalidArgument;
                },
            }
            try ctx.stack.push(.{ .byte_array = ba });
        },
        .vector => |vec| {
            if (n < vec.items.len) {
                setErrorContext(ctx, "#grow! count {d} is less than vector length {d}", .{ n_val, vec.items.len });
                return error.IndexOutOfBounds;
            }
            const alloc = ctx.containerAllocator();
            const old_len = vec.items.len;
            vec.ensureTotalCapacity(alloc, n) catch return error.OutOfMemory;
            vec.items.len = n;
            const stored_fill = if (ctx.parent_context != null) tasks.deepCopyValue(fill, alloc) catch return error.OutOfMemory else fill;
            @memset(vec.items[old_len..n], stored_fill);
            try ctx.stack.push(.{ .vector = vec });
        },
        else => {
            setErrorContext(ctx, "#grow! expected byte-array or vector, got {s}", .{valueTypeName(seq)});
            return error.TypeMismatch;
        },
    }
}

/// freeze ( vector -- array ) - Convert a vector to an array (copy semantics)
fn nativeFreeze(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, "freeze")) return;

    const val = try ctx.stack.pop();
    switch (val) {
        .vector => |vec| {
            const alloc = ctx.quotationAllocator();
            const items = try alloc.dupe(Value, vec.items);
            try ctx.stack.push(.{ .array = items });
        },
        else => {
            setErrorContext(ctx, "freeze expected vector, got {s}", .{valueTypeName(val)});
            return error.TypeMismatch;
        },
    }
}

/// >array ( vector -- array ) - Snapshot vector items into an immutable array
fn nativeToArrayVector(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();
    const items = try alloc.dupe(Value, val.vector.items);
    try ctx.stack.push(.{ .array = items });
}

/// >array ( byte-array -- array ) - Convert each byte to a fixnum element
fn nativeToArrayByteArray(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();
    const items = try sequenceToValues(val, alloc);
    try ctx.stack.push(.{ .array = items });
}

/// >array ( set -- array ) - Convert set to array in insertion order
fn nativeToArraySet(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();
    const items = try sequenceToValues(val, alloc);
    try ctx.stack.push(.{ .array = items });
}

/// >array ( array -- array ) - Identity, no allocation
fn nativeToArrayArray(_: *Context) anyerror!void {
    // Pop and push back, an identity (value is already on the stack)
}

/// >array ( container -- array ) - Convert vector, byte-array, set, or array to an immutable array
fn nativeToArray(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, ">array")) return;
    const val = try ctx.stack.pop();
    setErrorContext(ctx, ">array expected vector, byte-array, set, or array, got {s}", .{valueTypeName(val)});
    return error.TypeMismatch;
}

fn copyByteArrayToOwned(alloc: Allocator, src: *ByteArray) !*ByteArray {
    const dst = try alloc.create(ByteArray);
    dst.* = ByteArray{};
    try dst.ensureTotalCapacity(alloc, src.slice().len);
    dst.items.len = src.slice().len;
    @memcpy(dst.items, src.slice());
    return dst;
}

fn clonePackedToOwned(ctx: *Context, tagged: TaggedPayload) !void {
    if (!std.mem.startsWith(u8, tagged.tag.name, "packed-")) {
        setErrorContext(ctx, ">byte-array expected byte-array or packed value, got {s}", .{tagged.tag.name});
        return error.TypeMismatch;
    }

    const inner_ba = switch (tagged.inner.*) {
        .byte_array => |ba| ba,
        else => {
            setErrorContext(ctx, ">byte-array expected packed value backed by byte-array", .{});
            return error.TypeMismatch;
        },
    };

    if (!inner_ba.isBorrowed()) {
        try ctx.stack.push(.{ .tagged = tagged });
        return;
    }

    const alloc = ctx.containerAllocator();
    const owned_ba = try copyByteArrayToOwned(alloc, inner_ba);
    const new_inner = try alloc.create(Value);
    new_inner.* = .{ .byte_array = owned_ba };
    try ctx.stack.push(.{
        .tagged = .{
            .tag = tagged.tag,
            .inner = new_inner,
        },
    });
}

/// >byte-array ( value -- value ) - Ensure byte-array backing storage is owned
fn nativeToByteArray(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .byte_array => |ba| {
            if (!ba.isBorrowed()) {
                try ctx.stack.push(val);
                return;
            }

            try ctx.stack.push(.{ .byte_array = try copyByteArrayToOwned(ctx.containerAllocator(), ba) });
        },
        .tagged => |tagged| try clonePackedToOwned(ctx, tagged),
        else => {
            setErrorContext(ctx, ">byte-array expected byte-array or packed value, got {s}", .{valueTypeName(val)});
            return error.TypeMismatch;
        },
    }
}

/// >hash ( mutable-map -- hash ) - Snapshot mutable-map into an immutable hash
fn nativeToHashMutableMap(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const m = val.mutable_map;
    const alloc = ctx.quotationAllocator();
    const new_hash = alloc.create(HashTable) catch return error.OutOfMemory;
    new_hash.* = HashTable{};
    var iter = m.iterator();
    while (iter.next()) |entry| {
        const key_copy = alloc.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
        new_hash.put(alloc, key_copy, entry.value_ptr.*) catch return error.OutOfMemory;
    }
    try ctx.stack.push(.{ .hash = new_hash });
}

/// >hash ( hash -- hash ) - Identity, no allocation
fn nativeToHashHash(_: *Context) anyerror!void {}

/// >hash ( container -- hash ) - Convert mutable-map or hash to an immutable hash
fn nativeToHash(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, ">hash")) return;
    const val = try ctx.stack.pop();
    setErrorContext(ctx, ">hash expected mutable-map, hash, struct, virtual, or enum, got {s}", .{valueTypeName(val)});
    return error.TypeMismatch;
}

const native_endian = builtin.target.cpu.arch.endian();

fn validateWidth(ctx: *Context, width: i64) !u3 {
    return switch (width) {
        1 => 0,
        2 => 1,
        4 => 2,
        8 => 3,
        else => {
            setErrorContext(ctx, "#peek/#poke! width must be 1, 2, 4, or 8, got {d}", .{width});
            return error.InvalidArgument;
        },
    };
}

/// #peek ( byte-array offset width -- fixnum ) - Read width bytes at offset
fn nativePeekByteArray(ctx: *Context) anyerror!void {
    const width_val = try popFixnum(ctx);
    const offset_val = try popFixnum(ctx);
    const ba_val = try ctx.stack.pop();

    const ba = ba_val.byte_array;
    const bytes = ba.slice();

    _ = try validateWidth(ctx, width_val);
    const width: usize = @intCast(width_val);

    if (offset_val < 0) {
        setErrorContext(ctx, "negative offset {d}", .{offset_val});
        return error.IndexOutOfBounds;
    }
    const offset: usize = @intCast(offset_val);

    if (offset + width > bytes.len) {
        setErrorContext(ctx, "offset {d} + width {d} exceeds byte-array length {d}", .{ offset, width, bytes.len });
        return error.IndexOutOfBounds;
    }

    const slice = bytes[offset..];
    switch (width) {
        1 => try ctx.stack.push(.{ .fixnum = slice[0] }),
        2 => {
            const val = std.mem.readInt(u16, slice[0..2], native_endian);
            try ctx.stack.push(.{ .fixnum = val });
        },
        4 => {
            const val = std.mem.readInt(u32, slice[0..4], native_endian);
            try ctx.stack.push(.{ .fixnum = val });
        },
        8 => {
            const bits = std.mem.readInt(u64, slice[0..8], native_endian);
            if (bits <= std.math.maxInt(i64)) {
                try ctx.stack.push(.{ .fixnum = @intCast(bits) });
            } else {
                const alloc = ctx.arena.allocator();
                const big = try BigIntManaged.initSet(alloc, bits);
                try ctx.stack.push(.{ .bignum = big });
            }
        },
        else => unreachable,
    }
}

/// #poke! ( byte-array offset value width -- byte-array ) - Write value at offset
fn nativePokeByteArray(ctx: *Context) anyerror!void {
    const width_val = try popFixnum(ctx);
    const value = try ctx.stack.pop();
    const offset_val = try popFixnum(ctx);
    const ba_val = try ctx.stack.pop();

    const ba = ba_val.byte_array;
    const bytes = ba.slice();

    _ = try validateWidth(ctx, width_val);
    const width: usize = @intCast(width_val);

    if (offset_val < 0) {
        setErrorContext(ctx, "negative offset {d}", .{offset_val});
        return error.IndexOutOfBounds;
    }
    const offset: usize = @intCast(offset_val);

    if (offset + width > bytes.len) {
        setErrorContext(ctx, "offset {d} + width {d} exceeds byte-array length {d}", .{ offset, width, bytes.len });
        return error.IndexOutOfBounds;
    }

    // For width 8, any u64 is valid; for smaller widths, check range.
    const max_val: u64 = if (width == 8) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(width * 8)) - 1;

    const bits: u64 = switch (value) {
        .fixnum => |i| blk: {
            if (i < 0) {
                setErrorContext(ctx, "#poke! value must be non-negative, got {d}", .{i});
                return error.FixnumOverflow;
            }
            const u: u64 = @intCast(i);
            if (u > max_val) {
                setErrorContext(ctx, "#poke! value {d} exceeds range for width {d} (max {d})", .{ u, width, max_val });
                return error.FixnumOverflow;
            }
            break :blk u;
        },
        .bignum => |b| blk: {
            if (!b.fits(u64)) {
                setErrorContext(ctx, "#poke! value exceeds range for width {d}", .{width});
                return error.FixnumOverflow;
            }
            const u = b.toInt(u64) catch unreachable;
            if (u > max_val) {
                setErrorContext(ctx, "#poke! value {d} exceeds range for width {d} (max {d})", .{ u, width, max_val });
                return error.FixnumOverflow;
            }
            break :blk u;
        },
        else => {
            setErrorContext(ctx, "#poke! expected fixnum or bignum value, got {s}", .{valueTypeName(value)});
            return error.TypeMismatch;
        },
    };

    const slice = bytes[offset..];
    switch (width) {
        1 => slice[0] = @intCast(bits),
        2 => std.mem.writeInt(u16, slice[0..2], @intCast(bits), native_endian),
        4 => std.mem.writeInt(u32, slice[0..4], @intCast(bits), native_endian),
        8 => std.mem.writeInt(u64, slice[0..8], bits, native_endian),
        else => unreachable,
    }

    try ctx.stack.push(.{ .byte_array = ba });
}

/// #peek ( byte-array offset width -- fixnum ) - Entry point with dispatch
fn nativePeek(ctx: *Context) anyerror!void {
    // dispatch: byte-array is at stack depth 2 (below offset and width)
    if (ctx.stack.depth() >= 3) {
        const seq_peek = try ctx.stack.peekN(2);
        const a_type = dispatch_mod.dispatchDescriptor(seq_peek, ctx);
        if (ctx.resolveDispatchId("#peek")) |did| {
            if (ctx.lookupUnaryDispatch(did, a_type)) |entry| {
                try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                return;
            }
            if (dispatch_mod.dispatchEnumTypeValue(seq_peek)) |ae| {
                if (ctx.lookupUnaryDispatch(did, ae.descriptor.?)) |entry| {
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
            if (dispatch_mod.dispatchBaseTypeValue(seq_peek)) |bt| {
                if (ctx.lookupUnaryDispatch(did, bt.descriptor.?)) |entry| {
                    const len = ctx.stack.items.items.len;
                    ctx.stack.items.items[len - 3] = seq_peek.tagged.inner.*;
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
        }

        if (seq_peek == .byte_array) return nativePeekByteArray(ctx);
    }

    const val = try ctx.stack.pop();
    _ = val;
    const val2 = try ctx.stack.pop();
    _ = val2;
    const val3 = try ctx.stack.pop();
    setErrorContext(ctx, "#peek expected byte-array, got {s}", .{valueTypeName(val3)});
    return error.TypeMismatch;
}

/// #poke! ( byte-array offset value width -- byte-array ) - Entry point with dispatch
fn nativePoke(ctx: *Context) anyerror!void {
    // dispatch: byte-array is at stack depth 3 (below offset, value, and width)
    if (ctx.stack.depth() >= 4) {
        const seq_peek = try ctx.stack.peekN(3);
        const a_type = dispatch_mod.dispatchDescriptor(seq_peek, ctx);
        if (ctx.resolveDispatchId("#poke!")) |did| {
            if (ctx.lookupUnaryDispatch(did, a_type)) |entry| {
                try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                return;
            }
            if (dispatch_mod.dispatchEnumTypeValue(seq_peek)) |ae| {
                if (ctx.lookupUnaryDispatch(did, ae.descriptor.?)) |entry| {
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
            if (dispatch_mod.dispatchBaseTypeValue(seq_peek)) |bt| {
                if (ctx.lookupUnaryDispatch(did, bt.descriptor.?)) |entry| {
                    const len = ctx.stack.items.items.len;
                    ctx.stack.items.items[len - 4] = seq_peek.tagged.inner.*;
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
        }

        if (seq_peek == .byte_array) return nativePokeByteArray(ctx);
    }

    const val = try ctx.stack.pop();
    _ = val;
    const val2 = try ctx.stack.pop();
    _ = val2;
    const val3 = try ctx.stack.pop();
    _ = val3;
    const val4 = try ctx.stack.pop();
    setErrorContext(ctx, "#poke! expected byte-array, got {s}", .{valueTypeName(val4)});
    return error.TypeMismatch;
}

test "borrowed byte-array #nth! allows element writes" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var backing = [_]u8{ 10, 20, 30 };
    var ba = ByteArray{
        .items = backing[0..],
        .storage = .{ .borrowed = backing[0..] },
    };

    try ctx.stack.push(.{ .byte_array = &ba });
    try ctx.stack.push(.{ .fixnum = 1 });
    try ctx.stack.push(.{ .fixnum = 99 });

    try nativeNthMut(&ctx);

    try std.testing.expectEqual(@as(u8, 99), backing[1]);
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const result = try ctx.stack.pop();
    try std.testing.expect(result == .byte_array);
    try std.testing.expect(result.byte_array == &ba);
}

test "borrowed byte-array #poke! allows element writes" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var backing = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    var ba = ByteArray{
        .items = backing[0..],
        .storage = .{ .borrowed = backing[0..] },
    };

    try ctx.stack.push(.{ .byte_array = &ba });
    try ctx.stack.push(.{ .fixnum = 1 });
    try ctx.stack.push(.{ .fixnum = 0xABCD });
    try ctx.stack.push(.{ .fixnum = 2 });

    try nativePokeByteArray(&ctx);

    try std.testing.expectEqual(@as(u8, 0xCD), backing[1]);
    try std.testing.expectEqual(@as(u8, 0xAB), backing[2]);
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const result = try ctx.stack.pop();
    try std.testing.expect(result == .byte_array);
    try std.testing.expect(result.byte_array == &ba);
}

test "borrowed byte-array structural mutations are rejected" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var backing = [_]u8{ 1, 2, 3 };
    var ba = ByteArray{
        .items = backing[0..],
        .storage = .{ .borrowed = backing[0..] },
    };

    try ctx.stack.push(.{ .byte_array = &ba });
    try ctx.stack.push(.{ .fixnum = 2 });
    try std.testing.expectError(error.InvalidArgument, nativeShrinkMut(&ctx));
    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
    try std.testing.expectEqual(@as(usize, 3), backing.len);

    try ctx.stack.push(.{ .byte_array = &ba });
    try ctx.stack.push(.{ .fixnum = 5 });
    try ctx.stack.push(.{ .fixnum = 0 });
    try std.testing.expectError(error.InvalidArgument, nativeGrowMut(&ctx));
    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
    try std.testing.expectEqual(@as(usize, 3), ba.slice().len);
}

test ">byte-array on owned byte-array is a no-op" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var items = [_]u8{ 1, 2, 3 };
    var ba = ByteArray{
        .items = items[0..],
        .owned_items = .{ .items = items[0..], .capacity = items.len },
        .storage = .owned,
    };

    try ctx.stack.push(.{ .byte_array = &ba });
    try nativeToByteArray(&ctx);

    const result = try ctx.stack.pop();
    try std.testing.expect(result == .byte_array);
    try std.testing.expect(result.byte_array == &ba);
}

test ">byte-array copies borrowed byte-array to owned storage" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var items = [_]u8{ 9, 8, 7 };
    var ba = ByteArray{
        .items = items[0..],
        .storage = .{ .borrowed = items[0..] },
    };

    try ctx.stack.push(.{ .byte_array = &ba });
    try nativeToByteArray(&ctx);

    const result = try ctx.stack.pop();
    try std.testing.expect(result == .byte_array);
    try std.testing.expect(result.byte_array != &ba);
    try std.testing.expect(!result.byte_array.isBorrowed());
    try std.testing.expectEqualSlices(u8, items[0..], result.byte_array.slice());
}

test ">byte-array copies borrowed packed backing and preserves tag" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var items = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    var ba = ByteArray{
        .items = items[0..],
        .storage = .{ .borrowed = items[0..] },
    };
    const inner = Value{ .byte_array = &ba };
    const packed_type = value_mod.VirtualType{
        .name = "packed-u8",
        .inner_type = "byte-array",
    };

    try ctx.stack.push(.{
        .tagged = .{
            .tag = &packed_type,
            .inner = &inner,
        },
    });
    try nativeToByteArray(&ctx);

    const result = try ctx.stack.pop();
    try std.testing.expect(result == .tagged);
    try std.testing.expect(result.tagged.tag == &packed_type);
    try std.testing.expect(result.tagged.inner.* == .byte_array);
    try std.testing.expect(!result.tagged.inner.*.byte_array.isBorrowed());
    try std.testing.expectEqualSlices(u8, items[0..], result.tagged.inner.*.byte_array.slice());
}

test ">byte-array rejects unrelated values" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .fixnum = 42 });
    try std.testing.expectError(error.TypeMismatch, nativeToByteArray(&ctx));
}
