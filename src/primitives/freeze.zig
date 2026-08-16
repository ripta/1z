const std = @import("std");
const Allocator = std.mem.Allocator;

const context_mod = @import("../context.zig");
const Context = context_mod.Context;

const value_mod = @import("../value.zig");
const Value = value_mod.Value;

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;

const dispatch_helpers = @import("dispatch_helpers.zig");
const markers_mod = @import("markers.zig");
const container_backing = @import("../container_backing.zig");

const helpers = @import("helpers.zig");
const setErrorContext = helpers.setErrorContext;
const valueTypeName = helpers.valueTypeName;

const TaggedPayload = std.meta.TagPayload(Value, .tagged);

pub const primitives = [_]Primitive{
    .{ .name = "freeze", .stack_effect = "val -- frozen", .doc = "Deeply convert a value to its immutable counterpart (copy semantics): vectors become arrays, mutable-maps become hashes, byte-arrays become strings, recursively. String and symbol leaves are promoted onto heap backings so the frozen value can be shared across tasks. Scalars and other immutable values pass through.", .func = nativeFreeze, .markers = &.{@constCast(&markers_mod.generic_marker)} },
    .{ .name = "freeze!", .stack_effect = "val -- frozen", .doc = "Like freeze, but consumes the original. A sole-owner vector backing is converted in place; aliased values are copied.", .func = nativeFreezeBang, .markers = &.{@constCast(&markers_mod.generic_marker)} },
};

/// freeze ( val -- frozen )
fn nativeFreeze(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnaryByName(ctx, "freeze")) return;

    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);

    const frozen = try deepFreezeCopy(ctx, val);
    ctx.stack.pushMoved(frozen) catch |e| {
        container_backing.releaseValue(frozen);
        return e;
    };
}

/// freeze! ( val -- frozen )
fn nativeFreezeBang(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnaryByName(ctx, "freeze!")) return;

    const val = try ctx.stack.pop();
    const frozen = deepFreezeConsume(ctx, val) catch |e| {
        container_backing.releaseValue(val);
        return e;
    };
    ctx.stack.pushMoved(frozen) catch |e| {
        container_backing.releaseValue(frozen);
        return e;
    };
}

/// Deep-freeze a borrowed value and return a new owning reference.
///
/// Every mutable-typed node converts to its immutable counterpart. Containers the walker builds
/// live on the process-lifetime allocator so the share-safety scan can qualify them; the scan runs
/// once here to populate the memo, and its verdict (not the freeze itself) decides shareability.
pub fn deepFreezeCopy(ctx: *Context, val: Value) anyerror!Value {
    const r = try freezeCopy(ctx, val);
    _ = container_backing.valueShareable(r.value, ctx.allocator);
    return r.value;
}

/// Deep-freeze a value the caller owns, consuming it on success.
///
/// On error the input is not consumed and the caller must still release it. A sole-owner vector
/// backing on the process-lifetime allocator is adopted in place. Everything else copies and
/// releases.
pub fn deepFreezeConsume(ctx: *Context, val: Value) anyerror!Value {
    const r = try freezeConsume(ctx, val);
    _ = container_backing.valueShareable(r.value, ctx.allocator);
    return r.value;
}

/// A frozen node plus whether it differs from the input. Unchanged already-immutable subtrees
/// return the input retained, so re-freezing frozen data costs no allocation.
const FreezeResult = struct { value: Value, changed: bool };

const ItemsResult = struct { items: []Value, changed: bool };

