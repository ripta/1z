const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Marker = value_mod.Marker;
const Value = value_mod.Value;

const helpers = @import("helpers.zig");
const types_mod = @import("types.zig");
const Primitive = types_mod.Primitive;
const RegistryEntry = types_mod.RegistryEntry;

/// Well-known marker for parse-time word definitions.
/// This is a compile-time constant with identity semantics.
pub const parse_time_marker: Marker = .{ .name = "parse-time" };

/// Well-known marker for parse-time-only word definitions.
/// When present, the word can only be called during parse time.
pub const parse_time_only_marker: Marker = .{ .name = "parse-time-only" };

/// Well-known marker for mutable struct definitions.
/// When present on a struct, setters (>>field) are generated in addition to getters.
pub const mutable_marker: Marker = .{ .name = "mutable" };

/// Well-known marker for generic word definitions.
/// When present, method dispatch is enabled for the word.
pub const generic_marker: Marker = .{ .name = "generic" };

/// Well-known marker for constant word definitions.
/// When present, the word cannot be redefined.
///
/// XXX(ripta): I considered making all words const by default and having a
///             mutable marker instead, but that would be a breaking change.
///             Plus, we already have the mutable marker for structs, so it
///             gets confusing when `mutable` struct may affect the struct
///             contentts and the word definition itself.
pub const const_marker: Marker = .{ .name = "const" };

/// Well-known marker for branch combinators.
/// Indicates the word selects between quotation arguments based on a condition.
pub const branch_combinator_marker: Marker = .{ .name = "branch-combinator" };

/// Well-known marker for loop combinators.
/// Indicates the word repeatedly executes a quotation argument.
pub const loop_combinator_marker: Marker = .{ .name = "loop-combinator" };

/// Well-known marker for shadow-ok word definitions.
/// When present on a `use` invocation, suppresses the import conflict check.
pub const shadow_ok_marker: Marker = .{ .name = "shadow-ok" };

/// Well-known marker for type word definitions. When present, the word pushes a first-class type value.
/// Called "typed" rather than "type" to avoid conflicting with the `type` built-in type value word.
pub const typed_marker: Marker = .{ .name = "typed" };

/// Well-known marker for words that contain non-tail self-calls.
/// Applied by the compiler when a word calls itself outside of tail position.
pub const stack_recursive_marker: Marker = .{ .name = "stack-recursive" };

/// Well-known marker for words detected as recursive without TCO.
/// Applied internally by `;` -- not user-facing.
pub const recursive_non_tco_marker: Marker = .{ .name = "recursive-non-tco" };

/// Well-known marker for opting a word out of automatic compilation.
/// When present, the word is never assigned a word_id and is always interpreted.
pub const no_compile_marker: Marker = .{ .name = "no-compile" };

/// Well-known marker for deprecated word definitions.
/// When present, the linter warns at call sites of the word.
pub const deprecated_marker: Marker = .{ .name = "deprecated" };

/// Well-known marker for words that never return to their caller.
/// When present, the AOT compiler treats calls to this word as diverging
/// (sets state.diverged = true), so branches ending with this word
/// do not need to match the stack depth of other branches.
pub const never_returns_marker: Marker = .{ .name = "never-returns" };

/// Dispatch wildcard for `method{`, not a type -- no value has type `any`.
pub const any_marker: Marker = .{ .name = "any" };

/// Protocol self-type marker for type signatures.
pub const self_marker: Marker = .{ .name = "self" };

/// Sentinel TypeValue for `self` in type annotations.
/// Used to represent the implementing type. When this type appears at runtime, a concrete type is not known yet.
pub const self_type_sentinel: value_mod.TypeValue = .{ .name = "self", .descriptor = null };

/// Sentinel TypeValue for `any` in type annotations.
/// Used to represent any type during a dynamic method dispatch.
pub const any_type_sentinel: value_mod.TypeValue = .{ .name = "any", .descriptor = null };

