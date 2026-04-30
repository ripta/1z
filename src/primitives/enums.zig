const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const VirtualType = value_mod.VirtualType;
const StructType = value_mod.StructType;
const StructInstance = value_mod.StructInstance;
const Marker = value_mod.Marker;

const helpers = @import("helpers.zig");
const markers_mod = @import("markers.zig");
const virtual = @import("virtual.zig");

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;

const dictionary_mod = @import("../dictionary.zig");
const WordProvenance = dictionary_mod.WordProvenance;
const WordDefinition = dictionary_mod.WordDefinition;

pub const primitives = [_]Primitive{
    .{ .name = "define-enum", .stack_effect = "name: descriptor markers --", .doc = "Define an enum type with flat variant constructors and predicates.", .func = nativeDefineEnum },
    .{ .name = "enum-of", .stack_effect = "val -- str/f", .doc = "Return the parent enum name for an enum variant value, or f if not an enum variant.", .func = nativeEnumOf },
    .{ .name = "enum-variants", .stack_effect = "symbol -- array", .doc = "Return an array of variant name symbols for the named enum.", .func = nativeEnumVariants },
    .{ .name = "match", .stack_effect = "val branches -- ...", .doc = "Exhaustive dispatch on enum variants. Branches are alternating symbol-quotation pairs. Auto-unwraps data-carrying variants.", .func = nativeMatch, .markers = &.{@constCast(&markers_mod.branch_combinator_marker)} },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "enum-aggregate-predicate", .func = enumAggregatePredicateHelper },
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
    const desc_map = switch (desc_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable-map", desc_val);
            return error.TypeMismatch;
        },
    };
    const variants_val = desc_map.get("variants") orelse {
        helpers.setErrorContext(ctx, "enum descriptor missing variants key", .{});
        return error.MissingField;
    };
    const variants_array = switch (variants_val) {
        .array => |arr| arr,
        else => {
            helpers.setTypeMismatchError(ctx, "array", variants_val);
            return error.TypeMismatch;
        },
    };

    const name_val = try ctx.stack.pop();
    const enum_name = switch (name_val) {
        .symbol => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol", name_val);
            return error.TypeMismatch;
        },
    };

    var vtype_list = std.ArrayListUnmanaged(*const VirtualType){};
    var generated_words = std.ArrayListUnmanaged(Value){};

    var i: usize = 0;
    while (i < variants_array.len) {
        const variant_val = variants_array[i];
        const variant_sym = switch (variant_val) {
            .string => |s| s,
            .symbol => |s| s,
            else => {
                helpers.setTypeMismatchError(ctx, "string or symbol", variant_val);
                return error.TypeMismatch;
            },
        };

        const has_struct_desc = if (i + 1 < variants_array.len)
            switch (variants_array[i + 1]) {
                .mutable_map => true,
                else => false,
            }
        else
            false;

        if (has_struct_desc) {
            const struct_desc = switch (variants_array[i + 1]) {
                .mutable_map => |m| m,
                else => unreachable,
            };
            i += 2;

            const fields_val = struct_desc.get("fields") orelse {
                helpers.setErrorContext(ctx, "struct descriptor missing fields key", .{});
                return error.MissingField;
            };
            const fields_array = switch (fields_val) {
                .array => |arr| arr,
                else => {
                    helpers.setTypeMismatchError(ctx, "array", fields_val);
                    return error.TypeMismatch;
                },
            };

            if (fields_array.len == 0) {
                helpers.setErrorContext(ctx, "data variant '{s}' must have at least one field", .{variant_sym});
                return error.ParseError;
            }

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
                try fields_list.append(alloc, try alloc.dupe(u8, field_name));
            }
            const fields_slice = try fields_list.toOwnedSlice(alloc);

            const full_name = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ enum_name, variant_sym });

            const anon_struct = try alloc.create(StructType);
            anon_struct.* = .{
                .name = full_name,
                .fields = fields_slice,
            };

            const vtype = try alloc.create(VirtualType);
            vtype.* = .{
                .name = full_name,
                .inner_type = full_name,
                .enum_name = enum_name,
                .anon_struct = anon_struct,
            };

            try vtype_list.append(alloc, vtype);

            const wrap_name = try std.fmt.allocPrint(alloc, ">{s}", .{full_name});
            if (fields_slice.len > 1) {
                // Multi-field: >NAME is hash-based
                try virtual.defineStructHashWrap(ctx, wrap_name, vtype, markers_slice);
            } else {
                // Single-field: >NAME stays positional
                try virtual.defineStructWrap(ctx, wrap_name, vtype, markers_slice);
            }

            // make-NAME: positional wrap
            const make_name = try std.fmt.allocPrint(alloc, "make-{s}", .{full_name});
            try virtual.defineStructWrap(ctx, make_name, vtype, markers_slice);

            // unmake-NAME: destructuring unwrap
            const unmake_name = try std.fmt.allocPrint(alloc, "unmake-{s}", .{full_name});
            try virtual.defineStructUnwrap(ctx, unmake_name, vtype, markers_slice);

            const to_hash_name = try std.fmt.allocPrint(alloc, "{s}>hash", .{full_name});
            try virtual.defineVirtualToHash(ctx, to_hash_name, vtype, markers_slice);

            const hash_instrs = try alloc.alloc(Instruction, 2);
            hash_instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(@intFromPtr(vtype)) } }, .line = 0 };
            hash_instrs[1] = .{ .op = .{ .call_word = "native.virtual-struct-to-hash" }, .line = 0 };
            try virtual.registerHashDispatch(ctx, full_name, hash_instrs);

            const pred_name = try std.fmt.allocPrint(alloc, "{s}?", .{full_name});
            try virtual.definePredicate(ctx, pred_name, vtype, markers_slice);

            try generated_words.append(alloc, .{ .string = wrap_name });
            try generated_words.append(alloc, .{ .string = make_name });
            try generated_words.append(alloc, .{ .string = unmake_name });
            try generated_words.append(alloc, .{ .string = to_hash_name });
            try generated_words.append(alloc, .{ .string = pred_name });
        } else {
            const full_name = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ enum_name, variant_sym });

            const vtype = try alloc.create(VirtualType);
            vtype.* = .{
                .name = full_name,
                .inner_type = "symbol",
                .enum_name = enum_name,
            };

            try vtype_list.append(alloc, vtype);

            const inner = try alloc.create(Value);
            inner.* = .{ .symbol = variant_sym };

            const instrs = try alloc.alloc(Instruction, 1);
            instrs[0] = .{ .op = .{ .push_literal = .{ .tagged = .{ .tag = vtype, .inner = inner } } }, .line = 0 };

            try ctx.defineWord(full_name, .{
                .name = full_name,
                .markers = markers_slice,
                .provenance = .{ .generator = "enum", .parent = enum_name, .role = "variant-constructor" },
                .action = .{ .compound = instrs },
            });

            const pred_name = try std.fmt.allocPrint(alloc, "{s}:{s}?", .{ enum_name, variant_sym });
            try virtual.definePredicate(ctx, pred_name, vtype, markers_slice);

            try generated_words.append(alloc, .{ .string = full_name });
            try generated_words.append(alloc, .{ .string = pred_name });

            i += 1;
        }
    }

    // Aggregate predicate
    const agg_pred_name = try std.fmt.allocPrint(alloc, "{s}?", .{enum_name});
    const enum_name_str = try alloc.dupe(u8, enum_name);

    const agg_instrs = try alloc.alloc(Instruction, 2);
    agg_instrs[0] = .{ .op = .{ .push_literal = .{ .string = enum_name_str } }, .line = 0 };
    agg_instrs[1] = .{ .op = .{ .call_word = "native.enum-aggregate-predicate" }, .line = 0 };

    try ctx.defineWord(agg_pred_name, .{
        .name = agg_pred_name,
        .markers = markers_slice,
        .provenance = .{ .generator = "enum", .parent = enum_name, .role = "predicate" },
        .action = .{ .compound = agg_instrs },
    });

    try generated_words.append(alloc, .{ .string = agg_pred_name });
    const gw_slice = try generated_words.toOwnedSlice(alloc);
    try desc_map.put(alloc, "generated-words", .{ .array = gw_slice });
    try ctx.type_descriptors.put(ctx.allocator, enum_name, desc_map);

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
        else => {
            helpers.setTypeMismatchError(ctx, "string", name_val);
            return error.TypeMismatch;
        },
    };

    const val = try ctx.stack.pop();
    const is_match = switch (val) {
        .tagged => |t| if (t.tag.enum_name) |en| std.mem.eql(u8, en, enum_name) else false,
        else => false,
    };

    try ctx.stack.push(.{ .boolean = is_match });
}

