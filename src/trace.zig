const std = @import("std");
const File = std.fs.File;
const Value = @import("value.zig").Value;
const Stack = @import("stack.zig").Stack;
const dispatch = @import("dispatch.zig");

/// Configuration for execution tracing.
pub const TraceConfig = struct {
    trace_words: bool = false,
    trace_words_pattern: ?[]const u8 = null,
    trace_resolve: bool = false,
    trace_resolve_pattern: ?[]const u8 = null,
    trace_modules: bool = false,
    dump_scope: ?[]const u8 = null,

    pub fn isEnabled(self: TraceConfig) bool {
        return self.trace_words or self.trace_resolve or self.trace_modules or self.dump_scope != null;
    }
};

/// Buffered writer for trace output.
pub const TraceWriter = struct {
    file: File,

    pub fn init() TraceWriter {
        return .{ .file = .stderr() };
    }

    pub fn print(self: *TraceWriter, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        var w = self.file.writer(&buf);
        w.interface.print(fmt, args) catch return;
        w.interface.flush() catch return;
    }

    pub fn writeAll(self: *TraceWriter, bytes: []const u8) void {
        var buf: [4096]u8 = undefined;
        var w = self.file.writer(&buf);
        w.interface.writeAll(bytes) catch return;
        w.interface.flush() catch return;
    }
};

/// Write a short type-tagged preview of the top `max_values` stack entries
/// to the given writer. Values are shown deepest-to-shallowest.
///
/// Format: `stack=[type:preview type:preview ...]`
pub fn formatStackPreview(stack: *const Stack, writer: anytype, max_values: usize) void {
    const depth = stack.depth();
    writer.writeAll("stack=[") catch return;

    const show = @min(depth, max_values);
    const has_overflow = depth > max_values;

    if (has_overflow) {
        writer.writeAll("... ") catch return;
    }

    var i: usize = show;
    while (i > 0) {
        i -= 1;
        const val = stack.peekN(i) catch continue;
        const type_name = dispatch.dispatchTypeName(val);
        writer.print("{s}:", .{type_name}) catch return;
        writeValuePreview(val, writer) catch return;
        if (i > 0) {
            writer.writeByte(' ') catch return;
        }
    }

    writer.writeByte(']') catch return;
}

/// Write a short representation of a value suitable for trace output.
pub fn writeValuePreview(val: Value, writer: anytype) !void {
    switch (val) {
        .fixnum => |i| try writer.print("{d}", .{i}),
        .float => |f| {
            if (std.math.isNan(f)) {
                try writer.writeAll("nan");
            } else if (std.math.isInf(f)) {
                if (f < 0) try writer.writeByte('-');
                try writer.writeAll("inf");
            } else {
                try writer.print("{d}", .{f});
            }
        },
        .boolean => |b| try writer.writeAll(if (b) "t" else "f"),
        .string => |s| {
            if (s.len <= 20) {
                try writer.print("\"{s}\"", .{s});
            } else {
                try writer.print("\"{s}...\"", .{s[0..20]});
            }
        },
        .symbol => |s| try writer.print("{s}:", .{s}),
        .array => |items| try writer.print("<array:{d}>", .{items.len}),
        .vector => |v| try writer.print("<vector:{d}>", .{v.items.len}),
        .byte_array => |b| try writer.print("<byte-array:{d}>", .{b.items.len}),
        .set => |s| try writer.print("<set:{d}>", .{s.count()}),
        .hash => |h| try writer.print("<hash:{d}>", .{h.count()}),
        .mutable_map => |m| try writer.print("<mutable-map:{d}>", .{m.count()}),
        .bignum => try writer.writeAll("<bignum>"),
        .tagged => |t| try writer.print("<{s}>", .{t.tag.name}),
        .struct_instance => |si| try writer.print("<{s}>", .{si.struct_type.name}),
        .quotation => try writer.writeAll("<quotation>"),
        .stream => try writer.writeAll("<stream>"),
        .resource => |r| try writer.print("<resource:{s}>", .{r.type_name}),
        .module => |m| try writer.print("<module:{s}>", .{m.name}),
        .iterator => try writer.writeAll("<iterator>"),
        .channel => try writer.writeAll("<channel>"),
        .task => try writer.writeAll("<task>"),
        .parameter => try writer.writeAll("<parameter>"),
        .marker => try writer.writeAll("<marker>"),
        .struct_type => try writer.writeAll("<struct-type>"),
        .template => try writer.writeAll("<template>"),
        .benchmark_report => try writer.writeAll("<benchmark-report>"),
        .stack_effect => try writer.writeAll("<stack-effect>"),
        .error_value => try writer.writeAll("<error>"),
        .doc_string => try writer.writeAll("<doc-string>"),
    }
}

