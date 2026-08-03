const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Quotation = value_mod.Quotation;
const Context = @import("context.zig").Context;
const container_backing = @import("container_backing.zig");

pub const Iterator = struct {
    header: container_backing.ContainerHeader,
    kind: Kind,

    pub const Kind = union(enum) {
        array: ArrayIter,
        range: RangeIter,
        map: MapIter,
        filter: FilterIter,
        take: TakeIter,
        drop: DropIter,
        callback: CallbackIter,
    };

    pub fn create(allocator: std.mem.Allocator, kind: Kind) error{OutOfMemory}!*Iterator {
        const self = try allocator.create(Iterator);
        self.* = .{ .header = undefined, .kind = kind };
        self.header.init(allocator, destroyIterator);
        return self;
    }

    /// Release-to-zero callback. Frees memory only; it never executes user code, so a callback
    /// iterator's cleanup quotation still runs only via `close-iterator` or exhaustion.
    ///
    /// An `.array` kind with no source array owns its materialized slice; the slice must be
    /// allocated on the same allocator as the iterator. Its element string dupes are arena-owned
    /// and outlive the iterator, so any yielded string a consumer still holds stays valid.
    fn destroyIterator(header: *container_backing.ContainerHeader) void {
        const self: *Iterator = @fieldParentPtr("header", header);
        switch (self.kind) {
            .array => |ai| if (ai.source) |arr| arr.header.release() else {
                for (ai.items) |item| {
                    container_backing.releaseValue(item);
                }
                header.allocator.free(ai.items);
            },
            .map => |it| it.inner.header.release(),
            .filter => |it| it.inner.header.release(),
            .take => |it| it.inner.header.release(),
            .drop => |it| it.inner.header.release(),
            .range, .callback => {},
        }
        header.allocator.destroy(self);
    }

    pub fn next(self: *Iterator, ctx: *Context) anyerror!?Value {
        return switch (self.kind) {
            .array => |*it| it.next(),
            .range => |*it| it.next(),
            .map => |*it| try it.next(ctx),
            .filter => |*it| try it.next(ctx),
            .take => |*it| try it.next(ctx),
            .drop => |*it| try it.next(ctx),
            .callback => |*it| try it.next(ctx),
        };
    }

    pub fn close(self: *Iterator, ctx: *Context) anyerror!void {
        switch (self.kind) {
            .map => |it| try it.inner.close(ctx),
            .filter => |it| try it.inner.close(ctx),
            .take => |it| try it.inner.close(ctx),
            .drop => |it| try it.inner.close(ctx),
            .callback => |*it| {
                if (it.cleanup_quotation) |cq| {
                    if (!it.cleanup_ran) {
                        it.cleanup_ran = true;
                        it.exhausted = true;
                        try ctx.executeQuotationWithFrame(cq);
                    }
                }
            },
            .array, .range => {},
        }
    }

    pub fn kindName(self: *const Iterator) []const u8 {
        return switch (self.kind) {
            .array => "array",
            .range => "range",
            .map => "map",
            .filter => "filter",
            .take => "take",
            .drop => "drop",
            .callback => "callback",
        };
    }

    pub fn progressDisplay(self: *const Iterator, writer: anytype) !void {
        switch (self.kind) {
            .array => |it| try writer.print("{d}/{d}", .{ it.index, it.items.len }),
            .range => |it| {
                if (it.infinite)
                    try writer.print("{d}/inf", .{it.current})
                else
                    try writer.print("{d}..{d} step {d}", .{ it.current, it.end, it.step });
            },
            .map => |it| {
                try writer.writeAll("map(");
                try it.inner.progressDisplay(writer);
                try writer.writeAll(")");
            },
            .filter => |it| {
                try writer.writeAll("filter(");
                try it.inner.progressDisplay(writer);
                try writer.writeAll(")");
            },
            .take => |it| {
                try writer.print("take({d}, ", .{it.remaining});
                try it.inner.progressDisplay(writer);
                try writer.writeAll(")");
            },
            .drop => |it| {
                try writer.writeAll("drop(");
                try it.inner.progressDisplay(writer);
                try writer.writeAll(")");
            },
            .callback => try writer.writeAll("callback"),
        }
    }
};

