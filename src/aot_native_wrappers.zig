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

const data_structures = @import("primitives/data_structures.zig");
const associative = @import("primitives/associative.zig");
const stack_prims = @import("primitives/stack.zig");

const extracted_registry_entries = @import("primitives/mod.zig").extracted_registry_entries;

/// Build the wrapper body for one native. Mirrors `jitNativeCall`.
pub fn AotDirectWrapper(comptime func: NativeFn) type {
    return struct {
        fn call(ctx_raw: usize) callconv(.c) i32 {
            if (ctx_raw == 0) return 1;
            const ctx: *Context = @ptrFromInt(ctx_raw);
            func(ctx) catch |err| {
                ctx.jit_pending_error = err;
                return 2;
            };
            return 0;
        }
    };
}

/// A native word that AOT codegen invokes through a directly-linked `callconv(.c)` wrapper rather
/// than the runtime-resolving `jitNativeWordCall`.
///
/// The wrapper calls the same native the interpreter uses, so the emitted call carries no
/// interpreter fallback and survives the zero-fallback interpreter-free class, where the dispatch
/// table the word_id lookup needs is stripped from the binary.
///
/// Covers the concrete-arity container construction, mutation, and access natives plus the runtime-
/// depth indexed stack ops; each is a plain native that does its own internal type handling and
/// bounds checking, so a direct call is complete on its own.
const AotDirectNative = struct {
    name: []const u8,
    symbol: []const u8,
    func: NativeFn,
};

const aot_direct_natives = [_]AotDirectNative{
    .{ .name = "make-mutable-map", .symbol = "onez_native_make_mutable_map", .func = data_structures.nativeMakeMutableMap },
    .{ .name = "make-vector", .symbol = "onez_native_make_vector", .func = data_structures.nativeMakeVector },
    .{ .name = "@set!", .symbol = "onez_native_at_set_mut", .func = data_structures.nativeAtSetMut },
    .{ .name = "@set", .symbol = "onez_native_at_set", .func = associative.nativeAtSet },
    .{ .name = "@get", .symbol = "onez_native_at_get", .func = associative.nativeAtGet },
    // `drop` over an opaque row region pops one live value through the native
    // and keeps the row, so the call must link without a fallback too.
    .{ .name = "drop", .symbol = "onez_native_drop", .func = stack_prims.nativeDrop },
    // Runtime-depth indexed stack ops: codegen emits these against the live
    // stack when the depth is not a folded literal (e.g. `drop-at` -> `<rot-n`).
    .{ .name = "<rot-n", .symbol = "onez_native_rot_up", .func = stack_prims.nativeRotUp },
    .{ .name = "rot-n>", .symbol = "onez_native_rot_down", .func = stack_prims.nativeRotDown },
    .{ .name = "pick-n", .symbol = "onez_native_pick_n", .func = stack_prims.nativePickN },
    .{ .name = "nip-n", .symbol = "onez_native_nip_n", .func = stack_prims.nativeNipN },
};

/// The AOT-direct wrapper symbol for `name`, or null if the word is not in the directly-linked set
/// and must route through `jitNativeWordCall`.
pub fn aotDirectWrapperSymbol(name: []const u8) ?[]const u8 {
    for (aot_direct_natives) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.symbol;
    }
    return null;
}

comptime {
    for (aot_direct_natives) |entry| {
        @export(&AotDirectWrapper(entry.func).call, .{ .name = entry.symbol });
    }
}

/// `extern` declarations for the curated AOT-direct wrapper symbols, emitted into the generated C
/// preamble so direct calls to them resolve at link time.
pub const aot_direct_native_externs = blk: {
    var s: []const u8 = "";
    for (aot_direct_natives) |entry| {
        s = s ++ "extern int32_t " ++ entry.symbol ++ "(uintptr_t ctx);\n";
    }
    break :blk s;
};

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

comptime {
    @setEvalBranchQuota(2_000_000);
    const entries = extracted_registry_entries;
    var symbols: [entries.len][]const u8 = undefined;
    for (entries, 0..) |entry, i| symbols[i] = wrapperSymbolName(entry.name);

    // Guard against two distinct registry names mangling to the same symbol (the `-`/`_` ambiguity).
    // If this ever trips, disambiguate the colliding name with a registry-index suffix.
    for (symbols, 0..) |a, i| {
        for (symbols[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a, b)) {
                @compileError("native wrapper symbol collision: '" ++ entries[i].name ++ "' collides on " ++ a);
            }
        }
    }

    for (entries, 0..) |entry, i| {
        @export(&AotDirectWrapper(entry.func).call, .{ .name = symbols[i] });
    }
}

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
        const sym = comptime wrapperSymbolName(entry.name);
        try testing.expect(std.mem.startsWith(u8, sym, "onez_n_"));
        const gop = try seen.getOrPut(sym);
        try testing.expect(!gop.found_existing);
    }

    try testing.expectEqual(extracted_registry_entries.len, seen.count());
}

test "wrapper symbol name mirrors mangling with onez_n_ prefix" {
    try testing.expectEqualStrings("onez_n_cmp", wrapperSymbolName("cmp"));
    try testing.expectEqualStrings("onez_n__Aset_B", wrapperSymbolName("@set!"));
    try testing.expectEqualStrings("onez_n__Hmap", wrapperSymbolName("#map"));
    try testing.expectEqualStrings("onez_n__Qor_else", wrapperSymbolName("?or-else"));
    try testing.expectEqualStrings("onez_n__Gfloat", wrapperSymbolName(">float"));
}

test "wrapper invokes its native: borrowed? on a fixnum returns false" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .fixnum = 7 });

    const wrapper = AotDirectWrapper(registryFunc("borrowed?")).call;
    const status = wrapper(@intFromPtr(&ctx));

    try testing.expectEqual(@as(i32, 0), status);
    const top = try ctx.stack.pop();
    try testing.expect(top == .boolean);
    try testing.expectEqual(false, top.boolean);
}

test "wrapper maps a native error to status 2 and sets the pending error" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // Empty stack: `borrowed?` pops an operand and underflows.
    const wrapper = AotDirectWrapper(registryFunc("borrowed?")).call;
    const status = wrapper(@intFromPtr(&ctx));

    try testing.expectEqual(@as(i32, 2), status);
    try testing.expect(ctx.jit_pending_error != null);
}

test "wrapper bails with status 1 on a null context" {
    const wrapper = AotDirectWrapper(registryFunc("borrowed?")).call;
    try testing.expectEqual(@as(i32, 1), wrapper(0));
}
