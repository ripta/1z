const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const StructType = value_mod.StructType;
const StructInstance = value_mod.StructInstance;
const Marker = value_mod.Marker;
const markers_mod = @import("markers.zig");
const dispatch_mod = @import("../dispatch.zig");

const helpers = @import("helpers.zig");
const virtual = @import("virtual.zig");

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;

const dictionary_mod = @import("../dictionary.zig");
const WordProvenance = dictionary_mod.WordProvenance;
const WordDefinition = dictionary_mod.WordDefinition;

pub const primitives = [_]Primitive{
    .{ .name = "define-struct", .stack_effect = "name: descriptor markers --", .doc = "Define a struct type and its accessor words.", .func = nativeDefineStruct },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "make-struct-instance", .func = makeStructInstanceHelper },
    .{ .name = "hash-to-struct", .func = hashToStructHelper },
    .{ .name = "struct-type-predicate", .func = structTypePredicateHelper },
    .{ .name = "struct-field-get", .func = structFieldGetHelper },
    .{ .name = "struct-field-set", .func = structFieldSetHelper },
    .{ .name = "struct-instance-destructure", .func = structInstanceDestructureHelper },
    .{ .name = "struct-instance-to-hash", .func = structInstanceToHashHelper },
};

/// define-struct ( name: descriptor markers -- ) - Define a struct type and its accessor words
///
/// Generates: make-NAME, >NAME, NAME?, and FIELD>> for each field
fn nativeDefineStruct(ctx: *Context) anyerror!void {
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
    const desc_map: *value_mod.MutableMap = switch (desc_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable_map", desc_val);
            return error.TypeMismatch;
        },
    };
    const fields_val = desc_map.get("fields") orelse return error.MissingField;
    const fields_array = switch (fields_val) {
        .array => |arr| arr,
        else => {
            helpers.setTypeMismatchError(ctx, "array", fields_val);
            return error.TypeMismatch;
        },
    };

    var fields_list = std.ArrayListUnmanaged([]const u8){};
    for (fields_array) |f| {
        const raw = switch (f) {
            .string => |s| s,
            .symbol => |s| s,
            else => {
                helpers.setTypeMismatchError(ctx, "string or symbol", f);
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

    const name_val = try ctx.stack.pop();
    const name = switch (name_val) {
        .symbol => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol", name_val);
            return error.TypeMismatch;
        },
    };

    const struct_type = try alloc.create(StructType);
    struct_type.* = .{
        .name = name,
        .fields = fields_slice,
    };

    // Create a TypeValue for type-of lookups
    const tv = try alloc.create(value_mod.TypeValue);
    tv.* = .{ .name = name, .descriptor = null };
    struct_type.type_val = tv;

    // NAME: ( -- type ) - the struct type itself pushing a TypeValue
    const type_markers = try alloc.alloc(*Marker, 3);
    type_markers[0] = @constCast(&markers_mod.parse_time_marker);
    type_markers[1] = @constCast(&markers_mod.const_marker);
    type_markers[2] = @constCast(&markers_mod.typed_marker);

    const type_instrs = try alloc.alloc(Instruction, 1);
    type_instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = tv } }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .parse_time = true,
        .markers = type_markers,
        .provenance = .{ .generator = "struct", .parent = name, .role = "type" },
        .action = .{ .compound = type_instrs },
    });

    // make-NAME: ( field1 field2 ... -- instance ) - positional constructor
    const make_name = try std.fmt.allocPrint(alloc, "make-{s}", .{name});
    try defineConstructor(ctx, make_name, struct_type, markers_slice);

    // >NAME: ( hash -- instance ) - hash-to-struct converter
    const convert_name = try std.fmt.allocPrint(alloc, ">{s}", .{name});
    try defineHashConverter(ctx, convert_name, struct_type, markers_slice);

    // unmake-NAME: ( instance -- field1 field2 ... ) - positional destructor
    const unmake_name = try std.fmt.allocPrint(alloc, "unmake-{s}", .{name});
    try defineDestructor(ctx, unmake_name, struct_type, markers_slice);

    // NAME>hash: ( instance -- hash ) - convert to hash
    const to_hash_name = try std.fmt.allocPrint(alloc, "{s}>hash", .{name});
    try defineToHash(ctx, to_hash_name, struct_type, markers_slice);

    // >hash dispatch for this struct type
    const hash_instrs = try alloc.alloc(Instruction, 2);
    hash_instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    hash_instrs[1] = .{ .op = .{ .call_word = "native.struct-instance-to-hash" }, .line = 0 };
    try virtual.registerHashDispatch(ctx, name, hash_instrs);

    // NAME?: ( val -- ? ) - type predicate
    const pred_name = try std.fmt.allocPrint(alloc, "{s}?", .{name});
    try defineTypePredicate(ctx, pred_name, struct_type, markers_slice);

    // FIELD>>: ( instance -- value ) - field getter
    for (fields_slice, 0..) |field, i| {
        const getter_name = try std.fmt.allocPrint(alloc, "{s}>>", .{field});
        try defineFieldGetter(ctx, getter_name, struct_type, i, markers_slice, field);
    }

    // >>FIELD: ( instance value -- instance ) - field setter (only if mutable)
    const has_mutable = for (markers_slice) |mk| {
        if (markers_mod.isMutableMarker(mk)) break true;
    } else false;
    if (has_mutable) {
        for (fields_slice, 0..) |field, i| {
            const setter_name = try std.fmt.allocPrint(alloc, ">>{s}", .{field});
            try defineFieldSetter(ctx, setter_name, struct_type, i, markers_slice, field);
        }
    }

    // Build generated-words reverse index
    var generated_words = std.ArrayListUnmanaged(Value){};
    try generated_words.append(alloc, .{ .string = name });
    try generated_words.append(alloc, .{ .string = make_name });
    try generated_words.append(alloc, .{ .string = convert_name });
    try generated_words.append(alloc, .{ .string = unmake_name });
    try generated_words.append(alloc, .{ .string = to_hash_name });
    try generated_words.append(alloc, .{ .string = pred_name });
    for (fields_slice) |field| {
        const gw_name = try std.fmt.allocPrint(alloc, "{s}>>", .{field});
        try generated_words.append(alloc, .{ .string = gw_name });
    }
    if (has_mutable) {
        for (fields_slice) |field| {
            const gw_name = try std.fmt.allocPrint(alloc, ">>{s}", .{field});
            try generated_words.append(alloc, .{ .string = gw_name });
        }
    }
    const gw_slice = try generated_words.toOwnedSlice(alloc);
    try desc_map.put(alloc, "generated-words", .{ .array = gw_slice });
    const frozen_desc: *value_mod.HashTable = @ptrCast(desc_map);
    try ctx.type_descriptors.put(ctx.allocator, name, frozen_desc);
    struct_type.type_val.?.descriptor = frozen_desc;
}

