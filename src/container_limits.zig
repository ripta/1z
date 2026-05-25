const std = @import("std");
const builtin = @import("builtin");
const trace = @import("trace.zig");

/// Root of the cgroup filesystem hierarchy on Linux.
const cgroup_root = "/sys/fs/cgroup";

/// Filesystem roots the Linux detectors read from. The defaults are the real system paths;
/// tests inject temp-dir fixtures by overriding them.
const Roots = struct {
    cgroup: []const u8 = cgroup_root,
    proc_cgroup: []const u8 = "/proc/self/cgroup",
};

/// Where the resolved CPU count came from.
pub const CpuSource = enum { cgroup_v2, cgroup_v1, affinity, fallback };

/// Where the resolved memory cap came from. Memory has no affinity analogue,
/// so the only sources are the two cgroup versions and the hard fallback.
pub const MemorySource = enum { cgroup_v2, cgroup_v1, fallback };

/// Resolved CPU detection result.
pub const CpuDetection = struct {
    count: usize,
    source: CpuSource,
    raw_quota: ?i64 = null,
    raw_period: ?i64 = null,
};

/// Resolved memory detection result. `cap` is the detected cgroup limit in
/// bytes; it is 0 when `source == .fallback`, signalling "no cgroup limit
/// detected, the caller should apply its own default".
pub const MemoryDetection = struct {
    cap: usize,
    source: MemorySource,
    raw: ?u64 = null,
};

/// Detect the CPU budget. Combines the affinity-based count
/// (`std.Thread.getCpuCount`) with the cgroup bandwidth quota when present,
/// taking the tighter of the two and clamping to at least 1. On non-Linux
/// platforms, or when no cgroup quota is found, the affinity count is used.
pub fn detectCpus(trace_enabled: bool) CpuDetection {
    const affinity_opt: ?usize = std.Thread.getCpuCount() catch null;
    const affinity: usize = if (affinity_opt) |a| (if (a < 1) 1 else a) else 1;
    const base_source: CpuSource = if (affinity_opt != null) .affinity else .fallback;

    if (builtin.os.tag != .linux) {
        if (trace_enabled) traceLine("cpu: non-Linux platform has no cgroup support, using affinity count {d}", .{affinity});
        return .{ .count = affinity, .source = base_source };
    }

    if (detectCpuQuotaLinux(.{}, trace_enabled)) |q| {
        const cgroup_cpus = cpusFromQuota(q.quota, q.period);
        const count = @min(cgroup_cpus, affinity);
        return .{
            .count = if (count < 1) 1 else count,
            .source = q.source,
            .raw_quota = q.quota,
            .raw_period = q.period,
        };
    }

    if (trace_enabled) traceLine("cpu: no cgroup quota detected, using affinity count {d}", .{affinity});
    return .{ .count = affinity, .source = base_source };
}

/// Detect the memory budget from the container's cgroup limit. Returns a
/// `.fallback` result with `cap == 0` on non-Linux platforms or when no cgroup
/// limit is set; the caller is responsible for applying its own default in
/// that case.
pub fn detectMemory(trace_enabled: bool) MemoryDetection {
    if (builtin.os.tag != .linux) {
        if (trace_enabled) traceLine("memory: non-Linux platform has no cgroup support, caller uses its default", .{});
        return .{ .cap = 0, .source = .fallback };
    }

    if (detectMemoryLinux(.{}, trace_enabled)) |res| return res;

    if (trace_enabled) traceLine("memory: no cgroup limit detected, caller uses its default", .{});
    return .{ .cap = 0, .source = .fallback };
}

// =============================================================================
// Linux detection orchestration
// =============================================================================

const CpuQuota = struct { quota: i64, period: i64, source: CpuSource };

