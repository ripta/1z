const std = @import("std");
const builtin = @import("builtin");

// This root is only ever selected as capi_root for a genuine wasm32-freestanding build
// (build.zig's resolveBuildTarget); is_freestanding is true there.
//
// It is also compiled and run natively for `capi-test` so its logic gets a real test run, not
// just a cross-compile check. That host-test path uses its own per-call GeneralPurposeAllocator
// (see acquireRootAllocator) rather than std.heap.wasm_allocator, which only compiles for a wasm
// target, so it gets real leak diagnostics per test case instead of sharing one long-lived
// allocator across the whole binary.
const is_freestanding = builtin.os.tag == .freestanding;

const context_mod = @import("context.zig");
const Context = context_mod.Context;

const statement_mod = @import("statement.zig");
const StatementProcessor = statement_mod.StatementProcessor;

const capi_core = @import("capi_core.zig");

const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Stream = value_mod.Stream;
const StreamVTable = value_mod.StreamVTable;
const container_backing = @import("container_backing.zig");

const dictionary_mod = @import("dictionary.zig");
const HostCallbackFn = dictionary_mod.HostCallbackFn;
const StackEffect = @import("stack_effect.zig").StackEffect;

const helpers = @import("primitives/helpers.zig");

// The wasm build is always freestanding, so this root gives the linker no OS entry point and no
// stdio-backed panic handler to call into.
pub const panic = std.debug.no_panic;

// Error code constants, mirroring capi.zig's so a host familiar with the hosted embedding API
// reads the same values here.
pub const ONEZ_OK: c_int = 0;
pub const ONEZ_ERR_NULL_HANDLE: c_int = -1;
pub const ONEZ_ERR_NULL_VALUE: c_int = -2;
pub const ONEZ_ERR_TYPE_MISMATCH: c_int = 1;
pub const ONEZ_ERR_STACK_UNDERFLOW: c_int = 2;
pub const ONEZ_ERR_ALLOC: c_int = 3;
pub const ONEZ_ERR_INDEX_OUT_OF_RANGE: c_int = 4;
pub const ONEZ_ERR_KEY_NOT_FOUND: c_int = 5;
pub const ONEZ_ERR_NOT_HOST_WORD: c_int = 7;
pub const ONEZ_ERR_INVALID_EFFECT: c_int = 8;

// Three-way status for `onez_wasm_eval`. The host accumulates its own source buffer and re-sends
// the whole thing on every call; it grows the buffer further only on ONEZ_EVAL_NEEDS_MORE_INPUT.
pub const ONEZ_EVAL_COMPLETE: c_int = 0;
pub const ONEZ_EVAL_NEEDS_MORE_INPUT: c_int = 1;
pub const ONEZ_EVAL_ERROR: c_int = 2;

/// Host-supplied output sink: the host writes `len` bytes starting at `data` wherever it likes
/// (a browser console, a DOM node, ...) and returns the number of bytes it accepted.
pub const WriterFn = *const fn (writer_ctx: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) usize;

/// Host-provided output sink, resolved by the browser's `WebAssembly.instantiate()` import object.
extern "env" fn onez_host_write_output(data: [*]const u8, len: usize) void;

/// Trampoline satisfying `WriterFn` by forwarding to the host import. Guarded on `is_freestanding`
/// since this file also compiles natively for `capi-test`, where no "env" host exists to resolve
/// the extern against at link time; the comptime-known guard means the native build never emits
/// a reference to it.
fn hostOutputWrite(_: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) usize {
    if (is_freestanding) onez_host_write_output(data, len);
    return len;
}

const output_parameter_name = "output-stream";

fn outputUnsupportedRead(_: *Stream, _: []u8, _: *Context) anyerror!usize {
    return error.NotOpenForReading;
}

fn outputWrite(stream: *Stream, bytes: []const u8, _: *Context) anyerror!usize {
    const handle: *OnezHandle = @ptrCast(@alignCast(stream.impl orelse return error.NotOpenForWriting));
    const writer = handle.output_writer orelse return error.NotOpenForWriting;
    return writer(handle.output_writer_ctx, bytes.ptr, bytes.len);
}

fn outputClose(stream: *Stream) void {
    stream.closed = true;
}

fn outputFlush(_: *Stream) anyerror!void {}

const output_vtable = StreamVTable{
    .read = outputUnsupportedRead,
    .write = outputWrite,
    .close = outputClose,
    .flush = outputFlush,
};

const HostWordRegistration = struct {
    name: []const u8,
};

const OnezHandle = struct {
    allocator: std.mem.Allocator,
    /// Non-null only on the host-test path, where the GPA is a heap-allocated stateful object
    /// that `onez_deinit` leak-checks and frees. The real wasm target's `std.heap.wasm_allocator`
    /// carries no such object.
    gpa: ?*HostGpa,
    ctx: *Context,
    last_error: ?[:0]const u8 = null,
    host_words: std.ArrayListUnmanaged(HostWordRegistration) = .{},
    popped_values: std.ArrayListUnmanaged(*Value) = .{},

    output_writer_ctx: ?*anyopaque = null,
    output_writer: ?WriterFn = null,
    output_stream: Stream = .{
        .vtable = &output_vtable,
        .fd = -1,
        .mode = .write,
        .name = output_parameter_name,
    },

    /// Borrowed byte-array view over `framebuffer_buf`, constructed once at `onez_init` and
    /// reused on every `(wasm-framebuffer)` call so repeated calls don't leak one small wrapper
    /// allocation per call into the arena.
    framebuffer_ba: ?*value_mod.ByteArray = null,

    /// Borrowed byte-array view over `keyboard_buf`, constructed once at `onez_init` and
    /// reused on every `(wasm-keyboard)` call so repeated calls don't leak one small wrapper
    /// allocation per call into the arena.
    keyboard_ba: ?*value_mod.ByteArray = null,

    /// Borrowed byte-array view over `mouse_buf`, constructed once at `onez_init` and reused
    /// on every `(wasm-mouse)` call, for the same reason as `keyboard_ba`.
    mouse_ba: ?*value_mod.ByteArray = null,
};

