const std = @import("std");
const value_mod = @import("value.zig");
const TypeValue = value_mod.TypeValue;
const ProtocolDescriptor = value_mod.ProtocolDescriptor;
const ConstraintCombinator = value_mod.ConstraintCombinator;

/// A type annotation on a stack-effect parameter. Carries a concrete type (the
/// `( x: fixnum -- ... )` case), a protocol bound (`( x: comparable -- ... )`),
/// or a constraint combinator (`( x: comparable & stringable -- ... )` or a
/// mixed union `fixnum | comparable`). The arms stay distinct because
/// `TypeValue` describes value inhabitants, `ProtocolDescriptor` describes a
/// constraint on types, and `ConstraintCombinator` describes an algebraic
/// combination over constraints -- collapsing them would force every consumer
/// to learn a runtime flag-check.
pub const TypeAnnotation = union(enum) {
    type: *const TypeValue,
    protocol: *const ProtocolDescriptor,
    combination: *const ConstraintCombinator,

    pub fn name(self: TypeAnnotation) []const u8 {
        return switch (self) {
            .type => |tv| tv.name,
            .protocol => |pd| pd.name,
            // Combinators have no stored name and rendering the element list
            // requires allocation this accessor cannot do; structural
            // rendering belongs to the printer.
            .combination => "<constraint>",
        };
    }

    pub fn eql(self: TypeAnnotation, other: TypeAnnotation) bool {
        return switch (self) {
            .type => |a| switch (other) {
                .type => |b| a == b,
                .protocol, .combination => false,
            },
            .protocol => |a| switch (other) {
                .protocol => |b| a == b,
                .type, .combination => false,
            },
            .combination => |a| switch (other) {
                .combination => |b| a == b,
                .type, .protocol => false,
            },
        };
    }
};

