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
const markers_mod = @import("markers.zig");
const dispatch_mod = @import("../dispatch.zig");

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;

const dictionary_mod = @import("../dictionary.zig");
const WordProvenance = dictionary_mod.WordProvenance;
const WordDefinition = dictionary_mod.WordDefinition;

pub const primitives = [_]Primitive{
    .{ .name = "define-virtual", .stack_effect = "name: descriptor markers --", .doc = "Define a virtual type and its accessor words.", .func = nativeDefineVirtual },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "virtual-wrap", .func = virtualWrapHelper },
    .{ .name = "virtual-unwrap", .func = virtualUnwrapHelper },
    .{ .name = "virtual-type-predicate", .func = virtualTypePredicateHelper },
    .{ .name = "virtual-struct-wrap", .func = virtualStructWrapHelper },
    .{ .name = "virtual-struct-unwrap", .func = virtualStructUnwrapHelper },
    .{ .name = "virtual-struct-to-hash", .func = virtualStructToHashHelper },
    .{ .name = "virtual-struct-hash-wrap", .func = virtualStructHashWrapHelper },
};

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

    // Extract inner-type from descriptor map
    const desc_val = try ctx.stack.pop();
    const desc_map: *MutableMap = switch (desc_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable_map", desc_val);
            return error.TypeMismatch;
        },
    };
    const inner_type_raw = desc_map.get("inner-type") orelse return error.MissingField;
    const inner_type_val = switch (inner_type_raw) {
        .array => |arr| blk: {
            if (arr.len != 1) {
                helpers.setErrorContext(ctx, "virtual{{ expects exactly one inner type, got {d}", .{arr.len});
                return error.ParseError;
            }
            break :blk arr[0];
        },
        else => inner_type_raw,
    };

    const name_val = try ctx.stack.pop();
    const name = switch (name_val) {
        .symbol => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol", name_val);
            return error.TypeMismatch;
        },
    };

    switch (inner_type_val) {
        .string => |inner_type| {
            // Allocate singleton VirtualType shared by all instances
            const vtype = try alloc.create(VirtualType);
            vtype.* = .{
                .name = name,
                .inner_type = inner_type,
            };

            // >NAME / make-NAME: ( value -- tagged ) - wrap
            const wrap_name = try std.fmt.allocPrint(alloc, ">{s}", .{name});
            try defineWrap(ctx, wrap_name, vtype, markers_slice);

            const make_name = try std.fmt.allocPrint(alloc, "make-{s}", .{name});
            try defineWrap(ctx, make_name, vtype, markers_slice);

            // unmake-NAME: ( tagged -- value ) - unwrap
            const unmake_name = try std.fmt.allocPrint(alloc, "unmake-{s}", .{name});
            try defineUnwrap(ctx, unmake_name, vtype, markers_slice);

            // NAME?: ( value -- bool ) - predicate
            const pred_name = try std.fmt.allocPrint(alloc, "{s}?", .{name});
            try definePredicate(ctx, pred_name, vtype, markers_slice);
        },
        .mutable_map => |struct_desc| {
            const fields_val = struct_desc.get("fields") orelse return error.MissingField;
            const fields_array = switch (fields_val) {
                .array => |arr| arr,
                else => {
                    helpers.setErrorContext(ctx, "virtual{{ struct descriptor 'fields' must be an array, got {s}", .{helpers.valueTypeName(fields_val)});
                    return error.TypeMismatch;
                },
            };

            var fields_list = std.ArrayListUnmanaged([]const u8){};
            for (fields_array) |f| {
                const raw = switch (f) {
                    .string => |s| s,
                    .symbol => |s| s,
                    else => {
                        helpers.setErrorContext(ctx, "virtual{{ struct field name must be a string or symbol, got {s}", .{helpers.valueTypeName(f)});
                        return error.TypeMismatch;
                    },
                };
                const field_name = if (raw.len > 1 and raw[raw.len - 1] == ':')
                    raw[0 .. raw.len - 1]
                else
                    raw;
                try fields_list.append(alloc, field_name);
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

            // >NAME: ( hash -- tagged ) - hash-based wrap
            const wrap_name = try std.fmt.allocPrint(alloc, ">{s}", .{name});
            try defineStructHashWrap(ctx, wrap_name, vtype, markers_slice);

            // make-NAME: ( field1..fieldN -- tagged ) - positional wrap
            const make_name = try std.fmt.allocPrint(alloc, "make-{s}", .{name});
            try defineStructWrap(ctx, make_name, vtype, markers_slice);

            // unmake-NAME: ( tagged -- field1..fieldN ) - destructuring unwrap
            const unmake_name = try std.fmt.allocPrint(alloc, "unmake-{s}", .{name});
            try defineStructUnwrap(ctx, unmake_name, vtype, markers_slice);

            const to_hash_name = try std.fmt.allocPrint(alloc, "{s}>hash", .{name});
            try defineVirtualToHash(ctx, to_hash_name, vtype, markers_slice);

            const hash_instrs = try alloc.alloc(Instruction, 2);
            hash_instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
            hash_instrs[1] = .{ .op = .{ .call_word = "native.virtual-struct-to-hash" }, .line = 0 };
            try registerHashDispatch(ctx, name, hash_instrs);

            const pred_name = try std.fmt.allocPrint(alloc, "{s}?", .{name});
            try definePredicate(ctx, pred_name, vtype, markers_slice);
        },
        else => {
            helpers.setErrorContext(ctx, "virtual{{ inner type must be a string or struct descriptor, got {s}", .{helpers.valueTypeName(inner_type_val)});
            return error.TypeMismatch;
        },
    }
}

