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

    // Create a new hash table
    const hash = ctx.quotationAllocator().create(HashTable) catch return error.OutOfMemory;
    hash.* = HashTable{};

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
            .call_word => |name| {
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

        while (i < instrs.len and instrs[i].op == .call_word) : (i += 1) {}
        const val = if (i - val_start == 1 and instrs[val_start].op == .push_literal)
            instrs[val_start].op.push_literal
        else blk: {
            try ctx.executeQuotation(.{ .instructions = instrs[val_start..i] });
            break :blk ctx.stack.pop() catch {
                helpers.setErrorContext(ctx, "value for key '{s}' produced no result", .{key});
                return error.InvalidHashSyntax;
            };
        };

        // Copy key to arena for persistence
        const key_copy = ctx.quotationAllocator().dupe(u8, key) catch return error.OutOfMemory;
        container_backing.retainValue(val);
        hash.put(ctx.quotationAllocator(), key_copy, val) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .hash = hash });
}

/// make-vector ( quotation -- vector ) - Create a vector from values in quotation
/// Example: [ 1 2 3 ] make-vector
pub fn nativeMakeVector(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const instrs = quot.instructions;

    const alloc = ctx.containerAllocator();
    const in_task = ctx.parent_context != null;

    const vec = alloc.create(Vector) catch return error.OutOfMemory;
    vec.* = Vector{};

    // Execute each instruction and collect values
    for (instrs) |instr| {
        var val = switch (instr.op) {
            .push_literal => |v| v,
            .call_word => blk: {
                // Execute the word to get the value
                try ctx.executeQuotation(.{ .instructions = @as(*const [1]Instruction, &instr) });
                break :blk ctx.stack.pop() catch return error.OutOfMemory;
            },
        };
        if (in_task) val = tasks.deepCopyValue(val, alloc) catch return error.OutOfMemory;
        container_backing.retainValue(val);
        vec.append(alloc, val) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .vector = vec });
}

