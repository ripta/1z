const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const VirtualType = value_mod.VirtualType;
const Marker = value_mod.Marker;

const helpers = @import("helpers.zig");
const virtual = @import("virtual.zig");

const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "define-enum", .stack_effect = "name: descriptor markers --", .doc = "Define an enum type with flat variant constructors and predicates.", .func = nativeDefineEnum },
};

/// define-enum ( name: descriptor markers -- )
///
/// For each variant string in the descriptor's `variants` array, creates a
/// virtual type wrapping a symbol, defines a constant constructor and a
/// per-variant predicate. Also defines an aggregate predicate that matches
/// any variant of the enum.
fn nativeDefineEnum(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const markers_val = try ctx.stack.pop();
    const markers_array = switch (markers_val) {
        .array => |arr| arr,
        else => return error.TypeMismatch,
    };

    var markers_list = std.ArrayListUnmanaged(*Marker){};
    for (markers_array) |m| {
        switch (m) {
            .marker => |mk| try markers_list.append(alloc, mk),
            else => return error.TypeMismatch,
        }
    }
    const markers_slice = try markers_list.toOwnedSlice(alloc);

    const desc_val = try ctx.stack.pop();
    const desc_map = switch (desc_val) {
        .mutable_map => |m| m,
        else => return error.TypeMismatch,
    };
    const variants_val = desc_map.get("variants") orelse {
        helpers.setErrorContext(ctx, "enum descriptor missing variants key", .{});
        return error.MissingField;
    };
    const variants_array = switch (variants_val) {
        .array => |arr| arr,
        else => return error.TypeMismatch,
    };

    const name_val = try ctx.stack.pop();
    const enum_name = switch (name_val) {
        .symbol => |s| s,
        else => return error.TypeMismatch,
    };

    var vtype_list = std.ArrayListUnmanaged(*const VirtualType){};

    for (variants_array) |variant_val| {
        const variant_sym = switch (variant_val) {
            .string => |s| s,
            else => return error.TypeMismatch,
        };

        const full_name = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ enum_name, variant_sym });

        const vtype = try alloc.create(VirtualType);
        vtype.* = .{
            .name = full_name,
            .inner_type = "symbol",
            .enum_name = enum_name,
        };

        try vtype_list.append(alloc, vtype);

        // Constant constructor
        const inner = try alloc.create(Value);
        inner.* = .{ .symbol = variant_sym };

        const instrs = try alloc.alloc(Instruction, 1);
        instrs[0] = .{ .op = .{ .push_literal = .{ .tagged = .{ .tag = vtype, .inner = inner } } }, .line = 0 };

        try ctx.defineWord(full_name, .{
            .name = full_name,
            .markers = markers_slice,
            .action = .{ .compound = instrs },
        });

        // Per-variant predicate thru shared virtual type machinery
        const pred_name = try std.fmt.allocPrint(alloc, "{s}:{s}?", .{ enum_name, variant_sym });
        try virtual.definePredicate(ctx, pred_name, vtype, markers_slice);
    }

    // Aggregate predicate
    const agg_pred_name = try std.fmt.allocPrint(alloc, "{s}?", .{enum_name});
    const enum_name_str = try alloc.dupe(u8, enum_name);

    const agg_instrs = try alloc.alloc(Instruction, 3);
    agg_instrs[0] = .{ .op = .{ .push_literal = .{ .string = enum_name_str } }, .line = 0 };
    agg_instrs[1] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(&enumAggregatePredicateHelper)) } }, .line = 0 };
    agg_instrs[2] = .{ .op = .{ .call_word = "(trampoline)" }, .line = 0 };

    try ctx.defineWord(agg_pred_name, .{
        .name = agg_pred_name,
        .markers = markers_slice,
        .action = .{ .compound = agg_instrs },
    });

    const vtypes_slice = try vtype_list.toOwnedSlice(alloc);
    try ctx.enum_registry.put(ctx.allocator, enum_name, vtypes_slice);
}

/// Trampoline helper ( value enum-name-string -- bool )
///
/// Checks whether the value is a tagged virtual type whose enum_name matches
/// the given enum name string.
fn enumAggregatePredicateHelper(ctx: *Context) anyerror!void {
    const name_val = try ctx.stack.pop();
    const enum_name = switch (name_val) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const val = try ctx.stack.pop();
    const is_match = switch (val) {
        .tagged => |t| if (t.tag.enum_name) |en| std.mem.eql(u8, en, enum_name) else false,
        else => false,
    };

    try ctx.stack.push(.{ .boolean = is_match });
}
