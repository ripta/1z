const std = @import("std");
const context_mod = @import("../context.zig");
const Context = context_mod.Context;
const PragmaRegistration = context_mod.PragmaRegistration;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;
const parse_time_mod = @import("parse_time.zig");
const tokenizer_mod = @import("../tokenizer.zig");
const Token = tokenizer_mod.Token;

const popString = helpers.popString;

pub const primitives = [_]Primitive{
    .{ .name = "register-pragma", .stack_effect = "name validator --", .doc = "Register a pragma key with an optional validator quotation. Pass f for boolean-only pragmas.", .func = nativeRegisterPragma },
    .{ .name = "pragma{", .parse_time = true, .stack_effect = "--", .doc = "Set pragma values for the current file scope.", .func = nativePragmaBlock },
};

/// register-pragma ( name validator -- ) - Register a pragma key
fn nativeRegisterPragma(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const validator_val = try ctx.stack.pop();
    const name = try popString(ctx);

    const registration: PragmaRegistration = switch (validator_val) {
        .boolean => |b| blk: {
            if (b) {
                helpers.setErrorContext(ctx, "register-pragma: validator must be a quotation or f, got t", .{});
                return error.TypeMismatch;
            }
            break :blk .{ .validator = null };
        },
        .quotation => |q| .{ .validator = q },
        else => {
            helpers.setTypeMismatchError(ctx, "quotation or f", validator_val);
            return error.TypeMismatch;
        },
    };

    const duped_name = try alloc.dupe(u8, name);
    try ctx.pragma_registry.put(ctx.allocator, duped_name, registration);
}

fn isSkippable(kind: Token.Kind) bool {
    return kind == .comment or kind == .doc_comment or kind == .newline;
}

/// pragma{ ... } - Parse-time word for setting pragma values
fn nativePragmaBlock(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer orelse return error.NoTokenizerAvailable;
    const alloc = ctx.quotationAllocator();

    while (tokenizer.nextOrYield()) |tok| {
        if (isSkippable(tok.kind)) continue;

        const token = tok.text;

        if (std.mem.eql(u8, token, "}")) break;

        if (token.len > 1 and token[token.len - 1] == ':') {
            const pragma_name = token[0 .. token.len - 1];
            const reg = ctx.lookupPragmaRegistration(pragma_name) orelse {
                return throwPragmaError(ctx, alloc, "unknown-pragma", pragma_name);
            };

            const value = try parsePragmaValue(ctx, tokenizer, alloc);
            if (reg.validator) |validator| {
                try ctx.stack.push(value);
                try ctx.executeQuotation(validator);

                const ok = try helpers.popBoolean(ctx);
                if (ok) {
                    const validated = try ctx.stack.pop();
                    try ctx.setPragma(pragma_name, validated);
                } else {
                    const err_val = try ctx.stack.pop();
                    const err_msg = switch (err_val) {
                        .string => |s| s,
                        else => "validation failed",
                    };
                    return throwPragmaError(ctx, alloc, "pragma-error", err_msg);
                }

                continue;
            }

            switch (value) {
                .boolean => try ctx.setPragma(pragma_name, value),
                else => {
                    const msg = std.fmt.allocPrint(alloc, "pragma '{s}' accepts only boolean values", .{pragma_name}) catch "pragma accepts only boolean values";
                    return throwPragmaError(ctx, alloc, "pragma-error", msg);
                },
            }

            continue;
        }

        // Negation shorthand: "!key"
        if (token.len > 1 and token[0] == '!') {
            const pragma_name = token[1..];
            const reg = ctx.lookupPragmaRegistration(pragma_name) orelse {
                return throwPragmaError(ctx, alloc, "unknown-pragma", pragma_name);
            };

            if (reg.validator != null) {
                const msg = std.fmt.allocPrint(alloc, "pragma '{s}' requires a value, cannot use ! shorthand", .{pragma_name}) catch "cannot use ! on validated pragma";
                return throwPragmaError(ctx, alloc, "pragma-error", msg);
            }

            try ctx.setPragma(pragma_name, .{ .boolean = false });
            continue;
        }

        // Boolean shorthand: bare "key"
        {
            const pragma_name = token;
            const reg = ctx.lookupPragmaRegistration(pragma_name) orelse {
                return throwPragmaError(ctx, alloc, "unknown-pragma", pragma_name);
            };

            if (reg.validator != null) {
                const msg = std.fmt.allocPrint(alloc, "pragma '{s}' requires a value, cannot use boolean shorthand", .{pragma_name}) catch "cannot use boolean shorthand on validated pragma";
                return throwPragmaError(ctx, alloc, "pragma-error", msg);
            }

            try ctx.setPragma(pragma_name, .{ .boolean = true });
        }
    }
}

/// Read the next pragma value token. Handles `t`/`f` as boolean literals
/// directly since they are words in 1z, not literal tokens that
/// `parse-literal` can handle. All other values delegate to `parse-literal`.
fn parsePragmaValue(ctx: *Context, tokenizer: *tokenizer_mod.Tokenizer, alloc: std.mem.Allocator) !Value {
    _ = alloc;
    while (tokenizer.nextOrYield()) |val_tok| {
        if (isSkippable(val_tok.kind)) continue;

        if (std.mem.eql(u8, val_tok.text, "t")) return .{ .boolean = true };
        if (std.mem.eql(u8, val_tok.text, "f")) return .{ .boolean = false };

        // Put the token back and let parse-literal handle it
        tokenizer.peeked = val_tok;
        try parse_time_mod.nativeParseLiteral(ctx);
        return try ctx.stack.pop();
    }
    helpers.setErrorContext(ctx, "pragma: expected value after ':'", .{});
    return error.ParseError;
}

/// Set up a thrown error and return UserThrown for clean parse-time error display.
fn throwPragmaError(ctx: *Context, alloc: std.mem.Allocator, error_type: []const u8, message: []const u8) anyerror {
    _ = alloc;
    ctx.thrown_error = .{
        .error_type = error_type,
        .message = message,
    };
    return error.UserThrown;
}
