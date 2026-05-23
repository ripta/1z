const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const FormatSpec = value_mod.FormatSpec;
const TemplateSegment = value_mod.TemplateSegment;

const Value = value_mod.Value;
const StructInstance = value_mod.StructInstance;
const HashTable = value_mod.HashTable;
const MutableMap = value_mod.MutableMap;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = ">template", .stack_effect = "string -- template", .doc = "Parse format string into template value.", .func = nativeTemplate },
    .{ .name = "interpolate", .stack_effect = "source template -- string", .doc = "Apply template to source value.", .func = nativeInterpolate },
};

/// template ( string -- template ) - Parse format string into template value
fn nativeTemplate(ctx: *Context) anyerror!void {
    const input = try helpers.popString(ctx);
    const alloc = ctx.quotationAllocator();

    const segments = try parseTemplate(ctx, alloc, input);
    try ctx.stack.push(.{ .template = segments });
}

/// interpolate ( source template -- string ) - Apply template to source value
fn nativeInterpolate(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const val = try ctx.stack.pop();
    const segments = switch (val) {
        .template => |t| t,
        else => {
            helpers.setTypeMismatchError(ctx, "template", val);
            return error.TypeMismatch;
        },
    };
    const source = try ctx.stack.pop();

    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(alloc);

    for (segments) |seg| {
        switch (seg) {
            .literal => |text| {
                writer.writeAll(text) catch return error.OutOfMemory;
            },
            .identity => |spec| {
                const str = try valueToString(alloc, source);
                try appendFormatted(writer, str, spec);
            },
            .named => |n| {
                const field_val = try lookupNamed(ctx, source, n.name);
                const str = try valueToString(alloc, field_val);
                try appendFormatted(writer, str, n.spec);
            },
            .indexed => |idx| {
                const elem = try lookupIndexed(ctx, source, idx.index);
                const str = try valueToString(alloc, elem);
                try appendFormatted(writer, str, idx.spec);
            },
        }
    }

    try ctx.stack.push(.{ .string = buf.toOwnedSlice(alloc) catch return error.OutOfMemory });
}

/// Convert a value to its unquoted string representation, like `>string`
/// but without pushing to the stack.
fn valueToString(alloc: Allocator, val: Value) ![]const u8 {
    return switch (val) {
        .string => |s| s,
        else => {
            var buffer: std.ArrayListUnmanaged(u8) = .{};
            val.write(buffer.writer(alloc)) catch return error.OutOfMemory;
            return buffer.toOwnedSlice(alloc) catch return error.OutOfMemory;
        },
    };
}

/// Look up a named field on a struct instance, hash, or mutable map.
fn lookupNamed(ctx: ?*Context, source: Value, name: []const u8) !Value {
    switch (source) {
        .struct_instance => |si| {
            for (si.struct_type.fields, 0..) |field, i| {
                if (std.mem.eql(u8, field, name)) {
                    return si.fields[i];
                }
            }
            return error.KeyNotFound;
        },
        .hash => |h| {
            return h.get(name) orelse return error.KeyNotFound;
        },
        .mutable_map => |m| {
            return m.map.get(name) orelse return error.KeyNotFound;
        },
        else => {
            if (ctx) |c| helpers.setTypeMismatchError(c, "struct, hash, or mutable-map", source);
            return error.TypeMismatch;
        },
    }
}

/// Look up an indexed element on an array.
fn lookupIndexed(ctx: ?*Context, source: Value, index: usize) !Value {
    switch (source) {
        .array => |arr| {
            if (index >= arr.len) return error.IndexOutOfBounds;
            return arr[index];
        },
        else => {
            if (ctx) |c| helpers.setTypeMismatchError(c, "array", source);
            return error.TypeMismatch;
        },
    }
}

