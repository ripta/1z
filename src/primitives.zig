const std = @import("std");
const Allocator = std.mem.Allocator;

const Dictionary = @import("dictionary.zig").Dictionary;
const WordDefinition = @import("dictionary.zig").WordDefinition;
const StackEffect = @import("stack_effect.zig").StackEffect;

const primitives_mod = @import("primitives/mod.zig");
pub const InterpreterError = primitives_mod.InterpreterError;
const Primitive = primitives_mod.Primitive;
const makeSimpleEffect = primitives_mod.makeSimpleEffect;

const all_primitives = primitives_mod.extracted_primitives;

pub fn registerPrimitives(dict: *Dictionary, allocator: Allocator) !void {
    for (all_primitives) |p| {
        const effect: ?StackEffect = if (p.stack_effect) |raw|
            try makeSimpleEffect(allocator, raw)
        else
            null;

        try dict.put(p.name, WordDefinition{
            .name = p.name,
            .parse_time = p.parse_time,
            .stack_effect = effect,
            .action = .{ .native = p.func },
        });
    }
}