// wasm32-freestanding has no OS heap, but it does have `std.heap.wasm_allocator`: a real
// size-class free-list allocator built into Zig for exactly this target, growing the module's
// linear memory via `@wasmMemoryGrow` on demand instead of a fixed-size static region. Its `free`
// returns a block to its size class's free list for reuse by any later allocation, unlike
// `FixedBufferAllocator`, whose `free` is a silent no-op unless the freed block happens to be the
// most recent allocation. The interpreter's per-call module-deps-frame clone
// (`Context.pushModuleDepsFrame`) allocates and frees a same-sized block on every call to a
// module-defined word; that pattern is net-zero growth under a real free list but was an
// unrecoverable per-call leak under the fixed-buffer allocator.
//
// The host-test path uses a fresh GeneralPurposeAllocator per onez_init call instead, mirroring
// capi.zig's own hosted RootAllocator: a long-lived static allocator shared across every test case
// in the binary would need to outlive individual onez_deinit calls to get leak diagnostics.
const HostGpa = std.heap.GeneralPurposeAllocator(.{});

const RootAllocator = struct {
    allocator: std.mem.Allocator,
    gpa: ?*HostGpa,
};

fn acquireRootAllocator() ?RootAllocator {
    if (is_freestanding) {
        return .{ .allocator = std.heap.wasm_allocator, .gpa = null };
    }
    const gpa = std.heap.page_allocator.create(HostGpa) catch return null;
    gpa.* = .{};
    return .{ .allocator = gpa.allocator(), .gpa = gpa };
}

fn castHandle(ptr: ?*anyopaque) ?*OnezHandle {
    const p = ptr orelse return null;
    return @ptrCast(@alignCast(p));
}

fn clearLastError(handle: *OnezHandle) void {
    if (handle.last_error) |msg| {
        handle.allocator.free(@as([]const u8, msg.ptr[0 .. msg.len + 1]));
        handle.last_error = null;
    }
}

fn setLastError(handle: *OnezHandle, comptime fmt: []const u8, args: anytype) void {
    clearLastError(handle);
    handle.last_error = capi_core.allocPrintZ(handle.allocator, fmt, args) catch null;
}

fn captureError(handle: *OnezHandle, err: anyerror) void {
    clearLastError(handle);
    handle.last_error = capi_core.formatCapturedError(handle.ctx, handle.allocator, err);
}

/// Create the interpreter and load the embedded prelude. Returns null on failure.
export fn onez_init() ?*anyopaque {
    const root = acquireRootAllocator() orelse return null;
    const alloc = root.allocator;

    const ctx = alloc.create(Context) catch return null;
    ctx.* = Context.init(alloc);
    ctx.loadPrelude(null) catch {
        ctx.deinit();
        return null;
    };

    const handle = alloc.create(OnezHandle) catch {
        ctx.deinit();
        return null;
    };
    handle.* = .{ .allocator = alloc, .gpa = root.gpa, .ctx = ctx };
    handle.output_stream.impl = handle;

    const present_frame_effect = helpers.makeBoxedEffect(ctx.quotationAllocator(), "--") catch {
        onez_deinit(handle);
        return null;
    };
    capi_core.defineHostWord(ctx, "present-frame", present_frame_effect, presentFrameCallback, null, null) catch {
        onez_deinit(handle);
        return null;
    };

    handle.framebuffer_ba = value_mod.makeBorrowedByteArray(ctx.quotationAllocator(), &framebuffer_buf) catch {
        onez_deinit(handle);
        return null;
    };
    const framebuffer_bytes_effect = helpers.makeBoxedEffect(ctx.quotationAllocator(), "-- byte-array") catch {
        onez_deinit(handle);
        return null;
    };
    capi_core.defineHostWord(ctx, "(wasm-framebuffer)", framebuffer_bytes_effect, framebufferBytesCallback, handle, null) catch {
        onez_deinit(handle);
        return null;
    };

    handle.keyboard_ba = value_mod.makeBorrowedByteArray(ctx.quotationAllocator(), &keyboard_buf) catch {
        onez_deinit(handle);
        return null;
    };
    const keyboard_bytes_effect = helpers.makeBoxedEffect(ctx.quotationAllocator(), "-- byte-array") catch {
        onez_deinit(handle);
        return null;
    };
    capi_core.defineHostWord(ctx, "(wasm-keyboard)", keyboard_bytes_effect, keyboardBytesCallback, handle, null) catch {
        onez_deinit(handle);
        return null;
    };

    handle.mouse_ba = value_mod.makeBorrowedByteArray(ctx.quotationAllocator(), &mouse_buf) catch {
        onez_deinit(handle);
        return null;
    };
    const mouse_bytes_effect = helpers.makeBoxedEffect(ctx.quotationAllocator(), "-- byte-array") catch {
        onez_deinit(handle);
        return null;
    };
    capi_core.defineHostWord(ctx, "(wasm-mouse)", mouse_bytes_effect, mouseBytesCallback, handle, null) catch {
        onez_deinit(handle);
        return null;
    };

    // Every effect below is a bare list of parameter names. `makeSimpleEffect` reads a trailing
    // colon as the start of a quotation annotation, not a type annotation, so writing
    // `channels: fixnum` would parse as two separate parameters and inflate the arity. The
    // callbacks type-check their own inputs instead.
    const load_sample_effect = helpers.makeBoxedEffect(ctx.quotationAllocator(), "bytes channels rate -- handle") catch {
        onez_deinit(handle);
        return null;
    };
    capi_core.defineHostWord(ctx, "(wasm-load-sample)", load_sample_effect, loadSampleCallback, handle, null) catch {
        onez_deinit(handle);
        return null;
    };

    const play_sample_effect = helpers.makeBoxedEffect(ctx.quotationAllocator(), "handle --") catch {
        onez_deinit(handle);
        return null;
    };
    capi_core.defineHostWord(ctx, "(wasm-play-sample)", play_sample_effect, playSampleCallback, handle, null) catch {
        onez_deinit(handle);
        return null;
    };

    return handle;
}

