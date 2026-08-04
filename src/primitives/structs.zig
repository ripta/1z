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
const container_backing = @import("../container_backing.zig");

const helpers = @import("helpers.zig");
const protocols = @import("protocols.zig");
const struct_field_spec = @import("struct_field_spec.zig");
const virtual = @import("virtual.zig");

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;

const dictionary_mod = @import("../dictionary.zig");
const WordProvenance = dictionary_mod.WordProvenance;
const WordDefinition = dictionary_mod.WordDefinition;

const stack_effect_mod = @import("../stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;
const StackEffectParam = stack_effect_mod.StackEffectParam;

/// Source location of a `struct{ ... }` declaration, captured at parse time and
/// stamped on every generated word so introspection and the linter see the
/// declaration site rather than the prelude quotation that runs `define-struct`.
const GenSrcLoc = struct {
    file: ?[]const u8 = null,
    line: usize = 0,
    column: usize = 0,
};

pub const primitives = [_]Primitive{
    .{ .name = "define-struct", .stack_effect = "name: descriptor markers --", .doc = "Define a struct type and its accessor words.", .func = nativeDefineStruct },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "make-struct-instance", .func = makeStructInstanceHelper, .polymorphic = true },
    .{ .name = "hash-to-struct", .func = hashToStructHelper, .stack_effect = "hash vtype-ptr -- instance" },
    .{ .name = "struct-type-predicate", .func = structTypePredicateHelper, .stack_effect = "val vtype-ptr -- ?" },
    .{ .name = "struct-field-get", .func = structFieldGetHelper, .stack_effect = "instance vtype-ptr field-index -- value" },
    .{ .name = "struct-field-set", .func = structFieldSetHelper, .stack_effect = "instance new-val vtype-ptr field-index -- instance" },
    .{ .name = "struct-instance-destructure", .func = structInstanceDestructureHelper, .polymorphic = true },
    .{ .name = "struct-instance-to-hash", .func = structInstanceToHashHelper, .stack_effect = "instance vtype-ptr -- hash" },
};

