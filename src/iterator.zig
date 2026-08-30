const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Quotation = value_mod.Quotation;
const Callable = @import("callable.zig").Callable;
const Context = @import("context.zig").Context;
const container_backing = @import("container_backing.zig");
const packed_kernels = @import("packed.zig");

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
        packed_elems: PackedIter,
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
            .map => |it| {
                it.inner.header.release();
                it.callable.release();
            },
            .filter => |it| {
                it.inner.header.release();
                it.callable.release();
            },
            .take => |it| it.inner.header.release(),
            .drop => |it| it.inner.header.release(),
            .callback => |it| {
                it.callable.release();
                if (it.cleanup) |c| c.release();
            },
            .packed_elems => |it| {
                it.source.header.release();
                if (it.recognized) |rec| header.allocator.free(rec.chain);
            },
            .range => {},
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
            .packed_elems => |*it| try it.next(ctx),
        };
    }

    pub fn close(self: *Iterator, ctx: *Context) anyerror!void {
        switch (self.kind) {
            .map => |it| try it.inner.close(ctx),
            .filter => |it| try it.inner.close(ctx),
            .take => |it| try it.inner.close(ctx),
            .drop => |it| try it.inner.close(ctx),
            .callback => |*it| {
                if (it.cleanup) |cleanup| {
                    if (!it.cleanup_ran) {
                        it.cleanup_ran = true;
                        it.exhausted = true;
                        try cleanup.executeWithFrame(ctx);
                    }
                }
            },
            .array, .range, .packed_elems => {},
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
            .packed_elems => "packed",
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
            .packed_elems => |it| try writer.print("{d}/{d}", .{ it.index, it.elemCount() }),
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
    /// Owned: released at destroy, so a closure body stays alive across the
    /// lazy drain. A plain quotation's release is inert.
    callable: Callable,

    pub fn next(self: *MapIter, ctx: *Context) anyerror!?Value {
        const elem = try self.inner.next(ctx) orelse return null;
        // The inner element is owned; the quotation output we return is a
        // separate owned reference, so release the consumed input here.
        defer container_backing.releaseValue(elem);
        try ctx.stack.push(elem);
        try self.callable.executeWithFrame(ctx);
        return try ctx.stack.pop();
    }
};

pub const FilterIter = struct {
    inner: *Iterator,
    /// Owned; see `MapIter.callable`.
    callable: Callable,

    pub fn next(self: *FilterIter, ctx: *Context) anyerror!?Value {
        while (try self.inner.next(ctx)) |elem| {
            try ctx.stack.push(elem);
            try self.callable.executeWithFrame(ctx);
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
    /// Both owned; see `MapIter.callable`.
    callable: Callable,
    exhausted: bool,
    cleanup: ?Callable,
    cleanup_ran: bool,

    pub fn next(self: *CallbackIter, ctx: *Context) anyerror!?Value {
        if (self.exhausted) return null;
        try self.callable.executeWithFrame(ctx);
        const flag = try ctx.stack.pop();
        const is_true = flag != .boolean or flag.boolean;
        if (is_true) {
            return try ctx.stack.pop();
        } else {
            self.exhausted = true;
            if (self.cleanup) |cleanup| {
                if (!self.cleanup_ran) {
                    self.cleanup_ran = true;
                    try cleanup.executeWithFrame(ctx);
                }
            }
            return null;
        }
    }
};

pub const PackedIter = struct {
    /// One SIMD chunk of either float element type; the wider of the two widths.
    pub const chain_buf_cap = @max(packed_kernels.chainChunkLen(f32), packed_kernels.chainChunkLen(f64));

    /// A recognized arithmetic quotation and what recognition assumed about it. The three
    /// travel together so that a chain can never exist without the body it stands in for,
    /// which is what a retired chain hands the rest of the drain to.
    pub const Recognized = struct {
        /// Applied chunk-by-chunk as the iterator drains. Built only for `.f32` and `.f64`
        /// element types, the invariant the recognizer enforces. Owned: allocated on the
        /// iterator's allocator, freed at destroy.
        chain: []const packed_kernels.ChainOp,

        /// The dispatch generation recognition ran under. A method registered afterwards
        /// bumps it, which retires the chain, so a method the kernel cannot honor is
        /// honored by `quotation` anyway.
        ///
        /// Registration is all this catches. Redefining an arithmetic word does not bump
        /// the generation, and noticing one would need a by-name dispatch resolution per
        /// element, which costs more than the vectorization saves.
        dispatch_generation: u32,

        /// The body the chain was matched from. It needs no owning reference: `nativeMap`
        /// recognizes only a plain quotation, whose body outlives the iterator.
        quotation: Quotation,
    };

    /// The iterator holds one reference on the byte-array's header, dropped at destroy.
    ///
    /// `next` re-reads `source.slice()` and the element count on every call: an owned
    /// backing's `items` can be re-pointed or shrunk by `append`/`ensureTotalCapacity`,
    /// unlike `Array.items`, which is immutable after construction. A chained drain
    /// re-reads at the same points, one chunk at a time.
    source: *value_mod.ByteArray,
    elem_type: packed_kernels.ElementType,
    index: usize,

    /// Null for a plain element iterator, which is what `>iterator` builds.
    recognized: ?Recognized = null,
    buf: [chain_buf_cap]f64 = undefined,
    buf_len: usize = 0,
    buf_pos: usize = 0,

    /// Set once the generation guard fails, retiring the chain for the rest of this
    /// iterator's life. The chain stays allocated: `next` holds only the draining context's
    /// allocator, which need not be the one the iterator was created on.
    bailed: bool = false,

    fn elemCount(self: *const PackedIter) usize {
        return self.source.slice().len / self.elem_type.elemSize();
    }

    /// Retire the chain and rewind to the first element it computed but has not yielded.
    /// Those buffered elements came out of a kernel the guard has just disowned, so they
    /// are recomputed through the quotation rather than handed over.
    fn bail(self: *PackedIter) void {
        self.index -= self.buf_len - self.buf_pos;
        self.buf_len = 0;
        self.buf_pos = 0;
        self.bailed = true;
    }

    pub fn next(self: *PackedIter, ctx: *Context) anyerror!?Value {
        const rec = self.recognized orelse return self.nextElement(ctx.allocator);

        if (!self.bailed) {
            if (ctx.dispatch.generation == rec.dispatch_generation) return self.nextChained(rec.chain);
            self.bail();
        }

        const elem = try self.nextElement(ctx.allocator) orelse return null;

        // The element is owned; the quotation output returned in its place is a separate
        // owned reference, so release the consumed input here.
        defer container_backing.releaseValue(elem);
        try ctx.stack.push(elem);
        try ctx.executeQuotationWithFrame(rec.quotation);
        return try ctx.stack.pop();
    }

    fn nextElement(self: *PackedIter, allocator: std.mem.Allocator) error{OutOfMemory}!?Value {
        const bytes = self.source.slice();
        switch (self.elem_type) {
            inline else => |et| {
                const T = comptime et.toType();
                if (self.index >= packed_kernels.elementCount(T, bytes)) return null;
                const elem = packed_kernels.readElement(T, bytes, self.index);
                self.index += 1;
                // The element is freshly boxed, so the construction reference is the
                // yield; no retain is needed.
                return try value_mod.packedElementValue(T, allocator, elem);
            },
        }
    }

    /// Yield from the vectorized chunk buffer, computing the next chunk when it runs
    /// dry. Results are f64 in the buffer, so boxing allocates nothing; an f32 source
    /// computes in f32 and widens at buffer fill, the same widening the plain path
    /// applies at boxing.
    fn nextChained(self: *PackedIter, chain: []const packed_kernels.ChainOp) ?Value {
        if (self.buf_pos >= self.buf_len) {
            const bytes = self.source.slice();
            const produced = switch (self.elem_type) {
                .f32 => packed_kernels.applyChainChunk(f32, bytes, self.index, chain, &self.buf),
                .f64 => packed_kernels.applyChainChunk(f64, bytes, self.index, chain, &self.buf),
                else => unreachable,
            };
            if (produced == 0) return null;
            self.index += produced;
            self.buf_len = produced;
            self.buf_pos = 0;
        }
        const v = self.buf[self.buf_pos];
        self.buf_pos += 1;
        return .{ .float = v };
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

test "PackedIter walks an f64 backing and yields floats" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const ba = try value_mod.ByteArray.create(std.testing.allocator);
    defer container_backing.releaseValue(.{ .byte_array = ba });
    try ba.ensureTotalCapacity(std.testing.allocator, 3 * 8);
    ba.items.len = 3 * 8;
    packed_kernels.writeElement(f64, ba.items, 0, 1.5);
    packed_kernels.writeElement(f64, ba.items, 1, 2.5);
    packed_kernels.writeElement(f64, ba.items, 2, 3.5);

    var it = PackedIter{ .source = ba, .elem_type = .f64, .index = 0 };
    try std.testing.expectEqual(@as(f64, 1.5), (try it.next(&ctx)).?.float);
    try std.testing.expectEqual(@as(f64, 2.5), (try it.next(&ctx)).?.float);
    try std.testing.expectEqual(@as(f64, 3.5), (try it.next(&ctx)).?.float);
    try std.testing.expect(try it.next(&ctx) == null);
    try std.testing.expect(try it.next(&ctx) == null);
}

test "PackedIter on empty backing returns null immediately" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const ba = try value_mod.ByteArray.create(std.testing.allocator);
    defer container_backing.releaseValue(.{ .byte_array = ba });

    var it = PackedIter{ .source = ba, .elem_type = .f64, .index = 0 };
    try std.testing.expect(try it.next(&ctx) == null);
}

test "PackedIter boxes the u64 upper half as an owned bignum" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const ba = try value_mod.ByteArray.create(std.testing.allocator);
    defer container_backing.releaseValue(.{ .byte_array = ba });
    try ba.ensureTotalCapacity(std.testing.allocator, 2 * 8);
    ba.items.len = 2 * 8;
    packed_kernels.writeElement(u64, ba.items, 0, 7);
    packed_kernels.writeElement(u64, ba.items, 1, @as(u64, std.math.maxInt(i64)) + 1);

    var it = PackedIter{ .source = ba, .elem_type = .u64, .index = 0 };
    try std.testing.expectEqual(@as(i64, 7), (try it.next(&ctx)).?.fixnum);
    const big = (try it.next(&ctx)).?;
    try std.testing.expect(big == .bignum);
    container_backing.releaseValue(big);
    try std.testing.expect(try it.next(&ctx) == null);
}

test "PackedIter applies a chain across chunk boundaries" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const ba = try value_mod.ByteArray.create(std.testing.allocator);
    defer container_backing.releaseValue(.{ .byte_array = ba });
    const n = PackedIter.chain_buf_cap + 1;
    try ba.ensureTotalCapacity(std.testing.allocator, n * 8);
    ba.items.len = n * 8;
    for (0..n) |i| {
        packed_kernels.writeElement(f64, ba.items, i, @floatFromInt(i));
    }

    const chain = [_]packed_kernels.ChainOp{
        .{ .op = .mul, .scalar = 2.0 },
        .{ .op = .add, .scalar = 1.0 },
    };
    var it = PackedIter{ .source = ba, .elem_type = .f64, .index = 0, .recognized = .{
        .chain = &chain,
        .dispatch_generation = ctx.dispatch.generation,
        .quotation = .{ .instructions = &.{} },
    } };
    for (0..n) |i| {
        const expected: f64 = @as(f64, @floatFromInt(i)) * 2.0 + 1.0;
        try std.testing.expectEqual(expected, (try it.next(&ctx)).?.float);
    }
    try std.testing.expect(try it.next(&ctx) == null);
    try std.testing.expect(try it.next(&ctx) == null);
}

test "PackedIter chained f32 computes in f32 and widens" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const ba = try value_mod.ByteArray.create(std.testing.allocator);
    defer container_backing.releaseValue(.{ .byte_array = ba });
    try ba.ensureTotalCapacity(std.testing.allocator, 4);
    ba.items.len = 4;
    packed_kernels.writeElement(f32, ba.items, 0, 1.1);

    const chain = [_]packed_kernels.ChainOp{.{ .op = .mul, .scalar = 3.0 }};
    var it = PackedIter{ .source = ba, .elem_type = .f32, .index = 0, .recognized = .{
        .chain = &chain,
        .dispatch_generation = ctx.dispatch.generation,
        .quotation = .{ .instructions = &.{} },
    } };
    const expected: f32 = @as(f32, 1.1) * 3.0;
    try std.testing.expectEqual(@as(f64, @floatCast(expected)), (try it.next(&ctx)).?.float);
    try std.testing.expect(try it.next(&ctx) == null);
}

