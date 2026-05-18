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

/// Well-known marker certifying that a native primitive's runtime code path
/// depends on interpreter machinery and therefore must not be reachable from
/// interpreter-free AOT binaries.
///
/// A native carries this marker when its runtime body, or any helper it
/// transitively calls at runtime, uses any of:
///
/// - `Context.lookupWord` (name-based dictionary lookup)
/// - `Context.executeQuotation`, `executeQuotationWithFrame`,
///   `executeQuotationInline`, `executeInstructions` (generic execution of
///   `Instruction` slices not produced by AOT codegen)
/// - the runtime parser/evaluator (`StatementProcessor.feedLine`, the
///   `eval-string` entry, the `load-file` file-read+parse path)
/// - any helper that reconstructs the above indirectly
///
/// Parse-time and definition-time uses are out of scope: those execute
/// before AOT freeze begins and are not reachable from the compiled
/// program. Type-keyed dispatch (`lookupBinaryDispatch`,
/// `lookupUnaryDispatch`) is not interpreter machinery and does not require
/// the marker.
///
/// Interpreter-free AOT freeze rejects any reachable native that carries
/// this marker. Runtime-image AOT and the interpreter accept it.
pub const interpreter_dependent_marker: Marker = .{ .name = "interpreter-dependent" };

/// Well-known marker certifying that a word performs runtime string-to-code
/// evaluation (the `eval-string` capability). Freeze policy: allowed under
/// the interpreter and runtime-image AOT; banned under interpreter-free AOT.
pub const dynamic_eval_marker: Marker = .{ .name = "dynamic-eval" };

/// Well-known marker certifying that a word performs runtime module loading
/// (e.g., `load`, `reload`, `load-file`). Freeze policy: allowed under the
/// interpreter and runtime-image AOT; banned under interpreter-free AOT.
pub const dynamic_load_marker: Marker = .{ .name = "dynamic-load" };

/// Well-known marker certifying that a word invokes the compiler at runtime
/// (the `compile!` capability). Freeze policy: allowed under the
/// interpreter; banned under both runtime-image and interpreter-free AOT.
pub const dynamic_compile_marker: Marker = .{ .name = "dynamic-compile" };

/// Well-known marker certifying that a word constructs quotations from
/// runtime values (the `>quotation` capability). Freeze policy: allowed
/// under the interpreter and runtime-image AOT; banned under
/// interpreter-free AOT.
pub const dynamic_quotation_construction_marker: Marker = .{ .name = "dynamic-quotation-construction" };

/// The three semantic artifact classes a 1z build may produce. Class
/// reflects the maximum runtime capability of the artifact: an
/// interpreter-linked binary can do everything (eval-string, runtime
/// load, dynamic dispatch); a runtime-image-only AOT binary can
/// rehydrate the program dictionary but not evaluate new source; an
/// interpreter-free AOT binary only executes the frozen compiled graph.
pub const ArtifactClass = enum {
    interpreter,
    runtime_image_aot,
    interpreter_free_aot,

    /// Lowercase-with-dashes spelling embedded in the AOT metadata
    /// payload and printed by `1z inspect`. Stable across builds; do
    /// not change without bumping the metadata schema version.
    pub fn label(self: ArtifactClass) []const u8 {
        return switch (self) {
            .interpreter => "interpreter",
            .runtime_image_aot => "runtime-image-aot",
            .interpreter_free_aot => "interpreter-free-aot",
        };
    }
};

/// Freeze policy for the `dynamic-*` marker family. Each row names one
/// of the well-known dynamic-capability markers; the column flags say
/// which artifact classes ban that capability. Adding a new
/// dynamic-capability marker adds a row; adding a new artifact class
/// adds a column.
const DynamicMarkerPolicy = struct {
    marker: *const Marker,
    banned_in_interpreter: bool,
    banned_in_runtime_image_aot: bool,
    banned_in_interpreter_free_aot: bool,
};

