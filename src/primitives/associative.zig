const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const HashTable = value_mod.HashTable;
const ErrorObject = value_mod.ErrorObject;
const Module = value_mod.Module;
const Quotation = value_mod.Quotation;

const dispatch_mod = @import("../dispatch.zig");
const container_backing = @import("../container_backing.zig");
const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");
const setErrorContext = helpers.setErrorContext;
const valueTypeName = helpers.valueTypeName;

// Re-use extractKeyString from data_structures
const data_structures = @import("data_structures.zig");
const extractKeyString = data_structures.extractKeyString;

pub const primitives = [_]Primitive{
    .{ .name = "@get", .stack_effect = "assoc key -- value", .doc = "Get value by key from an associative type.", .func = nativeAtGet },
    .{ .name = "@get-or", .stack_effect = "assoc key default -- value", .doc = "Get value by key, or return default if missing.", .func = nativeAtGetOr },
    .{ .name = "@has?", .stack_effect = "assoc key -- ?", .doc = "Check if key exists in an associative type.", .func = nativeAtHas },
    .{ .name = "@set", .stack_effect = "assoc key value -- assoc'", .doc = "Set value by key, returns new hash.", .func = nativeAtSet },
    .{ .name = "@keys", .stack_effect = "assoc -- array", .doc = "Get all keys from an associative type.", .func = nativeAtKeys },
    .{ .name = "@values", .stack_effect = "assoc -- array", .doc = "Get all values from an associative type.", .func = nativeAtValues },
};

/// Helper to get error object field value. Returns an owning reference:
/// the `data` field is retained on the way out and the stack-trace frames
/// are freshly constructed, so callers hand the result to a slot with
/// `pushMoved` instead of `push`.
fn getErrorField(ctx: *Context, err: *const ErrorObject, field_name: []const u8) !Value {
    if (std.mem.eql(u8, field_name, "error-type")) {
        return Value{ .symbol = err.error_type };
    } else if (std.mem.eql(u8, field_name, "message")) {
        return .{ .string = err.message };
    } else if (std.mem.eql(u8, field_name, "data")) {
        if (err.data) |data| {
            container_backing.retainValue(data.*);
            return data.*;
        } else {
            return .{ .boolean = false }; // f for null
        }
    } else if (std.mem.eql(u8, field_name, "stack-trace")) {
        if (err.stack_trace) |trace| {
            const alloc = ctx.quotationAllocator();
            const frames = alloc.alloc(Value, trace.len) catch return error.OutOfMemory;
            var built: usize = 0;
            errdefer container_backing.releaseValues(frames[0..built]);
            for (trace, 0..) |frame, i| {
                const frame_hash = HashTable.create(ctx.allocator) catch return error.OutOfMemory;
                frames[i] = .{ .hash = frame_hash };
                built = i + 1;
                const hash_alloc = frame_hash.header.allocator;
                const word_key = hash_alloc.dupe(u8, "word") catch return error.OutOfMemory;
                frame_hash.map.put(hash_alloc, word_key, .{ .string = frame.word_name }) catch {
                    hash_alloc.free(word_key);
                    return error.OutOfMemory;
                };
                const line_key = hash_alloc.dupe(u8, "line") catch return error.OutOfMemory;
                frame_hash.map.put(hash_alloc, line_key, .{ .fixnum = @intCast(frame.line) }) catch {
                    hash_alloc.free(line_key);
                    return error.OutOfMemory;
                };
            }
            return .{ .array = frames };
        } else {
            return .{ .boolean = false }; // f for null
        }
    } else {
        setErrorContext(ctx, "key '{s}' not found in error", .{field_name});
        return error.KeyNotFound;
    }
}

/// @get ( assoc key -- value ) - Get value by key/field
/// Polymorphic on hash, mutable-map, error, module
pub fn nativeAtGet(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const obj_orig = try ctx.stack.pop();
    defer container_backing.releaseValue(obj_orig);
    const obj = dispatch_mod.unwrapBaseType(obj_orig);

    const key_str = try extractKeyString(ctx, key);

    switch (obj) {
        .hash => |h| {
            if (h.map.get(key_str)) |val| {
                try ctx.stack.push(val);
            } else {
                setErrorContext(ctx, "key '{s}' not found in hash", .{key_str});
                return error.KeyNotFound;
            }
        },
        .mutable_map => |m| {
            if (m.map.get(key_str)) |val| {
                try ctx.stack.push(val);
            } else {
                setErrorContext(ctx, "key '{s}' not found in mutable-map", .{key_str});
                return error.KeyNotFound;
            }
        },
        .error_value => |err| {
            const val = try getErrorField(ctx, err, key_str);
            try ctx.stack.pushMoved(val);
        },
        .module => |mod| {
            if (mod.words.get(key_str)) |word| {
                switch (word.action) {
                    .compound => |instrs| {
                        const alloc = ctx.quotationAllocator();
                        var quot = Quotation{ .instructions = instrs };
                        if (word.stack_effect) |effect| {
                            const effect_ptr = alloc.create(@TypeOf(effect)) catch return error.OutOfMemory;
                            effect_ptr.* = effect;
                            quot.effect = effect_ptr;
                        }
                        try ctx.stack.push(.{ .quotation = quot });
                    },
                    .native, .host_callback => {
                        try word.invoke(ctx);
                    },
                }
            } else {
                setErrorContext(ctx, "key '{s}' not found in module", .{key_str});
                return error.KeyNotFound;
            }
        },
        else => {
            setErrorContext(ctx, "expected associative type, got {s}", .{valueTypeName(obj)});
            return error.TypeMismatch;
        },
    }
}

