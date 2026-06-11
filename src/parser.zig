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

const stack_effect_mod = @import("stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;
const StackEffectParam = stack_effect_mod.StackEffectParam;

const Context = @import("context.zig").Context;
const markers_mod = @import("primitives/markers.zig");
const Marker = value_mod.Marker;

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
    if (c.parse_diagnostics != null) {
        // Primitive already set diagnostics directly; preserve them.
    } else if (c.thrown_error) |thrown| {
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
    } else if (c.pending_error_message) |msg| {
        c.parse_diagnostics = .{
            .error_type = @errorName(err),
            .message = msg,
        };
        c.pending_error_message = null;
    } else {
        c.parse_diagnostics = .{
            .error_type = @errorName(err),
        };
    }
    c.clearExecutionDetails();
    return ParseError.ParseTimeExecutionError;
}

/// Scan backwards through `instructions` past markers and doc_strings to find a
/// stack_effect literal. If found, remove it and return a heap-allocated pointer
/// to the effect. Otherwise, return null.
fn extractPrecedingEffect(instructions: *std.ArrayListUnmanaged(Instruction), allocator: Allocator) ?*const StackEffect {
    var i = instructions.items.len;
    while (i > 0) {
        i -= 1;

        const item = instructions.items[i];
        if (item.op == .push_literal) {
            switch (item.op.push_literal) {
                .stack_effect => |se| {
                    const effect_ptr = allocator.create(StackEffect) catch return null;
                    effect_ptr.* = se;
                    // Remove the stack_effect instruction by shifting subsequent items down
                    std.mem.copyForwards(
                        Instruction,
                        instructions.items[i .. instructions.items.len - 1],
                        instructions.items[i + 1 .. instructions.items.len],
                    );
                    instructions.items.len -= 1;
                    return effect_ptr;
                },
                .marker, .doc_string => continue,
                else => return null,
            }
        } else {
            return null;
        }
    }

    return null;
}

/// Capture all values above the pre-depth stack as `push_literal` instructions
///
/// The `call_word` acts as a barrier: the parse-time word can only reach back
/// to literals that appear after the last `call_word` in the pending instruction
/// stream. This prevents reordering when `push_literals` and `call_words` are
/// interleaved.
///
/// Scan backwards through pending instructions for a parse-time or parse-time-
/// only marker literal, stopping at call_word barriers.
fn hasParseTimeMarkerInTrail(instructions: []const Instruction) bool {
    var i = instructions.len;
    while (i > 0) {
        i -= 1;
        switch (instructions[i].op) {
            .push_literal => |val| {
                switch (val) {
                    .marker => |mk| {
                        if (mk == &markers_mod.parse_time_marker or
                            mk == &markers_mod.parse_time_only_marker) return true;
                    },
                    else => {},
                }
            },
            .call_word, .call_word_direct => break,
        }
    }
    return false;
}

