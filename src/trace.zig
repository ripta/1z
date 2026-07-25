const std = @import("std");
const builtin = @import("builtin");
const is_freestanding = builtin.os.tag == .freestanding;
const File = std.fs.File;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Marker = value_mod.Marker;
const ModuleWord = value_mod.ModuleWord;
const Stack = @import("stack.zig").Stack;
const StackEffect = @import("stack_effect.zig").StackEffect;
const dispatch = @import("dispatch.zig");

/// Categories of `--trace-modules` events. Each module-trace call site checks the
/// field that matches the event it is about to emit.
pub const ModuleTraceCategories = packed struct {
    lifecycle: bool = false,
    source: bool = false,
    define: bool = false,
    import: bool = false,
    deps: bool = false,

    /// True when at least one category is enabled.
    pub fn any(self: ModuleTraceCategories) bool {
        return self.lifecycle or self.source or self.define or self.import or self.deps;
    }

    /// All categories enabled. The shape produced by the bare `--trace-modules` flag.
    pub fn all() ModuleTraceCategories {
        return .{
            .lifecycle = true,
            .source = true,
            .define = true,
            .import = true,
            .deps = true,
        };
    }
};

/// Categories of `--trace-aot` events, one per AOT-compiler trace axis. Each
/// AOT trace call site checks the field for the axis it is about to emit.
pub const AotTraceCategories = packed struct {
    freeze: bool = false,
    codegen: bool = false,
    effect: bool = false,
    instr: bool = false,

    /// True when at least one axis is enabled.
    pub fn any(self: AotTraceCategories) bool {
        return self.freeze or self.codegen or self.effect or self.instr;
    }

    /// The three per-word axes enabled by bare `--trace-aot`. The per-instruction
    /// `instr` firehose stays opt-in and is left off here.
    pub fn perWordAxes() AotTraceCategories {
        return .{ .freeze = true, .codegen = true, .effect = true };
    }
};

/// Error returned by `parseModuleTraceCategories` when the value is malformed.
pub const ParseModuleTraceError = error{
    EmptyValue,
    UnknownCategory,
};

/// Error returned by `parseAotTraceCategories` when the value is malformed.
pub const ParseAotTraceError = error{
    EmptyValue,
    UnknownCategory,
};

/// Parse a comma-separated category list (e.g., `"lifecycle,source"`) into a
/// `ModuleTraceCategories`. Whitespace around each token is trimmed. Empty
/// strings and unknown tokens fail.
pub fn parseModuleTraceCategories(value: []const u8) ParseModuleTraceError!ModuleTraceCategories {
    if (value.len == 0) return error.EmptyValue;

    var cats: ModuleTraceCategories = .{};
    var iter = std.mem.splitScalar(u8, value, ',');
    while (iter.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t");
        if (trimmed.len == 0) return error.EmptyValue;
        if (std.mem.eql(u8, trimmed, "lifecycle")) {
            cats.lifecycle = true;
        } else if (std.mem.eql(u8, trimmed, "source")) {
            cats.source = true;
        } else if (std.mem.eql(u8, trimmed, "define")) {
            cats.define = true;
        } else if (std.mem.eql(u8, trimmed, "import")) {
            cats.import = true;
        } else if (std.mem.eql(u8, trimmed, "deps")) {
            cats.deps = true;
        } else {
            return error.UnknownCategory;
        }
    }
    return cats;
}

/// Parse a comma-separated category list (e.g., `"freeze,codegen"`) into an
/// `AotTraceCategories`. Whitespace around each token is trimmed. Empty strings
/// and unknown tokens fail. `instr` parses as a valid token; it has no emit
/// sites yet, so enabling it produces no output.
pub fn parseAotTraceCategories(value: []const u8) ParseAotTraceError!AotTraceCategories {
    if (value.len == 0) return error.EmptyValue;

    var cats: AotTraceCategories = .{};
    var iter = std.mem.splitScalar(u8, value, ',');
    while (iter.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t");
        if (trimmed.len == 0) return error.EmptyValue;
        if (std.mem.eql(u8, trimmed, "freeze")) {
            cats.freeze = true;
        } else if (std.mem.eql(u8, trimmed, "codegen")) {
            cats.codegen = true;
        } else if (std.mem.eql(u8, trimmed, "effect")) {
            cats.effect = true;
        } else if (std.mem.eql(u8, trimmed, "instr")) {
            cats.instr = true;
        } else {
            return error.UnknownCategory;
        }
    }
    return cats;
}

