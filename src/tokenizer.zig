const std = @import("std");
const ParserCoroutine = @import("parser_coroutine.zig").ParserCoroutine;

/// Token represents a lexical token with its kind, text, and source location.
pub const Token = struct {
    kind: Kind,
    text: []const u8,
    line: usize, // 1-based line number
    column: usize = 0, // 1-based column number

    pub const Kind = enum {
        word, // Regular token (word, number, symbol, bracket, etc.)
        comment, // Line comment starting with `\ `
        doc_comment, // Doc-comment starting with `\\ `
        newline, // Newline character (only emitted when preserve_newlines is true)
    };

    /// Returns true if this token is a comment.
    pub fn isComment(self: Token) bool {
        return self.kind == .comment;
    }

    /// Returns true if this token is a doc-comment.
    pub fn isDocComment(self: Token) bool {
        return self.kind == .doc_comment;
    }

    /// Returns true if this token is a newline.
    pub fn isNewline(self: Token) bool {
        return self.kind == .newline;
    }
};

/// Tokenizer splits input into whitespace-separated tokens.
/// Supports line comments (starting with `\ `) and optional newline preservation.
pub const Tokenizer = struct {
    input: []const u8,
    pos: usize,
    line: usize, // 1-based line number
    line_start: usize = 0, // byte offset of the current line's start
    preserve_newlines: bool,
    parser_coroutine: ?*ParserCoroutine = null,
    peeked: ?Token = null,
    /// Whether byte 0 of `input` is byte 0 of the source, which is what makes an interpreter line
    /// an interpreter line.
    ///
    /// It defaults to true, since a caller handing over a whole source is the common case. The
    /// interpreter is the exception: it tokenizes a file one top-level statement at a time, so
    /// every statement after the first begins at its own byte 0 and must say so.
    at_source_start: bool = true,

    pub fn init(input: []const u8) Tokenizer {
        return .{
            .input = input,
            .pos = 0,
            .line = 1,
            .preserve_newlines = false,
        };
    }

    /// Initialize tokenizer with newline preservation for formatting.
    pub fn initForFormatting(input: []const u8) Tokenizer {
        return .{
            .input = input,
            .pos = 0,
            .line = 1,
            .preserve_newlines = true,
        };
    }

    /// Returns the next token, or null if no more tokens.
    pub fn next(self: *Tokenizer) ?Token {
        // Skip whitespace, but handle newlines specially if preserving them
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '\n') {
                const current_line = self.line;
                self.line += 1;
                self.pos += 1;
                self.line_start = self.pos;
                if (self.preserve_newlines) {
                    return .{ .kind = .newline, .text = "\n", .line = current_line };
                }
            } else if (c == ' ' or c == '\t' or c == '\r') {
                self.pos += 1;
            } else {
                break;
            }
        }

        if (self.pos >= self.input.len) {
            return null;
        }

        const start = self.pos;
        const token_line = self.line;
        const token_column = start - self.line_start + 1;

        // Interpreter line: `#!` at the very first byte of the source runs to end of line.
        //
        // It is a comment token rather than a skip, so the formatter round-trips it. It lives in
        // the tokenizer rather than in a file reader, so every consumer accepts an executable
        // script.
        if (self.at_source_start and start == 0 and std.mem.startsWith(u8, self.input, "#!")) {
            while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                self.pos += 1;
            }
            return .{ .kind = .comment, .text = self.input[start..self.pos], .line = token_line, .column = token_column };
        }

        // Doc-comment: `\\` followed by space/tab/newline/CR or end-of-input
        if (self.input[self.pos] == '\\' and
            self.pos + 1 < self.input.len and
            self.input[self.pos + 1] == '\\' and
            (self.pos + 2 >= self.input.len or
                self.input[self.pos + 2] == ' ' or
                self.input[self.pos + 2] == '\t' or
                self.input[self.pos + 2] == '\n' or
                self.input[self.pos + 2] == '\r'))
        {
            while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                self.pos += 1;
            }
            return .{ .kind = .doc_comment, .text = self.input[start..self.pos], .line = token_line, .column = token_column };
        }

        // Line comment: `\ ` followed by space/tab, or `\` at end-of-line/input
        if (self.input[self.pos] == '\\' and
            (self.pos + 1 >= self.input.len or
                self.input[self.pos + 1] == ' ' or
                self.input[self.pos + 1] == '\t' or
                self.input[self.pos + 1] == '\n' or
                self.input[self.pos + 1] == '\r'))
        {
            // Consume until end of line or end of input
            while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                self.pos += 1;
            }
            return .{ .kind = .comment, .text = self.input[start..self.pos], .line = token_line, .column = token_column };
        }

        // String literal: collect until closing quote
        if (self.input[self.pos] == '"') {
            self.pos += 1; // skip opening quote
            while (self.pos < self.input.len and self.input[self.pos] != '"') {
                if (self.input[self.pos] == '\\' and self.pos + 1 < self.input.len) {
                    self.pos += 2;
                } else {
                    self.pos += 1;
                }
            }
            if (self.pos < self.input.len) {
                self.pos += 1; // skip closing quote
            }
            return .{ .kind = .word, .text = self.input[start..self.pos], .line = token_line, .column = token_column };
        }

        // Collect non-whitespace characters
        while (self.pos < self.input.len and !isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }

        return .{ .kind = .word, .text = self.input[start..self.pos], .line = token_line, .column = token_column };
    }

    /// Reset the tokenizer to the beginning.
    pub fn reset(self: *Tokenizer) void {
        self.pos = 0;
        self.line = 1;
        self.line_start = 0;
    }

    /// Rewind the scan position to the start of `tok` and clear any peeked
    /// token, so the next `next()` (or `nextOrYield()`) re-reads `tok`. Used
    /// when a delimited parse helper over-read one token and must hand it back
    /// to a `next()`-based caller that does not consult `peeked`. `tok.text`
    /// must be a slice into this tokenizer's current `input`.
    pub fn rewindTo(self: *Tokenizer, tok: Token) void {
        const offset = @intFromPtr(tok.text.ptr) - @intFromPtr(self.input.ptr);
        self.pos = offset;
        self.line = tok.line;
        self.line_start = offset + 1 - tok.column;
        self.peeked = null;
    }

    /// Like `next`, but yields to the parser coroutine when input is
    /// exhausted instead of returning null. Returns null only on true
    /// EOF (no coroutine, or coroutine flush with no new input).
    pub fn nextOrYield(self: *Tokenizer) ?Token {
        if (self.peeked) |tok| {
            self.peeked = null;
            return tok;
        }
        while (true) {
            if (self.next()) |tok| return tok;
            const co = self.parser_coroutine orelse return null;
            const prev_len = self.input.len;
            co.yield();
            if (self.input.len > prev_len) continue;
            return null;
        }
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }
};