fn freezeCopy(ctx: *Context, val: Value) anyerror!FreezeResult {
    switch (val) {
        .vector => |vec| {
            const r = try freezeItemsCopy(ctx, vec.list.items);
            return .{ .value = try adoptArray(ctx, r.items), .changed = true };
        },

        .mutable_map => |m| return .{ .value = .{ .hash = try freezeMapCopy(ctx, &m.map) }, .changed = true },

        .byte_array => |b| {
            const copy = try ctx.allocator.dupe(u8, b.slice());
            return .{ .value = try value_mod.ownedStringValue(ctx.allocator, copy), .changed = true };
        },

        .array => |arr| return freezeArray(ctx, arr, val),
        .hash => |h| return freezeHash(ctx, h, val),
        .set => |s| return freezeSet(ctx, s, val),

        .struct_instance => |si| return .{ .value = try freezeStruct(ctx, si), .changed = true },
        .tagged => |t| return freezeTagged(ctx, t, val),
        .error_value => |err| return freezeErrorValue(ctx, err, val),

        .string, .symbol => |s| return freezeStringLeaf(ctx, val, s),

        // Immutable leaves and reference types pass through. Reference types keep the treatment
        // deepCopyValue gives them; the share-safety scan classifies containers holding any of
        // these not-shareable, so passing them through cannot leak across a task boundary.
        //
        // A null-backed bignum stays a pass-through: promotion covers strings and symbols only,
        // so a bignum literal in a container keeps the container on the deep-copy path.
        .fixnum,
        .float,
        .boolean,
        .unit,
        .bignum,
        .doc_string,
        .quotation,
        .closure,
        .template,
        .stack_effect,
        .stream,
        .resource,
        .parameter,
        .module,
        .marker,
        .struct_type,
        .task,
        .channel,
        .iterator,
        .type_val,
        .type_descriptor,
        .protocol_descriptor,
        .constraint_combinator,
        .sandbox_spec,
        => {
            container_backing.retainValue(val);
            return .{ .value = val, .changed = false };
        },
    }
}

fn freezeConsume(ctx: *Context, val: Value) anyerror!FreezeResult {
    switch (val) {
        .vector => |vec| {
            // In-place adoption is safe only for the sole owner: no alias exists and no other
            // thread can reach the backing, so no lock is needed. The allocator must already be
            // the process-lifetime one because the array adopts the element buffer as-is.
            if (vec.header.isSoleOwner() and container_backing.allocatorEql(vec.header.allocator, ctx.allocator)) {
                for (vec.list.items) |*slot| {
                    const r = try freezeConsume(ctx, slot.*);
                    slot.* = r.value;
                }
                const items = try vec.list.toOwnedSlice(ctx.allocator);
                const arr = value_mod.Array.fromOwnedSlice(ctx.allocator, items) catch |e| {
                    container_backing.releaseValues(items);
                    ctx.allocator.free(items);
                    return e;
                };
                // The list is empty now, so this release frees the vector struct
                // without touching the elements the array just adopted.
                vec.header.release();
                return .{ .value = .{ .array = arr }, .changed = true };
            }

            const r = try freezeCopy(ctx, val);
            container_backing.releaseValue(val);
            return r;
        },
        else => {
            const r = try freezeCopy(ctx, val);
            container_backing.releaseValue(val);
            return r;
        },
    }
}

/// Promote a null-backed string or symbol leaf onto a heap backing, so a literal-bearing frozen
/// container passes the share-safety scan.
///
/// An already-backed durable leaf passes through by identity, mirroring the container fast path.
/// `changed = true` on promotion is what forces an enclosing durable container to rebuild
/// instead of returning by identity.
fn freezeStringLeaf(ctx: *Context, val: Value, s: value_mod.StringPayload) anyerror!FreezeResult {
    if (s.backing) |b| {
        if (durableBacking(ctx, &b.header)) {
            container_backing.retainValue(val);
            return .{ .value = val, .changed = false };
        }
    }

    const copy = try ctx.allocator.dupe(u8, s.bytes);
    errdefer ctx.allocator.free(copy);
    const promoted = switch (val) {
        .string => try value_mod.ownedStringValue(ctx.allocator, copy),
        .symbol => try value_mod.ownedSymbolValue(ctx.allocator, copy),
        else => unreachable,
    };
    return .{ .value = promoted, .changed = true };
}

/// Freeze each element of a borrowed slice into a fresh slice on the process-lifetime allocator.
/// The returned items hold one owning reference each.
fn freezeItemsCopy(ctx: *Context, src: []const Value) anyerror!ItemsResult {
    const items = try ctx.allocator.alloc(Value, src.len);
    var done: usize = 0;
    var changed = false;
    errdefer {
        container_backing.releaseValues(items[0..done]);
        ctx.allocator.free(items);
    }
    for (src) |item| {
        const r = try freezeCopy(ctx, item);
        items[done] = r.value;
        done += 1;
        changed = changed or r.changed;
    }
    return .{ .items = items, .changed = changed };
}

