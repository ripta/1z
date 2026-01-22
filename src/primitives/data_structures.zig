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
const Primitive = @import("types.zig").Primitive;

const popQuotation = helpers.popQuotation;

pub const primitives = [_]Primitive{
    .{ .name = "make-hash", .stack_effect = "quotation -- hash", .func = nativeMakeHash },
    .{ .name = "make-vector", .stack_effect = "quotation -- vector", .func = nativeMakeVector },
    .{ .name = "make-byte-array", .stack_effect = "quotation -- byte-array", .func = nativeMakeByteArray },
    .{ .name = "make-set", .stack_effect = "quotation -- set", .func = nativeMakeSet },
    .{ .name = "make-mutable-map", .stack_effect = "quotation -- mmap", .func = nativeMakeMutableMap },
    .{ .name = "@set!", .stack_effect = "mmap key value -- mmap", .func = nativeAtSetMut },
    .{ .name = "@remove!", .stack_effect = "mmap key -- mmap", .func = nativeAtRemoveMut },
};

/// Helper to extract string from symbol or string value
pub fn extractKeyString(val: Value) ![]const u8 {
    return switch (val) {
        .symbol => |s| s,
        .string => |s| s,
        else => error.TypeError,
    };
}

/// make-hash ( quotation -- hash ) - Create a hash table from key: value pairs
/// The quotation should contain alternating symbol keys and values.
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
        // Expect a symbol key
        const key_instr = instrs[i];
        const key = switch (key_instr.op) {
            .push_literal => |v| switch (v) {
                .symbol => |s| s,
                else => return error.InvalidHashSyntax,
            },
            .call_word => return error.InvalidHashSyntax,
        };
        i += 1;

        if (i >= instrs.len) return error.InvalidHashSyntax;

        // Get the value - could be a literal or need execution
        const val_instr = instrs[i];
        const val = switch (val_instr.op) {
            .push_literal => |v| v,
            .call_word => blk: {
                // Execute the remaining instructions to get the value
                // TODO(ripta): figure out supporting beyond single-words
                try ctx.executeQuotation(.{ .instructions = instrs[i .. i + 1] });
                break :blk ctx.stack.pop() catch return error.InvalidHashSyntax;
            },
        };
        i += 1;

        // Copy key to arena for persistence
        const key_copy = ctx.quotationAllocator().dupe(u8, key) catch return error.OutOfMemory;
        hash.put(ctx.quotationAllocator(), key_copy, val) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .hash = hash });
}

/// make-vector ( quotation -- vector ) - Create a vector from values in quotation
/// Example: [ 1 2 3 ] make-vector
pub fn nativeMakeVector(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const instrs = quot.instructions;
    const alloc = ctx.quotationAllocator();

    // Create a new vector
    const vec = alloc.create(Vector) catch return error.OutOfMemory;
    vec.* = Vector{};

    // Execute each instruction and collect values
    for (instrs) |instr| {
        const val = switch (instr.op) {
            .push_literal => |v| v,
            .call_word => blk: {
                // Execute the word to get the value
                try ctx.executeQuotation(.{ .instructions = @as(*const [1]Instruction, &instr) });
                break :blk ctx.stack.pop() catch return error.OutOfMemory;
            },
        };
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
    const alloc = ctx.quotationAllocator();

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
        // Value must be an integer in byte range
        switch (val) {
            .integer => |int| {
                if (int < 0 or int > 255) return error.IntegerOverflow;
                ba.append(alloc, @intCast(int)) catch return error.OutOfMemory;
            },
            else => return error.TypeError,
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

        set.put(alloc, val, {}) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .set = set });
}

/// make-mutable-map ( quotation -- mmap ) - Create a mutable map from key: value pairs
/// Example: [ name: "Alice" age: 30 ] make-mutable-map
pub fn nativeMakeMutableMap(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const instrs = quot.instructions;
    const alloc = ctx.quotationAllocator();

    // Create a new mutable map
    const mmap = alloc.create(MutableMap) catch return error.OutOfMemory;
    mmap.* = MutableMap{};

    // Parse instructions as key: value pairs (same as make-hash)
    var i: usize = 0;
    while (i < instrs.len) {
        // Expect a symbol key
        const key_instr = instrs[i];
        const key = switch (key_instr.op) {
            .push_literal => |v| switch (v) {
                .symbol => |s| s,
                else => return error.InvalidHashSyntax,
            },
            .call_word => return error.InvalidHashSyntax,
        };
        i += 1;

        if (i >= instrs.len) return error.InvalidHashSyntax;

        // Get the value - could be a literal or need execution
        const val_instr = instrs[i];
        const val = switch (val_instr.op) {
            .push_literal => |v| v,
            .call_word => blk: {
                try ctx.executeQuotation(.{ .instructions = instrs[i .. i + 1] });
                break :blk ctx.stack.pop() catch return error.InvalidHashSyntax;
            },
        };
        i += 1;

        // Copy key to arena for persistence
        const key_copy = alloc.dupe(u8, key) catch return error.OutOfMemory;
        mmap.put(alloc, key_copy, val) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .mutable_map = mmap });
}

/// @set! ( mmap key value -- mmap ) - Set value in mutable map, mutate in place
pub fn nativeAtSetMut(ctx: *Context) anyerror!void {
    const new_value = try ctx.stack.pop();
    const key = try ctx.stack.pop();
    const obj = try ctx.stack.pop();

    const key_str = try extractKeyString(key);

    switch (obj) {
        .mutable_map => |m| {
            const alloc = ctx.quotationAllocator();

            // Check if key already exists
            if (m.get(key_str) != null) {
                // Update existing key in place (use the same key pointer)
                m.putAssumeCapacity(key_str, new_value);
            } else {
                // New key - need to copy it
                const key_copy = alloc.dupe(u8, key_str) catch return error.OutOfMemory;
                m.put(alloc, key_copy, new_value) catch return error.OutOfMemory;
            }

            try ctx.stack.push(.{ .mutable_map = m });
        },
        else => return error.TypeError,
    }
}

/// @remove! ( mmap key -- mmap ) - Remove key from mutable map, mutate in place
pub fn nativeAtRemoveMut(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    const obj = try ctx.stack.pop();

    const key_str = try extractKeyString(key);

    switch (obj) {
        .mutable_map => |m| {
            _ = m.remove(key_str);
            try ctx.stack.push(.{ .mutable_map = m });
        },
        else => return error.TypeError,
    }
}