/// Validate underscore placement in a numeric token body (after optional sign).
/// Rejects leading underscore, trailing underscore, and consecutive underscores.
fn validateUnderscores(body: []const u8) bool {
    if (body.len == 0) return true;
    if (body[0] == '_') return false;
    if (body[body.len - 1] == '_') return false;
    var prev_underscore = false;
    for (body) |ch| {
        if (ch == '_') {
            if (prev_underscore) return false;
            prev_underscore = true;
        } else {
            prev_underscore = false;
        }
    }
    return true;
}

/// Strip underscores from input into a fixed buffer.
/// Returns the original slice if no underscores are present (zero-cost common path).
/// Returns null if the input exceeds the buffer or the result would be empty.
fn stripUnderscores(input: []const u8, buf: *[256]u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, input, '_') == null) return input;
    var i: usize = 0;
    for (input) |ch| {
        if (ch != '_') {
            if (i >= buf.len) return null;
            buf[i] = ch;
            i += 1;
        }
    }
    if (i == 0) return null;
    return buf[0..i];
}

/// Parse an integer from a token. Returns null if not a valid integer.
/// Supports hex (0x/0X), octal (0o/0O), and binary (0b/0B) prefixes,
/// including negatives and underscore digit separators.
pub fn parseInteger(token: []const u8) ?i64 {
    if (token.len == 0) return null;
    const is_negative = token[0] == '-';
    const after_sign = if (is_negative) token[1..] else token;
    if (after_sign.len == 0) return null;
    if (!validateUnderscores(after_sign)) return null;

    var buf: [256]u8 = undefined;

    if (after_sign.len > 2 and after_sign[0] == '0') {
        const prefix_char = after_sign[1];
        const base: u8 = if (prefix_char == 'x' or prefix_char == 'X')
            16
        else if (prefix_char == 'o' or prefix_char == 'O')
            8
        else if (prefix_char == 'b' or prefix_char == 'B')
            2
        else
            0;

        if (base != 0) {
            const digits = after_sign[2..];
            if (digits.len == 0) return null;
            const stripped = stripUnderscores(digits, &buf) orelse return null;
            const magnitude = std.fmt.parseInt(i64, stripped, base) catch return null;
            if (is_negative) {
                if (magnitude == 0) return 0;
                return std.math.negate(magnitude) catch null;
            }
            return magnitude;
        }
    }

    const stripped = stripUnderscores(token, &buf) orelse return null;
    return std.fmt.parseInt(i64, stripped, 10) catch null;
}

