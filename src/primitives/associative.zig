const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const HashTable = value_mod.HashTable;
const ErrorObject = value_mod.ErrorObject;
const Module = value_mod.Module;
const Quotation = value_mod.Quotation;

const dispatch_mod = @import("../dispatch.zig");
const DispatchTable = dispatch_mod.DispatchTable;
const dispatch_helpers = @import("dispatch_helpers.zig");
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
    .{ .name = "@has?", .stack_effect = "assoc key -- ?", .doc = "Check if key exists in an associative type.", .func = nativeAtHas },
    .{ .name = "@set", .stack_effect = "assoc key value -- assoc'", .doc = "Set value by key, returns new hash.", .func = nativeAtSet },
    .{ .name = "@keys", .stack_effect = "assoc -- array", .doc = "Get all keys from an associative type.", .func = nativeAtKeys },
    .{ .name = "@values", .stack_effect = "assoc -- array", .doc = "Get all values from an associative type.", .func = nativeAtValues },
};

pub fn registerNativeDispatch(dispatch: *DispatchTable, ctx: *Context) !void {
    const unary = ctx.getDispatchUnarySentinel();
    const tv = struct {
        fn get(c: *Context, name: []const u8) *const value_mod.TypeValue {
            return c.lookupBuiltinTypeValue(name).?;
        }
    }.get;

    const hash = tv(ctx, "hash");
    const mutable_map = tv(ctx, "mutable-map");
    const err_tv = tv(ctx, "error");
    const module = tv(ctx, "module");

    // @get / @has? : container-keyed at depth 1 (key rides on top).
    const get_did = ctx.resolveDispatchId("@get").?;
    try dispatch.registerNative(get_did, hash, unary, nativeAtGetHash);
    try dispatch.registerNative(get_did, mutable_map, unary, nativeAtGetMutableMap);
    try dispatch.registerNative(get_did, err_tv, unary, nativeAtGetError);
    try dispatch.registerNative(get_did, module, unary, nativeAtGetModule);

    const has_did = ctx.resolveDispatchId("@has?").?;
    try dispatch.registerNative(has_did, hash, unary, nativeAtHasHash);
    try dispatch.registerNative(has_did, mutable_map, unary, nativeAtHasMutableMap);
    try dispatch.registerNative(has_did, err_tv, unary, nativeAtHasError);
    try dispatch.registerNative(has_did, module, unary, nativeAtHasModule);

    // @set : a hash arm and an error arm that rejects.
    const set_did = ctx.resolveDispatchId("@set").?;
    try dispatch.registerNative(set_did, hash, unary, nativeAtSetHash);
    try dispatch.registerNative(set_did, err_tv, unary, nativeAtSetErrorReject);

    // @keys : container at top of stack.
    const keys_did = ctx.resolveDispatchId("@keys").?;
    try dispatch.registerNative(keys_did, hash, unary, nativeAtKeysHash);
    try dispatch.registerNative(keys_did, mutable_map, unary, nativeAtKeysMutableMap);
    try dispatch.registerNative(keys_did, err_tv, unary, nativeAtKeysError);
    try dispatch.registerNative(keys_did, module, unary, nativeAtKeysModule);

    // @values : container at top of stack. Hash, mutable-map, and error arms.
    const values_did = ctx.resolveDispatchId("@values").?;
    try dispatch.registerNative(values_did, hash, unary, nativeAtValuesHash);
    try dispatch.registerNative(values_did, mutable_map, unary, nativeAtValuesMutableMap);
    try dispatch.registerNative(values_did, err_tv, unary, nativeAtValuesError);
}

/// Returns an owning reference: the `data` field is retained on the way out and the stack-trace
/// frames are freshly constructed, so callers hand the result to a slot with `pushMoved` instead
/// of `push`.
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
            const alloc = ctx.allocator;
            const frames = alloc.alloc(Value, trace.len) catch return error.OutOfMemory;
            var built: usize = 0;
            errdefer {
                container_backing.releaseValues(frames[0..built]);
                alloc.free(frames);
            }
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
            const arr = try value_mod.Array.fromOwnedSlice(alloc, frames);
            return .{ .array = arr };
        } else {
            return .{ .boolean = false }; // f for null
        }
    } else {
        setErrorContext(ctx, "key '{s}' not found in error", .{field_name});
        return error.KeyNotFound;
    }
}

/// @get ( assoc key -- value ) - Get value by key/field
pub fn nativeAtGet(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchContainerAtDepth(ctx, "@get", 1, true)) return;

    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    _ = try extractKeyString(ctx, key);
    setErrorContext(ctx, "expected associative type, got {s}", .{valueTypeName(dispatch_mod.unwrapBaseType(obj))});
    return error.TypeMismatch;
}

