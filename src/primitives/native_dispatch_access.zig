const Context = @import("../context.zig").Context;
const dispatch_mod = @import("../dispatch.zig");
const dispatch_helpers = @import("dispatch_helpers.zig");
const helpers = @import("helpers.zig");
const RegistryEntry = @import("types.zig").RegistryEntry;

fn makeBinaryNativeAccessEntry(comptime word_name: []const u8) *const fn (*Context) anyerror!void {
    return &struct {
        fn func(ctx: *Context) anyerror!void {
            if (ctx.stack.depth() < 2) return error.StackUnderflow;

            const b = try ctx.stack.peek();
            const a = try ctx.stack.peekN(1);

            const type_a = dispatch_mod.dispatchDescriptor(a, ctx);
            const type_b = dispatch_mod.dispatchDescriptor(b, ctx);

            if (ctx.lookupNativeBinaryDispatch(word_name, type_a, type_b)) |entry| {
                try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                return;
            }

            helpers.setErrorHint(ctx, "no native dispatch entry for '" ++ word_name ++ "' with these operand types");
            return error.TypeMismatch;
        }
    }.func;
}

fn makeUnaryNativeAccessEntry(comptime word_name: []const u8) *const fn (*Context) anyerror!void {
    return &struct {
        fn func(ctx: *Context) anyerror!void {
            if (ctx.stack.depth() < 1) return error.StackUnderflow;

            const a = try ctx.stack.peek();
            const type_a = dispatch_mod.dispatchDescriptor(a, ctx);

            if (ctx.lookupNativeUnaryDispatch(word_name, type_a)) |entry| {
                try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                return;
            }

            helpers.setErrorHint(ctx, "no native dispatch entry for '" ++ word_name ++ "' with this operand type");
            return error.TypeMismatch;
        }
    }.func;
}

pub const registry_entries = [_]RegistryEntry{
    // Arithmetic (binary)
    .{ .name = "dispatch+", .func = makeBinaryNativeAccessEntry("+") },
    .{ .name = "dispatch-", .func = makeBinaryNativeAccessEntry("-") },
    .{ .name = "dispatch*", .func = makeBinaryNativeAccessEntry("*") },
    .{ .name = "dispatch/", .func = makeBinaryNativeAccessEntry("/") },
    .{ .name = "dispatch%", .func = makeBinaryNativeAccessEntry("%") },

    // Comparison (binary)
    .{ .name = "dispatch=", .func = makeBinaryNativeAccessEntry("=") },
    .{ .name = "dispatch<", .func = makeBinaryNativeAccessEntry("<") },
    .{ .name = "dispatch>", .func = makeBinaryNativeAccessEntry(">") },

    // Arithmetic (unary)
    .{ .name = "dispatchabs", .func = makeUnaryNativeAccessEntry("abs") },
    .{ .name = "dispatch>float", .func = makeUnaryNativeAccessEntry(">float") },
    .{ .name = "dispatch>integer", .func = makeUnaryNativeAccessEntry(">integer") },

    // Bitwise (binary)
    .{ .name = "dispatchbitand", .func = makeBinaryNativeAccessEntry("bitand") },
    .{ .name = "dispatchbitor", .func = makeBinaryNativeAccessEntry("bitor") },
    .{ .name = "dispatchbitxor", .func = makeBinaryNativeAccessEntry("bitxor") },

    // Bitwise (unary)
    .{ .name = "dispatchbitnot", .func = makeUnaryNativeAccessEntry("bitnot") },

    // Bitwise shifts (binary)
    .{ .name = "dispatchshift-left", .func = makeBinaryNativeAccessEntry("shift-left") },
    .{ .name = "dispatchshift-right", .func = makeBinaryNativeAccessEntry("shift-right") },
    .{ .name = "dispatchushift-right", .func = makeBinaryNativeAccessEntry("ushift-right") },
    .{ .name = "dispatchshift", .func = makeBinaryNativeAccessEntry("shift") },

    // Sequence (unary)
    .{ .name = "dispatch#len", .func = makeUnaryNativeAccessEntry("#len") },
    .{ .name = "dispatch#first", .func = makeUnaryNativeAccessEntry("#first") },
    .{ .name = "dispatch#last", .func = makeUnaryNativeAccessEntry("#last") },

    // Sequence (binary)
    .{ .name = "dispatch#nth", .func = makeBinaryNativeAccessEntry("#nth") },

    // Container conversion (unary)
    .{ .name = "dispatch>array", .func = makeUnaryNativeAccessEntry(">array") },
    .{ .name = "dispatch>hash", .func = makeUnaryNativeAccessEntry(">hash") },

    // String (unary)
    .{ .name = "dispatchinspect", .func = makeUnaryNativeAccessEntry("inspect") },
    .{ .name = "dispatch>string", .func = makeUnaryNativeAccessEntry(">string") },
};