/// define-struct ( name: descriptor markers -- )
///
/// Generates: make-NAME, >NAME, NAME?, and FIELD>> for each field
fn nativeDefineStruct(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const markers_val = try ctx.stack.pop();
    defer container_backing.releaseValue(markers_val);
    const markers_array = switch (markers_val) {
        .array => |arr| arr.items,
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
    defer container_backing.releaseValue(desc_val);
    const raw_desc_map: *value_mod.MutableMap = switch (desc_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable_map", desc_val);
            return error.TypeMismatch;
        },
    };
    const fields_val = raw_desc_map.map.get("fields") orelse return error.MissingField;
    const fields_array = switch (fields_val) {
        .array => |arr| arr.items,
        else => {
            helpers.setTypeMismatchError(ctx, "array", fields_val);
            return error.TypeMismatch;
        },
    };
    const parsed_fields = try struct_field_spec.parse(alloc, ctx, fields_array, "struct{");
    const fields_slice = parsed_fields.names;
    const field_types_slice = parsed_fields.types;

    const name_val = try ctx.stack.pop();
    defer container_backing.releaseValue(name_val);
    // The name escapes into the long-lived StructType and TypeValue.
    const name = switch (name_val) {
        .symbol => |s| try alloc.dupe(u8, s.bytes),
        else => {
            helpers.setTypeMismatchError(ctx, "symbol", name_val);
            return error.TypeMismatch;
        },
    };

    // The `struct{` parse-time word stamps the declaration's source location
    // into the descriptor under `src-loc` as a { file line column } array. The
    // descriptor map (and its borrowed file string) is released at function
    // end, so dupe the file into the long-lived quotation arena.
    var src_loc: GenSrcLoc = .{};
    if (raw_desc_map.map.get("src-loc")) |sl_val| {
        if (sl_val == .array and sl_val.array.items.len == 3) {
            const parts = sl_val.array.items;
            if (parts[0] == .string) src_loc.file = try alloc.dupe(u8, parts[0].string.bytes);
            if (parts[1] == .fixnum) src_loc.line = @intCast(parts[1].fixnum);
            if (parts[2] == .fixnum) src_loc.column = @intCast(parts[2].fixnum);
        }
    }

    const has_mutable = for (markers_slice) |mk| {
        if (markers_mod.isMutableMarker(mk)) break true;
    } else false;

    const frozen_desc = try ctx.getOrCreateStructDescriptor(fields_slice, field_types_slice, has_mutable);

    const struct_type = try alloc.create(StructType);
    struct_type.* = .{
        .name = name,
        .fields = fields_slice,
        .field_types = field_types_slice,
    };
    ctx.struct_type_count += 1;

    // Create a TypeValue for type-of lookups
    const tv = try alloc.create(value_mod.TypeValue);
    tv.* = .{ .name = name, .descriptor = frozen_desc };
    struct_type.type_val = tv;

    // Record the canonical StructType so the runtime-image loader can reuse it
    // for compiled-construction instances instead of allocating a second one.
    try ctx.registerStructType(name, struct_type);

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
        .stack_effect = try helpers.makeSimpleEffect(alloc, "-- type"),
        .markers = type_markers,
        .provenance = .{ .generator = "struct", .parent = name, .role = "type" },
        .source_file = src_loc.file,
        .source_line = src_loc.line,
        .source_column = src_loc.column,
        .action = .{ .compound = type_instrs },
    });

    // make-NAME: ( field1 field2 ... -- instance ) - positional constructor
    const make_name = try std.fmt.allocPrint(alloc, "make-{s}", .{name});
    try defineConstructor(ctx, make_name, struct_type, markers_slice, src_loc);

    // >NAME: ( hash -- instance ) - hash-to-struct converter
    const convert_name = try std.fmt.allocPrint(alloc, ">{s}", .{name});
    try defineHashConverter(ctx, convert_name, struct_type, markers_slice, src_loc);

    // unmake-NAME: ( instance -- field1 field2 ... ) - positional destructor
    const unmake_name = try std.fmt.allocPrint(alloc, "unmake-{s}", .{name});
    try defineDestructor(ctx, unmake_name, struct_type, markers_slice, src_loc);

    // NAME>hash: ( instance -- hash ) - convert to hash
    const to_hash_name = try std.fmt.allocPrint(alloc, "{s}>hash", .{name});
    try defineToHash(ctx, to_hash_name, struct_type, markers_slice, src_loc);

    // >hash dispatch for this struct type
    const hash_instrs = try alloc.alloc(Instruction, 2);
    hash_instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    hash_instrs[1] = .{ .op = .{ .call_word = "native.struct-instance-to-hash" }, .line = 0 };
    const struct_tv = struct_type.type_val orelse return error.TypeMismatch;
    try virtual.registerHashDispatch(ctx, struct_tv, hash_instrs);

    // NAME?: ( val -- ? ) - type predicate
    const pred_name = try std.fmt.allocPrint(alloc, "{s}?", .{name});
    try defineTypePredicate(ctx, pred_name, struct_type, markers_slice, src_loc);

    // FIELD>>: ( instance -- value ) - field getter
    for (fields_slice, 0..) |field, i| {
        const getter_name = try std.fmt.allocPrint(alloc, "{s}>>", .{field});
        try defineFieldGetter(ctx, getter_name, struct_type, i, markers_slice, field, src_loc);
    }

    // >>FIELD: ( instance value -- instance ) - field setter (only if mutable)
    if (has_mutable) {
        for (fields_slice, 0..) |field, i| {
            const setter_name = try std.fmt.allocPrint(alloc, ">>{s}", .{field});
            try defineFieldSetter(ctx, setter_name, struct_type, i, markers_slice, field, src_loc);
        }
    }

    // Build generated-words reverse index
    var generated_words = std.ArrayListUnmanaged(Value){};
    try generated_words.append(alloc, value_mod.stringValue(name));
    try generated_words.append(alloc, value_mod.stringValue(make_name));
    try generated_words.append(alloc, value_mod.stringValue(convert_name));
    try generated_words.append(alloc, value_mod.stringValue(unmake_name));
    try generated_words.append(alloc, value_mod.stringValue(to_hash_name));
    try generated_words.append(alloc, value_mod.stringValue(pred_name));
    for (fields_slice) |field| {
        const gw_name = try std.fmt.allocPrint(alloc, "{s}>>", .{field});
        try generated_words.append(alloc, value_mod.stringValue(gw_name));
    }
    if (has_mutable) {
        for (fields_slice) |field| {
            const gw_name = try std.fmt.allocPrint(alloc, ">>{s}", .{field});
            try generated_words.append(alloc, value_mod.stringValue(gw_name));
        }
    }
    const gw_slice = try generated_words.toOwnedSlice(alloc);
    struct_tv.generated_words = gw_slice;
    try ctx.registerTypeDescriptor(name, frozen_desc);
}