/// Adopt a filled slice (allocated on the process-lifetime allocator, elements owned) into a
/// fresh array. Ownership of the slice and elements ends here on every path.
fn adoptArray(ctx: *Context, items: []Value) anyerror!Value {
    const arr = value_mod.Array.fromOwnedSlice(ctx.allocator, items) catch |e| {
        container_backing.releaseValues(items);
        ctx.allocator.free(items);
        return e;
    };
    return .{ .array = arr };
}

/// Snapshot a string-keyed map into a fresh immutable hash on the process-lifetime allocator,
/// freezing each value. Keys are duped onto the hash's own backing, matching every hash insert
/// path.
fn freezeMapCopy(ctx: *Context, map: *const std.StringHashMapUnmanaged(Value)) anyerror!*value_mod.HashTable {
    const new_h = try value_mod.HashTable.create(ctx.allocator);
    errdefer new_h.header.release();
    const hash_alloc = new_h.header.allocator;
    try new_h.map.ensureTotalCapacity(hash_alloc, @intCast(map.count()));
    var iter = map.iterator();
    while (iter.next()) |entry| {
        const key_copy = try hash_alloc.dupe(u8, entry.key_ptr.*);
        errdefer hash_alloc.free(key_copy);
        const r = try freezeCopy(ctx, entry.value_ptr.*);
        new_h.map.putAssumeCapacityNoClobber(key_copy, r.value);
    }
    return new_h;
}

/// Whether a headered backing already lives on the process-lifetime allocator. Unchanged
/// containers on any other backing (static literal storage, a task arena) must still be rebuilt,
/// because the share-safety scan requires process-lifetime provenance.
fn durableBacking(ctx: *Context, header: *const container_backing.ContainerHeader) bool {
    return container_backing.allocatorEql(header.allocator, ctx.allocator);
}

fn freezeArray(ctx: *Context, arr: *value_mod.Array, val: Value) anyerror!FreezeResult {
    const r = try freezeItemsCopy(ctx, arr.items);

    const durable = arr.storage == .owned and durableBacking(ctx, &arr.header);
    if (!r.changed and durable) {
        container_backing.releaseValues(r.items);
        ctx.allocator.free(r.items);
        arr.header.retain();
        return .{ .value = val, .changed = false };
    }

    return .{ .value = try adoptArray(ctx, r.items), .changed = true };
}

const HashEntry = struct { key: []const u8, value: Value };

fn freezeHash(ctx: *Context, h: *value_mod.HashTable, val: Value) anyerror!FreezeResult {
    const scratch = ctx.quotationAllocator();
    var entries: std.ArrayListUnmanaged(HashEntry) = .{};
    var changed = false;
    errdefer for (entries.items) |e| container_backing.releaseValue(e.value);

    var iter = h.map.iterator();
    while (iter.next()) |entry| {
        const r = try freezeCopy(ctx, entry.value_ptr.*);
        try entries.append(scratch, .{ .key = entry.key_ptr.*, .value = r.value });
        changed = changed or r.changed;
    }

    if (!changed and durableBacking(ctx, &h.header)) {
        for (entries.items) |e| container_backing.releaseValue(e.value);
        h.header.retain();
        return .{ .value = val, .changed = false };
    }

    const slice = entries.items;
    entries.clearRetainingCapacity();
    const new_h = try buildFrozenHash(ctx, slice);
    return .{ .value = .{ .hash = new_h }, .changed = true };
}

/// Build a hash from entries whose values this function owns: on success they transfer into the
/// hash, on error the untransferred remainder is released alongside the partial hash.
fn buildFrozenHash(ctx: *Context, entries: []const HashEntry) anyerror!*value_mod.HashTable {
    const new_h = try value_mod.HashTable.create(ctx.allocator);
    errdefer new_h.header.release();
    var done: usize = 0;
    errdefer for (entries[done..]) |e| container_backing.releaseValue(e.value);

    const hash_alloc = new_h.header.allocator;
    try new_h.map.ensureTotalCapacity(hash_alloc, @intCast(entries.len));
    for (entries) |e| {
        const key_copy = try hash_alloc.dupe(u8, e.key);
        new_h.map.putAssumeCapacityNoClobber(key_copy, e.value);
        done += 1;
    }
    return new_h;
}

