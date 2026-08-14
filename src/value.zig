const std = @import("std");

const context_mod = @import("context.zig");
const Context = context_mod.Context;

const StackEffect = @import("stack_effect.zig").StackEffect;
const StackEffectParam = @import("stack_effect.zig").StackEffectParam;

const Task = @import("task.zig").Task;
const Iterator = @import("iterator.zig").Iterator;
const Channel = @import("channel.zig").Channel;

const dictionary_mod = @import("dictionary.zig");
const HostCallback = dictionary_mod.HostCallback;
const NativeFn = dictionary_mod.NativeFn;
const WordProvenance = dictionary_mod.WordProvenance;
const WordSlot = @import("word_slot.zig").WordSlot;

const FfiSignature = @import("ffi/signature.zig").FfiSignature;
const simd = @import("simd.zig");

const types_mod = @import("primitives/types.zig");
const Capability = types_mod.Capability;
pub const SandboxSpec = types_mod.SandboxSpec;

pub const BigIntManaged = std.math.big.int.Managed;

/// Instruction represents a single operation in a compiled quotation.
///
/// The three call forms differ only in how much resolution they skip.
///
/// `call_word` runs the full resolution ladder. `call_word_direct` is the parser's pre-resolution,
/// emitted only for a name `preResolveCallTarget` proved cannot be shadowed by any frame or module,
/// so it resolves nothing. `call_word_module` is the AOT image's build-time resolution of a name in
/// the executing body's own module scope, so it still yields to a captured lexical scope but skips
/// every rung below that.
pub const Instruction = struct {
    op: Op,
    line: usize, // 1-based line number from source
    column: usize = 0, // 1-based column number from source

    pub const Op = union(enum) {
        push_literal: Value,
        call_word: []const u8,
        call_word_direct: *WordSlot,
        call_word_module: *WordSlot,

        /// Name of the word a call instruction targets. Returns null for non-call instructions.
        /// All three call forms surface their target name here, so an analysis pass never has to
        /// discriminate between them.
        pub fn callTargetName(op: Op) ?[]const u8 {
            return switch (op) {
                .push_literal => null,
                .call_word => |name| name,
                .call_word_direct, .call_word_module => |slot| slot.name,
            };
        }

        /// True for any of the three call forms, false for a non-call instruction.
        pub fn isCall(op: Op) bool {
            return switch (op) {
                .push_literal => false,
                .call_word, .call_word_direct, .call_word_module => true,
            };
        }
    };
};

/// Hash table type for H{ } literals - immutable key-value store.
///
/// Storage layout mirrors `MutableMap`: a refcounted, mutex-guarded `ContainerHeader` at the top of
/// the struct, followed by the `StringHashMapUnmanaged` that holds the entries. Create via
/// `HashTable.create` so the header is initialised before the value can be observed by any other
/// thread.
pub const HashTable = struct {
    header: @import("container_backing.zig").ContainerHeader,
    map: std.StringHashMapUnmanaged(Value) = .{},

    pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*HashTable {
        const self = try allocator.create(HashTable);
        self.* = .{
            .header = undefined,
            .map = .{},
        };
        self.header.init(allocator, destroyHashTable);
        return self;
    }

    fn destroyHashTable(header: *@import("container_backing.zig").ContainerHeader) void {
        const cb = @import("container_backing.zig");
        const self: *HashTable = @fieldParentPtr("header", header);
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            header.allocator.free(entry.key_ptr.*);
            cb.releaseValue(entry.value_ptr.*);
        }
        self.map.deinit(header.allocator);
        header.allocator.destroy(self);
    }
};

/// Vector type for V{ } literals - mutable, dynamically-sized sequences.
///
/// Carries a `ContainerHeader` so the backing participates in the
/// cross-worker refcount + per-container mutex lifecycle. The actual element
/// storage lives in `list`. Create via `Vector.create` so the header is
/// initialized with the correct destroy callback.
pub const Vector = struct {
    header: @import("container_backing.zig").ContainerHeader,
    list: std.ArrayListUnmanaged(Value) = .{},

    pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*Vector {
        const self = try allocator.create(Vector);
        self.* = .{
            .header = undefined,
            .list = .{},
        };
        self.header.init(allocator, destroyVector);
        return self;
    }

    fn destroyVector(header: *@import("container_backing.zig").ContainerHeader) void {
        const cb = @import("container_backing.zig");
        const self: *Vector = @fieldParentPtr("header", header);
        for (self.list.items) |item| {
            cb.releaseValue(item);
        }
        self.list.deinit(header.allocator);
        header.allocator.destroy(self);
    }
};

/// Array type for { } literals - immutable sequences.
///
/// Carries a `ContainerHeader` so the backing participates in the cross-worker
/// refcount lifecycle, uniform with `Vector`, `HashTable`, and `Set`. Elements
/// are immutable after construction.
///
/// The header is uniform across storage variants; only the destroy callback
/// differs. `.owned` releases each element, frees the items slice, and frees
/// the struct. `.static` releases each element but frees no memory: the
/// struct and backing belong to the instruction memory of the quotation that
/// captured the literal and are reclaimed with it, so refcount traffic can
/// never free a literal's backing. The element release still runs because a
/// parse-time word inside a literal (e.g. `{ V{ } }`) transfers an owned
/// container reference into the items.
///
/// Create via `Array.fromOwnedSlice` (owned) or `Array.createStatic` (static)
/// so the header is initialized before the value can be observed by another
/// thread.
pub const Array = struct {
    header: @import("container_backing.zig").ContainerHeader,
    items: []const Value = &.{},
    storage: enum { owned, static } = .owned,

    /// Adopt a filled slice allocated on `allocator`. Ownership of the slice
    /// and of the element references transfers to the array: destroy releases
    /// each element and frees the slice. Callers that copy elements out of a
    /// container they do not own must retain them first.
    pub fn fromOwnedSlice(allocator: std.mem.Allocator, items: []const Value) error{OutOfMemory}!*Array {
        const self = try allocator.create(Array);
        self.* = .{
            .header = undefined,
            .items = items,
            .storage = .owned,
        };
        self.header.init(allocator, destroyArray);
        return self;
    }

    /// Copy `src` into a fresh owned array, retaining each copied element:
    /// the copies become owning references held by the array's backing and
    /// released by its destroy.
    pub fn createCopyFrom(allocator: std.mem.Allocator, src: []const Value) error{OutOfMemory}!*Array {
        const items = try allocator.alloc(Value, src.len);
        errdefer allocator.free(items);
        @memcpy(items, src);
        const self = try fromOwnedSlice(allocator, items);
        @import("container_backing.zig").retainValues(items);
        return self;
    }

    /// Wrap a parse-time or decode-time literal slice living on instruction
    /// memory. The shareable flag stays `.unknown`: instruction memory is not
    /// the process-lifetime allocator, so the send-path scan classifies static
    /// arrays not-shareable and they cross task boundaries by deep copy.
    pub fn createStatic(allocator: std.mem.Allocator, items: []const Value) error{OutOfMemory}!*Array {
        const self = try allocator.create(Array);
        self.* = .{
            .header = undefined,
            .items = items,
            .storage = .static,
        };
        self.header.init(allocator, destroyArray);
        return self;
    }

    fn destroyArray(header: *@import("container_backing.zig").ContainerHeader) void {
        const cb = @import("container_backing.zig");
        const self: *Array = @fieldParentPtr("header", header);
        for (self.items) |item| {
            cb.releaseValue(item);
        }
        switch (self.storage) {
            .owned => {
                header.allocator.free(self.items);
                header.allocator.destroy(self);
            },
            .static => {},
        }
    }
};

/// ByteArray type for B{ } literals - mutable, dynamically-sized byte sequences.
///
/// Carries a `ContainerHeader` so the backing participates in the cross-worker
/// refcount + per-container mutex lifecycle, uniform with `Vector` and
/// `MutableMap`. The header is uniform across storage variants; only the
/// destroy callback differs: `.owned` frees the underlying bytes, `.borrowed`
/// frees only the struct because the bytes belong to an external owner per the
/// borrowed-buffer model. Create via `ByteArray.create` (owned) or
/// `makeBorrowedByteArray` (borrowed) so the header is initialized before the
/// value can be observed by another thread.
pub const ByteArray = struct {
    header: @import("container_backing.zig").ContainerHeader,
    items: []u8 = &.{},
    owned_items: std.ArrayListUnmanaged(u8) = .{},
    storage: union(enum) {
        owned,
        borrowed: []u8,
    } = .owned,

    pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*ByteArray {
        const self = try allocator.create(ByteArray);
        self.* = .{
            .header = undefined,
            .items = &.{},
            .owned_items = .{},
            .storage = .owned,
        };
        self.header.init(allocator, destroyByteArray);
        return self;
    }

    fn destroyByteArray(header: *@import("container_backing.zig").ContainerHeader) void {
        const self: *ByteArray = @fieldParentPtr("header", header);
        switch (self.storage) {
            .owned => {
                self.syncOwnedView();
                self.owned_items.deinit(header.allocator);
            },
            .borrowed => {
                // The bytes belong to an external owner; free only the struct.
                // A non-empty owned_items view on a borrowed struct would mean
                // the borrowed contract was violated somewhere upstream.
                std.debug.assert(self.owned_items.capacity == 0);
            },
        }
        header.allocator.destroy(self);
    }

    pub fn slice(self: ByteArray) []u8 {
        return self.items;
    }

    pub fn isBorrowed(self: ByteArray) bool {
        return switch (self.storage) {
            .owned => false,
            .borrowed => true,
        };
    }

    pub fn syncOwnedView(self: *ByteArray) void {
        if (self.storage == .owned) {
            self.owned_items.items = self.items;
        }
    }

    pub fn refreshOwnedView(self: *ByteArray) void {
        if (self.storage == .owned) {
            self.items = self.owned_items.items[0..self.owned_items.items.len];
        }
    }

    /// A borrowed backing points at memory this ByteArray does not own, so it cannot be
    /// resized in place. Callers that want to grow one must copy it to owned storage first.
    pub const ResizeError = error{ OutOfMemory, BorrowedByteArray };

    pub fn ensureTotalCapacity(self: *ByteArray, allocator: std.mem.Allocator, n: usize) ResizeError!void {
        switch (self.storage) {
            .owned => {
                self.syncOwnedView();
                try self.owned_items.ensureTotalCapacity(allocator, n);
                self.refreshOwnedView();
            },
            .borrowed => return error.BorrowedByteArray,
        }
    }

    pub fn append(self: *ByteArray, allocator: std.mem.Allocator, item: u8) ResizeError!void {
        switch (self.storage) {
            .owned => {
                self.syncOwnedView();
                try self.owned_items.append(allocator, item);
                self.refreshOwnedView();
            },
            .borrowed => return error.BorrowedByteArray,
        }
    }

    pub fn appendAssumeCapacity(self: *ByteArray, item: u8) void {
        std.debug.assert(self.storage == .owned);
        self.syncOwnedView();
        self.owned_items.appendAssumeCapacity(item);
        self.refreshOwnedView();
    }

    pub fn appendSliceAssumeCapacity(self: *ByteArray, items: []const u8) void {
        std.debug.assert(self.storage == .owned);
        self.syncOwnedView();
        self.owned_items.appendSliceAssumeCapacity(items);
        self.refreshOwnedView();
    }

    pub fn deinit(self: *ByteArray, allocator: std.mem.Allocator) void {
        if (self.storage == .owned) {
            self.syncOwnedView();
            self.owned_items.deinit(allocator);
        }
    }
};

pub fn makeBorrowedByteArray(allocator: std.mem.Allocator, bytes: []u8) !*ByteArray {
    const ba = try allocator.create(ByteArray);
    ba.* = .{
        .header = undefined,
        .items = bytes,
        .storage = .{ .borrowed = bytes },
    };
    ba.header.init(allocator, ByteArray.destroyByteArray);
    return ba;
}

/// Refcounted backing for string and symbol byte payloads. A `StringPayload` carries an
/// optional pointer to one of these alongside its direct byte slice; a null backing means the
/// bytes belong to memory that outlives the value (source text, image data, interned tables),
/// and retain/release are no-ops.
///
/// Mirrors `ByteArray`'s shape: a `ContainerHeader` for the cross-worker refcount lifecycle,
/// and an owned/borrowed storage split. Only `.owned` is constructed today; `.borrowed` is the
/// reserved shape for externally-owned bytes.
pub const StringBacking = struct {
    header: @import("container_backing.zig").ContainerHeader,
    storage: union(enum) {
        owned: []u8,
        borrowed: []const u8,
    },

    /// Take ownership of `bytes`, which must have been allocated on `allocator`. The backing
    /// frees them when the last reference drops.
    pub fn adoptOwned(allocator: std.mem.Allocator, bytes: []u8) error{OutOfMemory}!*StringBacking {
        const self = try allocator.create(StringBacking);
        self.* = .{
            .header = undefined,
            .storage = .{ .owned = bytes },
        };
        self.header.init(allocator, destroyStringBacking);
        return self;
    }

    pub fn isBorrowed(self: StringBacking) bool {
        return self.storage == .borrowed;
    }

    fn destroyStringBacking(header: *@import("container_backing.zig").ContainerHeader) void {
        const self: *StringBacking = @fieldParentPtr("header", header);
        switch (self.storage) {
            .owned => |bytes| header.allocator.free(bytes),
            .borrowed => {},
        }
        header.allocator.destroy(self);
    }
};

/// The payload of `Value.string` and `Value.symbol`: a direct byte slice plus an optional
/// refcounted backing. `bytes` may be an interior sub-slice of the backing's storage;
/// sub-slicing narrows `bytes` and shares `backing`, so it stays zero-copy.
pub const StringPayload = struct {
    backing: ?*StringBacking = null,
    bytes: []const u8,

    /// A payload over a sub-range of this payload's bytes, sharing the same backing. The
    /// caller is responsible for the reference: pushing the result retains the backing
    /// through the usual choke points.
    pub fn sub(self: StringPayload, bytes: []const u8) StringPayload {
        return .{ .backing = self.backing, .bytes = bytes };
    }
};

