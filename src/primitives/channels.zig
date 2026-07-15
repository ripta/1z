const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;
const LockLevel = @import("../lock_order.zig").LockLevel;
const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const task_mod = @import("../task.zig");
const Task = task_mod.Task;
const channel_mod = @import("../channel.zig");
const Channel = channel_mod.Channel;
const Scheduler = @import("../scheduler.zig").Scheduler;
const tasks = @import("tasks.zig");
const container_backing = @import("../container_backing.zig");

fn acquireChannel(ctx: *Context, ch: *Channel) void {
    ctx.lock_order_tracker.acquire(.channel);
    ch.mutex.lock();
}

fn releaseChannel(ctx: *Context, ch: *Channel) void {
    ch.mutex.unlock();
    ctx.lock_order_tracker.release(.channel);
}

fn throwChannelClosed(ctx: *Context, message: []const u8) anyerror {
    ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = "channel-closed",
        .message = message,
    });
    return error.UserThrown;
}

fn throwBorrowedBufferEscape(ctx: *Context, message: []const u8) anyerror {
    ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = "borrowed-buffer-escape",
        .message = message,
    });
    return error.UserThrown;
}

fn ensureSendValueEscapable(ctx: *Context, value: Value) anyerror!void {
    if (value_mod.valueContainsBorrowedBuffer(value)) {
        return throwBorrowedBufferEscape(ctx, "borrowed buffer cannot cross task boundary via channel send; call >byte-array first");
    }
}

/// Take channel-buffer ownership of a sender's value. The sender can be reaped, and its arena
/// freed, before a buffered value is received, so the buffer must never hold a value whose bytes
/// live on the sender's arena.
///
/// Reference types cross unchanged and shareable values are retained, mirroring the
/// `deepCopyValue` fast paths. Anything else is deep-copied into a per-entry arena that lives on
/// the channel's allocator until the entry is destroyed.
fn adoptForBuffer(ctx: *Context, ch: *Channel, value: Value) Allocator.Error!channel_mod.BufferedValue {
    switch (value) {
        .stream, .parameter, .module, .marker, .struct_type, .benchmark_report, .task, .channel, .iterator, .resource, .type_val, .type_descriptor, .protocol_descriptor, .constraint_combinator, .sandbox_spec => {
            container_backing.retainValue(value);
            return .{ .value = value };
        },
        else => {},
    }

    if (container_backing.valueShareable(value, ctx.allocator)) {
        container_backing.retainValue(value);
        return .{ .value = value };
    }

    const arena = try ch.allocator.create(std.heap.ArenaAllocator);
    errdefer ch.allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(ch.allocator);
    errdefer arena.deinit();

    const copied = try tasks.deepCopyValue(value, arena.allocator(), ctx.allocator);
    return .{ .value = copied, .arena = arena };
}

pub const primitives = [_]Primitive{
    .{ .name = "<channel>", .stack_effect = "-- ch", .doc = "Create an unbufferedf channel.", .func = nativeCreateChannel },
    .{ .name = "send", .stack_effect = "val ch --", .doc = "Send a value to a channel. Blocks if no receiver ready (unbuffered) or buffer full. The value crosses the task boundary as an independent deep copy, or as a shared reference when it is provably immutable; when sender and receiver are on different workers the receiver wakes via its home worker's external queue.", .func = nativeSend },
    .{
        .name = "receive",
        .stack_effect = "ch -- val",
        .doc = "Receive a value from a channel. Blocks if no value available. Throws ChannelClosed if closed and empty. The value crosses the task boundary as an independent deep copy, or as a shared reference when it is provably immutable; when sender and receiver are on different workers the receiver wakes via its home worker's external queue.",
        .func = nativeReceive,
    },
    .{ .name = "try-receive", .stack_effect = "ch -- val/f ?", .doc = "Non-blocking receive. Returns value and t if data is available, or f and f if not. Any waiting sender on another worker is woken via the cross-worker wake queue.", .func = nativeTryReceive },
    .{ .name = "<buffered-channel>", .stack_effect = "n -- ch", .doc = "Create a buffered channel with capacity n.", .func = nativeCreateBufferedChannel },
    .{ .name = "close-channel", .stack_effect = "ch --", .doc = "Close a channel. No more sends allowed; receives drain buffered values. Blocked senders and receivers on other workers are woken via the cross-worker wake queue.", .func = nativeCloseChannel },
    .{ .name = "select", .stack_effect = "array -- val ch", .doc = "Wait on multiple channels. Returns the first available value and which channel it came from. Channels may have counterparties on any worker; delivery wakes the selecting task via its home worker's external queue.", .func = nativeSelect },
};

