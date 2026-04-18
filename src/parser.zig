const std = @import("std");
const Allocator = std.mem.Allocator;

const tokenizer_mod = @import("tokenizer.zig");
const Tokenizer = tokenizer_mod.Tokenizer;
const Token = tokenizer_mod.Token;
const parseInteger = tokenizer_mod.parseInteger;
const parseBigNum = tokenizer_mod.parseBigNum;
const parseFloat = tokenizer_mod.parseFloat;
const parseString = tokenizer_mod.parseString;

const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const Quotation = value_mod.Quotation;

const StackEffect = @import("stack_effect.zig").StackEffect;
const StackEffectParam = @import("stack_effect.zig").StackEffectParam;

const Context = @import("context.zig").Context;

/// Process escape sequences in a string and allocate the result; supports
/// Zig-compatible escape sequences: \n, \r, \t, \\, \", \', \xHH, \u{HHHH}
pub fn processEscapes(allocator: Allocator, input: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, input.len);
    var out_idx: usize = 0;

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\') {
            const parsed = std.zig.string_literal.parseEscapeSequence(input, &i);
            switch (parsed) {
                .success => |codepoint| {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &buf) catch 1;
                    @memcpy(result[out_idx..][0..len], buf[0..len]);
                    out_idx += len;
                },
                .failure => {
                    // Invalid escape - keep backslash
                    result[out_idx] = input[i];
                    out_idx += 1;
                    i += 1;
                },
            }
            continue;
        }

        result[out_idx] = input[i];
        out_idx += 1;
        i += 1;
    }

    return allocator.realloc(result, out_idx);
}

/// Get the next non-comment, non-newline token from the tokenizer.
fn nextToken(tokenizer: *Tokenizer) ?Token {
    while (tokenizer.next()) |tok| {
        // Skip comments and newlines during parsing
        if (tok.kind == .comment or tok.kind == .newline) {
            continue;
        }
        return tok;
    }
    return null;
}

/// Like `nextToken`, but calls `nextOrYield` so that delimited parse
/// functions can suspend when input is exhausted mid-construct.
fn nextTokenOrYield(tokenizer: *Tokenizer) ?Token {
    while (tokenizer.nextOrYield()) |tok| {
        if (tok.kind == .comment or tok.kind == .newline) {
            continue;
        }
        return tok;
    }
    return null;
}

/// All the different errors that can occur during parsing.
pub const ParseError = error{
    UnmatchedOpenBracket,
    UnmatchedCloseBracket,
    UnmatchedOpenBrace,
    UnmatchedCloseBrace,
    UnmatchedOpenParen,
    UnmatchedCloseParen,
    UnmatchedOpenQuote,
    InvalidArrayElement,
    OutOfMemory,
    ParseTimeExecutionError,
    DebuggerQuit,
};

/// Returns true if the parse error indicates incomplete input.
pub fn isIncompleteError(err: anyerror) bool {
    return err == error.UnmatchedOpenBracket or err == error.UnmatchedOpenBrace or err == error.UnmatchedOpenQuote;
}

fn setUnmatchedDiagnostics(ctx: ?*Context, comptime error_name: []const u8, opening_line: usize) void {
    if (ctx) |c| {
        c.parse_diagnostics = .{
            .error_type = error_name,
            .opening_line = opening_line,
        };
    }
}

const WordDefinition = @import("dictionary.zig").WordDefinition;

/// Execute a parse-time word during parsing:
///
/// 1. Find trailing `push_literal` instructions after the last `call_word` barrier
/// 2. Push trailing literals onto the data stack
/// 3. Keep everything before the trail, including call_words and their operands, untouched
/// 4. Run the parse-time word
/// Handle an error from a parse-time word execution: populate diagnostics on
/// the context, clear stale runtime error state, and return the appropriate
/// ParseError.
fn handleParseTimeError(c: *Context, err: anyerror) ParseError {
    if (err == error.DebuggerQuit) return ParseError.DebuggerQuit;
    if (c.thrown_error) |thrown| {
        c.parse_diagnostics = .{
            .error_type = thrown.error_type,
            .message = thrown.message,
        };
        c.thrown_error = null;
    } else if (c.error_details.items.len > 0) {
        const detail = c.error_details.items[0];
        const has_real_message = detail.word_name == null or
            !std.mem.eql(u8, detail.message, detail.word_name.?);
        c.parse_diagnostics = .{
            .error_type = detail.error_type,
            .message = if (has_real_message) detail.message else null,
        };
    } else {
        c.parse_diagnostics = .{
            .error_type = @errorName(err),
        };
    }
    c.clearExecutionDetails();
    return ParseError.ParseTimeExecutionError;
}

