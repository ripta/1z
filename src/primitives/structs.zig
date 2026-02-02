const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const StructType = value_mod.StructType;
const StructInstance = value_mod.StructInstance;
const Marker = value_mod.Marker;
const WordDefinition = @import("../dictionary.zig").WordDefinition;
const markers_mod = @import("markers.zig");

const helpers = @import("helpers.zig");

const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "define-struct", .stack_effect = "name: fields markers --", .func = nativeDefineStruct },
    .{ .name = "parse-struct-fields", .stack_effect = "-- fields", .func = nativeParseStructFields },
};

/// parse-struct-fields ( -- fields ) - Parse field names until } from tokenizer
/// Returns an array of field name symbols
fn nativeParseStructFields(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer orelse return error.NoTokenizerAvailable;
    const alloc = ctx.quotationAllocator();

    var fields = std.ArrayListUnmanaged(Value){};

    while (tokenizer.next()) |tok| {
        if (tok.kind == .comment or tok.kind == .newline) continue;

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

/// define-struct ( name: fields markers -- ) - Define a struct type and its accessor words
/// Creates: make-NAME, >NAME, NAME?, and FIELD>> for each field
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

    const fields_val = try ctx.stack.pop();
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

/// make-NAME: ( field1 field2 ... -- instance ) - positional constructor
fn defineConstructor(ctx: *Context, name: []const u8, struct_type: *const StructType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    const NativeConstructor = struct {
        fn make(c: *Context, st: *const StructType) !void {
            const a = c.quotationAllocator();
            const num_fields = st.fields.len;

            // Pop field values in reverse order
            const field_values = try a.alloc(Value, num_fields);
            var i: usize = num_fields;
            while (i > 0) {
                i -= 1;
                field_values[i] = try c.stack.pop();
            }

            // Create struct instance
            const instance = try a.create(StructInstance);
            instance.* = .{
                .struct_type = st,
                .fields = field_values,
            };

            try c.stack.push(.{ .struct_instance = instance });
        }
    };

    // NOTE(ripta): Create a closure that captures struct_type; since Zig
    //              doesn't have closures, we'll create instructions that push
    //              the type and call a native "word".
    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "__make-struct-instance" }, .line = 0 };

    try ctx.dictionary.put(name, .{
        .name = name,
        .markers = markers,
        .action = .{ .compound = instrs },
    });

    // Define the internal helper if not already defined
    if (ctx.dictionary.get("__make-struct-instance") == null) {
        try ctx.dictionary.put("__make-struct-instance", .{
            .name = "__make-struct-instance",
            .action = .{
                .native = struct {
                    fn helper(c: *Context) anyerror!void {
                        const st = try helpers.popStructType(c);
                        try NativeConstructor.make(c, st);
                    }
                }.helper,
            },
        });
    }
}

// >NAME: ( hash -- instance ) - hash-to-struct converter
fn defineHashConverter(ctx: *Context, name: []const u8, struct_type: *const StructType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    // NOTE(ripta): Create instructions that push the type and call the converter
    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "__hash-to-struct" }, .line = 0 };

    try ctx.dictionary.put(name, .{
        .name = name,
        .markers = markers,
        .action = .{ .compound = instrs },
    });

    if (ctx.dictionary.get("__hash-to-struct") == null) {
        try ctx.dictionary.put("__hash-to-struct", .{
            .name = "__hash-to-struct",
            .action = .{
                .native = struct {
                    fn helper(c: *Context) anyerror!void {
                        const st = try helpers.popStructType(c);

                        const hash_val = try c.stack.pop();
                        const hash = switch (hash_val) {
                            .hash => |h| h,
                            else => return error.TypeMismatch,
                        };

                        const a = c.quotationAllocator();
                        const field_values = try a.alloc(Value, st.fields.len);

                        for (st.fields, 0..) |field, i| {
                            if (hash.get(field)) |val| {
                                field_values[i] = val;
                            } else {
                                return error.MissingField;
                            }
                        }

                        const instance = try a.create(StructInstance);
                        instance.* = .{
                            .struct_type = st,
                            .fields = field_values,
                        };

                        try c.stack.push(.{ .struct_instance = instance });
                    }
                }.helper,
            },
        });
    }
}

