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
const structs = @import("structs.zig");
const virtual = @import("virtual.zig");
const container_backing = @import("../container_backing.zig");

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
    .{ .name = "unchecked-match", .stack_effect = "val branches -- ...", .doc = "Exhaustive dispatch on enum variants. Branches are alternating symbol-quotation pairs. Auto-unwraps data-carrying variants.", .func = nativeMatch, .markers = &.{@constCast(&markers_mod.branch_combinator_marker)} },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "enum-aggregate-predicate", .func = enumAggregatePredicateHelper, .stack_effect = "val enum-type-val -- ?" },
    .{ .name = "enum-from-symbol", .func = enumFromSymbolHelper, .stack_effect = "symbol enum-type-val -- enum-variant" },
    .{ .name = "validate-match-block", .func = nativeValidateMatchBlock, .stack_effect = "array -- array" },
};

fn enumVariantToSymbol(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .tagged => |t| {
            if (t.tag.parent_type == null) {
                helpers.setErrorContext(ctx, ">symbol requires an enum variant", .{});
                return error.TypeMismatch;
            }
            try ctx.stack.push(t.inner.*);
        },
        else => {
            helpers.setErrorContext(ctx, ">symbol requires an enum variant", .{});
            return error.TypeMismatch;
        },
    }
}

fn enumDataVariantToSymbol(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .tagged => |t| {
            helpers.setErrorContext(ctx, "cannot convert data-carrying enum variant '{s}' to symbol", .{t.tag.name});
            return error.TypeMismatch;
        },
        else => {
            helpers.setErrorContext(ctx, ">symbol requires an enum variant", .{});
            return error.TypeMismatch;
        },
    }
}

fn enumVariantShortName(full_name: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, full_name, ':') orelse return full_name;
    return full_name[idx + 1 ..];
}

fn stripTrailingColon(name: []const u8) []const u8 {
    if (name.len > 0 and name[name.len - 1] == ':') return name[0 .. name.len - 1];
    return name;
}

fn enumFromSymbolHelper(ctx: *Context) anyerror!void {
    const tv_val = try ctx.stack.pop();
    const enum_tv = switch (tv_val) {
        .type_val => |tv| tv,
        else => {
            helpers.setTypeMismatchError(ctx, "type", tv_val);
            return error.TypeMismatch;
        },
    };

    const symbol_val = try ctx.stack.pop();
    const variant_name = switch (symbol_val) {
        .symbol => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol", symbol_val);
            return error.TypeMismatch;
        },
    };

    const vtypes = ctx.lookupEnumVariants(enum_tv) orelse {
        helpers.setErrorContext(ctx, "unknown enum '{s}'", .{enum_tv.name});
        return error.NameError;
    };

    for (vtypes) |vtype| {
        const short_name = enumVariantShortName(vtype.name);
        if (!std.mem.eql(u8, short_name, variant_name)) continue;

        if (vtype.anon_struct != null) {
            const enum_display_name = stripTrailingColon(enum_tv.name);
            helpers.setErrorContext(
                ctx,
                "variant '{s}' of enum '{s}' carries data; use >{s} instead",
                .{ variant_name, enum_display_name, vtype.name },
            );
            return error.TypeMismatch;
        }

        const alloc = ctx.quotationAllocator();
        const inner = try alloc.create(Value);
        inner.* = .{ .symbol = short_name };
        try ctx.stack.push(.{ .tagged = .{ .tag = vtype, .inner = inner } });
        return;
    }

    helpers.setErrorContext(ctx, "unknown variant '{s}' for enum '{s}'", .{ variant_name, stripTrailingColon(enum_tv.name) });
    return error.NameError;
}