/// Trampoline helper ( field1 .. fieldN struct-type -- instance )
fn makeStructInstanceHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.allocator;
    const st = try helpers.popStructType(ctx);
    const num_fields = st.fields.len;

    // Fields are popped (moved) off the stack into field_values, so each slot
    // owns its value. `lowest` marks the range field_values[lowest..num_fields]
    // that has been populated; on any error path before the instance takes
    // ownership, those owned values are released and the slice is freed.
    const field_values = try alloc.alloc(Value, num_fields);
    var lowest: usize = num_fields;
    var fields_owned = true;
    errdefer if (fields_owned) {
        container_backing.releaseValues(field_values[lowest..num_fields]);
        alloc.free(field_values);
    };
    var i: usize = num_fields;
    while (i > 0) {
        i -= 1;
        field_values[i] = try ctx.stack.pop();
        lowest = i;
        if (st.field_types.len != 0) {
            const expected = st.field_types[i] orelse unreachable;
            if (!try protocols.valueMatchesElement(ctx, field_values[i], expected)) {
                const actual_tv = helpers.resolveValueTypeValue(ctx, field_values[i]) orelse unreachable;
                helpers.setErrorContext(ctx, "make-{s}: field '{s}' expects {s}, got {s}", .{ st.name, st.fields[i], fieldConstraintName(expected), actual_tv.name });
                return error.TypeError;
            }
        }
    }

    const instance = try value_mod.createStructInstance(alloc, st, field_values);
    fields_owned = false;
    errdefer container_backing.releaseValue(.{ .struct_instance = instance });

    // The popped field values were moved in; the instance now owns them, so
    // push without an additional retain.
    try ctx.stack.pushMoved(.{ .struct_instance = instance });
}

/// Trampoline helper ( hash struct-type -- instance )
fn hashToStructHelper(ctx: *Context) anyerror!void {
    const alloc = ctx.allocator;
    const st = try helpers.popStructType(ctx);

    const hash_val = try ctx.stack.pop();
    // The popped hash is consumed by this word; release it on every path.
    defer container_backing.releaseValue(hash_val);
    const hash = switch (hash_val) {
        .hash => |h| h,
        else => {
            helpers.setTypeMismatchError(ctx, "hash", hash_val);
            return error.TypeMismatch;
        },
    };

    const field_values = try alloc.alloc(Value, st.fields.len);
    var fields_owned = true;
    errdefer if (fields_owned) alloc.free(field_values);
    for (st.fields, 0..) |field, i| {
        if (hash.map.get(field)) |val| {
            if (st.field_types.len != 0) {
                const expected = st.field_types[i] orelse unreachable;
                if (!try protocols.valueMatchesElement(ctx, val, expected)) {
                    const actual_tv = helpers.resolveValueTypeValue(ctx, val) orelse unreachable;
                    helpers.setErrorContext(ctx, ">{s}: field '{s}' expects {s}, got {s}", .{ st.name, field, fieldConstraintName(expected), actual_tv.name });
                    return error.TypeError;
                }
            }
            field_values[i] = val;
        } else {
            helpers.setErrorContext(ctx, "field '{s}' missing in hash for struct '{s}'", .{ field, st.name });
            return error.MissingField;
        }
    }

    // Fields are borrowed from the source hash; retain each so the instance
    // becomes an independent owner before the hash is released above.
    container_backing.retainValues(field_values);
    errdefer if (fields_owned) container_backing.releaseValues(field_values);

    const instance = try value_mod.createStructInstance(alloc, st, field_values);
    fields_owned = false;
    errdefer container_backing.releaseValue(.{ .struct_instance = instance });

    try ctx.stack.pushMoved(.{ .struct_instance = instance });
}

