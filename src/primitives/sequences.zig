const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Vector = value_mod.Vector;
const ByteArray = value_mod.ByteArray;

const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");
const sequence = @import("sequence.zig");

const popInteger = helpers.popInteger;
const popBoolean = helpers.popBoolean;
const popQuotation = helpers.popQuotation;
const popVector = helpers.popVector;

const SequenceIterator = sequence.SequenceIterator;
const SequenceBuilder = sequence.SequenceBuilder;
const SequenceKind = sequence.SequenceKind;
const sequenceLength = sequence.sequenceLength;
const classifySequence = sequence.classifySequence;
const sequenceToValues = sequence.sequenceToValues;
const utf8NthCodepoint = sequence.utf8NthCodepoint;
const utf8SliceByCodepoints = sequence.utf8SliceByCodepoints;

pub const primitives = [_]Primitive{
    .{ .name = "#len", .stack_effect = "seq -- n", .func = nativeLen },
    .{ .name = "#nth", .stack_effect = "seq n -- elem", .func = nativeNth },
    .{ .name = "#first", .stack_effect = "seq -- elem", .func = nativeFirst },
    .{ .name = "#last", .stack_effect = "seq -- elem", .func = nativeLast },
    .{ .name = "#each", .stack_effect = "seq quot: ( elem -- ) --", .func = nativeEach },
    .{ .name = "#map", .stack_effect = "seq quot: ( elem -- elem' ) -- seq'", .func = nativeMap },
    .{ .name = "#filter", .stack_effect = "seq quot: ( elem -- ? ) -- seq'", .func = nativeFilter },
    .{ .name = "#reduce", .stack_effect = "seq init quot: ( acc elem -- acc' ) -- value", .func = nativeReduce },
    .{ .name = "#slice", .stack_effect = "seq start end -- subseq", .func = nativeSlice },
    .{ .name = "#append", .stack_effect = "seq1 seq2 -- seq", .func = nativeAppend },
    .{ .name = "#append!", .stack_effect = "vec seq -- vec", .func = nativeAppendMut },
    .{ .name = "#prepend", .stack_effect = "seq1 seq2 -- seq", .func = nativePrepend },
};

/// #len ( seq -- n ) - Get length of sequence (polymorphic on string, array, vector, byte-array, set)
pub fn nativeLen(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    // Use sequence module for standard sequences, handle mutable_map separately
    const len: i64 = if (sequenceLength(val)) |l|
        @intCast(l)
    else if (val == .mutable_map)
        @intCast(val.mutable_map.count())
    else
        return error.TypeError;
    try ctx.stack.push(.{ .integer = len });
}

/// #nth ( seq n -- elem ) - Get element at index (polymorphic on string, array, vector, byte-array)
pub fn nativeNth(ctx: *Context) anyerror!void {
    const index = try popInteger(ctx);
    const val = try ctx.stack.pop();

    if (index < 0) return error.IndexOutOfBounds;
    const idx: usize = @intCast(index);

    switch (val) {
        .string => |s| {
            const cp_slice = utf8NthCodepoint(s, idx) orelse return error.IndexOutOfBounds;
            const result = ctx.quotationAllocator().dupe(u8, cp_slice) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .string = result });
        },
        .array => |a| {
            if (idx >= a.len) return error.IndexOutOfBounds;
            try ctx.stack.push(a[idx]);
        },
        .vector => |v| {
            if (idx >= v.items.len) return error.IndexOutOfBounds;
            try ctx.stack.push(v.items[idx]);
        },
        .byte_array => |b| {
            if (idx >= b.items.len) return error.IndexOutOfBounds;
            try ctx.stack.push(.{ .integer = b.items[idx] });
        },
        else => return error.TypeError,
    }
}

/// #first ( seq -- elem ) - Get first element (polymorphic on string, array, vector, byte-array)
pub fn nativeFirst(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    // Sets are not supported for positional access (unordered)
    if (val == .set) return error.TypeError;

    var iter = SequenceIterator.init(val, alloc) orelse return error.TypeError;
    const first = try iter.next() orelse return error.EmptySequence;
    try ctx.stack.push(first);
}

