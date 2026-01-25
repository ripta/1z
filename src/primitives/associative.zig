const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const HashTable = value_mod.HashTable;
const ErrorObject = value_mod.ErrorObject;
const Module = value_mod.Module;
const Quotation = value_mod.Quotation;

const Primitive = @import("types.zig").Primitive;

// Re-use extractKeyString from data_structures
const data_structures = @import("data_structures.zig");
const extractKeyString = data_structures.extractKeyString;

pub const primitives = [_]Primitive{
    .{ .name = "@get", .stack_effect = "assoc key -- value", .func = nativeAtGet },
    .{ .name = "@has?", .stack_effect = "assoc key -- ?", .func = nativeAtHas },
    .{ .name = "@set", .stack_effect = "assoc key value -- assoc'", .func = nativeAtSet },
    .{ .name = "@keys", .stack_effect = "assoc -- array", .func = nativeAtKeys },
    .{ .name = "@values", .stack_effect = "assoc -- array", .func = nativeAtValues },
};

/// Helper to get error object field value
fn getErrorField(ctx: *Context, err: ErrorObject, field_name: []const u8) !Value {
    if (std.mem.eql(u8, field_name, "error-type")) {
        return .{ .string = err.error_type };
    } else if (std.mem.eql(u8, field_name, "message")) {
        return .{ .string = err.message };
    } else if (std.mem.eql(u8, field_name, "stack-trace")) {
        if (err.stack_trace) |trace| {
            const alloc = ctx.quotationAllocator();
            const frames = alloc.alloc(Value, trace.len) catch return error.OutOfMemory;
            for (trace, 0..) |frame, i| {
                const frame_hash = alloc.create(HashTable) catch return error.OutOfMemory;
                frame_hash.* = HashTable{};
                const word_key = alloc.dupe(u8, "word") catch return error.OutOfMemory;
                frame_hash.put(alloc, word_key, .{ .string = frame.word_name }) catch return error.OutOfMemory;
                const line_key = alloc.dupe(u8, "line") catch return error.OutOfMemory;
                frame_hash.put(alloc, line_key, .{ .integer = @intCast(frame.line) }) catch return error.OutOfMemory;
                frames[i] = .{ .hash = frame_hash };
            }
            return .{ .array = frames };
        } else {
            return .{ .boolean = false }; // f for null
        }
    } else {
        return error.KeyNotFound;
    }
}

/// @get ( assoc key -- value ) - Get value by key/field
/// Polymorphic on hash, mutable-map, error, module
pub fn nativeAtGet(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    const obj = try ctx.stack.pop();

    const key_str = try extractKeyString(key);

    switch (obj) {
        .hash => |h| {
            if (h.get(key_str)) |val| {
                try ctx.stack.push(val);
            } else {
                return error.KeyNotFound;
            }
        },
        .mutable_map => |m| {
            if (m.get(key_str)) |val| {
                try ctx.stack.push(val);
            } else {
                return error.KeyNotFound;
            }
        },
        .error_value => |err| {
            const val = try getErrorField(ctx, err, key_str);
            try ctx.stack.push(val);
        },
        .module => |mod| {
            if (mod.words.get(key_str)) |word| {
                const alloc = ctx.quotationAllocator();
                var quot = Quotation{ .instructions = word.instructions };
                if (word.stack_effect) |effect| {
                    const effect_ptr = alloc.create(@TypeOf(effect)) catch return error.OutOfMemory;
                    effect_ptr.* = effect;
                    quot.effect = effect_ptr;
                }

                try ctx.stack.push(.{ .quotation = quot });
            } else {
                return error.KeyNotFound;
            }
        },
        else => return error.TypeError,
    }
}

/// @has? ( assoc key -- ? ) - Check if key/field exists
/// Polymorphic on hash, mmap, module, error
pub fn nativeAtHas(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    const obj = try ctx.stack.pop();

    const key_str = try extractKeyString(key);

    switch (obj) {
        .hash => |h| {
            const exists = h.get(key_str) != null;
            try ctx.stack.push(.{ .boolean = exists });
        },
        .mutable_map => |m| {
            const exists = m.get(key_str) != null;
            try ctx.stack.push(.{ .boolean = exists });
        },
        .error_value => {
            // Check if field name is valid for errors
            const valid = std.mem.eql(u8, key_str, "error-type") or
                std.mem.eql(u8, key_str, "message") or
                std.mem.eql(u8, key_str, "stack-trace");
            try ctx.stack.push(.{ .boolean = valid });
        },
        .module => |mod| {
            const exists = mod.words.get(key_str) != null;
            try ctx.stack.push(.{ .boolean = exists });
        },
        else => return error.TypeError,
    }
}