fn nativeAtGetHash(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    const key_str = try extractKeyString(ctx, key);
    if (obj.hash.map.get(key_str)) |val| {
        try ctx.stack.push(val);
    } else {
        setErrorContext(ctx, "key '{s}' not found in hash", .{key_str});
        return error.KeyNotFound;
    }
}

fn nativeAtGetMutableMap(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    const key_str = try extractKeyString(ctx, key);
    if (obj.mutable_map.map.get(key_str)) |val| {
        try ctx.stack.push(val);
    } else {
        setErrorContext(ctx, "key '{s}' not found in mutable-map", .{key_str});
        return error.KeyNotFound;
    }
}

fn nativeAtGetError(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    const key_str = try extractKeyString(ctx, key);
    const val = try getErrorField(ctx, obj.error_value, key_str);
    try ctx.stack.pushMoved(val);
}

fn nativeAtGetModule(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    const key_str = try extractKeyString(ctx, key);
    if (obj.module.words.get(key_str)) |word| {
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
}

/// @has? ( assoc key -- ? ) - Check if key/field exists
pub fn nativeAtHas(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchContainerAtDepth(ctx, "@has?", 1, true)) return;

    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    _ = try extractKeyString(ctx, key);
    setErrorContext(ctx, "expected associative type, got {s}", .{valueTypeName(dispatch_mod.unwrapBaseType(obj))});
    return error.TypeMismatch;
}

fn nativeAtHasHash(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    const key_str = try extractKeyString(ctx, key);
    const exists = obj.hash.map.get(key_str) != null;
    try ctx.stack.push(.{ .boolean = exists });
}

fn nativeAtHasMutableMap(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    const key_str = try extractKeyString(ctx, key);
    const exists = obj.mutable_map.map.get(key_str) != null;
    try ctx.stack.push(.{ .boolean = exists });
}

fn nativeAtHasError(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    const key_str = try extractKeyString(ctx, key);
    // Error objects expose a fixed set of field names.
    const valid = std.mem.eql(u8, key_str, "error-type") or
        std.mem.eql(u8, key_str, "message") or
        std.mem.eql(u8, key_str, "data") or
        std.mem.eql(u8, key_str, "stack-trace");
    try ctx.stack.push(.{ .boolean = valid });
}

fn nativeAtHasModule(ctx: *Context) anyerror!void {
    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    const key_str = try extractKeyString(ctx, key);
    const exists = obj.module.words.get(key_str) != null;
    try ctx.stack.push(.{ .boolean = exists });
}

/// @set ( assoc key value -- assoc' ) - Set value, returns new hash
///
/// Hash-only; the error arm rejects explicitly.
pub fn nativeAtSet(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchContainerAtDepth(ctx, "@set", 2, false)) return;

    const new_value = try ctx.stack.pop();
    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    _ = extractKeyString(ctx, key) catch |e| {
        container_backing.releaseValue(new_value);
        return e;
    };
    container_backing.releaseValue(new_value);
    setErrorContext(ctx, "expected associative type, got {s}", .{valueTypeName(obj)});
    return error.TypeMismatch;
}

fn nativeAtSetHash(ctx: *Context) anyerror!void {
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

    const h = obj.hash;
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
}

fn nativeAtSetErrorReject(ctx: *Context) anyerror!void {
    const new_value = try ctx.stack.pop();
    const key = try ctx.stack.pop();
    defer container_backing.releaseValue(key);
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    _ = extractKeyString(ctx, key) catch |e| {
        container_backing.releaseValue(new_value);
        return e;
    };
    container_backing.releaseValue(new_value);
    setErrorContext(ctx, "cannot @set on error object", .{});
    return error.TypeMismatch;
}

/// @keys ( assoc -- array ) - Get all keys
pub fn nativeAtKeys(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, "@keys")) return;

    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    setErrorContext(ctx, "expected associative type, got {s}", .{valueTypeName(dispatch_mod.unwrapBaseType(obj))});
    return error.TypeMismatch;
}

