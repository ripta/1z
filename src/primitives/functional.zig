const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const HashTable = value_mod.HashTable;
const Quotation = value_mod.Quotation;
const benchmark_mod = @import("../benchmark.zig");
const BenchmarkStats = benchmark_mod.BenchmarkStats;
const BenchmarkReport = benchmark_mod.BenchmarkReport;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

const popQuotation = helpers.popQuotation;
const popString = helpers.popString;

pub const primitives = [_]Primitive{
    .{ .name = "curry", .stack_effect = "x quot -- quot'", .func = nativeCurry },
    .{ .name = "compose", .stack_effect = "quot1 quot2 -- quot'", .func = nativeCompose },
    .{ .name = "benchmark", .stack_effect = "quot -- hash", .func = nativeBenchmark },
    .{ .name = "make-benchmark-report", .stack_effect = "-- report", .func = nativeMakeBenchmarkReport },
    .{ .name = "benchmark-run", .stack_effect = "report label quot -- report", .func = nativeBenchmarkRun },
    .{ .name = "print-benchmark-report", .func = nativePrintBenchmarkReport },
};

/// curry ( x quot -- quot' ) - Partially apply a value to a quotation
/// Example: 5 [ + ] curry creates [ 5 + ]
pub fn nativeCurry(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const x = try ctx.stack.pop();

    // Allocate new instruction array: 1 (for push x) + original length
    const alloc = ctx.quotationAllocator();
    const new_instrs = try alloc.alloc(Instruction, 1 + quot.instructions.len);

    // First instruction: push the value x
    new_instrs[0] = .{ .op = .{ .push_literal = x }, .line = 0 };

    // Copy original quotation instructions
    @memcpy(new_instrs[1..], quot.instructions);

    // Curried quotation has no effect - effect validation happens at parameter attachment time
    try ctx.stack.push(.{ .quotation = .{ .instructions = new_instrs, .effect = null } });
}

/// compose ( quot1 quot2 -- quot' ) - Concatenate two quotations
/// Example: [ 2 * ] [ 3 + ] compose creates [ 2 * 3 + ]
pub fn nativeCompose(ctx: *Context) anyerror!void {
    const quot2 = try popQuotation(ctx);
    const quot1 = try popQuotation(ctx);

    // Allocate new instruction array: quot1.len + quot2.len
    const alloc = ctx.quotationAllocator();
    const new_instrs = try alloc.alloc(Instruction, quot1.instructions.len + quot2.instructions.len);

    // Copy quot1 then quot2
    @memcpy(new_instrs[0..quot1.instructions.len], quot1.instructions);
    @memcpy(new_instrs[quot1.instructions.len..], quot2.instructions);

    // Composed quotation has no effect - effect validation happens at parameter attachment time
    try ctx.stack.push(.{ .quotation = .{ .instructions = new_instrs, .effect = null } });
}