/// Configuration for execution tracing.
pub const TraceConfig = struct {
    trace_words: bool = false,
    trace_words_pattern: ?[]const u8 = null,
    trace_resolve: bool = false,
    trace_resolve_pattern: ?[]const u8 = null,
    trace_modules: ModuleTraceCategories = .{},

    // AOT-compiler trace axes. Driven by the AOT build path, not the
    // word-execution path, so it is excluded from `isEnabled` the same way the
    // sampler axes below are.
    trace_aot: AotTraceCategories = .{},

    // `--trace-aot-word=PAT` word-name filter, applied to whichever `trace_aot` axes are enabled.
    // A null pattern matches every word, so the filter is a noöp when the flag is absent.
    trace_aot_word_pattern: ?[]const u8 = null,

    trace_jit: bool = false,
    trace_pic: bool = false,
    trace_container_detect: bool = false,
    dump_scope: ?[]const u8 = null,

    // JIT native-code byte dumps. Fired on the compile path, not the word-execution path, so they
    // are excluded from `isEnabled` the same way the AOT and sampler axes are.
    dump_jit_bytes: bool = false,
    dump_jit_bin_dir: ?[]const u8 = null,

    // `--dump-jit-word=PAT` name filter over both dump sinks. Null matches every word.
    dump_jit_word_pattern: ?[]const u8 = null,

    // Periodic task/memory sampler axes and interval. Independent of the
    // trace flags above; the sampler is driven by the scheduler, not the
    // word-execution path, so it is excluded from `isEnabled`.
    //
    // `sampling_tick_ns` null means no interval was given; the sampler
    // defaults it to 1000ms when an axis is enabled.
    sample_tasks: bool = false,
    sample_memory: bool = false,
    sampling_tick_ns: ?i128 = null,

    pub fn isEnabled(self: TraceConfig) bool {
        return self.trace_words or self.trace_resolve or self.trace_modules.any() or self.trace_jit or self.trace_pic or self.trace_container_detect or self.dump_scope != null;
    }
};

/// Which backing store a module was loaded from.
pub const ModuleSourceKind = enum {
    embedded,
    filesystem,

    pub fn label(self: ModuleSourceKind) []const u8 {
        return switch (self) {
            .embedded => "embedded",
            .filesystem => "filesystem",
        };
    }
};

/// Buffered writer for trace output.
///
/// On freestanding targets there is no real stderr to write to (STDERR_FILENO is undefined on
/// the non-libc posix stub), so `file` stays `void` there and every write is a silent no-op.
/// Trace output is a diagnostic nicety, not load-bearing behavior; nothing on that target can
/// set the `--trace-*` flags that gate these calls anyway (no CLI), so this only matters once an
/// embedder starts flipping trace config programmatically. A real host-injected diagnostic sink
/// can replace this once one exists.
pub const TraceWriter = struct {
    file: if (is_freestanding) void else File,

    pub fn init() TraceWriter {
        if (comptime is_freestanding) return .{ .file = {} };
        return .{ .file = .stderr() };
    }

    pub fn print(self: *TraceWriter, comptime fmt: []const u8, args: anytype) void {
        if (comptime is_freestanding) return;
        var buf: [4096]u8 = undefined;
        var w = self.file.writer(&buf);
        w.interface.print(fmt, args) catch return;
        w.interface.flush() catch return;
    }

    pub fn writeAll(self: *TraceWriter, bytes: []const u8) void {
        if (comptime is_freestanding) return;
        var buf: [4096]u8 = undefined;
        var w = self.file.writer(&buf);
        w.interface.writeAll(bytes) catch return;
        w.interface.flush() catch return;
    }
};

/// Write a short type-tagged preview of the top `max_values` stack entries
/// to the given writer. Values are shown deepest-to-shallowest.
///
/// Format: `stack=[type:preview type:preview ...]`
pub fn formatStackPreview(stack: *const Stack, writer: anytype, max_values: usize) void {
    const depth = stack.depth();
    writer.writeAll("stack=[") catch return;

    const show = @min(depth, max_values);
    const has_overflow = depth > max_values;

    if (has_overflow) {
        writer.writeAll("... ") catch return;
    }

    var i: usize = show;
    while (i > 0) {
        i -= 1;
        const val = stack.peekN(i) catch continue;
        const type_name = dispatch.dispatchTypeName(val);
        writer.print("{s}:", .{type_name}) catch return;
        writeValuePreview(val, writer) catch return;
        if (i > 0) {
            writer.writeByte(' ') catch return;
        }
    }

    writer.writeByte(']') catch return;
}