/// A null-backed string value over bytes that outlive the value.
pub fn stringValue(bytes: []const u8) Value {
    return .{ .string = .{ .bytes = bytes } };
}

/// A null-backed symbol value over bytes that outlive the value.
pub fn symbolValue(bytes: []const u8) Value {
    return .{ .symbol = .{ .bytes = bytes } };
}

/// A string value owning `bytes` through a fresh heap backing. `bytes` must have been
/// allocated on `allocator`. The returned value holds the backing's creation reference,
/// which the caller transfers (`pushMoved`, container adoption) or releases.
pub fn ownedStringValue(allocator: std.mem.Allocator, bytes: []u8) error{OutOfMemory}!Value {
    return .{ .string = .{ .backing = try StringBacking.adoptOwned(allocator, bytes), .bytes = bytes } };
}

/// Symbol twin of `ownedStringValue`.
pub fn ownedSymbolValue(allocator: std.mem.Allocator, bytes: []u8) error{OutOfMemory}!Value {
    return .{ .symbol = .{ .backing = try StringBacking.adoptOwned(allocator, bytes), .bytes = bytes } };
}

/// Refcounted backing for a bignum value. A `BignumPayload` carries an optional pointer to
/// one of these alongside its direct `*BigIntManaged`; a null backing means the box and its
/// limbs live on an arena that outlives the value, and retain/release are no-ops.
///
/// The backing embeds the `Managed` it owns, so an owned bignum is one allocation plus its
/// limb array. The limbs are freed through `big.allocator`, which the constructors keep equal
/// to the backing's own allocator.
pub const BignumBacking = struct {
    header: @import("container_backing.zig").ContainerHeader,
    big: BigIntManaged,

    /// Take ownership of `big`, whose limbs must have been allocated on `allocator`. The
    /// backing deinits them when the last reference drops.
    pub fn adopt(allocator: std.mem.Allocator, big: BigIntManaged) error{OutOfMemory}!*BignumBacking {
        const self = try allocator.create(BignumBacking);
        self.* = .{
            .header = undefined,
            .big = big,
        };
        self.header.init(allocator, destroyBignumBacking);
        return self;
    }

    fn destroyBignumBacking(header: *@import("container_backing.zig").ContainerHeader) void {
        const self: *BignumBacking = @fieldParentPtr("header", header);
        self.big.deinit();
        header.allocator.destroy(self);
    }
};

/// The payload of `Value.bignum`: a direct pointer to the `Managed` plus an optional
/// refcounted backing, mirroring `StringPayload`'s null-means-inert split. For an owned
/// bignum, `big` points at the backing's embedded `Managed`.
pub const BignumPayload = struct {
    backing: ?*BignumBacking = null,
    big: *BigIntManaged,
};

/// A null-backed bignum value whose box and limbs ride `alloc`'s lifetime (an arena).
pub fn bignumValue(alloc: std.mem.Allocator, big: BigIntManaged) !Value {
    return .{ .bignum = .{ .big = try boxBigInt(alloc, big) } };
}

/// A bignum value owning `big` through a fresh heap backing. `big`'s limbs must have been
/// allocated on `allocator`. The returned value holds the backing's creation reference,
/// which the caller transfers (`pushMoved`, container adoption) or releases.
pub fn ownedBignumValue(allocator: std.mem.Allocator, big: BigIntManaged) error{OutOfMemory}!Value {
    const backing = try BignumBacking.adopt(allocator, big);
    return .{ .bignum = .{ .backing = backing, .big = &backing.big } };
}

/// Box a packed-array element. Floats box as `.float` (an f32 widens to f64), integers as
/// `.fixnum`, except the upper half of u64, which exceeds fixnum range and boxes as an owned
/// bignum on `allocator`.
pub fn packedElementValue(comptime T: type, allocator: std.mem.Allocator, elem: T) error{OutOfMemory}!Value {
    const info = @typeInfo(T);
    if (info == .float) {
        return .{ .float = @floatCast(elem) };
    } else if (info == .int) {
        if (info.int.signedness == .unsigned and @sizeOf(T) == 8) {
            if (elem > std.math.maxInt(i64)) {
                const big = try BigIntManaged.initSet(allocator, elem);
                return try ownedBignumValue(allocator, big);
            }
            return .{ .fixnum = @intCast(elem) };
        }
        return .{ .fixnum = @intCast(elem) };
    } else {
        unreachable;
    }
}

/// Refcounted backing for a tagged value's inner box. A `TaggedPayload` carries an optional
/// pointer to one of these alongside its direct inner pointer; a null backing means the box
/// lives on an arena that outlives the value, and the wrapper's reference is the recursive
/// claim on the inner value's own backings, exactly the pre-backing semantics.
///
/// The backing embeds the inner `Value` it owns, so an owned wrap is one allocation and the
/// payload's `inner` points at the embedded cell.
pub const TaggedBacking = struct {
    header: @import("container_backing.zig").ContainerHeader,
    inner: Value,

    /// Take ownership of the caller's reference to `inner`. The backing releases it when the
    /// last reference drops.
    pub fn adopt(allocator: std.mem.Allocator, inner: Value) error{OutOfMemory}!*TaggedBacking {
        const self = try allocator.create(TaggedBacking);
        self.* = .{
            .header = undefined,
            .inner = inner,
        };
        self.header.init(allocator, destroyTaggedBacking);
        return self;
    }

    /// Release-to-zero callback. Frees memory only; it never executes user code.
    fn destroyTaggedBacking(header: *@import("container_backing.zig").ContainerHeader) void {
        const cb = @import("container_backing.zig");
        const self: *TaggedBacking = @fieldParentPtr("header", header);
        cb.releaseValue(self.inner);
        header.allocator.destroy(self);
    }
};

/// The payload of `Value.tagged`: the virtual type, a direct pointer to the boxed inner
/// value, plus an optional refcounted backing, mirroring `StringPayload`'s null-means-inert
/// split. For an owned wrap, `inner` points at the backing's embedded cell.
pub const TaggedPayload = struct {
    backing: ?*TaggedBacking = null,
    tag: *const VirtualType,
    inner: *const Value,
};

/// A tagged value owning its inner box through a fresh heap backing, adopting the caller's
/// reference to `inner`. The returned value holds the backing's creation reference, which
/// the caller transfers (`pushMoved`, container adoption) or releases. On failure the
/// caller still owns `inner`.
pub fn ownedTaggedValue(allocator: std.mem.Allocator, tag: *const VirtualType, inner: Value) error{OutOfMemory}!Value {
    const backing = try TaggedBacking.adopt(allocator, inner);
    return .{ .tagged = .{ .backing = backing, .tag = tag, .inner = &backing.inner } };
}

pub fn valueContainsBorrowedBuffer(val: Value) bool {
    return switch (val) {
        .byte_array => |ba| ba.isBorrowed(),
        .array => |arr| containsBorrowedInSlice(arr.items),
        .quotation => |quot| blk: {
            for (quot.instructions) |instr| {
                switch (instr.op) {
                    .push_literal => |literal| {
                        if (valueContainsBorrowedBuffer(literal)) break :blk true;
                    },
                    .call_word, .call_word_direct, .call_word_module => {},
                }
            }
            break :blk false;
        },
        .closure => |c| valueContainsBorrowedBuffer(.{ .quotation = c.asQuotation() }),
        .hash => |h| blk: {
            var iter = h.map.iterator();
            while (iter.next()) |entry| {
                if (valueContainsBorrowedBuffer(entry.value_ptr.*)) break :blk true;
            }
            break :blk false;
        },
        .vector => |v| containsBorrowedInSlice(v.list.items),
        .set => |s| blk: {
            for (s.map.keys()) |key| {
                if (valueContainsBorrowedBuffer(key)) break :blk true;
            }
            break :blk false;
        },
        .mutable_map => |m| blk: {
            var iter = m.map.iterator();
            while (iter.next()) |entry| {
                if (valueContainsBorrowedBuffer(entry.value_ptr.*)) break :blk true;
            }
            break :blk false;
        },
        .struct_instance => |si| containsBorrowedInSlice(si.fields),
        .tagged => |t| valueContainsBorrowedBuffer(t.inner.*),
        .error_value => |err| if (err.data) |data| valueContainsBorrowedBuffer(data.*) else false,
        .string, .symbol => |s| if (s.backing) |b| b.isBorrowed() else false,
        .fixnum,
        .float,
        .boolean,
        .unit,
        .bignum,
        .stream,
        .parameter,
        .marker,
        .type_val,
        .type_descriptor,
        .protocol_descriptor,
        .constraint_combinator,
        .resource,
        .task,
        .iterator,
        .channel,
        .stack_effect,
        .struct_type,
        .template,
        .doc_string,
        .module,
        .sandbox_spec,
        => false,
    };
}

fn containsBorrowedInSlice(items: []const Value) bool {
    for (items) |item| {
        if (valueContainsBorrowedBuffer(item)) return true;
    }
    return false;
}

/// Return the tag of the first task-arena-owned reference variant reachable from `val`,
/// or null when there is none.
///
/// The four matched variants are allocated on the creating task's arena and dangle once
/// that task is reaped, so the cross-task copy funnel refuses them. The walk mirrors
/// `deepCopyValue`'s recursion, including closure segment captures, so a non-null result
/// is exactly a copy that fails with `error.TaskArenaEscape`.
pub fn findTaskArenaOwned(val: Value) ?std.meta.Tag(Value) {
    return switch (val) {
        .iterator, .parameter, .resource, .stream => std.meta.activeTag(val),
        .array => |arr| findArenaOwnedInSlice(arr.items),
        .vector => |v| findArenaOwnedInSlice(v.list.items),
        .quotation => |quot| blk: {
            for (quot.instructions) |instr| {
                switch (instr.op) {
                    .push_literal => |literal| {
                        if (findTaskArenaOwned(literal)) |tag| break :blk tag;
                    },
                    .call_word, .call_word_direct, .call_word_module => {},
                }
            }
            break :blk null;
        },
        .closure => |c| blk: {
            if (findTaskArenaOwned(.{ .quotation = c.asQuotation() })) |tag| break :blk tag;
            for (c.segments) |seg| {
                if (findArenaOwnedInSlice(seg.captures)) |tag| break :blk tag;
            }
            break :blk null;
        },
        .hash => |h| blk: {
            var iter = h.map.iterator();
            while (iter.next()) |entry| {
                if (findTaskArenaOwned(entry.value_ptr.*)) |tag| break :blk tag;
            }
            break :blk null;
        },
        .set => |s| blk: {
            for (s.map.keys()) |key| {
                if (findTaskArenaOwned(key)) |tag| break :blk tag;
            }
            break :blk null;
        },
        .mutable_map => |m| blk: {
            var iter = m.map.iterator();
            while (iter.next()) |entry| {
                if (findTaskArenaOwned(entry.value_ptr.*)) |tag| break :blk tag;
            }
            break :blk null;
        },

        .struct_instance => |si| findArenaOwnedInSlice(si.fields),
        .tagged => |t| findTaskArenaOwned(t.inner.*),
        .error_value => |err| if (err.data) |data| findTaskArenaOwned(data.*) else null,

        .fixnum,
        .float,
        .boolean,
        .unit,
        .bignum,
        .string,
        .symbol,
        .byte_array,
        .marker,
        .type_val,
        .type_descriptor,
        .protocol_descriptor,
        .constraint_combinator,
        .task,
        .channel,
        .stack_effect,
        .struct_type,
        .template,
        .doc_string,
        .module,
        .sandbox_spec,
        => null,
    };
}

fn findArenaOwnedInSlice(items: []const Value) ?std.meta.Tag(Value) {
    for (items) |item| {
        if (findTaskArenaOwned(item)) |tag| return tag;
    }
    return null;
}

/// Context for hashing and comparing Values in hash-based containers.
pub const ValueContext = struct {
    pub fn hash(self: @This(), key: Value) u32 {
        _ = self;
        // Truncate 64-bit hash to 32-bit as required by ArrayHashMap
        return @truncate(key.hashValue());
    }

    pub fn eql(self: @This(), a: Value, b: Value, index: usize) bool {
        _ = self;
        _ = index;
        return a.eql(b);
    }
};

/// Set type for S{ } literals - immutable collections of unique values.
/// Uses hash-based storage for O(1) average-case membership testing.
///
/// Storage layout mirrors `HashTable`: a refcounted, mutex-guarded `ContainerHeader` at the top of
/// the struct, followed by the `ArrayHashMapUnmanaged` that holds the members. Members are Values,
/// so destroy releases each one; there are no separate key bytes to free. Create via `Set.create`
/// so the header is initialised before the value can be observed by any other thread.
pub const Set = struct {
    header: @import("container_backing.zig").ContainerHeader,
    map: std.ArrayHashMapUnmanaged(Value, void, ValueContext, true) = .{},

    pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*Set {
        const self = try allocator.create(Set);
        self.* = .{
            .header = undefined,
            .map = .{},
        };
        self.header.init(allocator, destroySet);
        return self;
    }

    fn destroySet(header: *@import("container_backing.zig").ContainerHeader) void {
        const cb = @import("container_backing.zig");
        const self: *Set = @fieldParentPtr("header", header);
        for (self.map.keys()) |key| {
            cb.releaseValue(key);
        }
        self.map.deinit(header.allocator);
        header.allocator.destroy(self);
    }
};

/// MutableMap type for M{ } literals - mutable key-value store.
///
/// Storage layout mirrors `Vector`: a refcounted, mutex-guarded
/// `ContainerHeader` at the top of the struct, followed by the
/// `StringHashMapUnmanaged` that holds the entries. Create via
/// `MutableMap.create` so the header is initialised before the value
/// can be observed by any other thread.
pub const MutableMap = struct {
    header: @import("container_backing.zig").ContainerHeader,
    map: std.StringHashMapUnmanaged(Value) = .{},

    pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*MutableMap {
        const self = try allocator.create(MutableMap);
        self.* = .{
            .header = undefined,
            .map = .{},
        };
        self.header.init(allocator, destroyMutableMap);
        return self;
    }

    fn destroyMutableMap(header: *@import("container_backing.zig").ContainerHeader) void {
        const cb = @import("container_backing.zig");
        const self: *MutableMap = @fieldParentPtr("header", header);
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            header.allocator.free(entry.key_ptr.*);
            cb.releaseValue(entry.value_ptr.*);
        }
        self.map.deinit(header.allocator);
        header.allocator.destroy(self);
    }
};

