const std = @import("std");
const Context = @import("../context.zig").Context;
const parser = @import("../parser.zig");
const tokenizer_mod = @import("../tokenizer.zig");
const Token = tokenizer_mod.Token;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

const popString = helpers.popString;

pub const primitives = [_]Primitive{
    .{ .name = "parse-until", .stack_effect = "delimiter -- quotation", .doc = "Read tokens until delimiter, return as quotation.", .func = nativeParseUntil },
    .{ .name = "parse-tokens-until", .stack_effect = "delimiter -- array", .doc = "Read tokens until delimiter, return as string array.", .func = nativeParseTokensUntil },
    .{ .name = "parse-values-until", .stack_effect = "delimiter -- array", .doc = "Read tokens until delimiter, executing parse-time words. Return as array.", .func = nativeParseValuesUntil },
    .{ .name = "parse-token", .stack_effect = "-- string", .doc = "Read one raw token from the tokenizer, skipping comments and whitespace.", .func = nativeParseToken },
    .{ .name = "peek-token", .stack_effect = "-- string", .doc = "Return the next token without consuming it. Repeated calls return the same token until parse-token or another consuming primitive advances past it.", .func = nativePeekToken },
    .{ .name = "parse-literal", .stack_effect = "-- value", .doc = "Read the next literal value from the tokenizer.", .func = nativeParseLiteral },
};

fn isSkippable(kind: Token.Kind) bool {
    return kind == .comment or kind == .doc_comment or kind == .newline;
}

const ParseMode = enum { raw, evaluate_parse_time };

fn parseTokensUntilCore(ctx: *Context, delimiter: []const u8, mode: ParseMode) !Value {
    const tokenizer = ctx.parse_tokenizer orelse return error.NoTokenizerAvailable;
    const alloc = ctx.quotationAllocator();

    var tokens = std.ArrayListUnmanaged(Value){};
    defer tokens.deinit(alloc);

    while (tokenizer.nextOrYield()) |tok| {
        if (isSkippable(tok.kind)) continue;

        const token = tok.text;
        if (std.mem.eql(u8, token, delimiter)) {
            break;
        }

        if (mode == .evaluate_parse_time) {
            if (ctx.lookupWord(token)) |word| {
                if (word.parse_time) {
                    const pre_depth = ctx.stack.depth();
                    switch (word.action) {
                        .native => |func| try func(ctx),
                        .compound => |instrs| try ctx.executeQuotation(.{ .instructions = instrs }),
                    }
                    const post_depth = ctx.stack.depth();
                    if (post_depth > pre_depth) {
                        var i: usize = 0;
                        const num_results = post_depth - pre_depth;
                        while (i < num_results) : (i += 1) {
                            const val = try ctx.stack.pop();
                            try tokens.append(alloc, val);
                        }
                        // Reverse the results so they appear in stack order
                        const start = tokens.items.len - num_results;
                        std.mem.reverse(Value, tokens.items[start..]);
                    }
                    continue;
                }
            }
        }

        const token_copy = try alloc.dupe(u8, token);
        try tokens.append(alloc, .{ .string = token_copy });
    }

    const result = try tokens.toOwnedSlice(alloc);
    return .{ .array = result };
}

/// parse-until ( delimiter -- quotation ) - Read tokens until delimiter, return as quotation
/// This is a parse-time primitive that reads from the active tokenizer.
pub fn nativeParseUntil(ctx: *Context) anyerror!void {
    const delimiter = try popString(ctx);

    const tokenizer = ctx.parse_tokenizer orelse return error.NoTokenizerAvailable;

    const quot = parser.parseQuotationUntil(ctx.quotationAllocator(), tokenizer, ctx, delimiter, 0) catch return error.OutOfMemory;

    try ctx.stack.push(.{ .quotation = quot });
}