/// <channel> ( -- ch )
fn nativeCreateChannel(ctx: *Context) anyerror!void {
    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "<channel> must be called within a task-scope";
        return error.InvalidState;
    };

    const ch = try Channel.init(ctx.allocator, 0);
    try scheduler.trackChannel(ch);
    try ctx.stack.push(.{ .channel = ch });
}

/// <buffered-channel> ( n -- ch )
fn nativeCreateBufferedChannel(ctx: *Context) anyerror!void {
    const n = try helpers.popFixnum(ctx);

    if (n <= 0) {
        ctx.pending_error_message = "buffered channel capacity must be positive";
        return error.InvalidArgument;
    }

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "<buffered-channel> must be called within a task-scope";
        return error.InvalidState;
    };

    const ch = try Channel.init(ctx.allocator, @intCast(n));
    try scheduler.trackChannel(ch);
    try ctx.stack.push(.{ .channel = ch });
}

/// send ( val ch -- )
///
/// If the channel is unbuffered, blocks until a receiver is waiting, then hands off the value directly to that receiver.
/// If the channel is buffered and has space, pushes the value onto the buffer and returns immediately.
/// If the channel is buffered and full, blocks until a receiver takes something from the buffer, then pushes the value onto the buffer and returns.
///
/// In all cases, if the channel is closed, throws ChannelClosed. If the current task is cancelled while blocked, throws a "task-cancelled" error.
///
/// Values that cross the task boundary are deep-copied, or shared by refcount bump when provably
/// immutable and self-contained: either way the receiver observes a value independent of the
/// sender's. When sender and receiver are pinned to different workers, the receiver wakes via its
/// home worker's external queue.
fn nativeSend(ctx: *Context) anyerror!void {
    if (ctx.in_module_load) {
        ctx.pending_error_message = "send cannot be called during module loading";
        return error.InvalidState;
    }

    const ch = try helpers.popChannel(ctx);
    const value = try ctx.stack.pop();
    ensureSendValueEscapable(ctx, value) catch |err| {
        container_backing.releaseValue(value);
        return err;
    };

    acquireChannel(ctx, ch);

    if (ch.closed) {
        releaseChannel(ctx, ch);
        return throwChannelClosed(ctx, "cannot send on closed channel");
    }

    const scheduler = ctx.scheduler orelse {
        releaseChannel(ctx, ch);
        ctx.pending_error_message = "send must be called within a task-scope";
        return error.InvalidState;
    };

    const current = scheduler.current_task orelse {
        releaseChannel(ctx, ch);
        ctx.pending_error_message = "send must be called from a running task";
        return error.InvalidState;
    };

    // if there are waiting receivers, hand the value directly to the first eligible one
    while (ch.waiting_receivers.items.len > 0) {
        const receiver_entry = ch.waiting_receivers.orderedRemove(0);
        const receiver = receiver_entry.task;

        if (receiver_entry.select_ctx) |sel| {
            if (sel.fired) continue;
            sel.fired = true;
            sel.result_value = try tasks.deepCopyValue(value, receiver.ctx.arena.allocator(), ctx.allocator);
            sel.result_channel = ch;
        } else {
            const copied = try tasks.deepCopyValue(value, receiver.ctx.arena.allocator(), ctx.allocator);
            try receiver.ctx.stack.pushMoved(copied);
        }

        receiver.blocked_on_channel = null;
        receiver.value_delivered = true;
        releaseChannel(ctx, ch);
        // The receiver holds an independent deep copy, so the sender's
        // owning reference to the popped value ends here.
        container_backing.releaseValue(value);
        try scheduler.wakeTask(receiver);
        return;
    }

    // if buffer has space, which is never true for unbuffered, push to buffer.
    // The buffer takes its own reference or copy, because the sender and its arena can be gone
    // before the value is received; the sender's owning reference to the popped value ends here.
    if (ch.capacity > 0 and !ch.buffer.isFull()) {
        const entry = adoptForBuffer(ctx, ch, value) catch |err| {
            releaseChannel(ctx, ch);
            container_backing.releaseValue(value);
            return err;
        };
        ch.buffer.push(entry);
        releaseChannel(ctx, ch);
        container_backing.releaseValue(value);
        return;
    }

    // blocking send: add to waiting list, release lock, then suspend.
    // The entry holds the sender's owning reference while suspended.
    try ch.waiting_senders.append(ch.allocator, .{
        .task = current,
        .value = value,
    });
    current.blocked_on_channel = @ptrCast(ch);
    releaseChannel(ctx, ch);
    scheduler.suspendCurrentTask();

    // coming back from blocking
    acquireChannel(ctx, ch);
    current.blocked_on_channel = null;

    const delivered = current.value_delivered;
    current.value_delivered = false;
    const closed = ch.closed;
    releaseChannel(ctx, ch);

    // The sender's owning reference is done in every post-suspend case: a
    // receiver either deep-copied the value (independent copy) or moved it
    // into the buffer (retained there); on a failed send the popped value is
    // simply dropped.
    container_backing.releaseValue(value);

    // A receiver may have taken our value directly while we were suspended.
    // If so, the send is complete regardless of whether the channel was
    // subsequently closed.
    if (delivered) {
        return;
    }

    try helpers.checkCancellation(ctx);

    if (closed) {
        return throwChannelClosed(ctx, "cannot send on closed channel");
    }
}

