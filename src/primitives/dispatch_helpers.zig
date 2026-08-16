const std = @import("std");
const Context = @import("../context.zig").Context;
const dispatch_mod = @import("../dispatch.zig");

const pic_mod = @import("../pic.zig");
const PolymorphicCache = pic_mod.PolymorphicCache;

const container_backing = @import("../container_backing.zig");

const value_mod = @import("../value.zig");
const Instruction = value_mod.Instruction;
const Value = value_mod.Value;
const ProtocolDescriptor = value_mod.ProtocolDescriptor;
const ConstraintCombinator = value_mod.ConstraintCombinator;
const Marker = value_mod.Marker;

const stack_effect_mod = @import("../stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;

const protocols_mod = @import("protocols.zig");
const markers_mod = @import("markers.zig");
const helpers = @import("helpers.zig");
const trace_mod = @import("../trace.zig");

/// When the entry carries a defining module, the module's deps frame is pushed around the
/// quotation body so a method body resolves its module's private helpers the same way a regular
/// module word does. Native and host-callback bodies carry no defining module and run as opaque
/// functions.
pub fn executeDispatchBody(ctx: *Context, entry: dispatch_mod.DispatchEntry) !void {
    switch (entry.body) {
        .quotation => |q| {
            if (entry.source_module) |mod| {
                try ctx.pushModuleDepsFrame(mod);
                defer ctx.popModuleDepsFrameTraced(mod);
                try runDispatchQuotation(ctx, q, mod);
            } else {
                try runDispatchQuotation(ctx, q, null);
            }
        },
        .native_fn => |func| try func(ctx),
        .host_callback => |host| {
            const rc = host.callback(host.handle, host.user_data);
            if (rc != 0) return error.HostCallbackFailed;
        },
    }
}

/// An interpreter-registered method carries no compiled code pointer and runs its instructions on
/// the current frame. An AOT-replayed method carries a compiled `code_ptr` with an empty
/// instruction slice and runs through the compiled-call path. Gating on `code_ptr` keeps the
/// interpreter path free of the extra local frame `executeQuotationWithFrame` pushes.
///
/// `body_module` is the method's defining module, threaded so the body resolves its module's own
/// words under the `.module_deps` visibility filter -- the frame `executeDispatchBody` just pushed
/// is admitted only when the body reports that module as its defining one.
fn runDispatchQuotation(ctx: *Context, q: value_mod.Quotation, body_module: ?*const value_mod.Module) !void {
    if (q.code_ptr != null) {
        try ctx.executeQuotationWithFrame(q);
    } else {
        // A method body is reached as a dispatch entry rather than as a word, so nothing upstream
        // has pointed `current_source` at the file the body was written in.
        const saved_source = ctx.current_source;
        defer ctx.current_source = saved_source;
        ctx.enterBodySource(q.instructions);

        try ctx.executeQuotationWithPic(.{ .instructions = q.instructions }, null, body_module);
    }
}

fn autoUnwrapTopOperand(ctx: *Context) !void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    try ctx.stack.push(val.tagged.inner.*);
}

pub fn autoUnwrapBinaryOperands(ctx: *Context, unwrap_a: bool, unwrap_b: bool) !void {
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    defer container_backing.releaseValue(a);
    defer container_backing.releaseValue(b);
    const new_a = if (unwrap_a) a.tagged.inner.* else a;
    const new_b = if (unwrap_b) b.tagged.inner.* else b;
    try ctx.stack.push(new_a);
    try ctx.stack.push(new_b);
}

/// A resolved dispatch entry, plus which operands the caller must unwrap before running it. The
/// lookup itself never mutates the stack.
pub const AutoUnwrap = struct {
    entry: dispatch_mod.DispatchEntry,
    unwrap_a: bool,
    unwrap_b: bool,
};

/// Look up a binary dispatch entry, trying enum-level fallback.
///
/// Precedence:
/// 1. Exact variant type names (includes wildcard expansion)
/// 2. a's enum name with b's variant name
/// 3. a's variant name with b's enum name
/// 4. Both enum names
/// 5. Either or both base types, for a parameterized operand, which the caller unwraps first
pub fn lookupBinaryWithFallback(ctx: *Context, dispatch_id: u32, a: Value, b: Value) ?AutoUnwrap {
    const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
    const b_type = dispatch_mod.dispatchDescriptor(b, ctx);
    if (ctx.lookupBinaryDispatch(dispatch_id, a_type, b_type)) |entry| return .{ .entry = entry, .unwrap_a = false, .unwrap_b = false };

    const a_enum = dispatch_mod.dispatchEnumTypeValue(a);
    const b_enum = dispatch_mod.dispatchEnumTypeValue(b);
    if (a_enum) |ae| {
        if (ctx.lookupBinaryDispatch(dispatch_id, ae.descriptor.?, b_type)) |entry| return .{ .entry = entry, .unwrap_a = false, .unwrap_b = false };
    }
    if (b_enum) |be| {
        if (ctx.lookupBinaryDispatch(dispatch_id, a_type, be.descriptor.?)) |entry| return .{ .entry = entry, .unwrap_a = false, .unwrap_b = false };
    }

    if (a_enum) |ae| {
        if (b_enum) |be| {
            if (ctx.lookupBinaryDispatch(dispatch_id, ae.descriptor.?, be.descriptor.?)) |entry| return .{ .entry = entry, .unwrap_a = false, .unwrap_b = false };
        }
    }

    const a_base = dispatch_mod.dispatchBaseTypeValue(a);
    const b_base = dispatch_mod.dispatchBaseTypeValue(b);
    if (a_base) |ab| {
        if (ctx.lookupBinaryDispatch(dispatch_id, ab.descriptor.?, b_type)) |entry| return .{ .entry = entry, .unwrap_a = true, .unwrap_b = false };
    }
    if (b_base) |bb| {
        if (ctx.lookupBinaryDispatch(dispatch_id, a_type, bb.descriptor.?)) |entry| return .{ .entry = entry, .unwrap_a = false, .unwrap_b = true };
    }
    if (a_base) |ab| {
        if (b_base) |bb| {
            if (ctx.lookupBinaryDispatch(dispatch_id, ab.descriptor.?, bb.descriptor.?)) |entry| return .{ .entry = entry, .unwrap_a = true, .unwrap_b = true };
        }
    }

    return null;
}

/// Look up a unary dispatch entry, trying enum-level fallback.
///
/// Precedence:
/// 1. Exact variant type name (includes wildcard expansion)
/// 2. Enum name fallback
fn lookupUnaryWithFallback(ctx: *Context, dispatch_id: u32, a: Value) ?AutoUnwrap {
    const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
    if (ctx.lookupUnaryDispatch(dispatch_id, a_type)) |entry| return .{ .entry = entry, .unwrap_a = false, .unwrap_b = false };

    if (dispatch_mod.dispatchEnumTypeValue(a)) |ae| {
        if (ctx.lookupUnaryDispatch(dispatch_id, ae.descriptor.?)) |entry| return .{ .entry = entry, .unwrap_a = false, .unwrap_b = false };
    }

    if (dispatch_mod.dispatchBaseTypeValue(a)) |ab| {
        if (ctx.lookupUnaryDispatch(dispatch_id, ab.descriptor.?)) |entry| return .{ .entry = entry, .unwrap_a = true, .unwrap_b = false };
    }

    return null;
}