fn nativeAtKeysHash(ctx: *Context) anyerror!void {
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    const h = obj.hash;
    const keys = ctx.allocator.alloc(Value, h.map.count()) catch return error.OutOfMemory;
    var iter = h.map.iterator();
    var i: usize = 0;
    while (iter.next()) |entry| {
        // The hash owns its key bytes and frees them at destroy, so
        // the escaping symbols need arena-lifetime copies.
        const key_copy = ctx.quotationAllocator().dupe(u8, entry.key_ptr.*) catch {
            ctx.allocator.free(keys);
            return error.OutOfMemory;
        };
        keys[i] = .{ .symbol = key_copy };
        i += 1;
    }
    try helpers.pushAdoptedArray(ctx, ctx.allocator, keys);
}

fn nativeAtKeysMutableMap(ctx: *Context) anyerror!void {
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    const m = obj.mutable_map;
    const keys = ctx.allocator.alloc(Value, m.map.count()) catch return error.OutOfMemory;
    var iter = m.map.iterator();
    var i: usize = 0;
    while (iter.next()) |entry| {
        // The map owns its key bytes and frees them at release, so
        // the escaping symbols need arena-lifetime copies.
        const key_copy = ctx.quotationAllocator().dupe(u8, entry.key_ptr.*) catch {
            ctx.allocator.free(keys);
            return error.OutOfMemory;
        };
        keys[i] = .{ .symbol = key_copy };
        i += 1;
    }
    try helpers.pushAdoptedArray(ctx, ctx.allocator, keys);
}

fn nativeAtKeysError(ctx: *Context) anyerror!void {
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    // Error objects have fixed fields
    const keys = ctx.allocator.alloc(Value, 4) catch return error.OutOfMemory;
    keys[0] = .{ .symbol = "error-type" };
    keys[1] = .{ .symbol = "message" };
    keys[2] = .{ .symbol = "data" };
    keys[3] = .{ .symbol = "stack-trace" };
    try helpers.pushAdoptedArray(ctx, ctx.allocator, keys);
}

fn nativeAtKeysModule(ctx: *Context) anyerror!void {
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    const mod = obj.module;
    const keys = ctx.allocator.alloc(Value, mod.words.count()) catch return error.OutOfMemory;
    var iter = mod.words.iterator();
    var i: usize = 0;
    while (iter.next()) |entry| {
        keys[i] = .{ .symbol = entry.key_ptr.* };
        i += 1;
    }
    try helpers.pushAdoptedArray(ctx, ctx.allocator, keys);
}

/// @values ( assoc -- array ) - Get all values
///
/// No module arm, unlike @get/@has?/@keys.
pub fn nativeAtValues(ctx: *Context) anyerror!void {
    if (try dispatch_helpers.tryDispatchUnary(ctx, "@values")) return;

    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    setErrorContext(ctx, "expected associative type, got {s}", .{valueTypeName(dispatch_mod.unwrapBaseType(obj))});
    return error.TypeMismatch;
}

fn nativeAtValuesHash(ctx: *Context) anyerror!void {
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    const h = obj.hash;
    const values = ctx.allocator.alloc(Value, h.map.count()) catch return error.OutOfMemory;
    var iter = h.map.iterator();
    var i: usize = 0;
    while (iter.next()) |entry| {
        values[i] = entry.value_ptr.*;
        i += 1;
    }
    // The copied values are borrowed from the hash; the result array
    // must own its own references.
    container_backing.retainValues(values);
    try helpers.pushAdoptedArray(ctx, ctx.allocator, values);
}

fn nativeAtValuesMutableMap(ctx: *Context) anyerror!void {
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    const m = obj.mutable_map;
    const values = ctx.allocator.alloc(Value, m.map.count()) catch return error.OutOfMemory;
    var iter = m.map.iterator();
    var i: usize = 0;
    while (iter.next()) |entry| {
        values[i] = entry.value_ptr.*;
        i += 1;
    }
    container_backing.retainValues(values);
    try helpers.pushAdoptedArray(ctx, ctx.allocator, values);
}

fn nativeAtValuesError(ctx: *Context) anyerror!void {
    const obj = try ctx.stack.pop();
    defer container_backing.releaseValue(obj);
    const err = obj.error_value;
    // Get all four error field values. Both fetched fields come back
    // as owning references, so the array adopts them wholesale.
    const values = ctx.allocator.alloc(Value, 4) catch return error.OutOfMemory;
    values[0] = Value{ .symbol = err.error_type };
    values[1] = .{ .string = err.message };
    values[2] = getErrorField(ctx, err, "data") catch |e| {
        ctx.allocator.free(values);
        return e;
    };
    values[3] = getErrorField(ctx, err, "stack-trace") catch |e| {
        container_backing.releaseValue(values[2]);
        ctx.allocator.free(values);
        return e;
    };
    try helpers.pushAdoptedArray(ctx, ctx.allocator, values);
}
