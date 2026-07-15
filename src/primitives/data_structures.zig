const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const HashTable = value_mod.HashTable;
const Vector = value_mod.Vector;
const ByteArray = value_mod.ByteArray;
const Set = value_mod.Set;
const MutableMap = value_mod.MutableMap;

const helpers = @import("helpers.zig");
const dispatch_helpers = @import("dispatch_helpers.zig");
const dispatch_mod = @import("../dispatch.zig");
const Primitive = @import("types.zig").Primitive;
const tasks = @import("tasks.zig");
const container_backing = @import("../container_backing.zig");

const popQuotation = helpers.popQuotation;

pub const primitives = [_]Primitive{
    .{ .name = "make-hash", .stack_effect = "quotation -- hash", .doc = "Create a hash table from key-value pairs in a quotation. Keys may be symbols (name:) or strings (\"name\").", .func = nativeMakeHash },
    .{ .name = "make-vector", .stack_effect = "quotation -- vector", .doc = "Create a mutable vector from values in a quotation.", .func = nativeMakeVector },
    .{ .name = "make-byte-array", .stack_effect = "quotation -- byte-array", .doc = "Create a byte array from fixnum values in a quotation.", .func = nativeMakeByteArray },
    .{ .name = "make-set", .stack_effect = "quotation -- set", .doc = "Create a set from unique values in a quotation.", .func = nativeMakeSet },
    .{ .name = "make-mutable-map", .stack_effect = "quotation -- mmap", .doc = "Create a mutable map from key-value pairs in a quotation. Keys may be symbols (name:) or strings (\"name\").", .func = nativeMakeMutableMap },
    .{ .name = "@set!", .stack_effect = "mmap key value -- mmap", .doc = "Set value in mutable map, mutating in place.", .func = nativeAtSetMut },
    .{ .name = "@remove!", .stack_effect = "mmap key -- mmap", .doc = "Remove key from mutable map, mutating in place.", .func = nativeAtRemoveMut },
};

/// Helper to extract string from symbol or string value
pub fn extractKeyString(ctx: *Context, val: Value) ![]const u8 {
    return switch (val) {
        .symbol => |s| s,
        .string => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol or string", val);
            return error.TypeMismatch;
        },
    };
}

/// make-hash ( quotation -- hash ) - Create a hash table from key: value pairs
/// The quotation should contain alternating symbol or string keys and values.
/// Example: [ name: "Alice" age: 30 ] make-hash
pub fn nativeMakeHash(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const instrs = quot.instructions;

    const hash = HashTable.create(ctx.allocator) catch return error.OutOfMemory;
    errdefer container_backing.releaseValue(.{ .hash = hash });
    const hash_alloc = hash.header.allocator;

    // Parse instructions as key: value pairs
    var i: usize = 0;
    while (i < instrs.len) {
        const key_instr = instrs[i];
        const key = switch (key_instr.op) {
            .push_literal => |v| switch (v) {
                .symbol => |s| s,
                .string => |s| s,
                else => {
                    const brief = helpers.formatValueBrief(ctx.arena.allocator(), v, 20) catch helpers.valueTypeName(v);
                    helpers.setErrorContext(ctx, "expected symbol or string key, got {s} {s}", .{ helpers.valueTypeName(v), brief });
                    return error.InvalidHashSyntax;
                },
            },
            .call_word, .call_word_direct => {
                const name = key_instr.op.callTargetName().?;
                helpers.setErrorContext(ctx, "expected symbol or string key, got word '{s}'", .{name});
                return error.InvalidHashSyntax;
            },
        };
        i += 1;

        if (i >= instrs.len) {
            helpers.setErrorContext(ctx, "missing value after key '{s}'", .{key});
            return error.InvalidHashSyntax;
        }

        // Get the value: could be a literal, a call_word, or a literal followed by call_words
        // that transform it, e.g., `V{` producing push_literal [1 2 3] + call_word make-vector
        const val_start = i;
        i += 1;

        while (i < instrs.len and instrs[i].op.isCall()) : (i += 1) {}
        // push_literal values are borrowed from the instruction stream, so a
        // hash slot becomes a new owner and must retain. call_word values were
        // popped from the stack into a transient C-local, so the slot inherits
        // ownership without an additional retain.
        const val = if (i - val_start == 1 and instrs[val_start].op == .push_literal) blk: {
            const v = instrs[val_start].op.push_literal;
            container_backing.retainValue(v);
            break :blk v;
        } else blk: {
            try ctx.executeQuotation(.{ .instructions = instrs[val_start..i] });
            break :blk ctx.stack.pop() catch {
                helpers.setErrorContext(ctx, "value for key '{s}' produced no result", .{key});
                return error.InvalidHashSyntax;
            };
        };

        const key_copy = hash_alloc.dupe(u8, key) catch {
            container_backing.releaseValue(val);
            return error.OutOfMemory;
        };
        hash.map.put(hash_alloc, key_copy, val) catch {
            hash_alloc.free(key_copy);
            container_backing.releaseValue(val);
            return error.OutOfMemory;
        };
    }

    try ctx.stack.pushMoved(.{ .hash = hash });
}

