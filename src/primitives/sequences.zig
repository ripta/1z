const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Vector = value_mod.Vector;
const ByteArray = value_mod.ByteArray;

const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");
const sequence = @import("sequence.zig");
const Iterator = @import("../iterator.zig").Iterator;

const popInteger = helpers.popInteger;
const popBoolean = helpers.popBoolean;
const popQuotation = helpers.popQuotation;
const popVector = helpers.popVector;
const setErrorContext = helpers.setErrorContext;
const valueTypeName = helpers.valueTypeName;

const SequenceIterator = sequence.SequenceIterator;
const SequenceBuilder = sequence.SequenceBuilder;
const SequenceKind = sequence.SequenceKind;
const sequenceLength = sequence.sequenceLength;
const classifySequence = sequence.classifySequence;
const sequenceToValues = sequence.sequenceToValues;
const utf8NthCodepoint = sequence.utf8NthCodepoint;
const utf8SliceByCodepoints = sequence.utf8SliceByCodepoints;

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
    // Sequence concatenation
    .{ .name = "#append", .stack_effect = "seq1 seq2 -- seq", .doc = "Concatenate seq2 to seq1, returning new sequence of seq1's type.", .func = nativeAppend },
    .{ .name = "#append!", .stack_effect = "vec seq -- vec", .doc = "Mutably append sequence elements to vector.", .func = nativeAppendMut },
    .{ .name = "#prepend", .stack_effect = "seq1 seq2 -- seq", .doc = "Prepend seq2's elements before seq1, returning new sequence of seq1's type.", .func = nativePrepend },
    // Sequence element addition/removal
    .{ .name = "#push", .stack_effect = "seq elem -- seq'", .doc = "Add element to end of sequence, returns new sequence.", .func = nativePush },
    .{ .name = "#pop", .stack_effect = "seq -- seq' elem", .doc = "Remove last element, return both sequence and element.", .func = nativePop },
    .{ .name = "#unshift", .stack_effect = "seq elem -- seq'", .doc = "Add element to start of sequence, returns new sequence.", .func = nativeUnshift },
    .{ .name = "#shift", .stack_effect = "seq -- seq' elem", .doc = "Remove first element, return both truncated sequence and element.", .func = nativeShift },
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
    const val = try ctx.stack.pop();
    // Use sequence module for standard sequences, handle associative types separately
    const len: i64 = if (sequenceLength(val)) |l|
        @intCast(l)
    else if (val == .hash)
        @intCast(val.hash.count())
    else if (val == .mutable_map)
        @intCast(val.mutable_map.count())
    else if (val == .module)
        @intCast(val.module.words.count())
    else {
        setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(val)});
        return error.TypeMismatch;
    };
    try ctx.stack.push(.{ .integer = len });
}

/// #nth ( seq n -- elem ) - Get element at index
pub fn nativeNth(ctx: *Context) anyerror!void {
    const index = try popInteger(ctx);
    const val = try ctx.stack.pop();

    if (index < 0) {
        setErrorContext(ctx, "negative index {d}", .{index});
        return error.IndexOutOfBounds;
    }
    const idx: usize = @intCast(index);

    switch (val) {
        .string => |s| {
            const cp_slice = utf8NthCodepoint(s, idx) orelse {
                const slen = std.unicode.utf8CountCodepoints(s) catch s.len;
                setErrorContext(ctx, "index {d} out of bounds for string of length {d}", .{ idx, slen });
                return error.IndexOutOfBounds;
            };
            const result = ctx.quotationAllocator().dupe(u8, cp_slice) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .string = result });
        },
        .array => |a| {
            if (idx >= a.len) {
                setErrorContext(ctx, "index {d} out of bounds for array of length {d}", .{ idx, a.len });
                return error.IndexOutOfBounds;
            }
            try ctx.stack.push(a[idx]);
        },
        .vector => |v| {
            if (idx >= v.items.len) {
                setErrorContext(ctx, "index {d} out of bounds for vector of length {d}", .{ idx, v.items.len });
                return error.IndexOutOfBounds;
            }
            try ctx.stack.push(v.items[idx]);
        },
        .byte_array => |b| {
            if (idx >= b.items.len) {
                setErrorContext(ctx, "index {d} out of bounds for byte-array of length {d}", .{ idx, b.items.len });
                return error.IndexOutOfBounds;
            }
            try ctx.stack.push(.{ .integer = b.items[idx] });
        },
        else => {
            setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(val)});
            return error.TypeMismatch;
        },
    }
}