/// Returns true if `name` matches the given comma-separated pattern.
/// A null pattern matches everything.
pub fn matchesPattern(name: []const u8, pattern: ?[]const u8) bool {
    const pat = pattern orelse return true;
    var iter = std.mem.splitScalar(u8, pat, ',');
    while (iter.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t");
        if (trimmed.len > 0 and std.mem.eql(u8, trimmed, name)) {
            return true;
        }
    }
    return false;
}

// =============================================================================
// Tests
// ============================================================================

test "matchesPattern: null pattern matches everything" {
    try std.testing.expect(matchesPattern("anything", null));
    try std.testing.expect(matchesPattern("", null));
}

test "matchesPattern: single pattern" {
    try std.testing.expect(matchesPattern("foo", "foo"));
    try std.testing.expect(!matchesPattern("bar", "foo"));
}

test "matchesPattern: comma-separated patterns" {
    try std.testing.expect(matchesPattern("foo", "foo,bar,baz"));
    try std.testing.expect(matchesPattern("bar", "foo,bar,baz"));
    try std.testing.expect(matchesPattern("baz", "foo,bar,baz"));
    try std.testing.expect(!matchesPattern("qux", "foo,bar,baz"));
}

test "matchesPattern: whitespace trimming" {
    try std.testing.expect(matchesPattern("foo", " foo , bar "));
    try std.testing.expect(matchesPattern("bar", " foo , bar "));
    try std.testing.expect(!matchesPattern(" foo", " foo , bar "));
}

test "matchesPattern: no match" {
    try std.testing.expect(!matchesPattern("xyz", "foo,bar"));
}

test "TraceConfig.isEnabled: all false" {
    const config = TraceConfig{};
    try std.testing.expect(!config.isEnabled());
}

test "TraceConfig.isEnabled: trace_words" {
    const config = TraceConfig{ .trace_words = true };
    try std.testing.expect(config.isEnabled());
}

test "TraceConfig.isEnabled: trace_resolve" {
    const config = TraceConfig{ .trace_resolve = true };
    try std.testing.expect(config.isEnabled());
}

test "TraceConfig.isEnabled: trace_modules" {
    const config = TraceConfig{ .trace_modules = true };
    try std.testing.expect(config.isEnabled());
}

test "TraceConfig.isEnabled: dump_scope" {
    const config = TraceConfig{ .dump_scope = "foo" };
    try std.testing.expect(config.isEnabled());
}

test "formatStackPreview: empty stack" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const stack = Stack.init(std.testing.allocator);
    formatStackPreview(&stack, fbs.writer(), 3);
    try std.testing.expectEqualStrings("stack=[]", fbs.getWritten());
}

test "formatStackPreview: single value" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();
    try stack.push(.{ .fixnum = 42 });

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    formatStackPreview(&stack, fbs.writer(), 3);
    try std.testing.expectEqualStrings("stack=[fixnum:42]", fbs.getWritten());
}

test "formatStackPreview: mixed types" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();
    try stack.push(.{ .fixnum = 1 });
    try stack.push(.{ .boolean = true });
    try stack.push(.{ .string = "hi" });

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    formatStackPreview(&stack, fbs.writer(), 3);
    try std.testing.expectEqualStrings("stack=[fixnum:1 boolean:t string:\"hi\"]", fbs.getWritten());
}

test "formatStackPreview: overflow with ellipsis" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();
    try stack.push(.{ .fixnum = 1 });
    try stack.push(.{ .fixnum = 2 });
    try stack.push(.{ .fixnum = 3 });
    try stack.push(.{ .fixnum = 4 });

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    formatStackPreview(&stack, fbs.writer(), 3);
    try std.testing.expectEqualStrings("stack=[... fixnum:2 fixnum:3 fixnum:4]", fbs.getWritten());
}

test "writeValuePreview: string truncation" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeValuePreview(.{ .string = "this is a very long string that exceeds twenty" }, fbs.writer());
    try std.testing.expectEqualStrings("\"this is a very long ...\"", fbs.getWritten());
}

test "writeValuePreview: short string" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeValuePreview(.{ .string = "short" }, fbs.writer());
    try std.testing.expectEqualStrings("\"short\"", fbs.getWritten());
}

test "writeValuePreview: symbol" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeValuePreview(.{ .symbol = "foo" }, fbs.writer());
    try std.testing.expectEqualStrings("foo:", fbs.getWritten());
}