/// Parse a bignum from a token when parseInteger fails (overflow).
/// Supports decimal, hex (0x/0X), octal (0o/0O), and binary (0b/0B) prefixes,
/// including negatives and underscore digit separators.
pub fn parseBigNum(allocator: std.mem.Allocator, token: []const u8) ?std.math.big.int.Managed {
    if (token.len == 0) return null;
    const is_negative = token[0] == '-';
    const after_sign = if (is_negative) token[1..] else token;
    if (after_sign.len == 0) return null;
    if (!validateUnderscores(after_sign)) return null;

    var buf: [256]u8 = undefined;

    if (after_sign.len > 2 and after_sign[0] == '0') {
        const prefix_char = after_sign[1];
        const base: u8 = if (prefix_char == 'x' or prefix_char == 'X')
            16
        else if (prefix_char == 'o' or prefix_char == 'O')
            8
        else if (prefix_char == 'b' or prefix_char == 'B')
            2
        else
            0;

        if (base != 0) {
            const digits = after_sign[2..];
            if (digits.len == 0) return null;
            for (digits) |ch| {
                if (ch == '_') continue;
                const valid = switch (base) {
                    16 => std.ascii.isHex(ch),
                    8 => ch >= '0' and ch <= '7',
                    2 => ch == '0' or ch == '1',
                    else => false,
                };
                if (!valid) return null;
            }
            const stripped = stripUnderscores(digits, &buf) orelse return null;
            var big = std.math.big.int.Managed.init(allocator) catch return null;
            big.setString(base, stripped) catch {
                big.deinit();
                return null;
            };
            if (is_negative) big.negate();
            return big;
        }
    }

    if (after_sign.len == 0) return null;
    for (after_sign) |ch| {
        if (ch == '_') continue;
        if (ch < '0' or ch > '9') return null;
    }
    const stripped_token = stripUnderscores(token, &buf) orelse return null;
    var big = std.math.big.int.Managed.init(allocator) catch return null;
    big.setString(10, stripped_token) catch {
        big.deinit();
        return null;
    };
    return big;
}

/// Parse a float from a token. Returns null if not a valid float literal.
/// Accepts decimal (3.14), scientific (1.5e10), and negative (-3.14) forms.
/// Supports underscore digit separators (1_000.000_5).
/// Rejects hex prefixes, nan/inf literals, and tokens missing digits on either
/// side of the decimal point.
pub fn parseFloat(token: []const u8) ?f64 {
    if (token.len == 0) return null;

    const body = if (token[0] == '-') token[1..] else token;
    if (!validateUnderscores(body)) return null;

    var buf: [256]u8 = undefined;
    const stripped = stripUnderscores(token, &buf) orelse return null;

    const has_dot = std.mem.indexOfScalar(u8, stripped, '.') != null;
    const has_exp = std.mem.indexOfScalar(u8, stripped, 'e') != null or std.mem.indexOfScalar(u8, stripped, 'E') != null;
    if (!has_dot and !has_exp) return null;

    const stripped_body = if (stripped[0] == '-') stripped[1..] else stripped;
    if (stripped_body.len > 2 and stripped_body[0] == '0' and (stripped_body[1] == 'x' or stripped_body[1] == 'X')) return null;

    if (has_dot) {
        if (std.mem.indexOfScalar(u8, stripped, '.')) |dot_idx| {
            const before_dot = if (stripped[0] == '-') stripped[1..dot_idx] else stripped[0..dot_idx];
            const after_dot = stripped[dot_idx + 1 ..];
            if (before_dot.len == 0) return null;

            const after_digits = if (std.mem.indexOfAny(u8, after_dot, "eE")) |ei| after_dot[0..ei] else after_dot;
            if (after_digits.len == 0) return null;
        }
    }

    // NOTE(ripta): nan / inf will be preludes instead of  literals
    if (std.mem.eql(u8, stripped_body, "nan")) return null;
    if (std.mem.eql(u8, stripped_body, "inf")) return null;
    if (std.mem.eql(u8, stripped_body, "infinity")) return null;

    return std.fmt.parseFloat(f64, stripped) catch null;
}

/// Parse a string literal from a token. Returns the content without quotes,
/// or null if not a valid string literal.
pub fn parseString(token: []const u8) ?[]const u8 {
    if (token.len < 2) return null;
    if (token[0] != '"') return null;
    if (token[token.len - 1] != '"') return null;
    return token[1 .. token.len - 1];
}

// =============================================================================
// Tests
// =============================================================================

test "empty input" {
    var t = Tokenizer.init("");
    try std.testing.expectEqual(null, t.next());
}