/// receive ( ch -- val )
///
/// If there are waiting senders, takes a value directly from the first one and wakes that sender.
/// If the buffer is non-empty, pops a value from the buffer and returns it; if there are waiting senders, moves the first sender's value into the buffer and wakes that sender.
/// If the channel is closed and there are no waiting senders or buffered values, throws ChannelClosed.
/// Otherwise, blocks until a sender is waiting or a value is buffered, then behaves as above when it wakes up.
///
/// In all cases, if the current task is cancelled while blocked, throws a "task-cancelled" error.
///
/// Values that cross the task boundary are deep-copied, or shared by refcount bump when provably
/// immutable and self-contained: either way the receiver observes a value independent of the
/// sender's. Waking a sender or receiver pinned to a different worker routes through the target's
/// home worker external queue.
fn nativeReceive(ctx: *Context) anyerror!void {
    if (ctx.in_module_load) {
        ctx.pending_error_message = "receive cannot be called during module loading";
        return error.InvalidState;
    }

    const ch = try helpers.popChannel(ctx);

    acquireChannel(ctx, ch);

    const scheduler = ctx.scheduler orelse {
        releaseChannel(ctx, ch);
        ctx.pending_error_message = "receive must be called within a task-scope";
        return error.InvalidState;
    };

    const current = scheduler.current_task orelse {
        releaseChannel(ctx, ch);
        ctx.pending_error_message = "receive must be called from a running task";
        return error.InvalidState;
    };

    // NOTE(ripta): drain the buffer before any direct sender handoff so fifo order holds
    //
    // A sender on a buffered channel only blocks once the buffer is full, so the buffered values are
    // always older than a blocked sender's value. Pop from the buffer, then if a sender is waiting,
    // move its value into the freed slot and wake the sender.
    if (ch.capacity > 0 and !ch.buffer.isEmpty()) {
        const entry = ch.buffer.pop();
        const copied = try tasks.deepCopyValue(entry.value, ctx.arena.allocator(), ctx.allocator);
        try ctx.stack.pushMoved(copied);

        // The buffer's ownership of the popped entry ends here.
        entry.destroy(ch.allocator);

        if (ch.waiting_senders.items.len > 0) {
            // Adopt before removing the entry: on out-of-memory the sender simply stays queued
            // for a later receive, instead of being woken with its value silently dropped.
            if (adoptForBuffer(ctx, ch, ch.waiting_senders.items[0].value)) |refill| {
                const sender_entry = ch.waiting_senders.orderedRemove(0);

                // The buffer holds its own reference or copy; the woken sender releases its own reference.
                ch.buffer.push(refill);
                sender_entry.task.blocked_on_channel = null;
                sender_entry.task.value_delivered = true;
                try scheduler.wakeTask(sender_entry.task);
            } else |_| {}
        }

        releaseChannel(ctx, ch);
        return;
    }

    // buffer empty: always the case for an unbuffered channel
    // if sender is waiting, take its value directly and wake it
    if (ch.waiting_senders.items.len > 0) {
        const sender_entry = ch.waiting_senders.orderedRemove(0);
        const sender = sender_entry.task;

        const copied = try tasks.deepCopyValue(sender_entry.value, ctx.arena.allocator(), ctx.allocator);
        try ctx.stack.pushMoved(copied);

        sender.blocked_on_channel = null;
        sender.value_delivered = true;
        releaseChannel(ctx, ch);
        try scheduler.wakeTask(sender);
        return;
    }

    // if closed and nothing available, throw
    if (ch.closed) {
        releaseChannel(ctx, ch);
        return throwChannelClosed(ctx, "channel is closed");
    }

    // blocking receive: add to waiting list, release lock, then suspend
    try ch.waiting_receivers.append(ch.allocator, .{
        .task = current,
    });
    current.blocked_on_channel = @ptrCast(ch);
    releaseChannel(ctx, ch);
    scheduler.suspendCurrentTask();

    // resume from blocking
    acquireChannel(ctx, ch);
    current.blocked_on_channel = null;

    // NOTE(ripta): A sender may have delivered a value directly to our stack while we were suspended.
    //              If so, the receive is complete regardless of whether the channel was subsequently closed.
    if (current.value_delivered) {
        current.value_delivered = false;
        releaseChannel(ctx, ch);
        return;
    }

    const closed = ch.closed;
    releaseChannel(ctx, ch);

    try helpers.checkCancellation(ctx);

    // If the channel was closed while we were waiting, no value was pushed
    if (closed) {
        return throwChannelClosed(ctx, "channel is closed");
    }
}

