const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Instruction = value_mod.Instruction;
const Marker = value_mod.Marker;
const StackEffect = @import("../stack_effect.zig").StackEffect;
const WordDefinition = @import("../dictionary.zig").WordDefinition;
const markers_mod = @import("markers.zig");

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

/// call ( quot -- ) - Execute a quotation with a new local frame for scoping
pub fn nativeCall(ctx: *Context) anyerror!void {
    const instrs = try popQuotation(ctx);
    try ctx.executeQuotationWithFrame(instrs);
}

/// ; ( name: quot -- ) or ( name: value -- ) or ( name: marker -- ) - Define a new word
///
/// Polymorphic definition, depending on TOS type, with optional metadata:
///
/// - Quotation: define word
/// - Value: define word that pushes value, e.g., constant
/// - Marker: register as named marker
pub fn nativeSemicolon(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const top_val = try ctx.stack.pop();
    switch (top_val) {
        // Weird case of defining a marker, where the definition looks like:
        //
        //   name: marker ;
        //
        // The `marker` actually creates a new marker, but isn't tied back to
        // the name until the semicolon is executed.
        .marker => |marker| {
            // TODO(ripta): check for duplicate markers?
            while (true) {
                const next_val = try ctx.stack.peek();
                switch (next_val) {
                    .symbol => break,
                    else => return error.TypeError,
                }
            }

            const name = try popSymbol(ctx);
            const name_copy = try alloc.dupe(u8, name);

            // Tag the marker with its name. This is just for identification
            // purposes, and doesn't affect identity or equality checks.
            //
            // TODO(ripta): This mutates the marker in place, which is not ideal,
            //              but probably acceptable for now.
            marker.name = name_copy;

            const push_instr = try alloc.alloc(Instruction, 1);
            push_instr[0] = .{ .op = .{ .push_literal = top_val }, .line = 0 };
            try ctx.defineWord(name_copy, WordDefinition{
                .name = name_copy,
                .action = .{ .compound = push_instr },
            });
        },

        else => {
            var stack_effect_val: ?StackEffect = null;
            var collected_markers = std.ArrayListUnmanaged(*Marker){};
            defer collected_markers.deinit(alloc);

            while (true) {
                const next_val = try ctx.stack.peek();
                switch (next_val) {
                    .stack_effect => |se| {
                        _ = try ctx.stack.pop();
                        stack_effect_val = se;
                    },
                    .marker => |mk| {
                        _ = try ctx.stack.pop();
                        try collected_markers.append(alloc, mk);
                    },
                    .parse_time_marker => {
                        // Legacy support: convert old parse_time_marker to new marker
                        _ = try ctx.stack.pop();
                        try collected_markers.append(alloc, @constCast(&markers_mod.parse_time_marker));
                    },
                    .symbol => break,
                    else => return error.TypeError,
                }
            }

            const name = try popSymbol(ctx);
            const name_copy = try alloc.dupe(u8, name);

            const instructions = switch (top_val) {
                .quotation => |quot| quot.instructions,
                else => blk: {
                    const push_instr = try alloc.alloc(Instruction, 1);
                    push_instr[0] = .{ .op = .{ .push_literal = top_val }, .line = 0 };
                    break :blk push_instr;
                },
            };

            const markers_slice = try alloc.dupe(*Marker, collected_markers.items);
            const has_parse_time = for (collected_markers.items) |mk| {
                if (mk == &markers_mod.parse_time_marker) break true;
            } else false;

            try ctx.defineWord(name_copy, WordDefinition{
                .name = name_copy,
                .parse_time = has_parse_time,
                .stack_effect = stack_effect_val,
                .markers = markers_slice,
                .action = .{ .compound = instructions },
            });
        },
    }
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
    try ctx.executeQuotationWithFrame(if (cond) true_quot else false_quot);
}