/// Tear down the interpreter. On the real wasm target the ctx/handle allocations themselves are
/// never explicitly freed -- the module either keeps running or the page unloads it -- so this
/// only releases owning references that would otherwise report as leaked, matching the
/// freestanding precedent in capi.zig.
///
/// The host-test path actually frees: each `onez_init` call there got its own heap-allocated GPA
/// (`acquireRootAllocator`), so `.deinit()` here gives that one test case's leak diagnostics
/// rather than accumulating state across every test in the binary.
export fn onez_deinit(ptr: ?*anyopaque) void {
    const handle = castHandle(ptr) orelse return;
    const alloc = handle.allocator;

    clearLastError(handle);

    for (handle.host_words.items) |entry| alloc.free(entry.name);
    handle.host_words.deinit(alloc);

    for (handle.popped_values.items) |slot| {
        container_backing.releaseValue(slot.*);
    }
    handle.popped_values.deinit(alloc);

    handle.ctx.deinit();
    if (is_freestanding) return;
    alloc.destroy(handle.ctx);
    const gpa = handle.gpa;
    alloc.destroy(handle);
    if (gpa) |g| {
        _ = g.deinit();
        std.heap.page_allocator.destroy(g);
    }
}

export fn onez_last_error(ptr: ?*anyopaque) ?[*:0]const u8 {
    const handle = castHandle(ptr) orelse return null;
    if (handle.last_error) |err| return err.ptr else return null;
}

