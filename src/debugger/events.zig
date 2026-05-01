const std = @import("std");
const Context = @import("../context.zig").Context;

pub const DebugEvent = enum {
    paused,
    resumed,
    breakpoint_hit,
    step_completed,
};

pub const EventListener = *const fn (event: DebugEvent, ctx: *Context) void;

/// C-compatible callback type for the embedding API.
pub const CCallbackFn = *const fn (c_int, ?*anyopaque, ?*anyopaque) callconv(.c) void;

const max_listeners = 16;

pub const EventEmitter = struct {
    listeners: [max_listeners]EventListener = undefined,
    len: usize = 0,

    /// C embedding API callback and associated state.
    c_callback: ?CCallbackFn = null,
    c_handle: ?*anyopaque = null,
    c_userdata: ?*anyopaque = null,

    pub fn addListener(self: *EventEmitter, listener: EventListener) void {
        if (self.len < max_listeners) {
            self.listeners[self.len] = listener;
            self.len += 1;
        }
    }

    pub fn removeListener(self: *EventEmitter, listener: EventListener) void {
        for (0..self.len) |i| {
            if (self.listeners[i] == listener) {
                // Shift remaining listeners down
                var j = i;
                while (j + 1 < self.len) : (j += 1) {
                    self.listeners[j] = self.listeners[j + 1];
                }
                self.len -= 1;
                return;
            }
        }
    }

    pub fn emit(self: *EventEmitter, event: DebugEvent, ctx: *Context) void {
        for (self.listeners[0..self.len]) |listener| {
            listener(event, ctx);
        }
        if (self.c_callback) |cb| {
            cb(@intFromEnum(event), self.c_handle, self.c_userdata);
        }
    }
};

test "EventEmitter add and remove" {
    const testing = std.testing;

    var emitter = EventEmitter{};

    const Wrapper = struct {
        fn listener(_: DebugEvent, _: *Context) void {}
    };

    emitter.addListener(&Wrapper.listener);
    try testing.expectEqual(@as(usize, 1), emitter.len);

    emitter.removeListener(&Wrapper.listener);
    try testing.expectEqual(@as(usize, 0), emitter.len);
}

test "EventEmitter remove nonexistent listener is no-op" {
    const testing = std.testing;

    var emitter = EventEmitter{};

    const Wrapper = struct {
        fn listener(_: DebugEvent, _: *Context) void {}
    };

    emitter.removeListener(&Wrapper.listener);
    try testing.expectEqual(@as(usize, 0), emitter.len);
}

test "EventEmitter multiple listeners" {
    const testing = std.testing;

    var emitter = EventEmitter{};

    const W1 = struct {
        fn listener(_: DebugEvent, _: *Context) void {}
    };
    const W2 = struct {
        fn listener(_: DebugEvent, _: *Context) void {}
    };

    emitter.addListener(&W1.listener);
    emitter.addListener(&W2.listener);
    try testing.expectEqual(@as(usize, 2), emitter.len);

    emitter.removeListener(&W1.listener);
    try testing.expectEqual(@as(usize, 1), emitter.len);

    // Remaining listener should be W2
    try testing.expectEqual(&W2.listener, emitter.listeners[0]);
}
