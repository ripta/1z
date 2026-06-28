const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const HashTable = value_mod.HashTable;
const Quotation = value_mod.Quotation;
const Closure = value_mod.Closure;
const Segment = value_mod.Segment;
const benchmark_mod = @import("../benchmark.zig");
const BenchmarkStats = benchmark_mod.BenchmarkStats;
const BenchmarkReport = @import("../benchmark_report.zig").BenchmarkReport(Value);
const BenchmarkReportHandle = @import("../benchmark_report.zig").BenchmarkReportHandle;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;
const container_backing = @import("../container_backing.zig");

const popQuotation = helpers.popQuotation;
const popString = helpers.popString;
const popFixnum = helpers.popFixnum;

pub const primitives = [_]Primitive{
    .{ .name = "curry", .stack_effect = "x quot -- quot'", .doc = "Partially apply a value to a quotation.", .func = nativeCurry },
    .{ .name = "compose", .stack_effect = "quot1 quot2 -- quot'", .doc = "Concatenate two quotations into one.", .func = nativeCompose },
    .{ .name = "benchmark", .stack_effect = "quot -- hash", .doc = "Execute quotation once and return timing stats as a hash.", .func = nativeBenchmark },
    .{ .name = "make-benchmark-report", .stack_effect = "-- report", .doc = "Create a benchmark report collector.", .func = nativeMakeBenchmarkReport },
    .{ .name = "benchmark-run", .stack_effect = "report label quot -- report", .doc = "Benchmark a quotation once and add to report.", .func = nativeBenchmarkRun },
    .{ .name = "benchmark-n", .stack_effect = "report label n quot -- report", .doc = "Benchmark a quotation N times and add to report.", .func = nativeBenchmarkN },
    .{ .name = "benchmark-auto", .stack_effect = "report label quot -- report", .doc = "Auto-calibrate iterations targeting ~100ms and add to report.", .func = nativeBenchmarkAuto },
    .{ .name = "print-benchmark-report", .stack_effect = "report --", .doc = "Print benchmark results as a formatted table.", .func = nativePrintBenchmarkReport },
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
        .closure => |c| c.segments,
        else => null,
    };
}

/// curry ( x quot -- quot' ) - Partially apply a value to a quotation
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

    // Curried quotation has no effect - effect validation happens at parameter attachment time
    if (try segmentsOf(alloc, quot_val)) |base_segments| {
        const new_segments = try prependCapture(alloc, base_segments, x);
        const cl = try alloc.create(Closure);
        cl.* = .{ .instructions = new_instrs, .effect = null, .segments = new_segments };
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

/// compose ( quot1 quot2 -- quot' ) - Concatenate two quotations
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

    // Composed quotation has no effect - effect validation happens at parameter attachment time
    const s1 = try segmentsOf(alloc, quot1_val);
    const s2 = try segmentsOf(alloc, quot2_val);
    if (s1 != null and s2 != null) {
        const new_segments = try alloc.alloc(Segment, s1.?.len + s2.?.len);
        @memcpy(new_segments[0..s1.?.len], s1.?);
        @memcpy(new_segments[s1.?.len..], s2.?);
        const cl = try alloc.create(Closure);
        cl.* = .{ .instructions = new_instrs, .effect = null, .segments = new_segments };
        try ctx.stack.push(.{ .closure = cl });
    } else {
        try ctx.stack.push(.{ .quotation = .{ .instructions = new_instrs, .effect = null } });
    }
}