/// Represents a single parameter in a stack effect. Parameters can optionally
/// have quotation annotations.
pub const StackEffectParam = struct {
    name: []const u8,
    /// If non-null, this parameter is a quotation with its own stack effect
    quotation_effect: ?*const StackEffect = null,
    /// True if name starts with ".." (a row variable like ..a, ..b)
    is_row_variable: bool = false,
    /// If non-null, this parameter has a type annotation -- either a concrete
    /// type or a protocol bound. Mutually exclusive with quotation_effect.
    type_annotation: ?TypeAnnotation = null,

    /// Write parameter to writer.
    pub fn write(self: StackEffectParam, writer: anytype) anyerror!void {
        try writer.writeAll(self.name);
        if (self.quotation_effect) |effect| {
            try writer.writeAll(": ");
            try effect.write(writer);
        } else if (self.type_annotation) |ann| {
            try writer.writeAll(": ");
            try writer.writeAll(ann.name());
        }
    }

    pub fn eql(self: StackEffectParam, other: StackEffectParam) bool {
        if (!std.mem.eql(u8, self.name, other.name)) return false;
        if (self.is_row_variable != other.is_row_variable) return false;

        if (self.type_annotation) |a| {
            const b = other.type_annotation orelse return false;
            if (!a.eql(b)) return false;
        } else if (other.type_annotation != null) {
            return false;
        }

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

    /// True if the outputs declare an alternative arity with the `|` marker, e.g.:
    ///
    ///     ( scanner -- new-scanner token | f )
    ///
    /// The parser's way of recording a word whose output depth genuinely varies between branches.
    ///
    /// The `|` is stored as a literal output parameter, so its presence is the signal that the
    /// declared concrete output count does not model the result.
    pub fn hasAlternativeOutput(self: StackEffect) bool {
        return paramsHaveAlternativeOutput(self.outputs);
    }

    /// True if the outputs declare the bottom output `-- *`: a single output named `*`.
    ///
    /// This is the honest output shape of a word that never returns to its caller. The
    /// `*` is stored as an ordinary named output, not a row variable, so its presence is
    /// detected by name.
    pub fn isBottomOutput(self: StackEffect) bool {
        return self.outputs.len == 1 and std.mem.eql(u8, self.outputs[0].name, "*");
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

pub const PassThroughPair = struct {
    input_concrete_idx: usize,
    output_concrete_idx: usize,
};

pub const PassThroughResult = struct {
    items: [8]PassThroughPair = undefined,
    len: usize = 0,

    pub fn slice(self: *const PassThroughResult) []const PassThroughPair {
        return self.items[0..self.len];
    }

    fn append(self: *PassThroughResult, pair: PassThroughPair) void {
        if (self.len < 8) {
            self.items[self.len] = pair;
            self.len += 1;
        }
    }
};

/// Identify pass-through parameters: concrete, non-quotation input params
/// whose name also appears as a concrete, non-quotation output param.
/// Returns pairs of (input_concrete_idx, output_concrete_idx).
pub fn passThroughParams(effect: StackEffect) PassThroughResult {
    var result = PassThroughResult{};

    var in_idx: usize = 0;
    for (effect.inputs) |in_param| {
        if (in_param.is_row_variable) continue;
        if (in_param.quotation_effect != null) {
            in_idx += 1;
            continue;
        }

        var out_idx: usize = 0;
        for (effect.outputs) |out_param| {
            if (out_param.is_row_variable) continue;
            if (out_param.quotation_effect != null) {
                out_idx += 1;
                continue;
            }
            if (std.mem.eql(u8, in_param.name, out_param.name)) {
                result.append(.{ .input_concrete_idx = in_idx, .output_concrete_idx = out_idx });
                break;
            }
            out_idx += 1;
        }

        in_idx += 1;
    }

    return result;
}

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

/// Slice-level form of `StackEffect.hasAlternativeOutput`, for callers holding
/// only the output params.
pub fn paramsHaveAlternativeOutput(params: []const StackEffectParam) bool {
    for (params) |param| {
        if (std.mem.eql(u8, param.name, "|")) return true;
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

test "hasAlternativeOutput" {
    // `( scanner -- new-scanner token | f )`: the `|` marker is a literal
    // output parameter, so the alternative is detected.
    const alt = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "scanner" }},
        .outputs = &[_]StackEffectParam{
            .{ .name = "new-scanner" },
            .{ .name = "token" },
            .{ .name = "|" },
            .{ .name = "f" },
        },
    };
    try std.testing.expect(alt.hasAlternativeOutput());

    // A concrete single-output effect has no alternative.
    const concrete = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "name" }},
        .outputs = &[_]StackEffectParam{.{ .name = "option" }},
    };
    try std.testing.expect(!concrete.hasAlternativeOutput());

    // A `|` only in the inputs does not count as an alternative output.
    const input_pipe = StackEffect{
        .inputs = &[_]StackEffectParam{ .{ .name = "x" }, .{ .name = "|" } },
        .outputs = &[_]StackEffectParam{.{ .name = "y" }},
    };
    try std.testing.expect(!input_pipe.hasAlternativeOutput());
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

test "passThroughParams for call (no pass-throughs)" {
    // call: ( ..a quot -- ..b )
    const call_effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "quot", .quotation_effect = &StackEffect{
                .inputs = &[_]StackEffectParam{.{ .name = "a" }},
                .outputs = &[_]StackEffectParam{.{ .name = "b" }},
            } },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..b", .is_row_variable = true },
        },
    };
    const result = passThroughParams(call_effect);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "passThroughParams for dip (one pass-through)" {
    // dip: ( ..a x quot -- ..b x )
    const dip_effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "x" },
            .{ .name = "quot", .quotation_effect = &StackEffect{
                .inputs = &[_]StackEffectParam{.{ .name = "a" }},
                .outputs = &[_]StackEffectParam{.{ .name = "b" }},
            } },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..b", .is_row_variable = true },
            .{ .name = "x" },
        },
    };
    const result = passThroughParams(dip_effect);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(usize, 0), result.slice()[0].input_concrete_idx);
    try std.testing.expectEqual(@as(usize, 0), result.slice()[0].output_concrete_idx);
}

test "type_annotation write format" {
    var tv = TypeValue{ .name = "fixnum", .descriptor = null };
    const param = StackEffectParam{ .name = "n", .type_annotation = .{ .type = &tv } };

    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try param.write(fbs.writer());
    try std.testing.expectEqualStrings("n: fixnum", fbs.getWritten());
}

