const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const VirtualType = value_mod.VirtualType;
const ByteArray = value_mod.ByteArray;
const Marker = value_mod.Marker;

const helpers = @import("../primitives/helpers.zig");
const markers_mod = @import("../primitives/markers.zig");
const virtual = @import("../primitives/virtual.zig");

const types_mod = @import("../primitives/types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;

const signature = @import("signature.zig");
const FfiTypeTag = signature.FfiTypeTag;
const dynamic = @import("dynamic.zig");
const c_ffi = dynamic.c_ffi;
const struct_layout = @import("struct_layout.zig");
const FfiStructLayout = struct_layout.FfiStructLayout;
const FfiStructField = struct_layout.FfiStructField;

pub const primitives = [_]Primitive{
    .{ .name = "define-ffi-struct", .stack_effect = "name: descriptor markers --", .doc = "Define an FFI struct layout type.", .func = nativeDefineFfiStruct },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "ffi-struct-make", .func = nativeFfiStructMake, .stack_effect = "fields... layout-ptr vtype-ptr -- tagged" },
};

/// define-ffi-struct ( name: descriptor markers -- )
///
/// Defines a FFI struct layout virtual type backed by a byte array.
///
/// The descriptor contains a `fields` key with a flat token list of `name: type` pairs parsed by `parse-tokens-until`.
fn nativeDefineFfiStruct(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const markers_val = try ctx.stack.pop();
    const markers_array = switch (markers_val) {
        .array => |arr| arr,
        else => {
            helpers.setTypeMismatchError(ctx, "array", markers_val);
            return error.TypeMismatch;
        },
    };

    var markers_list = std.ArrayListUnmanaged(*Marker){};
    for (markers_array) |m| {
        switch (m) {
            .marker => |mk| try markers_list.append(alloc, mk),
            else => {
                helpers.setTypeMismatchError(ctx, "marker", m);
                return error.TypeMismatch;
            },
        }
    }
    const markers_slice = try markers_list.toOwnedSlice(alloc);

    const desc_val = try ctx.stack.pop();
    const src_map: *value_mod.MutableMap = switch (desc_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable_map", desc_val);
            return error.TypeMismatch;
        },
    };

    const desc_map = try alloc.create(value_mod.MutableMap);
    desc_map.* = value_mod.MutableMap{};
    var src_iter = src_map.iterator();
    while (src_iter.next()) |entry| {
        try desc_map.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
    }

    const fields_val = desc_map.get("fields") orelse {
        helpers.setErrorContext(ctx, "ffi-struct{{ descriptor missing 'fields' key", .{});
        return error.MissingField;
    };
    const fields_array = switch (fields_val) {
        .array => |arr| arr,
        else => {
            helpers.setErrorContext(ctx, "ffi-struct{{ 'fields' must be an array", .{});
            return error.TypeMismatch;
        },
    };

    const name_val = try ctx.stack.pop();
    const name = switch (name_val) {
        .symbol => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol", name_val);
            return error.TypeMismatch;
        },
    };

    if (fields_array.len == 0 or fields_array.len % 2 != 0) {
        helpers.setErrorContext(ctx, "ffi-struct{{ expects pairs of (name: type), got {d} tokens", .{fields_array.len});
        return error.ParseError;
    }

    const num_fields = fields_array.len / 2;
    var field_names = try alloc.alloc([]const u8, num_fields);
    var field_type_tokens = try alloc.alloc([]const u8, num_fields);

    for (0..num_fields) |i| {
        const name_tok = switch (fields_array[i * 2]) {
            .string => |s| s,
            else => {
                helpers.setErrorContext(ctx, "ffi-struct{{ field name must be a string", .{});
                return error.TypeMismatch;
            },
        };

        if (name_tok.len > 1 and name_tok[name_tok.len - 1] == ':') {
            field_names[i] = name_tok[0 .. name_tok.len - 1];
        } else {
            field_names[i] = name_tok;
        }

        field_type_tokens[i] = switch (fields_array[i * 2 + 1]) {
            .string => |s| s,
            else => {
                helpers.setErrorContext(ctx, "ffi-struct{{ field type must be a string", .{});
                return error.TypeMismatch;
            },
        };
    }

    var ffi_tags = try alloc.alloc(?FfiTypeTag, num_fields);
    var nested_layouts = try alloc.alloc(?*const FfiStructLayout, num_fields);

    for (field_type_tokens, 0..) |token, i| {
        if (signature.parseTypeToken(token)) |ffi_type| {
            ffi_tags[i] = ffi_type.tag;
            nested_layouts[i] = null;
        } else |_| {
            const desc = ctx.lookupTypeDescriptor(token) orelse {
                helpers.setErrorContext(ctx, "ffi-struct{{ unknown field type: {s}", .{token});
                return error.FFITypeMismatch;
            };
            const layout_val = desc.get("ffi-layout") orelse {
                helpers.setErrorContext(ctx, "ffi-struct{{ type '{s}' is not an FFI struct", .{token});
                return error.FFITypeMismatch;
            };
            const layout_ptr = switch (layout_val) {
                .fixnum => |v| @as(*const FfiStructLayout, @ptrFromInt(@as(usize, @intCast(v)))),
                else => {
                    helpers.setErrorContext(ctx, "ffi-struct{{ invalid ffi-layout descriptor for '{s}'", .{token});
                    return error.FFITypeMismatch;
                },
            };
            ffi_tags[i] = null;
            nested_layouts[i] = layout_ptr;
        }
    }

    //  libffi ffi_type struct
    const ffi_struct_type = try alloc.create(c_ffi.ffi_type);
    const elements = try alloc.alloc([*c]c_ffi.ffi_type, num_fields + 1);
    for (0..num_fields) |i| {
        if (ffi_tags[i]) |tag| {
            elements[i] = dynamic.ffiTypeToLibffi(tag);
        } else if (nested_layouts[i]) |nl| {
            elements[i] = nl.ffi_type;
        } else {
            unreachable;
        }
    }
    elements[num_fields] = null; // null-terminated

    ffi_struct_type.* = .{
        .size = 0,
        .alignment = 0,
        .type = c_ffi.FFI_TYPE_STRUCT,
        .elements = elements.ptr,
    };

    // ffi_get_struct_offsets gets us offsets, size, and alignment
    const offsets = try alloc.alloc(usize, num_fields);
    const status = c_ffi.ffi_get_struct_offsets(
        c_ffi.FFI_DEFAULT_ABI,
        ffi_struct_type,
        @ptrCast(offsets.ptr),
    );
    if (status != c_ffi.FFI_OK) {
        helpers.setErrorContext(ctx, "ffi_get_struct_offsets failed (status {d})", .{status});
        return error.FFICallFailed;
    }

    const fields = try alloc.alloc(FfiStructField, num_fields);
    for (0..num_fields) |i| {
        const field_size = if (ffi_tags[i]) |tag|
            struct_layout.ffiTagToSize(tag)
        else if (nested_layouts[i]) |nl|
            nl.total_size
        else
            unreachable;

        fields[i] = .{
            .name = field_names[i],
            .type_token = field_type_tokens[i],
            .ffi_tag = ffi_tags[i],
            .nested_layout = nested_layouts[i],
            .offset = offsets[i],
            .size = field_size,
        };
    }

    const layout = try alloc.create(FfiStructLayout);
    layout.* = .{
        .fields = fields,
        .total_size = ffi_struct_type.size,
        .alignment = @intCast(ffi_struct_type.alignment),
        .ffi_type = ffi_struct_type,
        .elements = elements.ptr,
    };

    const vtype = try alloc.create(VirtualType);
    vtype.* = .{
        .name = name,
        .inner_type = "byte-array",
    };

    const tv = try alloc.create(value_mod.TypeValue);
    tv.* = .{ .name = name, .descriptor = null };
    vtype.type_val = tv;

    // Define NAME as parse-time const pushing TypeValue
    const type_markers = try alloc.alloc(*Marker, 3);
    type_markers[0] = @constCast(&markers_mod.parse_time_marker);
    type_markers[1] = @constCast(&markers_mod.const_marker);
    type_markers[2] = @constCast(&markers_mod.typed_marker);

    const type_instrs = try alloc.alloc(Instruction, 1);
    type_instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .parse_time = true,
        .stack_effect = try helpers.makeSimpleEffect(alloc, "-- type"),
        .markers = type_markers,
        .provenance = .{ .generator = "ffi-struct", .parent = name, .role = "type" },
        .action = .{ .compound = type_instrs },
    });

    // make-NAME: pushes layout ptr + vtype ptr, calls native.ffi-struct-make
    const make_name = try std.fmt.allocPrint(alloc, "make-{s}", .{name});
    const make_instrs = try alloc.alloc(Instruction, 3);
    make_instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(layout)) } }, .line = 0 };
    make_instrs[1] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    make_instrs[2] = .{ .op = .{ .call_word = "native.ffi-struct-make" }, .line = 0 };

    var effect_buf = std.ArrayListUnmanaged(u8){};
    for (fields) |f| {
        try effect_buf.appendSlice(alloc, f.name);
        try effect_buf.append(alloc, ' ');
    }
    try effect_buf.appendSlice(alloc, "-- ");
    try effect_buf.appendSlice(alloc, name);
    const effect_str = try effect_buf.toOwnedSlice(alloc);

    try ctx.defineWord(make_name, .{
        .name = make_name,
        .stack_effect = try helpers.makeSimpleEffect(alloc, effect_str),
        .markers = markers_slice,
        .provenance = .{ .generator = "ffi-struct", .parent = name, .role = "constructor" },
        .action = .{ .compound = make_instrs },
    });

    // NAME?: ( -- bool) predicate to check if TOS is this struct type
    const pred_name = try std.fmt.allocPrint(alloc, "{s}?", .{name});
    try virtual.definePredicate(ctx, pred_name, vtype, markers_slice);

    var generated_words = std.ArrayListUnmanaged(Value){};
    try generated_words.append(alloc, .{ .string = name });
    try generated_words.append(alloc, .{ .string = make_name });
    try generated_words.append(alloc, .{ .string = pred_name });
    const gw_slice = try generated_words.toOwnedSlice(alloc);
    try desc_map.put(alloc, "generated-words", .{ .array = gw_slice });

    try desc_map.put(alloc, "ffi-layout", .{ .fixnum = @intCast(@intFromPtr(layout)) });

    const frozen_desc: *value_mod.HashTable = @ptrCast(desc_map);
    try ctx.registerTypeDescriptor(name, frozen_desc);
    vtype.type_val.?.descriptor = frozen_desc;
}