/// define-enum ( name: descriptor markers -- )
///
/// For each variant string in the descriptor's `variants` array, creates a
/// virtual type wrapping a symbol, defines a constant constructor and a
/// per-variant predicate. Also defines an aggregate predicate that matches
/// any variant of the enum.
fn nativeDefineEnum(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const unary = ctx.getDispatchUnarySentinel();

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
    defer container_backing.releaseValue(desc_val);
    const desc_map = switch (desc_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable-map", desc_val);
            return error.TypeMismatch;
        },
    };
    const variants_val = desc_map.map.get("variants") orelse {
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

    if (variants_array.len % 2 != 0) {
        helpers.setErrorContext(ctx, "enum variants must be name: type pairs (got odd count {d})", .{variants_array.len});
        return error.ParseError;
    }
    const variants_slice = try alloc.alloc(value_mod.Variant, variants_array.len / 2);
    {
        var vi: usize = 0;
        while (vi < variants_array.len) : (vi += 2) {
            const variant_name_val = variants_array[vi];
            const raw_name = switch (variant_name_val) {
                .symbol => |s| s,
                else => {
                    helpers.setTypeMismatchError(ctx, "symbol", variant_name_val);
                    return error.TypeMismatch;
                },
            };
            const bare_name = if (raw_name.len > 1 and raw_name[raw_name.len - 1] == ':')
                raw_name[0 .. raw_name.len - 1]
            else
                raw_name;
            const type_v = variants_array[vi + 1];
            const tv_ptr = switch (type_v) {
                .type_val => |t| t,
                else => {
                    helpers.setTypeMismatchError(ctx, "type", type_v);
                    return error.TypeMismatch;
                },
            };
            variants_slice[vi / 2] = .{ .name = bare_name, .type_val = tv_ptr };
        }
    }

    const enum_desc = try value_mod.createTypeDescriptor(
        alloc,
        .{ .enum_ = .{ .variants = variants_slice } },
        .{},
    );

    // Create a TypeValue for the enum type itself
    const enum_tv = try alloc.create(value_mod.TypeValue);
    enum_tv.* = .{ .name = enum_name, .descriptor = enum_desc };

    // NAME: ( -- type ) - the enum type pushing a TypeValue
    const type_markers = try alloc.alloc(*Marker, 3);
    type_markers[0] = @constCast(&markers_mod.parse_time_marker);
    type_markers[1] = @constCast(&markers_mod.const_marker);
    type_markers[2] = @constCast(&markers_mod.typed_marker);

    const type_instrs = try alloc.alloc(Instruction, 1);
    type_instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = enum_tv } }, .line = 0 };

    try ctx.defineWord(enum_name, .{
        .name = enum_name,
        .parse_time = true,
        .stack_effect = try helpers.makeSimpleEffect(alloc, "-- type"),
        .markers = type_markers,
        .provenance = .{ .generator = "enum", .parent = enum_name, .role = "type" },
        .action = .{ .compound = type_instrs },
    });

    var vtype_list = std.ArrayListUnmanaged(*const VirtualType){};
    var generated_words = std.ArrayListUnmanaged(Value){};

    const unit_tv = ctx.lookupBuiltinTypeValue("unit");

    var i: usize = 0;
    while (i < variants_array.len) : (i += 2) {
        const variant_name_val = variants_array[i];
        const raw_name = switch (variant_name_val) {
            .symbol => |s| s,
            else => {
                helpers.setTypeMismatchError(ctx, "symbol", variant_name_val);
                return error.TypeMismatch;
            },
        };

        // Strip trailing colon to get the variant name
        const variant_sym = if (raw_name.len > 1 and raw_name[raw_name.len - 1] == ':')
            raw_name[0 .. raw_name.len - 1]
        else
            raw_name;

        const type_val = variants_array[i + 1];
        const tv = switch (type_val) {
            .type_val => |t| t,
            else => {
                helpers.setTypeMismatchError(ctx, "type", type_val);
                return error.TypeMismatch;
            },
        };

        const full_name = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ enum_name, variant_sym });

        if (unit_tv != null and tv == unit_tv.?) {
            // Flat variant: inner value is a symbol
            const vtype = try alloc.create(VirtualType);
            vtype.* = .{
                .name = full_name,
                .inner_type = "symbol",
                .parent_type = enum_tv,
            };
            ctx.virtual_type_count += 1;

            const variant_tv = try alloc.create(value_mod.TypeValue);
            const variant_desc = try value_mod.createTypeDescriptor(
                alloc,
                .{ .enum_variant = .{ .parent = enum_tv, .inner_type = tv } },
                .{},
            );
            variant_tv.* = .{ .name = full_name, .descriptor = variant_desc };
            vtype.type_val = variant_tv;
            variant_tv.virtual_type = vtype;

            try vtype_list.append(alloc, vtype);

            const inner = try alloc.create(Value);
            inner.* = .{ .symbol = variant_sym };

            const instrs = try alloc.alloc(Instruction, 1);
            instrs[0] = .{ .op = .{ .push_literal = .{ .tagged = .{ .tag = vtype, .inner = inner } } }, .line = 0 };

            const variant_effect_str = try std.fmt.allocPrint(alloc, "-- {s}", .{full_name});
            try ctx.defineWord(full_name, .{
                .name = full_name,
                .stack_effect = try helpers.makeSimpleEffect(alloc, variant_effect_str),
                .markers = markers_slice,
                .provenance = .{ .generator = "enum", .parent = enum_name, .role = "variant-constructor" },
                .action = .{ .compound = instrs },
            });

            const pred_name = try std.fmt.allocPrint(alloc, "{s}:{s}?", .{ enum_name, variant_sym });
            try virtual.definePredicate(ctx, pred_name, vtype, markers_slice);
            try ctx.dispatch.registerNative(ctx.resolveDispatchId(">symbol").?, variant_tv, unary, enumVariantToSymbol);

            try generated_words.append(alloc, .{ .string = full_name });
            try generated_words.append(alloc, .{ .string = pred_name });
        } else {
            // Data-carrying variant: look up the pre-defined StructType
            const maker_name = try std.fmt.allocPrint(alloc, "make-{s}", .{tv.name});
            const struct_type = structs.getStructTypeFromMaker(ctx, maker_name) orelse {
                helpers.setErrorContext(ctx, "enum variant type must be unit or a struct type, got '{s}'", .{tv.name});
                return error.TypeMismatch;
            };

            const vtype = try alloc.create(VirtualType);
            vtype.* = .{
                .name = full_name,
                .inner_type = full_name,
                .parent_type = enum_tv,
                .anon_struct = struct_type,
            };
            ctx.virtual_type_count += 1;

            const variant_tv = try alloc.create(value_mod.TypeValue);
            const variant_desc = try value_mod.createTypeDescriptor(
                alloc,
                .{ .enum_variant = .{ .parent = enum_tv, .inner_type = tv } },
                .{},
            );
            variant_tv.* = .{ .name = full_name, .descriptor = variant_desc };
            vtype.type_val = variant_tv;
            variant_tv.virtual_type = vtype;

            try vtype_list.append(alloc, vtype);

            const wrap_name = try std.fmt.allocPrint(alloc, ">{s}", .{full_name});
            try virtual.defineStructWrap(ctx, wrap_name, vtype, markers_slice);

            const make_name_word = try std.fmt.allocPrint(alloc, "make-{s}", .{full_name});
            try virtual.defineStructWrap(ctx, make_name_word, vtype, markers_slice);

            const unmake_name = try std.fmt.allocPrint(alloc, "unmake-{s}", .{full_name});
            try virtual.defineStructUnwrap(ctx, unmake_name, vtype, markers_slice);

            const destruct_name = try std.fmt.allocPrint(alloc, "{s}>", .{full_name});
            try virtual.defineStructUnwrap(ctx, destruct_name, vtype, markers_slice);

            const to_hash_name = try std.fmt.allocPrint(alloc, "{s}>hash", .{full_name});
            try virtual.defineVirtualToHash(ctx, to_hash_name, vtype, markers_slice);

            const hash_instrs = try alloc.alloc(Instruction, 2);
            hash_instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = vtype.type_val.? } }, .line = 0 };
            hash_instrs[1] = .{ .op = .{ .call_word = "native.virtual-struct-to-hash" }, .line = 0 };
            try virtual.registerHashDispatch(ctx, vtype.type_val.?, hash_instrs);

            const pred_name = try std.fmt.allocPrint(alloc, "{s}?", .{full_name});
            try virtual.definePredicate(ctx, pred_name, vtype, markers_slice);
            try ctx.dispatch.registerNative(ctx.resolveDispatchId(">symbol").?, variant_tv, unary, enumDataVariantToSymbol);

            try generated_words.append(alloc, .{ .string = wrap_name });
            try generated_words.append(alloc, .{ .string = make_name_word });
            try generated_words.append(alloc, .{ .string = unmake_name });
            try generated_words.append(alloc, .{ .string = destruct_name });
            try generated_words.append(alloc, .{ .string = to_hash_name });
            try generated_words.append(alloc, .{ .string = pred_name });
        }
    }

    // Aggregate predicate
    const agg_pred_name = try std.fmt.allocPrint(alloc, "{s}?", .{enum_name});
    const agg_instrs = try alloc.alloc(Instruction, 2);
    agg_instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = enum_tv } }, .line = 0 };
    agg_instrs[1] = .{ .op = .{ .call_word = "native.enum-aggregate-predicate" }, .line = 0 };

    try ctx.defineWord(agg_pred_name, .{
        .name = agg_pred_name,
        .stack_effect = try helpers.makeSimpleEffect(alloc, "val -- ?"),
        .markers = markers_slice,
        .provenance = .{ .generator = "enum", .parent = enum_name, .role = "predicate" },
        .action = .{ .compound = agg_instrs },
    });

    const enum_display_name = stripTrailingColon(enum_name);
    const convert_name = try std.fmt.allocPrint(alloc, ">{s}", .{enum_display_name});
    const convert_effect = try std.fmt.allocPrint(alloc, "symbol -- {s}", .{enum_display_name});
    const convert_instrs = try alloc.alloc(Instruction, 2);
    convert_instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = enum_tv } }, .line = 0 };
    convert_instrs[1] = .{ .op = .{ .call_word = "native.enum-from-symbol" }, .line = 0 };

    const convert_markers = try alloc.alloc(*Marker, markers_slice.len + 1);
    for (markers_slice, 0..) |mk, mi| convert_markers[mi] = mk;
    convert_markers[markers_slice.len] = @constCast(&markers_mod.generic_marker);

    try ctx.defineWord(convert_name, .{
        .name = convert_name,
        .stack_effect = try helpers.makeSimpleEffect(alloc, convert_effect),
        .markers = convert_markers,
        .provenance = .{ .generator = "enum", .parent = enum_name, .role = "conversion" },
        .action = .{ .compound = convert_instrs },
    });

    if (ctx.lookupBuiltinTypeValue("symbol")) |symbol_tv| {
        const did = ctx.lookupWord(convert_name).?.dispatch_id;
        try ctx.registerDispatch(.{
            .dispatch_id = did,
            .type_a = symbol_tv.descriptor.?,
            .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
        }, .{ .body = .{ .quotation = convert_instrs } }, true);
    }

    try generated_words.append(alloc, .{ .string = agg_pred_name });
    try generated_words.append(alloc, .{ .string = convert_name });
    try generated_words.append(alloc, .{ .string = try alloc.dupe(u8, enum_name) });
    const gw_slice = try generated_words.toOwnedSlice(alloc);
    enum_tv.generated_words = gw_slice;
    try ctx.registerTypeDescriptor(enum_name, enum_desc);

    const vtypes_slice = try vtype_list.toOwnedSlice(alloc);
    try ctx.registerEnumVariants(enum_tv, vtypes_slice);
}

