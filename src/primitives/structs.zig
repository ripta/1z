const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const StructType = value_mod.StructType;
const StructInstance = value_mod.StructInstance;
const Marker = value_mod.Marker;
const markers_mod = @import("markers.zig");

const helpers = @import("helpers.zig");

const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "define-struct", .stack_effect = "name: descriptor markers --", .doc = "Define a struct type and its accessor words.", .func = nativeDefineStruct },
    .{ .name = "parse-struct-fields", .stack_effect = "-- fields", .doc = "Parse field names until } from tokenizer.", .func = nativeParseStructFields },
};

/// parse-struct-fields ( -- fields ) - Parse field names until } from tokenizer
/// Returns an array of field name symbols
fn nativeParseStructFields(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer orelse return error.NoTokenizerAvailable;
    const alloc = ctx.quotationAllocator();

    var fields = std.ArrayListUnmanaged(Value){};

    while (tokenizer.next()) |tok| {
        if (tok.kind == .comment or tok.kind == .doc_comment or tok.kind == .newline) continue;

        const token = tok.text;
        if (std.mem.eql(u8, token, "}")) {
            break;
        }

        if (token.len > 1 and token[token.len - 1] == ':') {
            const field_name = try alloc.dupe(u8, token[0 .. token.len - 1]);
            try fields.append(alloc, .{ .symbol = field_name });
        } else {
            const field_name = try alloc.dupe(u8, token);
            try fields.append(alloc, .{ .symbol = field_name });
        }
    }

    const fields_array = try fields.toOwnedSlice(alloc);
    try ctx.stack.push(.{ .array = fields_array });
}

/// define-struct ( name: descriptor markers -- ) - Define a struct type and its accessor words
///
/// Generates: make-NAME, >NAME, NAME?, and FIELD>> for each field
fn nativeDefineStruct(ctx: *Context) anyerror!void {
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
    const desc_map: *value_mod.MutableMap = switch (desc_val) {
        .mutable_map => |m| m,
        else => return error.TypeMismatch,
    };
    const fields_val = desc_map.get("fields") orelse return error.MissingField;
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

    const name_val = try ctx.stack.pop();
    const name = switch (name_val) {
        .symbol => |s| s,
        else => return error.TypeMismatch,
    };

    const struct_type = try alloc.create(StructType);
    struct_type.* = .{
        .name = name,
        .fields = fields_slice,
    };

    // make-NAME: ( field1 field2 ... -- instance ) - positional constructor
    const make_name = try std.fmt.allocPrint(alloc, "make-{s}", .{name});
    try defineConstructor(ctx, make_name, struct_type, markers_slice);

    // >NAME: ( hash -- instance ) - hash-to-struct converter
    const convert_name = try std.fmt.allocPrint(alloc, ">{s}", .{name});
    try defineHashConverter(ctx, convert_name, struct_type, markers_slice);

    // NAME?: ( val -- ? ) - type predicate
    const pred_name = try std.fmt.allocPrint(alloc, "{s}?", .{name});
    try defineTypePredicate(ctx, pred_name, struct_type, markers_slice);

    // FIELD>>: ( instance -- value ) - field getter
    for (fields_slice, 0..) |field, i| {
        const getter_name = try std.fmt.allocPrint(alloc, "{s}>>", .{field});
        try defineFieldGetter(ctx, getter_name, struct_type, i, markers_slice);
    }

    // >>FIELD: ( instance value -- instance ) - field setter (only if mutable)
    const has_mutable = for (markers_slice) |mk| {
        if (markers_mod.isMutableMarker(mk)) break true;
    } else false;
    if (has_mutable) {
        for (fields_slice, 0..) |field, i| {
            const setter_name = try std.fmt.allocPrint(alloc, ">>{s}", .{field});
            try defineFieldSetter(ctx, setter_name, struct_type, i, markers_slice);
        }
    }
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
        else => return error.TypeMismatch,
    };

    const field_values = try alloc.alloc(Value, st.fields.len);
    for (st.fields, 0..) |field, i| {
        if (hash.get(field)) |val| {
            field_values[i] = val;
        } else {
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
    const idx: usize = @intCast(try helpers.popInteger(ctx));
    const st = try helpers.popStructType(ctx);
    const inst = try helpers.popStructInstance(ctx);

    if (inst.struct_type != st) {
        return error.TypeMismatch;
    }

    try ctx.stack.push(inst.fields[idx]);
}

/// Trampoline helper ( instance value struct-type field-index -- instance )
fn structFieldSetHelper(ctx: *Context) anyerror!void {
    const idx: usize = @intCast(try helpers.popInteger(ctx));
    const st = try helpers.popStructType(ctx);
    const new_val = try ctx.stack.pop();
    const inst = try helpers.popStructInstance(ctx);

    if (inst.struct_type != st) {
        return error.TypeMismatch;
    }

    inst.fields[idx] = new_val;
    try ctx.stack.push(.{ .struct_instance = inst });
}

/// make-NAME: ( field1 field2 ... -- instance ) - positional constructor
fn defineConstructor(ctx: *Context, name: []const u8, struct_type: *const StructType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(&makeStructInstanceHelper)) } }, .line = 0 };
    instrs[2] = .{ .op = .{ .call_word = "(trampoline)" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .action = .{ .compound = instrs },
    });
}

// >NAME: ( hash -- instance ) - hash-to-struct converter
fn defineHashConverter(ctx: *Context, name: []const u8, struct_type: *const StructType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(&hashToStructHelper)) } }, .line = 0 };
    instrs[2] = .{ .op = .{ .call_word = "(trampoline)" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .action = .{ .compound = instrs },
    });
}

/// NAME?: ( val -- ? ) - type predicate
fn defineTypePredicate(ctx: *Context, name: []const u8, struct_type: *const StructType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(&structTypePredicateHelper)) } }, .line = 0 };
    instrs[2] = .{ .op = .{ .call_word = "(trampoline)" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .action = .{ .compound = instrs },
    });
}

/// FIELD>>: ( instance -- value ) - field getter
fn defineFieldGetter(ctx: *Context, name: []const u8, struct_type: *const StructType, field_index: usize, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 4);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .integer = @intCast(field_index) } }, .line = 0 };
    instrs[2] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(&structFieldGetHelper)) } }, .line = 0 };
    instrs[3] = .{ .op = .{ .call_word = "(trampoline)" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .action = .{ .compound = instrs },
    });
}

/// >>FIELD: ( instance value -- instance ) - field setter
fn defineFieldSetter(ctx: *Context, name: []const u8, struct_type: *const StructType, field_index: usize, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const instrs = try alloc.alloc(Instruction, 4);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .integer = @intCast(field_index) } }, .line = 0 };
    instrs[2] = .{ .op = .{ .push_literal = .{ .integer = @intCast(@intFromPtr(&structFieldSetHelper)) } }, .line = 0 };
    instrs[3] = .{ .op = .{ .call_word = "(trampoline)" }, .line = 0 };

    try ctx.defineWord(name, .{
        .name = name,
        .markers = markers,
        .action = .{ .compound = instrs },
    });
}