/// StreamMode indicates how a stream was opened.
pub const StreamMode = enum {
    read,
    write,
    append,
    read_write,

    pub fn toString(self: StreamMode) []const u8 {
        return switch (self) {
            .read => "read",
            .write => "write",
            .append => "append",
            .read_write => "read-write",
        };
    }
};

/// BufferingMode indicates how a stream is buffered.
pub const BufferingMode = enum {
    none,
    line,
    block,

    pub fn toSymbol(self: BufferingMode) []const u8 {
        return switch (self) {
            .none => "none",
            .line => "line",
            .block => "block",
        };
    }
};

/// VTable for stream I/O dispatch. Each wrapper layer provides its own vtable.
pub const StreamVTable = struct {
    read: *const fn (*Stream, []u8, *Context) anyerror!usize,
    write: *const fn (*Stream, []const u8, *Context) anyerror!usize,
    close: *const fn (*Stream) void,
    flush: *const fn (*Stream) anyerror!void,
};

/// Stream wraps a file descriptor for I/O operations. Wrappers (TLS,
/// compression, etc.) form a singly-linked list via `inner`, each with
/// its own vtable. The `fd` field always holds the bottom-level file
/// descriptor for scheduler integration and fcntl operations.
pub const Stream = struct {
    vtable: *const StreamVTable,
    // Plain i32, not std.posix.fd_t: fd_t is void on freestanding targets
    // (no OS-level file descriptors), which cannot hold the real fd numbers
    // or in-memory-stream sentinels this field is assigned throughout
    // streams.zig. i32 matches fd_t's actual definition on every hosted
    // target this project supports (Linux, macOS), so this is a no-op there.
    fd: i32,
    mode: StreamMode,
    closed: bool = false,
    // For display: "stdout", "stderr", file path
    name: []const u8,
    buffering: BufferingMode = .none,
    nonblocking_set: bool = false,
    // Wrapper-specific state, e.g., TLS session state or compressor context.
    impl: ?*anyopaque = null,
    // Wrapped stream, where base streams have null inner.
    inner: ?*Stream = null,
};

/// Resource wraps an opaque C pointer for FFI interop.
/// All instances of the same resource type share a type_name string.
/// The ptr is nulled on close as defense-in-depth alongside the closed flag.
pub const FfiCloseFn = struct {
    fn_ptr: *anyopaque,
};

pub const CloseFn = union(enum) {
    none,
    native: *const fn (*anyopaque) void,
    ffi: *const FfiCloseFn,
};

pub const Resource = struct {
    type_name: []const u8,
    ptr: ?*anyopaque = null,
    closed: bool = false,
    close_fn: CloseFn = .none,
    ffi_signature: ?*const FfiSignature = null,
};

/// Parameter represents a dynamically-scoped variable with a lazy default.
/// The default quotation is evaluated each time the parameter is accessed
/// without a binding in the current dynamic scope.
pub const Parameter = struct {
    name: []const u8,
    default_quotation: Quotation, // Lazy default - evaluated on get if unbound
};

/// Marker represents a named marker for attaching metadata to definitions.
/// Markers are pure metadata values that can be attached to word definitions.
/// Anonymous markers (created by `marker` word) have empty name until defined.
pub const Marker = struct {
    name: []const u8, // Empty for anonymous, actual name when defined with ;
};

/// VirtualType represents the definition of a virtual type.
///
/// All instances of the same virtual type share a single VirtualType allocation,
/// enabling pointer equality for type identity checks.
///
/// The `parent_type` field models a variant-to-parent relationship. For example,
/// when `define-enum` creates variants like `color:red`, it set each variant's
/// `parent_type` to point at the parent enum's `TypeValue`. This chain is
/// exactly one level deep: a variant points to its enum, and the enum itself
/// has no parent. This constraint is structural: only VirtualType carries
/// `parent_type`, and an enum's TypeValue is not  backed by any VirtualType.
///
/// `instance-of?` uses the parent_type field as a one-level fallback: it first
/// compares the value's own TypeValue pointer against the query type, then
/// checks the value's `parent_type` if set. This allows:
///
///   color:red instance-of? color
///
/// to return true.
///
/// `parent_type` is unrelated to value containment. A nested array like
/// `{ { 1 } }` has type `array`, not `array(array(fixnum))`. The type
/// system does not currently track inner element types at the value level.
///
/// Parameterized virtual types use `base_type` to record what base type they
/// wrap (e.g., array) and `type_params` to record element constraints (e.g.,
/// fixnum). The validating wrap word checks each element against type_params
/// during construction.
pub const VirtualType = struct {
    // Type name, e.g., "duration"
    name: []const u8,
    // Expected inner type name, e.g., "fixnum"
    inner_type: []const u8,
    // Anonymous struct backing, if struct-backed
    anon_struct: ?*const StructType = null,
    // Parent enum type for enum variants, e.g., the "color" TypeValue for "color:red"
    parent_type: ?*const TypeValue = null,
    // Base type for parameterized types, e.g., the "array" TypeValue for "array(fixnum)"
    base_type: ?*const TypeValue = null,
    // Type parameters for parameterized types, e.g., [fixnum] for "array(fixnum)"
    type_params: ?[]*const TypeValue = null,
    // First-class type value for this virtual type, set during type registration
    type_val: ?*TypeValue = null,
};

/// StructType represents the definition of a struct type.
/// Created by `struct{ field1 field2 ... }` syntax.
pub const StructType = struct {
    // Type name, e.g., "point"
    name: []const u8,
    // Field names in order, e.g., ["x", "y"]
    fields: []const []const u8,
    // Optional per-field constraint annotations for validation. Each element is
    // a concrete type, a protocol bound, or a combinator, mirroring a
    // stack-effect parameter's annotation.
    field_types: []const ?ConstraintCombinator.Element = &.{},
    // First-class type value for this struct type, set during type registration
    type_val: ?*TypeValue = null,
};

/// FormatSpec controls padding/alignment when rendering a template placeholder.
pub const FormatSpec = struct {
    width: ?usize = null,
    fill: u8 = ' ',
    align_left: bool = false,
};

/// TemplateSegment is one piece of a parsed template: either literal text or a placeholder.
pub const TemplateSegment = union(enum) {
    literal: []const u8,
    identity: FormatSpec,
    named: struct {
        name: []const u8,
        spec: FormatSpec,
    },
    indexed: struct {
        index: usize,
        spec: FormatSpec,
    },
};

/// TypeValue represents a first-class type value that can be pushed onto the stack.
/// Created when type names are used as words.
pub const TypeValue = struct {
    name: []const u8,
    descriptor: ?*TypeDescriptor,
    generated_words: ?[]Value = null,
    member_types: ?[]const *const TypeValue = null,
    /// Back-reference to the VirtualType when this TypeValue represents a
    /// virtual type. Mirrors VirtualType.type_val. Used by generator-emitted
    /// natives to recover the VirtualType pointer from a popped .type_val
    /// without resorting to fixnum-disguised pointers.
    virtual_type: ?*const VirtualType = null,
};

pub const DescriptorFlags = struct {
    numeric: bool = false,
    exact: bool = false,
    integer: bool = false,
    mutable: bool = false,
};

/// TypeKind classifies the descriptor kinds. The variant chosen here
/// determines which payload struct lives inside the `TypeKindData`
/// tagged union.
pub const TypeKind = enum {
    builtin,
    sentinel,
    struct_,
    virtual,
    enum_,
    enum_variant,
    resource,
    ffi_struct,
    union_,
    type_parameter,
};

/// TypeDescriptor carries a type's metadata in a closed-vocabulary,
/// statically-typed shape. The four universal boolean properties live
/// as direct fields; kind-specific data lives in `kind`.
pub const TypeDescriptor = struct {
    numeric: bool = false,
    exact: bool = false,
    integer: bool = false,
    mutable: bool = false,
    kind: TypeKindData,
};

/// TypeKindData carries the kind-specific payload of a TypeDescriptor.
pub const TypeKindData = union(TypeKind) {
    builtin: void,
    sentinel: void,
    struct_: StructData,
    virtual: VirtualData,
    enum_: EnumData,
    enum_variant: EnumVariantData,
    resource: ResourceData,
    ffi_struct: FfiStructData,
    /// Anonymous union types carry their member list on `TypeValue.member_types`;
    /// the descriptor itself has no extra kind-specific data beyond the
    /// universal flags inferred from the union members.
    union_: void,
    /// A type parameter is a hole in a generic type definition. Its name rides
    /// on `TypeValue.name`; the payload carries only its position in the
    /// defining type's parameter list.
    type_parameter: TypeParameterData,
};

/// ProtocolDescriptor carries a protocol's metadata: its name, the method
/// list as the flat symbol-interleaved-with-stack-effect array that
/// `nativeDefineProtocol` and `protocolCheckHelper` already consume, and a
/// monotonic protocol_id assigned by Context. Each `protocol{` definition
/// allocates its own descriptor; identity is the pointer.
pub const ProtocolDescriptor = struct {
    name: []const u8,
    methods: []const Value,
    protocol_id: u32,
};

/// ConstraintCombinator carries an algebraic combination over constraints: an
/// intersection (`&`) or a union (`|`) of element constraints. Each element is
/// itself a concrete type, a protocol bound, or a nested combinator, so
/// combinators compose recursively. A monotonic combinator_id assigned by
/// Context parallels ProtocolDescriptor's protocol_id; each combinator
/// allocates its own descriptor and identity is the pointer.
pub const ConstraintCombinator = struct {
    pub const Kind = enum { intersection, @"union" };

    /// One element of a combinator. The `union` keyword forces the field name
    /// `combinator` for the recursive arm rather than the more natural
    /// `combination`; the three arms mirror TypeAnnotation's tagged variants.
    pub const Element = union(enum) {
        type: *const TypeValue,
        protocol: *const ProtocolDescriptor,
        combinator: *const ConstraintCombinator,
    };

    kind: Kind,
    elements: []const Element,
    combinator_id: u32,
};

/// StructData carries the metadata of a struct-defined type.
pub const StructData = struct {
    fields: []const []const u8 = &.{},
    field_types: []const ?ConstraintCombinator.Element = &.{},
    /// Declared type parameters, ordered by position, for a generic struct
    /// definition (e.g. `struct{ id: T: age: U: }`). Empty for a concrete
    /// struct. Each entry is the same parameter TypeValue referenced by the
    /// corresponding `field_types` slot, so `field_types` remains the source of
    /// truth and this is the position-ordered projection of it.
    type_params: []const *const TypeValue = &.{},
};

/// VirtualData carries the metadata of a virtual-defined type.
pub const VirtualData = struct {
    /// Inner type for non-parameterized virtual types: the wrap target.
    /// For struct-backed virtual types this is null; reach the anon
    /// struct through `anon_struct` instead.
    inner_type: ?*const TypeValue = null,
    /// For struct-backed virtual types, the anonymous struct backing.
    /// Mirrors `VirtualType.anon_struct` so descriptor-only readers can
    /// reach the struct shape.
    anon_struct: ?*const StructType = null,
    /// Type parameters for parameterized types (e.g. `[fixnum]` for
    /// `array(fixnum)`).
    type_params: []const *const TypeValue = &.{},
};

/// EnumData carries the metadata of an enum-defined type.
pub const EnumData = struct {
    variants: []const Variant = &.{},
    /// Declared enum-level type parameters, ordered by position, for a generic
    /// enum definition (e.g. `enum{ ok: result-value bind{ T: } ... }`). Empty
    /// for a concrete enum. Each parameter is minted once per enum definition
    /// and shared across the variants that bind it.
    type_params: []const *const TypeValue = &.{},
};

/// Variant pairs a variant name with its inner-type, mirroring the
/// `(name, type)` shape carried by enum descriptors.
pub const Variant = struct {
    name: []const u8,
    type_val: ?*const TypeValue = null,
};

/// EnumVariantData carries the metadata of a single enum variant's TypeValue.
pub const EnumVariantData = struct {
    parent: ?*const TypeValue = null,
    inner_type: ?*const TypeValue = null,
    /// For data-carrying variants, the struct backing the payload. Mirrors
    /// `VirtualType.anon_struct` so descriptor-only readers (AOT emit/load)
    /// can reach the struct shape the variant's wrap constructor needs.
    anon_struct: ?*const StructType = null,
};

/// ResourceData carries the metadata of a resource type.
pub const ResourceData = struct {
    resource_kind: []const u8 = &.{},
};

/// FfiStructData carries the metadata of an FFI struct type.
pub const FfiStructData = struct {
    fields: []const []const u8 = &.{},
    field_types: []const ?*const TypeValue = &.{},
    /// Pointer to the FFI layout object, encoded as a usize. The
    /// previous `MutableMap` descriptor stored this as a fixnum
    /// carrying the pointer; the value-level shape is preserved.
    ffi_layout: usize = 0,
};

/// TypeParameterData carries the metadata of a type parameter: its position in
/// the defining type's parameter list. The parameter's name rides on the
/// always-present `TypeValue.name`, so no name field is duplicated here.
pub const TypeParameterData = struct {
    position: u32 = 0,
};

/// Allocate a TypeDescriptor with the given kind payload and universal
/// boolean flags. Producers that build kind-specific payloads
/// progressively can pass `.{ .builtin = {} }` (or the eventual kind
/// with empty defaults) and mutate `desc.kind` afterwards.
pub fn createTypeDescriptor(
    allocator: std.mem.Allocator,
    kind: TypeKindData,
    flags: DescriptorFlags,
) !*TypeDescriptor {
    const desc = try allocator.create(TypeDescriptor);
    desc.* = .{
        .numeric = flags.numeric,
        .exact = flags.exact,
        .integer = flags.integer,
        .mutable = flags.mutable,
        .kind = kind,
    };
    return desc;
}

