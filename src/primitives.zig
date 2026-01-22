const std = @import("std");
const Allocator = std.mem.Allocator;

const Context = @import("context.zig").Context;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Quotation = value_mod.Quotation;
const Instruction = value_mod.Instruction;
const HashTable = value_mod.HashTable;
const Vector = value_mod.Vector;
const ByteArray = value_mod.ByteArray;
const Set = value_mod.Set;
const MutableMap = value_mod.MutableMap;
const Stream = value_mod.Stream;
const StreamMode = value_mod.StreamMode;
const BufferingMode = value_mod.BufferingMode;
const Parameter = value_mod.Parameter;
const ErrorObject = value_mod.ErrorObject;
const StackFrame = value_mod.StackFrame;

const Dictionary = @import("dictionary.zig").Dictionary;
const WordDefinition = @import("dictionary.zig").WordDefinition;
const NativeFn = @import("dictionary.zig").NativeFn;
const StackEffect = @import("stack_effect.zig").StackEffect;
const StackEffectParam = @import("stack_effect.zig").StackEffectParam;
const StatementProcessor = @import("statement.zig").StatementProcessor;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const parser = @import("parser.zig");
const BenchmarkStats = @import("benchmark.zig").BenchmarkStats;

const primitives_mod = @import("primitives/mod.zig");
pub const InterpreterError = primitives_mod.InterpreterError;
const Primitive = primitives_mod.Primitive;

const makeSimpleEffect = primitives_mod.makeSimpleEffect;
const popInteger = primitives_mod.popInteger;
const popBoolean = primitives_mod.popBoolean;
const popQuotation = primitives_mod.popQuotation;
const popSymbol = primitives_mod.popSymbol;
const popString = primitives_mod.popString;
const popStackEffect = primitives_mod.popStackEffect;
const popVector = primitives_mod.popVector;
const popByteArray = primitives_mod.popByteArray;
const popStream = primitives_mod.popStream;

const mapFileOpenError = primitives_mod.mapFileOpenError;
const mapFileCreateError = primitives_mod.mapFileCreateError;
const mapFileWriteError = primitives_mod.mapFileWriteError;
const mapFileReadError = primitives_mod.mapFileReadError;
const mapFileSyncError = primitives_mod.mapFileSyncError;
const mapSeekError = primitives_mod.mapSeekError;
const mapGetPosError = primitives_mod.mapGetPosError;
const ensureStreamOpen = primitives_mod.ensureStreamOpen;

const SequenceIterator = primitives_mod.SequenceIterator;
const SequenceBuilder = primitives_mod.SequenceBuilder;
const SequenceKind = primitives_mod.SequenceKind;
const sequenceLength = primitives_mod.sequenceLength;
const sequenceToValues = primitives_mod.sequence.sequenceToValues;
const classifySequence = primitives_mod.classifySequence;

const stack_mod = primitives_mod.stack;
const nativeDup = stack_mod.nativeDup;
const nativeDrop = stack_mod.nativeDrop;
const nativeSwap = stack_mod.nativeSwap;
const nativeOver = stack_mod.nativeOver;
const nativeDip = stack_mod.nativeDip;
const nativeWipe = stack_mod.nativeWipe;

const arithmetic_mod = primitives_mod.arithmetic;
const nativeAdd = arithmetic_mod.nativeAdd;
const nativeSub = arithmetic_mod.nativeSub;
const nativeMul = arithmetic_mod.nativeMul;
const nativeDiv = arithmetic_mod.nativeDiv;
const nativeMod = arithmetic_mod.nativeMod;
const nativeAddWrap = arithmetic_mod.nativeAddWrap;
const nativeSubWrap = arithmetic_mod.nativeSubWrap;
const nativeMulWrap = arithmetic_mod.nativeMulWrap;
const nativeEq = arithmetic_mod.nativeEq;
const nativeLt = arithmetic_mod.nativeLt;
const nativeGt = arithmetic_mod.nativeGt;

const control_mod = primitives_mod.control;
const nativeCall = control_mod.nativeCall;
const nativeSemicolon = control_mod.nativeSemicolon;
const nativeIf = control_mod.nativeIf;

const parse_time_mod = primitives_mod.parse_time;
const nativeParseTime = parse_time_mod.nativeParseTime;
const nativeParseUntil = parse_time_mod.nativeParseUntil;

const utf8CodepointCount = primitives_mod.utf8CodepointCount;
const utf8NthCodepoint = primitives_mod.utf8NthCodepoint;
const utf8SliceByCodepoints = primitives_mod.utf8SliceByCodepoints;

const remaining_primitives = [_]Primitive{
    // Error handling
    .{ .name = "recover", .stack_effect = "try-quot recover-quot: ( error -- ) --", .func = nativeRecover },
    .{ .name = "cleanup", .stack_effect = "body-quot cleanup-quot --", .func = nativeCleanup },
    .{ .name = "rethrow", .stack_effect = "error --", .func = nativeRethrow },
    // Data structure creation and manipulation
    .{ .name = "make-hash", .stack_effect = "quotation -- hash", .func = nativeMakeHash },
    .{ .name = "make-vector", .stack_effect = "quotation -- vector", .func = nativeMakeVector },
    .{ .name = "make-byte-array", .stack_effect = "quotation -- byte-array", .func = nativeMakeByteArray },
    .{ .name = "make-set", .stack_effect = "quotation -- set", .func = nativeMakeSet },
    .{ .name = "make-mutable-map", .stack_effect = "quotation -- mmap", .func = nativeMakeMutableMap },
    .{ .name = "@set!", .stack_effect = "mmap key value -- mmap", .func = nativeAtSetMut },
    .{ .name = "@remove!", .stack_effect = "mmap key -- mmap", .func = nativeAtRemoveMut },
    // Functional programming primitives
    .{ .name = "curry", .stack_effect = "x quot -- quot'", .func = nativeCurry },
    .{ .name = "compose", .stack_effect = "quot1 quot2 -- quot'", .func = nativeCompose },
    // Benchmarking
    .{ .name = "benchmark", .stack_effect = "quot -- hash", .func = nativeBenchmark },
    // Sequence queries
    .{ .name = "#len", .stack_effect = "seq -- n", .func = nativeLen },
    .{ .name = "#nth", .stack_effect = "seq n -- elem", .func = nativeNth },
    .{ .name = "#first", .stack_effect = "seq -- elem", .func = nativeFirst },
    .{ .name = "#last", .stack_effect = "seq -- elem", .func = nativeLast },
    // Associative operations
    .{ .name = "@get", .stack_effect = "assoc key -- value", .func = nativeAtGet },
    .{ .name = "@has?", .stack_effect = "assoc key -- ?", .func = nativeAtHas },
    .{ .name = "@set", .stack_effect = "assoc key value -- assoc'", .func = nativeAtSet },
    .{ .name = "@keys", .stack_effect = "assoc -- array", .func = nativeAtKeys },
    .{ .name = "@values", .stack_effect = "assoc -- array", .func = nativeAtValues },
    // Sequence operations
    .{ .name = "#each", .stack_effect = "seq quot: ( elem -- ) --", .func = nativeEach },
    .{ .name = "#map", .stack_effect = "seq quot: ( elem -- elem' ) -- seq'", .func = nativeMap },
    .{ .name = "#filter", .stack_effect = "seq quot: ( elem -- ? ) -- seq'", .func = nativeFilter },
    .{ .name = "#reduce", .stack_effect = "seq init quot: ( acc elem -- acc' ) -- value", .func = nativeReduce },
    .{ .name = "#slice", .stack_effect = "seq start end -- subseq", .func = nativeSlice },
    .{ .name = "#append", .stack_effect = "seq1 seq2 -- seq", .func = nativeAppend },
    .{ .name = "#append!", .stack_effect = "vec seq -- vec", .func = nativeAppendMut },
    .{ .name = "#prepend", .stack_effect = "seq1 seq2 -- seq", .func = nativePrepend },
    // Mutable vector operations
    .{ .name = "#push!", .stack_effect = "vec elem -- vec", .func = nativePushMut },
    .{ .name = "#pop!", .stack_effect = "vec -- elem", .func = nativePopMut },
    // Set operations
    .{ .name = "@in?", .stack_effect = "set value -- ?", .func = nativeAtIn },
    .{ .name = "@adjoin", .stack_effect = "set value -- set'", .func = nativeAtAdjoin },
    .{ .name = "@remove", .stack_effect = "set value -- set'", .func = nativeAtRemove },
    .{ .name = "@union", .stack_effect = "set1 set2 -- set'", .func = nativeAtUnion },
    .{ .name = "@intersection", .stack_effect = "set1 set2 -- set'", .func = nativeAtIntersection },
    .{ .name = "@difference", .stack_effect = "set1 set2 -- set'", .func = nativeAtDifference },
    // Stream I/O primitives
    .{ .name = "stdin", .stack_effect = "-- stream", .func = nativeStdin },
    .{ .name = "stdout", .stack_effect = "-- stream", .func = nativeStdout },
    .{ .name = "stderr", .stack_effect = "-- stream", .func = nativeStderr },
    .{ .name = "stream-open", .stack_effect = "path mode -- stream", .func = nativeStreamOpen },
    .{ .name = "stream-close", .stack_effect = "stream --", .func = nativeStreamClose },
    .{ .name = "stream-write", .stack_effect = "stream bytes -- n", .func = nativeStreamWrite },
    .{ .name = "stream-flush", .stack_effect = "stream --", .func = nativeStreamFlush },
    .{ .name = "stream-read", .stack_effect = "stream n -- bytes", .func = nativeStreamRead },
    .{ .name = "stream-read-line", .stack_effect = "stream -- str/f", .func = nativeStreamReadLine },
    .{ .name = "stream-read-all", .stack_effect = "stream -- bytes", .func = nativeStreamReadAll },
    .{ .name = "stream-tell", .stack_effect = "stream -- pos", .func = nativeStreamTell },
    .{ .name = "stream-seek", .stack_effect = "stream pos --", .func = nativeStreamSeek },
    .{ .name = "stream-seek-end", .stack_effect = "stream offset --", .func = nativeStreamSeekEnd },
    .{ .name = "buffering-mode", .stack_effect = "stream -- symbol", .func = nativeBufferingMode },
    .{ .name = "set-buffering-mode", .stack_effect = "stream symbol --", .func = nativeSetBufferingMode },
    .{ .name = "stream->fd", .stack_effect = "stream -- int", .func = nativeStreamToFd },
    .{ .name = "fd->stream", .stack_effect = "int mode -- stream", .func = nativeFdToStream },
    .{ .name = ">char", .stack_effect = "codepoint -- str", .func = nativeChr },
    .{ .name = ">codepoint", .stack_effect = "str -- codepoint", .func = nativeToCodepoint },
    // Dynamic variables (parameters) - parse-time primitives
    .{ .name = "parse-quotation", .stack_effect = "-- quotation", .func = nativeParseQuotation },
    // Dynamic variables (parameters) - runtime primitives
    .{ .name = "make-parameter", .stack_effect = "name: quot -- param", .func = nativeMakeParameter },
    .{ .name = "get", .stack_effect = "param -- value", .func = nativeGet },
    .{ .name = "with-parameter", .stack_effect = "value param quot --", .func = nativeWithParameter },
};