test "whitespace only" {
    var t = Tokenizer.init("   \t\n  ");
    try std.testing.expectEqual(null, t.next());
}

test "single token" {
    var t = Tokenizer.init("hello");
    const tok = t.next().?;
    try std.testing.expectEqualStrings("hello", tok.text);
    try std.testing.expectEqual(Token.Kind.word, tok.kind);
    try std.testing.expectEqual(null, t.next());
}

test "multiple tokens" {
    var t = Tokenizer.init("one two three");
    try std.testing.expectEqualStrings("one", t.next().?.text);
    try std.testing.expectEqualStrings("two", t.next().?.text);
    try std.testing.expectEqualStrings("three", t.next().?.text);
    try std.testing.expectEqual(null, t.next());
}

test "tokens with various whitespace" {
    var t = Tokenizer.init("  a\tb\nc  ");
    try std.testing.expectEqualStrings("a", t.next().?.text);
    try std.testing.expectEqualStrings("b", t.next().?.text);
    try std.testing.expectEqualStrings("c", t.next().?.text);
    try std.testing.expectEqual(null, t.next());
}

test "number tokens" {
    var t = Tokenizer.init("123 456 -789");
    try std.testing.expectEqualStrings("123", t.next().?.text);
    try std.testing.expectEqualStrings("456", t.next().?.text);
    try std.testing.expectEqualStrings("-789", t.next().?.text);
    try std.testing.expectEqual(null, t.next());
}

test "parseInteger valid" {
    try std.testing.expectEqual(@as(i64, 123), parseInteger("123").?);
    try std.testing.expectEqual(@as(i64, -456), parseInteger("-456").?);
    try std.testing.expectEqual(@as(i64, 0), parseInteger("0").?);
}

test "parseInteger invalid" {
    try std.testing.expectEqual(null, parseInteger("abc"));
    try std.testing.expectEqual(null, parseInteger("12.34"));
    try std.testing.expectEqual(null, parseInteger(""));
}

test "reset" {
    var t = Tokenizer.init("a b");
    _ = t.next();
    _ = t.next();
    try std.testing.expectEqual(null, t.next());

    t.reset();
    try std.testing.expectEqualStrings("a", t.next().?.text);
}

test "string literal" {
    var t = Tokenizer.init("\"hello world\"");
    try std.testing.expectEqualStrings("\"hello world\"", t.next().?.text);
    try std.testing.expectEqual(null, t.next());
}

test "string literal with surrounding tokens" {
    var t = Tokenizer.init("1 \"hello\" 2");
    try std.testing.expectEqualStrings("1", t.next().?.text);
    try std.testing.expectEqualStrings("\"hello\"", t.next().?.text);
    try std.testing.expectEqualStrings("2", t.next().?.text);
    try std.testing.expectEqual(null, t.next());
}

test "empty string literal" {
    var t = Tokenizer.init("\"\"");
    try std.testing.expectEqualStrings("\"\"", t.next().?.text);
}

test "parseString valid" {
    try std.testing.expectEqualStrings("hello", parseString("\"hello\"").?);
    try std.testing.expectEqualStrings("hello world", parseString("\"hello world\"").?);
    try std.testing.expectEqualStrings("", parseString("\"\"").?);
}

test "parseString invalid" {
    try std.testing.expectEqual(null, parseString("hello"));
    try std.testing.expectEqual(null, parseString("\""));
    try std.testing.expectEqual(null, parseString(""));
}

test "line comment" {
    var t = Tokenizer.init("\\ this is a comment");
    const tok = t.next().?;
    try std.testing.expectEqual(Token.Kind.comment, tok.kind);
    try std.testing.expectEqualStrings("\\ this is a comment", tok.text);
    try std.testing.expectEqual(null, t.next());
}

test "comment with code before" {
    var t = Tokenizer.init("1 2 + \\ add two numbers");
    try std.testing.expectEqualStrings("1", t.next().?.text);
    try std.testing.expectEqualStrings("2", t.next().?.text);
    try std.testing.expectEqualStrings("+", t.next().?.text);
    const comment = t.next().?;
    try std.testing.expectEqual(Token.Kind.comment, comment.kind);
    try std.testing.expectEqualStrings("\\ add two numbers", comment.text);
    try std.testing.expectEqual(null, t.next());
}

test "comment with code after on new line" {
    var t = Tokenizer.init("\\ comment\n42");
    const comment = t.next().?;
    try std.testing.expectEqual(Token.Kind.comment, comment.kind);
    try std.testing.expectEqualStrings("\\ comment", comment.text);
    try std.testing.expectEqualStrings("42", t.next().?.text);
    try std.testing.expectEqual(null, t.next());
}