/// @get-or ( assoc key default -- value ) - Get value by key, or default if missing
/// Polymorphic on hash, mutable-map, error, module
fn nativeAtGetOr(ctx: *Context) anyerror!void {
    const default = try ctx.stack.pop();
    defer container_backing.releaseValue(default);
    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const obj_orig = try ctx.stack.pop();
    defer container_backing.releaseValue(obj_orig);
    const obj = dispatch_mod.unwrapBaseType(obj_orig);

    const key_str = try extractKeyString(ctx, key);

    switch (obj) {
        .hash => |h| {
            if (h.map.get(key_str)) |val| {
                try ctx.stack.push(val);
            } else {
                try ctx.stack.push(default);
            }
        },
        .mutable_map => |m| {
            if (m.map.get(key_str)) |val| {
                try ctx.stack.push(val);
            } else {
                try ctx.stack.push(default);
            }
        },
        .error_value => |err| {
            const val = getErrorField(ctx, err, key_str) catch |e| {
                if (e == error.KeyNotFound) {
                    try ctx.stack.push(default);
                    return;
                }
                return e;
            };
            try ctx.stack.pushMoved(val);
        },
        .module => |mod| {
            if (mod.words.get(key_str)) |word| {
                switch (word.action) {
                    .compound => |instrs| {
                        const alloc = ctx.quotationAllocator();
                        var quot = Quotation{ .instructions = instrs };
                        if (word.stack_effect) |effect| {
                            const effect_ptr = alloc.create(@TypeOf(effect)) catch return error.OutOfMemory;
                            effect_ptr.* = effect;
                            quot.effect = effect_ptr;
                        }
                        try ctx.stack.push(.{ .quotation = quot });
                    },
                    .native, .host_callback => {
                        try word.invoke(ctx);
                    },
                }
            } else {
                try ctx.stack.push(default);
            }
        },
        else => {
            setErrorContext(ctx, "expected associative type, got {s}", .{valueTypeName(obj)});
            return error.TypeMismatch;
        },
    }
}

/// @has? ( assoc key -- ? ) - Check if key/field exists
/// Polymorphic on hash, mmap, module, error
pub fn nativeAtHas(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const obj_orig = try ctx.stack.pop();
    defer container_backing.releaseValue(obj_orig);
    const obj = dispatch_mod.unwrapBaseType(obj_orig);

    const key_str = try extractKeyString(ctx, key);

    switch (obj) {
        .hash => |h| {
            const exists = h.map.get(key_str) != null;
            try ctx.stack.push(.{ .boolean = exists });
        },
        .mutable_map => |m| {
            const exists = m.map.get(key_str) != null;
            try ctx.stack.push(.{ .boolean = exists });
        },
        .error_value => {
            // Check if field name is valid for errors
            const valid = std.mem.eql(u8, key_str, "error-type") or
                std.mem.eql(u8, key_str, "message") or
                std.mem.eql(u8, key_str, "data") or
                std.mem.eql(u8, key_str, "stack-trace");
            try ctx.stack.push(.{ .boolean = valid });
        },
        .module => |mod| {
            const exists = mod.words.get(key_str) != null;
            try ctx.stack.push(.{ .boolean = exists });
        },
        else => {
            setErrorContext(ctx, "expected associative type, got {s}", .{valueTypeName(obj)});
            return error.TypeMismatch;
        },
    }
}

