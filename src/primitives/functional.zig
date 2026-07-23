const std = @import("std");
const scheduler_mod = @import("../scheduler.zig");
const context_mod = @import("../context.zig");
const Context = context_mod.Context;
const CapturedScope = context_mod.CapturedScope;
const LocalFrame = context_mod.LocalFrame;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const HashTable = value_mod.HashTable;
const Quotation = value_mod.Quotation;
const Closure = value_mod.Closure;
const Segment = value_mod.Segment;
const benchmark_mod = @import("../benchmark.zig");
const BenchmarkStats = benchmark_mod.BenchmarkStats;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;
const container_backing = @import("../container_backing.zig");

const popQuotation = helpers.popQuotation;
const popFixnum = helpers.popFixnum;

pub const primitives = [_]Primitive{
    .{ .name = "curry", .stack_effect = "x quot -- quot'", .doc = "Partially apply a value to a quotation.", .func = nativeCurry },
    .{ .name = "compose", .stack_effect = "quot1 quot2 -- quot'", .doc = "Concatenate two quotations into one.", .func = nativeCompose },
    .{ .name = "(benchmark-n)", .stack_effect = "n quot -- hash", .doc = "Run quot n times in one timing window; return the raw timing hash.", .func = nativeBenchmarkNRaw },
};

/// The callable instruction body of a quotation or closure, or null for a
/// non-callable value.
fn callableInstrs(val: Value) ?[]const Instruction {
    return switch (val) {
        .quotation => |q| q.instructions,
        .closure => |c| c.instructions,
        else => null,
    };
}

/// Decompose a callable into closure segments when every base it covers is
/// already compiled (has a `code_ptr`), or null otherwise. A plain compiled
/// quotation is a single capture-free segment; a closure carries its own
/// segments. The returned captures borrow the constituent values -- the owning
/// references live in the new closure's `instructions` (registered for release
/// at teardown), and `jitCallClosure` retains each capture when it pushes it.
fn segmentsOf(alloc: std.mem.Allocator, val: Value) !?[]const Segment {
    return switch (val) {
        .quotation => |q| if (q.code_ptr) |cp| blk: {
            const segs = try alloc.alloc(Segment, 1);
            segs[0] = .{ .captures = &.{}, .base_code_ptr = cp };
            break :blk segs;
        } else null,
        // A scope-carrying closure over an uncompiled base has empty segments -- it is compiled in
        // no sense, so treat it like an uncompiled quotation and take the interpreter branch.
        .closure => |c| if (c.segments.len == 0) null else c.segments,
        else => null,
    };
}

/// The lexical scope a base callable closes over, if any. A closure carries it on the value; a
/// plain quotation's scope lives in the capture side map, looked up here in this context and, for a
/// quotation created in an ancestor task, up the parent chain. `curry`/`compose` embed the result
/// onto the closure they build so it rides the value across spawn boundaries.
///
/// A closure's own `captured_scope` is already an independent, owned copy -- every closure built
/// anywhere in the interpreter (`Context.promoteToClosure`, and `curry`/`compose` below) makes one
/// -- so it is returned as-is, safe to share further: it is never retained, released, or
/// superseded, unlike a map entry. A plain quotation's scope, if any, still lives in the refcounted
/// capture map, so `findCapturedScopeForBody` returns a fresh, independently-owned copy on `alloc`
/// rather than a shared pointer into it -- see `Context.promoteToClosure`'s doc comment for why
/// that copy is load-bearing.
fn baseCapturedScope(ctx: *Context, alloc: std.mem.Allocator, val: Value) !?*const CapturedScope {
    return switch (val) {
        .closure => |c| c.captured_scope,
        .quotation => |q| try ctx.findCapturedScopeForBody(alloc, @intFromPtr(q.instructions.ptr)),
        else => null,
    };
}

/// Deep-copy the concatenation of two source scopes onto `alloc`, `a`'s frames before `b`'s.
/// `compose` runs `instrs1` then `instrs2`, so a name bound in both resolves to `b`'s binding,
/// matching `lookupInCapturedScope`'s most-recent-first walk. Only reached when both bases carry a
/// scope; the single-source case shares the base's scope with no copy.
fn mergeCapturedScopes(alloc: std.mem.Allocator, a: *const CapturedScope, b: *const CapturedScope) !*CapturedScope {
    const a_frames = a.lexical_frames;
    const b_frames = b.lexical_frames;

    const frames = try alloc.alloc(LocalFrame, a_frames.len + b_frames.len);
    var built: usize = 0;
    errdefer {
        for (frames[0..built]) |*f| f.deinit(alloc);
        alloc.free(frames);
    }

    for ([_][]const LocalFrame{ a_frames, b_frames }) |group| {
        for (group) |*sf| {
            var clone: LocalFrame = .{};
            errdefer clone.deinit(alloc);
            var it = sf.iterator();
            while (it.next()) |e| try clone.put(alloc, e.key_ptr.*, e.value_ptr.*);
            frames[built] = clone;
            built += 1;
        }
    }

    const scope = try alloc.create(CapturedScope);
    scope.* = .{ .lexical_frames = frames, .allocator = alloc };
    return scope;
}

