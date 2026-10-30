const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Instruction = value_mod.Instruction;
const Marker = value_mod.Marker;
const Value = value_mod.Value;
const Quotation = value_mod.Quotation;

const stack_effect_mod = @import("../stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;

const dictionary_mod = @import("../dictionary.zig");
const WordProvenance = dictionary_mod.WordProvenance;
const WordDefinition = dictionary_mod.WordDefinition;

const callable_mod = @import("../callable.zig");
const container_backing = @import("../container_backing.zig");
const MemoryLimitAllocator = @import("../memory_limit.zig").MemoryLimitAllocator;

const markers_mod = @import("markers.zig");
const may_define = @import("../may_define.zig");

const hooks = @import("hooks.zig");
const introspect = @import("introspect.zig");

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

const popQuotation = helpers.popQuotation;
const popBoolean = helpers.popBoolean;
const popSymbol = helpers.popSymbol;

/// The shape a `once` word's declared effect must have: nothing in, one concrete value out.
///
/// The bottom output `( -- * )` is the one other shape the count alone admits, since it is a
/// single output named `*`. An alternative like `( -- a | f )` stores the `|` as an output
/// parameter of its own, so the count already rejects it; the check below catches only the
/// degenerate `( -- | )`.
fn isOnceEffectShape(effect: StackEffect) bool {
    if (effect.inputs.len != 0) return false;
    if (effect.outputs.len != 1) return false;
    if (effect.outputs[0].is_row_variable) return false;
    if (effect.isBottomOutput()) return false;
    if (effect.hasAlternativeOutput()) return false;
    return true;
}

/// Move a `once` word's source body into a cell and return the cell, whose guard is the
/// two-instruction body that stands in for it: push the cell, call the native that forces it.
///
/// A cell the frame will own is allocated on the cross-worker allocator and dies with its last
/// reference. It takes over the caller's reference to `owner` once this returns, and releases it
/// when it dies. The caller decides which kind of cell this is with `frameMayOwnOnceCell`.
///
/// Any other cell is allocated on `alloc`, the definition's own allocator, which a module load
/// redirects to the root. Its lifetime is the root context's, a `reload` gets a fresh one, and
/// `owner` is borrowed from the teardown list.
fn installOnceCell(
    ctx: *Context,
    alloc: std.mem.Allocator,
    name: []const u8,
    body: []const Instruction,
    owner: ?*const value_mod.Closure,
    frame_owned: bool,
) !*value_mod.OnceCell {
    const line = if (body.len > 0) body[0].line else 0;
    const column = if (body.len > 0) body[0].column else 0;
    const calls_defining_native = may_define.bodyCallsDefiningNative(body);

    // A body the owner closure owns releases its own container literals when the closure is
    // destroyed, so the dictionary's release list must not name it as well.
    const closure_owns_body = if (owner) |closure| closure.ownsBodyTransitively() else false;

    if (frame_owned) {
        const cell = try value_mod.OnceCell.createFrameOwned(
            ctx.allocator,
            .{ .instructions = body },
            calls_defining_native,
            name,
            ctx.stateTarget().containerOwnerTag(),
            .{ .line = line, .column = column },
        );
        errdefer container_backing.releaseValue(.{ .once_cell = cell });

        if (!closure_owns_body) {
            ctx.unregisterQuotationContainerLiterals(body);
            try ctx.registerCompoundBody(body);
        }

        cell.owner = owner;
        return cell;
    }

    const cell = try alloc.create(value_mod.OnceCell);
    cell.* = .{
        .body = .{ .instructions = body },
        .owner = owner,
        .may_define = calls_defining_native,
        // The name is what a cycle diagnostic prints, so the cell keeps a copy of its own: the
        // caller's slice is parse-owned and `defineBinding` has not interned it yet.
        .name = try alloc.dupe(u8, name),
        // Whichever worker reads the word appends to the waiter list, so it cannot live on
        // `alloc`. That is an arena with a single owner.
        .allocator = ctx.allocator,
    };
    try ctx.registerOnceCell(cell);

    // The definition no longer stores the source body, so the ownership transfer
    // `defineWordLocked` would have performed for it happens here instead. Its captured
    // container literals are reachable only through the cell now.
    if (!closure_owns_body) {
        ctx.unregisterQuotationContainerLiterals(body);
        try ctx.registerCompoundBody(body);
    }

    const guard = try alloc.alloc(Instruction, 2);
    guard[0] = .{ .op = .{ .push_literal = .{ .once_cell = cell } }, .line = line, .column = column };
    guard[1] = .{ .op = .{ .call_word = "native.force-once" }, .line = line, .column = column };
    cell.guard = guard;
    return cell;
}

/// Check if a value is a definition descriptor, which is a hash or mutable-map with a `define:` quotation.
/// Used by `;` to recognize type-defining syntaxes like `struct{ ... }` or `virtual{ ... }`.
fn isDefinitionDescriptor(val: Value) bool {
    const define_val_opt: ?Value = switch (val) {
        .hash => |h| h.map.get("define"),
        .mutable_map => |m| m.map.get("define"),
        else => null,
    };

    if (define_val_opt) |define_val| {
        return switch (define_val) {
            .quotation, .closure => true,
            else => false,
        };
    }

    return false;
}

/// Get the underlying map from a definition descriptor. Both `hash` and
/// `mutable_map` ultimately store a `std.StringHashMapUnmanaged(Value)`;
/// each wrapper exposes it as `.map`.
fn getDescriptorMap(val: Value) ?*std.StringHashMapUnmanaged(Value) {
    return switch (val) {
        .hash => |h| &h.map,
        .mutable_map => |m| &m.map,
        else => null,
    };
}

/// Check if a word is a branch combinator by looking up its definition and
/// checking for the branch-combinator marker.
fn isBranchCombinator(ctx: *const Context, name: []const u8) bool {
    const word = ctx.lookupWord(name) orelse return false;
    for (word.markers) |mk| {
        if (markers_mod.isBranchCombinatorMarker(mk)) return true;
    }
    return false;
}

/// Return true if `name` appears as a `call_word` anywhere in the instruction
/// array, including inside nested quotation literals.
fn containsSelfCallAnywhere(instructions: []const Instruction, name: []const u8) bool {
    for (instructions) |instr| {
        switch (instr.op) {
            .call_word, .call_word_direct, .call_word_module => {
                const w = instr.op.callTargetName().?;
                if (std.mem.eql(u8, w, name)) return true;
            },
            .push_literal => |val| {
                switch (val) {
                    .quotation => |q| {
                        if (containsSelfCallAnywhere(q.instructions, name)) return true;
                    },
                    else => {},
                }
            },
        }
    }
    return false;
}

/// Return true if `name` appears in a non-tail self-call position within the
/// instruction array. Tail position propagates into quotation arguments of
/// branch combinators.
fn containsNonTailSelfCall(ctx: *const Context, instructions: []const Instruction, name: []const u8) bool {
    if (instructions.len == 0) return false;

    const last_idx = instructions.len - 1;
    const last_is_branch = switch (instructions[last_idx].op) {
        .call_word => |w| isBranchCombinator(ctx, w),
        .call_word_direct, .call_word_module => |slot| isBranchCombinator(ctx, slot.name),
        else => false,
    };

    for (instructions, 0..) |instr, i| {
        const is_last = (i == last_idx);
        switch (instr.op) {
            .call_word, .call_word_direct, .call_word_module => {
                const w = instr.op.callTargetName().?;
                if (std.mem.eql(u8, w, name)) {
                    if (!is_last) return true;
                    // Last instruction: tail self-call, not an error
                }
            },
            .push_literal => |val| {
                switch (val) {
                    .quotation => |q| {
                        if (is_last) {
                            // Last instruction is a quotation literal not followed
                            // by a branch combinator; any self-call inside is non-tail.
                            if (containsSelfCallAnywhere(q.instructions, name)) return true;
                        } else if (last_is_branch) {
                            // Quotation arg to a branch combinator: tail position
                            // propagates into it.
                            if (containsNonTailSelfCall(ctx, q.instructions, name)) return true;
                        } else {
                            // Not a branch combinator arg; any self-call is non-tail.
                            if (containsSelfCallAnywhere(q.instructions, name)) return true;
                        }
                    },
                    else => {},
                }
            },
        }
    }
    return false;
}

/// Bit flags for require-doc enforcement. The prelude validator maps level
/// names to a bitmask of these flags; Zig only checks the relevant bit.
const require_doc_normal: i64 = 1; // bit 0
const require_doc_parse_time: i64 = 2; // bit 1
const require_doc_type_descriptor: i64 = 4; // bit 2
const require_doc_marker: i64 = 8; // bit 3

pub fn nativeRedefinitionArityMismatchValidator(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    switch (val) {
        .string => |s| {
            if (std.mem.eql(u8, s.bytes, "error") or std.mem.eql(u8, s.bytes, "warning")) {
                try ctx.stack.push(.{ .string = s });
                try ctx.stack.push(.{ .boolean = true });
            } else {
                try ctx.stack.push(value_mod.stringValue("redefinition-arity-mismatch: expected \"error\" or \"warning\""));
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        else => {
            try ctx.stack.push(value_mod.stringValue("redefinition-arity-mismatch: expected \"error\" or \"warning\""));
            try ctx.stack.push(.{ .boolean = false });
        },
    }
}

/// Native validator for the callsite-arity-mismatch pragma.
pub fn nativeCallsiteArityMismatchValidator(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    switch (val) {
        .string => |s| {
            if (std.mem.eql(u8, s.bytes, "error") or std.mem.eql(u8, s.bytes, "warning") or std.mem.eql(u8, s.bytes, "off")) {
                try ctx.stack.push(.{ .string = s });
                try ctx.stack.push(.{ .boolean = true });
            } else {
                try ctx.stack.push(value_mod.stringValue("callsite-arity-mismatch: expected \"error\", \"warning\", or \"off\""));
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        else => {
            try ctx.stack.push(value_mod.stringValue("callsite-arity-mismatch: expected \"error\", \"warning\", or \"off\""));
            try ctx.stack.push(.{ .boolean = false });
        },
    }
}

/// Native validator for the type-check pragma.
pub fn nativeTypeCheckValidator(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    switch (val) {
        .string => |s| {
            if (std.mem.eql(u8, s.bytes, "error") or std.mem.eql(u8, s.bytes, "warning") or std.mem.eql(u8, s.bytes, "off")) {
                try ctx.stack.push(.{ .string = s });
                try ctx.stack.push(.{ .boolean = true });
            } else {
                try ctx.stack.push(value_mod.stringValue("type-check: expected \"error\", \"warning\", or \"off\""));
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        else => {
            try ctx.stack.push(value_mod.stringValue("type-check: expected \"error\", \"warning\", or \"off\""));
            try ctx.stack.push(.{ .boolean = false });
        },
    }
}

/// Native validator for the never-returns-consistency pragma.
pub fn nativeNeverReturnsConsistencyValidator(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    switch (val) {
        .string => |s| {
            if (std.mem.eql(u8, s.bytes, "error") or std.mem.eql(u8, s.bytes, "warning") or std.mem.eql(u8, s.bytes, "off")) {
                try ctx.stack.push(.{ .string = s });
                try ctx.stack.push(.{ .boolean = true });
            } else {
                try ctx.stack.push(value_mod.stringValue("never-returns-consistency: expected \"error\", \"warning\", or \"off\""));
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        else => {
            try ctx.stack.push(value_mod.stringValue("never-returns-consistency: expected \"error\", \"warning\", or \"off\""));
            try ctx.stack.push(.{ .boolean = false });
        },
    }
}

/// Native validator for the missing-default-arm pragma.
pub fn nativeMissingDefaultArmValidator(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    switch (val) {
        .string => |s| {
            if (std.mem.eql(u8, s.bytes, "error") or std.mem.eql(u8, s.bytes, "warning") or std.mem.eql(u8, s.bytes, "off")) {
                try ctx.stack.push(.{ .string = s });
                try ctx.stack.push(.{ .boolean = true });
            } else {
                try ctx.stack.push(value_mod.stringValue("missing-default-arm: expected \"error\", \"warning\", or \"off\""));
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        else => {
            try ctx.stack.push(value_mod.stringValue("missing-default-arm: expected \"error\", \"warning\", or \"off\""));
            try ctx.stack.push(.{ .boolean = false });
        },
    }
}

/// Native validator for the dictionary-shadow pragma, which relaxes the guard on a top-level
/// definition shadowing a prelude or native word.
pub fn nativeDictionaryShadowValidator(ctx: *Context) anyerror!void {
    return collisionGuardValidator(ctx, "dictionary-shadow");
}

/// Native validator for the import-collision pragma, which relaxes the guard on a definition and
/// an import landing on one name in one scope.
pub fn nativeImportCollisionValidator(ctx: *Context) anyerror!void {
    return collisionGuardValidator(ctx, "import-collision");
}

/// Shared validator for the two pragmas that relax a redefinition collision guard. These express a
/// user's preference for their own environment, so a set is accepted from the startup file and
/// from a REPL prompt and refused from a source file.
///
/// The set site is checked before the value, so a source file learns the rule rather than being
/// told its value is wrong when the value was never the problem.
fn collisionGuardValidator(ctx: *Context, comptime key: []const u8) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);

    if (!ctx.pragmaEnvironmentSetSite()) {
        try ctx.stack.push(value_mod.stringValue(key ++ ": may be set only from a startup file or a REPL prompt, not from a source file"));
        try ctx.stack.push(.{ .boolean = false });
        return;
    }

    if (collisionGuardValueOk(val)) {
        try ctx.stack.push(val);
        try ctx.stack.push(.{ .boolean = true });
        return;
    }

    try ctx.stack.push(value_mod.stringValue(key ++ ": expected \"error\", \"warning\", \"off\", or an array of word-name symbols"));
    try ctx.stack.push(.{ .boolean = false });
}

/// A severity word, or an allowlist of word names.
///
/// Names are symbols because a word name is a symbol everywhere else in the language, and because
/// it keeps an allowlist from reading like a severity.
///
/// An empty allowlist is legal and allows nothing, which is what an unset key already means.
fn collisionGuardValueOk(val: Value) bool {
    switch (val) {
        .string => |s| return std.mem.eql(u8, s.bytes, "error") or
            std.mem.eql(u8, s.bytes, "warning") or
            std.mem.eql(u8, s.bytes, "off"),
        .array => |a| {
            for (a.items) |item| {
                if (item != .symbol) return false;
            }
            return true;
        },
        else => return false,
    }
}

/// Native validator for the lint-suppress pragma, which names the linter rules a file opts out of.
///
/// Nothing at runtime reads the value back. The linter finds it by scanning the file's tokens, so
/// this only keeps a file carrying the pragma loadable, and holds the value to the shape that scan
/// understands. Rule ids are not checked here, because only the linter knows which rules exist.
pub fn nativeLintSuppressValidator(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);

    const ok = switch (val) {
        .array => |a| for (a.items) |item| {
            if (item != .symbol) break false;
        } else true,
        else => false,
    };

    if (ok) {
        try ctx.stack.push(val);
        try ctx.stack.push(.{ .boolean = true });
        return;
    }

    try ctx.stack.push(value_mod.stringValue("lint-suppress: expected an array of rule-id symbols, such as { non-kebab-case: }"));
    try ctx.stack.push(.{ .boolean = false });
}

/// Native validator for the require-doc pragma. Maps level names to the bitmask
/// consumed by enforceRequireDoc. Follows the same push-value/t or push-error/f
/// protocol as the other pragma validators.
pub fn nativeRequireDocValidator(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    switch (val) {
        .boolean => |b| {
            try ctx.stack.push(.{ .fixnum = if (b) require_doc_normal else 0 });
            try ctx.stack.push(.{ .boolean = true });
        },
        .string => |s| {
            const level: ?i64 = if (std.mem.eql(u8, s.bytes, "relaxed"))
                0
            else if (std.mem.eql(u8, s.bytes, "standard"))
                require_doc_normal
            else if (std.mem.eql(u8, s.bytes, "strict"))
                require_doc_normal | require_doc_parse_time | require_doc_type_descriptor
            else if (std.mem.eql(u8, s.bytes, "pedantic"))
                require_doc_normal | require_doc_parse_time | require_doc_type_descriptor | require_doc_marker
            else
                null;

            if (level) |l| {
                try ctx.stack.push(.{ .fixnum = l });
                try ctx.stack.push(.{ .boolean = true });
            } else {
                try ctx.stack.push(value_mod.stringValue("require-doc: expected t, f, or one of relaxed, standard, strict, pedantic"));
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        else => {
            try ctx.stack.push(value_mod.stringValue("require-doc: expected t, f, or one of relaxed, standard, strict, pedantic"));
            try ctx.stack.push(.{ .boolean = false });
        },
    }
}

/// The pragma value is an integer bitmask set by the native validator.
fn enforceRequireDoc(ctx: *Context, name: []const u8, has_doc: bool, is_parse_time: bool, is_type_descriptor: bool, is_marker: bool) anyerror!void {
    if (has_doc) return;

    const pragma_val = ctx.getPragma("require-doc") orelse return;
    const mask = switch (pragma_val) {
        .fixnum => |n| n,
        else => return,
    };

    const bit = if (is_marker)
        require_doc_marker
    else if (is_type_descriptor)
        require_doc_type_descriptor
    else if (is_parse_time)
        require_doc_parse_time
    else
        require_doc_normal;

    if (mask & bit == 0) return;

    const alloc = ctx.quotationAllocator();
    ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = "missing-doc-comment",
        .message = std.fmt.allocPrint(alloc, "word '{s}' defined without a doc-comment", .{name}) catch "word defined without a doc-comment",
    });
    return error.UserThrown;
}

pub const primitives = [_]Primitive{
    .{ .name = "call", .stack_effect = "..a quot: ( ..a -- ..b ) -- ..b", .doc = "Execute a quotation.", .func = nativeCall, .effect_transparent = true },
    .{ .name = ";", .stack_effect = "name quot --", .doc = "Define a new word.", .func = nativeSemicolon, .defines_word = true },
    .{ .name = "t", .stack_effect = "-- t", .doc = "Push true.", .func = nativeTrue },
    .{ .name = "f", .stack_effect = "-- f", .doc = "Push false.", .func = nativeFalse },
    .{ .name = "if", .stack_effect = "..a ? true-quot: ( ..a -- ..b ) false-quot: ( ..a -- ..b ) -- ..b", .doc = "Conditional execution.", .func = nativeIf, .markers = &.{@constCast(&markers_mod.branch_combinator_marker)} },
};

/// call ( quot -- )
///
/// Runs in a new local frame, so locals defined inside stay scoped to the call.
pub fn nativeCall(ctx: *Context) anyerror!void {
    // Hold the popped reference across execution: for a closure it is what
    // keeps the body alive while it runs.
    const pc = try popQuotation(ctx);
    defer pc.release();
    try pc.executeWithFrame(ctx);
}

/// Markers `;` collects on the stack before it spills to the heap. A definition rarely carries more.
const scratch_marker_slots = 16;
const scratch_marker_bytes = scratch_marker_slots * @sizeOf(*Marker);

/// Scratch space for the markers `;` collects. Spills onto the state target's heap allocator, never
/// its arena, so the list is gone once the definition is made. The caller takes the allocator from
/// its own local copy, since the buffer lives inside the returned value.
fn markerScratchFallback(ctx: *Context) std.heap.StackFallbackAllocator(scratch_marker_bytes) {
    return std.heap.stackFallback(scratch_marker_bytes, ctx.stateTarget().allocator);
}

fn hasMarker(list: []const *Marker, marker: *const Marker) bool {
    for (list) |mk| {
        if (mk == marker) return true;
    }

    return false;
}

/// ; ( name: quot -- ) or ( name: value -- ) or ( name: marker -- )
///
/// Polymorphic definition, depending on TOS type, with optional metadata:
///
/// - Quotation: define word
/// - Value: define word that pushes value, e.g., constant
/// - Marker: register as named marker
pub fn nativeSemicolon(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const top_val = try ctx.stack.pop();
    switch (top_val) {
        // Weird case of defining a marker, where the definition looks like:
        //
        //   name: marker ;
        //
        // The `marker` actually creates a new marker, but isn't tied back to
        // the name until the semicolon is executed.
        .marker => |marker| {
            // TODO(ripta): check for duplicate markers?
            var doc_val: ?[]const u8 = null;
            while (true) {
                const next_val = try ctx.stack.peek();
                switch (next_val) {
                    .doc_string => |d| {
                        try ctx.stack.popAndRelease();
                        doc_val = d;
                    },
                    .symbol => break,
                    else => {
                        helpers.setTypeMismatchError(ctx, "symbol before marker definition", next_val);
                        return error.TypeMismatch;
                    },
                }
            }

            const name_pay = try popSymbol(ctx);
            defer container_backing.releaseValue(.{ .symbol = name_pay });
            const name = name_pay.bytes;
            try enforceRequireDoc(ctx, name, doc_val != null, false, false, true);

            // Naming writes into the marker, so analysis may name only a marker its own load owner
            // made. The check runs ahead of the binding so a refused name leaves no trace.
            if (marker.name.len == 0) try ctx.checkWrite(marker.owner, "a marker");

            // User-defined markers are automatically parse-time so they work
            // correctly with parse-time constructs like struct{}.
            const interned = try ctx.defineBinding(name, WordDefinition{
                .name = name,
                .doc = doc_val,
                .parse_time = true,
                .action = .{ .literal = top_val },
            });

            // Tag the marker with its name. This is just for identification
            // purposes, and doesn't affect identity or equality checks.
            //
            // Only an anonymous marker takes the name. A marker that already carries one, such as
            // a well-known marker, is bound under the new name and keeps its own, because the
            // interned slice lives in the table of the context running this definition and a
            // marker shared beyond that context must not borrow it.
            //
            // TODO(ripta): This mutates the marker in place, which is not ideal,
            //              but probably acceptable for now.
            if (marker.name.len == 0) marker.name = interned;
            fireWordDefinedHook(ctx, alloc, interned);
        },

        else => {
            // Owned until a branch transfers it: into the descriptor consumer's slot, or into the word action.
            var top_owned = true;
            errdefer if (top_owned) container_backing.releaseValue(top_val);

            if (isDefinitionDescriptor(top_val)) {
                const desc_map = getDescriptorMap(top_val) orelse {
                    helpers.setErrorContext(ctx, "definition descriptor has no accessible map", .{});
                    return error.TypeMismatch;
                };

                var scratch_fallback = markerScratchFallback(ctx);
                const scratch = scratch_fallback.get();
                var collected_markers = std.ArrayListUnmanaged(*Marker){};
                defer collected_markers.deinit(scratch);
                var captured_doc: ?[]const u8 = null;

                while (true) {
                    const next_val = try ctx.stack.peek();
                    switch (next_val) {
                        .marker => |mk| {
                            try ctx.stack.popAndRelease();
                            try collected_markers.append(scratch, mk);
                        },
                        .doc_string => |d| {
                            try ctx.stack.popAndRelease();
                            if (captured_doc == null) captured_doc = d;
                        },
                        .symbol => break,
                        else => {
                            helpers.setTypeMismatchError(ctx, "symbol, marker, or doc-string before type definition", next_val);
                            return error.TypeMismatch;
                        },
                    }
                }

                const name = try popSymbol(ctx);
                var name_owned = true;
                errdefer if (name_owned) container_backing.releaseValue(.{ .symbol = name });
                try enforceRequireDoc(ctx, name.bytes, captured_doc != null, false, true, false);
                if (captured_doc) |doc_text| {
                    if (!desc_map.contains("doc")) {
                        const map_alloc = switch (top_val) {
                            .mutable_map => |m| m.header.allocator,
                            .hash => |h| h.header.allocator,
                            else => alloc,
                        };
                        const key_copy = try map_alloc.dupe(u8, "doc");
                        try desc_map.put(map_alloc, key_copy, .{ .doc_string = doc_text });
                    }
                }
                try ctx.stack.pushMoved(.{ .symbol = name });
                name_owned = false;

                // Move ownership of `top_val` into the slot the consumer
                // will pop. `pop` (line 294) already transferred the prior
                // slot's reference to this local; pushing via `pushMoved`
                // forwards that same reference into the new slot without
                // an extra retain. The consumer's `releaseValue` on its
                // descriptor local then balances the original creation.
                try ctx.stack.pushMoved(top_val);
                top_owned = false;

                const markers_array = try alloc.alloc(Value, collected_markers.items.len);
                for (collected_markers.items, 0..) |mk, i| {
                    markers_array[i] = .{ .marker = mk };
                }
                try helpers.pushAdoptedArray(ctx, alloc, markers_array);

                const define_val = desc_map.get("define") orelse return error.MissingField;
                const define_quot = (try helpers.asQuotationStamped(ctx, define_val)) orelse {
                    helpers.setTypeMismatchError(ctx, "quotation for definition descriptor 'define' field", define_val);
                    return error.TypeMismatch;
                };
                // The descriptor's own reference now lives in the slot this body pops, and the body
                // releases it, so `define_val` is borrowed out of a map its own execution can free.
                //
                // Hold a reference of our own for the call: a body the value's closure owns
                // resolves off that closure, which has to outlive the run.
                container_backing.retainValue(define_val);
                defer container_backing.releaseValue(define_val);
                try ctx.executeQuotationWithOwner(define_quot, callable_mod.ownerClosureOf(define_val));
            } else {
                // Fall back to normal word definition
                var stack_effect_val: ?*const StackEffect = null;
                var doc_val: ?[]const u8 = null;
                var scratch_fallback = markerScratchFallback(ctx);
                const scratch = scratch_fallback.get();
                var collected_markers = std.ArrayListUnmanaged(*Marker){};
                defer collected_markers.deinit(scratch);
                // A definition whose body resolves to a single constraint value
                // becomes a parse-time const that pushes it, so the name is
                // usable in annotation positions. This covers named composed
                // protocols and mixed unions (constraint combinators), bare
                // protocol aliases, and the existing named type-union case.
                // Bare concrete-type aliases (a plain type-val without member
                // types) keep their prior runtime-word behavior.
                const is_named_constraint = top_val == .constraint_combinator or
                    top_val == .protocol_descriptor or
                    (top_val == .type_val and top_val.type_val.member_types != null);

                // Extract stack effect from the quotation's (or promoted closure's) .effect
                // field if present
                const top_effect: ?*const StackEffect = switch (top_val) {
                    .quotation => |q| q.effect,
                    .closure => |c| c.effect,
                    else => null,
                };

                // The definition holds the state target's interned copy rather than the value's
                // effect. One parsed body is executed once per scope that loads it, so the same
                // parse-owned effect would otherwise be reached by definitions on arenas that
                // outlive each other in either order. Interning also keeps a definition made on
                // every call of a word from adding a copy per call.
                if (top_effect) |eff| stack_effect_val = try ctx.internStackEffect(eff.*);

                while (true) {
                    const next_val = try ctx.stack.peek();
                    switch (next_val) {
                        .marker => |mk| {
                            try ctx.stack.popAndRelease();
                            try collected_markers.append(scratch, mk);
                        },
                        .doc_string => |d| {
                            try ctx.stack.popAndRelease();
                            doc_val = d;
                        },
                        .stack_effect => |eff| {
                            try ctx.stack.popAndRelease();
                            if (stack_effect_val == null) {
                                stack_effect_val = try ctx.internStackEffect(eff);
                            }
                        },
                        .symbol => break,
                        else => {
                            helpers.setTypeMismatchError(ctx, "symbol, marker, or doc-string before word definition", next_val);
                            return error.TypeMismatch;
                        },
                    }
                }

                const name_pay = try popSymbol(ctx);
                defer container_backing.releaseValue(.{ .symbol = name_pay });
                const name = name_pay.bytes;

                const has_parse_time = for (collected_markers.items) |mk| {
                    if (mk == @as(*const Marker, &markers_mod.parse_time_marker)) break true;
                } else false;

                const has_parse_time_only = for (collected_markers.items) |mk| {
                    if (mk == @as(*const Marker, &markers_mod.parse_time_only_marker)) break true;
                } else false;

                try enforceRequireDoc(ctx, name, doc_val != null, has_parse_time or has_parse_time_only, is_named_constraint, false);

                // The closure behind a closure-bodied definition, so the word body resolves off the
                // value the way the same body would when it is invoked as one.
                var body_owner: ?*const value_mod.Closure = null;

                // The cell behind a `once` definition. The caller's reference to a frame-owned
                // one is ours until the definition installs, which hands it to the frame.
                var once_cell: ?*value_mod.OnceCell = null;
                var once_cell_owned: ?*value_mod.OnceCell = null;
                errdefer if (once_cell_owned) |cell| container_backing.releaseValue(.{ .once_cell = cell });

                const has_once = for (collected_markers.items) |mk| {
                    if (markers_mod.isOnceMarker(mk)) break true;
                } else false;

                // Only a quotation or closure body can contain a self-call: the non-quotation
                // branch stores the bound value directly and allocates no instructions at all,
                // so containsNonTailSelfCall below is only ever meaningful for the
                // .quotation/.closure case.
                var action: WordDefinition.Action = switch (top_val) {
                    .quotation => |quot| .{ .compound = quot.instructions },
                    // A closure is a quotation literal promoted at push time because it closed over
                    // an outer local, or a curry/compose product (see `Context.captureQuotationScope`
                    // and `nativeCurry`). Without this arm it would fall to the bound-value branch
                    // below, which would store the closure as a `.literal` -- turning the defined
                    // word into one that pushes the closure as a constant instead of calling it.
                    //
                    // The word borrows the closure's body, so the popped reference has to outlive
                    // every call of the word. The definition decides who holds it: the frame
                    // when the closure cannot reach a container, the dictionary's teardown list
                    // otherwise. A `once` definition hands the reference to its cell below.
                    .closure => |c| blk: {
                        body_owner = c;
                        break :blk .{ .compound = c.instructions };
                    },
                    else => .{ .literal = top_val },
                };

                // Read off the markers the definition declared. The extensions below append to the
                // same scratch list, and these answers are about what the source wrote.
                const has_stack_recursive = for (collected_markers.items) |mk| {
                    if (markers_mod.isStackRecursiveMarker(mk)) break true;
                } else false;

                if (is_named_constraint) {
                    const implied = [_]*Marker{
                        @constCast(&markers_mod.parse_time_marker),
                        @constCast(&markers_mod.const_marker),
                        @constCast(&markers_mod.typed_marker),
                    };

                    for (implied) |marker| {
                        if (hasMarker(collected_markers.items, marker)) continue;
                        try collected_markers.append(scratch, marker);
                    }
                }

                if (action == .compound and !ctx.allow_all_recursion and containsNonTailSelfCall(ctx, action.compound, name)) {
                    if (has_stack_recursive) {
                        try collected_markers.append(scratch, @constCast(&markers_mod.recursive_non_tco_marker));
                    } else {
                        helpers.setErrorContext(ctx, "word '{s}' contains a non-tail self-call", .{name});
                        helpers.setErrorHint(ctx, "add the 'stack-recursive' marker if intentional");
                        return error.NonTailRecursion;
                    }
                }

                // `defineWordLocked` applies the same rules to every definer, this one included, so
                // the check here is about order rather than reach. It runs ahead of the `once`
                // rules below so `once inline` reports the combination rather than the effect
                // shape, and so a rejected definition never installs a once cell on its way out.
                if (markers_mod.inlineViolation(collected_markers.items)) |violation| return violation.raise(ctx);

                if (has_once) {
                    if (action != .compound) {
                        helpers.setErrorContext(ctx, "'once' needs a quotation body; a bracket-less binding is already computed once at module load", .{});
                        return error.InvalidOnceDefinition;
                    }

                    if (stack_effect_val) |eff| {
                        if (!isOnceEffectShape(eff.*)) {
                            var buf: [256]u8 = undefined;
                            var fbs = std.io.fixedBufferStream(&buf);
                            eff.write(fbs.writer()) catch {};
                            helpers.setErrorContext(
                                ctx,
                                "a 'once' word must declare ( -- value ); '{s}' declares {s}",
                                .{ name, fbs.getWritten() },
                            );
                            return error.InvalidOnceDefinition;
                        }
                    }

                    // The frame owns the cell when the definition lands in a transient frame and
                    // the closure cannot reach a container. Otherwise the cell stays on the
                    // arena, and the closure is pinned to teardown as any other closure is.
                    const frame_owned_cell = ctx.frameMayOwnOnceCell(body_owner);
                    if (body_owner != null and !frame_owned_cell) {
                        try ctx.retainValueForTeardown(top_val);
                        top_owned = false;
                    }

                    const cell = try installOnceCell(ctx, alloc, name, action.compound, body_owner, frame_owned_cell);
                    if (frame_owned_cell) {
                        // The cell holds the popped closure reference from here on, and the
                        // caller's reference to the cell goes to the frame once the definition
                        // installs.
                        if (body_owner != null) top_owned = false;
                        once_cell_owned = cell;
                    }

                    action = .{ .compound = cell.guard };
                    once_cell = cell;

                    // The guard did not come out of the closure the source body did, so the
                    // definition stops naming one. The cell carries the owner to each attempt to
                    // force.
                    body_owner = null;
                }

                const markers_slice = try ctx.internMarkerList(collected_markers.items);

                const definition = WordDefinition{
                    .name = name,
                    .parse_time = has_parse_time or has_parse_time_only or is_named_constraint,
                    .parse_time_only = has_parse_time_only,
                    .stack_effect = stack_effect_val,
                    .markers = markers_slice,
                    .doc = doc_val,
                    .body_owner = body_owner,
                    .once_cell = once_cell,
                    .action = action,
                };

                // A closure body whose reference is still ours is handed to the definition, which
                // decides whether the frame or the teardown list holds it.
                const interned = if (body_owner != null)
                    try ctx.defineBindingAdoptingOwner(name, definition)
                else
                    try ctx.defineBinding(name, definition);

                // The definition now holds the popped reference. Until it does, every failure
                // between the pop and here -- a const or arity rejection, or an allocation
                // failure -- still has to release it.
                top_owned = false;
                once_cell_owned = null;
                fireWordDefinedHook(ctx, alloc, interned);
            }
        },
    }
}

fn fireWordDefinedHook(ctx: *Context, alloc: std.mem.Allocator, name: []const u8) void {
    if (!hooks.hasScopedHooks(ctx, "word-defined-hooks")) return;
    if (ctx.lookupWord(name)) |word_def| {
        const info = introspect.buildWordInfo(alloc, ctx, name, word_def) catch return;
        defer container_backing.releaseValue(info);
        hooks.fireScopedHooks(ctx, "word-defined-hooks", &.{info});
    }
}

pub fn nativeTrue(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .boolean = true });
}

pub fn nativeFalse(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .boolean = false });
}

/// if ( ? true-quot false-quot -- )
///
/// Uses executeQuotationInline so tail calls in branches propagate to the
/// enclosing word's TCO loop (e.g., times -> if -> [... times] tail-calls).
pub fn nativeIf(ctx: *Context) anyerror!void {
    const false_quot = try popQuotation(ctx);
    defer false_quot.release();
    const true_quot = try popQuotation(ctx);
    defer true_quot.release();
    const cond = try popBoolean(ctx);
    try (if (cond) true_quot else false_quot).executeInline(ctx);
}

test "semicolon defines named union type as parse-time word" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const bignum_tv = ctx.lookupBuiltinTypeValue("bignum").?;
    const float_tv = ctx.lookupBuiltinTypeValue("float").?;
    const union_tv = try ctx.getOrCreateAnonymousUnionTypeValue(&.{ fixnum_tv, bignum_tv, float_tv });

    try ctx.stack.push(value_mod.symbolValue("number"));
    try ctx.stack.push(.{ .type_val = union_tv });
    try nativeSemicolon(&ctx);

    const word = ctx.lookupWord("number") orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(word.parse_time);

    const has_parse_time = for (word.markers) |mk| {
        if (mk == @as(*const Marker, &markers_mod.parse_time_marker)) break true;
    } else false;
    const has_const = for (word.markers) |mk| {
        if (mk == @as(*const Marker, &markers_mod.const_marker)) break true;
    } else false;
    const has_typed = for (word.markers) |mk| {
        if (mk == @as(*const Marker, &markers_mod.typed_marker)) break true;
    } else false;

    try std.testing.expect(has_parse_time);
    try std.testing.expect(has_const);
    try std.testing.expect(has_typed);

    switch (word.action) {
        .literal => |v| {
            try std.testing.expect(v == .type_val);
            try std.testing.expect(v.type_val == union_tv);
        },
        .compound, .native, .host_callback => try std.testing.expect(false),
    }
}

test "semicolon copies the declared effect onto its own arena, parameters included" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Stands in for the parse that produced the quotation, whose arena is not the definition's.
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer parse_arena.deinit();

    const nested = try stack_effect_mod.box(parse_arena.allocator(), .{ .inputs = &.{}, .outputs = &.{} });
    const parse_effect = try stack_effect_mod.box(parse_arena.allocator(), .{
        .inputs = try parse_arena.allocator().dupe(stack_effect_mod.StackEffectParam, &.{
            .{ .name = "q", .quotation_effect = nested },
        }),
        .outputs = try parse_arena.allocator().dupe(stack_effect_mod.StackEffectParam, &.{.{ .name = "b" }}),
    });

    try ctx.stack.push(value_mod.symbolValue("effect-owner"));
    try ctx.stack.push(.{ .quotation = .{ .instructions = &.{}, .effect = parse_effect } });
    try nativeSemicolon(&ctx);

    const effect = (ctx.lookupWord("effect-owner") orelse return error.TestExpectedWord).stack_effect.?;
    try std.testing.expect(effect != parse_effect);
    try std.testing.expect(effect.inputs.ptr != parse_effect.inputs.ptr);
    try std.testing.expect(effect.inputs[0].quotation_effect.? != nested);

    // Everything read past here would be the parse's memory had the copy been shallow.
    parse_arena.deinit();

    try std.testing.expectEqualStrings("q", effect.inputs[0].name);
    try std.testing.expectEqualStrings("b", effect.outputs[0].name);
    try std.testing.expectEqual(@as(usize, 0), effect.inputs[0].quotation_effect.?.inputs.len);
}

test "semicolon interned effect owns its parameter names" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer parse_arena.deinit();
    const parse_alloc = parse_arena.allocator();

    const nested_inputs = try parse_alloc.dupe(stack_effect_mod.StackEffectParam, &.{.{ .name = try parse_alloc.dupe(u8, "inner") }});
    const nested = try stack_effect_mod.box(parse_alloc, .{ .inputs = nested_inputs, .outputs = &.{} });
    const parse_effect = try stack_effect_mod.box(parse_alloc, .{
        .inputs = try parse_alloc.dupe(stack_effect_mod.StackEffectParam, &.{
            .{ .name = try parse_alloc.dupe(u8, "quot"), .quotation_effect = nested },
        }),
        .outputs = try parse_alloc.dupe(stack_effect_mod.StackEffectParam, &.{.{ .name = try parse_alloc.dupe(u8, "out") }}),
    });

    try defineEmptyBody(&ctx, "owned-names", parse_effect, &.{});
    parse_arena.deinit();

    const effect = (ctx.lookupWord("owned-names") orelse return error.TestExpectedWord).stack_effect.?;
    try std.testing.expectEqualStrings("quot", effect.inputs[0].name);
    try std.testing.expectEqualStrings("out", effect.outputs[0].name);
    try std.testing.expectEqualStrings("inner", effect.inputs[0].quotation_effect.?.inputs[0].name);
}

test "semicolon shares one effect box between definitions whose effects are equal" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;

    const first = StackEffect{
        .inputs = &.{.{ .name = "x", .type_annotation = .{ .type = fixnum_tv } }},
        .outputs = &.{.{ .name = "x" }},
    };
    const equal = StackEffect{
        .inputs = &.{.{ .name = "x", .type_annotation = .{ .type = fixnum_tv } }},
        .outputs = &.{.{ .name = "x" }},
    };
    const other_annotation = StackEffect{
        .inputs = &.{.{ .name = "x", .type_annotation = .{ .type = string_tv } }},
        .outputs = &.{.{ .name = "x" }},
    };
    const no_annotation = StackEffect{
        .inputs = &.{.{ .name = "x" }},
        .outputs = &.{.{ .name = "x" }},
    };
    const other_name = StackEffect{
        .inputs = &.{.{ .name = "y", .type_annotation = .{ .type = fixnum_tv } }},
        .outputs = &.{.{ .name = "x" }},
    };

    try defineEmptyBody(&ctx, "shared-a", &first, &.{});
    try defineEmptyBody(&ctx, "shared-b", &equal, &.{});
    try defineEmptyBody(&ctx, "shared-c", &other_annotation, &.{});
    try defineEmptyBody(&ctx, "shared-d", &no_annotation, &.{});
    try defineEmptyBody(&ctx, "shared-e", &other_name, &.{});

    const a = ctx.lookupWord("shared-a").?.stack_effect.?;
    try std.testing.expect(a != &first);
    try std.testing.expectEqual(a, ctx.lookupWord("shared-b").?.stack_effect.?);
    try std.testing.expect(a != ctx.lookupWord("shared-c").?.stack_effect.?);
    try std.testing.expect(a != ctx.lookupWord("shared-d").?.stack_effect.?);
    try std.testing.expect(a != ctx.lookupWord("shared-e").?.stack_effect.?);
    try std.testing.expectEqual(string_tv, ctx.lookupWord("shared-c").?.stack_effect.?.inputs[0].type_annotation.?.type);
}

