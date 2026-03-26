const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;
const LockLevel = @import("../lock_order.zig").LockLevel;
const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const channel_mod = @import("../channel.zig");
const Channel = channel_mod.Channel;
const Scheduler = @import("../scheduler.zig").Scheduler;
const tasks = @import("tasks.zig");

fn acquireChannel(ctx: *Context, ch: *Channel) void {
    ctx.lock_order_tracker.acquire(.channel);
    ch.mutex.lock();
}

fn releaseChannel(ctx: *Context, ch: *Channel) void {
    ch.mutex.unlock();
    ctx.lock_order_tracker.release(.channel);
}

fn throwChannelClosed(ctx: *Context, message: []const u8) anyerror {
    ctx.thrown_error = .{
        .error_type = "channel-closed",
        .message = message,
    };
    return error.UserThrown;
}

pub const primitives = [_]Primitive{
    .{ .name = "<channel>", .stack_effect = "-- ch", .doc = "Create an unbufferedf channel.", .func = nativeCreateChannel },
    .{ .name = "send", .stack_effect = "val ch --", .doc = "Send a value to a channel. Blocks if no receiver ready (unbuffered) or buffer full.", .func = nativeSend },
    .{
        .name = "receive",
        .stack_effect = "ch -- val",
        .doc = "Receive a value from a channel. Blocks if no value available. Throws ChannelClosed if closed and empty.",
        .func = nativeReceive,
    },
    .{ .name = "try-receive", .stack_effect = "ch -- val/f ?", .doc = "Non-blocking receive. Returns value and t if data is available, or f and f if not.", .func = nativeTryReceive },
    .{ .name = "<buffered-channel>", .stack_effect = "n -- ch", .doc = "Create a buffered channel with capacity n.", .func = nativeCreateBufferedChannel },
    .{ .name = "close-channel", .stack_effect = "ch --", .doc = "Close a channel. No more sends allowed; receives drain buffered values.", .func = nativeCloseChannel },
    .{ .name = "select", .stack_effect = "array -- val ch", .doc = "Wait on multiple channels. Returns the first available value and which channel it came from.", .func = nativeSelect },
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
fn nativeSend(ctx: *Context) anyerror!void {
    if (ctx.in_module_load) {
        ctx.pending_error_message = "send cannot be called during module loading";
        return error.InvalidState;
    }

    const ch = try helpers.popChannel(ctx);
    const value = try ctx.stack.pop();

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
            sel.result_value = try tasks.deepCopyValue(value, receiver.ctx.arena.allocator());
            sel.result_channel = ch;
        } else {
            const copied = try tasks.deepCopyValue(value, receiver.ctx.arena.allocator());
            try receiver.ctx.stack.push(copied);
        }

        receiver.blocked_on_channel = null;
        receiver.value_delivered = true;
        releaseChannel(ctx, ch);
        try scheduler.enqueue(receiver);
        return;
    }

    // if buffer has space, which is never true for unbuffered, push to buffer
    if (ch.capacity > 0 and !ch.buffer.isFull()) {
        ch.buffer.push(value);
        releaseChannel(ctx, ch);
        return;
    }

    // blocking send: add to waiting list, release lock, then suspend
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

    // A receiver may have taken our value directly while we were suspended.
    // If so, the send is complete regardless of whether the channel was
    // subsequently closed.
    if (current.value_delivered) {
        current.value_delivered = false;
        releaseChannel(ctx, ch);
        return;
    }

    const closed = ch.closed;
    releaseChannel(ctx, ch);

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

    // if there are waiting senders, take the value directly from the first one
    if (ch.waiting_senders.items.len > 0) {
        const sender_entry = ch.waiting_senders.orderedRemove(0);
        const sender = sender_entry.task;

        const copied = try tasks.deepCopyValue(sender_entry.value, ctx.arena.allocator());
        try ctx.stack.push(copied);

        sender.blocked_on_channel = null;
        sender.value_delivered = true;
        releaseChannel(ctx, ch);
        try scheduler.enqueue(sender);
        return;
    }

    // if buffer is non-empty, pop from it; then if senders are waiting, move
    // the first sender's value into the buffer and wake the sender
    if (ch.capacity > 0 and !ch.buffer.isEmpty()) {
        const val = ch.buffer.pop();
        const copied = try tasks.deepCopyValue(val, ctx.arena.allocator());
        try ctx.stack.push(copied);

        if (ch.waiting_senders.items.len > 0) {
            const sender_entry = ch.waiting_senders.orderedRemove(0);
            ch.buffer.push(sender_entry.value);
            sender_entry.task.blocked_on_channel = null;
            sender_entry.task.value_delivered = true;
            try scheduler.enqueue(sender_entry.task);
        }
        releaseChannel(ctx, ch);
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

    // NOTE(ripta_: A sender may have delivered a value directly to our stack while we
    //              were suspended. If so, the receive is complete regardless of whether
    //              the channel was subsequently closed.
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
fn nativeTryReceive(ctx: *Context) anyerror!void {
    const ch = try helpers.popChannel(ctx);

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "try-receive must be called within a task-scope";
        return error.InvalidState;
    };

    acquireChannel(ctx, ch);
    defer releaseChannel(ctx, ch);

    if (ch.waiting_senders.items.len > 0) {
        const sender_entry = ch.waiting_senders.orderedRemove(0);
        const copied = try tasks.deepCopyValue(sender_entry.value, ctx.arena.allocator());
        try ctx.stack.push(copied);
        try ctx.stack.push(.{ .boolean = true });
        sender_entry.task.blocked_on_channel = null;
        sender_entry.task.value_delivered = true;
        try scheduler.enqueue(sender_entry.task);
        return;
    }

    if (ch.capacity > 0 and !ch.buffer.isEmpty()) {
        const val = ch.buffer.pop();
        const copied = try tasks.deepCopyValue(val, ctx.arena.allocator());
        try ctx.stack.push(copied);
        try ctx.stack.push(.{ .boolean = true });

        if (ch.waiting_senders.items.len > 0) {
            const sender_entry = ch.waiting_senders.orderedRemove(0);
            ch.buffer.push(sender_entry.value);
            sender_entry.task.blocked_on_channel = null;
            sender_entry.task.value_delivered = true;
            try scheduler.enqueue(sender_entry.task);
        }
        return;
    }

    try ctx.stack.push(.{ .boolean = false });
    try ctx.stack.push(.{ .boolean = false });
}