test "type_annotation in full stack effect" {
    var tv = TypeValue{ .name = "fixnum", .descriptor = null };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "n", .type_annotation = .{ .type = &tv } },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "m", .type_annotation = .{ .type = &tv } },
        },
    };

    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try effect.write(fbs.writer());
    try std.testing.expectEqualStrings("( n: fixnum -- m: fixnum )", fbs.getWritten());
}

test "type_annotation equality" {
    var tv_a = TypeValue{ .name = "fixnum", .descriptor = null };
    var tv_b = TypeValue{ .name = "string", .descriptor = null };
    const a = StackEffectParam{ .name = "n", .type_annotation = .{ .type = &tv_a } };
    const b = StackEffectParam{ .name = "n", .type_annotation = .{ .type = &tv_a } };
    const c = StackEffectParam{ .name = "n", .type_annotation = .{ .type = &tv_b } };
    const d = StackEffectParam{ .name = "n" };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.eql(d));
    try std.testing.expect(!d.eql(a));
}

test "type_annotation parameterized type" {
    var tv = TypeValue{ .name = "array(fixnum)", .descriptor = null };
    const param = StackEffectParam{ .name = "arr", .type_annotation = .{ .type = &tv } };

    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try param.write(fbs.writer());
    try std.testing.expectEqualStrings("arr: array(fixnum)", fbs.getWritten());
}

test "type_annotation protocol write format" {
    const pd = ProtocolDescriptor{ .name = "comparable", .methods = &.{}, .protocol_id = 0 };
    const param = StackEffectParam{ .name = "n", .type_annotation = .{ .protocol = &pd } };

    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try param.write(fbs.writer());
    try std.testing.expectEqualStrings("n: comparable", fbs.getWritten());
}

test "type_annotation protocol equality" {
    const pd_a = ProtocolDescriptor{ .name = "comparable", .methods = &.{}, .protocol_id = 0 };
    const pd_b = ProtocolDescriptor{ .name = "stringable", .methods = &.{}, .protocol_id = 1 };
    var tv = TypeValue{ .name = "fixnum", .descriptor = null };

    const a = StackEffectParam{ .name = "n", .type_annotation = .{ .protocol = &pd_a } };
    const b = StackEffectParam{ .name = "n", .type_annotation = .{ .protocol = &pd_a } };
    const c = StackEffectParam{ .name = "n", .type_annotation = .{ .protocol = &pd_b } };
    const d = StackEffectParam{ .name = "n", .type_annotation = .{ .type = &tv } };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.eql(d));
    try std.testing.expect(!d.eql(a));
}

test "type_annotation combination write format" {
    const cc = ConstraintCombinator{ .kind = .intersection, .elements = &.{}, .combinator_id = 0 };
    const param = StackEffectParam{ .name = "n", .type_annotation = .{ .combination = &cc } };

    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try param.write(fbs.writer());
    try std.testing.expectEqualStrings("n: <constraint>", fbs.getWritten());
}

test "type_annotation combination equality" {
    const cc_a = ConstraintCombinator{ .kind = .intersection, .elements = &.{}, .combinator_id = 0 };
    const cc_b = ConstraintCombinator{ .kind = .@"union", .elements = &.{}, .combinator_id = 1 };
    const pd = ProtocolDescriptor{ .name = "comparable", .methods = &.{}, .protocol_id = 0 };
    var tv = TypeValue{ .name = "fixnum", .descriptor = null };

    const a = StackEffectParam{ .name = "n", .type_annotation = .{ .combination = &cc_a } };
    const b = StackEffectParam{ .name = "n", .type_annotation = .{ .combination = &cc_a } };
    const c = StackEffectParam{ .name = "n", .type_annotation = .{ .combination = &cc_b } };
    const d = StackEffectParam{ .name = "n", .type_annotation = .{ .protocol = &pd } };
    const e = StackEffectParam{ .name = "n", .type_annotation = .{ .type = &tv } };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.eql(d));
    try std.testing.expect(!d.eql(a));
    try std.testing.expect(!a.eql(e));
    try std.testing.expect(!e.eql(a));
}
