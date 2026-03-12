const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Vector = value_mod.Vector;
const ByteArray = value_mod.ByteArray;

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;
const helpers = @import("helpers.zig");
const dispatch_helpers = @import("dispatch_helpers.zig");
const dispatch_mod = @import("../dispatch.zig");
const DispatchTable = dispatch_mod.DispatchTable;
const unary_sentinel = dispatch_mod.unary_sentinel;
const sequence = @import("sequence.zig");
const Iterator = @import("../iterator.zig").Iterator;

const popFixnum = helpers.popFixnum;
const popBoolean = helpers.popBoolean;
const popQuotation = helpers.popQuotation;
const popVector = helpers.popVector;
const popByteArray = helpers.popByteArray;
const setErrorContext = helpers.setErrorContext;
const valueTypeName = helpers.valueTypeName;

const Allocator = std.mem.Allocator;

/// Convert a sequence value to an ArrayIter. Returns null if the value is not
/// a recognized sequence type. For arrays, wraps directly; for other types
/// (string, vector, byte-array, set), materializes to a values array first.
fn seqToArrayIter(seq: Value, alloc: Allocator) !?*Iterator {
    const items: []const Value = switch (seq) {
        .array => |arr| arr,
        .string, .vector, .byte_array, .set => try sequenceToValues(seq, alloc),
        else => return null,
    };
    const iter = try alloc.create(Iterator);
    iter.* = .{ .kind = .{ .array = .{ .items = items, .index = 0 } } };
    return iter;
}

const arithmetic = @import("arithmetic.zig");

/// Materialize any iterable to a mutable []Value for in-place sorting.
fn collectToMutableArray(seq: Value, ctx: *Context, alloc: Allocator) ![]Value {
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
    try ctx.stack.push(.{ .fixnum = @intCast(val.byte_array.items.len) });
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
    if (idx >= ba.items.len) {
        setErrorContext(ctx, "index {d} out of bounds for byte-array of length {d}", .{ idx, ba.items.len });
        return error.IndexOutOfBounds;
    }
    try ctx.stack.push(.{ .fixnum = ba.items[idx] });
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
    if (b.items.len == 0) {
        setErrorContext(ctx, "empty byte-array", .{});
        return error.EmptySequence;
    }
    try ctx.stack.push(.{ .fixnum = b.items[0] });
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
    if (b.items.len == 0) {
        setErrorContext(ctx, "empty byte-array", .{});
        return error.EmptySequence;
    }
    try ctx.stack.push(.{ .fixnum = b.items[b.items.len - 1] });
}

// =============================================================================
// Registration of all native dispatch entries
// =============================================================================

pub fn registerNativeDispatch(dispatch: *DispatchTable) !void {
    // #len : 8 unary entries
    try dispatch.registerNative("#len", "string", unary_sentinel, nativeLenString);
    try dispatch.registerNative("#len", "array", unary_sentinel, nativeLenArray);
    try dispatch.registerNative("#len", "vector", unary_sentinel, nativeLenVector);
    try dispatch.registerNative("#len", "byte-array", unary_sentinel, nativeLenByteArray);
    try dispatch.registerNative("#len", "set", unary_sentinel, nativeLenSet);
    try dispatch.registerNative("#len", "hash", unary_sentinel, nativeLenHash);
    try dispatch.registerNative("#len", "mutable-map", unary_sentinel, nativeLenMutableMap);
    try dispatch.registerNative("#len", "module", unary_sentinel, nativeLenModule);

    // #nth : 4 binary entries (all with type_b = fixnum)
    try dispatch.registerNative("#nth", "string", "fixnum", nativeNthString);
    try dispatch.registerNative("#nth", "array", "fixnum", nativeNthArray);
    try dispatch.registerNative("#nth", "vector", "fixnum", nativeNthVector);
    try dispatch.registerNative("#nth", "byte-array", "fixnum", nativeNthByteArray);

    // #first : 4 unary entries
    try dispatch.registerNative("#first", "string", unary_sentinel, nativeFirstString);
    try dispatch.registerNative("#first", "array", unary_sentinel, nativeFirstArray);
    try dispatch.registerNative("#first", "vector", unary_sentinel, nativeFirstVector);
    try dispatch.registerNative("#first", "byte-array", unary_sentinel, nativeFirstByteArray);

    // #last : 4 unary entries
    try dispatch.registerNative("#last", "string", unary_sentinel, nativeLastString);
    try dispatch.registerNative("#last", "array", unary_sentinel, nativeLastArray);
    try dispatch.registerNative("#last", "vector", unary_sentinel, nativeLastVector);
    try dispatch.registerNative("#last", "byte-array", unary_sentinel, nativeLastByteArray);
}