// All primitives: extracted modules + remaining local ones
const all_primitives = primitives_mod.extracted_primitives ++ remaining_primitives;

pub fn registerPrimitives(dict: *Dictionary, allocator: Allocator) !void {
    for (all_primitives) |p| {
        const effect: ?StackEffect = if (p.stack_effect) |raw|
            try makeSimpleEffect(allocator, raw)
        else
            null;

        try dict.put(p.name, WordDefinition{
            .name = p.name,
            .parse_time = p.parse_time,
            .stack_effect = effect,
            .action = .{ .native = p.func },
        });
    }
}

// =============================================================================
// Primitive implementations (remaining - not yet extracted to modules)
// =============================================================================

/// recover ( try-quot recover-quot -- ) - Execute try quotation; if error,
/// execute recover quotation with error on stack
fn nativeRecover(ctx: *Context) anyerror!void {
    // Note: Parameter effects are validated statically by validateParameterEffects
    // before this function is called, so we just pop the quotations here.
    const recover_quot = try popQuotation(ctx);
    const try_quot = try popQuotation(ctx);

    // Execute try quotation with error-catching
    ctx.executeQuotation(try_quot) catch |err| {
        const alloc = ctx.quotationAllocator();
        var stack_trace: ?[]const StackFrame = null;

        if (ctx.error_details.items.len > 0) {
            const frames = alloc.alloc(StackFrame, ctx.error_details.items.len) catch null;
            if (frames) |f| {
                for (ctx.error_details.items, 0..) |detail, i| {
                    f[i] = .{
                        .word_name = detail.word_name orelse detail.message,
                        .line = detail.line,
                    };
                }
                stack_trace = f;
            }
        }

        const error_obj = ErrorObject{
            .error_type = @errorName(err),
            .message = @errorName(err),
            .stack_trace = stack_trace,
        };
        try ctx.stack.push(.{ .error_value = error_obj });

        // Clear error details after capturing, and execute recovery
        ctx.clearExecutionDetails();
        try ctx.executeQuotation(recover_quot);
        return;
    };
}

/// cleanup ( body-quot cleanup-quot -- ) - Execute body, always run cleanup,
/// then re-throw any error from body
fn nativeCleanup(ctx: *Context) anyerror!void {
    const cleanup_quot = try popQuotation(ctx);
    const body_quot = try popQuotation(ctx);

    // Execute body quotation, capturing any error
    const body_result = ctx.executeQuotation(body_quot);

    // Always execute cleanup quotation, even if body failed
    // If cleanup also fails, we ignore that error and prioritize the body error
    ctx.executeQuotation(cleanup_quot) catch {
        // Cleanup error is suppressed; body error takes priority
    };

    // Re-throw original error if body failed
    try body_result;
}

/// rethrow ( error -- ) - Re-raise an error value as an actual error
fn nativeRethrow(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .error_value => |err_obj| {
            // Restore the error details from the ErrorObject's stack trace
            if (err_obj.stack_trace) |trace| {
                // Clear any existing error details and restore from the error object
                ctx.error_details.clearRetainingCapacity();
                for (trace) |frame| {
                    ctx.error_details.append(ctx.allocator, .{
                        .error_type = err_obj.error_type,
                        .message = err_obj.message,
                        .line = frame.line,
                        .word_name = frame.word_name,
                    }) catch {};
                }
            }
            return error.RethrowError;
        },
        else => return error.TypeError,
    }
}

/// make-hash ( quotation -- hash ) - Create a hash table from key: value pairs
/// The quotation should contain alternating symbol keys and values.
/// Example: [ name: "Alice" age: 30 ] make-hash
fn nativeMakeHash(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const instrs = quot.instructions;

    // Create a new hash table
    const hash = ctx.quotationAllocator().create(HashTable) catch return error.OutOfMemory;
    hash.* = HashTable{};

    // Parse instructions as key: value pairs
    var i: usize = 0;
    while (i < instrs.len) {
        // Expect a symbol key
        const key_instr = instrs[i];
        const key = switch (key_instr.op) {
            .push_literal => |v| switch (v) {
                .symbol => |s| s,
                else => return error.InvalidHashSyntax,
            },
            .call_word => return error.InvalidHashSyntax,
        };
        i += 1;

        if (i >= instrs.len) return error.InvalidHashSyntax;

        // Get the value - could be a literal or need execution
        const val_instr = instrs[i];
        const val = switch (val_instr.op) {
            .push_literal => |v| v,
            .call_word => blk: {
                // Execute the remaining instructions to get the value
                // TODO(ripta): figure out supporting beyond single-words
                try ctx.executeQuotation(.{ .instructions = instrs[i .. i + 1] });
                break :blk ctx.stack.pop() catch return error.InvalidHashSyntax;
            },
        };
        i += 1;

        // Copy key to arena for persistence
        const key_copy = ctx.quotationAllocator().dupe(u8, key) catch return error.OutOfMemory;
        hash.put(ctx.quotationAllocator(), key_copy, val) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .hash = hash });
}

/// make-vector ( quotation -- vector ) - Create a vector from values in quotation
/// Example: [ 1 2 3 ] make-vector
fn nativeMakeVector(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const instrs = quot.instructions;
    const alloc = ctx.quotationAllocator();

    // Create a new vector
    const vec = alloc.create(Vector) catch return error.OutOfMemory;
    vec.* = Vector{};

    // Execute each instruction and collect values
    for (instrs) |instr| {
        const val = switch (instr.op) {
            .push_literal => |v| v,
            .call_word => blk: {
                // Execute the word to get the value
                try ctx.executeQuotation(.{ .instructions = @as(*const [1]Instruction, &instr) });
                break :blk ctx.stack.pop() catch return error.OutOfMemory;
            },
        };
        vec.append(alloc, val) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .vector = vec });
}

/// make-byte-array ( quotation -- byte-array ) - Create a byte array from values in quotation
/// Example: [ 0xFF 0x00 0x42 ] make-byte-array
/// Values must be integers in range 0-255
fn nativeMakeByteArray(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const instrs = quot.instructions;
    const alloc = ctx.quotationAllocator();

    // Create a new byte array
    const ba = alloc.create(ByteArray) catch return error.OutOfMemory;
    ba.* = ByteArray{};

    // Execute each instruction and collect byte values
    for (instrs) |instr| {
        const val = switch (instr.op) {
            .push_literal => |v| v,
            .call_word => blk: {
                // Execute the word to get the value
                try ctx.executeQuotation(.{ .instructions = @as(*const [1]Instruction, &instr) });
                break :blk ctx.stack.pop() catch return error.OutOfMemory;
            },
        };
        // Value must be an integer in byte range
        switch (val) {
            .integer => |i| {
                if (i < 0 or i > 255) return error.IntegerOverflow;
                ba.append(alloc, @intCast(i)) catch return error.OutOfMemory;
            },
            else => return error.TypeError,
        }
    }

    try ctx.stack.push(.{ .byte_array = ba });
}

/// make-set ( quotation -- set ) - Create a set from unique values in quotation
/// Example: [ 1 2 3 2 1 ] make-set creates S{ 1 2 3 } (duplicates removed)
fn nativeMakeSet(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const instrs = quot.instructions;
    const alloc = ctx.quotationAllocator();

    // Create a new set
    const set = alloc.create(Set) catch return error.OutOfMemory;
    set.* = Set{};

    // Execute each instruction and collect unique values
    for (instrs) |instr| {
        const val = switch (instr.op) {
            .push_literal => |v| v,
            .call_word => blk: {
                // Execute the word to get the value
                try ctx.executeQuotation(.{ .instructions = @as(*const [1]Instruction, &instr) });
                break :blk ctx.stack.pop() catch return error.OutOfMemory;
            },
        };

        set.put(alloc, val, {}) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .set = set });
}

/// make-mutable-map ( quotation -- mmap ) - Create a mutable map from key: value pairs
/// Example: [ name: "Alice" age: 30 ] make-mutable-map
fn nativeMakeMutableMap(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const instrs = quot.instructions;
    const alloc = ctx.quotationAllocator();

    // Create a new mutable map
    const mmap = alloc.create(MutableMap) catch return error.OutOfMemory;
    mmap.* = MutableMap{};

    // Parse instructions as key: value pairs (same as make-hash)
    var i: usize = 0;
    while (i < instrs.len) {
        // Expect a symbol key
        const key_instr = instrs[i];
        const key = switch (key_instr.op) {
            .push_literal => |v| switch (v) {
                .symbol => |s| s,
                else => return error.InvalidHashSyntax,
            },
            .call_word => return error.InvalidHashSyntax,
        };
        i += 1;

        if (i >= instrs.len) return error.InvalidHashSyntax;

        // Get the value - could be a literal or need execution
        const val_instr = instrs[i];
        const val = switch (val_instr.op) {
            .push_literal => |v| v,
            .call_word => blk: {
                try ctx.executeQuotation(.{ .instructions = instrs[i .. i + 1] });
                break :blk ctx.stack.pop() catch return error.InvalidHashSyntax;
            },
        };
        i += 1;

        // Copy key to arena for persistence
        const key_copy = alloc.dupe(u8, key) catch return error.OutOfMemory;
        mmap.put(alloc, key_copy, val) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .mutable_map = mmap });
}

