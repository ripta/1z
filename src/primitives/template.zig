const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const FormatSpec = value_mod.FormatSpec;
const TemplateSegment = value_mod.TemplateSegment;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "template", .stack_effect = "string -- template", .func = nativeTemplate },
};

/// template ( string -- template ) - Parse format string into template value
fn nativeTemplate(ctx: *Context) anyerror!void {
    const input = try helpers.popString(ctx);
    const alloc = ctx.quotationAllocator();

    const segments = try parseTemplate(alloc, input);
    try ctx.stack.push(.{ .template = segments });
}

/// Parse a format string into an array of template segments.
///
/// Handles `\{` and `\}` escapes, `{}` identity, `{name}` named,
/// `{0}` indexed placeholders, and `{name:key=value,...}` format specs.
pub fn parseTemplate(alloc: Allocator, input: []const u8) ![]const TemplateSegment {
    var segments: std.ArrayListUnmanaged(TemplateSegment) = .{};
    errdefer {
        for (segments.items) |seg| {
            switch (seg) {
                .literal => |t| alloc.free(t),
                .named => |n| alloc.free(n.name),
                else => {},
            }
        }
        segments.deinit(alloc);
    }
    var literal_buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer literal_buf.deinit(alloc);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len and (input[i + 1] == '{' or input[i + 1] == '}')) {
            // Escaped brace: emit the literal brace character
            literal_buf.append(alloc, input[i + 1]) catch return error.OutOfMemory;
            i += 2;
        } else if (input[i] == '}') {
            // Unmatched closing brace (not escaped)
            return error.TypeError;
        } else if (input[i] == '{') {
            // Flush accumulated literal text
            if (literal_buf.items.len > 0) {
                const text = literal_buf.toOwnedSlice(alloc) catch return error.OutOfMemory;
                segments.append(alloc, .{ .literal = text }) catch return error.OutOfMemory;
            }

            const start = i + 1;
            var end = start;
            while (end < input.len and input[end] != '}') : (end += 1) {}
            if (end >= input.len) {
                // Unmatched opening brace
                return error.TypeError;
            }

            const content = input[start..end];
            i = end + 1;

            var name_part: []const u8 = content;
            var spec_part: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, content, ':')) |colon_pos| {
                name_part = content[0..colon_pos];
                spec_part = content[colon_pos + 1 ..];
            }

            const spec = if (spec_part) |sp| try parseFormatSpec(sp) else FormatSpec{};
            if (name_part.len == 0) {
                segments.append(alloc, .{ .identity = spec }) catch return error.OutOfMemory;
            } else if (isNumeric(name_part)) {
                const index = std.fmt.parseInt(usize, name_part, 10) catch return error.TypeError;
                segments.append(alloc, .{ .indexed = .{ .index = index, .spec = spec } }) catch return error.OutOfMemory;
            } else {
                const name = alloc.dupe(u8, name_part) catch return error.OutOfMemory;
                segments.append(alloc, .{ .named = .{ .name = name, .spec = spec } }) catch return error.OutOfMemory;
            }
        } else {
            literal_buf.append(alloc, input[i]) catch return error.OutOfMemory;
            i += 1;
        }
    }

    if (literal_buf.items.len > 0) {
        const text = literal_buf.toOwnedSlice(alloc) catch return error.OutOfMemory;
        segments.append(alloc, .{ .literal = text }) catch return error.OutOfMemory;
    }

    return segments.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