pub fn createBuiltinTypeDescriptor(allocator: std.mem.Allocator, flags: DescriptorFlags) !*TypeDescriptor {
    return createTypeDescriptor(allocator, .{ .builtin = {} }, flags);
}

pub fn createSentinelTypeDescriptor(allocator: std.mem.Allocator) !*TypeDescriptor {
    return createTypeDescriptor(allocator, .{ .sentinel = {} }, .{});
}

pub fn destroyTypeDescriptor(allocator: std.mem.Allocator, desc: *TypeDescriptor) void {
    allocator.destroy(desc);
}

pub fn createTypeParameterDescriptor(allocator: std.mem.Allocator, position: u32) !*TypeDescriptor {
    return createTypeDescriptor(allocator, .{ .type_parameter = .{ .position = position } }, .{});
}

/// Mint a fresh type-parameter TypeValue for a generic definition's hole. Each
/// call allocates a new descriptor and TypeValue, so per-definition parameters
/// have distinct identity even when they share a spelling. The `name` slice is
/// borrowed, matching how every other TypeValue stores its name; the caller
/// owns the name's lifetime. Real callers pass `ctx.arena.allocator()`, so no
/// manual free is needed.
pub fn mintTypeParameter(allocator: std.mem.Allocator, name: []const u8, position: u32) !*TypeValue {
    const desc = try createTypeParameterDescriptor(allocator, position);
    const tv = try allocator.create(TypeValue);
    tv.* = .{ .name = name, .descriptor = desc };
    return tv;
}

/// True when the TypeValue is a type-parameter hole rather than a concrete type.
pub fn isTypeParameter(tv: *const TypeValue) bool {
    const desc = tv.descriptor orelse return false;
    return desc.kind == .type_parameter;
}

/// The type parameter's position in its defining type's parameter list, or null
/// when the TypeValue is not a type parameter.
pub fn typeParameterPosition(tv: *const TypeValue) ?u32 {
    const desc = tv.descriptor orelse return null;
    return switch (desc.kind) {
        .type_parameter => |d| d.position,
        else => null,
    };
}

/// Collect the distinct type parameters referenced by a type, ordered by first appearance,
/// appending into `params` and deduped by pointer.
///
/// A bare type-parameter hole is collected directly; a parameterized virtual type is walked so
/// parameters buried in its type_params tuple are surfaced too.
///
/// Concrete types contribute nothing.
fn collectTypeParams(alloc: std.mem.Allocator, params: *std.ArrayListUnmanaged(*const TypeValue), tv: *const TypeValue) !void {
    if (isTypeParameter(tv)) {
        const seen = for (params.items) |p| {
            if (p == tv) break true;
        } else false;
        if (!seen) try params.append(alloc, tv);
        return;
    }
    const desc = tv.descriptor orelse return;
    switch (desc.kind) {
        .virtual => |vd| {
            for (vd.type_params) |p| try collectTypeParams(alloc, params, p);
        },
        else => {},
    }
}

/// Collect the distinct type parameters referenced by a struct's field types, ordered by first
/// appearance.
///
/// A field typed as a bare parameter hole, or as a parameterized type carrying parameter holes
/// in its type_params, contributes its parameters. A parameter shared by several fields is
/// returned once. Returns an empty slice for a concrete struct.
pub fn deriveStructTypeParams(alloc: std.mem.Allocator, field_types: []const ?ConstraintCombinator.Element) ![]const *const TypeValue {
    var params = std.ArrayListUnmanaged(*const TypeValue){};
    errdefer params.deinit(alloc);
    for (field_types) |ft| {
        const element = ft orelse continue;
        const tv = switch (element) {
            .type => |t| t,
            else => continue,
        };
        try collectTypeParams(alloc, &params, tv);
    }
    if (params.items.len == 0) {
        params.deinit(alloc);
        return &.{};
    }
    return params.toOwnedSlice(alloc);
}

/// Collect the distinct enum-level type parameters referenced by a list of
/// variant type values, ordered by first appearance and deduped by pointer.
///
/// A parameterized variant base (`result-value bind{ T: }`) is a virtual
/// type whose `type_params` tuple carries the enum parameters it binds;
/// walking those surfaces the enum's declared parameters. A concrete variant
/// base (a plain struct, or `unit`) contributes nothing.
pub fn deriveEnumTypeParams(alloc: std.mem.Allocator, variant_tvs: []const *const TypeValue) ![]const *const TypeValue {
    var params = std.ArrayListUnmanaged(*const TypeValue){};
    errdefer params.deinit(alloc);
    for (variant_tvs) |tv| {
        try collectTypeParams(alloc, &params, tv);
    }
    if (params.items.len == 0) {
        params.deinit(alloc);
        return &.{};
    }
    return params.toOwnedSlice(alloc);
}

/// Returns the stored symbol name for a TypeKindData variant. The 1z
/// symbol-literal syntax `name:` produces a symbol whose stored name is
/// `name` (the trailing colon is syntactic), so these strings omit the
/// colon. The 1z-level inspect form re-adds the colon when printing.
pub fn typeKindSymbol(kind: TypeKindData) []const u8 {
    return switch (kind) {
        .builtin => "builtin-type",
        .sentinel => "sentinel",
        .struct_ => "struct-descriptor",
        .virtual => "virtual",
        .enum_ => "enum-descriptor",
        .enum_variant => "enum-variant",
        .resource => "resource-type",
        .ffi_struct => "ffi-struct-type",
        .union_ => "union-type",
        .type_parameter => "type-parameter",
    };
}

/// StructInstance represents an instance of a struct type.
/// Created by make-NAME or >NAME words.
///
/// A runtime-created instance carries a refcounted header, built through
/// `createStructInstance`, so every copy of the value shares one owner of the field set and
/// the generated field setter can replace a field in place without unbalancing other live
/// copies.
///
/// A headerless instance is the legacy per-copy-claims form: each copy retains and releases
/// every field itself. That form is only balanced while the fields never change, so it is
/// reserved for instances that are never field-mutated, which in practice means test
/// fixtures and other statically-constructed values.
pub const StructInstance = struct {
    struct_type: *const StructType, // Reference to the type definition
    fields: []Value, // Field values in order (mutable for setter support)
    header: ?*@import("container_backing.zig").ContainerHeader = null,
};

/// Owning allocation behind a headered `StructInstance`: the refcounted header and the
/// instance it governs, allocated as one block so the header's destroy callback can free
/// everything it owns.
pub const StructInstanceBacking = struct {
    header: @import("container_backing.zig").ContainerHeader,
    instance: StructInstance,

    fn destroyStructInstance(header: *@import("container_backing.zig").ContainerHeader) void {
        const cb = @import("container_backing.zig");
        const self: *StructInstanceBacking = @fieldParentPtr("header", header);
        for (self.instance.fields) |field| {
            cb.releaseValue(field);
        }
        header.allocator.free(self.instance.fields);
        header.allocator.destroy(self);
    }
};

/// Create a refcounted struct instance. `fields` must be allocated on `allocator`, and
/// ownership of both the slice and the element references transfers to the instance:
/// destroy releases each field once and frees the slice.
///
/// `allocator` should be the process-lifetime allocator, like every other refcounted
/// backing: the last release can run from a context whose arena is already gone, so
/// nothing destroy frees may be arena-owned. A site that passes an arena anyway must
/// prove its own release ordering pins the refcount until the arena's teardown.
pub fn createStructInstance(
    allocator: std.mem.Allocator,
    struct_type: *const StructType,
    fields: []Value,
) error{OutOfMemory}!*StructInstance {
    const backing = try allocator.create(StructInstanceBacking);
    backing.* = .{
        .header = undefined,
        .instance = .{
            .struct_type = struct_type,
            .fields = fields,
            .header = undefined,
        },
    };
    backing.header.init(allocator, StructInstanceBacking.destroyStructInstance);
    backing.instance.header = &backing.header;
    return &backing.instance;
}

fn structTypeDescriptor(st: *const StructType) ?*const TypeDescriptor {
    const tv = st.type_val orelse return null;
    return tv.descriptor;
}

/// ModuleWord represents a word definition captured from a loaded file
/// or registered in a virtual module.
pub const ModuleWord = struct {
    stack_effect: ?StackEffect = null,
    polymorphic: bool = false,
    markers: []const *Marker = &.{},
    source_module: ?*const Module = null,
    doc: ?[]const u8 = null,
    source_file: ?[]const u8 = null,
    source_line: usize = 0,
    source_column: usize = 0,
    provenance: ?WordProvenance = null,
    capability: Capability = .none,
    dispatch_id: u32 = 0,
    /// JIT dispatch table ID, populated when this word is registered for
    /// AOT-compiled execution. The runtime-image loader sets this from
    /// the embedded image so module-private dictionary entries can fall
    /// through to compiled dispatch when their compound body is the M1
    /// stub.
    word_id: ?u32 = null,
    action: Action,

    pub const Action = union(enum) {
        compound: []const Instruction,
        native: NativeFn,
        host_callback: HostCallback,
    };

    pub fn invoke(self: ModuleWord, ctx: *Context) anyerror!void {
        switch (self.action) {
            .native => |func| try func(ctx),
            .host_callback => |host| {
                const rc = host.callback(host.handle, host.user_data);
                if (rc != 0) return error.HostCallbackFailed;
            },
            .compound => unreachable,
        }
    }
};

/// Module represents a collection of word definitions loaded from a file.
/// Created by `load` and used for qualified name access (e.g., math.double).
pub const Module = struct {
    name: []const u8,
    words: std.StringHashMapUnmanaged(ModuleWord),
    /// Dependencies: words imported from other modules during loading.
    /// These are not part of the module's public API but are needed at
    /// runtime by the module's own words (late binding resolution).
    deps: std.StringHashMapUnmanaged(ModuleWord) = .{},
    /// Whether this module can be imported with `import`. Virtual modules
    /// like `native` set this to false.
    importable: bool = true,
    /// Pre-built deps-and-words frame for module-word calls; see `context.DepsFrameTemplate`.
    /// Null for a module that never had one built (an ad-hoc module), in which case
    /// `pushModuleDepsFrame` rebuilds the frame per entry.
    ///
    /// The template needs no invalidation because a module is immutable after it is built.
    /// `reload` produces a brand-new `Module`, and a runtime redefinition writes to a local frame
    /// or the global dictionary, never to `words`/`deps`. So the template always matches the module
    /// it hangs off. A future code path that mutates a templated module's `words` or `deps` in
    /// place must rebuild the template with `buildModuleDepsTemplate`, or the frame clones go stale.
    deps_template: ?context_mod.DepsFrameTemplate = null,
};

/// StackFrame represents a single frame in a stack trace.
pub const StackFrame = struct {
    word_name: []const u8,
    source: []const u8,
    line: usize,
};

/// ErrorObject represents a structured error with type, message, optional data, and optional stack trace.
pub const ErrorObject = struct {
    error_type: []const u8,
    message: []const u8,
    data: ?*const Value = null,
    stack_trace: ?[]const StackFrame = null,

    pub fn write(self: ErrorObject, writer: anytype) !void {
        try writer.print("<error {s}: {s}", .{ self.error_type, self.message });
        if (self.data) |data| {
            try writer.writeAll(" data=");
            try data.write(writer);
        }

        if (self.stack_trace) |trace| {
            try writer.writeAll(" [");
            for (trace, 0..) |frame, i| {
                if (i > 0) try writer.writeAll(" <- ");
                try writer.print("{s}:{d}:{s}", .{ frame.source, frame.line, frame.word_name });
            }
            try writer.writeAll("]");
        }
        try writer.writeAll(">");
    }

    pub fn eql(self: ErrorObject, other: ErrorObject) bool {
        if (!std.mem.eql(u8, self.error_type, other.error_type)) return false;
        if (!std.mem.eql(u8, self.message, other.message)) return false;

        // Compare data
        if (self.data == null and other.data == null) {
            // both null, ok
        } else if (self.data != null and other.data != null) {
            if (!self.data.?.eql(other.data.?.*)) return false;
        } else {
            return false;
        }

        // Compare stack traces
        if (self.stack_trace == null and other.stack_trace == null) return true;
        if (self.stack_trace == null or other.stack_trace == null) return false;

        const a = self.stack_trace.?;
        const b = other.stack_trace.?;
        if (a.len != b.len) return false;
        for (a, b) |fa, fb| {
            if (!std.mem.eql(u8, fa.word_name, fb.word_name)) return false;
            if (fa.line != fb.line) return false;
        }
        return true;
    }
};

/// Allocate an `ErrorObject` box on the given allocator and return its
/// pointer. The `error_value` `Value` variant stores this pointer; the
/// inner `error_type`, `message`, `data`, and `stack_trace` fields remain
/// owned by whatever allocator the caller used for them (typically the
/// per-context arena).
pub fn boxErrorObject(alloc: std.mem.Allocator, obj: ErrorObject) !*ErrorObject {
    const ptr = try alloc.create(ErrorObject);
    ptr.* = obj;
    return ptr;
}

/// Allocate a `BigIntManaged` box on the given allocator and return its
/// pointer, for a null-backed `BignumPayload` over arena memory. The limb
/// array is still owned by `obj.allocator`; box and limbs ride the arena's
/// lifetime. Reclaimable bignums go through `ownedBignumValue` instead.
pub fn boxBigInt(alloc: std.mem.Allocator, obj: BigIntManaged) !*BigIntManaged {
    const ptr = try alloc.create(BigIntManaged);
    ptr.* = obj;
    return ptr;
}

fn formatSpecEql(a: FormatSpec, b: FormatSpec) bool {
    return a.width == b.width and a.fill == b.fill and a.align_left == b.align_left;
}

fn templateSegmentEql(a: TemplateSegment, b: TemplateSegment) bool {
    const Tag = std.meta.Tag(TemplateSegment);
    if (@as(Tag, a) != @as(Tag, b)) return false;
    return switch (a) {
        .literal => |text| std.mem.eql(u8, text, b.literal),
        .identity => |spec| formatSpecEql(spec, b.identity),
        .named => |n| std.mem.eql(u8, n.name, b.named.name) and formatSpecEql(n.spec, b.named.spec),
        .indexed => |idx| idx.index == b.indexed.index and formatSpecEql(idx.spec, b.indexed.spec),
    };
}