/// curry ( x quot -- quot' )
/// Example: 5 [ + ] curry creates [ 5 + ]
///
/// When the base quotation is already compiled, the result is a closure that
/// carries the base's `code_ptr` and `x` as a captured prefix, so it is callable
/// in an interpreter-free AOT binary (push-then-call). Otherwise it is a plain
/// quotation, unchanged from before.
pub fn nativeCurry(ctx: *Context) anyerror!void {
    const quot_val = try ctx.stack.pop();
    const base_instrs = callableInstrs(quot_val) orelse {
        helpers.setTypeMismatchError(ctx, "quotation", quot_val);
        container_backing.releaseValue(quot_val);
        return error.TypeMismatch;
    };
    const x = try ctx.stack.pop();

    // Allocate new instruction array: 1 (for push x) + original length
    const alloc = ctx.quotationAllocator();
    const new_instrs = try alloc.alloc(Instruction, 1 + base_instrs.len);

    // First instruction: push the value x.
    // x came from a pop (transfer); embedding here is also a transfer,
    // no retain needed.
    new_instrs[0] = .{ .op = .{ .push_literal = x }, .line = 0 };

    // Copy original quotation instructions. Container literals shared
    // with the source quotation gain a second owner (this new slice
    // will also be registered for release at teardown), so retain each.
    @memcpy(new_instrs[1..], base_instrs);
    container_backing.retainInstructionsContainerLiterals(new_instrs[1..]);

    try ctx.registerQuotationContainerLiterals(new_instrs);

    // Carry the base's captured lexical scope onto the new body so a curried closure resolves its
    // bare words at its creation site wherever it later runs.
    const carried: ?*const CapturedScope = try baseCapturedScope(ctx, alloc, quot_val);

    // Curried quotation has no effect - effect validation happens at parameter attachment time
    if (try segmentsOf(alloc, quot_val)) |base_segments| {
        const new_segments = try prependCapture(alloc, base_segments, x);
        const cl = try alloc.create(Closure);
        cl.* = .{ .instructions = new_instrs, .effect = null, .segments = new_segments, .captured_scope = carried };
        try ctx.stack.push(.{ .closure = cl });
    } else if (carried != null) {
        // No compiled segments, but a scope to carry: box a closure over the interpreter body so
        // the scope rides the value. `segments` is empty; the interpreter runs `instructions`.
        const cl = try alloc.create(Closure);
        cl.* = .{ .instructions = new_instrs, .effect = null, .segments = &.{}, .captured_scope = carried };
        try ctx.stack.push(.{ .closure = cl });
    } else {
        try ctx.stack.push(.{ .quotation = .{ .instructions = new_instrs, .effect = null } });
    }
}

/// Prepend a captured value to the first segment of a closure body. The first
/// base runs after `x` and the segment's existing captures are on the stack.
fn prependCapture(alloc: std.mem.Allocator, segs: []const Segment, x: Value) ![]const Segment {
    const new_segs = try alloc.alloc(Segment, segs.len);
    const first = segs[0];
    const new_caps = try alloc.alloc(Value, 1 + first.captures.len);
    new_caps[0] = x;
    @memcpy(new_caps[1..], first.captures);
    new_segs[0] = .{ .captures = new_caps, .base_code_ptr = first.base_code_ptr };
    @memcpy(new_segs[1..], segs[1..]);
    return new_segs;
}

