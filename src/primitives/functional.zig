const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Instruction = value_mod.Instruction;
const HashTable = value_mod.HashTable;
const BenchmarkStats = @import("../benchmark.zig").BenchmarkStats;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

const popQuotation = helpers.popQuotation;

pub const primitives = [_]Primitive{
    .{ .name = "curry", .stack_effect = "x quot -- quot'", .func = nativeCurry },
    .{ .name = "compose", .stack_effect = "quot1 quot2 -- quot'", .func = nativeCompose },
    .{ .name = "benchmark", .stack_effect = "quot -- hash", .func = nativeBenchmark },
};

/// curry ( x quot -- quot' ) - Partially apply a value to a quotation
/// Example: 5 [ + ] curry creates [ 5 + ]
pub fn nativeCurry(ctx: *Context) anyerror!void {
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
pub fn nativeCompose(ctx: *Context) anyerror!void {
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
pub fn nativeBenchmark(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);

    // Create temporary benchmark stats for this execution
    var local_stats = BenchmarkStats{};

    // Save and replace context benchmark pointer
    const saved_benchmark = ctx.benchmark;
    ctx.benchmark = &local_stats;

    // Time and execute
    const start_time = std.time.nanoTimestamp();
    const exec_result = ctx.executeQuotationWithFrame(quot);

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