fn freezeSet(ctx: *Context, s: *value_mod.Set, val: Value) anyerror!FreezeResult {
    const scratch = ctx.quotationAllocator();
    var keys: std.ArrayListUnmanaged(Value) = .{};
    var changed = false;
    errdefer for (keys.items) |k| container_backing.releaseValue(k);

    for (s.map.keys()) |key| {
        const r = try freezeCopy(ctx, key);
        try keys.append(scratch, r.value);
        changed = changed or r.changed;
    }

    if (!changed and durableBacking(ctx, &s.header)) {
        for (keys.items) |k| container_backing.releaseValue(k);
        s.header.retain();
        return .{ .value = val, .changed = false };
    }

    const slice = keys.items;
    keys.clearRetainingCapacity();
    const new_s = try buildFrozenSet(ctx, slice);
    return .{ .value = .{ .set = new_s }, .changed = true };
}

/// Build a set from keys this function owns: on success they transfer into the set (duplicates
/// collapsing to the first occurrence), on error the untransferred remainder is released.
fn buildFrozenSet(ctx: *Context, keys: []const Value) anyerror!*value_mod.Set {
    const new_s = try value_mod.Set.create(ctx.allocator);
    errdefer new_s.header.release();
    var done: usize = 0;
    errdefer for (keys[done..]) |k| container_backing.releaseValue(k);

    try new_s.map.ensureTotalCapacity(ctx.allocator, @intCast(keys.len));
    for (keys) |key| {
        const gop = new_s.map.getOrPutAssumeCapacity(key);
        if (gop.found_existing) container_backing.releaseValue(key);
        done += 1;
    }
    return new_s;
}

/// Copy a struct instance with recursively frozen fields.
///
/// The copy keeps freeze's copy semantics: later mutation through the original never shows in the
/// frozen value. The shell itself stays setter-mutable, which the share-safety scan accounts for.
fn freezeStruct(ctx: *Context, si: *const value_mod.StructInstance) anyerror!Value {
    const alloc = ctx.allocator;
    const new_fields = try alloc.alloc(Value, si.fields.len);
    var done: usize = 0;
    errdefer {
        container_backing.releaseValues(new_fields[0..done]);
        alloc.free(new_fields);
    }

    for (si.fields) |field| {
        const r = try freezeCopy(ctx, field);
        new_fields[done] = r.value;
        done += 1;
    }

    const new_si = try value_mod.createStructInstance(alloc, si.struct_type, new_fields);
    return .{ .struct_instance = new_si };
}

fn freezeTagged(ctx: *Context, t: TaggedPayload, val: Value) anyerror!FreezeResult {
    switch (t.inner.*) {
        // A parameterized typed container converts to its typed counterpart through the generated
        // wrap word, which revalidates the elements against the counterpart's element type.
        .vector => |vec| {
            const elem = parameterizedElemName(t.tag) orelse return freezeNoCounterpart(ctx, t.tag, "vector");
            const r = try freezeItemsCopy(ctx, vec.list.items);
            const raw = try adoptArray(ctx, r.items);
            return .{ .value = try invokeWrap(ctx, raw, "array", elem), .changed = true };
        },
        .mutable_map => |m| {
            const elem = parameterizedElemName(t.tag) orelse return freezeNoCounterpart(ctx, t.tag, "mutable-map");
            const new_h = try freezeMapCopy(ctx, &m.map);
            return .{ .value = try invokeWrap(ctx, .{ .hash = new_h }, "hash", elem), .changed = true };
        },
        .byte_array => return freezeNoCounterpart(ctx, t.tag, "byte-array"),
        else => {
            const r = try freezeCopy(ctx, t.inner.*);
            if (!r.changed) {
                container_backing.releaseValue(r.value);
                container_backing.retainValue(val);
                return .{ .value = val, .changed = false };
            }
            const wrapped = value_mod.ownedTaggedValue(ctx.allocator, t.tag, r.value) catch |e| {
                container_backing.releaseValue(r.value);
                return e;
            };
            return .{ .value = wrapped, .changed = true };
        },
    }
}