/// compose ( quot1 quot2 -- quot' )
/// Example: [ 2 * ] [ 3 + ] compose creates [ 2 * 3 + ]
///
/// When both bases are compiled, the result is a closure whose segments are the
/// two bases' segments in order, callable interpreter-free. If either base lacks
/// a `code_ptr`, the result is a plain quotation, unchanged from before.
pub fn nativeCompose(ctx: *Context) anyerror!void {
    const quot2_val = try ctx.stack.pop();
    const instrs2 = callableInstrs(quot2_val) orelse {
        helpers.setTypeMismatchError(ctx, "quotation", quot2_val);
        container_backing.releaseValue(quot2_val);
        return error.TypeMismatch;
    };
    const quot1_val = try ctx.stack.pop();
    const instrs1 = callableInstrs(quot1_val) orelse {
        helpers.setTypeMismatchError(ctx, "quotation", quot1_val);
        container_backing.releaseValue(quot1_val);
        return error.TypeMismatch;
    };

    // Allocate new instruction array: quot1.len + quot2.len
    const alloc = ctx.quotationAllocator();
    const new_instrs = try alloc.alloc(Instruction, instrs1.len + instrs2.len);

    // Copy quot1 then quot2; container literals shared with the source
    // quotations gain a second owner under this new registration, so
    // retain each copied literal.
    @memcpy(new_instrs[0..instrs1.len], instrs1);
    @memcpy(new_instrs[instrs1.len..], instrs2);
    container_backing.retainInstructionsContainerLiterals(new_instrs);

    try ctx.registerQuotationContainerLiterals(new_instrs);

    // Carry the bases' captured lexical scopes onto the composed body. A single source is carried
    // as-is; two are merged into one scope on the quotation arena, `quot1`'s frames before `quot2`'s.
    const sa = try baseCapturedScope(ctx, alloc, quot1_val);
    const sb = try baseCapturedScope(ctx, alloc, quot2_val);
    const carried: ?*const CapturedScope = if (sa != null and sb != null)
        try mergeCapturedScopes(alloc, sa.?, sb.?)
    else
        (sa orelse sb);

    // Composed quotation has no effect - effect validation happens at parameter attachment time
    const s1 = try segmentsOf(alloc, quot1_val);
    const s2 = try segmentsOf(alloc, quot2_val);
    if (s1 != null and s2 != null) {
        const new_segments = try alloc.alloc(Segment, s1.?.len + s2.?.len);
        @memcpy(new_segments[0..s1.?.len], s1.?);
        @memcpy(new_segments[s1.?.len..], s2.?);
        const cl = try alloc.create(Closure);
        cl.* = .{ .instructions = new_instrs, .effect = null, .segments = new_segments, .captured_scope = carried };
        try ctx.stack.push(.{ .closure = cl });
    } else if (carried != null) {
        const cl = try alloc.create(Closure);
        cl.* = .{ .instructions = new_instrs, .effect = null, .segments = &.{}, .captured_scope = carried };
        try ctx.stack.push(.{ .closure = cl });
    } else {
        try ctx.stack.push(.{ .quotation = .{ .instructions = new_instrs, .effect = null } });
    }
}

/// Execute a quotation N times inside a single timing window.
fn executeBenchmarkN(ctx: *Context, quot: Quotation, n: u64) !*HashTable {
    // Create temporary benchmark stats for this execution
    var local_stats = BenchmarkStats{};
    defer local_stats.deinit(ctx.allocator);

    // Save and replace context benchmark pointer
    const saved_benchmark = ctx.benchmark;
    ctx.benchmark = &local_stats;

    // Snapshot allocation counters from CLI-level stats (if --benchmark is active)
    const alloc_before: ?struct { allocs: usize, bytes: usize } = if (saved_benchmark) |sb|
        .{ .allocs = sb.total_allocations, .bytes = sb.total_bytes }
    else
        null;

    // Time and execute
    const start_time = scheduler_mod.elapsedTimerNowNs();
    var exec_result: anyerror!void = {};
    // A while loop with an explicit u64 counter, not `for (0..n)`: n is u64 (a fixnum count),
    // and `for` range bounds must fit usize, which is only 32 bits on wasm32.
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        exec_result = ctx.executeQuotationWithFrame(quot);
        if (exec_result) |_| {} else |_| break;
    }

    const end_time = scheduler_mod.elapsedTimerNowNs();
    const elapsed_ns = end_time - start_time;

    // Compute allocation deltas before restoring benchmark pointer
    const alloc_delta: ?struct { allocs: usize, bytes: usize } = if (saved_benchmark) |sb|
        if (alloc_before) |before|
            .{ .allocs = sb.total_allocations - before.allocs, .bytes = sb.total_bytes - before.bytes }
        else
            null
    else
        null;

    // Restore original benchmark pointer
    ctx.benchmark = saved_benchmark;

    // Propagate execution error after restoring state
    try exec_result;

    // Build result hash
    const hash = HashTable.create(ctx.allocator) catch return error.OutOfMemory;
    errdefer hash.header.release();
    const hash_alloc = hash.header.allocator;

    const key1 = hash_alloc.dupe(u8, "elapsed_ns") catch return error.OutOfMemory;
    hash.map.put(hash_alloc, key1, .{ .fixnum = @intCast(elapsed_ns) }) catch return error.OutOfMemory;

    const key2 = hash_alloc.dupe(u8, "push_literal") catch return error.OutOfMemory;
    hash.map.put(hash_alloc, key2, .{ .fixnum = @intCast(local_stats.push_literal_count) }) catch return error.OutOfMemory;

    const key3 = hash_alloc.dupe(u8, "call_word") catch return error.OutOfMemory;
    hash.map.put(hash_alloc, key3, .{ .fixnum = @intCast(local_stats.call_word_count) }) catch return error.OutOfMemory;

    const key4 = hash_alloc.dupe(u8, "total_instructions") catch return error.OutOfMemory;
    hash.map.put(hash_alloc, key4, .{ .fixnum = @intCast(local_stats.totalInstructions()) }) catch return error.OutOfMemory;

    const key5 = hash_alloc.dupe(u8, "peak_stack_depth") catch return error.OutOfMemory;
    hash.map.put(hash_alloc, key5, .{ .fixnum = @intCast(local_stats.peak_stack_depth) }) catch return error.OutOfMemory;

    const key_iter = hash_alloc.dupe(u8, "iterations") catch return error.OutOfMemory;
    hash.map.put(hash_alloc, key_iter, .{ .fixnum = @intCast(n) }) catch return error.OutOfMemory;

    // Add allocation stats only when --benchmark is active
    if (alloc_delta) |delta| {
        const key6 = hash_alloc.dupe(u8, "total_allocations") catch return error.OutOfMemory;
        hash.map.put(hash_alloc, key6, .{ .fixnum = @intCast(delta.allocs) }) catch return error.OutOfMemory;

        const key7 = hash_alloc.dupe(u8, "total_bytes") catch return error.OutOfMemory;
        hash.map.put(hash_alloc, key7, .{ .fixnum = @intCast(delta.bytes) }) catch return error.OutOfMemory;
    }

    return hash;
}

