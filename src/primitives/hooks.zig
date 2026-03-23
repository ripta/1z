const std = @import("std");
const Context = @import("../context.zig").Context;
const Value = @import("../value.zig").Value;
const Quotation = @import("../value.zig").Quotation;
const helpers = @import("helpers.zig");
const RegistryEntry = @import("types.zig").RegistryEntry;

pub const HookRegistry = struct {
    hooks: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Quotation)) = .{},
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "register-hook", .func = nativeRegisterHook, .stack_effect = "key quot --" },
};

/// ( key quot -- ) Register a hook quotation for a lifecycle event.
/// The key can be a symbol or a string.
fn nativeRegisterHook(ctx: *Context) anyerror!void {
    const quot = try helpers.popQuotation(ctx);
    const val = ctx.stack.pop() catch return error.StackUnderflow;
    const sym = switch (val) {
        .symbol => |s| s,
        .string => |s| s,
        else => {
            ctx.pending_error_message = "register-hook expects a symbol or string as the event key";
            return error.TypeMismatch;
        },
    };

    const registry = ctx.hook_registry;
    const alloc = ctx.containerAllocator();

    const result = registry.hooks.getOrPut(alloc, sym) catch return error.OutOfMemory;
    if (!result.found_existing) {
        result.key_ptr.* = alloc.dupe(u8, sym) catch return error.OutOfMemory;
        result.value_ptr.* = .{};
    }
    result.value_ptr.append(alloc, quot) catch return error.OutOfMemory;
}

/// Fire all hooks registered for the given event name.
/// Pushes args onto the stack before each hook. Iterates in reverse (LIFO).
/// On error, logs to stderr and continues with remaining hooks.
pub fn fireHooks(ctx: *Context, event_name: []const u8, args: []const Value) void {
    const registry = ctx.hook_registry;
    const hook_list = registry.hooks.get(event_name) orelse return;
    if (hook_list.items.len == 0) return;

    var i = hook_list.items.len;
    while (i > 0) {
        i -= 1;
        const quot = hook_list.items[i];

        for (args) |arg| {
            ctx.stack.push(arg) catch continue;
        }

        ctx.executeQuotation(quot) catch |err| {
            const stderr_file: std.fs.File = .stderr();
            var buf: [256]u8 = undefined;
            var writer = stderr_file.writer(&buf);
            writer.interface.print("hook error ({s}): {s}\n", .{ event_name, @errorName(err) }) catch {};
            writer.interface.flush() catch {};
            continue;
        };
    }
}

const Instruction = @import("../value.zig").Instruction;

fn makeInstr(op: Instruction.Op) Instruction {
    return .{ .op = op, .line = 0 };
}

test "LIFO ordering" {
    const context_mod = @import("../context.zig");
    var ctx = context_mod.Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.loadPrelude(null) catch unreachable;

    const alloc = ctx.containerAllocator();
    const registry = ctx.hook_registry;

    const instrs1 = try alloc.alloc(Instruction, 1);
    instrs1[0] = makeInstr(.{ .push_literal = .{ .fixnum = 1 } });
    const quot1 = Quotation{ .instructions = instrs1 };

    const instrs2 = try alloc.alloc(Instruction, 1);
    instrs2[0] = makeInstr(.{ .push_literal = .{ .fixnum = 2 } });
    const quot2 = Quotation{ .instructions = instrs2 };

    const key = try alloc.dupe(u8, "test-event");
    var list = std.ArrayListUnmanaged(Quotation){};
    try list.append(alloc, quot1);
    try list.append(alloc, quot2);
    try registry.hooks.put(alloc, key, list);

    // LIFO: hook2 fires first, then hook1
    fireHooks(&ctx, "test-event", &.{});

    const top = try ctx.stack.pop();
    try std.testing.expectEqual(@as(i64, 1), top.fixnum);
    const second = try ctx.stack.pop();
    try std.testing.expectEqual(@as(i64, 2), second.fixnum);
}

test "error resilience" {
    const context_mod = @import("../context.zig");
    var ctx = context_mod.Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.loadPrelude(null) catch unreachable;

    const alloc = ctx.containerAllocator();
    const registry = ctx.hook_registry;

    const instrs1 = try alloc.alloc(Instruction, 1);
    instrs1[0] = makeInstr(.{ .push_literal = .{ .fixnum = 42 } });
    const quot1 = Quotation{ .instructions = instrs1 };

    // Second hook: reference an undefined word (will error without consuming stack)
    const instrs2 = try alloc.alloc(Instruction, 1);
    instrs2[0] = makeInstr(.{ .call_word = "nonexistent-word-for-hook-test" });
    const quot2 = Quotation{ .instructions = instrs2 };

    const instrs3 = try alloc.alloc(Instruction, 1);
    instrs3[0] = makeInstr(.{ .push_literal = .{ .fixnum = 99 } });
    const quot3 = Quotation{ .instructions = instrs3 };

    // Register: quot1, quot2 (throws), quot3
    // LIFO firing: quot3 -> quot2 (error) -> quot1
    const key = try alloc.dupe(u8, "test-err");
    var list = std.ArrayListUnmanaged(Quotation){};
    try list.append(alloc, quot1);
    try list.append(alloc, quot2);
    try list.append(alloc, quot3);
    try registry.hooks.put(alloc, key, list);

    fireHooks(&ctx, "test-err", &.{});

    // quot3 pushed 99, quot2 errored (UnknownWord), quot1 pushed 42
    const top = try ctx.stack.pop();
    try std.testing.expectEqual(@as(i64, 42), top.fixnum);
    const second = try ctx.stack.pop();
    try std.testing.expectEqual(@as(i64, 99), second.fixnum);
}

test "empty registry" {
    const context_mod = @import("../context.zig");
    var ctx = context_mod.Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.loadPrelude(null) catch unreachable;

    fireHooks(&ctx, "nonexistent-event", &.{});
    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
}
