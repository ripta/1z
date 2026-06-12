//! Static analysis of constraint combinators (`&` intersection / `|` union).
//!
//! A combinator expression can describe a constraint no value can ever satisfy
//! (`fixnum & string`) or one that carries a superfluous bound (`fixnum &
//! fixnum`). This module decides which, so the parser can reject the impossible
//! shapes and warn on the redundant ones. The decision is made from the
//! descriptors in hand; cases that depend on protocol method registrations not
//! yet loaded defer to the runtime satisfies-check by reporting `.unknown`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("value.zig");
const Context = @import("context.zig").Context;
const helpers = @import("primitives/helpers.zig");

const Element = value_mod.ConstraintCombinator.Element;

/// Whether some value can satisfy a constraint. `.uninhabited` is the only
/// verdict that drives an error or a dropped subterm; `.inhabited` and
/// `.unknown` both mean "keep it" and differ only in whether the analyzer
/// reached a positive conclusion or merely could not refute the constraint.
pub const Verdict = enum { inhabited, uninhabited, unknown };

pub const Result = struct {
    verdict: Verdict,
    /// For `.uninhabited`, a description of the conflict allocated with the
    /// analysis allocator. Null otherwise.
    reason: ?[]const u8 = null,
};

fn isAny(ctx: *Context, tv: *const value_mod.TypeValue) bool {
    return tv == ctx.getAnyTypeSentinel();
}

fn isSelf(ctx: *Context, tv: *const value_mod.TypeValue) bool {
    return tv == ctx.getSelfTypeSentinel();
}

fn elementName(e: Element) []const u8 {
    return switch (e) {
        .type => |t| t.name,
        .protocol => |p| p.name,
        .combinator => "<constraint>",
    };
}

/// Emit a transient redundancy / dead-subterm warning to stderr.
fn warn(ctx: *Context, allocator: Allocator, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(msg);
    ctx.emitConstraintWarning(msg);
}

/// Analyze an intersection's element list. Reports `.uninhabited` (with a
/// reason) when no value can satisfy every element, `.inhabited` when the bounds
/// are jointly satisfiable, or `.unknown` when the decision depends on
/// registrations not yet loaded or on bounds this analyzer does not reason
/// about. Redundancy warnings are emitted as a side effect.
pub fn analyzeIntersection(
    ctx: *Context,
    allocator: Allocator,
    elements: []const Element,
) anyerror!Result {
    var has_unknown = false;

    // 1. Type-vs-type. Two distinct concrete types can never coexist on one
    //    value (cases 1, 6, 7); a type that subsumes or equals another makes the
    //    wider bound redundant (cases 2, and a type narrower than a union).
    var i: usize = 0;
    while (i < elements.len) : (i += 1) {
        const a = switch (elements[i]) {
            .type => |t| t,
            else => continue,
        };
        if (isAny(ctx, a)) {
            warn(ctx, allocator, "redundant constraint: 'any' adds no bound to the intersection", .{});
            continue;
        }
        if (isSelf(ctx, a)) {
            has_unknown = true;
            continue;
        }
        var j: usize = i + 1;
        while (j < elements.len) : (j += 1) {
            const b = switch (elements[j]) {
                .type => |t| t,
                else => continue,
            };
            if (isAny(ctx, b) or isSelf(ctx, b)) continue;

            const a_in_b = helpers.typeMatchesConstraint(a, b);
            const b_in_a = helpers.typeMatchesConstraint(b, a);
            if (a_in_b or b_in_a) {
                warn(ctx, allocator, "redundant constraint: '{s}' and '{s}' overlap in the intersection; the narrower bound suffices", .{ a.name, b.name });
                continue;
            }
            // Disjoint bounds. Decidable as uninhabited when at least one side is
            // a concrete (non-union) type. Two unions with no subset relation may
            // still share a member, so leave that undecided to avoid a false
            // positive on a non-empty meet.
            if (a.member_types == null or b.member_types == null) {
                return .{
                    .verdict = .uninhabited,
                    .reason = try std.fmt.allocPrint(allocator, "no value is both '{s}' and '{s}'", .{ a.name, b.name }),
                };
            }
            has_unknown = true;
        }
    }

    // 2. Concrete-type-vs-protocol / nested combinator (cases 3, 4). A concrete
    //    type either already satisfies the bound (redundant) or can never satisfy
    //    it (uninhabited). The decision needs the method registrations, so it is
    //    deferred to runtime during a module load.
    var has_protocol = false;
    var has_concrete = false;
    for (elements) |e| {
        switch (e) {
            .protocol, .combinator => has_protocol = true,
            .type => |t| {
                if (!isAny(ctx, t) and !isSelf(ctx, t) and t.member_types == null and t.descriptor != null) {
                    has_concrete = true;
                }
            },
        }
    }

    if (ctx.in_module_load) {
        if (has_protocol) has_unknown = true;
    } else {
        for (elements) |te| {
            const t = switch (te) {
                .type => |tv| tv,
                else => continue,
            };
            if (isAny(ctx, t) or isSelf(ctx, t)) continue;
            if (t.member_types != null or t.descriptor == null) continue;
            for (elements) |pe| {
                switch (pe) {
                    .protocol, .combinator => {},
                    .type => continue,
                }
                const sat = ctx.constraintTypeSatisfies(t, pe) catch {
                    has_unknown = true;
                    continue;
                };
                if (sat) {
                    warn(ctx, allocator, "redundant constraint: '{s}' already satisfies '{s}'", .{ t.name, elementName(pe) });
                } else {
                    return .{
                        .verdict = .uninhabited,
                        .reason = try std.fmt.allocPrint(allocator, "'{s}' cannot satisfy '{s}'", .{ t.name, elementName(pe) }),
                    };
                }
            }
        }
        // A protocol bound with no concrete type to pin it against (`comparable &
        // stringable`) is undecidable: any future type may satisfy both.
        if (has_protocol and !has_concrete) has_unknown = true;
    }

    if (has_unknown) return .{ .verdict = .unknown };
    return .{ .verdict = .inhabited };
}