/// Write a short representation of a value suitable for trace output.
pub fn writeValuePreview(val: Value, writer: anytype) !void {
    switch (val) {
        .fixnum => |i| try writer.print("{d}", .{i}),
        .float => |f| {
            if (std.math.isNan(f)) {
                try writer.writeAll("nan");
            } else if (std.math.isInf(f)) {
                if (f < 0) try writer.writeByte('-');
                try writer.writeAll("inf");
            } else {
                try writer.print("{d}", .{f});
            }
        },
        .boolean => |b| try writer.writeAll(if (b) "t" else "f"),
        .string => |s| {
            if (s.len <= 20) {
                try writer.print("\"{s}\"", .{s});
            } else {
                try writer.print("\"{s}...\"", .{s[0..20]});
            }
        },
        .symbol => |s| try writer.print("{s}:", .{s}),
        .array => |arr| try writer.print("<array:{d}>", .{arr.items.len}),
        .vector => |v| try writer.print("<vector:{d}>", .{v.list.items.len}),
        .byte_array => |b| try writer.print("<byte-array:{d}>", .{b.slice().len}),
        .set => |s| try writer.print("<set:{d}>", .{s.map.count()}),
        .hash => |h| try writer.print("<hash:{d}>", .{h.map.count()}),
        .mutable_map => |m| try writer.print("<mutable-map:{d}>", .{m.map.count()}),
        .bignum => try writer.writeAll("<bignum>"),
        .tagged => |t| try writer.print("<{s}>", .{t.tag.name}),
        .struct_instance => |si| try writer.print("<{s}>", .{si.struct_type.name}),
        .quotation => try writer.writeAll("<quotation>"),
        .closure => try writer.writeAll("<quotation>"),
        .stream => try writer.writeAll("<stream>"),
        .resource => |r| try writer.print("<resource:{s}>", .{r.type_name}),
        .module => |m| try writer.print("<module:{s}>", .{m.name}),
        .iterator => try writer.writeAll("<iterator>"),
        .channel => try writer.writeAll("<channel>"),
        .task => try writer.writeAll("<task>"),
        .parameter => try writer.writeAll("<parameter>"),
        .marker => try writer.writeAll("<marker>"),
        .struct_type => try writer.writeAll("<struct-type>"),
        .template => try writer.writeAll("<template>"),
        .stack_effect => try writer.writeAll("<stack-effect>"),
        .error_value => try writer.writeAll("<error>"),
        .doc_string => try writer.writeAll("<doc-string>"),
        .type_val => |tv| try writer.print("<type:{s}>", .{tv.name}),
        .type_descriptor => |desc| try writer.print(
            "<type-descriptor:{s}>",
            .{value_mod.typeKindSymbol(desc.kind)},
        ),
        .protocol_descriptor => |desc| try writer.print(
            "<protocol-descriptor:{s}>",
            .{desc.name},
        ),
        .constraint_combinator => |cc| try writer.print(
            "<constraint-combinator:{d}>",
            .{cc.combinator_id},
        ),
        .sandbox_spec => try writer.writeAll("<sandbox-spec>"),
        .unit => try writer.writeAll("unit"),
    }
}

/// Where a word was found during lookup.
pub const ResolveSource = union(enum) {
    local_frame: usize,
    global_dict: void,
    parent_local_frame: usize,
    parent_global_dict: void,
    qualified_found: struct { module: []const u8, word: []const u8 },
    qualified_not_found: struct { module: []const u8, word: []const u8 },
    not_found: void,
};

/// Emit a TRACE call line for `--trace-words`. Caller is responsible for
/// checking `trace.trace_words` and pattern matching before calling.
pub fn traceWord(
    trace_writer: *TraceWriter,
    name: []const u8,
    source: []const u8,
    line: usize,
    stack: *const Stack,
) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.print("TRACE call {s} at {s}:{d} ", .{ name, source, line }) catch return;
    formatStackPreview(stack, w, 3);
    w.writeByte('\n') catch return;

    trace_writer.writeAll(fbs.getWritten());
}

/// Emit a RESOLVE line for `--trace-resolve`. Caller is responsible for
/// checking `trace.trace_resolve` and pattern matching before calling.
pub fn traceResolve(
    trace_writer: *TraceWriter,
    name: []const u8,
    source: ResolveSource,
) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.print("RESOLVE {s} -> ", .{name}) catch return;
    switch (source) {
        .local_frame => |idx| w.print("local-frame[{d}]", .{idx}) catch return,
        .global_dict => w.writeAll("global-dict") catch return,
        .parent_local_frame => |idx| w.print("parent:local-frame[{d}]", .{idx}) catch return,
        .parent_global_dict => w.writeAll("parent:global-dict") catch return,
        .qualified_found => |q| w.print("qualified({s}, {s}) -> module-word", .{ q.module, q.word }) catch return,
        .qualified_not_found => |q| w.print("qualified({s}, {s}) -> NOT FOUND", .{ q.module, q.word }) catch return,
        .not_found => w.writeAll("NOT FOUND") catch return,
    }
    w.writeByte('\n') catch return;

    trace_writer.writeAll(fbs.getWritten());
}

/// Emit a MODULE load line for `--trace-modules`.
pub fn traceModuleLoad(trace_writer: *TraceWriter, name: []const u8, path: []const u8) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.print("MODULE load {s} ({s})\n", .{ name, path }) catch return;
    trace_writer.writeAll(fbs.getWritten());
}

/// Emit a MODULE source load line for `--trace-module-source`.
pub fn traceModuleSourceLoad(
    trace_writer: *TraceWriter,
    kind: ModuleSourceKind,
    name: []const u8,
    path: []const u8,
) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.print("MODULE source load {s} {s} ({s})\n", .{ kind.label(), name, path }) catch return;
    trace_writer.writeAll(fbs.getWritten());
}