/// #first ( seq -- elem ) - Get first element
pub fn nativeFirst(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    // Sets are not supported for positional access (unordered)
    if (val == .set) {
        setErrorContext(ctx, "sets do not support positional access", .{});
        return error.TypeMismatch;
    }

    var iter = SequenceIterator.init(val, alloc) orelse {
        setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(val)});
        return error.TypeMismatch;
    };
    const first = try iter.next() orelse {
        setErrorContext(ctx, "empty {s}", .{valueTypeName(val)});
        return error.EmptySequence;
    };
    try ctx.stack.push(first);
}

/// #last ( seq -- elem ) - Get last element
pub fn nativeLast(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    // Sets are not supported for positional access (unordered)
    if (val == .set) {
        setErrorContext(ctx, "sets do not support positional access", .{});
        return error.TypeMismatch;
    }

    var iter = SequenceIterator.init(val, alloc) orelse {
        setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(val)});
        return error.TypeMismatch;
    };
    var last: ?Value = null;
    while (try iter.next()) |elem| {
        last = elem;
    }
    try ctx.stack.push(last orelse {
        setErrorContext(ctx, "empty {s}", .{valueTypeName(val)});
        return error.EmptySequence;
    });
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

/// #map ( seq quot -- seq' ) - Transform each element of sequence
///
/// Iterators are lazily mapped instead of materialized.
/// Both string and byte_array map to array.
/// Anything else preserve type.
pub fn nativeMap(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    if (seq == .iterator) {
        const iter = alloc.create(Iterator) catch return error.OutOfMemory;
        iter.* = .{ .kind = .{ .map = .{ .inner = seq.iterator, .quotation = quot } } };
        try ctx.stack.push(.{ .iterator = iter });
        return;
    }

    const input_kind = classifySequence(seq) orelse {
        setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
        return error.TypeMismatch;
    };
    const output_kind: SequenceKind = switch (input_kind) {
        .string, .byte_array => .array,
        else => input_kind,
    };

    const len = sequenceLength(seq) orelse {
        setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
        return error.TypeMismatch;
    };
    var iter = SequenceIterator.init(seq, alloc) orelse {
        setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
        return error.TypeMismatch;
    };
    var builder = try SequenceBuilder.initWithCapacity(output_kind, alloc, len);

    while (try iter.next()) |elem| {
        try ctx.stack.push(elem);
        try ctx.executeQuotationWithFrame(quot);
        const mapped = try ctx.stack.pop();
        try builder.append(mapped);
    }

    try ctx.stack.push(try builder.toValue());
}

