const std = @import("std");
const Allocator = std.mem.Allocator;

const Dictionary = @import("dictionary.zig").Dictionary;
const WordDefinition = @import("dictionary.zig").WordDefinition;
const NativeFn = @import("dictionary.zig").NativeFn;
const StackEffect = @import("stack_effect.zig").StackEffect;

const value_mod = @import("value.zig");
const Module = value_mod.Module;
const ModuleWord = value_mod.ModuleWord;
const Instruction = value_mod.Instruction;

const primitives_mod = @import("primitives/mod.zig");
pub const InterpreterError = primitives_mod.InterpreterError;
const Primitive = primitives_mod.Primitive;
const makeBoxedEffect = primitives_mod.makeBoxedEffect;
const all_primitives = primitives_mod.extracted_primitives;
const all_registry_entries = primitives_mod.extracted_registry_entries;

const dispatch_mod = @import("dispatch.zig");
const DispatchTable = dispatch_mod.DispatchTable;

const arithmetic_mod = @import("primitives/arithmetic.zig");
const bitwise_mod = @import("primitives/bitwise.zig");
const sequences_mod = @import("primitives/sequences.zig");
const strings_mod = @import("primitives/strings.zig");
const associative_mod = @import("primitives/associative.zig");

const Context = @import("context.zig").Context;

/// The natives whose `defines_word` flag is set, drawn from both the global primitives and the
/// `native`-module registry entries.
///
/// Two parallel views of one set: the resolvers hold a `NativeFn` and match by identity, while the
/// define-site assertion holds only the name it recorded. A function registered under two names
/// appears twice, which both linear scans tolerate.
const defining_natives_buf = blk: {
    @setEvalBranchQuota(8_000_000);
    const upper_bound = all_primitives.len + all_registry_entries.len;
    var funcs: [upper_bound]NativeFn = undefined;
    var names: [upper_bound][]const u8 = undefined;
    var n: usize = 0;
    for (all_primitives) |p| {
        if (!p.defines_word) continue;
        funcs[n] = p.func;
        names[n] = p.name;
        n += 1;
    }
    for (all_registry_entries) |e| {
        if (!e.defines_word) continue;
        funcs[n] = e.func;
        names[n] = e.name;
        n += 1;
    }
    break :blk .{ .funcs = funcs, .names = names, .count = n };
};

const defining_natives: [defining_natives_buf.count]NativeFn = defining_natives_buf.funcs[0..defining_natives_buf.count].*;
const defining_native_names: [defining_natives_buf.count][]const u8 = defining_natives_buf.names[0..defining_natives_buf.count].*;

/// Whether calling `func` can install a word definition. See `Primitive.defines_word`.
pub fn nativeDefinesWord(func: NativeFn) bool {
    for (defining_natives) |f| {
        if (f == func) return true;
    }
    return false;
}

/// Whether the native named `name` can install a word definition. A `native`-module registry entry
/// is keyed by its bare name here, the spelling `Context.current_native` records.
pub fn nativeNameDefinesWord(name: []const u8) bool {
    for (defining_native_names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

pub fn registerPrimitives(dict: *Dictionary, allocator: Allocator, dispatch_counter: *std.atomic.Value(u32)) !void {
    for (all_primitives) |p| {
        const effect: ?*const StackEffect = if (p.stack_effect) |raw|
            try makeBoxedEffect(allocator, raw)
        else
            null;

        try dict.put(p.name, WordDefinition{
            .name = p.name,
            .parse_time = p.parse_time,
            .parse_time_only = p.parse_time_only,
            .effect_transparent = p.effect_transparent,
            .stack_effect = effect,
            .markers = p.markers,
            .doc = p.doc,
            .capability = p.capability,
            .dispatch_id = dispatch_counter.fetchAdd(1, .monotonic),
            .action = .{ .native = p.func },
        });
    }
}

pub fn registerNativeDispatch(dispatch: *DispatchTable, ctx: *Context) !void {
    try arithmetic_mod.registerNativeDispatch(dispatch, ctx);
    try bitwise_mod.registerNativeDispatch(dispatch, ctx);
    try sequences_mod.registerNativeDispatch(dispatch, ctx);
    try strings_mod.registerNativeDispatch(dispatch, ctx);
    try associative_mod.registerNativeDispatch(dispatch, ctx);
}

pub fn createNativeModule(dict: *Dictionary, allocator: Allocator, dispatch_counter: *std.atomic.Value(u32)) !void {
    const module = try allocator.create(Module);
    module.* = .{
        .name = "native",
        .words = .{},
        .importable = false,
    };

    for (all_registry_entries) |entry| {
        const effect: ?*const StackEffect = if (entry.stack_effect) |raw|
            try makeBoxedEffect(allocator, raw)
        else
            null;
        try module.words.put(allocator, entry.name, .{
            .action = .{ .native = entry.func },
            .stack_effect = effect,
            .polymorphic = entry.polymorphic,
            .capability = entry.capability,
            .dispatch_id = dispatch_counter.fetchAdd(1, .monotonic),
        });
    }

    const instrs = try allocator.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .push_literal = .{ .module = module } }, .line = 0 };
    try dict.put("native", .{
        .name = "native",
        .dispatch_id = dispatch_counter.fetchAdd(1, .monotonic),
        .action = .{ .compound = instrs },
    });
}

test "the defines_word set is exactly the natives known to install a definition" {
    // Every entry reaches `Context.defineWord` / `defineImportedWord` itself, runs arbitrary
    // source that does, or invokes a word chosen at runtime that does. Changing this list changes
    // whether compiled quotation dispatch brackets a body, so the set is pinned rather than left
    // to drift.
    //
    // The list is what review found. A native that reaches a define without declaring it trips the
    // Debug-only assertion at both choke points, which is the net this test cannot be.
    const expected = [_][]const u8{
        "@get",
        ";",
        "borrow-deps",
        "define-builtin-type",
        "define-enum",
        "define-ffi-struct",
        "define-parameter",
        "define-parameterized-type",
        "define-protocol",
        "define-struct",
        "define-virtual",
        "eval-string",
        "import",
        "load-check-file",
        "load-file",
        "reload-file",
    };

    try std.testing.expectEqual(expected.len, defining_native_names.len);
    for (expected) |name| {
        try std.testing.expect(nativeNameDefinesWord(name));
    }

    // `define-method` writes only the dispatch table, and `compile!` compiles a word that already
    // exists. Neither installs a binding, so neither belongs in the set.
    try std.testing.expect(!nativeNameDefinesWord("define-method"));
    try std.testing.expect(!nativeNameDefinesWord("compile!"));
    try std.testing.expect(!nativeNameDefinesWord("call"));
}

test "nativeDefinesWord answers by function identity" {
    try std.testing.expect(nativeDefinesWord(primitives_mod.control.nativeSemicolon));
    try std.testing.expect(!nativeDefinesWord(primitives_mod.control.nativeCall));
}