/// Emit a MODULE cache-hit line for `--trace-modules`.
pub fn traceModuleCacheHit(trace_writer: *TraceWriter, name: []const u8, path: []const u8) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.print("MODULE cache-hit {s} ({s})\n", .{ name, path }) catch return;
    trace_writer.writeAll(fbs.getWritten());
}

/// Emit a MODULE define line for `--trace-modules`.
pub fn traceModuleDefine(trace_writer: *TraceWriter, module_name: []const u8, word_name: []const u8, mod_word: ModuleWord) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    const kind: []const u8 = switch (mod_word.action) {
        .compound => "compound",
        .native, .host_callback => "native",
    };

    w.print("MODULE define {s}: {s} ({s}", .{ module_name, word_name, kind }) catch return;

    if (mod_word.stack_effect) |effect| {
        w.writeByte(' ') catch return;
        effect.write(w) catch return;
    }

    for (mod_word.markers) |mk| {
        w.print(", {s}", .{mk.name}) catch return;
    }

    w.writeAll(")\n") catch return;
    trace_writer.writeAll(fbs.getWritten());
}

/// Emit a MODULE load-end line for `--trace-modules`.
pub fn traceModuleLoadEnd(trace_writer: *TraceWriter, name: []const u8, word_count: usize) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.print("MODULE load-end {s} ({d} words)\n", .{ name, word_count }) catch return;
    trace_writer.writeAll(fbs.getWritten());
}

/// Emit a MODULE import line for `--trace-modules`.
pub fn traceModuleImport(trace_writer: *TraceWriter, target_source: []const u8, word_name: []const u8, source_module_name: []const u8) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.print("MODULE import {s}: {s} (from {s})\n", .{ target_source, word_name, source_module_name }) catch return;
    trace_writer.writeAll(fbs.getWritten());
}

/// Emit a MODULE deps-push line for `--trace-modules`.
pub fn traceModuleDepsPush(
    trace_writer: *TraceWriter,
    module_name: []const u8,
    words: *const std.StringHashMapUnmanaged(ModuleWord),
    deps: *const std.StringHashMapUnmanaged(ModuleWord),
    max_show: usize,
) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.print("MODULE deps-push {s} [", .{module_name}) catch return;

    const total = deps.count() + words.count();
    var shown: usize = 0;

    var dep_iter = deps.iterator();
    while (dep_iter.next()) |entry| {
        if (shown >= max_show) break;
        if (shown > 0) w.writeAll(", ") catch return;
        w.writeAll(entry.key_ptr.*) catch return;
        shown += 1;
    }

    var word_iter = words.iterator();
    while (word_iter.next()) |entry| {
        if (shown >= max_show) break;
        if (shown > 0) w.writeAll(", ") catch return;
        w.writeAll(entry.key_ptr.*) catch return;
        shown += 1;
    }

    if (total > max_show) {
        w.print(", ... {d} more", .{total - max_show}) catch return;
    }

    w.writeAll("]\n") catch return;
    trace_writer.writeAll(fbs.getWritten());
}

/// Emit a MODULE deps-pop line for `--trace-modules`.
pub fn traceModuleDepsPop(trace_writer: *TraceWriter, module_name: []const u8) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.print("MODULE deps-pop {s}\n", .{module_name}) catch return;
    trace_writer.writeAll(fbs.getWritten());
}

/// Emit a SCOPE-DUMP header line for `--dump-scope`.
pub fn traceDumpScopeHeader(tw: *TraceWriter, name: []const u8, source: []const u8, line: usize) void {
    tw.print("SCOPE-DUMP at {s} ({s}:{d}):\n", .{ name, source, line });
}

/// Emit a single frame line in a scope dump.
pub fn traceDumpScopeFrame(tw: *TraceWriter, prefix: []const u8, index: usize, count: usize, label: ?[]const u8) void {
    if (label) |l| {
        tw.print("  {s}local-frame[{d}]: {d} words ({s})\n", .{ prefix, index, count, l });
    } else {
        tw.print("  {s}local-frame[{d}]: {d} words\n", .{ prefix, index, count });
    }
}

/// Emit a dictionary line in a scope dump.
pub fn traceDumpScopeDict(tw: *TraceWriter, prefix: []const u8, count: usize) void {
    tw.print("  {s}global-dict: {d} words\n", .{ prefix, count });
}

/// Emit a JIT compile line for `--trace-jit`.
pub fn traceJitCompile(trace_writer: *TraceWriter, name: []const u8, word_id: u32) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.print("JIT compile {s} (wid={d})\n", .{ name, word_id }) catch return;
    trace_writer.writeAll(fbs.getWritten());
}

/// Emit a JIT dispatch line for `--trace-jit`.
pub fn traceJitDispatch(trace_writer: *TraceWriter, name: []const u8, word_id: u32, hit: bool) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    const status = if (hit) "hit" else "miss";
    w.print("JIT dispatch {s} (wid={d}) -> {s}\n", .{ name, word_id, status }) catch return;
    trace_writer.writeAll(fbs.getWritten());
}

