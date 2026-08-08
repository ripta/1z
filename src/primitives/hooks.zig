const builtin = @import("builtin");
const std = @import("std");
const is_freestanding = builtin.os.tag == .freestanding;
const context_mod = @import("../context.zig");
const Context = context_mod.Context;
const value_mod = @import("../value.zig");
const container_backing = @import("../container_backing.zig");
const Instruction = value_mod.Instruction;
const Quotation = value_mod.Quotation;
const Value = value_mod.Value;
const helpers = @import("helpers.zig");
const RegistryEntry = @import("types.zig").RegistryEntry;

/// A registered hook: the executable view plus the owning reference the
/// registration transferred in. For a closure the reference keeps the body
/// alive for the registry's lifetime; a plain quotation's owner is inert.
pub const StoredHook = struct {
    quot: Quotation,
    owner: Value,
};

pub const HookRegistry = struct {
    hooks: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(StoredHook)) = .{},

    /// Free the registry's owned storage: each event's hook list with its
    /// owning references, the duped event-name keys, and the map itself.
    /// Plain quotation bodies are borrowed from the dictionary or a
    /// per-context arena and are not freed here.
    pub fn deinit(self: *HookRegistry, allocator: std.mem.Allocator) void {
        var iter = self.hooks.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |hook| container_backing.releaseValue(hook.owner);
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
    // The popped owning reference transfers into the registry entry; every
    // failure path below releases it instead.
    const pc = try helpers.popQuotation(ctx);
    errdefer pc.release();
    const val = ctx.stack.pop() catch return error.StackUnderflow;
    // The event-key bytes are duped for a fresh map entry below.
    defer container_backing.releaseValue(val);
    const sym = switch (val) {
        .symbol => |s| s.bytes,
        .string => |s| s.bytes,
        else => {
            ctx.pending_error_message = "register-global-hook expects a symbol or string as the event key";
            return error.TypeMismatch;
        },
    };

    const registry = ctx.hook_registry;
    const alloc = ctx.allocator;

    const result = registry.hooks.getOrPut(alloc, sym) catch return error.OutOfMemory;
    if (!result.found_existing) {
        // A failed dupe must not leave the entry keyed by the popped value's
        // bytes, which the deferred release may free.
        result.key_ptr.* = alloc.dupe(u8, sym) catch {
            registry.hooks.removeByPtr(result.key_ptr);
            return error.OutOfMemory;
        };
        result.value_ptr.* = .{};
    }
    result.value_ptr.append(alloc, .{ .quot = pc.quot, .owner = pc.owner }) catch return error.OutOfMemory;
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
        const quot = hook_list.items[i].quot;

        for (args) |arg| {
            ctx.stack.push(arg) catch continue;
        }

        ctx.executeQuotation(quot) catch |err| {
            // Freestanding has no real stderr (STDOUT/STDERR_FILENO are undefined there); this
            // diagnostic is a nicety, not load-bearing, so it's silently skipped on that target.
            if (!builtin.is_test and !is_freestanding) {
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
    defer container_backing.releaseValue(param_val);
    const param = switch (param_val) {
        .parameter => |p| p,
        else => {
            ctx.pending_error_message = "register-scoped-hook expects a parameter as second argument";
            return error.TypeMismatch;
        },
    };

    const quot_val = ctx.stack.pop() catch return error.StackUnderflow;
    switch (quot_val) {
        .quotation, .closure => {},
        else => {
            ctx.pending_error_message = "register-scoped-hook expects a quotation as first argument";
            container_backing.releaseValue(quot_val);
            return error.TypeMismatch;
        },
    }

    const alloc = ctx.quotationAllocator();

    var current_owned = false;
    const current = ctx.getParameterBinding(param.name) orelse blk: {
        try ctx.executeQuotation(param.default_quotation);
        current_owned = true;
        break :blk ctx.stack.pop() catch return error.StackUnderflow;
    };
    // A binding hit is a borrow; only the default-quotation result is owned here.
    defer if (current_owned) container_backing.releaseValue(current);

    const old_items = switch (current) {
        .array => |arr| arr.items,
        else => &[_]Value{},
    };

    const new_items = alloc.alloc(Value, old_items.len + 1) catch return error.OutOfMemory;
    @memcpy(new_items[0..old_items.len], old_items);
    // The copied elements become new owning references held by the array;
    // quot_val's reference transfers into the last slot.
    container_backing.retainValues(new_items[0..old_items.len]);
    new_items[old_items.len] = quot_val;

    const arr = try value_mod.Array.fromOwnedSlice(alloc, new_items);
    // The parameter frame slot retains on store; drop the creation reference
    // so the binding is the sole owner.
    defer container_backing.releaseValue(.{ .array = arr });
    try ctx.setParameterInTopFrame(param.name, .{ .array = arr });
}

/// Whether any quotations are currently registered for the given scoped-hook parameter (e.g.
/// "word-defined-hooks"). Lets a caller skip building an argument value (like a WordInfo record)
/// when nothing would consume it.
pub fn hasScopedHooks(ctx: *Context, param_name: []const u8) bool {
    if (ctx.firing_scoped_hooks) return false;
    const hook_array = ctx.getParameterBinding(param_name) orelse return false;
    return switch (hook_array) {
        .array => |arr| arr.items.len > 0,
        else => false,
    };
}

/// Fire all scoped hooks stored in a dynamic parameter.
///
/// Reëntrant calls are suppressed to prevent infinite recursion, e.g., a word-defined hook that
/// itself defines words.
pub fn fireScopedHooks(ctx: *Context, param_name: []const u8, args: []const Value) void {
    if (!hasScopedHooks(ctx, param_name)) return;

    const items = ctx.getParameterBinding(param_name).?.array.items;

    ctx.firing_scoped_hooks = true;
    defer ctx.firing_scoped_hooks = false;

    var i = items.len;
    while (i > 0) {
        i -= 1;
        const quot = (helpers.asQuotationStamped(ctx, items[i]) catch continue) orelse continue;

        for (args) |arg| {
            ctx.stack.push(arg) catch continue;
        }

        ctx.executeQuotation(quot) catch |err| {
            if (!builtin.is_test and !is_freestanding) {
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
    var list = std.ArrayListUnmanaged(StoredHook){};
    try list.append(alloc, .{ .quot = quot1, .owner = .unit });
    try list.append(alloc, .{ .quot = quot2, .owner = .unit });
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
    var list = std.ArrayListUnmanaged(StoredHook){};
    try list.append(alloc, .{ .quot = quot1, .owner = .unit });
    try list.append(alloc, .{ .quot = quot2, .owner = .unit });
    try list.append(alloc, .{ .quot = quot3, .owner = .unit });
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

test "hasScopedHooks reports false with no binding" {
    var ctx = context_mod.Context.init(std.testing.allocator);
    defer ctx.deinit();
    try std.testing.expect(!hasScopedHooks(&ctx, "word-defined-hooks"));
}

test "hasScopedHooks reports false with an empty array binding" {
    var ctx = context_mod.Context.init(std.testing.allocator);
    defer ctx.deinit();
    const alloc = ctx.quotationAllocator();
    const empty_arr = try value_mod.Array.fromOwnedSlice(alloc, &.{});
    try ctx.setParameterInTopFrame("word-defined-hooks", .{ .array = empty_arr });
    try std.testing.expect(!hasScopedHooks(&ctx, "word-defined-hooks"));
}

test "hasScopedHooks reports true with a non-empty array binding" {
    var ctx = context_mod.Context.init(std.testing.allocator);
    defer ctx.deinit();
    const alloc = ctx.quotationAllocator();
    const items = try alloc.alloc(Value, 1);
    items[0] = .{ .quotation = .{ .instructions = &.{} } };
    const arr = try value_mod.Array.fromOwnedSlice(alloc, items);
    try ctx.setParameterInTopFrame("word-defined-hooks", .{ .array = arr });
    try std.testing.expect(hasScopedHooks(&ctx, "word-defined-hooks"));
}