test "backslash not followed by space is not a comment" {
    var t = Tokenizer.init("\\n foo");
    try std.testing.expectEqualStrings("\\n", t.next().?.text);
    try std.testing.expectEqualStrings("foo", t.next().?.text);
    try std.testing.expectEqual(null, t.next());
}

test "shebang line is a comment" {
    var t = Tokenizer.init("#!/usr/bin/env -S 1z\n42");
    const shebang = t.next().?;
    try std.testing.expectEqual(Token.Kind.comment, shebang.kind);
    try std.testing.expectEqualStrings("#!/usr/bin/env -S 1z", shebang.text);
    try std.testing.expectEqualStrings("42", t.next().?.text);
    try std.testing.expectEqual(null, t.next());
}

test "shebang at end of input" {
    var t = Tokenizer.init("#!/usr/bin/env 1z");
    const shebang = t.next().?;
    try std.testing.expectEqual(Token.Kind.comment, shebang.kind);
    try std.testing.expectEqualStrings("#!/usr/bin/env 1z", shebang.text);
    try std.testing.expectEqual(null, t.next());
}

test "shebang off the first byte is an ordinary word" {
    var t = Tokenizer.init(" #!/usr/bin/env");
    try std.testing.expectEqualStrings("#!/usr/bin/env", t.next().?.text);
    try std.testing.expectEqual(null, t.next());

    var second_line = Tokenizer.init("42\n#!/usr/bin/env");
    try std.testing.expectEqualStrings("42", second_line.next().?.text);
    try std.testing.expectEqualStrings("#!/usr/bin/env", second_line.next().?.text);
    try std.testing.expectEqual(null, second_line.next());
}

test "sequence words keep their leading hash" {
    var t = Tokenizer.init("#len #map");
    try std.testing.expectEqualStrings("#len", t.next().?.text);
    try std.testing.expectEqualStrings("#map", t.next().?.text);
    try std.testing.expectEqual(null, t.next());
}

test "a shebang away from the source start is an ordinary word" {
    var t = Tokenizer.init("#!/usr/bin/env 1z");
    t.at_source_start = false;
    const tok = t.next().?;
    try std.testing.expectEqual(Token.Kind.word, tok.kind);
    try std.testing.expectEqualStrings("#!/usr/bin/env", tok.text);
    try std.testing.expectEqualStrings("1z", t.next().?.text);
    try std.testing.expectEqual(null, t.next());
}

test "preserve newlines mode" {
    var t = Tokenizer.initForFormatting("a\nb");
    try std.testing.expectEqualStrings("a", t.next().?.text);
    const newline = t.next().?;
    try std.testing.expectEqual(Token.Kind.newline, newline.kind);
    try std.testing.expectEqualStrings("b", t.next().?.text);
    try std.testing.expectEqual(null, t.next());
}

test "preserve newlines with multiple newlines" {
    var t = Tokenizer.initForFormatting("a\n\nb");
    try std.testing.expectEqualStrings("a", t.next().?.text);
    try std.testing.expectEqual(Token.Kind.newline, t.next().?.kind);
    try std.testing.expectEqual(Token.Kind.newline, t.next().?.kind);
    try std.testing.expectEqualStrings("b", t.next().?.text);
    try std.testing.expectEqual(null, t.next());
}

test "default mode skips newlines" {
    var t = Tokenizer.init("a\n\nb");
    try std.testing.expectEqualStrings("a", t.next().?.text);
    try std.testing.expectEqualStrings("b", t.next().?.text);
    try std.testing.expectEqual(null, t.next());
}

test "line tracking" {
    var t = Tokenizer.init("a\nb\n\nc");
    const tok1 = t.next().?;
    try std.testing.expectEqualStrings("a", tok1.text);
    try std.testing.expectEqual(@as(usize, 1), tok1.line);

    const tok2 = t.next().?;
    try std.testing.expectEqualStrings("b", tok2.text);
    try std.testing.expectEqual(@as(usize, 2), tok2.line);

    const tok3 = t.next().?;
    try std.testing.expectEqualStrings("c", tok3.text);
    try std.testing.expectEqual(@as(usize, 4), tok3.line);
}

test "line tracking with comments" {
    var t = Tokenizer.init("a\n\\ comment\nb");
    const tok1 = t.next().?;
    try std.testing.expectEqual(@as(usize, 1), tok1.line);

    const comment = t.next().?;
    try std.testing.expectEqual(Token.Kind.comment, comment.kind);
    try std.testing.expectEqual(@as(usize, 2), comment.line);

    const tok2 = t.next().?;
    try std.testing.expectEqual(@as(usize, 3), tok2.line);
}