/// Try to dispatch a binary operation via the dispatch table.
///
/// Peeks at the top two stack values and looks up a registered method, executing the body with
/// operands left on the stack for it to consume. Returns true if dispatched.
///
/// Opt-in only: each native that supports dispatch must call this explicitly. Only type-switching
/// natives that branch on operand types (arithmetic, comparison, inspect, sequence ops, etc.)
/// should opt in; type-agnostic natives (dup, drop, swap, etc.) must not dispatch. See also notes
/// in the implementation of `nativeDefineMethod`.
pub fn tryDispatchBinary(ctx: *Context, dispatch_id: u32) !bool {
    if (ctx.stack.depth() < 2) return false;

    const a = try ctx.stack.peekN(1);
    const b = try ctx.stack.peek();

    if (ctx.current_pic_entry) |cache| {
        if (!cache.megamorphic) {
            if (cache.count > 0 and cache.generation != ctx.dispatch.generation) {
                cache.count = 0;
            } else if (cache.count > 0) {
                const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
                const b_type = dispatch_mod.dispatchDescriptor(b, ctx);
                if (cache.lookup(a_type, b_type)) |entry| {
                    if (entry.unwrap_a or entry.unwrap_b) {
                        try autoUnwrapBinaryOperands(ctx, entry.unwrap_a, entry.unwrap_b);
                    }
                    try executeDispatchBody(ctx, entry.entry);
                    return true;
                }
            }
        }
    }

    if (lookupBinaryWithFallback(ctx, dispatch_id, a, b)) |result| {
        if (ctx.current_pic_entry) |cache| {
            if (!cache.megamorphic) {
                const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
                const b_type = dispatch_mod.dispatchDescriptor(b, ctx);
                cache.insert(.{
                    .type_a = a_type,
                    .type_b = b_type,
                    .entry = result.entry,
                    .unwrap_a = result.unwrap_a,
                    .unwrap_b = result.unwrap_b,
                });
                cache.generation = ctx.dispatch.generation;
            }
        }
        if (result.unwrap_a or result.unwrap_b) {
            try autoUnwrapBinaryOperands(ctx, result.unwrap_a, result.unwrap_b);
        }
        try executeDispatchBody(ctx, result.entry);
        return true;
    }

    return false;
}

/// Try to dispatch a unary operation via the dispatch table.
///
/// Peeks at the top stack value and looks up a registered method, executing the body with the
/// operand left on the stack. Returns true if dispatched.
///
/// Same opt-in rules as tryDispatchBinary.
pub fn tryDispatchUnary(ctx: *Context, dispatch_id: u32) !bool {
    if (ctx.stack.depth() < 1) return false;

    const a = try ctx.stack.peek();

    if (ctx.current_pic_entry) |cache| {
        if (!cache.megamorphic) {
            if (cache.count > 0 and cache.generation != ctx.dispatch.generation) {
                cache.count = 0;
            } else if (cache.count > 0) {
                const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
                if (cache.lookup(a_type, ctx.getDispatchUnarySentinel().descriptor.?)) |entry| {
                    if (entry.unwrap_a) {
                        try autoUnwrapTopOperand(ctx);
                    }
                    try executeDispatchBody(ctx, entry.entry);
                    return true;
                }
            }
        }
    }

    if (lookupUnaryWithFallback(ctx, dispatch_id, a)) |result| {
        if (ctx.current_pic_entry) |cache| {
            if (!cache.megamorphic) {
                const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
                cache.insert(.{
                    .type_a = a_type,
                    .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
                    .entry = result.entry,
                    .unwrap_a = result.unwrap_a,
                    .unwrap_b = false,
                });
                cache.generation = ctx.dispatch.generation;
            }
        }
        if (result.unwrap_a) {
            try autoUnwrapTopOperand(ctx);
        }
        try executeDispatchBody(ctx, result.entry);
        return true;
    }
    return false;
}

/// Dispatch `dispatch_id`'s unary method on `val`, pushing it and leaving the method's result on
/// the stack. Returns false without touching the stack when no method is registered.
///
/// Unlike `tryDispatchUnary`, the operand is in the caller's hands rather than on the stack, and
/// no PIC is consulted: `ctx.current_pic_entry` belongs to the enclosing word's call site, and
/// seeding it with another word's entries would poison that cache.
pub fn dispatchUnaryOnValue(ctx: *Context, dispatch_id: u32, val: Value) !bool {
    const result = lookupUnaryWithFallback(ctx, dispatch_id, val) orelse return false;
    try ctx.stack.push(val);
    if (result.unwrap_a) {
        try autoUnwrapTopOperand(ctx);
    }
    try executeDispatchBody(ctx, result.entry);
    return true;
}

/// Dispatch a container-keyed word whose container operand sits `depth` slots below the top of stack, the
/// `#nth!` / `#poke!` shape. The dispatch key is the container's type with the unary sentinel, so a user
/// type registers `method{ your-type }` and the key/value operands above the container ride along untouched.
///
/// When `unwrap_base` is true, a tagged container carrying a base type is unwrapped in place before its
/// base-type arm runs, reproducing the `unwrapBaseType` behavior of `@get`/`@has?`/`@keys`/`@values`. When
/// false, a tagged base-typed container is left to fall through, matching `@set`'s rejection of tagged
/// values without unwrapping.
///
/// Returns true when an arm ran. Returns false when no arm matched, leaving the stack untouched so the
/// caller can pop and report its own type error.
pub fn tryDispatchContainerAtDepth(ctx: *Context, dispatch_id: u32, depth: usize, unwrap_base: bool) !bool {
    if (ctx.stack.depth() < depth + 1) return false;

    const peeked = try ctx.stack.peekN(depth);
    const a_type = dispatch_mod.dispatchDescriptor(peeked, ctx);
    if (ctx.lookupUnaryDispatch(dispatch_id, a_type)) |entry| {
        try executeDispatchBody(ctx, entry);
        return true;
    }

    if (dispatch_mod.dispatchEnumTypeValue(peeked)) |ae| {
        if (ctx.lookupUnaryDispatch(dispatch_id, ae.descriptor.?)) |entry| {
            try executeDispatchBody(ctx, entry);
            return true;
        }
    }

    if (unwrap_base) {
        if (dispatch_mod.dispatchBaseTypeValue(peeked)) |bt| {
            if (ctx.lookupUnaryDispatch(dispatch_id, bt.descriptor.?)) |entry| {
                const len = ctx.stack.items.items.len;
                helpers.unwrapTaggedSlotInPlace(&ctx.stack.items.items[len - (depth + 1)]);
                try executeDispatchBody(ctx, entry);
                return true;
            }
        }
    }

    return false;
}