fn detectCpuQuotaLinux(roots: Roots, trace_enabled: bool) ?CpuQuota {
    var proc_buf: [4096]u8 = undefined;
    const proc = readSmallFile(roots.proc_cgroup, &proc_buf) orelse {
        if (trace_enabled) traceLine("cpu: cannot read /proc/self/cgroup", .{});
        return null;
    };

    var path_buf: [512]u8 = undefined;
    var val_buf: [256]u8 = undefined;

    // cgroup v2 unified hierarchy: the single "0::<path>" line points at the
    // leaf cgroup; cpu.max lives at /sys/fs/cgroup<path>/cpu.max. Fall back to
    // the root cpu.max when the leaf file is absent.
    if (parseProcCgroupV2(proc)) |subpath| {
        if (std.fmt.bufPrint(&path_buf, "{s}{s}/cpu.max", .{ roots.cgroup, subpath })) |leaf_path| {
            if (readSmallFile(leaf_path, &val_buf)) |content| {
                if (parseCpuMaxV2(content)) |q| {
                    return .{ .quota = q.quota, .period = q.period, .source = .cgroup_v2 };
                }
            }
        } else |_| {}
        if (std.fmt.bufPrint(&path_buf, "{s}/cpu.max", .{roots.cgroup})) |root_path| {
            if (readSmallFile(root_path, &val_buf)) |content| {
                if (parseCpuMaxV2(content)) |q| {
                    return .{ .quota = q.quota, .period = q.period, .source = .cgroup_v2 };
                }
            }
        } else |_| {}
        if (trace_enabled) traceLine("cpu: cgroup v2 cpu.max missing, unparseable, or unlimited", .{});
        return null;
    }

    // cgroup v1 per-controller hierarchy: the cpu controller is usually mounted
    // as cpu,cpuacct but may be a bare cpu directory on some systems.
    if (parseProcCgroupV1(proc, "cpu")) |subpath| {
        const cpu_dirs = [_][]const u8{ "cpu,cpuacct", "cpu" };
        const quota_content = readV1ControllerFile(roots.cgroup, &path_buf, &val_buf, &cpu_dirs, subpath, "cpu.cfs_quota_us") orelse {
            if (trace_enabled) traceLine("cpu: cgroup v1 cpu.cfs_quota_us unreadable", .{});
            return null;
        };
        const quota = parseCfsQuotaV1(quota_content) orelse {
            if (trace_enabled) traceLine("cpu: cgroup v1 quota unset or unparseable", .{});
            return null;
        };
        const period_content = readV1ControllerFile(roots.cgroup, &path_buf, &val_buf, &cpu_dirs, subpath, "cpu.cfs_period_us") orelse {
            if (trace_enabled) traceLine("cpu: cgroup v1 cpu.cfs_period_us unreadable", .{});
            return null;
        };
        const period = parseCfsPeriodV1(period_content) orelse {
            if (trace_enabled) traceLine("cpu: cgroup v1 period unparseable", .{});
            return null;
        };
        return .{ .quota = quota, .period = period, .source = .cgroup_v1 };
    }

    if (trace_enabled) traceLine("cpu: no cgroup v1 or v2 controller path in /proc/self/cgroup", .{});
    return null;
}

fn detectMemoryLinux(roots: Roots, trace_enabled: bool) ?MemoryDetection {
    var proc_buf: [4096]u8 = undefined;
    const proc = readSmallFile(roots.proc_cgroup, &proc_buf) orelse {
        if (trace_enabled) traceLine("memory: cannot read /proc/self/cgroup", .{});
        return null;
    };

    var path_buf: [512]u8 = undefined;
    var val_buf: [256]u8 = undefined;

    if (parseProcCgroupV2(proc)) |subpath| {
        if (std.fmt.bufPrint(&path_buf, "{s}{s}/memory.max", .{ roots.cgroup, subpath })) |leaf_path| {
            if (readSmallFile(leaf_path, &val_buf)) |content| {
                if (parseMemLimit(content)) |v| {
                    return .{ .cap = v, .source = .cgroup_v2, .raw = v };
                }
            }
        } else |_| {}
        if (std.fmt.bufPrint(&path_buf, "{s}/memory.max", .{roots.cgroup})) |root_path| {
            if (readSmallFile(root_path, &val_buf)) |content| {
                if (parseMemLimit(content)) |v| {
                    return .{ .cap = v, .source = .cgroup_v2, .raw = v };
                }
            }
        } else |_| {}
        if (trace_enabled) traceLine("memory: cgroup v2 memory.max missing, unparseable, or unlimited", .{});
        return null;
    }

    if (parseProcCgroupV1(proc, "memory")) |subpath| {
        const mem_dirs = [_][]const u8{"memory"};
        const content = readV1ControllerFile(roots.cgroup, &path_buf, &val_buf, &mem_dirs, subpath, "memory.limit_in_bytes") orelse {
            if (trace_enabled) traceLine("memory: cgroup v1 memory.limit_in_bytes unreadable", .{});
            return null;
        };
        if (parseMemLimit(content)) |v| {
            return .{ .cap = v, .source = .cgroup_v1, .raw = v };
        }
        if (trace_enabled) traceLine("memory: cgroup v1 limit unset, unlimited, or unparseable", .{});
        return null;
    }

    if (trace_enabled) traceLine("memory: no cgroup v1 or v2 controller path in /proc/self/cgroup", .{});
    return null;
}

