//! Context-free protocol satisfies-check core.
//!
//! The full obligation walk and its same-type-only variant live here so every runtime shell
//! shares one implementation of the memoized satisfies-check, typed-method validation, and
//! `any`-position entry enumeration. This module must stay free of `context.zig` and the hosted
//! primitive modules; everything runtime-specific arrives through the environment.
//!
//! `SatisfiesCore` is parameterized on a narrow environment type supplied by the shell. Locks,
//! dispatch frames, parent-context chains, tracing, and call frames stay in the shells, behind
//! the environment's methods. The environment must provide:
//!
//! - `resolveDispatchId(name: []const u8) ?u32`
//! - `hasUnaryDispatch(dispatch_id: u32, type_a: *const TypeDescriptor) bool`
//! - `hasBinaryDispatch(dispatch_id: u32, type_a: *const TypeDescriptor, type_b: *const TypeDescriptor) bool`
//! - `dispatchKeysForWord(name: []const u8, alloc: Allocator) anyerror![]DispatchKey`
//! - `selfTypeSentinel()`, `anyTypeSentinel()`, `dispatchUnarySentinel()`, and
//!   `dispatchAnySentinel()`, each returning `*const TypeValue`
//! - `lookupSatisfies(td: *const TypeDescriptor, pd: *const ProtocolDescriptor) ?bool` and
//!   `storeSatisfies(td, pd, value: bool) void` over the satisfies memo
//! - `typeValueByName(name: []const u8) ?*TypeValue`
//! - `scratchAllocator() Allocator` for walk-local allocations
//! - `setProtocolError(message: []const u8) void`, boxing a `protocol-error` into the runtime's
//!   thrown-error slot, and `setErrorContext(comptime fmt, args) void` for programming errors
//! - a `ThrownState` type with `saveThrown() ThrownState` and `restoreThrown(ThrownState)`, so
//!   the predicate-shaped check can probe without leaking a boxed error

const std = @import("std");

const value_mod = @import("value.zig");
const TypeValue = value_mod.TypeValue;
const ProtocolDescriptor = value_mod.ProtocolDescriptor;