fn instructionEql(a: Instruction, b: Instruction) bool {
    const Tag = std.meta.Tag(Instruction.Op);
    if (@as(Tag, a.op) != @as(Tag, b.op)) return false;
    return switch (a.op) {
        .push_literal => |va| va.eql(b.op.push_literal),
        .call_word => |na| std.mem.eql(u8, na, b.op.call_word),
        .call_word_direct => |slot| slot == b.op.call_word_direct,
        .call_word_module => |slot| slot == b.op.call_word_module,
    };
}

/// Quotation represents executable code with optional stack effect annotation.
pub const Quotation = struct {
    instructions: []const Instruction,
    /// If non-null, the expected stack effect for this quotation.
    /// Used for validation when the quotation is executed.
    effect: ?*const StackEffect = null,
    /// If non-null, a JIT-compiled native code pointer for this quotation's body.
    /// Used by the JIT compiler for indirect calls via `call`.
    code_ptr: ?*const anyopaque = null,

    pub fn eql(self: Quotation, other: Quotation) bool {
        if (self.instructions.len != other.instructions.len) return false;
        for (self.instructions, other.instructions) |ai, bi| {
            if (!instructionEql(ai, bi)) return false;
        }
        // Compare effects
        if (self.effect == null and other.effect == null) return true;
        if (self.effect == null or other.effect == null) return false;
        return self.effect.?.eql(other.effect.?.*);
    }
};

/// One step of a Closure: the captured values pushed before, and the compiled
/// code_ptr of, one already-compiled base body. `curry`/`compose` decompose into
/// an ordered list of these so the interpreter-free compiled `call` can push the
/// captures and jump to each base in turn (push-then-call).
pub const Segment = struct {
    captures: []const Value,
    base_code_ptr: *const anyopaque,
};

/// A Closure is the compiled form of a `curry`/`compose` result: a quotation
/// whose body is an ordered list of segments over already-compiled bases. It is
/// an internal optimization of a quotation, not a distinct user-visible type --
/// it presents as a quotation everywhere (predicates, inspect, equality). The
/// `instructions` field carries the full `[push captures] ++ base...` body so the
/// interpreter can re-execute it; `segments` is the fast path used only by the
/// compiled runtime-selected `call`.
pub const Closure = struct {
    instructions: []const Instruction,
    effect: ?*const StackEffect = null,
    segments: []const Segment,

    /// The lexical scope captured where this closure was created, carried by
    /// `curry`/`compose` off the base quotation, or built directly by
    /// `Context.promoteToClosure` when a plain quotation literal is promoted on
    /// push. It rides the value across every spawn boundary, so a curried
    /// closure resolves its bare words at its creation site no matter which
    /// task later runs it. Null when the base closed over no lexical binding.
    ///
    /// Either a deep copy this closure owns (`owns_scope`), or the scope of a
    /// retained base closure, kept alive through `bases`. Never a shared
    /// pointer into a context's refcounted capture map, which is free to
    /// supersede and free its own entries as the same body is pushed again
    /// elsewhere. See `context.CapturedScope`.
    captured_scope: ?*const context_mod.CapturedScope = null,

    /// Refcounted lifecycle header. Every closure carries one. A task-boundary
    /// deep copy's header lives on the destination task arena, and the copy
    /// rides the arena like the other cross-task copies; its destroy frees
    /// nothing real beyond the scope copy's own binding references.
    header: @import("container_backing.zig").ContainerHeader,

    /// Ownership follows "own what you allocate, retain what you alias": the
    /// destroy path frees exactly what the creation site freshly allocated on
    /// `header.allocator`, and releases `bases`, the source closures whose
    /// memory this one still references.
    ///
    /// `owns_body` covers the instruction slice plus the container-literal
    /// references embedded in it; `curry`/`compose` build a fresh body, while
    /// a push-time promotion aliases the module-owned literal. `owns_segments`
    /// covers the segments slice and every captures slice in it; the capture
    /// values themselves are borrows whose owning references live in the owned
    /// body or in a retained base's. `owns_scope` covers `captured_scope`, and
    /// is false when the scope is shared from a base.
    owns_body: bool = false,
    owns_segments: bool = false,
    owns_scope: bool = false,
    bases: []const *Closure = &.{},

    // The freestanding mirror in capi_freestanding.zig re-declares the three leading fields
    // and reads `segments` through its own layout. Both declarations pin the offsets to the
    // same constants, so a compiler reordering on either side fails the build.
    comptime {
        std.debug.assert(@offsetOf(Closure, "instructions") == 0);
        std.debug.assert(@offsetOf(Closure, "effect") == 16);
        std.debug.assert(@offsetOf(Closure, "segments") == 24);
    }

    /// Allocate a closure on `allocator` from a template whose `header` field
    /// is ignored, initializing the refcount at 1. The caller transfers that
    /// creation reference (`pushMoved`, container adoption) or releases it.
    pub fn create(allocator: std.mem.Allocator, template: Closure) error{OutOfMemory}!*Closure {
        const self = try allocator.create(Closure);
        self.* = template;
        self.header.init(allocator, destroyClosure);
        return self;
    }

    /// View the closure body as a plain quotation for interpreter execution and
    /// the reuse of quotation formatting/equality/hashing. `code_ptr` is null so
    /// the interpreter runs `instructions` rather than dispatching a base.
    pub fn asQuotation(self: *const Closure) Quotation {
        return .{ .instructions = self.instructions, .effect = self.effect };
    }

    /// Whether this closure's body is heap-owned somewhere in its retained chain: by the closure
    /// itself, or by a base whose body it aliases, which is the `attach-stack-effect` shape. A
    /// push-time promotion aliases a durable module body instead, so its chain owns nothing. `;`
    /// keys its release-path handoff on this: a chain-owned body is released by the owning
    /// closure's destroy, so it must not also sit on a dictionary release list.
    pub fn ownsBodyTransitively(self: *const Closure) bool {
        if (self.owns_body) return true;
        for (self.bases) |base| {
            if (base.instructions.ptr == self.instructions.ptr and base.ownsBodyTransitively()) return true;
        }
        return false;
    }

    /// Release-to-zero callback. Frees memory only; it never executes user code.
    fn destroyClosure(header: *@import("container_backing.zig").ContainerHeader) void {
        const cb = @import("container_backing.zig");
        const self: *Closure = @fieldParentPtr("header", header);
        const alloc = header.allocator;

        if (self.owns_body) {
            cb.releaseInstructionsContainerLiterals(self.instructions);
            alloc.free(self.instructions);
        }

        if (self.owns_segments) {
            for (self.segments) |seg| alloc.free(seg.captures);
            alloc.free(self.segments);
        }

        if (self.owns_scope) {
            if (self.captured_scope) |scope| @constCast(scope).release();
        }

        for (self.bases) |base| base.header.release();
        alloc.free(self.bases);

        alloc.destroy(self);
    }
};

fn writeTemplateSegment(writer: anytype, seg: TemplateSegment) !void {
    // XXX(ripta): omg, ew
    switch (seg) {
        .literal => |text| {
            for (text) |ch| {
                if (ch == '{' or ch == '}' or ch == '"' or ch == '\\') {
                    try writer.writeByte('\\');
                }
                try writer.writeByte(ch);
            }
        },
        .identity => |spec| {
            try writer.writeByte('{');
            try writeFormatSpec(writer, spec);
            try writer.writeByte('}');
        },
        .named => |n| {
            try writer.writeByte('{');
            try writer.writeAll(n.name);
            try writeFormatSpec(writer, n.spec);
            try writer.writeByte('}');
        },
        .indexed => |idx| {
            try writer.writeByte('{');
            try writer.print("{d}", .{idx.index});
            try writeFormatSpec(writer, idx.spec);
            try writer.writeByte('}');
        },
    }
}

fn writeFormatSpec(writer: anytype, spec: FormatSpec) !void {
    const has_spec = spec.width != null or spec.fill != ' ' or spec.align_left;
    if (!has_spec) return;
    try writer.writeByte(':');
    var need_comma = false;
    if (spec.width) |w| {
        try writer.print("width={d}", .{w});
        need_comma = true;
    }
    if (spec.fill != ' ') {
        if (need_comma) try writer.writeByte(',');
        try writer.print("fill={c}", .{spec.fill});
        need_comma = true;
    }
    if (spec.align_left) {
        if (need_comma) try writer.writeByte(',');
        try writer.writeAll("align=left");
    }
}

/// View a `.quotation` or `.closure` value as a plain `Quotation`, for equality comparisons that
/// treat the two tags as the same callable shape. Asserts on any other tag.
fn callableView(v: Value) Quotation {
    return switch (v) {
        .quotation => |q| q,
        .closure => |c| c.asQuotation(),
        else => unreachable,
    };
}

