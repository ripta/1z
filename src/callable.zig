const container_backing = @import("container_backing.zig");
const context_mod = @import("context.zig");
const value_mod = @import("value.zig");

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
///   context-lifetime: a parameter's default, a dispatch entry's method body, a pragma validator,
///   a signal handler, an FFI callback, a deferred parse-time emission, and a closure-bodied word
///   definition. `adoptForTeardown` is that path.
/// - The owner is borrowed from a live container the site does not hold: `fireScopedHooks` runs
///   bodies out of an array the parameter binding owns.
/// - There is no owner at all: `PackedIter.Recognized.quotation` is reached only when `#map`'s
///   `owner != .closure` gate admitted it, so the body outlives the iterator on its own.
/// - The body is not the callable's: the `make-*` builders execute sub-slices of a body they hold
///   a `Callable` for.
/// - The body belongs to a module or the dictionary arena: a word body, and a dispatch body.
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

    /// Run the body without a lexical frame of its own.
    pub fn execute(self: Callable, ctx: *Context) anyerror!void {
        return ctx.executeQuotation(self.quot);
    }

    /// Run the body in a fresh lexical frame. The common form.
    pub fn executeWithFrame(self: Callable, ctx: *Context) anyerror!void {
        return ctx.executeQuotationWithFrame(self.quot);
    }

    /// Run the body in a fresh lexical frame but outside the tail-call loop, so a pending tail
    /// call propagates to the enclosing loop. `if` is the only caller.
    pub fn executeInline(self: Callable, ctx: *Context) anyerror!void {
        return ctx.executeQuotationInline(self.quot);
    }
};
