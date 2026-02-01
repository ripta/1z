const Context = @import("../context.zig").Context;
const parser = @import("../parser.zig");

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

const popString = helpers.popString;

pub const primitives = [_]Primitive{
    .{ .name = "parse-until", .stack_effect = "delimiter -- quotation", .func = nativeParseUntil },
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