pub const primitives = [_]Primitive{
    .{ .name = "define-marker", .stack_effect = "-- marker", .doc = "Create an anonymous marker value.", .func = nativeMarker },
    .{ .name = "parse-time", .stack_effect = "-- marker", .doc = "Push the well-known parse-time marker.", .func = nativeParseTimeMarker, .parse_time = true },
    .{ .name = "parse-time-only", .stack_effect = "-- marker", .doc = "Push the well-known parse-time-only marker.", .func = nativeParseTimeOnlyMarker, .parse_time = true },
    .{ .name = "mutable", .stack_effect = "-- marker", .doc = "Push the well-known mutable marker.", .func = nativeMutableMarker, .parse_time = true },
    .{ .name = "generic", .stack_effect = "-- marker", .doc = "Push the well-known generic marker.", .func = nativeGenericMarker, .parse_time = true },
    .{ .name = "const", .stack_effect = "-- marker", .doc = "Push the well-known const marker.", .func = nativeConstMarker, .parse_time = true },
    .{ .name = "branch-combinator", .stack_effect = "-- marker", .doc = "Push the well-known branch-combinator marker.", .func = nativeBranchCombinatorMarker, .parse_time = true },
    .{ .name = "loop-combinator", .stack_effect = "-- marker", .doc = "Push the well-known loop-combinator marker.", .func = nativeLoopCombinatorMarker, .parse_time = true },
    .{ .name = "shadow-ok", .stack_effect = "-- marker", .doc = "Push the well-known shadow-ok marker. Suppresses the import conflict check on `use`.", .func = nativeShadowOkMarker, .parse_time = true },
    .{ .name = "typed", .stack_effect = "-- marker", .doc = "Push the well-known typed marker.", .func = nativeTypedMarker, .parse_time = true },
    .{ .name = "stack-recursive", .stack_effect = "-- marker", .doc = "Push the well-known stack-recursive marker.", .func = nativeStackRecursiveMarker, .parse_time = true },
    .{ .name = "no-compile", .stack_effect = "-- marker", .doc = "Push the well-known no-compile marker. Opts a word out of automatic compilation.", .func = nativeNoCompileMarker, .parse_time = true },
    .{ .name = "deprecated", .stack_effect = "-- marker", .doc = "Push the well-known deprecated marker. The linter warns at call sites of deprecated words.", .func = nativeDeprecatedMarker, .parse_time = true },
    .{ .name = "never-returns", .stack_effect = "-- marker", .doc = "Push the well-known never-returns marker. Indicates the word never returns to its caller.", .func = nativeNeverReturnsMarker, .parse_time = true },
    .{ .name = "any", .stack_effect = "-- marker", .doc = "Push the well-known any marker for method dispatch wildcards.", .func = nativeAnyMarker, .parse_time = true, .markers = &.{@constCast(&const_marker)} },
    .{ .name = "self", .stack_effect = "-- marker", .doc = "Push the well-known self marker for protocol type annotations.", .func = nativeSelfMarker, .parse_time = true, .markers = &.{@constCast(&const_marker)} },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "word-markers", .func = nativeWordMarkers, .stack_effect = "module name -- array" },
    .{ .name = "native?", .func = nativeIsNative, .stack_effect = "module name -- ?" },
};

/// marker ( -- marker ) - Create an anonymous marker value
/// The marker gets its name when defined with ;
pub fn nativeMarker(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const marker = try alloc.create(Marker);
    marker.* = .{ .name = "" }; // Anonymous until defined
    try ctx.stack.push(.{ .marker = marker });
}

/// parse-time ( -- marker ) - Push the well-known parse-time marker
/// This marker indicates that a word should be executed at parse time.
pub fn nativeParseTimeMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&parse_time_marker) });
}

/// parse-time-only ( -- marker ) - Push the well-known parse-time-only marker
pub fn nativeParseTimeOnlyMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&parse_time_only_marker) });
}