/// Derive a comparison result from a `cmp` dispatch method, for a type that defines `cmp` but not
/// a direct `=`/`<`/`>` method. Accepts a raw fixnum or an `ordering:*` enum variant.
///
/// XXX(ripta): This reaches into 1z runtime to look up ordering:* enum variants.
pub fn tryDispatchBinaryViaCmp(ctx: *Context, comptime op: enum { eq, lt, gt }) !bool {
    if (ctx.stack.depth() < 2) return false;
    const cmp_id = ctx.resolveDispatchId("cmp") orelse return false;

    const a = try ctx.stack.peekN(1);
    const b = try ctx.stack.peek();
    if (lookupBinaryWithFallback(ctx, cmp_id, a, b)) |result| {
        if (result.unwrap_a or result.unwrap_b) {
            try autoUnwrapBinaryOperands(ctx, result.unwrap_a, result.unwrap_b);
        }
        try executeDispatchBody(ctx, result.entry);
        const cmp_result = try ctx.stack.pop();
        defer container_backing.releaseValue(cmp_result);
        const boolean = switch (cmp_result) {
            .fixnum => |cmp_val| switch (op) {
                .eq => cmp_val == 0,
                .lt => cmp_val < 0,
                .gt => cmp_val > 0,
            },
            .tagged => |t| blk: {
                const name = t.tag.name;
                if (std.mem.eql(u8, name, "ordering:lt")) {
                    break :blk op == .lt;
                } else if (std.mem.eql(u8, name, "ordering:eq")) {
                    break :blk op == .eq;
                } else if (std.mem.eql(u8, name, "ordering:gt")) {
                    break :blk op == .gt;
                } else {
                    return error.TypeMismatch;
                }
            },
            else => return error.TypeMismatch,
        };
        try ctx.stack.push(.{ .boolean = boolean });
        return true;
    }

    return false;
}

/// Try to dispatch a generic word via the dispatch table.
///
/// Unlike the tryDispatchBinary / tryDispatchUnary versions used by native ops,
/// this does not restrict dispatch to user types. Generic words may have methods
/// registered for any type combination, including native types.
///
/// Tries binary dispatch first (if stack depth >= 2), then unary.
/// Returns true if dispatched, false if not.
pub fn tryDispatchGeneric(ctx: *Context, word_name: []const u8) !bool {
    const dispatch_id = ctx.resolveDispatchId(word_name) orelse return false;
    return tryDispatchGenericById(ctx, dispatch_id, null);
}

/// Convenience wrapper: resolve word name, then dispatch with PIC.
pub fn tryDispatchGenericWithPic(ctx: *Context, word_name: []const u8, pic: ?*PolymorphicCache) !bool {
    const dispatch_id = ctx.resolveDispatchId(word_name) orelse return false;
    return tryDispatchGenericById(ctx, dispatch_id, pic);
}

/// Try to dispatch a generic word by dispatch ID, with optional PIC.
///
/// Used by the execution loop where the WordDefinition (and its dispatch_id)
/// is already in hand, avoiding an extra dictionary lookup.
pub fn tryDispatchGenericById(ctx: *Context, dispatch_id: u32, pic: ?*PolymorphicCache) !bool {
    if (pic) |cache| {
        if (!cache.megamorphic) {
            if (cache.count > 0 and cache.generation != ctx.dispatch.generation) {
                cache.count = 0;
            } else if (cache.count > 0) {
                if (ctx.stack.depth() >= 2) {
                    const a = try ctx.stack.peekN(1);
                    const b = try ctx.stack.peek();
                    const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
                    const b_type = dispatch_mod.dispatchDescriptor(b, ctx);
                    if (cache.lookup(a_type, b_type)) |entry| {
                        if (entry.unwrap_a or entry.unwrap_b) {
                            try autoUnwrapBinaryOperands(ctx, entry.unwrap_a, entry.unwrap_b);
                        }
                        try executeDispatchBody(ctx, entry.entry);
                        return true;
                    }
                } else if (ctx.stack.depth() >= 1) {
                    const a = try ctx.stack.peek();
                    const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
                    if (cache.lookup(a_type, ctx.getDispatchUnarySentinel().descriptor.?)) |entry| {
                        if (entry.unwrap_a) {
                            try autoUnwrapTopOperand(ctx);
                        }
                        try executeDispatchBody(ctx, entry.entry);
                        return true;
                    }
                }
            }
        }
    }

    if (ctx.stack.depth() >= 2) {
        const a = try ctx.stack.peekN(1);
        const b = try ctx.stack.peek();
        if (lookupBinaryWithFallback(ctx, dispatch_id, a, b)) |result| {
            if (pic) |cache| {
                if (!cache.megamorphic) {
                    const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
                    const b_type = dispatch_mod.dispatchDescriptor(b, ctx);
                    cache.insert(.{
                        .type_a = a_type,
                        .type_b = b_type,
                        .entry = result.entry,
                        .unwrap_a = result.unwrap_a,
                        .unwrap_b = result.unwrap_b,
                    });
                    cache.generation = ctx.dispatch.generation;
                }
            }
            if (result.unwrap_a or result.unwrap_b) {
                try autoUnwrapBinaryOperands(ctx, result.unwrap_a, result.unwrap_b);
            }
            try executeDispatchBody(ctx, result.entry);
            return true;
        }
    }

    if (ctx.stack.depth() >= 1) {
        const a = try ctx.stack.peek();
        if (lookupUnaryWithFallback(ctx, dispatch_id, a)) |result| {
            if (pic) |cache| {
                if (!cache.megamorphic) {
                    const a_type = dispatch_mod.dispatchDescriptor(a, ctx);
                    cache.insert(.{
                        .type_a = a_type,
                        .type_b = ctx.getDispatchUnarySentinel().descriptor.?,
                        .entry = result.entry,
                        .unwrap_a = result.unwrap_a,
                        .unwrap_b = false,
                    });
                    cache.generation = ctx.dispatch.generation;
                }
            }
            if (result.unwrap_a) {
                try autoUnwrapTopOperand(ctx);
            }
            try executeDispatchBody(ctx, result.entry);
            return true;
        }
    }

    return false;
}

/// Operand arity of a protocol-bounded call site, as known statically by the caller. Selects how
/// many operands the satisfies-check guards and which dispatch lookup runs.
pub const ProtocolArity = enum { unary, binary };

/// The bound a bounded call site checks operands against: a single protocol or a
/// constraint combinator. Both kinds flow through the same dispatch helper; only
/// the operand satisfies-check differs.
pub const BoundedConstraint = union(enum) {
    protocol: *const ProtocolDescriptor,
    combinator: *const ConstraintCombinator,
};

/// Verify the dispatched operand satisfies `constraint`. Mirrors the interpreter's per-parameter
/// check in `Context.validateTypeAnnotations`: a value whose type cannot be resolved, or has no
/// descriptor, is left to the dispatch lookup rather than failing the bound. A non-satisfying
/// operand raises `protocol-error`.
fn checkOperand(ctx: *Context, val: Value, constraint: BoundedConstraint) !void {
    const val_tv = helpers.resolveValueTypeValue(ctx, val) orelse return;
    if (val_tv.descriptor == null) return;
    switch (constraint) {
        .protocol => |descriptor| {
            if (try protocols_mod.satisfiesByDescriptor(ctx, val_tv, descriptor)) return;
            const msg = std.fmt.allocPrint(
                ctx.arena.allocator(),
                "type '{s}' does not satisfy protocol '{s}'",
                .{ val_tv.name, descriptor.name },
            ) catch "protocol mismatch";
            return protocols_mod.raiseProtocolError(ctx, msg);
        },
        .combinator => |cc| {
            if (try protocols_mod.typeSatisfiesConstraint(ctx, val_tv, .{ .combinator = cc })) return;
            return protocols_mod.raiseCombinatorError(ctx, val_tv.name);
        },
    }
}

