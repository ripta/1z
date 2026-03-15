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
const makeSimpleEffect = primitives_mod.makeSimpleEffect;

const all_primitives = primitives_mod.extracted_primitives;
const all_registry_entries = primitives_mod.extracted_registry_entries;

pub fn registerPrimitives(dict: *Dictionary, allocator: Allocator) !void {
    for (all_primitives) |p| {
        const effect: ?StackEffect = if (p.stack_effect) |raw|
            try makeSimpleEffect(allocator, raw)
        else
            null;

        try dict.put(p.name, WordDefinition{
            .name = p.name,
            .parse_time = p.parse_time or p.parse_time_only,
            .parse_time_only = p.parse_time_only,
            .effect_transparent = p.effect_transparent,
            .stack_effect = effect,
            .markers = p.markers,
            .doc = p.doc,
            .action = .{ .native = p.func },
        });
    }
}

pub fn registerNativeDispatch(dispatch: *@import("dispatch.zig").DispatchTable) !void {
    try @import("primitives/arithmetic.zig").registerNativeDispatch(dispatch);
    try @import("primitives/bitwise.zig").registerNativeDispatch(dispatch);
    try @import("primitives/sequences.zig").registerNativeDispatch(dispatch);
    try @import("primitives/strings.zig").registerNativeDispatch(dispatch);
}

pub fn createNativeModule(dict: *Dictionary, allocator: Allocator) !void {
    const module = try allocator.create(Module);
    module.* = .{
        .name = "native",
        .words = .{},
        .importable = false,
    };

    for (all_registry_entries) |entry| {
        const effect: ?StackEffect = if (entry.stack_effect) |raw|
            try makeSimpleEffect(allocator, raw)
        else
            null;
        try module.words.put(allocator, entry.name, .{
            .action = .{ .native = entry.func },
            .stack_effect = effect,
            .polymorphic = entry.polymorphic,
        });
    }

    const instrs = try allocator.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .push_literal = .{ .module = module } }, .line = 0 };
    try dict.put("native", .{
        .name = "native",
        .action = .{ .compound = instrs },
    });
}