/// enum-of ( val -- str | f )
///
/// Returns the parent enum name as a string if the value is an enum variant,
/// or f if the value is not an enum variant.
fn nativeEnumOf(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .tagged => |t| {
            if (t.tag.enum_name) |en| {
                try ctx.stack.push(.{ .string = en });
                return;
            }
        },
        else => {},
    }
    try ctx.stack.push(.{ .boolean = false });
}

/// enum-variants ( symbol -- array )
///
/// Returns an array of variant name symbols for the named enum.
fn nativeEnumVariants(ctx: *Context) anyerror!void {
    const name_val = try ctx.stack.pop();
    const enum_name = switch (name_val) {
        .symbol => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol", name_val);
            return error.TypeMismatch;
        },
    };

    const vtypes = ctx.lookupEnumVariants(enum_name) orelse {
        helpers.setErrorContext(ctx, "unknown enum '{s}'", .{enum_name});
        return error.NameError;
    };

    const alloc = ctx.quotationAllocator();
    const result = try alloc.alloc(Value, vtypes.len);
    for (vtypes, 0..) |vt, i| {
        result[i] = .{ .symbol = vt.name };
    }

    try ctx.stack.push(.{ .array = result });
}

/// match ( val branches -- ... )
///
/// Exhaustive dispatch on enum variants. The branches array alternates between
/// variant name symbols and quotation bodies. Every variant of the enum must
/// appear exactly once. For data-carrying variants, the unwrapped payload fields
/// are pushed onto the stack before the body executes.
fn nativeMatch(ctx: *Context) anyerror!void {
    const branches_val = try ctx.stack.pop();
    const branches = switch (branches_val) {
        .array => |arr| arr,
        else => {
            helpers.setTypeMismatchError(ctx, "array", branches_val);
            return error.TypeMismatch;
        },
    };

    const val = try ctx.stack.pop();
    const tag = switch (val) {
        .tagged => |t| t,
        else => {
            helpers.setErrorContext(ctx, "match requires an enum variant, got {s}", .{helpers.valueTypeName(val)});
            return error.TypeMismatch;
        },
    };

    const enum_name = tag.tag.enum_name orelse {
        helpers.setErrorContext(ctx, "match requires an enum variant, got virtual type '{s}'", .{tag.tag.name});
        return error.TypeMismatch;
    };

    if (branches.len % 2 != 0) {
        helpers.setErrorContext(ctx, "match branches must be symbol-quotation pairs (got odd count {d})", .{branches.len});
        return error.ParseError;
    }

    const vtypes = ctx.lookupEnumVariants(enum_name) orelse {
        helpers.setErrorContext(ctx, "unknown enum '{s}'", .{enum_name});
        return error.NameError;
    };

    const alloc = ctx.quotationAllocator();
    const n_branches = branches.len / 2;

    if (n_branches != vtypes.len) {
        helpers.setErrorContext(ctx, "match has {d} branches but enum '{s}' has {d} variants", .{ n_branches, enum_name, vtypes.len });
        return error.ParseError;
    }

    var matched_body: ?value_mod.Quotation = null;
    var seen = std.StringHashMapUnmanaged(void){};

    var i: usize = 0;
    while (i < branches.len) : (i += 2) {
        const key = switch (branches[i]) {
            .symbol => |s| s,
            else => {
                helpers.setErrorContext(ctx, "match branch key must be a symbol, got {s}", .{helpers.valueTypeName(branches[i])});
                return error.TypeMismatch;
            },
        };
        const body = switch (branches[i + 1]) {
            .quotation => |q| q,
            else => {
                helpers.setErrorContext(ctx, "match branch body must be a quotation", .{});
                return error.TypeMismatch;
            },
        };

        var valid = false;
        for (vtypes) |vt| {
            if (std.mem.eql(u8, vt.name, key)) {
                valid = true;
                break;
            }
        }
        if (!valid) {
            helpers.setErrorContext(ctx, "'{s}' is not a variant of enum '{s}'", .{ key, enum_name });
            return error.NameError;
        }

        if (seen.contains(key)) {
            helpers.setErrorContext(ctx, "duplicate match branch for '{s}'", .{key});
            return error.ParseError;
        }
        try seen.put(alloc, key, {});

        if (std.mem.eql(u8, tag.tag.name, key)) {
            matched_body = body;
        }
    }

    // Exhaustiveness check
    for (vtypes) |vt| {
        if (!seen.contains(vt.name)) {
            helpers.setErrorContext(ctx, "missing match branch for variant '{s}'", .{vt.name});
            return error.ParseError;
        }
    }

    const body = matched_body orelse unreachable;

    // For data-carrying variants, unwrap the struct fields onto the stack
    if (tag.tag.anon_struct != null) {
        switch (tag.inner.*) {
            .struct_instance => |si| {
                for (si.fields) |field_val| {
                    try ctx.stack.push(field_val);
                }
            },
            else => {},
        }
    }

    try ctx.executeQuotation(body);
}