/// make-byte-array ( quotation -- byte-array ) - Create a byte array from values in quotation
/// Example: [ 0xFF 0x00 0x42 ] make-byte-array
/// Values must be integers in range 0-255
pub fn nativeMakeByteArray(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const instrs = quot.instructions;
    const alloc = ctx.containerAllocator();

    // Create a new byte array
    const ba = alloc.create(ByteArray) catch return error.OutOfMemory;
    ba.* = ByteArray{};

    // Execute each instruction and collect byte values
    for (instrs) |instr| {
        const val = switch (instr.op) {
            .push_literal => |v| v,
            .call_word => blk: {
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

    try ctx.stack.push(.{ .byte_array = ba });
}

/// make-set ( quotation -- set ) - Create a set from unique values in quotation
/// Example: [ 1 2 3 2 1 ] make-set creates S{ 1 2 3 } (duplicates removed)
pub fn nativeMakeSet(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const instrs = quot.instructions;
    const alloc = ctx.quotationAllocator();

    // Create a new set
    const set = alloc.create(Set) catch return error.OutOfMemory;
    set.* = Set{};

    // Execute each instruction and collect unique values
    for (instrs) |instr| {
        const val = switch (instr.op) {
            .push_literal => |v| v,
            .call_word => blk: {
                // Execute the word to get the value
                try ctx.executeQuotation(.{ .instructions = @as(*const [1]Instruction, &instr) });
                break :blk ctx.stack.pop() catch return error.OutOfMemory;
            },
        };

        container_backing.retainValue(val);
        set.put(alloc, val, {}) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .set = set });
}

/// make-mutable-map ( quotation -- mmap ) - Create a mutable map from key: value pairs
/// Example: [ name: "Alice" age: 30 ] make-mutable-map
pub fn nativeMakeMutableMap(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const instrs = quot.instructions;
    const alloc = ctx.containerAllocator();
    const in_task = ctx.parent_context != null;

    // Create a new mutable map
    const mmap = alloc.create(MutableMap) catch return error.OutOfMemory;
    mmap.* = MutableMap{};

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
            .call_word => |name| {
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
        while (i < instrs.len and instrs[i].op == .call_word) : (i += 1) {}
        const val = if (i - val_start == 1 and instrs[val_start].op == .push_literal)
            instrs[val_start].op.push_literal
        else blk: {
            try ctx.executeQuotation(.{ .instructions = instrs[val_start..i] });
            break :blk ctx.stack.pop() catch {
                helpers.setErrorContext(ctx, "value for key '{s}' produced no result", .{key});
                return error.InvalidHashSyntax;
            };
        };

        // Copy key to arena for persistence
        const key_copy = alloc.dupe(u8, key) catch return error.OutOfMemory;
        const stored_val = if (in_task) tasks.deepCopyValue(val, alloc) catch return error.OutOfMemory else val;
        container_backing.retainValue(stored_val);
        mmap.put(alloc, key_copy, stored_val) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .mutable_map = mmap });
}

/// @set! ( mmap key value -- mmap ) - Set value in mutable map, mutate in place
pub fn nativeAtSetMut(ctx: *Context) anyerror!void {
    // dispatch: mmap is at position 2 (below key and value)
    if (ctx.stack.depth() >= 3) {
        if (ctx.resolveDispatchId("@set!")) |did| {
            const mmap_peek = try ctx.stack.peekN(2);
            const a_type = dispatch_mod.dispatchDescriptor(mmap_peek, ctx);
            if (ctx.lookupUnaryDispatch(did, a_type)) |entry| {
                try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                return;
            }
            if (dispatch_mod.dispatchEnumTypeValue(mmap_peek)) |ae| {
                if (ctx.lookupUnaryDispatch(did, ae.descriptor.?)) |entry| {
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
            if (dispatch_mod.dispatchBaseTypeValue(mmap_peek)) |bt| {
                if (ctx.lookupUnaryDispatch(did, bt.descriptor.?)) |entry| {
                    const len = ctx.stack.items.items.len;
                    ctx.stack.items.items[len - 3] = mmap_peek.tagged.inner.*;
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
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
            const alloc = ctx.containerAllocator();
            const stored_value = if (ctx.parent_context != null)
                tasks.deepCopyValue(new_value, alloc) catch return error.OutOfMemory
            else
                new_value;

            // Check if key already exists
            if (m.get(key_str)) |prior| {
                // Update existing key in place (use the same key pointer);
                // release the prior slot owner before overwriting.
                container_backing.releaseValue(prior);
                container_backing.retainValue(stored_value);
                m.putAssumeCapacity(key_str, stored_value);
            } else {
                // New key - need to copy it
                const key_copy = alloc.dupe(u8, key_str) catch return error.OutOfMemory;
                container_backing.retainValue(stored_value);
                m.put(alloc, key_copy, stored_value) catch return error.OutOfMemory;
            }

            try ctx.stack.push(.{ .mutable_map = m });
        },
        else => {
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
                try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                return;
            }
            if (dispatch_mod.dispatchEnumTypeValue(mmap_peek)) |ae| {
                if (ctx.lookupUnaryDispatch(did, ae.descriptor.?)) |entry| {
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
            if (dispatch_mod.dispatchBaseTypeValue(mmap_peek)) |bt| {
                if (ctx.lookupUnaryDispatch(did, bt.descriptor.?)) |entry| {
                    const len = ctx.stack.items.items.len;
                    ctx.stack.items.items[len - 2] = mmap_peek.tagged.inner.*;
                    try dispatch_helpers.executeDispatchBody(ctx, entry.body);
                    return;
                }
            }
        }
    }

    const key = try ctx.stack.pop();
    const obj = try ctx.stack.pop();

    const key_str = try extractKeyString(ctx, key);

    switch (obj) {
        .mutable_map => |m| {
            if (m.fetchRemove(key_str)) |entry| {
                container_backing.releaseValue(entry.value);
            }
            try ctx.stack.push(.{ .mutable_map = m });
        },
        else => {
            helpers.setTypeMismatchError(ctx, "mutable-map", obj);
            return error.TypeMismatch;
        },
    }
}
