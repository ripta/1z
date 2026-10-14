const std = @import("std");
const builtin = @import("builtin");
const is_freestanding = builtin.os.tag == .freestanding;
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;
const dispatch_mod = @import("../dispatch.zig");
const dictionary_mod = @import("../dictionary.zig");
const WordDefinition = dictionary_mod.WordDefinition;
const WordProvenance = dictionary_mod.WordProvenance;
const call_graph_mod = @import("../call_graph.zig");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const HashTable = value_mod.HashTable;
const TypeDescriptor = value_mod.TypeDescriptor;
const Module = value_mod.Module;
const ModuleWord = value_mod.ModuleWord;
const MutableMap = value_mod.MutableMap;
const ProtocolDescriptor = value_mod.ProtocolDescriptor;
const ConstraintCombinator = value_mod.ConstraintCombinator;

const StackEffect = @import("../stack_effect.zig").StackEffect;
const Tokenizer = @import("../tokenizer.zig").Tokenizer;
const parser_mod = @import("../parser.zig");

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;

const markers_mod = @import("markers.zig");
const helpers = @import("helpers.zig");
const container_backing = @import("../container_backing.zig");

pub const primitives = [_]Primitive{};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = ">word", .func = nativeToWord, .stack_effect = "module name -- word-info" },
    .{ .name = "all-words", .func = nativeAllWords, .stack_effect = "-- array" },
    .{ .name = "current-scope", .func = nativeCurrentScope, .stack_effect = "-- module" },
    .{ .name = "local-scope", .func = nativeLocalScope, .stack_effect = "-- module" },
    .{ .name = "module-deps", .func = nativeModuleDeps, .stack_effect = "module -- module" },
    .{ .name = ">constraint-info", .func = nativeConstraintToInfo, .stack_effect = "constraint -- array" },
    .{ .name = "dead-definitions", .func = nativeDeadDefinitions },
    .{ .name = "defined?", .func = nativeDefined, .stack_effect = "module name -- ?" },
    .{ .name = "local-word-source", .func = nativeLocalWordSource, .stack_effect = "name -- module/f" },
    .{ .name = "locally-defined?", .func = nativeLocallyDefined, .stack_effect = "name -- ?" },
    .{ .name = "scope-frames", .func = nativeScopeFrames, .stack_effect = "-- array" },
    .{ .name = "stack-snapshot", .func = nativeStackSnapshot },
    .{ .name = "type-descriptor", .func = nativeTypeDescriptor },
    .{ .name = "type-generated-words", .func = nativeTypeGeneratedWords },
    .{ .name = "type-info-string", .func = nativeTypeInfoString },
    .{ .name = "word-source", .func = nativeWordSource, .stack_effect = "module name -- module/f" },
    .{ .name = "quotation>effect", .func = nativeQuotationToEffect },
    .{ .name = ">stack-effect-info", .func = nativeStackEffectToInfo, .stack_effect = "stack-effect -- array" },
    .{ .name = "quotation>opcodes", .func = nativeQuotationToOpcodes },
    .{ .name = "parse-stack-effect", .func = nativeParseStackEffect, .stack_effect = "string -- stack-effect" },
};

const StackEffectParam = @import("../stack_effect.zig").StackEffectParam;

/// Build one `{ name row? effect annotation }` parameter record on `alloc`.
///
/// The name is an owned copy because the effect can come from a task's own storage, and the record
/// can outlive that task.
fn buildStackEffectParamValue(alloc: Allocator, param: StackEffectParam) Allocator.Error!Value {
    var fields = try helpers.ArrayBuilder.init(alloc, 4);
    errdefer fields.deinit();

    fields.items[0] = try helpers.ownedStringCopy(alloc, param.name);
    fields.items[1] = .{ .boolean = param.is_row_variable };
    fields.items[2] = if (param.quotation_effect) |nested|
        try buildStackEffectValue(alloc, nested)
    else
        .{ .boolean = false };
    fields.items[3] = if (param.type_annotation) |ann| switch (ann) {
        .type => |tv| Value{ .type_val = @constCast(tv) },
        .protocol => |pd| Value{ .protocol_descriptor = pd },
        // Surface the combinator value itself, mirroring how a protocol-bound
        // parameter surfaces its descriptor. Structured breakdown of the
        // combinator's elements is a separate introspection surface.
        .combination => |cc| Value{ .constraint_combinator = cc },
    } else .{ .boolean = false };

    return try fields.finish();
}

/// The backing of a constraint node: a base protocol or a combinator. Type
/// leaves are not records and never reach here -- they are surfaced as raw type
/// values inside a combinator's element list.
const ConstraintBacking = union(enum) {
    protocol: *const ProtocolDescriptor,
    combinator: *const ConstraintCombinator,
};

fn constraintKindSymbol(kind: ConstraintCombinator.Kind) []const u8 {
    return switch (kind) {
        .intersection => "intersection",
        .@"union" => "union",
    };
}