/// @set ( assoc key value -- assoc' ) - Set value, returns new hash
/// Non-polymorphic, only works on hash tables
pub fn nativeAtSet(ctx: *Context) anyerror!void {
    const new_value = try ctx.stack.pop();
    const key = try ctx.stack.pop();
    const obj = try ctx.stack.pop();

    const key_str = try extractKeyString(key);

    switch (obj) {
        .hash => |h| {
            const alloc = ctx.quotationAllocator();
            const new_hash = alloc.create(HashTable) catch return error.OutOfMemory;
            new_hash.* = HashTable{};

            // Clone the existing entries
            var iter = h.iterator();
            while (iter.next()) |entry| {
                const key_copy = alloc.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
                new_hash.put(alloc, key_copy, entry.value_ptr.*) catch return error.OutOfMemory;
            }

            // Add/update the new key-value pair
            const new_key = alloc.dupe(u8, key_str) catch return error.OutOfMemory;
            new_hash.put(alloc, new_key, new_value) catch return error.OutOfMemory;

            try ctx.stack.push(.{ .hash = new_hash });
        },
        .error_value => return error.TypeError,
        else => return error.TypeError,
    }
}

/// @keys ( assoc -- array ) - Get all keys
/// Polymorphic on hash, error, module, mutable-map
pub fn nativeAtKeys(ctx: *Context) anyerror!void {
    const obj = try ctx.stack.pop();

    switch (obj) {
        .hash => |h| {
            const alloc = ctx.quotationAllocator();
            const keys = alloc.alloc(Value, h.count()) catch return error.OutOfMemory;
            var iter = h.iterator();
            var i: usize = 0;
            while (iter.next()) |entry| {
                keys[i] = .{ .symbol = entry.key_ptr.* };
                i += 1;
            }
            try ctx.stack.push(.{ .array = keys });
        },
        .mutable_map => |m| {
            const alloc = ctx.quotationAllocator();
            const keys = alloc.alloc(Value, m.count()) catch return error.OutOfMemory;
            var iter = m.iterator();
            var i: usize = 0;
            while (iter.next()) |entry| {
                keys[i] = .{ .symbol = entry.key_ptr.* };
                i += 1;
            }
            try ctx.stack.push(.{ .array = keys });
        },
        .error_value => {
            // Error objects have fixed fields
            const alloc = ctx.quotationAllocator();
            const keys = alloc.alloc(Value, 3) catch return error.OutOfMemory;
            keys[0] = .{ .symbol = "error-type" };
            keys[1] = .{ .symbol = "message" };
            keys[2] = .{ .symbol = "stack-trace" };
            try ctx.stack.push(.{ .array = keys });
        },
        .module => |mod| {
            const alloc = ctx.quotationAllocator();
            const keys = alloc.alloc(Value, mod.words.count()) catch return error.OutOfMemory;
            var iter = mod.words.iterator();
            var i: usize = 0;
            while (iter.next()) |entry| {
                keys[i] = .{ .symbol = entry.key_ptr.* };
                i += 1;
            }
            try ctx.stack.push(.{ .array = keys });
        },
        else => return error.TypeError,
    }
}

/// @values ( assoc -- array ) - Get all values
/// Polymorphic on hash, mutable-map, error
pub fn nativeAtValues(ctx: *Context) anyerror!void {
    const obj = try ctx.stack.pop();
    switch (obj) {
        .hash => |h| {
            const alloc = ctx.quotationAllocator();
            const values = alloc.alloc(Value, h.count()) catch return error.OutOfMemory;
            var iter = h.iterator();
            var i: usize = 0;
            while (iter.next()) |entry| {
                values[i] = entry.value_ptr.*;
                i += 1;
            }
            try ctx.stack.push(.{ .array = values });
        },
        .mutable_map => |m| {
            const alloc = ctx.quotationAllocator();
            const values = alloc.alloc(Value, m.count()) catch return error.OutOfMemory;
            var iter = m.iterator();
            var i: usize = 0;
            while (iter.next()) |entry| {
                values[i] = entry.value_ptr.*;
                i += 1;
            }
            try ctx.stack.push(.{ .array = values });
        },
        .error_value => |err| {
            // Get all three error field values
            const alloc = ctx.quotationAllocator();
            const values = alloc.alloc(Value, 3) catch return error.OutOfMemory;
            values[0] = .{ .string = err.error_type };
            values[1] = .{ .string = err.message };
            values[2] = try getErrorField(ctx, err, "stack-trace");
            try ctx.stack.push(.{ .array = values });
        },
        else => return error.TypeError,
    }
}