pub const ArrayIter = struct {
    items: []const Value,
    index: usize,

    /// Set when the iterator walks a headered array's backing: the iterator holds one reference on
    /// the array's header, which keeps both the elements and the slice memory alive. Null for
    /// slices materialized from other sequence types, which the iterator owns outright: one element
    /// reference apiece, and the slice memory itself, both dropped at destroy.
    source: ?*value_mod.Array = null,

    pub fn next(self: *ArrayIter) ?Value {
        if (self.index >= self.items.len) return null;
        const val = self.items[self.index];
        self.index += 1;
        // A leaf array iterator hands out an owning reference: the element also
        // lives in the iterator's backing, so retain it so the consumer's
        // release balances against this yield rather than the backing.
        container_backing.retainValue(val);
        return val;
    }
};

pub const RangeIter = struct {
    current: i64,
    end: i64,
    step: i64,
    infinite: bool,

    pub fn next(self: *RangeIter) ?Value {
        if (self.infinite) {
            const val = self.current;
            self.current +%= self.step;
            return .{ .fixnum = val };
        }
        if (self.step > 0) {
            if (self.current >= self.end) return null;
        } else {
            if (self.current <= self.end) return null;
        }
        const val = self.current;
        self.current +%= self.step;
        return .{ .fixnum = val };
    }
};

pub const MapIter = struct {
    inner: *Iterator,
    quotation: Quotation,

    pub fn next(self: *MapIter, ctx: *Context) anyerror!?Value {
        const elem = try self.inner.next(ctx) orelse return null;
        // The inner element is owned; the quotation output we return is a
        // separate owned reference, so release the consumed input here.
        defer container_backing.releaseValue(elem);
        try ctx.stack.push(elem);
        try ctx.executeQuotationWithFrame(self.quotation);
        return try ctx.stack.pop();
    }
};

pub const FilterIter = struct {
    inner: *Iterator,
    quotation: Quotation,

    pub fn next(self: *FilterIter, ctx: *Context) anyerror!?Value {
        while (try self.inner.next(ctx)) |elem| {
            try ctx.stack.push(elem);
            try ctx.executeQuotationWithFrame(self.quotation);
            const result = try ctx.stack.pop();
            const keep = result != .boolean or result.boolean;
            // The inner element is owned. Keeping forwards that ownership to the
            // consumer; rejecting drops it here.
            if (keep) return elem;
            container_backing.releaseValue(elem);
        }
        return null;
    }
};

pub const TakeIter = struct {
    inner: *Iterator,
    remaining: usize,

    pub fn next(self: *TakeIter, ctx: *Context) anyerror!?Value {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        return try self.inner.next(ctx);
    }
};

pub const DropIter = struct {
    inner: *Iterator,
    to_skip: usize,

    pub fn next(self: *DropIter, ctx: *Context) anyerror!?Value {
        while (self.to_skip > 0) {
            self.to_skip -= 1;
            // Skipped elements are owned yields; drop them rather than leak.
            const skipped = try self.inner.next(ctx) orelse return null;
            container_backing.releaseValue(skipped);
        }
        return try self.inner.next(ctx);
    }
};