test "empty comment at end of input" {
    var t = Tokenizer.init("\\");
    const tok = t.next().?;
    try std.testing.expectEqual(Token.Kind.comment, tok.kind);
    try std.testing.expectEqualStrings("\\", tok.text);
    try std.testing.expectEqual(null, t.next());
}

test "empty comment followed by newline" {
    var t = Tokenizer.init("\\\n42");
    const comment = t.next().?;
    try std.testing.expectEqual(Token.Kind.comment, comment.kind);
    try std.testing.expectEqualStrings("\\", comment.text);
    try std.testing.expectEqualStrings("42", t.next().?.text);
    try std.testing.expectEqual(null, t.next());
}

test "empty comment with carriage return" {
    var t = Tokenizer.init("\\\r\n42");
    const comment = t.next().?;
    try std.testing.expectEqual(Token.Kind.comment, comment.kind);
    // The \r is included in the comment text (before the \n)
    try std.testing.expectEqualStrings("\\\r", comment.text);
    try std.testing.expectEqualStrings("42", t.next().?.text);
    try std.testing.expectEqual(null, t.next());
}

test "empty comment with code before" {
    var t = Tokenizer.init("1 2 + \\\n3");
    try std.testing.expectEqualStrings("1", t.next().?.text);
    try std.testing.expectEqualStrings("2", t.next().?.text);
    try std.testing.expectEqualStrings("+", t.next().?.text);
    const comment = t.next().?;
    try std.testing.expectEqual(Token.Kind.comment, comment.kind);
    try std.testing.expectEqualStrings("\\", comment.text);
    try std.testing.expectEqualStrings("3", t.next().?.text);
    try std.testing.expectEqual(null, t.next());
}

test "doc-comment" {
    var t = Tokenizer.init("\\\\ this is a doc comment");
    const tok = t.next().?;
    try std.testing.expectEqual(Token.Kind.doc_comment, tok.kind);
    try std.testing.expectEqualStrings("\\\\ this is a doc comment", tok.text);
    try std.testing.expectEqual(null, t.next());
}

test "doc-comment with code before" {
    var t = Tokenizer.init("1 2 + \\\\ doc");
    try std.testing.expectEqualStrings("1", t.next().?.text);
    try std.testing.expectEqualStrings("2", t.next().?.text);
    try std.testing.expectEqualStrings("+", t.next().?.text);
    const doc = t.next().?;
    try std.testing.expectEqual(Token.Kind.doc_comment, doc.kind);
    try std.testing.expectEqualStrings("\\\\ doc", doc.text);
    try std.testing.expectEqual(null, t.next());
}

test "empty doc-comment at end of input" {
    var t = Tokenizer.init("\\\\");
    const tok = t.next().?;
    try std.testing.expectEqual(Token.Kind.doc_comment, tok.kind);
    try std.testing.expectEqualStrings("\\\\", tok.text);
    try std.testing.expectEqual(null, t.next());
}

test "doc-comment followed by newline and code" {
    var t = Tokenizer.init("\\\\\n42");
    const doc = t.next().?;
    try std.testing.expectEqual(Token.Kind.doc_comment, doc.kind);
    try std.testing.expectEqualStrings("\\\\", doc.text);
    try std.testing.expectEqualStrings("42", t.next().?.text);
    try std.testing.expectEqual(null, t.next());
}

test "double backslash without space is not a doc-comment" {
    var t = Tokenizer.init("\\\\word");
    const tok = t.next().?;
    try std.testing.expectEqual(Token.Kind.word, tok.kind);
    try std.testing.expectEqualStrings("\\\\word", tok.text);
    try std.testing.expectEqual(null, t.next());
}

test "consecutive doc-comments" {
    var t = Tokenizer.init("\\\\ line one\n\\\\ line two");
    const doc1 = t.next().?;
    try std.testing.expectEqual(Token.Kind.doc_comment, doc1.kind);
    try std.testing.expectEqualStrings("\\\\ line one", doc1.text);
    const doc2 = t.next().?;
    try std.testing.expectEqual(Token.Kind.doc_comment, doc2.kind);
    try std.testing.expectEqualStrings("\\\\ line two", doc2.text);
    try std.testing.expectEqual(null, t.next());
}

test "doc-comment line tracking" {
    var t = Tokenizer.init("a\n\\\\ doc\nb");
    const tok1 = t.next().?;
    try std.testing.expectEqual(@as(usize, 1), tok1.line);

    const doc = t.next().?;
    try std.testing.expectEqual(Token.Kind.doc_comment, doc.kind);
    try std.testing.expectEqual(@as(usize, 2), doc.line);

    const tok2 = t.next().?;
    try std.testing.expectEqual(@as(usize, 3), tok2.line);
}

