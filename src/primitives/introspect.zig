const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;
const dispatch_mod = @import("../dispatch.zig");
const dictionary_mod = @import("../dictionary.zig");
const WordDefinition = dictionary_mod.WordDefinition;
const WordProvenance = dictionary_mod.WordProvenance;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const HashTable = value_mod.HashTable;

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;

const helpers = @import("helpers.zig");

pub const primitives = [_]Primitive{};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = ">word", .func = nativeToWord },
    .{ .name = "all-words", .func = nativeAllWords },
    .{ .name = "scope-frames", .func = nativeScopeFrames },
};

fn buildWordInfo(alloc: Allocator, ctx: *const Context, name: []const u8, word: WordDefinition) !Value {
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
        break :blk .{ .array = se_fields };
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
        break :blk .{ .array = sl_fields };
    } else .{ .boolean = false };

    const module_val: Value = if (word.source_module) |mod|
        .{ .module = @constCast(mod) }
    else
        .{ .boolean = false };

    const provenance_val: Value = if (word.provenance) |p| blk: {
        const prov_fields = try alloc.alloc(Value, 3);
        prov_fields[0] = .{ .string = p.generator };
        prov_fields[1] = .{ .string = p.parent };
        prov_fields[2] = .{ .string = p.role };
        break :blk .{ .array = prov_fields };
    } else .{ .boolean = false };

    // Raw array: name stack-effect doc markers native? body methods source-loc module provenance
    const wi_fields = try alloc.alloc(Value, 10);
    wi_fields[0] = .{ .string = name };
    wi_fields[1] = effect_val;
    wi_fields[2] = doc_val;
    wi_fields[3] = .{ .array = markers_arr };
    wi_fields[4] = .{ .boolean = is_native };
    wi_fields[5] = body_val;
    wi_fields[6] = .{ .array = methods_arr };
    wi_fields[7] = source_loc_val;
    wi_fields[8] = module_val;
    wi_fields[9] = provenance_val;

    return .{ .array = wi_fields };
}

/// >word ( symbol -- array ) - Look up a word by symbol name and return a raw 9-element array
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

    const word = ctx.lookupUserVisibleWord(name) orelse {
        helpers.setErrorContext(ctx, "word not found: {s}", .{name});
        return error.NameError;
    };

    try ctx.stack.push(try buildWordInfo(alloc, ctx, name, word));
}

/// all-words ( -- array ) - Return an array of raw word-info arrays for every visible word.
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

    var seen: std.StringHashMapUnmanaged(void) = .{};
    var results: std.ArrayListUnmanaged(Value) = .{};

    try collectFrameWords(alloc, ctx, ctx, &seen, &results);

    var ancestor = ctx.parent_context;
    while (ancestor) |anc| {
        try collectFrameWords(alloc, ctx, anc, &seen, &results);
        ancestor = anc.parent_context;
    }

    try ctx.stack.push(.{ .array = results.items });
}

/// scope-frames ( -- array ) - Return an array of frame descriptor hashes for the full scope chain.
fn nativeScopeFrames(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    var results: std.ArrayListUnmanaged(Value) = .{};

    try collectScopeFrames(alloc, ctx, "", &results);

    var ancestor = ctx.parent_context;
    while (ancestor) |anc| {
        try collectScopeFrames(alloc, anc, "parent-", &results);
        ancestor = anc.parent_context;
    }

    try ctx.stack.push(.{ .array = results.items });
}

fn buildFrameHash(
    alloc: Allocator,
    type_name: []const u8,
    index: i64,
    frame_words: anytype,
    is_import_frame: bool,
) !Value {
    const hash = try alloc.create(HashTable);
    hash.* = HashTable{};

    try hash.put(alloc, "type", .{ .string = type_name });
    try hash.put(alloc, "index", .{ .fixnum = index });
    try hash.put(alloc, "import-frame?", .{ .boolean = is_import_frame });

    var word_names: std.ArrayListUnmanaged(Value) = .{};
    var count: i64 = 0;

    var iter = frame_words.iterator();
    while (iter.next()) |entry| {
        try word_names.append(alloc, .{ .string = entry.key_ptr.* });
        count += 1;
    }

    try hash.put(alloc, "words", .{ .array = word_names.items });
    try hash.put(alloc, "count", .{ .fixnum = count });

    return .{ .hash = hash };
}

fn collectScopeFrames(
    alloc: Allocator,
    source_ctx: *const Context,
    prefix: []const u8,
    results: *std.ArrayListUnmanaged(Value),
) !void {
    const local_type = if (prefix.len > 0) "parent-local-frame" else "local-frame";
    const dict_type = if (prefix.len > 0) "parent-global-dict" else "global-dict";

    var i = source_ctx.local_frames.items.len;
    while (i > 0) {
        i -= 1;
        const is_import = source_ctx.import_frame_index != null and i == source_ctx.import_frame_index.?;
        try results.append(alloc, try buildFrameHash(
            alloc,
            local_type,
            @intCast(i),
            &source_ctx.local_frames.items[i],
            is_import,
        ));
    }

    try results.append(alloc, try buildFrameHash(
        alloc,
        dict_type,
        -1,
        &source_ctx.dictionary.entries,
        false,
    ));
}

/// Collect words from a single context's local frames and dictionary,
/// skipping any names already in `seen`. Only iterates frames up to
/// import_frame_index to exclude transient frames pushed during word
/// execution (module deps frames, combinator frames).
fn collectFrameWords(
    alloc: std.mem.Allocator,
    lookup_ctx: *Context,
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
                try results.append(alloc, try buildWordInfo(alloc, lookup_ctx, entry.key_ptr.*, entry.value_ptr.*));
            }
        }
    }
    var dict_iter = source_ctx.dictionary.entries.iterator();
    while (dict_iter.next()) |entry| {
        const gop = try seen.getOrPut(alloc, entry.key_ptr.*);
        if (!gop.found_existing) {
            try results.append(alloc, try buildWordInfo(alloc, lookup_ctx, entry.key_ptr.*, entry.value_ptr.*));
        }
    }
}