/// #filter ( seq quot -- seq' ) - Keep elements where quotation returns true
///
/// Iterators are lazily filtered instead of materialized.
pub fn nativeFilter(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    if (seq == .iterator) {
        const iter = alloc.create(Iterator) catch return error.OutOfMemory;
        iter.* = .{ .kind = .{ .filter = .{ .inner = seq.iterator, .quotation = quot } } };
        try ctx.stack.push(.{ .iterator = iter });
        return;
    }

    const kind = classifySequence(seq) orelse {
        setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
        return error.TypeMismatch;
    };
    var iter = SequenceIterator.init(seq, alloc) orelse {
        setErrorContext(ctx, "expected sequence, got {s}", .{valueTypeName(seq)});
        return error.TypeMismatch;
    };
    var builder = try SequenceBuilder.init(kind, alloc);

    while (try iter.next()) |elem| {
        try ctx.stack.push(elem);
        try ctx.executeQuotationWithFrame(quot);
        const predicate = try popBoolean(ctx);
        if (predicate) {
            try builder.append(elem);
        }
    }

    try ctx.stack.push(try builder.toValue());
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
    const end_val = try popInteger(ctx);
    const start_val = try popInteger(ctx);
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
                    .integer => |i| {
                        if (i < 0 or i > 255) {
                            setErrorContext(ctx, "byte value {d} out of range 0-255", .{i});
                            return error.IntegerOverflow;
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
                    .integer => |i| {
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
                    .integer => |i| {
                        if (i < 0 or i > 255) {
                            setErrorContext(ctx, "byte value {d} out of range 0-255", .{i});
                            return error.IntegerOverflow;
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
                    .integer => |i| {
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
                    .integer => |i| {
                        if (i < 0 or i > 255) {
                            setErrorContext(ctx, "byte value {d} out of range 0-255", .{i});
                            return error.IntegerOverflow;
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
                    .integer => |i| {
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
                    .integer => |i| {
                        if (i < 0 or i > 255) {
                            setErrorContext(ctx, "byte value {d} out of range 0-255", .{i});
                            return error.IntegerOverflow;
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
                    .integer => |i| {
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
            // Element must be an integer 0-255
            const byte_val: u8 = switch (elem) {
                .integer => |i| blk: {
                    if (i < 0 or i > 255) {
                        setErrorContext(ctx, "byte value {d} out of range 0-255", .{i});
                        return error.IntegerOverflow;
                    }
                    break :blk @intCast(i);
                },
                else => {
                    setErrorContext(ctx, "#push on byte-array requires integer element, got {s}", .{valueTypeName(elem)});
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
            try ctx.stack.push(.{ .integer = last_byte });
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
                .integer => |i| blk: {
                    if (i < 0 or i > 255) {
                        setErrorContext(ctx, "byte value {d} out of range 0-255", .{i});
                        return error.IntegerOverflow;
                    }
                    break :blk @intCast(i);
                },
                else => {
                    setErrorContext(ctx, "#unshift on byte-array requires integer element, got {s}", .{valueTypeName(elem)});
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
            try ctx.stack.push(.{ .integer = first_byte });
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
                if (p != .integer or p.integer < 0 or p.integer > 255) {
                    setErrorContext(ctx, "#starts-with? on byte-array requires integer elements 0-255", .{});
                    return error.TypeMismatch;
                }
                if (b.items[i] != @as(u8, @intCast(p.integer))) {
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
                if (s != .integer or s.integer < 0 or s.integer > 255) {
                    setErrorContext(ctx, "#ends-with? on byte-array requires integer elements 0-255", .{});
                    return error.TypeMismatch;
                }
                if (b.items[start + i] != @as(u8, @intCast(s.integer))) {
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
                .integer => |i| blk: {
                    if (i < 0 or i > 255) {
                        setErrorContext(ctx, "byte value {d} out of range 0-255", .{i});
                        return error.IntegerOverflow;
                    }
                    break :blk @intCast(i);
                },
                else => {
                    setErrorContext(ctx, "#in? on byte-array requires integer element, got {s}", .{valueTypeName(elem)});
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
                try ctx.stack.push(.{ .integer = @intCast(cp_idx) });
            } else {
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        .array => |arr| {
            for (arr, 0..) |item, idx| {
                if (item.eql(elem)) {
                    try ctx.stack.push(.{ .integer = @intCast(idx) });
                    return;
                }
            }
            try ctx.stack.push(.{ .boolean = false });
        },
        .vector => |vec| {
            for (vec.items, 0..) |item, idx| {
                if (item.eql(elem)) {
                    try ctx.stack.push(.{ .integer = @intCast(idx) });
                    return;
                }
            }
            try ctx.stack.push(.{ .boolean = false });
        },
        .byte_array => |b| {
            const byte_val: u8 = switch (elem) {
                .integer => |i| blk: {
                    if (i < 0 or i > 255) {
                        setErrorContext(ctx, "byte value {d} out of range 0-255", .{i});
                        return error.IntegerOverflow;
                    }
                    break :blk @intCast(i);
                },
                else => {
                    setErrorContext(ctx, "#index-of on byte-array requires integer element, got {s}", .{valueTypeName(elem)});
                    return error.TypeMismatch;
                },
            };
            if (std.mem.indexOfScalar(u8, b.items, byte_val)) |idx| {
                try ctx.stack.push(.{ .integer = @intCast(idx) });
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
    const n_val = try popInteger(ctx);
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
    const n_val = try popInteger(ctx);
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