/// Trampoline helper ( val struct-type -- ? )
fn structTypePredicateHelper(ctx: *Context) anyerror!void {
    const st = try helpers.popStructType(ctx);

    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    const is_instance = switch (val) {
        .struct_instance => |si| si.struct_type.type_val.?.descriptor.? == st.type_val.?.descriptor.?,
        else => false,
    };

    try ctx.stack.push(.{ .boolean = is_instance });
}

/// Trampoline helper ( instance struct-type field-index -- value )
fn structFieldGetHelper(ctx: *Context) anyerror!void {
    const idx: usize = @intCast(try helpers.popFixnum(ctx));
    const st = try helpers.popStructType(ctx);
    const inst = try helpers.popStructInstance(ctx);
    // The instance was popped (moved) into this word; release it once the
    // extracted field has been pushed (push retains the field for its new slot).
    defer container_backing.releaseValue(.{ .struct_instance = inst });

    if (inst.struct_type.type_val.?.descriptor.? != st.type_val.?.descriptor.?) {
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
    const inst = helpers.popStructInstance(ctx) catch |err| {
        container_backing.releaseValue(new_val);
        return err;
    };
    // Both `new_val` and `inst` are owned (moved off the stack). The block's
    // errdefer releases them on the validation-error paths; it is discharged
    // once validation passes, after which `new_val` is moved into the field
    // and `inst` is returned via pushMoved.
    {
        errdefer {
            container_backing.releaseValue(new_val);
            container_backing.releaseValue(.{ .struct_instance = inst });
        }

        if (inst.struct_type.type_val.?.descriptor.? != st.type_val.?.descriptor.?) {
            helpers.setErrorContext(ctx, "expected struct '{s}', got struct '{s}'", .{ st.name, inst.struct_type.name });
            return error.TypeMismatch;
        }

        if (st.field_types.len != 0) {
            const expected = st.field_types[idx] orelse unreachable;
            if (!try protocols.valueMatchesElement(ctx, new_val, expected)) {
                const actual_tv = helpers.resolveValueTypeValue(ctx, new_val) orelse unreachable;
                helpers.setErrorContext(ctx, ">>{s}: field '{s}' expects {s}, got {s}", .{ st.fields[idx], st.fields[idx], fieldConstraintName(expected), actual_tv.name });
                return error.TypeError;
            }
        }
    }

    // Replace the stored field: release the instance's single owning reference to the old
    // value and move the new value in. The popped instance reference itself returns to the
    // stack via pushMoved. Sound only for a headered instance, where the instance is the one
    // owner of its field set; no runtime creation path produces a headerless one.
    container_backing.releaseValue(inst.fields[idx]);
    inst.fields[idx] = new_val;
    ctx.stack.pushMoved(.{ .struct_instance = inst }) catch |err| {
        container_backing.releaseValue(.{ .struct_instance = inst });
        return err;
    };
}

/// Trampoline helper ( instance struct-type -- field1 ... fieldN )
fn structInstanceDestructureHelper(ctx: *Context) anyerror!void {
    const st = try helpers.popStructType(ctx);
    const inst = try helpers.popStructInstance(ctx);
    // The instance was popped (moved) here; release it once each field has been
    // pushed (push retains every field for its new slot).
    defer container_backing.releaseValue(.{ .struct_instance = inst });

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
    const st = try helpers.popStructType(ctx);
    const inst = try helpers.popStructInstance(ctx);
    // The instance was popped (moved) here; release it once the hash holds
    // its own references to the field values.
    defer container_backing.releaseValue(.{ .struct_instance = inst });

    if (inst.struct_type != st) {
        helpers.setErrorContext(ctx, "expected struct '{s}', got struct '{s}'", .{ st.name, inst.struct_type.name });
        return error.TypeMismatch;
    }

    const hash = try value_mod.HashTable.create(ctx.allocator);
    errdefer hash.header.release();
    const hash_alloc = hash.header.allocator;
    for (st.fields, 0..) |field, i| {
        const key_copy = try hash_alloc.dupe(u8, field);
        container_backing.retainValue(inst.fields[i]);
        hash.map.put(hash_alloc, key_copy, inst.fields[i]) catch {
            hash_alloc.free(key_copy);
            container_backing.releaseValue(inst.fields[i]);
            return error.OutOfMemory;
        };
    }

    try ctx.stack.pushMoved(.{ .hash = hash });
}

/// make-NAME: ( field1 field2 ... -- instance ) - positional constructor
fn defineConstructor(ctx: *Context, name: []const u8, struct_type: *const StructType, markers: []const *Marker, src_loc: GenSrcLoc) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.make-struct-instance" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .stack_effect = try buildConstructorEffect(alloc, struct_type),
        .markers = markers,
        .provenance = .{ .generator = "struct", .parent = struct_type.name, .role = "constructor" },
        .source_file = src_loc.file,
        .source_line = src_loc.line,
        .source_column = src_loc.column,
        .action = .{ .compound = instrs },
    });
}

