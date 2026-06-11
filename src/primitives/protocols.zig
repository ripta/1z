const std = @import("std");

const context_mod = @import("../context.zig");
const Context = context_mod.Context;
const ProtocolSatisfiesKey = context_mod.ProtocolSatisfiesKey;

const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Marker = value_mod.Marker;
const MutableMap = value_mod.MutableMap;
const Instruction = value_mod.Instruction;
const ProtocolDescriptor = value_mod.ProtocolDescriptor;

const stack_effect_mod = @import("../stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;

const markers_mod = @import("markers.zig");
const dispatch_mod = @import("../dispatch.zig");
const container_backing = @import("../container_backing.zig");

const helpers = @import("helpers.zig");

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;

pub const primitives = [_]Primitive{
    .{ .name = "define-protocol", .stack_effect = "name: descriptor markers --", .doc = "Define a protocol word that validates a type implements all required methods.", .func = nativeDefineProtocol },
    .{ .name = "assert-satisfies", .stack_effect = "type-sym constraint --", .doc = "Throws a protocol-error if the named type does not satisfy the given protocol constraint.", .func = protocolCheckHelper },
    .{ .name = "satisfies?", .stack_effect = "type-sym constraint -- ?", .doc = "Returns t if the named type satisfies the protocol constraint, f otherwise.", .func = nativeSatisfies },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "protocol-check", .func = protocolCheckHelper, .stack_effect = "type-name descriptor --" },
};

/// define-protocol ( name: descriptor markers -- )
///
/// Called by `;` when it recognizes a protocol descriptor.
///
/// Allocates a `ProtocolDescriptor` that owns the protocol's name and methods list, then emits a
/// parse-time const word whose body pushes the descriptor pointer onto the stack. Runtime
/// validation is performed by separate verbs (`assert-satisfies`); the protocol word itself is
/// just a handle factory.
///
/// The parse-time descriptor is a mutable-map with:
///
/// - `methods:` flat array of symbols interleaved with optional stack-effects
fn nativeDefineProtocol(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const markers_val = try ctx.stack.pop();
    _ = switch (markers_val) {
        .array => |arr| arr,
        else => {
            helpers.setTypeMismatchError(ctx, "array", markers_val);
            return error.TypeMismatch;
        },
    };

    const desc_val = try ctx.stack.pop();
    defer container_backing.releaseValue(desc_val);
    const desc_map: *MutableMap = switch (desc_val) {
        .mutable_map => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "mutable-map", desc_val);
            return error.TypeMismatch;
        },
    };

    const methods_val = desc_map.map.get("methods") orelse return error.MissingField;
    const methods_array = switch (methods_val) {
        .array => |arr| arr,
        else => {
            helpers.setErrorContext(ctx, "protocol descriptor 'methods' field must be an array", .{});
            return error.TypeMismatch;
        },
    };

    if (methods_array.len == 0) {
        helpers.setErrorContext(ctx, "protocol requires at least one method", .{});
        return error.InvalidArgument;
    }

    const name_val = try ctx.stack.pop();
    const protocol_name = switch (name_val) {
        .symbol => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol", name_val);
            return error.TypeMismatch;
        },
    };

    const descriptor = try ctx.createProtocolDescriptor(protocol_name, methods_array);

    const instrs = try alloc.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .push_literal = .{ .protocol_descriptor = descriptor } }, .line = 0 };

    const word_markers = try alloc.alloc(*Marker, 2);
    word_markers[0] = @constCast(&markers_mod.parse_time_marker);
    word_markers[1] = @constCast(&markers_mod.const_marker);

    try ctx.defineWord(protocol_name, .{
        .name = descriptor.name,
        .parse_time = true,
        .markers = word_markers,
        .provenance = .{ .generator = "protocol", .parent = descriptor.name, .role = "constraint" },
        .action = .{ .compound = instrs },
    });
}