/// Protocol-bounded dispatch helper emitted by compiled code at a call site whose parameter is
/// bound by a protocol or a constraint combinator. Every operand the dispatch consumes is
/// satisfies-checked against `constraint` first; a non-satisfying operand raises `protocol-error`.
///
/// On success the existing dispatch lookup resolves the concrete-type method and transfers into
/// it, leaving the operands on the stack for the body to consume. No polymorphic inline cache is
/// consulted or installed at bounded sites.
pub fn satisfiesAndDispatch(
    ctx: *Context,
    dispatch_id: u32,
    constraint: BoundedConstraint,
    arity: ProtocolArity,
    trace_name: []const u8,
    source_override: ?[]const u8,
    line: usize,
) !void {
    // Name the bounded site by its protocol for the duration of the dispatch.
    // The frame makes the site visible to scheduler task dumps when a body
    // parks here and to call-stack-based error backtraces; the live event
    // mirrors the interpreter's `--trace-words` output for an ordinary word.
    const source = source_override orelse (ctx.jit_trace_source orelse ctx.current_source);
    ctx.pushCallFrame(trace_name, source, line, 0);
    defer ctx.popCallFrame();
    if (ctx.trace.trace_words and trace_mod.matchesPattern(trace_name, ctx.trace.trace_words_pattern)) {
        var tw = trace_mod.TraceWriter.init();
        trace_mod.traceWord(&tw, trace_name, source, line, &ctx.stack);
    }
    switch (arity) {
        .binary => {
            if (ctx.stack.depth() < 2) return error.StackUnderflow;
            const a = try ctx.stack.peekN(1);
            const b = try ctx.stack.peek();
            try checkOperand(ctx, a, constraint);
            try checkOperand(ctx, b, constraint);

            if (lookupBinaryWithFallback(ctx, dispatch_id, a, b)) |result| {
                if (result.unwrap_a or result.unwrap_b) {
                    try autoUnwrapBinaryOperands(ctx, result.unwrap_a, result.unwrap_b);
                }
                try executeDispatchBody(ctx, result.entry);
                return;
            }
        },
        .unary => {
            if (ctx.stack.depth() < 1) return error.StackUnderflow;
            const a = try ctx.stack.peek();
            try checkOperand(ctx, a, constraint);

            if (lookupUnaryWithFallback(ctx, dispatch_id, a)) |result| {
                if (result.unwrap_a) {
                    try autoUnwrapTopOperand(ctx);
                }
                try executeDispatchBody(ctx, result.entry);
                return;
            }
        },
    }

    // Operands satisfied the bound but no concrete-type method resolved. This is reachable for a
    // binary site whose mixed operand pair has no registered method; surface the same failure the
    // interpreter's generic dispatch does.
    ctx.pending_error_message = "no method found for generic word";
    return error.TypeError;
}

/// True when `descriptor`'s method list names `method_name`. The methods array is a flat sequence
/// of method-name symbols, each optionally followed by a stack-effect entry; only the symbols are
/// method names.
pub fn protocolRequiresMethod(descriptor: *const ProtocolDescriptor, method_name: []const u8) bool {
    for (descriptor.methods) |entry| {
        switch (entry) {
            .symbol => |s| if (std.mem.eql(u8, s.bytes, method_name)) return true,
            else => {},
        }
    }
    return false;
}

/// True when satisfying `cc` provably guarantees a registered method named
/// `name` for any type. An intersection guarantees the method when *any* element
/// does (a satisfying type satisfies every element, so one guaranteeing element
/// suffices); a union guarantees it only when *every* element does (a satisfying
/// type satisfies some element, so all must guarantee). A concrete-type element
/// never guarantees a registered method; a protocol element guarantees it when
/// the protocol requires it; a nested combinator recurses.
pub fn combinatorGuaranteesMethod(cc: *const ConstraintCombinator, name: []const u8) bool {
    return switch (cc.kind) {
        .intersection => {
            for (cc.elements) |el| {
                if (elementGuaranteesMethod(el, name)) return true;
            }
            return false;
        },
        .@"union" => {
            for (cc.elements) |el| {
                if (!elementGuaranteesMethod(el, name)) return false;
            }
            return cc.elements.len > 0;
        },
    };
}

fn elementGuaranteesMethod(el: ConstraintCombinator.Element, name: []const u8) bool {
    return switch (el) {
        .type => false,
        .protocol => |p| protocolRequiresMethod(p, name),
        .combinator => |sub| combinatorGuaranteesMethod(sub, name),
    };
}

/// The bound and dispatch arity of a bounded generic call site.
pub const BoundedDispatch = struct {
    constraint: BoundedConstraint,
    arity: ProtocolArity,
};

/// True when two bounds are the same descriptor of the same kind (pointer identity).
fn boundedConstraintEql(a: BoundedConstraint, b: BoundedConstraint) bool {
    return switch (a) {
        .protocol => |pa| switch (b) {
            .protocol => |pb| pa == pb,
            .combinator => false,
        },
        .combinator => |ca| switch (b) {
            .combinator => |cb| ca == cb,
            .protocol => false,
        },
    };
}

/// Decide whether a call to word `name` with stack effect `effect` and `markers` is a
/// bounded generic dispatch site that compiled code should lower to `satisfiesAndDispatch`
/// rather than the usual dispatch path. Returns the bound and dispatch arity when:
///
///   1. the word is generic (carries the `generic` marker),
///   2. it has no row-variable inputs and exactly one or two concrete inputs,
///   3. every concrete input is bound by the *same* protocol descriptor or constraint
///      combinator C, and
///   4. C provably requires `name` as a method: a protocol requires `name`, or a combinator
///      provably guarantees a registered `name` for every satisfying type (see
///      `combinatorGuaranteesMethod`).
///
/// Condition 4 guarantees that any operand satisfying C has a registered method for `name`, so the
/// dispatch can never miss and the helper's raise-on-miss path is unreachable. That keeps compiled
/// behavior identical to the interpreter, which would otherwise run the generic's fallback body on
/// a miss. Mixed-bound, concrete-type, or otherwise non-conforming generics return null and keep
/// the existing dispatch path.
pub fn boundedDispatchFor(
    effect: *const StackEffect,
    markers: []const *Marker,
    name: []const u8,
) ?BoundedDispatch {
    const is_generic = for (markers) |mk| {
        if (markers_mod.isGenericMarker(mk)) break true;
    } else false;
    if (!is_generic) return null;

    if (stack_effect_mod.hasAnyRowVariable(effect.*)) return null;

    const n = effect.inputs.len;
    if (n != 1 and n != 2) return null;

    var bound: ?BoundedConstraint = null;
    for (effect.inputs) |param| {
        const ann = param.type_annotation orelse return null;
        const this: BoundedConstraint = switch (ann) {
            .protocol => |p| .{ .protocol = p },
            .combination => |c| .{ .combinator = c },
            .type => return null,
        };
        if (bound) |b| {
            if (!boundedConstraintEql(b, this)) return null;
        } else {
            bound = this;
        }
    }

    const b = bound orelse return null;
    switch (b) {
        .protocol => |d| if (!protocolRequiresMethod(d, name)) return null,
        .combinator => |cc| if (!combinatorGuaranteesMethod(cc, name)) return null,
    }

    return .{ .constraint = b, .arity = if (n == 2) .binary else .unary };
}

