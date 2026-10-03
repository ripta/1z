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
const Callable = @import("../callable.zig").Callable;
const helpers = @import("helpers.zig");
const RegistryEntry = @import("types.zig").RegistryEntry;

pub const HookRegistry = struct {
    /// Each registered hook owns the reference its registration transferred in, which for a
    /// closure keeps the body alive for the registry's lifetime.
    hooks: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Callable)) = .{},

    /// Free the registry's owned storage: each event's hook list with its
    /// owning references, the duped event-name keys, and the map itself.
    /// Plain quotation bodies are borrowed from the dictionary or a
    /// per-context arena and are not freed here.
    pub fn deinit(self: *HookRegistry, allocator: std.mem.Allocator) void {
        var iter = self.hooks.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |hook| hook.release();
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
    result.value_ptr.append(alloc, pc) catch return error.OutOfMemory;
}

/// Fire all hooks registered for the given event name.
/// Pushes args onto the stack before each hook. Iterates in reverse (LIFO).
/// Restores the in-flight error state after every hook, failed or not.
/// On error, logs to stderr and continues with remaining hooks.
pub fn fireHooks(ctx: *Context, event_name: []const u8, args: []const Value) void {
    const registry = ctx.hook_registry;
    const hook_list = registry.hooks.get(event_name) orelse return;
    if (hook_list.items.len == 0) return;

    var i = hook_list.items.len;
    while (i > 0) {
        i -= 1;
        runHook(ctx, hook_list.items[i], args) catch |err| reportHookError("hook error", event_name, err);
    }
}

/// Run one hook over `args`, leaving the stack as it was before they were pushed.
///
/// The code around a fire never chose to run the hook. A hook that raises, or that returns with the
/// stack changed, has failed, and the stack it was handed is put back.
fn runHook(ctx: *Context, hook: Callable, args: []const Value) anyerror!void {
    const entry = try ctx.catch_snapshots.push(ctx.allocator, &ctx.stack);

    // The hook's error is reported and dropped, so it must not extend or replace the chain of
    // whatever is propagating around this fire, nor hand its state to the next hook.
    const saved_error_state = ctx.saveErrorState();
    defer ctx.restoreErrorState(saved_error_state);

    const result = runHookOver(ctx, hook, args);
    if (result) |_| {
        if (ctx.catch_snapshots.unchanged(entry, &ctx.stack)) {
            ctx.catch_snapshots.discard(entry);
            return;
        }
        ctx.catch_snapshots.restore(entry, &ctx.stack);
        return error.StackEffectMismatch;
    } else |err| {
        ctx.catch_snapshots.restore(entry, &ctx.stack);
        return err;
    }
}

fn runHookOver(ctx: *Context, hook: Callable, args: []const Value) anyerror!void {
    for (args) |arg| try ctx.stack.push(arg);
    try hook.execute(ctx);
}

fn reportHookError(comptime kind: []const u8, label: []const u8, err: anyerror) void {
    // Freestanding has no real stderr (STDOUT/STDERR_FILENO are undefined there); this
    // diagnostic is a nicety, not load-bearing, so it's silently skipped on that target.
    if (builtin.is_test or is_freestanding) return;

    const stderr_file: std.fs.File = .stderr();
    var buf: [256]u8 = undefined;
    var writer = stderr_file.writerStreaming(&buf);
    writer.interface.print(kind ++ " ({s}): {s}\n", .{ label, @errorName(err) }) catch {};
    writer.interface.flush() catch {};
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
        try ctx.executeQuotationWithOwner(param.default_quotation, param.default_owner);
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

    // The binding is only borrowed, and a hook may register another one, which rebinds the
    // parameter and releases what this loop is walking. Holding the array for the sweep keeps both
    // the slice and every closure body in it alive; reëntrancy suppression covers firing, not
    // registration.
    const bound = ctx.getParameterBinding(param_name).?;
    container_backing.retainValue(bound);
    defer container_backing.releaseValue(bound);
    const items = bound.array.items;

    ctx.firing_scoped_hooks = true;
    defer ctx.firing_scoped_hooks = false;

    var i = items.len;
    while (i > 0) {
        i -= 1;
        const hook = items[i];
        const quot = (helpers.asQuotationStamped(ctx, hook) catch continue) orelse continue;

        // Borrowed: the retained array above owns every element for the sweep.
        const callable: Callable = .{ .quot = quot, .owner = hook };
        runHook(ctx, callable, args) catch |err| reportHookError("scoped hook error", param_name, err);
    }
}

fn makeInstr(op: Instruction.Op) Instruction {
    return .{ .op = op, .line = 0 };
}

/// A stack-neutral hook body that appends `n` to `log`.
fn recordingHook(ialloc: std.mem.Allocator, log: *value_mod.Vector, n: i64) !Quotation {
    const instrs = try ialloc.alloc(Instruction, 4);
    instrs[0] = makeInstr(.{ .push_literal = .{ .vector = log } });
    instrs[1] = makeInstr(.{ .push_literal = .{ .fixnum = n } });
    instrs[2] = makeInstr(.{ .call_word = "#push!" });
    instrs[3] = makeInstr(.{ .call_word = "drop" });
    return .{ .instructions = instrs };
}

