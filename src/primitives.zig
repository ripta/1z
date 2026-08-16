const std = @import("std");
const Allocator = std.mem.Allocator;

const Dictionary = @import("dictionary.zig").Dictionary;
const WordDefinition = @import("dictionary.zig").WordDefinition;
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
