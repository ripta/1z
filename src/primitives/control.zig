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

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

const popQuotation = helpers.popQuotation;
const popBoolean = helpers.popBoolean;
const popSymbol = helpers.popSymbol;

/// Check if a value is a type descriptor, which is a hash or mutable-map with a `define:` quotation.
/// Used by `;` to recognize type-defining syntaxes like `struct{ ... }` or `virtual{ ... }`.
fn isTypeDescriptor(val: Value) bool {
    const define_val_opt: ?Value = switch (val) {
        .hash => |h| h.get("define"),
        .mutable_map => |m| m.get("define"),
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

/// Get the underlying map from a type descriptor
fn getDescriptorMap(val: Value) ?*value_mod.MutableMap {
    return switch (val) {
        .hash => |h| h,
        .mutable_map => |m| m,
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
            .call_word => |w| {
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
        else => false,
    };

    for (instructions, 0..) |instr, i| {
        const is_last = (i == last_idx);
        switch (instr.op) {
            .call_word => |w| {
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

pub fn nativeArityMismatchValidator(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .string => |s| {
            if (std.mem.eql(u8, s, "error") or std.mem.eql(u8, s, "warning")) {
                try ctx.stack.push(.{ .string = s });
                try ctx.stack.push(.{ .boolean = true });
            } else {
                try ctx.stack.push(.{ .string = "arity-mismatch: expected \"error\" or \"warning\"" });
                try ctx.stack.push(.{ .boolean = false });
            }
        },
        else => {
            try ctx.stack.push(.{ .string = "arity-mismatch: expected \"error\" or \"warning\"" });
            try ctx.stack.push(.{ .boolean = false });
        },
    }
}

/// Native validator for the require-doc pragma. Maps level names to the
/// bitmask consumed by enforceRequireDoc. Follows the same protocol as
/// quotation validators: push validated_value t on success, or error_msg f
/// on failure.
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

/// Check the require-doc pragma and throw missing-doc-comment if a
/// doc-comment is required but absent. The pragma value is an integer
/// bitmask set by the native validator.
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
    ctx.thrown_error = .{
        .error_type = "missing-doc-comment",
        .message = std.fmt.allocPrint(alloc, "word '{s}' defined without a doc-comment", .{name}) catch "word defined without a doc-comment",
    };
    return error.UserThrown;
}

pub const primitives = [_]Primitive{
    .{ .name = "call", .stack_effect = "..a quot: ( ..a -- ..b ) -- ..b", .doc = "Execute a quotation.", .func = nativeCall },
    .{ .name = ";", .stack_effect = "name quot --", .doc = "Define a new word.", .func = nativeSemicolon },
    .{ .name = "t", .stack_effect = "-- t", .doc = "Push true.", .func = nativeTrue },
    .{ .name = "f", .stack_effect = "-- f", .doc = "Push false.", .func = nativeFalse },
    .{ .name = "if", .stack_effect = "..a ? true-quot: ( ..a -- ..b ) false-quot: ( ..a -- ..b ) -- ..b", .doc = "Conditional execution.", .func = nativeIf, .markers = &.{@constCast(&markers_mod.branch_combinator_marker)} },
};

/// call ( quot -- ) - Execute a quotation with a new local frame for scoping
pub fn nativeCall(ctx: *Context) anyerror!void {
    const instrs = try popQuotation(ctx);
    try ctx.executeQuotationWithFrame(instrs);
}

/// ; ( name: quot -- ) or ( name: value -- ) or ( name: marker -- ) - Define a new word
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
                        _ = try ctx.stack.pop();
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
        },

        else => {
            if (isTypeDescriptor(top_val)) {
                const desc_map = getDescriptorMap(top_val) orelse {
                    helpers.setErrorContext(ctx, "type descriptor has no accessible map", .{});
                    return error.TypeMismatch;
                };

                var collected_markers = std.ArrayListUnmanaged(*Marker){};
                defer collected_markers.deinit(alloc);
                var has_doc = false;

                while (true) {
                    const next_val = try ctx.stack.peek();
                    switch (next_val) {
                        .marker => |mk| {
                            _ = try ctx.stack.pop();
                            try collected_markers.append(alloc, mk);
                        },
                        .doc_string => {
                            _ = try ctx.stack.pop();
                            has_doc = true;
                        },
                        .symbol => break,
                        else => {
                            helpers.setTypeMismatchError(ctx, "symbol, marker, or doc-string before type definition", next_val);
                            return error.TypeMismatch;
                        },
                    }
                }

                const name = try popSymbol(ctx);
                try enforceRequireDoc(ctx, name, has_doc, false, true, false);
                try ctx.stack.push(.{ .symbol = name });

                try ctx.stack.push(top_val);

                const markers_array = try alloc.alloc(Value, collected_markers.items.len);
                for (collected_markers.items, 0..) |mk, i| {
                    markers_array[i] = .{ .marker = mk };
                }
                try ctx.stack.push(.{ .array = markers_array });

                const define_val = desc_map.get("define") orelse return error.MissingField;
                const define_quot = switch (define_val) {
                    .quotation => |q| q,
                    else => {
                        helpers.setTypeMismatchError(ctx, "quotation for type descriptor 'define' field", define_val);
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

                while (true) {
                    const next_val = try ctx.stack.peek();
                    switch (next_val) {
                        .stack_effect => |se| {
                            _ = try ctx.stack.pop();
                            stack_effect_val = se;
                        },
                        .marker => |mk| {
                            _ = try ctx.stack.pop();
                            try collected_markers.append(alloc, mk);
                        },
                        .doc_string => |d| {
                            _ = try ctx.stack.pop();
                            doc_val = d;
                        },
                        .symbol => break,
                        else => {
                            helpers.setTypeMismatchError(ctx, "symbol, marker, stack-effect, or doc-string before word definition", next_val);
                            return error.TypeMismatch;
                        },
                    }
                }

                const name = try popSymbol(ctx);

                const has_parse_time = for (collected_markers.items) |mk| {
                    if (mk == @as(*const Marker, &markers_mod.parse_time_marker)) break true;
                } else false;

                try enforceRequireDoc(ctx, name, doc_val != null, has_parse_time, false, false);

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
                    .parse_time = has_parse_time,
                    .stack_effect = stack_effect_val,
                    .markers = markers_slice,
                    .doc = doc_val,
                    .action = .{ .compound = instructions },
                });
            }
        },
    }
}

pub fn nativeTrue(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .boolean = true });
}

pub fn nativeFalse(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .boolean = false });
}

/// if ( ? true-quot false-quot -- ) - Conditional execution
///
/// Uses executeQuotationInline so tail calls in branches propagate to the
/// enclosing word's TCO loop (e.g., times -> if -> [... times] tail-calls).
pub fn nativeIf(ctx: *Context) anyerror!void {
    const false_quot = try popQuotation(ctx);
    const true_quot = try popQuotation(ctx);
    const cond = try popBoolean(ctx);
    try ctx.executeQuotationInline(if (cond) true_quot else false_quot);
}