test "PackedIter chained on empty backing returns null immediately" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const ba = try value_mod.ByteArray.create(std.testing.allocator);
    defer container_backing.releaseValue(.{ .byte_array = ba });

    const chain = [_]packed_kernels.ChainOp{.{ .op = .add, .scalar = 1.0 }};
    var it = PackedIter{ .source = ba, .elem_type = .f64, .index = 0, .recognized = .{
        .chain = &chain,
        .dispatch_generation = ctx.dispatch.generation,
        .quotation = .{ .instructions = &.{} },
    } };
    try std.testing.expect(try it.next(&ctx) == null);
}

test "PackedIter bails the unyielded remainder when the dispatch generation changes" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const ba = try value_mod.ByteArray.create(std.testing.allocator);
    defer container_backing.releaseValue(.{ .byte_array = ba });
    const n = 4 * packed_kernels.chainChunkLen(f64);
    try ba.ensureTotalCapacity(std.testing.allocator, n * 8);
    ba.items.len = n * 8;
    for (0..n) |i| {
        packed_kernels.writeElement(f64, ba.items, i, @floatFromInt(i + 1));
    }

    // An empty body is the identity map, so a bailed element arrives as itself and a
    // chained one arrives doubled. That is what makes the handover point readable.
    const chain = [_]packed_kernels.ChainOp{.{ .op = .mul, .scalar = 2.0 }};
    var it = PackedIter{ .source = ba, .elem_type = .f64, .index = 0, .recognized = .{
        .chain = &chain,
        .dispatch_generation = ctx.dispatch.generation,
        .quotation = .{ .instructions = &.{} },
    } };

    try std.testing.expectEqual(@as(f64, 2.0), (try it.next(&ctx)).?.float);

    // One yield leaves the rest of the first chunk computed but unyielded, so the rewind is
    // what keeps those elements from being skipped or handed over doubled.
    ctx.dispatch.generation +%= 1;
    for (1..n) |i| {
        try std.testing.expectEqual(@as(f64, @floatFromInt(i + 1)), (try it.next(&ctx)).?.float);
    }
    try std.testing.expect(try it.next(&ctx) == null);
}

test "Iterator kindName returns packed" {
    const iter = Iterator{ .header = undefined, .kind = .{ .packed_elems = .{ .source = undefined, .elem_type = .f64, .index = 0 } } };
    try std.testing.expectEqualStrings("packed", iter.kindName());
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