/// make-vector ( quotation -- vector ) - Create a vector from values in quotation
/// Example: [ 1 2 3 ] make-vector
pub fn nativeMakeVector(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const instrs = quot.instructions;

    const vec = Vector.create(ctx.allocator) catch return error.OutOfMemory;
    errdefer container_backing.releaseValue(.{ .vector = vec });

    // Execute each instruction and collect values. push_literal values
    // are borrowed from the instruction stream, so a vec slot becomes a
    // new owner and must retain. call_word values were popped from the
    // stack into a transient C-local, so the slot inherits ownership
    // without an additional retain.
    for (instrs) |instr| {
        const val = switch (instr.op) {
            .push_literal => |v| blk: {
                container_backing.retainValue(v);
                break :blk v;
            },
            .call_word, .call_word_direct => blk: {
                try ctx.executeQuotation(.{ .instructions = @as(*const [1]Instruction, &instr) });
                break :blk ctx.stack.pop() catch return error.OutOfMemory;
            },
        };
        vec.list.append(vec.header.allocator, val) catch |err| {
            container_backing.releaseValue(val);
            return err;
        };
    }

    try ctx.stack.pushMoved(.{ .vector = vec });
}

/// make-byte-array ( quotation -- byte-array ) - Create a byte array from values in quotation
/// Example: [ 0xFF 0x00 0x42 ] make-byte-array
/// Values must be integers in range 0-255
pub fn nativeMakeByteArray(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const instrs = quot.instructions;

    // Create a new byte array on the thread-safe heap so the backing
    // participates in the refcounted cross-worker lifecycle.
    const ba = ByteArray.create(ctx.allocator) catch return error.OutOfMemory;
    errdefer container_backing.releaseValue(.{ .byte_array = ba });
    const alloc = ba.header.allocator;

    // Execute each instruction and collect byte values. Byte values are
    // always fixnums, so the popped `call_word` results carry no refcounted
    // backing and need no release.
    for (instrs) |instr| {
        const val = switch (instr.op) {
            .push_literal => |v| v,
            .call_word, .call_word_direct => blk: {
                // Execute the word to get the value
                try ctx.executeQuotation(.{ .instructions = @as(*const [1]Instruction, &instr) });
                break :blk ctx.stack.pop() catch return error.OutOfMemory;
            },
        };
        // Value must be a fixnum in byte range
        switch (val) {
            .fixnum => |int| {
                if (int < 0 or int > 255) return error.FixnumOverflow;
                ba.append(alloc, @intCast(int)) catch return error.OutOfMemory;
            },
            else => {
                helpers.setErrorHint(ctx, "byte array elements must be fixnum values in 0-255");
                helpers.setTypeMismatchError(ctx, "fixnum", val);
                return error.TypeMismatch;
            },
        }
    }

    try ctx.stack.pushMoved(.{ .byte_array = ba });
}

/// make-set ( quotation -- set ) - Create a set from unique values in quotation
/// Example: [ 1 2 3 2 1 ] make-set creates S{ 1 2 3 } (duplicates removed)
pub fn nativeMakeSet(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const instrs = quot.instructions;

    const set = Set.create(ctx.allocator) catch return error.OutOfMemory;
    errdefer container_backing.releaseValue(.{ .set = set });
    const set_alloc = set.header.allocator;

    // Execute each instruction and collect unique values. push_literal values
    // are borrowed from the instruction stream, so a set slot becomes a new
    // owner and must retain. call_word values were popped from the stack into
    // a transient C-local, so the slot inherits ownership without a retain.
    for (instrs) |instr| {
        const val = switch (instr.op) {
            .push_literal => |v| blk: {
                container_backing.retainValue(v);
                break :blk v;
            },
            .call_word, .call_word_direct => blk: {
                // Execute the word to get the value
                try ctx.executeQuotation(.{ .instructions = @as(*const [1]Instruction, &instr) });
                break :blk ctx.stack.pop() catch return error.OutOfMemory;
            },
        };

        // A duplicate key already present in the set keeps its existing owning
        // reference; release the redundant one this iteration produced.
        const gop = set.map.getOrPut(set_alloc, val) catch {
            container_backing.releaseValue(val);
            return error.OutOfMemory;
        };
        if (gop.found_existing) {
            container_backing.releaseValue(val);
        }
    }

    try ctx.stack.pushMoved(.{ .set = set });
}