// =============================================================================
// File reading
// =============================================================================

/// Read up to `buf.len` bytes from an absolute path into `buf`. Any error or an
/// empty read yields null, which drives the silent-fallback behaviour.
fn readSmallFile(path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const n = file.read(buf) catch return null;
    if (n == 0) return null;
    return buf[0..n];
}

/// Try each candidate controller mount directory in turn, reading the named
/// file under `<root>/<dir><subpath>/<filename>`. Returns the first readable
/// content, or null when none exist.
fn readV1ControllerFile(
    root: []const u8,
    path_buf: []u8,
    val_buf: []u8,
    dir_candidates: []const []const u8,
    subpath: []const u8,
    filename: []const u8,
) ?[]const u8 {
    for (dir_candidates) |dir| {
        const path = std.fmt.bufPrint(path_buf, "{s}/{s}{s}/{s}", .{ root, dir, subpath, filename }) catch continue;
        if (readSmallFile(path, val_buf)) |content| return content;
    }
    return null;
}

// =============================================================================
// Pure parse helpers
// =============================================================================

const Quota = struct { quota: i64, period: i64 };

/// Parse a cgroup v2 `cpu.max` value of the form "$quota $period". A quota of
/// the literal "max" means no limit and yields null, as does any unparseable or
/// non-positive value.
fn parseCpuMaxV2(content: []const u8) ?Quota {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
    const quota_tok = it.next() orelse return null;
    const period_tok = it.next() orelse return null;
    if (std.mem.eql(u8, quota_tok, "max")) return null;
    const quota = std.fmt.parseInt(i64, quota_tok, 10) catch return null;
    const period = std.fmt.parseInt(i64, period_tok, 10) catch return null;
    if (quota <= 0 or period <= 0) return null;
    return .{ .quota = quota, .period = period };
}

/// Parse a cgroup v1 `cpu.cfs_quota_us` value. A value of -1 means no quota and
/// yields null.
fn parseCfsQuotaV1(content: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    const v = std.fmt.parseInt(i64, trimmed, 10) catch return null;
    if (v <= 0) return null;
    return v;
}

/// Parse a cgroup v1 `cpu.cfs_period_us` value. Non-positive or unparseable
/// values yield null.
fn parseCfsPeriodV1(content: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    const v = std.fmt.parseInt(i64, trimmed, 10) catch return null;
    if (v <= 0) return null;
    return v;
}

/// The cgroup v1 "no limit" sentinel for memory.limit_in_bytes: i64 max rounded
/// down to a page boundary (0x7FFFFFFFFFFFF000). Values at or above this mean
/// no limit is set.
const mem_no_limit_threshold: u64 = @as(u64, std.math.maxInt(i64)) - 4095;

/// Parse a cgroup memory limit (v2 `memory.max` or v1 `memory.limit_in_bytes`).
/// The cgroup v2 literal "max", a zero value, the v1 no-limit sentinel, and any
/// unparseable input all yield null.
fn parseMemLimit(content: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "max")) return null;
    const v = std.fmt.parseInt(u64, trimmed, 10) catch return null;
    if (v == 0) return null;
    if (v >= mem_no_limit_threshold) return null;
    return v;
}

/// Extract the cgroup path from a cgroup v2 `/proc/self/cgroup`, whose single
/// entry has the form "0::<path>".
fn parseProcCgroupV2(content: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "0::")) {
            return std.mem.trim(u8, line["0::".len..], " \t\r");
        }
    }
    return null;
}

/// Extract the cgroup path for a named controller from a cgroup v1
/// `/proc/self/cgroup`, whose entries have the form
/// "hierarchy-id:controller-list:cgroup-path".
fn parseProcCgroupV1(content: []const u8, controller: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const first = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const rest = line[first + 1 ..];
        const second = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
        const ctrl_list = rest[0..second];
        const path = rest[second + 1 ..];
        var ctrls = std.mem.tokenizeScalar(u8, ctrl_list, ',');
        while (ctrls.next()) |c| {
            if (std.mem.eql(u8, c, controller)) {
                return std.mem.trim(u8, path, " \t\r");
            }
        }
    }
    return null;
}

