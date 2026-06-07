const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const parser = @import("parser.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Instruction = @import("value.zig").Instruction;
const Context = @import("context.zig").Context;
const task_mod = @import("task.zig");

const is_freestanding = builtin.os.tag == .freestanding;

/// Freestanding builds have no libc and no ucontext-based coroutine support.
/// The parser-coroutine path is unreachable on freestanding (no interactive
/// repl/debugger, no incremental parse), so stub the symbols and types so
/// the module compiles without resolving `extern "c"` declarations.
const FreestandingUcontext = extern struct {
    stack: extern struct {
        sp: ?*anyopaque = null,
        size: usize = 0,
        flags: c_int = 0,
    } = .{},
    link: ?*FreestandingUcontext = null,
};

const ucontext_t = if (is_freestanding) FreestandingUcontext else std.c.ucontext_t;

const c = if (is_freestanding) struct {
    pub fn getcontext(_: *ucontext_t) c_int {
        return 0;
    }
    pub fn makecontext(_: *ucontext_t, _: *const fn () callconv(.c) void, _: c_int) void {}
    pub fn swapcontext(_: *ucontext_t, _: *const ucontext_t) c_int {
        return 0;
    }
} else struct {
    extern "c" fn getcontext(ucp: *std.c.ucontext_t) c_int;
    extern "c" fn makecontext(ucp: *std.c.ucontext_t, func: *const fn () callconv(.c) void, argc: c_int) void;
    extern "c" fn swapcontext(oucp: *std.c.ucontext_t, ucp: *const std.c.ucontext_t) c_int;
};

pub const ParseResult = union(enum) {
    success: []const Instruction,
    parse_error: parser.ParseError,
};

pub const Status = enum { running, yielded, completed };

pub const ParserCoroutine = struct {
    uctx: ucontext_t = undefined,
    caller_uctx: ucontext_t = undefined,
    stack_mem: []align(std.heap.page_size_min) u8,
    tokenizer: ?*Tokenizer = null,
    result: ?ParseResult = null,
    status: Status = .running,
    allocator: Allocator,
    ctx: ?*Context,
    initial_input: []const u8 = "",

    pub fn yield(self: *ParserCoroutine) void {
        self.status = .yielded;
        _ = c.swapcontext(&self.uctx, &self.caller_uctx);
    }

    pub fn @"resume"(self: *ParserCoroutine) void {
        self.status = .running;
        _ = c.swapcontext(&self.caller_uctx, &self.uctx);
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

    _ = c.getcontext(&co.uctx);
    co.uctx.stack.sp = @ptrCast(co.stack_mem.ptr + page_size);
    co.uctx.stack.size = @intCast(co.stack_mem.len - page_size);
    co.uctx.stack.flags = 0;
    co.uctx.link = &co.caller_uctx;

    c.makecontext(&co.uctx, &parserEntryPoint, 0);
}
