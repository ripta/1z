const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const MutableMap = value_mod.MutableMap;
const Instruction = value_mod.Instruction;

const helpers = @import("helpers.zig");

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;

pub const primitives = [_]Primitive{
    .{ .name = "define-protocol", .stack_effect = "name: descriptor markers --", .doc = "Define a protocol word that validates a type implements all required methods.", .func = nativeDefineProtocol },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "protocol-check", .func = protocolCheckHelper },
};

/// define-protocol ( name: descriptor markers -- )
///
/// Called by `;` when it recognizes a protocol descriptor. Creates a word that,
/// when called with a type symbol on the stack, checks the dispatch table for
/// each required method. Throws protocol-error if any method is missing.
///
/// The descriptor is a mutable-map with:
/// - methods: array of method name strings
fn nativeDefineProtocol(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const markers_val = try ctx.stack.pop();
    _ = switch (markers_val) {
        .array => |arr| arr,
        else => return error.TypeMismatch,
    };

    const desc_val = try ctx.stack.pop();
    const desc_map: *MutableMap = switch (desc_val) {
        .mutable_map => |m| m,
        else => return error.TypeMismatch,
    };

    const methods_val = desc_map.get("methods") orelse return error.MissingField;
    const methods_array = switch (methods_val) {
        .array => |arr| arr,
        else => return error.TypeMismatch,
    };

    if (methods_array.len == 0) {
        helpers.setErrorContext(ctx, "protocol requires at least one method", .{});
        return error.InvalidArgument;
    }

    const name_val = try ctx.stack.pop();
    const protocol_name = switch (name_val) {
        .symbol => |s| s,
        else => return error.TypeMismatch,
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
/// The trampoline pops the function pointer, while the remaining stack is ours.
///
/// This is used for side-effect of validating the protocol at runtime: when everything
/// is valid, it returns void and the protocol word does nothing. If validation fails,
/// it throws an error with context about which method is missing and which type failed
/// to implement the protocol.
fn protocolCheckHelper(ctx: *Context) anyerror!void {
    const protocol_name = switch (try ctx.stack.pop()) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };
    const methods_array = switch (try ctx.stack.pop()) {
        .array => |arr| arr,
        else => return error.TypeMismatch,
    };
    const type_name = switch (try ctx.stack.pop()) {
        .symbol => |s| s,
        else => {
            helpers.setErrorContext(ctx, "protocol validation expects a type name (symbol) on the stack", .{});
            return error.TypeMismatch;
        },
    };

    for (methods_array) |method_val| {
        const method_name = switch (method_val) {
            .string => |s| s,
            else => return error.TypeMismatch,
        };

        if (ctx.dispatch.lookupUnary(method_name, type_name) == null) {
            const msg = std.fmt.allocPrint(
                ctx.arena.allocator(),
                "type '{s}' does not implement '{s}' required by protocol '{s}'",
                .{ type_name, method_name, protocol_name },
            ) catch "protocol validation failed";

            ctx.thrown_error = .{
                .error_type = "protocol-error",
                .message = msg,
            };
            return error.UserThrown;
        }
    }
}