/// @set! ( mmap key value -- mmap ) - Set value in mutable map, mutate in place
fn nativeAtSetMut(ctx: *Context) anyerror!void {
    const new_value = try ctx.stack.pop();
    const key = try ctx.stack.pop();
    const obj = try ctx.stack.pop();

    const key_str = try extractKeyString(key);

    switch (obj) {
        .mutable_map => |m| {
            const alloc = ctx.quotationAllocator();

            // Check if key already exists
            if (m.get(key_str) != null) {
                // Update existing key in place (use the same key pointer)
                m.putAssumeCapacity(key_str, new_value);
            } else {
                // New key - need to copy it
                const key_copy = alloc.dupe(u8, key_str) catch return error.OutOfMemory;
                m.put(alloc, key_copy, new_value) catch return error.OutOfMemory;
            }

            try ctx.stack.push(.{ .mutable_map = m });
        },
        else => return error.TypeError,
    }
}

/// @remove! ( mmap key -- mmap ) - Remove key from mutable map, mutate in place
fn nativeAtRemoveMut(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    const obj = try ctx.stack.pop();

    const key_str = try extractKeyString(key);

    switch (obj) {
        .mutable_map => |m| {
            _ = m.remove(key_str);
            try ctx.stack.push(.{ .mutable_map = m });
        },
        else => return error.TypeError,
    }
}

/// @in? ( set value -- ? ) - Check if value is in the set
fn nativeAtIn(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const set_val = try ctx.stack.pop();

    const set = switch (set_val) {
        .set => |s| s,
        else => return error.TypeError,
    };

    try ctx.stack.push(.{ .boolean = set.contains(val) });
}

/// @adjoin ( set value -- set' ) - Add value to set, returning new set (immutable)
fn nativeAtAdjoin(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const set_val = try ctx.stack.pop();

    const old_set = switch (set_val) {
        .set => |s| s,
        else => return error.TypeError,
    };

    if (old_set.contains(val)) {
        // Value already in set, return same set
        try ctx.stack.push(.{ .set = old_set });
        return;
    }

    const alloc = ctx.quotationAllocator();

    // Create new set with the additional value
    const new_set = alloc.create(Set) catch return error.OutOfMemory;
    new_set.* = old_set.clone(alloc) catch return error.OutOfMemory;

    // Add new element
    new_set.put(alloc, val, {}) catch return error.OutOfMemory;

    try ctx.stack.push(.{ .set = new_set });
}

/// @remove ( set value -- set' ) - Remove value from set, returning new set (immutable)
fn nativeAtRemove(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const set_val = try ctx.stack.pop();

    const old_set = switch (set_val) {
        .set => |s| s,
        else => return error.TypeError,
    };

    const alloc = ctx.quotationAllocator();

    // Create new set without the specified value
    const new_set = alloc.create(Set) catch return error.OutOfMemory;
    new_set.* = old_set.clone(alloc) catch return error.OutOfMemory;

    _ = new_set.swapRemove(val);
    try ctx.stack.push(.{ .set = new_set });
}

/// @union ( set1 set2 -- set' ) - Return union of two sets
fn nativeAtUnion(ctx: *Context) anyerror!void {
    const set2_val = try ctx.stack.pop();
    const set1_val = try ctx.stack.pop();

    const set1 = switch (set1_val) {
        .set => |s| s,
        else => return error.TypeError,
    };
    const set2 = switch (set2_val) {
        .set => |s| s,
        else => return error.TypeError,
    };

    const alloc = ctx.quotationAllocator();

    // Create new set with all elements from both sets
    const new_set = alloc.create(Set) catch return error.OutOfMemory;
    new_set.* = set1.clone(alloc) catch return error.OutOfMemory;

    // Add all elements from set2 (duplicates handled automatically)
    for (set2.keys()) |key| {
        new_set.put(alloc, key, {}) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .set = new_set });
}

/// @intersection ( set1 set2 -- set' ) - Return intersection of two sets
fn nativeAtIntersection(ctx: *Context) anyerror!void {
    const set2_val = try ctx.stack.pop();
    const set1_val = try ctx.stack.pop();

    const set1 = switch (set1_val) {
        .set => |s| s,
        else => return error.TypeError,
    };
    const set2 = switch (set2_val) {
        .set => |s| s,
        else => return error.TypeError,
    };

    const alloc = ctx.quotationAllocator();

    // Create new set with elements that are in both sets
    const new_set = alloc.create(Set) catch return error.OutOfMemory;
    new_set.* = Set{};

    for (set1.keys()) |key| {
        if (set2.contains(key)) {
            new_set.put(alloc, key, {}) catch return error.OutOfMemory;
        }
    }

    try ctx.stack.push(.{ .set = new_set });
}

/// @difference ( set1 set2 -- set' ) - Return elements in set1 but not in set2
fn nativeAtDifference(ctx: *Context) anyerror!void {
    const set2_val = try ctx.stack.pop();
    const set1_val = try ctx.stack.pop();

    const set1 = switch (set1_val) {
        .set => |s| s,
        else => return error.TypeError,
    };
    const set2 = switch (set2_val) {
        .set => |s| s,
        else => return error.TypeError,
    };

    const alloc = ctx.quotationAllocator();

    // Create new set with elements from set1 that aren't in set2
    const new_set = alloc.create(Set) catch return error.OutOfMemory;
    new_set.* = Set{};

    for (set1.keys()) |key| {
        if (!set2.contains(key)) {
            new_set.put(alloc, key, {}) catch return error.OutOfMemory;
        }
    }

    try ctx.stack.push(.{ .set = new_set });
}

/// curry ( x quot -- quot' ) - Create new quotation with x prepended
/// Example: 5 [ + ] curry creates [ 5 + ]
fn nativeCurry(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const x = try ctx.stack.pop();

    // Allocate new instruction array: 1 (for push x) + original length
    const alloc = ctx.quotationAllocator();
    const new_instrs = try alloc.alloc(Instruction, 1 + quot.instructions.len);

    // First instruction: push the value x
    new_instrs[0] = .{ .op = .{ .push_literal = x }, .line = 0 };

    // Copy original quotation instructions
    @memcpy(new_instrs[1..], quot.instructions);

    // Curried quotation has no effect - effect validation happens at parameter attachment time
    try ctx.stack.push(.{ .quotation = .{ .instructions = new_instrs, .effect = null } });
}

/// compose ( quot1 quot2 -- quot' ) - Concatenate two quotations
/// Example: [ 2 * ] [ 3 + ] compose creates [ 2 * 3 + ]
fn nativeCompose(ctx: *Context) anyerror!void {
    const quot2 = try popQuotation(ctx);
    const quot1 = try popQuotation(ctx);

    // Allocate new instruction array: quot1.len + quot2.len
    const alloc = ctx.quotationAllocator();
    const new_instrs = try alloc.alloc(Instruction, quot1.instructions.len + quot2.instructions.len);

    // Copy quot1 then quot2
    @memcpy(new_instrs[0..quot1.instructions.len], quot1.instructions);
    @memcpy(new_instrs[quot1.instructions.len..], quot2.instructions);

    // Composed quotation has no effect - effect validation happens at parameter attachment time
    try ctx.stack.push(.{ .quotation = .{ .instructions = new_instrs, .effect = null } });
}

/// benchmark ( quot -- hash ) - Execute quotation and return benchmark stats
fn nativeBenchmark(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);

    // Create temporary benchmark stats for this execution
    var local_stats = BenchmarkStats{};

    // Save and replace context benchmark pointer
    const saved_benchmark = ctx.benchmark;
    ctx.benchmark = &local_stats;

    // Time and execute
    const start_time = std.time.nanoTimestamp();
    const exec_result = ctx.executeQuotation(quot);

    const end_time = std.time.nanoTimestamp();
    const elapsed_ns = end_time - start_time;

    // Restore original benchmark pointer
    ctx.benchmark = saved_benchmark;

    // Propagate execution error after restoring state
    try exec_result;

    // Build result hash
    const alloc = ctx.quotationAllocator();
    const hash = alloc.create(HashTable) catch return error.OutOfMemory;
    hash.* = HashTable{};

    const key1 = alloc.dupe(u8, "elapsed_ns") catch return error.OutOfMemory;
    hash.put(alloc, key1, .{ .integer = @intCast(elapsed_ns) }) catch return error.OutOfMemory;

    const key2 = alloc.dupe(u8, "push_literal") catch return error.OutOfMemory;
    hash.put(alloc, key2, .{ .integer = @intCast(local_stats.push_literal_count) }) catch return error.OutOfMemory;

    const key3 = alloc.dupe(u8, "call_word") catch return error.OutOfMemory;
    hash.put(alloc, key3, .{ .integer = @intCast(local_stats.call_word_count) }) catch return error.OutOfMemory;

    const key4 = alloc.dupe(u8, "total_instructions") catch return error.OutOfMemory;
    hash.put(alloc, key4, .{ .integer = @intCast(local_stats.totalInstructions()) }) catch return error.OutOfMemory;

    const key5 = alloc.dupe(u8, "peak_stack_depth") catch return error.OutOfMemory;
    hash.put(alloc, key5, .{ .integer = @intCast(local_stats.peak_stack_depth) }) catch return error.OutOfMemory;

    try ctx.stack.push(.{ .hash = hash });
}