const stack_effect_mod = @import("stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;

/// Check whether an actual type satisfies an expected type constraint. Supports anonymous union
/// constraints on the expected type.
pub fn typeMatchesConstraint(actual_tv: *const TypeValue, expected_tv: *const TypeValue) bool {
    if (actual_tv == expected_tv) return true;

    if (expected_tv.member_types) |members| {
        for (members) |member_tv| {
            if (typeMatchesConstraint(actual_tv, member_tv)) return true;
        }
        return false;
    }

    return false;
}

pub fn SatisfiesCore(comptime Env: type) type {
    return struct {
        /// Memoized satisfies-check: a memo hit is a single lookup; a miss runs the full
        /// obligation walk. A `UserThrown` from the walk converts to `false` with the
        /// environment's thrown state restored, so probing never leaks a boxed protocol-error.
        pub fn satisfiesByDescriptor(
            env: Env,
            type_tv: *const TypeValue,
            descriptor: *const ProtocolDescriptor,
        ) !bool {
            if (env.lookupSatisfies(type_tv.descriptor.?, descriptor)) |cached| {
                return cached;
            }

            const saved_thrown = env.saveThrown();
            if (validateProtocolObligationUncached(env, type_tv, descriptor)) |_| {
                env.storeSatisfies(type_tv.descriptor.?, descriptor, true);
                return true;
            } else |err| {
                if (err == error.UserThrown) {
                    env.restoreThrown(saved_thrown);
                    env.storeSatisfies(type_tv.descriptor.?, descriptor, false);
                    return false;
                }
                return err;
            }
        }

        /// Constraint-element recursion: intersection requires every element to be satisfied,
        /// union requires any one, nested combinators recurse. Type elements use the
        /// anonymous-union-aware match; protocol elements reuse the memoized satisfies-check.
        pub fn typeSatisfiesConstraint(
            env: Env,
            type_tv: *const TypeValue,
            element: value_mod.ConstraintCombinator.Element,
        ) anyerror!bool {
            return switch (element) {
                .type => |expected| typeMatchesConstraint(type_tv, expected),
                .protocol => |descriptor| try satisfiesByDescriptor(env, type_tv, descriptor),
                .combinator => |cc| switch (cc.kind) {
                    .intersection => {
                        for (cc.elements) |sub| {
                            if (!try typeSatisfiesConstraint(env, type_tv, sub)) return false;
                        }
                        return true;
                    },
                    .@"union" => {
                        for (cc.elements) |sub| {
                            if (try typeSatisfiesConstraint(env, type_tv, sub)) return true;
                        }
                        return false;
                    },
                },
            };
        }

        /// Same-type-only counterpart to `typeSatisfiesConstraint`. Protocol elements defer to
        /// the same-type-only descriptor check; type elements and combinator recursion behave
        /// exactly as in the full check.
        pub fn typeSatisfiesConstraintSameTypeOnly(
            env: Env,
            type_tv: *const TypeValue,
            element: value_mod.ConstraintCombinator.Element,
        ) anyerror!bool {
            return switch (element) {
                .type => |expected| typeMatchesConstraint(type_tv, expected),
                .protocol => |descriptor| try satisfiesByDescriptorSameTypeOnly(env, type_tv, descriptor),
                .combinator => |cc| switch (cc.kind) {
                    .intersection => {
                        for (cc.elements) |sub| {
                            if (!try typeSatisfiesConstraintSameTypeOnly(env, type_tv, sub)) return false;
                        }
                        return true;
                    },
                    .@"union" => {
                        for (cc.elements) |sub| {
                            if (try typeSatisfiesConstraintSameTypeOnly(env, type_tv, sub)) return true;
                        }
                        return false;
                    },
                },
            };
        }

        /// Satisfies check that only verifies same-type methods. Cross-type methods (those with
        /// `any` annotations or non-self concrete annotations) are skipped because the
        /// contributing modules may not have loaded yet; the runtime check at the call site
        /// remains authoritative for those.
        ///
        /// Returns true when every same-type method in the descriptor has a matching dispatch
        /// entry for `type_tv`, including the trivial case where the descriptor contains only
        /// cross-type methods. Never consults the satisfies memo.
        pub fn satisfiesByDescriptorSameTypeOnly(
            env: Env,
            type_tv: *const TypeValue,
            descriptor: *const ProtocolDescriptor,
        ) !bool {
            const methods_array = descriptor.methods;
            var i: usize = 0;
            while (i < methods_array.len) {
                const method_val = methods_array[i];
                const method_name = switch (method_val) {
                    .symbol => |s| s,
                    else => {
                        env.setErrorContext("protocol method entries must be symbols", .{});
                        return error.TypeMismatch;
                    },
                };
                i += 1;

                if (i < methods_array.len and methods_array[i] == .stack_effect) {
                    const effect = methods_array[i].stack_effect;
                    i += 1;
                    if (isCrossTypeMethod(env, effect)) continue;
                    if (!sameTypeMethodRegistered(env, method_name, effect, type_tv)) return false;
                } else {
                    const did = env.resolveDispatchId(method_name) orelse return false;
                    const has_method = env.hasUnaryDispatch(did, type_tv.descriptor.?) or
                        env.hasBinaryDispatch(did, type_tv.descriptor.?, type_tv.descriptor.?);
                    if (!has_method) return false;
                }
            }
            return true;
        }

        /// Check that a same-type method has a dispatch entry for `type_tv`.
        /// Caller must have verified `isCrossTypeMethod(env, effect) == false`,
        /// so every input is either unannotated or carries the `self` sentinel.
        fn sameTypeMethodRegistered(
            env: Env,
            method_name: []const u8,
            effect: StackEffect,
            type_tv: *const TypeValue,
        ) bool {
            const did = env.resolveDispatchId(method_name) orelse return false;
            const n_inputs = @min(effect.inputs.len, 2);
            if (n_inputs <= 1) {
                return env.hasUnaryDispatch(did, type_tv.descriptor.?);
            }
            return env.hasBinaryDispatch(did, type_tv.descriptor.?, type_tv.descriptor.?);
        }

        /// Memoized obligation validation for a named type. A cached success returns
        /// immediately; a cached failure deliberately re-walks so the raised protocol-error
        /// names the specific missing method.
        pub fn validateProtocolObligation(
            env: Env,
            type_name: []const u8,
            descriptor: *const ProtocolDescriptor,
        ) !void {
            const type_tv = env.typeValueByName(type_name) orelse {
                env.setErrorContext("unknown type '{s}' in protocol validation", .{type_name});
                return error.TypeMismatch;
            };

            if (env.lookupSatisfies(type_tv.descriptor.?, descriptor)) |cached| {
                if (cached) return;
                // Cached failure: re-walk to throw a method-specific protocol error.
            }

            validateProtocolObligationUncached(env, type_tv, descriptor) catch |err| {
                env.storeSatisfies(type_tv.descriptor.?, descriptor, false);
                return err;
            };
            env.storeSatisfies(type_tv.descriptor.?, descriptor, true);
        }

        /// Full satisfies-check walk. Same-type and bare methods are checked
        /// immediately; cross-type (`any`) methods are checked immediately as well
        /// (they enumerate dispatch entries).
        fn validateProtocolObligationUncached(
            env: Env,
            type_tv: *const TypeValue,
            descriptor: *const ProtocolDescriptor,
        ) !void {
            const methods_array = descriptor.methods;
            const protocol_name = descriptor.name;
            const type_name = type_tv.name;
            var i: usize = 0;
            while (i < methods_array.len) {
                const method_val = methods_array[i];
                const method_name = switch (method_val) {
                    .symbol => |s| s,
                    else => {
                        env.setErrorContext("protocol method entries must be symbols", .{});
                        return error.TypeMismatch;
                    },
                };
                i += 1;

                if (i < methods_array.len and methods_array[i] == .stack_effect) {
                    const effect = methods_array[i].stack_effect;
                    i += 1;

                    try validateTypedMethod(env, method_name, effect, type_tv, protocol_name);
                } else {
                    const has_method = if (env.resolveDispatchId(method_name)) |did|
                        env.hasUnaryDispatch(did, type_tv.descriptor.?) or
                            env.hasBinaryDispatch(did, type_tv.descriptor.?, type_tv.descriptor.?)
                    else
                        false;

                    if (!has_method) {
                        throwProtocolError(env, type_name, method_name, protocol_name);
                        return error.UserThrown;
                    }
                }
            }
        }

        /// Validate a single obligation for a named type, but skip any method that involves a
        /// cross-type `any` marker, which are left to runtime checks.
        pub fn validateObligationSameTypeOnly(
            env: Env,
            type_name: []const u8,
            descriptor: *const ProtocolDescriptor,
        ) !void {
            const methods_array = descriptor.methods;
            const protocol_name = descriptor.name;
            const type_tv = env.typeValueByName(type_name) orelse {
                env.setErrorContext("unknown type '{s}' in protocol validation", .{type_name});
                return error.TypeMismatch;
            };
            var i: usize = 0;
            while (i < methods_array.len) {
                const method_val = methods_array[i];
                const method_name = switch (method_val) {
                    .symbol => |s| s,
                    else => {
                        env.setErrorContext("protocol method entries must be symbols", .{});
                        return error.TypeMismatch;
                    },
                };
                i += 1;

                if (i < methods_array.len and methods_array[i] == .stack_effect) {
                    const effect = methods_array[i].stack_effect;
                    i += 1;

                    if (isCrossTypeMethod(env, effect)) continue;

                    try validateTypedMethod(env, method_name, effect, type_tv, protocol_name);
                } else {
                    const has_method = if (env.resolveDispatchId(method_name)) |did|
                        env.hasUnaryDispatch(did, type_tv.descriptor.?) or
                            env.hasBinaryDispatch(did, type_tv.descriptor.?, type_tv.descriptor.?)
                    else
                        false;

                    if (!has_method) {
                        throwProtocolError(env, type_name, method_name, protocol_name);
                        return error.UserThrown;
                    }
                }
            }
        }

        /// Returns true if the stack effect has any non-self type annotation,
        /// i.e., the `any` sentinel or a concrete type that is not `self`.
        /// A protocol-bound input is treated as cross-type (it describes a set of
        /// types rather than the implementing one), so validation defers to runtime.
        fn isCrossTypeMethod(env: Env, effect: StackEffect) bool {
            const n_inputs = @min(effect.inputs.len, 2);
            for (0..n_inputs) |pos| {
                if (effect.inputs[pos].type_annotation) |ann| {
                    switch (ann) {
                        .type => |tv| {
                            if (tv == env.anyTypeSentinel()) return true;
                            if (tv != env.selfTypeSentinel()) return true;
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
            env: Env,
            method_name: []const u8,
            effect: StackEffect,
            type_tv: *const TypeValue,
            protocol_name: []const u8,
        ) !void {
            const inputs = effect.inputs;
            const type_name = type_tv.name;

            // Determine concrete TypeValues for each input position, substituting sentinels
            var has_any = false;
            var any_position: usize = 0;
            var concrete_types: [2]*const TypeValue = .{ env.dispatchUnarySentinel(), env.dispatchUnarySentinel() };
            const n_inputs = @min(inputs.len, 2);

            for (0..n_inputs) |pos| {
                if (inputs[pos].type_annotation) |ann| {
                    switch (ann) {
                        .type => |tv| {
                            if (tv == env.selfTypeSentinel()) {
                                concrete_types[pos] = type_tv;
                            } else if (tv == env.anyTypeSentinel()) {
                                has_any = true;
                                any_position = pos;
                                concrete_types[pos] = env.dispatchAnySentinel();
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
                    const unary_did = env.resolveDispatchId(method_name) orelse {
                        throwProtocolError(env, type_name, method_name, protocol_name);
                        return error.UserThrown;
                    };
                    if (!env.hasUnaryDispatch(unary_did, type_a.descriptor.?)) {
                        throwProtocolError(env, type_name, method_name, protocol_name);
                        return error.UserThrown;
                    }
                } else {
                    // `any` in unary position: check that at least one entry exists
                    if (!hasAnyMatchingEntry(env, method_name, type_tv, true, 0)) {
                        throwProtocolError(env, type_name, method_name, protocol_name);
                        return error.UserThrown;
                    }
                }
            } else {
                // Binary dispatch
                if (!has_any) {
                    const binary_did = env.resolveDispatchId(method_name) orelse {
                        throwProtocolError(env, type_name, method_name, protocol_name);
                        return error.UserThrown;
                    };
                    if (!env.hasBinaryDispatch(binary_did, concrete_types[0].descriptor.?, concrete_types[1].descriptor.?)) {
                        throwProtocolError(env, type_name, method_name, protocol_name);
                        return error.UserThrown;
                    }
                } else {
                    // `any` in one position: check that at least one dispatch entry exists
                    // where the non-any position matches the implementing type
                    if (!hasAnyMatchingEntry(env, method_name, type_tv, false, any_position)) {
                        throwProtocolError(env, type_name, method_name, protocol_name);
                        return error.UserThrown;
                    }
                }
            }
        }

        /// Check if at least one dispatch entry exists for the given method where the
        /// implementing type appears in the non-any position.
        fn hasAnyMatchingEntry(
            env: Env,
            method_name: []const u8,
            type_tv: *const TypeValue,
            is_unary: bool,
            any_position: usize,
        ) bool {
            const alloc = env.scratchAllocator();
            const keys = env.dispatchKeysForWord(method_name, alloc) catch return false;
            defer alloc.free(keys);

            for (keys) |key| {
                if (is_unary) {
                    if (key.type_b == env.dispatchUnarySentinel().descriptor.?) {
                        if (key.type_a == type_tv.descriptor.? or
                            key.type_a == env.dispatchAnySentinel().descriptor.?)
                        {
                            return true;
                        }
                    }
                } else {
                    if (key.type_b == env.dispatchUnarySentinel().descriptor.?) continue;
                    if (any_position == 0) {
                        // any is first position, self must be in second
                        if (key.type_b == type_tv.descriptor.? or
                            key.type_b == env.dispatchAnySentinel().descriptor.?)
                        {
                            return true;
                        }
                    } else {
                        // any is second position, self must be in first
                        if (key.type_a == type_tv.descriptor.? or
                            key.type_a == env.dispatchAnySentinel().descriptor.?)
                        {
                            return true;
                        }
                    }
                }
            }
            return false;
        }

        /// Format the missing-method message and box it through the environment's error sink.
        /// The format string lives here so every runtime produces identical diagnostics.
        fn throwProtocolError(env: Env, type_name: []const u8, method_name: []const u8, protocol_name: []const u8) void {
            const msg = std.fmt.allocPrint(
                env.scratchAllocator(),
                "type '{s}' does not implement '{s}' required by protocol '{s}'",
                .{ type_name, method_name, protocol_name },
            ) catch "protocol validation failed";

            env.setProtocolError(msg);
        }
    };
}
