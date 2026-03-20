const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const MutableMap = value_mod.MutableMap;
const Instruction = value_mod.Instruction;
const StackEffect = @import("../stack_effect.zig").StackEffect;

const markers_mod = @import("markers.zig");
const dispatch_mod = @import("../dispatch.zig");

const helpers = @import("helpers.zig");

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;

pub const primitives = [_]Primitive{
    .{ .name = "define-protocol", .stack_effect = "name: descriptor markers --", .doc = "Define a protocol word that validates a type implements all required methods.", .func = nativeDefineProtocol },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "protocol-check", .func = protocolCheckHelper, .stack_effect = "type-name methods protocol-name --" },
};

/// define-protocol ( name: descriptor markers -- )
///
/// Called by `;` when it recognizes a protocol descriptor. Creates a word that,
/// when called with a type symbol on the stack, checks the dispatch table for
/// each required method. Throws protocol-error if any method is missing.
///
/// The descriptor is a mutable-map with:
///
/// - `methods:` flat array of symbols interleaved with optional stack-effects
fn nativeDefineProtocol(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const markers_val = try ctx.stack.pop();
    _ = switch (markers_val) {
        .array => |arr| arr,
        else => {
            helpers.setTypeMismatchError(ctx, "array", markers_val);
            return error.TypeMismatch;
        },
    };

    const desc_val = try ctx.stack.pop();
    const desc_map: *MutableMap = switch (desc_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable-map", desc_val);
            return error.TypeMismatch;
        },
    };

    const methods_val = desc_map.get("methods") orelse return error.MissingField;
    const methods_array = switch (methods_val) {
        .array => |arr| arr,
        else => {
            helpers.setErrorContext(ctx, "protocol descriptor 'methods' field must be an array", .{});
            return error.TypeMismatch;
        },
    };

    if (methods_array.len == 0) {
        helpers.setErrorContext(ctx, "protocol requires at least one method", .{});
        return error.InvalidArgument;
    }

    const name_val = try ctx.stack.pop();
    const protocol_name = switch (name_val) {
        .symbol => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol", name_val);
            return error.TypeMismatch;
        },
    };

    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .op = .{ .push_literal = .{ .array = methods_array } }, .line = 0 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .string = protocol_name } }, .line = 0 };
    instrs[2] = .{ .op = .{ .call_word = "native.protocol-check" }, .line = 0 };

    try ctx.defineWord(protocol_name, .{
        .name = protocol_name,
        .action = .{ .compound = instrs },
    });
}

/// Trampoline helper ( type-name methods protocol-name -- )
///
/// The methods array is a flat sequence of symbols interleaved with optional stack-effects.
///
/// For each symbol:
///
/// - If followed by a `stack-effect:` typed method validation using the effect's input type annotations.
/// - The `self` sentinel is substituted with the implementing type.
/// - The `any` sentinel triggers enumeration of dispatch entries.
/// - Otherwise, bare `method` (backward compat) checking unary or same-type binary dispatch.
fn protocolCheckHelper(ctx: *Context) anyerror!void {
    const pname_val = try ctx.stack.pop();
    const protocol_name = switch (pname_val) {
        .string => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "string", pname_val);
            return error.TypeMismatch;
        },
    };
    const methods_val = try ctx.stack.pop();
    const methods_array = switch (methods_val) {
        .array => |arr| arr,
        else => {
            helpers.setTypeMismatchError(ctx, "array", methods_val);
            return error.TypeMismatch;
        },
    };
    const type_name = switch (try ctx.stack.pop()) {
        .symbol => |s| s,
        else => {
            helpers.setErrorContext(ctx, "protocol validation expects a type name (symbol) on the stack", .{});
            return error.TypeMismatch;
        },
    };

    var i: usize = 0;
    while (i < methods_array.len) {
        const method_val = methods_array[i];
        const method_name = switch (method_val) {
            .symbol => |s| s,
            else => {
                helpers.setErrorContext(ctx, "protocol method entries must be symbols", .{});
                return error.TypeMismatch;
            },
        };
        i += 1;

        // Check if next element is a stack-effect typed method
        if (i < methods_array.len and methods_array[i] == .stack_effect) {
            const effect = methods_array[i].stack_effect;
            i += 1;

            try validateTypedMethod(ctx, method_name, effect, type_name, protocol_name);
        } else {
            // Bare method fallback: check unary or same-type binary
            const has_method = ctx.dispatch.lookupUnary(method_name, type_name) != null or
                ctx.dispatch.lookupBinary(method_name, type_name, type_name) != null;

            if (!has_method) {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            }
        }
    }
}