/// try-receive ( ch -- val/f flag )
///
/// Non-blocking receive attempt. If a value is immediately available from a
/// waiting sender or the buffer, pushes the value and t. Otherwise pushes f f.
///
/// The received value is deep-copied at the task boundary. When the
/// waiting sender that supplied the value is pinned to another worker, the
/// sender wakes via its home worker's external queue.
fn nativeTryReceive(ctx: *Context) anyerror!void {
    const ch = try helpers.popChannel(ctx);

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "try-receive must be called within a task-scope";
        return error.InvalidState;
    };

    acquireChannel(ctx, ch);
    defer releaseChannel(ctx, ch);

    // drain buffered data before a blocked sender so FIFO order holds, matching receive
    // an unbuffered channel has an empty buffer and falls through
    if (ch.capacity > 0 and !ch.buffer.isEmpty()) {
        const entry = ch.buffer.pop();
        const copied = try tasks.deepCopyValue(entry.value, ctx.arena.allocator(), ctx.allocator);
        try ctx.stack.pushMoved(copied);
        try ctx.stack.push(.{ .boolean = true });
        // The buffer's ownership of the popped entry ends here.
        entry.destroy(ch.allocator);

        if (ch.waiting_senders.items.len > 0) {
            // Adopt before removing the entry: on out-of-memory the sender simply stays queued
            // for a later receive, instead of being woken with its value silently dropped.
            if (adoptForBuffer(ctx, ch, ch.waiting_senders.items[0].value)) |refill| {
                const sender_entry = ch.waiting_senders.orderedRemove(0);
                // The buffer holds its own reference or copy; the woken sender releases its own reference.
                ch.buffer.push(refill);
                sender_entry.task.blocked_on_channel = null;
                sender_entry.task.value_delivered = true;
                try scheduler.wakeTask(sender_entry.task);
            } else |_| {}
        }
        return;
    }

    if (ch.waiting_senders.items.len > 0) {
        const sender_entry = ch.waiting_senders.orderedRemove(0);
        const copied = try tasks.deepCopyValue(sender_entry.value, ctx.arena.allocator(), ctx.allocator);
        try ctx.stack.pushMoved(copied);
        try ctx.stack.push(.{ .boolean = true });
        sender_entry.task.blocked_on_channel = null;
        sender_entry.task.value_delivered = true;
        try scheduler.wakeTask(sender_entry.task);
        return;
    }

    try ctx.stack.push(.{ .boolean = false });
    try ctx.stack.push(.{ .boolean = false });
}