fn executeParseTimeWord(
    c: *Context,
    word: WordDefinition,
    tokenizer: *Tokenizer,
    instructions: *std.ArrayListUnmanaged(Instruction),
    allocator: Allocator,
    line: usize,
    column: usize,
) ParseError!void {
    const pre_depth = c.stack.depth();

    // 1. Find trailing `push_literal` instructions after the last `call_word` barrier
    var tail_start = instructions.items.len;
    while (tail_start > 0) {
        switch (instructions.items[tail_start - 1].op) {
            .push_literal => tail_start -= 1,
            .call_word, .call_word_direct => break,
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

    const old_invoke_file = c.parse_time_source_file;
    const old_invoke_line = c.parse_time_source_line;
    const old_invoke_column = c.parse_time_source_column;
    c.parse_time_source_file = c.current_source;
    c.parse_time_source_line = line + c.parse_line_offset;
    c.parse_time_source_column = column;
    defer c.parse_time_source_file = old_invoke_file;
    defer c.parse_time_source_line = old_invoke_line;
    defer c.parse_time_source_column = old_invoke_column;

    const old_tokenizer = c.parse_tokenizer;
    c.parse_tokenizer = tokenizer;
    defer c.parse_tokenizer = old_tokenizer;

    // 4. Run the parse-time word
    switch (word.action) {
        .native, .host_callback => word.invoke(c) catch |err| return handleParseTimeError(c, err),
        .compound => |instrs| c.executeQuotationWithFrame(.{ .instructions = instrs }) catch |err| return handleParseTimeError(c, err),
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

    // 6. Emit deferred call_word instructions requested via `emit-call`
    for (c.parse_time_deferred_calls.items) |call_name| {
        if (c.preResolveCallTarget(call_name)) |slot| {
            instructions.append(allocator, .{ .op = .{ .call_word_direct = slot }, .line = line }) catch return ParseError.OutOfMemory;
        } else {
            instructions.append(allocator, .{ .op = .{ .call_word = call_name }, .line = line }) catch return ParseError.OutOfMemory;
        }
    }
    c.parse_time_deferred_calls.clearRetainingCapacity();
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

/// Classification result for a token examined as a scalar literal.
const ClassifyResult = union(enum) {
    /// Token resolved to a scalar value (fixnum, bignum, float, string, or symbol).
    value: Value,
    /// Token starts with `"` but is not a complete string literal.
    unmatched_quote,
    /// Token is not a scalar literal.
    unrecognized,
};

/// Classify a token as a scalar literal value. Returns `.value` for fixnum,
/// bignum, float, quoted string, or trailing-colon symbol. Returns
/// `.unmatched_quote` for a bare open-quote token. Returns `.unrecognized`
/// for anything else.
fn classifyLiteral(allocator: Allocator, token: []const u8) Allocator.Error!ClassifyResult {
    if (parseInteger(token)) |n| {
        return .{ .value = .{ .fixnum = n } };
    }
    if (parseBigNum(allocator, token)) |big| {
        return .{ .value = .{ .bignum = try value_mod.boxBigInt(allocator, big) } };
    }
    if (parseFloat(token)) |f| {
        return .{ .value = .{ .float = f } };
    }
    if (parseString(token)) |s| {
        const s_copy = try processEscapes(allocator, s);
        return .{ .value = .{ .string = s_copy } };
    }
    if (token.len > 0 and token[0] == '"') {
        return .unmatched_quote;
    }
    if (token.len > 1 and token[token.len - 1] == ':') {
        const sym_copy = try allocator.dupe(u8, token[0 .. token.len - 1]);
        return .{ .value = .{ .symbol = sym_copy } };
    }
    return .unrecognized;
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
            const preceding_effect = extractPrecedingEffect(&instructions, allocator);
            if (ctx) |c| {
                if (hasParseTimeMarkerInTrail(instructions.items)) {
                    const old = c.parsing_parse_time_def;
                    c.parsing_parse_time_def = true;

                    var quotation = try parseQuotation(allocator, tokenizer, ctx, line);
                    c.parsing_parse_time_def = old;

                    if (quotation.effect == null) quotation.effect = preceding_effect;
                    instructions.append(allocator, .{ .op = .{ .push_literal = .{ .quotation = quotation } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
                } else {
                    var quotation = try parseQuotation(allocator, tokenizer, ctx, line);

                    if (quotation.effect == null) quotation.effect = preceding_effect;
                    instructions.append(allocator, .{ .op = .{ .push_literal = .{ .quotation = quotation } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
                }
            } else {
                var quotation = try parseQuotation(allocator, tokenizer, ctx, line);
                if (quotation.effect == null) quotation.effect = preceding_effect;
                instructions.append(allocator, .{ .op = .{ .push_literal = .{ .quotation = quotation } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
            }
        } else if (std.mem.eql(u8, token, "]")) {
            return ParseError.UnmatchedCloseBracket;
        } else if (std.mem.eql(u8, token, "{")) {
            const arr = try parseArray(allocator, tokenizer, ctx, line);
            instructions.append(allocator, .{ .op = .{ .push_literal = .{ .array = arr } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, "}")) {
            return ParseError.UnmatchedCloseBrace;
        } else if (std.mem.eql(u8, token, "(") and ctx == null) {
            const effect = try parseStackEffect(allocator, tokenizer, null, line);
            instructions.append(allocator, .{ .op = .{ .push_literal = .{ .stack_effect = effect } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, ")")) {
            return ParseError.UnmatchedCloseParen;
        } else {
            const classified = classifyLiteral(allocator, token) catch return ParseError.OutOfMemory;
            switch (classified) {
                .value => |val| {
                    instructions.append(allocator, .{ .op = .{ .push_literal = val }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
                    if (val == .symbol and has_pending_docs) {
                        const doc_text = try joinDocLines(allocator, doc_lines.items);
                        instructions.append(allocator, .{ .op = .{ .push_literal = .{ .doc_string = doc_text } }, .line = pending_doc_line }) catch return ParseError.OutOfMemory;
                    }
                },
                .unmatched_quote => {
                    setUnmatchedDiagnostics(ctx, "UnmatchedOpenQuote", line);
                    return ParseError.UnmatchedOpenQuote;
                },
                .unrecognized => {
                    if (ctx != null) {
                        if (try maybeParseTypeUnionToken(allocator, tokenizer, ctx, token)) |union_type| {
                            instructions.append(allocator, .{ .op = .{ .push_literal = .{ .type_val = @constCast(union_type) } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
                            if (has_pending_docs) {
                                doc_lines.clearRetainingCapacity();
                                doc_first_line = 0;
                            }
                            continue;
                        }
                    }
                    if (ctx) |c| {
                        if (c.lookupWord(token)) |word| {
                            if (word.parse_time) {
                                try executeParseTimeWord(c, word, tokenizer, &instructions, allocator, line, column);

                                if (has_pending_docs) {
                                    doc_lines.clearRetainingCapacity();
                                    doc_first_line = 0;
                                }

                                continue;
                            }
                        }
                    }

                    if (ctx) |c| {
                        if (c.preResolveCallTarget(token)) |slot| {
                            instructions.append(allocator, .{ .op = .{ .call_word_direct = slot }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
                        } else {
                            const name_copy = allocator.dupe(u8, token) catch return ParseError.OutOfMemory;
                            instructions.append(allocator, .{ .op = .{ .call_word = name_copy }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
                        }
                    } else {
                        const name_copy = allocator.dupe(u8, token) catch return ParseError.OutOfMemory;
                        instructions.append(allocator, .{ .op = .{ .call_word = name_copy }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
                    }
                },
            }
        }

        if (has_pending_docs) {
            doc_lines.clearRetainingCapacity();
            doc_first_line = 0;
        }
    }

    const instrs = instructions.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
    if (ctx) |c| {
        c.registerQuotationContainerLiterals(instrs) catch return ParseError.OutOfMemory;
    }
    return instrs;
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
            if (ctx) |c| {
                c.registerQuotationContainerLiterals(instrs) catch return ParseError.OutOfMemory;
            }
            return Quotation{ .instructions = instrs, .effect = quotation_effect };
        } else if (std.mem.eql(u8, token, "[")) {
            is_first_token = false;
            const preceding_effect = extractPrecedingEffect(&instructions, allocator);

            if (ctx) |c| {
                if (hasParseTimeMarkerInTrail(instructions.items)) {
                    const old = c.parsing_parse_time_def;
                    c.parsing_parse_time_def = true;
                    var nested = try parseQuotation(allocator, tokenizer, ctx, line);
                    c.parsing_parse_time_def = old;
                    if (nested.effect == null) nested.effect = preceding_effect;
                    instructions.append(allocator, .{ .op = .{ .push_literal = .{ .quotation = nested } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
                } else {
                    var nested = try parseQuotation(allocator, tokenizer, ctx, line);
                    if (nested.effect == null) nested.effect = preceding_effect;
                    instructions.append(allocator, .{ .op = .{ .push_literal = .{ .quotation = nested } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
                }
            } else {
                var nested = try parseQuotation(allocator, tokenizer, ctx, line);
                if (nested.effect == null) nested.effect = preceding_effect;
                instructions.append(allocator, .{ .op = .{ .push_literal = .{ .quotation = nested } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
            }
        } else if (std.mem.eql(u8, token, "]")) {
            return ParseError.UnmatchedCloseBracket;
        } else if (std.mem.eql(u8, token, "{")) {
            is_first_token = false;
            const arr = try parseArray(allocator, tokenizer, ctx, line);
            instructions.append(allocator, .{ .op = .{ .push_literal = .{ .array = arr } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
        } else if (std.mem.eql(u8, token, "}")) {
            return ParseError.UnmatchedCloseBrace;
        } else if (std.mem.eql(u8, token, "(") and ctx == null) {
            const effect = try parseStackEffect(allocator, tokenizer, null, line);
            if (is_first_token) {
                const effect_ptr = allocator.create(StackEffect) catch return ParseError.OutOfMemory;
                effect_ptr.* = effect;
                quotation_effect = effect_ptr;
            } else {
                instructions.append(allocator, .{ .op = .{ .push_literal = .{ .stack_effect = effect } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
            }
            is_first_token = false;
        } else if (std.mem.eql(u8, token, ")")) {
            return ParseError.UnmatchedCloseParen;
        } else {
            const classified = classifyLiteral(allocator, token) catch return ParseError.OutOfMemory;
            switch (classified) {
                .value => |val| {
                    is_first_token = false;
                    instructions.append(allocator, .{ .op = .{ .push_literal = val }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
                    if (val == .symbol and has_pending_docs) {
                        const doc_text = try joinDocLines(allocator, doc_lines.items);
                        instructions.append(allocator, .{ .op = .{ .push_literal = .{ .doc_string = doc_text } }, .line = pending_doc_line }) catch return ParseError.OutOfMemory;
                    }
                },
                .unmatched_quote => {
                    setUnmatchedDiagnostics(ctx, "UnmatchedOpenQuote", line);
                    return ParseError.UnmatchedOpenQuote;
                },
                .unrecognized => {
                    if (ctx != null) {
                        if (try maybeParseTypeUnionToken(allocator, tokenizer, ctx, token)) |union_type| {
                            is_first_token = false;
                            instructions.append(allocator, .{ .op = .{ .push_literal = .{ .type_val = @constCast(union_type) } }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
                            if (has_pending_docs) {
                                doc_lines.clearRetainingCapacity();
                                doc_first_line = 0;
                            }
                            continue;
                        }
                    }
                    if (ctx) |c| {
                        if (c.lookupWord(token)) |word| {
                            if (word.parse_time) {
                                if (word.parse_time_only and !c.parsing_parse_time_def and c.parse_tokenizer == null) {
                                    c.parse_diagnostics = .{
                                        .error_type = "ParseTimeOnly",
                                        .message = std.fmt.allocPrint(allocator, "'{s}' can only be used in parse-time definitions", .{token}) catch null,
                                    };
                                    return ParseError.ParseTimeExecutionError;
                                }
                                const was_first_token = is_first_token;
                                try executeParseTimeWord(c, word, tokenizer, &instructions, allocator, line, column);

                                if (was_first_token and instructions.items.len > 0) {
                                    const last = instructions.items[instructions.items.len - 1];
                                    if (last.op == .push_literal and last.op.push_literal == .stack_effect) {
                                        const effect_ptr = allocator.create(StackEffect) catch return ParseError.OutOfMemory;
                                        effect_ptr.* = last.op.push_literal.stack_effect;
                                        quotation_effect = effect_ptr;
                                        instructions.items.len -= 1;
                                    }
                                }

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
                    if (ctx) |c| {
                        if (c.preResolveCallTarget(token)) |slot| {
                            instructions.append(allocator, .{ .op = .{ .call_word_direct = slot }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
                        } else {
                            const name_copy = allocator.dupe(u8, token) catch return ParseError.OutOfMemory;
                            instructions.append(allocator, .{ .op = .{ .call_word = name_copy }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
                        }
                    } else {
                        const name_copy = allocator.dupe(u8, token) catch return ParseError.OutOfMemory;
                        instructions.append(allocator, .{ .op = .{ .call_word = name_copy }, .line = line, .column = column }) catch return ParseError.OutOfMemory;
                    }
                },
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

/// Return whether the token can plausibly name a type annotation.
/// Excludes delimiters, declaration names, and tokens containing syntax
/// characters that are never valid standalone type names here.
fn isTypeAnnotationCandidate(token: []const u8) bool {
    if (token.len == 0) return false;
    if (std.mem.eql(u8, token, "|") or
        std.mem.eql(u8, token, "&") or
        std.mem.eql(u8, token, "--") or
        std.mem.eql(u8, token, ";") or
        std.mem.eql(u8, token, "(") or
        std.mem.eql(u8, token, ")") or
        std.mem.eql(u8, token, "[") or
        std.mem.eql(u8, token, "]") or
        std.mem.eql(u8, token, "{") or
        std.mem.eql(u8, token, "}")) return false;

    if (token[token.len - 1] == ':') return false;
    if (std.mem.indexOfAny(u8, token, "{}[];|&")) |_| return false;
    return true;
}

/// Result of resolving a constraint in stack-effect annotation position: a
/// concrete `TypeValue` (the existing path -- includes the `self` and `any`
/// marker sentinels and pure type unions), a `ProtocolDescriptor` produced by a
/// constraint-pushing protocol word, or a `ConstraintCombinator` built from an
/// `&` / `|` constraint expression.
const ResolvedAnnotation = union(enum) {
    type: *const value_mod.TypeValue,
    protocol: *const value_mod.ProtocolDescriptor,
    combination: *const value_mod.ConstraintCombinator,
};

/// Resolve a type annotation token by looking up the word in the context
/// and, when the word is a parse-time const, executing it and consuming the
/// single value it pushes. Returns null if ctx is null (as in unit tests),
/// the token is not a candidate, the word is not parse-time, or the pushed
/// value is neither a type nor a protocol descriptor.
fn resolveTypeAnnotation(ctx: ?*Context, token: []const u8) ?ResolvedAnnotation {
    const c = ctx orelse return null;
    if (!isTypeAnnotationCandidate(token)) return null;
    if (c.lookupWord(token)) |word| {
        if (word.parse_time) {
            const old_tokenizer = c.parse_tokenizer;
            defer c.parse_tokenizer = old_tokenizer;

            const pre_depth = c.stack.depth();
            switch (word.action) {
                .native, .host_callback => word.invoke(c) catch return null,
                .compound => |instrs| c.executeQuotation(.{ .instructions = instrs }) catch return null,
            }

            const post_depth = c.stack.depth();
            if (post_depth > pre_depth) {
                const val = c.stack.pop() catch return null;
                if (val == .type_val) return .{ .type = val.type_val };
                if (val == .protocol_descriptor) return .{ .protocol = val.protocol_descriptor };
                if (val == .marker) {
                    if (markers_mod.isSelfMarker(val.marker)) return .{ .type = c.getSelfTypeSentinel() };
                    if (markers_mod.isAnyMarker(val.marker)) return .{ .type = c.getAnyTypeSentinel() };
                }
            }
        }
    }

    return null;
}

/// Raise a parse-time diagnostic for malformed inline type unions.
fn invalidTypeUnion(ctx: ?*Context, allocator: Allocator, comptime fmt: []const u8, args: anytype) ParseError {
    if (ctx) |c| {
        c.parse_diagnostics = .{
            .error_type = "InvalidTypeUnion",
            .message = std.fmt.allocPrint(allocator, fmt, args) catch null,
        };
        return ParseError.ParseTimeExecutionError;
    }
    return ParseError.OutOfMemory;
}

/// Parse the remaining `| T | U ...` tail after the first type token has
/// already been resolved. Produces the canonical anonymous union type.
fn parseTypeUnionTail(
    allocator: Allocator,
    tokenizer: *Tokenizer,
    ctx: ?*Context,
    first_type: *const value_mod.TypeValue,
) ParseError!*const value_mod.TypeValue {
    const c = ctx orelse return first_type;

    var members = std.ArrayListUnmanaged(*const value_mod.TypeValue){};
    defer members.deinit(allocator);
    members.append(allocator, first_type) catch return ParseError.OutOfMemory;

    while (true) {
        const member_tok = nextTokenOrYield(tokenizer) orelse {
            return invalidTypeUnion(ctx, allocator, "expected a type after '|'", .{});
        };
        const resolved = resolveTypeAnnotation(ctx, member_tok.text) orelse {
            return invalidTypeUnion(ctx, allocator, "'{s}' is not a known type in union position", .{member_tok.text});
        };
        const member_type = switch (resolved) {
            .type => |t| t,
            .protocol, .combination => return invalidTypeUnion(ctx, allocator, "protocol '{s}' cannot appear in a type union; protocol composition with '|' is not yet supported", .{member_tok.text}),
        };
        members.append(allocator, member_type) catch return ParseError.OutOfMemory;

        const next_tok = nextTokenOrYield(tokenizer) orelse {
            return c.getOrCreateAnonymousUnionTypeValue(members.items) catch return ParseError.OutOfMemory;
        };
        if (std.mem.eql(u8, next_tok.text, "|")) continue;
        tokenizer.peeked = next_tok;
        return c.getOrCreateAnonymousUnionTypeValue(members.items) catch return ParseError.OutOfMemory;
    }
}

/// Raise a parse-time diagnostic for a malformed `&` / `|` constraint
/// expression.
fn invalidConstraint(ctx: ?*Context, allocator: Allocator, comptime fmt: []const u8, args: anytype) ParseError {
    if (ctx) |c| {
        c.parse_diagnostics = .{
            .error_type = "InvalidConstraint",
            .message = std.fmt.allocPrint(allocator, fmt, args) catch null,
        };
        return ParseError.ParseTimeExecutionError;
    }
    return ParseError.OutOfMemory;
}

/// Resolve a single constraint atom token into a combinator element. Returns
/// null when the token does not resolve to a type or constraint.
fn resolveAtomElement(ctx: ?*Context, token: []const u8) ?value_mod.ConstraintCombinator.Element {
    const resolved = resolveTypeAnnotation(ctx, token) orelse return null;
    return switch (resolved) {
        .type => |t| .{ .type = t },
        .protocol => |p| .{ .protocol = p },
        // A single token resolves to a named combinator once the named
        // top-level constraint form lands; it does not today, but the mapping
        // keeps the arm exhaustive.
        .combination => |c| .{ .combinator = c },
    };
}

/// Parse one conjunction: an atom followed by a greedy run of `& atom`. `&`
/// binds tighter than `|`, so a conjunction is the inner term of the
/// disjunction-of-conjunctions normal form. A single atom returns its element
/// directly; multiple atoms intern an intersection combinator. Returns null
/// only when the head atom does not resolve (the caller decides whether that is
/// a silent drop or an error).
fn parseConjunction(
    allocator: Allocator,
    tokenizer: *Tokenizer,
    ctx: ?*Context,
    head_token: []const u8,
) ParseError!?value_mod.ConstraintCombinator.Element {
    const head = resolveAtomElement(ctx, head_token) orelse return null;
    const c = ctx orelse return head;

    var atoms = std.ArrayListUnmanaged(value_mod.ConstraintCombinator.Element){};
    defer atoms.deinit(allocator);
    atoms.append(allocator, head) catch return ParseError.OutOfMemory;

    while (true) {
        const next_tok = nextTokenOrYield(tokenizer) orelse break;
        if (!std.mem.eql(u8, next_tok.text, "&")) {
            tokenizer.peeked = next_tok;
            break;
        }
        const atom_tok = nextTokenOrYield(tokenizer) orelse {
            return invalidConstraint(ctx, allocator, "expected a constraint after '&'", .{});
        };
        if (std.mem.eql(u8, atom_tok.text, "&") or std.mem.eql(u8, atom_tok.text, "|")) {
            return invalidConstraint(ctx, allocator, "expected a constraint after '&', found '{s}'", .{atom_tok.text});
        }
        const atom = resolveAtomElement(ctx, atom_tok.text) orelse {
            return invalidConstraint(ctx, allocator, "'{s}' is not a known type or constraint", .{atom_tok.text});
        };
        atoms.append(allocator, atom) catch return ParseError.OutOfMemory;
    }

    if (atoms.items.len == 1) return atoms.items[0];
    const cc = c.createConstraintCombinator(.intersection, atoms.items) catch return ParseError.OutOfMemory;
    return .{ .combinator = cc };
}

/// Convert a resolved combinator element into the annotation stored on a
/// stack-effect parameter.
fn elementToAnnotation(element: value_mod.ConstraintCombinator.Element) ResolvedAnnotation {
    return switch (element) {
        .type => |t| .{ .type = t },
        .protocol => |p| .{ .protocol = p },
        .combinator => |c| .{ .combination = c },
    };
}

/// Parse a constraint expression in stack-effect annotation position. Handles a
/// bare type or protocol, a pure type union (`fixnum | bignum`, kept as a
/// `TypeValue`), an intersection (`comparable & stringable`), and a mixed union
/// (`fixnum | comparable`). `&` binds tighter than `|`; both are greedy
/// continuation markers. Leading `&` / `|` and adjacent doubles are errors. A
/// head that does not resolve returns null, leaving the parameter unannotated,
/// matching the prior behavior for unknown annotation tokens.
fn parseConstraintAnnotation(
    allocator: Allocator,
    tokenizer: *Tokenizer,
    ctx: ?*Context,
    token: []const u8,
) ParseError!?ResolvedAnnotation {
    if (std.mem.eql(u8, token, "&") or std.mem.eql(u8, token, "|")) {
        return invalidConstraint(ctx, allocator, "constraint expression cannot begin with '{s}'", .{token});
    }

    const first = (try parseConjunction(allocator, tokenizer, ctx, token)) orelse return null;
    const c = ctx orelse return elementToAnnotation(first);

    var disjuncts = std.ArrayListUnmanaged(value_mod.ConstraintCombinator.Element){};
    defer disjuncts.deinit(allocator);
    disjuncts.append(allocator, first) catch return ParseError.OutOfMemory;

    while (true) {
        const next_tok = nextTokenOrYield(tokenizer) orelse break;
        if (!std.mem.eql(u8, next_tok.text, "|")) {
            tokenizer.peeked = next_tok;
            break;
        }
        const conj_tok = nextTokenOrYield(tokenizer) orelse {
            return invalidConstraint(ctx, allocator, "expected a constraint after '|'", .{});
        };
        if (std.mem.eql(u8, conj_tok.text, "&") or std.mem.eql(u8, conj_tok.text, "|")) {
            return invalidConstraint(ctx, allocator, "expected a constraint after '|', found '{s}'", .{conj_tok.text});
        }
        const conj = (try parseConjunction(allocator, tokenizer, ctx, conj_tok.text)) orelse {
            return invalidConstraint(ctx, allocator, "'{s}' is not a known type or constraint", .{conj_tok.text});
        };
        disjuncts.append(allocator, conj) catch return ParseError.OutOfMemory;
    }

    if (disjuncts.items.len == 1) return elementToAnnotation(disjuncts.items[0]);

    // A union whose every disjunct is a concrete type stays a pure type union on
    // TypeValue.member_types; as soon as a protocol or intersection joins, the
    // union becomes a ConstraintCombinator.
    var all_types = true;
    for (disjuncts.items) |d| {
        if (d != .type) {
            all_types = false;
            break;
        }
    }
    if (all_types) {
        var members = std.ArrayListUnmanaged(*const value_mod.TypeValue){};
        defer members.deinit(allocator);
        for (disjuncts.items) |d| members.append(allocator, d.type) catch return ParseError.OutOfMemory;
        const union_type = c.getOrCreateAnonymousUnionTypeValue(members.items) catch return ParseError.OutOfMemory;
        return .{ .type = union_type };
    }

    const cc = c.createConstraintCombinator(.@"union", disjuncts.items) catch return ParseError.OutOfMemory;
    return .{ .combination = cc };
}

/// Try to interpret an otherwise-unrecognized token as the start of an
/// anonymous type union in general parse-time value contexts.
pub fn maybeParseTypeUnionToken(
    allocator: Allocator,
    tokenizer: *Tokenizer,
    ctx: ?*Context,
    token: []const u8,
) ParseError!?*const value_mod.TypeValue {
    if (!isTypeAnnotationCandidate(token)) return null;

    // Quick peek at the raw input to check for a `|` continuation without
    // consuming any tokens or mutating tokenizer state.
    if (!peekNextTokenIsPipe(tokenizer)) return null;

    const first = resolveTypeAnnotation(ctx, token) orelse return null;
    const first_type = switch (first) {
        .type => |t| t,
        .protocol, .combination => return null,
    };
    // Consume the `|` we already verified is there.
    _ = nextTokenOrYield(tokenizer);
    return parseTypeUnionTail(allocator, tokenizer, ctx, first_type);
}

/// Check whether the next non-whitespace, non-comment token in the raw input
/// is the single-character `|` token, without advancing the tokenizer state.
fn peekNextTokenIsPipe(tokenizer: *const Tokenizer) bool {
    if (tokenizer.peeked) |tok| return std.mem.eql(u8, tok.text, "|");
    var pos = tokenizer.pos;
    while (pos < tokenizer.input.len) : (pos += 1) {
        const c = tokenizer.input[pos];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') continue;
        if (c == '\\') return false; // comment, so stop scanning
        return c == '|' and (pos + 1 >= tokenizer.input.len or isWhitespace(tokenizer.input[pos + 1]));
    }
    return false;
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
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
    var pending_is_annotated: bool = false;

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
                    .is_row_variable = stack_effect_mod.isRowVariable(name),
                };
                current_list.append(allocator, param) catch return ParseError.OutOfMemory;
                pending_param_name = null;
                pending_is_annotated = false;
            } else {
                // Unexpected ( without a parameter name
                return ParseError.OutOfMemory;
            }
        } else if (std.mem.eql(u8, token, ")")) {
            if (pending_is_annotated) {
                // Annotation colon without a type following
                return ParseError.OutOfMemory;
            }
            // Flush any pending parameter
            if (pending_param_name) |name| {
                current_list.append(allocator, .{ .name = name, .is_row_variable = stack_effect_mod.isRowVariable(name) }) catch return ParseError.OutOfMemory;
            }

            return StackEffect{
                .inputs = inputs.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
                .outputs = outputs.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
            };
        } else if (std.mem.eql(u8, token, "--")) {
            if (pending_is_annotated) {
                // Annotation colon without a type following
                return ParseError.OutOfMemory;
            }
            // Flush pending parameter before switching
            if (pending_param_name) |name| {
                current_list.append(allocator, .{ .name = name, .is_row_variable = stack_effect_mod.isRowVariable(name) }) catch return ParseError.OutOfMemory;
                pending_param_name = null;
            }
            current_list = &outputs;
        } else if (pending_param_name) |name| {
            if (pending_is_annotated) {
                const resolved = try parseConstraintAnnotation(allocator, tokenizer, ctx, token);
                const ann: ?stack_effect_mod.TypeAnnotation = if (resolved) |r| switch (r) {
                    .type => |tv| .{ .type = tv },
                    .protocol => |pd| .{ .protocol = pd },
                    .combination => |cc| .{ .combination = cc },
                } else null;
                current_list.append(allocator, .{
                    .name = name,
                    .type_annotation = ann,
                    .is_row_variable = stack_effect_mod.isRowVariable(name),
                }) catch return ParseError.OutOfMemory;
                pending_param_name = null;
                pending_is_annotated = false;
            } else if (token.len > 0 and token[token.len - 1] == ':') {
                current_list.append(allocator, .{ .name = name, .is_row_variable = stack_effect_mod.isRowVariable(name) }) catch return ParseError.OutOfMemory;
                pending_param_name = allocator.dupe(u8, token[0 .. token.len - 1]) catch return ParseError.OutOfMemory;
                pending_is_annotated = true;
            } else {
                current_list.append(allocator, .{ .name = name, .is_row_variable = stack_effect_mod.isRowVariable(name) }) catch return ParseError.OutOfMemory;
                pending_param_name = allocator.dupe(u8, token) catch return ParseError.OutOfMemory;
                pending_is_annotated = false;
            }
        } else if (token.len > 0 and token[token.len - 1] == ':') {
            pending_param_name = allocator.dupe(u8, token[0 .. token.len - 1]) catch return ParseError.OutOfMemory;
            pending_is_annotated = true;
        } else {
            pending_param_name = allocator.dupe(u8, token) catch return ParseError.OutOfMemory;
            pending_is_annotated = false;
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
        .native, .host_callback => word.invoke(c) catch |err| return handleParseTimeError(c, err),
        .compound => |instrs| c.executeQuotationWithFrame(.{ .instructions = instrs }) catch |err| return handleParseTimeError(c, err),
    }

    // Execute deferred calls, e.g., `emit-call` from `V{`, `B{`, `M{`, so the
    // final value is produced immediately rather than left as a raw quotation.
    for (c.parse_time_deferred_calls.items) |call_name| {
        if (c.lookupWord(call_name)) |deferred_word| {
            switch (deferred_word.action) {
                .native, .host_callback => deferred_word.invoke(c) catch |err| return handleParseTimeError(c, err),
                .compound => |instrs| c.executeQuotationWithFrame(.{ .instructions = instrs }) catch |err| return handleParseTimeError(c, err),
            }
        }
    }
    c.parse_time_deferred_calls.clearRetainingCapacity();

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
        } else {
            const classified = classifyLiteral(allocator, token) catch return ParseError.OutOfMemory;
            switch (classified) {
                .value => |val| {
                    values.append(allocator, val) catch return ParseError.OutOfMemory;
                },
                .unmatched_quote => {
                    setUnmatchedDiagnostics(ctx, "UnmatchedOpenQuote", tok.line);
                    return ParseError.UnmatchedOpenQuote;
                },
                .unrecognized => {
                    if (ctx) |c| {
                        if (c.lookupWord(token)) |word| {
                            if (word.parse_time) {
                                if (word.parse_time_only and !c.parsing_parse_time_def and c.parse_tokenizer == null) {
                                    c.parse_diagnostics = .{
                                        .error_type = "ParseTimeOnly",
                                        .message = std.fmt.allocPrint(allocator, "'{s}' can only be used in parse-time definitions", .{token}) catch null,
                                    };
                                    return ParseError.ParseTimeExecutionError;
                                }
                                try executeParseTimeWordForArray(c, word, tokenizer, &values, allocator);
                                continue;
                            }
                        }
                        c.parse_diagnostics = .{
                            .error_type = "InvalidArrayElement",
                            .message = std.fmt.allocPrint(allocator, "'{s}' is not a literal value", .{token}) catch null,
                        };
                    }
                    return ParseError.InvalidArrayElement;
                },
            }
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

    try std.testing.expectEqual(@as(usize, 2), instrs.len);
    try std.testing.expectEqualStrings("foo", instrs[0].op.push_literal.symbol);

    const quot = instrs[1].op.push_literal.quotation;
    try std.testing.expect(quot.effect != null);
    try std.testing.expectEqual(@as(usize, 1), quot.effect.?.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), quot.effect.?.outputs.len);
    try std.testing.expectEqualStrings("n", quot.effect.?.inputs[0].name);
    try std.testing.expectEqual(@as(usize, 1), quot.instructions.len);
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

test "parse row-polymorphic stack effect sets is_row_variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("..a x -- ..a x y )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer, null, 0);

    try std.testing.expectEqual(@as(usize, 2), effect.inputs.len);
    try std.testing.expectEqual(@as(usize, 3), effect.outputs.len);

    try std.testing.expect(effect.inputs[0].is_row_variable);
    try std.testing.expectEqualStrings("..a", effect.inputs[0].name);
    try std.testing.expect(!effect.inputs[1].is_row_variable);
    try std.testing.expectEqualStrings("x", effect.inputs[1].name);

    try std.testing.expect(effect.outputs[0].is_row_variable);
    try std.testing.expectEqualStrings("..a", effect.outputs[0].name);
    try std.testing.expect(!effect.outputs[1].is_row_variable);
    try std.testing.expect(!effect.outputs[2].is_row_variable);
}

test "parse row-polymorphic effect with quotation annotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("..a x quot: ( ..a x -- ..b ) -- ..b x )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer, null, 0);

    try std.testing.expectEqual(@as(usize, 3), effect.inputs.len);
    try std.testing.expectEqual(@as(usize, 2), effect.outputs.len);

    // ..a is a row variable
    try std.testing.expect(effect.inputs[0].is_row_variable);
    try std.testing.expectEqualStrings("..a", effect.inputs[0].name);

    // x is concrete
    try std.testing.expect(!effect.inputs[1].is_row_variable);

    // quot has a quotation annotation with row variables
    try std.testing.expect(!effect.inputs[2].is_row_variable);
    try std.testing.expect(effect.inputs[2].quotation_effect != null);
    const nested = effect.inputs[2].quotation_effect.?;
    try std.testing.expect(nested.inputs[0].is_row_variable);
    try std.testing.expectEqualStrings("..a", nested.inputs[0].name);
    try std.testing.expect(nested.outputs[0].is_row_variable);
    try std.testing.expectEqualStrings("..b", nested.outputs[0].name);

    // ..b in outputs is a row variable
    try std.testing.expect(effect.outputs[0].is_row_variable);
    try std.testing.expectEqualStrings("..b", effect.outputs[0].name);
    try std.testing.expect(!effect.outputs[1].is_row_variable);
}

test "parse stack effect type union with context" {
    var ctx = Context.initWithPrelude(std.testing.allocator);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("n: fixnum | string -- out: string | fixnum )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer, &ctx, 0);

    try std.testing.expectEqual(@as(usize, 1), effect.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), effect.outputs.len);
    try std.testing.expect(effect.inputs[0].type_annotation != null);
    try std.testing.expect(effect.outputs[0].type_annotation != null);
    const in_tv = effect.inputs[0].type_annotation.?.type;
    const out_tv = effect.outputs[0].type_annotation.?.type;
    try std.testing.expect(in_tv == out_tv);
    try std.testing.expect(in_tv.member_types != null);
    try std.testing.expectEqual(@as(usize, 2), in_tv.member_types.?.len);
    try std.testing.expectEqualStrings("fixnum|string", in_tv.name);
}

test "named union definition parses anonymous union before semicolon" {
    var ctx = Context.initWithPrelude(std.testing.allocator);
    defer ctx.deinit();

    const alloc = ctx.quotationAllocator();
    var tokenizer = Tokenizer.init("number: fixnum | bignum | float ;");
    const instrs = try parseTopLevel(alloc, &tokenizer, &ctx);

    try std.testing.expectEqual(@as(usize, 2), instrs.len);
    try std.testing.expectEqualStrings("number", instrs[0].op.push_literal.symbol);
    try std.testing.expect(instrs[1].op.push_literal == .type_val);
    try std.testing.expect(instrs[1].op.push_literal.type_val.member_types != null);
    try std.testing.expectEqual(@as(usize, 3), instrs[1].op.push_literal.type_val.member_types.?.len);
    try std.testing.expectEqualStrings("bignum|fixnum|float", instrs[1].op.push_literal.type_val.name);
}

test "struct field annotations accept anonymous unions" {
    var ctx = Context.initWithPrelude(std.testing.allocator);
    defer ctx.deinit();

    const alloc = ctx.quotationAllocator();
    var tokenizer = Tokenizer.init("range-like: struct{ start: fixnum | bignum end: fixnum | bignum } ;");
    const instrs = try parseTopLevel(alloc, &tokenizer, &ctx);
    try ctx.executeQuotation(.{ .instructions = instrs });

    const word = ctx.lookupWord("range-like") orelse {
        try std.testing.expect(false);
        return;
    };
    switch (word.action) {
        .compound => |type_instrs| {
            const tv = type_instrs[0].op.push_literal.type_val;
            const desc = tv.descriptor orelse {
                try std.testing.expect(false);
                return;
            };
            const sd = switch (desc.kind) {
                .struct_ => |s| s,
                else => {
                    try std.testing.expect(false);
                    return;
                },
            };
            const field_types = sd.field_types;

            try std.testing.expectEqual(@as(usize, 2), field_types.len);
            try std.testing.expect(field_types[0].?.member_types != null);
            try std.testing.expect(field_types[0].? == field_types[1].?);
            try std.testing.expectEqualStrings("bignum|fixnum", field_types[0].?.name);
        },
        .native, .host_callback => try std.testing.expect(false),
    }
}

test "parse stack effect intersection constraint" {
    var ctx = Context.initWithPrelude(std.testing.allocator);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("x: comparable & stringable -- )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer, &ctx, 0);

    try std.testing.expectEqual(@as(usize, 1), effect.inputs.len);
    const ann = effect.inputs[0].type_annotation orelse return error.TestExpectedAnnotation;
    try std.testing.expect(ann == .combination);
    const cc = ann.combination;
    try std.testing.expectEqual(value_mod.ConstraintCombinator.Kind.intersection, cc.kind);
    try std.testing.expectEqual(@as(usize, 2), cc.elements.len);
    try std.testing.expect(cc.elements[0] == .protocol);
    try std.testing.expect(cc.elements[1] == .protocol);
    try std.testing.expectEqualStrings("comparable", cc.elements[0].protocol.name);
    try std.testing.expectEqualStrings("stringable", cc.elements[1].protocol.name);
}

test "parse stack effect mixed union constraint" {
    var ctx = Context.initWithPrelude(std.testing.allocator);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("x: fixnum | comparable -- )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer, &ctx, 0);

    const ann = effect.inputs[0].type_annotation orelse return error.TestExpectedAnnotation;
    try std.testing.expect(ann == .combination);
    const cc = ann.combination;
    try std.testing.expectEqual(value_mod.ConstraintCombinator.Kind.@"union", cc.kind);
    try std.testing.expectEqual(@as(usize, 2), cc.elements.len);
    try std.testing.expect(cc.elements[0] == .type);
    try std.testing.expectEqualStrings("fixnum", cc.elements[0].type.name);
    try std.testing.expect(cc.elements[1] == .protocol);
    try std.testing.expectEqualStrings("comparable", cc.elements[1].protocol.name);
}

test "parse stack effect constraint precedence: & binds tighter than |" {
    var ctx = Context.initWithPrelude(std.testing.allocator);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // comparable & stringable | inspectable  ==>  (comparable & stringable) | inspectable
    var tokenizer = Tokenizer.init("x: comparable & stringable | inspectable -- )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer, &ctx, 0);

    const ann = effect.inputs[0].type_annotation orelse return error.TestExpectedAnnotation;
    try std.testing.expect(ann == .combination);
    const cc = ann.combination;
    try std.testing.expectEqual(value_mod.ConstraintCombinator.Kind.@"union", cc.kind);
    try std.testing.expectEqual(@as(usize, 2), cc.elements.len);

    // First disjunct is the nested intersection (comparable & stringable).
    try std.testing.expect(cc.elements[0] == .combinator);
    const inner = cc.elements[0].combinator;
    try std.testing.expectEqual(value_mod.ConstraintCombinator.Kind.intersection, inner.kind);
    try std.testing.expectEqual(@as(usize, 2), inner.elements.len);
    try std.testing.expectEqualStrings("comparable", inner.elements[0].protocol.name);
    try std.testing.expectEqualStrings("stringable", inner.elements[1].protocol.name);

    // Second disjunct is the bare protocol.
    try std.testing.expect(cc.elements[1] == .protocol);
    try std.testing.expectEqualStrings("inspectable", cc.elements[1].protocol.name);
}

test "parse stack effect pure type union stays a TypeValue" {
    var ctx = Context.initWithPrelude(std.testing.allocator);
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init("x: fixnum | bignum -- )");
    const effect = try parseStackEffect(arena.allocator(), &tokenizer, &ctx, 0);

    const ann = effect.inputs[0].type_annotation orelse return error.TestExpectedAnnotation;
    try std.testing.expect(ann == .type);
    try std.testing.expect(ann.type.member_types != null);
    try std.testing.expectEqual(@as(usize, 2), ann.type.member_types.?.len);
    try std.testing.expectEqualStrings("bignum|fixnum", ann.type.name);
}

test "parse stack effect rejects leading constraint marker" {
    for ([_][]const u8{ "x: & comparable -- )", "x: | comparable -- )" }) |src| {
        var ctx = Context.initWithPrelude(std.testing.allocator);
        defer ctx.deinit();

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        var tokenizer = Tokenizer.init(src);
        try std.testing.expectError(ParseError.ParseTimeExecutionError, parseStackEffect(arena.allocator(), &tokenizer, &ctx, 0));
        try std.testing.expectEqualStrings("InvalidConstraint", ctx.parse_diagnostics.?.error_type.?);
    }
}

test "parse stack effect rejects adjacent constraint markers" {
    for ([_][]const u8{ "x: comparable & & stringable -- )", "x: fixnum | | comparable -- )" }) |src| {
        var ctx = Context.initWithPrelude(std.testing.allocator);
        defer ctx.deinit();

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        var tokenizer = Tokenizer.init(src);
        try std.testing.expectError(ParseError.ParseTimeExecutionError, parseStackEffect(arena.allocator(), &tokenizer, &ctx, 0));
        try std.testing.expectEqualStrings("InvalidConstraint", ctx.parse_diagnostics.?.error_type.?);
    }
}
