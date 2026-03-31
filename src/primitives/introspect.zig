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
const Module = value_mod.Module;
const ModuleWord = value_mod.ModuleWord;

const StackEffect = @import("../stack_effect.zig").StackEffect;

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;

const markers_mod = @import("markers.zig");
const helpers = @import("helpers.zig");

pub const primitives = [_]Primitive{};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = ">word", .func = nativeToWord },
    .{ .name = "all-words", .func = nativeAllWords },
    .{ .name = "current-scope", .func = nativeCurrentScope },
    .{ .name = "defined?", .func = nativeDefined },
    .{ .name = "locally-defined?", .func = nativeLocallyDefined },
    .{ .name = "scope-frames", .func = nativeScopeFrames },
    .{ .name = "type-descriptor", .func = nativeTypeDescriptor },
    .{ .name = "word-source", .func = nativeWordSource },
    .{ .name = "quotation>effect", .func = nativeQuotationToEffect },
};

const StackEffectParam = @import("../stack_effect.zig").StackEffectParam;

fn buildStackEffectParamValue(alloc: Allocator, param: StackEffectParam) Allocator.Error!Value {
    const fields = try alloc.alloc(Value, 4);
    fields[0] = .{ .string = param.name };
    fields[1] = .{ .boolean = param.is_row_variable };
    fields[2] = if (param.quotation_effect) |nested|
        try buildStackEffectValue(alloc, nested)
    else
        .{ .boolean = false };
    fields[3] = if (param.type_annotation) |tv|
        Value{ .type_val = @constCast(tv) }
    else
        .{ .boolean = false };
    return .{ .array = fields };
}

fn buildStackEffectValue(alloc: Allocator, effect: *const StackEffect) Allocator.Error!Value {
    const inputs_arr = try alloc.alloc(Value, effect.inputs.len);
    for (effect.inputs, 0..) |param, i| {
        inputs_arr[i] = try buildStackEffectParamValue(alloc, param);
    }
    const outputs_arr = try alloc.alloc(Value, effect.outputs.len);
    for (effect.outputs, 0..) |param, i| {
        outputs_arr[i] = try buildStackEffectParamValue(alloc, param);
    }
    const se_fields = try alloc.alloc(Value, 2);
    se_fields[0] = .{ .array = inputs_arr };
    se_fields[1] = .{ .array = outputs_arr };
    return .{ .array = se_fields };
}

pub fn buildWordInfo(alloc: Allocator, ctx: *const Context, name: []const u8, word: WordDefinition) !Value {
    const effect_val: Value = if (word.stack_effect) |effect|
        try buildStackEffectValue(alloc, &effect)
    else
        .{ .boolean = false };

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

    const dispatch_pairs = try ctx.dispatchEntriesForWord(name, alloc);
    const methods_arr = try alloc.alloc(Value, dispatch_pairs.len);
    for (dispatch_pairs, 0..) |pair, i| {
        const types = if (pair.key.type_b == ctx.getDispatchUnarySentinel()) blk: {
            const t = try alloc.alloc(Value, 1);
            t[0] = .{ .string = pair.key.type_a.name };
            break :blk t;
        } else blk: {
            const t = try alloc.alloc(Value, 2);
            t[0] = .{ .string = pair.key.type_a.name };
            t[1] = .{ .string = pair.key.type_b.name };
            break :blk t;
        };

        const prov_val: Value = if (pair.entry.provenance) |dp| blk: {
            const dp_fields = try alloc.alloc(Value, 4);
            dp_fields[0] = .{ .string = dp.generator };
            dp_fields[1] = .{ .string = dp.parent };
            dp_fields[2] = .{ .string = dp.role };
            dp_fields[3] = .{ .string = dp.field };
            break :blk .{ .array = dp_fields };
        } else .{ .boolean = false };

        const method_fields = try alloc.alloc(Value, 2);
        method_fields[0] = .{ .array = types };
        method_fields[1] = prov_val;
        methods_arr[i] = .{ .array = method_fields };
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

    const is_compiled: bool = blk: {
        for (ctx.jit_dispatch.entries.items) |entry| {
            if (std.mem.eql(u8, entry.word_name, name) and entry.code_ptr != null) break :blk true;
        }
        break :blk false;
    };

    // Raw array: name stack-effect doc markers native? body methods source-loc module provenance compiled?
    const wi_fields = try alloc.alloc(Value, 11);
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
    wi_fields[10] = .{ .boolean = is_compiled };

    return .{ .array = wi_fields };
}

fn moduleWordToWordDef(name: []const u8, mw: ModuleWord) WordDefinition {
    return .{
        .name = name,
        .stack_effect = mw.stack_effect,
        .markers = mw.markers,
        .source_module = mw.source_module,
        .doc = mw.doc,
        .source_file = mw.source_file,
        .source_line = mw.source_line,
        .source_column = mw.source_column,
        .provenance = mw.provenance,
        .action = switch (mw.action) {
            .compound => |instrs| .{ .compound = instrs },
            .native => |f| .{ .native = f },
        },
    };
}

fn wordDefToModuleWord(def: WordDefinition) ModuleWord {
    return .{
        .stack_effect = def.stack_effect,
        .markers = def.markers,
        .source_module = def.source_module,
        .doc = def.doc,
        .source_file = def.source_file,
        .source_line = def.source_line,
        .source_column = def.source_column,
        .provenance = def.provenance,
        .action = switch (def.action) {
            .compound => |instrs| .{ .compound = instrs },
            .native => |f| .{ .native = f },
        },
    };
}

/// current-scope ( -- module ) - Snapshot all user-visible words into a Module value.
fn nativeCurrentScope(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const module = try alloc.create(Module);
    module.* = .{
        .name = "<scope>",
        .words = .{},
        .importable = false,
    };

    var seen: std.StringHashMapUnmanaged(void) = .{};

    const frame_cap = if (ctx.import_frame_index) |idx| idx + 1 else 0;
    var i = frame_cap;
    while (i > 0) {
        i -= 1;
        var iter = ctx.local_frames.items[i].iterator();
        while (iter.next()) |entry| {
            const gop = try seen.getOrPut(alloc, entry.key_ptr.*);
            if (!gop.found_existing) {
                try module.words.put(alloc, entry.key_ptr.*, wordDefToModuleWord(entry.value_ptr.*));
            }
        }
    }

    {
        var iter = ctx.dictionary.entries.iterator();
        while (iter.next()) |entry| {
            const gop = try seen.getOrPut(alloc, entry.key_ptr.*);
            if (!gop.found_existing) {
                try module.words.put(alloc, entry.key_ptr.*, wordDefToModuleWord(entry.value_ptr.*));
            }
        }
    }

    var ancestor = ctx.parent_context;
    while (ancestor) |anc| {
        const anc_cap = if (anc.import_frame_index) |idx| idx + 1 else 0;
        var j = anc_cap;
        while (j > 0) {
            j -= 1;
            var iter = anc.local_frames.items[j].iterator();
            while (iter.next()) |entry| {
                const gop = try seen.getOrPut(alloc, entry.key_ptr.*);
                if (!gop.found_existing) {
                    try module.words.put(alloc, entry.key_ptr.*, wordDefToModuleWord(entry.value_ptr.*));
                }
            }
        }

        {
            var iter = anc.dictionary.entries.iterator();
            while (iter.next()) |entry| {
                const gop = try seen.getOrPut(alloc, entry.key_ptr.*);
                if (!gop.found_existing) {
                    try module.words.put(alloc, entry.key_ptr.*, wordDefToModuleWord(entry.value_ptr.*));
                }
            }
        }

        ancestor = anc.parent_context;
    }

    try ctx.stack.push(.{ .module = module });
}

/// >word ( module symbol -- array ) - Look up a word in a module and return a raw 11-element array
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

    const mod_val = try ctx.stack.pop();
    const module = switch (mod_val) {
        .module => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "module", mod_val);
            return error.TypeMismatch;
        },
    };

    const mod_word = module.words.get(name) orelse {
        helpers.setErrorContext(ctx, "word not found: {s}", .{name});
        return error.NameError;
    };

    const word = moduleWordToWordDef(name, mod_word);
    try ctx.stack.push(try buildWordInfo(alloc, ctx, name, word));
}