/// Validate a typed method by examining the stack effect's input type annotations.
/// Substitutes `self` sentinels with the implementing type name and handles `any`
/// sentinels by enumerating dispatch entries.
fn validateTypedMethod(
    ctx: *Context,
    method_name: []const u8,
    effect: StackEffect,
    type_name: []const u8,
    protocol_name: []const u8,
) !void {
    const inputs = effect.inputs;

    // Determine concrete type names for each input position, substituting sentinels
    var has_any = false;
    var any_position: usize = 0;
    var concrete_types: [2][]const u8 = .{ "", "" };
    const n_inputs = @min(inputs.len, 2);

    for (0..n_inputs) |pos| {
        if (inputs[pos].type_annotation) |tv| {
            if (tv == &markers_mod.self_type_sentinel) {
                concrete_types[pos] = type_name;
            } else if (tv == &markers_mod.any_type_sentinel) {
                has_any = true;
                any_position = pos;
                concrete_types[pos] = dispatch_mod.any_sentinel;
            } else {
                concrete_types[pos] = tv.name;
            }
        } else {
            // Unannotated input -- treat as `self`
            concrete_types[pos] = type_name;
        }
    }

    if (n_inputs == 0 or n_inputs == 1) {
        // Unary dispatch
        const type_a = if (n_inputs == 1) concrete_types[0] else type_name;
        if (!has_any) {
            if (ctx.dispatch.lookupUnary(method_name, type_a) == null) {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            }
        } else {
            // `any` in unary position: check that at least one entry exists
            if (!hasAnyMatchingEntry(ctx, method_name, type_name, true, 0)) {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            }
        }
    } else {
        // Binary dispatch
        if (!has_any) {
            if (ctx.dispatch.lookupBinary(method_name, concrete_types[0], concrete_types[1]) == null) {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            }
        } else {
            // `any` in one position: check that at least one dispatch entry exists
            // where the non-any position matches the implementing type
            if (!hasAnyMatchingEntry(ctx, method_name, type_name, false, any_position)) {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            }
        }
    }
}

/// Check if at least one dispatch entry exists for the given method where the
/// implementing type appears in the non-any position.
fn hasAnyMatchingEntry(
    ctx: *Context,
    method_name: []const u8,
    type_name: []const u8,
    is_unary: bool,
    any_position: usize,
) bool {
    const alloc = ctx.arena.allocator();
    const keys = ctx.dispatch.keysForWord(method_name, alloc) catch return false;
    defer alloc.free(keys);

    for (keys) |key| {
        if (is_unary) {
            if (std.mem.eql(u8, key.type_b, dispatch_mod.unary_sentinel)) {
                if (std.mem.eql(u8, key.type_a, type_name) or
                    std.mem.eql(u8, key.type_a, dispatch_mod.any_sentinel))
                {
                    return true;
                }
            }
        } else {
            if (std.mem.eql(u8, key.type_b, dispatch_mod.unary_sentinel)) continue;
            if (any_position == 0) {
                // any is first position, self must be in second
                if (std.mem.eql(u8, key.type_b, type_name) or
                    std.mem.eql(u8, key.type_b, dispatch_mod.any_sentinel))
                {
                    return true;
                }
            } else {
                // any is second position, self must be in first
                if (std.mem.eql(u8, key.type_a, type_name) or
                    std.mem.eql(u8, key.type_a, dispatch_mod.any_sentinel))
                {
                    return true;
                }
            }
        }
    }
    return false;
}

fn throwProtocolError(ctx: *Context, type_name: []const u8, method_name: []const u8, protocol_name: []const u8) void {
    const msg = std.fmt.allocPrint(
        ctx.arena.allocator(),
        "type '{s}' does not implement '{s}' required by protocol '{s}'",
        .{ type_name, method_name, protocol_name },
    ) catch "protocol validation failed";

    ctx.thrown_error = .{
        .error_type = "protocol-error",
        .message = msg,
    };
}