/// Resolve the shared dispatch_id for a `struct{`-generated field getter or setter name, so every
/// struct anywhere in the program with a field of this name dispatches through one table, regardless
/// of which mutually-invisible scope's `struct{` defines the accessor word first. The first `struct{`
/// to see a name seeds the registry with its `local_dispatch_id`; every later one reuses that id.
///
/// Not used by the `>NAME` hash converter: see the comment at its own dispatch registration for why
/// that one must stay scope-local.
fn sharedAccessorDispatchId(ctx: *Context, name: []const u8, local_dispatch_id: u32) !u32 {
    if (ctx.generic_accessor_dispatch_ids.get(name)) |shared_id| return shared_id;
    try ctx.generic_accessor_dispatch_ids.put(ctx.allocator, name, local_dispatch_id);
    return local_dispatch_id;
}

// >NAME: ( hash -- instance ) - hash-to-struct converter (generic, extensible via method{)
fn defineHashConverter(ctx: *Context, name: []const u8, struct_type: *const StructType, markers: []const *Marker, src_loc: GenSrcLoc) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.hash-to-struct" }, .line = 0 };

    const generic_markers = try alloc.alloc(*Marker, markers.len + 1);
    for (markers, 0..) |mk, i| generic_markers[i] = mk;
    generic_markers[markers.len] = @constCast(&markers_mod.generic_marker);

    const effect_str = try std.fmt.allocPrint(alloc, "hash -- {s}", .{struct_type.name});
    try ctx.defineWord(name, .{
        .name = name,
        .stack_effect = try helpers.makeSimpleEffect(alloc, effect_str),
        .markers = generic_markers,
        .provenance = .{ .generator = "struct", .parent = struct_type.name, .role = "hash-converter" },
        .source_file = src_loc.file,
        .source_line = src_loc.line,
        .source_column = src_loc.column,
        .action = .{ .compound = instrs },
    });

    // Unlike the field getter/setter below, this dispatch key is always (hash, unary_sentinel)
    // regardless of which struct it converts to -- the struct type itself is not part of the key.
    // So this dispatch_id must stay scope-local, not shared via `sharedAccessorDispatchId`: two
    // unrelated structs that happen to share a *type* name (e.g. `thing` in two different modules)
    // are meant to keep independent `>thing` converters, discriminated only by which word you call,
    // not by argument type. Sharing the dispatch_id here would collapse both converters onto one
    // key, so the second registration silently wins for both (see cross_mod_conversion.1z).
    const hash_tv = ctx.lookupBuiltinTypeValue("hash") orelse return;
    try ctx.registerDispatch(.{
        .dispatch_id = ctx.lookupWord(name).?.dispatch_id,
        .type_a = hash_tv.descriptor.?,
        .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
    }, .{ .body = .{ .quotation = .{ .instructions = instrs } } }, true);
}

/// unmake-NAME: ( instance -- field1 field2 ... ) - positional destructor
fn defineDestructor(ctx: *Context, name: []const u8, struct_type: *const StructType, markers: []const *Marker, src_loc: GenSrcLoc) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.struct-instance-destructure" }, .line = 0 };

    const effect_str = try helpers.buildDestructorEffectStr(alloc, struct_type.fields, struct_type.name);
    try ctx.defineWord(name, .{
        .name = name,
        .stack_effect = try helpers.makeSimpleEffect(alloc, effect_str),
        .markers = markers,
        .provenance = .{ .generator = "struct", .parent = struct_type.name, .role = "destructor" },
        .source_file = src_loc.file,
        .source_line = src_loc.line,
        .source_column = src_loc.column,
        .action = .{ .compound = instrs },
    });
}