/// Value represents any value that can be stored on the stack.
pub const Value = union(enum) {
    fixnum: i64,
    float: f64,
    bignum: BignumPayload,
    boolean: bool,
    string: StringPayload,
    symbol: StringPayload,
    array: *Array,
    quotation: Quotation,
    closure: *Closure,
    hash: *HashTable,
    vector: *Vector,
    byte_array: *ByteArray,
    set: *Set,
    mutable_map: *MutableMap,
    stream: *Stream,
    resource: *Resource,
    parameter: *Parameter,
    module: *Module,
    marker: *Marker,
    struct_type: *StructType,
    struct_instance: *StructInstance,
    tagged: TaggedPayload,
    template: []const TemplateSegment,
    stack_effect: StackEffect,
    error_value: *ErrorObject,
    task: *Task,
    channel: *Channel,
    iterator: *Iterator,
    doc_string: []const u8,
    type_val: *TypeValue,
    type_descriptor: *const TypeDescriptor,
    protocol_descriptor: *const ProtocolDescriptor,
    constraint_combinator: *const ConstraintCombinator,
    sandbox_spec: *SandboxSpec,
    unit: void,

    pub fn write(self: Value, writer: anytype) anyerror!void {
        switch (self) {
            .fixnum => |i| try writer.print("{d}", .{i}),
            .float => |f| {
                if (std.math.isNan(f)) {
                    try writer.writeAll("nan");
                } else if (std.math.isInf(f)) {
                    if (f < 0) try writer.writeByte('-');
                    try writer.writeAll("inf");
                } else {
                    var buf: [64]u8 = undefined;
                    const formatted = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
                    try writer.writeAll(formatted);
                    if (std.mem.indexOfScalar(u8, formatted, '.') == null) {
                        try writer.writeAll(".0");
                    }
                }
            },
            .bignum => |b| {
                const str = try b.big.toConst().toStringAlloc(b.big.allocator, 10, .lower);
                defer b.big.allocator.free(str);
                try writer.writeAll(str);
            },
            .boolean => |b| try writer.writeAll(if (b) "t" else "f"),
            .string => |s| try writer.print("\"{s}\"", .{s.bytes}),
            .symbol => |s| try writer.print("{s}:", .{s.bytes}),
            .array => |arr| {
                try writer.writeAll("{ ");
                for (arr.items) |item| {
                    try item.write(writer);
                    try writer.writeAll(" ");
                }
                try writer.writeAll("}");
            },
            .quotation => |quot| {
                try writer.writeAll("[ ");
                for (quot.instructions) |instr| {
                    switch (instr.op) {
                        .push_literal => |v| {
                            try v.write(writer);
                            try writer.writeAll(" ");
                        },
                        .call_word => |name| try writer.print("{s} ", .{name}),
                        .call_word_direct, .call_word_module => |slot| try writer.print("{s} ", .{slot.name}),
                    }
                }
                try writer.writeAll("]");
            },
            .closure => |c| try (Value{ .quotation = c.asQuotation() }).write(writer),
            // TODO(ripta): This is currently tightly-coupled to the internal
            // representation of HashTable, despite H{ } being a non-native
            // implementation in the prelude.
            .hash => |h| {
                try writer.writeAll("H{ ");
                var iter = h.map.iterator();
                while (iter.next()) |entry| {
                    try writer.print("{s}: ", .{entry.key_ptr.*});
                    try entry.value_ptr.write(writer);
                    try writer.writeAll(" ");
                }
                try writer.writeAll("}");
            },
            .vector => |v| {
                try writer.writeAll("V{ ");
                for (v.list.items) |item| {
                    try item.write(writer);
                    try writer.writeAll(" ");
                }
                try writer.writeAll("}");
            },
            .byte_array => |b| {
                try writer.writeAll("B{ ");
                for (b.slice()) |byte| {
                    try writer.print("0x{X:0>2} ", .{byte});
                }
                try writer.writeAll("}");
            },
            .set => |s| {
                try writer.writeAll("S{ ");
                for (s.map.keys()) |key| {
                    try key.write(writer);
                    try writer.writeAll(" ");
                }
                try writer.writeAll("}");
            },
            .mutable_map => |m| {
                try writer.writeAll("M{ ");
                var iter = m.map.iterator();
                while (iter.next()) |entry| {
                    try writer.print("{s}: ", .{entry.key_ptr.*});
                    try entry.value_ptr.write(writer);
                    try writer.writeAll(" ");
                }
                try writer.writeAll("}");
            },
            .stream => |s| {
                if (s.closed) {
                    try writer.print("<stream {s} (closed)>", .{s.name});
                } else {
                    try writer.writeAll("<stream ");
                    // Walk the wrapper chain from outermost to innermost to
                    // build labels like "tls fd" or "compress tls fd".
                    var cur: ?*const Stream = s;
                    var first = true;
                    while (cur) |c| {
                        if (!first) try writer.writeAll(" ");
                        first = false;
                        try writer.writeAll(c.name);
                        cur = c.inner;
                    }
                    try writer.print(" {s}>", .{s.mode.toString()});
                }
            },
            .resource => |r| {
                if (r.closed) {
                    try writer.print("<resource:{s} (closed)>", .{r.type_name});
                } else {
                    try writer.print("<resource:{s}>", .{r.type_name});
                }
            },
            .parameter => |p| try writer.print("<parameter:{s}>", .{p.name}),
            .module => |m| try writer.print("<module:{s} ({d} words)>", .{ m.name, m.words.count() }),
            .marker => |mk| {
                if (mk.name.len == 0) {
                    try writer.writeAll("<marker>");
                } else {
                    try writer.print("<marker:{s}>", .{mk.name});
                }
            },
            .struct_type => |st| try writer.print("<struct-type:{s}>", .{st.name}),
            .struct_instance => |si| {
                try writer.print("{s}{{ ", .{si.struct_type.name});
                for (si.struct_type.fields, 0..) |field, i| {
                    try writer.print("{s}: ", .{field});
                    try si.fields[i].write(writer);
                    try writer.writeAll(" ");
                }
                try writer.writeAll("}");
            },
            .tagged => |t| {
                try writer.print("<{s} ", .{t.tag.name});
                try t.inner.write(writer);
                try writer.writeAll(">");
            },
            .template => |segments| {
                try writer.writeAll("T\"");
                for (segments) |seg| {
                    try writeTemplateSegment(writer, seg);
                }
                try writer.writeByte('"');
            },
            .stack_effect => |effect| try effect.write(writer),
            .error_value => |err| try err.write(writer),
            .task => |t| {
                const status = t.getStatus();
                if (t.name) |name| {
                    try writer.print("<task #{d} ({s}) {s}>", .{
                        t.id,
                        name,
                        @tagName(status),
                    });
                } else {
                    try writer.print("<task #{d} {s}>", .{
                        t.id,
                        @tagName(status),
                    });
                }
            },
            .channel => |ch| {
                if (ch.capacity == 0) {
                    try writer.writeAll("<channel unbuffered>");
                } else {
                    try writer.print("<channel capacity={d}>", .{ch.capacity});
                }
            },
            .iterator => |it| {
                try writer.print("<iterator {s} ", .{it.kindName()});
                try it.progressDisplay(writer);
                try writer.writeAll(">");
            },
            .doc_string => |s| try writer.print("<doc-string \"{s}\">", .{s}),
            .type_val => |tv| try writer.print("<type:{s}>", .{tv.name}),
            .type_descriptor => |desc| try writer.print("<type-descriptor:{s}>", .{typeKindSymbol(desc.kind)}),
            .protocol_descriptor => |desc| try writer.print("<protocol-descriptor:{s}>", .{desc.name}),
            .constraint_combinator => |cc| try writer.print("<constraint-combinator:{d}>", .{cc.combinator_id}),
            .sandbox_spec => |spec| try spec.writeGranted(writer),
            .unit => try writer.writeAll("unit"),
        }
    }

    pub fn eql(self: Value, other: Value) bool {
        // A closure is a quotation literal promoted at push time when it closed over an outer
        // local (see `Context.captureQuotationScope`); it presents as a quotation everywhere else
        // (predicates, inspect), so equality compares both sides structurally as quotations
        // regardless of which side was promoted.
        const self_is_callable = self == .quotation or self == .closure;
        const other_is_callable = other == .quotation or other == .closure;
        if (self_is_callable and other_is_callable) {
            return callableView(self).eql(callableView(other));
        }

        const Tag = std.meta.Tag(Value);
        if (@as(Tag, self) != @as(Tag, other)) {
            return false;
        }

        return switch (self) {
            .fixnum => |a| a == other.fixnum,
            .float => |a| a == other.float,
            .bignum => |a| a.big.toConst().eql(other.bignum.big.toConst()),
            .boolean => |a| a == other.boolean,
            .string => |a| simd.eqlBytes(a.bytes, other.string.bytes),
            .symbol => |a| simd.eqlBytes(a.bytes, other.symbol.bytes),
            .array => |a| {
                const b = other.array;
                if (a == b) return true;
                if (a.items.len != b.items.len) return false;
                for (a.items, b.items) |ai, bi| {
                    if (!ai.eql(bi)) return false;
                }
                return true;
            },
            // Handled by the callable check above.
            .quotation, .closure => unreachable,
            // TODO(ripta): This is currently tightly-coupled to the internal
            // representation of HashTable, despite H{ } being a non-native
            // implementation in the prelude.
            .hash => |a| {
                const b = other.hash;
                if (a.map.count() != b.map.count()) return false;
                var iter = a.map.iterator();
                while (iter.next()) |entry| {
                    if (b.map.get(entry.key_ptr.*)) |bval| {
                        if (!entry.value_ptr.eql(bval)) return false;
                    } else {
                        return false;
                    }
                }
                return true;
            },
            .vector => |a| {
                const b = other.vector;
                if (a.list.items.len != b.list.items.len) return false;
                for (a.list.items, b.list.items) |ai, bi| {
                    if (!ai.eql(bi)) return false;
                }
                return true;
            },
            .byte_array => |a| {
                const b = other.byte_array;
                return simd.eqlBytes(a.slice(), b.slice());
            },
            // Sets use order-independent equality: two sets are equal if they
            // contain the same elements regardless of iteration order.
            .set => |a| {
                const b = other.set;
                if (a.map.count() != b.map.count()) return false;
                // Check that every element in a exists in b (O(n) with O(1) lookups)
                for (a.map.keys()) |key| {
                    if (!b.map.contains(key)) return false;
                }
                return true;
            },
            .mutable_map => |a| {
                const b = other.mutable_map;
                if (a.map.count() != b.map.count()) return false;
                var iter = a.map.iterator();
                while (iter.next()) |entry| {
                    if (b.map.get(entry.key_ptr.*)) |bval| {
                        if (!entry.value_ptr.eql(bval)) return false;
                    } else {
                        return false;
                    }
                }
                return true;
            },
            // Streams are equal if they refer to the same underlying file handle
            .stream => |a| a == other.stream,
            // Resources are equal if same type name and same pointer
            .resource => |a| {
                const b = other.resource;
                return std.mem.eql(u8, a.type_name, b.type_name) and a.ptr == b.ptr;
            },
            // Parameters are equal if they refer to the same parameter object
            .parameter => |a| a == other.parameter,
            // Modules are equal if they refer to the same module object
            .module => |a| a == other.module,
            // Markers are equal if they refer to the same marker object
            .marker => |a| a == other.marker,
            // Struct types are equal if they refer to the same type object
            .struct_type => |a| a == other.struct_type,
            // Struct instances are equal if same type and all fields equal
            .struct_instance => |a| {
                const b = other.struct_instance;
                if (structTypeDescriptor(a.struct_type)) |a_desc| {
                    const b_desc = structTypeDescriptor(b.struct_type) orelse return false;
                    if (a_desc != b_desc) return false;
                } else if (a.struct_type != b.struct_type) return false;
                for (a.fields, b.fields) |af, bf| {
                    if (!af.eql(bf)) return false;
                }
                return true;
            },
            // Tagged values are equal if same tag pointer and inner values equal
            .tagged => |a| {
                const b = other.tagged;
                return a.tag == b.tag and a.inner.eql(b.inner.*);
            },
            .template => |a| {
                const b = other.template;

                if (a.len != b.len) return false;
                for (a, b) |sa, sb| {
                    if (!templateSegmentEql(sa, sb)) return false;
                }
                return true;
            },
            .stack_effect => |a| a.eql(other.stack_effect),
            .error_value => |a| a.eql(other.error_value.*),
            .task => |a| a == other.task,
            .channel => |a| a == other.channel,
            .iterator => |a| a == other.iterator,
            .doc_string => |a| std.mem.eql(u8, a, other.doc_string),
            .type_val => |a| {
                const b = other.type_val;
                if (a.descriptor) |a_desc| {
                    return b.descriptor != null and a_desc == b.descriptor.?;
                }
                return b.descriptor == null and a == b;
            },
            .type_descriptor => |a| a == other.type_descriptor,
            .protocol_descriptor => |a| a == other.protocol_descriptor,
            .constraint_combinator => |a| a == other.constraint_combinator,
            .sandbox_spec => |a| a == other.sandbox_spec,
            .unit => true,
        };
    }

    /// Compute a hash value for this Value.
    /// Used by hash-based containers like Set.
    pub fn hashValue(self: Value) u64 {
        const Hasher = std.hash.Wyhash;
        var hasher = Hasher.init(0);

        // Hash the tag first to distinguish types. A closure hashes under the quotation tag since
        // it presents as a quotation everywhere else (predicates, inspect, equality).
        const Tag = std.meta.Tag(Value);
        const tag_for_hash: Tag = if (self == .closure) .quotation else @as(Tag, self);
        const tag = @intFromEnum(tag_for_hash);
        hasher.update(std.mem.asBytes(&tag));

        switch (self) {
            .fixnum => |i| hasher.update(std.mem.asBytes(&i)),
            .float => |f| {
                var canonical = f;
                if (canonical == 0.0) canonical = 0.0;
                hasher.update(std.mem.asBytes(&canonical));
            },
            .bignum => |b| {
                const c = b.big.toConst();
                const positive_byte: u8 = if (c.positive) 1 else 0;
                hasher.update(&.{positive_byte});
                for (c.limbs[0..c.limbs.len]) |limb| {
                    hasher.update(std.mem.asBytes(&limb));
                }
            },
            .boolean => |b| hasher.update(std.mem.asBytes(&b)),
            .string, .symbol => |s| hasher.update(s.bytes),
            .array => |arr| {
                for (arr.items) |elem| {
                    const elem_hash = elem.hashValue();
                    hasher.update(std.mem.asBytes(&elem_hash));
                }
            },
            .quotation => |quot| {
                for (quot.instructions) |instr| {
                    const line_hash = instr.line;
                    hasher.update(std.mem.asBytes(&line_hash));
                    switch (instr.op) {
                        .push_literal => |v| {
                            const v_hash = v.hashValue();
                            hasher.update(std.mem.asBytes(&v_hash));
                        },
                        .call_word => |name| hasher.update(name),
                        .call_word_direct, .call_word_module => |slot| hasher.update(slot.name),
                    }
                }
            },
            .closure => |c| {
                for (c.instructions) |instr| {
                    const line_hash = instr.line;
                    hasher.update(std.mem.asBytes(&line_hash));
                    switch (instr.op) {
                        .push_literal => |v| {
                            const v_hash = v.hashValue();
                            hasher.update(std.mem.asBytes(&v_hash));
                        },
                        .call_word => |name| hasher.update(name),
                        .call_word_direct, .call_word_module => |slot| hasher.update(slot.name),
                    }
                }
            },
            .hash => |h| {
                // Order-independent hash using XOR
                var combined: u64 = 0;
                var iter = h.map.iterator();
                while (iter.next()) |entry| {
                    var pair_hasher = Hasher.init(0);
                    pair_hasher.update(entry.key_ptr.*);
                    const val_hash = entry.value_ptr.hashValue();
                    pair_hasher.update(std.mem.asBytes(&val_hash));
                    combined ^= pair_hasher.final();
                }
                hasher.update(std.mem.asBytes(&combined));
            },
            .vector => |v| {
                for (v.list.items) |elem| {
                    const elem_hash = elem.hashValue();
                    hasher.update(std.mem.asBytes(&elem_hash));
                }
            },
            .byte_array => |b| hasher.update(b.slice()),
            .set => |s| {
                // Order-independent hash using XOR
                var combined: u64 = 0;
                for (s.map.keys()) |key| {
                    combined ^= key.hashValue();
                }
                hasher.update(std.mem.asBytes(&combined));
            },
            .mutable_map => |m| {
                // Order-independent hash using XOR (same as immutable hash)
                var combined: u64 = 0;
                var iter = m.map.iterator();
                while (iter.next()) |entry| {
                    var pair_hasher = Hasher.init(0);
                    pair_hasher.update(entry.key_ptr.*);
                    const val_hash = entry.value_ptr.hashValue();
                    pair_hasher.update(std.mem.asBytes(&val_hash));
                    combined ^= pair_hasher.final();
                }
                hasher.update(std.mem.asBytes(&combined));
            },
            // Streams hash by pointer identity (same as equality)
            .stream => |s| {
                const ptr_val = @intFromPtr(s);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            // Resources hash by type name and pointer address
            .resource => |r| {
                hasher.update(r.type_name);
                const ptr_val = @intFromPtr(r.ptr);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            // Parameters hash by pointer identity (same as equality)
            .parameter => |p| {
                const ptr_val = @intFromPtr(p);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            // Modules hash by pointer identity (same as equality)
            .module => |m| {
                const ptr_val = @intFromPtr(m);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            // Markers hash by pointer identity (same as equality)
            .marker => |mk| {
                const ptr_val = @intFromPtr(mk);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            // Struct types hash by pointer identity (same as equality)
            .struct_type => |st| {
                const ptr_val = @intFromPtr(st);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            // Struct instances hash by type pointer and field values
            .struct_instance => |si| {
                const ptr_val = @intFromPtr(si.struct_type);
                hasher.update(std.mem.asBytes(&ptr_val));
                for (si.fields) |field| {
                    const field_hash = field.hashValue();
                    hasher.update(std.mem.asBytes(&field_hash));
                }
            },
            // Tagged values hash by tag pointer and inner value
            .tagged => |t| {
                const ptr_val = @intFromPtr(t.tag);
                hasher.update(std.mem.asBytes(&ptr_val));
                const inner_hash = t.inner.hashValue();
                hasher.update(std.mem.asBytes(&inner_hash));
            },
            .template => |segments| {
                for (segments) |seg| {
                    switch (seg) {
                        .literal => |text| hasher.update(text),
                        .identity => hasher.update("{}"),
                        .named => |n| hasher.update(n.name),
                        .indexed => |idx| hasher.update(std.mem.asBytes(&idx.index)),
                    }
                }
            },
            .stack_effect => |effect| {
                for (effect.inputs) |param| {
                    hasher.update(param.name);
                }
                hasher.update("--");
                for (effect.outputs) |param| {
                    hasher.update(param.name);
                }
            },
            .error_value => |err| {
                hasher.update(err.error_type);
                hasher.update(err.message);
                if (err.data) |data| {
                    const data_hash = data.hashValue();
                    hasher.update(std.mem.asBytes(&data_hash));
                }
            },
            // Tasks hash by pointer identity (same as equality)
            .task => |t| {
                const ptr_val = @intFromPtr(t);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            .channel => |ch| {
                const ptr_val = @intFromPtr(ch);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            .iterator => |it| {
                const ptr_val = @intFromPtr(it);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            .doc_string => |s| hasher.update(s),
            .type_val => |tv| {
                const ptr_val = @intFromPtr(tv);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            .type_descriptor => |desc| {
                const ptr_val = @intFromPtr(desc);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            .protocol_descriptor => |desc| {
                const ptr_val = @intFromPtr(desc);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            .constraint_combinator => |cc| {
                const ptr_val = @intFromPtr(cc);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            .sandbox_spec => |spec| {
                const ptr_val = @intFromPtr(spec);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            .unit => {},
        }

        return hasher.final();
    }
};

// Size budget for the Value union. The largest variants, which are currently ErrorObject and BigIntManaged,
// are heap-indirected, so the union body is currently driven by Quotation and StackEffect at 32 bytes plus
// the 4-byte tag and padding on 64-bit hosts. On wasm32's 4-byte pointers those same variants are 16 bytes
// (20 with the tag), but an 8-byte-aligned payload elsewhere in the union (e.g. an f64/i64-bearing variant)
// forces the union's overall alignment to 8, rounding the total up to 24; this is asserted, not merely
// tolerated, so a genuine wasm32 regression still trips.
//
// A regression here multiplies across every stack slot, every array element, every hash bucket value, and
// every push_literal instruction. If a new variant pushes the union wider, change this assertion deliberately.
comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(Value) == 40);
    } else if (@sizeOf(usize) == 4) {
        std.debug.assert(@sizeOf(Value) == 24);
    }
}

// =============================================================================
// Tests
// =============================================================================

test "fixnum format" {
    const val = Value{ .fixnum = 42 };
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("42", fbs.getWritten());
}

test "negative fixnum format" {
    const val = Value{ .fixnum = -123 };
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("-123", fbs.getWritten());
}

test "fixnum equality" {
    const a = Value{ .fixnum = 42 };
    const b = Value{ .fixnum = 42 };
    const c = Value{ .fixnum = 100 };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "float format" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const val = Value{ .float = 3.14 };
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("3.14", fbs.getWritten());
}

test "float format whole number" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const val = Value{ .float = 3.0 };
    try val.write(fbs.writer());
    const written = fbs.getWritten();
    try std.testing.expect(std.mem.indexOfScalar(u8, written, '.') != null);
}

test "float format nan" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const val = Value{ .float = std.math.nan(f64) };
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("nan", fbs.getWritten());
}

test "float format inf" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const val = Value{ .float = std.math.inf(f64) };
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("inf", fbs.getWritten());
}

test "float format negative inf" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const val = Value{ .float = -std.math.inf(f64) };
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("-inf", fbs.getWritten());
}

test "float equality" {
    const a = Value{ .float = 3.14 };
    const b = Value{ .float = 3.14 };
    const c = Value{ .float = 2.71 };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "float nan inequality" {
    const a = Value{ .float = std.math.nan(f64) };
    const b = Value{ .float = std.math.nan(f64) };
    try std.testing.expect(!a.eql(b));
}

test "float signed zero equality" {
    const pos = Value{ .float = 0.0 };
    const neg = Value{ .float = -0.0 };
    try std.testing.expect(pos.eql(neg));
}

test "float signed zero hash equality" {
    const pos = Value{ .float = 0.0 };
    const neg = Value{ .float = -0.0 };
    try std.testing.expectEqual(pos.hashValue(), neg.hashValue());
}

test "float vs fixnum not equal" {
    const f = Value{ .float = 42.0 };
    const i = Value{ .fixnum = 42 };
    try std.testing.expect(!f.eql(i));
}

test "stack effect format" {
    const val = Value{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    } };
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("( n -- n )", fbs.getWritten());
}

test "stack effect equality" {
    const a = Value{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    } };
    const b = Value{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    } };
    const c = Value{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{ .{ .name = "a" }, .{ .name = "b" } },
        .outputs = &[_]StackEffectParam{.{ .name = "c" }},
    } };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "stack effect not equal to other types" {
    const effect = Value{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    } };
    const str = stringValue("n -- n");
    const sym = symbolValue("n -- n");

    try std.testing.expect(!effect.eql(str));
    try std.testing.expect(!effect.eql(sym));
}

test "marker format" {
    var anon = Marker{ .name = "" };
    var named = Marker{ .name = "test-marker" };

    const anon_marker = Value{ .marker = &anon };
    const named_marker = Value{ .marker = &named };

    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try anon_marker.write(fbs.writer());
    try std.testing.expectEqualStrings("<marker>", fbs.getWritten());

    fbs.reset();

    try named_marker.write(fbs.writer());
    try std.testing.expectEqualStrings("<marker:test-marker>", fbs.getWritten());
}

test "marker equality" {
    var m1 = Marker{ .name = "marker" };
    var m2 = Marker{ .name = "marker" };

    const marker1 = &m1;
    const marker2 = &m2;
    const marker3 = marker1;

    const val1 = Value{ .marker = marker1 };
    const val2 = Value{ .marker = marker2 };
    const val3 = Value{ .marker = marker3 };

    try std.testing.expect(!val1.eql(val2));
    try std.testing.expect(val1.eql(val3));
}

test "boolean equality" {
    const t1 = Value{ .boolean = true };
    const t2 = Value{ .boolean = true };
    const f1 = Value{ .boolean = false };

    try std.testing.expect(t1.eql(t2));
    try std.testing.expect(!t1.eql(f1));
}

test "string equality" {
    const a = stringValue("hello");
    const b = stringValue("hello");
    const c = stringValue("world");

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "symbol equality" {
    const a = symbolValue("foo");
    const b = symbolValue("foo");
    const c = symbolValue("bar");

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "byte array slice owned" {
    var items = [_]u8{ 0x01, 0x7F, 0xFF };
    const backing = std.ArrayListUnmanaged(u8){
        .items = items[0..],
        .capacity = items.len,
    };
    const ba = ByteArray{
        .header = undefined,
        .items = items[0..],
        .owned_items = backing,
        .storage = .owned,
    };

    try std.testing.expectEqualSlices(u8, items[0..], ba.slice());
}

test "byte array slice borrowed" {
    var items = [_]u8{ 0x10, 0x20, 0x30 };
    const ba = ByteArray{
        .header = undefined,
        .items = items[0..],
        .storage = .{ .borrowed = items[0..] },
    };

    try std.testing.expectEqualSlices(u8, items[0..], ba.slice());
}

test "makeBorrowedByteArray constructs borrowed storage" {
    var items = [_]u8{ 0xAA, 0xBB, 0xCC };
    const ba = try makeBorrowedByteArray(std.testing.allocator, items[0..]);
    defer std.testing.allocator.destroy(ba);

    try std.testing.expect(ba.isBorrowed());
    try std.testing.expectEqualSlices(u8, items[0..], ba.slice());
    try std.testing.expectEqual(@intFromPtr(items[0..].ptr), @intFromPtr(ba.slice().ptr));
}

test "string backing adoptOwned lifecycle balances retain and release" {
    const cb = @import("container_backing.zig");
    const bytes = try std.testing.allocator.dupe(u8, "hello");
    const val = try ownedStringValue(std.testing.allocator, bytes);
    try std.testing.expectEqualStrings("hello", val.string.bytes);
    try std.testing.expect(val.string.backing != null);

    // A second owner retains; both releases drop, and the leak detector proves the free.
    cb.retainValue(val);
    cb.releaseValue(val);
    cb.releaseValue(val);
}

test "string sub-slice shares the parent backing" {
    const cb = @import("container_backing.zig");
    const bytes = try std.testing.allocator.dupe(u8, "hello world");
    const val = try ownedStringValue(std.testing.allocator, bytes);

    const sub = Value{ .string = val.string.sub(val.string.bytes[6..]) };
    try std.testing.expectEqualStrings("world", sub.string.bytes);
    try std.testing.expectEqual(val.string.backing, sub.string.backing);

    // The sub-slice's own retain keeps the bytes alive past the parent's release.
    cb.retainValue(sub);
    cb.releaseValue(val);
    try std.testing.expectEqualStrings("world", sub.string.bytes);
    cb.releaseValue(sub);
}

test "bignum backing adopt lifecycle balances retain and release" {
    const cb = @import("container_backing.zig");
    const big = try BigIntManaged.initSet(std.testing.allocator, 123456789);
    const val = try ownedBignumValue(std.testing.allocator, big);
    try std.testing.expect(val.bignum.backing != null);
    try std.testing.expect(cb.valueCarriesBacking(val));

    // A second owner retains; both releases drop, and the leak detector proves
    // the backing and the limb array are both freed.
    cb.retainValue(val);
    cb.releaseValue(val);
    cb.releaseValue(val);
}

test "demoteBignum wraps an oversized value in an owned backing and deinits a fitting one" {
    const cb = @import("container_backing.zig");
    const helpers = @import("primitives/helpers.zig");

    const small = try BigIntManaged.initSet(std.testing.allocator, 42);
    const small_val = try helpers.demoteBignum(std.testing.allocator, small);
    try std.testing.expectEqual(Value{ .fixnum = 42 }, small_val);

    var large = try BigIntManaged.initSet(std.testing.allocator, std.math.maxInt(i64));
    try large.addScalar(&large, 1);
    const large_val = try helpers.demoteBignum(std.testing.allocator, large);
    try std.testing.expect(large_val == .bignum);
    try std.testing.expect(large_val.bignum.backing != null);
    cb.releaseValue(large_val);
}

test "null-backed bignum retain and release are no-ops" {
    const cb = @import("container_backing.zig");
    var big = try BigIntManaged.initSet(std.testing.allocator, 7);
    defer big.deinit();
    const val = Value{ .bignum = .{ .big = &big } };
    try std.testing.expect(!cb.valueCarriesBacking(val));
    cb.retainValue(val);
    cb.releaseValue(val);
    cb.releaseValue(val);
    try std.testing.expectEqual(@as(i64, 7), try val.bignum.big.toInt(i64));
}

test "tagged backing adopt lifecycle balances retain and release" {
    const cb = @import("container_backing.zig");
    const vec = try Vector.create(std.testing.allocator);
    var dummy_vt: VirtualType = undefined;
    const val = try ownedTaggedValue(std.testing.allocator, &dummy_vt, .{ .vector = vec });
    try std.testing.expect(val.tagged.backing != null);
    try std.testing.expect(cb.valueCarriesBacking(val));

    // A second owner retains the backing header only; the inner vector's single
    // reference belongs to the backing. Both releases drop, and the leak
    // detector proves the box and the vector are both freed.
    cb.retainValue(val);
    try std.testing.expectEqual(@as(u32, 2), val.tagged.backing.?.header.refcountValue());
    try std.testing.expectEqual(@as(u32, 1), vec.header.refcountValue());
    cb.releaseValue(val);
    cb.releaseValue(val);
}

test "null-backed string retain and release are no-ops" {
    const cb = @import("container_backing.zig");
    const val = stringValue("static");
    cb.retainValue(val);
    cb.releaseValue(val);
    cb.releaseValue(val);
    try std.testing.expectEqualStrings("static", val.string.bytes);
}

test "byte array value uses slice for equality write and hash" {
    var owned_items = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const owned_list = std.ArrayListUnmanaged(u8){
        .items = owned_items[0..],
        .capacity = owned_items.len,
    };
    var borrowed_items = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

    var owned = ByteArray{
        .header = undefined,
        .items = owned_items[0..],
        .owned_items = owned_list,
        .storage = .owned,
    };
    var borrowed = ByteArray{
        .header = undefined,
        .items = borrowed_items[0..],
        .storage = .{ .borrowed = borrowed_items[0..] },
    };
    const a = Value{ .byte_array = &owned };
    const b = Value{ .byte_array = &borrowed };

    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try a.write(fbs.writer());
    try std.testing.expectEqualStrings("B{ 0xDE 0xAD 0xBE 0xEF }", fbs.getWritten());

    try std.testing.expect(a.eql(b));
    try std.testing.expectEqual(a.hashValue(), b.hashValue());
}

test "valueContainsBorrowedBuffer detects direct packed and nested borrowed buffers" {
    var owned_items = [_]u8{ 1, 2, 3 };
    var borrowed_items = [_]u8{ 4, 5, 6 };

    var owned_ba = ByteArray{
        .header = undefined,
        .items = owned_items[0..],
        .owned_items = .{
            .items = owned_items[0..],
            .capacity = owned_items.len,
        },
        .storage = .owned,
    };
    var borrowed_ba = ByteArray{
        .header = undefined,
        .items = borrowed_items[0..],
        .storage = .{ .borrowed = borrowed_items[0..] },
    };

    const packed_type = VirtualType{
        .name = "packed-u8",
        .inner_type = "byte-array",
    };
    const borrowed_inner = Value{ .byte_array = &borrowed_ba };
    const packed_borrowed = Value{ .tagged = .{ .tag = &packed_type, .inner = &borrowed_inner } };

    var nested_array_items = [_]Value{
        .{ .fixnum = 1 },
        .{ .byte_array = &borrowed_ba },
    };
    var nested_array = Array{ .header = undefined, .items = nested_array_items[0..], .storage = .static };
    var nested_struct_fields = [_]Value{
        .{ .fixnum = 99 },
        packed_borrowed,
    };
    var struct_type = StructType{
        .name = "borrowed-holder",
        .fields = &.{ "id", "payload" },
    };
    var struct_instance = StructInstance{
        .struct_type = &struct_type,
        .fields = nested_struct_fields[0..],
    };

    var err_data = borrowed_inner;
    var err_obj = ErrorObject{
        .error_type = "borrowed-buffer-escape",
        .message = "test",
        .data = &err_data,
    };

    try std.testing.expect(!valueContainsBorrowedBuffer(.{ .byte_array = &owned_ba }));
    try std.testing.expect(valueContainsBorrowedBuffer(.{ .byte_array = &borrowed_ba }));
    try std.testing.expect(valueContainsBorrowedBuffer(packed_borrowed));
    try std.testing.expect(valueContainsBorrowedBuffer(.{ .array = &nested_array }));
    try std.testing.expect(valueContainsBorrowedBuffer(.{ .struct_instance = &struct_instance }));
    try std.testing.expect(valueContainsBorrowedBuffer(.{ .error_value = &err_obj }));
    try std.testing.expect(!valueContainsBorrowedBuffer(.{ .fixnum = 42 }));
}

test "findTaskArenaOwned finds direct nested and captured arena-owned variants" {
    var res = Resource{ .type_name = "test-resource" };
    const res_val = Value{ .resource = &res };

    var nested_array_items = [_]Value{
        .{ .fixnum = 1 },
        res_val,
    };
    var nested_array = Array{ .header = undefined, .items = nested_array_items[0..], .storage = .static };

    const captures = [_]Value{res_val};
    const segments = [_]Segment{.{ .captures = captures[0..], .base_code_ptr = &nested_array }};
    var closure = Closure{
        .instructions = &.{},
        .segments = segments[0..],
        .header = undefined,
    };

    var err_data = res_val;
    var err_obj = ErrorObject{
        .error_type = "test-error",
        .message = "test",
        .data = &err_data,
    };

    try std.testing.expectEqual(.resource, findTaskArenaOwned(res_val));
    try std.testing.expectEqual(.resource, findTaskArenaOwned(.{ .array = &nested_array }));
    try std.testing.expectEqual(.resource, findTaskArenaOwned(.{ .closure = &closure }));
    try std.testing.expectEqual(.resource, findTaskArenaOwned(.{ .error_value = &err_obj }));
    try std.testing.expectEqual(null, findTaskArenaOwned(.{ .fixnum = 42 }));
    try std.testing.expectEqual(null, findTaskArenaOwned(stringValue("hello")));
}

test "array equality" {
    var arr1 = Array{ .header = undefined, .items = &[_]Value{ .{ .fixnum = 1 }, .{ .fixnum = 2 } }, .storage = .static };
    var arr2 = Array{ .header = undefined, .items = &[_]Value{ .{ .fixnum = 1 }, .{ .fixnum = 2 } }, .storage = .static };
    var arr3 = Array{ .header = undefined, .items = &[_]Value{ .{ .fixnum = 1 }, .{ .fixnum = 3 } }, .storage = .static };
    var arr4 = Array{ .header = undefined, .items = &[_]Value{.{ .fixnum = 1 }}, .storage = .static };

    const a = Value{ .array = &arr1 };
    const b = Value{ .array = &arr2 };
    const c = Value{ .array = &arr3 };
    const d = Value{ .array = &arr4 };

    try std.testing.expect(a.eql(a));
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.eql(d));
}

test "quotation equality" {
    const instrs1 = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    };
    const instrs2 = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    };
    const instrs3 = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
    };

    const a = Value{ .quotation = .{ .instructions = instrs1 } };
    const b = Value{ .quotation = .{ .instructions = instrs2 } };
    const c = Value{ .quotation = .{ .instructions = instrs3 } };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "quotation and closure with identical content compare and hash equal, both orderings" {
    const instrs1 = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    };
    const instrs2 = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    };
    const other_instrs = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
    };

    var closure = Closure{ .instructions = instrs1, .segments = &.{}, .header = undefined };

    const quot = Value{ .quotation = .{ .instructions = instrs2 } };
    const clos = Value{ .closure = &closure };
    const other_quot = Value{ .quotation = .{ .instructions = other_instrs } };

    try std.testing.expect(quot.eql(clos));
    try std.testing.expect(clos.eql(quot));
    try std.testing.expectEqual(quot.hashValue(), clos.hashValue());

    try std.testing.expect(!quot.eql(other_quot));
    try std.testing.expect(!clos.eql(other_quot));
}