/// #last ( seq -- elem ) - Get last element (polymorphic on string, array, vector, byte-array)
pub fn nativeLast(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    // Sets are not supported for positional access (unordered)
    if (val == .set) return error.TypeError;

    var iter = SequenceIterator.init(val, alloc) orelse return error.TypeError;
    var last: ?Value = null;
    while (try iter.next()) |elem| {
        last = elem;
    }
    try ctx.stack.push(last orelse return error.EmptySequence);
}

/// #each ( seq quot -- ) - Execute quotation for each element of sequence
pub fn nativeEach(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    var iter = SequenceIterator.init(seq, alloc) orelse return error.TypeError;
    while (try iter.next()) |elem| {
        try ctx.stack.push(elem);
        try ctx.executeQuotationWithFrame(quot);
    }
}

/// #map ( seq quot -- seq' ) - Transform each element of sequence
/// Note: string and byte_array map to array; others preserve type
pub fn nativeMap(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    const input_kind = classifySequence(seq) orelse return error.TypeError;
    // string and byte_array map to array; others preserve type
    const output_kind: SequenceKind = switch (input_kind) {
        .string, .byte_array => .array,
        else => input_kind,
    };

    const len = sequenceLength(seq) orelse return error.TypeError;
    var iter = SequenceIterator.init(seq, alloc) orelse return error.TypeError;
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
pub fn nativeFilter(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    const kind = classifySequence(seq) orelse return error.TypeError;
    var iter = SequenceIterator.init(seq, alloc) orelse return error.TypeError;
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

    var iter = SequenceIterator.init(seq, alloc) orelse return error.TypeError;
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

    if (start_val < 0) return error.IndexOutOfBounds;
    if (end_val < 0) return error.IndexOutOfBounds;
    if (start_val > end_val) return error.IndexOutOfBounds;

    const start: usize = @intCast(start_val);
    const end: usize = @intCast(end_val);

    const alloc = ctx.quotationAllocator();

    switch (seq) {
        .array => |arr| {
            if (end > arr.len) return error.IndexOutOfBounds;
            const slice_len = end - start;
            const result = alloc.alloc(Value, slice_len) catch return error.OutOfMemory;
            @memcpy(result, arr[start..end]);
            try ctx.stack.push(.{ .array = result });
        },
        .string => |s| {
            const bounds = utf8SliceByCodepoints(s, start, end) orelse return error.IndexOutOfBounds;
            const result = alloc.dupe(u8, s[bounds.start_byte..bounds.end_byte]) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .string = result });
        },
        .vector => |v| {
            if (end > v.items.len) return error.IndexOutOfBounds;
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
            if (end > b.items.len) return error.IndexOutOfBounds;
            const slice_len = end - start;
            const result_ba = alloc.create(ByteArray) catch return error.OutOfMemory;
            result_ba.* = ByteArray{};
            result_ba.ensureTotalCapacity(alloc, slice_len) catch return error.OutOfMemory;
            for (b.items[start..end]) |byte| {
                result_ba.appendAssumeCapacity(byte);
            }
            try ctx.stack.push(.{ .byte_array = result_ba });
        },
        else => return error.TypeError,
    }
}

/// #append ( seq1 seq2 -- seq ) - Concatenate seq2 to seq1, returns new sequence of type seq1
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
                        if (i < 0 or i > 255) return error.IntegerOverflow;
                        total_len += 1;
                    },
                    else => return error.TypeError,
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
                        if (i < 0 or i > 255) return error.IntegerOverflow;
                        extra_len += 1;
                    },
                    .string => |s| extra_len += s.len,
                    else => return error.TypeError,
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
        else => return error.TypeError,
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
                        if (i < 0 or i > 255) return error.IntegerOverflow;
                        total_len += 1; // single byte
                    },
                    else => return error.TypeError,
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
                        if (i < 0 or i > 255) return error.IntegerOverflow;
                        extra_len += 1;
                    },
                    .string => |s| extra_len += s.len,
                    else => return error.TypeError,
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
        else => return error.TypeError,
    }
}