/// close-channel ( ch -- )
///
/// Mark the channel as closed. Double-close is a no-op.
/// Wakes all blocked senders and receivers so they can observe the closed
/// state. Tasks pinned to other workers are woken via their home worker's
/// external queue.
fn nativeCloseChannel(ctx: *Context) anyerror!void {
    const ch = try helpers.popChannel(ctx);

    acquireChannel(ctx, ch);

    if (ch.closed) {
        releaseChannel(ctx, ch);
        return;
    }
    ch.closed = true;

    const scheduler = ctx.scheduler orelse {
        releaseChannel(ctx, ch);
        return;
    };

    // Collect tasks to wake under the lock, then enqueue outside the lock
    //  to avoid holding the channel mutex while touching the scheduler
    const alloc = ctx.arena.allocator();
    const tasks_to_wake = alloc.alloc(*Task, ch.waiting_senders.items.len + ch.waiting_receivers.items.len) catch {
        releaseChannel(ctx, ch);
        return;
    };
    var wake_count: usize = 0;

    for (ch.waiting_senders.items) |entry| {
        entry.task.blocked_on_channel = null;
        tasks_to_wake[wake_count] = entry.task;
        wake_count += 1;
    }
    ch.waiting_senders.clearRetainingCapacity();

    for (ch.waiting_receivers.items) |entry| {
        if (entry.select_ctx) |sel| {
            if (sel.fired) continue;
            sel.fired = true;
            sel.result_channel = ch;
        }
        entry.task.blocked_on_channel = null;
        tasks_to_wake[wake_count] = entry.task;
        wake_count += 1;
    }
    ch.waiting_receivers.clearRetainingCapacity();

    releaseChannel(ctx, ch);

    for (tasks_to_wake[0..wake_count]) |task| {
        scheduler.wakeTask(task) catch {};
    }
}