/// @set ( assoc key value -- assoc' ) - Set value, returns new hash
/// Non-polymorphic, only works on hash tables
pub fn nativeAtSet(ctx: *Context) anyerror!void {
    // `new_value` was popped into a C local with ownership transferred from
    // its stack slot; its reference flows into the new hash's slot below, so
    // there is no defer release for it. `obj` and `key` are pure consumes.
    const new_value = try ctx.stack.pop();
    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);

    const key_str = extractKeyString(ctx, key) catch |e| {
        container_backing.releaseValue(new_value);
        return e;
    };

    switch (obj) {
        .hash => |h| {
            const new_hash = HashTable.create(ctx.allocator) catch {
                container_backing.releaseValue(new_value);
                return error.OutOfMemory;
            };
            errdefer container_backing.releaseValue(.{ .hash = new_hash });
            const alloc = new_hash.header.allocator;

            // Clone the existing entries; each copied slot takes its own
            // owning reference to the value.
            var iter = h.map.iterator();
            while (iter.next()) |entry| {
                const key_copy = alloc.dupe(u8, entry.key_ptr.*) catch {
                    container_backing.releaseValue(new_value);
                    return error.OutOfMemory;
                };
                container_backing.retainValue(entry.value_ptr.*);
                new_hash.map.put(alloc, key_copy, entry.value_ptr.*) catch {
                    alloc.free(key_copy);
                    container_backing.releaseValue(entry.value_ptr.*);
                    container_backing.releaseValue(new_value);
                    return error.OutOfMemory;
                };
            }

            // Add/update the new key-value pair. On an existing key the
            // cloned value is displaced: release its reference and keep the
            // already-dup'd key bytes.
            if (new_hash.map.getEntry(key_str)) |entry| {
                const displaced = entry.value_ptr.*;
                entry.value_ptr.* = new_value;
                container_backing.releaseValue(displaced);
            } else {
                const new_key = alloc.dupe(u8, key_str) catch {
                    container_backing.releaseValue(new_value);
                    return error.OutOfMemory;
                };
                new_hash.map.put(alloc, new_key, new_value) catch {
                    alloc.free(new_key);
                    container_backing.releaseValue(new_value);
                    return error.OutOfMemory;
                };
            }

            try ctx.stack.pushMoved(.{ .hash = new_hash });
        },
        .error_value => {
            container_backing.releaseValue(new_value);
            setErrorContext(ctx, "cannot @set on error object", .{});
            return error.TypeMismatch;
        },
        else => {
            container_backing.releaseValue(new_value);
            setErrorContext(ctx, "expected associative type, got {s}", .{valueTypeName(obj)});
            return error.TypeMismatch;
        },
    }
}

/// @keys ( assoc -- array ) - Get all keys
/// Polymorphic on hash, error, module, mutable-map
pub fn nativeAtKeys(ctx: *Context) anyerror!void {
    const obj_orig = try ctx.stack.pop();
    defer container_backing.releaseValue(obj_orig);
    const obj = dispatch_mod.unwrapBaseType(obj_orig);

    switch (obj) {
        .hash => |h| {
            const alloc = ctx.quotationAllocator();
            const keys = alloc.alloc(Value, h.map.count()) catch return error.OutOfMemory;
            var iter = h.map.iterator();
            var i: usize = 0;
            while (iter.next()) |entry| {
                // The hash owns its key bytes and frees them at destroy, so
                // the escaping symbols need arena-lifetime copies.
                const key_copy = alloc.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
                keys[i] = .{ .symbol = key_copy };
                i += 1;
            }
            try ctx.stack.push(.{ .array = keys });
        },
        .mutable_map => |m| {
            const alloc = ctx.quotationAllocator();
            const keys = alloc.alloc(Value, m.map.count()) catch return error.OutOfMemory;
            var iter = m.map.iterator();
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
            const keys = alloc.alloc(Value, 4) catch return error.OutOfMemory;
            keys[0] = .{ .symbol = "error-type" };
            keys[1] = .{ .symbol = "message" };
            keys[2] = .{ .symbol = "data" };
            keys[3] = .{ .symbol = "stack-trace" };
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
        else => {
            setErrorContext(ctx, "expected associative type, got {s}", .{valueTypeName(obj)});
            return error.TypeMismatch;
        },
    }
}

/// @values ( assoc -- array ) - Get all values
/// Polymorphic on hash, mutable-map, error
pub fn nativeAtValues(ctx: *Context) anyerror!void {
    const obj_orig = try ctx.stack.pop();
    defer container_backing.releaseValue(obj_orig);
    const obj = dispatch_mod.unwrapBaseType(obj_orig);
    switch (obj) {
        .hash => |h| {
            const alloc = ctx.quotationAllocator();
            const values = alloc.alloc(Value, h.map.count()) catch return error.OutOfMemory;
            var iter = h.map.iterator();
            var i: usize = 0;
            while (iter.next()) |entry| {
                values[i] = entry.value_ptr.*;
                i += 1;
            }
            try ctx.stack.push(.{ .array = values });
        },
        .mutable_map => |m| {
            const alloc = ctx.quotationAllocator();
            const values = alloc.alloc(Value, m.map.count()) catch return error.OutOfMemory;
            var iter = m.map.iterator();
            var i: usize = 0;
            while (iter.next()) |entry| {
                values[i] = entry.value_ptr.*;
                i += 1;
            }
            try ctx.stack.push(.{ .array = values });
        },
        .error_value => |err| {
            // Get all four error field values. Both fetched fields come back
            // as owning references, so the array transfers to its slot with
            // `pushMoved`.
            const alloc = ctx.quotationAllocator();
            const values = alloc.alloc(Value, 4) catch return error.OutOfMemory;
            values[0] = Value{ .symbol = err.error_type };
            values[1] = .{ .string = err.message };
            values[2] = try getErrorField(ctx, err, "data");
            values[3] = getErrorField(ctx, err, "stack-trace") catch |e| {
                container_backing.releaseValue(values[2]);
                return e;
            };
            try ctx.stack.pushMoved(.{ .array = values });
        },
        else => {
            setErrorContext(ctx, "expected associative type, got {s}", .{valueTypeName(obj)});
            return error.TypeMismatch;
        },
    }
}