test "LIFO ordering" {
    var ctx = context_mod.Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.loadPrelude(null) catch unreachable;

    const alloc = ctx.allocator;
    const ialloc = ctx.quotationAllocator();
    const registry = ctx.hook_registry;

    const log = try value_mod.Vector.create(alloc);
    defer log.header.release();

    const key = try alloc.dupe(u8, "test-event");
    var list = std.ArrayListUnmanaged(Callable){};
    try list.append(alloc, .{ .quot = try recordingHook(ialloc, log, 1), .owner = .unit });
    try list.append(alloc, .{ .quot = try recordingHook(ialloc, log, 2), .owner = .unit });
    try registry.hooks.put(alloc, key, list);

    // LIFO: hook2 fires first, then hook1
    fireHooks(&ctx, "test-event", &.{});

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
    try std.testing.expectEqual(@as(usize, 2), log.list.items.len);
    try std.testing.expectEqual(@as(i64, 2), log.list.items[0].fixnum);
    try std.testing.expectEqual(@as(i64, 1), log.list.items[1].fixnum);
}

test "error resilience" {
    var ctx = context_mod.Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.loadPrelude(null) catch unreachable;

    const alloc = ctx.allocator;
    const ialloc = ctx.quotationAllocator();
    const registry = ctx.hook_registry;

    const log = try value_mod.Vector.create(alloc);
    defer log.header.release();

    // The middle hook references an undefined word.
    const failing = try ialloc.alloc(Instruction, 1);
    failing[0] = makeInstr(.{ .call_word = "nonexistent-word-for-hook-test" });

    // LIFO firing: 99, then the failing hook, then 42
    const key = try alloc.dupe(u8, "test-err");
    var list = std.ArrayListUnmanaged(Callable){};
    try list.append(alloc, .{ .quot = try recordingHook(ialloc, log, 42), .owner = .unit });
    try list.append(alloc, .{ .quot = .{ .instructions = failing }, .owner = .unit });
    try list.append(alloc, .{ .quot = try recordingHook(ialloc, log, 99), .owner = .unit });
    try registry.hooks.put(alloc, key, list);

    fireHooks(&ctx, "test-err", &.{});

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
    try std.testing.expectEqual(@as(usize, 2), log.list.items.len);
    try std.testing.expectEqual(@as(i64, 99), log.list.items[0].fixnum);
    try std.testing.expectEqual(@as(i64, 42), log.list.items[1].fixnum);
}

test "a hook that changes the stack has the stack it was handed put back" {
    var ctx = context_mod.Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.loadPrelude(null) catch unreachable;

    const alloc = ctx.allocator;
    const ialloc = ctx.quotationAllocator();
    const registry = ctx.hook_registry;

    // drop drop 888: consumes its argument and a value below it, then pushes one back.
    const instrs = try ialloc.alloc(Instruction, 3);
    instrs[0] = makeInstr(.{ .call_word = "drop" });
    instrs[1] = makeInstr(.{ .call_word = "drop" });
    instrs[2] = makeInstr(.{ .push_literal = .{ .fixnum = 888 } });

    const key = try alloc.dupe(u8, "test-changed");
    var list = std.ArrayListUnmanaged(Callable){};
    try list.append(alloc, .{ .quot = .{ .instructions = instrs }, .owner = .unit });
    try registry.hooks.put(alloc, key, list);

    try ctx.stack.push(.{ .fixnum = 1 });
    fireHooks(&ctx, "test-changed", &.{.{ .fixnum = 7 }});

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).fixnum);
}

test "a failing hook gives back the error state it overwrote" {
    var ctx = context_mod.Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.loadPrelude(null) catch unreachable;

    const alloc = ctx.allocator;
    const ialloc = ctx.quotationAllocator();
    const registry = ctx.hook_registry;

    const instrs = try ialloc.alloc(Instruction, 1);
    instrs[0] = makeInstr(.{ .call_word = "nonexistent-word-for-hook-shield-test" });

    const key = try alloc.dupe(u8, "test-shield");
    var list = std.ArrayListUnmanaged(Callable){};
    try list.append(alloc, .{ .quot = .{ .instructions = instrs }, .owner = .unit });
    try registry.hooks.put(alloc, key, list);

    ctx.pending_error_message = "body failed";
    ctx.appendPendingSyntheticErrorFrame("boom", "<test>", 4, null);

    fireHooks(&ctx, "test-shield", &.{});

    try std.testing.expectEqualStrings("body failed", ctx.pending_error_message.?);
    try std.testing.expectEqual(@as(usize, 1), ctx.jit_pending_trace_frames.items.len);
    try std.testing.expectEqualStrings("boom", ctx.jit_pending_trace_frames.items[0].word_name);
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