// =============================================================================
// Sequence Accessors
// =============================================================================

/// #len ( seq -- n ) - Get sequence length (polymorphic on string, array, vector, byte-array)
fn nativeLen(ctx: *Context) anyerror!void {
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
fn nativeNth(ctx: *Context) anyerror!void {
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
fn nativeFirst(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    // Sets are not supported for positional access (unordered)
    if (val == .set) return error.TypeError;

    var iter = SequenceIterator.init(val, alloc) orelse return error.TypeError;
    const first = try iter.next() orelse return error.EmptySequence;
    try ctx.stack.push(first);
}

/// #last ( seq -- elem ) - Get last element (polymorphic on string, array, vector, byte-array)
fn nativeLast(ctx: *Context) anyerror!void {
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

// =============================================================================
// Associative Accessors
// =============================================================================

/// Helper to extract key string from symbol or string value
fn extractKeyString(val: Value) ![]const u8 {
    return switch (val) {
        .symbol => |s| s,
        .string => |s| s,
        else => error.TypeError,
    };
}

/// Helper to get error object field value
fn getErrorField(ctx: *Context, err: ErrorObject, field_name: []const u8) !Value {
    if (std.mem.eql(u8, field_name, "error-type")) {
        return .{ .string = err.error_type };
    } else if (std.mem.eql(u8, field_name, "message")) {
        return .{ .string = err.message };
    } else if (std.mem.eql(u8, field_name, "stack-trace")) {
        if (err.stack_trace) |trace| {
            // Convert stack trace to array of hashes
            const alloc = ctx.quotationAllocator();
            const frames = alloc.alloc(Value, trace.len) catch return error.OutOfMemory;
            for (trace, 0..) |frame, i| {
                const frame_hash = alloc.create(HashTable) catch return error.OutOfMemory;
                frame_hash.* = HashTable{};
                const word_key = alloc.dupe(u8, "word") catch return error.OutOfMemory;
                frame_hash.put(alloc, word_key, .{ .string = frame.word_name }) catch return error.OutOfMemory;
                const line_key = alloc.dupe(u8, "line") catch return error.OutOfMemory;
                frame_hash.put(alloc, line_key, .{ .integer = @intCast(frame.line) }) catch return error.OutOfMemory;
                frames[i] = .{ .hash = frame_hash };
            }
            return .{ .array = frames };
        } else {
            return .{ .boolean = false }; // f for null
        }
    } else {
        return error.KeyNotFound;
    }
}

/// @get ( assoc key -- value ) - Get value by key/field (polymorphic on hash, error)
fn nativeAtGet(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    const obj = try ctx.stack.pop();

    const key_str = try extractKeyString(key);

    switch (obj) {
        .hash => |h| {
            if (h.get(key_str)) |val| {
                try ctx.stack.push(val);
            } else {
                return error.KeyNotFound;
            }
        },
        .mutable_map => |m| {
            if (m.get(key_str)) |val| {
                try ctx.stack.push(val);
            } else {
                return error.KeyNotFound;
            }
        },
        .error_value => |err| {
            const val = try getErrorField(ctx, err, key_str);
            try ctx.stack.push(val);
        },
        else => return error.TypeError,
    }
}

/// @has? ( assoc key -- ? ) - Check if key/field exists (polymorphic on hash, mmap, error)
fn nativeAtHas(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    const obj = try ctx.stack.pop();

    const key_str = try extractKeyString(key);

    switch (obj) {
        .hash => |h| {
            const exists = h.get(key_str) != null;
            try ctx.stack.push(.{ .boolean = exists });
        },
        .mutable_map => |m| {
            const exists = m.get(key_str) != null;
            try ctx.stack.push(.{ .boolean = exists });
        },
        .error_value => {
            // Check if field name is valid for errors
            const valid = std.mem.eql(u8, key_str, "error-type") or
                std.mem.eql(u8, key_str, "message") or
                std.mem.eql(u8, key_str, "stack-trace");
            try ctx.stack.push(.{ .boolean = valid });
        },
        else => return error.TypeError,
    }
}

/// @set ( assoc key value -- assoc' ) - Set value, returns new hash (hash only)
fn nativeAtSet(ctx: *Context) anyerror!void {
    const new_value = try ctx.stack.pop();
    const key = try ctx.stack.pop();
    const obj = try ctx.stack.pop();

    const key_str = try extractKeyString(key);

    switch (obj) {
        .hash => |h| {
            const alloc = ctx.quotationAllocator();

            // Create new hash table on heap
            const new_hash = alloc.create(HashTable) catch return error.OutOfMemory;
            new_hash.* = HashTable{};

            // Clone the existing entries
            var iter = h.iterator();
            while (iter.next()) |entry| {
                const key_copy = alloc.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
                new_hash.put(alloc, key_copy, entry.value_ptr.*) catch return error.OutOfMemory;
            }

            // Add/update the new key-value pair
            const new_key = alloc.dupe(u8, key_str) catch return error.OutOfMemory;
            new_hash.put(alloc, new_key, new_value) catch return error.OutOfMemory;

            try ctx.stack.push(.{ .hash = new_hash });
        },
        .error_value => {
            // Error objects are immutable
            return error.TypeError;
        },
        else => return error.TypeError,
    }
}

/// @keys ( assoc -- array ) - Get all keys (polymorphic on hash, error)
fn nativeAtKeys(ctx: *Context) anyerror!void {
    const obj = try ctx.stack.pop();

    switch (obj) {
        .hash => |h| {
            const alloc = ctx.quotationAllocator();
            const keys = alloc.alloc(Value, h.count()) catch return error.OutOfMemory;
            var iter = h.iterator();
            var i: usize = 0;
            while (iter.next()) |entry| {
                keys[i] = .{ .symbol = entry.key_ptr.* };
                i += 1;
            }
            try ctx.stack.push(.{ .array = keys });
        },
        .mutable_map => |m| {
            const alloc = ctx.quotationAllocator();
            const keys = alloc.alloc(Value, m.count()) catch return error.OutOfMemory;
            var iter = m.iterator();
            var i: usize = 0;
            while (iter.next()) |entry| {
                keys[i] = .{ .symbol = entry.key_ptr.* };
                i += 1;
            }
            try ctx.stack.push(.{ .array = keys });
        },
        .error_value => {
            // Error objects have fixed fields
            const alloc = ctx.quotationAllocator();
            const keys = alloc.alloc(Value, 3) catch return error.OutOfMemory;
            keys[0] = .{ .symbol = "error-type" };
            keys[1] = .{ .symbol = "message" };
            keys[2] = .{ .symbol = "stack-trace" };
            try ctx.stack.push(.{ .array = keys });
        },
        else => return error.TypeError,
    }
}

/// @values ( assoc -- array ) - Get all values (polymorphic on hash, mmap, error)
fn nativeAtValues(ctx: *Context) anyerror!void {
    const obj = try ctx.stack.pop();

    switch (obj) {
        .hash => |h| {
            const alloc = ctx.quotationAllocator();
            const values = alloc.alloc(Value, h.count()) catch return error.OutOfMemory;
            var iter = h.iterator();
            var i: usize = 0;
            while (iter.next()) |entry| {
                values[i] = entry.value_ptr.*;
                i += 1;
            }
            try ctx.stack.push(.{ .array = values });
        },
        .mutable_map => |m| {
            const alloc = ctx.quotationAllocator();
            const values = alloc.alloc(Value, m.count()) catch return error.OutOfMemory;
            var iter = m.iterator();
            var i: usize = 0;
            while (iter.next()) |entry| {
                values[i] = entry.value_ptr.*;
                i += 1;
            }
            try ctx.stack.push(.{ .array = values });
        },
        .error_value => |err| {
            // Get all three error field values
            const alloc = ctx.quotationAllocator();
            const values = alloc.alloc(Value, 3) catch return error.OutOfMemory;
            values[0] = .{ .string = err.error_type };
            values[1] = .{ .string = err.message };
            values[2] = try getErrorField(ctx, err, "stack-trace");
            try ctx.stack.push(.{ .array = values });
        },
        else => return error.TypeError,
    }
}

// =============================================================================
// Higher-Order Combinators
// =============================================================================

/// #each ( seq quot -- ) - Execute quotation for each element
fn nativeEach(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    var iter = SequenceIterator.init(seq, alloc) orelse return error.TypeError;
    while (try iter.next()) |elem| {
        try ctx.stack.push(elem);
        try ctx.executeQuotation(quot);
    }
}

/// #map ( seq quot -- seq' ) - Transform each element of sequence
/// Note: string and byte_array map to array; others preserve type
fn nativeMap(ctx: *Context) anyerror!void {
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
        try ctx.executeQuotation(quot);
        const mapped = try ctx.stack.pop();
        try builder.append(mapped);
    }

    try ctx.stack.push(try builder.toValue());
}

/// #filter ( seq quot -- seq' ) - Keep elements where quotation returns true
fn nativeFilter(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    const kind = classifySequence(seq) orelse return error.TypeError;
    var iter = SequenceIterator.init(seq, alloc) orelse return error.TypeError;
    var builder = try SequenceBuilder.init(kind, alloc);

    while (try iter.next()) |elem| {
        try ctx.stack.push(elem);
        try ctx.executeQuotation(quot);
        const predicate = try popBoolean(ctx);
        if (predicate) {
            try builder.append(elem);
        }
    }

    try ctx.stack.push(try builder.toValue());
}

/// #reduce ( seq init quot -- result ) - Fold sequence with accumulator
fn nativeReduce(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    var acc = try ctx.stack.pop(); // initial accumulator
    const seq = try ctx.stack.pop();
    const alloc = ctx.quotationAllocator();

    var iter = SequenceIterator.init(seq, alloc) orelse return error.TypeError;
    while (try iter.next()) |elem| {
        try ctx.stack.push(acc);
        try ctx.stack.push(elem);
        try ctx.executeQuotation(quot);
        acc = try ctx.stack.pop();
    }
    try ctx.stack.push(acc);
}

/// #slice ( seq start end -- subseq ) - Extract subsequence [start, end)
fn nativeSlice(ctx: *Context) anyerror!void {
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
fn nativeAppend(ctx: *Context) anyerror!void {
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

/// Helper to get items slice from array or vector (no allocation needed)
fn getSequenceItems(seq: Value) ?[]const Value {
    return switch (seq) {
        .array => |arr| arr,
        .vector => |vec| vec.items,
        else => null,
    };
}

/// #append! ( vec seq -- vec ) - Mutably append sequence elements to vector
fn nativeAppendMut(ctx: *Context) anyerror!void {
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
fn nativePrepend(ctx: *Context) anyerror!void {
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

/// #push! ( vec elem -- vec ) - Append element to vector, mutate in place
fn nativePushMut(ctx: *Context) anyerror!void {
    const elem = try ctx.stack.pop();
    const vec = try popVector(ctx);

    vec.append(ctx.quotationAllocator(), elem) catch return error.OutOfMemory;

    try ctx.stack.push(.{ .vector = vec });
}

/// #pop! ( vec -- elem ) - Remove and return last element from vector
fn nativePopMut(ctx: *Context) anyerror!void {
    const vec = try popVector(ctx);

    if (vec.items.len == 0) {
        return error.EmptySequence;
    }

    const elem = vec.pop().?; // Safe: we checked len > 0
    try ctx.stack.push(elem);
}

// =============================================================================
// Stream I/O primitives
// =============================================================================

/// stdin ( -- stream ) - Push standard input stream
fn nativeStdin(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const stream = alloc.create(Stream) catch return error.OutOfMemory;
    stream.* = Stream{
        .file = std.fs.File.stdin(),
        .mode = .read,
        .name = "stdin",
        .buffering = .line,
    };
    try ctx.stack.push(.{ .stream = stream });
}

/// stdout ( -- stream ) - Push standard output stream
fn nativeStdout(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const stream = alloc.create(Stream) catch return error.OutOfMemory;
    stream.* = Stream{
        .file = std.fs.File.stdout(),
        .mode = .write,
        .name = "stdout",
        .buffering = .line,
    };
    try ctx.stack.push(.{ .stream = stream });
}

/// stderr ( -- stream ) - Push standard error stream
fn nativeStderr(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const stream = alloc.create(Stream) catch return error.OutOfMemory;
    stream.* = Stream{
        .file = std.fs.File.stderr(),
        .mode = .write,
        .name = "stderr",
        .buffering = .line,
    };
    try ctx.stack.push(.{ .stream = stream });
}

/// stream-open ( path mode -- stream ) - Open a file stream
/// Mode symbols: read: write: append: read-write:
fn nativeStreamOpen(ctx: *Context) anyerror!void {
    const mode_sym = try popSymbol(ctx);
    const path = try popString(ctx);
    const alloc = ctx.quotationAllocator();

    // Parse mode symbol
    const mode: StreamMode = if (std.mem.eql(u8, mode_sym, "read"))
        .read
    else if (std.mem.eql(u8, mode_sym, "write"))
        .write
    else if (std.mem.eql(u8, mode_sym, "append"))
        .append
    else if (std.mem.eql(u8, mode_sym, "read-write"))
        .read_write
    else
        return error.TypeError;

    // Open file based on mode
    const file = switch (mode) {
        .read => std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| {
            return mapFileOpenError(err);
        },
        .write => std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
            return mapFileCreateError(err);
        },
        .append => blk: {
            const f = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch |open_err| {
                // File doesn't exist, create it
                if (open_err == error.FileNotFound) {
                    break :blk std.fs.cwd().createFile(path, .{}) catch |err| {
                        return mapFileCreateError(err);
                    };
                }
                return mapFileOpenError(open_err);
            };
            // Seek to end for append mode
            f.seekFromEnd(0) catch return error.IOError;
            break :blk f;
        },
        .read_write => blk: {
            break :blk std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| {
                // Try creating if doesn't exist
                if (err == error.FileNotFound) {
                    break :blk std.fs.cwd().createFile(path, .{ .read = true }) catch |create_err| {
                        return mapFileCreateError(create_err);
                    };
                }
                return mapFileOpenError(err);
            };
        },
    };

    // Create stream object
    const stream = alloc.create(Stream) catch return error.OutOfMemory;
    const name_copy = alloc.dupe(u8, path) catch return error.OutOfMemory;
    stream.* = Stream{
        .file = file,
        .mode = mode,
        .name = name_copy,
    };
    try ctx.stack.push(.{ .stream = stream });
}

/// stream-close ( stream -- ) - Close a stream
fn nativeStreamClose(ctx: *Context) anyerror!void {
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    // Don't actually close stdin/stdout/stderr
    if (std.mem.eql(u8, stream.name, "stdin") or
        std.mem.eql(u8, stream.name, "stdout") or
        std.mem.eql(u8, stream.name, "stderr"))
    {
        stream.closed = true;
        return;
    }

    stream.file.close();
    stream.closed = true;
}

// =============================================================================
// Stream writing primitives
// =============================================================================

/// stream-write ( stream bytes -- n ) - Write bytes to stream, return count written
fn nativeStreamWrite(ctx: *Context) anyerror!void {
    const bytes_val = try ctx.stack.pop();
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    // Get bytes to write - accept byte arrays or strings
    const bytes: []const u8 = switch (bytes_val) {
        .byte_array => |ba| ba.items,
        .string => |s| s,
        else => return error.TypeError,
    };

    // Write to file
    const written = stream.file.write(bytes) catch |err| {
        return mapFileWriteError(err);
    };

    try ctx.stack.push(.{ .integer = @intCast(written) });
}

/// stream-flush ( stream -- ) - Flush stream buffer
fn nativeStreamFlush(ctx: *Context) anyerror!void {
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    // Note: Zig's std.fs.File doesn't have a direct flush method for unbuffered I/O
    // For buffered streams, we'd need to sync. For now, use sync for file streams.
    // Standard streams (stdout/stderr) are typically line-buffered or unbuffered.
    if (!std.mem.eql(u8, stream.name, "stdin") and
        !std.mem.eql(u8, stream.name, "stdout") and
        !std.mem.eql(u8, stream.name, "stderr"))
    {
        stream.file.sync() catch |err| {
            return mapFileSyncError(err);
        };
    }
}

// =============================================================================
// Stream reading primitives
// =============================================================================

/// stream-read ( stream n -- bytes ) - Read up to n bytes from stream
fn nativeStreamRead(ctx: *Context) anyerror!void {
    const n = try popInteger(ctx);
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    if (n < 0) {
        return error.InvalidArgument;
    }

    const alloc = ctx.quotationAllocator();
    const buffer = alloc.alloc(u8, @intCast(n)) catch return error.OutOfMemory;
    defer alloc.free(buffer);

    const bytes_read = stream.file.read(buffer) catch |err| {
        return mapFileReadError(err);
    };

    const ba = alloc.create(ByteArray) catch return error.OutOfMemory;
    ba.* = ByteArray{};
    ba.ensureTotalCapacity(alloc, bytes_read) catch return error.OutOfMemory;
    for (buffer[0..bytes_read]) |byte| {
        ba.appendAssumeCapacity(byte);
    }

    try ctx.stack.push(.{ .byte_array = ba });
}

/// stream-read-line ( stream -- str/f ) - Read line (no newline), f at EOF
fn nativeStreamReadLine(ctx: *Context) anyerror!void {
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    const alloc = ctx.quotationAllocator();
    var line_buf: std.ArrayListUnmanaged(u8) = .{};
    defer line_buf.deinit(alloc);

    while (true) {
        var byte_buf: [1]u8 = undefined;
        const bytes_read = stream.file.read(&byte_buf) catch |err| {
            return mapFileReadError(err);
        };

        if (bytes_read == 0) {
            // No data read at all, return false for EOF
            if (line_buf.items.len == 0) {
                try ctx.stack.push(.{ .boolean = false });
                return;
            }
            // Return what we have; last line without newline
            break;
        }

        const byte = byte_buf[0];
        if (byte == '\n') {
            // End of line, sans newline
            break;
        }

        // Handle \r\n by skipping \r if followed by \n
        if (byte == '\r') {
            var peek_buf: [1]u8 = undefined;
            const peek_read = stream.file.read(&peek_buf) catch |err| {
                return mapFileReadError(err);
            };
            if (peek_read > 0 and peek_buf[0] == '\n') {
                break;
            }
            line_buf.append(alloc, '\r') catch return error.OutOfMemory;
            if (peek_read > 0) {
                if (peek_buf[0] == '\n') {
                    break;
                }
                line_buf.append(alloc, peek_buf[0]) catch return error.OutOfMemory;
            }
            continue;
        }

        line_buf.append(alloc, byte) catch return error.OutOfMemory;
    }

    const result = alloc.dupe(u8, line_buf.items) catch return error.OutOfMemory;
    try ctx.stack.push(.{ .string = result });
}

/// stream-read-all ( stream -- bytes ) - Read all remaining content
fn nativeStreamReadAll(ctx: *Context) anyerror!void {
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    const alloc = ctx.quotationAllocator();

    // TODO(ripta): 10 MB seems reasonable, right?
    const max_size: usize = 10 * 1024 * 1024;
    var content: std.ArrayListUnmanaged(u8) = .{};
    defer content.deinit(alloc);

    var buffer: [4096]u8 = undefined;
    while (true) {
        const bytes_read = stream.file.read(&buffer) catch |err| {
            return mapFileReadError(err);
        };

        // EOF?
        if (bytes_read == 0) {
            break;
        }

        if (content.items.len + bytes_read > max_size) {
            return error.OutOfMemory;
        }

        content.appendSlice(alloc, buffer[0..bytes_read]) catch return error.OutOfMemory;
    }

    const ba = alloc.create(ByteArray) catch return error.OutOfMemory;
    ba.* = ByteArray{};
    ba.ensureTotalCapacity(alloc, content.items.len) catch return error.OutOfMemory;
    for (content.items) |byte| {
        ba.appendAssumeCapacity(byte);
    }

    try ctx.stack.push(.{ .byte_array = ba });
}

// =============================================================================
// Stream positioning primitives
// =============================================================================

/// stream-tell ( stream -- pos ) - Get current stream position
fn nativeStreamTell(ctx: *Context) anyerror!void {
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    const pos = stream.file.getPos() catch |err| {
        return mapGetPosError(err);
    };

    try ctx.stack.push(.{ .integer = @intCast(pos) });
}

/// stream-seek ( stream pos -- ) - Seek to absolute position
fn nativeStreamSeek(ctx: *Context) anyerror!void {
    const pos = try popInteger(ctx);
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    if (pos < 0) {
        return error.InvalidArgument;
    }

    stream.file.seekTo(@intCast(pos)) catch |err| {
        return mapSeekError(err);
    };
}

/// stream-seek-end ( stream offset -- ) - Seek relative to end of stream
fn nativeStreamSeekEnd(ctx: *Context) anyerror!void {
    const offset = try popInteger(ctx);
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    stream.file.seekFromEnd(offset) catch |err| {
        return mapSeekError(err);
    };
}

// =============================================================================
// Buffering control primitives
// =============================================================================

/// buffering-mode ( stream -- symbol ) - Get stream buffering mode
fn nativeBufferingMode(ctx: *Context) anyerror!void {
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    try ctx.stack.push(.{ .symbol = stream.buffering.toSymbol() });
}

/// set-buffering-mode ( stream symbol -- ) - Set stream buffering mode
fn nativeSetBufferingMode(ctx: *Context) anyerror!void {
    const mode_sym = try popSymbol(ctx);
    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    const mode: BufferingMode = if (std.mem.eql(u8, mode_sym, "none"))
        .none
    else if (std.mem.eql(u8, mode_sym, "line"))
        .line
    else if (std.mem.eql(u8, mode_sym, "block"))
        .block
    else
        return error.InvalidArgument;

    stream.buffering = mode;
}

// =============================================================================
// Unix interop primitives
// =============================================================================

const builtin = @import("builtin");
const native_os = builtin.os.tag;

/// stream->fd ( stream -- int ) - Get file descriptor from stream (Unix only)
fn nativeStreamToFd(ctx: *Context) anyerror!void {
    if (native_os == .windows) {
        return error.UnsupportedOperation;
    }

    const stream = try popStream(ctx);
    try ensureStreamOpen(stream);

    const fd: i64 = @intCast(stream.file.handle);
    try ctx.stack.push(.{ .integer = fd });
}

/// fd->stream ( int mode -- stream ) - Create stream from file descriptor (Unix only)
fn nativeFdToStream(ctx: *Context) anyerror!void {
    if (native_os == .windows) {
        return error.UnsupportedOperation;
    }

    const mode_sym = try popSymbol(ctx);
    const fd_val = try popInteger(ctx);

    if (fd_val < 0) {
        return error.InvalidArgument;
    }

    const mode: StreamMode = if (std.mem.eql(u8, mode_sym, "read"))
        .read
    else if (std.mem.eql(u8, mode_sym, "write"))
        .write
    else if (std.mem.eql(u8, mode_sym, "append"))
        .append
    else if (std.mem.eql(u8, mode_sym, "read-write"))
        .read_write
    else
        return error.InvalidArgument;

    const alloc = ctx.quotationAllocator();
    const stream = alloc.create(Stream) catch return error.OutOfMemory;
    stream.* = Stream{
        .file = std.fs.File{ .handle = @intCast(fd_val) },
        .mode = mode,
        .name = "fd",
    };
    try ctx.stack.push(.{ .stream = stream });
}

// =============================================================================
// Character conversion primitives
// =============================================================================

/// >char ( codepoint -- str ) - Convert Unicode codepoint to single-character string
fn nativeChr(ctx: *Context) anyerror!void {
    const codepoint_val = try popInteger(ctx);
    if (codepoint_val < 0 or codepoint_val > 0x10FFFF) {
        return error.InvalidArgument;
    }

    const codepoint: u21 = @intCast(codepoint_val);
    if (codepoint >= 0xD800 and codepoint <= 0xDFFF) {
        return error.InvalidArgument;
    }

    const alloc = ctx.quotationAllocator();
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidArgument;

    const str = alloc.dupe(u8, buf[0..len]) catch return error.OutOfMemory;
    try ctx.stack.push(.{ .string = str });
}

/// >codepoint ( str -- int ) - Convert single-character string to Unicode codepoint
fn nativeToCodepoint(ctx: *Context) anyerror!void {
    const str = try popString(ctx);
    var iter = std.unicode.Utf8Iterator{ .bytes = str, .i = 0 };
    const first_codepoint = iter.nextCodepoint() orelse {
        return error.InvalidArgument;
    };

    if (iter.nextCodepoint() != null) {
        return error.InvalidArgument;
    }

    try ctx.stack.push(.{ .integer = @intCast(first_codepoint) });
}

// =============================================================================
// Dynamic Variables (Parameters) - Parse-time primitives
// =============================================================================

/// parse-quotation ( -- quotation ) - Read the next [ ... ] block from the tokenizer
/// Can only be called during parse-time execution (when tokenizer is available)
fn nativeParseQuotation(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer orelse return error.NoTokenizerAvailable;

    // Skip whitespace/comments until we find '['
    while (tokenizer.next()) |tok| {
        if (tok.kind == .comment or tok.kind == .newline) continue;

        if (!std.mem.eql(u8, tok.text, "[")) {
            // Expected '[' but got something else
            return error.TypeError;
        }

        // Found '[', now parse the quotation body
        const quot = parser.parseQuotation(ctx.quotationAllocator(), tokenizer, ctx) catch return error.OutOfMemory;
        try ctx.stack.push(.{ .quotation = quot });
        return;
    }

    // Unexpected end of input
    return error.TypeError;
}

// =============================================================================
// Dynamic Variables (Parameters) - Runtime primitives
// =============================================================================

/// make-parameter ( name: quot -- param ) - Create a parameter with the given name and default quotation
fn nativeMakeParameter(ctx: *Context) anyerror!void {
    const default_quot = try popQuotation(ctx);
    const name = try popSymbol(ctx);

    const alloc = ctx.quotationAllocator();
    const param = alloc.create(Parameter) catch return error.OutOfMemory;
    param.* = .{
        .name = alloc.dupe(u8, name) catch return error.OutOfMemory,
        .default_quotation = default_quot,
    };

    try ctx.stack.push(.{ .parameter = param });
}

/// get ( param -- value ) - Get the current value of a parameter
/// Searches environment frames from top to bottom; if not found, evaluates default quotation
fn nativeGet(ctx: *Context) anyerror!void {
    const param_val = try ctx.stack.pop();
    const param = switch (param_val) {
        .parameter => |p| p,
        else => return error.TypeError,
    };

    // Search frames from top (innermost) to bottom (outermost)
    if (ctx.getParameterBinding(param.name)) |bound_value| {
        try ctx.stack.push(bound_value);
    } else {
        // No binding found - evaluate default quotation
        // The result is left on the stack by the quotation
        try ctx.executeQuotation(param.default_quotation);
    }
}

/// with-parameter ( value param quot -- ... ) - Execute quotation with parameter temporarily bound
/// The parameter binding is restored even if the quotation throws an error
fn nativeWithParameter(ctx: *Context) anyerror!void {
    const body_quot = try popQuotation(ctx);
    const param_val = try ctx.stack.pop();
    const param = switch (param_val) {
        .parameter => |p| p,
        else => return error.TypeError,
    };
    const new_value = try ctx.stack.pop();

    // Push new frame with binding
    try ctx.pushParameterFrame();
    try ctx.setParameterInTopFrame(param.name, new_value);

    // Execute body with cleanup (pops frame even on error)
    const result = ctx.executeQuotation(body_quot);
    ctx.popParameterFrame();
    try result;
}

// =============================================================================
// Tests
// =============================================================================

test "dup" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 42 });
    try nativeDup(&ctx);

    try std.testing.expectEqual(@as(usize, 2), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 42), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 42), (try ctx.stack.pop()).integer);
}

