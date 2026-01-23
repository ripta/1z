const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Instruction = value_mod.Instruction;
const StackEffect = @import("../stack_effect.zig").StackEffect;
const WordDefinition = @import("../dictionary.zig").WordDefinition;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

const popQuotation = helpers.popQuotation;
const popBoolean = helpers.popBoolean;
const popSymbol = helpers.popSymbol;

pub const primitives = [_]Primitive{
    .{ .name = "call", .stack_effect = "quot --", .func = nativeCall },
    .{ .name = ";", .stack_effect = "name quot --", .func = nativeSemicolon },
    .{ .name = "t", .stack_effect = "-- t", .func = nativeTrue },
    .{ .name = "f", .stack_effect = "-- f", .func = nativeFalse },
    .{ .name = "if", .stack_effect = "? true-quot false-quot --", .func = nativeIf },
};

/// call ( quot -- ) - Execute a quotation
pub fn nativeCall(ctx: *Context) anyerror!void {
    const instrs = try popQuotation(ctx);
    try ctx.executeQuotation(instrs);
}

/// ; ( name: quot -- ) or ( name: value -- ) or ( name: ( effect ) quot -- ) or ( name: parse-time quot -- ) - Define a new word
/// Supports both quotation definitions (compound words) and value definitions (words that push a value)
pub fn nativeSemicolon(ctx: *Context) anyerror!void {
    const top_val = try ctx.stack.pop();

    // Check for optional metadata (stack effect and/or parse-time marker)
    // Stack could be: symbol quot
    //            or: symbol value
    //            or: symbol stack-effect quot
    //            or: symbol parse-time quot
    //            or: symbol parse-time stack-effect quot
    var stack_effect_val: ?StackEffect = null;
    var is_parse_time = false;

    // Loop to collect metadata until we find the symbol
    while (true) {
        const next_val = try ctx.stack.peek();
        switch (next_val) {
            .stack_effect => |se| {
                _ = try ctx.stack.pop();
                stack_effect_val = se;
            },
            .parse_time_marker => {
                _ = try ctx.stack.pop();
                is_parse_time = true;
            },
            .symbol => break, // Found the name, stop
            else => return error.TypeError, // Invalid definition syntax
        }
    }

    const name = try popSymbol(ctx);
    const alloc = ctx.quotationAllocator();
    // Copy name to arena so it persists after input buffer is reused
    const name_copy = try alloc.dupe(u8, name);

    // Handle different value types
    const instructions = switch (top_val) {
        .quotation => |quot| quot.instructions,
        else => blk: {
            // Value definition - create a word that pushes the value
            const push_instr = try alloc.alloc(Instruction, 1);
            push_instr[0] = .{ .op = .{ .push_literal = top_val }, .line = 0 };
            break :blk push_instr;
        },
    };

    try ctx.dictionary.put(name_copy, WordDefinition{
        .name = name_copy,
        .parse_time = is_parse_time,
        .stack_effect = stack_effect_val,
        .action = .{ .compound = instructions },
    });
}

pub fn nativeTrue(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .boolean = true });
}

pub fn nativeFalse(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .boolean = false });
}

/// if ( ? true-quot false-quot -- ) - Conditional execution
pub fn nativeIf(ctx: *Context) anyerror!void {
    const false_quot = try popQuotation(ctx);
    const true_quot = try popQuotation(ctx);
    const cond = try popBoolean(ctx);
    try ctx.executeQuotation(if (cond) true_quot else false_quot);
}
