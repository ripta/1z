const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("../context.zig").Context;
const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const channel_mod = @import("../channel.zig");
const Channel = channel_mod.Channel;
const Scheduler = @import("../scheduler.zig").Scheduler;
const tasks = @import("tasks.zig");

pub const primitives = [_]Primitive{
    .{ .name = "<channel>", .stack_effect = "-- ch", .doc = "Create an unbufferedf channel.", .func = nativeCreateChannel },
    .{ .name = "send", .stack_effect = "val ch --", .doc = "Send a value to a channel. Blocks if no receiver ready (unbuffered) or buffer full.", .func = nativeSend },
    .{
        .name = "receive",
        .stack_effect = "ch -- val",
        .doc = "Receive a value from a channel. Blocks if no value available. Throws ChannelClosed if closed and empty.",
        .func = nativeReceive,
    },
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

/// send ( val ch -- )
///
/// If the channel is unbuffered, blocks until a receiver is waiting, then hands off the value directly to that receiver.
/// If the channel is buffered and has space, pushes the value onto the buffer and returns immediately.
/// If the channel is buffered and full, blocks until a receiver takes something from the buffer, then pushes the value onto the buffer and returns.
///
/// In all cases, if the channel is closed, throws ChannelClosed. If the current task is cancelled while blocked, throws a "task-cancelled" error.
fn nativeSend(ctx: *Context) anyerror!void {
    const ch = try helpers.popChannel(ctx);
    const value = try ctx.stack.pop();

    if (ch.closed) {
        ctx.pending_error_message = "cannot send on closed channel";
        return error.ChannelClosed;
    }

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "send must be called within a task-scope";
        return error.InvalidState;
    };

    const current = scheduler.current_task orelse {
        ctx.pending_error_message = "send must be called from a running task";
        return error.InvalidState;
    };

    // if there are waiting receivers, hand the value directly to the first one
    if (ch.waiting_receivers.items.len > 0) {
        const receiver_entry = ch.waiting_receivers.orderedRemove(0);
        const receiver = receiver_entry.task;

        const copied = try tasks.deepCopyValue(value, receiver.ctx.arena.allocator());
        try receiver.ctx.stack.push(copied);

        receiver.blocked_on_channel = null;
        try scheduler.enqueue(receiver);
        return;
    }

    // if buffer has space, which is never true for unbuffered, push to buffer
    if (ch.capacity > 0 and !ch.buffer.isFull()) {
        ch.buffer.push(value);
        return;
    }

    // blocking send, ig
    try ch.waiting_senders.append(ch.allocator, .{
        .task = current,
        .value = value,
    });
    current.blocked_on_channel = @ptrCast(ch);
    scheduler.suspendCurrentTask();

    // coming back from blocking
    current.blocked_on_channel = null;
    if (current.cancelled) {
        ctx.thrown_error = .{
            .error_type = "task-cancelled",
            .message = "task was cancelled",
        };
        return error.UserThrown;
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
    const ch = try helpers.popChannel(ctx);

    const scheduler = ctx.scheduler orelse {
        ctx.pending_error_message = "receive must be called within a task-scope";
        return error.InvalidState;
    };

    const current = scheduler.current_task orelse {
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
            try scheduler.enqueue(sender_entry.task);
        }
        return;
    }

    // if closed and nothing available, throw
    if (ch.closed) {
        ctx.pending_error_message = "channel is closed";
        return error.ChannelClosed;
    }

    // blocking receive
    try ch.waiting_receivers.append(ch.allocator, .{
        .task = current,
    });
    current.blocked_on_channel = @ptrCast(ch);
    scheduler.suspendCurrentTask();

    // resume from blocking
    current.blocked_on_channel = null;
    if (current.cancelled) {
        ctx.thrown_error = .{
            .error_type = "task-cancelled",
            .message = "task was cancelled",
        };
        return error.UserThrown;
    }
}