test "drop" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 1 });
    try ctx.stack.push(.{ .integer = 2 });
    try nativeDrop(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).integer);
}

test "swap" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 1 });
    try ctx.stack.push(.{ .integer = 2 });
    try nativeSwap(&ctx);

    try std.testing.expectEqual(@as(usize, 2), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 2), (try ctx.stack.pop()).integer);
}

test "over" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 1 });
    try ctx.stack.push(.{ .integer = 2 });
    try nativeOver(&ctx);

    try std.testing.expectEqual(@as(usize, 3), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 2), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).integer);
}

test "dip executes quotation with top item hidden" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Stack: 10 20, then dip with [ 1 + ]
    // Should: hide 20, execute [ 1 + ] on 10 -> 11, restore 20
    // Result: 11 20
    const quot = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .integer = 1 } }, .line = 0 },
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    try ctx.stack.push(.{ .integer = 10 });
    try ctx.stack.push(.{ .integer = 20 });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &quot } });
    try nativeDip(&ctx);

    try std.testing.expectEqual(@as(usize, 2), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 20), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 11), (try ctx.stack.pop()).integer);
}

test "dip with empty quotation" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Stack: 1 2, dip with [ ] should just restore 2
    const quot = [_]Instruction{};
    try ctx.stack.push(.{ .integer = 1 });
    try ctx.stack.push(.{ .integer = 2 });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &quot } });
    try nativeDip(&ctx);

    try std.testing.expectEqual(@as(usize, 2), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 2), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).integer);
}