/// Execute a quotation and return benchmark results as a hash.
/// Shared core logic for `benchmark` and `benchmark-run`.
fn executeBenchmark(ctx: *Context, quot: Quotation) !*HashTable {
    return executeBenchmarkN(ctx, quot, 1);
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
    const start_time = std.time.nanoTimestamp();
    var exec_result: anyerror!void = {};
    for (0..n) |_| {
        exec_result = ctx.executeQuotationWithFrame(quot);
        if (exec_result) |_| {} else |_| break;
    }

    const end_time = std.time.nanoTimestamp();
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
    const alloc = ctx.quotationAllocator();
    const hash = alloc.create(HashTable) catch return error.OutOfMemory;
    hash.* = HashTable{};

    const key1 = alloc.dupe(u8, "elapsed_ns") catch return error.OutOfMemory;
    hash.put(alloc, key1, .{ .fixnum = @intCast(elapsed_ns) }) catch return error.OutOfMemory;

    const key2 = alloc.dupe(u8, "push_literal") catch return error.OutOfMemory;
    hash.put(alloc, key2, .{ .fixnum = @intCast(local_stats.push_literal_count) }) catch return error.OutOfMemory;

    const key3 = alloc.dupe(u8, "call_word") catch return error.OutOfMemory;
    hash.put(alloc, key3, .{ .fixnum = @intCast(local_stats.call_word_count) }) catch return error.OutOfMemory;

    const key4 = alloc.dupe(u8, "total_instructions") catch return error.OutOfMemory;
    hash.put(alloc, key4, .{ .fixnum = @intCast(local_stats.totalInstructions()) }) catch return error.OutOfMemory;

    const key5 = alloc.dupe(u8, "peak_stack_depth") catch return error.OutOfMemory;
    hash.put(alloc, key5, .{ .fixnum = @intCast(local_stats.peak_stack_depth) }) catch return error.OutOfMemory;

    const key_iter = alloc.dupe(u8, "iterations") catch return error.OutOfMemory;
    hash.put(alloc, key_iter, .{ .fixnum = @intCast(n) }) catch return error.OutOfMemory;

    // Add allocation stats only when --benchmark is active
    if (alloc_delta) |delta| {
        const key6 = alloc.dupe(u8, "total_allocations") catch return error.OutOfMemory;
        hash.put(alloc, key6, .{ .fixnum = @intCast(delta.allocs) }) catch return error.OutOfMemory;

        const key7 = alloc.dupe(u8, "total_bytes") catch return error.OutOfMemory;
        hash.put(alloc, key7, .{ .fixnum = @intCast(delta.bytes) }) catch return error.OutOfMemory;
    }

    return hash;
}

/// benchmark ( quot -- hash ) - Execute quotation and return benchmark stats
pub fn nativeBenchmark(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const hash = try executeBenchmark(ctx, quot);
    try ctx.stack.push(.{ .hash = hash });
}

/// make-benchmark-report ( -- report ) - Create a benchmark report collector
fn nativeMakeBenchmarkReport(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const report = alloc.create(BenchmarkReport) catch return error.OutOfMemory;
    report.* = BenchmarkReport.init(alloc);
    try ctx.stack.push(.{ .benchmark_report = @as(*BenchmarkReportHandle, @ptrCast(report)) });
}

/// benchmark-run ( report label quot -- report ) - Benchmark a quotation once and add to report
fn nativeBenchmarkRun(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);

    const label = try popString(ctx);
    const val = try ctx.stack.pop();
    const report = switch (val) {
        .benchmark_report => |r| @as(*BenchmarkReport, @ptrCast(@alignCast(r))),
        else => {
            helpers.setTypeMismatchError(ctx, "benchmark-report", val);
            return error.TypeMismatch;
        },
    };

    const hash = try executeBenchmark(ctx, quot);
    try report.addEntry(label, hash);
    try ctx.stack.push(.{ .benchmark_report = @as(*BenchmarkReportHandle, @ptrCast(report)) });
}

/// benchmark-n ( report label n quot -- report ) - Benchmark a quotation N times and add to report
fn nativeBenchmarkN(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);

    const n_raw = try popFixnum(ctx);
    if (n_raw < 1) return error.InvalidArgument;
    const n: u64 = @intCast(n_raw);

    const label = try popString(ctx);
    const val = try ctx.stack.pop();
    const report = switch (val) {
        .benchmark_report => |r| @as(*BenchmarkReport, @ptrCast(@alignCast(r))),
        else => {
            helpers.setTypeMismatchError(ctx, "benchmark-report", val);
            return error.TypeMismatch;
        },
    };

    const hash = try executeBenchmarkN(ctx, quot, n);
    try report.addEntry(label, hash);
    try ctx.stack.push(.{ .benchmark_report = @as(*BenchmarkReportHandle, @ptrCast(report)) });
}