/// select ( array -- val ch )
///
/// Wait on multiple channels. Scans each channel for an immediately available
/// value (waiting senders or buffered data). If one is found, returns
/// immediately with the value and the channel it came from.
///
/// If no channel has data ready, registers the current task as a receiver on
/// all channels with a shared SelectContext, then suspends. When any channel
/// delivers a value (via send) or is closed, the task wakes and returns the
/// result. Stale receiver entries are cleaned from the other channels.
///
/// Registered channels may have senders and receivers pinned to any worker;
/// when delivery happens on another worker, the selecting task wakes via
/// its home worker's external queue. The delivered value is deep-copied at
/// the task boundary.
fn nativeSelect(ctx: *Context) anyerror!void {
    if (ctx.in_module_load) {
        ctx.pending_error_message = "select cannot be called during module loading";
        return error.InvalidState;
    }

    const val = try ctx.stack.pop();
    // The popped array must stay alive across the suspension below, since
    // `items` borrows its backing; the deferred release runs at return.
    defer container_backing.releaseValue(val);
    const items = switch (val) {
        .array => |a| a.items,
        else => {
            helpers.setTypeMismatchError(ctx, "array", val);
            return error.TypeMismatch;
        },
    };

    if (items.len == 0) {
        ctx.pending_error_message = "select requires a non-empty array of channels";
        return error.InvalidArgument;
    }

    const alloc = ctx.arena.allocator();
    const channels = try alloc.alloc(*Channel, items.len);
    for (items, 0..) |item, i| {
        channels[i] = switch (item) {
            .channel => |ch| ch,
            else => {
                helpers.setTypeMismatchError(ctx, "channel", item);
                return error.TypeMismatch;
            },
        };
    }

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "select must be called within a task-scope";
        return error.InvalidState;
    };

    const current = scheduler.current_task orelse {
        ctx.pending_error_message = "select must be called from a running task";
        return error.InvalidState;
    };

    lockChannelsOrdered(ctx, channels);

    // Per channel, drain buffered data before a blocked sender so FIFO order
    // holds: a sender on a buffered channel only blocks once the buffer is
    // full, so the buffered values are older. An unbuffered channel has an
    // empty buffer and falls through to its waiting sender, preserving the
    // direct-handoff priority that path relies on.
    for (channels) |ch| {
        if (ch.capacity > 0 and !ch.buffer.isEmpty()) {
            const entry = ch.buffer.pop();
            const copied = try tasks.deepCopyValue(entry.value, alloc, ctx.allocator);

            try ctx.stack.pushMoved(copied);
            try ctx.stack.push(.{ .channel = ch });
            // The buffer's ownership of the popped entry ends here.
            entry.destroy(ch.allocator);

            if (ch.waiting_senders.items.len > 0) {
                // Adopt before removing the entry: on out-of-memory the sender simply stays
                // queued for a later receive, instead of being woken with its value silently
                // dropped.
                if (adoptForBuffer(ctx, ch, ch.waiting_senders.items[0].value)) |refill| {
                    const sender_entry = ch.waiting_senders.orderedRemove(0);
                    // The buffer holds its own reference or copy; the woken sender releases its
                    // own reference.
                    ch.buffer.push(refill);
                    sender_entry.task.blocked_on_channel = null;
                    try scheduler.wakeTask(sender_entry.task);
                } else |_| {}
            }
            unlockChannelsOrdered(ctx, channels);
            return;
        }

        if (ch.waiting_senders.items.len > 0) {
            const sender_entry = ch.waiting_senders.orderedRemove(0);
            const copied = try tasks.deepCopyValue(sender_entry.value, alloc, ctx.allocator);
            try ctx.stack.pushMoved(copied);
            try ctx.stack.push(.{ .channel = ch });

            sender_entry.task.blocked_on_channel = null;
            unlockChannelsOrdered(ctx, channels);
            try scheduler.wakeTask(sender_entry.task);
            return;
        }
    }

    var all_closed = true;
    for (channels) |ch| {
        if (!ch.closed) {
            all_closed = false;
            break;
        }
    }
    if (all_closed) {
        unlockChannelsOrdered(ctx, channels);
        return throwChannelClosed(ctx, "all channels in select are closed");
    }

    // NOTE(ripta): no immediate data, register on all non-closed channels and suspend
    var sel_ctx = channel_mod.SelectContext{
        .task = current,
    };

    for (channels) |ch| {
        if (ch.closed) continue;
        try ch.waiting_receivers.append(ch.allocator, .{
            .task = current,
            .select_ctx = &sel_ctx,
        });
    }

    current.blocked_on_channel = @ptrCast(channels[0]);
    unlockChannelsOrdered(ctx, channels);
    scheduler.suspendCurrentTask();

    lockChannelsOrdered(ctx, channels);
    current.blocked_on_channel = null;

    for (channels) |ch| {
        removeReceiverEntries(ch, current);
    }

    const result_value = sel_ctx.result_value;
    const result_channel = sel_ctx.result_channel;
    unlockChannelsOrdered(ctx, channels);

    // A delivered result the task never consumes carries its own owning reference (a shared
    // backing's refcount bump), so cancellation must release it or the backing leaks.
    helpers.checkCancellation(ctx) catch |err| {
        if (result_value) |result_val| container_backing.releaseValue(result_val);
        return err;
    };

    if (result_value) |result_val| {
        try ctx.stack.pushMoved(result_val);
        try ctx.stack.push(.{ .channel = result_channel.? });
        return;
    }

    return throwChannelClosed(ctx, "selected channel was closed");
}