/// Trampoline helper ( field1 .. fieldN struct-type -- instance )
fn makeStructInstanceHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const st = try helpers.popStructType(ctx);
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

    try ctx.stack.push(.{ .struct_instance = instance });
}

/// Trampoline helper ( hash struct-type -- instance )
fn hashToStructHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const st = try helpers.popStructType(ctx);

    const hash_val = try ctx.stack.pop();
    const hash = switch (hash_val) {
        .hash => |h| h,
        else => {
            helpers.setTypeMismatchError(ctx, "hash", hash_val);
            return error.TypeMismatch;
        },
    };

    const field_values = try alloc.alloc(Value, st.fields.len);
    for (st.fields, 0..) |field, i| {
        if (hash.get(field)) |val| {
            field_values[i] = val;
        } else {
            helpers.setErrorContext(ctx, "field '{s}' missing in hash for struct '{s}'", .{ field, st.name });
            return error.MissingField;
        }
    }

    const instance = try alloc.create(StructInstance);
    instance.* = .{
        .struct_type = st,
        .fields = field_values,
    };

    try ctx.stack.push(.{ .struct_instance = instance });
}

/// Trampoline helper ( val struct-type -- ? )
fn structTypePredicateHelper(ctx: *Context) anyerror!void {
    const st = try helpers.popStructType(ctx);

    const val = try ctx.stack.pop();
    const is_instance = switch (val) {
        .struct_instance => |si| si.struct_type == st,
        else => false,
    };

    try ctx.stack.push(.{ .boolean = is_instance });
}