/// Emit a JIT safepoint line for `--trace-jit`.
pub fn traceJitSafepoint(trace_writer: *TraceWriter, yielded: bool, cancelled: bool) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    if (cancelled) {
        w.writeAll("JIT safepoint -> cancelled\n") catch return;
    } else if (yielded) {
        w.writeAll("JIT safepoint -> yielded\n") catch return;
    } else {
        w.writeAll("JIT safepoint -> no-op\n") catch return;
    }
    trace_writer.writeAll(fbs.getWritten());
}

/// Emit a PIC hit line for `--trace-pic`.
pub fn tracePicHit(trace_writer: *TraceWriter, name: []const u8) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.print("PIC hit {s}\n", .{name}) catch return;
    trace_writer.writeAll(fbs.getWritten());
}

// =============================================================================
// AOT compiler tracing (`--trace-aot`)
//
// Each helper is split into a pure `writeAot*Line` formatter and a thin
// `traceAot*` wrapper that buffers and writes. The formatters take the AOT
// rejection reason as pre-formatted `code` / `message` strings (the caller
// passes `NotCompilableReason.code()` / `.message()`), so this module stays
// decoupled from `ir_codegen.zig`.
// =============================================================================

/// Format a `freeze` per-word discovery line. `kind` is `"compound"` or `"native"`.
pub fn writeAotFreezeWordLine(w: anytype, name: []const u8, kind: []const u8) !void {
    try w.print("AOT freeze word {s} ({s})\n", .{ name, kind });
}

/// Format a `freeze` quotation-discovery line. A quotation has no name, so it is
/// identified by its instruction-body pointer and the caller it was found in.
pub fn writeAotFreezeQuotationLine(w: anytype, caller: []const u8, ptr_key: usize) !void {
    try w.print("AOT freeze quot @0x{x} (in {s})\n", .{ ptr_key, caller });
}

/// Format a `freeze` line naming a parameter type proved from the program's call sites. `index` is
/// the parameter's position among the declared inputs.
pub fn writeAotFreezeParamLine(w: anytype, name: []const u8, index: usize, type_name: []const u8) !void {
    try w.print("AOT freeze param {s} #{d} -> {s}\n", .{ name, index, type_name });
}

/// Format a `codegen` trial-compile line. `kind` is `"word"` or `"quot"`. A null
/// `code` is a success; otherwise `code` / `message` name the rejection reason.
pub fn writeAotCodegenLine(
    w: anytype,
    kind: []const u8,
    name: []const u8,
    code: ?[]const u8,
    message: []const u8,
) !void {
    if (code) |c| {
        try w.print("AOT codegen {s} {s} -> REJECT {s}: {s}\n", .{ kind, name, c, message });
    } else {
        try w.print("AOT codegen {s} {s} -> ok\n", .{ kind, name });
    }
}

/// Format an `effect` compile-to-discover attempt line. A non-null `out_arity`
/// is a success at input arity `in_arity`. A non-null `code` names a categorized
/// rejection. A bare failure carries neither: the arity-sweep just did not fit at
/// this input count and the next arity will be tried, so it reads `-> fail`.
pub fn writeAotEffectAttemptLine(
    w: anytype,
    name: []const u8,
    in_arity: u8,
    out_arity: ?u8,
    code: ?[]const u8,
    message: []const u8,
) !void {
    if (out_arity) |out| {
        try w.print("AOT effect quot {s} (in={d}) -> ok (out={d})\n", .{ name, in_arity, out });
    } else if (code) |c| {
        try w.print("AOT effect quot {s} (in={d}) -> REJECT {s}: {s}\n", .{ name, in_arity, c, message });
    } else {
        try w.print("AOT effect quot {s} (in={d}) -> fail\n", .{ name, in_arity });
    }
}

/// Emit a `freeze` per-word discovery line for `--trace-aot=freeze`.
pub fn traceAotFreezeWord(trace_writer: *TraceWriter, name: []const u8, kind: []const u8) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    writeAotFreezeWordLine(fbs.writer(), name, kind) catch return;
    trace_writer.writeAll(fbs.getWritten());
}

/// Emit a `freeze` quotation-discovery line for `--trace-aot=freeze`.
pub fn traceAotFreezeQuotation(trace_writer: *TraceWriter, caller: []const u8, ptr_key: usize) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    writeAotFreezeQuotationLine(fbs.writer(), caller, ptr_key) catch return;
    trace_writer.writeAll(fbs.getWritten());
}

/// Emit a `freeze` inferred-parameter line for `--trace-aot=freeze`.
pub fn traceAotFreezeParam(trace_writer: *TraceWriter, name: []const u8, index: usize, type_name: []const u8) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    writeAotFreezeParamLine(fbs.writer(), name, index, type_name) catch return;
    trace_writer.writeAll(fbs.getWritten());
}

