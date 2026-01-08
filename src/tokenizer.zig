const std = @import("std");

/// Token represents a lexical token with its kind, text, and source location.
pub const Token = struct {
    kind: Kind,
    text: []const u8,
    line: usize, // 1-based line number

    pub const Kind = enum {
        word, // Regular token (word, number, symbol, bracket, etc.)
        comment, // Line comment starting with `\ `
        newline, // Newline character (only emitted when preserve_newlines is true)
    };

    /// Returns true if this token is a comment.
    pub fn isComment(self: Token) bool {
        return self.kind == .comment;
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
    preserve_newlines: bool,

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

        // Line comment: `\ ` followed by rest of line
        if (self.input[self.pos] == '\\' and
            self.pos + 1 < self.input.len and
            (self.input[self.pos + 1] == ' ' or self.input[self.pos + 1] == '\t'))
        {
            // Consume until end of line or end of input
            while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                self.pos += 1;
            }
            return .{ .kind = .comment, .text = self.input[start..self.pos], .line = token_line };
        }

        // String literal: collect until closing quote
        if (self.input[self.pos] == '"') {
            self.pos += 1; // skip opening quote
            while (self.pos < self.input.len and self.input[self.pos] != '"') {
                self.pos += 1;
            }
            if (self.pos < self.input.len) {
                self.pos += 1; // skip closing quote
            }
            return .{ .kind = .word, .text = self.input[start..self.pos], .line = token_line };
        }

        // Collect non-whitespace characters
        while (self.pos < self.input.len and !isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }

        return .{ .kind = .word, .text = self.input[start..self.pos], .line = token_line };
    }

    /// Reset the tokenizer to the beginning.
    pub fn reset(self: *Tokenizer) void {
        self.pos = 0;
        self.line = 1;
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }
};

/// Parse an integer from a token. Returns null if not a valid integer.
pub fn parseInteger(token: []const u8) ?i64 {
    return std.fmt.parseInt(i64, token, 10) catch null;
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