/// Convert a CPU bandwidth quota/period pair into a worker count by rounding
/// `quota / period` up to the nearest integer and clamping to at least 1.
fn cpusFromQuota(quota: i64, period: i64) usize {
    if (quota <= 0 or period <= 0) return 1;
    const q: u64 = @intCast(quota);
    const p: u64 = @intCast(period);
    const cpus = (q + p - 1) / p;
    return if (cpus < 1) 1 else @intCast(cpus);
}

// =============================================================================
// Trace output
// =============================================================================

/// Print one container-detection diagnostic line to stderr.
fn traceLine(comptime fmt: []const u8, args: anytype) void {
    var tw = trace.TraceWriter.init();
    tw.print("CONTAINER detect: " ++ fmt ++ "\n", args);
}

// =============================================================================
// Tests
// =============================================================================

test "parseCpuMaxV2: explicit quota and period" {
    const q = parseCpuMaxV2("200000 100000").?;
    try std.testing.expectEqual(@as(i64, 200000), q.quota);
    try std.testing.expectEqual(@as(i64, 100000), q.period);
}

test "parseCpuMaxV2: trailing newline" {
    const q = parseCpuMaxV2("100000 100000\n").?;
    try std.testing.expectEqual(@as(i64, 100000), q.quota);
    try std.testing.expectEqual(@as(i64, 100000), q.period);
}

test "parseCpuMaxV2: max means no limit" {
    try std.testing.expectEqual(@as(?Quota, null), parseCpuMaxV2("max 100000"));
}

test "parseCpuMaxV2: invalid input" {
    try std.testing.expectEqual(@as(?Quota, null), parseCpuMaxV2(""));
    try std.testing.expectEqual(@as(?Quota, null), parseCpuMaxV2("100000"));
    try std.testing.expectEqual(@as(?Quota, null), parseCpuMaxV2("abc def"));
    try std.testing.expectEqual(@as(?Quota, null), parseCpuMaxV2("0 100000"));
}

test "parseCfsQuotaV1: positive and no-limit" {
    try std.testing.expectEqual(@as(?i64, 50000), parseCfsQuotaV1("50000"));
    try std.testing.expectEqual(@as(?i64, null), parseCfsQuotaV1("-1"));
    try std.testing.expectEqual(@as(?i64, null), parseCfsQuotaV1("abc"));
}

test "parseCfsPeriodV1: positive" {
    try std.testing.expectEqual(@as(?i64, 100000), parseCfsPeriodV1("100000\n"));
    try std.testing.expectEqual(@as(?i64, null), parseCfsPeriodV1("0"));
}

test "parseMemLimit: explicit bytes" {
    try std.testing.expectEqual(@as(?u64, 104857600), parseMemLimit("104857600"));
    try std.testing.expectEqual(@as(?u64, 4 * 1024 * 1024 * 1024), parseMemLimit("4294967296\n"));
}

test "parseMemLimit: unlimited and sentinels" {
    try std.testing.expectEqual(@as(?u64, null), parseMemLimit("max"));
    try std.testing.expectEqual(@as(?u64, null), parseMemLimit("0"));
    try std.testing.expectEqual(@as(?u64, null), parseMemLimit("9223372036854771712"));
    try std.testing.expectEqual(@as(?u64, null), parseMemLimit("abc"));
}

test "parseProcCgroupV2: extracts path" {
    try std.testing.expectEqualStrings("/foo/bar", parseProcCgroupV2("0::/foo/bar\n").?);
    try std.testing.expectEqualStrings("/", parseProcCgroupV2("0::/\n").?);
}

test "parseProcCgroupV2: v1-only content yields null" {
    try std.testing.expectEqual(@as(?[]const u8, null), parseProcCgroupV2("12:cpu,cpuacct:/docker/abc\n"));
}

test "parseProcCgroupV1: matches controller in list" {
    const content = "12:cpu,cpuacct:/docker/abc\n11:memory:/docker/xyz\n";
    try std.testing.expectEqualStrings("/docker/abc", parseProcCgroupV1(content, "cpu").?);
    try std.testing.expectEqualStrings("/docker/abc", parseProcCgroupV1(content, "cpuacct").?);
    try std.testing.expectEqualStrings("/docker/xyz", parseProcCgroupV1(content, "memory").?);
}