/// Trampoline helper ( type-name descriptor -- )
///
/// Reads `methods` and `name` off the descriptor. The methods slice is a flat sequence of symbols
/// interleaved with optional stack-effects.
///
/// For each symbol:
///
/// - If followed by a `stack-effect:` typed method validation using the effect's input type annotations.
/// - The `self` sentinel is substituted with the implementing type.
/// - The `any` sentinel triggers enumeration of dispatch entries.
/// - Otherwise, bare `method` (backward compat) checking unary or same-type binary dispatch.
fn protocolCheckHelper(ctx: *Context) anyerror!void {
    const desc_val = try ctx.stack.pop();
    const descriptor = switch (desc_val) {
        .protocol_descriptor => |d| d,
        else => {
            helpers.setTypeMismatchError(ctx, "constraint", desc_val);
            return error.TypeMismatch;
        },
    };
    const type_name = switch (try ctx.stack.pop()) {
        .symbol => |s| s,
        else => {
            helpers.setErrorContext(ctx, "protocol validation expects a type name (symbol) on the stack", .{});
            return error.TypeMismatch;
        },
    };

    if (ctx.in_module_load) {
        try ctx.protocol_obligations.append(ctx.allocator, .{
            .type_name = type_name,
            .descriptor = descriptor,
        });
        return;
    }

    try validateProtocolObligation(ctx, type_name, descriptor);
}

/// satisfies? ( type-sym constraint -- ? )
///
/// Predicate companion to `assert-satisfies`: returns a boolean instead of throwing.
/// Shares the per-`Context` satisfies memo populated by `assert-satisfies`, so the
/// steady-state path is a single hash lookup either way.
fn nativeSatisfies(ctx: *Context) anyerror!void {
    const desc_val = try ctx.stack.pop();
    const descriptor = switch (desc_val) {
        .protocol_descriptor => |d| d,
        else => {
            helpers.setTypeMismatchError(ctx, "constraint", desc_val);
            return error.TypeMismatch;
        },
    };
    const type_name = switch (try ctx.stack.pop()) {
        .symbol => |s| s,
        else => {
            helpers.setErrorContext(ctx, "satisfies? expects a type name (symbol) on the stack", .{});
            return error.TypeMismatch;
        },
    };

    const result = try checkProtocolObligation(ctx, type_name, descriptor);
    try ctx.stack.push(.{ .boolean = result });
}

/// Predicate-shaped variant of `validateProtocolObligation`. Returns true if the
/// type satisfies the protocol, false otherwise; never raises `protocol-error`.
/// Other failures (e.g. `TypeMismatch` from a malformed descriptor) still
/// propagate, since those are programming errors rather than protocol mismatches.
pub fn checkProtocolObligation(
    ctx: *Context,
    type_name: []const u8,
    descriptor: *const ProtocolDescriptor,
) !bool {
    const type_tv = ctx.lookupTypeValueByName(type_name) orelse {
        helpers.setErrorContext(ctx, "unknown type '{s}' in protocol validation", .{type_name});
        return error.TypeMismatch;
    };
    return satisfiesByDescriptor(ctx, type_tv, descriptor);
}

/// Pointer-only entry into the satisfies-check: callers that already have a
/// resolved `TypeValue` skip the name-to-TypeValue lookup. Returns true on
/// satisfy, false on mismatch, and never raises `protocol-error`. Programming
/// errors (e.g. a malformed descriptor) still propagate.
///
/// Used by the runtime check in `Context.validateTypeAnnotations` for
/// protocol-bounded parameters, where the call site already has a resolved
/// `TypeValue` for the actual stack value.
pub fn satisfiesByDescriptor(
    ctx: *Context,
    type_tv: *const value_mod.TypeValue,
    descriptor: *const ProtocolDescriptor,
) !bool {
    const key = ProtocolSatisfiesKey{
        .type_descriptor = type_tv.descriptor.?,
        .protocol_descriptor = descriptor,
    };

    if (ctx.lookupProtocolSatisfies(key)) |cached| {
        return cached;
    }

    const saved_thrown = ctx.thrown_error;
    if (validateProtocolObligationUncached(ctx, type_tv.name, descriptor)) |_| {
        ctx.storeProtocolSatisfies(key, true);
        return true;
    } else |err| {
        if (err == error.UserThrown) {
            ctx.thrown_error = saved_thrown;
            ctx.storeProtocolSatisfies(key, false);
            return false;
        }
        return err;
    }
}