/// benchmark-auto ( report label quot -- report ) - Auto-calibrate iterations targeting ~100ms
fn nativeBenchmarkAuto(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const label = try popString(ctx);
    const val = try ctx.stack.pop();
    const report = switch (val) {
        .benchmark_report => |r| @as(*BenchmarkReport, @ptrCast(@alignCast(r))),
        else => {
            helpers.setTypeMismatchError(ctx, "benchmark-report", val);
            return error.TypeMismatch;
        },
    };

    const target_ns: u64 = 100_000_000; // 100ms
    const max_iters: u64 = 1_000_000_000;

    var n: u64 = 1;
    var final_hash: ?*HashTable = null;

    while (true) {
        const hash = try executeBenchmarkN(ctx, quot, n);
        const elapsed_ns: u64 = @intCast(getHashInt(hash, "elapsed_ns") orelse 0);

        if (elapsed_ns >= target_ns or n >= max_iters) {
            final_hash = hash;
            break;
        }

        const scaled = if (elapsed_ns > 0)
            @min(max_iters, @max(n * 2, n * target_ns / elapsed_ns))
        else
            @min(max_iters, n * 2);

        n = if (scaled > n) scaled else n * 2;
        if (n > max_iters) n = max_iters;
    }

    try report.addEntry(label, final_hash.?);
    try ctx.stack.push(.{ .benchmark_report = @as(*BenchmarkReportHandle, @ptrCast(report)) });
}

/// print-benchmark-report - Polymorphic:
///   ( report -- )      print all entries as table
///   ( label hash -- )  print single benchmark as one-row table
fn nativePrintBenchmarkReport(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const val = try ctx.stack.pop();

    switch (val) {
        .benchmark_report => |report| {
            try printReportTable(ctx, @as(*BenchmarkReport, @ptrCast(@alignCast(report))));
        },
        .hash => |hash| {
            // Single benchmark: label is on the stack
            const label_val = try ctx.stack.pop();
            const label = switch (label_val) {
                .string => |s| s,
                else => {
                    helpers.setTypeMismatchError(ctx, "string", label_val);
                    return error.TypeMismatch;
                },
            };
            // Create a temporary single-entry report
            var tmp_report = BenchmarkReport.init(alloc);
            try tmp_report.addEntry(label, hash);
            try printReportTable(ctx, &tmp_report);
        },
        else => {
            helpers.setTypeMismatchError(ctx, "benchmark-report or hash", val);
            return error.TypeMismatch;
        },
    }
}

// =============================================================================
// Table formatter
// =============================================================================

fn getHashInt(hash: *HashTable, key: []const u8) ?i64 {
    const val = hash.get(key) orelse return null;
    return switch (val) {
        .fixnum => |i| i,
        else => null,
    };
}

fn formatToBuffer(buf: []u8, comptime fmt_fn: enum { time, bytes, number }, value: anytype) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    switch (fmt_fn) {
        .time => BenchmarkStats.formatTime(writer, value) catch {},
        .bytes => BenchmarkStats.formatBytes(writer, @as(usize, @intCast(value))) catch {},
        .number => BenchmarkStats.formatNumber(writer, @as(u64, @intCast(value))) catch {},
    }
    return stream.getWritten();
}

const Column = struct {
    header: []const u8,
    width: usize,
};

