const std = @import("std");
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

/// Error returned by `parseModuleTraceCategories` when the value is malformed.
pub const ParseModuleTraceError = error{
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

/// Configuration for execution tracing.
pub const TraceConfig = struct {
    trace_words: bool = false,
    trace_words_pattern: ?[]const u8 = null,
    trace_resolve: bool = false,
    trace_resolve_pattern: ?[]const u8 = null,
    trace_modules: ModuleTraceCategories = .{},
    trace_jit: bool = false,
    trace_pic: bool = false,
    trace_container_detect: bool = false,
    dump_scope: ?[]const u8 = null,

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
pub const TraceWriter = struct {
    file: File,

    pub fn init() TraceWriter {
        return .{ .file = .stderr() };
    }

    pub fn print(self: *TraceWriter, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        var w = self.file.writer(&buf);
        w.interface.print(fmt, args) catch return;
        w.interface.flush() catch return;
    }

    pub fn writeAll(self: *TraceWriter, bytes: []const u8) void {
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
        .array => |items| try writer.print("<array:{d}>", .{items.len}),
        .vector => |v| try writer.print("<vector:{d}>", .{v.list.items.len}),
        .byte_array => |b| try writer.print("<byte-array:{d}>", .{b.slice().len}),
        .set => |s| try writer.print("<set:{d}>", .{s.count()}),
        .hash => |h| try writer.print("<hash:{d}>", .{h.count()}),
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
        .benchmark_report => try writer.writeAll("<benchmark-report>"),
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
