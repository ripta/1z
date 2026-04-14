const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;
const dispatch_mod = @import("../dispatch.zig");
const dictionary_mod = @import("../dictionary.zig");
const WordDefinition = dictionary_mod.WordDefinition;
const WordProvenance = dictionary_mod.WordProvenance;
const call_graph_mod = @import("../call_graph.zig");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const HashTable = value_mod.HashTable;
const Module = value_mod.Module;
const ModuleWord = value_mod.ModuleWord;
const MutableMap = value_mod.MutableMap;

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
    .{ .name = "dead-definitions", .func = nativeDeadDefinitions },
    .{ .name = "defined?", .func = nativeDefined },
    .{ .name = "locally-defined?", .func = nativeLocallyDefined },
    .{ .name = "scope-frames", .func = nativeScopeFrames },
    .{ .name = "stack-snapshot", .func = nativeStackSnapshot },
    .{ .name = "type-descriptor", .func = nativeTypeDescriptor },
    .{ .name = "type-generated-words", .func = nativeTypeGeneratedWords },
    .{ .name = "type-info-string", .func = nativeTypeInfoString },
    .{ .name = "word-source", .func = nativeWordSource },
    .{ .name = "quotation>effect", .func = nativeQuotationToEffect },
    .{ .name = "quotation>opcodes", .func = nativeQuotationToOpcodes },
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
        .native, .host_callback => true,
    };

    const body_val: Value = switch (word.action) {
        .compound => |instrs| .{ .quotation = .{ .instructions = instrs } },
        .native, .host_callback => .{ .boolean = false },
    };

    const dispatch_pairs = try ctx.dispatchEntriesForWord(name, alloc);
    const methods_arr = try alloc.alloc(Value, dispatch_pairs.len);
    for (dispatch_pairs, 0..) |pair, i| {
        const type_a_name = ctx.lookupTypeNameByDescriptor(pair.key.type_a) orelse "<unknown>";
        const type_b_name = ctx.lookupTypeNameByDescriptor(pair.key.type_b) orelse "<unknown>";
        const types = if (pair.key.type_b == ctx.getDispatchUnarySentinel().descriptor.?) blk: {
            const t = try alloc.alloc(Value, 1);
            t[0] = .{ .string = type_a_name };
            break :blk t;
        } else blk: {
            const t = try alloc.alloc(Value, 2);
            t[0] = .{ .string = type_a_name };
            t[1] = .{ .string = type_b_name };
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
        .dispatch_id = mw.dispatch_id,
        .action = switch (mw.action) {
            .compound => |instrs| .{ .compound = instrs },
            .native => |f| .{ .native = f },
            .host_callback => |host| .{ .host_callback = host },
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
        .dispatch_id = def.dispatch_id,
        .action = switch (def.action) {
            .compound => |instrs| .{ .compound = instrs },
            .native => |f| .{ .native = f },
            .host_callback => |host| .{ .host_callback = host },
        },
    };
}

const DeadDefinitionInfo = struct {
    name: []const u8,
    source_file: []const u8,
    source_line: usize,
    source_column: usize,
};

fn popStringArray(ctx: *Context, val: Value) anyerror![]const []const u8 {
    const alloc = ctx.quotationAllocator();
    const arr = switch (val) {
        .array => |items| items,
        else => {
            helpers.setTypeMismatchError(ctx, "array", val);
            return error.TypeMismatch;
        },
    };

    const result = try alloc.alloc([]const u8, arr.len);
    for (arr, 0..) |item, i| {
        result[i] = switch (item) {
            .string => |s| s,
            else => {
                helpers.setTypeMismatchError(ctx, "string", item);
                return error.TypeMismatch;
            },
        };
    }
    return result;
}

fn moduleFromCache(cache: *const MutableMap, resolved_path: []const u8) ?*const Module {
    const cached = cache.get(resolved_path) orelse return null;
    return switch (cached) {
        .module => |m| m,
        else => null,
    };
}

fn isLintSemanticWord(name: []const u8, word: WordDefinition) bool {
    if (word.provenance != null) return false;
    if (std.mem.startsWith(u8, name, "(")) return false;
    return switch (word.action) {
        .compound => true,
        .native, .host_callback => false,
    };
}

fn componentKey(component_ids: *const std.StringHashMapUnmanaged(u32), name: []const u8) []const u8 {
    if (component_ids.get(name)) |component_id| {
        return std.fmt.comptimePrint("__scc__{d}", .{component_id});
    }
    return name;
}

fn buildDeadDefinitionValue(alloc: Allocator, info: DeadDefinitionInfo) !Value {
    const fields = try alloc.alloc(Value, 4);
    fields[0] = .{ .string = info.name };
    fields[1] = .{ .string = info.source_file };
    fields[2] = .{ .fixnum = @intCast(info.source_line) };
    fields[3] = .{ .fixnum = @intCast(info.source_column) };
    return .{ .array = fields };
}

/// dead-definitions ( cache files -- array )
/// Return array entries of [ name file line column ] for checked-file compound
/// words that have no inbound edge from another checked-file component.
fn nativeDeadDefinitions(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const files_val = try ctx.stack.pop();
    const file_paths = try popStringArray(ctx, files_val);

    const cache_val = try ctx.stack.pop();
    const cache = switch (cache_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable-map", cache_val);
            return error.TypeMismatch;
        },
    };

    var checked_files = std.StringHashMapUnmanaged(void){};
    defer checked_files.deinit(alloc);

    var dictionary = dictionary_mod.Dictionary.init(alloc);
    defer dictionary.deinit();

    var word_info = std.StringHashMapUnmanaged(DeadDefinitionInfo){};
    defer word_info.deinit(alloc);

    for (file_paths) |path| {
        const resolved = std.fs.cwd().realpathAlloc(alloc, path) catch {
            helpers.setErrorContext(ctx, "could not resolve lint path '{s}'", .{path});
            return error.FileNotFound;
        };
        try checked_files.put(alloc, resolved, {});

        const module = moduleFromCache(cache, resolved) orelse {
            helpers.setErrorContext(ctx, "lint cache missing module for '{s}'", .{resolved});
            return error.KeyNotFound;
        };

        var iter = module.words.iterator();
        while (iter.next()) |entry| {
            const name = entry.key_ptr.*;
            const word = moduleWordToWordDef(name, entry.value_ptr.*);
            if (!isLintSemanticWord(name, word)) continue;

            const gop = try dictionary.entries.getOrPut(alloc, name);
            if (!gop.found_existing) {
                gop.value_ptr.* = word;
                const source_file = word.source_file orelse continue;
                try word_info.put(alloc, name, .{
                    .name = name,
                    .source_file = source_file,
                    .source_line = word.source_line,
                    .source_column = word.source_column,
                });
            }
        }
    }

    var graph = try call_graph_mod.build(&dictionary, &ctx.dispatch, alloc);
    defer {
        var iter = graph.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.value_ptr.callees);
        }
        graph.deinit(alloc);
    }

    const sccs = try call_graph_mod.findSCCs(&graph, alloc);
    defer {
        for (sccs) |members| {
            alloc.free(members);
        }
        alloc.free(sccs);
    }

    var component_ids = std.StringHashMapUnmanaged(u32){};
    defer component_ids.deinit(alloc);

    for (sccs, 0..) |members, i| {
        const component_id: u32 = @intCast(i);
        for (members) |name| {
            try component_ids.put(alloc, name, component_id);
        }
    }

    var has_external_inbound = std.StringHashMapUnmanaged(void){};
    defer has_external_inbound.deinit(alloc);

    var graph_iter = graph.iterator();
    while (graph_iter.next()) |entry| {
        const caller_name = entry.key_ptr.*;
        if (!word_info.contains(caller_name)) continue;

        const caller_component = component_ids.get(caller_name);
        for (entry.value_ptr.callees) |callee_name| {
            if (!word_info.contains(callee_name)) continue;

            const callee_component = component_ids.get(callee_name);
            const same_component =
                caller_component != null and callee_component != null and caller_component.? == callee_component.?;
            if (same_component) continue;
            if (caller_component == null and callee_component == null and std.mem.eql(u8, caller_name, callee_name)) continue;

            try has_external_inbound.put(alloc, callee_name, {});
        }
    }

    var dead_infos = std.ArrayListUnmanaged(DeadDefinitionInfo){};
    defer dead_infos.deinit(alloc);

    var info_iter = word_info.iterator();
    while (info_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        if (has_external_inbound.contains(name)) continue;

        if (component_ids.get(name)) |component_id| {
            var component_has_external = false;
            var members_iter = component_ids.iterator();
            while (members_iter.next()) |member| {
                if (member.value_ptr.* != component_id) continue;
                if (has_external_inbound.contains(member.key_ptr.*)) {
                    component_has_external = true;
                    break;
                }
            }
            if (component_has_external) continue;
        }

        try dead_infos.append(alloc, entry.value_ptr.*);
    }

    std.mem.sort(DeadDefinitionInfo, dead_infos.items, {}, struct {
        fn lessThan(_: void, a: DeadDefinitionInfo, b: DeadDefinitionInfo) bool {
            const file_order = std.mem.order(u8, a.source_file, b.source_file);
            if (file_order != .eq) return file_order == .lt;
            if (a.source_line != b.source_line) return a.source_line < b.source_line;
            if (a.source_column != b.source_column) return a.source_column < b.source_column;
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    const result = try alloc.alloc(Value, dead_infos.items.len);
    for (dead_infos.items, 0..) |info, i| {
        result[i] = try buildDeadDefinitionValue(alloc, info);
    }
    try ctx.stack.push(.{ .array = result });
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

/// type-generated-words ( symbol|type -- array ) - Look up generated words for a type name or value
fn nativeTypeGeneratedWords(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const tv = switch (val) {
        .type_val => |tv| tv,
        .symbol, .string => |name| ctx.lookupTypeValueByName(name) orelse {
            helpers.setErrorContext(ctx, "no type value for '{s}'", .{name});
            return error.NameError;
        },
        else => {
            helpers.setTypeMismatchError(ctx, "symbol or type", val);
            return error.TypeMismatch;
        },
    };
    try ctx.stack.push(.{ .array = tv.generated_words orelse &.{} });
}

fn resolveTypeValue(ctx: *Context, val: Value) !*value_mod.TypeValue {
    return switch (val) {
        .type_val => |tv| tv,
        .symbol, .string => |name| ctx.lookupTypeValueByName(name) orelse {
            helpers.setErrorContext(ctx, "no type value for '{s}'", .{name});
            return error.NameError;
        },
        else => {
            helpers.setTypeMismatchError(ctx, "symbol or type", val);
            return error.TypeMismatch;
        },
    };
}

fn appendGeneratedWords(buf: *std.ArrayListUnmanaged(u8), alloc: Allocator, tv: *const value_mod.TypeValue) !void {
    try buf.appendSlice(alloc, "  generated-words: ");
    if (tv.generated_words) |words| {
        for (words, 0..) |word, i| {
            if (i > 0) try buf.append(alloc, ' ');
            switch (word) {
                .string => |s| try buf.appendSlice(alloc, s),
                .symbol => |s| try buf.appendSlice(alloc, s),
                else => try buf.appendSlice(alloc, try helpers.formatValueBrief(alloc, word, 256)),
            }
        }
    }
    try buf.appendSlice(alloc, "\n");
}

fn appendBoolFieldIfTrue(
    buf: *std.ArrayListUnmanaged(u8),
    alloc: Allocator,
    desc: *const value_mod.HashTable,
    key: []const u8,
) !void {
    const field = desc.get(key) orelse return;
    if (field != .boolean or !field.boolean) return;
    try buf.appendSlice(alloc, "  ");
    try buf.appendSlice(alloc, key);
    try buf.appendSlice(alloc, ": ");
    try buf.appendSlice(alloc, try helpers.formatValueBrief(alloc, field, 256));
    try buf.appendSlice(alloc, "\n");
}

/// type-info-string ( symbol|type -- string ) - Render type info for help/introspection output.
fn nativeTypeInfoString(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const tv = try resolveTypeValue(ctx, try ctx.stack.pop());
    const desc = tv.descriptor orelse {
        try ctx.stack.push(.{ .string = "" });
        return;
    };

    const kind = desc.get("type") orelse {
        try ctx.stack.push(.{ .string = "" });
        return;
    };

    var buf: std.ArrayListUnmanaged(u8) = .{};

    const kind_name = switch (kind) {
        .symbol => |sym| sym,
        .string => |s| s,
        else => "",
    };

    if (std.mem.eql(u8, kind_name, "builtin-type:") or std.mem.eql(u8, kind_name, "builtin-type")) {
        try buf.appendSlice(alloc, "type info:\n  kind: builtin-type\n");
        const ordered_keys = [_][]const u8{ "integer", "exact", "numeric", "mutable" };
        for (ordered_keys) |key| {
            try appendBoolFieldIfTrue(&buf, alloc, desc, key);
        }
    } else if (std.mem.eql(u8, kind_name, "struct-descriptor:")) {
        try buf.appendSlice(alloc, "type info:\n  kind: struct\n  fields: ");
        if (desc.get("fields")) |fields| if (fields == .array) {
            for (fields.array, 0..) |field, i| {
                if (i > 0) try buf.append(alloc, ' ');
                try buf.appendSlice(alloc, field.string);
            }
        };
        try buf.appendSlice(alloc, "\n");
        try appendGeneratedWords(&buf, alloc, tv);
    } else if (std.mem.eql(u8, kind_name, "virtual:")) {
        try buf.appendSlice(alloc, "type info:\n  kind: virtual\n");
        if (desc.get("inner-type")) |inner_raw| {
            const inner = if (inner_raw == .array and inner_raw.array.len > 0) inner_raw.array[0] else inner_raw;
            switch (inner) {
                .type_val => |inner_tv| {
                    try buf.appendSlice(alloc, "  wraps: ");
                    try buf.appendSlice(alloc, inner_tv.name);
                    try buf.appendSlice(alloc, "\n");
                },
                .mutable_map, .hash => |h| {
                    try buf.appendSlice(alloc, "  fields: ");
                    if (h.get("fields")) |fields| if (fields == .array) {
                        for (fields.array, 0..) |field, i| {
                            if (i > 0) try buf.append(alloc, ' ');
                            try buf.appendSlice(alloc, field.string);
                        }
                    };
                    try buf.appendSlice(alloc, "\n");
                },
                else => {},
            }
        }
        try appendGeneratedWords(&buf, alloc, tv);
    } else if (std.mem.eql(u8, kind_name, "enum-descriptor:")) {
        try buf.appendSlice(alloc, "type info:\n  kind: enum\n  variants:\n");
        if (desc.get("variants")) |variants| if (variants == .array) {
            var max_name_len: usize = 0;
            var i_width: usize = 0;
            while (i_width + 1 < variants.array.len) : (i_width += 2) {
                const variant_name = variants.array[i_width];
                const name_len = switch (variant_name) {
                    .symbol => |name| name.len,
                    .string => |name| name.len,
                    else => continue,
                };
                if (name_len > max_name_len) max_name_len = name_len;
            }

            var i: usize = 0;
            while (i + 1 < variants.array.len) : (i += 2) {
                const variant_name = variants.array[i];
                const variant_type = variants.array[i + 1];
                const variant_name_str = switch (variant_name) {
                    .symbol => |name| name,
                    .string => |name| name,
                    else => try helpers.formatValueBrief(alloc, variant_name, 256),
                };
                try buf.appendSlice(alloc, "    ");
                try buf.appendSlice(alloc, variant_name_str);
                try buf.appendSlice(alloc, ":");
                const padding = max_name_len - variant_name_str.len + 1;
                for (0..padding) |_| try buf.append(alloc, ' ');
                switch (variant_type) {
                    .type_val => |variant_tv| try buf.appendSlice(alloc, variant_tv.name),
                    else => try buf.appendSlice(alloc, try helpers.formatValueBrief(alloc, variant_type, 256)),
                }
                try buf.appendSlice(alloc, "\n");
            }
        };
        try appendGeneratedWords(&buf, alloc, tv);
    }

    try ctx.stack.push(.{ .string = try buf.toOwnedSlice(alloc) });
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

/// stack-snapshot ( -- string ) - Return a debug snapshot of the current data stack.
fn nativeStackSnapshot(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    var buf = std.ArrayList(u8){};
    defer buf.deinit(alloc);
    try ctx.stack.dump(buf.writer(alloc));
    try ctx.stack.push(.{ .string = try buf.toOwnedSlice(alloc) });
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

/// quotation>opcodes ( quotation -- array ) - Return instruction pairs as raw [symbol, value] arrays.
fn nativeQuotationToOpcodes(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const val = try ctx.stack.pop();
    const quot = switch (val) {
        .quotation => |q| q,
        else => {
            helpers.setTypeMismatchError(ctx, "quotation", val);
            return error.TypeMismatch;
        },
    };

    const result = try alloc.alloc(Value, quot.instructions.len);
    for (quot.instructions, 0..) |instr, i| {
        const pair = try alloc.alloc(Value, 2);
        switch (instr.op) {
            .push_literal => |lit| {
                pair[0] = .{ .symbol = "push-literal" };
                pair[1] = lit;
            },
            .call_word => |name| {
                pair[0] = .{ .symbol = "call-word" };
                pair[1] = .{ .string = name };
            },
        }
        result[i] = .{ .array = pair };
    }

    try ctx.stack.push(.{ .array = result });
}
