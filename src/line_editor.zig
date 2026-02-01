const std = @import("std");

/// Key represents a parsed keyboard input event.
pub const Key = union(enum) {
    char: u8,
    enter,
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    ctrl_a,
    ctrl_c,
    ctrl_d,
    ctrl_e,
    ctrl_k,
    ctrl_u,
    ctrl_w,
    tab,
    unknown,
};

/// LineEditor provides character-by-character line editing with raw terminal mode.
pub const LineEditor = struct {
    original_termios: std.posix.termios,
    buf: [4096]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    prompt: []const u8 = "> ",

    /// Initialize the LineEditor by saving the current terminal settings and switching to raw mode.
    pub fn init() !LineEditor {
        const fd = std.posix.STDIN_FILENO;
        const original = try std.posix.tcgetattr(fd);

        var raw = original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;

        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;

        try std.posix.tcsetattr(fd, .FLUSH, raw);
        return .{
            .original_termios = original,
        };
    }

    /// Restore the original terminal settings.
    pub fn deinit(self: *LineEditor) void {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original_termios) catch {};
    }

    /// Read a complete line of input, returning null on EOF (Ctrl-D with empty buffer).
    pub fn readLine(self: *LineEditor, prompt: []const u8) !?[]const u8 {
        self.prompt = prompt;
        self.len = 0;
        self.cursor = 0;
        self.refreshLine();

        while (true) {
            const key = readKey();
            switch (key) {
                .char => |c| {
                    insertChar(self, c);
                    self.refreshLine();
                },
                .enter => {
                    _ = std.posix.write(std.posix.STDOUT_FILENO, "\r\n") catch {};
                    return self.buf[0..self.len];
                },
                .backspace => {
                    deleteCharBefore(self);
                    self.refreshLine();
                },
                .delete => {
                    deleteCharAt(self);
                    self.refreshLine();
                },
                .left => {
                    if (self.cursor > 0) {
                        self.cursor -= 1;
                        self.refreshLine();
                    }
                },
                .right => {
                    if (self.cursor < self.len) {
                        self.cursor += 1;
                        self.refreshLine();
                    }
                },
                .home, .ctrl_a => {
                    if (self.cursor != 0) {
                        self.cursor = 0;
                        self.refreshLine();
                    }
                },
                .end, .ctrl_e => {
                    if (self.cursor != self.len) {
                        self.cursor = self.len;
                        self.refreshLine();
                    }
                },
                .ctrl_d => {
                    if (self.len == 0) {
                        _ = std.posix.write(std.posix.STDOUT_FILENO, "\r\n") catch {};
                        return null;
                    }
                    deleteCharAt(self);
                    self.refreshLine();
                },
                .ctrl_c => {
                    _ = std.posix.write(std.posix.STDOUT_FILENO, "^C\r\n") catch {};
                    self.len = 0;
                    self.cursor = 0;
                    self.refreshLine();
                },
                .ctrl_k => {
                    if (self.cursor < self.len) {
                        self.len = self.cursor;
                        self.refreshLine();
                    }
                },
                .ctrl_u => {
                    killToStart(self);
                    self.refreshLine();
                },
                .ctrl_w => {
                    killWordBackward(self);
                    self.refreshLine();
                },
                .up, .down, .tab => {},
                .unknown => {},
            }
        }
    }

    /// Refresh the displayed line on screen.
    fn refreshLine(self: *LineEditor) void {
        var out_buf: [8192]u8 = undefined;
        var stream = std.io.fixedBufferStream(&out_buf);
        const writer = stream.writer();

        writer.writeAll("\r") catch return;
        writer.writeAll(self.prompt) catch return;
        writer.writeAll(self.buf[0..self.len]) catch return;
        writer.writeAll("\x1b[K") catch return;

        const chars_after_cursor = self.len - self.cursor;
        if (chars_after_cursor > 0) {
            std.fmt.format(writer, "\x1b[{d}D", .{chars_after_cursor}) catch return;
        }

        const data = stream.getWritten();
        _ = std.posix.write(std.posix.STDOUT_FILENO, data) catch {};
    }

    /// Read and parse a single key event from stdin.
    fn readKey() Key {
        var byte_buf: [1]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &byte_buf) catch return .unknown;
        if (n == 0) return .unknown;

        const byte = byte_buf[0];
        if (byte == '\x1b') {
            return readEscapeSequence();
        }

        return switch (byte) {
            '\r' => .enter,
            '\x7f', '\x08' => .backspace,
            '\x01' => .ctrl_a,
            '\x03' => .ctrl_c,
            '\x04' => .ctrl_d,
            '\x05' => .ctrl_e,
            '\x0b' => .ctrl_k,
            '\x15' => .ctrl_u,
            '\x17' => .ctrl_w,
            '\t' => .tab,
            0x20...0x7e => .{ .char = byte },
            else => .unknown,
        };
    }

    /// Parse an escape sequence after reading ESC (0x1b).
    fn readEscapeSequence() Key {
        var seq_buf: [1]u8 = undefined;

        const n1 = std.posix.read(std.posix.STDIN_FILENO, &seq_buf) catch return .unknown;
        if (n1 == 0) return .unknown;

        if (seq_buf[0] == '[') {
            const n2 = std.posix.read(std.posix.STDIN_FILENO, &seq_buf) catch return .unknown;
            if (n2 == 0) return .unknown;

            return switch (seq_buf[0]) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                'H' => .home,
                'F' => .end,
                '3' => blk: {
                    var tilde_buf: [1]u8 = undefined;
                    const n3 = std.posix.read(std.posix.STDIN_FILENO, &tilde_buf) catch break :blk .unknown;
                    if (n3 > 0 and tilde_buf[0] == '~') break :blk .delete;
                    break :blk .unknown;
                },
                '1' => blk: {
                    var tilde_buf: [1]u8 = undefined;
                    const n3 = std.posix.read(std.posix.STDIN_FILENO, &tilde_buf) catch break :blk .unknown;
                    if (n3 > 0 and tilde_buf[0] == '~') break :blk .home;
                    break :blk .unknown;
                },
                '4' => blk: {
                    var tilde_buf: [1]u8 = undefined;
                    const n3 = std.posix.read(std.posix.STDIN_FILENO, &tilde_buf) catch break :blk .unknown;
                    if (n3 > 0 and tilde_buf[0] == '~') break :blk .end;
                    break :blk .unknown;
                },
                else => .unknown,
            };
        } else if (seq_buf[0] == 'O') {
            const n2 = std.posix.read(std.posix.STDIN_FILENO, &seq_buf) catch return .unknown;
            if (n2 == 0) return .unknown;

            return switch (seq_buf[0]) {
                'H' => .home,
                'F' => .end,
                else => .unknown,
            };
        }

        return .unknown;
    }

    fn insertChar(self: *LineEditor, c: u8) void {
        if (self.len >= self.buf.len) return;
        if (self.cursor < self.len) {
            std.mem.copyBackwards(u8, self.buf[self.cursor + 1 .. self.len + 1], self.buf[self.cursor..self.len]);
        }
        self.buf[self.cursor] = c;
        self.len += 1;
        self.cursor += 1;
    }

    fn deleteCharBefore(self: *LineEditor) void {
        if (self.cursor == 0) return;
        if (self.cursor < self.len) {
            std.mem.copyForwards(u8, self.buf[self.cursor - 1 .. self.len - 1], self.buf[self.cursor..self.len]);
        }
        self.len -= 1;
        self.cursor -= 1;
    }

    fn deleteCharAt(self: *LineEditor) void {
        if (self.cursor >= self.len) return;
        if (self.cursor + 1 < self.len) {
            std.mem.copyForwards(u8, self.buf[self.cursor .. self.len - 1], self.buf[self.cursor + 1 .. self.len]);
        }
        self.len -= 1;
    }

    fn killToStart(self: *LineEditor) void {
        if (self.cursor > 0) {
            if (self.cursor < self.len) {
                std.mem.copyForwards(u8, self.buf[0 .. self.len - self.cursor], self.buf[self.cursor..self.len]);
            }
            self.len -= self.cursor;
            self.cursor = 0;
        }
    }

    fn killWordBackward(self: *LineEditor) void {
        if (self.cursor == 0) return;
        var pos = self.cursor;
        while (pos > 0 and self.buf[pos - 1] == ' ') pos -= 1;
        while (pos > 0 and self.buf[pos - 1] != ' ') pos -= 1;
        const deleted = self.cursor - pos;
        if (deleted == 0) return;
        if (self.cursor < self.len) {
            std.mem.copyForwards(u8, self.buf[pos .. self.len - deleted], self.buf[self.cursor..self.len]);
        }
        self.len -= deleted;
        self.cursor = pos;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "LineEditor buffer operations" {
    var editor = LineEditor{
        .original_termios = undefined,
    };

    // Insert characters
    LineEditor.insertChar(&editor, 'h');
    LineEditor.insertChar(&editor, 'e');
    LineEditor.insertChar(&editor, 'l');
    LineEditor.insertChar(&editor, 'l');
    LineEditor.insertChar(&editor, 'o');

    try std.testing.expectEqualStrings("hello", editor.buf[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 5), editor.cursor);

    // Move cursor left and insert
    editor.cursor = 2;
    LineEditor.insertChar(&editor, 'X');
    try std.testing.expectEqualStrings("heXllo", editor.buf[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 3), editor.cursor);

    // Delete at cursor
    LineEditor.deleteCharAt(&editor);
    try std.testing.expectEqualStrings("heXlo", editor.buf[0..editor.len]);

    // Delete before cursor (backspace)
    LineEditor.deleteCharBefore(&editor);
    try std.testing.expectEqualStrings("helo", editor.buf[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 2), editor.cursor);
}

test "LineEditor kill operations" {
    var editor = LineEditor{
        .original_termios = undefined,
    };

    // Set up "hello world"
    const text = "hello world";
    @memcpy(editor.buf[0..text.len], text);
    editor.len = text.len;
    editor.cursor = 5;

    // Kill to end
    editor.len = editor.cursor;
    try std.testing.expectEqualStrings("hello", editor.buf[0..editor.len]);

    // Reset
    @memcpy(editor.buf[0..text.len], text);
    editor.len = text.len;
    editor.cursor = 5;

    // Kill to start
    LineEditor.killToStart(&editor);
    try std.testing.expectEqualStrings(" world", editor.buf[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
}

test "LineEditor kill word backward" {
    var editor = LineEditor{
        .original_termios = undefined,
    };

    const text = "hello world foo";
    @memcpy(editor.buf[0..text.len], text);
    editor.len = text.len;
    editor.cursor = text.len;

    LineEditor.killWordBackward(&editor);
    try std.testing.expectEqualStrings("hello world ", editor.buf[0..editor.len]);

    LineEditor.killWordBackward(&editor);
    try std.testing.expectEqualStrings("hello ", editor.buf[0..editor.len]);
}