/// 5. Capture all values above the pre-depth stack as `push_literal` instructions
///
/// NOTE(ripta): The `call_word` acts as a barrier: the parse-time word can only reach back
///              to literals that appear after the last `call_word` in the pending
///              instruction stream. This prevents reordering when `push_literals` and
///              `call_words` are interleaved.
fn executeParseTimeWord(
    c: *Context,
    word: WordDefinition,
    tokenizer: *Tokenizer,
    instructions: *std.ArrayListUnmanaged(Instruction),
    allocator: Allocator,
    line: usize,
) ParseError!void {
    const pre_depth = c.stack.depth();

    // 1. Find trailing `push_literal` instructions after the last `call_word` barrier
    var tail_start = instructions.items.len;
    while (tail_start > 0) {
        switch (instructions.items[tail_start - 1].op) {
            .push_literal => tail_start -= 1,
            .call_word => break,
        }
    }

    // 2. Push trailing literals onto the data stack, saving doc_strings
    //    separately. Doc-string values are definition metadata that parse-time
    //    words should not see on the stack.
    //
    // TODO(ripta): Supports up to 8 trailing doc_strings, which should be
    //              plenty for most use cases but is an arbitrary limit.
    var saved_doc_instrs: [8]Instruction = undefined;
    var saved_doc_count: usize = 0;
    var pushed_count: usize = 0;
    for (instructions.items[tail_start..]) |instr| {
        switch (instr.op.push_literal) {
            .doc_string => {
                saved_doc_instrs[saved_doc_count] = instr;
                saved_doc_count += 1;
            },
            else => {
                c.stack.push(instr.op.push_literal) catch return ParseError.OutOfMemory;
                pushed_count += 1;
            },
        }
    }

    // 3. Keep everything before the trail, including call_words and their operands, untouched
    instructions.items.len = tail_start;

    const old_tokenizer = c.parse_tokenizer;
    c.parse_tokenizer = tokenizer;
    defer c.parse_tokenizer = old_tokenizer;

    // 4. Run the parse-time word
    switch (word.action) {
        .native => |func| func(c) catch |err| return handleParseTimeError(c, err),
        .compound => |instrs| c.executeQuotation(.{ .instructions = instrs }) catch |err| return handleParseTimeError(c, err),
    }

    // 5. Capture all values above the pre-depth stack as `push_literal` instructions
    const post_depth = c.stack.depth();
    if (post_depth > pre_depth) {
        const num_results = post_depth - pre_depth;
        const base_idx = instructions.items.len;
        var i: usize = 0;

        while (i < num_results) : (i += 1) {
            const val = c.stack.pop() catch return ParseError.ParseTimeExecutionError;
            instructions.append(allocator, .{ .op = .{ .push_literal = val }, .line = line }) catch return ParseError.OutOfMemory;
        }

        std.mem.reverse(Instruction, instructions.items[base_idx..]);

        // Reïnsert saved doc_string instructions after the original
        // trailing literals, e.g., the name symbol, but before the
        // parse-time word's results: they end up between the name
        // and the definition value on the stack for `;` to collect.
        //
        // TODO(ripta): Hacky
        if (saved_doc_count > 0) {
            const insert_at = base_idx + @min(pushed_count, num_results);
            for (saved_doc_instrs[0..saved_doc_count]) |doc_instr| {
                instructions.insert(allocator, insert_at, doc_instr) catch return ParseError.OutOfMemory;
            }
        }
    } else if (saved_doc_count > 0) {
        for (saved_doc_instrs[0..saved_doc_count]) |doc_instr| {
            instructions.append(allocator, doc_instr) catch return ParseError.OutOfMemory;
        }
    }
}

/// Strip the `\\ ` prefix from a doc-comment token's text.
/// Returns the documentation content without the leading `\\ `.
fn stripDocCommentPrefix(text: []const u8) []const u8 {
    if (text.len <= 2) return "";
    if (text[2] == ' ' or text[2] == '\t') return text[3..];
    return text[2..];
}

/// Join multiple doc-comment lines into a single string separated by newlines.
fn joinDocLines(allocator: Allocator, lines: []const []const u8) ParseError![]const u8 {
    if (lines.len == 0) return "";
    if (lines.len == 1) return allocator.dupe(u8, lines[0]) catch return ParseError.OutOfMemory;

    var total_len: usize = lines.len - 1;
    for (lines) |line| total_len += line.len;

    const result = allocator.alloc(u8, total_len) catch return ParseError.OutOfMemory;
    var pos: usize = 0;
    for (lines, 0..) |line, i| {
        if (i > 0) {
            result[pos] = '\n';
            pos += 1;
        }
        @memcpy(result[pos..][0..line.len], line);
        pos += line.len;
    }
    return result;
}