/// (benchmark-n) ( n quot -- hash )
///
/// The building block for the 1z benchmark words.
pub fn nativeBenchmarkNRaw(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const n_raw = try popFixnum(ctx);
    if (n_raw < 1) return error.InvalidArgument;
    const hash = try executeBenchmarkN(ctx, quot, @intCast(n_raw));
    try ctx.stack.pushMoved(.{ .hash = hash });
}

test "curry over a compiled base produces a closure carrying the base code_ptr" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const dummy_code: *const anyopaque = @ptrFromInt(0x1000);
    try ctx.stack.push(.{ .fixnum = 7 });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &.{}, .code_ptr = dummy_code } });
    try nativeCurry(&ctx);

    const result = try ctx.stack.pop();
    try std.testing.expect(result == .closure);
    const cl = result.closure;
    try std.testing.expectEqual(@as(usize, 1), cl.segments.len);
    try std.testing.expectEqual(@as(usize, 1), cl.segments[0].captures.len);
    try std.testing.expectEqual(@as(i64, 7), cl.segments[0].captures[0].fixnum);
    try std.testing.expectEqual(dummy_code, cl.segments[0].base_code_ptr);
}

test "curry over an uncompiled base produces a plain quotation" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .fixnum = 7 });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &.{} } });
    try nativeCurry(&ctx);

    const result = try ctx.stack.pop();
    try std.testing.expect(result == .quotation);
}

test "compose over compiled bases produces a closure with both segments in order" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const code_a: *const anyopaque = @ptrFromInt(0x1000);
    const code_b: *const anyopaque = @ptrFromInt(0x2000);
    try ctx.stack.push(.{ .quotation = .{ .instructions = &.{}, .code_ptr = code_a } });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &.{}, .code_ptr = code_b } });
    try nativeCompose(&ctx);

    const result = try ctx.stack.pop();
    try std.testing.expect(result == .closure);
    const cl = result.closure;
    try std.testing.expectEqual(@as(usize, 2), cl.segments.len);
    try std.testing.expectEqual(code_a, cl.segments[0].base_code_ptr);
    try std.testing.expectEqual(code_b, cl.segments[1].base_code_ptr);
}

test "nested curry prepends a capture to the first segment" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const dummy_code: *const anyopaque = @ptrFromInt(0x1000);
    try ctx.stack.push(.{ .fixnum = 7 });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &.{}, .code_ptr = dummy_code } });
    try nativeCurry(&ctx);

    const inner = try ctx.stack.pop();
    try ctx.stack.push(.{ .fixnum = 9 });
    try ctx.stack.push(inner);
    try nativeCurry(&ctx);

    const result = try ctx.stack.pop();
    try std.testing.expect(result == .closure);
    const cl = result.closure;
    try std.testing.expectEqual(@as(usize, 1), cl.segments.len);
    try std.testing.expectEqual(@as(usize, 2), cl.segments[0].captures.len);
    try std.testing.expectEqual(@as(i64, 9), cl.segments[0].captures[0].fixnum);
    try std.testing.expectEqual(@as(i64, 7), cl.segments[0].captures[1].fixnum);
    try std.testing.expectEqual(dummy_code, cl.segments[0].base_code_ptr);
}