fn printReportTable(_: *Context, report: *BenchmarkReport) !void {
    const entries = report.entries.items;
    if (entries.len == 0) return;

    const has_allocs = entries[0].results.get("total_allocations") != null;

    // Columns: Name, Iters, Elapsed, Elapsed/iter, Instrs/iter, Peak Stack [, Allocs, Bytes]
    const max_col_count = 8;

    var columns: [max_col_count]Column = undefined;
    var col_count: usize = undefined;

    columns[0] = .{ .header = "Name", .width = 4 };
    columns[1] = .{ .header = "Iters", .width = 5 };
    columns[2] = .{ .header = "Elapsed", .width = 7 };
    columns[3] = .{ .header = "Elapsed/iter", .width = 12 };
    columns[4] = .{ .header = "Instrs/iter", .width = 11 };
    columns[5] = .{ .header = "Peak Stack", .width = 10 };
    col_count = 6;

    if (has_allocs) {
        columns[6] = .{ .header = "Allocs", .width = 6 };
        columns[7] = .{ .header = "Bytes", .width = 5 };
        col_count = 8;
    }

    const max_entries = 64;
    const actual_entries = @min(entries.len, max_entries);

    var cell_bufs: [max_entries][max_col_count][64]u8 = undefined;
    var cell_lens: [max_entries][max_col_count]usize = undefined;

    for (0..actual_entries) |row| {
        const entry = entries[row];
        const h = entry.results;

        // Label
        const label_len = @min(entry.label.len, 64);
        @memcpy(cell_bufs[row][0][0..label_len], entry.label[0..label_len]);
        cell_lens[row][0] = label_len;

        // Iters
        const iters = getHashInt(h, "iterations") orelse 1;
        const iters_u: u64 = @intCast(if (iters < 1) 1 else iters);
        const it_str = formatToBuffer(&cell_bufs[row][1], .number, iters_u);
        cell_lens[row][1] = it_str.len;

        // Elapsed
        const elapsed_ns = getHashInt(h, "elapsed_ns") orelse 0;
        const elapsed_str = formatToBuffer(&cell_bufs[row][2], .time, @as(i128, elapsed_ns));
        cell_lens[row][2] = elapsed_str.len;

        // Elapsed/iter
        const elapsed_per_iter: i128 = if (iters_u > 0) @divTrunc(@as(i128, elapsed_ns), @as(i128, iters_u)) else @as(i128, elapsed_ns);
        const epi_str = formatToBuffer(&cell_bufs[row][3], .time, elapsed_per_iter);
        cell_lens[row][3] = epi_str.len;

        // Instrs/iter
        const total_i = getHashInt(h, "total_instructions") orelse 0;
        const total_u: u64 = @intCast(if (total_i < 0) 0 else total_i);
        const instrs_per_iter: u64 = if (iters_u > 0) total_u / iters_u else total_u;
        const ipi_str = formatToBuffer(&cell_bufs[row][4], .number, instrs_per_iter);
        cell_lens[row][4] = ipi_str.len;

        // Peak Stack
        const peak = getHashInt(h, "peak_stack_depth") orelse 0;
        const pk_str = formatToBuffer(&cell_bufs[row][5], .number, peak);
        cell_lens[row][5] = pk_str.len;

        if (has_allocs) {
            // Total Allocs
            const allocs = getHashInt(h, "total_allocations") orelse 0;
            const al_str = formatToBuffer(&cell_bufs[row][6], .number, allocs);
            cell_lens[row][6] = al_str.len;

            // Total Bytes
            const bytes = getHashInt(h, "total_bytes") orelse 0;
            const by_str = formatToBuffer(&cell_bufs[row][7], .bytes, bytes);
            cell_lens[row][7] = by_str.len;
        }
    }

    // Compute column widths (max of header and all cells)
    for (0..col_count) |col| {
        for (0..actual_entries) |row| {
            if (cell_lens[row][col] > columns[col].width) {
                columns[col].width = cell_lens[row][col];
            }
        }
    }

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(report.allocator);
    const writer = output.writer(report.allocator);

    // Header row
    for (0..col_count) |col| {
        if (col > 0) try writer.writeAll("   ");
        const w = columns[col].width;
        const h = columns[col].header;
        if (col == 0) {
            // Label: left-aligned
            try writer.writeAll(h);
            try writeSpaces(writer, w - h.len);
        } else {
            // Numeric: right-aligned
            try writeSpaces(writer, w - h.len);
            try writer.writeAll(h);
        }
    }
    try writer.writeAll("\n");

    // Sep row
    for (0..col_count) |col| {
        if (col > 0) try writer.writeAll("   ");
        try writeDashes(writer, columns[col].width);
    }
    try writer.writeAll("\n");

    // Dem data rows
    for (0..actual_entries) |row| {
        for (0..col_count) |col| {
            if (col > 0) try writer.writeAll("   ");
            const w = columns[col].width;
            const cell = cell_bufs[row][col][0..cell_lens[row][col]];
            if (col == 0) {
                // Label: left-aligned
                try writer.writeAll(cell);
                try writeSpaces(writer, w - cell.len);
            } else {
                // Numeric: right-aligned
                try writeSpaces(writer, w - cell.len);
                try writer.writeAll(cell);
            }
        }
        try writer.writeAll("\n");
    }

    // Buffered writes causing problems =\
    const fd = std.posix.STDOUT_FILENO;
    var written: usize = 0;
    while (written < output.items.len) {
        written += std.posix.write(fd, output.items[written..]) catch break;
    }
}

fn writeSpaces(writer: anytype, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try writer.writeAll(" ");
    }
}

fn writeDashes(writer: anytype, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try writer.writeAll("-");
    }
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