/// parse-tokens-until ( delimiter -- array ) - Read tokens until delimiter, return as string array
/// This is a parse-time primitive that reads raw tokens from the active tokenizer.
/// Unlike parse-until, this does not parse the tokens as instructions - it returns
/// them as literal strings, useful for syntax like `method{ type1 type2 }`.
pub fn nativeParseTokensUntil(ctx: *Context) anyerror!void {
    const delimiter = try popString(ctx);
    const result = try parseTokensUntilCore(ctx, delimiter, .raw);
    try ctx.stack.push(result);
}

/// parse-values-until ( delimiter -- array ) - Read tokens until delimiter, executing parse-time words
fn nativeParseValuesUntil(ctx: *Context) anyerror!void {
    const delimiter = try popString(ctx);
    const result = try parseTokensUntilCore(ctx, delimiter, .evaluate_parse_time);
    try ctx.stack.push(result);
}

/// parse-token ( -- string ) - Read one raw token from the tokenizer
fn nativeParseToken(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer orelse return error.NoTokenizerAvailable;
    const alloc = ctx.quotationAllocator();
    while (tokenizer.nextOrYield()) |tok| {
        if (isSkippable(tok.kind)) continue;
        const token_copy = try alloc.dupe(u8, tok.text);
        try ctx.stack.push(.{ .string = token_copy });
        return;
    }
    return error.ParseError;
}

/// peek-token ( -- string ) - Return the next token without consuming it
fn nativePeekToken(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer orelse return error.NoTokenizerAvailable;
    const alloc = ctx.quotationAllocator();
    while (tokenizer.nextOrYield()) |tok| {
        if (isSkippable(tok.kind)) continue;
        tokenizer.peeked = tok;
        const token_copy = try alloc.dupe(u8, tok.text);
        try ctx.stack.push(.{ .string = token_copy });
        return;
    }
    return error.ParseError;
}

/// parse-literal ( -- value ) - Read the next literal from the tokenizer
fn nativeParseLiteral(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer orelse return error.NoTokenizerAvailable;
    const alloc = ctx.quotationAllocator();
    while (tokenizer.nextOrYield()) |tok| {
        if (isSkippable(tok.kind)) continue;

        const token = tok.text;

        if (std.mem.eql(u8, token, "{")) {
            const arr = parser.parseArray(alloc, tokenizer, ctx, tok.line) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .array = arr });
            return;
        }

        if (std.mem.eql(u8, token, "[")) {
            const quot = parser.parseQuotation(alloc, tokenizer, ctx, tok.line) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .quotation = quot });
            return;
        }

        if (tokenizer_mod.parseString(token)) |s| {
            const s_copy = parser.processEscapes(alloc, s) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .string = s_copy });
            return;
        }

        if (token.len > 1 and token[token.len - 1] == ':') {
            const sym_copy = alloc.dupe(u8, token[0 .. token.len - 1]) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .symbol = sym_copy });
            return;
        }

        if (tokenizer_mod.parseInteger(token)) |n| {
            try ctx.stack.push(.{ .fixnum = n });
            return;
        }

        if (tokenizer_mod.parseBigNum(ctx.arena.allocator(), token)) |big| {
            try ctx.stack.push(.{ .bignum = big });
            return;
        }

        if (tokenizer_mod.parseFloat(token)) |f| {
            try ctx.stack.push(.{ .float = f });
            return;
        }

        if (ctx.lookupWord(token)) |word| {
            if (word.parse_time) {
                const pre_depth = ctx.stack.depth();
                switch (word.action) {
                    .native => |func| try func(ctx),
                    .compound => |instrs| try ctx.executeQuotation(.{ .instructions = instrs }),
                }
                const post_depth = ctx.stack.depth();
                if (post_depth > pre_depth) return;
                helpers.setErrorContext(ctx, "parse-literal: parse-time word '{s}' did not produce a value", .{token});
                return error.TypeMismatch;
            }
        }

        helpers.setErrorContext(ctx, "parse-literal: not a recognized literal: {s}", .{token});
        return error.TypeMismatch;
    }

    helpers.setErrorContext(ctx, "parse-literal: no token available", .{});
    return error.TypeMismatch;
}