pub const CallbackIter = struct {
    quotation: Quotation,
    exhausted: bool,
    cleanup_quotation: ?Quotation,
    cleanup_ran: bool,

    pub fn next(self: *CallbackIter, ctx: *Context) anyerror!?Value {
        if (self.exhausted) return null;
        try ctx.executeQuotationWithFrame(self.quotation);
        const flag = try ctx.stack.pop();
        const is_true = flag != .boolean or flag.boolean;
        if (is_true) {
            return try ctx.stack.pop();
        } else {
            self.exhausted = true;
            if (self.cleanup_quotation) |cq| {
                if (!self.cleanup_ran) {
                    self.cleanup_ran = true;
                    try ctx.executeQuotationWithFrame(cq);
                }
            }
            return null;
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ArrayIter advances through elements" {
    const items = &[_]Value{ .{ .fixnum = 10 }, .{ .fixnum = 20 }, .{ .fixnum = 30 } };
    var it = ArrayIter{ .items = items, .index = 0 };

    try std.testing.expectEqual(@as(i64, 10), it.next().?.fixnum);
    try std.testing.expectEqual(@as(i64, 20), it.next().?.fixnum);
    try std.testing.expectEqual(@as(i64, 30), it.next().?.fixnum);
    try std.testing.expect(it.next() == null);
    try std.testing.expect(it.next() == null);
}

test "ArrayIter on empty array returns null immediately" {
    var it = ArrayIter{ .items = &.{}, .index = 0 };
    try std.testing.expect(it.next() == null);
}

test "Iterator kindName returns correct name" {
    const iter = Iterator{ .header = undefined, .kind = .{ .array = .{ .items = &.{}, .index = 0 } } };
    try std.testing.expectEqualStrings("array", iter.kindName());
}

test "RangeIter ascending exclusive" {
    var it = RangeIter{ .current = 1, .end = 5, .step = 1, .infinite = false };
    try std.testing.expectEqual(@as(i64, 1), it.next().?.fixnum);
    try std.testing.expectEqual(@as(i64, 2), it.next().?.fixnum);
    try std.testing.expectEqual(@as(i64, 3), it.next().?.fixnum);
    try std.testing.expectEqual(@as(i64, 4), it.next().?.fixnum);
    try std.testing.expect(it.next() == null);
}

test "RangeIter descending exclusive" {
    var it = RangeIter{ .current = 5, .end = 1, .step = -1, .infinite = false };
    try std.testing.expectEqual(@as(i64, 5), it.next().?.fixnum);
    try std.testing.expectEqual(@as(i64, 4), it.next().?.fixnum);
    try std.testing.expectEqual(@as(i64, 3), it.next().?.fixnum);
    try std.testing.expectEqual(@as(i64, 2), it.next().?.fixnum);
    try std.testing.expect(it.next() == null);
}

test "RangeIter stepped" {
    var it = RangeIter{ .current = 1, .end = 10, .step = 3, .infinite = false };
    try std.testing.expectEqual(@as(i64, 1), it.next().?.fixnum);
    try std.testing.expectEqual(@as(i64, 4), it.next().?.fixnum);
    try std.testing.expectEqual(@as(i64, 7), it.next().?.fixnum);
    try std.testing.expect(it.next() == null);
}

test "RangeIter empty when start equals end" {
    var it = RangeIter{ .current = 5, .end = 5, .step = 1, .infinite = false };
    try std.testing.expect(it.next() == null);
}

test "RangeIter kindName returns range" {
    const iter = Iterator{ .header = undefined, .kind = .{ .range = .{ .current = 0, .end = 10, .step = 1, .infinite = false } } };
    try std.testing.expectEqualStrings("range", iter.kindName());
}

test "ArrayIter yields an owned reference for refcounted elements" {
    const Vector = value_mod.Vector;
    const vec = try Vector.create(std.testing.allocator);
    // Creation leaves refcount=1; the backing slice below is that one owner.
    const items = [_]Value{.{ .vector = vec }};
    var it = ArrayIter{ .items = &items, .index = 0 };

    const yielded = it.next().?;
    // next retains, so the consumer holds a second owning reference.
    try std.testing.expectEqual(@as(u32, 2), vec.header.refcountValue());

    // The consumer releases its owned yield.
    container_backing.releaseValue(yielded);
    try std.testing.expectEqual(@as(u32, 1), vec.header.refcountValue());

    try std.testing.expect(it.next() == null);

    // Release the backing's reference; last drop destroys the vector.
    container_backing.releaseValue(.{ .vector = vec });
}
