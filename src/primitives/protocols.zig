const std = @import("std");

const context_mod = @import("../context.zig");
const Context = context_mod.Context;
const obligation_sink_mod = @import("../obligation_sink.zig");
const ObligationSink = obligation_sink_mod.ObligationSink;

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
const satisfies_core = @import("../satisfies_core.zig");

const helpers = @import("helpers.zig");

const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;

pub const primitives = [_]Primitive{
    .{ .name = "define-protocol", .stack_effect = "name: descriptor markers --", .doc = "Define a protocol word that validates a type implements all required methods.", .func = nativeDefineProtocol, .defines_word = true },
    .{ .name = "assert-satisfies", .stack_effect = "type-sym constraint --", .doc = "Throws a protocol-error if the named type does not satisfy the given protocol constraint.", .func = protocolCheckHelper },
    .{ .name = "satisfies?", .stack_effect = "type-sym constraint -- ?", .doc = "Returns t if the named type satisfies the protocol constraint, f otherwise.", .func = nativeSatisfies },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "protocol-check", .func = protocolCheckHelper, .stack_effect = "type-name descriptor --" },
};

/// Hosted environment for the shared satisfies core. Each method delegates to the locked
/// `Context` accessor, so dispatch-frame overlays, the parent-context chain, and memo locking
/// all stay behind this boundary.
const HostedEnv = struct {
    ctx: *Context,

    pub const ThrownState = ?*value_mod.ErrorObject;

    pub fn resolveDispatchId(self: HostedEnv, name: []const u8) ?u32 {
        return self.ctx.resolveDispatchId(name);
    }

    pub fn hasUnaryDispatch(self: HostedEnv, dispatch_id: u32, type_a: *const value_mod.TypeDescriptor) bool {
        return self.ctx.lookupUnaryDispatch(dispatch_id, type_a) != null;
    }

    pub fn hasBinaryDispatch(self: HostedEnv, dispatch_id: u32, type_a: *const value_mod.TypeDescriptor, type_b: *const value_mod.TypeDescriptor) bool {
        return self.ctx.lookupBinaryDispatch(dispatch_id, type_a, type_b) != null;
    }

    pub fn dispatchKeysForWord(self: HostedEnv, name: []const u8, alloc: std.mem.Allocator) anyerror![]dispatch_mod.DispatchKey {
        return self.ctx.dispatchKeysForWord(name, alloc);
    }

    pub fn selfTypeSentinel(self: HostedEnv) *const value_mod.TypeValue {
        return self.ctx.getSelfTypeSentinel();
    }

    pub fn anyTypeSentinel(self: HostedEnv) *const value_mod.TypeValue {
        return self.ctx.getAnyTypeSentinel();
    }

    pub fn dispatchUnarySentinel(self: HostedEnv) *const value_mod.TypeValue {
        return self.ctx.getDispatchUnarySentinel();
    }

    pub fn dispatchAnySentinel(self: HostedEnv) *const value_mod.TypeValue {
        return self.ctx.getDispatchAnySentinel();
    }

    pub fn lookupSatisfies(self: HostedEnv, td: *const value_mod.TypeDescriptor, pd: *const ProtocolDescriptor) ?bool {
        return self.ctx.lookupProtocolSatisfies(.{ .type_descriptor = td, .protocol_descriptor = pd });
    }

    pub fn storeSatisfies(self: HostedEnv, td: *const value_mod.TypeDescriptor, pd: *const ProtocolDescriptor, value: bool) void {
        self.ctx.storeProtocolSatisfies(.{ .type_descriptor = td, .protocol_descriptor = pd }, value);
    }

    pub fn typeValueByName(self: HostedEnv, name: []const u8) ?*value_mod.TypeValue {
        return self.ctx.lookupTypeValueByName(name);
    }

    pub fn scratchAllocator(self: HostedEnv) std.mem.Allocator {
        return self.ctx.arena.allocator();
    }

    pub fn setProtocolError(self: HostedEnv, message: []const u8) void {
        self.ctx.thrown_error = value_mod.boxErrorObject(self.ctx.quotationAllocator(), .{
            .error_type = "protocol-error",
            .message = message,
        }) catch null;
    }

    pub fn setErrorContext(self: HostedEnv, comptime fmt: []const u8, args: anytype) void {
        helpers.setErrorContext(self.ctx, fmt, args);
    }

    pub fn saveThrown(self: HostedEnv) ThrownState {
        return self.ctx.thrown_error;
    }

    pub fn restoreThrown(self: HostedEnv, state: ThrownState) void {
        self.ctx.thrown_error = state;
    }
};

