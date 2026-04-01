const std = @import("std");
const Context = @import("../context.zig").Context;
const parser = @import("../parser.zig");
const Value = @import("../value.zig").Value;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

const popString = helpers.popString;

pub const primitives = [_]Primitive{
    .{ .name = "parse-until", .stack_effect = "delimiter -- quotation", .doc = "Read tokens until delimiter, return as quotation.", .func = nativeParseUntil },
    .{ .name = "parse-tokens-until", .stack_effect = "delimiter -- array", .doc = "Read tokens until delimiter, return as string array.", .func = nativeParseTokensUntil },
};

/// parse-until ( delimiter -- quotation ) - Read tokens until delimiter, return as quotation
/// This is a parse-time primitive that reads from the active tokenizer.
pub fn nativeParseUntil(ctx: *Context) anyerror!void {
    const delimiter = try popString(ctx);

    // Get the tokenizer from parse-time context
    const tokenizer = ctx.parse_tokenizer orelse return error.NoTokenizerAvailable;

    // Delegate to the parser, which handles nested parse-time constructs naturally
    const quot = parser.parseQuotationUntil(ctx.quotationAllocator(), tokenizer, ctx, delimiter) catch return error.OutOfMemory;

    try ctx.stack.push(.{ .quotation = quot });
}

/// parse-tokens-until ( delimiter -- array ) - Read tokens until delimiter, return as string array
/// This is a parse-time primitive that reads raw tokens from the active tokenizer.
/// Unlike parse-until, this does not parse the tokens as instructions - it returns
/// them as literal strings, useful for syntax like `method{ type1 type2 }`.
pub fn nativeParseTokensUntil(ctx: *Context) anyerror!void {
    const delimiter = try popString(ctx);
    const alloc = ctx.quotationAllocator();

    const tokenizer = ctx.parse_tokenizer orelse return error.NoTokenizerAvailable;

    var tokens = std.ArrayListUnmanaged(Value){};
    defer tokens.deinit(alloc);

    while (tokenizer.next()) |tok| {
        if (tok.kind == .comment or tok.kind == .doc_comment or tok.kind == .newline) continue;

        const token = tok.text;
        if (std.mem.eql(u8, token, delimiter)) {
            break;
        }

        const token_copy = try alloc.dupe(u8, token);
        try tokens.append(alloc, .{ .string = token_copy });
    }

    const result = try tokens.toOwnedSlice(alloc);
    try ctx.stack.push(.{ .array = result });
}