/// make-mutable-map ( quotation -- mmap ) - Create a mutable map from key: value pairs
/// Example: [ name: "Alice" age: 30 ] make-mutable-map
pub fn nativeMakeMutableMap(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const instrs = quot.instructions;

    const mmap = MutableMap.create(ctx.allocator) catch return error.OutOfMemory;
    errdefer container_backing.releaseValue(.{ .mutable_map = mmap });
    const alloc = mmap.header.allocator;

    // Parse instructions as key: value pairs (same as make-hash)
    var i: usize = 0;
    while (i < instrs.len) {
        const key_instr = instrs[i];
        const key = switch (key_instr.op) {
            .push_literal => |v| switch (v) {
                .symbol => |s| s,
                .string => |s| s,
                else => {
                    const brief = helpers.formatValueBrief(ctx.arena.allocator(), v, 20) catch helpers.valueTypeName(v);
                    helpers.setErrorContext(ctx, "expected symbol or string key, got {s} {s}", .{ helpers.valueTypeName(v), brief });
                    return error.InvalidHashSyntax;
                },
            },
            .call_word, .call_word_direct => {
                const name = key_instr.op.callTargetName().?;
                helpers.setErrorContext(ctx, "expected symbol or string key, got word '{s}'", .{name});
                return error.InvalidHashSyntax;
            },
        };
        i += 1;

        if (i >= instrs.len) {
            helpers.setErrorContext(ctx, "missing value after key '{s}'", .{key});
            return error.InvalidHashSyntax;
        }

        // Get the value - could be a literal, a call_word, or a literal
        // followed by call_words that transform it (e.g., V{ } producing
        // push_literal [1 2 3] + call_word make-vector).
        const val_start = i;
        i += 1;
        while (i < instrs.len and instrs[i].op.isCall()) : (i += 1) {}
        // push_literal values are borrowed from the instruction stream, so a
        // map slot becomes a new owner and must retain. call_word values were
        // popped from the stack into a transient C-local, so the slot inherits
        // ownership without an additional retain.
        const stored_val = if (i - val_start == 1 and instrs[val_start].op == .push_literal) blk: {
            const v = instrs[val_start].op.push_literal;
            container_backing.retainValue(v);
            break :blk v;
        } else blk: {
            try ctx.executeQuotation(.{ .instructions = instrs[val_start..i] });
            break :blk ctx.stack.pop() catch {
                helpers.setErrorContext(ctx, "value for key '{s}' produced no result", .{key});
                return error.InvalidHashSyntax;
            };
        };

        const key_copy = alloc.dupe(u8, key) catch {
            container_backing.releaseValue(stored_val);
            return error.OutOfMemory;
        };
        mmap.map.put(alloc, key_copy, stored_val) catch |err| {
            alloc.free(key_copy);
            container_backing.releaseValue(stored_val);
            return err;
        };
    }

    try ctx.stack.pushMoved(.{ .mutable_map = mmap });
}

