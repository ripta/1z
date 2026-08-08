//! AOT-direct native wrappers.
//!
//! AOT-compiled code cannot bake live native function pointers the way the JIT does, so a native
//! call would otherwise route through `jitNativeWordCall`, which performs a runtime dispatch-table
//! lookup before the indirect call.
//!
//! This module generates a thin `callconv(.c)` wrapper for each native and exports it under a stable
//! C symbol, so AOT codegen can emit a direct call into the wrapper with no runtime resolution step.

const std = @import("std");

const Context = @import("context.zig").Context;
const NativeFn = @import("dictionary.zig").NativeFn;
const Marker = @import("value.zig").Marker;

const markers_mod = @import("primitives/markers.zig");

const extracted_primitives = @import("primitives/mod.zig").extracted_primitives;
const extracted_registry_entries = @import("primitives/mod.zig").extracted_registry_entries;

/// Build the wrapper body for one native. Mirrors `jitNativeWordCall` minus the runtime
/// dispatch-table lookup and generic dispatch: it pushes the native's call frame, invokes the
/// native, and runs the same success / error cleanup. Preserving the frame and cleanup keeps the
/// word name and stack effect on an error so AOT diagnostics match the interpreter; `line_raw` is
/// the call-site line, used for the frame.
pub fn AotDirectWrapper(comptime func: NativeFn, comptime word_name: []const u8) type {
    return struct {
        fn call(ctx_raw: usize, line_raw: usize) callconv(.c) i32 {
            if (ctx_raw == 0) return 1;
            const ctx: *Context = @ptrFromInt(ctx_raw);
            ctx.pushCallFrame(word_name, ctx.current_source, line_raw, 0);
            func(ctx) catch |err| {
                ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, err);
                return 2;
            };
            ctx.wordSuccessCleanup(word_name, null) catch |err| {
                ctx.jit_pending_error = err;
                return 2;
            };
            return 0;
        }
    };
}

/// Convert a 1z word name to the C symbol of its generated native wrapper.
///
/// Mirrors `ir_codegen.mangleWordName`'s per-character escaping, but with the `onez_n_` (native)
/// prefix instead of `onez_w_` (word), so a native wrapper never collides with a compiled
/// compound-word symbol of the same name.
pub fn wrapperSymbolName(comptime name: []const u8) []const u8 {
    return comptime blk: {
        var result: []const u8 = "onez_n_";
        for (name) |ch| {
            const piece: []const u8 = switch (ch) {
                'a'...'z', 'A'...'Z', '0'...'9', '_' => &[_]u8{ch},
                '-' => "_",
                '#' => "_H",
                '@' => "_A",
                '?' => "_Q",
                '!' => "_B",
                '*' => "_S",
                '+' => "_P",
                '/' => "_D",
                '<' => "_L",
                '>' => "_G",
                '=' => "_E",
                '.' => "_O",
                ':' => "_C",
                else => std.fmt.comptimePrint("_x{X:0>2}_", .{ch}),
            };
            result = result ++ piece;
        }
        break :blk result;
    };
}

/// A native word paired with the C symbol of its generated wrapper. The symbol is
/// sentinel-terminated so it can be handed straight to `ir_str` as a C string.
///
/// `name` is the word name compiled code resolves against, not the bare dictionary name. A global
/// primitive is reached bare, and a `native`-module registry entry is reached only through its
/// `native.`-qualified name, so the two never share a key.
const NativeWrapper = struct {
    name: []const u8,
    func: NativeFn,
    symbol: [:0]const u8,
};

/// True when a primitive carries the generic marker, so its dictionary word dispatches to
/// registered methods. Such a native must keep routing through `jitNativeWordCall`, whose
/// generic dispatch the thin wrapper does not replicate, so it is excluded from the direct set.
fn primitiveIsGeneric(comptime mks: []const *Marker) bool {
    for (mks) |mk| {
        if (markers_mod.isGenericMarker(mk)) return true;
    }
    return false;
}

const wrappers_upper_bound = extracted_primitives.len + extracted_registry_entries.len;

/// The module qualifier every `native`-module registry entry is reached through. The module is
/// marked non-importable, so a registry entry has no bare-name spelling in compiled code.
const native_module_prefix = "native.";