// =============================================================================
// Tests
// =============================================================================

test "tryDispatchBinary returns false with empty stack" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const result = try tryDispatchBinary(&ctx, ctx.nativeDispatchId(.add));
    try std.testing.expect(!result);
}

test "tryDispatchBinary returns false when the id owns no entries" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.defineWord("no-such-word", .{ .name = "no-such-word", .action = .{ .compound = &[_]Instruction{} } });

    try ctx.stack.push(.{ .fixnum = 1 });
    try ctx.stack.push(.{ .fixnum = 2 });

    const result = try tryDispatchBinary(&ctx, ctx.resolveDispatchId("no-such-word").?);
    try std.testing.expect(!result);

    try std.testing.expectEqual(@as(usize, 2), ctx.stack.depth());
}

test "tryDispatchUnary returns false with empty stack" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const result = try tryDispatchUnary(&ctx, ctx.nativeDispatchId(.abs));
    try std.testing.expect(!result);
}

test "tryDispatchUnary returns false when the id owns no entries" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.defineWord("serialize", .{ .name = "serialize", .action = .{ .compound = &[_]Instruction{} } });

    try ctx.stack.push(.{ .fixnum = 42 });

    const result = try tryDispatchUnary(&ctx, ctx.resolveDispatchId("serialize").?);
    try std.testing.expect(!result);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
}

test "tryDispatchBinary with the native's own id ignores a shadowing frame binding" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // A frame-local binding named `-` shadows the native for by-name resolution.
    try ctx.pushLocalFrame();
    defer ctx.popLocalFrame();
    try ctx.defineWord("-", .{ .name = "-", .action = .{ .compound = &[_]Instruction{} } });

    try ctx.stack.push(.{ .float = 100.0 });
    try ctx.stack.push(.{ .float = 40.0 });

    const result = try tryDispatchBinary(&ctx, ctx.nativeDispatchId(.sub));
    try std.testing.expect(result);
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(f64, 60.0), (try ctx.stack.pop()).float);
}

test "tryDispatchUnary with the native's own id ignores a shadowing frame binding" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.pushLocalFrame();
    defer ctx.popLocalFrame();
    try ctx.defineWord("abs", .{ .name = "abs", .action = .{ .compound = &[_]Instruction{} } });

    try ctx.stack.push(.{ .float = -3.5 });

    const result = try tryDispatchUnary(&ctx, ctx.nativeDispatchId(.abs));
    try std.testing.expect(result);
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(f64, 3.5), (try ctx.stack.pop()).float);
}

test "tryDispatchContainerAtDepth with the native's own id ignores a shadowing frame binding" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // `@get`'s builtin arms key on container types the test cannot cheaply build, so the arm
    // under test keys on the fixnum standing in for the container.
    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const body = &[_]Instruction{
        .{ .op = .{ .call_word = "drop" }, .line = 0 },
        .{ .op = .{ .call_word = "drop" }, .line = 0 },
        .{ .op = .{ .push_literal = .{ .fixnum = 99 } }, .line = 0 },
    };
    try ctx.dispatch.register(
        .{ .dispatch_id = ctx.nativeDispatchId(.at_get), .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    try ctx.pushLocalFrame();
    defer ctx.popLocalFrame();
    try ctx.defineWord("@get", .{ .name = "@get", .action = .{ .compound = &[_]Instruction{} } });

    try ctx.stack.push(.{ .fixnum = 7 });
    try ctx.stack.push(.{ .fixnum = 1 });

    const result = try tryDispatchContainerAtDepth(&ctx, ctx.nativeDispatchId(.at_get), 1, true);
    try std.testing.expect(result);
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 99), (try ctx.stack.pop()).fixnum);
}

test "tryDispatchGeneric returns false with empty stack" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const result = try tryDispatchGeneric(&ctx, "serialize");
    try std.testing.expect(!result);
}

test "tryDispatchGeneric returns false when no method registered" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .fixnum = 42 });

    const result = try tryDispatchGeneric(&ctx, "serialize");
    try std.testing.expect(!result);

    // Stack should be unchanged
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
}

test "tryDispatchGeneric dispatches unary method for native type" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;

    // Register a unary method for "fixnum" type
    const body = &[_]Instruction{
        .{ .op = .{ .call_word = "inspect" }, .line = 0 },
    };
    const dispatch_id: u32 = 1;
    try ctx.dispatch.register(
        .{ .dispatch_id = dispatch_id, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    try ctx.stack.push(.{ .fixnum = 42 });

    const result = try tryDispatchGenericById(&ctx, dispatch_id, null);
    try std.testing.expect(result);

    // Method should have executed (inspect converts fixnum to string)
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const top = try ctx.stack.pop();
    defer container_backing.releaseValue(top);
    try std.testing.expectEqualStrings("42", top.string.bytes);
}

test "tryDispatchGeneric tries binary before unary" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;

    // Register both binary and unary methods
    const binary_body = &[_]Instruction{
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    const unary_body = &[_]Instruction{
        .{ .op = .{ .call_word = "inspect" }, .line = 0 },
    };

    const dispatch_id: u32 = 2;
    try ctx.dispatch.register(
        .{ .dispatch_id = dispatch_id, .type_a = fixnum_tv.descriptor.?, .type_b = fixnum_tv.descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = binary_body } } },
        false,
    );
    try ctx.dispatch.register(
        .{ .dispatch_id = dispatch_id, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = unary_body } } },
        false,
    );

    // With two fixnums on stack, binary should be chosen
    try ctx.stack.push(.{ .fixnum = 10 });
    try ctx.stack.push(.{ .fixnum = 32 });

    const result = try tryDispatchGenericById(&ctx, dispatch_id, null);
    try std.testing.expect(result);

    // Binary method (addition) should have run
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const top = try ctx.stack.pop();
    try std.testing.expectEqual(@as(i64, 42), top.fixnum);
}