test "semicolon shares one marker slice between definitions whose markers are equal" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const typed: *Marker = @constCast(&markers_mod.typed_marker);
    const constant: *Marker = @constCast(&markers_mod.const_marker);

    try defineEmptyBody(&ctx, "marked-a", null, &.{ typed, constant });
    try defineEmptyBody(&ctx, "marked-b", null, &.{ typed, constant });
    try defineEmptyBody(&ctx, "marked-c", null, &.{ constant, typed });

    const a = ctx.lookupWord("marked-a").?.markers;
    try std.testing.expectEqual(@as(usize, 2), a.len);
    try std.testing.expectEqual(a.ptr, ctx.lookupWord("marked-b").?.markers.ptr);
    try std.testing.expect(a.ptr != ctx.lookupWord("marked-c").?.markers.ptr);
}

test "semicolon keeps every marker when a definition carries more than the scratch list holds" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var storage: [scratch_marker_slots + 4]Marker = undefined;
    var markers: [storage.len]*Marker = undefined;
    for (&storage, &markers) |*marker, *slot| {
        marker.* = .{ .name = "many" };
        slot.* = marker;
    }

    try defineEmptyBody(&ctx, "many-markers", null, &markers);

    const defined = ctx.lookupWord("many-markers").?.markers;
    try std.testing.expectEqualSlices(*Marker, &markers, defined);
}

