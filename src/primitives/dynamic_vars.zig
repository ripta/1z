const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Parameter = value_mod.Parameter;

const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");

const popQuotation = helpers.popQuotation;
const popSymbol = helpers.popSymbol;

pub const primitives = [_]Primitive{
    .{ .name = "make-parameter", .stack_effect = "name: quot -- param", .doc = "Create a dynamic parameter with a name and default quotation.", .func = nativeMakeParameter },
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

/// get ( param -- value ) - Get the current value of a parameter
/// Searches environment frames from top to bottom; if not found, evaluates default quotation
pub fn nativeGet(ctx: *Context) anyerror!void {
    const param_val = try ctx.stack.pop();
    const param = switch (param_val) {
        .parameter => |p| p,
        else => return error.TypeMismatch,
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
        else => return error.TypeMismatch,
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