/// Check whether a resolved type satisfies a constraint element: a concrete
/// type, a protocol bound, or a combinator. Intersection requires every
/// element to be satisfied; union requires any one; nested combinators recurse.
/// Reuses the memoized protocol satisfies-check for the protocol case and the
/// anonymous-union-aware type match for the type case. Never raises
/// `protocol-error`; programming errors (e.g. a malformed descriptor) propagate.
pub fn typeSatisfiesConstraint(
    ctx: *Context,
    type_tv: *const value_mod.TypeValue,
    element: value_mod.ConstraintCombinator.Element,
) anyerror!bool {
    return switch (element) {
        .type => |expected| helpers.typeMatchesConstraint(type_tv, expected),
        .protocol => |descriptor| try satisfiesByDescriptor(ctx, type_tv, descriptor),
        .combinator => |cc| switch (cc.kind) {
            .intersection => {
                for (cc.elements) |sub| {
                    if (!try typeSatisfiesConstraint(ctx, type_tv, sub)) return false;
                }
                return true;
            },
            .@"union" => {
                for (cc.elements) |sub| {
                    if (try typeSatisfiesConstraint(ctx, type_tv, sub)) return true;
                }
                return false;
            },
        },
    };
}

/// Check whether a value satisfies a struct-field constraint element. Concrete
/// types route through `valueMatchesType` so the `any` sentinel, anonymous
/// unions, and tagged parent/base relationships are honored; protocol and
/// combinator elements check the value's resolved type against the constraint.
pub fn valueMatchesElement(
    ctx: *Context,
    val: Value,
    element: value_mod.ConstraintCombinator.Element,
) anyerror!bool {
    return switch (element) {
        .type => |tv| helpers.valueMatchesType(ctx, val, tv),
        .protocol, .combinator => blk: {
            const type_tv = helpers.resolveValueTypeValue(ctx, val) orelse break :blk false;
            break :blk try typeSatisfiesConstraint(ctx, type_tv, element);
        },
    };
}

/// Parse-time satisfies check that only verifies same-type methods.
/// Cross-type methods (those with `any` annotations or non-self concrete
/// annotations) are skipped because the contributing modules may not have
/// loaded yet; the runtime check at the call site remains authoritative
/// for those.
///
/// Returns true when every same-type method in the descriptor has a
/// matching dispatch entry for `type_tv`, including the trivial case
/// where the descriptor contains only cross-type methods.
pub fn satisfiesByDescriptorSameTypeOnly(
    ctx: *Context,
    type_tv: *const value_mod.TypeValue,
    descriptor: *const ProtocolDescriptor,
) !bool {
    const methods_array = descriptor.methods;
    var i: usize = 0;
    while (i < methods_array.len) {
        const method_val = methods_array[i];
        const method_name = switch (method_val) {
            .symbol => |s| s,
            else => {
                helpers.setErrorContext(ctx, "protocol method entries must be symbols", .{});
                return error.TypeMismatch;
            },
        };
        i += 1;

        if (i < methods_array.len and methods_array[i] == .stack_effect) {
            const effect = methods_array[i].stack_effect;
            i += 1;
            if (isCrossTypeMethod(ctx, effect)) continue;
            if (!sameTypeMethodRegistered(ctx, method_name, effect, type_tv)) return false;
        } else {
            const did = ctx.resolveDispatchId(method_name) orelse return false;
            const has_method = ctx.lookupUnaryDispatch(did, type_tv.descriptor.?) != null or
                ctx.lookupBinaryDispatch(did, type_tv.descriptor.?, type_tv.descriptor.?) != null;
            if (!has_method) return false;
        }
    }
    return true;
}

/// Check that a same-type method has a dispatch entry for `type_tv`.
/// Caller must have verified `isCrossTypeMethod(ctx, effect) == false`,
/// so every input is either unannotated or carries the `self` sentinel.
fn sameTypeMethodRegistered(
    ctx: *Context,
    method_name: []const u8,
    effect: StackEffect,
    type_tv: *const value_mod.TypeValue,
) bool {
    const did = ctx.resolveDispatchId(method_name) orelse return false;
    const n_inputs = @min(effect.inputs.len, 2);
    if (n_inputs <= 1) {
        return ctx.lookupUnaryDispatch(did, type_tv.descriptor.?) != null;
    }
    return ctx.lookupBinaryDispatch(did, type_tv.descriptor.?, type_tv.descriptor.?) != null;
}