/// Build the raw 5-field constraint-info record `{name kind methods elements id}` from a
/// constraint backing; the prelude wraps this into the `constraint-info` struct. A combinator
/// carries no stored name, so `name_override` supplies the top-level name; pass `null` for nested
/// elements and bare-value entry points, which then report `f`.
///
/// A combinator's element list is heterogeneous: a `type` element is the raw type value, while
/// `protocol` and `combinator` elements recurse into nested records.
fn buildConstraintRecord(alloc: Allocator, backing: ConstraintBacking, name_override: ?[]const u8) Allocator.Error!Value {
    var fields = try helpers.ArrayBuilder.init(alloc, 5);
    errdefer fields.deinit();

    switch (backing) {
        .protocol => |descriptor| {
            var methods = try helpers.ArrayBuilder.init(alloc, descriptor.methods.len);
            errdefer methods.deinit();

            for (descriptor.methods, 0..) |method, i| {
                container_backing.retainValue(method);
                methods.items[i] = method;
            }

            fields.items[0] = try helpers.ownedStringCopy(alloc, name_override orelse descriptor.name);
            fields.items[1] = value_mod.symbolValue("protocol");
            fields.items[2] = try methods.finish();
            fields.items[3] = .{ .boolean = false };
            fields.items[4] = .{ .fixnum = @intCast(descriptor.protocol_id) };
        },
        .combinator => |cc| {
            var elements = try helpers.ArrayBuilder.init(alloc, cc.elements.len);
            errdefer elements.deinit();

            for (cc.elements, 0..) |el, i| {
                elements.items[i] = switch (el) {
                    .type => |tv| Value{ .type_val = @constCast(tv) },
                    .protocol => |pd| try buildConstraintRecord(alloc, .{ .protocol = pd }, null),
                    .combinator => |nested| try buildConstraintRecord(alloc, .{ .combinator = nested }, null),
                };
            }

            fields.items[0] = if (name_override) |n| try helpers.ownedStringCopy(alloc, n) else Value{ .boolean = false };
            fields.items[1] = value_mod.symbolValue(constraintKindSymbol(cc.kind));
            fields.items[2] = .{ .boolean = false };
            fields.items[3] = try elements.finish();
            fields.items[4] = .{ .fixnum = @intCast(cc.combinator_id) };
        },
    }

    return try fields.finish();
}

/// Recognize a constraint word and return the raw constraint-info record, or `f`
/// for any other shape. A constraint word's body is the single-instruction shape
/// that protocol and combinator definitions emit: a `push_literal` of a
/// `protocol_descriptor` or a `constraint_combinator`. The word name becomes the
/// top-level record's name.
fn buildConstraintInfo(alloc: Allocator, name: []const u8, word: WordDefinition) Allocator.Error!Value {
    const lit: Value = switch (word.action) {
        .literal => |v| v,
        .compound => |body| blk: {
            if (body.len != 1) return .{ .boolean = false };
            break :blk switch (body[0].op) {
                .push_literal => |v| v,
                else => return .{ .boolean = false },
            };
        },
        .native, .host_callback => return .{ .boolean = false },
    };

    return switch (lit) {
        .protocol_descriptor => |d| try buildConstraintRecord(alloc, .{ .protocol = d }, name),
        .constraint_combinator => |cc| try buildConstraintRecord(alloc, .{ .combinator = cc }, name),
        else => .{ .boolean = false },
    };
}

fn buildStackEffectValue(alloc: Allocator, effect: *const StackEffect) Allocator.Error!Value {
    var record = try helpers.ArrayBuilder.init(alloc, 2);
    errdefer record.deinit();

    var inputs = try helpers.ArrayBuilder.init(alloc, effect.inputs.len);
    errdefer inputs.deinit();
    for (effect.inputs, 0..) |param, i| {
        inputs.items[i] = try buildStackEffectParamValue(alloc, param);
    }
    record.items[0] = try inputs.finish();

    var outputs = try helpers.ArrayBuilder.init(alloc, effect.outputs.len);
    errdefer outputs.deinit();
    for (effect.outputs, 0..) |param, i| {
        outputs.items[i] = try buildStackEffectParamValue(alloc, param);
    }
    record.items[1] = try outputs.finish();

    return try record.finish();
}

/// An array of owned strings copied from `parts`.
fn buildOwnedStringsArray(alloc: Allocator, parts: []const []const u8) Allocator.Error!Value {
    var strings = try helpers.ArrayBuilder.init(alloc, parts.len);
    errdefer strings.deinit();

    for (parts, 0..) |part, i| {
        strings.items[i] = try helpers.ownedStringCopy(alloc, part);
    }

    return try strings.finish();
}