/// @set! ( mmap key value -- mmap ) - Set value in mutable map, mutate in place
pub fn nativeAtSetMut(ctx: *Context) anyerror!void {
    // dispatch: mmap is at position 2 (below key and value)
    if (ctx.stack.depth() >= 3) {
        if (ctx.resolveDispatchId("@set!")) |did| {
            const mmap_peek = try ctx.stack.peekN(2);
            const a_type = dispatch_mod.dispatchDescriptor(mmap_peek, ctx);
            if (ctx.lookupUnaryDispatch(did, a_type)) |entry| {
                try dispatch_helpers.executeDispatchBody(ctx, entry);
                return;
            }
            if (dispatch_mod.dispatchEnumTypeValue(mmap_peek)) |ae| {
                if (ctx.lookupUnaryDispatch(did, ae.descriptor.?)) |entry| {
                    try dispatch_helpers.executeDispatchBody(ctx, entry);
                    return;
                }
            }
            if (dispatch_mod.dispatchBaseTypeValue(mmap_peek)) |bt| {
                if (ctx.lookupUnaryDispatch(did, bt.descriptor.?)) |entry| {
                    const len = ctx.stack.items.items.len;
                    ctx.stack.items.items[len - 3] = mmap_peek.tagged.inner.*;
                    try dispatch_helpers.executeDispatchBody(ctx, entry);
                    return;
                }
            }
        }
    }

    const new_value = try ctx.stack.pop();
    const key = try ctx.stack.pop();
    const obj = try ctx.stack.pop();

    const key_str = try extractKeyString(ctx, key);

    switch (obj) {
        .mutable_map => |m| {
            const alloc = m.header.allocator;

            // `new_value` and `obj` were popped into C locals with ownership
            // transferred from their stack slots. The map slot below takes
            // over `new_value`'s reference; `obj` flows into the result slot
            // via `pushMoved`. No extra retains are needed in either path.
            m.header.lock();
            const existing_entry = m.map.getEntry(key_str);
            if (existing_entry) |entry| {
                const displaced = entry.value_ptr.*;
                entry.value_ptr.* = new_value;
                m.header.unlock();
                container_backing.releaseValue(displaced);
            } else {
                const key_copy = alloc.dupe(u8, key_str) catch {
                    m.header.unlock();
                    container_backing.releaseValue(new_value);
                    container_backing.releaseValue(.{ .mutable_map = m });
                    return error.OutOfMemory;
                };
                m.map.put(alloc, key_copy, new_value) catch |err| {
                    m.header.unlock();
                    alloc.free(key_copy);
                    container_backing.releaseValue(new_value);
                    container_backing.releaseValue(.{ .mutable_map = m });
                    return err;
                };
                m.header.unlock();
            }

            ctx.stack.pushMoved(.{ .mutable_map = m }) catch |err| {
                container_backing.releaseValue(.{ .mutable_map = m });
                return err;
            };
        },
        else => {
            container_backing.releaseValue(new_value);
            container_backing.releaseValue(obj);
            helpers.setTypeMismatchError(ctx, "mutable-map", obj);
            return error.TypeMismatch;
        },
    }
}

/// @remove! ( mmap key -- mmap ) - Remove key from mutable map, mutate in place
pub fn nativeAtRemoveMut(ctx: *Context) anyerror!void {
    // dispatch: mmap is at position 1 (below key)
    if (ctx.stack.depth() >= 2) {
        if (ctx.resolveDispatchId("@remove!")) |did| {
            const mmap_peek = try ctx.stack.peekN(1);
            const a_type = dispatch_mod.dispatchDescriptor(mmap_peek, ctx);
            if (ctx.lookupUnaryDispatch(did, a_type)) |entry| {
                try dispatch_helpers.executeDispatchBody(ctx, entry);
                return;
            }
            if (dispatch_mod.dispatchEnumTypeValue(mmap_peek)) |ae| {
                if (ctx.lookupUnaryDispatch(did, ae.descriptor.?)) |entry| {
                    try dispatch_helpers.executeDispatchBody(ctx, entry);
                    return;
                }
            }
            if (dispatch_mod.dispatchBaseTypeValue(mmap_peek)) |bt| {
                if (ctx.lookupUnaryDispatch(did, bt.descriptor.?)) |entry| {
                    const len = ctx.stack.items.items.len;
                    ctx.stack.items.items[len - 2] = mmap_peek.tagged.inner.*;
                    try dispatch_helpers.executeDispatchBody(ctx, entry);
                    return;
                }
            }
        }
    }

    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const obj = try ctx.stack.pop();

    const key_str = try extractKeyString(ctx, key);

    switch (obj) {
        .mutable_map => |m| {
            m.header.lock();
            const removed = m.map.fetchRemove(key_str);
            m.header.unlock();
            if (removed) |kv| {
                m.header.allocator.free(kv.key);
                container_backing.releaseValue(kv.value);
            }
            ctx.stack.pushMoved(.{ .mutable_map = m }) catch |err| {
                container_backing.releaseValue(.{ .mutable_map = m });
                return err;
            };
        },
        else => {
            container_backing.releaseValue(obj);
            helpers.setTypeMismatchError(ctx, "mutable-map", obj);
            return error.TypeMismatch;
        },
    }
}