pub const primitives = [_]Primitive{
    // Sequence length
    .{
        .name = "#len",
        .stack_effect = "seq -- n",
        .doc = "Get length of sequence. O(1) and non-destructive; does not work on iterators (use #count instead).",
        .func = nativeLen,
    },
    // Sequence element access
    .{ .name = "#nth", .stack_effect = "seq n -- elem", .doc = "Get element at index.", .func = nativeNth },
    .{ .name = "#first", .stack_effect = "seq -- elem", .doc = "Get first element of sequence.", .func = nativeFirst },
    .{ .name = "#last", .stack_effect = "seq -- elem", .doc = "Get last element of sequence.", .func = nativeLast },
    // Sequence transformations
    .{ .name = "#each", .stack_effect = "seq quot: ( elem -- ) --", .doc = "Execute quotation for each element of sequence.", .func = nativeEach },
    .{ .name = "#map", .stack_effect = "seq quot: ( elem -- elem' ) -- seq'", .doc = "Transform each element of sequence using quotation.", .func = nativeMap },
    .{ .name = "#filter", .stack_effect = "seq quot: ( elem -- ? ) -- seq'", .doc = "Keep elements where quotation returns true.", .func = nativeFilter },
    .{ .name = "#reduce", .stack_effect = "seq init quot: ( acc elem -- acc' ) -- value", .doc = "Fold sequence with accumulator.", .func = nativeReduce },
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
    // Dispatch for custom types: seq is at position 2 (below n and value)
    if (ctx.stack.depth() >= 3) {
        const seq_peek = try ctx.stack.peekN(2);
        const a_type = dispatch_mod.dispatchTypeName(seq_peek);
        if (ctx.lookupUnaryDispatch("#nth!", a_type)) |entry| {
            try dispatch_helpers.executeDispatchBody(ctx, entry.body);
            return;
        }
        if (dispatch_mod.dispatchEnumName(seq_peek)) |ae| {
            if (ctx.lookupUnaryDispatch("#nth!", ae)) |entry| {
                try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                return;
            }
        }
    }

    const value = try ctx.stack.pop();
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
            v.items[idx] = value;
            try ctx.stack.push(.{ .vector = v });
        },
        .byte_array => |b| {
            if (idx >= b.items.len) {
                setErrorContext(ctx, "index {d} out of bounds for byte-array of length {d}", .{ idx, b.items.len });
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
            b.items[idx] = byte_val;
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
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    if (seq == .iterator) {
        while (try seq.iterator.next(ctx)) |elem| {
            try ctx.stack.push(elem);
            try ctx.executeQuotationWithFrame(quot);
        }
        return;
    }

    var iter = SequenceIterator.init(seq, alloc) orelse {
        setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
        return error.TypeMismatch;
    };
    while (try iter.next()) |elem| {
        try ctx.stack.push(elem);
        try ctx.executeQuotationWithFrame(quot);
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
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

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
            if (end > b.items.len) {
                setErrorContext(ctx, "slice [{}:{}] out of bounds for byte-array of length {}", .{ start, end, b.items.len });
                return error.IndexOutOfBounds;
            }
            const slice_len = end - start;
            const result_ba = alloc.create(ByteArray) catch return error.OutOfMemory;
            result_ba.* = ByteArray{};
            result_ba.ensureTotalCapacity(alloc, slice_len) catch return error.OutOfMemory;
            for (b.items[start..end]) |byte| {
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
            result_ba.ensureTotalCapacity(alloc, b1.items.len + extra_len) catch return error.OutOfMemory;
            for (b1.items) |byte| {
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
    const seq = try ctx.stack.pop();
    const vec = try popVector(ctx);
    const alloc = ctx.quotationAllocator();

    const items = try sequenceToValues(seq, alloc);
    for (items) |elem| {
        vec.append(alloc, elem) catch return error.OutOfMemory;
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
            result_ba.ensureTotalCapacity(alloc, extra_len + b1.items.len) catch return error.OutOfMemory;
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

            for (b1.items) |byte| {
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
            result_ba.ensureTotalCapacity(alloc, b.items.len + 1) catch return error.OutOfMemory;
            for (b.items) |byte| {
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
            if (b.items.len == 0) {
                setErrorContext(ctx, "cannot #pop from empty byte-array", .{});
                return error.EmptySequence;
            }
            const last_byte = b.items[b.items.len - 1];
            const result_ba = alloc.create(ByteArray) catch return error.OutOfMemory;
            result_ba.* = ByteArray{};
            result_ba.ensureTotalCapacity(alloc, b.items.len - 1) catch return error.OutOfMemory;
            for (b.items[0 .. b.items.len - 1]) |byte| {
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
            result_ba.ensureTotalCapacity(alloc, b.items.len + 1) catch return error.OutOfMemory;
            result_ba.appendAssumeCapacity(byte_val);
            for (b.items) |byte| {
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
            if (b.items.len == 0) {
                setErrorContext(ctx, "cannot #shift from empty byte-array", .{});
                return error.EmptySequence;
            }
            const first_byte = b.items[0];
            const result_ba = alloc.create(ByteArray) catch return error.OutOfMemory;
            result_ba.* = ByteArray{};
            result_ba.ensureTotalCapacity(alloc, b.items.len - 1) catch return error.OutOfMemory;
            for (b.items[1..]) |byte| {
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
    const elem = try ctx.stack.pop();
    const vec = try popVector(ctx);
    const alloc = ctx.quotationAllocator();

    vec.append(alloc, elem) catch return error.OutOfMemory;
    try ctx.stack.push(.{ .vector = vec });
}

/// #pop! ( vec -- vec elem ) - Mutate vec to remove last element from vector
fn nativePopMut(ctx: *Context) anyerror!void {
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
    const elem = try ctx.stack.pop();
    const vec = try popVector(ctx);
    const alloc = ctx.quotationAllocator();

    vec.insert(alloc, 0, elem) catch return error.OutOfMemory;
    try ctx.stack.push(.{ .vector = vec });
}

/// #shift! ( vec -- vec elem ) - Mutate vec to remove first element
fn nativeShiftMut(ctx: *Context) anyerror!void {
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
            if (prefix_items.len > b.items.len) {
                try ctx.stack.push(.{ .boolean = false });
                return;
            }
            for (prefix_items, 0..) |p, i| {
                if (p != .fixnum or p.fixnum < 0 or p.fixnum > 255) {
                    setErrorContext(ctx, "#starts-with? on byte-array requires fixnum elements 0-255", .{});
                    return error.TypeMismatch;
                }
                if (b.items[i] != @as(u8, @intCast(p.fixnum))) {
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
            if (suffix_items.len > b.items.len) {
                try ctx.stack.push(.{ .boolean = false });
                return;
            }
            const start = b.items.len - suffix_items.len;
            for (suffix_items, 0..) |s, i| {
                if (s != .fixnum or s.fixnum < 0 or s.fixnum > 255) {
                    setErrorContext(ctx, "#ends-with? on byte-array requires fixnum elements 0-255", .{});
                    return error.TypeMismatch;
                }
                if (b.items[start + i] != @as(u8, @intCast(s.fixnum))) {
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
            const found = std.mem.indexOfScalar(u8, b.items, byte_val) != null;
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
            if (std.mem.indexOfScalar(u8, b.items, byte_val)) |idx| {
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
fn nativeTake(ctx: *Context) anyerror!void {
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
            const take_count = @min(n, b.items.len);
            const result_ba = alloc.create(ByteArray) catch return error.OutOfMemory;
            result_ba.* = ByteArray{};
            result_ba.ensureTotalCapacity(alloc, take_count) catch return error.OutOfMemory;
            for (b.items[0..take_count]) |byte| {
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
fn nativeDrop(ctx: *Context) anyerror!void {
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
            if (n >= b.items.len) {
                const result_ba = alloc.create(ByteArray) catch return error.OutOfMemory;
                result_ba.* = ByteArray{};
                try ctx.stack.push(.{ .byte_array = result_ba });
                return;
            }
            const result_ba = alloc.create(ByteArray) catch return error.OutOfMemory;
            result_ba.* = ByteArray{};
            result_ba.ensureTotalCapacity(alloc, b.items.len - n) catch return error.OutOfMemory;
            for (b.items[n..]) |byte| {
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
};

/// bytes-alloc ( n -- byte-array ) - Create a fresh zero-filled byte array of size n.
fn nativeBytesAlloc(ctx: *Context) anyerror!void {
    const n_val = try popFixnum(ctx);
    if (n_val < 0) {
        setErrorContext(ctx, "bytes-alloc size must be non-negative, got {d}", .{n_val});
        return error.IndexOutOfBounds;
    }
    const n: usize = @intCast(n_val);
    const alloc = ctx.quotationAllocator();
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
            if (n > ba.items.len) {
                setErrorContext(ctx, "#shrink! count {d} exceeds byte-array length {d}", .{ n_val, ba.items.len });
                return error.IndexOutOfBounds;
            }
            ba.items.len = n;
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
            if (n < ba.items.len) {
                setErrorContext(ctx, "#grow! count {d} is less than byte-array length {d}", .{ n_val, ba.items.len });
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
            const alloc = ctx.quotationAllocator();
            const old_len = ba.items.len;
            ba.ensureTotalCapacity(alloc, n) catch return error.OutOfMemory;
            ba.items.len = n;
            @memset(ba.items[old_len..n], fill_byte);
            try ctx.stack.push(.{ .byte_array = ba });
        },
        .vector => |vec| {
            if (n < vec.items.len) {
                setErrorContext(ctx, "#grow! count {d} is less than vector length {d}", .{ n_val, vec.items.len });
                return error.IndexOutOfBounds;
            }
            const alloc = ctx.quotationAllocator();
            const old_len = vec.items.len;
            vec.ensureTotalCapacity(alloc, n) catch return error.OutOfMemory;
            vec.items.len = n;
            @memset(vec.items[old_len..n], fill);
            try ctx.stack.push(.{ .vector = vec });
        },
        else => {
            setErrorContext(ctx, "#grow! expected byte-array or vector, got {s}", .{valueTypeName(seq)});
            return error.TypeMismatch;
        },
    }
}
