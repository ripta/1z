const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Instruction = value_mod.Instruction;
const Marker = value_mod.Marker;
const Value = value_mod.Value;
const Quotation = value_mod.Quotation;
const StackEffect = @import("../stack_effect.zig").StackEffect;
const WordDefinition = @import("../dictionary.zig").WordDefinition;
const markers_mod = @import("markers.zig");

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

const popQuotation = helpers.popQuotation;
const popBoolean = helpers.popBoolean;
const popSymbol = helpers.popSymbol;

/// Check if a value is a struct descriptor, which is hash or mutable-map
/// with type: and struct-descriptor: fields
fn isStructDescriptor(val: Value) bool {
    const type_val_opt: ?Value = switch (val) {
        .hash => |h| h.get("type"),
        .mutable_map => |m| m.get("type"),
        else => null,
    };

    if (type_val_opt) |type_val| {
        switch (type_val) {
            .symbol => |s| return std.mem.eql(u8, s, "struct-descriptor"),
            else => return false,
        }
    }

    return false;
}

/// Get the underlying map from a struct descriptor
fn getDescriptorMap(val: Value) ?*value_mod.MutableMap {
    return switch (val) {
        .hash => |h| h,
        .mutable_map => |m| m,
        else => null,
    };
}

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

            // User-defined markers are automatically parse-time so they work
            // correctly with parse-time constructs like struct{}.
            const push_instr = try alloc.alloc(Instruction, 1);
            push_instr[0] = .{ .op = .{ .push_literal = top_val }, .line = 0 };
            try ctx.defineWord(name_copy, WordDefinition{
                .name = name_copy,
                .parse_time = true,
                .action = .{ .compound = push_instr },
            });
        },

        else => {
            if (isStructDescriptor(top_val)) {
                // Handle struct definition first
                const desc_map = getDescriptorMap(top_val) orelse return error.TypeError;

                var collected_markers = std.ArrayListUnmanaged(*Marker){};
                defer collected_markers.deinit(alloc);

                while (true) {
                    const next_val = try ctx.stack.peek();
                    switch (next_val) {
                        .marker => |mk| {
                            _ = try ctx.stack.pop();
                            try collected_markers.append(alloc, mk);
                        },
                        .parse_time_marker => {
                            _ = try ctx.stack.pop();
                            try collected_markers.append(alloc, @constCast(&markers_mod.parse_time_marker));
                        },
                        .symbol => break,
                        else => return error.TypeError,
                    }
                }

                const name = try popSymbol(ctx);
                try ctx.stack.push(.{ .symbol = name });

                const fields_val = desc_map.get("fields") orelse return error.MissingField;
                try ctx.stack.push(fields_val);

                const markers_array = try alloc.alloc(Value, collected_markers.items.len);
                for (collected_markers.items, 0..) |mk, i| {
                    markers_array[i] = .{ .marker = mk };
                }
                try ctx.stack.push(.{ .array = markers_array });

                const define_val = desc_map.get("define") orelse return error.MissingField;
                const define_quot = switch (define_val) {
                    .quotation => |q| q,
                    else => return error.TypeError,
                };
                try ctx.executeQuotationWithFrame(define_quot);

            } else {
                // Fall back to normal word definition
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
                    if (mk == @as(*const Marker, &markers_mod.parse_time_marker)) break true;
                } else false;

                try ctx.defineWord(name_copy, WordDefinition{
                    .name = name_copy,
                    .parse_time = has_parse_time,
                    .stack_effect = stack_effect_val,
                    .markers = markers_slice,
                    .action = .{ .compound = instructions },
                });
            }
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
