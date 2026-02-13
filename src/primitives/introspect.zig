const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const StructType = value_mod.StructType;
const StructInstance = value_mod.StructInstance;

const structs_mod = @import("structs.zig");
const getStructTypeFromMaker = structs_mod.getStructTypeFromMaker;

const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");

pub const primitives = [_]Primitive{
    .{ .name = ">word", .stack_effect = "symbol -- word-info", .doc = "Look up a word by symbol name. Returns a word-info struct. Throws NameError if the word is not found.", .func = nativeToWord },
};

/// >word ( symbol -- word-info ) - Look up a word by symbol name and return structured word-info
fn nativeToWord(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const val = try ctx.stack.pop();
    const name = switch (val) {
        .symbol => |s| s,
        .string => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol", val);
            return error.TypeMismatch;
        },
    };

    const word = ctx.lookupWord(name) orelse {
        helpers.setErrorContext(ctx, "word not found: {s}", .{name});
        return error.NameError;
    };

    // NOTE(ripta): Structs are defined as part of the prelude, which means we need to reach into the context
    //              to retrieve the definitions for word-info, stack-effect, and source-loc structs.
    //              This couples the native word `>word` to a specific prelude implementation.
    //              It moreover couples a specific contract, i.e., `make-NAME` words.
    const word_info_st = getStructTypeFromMaker(ctx, "make-word-info") orelse {
        helpers.setErrorContext(ctx, "word-info struct type not found", .{});
        return error.NameError;
    };
    const stack_effect_st = getStructTypeFromMaker(ctx, "make-stack-effect") orelse {
        helpers.setErrorContext(ctx, "stack-effect struct type not found", .{});
        return error.NameError;
    };
    const source_loc_st = getStructTypeFromMaker(ctx, "make-source-loc") orelse {
        helpers.setErrorContext(ctx, "source-loc struct type not found", .{});
        return error.NameError;
    };

    const effect_val: Value = if (word.stack_effect) |effect| blk: {
        const inputs_arr = try alloc.alloc(Value, effect.inputs.len);
        for (effect.inputs, 0..) |param, i| {
            inputs_arr[i] = .{ .string = param.name };
        }
        const outputs_arr = try alloc.alloc(Value, effect.outputs.len);
        for (effect.outputs, 0..) |param, i| {
            outputs_arr[i] = .{ .string = param.name };
        }
        const se_fields = try alloc.alloc(Value, 2);
        se_fields[0] = .{ .array = inputs_arr };
        se_fields[1] = .{ .array = outputs_arr };
        const se_instance = try alloc.create(StructInstance);
        se_instance.* = .{ .struct_type = stack_effect_st, .fields = se_fields };
        break :blk .{ .struct_instance = se_instance };
    } else .{ .boolean = false };

    const markers_arr = try alloc.alloc(Value, word.markers.len);
    for (word.markers, 0..) |mk, i| {
        markers_arr[i] = .{ .marker = mk };
    }

    const is_native: bool = switch (word.action) {
        .compound => false,
        .native => true,
    };

    const body_val: Value = switch (word.action) {
        .compound => |instrs| .{ .quotation = .{ .instructions = instrs } },
        .native => .{ .boolean = false },
    };

    const source_loc_val: Value = if (word.source_file) |file| blk: {
        const sl_fields = try alloc.alloc(Value, 3);
        sl_fields[0] = .{ .string = file };
        sl_fields[1] = .{ .integer = @intCast(word.source_line) };
        sl_fields[2] = .{ .integer = @intCast(word.source_column) };
        const sl_instance = try alloc.create(StructInstance);
        sl_instance.* = .{ .struct_type = source_loc_st, .fields = sl_fields };
        break :blk .{ .struct_instance = sl_instance };
    } else .{ .boolean = false };

    const module_val: Value = if (word.source_module) |mod|
        .{ .module = @constCast(mod) }
    else .{ .boolean = false };

    const wi_fields = try alloc.alloc(Value, 7);
    wi_fields[0] = .{ .string = name };
    wi_fields[1] = effect_val;
    wi_fields[2] = .{ .array = markers_arr };
    wi_fields[3] = .{ .boolean = is_native };
    wi_fields[4] = body_val;
    wi_fields[5] = source_loc_val;
    wi_fields[6] = module_val;
    const wi_instance = try alloc.create(StructInstance);
    wi_instance.* = .{ .struct_type = word_info_st, .fields = wi_fields };

    try ctx.stack.push(.{ .struct_instance = wi_instance });
}
