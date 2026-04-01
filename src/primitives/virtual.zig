const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const VirtualType = value_mod.VirtualType;
const Marker = value_mod.Marker;
const MutableMap = value_mod.MutableMap;

const helpers = @import("helpers.zig");

const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "define-virtual", .stack_effect = "name: descriptor markers --", .func = nativeDefineVirtual },
    .{ .name = "parse-virtual-inner", .stack_effect = "-- inner-type", .func = nativeParseVirtualInner },
};

/// parse-virtual-inner ( -- inner-type ) - Parse inner type name until } from tokenizer
fn nativeParseVirtualInner(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer orelse return error.NoTokenizerAvailable;
    const alloc = ctx.quotationAllocator();

    var inner_type: ?[]const u8 = null;

    while (tokenizer.next()) |tok| {
        if (tok.kind == .comment or tok.kind == .doc_comment or tok.kind == .newline) continue;

        const token = tok.text;
        if (std.mem.eql(u8, token, "}")) {
            break;
        }

        if (inner_type != null) {
            helpers.setErrorContext(ctx, "virtual{{ expects exactly one inner type name before }}", .{});
            return error.ParseError;
        }

        inner_type = try alloc.dupe(u8, token);
    }

    if (inner_type) |it| {
        try ctx.stack.push(.{ .string = it });
    } else {
        helpers.setErrorContext(ctx, "virtual{{ expects an inner type name", .{});
        return error.ParseError;
    }
}

/// define-virtual ( name: descriptor markers -- ) - Define a virtual type and its accessor words
///
/// Creates: >NAME (wrap), NAME> (unwrap), NAME? (predicate)
fn nativeDefineVirtual(ctx: *Context) anyerror!void {
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

    // Extract inner-type from descriptor map
    const desc_val = try ctx.stack.pop();
    const desc_map: *MutableMap = switch (desc_val) {
        .mutable_map => |m| m,
        else => return error.TypeMismatch,
    };
    const inner_type_val = desc_map.get("inner-type") orelse return error.MissingField;
    const inner_type = switch (inner_type_val) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const name_val = try ctx.stack.pop();
    const name = switch (name_val) {
        .symbol => |s| s,
        else => return error.TypeMismatch,
    };

    // Allocate singleton VirtualType shared by all instances
    const vtype = try alloc.create(VirtualType);
    vtype.* = .{
        .name = name,
        .inner_type = inner_type,
    };

    // >NAME: ( value -- tagged ) - wrap
    const wrap_name = try std.fmt.allocPrint(alloc, ">{s}", .{name});
    try defineWrap(ctx, wrap_name, vtype, markers_slice);

    // NAME>: ( tagged -- value ) - unwrap
    const unwrap_name = try std.fmt.allocPrint(alloc, "{s}>", .{name});
    try defineUnwrap(ctx, unwrap_name, vtype, markers_slice);

    // NAME?: ( value -- bool ) - predicate
    const pred_name = try std.fmt.allocPrint(alloc, "{s}?", .{name});
    try definePredicate(ctx, pred_name, vtype, markers_slice);
}

/// Trampoline helper ( value vtype-ptr -- tagged )
fn virtualWrapHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const ptr_val = try helpers.popInteger(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    const val = try ctx.stack.pop();

    const inner = try alloc.create(Value);
    inner.* = val;

    try ctx.stack.push(.{ .tagged = .{ .tag = vt, .inner = inner } });
}

/// Trampoline helper ( tagged vtype-ptr -- value )
fn virtualUnwrapHelper(ctx: *Context) anyerror!void {
    const ptr_val = try helpers.popInteger(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    const val = try ctx.stack.pop();
    switch (val) {
        .tagged => |t| {
            if (t.tag == vt) {
                try ctx.stack.push(t.inner.*);
            } else {
                helpers.setErrorContext(ctx, "expected {s}, got {s}", .{ vt.name, t.tag.name });
                return error.TypeMismatch;
            }
        },
        else => {
            helpers.setErrorContext(ctx, "expected {s}, got {s}", .{ vt.name, helpers.valueTypeName(val) });
            return error.TypeMismatch;
        },
    }
}

/// Trampoline helper ( value vtype-ptr -- ? )
fn virtualTypePredicateHelper(ctx: *Context) anyerror!void {
    const ptr_val = try helpers.popInteger(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    const val = try ctx.stack.pop();
    const is_match = switch (val) {
        .tagged => |t| t.tag == vt,
        else => false,
    };

    try ctx.stack.push(.{ .boolean = is_match });
}

/// >NAME: ( value -- tagged ) - wrap a value as this virtual type
fn defineWrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(&virtualWrapHelper)) } }, .line = 0 };
    instrs[2] = .{ .op = .{ .call_word = "(trampoline)" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .action = .{ .compound = instrs },
    });
}

/// NAME>: ( tagged -- value ) - unwrap a tagged value, validating the type
fn defineUnwrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(&virtualUnwrapHelper)) } }, .line = 0 };
    instrs[2] = .{ .op = .{ .call_word = "(trampoline)" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .action = .{ .compound = instrs },
    });
}

/// NAME?: ( value -- bool ) - type predicate for virtual type
fn definePredicate(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(&virtualTypePredicateHelper)) } }, .line = 0 };
    instrs[2] = .{ .op = .{ .call_word = "(trampoline)" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .action = .{ .compound = instrs },
    });
}
