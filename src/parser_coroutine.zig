const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const parser = @import("parser.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Instruction = @import("value.zig").Instruction;
const Context = @import("context.zig").Context;
const task_mod = @import("task.zig");

// Freestanding targets have no libc and thus no `ucontext_t`. The parser coroutine is unusable
// there regardless: `StatementProcessor` (statement.zig) takes a separate, coroutine-free
// reparse path on that target and never constructs or resumes one of these. This stub keeps
// `ParserCoroutine`'s type well-formed without ever needing the real ucontext machinery to
// compile, mirroring task.zig's `mc` freestanding stub for the unrelated task-level coroutine.
const is_freestanding = builtin.os.tag == .freestanding;

const UctxT = if (is_freestanding) void else std.c.ucontext_t;

const c = if (!is_freestanding) struct {
    extern "c" fn getcontext(ucp: *std.c.ucontext_t) c_int;
    extern "c" fn makecontext(ucp: *std.c.ucontext_t, func: *const fn () callconv(.c) void, argc: c_int) void;
    extern "c" fn swapcontext(oucp: *std.c.ucontext_t, ucp: *const std.c.ucontext_t) c_int;
} else struct {};

pub const ParseResult = union(enum) {
    success: []const Instruction,
    parse_error: parser.ParseError,
};

pub const Status = enum { running, yielded, completed };

pub const ParserCoroutine = struct {
    uctx: UctxT = if (is_freestanding) {} else undefined,
    caller_uctx: UctxT = if (is_freestanding) {} else undefined,
    stack_mem: []align(std.heap.page_size_min) u8,
    tokenizer: ?*Tokenizer = null,
    result: ?ParseResult = null,
    status: Status = .running,
    allocator: Allocator,
    ctx: ?*Context,
    initial_input: []const u8 = "",
    /// Passed through to the tokenizer this coroutine builds. See `Tokenizer.at_source_start`.
    at_source_start: bool = true,

    pub fn yield(self: *ParserCoroutine) void {
        if (comptime is_freestanding) unreachable;
        self.status = .yielded;
        _ = c.swapcontext(&self.uctx, &self.caller_uctx);
    }

    pub fn @"resume"(self: *ParserCoroutine) void {
        if (comptime is_freestanding) unreachable;
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
    tokenizer.at_source_start = co.at_source_start;
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

// Apple's aarch64 makecontext trampoline enters the coroutine with x29 set to one past the
// stack top, leaving the frame-pointer chain unterminated. A stack walker (the debug
// allocator's trace capture runs on every allocation) then reads past the stack and dies with
// SIGBUS whenever the adjacent page is PROT_NONE, such as another coroutine stack's leading
// guard page.
//
// The shim zeroes x29 only for the duration of the entry call, so the entry frame's record
// terminates the chain and walkers stop there -- the same guarantee minicoro's zeroed context
// gives task coroutines. The trampoline's x29 and x30 are restored before returning: the
// trampoline anchors its post-return uc_link handoff on them, and zeroing x29 across the
// return dies with SIGILL. The walker never reads the shim's saved pair, because the walk
// already stopped at the entry frame's zero.
const use_entry_shim = !is_freestanding and builtin.cpu.arch == .aarch64;

const entry_asm_name = if (builtin.os.tag.isDarwin()) "_onez_parser_entry_point" else "onez_parser_entry_point";

comptime {
    if (use_entry_shim) {
        @export(&parserEntryPoint, .{ .name = "onez_parser_entry_point" });
    }
}

fn parserEntryShim() callconv(.naked) void {
    asm volatile ("stp x29, x30, [sp, #-16]!\n" ++
            "mov x29, xzr\n" ++
            "bl " ++ entry_asm_name ++ "\n" ++
            "ldp x29, x30, [sp], #16\n" ++
            "ret");
}

/// Initialize a ucontext_t for a parser coroutine, setting up the stack and
/// entry function. Parallel to task.initTaskContext. Never called on
/// freestanding targets; see the freestanding stub note at the top of this file.
pub fn initCoroutineContext(co: *ParserCoroutine) void {
    if (comptime is_freestanding) unreachable;

    const page_size = std.heap.page_size_min;

    _ = std.c.getcontext(&co.uctx);
    co.uctx.stack.sp = @ptrCast(co.stack_mem.ptr + page_size);
    co.uctx.stack.size = @intCast(co.stack_mem.len - page_size);
    co.uctx.stack.flags = 0;
    co.uctx.link = &co.caller_uctx;

    const entry: *const fn () callconv(.c) void = if (comptime use_entry_shim)
        @ptrCast(&parserEntryShim)
    else
        &parserEntryPoint;
    c.makecontext(&co.uctx, entry, 0);
}

test "debug-allocator stack capture on the coroutine survives a PROT_NONE page above the stack" {
    if (comptime is_freestanding or builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const page = std.heap.page_size_min;
    const stack_size: usize = 1 << 20;
    const total = stack_size + page;
    const region = try std.posix.mmap(
        null,
        total,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(region);

    // Model the hostile layout behind the recorded field crashes: the leading PROT_NONE guard
    // page of an adjacently-mapped coroutine stack sits directly above this stack's top, which is
    // where the makecontext trampoline frame points. Every allocation below parses under the
    // testing debug allocator, whose stack capture walks the frame chain; an unterminated chain
    // reads that page and dies with SIGBUS.
    try std.posix.mprotect(@alignCast(region[stack_size..total]), std.posix.PROT.NONE);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var co = ParserCoroutine{
        .stack_mem = @alignCast(region[0..stack_size]),
        .allocator = arena.allocator(),
        .ctx = null,
        .initial_input = "first-word second-word: 42",
    };
    initCoroutineContext(&co);
    pending_entry_coroutine = &co;
    co.@"resume"();

    try std.testing.expectEqual(Status.completed, co.status);
    try std.testing.expect(co.result.? == .success);
}
