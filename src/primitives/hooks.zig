const builtin = @import("builtin");
const std = @import("std");
const context_mod = @import("../context.zig");
const Context = context_mod.Context;
const value_mod = @import("../value.zig");
const Instruction = value_mod.Instruction;
const Quotation = value_mod.Quotation;
const Value = value_mod.Value;
const helpers = @import("helpers.zig");
const RegistryEntry = @import("types.zig").RegistryEntry;

pub const HookRegistry = struct {
    hooks: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Quotation)) = .{},

    /// Free the registry's owned storage: each event's quotation list, the
    /// duped event-name keys, and the map itself. Quotation instruction
    /// bodies are borrowed from the dictionary or a per-context arena and are
    /// not freed here.
    pub fn deinit(self: *HookRegistry, allocator: std.mem.Allocator) void {
        var iter = self.hooks.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.hooks.deinit(allocator);
    }
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "register-global-hook", .func = nativeRegisterHook, .stack_effect = "key quot --" },
    .{ .name = "register-scoped-hook", .func = nativeRegisterScopedHook, .stack_effect = "quot param --" },
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
            ctx.pending_error_message = "register-global-hook expects a symbol or string as the event key";
            return error.TypeMismatch;
        },
    };

    const registry = ctx.hook_registry;
    const alloc = ctx.allocator;

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
            if (!builtin.is_test) {
                const stderr_file: std.fs.File = .stderr();
                var buf: [256]u8 = undefined;
                var writer = stderr_file.writer(&buf);
                writer.interface.print("hook error ({s}): {s}\n", .{ event_name, @errorName(err) }) catch {};
                writer.interface.flush() catch {};
            }
            continue;
        };
    }
}

/// ( quot param -- ) Register a scoped hook quotation on a dynamic parameter.
///
/// The parameter should hold an array of quotations, e.g., word-defined-hooks.
fn nativeRegisterScopedHook(ctx: *Context) anyerror!void {
    const param_val = ctx.stack.pop() catch return error.StackUnderflow;
    const param = switch (param_val) {
        .parameter => |p| p,
        else => {
            ctx.pending_error_message = "register-scoped-hook expects a parameter as second argument";
            return error.TypeMismatch;
        },
    };

    const quot_val = ctx.stack.pop() catch return error.StackUnderflow;
    switch (quot_val) {
        .quotation => {},
        else => {
            ctx.pending_error_message = "register-scoped-hook expects a quotation as first argument";
            return error.TypeMismatch;
        },
    }

    const alloc = ctx.quotationAllocator();

    const current = ctx.getParameterBinding(param.name) orelse blk: {
        ctx.executeQuotation(param.default_quotation) catch return error.OutOfMemory;
        break :blk ctx.stack.pop() catch return error.StackUnderflow;
    };

    const old_items = switch (current) {
        .array => |arr| arr,
        else => &[_]Value{},
    };

    const new_items = alloc.alloc(Value, old_items.len + 1) catch return error.OutOfMemory;
    @memcpy(new_items[0..old_items.len], old_items);
    new_items[old_items.len] = quot_val;

    try ctx.setParameterInTopFrame(param.name, .{ .array = new_items });
}

/// Fire all scoped hooks stored in a dynamic parameter.
///
/// Pushes args onto the stack before each hook. Iterates in LIFO (reverse) order.
/// On error, logs to stderr and continues with remaining hooks.
/// Reëntrant calls are suppressed to prevent infinite recursion, e.g., a word-defined hook that itself defines words.
pub fn fireScopedHooks(ctx: *Context, param_name: []const u8, args: []const Value) void {
    if (ctx.firing_scoped_hooks) return;

    const hook_array = ctx.getParameterBinding(param_name) orelse return;
    const items = switch (hook_array) {
        .array => |arr| arr,
        else => return,
    };
    if (items.len == 0) return;

    ctx.firing_scoped_hooks = true;
    defer ctx.firing_scoped_hooks = false;

    var i = items.len;
    while (i > 0) {
        i -= 1;
        const quot = switch (items[i]) {
            .quotation => |q| q,
            else => continue,
        };

        for (args) |arg| {
            ctx.stack.push(arg) catch continue;
        }

        ctx.executeQuotation(quot) catch |err| {
            if (!builtin.is_test) {
                const stderr_file: std.fs.File = .stderr();
                var buf: [256]u8 = undefined;
                var writer = stderr_file.writer(&buf);
                writer.interface.print("scoped hook error ({s}): {s}\n", .{ param_name, @errorName(err) }) catch {};
                writer.interface.flush() catch {};
            }
            continue;
        };
    }
}

fn makeInstr(op: Instruction.Op) Instruction {
    return .{ .op = op, .line = 0 };
}

test "LIFO ordering" {
    var ctx = context_mod.Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.loadPrelude(null) catch unreachable;

    const alloc = ctx.allocator;
    const ialloc = ctx.quotationAllocator();
    const registry = ctx.hook_registry;

    const instrs1 = try ialloc.alloc(Instruction, 1);
    instrs1[0] = makeInstr(.{ .push_literal = .{ .fixnum = 1 } });
    const quot1 = Quotation{ .instructions = instrs1 };

    const instrs2 = try ialloc.alloc(Instruction, 1);
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
    var ctx = context_mod.Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.loadPrelude(null) catch unreachable;

    const alloc = ctx.allocator;
    const ialloc = ctx.quotationAllocator();
    const registry = ctx.hook_registry;

    const instrs1 = try ialloc.alloc(Instruction, 1);
    instrs1[0] = makeInstr(.{ .push_literal = .{ .fixnum = 42 } });
    const quot1 = Quotation{ .instructions = instrs1 };

    // Second hook: reference an undefined word (will error without consuming stack)
    const instrs2 = try ialloc.alloc(Instruction, 1);
    instrs2[0] = makeInstr(.{ .call_word = "nonexistent-word-for-hook-test" });
    const quot2 = Quotation{ .instructions = instrs2 };

    const instrs3 = try ialloc.alloc(Instruction, 1);
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
    var ctx = context_mod.Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.loadPrelude(null) catch unreachable;

    fireHooks(&ctx, "nonexistent-event", &.{});
    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
}