/// Validate a single protocol obligation: check that all required methods
/// are registered in the dispatch table. Consults the per-`Context`
/// satisfies-check memo so the steady-state path is a single hash lookup;
/// on miss, runs the full walk and caches the outcome. Coarse invalidation
/// in `registerDispatchLocked` / `popDispatchFrameLocked` keeps the memo
/// honest across REPL definitions and runtime module loads.
pub fn validateProtocolObligation(
    ctx: *Context,
    type_name: []const u8,
    descriptor: *const ProtocolDescriptor,
) !void {
    const type_tv = ctx.lookupTypeValueByName(type_name) orelse {
        helpers.setErrorContext(ctx, "unknown type '{s}' in protocol validation", .{type_name});
        return error.TypeMismatch;
    };
    const key = ProtocolSatisfiesKey{
        .type_descriptor = type_tv.descriptor.?,
        .protocol_descriptor = descriptor,
    };

    if (ctx.lookupProtocolSatisfies(key)) |cached| {
        if (cached) return;
        // Cached failure: re-walk to throw a method-specific protocol error.
    }

    validateProtocolObligationUncached(ctx, type_name, descriptor) catch |err| {
        ctx.storeProtocolSatisfies(key, false);
        return err;
    };
    ctx.storeProtocolSatisfies(key, true);
}

/// Full satisfies-check walk. Same-type and bare methods are checked
/// immediately; cross-type (`any`) methods are checked immediately as well
/// (they enumerate dispatch entries).
fn validateProtocolObligationUncached(
    ctx: *Context,
    type_name: []const u8,
    descriptor: *const ProtocolDescriptor,
) !void {
    const methods_array = descriptor.methods;
    const protocol_name = descriptor.name;
    var i: usize = 0;
    while (i < methods_array.len) {
        const method_val = methods_array[i];
        const method_name = switch (method_val) {
            .symbol => |s| s,
            else => {
                helpers.setErrorContext(ctx, "protocol method entries must be symbols", .{});
                return error.TypeMismatch;
            },
        };
        i += 1;

        if (i < methods_array.len and methods_array[i] == .stack_effect) {
            const effect = methods_array[i].stack_effect;
            i += 1;

            try validateTypedMethod(ctx, method_name, effect, type_name, protocol_name);
        } else {
            const type_tv = ctx.lookupTypeValueByName(type_name) orelse {
                helpers.setErrorContext(ctx, "unknown type '{s}' in protocol validation", .{type_name});
                return error.TypeMismatch;
            };
            const has_method = if (ctx.resolveDispatchId(method_name)) |did|
                ctx.lookupUnaryDispatch(did, type_tv.descriptor.?) != null or
                    ctx.lookupBinaryDispatch(did, type_tv.descriptor.?, type_tv.descriptor.?) != null
            else
                false;

            if (!has_method) {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            }
        }
    }
}

/// Validate deferred protocol obligations.
pub fn validateObligationsSameType(ctx: *Context) !void {
    for (ctx.protocol_obligations.items) |obligation| {
        try validateObligationSameTypeOnly(
            ctx,
            obligation.type_name,
            obligation.descriptor,
        );
    }

    ctx.protocol_obligations.clearRetainingCapacity();
}

/// Validate a single obligation, but skip any method that involves a cross-type
/// `ˀany` marker, which are left to runtime checks.
fn validateObligationSameTypeOnly(
    ctx: *Context,
    type_name: []const u8,
    descriptor: *const ProtocolDescriptor,
) !void {
    const methods_array = descriptor.methods;
    const protocol_name = descriptor.name;
    var i: usize = 0;
    while (i < methods_array.len) {
        const method_val = methods_array[i];
        const method_name = switch (method_val) {
            .symbol => |s| s,
            else => {
                helpers.setErrorContext(ctx, "protocol method entries must be symbols", .{});
                return error.TypeMismatch;
            },
        };
        i += 1;

        if (i < methods_array.len and methods_array[i] == .stack_effect) {
            const effect = methods_array[i].stack_effect;
            i += 1;

            if (isCrossTypeMethod(ctx, effect)) continue;

            try validateTypedMethod(ctx, method_name, effect, type_name, protocol_name);
        } else {
            const type_tv = ctx.lookupTypeValueByName(type_name) orelse {
                helpers.setErrorContext(ctx, "unknown type '{s}' in protocol validation", .{type_name});
                return error.TypeMismatch;
            };
            const has_method = if (ctx.resolveDispatchId(method_name)) |did|
                ctx.lookupUnaryDispatch(did, type_tv.descriptor.?) != null or
                    ctx.lookupBinaryDispatch(did, type_tv.descriptor.?, type_tv.descriptor.?) != null
            else
                false;

            if (!has_method) {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            }
        }
    }
}

