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
        if (tok.kind == .comment or tok.kind == .newline) continue;

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

/// >NAME: ( value -- tagged ) - wrap a value as this virtual type
fn defineWrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "__virtual-wrap" }, .line = 0 };

    try ctx.dictionary.put(name, .{
        .name = name,
        .markers = markers,
        .action = .{ .compound = instrs },
    });

    if (ctx.dictionary.get("__virtual-wrap") == null) {
        try ctx.dictionary.put("__virtual-wrap", .{
            .name = "__virtual-wrap",
            .action = .{
                .native = struct {
                    fn helper(c: *Context) anyerror!void {
                        const a = c.quotationAllocator();

                        const ptr_val = try helpers.popInteger(c);
                        const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

                        const val = try c.stack.pop();

                        const inner = try a.create(Value);
                        inner.* = val;

                        try c.stack.push(.{ .tagged = .{ .tag = vt, .inner = inner } });
                    }
                }.helper,
            },
        });
    }
}

/// NAME>: ( tagged -- value ) - unwrap a tagged value, validating the type
fn defineUnwrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "__virtual-unwrap" }, .line = 0 };

    try ctx.dictionary.put(name, .{
        .name = name,
        .markers = markers,
        .action = .{ .compound = instrs },
    });

    if (ctx.dictionary.get("__virtual-unwrap") == null) {
        try ctx.dictionary.put("__virtual-unwrap", .{
            .name = "__virtual-unwrap",
            .action = .{
                .native = struct {
                    fn helper(c: *Context) anyerror!void {
                        const ptr_val = try helpers.popInteger(c);
                        const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

                        const val = try c.stack.pop();
                        switch (val) {
                            .tagged => |t| {
                                if (t.tag == vt) {
                                    try c.stack.push(t.inner.*);
                                } else {
                                    helpers.setErrorContext(c, "expected {s}, got {s}", .{ vt.name, t.tag.name });
                                    return error.TypeMismatch;
                                }
                            },
                            else => {
                                helpers.setErrorContext(c, "expected {s}, got {s}", .{ vt.name, helpers.valueTypeName(val) });
                                return error.TypeMismatch;
                            },
                        }
                    }
                }.helper,
            },
        });
    }
}

/// NAME?: ( value -- bool ) - type predicate for virtual type
fn definePredicate(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "__virtual-type?" }, .line = 0 };

    try ctx.dictionary.put(name, .{
        .name = name,
        .markers = markers,
        .action = .{ .compound = instrs },
    });

    if (ctx.dictionary.get("__virtual-type?") == null) {
        try ctx.dictionary.put("__virtual-type?", .{
            .name = "__virtual-type?",
            .action = .{
                .native = struct {
                    fn helper(c: *Context) anyerror!void {
                        const ptr_val = try helpers.popInteger(c);
                        const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

                        const val = try c.stack.pop();
                        const is_match = switch (val) {
                            .tagged => |t| t.tag == vt,
                            else => false,
                        };

                        try c.stack.push(.{ .boolean = is_match });
                    }
                }.helper,
            },
        });
    }
}
