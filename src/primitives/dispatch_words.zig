const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const MutableMap = value_mod.MutableMap;

const dispatch_mod = @import("../dispatch.zig");
const DispatchKey = dispatch_mod.DispatchKey;
const DispatchEntry = dispatch_mod.DispatchEntry;

const container_backing = @import("../container_backing.zig");
const helpers = @import("helpers.zig");
const markers_mod = @import("markers.zig");

const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "define-method", .stack_effect = "name: descriptor markers --", .doc = "Register a method in the dispatch table.", .func = nativeDefineMethod },
};

/// define-method ( name: descriptor markers -- )
///
/// Called by `;` when it recognizes a method descriptor. The descriptor is a mutable-map with:
/// - types: array of 1-2 type specifiers (TypeValues, the `any` marker, or string fallback)
/// - body: quotation to execute when dispatched
fn nativeDefineMethod(ctx: *Context) anyerror!void {
    const markers_val = try ctx.stack.pop();
    defer container_backing.releaseValue(markers_val);
    const markers_array = switch (markers_val) {
        .array => |arr| arr.items,
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
    defer container_backing.releaseValue(desc_val);
    const desc_map: *MutableMap = switch (desc_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable-map", desc_val);
            return error.TypeMismatch;
        },
    };

    const types_val = desc_map.map.get("types") orelse return error.MissingField;
    const types_array = switch (types_val) {
        .array => |arr| arr.items,
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

    const body_val = desc_map.map.get("body") orelse return error.MissingField;
    const body = (try helpers.asQuotationStamped(ctx, body_val)) orelse {
        helpers.setTypeMismatchError(ctx, "quotation", body_val);
        return error.TypeMismatch;
    };

    const name_val = try ctx.stack.pop();
    const word_name = switch (name_val) {
        .symbol => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol", name_val);
            return error.TypeMismatch;
        },
    };

    const resolved = resolveWordForDispatch(ctx, word_name) orelse {
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
    switch (resolved.action) {
        .native, .host_callback => {},
        .compound => {
            var has_generic = false;
            for (resolved.markers) |mk| {
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

    var type_a: *const value_mod.TypeValue = undefined;
    var type_b: *const value_mod.TypeValue = ctx.getDispatchUnarySentinel();

    type_a = try extractTypeValue(ctx, types_array[0]);

    if (types_array.len == 2) {
        type_b = try extractTypeValue(ctx, types_array[1]);
    }

    const dispatch_id = resolved.dispatch_id;
    const key = DispatchKey{
        .dispatch_id = dispatch_id,
        .type_a = type_a.descriptor.?,
        .type_b = type_b.descriptor.?,
    };
    const entry = DispatchEntry{
        .body = .{ .quotation = .{ .instructions = body.instructions } },
        .source_module = ctx.loading_module,
    };

    ctx.registerDispatch(key, entry, allow_overwrite) catch |err| {
        if (err == error.DuplicateMethod) {
            // If the existing entry was registered by the native dispatch
            // system, allow user methods to silently overwrite it. This lets
            // libraries like ratio register `method{ fixnum fixnum }` for `/`
            // without requiring the `mutable` marker.
            if (ctx.getDispatchEntry(key)) |existing| {
                if (existing.provenance) |prov| {
                    if (std.mem.eql(u8, prov.generator, "native")) {
                        ctx.registerDispatch(key, entry, true) catch |err2| return err2;
                        return;
                    }
                }
            }
            helpers.setErrorContext(ctx, "method for '{s}' with types ({s}, {s}) already registered (use `mutable` to overwrite)", .{ word_name, type_a.name, type_b.name });
            return error.DuplicateMethod;
        }
        return err;
    };
}

fn extractTypeValue(ctx: *Context, val: value_mod.Value) !*const value_mod.TypeValue {
    return switch (val) {
        .type_val => |tv| tv,
        .marker => |mk| {
            if (markers_mod.isAnyMarker(mk)) return ctx.getDispatchAnySentinel();
            helpers.setErrorContext(ctx, "invalid marker in method type position; only `any` is allowed", .{});
            return error.InvalidArgument;
        },
        .string => |s| {
            if (ctx.lookupTypeValueByName(s)) |tv| return tv;

            // Try qualified name resolution: "module.typename"
            if (std.mem.indexOfScalar(u8, s, '.') != null) {
                if (resolveQualifiedTypeValue(ctx, s)) |tv| return tv;
            }

            helpers.setErrorContext(ctx, "unknown type name '{s}' in method type position", .{s});
            return error.TypeMismatch;
        },
        else => {
            helpers.setTypeMismatchError(ctx, "type, `any` marker, or string", val);
            return error.TypeMismatch;
        },
    };
}

const ResolvedWord = struct {
    dispatch_id: u32,
    markers: []const *value_mod.Marker,
    action: union(enum) {
        native,
        host_callback,
        compound,
    },
};

/// Resolve a word name (bare or dot-qualified) to dispatch-relevant fields.
fn resolveWordForDispatch(ctx: *Context, name: []const u8) ?ResolvedWord {
    if (ctx.lookupWord(name)) |wd| {
        return .{
            .dispatch_id = wd.dispatch_id,
            .markers = wd.markers,
            .action = switch (wd.action) {
                .native => .native,
                .host_callback => .host_callback,
                // A literal is a user-defined binding, not a native
                // function, so it is subject to the same generic-marker
                // requirement as a compound word.
                .compound, .literal => .compound,
            },
        };
    }

    const mod_word = ctx.resolveQualifiedModuleWord(name) orelse return null;
    return .{
        .dispatch_id = mod_word.dispatch_id,
        .markers = mod_word.markers,
        .action = switch (mod_word.action) {
            .native => .native,
            .host_callback => .host_callback,
            .compound => .compound,
        },
    };
}

/// Resolve a dot-qualified type name (e.g., "ea.color") to a TypeValue by
/// inspecting the module word's literal and looking up the type in that module.
fn resolveQualifiedTypeValue(ctx: *Context, name: []const u8) ?*const value_mod.TypeValue {
    const mod_word = ctx.resolveQualifiedModuleWord(name) orelse return null;
    switch (mod_word.action) {
        .compound => |instrs| {
            if (instrs.len == 1) {
                switch (instrs[0].op) {
                    .push_literal => |val| switch (val) {
                        .type_val => |tv| return tv,
                        .tagged => |t| return t.tag.type_val,
                        else => return null,
                    },
                    else => return null,
                }
            }
            return null;
        },
        .native, .host_callback => return null,
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;

fn noopNative(_: *Context) anyerror!void {}

/// Drive `nativeDefineMethod` for a unary method on a freshly-defined native
/// generic word keyed by `tv`, with `ctx.loading_module` set to `loading` for
/// the duration of the registration. Returns the registered entry.
fn registerUnaryMethod(
    ctx: *Context,
    word_name: []const u8,
    tv: *value_mod.TypeValue,
    loading: ?*const value_mod.Module,
) !?DispatchEntry {
    // A native target word skips the `generic` marker requirement, keeping the
    // test focused on the defining-module capture rather than marker plumbing.
    try ctx.defineWord(word_name, .{ .name = word_name, .action = .{ .native = noopNative } });

    const desc_map = try value_mod.MutableMap.create(testing.allocator);
    // The map slot releases its values at destroy, so the types array needs an
    // initialized header; the context arena reclaims the static allocations.
    const types_items = try ctx.quotationAllocator().dupe(Value, &.{.{ .type_val = tv }});
    const types_arr_val = try value_mod.Array.createStatic(ctx.quotationAllocator(), types_items);
    try desc_map.map.put(testing.allocator, try testing.allocator.dupe(u8, "types"), .{ .array = types_arr_val });
    const body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 0 }};
    try desc_map.map.put(testing.allocator, try testing.allocator.dupe(u8, "body"), .{ .quotation = .{ .instructions = body } });

    // Stack order: name, descriptor, markers (popped in reverse). The map's
    // sole owning reference moves to the stack via pushMoved, so the eventual
    // release inside nativeDefineMethod destroys it exactly once.
    try ctx.stack.push(.{ .symbol = word_name });
    try ctx.stack.pushMoved(.{ .mutable_map = desc_map });
    // The push retains the header, so the empty markers array needs an
    // initialized one; the context arena reclaims the static struct.
    const empty_markers = try value_mod.Array.createStatic(ctx.quotationAllocator(), &.{});
    try ctx.stack.push(.{ .array = empty_markers });

    const saved = ctx.loading_module;
    ctx.loading_module = loading;
    defer ctx.loading_module = saved;
    try nativeDefineMethod(ctx);

    const dispatch_id = ctx.lookupWord(word_name).?.dispatch_id;
    const key = DispatchKey{
        .dispatch_id = dispatch_id,
        .type_a = tv.descriptor.?,
        .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
    };
    return ctx.getDispatchEntry(key);
}

test "method entry carries its defining module after registration" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const desc = try value_mod.createBuiltinTypeDescriptor(testing.allocator, .{});
    defer value_mod.destroyTypeDescriptor(testing.allocator, desc);
    var tv = value_mod.TypeValue{ .name = "widget", .descriptor = desc };

    var defining = value_mod.Module{ .name = "widgets", .words = .{} };

    const entry = (try registerUnaryMethod(&ctx, "render", &tv, &defining)).?;
    try testing.expectEqual(@as(?*const value_mod.Module, &defining), entry.source_module);
}

test "cross-module method records the defining module, not the type's module" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // The type conceptually belongs to module N; the method body is written in
    // module M (the loading module). The entry must record M.
    const desc = try value_mod.createBuiltinTypeDescriptor(testing.allocator, .{});
    defer value_mod.destroyTypeDescriptor(testing.allocator, desc);
    var tv = value_mod.TypeValue{ .name = "color", .descriptor = desc };

    var type_module = value_mod.Module{ .name = "palette", .words = .{} };
    var body_module = value_mod.Module{ .name = "renderer", .words = .{} };

    const entry = (try registerUnaryMethod(&ctx, "inspect", &tv, &body_module)).?;
    try testing.expectEqual(@as(?*const value_mod.Module, &body_module), entry.source_module);
    try testing.expect(entry.source_module != &type_module);
}

test "method registered outside a module load has no defining module" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const desc = try value_mod.createBuiltinTypeDescriptor(testing.allocator, .{});
    defer value_mod.destroyTypeDescriptor(testing.allocator, desc);
    var tv = value_mod.TypeValue{ .name = "gadget", .descriptor = desc };

    const entry = (try registerUnaryMethod(&ctx, "describe", &tv, null)).?;
    try testing.expectEqual(@as(?*const value_mod.Module, null), entry.source_module);
}