/// Returns true if the stack effect has any non-self type annotation,
/// i.e., the `any` sentinel or a concrete type that is not `self`.
/// A protocol-bound input is treated as cross-type (it describes a set of
/// types rather than the implementing one), so validation defers to runtime.
fn isCrossTypeMethod(ctx: *Context, effect: StackEffect) bool {
    const n_inputs = @min(effect.inputs.len, 2);
    for (0..n_inputs) |pos| {
        if (effect.inputs[pos].type_annotation) |ann| {
            switch (ann) {
                .type => |tv| {
                    if (tv == ctx.getAnyTypeSentinel()) return true;
                    if (tv != ctx.getSelfTypeSentinel()) return true;
                },
                .protocol, .combination => return true,
            }
        }
    }
    return false;
}

/// Validate a typed method by examining the stack effect's input type annotations.
/// Substitutes `self` sentinels with the implementing type name and handles `any`
/// sentinels by enumerating dispatch entries.
fn validateTypedMethod(
    ctx: *Context,
    method_name: []const u8,
    effect: StackEffect,
    type_name: []const u8,
    protocol_name: []const u8,
) !void {
    const inputs = effect.inputs;

    // Look up the TypeValue for the implementing type
    const type_tv = ctx.lookupTypeValueByName(type_name) orelse {
        helpers.setErrorContext(ctx, "unknown type '{s}' in protocol validation", .{type_name});
        return error.TypeMismatch;
    };

    // Determine concrete TypeValues for each input position, substituting sentinels
    var has_any = false;
    var any_position: usize = 0;
    var concrete_types: [2]*const value_mod.TypeValue = .{ ctx.getDispatchUnarySentinel(), ctx.getDispatchUnarySentinel() };
    const n_inputs = @min(inputs.len, 2);

    for (0..n_inputs) |pos| {
        if (inputs[pos].type_annotation) |ann| {
            switch (ann) {
                .type => |tv| {
                    if (tv == ctx.getSelfTypeSentinel()) {
                        concrete_types[pos] = type_tv;
                    } else if (tv == ctx.getAnyTypeSentinel()) {
                        has_any = true;
                        any_position = pos;
                        concrete_types[pos] = ctx.getDispatchAnySentinel();
                    } else {
                        concrete_types[pos] = tv;
                    }
                },
                // A protocol-bound or combinator-bound input describes a set of
                // types that satisfy the constraint, not a single dispatch
                // type. Treat it as the implementing type for validation
                // purposes; the runtime check carries the real enforcement.
                .protocol, .combination => concrete_types[pos] = type_tv,
            }
        } else {
            // Unannotated input -- treat as `self`
            concrete_types[pos] = type_tv;
        }
    }

    if (n_inputs == 0 or n_inputs == 1) {
        // Unary dispatch
        const type_a = if (n_inputs == 1) concrete_types[0] else type_tv;
        if (!has_any) {
            const unary_did = ctx.resolveDispatchId(method_name) orelse {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            };
            if (ctx.lookupUnaryDispatch(unary_did, type_a.descriptor.?) == null) {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            }
        } else {
            // `any` in unary position: check that at least one entry exists
            if (!hasAnyMatchingEntry(ctx, method_name, type_tv, true, 0)) {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            }
        }
    } else {
        // Binary dispatch
        if (!has_any) {
            const binary_did = ctx.resolveDispatchId(method_name) orelse {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            };
            if (ctx.lookupBinaryDispatch(binary_did, concrete_types[0].descriptor.?, concrete_types[1].descriptor.?) == null) {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            }
        } else {
            // `any` in one position: check that at least one dispatch entry exists
            // where the non-any position matches the implementing type
            if (!hasAnyMatchingEntry(ctx, method_name, type_tv, false, any_position)) {
                throwProtocolError(ctx, type_name, method_name, protocol_name);
                return error.UserThrown;
            }
        }
    }
}

