const container_backing = @import("container_backing.zig");
const context_mod = @import("context.zig");
const value_mod = @import("value.zig");

const Closure = value_mod.Closure;
const Context = context_mod.Context;
const Quotation = value_mod.Quotation;
const Value = value_mod.Value;

/// An executable quotation view paired with the reference behind it. For a closure that reference
/// is what keeps the body memory alive; a plain quotation's is inert.
///
/// Whether the reference is owned or borrowed is the holder's contract, not the type's. A holder
/// that owns it calls `release` or hands it onward. A holder that borrows it -- `SortContext`, and
/// the by-value copy `tryVectorizedPackedMap` receives -- never releases, and relies on an
/// enclosing frame outliving it.
///
/// Every site that keeps a body alive across execution holds one of these, so a body run through a
/// bare `Quotation` is an exception. There are five, each with its own reason:
///
/// - The owner is parked on the dictionary's teardown list, which makes the body
///   context-lifetime. `adoptForTeardown` is that path.
///
///   A parameter's default, a dispatch entry's method body, a pragma validator, a signal handler,
///   an FFI callback, and a closure-bodied word definition each keep a `?*const Closure` carrier
///   beside the view, from `ownerClosureOf`, since a body its closure owns resolves off the value.
///   A deferred parse-time emission needs none: it is spliced into the enclosing body rather than
///   run from where it was stored.
/// - The owner is borrowed from a live container the site does not hold: `fireScopedHooks` runs
///   bodies out of an array the parameter binding owns.
/// - There is no owner at all: `PackedIter.Recognized.quotation` is reached only when `#map`'s
///   `owner != .closure` gate admitted it, so the body outlives the iterator on its own.
/// - The body is not the callable's: the `make-*` builders execute sub-slices of a body they hold
///   a `Callable` for.
/// - The body belongs to a module or the dictionary arena: a word body whose definition names no
///   closure, and a synthesized or AOT-replayed dispatch body.
pub const Callable = struct {
    quot: Quotation,
    owner: Value,

    pub fn release(self: Callable) void {
        container_backing.releaseValue(self.owner);
    }

    /// Hand a body that escapes into context-lifetime storage over to the dictionary's teardown
    /// list, so it outlives the value. An inert owner is dropped instead.
    pub fn adoptForTeardown(self: Callable, ctx: *Context) !void {
        if (self.owner == .closure) {
            try ctx.retainValueForTeardown(self.owner);
        } else {
            container_backing.releaseValue(self.owner);
        }
    }

    /// The closure behind the body, for a body it may own.
    ///
    /// Body entry reads a closure-owned body's captured scope and defining module off this rather
    /// than out of the pointer-keyed side map, which such a body never enters.
    pub fn ownerClosure(self: Callable) ?*const Closure {
        return ownerClosureOf(self.owner);
    }

    /// Run the body without a lexical frame of its own.
    pub fn execute(self: Callable, ctx: *Context) anyerror!void {
        return ctx.executeQuotationWithOwner(self.quot, self.ownerClosure());
    }

    /// Run the body in a fresh lexical frame. The common form.
    pub fn executeWithFrame(self: Callable, ctx: *Context) anyerror!void {
        return ctx.executeQuotationWithFrame(self.quot, self.ownerClosure());
    }

    /// Run the body in a fresh lexical frame but outside the tail-call loop, so a pending tail
    /// call propagates to the enclosing loop. `if` is the only caller.
    pub fn executeInline(self: Callable, ctx: *Context) anyerror!void {
        return ctx.executeQuotationInline(self.quot, self.ownerClosure());
    }
};

/// The carrier behind a callable value, or null for a value that owns no body.
///
/// A registry that keeps only the quotation view stores this beside it. The pointer is borrowed:
/// the registration hands the owning reference to the dictionary's teardown list, which is what
/// keeps the body and the scope it points at alive, so the registry itself never releases.
pub fn ownerClosureOf(owner: Value) ?*const Closure {
    return switch (owner) {
        .closure => |c| c,
        else => null,
    };
}