test "tryDispatchGenericWithPic populates cache on miss" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;

    const body = &[_]Instruction{
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    const dispatch_id: u32 = 3;
    try ctx.dispatch.register(
        .{ .dispatch_id = dispatch_id, .type_a = fixnum_tv.descriptor.?, .type_b = fixnum_tv.descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    var cache = PolymorphicCache{};

    try ctx.stack.push(.{ .fixnum = 3 });
    try ctx.stack.push(.{ .fixnum = 4 });

    const result = try tryDispatchGenericById(&ctx, dispatch_id, &cache);
    try std.testing.expect(result);
    try std.testing.expectEqual(@as(i64, 7), (try ctx.stack.pop()).fixnum);

    // Cache should now be populated
    try std.testing.expectEqual(@as(u8, 1), cache.count);
    try std.testing.expectEqual(fixnum_tv.descriptor.?, cache.entries[0].type_a);
    try std.testing.expectEqual(fixnum_tv.descriptor.?, cache.entries[0].type_b);
    try std.testing.expectEqual(ctx.dispatch.generation, cache.generation);
}

test "tryDispatchGenericWithPic hits cache on matching types" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;

    const body = &[_]Instruction{
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    const dispatch_id: u32 = 3;
    try ctx.dispatch.register(
        .{ .dispatch_id = dispatch_id, .type_a = fixnum_tv.descriptor.?, .type_b = fixnum_tv.descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    var cache = PolymorphicCache{};

    // First call: populates cache
    try ctx.stack.push(.{ .fixnum = 1 });
    try ctx.stack.push(.{ .fixnum = 2 });
    _ = try tryDispatchGenericById(&ctx, dispatch_id, &cache);
    try ctx.stack.popAndRelease();

    // Second call: should hit cache (same types)
    try ctx.stack.push(.{ .fixnum = 10 });
    try ctx.stack.push(.{ .fixnum = 20 });
    const result = try tryDispatchGenericById(&ctx, dispatch_id, &cache);
    try std.testing.expect(result);
    try std.testing.expectEqual(@as(i64, 30), (try ctx.stack.pop()).fixnum);
}

test "tryDispatchGenericWithPic invalidates on generation change" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;

    const body = &[_]Instruction{
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    const add_id: u32 = 3;
    try ctx.dispatch.register(
        .{ .dispatch_id = add_id, .type_a = fixnum_tv.descriptor.?, .type_b = fixnum_tv.descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    var cache = PolymorphicCache{};

    // Populate cache
    try ctx.stack.push(.{ .fixnum = 1 });
    try ctx.stack.push(.{ .fixnum = 2 });
    _ = try tryDispatchGenericById(&ctx, add_id, &cache);
    try ctx.stack.popAndRelease();

    const gen_before = cache.generation;

    // Register a new method, bumping generation
    const body2 = &[_]Instruction{
        .{ .op = .{ .call_word = "inspect" }, .line = 0 },
    };
    try ctx.dispatch.register(
        .{ .dispatch_id = 4, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = body2 } } },
        false,
    );

    try std.testing.expect(ctx.dispatch.generation > gen_before);

    // Cache should be stale: generation no longer matches
    try ctx.stack.push(.{ .fixnum = 5 });
    try ctx.stack.push(.{ .fixnum = 6 });
    const result = try tryDispatchGenericById(&ctx, add_id, &cache);
    try std.testing.expect(result);
    try std.testing.expectEqual(@as(i64, 11), (try ctx.stack.pop()).fixnum);

    // Cache should be re-populated with new generation
    try std.testing.expectEqual(ctx.dispatch.generation, cache.generation);
}

test "tryDispatchGenericWithPic with null pic_entry falls back to full lookup" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;

    const body = &[_]Instruction{
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    const dispatch_id: u32 = 3;
    try ctx.dispatch.register(
        .{ .dispatch_id = dispatch_id, .type_a = fixnum_tv.descriptor.?, .type_b = fixnum_tv.descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    try ctx.stack.push(.{ .fixnum = 10 });
    try ctx.stack.push(.{ .fixnum = 20 });

    const result = try tryDispatchGenericById(&ctx, dispatch_id, null);
    try std.testing.expect(result);
    try std.testing.expectEqual(@as(i64, 30), (try ctx.stack.pop()).fixnum);
}

test "tryDispatchGenericWithPic caches unary dispatch" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;

    const body = &[_]Instruction{
        .{ .op = .{ .call_word = "inspect" }, .line = 0 },
    };
    const dispatch_id: u32 = 4;
    try ctx.dispatch.register(
        .{ .dispatch_id = dispatch_id, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    var cache = PolymorphicCache{};

    try ctx.stack.push(.{ .fixnum = 42 });
    const result = try tryDispatchGenericById(&ctx, dispatch_id, &cache);
    try std.testing.expect(result);
    const popped = try ctx.stack.pop();
    defer container_backing.releaseValue(popped);
    try std.testing.expectEqualStrings("42", popped.string.bytes);

    // Cache should record unary dispatch (type_b is unary_sentinel)
    try std.testing.expectEqual(@as(u8, 1), cache.count);
    try std.testing.expectEqual(fixnum_tv.descriptor.?, cache.entries[0].type_a);
    try std.testing.expectEqual(ctx.getDispatchUnarySentinel().descriptor.?, cache.entries[0].type_b);
}

/// Define a generic word `name`, so that it has a dispatch_id resolvable by the protocol
/// satisfies-check, and return that dispatch_id.
fn defineGenericForTest(ctx: *Context, name: []const u8) !u32 {
    try ctx.defineWord(name, .{ .name = name, .action = .{ .compound = &[_]Instruction{} } });
    return ctx.resolveDispatchId(name).?;
}

test "satisfiesAndDispatch dispatches a satisfying type" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const did = try defineGenericForTest(&ctx, "describe");

    const body = &[_]Instruction{
        .{ .op = .{ .call_word = "inspect" }, .line = 0 },
    };
    try ctx.registerDispatch(
        .{ .dispatch_id = did, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    const descriptor = try ctx.createProtocolDescriptor("describable", &[_]Value{value_mod.symbolValue("describe")});

    try ctx.stack.push(.{ .fixnum = 42 });
    const frames_before = ctx.call_stack.items.len;
    try satisfiesAndDispatch(&ctx, did, .{ .protocol = descriptor }, .unary, ctx.boundedDispatchTraceName(descriptor), null, 0);

    // The diagnostic frame is pushed for the dispatch and popped on the way
    // out, leaving the call stack balanced.
    try std.testing.expectEqual(frames_before, ctx.call_stack.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const popped = try ctx.stack.pop();
    defer container_backing.releaseValue(popped);
    try std.testing.expectEqualStrings("42", popped.string.bytes);
}

test "satisfiesAndDispatch raises protocol-error for a non-satisfying type" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const did = try defineGenericForTest(&ctx, "describe");

    // describe is registered only for fixnum, so a boolean does not satisfy.
    const body = &[_]Instruction{
        .{ .op = .{ .call_word = "inspect" }, .line = 0 },
    };
    try ctx.registerDispatch(
        .{ .dispatch_id = did, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    const descriptor = try ctx.createProtocolDescriptor("describable", &[_]Value{value_mod.symbolValue("describe")});

    try ctx.stack.push(.{ .boolean = true });
    const frames_before = ctx.call_stack.items.len;
    const result = satisfiesAndDispatch(&ctx, did, .{ .protocol = descriptor }, .unary, ctx.boundedDispatchTraceName(descriptor), null, 0);
    try std.testing.expectError(error.UserThrown, result);

    // The diagnostic frame is popped even on the protocol-error path.
    try std.testing.expectEqual(frames_before, ctx.call_stack.items.len);

    const thrown = ctx.thrown_error.?;
    try std.testing.expectEqualStrings("protocol-error", thrown.error_type);
}

test "satisfiesAndDispatch reaches a method registered after a failed check" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const did = try defineGenericForTest(&ctx, "describe");
    const descriptor = try ctx.createProtocolDescriptor("describable", &[_]Value{value_mod.symbolValue("describe")});

    // No method yet: the check fails and memoizes the negative answer.
    try ctx.stack.push(.{ .fixnum = 42 });
    try std.testing.expectError(error.UserThrown, satisfiesAndDispatch(&ctx, did, .{ .protocol = descriptor }, .unary, ctx.boundedDispatchTraceName(descriptor), null, 0));
    try ctx.stack.popAndRelease();

    // Registering the method invalidates the satisfies memo coarsely, so the
    // next call re-checks, satisfies, and dispatches the new entry.
    const body = &[_]Instruction{
        .{ .op = .{ .call_word = "inspect" }, .line = 0 },
    };
    try ctx.registerDispatch(
        .{ .dispatch_id = did, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    try ctx.stack.push(.{ .fixnum = 42 });
    try satisfiesAndDispatch(&ctx, did, .{ .protocol = descriptor }, .unary, ctx.boundedDispatchTraceName(descriptor), null, 0);
    const popped = try ctx.stack.pop();
    defer container_backing.releaseValue(popped);
    try std.testing.expectEqualStrings("42", popped.string.bytes);
}

test "satisfiesAndDispatch handles a binary satisfying pair" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const did = try defineGenericForTest(&ctx, "cmp");

    const body = &[_]Instruction{
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    try ctx.registerDispatch(
        .{ .dispatch_id = did, .type_a = fixnum_tv.descriptor.?, .type_b = fixnum_tv.descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    const descriptor = try ctx.createProtocolDescriptor("comparable", &[_]Value{value_mod.symbolValue("cmp")});

    try ctx.stack.push(.{ .fixnum = 3 });
    try ctx.stack.push(.{ .fixnum = 5 });
    try satisfiesAndDispatch(&ctx, did, .{ .protocol = descriptor }, .binary, ctx.boundedDispatchTraceName(descriptor), null, 0);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 8), (try ctx.stack.pop()).fixnum);
}

const StackEffectParam = stack_effect_mod.StackEffectParam;

fn genericMarkers() [1]*Marker {
    return [1]*Marker{@constCast(&markers_mod.generic_marker)};
}

test "boundedDispatchFor: unary generic bounded by a requiring protocol" {
    const pd = ProtocolDescriptor{ .name = "flyable", .methods = &[_]Value{value_mod.symbolValue("soar")}, .protocol_id = 0 };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "x", .type_annotation = .{ .protocol = &pd } }},
        .outputs = &[_]StackEffectParam{.{ .name = "y" }},
    };
    const markers = genericMarkers();
    const result = boundedDispatchFor(&effect, &markers, "soar").?;
    try std.testing.expectEqual(&pd, result.constraint.protocol);
    try std.testing.expectEqual(ProtocolArity.unary, result.arity);
}

test "boundedDispatchFor: binary generic with one protocol on both operands" {
    const pd = ProtocolDescriptor{ .name = "comparable", .methods = &[_]Value{value_mod.symbolValue("cmp")}, .protocol_id = 0 };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "a", .type_annotation = .{ .protocol = &pd } },
            .{ .name = "b", .type_annotation = .{ .protocol = &pd } },
        },
        .outputs = &[_]StackEffectParam{.{ .name = "o" }},
    };
    const markers = genericMarkers();
    const result = boundedDispatchFor(&effect, &markers, "cmp").?;
    try std.testing.expectEqual(&pd, result.constraint.protocol);
    try std.testing.expectEqual(ProtocolArity.binary, result.arity);
}

test "boundedDispatchFor: non-generic word returns null" {
    const pd = ProtocolDescriptor{ .name = "flyable", .methods = &[_]Value{value_mod.symbolValue("soar")}, .protocol_id = 0 };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "x", .type_annotation = .{ .protocol = &pd } }},
        .outputs = &[_]StackEffectParam{.{ .name = "y" }},
    };
    const markers = [_]*Marker{};
    try std.testing.expectEqual(@as(?BoundedDispatch, null), boundedDispatchFor(&effect, &markers, "soar"));
}

test "boundedDispatchFor: protocol not requiring the generic returns null" {
    const pd = ProtocolDescriptor{ .name = "flyable", .methods = &[_]Value{value_mod.symbolValue("fly")}, .protocol_id = 0 };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "x", .type_annotation = .{ .protocol = &pd } }},
        .outputs = &[_]StackEffectParam{.{ .name = "y" }},
    };
    const markers = genericMarkers();
    // `flyable` requires `fly`, not the dispatched generic `soar`.
    try std.testing.expectEqual(@as(?BoundedDispatch, null), boundedDispatchFor(&effect, &markers, "soar"));
}