/// Bind a host writer as the interpreter's default output stream, so `print`/`output-stream get`
/// resolve to it instead of evaluating the prelude's `[ stdout ]` default. Callable again later
/// to rebind to a different writer.
///
/// Uses the interpreter's existing dynamic-scope Parameter mechanism
/// (`Context.setParameterInTopFrame`), not an AOT slot-table trick -- this root runs a real
/// interpreter, not a metadata-only image.
export fn onez_wasm_init_output(ptr: ?*anyopaque, writer_ctx: ?*anyopaque, writer: ?WriterFn) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const write_fn = writer orelse {
        setLastError(handle, "output writer is required", .{});
        return ONEZ_ERR_NULL_VALUE;
    };

    handle.output_writer_ctx = writer_ctx;
    handle.output_writer = write_fn;
    handle.output_stream.impl = handle;
    handle.output_stream.closed = false;

    handle.ctx.setParameterInTopFrame(output_parameter_name, .{ .stream = &handle.output_stream }) catch {
        setLastError(handle, "allocation failure binding output-stream parameter", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

/// Convenience wrapper for the browser host: binds the static `onez_host_write_output` import as
/// the output writer, so JS never has to construct a wasm-callable function pointer of its own.
export fn onez_wasm_use_host_output(ptr: ?*anyopaque) c_int {
    return onez_wasm_init_output(ptr, null, hostOutputWrite);
}

/// Parse and, if complete, execute one chunk of host-fed source. The host owns accumulation: on
/// ONEZ_EVAL_NEEDS_MORE_INPUT it grows its buffer and calls again with the whole thing; on
/// ONEZ_EVAL_COMPLETE or ONEZ_EVAL_ERROR it starts a fresh buffer for the next statement. A fresh
/// StatementProcessor is used per call and the buffer is reparsed from scratch each time, so no
/// state carries between calls and no `flush()` is ever needed -- "no more input is coming" is
/// never a valid assumption for a live REPL session.
///
/// On the real wasm32-freestanding target, StatementProcessor.feedLine takes its coroutine-free
/// `tryParseDirect` path (`comptime is_freestanding`), which this contract is designed around. The
/// `capi-test` build of this file runs on the host target instead, so its own tests exercise the
/// ordinary coroutine path here -- the same three-way Result contract, but not tryParseDirect
/// itself; that path is compile-checked only, via `wasm-freestanding-build`, since no wasm runtime
/// exists in this repo's test setup to execute it.
export fn onez_wasm_eval(ptr: ?*anyopaque, code: [*]const u8, len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const ctx = handle.ctx;
    const alloc = ctx.quotationAllocator();

    ctx.clearExecutionDetails();
    clearLastError(handle);

    const old_source = ctx.current_source;
    ctx.current_source = "<eval>";
    defer ctx.current_source = old_source;

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    return switch (capi_core.evalStep(ctx, &processor, alloc, code[0..len])) {
        .needs_more_input => ONEZ_EVAL_NEEDS_MORE_INPUT,
        .parse_error, .exec_error => |err| blk: {
            captureError(handle, err);
            break :blk ONEZ_EVAL_ERROR;
        },
        .complete => ONEZ_EVAL_COMPLETE,
    };
}

// Staging buffer for onez_wasm_eval's code/len args.
//
// JS has no pointer of its own to write source bytes into, so it queries this once and reuses it.
// Static rather than alloc/free, so JS can cache the pointer for the module's whole lifetime
// instead of re-querying it before every eval call.
const eval_input_capacity: usize = 65536;
var eval_input_buf: [eval_input_capacity]u8 = undefined;

export fn onez_wasm_input_ptr() [*]u8 {
    return &eval_input_buf;
}

export fn onez_wasm_input_capacity() usize {
    return eval_input_capacity;
}

// =============================================================================
// Framebuffer presentation
// =============================================================================

/// Host-provided buffer is ready signal.
///
/// Resolved by the browser's `WebAssembly.instantiate()` import object. Takes no arguments and
/// returns nothing.
///
/// Pixel data is never marshalled through call arguments, since JS reads it directly out of wasm
/// linear memory at the cached framebuffer pointer.
extern "env" fn onez_host_present() void;

/// `present-frame`'s host_callback body.
///
/// Guarded on `is_freestanding`, since this file also compiles natively for `capi-test`, where no
/// env host exists to resolve the extern against at link time.
fn presentFrameCallback(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    if (is_freestanding) onez_host_present();
    return 0;
}

// The game platform's framebufferi, which s a single 1z-owned static RGBA8888 buffer in wasm linear
// memory, row-major, top-left origin, and y-down.
//
// JS queries its pointer and length once via the exported getters below and caches them.
//
// There is no double buffering. The synchronous single-threaded wasm call model guarantees `draw`
// always completes before control returns to JS.
const framebuffer_width: usize = 256;
const framebuffer_height: usize = 224;
const framebuffer_bytes_per_pixel: usize = 4;
const framebuffer_len: usize = framebuffer_width * framebuffer_height * framebuffer_bytes_per_pixel;
var framebuffer_buf: [framebuffer_len]u8 = [_]u8{0} ** framebuffer_len;

export fn onez_wasm_framebuffer_ptr() [*]u8 {
    return &framebuffer_buf;
}

export fn onez_wasm_framebuffer_len() usize {
    return framebuffer_len;
}

/// The host callback body for `(wasm-framebuffer)`.
///
/// Pushes the cached borrowed byte-array view over `framebuffer_buf`. `Stack.push` retains on
/// every call. Repeated calls correctly share one underlying buffer instead of allocating a
/// new wrapper each time.
fn framebufferBytesCallback(handle_ptr: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const handle = castHandle(handle_ptr) orelse return 1;
    const ba = handle.framebuffer_ba orelse return 1;
    handle.ctx.stack.push(.{ .byte_array = ba }) catch {
        setLastError(handle, "allocation failure pushing framebuffer byte-array", .{});
        return 1;
    };
    return 0;
}

// =============================================================================
// Keyboard input
// =============================================================================

// One byte per tracked key: 0 is up, nonzero is down. JS's keydown/keyup listeners write
// directly into this buffer at a fixed-offset index, so there is no host call in either
// direction -- 1z reads it as a local memory read, the same as the framebuffer. The key-name-
// to-index mapping is not known here; it is a private contract between lib/game/input.1z and
// the JS host harness (see lib/game/input.1z's key-index table).
const keyboard_key_count: usize = 48;
var keyboard_buf: [keyboard_key_count]u8 = [_]u8{0} ** keyboard_key_count;

export fn onez_wasm_keyboard_ptr() [*]u8 {
    return &keyboard_buf;
}

export fn onez_wasm_keyboard_len() usize {
    return keyboard_key_count;
}

/// The host callback body for `(wasm-keyboard)`.
///
/// Pushes the cached borrowed byte-array view over `keyboard_buf`. `Stack.push` retains on
/// every call. Repeated calls correctly share one underlying buffer instead of allocating a
/// new wrapper each time.
fn keyboardBytesCallback(handle_ptr: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const handle = castHandle(handle_ptr) orelse return 1;
    const ba = handle.keyboard_ba orelse return 1;
    handle.ctx.stack.push(.{ .byte_array = ba }) catch {
        setLastError(handle, "allocation failure pushing keyboard byte-array", .{});
        return 1;
    };
    return 0;
}

// =============================================================================
// Mouse input
// =============================================================================

// Pointer state and button events share one buffer: a fixed header holding the pointer
// position, an inside-canvas flag, a held-button bitmap, and the ring's two indices, followed
// by a ring of fixed-size event slots. JS's pointer listeners write the header and append to
// the ring; 1z drains the ring once per update tick and advances the read index. As with the
// keyboard, there is no host call in either direction, and the byte layout is not known here:
// it is a private contract between lib/game/input.1z and the JS host harness. This file only
// sizes the buffer.
const mouse_header_len: usize = 16;
const mouse_ring_capacity: usize = 32;
const mouse_event_len: usize = 8;
const mouse_buf_len: usize = mouse_header_len + mouse_ring_capacity * mouse_event_len;
var mouse_buf: [mouse_buf_len]u8 = [_]u8{0} ** mouse_buf_len;

export fn onez_wasm_mouse_ptr() [*]u8 {
    return &mouse_buf;
}

export fn onez_wasm_mouse_len() usize {
    return mouse_buf_len;
}

/// The host callback body for `(wasm-mouse)`.
///
/// Pushes the cached borrowed byte-array view over `mouse_buf`, so repeated calls share one
/// underlying buffer, as `keyboardBytesCallback` does.
fn mouseBytesCallback(handle_ptr: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const handle = castHandle(handle_ptr) orelse return 1;
    const ba = handle.mouse_ba orelse return 1;
    handle.ctx.stack.push(.{ .byte_array = ba }) catch {
        setLastError(handle, "allocation failure pushing mouse byte-array", .{});
        return 1;
    };
    return 0;
}

// =============================================================================
// Audio
// =============================================================================

/// Host-provided sample load.
///
/// `data`/`len` address interleaved 32-bit float PCM in wasm linear memory, which the host reads
/// synchronously and copies into an audio buffer of its own. Nothing in the path waits on a host
/// completion, so no task ever parks on a wake the wasm tier cannot deliver.
///
/// Returns a nonnegative opaque handle, or a negative value if the host rejected the sample.
extern "env" fn onez_host_load_sample(data: [*]const u8, len: usize, channels: u32, rate: u32) i32;

/// Host-provided one-shot trigger for a previously loaded sample.
///
/// A handle the host does not recognize is the host's to ignore.
extern "env" fn onez_host_play_sample(handle: i32) void;

/// The host callback body for `(wasm-load-sample)`.
///
/// The three inputs are peeked and type-checked before anything is consumed, so a rejected call
/// leaves the stack exactly as it found it. The byte array's bytes are handed to the host while
/// the stack still owns them; only once the host has copied them do the inputs get released.
///
/// Guarded on `is_freestanding`, since this file also compiles natively for `capi-test`, where no
/// env host exists to resolve the extern against at link time. The native path reports handle 0.
fn loadSampleCallback(handle_ptr: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const handle = castHandle(handle_ptr) orelse return 1;
    const stack = &handle.ctx.stack;

    if (stack.depth() < 3) {
        setLastError(handle, "(wasm-load-sample) requires three inputs", .{});
        return 1;
    }
    const rate_val = stack.peekN(0) catch return 1;
    const channels_val = stack.peekN(1) catch return 1;
    const bytes_val = stack.peekN(2) catch return 1;

    if (bytes_val != .byte_array) {
        setLastError(handle, "(wasm-load-sample) requires a byte-array of PCM data, got {s}", .{@tagName(bytes_val)});
        return 1;
    }
    const channels = loadSampleCount(handle, channels_val, "channels") orelse return 1;
    const rate = loadSampleCount(handle, rate_val, "rate") orelse return 1;

    const bytes = bytes_val.byte_array.items;
    var id: i32 = 0;
    if (is_freestanding) id = onez_host_load_sample(bytes.ptr, bytes.len, channels, rate);
    if (id < 0) {
        setLastError(handle, "the host rejected the sample", .{});
        return 1;
    }

    for (0..3) |_| {
        stack.popAndRelease() catch return 1;
    }
    stack.push(.{ .fixnum = id }) catch {
        setLastError(handle, "allocation failure pushing the sample handle", .{});
        return 1;
    };
    return 0;
}

/// Read one of `(wasm-load-sample)`'s two counts, which has to survive the trip through a `u32`
/// host parameter. Returns null after recording why, so the caller can bail on the spot.
fn loadSampleCount(handle: *OnezHandle, val: Value, name: []const u8) ?u32 {
    if (val != .fixnum) {
        setLastError(handle, "(wasm-load-sample) requires a fixnum {s}, got {s}", .{ name, @tagName(val) });
        return null;
    }
    if (val.fixnum <= 0 or val.fixnum > std.math.maxInt(u32)) {
        setLastError(handle, "(wasm-load-sample) requires a positive {s} that fits 32 bits", .{name});
        return null;
    }
    return @intCast(val.fixnum);
}

/// The host callback body for `(wasm-play-sample)`.
///
/// Guarded on `is_freestanding`, since this file also compiles natively for `capi-test`, where no
/// env host exists to resolve the extern against at link time.
fn playSampleCallback(handle_ptr: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const handle = castHandle(handle_ptr) orelse return 1;
    const stack = &handle.ctx.stack;

    const val = stack.peek() catch {
        setLastError(handle, "(wasm-play-sample) requires a sample handle", .{});
        return 1;
    };
    if (val != .fixnum) {
        setLastError(handle, "(wasm-play-sample) requires a fixnum handle, got {s}", .{@tagName(val)});
        return 1;
    }
    if (val.fixnum < std.math.minInt(i32) or val.fixnum > std.math.maxInt(i32)) {
        setLastError(handle, "(wasm-play-sample) requires a handle that fits 32 bits", .{});
        return 1;
    }
    const id: i32 = @intCast(val.fixnum);

    stack.popAndRelease() catch return 1;
    if (is_freestanding) onez_host_play_sample(id);
    return 0;
}

export fn onez_push_int(ptr: ?*anyopaque, value: i64) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    capi_core.pushInt(handle.ctx, value) catch {
        setLastError(handle, "allocation failure pushing int", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_push_double(ptr: ?*anyopaque, value: f64) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    capi_core.pushDouble(handle.ctx, value) catch {
        setLastError(handle, "allocation failure pushing double", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_push_bool(ptr: ?*anyopaque, value: bool) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    capi_core.pushBool(handle.ctx, value) catch {
        setLastError(handle, "allocation failure pushing bool", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_push_string(ptr: ?*anyopaque, data: [*]const u8, len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    capi_core.pushString(handle.ctx, data[0..len]) catch {
        setLastError(handle, "allocation failure pushing string", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_push_symbol(ptr: ?*anyopaque, data: [*]const u8, len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    capi_core.pushSymbol(handle.ctx, data[0..len]) catch {
        setLastError(handle, "allocation failure pushing symbol", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_pop_int(ptr: ?*anyopaque, out: *i64) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    var mismatched: Value = undefined;
    out.* = capi_core.popInt(handle.ctx, &mismatched) catch |err| switch (err) {
        error.TypeMismatch => {
            setLastError(handle, "type mismatch: expected fixnum, got {s}", .{@tagName(mismatched)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
        else => {
            setLastError(handle, "stack underflow: cannot pop int from empty stack", .{});
            return ONEZ_ERR_STACK_UNDERFLOW;
        },
    };
    return ONEZ_OK;
}

export fn onez_pop_double(ptr: ?*anyopaque, out: *f64) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    var mismatched: Value = undefined;
    out.* = capi_core.popDouble(handle.ctx, &mismatched) catch |err| switch (err) {
        error.TypeMismatch => {
            setLastError(handle, "type mismatch: expected float, got {s}", .{@tagName(mismatched)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
        else => {
            setLastError(handle, "stack underflow: cannot pop double from empty stack", .{});
            return ONEZ_ERR_STACK_UNDERFLOW;
        },
    };
    return ONEZ_OK;
}

export fn onez_pop_bool(ptr: ?*anyopaque, out: *bool) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    var mismatched: Value = undefined;
    out.* = capi_core.popBool(handle.ctx, &mismatched) catch |err| switch (err) {
        error.TypeMismatch => {
            setLastError(handle, "type mismatch: expected boolean, got {s}", .{@tagName(mismatched)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
        else => {
            setLastError(handle, "stack underflow: cannot pop bool from empty stack", .{});
            return ONEZ_ERR_STACK_UNDERFLOW;
        },
    };
    return ONEZ_OK;
}

export fn onez_pop_string(ptr: ?*anyopaque, out_ptr: *[*]const u8, out_len: *usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    var mismatched: Value = undefined;
    const s = capi_core.popString(handle.ctx, &mismatched) catch |err| switch (err) {
        error.TypeMismatch => {
            setLastError(handle, "type mismatch: expected string, got {s}", .{@tagName(mismatched)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
        else => {
            setLastError(handle, "stack underflow: cannot pop string from empty stack", .{});
            return ONEZ_ERR_STACK_UNDERFLOW;
        },
    };
    out_ptr.* = s.ptr;
    out_len.* = s.len;
    return ONEZ_OK;
}

export fn onez_pop_value(ptr: ?*anyopaque, out: *?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const slot = capi_core.popValueBoxed(handle.ctx) catch |err| switch (err) {
        error.StackUnderflow => {
            setLastError(handle, "stack underflow: cannot pop value from empty stack", .{});
            return ONEZ_ERR_STACK_UNDERFLOW;
        },
        else => {
            setLastError(handle, "allocation failure creating value handle", .{});
            return ONEZ_ERR_ALLOC;
        },
    };
    handle.popped_values.append(handle.allocator, slot) catch {
        handle.ctx.stack.pushMoved(slot.*) catch {};
        setLastError(handle, "allocation failure tracking value handle", .{});
        return ONEZ_ERR_ALLOC;
    };
    out.* = slot;
    return ONEZ_OK;
}

export fn onez_push_value(ptr: ?*anyopaque, val_ptr: ?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const vp = val_ptr orelse {
        setLastError(handle, "null value handle passed to onez_push_value", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const value: *const Value = @ptrCast(@alignCast(vp));
    capi_core.pushBoxedValue(handle.ctx, value) catch {
        setLastError(handle, "allocation failure pushing value", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_value_type(val_ptr: ?*anyopaque) c_int {
    const vp = val_ptr orelse return capi_core.ONEZ_TYPE_UNKNOWN;
    const value: *const Value = @ptrCast(@alignCast(vp));
    return capi_core.valueTypeToInt(value.*);
}

export fn onez_stack_depth(ptr: ?*anyopaque) usize {
    const handle = castHandle(ptr) orelse return 0;
    return handle.ctx.stack.depth();
}

export fn onez_stack_type(ptr: ?*anyopaque, index: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.peekN(index) catch return ONEZ_ERR_NULL_HANDLE;
    return capi_core.valueTypeToInt(val);
}

/// Non-destructive read of the value at stack position `index` (0 = top).
export fn onez_stack_peek(ptr: ?*anyopaque, index: usize, out: *?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const slot = capi_core.peekBoxed(handle.ctx, index) catch |err| switch (err) {
        error.StackUnderflow => return ONEZ_ERR_INDEX_OUT_OF_RANGE,
        else => return ONEZ_ERR_ALLOC,
    };
    out.* = slot;
    return ONEZ_OK;
}

/// Strip optional surrounding parentheses and whitespace from an effect string.
fn stripEffectParens(raw: []const u8) []const u8 {
    var s = std.mem.trim(u8, raw, " \t");
    if (s.len >= 2 and s[0] == '(' and s[s.len - 1] == ')') {
        s = std.mem.trim(u8, s[1 .. s.len - 1], " \t");
    }
    return s;
}

export fn onez_register_word(ptr: ?*anyopaque, name: ?[*:0]const u8, callback: ?HostCallbackFn, user_data: ?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    clearLastError(handle);
    handle.ctx.clearExecutionDetails();

    const name_ptr = name orelse {
        setLastError(handle, "null name passed to onez_register_word", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const callback_fn = callback orelse {
        setLastError(handle, "null callback passed to onez_register_word", .{});
        return ONEZ_ERR_NULL_VALUE;
    };

    const name_slice = std.mem.span(name_ptr);
    if (name_slice.len == 0) {
        setLastError(handle, "empty name passed to onez_register_word", .{});
        return ONEZ_ERR_TYPE_MISMATCH;
    }

    const name_copy = handle.allocator.dupe(u8, name_slice) catch {
        setLastError(handle, "allocation failure copying word name", .{});
        return ONEZ_ERR_ALLOC;
    };
    errdefer handle.allocator.free(name_copy);

    handle.host_words.append(handle.allocator, .{ .name = name_copy }) catch {
        setLastError(handle, "allocation failure tracking host word", .{});
        return ONEZ_ERR_ALLOC;
    };
    errdefer _ = handle.host_words.pop();

    capi_core.defineHostWord(handle.ctx, name_copy, null, callback_fn, ptr, user_data) catch |err| {
        if (handle.ctx.pending_error_message) |msg| {
            setLastError(handle, "{s}", .{msg});
        } else {
            captureError(handle, err);
        }
        return 1;
    };

    return ONEZ_OK;
}

export fn onez_register_word_with_effect(
    ptr: ?*anyopaque,
    name: ?[*:0]const u8,
    effect_str: ?[*:0]const u8,
    callback: ?HostCallbackFn,
    user_data: ?*anyopaque,
) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    clearLastError(handle);
    handle.ctx.clearExecutionDetails();

    const name_ptr = name orelse {
        setLastError(handle, "null name passed to onez_register_word_with_effect", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const callback_fn = callback orelse {
        setLastError(handle, "null callback passed to onez_register_word_with_effect", .{});
        return ONEZ_ERR_NULL_VALUE;
    };

    const name_slice = std.mem.span(name_ptr);
    if (name_slice.len == 0) {
        setLastError(handle, "empty name passed to onez_register_word_with_effect", .{});
        return ONEZ_ERR_TYPE_MISMATCH;
    }

    const parsed_effect: ?*const StackEffect = if (effect_str) |eptr| blk: {
        const raw = std.mem.span(eptr);
        if (raw.len == 0) break :blk null;
        const stripped = stripEffectParens(raw);
        if (std.mem.indexOf(u8, stripped, "--") == null) {
            setLastError(handle, "stack effect string must contain '--'", .{});
            return ONEZ_ERR_INVALID_EFFECT;
        }
        break :blk helpers.makeBoxedEffect(handle.ctx.quotationAllocator(), stripped) catch {
            setLastError(handle, "invalid stack effect string", .{});
            return ONEZ_ERR_INVALID_EFFECT;
        };
    } else null;

    const name_copy = handle.allocator.dupe(u8, name_slice) catch {
        setLastError(handle, "allocation failure copying word name", .{});
        return ONEZ_ERR_ALLOC;
    };
    errdefer handle.allocator.free(name_copy);

    handle.host_words.append(handle.allocator, .{ .name = name_copy }) catch {
        setLastError(handle, "allocation failure tracking host word", .{});
        return ONEZ_ERR_ALLOC;
    };
    errdefer _ = handle.host_words.pop();

    capi_core.defineHostWord(handle.ctx, name_copy, parsed_effect, callback_fn, ptr, user_data) catch |err| {
        if (handle.ctx.pending_error_message) |msg| {
            setLastError(handle, "{s}", .{msg});
        } else {
            captureError(handle, err);
        }
        return 1;
    };

    return ONEZ_OK;
}

/// Remove a previously registered host word from the dictionary.
export fn onez_unregister_word(ptr: ?*anyopaque, name: ?[*:0]const u8) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    clearLastError(handle);
    handle.ctx.clearExecutionDetails();

    const name_ptr = name orelse {
        setLastError(handle, "null name passed to onez_unregister_word", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const name_slice = std.mem.span(name_ptr);

    const definition = handle.ctx.lookupWord(name_slice) orelse {
        setLastError(handle, "word '{s}' not found", .{name_slice});
        return ONEZ_ERR_KEY_NOT_FOUND;
    };

    switch (definition.action) {
        .host_callback => {},
        else => {
            setLastError(handle, "word '{s}' is not a host callback", .{name_slice});
            return ONEZ_ERR_NOT_HOST_WORD;
        },
    }

    if (!handle.ctx.removeWord(name_slice)) {
        setLastError(handle, "word '{s}' could not be removed", .{name_slice});
        return ONEZ_ERR_KEY_NOT_FOUND;
    }

    for (handle.host_words.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, name_slice)) {
            handle.allocator.free(entry.name);
            _ = handle.host_words.swapRemove(i);
            break;
        }
    }

    return ONEZ_OK;
}

// =============================================================================
// Tests
// =============================================================================

test "init/eval/deinit round trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_EVAL_COMPLETE, onez_wasm_eval(handle_ptr, "1 2 +", 5));
}

test "eval reports needs-more-input for an unterminated bracket" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const src = "[ 1 2 +";
    try std.testing.expectEqual(ONEZ_EVAL_NEEDS_MORE_INPUT, onez_wasm_eval(handle_ptr, src, src.len));
}

test "eval completes once the buffer is grown to a full statement" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const partial = "[ 1 2 +";
    try std.testing.expectEqual(ONEZ_EVAL_NEEDS_MORE_INPUT, onez_wasm_eval(handle_ptr, partial, partial.len));

    const whole = "[ 1 2 + ] call";
    try std.testing.expectEqual(ONEZ_EVAL_COMPLETE, onez_wasm_eval(handle_ptr, whole, whole.len));
}

test "eval reports an error for a genuine parse failure" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const src = "}";
    try std.testing.expectEqual(ONEZ_EVAL_ERROR, onez_wasm_eval(handle_ptr, src, src.len));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "output injection routes print through the host writer" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const Sink = struct {
        var buf: [256]u8 = undefined;
        var len: usize = 0;

        fn write(_: ?*anyopaque, data: [*]const u8, n: usize) callconv(.c) usize {
            @memcpy(buf[len .. len + n], data[0..n]);
            len += n;
            return n;
        }
    };
    Sink.len = 0;

    try std.testing.expectEqual(ONEZ_OK, onez_wasm_init_output(handle_ptr, null, Sink.write));

    const src = "\"hi\" print";
    try std.testing.expectEqual(ONEZ_EVAL_COMPLETE, onez_wasm_eval(handle_ptr, src, src.len));

    try std.testing.expectEqualStrings("hi", Sink.buf[0..Sink.len]);
}

// Only proves the wiring compiles and runs
test "onez_wasm_use_host_output wires the host import trampoline" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_wasm_use_host_output(handle_ptr));

    const src = "\"hi\" print";
    try std.testing.expectEqual(ONEZ_EVAL_COMPLETE, onez_wasm_eval(handle_ptr, src, src.len));
}

test "input buffer pointer and capacity round-trip through eval" {
    const ptr = onez_wasm_input_ptr();
    const capacity = onez_wasm_input_capacity();
    try std.testing.expectEqual(@as(usize, eval_input_capacity), capacity);

    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const src = "1 2 +";
    @memcpy(ptr[0..src.len], src);
    try std.testing.expectEqual(ONEZ_EVAL_COMPLETE, onez_wasm_eval(handle_ptr, ptr, src.len));

    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 3), out);
}

test "framebuffer pointer and length are exposed" {
    const ptr = onez_wasm_framebuffer_ptr();
    const len = onez_wasm_framebuffer_len();
    try std.testing.expectEqual(@as(usize, 256 * 224 * 4), len);
    try std.testing.expect(ptr[0..len].len == len);
}

test "present-frame fills the buffer and signals ready" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const ptr = onez_wasm_framebuffer_ptr();
    const len = onez_wasm_framebuffer_len();
    for (ptr[0..len], 0..) |*byte, i| byte.* = @truncate(i);

    // Only proves the wiring compiles and runs, and that present-frame does not touch the
    // buffer; real delivery to JS needs the actual wasm target, where JS supplies
    // "env".onez_host_present.
    const src = "present-frame";
    try std.testing.expectEqual(ONEZ_EVAL_COMPLETE, onez_wasm_eval(handle_ptr, src, src.len));

    for (ptr[0..len], 0..) |byte, i| {
        try std.testing.expectEqual(@as(u8, @truncate(i)), byte);
    }
}

test "(wasm-framebuffer) exposes a mutable byte-array view over framebuffer_buf" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const ptr = onez_wasm_framebuffer_ptr();
    @memset(ptr[0..onez_wasm_framebuffer_len()], 0);

    const src = "(wasm-framebuffer) 0 0x11223344 4 #poke!";
    try std.testing.expectEqual(ONEZ_EVAL_COMPLETE, onez_wasm_eval(handle_ptr, src, src.len));

    // #poke32! writes least-significant byte first: 0x44, 0x33, 0x22, 0x11.
    try std.testing.expectEqual(@as(u8, 0x44), ptr[0]);
    try std.testing.expectEqual(@as(u8, 0x33), ptr[1]);
    try std.testing.expectEqual(@as(u8, 0x22), ptr[2]);
    try std.testing.expectEqual(@as(u8, 0x11), ptr[3]);
}

test "(wasm-framebuffer) returns the same shared buffer across calls" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const src = "(wasm-framebuffer) 0 7 1 #poke! drop (wasm-framebuffer) 0 1 #peek";
    try std.testing.expectEqual(ONEZ_EVAL_COMPLETE, onez_wasm_eval(handle_ptr, src, src.len));

    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 7), out);
}

test "keyboard pointer and length are exposed" {
    const ptr = onez_wasm_keyboard_ptr();
    const len = onez_wasm_keyboard_len();
    try std.testing.expectEqual(@as(usize, 48), len);
    try std.testing.expect(ptr[0..len].len == len);
}

test "(wasm-keyboard) exposes a mutable byte-array view over keyboard_buf" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const ptr = onez_wasm_keyboard_ptr();
    @memset(ptr[0..onez_wasm_keyboard_len()], 0);

    const src = "(wasm-keyboard) 3 1 1 #poke!";
    try std.testing.expectEqual(ONEZ_EVAL_COMPLETE, onez_wasm_eval(handle_ptr, src, src.len));

    try std.testing.expectEqual(@as(u8, 1), ptr[3]);
}

test "(wasm-keyboard) returns the same shared buffer across calls" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const src = "(wasm-keyboard) 5 1 1 #poke! drop (wasm-keyboard) 5 1 #peek";
    try std.testing.expectEqual(ONEZ_EVAL_COMPLETE, onez_wasm_eval(handle_ptr, src, src.len));

    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 1), out);
}

test "mouse pointer and length are exposed" {
    const ptr = onez_wasm_mouse_ptr();
    const len = onez_wasm_mouse_len();
    try std.testing.expectEqual(@as(usize, 272), len);
    try std.testing.expect(ptr[0..len].len == len);
}

test "(wasm-mouse) exposes a mutable byte-array view over mouse_buf" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const ptr = onez_wasm_mouse_ptr();
    @memset(ptr[0..onez_wasm_mouse_len()], 0);

    // A 16-bit poke at the header's x field, little-endian: 0x34 then 0x12.
    const src = "(wasm-mouse) 0 0x1234 2 #poke!";
    try std.testing.expectEqual(ONEZ_EVAL_COMPLETE, onez_wasm_eval(handle_ptr, src, src.len));

    try std.testing.expectEqual(@as(u8, 0x34), ptr[0]);
    try std.testing.expectEqual(@as(u8, 0x12), ptr[1]);
}

test "(wasm-mouse) returns the same shared buffer across calls" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const src = "(wasm-mouse) 5 7 1 #poke! drop (wasm-mouse) 5 1 #peek";
    try std.testing.expectEqual(ONEZ_EVAL_COMPLETE, onez_wasm_eval(handle_ptr, src, src.len));

    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 7), out);
}

test "(wasm-load-sample) consumes its three inputs and pushes a handle" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    // One 32-bit float frame, 1.0f little-endian. Only proves the arity and the wiring; the
    // native path never reaches a host, so the handle is always 0. Real loading needs the actual
    // wasm target, where JS supplies "env".onez_host_load_sample.
    const src = "B{ 0x00 0x00 0x80 0x3f } 1 8000 (wasm-load-sample)";
    try std.testing.expectEqual(ONEZ_EVAL_COMPLETE, onez_wasm_eval(handle_ptr, src, src.len));

    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 0), out);
    try std.testing.expectEqual(@as(usize, 0), onez_stack_depth(handle_ptr));
}

test "(wasm-load-sample) rejects a non-byte-array first input without consuming the stack" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const src = "1 1 8000 (wasm-load-sample)";
    try std.testing.expectEqual(ONEZ_EVAL_ERROR, onez_wasm_eval(handle_ptr, src, src.len));
    try std.testing.expectEqual(@as(usize, 3), onez_stack_depth(handle_ptr));
}

test "(wasm-load-sample) rejects a non-positive channel count" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const src = "B{ 0x00 0x00 0x80 0x3f } 0 8000 (wasm-load-sample)";
    try std.testing.expectEqual(ONEZ_EVAL_ERROR, onez_wasm_eval(handle_ptr, src, src.len));
    try std.testing.expectEqual(@as(usize, 3), onez_stack_depth(handle_ptr));
}

test "(wasm-play-sample) consumes a fixnum handle" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const src = "0 (wasm-play-sample)";
    try std.testing.expectEqual(ONEZ_EVAL_COMPLETE, onez_wasm_eval(handle_ptr, src, src.len));
    try std.testing.expectEqual(@as(usize, 0), onez_stack_depth(handle_ptr));
}

test "(wasm-play-sample) rejects a non-fixnum handle without consuming the stack" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const src = "\"not-a-handle\" (wasm-play-sample)";
    try std.testing.expectEqual(ONEZ_EVAL_ERROR, onez_wasm_eval(handle_ptr, src, src.len));
    try std.testing.expectEqual(@as(usize, 1), onez_stack_depth(handle_ptr));
}

test "registered host word is invoked via dictionary lookup" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const Callback = struct {
        var invocations: usize = 0;

        fn callback(ctx: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            invocations += 1;
            _ = onez_push_int(ctx, 99);
            return 0;
        }
    };
    Callback.invocations = 0;

    try std.testing.expectEqual(ONEZ_OK, onez_register_word(handle_ptr, "test-host-word", Callback.callback, null));

    const src = "test-host-word";
    try std.testing.expectEqual(ONEZ_EVAL_COMPLETE, onez_wasm_eval(handle_ptr, src, src.len));
    try std.testing.expectEqual(@as(usize, 1), Callback.invocations);

    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 99), out);
}

test "push/pop int round trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 42), out);
}

test "push/pop string round trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const input = "hello";
    try std.testing.expectEqual(ONEZ_OK, onez_push_string(handle_ptr, input.ptr, input.len));
    var out_ptr: [*]const u8 = undefined;
    var out_len: usize = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_string(handle_ptr, &out_ptr, &out_len));
    try std.testing.expectEqualStrings("hello", out_ptr[0..out_len]);
}

test "pop type mismatch preserves stack" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var out: f64 = 0;
    try std.testing.expectEqual(ONEZ_ERR_TYPE_MISMATCH, onez_pop_double(handle_ptr, &out));
    try std.testing.expectEqual(@as(usize, 1), onez_stack_depth(handle_ptr));
}

test "stack_peek is non-destructive" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 7));
    var out: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_stack_peek(handle_ptr, 0, &out));
    try std.testing.expectEqual(@as(usize, 1), onez_stack_depth(handle_ptr));

    const value: *const Value = @ptrCast(@alignCast(out.?));
    try std.testing.expectEqual(@as(i64, 7), value.fixnum);
}
