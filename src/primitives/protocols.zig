const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const MutableMap = value_mod.MutableMap;
const Instruction = value_mod.Instruction;
const StackEffect = @import("../stack_effect.zig").StackEffect;

const markers_mod = @import("markers.zig");
const dispatch_mod = @import("../dispatch.zig");
const container_backing = @import("../container_backing.zig");

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
    defer container_backing.releaseValue(desc_val);
    const desc_map: *MutableMap = switch (desc_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable-map", desc_val);
            return error.TypeMismatch;
        },
    };

    const methods_val = desc_map.map.get("methods") orelse return error.MissingField;
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

    if (ctx.in_module_load) {
        try ctx.protocol_obligations.append(ctx.allocator, .{
            .type_name = type_name,
            .methods_array = methods_array,
            .protocol_name = protocol_name,
        });
        return;
    }

    try validateProtocolObligation(ctx, type_name, methods_array, protocol_name);
}

/// Validate a single protocol obligation: check that all required methods
/// are registered in the dispatch table. Same-type and bare methods are
/// checked immediately; cross-type (`any`) methods are checked immediately
/// as well (they enumerate dispatch entries).
pub fn validateProtocolObligation(
    ctx: *Context,
    type_name: []const u8,
    methods_array: []const Value,
    protocol_name: []const u8,
) !void {
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

        if (i < methods_array.len and methods_array[i] == .stack_effect) {
            const effect = methods_array[i].stack_effect;
            i += 1;

            try validateTypedMethod(ctx, method_name, effect, type_name, protocol_name);
        } else {
            const type_tv = ctx.lookupTypeValueByName(type_name) orelse {
                helpers.setErrorContext(ctx, "unknown type '{s}' in protocol validation", .{type_name});
                return error.TypeMismatch;
            };
            const has_method = if (ctx.resolveDispatchId(method_name)) |did|
                ctx.lookupUnaryDispatch(did, type_tv.descriptor.?) != null or
                    ctx.lookupBinaryDispatch(did, type_tv.descriptor.?, type_tv.descriptor.?) != null
            else
                false;

            if (!has_method) {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            }
        }
    }
}

/// Validate deferred protocol obligations.
pub fn validateObligationsSameType(ctx: *Context) !void {
    for (ctx.protocol_obligations.items) |obligation| {
        try validateObligationSameTypeOnly(
            ctx,
            obligation.type_name,
            obligation.methods_array,
            obligation.protocol_name,
        );
    }

    ctx.protocol_obligations.clearRetainingCapacity();
}

/// Validate a single obligation, but skip any method that involves a cross-type
/// `ˀany` marker, which are left to runtime checks.
fn validateObligationSameTypeOnly(
    ctx: *Context,
    type_name: []const u8,
    methods_array: []const Value,
    protocol_name: []const u8,
) !void {
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

        if (i < methods_array.len and methods_array[i] == .stack_effect) {
            const effect = methods_array[i].stack_effect;
            i += 1;

            if (isCrossTypeMethod(ctx, effect)) continue;

            try validateTypedMethod(ctx, method_name, effect, type_name, protocol_name);
        } else {
            const type_tv = ctx.lookupTypeValueByName(type_name) orelse {
                helpers.setErrorContext(ctx, "unknown type '{s}' in protocol validation", .{type_name});
                return error.TypeMismatch;
            };
            const has_method = if (ctx.resolveDispatchId(method_name)) |did|
                ctx.lookupUnaryDispatch(did, type_tv.descriptor.?) != null or
                    ctx.lookupBinaryDispatch(did, type_tv.descriptor.?, type_tv.descriptor.?) != null
            else
                false;

            if (!has_method) {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            }
        }
    }
}

/// Returns true if the stack effect has any non-self type annotation,
/// i.e., the `any` sentinel or a concrete type that is not `self`.
fn isCrossTypeMethod(ctx: *Context, effect: StackEffect) bool {
    const n_inputs = @min(effect.inputs.len, 2);
    for (0..n_inputs) |pos| {
        if (effect.inputs[pos].type_annotation) |tv| {
            if (tv == ctx.getAnyTypeSentinel()) return true;
            if (tv != ctx.getSelfTypeSentinel()) return true;
        }
    }
    return false;
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

    // Look up the TypeValue for the implementing type
    const type_tv = ctx.lookupTypeValueByName(type_name) orelse {
        helpers.setErrorContext(ctx, "unknown type '{s}' in protocol validation", .{type_name});
        return error.TypeMismatch;
    };

    // Determine concrete TypeValues for each input position, substituting sentinels
    var has_any = false;
    var any_position: usize = 0;
    var concrete_types: [2]*const value_mod.TypeValue = .{ ctx.getDispatchUnarySentinel(), ctx.getDispatchUnarySentinel() };
    const n_inputs = @min(inputs.len, 2);

    for (0..n_inputs) |pos| {
        if (inputs[pos].type_annotation) |tv| {
            if (tv == ctx.getSelfTypeSentinel()) {
                concrete_types[pos] = type_tv;
            } else if (tv == ctx.getAnyTypeSentinel()) {
                has_any = true;
                any_position = pos;
                concrete_types[pos] = ctx.getDispatchAnySentinel();
            } else {
                concrete_types[pos] = tv;
            }
        } else {
            // Unannotated input -- treat as `self`
            concrete_types[pos] = type_tv;
        }
    }

    if (n_inputs == 0 or n_inputs == 1) {
        // Unary dispatch
        const type_a = if (n_inputs == 1) concrete_types[0] else type_tv;
        if (!has_any) {
            const unary_did = ctx.resolveDispatchId(method_name) orelse {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            };
            if (ctx.lookupUnaryDispatch(unary_did, type_a.descriptor.?) == null) {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            }
        } else {
            // `any` in unary position: check that at least one entry exists
            if (!hasAnyMatchingEntry(ctx, method_name, type_tv, true, 0)) {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            }
        }
    } else {
        // Binary dispatch
        if (!has_any) {
            const binary_did = ctx.resolveDispatchId(method_name) orelse {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            };
            if (ctx.lookupBinaryDispatch(binary_did, concrete_types[0].descriptor.?, concrete_types[1].descriptor.?) == null) {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            }
        } else {
            // `any` in one position: check that at least one dispatch entry exists
            // where the non-any position matches the implementing type
            if (!hasAnyMatchingEntry(ctx, method_name, type_tv, false, any_position)) {
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
    type_tv: *const value_mod.TypeValue,
    is_unary: bool,
    any_position: usize,
) bool {
    const alloc = ctx.arena.allocator();
    const keys = ctx.dispatchKeysForWord(method_name, alloc) catch return false;
    defer alloc.free(keys);

    for (keys) |key| {
        if (is_unary) {
            if (key.type_b == ctx.getDispatchUnarySentinel().descriptor.?) {
                if (key.type_a == type_tv.descriptor.? or
                    key.type_a == ctx.getDispatchAnySentinel().descriptor.?)
                {
                    return true;
                }
            }
        } else {
            if (key.type_b == ctx.getDispatchUnarySentinel().descriptor.?) continue;
            if (any_position == 0) {
                // any is first position, self must be in second
                if (key.type_b == type_tv.descriptor.? or
                    key.type_b == ctx.getDispatchAnySentinel().descriptor.?)
                {
                    return true;
                }
            } else {
                // any is second position, self must be in first
                if (key.type_a == type_tv.descriptor.? or
                    key.type_a == ctx.getDispatchAnySentinel().descriptor.?)
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

    ctx.thrown_error = value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = "protocol-error",
        .message = msg,
    }) catch null;
}