const Core = satisfies_core.SatisfiesCore(HostedEnv);

fn hostedEnv(ctx: *Context) HostedEnv {
    return .{ .ctx = ctx };
}

/// define-protocol ( name: descriptor markers -- )
///
/// Called by `;` when it recognizes a protocol descriptor. The protocol word itself is just a
/// handle factory; runtime validation happens in `assert-satisfies`. The parse-time descriptor is
/// a mutable-map whose `methods:` field is a flat array of symbols interleaved with optional
/// stack-effects.
fn nativeDefineProtocol(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const markers_val = try ctx.stack.pop();
    defer container_backing.releaseValue(markers_val);
    _ = switch (markers_val) {
        .array => |arr| arr.items,
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
        .array => |arr| arr.items,
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
    // createProtocolDescriptor dupes the name, so the popped symbol releases here.
    defer container_backing.releaseValue(name_val);
    const protocol_name = switch (name_val) {
        .symbol => |s| s.bytes,
        else => {
            helpers.setTypeMismatchError(ctx, "symbol", name_val);
            return error.TypeMismatch;
        },
    };

    // The protocol word below is generated by this declaration, so it records the declaration
    // site rather than the prelude quotation that ran this native.
    const saved_src_loc = ctx.generated_src_loc;
    defer ctx.generated_src_loc = saved_src_loc;
    ctx.generated_src_loc = try helpers.genSrcLocFrom(alloc, desc_map.map.get("src-loc"));

    const descriptor = try ctx.createProtocolDescriptor(protocol_name, methods_array);

    const instrs = try alloc.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .push_literal = .{ .protocol_descriptor = descriptor } }, .line = 0 };

    const word_markers = try alloc.alloc(*Marker, 2);
    word_markers[0] = @constCast(&markers_mod.parse_time_marker);
    word_markers[1] = @constCast(&markers_mod.const_marker);

    // The dictionary borrows its key, so key the word on the descriptor's
    // duped copy of the name rather than the released payload's bytes.
    try ctx.defineWord(descriptor.name, .{
        .name = descriptor.name,
        .parse_time = true,
        .markers = word_markers,
        .provenance = .{ .generator = "protocol", .parent = descriptor.name, .role = "constraint" },
        .action = .{ .compound = instrs },
    });
}

/// How `protocolCheckHelper` handles one obligation.
const Route = enum {
    /// Recorded in the open sink. The load's drain validates it.
    deferred,
    /// The sink closed before the obligation could land. Check same-type methods only, the way
    /// the drain would have.
    same_type_only,
    /// Check now, in full, with no deferral in play.
    full,
    /// Check now, in full. The constraint or the type was created inside a task, so no drain
    /// could have resolved it.
    full_task_origin,
};

/// Decide whether an obligation defers to the load's sink.
///
/// A context with no sink checks in full. With a sink, the obligation defers only when the
/// constraint is durable and the type does not live on a task arena. A type that does not resolve
/// yet defers, because the module may still define it.
///
/// A closed sink means the load has already drained. Every method the module registers is in
/// place by then, so the obligation gets the drain's same-type-only check. The result then does
/// not depend on which side of the drain the task ran on.
fn routeObligation(
    ctx: *Context,
    type_name: []const u8,
    constraint: obligation_sink_mod.Obligation.Constraint,
    durable: bool,
) !Route {
    const sink = ctx.obligation_sink orelse return .full;

    if (!durable) return .full_task_origin;
    if (typeOnTaskArena(ctx, type_name)) return .full_task_origin;

    if (try sink.append(type_name, constraint)) return .deferred;
    return .same_type_only;
}