/// Check if at least one dispatch entry exists for the given method where the
/// implementing type appears in the non-any position.
fn hasAnyMatchingEntry(
    ctx: *Context,
    method_name: []const u8,
    type_tv: *const value_mod.TypeValue,
    is_unary: bool,
    any_position: usize,
) bool {
    const alloc = ctx.arena.allocator();
    const keys = ctx.dispatchKeysForWord(method_name, alloc) catch return false;
    defer alloc.free(keys);

    for (keys) |key| {
        if (is_unary) {
            if (key.type_b == ctx.getDispatchUnarySentinel().descriptor.?) {
                if (key.type_a == type_tv.descriptor.? or
                    key.type_a == ctx.getDispatchAnySentinel().descriptor.?)
                {
                    return true;
                }
            }
        } else {
            if (key.type_b == ctx.getDispatchUnarySentinel().descriptor.?) continue;
            if (any_position == 0) {
                // any is first position, self must be in second
                if (key.type_b == type_tv.descriptor.? or
                    key.type_b == ctx.getDispatchAnySentinel().descriptor.?)
                {
                    return true;
                }
            } else {
                // any is second position, self must be in first
                if (key.type_a == type_tv.descriptor.? or
                    key.type_a == ctx.getDispatchAnySentinel().descriptor.?)
                {
                    return true;
                }
            }
        }
    }
    return false;
}

/// Box a `protocol-error` carrying `message` into `ctx.thrown_error` and signal it.
/// Caller supplies the formatted message.
pub fn raiseProtocolError(ctx: *Context, message: []const u8) error{UserThrown} {
    ctx.thrown_error = value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = "protocol-error",
        .message = message,
    }) catch null;
    return error.UserThrown;
}

fn throwProtocolError(ctx: *Context, type_name: []const u8, method_name: []const u8, protocol_name: []const u8) void {
    const msg = std.fmt.allocPrint(
        ctx.arena.allocator(),
        "type '{s}' does not implement '{s}' required by protocol '{s}'",
        .{ type_name, method_name, protocol_name },
    ) catch "protocol validation failed";

    ctx.thrown_error = value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = "protocol-error",
        .message = msg,
    }) catch null;
}

const testing = std.testing;

test "typeSatisfiesConstraint over concrete-type combinators" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;
    const boolean_tv = ctx.lookupBuiltinTypeValue("boolean").?;

    const fixnum_el: value_mod.ConstraintCombinator.Element = .{ .type = fixnum_tv };
    const string_el: value_mod.ConstraintCombinator.Element = .{ .type = string_tv };

    // Bare type element.
    try testing.expect(try typeSatisfiesConstraint(&ctx, fixnum_tv, fixnum_el));
    try testing.expect(!try typeSatisfiesConstraint(&ctx, boolean_tv, fixnum_el));

    // Union: fixnum | string.
    const union_cc = try ctx.createConstraintCombinator(.@"union", &.{ fixnum_el, string_el });
    try testing.expect(try typeSatisfiesConstraint(&ctx, fixnum_tv, .{ .combinator = union_cc }));
    try testing.expect(try typeSatisfiesConstraint(&ctx, string_tv, .{ .combinator = union_cc }));
    try testing.expect(!try typeSatisfiesConstraint(&ctx, boolean_tv, .{ .combinator = union_cc }));

    // Intersection: fixnum & fixnum (inhabited) vs fixnum & string (empty).
    const inter_ok = try ctx.createConstraintCombinator(.intersection, &.{ fixnum_el, fixnum_el });
    try testing.expect(try typeSatisfiesConstraint(&ctx, fixnum_tv, .{ .combinator = inter_ok }));
    const inter_empty = try ctx.createConstraintCombinator(.intersection, &.{ fixnum_el, string_el });
    try testing.expect(!try typeSatisfiesConstraint(&ctx, fixnum_tv, .{ .combinator = inter_empty }));

    // Nested: (fixnum | string) & fixnum.
    const nested = try ctx.createConstraintCombinator(.intersection, &.{ .{ .combinator = union_cc }, fixnum_el });
    try testing.expect(try typeSatisfiesConstraint(&ctx, fixnum_tv, .{ .combinator = nested }));
    try testing.expect(!try typeSatisfiesConstraint(&ctx, string_tv, .{ .combinator = nested }));
}