/// Trampoline helper ( value vtype-ptr -- tagged )
///
/// Given a value, wraps it as a tagged virtual type instance.
fn virtualWrapHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const ptr_val = try helpers.popFixnum(ctx);
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
    const ptr_val = try helpers.popFixnum(ctx);
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
    const ptr_val = try helpers.popFixnum(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    const val = try ctx.stack.pop();
    const is_match = switch (val) {
        .tagged => |t| t.tag == vt,
        else => false,
    };

    try ctx.stack.push(.{ .boolean = is_match });
}

fn vtypeProvenance(vtype: *const VirtualType, role: []const u8) WordProvenance {
    return .{
        .generator = if (vtype.enum_name != null) "enum" else "virtual",
        .parent = if (vtype.enum_name) |en| en else vtype.name,
        .role = role,
    };
}

/// >NAME: ( value -- tagged ) - wrap a value as this virtual type
pub fn defineWrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.virtual-wrap" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .provenance = vtypeProvenance(vtype, "wrap"),
        .action = .{ .compound = instrs },
    });
}

/// NAME>: ( tagged -- value ) - unwrap a tagged value, validating the type
pub fn defineUnwrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.virtual-unwrap" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .provenance = vtypeProvenance(vtype, "unwrap"),
        .action = .{ .compound = instrs },
    });
}

/// NAME?: ( value -- bool ) - type predicate for virtual type
pub fn definePredicate(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.virtual-type-predicate" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .provenance = vtypeProvenance(vtype, "predicate"),
        .action = .{ .compound = instrs },
    });
}