/// ffi-struct-make ( field1..fieldN layout-ptr vtype-ptr -- tagged )
///
/// Constructs an FFI struct value by marshaling field values into a byte array.
fn nativeFfiStructMake(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const vtype_fixnum = try helpers.popFixnum(ctx);
    const vtype: *const VirtualType = @ptrFromInt(@as(usize, @intCast(vtype_fixnum)));

    const layout_fixnum = try helpers.popFixnum(ctx);
    const layout: *const FfiStructLayout = @ptrFromInt(@as(usize, @intCast(layout_fixnum)));

    const num_fields = layout.fields.len;

    // field values
    var field_vals = try alloc.alloc(Value, num_fields);
    var i: usize = num_fields;
    while (i > 0) {
        i -= 1;
        field_vals[i] = try ctx.stack.pop();
    }

    // zero-initialize byte array allocation of total_size
    const ba = try alloc.create(ByteArray);
    ba.* = ByteArray{};
    try ba.ensureTotalCapacity(alloc, layout.total_size);
    ba.items.len = layout.total_size;
    @memset(ba.items[0..layout.total_size], 0);

    for (layout.fields, 0..) |field, fi| {
        const val = field_vals[fi];
        const buf = ba.items[field.offset .. field.offset + field.size];

        if (field.nested_layout) |_| {
            const inner_ba = switch (val) {
                .tagged => |t| switch (t.inner.*) {
                    .byte_array => |b| b,
                    else => {
                        helpers.setErrorContext(ctx, "make-{s}: field '{s}' expected FFI struct, got {s}", .{ vtype.name, field.name, helpers.valueTypeName(t.inner.*) });
                        return error.TypeMismatch;
                    },
                },
                else => {
                    helpers.setErrorContext(ctx, "make-{s}: field '{s}' expected FFI struct, got {s}", .{ vtype.name, field.name, helpers.valueTypeName(val) });
                    return error.TypeMismatch;
                },
            };
            if (inner_ba.items.len != field.size) {
                helpers.setErrorContext(ctx, "make-{s}: field '{s}' size mismatch: expected {d}, got {d}", .{ vtype.name, field.name, field.size, inner_ba.items.len });
                return error.FFITypeMismatch;
            }
            @memcpy(buf, inner_ba.items[0..field.size]);
        } else if (field.ffi_tag) |tag| {
            try marshalFieldValue(ctx, vtype.name, field.name, tag, val, buf);
        }
    }

    const inner = try alloc.create(Value);
    inner.* = .{ .byte_array = ba };
    try ctx.stack.push(.{ .tagged = .{ .tag = vtype, .inner = inner } });
}