test "boundedDispatchFor: mixed protocols return null" {
    const fly = ProtocolDescriptor{ .name = "flyable", .methods = &[_]Value{value_mod.symbolValue("go")}, .protocol_id = 0 };
    const swim = ProtocolDescriptor{ .name = "swimmable", .methods = &[_]Value{value_mod.symbolValue("go")}, .protocol_id = 1 };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "a", .type_annotation = .{ .protocol = &fly } },
            .{ .name = "b", .type_annotation = .{ .protocol = &swim } },
        },
        .outputs = &[_]StackEffectParam{.{ .name = "o" }},
    };
    const markers = genericMarkers();
    try std.testing.expectEqual(@as(?BoundedDispatch, null), boundedDispatchFor(&effect, &markers, "go"));
}

test "boundedDispatchFor: concrete-type annotation returns null" {
    var tv = value_mod.TypeValue{ .name = "fixnum", .descriptor = null };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "x", .type_annotation = .{ .type = &tv } }},
        .outputs = &[_]StackEffectParam{.{ .name = "y" }},
    };
    const markers = genericMarkers();
    try std.testing.expectEqual(@as(?BoundedDispatch, null), boundedDispatchFor(&effect, &markers, "soar"));
}

test "boundedDispatchFor: more than two inputs returns null" {
    const pd = ProtocolDescriptor{ .name = "p", .methods = &[_]Value{value_mod.symbolValue("m")}, .protocol_id = 0 };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "a", .type_annotation = .{ .protocol = &pd } },
            .{ .name = "b", .type_annotation = .{ .protocol = &pd } },
            .{ .name = "c", .type_annotation = .{ .protocol = &pd } },
        },
        .outputs = &[_]StackEffectParam{.{ .name = "o" }},
    };
    const markers = genericMarkers();
    try std.testing.expectEqual(@as(?BoundedDispatch, null), boundedDispatchFor(&effect, &markers, "m"));
}

test "boundedDispatchFor: unannotated input returns null" {
    const pd = ProtocolDescriptor{ .name = "p", .methods = &[_]Value{value_mod.symbolValue("m")}, .protocol_id = 0 };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "a", .type_annotation = .{ .protocol = &pd } },
            .{ .name = "b" },
        },
        .outputs = &[_]StackEffectParam{.{ .name = "o" }},
    };
    const markers = genericMarkers();
    try std.testing.expectEqual(@as(?BoundedDispatch, null), boundedDispatchFor(&effect, &markers, "m"));
}