test "semicolon adds the named-constraint markers to the one interned slice" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const bignum_tv = ctx.lookupBuiltinTypeValue("bignum").?;
    const union_tv = try ctx.getOrCreateAnonymousUnionTypeValue(&.{ fixnum_tv, bignum_tv });

    for ([_][]const u8{ "constraint-a", "constraint-b" }) |name| {
        try ctx.stack.push(value_mod.symbolValue(name));
        try ctx.stack.push(.{ .type_val = union_tv });
        try nativeSemicolon(&ctx);
    }

    const a = ctx.lookupWord("constraint-a").?.markers;
    try std.testing.expectEqual(@as(usize, 3), a.len);
    try std.testing.expectEqual(a.ptr, ctx.lookupWord("constraint-b").?.markers.ptr);
}

test "redefining a typed and marked word across many calls adds no durable growth per call" {
    const multi_param = StackEffect{
        .inputs = &.{ .{ .name = "a" }, .{ .name = "b" } },
        .outputs = &.{ .{ .name = "c" }, .{ .name = "d" } },
    };
    const typed: *Marker = @constCast(&markers_mod.typed_marker);
    const deprecated: *Marker = @constCast(&markers_mod.deprecated_marker);

    const iterations: usize = 8_192;
    const plain_growth = try redefinitionSecondBatchGrowth(null, &.{}, iterations);
    const effect_growth = try redefinitionSecondBatchGrowth(&multi_param, &.{}, iterations);
    const marker_growth = try redefinitionSecondBatchGrowth(null, &.{ typed, deprecated }, iterations);
    const both_growth = try redefinitionSecondBatchGrowth(&multi_param, &.{ typed, deprecated }, iterations);

    // The slack absorbs arena chunk boundaries.
    const slack: usize = 64 * 1024;
    try std.testing.expect(effect_growth < plain_growth + slack);
    try std.testing.expect(marker_growth < plain_growth + slack);
    try std.testing.expect(both_growth < plain_growth + slack);
}