test "dip with quotation that pushes multiple values" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Stack: 5, dip with [ 1 2 3 ]
    // Should: hide 5, push 1 2 3, restore 5
    // Result: 1 2 3 5
    const quot = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .integer = 1 } }, .line = 0 },
        .{ .op = .{ .push_literal = .{ .integer = 2 } }, .line = 0 },
        .{ .op = .{ .push_literal = .{ .integer = 3 } }, .line = 0 },
    };
    try ctx.stack.push(.{ .integer = 5 });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &quot } });
    try nativeDip(&ctx);

    try std.testing.expectEqual(@as(usize, 4), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 5), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 3), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 2), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).integer);
}

test "wipe" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 1 });
    try ctx.stack.push(.{ .integer = 2 });
    try ctx.stack.push(.{ .integer = 3 });
    try nativeWipe(&ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
}

test "wipe empty stack" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try nativeWipe(&ctx);
    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
}

test "add" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 3 });
    try ctx.stack.push(.{ .integer = 4 });
    try nativeAdd(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 7), (try ctx.stack.pop()).integer);
}

test "add overflow" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = std.math.maxInt(i64) });
    try ctx.stack.push(.{ .integer = 1 });

    const result = nativeAdd(&ctx);
    try std.testing.expectError(error.IntegerOverflow, result);
}