/// Emit a `codegen` trial-compile line for `--trace-aot=codegen`.
pub fn traceAotCodegen(
    trace_writer: *TraceWriter,
    kind: []const u8,
    name: []const u8,
    code: ?[]const u8,
    message: []const u8,
) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    writeAotCodegenLine(fbs.writer(), kind, name, code, message) catch return;
    trace_writer.writeAll(fbs.getWritten());
}

/// Emit an `effect` compile-to-discover attempt line for `--trace-aot=effect`.
pub fn traceAotEffectAttempt(
    trace_writer: *TraceWriter,
    name: []const u8,
    in_arity: u8,
    out_arity: ?u8,
    code: ?[]const u8,
    message: []const u8,
) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    writeAotEffectAttemptLine(fbs.writer(), name, in_arity, out_arity, code, message) catch return;
    trace_writer.writeAll(fbs.getWritten());
}

/// Format an `instr` per-instruction line. `word` is the enclosing word, `op` the op tag, and
/// `target` the call target (or `"-"` for a non-call op).
///
/// `sp` is the abstract-stack depth going into the instruction, and `has_row` whether a row region
/// is live below it. A failing op leaves its own line as the last one before the rejection, so
/// `sp` / `target` locate the failure to the instruction.
pub fn writeAotInstrLine(w: anytype, word: []const u8, op: []const u8, target: []const u8, sp: usize, has_row: bool, line: usize) !void {
    try w.print("AOT instr {s} op={s} target={s} sp={d} row={} line={d}\n", .{ word, op, target, sp, has_row, line });
}

/// Emit an `instr` per-instruction line for `--trace-aot=instr`.
pub fn traceAotInstr(trace_writer: *TraceWriter, word: []const u8, op: []const u8, target: []const u8, sp: usize, has_row: bool, line: usize) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    writeAotInstrLine(fbs.writer(), word, op, target, sp, has_row, line) catch return;
    trace_writer.writeAll(fbs.getWritten());
}

/// Returns true if `name` matches the given comma-separated pattern.
/// A null pattern matches everything.
pub fn matchesPattern(name: []const u8, pattern: ?[]const u8) bool {
    const pat = pattern orelse return true;
    var iter = std.mem.splitScalar(u8, pat, ',');
    while (iter.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t");
        if (trimmed.len > 0 and std.mem.eql(u8, trimmed, name)) {
            return true;
        }
    }
    return false;
}

// =============================================================================
// Tests
// ============================================================================

test "matchesPattern: null pattern matches everything" {
    try std.testing.expect(matchesPattern("anything", null));
    try std.testing.expect(matchesPattern("", null));
}

test "matchesPattern: single pattern" {
    try std.testing.expect(matchesPattern("foo", "foo"));
    try std.testing.expect(!matchesPattern("bar", "foo"));
}

test "matchesPattern: comma-separated patterns" {
    try std.testing.expect(matchesPattern("foo", "foo,bar,baz"));
    try std.testing.expect(matchesPattern("bar", "foo,bar,baz"));
    try std.testing.expect(matchesPattern("baz", "foo,bar,baz"));
    try std.testing.expect(!matchesPattern("qux", "foo,bar,baz"));
}

test "matchesPattern: whitespace trimming" {
    try std.testing.expect(matchesPattern("foo", " foo , bar "));
    try std.testing.expect(matchesPattern("bar", " foo , bar "));
    try std.testing.expect(!matchesPattern(" foo", " foo , bar "));
}

test "matchesPattern: no match" {
    try std.testing.expect(!matchesPattern("xyz", "foo,bar"));
}

test "TraceConfig.isEnabled: all false" {
    const config = TraceConfig{};
    try std.testing.expect(!config.isEnabled());
}

test "TraceConfig.isEnabled: trace_words" {
    const config = TraceConfig{ .trace_words = true };
    try std.testing.expect(config.isEnabled());
}

test "TraceConfig.isEnabled: trace_resolve" {
    const config = TraceConfig{ .trace_resolve = true };
    try std.testing.expect(config.isEnabled());
}

test "TraceConfig.isEnabled: trace_modules any category" {
    const config = TraceConfig{ .trace_modules = .{ .lifecycle = true } };
    try std.testing.expect(config.isEnabled());
}

test "TraceConfig.isEnabled: trace_modules all categories" {
    const config = TraceConfig{ .trace_modules = ModuleTraceCategories.all() };
    try std.testing.expect(config.isEnabled());
}

test "TraceConfig.isEnabled: trace_modules empty" {
    const config = TraceConfig{ .trace_modules = .{} };
    try std.testing.expect(!config.isEnabled());
}

test "ModuleTraceCategories.any" {
    try std.testing.expect(!(ModuleTraceCategories{}).any());
    try std.testing.expect((ModuleTraceCategories{ .source = true }).any());
    try std.testing.expect(ModuleTraceCategories.all().any());
}