/// NAME?: ( val -- ? ) - type predicate
fn defineTypePredicate(ctx: *Context, name: []const u8, struct_type: *const StructType, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    // NOTE(ripta): Create instructions that push the type and call the predicate
    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "__struct-type?" }, .line = 0 };

    try ctx.dictionary.put(name, .{
        .name = name,
        .markers = markers,
        .action = .{ .compound = instrs },
    });

    // Define the internal helper if not already defined
    if (ctx.dictionary.get("__struct-type?") == null) {
        try ctx.dictionary.put("__struct-type?", .{
            .name = "__struct-type?",
            .action = .{
                .native = struct {
                    fn helper(c: *Context) anyerror!void {
                        const st = try helpers.popStructType(c);

                        const val = try c.stack.pop();
                        const is_instance = switch (val) {
                            .struct_instance => |si| si.struct_type == st,
                            else => false,
                        };

                        try c.stack.push(.{ .boolean = is_instance });
                    }
                }.helper,
            },
        });
    }
}

/// FIELD>>: ( instance -- value ) - field getter
fn defineFieldGetter(ctx: *Context, name: []const u8, struct_type: *const StructType, field_index: usize, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    // NOTE(ripta): Create instructions that push the type, index, and call the getter
    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .integer = @intCast(field_index) } }, .line = 0 };
    instrs[2] = .{ .op = .{ .call_word = "__struct-field-get" }, .line = 0 };

    try ctx.dictionary.put(name, .{
        .name = name,
        .markers = markers,
        .action = .{ .compound = instrs },
    });

    if (ctx.dictionary.get("__struct-field-get") == null) {
        try ctx.dictionary.put("__struct-field-get", .{
            .name = "__struct-field-get",
            .action = .{
                .native = struct {
                    fn helper(c: *Context) anyerror!void {
                        const idx: usize = @intCast(try helpers.popInteger(c));
                        const st = try helpers.popStructType(c);
                        const inst = try helpers.popStructInstance(c);

                        // Type check
                        if (inst.struct_type != st) {
                            return error.TypeMismatch;
                        }

                        try c.stack.push(inst.fields[idx]);
                    }
                }.helper,
            },
        });
    }
}

/// >>FIELD: ( instance value -- instance ) - field setter
fn defineFieldSetter(ctx: *Context, name: []const u8, struct_type: *const StructType, field_index: usize, markers: []const *Marker) !void {
    const alloc = ctx.quotationAllocator();

    // Create instructions that push the type, index, and call the setter
    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .op = .{ .push_literal = .{ .struct_type = @constCast(struct_type) } }, .line = 0 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .integer = @intCast(field_index) } }, .line = 0 };
    instrs[2] = .{ .op = .{ .call_word = "__struct-field-set" }, .line = 0 };

    try ctx.dictionary.put(name, .{
        .name = name,
        .markers = markers,
        .action = .{ .compound = instrs },
    });

    if (ctx.dictionary.get("__struct-field-set") == null) {
        try ctx.dictionary.put("__struct-field-set", .{
            .name = "__struct-field-set",
            .action = .{
                .native = struct {
                    fn helper(c: *Context) anyerror!void {
                        const idx: usize = @intCast(try helpers.popInteger(c));
                        const st = try helpers.popStructType(c);
                        const new_val = try c.stack.pop();
                        const inst = try helpers.popStructInstance(c);

                        // Type check
                        if (inst.struct_type != st) {
                            return error.TypeMismatch;
                        }

                        // Mutate the field in place
                        inst.fields[idx] = new_val;
                        try c.stack.push(.{ .struct_instance = inst });
                    }
                }.helper,
            },
        });
    }
}