/// close-channel ( ch -- )
///
/// Mark the channel as closed. Double-close is a no-op.
/// Wakes all blocked senders and receivers so they can observe the closed state.
fn nativeCloseChannel(ctx: *Context) anyerror!void {
    const Task = @import("../task.zig").Task;
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
        scheduler.enqueue(task) catch {};
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
fn nativeSelect(ctx: *Context) anyerror!void {
    if (ctx.in_module_load) {
        ctx.pending_error_message = "select cannot be called during module loading";
        return error.InvalidState;
    }

    const val = try ctx.stack.pop();
    const items = switch (val) {
        .array => |a| a,
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

    // NOTE(ripta): we check waiting senders before buffered data to give priority to directt
    //              handoff in unbuffered channels, but this means that if a sender and a buffered
    //              value become available simultaneously, the sender wins.
    for (channels) |ch| {
        if (ch.waiting_senders.items.len > 0) {
            const sender_entry = ch.waiting_senders.orderedRemove(0);
            const copied = try tasks.deepCopyValue(sender_entry.value, alloc);
            try ctx.stack.push(copied);
            try ctx.stack.push(.{ .channel = ch });

            sender_entry.task.blocked_on_channel = null;
            unlockChannelsOrdered(ctx, channels);
            try scheduler.enqueue(sender_entry.task);
            return;
        }

        if (ch.capacity > 0 and !ch.buffer.isEmpty()) {
            const buf_val = ch.buffer.pop();
            const copied = try tasks.deepCopyValue(buf_val, alloc);

            try ctx.stack.push(copied);
            try ctx.stack.push(.{ .channel = ch });

            if (ch.waiting_senders.items.len > 0) {
                const sender_entry = ch.waiting_senders.orderedRemove(0);
                ch.buffer.push(sender_entry.value);
                sender_entry.task.blocked_on_channel = null;
                try scheduler.enqueue(sender_entry.task);
            }
            unlockChannelsOrdered(ctx, channels);
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

    try helpers.checkCancellation(ctx);

    if (result_value) |result_val| {
        try ctx.stack.push(result_val);
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
fn removeReceiverEntries(ch: *Channel, task: *@import("../task.zig").Task) void {
    var i: usize = 0;
    while (i < ch.waiting_receivers.items.len) {
        if (ch.waiting_receivers.items[i].task == task) {
            _ = ch.waiting_receivers.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}