fn parameterizedElemName(tag: *const value_mod.VirtualType) ?[]const u8 {
    const params = tag.type_params orelse return null;
    if (params.len == 0) return null;
    return params[0].name;
}

fn freezeNoCounterpart(ctx: *Context, tag: *const value_mod.VirtualType, inner_name: []const u8) anyerror {
    setErrorContext(ctx, "freeze: {s} wraps a {s} with no immutable counterpart type", .{ tag.name, inner_name });
    return error.TypeMismatch;
}

/// Wrap an owned raw container into its typed counterpart by invoking the generated
/// `>kind(elem)` word. Ownership of `raw` transfers to the wrap word's stack slot; the popped
/// result is the returned owning reference.
fn invokeWrap(ctx: *Context, raw: Value, comptime kind: []const u8, elem: []const u8) anyerror!Value {
    const wrap_name = std.fmt.allocPrint(ctx.quotationAllocator(), ">" ++ kind ++ "({s})", .{elem}) catch |e| {
        container_backing.releaseValue(raw);
        return e;
    };
    const wrap_word = ctx.lookupWord(wrap_name) orelse {
        container_backing.releaseValue(raw);
        setErrorContext(ctx, "freeze: no typed " ++ kind ++ " defined for element type {s} (need to define " ++ kind ++ "({s}))", .{ elem, elem });
        return error.WordNotFound;
    };

    ctx.stack.pushMoved(raw) catch |e| {
        container_backing.releaseValue(raw);
        return e;
    };
    switch (wrap_word.action) {
        .native, .host_callback => try wrap_word.invoke(ctx),
        .compound => |instrs| try ctx.executeQuotation(.{ .instructions = instrs }),
        .literal => |v| try ctx.stack.push(v),
    }
    return try ctx.stack.pop();
}

fn freezeErrorValue(ctx: *Context, err: *value_mod.ErrorObject, val: Value) anyerror!FreezeResult {
    const data = err.data orelse {
        container_backing.retainValue(val);
        return .{ .value = val, .changed = false };
    };

    const r = try freezeCopy(ctx, data.*);
    if (!r.changed) {
        container_backing.releaseValue(r.value);
        container_backing.retainValue(val);
        return .{ .value = val, .changed = false };
    }

    const alloc = ctx.quotationAllocator();
    const box = try alloc.create(Value);
    box.* = r.value;
    const new_err = try alloc.create(value_mod.ErrorObject);
    new_err.* = err.*;
    new_err.data = box;
    return .{ .value = .{ .error_value = new_err }, .changed = true };
}

const testing = std.testing;

test "freeze converts a vector of scalars to a shareable array" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const vec = try value_mod.Vector.create(ctx.allocator);
    try vec.list.append(ctx.allocator, .{ .fixnum = 1 });
    try vec.list.append(ctx.allocator, .{ .fixnum = 2 });
    const input: Value = .{ .vector = vec };
    defer container_backing.releaseValue(input);

    const frozen = try deepFreezeCopy(&ctx, input);
    defer container_backing.releaseValue(frozen);

    try testing.expect(frozen == .array);
    try testing.expectEqual(@as(usize, 2), frozen.array.items.len);
    try testing.expectEqual(@as(i64, 1), frozen.array.items[0].fixnum);
    try testing.expectEqual(container_backing.Shareable.shareable, frozen.array.header.shareableState());

    // Copy semantics: the original vector is untouched.
    try testing.expectEqual(@as(usize, 2), vec.list.items.len);
}

test "freeze recurses into nested vectors" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const inner = try value_mod.Vector.create(ctx.allocator);
    try inner.list.append(ctx.allocator, .{ .fixnum = 7 });
    const outer = try value_mod.Vector.create(ctx.allocator);
    try outer.list.append(ctx.allocator, .{ .vector = inner });
    const input: Value = .{ .vector = outer };
    defer container_backing.releaseValue(input);

    const frozen = try deepFreezeCopy(&ctx, input);
    defer container_backing.releaseValue(frozen);

    try testing.expect(frozen == .array);
    try testing.expect(frozen.array.items[0] == .array);
    try testing.expectEqual(@as(i64, 7), frozen.array.items[0].array.items[0].fixnum);
    try testing.expectEqual(container_backing.Shareable.shareable, frozen.array.header.shareableState());
}