/// mutable ( -- marker ) - Push the well-known mutable marker
/// This marker indicates that a struct should generate setters in addition to getters.
pub fn nativeMutableMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&mutable_marker) });
}

/// generic ( -- marker ) - Push the well-known generic marker
/// This marker indicates that a word supports method dispatch.
pub fn nativeGenericMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&generic_marker) });
}

/// const ( -- marker ) - Push the well-known const marker
/// This marker indicates that a word cannot be redefined.
pub fn nativeConstMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&const_marker) });
}

/// branch-combinator ( -- marker ) - Push the well-known branch-combinator marker
pub fn nativeBranchCombinatorMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&branch_combinator_marker) });
}

/// loop-combinator ( -- marker ) - Push the well-known loop-combinator marker
pub fn nativeLoopCombinatorMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&loop_combinator_marker) });
}

/// shadow-ok ( -- marker ) - Push the well-known shadow-ok marker
pub fn nativeShadowOkMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&shadow_ok_marker) });
}

/// typed ( -- marker ) - Push the well-known typed marker
pub fn nativeTypedMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&typed_marker) });
}

/// stack-recursive ( -- marker ) - Push the well-known stack-recursive marker
pub fn nativeStackRecursiveMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&stack_recursive_marker) });
}

/// no-compile ( -- marker ) - Push the well-known no-compile marker
pub fn nativeNoCompileMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&no_compile_marker) });
}

/// deprecated ( -- marker ) - Push the well-known deprecated marker
pub fn nativeDeprecatedMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&deprecated_marker) });
}

/// never-returns ( -- marker ) - Push the well-known never-returns marker
pub fn nativeNeverReturnsMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&never_returns_marker) });
}

/// any ( -- marker ) - Push the well-known any marker
pub fn nativeAnyMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&any_marker) });
}

/// self ( -- marker ) - Push the well-known self marker for protocol type annotations
pub fn nativeSelfMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&self_marker) });
}

/// Check if a marker is the well-known mutable marker
pub fn isMutableMarker(mk: *const Marker) bool {
    return mk == &mutable_marker;
}

/// Check if a marker is the well-known parse-time marker
pub fn isParseTimeMarker(mk: *const Marker) bool {
    return mk == &parse_time_marker;
}

/// Check if a marker is the well-known parse-time-only marker
pub fn isParseTimeOnlyMarker(mk: *const Marker) bool {
    return mk == &parse_time_only_marker;
}

/// Check if a marker is the well-known generic marker
pub fn isGenericMarker(mk: *const Marker) bool {
    return mk == &generic_marker;
}

/// Check if a marker is the well-known const marker
pub fn isConstMarker(mk: *const Marker) bool {
    return mk == &const_marker;
}

/// Check if a marker is the well-known branch-combinator marker
pub fn isBranchCombinatorMarker(mk: *const Marker) bool {
    return mk == &branch_combinator_marker;
}

/// Check if a marker is the well-known loop-combinator marker
pub fn isLoopCombinatorMarker(mk: *const Marker) bool {
    return mk == &loop_combinator_marker;
}

/// Check if a marker is the well-known shadow-ok marker
pub fn isShadowOkMarker(mk: *const Marker) bool {
    return mk == &shadow_ok_marker;
}

/// Check if a marker is the well-known typed marker
pub fn isTypedMarker(mk: *const Marker) bool {
    return mk == &typed_marker;
}

/// Check if a marker is the well-known any marker
pub fn isAnyMarker(mk: *const Marker) bool {
    return mk == &any_marker;
}

/// Check if a marker is the well-known self marker
pub fn isSelfMarker(mk: *const Marker) bool {
    return mk == &self_marker;
}

/// Check if a marker is the well-known stack-recursive marker
pub fn isStackRecursiveMarker(mk: *const Marker) bool {
    return mk == &stack_recursive_marker;
}

/// Check if a marker is the well-known no-compile marker
pub fn isNoCompileMarker(mk: *const Marker) bool {
    return mk == &no_compile_marker;
}