/// Parse a top-level sequence of instructions. This is the entry point for
/// parsing, and handles continuation lines (multiline statements).
/// If ctx is provided, parse-time words will be executed during parsing.
pub fn parseTopLevel(allocator: Allocator, tokenizer: *Tokenizer, ctx: ?*Context) ParseError![]const Instruction {
    var instructions: std.ArrayListUnmanaged(Instruction) = .{};
    errdefer instructions.deinit(allocator);

    var doc_lines: std.ArrayListUnmanaged([]const u8) = .{};
    defer doc_lines.deinit(allocator);
    var doc_first_line: usize = 0;

    while (nextToken(tokenizer)) |tok| {
        if (tok.kind == .doc_comment) {
            doc_lines.append(allocator, stripDocCommentPrefix(tok.text)) catch return ParseError.OutOfMemory;
            if (doc_first_line == 0) doc_first_line = tok.line;
            continue;
        }

        const pending_doc_line = doc_first_line;
        const has_pending_docs = doc_lines.items.len > 0;

        const token = tok.text;
        const line = tok.line;
        const column = tok.column;
        if (std.mem.eql(u8, token, "[")) {
            const quotation = try parseQuotation(allocator, tokenizer, ctx, line);
            instructions.append(allocator, .{ .op = .{ .push_literal = .{ .quotation = quotation } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, "]")) {
            return ParseError.UnmatchedCloseBracket;
        } else if (std.mem.eql(u8, token, "{")) {
            const arr = try parseArray(allocator, tokenizer, ctx, line);
            instructions.append(allocator, .{ .op = .{ .push_literal = .{ .array = arr } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, "}")) {
            return ParseError.UnmatchedCloseBrace;
        } else if (std.mem.eql(u8, token, "(")) {
            const effect = try parseStackEffect(allocator, tokenizer, ctx, line);
            instructions.append(allocator, .{ .op = .{ .push_literal = .{ .stack_effect = effect } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, ")")) {
            return ParseError.UnmatchedCloseParen;
        } else if (parseInteger(token)) |n| {
            instructions.append(allocator, .{ .op = .{ .push_literal = .{ .fixnum = n } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
        } else if (parseBigNum(allocator, token)) |big| {
            instructions.append(allocator, .{ .op = .{ .push_literal = .{ .bignum = big } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
        } else if (parseFloat(token)) |f| {
            instructions.append(allocator, .{ .op = .{ .push_literal = .{ .float = f } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
        } else if (parseString(token)) |s| {
            const s_copy = processEscapes(allocator, s) catch return ParseError.OutOfMemory;
            instructions.append(allocator, .{ .op = .{ .push_literal = .{ .string = s_copy } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
        } else if (token.len > 0 and token[0] == '"') {
            setUnmatchedDiagnostics(ctx, "UnmatchedOpenQuote", line);
            return ParseError.UnmatchedOpenQuote;
        } else {
            // Check if this is a parse-time word
            if (ctx) |c| {
                if (c.lookupWord(token)) |word| {
                    if (word.parse_time) {
                        try executeParseTimeWord(c, word, tokenizer, &instructions, allocator, line);

                        if (has_pending_docs) {
                            doc_lines.clearRetainingCapacity();
                            doc_first_line = 0;
                        }

                        continue;
                    }
                }
            }

            if (token.len > 1 and token[token.len - 1] == ':') {
                const sym_copy = allocator.dupe(u8, token[0 .. token.len - 1]) catch return ParseError.OutOfMemory;
                instructions.append(allocator, .{ .op = .{ .push_literal = .{ .symbol = sym_copy } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;

                if (has_pending_docs) {
                    const doc_text = try joinDocLines(allocator, doc_lines.items);
                    instructions.append(allocator, .{ .op = .{ .push_literal = .{ .doc_string = doc_text } }, .line = pending_doc_line }) catch return ParseError.OutOfMemory;
                }
            } else {
                const name_copy = allocator.dupe(u8, token) catch return ParseError.OutOfMemory;
                instructions.append(allocator, .{ .op = .{ .call_word = name_copy }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
            }
        }

        if (has_pending_docs) {
            doc_lines.clearRetainingCapacity();
            doc_first_line = 0;
        }
    }

    return instructions.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
}

/// Parse a quotation. If ctx is provided, parse-time words will be executed.
/// A leading stack effect `( ... )` becomes the quotation's declared effect.
pub fn parseQuotation(allocator: Allocator, tokenizer: *Tokenizer, ctx: ?*Context, opening_line: usize) ParseError!Quotation {
    return parseQuotationUntil(allocator, tokenizer, ctx, "]", opening_line);
}

/// Parse a quotation terminated by a caller-specified delimiter.
pub fn parseQuotationUntil(allocator: Allocator, tokenizer: *Tokenizer, ctx: ?*Context, close_delim: []const u8, opening_line: usize) ParseError!Quotation {
    var instructions: std.ArrayListUnmanaged(Instruction) = .{};
    errdefer instructions.deinit(allocator);

    // Track if we should look for a leading stack effect
    var is_first_token = true;
    var quotation_effect: ?*const StackEffect = null;

    var doc_lines: std.ArrayListUnmanaged([]const u8) = .{};
    defer doc_lines.deinit(allocator);
    var doc_first_line: usize = 0;

    while (nextTokenOrYield(tokenizer)) |tok| {
        if (tok.kind == .doc_comment) {
            doc_lines.append(allocator, stripDocCommentPrefix(tok.text)) catch return ParseError.OutOfMemory;
            if (doc_first_line == 0) doc_first_line = tok.line;
            continue;
        }

        const pending_doc_line = doc_first_line;
        const has_pending_docs = doc_lines.items.len > 0;

        const token = tok.text;
        const line = tok.line;
        const column = tok.column;
        if (std.mem.eql(u8, token, close_delim)) {
            const instrs = instructions.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
            return Quotation{ .instructions = instrs, .effect = quotation_effect };
        } else if (std.mem.eql(u8, token, "[")) {
            is_first_token = false;
            const nested = try parseQuotation(allocator, tokenizer, ctx, line);
            instructions.append(allocator, .{ .op = .{ .push_literal = .{ .quotation = nested } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, "]")) {
            return ParseError.UnmatchedCloseBracket;
        } else if (std.mem.eql(u8, token, "{")) {
            is_first_token = false;
            const arr = try parseArray(allocator, tokenizer, ctx, line);
            instructions.append(allocator, .{ .op = .{ .push_literal = .{ .array = arr } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, "}")) {
            return ParseError.UnmatchedCloseBrace;
        } else if (std.mem.eql(u8, token, "(")) {
            const effect = try parseStackEffect(allocator, tokenizer, ctx, line);
            if (is_first_token) {
                // Leading stack effect becomes the quotation's declared effect
                const effect_ptr = allocator.create(StackEffect) catch return ParseError.OutOfMemory;
                effect_ptr.* = effect;
                quotation_effect = effect_ptr;
            } else {
                // Non-leading stack effect is pushed as a value
                instructions.append(allocator, .{ .op = .{ .push_literal = .{ .stack_effect = effect } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
            }
            is_first_token = false;
        } else if (std.mem.eql(u8, token, ")")) {
            return ParseError.UnmatchedCloseParen;
        } else if (parseInteger(token)) |n| {
            is_first_token = false;
            instructions.append(allocator, .{ .op = .{ .push_literal = .{ .fixnum = n } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
        } else if (parseBigNum(allocator, token)) |big| {
            is_first_token = false;
            instructions.append(allocator, .{ .op = .{ .push_literal = .{ .bignum = big } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
        } else if (parseFloat(token)) |f| {
            is_first_token = false;
            instructions.append(allocator, .{ .op = .{ .push_literal = .{ .float = f } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
        } else if (parseString(token)) |s| {
            is_first_token = false;
            const s_copy = processEscapes(allocator, s) catch return ParseError.OutOfMemory;
            instructions.append(allocator, .{ .op = .{ .push_literal = .{ .string = s_copy } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
        } else if (token.len > 0 and token[0] == '"') {
            setUnmatchedDiagnostics(ctx, "UnmatchedOpenQuote", line);
            return ParseError.UnmatchedOpenQuote;
        } else {
            // Check if this is a parse-time word
            if (ctx) |c| {
                if (c.lookupWord(token)) |word| {
                    if (word.parse_time) {
                        try executeParseTimeWord(c, word, tokenizer, &instructions, allocator, line);
                        is_first_token = false;

                        if (has_pending_docs) {
                            doc_lines.clearRetainingCapacity();
                            doc_first_line = 0;
                        }
                        continue;
                    }
                }
            }

            is_first_token = false;
            if (token.len > 1 and token[token.len - 1] == ':') {
                const sym_copy = allocator.dupe(u8, token[0 .. token.len - 1]) catch return ParseError.OutOfMemory;
                instructions.append(allocator, .{ .op = .{ .push_literal = .{ .symbol = sym_copy } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;

                if (has_pending_docs) {
                    const doc_text = try joinDocLines(allocator, doc_lines.items);
                    instructions.append(allocator, .{ .op = .{ .push_literal = .{ .doc_string = doc_text } }, .line = pending_doc_line }) catch return ParseError.OutOfMemory;
                }
            } else {
                const name_copy = allocator.dupe(u8, token) catch return ParseError.OutOfMemory;
                instructions.append(allocator, .{ .op = .{ .call_word = name_copy }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
            }
        }

        if (has_pending_docs) {
            doc_lines.clearRetainingCapacity();
            doc_first_line = 0;
        }
    }

    setUnmatchedDiagnostics(ctx, "UnmatchedOpenBracket", opening_line);
    return ParseError.UnmatchedOpenBracket;
}

/// Parse a stack effect with support for quotation annotations.
/// Handles nested parentheses for syntax like:
///   ( try-quot recover-quot: ( error -- ) -- )
///   ( seq quot: ( elem -- elem' ) -- seq' )
pub fn parseStackEffect(allocator: Allocator, tokenizer: *Tokenizer, ctx: ?*Context, opening_line: usize) ParseError!StackEffect {
    var inputs: std.ArrayListUnmanaged(StackEffectParam) = .{};
    errdefer inputs.deinit(allocator);

    var outputs: std.ArrayListUnmanaged(StackEffectParam) = .{};
    errdefer outputs.deinit(allocator);

    var current_list = &inputs;
    var pending_param_name: ?[]const u8 = null;

    while (nextTokenOrYield(tokenizer)) |tok| {
        if (tok.kind == .doc_comment) continue;

        const token = tok.text;
        if (std.mem.eql(u8, token, "(")) {
            // This should be a nested effect for the pending parameter
            if (pending_param_name) |name| {
                const nested = try parseStackEffect(allocator, tokenizer, ctx, tok.line);
                const nested_ptr = allocator.create(StackEffect) catch return ParseError.OutOfMemory;
                nested_ptr.* = nested;

                const param = StackEffectParam{
                    .name = name,
                    .quotation_effect = nested_ptr,
                };
                current_list.append(allocator, param) catch return ParseError.OutOfMemory;
                pending_param_name = null;
            } else {
                // Unexpected ( without a parameter name
                return ParseError.OutOfMemory;
            }
        } else if (std.mem.eql(u8, token, ")")) {
            // Flush any pending parameter
            if (pending_param_name) |name| {
                current_list.append(allocator, .{ .name = name }) catch return ParseError.OutOfMemory;
            }

            return StackEffect{
                .inputs = inputs.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
                .outputs = outputs.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
            };
        } else if (std.mem.eql(u8, token, "--")) {
            // Flush pending parameter before switching
            if (pending_param_name) |name| {
                current_list.append(allocator, .{ .name = name }) catch return ParseError.OutOfMemory;
                pending_param_name = null;
            }
            current_list = &outputs;
        } else if (token.len > 0 and token[token.len - 1] == ':') {
            // Flush previous pending parameter (if any)
            if (pending_param_name) |name| {
                current_list.append(allocator, .{ .name = name }) catch return ParseError.OutOfMemory;
            }
            // This is a parameter name with annotation (strip the colon)
            pending_param_name = allocator.dupe(u8, token[0 .. token.len - 1]) catch return ParseError.OutOfMemory;
        } else {
            // Flush previous pending parameter (if any)
            if (pending_param_name) |name| {
                current_list.append(allocator, .{ .name = name }) catch return ParseError.OutOfMemory;
            }
            // Regular parameter name
            pending_param_name = allocator.dupe(u8, token) catch return ParseError.OutOfMemory;
        }
    }

    setUnmatchedDiagnostics(ctx, "UnmatchedOpenParen", opening_line);
    return ParseError.UnmatchedOpenParen;
}

/// Execute a parse-time word during array parsing. Simplified version of
/// executeParseTimeWord that captures values directly instead of instructions.
/// Collection parse-time words consume only from the tokenizer, so no
/// trailing-literal barrier is needed.
///
/// TODO(ripta): Unify with executeParseTimeWord if we need parse-time words to consume
///              preceding array elements. For now, they only consume from the tokenizer.
///              See commit message that introduced this divergence for details.
fn executeParseTimeWordForArray(
    c: *Context,
    word: WordDefinition,
    tokenizer: *Tokenizer,
    values: *std.ArrayListUnmanaged(Value),
    allocator: Allocator,
) ParseError!void {
    const pre_depth = c.stack.depth();

    const old_tokenizer = c.parse_tokenizer;
    c.parse_tokenizer = tokenizer;
    defer c.parse_tokenizer = old_tokenizer;

    switch (word.action) {
        .native => |func| func(c) catch |err| return handleParseTimeError(c, err),
        .compound => |instrs| c.executeQuotation(.{ .instructions = instrs }) catch |err| return handleParseTimeError(c, err),
    }

    const post_depth = c.stack.depth();
    if (post_depth > pre_depth) {
        const num_results = post_depth - pre_depth;
        const base_idx = values.items.len;
        var i: usize = 0;

        while (i < num_results) : (i += 1) {
            const val = c.stack.pop() catch return ParseError.ParseTimeExecutionError;
            values.append(allocator, val) catch return ParseError.OutOfMemory;
        }

        std.mem.reverse(Value, values.items[base_idx..]);
    }
}

pub fn parseArray(allocator: Allocator, tokenizer: *Tokenizer, ctx: ?*Context, opening_line: usize) ParseError![]const Value {
    var values: std.ArrayListUnmanaged(Value) = .{};
    errdefer values.deinit(allocator);

    while (nextTokenOrYield(tokenizer)) |tok| {
        if (tok.kind == .doc_comment) continue;

        const token = tok.text;
        if (std.mem.eql(u8, token, "{")) {
            const nested = try parseArray(allocator, tokenizer, ctx, tok.line);
            values.append(allocator, .{ .array = nested }) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, "}")) {
            return values.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, "[")) {
            // Quotations inside arrays don't execute parse-time words (arrays are data)
            const quot = try parseQuotation(allocator, tokenizer, null, tok.line);
            values.append(allocator, .{ .quotation = quot }) catch return ParseError.OutOfMemory;
        } else if (parseInteger(token)) |n| {
            values.append(allocator, .{ .fixnum = n }) catch return ParseError.OutOfMemory;
        } else if (parseBigNum(allocator, token)) |big| {
            values.append(allocator, .{ .bignum = big }) catch return ParseError.OutOfMemory;
        } else if (parseFloat(token)) |f| {
            values.append(allocator, .{ .float = f }) catch return ParseError.OutOfMemory;
        } else if (parseString(token)) |s| {
            const s_copy = processEscapes(allocator, s) catch return ParseError.OutOfMemory;
            values.append(allocator, .{ .string = s_copy }) catch return ParseError.OutOfMemory;
        } else if (token.len > 0 and token[0] == '"') {
            setUnmatchedDiagnostics(ctx, "UnmatchedOpenQuote", tok.line);
            return ParseError.UnmatchedOpenQuote;
        } else if (token.len > 1 and token[token.len - 1] == ':') {
            const sym_copy = allocator.dupe(u8, token[0 .. token.len - 1]) catch return ParseError.OutOfMemory;
            values.append(allocator, .{ .symbol = sym_copy }) catch return ParseError.OutOfMemory;
        } else {
            if (ctx) |c| {
                if (c.lookupWord(token)) |word| {
                    if (word.parse_time) {
                        try executeParseTimeWordForArray(c, word, tokenizer, &values, allocator);
                        continue;
                    }
                }
            }
            return ParseError.InvalidArrayElement;
        }
    }

    setUnmatchedDiagnostics(ctx, "UnmatchedOpenBrace", opening_line);
    return ParseError.UnmatchedOpenBrace;
}

// =============================================================================
// Tests
// =============================================================================

test "parse simple quotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("1 2 + ]");
    const quot = try parseQuotation(arena.allocator(), &tokenizer, null, 0);

    try std.testing.expectEqual(@as(usize, 3), quot.instructions.len);
    try std.testing.expectEqual(@as(i64, 1), quot.instructions[0].op.push_literal.fixnum);
    try std.testing.expectEqual(@as(i64, 2), quot.instructions[1].op.push_literal.fixnum);
    try std.testing.expectEqualStrings("+", quot.instructions[2].op.call_word);
}

test "parse nested quotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("[ 1 ] ]");
    const quot = try parseQuotation(arena.allocator(), &tokenizer, null, 0);

    try std.testing.expectEqual(@as(usize, 1), quot.instructions.len);
    const nested = quot.instructions[0].op.push_literal.quotation;
    try std.testing.expectEqual(@as(usize, 1), nested.instructions.len);
    try std.testing.expectEqual(@as(i64, 1), nested.instructions[0].op.push_literal.fixnum);
}

test "parse quotation with leading stack effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("( n -- n ) dup ]");
    const quot = try parseQuotation(arena.allocator(), &tokenizer, null, 0);

    // The quotation should have an effect attached
    try std.testing.expect(quot.effect != null);
    try std.testing.expectEqual(@as(usize, 1), quot.effect.?.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), quot.effect.?.outputs.len);
    try std.testing.expectEqualStrings("n", quot.effect.?.inputs[0].name);
    try std.testing.expectEqualStrings("n", quot.effect.?.outputs[0].name);

    // The instructions should not include the stack effect
    try std.testing.expectEqual(@as(usize, 1), quot.instructions.len);
    try std.testing.expectEqualStrings("dup", quot.instructions[0].op.call_word);
}

test "parse quotation with non-leading stack effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Stack effect after other content is pushed as a value
    var tokenizer = Tokenizer.init("1 ( n -- n ) ]");
    const quot = try parseQuotation(arena.allocator(), &tokenizer, null, 0);

    // No quotation-level effect
    try std.testing.expect(quot.effect == null);

    // The stack effect should be a push_literal instruction
    try std.testing.expectEqual(@as(usize, 2), quot.instructions.len);
    try std.testing.expectEqual(@as(i64, 1), quot.instructions[0].op.push_literal.fixnum);
    const effect = quot.instructions[1].op.push_literal.stack_effect;
    try std.testing.expectEqual(@as(usize, 1), effect.inputs.len);
}

test "unmatched open bracket" {
    var tokenizer = Tokenizer.init("1 2");
    const result = parseQuotation(std.testing.allocator, &tokenizer, null, 0);
    try std.testing.expectError(ParseError.UnmatchedOpenBracket, result);
}

test "parse simple array" {
    var tokenizer = Tokenizer.init("1 2 3 }");
    const arr = try parseArray(std.testing.allocator, &tokenizer, null, 0);
    defer std.testing.allocator.free(arr);

    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(i64, 1), arr[0].fixnum);
    try std.testing.expectEqual(@as(i64, 2), arr[1].fixnum);
    try std.testing.expectEqual(@as(i64, 3), arr[2].fixnum);
}

test "parse nested array" {
    var tokenizer = Tokenizer.init("{ 1 2 } }");
    const arr = try parseArray(std.testing.allocator, &tokenizer, null, 0);
    defer std.testing.allocator.free(arr);

    try std.testing.expectEqual(@as(usize, 1), arr.len);
    const nested = arr[0].array;
    defer std.testing.allocator.free(nested);
    try std.testing.expectEqual(@as(usize, 2), nested.len);
    try std.testing.expectEqual(@as(i64, 1), nested[0].fixnum);
    try std.testing.expectEqual(@as(i64, 2), nested[1].fixnum);
}

test "parse array with string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("\"hello\" 42 }");
    const arr = try parseArray(arena.allocator(), &tokenizer, null, 0);

    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("hello", arr[0].string);
    try std.testing.expectEqual(@as(i64, 42), arr[1].fixnum);
}

test "unmatched open brace" {
    var tokenizer = Tokenizer.init("1 2");
    const result = parseArray(std.testing.allocator, &tokenizer, null, 0);
    try std.testing.expectError(ParseError.UnmatchedOpenBrace, result);
}

test "parse simple stack effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("n -- n )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer, null, 0);

    try std.testing.expectEqual(@as(usize, 1), effect.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), effect.outputs.len);
    try std.testing.expectEqualStrings("n", effect.inputs[0].name);
    try std.testing.expectEqualStrings("n", effect.outputs[0].name);
}

test "parse multi-arg stack effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("a b c -- sum )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer, null, 0);

    try std.testing.expectEqual(@as(usize, 3), effect.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), effect.outputs.len);
    try std.testing.expectEqualStrings("a", effect.inputs[0].name);
    try std.testing.expectEqualStrings("b", effect.inputs[1].name);
    try std.testing.expectEqualStrings("c", effect.inputs[2].name);
    try std.testing.expectEqualStrings("sum", effect.outputs[0].name);
}

test "parse empty stack effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("-- )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer, null, 0);

    try std.testing.expectEqual(@as(usize, 0), effect.inputs.len);
    try std.testing.expectEqual(@as(usize, 0), effect.outputs.len);
}

test "unmatched open paren" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("n -- n");
    const result = parseStackEffect(arena.allocator(), &tokenizer, null, 0);
    try std.testing.expectError(ParseError.UnmatchedOpenParen, result);
}

test "parse stack effect with quotation annotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("seq quot: ( elem -- elem' ) -- seq' )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer, null, 0);

    try std.testing.expectEqual(@as(usize, 2), effect.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), effect.outputs.len);

    // First input: seq (no annotation)
    try std.testing.expectEqualStrings("seq", effect.inputs[0].name);
    try std.testing.expect(effect.inputs[0].quotation_effect == null);

    // Second input: quot with annotation
    try std.testing.expectEqualStrings("quot", effect.inputs[1].name);
    try std.testing.expect(effect.inputs[1].quotation_effect != null);

    const nested = effect.inputs[1].quotation_effect.?;
    try std.testing.expectEqual(@as(usize, 1), nested.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), nested.outputs.len);
    try std.testing.expectEqualStrings("elem", nested.inputs[0].name);
    try std.testing.expectEqualStrings("elem'", nested.outputs[0].name);
}

test "parse recover stack effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("try-quot recover-quot: ( error -- ) -- )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer, null, 0);

    try std.testing.expectEqual(@as(usize, 2), effect.inputs.len);
    try std.testing.expectEqual(@as(usize, 0), effect.outputs.len);

    try std.testing.expectEqualStrings("try-quot", effect.inputs[0].name);
    try std.testing.expect(effect.inputs[0].quotation_effect == null);

    try std.testing.expectEqualStrings("recover-quot", effect.inputs[1].name);
    try std.testing.expect(effect.inputs[1].quotation_effect != null);

    const nested = effect.inputs[1].quotation_effect.?;
    try std.testing.expectEqual(@as(usize, 1), nested.inputs.len);
    try std.testing.expectEqual(@as(usize, 0), nested.outputs.len);
    try std.testing.expectEqualStrings("error", nested.inputs[0].name);
}

test "parse bi stack effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("x p: ( x -- a ) q: ( x -- b ) -- a b )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer, null, 0);

    try std.testing.expectEqual(@as(usize, 3), effect.inputs.len);
    try std.testing.expectEqual(@as(usize, 2), effect.outputs.len);

    // x has no annotation
    try std.testing.expectEqualStrings("x", effect.inputs[0].name);
    try std.testing.expect(effect.inputs[0].quotation_effect == null);

    // p and q have annotations
    try std.testing.expectEqualStrings("p", effect.inputs[1].name);
    try std.testing.expect(effect.inputs[1].quotation_effect != null);
    try std.testing.expectEqualStrings("q", effect.inputs[2].name);
    try std.testing.expect(effect.inputs[2].quotation_effect != null);
}

test "parse top level with stack effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("foo: ( n -- n ) [ 1 ]");
    const instrs = try parseTopLevel(arena.allocator(), &tokenizer, null);

    try std.testing.expectEqual(@as(usize, 3), instrs.len);
    try std.testing.expectEqualStrings("foo", instrs[0].op.push_literal.symbol);

    const effect = instrs[1].op.push_literal.stack_effect;
    try std.testing.expectEqual(@as(usize, 1), effect.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), effect.outputs.len);
    try std.testing.expectEqualStrings("n", effect.inputs[0].name);

    try std.testing.expectEqual(@as(usize, 1), instrs[2].op.push_literal.quotation.instructions.len);
}

test "parse top level with comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("\\ This is a comment\n1 2 +");
    const instrs = try parseTopLevel(arena.allocator(), &tokenizer, null);

    // Comment should be skipped
    try std.testing.expectEqual(@as(usize, 3), instrs.len);
    try std.testing.expectEqual(@as(i64, 1), instrs[0].op.push_literal.fixnum);
    try std.testing.expectEqual(@as(i64, 2), instrs[1].op.push_literal.fixnum);
    try std.testing.expectEqualStrings("+", instrs[2].op.call_word);
}

test "parse with inline comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("1 2 \\ inline comment\n+");
    const instrs = try parseTopLevel(arena.allocator(), &tokenizer, null);

    try std.testing.expectEqual(@as(usize, 3), instrs.len);
    try std.testing.expectEqual(@as(i64, 1), instrs[0].op.push_literal.fixnum);
    try std.testing.expectEqual(@as(i64, 2), instrs[1].op.push_literal.fixnum);
    try std.testing.expectEqualStrings("+", instrs[2].op.call_word);
}

test "parse-time word preserves preceding literals" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const alloc = ctx.quotationAllocator();
    const dup_instrs = try alloc.alloc(Instruction, 1);
    dup_instrs[0] = .{ .op = .{ .call_word = "dup" }, .line = 0 };

    try ctx.dictionary.put("test-dup", .{
        .name = "test-dup",
        .parse_time = true,
        .action = .{ .compound = dup_instrs },
    });

    var tokenizer = Tokenizer.init("foo: test-dup bar");
    const instrs = try parseTopLevel(alloc, &tokenizer, &ctx);

    try std.testing.expectEqual(@as(usize, 3), instrs.len);
    try std.testing.expectEqualStrings("foo", instrs[0].op.push_literal.symbol);
    try std.testing.expectEqualStrings("foo", instrs[1].op.push_literal.symbol);
    try std.testing.expectEqualStrings("bar", instrs[2].op.call_word);
}

test "parse-time word preserves call_word barrier ordering" {
    // Scenario: push_literal, call_word, push_literal, parse-time-word
    // Example: `foo: some-word bar: test-dup`
    // Expected: call_word barrier prevents foo: from being consumed by test-dup.
    //
    //   - foo: and some-word stay as instructions (push_literal + call_word)
    //   - bar: is the only trailing literal, so test-dup duplicates it
    //   - Result: [push_literal(foo:), call_word(some-word), push_literal(bar:), push_literal(bar:)]
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const alloc = ctx.quotationAllocator();
    const dup_instrs = try alloc.alloc(Instruction, 1);
    dup_instrs[0] = .{ .op = .{ .call_word = "dup" }, .line = 0 };

    try ctx.dictionary.put("test-dup", .{
        .name = "test-dup",
        .parse_time = true,
        .action = .{ .compound = dup_instrs },
    });

    var tokenizer = Tokenizer.init("foo: some-word bar: test-dup");
    const instrs = try parseTopLevel(alloc, &tokenizer, &ctx);

    try std.testing.expectEqual(@as(usize, 4), instrs.len);
    try std.testing.expectEqualStrings("foo", instrs[0].op.push_literal.symbol);
    try std.testing.expectEqualStrings("some-word", instrs[1].op.call_word);
    try std.testing.expectEqualStrings("bar", instrs[2].op.push_literal.symbol);
    try std.testing.expectEqualStrings("bar", instrs[3].op.push_literal.symbol);
}

test "doc-comment before definition emits doc_string after symbol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("\\\\ Add two numbers.\nfoo: 42");
    const instrs = try parseTopLevel(arena.allocator(), &tokenizer, null);

    try std.testing.expectEqual(@as(usize, 3), instrs.len);
    try std.testing.expectEqualStrings("foo", instrs[0].op.push_literal.symbol);
    try std.testing.expectEqualStrings("Add two numbers.", instrs[1].op.push_literal.doc_string);
    try std.testing.expectEqual(@as(i64, 42), instrs[2].op.push_literal.fixnum);
}

test "consecutive doc-comments joined with newlines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("\\\\ line one\n\\\\ line two\nfoo: 1");
    const instrs = try parseTopLevel(arena.allocator(), &tokenizer, null);

    try std.testing.expectEqual(@as(usize, 3), instrs.len);
    try std.testing.expectEqualStrings("foo", instrs[0].op.push_literal.symbol);
    try std.testing.expectEqualStrings("line one\nline two", instrs[1].op.push_literal.doc_string);
    try std.testing.expectEqual(@as(i64, 1), instrs[2].op.push_literal.fixnum);
}

test "orphaned doc-comment before non-symbol is discarded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("\\\\ orphaned\n42");
    const instrs = try parseTopLevel(arena.allocator(), &tokenizer, null);

    try std.testing.expectEqual(@as(usize, 1), instrs.len);
    try std.testing.expectEqual(@as(i64, 42), instrs[0].op.push_literal.fixnum);
}

test "doc-comment inside quotation emits doc_string after symbol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("\\\\ doc\nbar: 1 ]");
    const quot = try parseQuotation(arena.allocator(), &tokenizer, null, 0);

    try std.testing.expectEqual(@as(usize, 3), quot.instructions.len);
    try std.testing.expectEqualStrings("bar", quot.instructions[0].op.push_literal.symbol);
    try std.testing.expectEqualStrings("doc", quot.instructions[1].op.push_literal.doc_string);
    try std.testing.expectEqual(@as(i64, 1), quot.instructions[2].op.push_literal.fixnum);
}

test "doc-comment does not affect leading stack effect in quotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("\\\\ orphaned doc\n( n -- n ) dup ]");
    const quot = try parseQuotation(arena.allocator(), &tokenizer, null, 0);

    try std.testing.expect(quot.effect != null);
    try std.testing.expectEqual(@as(usize, 1), quot.effect.?.inputs.len);
    try std.testing.expectEqualStrings("n", quot.effect.?.inputs[0].name);

    try std.testing.expectEqual(@as(usize, 1), quot.instructions.len);
    try std.testing.expectEqualStrings("dup", quot.instructions[0].op.call_word);
}