test "ModuleTraceCategories.all" {
    const cats = ModuleTraceCategories.all();
    try std.testing.expect(cats.lifecycle);
    try std.testing.expect(cats.source);
    try std.testing.expect(cats.define);
    try std.testing.expect(cats.import);
    try std.testing.expect(cats.deps);
}

test "parseModuleTraceCategories: single category" {
    const cats = try parseModuleTraceCategories("source");
    try std.testing.expect(cats.source);
    try std.testing.expect(!cats.lifecycle);
    try std.testing.expect(!cats.define);
    try std.testing.expect(!cats.import);
    try std.testing.expect(!cats.deps);
}

test "parseModuleTraceCategories: multiple categories" {
    const cats = try parseModuleTraceCategories("lifecycle,source,deps");
    try std.testing.expect(cats.lifecycle);
    try std.testing.expect(cats.source);
    try std.testing.expect(cats.deps);
    try std.testing.expect(!cats.define);
    try std.testing.expect(!cats.import);
}

test "parseModuleTraceCategories: all five" {
    const cats = try parseModuleTraceCategories("lifecycle,source,define,import,deps");
    try std.testing.expect(cats.lifecycle);
    try std.testing.expect(cats.source);
    try std.testing.expect(cats.define);
    try std.testing.expect(cats.import);
    try std.testing.expect(cats.deps);
}

test "parseModuleTraceCategories: whitespace trimming" {
    const cats = try parseModuleTraceCategories(" lifecycle , source ");
    try std.testing.expect(cats.lifecycle);
    try std.testing.expect(cats.source);
}

test "parseModuleTraceCategories: empty value" {
    try std.testing.expectError(error.EmptyValue, parseModuleTraceCategories(""));
}

test "parseModuleTraceCategories: empty segment" {
    try std.testing.expectError(error.EmptyValue, parseModuleTraceCategories("source,,deps"));
}

test "parseModuleTraceCategories: unknown category" {
    try std.testing.expectError(error.UnknownCategory, parseModuleTraceCategories("bogus"));
    try std.testing.expectError(error.UnknownCategory, parseModuleTraceCategories("source,bogus"));
}

test "AotTraceCategories.any" {
    try std.testing.expect(!(AotTraceCategories{}).any());
    try std.testing.expect((AotTraceCategories{ .freeze = true }).any());
    try std.testing.expect((AotTraceCategories{ .instr = true }).any());
}

test "AotTraceCategories.perWordAxes enables the three per-word axes, not instr" {
    const cats = AotTraceCategories.perWordAxes();
    try std.testing.expect(cats.freeze);
    try std.testing.expect(cats.codegen);
    try std.testing.expect(cats.effect);
    try std.testing.expect(!cats.instr);
}

test "parseAotTraceCategories: single category" {
    const cats = try parseAotTraceCategories("codegen");
    try std.testing.expect(cats.codegen);
    try std.testing.expect(!cats.freeze);
    try std.testing.expect(!cats.effect);
    try std.testing.expect(!cats.instr);
}

test "parseAotTraceCategories: multiple categories" {
    const cats = try parseAotTraceCategories("freeze,effect");
    try std.testing.expect(cats.freeze);
    try std.testing.expect(cats.effect);
    try std.testing.expect(!cats.codegen);
    try std.testing.expect(!cats.instr);
}

test "parseAotTraceCategories: all four" {
    const cats = try parseAotTraceCategories("freeze,codegen,effect,instr");
    try std.testing.expect(cats.freeze);
    try std.testing.expect(cats.codegen);
    try std.testing.expect(cats.effect);
    try std.testing.expect(cats.instr);
}

test "parseAotTraceCategories: whitespace trimming" {
    const cats = try parseAotTraceCategories(" freeze , codegen ");
    try std.testing.expect(cats.freeze);
    try std.testing.expect(cats.codegen);
}

test "parseAotTraceCategories: empty value" {
    try std.testing.expectError(error.EmptyValue, parseAotTraceCategories(""));
}

test "parseAotTraceCategories: empty segment" {
    try std.testing.expectError(error.EmptyValue, parseAotTraceCategories("freeze,,effect"));
}

test "parseAotTraceCategories: unknown category" {
    try std.testing.expectError(error.UnknownCategory, parseAotTraceCategories("bogus"));
    try std.testing.expectError(error.UnknownCategory, parseAotTraceCategories("freeze,bogus"));
}

test "writeAotFreezeWordLine" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeAotFreezeWordLine(&w, "static-file-handler", "compound");
    try std.testing.expectEqualStrings("AOT freeze word static-file-handler (compound)\n", w.buffered());
}

test "writeAotFreezeQuotationLine" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeAotFreezeQuotationLine(&w, "serve-loop", 0x10a3f0);
    try std.testing.expectEqualStrings("AOT freeze quot @0x10a3f0 (in serve-loop)\n", w.buffered());
}