test "sub" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 10 });
    try ctx.stack.push(.{ .integer = 3 });
    try nativeSub(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 7), (try ctx.stack.pop()).integer);
}

test "sub overflow" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = std.math.minInt(i64) });
    try ctx.stack.push(.{ .integer = 1 });

    const result = nativeSub(&ctx);
    try std.testing.expectError(error.IntegerOverflow, result);
}

test "mul" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 3 });
    try ctx.stack.push(.{ .integer = 4 });
    try nativeMul(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 12), (try ctx.stack.pop()).integer);
}

test "mul overflow" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = std.math.maxInt(i64) });
    try ctx.stack.push(.{ .integer = 2 });

    const result = nativeMul(&ctx);
    try std.testing.expectError(error.IntegerOverflow, result);
}

test "div" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 10 });
    try ctx.stack.push(.{ .integer = 3 });
    try nativeDiv(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 3), (try ctx.stack.pop()).integer);
}

test "div by zero" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 10 });
    try ctx.stack.push(.{ .integer = 0 });

    const result = nativeDiv(&ctx);
    try std.testing.expectError(error.DivisionByZero, result);
}

test "div overflow" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // MIN_INT / -1 would overflow because -MIN_INT > MAX_INT
    try ctx.stack.push(.{ .integer = std.math.minInt(i64) });
    try ctx.stack.push(.{ .integer = -1 });

    const result = nativeDiv(&ctx);
    try std.testing.expectError(error.IntegerOverflow, result);
}

test "mod" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 10 });
    try ctx.stack.push(.{ .integer = 3 });
    try nativeMod(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).integer);
}

test "mod by zero" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 10 });
    try ctx.stack.push(.{ .integer = 0 });

    const result = nativeMod(&ctx);
    try std.testing.expectError(error.DivisionByZero, result);
}

test "+% wrapping addition" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // MAX_INT +w 1 should wrap to MIN_INT
    try ctx.stack.push(.{ .integer = std.math.maxInt(i64) });
    try ctx.stack.push(.{ .integer = 1 });
    try nativeAddWrap(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(std.math.minInt(i64), (try ctx.stack.pop()).integer);
}

test "-% wrapping subtraction" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // MIN_INT -w 1 should wrap to MAX_INT
    try ctx.stack.push(.{ .integer = std.math.minInt(i64) });
    try ctx.stack.push(.{ .integer = 1 });
    try nativeSubWrap(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(std.math.maxInt(i64), (try ctx.stack.pop()).integer);
}

test "*% wrapping multiplication" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // MAX_INT *w 2 should wrap
    try ctx.stack.push(.{ .integer = std.math.maxInt(i64) });
    try ctx.stack.push(.{ .integer = 2 });
    try nativeMulWrap(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, -2), (try ctx.stack.pop()).integer);
}

test "call executes quotation" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .integer = 1 } }, .line = 0 },
        .{ .op = .{ .push_literal = .{ .integer = 2 } }, .line = 0 },
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    try ctx.stack.push(.{ .quotation = .{ .instructions = &instrs } });
    try nativeCall(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 3), (try ctx.stack.pop()).integer);
}

test "semicolon defines word" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .integer = 2 } }, .line = 0 },
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    try ctx.stack.push(.{ .symbol = "add2" });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &instrs } });
    try nativeSemicolon(&ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
    const word = ctx.dictionary.get("add2");
    try std.testing.expect(word != null);
    try std.testing.expect(word.?.stack_effect == null);
}

test "semicolon defines word with stack effect" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .integer = 2 } }, .line = 0 },
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    try ctx.stack.push(.{ .symbol = "add2" });
    try ctx.stack.push(.{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    } });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &instrs } });
    try nativeSemicolon(&ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
    const word = ctx.dictionary.get("add2");
    try std.testing.expect(word != null);
    try std.testing.expect(word.?.stack_effect != null);
    try std.testing.expectEqual(@as(usize, 1), word.?.stack_effect.?.inputs.len);
    try std.testing.expectEqualStrings("n", word.?.stack_effect.?.inputs[0].name);
}

test "if true branch" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const true_quot = [_]Instruction{.{ .op = .{ .push_literal = .{ .integer = 1 } }, .line = 0 }};
    const false_quot = [_]Instruction{.{ .op = .{ .push_literal = .{ .integer = 2 } }, .line = 0 }};
    try ctx.stack.push(.{ .boolean = true });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &true_quot } });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &false_quot } });
    try nativeIf(&ctx);

    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).integer);
}

test "if false branch" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const true_quot = [_]Instruction{.{ .op = .{ .push_literal = .{ .integer = 1 } }, .line = 0 }};
    const false_quot = [_]Instruction{.{ .op = .{ .push_literal = .{ .integer = 2 } }, .line = 0 }};
    try ctx.stack.push(.{ .boolean = false });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &true_quot } });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &false_quot } });
    try nativeIf(&ctx);

    try std.testing.expectEqual(@as(i64, 2), (try ctx.stack.pop()).integer);
}

test "comparison operators" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 5 });
    try ctx.stack.push(.{ .integer = 5 });
    try nativeEq(&ctx);
    try std.testing.expectEqual(true, (try ctx.stack.pop()).boolean);

    try ctx.stack.push(.{ .integer = 3 });
    try ctx.stack.push(.{ .integer = 5 });
    try nativeLt(&ctx);
    try std.testing.expectEqual(true, (try ctx.stack.pop()).boolean);

    try ctx.stack.push(.{ .integer = 5 });
    try ctx.stack.push(.{ .integer = 3 });
    try nativeGt(&ctx);
    try std.testing.expectEqual(true, (try ctx.stack.pop()).boolean);
}

test "register primitives" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var dict = Dictionary.init(allocator);
    defer dict.deinit();

    try registerPrimitives(&dict, arena.allocator());

    try std.testing.expect(dict.get("dup") != null);
    try std.testing.expect(dict.get("drop") != null);
    try std.testing.expect(dict.get("swap") != null);
    try std.testing.expect(dict.get("over") != null);
    try std.testing.expect(dict.get("dip") != null);
    try std.testing.expect(dict.get("wipe") != null);
    try std.testing.expect(dict.get("+") != null);
    try std.testing.expect(dict.get("-") != null);
    try std.testing.expect(dict.get("*") != null);
    try std.testing.expect(dict.get("/") != null);
    try std.testing.expect(dict.get("%") != null);
    try std.testing.expect(dict.get("+%") != null);
    try std.testing.expect(dict.get("-%") != null);
    try std.testing.expect(dict.get("*%") != null);
    try std.testing.expect(dict.get("call") != null);
    try std.testing.expect(dict.get(";") != null);
    try std.testing.expect(dict.get("if") != null);
    try std.testing.expect(dict.get("to-string") != null);
    try std.testing.expect(dict.get("recover") != null);
    try std.testing.expect(dict.get("cleanup") != null);
    try std.testing.expect(dict.get("rethrow") != null);
    try std.testing.expect(dict.get("curry") != null);
    try std.testing.expect(dict.get("compose") != null);
}

test "recover catches error and executes recovery" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Try quotation that causes stack underflow, recovery pushes 42
    const try_quot = [_]Instruction{.{ .op = .{ .call_word = "drop" }, .line = 0 }}; // Stack underflow
    const recover_quot = [_]Instruction{
        .{ .op = .{ .call_word = "drop" }, .line = 0 }, // Drop the error value
        .{ .op = .{ .push_literal = .{ .integer = 42 } }, .line = 0 },
    };
    try ctx.stack.push(.{ .quotation = .{ .instructions = &try_quot } });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &recover_quot } });
    try nativeRecover(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 42), (try ctx.stack.pop()).integer);
}

test "recover succeeds without error" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Try quotation succeeds
    const try_quot = [_]Instruction{.{ .op = .{ .push_literal = .{ .integer = 100 } }, .line = 0 }};
    const recover_quot = [_]Instruction{.{ .op = .{ .push_literal = .{ .integer = 42 } }, .line = 0 }};
    try ctx.stack.push(.{ .quotation = .{ .instructions = &try_quot } });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &recover_quot } });
    try nativeRecover(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 100), (try ctx.stack.pop()).integer);
}

test "recover pushes error value on failure" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Try quotation fails, recovery just leaves error on stack
    const try_quot = [_]Instruction{.{ .op = .{ .call_word = "drop" }, .line = 0 }}; // Stack underflow
    const recover_quot = [_]Instruction{}; // Do nothing, leave error on stack
    try ctx.stack.push(.{ .quotation = .{ .instructions = &try_quot } });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &recover_quot } });
    try nativeRecover(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const val = try ctx.stack.pop();

    try std.testing.expectEqualStrings("StackUnderflow", val.error_value.error_type);
    try std.testing.expectEqualStrings("StackUnderflow", val.error_value.message);

    try std.testing.expect(val.error_value.stack_trace != null);
    try std.testing.expectEqual(@as(usize, 1), val.error_value.stack_trace.?.len);
    try std.testing.expectEqualStrings("drop", val.error_value.stack_trace.?[0].word_name);
}