const testing = std.testing;

fn builtinElement(ctx: *Context, name: []const u8) Element {
    return .{ .type = ctx.lookupBuiltinTypeValue(name).? };
}

test "distinct concrete types under & are uninhabited" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const elements = [_]Element{ builtinElement(&ctx, "fixnum"), builtinElement(&ctx, "string") };
    const res = try analyzeIntersection(&ctx, testing.allocator, &elements);
    defer if (res.reason) |r| testing.allocator.free(r);
    try testing.expectEqual(Verdict.uninhabited, res.verdict);
}

test "same concrete type repeated under & is redundant but inhabited" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const elements = [_]Element{ builtinElement(&ctx, "fixnum"), builtinElement(&ctx, "fixnum") };
    const res = try analyzeIntersection(&ctx, testing.allocator, &elements);
    try testing.expectEqual(Verdict.inhabited, res.verdict);
}

test "concrete type & union excluding it is uninhabited" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const string_tv = ctx.lookupBuiltinTypeValue("string").?;
    const boolean_tv = ctx.lookupBuiltinTypeValue("boolean").?;
    const sb = try ctx.getOrCreateAnonymousUnionTypeValue(&.{ string_tv, boolean_tv });

    const elements = [_]Element{ builtinElement(&ctx, "fixnum"), .{ .type = sb } };
    const res = try analyzeIntersection(&ctx, testing.allocator, &elements);
    defer if (res.reason) |r| testing.allocator.free(r);
    try testing.expectEqual(Verdict.uninhabited, res.verdict);
}

test "concrete type & union including it is redundant but inhabited" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;
    const fs = try ctx.getOrCreateAnonymousUnionTypeValue(&.{ fixnum_tv, string_tv });

    const elements = [_]Element{ .{ .type = fixnum_tv }, .{ .type = fs } };
    const res = try analyzeIntersection(&ctx, testing.allocator, &elements);
    try testing.expectEqual(Verdict.inhabited, res.verdict);
}

test "two protocols under & cannot be decided" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    var p1 = value_mod.ProtocolDescriptor{ .name = "p1", .methods = &.{}, .protocol_id = 0 };
    var p2 = value_mod.ProtocolDescriptor{ .name = "p2", .methods = &.{}, .protocol_id = 1 };
    const elements = [_]Element{ .{ .protocol = &p1 }, .{ .protocol = &p2 } };
    const res = try analyzeIntersection(&ctx, testing.allocator, &elements);
    try testing.expectEqual(Verdict.unknown, res.verdict);
}

test "type & protocol is deferred to runtime during a module load" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    var p1 = value_mod.ProtocolDescriptor{ .name = "p1", .methods = &.{}, .protocol_id = 0 };
    const elements = [_]Element{ builtinElement(&ctx, "fixnum"), .{ .protocol = &p1 } };

    ctx.in_module_load = true;
    const res = try analyzeIntersection(&ctx, testing.allocator, &elements);
    try testing.expectEqual(Verdict.unknown, res.verdict);
}
