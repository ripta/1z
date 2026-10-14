const std = @import("std");
const Allocator = std.mem.Allocator;

const container_backing = @import("container_backing.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;

/// How an annotated call treats a mismatched input, as the `type-check` pragma sets it.
pub const TypeCheckMode = enum { err, warning, off };

/// The `type-check` mode a pragma value selects. Unset and unrecognized values check.
pub fn typeCheckModeOf(value: ?Value) TypeCheckMode {
    const v = value orelse return .err;
    if (v != .string) return .err;
    if (std.mem.eql(u8, v.string.bytes, "off")) return .off;
    if (std.mem.eql(u8, v.string.bytes, "warning")) return .warning;
    return .err;
}

/// Every pragma visible at one pragma frame level, flattened into one map, with the `type-check`
/// mode precomputed.
///
/// A view is immutable once published. Setting a pragma builds a new view with `withValue`, so a
/// holder never sees a view change under it. A frame push shares the view below by retaining it,
/// and a pop only releases, so neither can leave a level without a view.
///
/// The view owns copies of its keys and one reference to each value, so it can outlive the frame
/// whose write produced it. The refcount is atomic because holders may release on different threads.
pub const PragmaView = struct {
    refcount: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    allocator: Allocator,
    values: std.StringHashMapUnmanaged(Value) = .{},
    type_check: TypeCheckMode = .err,

    pub fn createEmpty(allocator: Allocator) !*PragmaView {
        const view = try allocator.create(PragmaView);
        view.* = .{ .allocator = allocator };
        return view;
    }

    /// A new view holding everything in `self` plus `name` set to `value`. `self` is unchanged, and
    /// `value` is retained, not consumed.
    pub fn withValue(self: *const PragmaView, name: []const u8, value: Value) !*PragmaView {
        const view = try createEmpty(self.allocator);
        errdefer view.release();

        try view.values.ensureTotalCapacity(view.allocator, self.values.count() + 1);

        var it = self.values.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) continue;
            const key = try view.allocator.dupe(u8, entry.key_ptr.*);
            container_backing.retainValue(entry.value_ptr.*);
            view.values.putAssumeCapacityNoClobber(key, entry.value_ptr.*);
        }

        const key = try view.allocator.dupe(u8, name);
        container_backing.retainValue(value);
        view.values.putAssumeCapacityNoClobber(key, value);

        view.type_check = typeCheckModeOf(view.values.get("type-check"));
        return view;
    }

    pub fn get(self: *const PragmaView, name: []const u8) ?Value {
        return self.values.get(name);
    }

    pub fn retain(self: *PragmaView) void {
        _ = self.refcount.fetchAdd(1, .monotonic);
    }

    /// Drop one reference. The last drop releases every value and frees the keys and the view.
    ///
    /// `.acq_rel` on the decrement makes every other holder's reads happen before the free.
    pub fn release(self: *PragmaView) void {
        const prev = self.refcount.fetchSub(1, .acq_rel);
        std.debug.assert(prev != 0);
        if (prev != 1) return;

        var it = self.values.iterator();
        while (it.next()) |entry| {
            container_backing.releaseValue(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }

        self.values.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

test "an empty view has no values and checks types" {
    const view = try PragmaView.createEmpty(std.testing.allocator);
    defer view.release();

    try std.testing.expectEqual(@as(u32, 0), view.values.count());
    try std.testing.expect(view.get("type-check") == null);
    try std.testing.expectEqual(TypeCheckMode.err, view.type_check);
}

test "withValue adds a key and leaves the source view unchanged" {
    const empty = try PragmaView.createEmpty(std.testing.allocator);
    defer empty.release();

    const one = try empty.withValue("x-debug", .{ .boolean = true });
    defer one.release();

    try std.testing.expect(empty.get("x-debug") == null);
    try std.testing.expect(one.get("x-debug").?.boolean);

    const two = try one.withValue("x-level", .{ .fixnum = 3 });
    defer two.release();

    try std.testing.expectEqual(@as(u32, 1), one.values.count());
    try std.testing.expectEqual(@as(u32, 2), two.values.count());
    try std.testing.expect(two.get("x-debug").?.boolean);
    try std.testing.expectEqual(@as(i64, 3), two.get("x-level").?.fixnum);
}

test "withValue overwrites a key in the new view only" {
    const empty = try PragmaView.createEmpty(std.testing.allocator);
    defer empty.release();

    const first = try empty.withValue("x-level", .{ .fixnum = 1 });
    defer first.release();

    const second = try first.withValue("x-level", .{ .fixnum = 2 });
    defer second.release();

    try std.testing.expectEqual(@as(u32, 1), second.values.count());
    try std.testing.expectEqual(@as(i64, 1), first.get("x-level").?.fixnum);
    try std.testing.expectEqual(@as(i64, 2), second.get("x-level").?.fixnum);
}

test "the type-check mode follows the pragma value" {
    const empty = try PragmaView.createEmpty(std.testing.allocator);
    defer empty.release();

    const off = try empty.withValue("type-check", value_mod.stringValue("off"));
    defer off.release();
    try std.testing.expectEqual(TypeCheckMode.off, off.type_check);

    const warning = try off.withValue("type-check", value_mod.stringValue("warning"));
    defer warning.release();
    try std.testing.expectEqual(TypeCheckMode.warning, warning.type_check);

    const err = try warning.withValue("type-check", value_mod.stringValue("error"));
    defer err.release();
    try std.testing.expectEqual(TypeCheckMode.err, err.type_check);

    const other = try off.withValue("type-check", .{ .boolean = true });
    defer other.release();
    try std.testing.expectEqual(TypeCheckMode.err, other.type_check);

    // Setting an unrelated key carries the mode forward.
    const carried = try off.withValue("x-debug", .{ .boolean = true });
    defer carried.release();
    try std.testing.expectEqual(TypeCheckMode.off, carried.type_check);
}

test "a shared view is freed on its last release" {
    const empty = try PragmaView.createEmpty(std.testing.allocator);
    defer empty.release();

    const view = try empty.withValue("x-debug", .{ .boolean = true });
    view.retain();
    try std.testing.expectEqual(@as(u32, 2), view.refcount.load(.monotonic));

    view.release();
    try std.testing.expect(view.get("x-debug").?.boolean);

    // The testing allocator reports a leak if this last release does not free the keys and view.
    view.release();
}