test "column tracking" {
    var t = Tokenizer.init("abc def");
    const tok1 = t.next().?;
    try std.testing.expectEqualStrings("abc", tok1.text);
    try std.testing.expectEqual(@as(usize, 1), tok1.column);

    const tok2 = t.next().?;
    try std.testing.expectEqualStrings("def", tok2.text);
    try std.testing.expectEqual(@as(usize, 5), tok2.column);
}

test "column tracking across lines" {
    var t = Tokenizer.init("ab\n  cd\nef");
    const tok1 = t.next().?;
    try std.testing.expectEqual(@as(usize, 1), tok1.line);
    try std.testing.expectEqual(@as(usize, 1), tok1.column);

    const tok2 = t.next().?;
    try std.testing.expectEqual(@as(usize, 2), tok2.line);
    try std.testing.expectEqual(@as(usize, 3), tok2.column);

    const tok3 = t.next().?;
    try std.testing.expectEqual(@as(usize, 3), tok3.line);
    try std.testing.expectEqual(@as(usize, 1), tok3.column);
}

test "column tracking with string literal" {
    var t = Tokenizer.init("a \"hello world\" b");
    const tok1 = t.next().?;
    try std.testing.expectEqual(@as(usize, 1), tok1.column);

    const tok2 = t.next().?;
    try std.testing.expectEqualStrings("\"hello world\"", tok2.text);
    try std.testing.expectEqual(@as(usize, 3), tok2.column);

    const tok3 = t.next().?;
    try std.testing.expectEqual(@as(usize, 17), tok3.column);
}

test "column resets after reset" {
    var t = Tokenizer.init("abc def");
    _ = t.next();
    _ = t.next();
    t.reset();
    const tok1 = t.next().?;
    try std.testing.expectEqual(@as(usize, 1), tok1.column);
}

test "parseFloat valid decimals" {
    try std.testing.expectEqual(@as(f64, 3.14), parseFloat("3.14").?);
    try std.testing.expectEqual(@as(f64, 0.5), parseFloat("0.5").?);
    try std.testing.expectEqual(@as(f64, 5.0), parseFloat("5.0").?);
    try std.testing.expectEqual(@as(f64, 100.001), parseFloat("100.001").?);
}

test "parseFloat valid negatives" {
    try std.testing.expectEqual(@as(f64, -3.14), parseFloat("-3.14").?);
    const neg_zero = parseFloat("-0.0").?;
    try std.testing.expect(neg_zero == 0.0 and std.math.isNegativeZero(neg_zero));
}

test "parseFloat valid scientific" {
    try std.testing.expectEqual(@as(f64, 1.5e10), parseFloat("1.5e10").?);
    try std.testing.expectEqual(@as(f64, 1.5e10), parseFloat("1.5E10").?);
    try std.testing.expectEqual(@as(f64, 2.5e-3), parseFloat("2.5e-3").?);
    try std.testing.expectEqual(@as(f64, -1.5e10), parseFloat("-1.5e10").?);
    try std.testing.expectEqual(@as(f64, 1e10), parseFloat("1e10").?);
}

test "parseFloat rejects missing digits around dot" {
    try std.testing.expectEqual(null, parseFloat(".5"));
    try std.testing.expectEqual(null, parseFloat("5."));
    try std.testing.expectEqual(null, parseFloat("-.5"));
    try std.testing.expectEqual(null, parseFloat("-5."));
    try std.testing.expectEqual(null, parseFloat("."));
}

test "parseFloat rejects special values" {
    try std.testing.expectEqual(null, parseFloat("nan"));
    try std.testing.expectEqual(null, parseFloat("inf"));
    try std.testing.expectEqual(null, parseFloat("-inf"));
    try std.testing.expectEqual(null, parseFloat("infinity"));
    try std.testing.expectEqual(null, parseFloat("-infinity"));
}

test "parseFloat rejects non-float tokens" {
    try std.testing.expectEqual(null, parseFloat("42"));
    try std.testing.expectEqual(null, parseFloat("-42"));
    try std.testing.expectEqual(null, parseFloat("abc"));
    try std.testing.expectEqual(null, parseFloat("\"\""));
}

test "parseFloat rejects hex" {
    try std.testing.expectEqual(null, parseFloat("0xDEAD"));
    try std.testing.expectEqual(null, parseFloat("0xFF"));
}

test "peeked token is returned by nextOrYield" {
    var t = Tokenizer.init("a b c");
    const tok_a = t.next().?;
    try std.testing.expectEqualStrings("a", tok_a.text);

    // Manually set peeked; nextOrYield should return it instead of scanning
    t.peeked = tok_a;
    const peeked = t.nextOrYield().?;
    try std.testing.expectEqualStrings("a", peeked.text);

    // After consuming peeked, nextOrYield resumes normal scanning
    try std.testing.expectEqual(@as(?Token, null), t.peeked);
    const tok_b = t.nextOrYield().?;
    try std.testing.expectEqualStrings("b", tok_b.text);
}