fn typeOnTaskArena(ctx: *Context, type_name: []const u8) bool {
    const type_tv = ctx.lookupTypeValueByName(type_name) orelse return false;
    const desc = type_tv.descriptor orelse return false;
    return ctx.typeIsOnTaskArena(desc);
}

/// Add the task origin to a protocol-error already raised by a full check. Other errors pass
/// through untouched.
fn noteTaskOrigin(ctx: *Context, err: anyerror) anyerror {
    if (err != error.UserThrown) return err;

    const thrown = ctx.thrown_error orelse return err;
    if (!std.mem.eql(u8, thrown.error_type, "protocol-error")) return err;

    const message = std.fmt.allocPrint(
        ctx.quotationAllocator(),
        "{s}. The constraint or the type was created inside a task, so the load could not check it",
        .{thrown.message},
    ) catch return err;

    return raiseProtocolError(ctx, message);
}

/// Trampoline helper ( type-name descriptor -- )
///
/// Backs both `assert-satisfies` and the `protocol-check` registry entry. Dispatches a popped
/// constraint (protocol descriptor or combinator) to an immediate check, or defers it as a
/// protocol obligation while a module is still loading.
fn protocolCheckHelper(ctx: *Context) anyerror!void {
    const desc_val = try ctx.stack.pop();
    defer container_backing.releaseValue(desc_val);
    const name_val = try ctx.stack.pop();
    defer container_backing.releaseValue(name_val);
    const type_name = switch (name_val) {
        .symbol => |s| s.bytes,
        else => {
            helpers.setErrorContext(ctx, "protocol validation expects a type name (symbol) on the stack", .{});
            return error.TypeMismatch;
        },
    };

    switch (desc_val) {
        .protocol_descriptor => |descriptor| {
            const route = try routeObligation(ctx, type_name, .{ .protocol = descriptor }, descriptor.durable);
            switch (route) {
                .deferred => {},
                .same_type_only => try Core.validateObligationSameTypeOnly(hostedEnv(ctx), type_name, descriptor),
                .full => try validateProtocolObligation(ctx, type_name, descriptor),
                .full_task_origin => validateProtocolObligation(ctx, type_name, descriptor) catch |err| {
                    return noteTaskOrigin(ctx, err);
                },
            }
        },
        .constraint_combinator => |cc| {
            const route = try routeObligation(ctx, type_name, .{ .combination = cc }, cc.durable);
            switch (route) {
                .deferred => {},
                .same_type_only => try validateCombinatorObligationSameTypeOnly(ctx, type_name, cc),
                .full => try validateCombinatorObligation(ctx, type_name, cc),
                .full_task_origin => validateCombinatorObligation(ctx, type_name, cc) catch |err| {
                    return noteTaskOrigin(ctx, err);
                },
            }
        },
        else => {
            helpers.setTypeMismatchError(ctx, "constraint", desc_val);
            return error.TypeMismatch;
        },
    }
}

/// satisfies? ( type-sym constraint -- ? )
///
/// Predicate companion to `assert-satisfies`: returns a boolean instead of throwing.
/// Shares the per-`Context` satisfies memo populated by `assert-satisfies`, so the
/// steady-state path is a single hash lookup either way.
fn nativeSatisfies(ctx: *Context) anyerror!void {
    const desc_val = try ctx.stack.pop();
    defer container_backing.releaseValue(desc_val);
    const name_val = try ctx.stack.pop();
    defer container_backing.releaseValue(name_val);
    const type_name = switch (name_val) {
        .symbol => |s| s.bytes,
        else => {
            helpers.setErrorContext(ctx, "satisfies? expects a type name (symbol) on the stack", .{});
            return error.TypeMismatch;
        },
    };

    const result = try constraintSatisfied(ctx, type_name, desc_val);
    try ctx.stack.push(.{ .boolean = result });
}