fn defineEmptyBody(ctx: *Context, name: []const u8, effect: ?*const StackEffect, markers: []const *Marker) !void {
    try ctx.stack.push(value_mod.symbolValue(name));

    // `;` collects markers from the top of the stack down, so the list is pushed last first.
    var remaining = markers.len;
    while (remaining > 0) {
        remaining -= 1;
        try ctx.stack.push(.{ .marker = markers[remaining] });
    }

    try ctx.stack.push(.{ .quotation = .{ .instructions = &.{}, .effect = effect } });
    try nativeSemicolon(ctx);
}

/// Bytes the tracked allocator grows by over a second batch of `iterations` redefinitions of one
/// word, after a first batch of the same size has absorbed the one-time costs.
fn redefinitionSecondBatchGrowth(effect: ?*const StackEffect, markers: []const *Marker, iterations: usize) !usize {
    var mem_limit = MemoryLimitAllocator.init(std.testing.allocator, 0);
    var ctx = Context.init(mem_limit.allocator());
    defer ctx.deinit();

    var i: usize = 0;
    while (i < iterations) : (i += 1) try defineEmptyBody(&ctx, "redefined", effect, markers);
    const mid_bytes = mem_limit.currentBytes();

    while (i < 2 * iterations) : (i += 1) try defineEmptyBody(&ctx, "redefined", effect, markers);

    return mem_limit.currentBytes() -| mid_bytes;
}

