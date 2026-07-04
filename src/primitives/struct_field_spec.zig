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

    // Per-definition map from a type-parameter symbol to its minted TypeValue.
    // The first sight of a symbol in a type slot mints a fresh parameter at the
    // next position; a repeat reuses it (shared constraint). The map is local to
    // this call, so `T:` in one definition is independent of `T:` in another.
    var type_params = std.StringHashMapUnmanaged(*const value_mod.TypeValue){};
    defer type_params.deinit(allocator);
    var next_param_pos: u32 = 0;

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
                .symbol => |s| blk: {
                    if (type_params.get(s)) |existing| break :blk .{ .type = existing };
                    const param_tv = try value_mod.mintTypeParameter(allocator, s, next_param_pos);
                    next_param_pos += 1;
                    try type_params.put(allocator, s, param_tv);
                    break :blk .{ .type = param_tv };
                },
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

const testing = std.testing;

test "type-parameter symbols in the type slot mint per-position parameters" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // struct{ id: T: age: U: }
    const values = [_]Value{
        .{ .symbol = "id" },  .{ .symbol = "T" },
        .{ .symbol = "age" }, .{ .symbol = "U" },
    };
    const parsed = try parse(alloc, &ctx, &values, "struct{");

    try testing.expectEqual(@as(usize, 2), parsed.names.len);
    try testing.expectEqualStrings("id", parsed.names[0]);
    try testing.expectEqualStrings("age", parsed.names[1]);

    const t0 = parsed.types[0].?.type;
    const t1 = parsed.types[1].?.type;
    try testing.expect(value_mod.isTypeParameter(t0));
    try testing.expect(value_mod.isTypeParameter(t1));
    try testing.expect(t0 != t1);
    try testing.expectEqual(@as(?u32, 0), value_mod.typeParameterPosition(t0));
    try testing.expectEqual(@as(?u32, 1), value_mod.typeParameterPosition(t1));
    try testing.expectEqualStrings("T", t0.name);
    try testing.expectEqualStrings("U", t1.name);
}

test "a repeated type-parameter symbol is shared across fields" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // struct{ first: T: second: T: }
    const values = [_]Value{
        .{ .symbol = "first" },  .{ .symbol = "T" },
        .{ .symbol = "second" }, .{ .symbol = "T" },
    };
    const parsed = try parse(alloc, &ctx, &values, "struct{");

    const t0 = parsed.types[0].?.type;
    const t1 = parsed.types[1].?.type;
    try testing.expect(value_mod.isTypeParameter(t0));
    // Same symbol within one definition reuses one minted parameter.
    try testing.expect(t0 == t1);
    try testing.expectEqual(@as(?u32, 0), value_mod.typeParameterPosition(t0));
}

test "same-spelled type parameters are independent across definitions" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const values_a = [_]Value{ .{ .symbol = "x" }, .{ .symbol = "T" } };
    const values_b = [_]Value{ .{ .symbol = "y" }, .{ .symbol = "T" } };
    const parsed_a = try parse(alloc, &ctx, &values_a, "struct{");
    const parsed_b = try parse(alloc, &ctx, &values_b, "struct{");

    const ta = parsed_a.types[0].?.type;
    const tb = parsed_b.types[0].?.type;
    try testing.expect(value_mod.isTypeParameter(ta));
    try testing.expect(value_mod.isTypeParameter(tb));
    // Distinct definitions mint distinct parameters even for the same spelling.
    try testing.expect(ta != tb);
}

test "struct descriptor projects declared type parameters in position order" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // struct{ id: T: age: U: first: T: } -- T shared by two slots, U once.
    const values = [_]Value{
        .{ .symbol = "id" },    .{ .symbol = "T" },
        .{ .symbol = "age" },   .{ .symbol = "U" },
        .{ .symbol = "first" }, .{ .symbol = "T" },
    };
    const parsed = try parse(alloc, &ctx, &values, "struct{");

    const desc = try ctx.getOrCreateStructDescriptor(parsed.names, parsed.types, false);
    const params = desc.kind.struct_.type_params;
    try testing.expectEqual(@as(usize, 2), params.len);
    try testing.expectEqualStrings("T", params[0].name);
    try testing.expectEqualStrings("U", params[1].name);
    try testing.expectEqual(@as(?u32, 0), value_mod.typeParameterPosition(params[0]));
    try testing.expectEqual(@as(?u32, 1), value_mod.typeParameterPosition(params[1]));
    // The projection reuses the exact parameter pointers from the field slots.
    try testing.expect(params[0] == parsed.types[0].?.type);
    try testing.expect(params[0] == parsed.types[2].?.type);
}