/// Full satisfies-check for a popped constraint value (`ProtocolDescriptor` or
/// `ConstraintCombinator`) against a named type.
fn constraintSatisfied(ctx: *Context, type_name: []const u8, desc_val: Value) !bool {
    switch (desc_val) {
        .protocol_descriptor => |descriptor| return checkProtocolObligation(ctx, type_name, descriptor),
        .constraint_combinator => |cc| {
            const type_tv = ctx.lookupTypeValueByName(type_name) orelse {
                helpers.setErrorContext(ctx, "unknown type '{s}' in protocol validation", .{type_name});
                return error.TypeMismatch;
            };
            return typeSatisfiesConstraint(ctx, type_tv, .{ .combinator = cc });
        },
        else => {
            helpers.setTypeMismatchError(ctx, "constraint", desc_val);
            return error.TypeMismatch;
        },
    }
}

/// Predicate-shaped variant of `validateProtocolObligation` for a named type.
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
    return Core.satisfiesByDescriptor(hostedEnv(ctx), type_tv, descriptor);
}

/// Check whether a resolved type satisfies a constraint element: a concrete
/// type, a protocol bound, or a combinator.
pub fn typeSatisfiesConstraint(
    ctx: *Context,
    type_tv: *const value_mod.TypeValue,
    element: value_mod.ConstraintCombinator.Element,
) anyerror!bool {
    return Core.typeSatisfiesConstraint(hostedEnv(ctx), type_tv, element);
}

/// Same-type-only counterpart to `typeSatisfiesConstraint`, used by the
/// module-load deferral. Cross-type (`any`-marked) methods are skipped and
/// left to the runtime call-site check. This keeps a top-level combinator
/// `assert-satisfies` consistent with how a bare-protocol `assert-satisfies`
/// already treats cross-type methods at load time.
pub fn typeSatisfiesConstraintSameTypeOnly(
    ctx: *Context,
    type_tv: *const value_mod.TypeValue,
    element: value_mod.ConstraintCombinator.Element,
) anyerror!bool {
    return Core.typeSatisfiesConstraintSameTypeOnly(hostedEnv(ctx), type_tv, element);
}

/// Runtime validation of a combinator obligation: full check, raising
/// `protocol-error` if the type does not satisfy the combinator.
fn validateCombinatorObligation(
    ctx: *Context,
    type_name: []const u8,
    cc: *const value_mod.ConstraintCombinator,
) !void {
    const type_tv = ctx.lookupTypeValueByName(type_name) orelse {
        helpers.setErrorContext(ctx, "unknown type '{s}' in protocol validation", .{type_name});
        return error.TypeMismatch;
    };
    if (!try typeSatisfiesConstraint(ctx, type_tv, .{ .combinator = cc })) {
        return raiseCombinatorError(ctx, type_name);
    }
}

/// Module-load validation of a deferred combinator obligation: same-type-only,
/// skipping cross-type methods inside protocol elements.
fn validateCombinatorObligationSameTypeOnly(
    ctx: *Context,
    type_name: []const u8,
    cc: *const value_mod.ConstraintCombinator,
) !void {
    const type_tv = ctx.lookupTypeValueByName(type_name) orelse {
        helpers.setErrorContext(ctx, "unknown type '{s}' in protocol validation", .{type_name});
        return error.TypeMismatch;
    };
    if (!try typeSatisfiesConstraintSameTypeOnly(ctx, type_tv, .{ .combinator = cc })) {
        return raiseCombinatorError(ctx, type_name);
    }
}