test "fireWordDefinedHook skips buildWordInfo when no word-defined-hooks are registered" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(value_mod.symbolValue("foo"));
    try ctx.stack.push(.{ .fixnum = 42 });
    try nativeSemicolon(&ctx);

    const before_end = ctx.arena.state.end_index;
    const before_node = ctx.arena.state.buffer_list.first;

    fireWordDefinedHook(&ctx, ctx.quotationAllocator(), "foo");

    try std.testing.expectEqual(before_end, ctx.arena.state.end_index);
    try std.testing.expectEqual(before_node, ctx.arena.state.buffer_list.first);
}

test "fireWordDefinedHook still builds and fires WordInfo when word-defined-hooks are registered" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(value_mod.symbolValue("foo"));
    try ctx.stack.push(.{ .fixnum = 42 });
    try nativeSemicolon(&ctx);

    const alloc = ctx.quotationAllocator();

    // A hook must leave the stack as it found it, so this one moves its argument into a vector.
    const log = try value_mod.Vector.create(ctx.allocator, ctx.containerOwnerTag());
    defer log.header.release();
    const hook_body = try alloc.alloc(Instruction, 4);
    hook_body[0] = .{ .op = .{ .push_literal = .{ .vector = log } }, .line = 0 };
    hook_body[1] = .{ .op = .{ .call_word = "swap" }, .line = 0 };
    hook_body[2] = .{ .op = .{ .call_word = "#push!" }, .line = 0 };
    hook_body[3] = .{ .op = .{ .call_word = "drop" }, .line = 0 };

    const hook_items = try alloc.alloc(Value, 1);
    hook_items[0] = .{ .quotation = .{ .instructions = hook_body } };
    const hook_arr = try value_mod.Array.fromOwnedSlice(alloc, hook_items, 0);
    try ctx.setParameterInTopFrame("word-defined-hooks", .{ .array = hook_arr });

    fireWordDefinedHook(&ctx, alloc, "foo");

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
    try std.testing.expectEqual(@as(usize, 1), log.list.items.len);
    const info = log.list.items[0];
    try std.testing.expect(info == .array);
    try std.testing.expect(info.array.items[0] == .string);
    try std.testing.expectEqualStrings("foo", info.array.items[0].string.bytes);
}

/// Define `name` through `;` with the `once` marker, an optional declared effect, and `body`.
fn defineOnce(
    ctx: *Context,
    name: []const u8,
    effect: ?StackEffect,
    body: []const Instruction,
) anyerror!void {
    try defineOnceValue(ctx, name, effect, .{ .quotation = .{ .instructions = body } });
}

fn defineOnceValue(ctx: *Context, name: []const u8, effect: ?StackEffect, body: Value) anyerror!void {
    try ctx.stack.push(value_mod.symbolValue(name));
    if (effect) |eff| try ctx.stack.push(.{ .stack_effect = eff });
    try ctx.stack.push(.{ .marker = @constCast(&markers_mod.once_marker) });
    try ctx.stack.push(body);
    try nativeSemicolon(ctx);
}

fn onceCellOf(ctx: *Context, name: []const u8) !*value_mod.OnceCell {
    const word = ctx.lookupWord(name) orelse return error.TestExpectedWord;
    return switch (word.action) {
        .compound => |instrs| instrs[0].op.push_literal.once_cell,
        else => error.TestExpectedCompound,
    };
}

fn oneOutputParam(name: []const u8) [1]stack_effect_mod.StackEffectParam {
    return [1]stack_effect_mod.StackEffectParam{.{ .name = name }};
}

