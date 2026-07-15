const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const Task = @import("task.zig").Task;

const container_backing = @import("container_backing.zig");

pub const Channel = struct {
    capacity: usize,
    closed: bool = false,
    buffer: RingBuffer,
    waiting_senders: std.ArrayListUnmanaged(SenderEntry),
    waiting_receivers: std.ArrayListUnmanaged(ReceiverEntry),
    allocator: Allocator,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: Allocator, capacity: usize) !*Channel {
        const ch = try allocator.create(Channel);
        ch.* = .{
            .capacity = capacity,
            .buffer = try RingBuffer.init(allocator, capacity),
            .waiting_senders = .{},
            .waiting_receivers = .{},
            .allocator = allocator,
        };
        return ch;
    }

    /// Remove `task`'s pending waiter entry (as receiver or sender) under the
    /// channel mutex. Returns true if an entry was removed, meaning the task
    /// was still genuinely blocked on this channel.
    ///
    /// A blocked sender's owning `value` reference is left in place: the sender
    /// task releases it when it resumes and unwinds. This only drops the entry.
    ///
    /// Callers gate re-enqueue on the result. A false return means a concurrent
    /// send or receive already woke the task, so re-enqueuing it would resume a
    /// coroutine that is no longer suspended.
    pub fn removeWaiter(self: *Channel, task: *Task) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var removed = false;
        var i: usize = 0;
        while (i < self.waiting_receivers.items.len) {
            if (self.waiting_receivers.items[i].task == task) {
                _ = self.waiting_receivers.orderedRemove(i);
                removed = true;
            } else {
                i += 1;
            }
        }
        i = 0;
        while (i < self.waiting_senders.items.len) {
            if (self.waiting_senders.items[i].task == task) {
                _ = self.waiting_senders.orderedRemove(i);
                removed = true;
            } else {
                i += 1;
            }
        }
        task.blocked_on_channel = null;
        return removed;
    }

    pub fn deinit(self: *Channel) void {
        // Destroy entries the channel still owns at teardown: anything left in
        // the buffer (never received) and any sender that was abandoned while
        // blocked (e.g., a task suspended on send at shutdown). Normal
        // completion drains both, so this only fires on shutdown residue.
        var i: usize = 0;
        while (i < self.buffer.count) : (i += 1) {
            const idx = (self.buffer.head + i) % self.buffer.items.len;
            self.buffer.items[idx].destroy(self.allocator);
        }
        for (self.waiting_senders.items) |entry| {
            container_backing.releaseValue(entry.value);
        }
        self.buffer.deinit(self.allocator);
        self.waiting_senders.deinit(self.allocator);
        self.waiting_receivers.deinit(self.allocator);
    }
};

/// A value the channel buffer owns. The buffer never stores a sender's value directly, because
/// the sender's arena can be freed before the value is received: a shareable value is stored with
/// its own retained reference, and anything else is deep-copied into `arena`, a per-entry arena
/// on the channel's allocator that dies with the entry.
pub const BufferedValue = struct {
    value: Value,
    arena: ?*std.heap.ArenaAllocator = null,

    /// Release the entry's owning reference, then free its copy arena. The release runs first
    /// because a copied container's destroy touches arena memory.
    pub fn destroy(self: BufferedValue, allocator: std.mem.Allocator) void {
        container_backing.releaseValue(self.value);
        if (self.arena) |a| {
            a.deinit();
            allocator.destroy(a);
        }
    }
};

pub const RingBuffer = struct {
    items: []BufferedValue,
    head: usize = 0,
    count: usize = 0,

    pub fn init(allocator: Allocator, capacity: usize) !RingBuffer {
        if (capacity == 0) {
            return .{ .items = &.{} };
        }
        const items = try allocator.alloc(BufferedValue, capacity);
        return .{ .items = items };
    }

    pub fn deinit(self: *RingBuffer, allocator: Allocator) void {
        if (self.items.len > 0) {
            allocator.free(self.items);
        }
    }

    pub fn isFull(self: *const RingBuffer) bool {
        return self.count == self.items.len;
    }

    pub fn isEmpty(self: *const RingBuffer) bool {
        return self.count == 0;
    }

    pub fn push(self: *RingBuffer, entry: BufferedValue) void {
        const idx = (self.head + self.count) % self.items.len;
        self.items[idx] = entry;
        self.count += 1;
    }

    pub fn pop(self: *RingBuffer) BufferedValue {
        const entry = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.count -= 1;
        return entry;
    }
};

pub const SenderEntry = struct {
    task: *Task,
    value: Value,
    delivered: bool = false,
};

pub const ReceiverEntry = struct {
    task: *Task,
    select_ctx: ?*SelectContext = null,
};

pub const SelectContext = struct {
    task: *Task,
    fired: bool = false,
    result_value: ?Value = null,
    result_channel: ?*Channel = null,
};