test "freeze promotes string leaves onto heap backings and the array shares" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const vec = try value_mod.Vector.create(ctx.allocator);
    try vec.list.append(ctx.allocator, value_mod.stringValue("hello"));
    const input: Value = .{ .vector = vec };
    defer container_backing.releaseValue(input);

    const frozen = try deepFreezeCopy(&ctx, input);
    defer container_backing.releaseValue(frozen);

    try testing.expect(frozen == .array);
    const leaf = frozen.array.items[0].string;
    try testing.expect(leaf.backing != null);
    try testing.expect(leaf.bytes.ptr != @as([*]const u8, "hello".ptr));
    try testing.expectEqualStrings("hello", leaf.bytes);
    try testing.expectEqual(container_backing.Shareable.shareable, frozen.array.header.shareableState());
}

test "freeze promotes a bare string and symbol leaf" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const frozen_str = try deepFreezeCopy(&ctx, value_mod.stringValue("lit"));
    defer container_backing.releaseValue(frozen_str);
    try testing.expect(frozen_str == .string);
    try testing.expect(frozen_str.string.backing != null);
    try testing.expectEqualStrings("lit", frozen_str.string.bytes);

    const frozen_sym = try deepFreezeCopy(&ctx, value_mod.symbolValue("sym"));
    defer container_backing.releaseValue(frozen_sym);
    try testing.expect(frozen_sym == .symbol);
    try testing.expect(frozen_sym.symbol.backing != null);
    try testing.expectEqualStrings("sym", frozen_sym.symbol.bytes);
}

test "freeze returns a durable array of backed strings by identity" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const items = try ctx.allocator.alloc(Value, 1);
    items[0] = try value_mod.ownedStringValue(ctx.allocator, try ctx.allocator.dupe(u8, "owned"));
    const arr = try value_mod.Array.fromOwnedSlice(ctx.allocator, items);
    const input: Value = .{ .array = arr };
    defer container_backing.releaseValue(input);

    const frozen = try deepFreezeCopy(&ctx, input);
    defer container_backing.releaseValue(frozen);

    try testing.expect(frozen.array == arr);
    try testing.expectEqual(@as(u32, 2), arr.header.refcountValue());
    try testing.expectEqual(container_backing.Shareable.shareable, arr.header.shareableState());
}

test "freeze converts a mutable-map to a hash with frozen values" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const mm = try value_mod.MutableMap.create(ctx.allocator);
    const key = try ctx.allocator.dupe(u8, "k");
    const inner = try value_mod.Vector.create(ctx.allocator);
    try inner.list.append(ctx.allocator, .{ .fixnum = 3 });
    try mm.map.put(ctx.allocator, key, .{ .vector = inner });
    const input: Value = .{ .mutable_map = mm };
    defer container_backing.releaseValue(input);

    const frozen = try deepFreezeCopy(&ctx, input);
    defer container_backing.releaseValue(frozen);

    try testing.expect(frozen == .hash);
    const got = frozen.hash.map.get("k").?;
    try testing.expect(got == .array);
    try testing.expectEqual(@as(i64, 3), got.array.items[0].fixnum);

    // Copy semantics: the original map still holds the vector.
    try testing.expect(mm.map.get("k").? == .vector);
}

test "freeze converts a byte-array to a string" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const ba = try value_mod.ByteArray.create(ctx.allocator);
    try ba.ensureTotalCapacity(ctx.allocator, 2);
    ba.appendSliceAssumeCapacity("ab");
    const input: Value = .{ .byte_array = ba };
    defer container_backing.releaseValue(input);

    const frozen = try deepFreezeCopy(&ctx, input);
    defer container_backing.releaseValue(frozen);

    try testing.expect(frozen == .string);
    try testing.expectEqualStrings("ab", frozen.string.bytes);
}