/// Build the raw word-info array on `ctx.allocator`, so the result outlives the context that
/// built it. `scratch` holds only temporaries and the one-instruction body of a literal word.
pub fn buildWordInfo(scratch: Allocator, ctx: *const Context, name: []const u8, word: WordDefinition) !Value {
    const alloc = ctx.allocator;

    // Raw array: name stack-effect doc markers native? body methods source-loc module provenance
    // compiled? protocol binding? parse-time?
    //
    // `binding?` exposes the `.literal` action the body wrapping hides, so a bracket-less
    // binding stays distinguishable from a one-literal quotation body.
    var info = try helpers.ArrayBuilder.init(alloc, 14);
    errdefer info.deinit();

    info.items[0] = try helpers.ownedStringCopy(alloc, name);

    info.items[1] = if (word.stack_effect) |effect|
        try buildStackEffectValue(alloc, effect)
    else
        .{ .boolean = false };

    info.items[2] = if (word.doc) |d|
        try helpers.ownedStringCopy(alloc, d)
    else
        .{ .boolean = false };

    var markers = try helpers.ArrayBuilder.init(alloc, word.markers.len);
    errdefer markers.deinit();
    for (word.markers, 0..) |mk, i| {
        markers.items[i] = .{ .marker = mk };
    }
    info.items[3] = try markers.finish();

    info.items[4] = .{ .boolean = switch (word.action) {
        .compound, .literal => false,
        .native, .host_callback => true,
    } };

    // A .literal word has no instruction body; wrap its value in the same
    // single-instruction shape a one-element .compound body would have
    // produced before this variant existed, so `body>>` reads the same either way.
    info.items[5] = switch (word.action) {
        .compound => |instrs| .{ .quotation = .{ .instructions = instrs } },
        .literal => |v| blk: {
            const instrs = try scratch.alloc(Instruction, 1);
            instrs[0] = .{ .op = .{ .push_literal = v }, .line = 0 };
            break :blk .{ .quotation = .{ .instructions = instrs } };
        },
        .native, .host_callback => .{ .boolean = false },
    };

    // Use the definition's own dispatch id rather than re-resolving the name
    // in scope: a module-qualified word's bare name is not in scope, and a
    // shadowed name would resolve to the wrong definition's methods.
    //
    // The analysis view includes the arms a check-mode load registered, which the linter reads
    // after the load has ended.
    const dispatch_pairs = try ctx.analysisDispatchEntriesForId(word.dispatch_id, .by_type_name, scratch);
    var methods = try helpers.ArrayBuilder.init(alloc, dispatch_pairs.len);
    errdefer methods.deinit();
    for (dispatch_pairs, 0..) |pair, i| {
        const type_a_name = ctx.lookupTypeNameByDescriptor(pair.key.type_a) orelse "<unknown>";
        const type_b_name = ctx.lookupTypeNameByDescriptor(pair.key.type_b) orelse "<unknown>";
        const is_unary = pair.key.type_b == ctx.getDispatchUnarySentinel().descriptor.?;

        var method = try helpers.ArrayBuilder.init(alloc, 2);
        errdefer method.deinit();

        var types = try helpers.ArrayBuilder.init(alloc, if (is_unary) 1 else 2);
        errdefer types.deinit();
        types.items[0] = value_mod.stringValue(type_a_name);
        if (!is_unary) types.items[1] = value_mod.stringValue(type_b_name);
        method.items[0] = try types.finish();

        method.items[1] = if (pair.entry.provenance) |dp|
            try buildOwnedStringsArray(alloc, &.{ dp.generator, dp.parent, dp.role, dp.field })
        else
            .{ .boolean = false };

        methods.items[i] = try method.finish();
    }
    info.items[6] = try methods.finish();

    info.items[7] = if (word.source_file) |file| blk: {
        var loc = try helpers.ArrayBuilder.init(alloc, 3);
        errdefer loc.deinit();
        loc.items[0] = try helpers.ownedStringCopy(alloc, file);
        loc.items[1] = .{ .fixnum = @intCast(word.source_line) };
        loc.items[2] = .{ .fixnum = @intCast(word.source_column) };
        break :blk try loc.finish();
    } else .{ .boolean = false };

    info.items[8] = if (word.source_module) |mod|
        .{ .module = @constCast(mod) }
    else
        .{ .boolean = false };

    info.items[9] = if (word.provenance) |p|
        try buildOwnedStringsArray(alloc, &.{ p.generator, p.parent, p.role })
    else
        .{ .boolean = false };

    info.items[10] = .{ .boolean = blk: {
        for (ctx.jit_dispatch.entries.items) |entry| {
            if (std.mem.eql(u8, entry.word_name, name) and entry.code_ptr != null) break :blk true;
        }
        break :blk false;
    } };

    info.items[11] = try buildConstraintInfo(alloc, name, word);
    info.items[12] = .{ .boolean = word.action == .literal };
    info.items[13] = .{ .boolean = word.parse_time };

    return try info.finish();
}

fn moduleWordToWordDef(name: []const u8, mw: ModuleWord) WordDefinition {
    var def: WordDefinition = .{
        .name = name,
        .action = switch (mw.action) {
            .compound => |instrs| .{ .compound = instrs },
            .native => |f| .{ .native = f },
            .host_callback => |host| .{ .host_callback = host },
            .literal => |lit| .{ .literal = lit.value },
        },
    };
    dictionary_mod.copySharedFields(&def, mw, &.{"action"});
    return def;
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
        .array => |a| a.items,
        else => {
            helpers.setTypeMismatchError(ctx, "array", val);
            return error.TypeMismatch;
        },
    };

    const result = try alloc.alloc([]const u8, arr.len);
    for (arr, 0..) |item, i| {
        result[i] = switch (item) {
            .string => |s| s.bytes,
            else => {
                helpers.setTypeMismatchError(ctx, "string", item);
                return error.TypeMismatch;
            },
        };
    }
    return result;
}

fn moduleFromCache(cache: *const MutableMap, resolved_path: []const u8) ?*const Module {
    const cached = cache.map.get(resolved_path) orelse return null;
    return switch (cached) {
        .module => |m| m,
        else => null,
    };
}

fn isLintSemanticWord(name: []const u8, word: WordDefinition) bool {
    if (word.provenance != null) return false;
    if (std.mem.startsWith(u8, name, "(")) return false;
    return switch (word.action) {
        .compound, .literal => true,
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
    var fields = try helpers.ArrayBuilder.init(alloc, 4);
    errdefer fields.deinit();

    fields.items[0] = try helpers.ownedStringCopy(alloc, info.name);
    fields.items[1] = try helpers.ownedStringCopy(alloc, info.source_file);
    fields.items[2] = .{ .fixnum = @intCast(info.source_line) };
    fields.items[3] = .{ .fixnum = @intCast(info.source_column) };

    return try fields.finish();
}

/// dead-definitions ( cache files -- array )
/// Return array entries of [ name file line column ] for checked-file compound
/// words that have no inbound edge from another checked-file component.
fn nativeDeadDefinitions(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "dead-definitions");

    const alloc = ctx.quotationAllocator();

    const files_val = try ctx.stack.pop();
    defer container_backing.releaseValue(files_val);
    const file_paths = try popStringArray(ctx, files_val);

    const cache_val = try ctx.stack.pop();
    defer container_backing.releaseValue(cache_val);
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

            if (dictionary.get(name) == null) {
                try dictionary.put(name, word);
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

    var graph = try call_graph_mod.build(&dictionary, .{ .context = ctx }, alloc);
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

    var result = try helpers.ArrayBuilder.init(ctx.allocator, dead_infos.items.len);
    errdefer result.deinit();
    for (dead_infos.items, 0..) |info, i| {
        result.items[i] = try buildDeadDefinitionValue(ctx.allocator, info);
    }
    try helpers.pushMovedValue(ctx, try result.finish());
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
                try module.words.put(alloc, entry.key_ptr.*, try ctx.moduleWordFor(alloc, entry.value_ptr.*));
            }
        }
    }

    {
        var iter = ctx.dictionary.entries.iterator();
        while (iter.next()) |entry| {
            const gop = try seen.getOrPut(alloc, entry.key_ptr.*);
            if (!gop.found_existing) {
                try module.words.put(alloc, entry.key_ptr.*, try ctx.moduleWordFor(alloc, dictionary_mod.loadSlot(entry.value_ptr.*).*));
            }
        }
    }

    var ancestor = ctx.parent_context;
    while (ancestor) |anc| {
        const anc_cap = if (anc.durable_frame_floor) |idx| idx + 1 else 0;
        var j = anc_cap;
        while (j > 0) {
            j -= 1;
            var iter = anc.local_frames.items[j].iterator();
            while (iter.next()) |entry| {
                const gop = try seen.getOrPut(alloc, entry.key_ptr.*);
                if (!gop.found_existing) {
                    try module.words.put(alloc, entry.key_ptr.*, try ctx.moduleWordFor(alloc, entry.value_ptr.*));
                }
            }
        }

        {
            var iter = anc.dictionary.entries.iterator();
            while (iter.next()) |entry| {
                const gop = try seen.getOrPut(alloc, entry.key_ptr.*);
                if (!gop.found_existing) {
                    try module.words.put(alloc, entry.key_ptr.*, try ctx.moduleWordFor(alloc, dictionary_mod.loadSlot(entry.value_ptr.*).*));
                }
            }
        }

        ancestor = anc.parent_context;
    }

    try ctx.stack.push(.{ .module = module });
}

