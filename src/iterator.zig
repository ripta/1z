const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Quotation = value_mod.Quotation;
const Context = @import("context.zig").Context;

pub const Iterator = struct {
    kind: Kind,

    pub const Kind = union(enum) {
        array: ArrayIter,
        map: MapIter,
        filter: FilterIter,
        take: TakeIter,
        drop: DropIter,
    };

    pub fn next(self: *Iterator, ctx: *Context) anyerror!?Value {
        return switch (self.kind) {
            .array => |*it| it.next(),
            .map => |*it| try it.next(ctx),
            .filter => |*it| try it.next(ctx),
            .take => |*it| try it.next(ctx),
            .drop => |*it| try it.next(ctx),
        };
    }

    pub fn kindName(self: *const Iterator) []const u8 {
        return switch (self.kind) {
            .array => "array",
            .map => "map",
            .filter => "filter",
            .take => "take",
            .drop => "drop",
        };
    }

    pub fn progressDisplay(self: *const Iterator, writer: anytype) !void {
        switch (self.kind) {
            .array => |it| try writer.print("{d}/{d}", .{ it.index, it.items.len }),
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
        }
    }
};

pub const ArrayIter = struct {
    items: []const Value,
    index: usize,

    pub fn next(self: *ArrayIter) ?Value {
        if (self.index >= self.items.len) return null;
        const val = self.items[self.index];
        self.index += 1;
        return val;
    }
};

pub const MapIter = struct {
    inner: *Iterator,
    quotation: Quotation,

    pub fn next(self: *MapIter, ctx: *Context) anyerror!?Value {
        const elem = try self.inner.next(ctx) orelse return null;
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
            if (keep) return elem;
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
            _ = try self.inner.next(ctx) orelse return null;
        }
        return try self.inner.next(ctx);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ArrayIter advances through elements" {
    const items = &[_]Value{ .{ .integer = 10 }, .{ .integer = 20 }, .{ .integer = 30 } };
    var it = ArrayIter{ .items = items, .index = 0 };

    try std.testing.expectEqual(@as(i64, 10), it.next().?.integer);
    try std.testing.expectEqual(@as(i64, 20), it.next().?.integer);
    try std.testing.expectEqual(@as(i64, 30), it.next().?.integer);
    try std.testing.expect(it.next() == null);
    try std.testing.expect(it.next() == null);
}

test "ArrayIter on empty array returns null immediately" {
    var it = ArrayIter{ .items = &.{}, .index = 0 };
    try std.testing.expect(it.next() == null);
}

test "Iterator kindName returns correct name" {
    const iter = Iterator{ .kind = .{ .array = .{ .items = &.{}, .index = 0 } } };
    try std.testing.expectEqualStrings("array", iter.kindName());
}