/// Trampoline helper ( instance struct-type field-index -- value )
fn structFieldGetHelper(ctx: *Context) anyerror!void {
    const idx: usize = @intCast(try helpers.popFixnum(ctx));
    const st = try helpers.popStructType(ctx);
    const inst = try helpers.popStructInstance(ctx);

    if (inst.struct_type != st) {
        helpers.setErrorContext(ctx, "expected struct '{s}', got struct '{s}'", .{ st.name, inst.struct_type.name });
        return error.TypeMismatch;
    }

    try ctx.stack.push(inst.fields[idx]);
}

/// Trampoline helper ( instance value struct-type field-index -- instance )
fn structFieldSetHelper(ctx: *Context) anyerror!void {
    const idx: usize = @intCast(try helpers.popFixnum(ctx));
    const st = try helpers.popStructType(ctx);
    const new_val = try ctx.stack.pop();
    const inst = try helpers.popStructInstance(ctx);

    if (inst.struct_type != st) {
        helpers.setErrorContext(ctx, "expected struct '{s}', got struct '{s}'", .{ st.name, inst.struct_type.name });
        return error.TypeMismatch;
    }

    inst.fields[idx] = new_val;
    try ctx.stack.push(.{ .struct_instance = inst });
}

/// Trampoline helper ( instance struct-type -- field1 ... fieldN )
fn structInstanceDestructureHelper(ctx: *Context) anyerror!void {
    const st = try helpers.popStructType(ctx);
    const inst = try helpers.popStructInstance(ctx);

    if (inst.struct_type != st) {
        helpers.setErrorContext(ctx, "expected struct '{s}', got struct '{s}'", .{ st.name, inst.struct_type.name });
        return error.TypeMismatch;
    }

    for (inst.fields) |field_val| {
        try ctx.stack.push(field_val);
    }
}

/// Trampoline helper ( instance struct-type -- hash )
fn structInstanceToHashHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const st = try helpers.popStructType(ctx);
    const inst = try helpers.popStructInstance(ctx);

    if (inst.struct_type != st) {
        helpers.setErrorContext(ctx, "expected struct '{s}', got struct '{s}'", .{ st.name, inst.struct_type.name });
        return error.TypeMismatch;
    }

    const hash = try alloc.create(value_mod.HashTable);
    hash.* = .{};
    for (st.fields, 0..) |field, i| {
        try hash.put(alloc, field, inst.fields[i]);
    }

    try ctx.stack.push(.{ .hash = hash });
}

/// make-NAME: ( field1 field2 ... -- instance ) - positional constructor
fn defineConstructor(ctx: *Context, name: []const u8, struct_type: *const StructType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.make-struct-instance" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .provenance = .{ .generator = "struct", .parent = struct_type.name, .role = "constructor" },
        .action = .{ .compound = instrs },
    });
}

// >NAME: ( hash -- instance ) - hash-to-struct converter
fn defineHashConverter(ctx: *Context, name: []const u8, struct_type: *const StructType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.hash-to-struct" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .provenance = .{ .generator = "struct", .parent = struct_type.name, .role = "hash-converter" },
        .action = .{ .compound = instrs },
    });
}

/// unmake-NAME: ( instance -- field1 field2 ... ) - positional destructor
fn defineDestructor(ctx: *Context, name: []const u8, struct_type: *const StructType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.struct-instance-destructure" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .provenance = .{ .generator = "struct", .parent = struct_type.name, .role = "destructor" },
        .action = .{ .compound = instrs },
    });
}