test "cross-type inequality" {
    const int_val = Value{ .fixnum = 42 };
    const bool_val = Value{ .boolean = true };
    const str_val = stringValue("42");
    const sym_val = symbolValue("42");
    var empty_arr = Array{ .header = undefined, .items = &[_]Value{}, .storage = .static };
    const arr_val = Value{ .array = &empty_arr };

    // Different types are never equal
    try std.testing.expect(!int_val.eql(bool_val));
    try std.testing.expect(!int_val.eql(str_val));
    try std.testing.expect(!str_val.eql(sym_val));
    try std.testing.expect(!arr_val.eql(int_val));
}

test "resource format open" {
    var r = Resource{ .type_name = "sqlite-db" };
    const val = Value{ .resource = &r };
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("<resource:sqlite-db>", fbs.getWritten());
}

test "resource format closed" {
    var r = Resource{ .type_name = "sqlite-db", .closed = true };
    const val = Value{ .resource = &r };
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("<resource:sqlite-db (closed)>", fbs.getWritten());
}

test "resource equality same type and ptr" {
    var sentinel: u8 = 0;
    var r1 = Resource{ .type_name = "test", .ptr = @ptrCast(&sentinel) };
    var r2 = Resource{ .type_name = "test", .ptr = @ptrCast(&sentinel) };
    const val1 = Value{ .resource = &r1 };
    const val2 = Value{ .resource = &r2 };
    try std.testing.expect(val1.eql(val2));
}