test "peeked token cleared after nextOrYield consumes it" {
    var t = Tokenizer.init("x y");
    const tok_x = t.nextOrYield().?;
    t.peeked = tok_x;

    // First nextOrYield returns peeked and clears it
    _ = t.nextOrYield();
    try std.testing.expectEqual(@as(?Token, null), t.peeked);

    // Second nextOrYield scans normally
    const tok_y = t.nextOrYield().?;
    try std.testing.expectEqualStrings("y", tok_y.text);
}

test "parseInteger octal" {
    try std.testing.expectEqual(@as(i64, 511), parseInteger("0o777").?);
    try std.testing.expectEqual(@as(i64, 420), parseInteger("0o644").?);
    try std.testing.expectEqual(@as(i64, 8), parseInteger("0o10").?);
    try std.testing.expectEqual(@as(i64, 511), parseInteger("0O777").?);
    try std.testing.expectEqual(@as(i64, -8), parseInteger("-0o10").?);
}

test "parseInteger binary" {
    try std.testing.expectEqual(@as(i64, 255), parseInteger("0b11111111").?);
    try std.testing.expectEqual(@as(i64, 5), parseInteger("0b101").?);
    try std.testing.expectEqual(@as(i64, 5), parseInteger("0B101").?);
    try std.testing.expectEqual(@as(i64, -10), parseInteger("-0b1010").?);
}

test "parseInteger with underscores" {
    try std.testing.expectEqual(@as(i64, 1000000), parseInteger("1_000_000").?);
    try std.testing.expectEqual(@as(i64, -1000000), parseInteger("-1_000_000").?);
    try std.testing.expectEqual(@as(i64, 65535), parseInteger("0xFF_FF").?);
    try std.testing.expectEqual(@as(i64, 255), parseInteger("0x_FF").?);
    try std.testing.expectEqual(@as(i64, 81), parseInteger("0b0101_0001").?);
    try std.testing.expectEqual(@as(i64, 5), parseInteger("0b_0101").?);
    try std.testing.expectEqual(@as(i64, 4095), parseInteger("0o7_777").?);
    try std.testing.expectEqual(@as(i64, 511), parseInteger("0o_777").?);
}

test "parseInteger rejects invalid underscores" {
    try std.testing.expectEqual(null, parseInteger("_100"));
    try std.testing.expectEqual(null, parseInteger("100_"));
    try std.testing.expectEqual(null, parseInteger("1__000"));
    try std.testing.expectEqual(null, parseInteger("0x_"));
    try std.testing.expectEqual(null, parseInteger("-_100"));
}

test "parseInteger rejects invalid prefixed literals" {
    try std.testing.expectEqual(null, parseInteger("0o"));
    try std.testing.expectEqual(null, parseInteger("0b"));
    try std.testing.expectEqual(null, parseInteger("0o89"));
    try std.testing.expectEqual(null, parseInteger("0b23"));
}

test "parseFloat with underscores" {
    try std.testing.expectEqual(@as(f64, 1000.0005), parseFloat("1_000.000_5").?);
    try std.testing.expectEqual(@as(f64, 1000000.0), parseFloat("1_000_000.0").?);
    try std.testing.expectEqual(@as(f64, -1000.5), parseFloat("-1_000.5").?);
    try std.testing.expectEqual(@as(f64, 1.5e10), parseFloat("1.5e1_0").?);
}

test "parseFloat rejects invalid underscores" {
    try std.testing.expectEqual(null, parseFloat("_100.0"));
    try std.testing.expectEqual(null, parseFloat("100.0_"));
    try std.testing.expectEqual(null, parseFloat("1__000.0"));
}

test "validateUnderscores" {
    try std.testing.expect(validateUnderscores("123"));
    try std.testing.expect(validateUnderscores("1_000"));
    try std.testing.expect(validateUnderscores("0x_FF"));
    try std.testing.expect(!validateUnderscores("_100"));
    try std.testing.expect(!validateUnderscores("100_"));
    try std.testing.expect(!validateUnderscores("1__0"));
}

test "stripUnderscores" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("123", stripUnderscores("123", &buf).?);
    try std.testing.expectEqualStrings("1000", stripUnderscores("1_000", &buf).?);
    try std.testing.expectEqualStrings("FF", stripUnderscores("F_F", &buf).?);
    try std.testing.expectEqual(null, stripUnderscores("_", &buf));
}