/// The non-generic native surface that AOT codegen can direct-call, drawn from both the global
/// primitives and the `native`-module registry entries.
///
/// Each entry is keyed by the name codegen resolves against, so a registry entry is keyed
/// `native.<name>` and a primitive by its bare name. `file-info` and `list-directory` exist in both
/// sets, and keying by the resolved name keeps them as two independent wrappers instead of forcing
/// one to displace the other.
///
/// Registry-entry natives carry no markers in the dictionary, so none of them dispatch generically
/// and all are eligible. Their `polymorphic` flag drives effect inference, not method dispatch.
const direct_natives_buf = blk: {
    @setEvalBranchQuota(8_000_000);
    var buf: [wrappers_upper_bound]NativeWrapper = undefined;
    var n: usize = 0;
    for (extracted_primitives) |p| {
        if (primitiveIsGeneric(p.markers)) continue;
        buf[n] = .{ .name = p.name, .func = p.func, .symbol = std.fmt.comptimePrint("{s}", .{wrapperSymbolName(p.name)}) };
        n += 1;
    }
    for (extracted_registry_entries) |e| {
        const qualified = native_module_prefix ++ e.name;
        buf[n] = .{ .name = qualified, .func = e.func, .symbol = std.fmt.comptimePrint("{s}", .{wrapperSymbolName(qualified)}) };
        n += 1;
    }

    // Guard against two distinct names mangling to the same symbol (the `-`/`_` ambiguity).
    // If this ever trips, disambiguate the colliding name with an index suffix.
    for (buf[0..n], 0..) |a, i| {
        for (buf[i + 1 .. n]) |b| {
            if (std.mem.eql(u8, a.symbol, b.symbol)) {
                @compileError("native wrapper symbol collision: '" ++ a.name ++ "' and '" ++ b.name ++ "' both mangle to " ++ a.symbol);
            }
        }
    }

    break :blk .{ .buf = buf, .count = n };
};

const direct_natives: [direct_natives_buf.count]NativeWrapper = direct_natives_buf.buf[0..direct_natives_buf.count].*;

comptime {
    for (direct_natives) |w| {
        @export(&AotDirectWrapper(w.func, w.name).call, .{ .name = w.symbol });
    }
}

/// The generated wrapper symbol for the non-generic native `name`, or null if `name` is generic
/// or not a native. AOT codegen emits a direct call into the wrapper instead of the
/// runtime-resolving `jitNativeWordCall`.
///
/// `name` must be spelled the way codegen resolved it. A `native`-module registry entry is keyed
/// under its `native.`-qualified name, so passing the bare name misses.
pub fn registryWrapperSymbol(name: []const u8) ?[:0]const u8 {
    for (direct_natives) |w| {
        if (std.mem.eql(u8, w.name, name)) return w.symbol;
    }
    return null;
}

/// `extern` declarations for every generated wrapper symbol, emitted into the generated C
/// preamble so direct calls to them resolve at link time.
pub const registry_wrapper_externs = blk: {
    @setEvalBranchQuota(8_000_000);
    var s: []const u8 = "";
    for (direct_natives) |w| {
        s = s ++ "extern int32_t " ++ w.symbol ++ "(uintptr_t ctx, uintptr_t line);\n";
    }
    break :blk s;
};

// Tests

const testing = std.testing;

/// Look up a registry native's function by 1z word name, for tests that drive a generated wrapper directly.
fn registryFunc(comptime name: []const u8) NativeFn {
    inline for (extracted_registry_entries) |entry| {
        if (comptime std.mem.eql(u8, entry.name, name)) return entry.func;
    }
    @compileError("no registry entry named " ++ name);
}

test "wrapper symbol generated and unique for every registry entry" {
    @setEvalBranchQuota(2_000_000);
    var seen = std.StringHashMap(void).init(testing.allocator);
    defer seen.deinit();

    inline for (extracted_registry_entries) |entry| {
        const sym = comptime wrapperSymbolName(native_module_prefix ++ entry.name);
        try testing.expect(std.mem.startsWith(u8, sym, "onez_n_"));
        const gop = try seen.getOrPut(sym);
        try testing.expect(!gop.found_existing);
    }

    try testing.expectEqual(extracted_registry_entries.len, seen.count());
}