test "cleanup runs on success" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Body pushes 10, cleanup pushes 20
    const body_quot = [_]Instruction{.{ .op = .{ .push_literal = .{ .integer = 10 } }, .line = 0 }};
    const cleanup_quot = [_]Instruction{.{ .op = .{ .push_literal = .{ .integer = 20 } }, .line = 0 }};
    try ctx.stack.push(.{ .quotation = .{ .instructions = &body_quot } });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &cleanup_quot } });
    try nativeCleanup(&ctx);

    // Both should have run: stack has 10, then 20
    try std.testing.expectEqual(@as(usize, 2), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 20), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 10), (try ctx.stack.pop()).integer);
}

test "cleanup runs on error and rethrows" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Body fails (stack underflow), cleanup pushes 99
    const body_quot = [_]Instruction{.{ .op = .{ .call_word = "drop" }, .line = 0 }};
    const cleanup_quot = [_]Instruction{.{ .op = .{ .push_literal = .{ .integer = 99 } }, .line = 0 }};
    try ctx.stack.push(.{ .quotation = .{ .instructions = &body_quot } });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &cleanup_quot } });

    // cleanup should rethrow the error
    const result = nativeCleanup(&ctx);
    try std.testing.expectError(error.StackUnderflow, result);

    // But cleanup should have run - 99 is on the stack
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 99), (try ctx.stack.pop()).integer);
}

test "cleanup error is suppressed if body fails" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Both body and cleanup fail
    const body_quot = [_]Instruction{.{ .op = .{ .call_word = "drop" }, .line = 0 }};
    const cleanup_quot = [_]Instruction{.{ .op = .{ .call_word = "drop" }, .line = 0 }};
    try ctx.stack.push(.{ .quotation = .{ .instructions = &body_quot } });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &cleanup_quot } });

    // Body error should be rethrown (cleanup error suppressed)
    const result = nativeCleanup(&ctx);
    try std.testing.expectError(error.StackUnderflow, result);
}

test "rethrow re-raises error value" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Create an error object and push it
    const error_obj = ErrorObject{
        .error_type = "StackUnderflow",
        .message = "StackUnderflow",
        .stack_trace = null,
    };
    try ctx.stack.push(.{ .error_value = error_obj });

    // rethrow should return RethrowError
    const result = nativeRethrow(&ctx);
    try std.testing.expectError(error.RethrowError, result);
}

test "rethrow restores stack trace" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Create an error object with stack trace
    const frames = [_]StackFrame{
        .{ .word_name = "inner", .line = 10 },
        .{ .word_name = "outer", .line = 20 },
    };
    const error_obj = ErrorObject{
        .error_type = "TestError",
        .message = "test message",
        .stack_trace = &frames,
    };
    try ctx.stack.push(.{ .error_value = error_obj });

    // rethrow should restore error_details
    _ = nativeRethrow(&ctx) catch {};

    // Check that error_details were restored
    try std.testing.expectEqual(@as(usize, 2), ctx.error_details.items.len);
    try std.testing.expectEqualStrings("inner", ctx.error_details.items[0].word_name.?);
    try std.testing.expectEqual(@as(usize, 10), ctx.error_details.items[0].line);
    try std.testing.expectEqualStrings("outer", ctx.error_details.items[1].word_name.?);
    try std.testing.expectEqual(@as(usize, 20), ctx.error_details.items[1].line);
}

test "rethrow fails on non-error value" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Push a non-error value
    try ctx.stack.push(.{ .integer = 42 });

    // rethrow should return TypeError
    const result = nativeRethrow(&ctx);
    try std.testing.expectError(error.TypeError, result);
}

test "parse-time pushes marker onto stack" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try nativeParseTime(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const val = try ctx.stack.pop();
    try std.testing.expectEqual(Value.parse_time_marker, std.meta.activeTag(val));
}

test "semicolon defines parse-time word when marker is present" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .integer = 42 } }, .line = 0 },
    };
    // Stack: symbol, parse-time marker, quotation
    try ctx.stack.push(.{ .symbol = "my-macro" });
    try ctx.stack.push(.{ .parse_time_marker = {} });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &instrs } });
    try nativeSemicolon(&ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
    const word = ctx.dictionary.get("my-macro");
    try std.testing.expect(word != null);
    try std.testing.expectEqual(true, word.?.parse_time);
}

test "semicolon defines non-parse-time word by default" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .integer = 42 } }, .line = 0 },
    };
    // Stack: symbol, quotation (no parse-time marker)
    try ctx.stack.push(.{ .symbol = "regular-word" });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &instrs } });
    try nativeSemicolon(&ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
    const word = ctx.dictionary.get("regular-word");
    try std.testing.expect(word != null);
    try std.testing.expectEqual(false, word.?.parse_time);
}

test "semicolon defines parse-time word with stack effect" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .integer = 42 } }, .line = 0 },
    };
    // Stack: symbol, parse-time marker, stack effect, quotation
    try ctx.stack.push(.{ .symbol = "my-macro" });
    try ctx.stack.push(.{ .parse_time_marker = {} });
    try ctx.stack.push(.{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{},
        .outputs = &[_]StackEffectParam{.{ .name = "x" }},
    } });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &instrs } });
    try nativeSemicolon(&ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
    const word = ctx.dictionary.get("my-macro");
    try std.testing.expect(word != null);
    try std.testing.expectEqual(true, word.?.parse_time);
    try std.testing.expect(word.?.stack_effect != null);
    try std.testing.expectEqual(@as(usize, 0), word.?.stack_effect.?.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), word.?.stack_effect.?.outputs.len);
}

test "parse-until reads tokens until delimiter" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Set up a tokenizer as if we're in parse-time context
    var tokenizer = Tokenizer.init("1 2 + }");
    ctx.parse_tokenizer = &tokenizer;

    // Push the delimiter
    try ctx.stack.push(.{ .string = "}" });

    // Call parse-until
    try nativeParseUntil(&ctx);

    // Should have a quotation on the stack
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const val = try ctx.stack.pop();
    try std.testing.expectEqual(Value.quotation, std.meta.activeTag(val));

    // The quotation should contain: push 1, push 2, call +
    const quot = val.quotation;
    try std.testing.expectEqual(@as(usize, 3), quot.instructions.len);
    try std.testing.expectEqual(@as(i64, 1), quot.instructions[0].op.push_literal.integer);
    try std.testing.expectEqual(@as(i64, 2), quot.instructions[1].op.push_literal.integer);
    try std.testing.expectEqualStrings("+", quot.instructions[2].op.call_word);
}

test "parse-until with empty content" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Set up a tokenizer with just the delimiter
    var tokenizer = Tokenizer.init("}");
    ctx.parse_tokenizer = &tokenizer;

    // Push the delimiter
    try ctx.stack.push(.{ .string = "}" });

    // Call parse-until
    try nativeParseUntil(&ctx);

    // Should have an empty quotation on the stack
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const val = try ctx.stack.pop();
    const quot = val.quotation;
    try std.testing.expectEqual(@as(usize, 0), quot.instructions.len);
}

test "parse-until fails without tokenizer" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // No tokenizer set (parse_tokenizer is null)
    try ctx.stack.push(.{ .string = "}" });

    // Should fail with NoTokenizerAvailable
    const result = nativeParseUntil(&ctx);
    try std.testing.expectError(error.NoTokenizerAvailable, result);
}

test "curry prepends value to quotation" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // 3 5 [ + ] curry call should give 8
    // First create quotation [ + ]
    const quot = [_]Instruction{
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    try ctx.stack.push(.{ .integer = 3 }); // Will be on stack when curried quot runs
    try ctx.stack.push(.{ .integer = 5 }); // Value to curry
    try ctx.stack.push(.{ .quotation = .{ .instructions = &quot } });
    try nativeCurry(&ctx);

    // Now we have: 3 [ 5 + ]
    try std.testing.expectEqual(@as(usize, 2), ctx.stack.depth());

    // Call the curried quotation
    try nativeCall(&ctx);

    // Result: 8 (3 + 5)
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 8), (try ctx.stack.pop()).integer);
}

test "curry with empty quotation" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // 42 [ ] curry call should leave 42 on stack
    const quot = [_]Instruction{};
    try ctx.stack.push(.{ .integer = 42 });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &quot } });
    try nativeCurry(&ctx);
    try nativeCall(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 42), (try ctx.stack.pop()).integer);
}

test "compose concatenates quotations" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // 5 [ 2 * ] [ 3 + ] compose call should give 13 (5*2 + 3)
    const quot1 = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .integer = 2 } }, .line = 0 },
        .{ .op = .{ .call_word = "*" }, .line = 0 },
    };
    const quot2 = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .integer = 3 } }, .line = 0 },
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    try ctx.stack.push(.{ .integer = 5 });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &quot1 } });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &quot2 } });
    try nativeCompose(&ctx);

    // Now we have: 5 [ 2 * 3 + ]
    try std.testing.expectEqual(@as(usize, 2), ctx.stack.depth());

    // Call the composed quotation
    try nativeCall(&ctx);

    // Result: 13 (5 * 2 + 3)
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 13), (try ctx.stack.pop()).integer);
}

test "compose with empty quotations" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // [ ] [ ] compose should give [ ]
    const quot1 = [_]Instruction{};
    const quot2 = [_]Instruction{};
    try ctx.stack.push(.{ .quotation = .{ .instructions = &quot1 } });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &quot2 } });
    try nativeCompose(&ctx);

    const result = try ctx.stack.pop();
    try std.testing.expectEqual(@as(usize, 0), result.quotation.instructions.len);
}
