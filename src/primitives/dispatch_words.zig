const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const MutableMap = value_mod.MutableMap;

const dispatch_mod = @import("../dispatch.zig");
const DispatchKey = dispatch_mod.DispatchKey;
const DispatchEntry = dispatch_mod.DispatchEntry;
const any_sentinel = dispatch_mod.any_sentinel;
const unary_sentinel = dispatch_mod.unary_sentinel;

const helpers = @import("helpers.zig");
const markers_mod = @import("markers.zig");

const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "define-method", .stack_effect = "name: descriptor markers --", .doc = "Register a method in the dispatch table.", .func = nativeDefineMethod },
};

/// define-method ( name: descriptor markers -- ) - Register a method in the dispatch table
///
/// Called by `;` when it recognizes a method descriptor.
/// Validates the word exists and has appropriate markers, then registers.
///
/// The descriptor is a mutable-map with:
/// - types: array of 1-2 type name strings (use "any" for wildcard)
/// - body: quotation to execute when dispatched
fn nativeDefineMethod(ctx: *Context) anyerror!void {
    const markers_val = try ctx.stack.pop();
    const markers_array = switch (markers_val) {
        .array => |arr| arr,
        else => {
            helpers.setTypeMismatchError(ctx, "array", markers_val);
            return error.TypeMismatch;
        },
    };

    var allow_overwrite = false;
    for (markers_array) |m| {
        switch (m) {
            .marker => |mk| {
                if (markers_mod.isMutableMarker(mk)) {
                    allow_overwrite = true;
                }
            },
            else => {},
        }
    }

    const desc_val = try ctx.stack.pop();
    const desc_map: *MutableMap = switch (desc_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable-map", desc_val);
            return error.TypeMismatch;
        },
    };

    const types_val = desc_map.get("types") orelse return error.MissingField;
    const types_array = switch (types_val) {
        .array => |arr| arr,
        else => {
            helpers.setTypeMismatchError(ctx, "array", types_val);
            return error.TypeMismatch;
        },
    };

    if (types_array.len == 0) {
        helpers.setErrorContext(ctx, "method requires at least one type", .{});
        return error.InvalidArgument;
    }
    if (types_array.len > 2) {
        helpers.setErrorContext(ctx, "method supports at most 2 types (unary or binary dispatch)", .{});
        return error.InvalidArgument;
    }

    const body_val = desc_map.get("body") orelse return error.MissingField;
    const body = switch (body_val) {
        .quotation => |q| q,
        else => {
            helpers.setTypeMismatchError(ctx, "quotation", body_val);
            return error.TypeMismatch;
        },
    };

    const name_val = try ctx.stack.pop();
    const word_name = switch (name_val) {
        .symbol => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol", name_val);
            return error.TypeMismatch;
        },
    };

    const word_def = ctx.lookupWord(word_name) orelse {
        helpers.setErrorContext(ctx, "cannot register method for unknown word '{s}'", .{word_name});
        return error.WordNotFound;
    };

    // For user-defined words, require the `generic` marker.
    //
    // XXX(ripta): Native words accept method registrations without a marker,
    // but only ones that manually call tryDispatchBinary/tryDispatchUnary
    // actually check the dispatch table at runtime. Registering a method on
    // a native that never calls those helpers silently does nothing.
    //
    // NOTE(ripta): Not every native should dispatch. Type-agnostic natives
    // (e.g., dup, drop, swap, etc.) operate on values regardless of type;
    // auto-dispatching them would silently replace structural stack operations,
    // which is dangerous and surprising. Type-switching natives, i.e., those
    // that branch on operand types (like +, inspect, #len), are safe candidates
    // because they already do type-based branching and user types need to plug
    // into that branching.
    //
    // A future `dispatchable` flag on Primitive could move the dispatch
    // check from inside each native to the interpreter call site, removing
    // the manual boilerplate and ensuring the flag and behavior stay in
    // sync. Until then, each type-switching native is responsible for
    // calling tryDispatchBinary or tryDispatchUnary itself.
    switch (word_def.action) {
        .native => {},
        .compound => {
            var has_generic = false;
            for (word_def.markers) |mk| {
                if (markers_mod.isGenericMarker(mk)) {
                    has_generic = true;
                    break;
                }
            }
            if (!has_generic) {
                helpers.setErrorContext(ctx, "cannot register method for non-generic word '{s}' (add `generic` marker)", .{word_name});
                return error.TypeMismatch;
            }
        },
    }

    var type_a: []const u8 = undefined;
    var type_b: []const u8 = unary_sentinel;

    const type_a_str = switch (types_array[0]) {
        .string => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "string", types_array[0]);
            return error.TypeMismatch;
        },
    };
    type_a = if (std.mem.eql(u8, type_a_str, "any")) any_sentinel else type_a_str;

    if (types_array.len == 2) {
        const type_b_str = switch (types_array[1]) {
            .string => |s| s,
            else => {
                helpers.setTypeMismatchError(ctx, "string", types_array[1]);
                return error.TypeMismatch;
            },
        };
        type_b = if (std.mem.eql(u8, type_b_str, "any")) any_sentinel else type_b_str;
    }

    const key = DispatchKey{
        .word_name = word_name,
        .type_a = type_a,
        .type_b = type_b,
    };
    const entry = DispatchEntry{
        .body = body.instructions,
    };

    ctx.dispatch.register(key, entry, allow_overwrite) catch |err| {
        if (err == error.DuplicateMethod) {
            helpers.setErrorContext(ctx, "method for '{s}' with types ({s}, {s}) already registered (use `mutable` to overwrite)", .{ word_name, type_a, type_b });
            return error.DuplicateMethod;
        }
        return err;
    };
}