/// Trampoline helper ( value enum-type-val -- bool )
///
/// Checks whether the value is a tagged virtual type whose parent_type matches
/// the given enum TypeValue pointer.
fn enumAggregatePredicateHelper(ctx: *Context) anyerror!void {
    const tv_val = try ctx.stack.pop();
    const enum_tv_ptr = switch (tv_val) {
        .type_val => |tv| tv,
        else => {
            helpers.setTypeMismatchError(ctx, "type", tv_val);
            return error.TypeMismatch;
        },
    };

    const val = try ctx.stack.pop();
    const is_match = switch (val) {
        .tagged => |t| t.tag.parent_type == enum_tv_ptr,
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
            if (t.tag.parent_type) |pt| {
                try ctx.stack.push(.{ .string = pt.name });
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

    const enum_tv = ctx.lookupTypeValueByName(enum_name) orelse {
        helpers.setErrorContext(ctx, "unknown enum '{s}'", .{enum_name});
        return error.NameError;
    };
    const vtypes = ctx.lookupEnumVariants(enum_tv) orelse {
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

    const parent_tv = tag.tag.parent_type orelse {
        helpers.setErrorContext(ctx, "match requires an enum variant, got virtual type '{s}'", .{tag.tag.name});
        return error.TypeMismatch;
    };

    if (branches.len % 2 != 0) {
        helpers.setErrorContext(ctx, "match branches must be symbol-quotation pairs (got odd count {d})", .{branches.len});
        return error.ParseError;
    }

    const vtypes = ctx.lookupEnumVariants(parent_tv) orelse {
        helpers.setErrorContext(ctx, "unknown enum '{s}'", .{parent_tv.name});
        return error.NameError;
    };

    const alloc = ctx.quotationAllocator();

    var matched_body: ?value_mod.Quotation = null;
    var default_body: ?value_mod.Quotation = null;
    var seen = std.StringHashMapUnmanaged(void){};
    var has_default = false;

    var i: usize = 0;
    while (i < branches.len) : (i += 2) {
        const key_val = branches[i];
        const is_default = switch (key_val) {
            .symbol => |s| std.mem.eql(u8, s, "_"),
            .string => |s| std.mem.eql(u8, s, "_"),
            else => false,
        };
        const key = switch (key_val) {
            .symbol => |s| s,
            .string => |s| if (std.mem.eql(u8, s, "_")) s else {
                helpers.setErrorContext(ctx, "match branch key must be a symbol, got string", .{});
                return error.TypeMismatch;
            },
            else => {
                helpers.setErrorContext(ctx, "match branch key must be a symbol, got {s}", .{helpers.valueTypeName(key_val)});
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

        if (is_default) {
            if (has_default) {
                helpers.setErrorContext(ctx, "duplicate default '_' branch in match", .{});
                return error.ParseError;
            }
            has_default = true;
            default_body = body;
            continue;
        }

        var valid = false;
        for (vtypes) |vt| {
            if (std.mem.eql(u8, vt.name, key)) {
                valid = true;
                break;
            }
        }
        if (!valid) {
            helpers.setErrorContext(ctx, "'{s}' is not a variant of enum '{s}'", .{ key, parent_tv.name });
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

    // Exhaustiveness check: all variants must be covered unless a default exists
    if (!has_default) {
        for (vtypes) |vt| {
            if (!seen.contains(vt.name)) {
                helpers.setErrorContext(ctx, "missing match branch for variant '{s}'", .{vt.name});
                return error.ParseError;
            }
        }
    }

    if (matched_body) |body| {
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
    } else if (default_body) |body| {
        // Default branch receives the raw tagged value, not unwrapped
        try ctx.stack.push(val);
        try ctx.executeQuotation(body);
    } else {
        unreachable;
    }
}

const EnumInfo = struct {
    enum_tv: *const value_mod.TypeValue,
    variants: []const *const VirtualType,

    fn name(self: EnumInfo) []const u8 {
        return self.enum_tv.name;
    }
};

/// Look up which enum a variant belongs to by searching the enum registry.
fn lookupVariantEnum(ctx: *const Context, variant_name: []const u8) ?EnumInfo {
    const registries = [_]struct { ctx: *const Context }{.{ .ctx = ctx }};
    _ = registries;

    var search_ctx: ?*const Context = ctx;
    while (search_ctx) |c| {
        var fi = c.type_registry_frames.items.len;
        while (fi > 0) {
            fi -= 1;
            var it = c.type_registry_frames.items[fi].enum_registry.iterator();
            while (it.next()) |entry| {
                for (entry.value_ptr.*) |vt| {
                    if (std.mem.eql(u8, vt.name, variant_name)) {
                        return .{ .enum_tv = entry.key_ptr.*, .variants = entry.value_ptr.* };
                    }
                }
            }
        }
        search_ctx = c.parent_context;
    }
    return null;
}

/// validate-match-block ( array -- array )
///
/// Validates the alternating symbol/quotation array from parse-values-until
/// against the enum registry. Discovers the enum from the first variant,
/// checks all variants belong to the same enum, checks for duplicates,
/// and checks exhaustiveness.
fn nativeValidateMatchBlock(ctx: *Context) anyerror!void {
    const arr_val = try ctx.stack.pop();
    const arr = switch (arr_val) {
        .array => |a| a,
        else => {
            helpers.setTypeMismatchError(ctx, "array", arr_val);
            return error.TypeMismatch;
        },
    };

    if (arr.len == 0) {
        helpers.setErrorContext(ctx, "match: empty branch block", .{});
        return error.ParseError;
    }

    if (arr.len % 2 != 0) {
        helpers.setErrorContext(ctx, "match: branches must be symbol-quotation pairs (got odd count {d})", .{arr.len});
        return error.ParseError;
    }

    const alloc = ctx.quotationAllocator();
    var seen = std.StringHashMapUnmanaged(void){};
    var has_default = false;
    var enum_info: ?EnumInfo = null;

    var i: usize = 0;
    while (i < arr.len) : (i += 2) {
        // Key: symbol (variant name) or string "_" for default
        const key_val = arr[i];
        const is_default = switch (key_val) {
            .symbol => |s| std.mem.eql(u8, s, "_"),
            .string => |s| std.mem.eql(u8, s, "_"),
            else => false,
        };
        const key = switch (key_val) {
            .symbol => |s| s,
            .string => |s| s,
            else => {
                helpers.setErrorContext(ctx, "match: expected symbol or quotation, got {s}", .{helpers.valueTypeName(key_val)});
                return error.TypeMismatch;
            },
        };

        // Body: quotation
        const body_val = arr[i + 1];
        switch (body_val) {
            .quotation => {},
            else => {
                helpers.setErrorContext(ctx, "match: expected symbol or quotation, got {s}", .{helpers.valueTypeName(body_val)});
                return error.TypeMismatch;
            },
        }

        if (is_default) {
            if (has_default) {
                helpers.setErrorContext(ctx, "match: duplicate branch for '_'", .{});
                return error.ParseError;
            }
            has_default = true;
            continue;
        }

        // Discover enum from first named variant
        if (enum_info == null) {
            enum_info = lookupVariantEnum(ctx, key) orelse {
                helpers.setErrorContext(ctx, "match: variant '{s}' is not a known enum variant", .{key});
                return error.NameError;
            };
        } else {
            // Verify this variant belongs to the same enum
            const info = enum_info.?;
            var found = false;
            for (info.variants) |vt| {
                if (std.mem.eql(u8, vt.name, key)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                helpers.setErrorContext(ctx, "match: '{s}' is not a variant of enum '{s}'", .{ key, info.name() });
                return error.NameError;
            }
        }

        if (seen.contains(key)) {
            helpers.setErrorContext(ctx, "match: duplicate branch for '{s}'", .{key});
            return error.ParseError;
        }
        try seen.put(alloc, key, {});
    }

    // Exhaustiveness check
    if (enum_info) |info| {
        if (!has_default) {
            var missing = std.ArrayListUnmanaged([]const u8){};
            for (info.variants) |vt| {
                if (!seen.contains(vt.name)) {
                    try missing.append(alloc, vt.name);
                }
            }
            if (missing.items.len > 0) {
                var msg = std.ArrayListUnmanaged(u8){};
                try msg.appendSlice(alloc, "match: non-exhaustive for enum '");
                try msg.appendSlice(alloc, info.name());
                try msg.appendSlice(alloc, "', missing: ");
                for (missing.items, 0..) |name, j| {
                    if (j > 0) try msg.appendSlice(alloc, ", ");
                    try msg.appendSlice(alloc, name);
                }
                ctx.pending_error_message = msg.items;
                return error.ParseError;
            }
        }
    } else if (!has_default) {
        helpers.setErrorContext(ctx, "match: no named variants and no default branch", .{});
        return error.ParseError;
    }

    try ctx.stack.push(arr_val);
}