test "semicolon moves a once word's body into a cell and stores the guard in its place" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // A `;` at the body's top level, so the cell records that forcing needs a lexical frame.
    const source = [_]Instruction{
        .{ .op = .{ .push_literal = value_mod.symbolValue("i") }, .line = 3 },
        .{ .op = .{ .push_literal = .{ .fixnum = 4 } }, .line = 3 },
        .{ .op = .{ .call_word = ";" }, .line = 3 },
        .{ .op = .{ .call_word = "i" }, .line = 4 },
    };
    const outputs = oneOutputParam("v");
    try defineOnce(&ctx, "held", .{ .inputs = &.{}, .outputs = &outputs }, &source);

    const word = ctx.lookupWord("held") orelse return error.TestExpectedWord;
    const stored = switch (word.action) {
        .compound => |instrs| instrs,
        else => return error.TestExpectedCompound,
    };

    try std.testing.expectEqual(@as(usize, 2), stored.len);
    try std.testing.expect(stored[0].op == .push_literal);
    try std.testing.expect(stored[0].op.push_literal == .once_cell);
    try std.testing.expectEqualStrings("native.force-once", stored[1].op.call_word);
    // The guard reports the source body's first line, so a frame it pushes names the definition.
    try std.testing.expectEqual(@as(usize, 3), stored[0].line);

    const cell = stored[0].op.push_literal.once_cell;
    try std.testing.expectEqual(source.len, cell.body.instructions.len);
    try std.testing.expectEqual(@as(?*const value_mod.Closure, null), cell.owner);
    try std.testing.expect(cell.may_define);
    try std.testing.expectEqual(value_mod.OnceCell.State.cold, cell.state.load(.acquire));
    try std.testing.expectEqualStrings("held", cell.name);

    // The declared effect stays on the definition, so help and word-info report what was written.
    const effect = word.stack_effect orelse return error.TestExpectedEffect;
    try std.testing.expectEqual(@as(usize, 0), effect.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), effect.outputs.len);
}

test "semicolon rejects a once word whose declared effect is not ( -- value )" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const body = [_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 }};

    const inputs = oneOutputParam("a");
    const outputs = oneOutputParam("b");
    try std.testing.expectError(
        error.InvalidOnceDefinition,
        defineOnce(&ctx, "takes-input", .{ .inputs = &inputs, .outputs = &outputs }, &body),
    );
    try std.testing.expectEqualStrings(
        "a 'once' word must declare ( -- value ); 'takes-input' declares ( a -- b )",
        ctx.pending_error_message.?,
    );
    ctx.stack.clear();

    try std.testing.expectError(
        error.InvalidOnceDefinition,
        defineOnce(&ctx, "no-output", .{ .inputs = &.{}, .outputs = &.{} }, &body),
    );
    ctx.stack.clear();

    const bottom = [1]stack_effect_mod.StackEffectParam{.{ .name = "*" }};
    try std.testing.expectError(
        error.InvalidOnceDefinition,
        defineOnce(&ctx, "bottom", .{ .inputs = &.{}, .outputs = &bottom }, &body),
    );
    ctx.stack.clear();

    const row = [1]stack_effect_mod.StackEffectParam{.{ .name = "..a", .is_row_variable = true }};
    try std.testing.expectError(
        error.InvalidOnceDefinition,
        defineOnce(&ctx, "row", .{ .inputs = &row, .outputs = &outputs }, &body),
    );
    ctx.stack.clear();

    // The accepted shape defines, so the rejections above are the marker's rule rather than a
    // blanket refusal.
    const ok = oneOutputParam("v");
    try defineOnce(&ctx, "fine", .{ .inputs = &.{}, .outputs = &ok }, &body);
    try std.testing.expect(ctx.lookupWord("fine") != null);
}

test "semicolon rejects once on a bracket-less binding" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(value_mod.symbolValue("eager"));
    try ctx.stack.push(.{ .marker = @constCast(&markers_mod.once_marker) });
    try ctx.stack.push(.{ .fixnum = 5 });

    try std.testing.expectError(error.InvalidOnceDefinition, nativeSemicolon(&ctx));
    try std.testing.expectEqualStrings(
        "'once' needs a quotation body; a bracket-less binding is already computed once at module load",
        ctx.pending_error_message.?,
    );
    try std.testing.expect(ctx.lookupWord("eager") == null);
}

const once_probe_body = [_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 1 }};

test "a once word defined in a transient frame is owned by the frame and freed when it pops" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const outputs = oneOutputParam("v");
    const effect: StackEffect = .{ .inputs = &.{}, .outputs = &outputs };

    try ctx.pushLocalFrame();
    try defineOnce(&ctx, "held", effect, &once_probe_body);

    const word = ctx.lookupWord("held") orelse return error.TestExpectedWord;
    const cell = try onceCellOf(&ctx, "held");
    try std.testing.expect(word.frame_owned);
    try std.testing.expect(cell.frame_owned);
    try std.testing.expectEqual(word.once_cell, cell);
    try std.testing.expectEqual(@as(u32, 1), cell.header.refcountValue());
    try std.testing.expectEqual(@as(usize, 0), ctx.dictionary.once_cells.items.len);

    // The guard names its cell, and the cell names its guard.
    try std.testing.expectEqual(cell.guard.ptr, word.action.compound.ptr);

    // The testing allocator reports the cell, its name, and its guard if the pop leaves any.
    ctx.popLocalFrame();
}

test "rebinding a frame-owned once word in the same frame frees the displaced cell" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const outputs = oneOutputParam("v");
    const effect: StackEffect = .{ .inputs = &.{}, .outputs = &outputs };

    try ctx.pushLocalFrame();
    try defineOnce(&ctx, "held", effect, &once_probe_body);
    try defineOnce(&ctx, "held", effect, &once_probe_body);

    ctx.popLocalFrame();
}

test "a once word defined outside a transient frame keeps its arena cell on the teardown list" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const outputs = oneOutputParam("v");
    try defineOnce(&ctx, "held", .{ .inputs = &.{}, .outputs = &outputs }, &once_probe_body);

    const word = ctx.lookupWord("held") orelse return error.TestExpectedWord;
    const cell = try onceCellOf(&ctx, "held");
    try std.testing.expect(!word.frame_owned);
    try std.testing.expect(!cell.frame_owned);
    try std.testing.expectEqual(@as(usize, 1), ctx.dictionary.once_cells.items.len);
}

test "a once body that captures a leaf is frame-owned and its cell owns the closure" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const outputs = oneOutputParam("v");
    const effect: StackEffect = .{ .inputs = &.{}, .outputs = &outputs };

    const cl = try value_mod.Closure.create(std.testing.allocator, .{
        .instructions = &once_probe_body,
        .segments = &.{},
        .header = undefined,
    }, ctx.containerOwnerTag());
    defer container_backing.releaseValue(.{ .closure = cl });

    try ctx.pushLocalFrame();

    // The push takes the reference `;` pops, and the cell takes it over.
    try defineOnceValue(&ctx, "held", effect, .{ .closure = cl });
    try std.testing.expectEqual(@as(u32, 2), cl.header.refcountValue());

    const cell = try onceCellOf(&ctx, "held");
    try std.testing.expect(cell.frame_owned);
    try std.testing.expectEqual(@as(?*const value_mod.Closure, cl), cell.owner);
    try std.testing.expect(cl.frame_owned_body);
    try std.testing.expect(ctx.lookupWord("held").?.body_owner == null);

    ctx.popLocalFrame();
    try std.testing.expectEqual(@as(u32, 1), cl.header.refcountValue());
}

test "a once body that captures a container is pinned at definition" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const outputs = oneOutputParam("v");
    const effect: StackEffect = .{ .inputs = &.{}, .outputs = &outputs };

    const items = try std.testing.allocator.alloc(Value, 1);
    items[0] = .{ .fixnum = 1 };
    const arr = try value_mod.Array.fromOwnedSlice(std.testing.allocator, items, 0);
    defer container_backing.releaseValue(.{ .array = arr });

    // A curry product shape: the closure owns a body that carries the container.
    const boxed = try std.testing.allocator.alloc(Instruction, 1);
    boxed[0] = .{ .op = .{ .push_literal = .{ .array = arr } }, .line = 1 };
    container_backing.retainValue(.{ .array = arr });

    const cl = try value_mod.Closure.create(std.testing.allocator, .{
        .instructions = boxed,
        .segments = &.{},
        .owns_body = true,
        .header = undefined,
    }, ctx.containerOwnerTag());
    defer container_backing.releaseValue(.{ .closure = cl });

    try ctx.pushLocalFrame();
    try defineOnceValue(&ctx, "held", effect, .{ .closure = cl });

    // The closure did not qualify, so the cell stays on the arena and the closure on the teardown
    // list, which is what the definition did before cells could be frame-owned.
    const cell = try onceCellOf(&ctx, "held");
    try std.testing.expect(!cell.frame_owned);
    try std.testing.expect(!cl.frame_owned_body);
    try std.testing.expect(!ctx.lookupWord("held").?.frame_owned);
    try std.testing.expectEqual(@as(usize, 1), ctx.dictionary.once_cells.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.dictionary.retained_values.items.len);

    ctx.popLocalFrame();
}

/// Define `name` through `;` with `marks` and `body`, a quotation body when `body` is given and a
/// bare fixnum binding when it is not.
fn defineMarked(
    ctx: *Context,
    name: []const u8,
    marks: []const *const Marker,
    body: ?[]const Instruction,
) anyerror!void {
    try ctx.stack.push(value_mod.symbolValue(name));
    for (marks) |mk| try ctx.stack.push(.{ .marker = @constCast(mk) });
    if (body) |instrs| {
        try ctx.stack.push(.{ .quotation = .{ .instructions = instrs } });
    } else {
        try ctx.stack.push(.{ .fixnum = 7 });
    }
    try nativeSemicolon(ctx);
}

test "semicolon rejects inline without const" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try std.testing.expectError(
        error.InvalidInlineDefinition,
        defineMarked(&ctx, "bare", &.{&markers_mod.inline_marker}, &.{}),
    );
    try std.testing.expectEqualStrings(
        "'inline' needs 'const'; a redefinition would strand the copies expansion made in its callers",
        ctx.pending_error_message.?,
    );
    try std.testing.expect(ctx.lookupWord("bare") == null);
    ctx.stack.clear();

    // A bare binding is an inline candidate too, so the rule reaches it rather than only a body.
    try std.testing.expectError(
        error.InvalidInlineDefinition,
        defineMarked(&ctx, "bare-binding", &.{&markers_mod.inline_marker}, null),
    );
    try std.testing.expect(ctx.lookupWord("bare-binding") == null);
}