const dynamic_marker_policy = [_]DynamicMarkerPolicy{
    .{
        .marker = &dynamic_compile_marker,
        .banned_in_interpreter = false,
        .banned_in_runtime_image_aot = true,
        .banned_in_interpreter_free_aot = true,
    },
    .{
        .marker = &dynamic_eval_marker,
        .banned_in_interpreter = false,
        .banned_in_runtime_image_aot = false,
        .banned_in_interpreter_free_aot = true,
    },
    .{
        .marker = &dynamic_load_marker,
        .banned_in_interpreter = false,
        .banned_in_runtime_image_aot = false,
        .banned_in_interpreter_free_aot = true,
    },
    .{
        .marker = &dynamic_quotation_construction_marker,
        .banned_in_interpreter = false,
        .banned_in_runtime_image_aot = false,
        .banned_in_interpreter_free_aot = true,
    },
};

/// Returns true if the marker is one of the well-known `dynamic-*`
/// markers and its policy entry bans the given artifact class. Returns
/// false for any non-policy marker (anonymous markers, parse-time
/// markers, etc.); identity comparison ensures unrelated markers with
/// coincidental names cannot satisfy the predicate.
pub fn isDynamicMarkerBannedIn(mk: *const Marker, class: ArtifactClass) bool {
    for (dynamic_marker_policy) |entry| {
        if (entry.marker != mk) continue;
        return switch (class) {
            .interpreter => entry.banned_in_interpreter,
            .runtime_image_aot => entry.banned_in_runtime_image_aot,
            .interpreter_free_aot => entry.banned_in_interpreter_free_aot,
        };
    }
    return false;
}

/// Returns true if the marker is one of the four well-known `dynamic-*`
/// capability markers, regardless of artifact-class policy. Identity
/// comparison ensures non-policy markers with coincidental names are excluded.
pub fn isDynamicMarker(mk: *const Marker) bool {
    for (dynamic_marker_policy) |entry| {
        if (entry.marker == mk) return true;
    }
    return false;
}

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
    .{ .name = "make-marker", .stack_effect = "-- marker", .doc = "Create an anonymous marker value.", .func = nativeMarker },
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
    .{ .name = "interpreter-dependent", .stack_effect = "-- marker", .doc = "Push the well-known interpreter-dependent marker. Reachable natives carrying this marker are rejected by interpreter-free AOT.", .func = nativeInterpreterDependentMarker, .parse_time = true },
    .{ .name = "dynamic-eval", .stack_effect = "-- marker", .doc = "Push the well-known dynamic-eval marker. Certifies the word performs runtime string-to-code evaluation.", .func = nativeDynamicEvalMarker, .parse_time = true },
    .{ .name = "dynamic-load", .stack_effect = "-- marker", .doc = "Push the well-known dynamic-load marker. Certifies the word performs runtime module loading.", .func = nativeDynamicLoadMarker, .parse_time = true },
    .{ .name = "dynamic-compile", .stack_effect = "-- marker", .doc = "Push the well-known dynamic-compile marker. Certifies the word invokes the compiler at runtime.", .func = nativeDynamicCompileMarker, .parse_time = true },
    .{ .name = "dynamic-quotation-construction", .stack_effect = "-- marker", .doc = "Push the well-known dynamic-quotation-construction marker. Certifies the word constructs quotations from runtime values.", .func = nativeDynamicQuotationConstructionMarker, .parse_time = true },
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

/// interpreter-dependent ( -- marker ) - Push the well-known interpreter-dependent marker
pub fn nativeInterpreterDependentMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&interpreter_dependent_marker) });
}

/// dynamic-eval ( -- marker ) - Push the well-known dynamic-eval marker
pub fn nativeDynamicEvalMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&dynamic_eval_marker) });
}

/// dynamic-load ( -- marker ) - Push the well-known dynamic-load marker
pub fn nativeDynamicLoadMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&dynamic_load_marker) });
}