/// NAME>hash: ( instance -- hash ) - convert struct instance to hash
fn defineToHash(ctx: *Context, name: []const u8, struct_type: *const StructType, markers: []const *Marker, src_loc: GenSrcLoc) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.struct-instance-to-hash" }, .line = 0 };

    const effect_str = try std.fmt.allocPrint(alloc, "{s} -- hash", .{struct_type.name});
    try ctx.defineWord(name, .{
        .name = name,
        .stack_effect = try helpers.makeSimpleEffect(alloc, effect_str),
        .markers = markers,
        .provenance = .{ .generator = "struct", .parent = struct_type.name, .role = "to-hash" },
        .source_file = src_loc.file,
        .source_line = src_loc.line,
        .source_column = src_loc.column,
        .action = .{ .compound = instrs },
    });
}

/// NAME?: ( val -- ? ) - type predicate
fn defineTypePredicate(ctx: *Context, name: []const u8, struct_type: *const StructType, markers: []const *Marker, src_loc: GenSrcLoc) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "native.struct-type-predicate" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .stack_effect = try helpers.makeSimpleEffect(alloc, "val -- ?"),
        .markers = markers,
        .provenance = .{ .generator = "struct", .parent = struct_type.name, .role = "predicate" },
        .source_file = src_loc.file,
        .source_line = src_loc.line,
        .source_column = src_loc.column,
        .action = .{ .compound = instrs },
    });
}

/// FIELD>>: ( instance -- value ) - field getter (generic, dispatches on struct type)
fn defineFieldGetter(ctx: *Context, name: []const u8, struct_type: *const StructType, field_index: usize, _: []const *Marker, field: []const u8, src_loc: GenSrcLoc) !void {
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

    const generic_markers = try alloc.alloc(*Marker, 1);
    generic_markers[0] = @constCast(&markers_mod.generic_marker);

    if (!is_generic) {
        try ctx.defineWord(name, .{
            .name = name,
            .stack_effect = try buildGetterEffect(alloc, struct_type, field_index),
            .markers = generic_markers,
            .provenance = .{ .generator = "struct", .parent = struct_type.name, .role = "getter" },
            .source_file = src_loc.file,
            .source_line = src_loc.line,
            .source_column = src_loc.column,
            .action = .{ .compound = &.{} },
        });
    }

    const type_tv = struct_type.type_val orelse return error.TypeMismatch;
    const dispatch_id = try sharedAccessorDispatchId(ctx, name, ctx.lookupWord(name).?.dispatch_id);
    ctx.overrideWordDispatchId(name, dispatch_id);
    try ctx.registerDispatch(.{
        .dispatch_id = dispatch_id,
        .type_a = type_tv.descriptor.?,
        .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
    }, .{
        .body = .{ .quotation = .{ .instructions = instrs } },
        .provenance = .{ .generator = "struct", .parent = struct_type.name, .role = "getter", .field = field },
    }, true);
}

/// >>FIELD: ( instance value -- instance ) - field setter (generic, dispatches on struct type)
///
/// Setters use binary dispatch keyed on (struct_type, *) so the dispatch
/// system matches the struct instance at stack position N-2 regardless of
/// the value type at the top.
fn defineFieldSetter(ctx: *Context, name: []const u8, struct_type: *const StructType, field_index: usize, _: []const *Marker, field: []const u8, src_loc: GenSrcLoc) !void {
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

    const generic_markers = try alloc.alloc(*Marker, 1);
    generic_markers[0] = @constCast(&markers_mod.generic_marker);

    if (!is_generic) {
        try ctx.defineWord(name, .{
            .name = name,
            .stack_effect = try buildSetterEffect(alloc, struct_type, field_index),
            .markers = generic_markers,
            .provenance = .{ .generator = "struct", .parent = struct_type.name, .role = "setter" },
            .source_file = src_loc.file,
            .source_line = src_loc.line,
            .source_column = src_loc.column,
            .action = .{ .compound = &.{} },
        });
    }

    const type_tv = struct_type.type_val orelse return error.TypeMismatch;
    const dispatch_id = try sharedAccessorDispatchId(ctx, name, ctx.lookupWord(name).?.dispatch_id);
    ctx.overrideWordDispatchId(name, dispatch_id);
    try ctx.registerDispatch(.{
        .dispatch_id = dispatch_id,
        .type_a = type_tv.descriptor.?,
        .type_b = ctx.getDispatchAnySentinel().descriptor.?,
    }, .{
        .body = .{ .quotation = .{ .instructions = instrs } },
        .provenance = .{ .generator = "struct", .parent = struct_type.name, .role = "setter", .field = field },
    }, true);
}