/// Raise a `protocol-error` for a type that fails a combinator constraint. The
/// combinator is anonymous from the descriptor's view, so the message names the
/// type rather than a single protocol.
pub fn raiseCombinatorError(ctx: *Context, type_name: []const u8) error{UserThrown} {
    const msg = std.fmt.allocPrint(
        ctx.arena.allocator(),
        "type '{s}' does not satisfy the required constraint",
        .{type_name},
    ) catch "protocol validation failed";
    return raiseProtocolError(ctx, msg);
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
/// Cross-type methods are skipped because the contributing modules may not
/// have loaded yet; the runtime check at the call site remains authoritative
/// for those.
pub fn satisfiesByDescriptorSameTypeOnly(
    ctx: *Context,
    type_tv: *const value_mod.TypeValue,
    descriptor: *const ProtocolDescriptor,
) !bool {
    return Core.satisfiesByDescriptorSameTypeOnly(hostedEnv(ctx), type_tv, descriptor);
}

/// Validate a single protocol obligation: check that all required methods
/// are registered in the dispatch table. The steady-state path is a single
/// memo lookup. Coarse invalidation in `registerDispatchLocked` /
/// `popDispatchFrameLocked` keeps the memo honest across REPL definitions
/// and runtime module loads.
pub fn validateProtocolObligation(
    ctx: *Context,
    type_name: []const u8,
    descriptor: *const ProtocolDescriptor,
) !void {
    return Core.validateProtocolObligation(hostedEnv(ctx), type_name, descriptor);
}

/// Validate the obligations taken from a closed sink. The caller frees `pending`.
pub fn validateObligationsSameType(ctx: *Context, pending: *const ObligationSink.Pending) !void {
    var cursor = pending.head;
    while (cursor) |entry| : (cursor = entry.next) {
        const obligation = entry.obligation;
        switch (obligation.constraint) {
            .protocol => |descriptor| try Core.validateObligationSameTypeOnly(
                hostedEnv(ctx),
                obligation.type_name,
                descriptor,
            ),
            .combination => |cc| try validateCombinatorObligationSameTypeOnly(
                ctx,
                obligation.type_name,
                cc,
            ),
        }
    }
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

test "typeSatisfiesConstraintSameTypeOnly skips cross-type methods at load time" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;

    // A protocol whose only method is cross-type (`b: any`). No dispatch entry
    // is ever registered, so the full check rejects it while the same-type-only
    // check skips it and defers to the runtime call-site check.
    const inputs = [_]stack_effect_mod.StackEffectParam{
        .{ .name = "a", .type_annotation = .{ .type = ctx.getSelfTypeSentinel() } },
        .{ .name = "b", .type_annotation = .{ .type = ctx.getAnyTypeSentinel() } },
    };
    const outputs = [_]stack_effect_mod.StackEffectParam{.{ .name = "result" }};
    const effect = StackEffect{ .inputs = &inputs, .outputs = &outputs };
    const methods = [_]Value{ value_mod.symbolValue("scale-by"), .{ .stack_effect = effect } };
    const scaleable = try ctx.createProtocolDescriptor("scaleable", &methods);

    const proto_el: value_mod.ConstraintCombinator.Element = .{ .protocol = scaleable };

    // The bare protocol element: full rejects, same-type-only accepts.
    try testing.expect(!try typeSatisfiesConstraint(&ctx, fixnum_tv, proto_el));
    try testing.expect(try typeSatisfiesConstraintSameTypeOnly(&ctx, fixnum_tv, proto_el));

    // The skip propagates through intersection recursion: a satisfiable type
    // element alongside the deferred protocol passes under same-type-only.
    const fixnum_el: value_mod.ConstraintCombinator.Element = .{ .type = fixnum_tv };
    const inter = try ctx.createConstraintCombinator(.intersection, &.{ proto_el, fixnum_el });
    try testing.expect(try typeSatisfiesConstraintSameTypeOnly(&ctx, fixnum_tv, .{ .combinator = inter }));
    try testing.expect(!try typeSatisfiesConstraint(&ctx, fixnum_tv, .{ .combinator = inter }));

    // A type element the type genuinely fails still fails under same-type-only,
    // so the deferral does not mask non-protocol mismatches.
    const string_el: value_mod.ConstraintCombinator.Element = .{ .type = string_tv };
    const inter_fail = try ctx.createConstraintCombinator(.intersection, &.{ proto_el, string_el });
    try testing.expect(!try typeSatisfiesConstraintSameTypeOnly(&ctx, fixnum_tv, .{ .combinator = inter_fail }));
}

test "routeObligation: defers to an open sink, then checks same-type only once it closes" {
    var root = Context.init(testing.allocator);
    defer root.deinit();

    const durable: ProtocolDescriptor = .{ .name = "p", .methods = &.{}, .protocol_id = 0, .durable = true };

    try testing.expectEqual(Route.full, try routeObligation(&root, "fixnum", .{ .protocol = &durable }, true));

    const scope = try root.enterObligationSink();
    defer root.leaveObligationSink(scope);

    var child = try Context.initChild(testing.allocator, &root, .task);
    defer child.deinit();

    const constraint: obligation_sink_mod.Obligation.Constraint = .{ .protocol = &durable };
    try testing.expectEqual(Route.deferred, try routeObligation(&child, "fixnum", constraint, true));
    try testing.expectEqual(Route.deferred, try routeObligation(&child, "not-defined-yet", constraint, true));
    try testing.expectEqual(Route.full_task_origin, try routeObligation(&child, "fixnum", constraint, false));

    scope.sink.discard();
    try testing.expectEqual(Route.same_type_only, try routeObligation(&child, "fixnum", constraint, true));
    try testing.expectEqual(Route.full_task_origin, try routeObligation(&child, "fixnum", constraint, false));
}

test "a closed sink checks same-type methods only and leaves the satisfies memo alone" {
    var root = Context.init(testing.allocator);
    defer root.deinit();

    const inputs = [_]stack_effect_mod.StackEffectParam{
        .{ .name = "a", .type_annotation = .{ .type = root.getSelfTypeSentinel() } },
        .{ .name = "b", .type_annotation = .{ .type = root.getAnyTypeSentinel() } },
    };
    const outputs = [_]stack_effect_mod.StackEffectParam{.{ .name = "result" }};
    const effect = StackEffect{ .inputs = &inputs, .outputs = &outputs };
    const methods = [_]Value{ value_mod.symbolValue("scale-by"), .{ .stack_effect = effect } };
    const scaleable = try root.createProtocolDescriptor("scaleable", &methods);

    const scope = try root.enterObligationSink();
    defer root.leaveObligationSink(scope);

    var child = try Context.initChild(testing.allocator, &root, .task);
    defer child.deinit();

    scope.sink.discard();

    try child.stack.push(value_mod.symbolValue("fixnum"));
    try child.stack.push(.{ .protocol_descriptor = scaleable });
    try protocolCheckHelper(&child);

    const fixnum_tv = root.lookupBuiltinTypeValue("fixnum").?;
    try testing.expect(child.lookupProtocolSatisfies(.{
        .type_descriptor = fixnum_tv.descriptor.?,
        .protocol_descriptor = scaleable,
    }) == null);

    try testing.expect(!try satisfiesByDescriptor(&child, fixnum_tv, scaleable));
}

test "children appending while the loader drains lose no obligation" {
    var root = Context.init(testing.allocator);
    defer root.deinit();

    const scope = try root.enterObligationSink();
    defer root.leaveObligationSink(scope);

    const worker_count = 3;
    const rounds = 300;

    var children: [worker_count]Context = undefined;
    var made: usize = 0;
    defer for (children[0..made]) |*child| child.deinit();
    while (made < worker_count) : (made += 1) {
        children[made] = try Context.initChild(testing.allocator, &root, .task);
    }

    const durable: ProtocolDescriptor = .{ .name = "p", .methods = &.{}, .protocol_id = 0, .durable = true };

    const Worker = struct {
        fn run(
            child: *Context,
            descriptor: *const ProtocolDescriptor,
            deferred: *std.atomic.Value(u32),
            eager: *std.atomic.Value(u32),
        ) void {
            var i: usize = 0;
            while (i < rounds) : (i += 1) {
                const route = routeObligation(child, "fixnum", .{ .protocol = descriptor }, true) catch return;
                switch (route) {
                    .deferred => _ = deferred.fetchAdd(1, .monotonic),
                    .same_type_only => _ = eager.fetchAdd(1, .monotonic),
                    else => return,
                }
            }
        }
    };

    var deferred = std.atomic.Value(u32).init(0);
    var eager = std.atomic.Value(u32).init(0);
    var threads: [worker_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &children[i], &durable, &deferred, &eager });
    }

    var pending = scope.sink.takeAndClose();
    for (threads) |thread| thread.join();

    var drained: u32 = 0;
    var cursor = pending.head;
    while (cursor) |entry| : (cursor = entry.next) drained += 1;
    pending.deinit();

    try testing.expectEqual(deferred.load(.monotonic), drained);
    try testing.expectEqual(@as(u32, worker_count * rounds), deferred.load(.monotonic) + eager.load(.monotonic));
    scope.sink.assertClosedAndEmpty();
}