test "semicolon rejects inline beside a marker it cannot combine with" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const forbidden = [_]*const Marker{
        &markers_mod.generic_marker,
        &markers_mod.once_marker,
        &markers_mod.dynamic_compile_marker,
        &markers_mod.dynamic_eval_marker,
        &markers_mod.dynamic_load_marker,
        &markers_mod.dynamic_quotation_construction_marker,
        &markers_mod.interpreter_dependent_marker,
    };

    for (forbidden) |mk| {
        try std.testing.expectError(
            error.InvalidInlineDefinition,
            defineMarked(&ctx, "clashing", &.{ &markers_mod.const_marker, &markers_mod.inline_marker, mk }, &.{}),
        );
        try std.testing.expect(ctx.lookupWord("clashing") == null);
        ctx.stack.clear();
    }

    try std.testing.expectError(
        error.InvalidInlineDefinition,
        defineMarked(&ctx, "held", &.{ &markers_mod.const_marker, &markers_mod.inline_marker, &markers_mod.once_marker }, &.{}),
    );
    try std.testing.expectEqualStrings(
        "cannot combine 'once' and 'inline': an inlined body has no boundary to check its single output at",
        ctx.pending_error_message.?,
    );
    ctx.stack.clear();

    // A conflict is reported even with no `const` to add, so the combination is what the author is
    // told about first.
    try std.testing.expectError(
        error.InvalidInlineDefinition,
        defineMarked(&ctx, "both-wrong", &.{ &markers_mod.inline_marker, &markers_mod.generic_marker }, &.{}),
    );
    try std.testing.expectEqualStrings(
        "cannot combine 'generic' and 'inline': dispatch picks the body by argument type at the call",
        ctx.pending_error_message.?,
    );
}

test "semicolon accepts const inline on a body and on a bare binding" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const marks = [_]*const Marker{ &markers_mod.const_marker, &markers_mod.inline_marker };

    try defineMarked(&ctx, "doubled", &marks, &.{});
    try std.testing.expect(ctx.lookupWord("doubled") != null);

    try defineMarked(&ctx, "width", &marks, null);
    const bound = ctx.lookupWord("width") orelse return error.TestExpectedWord;
    switch (bound.action) {
        .literal => |v| try std.testing.expectEqual(@as(i64, 7), v.fixnum),
        .compound, .native, .host_callback => try std.testing.expect(false),
    }

    // A marker with no rule against it still defines, so the rejections above are the two rules
    // rather than a blanket refusal of anything beside `inline`.
    try defineMarked(&ctx, "flagged", &.{ &markers_mod.const_marker, &markers_mod.inline_marker, &markers_mod.deprecated_marker }, &.{});
    try std.testing.expect(ctx.lookupWord("flagged") != null);
}

test "semicolon accepts inline on a named constraint, whose const is added for it" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const float_tv = ctx.lookupBuiltinTypeValue("float").?;
    const union_tv = try ctx.getOrCreateAnonymousUnionTypeValue(&.{ fixnum_tv, float_tv });

    try ctx.stack.push(value_mod.symbolValue("number"));
    try ctx.stack.push(.{ .marker = @constCast(&markers_mod.inline_marker) });
    try ctx.stack.push(.{ .type_val = union_tv });
    try nativeSemicolon(&ctx);

    const word = ctx.lookupWord("number") orelse return error.TestExpectedWord;
    const has_const = for (word.markers) |mk| {
        if (markers_mod.isConstMarker(mk)) break true;
    } else false;

    // The rule asks that the definition be const, not that its author spell it. Reading the
    // author's markers alone would reject this word for lacking the marker it is about to carry.
    try std.testing.expect(has_const);
}

test "semicolon binds a non-refcounted plain value as .literal, with no instruction allocation" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(value_mod.symbolValue("x"));
    try ctx.stack.push(.{ .fixnum = 5 });
    try nativeSemicolon(&ctx);

    const word = ctx.lookupWord("x") orelse return error.TestExpectedWord;
    switch (word.action) {
        .literal => |v| {
            try std.testing.expect(v == .fixnum);
            try std.testing.expectEqual(@as(i64, 5), v.fixnum);
        },
        .compound, .native, .host_callback => try std.testing.expect(false),
    }

    const body = [_]Instruction{.{ .op = .{ .call_word = "x" }, .line = 0 }};
    try ctx.executeQuotation(.{ .instructions = &body });

    const result = try ctx.stack.pop();
    try std.testing.expect(result == .fixnum);
    try std.testing.expectEqual(@as(i64, 5), result.fixnum);
}

test "semicolon binds a container-backed plain value as .literal at durable scope" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const alloc = ctx.quotationAllocator();
    const elements = try alloc.alloc(Value, 1);
    elements[0] = .{ .fixnum = 7 };
    const arr = try value_mod.Array.fromOwnedSlice(alloc, elements, 0);

    try ctx.stack.push(value_mod.symbolValue("xs"));
    try ctx.stack.push(.{ .array = arr });
    try nativeSemicolon(&ctx);

    const word = ctx.lookupWord("xs") orelse return error.TestExpectedWord;
    switch (word.action) {
        .literal => |v| try std.testing.expect(v == .array),
        .compound, .native, .host_callback => try std.testing.expect(false),
    }
    // A durable binding has no frame to reclaim its reference, so the dictionary holds it.
    try std.testing.expect(!word.frame_owned);

    const body = [_]Instruction{.{ .op = .{ .call_word = "xs" }, .line = 0 }};
    try ctx.executeQuotation(.{ .instructions = &body });

    const result = try ctx.stack.pop();
    defer container_backing.releaseValue(result);
    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 1), result.array.items.len);
    try std.testing.expectEqual(@as(i64, 7), result.array.items[0].fixnum);
}

test "semicolon marker-definition branch keeps the name a marker already carries" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var marker: Marker = .{ .name = "original" };

    try ctx.stack.push(value_mod.symbolValue("alias"));
    try ctx.stack.push(.{ .marker = &marker });
    try nativeSemicolon(&ctx);

    try std.testing.expectEqualStrings("original", marker.name);

    const word = ctx.lookupWord("alias") orelse return error.TestExpectedWord;
    try std.testing.expectEqualStrings("alias", word.name);
    try std.testing.expect(word.action == .literal);
    try std.testing.expectEqual(&marker, word.action.literal.marker);
}

test "semicolon marker-definition branch binds the tagged marker as .literal" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var marker: Marker = .{ .name = "" };

    try ctx.stack.push(value_mod.symbolValue("my-marker"));
    try ctx.stack.push(.{ .marker = &marker });
    try nativeSemicolon(&ctx);

    try std.testing.expectEqualStrings("my-marker", marker.name);

    const word = ctx.lookupWord("my-marker") orelse return error.TestExpectedWord;
    try std.testing.expectEqual(word.name.ptr, marker.name.ptr);
    try std.testing.expect(word.parse_time);
    switch (word.action) {
        .literal => |v| {
            try std.testing.expect(v == .marker);
            try std.testing.expectEqual(&marker, v.marker);
        },
        .compound, .native, .host_callback => try std.testing.expect(false),
    }

    const body = [_]Instruction{.{ .op = .{ .call_word = "my-marker" }, .line = 0 }};
    try ctx.executeQuotation(.{ .instructions = &body });

    const result = try ctx.stack.pop();
    try std.testing.expect(result == .marker);
    try std.testing.expectEqual(&marker, result.marker);
}

test "word with a scalar-valued named local does not blow up arena memory across many repeated calls" {
    var mem_limit = MemoryLimitAllocator.init(std.testing.allocator, 0);
    var ctx = Context.init(mem_limit.allocator());
    defer ctx.deinit();

    const call_body = [_]Instruction{.{ .op = .{ .call_word = "a" }, .line = 0 }};

    var i: usize = 0;
    while (i < 57_344) : (i += 1) {
        try ctx.stack.push(value_mod.symbolValue("a"));
        try ctx.stack.push(.{ .fixnum = @as(i64, @intCast(i)) });
        try nativeSemicolon(&ctx);
        try ctx.executeQuotation(.{ .instructions = &call_body });
        _ = try ctx.stack.pop();
    }
    const mid_bytes = mem_limit.currentBytes();

    while (i < 114_688) : (i += 1) {
        try ctx.stack.push(value_mod.symbolValue("a"));
        try ctx.stack.push(.{ .fixnum = @as(i64, @intCast(i)) });
        try nativeSemicolon(&ctx);
        try ctx.executeQuotation(.{ .instructions = &call_body });
        _ = try ctx.stack.pop();
    }
    const end_bytes = mem_limit.currentBytes();

    // A word that redefines a fixnum-valued named local on every call used to allocate a fresh
    // push_literal Instruction from the arena on top of the dictionary's own per-redefinition
    // WordDefinition box; both accumulated for the life of the Context, so tens of thousands of
    // calls at a nonzero local count could exhaust a real memory cap.
    //
    // The literal-eligible path drops the Instruction allocation entirely, leaving only the
    // dictionary's own fixed per-redefinition cost, so the second batch should cost only a small,
    // roughly constant amount -- nowhere near a cap a real workload would hit.
    const second_batch_growth = end_bytes - mid_bytes;
    try std.testing.expect(second_batch_growth < 32 * 1024 * 1024);
}

test "rebinding a named local across many repeated calls retains the name once whatever its length" {
    // Two contexts run the same rebind loop, one with a one-byte name and one with a 64-byte name.
    // The name used to be duped onto the context arena on every rebind, so the long name cost 63
    // more bytes per iteration. Interned, both loops cost the dictionary's own fixed
    // per-redefinition amount, and the name once.
    const short_name = "a";
    const long_name = "a-sixty-four-byte-local-binding-name-that-this-test-rebinds-here";
    try std.testing.expectEqual(@as(usize, 64), long_name.len);

    const iterations: usize = 8_192;
    const short_growth = try rebindSecondBatchGrowth(short_name, iterations);
    const long_growth = try rebindSecondBatchGrowth(long_name, iterations);

    const name_bytes = (long_name.len - short_name.len) * iterations;
    try std.testing.expect(long_growth < short_growth + name_bytes / 2);
}