test "protocolRequiresMethod: skips stack-effect entries" {
    const empty = StackEffect{ .inputs = &.{}, .outputs = &.{} };
    const pd = ProtocolDescriptor{
        .name = "p",
        .methods = &[_]Value{ value_mod.symbolValue("m"), .{ .stack_effect = empty }, value_mod.symbolValue("n") },
        .protocol_id = 0,
    };
    try std.testing.expect(protocolRequiresMethod(&pd, "m"));
    try std.testing.expect(protocolRequiresMethod(&pd, "n"));
    try std.testing.expect(!protocolRequiresMethod(&pd, "missing"));
}

test "combinatorGuaranteesMethod: intersection needs one guaranteeing element" {
    const requires_m = ProtocolDescriptor{ .name = "a", .methods = &[_]Value{value_mod.symbolValue("m")}, .protocol_id = 0 };
    const requires_other = ProtocolDescriptor{ .name = "b", .methods = &[_]Value{value_mod.symbolValue("n")}, .protocol_id = 1 };
    const cc = ConstraintCombinator{
        .kind = .intersection,
        .elements = &[_]ConstraintCombinator.Element{ .{ .protocol = &requires_m }, .{ .protocol = &requires_other } },
        .combinator_id = 0,
    };
    // One element (`a`) requires `m`, so the intersection guarantees it.
    try std.testing.expect(combinatorGuaranteesMethod(&cc, "m"));
    // No element requires `missing`.
    try std.testing.expect(!combinatorGuaranteesMethod(&cc, "missing"));
}

test "combinatorGuaranteesMethod: union needs every element to guarantee" {
    const requires_m = ProtocolDescriptor{ .name = "a", .methods = &[_]Value{value_mod.symbolValue("m")}, .protocol_id = 0 };
    const also_m = ProtocolDescriptor{ .name = "b", .methods = &[_]Value{value_mod.symbolValue("m")}, .protocol_id = 1 };
    const not_m = ProtocolDescriptor{ .name = "c", .methods = &[_]Value{value_mod.symbolValue("n")}, .protocol_id = 2 };

    const both = ConstraintCombinator{
        .kind = .@"union",
        .elements = &[_]ConstraintCombinator.Element{ .{ .protocol = &requires_m }, .{ .protocol = &also_m } },
        .combinator_id = 0,
    };
    try std.testing.expect(combinatorGuaranteesMethod(&both, "m"));

    const one_misses = ConstraintCombinator{
        .kind = .@"union",
        .elements = &[_]ConstraintCombinator.Element{ .{ .protocol = &requires_m }, .{ .protocol = &not_m } },
        .combinator_id = 1,
    };
    try std.testing.expect(!combinatorGuaranteesMethod(&one_misses, "m"));
}

test "combinatorGuaranteesMethod: concrete-type element never guarantees" {
    var tv = value_mod.TypeValue{ .name = "fixnum", .descriptor = null };
    const requires_m = ProtocolDescriptor{ .name = "a", .methods = &[_]Value{value_mod.symbolValue("m")}, .protocol_id = 0 };
    // A union with a type element can never guarantee the method for the type arm.
    const u = ConstraintCombinator{
        .kind = .@"union",
        .elements = &[_]ConstraintCombinator.Element{ .{ .protocol = &requires_m }, .{ .type = &tv } },
        .combinator_id = 0,
    };
    try std.testing.expect(!combinatorGuaranteesMethod(&u, "m"));
    // But an intersection only needs the protocol arm to require it.
    const i = ConstraintCombinator{
        .kind = .intersection,
        .elements = &[_]ConstraintCombinator.Element{ .{ .protocol = &requires_m }, .{ .type = &tv } },
        .combinator_id = 1,
    };
    try std.testing.expect(combinatorGuaranteesMethod(&i, "m"));
}

test "boundedDispatchFor: combinator intersection bound by a guaranteeing element" {
    const requires_m = ProtocolDescriptor{ .name = "a", .methods = &[_]Value{value_mod.symbolValue("m")}, .protocol_id = 0 };
    const requires_n = ProtocolDescriptor{ .name = "b", .methods = &[_]Value{value_mod.symbolValue("n")}, .protocol_id = 1 };
    const cc = ConstraintCombinator{
        .kind = .intersection,
        .elements = &[_]ConstraintCombinator.Element{ .{ .protocol = &requires_m }, .{ .protocol = &requires_n } },
        .combinator_id = 0,
    };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "x", .type_annotation = .{ .combination = &cc } }},
        .outputs = &[_]StackEffectParam{.{ .name = "y" }},
    };
    const markers = genericMarkers();
    const result = boundedDispatchFor(&effect, &markers, "m").?;
    try std.testing.expectEqual(&cc, result.constraint.combinator);
    try std.testing.expectEqual(ProtocolArity.unary, result.arity);
}

test "boundedDispatchFor: non-guaranteeing union combinator returns null" {
    const requires_m = ProtocolDescriptor{ .name = "a", .methods = &[_]Value{value_mod.symbolValue("m")}, .protocol_id = 0 };
    const requires_n = ProtocolDescriptor{ .name = "b", .methods = &[_]Value{value_mod.symbolValue("n")}, .protocol_id = 1 };
    const cc = ConstraintCombinator{
        .kind = .@"union",
        .elements = &[_]ConstraintCombinator.Element{ .{ .protocol = &requires_m }, .{ .protocol = &requires_n } },
        .combinator_id = 0,
    };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "x", .type_annotation = .{ .combination = &cc } }},
        .outputs = &[_]StackEffectParam{.{ .name = "y" }},
    };
    const markers = genericMarkers();
    // `b` does not require `m`, so the union cannot guarantee `m`.
    try std.testing.expectEqual(@as(?BoundedDispatch, null), boundedDispatchFor(&effect, &markers, "m"));
}

test "boundedDispatchFor: mixed protocol and combinator bounds return null" {
    const requires_m = ProtocolDescriptor{ .name = "a", .methods = &[_]Value{value_mod.symbolValue("m")}, .protocol_id = 0 };
    const cc = ConstraintCombinator{
        .kind = .intersection,
        .elements = &[_]ConstraintCombinator.Element{.{ .protocol = &requires_m }},
        .combinator_id = 0,
    };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "a", .type_annotation = .{ .protocol = &requires_m } },
            .{ .name = "b", .type_annotation = .{ .combination = &cc } },
        },
        .outputs = &[_]StackEffectParam{.{ .name = "o" }},
    };
    const markers = genericMarkers();
    try std.testing.expectEqual(@as(?BoundedDispatch, null), boundedDispatchFor(&effect, &markers, "m"));
}

test "satisfiesAndDispatch raises protocol-error for a non-satisfying combinator operand" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const did = try defineGenericForTest(&ctx, "bump-it");
    const addable = try ctx.createProtocolDescriptor("addable", &[_]Value{value_mod.symbolValue("bump-it")});
    const cc = try ctx.createConstraintCombinator(.intersection, &[_]ConstraintCombinator.Element{.{ .protocol = addable }});

    // fixnum has no registered `bump-it`, so it does not satisfy `addable`.
    try ctx.stack.push(.{ .fixnum = 3 });
    const err = satisfiesAndDispatch(&ctx, did, .{ .combinator = cc }, .unary, "satisfies-and-dispatch[constraint]", null, 0);
    try std.testing.expectError(error.UserThrown, err);
}