test "resource inequality different ptr" {
    var s1: u8 = 0;
    var s2: u8 = 0;
    var r1 = Resource{ .type_name = "test", .ptr = @ptrCast(&s1) };
    var r2 = Resource{ .type_name = "test", .ptr = @ptrCast(&s2) };
    const val1 = Value{ .resource = &r1 };
    const val2 = Value{ .resource = &r2 };
    try std.testing.expect(!val1.eql(val2));
}

test "resource inequality different type name" {
    var sentinel: u8 = 0;
    var r1 = Resource{ .type_name = "type-a", .ptr = @ptrCast(&sentinel) };
    var r2 = Resource{ .type_name = "type-b", .ptr = @ptrCast(&sentinel) };
    const val1 = Value{ .resource = &r1 };
    const val2 = Value{ .resource = &r2 };
    try std.testing.expect(!val1.eql(val2));
}

test "resource hash consistent with equality" {
    var sentinel: u8 = 0;
    var r1 = Resource{ .type_name = "test", .ptr = @ptrCast(&sentinel) };
    var r2 = Resource{ .type_name = "test", .ptr = @ptrCast(&sentinel) };
    const val1 = Value{ .resource = &r1 };
    const val2 = Value{ .resource = &r2 };
    try std.testing.expectEqual(val1.hashValue(), val2.hashValue());
}

test "TypeDescriptor default construction" {
    const desc: TypeDescriptor = .{ .kind = .{ .builtin = {} } };
    try std.testing.expectEqual(false, desc.numeric);
    try std.testing.expectEqual(false, desc.exact);
    try std.testing.expectEqual(false, desc.integer);
    try std.testing.expectEqual(false, desc.mutable);
    try std.testing.expectEqual(TypeKind.builtin, @as(TypeKind, desc.kind));
}

test "TypeKindData exhaustive switch over all variants" {
    const variants = [_]TypeKindData{
        .{ .builtin = {} },
        .{ .sentinel = {} },
        .{ .struct_ = .{} },
        .{ .virtual = .{} },
        .{ .enum_ = .{} },
        .{ .enum_variant = .{} },
        .{ .resource = .{} },
        .{ .ffi_struct = .{} },
        .{ .union_ = {} },
        .{ .type_parameter = .{} },
    };
    for (variants) |v| {
        const tag: TypeKind = switch (v) {
            .builtin => .builtin,
            .sentinel => .sentinel,
            .struct_ => .struct_,
            .virtual => .virtual,
            .enum_ => .enum_,
            .enum_variant => .enum_variant,
            .resource => .resource,
            .ffi_struct => .ffi_struct,
            .union_ => .union_,
            .type_parameter => .type_parameter,
        };
        try std.testing.expectEqual(@as(TypeKind, v), tag);
    }
}

test "createTypeDescriptor preserves flags and kind" {
    const desc = try createTypeDescriptor(
        std.testing.allocator,
        .{ .builtin = {} },
        .{ .numeric = true, .integer = true },
    );
    defer destroyTypeDescriptor(std.testing.allocator, desc);
    try std.testing.expect(desc.numeric);
    try std.testing.expect(!desc.exact);
    try std.testing.expect(desc.integer);
    try std.testing.expect(!desc.mutable);
    try std.testing.expectEqual(TypeKind.builtin, @as(TypeKind, desc.kind));
}

test "createBuiltinTypeDescriptor wires builtin kind" {
    const desc = try createBuiltinTypeDescriptor(std.testing.allocator, .{ .mutable = true });
    defer destroyTypeDescriptor(std.testing.allocator, desc);
    try std.testing.expect(desc.mutable);
    try std.testing.expectEqual(TypeKind.builtin, @as(TypeKind, desc.kind));
}

test "createSentinelTypeDescriptor wires sentinel kind" {
    const desc = try createSentinelTypeDescriptor(std.testing.allocator);
    defer destroyTypeDescriptor(std.testing.allocator, desc);
    try std.testing.expectEqual(TypeKind.sentinel, @as(TypeKind, desc.kind));
}

test "StructData default fields are empty slices" {
    const data: StructData = .{};
    try std.testing.expectEqual(@as(usize, 0), data.fields.len);
    try std.testing.expectEqual(@as(usize, 0), data.field_types.len);
}

test "VirtualData default fields are null and empty" {
    const data: VirtualData = .{};
    try std.testing.expectEqual(@as(?*const TypeValue, null), data.inner_type);
    try std.testing.expectEqual(@as(?*const StructType, null), data.anon_struct);
    try std.testing.expectEqual(@as(usize, 0), data.type_params.len);
}

test "EnumData and Variant round-trip" {
    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    const variants = [_]Variant{
        .{ .name = "red", .type_val = &fixnum_tv },
        .{ .name = "green", .type_val = null },
    };
    const data: EnumData = .{ .variants = &variants };
    try std.testing.expectEqual(@as(usize, 2), data.variants.len);
    try std.testing.expectEqualStrings("red", data.variants[0].name);
    try std.testing.expect(data.variants[0].type_val == &fixnum_tv);
    try std.testing.expectEqualStrings("green", data.variants[1].name);
    try std.testing.expectEqual(@as(?*const TypeValue, null), data.variants[1].type_val);
}

test "EnumVariantData carries parent and inner_type" {
    var parent_tv = TypeValue{ .name = "color", .descriptor = null };
    var inner_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    const data: EnumVariantData = .{ .parent = &parent_tv, .inner_type = &inner_tv };
    try std.testing.expect(data.parent == &parent_tv);
    try std.testing.expect(data.inner_type == &inner_tv);
}

test "ResourceData carries resource_kind" {
    const data: ResourceData = .{ .resource_kind = "stream" };
    try std.testing.expectEqualStrings("stream", data.resource_kind);
}

test "FfiStructData defaults" {
    const data: FfiStructData = .{};
    try std.testing.expectEqual(@as(usize, 0), data.fields.len);
    try std.testing.expectEqual(@as(usize, 0), data.field_types.len);
    try std.testing.expectEqual(@as(usize, 0), data.ffi_layout);
}

test "TypeValue carries TypeDescriptor pointer" {
    const desc = try createBuiltinTypeDescriptor(std.testing.allocator, .{ .numeric = true });
    defer destroyTypeDescriptor(std.testing.allocator, desc);
    const tv = TypeValue{ .name = "fixnum", .descriptor = desc };
    try std.testing.expectEqualStrings("fixnum", tv.name);
    try std.testing.expect(tv.descriptor.?.numeric);
}

test "createTypeParameterDescriptor wires kind and position" {
    const desc = try createTypeParameterDescriptor(std.testing.allocator, 3);
    defer destroyTypeDescriptor(std.testing.allocator, desc);
    try std.testing.expectEqual(TypeKind.type_parameter, @as(TypeKind, desc.kind));
    try std.testing.expectEqual(@as(u32, 3), desc.kind.type_parameter.position);
}

test "mintTypeParameter carries name and position" {
    const tv = try mintTypeParameter(std.testing.allocator, "T", 0);
    defer {
        destroyTypeDescriptor(std.testing.allocator, tv.descriptor.?);
        std.testing.allocator.destroy(tv);
    }
    try std.testing.expectEqualStrings("T", tv.name);
    try std.testing.expect(isTypeParameter(tv));
    try std.testing.expectEqual(@as(?u32, 0), typeParameterPosition(tv));
}

test "mintTypeParameter yields a fresh identity per position" {
    const t = try mintTypeParameter(std.testing.allocator, "T", 0);
    defer {
        destroyTypeDescriptor(std.testing.allocator, t.descriptor.?);
        std.testing.allocator.destroy(t);
    }
    const u = try mintTypeParameter(std.testing.allocator, "U", 1);
    defer {
        destroyTypeDescriptor(std.testing.allocator, u.descriptor.?);
        std.testing.allocator.destroy(u);
    }
    try std.testing.expect(t != u);
    try std.testing.expectEqual(@as(?u32, 0), typeParameterPosition(t));
    try std.testing.expectEqual(@as(?u32, 1), typeParameterPosition(u));
}

test "isTypeParameter is false for concrete and null-descriptor TypeValues" {
    const builtin_desc = try createBuiltinTypeDescriptor(std.testing.allocator, .{});
    defer destroyTypeDescriptor(std.testing.allocator, builtin_desc);
    const builtin_tv = TypeValue{ .name = "fixnum", .descriptor = builtin_desc };
    try std.testing.expect(!isTypeParameter(&builtin_tv));
    try std.testing.expectEqual(@as(?u32, null), typeParameterPosition(&builtin_tv));

    const null_tv = TypeValue{ .name = "opaque", .descriptor = null };
    try std.testing.expect(!isTypeParameter(&null_tv));
    try std.testing.expectEqual(@as(?u32, null), typeParameterPosition(&null_tv));
}
