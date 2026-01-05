const std = @import("std");

/// Represents a single parameter in a stack effect. Parameters can optionally
/// have quotation annotations.
pub const StackEffectParam = struct {
    name: []const u8,
    /// If non-null, this parameter is a quotation with its own stack effect
    quotation_effect: ?*const StackEffect = null,

    /// Write parameter to writer.
    pub fn write(self: StackEffectParam, writer: anytype) anyerror!void {
        try writer.writeAll(self.name);
        if (self.quotation_effect) |effect| {
            try writer.writeAll(": ");
            try effect.write(writer);
        }
    }

    pub fn eql(self: StackEffectParam, other: StackEffectParam) bool {
        if (!std.mem.eql(u8, self.name, other.name)) return false;
        if (self.quotation_effect == null and other.quotation_effect == null) return true;
        if (self.quotation_effect == null or other.quotation_effect == null) return false;
        return self.quotation_effect.?.eql(other.quotation_effect.?.*);
    }
};

/// Represents a complete stack effect declaration.
pub const StackEffect = struct {
    inputs: []const StackEffectParam,
    outputs: []const StackEffectParam,

    pub fn write(self: StackEffect, writer: anytype) anyerror!void {
        try writer.writeAll("( ");
        for (self.inputs, 0..) |param, i| {
            if (i > 0) try writer.writeAll(" ");
            try param.write(writer);
        }
        try writer.writeAll(" -- ");
        for (self.outputs, 0..) |param, i| {
            if (i > 0) try writer.writeAll(" ");
            try param.write(writer);
        }
        try writer.writeAll(" )");
    }

    pub fn eql(self: StackEffect, other: StackEffect) bool {
        if (self.inputs.len != other.inputs.len) return false;
        if (self.outputs.len != other.outputs.len) return false;
        for (self.inputs, other.inputs) |a, b| {
            if (!a.eql(b)) return false;
        }
        for (self.outputs, other.outputs) |a, b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "simple stack effect format" {
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{ .{ .name = "a" }, .{ .name = "b" } },
        .outputs = &[_]StackEffectParam{.{ .name = "c" }},
    };

    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try effect.write(fbs.writer());
    try std.testing.expectEqualStrings("( a b -- c )", fbs.getWritten());
}

test "stack effect with quotation annotation" {
    const nested = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "elem" }},
        .outputs = &[_]StackEffectParam{.{ .name = "elem'" }},
    };

    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "seq" },
            .{ .name = "quot", .quotation_effect = &nested },
        },
        .outputs = &[_]StackEffectParam{.{ .name = "seq'" }},
    };

    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try effect.write(fbs.writer());
    try std.testing.expectEqualStrings("( seq quot: ( elem -- elem' ) -- seq' )", fbs.getWritten());
}

test "stack effect equality" {
    const a = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    };
    const b = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    };
    const c = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "x" }},
        .outputs = &[_]StackEffectParam{.{ .name = "x" }},
    };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "empty stack effect" {
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{},
        .outputs = &[_]StackEffectParam{},
    };

    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try effect.write(fbs.writer());
    try std.testing.expectEqualStrings("(  --  )", fbs.getWritten());
}