/// Execute a quotation and return benchmark results as a hash.
/// Shared core logic for `benchmark` and `benchmark-run`.
fn executeBenchmark(ctx: *Context, quot: Quotation) !*HashTable {
    // Create temporary benchmark stats for this execution
    var local_stats = BenchmarkStats{};

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
    const exec_result = ctx.executeQuotationWithFrame(quot);

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
    hash.put(alloc, key1, .{ .integer = @intCast(elapsed_ns) }) catch return error.OutOfMemory;

    const key2 = alloc.dupe(u8, "push_literal") catch return error.OutOfMemory;
    hash.put(alloc, key2, .{ .integer = @intCast(local_stats.push_literal_count) }) catch return error.OutOfMemory;

    const key3 = alloc.dupe(u8, "call_word") catch return error.OutOfMemory;
    hash.put(alloc, key3, .{ .integer = @intCast(local_stats.call_word_count) }) catch return error.OutOfMemory;

    const key4 = alloc.dupe(u8, "total_instructions") catch return error.OutOfMemory;
    hash.put(alloc, key4, .{ .integer = @intCast(local_stats.totalInstructions()) }) catch return error.OutOfMemory;

    const key5 = alloc.dupe(u8, "peak_stack_depth") catch return error.OutOfMemory;
    hash.put(alloc, key5, .{ .integer = @intCast(local_stats.peak_stack_depth) }) catch return error.OutOfMemory;

    // Add allocation stats only when --benchmark is active
    if (alloc_delta) |delta| {
        const key6 = alloc.dupe(u8, "total_allocations") catch return error.OutOfMemory;
        hash.put(alloc, key6, .{ .integer = @intCast(delta.allocs) }) catch return error.OutOfMemory;

        const key7 = alloc.dupe(u8, "total_bytes") catch return error.OutOfMemory;
        hash.put(alloc, key7, .{ .integer = @intCast(delta.bytes) }) catch return error.OutOfMemory;
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
    try ctx.stack.push(.{ .benchmark_report = report });
}

/// benchmark-run ( report label quot -- report ) - Benchmark a quotation and add to report
fn nativeBenchmarkRun(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const label = try popString(ctx);
    const val = try ctx.stack.pop();
    const report = switch (val) {
        .benchmark_report => |r| r,
        else => return error.TypeError,
    };

    const hash = try executeBenchmark(ctx, quot);
    try report.addEntry(label, hash);
    try ctx.stack.push(.{ .benchmark_report = report });
}

/// print-benchmark-report - Polymorphic:
///   ( report -- )      print all entries as table
///   ( label hash -- )  print single benchmark as one-row table
fn nativePrintBenchmarkReport(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();

    switch (val) {
        .benchmark_report => |report| {
            try printReportTable(ctx, report);
        },
        .hash => |hash| {
            // Single benchmark: label is on the stack
            const label_val = try ctx.stack.pop();
            const label = switch (label_val) {
                .string => |s| s,
                else => return error.TypeError,
            };
            // Create a temporary single-entry report
            const alloc = ctx.quotationAllocator();
            var tmp_report = BenchmarkReport.init(alloc);
            try tmp_report.addEntry(label, hash);
            try printReportTable(ctx, &tmp_report);
        },
        else => return error.TypeError,
    }
}

// =============================================================================
// Table formatter
// =============================================================================

fn getHashInt(hash: *HashTable, key: []const u8) ?i64 {
    const val = hash.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
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

    const has_allocs = if (entries.len > 0) entries[0].results.get("total_allocations") != null else false;

    const base_col_count = 6;
    const max_col_count = 8; // +2 for allocs/bytes
    const col_count: usize = if (has_allocs) max_col_count else base_col_count;

    var columns: [max_col_count]Column = undefined;
    columns[0] = .{ .header = "Name", .width = 4 };
    columns[1] = .{ .header = "Elapsed", .width = 7 };
    columns[2] = .{ .header = "push_literal", .width = 12 };
    columns[3] = .{ .header = "call_word", .width = 9 };
    columns[4] = .{ .header = "Total Instrs", .width = 12 };
    columns[5] = .{ .header = "Peak Stack", .width = 10 };
    if (has_allocs) {
        columns[6] = .{ .header = "Allocs", .width = 6 };
        columns[7] = .{ .header = "Bytes", .width = 5 };
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

        // Elapsed
        const elapsed_ns = getHashInt(h, "elapsed_ns") orelse 0;
        const elapsed_str = formatToBuffer(&cell_bufs[row][1], .time, @as(i128, elapsed_ns));
        cell_lens[row][1] = elapsed_str.len;

        // push_literal
        const push_lit = getHashInt(h, "push_literal") orelse 0;
        const pl_str = formatToBuffer(&cell_bufs[row][2], .number, push_lit);
        cell_lens[row][2] = pl_str.len;

        // call_word
        const call_w = getHashInt(h, "call_word") orelse 0;
        const cw_str = formatToBuffer(&cell_bufs[row][3], .number, call_w);
        cell_lens[row][3] = cw_str.len;

        // total_instructions
        const total_i = getHashInt(h, "total_instructions") orelse 0;
        const ti_str = formatToBuffer(&cell_bufs[row][4], .number, total_i);
        cell_lens[row][4] = ti_str.len;

        // peak_stack_depth
        const peak = getHashInt(h, "peak_stack_depth") orelse 0;
        const pk_str = formatToBuffer(&cell_bufs[row][5], .number, peak);
        cell_lens[row][5] = pk_str.len;

        if (has_allocs) {
            // total_allocations
            const allocs = getHashInt(h, "total_allocations") orelse 0;
            const al_str = formatToBuffer(&cell_bufs[row][6], .number, allocs);
            cell_lens[row][6] = al_str.len;

            // total_bytes
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
