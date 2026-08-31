const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const is_freestanding = builtin.os.tag == .freestanding;

const Context = @import("../context.zig").Context;
const signal_mod = @import("../signal.zig");
const helpers = @import("helpers.zig");
const container_backing = @import("../container_backing.zig");

const Primitive = @import("types.zig").Primitive;
const RegistryEntry = @import("types.zig").RegistryEntry;
const Capability = @import("types.zig").Capability;

pub const primitives = [_]Primitive{
    .{
        .name = "set-signal-handler",
        .stack_effect = "signal quot --",
        .doc = "Register a handler quotation for a signal number. The handler receives the signal number on the stack when invoked.",
        .func = nativeSetSignalHandler,
        .capability = .system,
    },
    .{
        .name = "clear-signal-handler",
        .stack_effect = "signal --",
        .doc = "Remove the handler for a signal number, restoring default behavior.",
        .func = nativeClearSignalHandler,
        .capability = .system,
    },
    .{
        .name = "get-signal-handler",
        .stack_effect = "signal -- quot/f",
        .doc = "Return the handler quotation for a signal number, or f if none is registered.",
        .func = nativeGetSignalHandler,
        .capability = .system,
    },
};

pub const registry_entries = [_]RegistryEntry{
    .{
        .name = "signal-number",
        .func = nativeSignalNumber,
        .stack_effect = "sym/str -- n",
        .capability = .system,
    },
};

/// ( signal quot -- )
fn nativeSetSignalHandler(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "set-signal-handler");
    // The handler body escapes into the global handler table.
    const pc = try helpers.popQuotation(ctx);
    errdefer pc.release();
    const signum = try helpers.popFixnum(ctx);

    if (!signal_mod.isHandleable(signum)) {
        helpers.setErrorContext(ctx, "set-signal-handler: invalid or uncatchable signal number {d}", .{signum});
        return error.TypeMismatch;
    }

    const s: u6 = @intCast(signum);
    signal_mod.setUserHandler(s, .{ .quot = pc.quot, .owner = pc.ownerClosure() });
    try pc.adoptForTeardown(ctx);
    signal_mod.installHandler(s);
}

/// ( signal -- )
///
/// SIGINT keeps the runtime's own handler so the "interrupted" behavior is preserved; every
/// other signal is restored to its OS default.
fn nativeClearSignalHandler(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "clear-signal-handler");
    const signum = try helpers.popFixnum(ctx);

    if (!signal_mod.isHandleable(signum)) {
        helpers.setErrorContext(ctx, "clear-signal-handler: invalid or uncatchable signal number {d}", .{signum});
        return error.TypeMismatch;
    }

    const s: u6 = @intCast(signum);
    signal_mod.setUserHandler(s, null);
    if (s != @as(u6, @intCast(posix.SIG.INT))) {
        signal_mod.removeHandler(s);
    }
}

/// ( signal -- quot/f )
fn nativeGetSignalHandler(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "get-signal-handler");
    const signum = try helpers.popFixnum(ctx);
    if (!signal_mod.isHandleable(signum)) {
        helpers.setErrorContext(ctx, "get-signal-handler: invalid or uncatchable signal number {d}", .{signum});
        return error.TypeMismatch;
    }

    const s: u6 = @intCast(signum);
    if (signal_mod.getUserHandler(s)) |handler| {
        // The bare view, not the closure behind it. `push` retains, and this table's entry can
        // outlive its own registration: a handler registered inside a task is parked on that
        // task's dictionary and freed at reap, leaving a pointer only a read survives.
        try ctx.stack.push(.{ .quotation = handler.quot });
    } else {
        try ctx.stack.push(.{ .boolean = false });
    }
}

const signal_names = .{
    .{ "INT", posix.SIG.INT },
    .{ "TERM", posix.SIG.TERM },
    .{ "HUP", posix.SIG.HUP },
    .{ "QUIT", posix.SIG.QUIT },
    .{ "PIPE", posix.SIG.PIPE },
    .{ "USR1", posix.SIG.USR1 },
    .{ "USR2", posix.SIG.USR2 },
    .{ "ALRM", posix.SIG.ALRM },
    .{ "CHLD", posix.SIG.CHLD },
    .{ "WINCH", posix.SIG.WINCH },
};

/// ( sym/str -- n ) Look up a POSIX signal number by name.
///
/// Accepts a symbol (INT:) or string ("INT").
fn nativeSignalNumber(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "signal-number");
    const val = ctx.stack.pop() catch return error.StackUnderflow;
    defer container_backing.releaseValue(val);
    const name = switch (val) {
        .symbol => |s| s.bytes,
        .string => |s| s.bytes,
        else => {
            ctx.pending_error_message = "signal-number expects a symbol or string";
            return error.TypeMismatch;
        },
    };

    inline for (signal_names) |entry| {
        if (std.mem.eql(u8, name, entry[0])) {
            try ctx.stack.push(.{ .fixnum = entry[1] });
            return;
        }
    }

    helpers.setErrorContext(ctx, "signal-number: unknown signal name '{s}'", .{name});
    return error.TypeMismatch;
}