/// type-descriptor ( symbol|type -- hash ) - Look up a type descriptor by name or type value
fn nativeTypeDescriptor(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .type_val => |tv| {
            const desc = tv.descriptor orelse {
                helpers.setErrorContext(ctx, "no type descriptor for '{s}'", .{tv.name});
                return error.NameError;
            };
            try ctx.stack.push(.{ .hash = desc });
        },
        .symbol, .string => |name| {
            const desc = ctx.lookupTypeDescriptor(name) orelse {
                helpers.setErrorContext(ctx, "no type descriptor for '{s}'", .{name});
                return error.NameError;
            };
            try ctx.stack.push(.{ .hash = desc });
        },
        else => {
            helpers.setTypeMismatchError(ctx, "symbol or type", val);
            return error.TypeMismatch;
        },
    }
}

/// locally-defined? ( name -- bool ) - Check if a word is defined in the import frame.
fn nativeLocallyDefined(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const name = switch (val) {
        .symbol => |s| s,
        .string => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol or string", val);
            return error.TypeMismatch;
        },
    };

    const idx = ctx.import_frame_index orelse {
        try ctx.stack.push(.{ .boolean = false });
        return;
    };

    const found = ctx.local_frames.items[idx].get(name) != null;
    try ctx.stack.push(.{ .boolean = found });
}

/// defined? ( module name -- bool ) - Check if a word exists in a module.
fn nativeDefined(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const name = switch (val) {
        .symbol => |s| s,
        .string => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol or string", val);
            return error.TypeMismatch;
        },
    };

    const mod_val = try ctx.stack.pop();
    const module = switch (mod_val) {
        .module => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "module", mod_val);
            return error.TypeMismatch;
        },
    };

    try ctx.stack.push(.{ .boolean = module.words.get(name) != null });
}

/// word-source ( module name -- module/f ) - Return the source module for a word, or f.
fn nativeWordSource(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const name = switch (val) {
        .symbol => |s| s,
        .string => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol or string", val);
            return error.TypeMismatch;
        },
    };

    const mod_val = try ctx.stack.pop();
    const module = switch (mod_val) {
        .module => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "module", mod_val);
            return error.TypeMismatch;
        },
    };

    if (module.words.get(name)) |word| {
        if (word.source_module) |mod| {
            try ctx.stack.push(.{ .module = @constCast(mod) });
            return;
        }
    }
    try ctx.stack.push(.{ .boolean = false });
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

/// quotation>effect ( quot -- effect-or-false ) - Extract the stack effect from a quotation.
fn nativeQuotationToEffect(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const val = try ctx.stack.pop();
    const quot = switch (val) {
        .quotation => |q| q,
        else => {
            helpers.setTypeMismatchError(ctx, "quotation", val);
            return error.TypeMismatch;
        },
    };

    if (quot.effect) |effect| {
        try ctx.stack.push(try buildStackEffectValue(alloc, effect));
    } else {
        try ctx.stack.push(.{ .boolean = false });
    }
}