test "doc-comment with definition in quotation preserves leading stack effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("( n -- n ) \\\\ doc\nfoo: 1 ]");
    const quot = try parseQuotation(arena.allocator(), &tokenizer, null, 0);

    try std.testing.expect(quot.effect != null);

    try std.testing.expectEqual(@as(usize, 3), quot.instructions.len);
    try std.testing.expectEqualStrings("foo", quot.instructions[0].op.push_literal.symbol);
    try std.testing.expectEqualStrings("doc", quot.instructions[1].op.push_literal.doc_string);
    try std.testing.expectEqual(@as(i64, 1), quot.instructions[2].op.push_literal.fixnum);
}

test "doc-comment line number preserved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("1\n\\\\ doc\nfoo: 2");
    const instrs = try parseTopLevel(arena.allocator(), &tokenizer, null);

    try std.testing.expectEqual(@as(usize, 4), instrs.len);
    try std.testing.expectEqualStrings("doc", instrs[2].op.push_literal.doc_string);
    try std.testing.expectEqual(@as(usize, 2), instrs[2].line);
}

test "stripDocCommentPrefix" {
    try std.testing.expectEqualStrings("", stripDocCommentPrefix("\\\\"));
    try std.testing.expectEqualStrings("hello", stripDocCommentPrefix("\\\\ hello"));
    try std.testing.expectEqualStrings("hello", stripDocCommentPrefix("\\\\\thello"));
    try std.testing.expectEqualStrings("", stripDocCommentPrefix("\\\\ "));
}

test "doc-comment in array is skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("1 \\\\ comment inside array\n2 }");
    const arr = try parseArray(arena.allocator(), &tokenizer, null, 0);

    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqual(@as(i64, 1), arr[0].fixnum);
    try std.testing.expectEqual(@as(i64, 2), arr[1].fixnum);
}
