const std = @import("std");
const Dictionary = @import("dictionary.zig").Dictionary;

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

const max_history = 4096;

/// LineEditor provides character-by-character line editing with raw terminal mode.
pub const LineEditor = struct {
    original_termios: std.posix.termios,
    allocator: std.mem.Allocator,
    buf: [4096]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    prompt: []const u8 = "> ",
    history: std.ArrayListUnmanaged([]u8) = .{},
    history_index: ?usize = null,
    saved_buf: [4096]u8 = undefined,
    saved_len: usize = 0,
    dictionary: ?*Dictionary = null,
    last_was_tab: bool = false,

    /// Initialize the LineEditor by saving the current terminal settings and switching to raw mode.
    pub fn init(allocator: std.mem.Allocator) !LineEditor {
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
            .allocator = allocator,
        };
    }

    /// Restore the original terminal settings.
    pub fn deinit(self: *LineEditor) void {
        for (self.history.items) |entry| {
            self.allocator.free(entry);
        }
        self.history.deinit(self.allocator);
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original_termios) catch {};
    }

    /// Resolve the history file path. Returns null if no path can be determined.
    /// Up to the caller to free the returned slice.
    ///
    /// Prioritize $ONEZ_HISTFILE if set, otherwise $XDG_STATE_HOME/1z/history, and
    /// lastly ~/.local/state/1z/history (the default).
    pub fn resolveHistoryPath(self: *LineEditor) ?[]u8 {
        if (std.posix.getenv("ONEZ_HISTFILE")) |path| {
            return self.allocator.dupe(u8, path) catch null;
        }

        if (std.posix.getenv("XDG_STATE_HOME")) |xdg| {
            return std.fs.path.join(self.allocator, &.{ xdg, "1z", "history" }) catch null;
        }

        const home = std.posix.getenv("HOME") orelse return null;
        return std.fs.path.join(self.allocator, &.{ home, ".local", "state", "1z", "history" }) catch null;
    }

    /// Load history from a file. One entry per line. Silently ignores all errors.
    pub fn loadHistory(self: *LineEditor, path: []const u8) void {
        const file = std.fs.cwd().openFile(path, .{}) catch return;
        defer file.close();

        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(&read_buf);
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch return;
            const trimmed = std.mem.trimRight(u8, line, "\r\n");
            if (trimmed.len > 0) {
                self.addHistory(trimmed);
            }
        }
    }

    /// Save history to a file. One entry per line. Creates parent directory if needed.
    /// Silently ignores all errors.
    pub fn saveHistory(self: *LineEditor, path: []const u8) void {
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }

        const file = std.fs.cwd().createFile(path, .{}) catch return;
        defer file.close();

        var write_buf: [4096]u8 = undefined;
        var writer = file.writer(&write_buf);
        for (self.history.items) |entry| {
            writer.interface.writeAll(entry) catch return;
            writer.interface.writeAll("\n") catch return;
        }

        writer.interface.flush() catch {};
    }

    /// Add a line to history. Skips empty lines and consecutive duplicates.
    pub fn addHistory(self: *LineEditor, line: []const u8) void {
        if (line.len == 0) return;

        if (self.history.items.len > 0) {
            const last = self.history.items[self.history.items.len - 1];
            if (std.mem.eql(u8, last, line)) return;
        }

        if (self.history.items.len >= max_history) {
            self.allocator.free(self.history.items[0]);
            _ = self.history.orderedRemove(0);
        }

        const copy = self.allocator.dupe(u8, line) catch return;
        self.history.append(self.allocator, copy) catch {
            self.allocator.free(copy);
        };
    }

    /// Read a complete line of input, returning null on EOF (Ctrl-D with empty buffer).
    pub fn readLine(self: *LineEditor, prompt: []const u8) !?[]const u8 {
        self.prompt = prompt;
        self.len = 0;
        self.cursor = 0;
        self.history_index = null;
        self.refreshLine();

        while (true) {
            const key = readKey();
            const is_tab = key == .tab;
            defer self.last_was_tab = is_tab;

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
                .up => {
                    self.historyUp();
                    self.refreshLine();
                },
                .down => {
                    self.historyDown();
                    self.refreshLine();
                },
                .tab => {
                    if (self.last_was_tab) {
                        self.showCompletions();
                    } else {
                        self.tabComplete();
                    }
                    self.refreshLine();
                },
                .unknown => {},
            }
        }
    }

    fn historyUp(self: *LineEditor) void {
        if (self.history.items.len == 0) return;

        if (self.history_index) |idx| {
            if (idx > 0) {
                self.history_index = idx - 1;
                self.loadHistoryEntry(idx - 1);
            }
            return;
        }

        @memcpy(self.saved_buf[0..self.len], self.buf[0..self.len]);
        self.saved_len = self.len;
        const new_idx = self.history.items.len - 1;
        self.history_index = new_idx;
        self.loadHistoryEntry(new_idx);
    }

    fn historyDown(self: *LineEditor) void {
        if (self.history_index) |idx| {
            if (idx + 1 < self.history.items.len) {
                self.history_index = idx + 1;
                self.loadHistoryEntry(idx + 1);
                return;
            }

            self.history_index = null;
            @memcpy(self.buf[0..self.saved_len], self.saved_buf[0..self.saved_len]);
            self.len = self.saved_len;
            self.cursor = self.len;
        }
    }

    fn loadHistoryEntry(self: *LineEditor, idx: usize) void {
        const entry = self.history.items[idx];
        const copy_len = @min(entry.len, self.buf.len);
        @memcpy(self.buf[0..copy_len], entry[0..copy_len]);
        self.len = copy_len;
        self.cursor = copy_len;
    }

    /// Perform tab completion using the dictionary, if set.
    /// Completes the word at the cursor position by looking for longest common prefix
    /// among dictionary entries that start with the current token.
    ///
    /// - If no matches, rings bell.
    /// - If one match, completes the word and adds a trailing space.
    /// - If multiple matches, extends to longest common prefix, or rings bell if no extension.
    fn tabComplete(self: *LineEditor) void {
        const dict = self.dictionary orelse return;

        var token_start = self.cursor;
        while (token_start > 0 and self.buf[token_start - 1] != ' ') {
            token_start -= 1;
        }
        const prefix = self.buf[token_start..self.cursor];
        if (prefix.len == 0) return;

        var match_count: usize = 0;
        var first_match: ?[]const u8 = null;
        var lcp_len: usize = 0;

        var iter = dict.entries.iterator();
        while (iter.next()) |entry| {
            const name = entry.key_ptr.*;
            if (name.len >= prefix.len and std.mem.eql(u8, name[0..prefix.len], prefix)) {
                match_count += 1;
                if (first_match == null) {
                    first_match = name;
                    lcp_len = name.len;
                } else {
                    const limit = @min(lcp_len, name.len);
                    var i: usize = prefix.len;
                    while (i < limit and first_match.?[i] == name[i]) {
                        i += 1;
                    }
                    lcp_len = i;
                }
            }
        }

        if (match_count == 0) {
            _ = std.posix.write(std.posix.STDOUT_FILENO, "\x07") catch {};
            return;
        }

        if (match_count == 1) {
            const word = first_match.?;
            const suffix_with_space = word.len + 1;
            const new_len = token_start + suffix_with_space + (self.len - self.cursor);
            if (new_len > self.buf.len) return;

            const after_cursor = self.len - self.cursor;
            if (after_cursor > 0) {
                std.mem.copyBackwards(
                    u8,
                    self.buf[token_start + suffix_with_space .. token_start + suffix_with_space + after_cursor],
                    self.buf[self.cursor .. self.cursor + after_cursor],
                );
            }

            @memcpy(self.buf[token_start .. token_start + word.len], word);
            self.buf[token_start + word.len] = ' ';
            self.len = new_len;
            self.cursor = token_start + suffix_with_space;
            return;
        }

        if (lcp_len > prefix.len) {
            const extension = first_match.?[prefix.len..lcp_len];
            const new_len = self.len + extension.len;
            if (new_len > self.buf.len) return;

            const after_cursor = self.len - self.cursor;
            if (after_cursor > 0) {
                std.mem.copyBackwards(
                    u8,
                    self.buf[self.cursor + extension.len .. self.cursor + extension.len + after_cursor],
                    self.buf[self.cursor .. self.cursor + after_cursor],
                );
            }

            @memcpy(self.buf[self.cursor .. self.cursor + extension.len], extension);
            self.len = new_len;
            self.cursor += extension.len;
            return;
        }

        _ = std.posix.write(std.posix.STDOUT_FILENO, "\x07") catch {};
    }

    /// Display all matching completions below the current line on second consecutive Tab.
    /// Matches are sorted alphabetically and displayed in columns; truncated to 20 entries.
    fn showCompletions(self: *LineEditor) void {
        const dict = self.dictionary orelse return;

        var token_start = self.cursor;
        while (token_start > 0 and self.buf[token_start - 1] != ' ') {
            token_start -= 1;
        }

        const prefix = self.buf[token_start..self.cursor];
        if (prefix.len == 0) return;

        const max_collect = 256;
        var matches_buf: [max_collect][]const u8 = undefined;
        var match_count: usize = 0;

        var iter = dict.entries.iterator();
        while (iter.next()) |entry| {
            const name = entry.key_ptr.*;
            if (name.len >= prefix.len and std.mem.eql(u8, name[0..prefix.len], prefix)) {
                if (match_count < max_collect) {
                    matches_buf[match_count] = name;
                    match_count += 1;
                }
            }
        }

        if (match_count == 0) return;

        const matches = matches_buf[0..match_count];
        std.mem.sort([]const u8, matches, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        const term_width = getTerminalWidth();

        var max_word_len: usize = 0;
        const display_count = @min(match_count, 20);
        for (matches[0..display_count]) |m| {
            if (m.len > max_word_len) max_word_len = m.len;
        }
        const col_width = max_word_len + 2; // 2 spaces padding
        const num_cols = @max(term_width / col_width, 1);

        var out_buf: [8192]u8 = undefined;
        var stream = std.io.fixedBufferStream(&out_buf);
        const writer = stream.writer();

        writer.writeAll("\r\n") catch return;
        for (matches[0..display_count], 0..) |m, i| {
            writer.writeAll(m) catch return;
            if ((i + 1) % num_cols == 0 or i + 1 == display_count) {
                writer.writeAll("\r\n") catch return;
            } else {
                // Pad to column width
                const padding = col_width - m.len;
                var p: usize = 0;
                while (p < padding) : (p += 1) {
                    writer.writeAll(" ") catch return;
                }
            }
        }

        if (match_count > 20) {
            std.fmt.format(writer, "... and {d} more\r\n", .{match_count - 20}) catch {};
        }

        const data = stream.getWritten();
        _ = std.posix.write(std.posix.STDOUT_FILENO, data) catch {};
    }

    fn getTerminalWidth() usize {
        if (!@hasDecl(std.posix.system, "winsize")) {
            var ws: std.posix.system.winsize = undefined;
            const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.system.T.IOCGWINSZ, @intFromPtr(&ws));
            if (rc == 0 and ws.col > 0) {
                return ws.col;
            }
        }

        return 80;
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

fn testEditor() LineEditor {
    return .{
        .original_termios = undefined,
        .allocator = std.testing.allocator,
    };
}

test "LineEditor buffer operations" {
    var editor = testEditor();

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
    var editor = testEditor();

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
    var editor = testEditor();

    const text = "hello world foo";
    @memcpy(editor.buf[0..text.len], text);
    editor.len = text.len;
    editor.cursor = text.len;

    LineEditor.killWordBackward(&editor);
    try std.testing.expectEqualStrings("hello world ", editor.buf[0..editor.len]);

    LineEditor.killWordBackward(&editor);
    try std.testing.expectEqualStrings("hello ", editor.buf[0..editor.len]);
}

test "LineEditor addHistory" {
    var editor = testEditor();
    defer editor.deinit();

    editor.addHistory("first");
    editor.addHistory("second");
    editor.addHistory("third");

    try std.testing.expectEqual(@as(usize, 3), editor.history.items.len);
    try std.testing.expectEqualStrings("first", editor.history.items[0]);
    try std.testing.expectEqualStrings("second", editor.history.items[1]);
    try std.testing.expectEqualStrings("third", editor.history.items[2]);
}

test "LineEditor addHistory skips empty and duplicates" {
    var editor = testEditor();
    defer editor.deinit();

    editor.addHistory("");
    try std.testing.expectEqual(@as(usize, 0), editor.history.items.len);

    editor.addHistory("hello");
    editor.addHistory("hello");
    try std.testing.expectEqual(@as(usize, 1), editor.history.items.len);

    editor.addHistory("world");
    editor.addHistory("hello");
    try std.testing.expectEqual(@as(usize, 3), editor.history.items.len);
}

test "LineEditor history navigation" {
    var editor = testEditor();
    defer editor.deinit();

    editor.addHistory("first");
    editor.addHistory("second");
    editor.addHistory("third");

    // Set current line content
    const current = "typing";
    @memcpy(editor.buf[0..current.len], current);
    editor.len = current.len;
    editor.cursor = current.len;

    // Up goes to most recent
    LineEditor.historyUp(&editor);
    try std.testing.expectEqualStrings("third", editor.buf[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 2), editor.history_index.?);

    // Up again
    LineEditor.historyUp(&editor);
    try std.testing.expectEqualStrings("second", editor.buf[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 1), editor.history_index.?);

    // Up again
    LineEditor.historyUp(&editor);
    try std.testing.expectEqualStrings("first", editor.buf[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 0), editor.history_index.?);

    // Up at top stays at top
    LineEditor.historyUp(&editor);
    try std.testing.expectEqualStrings("first", editor.buf[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 0), editor.history_index.?);

    // Down goes forward
    LineEditor.historyDown(&editor);
    try std.testing.expectEqualStrings("second", editor.buf[0..editor.len]);

    LineEditor.historyDown(&editor);
    try std.testing.expectEqualStrings("third", editor.buf[0..editor.len]);

    // Down past end restores saved line
    LineEditor.historyDown(&editor);
    try std.testing.expectEqualStrings("typing", editor.buf[0..editor.len]);
    try std.testing.expect(editor.history_index == null);
}
