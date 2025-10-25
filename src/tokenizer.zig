const std = @import("std");

/// Tokenizer splits input into whitespace-separated tokens.
/// Future milestones will add special handling for brackets, strings, etc.
pub const Tokenizer = struct {
    input: []const u8,
    pos: usize,

    pub fn init(input: []const u8) Tokenizer {
        return .{
            .input = input,
            .pos = 0,
        };
    }

    /// Returns the next token, or null if no more tokens.
    pub fn next(self: *Tokenizer) ?[]const u8 {
        // Skip leading whitespace
        while (self.pos < self.input.len and isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }

        if (self.pos >= self.input.len) {
            return null;
        }

        const start = self.pos;

        // Collect non-whitespace characters
        while (self.pos < self.input.len and !isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }

        return self.input[start..self.pos];
    }

    /// Reset the tokenizer to the beginning.
    pub fn reset(self: *Tokenizer) void {
        self.pos = 0;
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }
};

/// Parse an integer from a token. Returns null if not a valid integer.
pub fn parseInteger(token: []const u8) ?i64 {
    return std.fmt.parseInt(i64, token, 10) catch null;
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
    try std.testing.expectEqualStrings("hello", t.next().?);
    try std.testing.expectEqual(null, t.next());
}

test "multiple tokens" {
    var t = Tokenizer.init("one two three");
    try std.testing.expectEqualStrings("one", t.next().?);
    try std.testing.expectEqualStrings("two", t.next().?);
    try std.testing.expectEqualStrings("three", t.next().?);
    try std.testing.expectEqual(null, t.next());
}

test "tokens with various whitespace" {
    var t = Tokenizer.init("  a\tb\nc  ");
    try std.testing.expectEqualStrings("a", t.next().?);
    try std.testing.expectEqualStrings("b", t.next().?);
    try std.testing.expectEqualStrings("c", t.next().?);
    try std.testing.expectEqual(null, t.next());
}

test "number tokens" {
    var t = Tokenizer.init("123 456 -789");
    try std.testing.expectEqualStrings("123", t.next().?);
    try std.testing.expectEqualStrings("456", t.next().?);
    try std.testing.expectEqualStrings("-789", t.next().?);
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
    try std.testing.expectEqualStrings("a", t.next().?);
}