test "writeAotCodegenLine: success" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeAotCodegenLine(&w, "word", "static-file-handler", null, "");
    try std.testing.expectEqualStrings("AOT codegen word static-file-handler -> ok\n", w.buffered());
}

test "writeAotCodegenLine: rejection names the word and its reason" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeAotCodegenLine(&w, "word", "static-file-handler", "NC.13", "word body underflows the abstract stack (row-variable effects)");
    try std.testing.expectEqualStrings(
        "AOT codegen word static-file-handler -> REJECT NC.13: word body underflows the abstract stack (row-variable effects)\n",
        w.buffered(),
    );
}

test "writeAotEffectAttemptLine: success" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeAotEffectAttemptLine(&w, "pick-quot/quot", 1, 1, null, "");
    try std.testing.expectEqualStrings("AOT effect quot pick-quot/quot (in=1) -> ok (out=1)\n", w.buffered());
}

test "writeAotEffectAttemptLine: rejection" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeAotEffectAttemptLine(&w, "pick-quot/quot", 2, null, "NC.13", "word body underflows the abstract stack (row-variable effects)");
    try std.testing.expectEqualStrings(
        "AOT effect quot pick-quot/quot (in=2) -> REJECT NC.13: word body underflows the abstract stack (row-variable effects)\n",
        w.buffered(),
    );
}

test "writeAotEffectAttemptLine: bare arity-sweep miss" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeAotEffectAttemptLine(&w, "onez_q_12", 0, null, null, "");
    try std.testing.expectEqualStrings("AOT effect quot onez_q_12 (in=0) -> fail\n", w.buffered());
}

test "writeAotInstrLine: call op locates an underflow to the instruction" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeAotInstrLine(&w, "bad-word", "call_word", "+", 1, false, 7);
    try std.testing.expectEqualStrings("AOT instr bad-word op=call_word target=+ sp=1 row=false line=7\n", w.buffered());
}

test "writeAotInstrLine: push_literal has no call target" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeAotInstrLine(&w, "greet", "push_literal", "-", 0, false, 3);
    try std.testing.expectEqualStrings("AOT instr greet op=push_literal target=- sp=0 row=false line=3\n", w.buffered());
}

test "writeAotInstrLine: live row region" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeAotInstrLine(&w, "loop-body", "call_word", "swap", 2, true, 12);
    try std.testing.expectEqualStrings("AOT instr loop-body op=call_word target=swap sp=2 row=true line=12\n", w.buffered());
}

test "ModuleSourceKind.label" {
    try std.testing.expectEqualStrings("embedded", ModuleSourceKind.embedded.label());
    try std.testing.expectEqualStrings("filesystem", ModuleSourceKind.filesystem.label());
}

test "TraceConfig.isEnabled: trace_container_detect" {
    const config = TraceConfig{ .trace_container_detect = true };
    try std.testing.expect(config.isEnabled());
}

test "TraceConfig.isEnabled: dump_scope" {
    const config = TraceConfig{ .dump_scope = "foo" };
    try std.testing.expect(config.isEnabled());
}

test "formatStackPreview: empty stack" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const stack = Stack.init(std.testing.allocator);
    formatStackPreview(&stack, fbs.writer(), 3);
    try std.testing.expectEqualStrings("stack=[]", fbs.getWritten());
}

test "formatStackPreview: single value" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();
    try stack.push(.{ .fixnum = 42 });

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    formatStackPreview(&stack, fbs.writer(), 3);
    try std.testing.expectEqualStrings("stack=[fixnum:42]", fbs.getWritten());
}

test "formatStackPreview: mixed types" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();
    try stack.push(.{ .fixnum = 1 });
    try stack.push(.{ .boolean = true });
    try stack.push(.{ .string = "hi" });

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    formatStackPreview(&stack, fbs.writer(), 3);
    try std.testing.expectEqualStrings("stack=[fixnum:1 boolean:t string:\"hi\"]", fbs.getWritten());
}

test "formatStackPreview: overflow with ellipsis" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();
    try stack.push(.{ .fixnum = 1 });
    try stack.push(.{ .fixnum = 2 });
    try stack.push(.{ .fixnum = 3 });
    try stack.push(.{ .fixnum = 4 });

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    formatStackPreview(&stack, fbs.writer(), 3);
    try std.testing.expectEqualStrings("stack=[... fixnum:2 fixnum:3 fixnum:4]", fbs.getWritten());
}

test "writeValuePreview: string truncation" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeValuePreview(.{ .string = "this is a very long string that exceeds twenty" }, fbs.writer());
    try std.testing.expectEqualStrings("\"this is a very long ...\"", fbs.getWritten());
}

test "writeValuePreview: short string" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeValuePreview(.{ .string = "short" }, fbs.writer());
    try std.testing.expectEqualStrings("\"short\"", fbs.getWritten());
}

test "writeValuePreview: symbol" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeValuePreview(.{ .symbol = "foo" }, fbs.writer());
    try std.testing.expectEqualStrings("foo:", fbs.getWritten());
}
