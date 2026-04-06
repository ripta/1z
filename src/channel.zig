const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const Task = @import("task.zig").Task;

pub const Channel = struct {
    capacity: usize,
    closed: bool = false,
    buffer: RingBuffer,
    waiting_senders: std.ArrayListUnmanaged(SenderEntry),
    waiting_receivers: std.ArrayListUnmanaged(ReceiverEntry),
    allocator: Allocator,

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

    pub fn deinit(self: *Channel) void {
        self.buffer.deinit(self.allocator);
        self.waiting_senders.deinit(self.allocator);
        self.waiting_receivers.deinit(self.allocator);
    }
};

pub const RingBuffer = struct {
    items: []Value,
    head: usize = 0,
    count: usize = 0,

    pub fn init(allocator: Allocator, capacity: usize) !RingBuffer {
        if (capacity == 0) {
            return .{ .items = &.{} };
        }
        const items = try allocator.alloc(Value, capacity);
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

    pub fn push(self: *RingBuffer, value: Value) void {
        const idx = (self.head + self.count) % self.items.len;
        self.items[idx] = value;
        self.count += 1;
    }

    pub fn pop(self: *RingBuffer) Value {
        const value = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.count -= 1;
        return value;
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