/// Check if a string consists entirely of ASCII digits.
fn isNumeric(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

/// Parse a format spec string like "width=2,fill=0,align=right".
fn parseFormatSpec(spec_str: []const u8) !FormatSpec {
    var spec = FormatSpec{};
    if (spec_str.len == 0) return spec;

    var iter = std.mem.splitScalar(u8, spec_str, ',');
    while (iter.next()) |pair| {
        if (pair.len == 0) continue;
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
            const key = pair[0..eq_pos];
            const val = pair[eq_pos + 1 ..];

            if (std.mem.eql(u8, key, "width")) {
                spec.width = std.fmt.parseInt(usize, val, 10) catch return error.TypeError;
            } else if (std.mem.eql(u8, key, "fill")) {
                if (val.len != 1) return error.TypeError;
                spec.fill = val[0];
            } else if (std.mem.eql(u8, key, "align")) {
                if (std.mem.eql(u8, val, "left")) {
                    spec.align_left = true;
                } else if (std.mem.eql(u8, val, "right")) {
                    spec.align_left = false;
                } else {
                    return error.TypeError;
                }
            } else {
                return error.TypeError;
            }
        } else {
            return error.TypeError;
        }
    }

    return spec;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const test_alloc = testing.allocator;

test "parse empty template" {
    const segments = try parseTemplate(test_alloc, "");
    defer test_alloc.free(segments);
    try testing.expectEqual(@as(usize, 0), segments.len);
}

test "parse literal only" {
    const segments = try parseTemplate(test_alloc, "hello world");
    defer {
        for (segments) |seg| {
            switch (seg) {
                .literal => |t| test_alloc.free(t),
                else => {},
            }
        }
        test_alloc.free(segments);
    }
    try testing.expectEqual(@as(usize, 1), segments.len);
    try testing.expectEqualStrings("hello world", segments[0].literal);
}

test "parse identity placeholder" {
    const segments = try parseTemplate(test_alloc, "val={}");
    defer {
        for (segments) |seg| {
            switch (seg) {
                .literal => |t| test_alloc.free(t),
                else => {},
            }
        }
        test_alloc.free(segments);
    }
    try testing.expectEqual(@as(usize, 2), segments.len);
    try testing.expectEqualStrings("val=", segments[0].literal);
    try testing.expectEqual(TemplateSegment{ .identity = FormatSpec{} }, segments[1]);
}

test "parse named placeholder" {
    const segments = try parseTemplate(test_alloc, "Hello {name}!");
    defer {
        for (segments) |seg| {
            switch (seg) {
                .literal => |t| test_alloc.free(t),
                .named => |n| test_alloc.free(n.name),
                else => {},
            }
        }
        test_alloc.free(segments);
    }
    try testing.expectEqual(@as(usize, 3), segments.len);
    try testing.expectEqualStrings("Hello ", segments[0].literal);
    try testing.expectEqualStrings("name", segments[1].named.name);
    try testing.expectEqualStrings("!", segments[2].literal);
}

test "parse indexed placeholder" {
    const segments = try parseTemplate(test_alloc, "{0} + {1}");
    defer {
        for (segments) |seg| {
            switch (seg) {
                .literal => |t| test_alloc.free(t),
                else => {},
            }
        }
        test_alloc.free(segments);
    }
    try testing.expectEqual(@as(usize, 3), segments.len);
    try testing.expectEqual(@as(usize, 0), segments[0].indexed.index);
    try testing.expectEqualStrings(" + ", segments[1].literal);
    try testing.expectEqual(@as(usize, 1), segments[2].indexed.index);
}

test "parse escaped braces" {
    const segments = try parseTemplate(test_alloc, "\\{literal\\}");
    defer {
        for (segments) |seg| {
            switch (seg) {
                .literal => |t| test_alloc.free(t),
                else => {},
            }
        }
        test_alloc.free(segments);
    }
    try testing.expectEqual(@as(usize, 1), segments.len);
    try testing.expectEqualStrings("{literal}", segments[0].literal);
}

test "parse format spec" {
    const segments = try parseTemplate(test_alloc, "{name:width=10,fill=0,align=left}");
    defer {
        for (segments) |seg| {
            switch (seg) {
                .named => |n| test_alloc.free(n.name),
                else => {},
            }
        }
        test_alloc.free(segments);
    }
    try testing.expectEqual(@as(usize, 1), segments.len);
    const named = segments[0].named;
    try testing.expectEqualStrings("name", named.name);
    try testing.expectEqual(@as(usize, 10), named.spec.width.?);
    try testing.expectEqual(@as(u8, '0'), named.spec.fill);
    try testing.expect(named.spec.align_left);
}

test "unmatched open brace is error" {
    const result = parseTemplate(test_alloc, "hello {world");
    try testing.expectError(error.TypeError, result);
}

test "unmatched close brace is error" {
    const result = parseTemplate(test_alloc, "hello }world");
    try testing.expectError(error.TypeError, result);
}

test "unknown format spec key is error" {
    const result = parseTemplate(test_alloc, "{name:bogus=1}");
    try testing.expectError(error.TypeError, result);
}