/// Bytes the tracked allocator grows by over a second batch of `iterations` rebind-and-call rounds
/// of `name`, after a first batch of the same size has absorbed the one-time costs.
fn rebindSecondBatchGrowth(name: []const u8, iterations: usize) !usize {
    var mem_limit = MemoryLimitAllocator.init(std.testing.allocator, 0);
    var ctx = Context.init(mem_limit.allocator());
    defer ctx.deinit();

    const call_body = [_]Instruction{.{ .op = .{ .call_word = name }, .line = 0 }};

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        try ctx.stack.push(value_mod.symbolValue(name));
        try ctx.stack.push(.{ .fixnum = @as(i64, @intCast(i)) });
        try nativeSemicolon(&ctx);
        try ctx.executeQuotation(.{ .instructions = &call_body });
        _ = try ctx.stack.pop();
    }
    const mid_bytes = mem_limit.currentBytes();

    while (i < 2 * iterations) : (i += 1) {
        try ctx.stack.push(value_mod.symbolValue(name));
        try ctx.stack.push(.{ .fixnum = @as(i64, @intCast(i)) });
        try nativeSemicolon(&ctx);
        try ctx.executeQuotation(.{ .instructions = &call_body });
        _ = try ctx.stack.pop();
    }

    try std.testing.expectEqual(@as(usize, 1), ctx.binding_names.count());
    return mem_limit.currentBytes() -| mid_bytes;
}

test "word with a container-bound named local documents the accepted residual leak across repeated calls" {
    var mem_limit = MemoryLimitAllocator.init(std.testing.allocator, 0);
    var ctx = Context.init(mem_limit.allocator());
    defer ctx.deinit();

    const arr_alloc = ctx.quotationAllocator();
    const elements = try arr_alloc.alloc(Value, 1);
    elements[0] = .{ .fixnum = 1 };
    const arr = try value_mod.Array.fromOwnedSlice(arr_alloc, elements, 0);

    const call_body = [_]Instruction{.{ .op = .{ .call_word = "b" }, .line = 0 }};

    // Deliberately smaller than the scalar-local test's 114,688-call scale: this path keeps
    // allocating for real on every call (see below), so the full scale runs an order of magnitude
    // slower here and would push this single test close to the per-test-case timeout. 8,192 calls
    // per batch is still large enough to show a clear, stable per-call rate.
    var i: usize = 0;
    while (i < 8_192) : (i += 1) {
        try ctx.stack.push(value_mod.symbolValue("b"));
        try ctx.stack.push(.{ .array = arr });
        try nativeSemicolon(&ctx);
        try ctx.executeQuotation(.{ .instructions = &call_body });
        const result = try ctx.stack.pop();
        container_backing.releaseValue(result);
    }
    const first_batch_bytes = mem_limit.currentBytes();

    while (i < 16_384) : (i += 1) {
        try ctx.stack.push(value_mod.symbolValue("b"));
        try ctx.stack.push(.{ .array = arr });
        try nativeSemicolon(&ctx);
        try ctx.executeQuotation(.{ .instructions = &call_body });
        const result = try ctx.stack.pop();
        container_backing.releaseValue(result);
    }
    const second_batch_bytes = mem_limit.currentBytes() - first_batch_bytes;

    // An array is excluded from the literal-eligible path (container_backing.valueCarriesBacking
    // is true for it), so this word keeps taking the older push_instr path: every redefinition
    // still allocates a fresh Instruction and retains a reference to `arr` that is never released
    // until Context teardown. This is a documented, accepted residual leak, not a bug this test is
    // meant to catch -- both batches are expected to grow by a real, comparable amount.
    //
    // What the second assertion actually guards is the leak *rate*: the second batch should cost a
    // similar amount to the first, not dramatically more. A future change that makes this leak
    // materially worse would blow through the multiplicative band below, which is the signal that
    // a real fix for the container-bound case is overdue.
    try std.testing.expect(first_batch_bytes > 0);
    try std.testing.expect(second_batch_bytes > 0);
    try std.testing.expect(second_batch_bytes < first_batch_bytes * 3);
}

fn defineAndCallLiteral(ctx: *Context, name: []const u8, v: Value) !Value {
    try ctx.stack.push(value_mod.symbolValue(name));
    try ctx.stack.push(v);
    try nativeSemicolon(ctx);

    const word = ctx.lookupWord(name) orelse return error.TestExpectedWord;
    switch (word.action) {
        .literal => {},
        .compound, .native, .host_callback => return error.TestUnexpectedActionKind,
    }

    const body = [_]Instruction{.{ .op = .{ .call_word = name }, .line = 0 }};
    try ctx.executeQuotation(.{ .instructions = &body });
    return try ctx.stack.pop();
}

fn defineAndCallForcedCompound(ctx: *Context, name: []const u8, v: Value) !Value {
    const alloc = ctx.quotationAllocator();
    const instrs = try alloc.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .push_literal = v }, .line = 0 };
    try ctx.defineWord(name, WordDefinition{ .name = name, .action = .{ .compound = instrs } });

    const body = [_]Instruction{.{ .op = .{ .call_word = name }, .line = 0 }};
    try ctx.executeQuotation(.{ .instructions = &body });
    return try ctx.stack.pop();
}

test "spot-check: representative unverified pointer types round-trip identically as .literal and as forced .compound" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // bignum
    {
        var big = try value_mod.BigIntManaged.initSet(std.testing.allocator, 42);
        defer big.deinit();
        const v: Value = .{ .bignum = .{ .big = &big } };

        const literal_result = try defineAndCallLiteral(&ctx, "spot-bignum-lit", v);
        try std.testing.expect(literal_result == .bignum);
        try std.testing.expectEqual(&big, literal_result.bignum.big);

        const compound_result = try defineAndCallForcedCompound(&ctx, "spot-bignum-cmp", v);
        try std.testing.expect(compound_result == .bignum);
        try std.testing.expectEqual(&big, compound_result.bignum.big);
    }

    // parameter
    {
        var param: value_mod.Parameter = .{ .name = "p", .default_quotation = .{ .instructions = &.{} } };
        const v: Value = .{ .parameter = &param };

        const literal_result = try defineAndCallLiteral(&ctx, "spot-param-lit", v);
        try std.testing.expect(literal_result == .parameter);
        try std.testing.expectEqual(&param, literal_result.parameter);

        const compound_result = try defineAndCallForcedCompound(&ctx, "spot-param-cmp", v);
        try std.testing.expect(compound_result == .parameter);
        try std.testing.expectEqual(&param, compound_result.parameter);
    }

    // resource
    {
        var resource: value_mod.Resource = .{ .type_name = "r" };
        const v: Value = .{ .resource = &resource };

        const literal_result = try defineAndCallLiteral(&ctx, "spot-resource-lit", v);
        try std.testing.expect(literal_result == .resource);
        try std.testing.expectEqual(&resource, literal_result.resource);

        const compound_result = try defineAndCallForcedCompound(&ctx, "spot-resource-cmp", v);
        try std.testing.expect(compound_result == .resource);
        try std.testing.expectEqual(&resource, compound_result.resource);
    }

    // struct_type
    {
        var struct_type: value_mod.StructType = .{ .name = "s", .fields = &.{} };
        const v: Value = .{ .struct_type = &struct_type };

        const literal_result = try defineAndCallLiteral(&ctx, "spot-structtype-lit", v);
        try std.testing.expect(literal_result == .struct_type);
        try std.testing.expectEqual(&struct_type, literal_result.struct_type);

        const compound_result = try defineAndCallForcedCompound(&ctx, "spot-structtype-cmp", v);
        try std.testing.expect(compound_result == .struct_type);
        try std.testing.expectEqual(&struct_type, compound_result.struct_type);
    }

    // closure -- the one exception in this list. `;` treats a `.closure` the same as a
    // `.quotation`: the defined word becomes a compound word running the closure's own
    // instructions, not a `.literal` constant pushing the closure value itself. A closure
    // presents as a quotation everywhere else in the language (dispatch, equality, inspect), so it
    // does not round-trip through the literal path the other pointer types above do; calling it
    // runs its body instead of yielding the closure value back.
    {
        const closure_instrs = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 99 } }, .line = 0 }};
        const closure = try value_mod.Closure.create(std.testing.allocator, .{
            .instructions = closure_instrs,
            .segments = &.{},
            .header = undefined,
        }, 0);
        const v: Value = .{ .closure = closure };
        // Drop the creation reference once the definition's adopted reference
        // is the only intended owner.
        defer container_backing.releaseValue(v);

        try ctx.stack.push(value_mod.symbolValue("spot-closure-compound"));
        try ctx.stack.push(v);
        try nativeSemicolon(&ctx);

        const word = ctx.lookupWord("spot-closure-compound") orelse return error.TestExpectedWord;
        switch (word.action) {
            .compound => |instrs| try std.testing.expectEqual(closure_instrs, instrs),
            .literal, .native, .host_callback => return error.TestUnexpectedActionKind,
        }

        const body = [_]Instruction{.{ .op = .{ .call_word = "spot-closure-compound" }, .line = 0 }};
        try ctx.executeQuotation(.{ .instructions = &body });
        const result = try ctx.stack.pop();
        try std.testing.expect(result == .fixnum);
        try std.testing.expectEqual(@as(i64, 99), result.fixnum);
    }

    // module
    {
        var module: value_mod.Module = .{ .name = "m", .words = .{} };
        const v: Value = .{ .module = &module };

        const literal_result = try defineAndCallLiteral(&ctx, "spot-module-lit", v);
        try std.testing.expect(literal_result == .module);
        try std.testing.expectEqual(&module, literal_result.module);

        const compound_result = try defineAndCallForcedCompound(&ctx, "spot-module-cmp", v);
        try std.testing.expect(compound_result == .module);
        try std.testing.expectEqual(&module, compound_result.module);
    }

    // type_val
    {
        const type_val = ctx.lookupBuiltinTypeValue("fixnum") orelse return error.TestExpectedTypeValue;
        const v: Value = .{ .type_val = type_val };

        const literal_result = try defineAndCallLiteral(&ctx, "spot-typeval-lit", v);
        try std.testing.expect(literal_result == .type_val);
        try std.testing.expectEqual(type_val, literal_result.type_val);

        const compound_result = try defineAndCallForcedCompound(&ctx, "spot-typeval-cmp", v);
        try std.testing.expect(compound_result == .type_val);
        try std.testing.expectEqual(type_val, compound_result.type_val);
    }
}
