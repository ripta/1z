const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Instruction = value_mod.Instruction;
const Marker = value_mod.Marker;
const MutableMap = value_mod.MutableMap;
const Parameter = value_mod.Parameter;

const dictionary_mod = @import("../dictionary.zig");
const WordDefinition = dictionary_mod.WordDefinition;
const container_backing = @import("../container_backing.zig");

const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");

const popQuotation = helpers.popQuotation;
const popSymbol = helpers.popSymbol;

pub const primitives = [_]Primitive{
    .{ .name = "make-parameter", .stack_effect = "name: quot -- param", .doc = "Create a dynamic parameter with a name and default quotation.", .func = nativeMakeParameter },
    .{ .name = "define-parameter", .stack_effect = "name: descriptor markers --", .doc = "Define a dynamic parameter word from a descriptor map carrying a 'default' quotation.", .func = nativeDefineParameter },
    .{ .name = "get", .stack_effect = "param -- value", .doc = "Get the current value of a dynamic parameter.", .func = nativeGet },
    .{ .name = "with-parameter", .stack_effect = "value param quot --", .doc = "Execute quotation with parameter temporarily bound to value.", .func = nativeWithParameter },
};

/// make-parameter ( name: quot -- param ) - Create a parameter with the given name and default quotation
pub fn nativeMakeParameter(ctx: *Context) anyerror!void {
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

/// define-parameter ( name: descriptor markers -- ) - Define a dynamic parameter
/// word from a descriptor map carrying a `default` quotation. Invoked through the
/// descriptor-driven `;` protocol: `;` pushes name, descriptor, and the collected
/// markers array, then calls the descriptor's `define:` quotation. The resulting
/// word is a compound that pushes a fresh `parameter` value with stack effect
/// `( -- param )`.
pub fn nativeDefineParameter(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const markers_val = try ctx.stack.pop();
    const markers_array = switch (markers_val) {
        .array => |arr| arr,
        else => {
            helpers.setTypeMismatchError(ctx, "array", markers_val);
            return error.TypeMismatch;
        },
    };

    const desc_val = try ctx.stack.pop();
    defer container_backing.releaseValue(desc_val);
    const desc_map: *MutableMap = switch (desc_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable-map", desc_val);
            return error.TypeMismatch;
        },
    };

    const default_val = desc_map.map.get("default") orelse {
        helpers.setErrorContext(ctx, "define-parameter descriptor missing 'default' field", .{});
        return error.MissingField;
    };
    const default_quot = switch (default_val) {
        .quotation => |q| q,
        else => {
            helpers.setTypeMismatchError(ctx, "quotation", default_val);
            return error.TypeMismatch;
        },
    };

    const doc_val: ?[]const u8 = if (desc_map.map.get("doc")) |v| switch (v) {
        .doc_string, .string => |s| s,
        else => null,
    } else null;

    const name = try popSymbol(ctx);
    const name_copy = try alloc.dupe(u8, name);

    const param = try alloc.create(Parameter);
    param.* = .{
        .name = name_copy,
        .default_quotation = default_quot,
    };

    var markers_list = std.ArrayListUnmanaged(*Marker){};
    for (markers_array) |m| {
        switch (m) {
            .marker => |mk| try markers_list.append(alloc, mk),
            else => {
                helpers.setTypeMismatchError(ctx, "marker", m);
                return error.TypeMismatch;
            },
        }
    }
    const markers_slice = try markers_list.toOwnedSlice(alloc);

    const param_instrs = try alloc.alloc(Instruction, 1);
    param_instrs[0] = .{ .op = .{ .push_literal = .{ .parameter = param } }, .line = 0 };

    try ctx.defineWord(name_copy, WordDefinition{
        .name = name_copy,
        .stack_effect = try helpers.makeSimpleEffect(alloc, "-- param"),
        .markers = markers_slice,
        .doc = doc_val,
        .provenance = .{ .generator = "parameter", .parent = name_copy, .role = "parameter" },
        .action = .{ .compound = param_instrs },
    });
}

/// get ( param -- value ) - Get the current value of a parameter
/// Searches environment frames from top to bottom; if not found, evaluates default quotation
pub fn nativeGet(ctx: *Context) anyerror!void {
    const param_val = try ctx.stack.pop();
    const param = switch (param_val) {
        .parameter => |p| p,
        else => {
            helpers.setTypeMismatchError(ctx, "parameter", param_val);
            return error.TypeMismatch;
        },
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
pub fn nativeWithParameter(ctx: *Context) anyerror!void {
    const body_quot = try popQuotation(ctx);
    const param_val = try ctx.stack.pop();
    const param = switch (param_val) {
        .parameter => |p| p,
        else => {
            helpers.setTypeMismatchError(ctx, "parameter", param_val);
            return error.TypeMismatch;
        },
    };
    const new_value = try ctx.stack.pop();

    // Push new frame with binding
    try ctx.pushParameterFrame();
    try ctx.setParameterInTopFrame(param.name, new_value);

    // Execute body with cleanup (pops frame even on error)
    const result = ctx.executeQuotationWithFrame(body_quot);
    ctx.popParameterFrame();
    try result;
}