/// local-scope ( -- module ) - Snapshot the topmost local frame into an importable Module.
fn nativeLocalScope(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    // At a definition scope (top level, load-top, REPL, eval) the topmost frame
    // is the import frame, so capturing it and feeding it to `import` would
    // silently demote the surrounding module's public API into private deps. A
    // transient frame above the import frame -- the frame a `call` pushes -- is
    // required.
    if (ctx.local_frames.items.len == 0 or
        (ctx.import_frame_index orelse 0) == ctx.local_frames.items.len - 1)
    {
        ctx.pending_error_message =
            "local-scope: no enclosing transient frame; call inside a quotation via `[ ... ] call`";
        return error.InvalidScope;
    }

    const module = try alloc.create(Module);
    module.* = .{ .name = "<local-scope>", .words = .{}, .importable = true };

    // Capture ambient imported words into deps so the synthesized module is
    // self-contained. Without this, a private{ } word entered by a tail call
    // cannot resolve its module's use-imports: TCO drops the caller's deps
    // frame, and <local-scope>'s own frame otherwise lacks the imports.
    // Iterate outermost-first so innermost-scope entries take precedence.
    for (ctx.local_frames.items) |*frame| {
        var dep_iter = frame.iterator();
        while (dep_iter.next()) |entry| {
            if (entry.value_ptr.*.imported) {
                try module.deps.put(alloc, entry.key_ptr.*, try ctx.moduleWordFor(alloc, entry.value_ptr.*));
            }
        }
    }

    var iter = ctx.local_frames.items[ctx.local_frames.items.len - 1].iterator();
    while (iter.next()) |entry| {
        try module.words.put(alloc, entry.key_ptr.*, try ctx.moduleWordFor(alloc, entry.value_ptr.*));
    }

    // The snapshot is complete here, so pre-build the frame template the way a `load` does. Every
    // call into a `private{ }` helper pushes this module's deps frame, and without a template each
    // push rebuilds the whole map entry by entry.
    try Context.buildModuleDepsTemplate(module, alloc);

    try ctx.stack.push(.{ .module = module });
}

/// module-deps ( module -- module ) - Snapshot a module's private `deps` into an introspectable
/// module whose `.words` mirror the deps.
///
/// `import` and every module-introspection native read `module.words`, never `module.deps`, so a
/// module's private helpers are otherwise invisible from 1z. This exposes them under the same
/// `@keys` / `word-source` / `word-markers` / `defined?` surface the public words use, which is what
/// the `borrow` shadow check reads. The result is non-importable: it is for inspection, not for
/// promoting privates into public API.
fn nativeModuleDeps(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const src_val = try ctx.stack.pop();
    defer container_backing.releaseValue(src_val);
    const source = switch (src_val) {
        .module => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "module", src_val);
            return error.TypeMismatch;
        },
    };

    const module = try alloc.create(Module);
    module.* = .{ .name = "<module-deps>", .words = .{}, .importable = false };

    var iter = source.deps.iterator();
    while (iter.next()) |entry| {
        try module.words.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
    }

    try ctx.stack.push(.{ .module = module });
}

/// >word ( module symbol -- array ) - Look up a word in a module and return a raw 11-element array
fn nativeToWord(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    const name = switch (val) {
        .symbol, .string => |s| s.bytes,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol", val);
            return error.TypeMismatch;
        },
    };

    const mod_val = try ctx.stack.pop();
    defer container_backing.releaseValue(mod_val);
    const module = switch (mod_val) {
        .module => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "module", mod_val);
            return error.TypeMismatch;
        },
    };

    if (module.words.get(name)) |mod_word| {
        const word = moduleWordToWordDef(name, mod_word);
        try helpers.pushMovedValue(ctx, try buildWordInfo(alloc, ctx, name, word));
        return;
    }

    // A qualified name like `math.sin` is not a key in the scope snapshot.
    // Resolve it through the module binding's literal, the same inspect-only
    // path dispatch registration and effect inference use. The word info
    // carries the bare word name, since dispatch entries and compile records
    // are keyed by it.
    if (Context.splitQualifiedName(name)) |qn| {
        if (ctx.resolveQualifiedModuleWord(name)) |mod_word| {
            const word = moduleWordToWordDef(qn.word_name, mod_word);
            try helpers.pushMovedValue(ctx, try buildWordInfo(alloc, ctx, qn.word_name, word));
            return;
        }
    }

    helpers.setErrorContext(ctx, "word not found: {s}", .{name});
    return error.NameError;
}

