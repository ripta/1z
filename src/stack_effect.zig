const std = @import("std");

/// Represents a single parameter in a stack effect. Parameters can optionally
/// have quotation annotations.
pub const StackEffectParam = struct {
    name: []const u8,
    /// If non-null, this parameter is a quotation with its own stack effect
    quotation_effect: ?*const StackEffect = null,
    /// True if name starts with ".." (a row variable like ..a, ..b)
    is_row_variable: bool = false,

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
        if (self.is_row_variable != other.is_row_variable) return false;
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

    /// Count of input parameters that are not row variables.
    pub fn concreteInputCount(self: StackEffect) usize {
        var count: usize = 0;
        for (self.inputs) |param| {
            if (!param.is_row_variable) count += 1;
        }
        return count;
    }

    /// Count of output parameters that are not row variables.
    pub fn concreteOutputCount(self: StackEffect) usize {
        var count: usize = 0;
        for (self.outputs) |param| {
            if (!param.is_row_variable) count += 1;
        }
        return count;
    }

    /// Net stack delta considering only concrete (non-row-variable) parameters.
    pub fn concreteDelta(self: StackEffect) i64 {
        const out: i64 = @intCast(self.concreteOutputCount());
        const in: i64 = @intCast(self.concreteInputCount());
        return out - in;
    }

    pub const RowVarNames = struct {
        items: [8][]const u8 = undefined,
        len: usize = 0,

        pub fn slice(self: *const RowVarNames) []const []const u8 {
            return self.items[0..self.len];
        }

        fn append(self: *RowVarNames, name: []const u8) void {
            if (self.len < 8) {
                self.items[self.len] = name;
                self.len += 1;
            }
        }
    };

    /// Collect row variable names from inputs.
    pub fn inputRowVariableNames(self: StackEffect) RowVarNames {
        var result = RowVarNames{};
        for (self.inputs) |param| {
            if (param.is_row_variable) {
                result.append(param.name);
            }
        }
        return result;
    }

    /// Collect row variable names from outputs.
    pub fn outputRowVariableNames(self: StackEffect) RowVarNames {
        var result = RowVarNames{};
        for (self.outputs) |param| {
            if (param.is_row_variable) {
                result.append(param.name);
            }
        }
        return result;
    }

    /// True if every row variable in inputs also appears in outputs and vice versa.
    pub fn hasBalancedRowVariables(self: StackEffect) bool {
        const input_vars = self.inputRowVariableNames();
        const output_vars = self.outputRowVariableNames();

        for (input_vars.slice()) |iv| {
            var found = false;
            for (output_vars.slice()) |ov| {
                if (std.mem.eql(u8, iv, ov)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        for (output_vars.slice()) |ov| {
            var found = false;
            for (input_vars.slice()) |iv| {
                if (std.mem.eql(u8, ov, iv)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        return true;
    }
};

/// Check if a parameter name is a row variable (starts with "..")
pub fn isRowVariable(name: []const u8) bool {
    return name.len >= 2 and name[0] == '.' and name[1] == '.';
}

/// Check if a stack effect contains any row variables in its inputs or outputs.
pub fn hasAnyRowVariable(effect: StackEffect) bool {
    for (effect.inputs) |param| {
        if (param.is_row_variable) return true;
    }
    for (effect.outputs) |param| {
        if (param.is_row_variable) return true;
    }
    return false;
}

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

test "is_row_variable field" {
    const row_param = StackEffectParam{ .name = "..a", .is_row_variable = true };
    const concrete_param = StackEffectParam{ .name = "x" };

    try std.testing.expect(row_param.is_row_variable);
    try std.testing.expect(!concrete_param.is_row_variable);

    // Default is false
    const default_param = StackEffectParam{ .name = "..b" };
    try std.testing.expect(!default_param.is_row_variable);
}

test "is_row_variable affects equality" {
    const a = StackEffectParam{ .name = "..a", .is_row_variable = true };
    const b = StackEffectParam{ .name = "..a", .is_row_variable = false };
    try std.testing.expect(!a.eql(b));

    const c = StackEffectParam{ .name = "..a", .is_row_variable = true };
    try std.testing.expect(a.eql(c));
}

test "concreteInputCount and concreteOutputCount" {
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "x" },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "x" },
            .{ .name = "y" },
        },
    };

    try std.testing.expectEqual(@as(usize, 1), effect.concreteInputCount());
    try std.testing.expectEqual(@as(usize, 2), effect.concreteOutputCount());
}

test "concreteDelta" {
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "x" },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "x" },
            .{ .name = "y" },
        },
    };

    try std.testing.expectEqual(@as(i64, 1), effect.concreteDelta());
}

test "inputRowVariableNames and outputRowVariableNames" {
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "x" },
            .{ .name = "..b", .is_row_variable = true },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..b", .is_row_variable = true },
            .{ .name = "y" },
        },
    };

    const input_vars = effect.inputRowVariableNames();
    try std.testing.expectEqual(@as(usize, 2), input_vars.len);
    try std.testing.expectEqualStrings("..a", input_vars.slice()[0]);
    try std.testing.expectEqualStrings("..b", input_vars.slice()[1]);

    const output_vars = effect.outputRowVariableNames();
    try std.testing.expectEqual(@as(usize, 1), output_vars.len);
    try std.testing.expectEqualStrings("..b", output_vars.slice()[0]);
}

test "hasBalancedRowVariables" {
    // Balanced: ..a appears in both inputs and outputs
    const balanced = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "x" },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "y" },
        },
    };
    try std.testing.expect(balanced.hasBalancedRowVariables());

    // Unbalanced: ..a only in inputs
    const unbalanced_input = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "x" },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "y" },
        },
    };
    try std.testing.expect(!unbalanced_input.hasBalancedRowVariables());

    // Unbalanced: ..b only in outputs
    const unbalanced_output = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "x" },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..b", .is_row_variable = true },
            .{ .name = "y" },
        },
    };
    try std.testing.expect(!unbalanced_output.hasBalancedRowVariables());

    // No row variables at all: balanced (vacuously true)
    const no_row_vars = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "x" }},
        .outputs = &[_]StackEffectParam{.{ .name = "y" }},
    };
    try std.testing.expect(no_row_vars.hasBalancedRowVariables());
}

test "hasAnyRowVariable using struct field" {
    const with_row = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "x" },
        },
        .outputs = &[_]StackEffectParam{.{ .name = "y" }},
    };
    try std.testing.expect(hasAnyRowVariable(with_row));

    const without_row = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "x" }},
        .outputs = &[_]StackEffectParam{.{ .name = "y" }},
    };
    try std.testing.expect(!hasAnyRowVariable(without_row));
}