test "registryWrapperSymbol resolves non-generic natives and rejects unknown names" {
    // A non-generic global primitive resolves to a usable, prefixed C string.
    const flush = registryWrapperSymbol("stream-flush") orelse return error.MissingWrapper;
    try testing.expect(std.mem.startsWith(u8, flush, "onez_n_"));
    try testing.expectEqual(@as(u8, 0), flush.ptr[flush.len]); // sentinel terminator past the slice end

    // A registry-entry native resolves under the qualified name codegen emits, not the bare one.
    try testing.expect(registryWrapperSymbol("native.borrowed?") != null);
    try testing.expect(registryWrapperSymbol("borrowed?") == null);

    // An unknown name does not.
    try testing.expect(registryWrapperSymbol("definitely-not-a-native-word") == null);
    try testing.expect(registryWrapperSymbol("native.definitely-not-a-native-word") == null);
}

test "registryWrapperSymbol resolves the value constructors a locked build needs" {
    // Every non-builtin construction path bottoms out in one of these. Missing any of them makes
    // the whole category uncompilable under `--lock-interpreter-setting`.
    try testing.expect(registryWrapperSymbol("native.virtual-wrap") != null);
    try testing.expect(registryWrapperSymbol("native.virtual-struct-wrap") != null);
    try testing.expect(registryWrapperSymbol("native.make-struct-instance") != null);
    try testing.expect(registryWrapperSymbol("native.struct-field-get") != null);
}

test "a name in both the primitive and registry sets keeps a wrapper per origin" {
    // `file-info` and `list-directory` are registered both globally and in the `native` module.
    // Keying by the resolved name gives each origin its own wrapper instead of dropping one.
    const bare = registryWrapperSymbol("file-info") orelse return error.MissingWrapper;
    const qualified = registryWrapperSymbol("native.file-info") orelse return error.MissingWrapper;
    try testing.expect(!std.mem.eql(u8, bare, qualified));

    try testing.expect(registryWrapperSymbol("list-directory") != null);
    try testing.expect(registryWrapperSymbol("native.list-directory") != null);
}

test "registryWrapperSymbol excludes generic natives so they keep generic dispatch" {
    // Arithmetic and comparison natives carry the generic marker; they must stay on
    // `jitNativeWordCall` and therefore have no direct wrapper.
    try testing.expect(registryWrapperSymbol("+") == null);
    try testing.expect(registryWrapperSymbol("=") == null);
    try testing.expect(registryWrapperSymbol("<") == null);
}

test "wrapper symbol name mirrors mangling with onez_n_ prefix" {
    try testing.expectEqualStrings("onez_n_cmp", wrapperSymbolName("cmp"));
    try testing.expectEqualStrings("onez_n__Aset_B", wrapperSymbolName("@set!"));
    try testing.expectEqualStrings("onez_n__Hmap", wrapperSymbolName("#map"));
    try testing.expectEqualStrings("onez_n__Qor_else", wrapperSymbolName("?or-else"));
    try testing.expectEqualStrings("onez_n__Gfloat", wrapperSymbolName(">float"));
    try testing.expectEqualStrings("onez_n_native_Ovirtual_wrap", wrapperSymbolName("native.virtual-wrap"));
}

test "wrapper invokes its native: borrowed? on a fixnum returns false" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .fixnum = 7 });

    const wrapper = AotDirectWrapper(registryFunc("borrowed?"), "borrowed?").call;
    const status = wrapper(@intFromPtr(&ctx), 0);

    try testing.expectEqual(@as(i32, 0), status);
    const top = try ctx.stack.pop();
    try testing.expect(top == .boolean);
    try testing.expectEqual(false, top.boolean);
}

test "wrapper maps a native error to status 2 and sets the pending error" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // Empty stack: `borrowed?` pops an operand and underflows.
    const wrapper = AotDirectWrapper(registryFunc("borrowed?"), "borrowed?").call;
    const status = wrapper(@intFromPtr(&ctx), 0);

    try testing.expectEqual(@as(i32, 2), status);
    try testing.expect(ctx.jit_pending_error != null);
}

test "wrapper bails with status 1 on a null context" {
    const wrapper = AotDirectWrapper(registryFunc("borrowed?"), "borrowed?").call;
    try testing.expectEqual(@as(i32, 1), wrapper(0, 0));
}
