const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;
const dispatch_mod = @import("../dispatch.zig");
const WordDefinition = @import("../dictionary.zig").WordDefinition;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const StructType = value_mod.StructType;
const StructInstance = value_mod.StructInstance;

const structs_mod = @import("structs.zig");
const getStructTypeFromMaker = structs_mod.getStructTypeFromMaker;

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;

const helpers = @import("helpers.zig");

pub const primitives = [_]Primitive{
    .{ .name = "all-words", .stack_effect = "-- array", .doc = "Return an array of word-info structs for every word in the dictionary.", .func = nativeAllWords },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = ">word", .func = nativeToWord },
};

const StructTypes = struct {
    word_info: *const StructType,
    stack_effect: *const StructType,
    source_loc: *const StructType,
};

fn lookupStructTypes(ctx: *const Context) !StructTypes {
    // NOTE(ripta): Structs are defined as part of the prelude, which means we need to reach into the context
    //              to retrieve the definitions for word-info, stack-effect, and source-loc structs.
    //              This couples the native word `>word` to a specific prelude implementation.
    //              It moreover couples a specific contract, i.e., `make-NAME` words.
    const word_info_st = getStructTypeFromMaker(ctx, "make-word-info") orelse {
        helpers.setErrorContext(@constCast(ctx), "word-info struct type not found", .{});
        return error.NameError;
    };
    const stack_effect_st = getStructTypeFromMaker(ctx, "make-stack-effect") orelse {
        helpers.setErrorContext(@constCast(ctx), "stack-effect struct type not found", .{});
        return error.NameError;
    };
    const source_loc_st = getStructTypeFromMaker(ctx, "make-source-loc") orelse {
        helpers.setErrorContext(@constCast(ctx), "source-loc struct type not found", .{});
        return error.NameError;
    };
    return .{
        .word_info = word_info_st,
        .stack_effect = stack_effect_st,
        .source_loc = source_loc_st,
    };
}

fn buildWordInfo(alloc: Allocator, ctx: *const Context, sts: StructTypes, name: []const u8, word: WordDefinition) !Value {
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
        se_instance.* = .{ .struct_type = sts.stack_effect, .fields = se_fields };
        break :blk .{ .struct_instance = se_instance };
    } else .{ .boolean = false };

    const doc_val: Value = if (word.doc) |d|
        .{ .string = d }
    else
        .{ .boolean = false };

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

    const dispatch_keys = try ctx.dispatch.keysForWord(name, alloc);
    const methods_arr = try alloc.alloc(Value, dispatch_keys.len);
    for (dispatch_keys, 0..) |key, i| {
        if (std.mem.eql(u8, key.type_b, dispatch_mod.unary_sentinel)) {
            const types = try alloc.alloc(Value, 1);
            types[0] = .{ .string = key.type_a };
            methods_arr[i] = .{ .array = types };
        } else {
            const types = try alloc.alloc(Value, 2);
            types[0] = .{ .string = key.type_a };
            types[1] = .{ .string = key.type_b };
            methods_arr[i] = .{ .array = types };
        }
    }

    const source_loc_val: Value = if (word.source_file) |file| blk: {
        const sl_fields = try alloc.alloc(Value, 3);
        sl_fields[0] = .{ .string = file };
        sl_fields[1] = .{ .fixnum = @intCast(word.source_line) };
        sl_fields[2] = .{ .fixnum = @intCast(word.source_column) };
        const sl_instance = try alloc.create(StructInstance);
        sl_instance.* = .{ .struct_type = sts.source_loc, .fields = sl_fields };
        break :blk .{ .struct_instance = sl_instance };
    } else .{ .boolean = false };

    const module_val: Value = if (word.source_module) |mod|
        .{ .module = @constCast(mod) }
    else
        .{ .boolean = false };

    // Fields: name stack-effect doc markers native? body methods source-loc module
    const wi_fields = try alloc.alloc(Value, 9);
    wi_fields[0] = .{ .string = name };
    wi_fields[1] = effect_val;
    wi_fields[2] = doc_val;
    wi_fields[3] = .{ .array = markers_arr };
    wi_fields[4] = .{ .boolean = is_native };
    wi_fields[5] = body_val;
    wi_fields[6] = .{ .array = methods_arr };
    wi_fields[7] = source_loc_val;
    wi_fields[8] = module_val;
    const wi_instance = try alloc.create(StructInstance);
    wi_instance.* = .{ .struct_type = sts.word_info, .fields = wi_fields };

    return .{ .struct_instance = wi_instance };
}

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

    const sts = try lookupStructTypes(ctx);
    try ctx.stack.push(try buildWordInfo(alloc, ctx, sts, name, word));
}

/// all-words ( -- array ) - Return an array of word-info structs for every visible word.
///
/// Searches in order:
///
/// 1. local frames, up to import_frame_index to skip transient module-deps frames;
/// 2. the global dictionary; and
/// 3. ancestor contexts.
///
/// Higher-priority definitions shadow lower ones.
fn nativeAllWords(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const sts = try lookupStructTypes(ctx);

    var seen: std.StringHashMapUnmanaged(void) = .{};
    var results: std.ArrayListUnmanaged(Value) = .{};

    try collectFrameWords(alloc, ctx, sts, ctx, &seen, &results);

    var ancestor = ctx.parent_context;
    while (ancestor) |anc| {
        try collectFrameWords(alloc, ctx, sts, anc, &seen, &results);
        ancestor = anc.parent_context;
    }

    try ctx.stack.push(.{ .array = results.items });
}

/// Collect words from a single context's local frames and dictionary,
/// skipping any names already in `seen`. Only iterates frames up to
/// import_frame_index to exclude transient frames pushed during word
/// execution (module deps frames, combinator frames).
fn collectFrameWords(
    alloc: std.mem.Allocator,
    lookup_ctx: *Context,
    sts: StructTypes,
    source_ctx: *const Context,
    seen: *std.StringHashMapUnmanaged(void),
    results: *std.ArrayListUnmanaged(Value),
) !void {
    const frame_cap = if (source_ctx.import_frame_index) |idx| idx + 1 else 0;
    var i = frame_cap;
    while (i > 0) {
        i -= 1;
        var iter = source_ctx.local_frames.items[i].iterator();
        while (iter.next()) |entry| {
            const gop = try seen.getOrPut(alloc, entry.key_ptr.*);
            if (!gop.found_existing) {
                try results.append(alloc, try buildWordInfo(alloc, lookup_ctx, sts, entry.key_ptr.*, entry.value_ptr.*));
            }
        }
    }
    var dict_iter = source_ctx.dictionary.entries.iterator();
    while (dict_iter.next()) |entry| {
        const gop = try seen.getOrPut(alloc, entry.key_ptr.*);
        if (!gop.found_existing) {
            try results.append(alloc, try buildWordInfo(alloc, lookup_ctx, sts, entry.key_ptr.*, entry.value_ptr.*));
        }
    }
}
