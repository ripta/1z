const std = @import("std");
const Allocator = std.mem.Allocator;

const statement = @import("statement.zig");

/// The most bytes of one line this reader retains: a full statement plus a line terminator, and
/// one byte more so that a line which does not fit stays visibly over the limit.
const retain_limit = statement.max_statement_len + 2;

pub const ReadError = error{ EndOfStream, ReadFailed, OutOfMemory };

/// Reads source text a line at a time without bounding a line by the reader's own buffer.
///
/// A line the reader's buffer holds is returned in place. A longer line is gathered into an
/// owned buffer. Bytes past `retain_limit` are discarded, and the last retained byte is replaced
/// so the line still measures over the statement limit once its terminator is trimmed. The
/// statement processor then raises its own too-long error, which names the limit.
pub const SourceLineReader = struct {
    overflow: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *SourceLineReader, allocator: Allocator) void {
        self.overflow.deinit(allocator);
    }

    /// Returns the next line with its `\n` when the source has one. The slice is valid until the
    /// next call. `error.EndOfStream` means no bytes remain.
    pub fn next(self: *SourceLineReader, allocator: Allocator, reader: *std.Io.Reader) ReadError![]const u8 {
        return reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => try self.gather(allocator, reader),
            error.EndOfStream => error.EndOfStream,
            error.ReadFailed => error.ReadFailed,
        };
    }

    fn gather(self: *SourceLineReader, allocator: Allocator, reader: *std.Io.Reader) ReadError![]const u8 {
        self.overflow.clearRetainingCapacity();

        var truncated = false;
        while (true) {
            const available = reader.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return error.ReadFailed,
            };

            const newline = std.mem.indexOfScalar(u8, available, '\n');
            const take = if (newline) |index| index + 1 else available.len;

            const room = retain_limit - self.overflow.items.len;
            if (take > room) truncated = true;

            try self.overflow.appendSlice(allocator, available[0..@min(take, room)]);
            reader.toss(take);

            if (newline != null) break;
        }

        if (truncated) self.overflow.items[self.overflow.items.len - 1] = ' ';

        return self.overflow.items;
    }
};

test "a line inside the reader buffer is returned unchanged" {
    var source = std.Io.Reader.fixed("one\ntwo\n");

    var lines: SourceLineReader = .{};
    defer lines.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("one\n", try lines.next(std.testing.allocator, &source));
    try std.testing.expectEqualStrings("two\n", try lines.next(std.testing.allocator, &source));
    try std.testing.expectError(error.EndOfStream, lines.next(std.testing.allocator, &source));
}

test "a line past the reader buffer is gathered whole" {
    const allocator = std.testing.allocator;

    const text = try allocator.alloc(u8, 10001);
    defer allocator.free(text);
    @memset(text, 'a');
    text[10000] = '\n';

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, text);
    try input.appendSlice(allocator, "next\n");

    var buffer: [64]u8 = undefined;
    var source = std.Io.Reader.fixed(input.items);
    var limited = source.limited(.unlimited, &buffer);

    var lines: SourceLineReader = .{};
    defer lines.deinit(allocator);

    try std.testing.expectEqualStrings(text, try lines.next(allocator, &limited.interface));
    try std.testing.expectEqualStrings("next\n", try lines.next(allocator, &limited.interface));
}

test "a line past the statement limit stays over it" {
    const allocator = std.testing.allocator;

    const text = try allocator.alloc(u8, statement.max_statement_len * 2);
    defer allocator.free(text);
    @memset(text, 'a');
    text[text.len - 2] = '\r';
    text[text.len - 1] = '\n';

    var buffer: [64]u8 = undefined;
    var source = std.Io.Reader.fixed(text);
    var limited = source.limited(.unlimited, &buffer);

    var lines: SourceLineReader = .{};
    defer lines.deinit(allocator);

    const line = try lines.next(allocator, &limited.interface);
    const body = std.mem.trimRight(u8, line, "\r\n");
    try std.testing.expect(body.len > statement.max_statement_len);
}
