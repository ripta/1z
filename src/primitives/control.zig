const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Instruction = value_mod.Instruction;
const Marker = value_mod.Marker;
const Value = value_mod.Value;
const Quotation = value_mod.Quotation;

const StackEffect = @import("../stack_effect.zig").StackEffect;

const dictionary_mod = @import("../dictionary.zig");
const WordProvenance = dictionary_mod.WordProvenance;
const WordDefinition = dictionary_mod.WordDefinition;

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
            .quotation => true,
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
            .call_word, .call_word_direct => {
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
        .call_word_direct => |slot| isBranchCombinator(ctx, slot.name),
        else => false,
    };

    for (instructions, 0..) |instr, i| {
        const is_last = (i == last_idx);
        switch (instr.op) {
            .call_word, .call_word_direct => {
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
    switch (val) {
        .string => |s| {
            if (std.mem.eql(u8, s, "error") or std.mem.eql(u8, s, "warning")) {
                try ctx.stack.push(.{ .string = s });
                try ctx.stack.push(.{ .boolean = true });
            } else {
                try ctx.stack.push(.{ .string = "redefinition-arity-mismatch: expected \"error\" or \"warning\"" });
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        else => {
            try ctx.stack.push(.{ .string = "redefinition-arity-mismatch: expected \"error\" or \"warning\"" });
            try ctx.stack.push(.{ .boolean = false });
        },
    }
}

/// Native validator for the callsite-arity-mismatch pragma.
pub fn nativeCallsiteArityMismatchValidator(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .string => |s| {
            if (std.mem.eql(u8, s, "error") or std.mem.eql(u8, s, "warning") or std.mem.eql(u8, s, "off")) {
                try ctx.stack.push(.{ .string = s });
                try ctx.stack.push(.{ .boolean = true });
            } else {
                try ctx.stack.push(.{ .string = "callsite-arity-mismatch: expected \"error\", \"warning\", or \"off\"" });
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        else => {
            try ctx.stack.push(.{ .string = "callsite-arity-mismatch: expected \"error\", \"warning\", or \"off\"" });
            try ctx.stack.push(.{ .boolean = false });
        },
    }
}

/// Native validator for the type-check pragma.
pub fn nativeTypeCheckValidator(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .string => |s| {
            if (std.mem.eql(u8, s, "error") or std.mem.eql(u8, s, "warning") or std.mem.eql(u8, s, "off")) {
                try ctx.stack.push(.{ .string = s });
                try ctx.stack.push(.{ .boolean = true });
            } else {
                try ctx.stack.push(.{ .string = "type-check: expected \"error\", \"warning\", or \"off\"" });
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        else => {
            try ctx.stack.push(.{ .string = "type-check: expected \"error\", \"warning\", or \"off\"" });
            try ctx.stack.push(.{ .boolean = false });
        },
    }
}

/// Native validator for the never-returns-consistency pragma.
pub fn nativeNeverReturnsConsistencyValidator(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .string => |s| {
            if (std.mem.eql(u8, s, "error") or std.mem.eql(u8, s, "warning") or std.mem.eql(u8, s, "off")) {
                try ctx.stack.push(.{ .string = s });
                try ctx.stack.push(.{ .boolean = true });
            } else {
                try ctx.stack.push(.{ .string = "never-returns-consistency: expected \"error\", \"warning\", or \"off\"" });
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        else => {
            try ctx.stack.push(.{ .string = "never-returns-consistency: expected \"error\", \"warning\", or \"off\"" });
            try ctx.stack.push(.{ .boolean = false });
        },
    }
}

/// Native validator for the missing-default-arm pragma.
pub fn nativeMissingDefaultArmValidator(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .string => |s| {
            if (std.mem.eql(u8, s, "error") or std.mem.eql(u8, s, "warning") or std.mem.eql(u8, s, "off")) {
                try ctx.stack.push(.{ .string = s });
                try ctx.stack.push(.{ .boolean = true });
            } else {
                try ctx.stack.push(.{ .string = "missing-default-arm: expected \"error\", \"warning\", or \"off\"" });
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        else => {
            try ctx.stack.push(.{ .string = "missing-default-arm: expected \"error\", \"warning\", or \"off\"" });
            try ctx.stack.push(.{ .boolean = false });
        },
    }
}

/// Native validator for the require-doc pragma. Maps level names to the bitmask
/// consumed by enforceRequireDoc. Follows the same push-value/t or push-error/f
/// protocol as the other pragma validators.
pub fn nativeRequireDocValidator(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .boolean => |b| {
            try ctx.stack.push(.{ .fixnum = if (b) require_doc_normal else 0 });
            try ctx.stack.push(.{ .boolean = true });
        },
        .string => |s| {
            const level: ?i64 = if (std.mem.eql(u8, s, "relaxed"))
                0
            else if (std.mem.eql(u8, s, "standard"))
                require_doc_normal
            else if (std.mem.eql(u8, s, "strict"))
                require_doc_normal | require_doc_parse_time | require_doc_type_descriptor
            else if (std.mem.eql(u8, s, "pedantic"))
                require_doc_normal | require_doc_parse_time | require_doc_type_descriptor | require_doc_marker
            else
                null;

            if (level) |l| {
                try ctx.stack.push(.{ .fixnum = l });
                try ctx.stack.push(.{ .boolean = true });
            } else {
                try ctx.stack.push(.{ .string = "require-doc: expected t, f, or one of relaxed, standard, strict, pedantic" });
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        else => {
            try ctx.stack.push(.{ .string = "require-doc: expected t, f, or one of relaxed, standard, strict, pedantic" });
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
    const instrs = try popQuotation(ctx);
    try ctx.executeQuotationWithFrame(instrs);
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

            const name = try popSymbol(ctx);
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
            const push_instr = try alloc.alloc(Instruction, 1);
            push_instr[0] = .{ .op = .{ .push_literal = top_val }, .line = 0 };
            try ctx.defineWord(name_copy, WordDefinition{
                .name = name_copy,
                .parse_time = true,
                .action = .{ .compound = push_instr },
            });
            fireWordDefinedHook(ctx, alloc, name_copy);
        },

        else => {
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
                try enforceRequireDoc(ctx, name, captured_doc != null, false, true, false);
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
                try ctx.stack.push(.{ .symbol = name });

                // Move ownership of `top_val` into the slot the consumer
                // will pop. `pop` (line 294) already transferred the prior
                // slot's reference to this local; pushing via `pushMoved`
                // forwards that same reference into the new slot without
                // an extra retain. The consumer's `releaseValue` on its
                // descriptor local then balances the original creation.
                try ctx.stack.pushMoved(top_val);

                const markers_array = try alloc.alloc(Value, collected_markers.items.len);
                for (collected_markers.items, 0..) |mk, i| {
                    markers_array[i] = .{ .marker = mk };
                }
                try helpers.pushAdoptedArray(ctx, alloc, markers_array);

                const define_val = desc_map.get("define") orelse return error.MissingField;
                const define_quot = switch (define_val) {
                    .quotation => |q| q,
                    else => {
                        helpers.setTypeMismatchError(ctx, "quotation for definition descriptor 'define' field", define_val);
                        return error.TypeMismatch;
                    },
                };
                try ctx.executeQuotation(define_quot);
            } else {
                // Fall back to normal word definition
                var stack_effect_val: ?StackEffect = null;
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

                // Extract stack effect from the quotation's .effect field if present
                if (top_val == .quotation) {
                    if (top_val.quotation.effect) |eff| {
                        stack_effect_val = eff.*;
                    }
                }

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
                            if (stack_effect_val == null) stack_effect_val = eff;
                        },
                        .symbol => break,
                        else => {
                            helpers.setTypeMismatchError(ctx, "symbol, marker, or doc-string before word definition", next_val);
                            return error.TypeMismatch;
                        },
                    }
                }

                const name = try popSymbol(ctx);

                const has_parse_time = for (collected_markers.items) |mk| {
                    if (mk == @as(*const Marker, &markers_mod.parse_time_marker)) break true;
                } else false;

                const has_parse_time_only = for (collected_markers.items) |mk| {
                    if (mk == @as(*const Marker, &markers_mod.parse_time_only_marker)) break true;
                } else false;

                try enforceRequireDoc(ctx, name, doc_val != null, has_parse_time or has_parse_time_only, is_named_constraint, false);

                const name_copy = try alloc.dupe(u8, name);

                const instructions = switch (top_val) {
                    .quotation => |quot| quot.instructions,
                    else => blk: {
                        const push_instr = try alloc.alloc(Instruction, 1);
                        push_instr[0] = .{ .op = .{ .push_literal = top_val }, .line = 0 };
                        break :blk push_instr;
                    },
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

                if (!ctx.allow_all_recursion and containsNonTailSelfCall(ctx, instructions, name_copy)) {
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
                    .action = .{ .compound = instructions },
                });
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
    const true_quot = try popQuotation(ctx);
    const cond = try popBoolean(ctx);
    try ctx.executeQuotationInline(if (cond) true_quot else false_quot);
}

test "semicolon defines named union type as parse-time word" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const bignum_tv = ctx.lookupBuiltinTypeValue("bignum").?;
    const float_tv = ctx.lookupBuiltinTypeValue("float").?;
    const union_tv = try ctx.getOrCreateAnonymousUnionTypeValue(&.{ fixnum_tv, bignum_tv, float_tv });

    try ctx.stack.push(.{ .symbol = "number" });
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
        .compound => |instrs| {
            try std.testing.expectEqual(@as(usize, 1), instrs.len);
            try std.testing.expect(instrs[0].op.push_literal == .type_val);
            try std.testing.expect(instrs[0].op.push_literal.type_val == union_tv);
        },
        .native, .host_callback => try std.testing.expect(false),
    }
}

test "fireWordDefinedHook skips buildWordInfo when no word-defined-hooks are registered" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .symbol = "foo" });
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

    try ctx.stack.push(.{ .symbol = "foo" });
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
    try std.testing.expectEqualStrings("foo", info.array.items[0].string);
}
