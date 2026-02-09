const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const VirtualType = value_mod.VirtualType;
const StructType = value_mod.StructType;
const StructInstance = value_mod.StructInstance;
const Marker = value_mod.Marker;
const MutableMap = value_mod.MutableMap;

const helpers = @import("helpers.zig");

const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "define-virtual", .stack_effect = "name: descriptor markers --", .doc = "Define a virtual type and its accessor words.", .func = nativeDefineVirtual },
    .{ .name = "parse-virtual-inner", .stack_effect = "-- inner-type", .doc = "Parse inner type name until } from tokenizer.", .func = nativeParseVirtualInner },
};

/// parse-virtual-inner ( -- inner-type ) - Parse inner type name until } from tokenizer
///
/// Reads the next non-comment token. If it is a parse-time word (e.g. `struct{`),
/// execute it -- it will consume its own tokens including its own `}` -- then pop
/// its result from the stack. Otherwise treat it as a type name string. After the
/// inner value is obtained, consume the outer `}` for `virtual{`.
fn nativeParseVirtualInner(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer orelse return error.NoTokenizerAvailable;
    const alloc = ctx.quotationAllocator();

    var got_inner = false;

    while (tokenizer.next()) |tok| {
        if (tok.kind == .comment or tok.kind == .doc_comment or tok.kind == .newline) continue;

        const token = tok.text;
        if (std.mem.eql(u8, token, "}")) {
            break;
        }

        if (got_inner) {
            helpers.setErrorContext(ctx, "virtual{{ expects exactly one inner type before }}", .{});
            return error.ParseError;
        }

        if (ctx.lookupWord(token)) |word| {
            if (word.parse_time) {
                switch (word.action) {
                    .native => |func| try func(ctx),
                    .compound => |instrs| try ctx.executeQuotation(.{ .instructions = instrs }),
                }
                got_inner = true;
                continue;
            }
        }

        try ctx.stack.push(.{ .string = try alloc.dupe(u8, token) });
        got_inner = true;
    }

    if (!got_inner) {
        helpers.setErrorContext(ctx, "virtual{{ expects an inner type name", .{});
        return error.ParseError;
    }
}

/// define-virtual ( name: descriptor markers -- ) - Define a virtual type and its accessor words
///
/// Generates: >NAME (wrap), NAME> (unwrap), NAME? (predicate)
///
/// When inner-type is a string, creates a simple virtual type wrapping that type.
/// When inner-type is a mutable map (struct descriptor from `struct{`), creates a
/// struct-backed virtual type with positional wrap and destructuring unwrap.
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

    const name_val = try ctx.stack.pop();
    const name = switch (name_val) {
        .symbol => |s| s,
        else => return error.TypeMismatch,
    };

    switch (inner_type_val) {
        .string => |inner_type| {
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
        },
        .mutable_map => |struct_desc| {
            const fields_val = struct_desc.get("fields") orelse return error.MissingField;
            const fields_array = switch (fields_val) {
                .array => |arr| arr,
                else => return error.TypeMismatch,
            };

            var fields_list = std.ArrayListUnmanaged([]const u8){};
            for (fields_array) |f| {
                switch (f) {
                    .symbol => |s| try fields_list.append(alloc, s),
                    else => return error.TypeMismatch,
                }
            }
            const fields_slice = try fields_list.toOwnedSlice(alloc);

            const anon_struct = try alloc.create(StructType);
            anon_struct.* = .{
                .name = name,
                .fields = fields_slice,
            };

            const vtype = try alloc.create(VirtualType);
            vtype.* = .{
                .name = name,
                .inner_type = name,
                .anon_struct = anon_struct,
            };

            const wrap_name = try std.fmt.allocPrint(alloc, ">{s}", .{name});
            try defineStructWrap(ctx, wrap_name, vtype, markers_slice);

            const unwrap_name = try std.fmt.allocPrint(alloc, "{s}>", .{name});
            try defineStructUnwrap(ctx, unwrap_name, vtype, markers_slice);

            const pred_name = try std.fmt.allocPrint(alloc, "{s}?", .{name});
            try definePredicate(ctx, pred_name, vtype, markers_slice);
        },
        else => return error.TypeMismatch,
    }
}

/// Trampoline helper ( value vtype-ptr -- tagged )
///
/// Given a value, wraps it as a tagged virtual type instance.
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
///
/// Given a tagged virtual type instance, unwraps and validates its type.
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
///
/// Given a value, checks if it is a tagged instance of the given virtual type.
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
pub fn definePredicate(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
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

/// Trampoline helper ( field1..fieldN vtype-ptr -- tagged )
fn virtualStructWrapHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const ptr_val = try helpers.popInteger(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    const st = vt.anon_struct orelse return error.TypeMismatch;
    const num_fields = st.fields.len;

    const field_values = try alloc.alloc(Value, num_fields);
    var i: usize = num_fields;
    while (i > 0) {
        i -= 1;
        field_values[i] = try ctx.stack.pop();
    }

    const instance = try alloc.create(StructInstance);
    instance.* = .{
        .struct_type = st,
        .fields = field_values,
    };

    const inner = try alloc.create(Value);
    inner.* = .{ .struct_instance = instance };

    try ctx.stack.push(.{ .tagged = .{ .tag = vt, .inner = inner } });
}

/// Trampoline helper ( tagged vtype-ptr -- field1..fieldN )
fn virtualStructUnwrapHelper(ctx: *Context) anyerror!void {
    const ptr_val = try helpers.popInteger(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    const val = try ctx.stack.pop();
    switch (val) {
        .tagged => |t| {
            if (t.tag != vt) {
                helpers.setErrorContext(ctx, "expected {s}, got {s}", .{ vt.name, t.tag.name });
                return error.TypeMismatch;
            }
            switch (t.inner.*) {
                .struct_instance => |si| {
                    for (si.fields) |field_val| {
                        try ctx.stack.push(field_val);
                    }
                },
                else => {
                    helpers.setErrorContext(ctx, "expected struct-backed {s}", .{vt.name});
                    return error.TypeMismatch;
                },
            }
        },
        else => {
            helpers.setErrorContext(ctx, "expected {s}, got {s}", .{ vt.name, helpers.valueTypeName(val) });
            return error.TypeMismatch;
        },
    }
}

/// >NAME: ( field1..fieldN -- tagged ) - struct-aware positional wrap
fn defineStructWrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(&virtualStructWrapHelper)) } }, .line = 0 };
    instrs[2] = .{ .op = .{ .call_word = "(trampoline)" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .action = .{ .compound = instrs },
    });
}

/// NAME>: ( tagged -- field1..fieldN ) - struct-aware destructuring unwrap
fn defineStructUnwrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(&virtualStructUnwrapHelper)) } }, .line = 0 };
    instrs[2] = .{ .op = .{ .call_word = "(trampoline)" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .action = .{ .compound = instrs },
    });
}