/// dynamic-compile ( -- marker ) - Push the well-known dynamic-compile marker
pub fn nativeDynamicCompileMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&dynamic_compile_marker) });
}

/// dynamic-quotation-construction ( -- marker ) - Push the well-known dynamic-quotation-construction marker
pub fn nativeDynamicQuotationConstructionMarker(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .marker = @constCast(&dynamic_quotation_construction_marker) });
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

/// Check if a marker is the well-known interpreter-dependent marker
pub fn isInterpreterDependentMarker(mk: *const Marker) bool {
    return mk == &interpreter_dependent_marker;
}

/// Check if a marker is the well-known dynamic-eval marker
pub fn isDynamicEvalMarker(mk: *const Marker) bool {
    return mk == &dynamic_eval_marker;
}

/// Check if a marker is the well-known dynamic-load marker
pub fn isDynamicLoadMarker(mk: *const Marker) bool {
    return mk == &dynamic_load_marker;
}

/// Check if a marker is the well-known dynamic-compile marker
pub fn isDynamicCompileMarker(mk: *const Marker) bool {
    return mk == &dynamic_compile_marker;
}

/// Check if a marker is the well-known dynamic-quotation-construction marker
pub fn isDynamicQuotationConstructionMarker(mk: *const Marker) bool {
    return mk == &dynamic_quotation_construction_marker;
}

/// Resolve a marker name to the corresponding well-known static-singleton
/// `*Marker`, or null when no built-in marker matches. The list mirrors
/// the well-known `Marker` constants enumerated at the top of this file
/// and registered through the `primitives` array. Used by the AOT runtime
/// image loader to preserve freeze→runtime pointer identity for built-in
/// markers when populating `onez_image_marker_slots[]`.
pub fn lookupWellKnownMarker(name: []const u8) ?*Marker {
    if (std.mem.eql(u8, name, "parse-time")) return @constCast(&parse_time_marker);
    if (std.mem.eql(u8, name, "parse-time-only")) return @constCast(&parse_time_only_marker);
    if (std.mem.eql(u8, name, "mutable")) return @constCast(&mutable_marker);
    if (std.mem.eql(u8, name, "generic")) return @constCast(&generic_marker);
    if (std.mem.eql(u8, name, "const")) return @constCast(&const_marker);
    if (std.mem.eql(u8, name, "branch-combinator")) return @constCast(&branch_combinator_marker);
    if (std.mem.eql(u8, name, "loop-combinator")) return @constCast(&loop_combinator_marker);
    if (std.mem.eql(u8, name, "shadow-ok")) return @constCast(&shadow_ok_marker);
    if (std.mem.eql(u8, name, "typed")) return @constCast(&typed_marker);
    if (std.mem.eql(u8, name, "stack-recursive")) return @constCast(&stack_recursive_marker);
    if (std.mem.eql(u8, name, "no-compile")) return @constCast(&no_compile_marker);
    if (std.mem.eql(u8, name, "deprecated")) return @constCast(&deprecated_marker);
    if (std.mem.eql(u8, name, "never-returns")) return @constCast(&never_returns_marker);
    if (std.mem.eql(u8, name, "interpreter-dependent")) return @constCast(&interpreter_dependent_marker);
    if (std.mem.eql(u8, name, "dynamic-eval")) return @constCast(&dynamic_eval_marker);
    if (std.mem.eql(u8, name, "dynamic-load")) return @constCast(&dynamic_load_marker);
    if (std.mem.eql(u8, name, "dynamic-compile")) return @constCast(&dynamic_compile_marker);
    if (std.mem.eql(u8, name, "dynamic-quotation-construction")) return @constCast(&dynamic_quotation_construction_marker);
    if (std.mem.eql(u8, name, "any")) return @constCast(&any_marker);
    if (std.mem.eql(u8, name, "self")) return @constCast(&self_marker);
    return null;
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