pub fn getStructTypeFromMaker(ctx: *const Context, maker_name: []const u8) ?*const StructType {
    const word = ctx.lookupWord(maker_name) orelse return null;
    switch (word.action) {
        .literal => |v| return switch (v) {
            .struct_type => |st| st,
            else => null,
        },
        .native, .host_callback => return null,
        .compound => {},
    }

    const instrs = word.action.compound;
    if (instrs.len == 0) return null;

    return switch (instrs[0].op) {
        .push_literal => |v| switch (v) {
            .struct_type => |st| st,
            else => null,
        },
        else => null,
    };
}

fn fieldAnnotation(struct_type: *const StructType, field_index: usize) ?stack_effect_mod.TypeAnnotation {
    if (struct_type.field_types.len == 0) return null;
    const element = struct_type.field_types[field_index] orelse return null;
    return switch (element) {
        .type => |tv| .{ .type = tv },
        .protocol => |pd| .{ .protocol = pd },
        .combinator => |cc| .{ .combination = cc },
    };
}

/// Human-readable name of a field constraint for error messages.
fn fieldConstraintName(element: value_mod.ConstraintCombinator.Element) []const u8 {
    return switch (element) {
        .type => |tv| tv.name,
        .protocol => |pd| pd.name,
        .combinator => "<constraint>",
    };
}

fn typeValAnnotation(struct_type: *const StructType) ?stack_effect_mod.TypeAnnotation {
    const tv = struct_type.type_val orelse return null;
    return .{ .type = tv };
}

fn buildConstructorEffect(alloc: std.mem.Allocator, struct_type: *const StructType) !StackEffect {
    const inputs = try alloc.alloc(StackEffectParam, struct_type.fields.len);
    for (struct_type.fields, 0..) |field, i| {
        inputs[i] = .{
            .name = field,
            .type_annotation = fieldAnnotation(struct_type, i),
        };
    }

    const outputs = try alloc.alloc(StackEffectParam, 1);
    outputs[0] = .{
        .name = struct_type.name,
        .type_annotation = typeValAnnotation(struct_type),
    };

    return .{ .inputs = inputs, .outputs = outputs };
}

fn buildGetterEffect(alloc: std.mem.Allocator, struct_type: *const StructType, field_index: usize) !StackEffect {
    const inputs = try alloc.alloc(StackEffectParam, 1);
    inputs[0] = .{
        .name = "instance",
        .type_annotation = typeValAnnotation(struct_type),
    };

    const outputs = try alloc.alloc(StackEffectParam, 1);
    outputs[0] = .{
        .name = struct_type.fields[field_index],
        .type_annotation = fieldAnnotation(struct_type, field_index),
    };

    return .{ .inputs = inputs, .outputs = outputs };
}

fn buildSetterEffect(alloc: std.mem.Allocator, struct_type: *const StructType, field_index: usize) !StackEffect {
    const inputs = try alloc.alloc(StackEffectParam, 2);
    inputs[0] = .{
        .name = "instance",
        .type_annotation = typeValAnnotation(struct_type),
    };
    inputs[1] = .{
        .name = struct_type.fields[field_index],
        .type_annotation = fieldAnnotation(struct_type, field_index),
    };

    const outputs = try alloc.alloc(StackEffectParam, 1);
    outputs[0] = .{
        .name = "instance",
        .type_annotation = typeValAnnotation(struct_type),
    };

    return .{ .inputs = inputs, .outputs = outputs };
}