fn channelPtrLessThan(_: void, a: *Channel, b: *Channel) bool {
    return @intFromPtr(a) < @intFromPtr(b);
}

fn lockChannelsOrdered(ctx: *Context, channels: []*Channel) void {
    std.mem.sort(*Channel, channels, {}, channelPtrLessThan);
    for (channels) |ch| acquireChannel(ctx, ch);
}

fn unlockChannelsOrdered(ctx: *Context, channels: []*Channel) void {
    var i: usize = channels.len;
    while (i > 0) {
        i -= 1;
        releaseChannel(ctx, channels[i]);
    }
}

/// Remove all receiver entries for a specific task from a channel's waiting list.
///
fn removeReceiverEntries(ch: *Channel, task: *Task) void {
    var i: usize = 0;
    while (i < ch.waiting_receivers.items.len) {
        if (ch.waiting_receivers.items[i].task == task) {
            _ = ch.waiting_receivers.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

test "send rejects borrowed buffer before buffered channel insertion" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var scheduler = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var scope = task_mod.TaskScope.init(std.testing.allocator);
    defer scope.deinit();

    var current = Task{
        .id = 1,
        .name = null,
        .status = std.atomic.Value(task_mod.TaskStatus).init(.running),
        .ctx = &ctx,
        .scope = &scope,
        .quotation = .{ .instructions = &.{}, .effect = null },
    };
    scheduler.current_task = &current;
    ctx.scheduler = &scheduler;

    const ch = try Channel.init(std.testing.allocator, 1);
    defer {
        ch.deinit();
        std.testing.allocator.destroy(ch);
    }

    var bytes = [_]u8{ 1, 2, 3 };
    const ba = try value_mod.makeBorrowedByteArray(std.testing.allocator, bytes[0..]);
    defer std.testing.allocator.destroy(ba);

    try ctx.stack.push(.{ .byte_array = ba });
    try ctx.stack.push(.{ .channel = ch });

    try std.testing.expectError(error.UserThrown, nativeSend(&ctx));
    try std.testing.expect(ctx.thrown_error != null);
    try std.testing.expectEqualStrings("borrowed-buffer-escape", ctx.thrown_error.?.error_type);
    try std.testing.expectEqual(@as(usize, 0), ch.buffer.count);
    try std.testing.expectEqual(@as(usize, 0), ch.waiting_senders.items.len);
}

test "send accepts owned buffer into buffered channel" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var scheduler = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var scope = task_mod.TaskScope.init(std.testing.allocator);
    defer scope.deinit();

    var current = Task{
        .id = 1,
        .name = null,
        .status = std.atomic.Value(task_mod.TaskStatus).init(.running),
        .ctx = &ctx,
        .scope = &scope,
        .quotation = .{ .instructions = &.{}, .effect = null },
    };
    scheduler.current_task = &current;
    ctx.scheduler = &scheduler;

    const ch = try Channel.init(std.testing.allocator, 1);
    defer {
        ch.deinit();
        std.testing.allocator.destroy(ch);
    }

    const ba = try value_mod.ByteArray.create(std.testing.allocator);
    defer container_backing.releaseValue(.{ .byte_array = ba });
    try ba.ensureTotalCapacity(std.testing.allocator, 3);
    ba.appendAssumeCapacity(1);
    ba.appendAssumeCapacity(2);
    ba.appendAssumeCapacity(3);

    try ctx.stack.push(.{ .byte_array = ba });
    try ctx.stack.push(.{ .channel = ch });

    try nativeSend(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ch.buffer.count);
    try std.testing.expect(ctx.thrown_error == null);

    // send adopted the value into a buffer-owned entry; destroy it so the
    // entry's reference and copy arena balance.
    const buffered = ch.buffer.pop();
    buffered.destroy(ch.allocator);
}
