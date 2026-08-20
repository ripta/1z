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

const container_backing = @import("../container_backing.zig");
const MemoryLimitAllocator = @import("../memory_limit.zig").MemoryLimitAllocator;

const markers_mod = @import("markers.zig");

const hooks = @import("hooks.zig");
const introspect = @import("introspect.zig");

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

const popQuotation = helpers.popQuotation;
const popBoolean = helpers.popBoolean;
const popSymbol = helpers.popSymbol;

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
    .{ .name = ";", .stack_effect = "name quot --", .doc = "Define a new word.", .func = nativeSemicolon },
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
    try ctx.executeQuotationWithFrame(pc.quot);
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
            var has_doc = false;
            while (true) {
                const next_val = try ctx.stack.peek();
                switch (next_val) {
                    .doc_string => {
                        try ctx.stack.popAndRelease();
                        has_doc = true;
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
            try enforceRequireDoc(ctx, name, has_doc, false, false, true);
            const name_copy = try alloc.dupe(u8, name);

            // Tag the marker with its name. This is just for identification
            // purposes, and doesn't affect identity or equality checks.
            //
            // TODO(ripta): This mutates the marker in place, which is not ideal,
            //              but probably acceptable for now.
            marker.name = name_copy;

            // User-defined markers are automatically parse-time so they work
            // correctly with parse-time constructs like struct{}.
            try ctx.defineWord(name_copy, WordDefinition{
                .name = name_copy,
                .parse_time = true,
                .action = .{ .literal = top_val },
            });
            fireWordDefinedHook(ctx, alloc, name_copy);
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

                var collected_markers = std.ArrayListUnmanaged(*Marker){};
                defer collected_markers.deinit(alloc);
                var captured_doc: ?[]const u8 = null;

                while (true) {
                    const next_val = try ctx.stack.peek();
                    switch (next_val) {
                        .marker => |mk| {
                            try ctx.stack.popAndRelease();
                            try collected_markers.append(alloc, mk);
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
                try ctx.executeQuotation(define_quot);
            } else {
                // Fall back to normal word definition
                var stack_effect_val: ?*const StackEffect = null;
                var doc_val: ?[]const u8 = null;
                var collected_markers = std.ArrayListUnmanaged(*Marker){};
                defer collected_markers.deinit(alloc);
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

                // The definition owns its effect rather than sharing the value's. One parsed body
                // is executed once per scope that loads it, so the same parse-owned effect would
                // otherwise be reached by definitions on arenas that outlive each other in either
                // order.
                if (top_effect) |eff| stack_effect_val = try stack_effect_mod.copyOnto(alloc, eff.*);

                while (true) {
                    const next_val = try ctx.stack.peek();
                    switch (next_val) {
                        .marker => |mk| {
                            try ctx.stack.popAndRelease();
                            try collected_markers.append(alloc, mk);
                        },
                        .doc_string => |d| {
                            try ctx.stack.popAndRelease();
                            doc_val = d;
                        },
                        .stack_effect => |eff| {
                            try ctx.stack.popAndRelease();
                            if (stack_effect_val == null) {
                                stack_effect_val = try stack_effect_mod.box(alloc, eff);
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

                const name_copy = try alloc.dupe(u8, name);

                // Only a quotation or closure body can contain a self-call: the non-quotation
                // branch stores the bound value directly and allocates no instructions at all,
                // so containsNonTailSelfCall below is only ever meaningful for the
                // .quotation/.closure case.
                const action: WordDefinition.Action = switch (top_val) {
                    .quotation => |quot| .{ .compound = quot.instructions },
                    // A closure is a quotation literal promoted at push time because it closed over
                    // an outer local, or a curry/compose product (see `Context.captureQuotationScope`
                    // and `nativeCurry`). Without this arm it would fall to the bound-value branch
                    // below, which would store the closure as a `.literal` -- turning the defined
                    // word into one that pushes the closure as a constant instead of calling it.
                    //
                    // The word borrows the closure's body, so the popped reference is adopted by
                    // the dictionary and released only at teardown, keeping the body alive for
                    // every later call of the word.
                    .closure => |c| blk: {
                        try ctx.retainValueForTeardown(top_val);
                        // The dictionary adopted the popped reference here rather than at the
                        // definition, so this arm alone hands ownership over early.
                        top_owned = false;
                        break :blk .{ .compound = c.instructions };
                    },
                    else => .{ .literal = top_val },
                };

                var markers_slice = try alloc.dupe(*Marker, collected_markers.items);

                if (is_named_constraint) {
                    const has_parse_time_marker = for (markers_slice) |mk| {
                        if (mk == @as(*const Marker, &markers_mod.parse_time_marker)) break true;
                    } else false;
                    const has_const_marker = for (markers_slice) |mk| {
                        if (mk == @as(*const Marker, &markers_mod.const_marker)) break true;
                    } else false;
                    const has_typed_marker = for (markers_slice) |mk| {
                        if (mk == @as(*const Marker, &markers_mod.typed_marker)) break true;
                    } else false;

                    var extra: usize = 0;
                    if (!has_parse_time_marker) extra += 1;
                    if (!has_const_marker) extra += 1;
                    if (!has_typed_marker) extra += 1;

                    if (extra != 0) {
                        const extended = try alloc.alloc(*Marker, markers_slice.len + extra);
                        @memcpy(extended[0..markers_slice.len], markers_slice);
                        var idx = markers_slice.len;
                        if (!has_parse_time_marker) {
                            extended[idx] = @constCast(&markers_mod.parse_time_marker);
                            idx += 1;
                        }
                        if (!has_const_marker) {
                            extended[idx] = @constCast(&markers_mod.const_marker);
                            idx += 1;
                        }
                        if (!has_typed_marker) {
                            extended[idx] = @constCast(&markers_mod.typed_marker);
                        }
                        markers_slice = extended;
                    }
                }

                if (action == .compound and !ctx.allow_all_recursion and containsNonTailSelfCall(ctx, action.compound, name_copy)) {
                    const has_stack_recursive = for (collected_markers.items) |mk| {
                        if (markers_mod.isStackRecursiveMarker(mk)) break true;
                    } else false;

                    if (has_stack_recursive) {
                        const extended = try alloc.alloc(*Marker, markers_slice.len + 1);
                        @memcpy(extended[0..markers_slice.len], markers_slice);
                        extended[markers_slice.len] = @constCast(&markers_mod.recursive_non_tco_marker);
                        markers_slice = extended;
                    } else {
                        helpers.setErrorContext(ctx, "word '{s}' contains a non-tail self-call", .{name_copy});
                        helpers.setErrorHint(ctx, "add the 'stack-recursive' marker if intentional");
                        return error.NonTailRecursion;
                    }
                }

                try ctx.defineWord(name_copy, WordDefinition{
                    .name = name_copy,
                    .parse_time = has_parse_time or has_parse_time_only or is_named_constraint,
                    .parse_time_only = has_parse_time_only,
                    .stack_effect = stack_effect_val,
                    .markers = markers_slice,
                    .doc = doc_val,
                    .action = action,
                });
                // The definition now holds the popped reference. Until it does, every failure
                // between the pop and here -- a const or arity rejection, or an allocation
                // failure -- still has to release it.
                top_owned = false;
                // For a chain-owned closure body the retained closure's destroy is the single
                // release path for the embedded literals, so remove the generic compound
                // registration `defineWord` just made; leaving both would double-release, and
                // the destroy's body free would leave the dictionary walking a dead slice.
                if (top_val == .closure and top_val.closure.ownsBodyTransitively()) {
                    ctx.unregisterCompoundBody(top_val.closure.instructions);
                }
                fireWordDefinedHook(ctx, alloc, name_copy);
            }
        },
    }
}

fn fireWordDefinedHook(ctx: *Context, alloc: std.mem.Allocator, name: []const u8) void {
    if (!hooks.hasScopedHooks(ctx, "word-defined-hooks")) return;
    if (ctx.lookupWord(name)) |word_def| {
        const info = introspect.buildWordInfo(alloc, ctx, name, word_def) catch return;
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
    try ctx.executeQuotationInline(if (cond) true_quot.quot else false_quot.quot);
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
    const hook_items = try alloc.alloc(Value, 1);
    hook_items[0] = .{ .quotation = .{ .instructions = &.{} } };
    const hook_arr = try value_mod.Array.fromOwnedSlice(alloc, hook_items);
    try ctx.setParameterInTopFrame("word-defined-hooks", .{ .array = hook_arr });

    const before_end = ctx.arena.state.end_index;
    const before_node = ctx.arena.state.buffer_list.first;

    fireWordDefinedHook(&ctx, alloc, "foo");

    // buildWordInfo ran: something was allocated.
    try std.testing.expect(ctx.arena.state.end_index != before_end or
        ctx.arena.state.buffer_list.first != before_node);

    // fireScopedHooks pushes the hook's args before executing its quotation; an
    // empty-instruction quotation consumes nothing, so the raw word-info array
    // is left on the stack for inspection.
    const info = try ctx.stack.pop();
    try std.testing.expect(info == .array);
    try std.testing.expect(info.array.items[0] == .string);
    try std.testing.expectEqualStrings("foo", info.array.items[0].string.bytes);
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
    const arr = try value_mod.Array.fromOwnedSlice(alloc, elements);

    try ctx.stack.push(value_mod.symbolValue("xs"));
    try ctx.stack.push(.{ .array = arr });
    try nativeSemicolon(&ctx);

    const word = ctx.lookupWord("xs") orelse return error.TestExpectedWord;
    switch (word.action) {
        .literal => |v| try std.testing.expect(v == .array),
        .compound, .native, .host_callback => try std.testing.expect(false),
    }
    // A durable binding has no frame to reclaim its reference, so the dictionary holds it.
    try std.testing.expect(!word.owns_literal);

    const body = [_]Instruction{.{ .op = .{ .call_word = "xs" }, .line = 0 }};
    try ctx.executeQuotation(.{ .instructions = &body });

    const result = try ctx.stack.pop();
    defer container_backing.releaseValue(result);
    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 1), result.array.items.len);
    try std.testing.expectEqual(@as(i64, 7), result.array.items[0].fixnum);
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

test "word with a container-bound named local documents the accepted residual leak across repeated calls" {
    var mem_limit = MemoryLimitAllocator.init(std.testing.allocator, 0);
    var ctx = Context.init(mem_limit.allocator());
    defer ctx.deinit();

    const arr_alloc = ctx.quotationAllocator();
    const elements = try arr_alloc.alloc(Value, 1);
    elements[0] = .{ .fixnum = 1 };
    const arr = try value_mod.Array.fromOwnedSlice(arr_alloc, elements);

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
        });
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