/// Append a string to the writer, applying format spec padding.
fn appendFormatted(writer: anytype, str: []const u8, spec: FormatSpec) !void {
    const width = spec.width orelse {
        writer.writeAll(str) catch return error.OutOfMemory;
        return;
    };

    if (str.len >= width) {
        writer.writeAll(str) catch return error.OutOfMemory;
        return;
    }

    const padding = width - str.len;
    if (spec.align_left) {
        writer.writeAll(str) catch return error.OutOfMemory;
        for (0..padding) |_| {
            writer.writeByte(spec.fill) catch return error.OutOfMemory;
        }
    } else {
        for (0..padding) |_| {
            writer.writeByte(spec.fill) catch return error.OutOfMemory;
        }
        writer.writeAll(str) catch return error.OutOfMemory;
    }
}

/// Parse a format string into an array of template segments.
///
/// Handles `\{` and `\}` escapes, `{}` identity, `{name}` named,
/// `{0}` indexed placeholders, and `{name:key=value,...}` format specs.
pub fn parseTemplate(ctx: ?*Context, alloc: Allocator, input: []const u8) ![]const TemplateSegment {
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
            if (ctx) |c| helpers.setErrorContext(c, "unmatched closing brace in template string", .{});
            return error.TypeMismatch;
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
                if (ctx) |c| helpers.setErrorContext(c, "unmatched opening brace in template string", .{});
                return error.TypeMismatch;
            }

            const content = input[start..end];
            i = end + 1;

            var name_part: []const u8 = content;
            var spec_part: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, content, ':')) |colon_pos| {
                name_part = content[0..colon_pos];
                spec_part = content[colon_pos + 1 ..];
            }

            const spec = if (spec_part) |sp| try parseFormatSpec(ctx, sp) else FormatSpec{};
            if (name_part.len == 0) {
                segments.append(alloc, .{ .identity = spec }) catch return error.OutOfMemory;
            } else if (isNumeric(name_part)) {
                const index = std.fmt.parseInt(usize, name_part, 10) catch {
                    if (ctx) |c| helpers.setErrorContext(c, "invalid placeholder index '{s}'", .{name_part});
                    return error.TypeMismatch;
                };
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
fn parseFormatSpec(ctx: ?*Context, spec_str: []const u8) !FormatSpec {
    var spec = FormatSpec{};
    if (spec_str.len == 0) return spec;

    var iter = std.mem.splitScalar(u8, spec_str, ',');
    while (iter.next()) |pair| {
        if (pair.len == 0) continue;
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
            const key = pair[0..eq_pos];
            const val = pair[eq_pos + 1 ..];

            if (std.mem.eql(u8, key, "width")) {
                spec.width = std.fmt.parseInt(usize, val, 10) catch {
                    if (ctx) |c| helpers.setErrorContext(c, "invalid width value '{s}' in format spec", .{val});
                    return error.TypeMismatch;
                };
            } else if (std.mem.eql(u8, key, "fill")) {
                if (val.len != 1) {
                    if (ctx) |c| helpers.setErrorContext(c, "fill must be a single character, got '{s}'", .{val});
                    return error.TypeMismatch;
                }
                spec.fill = val[0];
            } else if (std.mem.eql(u8, key, "align")) {
                if (std.mem.eql(u8, val, "left")) {
                    spec.align_left = true;
                } else if (std.mem.eql(u8, val, "right")) {
                    spec.align_left = false;
                } else {
                    if (ctx) |c| helpers.setErrorContext(c, "invalid align value '{s}', expected 'left' or 'right'", .{val});
                    return error.TypeMismatch;
                }
            } else {
                if (ctx) |c| helpers.setErrorContext(c, "unknown format spec key '{s}'", .{key});
                return error.TypeMismatch;
            }
        } else {
            if (ctx) |c| helpers.setErrorContext(c, "format spec pair '{s}' missing '=' separator", .{pair});
            return error.TypeMismatch;
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
    const segments = try parseTemplate(null, test_alloc, "");
    defer test_alloc.free(segments);
    try testing.expectEqual(@as(usize, 0), segments.len);
}

test "parse literal only" {
    const segments = try parseTemplate(null, test_alloc, "hello world");
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
    const segments = try parseTemplate(null, test_alloc, "val={}");
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
    const segments = try parseTemplate(null, test_alloc, "Hello {name}!");
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
    const segments = try parseTemplate(null, test_alloc, "{0} + {1}");
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
    const segments = try parseTemplate(null, test_alloc, "\\{literal\\}");
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
    const segments = try parseTemplate(null, test_alloc, "{name:width=10,fill=0,align=left}");
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
    const result = parseTemplate(null, test_alloc, "hello {world");
    try testing.expectError(error.TypeMismatch, result);
}

test "unmatched close brace is error" {
    const result = parseTemplate(null, test_alloc, "hello }world");
    try testing.expectError(error.TypeMismatch, result);
}

test "unknown format spec key is error" {
    const result = parseTemplate(null, test_alloc, "{name:bogus=1}");
    try testing.expectError(error.TypeMismatch, result);
}

test "valueToString passes strings through" {
    const result = try valueToString(test_alloc, .{ .string = "hello" });
    try testing.expectEqualStrings("hello", result);
}

test "valueToString converts fixnum" {
    const result = try valueToString(test_alloc, .{ .fixnum = 42 });
    defer test_alloc.free(result);
    try testing.expectEqualStrings("42", result);
}

test "valueToString converts boolean" {
    const result = try valueToString(test_alloc, .{ .boolean = true });
    defer test_alloc.free(result);
    try testing.expectEqualStrings("t", result);
}

test "lookupNamed on hash" {
    var h = HashTable{};
    defer h.deinit(test_alloc);
    try h.put(test_alloc, "x", .{ .fixnum = 10 });
    const val = try lookupNamed(null, .{ .hash = &h }, "x");
    try testing.expectEqual(Value{ .fixnum = 10 }, val);
}

test "lookupNamed on hash missing key" {
    var h = HashTable{};
    defer h.deinit(test_alloc);
    try h.put(test_alloc, "x", .{ .fixnum = 10 });
    const result = lookupNamed(null, .{ .hash = &h }, "y");
    try testing.expectError(error.KeyNotFound, result);
}

test "lookupNamed on array is TypeError" {
    const arr = &[_]Value{.{ .fixnum = 1 }};
    const result = lookupNamed(null, .{ .array = arr }, "x");
    try testing.expectError(error.TypeMismatch, result);
}

test "lookupIndexed on array" {
    const arr = &[_]Value{ .{ .fixnum = 10 }, .{ .fixnum = 20 } };
    const val = try lookupIndexed(null, .{ .array = arr }, 1);
    try testing.expectEqual(Value{ .fixnum = 20 }, val);
}

test "lookupIndexed out of bounds" {
    const arr = &[_]Value{.{ .fixnum = 10 }};
    const result = lookupIndexed(null, .{ .array = arr }, 5);
    try testing.expectError(error.IndexOutOfBounds, result);
}

test "lookupIndexed on hash is TypeError" {
    var h = HashTable{};
    defer h.deinit(test_alloc);
    const result = lookupIndexed(null, .{ .hash = &h }, 0);
    try testing.expectError(error.TypeMismatch, result);
}

test "appendFormatted no spec" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(test_alloc);
    try appendFormatted(buf.writer(test_alloc), "hello", .{});
    try testing.expectEqualStrings("hello", buf.items);
}

test "appendFormatted right-align with fill" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(test_alloc);
    try appendFormatted(buf.writer(test_alloc), "3", .{ .width = 4, .fill = '0' });
    try testing.expectEqualStrings("0003", buf.items);
}

test "appendFormatted left-align with fill" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(test_alloc);
    try appendFormatted(buf.writer(test_alloc), "hi", .{ .width = 6, .fill = '.', .align_left = true });
    try testing.expectEqualStrings("hi....", buf.items);
}

test "appendFormatted no padding when value exceeds width" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(test_alloc);
    try appendFormatted(buf.writer(test_alloc), "longstring", .{ .width = 3 });
    try testing.expectEqualStrings("longstring", buf.items);
}