test "freeze rebuilds a static array onto owned shareable storage" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const scratch = ctx.quotationAllocator();
    const items = try scratch.alloc(Value, 2);
    items[0] = .{ .fixnum = 1 };
    items[1] = .{ .fixnum = 2 };
    const static_arr = try value_mod.Array.createStatic(scratch, items);
    const input: Value = .{ .array = static_arr };
    defer container_backing.releaseValue(input);

    const frozen = try deepFreezeCopy(&ctx, input);
    defer container_backing.releaseValue(frozen);

    try testing.expect(frozen == .array);
    try testing.expect(frozen.array != static_arr);
    try testing.expect(frozen.array.storage == .owned);
    try testing.expectEqual(container_backing.Shareable.shareable, frozen.array.header.shareableState());
}

test "freeze returns an unchanged durable array by identity" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const arr = try value_mod.Array.createCopyFrom(ctx.allocator, &.{.{ .fixnum = 5 }});
    const input: Value = .{ .array = arr };
    defer container_backing.releaseValue(input);

    const frozen = try deepFreezeCopy(&ctx, input);
    defer container_backing.releaseValue(frozen);

    try testing.expect(frozen == .array);
    try testing.expect(frozen.array == arr);
    try testing.expectEqual(@as(u32, 2), arr.header.refcountValue());
}

test "freeze! adopts a sole-owner vector backing in place" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const vec = try value_mod.Vector.create(ctx.allocator);
    try vec.list.ensureTotalCapacityPrecise(ctx.allocator, 2);
    vec.list.appendAssumeCapacity(.{ .fixnum = 1 });
    vec.list.appendAssumeCapacity(.{ .fixnum = 2 });
    const items_ptr = vec.list.items.ptr;

    const frozen = try deepFreezeConsume(&ctx, .{ .vector = vec });
    defer container_backing.releaseValue(frozen);

    try testing.expect(frozen == .array);
    try testing.expectEqual(items_ptr, frozen.array.items.ptr);
    try testing.expectEqual(container_backing.Shareable.shareable, frozen.array.header.shareableState());
}

test "freeze! in-place vector adoption promotes string elements" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const vec = try value_mod.Vector.create(ctx.allocator);
    try vec.list.ensureTotalCapacityPrecise(ctx.allocator, 1);
    vec.list.appendAssumeCapacity(value_mod.stringValue("lit"));
    const items_ptr = vec.list.items.ptr;

    const frozen = try deepFreezeConsume(&ctx, .{ .vector = vec });
    defer container_backing.releaseValue(frozen);

    try testing.expect(frozen == .array);
    try testing.expectEqual(items_ptr, frozen.array.items.ptr);
    try testing.expect(frozen.array.items[0].string.backing != null);
    try testing.expectEqual(container_backing.Shareable.shareable, frozen.array.header.shareableState());
}

test "freeze! copies an aliased vector and leaves the alias intact" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const vec = try value_mod.Vector.create(ctx.allocator);
    try vec.list.append(ctx.allocator, .{ .fixnum = 9 });
    const alias: Value = .{ .vector = vec };
    container_backing.retainValue(alias);
    defer container_backing.releaseValue(alias);

    const frozen = try deepFreezeConsume(&ctx, .{ .vector = vec });
    defer container_backing.releaseValue(frozen);

    try testing.expect(frozen == .array);
    try testing.expectEqual(@as(usize, 1), vec.list.items.len);
    try testing.expectEqual(@as(i64, 9), vec.list.items[0].fixnum);
}

test "freeze returns an unchanged durable hash and set by identity" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const h = try value_mod.HashTable.create(ctx.allocator);
    const key = try ctx.allocator.dupe(u8, "a");
    try h.map.put(ctx.allocator, key, .{ .fixnum = 1 });
    const hash_input: Value = .{ .hash = h };
    defer container_backing.releaseValue(hash_input);

    const frozen_hash = try deepFreezeCopy(&ctx, hash_input);
    defer container_backing.releaseValue(frozen_hash);
    try testing.expect(frozen_hash.hash == h);

    const s = try value_mod.Set.create(ctx.allocator);
    try s.map.put(ctx.allocator, .{ .fixnum = 4 }, {});
    const set_input: Value = .{ .set = s };
    defer container_backing.releaseValue(set_input);

    const frozen_set = try deepFreezeCopy(&ctx, set_input);
    defer container_backing.releaseValue(frozen_set);
    try testing.expect(frozen_set.set == s);
}
