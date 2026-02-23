const std = @import("std");
const Context = @import("../context.zig").Context;
const Tokenizer = @import("../tokenizer.zig").Tokenizer;
const parser = @import("../parser.zig");

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

const popString = helpers.popString;

pub const primitives = [_]Primitive{
    .{ .name = "parse-time", .stack_effect = "-- marker", .func = nativeParseTime },
    .{ .name = "parse-until", .stack_effect = "delimiter -- quotation", .func = nativeParseUntil },
};

/// parse-time ( -- marker ) - Push parse-time marker onto stack
/// When `;` sees this marker, it will set the word's parse_time flag
pub fn nativeParseTime(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .parse_time_marker = {} });
}

/// parse-until ( delimiter -- quotation ) - Read tokens until delimiter, return as quotation
/// This is a parse-time primitive that reads from the active tokenizer.
pub fn nativeParseUntil(ctx: *Context) anyerror!void {
    const delimiter = try popString(ctx);

    // Get the tokenizer from parse-time context
    const tokenizer = ctx.parse_tokenizer orelse return error.NoTokenizerAvailable;

    // Collect tokens until we hit the delimiter
    var tokens: std.ArrayListUnmanaged([]const u8) = .{};
    defer tokens.deinit(ctx.allocator);

    while (tokenizer.next()) |tok| {
        // Skip comments
        if (tok.kind == .comment or tok.kind == .newline) continue;

        if (std.mem.eql(u8, tok.text, delimiter)) {
            break;
        }
        tokens.append(ctx.allocator, tok.text) catch return error.OutOfMemory;
    }

    // Join tokens into a single string and parse as a quotation body
    const joined = std.mem.join(ctx.quotationAllocator(), " ", tokens.items) catch return error.OutOfMemory;

    // Parse the tokens as a quotation body (without enclosing brackets)
    // We add a closing bracket so parseQuotation can work correctly
    const with_bracket = std.fmt.allocPrint(ctx.quotationAllocator(), "{s} ]", .{joined}) catch return error.OutOfMemory;

    var inner_tokenizer = Tokenizer.init(with_bracket);
    const instrs = parser.parseQuotation(ctx.quotationAllocator(), &inner_tokenizer, ctx) catch return error.OutOfMemory;

    try ctx.stack.push(.{ .quotation = instrs });
}
