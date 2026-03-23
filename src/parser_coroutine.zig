const std = @import("std");
const Allocator = std.mem.Allocator;

const parser = @import("parser.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Instruction = @import("value.zig").Instruction;
const Context = @import("context.zig").Context;
const task_mod = @import("task.zig");

pub const ParseResult = union(enum) {
    success: []const Instruction,
    parse_error: parser.ParseError,
};

pub const Status = enum { running, yielded, completed };

pub const ParserCoroutine = struct {
    uctx: std.c.ucontext_t = undefined,
    caller_uctx: std.c.ucontext_t = undefined,
    stack_mem: []align(std.heap.page_size_min) u8,
    tokenizer: ?*Tokenizer = null,
    result: ?ParseResult = null,
    status: Status = .running,
    allocator: Allocator,
    ctx: ?*Context,
    initial_input: []const u8 = "",

    pub fn yield(self: *ParserCoroutine) void {
        self.status = .yielded;
        _ = task_mod.swapcontext(&self.uctx, &self.caller_uctx);
    }

    pub fn @"resume"(self: *ParserCoroutine) void {
        self.status = .running;
        _ = task_mod.swapcontext(&self.caller_uctx, &self.uctx);
    }
};

/// Thread-local variable to pass the coroutine pointer to `parserEntryPoint`.
/// Thread safety is enforced by `threadlocal`: each OS thread gets its own
/// slot, so concurrent threads cannot interfere. Within a thread the usage
/// is a same-thread trampoline: set immediately before the first resume,
/// read and cleared in the entry function before any yield point.
pub threadlocal var pending_entry_coroutine: ?*ParserCoroutine = null;

/// Entry function for parser coroutines. Called via makecontext with no
/// arguments; reads the coroutine pointer from `pending_entry_coroutine`.
pub fn parserEntryPoint() callconv(.c) void {
    const co = pending_entry_coroutine.?;
    pending_entry_coroutine = null;

    var tokenizer = Tokenizer.init(co.initial_input);
    tokenizer.parser_coroutine = co;
    co.tokenizer = &tokenizer;

    const instrs = parser.parseTopLevel(
        co.allocator,
        &tokenizer,
        co.ctx,
    ) catch |err| {
        co.result = .{ .parse_error = err };
        co.status = .completed;
        return;
    };
    co.result = .{ .success = instrs };
    co.status = .completed;
}

/// Initialize a ucontext_t for a parser coroutine, setting up the stack and
/// entry function. Parallel to task.initTaskContext.
pub fn initCoroutineContext(co: *ParserCoroutine) void {
    const page_size = std.heap.page_size_min;

    _ = std.c.getcontext(&co.uctx);
    co.uctx.stack.sp = @ptrCast(co.stack_mem.ptr + page_size);
    co.uctx.stack.size = @intCast(co.stack_mem.len - page_size);
    co.uctx.stack.flags = 0;
    co.uctx.link = &co.caller_uctx;

    task_mod.makecontext(&co.uctx, &parserEntryPoint, 0);
}