test "parseProcCgroupV1: missing controller yields null" {
    const content = "12:cpu,cpuacct:/docker/abc\n";
    try std.testing.expectEqual(@as(?[]const u8, null), parseProcCgroupV1(content, "blkio"));
}

test "cpusFromQuota: rounds up and clamps" {
    try std.testing.expectEqual(@as(usize, 2), cpusFromQuota(200000, 100000));
    try std.testing.expectEqual(@as(usize, 1), cpusFromQuota(20000, 100000)); // 0.2 -> 1
    try std.testing.expectEqual(@as(usize, 2), cpusFromQuota(150000, 100000)); // 1.5 -> 2
    try std.testing.expectEqual(@as(usize, 3), cpusFromQuota(250000, 100000)); // 2.5 -> 3
    try std.testing.expectEqual(@as(usize, 1), cpusFromQuota(100000, 100000));
    try std.testing.expectEqual(@as(usize, 1), cpusFromQuota(-1, 100000));
}

test "detect orchestration: cgroup v2 leaf files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("mygroup");
    try tmp.dir.writeFile(.{ .sub_path = "mygroup/cpu.max", .data = "200000 100000\n" });
    try tmp.dir.writeFile(.{ .sub_path = "mygroup/memory.max", .data = "4294967296\n" });
    try tmp.dir.writeFile(.{ .sub_path = "proc_cgroup", .data = "0::/mygroup\n" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const proc = try tmp.dir.realpathAlloc(std.testing.allocator, "proc_cgroup");
    defer std.testing.allocator.free(proc);
    const roots = Roots{ .cgroup = root, .proc_cgroup = proc };

    const cpu = detectCpuQuotaLinux(roots, false).?;
    try std.testing.expectEqual(CpuSource.cgroup_v2, cpu.source);
    try std.testing.expectEqual(@as(i64, 200000), cpu.quota);
    try std.testing.expectEqual(@as(i64, 100000), cpu.period);

    const mem = detectMemoryLinux(roots, false).?;
    try std.testing.expectEqual(MemorySource.cgroup_v2, mem.source);
    try std.testing.expectEqual(@as(usize, 4294967296), mem.cap);
}

test "detect orchestration: cgroup v1 per-controller files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cpu,cpuacct/docker/abc");
    try tmp.dir.writeFile(.{ .sub_path = "cpu,cpuacct/docker/abc/cpu.cfs_quota_us", .data = "50000\n" });
    try tmp.dir.writeFile(.{ .sub_path = "cpu,cpuacct/docker/abc/cpu.cfs_period_us", .data = "100000\n" });
    try tmp.dir.makePath("memory/docker/xyz");
    try tmp.dir.writeFile(.{ .sub_path = "memory/docker/xyz/memory.limit_in_bytes", .data = "104857600\n" });
    try tmp.dir.writeFile(.{ .sub_path = "proc_cgroup", .data = "12:cpu,cpuacct:/docker/abc\n11:memory:/docker/xyz\n" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const proc = try tmp.dir.realpathAlloc(std.testing.allocator, "proc_cgroup");
    defer std.testing.allocator.free(proc);
    const roots = Roots{ .cgroup = root, .proc_cgroup = proc };

    const cpu = detectCpuQuotaLinux(roots, false).?;
    try std.testing.expectEqual(CpuSource.cgroup_v1, cpu.source);
    try std.testing.expectEqual(@as(i64, 50000), cpu.quota);
    try std.testing.expectEqual(@as(i64, 100000), cpu.period);

    const mem = detectMemoryLinux(roots, false).?;
    try std.testing.expectEqual(MemorySource.cgroup_v1, mem.source);
    try std.testing.expectEqual(@as(usize, 104857600), mem.cap);
}

test "detect orchestration: bare host with no cgroup file" {
    const roots = Roots{ .cgroup = "/nonexistent/cgroup/root", .proc_cgroup = "/nonexistent/proc/cgroup" };
    try std.testing.expectEqual(@as(?CpuQuota, null), detectCpuQuotaLinux(roots, false));
    try std.testing.expectEqual(@as(?MemoryDetection, null), detectMemoryLinux(roots, false));
}