/// Check if a marker is the well-known deprecated marker
pub fn isDeprecatedMarker(mk: *const Marker) bool {
    return mk == &deprecated_marker;
}

/// Check if a marker is the well-known never-returns marker
pub fn isNeverReturnsMarker(mk: *const Marker) bool {
    return mk == &never_returns_marker;
}

/// word-markers ( module name -- markers ) - Get the markers attached to a word in a module
///
/// Returns an array of marker values. Returns empty array if word has no markers.
/// Raises WordNotFound if the word doesn't exist.
fn nativeWordMarkers(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const name_val = try ctx.stack.pop();
    const name = switch (name_val) {
        .symbol, .string => |s| s,
        else => {
            const type_name = helpers.valueTypeName(name_val);
            const msg = std.fmt.allocPrint(alloc, "expected symbol or string, got {s}", .{type_name}) catch "expected symbol or string";
            ctx.error_details.append(ctx.allocator, .{
                .error_type = "type-mismatch",
                .message = msg,
                .source = ctx.ownedCurrentSource(),
                .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
                .word_name = "word-markers",
            }) catch {};
            return error.TypeMismatch;
        },
    };

    const mod_val = try ctx.stack.pop();
    const module = switch (mod_val) {
        .module => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "module", mod_val);
            return error.TypeMismatch;
        },
    };

    const mod_word = module.words.get(name) orelse {
        const msg = std.fmt.allocPrint(alloc, "word '{s}'", .{name}) catch "word '<unknown>'";
        ctx.error_details.append(ctx.allocator, .{
            .error_type = "word-not-found",
            .message = msg,
            .source = ctx.ownedCurrentSource(),
            .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
            .word_name = "word-markers",
        }) catch {};
        return error.WordNotFound;
    };

    const word_markers = mod_word.markers;
    const result = try alloc.alloc(Value, word_markers.len);
    for (word_markers, 0..) |mk, i| {
        result[i] = .{ .marker = @constCast(mk) };
    }

    try ctx.stack.push(.{ .array = result });
}

/// native? ( module name -- ? ) - Check if a word in a module is a native primitive
///
/// Returns true if the word exists and is a native implementation, false if
/// it exists but is a compound (user-defined) word.
/// Raises WordNotFound if the word doesn't exist.
fn nativeIsNative(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const name_val = try ctx.stack.pop();
    const name = switch (name_val) {
        .symbol, .string => |s| s,
        else => {
            const type_name = helpers.valueTypeName(name_val);
            const msg = std.fmt.allocPrint(alloc, "expected symbol or string, got {s}", .{type_name}) catch "expected symbol or string";
            ctx.error_details.append(ctx.allocator, .{
                .error_type = "type-mismatch",
                .message = msg,
                .source = ctx.ownedCurrentSource(),
                .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
                .word_name = "native?",
            }) catch {};
            return error.TypeMismatch;
        },
    };

    const mod_val = try ctx.stack.pop();
    const module = switch (mod_val) {
        .module => |m| m,
        else => {
            helpers.setTypeMismatchError(ctx, "module", mod_val);
            return error.TypeMismatch;
        },
    };

    const mod_word = module.words.get(name) orelse {
        const msg = std.fmt.allocPrint(alloc, "word '{s}'", .{name}) catch "word '<unknown>'";
        ctx.error_details.append(ctx.allocator, .{
            .error_type = "word-not-found",
            .message = msg,
            .source = ctx.ownedCurrentSource(),
            .line = if (ctx.call_stack.items.len > 0) ctx.call_stack.items[ctx.call_stack.items.len - 1].line else 0,
            .word_name = "native?",
        }) catch {};
        return error.WordNotFound;
    };

    const is_native = switch (mod_word.action) {
        .native, .host_callback => true,
        .compound => false,
    };
    try ctx.stack.push(.{ .boolean = is_native });
}