/// Trampoline helper ( field1..fieldN vtype-ptr -- tagged )
fn virtualStructWrapHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const ptr_val = try helpers.popFixnum(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    const st = vt.anon_struct orelse {
        helpers.setErrorContext(ctx, "{s} is not a struct-backed virtual type", .{vt.name});
        return error.TypeMismatch;
    };
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
    const ptr_val = try helpers.popFixnum(ctx);
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

/// Trampoline helper ( tagged vtype-ptr -- hash )
///
/// Validates the tag, unwraps to struct instance, converts fields to a hash.
fn virtualStructToHashHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const ptr_val = try helpers.popFixnum(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    const st = vt.anon_struct orelse {
        helpers.setErrorContext(ctx, "{s} is not a struct-backed virtual type", .{vt.name});
        return error.TypeMismatch;
    };

    const val = try ctx.stack.pop();
    switch (val) {
        .tagged => |t| {
            if (t.tag != vt) {
                helpers.setErrorContext(ctx, "expected {s}, got {s}", .{ vt.name, t.tag.name });
                return error.TypeMismatch;
            }
            switch (t.inner.*) {
                .struct_instance => |si| {
                    const hash = try alloc.create(value_mod.HashTable);
                    hash.* = .{};
                    for (st.fields, 0..) |field, i| {
                        try hash.put(alloc, field, si.fields[i]);
                    }
                    try ctx.stack.push(.{ .hash = hash });
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

/// Trampoline helper ( hash vtype-ptr -- tagged )
///
/// Takes a hash and a VirtualType pointer, validates that the hash has every
/// field required by the anonymous struct (and no extras), reads field values
/// from the hash in field order, and constructs a tagged struct instance.
fn virtualStructHashWrapHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const ptr_val = try helpers.popFixnum(ctx);
    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(ptr_val)));

    const st = vt.anon_struct orelse {
        helpers.setErrorContext(ctx, "{s} is not a struct-backed virtual type", .{vt.name});
        return error.TypeMismatch;
    };

    const val = try ctx.stack.pop();
    const hash = switch (val) {
        .hash => |h| h,
        else => {
            helpers.setErrorContext(ctx, ">{s} expects a hash, got {s}", .{ vt.name, helpers.valueTypeName(val) });
            return error.TypeMismatch;
        },
    };

    if (hash.count() != st.fields.len) {
        helpers.setErrorContext(ctx, ">{s} expects {d} fields, got {d}", .{ vt.name, st.fields.len, hash.count() });
        return error.TypeMismatch;
    }

    const field_values = try alloc.alloc(Value, st.fields.len);
    for (st.fields, 0..) |field, i| {
        field_values[i] = hash.get(field) orelse {
            helpers.setErrorContext(ctx, ">{s} missing field '{s}'", .{ vt.name, field });
            return error.MissingField;
        };
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

/// >NAME: ( hash -- tagged ) - hash-based wrap for struct-backed virtuals
pub fn defineStructHashWrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.virtual-struct-hash-wrap" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .provenance = vtypeProvenance(vtype, "hash-wrap"),
        .action = .{ .compound = instrs },
    });
}

/// >NAME: ( field1..fieldN -- tagged ) - struct-aware positional wrap
pub fn defineStructWrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.virtual-struct-wrap" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .provenance = vtypeProvenance(vtype, "constructor"),
        .action = .{ .compound = instrs },
    });
}

/// NAME>: ( tagged -- field1..fieldN ) - struct-aware destructuring unwrap
pub fn defineStructUnwrap(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.virtual-struct-unwrap" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .provenance = vtypeProvenance(vtype, "unwrap"),
        .action = .{ .compound = instrs },
    });
}

/// NAME>hash: ( tagged -- hash ) - convert struct-backed virtual to hash
pub fn defineVirtualToHash(ctx: *Context, name: []const u8, vtype: *const VirtualType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.virtual-struct-to-hash" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .provenance = vtypeProvenance(vtype, "to-hash"),
        .action = .{ .compound = instrs },
    });
}

/// Register a >hash dispatch entry for a type name, creating the generic `>hash` word if it doesn't exist yet.
pub fn registerHashDispatch(ctx: *Context, type_name: []const u8, instrs: []const Instruction) !void {
    const alloc = ctx.quotationAllocator();

    const is_generic = if (ctx.lookupWord(">hash")) |existing| blk: {
        for (existing.markers) |mk| {
            if (markers_mod.isGenericMarker(mk)) break :blk true;
        }
        break :blk false;
    } else false;

    if (!is_generic) {
        const generic_markers = try alloc.alloc(*Marker, 1);
        generic_markers[0] = @constCast(&markers_mod.generic_marker);

        try ctx.defineWord(">hash", .{
            .name = ">hash",
            .markers = generic_markers,
            .action = .{ .compound = &.{} },
        });
    }

    try ctx.dispatch.register(.{
        .word_name = ">hash",
        .type_a = type_name,
        .type_b = dispatch_mod.unary_sentinel,
    }, .{ .body = instrs }, true);
}