/// Marshal a single 1z value into a byte buffer at the appropriate size.
fn marshalFieldValue(ctx: *Context, struct_name: []const u8, field_name: []const u8, tag: FfiTypeTag, val: Value, buf: []u8) !void {
    switch (tag) {
        .i8 => {
            const v = try expectFixnum(ctx, struct_name, field_name, val);
            try checkFieldRange(ctx, struct_name, field_name, v, i8);
            std.mem.writeInt(i8, buf[0..1], @intCast(v), .little);
        },
        .i16 => {
            const v = try expectFixnum(ctx, struct_name, field_name, val);
            try checkFieldRange(ctx, struct_name, field_name, v, i16);
            std.mem.writeInt(i16, buf[0..2], @intCast(v), .little);
        },
        .i32 => {
            const v = try expectFixnum(ctx, struct_name, field_name, val);
            try checkFieldRange(ctx, struct_name, field_name, v, i32);
            std.mem.writeInt(i32, buf[0..4], @intCast(v), .little);
        },
        .i64 => {
            const v = try expectFixnum(ctx, struct_name, field_name, val);
            std.mem.writeInt(i64, buf[0..8], v, .little);
        },
        .u8 => {
            const v = try expectFixnum(ctx, struct_name, field_name, val);
            try checkFieldRange(ctx, struct_name, field_name, v, u8);
            std.mem.writeInt(u8, buf[0..1], @intCast(v), .little);
        },
        .u16 => {
            const v = try expectFixnum(ctx, struct_name, field_name, val);
            try checkFieldRange(ctx, struct_name, field_name, v, u16);
            std.mem.writeInt(u16, buf[0..2], @intCast(v), .little);
        },
        .u32 => {
            const v = try expectFixnum(ctx, struct_name, field_name, val);
            try checkFieldRange(ctx, struct_name, field_name, v, u32);
            std.mem.writeInt(u32, buf[0..4], @intCast(v), .little);
        },
        .u64 => {
            const v = try expectFixnum(ctx, struct_name, field_name, val);
            if (v < 0) {
                helpers.setErrorContext(ctx, "make-{s}: field '{s}' value {d} out of range for u64", .{ struct_name, field_name, v });
                return error.FFIRangeError;
            }
            std.mem.writeInt(u64, buf[0..8], @intCast(v), .little);
        },
        .f32 => {
            const f = try expectFloat(ctx, struct_name, field_name, val);
            const bits: u32 = @bitCast(@as(f32, @floatCast(f)));
            std.mem.writeInt(u32, buf[0..4], bits, .little);
        },
        .f64 => {
            const f = try expectFloat(ctx, struct_name, field_name, val);
            const bits: u64 = @bitCast(f);
            std.mem.writeInt(u64, buf[0..8], bits, .little);
        },
        .bool_type => {
            const b = switch (val) {
                .boolean => |v| v,
                else => {
                    helpers.setErrorContext(ctx, "make-{s}: field '{s}' expected boolean, got {s}", .{ struct_name, field_name, helpers.valueTypeName(val) });
                    return error.TypeMismatch;
                },
            };
            buf[0] = if (b) 1 else 0;
        },
        .usize_type => {
            const v = try expectFixnum(ctx, struct_name, field_name, val);
            if (v < 0) {
                helpers.setErrorContext(ctx, "make-{s}: field '{s}' value {d} out of range for usize", .{ struct_name, field_name, v });
                return error.FFIRangeError;
            }
            std.mem.writeInt(usize, buf[0..@sizeOf(usize)], @intCast(v), .little);
        },
        .isize_type => {
            const v = try expectFixnum(ctx, struct_name, field_name, val);
            std.mem.writeInt(isize, buf[0..@sizeOf(isize)], @intCast(v), .little);
        },
        else => {
            helpers.setErrorContext(ctx, "make-{s}: unsupported field type for '{s}'", .{ struct_name, field_name });
            return error.FFITypeMismatch;
        },
    }
}

fn expectFixnum(ctx: *Context, struct_name: []const u8, field_name: []const u8, val: Value) !i64 {
    return switch (val) {
        .fixnum => |v| v,
        else => {
            helpers.setErrorContext(ctx, "make-{s}: field '{s}' expected fixnum, got {s}", .{ struct_name, field_name, helpers.valueTypeName(val) });
            return error.TypeMismatch;
        },
    };
}

fn expectFloat(ctx: *Context, struct_name: []const u8, field_name: []const u8, val: Value) !f64 {
    return switch (val) {
        .float => |v| v,
        else => {
            helpers.setErrorContext(ctx, "make-{s}: field '{s}' expected float, got {s}", .{ struct_name, field_name, helpers.valueTypeName(val) });
            return error.TypeMismatch;
        },
    };
}

fn checkFieldRange(ctx: *Context, struct_name: []const u8, field_name: []const u8, fixnum: i64, comptime T: type) !void {
    if (fixnum < std.math.minInt(T) or fixnum > std.math.maxInt(T)) {
        helpers.setErrorContext(ctx, "make-{s}: field '{s}' value {d} out of range for {s}", .{ struct_name, field_name, fixnum, @typeName(T) });
        return error.FFIRangeError;
    }
}
