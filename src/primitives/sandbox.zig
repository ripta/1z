const std = @import("std");
const Context = @import("../context.zig").Context;
const Value = @import("../value.zig").Value;
const container_backing = @import("../container_backing.zig");
const helpers = @import("helpers.zig");
const SandboxSpec = @import("types.zig").SandboxSpec;
const Primitive = @import("types.zig").Primitive;
const Token = @import("../tokenizer.zig").Token;

pub const primitives = [_]Primitive{
    .{ .name = "sandbox{", .func = nativeSandboxParse, .parse_time = true, .stack_effect = "-- sandbox-spec", .doc = "Parse a sandbox specification granting named capabilities. Default-deny: an empty sandbox{ } grants nothing." },
    .{ .name = "with-sandbox", .func = nativeWithSandbox, .stack_effect = "sandbox-spec quot --", .doc = "Execute quotation with the given sandbox restricting capability access. Nesting intersects (can only restrict, never widen)." },
};

/// with-sandbox ( sandbox-spec quot -- )
fn nativeWithSandbox(ctx: *Context) anyerror!void {
    const pc = try helpers.popQuotation(ctx);
    defer pc.release();
    const spec_val = ctx.stack.pop() catch return error.StackUnderflow;
    defer container_backing.releaseValue(spec_val);
    const spec = switch (spec_val) {
        .sandbox_spec => |s| s,
        else => {
            ctx.pending_error_message = "with-sandbox expects a sandbox-spec value";
            return error.TypeMismatch;
        },
    };

    var effective = spec.*;
    if (ctx.active_sandbox) |parent_sandbox| {
        effective = parent_sandbox.intersect(effective);
    }

    const saved = ctx.active_sandbox;
    ctx.active_sandbox = &effective;
    defer ctx.active_sandbox = saved;

    try pc.executeWithFrame(ctx);
}

/// sandbox{ ( -- sandbox-spec )
///
/// Syntax: `sandbox{ cap1 cap2 ... }`.
fn nativeSandboxParse(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer orelse return error.NoTokenizerAvailable;
    const alloc = ctx.quotationAllocator();

    const spec = try alloc.create(SandboxSpec);
    spec.* = .{};

    while (tokenizer.nextOrYield()) |tok| {
        if (tok.kind == .comment or tok.kind == .doc_comment or tok.kind == .newline) continue;
        if (std.mem.eql(u8, tok.text, "}")) {
            try ctx.stack.push(.{ .sandbox_spec = spec });
            return;
        }
        if (SandboxSpec.fromString(tok.text)) |cap| {
            spec.grant(cap);
        } else {
            ctx.parse_diagnostics = .{
                .error_type = "TypeMismatch",
                .message = std.fmt.allocPrint(alloc, "sandbox{{: unknown capability '{s}'. Valid capabilities: io, process, io/fs, io/net, ffi, system, eval", .{tok.text}) catch null,
            };
            return error.TypeMismatch;
        }
    }

    ctx.parse_diagnostics = .{
        .error_type = "ParseError",
        .message = "sandbox{: unexpected end of input, expected '}' to close sandbox spec",
    };
    return error.ParseError;
}