/// NAME>hash: ( instance -- hash ) - convert struct instance to hash
fn defineToHash(ctx: *Context, name: []const u8, struct_type: *const StructType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.struct-instance-to-hash" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .provenance = .{ .generator = "struct", .parent = struct_type.name, .role = "to-hash" },
        .action = .{ .compound = instrs },
    });
}

/// NAME?: ( val -- ? ) - type predicate
fn defineTypePredicate(ctx: *Context, name: []const u8, struct_type: *const StructType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.struct-type-predicate" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .provenance = .{ .generator = "struct", .parent = struct_type.name, .role = "predicate" },
        .action = .{ .compound = instrs },
    });
}

/// FIELD>>: ( instance -- value ) - field getter (generic, dispatches on struct type)
fn defineFieldGetter(ctx: *Context, name: []const u8, struct_type: *const StructType, field_index: usize, _: []const *Marker, field: []const u8) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(field_index) } }, .line = 0 };
    instrs[2] = .{ .op = .{ .call_word = "native.struct-field-get" }, .line = 0 };

    const is_generic = if (ctx.lookupWord(name)) |existing| blk: {
        for (existing.markers) |mk| {
            if (markers_mod.isGenericMarker(mk)) break :blk true;
        }
        break :blk false;
    } else false;

    if (!is_generic) {
        const generic_markers = try alloc.alloc(*Marker, 1);
        generic_markers[0] = @constCast(&markers_mod.generic_marker);

        try ctx.defineWord(name, .{
            .name = name,
            .markers = generic_markers,
            .action = .{ .compound = &.{} },
        });
    }

    try ctx.dispatch.register(.{
        .word_name = name,
        .type_a = struct_type.name,
        .type_b = dispatch_mod.unary_sentinel,
    }, .{
        .body = instrs,
        .provenance = .{ .generator = "struct", .parent = struct_type.name, .role = "getter", .field = field },
    }, true);
}

/// >>FIELD: ( instance value -- instance ) - field setter (generic, dispatches on struct type)
///
/// Setters use binary dispatch keyed on (struct_type, *) so the dispatch
/// system matches the struct instance at stack position N-2 regardless of
/// the value type at the top.
fn defineFieldSetter(ctx: *Context, name: []const u8, struct_type: *const StructType, field_index: usize, _: []const *Marker, field: []const u8) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(field_index) } }, .line = 0 };
    instrs[2] = .{ .op = .{ .call_word = "native.struct-field-set" }, .line = 0 };

    const is_generic = if (ctx.lookupWord(name)) |existing| blk: {
        for (existing.markers) |mk| {
            if (markers_mod.isGenericMarker(mk)) break :blk true;
        }
        break :blk false;
    } else false;

    if (!is_generic) {
        const generic_markers = try alloc.alloc(*Marker, 1);
        generic_markers[0] = @constCast(&markers_mod.generic_marker);

        try ctx.defineWord(name, .{
            .name = name,
            .markers = generic_markers,
            .action = .{ .compound = &.{} },
        });
    }

    try ctx.dispatch.register(.{
        .word_name = name,
        .type_a = struct_type.name,
        .type_b = dispatch_mod.any_sentinel,
    }, .{
        .body = instrs,
        .provenance = .{ .generator = "struct", .parent = struct_type.name, .role = "setter", .field = field },
    }, true);
}

pub fn getStructTypeFromMaker(ctx: *const Context, maker_name: []const u8) ?*const StructType {
    const word = ctx.lookupWord(maker_name) orelse return null;
    const instrs = switch (word.action) {
        .compound => |c| c,
        .native => return null,
    };

    if (instrs.len == 0) return null;

    return switch (instrs[0].op) {
        .push_literal => |v| switch (v) {
            .struct_type => |st| st,
            else => null,
        },
        else => null,
    };
}
