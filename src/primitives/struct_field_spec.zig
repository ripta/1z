const std = @import("std");
const Allocator = std.mem.Allocator;

const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const helpers = @import("helpers.zig");
const markers_mod = @import("markers.zig");

pub const ParsedStructFields = struct {
    names: []const []const u8,
    types: []const ?value_mod.ConstraintCombinator.Element = &.{},
};

pub fn parse(
    allocator: Allocator,
    ctx: *Context,
    values: []const Value,
    comptime owner: []const u8,
) !ParsedStructFields {
    var field_names = std.ArrayListUnmanaged([]const u8){};
    errdefer field_names.deinit(allocator);

    var field_types = std.ArrayListUnmanaged(?value_mod.ConstraintCombinator.Element){};
    errdefer field_types.deinit(allocator);

    var saw_typed = false;
    var saw_untyped = false;
    var i: usize = 0;
    while (i < values.len) {
        const raw = switch (values[i]) {
            .string => |s| s,
            .symbol => |s| s,
            .type_val => |tv| tv.name,
            .marker => |mk| mk.name,
            else => {
                helpers.setErrorContext(ctx, "{s} field name must be a string or symbol, got {s}", .{ owner, helpers.valueTypeName(values[i]) });
                return error.TypeMismatch;
            },
        };
        const is_typed_name = switch (values[i]) {
            .symbol => true,
            else => raw.len > 1 and raw[raw.len - 1] == ':',
        };

        if (is_typed_name) {
            if (i + 1 >= values.len) {
                helpers.setErrorContext(ctx, "{s} field '{s}' is missing a type annotation", .{ owner, raw });
                return error.ParseError;
            }
            const element: value_mod.ConstraintCombinator.Element = switch (values[i + 1]) {
                .type_val => |tv| .{ .type = tv },
                .protocol_descriptor => |pd| .{ .protocol = pd },
                .constraint_combinator => |cc| .{ .combinator = cc },
                .marker => |mk| blk: {
                    if (markers_mod.isAnyMarker(mk)) break :blk .{ .type = ctx.getAnyTypeSentinel() };
                    helpers.setErrorContext(ctx, "{s} field '{s}' only allows the `any` marker in type position", .{ owner, raw });
                    return error.InvalidArgument;
                },
                else => {
                    helpers.setErrorContext(ctx, "{s} field '{s}' expects a type or constraint after ':', got {s}", .{ owner, raw, helpers.valueTypeName(values[i + 1]) });
                    return error.TypeMismatch;
                },
            };
            if (saw_untyped) {
                helpers.setErrorContext(ctx, "{s} cannot mix typed and untyped fields", .{owner});
                return error.ParseError;
            }
            saw_typed = true;
            try field_names.append(allocator, if (values[i] == .symbol) raw else raw[0 .. raw.len - 1]);
            try field_types.append(allocator, element);
            i += 2;
            continue;
        }

        if (saw_typed) {
            helpers.setErrorContext(ctx, "{s} cannot mix typed and untyped fields", .{owner});
            return error.ParseError;
        }
        saw_untyped = true;
        try field_names.append(allocator, raw);
        i += 1;
    }

    return .{
        .names = try field_names.toOwnedSlice(allocator),
        .types = if (saw_typed) try field_types.toOwnedSlice(allocator) else &.{},
    };
}