/// >constraint-info ( constraint -- array ) - Convert a constraint value into the same
/// raw constraint-info record `{name kind methods elements id}` that `>word-info`'s
/// `protocol` field carries. Accepts both protocol-descriptor and combinator backings.
fn nativeConstraintToInfo(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    const backing: ConstraintBacking = switch (val) {
        .protocol_descriptor => |d| .{ .protocol = d },
        .constraint_combinator => |cc| .{ .combinator = cc },
        else => {
            helpers.setTypeMismatchError(ctx, "constraint", val);
            return error.TypeMismatch;
        },
    };
    try helpers.pushMovedValue(ctx, try buildConstraintRecord(ctx.allocator, backing, null));
}

/// type-descriptor ( symbol|type -- type-descriptor ) - Look up a type descriptor by name or type value.
fn nativeTypeDescriptor(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    switch (val) {
        .type_val => |tv| {
            const desc = tv.descriptor orelse {
                helpers.setErrorContext(ctx, "no type descriptor for '{s}'", .{tv.name});
                return error.NameError;
            };
            try ctx.stack.push(.{ .type_descriptor = desc });
        },
        .symbol, .string => |name| {
            const desc = ctx.lookupTypeDescriptor(name.bytes) orelse {
                helpers.setErrorContext(ctx, "no type descriptor for '{s}'", .{name.bytes});
                return error.NameError;
            };
            try ctx.stack.push(.{ .type_descriptor = desc });
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
    defer container_backing.releaseValue(val);
    const tv = switch (val) {
        .type_val => |tv| tv,
        .symbol, .string => |name| ctx.lookupTypeValueByName(name.bytes) orelse {
            helpers.setErrorContext(ctx, "no type value for '{s}'", .{name.bytes});
            return error.NameError;
        },
        else => {
            helpers.setTypeMismatchError(ctx, "symbol or type", val);
            return error.TypeMismatch;
        },
    };
    // The generated-words slice belongs to the type value; the result array
    // copies it.
    try helpers.pushCopiedArray(ctx, ctx.allocator, tv.generated_words orelse &.{});
}

fn resolveTypeValue(ctx: *Context, val: Value) !*value_mod.TypeValue {
    return switch (val) {
        .type_val => |tv| tv,
        .symbol, .string => |name| ctx.lookupTypeValueByName(name.bytes) orelse {
            helpers.setErrorContext(ctx, "no type value for '{s}'", .{name.bytes});
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
                .string => |s| try buf.appendSlice(alloc, s.bytes),
                .symbol => |s| try buf.appendSlice(alloc, s.bytes),
                else => try buf.appendSlice(alloc, try helpers.formatValueBrief(alloc, word, 256)),
            }
        }
    }
    try buf.appendSlice(alloc, "\n");
}

fn appendBoolFieldIfTrue(
    buf: *std.ArrayListUnmanaged(u8),
    alloc: Allocator,
    key: []const u8,
    val: bool,
) !void {
    if (!val) return;
    try buf.appendSlice(alloc, "  ");
    try buf.appendSlice(alloc, key);
    try buf.appendSlice(alloc, ": t\n");
}

/// type-info-string ( symbol|type -- string ) - Render type info for help/introspection output.
fn nativeTypeInfoString(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const type_val = try ctx.stack.pop();
    defer container_backing.releaseValue(type_val);
    const tv = try resolveTypeValue(ctx, type_val);
    const desc = tv.descriptor orelse {
        try ctx.stack.push(value_mod.stringValue(""));
        return;
    };

    var buf: std.ArrayListUnmanaged(u8) = .{};

    switch (desc.kind) {
        .builtin => {
            try buf.appendSlice(alloc, "type info:\n  kind: builtin-type\n");
            try appendBoolFieldIfTrue(&buf, alloc, "integer", desc.integer);
            try appendBoolFieldIfTrue(&buf, alloc, "exact", desc.exact);
            try appendBoolFieldIfTrue(&buf, alloc, "numeric", desc.numeric);
            try appendBoolFieldIfTrue(&buf, alloc, "mutable", desc.mutable);
        },
        .struct_ => |sd| {
            try buf.appendSlice(alloc, "type info:\n  kind: struct\n  fields: ");
            for (sd.fields, 0..) |field, i| {
                if (i > 0) try buf.append(alloc, ' ');
                try buf.appendSlice(alloc, field);
            }
            try buf.appendSlice(alloc, "\n");
            try appendGeneratedWords(&buf, alloc, tv);
        },
        .virtual => |vd| {
            try buf.appendSlice(alloc, "type info:\n  kind: virtual\n");
            if (vd.inner_type) |inner_tv| {
                try buf.appendSlice(alloc, "  wraps: ");
                try buf.appendSlice(alloc, inner_tv.name);
                try buf.appendSlice(alloc, "\n");
            } else if (vd.anon_struct) |st| {
                try buf.appendSlice(alloc, "  fields: ");
                for (st.fields, 0..) |field, i| {
                    if (i > 0) try buf.append(alloc, ' ');
                    try buf.appendSlice(alloc, field);
                }
                try buf.appendSlice(alloc, "\n");
            }
            try appendGeneratedWords(&buf, alloc, tv);
        },
        .enum_ => |ed| {
            try buf.appendSlice(alloc, "type info:\n  kind: enum\n  variants:\n");
            var max_name_len: usize = 0;
            for (ed.variants) |v| {
                if (v.name.len > max_name_len) max_name_len = v.name.len;
            }
            for (ed.variants) |v| {
                const variant_name_str = v.name;
                const variant_type = if (v.type_val) |t| Value{ .type_val = @constCast(t) } else Value{ .unit = {} };
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
            try appendGeneratedWords(&buf, alloc, tv);
        },
        .enum_variant, .resource, .ffi_struct, .sentinel, .union_, .type_parameter => {},
    }

    try helpers.pushOwnedString(ctx, try ctx.allocator.dupe(u8, buf.items));
}

/// locally-defined? ( name -- bool ) - Check if a word is defined in the import frame.
fn nativeLocallyDefined(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    const name = switch (val) {
        .symbol => |s| s.bytes,
        .string => |s| s.bytes,
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

/// local-word-source ( name -- module/f ) - Return the source module of the import-frame
/// binding for a word, or f when the word is absent, locally defined, or not imported.
fn nativeLocalWordSource(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    const name = switch (val) {
        .symbol => |s| s.bytes,
        .string => |s| s.bytes,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol or string", val);
            return error.TypeMismatch;
        },
    };

    const idx = ctx.import_frame_index orelse {
        try ctx.stack.push(.{ .boolean = false });
        return;
    };

    if (ctx.local_frames.items[idx].get(name)) |existing| {
        if (existing.imported) {
            if (existing.source_module) |mod| {
                try ctx.stack.push(.{ .module = @constCast(mod) });
                return;
            }
        }
    }
    try ctx.stack.push(.{ .boolean = false });
}

/// defined? ( module name -- bool ) - Check if a word exists in a module.
fn nativeDefined(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    const name = switch (val) {
        .symbol => |s| s.bytes,
        .string => |s| s.bytes,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol or string", val);
            return error.TypeMismatch;
        },
    };

    const mod_val = try ctx.stack.pop();
    defer container_backing.releaseValue(mod_val);
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
    defer container_backing.releaseValue(val);
    const name = switch (val) {
        .symbol => |s| s.bytes,
        .string => |s| s.bytes,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol or string", val);
            return error.TypeMismatch;
        },
    };

    const mod_val = try ctx.stack.pop();
    defer container_backing.releaseValue(mod_val);
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
/// 3. ancestor contexts, read only up to each ancestor's durable floor.
///
/// Higher-priority definitions shadow lower ones.
fn nativeAllWords(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    var seen: std.StringHashMapUnmanaged(void) = .{};
    var results: std.ArrayListUnmanaged(Value) = .{};
    defer results.deinit(ctx.allocator);
    errdefer container_backing.releaseValues(results.items);

    try collectFrameWords(alloc, ctx, ctx, &seen, &results, false);

    var ancestor = ctx.parent_context;
    while (ancestor) |anc| {
        try collectFrameWords(alloc, ctx, anc, &seen, &results, true);
        ancestor = anc.parent_context;
    }

    const items = try ctx.allocator.dupe(Value, results.items);
    results.clearRetainingCapacity();
    try helpers.pushAdoptedArray(ctx, ctx.allocator, items);
}

/// Append the word-info record for `name`, releasing it when the append fails.
fn appendWordInfo(
    scratch: Allocator,
    lookup_ctx: *Context,
    results: *std.ArrayListUnmanaged(Value),
    name: []const u8,
    word: WordDefinition,
) !void {
    const info = try buildWordInfo(scratch, lookup_ctx, name, word);
    results.append(lookup_ctx.allocator, info) catch |e| {
        container_backing.releaseValue(info);
        return e;
    };
}

/// scope-frames ( -- array ) - Return an array of frame descriptor hashes for the full scope chain.
fn nativeScopeFrames(ctx: *Context) anyerror!void {
    var results: std.ArrayListUnmanaged(Value) = .{};
    defer results.deinit(ctx.allocator);
    errdefer container_backing.releaseValues(results.items);

    try collectScopeFrames(ctx.allocator, ctx, "", &results, false);

    var ancestor = ctx.parent_context;
    while (ancestor) |anc| {
        // A descendant task resolves only an ancestor's stable scope, so the
        // dump stops at each ancestor's durable floor rather than walking its
        // task-private transient frames across the spawn boundary.
        try collectScopeFrames(ctx.allocator, anc, "parent-", &results, true);
        ancestor = anc.parent_context;
    }

    const items = try ctx.allocator.dupe(Value, results.items);
    results.clearRetainingCapacity();
    try helpers.pushAdoptedArray(ctx, ctx.allocator, items);
}

/// stack-snapshot ( -- string ) - Return a debug snapshot of the current data stack.
fn nativeStackSnapshot(ctx: *Context) anyerror!void {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(ctx.allocator);
    try ctx.stack.dump(buf.writer(ctx.allocator));
    try helpers.pushOwnedString(ctx, try buf.toOwnedSlice(ctx.allocator));
}

/// Store `val` under a copy of `key`, taking ownership of `val` on every path.
fn putFrameEntry(hash: *HashTable, key: []const u8, val: Value) !void {
    const hash_alloc = hash.header.allocator;
    const key_copy = hash_alloc.dupe(u8, key) catch |e| {
        container_backing.releaseValue(val);
        return e;
    };
    hash.map.put(hash_alloc, key_copy, val) catch |e| {
        hash_alloc.free(key_copy);
        container_backing.releaseValue(val);
        return e;
    };
}

/// A frame descriptor hash on `gpa`. The word names are owned copies because a frame can belong
/// to a task, and the hash can outlive it.
fn buildFrameHash(
    gpa: Allocator,
    type_name: []const u8,
    index: i64,
    frame_words: anytype,
    is_import_frame: bool,
) !Value {
    const hash = try HashTable.create(gpa);
    errdefer container_backing.releaseValue(.{ .hash = hash });

    try putFrameEntry(hash, "type", value_mod.stringValue(type_name));
    try putFrameEntry(hash, "index", .{ .fixnum = index });
    try putFrameEntry(hash, "import-frame?", .{ .boolean = is_import_frame });

    var word_names: std.ArrayListUnmanaged(Value) = .{};
    defer word_names.deinit(gpa);
    errdefer container_backing.releaseValues(word_names.items);

    var iter = frame_words.iterator();
    while (iter.next()) |entry| {
        const name_val = try helpers.ownedStringCopy(gpa, entry.key_ptr.*);
        word_names.append(gpa, name_val) catch |e| {
            container_backing.releaseValue(name_val);
            return e;
        };
    }
    const count: i64 = @intCast(word_names.items.len);

    const names = try gpa.dupe(Value, word_names.items);
    const names_arr = value_mod.Array.fromOwnedSlice(gpa, names) catch |e| {
        gpa.free(names);
        return e;
    };
    word_names.clearRetainingCapacity();

    try putFrameEntry(hash, "words", .{ .array = names_arr });
    try putFrameEntry(hash, "count", .{ .fixnum = count });

    return .{ .hash = hash };
}

/// Append the frame descriptor for one frame, releasing it when the append fails.
fn appendFrameHash(
    gpa: Allocator,
    results: *std.ArrayListUnmanaged(Value),
    type_name: []const u8,
    index: i64,
    frame_words: anytype,
    is_import_frame: bool,
) !void {
    const frame_val = try buildFrameHash(gpa, type_name, index, frame_words, is_import_frame);
    results.append(gpa, frame_val) catch |e| {
        container_backing.releaseValue(frame_val);
        return e;
    };
}

fn collectScopeFrames(
    gpa: Allocator,
    source_ctx: *const Context,
    prefix: []const u8,
    results: *std.ArrayListUnmanaged(Value),
    stable_only: bool,
) !void {
    const local_type = if (prefix.len > 0) "parent-local-frame" else "local-frame";
    const dict_type = if (prefix.len > 0) "parent-global-dict" else "global-dict";

    // For an ancestor context, cap the walk at the durable floor: its frames
    // above it are task-private and not resolvable from a descendant.
    var i = if (stable_only)
        (if (source_ctx.durable_frame_floor) |idx| idx + 1 else 0)
    else
        source_ctx.local_frames.items.len;
    while (i > 0) {
        i -= 1;
        // For an ancestor the flag derives from the floor, since another task's `import_frame_index`
        // is a live field a runtime load moves without synchronization.
        const import_idx = if (stable_only) source_ctx.durable_frame_floor else source_ctx.import_frame_index;
        const is_import = import_idx != null and i == import_idx.?;
        try appendFrameHash(gpa, results, local_type, @intCast(i), &source_ctx.local_frames.items[i], is_import);
    }

    try appendFrameHash(gpa, results, dict_type, -1, &source_ctx.dictionary.entries, false);
}

/// Collect words from a single context's local frames and dictionary, skipping any names already
/// in `seen`. The self walk caps at import_frame_index to exclude transient frames pushed during
/// word execution (module deps frames, combinator frames). An ancestor context passes `ancestor`,
/// capping at the durable floor instead so the walk never reads another task's live frames.
fn collectFrameWords(
    alloc: std.mem.Allocator,
    lookup_ctx: *Context,
    source_ctx: *const Context,
    seen: *std.StringHashMapUnmanaged(void),
    results: *std.ArrayListUnmanaged(Value),
    ancestor: bool,
) !void {
    const frame_cap = if (ancestor)
        (if (source_ctx.durable_frame_floor) |idx| idx + 1 else 0)
    else if (source_ctx.import_frame_index) |idx| idx + 1 else 0;
    var i = frame_cap;
    while (i > 0) {
        i -= 1;
        var iter = source_ctx.local_frames.items[i].iterator();
        while (iter.next()) |entry| {
            const gop = try seen.getOrPut(alloc, entry.key_ptr.*);
            if (!gop.found_existing) {
                try appendWordInfo(alloc, lookup_ctx, results, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }
    var dict_iter = source_ctx.dictionary.entries.iterator();
    while (dict_iter.next()) |entry| {
        const gop = try seen.getOrPut(alloc, entry.key_ptr.*);
        if (!gop.found_existing) {
            try appendWordInfo(alloc, lookup_ctx, results, entry.key_ptr.*, dictionary_mod.loadSlot(entry.value_ptr.*).*);
        }
    }
}

/// quotation>effect ( quot -- effect-or-false ) - Extract the stack effect from a quotation.
fn nativeQuotationToEffect(ctx: *Context) anyerror!void {
    const pc = try helpers.popQuotation(ctx);
    defer pc.release();
    const quot = pc.quot;

    if (quot.effect) |effect| {
        try helpers.pushMovedValue(ctx, try buildStackEffectValue(ctx.allocator, effect));
    } else {
        try ctx.stack.push(.{ .boolean = false });
    }
}

/// >stack-effect-info ( stack-effect -- array ) - Unpack a stack-effect value into the raw
/// `{ inputs outputs }` record that `quotation>effect` returns, so 1z code can read its parameters.
fn nativeStackEffectToInfo(ctx: *Context) anyerror!void {
    const effect = try helpers.popStackEffect(ctx);
    try helpers.pushMovedValue(ctx, try buildStackEffectValue(ctx.allocator, &effect));
}

/// parse-stack-effect ( string -- stack-effect ) - Build a stack-effect value
/// from an effect body string with no surrounding parens, e.g. "a b -- result".
/// The runtime analog of the parse-time `(` word, sharing its parser, so typed
/// annotations (`n: fixnum`), nested quotation effects, and row variables all
/// resolve exactly as they would in source.
fn nativeParseStackEffect(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const raw_str = try helpers.popString(ctx);
    defer container_backing.releaseValue(.{ .string = raw_str });
    const raw = raw_str.bytes;
    // The shared parser consumes tokens up to the matching `)`; the body string
    // carries no parens, so close it here. Parameter names are duped onto
    // `alloc` by the parser, so nothing references the wrapped string after
    // parsing.
    const wrapped = try std.fmt.allocPrint(alloc, "{s} )", .{raw});
    var tokenizer = Tokenizer.init(wrapped);
    // An effect body is a fragment, not a source, so a leading `#!` in it is an ordinary word.
    tokenizer.at_source_start = false;
    ctx.parse_diagnostics = null;
    const effect = parser_mod.parseStackEffect(alloc, &tokenizer, ctx, 0) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (ctx.parse_diagnostics) |diag| {
            if (diag.message) |msg| {
                helpers.setErrorContext(ctx, "parse-stack-effect: {s}", .{msg});
                return error.InvalidArgument;
            }
        }
        helpers.setErrorContext(ctx, "parse-stack-effect: invalid stack effect '{s}'", .{raw});
        return error.InvalidArgument;
    };
    try ctx.stack.push(.{ .stack_effect = effect });
}

/// quotation>opcodes ( quotation -- array ) - Return instruction pairs as raw [symbol, value] arrays.
fn nativeQuotationToOpcodes(ctx: *Context) anyerror!void {
    const alloc = ctx.allocator;
    const pc = try helpers.popQuotation(ctx);
    defer pc.release();
    const quot = pc.quot;

    var result = try helpers.ArrayBuilder.init(alloc, quot.instructions.len);
    errdefer result.deinit();

    for (quot.instructions, 0..) |instr, i| {
        var pair = try helpers.ArrayBuilder.init(alloc, 2);
        errdefer pair.deinit();

        switch (instr.op) {
            .push_literal => |lit| {
                pair.items[0] = value_mod.symbolValue("push-literal");
                // The literal is borrowed from the instruction stream; the
                // pair array must own its own reference.
                container_backing.retainValue(lit);
                pair.items[1] = lit;
            },
            .call_word => |name| {
                pair.items[0] = value_mod.symbolValue("call-word");
                pair.items[1] = try helpers.ownedStringCopy(alloc, name);
            },
            .call_word_direct, .call_word_module => |slot| {
                pair.items[0] = value_mod.symbolValue("call-word");
                pair.items[1] = try helpers.ownedStringCopy(alloc, slot.name);
            },
        }

        result.items[i] = try pair.finish();
    }

    try helpers.pushMovedValue(ctx, try result.finish());
}

const testing = std.testing;

test "parse-stack-effect parses an unannotated effect body" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(value_mod.stringValue("a b -- r"));
    try nativeParseStackEffect(&ctx);

    const val = try ctx.stack.pop();
    try testing.expect(val == .stack_effect);
    try testing.expectEqual(@as(usize, 2), val.stack_effect.inputs.len);
    try testing.expectEqual(@as(usize, 1), val.stack_effect.outputs.len);
    try testing.expectEqualStrings("a", val.stack_effect.inputs[0].name);
    try testing.expectEqualStrings("b", val.stack_effect.inputs[1].name);
    try testing.expectEqualStrings("r", val.stack_effect.outputs[0].name);
    try testing.expect(val.stack_effect.inputs[0].type_annotation == null);
}

test "parse-stack-effect resolves type annotations" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    try ctx.stack.push(value_mod.stringValue("a: fixnum b -- r: string"));
    try nativeParseStackEffect(&ctx);

    const val = try ctx.stack.pop();
    try testing.expect(val == .stack_effect);
    try testing.expectEqual(@as(usize, 2), val.stack_effect.inputs.len);
    try testing.expectEqual(@as(usize, 1), val.stack_effect.outputs.len);

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;
    try testing.expectEqualStrings("a", val.stack_effect.inputs[0].name);
    try testing.expect(val.stack_effect.inputs[0].type_annotation.?.type == fixnum_tv);
    try testing.expect(val.stack_effect.inputs[1].type_annotation == null);
    try testing.expectEqualStrings("r", val.stack_effect.outputs[0].name);
    try testing.expect(val.stack_effect.outputs[0].type_annotation.?.type == string_tv);
}

test "parse-stack-effect keeps row variables" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(value_mod.stringValue("..a x -- ..a"));
    try nativeParseStackEffect(&ctx);

    const val = try ctx.stack.pop();
    try testing.expect(val == .stack_effect);
    try testing.expectEqual(@as(usize, 2), val.stack_effect.inputs.len);
    try testing.expect(val.stack_effect.inputs[0].is_row_variable);
    try testing.expect(!val.stack_effect.inputs[1].is_row_variable);
    try testing.expect(val.stack_effect.outputs[0].is_row_variable);
}

test ">stack-effect-info unpacks row, typed, and nested parameters" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    try ctx.stack.push(value_mod.stringValue("..a n: fixnum q: ( x -- y ) -- ..a"));
    try nativeParseStackEffect(&ctx);
    try nativeStackEffectToInfo(&ctx);

    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    const record = val.array.items;
    try testing.expectEqual(@as(usize, 2), record.len);

    const inputs = record[0].array.items;
    const outputs = record[1].array.items;
    try testing.expectEqual(@as(usize, 3), inputs.len);
    try testing.expectEqual(@as(usize, 1), outputs.len);

    const row = inputs[0].array.items;
    try testing.expectEqualStrings("..a", row[0].string.bytes);
    try testing.expect(row[1].boolean);

    const typed = inputs[1].array.items;
    try testing.expectEqualStrings("n", typed[0].string.bytes);
    try testing.expect(typed[0].string.backing != null);
    try testing.expectEqual(ctx.allocator.ptr, val.array.header.allocator.ptr);
    try testing.expect(!typed[1].boolean);
    try testing.expect(typed[3].type_val == ctx.lookupBuiltinTypeValue("fixnum").?);

    const nested = inputs[2].array.items;
    try testing.expectEqualStrings("q", nested[0].string.bytes);
    try testing.expect(nested[2] == .array);
}

test ">stack-effect-info rejects a value that is not a stack effect" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .fixnum = 1 });
    try testing.expectError(error.TypeMismatch, nativeStackEffectToInfo(&ctx));
}

test "parse-stack-effect rejects an unknown annotation type" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    try ctx.stack.push(value_mod.stringValue("a: no-such-type -- r"));
    try testing.expectError(error.InvalidArgument, nativeParseStackEffect(&ctx));
}

test "local-scope leaves a deps template on the module it snapshots" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const noop: dictionary_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    try ctx.pushLocalFrame();
    try ctx.local_frames.items[1].put(ctx.allocator, "helper", .{ .name = "helper", .action = .{ .native = noop } });

    try nativeLocalScope(&ctx);

    const val = try ctx.stack.pop();
    try testing.expect(val == .module);
    try testing.expect(val.module.deps_template != null);
    try testing.expect(val.module.deps_template.?.frame.get("helper") != null);
}
