const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const Value = value_mod.Value;
const VirtualType = value_mod.VirtualType;
const StructInstance = value_mod.StructInstance;
const StructType = value_mod.StructType;
const TypeValue = value_mod.TypeValue;
const TypeDescriptor = value_mod.TypeDescriptor;

const ir_mod = @import("ffi/ir.zig");
const JitBuffer = ir_mod.JitBuffer;
const c = ir_mod.ir;

const jit_dispatch_mod = @import("jit_dispatch.zig");
const JitDispatchTable = jit_dispatch_mod.JitDispatchTable;
const JitEntry = jit_dispatch_mod.JitEntry;

const pic_mod = @import("pic.zig");
const dispatch_mod = @import("dispatch.zig");

const Context = @import("context.zig").Context;

const container_backing = @import("container_backing.zig");

const aot_image_mod = @import("aot_image.zig");
const aot_image_emit_mod = @import("aot_image_emit.zig");
const bail_stats_mod = @import("bail_stats.zig");
const ibc = @import("instruction_bytecode.zig");

const stack_effect_mod = @import("stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;

const signal = @import("signal.zig");
const trace_mod = @import("trace.zig");

const Scheduler = @import("scheduler.zig").Scheduler;

const helpers = @import("primitives/helpers.zig");
const dynamic_vars_mod = @import("primitives/dynamic_vars.zig");
const errors_mod = @import("primitives/errors.zig");
const iterators_mod = @import("primitives/iterators.zig");
const sequences_mod = @import("primitives/sequences.zig");
const control = @import("primitives/control.zig");
const dispatch_helpers = @import("primitives/dispatch_helpers.zig");
const markers_mod = @import("primitives/markers.zig");
const WordDefinition = @import("dictionary.zig").WordDefinition;

const aot_wrappers = @import("aot_native_wrappers.zig");
const AotQuotationDesc = @import("aot_freeze.zig").AotQuotationDesc;

pub const IrCodegenError = error{
    NotCompilable,
    CompilationFailed,
    StackUnderflow,
    StackShapeMismatch,
    UncompiledWords,
    UncompiledQuotations,
    InterpreterRequiredButLocked,
    CompoundFallbackRequired,
    /// The generated C source contains `jitInterpretedCall(` references
    /// even though the build classified the binary as not linking the
    /// interpreter (no `compound_uncompiled` fallback sites). This is a
    /// codegen-leak diagnostic: it means a path emitted a call without
    /// going through `noteAotFallbackEmission`, so the inventory and the
    /// final C disagree.
    JitInterpretedCallLeaked,
    /// An interpreter-linked metadata-only build would drop the body of a
    /// non-prelude word reachable from an interpreted quotation, so the
    /// call would silently run the empty rehydrated body. Only a full
    /// runtime image (`--emit-runtime-image`) carries such bodies.
    RuntimeImageRequired,
    OutOfMemory,
};

/// Categorizes why a word returned NotCompilable.
pub const NotCompilableReason = enum {
    non_numeric_operand,
    unresolvable_operands,
    quotation_truthiness,
    non_serializable_literal,
    post_dynamic_call,
    unresolvable_word,
    too_many_inputs,
    quotation_reification,
    merge_type_mismatch,
    nested_loop_conflict,
    pre_scan_failure,
    post_compile_reject,
    abstract_stack_underflow,
    effect_inference_overflow,
    row_binding_overflow,
    quotation_slot_overflow,
    indexed_access_into_row,
    nested_definition,
    unknown_reason,

    pub fn code(self: NotCompilableReason) []const u8 {
        return switch (self) {
            .non_numeric_operand => "NC.1",
            .unresolvable_operands => "NC.2",
            .quotation_truthiness => "NC.3",
            .non_serializable_literal => "NC.4",
            .post_dynamic_call => "NC.5",
            .unresolvable_word => "NC.6",
            .too_many_inputs => "NC.7",
            .quotation_reification => "NC.8",
            .merge_type_mismatch => "NC.9",
            .nested_loop_conflict => "NC.10",
            .pre_scan_failure => "NC.11",
            .post_compile_reject => "NC.12",
            .abstract_stack_underflow => "NC.13",
            .effect_inference_overflow => "NC.14",
            .row_binding_overflow => "NC.15",
            .quotation_slot_overflow => "NC.16",
            .indexed_access_into_row => "NC.17",
            .unknown_reason => "NC.18",
            .nested_definition => "NC.19",
        };
    }

    pub fn message(self: NotCompilableReason) []const u8 {
        return switch (self) {
            .non_numeric_operand => "arithmetic operand is not a fixnum or float",
            .unresolvable_operands => "binary operation has two operands with no known numeric type",
            .quotation_truthiness => "condition is a quotation value in abstract form",
            .non_serializable_literal => "word pushes a value that cannot be embedded in an AOT binary",
            .post_dynamic_call => "calls a quotation whose stack effect is unknown",
            .unresolvable_word => "calls a word that is not available in the AOT compilation set",
            .too_many_inputs => std.fmt.comptimePrint("takes more than {d} input parameters", .{max_abstract_stack_depth}),
            .quotation_reification => "a quotation in abstract form must become a concrete runtime value",
            .merge_type_mismatch => "if/else branches produce different value types",
            .nested_loop_conflict => "contains two self-recursive tail calls",
            .pre_scan_failure => "instruction pre-scan rejected the word before compilation started",
            .post_compile_reject => "compilation produced unresolved dynamic calls or abstract stack entries",
            .abstract_stack_underflow => "word body underflows the abstract stack (row-variable effects)",
            .effect_inference_overflow => std.fmt.comptimePrint("quotation effect inference exceeded mini-stack capacity ({d})", .{max_mini_stack_depth}),
            .row_binding_overflow => std.fmt.comptimePrint("row variable specialization exceeded binding capacity ({d})", .{max_row_var_bindings}),
            .quotation_slot_overflow => std.fmt.comptimePrint("word has more quotation parameters with concrete effects than the compiler can track ({d})", .{max_quotation_slots}),
            .indexed_access_into_row => "indexed stack access targets the symbolic row region",
            .unknown_reason => "compilation failed without a categorized reason",
            .nested_definition => "defines a helper word inside its body that AOT compilation cannot discover",
        };
    }

    pub fn hint(self: NotCompilableReason) ?[]const u8 {
        return switch (self) {
            .non_numeric_operand => "blocked until polymorphic arithmetic can be compiled",
            .unresolvable_operands => "blocked until polymorphic arithmetic can be compiled",
            .quotation_truthiness => "blocked until quotation bodies can be compiled",
            .non_serializable_literal => "blocked until AOT literals can be serialized",
            .post_dynamic_call => "annotate the quotation parameter with a concrete stack effect",
            .unresolvable_word => "blocked until the AOT resolver includes this word",
            .too_many_inputs => std.fmt.comptimePrint("reduce input parameters to {d} or fewer", .{max_abstract_stack_depth}),
            .quotation_reification => "blocked until quotation bodies can be compiled",
            .merge_type_mismatch => "blocked until polymorphic branch merging is implemented",
            .nested_loop_conflict => "split into two words so each has one recursive call",
            .pre_scan_failure => "blocked until the called word is in the AOT compilation set",
            .post_compile_reject => null,
            .abstract_stack_underflow => "blocked until row-variable stack regions can be modeled",
            .effect_inference_overflow => "simplify the quotation body to use fewer intermediate values",
            .row_binding_overflow => "reduce the number of distinct row variable bindings at this call site",
            .quotation_slot_overflow => "simplify the word to use fewer quotation parameters",
            .indexed_access_into_row => "only literal depths into known stack slots above the row are supported",
            .unknown_reason => "diagnostic gap; please report",
            .nested_definition => "move the helper into a private{ } block at module scope",
        };
    }
};

pub const QuotationFallbackReason = enum {
    row_variables,
    no_annotation,
};

pub const QuotationFallbackWarning = struct {
    word_name: []const u8,
    param_name: []const u8,
    reason: QuotationFallbackReason,
};

pub const UncompiledWord = struct {
    name: []const u8,
    reason: NotCompilableReason,
    /// Set when the word fails because it defines a helper word inside its own
    /// body that AOT compilation cannot discover. Names that helper so the
    /// build diagnostic can point at it and recommend a `private{ }` block.
    /// Borrows from the word's instruction stream.
    nested_definition: ?[]const u8 = null,
};

pub const PreludeStats = struct {
    total: u32 = 0,
    compiled: u32 = 0,
    uncompiled: []const UncompiledWord = &.{},
};

/// Why a reachable `method{` dispatch body that the IR codegen could not
/// compile to native code is a hard build error rather than being served by
/// the interpreter-run fallback. Drives the build diagnostic's hint.
pub const MethodBodyUncompilableReason = enum {
    /// No runtime image to carry the body's bytecode; rebuild with
    /// `--emit-runtime-image`.
    needs_runtime_image,
    /// `--emit-runtime-image` is set, but the interpreter is locked off, so
    /// there is nothing to run the body.
    interpreter_locked,
    /// The body embeds a value that cannot be serialized into the image.
    non_serializable,
};

pub const UncompiledQuotation = struct {
    quotation_id: u32,
    c_name: []const u8,
    /// Set when this quotation is a `method{` dispatch body or a reified escaping
    /// quotation; selects the interpreter-run diagnostic and its hint. Null for
    /// ordinary non-reified literal quotations, which keep the generic message.
    method_body_reason: ?MethodBodyUncompilableReason = null,
    /// True when this entry is a reified (escaping/consumed) literal quotation
    /// rather than a `method{` dispatch body, so the diagnostic says "quotation
    /// body" while sharing the method-body hint table.
    reification: bool = false,
};

pub const PicStats = struct {
    sites_attempted: u32 = 0,
    sites_emitted: u32 = 0,
};

/// Classification of an AOT-mode interpreter-callback emission. Covers both
/// `jitInterpretedCall` (native and compound fallback) and `jitCallQuotation`
/// (quotation fallback). Each emission site supplies one of these so
/// `--compilation-stats` and the locked-fallback error can show why the
/// interpreter is still being reached at runtime, and so a follow-up static
/// cross-check can confirm the inventory matches the generated C.
///
/// Strict-AOT policy (`--interpreter-fallback=false`):
///
///   category               | strict build       | runtime callback
///   -----------------------+--------------------+----------------------
///   native                 | allowed            | jitNativeWordCall
///   per_op_native          | allowed            | jitNativeWordCall
///   quotation              | allowed            | jitCallQuotation
///   compound_uncompiled    | REJECTED at build  | jitInterpretedCall
///   unexpected             | REJECTED at build  | (triage sentinel)
///
/// `native` and `per_op_native` were redirected to `jitNativeWordCall` by
/// the work that closed the native fallback track, so neither category
/// reaches `jitInterpretedCall` anymore. `quotation` remains allowed
/// because removing `jitCallQuotation` is intentionally out of scope for
/// the current removal effort. `compound_uncompiled` is the one
/// strict-mode rejection enforced today; see
/// `printCompoundFallbackRequiredError` in `main.zig`.
///
/// Emission sites in this file (kept in sync with
/// `AotFallbackStaticCheck`); each one calls `noteAotFallbackEmission`
/// once per emission:
///
///   category            | site
///   --------------------+----------------------------------------------
///   per_op_native       | polymorphic arithmetic/comparison cold path
///   quotation           | emitIndirectQuotCall (raw quotation slot)
///   quotation           | emitIfBranchDispatch (if branch on raw slot)
///   quotation           | `<choose>` indirect dispatch
///   quotation           | dynamic `call` inside a compiled word
///   quotation           | with-parameter dispatch
///   compound_uncompiled | row-variable failure -> emitAotWordCall
///   compound_uncompiled | dispatch-table indirect cold path
///   native              | emitNativeWordCall (AOT path)
///   compound_uncompiled | emitAotWordCall uncompiled fallthrough
///
/// Symbolic-row machinery is consumed at:
///
///   - `fixupBranchMergeRowRegions` for branch merge,
///   - the `call`-on-raw-slot path that inserts a fresh `row_region`
///     after dispatch when the quotation's effect is unresolved,
///   - `rewriteIndexedStackOp` for compile-time rewrite of indexed stack
///     ops (`pick-n`, `<rot-n`, `rot-n>`, `nip-n`) whose literal depth
///     lands on known slots above the row.
///
/// `dynamic_call_emitted` is a compilation abandon signal, not a
/// fallback emission: the affected body returns early without emitting
/// `jitInterpretedCall`.
pub const AotFallbackCategory = enum {
    /// Native word reached without an inline emitter applying.
    native,
    /// Per-operation polymorphic native fallback for arithmetic/comparison.
    per_op_native,
    /// Compound word whose body did not compile; AOT C dispatches through
    /// the interpreter instead of emitting a direct call.
    compound_uncompiled,
    /// Quotation lacking a compiled `code_ptr`; AOT C falls back through
    /// `jitCallQuotation`. Tracked alongside `jitInterpretedCall` because
    /// both keep the interpreter linked and contribute to the
    /// `aot_fallback_emit_count` decision.
    quotation,
    /// Sentinel for emission paths that have not been classified yet. A
    /// non-zero count here means a new codegen path was added without a
    /// category and should be triaged.
    unexpected,

    pub fn label(self: AotFallbackCategory) []const u8 {
        return switch (self) {
            .native => "native",
            .per_op_native => "per-op-native",
            .compound_uncompiled => "compound-uncompiled",
            .quotation => "quotation",
            .unexpected => "unexpected",
        };
    }
};

pub const aot_fallback_category_count: usize = @typeInfo(AotFallbackCategory).@"enum".fields.len;

/// One AOT `jitInterpretedCall` emission, attributed back to the caller and
/// callee that produced it. `callee_reason` and `callee_is_native` are
/// filled by a post-pass once every word has been considered for
/// compilation; they are unset at the emission site because the callee's
/// classification may not be known yet. The strict-AOT compound-fallback
/// diagnostic uses both fields to distinguish compound words that failed
/// to compile (reason known) from native words that the AOT resolver
/// cannot dispatch directly (native flag set).
pub const AotFallbackSite = struct {
    category: AotFallbackCategory,
    caller_word: []const u8,
    callee_word: []const u8,
    callee_word_id: u32,
    line: u32,
    callee_reason: ?NotCompilableReason = null,
    callee_is_native: bool = false,
};

/// A non-prelude word the freezer did not compile, reachable from a composite-buried quotation
/// that runs interpreted at its dispatch site.
///
/// A metadata-only image rehydrates such a word's dictionary row with an empty body, so an
/// interpreted call to it silently runs nothing. The freeze detection records each offending
/// callee with the composite literal that buries the reaching quotation, and codegen rejects the
/// interpreter-linked metadata-only build when any are present.
pub const InterpretedReachViolation = struct {
    callee_name: []const u8,
    /// The word whose body pushes the burying composite literal, or `__entry__` for a top-level
    /// literal.
    caller_word: []const u8,
    /// Source file of the caller word, when known.
    source_file: ?[]const u8,
    /// 1-based line of the burying composite literal. Zero when unknown.
    line: usize,
};

/// Result of cross-checking the build-time fallback inventory against the
/// assembled C source. `expected_*` mirrors the build-time totals from
/// `AotFallbackReportBuilder`; `observed_*` comes from a single scan of
/// the assembled C output. A mismatch indicates a codegen path that
/// emits an interpreter callback without going through
/// `noteAotFallbackEmission`, or vice versa.
pub const AotFallbackStaticCheck = struct {
    /// Whether the cross-check has been run. Default-initialized reports
    /// (e.g. before `emitProgramC` finishes assembling output) carry an
    /// unpopulated check that printers should skip.
    populated: bool = false,
    expected_jit_interpreted_calls: u32 = 0,
    observed_jit_interpreted_calls: u32 = 0,
    expected_jit_native_word_calls: u32 = 0,
    observed_jit_native_word_calls: u32 = 0,
    expected_jit_call_quotation: u32 = 0,
    observed_jit_call_quotation: u32 = 0,

    pub fn matches(self: AotFallbackStaticCheck) bool {
        return self.expected_jit_interpreted_calls == self.observed_jit_interpreted_calls and
            self.expected_jit_native_word_calls == self.observed_jit_native_word_calls and
            self.expected_jit_call_quotation == self.observed_jit_call_quotation;
    }
};

/// Count non-overlapping occurrences of `needle` in `haystack`.
fn countOccurrences(haystack: []const u8, needle: []const u8) u32 {
    if (needle.len == 0 or haystack.len < needle.len) return 0;
    var count: u32 = 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) {
            count += 1;
            i += needle.len;
        } else {
            i += 1;
        }
    }
    return count;
}

/// Cross-check the build-time fallback inventory against the assembled C
/// source. The `extern` declarations of `jitNativeWordCall(...)` and
/// `jitCallQuotation(...)` are emitted unconditionally, so each of their
/// observed call-site counts is the raw match count minus one when at
/// least one occurrence appears. The `jitInterpretedCall(...)` extern is
/// only emitted when at least one `compound_uncompiled` site needs it, so
/// the caller passes `jit_interpreted_call_extern_emitted` to indicate
/// whether the raw count needs the same minus-one adjustment.
pub fn verifyAotFallbackInventory(
    source: []const u8,
    report: *const AotFallbackReport,
    jit_interpreted_call_extern_emitted: bool,
) AotFallbackStaticCheck {
    const raw_jic = countOccurrences(source, "jitInterpretedCall(");
    const raw_jnwc = countOccurrences(source, "jitNativeWordCall(");
    const raw_jcq = countOccurrences(source, "jitCallQuotation(");
    const observed_jic = if (jit_interpreted_call_extern_emitted)
        (if (raw_jic > 0) raw_jic - 1 else 0)
    else
        raw_jic;
    const observed_jnwc = if (raw_jnwc > 0) raw_jnwc - 1 else 0;
    const observed_jcq = if (raw_jcq > 0) raw_jcq - 1 else 0;

    const expected_jic = report.totals[@intFromEnum(AotFallbackCategory.compound_uncompiled)];
    const expected_jnwc =
        report.totals[@intFromEnum(AotFallbackCategory.native)] +
        report.totals[@intFromEnum(AotFallbackCategory.per_op_native)];
    const expected_jcq = report.totals[@intFromEnum(AotFallbackCategory.quotation)];

    return .{
        .populated = true,
        .expected_jit_interpreted_calls = expected_jic,
        .observed_jit_interpreted_calls = observed_jic,
        .expected_jit_native_word_calls = expected_jnwc,
        .observed_jit_native_word_calls = observed_jnwc,
        .expected_jit_call_quotation = expected_jcq,
        .observed_jit_call_quotation = observed_jcq,
    };
}

/// Snapshot of all AOT fallback emissions for one program. Owned by
/// `CodegenDiagnostics` once finalized.
pub const AotFallbackReport = struct {
    totals: [aot_fallback_category_count]u32 = [_]u32{0} ** aot_fallback_category_count,
    sites: []const AotFallbackSite = &.{},
    /// Populated by `emitProgramC` once the C output has been fully
    /// assembled. Default-initialized reports leave this unpopulated.
    static_check: AotFallbackStaticCheck = .{},

    pub fn total(self: *const AotFallbackReport) u32 {
        var sum: u32 = 0;
        for (self.totals) |count| sum += count;
        return sum;
    }
};

/// Per-compilation builder that codegen pushes into. The finalized
/// `AotFallbackReport` is built from this at the end of `emitProgramC`.
pub const AotFallbackReportBuilder = struct {
    totals: [aot_fallback_category_count]u32 = [_]u32{0} ** aot_fallback_category_count,
    sites: std.ArrayListUnmanaged(AotFallbackSite) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AotFallbackReportBuilder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AotFallbackReportBuilder) void {
        self.sites.deinit(self.allocator);
    }

    pub fn record(self: *AotFallbackReportBuilder, site: AotFallbackSite) void {
        self.totals[@intFromEnum(site.category)] += 1;
        self.sites.append(self.allocator, site) catch {
            // Memory pressure: drop the per-site detail but keep the
            // total accurate so the locked-fallback error and stats line
            // still surface the category breakdown.
        };
    }

    pub fn snapshot(self: *const AotFallbackReportBuilder, allocator: std.mem.Allocator) !AotFallbackReport {
        const sites_copy = try allocator.alloc(AotFallbackSite, self.sites.items.len);
        @memcpy(sites_copy, self.sites.items);
        return .{ .totals = self.totals, .sites = sites_copy };
    }
};

pub const CodegenDiagnostics = struct {
    uncompiled_words: []const UncompiledWord = &.{},
    uncompiled_quotations: []const UncompiledQuotation = &.{},
    quotation_fallbacks: []const QuotationFallbackWarning = &.{},
    prelude_stats: PreludeStats = .{},
    pic_stats: PicStats = .{},
    resolved_interpreter_fallback: ?InterpreterFallbackMode = null,
    has_interpreter_callbacks: bool = false,
    /// Whether the generated C declares and references `jitInterpretedCall`.
    /// True iff any `compound_uncompiled` fallback site was emitted, since
    /// that is the only category that targets `jitInterpretedCall` after
    /// native and per-op-native callbacks were redirected to
    /// `jitNativeWordCall`. Drives the conditional extern emission, the
    /// build-summary line, and the `jit-interpreted-call-linked` metadata
    /// field surfaced by `1z inspect`.
    jit_interpreted_call_linked: bool = false,
    /// Populated when `emit_runtime_image=true`. Drives the
    /// `runtime-image-*` metadata fields and lets tests confirm the
    /// emission wiring without inspecting the generated C source.
    image_stats: ?aot_image_emit_mod.ImageEmissionStats = null,
    /// Per-category breakdown of AOT-mode `jitInterpretedCall` emissions.
    /// Always populated for AOT builds so the locked-fallback error and
    /// `--compilation-stats` output can attribute interpreter calls to the
    /// site that produced them.
    aot_fallback_report: AotFallbackReport = .{},
};

pub const CompiledWord = struct {
    code_ptr: *const anyopaque,
    jit_buf: JitBuffer,
    peak_stack_depth: u32 = 0,
    /// Number of same-type `if` merges this word lowered to a branchless
    /// `IR_COND` select instead of the boxed flush/`MERGE_2` path. Observable
    /// so tests can confirm a qualifying merge took the fast path.
    cond_select_count: u32 = 0,
};

fn shouldSkipTypeAnnotationValidation(word: WordDefinition) bool {
    const has_generic = for (word.markers) |mk| {
        if (markers_mod.isGenericMarker(mk)) break true;
    } else false;
    if (!has_generic) return false;

    return switch (word.action) {
        .compound => |instrs| instrs.len == 0,
        .native, .host_callback, .literal => false,
    };
}

/// A parameter type proved by the freeze-time call-site inference pass.
///
/// `unknown` means the pass proved nothing and the parameter stays opaque, which is how every
/// parameter behaves without the pass. The concrete arms name only the types codegen can seed as
/// unboxed scalars, so a proof the prologue could not act on is never recorded.
pub const InferredParamType = enum {
    unknown,
    fixnum,
    float,
};

/// Description of a word to be compiled for AOT C emission.
pub const AotWordDesc = struct {
    name: []const u8,
    instructions: []const Instruction,
    input_count: u8,
    output_count: u8,
    word_id: u32,
    /// Monotonic dispatch id of this word, used to build the runtime
    /// name -> dispatch_id map the AOT loader replays for the protocol
    /// satisfies-check. Zero when the word carries no dispatch id.
    dispatch_id: u32 = 0,
    /// True when the word carries the `generic` marker. AOT codegen emits a
    /// dispatch helper at its call sites so a registered method runs, falling
    /// to the word's default body on a miss.
    is_generic: bool = false,
    /// Prelude words are available in the AOT runtime dictionary. In
    /// permissive AOT a codegen failure here falls through to
    /// `jitInterpretedCall`; strict AOT rejects the build via
    /// `CompoundFallbackRequired` instead.
    is_prelude: bool = false,
    /// Native words have no compound instructions. At runtime they are
    /// dispatched through `jitNativeWordCall`, not the interpreter. They
    /// are included in the resolver so that non-prelude words calling them
    /// are not rejected, but they must not enter compiled_names or be
    /// trial-compiled.
    is_native: bool = false,
    /// Address of the native function for native generic words.
    /// Used by the AOT resolver to populate ResolvedWord.native_fn_ptr
    /// so emitInlinePicCheck can fire at generic call sites.
    native_fn_ptr: ?usize = null,
    /// Full stack effect declaration for this word. Used by the compiler
    /// to track stack shapes through quotation calls.
    stack_effect: ?StackEffect = null,
    /// Types the freeze-time call-site inference pass proved for this word's parameters. Sized and
    /// indexed by `input_count`, so it covers the concrete inputs only; the pass proves nothing for
    /// a word whose effect carries a row variable. Empty when the pass did not run or proved
    /// nothing.
    ///
    /// A concrete entry asserts that every call site in the program passes that type, so codegen
    /// may narrow the parameter with no runtime check.
    inferred_param_types: []const InferredParamType = &.{},
    /// When true, the word never returns to its caller (has the
    /// never-returns marker). The compiler emits terminal control flow
    /// instead of continuing in the current block after the call.
    never_returns: bool = false,
    /// Snapshot of interpreter PIC data for this word's instructions.
    /// Captured during freeze so the AOT compiler can emit inline type
    /// checks preseeded from interpreter profiling.
    pic_snapshot: ?*pic_mod.PicTable = null,
    /// Source file containing this word's definition, or null when
    /// unknown. Used by AOT C emission to attach a `#line` directive
    /// at the word's emitted C function entry.
    source_file: ?[]const u8 = null,
    /// 1-based line of this word's definition in `source_file`. Zero
    /// when unknown.
    source_line: usize = 0,
    /// True when the word was synthesized by the runtime (struct accessors, generated conversion
    /// words, etc.) and therefore carries provenance. AOT codegen routes these through the qualified
    /// asm-name form rather than the verbatim-name path used for hand-written words.
    is_generated: bool = false,
    /// Provenance parent for generated words, or null when the word has no meaningful parent.
    /// AOT codegen uses this to format the qualified asm-name override as `<parent>/<name>`;
    /// a null or empty parent falls back to a bare-name asm-name.
    parent: ?[]const u8 = null,
    /// Dispatch ID for bounded call sites. Zero when the word is not a
    /// bounded generic.
    bounded_dispatch_id: u32 = 0,
    /// When non-null, this word is a bounded generic (protocol- or
    /// combinator-bound). AOT codegen emits the satisfies-and-dispatch helper at
    /// call sites, referencing the descriptor via a slot-table index instead of a
    /// process-local pointer.
    bounded_constraint: ?dispatch_helpers.BoundedConstraint = null,
    /// Arity for the bounded dispatch. Meaningful only when `bounded_constraint` is non-null.
    bounded_arity: dispatch_helpers.ProtocolArity = .unary,
};

const supported_indexed_stack_ops = [_][]const u8{ "pick-n", "<rot-n", "rot-n>", "nip-n" };

fn isIndexedStackOp(name: []const u8) bool {
    for (supported_indexed_stack_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

const IteratorOpcode = enum(u8) {
    next = 1,
    collect = 2,
    count = 3,
    close_iterator = 4,
    take = 5,
    drop = 6,
    each = 7,
    map = 8,
    filter = 9,
    reduce = 10,
};

const IteratorEffects = struct {
    inputs: usize,
    outputs: usize,
    dynamic: bool,
};

fn iteratorEffects(opcode: IteratorOpcode) IteratorEffects {
    return switch (opcode) {
        .next => .{ .inputs = 1, .outputs = 1, .dynamic = false },
        .collect => .{ .inputs = 1, .outputs = 1, .dynamic = false },
        .count => .{ .inputs = 1, .outputs = 1, .dynamic = false },
        .close_iterator => .{ .inputs = 1, .outputs = 0, .dynamic = false },
        .take => .{ .inputs = 2, .outputs = 1, .dynamic = false },
        .drop => .{ .inputs = 2, .outputs = 1, .dynamic = false },
        .each => .{ .inputs = 2, .outputs = 0, .dynamic = true },
        .map => .{ .inputs = 2, .outputs = 1, .dynamic = true },
        .filter => .{ .inputs = 2, .outputs = 1, .dynamic = true },
        .reduce => .{ .inputs = 3, .outputs = 1, .dynamic = true },
    };
}

/// Layout of Value for use in generated IR code, determined at runtime
/// since Zig unions don't expose field offsets at comptime.
const ValueLayout = struct {
    const TagType = std.meta.Tag(Value);
    const value_size: usize = @sizeOf(Value);
    const tag_size: usize = @sizeOf(TagType);
    const fixnum_tag: u8 = @intFromEnum(@as(TagType, .fixnum));
    const quotation_tag: u8 = @intFromEnum(@as(TagType, .quotation));
    const tagged_tag: u8 = @intFromEnum(@as(TagType, .tagged));

    const ir_tag_type: c_uint = switch (tag_size) {
        1 => c.IR_U8,
        2 => c.IR_U16,
        4 => c.IR_U32,
        else => unreachable,
    };

    const PayloadKind = enum {
        void_,
        i64_,
        f64_,
        bool_,
        ptr,
        slice,
        dual_ptr,
        inline_,
    };

    fn payloadKindOf(tag: TagType) PayloadKind {
        return switch (tag) {
            .unit => .void_,
            .fixnum => .i64_,
            .float => .f64_,
            .boolean => .bool_,
            .hash, .vector, .byte_array, .set, .mutable_map, .array, .stream, .resource, .parameter, .module, .marker, .struct_type, .struct_instance, .task, .channel, .iterator, .type_val, .sandbox_spec, .error_value, .bignum => .ptr,
            .string, .symbol, .doc_string, .template => .slice,
            .tagged => .dual_ptr,
            .closure => .ptr,
            .quotation, .stack_effect => .inline_,
        };
    }

    var payload_offset: usize = 0;
    var tag_offset: usize = 0;
    var slice_len_offset: usize = 0;
    var quotation_code_ptr_offset: usize = 0;
    var tagged_tag_ptr_offset: usize = 0;
    var tagged_inner_ptr_offset: usize = 0;
    var initialized: bool = false;

    fn ensureInit() void {
        if (initialized) return;

        var v: Value = .{ .fixnum = 0 };
        payload_offset = @intFromPtr(&v.fixnum) - @intFromPtr(&v);

        // Discover the tag offset by finding the byte position where three
        // differently-tagged values each store their expected tag integer.
        // Padding bytes are undefined in Zig unions, so comparing only two
        // values can produce false positives. Three values with distinct
        // non-adjacent tag integers (0, 1, 3) make a coincidental match
        // in padding astronomically unlikely.
        const tag0: u8 = @intFromEnum(@as(TagType, .fixnum)); // 0
        const tag1: u8 = @intFromEnum(@as(TagType, .float)); // 1
        const tag3: u8 = @intFromEnum(@as(TagType, .boolean)); // 3

        var v1: Value = .{ .fixnum = 0 };
        var v2: Value = .{ .float = 0.0 };
        var v3: Value = .{ .boolean = false };

        const b1: [*]const u8 = @ptrCast(&v1);
        const b2: [*]const u8 = @ptrCast(&v2);
        const b3: [*]const u8 = @ptrCast(&v3);

        for (0..@sizeOf(Value)) |i| {
            if (b1[i] == tag0 and b2[i] == tag1 and b3[i] == tag3) {
                tag_offset = i;
                break;
            }
        }

        // Discover the slice len offset. Zig slices are {ptr, len} but the
        // exact position relative to the Value base must be verified at runtime.
        slice_len_offset = payload_offset + @sizeOf(usize);
        var sv: Value = .{ .string = "ABCDE" };
        const sv_bytes: [*]const u8 = @ptrCast(&sv);
        const len_at_offset: *align(1) const usize = @ptrCast(sv_bytes + slice_len_offset);
        std.debug.assert(len_at_offset.* == 5);

        // Discover the code_ptr offset within a quotation Value by writing
        // a sentinel pointer and scanning for it.
        const sentinel: *const anyopaque = @ptrFromInt(0xDEAD_BEEF_CAFE_F00D);
        var qv: Value = .{ .quotation = .{ .instructions = &.{}, .code_ptr = sentinel } };
        const qv_bytes: [*]const u8 = @ptrCast(&qv);
        var found_code_ptr = false;
        for (0..@sizeOf(Value) - @sizeOf(usize) + 1) |offset| {
            const ptr_at: *align(1) const usize = @ptrCast(qv_bytes + offset);
            if (ptr_at.* == @intFromPtr(sentinel)) {
                quotation_code_ptr_offset = offset;
                found_code_ptr = true;
                break;
            }
        }
        std.debug.assert(found_code_ptr);

        // tag and inner pointer offsets within the `tagged` variant's double-indirection
        const tag_sentinel_addr: usize = 0xDEAD_BEEF_CAFE_0010;
        const inner_sentinel_addr: usize = 0xDEAD_BEEF_CAFE_0020;

        var tv: Value = .{ .tagged = .{
            .tag = @ptrFromInt(tag_sentinel_addr),
            .inner = @ptrFromInt(inner_sentinel_addr),
        } };

        const tv_bytes: [*]const u8 = @ptrCast(&tv);
        var found_tag_ptr = false;
        var found_inner_ptr = false;
        for (0..@sizeOf(Value) - @sizeOf(usize) + 1) |offset| {
            const ptr_at: *align(1) const usize = @ptrCast(tv_bytes + offset);
            if (!found_tag_ptr and ptr_at.* == tag_sentinel_addr) {
                tagged_tag_ptr_offset = offset;
                found_tag_ptr = true;
            } else if (!found_inner_ptr and ptr_at.* == inner_sentinel_addr) {
                tagged_inner_ptr_offset = offset;
                found_inner_ptr = true;
            }

            if (found_tag_ptr and found_inner_ptr) break;
        }

        std.debug.assert(found_tag_ptr);
        std.debug.assert(found_inner_ptr);

        initialized = true;
    }
};

/// Layout of StructInstance for use in generated IR code, determined at
/// runtime since Zig structs don't expose field offsets at comptime.
const StructInstanceLayout = struct {
    var struct_type_offset: usize = 0;
    var fields_ptr_offset: usize = 0;
    var initialized: bool = false;

    fn ensureInit() void {
        if (initialized) return;

        var dummy: StructInstance = undefined;
        const base: usize = @intFromPtr(&dummy);
        struct_type_offset = @intFromPtr(&dummy.struct_type) - base;
        fields_ptr_offset = @intFromPtr(&dummy.fields.ptr) - base;

        initialized = true;
    }
};

/// Result of resolving a word name to a dispatch table entry.
pub const ResolvedWord = struct {
    word_id: u32,
    input_count: u8,
    output_count: u8,
    /// True when the underlying word definition is a native primitive.
    /// Drives routing between `emitNativeWordCall` and `emitAotWordCall`
    /// in AOT mode; in JIT mode, native sites that participate in PIC
    /// inline dispatch additionally set `native_fn_ptr`.
    is_native: bool = false,
    native_fn_ptr: ?usize = null,
    stack_effect_ptr: ?usize = null,
    /// When non-null, the callee has row-variable quotation parameters.
    /// The caller must specialize the effect at the call site using
    /// resolveRowVariableEffect() before using input_count/output_count.
    callee_effect: ?*const StackEffect = null,
    /// When true, the word never returns to its caller (e.g., throw, rethrow).
    /// The compiler emits a terminal return after the call instead of
    /// continuing control flow in the current block.
    never_returns: bool = false,
    /// Monotonic dispatch ID of the callee, used by the protocol-bounded
    /// dispatch helper to resolve the concrete-type method.
    dispatch_id: u32 = 0,
    /// When non-null, this call is a bounded generic dispatch site (protocol- or
    /// combinator-bound): the compiler emits `satisfiesAndDispatch` instead of
    /// installing a PIC or an ordinary dispatch. Carries the bound and arity.
    bounded_constraint: ?dispatch_helpers.BoundedConstraint = null,
    bounded_arity: dispatch_helpers.ProtocolArity = .unary,
    /// True when the callee carries the `generic` marker but is not bounded.
    /// AOT codegen emits the plain-generic dispatch helper at the call site.
    is_generic: bool = false,
    /// Diagnostic identity (`satisfies-and-dispatch[<name>]`) baked into
    /// the helper call so word traces, scheduler dumps, and error backtraces
    /// name the bounded site by its constraint. Set whenever `bounded_constraint`
    /// is set.
    bounded_trace_name: ?[]const u8 = null,
    /// True when the callee's compiled body ends with an opaque row region
    /// (or a dynamic call) rather than a concrete-arity stack, so its real
    /// output depth is determined at runtime. The declared `output_count` is
    /// then not a faithful model of the call result: the call site must
    /// collapse the abstract stack to a fresh row rather than apply the
    /// declared concrete effect, or a later branch merge sees diverging
    /// depths. Populated from the row-returning set discovered before Pass 1a.
    returns_row: bool = false,
};

/// Callback interface for resolving word names to dispatch table IDs.
/// Used during compilation to map `call_word` names to JIT dispatch entries.
pub const WordResolver = struct {
    resolve: *const fn ([]const u8, *anyopaque) ?ResolvedWord,
    user_data: *anyopaque,
    /// Stable pointer to the JitDispatchTable, baked into generated code as a constant.
    dispatch_table_ptr: *const anyopaque,
};

/// Layout of JitDispatchTable and JitEntry for generated IR code.
const DispatchLayout = struct {
    var items_ptr_offset: usize = 0;
    var entry_size: usize = 0;
    var code_ptr_offset: usize = 0;
    var initialized: bool = false;

    fn ensureInit() void {
        if (initialized) return;

        var table = JitDispatchTable.init(std.heap.page_allocator);
        const table_base: usize = @intFromPtr(&table);
        const items_ptr_addr: usize = @intFromPtr(&table.entries.items.ptr);
        items_ptr_offset = items_ptr_addr - table_base;

        entry_size = @sizeOf(JitEntry);

        var dummy_entry = JitEntry{ .code_ptr = null, .jit_buf = null, .word_name = "" };
        const entry_base: usize = @intFromPtr(&dummy_entry);
        const code_ptr_addr: usize = @intFromPtr(&dummy_entry.code_ptr);
        code_ptr_offset = code_ptr_addr - entry_base;

        initialized = true;
    }
};

/// Offsets for loading ctx.dispatch.generation at runtime.
const DispatchGenerationLayout = struct {
    var dispatch_offset: usize = 0;
    var generation_offset: usize = 0;
    var initialized: bool = false;

    fn ensureInit() void {
        if (initialized) return;
        dispatch_offset = @offsetOf(Context, "dispatch");
        generation_offset = @offsetOf(dispatch_mod.DispatchTable, "generation");
        initialized = true;
    }
};

/// Given a dispatch descriptor pointer, search the builtin_type_array to find
/// which Value tag it corresponds to. Returns null for non-builtin types
/// (tagged, struct_instance, resource with instance-specific descriptors).
fn reverseMapDescriptorToTag(
    interp_ctx: *const Context,
    descriptor: *const TypeDescriptor,
) ?std.meta.Tag(Value) {
    for (interp_ctx.builtin_type_array, 0..) |slot, i| {
        if (slot) |tv| {
            if (tv.descriptor) |desc| {
                if (desc == descriptor) return @enumFromInt(i);
            }
        }
    }
    return null;
}

// =============================================================================
// Emit helpers
// =============================================================================

/// Produce an IR constant for a variant's tag value.
fn emitTagConst(ctx: *c.ir_ctx, tag: ValueLayout.TagType) c.ir_ref {
    const tag_int: u8 = @intFromEnum(tag);
    return switch (ValueLayout.tag_size) {
        1 => c.ir_const_u8(ctx, tag_int),
        2 => c.ir_const_u16(ctx, tag_int),
        4 => c.ir_const_u32(ctx, tag_int),
        else => unreachable,
    };
}

/// Map a type name string to an IR tag constant for the corresponding Value variant.
/// Returns null for types that need pointer comparison (virtual types, struct types).
fn mapTypeNameToTagConst(state: *CompileState, name: []const u8) ?c.ir_ref {
    const ctx = state.ctx;

    if (std.mem.eql(u8, name, "fixnum")) return state.fixnum_tag_const;
    if (std.mem.eql(u8, name, "float")) return state.float_tag_const;
    if (std.mem.eql(u8, name, "boolean")) return state.boolean_tag_const;
    if (std.mem.eql(u8, name, "string")) return emitTagConst(ctx, .string);
    if (std.mem.eql(u8, name, "symbol")) return emitTagConst(ctx, .symbol);
    if (std.mem.eql(u8, name, "array")) return emitTagConst(ctx, .array);
    if (std.mem.eql(u8, name, "quotation")) return emitTagConst(ctx, .quotation);
    if (std.mem.eql(u8, name, "hash")) return emitTagConst(ctx, .hash);
    if (std.mem.eql(u8, name, "vector")) return emitTagConst(ctx, .vector);
    if (std.mem.eql(u8, name, "byte-array")) return emitTagConst(ctx, .byte_array);
    if (std.mem.eql(u8, name, "set")) return emitTagConst(ctx, .set);
    if (std.mem.eql(u8, name, "mutable-map")) return emitTagConst(ctx, .mutable_map);
    if (std.mem.eql(u8, name, "bignum")) return emitTagConst(ctx, .bignum);

    return null;
}

/// Check the tag of a Value at elem_addr; bail if it doesn't match expected_tag.
fn emitTagCheck(
    ctx: *c.ir_ctx,
    elem_addr: c.ir_ref,
    expected_tag: c.ir_ref,
    tag_offset_const: c.ir_ref,
    bail_status: c.ir_ref,
) void {
    const tag_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, tag_offset_const);
    const tag_val = c._ir_LOAD(ctx, ValueLayout.ir_tag_type, tag_addr);
    const tag_mismatch = c.ir_fold2(ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), tag_val, expected_tag);
    const if_mismatch = c._ir_IF(ctx, tag_mismatch);
    c._ir_IF_TRUE_cold(ctx, if_mismatch);
    c._ir_RETURN(ctx, bail_status);
    c._ir_IF_FALSE(ctx, if_mismatch);
}

/// Call an error-reporting callback and return error_propagate_status.
/// Replaces the bail_status return pattern: instead of returning status 1
/// (bail) and relying on the caller to retry, this sets jit_pending_error
/// via the callback and returns status 2 (error_propagate).
fn emitErrorReturn(state: *CompileState, error_fn: c.ir_ref) void {
    const ctx = state.ctx;
    const ctx_val = if (state.preloaded_ctx_val != c.IR_UNUSED)
        state.preloaded_ctx_val
    else blk: {
        JitContextLayout.ensureInit();
        const ctx_off = c.ir_const_addr(ctx, JitContextLayout.ctx_offset);
        const ctx_addr2 = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
        break :blk c._ir_LOAD(ctx, c.IR_ADDR, ctx_addr2);
    };
    const call_result = c._ir_CALL_1(ctx, c.IR_I32, error_fn, ctx_val);
    c._ir_RETURN(ctx, call_result);
}

/// Check the tag of a Value at elem_addr; on mismatch, call an error
/// callback and return error_propagate_status instead of bailing.
fn emitTagCheckOrError(
    state: *CompileState,
    elem_addr: c.ir_ref,
    expected_tag: c.ir_ref,
    error_fn: c.ir_ref,
) void {
    const ctx = state.ctx;
    const tag_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, state.tag_offset_const);
    const tag_val = c._ir_LOAD(ctx, ValueLayout.ir_tag_type, tag_addr);
    const tag_mismatch = c.ir_fold2(ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), tag_val, expected_tag);
    const if_mismatch = c._ir_IF(ctx, tag_mismatch);
    c._ir_IF_TRUE_cold(ctx, if_mismatch);
    emitErrorReturn(state, error_fn);
    c._ir_IF_FALSE(ctx, if_mismatch);
}

/// Load an i64 payload from a Value at elem_addr.
fn emitUnboxI64(ctx: *c.ir_ctx, elem_addr: c.ir_ref, payload_offset_const: c.ir_ref) c.ir_ref {
    const payload_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, payload_offset_const);
    return c._ir_LOAD(ctx, c.IR_I64, payload_addr);
}

/// Load an f64 payload from a Value at elem_addr.
fn emitUnboxF64(ctx: *c.ir_ctx, elem_addr: c.ir_ref, payload_offset_const: c.ir_ref) c.ir_ref {
    const payload_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, payload_offset_const);
    return c._ir_LOAD(ctx, c.IR_DOUBLE, payload_addr);
}

/// Load a bool payload from a Value at elem_addr.
fn emitUnboxBool(ctx: *c.ir_ctx, elem_addr: c.ir_ref, payload_offset_const: c.ir_ref) c.ir_ref {
    const payload_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, payload_offset_const);
    return c._ir_LOAD(ctx, c.IR_BOOL, payload_addr);
}

/// Load a pointer payload from a Value at elem_addr.
fn emitUnboxPtr(ctx: *c.ir_ctx, elem_addr: c.ir_ref, payload_offset_const: c.ir_ref) c.ir_ref {
    const payload_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, payload_offset_const);
    return c._ir_LOAD(ctx, c.IR_ADDR, payload_addr);
}

const SliceRefs = struct { ptr: c.ir_ref, len: c.ir_ref };

/// Load a slice (ptr + len) payload from a Value at elem_addr.
fn emitUnboxSlice(
    ctx: *c.ir_ctx,
    elem_addr: c.ir_ref,
    payload_offset_const: c.ir_ref,
    slice_len_offset_const: c.ir_ref,
) SliceRefs {
    const ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, payload_offset_const);
    const ptr_val = c._ir_LOAD(ctx, c.IR_ADDR, ptr_addr);
    const len_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, slice_len_offset_const);
    const len_val = c._ir_LOAD(ctx, c.IR_ADDR, len_addr);
    return .{ .ptr = ptr_val, .len = len_val };
}

/// Store a tag at tag_offset within a Value at dest_addr.
fn emitBoxTag(ctx: *c.ir_ctx, dest_addr: c.ir_ref, tag_offset_const: c.ir_ref, tag_const: c.ir_ref) void {
    const tag_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), dest_addr, tag_offset_const);
    c._ir_STORE(ctx, tag_addr, tag_const);
}

/// Store a tag and a single payload value into a Value at dest_addr.
/// Works for i64, f64, bool, and pointer payloads (the IR type is
/// carried by the val ref itself).
fn emitBoxPayload(
    ctx: *c.ir_ctx,
    dest_addr: c.ir_ref,
    tag_offset_const: c.ir_ref,
    payload_offset_const: c.ir_ref,
    tag_const: c.ir_ref,
    val: c.ir_ref,
) void {
    emitBoxTag(ctx, dest_addr, tag_offset_const, tag_const);
    const payload_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), dest_addr, payload_offset_const);
    c._ir_STORE(ctx, payload_addr, val);
}

/// Store a tag and a slice (ptr + len) payload into a Value at dest_addr.
/// Used to construct string/symbol literal Values inline from a static
/// pointer and length, with no heap allocation.
fn emitBoxSlice(
    ctx: *c.ir_ctx,
    dest_addr: c.ir_ref,
    tag_offset_const: c.ir_ref,
    payload_offset_const: c.ir_ref,
    slice_len_offset_const: c.ir_ref,
    tag_const: c.ir_ref,
    ptr_val: c.ir_ref,
    len_val: c.ir_ref,
) void {
    emitBoxTag(ctx, dest_addr, tag_offset_const, tag_const);
    const ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), dest_addr, payload_offset_const);
    c._ir_STORE(ctx, ptr_addr, ptr_val);
    const len_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), dest_addr, slice_len_offset_const);
    c._ir_STORE(ctx, len_addr, len_val);
}

/// Result of numeric tag validation: the loaded tag and per-type booleans.
const NumericValidation = struct {
    is_fixnum: c.ir_ref,
    elem_addr: c.ir_ref,
};

/// Result of non-bailing numeric tag check: includes is_numeric for branching.
const NumericTagCheck = struct {
    is_fixnum: c.ir_ref,
    is_numeric: c.ir_ref,
    elem_addr: c.ir_ref,
};

/// Load a value's tag and check whether it is fixnum or float. Does NOT bail;
/// the caller is responsible for branching on is_numeric.
fn emitNumericTagCheckNoBail(
    ctx: *c.ir_ctx,
    slot: usize,
    base_addr: c.ir_ref,
    tag_offset_const: c.ir_ref,
    fixnum_tag_const: c.ir_ref,
    float_tag_const: c.ir_ref,
) NumericTagCheck {
    const slot_byte_offset = c.ir_const_addr(ctx, slot * ValueLayout.value_size);
    const elem_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
    const tag_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, tag_offset_const);
    const tag_val = c._ir_LOAD(ctx, ValueLayout.ir_tag_type, tag_addr);

    const is_fixnum = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), tag_val, fixnum_tag_const);
    const is_float = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), tag_val, float_tag_const);
    const is_numeric = c.ir_fold2(ctx, c.IR_OPT(c.IR_OR, c.IR_BOOL), is_fixnum, is_float);

    return .{ .is_fixnum = is_fixnum, .is_numeric = is_numeric, .elem_addr = elem_addr };
}

/// Load a value's tag and validate it is fixnum or float. Bail if neither.
/// Returns the is_fixnum boolean (true = fixnum, false = float after validation).
fn emitNumericTagValidation(
    ctx: *c.ir_ctx,
    slot: usize,
    base_addr: c.ir_ref,
    tag_offset_const: c.ir_ref,
    fixnum_tag_const: c.ir_ref,
    float_tag_const: c.ir_ref,
    bail_status: c.ir_ref,
) NumericValidation {
    const check = emitNumericTagCheckNoBail(ctx, slot, base_addr, tag_offset_const, fixnum_tag_const, float_tag_const);

    const if_not_numeric = c._ir_IF(ctx, check.is_numeric);
    c._ir_IF_FALSE_cold(ctx, if_not_numeric);
    c._ir_RETURN(ctx, bail_status);
    c._ir_IF_TRUE(ctx, if_not_numeric);

    return .{ .is_fixnum = check.is_fixnum, .elem_addr = check.elem_addr };
}

/// Given an operand address and its is_fixnum boolean, emit a conditional
/// f64 load: if fixnum, load i64 and convert via INT2FP; if float, load f64
/// directly. Returns the f64 IR ref via IF/MERGE/PHI.
fn emitConditionalF64Load(
    ctx: *c.ir_ctx,
    elem_addr: c.ir_ref,
    is_fixnum: c.ir_ref,
    payload_offset_const: c.ir_ref,
) c.ir_ref {
    const payload_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, payload_offset_const);

    const if_fixnum = c._ir_IF(ctx, is_fixnum);

    // Fixnum path: load i64, convert to f64
    c._ir_IF_TRUE(ctx, if_fixnum);
    const raw_i64 = c._ir_LOAD(ctx, c.IR_I64, payload_addr);
    const conv_f64 = c.ir_fold1(ctx, c.IR_OPT(c.IR_INT2FP, c.IR_DOUBLE), raw_i64);
    const end_conv = c._ir_END(ctx);

    // Float path: load f64 directly
    c._ir_IF_FALSE(ctx, if_fixnum);
    const raw_f64 = c._ir_LOAD(ctx, c.IR_DOUBLE, payload_addr);
    const end_raw = c._ir_END(ctx);

    c._ir_MERGE_2(ctx, end_conv, end_raw);
    return c._ir_PHI_2(ctx, c.IR_DOUBLE, conv_f64, raw_f64);
}

/// Polymorphic arithmetic operation identifier.
const PolyArithOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
};

/// Emit a per-operation fallback that calls the polymorphic native for a single arithmetic operation.
/// The operands are already in physical memory at slot_a and slot_b.
/// The native pops both and pushes one result, leaving it at slot_a (dest_slot).
///
/// Without the native the body is NotCompilable, matching `emitResolvedNativeCallback`. This arm
/// covers fixnum overflow and non-fixnum/float operands, so only the native's numeric-tower
/// promotion is a correct continuation. A terminal error stub here would misreport overflow as a
/// type mismatch. It also left this arm's control dead while the caller merged it with the numeric
/// path, and `emitC` runs no SCCP pass to delete a dead merge input, so `ir_build_cfg` followed the
/// dangling control edge and looped forever.
fn emitPerOperationFallback(
    state: *CompileState,
    op_name: []const u8,
    slot_a: usize,
    slot_b: usize,
    line: usize,
) IrCodegenError!void {
    const ctx = state.ctx;

    const res = state.resolver orelse {
        state.not_compilable_reason = .unresolvable_word;
        return IrCodegenError.NotCompilable;
    };
    const resolved = res.resolve(op_name, res.user_data) orelse {
        state.not_compilable_reason = .unresolvable_word;
        return IrCodegenError.NotCompilable;
    };

    // Store physical SP so the native sees both operands.
    // SP must point past slot_b (= slot_a + 1), i.e., slot_b + 1 elements.
    const sp_for_call = c.ir_const_addr(ctx, slot_b + 1);
    const new_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, sp_for_call);
    c._ir_STORE(ctx, state.sp_ptr, new_sp);

    // Load the interpreter Context pointer.
    const ctx_val = if (state.preloaded_ctx_val != c.IR_UNUSED)
        state.preloaded_ctx_val
    else blk: {
        JitContextLayout.ensureInit();
        const ctx_off = c.ir_const_addr(ctx, JitContextLayout.ctx_offset);
        const ctx_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
        break :blk c._ir_LOAD(ctx, c.IR_ADDR, ctx_addr);
    };

    // Call the polymorphic native: use jitNativeCall when a function pointer
    // is available (JIT mode), jitNativeWordCall with word_id otherwise (AOT).
    if (!state.aot_mode and resolved.native_fn_ptr != null) {
        const fn_ptr_const = c.ir_const_addr(ctx, resolved.native_fn_ptr.?);
        const call_result = c._ir_CALL_2(ctx, c.IR_I32, state.native_call_fn, ctx_val, fn_ptr_const);
        emitCallbackPostCheck(state, call_result, call_result, null, .{ .named = .{ .name = op_name, .line = line } });
    } else {
        const word_id_const = c.ir_const_addr(ctx, resolved.word_id);
        const line_const = c.ir_const_addr(ctx, line);
        state.noteAotFallbackEmission(.per_op_native, op_name, resolved.word_id, line);
        const call_result = c._ir_CALL_3(ctx, c.IR_I32, state.native_word_call_fn, ctx_val, word_id_const, line_const);
        emitCallbackPostCheck(state, call_result, state.error_propagate_status, null, .none);
    }

    // After the native returns, SP = base_idx + slot_a + 1 and the result
    // is at physical slot slot_a. The caller sets the abstract stack entry
    // to raw_at_slot(dest_slot).
    _ = slot_a;
}

/// Emit polymorphic binary arithmetic that handles both fixnum and float
/// operands at runtime via tag-check branching. Non-numeric operands fall
/// back to the polymorphic native via `jitNativeWordCall` (the
/// `per_op_native` fallback category) for just that operation, then continue
/// compiled execution. The result is written as a boxed Value at dest_slot.
fn emitPolymorphicBinaryArith(
    state: *CompileState,
    slot_a: usize,
    slot_b: usize,
    dest_slot: usize,
    op: PolyArithOp,
    line: usize,
) IrCodegenError!void {
    const ctx = state.ctx;

    // Check both operands for numeric tags (no bail on mismatch).
    const va = emitNumericTagCheckNoBail(
        ctx,
        slot_a,
        state.base_addr,
        state.tag_offset_const,
        state.fixnum_tag_const,
        state.float_tag_const,
    );
    const vb = emitNumericTagCheckNoBail(
        ctx,
        slot_b,
        state.base_addr,
        state.tag_offset_const,
        state.fixnum_tag_const,
        state.float_tag_const,
    );

    // Branch: both operands numeric (fixnum or float)?
    const both_numeric = c.ir_fold2(ctx, c.IR_OPT(c.IR_AND, c.IR_BOOL), va.is_numeric, vb.is_numeric);
    const if_numeric = c._ir_IF(ctx, both_numeric);

    // Collect fixnum error-path ends (overflow, div-by-zero, minInt/-1).
    // These merge with the non-numeric fallback instead of bailing.
    var fixnum_error_ends: [2]c.ir_ref = .{ c.IR_UNUSED, c.IR_UNUSED };
    var fixnum_error_count: usize = 0;

    // === Numeric path (hottt) ===
    c._ir_IF_TRUE(ctx, if_numeric);
    {
        // Destination address
        const dest_addr = liveSlotAddr(state, dest_slot);

        // Branch: both fixnum?
        const both_fixnum = c.ir_fold2(ctx, c.IR_OPT(c.IR_AND, c.IR_BOOL), va.is_fixnum, vb.is_fixnum);
        const if_both_fixnum = c._ir_IF(ctx, both_fixnum);

        // === Fixnum path ===
        c._ir_IF_TRUE(ctx, if_both_fixnum);
        {
            const a_i64 = emitUnboxI64(ctx, va.elem_addr, state.payload_offset_const);
            const b_i64 = emitUnboxI64(ctx, vb.elem_addr, state.payload_offset_const);

            switch (op) {
                .add, .sub, .mul => {
                    const ir_op = switch (op) {
                        .add => c.IR_ADD_OV,
                        .sub => c.IR_SUB_OV,
                        .mul => c.IR_MUL_OV,
                        else => unreachable,
                    };
                    const result_i64 = c.ir_fold2(ctx, c.IR_OPT(ir_op, c.IR_I64), a_i64, b_i64);
                    const ovf = c.ir_fold1(ctx, c.IR_OPT(c.IR_OVERFLOW, c.IR_BOOL), result_i64);
                    const if_ovf = c._ir_IF(ctx, ovf);
                    c._ir_IF_TRUE_cold(ctx, if_ovf);
                    fixnum_error_ends[fixnum_error_count] = c._ir_END(ctx);
                    fixnum_error_count += 1;
                    c._ir_IF_FALSE(ctx, if_ovf);
                    emitBoxPayload(ctx, dest_addr, state.tag_offset_const, state.payload_offset_const, state.fixnum_tag_const, result_i64);
                },
                .div => {
                    const zero = c.ir_const_i64(ctx, 0);
                    const is_zero = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), b_i64, zero);
                    const if_zero = c._ir_IF(ctx, is_zero);
                    c._ir_IF_TRUE_cold(ctx, if_zero);
                    fixnum_error_ends[fixnum_error_count] = c._ir_END(ctx);
                    fixnum_error_count += 1;
                    c._ir_IF_FALSE(ctx, if_zero);

                    const min_val = c.ir_const_i64(ctx, std.math.minInt(i64));
                    const neg_one = c.ir_const_i64(ctx, -1);
                    const is_min = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), a_i64, min_val);
                    const is_neg_one = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), b_i64, neg_one);
                    const is_overflow = c.ir_fold2(ctx, c.IR_OPT(c.IR_AND, c.IR_BOOL), is_min, is_neg_one);
                    const if_ov = c._ir_IF(ctx, is_overflow);
                    c._ir_IF_TRUE_cold(ctx, if_ov);
                    fixnum_error_ends[fixnum_error_count] = c._ir_END(ctx);
                    fixnum_error_count += 1;
                    c._ir_IF_FALSE(ctx, if_ov);

                    const result_i64 = c.ir_fold2(ctx, c.IR_OPT(c.IR_DIV, c.IR_I64), a_i64, b_i64);
                    emitBoxPayload(ctx, dest_addr, state.tag_offset_const, state.payload_offset_const, state.fixnum_tag_const, result_i64);
                },
                .mod => {
                    const zero = c.ir_const_i64(ctx, 0);
                    const is_zero = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), b_i64, zero);
                    const if_zero = c._ir_IF(ctx, is_zero);
                    c._ir_IF_TRUE_cold(ctx, if_zero);
                    fixnum_error_ends[fixnum_error_count] = c._ir_END(ctx);
                    fixnum_error_count += 1;
                    c._ir_IF_FALSE(ctx, if_zero);

                    // Euclidean modulo
                    const rem_val = c.ir_fold2(ctx, c.IR_OPT(c.IR_MOD, c.IR_I64), a_i64, b_i64);
                    const rem_xor_b = c.ir_fold2(ctx, c.IR_OPT(c.IR_XOR, c.IR_I64), rem_val, b_i64);
                    const signs_differ = c.ir_fold2(ctx, c.IR_OPT(c.IR_LT, c.IR_BOOL), rem_xor_b, zero);
                    const rem_nonzero = c.ir_fold2(ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), rem_val, zero);
                    const needs_adjust = c.ir_fold2(ctx, c.IR_OPT(c.IR_AND, c.IR_BOOL), rem_nonzero, signs_differ);
                    const adjusted = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_I64), rem_val, b_i64);
                    const result_i64 = c.ir_fold3(ctx, c.IR_OPT(c.IR_COND, c.IR_I64), needs_adjust, adjusted, rem_val);
                    emitBoxPayload(ctx, dest_addr, state.tag_offset_const, state.payload_offset_const, state.fixnum_tag_const, result_i64);
                },
            }
        }
        const end_fixnum = c._ir_END(ctx);

        // === Float path (at least one operand is float) ===
        c._ir_IF_FALSE(ctx, if_both_fixnum);
        {
            const a_f64 = emitConditionalF64Load(ctx, va.elem_addr, va.is_fixnum, state.payload_offset_const);
            const b_f64 = emitConditionalF64Load(ctx, vb.elem_addr, vb.is_fixnum, state.payload_offset_const);

            const result_f64 = switch (op) {
                .add => c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_DOUBLE), a_f64, b_f64),
                .sub => c.ir_fold2(ctx, c.IR_OPT(c.IR_SUB, c.IR_DOUBLE), a_f64, b_f64),
                .mul => c.ir_fold2(ctx, c.IR_OPT(c.IR_MUL, c.IR_DOUBLE), a_f64, b_f64),
                .div => c.ir_fold2(ctx, c.IR_OPT(c.IR_DIV, c.IR_DOUBLE), a_f64, b_f64),
                .mod => emitFloatRemainder(ctx, a_f64, b_f64),
            };

            emitBoxPayload(ctx, dest_addr, state.tag_offset_const, state.payload_offset_const, state.float_tag_const, result_f64);
        }
        const end_float = c._ir_END(ctx);

        c._ir_MERGE_2(ctx, end_fixnum, end_float);
    }
    const end_numeric = c._ir_END(ctx);

    // === Native fallback (cold): call the polymorphic native ===
    // Reached from non-numeric types AND fixnum overflow/division errors.
    c._ir_IF_FALSE_cold(ctx, if_numeric);

    // Merge fixnum error paths into the fallback entry.
    if (fixnum_error_count > 0) {
        const end_non_numeric = c._ir_END(ctx);
        if (fixnum_error_count == 1) {
            c._ir_MERGE_2(ctx, end_non_numeric, fixnum_error_ends[0]);
        } else {
            var inputs: [3]c.ir_ref = undefined;
            inputs[0] = end_non_numeric;
            inputs[1] = fixnum_error_ends[0];
            inputs[2] = fixnum_error_ends[1];
            c._ir_MERGE_N(ctx, @as(c.ir_ref, @intCast(fixnum_error_count + 1)), &inputs);
        }
    }

    {
        const op_name: []const u8 = switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
        };
        // Save state refs before the callback (it may refresh them).
        const saved_items_ptr = state.items_ptr;
        const saved_base_addr = state.base_addr;
        try emitPerOperationFallback(state, op_name, slot_a, slot_b, line);
        // Restore so the MERGE sees consistent refs from both paths.
        state.items_ptr = saved_items_ptr;
        state.base_addr = saved_base_addr;
    }
    const end_fallback = c._ir_END(ctx);

    c._ir_MERGE_2(ctx, end_numeric, end_fallback);

    // After the merge, the stack backing may have been reallocated by the
    // fallback path's native call. Refresh so subsequent code uses live refs.
    refreshCachedStackPointer(state);
}

/// Emit truncating float remainder: a - trunc(a/b) * b.
/// Matches the interpreter's @rem semantics for float operands of %.
fn emitFloatRemainder(ctx: *c.ir_ctx, a: c.ir_ref, b: c.ir_ref) c.ir_ref {
    // quotient = a / b
    const quotient = c.ir_fold2(ctx, c.IR_OPT(c.IR_DIV, c.IR_DOUBLE), a, b);
    // trunc_q = (double)(int64_t)quotient -- truncate toward zero
    const trunc_i64 = c.ir_fold1(ctx, c.IR_OPT(c.IR_FP2INT, c.IR_I64), quotient);
    const trunc_f64 = c.ir_fold1(ctx, c.IR_OPT(c.IR_INT2FP, c.IR_DOUBLE), trunc_i64);
    // result = a - trunc_f64 * b
    const product = c.ir_fold2(ctx, c.IR_OPT(c.IR_MUL, c.IR_DOUBLE), trunc_f64, b);
    return c.ir_fold2(ctx, c.IR_OPT(c.IR_SUB, c.IR_DOUBLE), a, product);
}

/// Copy an entire Value's raw bytes into the stack slot at dest_addr.
/// Emits one STORE per 8-byte word, with the literal bytes baked in
/// as IR constants.
fn emitPushValue(ctx: *c.ir_ctx, val: *const Value, dest_addr: c.ir_ref) void {
    const raw: [*]const u8 = @ptrCast(val);
    const num_words = ValueLayout.value_size / 8;
    var offset: usize = 0;
    var i: usize = 0;
    while (i < num_words) : (i += 1) {
        const word_ptr: *align(1) const u64 = @ptrCast(raw + offset);
        const word = word_ptr.*;
        const word_const = c.ir_const_u64(ctx, word);
        if (offset == 0) {
            c._ir_STORE(ctx, dest_addr, word_const);
        } else {
            const off_const = c.ir_const_addr(ctx, offset);
            const addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), dest_addr, off_const);
            c._ir_STORE(ctx, addr, word_const);
        }
        offset += 8;
    }
    while (offset < ValueLayout.value_size) : (offset += 1) {
        const byte_val = c.ir_const_u8(ctx, raw[offset]);
        const off_const = c.ir_const_addr(ctx, offset);
        const addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), dest_addr, off_const);
        c._ir_STORE(ctx, addr, byte_val);
    }
}

/// Copy a full Value's raw bytes between two physical stack slots.
fn emitCopySlot(ctx: *c.ir_ctx, base_addr: c.ir_ref, src_slot: usize, dest_slot: usize) void {
    const num_words = ValueLayout.value_size / 8;
    var i: usize = 0;
    while (i < num_words) : (i += 1) {
        const offset = i * 8;
        const src_off = src_slot * ValueLayout.value_size + offset;
        const dest_off = dest_slot * ValueLayout.value_size + offset;
        const src_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, src_off));
        const word_val = c._ir_LOAD(ctx, c.IR_U64, src_addr);
        const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, dest_off));
        c._ir_STORE(ctx, dest_addr, word_val);
    }
    var offset = num_words * 8;
    while (offset < ValueLayout.value_size) : (offset += 1) {
        const src_off = src_slot * ValueLayout.value_size + offset;
        const dest_off = dest_slot * ValueLayout.value_size + offset;
        const src_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, src_off));
        const byte_val = c._ir_LOAD(ctx, c.IR_U8, src_addr);
        const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, dest_off));
        c._ir_STORE(ctx, dest_addr, byte_val);
    }
}

/// Swap two physical stack slots by loading all words first, then storing.
fn emitSwapSlots(ctx: *c.ir_ctx, base_addr: c.ir_ref, slot_a: usize, slot_b: usize) void {
    const num_words = ValueLayout.value_size / 8;
    var a_words: [8]c.ir_ref = undefined;
    var b_words: [8]c.ir_ref = undefined;
    std.debug.assert(num_words <= a_words.len);

    var i: usize = 0;
    while (i < num_words) : (i += 1) {
        const offset = i * 8;
        const a_off = slot_a * ValueLayout.value_size + offset;
        const b_off = slot_b * ValueLayout.value_size + offset;
        const a_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, a_off));
        const b_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, b_off));
        a_words[i] = c._ir_LOAD(ctx, c.IR_U64, a_addr);
        b_words[i] = c._ir_LOAD(ctx, c.IR_U64, b_addr);
    }

    i = 0;
    while (i < num_words) : (i += 1) {
        const offset = i * 8;
        const a_off = slot_a * ValueLayout.value_size + offset;
        const b_off = slot_b * ValueLayout.value_size + offset;
        const a_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, a_off));
        const b_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, b_off));
        c._ir_STORE(ctx, a_addr, b_words[i]);
        c._ir_STORE(ctx, b_addr, a_words[i]);
    }

    // Handle trailing bytes (if value_size is not a multiple of 8)
    var offset = num_words * 8;
    while (offset < ValueLayout.value_size) : (offset += 1) {
        const a_off = slot_a * ValueLayout.value_size + offset;
        const b_off = slot_b * ValueLayout.value_size + offset;
        const a_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, a_off));
        const b_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, b_off));
        const a_byte = c._ir_LOAD(ctx, c.IR_U8, a_addr);
        const b_byte = c._ir_LOAD(ctx, c.IR_U8, b_addr);
        c._ir_STORE(ctx, a_addr, b_byte);
        c._ir_STORE(ctx, b_addr, a_byte);
    }
}

/// Copy a full Value's raw bytes from a runtime pointer into a physical stack slot.
fn emitCopyFromPtr(ctx: *c.ir_ctx, base_addr: c.ir_ref, src_ptr: c.ir_ref, dest_slot: usize) void {
    const num_words = ValueLayout.value_size / 8;
    var i: usize = 0;
    while (i < num_words) : (i += 1) {
        const offset = i * 8;
        const src_addr = if (offset == 0) src_ptr else c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), src_ptr, c.ir_const_addr(ctx, offset));
        const word_val = c._ir_LOAD(ctx, c.IR_U64, src_addr);
        const dest_off = dest_slot * ValueLayout.value_size + offset;
        const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, dest_off));
        c._ir_STORE(ctx, dest_addr, word_val);
    }
    var offset = num_words * 8;
    while (offset < ValueLayout.value_size) : (offset += 1) {
        const src_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), src_ptr, c.ir_const_addr(ctx, offset));
        const byte_val = c._ir_LOAD(ctx, c.IR_U8, src_addr);
        const dest_off = dest_slot * ValueLayout.value_size + offset;
        const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, dest_off));
        c._ir_STORE(ctx, dest_addr, byte_val);
    }
}

/// Copy a full Value's raw bytes from a physical stack slot into a runtime pointer.
fn emitCopyToPtr(ctx: *c.ir_ctx, base_addr: c.ir_ref, src_slot: usize, dest_ptr: c.ir_ref) void {
    const num_words = ValueLayout.value_size / 8;
    var i: usize = 0;
    while (i < num_words) : (i += 1) {
        const offset = i * 8;
        const src_off = src_slot * ValueLayout.value_size + offset;
        const src_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, src_off));
        const word_val = c._ir_LOAD(ctx, c.IR_U64, src_addr);
        const dest_addr = if (offset == 0) dest_ptr else c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), dest_ptr, c.ir_const_addr(ctx, offset));
        c._ir_STORE(ctx, dest_addr, word_val);
    }
    var offset = num_words * 8;
    while (offset < ValueLayout.value_size) : (offset += 1) {
        const src_off = src_slot * ValueLayout.value_size + offset;
        const src_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, src_off));
        const byte_val = c._ir_LOAD(ctx, c.IR_U8, src_addr);
        const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), dest_ptr, c.ir_const_addr(ctx, offset));
        c._ir_STORE(ctx, dest_addr, byte_val);
    }
}

/// Maximum depth of the abstract compilation stack used during word compilation. Each entry tracks
/// the type and form of a value at that stack position. Bounded by the largest word arity in prelude,
/// which is currently 9 for `make-word-info`, 64 should provides plenty headroom.
const max_abstract_stack_depth = 64;

/// Compute a conservative upper bound on the abstract stack depth needed to
/// compile a word during the discovery pass (pass 1). The exact depth is not
/// known until after pass 1 discovers `peak_sp`, so this bound must be generous
/// enough to cover any word without over-counting by too much.
///
/// A single `call_word` instruction can change the abstract stack depth by the
/// called word's stack effect (which may be much larger than 1), making a tight
/// instruction-count-based bound impractical. Instead, we use the total
/// instruction count across all nested quotation bodies, scaled to account for
/// multi-push effects, as the bound. This is still bounded by a minimum of 64
/// to handle pathological cases.
fn estimateStackDepth(instructions: []const Instruction, input_count: usize) usize {
    const total = countTotalInstructions(instructions) + input_count;
    return @max(total, 64);
}

fn countTotalInstructions(instructions: []const Instruction) usize {
    var total: usize = instructions.len;
    for (instructions) |instr| {
        switch (instr.op) {
            .push_literal => |val| {
                if (val == .quotation) {
                    total += countTotalInstructions(val.quotation.instructions);
                }
            },
            else => {},
        }
    }
    return total;
}

/// Unique identity for a symbolic row region, used to compare rows across
/// branch merge and loop back-edge checks.
const RowId = u32;

/// A single `(block-start ir_ref, source line)` pair. Aggregated on
/// `CompileState.source_line_entries` and handed to the patched
/// `ir_emit_c.c` via the `IrCSourceLines` side table so the C
/// emitter can write `#line N "file"` directives at control-flow
/// boundaries inside a word body. Layout must match the C-side
/// `ir_c_line_entry` struct in `ext/ir/ir_emit_c.c` exactly.
pub const LineEntry = extern struct {
    ref: u32,
    line: u32,
};

/// Magic tag that marks a `ctx.data` pointer as the source-line side
/// table the patched `ir_emit_c.c` knows how to consume. Other callers
/// leave `ctx.data` null; the patched code falls back to its
/// no-source-info behavior when the tag does not match.
pub const ir_c_source_lines_magic: u32 = 0x315A4C53; // "1ZLS"

/// Side table installed on `ir_ctx.data` before calling `ir_emit_c`.
/// Layout must match the C-side `ir_c_source_lines` struct in
/// `ext/ir/ir_emit_c.c` exactly. The patched emitter binary-searches
/// `entries` (sorted by `ref` ascending) and emits a `#line` directive
/// before each control-flow boundary block whose start ref matches.
pub const IrCSourceLines = extern struct {
    magic: u32,
    file: [*:0]const u8,
    entries: [*]const LineEntry,
    entries_count: u32,
};

/// Symbolic stack entry: tracks the IR representation of each value on the abstract compilation stack.
const StackEntry = union(enum) {
    /// Unboxed fixnum payload, usable directly in arithmetic and comparisons.
    i64_ref: c.ir_ref,
    /// Unboxed float payload, usable directly in float arithmetic.
    f64_ref: c.ir_ref,
    /// IR boolean from a comparison op or `t`/`f` literal, boxed to a boolean
    /// Value at finalization.
    bool_ref: c.ir_ref,
    /// Captured instruction slice from a quotation literal. Never reaches
    /// finalization -- consumed by `if` at compile time.
    quotation_body: []const Instruction,
    /// Opaque Value written to physical stack slot N. This is used for types
    /// that can't be represented as IR scalars, i.e., anything other than
    /// fixnum / boolean.
    raw_at_slot: usize,
    /// Opaque row region of unknown size inserted when a quotation call has
    /// unresolved row variables. Carries a RowId so that branch merge and
    /// loop back-edge checks can compare symbolic row identity. Operations
    /// on known entries above the region work normally; operations that need
    /// exact positions within the region return NotCompilable.
    row_region: RowId,

    /// Returns the slot index if this is a raw_at_slot.
    fn slotIndex(self: StackEntry) ?usize {
        return switch (self) {
            .raw_at_slot => |s| s,
            else => null,
        };
    }

    /// Returns true if this is an opaque slot.
    fn isAtSlot(self: StackEntry) bool {
        return self == .raw_at_slot;
    }

    /// Returns true if this entry is a symbolic row region.
    fn isRowRegion(self: StackEntry) bool {
        return self == .row_region;
    }

    /// Returns the RowId if this entry is a row_region, null otherwise.
    fn rowId(self: StackEntry) ?RowId {
        return switch (self) {
            .row_region => |id| id,
            else => null,
        };
    }
};

const ExitKind = enum {
    falls_through,
    terminal_return,
    loop_diverged,
};

fn exitFallsThrough(kind: ExitKind) bool {
    return kind == .falls_through;
}

fn mergeNonFallthroughExitKinds(a: ExitKind, b: ExitKind) ExitKind {
    std.debug.assert(!exitFallsThrough(a));
    std.debug.assert(!exitFallsThrough(b));
    if (a == .terminal_return or b == .terminal_return) return .terminal_return;
    return .loop_diverged;
}

/// Identity-keyed slot-index maps that codegen consults when emitting
/// typed-literal pushes. Each map is populated by
/// `aot_image_emit.collectImageSlots` before Pass 2 begins; codegen
/// reads through pointers and never mutates the maps. Bundled into a
/// single struct so the slot-table-literal feature does not balloon
/// every codegen function signature with five extra parameters.
pub const AotImageSlotMaps = struct {
    typevalue_slot_index: *const std.AutoHashMapUnmanaged(*const value_mod.TypeValue, u32),
    struct_type_slot_index: *const std.AutoHashMapUnmanaged(*const value_mod.StructType, u32),
    marker_slot_index: *const std.AutoHashMapUnmanaged(*const value_mod.Marker, u32),
    parameter_slot_index: *const std.AutoHashMapUnmanaged(*const value_mod.Parameter, u32),
    tagged_slot_index: *const std.AutoHashMapUnmanaged(ibc.TaggedKey, u32),
    mutable_map_slot_index: *const std.AutoHashMapUnmanaged(*const value_mod.MutableMap, u32),
    struct_instance_slot_index: *const std.AutoHashMapUnmanaged(*const value_mod.StructInstance, u32),
    vector_slot_index: *const std.AutoHashMapUnmanaged(*const value_mod.Vector, u32),
    protocol_slot_index: *const std.AutoHashMapUnmanaged(*const value_mod.ProtocolDescriptor, u32),
    combinator_slot_index: *const std.AutoHashMapUnmanaged(*const value_mod.ConstraintCombinator, u32),
};

/// Resolution result for a typed-literal slot lookup. Carries the
/// slot index and the C helper name codegen should call. Returned by
/// `slotIndexForTypedLiteral` when the value's pointer was interned
/// during the collection pass; null when the pointer was missed (e.g.
/// reachable only through a code path the seed walks didn't cover),
/// in which case codegen falls through to the legacy name-lookup
/// emission.
const TypedLiteralSlot = struct {
    slot: u32,
    helper_name: [*:0]const u8,
};

/// Resolve a `push_literal` Value to a slot-table reference. Returns
/// null when any of: slot-table emission is disabled, the slot maps are
/// not populated (e.g. pure-AOT build without an interpreter context),
/// the value variant is not a slot-tableable typed literal, or the
/// pointer was not interned during the collection pass. All five
/// type-carrier variants (`.type_val`, `.struct_type`, `.marker`,
/// `.parameter`, `.tagged`) participate.
fn resolveTypedLiteralSlot(state: *const CompileState, val: Value) ?TypedLiteralSlot {
    if (!state.aot_mode) return null;
    if (!state.aot_emit_slot_table_literals) return null;
    const maps = state.aot_slot_maps orelse return null;
    return switch (val) {
        .type_val => |tv| if (maps.typevalue_slot_index.get(tv)) |slot|
            .{ .slot = slot, .helper_name = "onez_push_typevalue_slot" }
        else
            null,
        .struct_type => |st| if (maps.struct_type_slot_index.get(st)) |slot|
            .{ .slot = slot, .helper_name = "onez_push_struct_type_slot" }
        else
            null,
        .marker => |mk| if (maps.marker_slot_index.get(mk)) |slot|
            .{ .slot = slot, .helper_name = "onez_push_marker_slot" }
        else
            null,
        .parameter => |p| if (maps.parameter_slot_index.get(p)) |slot|
            .{ .slot = slot, .helper_name = "onez_push_parameter_slot" }
        else
            null,
        .tagged => |t| if (maps.tagged_slot_index.get(.{ .tag = t.tag, .inner_ptr = t.inner })) |slot|
            .{ .slot = slot, .helper_name = "onez_push_tagged_slot" }
        else
            null,
        .mutable_map => |m| if (maps.mutable_map_slot_index.get(m)) |slot|
            .{ .slot = slot, .helper_name = "onez_push_mutable_map_slot" }
        else
            null,
        .struct_instance => |si| if (maps.struct_instance_slot_index.get(si)) |slot|
            .{ .slot = slot, .helper_name = "onez_push_struct_instance_slot" }
        else
            null,
        .vector => |v| if (maps.vector_slot_index.get(v)) |slot|
            .{ .slot = slot, .helper_name = "onez_push_vector_slot" }
        else
            null,
        else => null,
    };
}

/// Shared compilation state threaded through instruction compilation.
const CompileState = struct {
    /// Allocator for temporary heap allocations during compilation (branch
    /// stack copies, etc.). The JIT path uses page_allocator; the AOT path
    /// uses the caller-provided allocator.
    allocator: Allocator = std.heap.page_allocator,
    ctx: *c.ir_ctx,
    base_addr: c.ir_ref,
    tag_offset_const: c.ir_ref,
    payload_offset_const: c.ir_ref,
    fixnum_tag_const: c.ir_ref,
    float_tag_const: c.ir_ref,
    boolean_tag_const: c.ir_ref,
    tagged_tag_const: c.ir_ref,
    struct_instance_tag_const: c.ir_ref,
    bail_status: c.ir_ref,
    ok_status: c.ir_ref,
    items_ptr: c.ir_ref,
    sp_ptr: c.ir_ref,
    capacity_param: c.ir_ref,
    sp_val: c.ir_ref,
    base_idx: c.ir_ref,
    value_size_const: c.ir_ref,
    dynamic_call_emitted: bool = false,
    /// Set when this word's compiled body produces a runtime output depth that
    /// genuinely varies, so the declared output count does not faithfully model
    /// a call result. The trigger is an `if` over a row whose two fall-through
    /// branches leave different stack depths (e.g. `(try-rules)`, where one arm
    /// returns `new-scanner token` and another returns `t`). A caller of such a
    /// word must collapse its abstract stack to a row rather than apply the
    /// declared concrete effect, which would diverge from the runtime depth at a
    /// later branch merge. A row that arises from a deterministic mechanism
    /// (reach-below shuffles, indexed-row ops) leaves the declared count intact
    /// and does not set this.
    variable_arity: bool = false,
    /// Count of same-type `if` merges lowered to a branchless `IR_COND` select.
    /// Surfaced on the compiled result so tests can confirm the fast path fired.
    cond_select_count: u32 = 0,
    error_handler_terminal: bool = false,
    not_compilable_reason: ?NotCompilableReason = null,
    dispatch_ptr: c.ir_ref = c.IR_UNUSED,
    resolver: ?WordResolver = null,
    jit_ctx_ptr: c.ir_ref = c.IR_UNUSED,
    safepoint_fn: c.ir_ref = c.IR_UNUSED,
    recover_fn: c.ir_ref = c.IR_UNUSED,
    cleanup_fn: c.ir_ref = c.IR_UNUSED,
    get_fn: c.ir_ref = c.IR_UNUSED,
    with_parameter_fn: c.ir_ref = c.IR_UNUSED,
    iterator_fn: c.ir_ref = c.IR_UNUSED,
    native_call_fn: c.ir_ref = c.IR_UNUSED,
    interpreted_call_fn: c.ir_ref = c.IR_UNUSED,
    /// Callback ref for `jitNativeWordCall`: dispatches a native word by
    /// `word_id` using the cached `native_fn_ptr` on the JIT dispatch
    /// entry. AOT-mode replaces `interpreted_call_fn` for native targets.
    native_word_call_fn: c.ir_ref = c.IR_UNUSED,
    /// Reference to jitRefreshStack: re-LOADs ctx.stack.items.items.ptr and
    /// capacity into the JitContext after a callback may have reallocated
    /// the stack. Emitted from emitCallbackPostCheck on the hot-path continue
    /// branch.
    refresh_stack_fn: c.ir_ref = c.IR_UNUSED,
    /// References to jitRetainSlot / jitReleaseSlot: read the Value at a
    /// physical stack slot and retain / release its refcounted backing.
    /// Emitted where the codegen logically duplicates a `.raw_at_slot`
    /// entry (retain) or discards one without a native consuming it
    /// (release), so the "stack slot is an owning reference" invariant
    /// holds across the generated-code boundary.
    retain_slot_fn: c.ir_ref = c.IR_UNUSED,
    release_slot_fn: c.ir_ref = c.IR_UNUSED,
    validate_params_fn: c.ir_ref = c.IR_UNUSED,
    /// Function ref for `jitSatisfiesAndDispatch`, emitted at protocol-bounded
    /// generic dispatch sites. JIT-only; left unused in AOT mode.
    satisfies_dispatch_fn: c.ir_ref = c.IR_UNUSED,
    /// Function ref for `aotSatisfiesAndDispatch`, emitted at protocol-bounded
    /// generic dispatch sites in AOT mode. JIT mode uses satisfies_dispatch_fn.
    aot_satisfies_dispatch_fn: c.ir_ref = c.IR_UNUSED,
    /// Companions of the above for combinator-bounded dispatch sites, calling
    /// the `*SatisfiesAndDispatchCombinator` exports.
    satisfies_dispatch_combinator_fn: c.ir_ref = c.IR_UNUSED,
    aot_satisfies_dispatch_combinator_fn: c.ir_ref = c.IR_UNUSED,
    /// Function ref for `aotTryDispatchGenericOrCall`, emitted at plain
    /// (non-bounded) generic call sites in AOT mode so a user generic
    /// dispatches by operand type, falling to its default body on a miss.
    aot_generic_dispatch_fn: c.ir_ref = c.IR_UNUSED,
    interp_ctx: ?*const Context = null,
    /// Interpreter PIC table for the word being compiled. Each instruction
    /// index maps to a PolymorphicCache recording observed type pairs.
    /// Read at compile time to emit inline type-check-and-branch IR.
    pic_table: ?*pic_mod.PicTable = null,
    pic_dispatch_fn: c.ir_ref = c.IR_UNUSED,
    pic_native_call_fn: c.ir_ref = c.IR_UNUSED,
    pic_match_fn: c.ir_ref = c.IR_UNUSED,
    pic_dispatch_unary_fn: c.ir_ref = c.IR_UNUSED,
    pic_match_unary_fn: c.ir_ref = c.IR_UNUSED,
    pic_stats: ?*PicStats = null,
    /// Counts AOT-mode emissions of CALLs through interpreted_call_fn or
    /// call_quotation_fn. The substring scan that decides interpreter-free
    /// linking reads this counter instead of grepping the generated C.
    aot_fallback_emit_count: ?*u32 = null,
    /// Optional per-compilation report builder. When set, every AOT-mode
    /// `jitInterpretedCall` emission appends a classified site record so
    /// build-time diagnostics can attribute interpreter calls to the
    /// caller/callee/line that produced them.
    aot_fallback_report: ?*AotFallbackReportBuilder = null,
    /// Caller word name used for fallback report attribution. Always set
    /// for AOT compilations regardless of whether the word has a
    /// self-tail-call (`self_name` is only populated for the tail-call
    /// optimization path).
    caller_name_for_report: ?[]const u8 = null,
    error_propagate_status: c.ir_ref = c.IR_UNUSED,
    self_name: ?[]const u8 = null,
    loop_begin_ref: c.ir_ref = c.IR_UNUSED,
    input_count: u8 = 0,
    exit_kind: ExitKind = .falls_through,
    loop_end_set: bool = false,
    /// When true, this self-tail-call word threads state above a bounded row, so the loop entry is
    /// rebased around a row pinned at abstract slot 0 and the tail call emits a row-aware back-edge
    /// instead of ordinary recursion.
    row_aware_loop: bool = false,
    /// Pass-1 discovery output: set when the self-tail-call is reached in the preserved-`ic` row
    /// shape while `row_aware_loop` is false. The two-pass driver feeds this back as the pass-2
    /// `row_aware_loop` input.
    row_aware_loop_detected: bool = false,
    mutual_group: ?[]const []const u8 = null,
    trampoline_status: c.ir_ref = c.IR_UNUSED,
    /// When true, callback references use named extern symbols (ir_const_func)
    /// instead of baked function pointer addresses (ir_const_addr). This is
    /// required for AOT C emission where addresses are not known at compile time.
    aot_mode: bool = false,
    /// True for interpreter-free (strict) AOT builds
    /// (`--interpreter-fallback=false`), where any construct that would require
    /// interpreter re-entry at runtime must be rejected at build time rather
    /// than compiled to a path that fatals at runtime.
    interpreter_free: bool = false,
    /// True when the build targets a freestanding triple. Native word calls
    /// then route through `jitNativeWordCall` instead of the direct `onez_n_*`
    /// wrapper symbols, which are exported by the hosted runtime only.
    freestanding: bool = false,
    /// Set of compiled word names available in AOT mode. Used to decide whether
    /// a compound word call can be a direct function call or must fall through
    /// to `jitInterpretedCall` (permissive AOT only; strict AOT rejects the
    /// build at any such site).
    aot_compiled_names: ?*const std.StringHashMapUnmanaged(u32) = null,
    /// Prototype ref for 1-arg callbacks in AOT mode: (uintptr_t) -> int32_t.
    aot_proto_1arg: c.ir_ref = c.IR_UNUSED,
    /// Prototype ref for 2-arg callbacks in AOT mode: (uintptr_t, uintptr_t) -> int32_t.
    aot_proto_2arg: c.ir_ref = c.IR_UNUSED,
    /// jitCallQuotation callback ref (used inline, not stored in CompileState for JIT).
    call_quotation_fn: c.ir_ref = c.IR_UNUSED,
    /// jitCallCodePtr callback ref: dispatches a compiled quotation via its
    /// code_ptr in AOT mode. The IR C backend emits loaded addresses as
    /// uintptr_t which cannot be called directly; this callback casts and
    /// dispatches.
    call_code_ptr_fn: c.ir_ref = c.IR_UNUSED,
    /// jitCallValue callback ref: the unified interpreter-free dispatcher for a
    /// runtime-selected `call`. Given the slot's Value pointer it calls a
    /// quotation's code_ptr (trapping on null) or pushes a closure's captured
    /// prefix and calls each compiled base. Only wired in AOT mode.
    call_value_fn: c.ir_ref = c.IR_UNUSED,
    /// Error-reporting callbacks that set jit_pending_error and return 2.
    /// Used to replace bail_status returns with proper error propagation.
    type_mismatch_error_fn: c.ir_ref = c.IR_UNUSED,
    overflow_error_fn: c.ir_ref = c.IR_UNUSED,
    div_zero_error_fn: c.ir_ref = c.IR_UNUSED,
    underflow_error_fn: c.ir_ref = c.IR_UNUSED,
    /// Defined runtime trap for an interpreter-free dynamic quotation call
    /// reaching a null code_ptr. Replaces the interpreter fallback the strict
    /// path cannot use; only emitted in AOT interpreter-free mode.
    null_code_ptr_error_fn: c.ir_ref = c.IR_UNUSED,
    append_word_trace_frame_fn: c.ir_ref = c.IR_UNUSED,
    append_builtin_trace_frame_fn: c.ir_ref = c.IR_UNUSED,
    /// Pre-loaded interpreter Context pointer from JitContext. In AOT mode,
    /// this is loaded once in the prologue to avoid the ir_emit_c d_0 bug
    /// where unused LOADs get assigned vreg 0 without a declaration.
    preloaded_ctx_val: c.ir_ref = c.IR_UNUSED,
    /// Accumulator for string/symbol literals encountered during AOT compilation.
    /// Each entry gets emitted as a `static const char[]` in the C preamble.
    aot_string_literals: ?*std.ArrayListUnmanaged(AotStringLiteral) = null,
    /// Identity-keyed slot-index maps for the typed-literal pushes
    /// (TypeValue, StructType, Marker, Parameter). Populated by the
    /// runtime-image collection walk before Pass 2 begins. Null when
    /// the build does not emit an image, or when the migration flag
    /// is off; codegen falls back to runtime name lookup in that
    /// case.
    aot_slot_maps: ?*const AotImageSlotMaps = null,
    /// Migration toggle for slot-table-indexed typed literals. When
    /// true and `aot_slot_maps` is non-null, codegen emits
    /// `onez_push_*_slot(ctx, N)` callbacks for typed literals instead
    /// of the runtime name-lookup callbacks. Defaults to false during
    /// the migration so the new path can be enabled incrementally.
    aot_emit_slot_table_literals: bool = false,
    /// Accumulator for quotation literals encountered during AOT compilation.
    /// Each entry gets emitted as a `static const unsigned char[]` in the C preamble.
    aot_quotation_literals: ?*std.ArrayListUnmanaged(AotQuotationLiteral) = null,
    /// Accumulator for array/hash literals encountered during AOT compilation.
    /// Each entry gets emitted as a `static const unsigned char[]` in the C preamble.
    aot_array_literals: ?*std.ArrayListUnmanaged(AotArrayLiteral) = null,
    /// Mapping from quotation instruction body pointers to global quotation IDs.
    /// Used by materializeQuotations to pass the quotation_id to jitPushQuotation
    /// so it can attach compiled code_ptrs.
    aot_quotation_id_map: ?*const std.AutoHashMapUnmanaged(usize, u32) = null,
    /// Peak abstract stack pointer reached during compilation. Used to
    /// ensure the value stack has enough capacity before entering compiled
    /// code.
    peak_sp: u32 = 0,
    /// Stack effect of the word being compiled. Used to resolve quotation
    /// parameter effects through calls.
    stack_effect: ?*const StackEffect = null,
    /// Parameter types the freeze-time call-site inference proved for this body,
    /// positional against its inputs.
    ///
    /// Empty outside AOT: proving a type from call sites needs a closed world, and
    /// only an AOT freeze has one.
    inferred_param_types: []const InferredParamType = &.{},
    /// Mapping from input slot indices to concrete quotation effects.
    /// Populated when stack_effect is available and quotation parameters
    /// have fixed (non-row-variable) arities.
    quotation_slots: QuotationSlotMap = .{},
    inline_trace_frames: [max_inline_trace_frames]InlineTraceFrame = undefined,
    inline_trace_frame_count: usize = 0,
    /// Monotonic counter for allocating unique RowId values.
    next_row_id: RowId = 0,
    /// Source file containing the word or quotation being compiled.
    /// Threaded onto the source-lines side table so the patched
    /// `ir_emit_c.c` knows which file the `#line` directives point
    /// at. Null when unknown; codegen then skips installing the side
    /// table and the patched emitter falls back to its no-source-info
    /// behavior.
    source_file: ?[]const u8 = null,
    /// Accumulator for `(block-start ir_ref, source line)` pairs at
    /// user-visible control-flow boundaries (if/case arms, loop body
    /// entries, post-if merges). Installed via `ctx.data` before
    /// `ir_mod.emitC` so the patched `ir_emit_c.c` emits `#line`
    /// directives between blocks. Populated by `recordBlockStart`;
    /// flushed by `flushPendingLine` at the next instruction.
    source_line_entries: std.ArrayListUnmanaged(LineEntry) = .{},
    /// Most recent block-start ir_ref whose source-line attribution is
    /// still unknown. `flushPendingLine` consumes this on the next
    /// `compileInstructions` iteration with a non-zero `instr.line`,
    /// pairing the ref with the line of the first source instruction
    /// that emits code into the new block. `c.IR_UNUSED` when nothing
    /// is pending.
    pending_line_ref: c.ir_ref = c.IR_UNUSED,

    /// Allocate a fresh RowId, unique within this compilation.
    fn nextRowId(state: *CompileState) RowId {
        const id = state.next_row_id;
        state.next_row_id += 1;
        return id;
    }

    /// Record that the most recently emitted IR instruction starts a
    /// new basic block at a user-visible control-flow boundary. The
    /// source-line attribution for this ref is deferred until the next
    /// `compileInstructions` iteration carrying a non-zero source
    /// line, so the recorded line is the first source line of code
    /// that actually emits into the new block.
    fn recordBlockStart(state: *CompileState, ref: c.ir_ref) void {
        if (ref == c.IR_UNUSED or ref == 0) return;
        state.pending_line_ref = ref;
    }

    /// Pair the pending block-start ref (if any) with `line` and
    /// append to the source-line entry list. Called at the top of
    /// each `compileInstructions` iteration when `instr.line != 0`.
    fn flushPendingLine(state: *CompileState, line: u32) Allocator.Error!void {
        if (state.pending_line_ref == c.IR_UNUSED) return;
        if (line == 0) return;
        try state.source_line_entries.append(state.allocator, .{
            .ref = @intCast(state.pending_line_ref),
            .line = line,
        });
        state.pending_line_ref = c.IR_UNUSED;
    }

    /// Record an AOT-mode CALL through interpreted_call_fn or
    /// call_quotation_fn. Only AOT-mode emissions produce textual
    /// `jitInterpretedCall` / `jitCallQuotation` references in the
    /// generated C; JIT mode bakes addresses instead.
    ///
    /// `category` classifies the emission so build-time diagnostics can
    /// show which kind of fallback the interpreter is being reached for.
    /// The remaining parameters attribute the emission back to the
    /// caller, callee, and source location.
    fn noteAotFallbackEmission(
        state: *CompileState,
        category: AotFallbackCategory,
        callee_word: []const u8,
        callee_word_id: u32,
        line: usize,
    ) void {
        if (!state.aot_mode) return;
        // The counter feeds the "interpreter linked" decision in
        // `emitProgramC`. Native and per-op-native emissions now route
        // through `jitNativeWordCall`, which does not require the
        // interpreter, but they still increment the counter here to
        // preserve the existing linkage behavior.
        if (state.aot_fallback_emit_count) |counter| counter.* += 1;
        if (state.aot_fallback_report) |report| {
            report.record(.{
                .category = category,
                .caller_word = state.caller_name_for_report orelse state.self_name orelse "<unknown>",
                .callee_word = callee_word,
                .callee_word_id = callee_word_id,
                .line = @intCast(line),
            });
        }
    }
};

const BuiltinTraceFrameKind = enum(usize) {
    if_op = 0,
    call = 1,
    recover = 2,
    cleanup = 3,
};

const InlineTraceFrame = struct {
    kind: BuiltinTraceFrameKind,
    line: usize,
};

const max_inline_trace_frames = 8;

fn traceFramesEnabled(state: *const CompileState) bool {
    return state.append_word_trace_frame_fn != c.IR_UNUSED or state.append_builtin_trace_frame_fn != c.IR_UNUSED;
}

/// Concrete quotation effect for an input slot: the fixed number of values
/// consumed and produced by calling the quotation at that slot.
const QuotationSlotInfo = struct {
    slot: usize,
    input_count: u8,
    output_count: u8,
};

/// Maximum number of quotation parameters whose effects can be tracked simultaneously during word compilation.
/// No prelude word has more than three quotation parameters, so sixteen is generous. Overflow produces an
/// explicit NotCompilable error rather than silently truncating.
const max_quotation_slots = 16;

/// Fixed-capacity mapping from input slot indices to concrete quotation effects.
const QuotationSlotMap = struct {
    items: [max_quotation_slots]QuotationSlotInfo = undefined,
    len: usize = 0,

    fn add(self: *QuotationSlotMap, info: QuotationSlotInfo) bool {
        if (self.len >= max_quotation_slots) return false;
        self.items[self.len] = info;
        self.len += 1;
        return true;
    }

    fn findSlot(self: *const QuotationSlotMap, slot: usize) ?QuotationSlotInfo {
        for (self.items[0..self.len]) |item| {
            if (item.slot == slot) return item;
        }
        return null;
    }
};

/// Build quotation slot mapping from a stack effect's input parameters.
/// Records slots whose quotation_effect has concrete (non-row-variable) arities.
fn buildQuotationSlotMap(effect: ?*const StackEffect) ?QuotationSlotMap {
    var map = QuotationSlotMap{};
    const eff = effect orelse return map;
    var concrete_idx: usize = 0;
    for (eff.inputs) |param| {
        if (param.is_row_variable) continue;
        if (param.quotation_effect) |qe| {
            if (!stack_effect_mod.hasAnyRowVariable(qe.*)) {
                if (!map.add(.{
                    .slot = concrete_idx,
                    .input_count = @intCast(qe.concreteInputCount()),
                    .output_count = @intCast(qe.concreteOutputCount()),
                })) return null;
            }
        }
        concrete_idx += 1;
    }
    return map;
}

/// Collect diagnostic warnings for quotation parameters that could not be
/// given concrete effect mappings. Called after buildQuotationSlotMap to
/// identify parameters skipped due to row variables or missing annotations.
fn collectQuotationFallbacks(
    effect: ?*const StackEffect,
    slot_map: *const QuotationSlotMap,
    word_name: []const u8,
    out: *std.ArrayListUnmanaged(QuotationFallbackWarning),
    allocator: Allocator,
) Allocator.Error!void {
    const eff = effect orelse return;
    var concrete_idx: usize = 0;
    for (eff.inputs) |param| {
        if (param.is_row_variable) continue;
        defer concrete_idx += 1;
        if (param.quotation_effect) |qe| {
            if (slot_map.findSlot(concrete_idx) == null) {
                // Has quotation_effect but was skipped -- must be row variables
                _ = qe;
                try out.append(allocator, .{
                    .word_name = word_name,
                    .param_name = param.name,
                    .reason = .row_variables,
                });
            }
        }
    }
}

/// Result of inferring a quotation body's stack effect by abstract simulation.
pub const InferredEffect = struct {
    input_count: u8,
    output_count: u8,
};

/// Maximum depth of the mini-stack used during quotation effect inference. Quotation bodies are typically short.
const max_mini_stack_depth = 64;

/// Largest input arity the compile-to-discover effect search tries for a composite-nested quotation
/// whose effect `inferQuotationEffect` cannot derive.
///
/// Runtime-dispatched branch quotations take only a handful of inputs. The smallest arity that compiles
/// is taken as the effect.
const max_discovered_quotation_arity = 4;

/// Entry in the lightweight mini-stack used during quotation effect inference.
/// Tracks whether a position holds a known quotation body (for resolving
/// `call` and `if` within the body) or an opaque value.
const MiniStackEntry = union(enum) {
    quotation: []const Instruction,
    other,
};

/// Threaded state bundle passed to a custom intrinsic effect handler, mirroring `EmitCtx` on the codegen side.
/// Effect inference has no state object, so the bundle carries exactly the values the bespoke arms thread.
const EffectCtx = struct {
    mini_stack: *[max_mini_stack_depth]MiniStackEntry,
    sp: *usize,
    delta: *i32,
    min_delta: *i32,
    resolver: ?WordResolver,
};

/// A fixed `(input_count, output_count)` stack effect.
const FixedEffect = struct {
    input_count: u8,
    output_count: u8,
};

/// An intrinsic's effect during quotation effect inference.
///
/// `.none` means the op is not handled inline and falls through to the `WordResolver`.
/// `.fixed` carries a static count pair.
/// `.custom` points at a per-op effect handler for the bespoke mini-stack ops.
const IntrinsicEffect = union(enum) {
    none,
    fixed: FixedEffect,
    custom: *const fn (EffectCtx) error{EffectInferenceOverflow}!bool,
};

/// Infer the concrete stack effect of a quotation body by abstract stack
/// simulation. Returns null if the effect cannot be statically determined
/// (e.g., unresolvable word, dynamic call on unknown quotation).
///
/// Uses a low-water-mark algorithm: `input_count = -min_delta` and
/// `output_count = input_count + final_delta`, where delta tracks the
/// running net stack depth change.
pub fn inferQuotationEffect(
    instructions: []const Instruction,
    resolver: ?WordResolver,
) error{EffectInferenceOverflow}!?InferredEffect {
    var delta: i32 = 0;
    var min_delta: i32 = 0;

    // Mini-stack tracks known quotation bodies above the initial level.
    var mini_stack: [max_mini_stack_depth]MiniStackEntry = undefined;
    var sp: usize = 0;

    for (instructions) |instr| {
        switch (instr.op) {
            .push_literal => |val| {
                if (sp >= max_mini_stack_depth) return error.EffectInferenceOverflow;
                mini_stack[sp] = if (val == .quotation)
                    .{ .quotation = val.quotation.instructions }
                else
                    .other;
                sp += 1;
                delta += 1;
            },
            .call_word, .call_word_direct => blk: {
                const name = instr.op.callTargetName().?;
                if (try inferBuiltinEffect(name, &mini_stack, &sp, &delta, &min_delta, resolver)) |ok| {
                    if (!ok) return null;
                    break :blk;
                }
                // Not a built-in word: resolve via WordResolver.
                const res = resolver orelse return null;
                const resolved = res.resolve(name, res.user_data) orelse return null;

                // Row-variable callees have input_count/output_count
                // that include row variable params. Without knowing their
                // quotation arguments, the counts are unusable here.
                if (resolved.callee_effect != null) return null;

                // Consume inputs.
                const in: i32 = @intCast(resolved.input_count);
                const out: i32 = @intCast(resolved.output_count);
                delta -= in;
                min_delta = @min(min_delta, delta);
                delta += out;

                // Update mini-stack: pop consumed entries, push opaque outputs.
                var pops: usize = resolved.input_count;
                while (pops > 0 and sp > 0) {
                    sp -= 1;
                    pops -= 1;
                }
                var pushes: usize = resolved.output_count;
                while (pushes > 0) {
                    if (sp >= max_mini_stack_depth) return error.EffectInferenceOverflow;
                    mini_stack[sp] = .other;
                    sp += 1;
                    pushes -= 1;
                }
            },
        }
    }

    const input_count: i32 = if (min_delta < 0) -min_delta else 0;
    const output_count: i32 = input_count + delta;
    if (output_count < 0) return null;
    return .{
        .input_count = @intCast(input_count),
        .output_count = @intCast(output_count),
    };
}

/// Handle built-in words during quotation effect inference.
///
/// Returns `true` if the word was handled successfully, `false` if inference
/// should abort (bail), or `null` if the word is not a built-in (caller should
/// try the WordResolver).
///
/// The intrinsic effect surface is defined entirely by the table entry's `effect` field:
///
/// - `.fixed` carries a static count pair.
/// - `.custom` points at a per-op handler for the bespoke mini-stack ops (`dup`, `swap`, `over`,
///   `call`, `if`).
/// - `.none` is the deliberate, parity-preserving effect for resolver-dispatched ops
///   (indexed-stack, iterator, dynamic-var, struct-native, loop, error-handling) whose effect is
///   not statically inferable here, so they fall through to the `WordResolver`.
fn inferBuiltinEffect(
    name: []const u8,
    mini_stack: *[max_mini_stack_depth]MiniStackEntry,
    sp: *usize,
    delta: *i32,
    min_delta: *i32,
    resolver: ?WordResolver,
) error{EffectInferenceOverflow}!?bool {
    if (intrinsic_table.get(name)) |entry| switch (entry.effect) {
        .fixed => |fx| {
            try applyFixedEffect(mini_stack, sp, delta, min_delta, fx.input_count, fx.output_count);
            return true;
        },
        .custom => |handler| return try handler(.{
            .mini_stack = mini_stack,
            .sp = sp,
            .delta = delta,
            .min_delta = min_delta,
            .resolver = resolver,
        }),
        .none => {},
    };

    // Not a recognized built-in.
    return null;
}

/// `dup` effect: ( a -- a a ), net +1, needs 1 input. Duplicates the top
/// mini-stack entry so quotation-body knowledge propagates through the copy.
fn inferEffectDup(ec: EffectCtx) error{EffectInferenceOverflow}!bool {
    const mini_stack = ec.mini_stack;
    const sp = ec.sp;
    const delta = ec.delta;
    const min_delta = ec.min_delta;
    delta.* -= 1;
    min_delta.* = @min(min_delta.*, delta.*);
    delta.* += 2;
    if (sp.* >= 1) {
        // Duplicate top entry (preserving quotation body if present).
        const top = mini_stack[sp.* - 1];
        if (sp.* >= max_mini_stack_depth) return error.EffectInferenceOverflow;
        mini_stack[sp.*] = top;
        sp.* += 1;
    } else {
        // Duping from below initial level: push two unknowns.
        if (sp.* >= max_mini_stack_depth) return error.EffectInferenceOverflow;
        mini_stack[sp.*] = .other;
        sp.* += 1;
        if (sp.* >= max_mini_stack_depth) return error.EffectInferenceOverflow;
        mini_stack[sp.*] = .other;
        sp.* += 1;
    }
    return true;
}

/// `swap` effect: ( a b -- b a ), net 0, needs 2 inputs. Swaps the top two
/// mini-stack entries so quotation-body knowledge follows the shuffle.
fn inferEffectSwap(ec: EffectCtx) error{EffectInferenceOverflow}!bool {
    const mini_stack = ec.mini_stack;
    const sp = ec.sp;
    const delta = ec.delta;
    const min_delta = ec.min_delta;
    delta.* -= 2;
    min_delta.* = @min(min_delta.*, delta.*);
    delta.* += 2;
    if (sp.* >= 2) {
        const tmp = mini_stack[sp.* - 1];
        mini_stack[sp.* - 1] = mini_stack[sp.* - 2];
        mini_stack[sp.* - 2] = tmp;
    }
    // If sp < 2, entries are below initial level; no mini-stack change needed.
    return true;
}

/// `over` effect: ( a b -- a b a ), net +1, needs 2 inputs. Copies the second
/// mini-stack entry to the top so quotation-body knowledge propagates.
fn inferEffectOver(ec: EffectCtx) error{EffectInferenceOverflow}!bool {
    const mini_stack = ec.mini_stack;
    const sp = ec.sp;
    const delta = ec.delta;
    const min_delta = ec.min_delta;
    delta.* -= 2;
    min_delta.* = @min(min_delta.*, delta.*);
    delta.* += 3;
    if (sp.* >= max_mini_stack_depth) return error.EffectInferenceOverflow;
    if (sp.* >= 2) {
        // Copy second element to top.
        mini_stack[sp.*] = mini_stack[sp.* - 2];
    } else {
        // Some entries below initial level; push unknown.
        mini_stack[sp.*] = .other;
    }
    sp.* += 1;
    return true;
}

/// `call` effect: pop a quotation and apply its effect. Recurses into the
/// quotation's body when it is a known literal; bails (`false`) when the
/// callee is opaque or below the initial level.
fn inferEffectCall(ec: EffectCtx) error{EffectInferenceOverflow}!bool {
    const mini_stack = ec.mini_stack;
    const sp = ec.sp;
    const delta = ec.delta;
    const min_delta = ec.min_delta;
    const resolver = ec.resolver;

    // Consume the quotation from the stack.
    delta.* -= 1;
    min_delta.* = @min(min_delta.*, delta.*);

    // Check if top of mini-stack is a known quotation body.
    if (sp.* > 0) {
        sp.* -= 1;
        switch (mini_stack[sp.*]) {
            .quotation => |body| {
                // Recursively infer the quotation's effect.
                const effect = try inferQuotationEffect(body, resolver) orelse return false;
                const in: i32 = @intCast(effect.input_count);
                const out: i32 = @intCast(effect.output_count);
                delta.* -= in;
                min_delta.* = @min(min_delta.*, delta.*);
                delta.* += out;

                // Push opaque outputs onto mini-stack.
                var pushes: usize = effect.output_count;
                while (pushes > 0) {
                    if (sp.* >= max_mini_stack_depth) return error.EffectInferenceOverflow;
                    mini_stack[sp.*] = .other;
                    sp.* += 1;
                    pushes -= 1;
                }
                return true;
            },
            .other => return false, // Unknown quotation, bail.
        }
    } else {
        // Popping from below initial level: unknown value, bail.
        return false;
    }
}

/// `if` effect: ( cond true-quot false-quot -- results... ). Both branch
/// bodies must be known literals with matching input counts and net deltas;
/// bails (`false`) otherwise.
fn inferEffectIf(ec: EffectCtx) error{EffectInferenceOverflow}!bool {
    const mini_stack = ec.mini_stack;
    const sp = ec.sp;
    const delta = ec.delta;
    const min_delta = ec.min_delta;
    const resolver = ec.resolver;

    // Consume condition + two quotations.
    delta.* -= 3;
    min_delta.* = @min(min_delta.*, delta.*);

    // Need both quotation bodies visible on mini-stack.
    if (sp.* >= 3) {
        const false_entry = mini_stack[sp.* - 1];
        const true_entry = mini_stack[sp.* - 2];
        sp.* -= 3; // pop condition + both quotations

        const true_body = switch (true_entry) {
            .quotation => |body| body,
            .other => return false,
        };
        const false_body = switch (false_entry) {
            .quotation => |body| body,
            .other => return false,
        };

        const true_eff = try inferQuotationEffect(true_body, resolver) orelse return false;
        const false_eff = try inferQuotationEffect(false_body, resolver) orelse return false;

        // Both branches must have the same net delta.
        const true_delta = @as(i32, @intCast(true_eff.output_count)) - @as(i32, @intCast(true_eff.input_count));
        const false_delta = @as(i32, @intCast(false_eff.output_count)) - @as(i32, @intCast(false_eff.input_count));
        if (true_delta != false_delta) return false;

        // Both branches must consume the same number of inputs.
        if (true_eff.input_count != false_eff.input_count) return false;

        // Apply branch effect.
        const in: i32 = @intCast(true_eff.input_count);
        const out: i32 = @intCast(true_eff.output_count);
        delta.* -= in;
        min_delta.* = @min(min_delta.*, delta.*);
        delta.* += out;

        // Push opaque outputs.
        var pushes: usize = true_eff.output_count;
        while (pushes > 0) {
            if (sp.* >= max_mini_stack_depth) return error.EffectInferenceOverflow;
            mini_stack[sp.*] = .other;
            sp.* += 1;
            pushes -= 1;
        }
        return true;
    }
    return false;
}

/// Apply a fixed (input_count, output_count) effect to delta, min_delta,
/// and the mini-stack.
fn applyFixedEffect(
    mini_stack: *[max_mini_stack_depth]MiniStackEntry,
    sp: *usize,
    delta: *i32,
    min_delta: *i32,
    input_count: u8,
    output_count: u8,
) error{EffectInferenceOverflow}!void {
    const in: i32 = @intCast(input_count);
    const out: i32 = @intCast(output_count);
    delta.* -= in;
    min_delta.* = @min(min_delta.*, delta.*);
    delta.* += out;

    // Update mini-stack.
    var pops: usize = input_count;
    while (pops > 0 and sp.* > 0) {
        sp.* -= 1;
        pops -= 1;
    }
    var pushes: usize = output_count;
    while (pushes > 0) {
        if (sp.* >= max_mini_stack_depth) return error.EffectInferenceOverflow;
        mini_stack[sp.*] = .other;
        sp.* += 1;
        pushes -= 1;
    }
}

/// Maximum number of distinct row variable bindings that can be resolved during a single callsite specialization.
/// Row variable effects typically bind 1-2 variables per quotation parameter.
const max_row_var_bindings = 16;

/// Row variable binding: maps a row variable name to its resolved size.
const RowVarBinding = struct {
    name: []const u8,
    size: u8,
};

/// Resolve row-variable quotation effects at a call site. Given the callee's
/// full stack effect and the caller's abstract stack, infer concrete effects
/// for quotation arguments and bind row variables to compute specialized
/// input/output counts.
///
/// Returns null if specialization is not possible (quotation not visible as
/// a literal body, inference fails, or row variable bindings conflict).
fn resolveRowVariableEffect(
    effect: *const StackEffect,
    stack: []const StackEntry,
    sp: usize,
    resolver: ?WordResolver,
) error{ RowBindingOverflow, EffectInferenceOverflow }!?InferredEffect {
    const concrete_in = effect.concreteInputCount();

    // Map each concrete input parameter to its stack position.
    // Row variable params don't occupy stack slots.
    // Stack layout: [... | param_0 | param_1 | ... | param_(N-1) ]
    //                      ^-- sp - concrete_in

    if (sp < concrete_in) return null;
    const base_pos = sp - concrete_in;

    // Collect row variable bindings from quotation parameters.
    var bindings: [max_row_var_bindings]RowVarBinding = undefined;
    var num_bindings: usize = 0;

    var concrete_idx: usize = 0;
    for (effect.inputs) |param| {
        if (param.is_row_variable) continue;
        defer concrete_idx += 1;

        const qe_ptr = param.quotation_effect orelse continue;
        const qe = qe_ptr.*;
        if (!stack_effect_mod.hasAnyRowVariable(qe)) continue;

        // This quotation parameter has row-variable effects.
        // Check if the corresponding stack entry is a visible quotation body.
        const stack_pos = base_pos + concrete_idx;
        const body = switch (stack[stack_pos]) {
            .quotation_body => |b| b,
            else => return null,
        };

        // Infer the concrete effect of the quotation body.
        const inferred = try inferQuotationEffect(body, resolver) orelse return null;

        // Compute row variable sizes from the difference between
        // inferred concrete counts and the quotation's declared
        // concrete (non-row-variable) counts.
        const declared_concrete_in = qe.concreteInputCount();
        const declared_concrete_out = qe.concreteOutputCount();

        if (inferred.input_count < declared_concrete_in) return null;
        if (inferred.output_count < declared_concrete_out) return null;

        const row_in_size: u8 = inferred.input_count - @as(u8, @intCast(declared_concrete_in));
        const row_out_size: u8 = inferred.output_count - @as(u8, @intCast(declared_concrete_out));

        // Bind row variables from the quotation's input side.
        var input_has_row_var = false;
        for (qe.inputs) |qp| {
            if (!qp.is_row_variable) continue;
            input_has_row_var = true;
            if (!(try addOrCheckBinding(&bindings, &num_bindings, qp.name, row_in_size))) return null;
        }

        // Bind row variables from the quotation's output side.
        var output_has_row_var = false;
        for (qe.outputs) |qp| {
            if (!qp.is_row_variable) continue;
            output_has_row_var = true;
            if (!(try addOrCheckBinding(&bindings, &num_bindings, qp.name, row_out_size))) return null;
        }

        // A side that inferred more entries than it declares concretely, but carries no row
        // variable to absorb the surplus, is not soundly modeled. The extra entries would be
        // silently dropped.
        //
        // Bail so the call falls back to the interpreter rather than miscompiling. This is the
        // concrete-output + row-input shape, e.g., `try` with a multi-value quotation. The
        // `keep` / `dip` family always carries a row variable on both sides and never trips it.
        if (row_in_size > 0 and !input_has_row_var) return null;
        if (row_out_size > 0 and !output_has_row_var) return null;
    }

    // Compute specialized outer effect using row variable bindings.
    var specialized_in: u8 = @intCast(concrete_in);
    for (effect.inputs) |param| {
        if (!param.is_row_variable) continue;
        const size = lookupBinding(bindings[0..num_bindings], param.name) orelse return null;
        specialized_in = std.math.add(u8, specialized_in, size) catch return null;
    }

    var specialized_out: u8 = @intCast(effect.concreteOutputCount());
    for (effect.outputs) |param| {
        if (!param.is_row_variable) continue;
        const size = lookupBinding(bindings[0..num_bindings], param.name) orelse return null;
        specialized_out = std.math.add(u8, specialized_out, size) catch return null;
    }

    return .{
        .input_count = specialized_in,
        .output_count = specialized_out,
    };
}

/// Add a row variable binding or verify consistency with an existing one.
/// Returns false if the binding conflicts with a previously recorded size.
fn addOrCheckBinding(
    bindings: *[max_row_var_bindings]RowVarBinding,
    num_bindings: *usize,
    name: []const u8,
    size: u8,
) error{RowBindingOverflow}!bool {
    for (bindings[0..num_bindings.*]) |b| {
        if (std.mem.eql(u8, b.name, name)) {
            return b.size == size;
        }
    }
    if (num_bindings.* >= max_row_var_bindings) return error.RowBindingOverflow;
    bindings[num_bindings.*] = .{ .name = name, .size = size };
    num_bindings.* += 1;
    return true;
}

/// Look up a row variable's bound size.
fn lookupBinding(bindings: []const RowVarBinding, name: []const u8) ?u8 {
    for (bindings) |b| {
        if (std.mem.eql(u8, b.name, name)) return b.size;
    }
    return null;
}

const AotStringLiteral = struct {
    data: []const u8,
    is_symbol: bool,
};

/// Extract or emit an i64 IR ref from a stack entry. For raw_at_slot entries,
/// emits a fixnum tag check and unboxes the payload; bails if the tag doesn't match.
fn requireI64(entry: StackEntry, state: *CompileState) IrCodegenError!c.ir_ref {
    return switch (entry) {
        .i64_ref => |ref| ref,
        .raw_at_slot => |s| {
            const ctx = state.ctx;
            const elem_addr = liveSlotAddr(state, s);
            emitTagCheck(ctx, elem_addr, state.fixnum_tag_const, state.tag_offset_const, state.bail_status);
            return emitUnboxI64(ctx, elem_addr, state.payload_offset_const);
        },
        else => {
            state.not_compilable_reason = .non_numeric_operand;
            return IrCodegenError.NotCompilable;
        },
    };
}

/// Extract or emit an f64 IR ref from a stack entry. For raw_at_slot entries,
/// emits a float tag check and unboxes the payload; bails if the tag doesn't match.
fn requireF64(entry: StackEntry, state: *CompileState) IrCodegenError!c.ir_ref {
    return switch (entry) {
        .f64_ref => |ref| ref,
        .raw_at_slot => |s| {
            const ctx = state.ctx;
            const elem_addr = liveSlotAddr(state, s);
            emitTagCheck(ctx, elem_addr, state.float_tag_const, state.tag_offset_const, state.bail_status);
            return emitUnboxF64(ctx, elem_addr, state.payload_offset_const);
        },
        else => {
            state.not_compilable_reason = .non_numeric_operand;
            return IrCodegenError.NotCompilable;
        },
    };
}

const NarrowNumeric = enum { fixnum, float };

/// Classify a parameter's type annotation as a builtin scalar that narrows to
/// an unboxed IR value.
///
/// Only the builtin `fixnum` and `float` types qualify. They are recognized by
/// interned pointer identity through the interpreter context, so a user type
/// that merely shares the name is not mistaken for the builtin.
///
/// Returns null when there is no interpreter context, which leaves the
/// parameter opaque. The real compile paths always supply one; a null context
/// reaches here only from the test-only `emitWordC` entry point.
fn narrowableAnnotation(state: *CompileState, ann: stack_effect_mod.TypeAnnotation) ?NarrowNumeric {
    const tv = switch (ann) {
        .type => |t| t,
        .protocol, .combination => return null,
    };
    const ictx = state.interp_ctx orelse return null;
    if (ictx.lookupBuiltinTypeValue("fixnum")) |fx| {
        if (@intFromPtr(tv) == @intFromPtr(fx)) return .fixnum;
    }
    if (ictx.lookupBuiltinTypeValue("float")) |fl| {
        if (@intFromPtr(tv) == @intFromPtr(fl)) return .float;
    }
    return null;
}

/// True when the `type-check` pragma relaxes annotation checking to `off` or
/// `warning`. In either mode the interpreter lets a mistyped argument through,
/// so the declared type is not guaranteed at runtime and narrowing (which
/// trusts it) would be unsound. Mirrors the pragma read in
/// `Context.validateTypeAnnotationsScoped`.
fn typeCheckRelaxed(ctx: *const Context) bool {
    const pv = ctx.getPragma("type-check") orelse return false;
    if (pv != .string) return false;
    return std.mem.eql(u8, pv.string, "off") or std.mem.eql(u8, pv.string, "warning");
}

/// Seed narrowed `.i64_ref`/`.f64_ref` entries for every parameter whose type is known at
/// compile time, replacing the opaque `.raw_at_slot` entries the prologue installed.
///
/// Callers invoke this after the LOOP_BEGIN / row-loop setup, so for a self-tail-call word the
/// checks and unbox LOADs land inside the loop region and re-run each iteration as the back-edge
/// rewrites the parameter slots.
///
/// This is the only entry point to either seeder; both trust the guard below.
fn seedNarrowedParams(state: *CompileState, stack: []StackEntry, input_count: usize) void {
    // Row-aware self-loops rebase the abstract stack around a pinned row, so
    // parameters no longer sit at slots `0..input_count`. Leave them opaque.
    if (state.row_aware_loop) return;

    seedAnnotatedParams(state, stack, input_count);
    seedInferredParams(state, stack, input_count);
}

/// Seed narrowed entries for parameters that declare a builtin `fixnum`/`float`
/// type annotation.
///
/// A narrowed operand is consumed with no tag check, so the parameter's type
/// must be guaranteed. That guarantee comes from a tag-check-or-error at entry
/// in AOT mode and in any self-tail-call loop, and from the interpreter's or
/// JIT dispatch's own entry-time validation otherwise (see `enforce` below).
fn seedAnnotatedParams(state: *CompileState, stack: []StackEntry, input_count: usize) void {
    const effect = state.stack_effect orelse return;
    const ictx = state.interp_ctx orelse return;

    if (typeCheckRelaxed(ictx)) return;

    // AOT calls a compiled body directly with no annotation check in front of
    // it, so an AOT body enforces its own declared types. A self-tail-call loop
    // needs the same enforcement in every mode: the interpreter re-validates on
    // each recursive call, but the compiled back-edge rewrites the parameter
    // slots and jumps to the loop header, so nothing re-checks iterations past
    // the first. A non-looping word is validated once at entry by interpreter
    // and JIT dispatch, and its parameters are not rewritten, so its compiled
    // body relies on that and skips the redundant check.
    const enforce = state.aot_mode or state.loop_begin_ref != c.IR_UNUSED;

    // The enforcement path needs the hard-error callback to reject a mistyped
    // argument; without it, narrowing would be unsound, so leave params opaque.
    if (enforce and state.type_mismatch_error_fn == c.IR_UNUSED) return;

    // A row variable among the inputs makes the input-index -> slot mapping
    // ambiguous (the row stands for a variable slot count), so narrow nothing.
    for (effect.inputs) |param| {
        if (param.is_row_variable) return;
    }

    for (effect.inputs, 0..) |param, i| {
        if (i >= input_count) break;
        if (stack[i] != .raw_at_slot or stack[i].raw_at_slot != i) continue;

        const ann = param.type_annotation orelse continue;
        const kind = narrowableAnnotation(state, ann) orelse continue;

        const slot_addr = liveSlotAddr(state, i);
        switch (kind) {
            .fixnum => {
                if (enforce) emitTagCheckOrError(state, slot_addr, state.fixnum_tag_const, state.type_mismatch_error_fn);
                stack[i] = .{ .i64_ref = emitUnboxI64(state.ctx, slot_addr, state.payload_offset_const) };
            },
            .float => {
                if (enforce) emitTagCheckOrError(state, slot_addr, state.float_tag_const, state.type_mismatch_error_fn);
                stack[i] = .{ .f64_ref = emitUnboxF64(state.ctx, slot_addr, state.payload_offset_const) };
            },
        }
    }
}

/// Seed narrowed entries for parameters the freeze-time call-site inference proved.
///
/// No tag check guards these. A concrete table entry asserts that every call site in
/// the program passes that type, which is a stronger guarantee than a declaration: an
/// annotation states an intent the AOT direct-call path never verifies, while the proof
/// is over the call sites themselves.
///
/// For the same reason the `type-check` pragma does not apply here. It governs whether a
/// declared annotation can be trusted at runtime, and this path reads no declaration.
///
/// This is the only narrowing a quotation body gets: a quotation is compiled with no
/// `StackEffect`, so it has no annotations to read.
fn seedInferredParams(state: *CompileState, stack: []StackEntry, input_count: usize) void {
    if (state.inferred_param_types.len == 0) return;

    // All or nothing. Narrowing only some inputs leaves an operand pair with one narrowed and
    // one opaque side, which skips the polymorphic path and takes the concrete one, whose tag
    // check on the opaque side bails when the tag disagrees. An AOT bail aborts rather than
    // resuming interpreted, so `add2: ( a b -- r ) [ + ] ;` fed `1 2` and `1 2.5` would die on
    // the second call. That abort is a standing AOT gap, reachable today through a literal
    // operand and through a declared annotation; this keeps inference from widening it.
    for (state.inferred_param_types) |kind| {
        if (kind == .unknown) return;
    }

    // A row variable among the inputs makes the input-index -> slot mapping ambiguous.
    //
    // The inference pass already declines to prove anything for such a word, so this is codegen
    // refusing to depend on that rather than a live case.
    if (state.stack_effect) |effect| {
        for (effect.inputs) |param| {
            if (param.is_row_variable) return;
        }
    }

    for (state.inferred_param_types, 0..) |kind, i| {
        if (i >= input_count) break;
        if (stack[i] != .raw_at_slot or stack[i].raw_at_slot != i) continue;

        // A declaration takes precedence over a proof, narrowable or not:
        // `seedAnnotatedParams` owns every parameter that carries one.
        if (state.stack_effect) |effect| {
            if (i < effect.inputs.len and effect.inputs[i].type_annotation != null) continue;
        }

        switch (kind) {
            .unknown => {},
            .fixnum => {
                const slot_addr = liveSlotAddr(state, i);
                stack[i] = .{ .i64_ref = emitUnboxI64(state.ctx, slot_addr, state.payload_offset_const) };
            },
            .float => {
                const slot_addr = liveSlotAddr(state, i);
                stack[i] = .{ .f64_ref = emitUnboxF64(state.ctx, slot_addr, state.payload_offset_const) };
            },
        }
    }
}

const ResolvedPair = union(enum) {
    i64_pair: struct { a: c.ir_ref, b: c.ir_ref },
    f64_pair: struct { a: c.ir_ref, b: c.ir_ref },
};

/// Resolve a pair of stack entries to a common numeric type for binary ops.
/// If either operand is f64_ref, both resolve as f64. If either is i64_ref
/// (and neither is f64_ref), both resolve as i64. Two raw_at_slot entries
/// default to i64 (the common case; runtime tag check bails on mismatch).
fn resolveOperandPair(entry_a: StackEntry, entry_b: StackEntry, state: *CompileState) IrCodegenError!ResolvedPair {
    // f64 takes priority: if either operand is a known float, resolve both as f64.
    if (entry_a == .f64_ref or entry_b == .f64_ref) {
        return .{ .f64_pair = .{
            .a = try requireF64(entry_a, state),
            .b = try requireF64(entry_b, state),
        } };
    }
    // Otherwise resolve as i64 (covers i64_ref, raw_at_slot, and mixed).
    if (entry_a == .i64_ref or entry_b == .i64_ref or
        (entry_a == .raw_at_slot and entry_b == .raw_at_slot))
    {
        return .{ .i64_pair = .{
            .a = try requireI64(entry_a, state),
            .b = try requireI64(entry_b, state),
        } };
    }
    state.not_compilable_reason = .unresolvable_operands;
    return IrCodegenError.NotCompilable;
}

const AotQuotationLiteral = struct {
    data: []const u8,
    /// Global quotation_id when this literal reifies a quotation that *escapes* a
    /// word body as an output (word-output, branch-merge, loop-carry), else
    /// maxInt(u32). `materializeQuotations` records it only for escape positions so
    /// the AOT manifest pass can apply the reification policy (Option C) to an
    /// escaping body whose own body did not compile, without disturbing consumed
    /// (callback) reifications, which keep their existing handling.
    escape_q_id: u32 = std.math.maxInt(u32),
};

const AotArrayLiteral = struct {
    data: []const u8,
};

/// Bytecode encoder/decoder for `Instruction` slices lives in
/// `instruction_bytecode.zig`. The aliases below keep the call sites in
/// this file readable while the implementation stays in one place. The
/// wire format is documented at the top of that module.
const serializeQuotationInstructions = ibc.serializeQuotationInstructions;
const serializeValueInto = ibc.serializeValueInto;
const deserializeQuotationInstructions = ibc.deserializeQuotationInstructions;
const deserializeValueAt = ibc.deserializeValueAt;

/// Materialize any quotation_body entries as raw Values on the physical stack.
/// flushToPhysicalStack skips quotation_body since it's normally consumed by
/// `if`/`call`, but callback-based ops need them as proper Values for the
/// interpreter to pop.
///
/// In AOT mode, quotation bodies are serialized to byte arrays and pushed
/// via the jitPushQuotation callback, avoiding dangling instruction pointers.
fn materializeQuotations(state: *CompileState, stack: []StackEntry, sp: usize, escape: bool) IrCodegenError!void {
    const ctx = state.ctx;
    const base_addr = state.base_addr;
    for (0..sp) |qi| {
        switch (stack[qi]) {
            .quotation_body => |body| {
                if (state.aot_mode) {
                    // Serialize the instruction body and record it for C emission.
                    const serialized = serializeQuotationInstructions(body, std.heap.page_allocator, null) catch {
                        state.not_compilable_reason = .non_serializable_literal;
                        return IrCodegenError.NotCompilable;
                    };

                    const lit_id = if (state.aot_quotation_literals) |lits| lits.items.len else 0;

                    // Look up the global quotation_id for this body. Recorded on the
                    // literal so the manifest pass knows this quotation is reified.
                    const q_id: usize = if (state.aot_quotation_id_map) |m|
                        m.get(@intFromPtr(body.ptr)) orelse std.math.maxInt(u32)
                    else
                        std.math.maxInt(u32);

                    if (state.aot_quotation_literals) |lits| {
                        const escape_id: u32 = if (escape) @intCast(q_id) else std.math.maxInt(u32);
                        lits.append(std.heap.page_allocator, .{ .data = serialized, .escape_q_id = escape_id }) catch {
                            state.not_compilable_reason = .non_serializable_literal;
                            return IrCodegenError.NotCompilable;
                        };
                    }

                    // Emit callback: jitPushQuotation(ctx, data_ptr, data_len, dest_addr, quotation_id)
                    //
                    // Writes the quotation Value directly to the slot address rather than pushing to
                    // the stack top. The quotation_id allows jitPushQuotation to attach the compiled code_ptr.
                    const proto_5arg = c.ir_proto_5(ctx, 0, c.IR_I32, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR);
                    const push_fn = c.ir_const_func(ctx, c.ir_str(ctx, "onez_push_quotation"), proto_5arg);

                    const ctx_val = if (state.preloaded_ctx_val != c.IR_UNUSED)
                        state.preloaded_ctx_val
                    else blk: {
                        JitContextLayout.ensureInit();
                        const ctx_off = c.ir_const_addr(ctx, JitContextLayout.ctx_offset);
                        const ctx_addr2 = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
                        break :blk c._ir_LOAD(ctx, c.IR_ADDR, ctx_addr2);
                    };

                    // Reference the quotation data via a named symbol.
                    var sym_buf: [32]u8 = undefined;
                    const sym_name = std.fmt.bufPrint(&sym_buf, "onez_quot_{d}", .{lit_id}) catch unreachable;
                    const sym_ref = c.ir_const_func(ctx, c.ir_strl(ctx, &sym_buf, sym_name.len), 0);
                    const data_len_const = c.ir_const_addr(ctx, serialized.len);

                    // Compute destination address for this slot.
                    const slot_byte_offset = c.ir_const_addr(ctx, qi * ValueLayout.value_size);
                    const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);

                    const q_id_const = c.ir_const_addr(ctx, q_id);

                    const call_result = c._ir_CALL_5(ctx, c.IR_I32, push_fn, ctx_val, sym_ref, data_len_const, dest_addr, q_id_const);
                    emitCallbackPostCheck(state, call_result, state.error_propagate_status, null, .none);

                    stack[qi] = .{ .raw_at_slot = qi };
                } else {
                    const qval = Value{ .quotation = .{ .instructions = body, .code_ptr = null } };
                    const slot_byte_offset = c.ir_const_addr(ctx, qi * ValueLayout.value_size);
                    const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                    emitPushValue(ctx, &qval, dest_addr);
                    stack[qi] = .{ .raw_at_slot = qi };
                }
            },
            else => {},
        }
    }
}

/// Reload the physical stack pointer and recompute the base address after a
/// quotation call with unresolved row variables updated sp_ptr. Sets base_idx
/// to new_sp - 1 so that abstract slot 0 (row_region) maps to the physical
/// slot just below the new stack top, and abstract slot 1 (the first push
/// after the reload) maps to the new stack top.
fn reloadBaseAfterDynamicCall(state: *CompileState) void {
    const ctx = state.ctx;
    const new_sp_val = c._ir_LOAD(ctx, c.IR_ADDR, state.sp_ptr);
    const one_const = c.ir_const_addr(ctx, 1);
    const adjusted = c.ir_fold2(ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), new_sp_val, one_const);
    state.base_idx = adjusted;
    state.sp_val = new_sp_val;
    // Derive the base from a fresh items_ptr load rather than the cached
    // state.items_ptr: the dynamic call may have relocated the value buffer.
    refreshCachedStackPointer(state);
}

/// Check whether any stack entry in 0..sp is a row_region.
fn hasRowRegion(stack: []const StackEntry, sp: usize) bool {
    for (0..sp) |i| {
        if (stack[i] == .row_region) return true;
    }
    return false;
}

/// Return the index of the first row_region entry in stack[0..sp], or null.
fn findRowRegionIndex(stack: []const StackEntry, sp: usize) ?usize {
    for (0..sp) |i| {
        if (stack[i] == .row_region) return i;
    }
    return null;
}

/// Extract a non-negative fixnum literal from the instruction immediately
/// preceding `idx`. Returns null if the preceding instruction is not a
/// push_literal with a non-negative fixnum value.
fn extractPrecedingLiteralDepth(instructions: []const Instruction, idx: usize) ?usize {
    if (idx == 0) return null;
    return switch (instructions[idx - 1].op) {
        .push_literal => |v| if (v == .fixnum and v.fixnum >= 0) @as(?usize, @intCast(v.fixnum)) else null,
        else => null,
    };
}

/// Perform a compile-time symbolic rewrite of an indexed stack operation.
/// Rearranges the StackEntry array directly when the operation touches only known entries above a symbolic row.
/// The depth literal is popped from the abstract stack and the operation's semantics are applied abstractly.
/// Which indexed stack op a handler is rewriting. Replaces string matching on
/// the op name with a value so the abstract-stack rewrite carries no `eql`
/// re-derivation. `rot_up` is `<rot-n` (pull to top); `rot_down` is `rot-n>`
/// (push to depth).
const IndexedStackOp = enum { pick_n, rot_up, rot_down, nip_n };

fn rewriteIndexedStackOp(
    state: *CompileState,
    op: IndexedStackOp,
    stack: []StackEntry,
    sp: *usize,
    depth: usize,
) IrCodegenError!void {
    // Pop the depth literal from the abstract stack.
    sp.* -= 1;

    switch (op) {
        .pick_n => {
            // ( ... x_n ... x_0 n -- ... x_n ... x_0 x_n )
            // clone the entry at depth to the top
            const target = sp.* - 1 - depth;
            stack[sp.*] = try cloneStackEntry(state, state.base_addr, stack[target], sp.*);
            sp.* += 1;
        },
        .rot_up => {
            // ( ... x_n x_n-1 ... x_0 n -- ... x_n-1 ... x_0 x_n )
            // pull the entry at depth to the top, shifting others down
            if (depth == 0) return;
            const target = sp.* - 1 - depth;
            const saved = stack[target];
            var i = target;
            while (i < sp.* - 1) : (i += 1) {
                stack[i] = stack[i + 1];
            }
            stack[sp.* - 1] = saved;
        },
        .rot_down => {
            // ( ... x_0 n -- x_0 ... )
            // push the top entry to depth, shifting others up
            if (depth == 0) return;
            const target = sp.* - 1 - depth;
            const saved = stack[sp.* - 1];
            var i = sp.* - 1;
            while (i > target) : (i -= 1) {
                stack[i] = stack[i - 1];
            }
            stack[target] = saved;
        },
        .nip_n => {
            // ( ...x1..xn y n -- y )
            // keep the top entry, drop depth entries beneath it
            if (depth == 0) return;
            const top = stack[sp.* - 1];
            sp.* -= depth;
            stack[sp.* - 1] = top;
        },
    }
}

/// Reset all stack entries from 0..sp to raw_at_slot identity (slot i = i).
/// Used after operations that flush to physical memory, ensuring the abstract
/// stack mirrors the physical layout.
fn resetStackToPhysical(stack: []StackEntry, sp: usize) void {
    for (0..sp) |i| {
        stack[i] = .{ .raw_at_slot = i };
    }
}

/// Reset non-row stack entries to raw_at_slot identity, preserving
/// row_region entries. Used after branch merge when the merged state
/// must carry the symbolic row forward.
fn resetStackToPhysicalPreservingRows(stack: []StackEntry, sp: usize) void {
    for (0..sp) |i| {
        if (stack[i] != .row_region) {
            stack[i] = .{ .raw_at_slot = i };
        }
    }
}

/// Establish the row-aware self-tail-call loop entry.
///
/// Model the caller's region below the inputs as a bounded row pinned at abstract slot 0, with the
/// `ic` inputs as raw_at_slot entries above it, and rebase `base_idx` from the live stack pointer
/// so every iteration addresses the inputs sp-relative above the row. Emitted immediately after
/// `LOOP_BEGIN`, so the rederivation reruns at the loop header on every back-edge.
fn setupRowAwareLoopEntry(state: *CompileState, stack: []StackEntry, sp: *usize) void {
    const ctx = state.ctx;
    const ic: usize = state.input_count;
    // base_idx = live_sp - (1 + ic): the row occupies the slot just below input
    // 0, with the inputs in the top `ic` slots.
    const hdr_sp = c._ir_LOAD(ctx, c.IR_ADDR, state.sp_ptr);
    const off_const = c.ir_const_addr(ctx, 1 + ic);
    state.base_idx = c.ir_fold2(ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), hdr_sp, off_const);
    refreshCachedStackPointer(state);
    stack[0] = .{ .row_region = state.nextRowId() };
    var i: usize = 1;
    while (i <= ic) : (i += 1) stack[i] = .{ .raw_at_slot = i };
    sp.* = 1 + ic;
    if (sp.* > state.peak_sp) state.peak_sp = @intCast(sp.*);
}

/// Emit the row-aware self-tail-call back-edge for a word in the preserved-`ic` shape.
///
/// The `ic` new arguments are already the live top slots, so no copy to static input slots is needed.
/// sp is re-stored to the row-relative entry height (i.e., `base_idx + 1 + ic`) and the loop closes
/// over `LOOP_BEGIN`.
fn emitRowAwareSelfTailCall(state: *CompileState, stack: []StackEntry, sp: *usize) IrCodegenError!void {
    const ctx = state.ctx;
    const ic: usize = state.input_count;
    if (state.loop_end_set) {
        state.not_compilable_reason = .nested_loop_conflict;
        return IrCodegenError.NotCompilable;
    }

    // Reify a literal quotation argument above the preserved row before the flush;
    // see the matching note in the ordinary self-tail-call path. flushToPhysicalStack
    // skips quotation_body, so without this resetStackToPhysicalPreservingRows below
    // would rewrite it to a raw_at_slot over an unwritten slot.
    try materializeQuotations(state, stack, sp.*, true);

    flushToPhysicalStack(state, stack, sp.*);

    const height_const = c.ir_const_addr(ctx, 1 + ic);
    const height = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, height_const);
    c._ir_STORE(ctx, state.sp_ptr, height);
    emitSafepointCall(state);

    const loop_end = c._ir_LOOP_END(ctx);
    c.ir_set_op2(ctx, state.loop_begin_ref, loop_end);
    state.loop_end_set = true;
    state.exit_kind = .loop_diverged;
    sp.* = 1 + ic;

    resetStackToPhysicalPreservingRows(stack, sp.*);
}

/// Settle the abstract stack after a concrete-arity op (i.e., consuming `inputs`,
/// producing `outputs`) that may sit above or reach into a row_region at slot 0.
///
/// With no row present this is a plain reset to physical layout.
///
/// With a row at slot 0 and an op that consumes only the concrete entries above it,
/// the row is preserved so subsequent ops keep compiling against it. When the op
/// reaches into the row, it consumes at least as many entries as sit above the row,
/// and its effect on the opaque region cannot be modeled. The abstract stack resyncs
/// to the live runtime stack with a fresh row, matching how a row-introducing call
/// collapses the stack.
/// Collapse the abstract stack to a single fresh row region after a call whose
/// real result depth is runtime-determined. Reloads the live stack pointer so
/// the row's top maps to the new physical top, matching how an unresolved
/// dynamic call collapses the stack. Used at a call site to a row-returning
/// callee, where the declared concrete output count does not model the result.
fn collapseToFreshRow(state: *CompileState, stack: []StackEntry, sp: *usize) void {
    reloadBaseAfterDynamicCall(state);
    sp.* = 1;
    stack[0] = .{ .row_region = state.nextRowId() };
    // The collapse is driven by a genuinely variable-arity callee, so this
    // word's own output depth becomes variable unless a later normalizing `if`
    // reconciles it. Propagating the flag lets a word that merely passes a
    // variable result through inherit the caller-collapse requirement.
    state.variable_arity = true;
}

/// True when the word currently being compiled declares a variable-arity output.
///
/// Used by the `if` merge to distinguish a word whose two concrete arms are genuine output
/// alternatives from a word whose unequal arms are an artifact of a mismodeled callee, which
/// must stay a compile-time stack-shape error.
fn declaredAlternativeOutput(state: *const CompileState) bool {
    const eff = state.stack_effect orelse return false;
    return eff.hasAlternativeOutput();
}

fn settleRowAwareStack(state: *CompileState, stack: []StackEntry, sp: *usize, inputs: usize, outputs: usize) void {
    const sp_before = sp.*;
    const had_row = sp_before > 0 and stack[0].isRowRegion();
    const reaches_row = had_row and inputs >= sp_before;
    sp.* = sp_before - inputs + outputs;
    if (reaches_row) {
        reloadBaseAfterDynamicCall(state);
        sp.* = 1;
    } else if (had_row) {
        resetStackToPhysicalPreservingRows(stack, sp.*);
    } else {
        resetStackToPhysical(stack, sp.*);
    }
}

/// Compare symbolic shapes of two stack states after flushToPhysicalStack.
/// Returns true iff both have the same depth AND every position that is a
/// row_region in either stack is a row_region with the same RowId in the
/// other.
fn symbolicShapeMatches(stack_a: []const StackEntry, sp_a: usize, stack_b: []const StackEntry, sp_b: usize) bool {
    if (sp_a != sp_b) return false;
    for (0..sp_a) |i| {
        const a_row = stack_a[i].rowId();
        const b_row = stack_b[i].rowId();
        if (a_row != null or b_row != null) {
            if (a_row == null or b_row == null) return false;
            if (a_row.? != b_row.?) return false;
        }
    }
    return true;
}

/// A single physical-memory move emitted while materializing the abstract stack into Value slots.
const MoveOp = union(enum) {
    box_i64: struct { slot: usize, ref: c.ir_ref },
    box_f64: struct { slot: usize, ref: c.ir_ref },
    box_bool: struct { slot: usize, ref: c.ir_ref },
    copy: struct { src: usize, dest: usize },
    swap: struct { a: usize, b: usize },
};

/// Per-slot classification for flush moves.
///
/// `.none` marks a slot that is never written: an identity `raw_at_slot` whose value is already
/// in place, or a `quotation_body` / `row_region` entry the planner leaves to the caller.
const SlotMove = union(enum) {
    none,
    box_i64: c.ir_ref,
    box_f64: c.ir_ref,
    box_bool: c.ir_ref,
    copy: usize,
};

/// Count pending copy moves whose source is slot `d`. A slot may only be overwritten once this
/// reaches zero, so that no later move reads a value that has already been clobbered.
fn countSlotReaders(op: []const SlotMove, pending: []const bool, sp: usize, d: usize) usize {
    var count: usize = 0;
    for (0..sp) |j| {
        if (!pending[j]) continue;
        if (op[j] == .copy and op[j].copy == d) count += 1;
    }
    return count;
}

/// Sequentialize the parallel assignment "physical slot i := stack[i]" into an ordered move plan
/// that never destroys a source value before every dependent read has consumed it. Returns the
/// number of `MoveOp`s written to `out`, which must hold at least `sp` entries.
///
/// The earlier implementation boxed symbolic entries first and resolved raw aliases second, with
/// a hazard prepass bolted on to rescue the one shape where first-pass boxing clobbered a slot a
/// later copy still needed
///
///     1 - over swap (sum2) *
///
/// collapsing `[base, base, exp-1]` into `[base, exp-1, exp-1]`), plus a 2-cycle swap special case.
///
/// That pass order mishandled copy-copy cycles longer than two. Modeling materialization as a
/// dependency problem subsumes both repairs: a topological emit handles every acyclic case, and a
/// swap breaks each remaining permutation cycle.
fn planFlushMoves(stack: []const StackEntry, sp: usize, out: []MoveOp) usize {
    std.debug.assert(sp <= max_abstract_stack_depth);
    var op: [max_abstract_stack_depth]SlotMove = undefined;
    var pending: [max_abstract_stack_depth]bool = undefined;
    for (0..sp) |i| {
        op[i] = switch (stack[i]) {
            .i64_ref => |r| .{ .box_i64 = r },
            .f64_ref => |r| .{ .box_f64 = r },
            .bool_ref => |r| .{ .box_bool = r },
            .raw_at_slot => |s| if (s == i) .none else .{ .copy = s },
            .quotation_body, .row_region => .none,
        };
        pending[i] = op[i] != .none;
    }

    var n_out: usize = 0;
    while (true) {
        // Topological pass: emit any write whose destination is no longer read
        // by a pending move. Boxing writes have no source, so they only ever
        // wait on readers of their own destination slot.
        var progressed = false;
        var any_pending = false;
        for (0..sp) |d| {
            if (!pending[d]) continue;
            any_pending = true;
            if (countSlotReaders(&op, &pending, sp, d) != 0) continue;
            out[n_out] = switch (op[d]) {
                .box_i64 => |r| .{ .box_i64 = .{ .slot = d, .ref = r } },
                .box_f64 => |r| .{ .box_f64 = .{ .slot = d, .ref = r } },
                .box_bool => |r| .{ .box_bool = .{ .slot = d, .ref = r } },
                .copy => |s| .{ .copy = .{ .src = s, .dest = d } },
                .none => unreachable,
            };
            n_out += 1;
            pending[d] = false;
            progressed = true;
        }
        if (!any_pending) break;
        if (progressed) continue;

        // XXX(ripta): Deadlock! Only permutation cycles of copies remain; boxing writes are never
        //             sources, so they never deadlock. Some pending copy must read a pending slot.
        //             Otherwise, no pending slot would be read at all, yet a stuck slot is read by
        //             definition.
        //
        //             Swap such a copy `(d := s)`: slot d becomes correct, the old d value moves
        //             into slot s, so redirect every pending copy that read d to read s.
        //
        //             This retires one move per swap.
        var di: usize = 0;
        var found = false;
        while (di < sp) : (di += 1) {
            if (!pending[di]) continue;
            if (op[di] == .copy and op[di].copy < sp and pending[op[di].copy]) {
                found = true;
                break;
            }
        }
        std.debug.assert(found);
        const s = op[di].copy;
        out[n_out] = .{ .swap = .{ .a = di, .b = s } };
        n_out += 1;
        pending[di] = false;
        for (0..sp) |j| {
            if (!pending[j]) continue;
            if (op[j] == .copy and op[j].copy == di) {
                // The swap moved the old `di` value into slot `s`. A reader
                // whose own destination is `s` is now already satisfied (it
                // wanted that value, which the swap just placed); retire it.
                // Every other reader re-reads it from `s`.
                if (j == s) pending[j] = false else op[j] = .{ .copy = s };
            }
        }
    }
    return n_out;
}

/// Emit the IR for a single planned move against the live `base_addr`.
fn emitMoveOp(state: *CompileState, base_addr: c.ir_ref, m: MoveOp) void {
    const ctx = state.ctx;
    switch (m) {
        .box_i64 => |b| {
            const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, b.slot * ValueLayout.value_size));
            emitBoxPayload(ctx, dest_addr, state.tag_offset_const, state.payload_offset_const, state.fixnum_tag_const, b.ref);
        },
        .box_f64 => |b| {
            const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, b.slot * ValueLayout.value_size));
            emitBoxPayload(ctx, dest_addr, state.tag_offset_const, state.payload_offset_const, state.float_tag_const, b.ref);
        },
        .box_bool => |b| {
            const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, b.slot * ValueLayout.value_size));
            emitBoxPayload(ctx, dest_addr, state.tag_offset_const, state.payload_offset_const, state.boolean_tag_const, b.ref);
        },
        .copy => |cp| emitCopySlot(ctx, base_addr, cp.src, cp.dest),
        .swap => |sw| emitSwapSlots(ctx, base_addr, sw.a, sw.b),
    }
}

/// Write all pending symbolic stack entries to their physical memory slots.
/// After this, every entry is materialized in the Value array at base_addr.
fn flushToPhysicalStack(state: *CompileState, stack: []StackEntry, sp: usize) void {
    const base_addr = state.base_addr;

    var plan: [max_abstract_stack_depth]MoveOp = undefined;
    const n = planFlushMoves(stack, sp, &plan);
    for (plan[0..n]) |m| emitMoveOp(state, base_addr, m);

    // The abstract stack now mirrors physical layout. `quotation_body` and
    // `row_region` entries are not materialized here, so leave them untouched.
    for (0..sp) |i| {
        switch (stack[i]) {
            .quotation_body, .row_region => {},
            else => stack[i] = .{ .raw_at_slot = i },
        }
    }
}

/// True when a live `raw_at_slot` entry references a physical slot at or above
/// the current top -- a value stranded where the next push would land. `swap` is
/// lazy: it relabels `stack[i] = raw_at_slot{i+1}` (pointing one slot up) without
/// moving memory, and the in-place indexed rewrites do the same. While `sp` sits
/// above that slot the layout is fine, but a following pop (`drop`, `nip-n`) can
/// lower `sp` onto it, so the entry now aliases the slot a fresh push targets.
fn hasStrandedRawEntry(stack: []const StackEntry, sp: usize) bool {
    for (0..sp) |i| {
        if (stack[i] == .raw_at_slot and stack[i].raw_at_slot >= sp) return true;
    }
    return false;
}

/// Restore the invariant that no live value is stranded at or above `sp`.
///
/// Called after a lazy `sp`-decrease that can leave an up-pointing `raw_at_slot`
/// survivor. Without it, the next eager physical-slot write -- a quotation
/// materialize, or a `dup`/`over`/`pick-n` copy targeting slot `sp` -- overwrites
/// the stranded Value before the flush that would relocate it, a value-level
/// miscompile (`swap drop [ q ] dip` returns the quotation instead of the value
/// it must preserve). Reconciling the abstract stack to physical identity via the
/// proven flush planner relocates every stranded entry -- handling arbitrary
/// permutations, not just the single-survivor `swap drop` shape -- and no-ops
/// unless a strand is actually present, so the common pop path is untouched.
fn settleStrandedEntries(state: *CompileState, stack: []StackEntry, sp: usize) void {
    if (!hasStrandedRawEntry(stack, sp)) return;
    flushToPhysicalStack(state, stack, sp);
}

/// Emit the common epilogue for a compiled word: box typed stack entries
/// into physical Value slots, resolve raw_at_slot copies/swaps, update
/// sp_ptr, and emit RETURN with ok_status.
fn emitEpilogue(
    state: *CompileState,
    stack: []StackEntry,
    sp: usize,
    input_count: u8,
    output_count: u8,
) IrCodegenError!void {
    const ctx = state.ctx;
    const base_addr = state.base_addr;

    if (sp != output_count) return IrCodegenError.StackShapeMismatch;

    // Reification: quotations produced by a word can be output into a concrete runtime value before
    // the flush. This skips quotation bodies, but also means the quotation is written into the
    // physical slit. This is an escape position (word-output), so the reification is recorded for
    // the manifest pass's Option C policy.
    try materializeQuotations(state, stack, sp, true);

    // Epilogue: can't materialize a symbolic row as a word result
    for (0..sp) |i| {
        switch (stack[i]) {
            .row_region => {
                state.not_compilable_reason = .abstract_stack_underflow;
                return IrCodegenError.NotCompilable;
            },
            else => {},
        }
    }

    var plan: [max_abstract_stack_depth]MoveOp = undefined;
    const n = planFlushMoves(stack, sp, &plan);
    for (plan[0..n]) |m| emitMoveOp(state, base_addr, m);

    if (input_count > output_count) {
        const sp_delta = c.ir_const_addr(ctx, input_count - output_count);
        const new_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), state.sp_val, sp_delta);
        c._ir_STORE(ctx, state.sp_ptr, new_sp);
    } else if (input_count < output_count) {
        const sp_delta = c.ir_const_addr(ctx, output_count - input_count);
        const new_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.sp_val, sp_delta);
        c._ir_STORE(ctx, state.sp_ptr, new_sp);
    } else {
        c._ir_STORE(ctx, state.sp_ptr, state.sp_val);
    }

    c._ir_RETURN(ctx, state.ok_status);
}

/// Emit a retain on the refcounted backing of the Value at physical `slot`.
/// Call after physically duplicating a `.raw_at_slot` entry so the duplicate
/// counts as a new owning reference. No-op for scalar Values at runtime.
fn emitRetainSlot(state: *CompileState, slot: usize) void {
    if (state.retain_slot_fn == c.IR_UNUSED) return;
    const ctx = state.ctx;
    const slot_addr = liveSlotAddr(state, slot);
    _ = c._ir_CALL_1(ctx, c.IR_I32, state.retain_slot_fn, slot_addr);
}

/// Emit a release on the refcounted backing of the Value at physical `slot`.
/// Call before discarding a `.raw_at_slot` entry that no native consumes.
/// No-op for scalar Values at runtime.
fn emitReleaseSlot(state: *CompileState, slot: usize) void {
    if (state.release_slot_fn == c.IR_UNUSED) return;
    const ctx = state.ctx;
    const slot_addr = liveSlotAddr(state, slot);
    _ = c._ir_CALL_1(ctx, c.IR_I32, state.release_slot_fn, slot_addr);
}

/// Clone a stack entry to a new destination slot. For IR-ref entries
/// (i64, f64, bool, quotation_body) the ref is shared. For raw_at_slot
/// entries a physical copy is emitted and the new entry points to dest_slot.
fn cloneStackEntry(
    state: *CompileState,
    base_addr: c.ir_ref,
    entry: StackEntry,
    dest_slot: usize,
) IrCodegenError!StackEntry {
    return switch (entry) {
        .i64_ref => |ref| .{ .i64_ref = ref },
        .f64_ref => |ref| .{ .f64_ref = ref },
        .bool_ref => |ref| .{ .bool_ref = ref },
        .quotation_body => |body| .{ .quotation_body = body },
        .raw_at_slot => |s| blk: {
            emitCopySlot(state.ctx, base_addr, s, dest_slot);
            // The copy is a second owning reference to the same backing.
            emitRetainSlot(state, dest_slot);
            // When the source slot holds a quotation parameter with a tracked
            // concrete effect, carry that effect to the copy so a later `call`
            // on the copied quotation (the `over call` / `dup call` idiom in a
            // combinator like `(any-loop)`) resolves its arity instead of
            // collapsing the abstract stack to a row. A full slot map is a
            // graceful degrade: on overflow the copy is simply untracked and the
            // call falls back to the row path, exactly as before this change.
            if (state.quotation_slots.findSlot(s)) |info| {
                _ = state.quotation_slots.add(.{
                    .slot = dest_slot,
                    .input_count = info.input_count,
                    .output_count = info.output_count,
                });
            }
            break :blk .{ .raw_at_slot = dest_slot };
        },
        .row_region => blk: {
            state.not_compilable_reason = .abstract_stack_underflow;
            break :blk IrCodegenError.NotCompilable;
        },
    };
}

/// Resolve a word via the resolver and emit a native callback. Used for
/// words that have an inline fast path (tryEmitInline*) with a fallback
/// to the generic native call mechanism.
fn emitResolvedNativeCallback(
    state: *CompileState,
    name: []const u8,
    stack: []StackEntry,
    sp: *usize,
    line: usize,
) IrCodegenError!void {
    const res = state.resolver orelse {
        state.not_compilable_reason = .unresolvable_word;
        return IrCodegenError.NotCompilable;
    };
    const resolved = res.resolve(name, res.user_data) orelse {
        state.not_compilable_reason = .unresolvable_word;
        return IrCodegenError.NotCompilable;
    };

    if (resolved.is_native) {
        if (sp.* < resolved.input_count) return IrCodegenError.StackUnderflow;

        try materializeQuotations(state, stack, sp.*, false);
        flushToPhysicalStack(state, stack, sp.*);
        const ctx_val = emitCallbackPreamble(state, sp.*);

        if (resolved.stack_effect_ptr) |eff_ptr| {
            emitParamValidation(state, eff_ptr);
        }

        emitNativeWordCall(state, ctx_val, name, resolved, line);

        if (exitFallsThrough(state.exit_kind)) {
            settleRowAwareStack(state, stack, sp, resolved.input_count, resolved.output_count);
        }
    } else {
        state.not_compilable_reason = .unresolvable_word;
        return IrCodegenError.NotCompilable;
    }
}

/// Emit a word call whose effect on the abstract stack cannot be modeled, as an opaque dynamic call.
/// Used both for native callees with unresolved row-variable effects and for runtime-depth indexed
/// stack ops.
///
/// Returns true when compilation should `continue`; false when it diverged and the caller should `break`.
fn emitDynamicRowFallback(state: *CompileState, stack: []StackEntry, sp: *usize, name: []const u8, resolved: ResolvedWord, line: usize) IrCodegenError!bool {
    return emitDynamicRowFallbackPreserving(state, stack, sp, name, resolved, line, 0);
}

/// Emit a call that reaches below the abstract frame but has a CONCRETE net
/// effect (a fixed `effective_out`, not a row-returning callee). The call runs
/// against the live stack exactly like the row-fallback path, but because the
/// result depth is statically known, the abstract stack is re-established
/// concretely rather than collapsed to an opaque row: the anchor is rebased to
/// the `effective_out` results the call left at the physical top, so subsequent
/// ops address them correctly instead of sp-relative off a spurious row. This is
/// the reach-through-accumulator shape (`(push-non-kebab!)` inside a `#each`
/// body): folding the invariant accumulator into a row is what mis-addressed a
/// later store to a fixed outer slot.
fn emitReachBelowConcrete(state: *CompileState, stack: []StackEntry, sp: *usize, name: []const u8, resolved: ResolvedWord, line: usize, effective_out: usize) IrCodegenError!bool {
    try materializeQuotations(state, stack, sp.*, false);
    flushToPhysicalStack(state, stack, sp.*);

    const ctx_val = emitCallbackPreamble(state, sp.*);
    if (resolved.is_native) {
        emitNativeWordCall(state, ctx_val, name, resolved, line);
    } else if (resolved.is_generic) {
        emitAotGenericDispatch(state, resolved.dispatch_id, resolved.word_id, name, line);
    } else {
        emitAotWordCall(state, ctx_val, name, resolved, line);
    }

    if (exitFallsThrough(state.exit_kind)) {
        // Rebase to the concrete result region the call left at the physical
        // top: base_idx = live_sp - effective_out, so abstract slots
        // 0..effective_out map to those results. The invariant slots the call
        // reached but preserved (its outputs) stay concretely addressed.
        const ctx = state.ctx;
        const new_sp_val = c._ir_LOAD(ctx, c.IR_ADDR, state.sp_ptr);
        const off_const = c.ir_const_addr(ctx, effective_out);
        state.base_idx = c.ir_fold2(ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), new_sp_val, off_const);
        state.sp_val = new_sp_val;
        refreshCachedStackPointer(state);
        sp.* = effective_out;
        for (0..effective_out) |i| stack[i] = .{ .raw_at_slot = i };
        return true;
    }

    return false;
}

/// After the call keeps the callee's trailing `preserve` concrete outputs live above the collapsed
/// row instead of folding them into it.
///
/// Unspecializable row-variable callee whose declared effect keeps concrete values above the output
/// row variable:
///
///     2dip: ( ..a x y quot -- ..b x y )
///
/// keeps `x y`. Collapsing only the region the callee's quotation parameter actually touched (`..b`);
/// the threaded `x y` stay as `raw_at_slot` entries pinned at the live physical top, so a combinator
/// threading them keeps operating on real entries.
///
/// base_idx is set to `new_sp - 1 - preserve` so abstract slot 0 (i.e., the row) maps just below the
/// preserved suffix and abstract slots `1..=preserve` map to the top `preserve` physical slots.
/// `preserve == 0` is the plain collapse to `sp == 1`.
fn emitDynamicRowFallbackPreserving(state: *CompileState, stack: []StackEntry, sp: *usize, name: []const u8, resolved: ResolvedWord, line: usize, preserve: usize) IrCodegenError!bool {
    try materializeQuotations(state, stack, sp.*, false);
    flushToPhysicalStack(state, stack, sp.*);

    const ctx_val = emitCallbackPreamble(state, sp.*);
    if (resolved.is_native) {
        emitNativeWordCall(state, ctx_val, name, resolved, line);
    } else if (resolved.is_generic) {
        emitAotGenericDispatch(state, resolved.dispatch_id, resolved.word_id, name, line);
    } else {
        emitAotWordCall(state, ctx_val, name, resolved, line);
    }

    if (exitFallsThrough(state.exit_kind)) {
        if (preserve == 0) {
            reloadBaseAfterDynamicCall(state);
            sp.* = 1;
            stack[0] = .{ .row_region = state.nextRowId() };
        } else {
            const ctx = state.ctx;
            const new_sp_val = c._ir_LOAD(ctx, c.IR_ADDR, state.sp_ptr);
            const off_const = c.ir_const_addr(ctx, 1 + preserve);
            state.base_idx = c.ir_fold2(ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), new_sp_val, off_const);
            state.sp_val = new_sp_val;
            refreshCachedStackPointer(state);
            sp.* = 1 + preserve;
            stack[0] = .{ .row_region = state.nextRowId() };
            var i: usize = 1;
            while (i <= preserve) : (i += 1) stack[i] = .{ .raw_at_slot = i };
        }
        return true;
    }

    return false;
}

/// Count the trailing concrete outputs that sit above the last output row variable in `eff`.
///
/// Returns 0 when the outputs carry no row variable (the plain collapse applies) or ends with a
/// row variable (no concrete suffix to preserve). For example, for
///
///     2dip: ( ..a x y quot -- ..b x y )
///
/// this value is 2 (i.e., `x` and `y`).
fn trailingConcreteOutputs(eff: *const StackEffect) usize {
    var has_row = false;
    for (eff.outputs) |p| {
        if (p.is_row_variable) {
            has_row = true;
            break;
        }
    }
    if (!has_row) return 0;
    var count: usize = 0;
    var i = eff.outputs.len;
    while (i > 0) {
        i -= 1;
        if (eff.outputs[i].is_row_variable) break;
        count += 1;
    }
    return count;
}

/// Route an inline stack op (`swap`/`over`/`dup`) that reached below the
/// abstract base into the implicit caller row: resolve it as a native and emit
/// it against the live physical stack via emitDynamicRowFallback, collapsing the
/// abstract stack to a fresh row_region. Returns true to `continue`, false to
/// `break`. Caller must already be in aot_mode.
fn emitInlineRowUnderflow(
    state: *CompileState,
    stack: []StackEntry,
    sp: *usize,
    name: []const u8,
    line: usize,
) IrCodegenError!bool {
    const res = state.resolver orelse {
        state.not_compilable_reason = .unresolvable_word;
        return IrCodegenError.NotCompilable;
    };
    const resolved = res.resolve(name, res.user_data) orelse {
        state.not_compilable_reason = .unresolvable_word;
        return IrCodegenError.NotCompilable;
    };
    return emitDynamicRowFallback(state, stack, sp, name, resolved, line);
}

/// Emit a runtime truthiness check for a Value at a physical stack slot.
/// Loads the tag and payload, computing:
///   is_falsy = (tag == boolean) AND (payload == false)
/// Returns the negated result (is_truthy).
fn emitSlotTruthiness(ctx: *c.ir_ctx, base_addr: c.ir_ref, s: usize, state: *CompileState) c.ir_ref {
    const slot_byte_offset = c.ir_const_addr(ctx, s * ValueLayout.value_size);
    const slot_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
    const tag_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), slot_addr, state.tag_offset_const);
    const tag_val = c._ir_LOAD(ctx, ValueLayout.ir_tag_type, tag_addr);
    const is_bool_tag = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), tag_val, state.boolean_tag_const);

    const payload_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), slot_addr, state.payload_offset_const);

    // Read the payload's low byte as an integer, never as IR_BOOL. Only a boolean Value holds a
    // valid 0/1 there. `is_bool_tag` already gates the falsy result, but the IR AND evaluates both
    // operands unconditionally, so a non-boolean payload byte outside {0,1} would trip IR_BOOL's
    // load-safety check. An integer compare against zero is equivalent and panic-free.
    const payload_val = c._ir_LOAD(ctx, c.IR_U8, payload_addr);
    const zero_u8 = c.ir_const_u8(ctx, 0);
    const is_false_payload = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), payload_val, zero_u8);
    const is_falsy = c.ir_fold2(ctx, c.IR_OPT(c.IR_AND, c.IR_BOOL), is_bool_tag, is_false_payload);
    const false_const = c.ir_const_bool(ctx, false);
    return c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), is_falsy, false_const);
}

/// Compute the IR truthiness boolean for a stack entry.
/// 1z truthiness: only `f` (boolean false) is falsy.
fn emitTruthiness(state: *CompileState, entry: StackEntry, base_addr: c.ir_ref) IrCodegenError!c.ir_ref {
    const ctx = state.ctx;
    return switch (entry) {
        .bool_ref => |ref| ref,
        .i64_ref, .f64_ref => c.ir_const_bool(ctx, true),
        .raw_at_slot => |s| emitSlotTruthiness(ctx, base_addr, s, state),
        // Quotations are always truthy
        .quotation_body => c.ir_const_bool(ctx, true),
        .row_region => {
            state.not_compilable_reason = .quotation_truthiness;
            return IrCodegenError.NotCompilable;
        },
    };
}

/// Emit an indirect call to a quotation Value stored at physical stack slot.
/// Both AOT and JIT modes: tag check, code_ptr null check, direct call with
/// interpreter fallback for uncompiled quotations.
fn emitIndirectQuotCall(
    state: *CompileState,
    stack: []StackEntry,
    sp: *usize,
    slot: usize,
    line: usize,
) IrCodegenError!void {
    const ctx = state.ctx;
    const base_addr = state.base_addr;

    const slot_byte_offset = c.ir_const_addr(ctx, slot * ValueLayout.value_size);
    const elem_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);

    // Check tag is quotation
    const quotation_tag_const = emitTagConst(ctx, .quotation);
    if (state.type_mismatch_error_fn != c.IR_UNUSED) {
        emitTagCheckOrError(state, elem_addr, quotation_tag_const, state.type_mismatch_error_fn);
    } else {
        emitTagCheck(ctx, elem_addr, quotation_tag_const, state.tag_offset_const, state.bail_status);
    }

    // Load code_ptr
    const code_ptr_off = c.ir_const_addr(ctx, ValueLayout.quotation_code_ptr_offset);
    const code_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, code_ptr_off);
    const code_ptr_val = c._ir_LOAD(ctx, c.IR_ADDR, code_ptr_addr);

    // Null-check code_ptr
    const null_addr = c.ir_const_addr(ctx, 0);
    const is_null = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), code_ptr_val, null_addr);
    const if_null = c._ir_IF(ctx, is_null);

    // Cold path: interpreter fallback for quotations without a code_ptr
    c._ir_IF_TRUE_cold(ctx, if_null);
    {
        sp.* += 1;
        flushToPhysicalStack(state, stack, sp.*);
        const ctx_val = emitCallbackPreamble(state, sp.*);
        sp.* -= 1;
        const call_quot_fn = if (state.aot_mode)
            state.call_quotation_fn
        else
            c.ir_const_addr(ctx, @intFromPtr(&jitCallQuotation));
        state.noteAotFallbackEmission(.quotation, "<quotation>", 0, line);
        const fb_result = c._ir_CALL_1(ctx, c.IR_I32, call_quot_fn, ctx_val);
        emitCallbackPostCheck(state, fb_result, state.error_propagate_status, null, .{ .builtin = .{ .kind = .call, .line = line } });
    }
    const end_fallback = c._ir_END(ctx);

    // Hot path: quotation is compiled, call directly
    c._ir_IF_FALSE(ctx, if_null);
    {
        flushToPhysicalStack(state, stack, sp.*);

        const sp_const = c.ir_const_addr(ctx, sp.*);
        const new_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, sp_const);
        c._ir_STORE(ctx, state.sp_ptr, new_sp);

        const call_result = if (state.aot_mode)
            // AOT: dispatch via callback because ir_emit_c types loaded
            // addresses as uintptr_t which cannot be called directly.
            c._ir_CALL_2(ctx, c.IR_I32, state.call_code_ptr_fn, state.jit_ctx_ptr, code_ptr_val)
        else
            c._ir_CALL_1(ctx, c.IR_I32, code_ptr_val, state.jit_ctx_ptr);
        emitCallbackPostCheck(state, call_result, call_result, null, .{ .builtin = .{ .kind = .call, .line = line } });
    }
    const end_compiled = c._ir_END(ctx);

    c._ir_MERGE_2(ctx, end_fallback, end_compiled);

    if (state.refresh_stack_fn != c.IR_UNUSED) {
        refreshCachedStackPointer(state);
    }
}

/// Settle one branch of an if-over-row before its END so both branches leave the
/// physical stack at the same height for the merge's sp reload. Slot 0 is the row,
/// so the depth is `base_idx + branch_sp` even when the branch collapsed mid-way
/// and then pushed above the new row.
fn finalizeRowBranch(state: *CompileState, stack: []StackEntry, branch_sp: usize) void {
    flushToPhysicalStack(state, stack, branch_sp);
    const sp_const = c.ir_const_addr(state.ctx, branch_sp);
    const new_sp = c.ir_fold2(state.ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, sp_const);
    c._ir_STORE(state.ctx, state.sp_ptr, new_sp);
}

/// Decide the variable-arity flag after an if-over-row whose branches both fall
/// through. Two concrete arms reconcile to a fixed depth and may reset the flag;
/// an arm that collapsed to an opaque row carries no trustworthy depth, so it can
/// only accumulate a difference detected deeper, never clobber it.
fn mergedVariableArity(prev: bool, true_sp: usize, false_sp: usize, any_row_arm: bool) bool {
    if (any_row_arm) return prev or (true_sp != false_sp);
    return true_sp != false_sp;
}

/// Emit an `if` whose condition is a symbolic row: the live physical top holds
/// the boolean, and the remainder of the stack is opaque. Read truthiness from
/// the physical top, pop it, compile both branch bodies against a fresh row, and
/// rejoin to a single fresh row at the merge. AOT-only; the row reaches the live
/// runtime stack through native callbacks the branch bodies emit, so concrete
/// abstract modeling is neither possible nor needed. A branch quotation given as
/// a `raw_at_slot` value rather than a `quotation_body` is dispatched at runtime.
fn emitIfOverRow(
    state: *CompileState,
    stack: []StackEntry,
    sp: *usize,
    true_entry: StackEntry,
    false_entry: StackEntry,
    true_body: ?[]const Instruction,
    false_body: ?[]const Instruction,
) IrCodegenError!void {
    const ctx = state.ctx;

    // Truthiness of the live physical top, read before the condition is popped.
    const cond_ref = emitSlotTruthiness(ctx, state.base_addr, 0, state);
    emitReleaseSlot(state, 0);

    // Pop the condition from the physical stack, then resync the abstract row to
    // the new live top so both branches model a single fresh row.
    const one_const = c.ir_const_addr(ctx, 1);
    const popped_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), state.sp_val, one_const);
    c._ir_STORE(ctx, state.sp_ptr, popped_sp);
    reloadBaseAfterDynamicCall(state);
    sp.* = 1;
    stack[0] = .{ .row_region = state.nextRowId() };

    const saved_exit_kind = state.exit_kind;
    const saved_loop_end_set = state.loop_end_set;
    const saved_items_ptr = state.items_ptr;
    const saved_base_addr = state.base_addr;
    const saved_sp_val = state.sp_val;
    const saved_base_idx = state.base_idx;

    const if_ref = c._ir_IF(ctx, cond_ref);

    c._ir_IF_TRUE(ctx, if_ref);
    state.recordBlockStart(ctx.unnamed_0.control);
    state.exit_kind = .falls_through;
    var true_sp: usize = 1;
    stack[0] = .{ .row_region = state.nextRowId() };
    if (true_body) |tb| {
        try compileInstructions(state, tb, stack, &true_sp);
    } else {
        emitIfBranchDispatch(state, stack, &true_sp, true_entry.raw_at_slot);
    }
    const true_exit_kind = state.exit_kind;
    var end_true: c.ir_ref = c.IR_UNUSED;
    var true_ends_on_row = false;
    if (exitFallsThrough(true_exit_kind)) {
        finalizeRowBranch(state, stack, true_sp);
        true_ends_on_row = hasRowRegion(stack, true_sp);
        end_true = c._ir_END(ctx);
    }

    state.items_ptr = saved_items_ptr;
    state.base_addr = saved_base_addr;
    state.sp_val = saved_sp_val;
    state.base_idx = saved_base_idx;

    c._ir_IF_FALSE(ctx, if_ref);
    state.recordBlockStart(ctx.unnamed_0.control);
    state.exit_kind = .falls_through;
    var false_sp: usize = 1;
    stack[0] = .{ .row_region = state.nextRowId() };
    if (false_body) |fb| {
        try compileInstructions(state, fb, stack, &false_sp);
    } else {
        emitIfBranchDispatch(state, stack, &false_sp, false_entry.raw_at_slot);
    }
    const false_exit_kind = state.exit_kind;
    var false_ends_on_row = false;
    if (exitFallsThrough(false_exit_kind)) {
        finalizeRowBranch(state, stack, false_sp);
        false_ends_on_row = hasRowRegion(stack, false_sp);
    }

    const true_diverged = !exitFallsThrough(true_exit_kind);
    const false_diverged = !exitFallsThrough(false_exit_kind);

    if (true_diverged and false_diverged) {
        state.exit_kind = mergeNonFallthroughExitKinds(true_exit_kind, false_exit_kind);
        return;
    } else if (true_diverged) {
        // Only the false path continues; it falls through after IF_FALSE.
        reloadBaseAfterDynamicCall(state);
        sp.* = 1;
        stack[0] = .{ .row_region = state.nextRowId() };
        state.exit_kind = saved_exit_kind;
    } else if (false_diverged) {
        c._ir_BEGIN(ctx, end_true);
        reloadBaseAfterDynamicCall(state);
        sp.* = 1;
        stack[0] = .{ .row_region = state.nextRowId() };
        state.exit_kind = saved_exit_kind;
    } else {
        // Both branches fall through. When they leave different physical depths
        // (each branch stored its own sp via finalizeRowBranch), the word's
        // runtime output depth genuinely varies, so a caller must collapse to a
        // row rather than trust the declared output count. When both leave equal
        // concrete depths, the merge reconciles to that fixed depth, normalizing
        // away any variability a branch inherited from a variable-arity callee.
        // An arm that collapsed to an opaque row carries no trustworthy depth
        // (its abstract sp is 1 regardless of runtime depth), so it cannot
        // disprove a difference detected at a deeper if-over-row.
        state.variable_arity = mergedVariableArity(state.variable_arity, true_sp, false_sp, true_ends_on_row or false_ends_on_row);
        const end_false = c._ir_END(ctx);
        c._ir_MERGE_2(ctx, end_true, end_false);
        state.recordBlockStart(ctx.unnamed_0.control);
        reloadBaseAfterDynamicCall(state);
        sp.* = 1;
        stack[0] = .{ .row_region = state.nextRowId() };
        state.exit_kind = saved_exit_kind;
    }
    state.loop_end_set = saved_loop_end_set;
}

/// Emit a runtime quotation dispatch for an `if` branch where the quotation
/// is a `raw_at_slot` entry rather than a statically-known `quotation_body`.
/// Loads code_ptr from the quotation and calls it directly when compiled,
/// falling back to jitCallQuotation for uncompiled quotations.
///
/// Unlike `emitIndirectQuotCall`, this does NOT set `dynamic_call_emitted`
/// because the branch effect is known from the other (quotation_body) branch.
fn emitIfBranchDispatch(
    state: *CompileState,
    stack: []StackEntry,
    sp: *usize,
    slot: usize,
) void {
    const ctx = state.ctx;
    const base_addr = state.base_addr;

    const slot_byte_offset = c.ir_const_addr(ctx, slot * ValueLayout.value_size);
    const elem_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);

    // Load code_ptr from the quotation's payload
    const code_ptr_off = c.ir_const_addr(ctx, ValueLayout.quotation_code_ptr_offset);
    const code_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, code_ptr_off);
    const code_ptr_val = c._ir_LOAD(ctx, c.IR_ADDR, code_ptr_addr);

    // Null-check code_ptr
    const null_addr = c.ir_const_addr(ctx, 0);
    const is_null = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), code_ptr_val, null_addr);
    const if_null = c._ir_IF(ctx, is_null);

    // Cold path: interpreter fallback for uncompiled quotations
    c._ir_IF_TRUE_cold(ctx, if_null);
    {
        sp.* += 1;
        flushToPhysicalStack(state, stack, sp.*);
        const ctx_val = emitCallbackPreamble(state, sp.*);
        sp.* -= 1;
        const call_quot_fn = if (state.aot_mode)
            state.call_quotation_fn
        else
            c.ir_const_addr(ctx, @intFromPtr(&jitCallQuotation));
        state.noteAotFallbackEmission(.quotation, "<quotation>", 0, 0);
        const fb_result = c._ir_CALL_1(ctx, c.IR_I32, call_quot_fn, ctx_val);
        emitCallbackPostCheck(state, fb_result, state.error_propagate_status, null, .none);
    }
    const end_fallback = c._ir_END(ctx);

    // Hot path: quotation is compiled, call directly
    c._ir_IF_FALSE(ctx, if_null);
    {
        flushToPhysicalStack(state, stack, sp.*);

        const sp_const = c.ir_const_addr(ctx, sp.*);
        const new_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, sp_const);
        c._ir_STORE(ctx, state.sp_ptr, new_sp);

        const call_result = if (state.aot_mode)
            c._ir_CALL_2(ctx, c.IR_I32, state.call_code_ptr_fn, state.jit_ctx_ptr, code_ptr_val)
        else
            c._ir_CALL_1(ctx, c.IR_I32, code_ptr_val, state.jit_ctx_ptr);
        emitCallbackPostCheck(state, call_result, call_result, null, .none);
    }
    const end_compiled = c._ir_END(ctx);

    c._ir_MERGE_2(ctx, end_fallback, end_compiled);

    if (state.refresh_stack_fn != c.IR_UNUSED) {
        refreshCachedStackPointer(state);
    }
}

/// Compile a while/until loop: pred and body quotations with an optional
/// condition negation for `until` semantics.
fn compilePredBodyLoop(
    state: *CompileState,
    stack: []StackEntry,
    sp: *usize,
    pred_entry: StackEntry,
    body_entry: StackEntry,
    negate_cond: bool,
) IrCodegenError!void {
    const ctx = state.ctx;

    // Resolve the body quotation before compiling the predicate. Predicate
    // compilation writes through `stack`, and `body_entry` may alias the stack
    // slot it was read from, so reading `body_entry` after the predicate runs
    // would observe the predicate's scratch values instead of the body. The
    // scalar slice / slot extracted here cannot alias that slot.
    const BodySource = union(enum) { quotation: []const Instruction, slot: usize, unsupported };
    const body_source: BodySource = switch (body_entry) {
        .quotation_body => |body| .{ .quotation = body },
        .raw_at_slot => |s| .{ .slot = s },
        else => .unsupported,
    };

    // Reify any quotation carried below the loop args before the header; see the
    // matching note in emitIntrinsicTimes. body_source above already captured the
    // loop's body quotation, so this acts only on the carried region.
    try materializeQuotations(state, stack, sp.*, true);

    flushToPhysicalStack(state, stack, sp.*);

    // Snapshot the symbolic stack state at loop entry for back-edge
    // invariance checks (RowId positions must be identical each iteration).
    const loop_entry_stack = state.allocator.dupe(StackEntry, stack[0..sp.*]) catch return IrCodegenError.OutOfMemory;
    defer state.allocator.free(loop_entry_stack);
    const loop_entry_sp = sp.*;

    const pre_loop_sp_const = c.ir_const_addr(ctx, sp.*);
    const pre_loop_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, pre_loop_sp_const);
    c._ir_STORE(ctx, state.sp_ptr, pre_loop_sp);

    const entry_end = c._ir_END(ctx);
    const loop_ref = c._ir_LOOP_BEGIN(ctx, entry_end);
    state.recordBlockStart(loop_ref);
    // AOT loop back-edges can arrive after callbacks moved ctx.stack.items.
    // Refresh at the header so predicate/body slot accesses use the live base.
    if (state.aot_mode and state.refresh_stack_fn != c.IR_UNUSED) {
        refreshCachedStackPointer(state);
    }

    // Execute predicate
    const pre_body_sp = sp.*;
    switch (pred_entry) {
        .quotation_body => |body| {
            resetStackToPhysicalPreservingRows(stack, sp.*);
            try compileInstructions(state, body, stack, sp);
        },
        .raw_at_slot => |s| {
            try emitIndirectQuotCall(state, stack, sp, s, 0);
            sp.* += 1; // predicate pushes one value (bool)
            resetStackToPhysicalPreservingRows(stack, sp.*);
        },
        else => {
            state.not_compilable_reason = .quotation_reification;
            return IrCodegenError.NotCompilable;
        },
    }

    // Pred should push a boolean on top
    if (sp.* < pre_body_sp + 1) return IrCodegenError.StackShapeMismatch;
    sp.* -= 1;
    const cond_entry = stack[sp.*];
    if (!symbolicShapeMatches(stack, sp.*, loop_entry_stack, loop_entry_sp)) return IrCodegenError.StackShapeMismatch;

    const truthy = try emitTruthiness(state, cond_entry, state.base_addr);
    const continue_cond = if (negate_cond)
        c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), truthy, c.ir_const_bool(ctx, false))
    else
        truthy;

    flushToPhysicalStack(state, stack, sp.*);

    const if_continue = c._ir_IF(ctx, continue_cond);

    c._ir_IF_TRUE(ctx, if_continue);

    // Execute body
    switch (body_source) {
        .quotation => |body| {
            resetStackToPhysicalPreservingRows(stack, sp.*);
            try compileInstructions(state, body, stack, sp);
            if (!symbolicShapeMatches(stack, sp.*, loop_entry_stack, loop_entry_sp)) return IrCodegenError.StackShapeMismatch;
            flushToPhysicalStack(state, stack, sp.*);
        },
        .slot => |s| {
            try emitIndirectQuotCall(state, stack, sp, s, 0);
        },
        .unsupported => {
            state.not_compilable_reason = .quotation_reification;
            return IrCodegenError.NotCompilable;
        },
    }

    resetStackToPhysicalPreservingRows(stack, sp.*);

    emitSafepointCall(state);
    const loop_end = c._ir_LOOP_END(ctx);
    c.ir_set_op2(ctx, loop_ref, loop_end);

    c._ir_IF_FALSE(ctx, if_continue);

    // The safepoint on the IF_TRUE (continue) path updated
    // state.items_ptr/base_addr to IR refs that don't dominate
    // this exit path. Re-LOAD to get dominating refs.
    if (state.refresh_stack_fn != c.IR_UNUSED) {
        refreshCachedStackPointer(state);
    }

    resetStackToPhysicalPreservingRows(stack, sp.*);
}

/// Try to emit inline IR for virtual type unwrapping.
/// Recognizes the pattern: push_literal(type_val=tv) + call_word("native.virtual-unwrap").
/// Returns true if inlined; false to fall back to runtime callback.
fn tryEmitInlineVirtualUnwrap(
    state: *CompileState,
    instructions: []const Instruction,
    idx: usize,
    stack: []StackEntry,
    sp: *usize,
) bool {
    if (sp.* < 2) return false;

    // virtual type must be a constant .type_val from the preceding instruction
    const vt: *const VirtualType = if (idx > 0) blk: {
        break :blk switch (instructions[idx - 1].op) {
            .push_literal => |v| switch (v) {
                .type_val => |tv| tv.virtual_type orelse return false,
                else => return false,
            },
            else => return false,
        };
    } else return false;

    const value_slot: usize = switch (stack[sp.* - 2]) {
        .raw_at_slot => |s| s,
        else => return false,
    };

    sp.* -= 2;

    const ctx = state.ctx;
    const base_addr = state.base_addr;

    const elem_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, value_slot * ValueLayout.value_size));
    if (state.type_mismatch_error_fn != c.IR_UNUSED) {
        emitTagCheckOrError(state, elem_addr, state.tagged_tag_const, state.type_mismatch_error_fn);
    } else {
        emitTagCheck(ctx, elem_addr, state.tagged_tag_const, state.tag_offset_const, state.bail_status);
    }

    const tag_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, c.ir_const_addr(ctx, ValueLayout.tagged_tag_ptr_offset));
    const actual_vtype = c._ir_LOAD(ctx, c.IR_ADDR, tag_ptr_addr);
    const expected_vtype = c.ir_const_addr(ctx, @intFromPtr(vt));
    const vtype_mismatch = c.ir_fold2(ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), actual_vtype, expected_vtype);
    const if_mismatch = c._ir_IF(ctx, vtype_mismatch);
    c._ir_IF_TRUE_cold(ctx, if_mismatch);
    if (state.type_mismatch_error_fn != c.IR_UNUSED) {
        emitErrorReturn(state, state.type_mismatch_error_fn);
    } else {
        c._ir_RETURN(ctx, state.bail_status);
    }
    c._ir_IF_FALSE(ctx, if_mismatch);

    const inner_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, c.ir_const_addr(ctx, ValueLayout.tagged_inner_ptr_offset));
    const inner_ptr = c._ir_LOAD(ctx, c.IR_ADDR, inner_ptr_addr);
    emitCopyFromPtr(ctx, base_addr, inner_ptr, value_slot);

    stack[sp.*] = .{ .raw_at_slot = value_slot };
    sp.* += 1;
    return true;
}

/// Try to emit inline IR for parameterized type element validation.
/// Recognizes the pattern: push_literal(type_val=tv) + call_word("native.typed-validate-and-promote").
/// Returns true if inlined; false to fall back to runtime callback.
fn tryEmitInlineTypedValidateAndPromote(
    state: *CompileState,
    instructions: []const Instruction,
    idx: usize,
    stack: []StackEntry,
    sp: *usize,
) bool {
    if (sp.* < 2) return false;

    // virtual type must be a constant .type_val from the preceding instruction
    const vt: *const VirtualType = if (idx > 0) blk: {
        break :blk switch (instructions[idx - 1].op) {
            .push_literal => |v| switch (v) {
                .type_val => |tv| tv.virtual_type orelse return false,
                else => return false,
            },
            else => return false,
        };
    } else return false;

    // no type_params means validation is a no-op
    const params = vt.type_params orelse {
        sp.* -= 1;
        return true;
    };
    if (params.len == 0) {
        sp.* -= 1;
        return true;
    }

    const expected_name = params[0].name;

    const value_entry = stack[sp.* - 2];

    // statically known type on the abstract stack can be resolved at compile time
    switch (value_entry) {
        .i64_ref => {
            if (std.mem.eql(u8, expected_name, "fixnum")) {
                sp.* -= 1;
                return true;
            }
            return false;
        },
        .f64_ref => {
            if (std.mem.eql(u8, expected_name, "float")) {
                sp.* -= 1;
                return true;
            }
            return false;
        },
        .bool_ref => {
            if (std.mem.eql(u8, expected_name, "boolean")) {
                sp.* -= 1;
                return true;
            }
            return false;
        },
        .raw_at_slot => {},
        .quotation_body, .row_region => return false,
    }

    const expected_tag_const = mapTypeNameToTagConst(state, expected_name) orelse return false;

    const value_slot: usize = value_entry.slotIndex().?;

    sp.* -= 2;

    const ctx = state.ctx;
    const base_addr = state.base_addr;

    const elem_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, value_slot * ValueLayout.value_size));
    if (state.type_mismatch_error_fn != c.IR_UNUSED) {
        emitTagCheckOrError(state, elem_addr, expected_tag_const, state.type_mismatch_error_fn);
    } else {
        emitTagCheck(ctx, elem_addr, expected_tag_const, state.tag_offset_const, state.bail_status);
    }

    stack[sp.*] = .{ .raw_at_slot = value_slot };
    sp.* += 1;
    return true;
}

/// Try to emit inline IR for struct field access.
///
/// Attempts to recognize the pattern:
///
///     push_literal(.struct_type)
///     push_literal(.fixnum=idx)
///     call_word("native.struct-field-get")
///
/// Returns true if inlined; or false to fall back to runtime callback.
///
/// JIT-only: bakes a freeze-time `StructType` pointer constant for the expected-type check. AOT must
/// use the native callback, because its runtime image holds an independently-allocated descriptor.
/// The callsite gate in the dispatch loop enforces this.
fn tryEmitInlineStructFieldGet(
    state: *CompileState,
    instructions: []const Instruction,
    idx: usize,
    stack: []StackEntry,
    sp: *usize,
) bool {
    if (sp.* < 3) return false;
    if (idx < 2) return false;

    // struct_type pointer must be a const from two instructions back
    const struct_type_ptr: *const StructType = switch (instructions[idx - 2].op) {
        .push_literal => |v| if (v == .struct_type) v.struct_type else return false,
        else => return false,
    };

    // field index must be a const fixnum from the preceding instruction
    const field_index: usize = switch (instructions[idx - 1].op) {
        .push_literal => |v| if (v == .fixnum) @as(usize, @intCast(v.fixnum)) else return false,
        else => return false,
    };

    // the instance must be a raw value on the physical stack
    const instance_slot: usize = switch (stack[sp.* - 3]) {
        .raw_at_slot => |s| s,
        else => return false,
    };

    sp.* -= 3;

    StructInstanceLayout.ensureInit();

    const ctx = state.ctx;
    const base_addr = state.base_addr;

    // check Value at instance_slot must be .struct_instance
    const elem_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, instance_slot * ValueLayout.value_size));
    if (state.type_mismatch_error_fn != c.IR_UNUSED) {
        emitTagCheckOrError(state, elem_addr, state.struct_instance_tag_const, state.type_mismatch_error_fn);
    } else {
        emitTagCheck(ctx, elem_addr, state.struct_instance_tag_const, state.tag_offset_const, state.bail_status);
    }

    // load *StructInstance from Value
    const si_ptr = emitUnboxPtr(ctx, elem_addr, state.payload_offset_const);

    // check si_ptr.struct_type must match expected type
    const type_field_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), si_ptr, c.ir_const_addr(ctx, StructInstanceLayout.struct_type_offset));
    const actual_type = c._ir_LOAD(ctx, c.IR_ADDR, type_field_addr);
    const expected_type = c.ir_const_addr(ctx, @intFromPtr(struct_type_ptr));
    const type_mismatch = c.ir_fold2(ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), actual_type, expected_type);
    const if_mismatch = c._ir_IF(ctx, type_mismatch);
    c._ir_IF_TRUE_cold(ctx, if_mismatch);
    if (state.type_mismatch_error_fn != c.IR_UNUSED) {
        emitErrorReturn(state, state.type_mismatch_error_fn);
    } else {
        c._ir_RETURN(ctx, state.bail_status);
    }
    c._ir_IF_FALSE(ctx, if_mismatch);

    const fields_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), si_ptr, c.ir_const_addr(ctx, StructInstanceLayout.fields_ptr_offset));
    const fields_ptr = c._ir_LOAD(ctx, c.IR_ADDR, fields_ptr_addr);

    // index into fields [fields_ptr + field_index * value_size]
    const field_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), fields_ptr, c.ir_const_addr(ctx, field_index * ValueLayout.value_size));

    emitCopyFromPtr(ctx, base_addr, field_addr, instance_slot);

    stack[sp.*] = .{ .raw_at_slot = instance_slot };
    sp.* += 1;
    return true;
}

/// Try to emit inline IR for struct field assignment.
///
/// Attempts to recognize the pattern:
///
///     push_literal(.struct_type)
///     push_literal(.fixnum=idx)
///     call_word("native.struct-field-set")
///
/// Stack effect: ( instance new-val -- instance ). The struct_type pointer
/// and field index are inline literals from the dispatch body; the runtime
/// helper sees them on the stack as `instance new-val vtype-ptr field-index`
/// and pops all four.
///
/// Bails to the generic dispatch fallback when the struct has typed fields,
/// since runtime type validation isn't inlined here.
///
/// Returns true if inlined; or false to fall back to runtime callback.
///
/// JIT-only: bakes a freeze-time `StructType` pointer constant for the expected-type check. AOT must
/// use the native callback because its runtime image holds an independently-allocated descriptor.
/// Tthe callsite gate in the dispatch loop enforces this.
fn tryEmitInlineStructFieldSet(
    state: *CompileState,
    instructions: []const Instruction,
    idx: usize,
    stack: []StackEntry,
    sp: *usize,
) bool {
    if (sp.* < 4) return false;
    if (idx < 2) return false;

    // struct_type pointer must be a const from two instructions back
    const struct_type_ptr: *const StructType = switch (instructions[idx - 2].op) {
        .push_literal => |v| if (v == .struct_type) v.struct_type else return false,
        else => return false,
    };

    // field index must be a const fixnum from the preceding instruction
    const field_index: usize = switch (instructions[idx - 1].op) {
        .push_literal => |v| if (v == .fixnum) @as(usize, @intCast(v.fixnum)) else return false,
        else => return false,
    };

    // Typed fields require a runtime type check the inline path doesn't emit.
    if (struct_type_ptr.field_types.len != 0) return false;

    // Flush all four call inputs (instance, new_val, vtype-ptr literal,
    // field-index literal) to physical slots so they're addressable as
    // raw bytes for the field copy. After flush every entry [0..sp) is a
    // raw_at_slot indexing its own position; row_region cannot reach this
    // path because the dispatch site already gates it.
    materializeQuotations(state, stack, sp.*, false) catch return false;
    flushToPhysicalStack(state, stack, sp.*);

    const instance_slot = sp.* - 4;
    const new_val_slot = sp.* - 3;

    sp.* -= 4;

    StructInstanceLayout.ensureInit();

    const ctx = state.ctx;
    const base_addr = state.base_addr;

    // check Value at instance_slot must be .struct_instance
    const elem_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, instance_slot * ValueLayout.value_size));
    if (state.type_mismatch_error_fn != c.IR_UNUSED) {
        emitTagCheckOrError(state, elem_addr, state.struct_instance_tag_const, state.type_mismatch_error_fn);
    } else {
        emitTagCheck(ctx, elem_addr, state.struct_instance_tag_const, state.tag_offset_const, state.bail_status);
    }

    // load *StructInstance from Value
    const si_ptr = emitUnboxPtr(ctx, elem_addr, state.payload_offset_const);

    // check si_ptr.struct_type must match expected type
    const type_field_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), si_ptr, c.ir_const_addr(ctx, StructInstanceLayout.struct_type_offset));
    const actual_type = c._ir_LOAD(ctx, c.IR_ADDR, type_field_addr);
    const expected_type = c.ir_const_addr(ctx, @intFromPtr(struct_type_ptr));
    const type_mismatch = c.ir_fold2(ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), actual_type, expected_type);
    const if_mismatch = c._ir_IF(ctx, type_mismatch);
    c._ir_IF_TRUE_cold(ctx, if_mismatch);
    if (state.type_mismatch_error_fn != c.IR_UNUSED) {
        emitErrorReturn(state, state.type_mismatch_error_fn);
    } else {
        c._ir_RETURN(ctx, state.bail_status);
    }
    c._ir_IF_FALSE(ctx, if_mismatch);

    const fields_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), si_ptr, c.ir_const_addr(ctx, StructInstanceLayout.fields_ptr_offset));
    const fields_ptr = c._ir_LOAD(ctx, c.IR_ADDR, fields_ptr_addr);

    // index into fields [fields_ptr + field_index * value_size]
    const field_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), fields_ptr, c.ir_const_addr(ctx, field_index * ValueLayout.value_size));

    // copy new_val from stack into struct field
    emitCopyToPtr(ctx, base_addr, new_val_slot, field_addr);

    // instance remains as the output (its slot is unchanged)
    stack[sp.*] = .{ .raw_at_slot = instance_slot };
    sp.* += 1;
    return true;
}

/// Emit the body of the `choose` built-in when compiled as a standalone word.
/// All three parameters (a1, a2, quot) are raw_at_slot entries.
/// choose: ( a1 a2 quot -- a )
fn emitChooseBuiltin(
    state: *CompileState,
    stack: []StackEntry,
    sp: *usize,
) IrCodegenError!void {
    const ctx = state.ctx;
    const base_addr = state.base_addr;

    // a1 @ slot 0, a2 @ slot 1, quot @ slot 2
    const a1_slot: usize = 0;
    const a2_slot: usize = 1;
    const quot_slot: usize = 2;
    const output_slot: usize = 0;

    // Load code_ptr from quotation before rearranging.
    const quot_byte_offset = c.ir_const_addr(ctx, quot_slot * ValueLayout.value_size);
    const quot_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, quot_byte_offset);
    const quotation_tag_const = emitTagConst(ctx, .quotation);
    emitTagCheck(ctx, quot_addr, quotation_tag_const, state.tag_offset_const, state.bail_status);
    const code_ptr_off = c.ir_const_addr(ctx, ValueLayout.quotation_code_ptr_offset);
    const code_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), quot_addr, code_ptr_off);
    const code_ptr_val = c._ir_LOAD(ctx, c.IR_ADDR, code_ptr_addr);

    // Copy a1 to slot 2, a2 to slot 3 (quotation consumption copies). The
    // copies are owning references the predicate consumes and releases, so
    // retain each to balance that release.
    emitCopySlot(ctx, base_addr, a1_slot, 2);
    emitRetainSlot(state, 2);
    emitCopySlot(ctx, base_addr, a2_slot, 3);
    emitRetainSlot(state, 3);
    // Copy quotation to slot 4 (for interpreter fallback).
    emitCopySlot(ctx, base_addr, quot_slot, 4);

    sp.* = 4;
    if (sp.* + 1 > state.peak_sp) state.peak_sp = @intCast(sp.* + 1);

    // Null-check code_ptr for compiled vs interpreter dispatch.
    const null_addr = c.ir_const_addr(ctx, 0);
    const is_null = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), code_ptr_val, null_addr);
    const if_null = c._ir_IF(ctx, is_null);

    // Cold path: interpreter fallback expects quotation on top.
    c._ir_IF_TRUE_cold(ctx, if_null);
    {
        const fb_sp: usize = 5;
        const fb_sp_const = c.ir_const_addr(ctx, fb_sp);
        const fb_sp_val = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, fb_sp_const);
        c._ir_STORE(ctx, state.sp_ptr, fb_sp_val);

        const ctx_val = if (state.preloaded_ctx_val != c.IR_UNUSED)
            state.preloaded_ctx_val
        else blk: {
            JitContextLayout.ensureInit();
            const ctx_off = c.ir_const_addr(ctx, JitContextLayout.ctx_offset);
            const ctx_addr2 = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
            break :blk c._ir_LOAD(ctx, c.IR_ADDR, ctx_addr2);
        };
        const call_quot_fn = if (state.aot_mode)
            state.call_quotation_fn
        else
            c.ir_const_addr(ctx, @intFromPtr(&jitCallQuotation));
        state.noteAotFallbackEmission(.quotation, "<choose>", 0, 0);
        const fb_result = c._ir_CALL_1(ctx, c.IR_I32, call_quot_fn, ctx_val);
        emitCallbackPostCheck(state, fb_result, state.error_propagate_status, null, .none);
    }
    const end_fallback = c._ir_END(ctx);

    // Hot path: compiled quotation via code_ptr.
    c._ir_IF_FALSE(ctx, if_null);
    {
        const hot_sp_const = c.ir_const_addr(ctx, sp.*);
        const hot_sp_val = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, hot_sp_const);
        c._ir_STORE(ctx, state.sp_ptr, hot_sp_val);

        const call_result = if (state.aot_mode)
            c._ir_CALL_2(ctx, c.IR_I32, state.call_code_ptr_fn, state.jit_ctx_ptr, code_ptr_val)
        else
            c._ir_CALL_1(ctx, c.IR_I32, code_ptr_val, state.jit_ctx_ptr);
        emitCallbackPostCheck(state, call_result, call_result, null, .none);
    }
    const end_compiled = c._ir_END(ctx);

    c._ir_MERGE_2(ctx, end_fallback, end_compiled);

    if (state.refresh_stack_fn != c.IR_UNUSED) {
        refreshCachedStackPointer(state);
    }

    // Quotation consumed 2 copies, pushed 1 result at slot 2.
    const cond_ref = emitSlotTruthiness(ctx, state.base_addr, output_slot + 2, state);

    const if_ref = c._ir_IF(ctx, cond_ref);

    c._ir_IF_TRUE(ctx, if_ref);
    // a1 already at output_slot; release the non-selected a2.
    emitReleaseSlot(state, output_slot + 1);
    const true_end = c._ir_END(ctx);

    c._ir_IF_FALSE(ctx, if_ref);
    emitReleaseSlot(state, output_slot);
    emitCopySlot(ctx, state.base_addr, output_slot + 1, output_slot);
    const false_end = c._ir_END(ctx);

    c._ir_MERGE_2(ctx, true_end, false_end);

    // Final sp: output_slot + 1
    const final_sp_const = c.ir_const_addr(ctx, output_slot + 1);
    const final_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, final_sp_const);
    c._ir_STORE(ctx, state.sp_ptr, final_sp);

    sp.* = output_slot + 1;
    stack[output_slot] = .{ .raw_at_slot = output_slot };
}

/// How a per-op intrinsic handler tells `compileInstructions` to continue.
///
/// `next` lets the iteration finish through the shared epilogue, which is the normal fall-through.
/// It also stands in for an explicit `continue`, since after the row-fallback paths the epilogue
/// is a noöp.
///
/// `stop` ends compilation of the body, replacing the `break` the row-fallback arms take when no
/// native could be emitted.
const ControlFlow = enum { next, stop };

/// The inputs a per-op intrinsic handler needs at the dispatch boundary.
/// Everything else is reached through `state`.
const EmitCtx = struct {
    state: *CompileState,
    instructions: []const Instruction,
    idx: usize,
    name: []const u8,
    stack: []StackEntry,
    sp: *usize,
    line: usize,
};

/// Static pre-scan capability bits for an intrinsic, mirroring `PreScanFlags`.
///
/// Carried on each table entry so the pre-scan can read an op's requirements from the same source
/// of truth as codegen.
const PreScanCaps = struct {
    needs_safepoint: bool = false,
    needs_error_handling: bool = false,
    needs_dynamic_vars: bool = false,
    needs_iterators: bool = false,
    needs_param_validation: bool = false,
    needs_dispatch: bool = false,
    needs_poly_fallback: bool = false,
    needs_native_call: bool = false,
};

/// One intrinsic's compile-time codegen routine plus its static prescan capabilities. The handler
/// emits IR; the real native address still comes from the `WordResolver` at emit time, not from this table.
const IntrinsicEntry = struct {
    handler: *const fn (EmitCtx) IrCodegenError!ControlFlow,
    caps: PreScanCaps = .{},
    effect: IntrinsicEffect = .none,
};

/// The intrinsic codegen table:
///
///     op name -> emit handler + prescan caps
///
/// The codegen ladder dispatches through this intrinsic table, before its remaining `if`/`else if` arms.
/// Container-scope decls are order-independent, so this may reference handlers defined below.
const intrinsic_table = std.StaticStringMap(IntrinsicEntry).initComptime(.{
    .{ "t", IntrinsicEntry{ .handler = emitIntrinsicTrue, .effect = .{ .fixed = .{ .input_count = 0, .output_count = 1 } } } },
    .{ "f", IntrinsicEntry{ .handler = emitIntrinsicFalse, .effect = .{ .fixed = .{ .input_count = 0, .output_count = 1 } } } },
    .{ "abs", IntrinsicEntry{ .handler = emitIntrinsicAbs, .effect = .{ .fixed = .{ .input_count = 1, .output_count = 1 } } } },
    .{ "dup", IntrinsicEntry{ .handler = emitIntrinsicDup, .effect = .{ .custom = inferEffectDup } } },
    .{ "drop", IntrinsicEntry{ .handler = emitIntrinsicDrop, .effect = .{ .fixed = .{ .input_count = 1, .output_count = 0 } } } },
    .{ "swap", IntrinsicEntry{ .handler = emitIntrinsicSwap, .effect = .{ .custom = inferEffectSwap } } },
    .{ "over", IntrinsicEntry{ .handler = emitIntrinsicOver, .effect = .{ .custom = inferEffectOver } } },
    .{ "if", IntrinsicEntry{ .handler = emitIntrinsicIf, .effect = .{ .custom = inferEffectIf } } },
    .{ "call", IntrinsicEntry{ .handler = emitIntrinsicCall, .effect = .{ .custom = inferEffectCall } } },
    .{ "choose", IntrinsicEntry{ .handler = emitIntrinsicChoose, .effect = .{ .fixed = .{ .input_count = 3, .output_count = 1 } } } },
    .{ "=", IntrinsicEntry{ .handler = emitIntrinsicEq, .caps = .{ .needs_poly_fallback = true }, .effect = .{ .fixed = .{ .input_count = 2, .output_count = 1 } } } },
    .{ "<", IntrinsicEntry{ .handler = emitIntrinsicLt, .caps = .{ .needs_poly_fallback = true }, .effect = .{ .fixed = .{ .input_count = 2, .output_count = 1 } } } },
    .{ ">", IntrinsicEntry{ .handler = emitIntrinsicGt, .caps = .{ .needs_poly_fallback = true }, .effect = .{ .fixed = .{ .input_count = 2, .output_count = 1 } } } },
    .{ "+", IntrinsicEntry{ .handler = emitIntrinsicAdd, .caps = .{ .needs_poly_fallback = true }, .effect = .{ .fixed = .{ .input_count = 2, .output_count = 1 } } } },
    .{ "-", IntrinsicEntry{ .handler = emitIntrinsicSub, .caps = .{ .needs_poly_fallback = true }, .effect = .{ .fixed = .{ .input_count = 2, .output_count = 1 } } } },
    .{ "*", IntrinsicEntry{ .handler = emitIntrinsicMul, .caps = .{ .needs_poly_fallback = true }, .effect = .{ .fixed = .{ .input_count = 2, .output_count = 1 } } } },
    .{ "/", IntrinsicEntry{ .handler = emitIntrinsicDiv, .caps = .{ .needs_poly_fallback = true }, .effect = .{ .fixed = .{ .input_count = 2, .output_count = 1 } } } },
    .{ "%", IntrinsicEntry{ .handler = emitIntrinsicMod, .caps = .{ .needs_poly_fallback = true }, .effect = .{ .fixed = .{ .input_count = 2, .output_count = 1 } } } },
    .{ "div", IntrinsicEntry{ .handler = emitIntrinsicIntDiv, .effect = .{ .fixed = .{ .input_count = 2, .output_count = 1 } } } },
    .{ "rem", IntrinsicEntry{ .handler = emitIntrinsicRem, .effect = .{ .fixed = .{ .input_count = 2, .output_count = 1 } } } },
    .{ "pick-n", IntrinsicEntry{ .handler = emitIntrinsicPickN, .caps = .{ .needs_native_call = true } } },
    .{ "<rot-n", IntrinsicEntry{ .handler = emitIntrinsicRotNUp, .caps = .{ .needs_native_call = true } } },
    .{ "rot-n>", IntrinsicEntry{ .handler = emitIntrinsicRotNDown, .caps = .{ .needs_native_call = true } } },
    .{ "nip-n", IntrinsicEntry{ .handler = emitIntrinsicNipN, .caps = .{ .needs_native_call = true } } },
    .{ "drop-n", IntrinsicEntry{ .handler = emitIntrinsicDropN, .caps = .{ .needs_native_call = true } } },
    .{ "array-n", IntrinsicEntry{ .handler = emitIntrinsicArrayN, .caps = .{ .needs_native_call = true } } },
    .{ "times", IntrinsicEntry{ .handler = emitIntrinsicTimes, .caps = .{ .needs_safepoint = true } } },
    .{ "loop", IntrinsicEntry{ .handler = emitIntrinsicLoop, .caps = .{ .needs_safepoint = true } } },
    .{ "while", IntrinsicEntry{ .handler = emitIntrinsicWhile, .caps = .{ .needs_safepoint = true } } },
    .{ "until", IntrinsicEntry{ .handler = emitIntrinsicUntil, .caps = .{ .needs_safepoint = true } } },
    .{ "recover", IntrinsicEntry{ .handler = emitIntrinsicRecover, .caps = .{ .needs_error_handling = true } } },
    .{ "cleanup", IntrinsicEntry{ .handler = emitIntrinsicCleanup, .caps = .{ .needs_error_handling = true } } },
    .{ "get", IntrinsicEntry{ .handler = emitIntrinsicGet, .caps = .{ .needs_dynamic_vars = true } } },
    .{ "with-parameter", IntrinsicEntry{ .handler = emitIntrinsicWithParameter, .caps = .{ .needs_dynamic_vars = true } } },
    .{ "#next", IntrinsicEntry{ .handler = emitIntrinsicIterNext, .caps = .{ .needs_iterators = true } } },
    .{ "#collect", IntrinsicEntry{ .handler = emitIntrinsicIterCollect, .caps = .{ .needs_iterators = true } } },
    .{ "#count", IntrinsicEntry{ .handler = emitIntrinsicIterCount, .caps = .{ .needs_iterators = true } } },
    .{ "close-iterator", IntrinsicEntry{ .handler = emitIntrinsicCloseIterator, .caps = .{ .needs_iterators = true } } },
    .{ "#take", IntrinsicEntry{ .handler = emitIntrinsicIterTake, .caps = .{ .needs_iterators = true } } },
    .{ "#drop", IntrinsicEntry{ .handler = emitIntrinsicIterDrop, .caps = .{ .needs_iterators = true } } },
    .{ "#each", IntrinsicEntry{ .handler = emitIntrinsicIterEach, .caps = .{ .needs_iterators = true, .needs_param_validation = true } } },
    .{ "#map", IntrinsicEntry{ .handler = emitIntrinsicIterMap, .caps = .{ .needs_iterators = true, .needs_param_validation = true } } },
    .{ "#filter", IntrinsicEntry{ .handler = emitIntrinsicIterFilter, .caps = .{ .needs_iterators = true, .needs_param_validation = true } } },
    .{ "#reduce", IntrinsicEntry{ .handler = emitIntrinsicIterReduce, .caps = .{ .needs_iterators = true, .needs_param_validation = true } } },
    .{ "native.make-struct-instance", IntrinsicEntry{ .handler = emitIntrinsicMakeStructInstance, .caps = .{ .needs_dispatch = true } } },
    .{ "native.struct-instance-destructure", IntrinsicEntry{ .handler = emitIntrinsicStructInstanceDestructure, .caps = .{ .needs_dispatch = true } } },
    .{ "native.virtual-struct-wrap", IntrinsicEntry{ .handler = emitIntrinsicVirtualStructWrap, .caps = .{ .needs_dispatch = true } } },
    .{ "native.virtual-struct-unwrap", IntrinsicEntry{ .handler = emitIntrinsicVirtualStructUnwrap, .caps = .{ .needs_dispatch = true } } },
    .{ "native.virtual-unwrap", IntrinsicEntry{ .handler = emitIntrinsicVirtualUnwrap } },
    .{ "native.struct-field-get", IntrinsicEntry{ .handler = emitIntrinsicStructFieldGet } },
    .{ "native.struct-field-set", IntrinsicEntry{ .handler = emitIntrinsicStructFieldSet } },
    .{ "native.typed-validate-and-promote", IntrinsicEntry{ .handler = emitIntrinsicTypedValidateAndPromote } },
    .{ "native.struct-instance-to-hash", IntrinsicEntry{ .handler = emitIntrinsicStructInstanceToHash, .caps = .{ .needs_dispatch = true } } },
    .{ "native.struct-type-predicate", IntrinsicEntry{ .handler = emitIntrinsicStructTypePredicate, .caps = .{ .needs_dispatch = true } } },
    .{ "native.hash-to-struct", IntrinsicEntry{ .handler = emitIntrinsicHashToStruct, .caps = .{ .needs_dispatch = true } } },
});

fn emitIntrinsicTrue(ec: EmitCtx) IrCodegenError!ControlFlow {
    ec.stack[ec.sp.*] = .{ .bool_ref = c.ir_const_bool(ec.state.ctx, true) };
    ec.sp.* += 1;
    return .next;
}

fn emitIntrinsicFalse(ec: EmitCtx) IrCodegenError!ControlFlow {
    ec.stack[ec.sp.*] = .{ .bool_ref = c.ir_const_bool(ec.state.ctx, false) };
    ec.sp.* += 1;
    return .next;
}

fn emitIntrinsicAbs(ec: EmitCtx) IrCodegenError!ControlFlow {
    const state = ec.state;
    const stack = ec.stack;
    const sp = ec.sp;
    const ctx = state.ctx;
    const bail_status = state.bail_status;

    if (sp.* < 1) return IrCodegenError.StackUnderflow;
    sp.* -= 1;
    const entry = stack[sp.*];

    if (entry == .f64_ref) {
        const a = entry.f64_ref;
        const zero = c.ir_const_double(ctx, 0.0);
        const is_neg = c.ir_fold2(ctx, c.IR_OPT(c.IR_LT, c.IR_BOOL), a, zero);
        const neg_a = c.ir_fold1(ctx, c.IR_OPT(c.IR_NEG, c.IR_DOUBLE), a);
        const if_neg = c._ir_IF(ctx, is_neg);
        c._ir_IF_TRUE(ctx, if_neg);
        const end_true = c._ir_END(ctx);
        c._ir_IF_FALSE(ctx, if_neg);
        const end_false = c._ir_END(ctx);
        c._ir_MERGE_2(ctx, end_true, end_false);
        const result = c._ir_PHI_2(ctx, c.IR_DOUBLE, neg_a, a);
        stack[sp.*] = .{ .f64_ref = result };
    } else {
        const a = try requireI64(entry, state);

        const min_val = c.ir_const_i64(ctx, std.math.minInt(i64));
        const is_min = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), a, min_val);
        const if_min = c._ir_IF(ctx, is_min);
        c._ir_IF_TRUE_cold(ctx, if_min);
        if (state.overflow_error_fn != c.IR_UNUSED) {
            emitErrorReturn(state, state.overflow_error_fn);
        } else {
            c._ir_RETURN(ctx, bail_status);
        }
        c._ir_IF_FALSE(ctx, if_min);

        const zero = c.ir_const_i64(ctx, 0);
        const is_neg = c.ir_fold2(ctx, c.IR_OPT(c.IR_LT, c.IR_BOOL), a, zero);
        const neg_a = c.ir_fold1(ctx, c.IR_OPT(c.IR_NEG, c.IR_I64), a);
        const if_neg = c._ir_IF(ctx, is_neg);
        c._ir_IF_TRUE(ctx, if_neg);
        const end_true = c._ir_END(ctx);
        c._ir_IF_FALSE(ctx, if_neg);
        const end_false = c._ir_END(ctx);
        c._ir_MERGE_2(ctx, end_true, end_false);
        const result = c._ir_PHI_2(ctx, c.IR_I64, neg_a, a);
        stack[sp.*] = .{ .i64_ref = result };
    }
    sp.* += 1;
    return .next;
}

fn emitIntrinsicDup(ec: EmitCtx) IrCodegenError!ControlFlow {
    const state = ec.state;
    const stack = ec.stack;
    const sp = ec.sp;
    if (sp.* < 1) {
        if (state.aot_mode) {
            if (try emitInlineRowUnderflow(state, stack, sp, ec.name, ec.line)) return .next;
            return .stop;
        }
        return IrCodegenError.StackUnderflow;
    }
    if (state.aot_mode and stack[sp.* - 1] == .row_region) {
        if (try emitInlineRowUnderflow(state, stack, sp, ec.name, ec.line)) return .next;
        return .stop;
    }
    stack[sp.*] = try cloneStackEntry(state, state.base_addr, stack[sp.* - 1], sp.*);
    sp.* += 1;
    return .next;
}

fn emitIntrinsicDrop(ec: EmitCtx) IrCodegenError!ControlFlow {
    const state = ec.state;
    const stack = ec.stack;
    const sp = ec.sp;
    if (sp.* < 1) return IrCodegenError.StackUnderflow;
    if (stack[sp.* - 1] == .row_region and state.resolver != null) {
        // The row stands for an unknown number of live values and its top is the live physical top.
        // Pop exactly one through the native and keep the row, rather than discarding the whole
        // region, which would leave a following drop with nothing and underflow the word.
        try emitResolvedNativeCallback(state, ec.name, stack, sp, ec.line);
    } else {
        // Discarding an owning slot: release its backing. Scalars tracked as typed refs never alias
        // a backing.
        if (stack[sp.* - 1] == .raw_at_slot) {
            emitReleaseSlot(state, stack[sp.* - 1].raw_at_slot);
        } else if (stack[sp.* - 1] == .row_region) {
            // The row's top is the live physical top, so release it here rather than leaking its
            // backing; the abstract position maps through to that slot.
            emitReleaseSlot(state, sp.* - 1);
        }
        sp.* -= 1;
        // Dropping the top can uncover a lazy-`swap` survivor now stranded at a
        // physical slot >= the new top; reconcile so a following push does not
        // clobber it.
        settleStrandedEntries(state, stack, sp.*);
    }
    return .next;
}

fn emitIntrinsicSwap(ec: EmitCtx) IrCodegenError!ControlFlow {
    const state = ec.state;
    const stack = ec.stack;
    const sp = ec.sp;
    if (sp.* < 2) {
        // Reaches one below the abstract base into the caller row (the `swap drop` shape after a
        // row-collapsing call); emit native swap against the live stack.
        if (state.aot_mode) {
            if (try emitInlineRowUnderflow(state, stack, sp, ec.name, ec.line)) return .next;
            return .stop;
        }
        return IrCodegenError.StackUnderflow;
    }
    const top = stack[sp.* - 1];
    const second = stack[sp.* - 2];
    if (state.aot_mode and (top == .row_region or second == .row_region)) {
        // A swap whose pair touches the row cannot be tracked as an abstract reorder. That would
        // move the row off its pinned slot 0 and desync a later live sp-relative op.
        //
        // Emit the native swap against the live physical stack and collapse to a fresh row pinned
        // at slot 0, the same sp-relative path the indexed ops and the sp<2 swap use.
        if (try emitInlineRowUnderflow(state, stack, sp, ec.name, ec.line)) return .next;
        return .stop;
    }
    // Track swap abstractly without physical modification.
    // flushToPhysicalStack resolves cross-references later.
    stack[sp.* - 2] = top;
    stack[sp.* - 1] = second;
    return .next;
}

fn emitIntrinsicOver(ec: EmitCtx) IrCodegenError!ControlFlow {
    const state = ec.state;
    const stack = ec.stack;
    const sp = ec.sp;
    if (sp.* < 2) {
        if (state.aot_mode) {
            if (try emitInlineRowUnderflow(state, stack, sp, ec.name, ec.line)) return .next;
            return .stop;
        }
        return IrCodegenError.StackUnderflow;
    }
    if (state.aot_mode and (stack[sp.* - 1] == .row_region or stack[sp.* - 2] == .row_region)) {
        // The over source or the top is the row: cloning a
        // concrete value above the row would un-pin it, so emit
        // the native over against the live stack and collapse to
        // a fresh row pinned at slot 0.
        if (try emitInlineRowUnderflow(state, stack, sp, ec.name, ec.line)) return .next;
        return .stop;
    }
    stack[sp.*] = try cloneStackEntry(state, state.base_addr, stack[sp.* - 2], sp.*);
    sp.* += 1;
    return .next;
}

/// The literal a struct-native op derives its arity from sits in the preceding
/// instruction. Fetch it, failing as not-compilable when there is no preceding
/// instruction or it is not a `push_literal`.
fn precedingStructLiteral(ec: EmitCtx) IrCodegenError!Value {
    if (ec.idx < 1) {
        ec.state.not_compilable_reason = .pre_scan_failure;
        return IrCodegenError.NotCompilable;
    }
    return switch (ec.instructions[ec.idx - 1].op) {
        .push_literal => |v| v,
        else => {
            ec.state.not_compilable_reason = .pre_scan_failure;
            return IrCodegenError.NotCompilable;
        },
    };
}

/// Derive the struct type from a plain `.struct_type` literal.
fn structTypeFromStructLiteral(state: *CompileState, v: Value) IrCodegenError!*const StructType {
    if (v != .struct_type) {
        state.not_compilable_reason = .pre_scan_failure;
        return IrCodegenError.NotCompilable;
    }
    return v.struct_type;
}

/// Derive the struct type backing a struct-backed virtual type, from a
/// `.type_val` literal whose `virtual_type.anon_struct` carries the fields.
fn structTypeFromVirtualLiteral(state: *CompileState, v: Value) IrCodegenError!*const StructType {
    if (v != .type_val) {
        state.not_compilable_reason = .pre_scan_failure;
        return IrCodegenError.NotCompilable;
    }
    const vt = v.type_val.virtual_type orelse {
        state.not_compilable_reason = .pre_scan_failure;
        return IrCodegenError.NotCompilable;
    };
    return vt.anon_struct orelse {
        state.not_compilable_reason = .pre_scan_failure;
        return IrCodegenError.NotCompilable;
    };
}

/// The common emit tail shared by the four struct-native handlers: check the
/// stack depth, flush to the physical stack, then dispatch to the polymorphic
/// native through the resolver and settle the abstract stack with the op's
/// concrete in / out counts.
fn emitStructNativeTail(ec: EmitCtx, effective_in: u8, effective_out: u8) IrCodegenError!ControlFlow {
    const state = ec.state;
    const stack = ec.stack;
    const sp = ec.sp;

    if (sp.* < effective_in) return IrCodegenError.StackUnderflow;

    try materializeQuotations(state, stack, sp.*, false);
    flushToPhysicalStack(state, stack, sp.*);
    const ctx_val = emitCallbackPreamble(state, sp.*);

    const res = state.resolver orelse {
        state.not_compilable_reason = .unresolvable_word;
        return IrCodegenError.NotCompilable;
    };
    const resolved = res.resolve(ec.name, res.user_data) orelse {
        state.not_compilable_reason = .unresolvable_word;
        return IrCodegenError.NotCompilable;
    };

    emitNativeWordCall(state, ctx_val, ec.name, resolved, ec.line);

    if (exitFallsThrough(state.exit_kind)) {
        settleRowAwareStack(state, stack, sp, effective_in, effective_out);
    }
    return .next;
}

// make-struct-instance: ( field1..fieldN literal -- instance )
fn emitIntrinsicMakeStructInstance(ec: EmitCtx) IrCodegenError!ControlFlow {
    const v = try precedingStructLiteral(ec);
    const struct_type_ptr = try structTypeFromStructLiteral(ec.state, v);
    const num_fields: u8 = @intCast(struct_type_ptr.fields.len);
    return emitStructNativeTail(ec, num_fields + 1, 1);
}

// struct-instance-destructure: ( instance literal -- field1..fieldN )
fn emitIntrinsicStructInstanceDestructure(ec: EmitCtx) IrCodegenError!ControlFlow {
    const v = try precedingStructLiteral(ec);
    const struct_type_ptr = try structTypeFromStructLiteral(ec.state, v);
    const num_fields: u8 = @intCast(struct_type_ptr.fields.len);
    return emitStructNativeTail(ec, 2, num_fields);
}

// virtual-struct-wrap: ( field1..fieldN literal -- instance )
fn emitIntrinsicVirtualStructWrap(ec: EmitCtx) IrCodegenError!ControlFlow {
    const v = try precedingStructLiteral(ec);
    const struct_type_ptr = try structTypeFromVirtualLiteral(ec.state, v);
    const num_fields: u8 = @intCast(struct_type_ptr.fields.len);
    return emitStructNativeTail(ec, num_fields + 1, 1);
}

// virtual-struct-unwrap: ( instance literal -- field1..fieldN )
fn emitIntrinsicVirtualStructUnwrap(ec: EmitCtx) IrCodegenError!ControlFlow {
    const v = try precedingStructLiteral(ec);
    const struct_type_ptr = try structTypeFromVirtualLiteral(ec.state, v);
    const num_fields: u8 = @intCast(struct_type_ptr.fields.len);
    return emitStructNativeTail(ec, 2, num_fields);
}

// call: ( quot -- ... )   invoke a quotation
fn emitIntrinsicCall(ec: EmitCtx) IrCodegenError!ControlFlow {
    const state = ec.state;
    const ctx = state.ctx;
    const stack = ec.stack;
    const sp = ec.sp;

    if (sp.* < 1) return IrCodegenError.StackUnderflow;
    sp.* -= 1;
    const entry = stack[sp.*];
    switch (entry) {
        .quotation_body => |body| {
            const saved_inline_trace_frame_count = state.inline_trace_frame_count;
            if (traceFramesEnabled(state) and state.inline_trace_frame_count < max_inline_trace_frames) {
                state.inline_trace_frames[state.inline_trace_frame_count] = .{
                    .kind = .call,
                    .line = ec.line,
                };
                state.inline_trace_frame_count += 1;
            }
            try compileInstructions(state, body, stack, sp);
            if (traceFramesEnabled(state)) state.inline_trace_frame_count = saved_inline_trace_frame_count;
        },
        .raw_at_slot => |s| {
            const elem_addr = liveSlotAddr(state, s);

            if (state.aot_mode and state.interpreter_free) {
                // Interpreter-free.
                //
                // Dispatch the value at the slot through a single unified runtime helper.
                // jitCallValue inspects the tag, a quotation calls its code_ptr, and
                // a closure, pushes its captured prefix and calls each base in turn.
                //
                // This subsumes the former tag-check / null-check / cold-trap structure and is
                // the only place a runtime-selected dispatch can encounter a closure.
                //
                // The call arg's entry may be a `.raw_at_slot = s` whose `s` differs from its
                // logical position after a preceding `pick-n` / `swap` (a cross-slot reference).
                //
                // Handing jitCallValue a pointer to slot `s` and then flushing only the remaining
                // stack is unsafe: the flush can overwrite slot `s`, e.g., the swapped-down sibling,
                // before the runtime dereferences the pointer.
                //
                // Materialize the call arg to its natural top slot by including it in the flush,
                // then dispatch on that slot. The by-value path below avoids this because it LOADs
                // the code_ptr into an SSA temp before flushing.
                sp.* += 1;
                flushToPhysicalStack(state, stack, sp.*);
                sp.* -= 1;
                const arg_addr = liveSlotAddr(state, sp.*);

                const new_sp_const = c.ir_const_addr(ctx, sp.*);
                const new_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, new_sp_const);
                c._ir_STORE(ctx, state.sp_ptr, new_sp);

                const call_result = c._ir_CALL_2(ctx, c.IR_I32, state.call_value_fn, state.jit_ctx_ptr, arg_addr);
                emitCallbackPostCheck(state, call_result, call_result, null, .{ .builtin = .{ .kind = .call, .line = ec.line } });
            } else {
                // The slot value may be a compiled quotation, i.e., direct hot-path, an uncompiled
                // quotation, or a closure from curry/compose.
                //
                // Only a compiled quotation takes the direct call. Everything else routes through
                // jit_call_quotation, which runs an uncompiled quot's body and unwraps a closure.
                //
                // A non-quotation tag used to RETURN bail_status, but in AOT auto / runtime-image
                // mode there is no JIT re-run to catch a bail, so a closure surfaced as a hard
                // unknown runtime error.
                const quotation_tag_const = emitTagConst(ctx, .quotation);
                const tag_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, state.tag_offset_const);
                const tag_val = c._ir_LOAD(ctx, ValueLayout.ir_tag_type, tag_addr);
                const is_not_quotation = c.ir_fold2(ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), tag_val, quotation_tag_const);

                // Load code_ptr from the payload.
                //
                // For a non-quotation value this reads within the 40-byte Value and is harmless
                // because the OR below forces the soft path, so the loaded value is never called.
                const code_ptr_off = c.ir_const_addr(ctx, ValueLayout.quotation_code_ptr_offset);
                const code_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, code_ptr_off);
                const code_ptr_val = c._ir_LOAD(ctx, c.IR_ADDR, code_ptr_addr);

                // Take the soft path for an uncompiled quotation (null code_ptr) or any non-
                // quotation / closure.
                //
                // The direct hot-path is reached only when this is a quotation with a real
                // code_ptr, so the call below is always a valid compiled-quotation pointer.
                const null_addr = c.ir_const_addr(ctx, 0);
                const code_ptr_is_null = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), code_ptr_val, null_addr);
                const is_null = c.ir_fold2(ctx, c.IR_OPT(c.IR_OR, c.IR_BOOL), code_ptr_is_null, is_not_quotation);
                const if_null = c._ir_IF(ctx, is_null);

                // Both branches flush the pending abstract stack
                // to physical memory, but flushToPhysicalStack
                // mutates the shared `stack`/`sp` state, resetting
                // each entry to physical identity. The cold branch
                // is emitted first, so its flush would leave the
                // hot branch flushing an already-identity stack --
                // a silent no-op that drops the physical
                // rearrangement the direct call needs (e.g. a
                // preceding `pick-n swap` that left a cross-slot
                // reference). Snapshot here and restore before the
                // hot branch's flush so each branch flushes from
                // the same pre-flush state. The cold branch's
                // `sp += 1` widens the flush by one slot, so the
                // snapshot covers `sp + 1` entries. The cold
                // branch's callback also refreshes the cached
                // items_ptr / base_addr to refs defined inside the
                // cold block, which do not dominate the hot block;
                // restore those too so the hot branch's flush moves
                // are anchored to a dominating base.
                const snapshot_len = @min(sp.* + 1, stack.len);
                var saved_stack: [max_abstract_stack_depth]StackEntry = undefined;
                @memcpy(saved_stack[0..snapshot_len], stack[0..snapshot_len]);
                const saved_sp = sp.*;
                const saved_items_ptr = state.items_ptr;
                const saved_base_addr = state.base_addr;

                // Cold path: interpreter fallback for quotations
                // without a code_ptr (e.g., >quotation-constructed).
                c._ir_IF_TRUE_cold(ctx, if_null);
                {
                    sp.* += 1;
                    flushToPhysicalStack(state, stack, sp.*);
                    const ctx_val = emitCallbackPreamble(state, sp.*);
                    sp.* -= 1;
                    const call_quot_fn = if (state.aot_mode)
                        state.call_quotation_fn
                    else
                        c.ir_const_addr(ctx, @intFromPtr(&jitCallQuotation));
                    state.noteAotFallbackEmission(.quotation, "<quotation>", 0, ec.line);
                    const fb_result = c._ir_CALL_1(ctx, c.IR_I32, call_quot_fn, ctx_val);
                    emitCallbackPostCheck(state, fb_result, state.error_propagate_status, null, .{ .builtin = .{ .kind = .call, .line = ec.line } });
                }
                const end_fallback = c._ir_END(ctx);

                // Hot path: quotation is compiled, call directly
                c._ir_IF_FALSE(ctx, if_null);
                {
                    @memcpy(stack[0..snapshot_len], saved_stack[0..snapshot_len]);
                    sp.* = saved_sp;
                    state.items_ptr = saved_items_ptr;
                    state.base_addr = saved_base_addr;
                    flushToPhysicalStack(state, stack, sp.*);

                    const new_sp_const = c.ir_const_addr(ctx, sp.*);
                    const new_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, new_sp_const);
                    c._ir_STORE(ctx, state.sp_ptr, new_sp);

                    const call_result = if (state.aot_mode)
                        c._ir_CALL_2(ctx, c.IR_I32, state.call_code_ptr_fn, state.jit_ctx_ptr, code_ptr_val)
                    else
                        c._ir_CALL_1(ctx, c.IR_I32, code_ptr_val, state.jit_ctx_ptr);
                    emitCallbackPostCheck(state, call_result, call_result, null, .{ .builtin = .{ .kind = .call, .line = ec.line } });
                }
                const end_compiled = c._ir_END(ctx);

                c._ir_MERGE_2(ctx, end_fallback, end_compiled);

                if (state.refresh_stack_fn != c.IR_UNUSED) {
                    refreshCachedStackPointer(state);
                }
            }

            if (state.quotation_slots.findSlot(s)) |info| {
                // Concrete effect known: apply it to the abstract stack
                // and continue compilation.
                if (sp.* < info.input_count) return IrCodegenError.StackUnderflow;
                sp.* = sp.* - info.input_count + info.output_count;
                resetStackToPhysical(stack, sp.*);
            } else {
                // Unresolved quotation effect (row variables).
                // Reload physical sp and insert row_region so
                // subsequent instructions above the region can
                // continue compiling. Interpreter-free builds reach
                // here too: the dispatch above emits a defined trap on
                // a null code_ptr instead of an interpreter fallback,
                // so the runtime-depth row-rebase is legal with no
                // absent interpreter to re-enter.
                reloadBaseAfterDynamicCall(state);
                sp.* = 1;
                stack[0] = .{ .row_region = state.nextRowId() };
            }
        },
        .row_region => {
            // Runtime-selected quotation dispatch over a symbolic row.
            //
            // The value to call is the live physical top, but its abstract slot is opaque, since
            // the row models an unknown-depth region. There's no static slot to load a code_ptr
            // from and thus no compiled hot-path.
            if (state.aot_mode and state.interpreter_free) {
                // Interpreter-free dispatch of the live runtime top.
                //
                // The row arm is reached only when the popped top is the row itself, which the
                // reaches-row collapse leaves at physical slot base_idx (the last
                // reloadBaseAfterDynamicCall set base_idx = live_sp - 1 and nothing was pushed
                // since), so base_addr already points at the value to call. Mirror the
                // .raw_at_slot interpreter-free path with sp.* == 0: dispatch the value at
                // liveSlotAddr(state, 0) through jitCallValue (which calls a quotation's code_ptr,
                // runs a closure's segments, or traps cleanly on a null code_ptr -- no interpreter
                // re-entry), logically popping it by storing sp_ptr = base_idx + 0.
                const arg_addr = liveSlotAddr(state, 0);
                c._ir_STORE(ctx, state.sp_ptr, state.base_idx);
                const call_result = c._ir_CALL_2(ctx, c.IR_I32, state.call_value_fn, state.jit_ctx_ptr, arg_addr);
                emitCallbackPostCheck(state, call_result, call_result, null, .{ .builtin = .{ .kind = .call, .line = ec.line } });
                reloadBaseAfterDynamicCall(state);
                sp.* = 1;
                stack[0] = .{ .row_region = state.nextRowId() };
                return .next;
            }

            // Soft-dispatch the live top through the interpreter, mirroring the .raw_at_slot
            // cold path: jitCallQuotation pops the live top and runs it whether or not it was
            // compiled.
            //
            // sp.* is 0 here, representing the row was the popped top. The +1/-1 widens the flush
            // and stores sp_ptr just past the quotation at the live top. Afterward the region
            // stays opaque reëstablish a fresh row exactly as the unresolved-effect branch does.
            sp.* += 1;
            flushToPhysicalStack(state, stack, sp.*);
            const ctx_val = emitCallbackPreamble(state, sp.*);
            sp.* -= 1;
            const call_quot_fn = if (state.aot_mode)
                state.call_quotation_fn
            else
                c.ir_const_addr(ctx, @intFromPtr(&jitCallQuotation));
            state.noteAotFallbackEmission(.quotation, "<quotation>", 0, ec.line);
            const fb_result = c._ir_CALL_1(ctx, c.IR_I32, call_quot_fn, ctx_val);
            emitCallbackPostCheck(state, fb_result, state.error_propagate_status, null, .{ .builtin = .{ .kind = .call, .line = ec.line } });
            reloadBaseAfterDynamicCall(state);
            sp.* = 1;
            stack[0] = .{ .row_region = state.nextRowId() };
        },
        .i64_ref, .f64_ref, .bool_ref => {
            state.not_compilable_reason = .quotation_reification;
            return IrCodegenError.NotCompilable;
        },
    }
    return .next;
}

// choose: ( a1 a2 quot -- a )   keep a1 if quot(a1,a2) is truthy, else a2
fn emitIntrinsicChoose(ec: EmitCtx) IrCodegenError!ControlFlow {
    const state = ec.state;
    const ctx = state.ctx;
    const bail_status = state.bail_status;
    const stack = ec.stack;
    const sp = ec.sp;

    // Duplicate a1 and a2, call quot on the copies,
    // then branch: truthy keeps a1, falsy keeps a2.
    if (sp.* < 3) return IrCodegenError.StackUnderflow;
    sp.* -= 3;
    const output_slot = sp.*;
    const entry_a1 = stack[output_slot];
    const entry_a2 = stack[output_slot + 1];
    const entry_quot = stack[output_slot + 2];

    switch (entry_quot) {
        .quotation_body => |body| {
            // Flush a1/a2 to physical slots so they survive
            // the quotation body compilation.
            stack[output_slot] = entry_a1;
            stack[output_slot + 1] = entry_a2;
            sp.* = output_slot + 2;
            flushToPhysicalStack(state, stack, sp.*);

            // Copy a1/a2 for quotation consumption. The copies
            // are owning references the predicate consumes and
            // releases, so retain each to balance that release.
            emitCopySlot(ctx, state.base_addr, output_slot, output_slot + 2);
            emitRetainSlot(state, output_slot + 2);
            emitCopySlot(ctx, state.base_addr, output_slot + 1, output_slot + 3);
            emitRetainSlot(state, output_slot + 3);
            stack[output_slot + 2] = .{ .raw_at_slot = output_slot + 2 };
            stack[output_slot + 3] = .{ .raw_at_slot = output_slot + 3 };
            sp.* = output_slot + 4;
            if (sp.* > state.peak_sp) state.peak_sp = @intCast(sp.*);

            // Compile the quotation body: consumes 2, pushes 1.
            try compileInstructions(state, body, stack, sp);
            if (sp.* != output_slot + 3) return IrCodegenError.StackShapeMismatch;

            // Pop the result and compute truthiness.
            sp.* -= 1;
            const result_entry = stack[sp.*];
            const cond_ref = try emitTruthiness(state, result_entry, state.base_addr);

            // Branch: truthy keeps a1, falsy keeps a2. The
            // non-selected operand is dropped, so release it.
            const if_ref = c._ir_IF(ctx, cond_ref);

            c._ir_IF_TRUE(ctx, if_ref);
            emitReleaseSlot(state, output_slot + 1);
            const true_end = c._ir_END(ctx);

            c._ir_IF_FALSE(ctx, if_ref);
            emitReleaseSlot(state, output_slot);
            emitCopySlot(ctx, state.base_addr, output_slot + 1, output_slot);
            const false_end = c._ir_END(ctx);

            c._ir_MERGE_2(ctx, true_end, false_end);

            sp.* = output_slot + 1;
            stack[output_slot] = .{ .raw_at_slot = output_slot };
        },
        .raw_at_slot => |quot_slot| {
            // Dynamic quotation: load code_ptr before rearranging.
            const quot_addr = liveSlotAddr(state, quot_slot);

            // Tag-check: must be a quotation.
            const quotation_tag_const = emitTagConst(ctx, .quotation);
            emitTagCheck(ctx, quot_addr, quotation_tag_const, state.tag_offset_const, bail_status);

            // Load code_ptr from the quotation payload.
            const code_ptr_off = c.ir_const_addr(ctx, ValueLayout.quotation_code_ptr_offset);
            const code_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), quot_addr, code_ptr_off);
            const code_ptr_val = c._ir_LOAD(ctx, c.IR_ADDR, code_ptr_addr);

            // Flush a1/a2 to their physical slots.
            stack[output_slot] = entry_a1;
            stack[output_slot + 1] = entry_a2;
            sp.* = output_slot + 2;
            flushToPhysicalStack(state, stack, sp.*);

            // Copy a1/a2 for quotation consumption. The copies
            // are owning references the predicate consumes and
            // releases, so retain each to balance that release.
            emitCopySlot(ctx, state.base_addr, output_slot, output_slot + 2);
            emitRetainSlot(state, output_slot + 2);
            emitCopySlot(ctx, state.base_addr, output_slot + 1, output_slot + 3);
            emitRetainSlot(state, output_slot + 3);
            // Copy quotation to slot after the copies (a
            // quotation carries no refcounted backing).
            emitCopySlot(ctx, state.base_addr, quot_slot, output_slot + 4);

            sp.* = output_slot + 4;
            if (sp.* + 1 > state.peak_sp) state.peak_sp = @intCast(sp.* + 1);

            // Null-check code_ptr for compiled vs interpreter dispatch.
            const null_addr = c.ir_const_addr(ctx, 0);
            const is_null = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), code_ptr_val, null_addr);
            const if_null = c._ir_IF(ctx, is_null);

            // Cold path: interpreter fallback.
            c._ir_IF_TRUE_cold(ctx, if_null);
            {
                // Interpreter expects quotation on top of stack.
                const fb_sp = output_slot + 5;
                const fb_sp_const = c.ir_const_addr(ctx, fb_sp);
                const fb_sp_val = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, fb_sp_const);
                c._ir_STORE(ctx, state.sp_ptr, fb_sp_val);

                const ctx_val = if (state.preloaded_ctx_val != c.IR_UNUSED)
                    state.preloaded_ctx_val
                else blk: {
                    JitContextLayout.ensureInit();
                    const ctx_off = c.ir_const_addr(ctx, JitContextLayout.ctx_offset);
                    const ctx_addr2 = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
                    break :blk c._ir_LOAD(ctx, c.IR_ADDR, ctx_addr2);
                };
                const call_quot_fn = if (state.aot_mode)
                    state.call_quotation_fn
                else
                    c.ir_const_addr(ctx, @intFromPtr(&jitCallQuotation));
                state.noteAotFallbackEmission(.quotation, "<quotation>", 0, ec.line);
                const fb_result = c._ir_CALL_1(ctx, c.IR_I32, call_quot_fn, ctx_val);
                emitCallbackPostCheck(state, fb_result, state.error_propagate_status, null, .none);
            }
            const end_fallback = c._ir_END(ctx);

            // Hot path: compiled quotation via code_ptr.
            c._ir_IF_FALSE(ctx, if_null);
            {
                // sp points past the copies (no quotation on stack).
                const hot_sp_const = c.ir_const_addr(ctx, sp.*);
                const hot_sp_val = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, hot_sp_const);
                c._ir_STORE(ctx, state.sp_ptr, hot_sp_val);

                const call_result = if (state.aot_mode)
                    c._ir_CALL_2(ctx, c.IR_I32, state.call_code_ptr_fn, state.jit_ctx_ptr, code_ptr_val)
                else
                    c._ir_CALL_1(ctx, c.IR_I32, code_ptr_val, state.jit_ctx_ptr);
                emitCallbackPostCheck(state, call_result, call_result, null, .none);
            }
            const end_compiled = c._ir_END(ctx);

            c._ir_MERGE_2(ctx, end_fallback, end_compiled);

            if (state.refresh_stack_fn != c.IR_UNUSED) {
                refreshCachedStackPointer(state);
            }

            // Quotation consumed 2 copies and pushed 1 result.
            // Result is at physical slot output_slot + 2.
            const cond_ref = emitSlotTruthiness(ctx, state.base_addr, output_slot + 2, state);

            const if_ref = c._ir_IF(ctx, cond_ref);

            c._ir_IF_TRUE(ctx, if_ref);
            emitReleaseSlot(state, output_slot + 1);
            const true_end = c._ir_END(ctx);

            c._ir_IF_FALSE(ctx, if_ref);
            emitReleaseSlot(state, output_slot);
            emitCopySlot(ctx, state.base_addr, output_slot + 1, output_slot);
            const false_end = c._ir_END(ctx);

            c._ir_MERGE_2(ctx, true_end, false_end);

            // Write final sp.
            const final_sp_const = c.ir_const_addr(ctx, output_slot + 1);
            const final_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, final_sp_const);
            c._ir_STORE(ctx, state.sp_ptr, final_sp);

            sp.* = output_slot + 1;
            stack[output_slot] = .{ .raw_at_slot = output_slot };
        },
        else => {
            state.not_compilable_reason = .quotation_reification;
            return IrCodegenError.NotCompilable;
        },
    }
    return .next;
}

/// Inline ops admitted inside an `if` arm that the branchless `IR_COND`
/// merge select may evaluate unconditionally. Every entry is a pure
/// intrinsic that lowers to straight-line value folds or an abstract
/// stack reorder. `+ - *` are included even though their i64 path emits
/// an overflow guard and a raw operand a tag-check guard: both are pure
/// deopts the `ir` backend folds away when a trial arm is discarded, so
/// evaluating a non-taken arm costs at most a spurious guard. `nip` is
/// deliberately absent: it is a prelude word, not an intrinsic, so
/// compiling it flushes the abstract stack to physical slots -- stores
/// into the escaping stack array the backend cannot fold away, which
/// corrupts the fallback path when a trial arm is discarded. The trapping
/// division family (`/ % div rem`), all control flow, and every other
/// word are excluded.
const branchless_arm_ops = std.StaticStringMap(void).initComptime(.{
    .{ "+", {} },
    .{ "-", {} },
    .{ "*", {} },
    .{ "<", {} },
    .{ ">", {} },
    .{ "=", {} },
    .{ "dup", {} },
    .{ "drop", {} },
    .{ "swap", {} },
    .{ "over", {} },
});

/// Shuffle subset of `branchless_arm_ops`. On an unboxed scalar operand each
/// is pure (`dup`/`over` share the ref, `drop` is a no-op, `swap` reorders
/// abstractly), but on a `raw_at_slot` or row operand they instead emit a
/// copy + retain, a release, or a row callback -- side effects the backend
/// cannot fold away from a discarded trial. A shuffle-bearing arm therefore
/// takes the fast path only when every entry it touches is a scalar ref; a
/// pure literal/arithmetic/comparison arm needs no such restriction, which is
/// what lets the fast path fire inside a compiled loop where operands are raw.
const branchless_shuffle_ops = std.StaticStringMap(void).initComptime(.{
    .{ "dup", {} },
    .{ "drop", {} },
    .{ "swap", {} },
    .{ "over", {} },
});

/// Structural half of the branchless-merge precondition: true when every
/// instruction in an `if` arm is a scalar literal or one of the admitted
/// trap-free inline ops, so compiling the arm emits no store, no general
/// call, no division/`rem`/`%`, and no nested control flow. This is the
/// gate checked before emitting `IF`; the kind/shape half
/// (`condSelectMergeKind`) runs on the compiled arms. A nested quotation
/// literal disqualifies the arm: it only appears as the operand of a
/// control-flow op (`if`/`call`/loops), none of which are admitted.
fn armBodyBranchlessEligible(body: []const Instruction) bool {
    for (body) |instr| {
        switch (instr.op) {
            .push_literal => |val| switch (val) {
                .fixnum, .float, .boolean => {},
                else => return false,
            },
            .call_word, .call_word_direct => {
                const name = instr.op.callTargetName() orelse return false;
                if (!branchless_arm_ops.has(name)) return false;
            },
        }
    }
    return true;
}

/// Scalar kind a qualifying same-type `if` merge selects on. `f64` is
/// deliberately absent: the gating benchmark measured a regression for
/// floats, so a same-type `f64` merge takes the boxed fallback.
const CondSelectKind = enum { i64, bool };

/// Structural equality of two abstract-stack entries: same variant and
/// same payload identity. Used to confirm the shared lower stack of two
/// `if` arms is untouched so only the top needs selecting.
fn stackEntryEql(a: StackEntry, b: StackEntry) bool {
    return switch (a) {
        .i64_ref => |r| b == .i64_ref and b.i64_ref == r,
        .f64_ref => |r| b == .f64_ref and b.f64_ref == r,
        .bool_ref => |r| b == .bool_ref and b.bool_ref == r,
        .raw_at_slot => |s| b == .raw_at_slot and b.raw_at_slot == s,
        .row_region => |id| b == .row_region and b.row_region == id,
        .quotation_body => |body| b == .quotation_body and b.quotation_body.ptr == body.ptr and b.quotation_body.len == body.len,
    };
}

/// Kind/shape half of the branchless-merge precondition, run on the two
/// compiled arm stacks. Returns the scalar kind to select on when the
/// arms are top-only same-kind `i64`/`bool`: equal depth (at least one
/// entry), no `row_region` anywhere, the lower entries identical between
/// the arms and to the untouched pre-`if` stack, and both tops the same
/// unboxed scalar kind restricted to `i64_ref` or `bool_ref`. Any other
/// shape (cross-type, `f64`/`f64`, a non-scalar top, a row, or a
/// depth/lower-stack mismatch) returns null, taking the boxed fallback.
fn condSelectMergeKind(
    base: []const StackEntry,
    base_sp: usize,
    t_stack: []const StackEntry,
    t_sp: usize,
    f_stack: []const StackEntry,
    f_sp: usize,
) ?CondSelectKind {
    if (t_sp != f_sp or t_sp == 0) return null;
    const top = t_sp - 1;
    if (base_sp != t_sp) return null;

    // The shared lower stack must be the untouched pre-`if` stack on both
    // arms, with no opaque row anywhere in scope.
    for (0..top) |i| {
        if (t_stack[i] == .row_region or f_stack[i] == .row_region) return null;
        if (!stackEntryEql(t_stack[i], f_stack[i])) return null;
        if (!stackEntryEql(t_stack[i], base[i])) return null;
    }

    return switch (t_stack[top]) {
        .i64_ref => if (f_stack[top] == .i64_ref) .i64 else null,
        .bool_ref => if (f_stack[top] == .bool_ref) .bool else null,
        else => null,
    };
}

/// True when an `if` arm contains a `branchless_shuffle_ops` op, whose purity
/// hinges on its operand being an unboxed scalar.
fn armBodyHasShuffleOp(body: []const Instruction) bool {
    for (body) |instr| {
        switch (instr.op) {
            .call_word, .call_word_direct => {
                const name = instr.op.callTargetName() orelse continue;
                if (branchless_shuffle_ops.has(name)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn isUnboxedScalar(e: StackEntry) bool {
    return e == .i64_ref or e == .f64_ref or e == .bool_ref;
}

/// Guards the discardable trial compile against side effects that would survive
/// a fallback. Arms with no shuffle op are pure on any operand and always pass.
/// A shuffle-bearing arm passes only when every pre-`if` entry it could touch
/// (the deeper of the two arms' inferred input depths) is an unboxed scalar, so
/// `dup`/`over`/`drop`/`swap` lower to ref sharing or an abstract reorder rather
/// than a copy/retain/release/callback the backend cannot fold away.
fn condSelectArmsOperandSafe(
    state: *CompileState,
    stack: []const StackEntry,
    sp: usize,
    tb: []const Instruction,
    fb: []const Instruction,
) bool {
    if (!armBodyHasShuffleOp(tb) and !armBodyHasShuffleOp(fb)) return true;
    const resolver = if (state.resolver) |r| r else null;
    const t_eff = (inferQuotationEffect(tb, resolver) catch return false) orelse return false;
    const f_eff = (inferQuotationEffect(fb, resolver) catch return false) orelse return false;
    const reach = @max(t_eff.input_count, f_eff.input_count);
    if (reach > sp) return false;
    for (sp - reach..sp) |i| {
        if (!isUnboxedScalar(stack[i])) return false;
    }
    return true;
}

// if: ( cond true-quot false-quot -- ... )   branch on truthiness
fn emitIntrinsicIf(ec: EmitCtx) IrCodegenError!ControlFlow {
    const state = ec.state;
    const ctx = state.ctx;
    const stack = ec.stack;
    const sp = ec.sp;

    // 1z truthiness: only `f` (boolean false) is falsy; every other value is truthy.
    // The condition entry types each need a different IR emission strategy:
    //
    //   bool_ref       -- use the IR bool directly as the branch condition
    //   i64/f64/quot   -- always truthy, so emit only the true branch
    //   raw_at_slot    -- load tag+payload from memory to compute is_truthy at runtime
    //
    // Both branches must produce the same stack depth; results
    // are merged with PHI nodes after the MERGE point.
    if (sp.* < 3) return IrCodegenError.StackUnderflow;
    sp.* -= 3;

    const cond_entry = stack[sp.*];
    const true_entry = stack[sp.* + 1];
    const false_entry = stack[sp.* + 2];

    // Extract quotation bodies where available; raw_at_slot
    // branches will be dispatched at runtime.
    const true_body: ?[]const Instruction = switch (true_entry) {
        .quotation_body => |body| body,
        .raw_at_slot => null,
        else => {
            state.not_compilable_reason = .quotation_reification;
            return IrCodegenError.NotCompilable;
        },
    };
    const false_body: ?[]const Instruction = switch (false_entry) {
        .quotation_body => |body| body,
        .raw_at_slot => null,
        else => {
            state.not_compilable_reason = .quotation_reification;
            return IrCodegenError.NotCompilable;
        },
    };

    // At least one branch must be a quotation_body so the
    // branch effect can be inferred. Both raw_at_slot is
    // unsupported (no effect information available).
    if (true_body == null and false_body == null) {
        state.not_compilable_reason = .quotation_reification;
        return IrCodegenError.NotCompilable;
    }

    // Determine the IR bool for the condition
    const cond_ref = switch (cond_entry) {
        .bool_ref => |ref| ref,
        .i64_ref, .f64_ref, .quotation_body => {
            // Non-boolean values and quotations are always truthy
            // Only the true branch executes; compile both to validate stack effects match
            if (true_body) |tb| {
                if (false_body) |fb| {
                    const false_stack = state.allocator.dupe(StackEntry, stack) catch return IrCodegenError.OutOfMemory;
                    defer state.allocator.free(false_stack);
                    var false_sp = sp.*;
                    const saved_exit_kind = state.exit_kind;
                    const saved_loop_end_set = state.loop_end_set;
                    state.exit_kind = .falls_through;
                    try compileInstructions(state, fb, false_stack, &false_sp);
                    const false_exit_kind = state.exit_kind;
                    state.exit_kind = .falls_through;
                    state.loop_end_set = saved_loop_end_set;
                    try compileInstructions(state, tb, stack, sp);
                    if (exitFallsThrough(false_exit_kind) and !symbolicShapeMatches(stack, sp.*, false_stack, false_sp)) return IrCodegenError.StackShapeMismatch;
                    if (!exitFallsThrough(false_exit_kind) and exitFallsThrough(state.exit_kind)) {
                        state.loop_end_set = saved_loop_end_set;
                    } else if (exitFallsThrough(false_exit_kind) and !exitFallsThrough(state.exit_kind)) {
                        state.loop_end_set = saved_loop_end_set;
                    }
                    if (!exitFallsThrough(false_exit_kind) and !exitFallsThrough(state.exit_kind)) {
                        state.exit_kind = mergeNonFallthroughExitKinds(false_exit_kind, state.exit_kind);
                    } else if (exitFallsThrough(state.exit_kind)) {
                        state.exit_kind = saved_exit_kind;
                    }
                } else {
                    try compileInstructions(state, tb, stack, sp);
                }
            } else {
                // True branch is raw_at_slot: dispatch at runtime.
                emitIfBranchDispatch(state, stack, sp, true_entry.raw_at_slot);
                // Infer effect from the false (quotation_body) branch.
                const eff = inferQuotationEffect(false_body.?, if (state.resolver) |r| r else null) catch {
                    state.not_compilable_reason = .effect_inference_overflow;
                    return IrCodegenError.NotCompilable;
                } orelse {
                    state.not_compilable_reason = .quotation_reification;
                    return IrCodegenError.NotCompilable;
                };
                sp.* = sp.* - eff.input_count + eff.output_count;
                resetStackToPhysical(stack, sp.*);
            }
            return .next;
        },
        .raw_at_slot => |s| emitSlotTruthiness(ctx, state.base_addr, s, state),
        .row_region => {
            if (state.aot_mode) {
                try emitIfOverRow(state, stack, sp, true_entry, false_entry, true_body, false_body);
                return .next;
            }
            state.not_compilable_reason = .quotation_truthiness;
            return IrCodegenError.NotCompilable;
        },
    };

    // `if` consumes the condition; release its backing if it
    // carried one (mirrors the interpreter's popBoolean). The
    // condition slot is below the new top and no longer live, so
    // the release precedes the branch bodies that overwrite it.
    if (cond_entry == .raw_at_slot) {
        emitReleaseSlot(state, cond_entry.raw_at_slot);
    }

    // Pre-branch branchless fast path: when both arms are pure, trap-free,
    // single-value `i64`/`bool` expressions that only replace the top scalar,
    // lower the merge to one `IR_COND` select over the two unboxed refs instead
    // of boxing each arm and merging through the physical stack. `IR_COND` is a
    // data-flow select with no control-flow merge, so both operands must be live
    // in this one block -- the arms are compiled branchlessly from copies of the
    // pre-`if` stack, then discarded if they do not qualify. The eligibility plus
    // operand-safety gate keeps that discardable trial free of physical-stack
    // stores / releases the backend cannot fold away. Any shape the precondition
    // rejects (cross-type, `f64`, non-scalar, side-effecting / trapping, row,
    // depth change) falls through to the unchanged boxed `IF` / `MERGE_2` path.
    if (true_body) |tb| {
        if (false_body) |fb| {
            if (armBodyBranchlessEligible(tb) and armBodyBranchlessEligible(fb) and
                condSelectArmsOperandSafe(state, stack, sp.*, tb, fb))
            {
                const base_sp = sp.*;
                const saved_exit = state.exit_kind;
                const saved_items_ptr = state.items_ptr;
                const saved_base_addr = state.base_addr;
                const saved_sp_val = state.sp_val;
                const saved_base_idx = state.base_idx;

                const t_copy = state.allocator.dupe(StackEntry, stack) catch return IrCodegenError.OutOfMemory;
                defer state.allocator.free(t_copy);
                const f_copy = state.allocator.dupe(StackEntry, stack) catch return IrCodegenError.OutOfMemory;
                defer state.allocator.free(f_copy);

                var t_sp = base_sp;
                try compileInstructions(state, tb, t_copy, &t_sp);
                var f_sp = base_sp;
                try compileInstructions(state, fb, f_copy, &f_sp);

                // The admitted op set never moves these, but restore them so a
                // null-kind fall-through leaves the boxed path's own snapshots
                // pristine.
                state.exit_kind = saved_exit;
                state.items_ptr = saved_items_ptr;
                state.base_addr = saved_base_addr;
                state.sp_val = saved_sp_val;
                state.base_idx = saved_base_idx;

                if (condSelectMergeKind(stack, base_sp, t_copy, t_sp, f_copy, f_sp)) |kind| {
                    const top = t_sp - 1;
                    const ir_ty: c_uint = switch (kind) {
                        .i64 => c.IR_I64,
                        .bool => c.IR_BOOL,
                    };
                    const a = switch (kind) {
                        .i64 => t_copy[top].i64_ref,
                        .bool => t_copy[top].bool_ref,
                    };
                    const b = switch (kind) {
                        .i64 => f_copy[top].i64_ref,
                        .bool => f_copy[top].bool_ref,
                    };
                    const sel = c.ir_fold3(ctx, c.IR_OPT(c.IR_COND, ir_ty), cond_ref, a, b);
                    stack[top] = switch (kind) {
                        .i64 => .{ .i64_ref = sel },
                        .bool => .{ .bool_ref = sel },
                    };
                    sp.* = t_sp;
                    state.cond_select_count += 1;
                    return .next;
                }
            }
        }
    }

    // Save stack state for the false branch
    const saved_sp = sp.*;
    const saved_stack = state.allocator.dupe(StackEntry, stack) catch return IrCodegenError.OutOfMemory;
    defer state.allocator.free(saved_stack);
    const saved_exit_kind = state.exit_kind;
    const saved_loop_end_set = state.loop_end_set;

    // Save items_ptr/base_addr before the true branch so the
    // false branch can use refs that dominate both paths.
    // Callbacks in the true branch may update these to IR refs
    // that are only defined on the IF_TRUE path.
    const saved_items_ptr = state.items_ptr;
    const saved_base_addr = state.base_addr;
    // A row-collapsing op in the true branch mutates these; the
    // false branch and the merge must resume from the pre-if
    // values that dominate both paths.
    const saved_base_idx = state.base_idx;
    const saved_sp_val = state.sp_val;

    // Infer the branch effect when one branch is raw_at_slot.
    // The raw_at_slot branch is assumed to have the same effect
    // as the quotation_body branch.
    const branch_effect: ?InferredEffect = if (true_body == null or false_body == null) blk: {
        const known_body = true_body orelse false_body orelse unreachable;
        break :blk inferQuotationEffect(known_body, if (state.resolver) |r| r else null) catch {
            state.not_compilable_reason = .effect_inference_overflow;
            return IrCodegenError.NotCompilable;
        } orelse {
            state.not_compilable_reason = .quotation_reification;
            return IrCodegenError.NotCompilable;
        };
    } else null;

    // Emit true branch
    const if_ref = c._ir_IF(ctx, cond_ref);
    c._ir_IF_TRUE(ctx, if_ref);
    state.recordBlockStart(ctx.unnamed_0.control);
    state.exit_kind = .falls_through;
    const saved_inline_trace_frame_count = state.inline_trace_frame_count;
    if (traceFramesEnabled(state) and state.inline_trace_frame_count < max_inline_trace_frames) {
        state.inline_trace_frames[state.inline_trace_frame_count] = .{
            .kind = .if_op,
            .line = ec.line,
        };
        state.inline_trace_frame_count += 1;
    }
    if (true_body) |tb| {
        try compileInstructions(state, tb, stack, sp);
    } else {
        // Runtime dispatch for raw_at_slot quotation
        emitIfBranchDispatch(state, stack, sp, true_entry.raw_at_slot);
        const eff = branch_effect.?;
        sp.* = sp.* - eff.input_count + eff.output_count;
        resetStackToPhysical(stack, sp.*);
    }
    if (traceFramesEnabled(state)) state.inline_trace_frame_count = saved_inline_trace_frame_count;
    const true_exit_kind = state.exit_kind;
    var end_true: c.ir_ref = c.IR_UNUSED;
    // In AOT mode (ir_emit_c), skip END after terminal_return
    // because ir_emit_c hangs on dead code after RETURN.
    // In JIT mode (ir_emit), terminal_return branches still
    // get END for well-formed END/MERGE structure.
    if (if (state.aot_mode) exitFallsThrough(true_exit_kind) else true_exit_kind != .loop_diverged) {
        // A quotation pushed by this arm and left unconsumed escapes the merge
        // as a value; reify it before the flush so the shared slot is actually
        // written. flushToPhysicalStack skips quotation_body entries, so without
        // this the merge would rewrite a raw_at_slot over an unwritten slot.
        try materializeQuotations(state, stack, sp.*, true);
        flushToPhysicalStack(state, stack, sp.*);
        // Persist the physical sp so a row-aware merge can reload
        // it. A branch that collapsed to a fresh row moved base_idx
        // and already left the runtime sp live; one that only ran
        // abstract ops over a pre-existing row kept base_idx and
        // must store the height. Harmless with no row, as it equals
        // the epilogue's own store.
        if (state.aot_mode and state.base_idx == saved_base_idx) {
            const sp_const = c.ir_const_addr(ctx, sp.*);
            const new_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, sp_const);
            c._ir_STORE(ctx, state.sp_ptr, new_sp);
        }
        end_true = c._ir_END(ctx);
    }

    // Restore items_ptr/base_addr before the false branch so
    // it uses refs from before the IF that dominate both paths.
    state.items_ptr = saved_items_ptr;
    state.base_addr = saved_base_addr;
    state.base_idx = saved_base_idx;
    state.sp_val = saved_sp_val;

    // Emit false branch
    c._ir_IF_FALSE(ctx, if_ref);
    state.recordBlockStart(ctx.unnamed_0.control);
    var false_sp = saved_sp;
    state.exit_kind = .falls_through;
    if (traceFramesEnabled(state)) state.inline_trace_frame_count = saved_inline_trace_frame_count;
    if (traceFramesEnabled(state) and state.inline_trace_frame_count < max_inline_trace_frames) {
        state.inline_trace_frames[state.inline_trace_frame_count] = .{
            .kind = .if_op,
            .line = ec.line,
        };
        state.inline_trace_frame_count += 1;
    }
    if (false_body) |fb| {
        try compileInstructions(state, fb, saved_stack, &false_sp);
    } else {
        emitIfBranchDispatch(state, saved_stack, &false_sp, false_entry.raw_at_slot);
        const eff = branch_effect.?;
        false_sp = false_sp - eff.input_count + eff.output_count;
        resetStackToPhysical(saved_stack, false_sp);
    }
    if (traceFramesEnabled(state)) state.inline_trace_frame_count = saved_inline_trace_frame_count;
    const false_exit_kind = state.exit_kind;

    // In AOT mode, treat terminal_return the same as
    // loop_diverged (both are non-falls-through) because
    // ir_emit_c cannot handle dead END/MERGE after RETURN.
    // In JIT mode, only loop_diverged is truly diverged;
    // terminal_return branches participate in MERGE.
    const true_diverged = if (state.aot_mode) !exitFallsThrough(true_exit_kind) else true_exit_kind == .loop_diverged;
    const false_diverged = if (state.aot_mode) !exitFallsThrough(false_exit_kind) else false_exit_kind == .loop_diverged;

    // Reify a quotation escaping the false arm before its flush, mirroring the
    // true arm above. The IF_FALSE block is still current here. Skip a diverged
    // arm: nothing survives it, and AOT must not emit into dead post-RETURN code.
    if (!false_diverged) {
        try materializeQuotations(state, saved_stack, false_sp, true);
    }

    if (true_diverged and false_diverged) {
        state.exit_kind = mergeNonFallthroughExitKinds(true_exit_kind, false_exit_kind);
    } else if (true_diverged) {
        // Only false path continues. No END or MERGE needed:
        // the false branch code just falls through after IF_FALSE.
        // The same pattern as the exit path of a compiled loop.
        flushToPhysicalStack(state, saved_stack, false_sp);
        sp.* = false_sp;
        @memcpy(stack, saved_stack);
        resetStackToPhysicalPreservingRows(stack, sp.*);
        state.exit_kind = saved_exit_kind;
    } else if (false_diverged) {
        // Only true path continues. Resume from true branch's END.
        c._ir_BEGIN(ctx, end_true);
        if (state.refresh_stack_fn != c.IR_UNUSED) {
            refreshCachedStackPointer(state);
        }
        resetStackToPhysicalPreservingRows(stack, sp.*);
        state.exit_kind = saved_exit_kind;
    } else {
        // Neither branch terminated: normal merge.
        flushToPhysicalStack(state, saved_stack, false_sp);
        const false_has_row = hasRowRegion(saved_stack, false_sp);
        if (state.aot_mode and state.base_idx == saved_base_idx) {
            const sp_const = c.ir_const_addr(ctx, false_sp);
            const new_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, sp_const);
            c._ir_STORE(ctx, state.sp_ptr, new_sp);
        }
        const end_false = c._ir_END(ctx);
        c._ir_MERGE_2(ctx, end_true, end_false);
        state.recordBlockStart(ctx.unnamed_0.control);
        if (!symbolicShapeMatches(stack, sp.*, saved_stack, false_sp)) {
            const true_has_row = hasRowRegion(stack, sp.*);

            // A row on either side means one branch left an opaque result; the two physical tops
            // still agree, so rejoin to a single fresh row read from the live sp both paths stored.
            //
            // A genuine depth mismatch with no row is still a stack-effect error, unless the word's
            // declared output is itself variable-arity, in which case the two concrete arms are
            // the genuine alternatives.
            //
            // The declared output is the only thing that distinguishes this case from a word whose
            // unequal arms are an artifact of a mis-modeled variable-arity native call.
            const declared_var_arity = declaredAlternativeOutput(state);
            if (state.aot_mode and (true_has_row or false_has_row or declared_var_arity)) {
                // Two concrete unequal arms collapsing to a row for the first time vary the output
                // arity. Record it so callers read this word's result as a row rather than trusting
                // the declared concrete count. Preëxisting has-row case keeps its prior behavior of
                // not setting the flag here, so this is gated to the new no-row collapse.
                if (!(true_has_row or false_has_row)) state.variable_arity = true;

                reloadBaseAfterDynamicCall(state);

                sp.* = 1;
                stack[0] = .{ .row_region = state.nextRowId() };
                state.exit_kind = saved_exit_kind;
                state.loop_end_set = saved_loop_end_set;
                return .next;
            }
            return IrCodegenError.StackShapeMismatch;
        }
        if (state.refresh_stack_fn != c.IR_UNUSED) {
            refreshCachedStackPointer(state);
        }
        resetStackToPhysicalPreservingRows(stack, sp.*);
        state.exit_kind = saved_exit_kind;
        state.loop_end_set = saved_loop_end_set;
    }
    return .next;
}

/// Shared body for the comparison intrinsics (`=`, `<`, `>`): pop two operands
/// and fold a boolean compare with `ir_op`. When both operands are runtime
/// unknowns, or are non-numeric, fall back to the polymorphic native comparison
/// rather than optimistically assuming i64 (which would bail for type values,
/// strings, etc.).
fn emitComparison(ec: EmitCtx, ir_op: c_uint) IrCodegenError!ControlFlow {
    const state = ec.state;
    const ctx = state.ctx;
    const stack = ec.stack;
    const sp = ec.sp;
    const name = ec.name;
    const line = ec.line;

    if (sp.* < 2) return IrCodegenError.StackUnderflow;
    sp.* -= 2;

    // When both operands are runtime unknowns and a resolver is available,
    // delegate to the polymorphic native directly. resolveOperandPair would
    // optimistically assume i64 and emit a fixnum tag check that bails for
    // non-numeric types (type values, strings, etc.).
    if (stack[sp.*] == .raw_at_slot and stack[sp.* + 1] == .raw_at_slot and state.resolver != null) {
        sp.* += 2;
        try emitResolvedNativeCallback(state, name, stack, sp, line);
        return .next;
    }

    const resolved = resolveOperandPair(stack[sp.*], stack[sp.* + 1], state) catch |err| switch (err) {
        IrCodegenError.NotCompilable => {
            // Operands are not numeric (e.g., bool_ref vs raw_at_slot).
            // Fall back to the polymorphic native comparison.
            sp.* += 2;
            try emitResolvedNativeCallback(state, name, stack, sp, line);
            return .next;
        },
        else => return err,
    };

    const result = switch (resolved) {
        .i64_pair => |p| c.ir_fold2(ctx, c.IR_OPT(ir_op, c.IR_BOOL), p.a, p.b),
        .f64_pair => |p| c.ir_fold2(ctx, c.IR_OPT(ir_op, c.IR_BOOL), p.a, p.b),
    };
    stack[sp.*] = .{ .bool_ref = result };
    sp.* += 1;
    return .next;
}

fn emitIntrinsicEq(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitComparison(ec, c.IR_EQ);
}

fn emitIntrinsicLt(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitComparison(ec, c.IR_LT);
}

fn emitIntrinsicGt(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitComparison(ec, c.IR_GT);
}

/// Shared raw/raw polymorphic fast path for the arithmetic intrinsics that
/// support both fixnum and float (`+ - * / %`). When both operands are runtime
/// unknowns, emit polymorphic code that branches on fixnum vs float at runtime
/// instead of bailing on a type mismatch; returns true when it consumed the
/// operands, false when the caller should emit its concrete-type path. The
/// caller must have already popped the two operands (so they sit at sp and
/// sp+1).
fn emitPolyArithFastPath(ec: EmitCtx, op: PolyArithOp) IrCodegenError!bool {
    const state = ec.state;
    const ctx = state.ctx;
    const stack = ec.stack;
    const sp = ec.sp;
    const entry_a = stack[sp.*];
    const entry_b = stack[sp.* + 1];
    if (entry_a != .raw_at_slot or entry_b != .raw_at_slot) return false;

    // Polymorphic arith writes directly to a physical slot. If any entry below the operands
    // aliases `dest_slot`, save dest_slot to a scratch slot first so the write doesn't
    // clobber the aliased value.
    const dest_slot = sp.*;
    const scratch = @max(dest_slot, @max(entry_a.raw_at_slot, entry_b.raw_at_slot)) + 1;
    for (0..sp.*) |j| {
        if (stack[j] == .raw_at_slot and stack[j].raw_at_slot == dest_slot) {
            emitCopySlot(ctx, state.base_addr, dest_slot, scratch);
            stack[j] = .{ .raw_at_slot = scratch };
            break;
        }
    }
    try emitPolymorphicBinaryArith(state, entry_a.raw_at_slot, entry_b.raw_at_slot, dest_slot, op, ec.line);
    stack[sp.*] = .{ .raw_at_slot = sp.* };
    sp.* += 1;
    return true;
}

/// Shared body for the overflow-checked arithmetic intrinsics (`+ - *`): pop two
/// operands, try the polymorphic raw/raw fast path, else resolve the operand
/// pair and emit the overflow-checked i64 op (`ov_op`) or the folded f64 op
/// (`f64_op`).
fn emitOverflowArith(ec: EmitCtx, poly_op: PolyArithOp, comptime ov_op: comptime_int, f64_op: c_uint) IrCodegenError!ControlFlow {
    const state = ec.state;
    const ctx = state.ctx;
    const stack = ec.stack;
    const sp = ec.sp;

    if (sp.* < 2) return IrCodegenError.StackUnderflow;
    sp.* -= 2;

    if (try emitPolyArithFastPath(ec, poly_op)) return .next;

    const resolved = try resolveOperandPair(stack[sp.*], stack[sp.* + 1], state);
    switch (resolved) {
        .i64_pair => |p| stack[sp.*] = .{ .i64_ref = emitOverflowCheckedBinary(ctx, ov_op, p.a, p.b, state.bail_status) },
        .f64_pair => |p| stack[sp.*] = .{ .f64_ref = c.ir_fold2(ctx, c.IR_OPT(f64_op, c.IR_DOUBLE), p.a, p.b) },
    }
    sp.* += 1;
    return .next;
}

fn emitIntrinsicAdd(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitOverflowArith(ec, .add, c.IR_ADD_OV, c.IR_ADD);
}

fn emitIntrinsicSub(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitOverflowArith(ec, .sub, c.IR_SUB_OV, c.IR_SUB);
}

fn emitIntrinsicMul(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitOverflowArith(ec, .mul, c.IR_MUL_OV, c.IR_MUL);
}

/// `/`: like the overflow-checked family, but the i64 path is a guarded division
/// (div-by-zero and minInt/-1) rather than an overflow-checked op.
fn emitIntrinsicDiv(ec: EmitCtx) IrCodegenError!ControlFlow {
    const state = ec.state;
    const ctx = state.ctx;
    const stack = ec.stack;
    const sp = ec.sp;

    if (sp.* < 2) return IrCodegenError.StackUnderflow;
    sp.* -= 2;

    if (try emitPolyArithFastPath(ec, .div)) return .next;

    const resolved = try resolveOperandPair(stack[sp.*], stack[sp.* + 1], state);
    switch (resolved) {
        .i64_pair => |p| stack[sp.*] = .{ .i64_ref = emitDivision(ctx, p.a, p.b, state.bail_status) },
        .f64_pair => |p| stack[sp.*] = .{ .f64_ref = c.ir_fold2(ctx, c.IR_OPT(c.IR_DIV, c.IR_DOUBLE), p.a, p.b) },
    }
    sp.* += 1;
    return .next;
}

/// `%` (Euclidean mod): polymorphic raw/raw fast path, else an integer-only
/// guarded modulo.
fn emitIntrinsicMod(ec: EmitCtx) IrCodegenError!ControlFlow {
    const state = ec.state;
    const ctx = state.ctx;
    const stack = ec.stack;
    const sp = ec.sp;

    if (sp.* < 2) return IrCodegenError.StackUnderflow;
    sp.* -= 2;

    if (try emitPolyArithFastPath(ec, .mod)) return .next;

    const a = try requireI64(stack[sp.*], state);
    const b = try requireI64(stack[sp.* + 1], state);
    stack[sp.*] = .{ .i64_ref = emitEuclideanMod(ctx, a, b, state.bail_status) };
    sp.* += 1;
    return .next;
}

/// `div`: integer-only guarded division. No polymorphic float path.
fn emitIntrinsicIntDiv(ec: EmitCtx) IrCodegenError!ControlFlow {
    const state = ec.state;
    const ctx = state.ctx;
    const stack = ec.stack;
    const sp = ec.sp;

    if (sp.* < 2) return IrCodegenError.StackUnderflow;
    sp.* -= 2;

    const a = try requireI64(stack[sp.*], state);
    const b = try requireI64(stack[sp.* + 1], state);
    stack[sp.*] = .{ .i64_ref = emitDivision(ctx, a, b, state.bail_status) };
    sp.* += 1;
    return .next;
}

/// `rem`: integer-only guarded remainder. No polymorphic float path.
fn emitIntrinsicRem(ec: EmitCtx) IrCodegenError!ControlFlow {
    const state = ec.state;
    const ctx = state.ctx;
    const stack = ec.stack;
    const sp = ec.sp;

    if (sp.* < 2) return IrCodegenError.StackUnderflow;
    sp.* -= 2;

    const a = try requireI64(stack[sp.*], state);
    const b = try requireI64(stack[sp.* + 1], state);
    stack[sp.*] = .{ .i64_ref = emitRemainder(ctx, a, b, state.bail_status) };
    sp.* += 1;
    return .next;
}

/// Emit a resolved word through the generic native/dispatch path: row-variable
/// effect specialization, then the is_native / AOT-bounded / AOT-direct /
/// bounded / compound emission chain. Shared by the terminal `else` of
/// `compileInstructions` (ordinary words) and the indexed-stack handlers (the
/// literal-depth, no-row case that falls through to generic emission). Returns
/// `.next` for the inline `continue` paths and normal completion, `.stop` for
/// the inline `break` paths.
fn emitGenericResolvedNativeCall(ec: EmitCtx, resolved: ResolvedWord) IrCodegenError!ControlFlow {
    const state = ec.state;
    const ctx = state.ctx;
    const stack = ec.stack;
    const sp = ec.sp;
    const name = ec.name;
    const idx = ec.idx;
    const line = ec.line;

    // Specialize input/output counts for row-variable effects
    // using literal quotation bodies visible on the abstract stack.
    // Must happen before materializeQuotations destroys quotation_body entries.
    var effective_in = resolved.input_count;
    var effective_out = resolved.output_count;
    if (resolved.callee_effect) |callee_eff| {
        const row_result = resolveRowVariableEffect(callee_eff, stack, sp.*, state.resolver) catch |err| {
            state.not_compilable_reason = switch (err) {
                error.EffectInferenceOverflow => .effect_inference_overflow,
                error.RowBindingOverflow => .row_binding_overflow,
            };
            return IrCodegenError.NotCompilable;
        };
        if (row_result) |specialized| {
            effective_in = specialized.input_count;
            effective_out = specialized.output_count;
        } else if (state.aot_mode) {
            // Row-variable resolution failed but the word exists in the resolver.
            // Emit an interpreter call and insert a row_region so subsequent
            // instructions above the region can continue compiling.
            // Same model as quotation `call` with unresolved effects.
            //
            // The symbolic-row machinery used in the call sequel
            // (`reloadBaseAfterDynamicCall` + a fresh `row_region`) is what
            // lets compilation continue past this fallback. Strict-mode
            // rejection is intentionally handled out-of-line:
            // `emitNativeWordCall` and the uncompiled fallthrough in
            // `emitAotWordCall` register their emission via
            // `noteAotFallbackEmission`, and the compound-fallback
            // diagnostic in `main.zig` rejects the build when
            // `compound_uncompiled` is non-zero. The static cross-check in
            // `AotFallbackStaticCheck` guards the classification contract by
            // comparing the build-time inventory against the assembled C.
            //
            // When the callee keeps concrete outputs above its
            // output row variable (e.g. `2dip`'s `x y`), preserve
            // them as live entries above the bounded row so a
            // combinator threading them -- `times` decrementing
            // its counter after `dup 2dip` -- keeps operating on
            // real entries instead of reaching into a collapsed
            // region.
            const preserve = trailingConcreteOutputs(callee_eff);
            if (try emitDynamicRowFallbackPreserving(state, stack, sp, name, resolved, line, preserve)) {
                return .next;
            }
            return .stop;
        } else {
            state.not_compilable_reason = .unresolvable_word;
            return IrCodegenError.NotCompilable;
        }
    }

    if (resolved.is_native) {
        // Generic native word callback
        if (sp.* < effective_in) {
            // Reaching below the declared inputs touches the
            // implicit caller row. In AOT mode emit the native
            // against the live stack and collapse to a row,
            // rather than rejecting as an abstract underflow.
            if (state.aot_mode) {
                if (try emitDynamicRowFallback(state, stack, sp, name, resolved, line)) return .next;
                return .stop;
            }
            return IrCodegenError.StackUnderflow;
        }

        try materializeQuotations(state, stack, sp.*, false);
        flushToPhysicalStack(state, stack, sp.*);
        const ctx_val = emitCallbackPreamble(state, sp.*);

        if (resolved.stack_effect_ptr) |eff_ptr| {
            emitParamValidation(state, eff_ptr);
        }

        // Try inline PIC (from interpreter profiling) or
        // dispatch-table-driven inline checks (from frozen
        // dispatch table) before falling back to generic
        // native call. The binary variants apply to two-operand
        // words; the unary variants gate on `effective_in == 1`
        // and cover strictly-unary generics like `inspect`. Each
        // includes the slow-path fallback internally, so when any
        // one succeeds no separate call is needed.
        if (!emitInlinePicCheck(state, idx, ctx_val, name, resolved, effective_in, line) and
            !emitInlineDispatchTableCheck(state, ctx_val, name, resolved, effective_in, line) and
            !emitInlinePicCheckUnary(state, idx, ctx_val, name, resolved, effective_in, line) and
            !emitInlineDispatchTableCheckUnary(state, ctx_val, name, resolved, effective_in, line))
        {
            emitNativeWordCall(state, ctx_val, name, resolved, line);
        }

        if (exitFallsThrough(state.exit_kind)) {
            // Adjust abstract stack by specialized effect
            settleRowAwareStack(state, stack, sp, effective_in, effective_out);
        }
    } else if (state.aot_mode and resolved.bounded_constraint != null and state.aot_slot_maps != null) {
        // AOT bounded generic dispatch: emit the slot-indexed
        // helper that satisfies-checks the operand(s) and
        // dispatches the concrete-type method. Uses slot-table
        // index instead of a process-local descriptor pointer so
        // the AOT binary works across process boundaries. The
        // protocol and combinator bounds use parallel slot
        // tables and helper exports.
        if (sp.* < effective_in) {
            // Reaches into the implicit caller row: route the
            // bounded generic through plain generic dispatch
            // against the live stack and collapse to a row.
            if (try emitDynamicRowFallback(state, stack, sp, name, resolved, line)) return .next;
            return .stop;
        }

        try materializeQuotations(state, stack, sp.*, false);
        flushToPhysicalStack(state, stack, sp.*);
        _ = emitCallbackPreamble(state, sp.*);

        switch (resolved.bounded_constraint.?) {
            .protocol => |pd| emitAotSatisfiesAndDispatch(state, resolved.dispatch_id, pd, resolved.bounded_arity, line),
            .combinator => |cc| emitAotSatisfiesAndDispatchCombinator(state, resolved.dispatch_id, cc, resolved.bounded_arity, line),
        }

        if (exitFallsThrough(state.exit_kind)) {
            settleRowAwareStack(state, stack, sp, effective_in, effective_out);
        }
    } else if (state.aot_mode) {
        // AOT mode: direct call by name or interpreter fallback.
        // A plain (non-bounded) generic instead routes through the
        // dispatch helper so a registered method runs, falling to
        // the word's default body on a miss.
        if (sp.* < effective_in) {
            // A compound or generic word reaching below its declared inputs
            // touches the implicit caller region. When the callee has a concrete
            // net effect and no row is live, re-establish the abstract stack
            // concretely so a later store to an invariant outer slot stays
            // correctly addressed; a genuinely row-returning callee, or one
            // reaching past an existing row, collapses to an opaque row (the
            // `(file-use-targets) nip` shape).
            if (!resolved.returns_row and !hasRowRegion(stack, sp.*)) {
                if (try emitReachBelowConcrete(state, stack, sp, name, resolved, line, effective_out)) return .next;
                return .stop;
            }
            if (try emitDynamicRowFallback(state, stack, sp, name, resolved, line)) return .next;
            return .stop;
        }

        try materializeQuotations(state, stack, sp.*, false);
        flushToPhysicalStack(state, stack, sp.*);
        const ctx_val = emitCallbackPreamble(state, sp.*);

        if (resolved.stack_effect_ptr) |eff_ptr| {
            emitParamValidation(state, eff_ptr);
        }

        if (resolved.is_generic) {
            emitAotGenericDispatch(state, resolved.dispatch_id, resolved.word_id, name, line);
        } else {
            emitAotWordCall(state, ctx_val, name, resolved, line);
        }

        if (exitFallsThrough(state.exit_kind)) {
            if (resolved.returns_row) {
                collapseToFreshRow(state, stack, sp);
            } else {
                settleRowAwareStack(state, stack, sp, effective_in, effective_out);
            }
        }
    } else if (resolved.bounded_constraint != null) {
        // Bounded generic dispatch: emit the helper that
        // satisfies-checks the operand(s) and dispatches the
        // concrete-type method in one call. No PIC is installed,
        // and the bound is checked exactly once (by the helper)
        // rather than re-validated. The emission predicate
        // guarantees the bound requires this generic, so a
        // satisfying operand always resolves a method -- the helper
        // never reaches its raise-on-miss path, matching the
        // interpreter's behavior.
        if (sp.* < effective_in) return IrCodegenError.StackUnderflow;

        try materializeQuotations(state, stack, sp.*, false);
        flushToPhysicalStack(state, stack, sp.*);
        _ = emitCallbackPreamble(state, sp.*);

        switch (resolved.bounded_constraint.?) {
            .protocol => |pd| emitSatisfiesAndDispatch(state, resolved.dispatch_id, @intFromPtr(pd), resolved.bounded_arity, resolved.bounded_trace_name orelse name, line),
            .combinator => |cc| emitSatisfiesAndDispatchCombinator(state, resolved.dispatch_id, @intFromPtr(cc), resolved.bounded_arity, resolved.bounded_trace_name orelse name, line),
        }

        if (exitFallsThrough(state.exit_kind)) {
            settleRowAwareStack(state, stack, sp, effective_in, effective_out);
        }
    } else {
        // Compound word: dispatch table indirect call
        DispatchLayout.ensureInit();

        if (sp.* < effective_in) return IrCodegenError.StackUnderflow;

        try materializeQuotations(state, stack, sp.*, false);
        flushToPhysicalStack(state, stack, sp.*);
        _ = emitCallbackPreamble(state, sp.*);

        if (resolved.stack_effect_ptr) |eff_ptr| {
            emitParamValidation(state, eff_ptr);
        }

        // Load entries.items.ptr from the dispatch table
        const dispatch_ptr = state.dispatch_ptr;
        const items_ptr_off = c.ir_const_addr(ctx, DispatchLayout.items_ptr_offset);
        const entries_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), dispatch_ptr, items_ptr_off);
        const entries_ptr = c._ir_LOAD(ctx, c.IR_ADDR, entries_ptr_addr);

        // Index into entries array: entries_ptr + word_id * entry_size + code_ptr_offset
        const entry_byte_off = c.ir_const_addr(ctx, resolved.word_id * DispatchLayout.entry_size + DispatchLayout.code_ptr_offset);
        const code_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), entries_ptr, entry_byte_off);
        const callee_code_ptr = c._ir_LOAD(ctx, c.IR_ADDR, code_ptr_addr);

        // Null-check code_ptr: fallback to interpreter if callee not compiled
        const null_addr = c.ir_const_addr(ctx, 0);
        const is_null = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), callee_code_ptr, null_addr);
        const if_null = c._ir_IF(ctx, is_null);

        // Cold path: callee not compiled, call interpreter fallback
        c._ir_IF_TRUE_cold(ctx, if_null);
        {
            JitContextLayout.ensureInit();
            const ctx_off = c.ir_const_addr(ctx, JitContextLayout.ctx_offset);
            const ctx_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
            const ctx_val2 = c._ir_LOAD(ctx, c.IR_ADDR, ctx_addr);
            const word_id_const = c.ir_const_addr(ctx, resolved.word_id);
            const line_const = c.ir_const_addr(ctx, line);
            state.noteAotFallbackEmission(.compound_uncompiled, name, resolved.word_id, line);
            const fb_result = c._ir_CALL_3(ctx, c.IR_I32, state.interpreted_call_fn, ctx_val2, word_id_const, line_const);
            emitCallbackPostCheck(state, fb_result, state.error_propagate_status, if (resolved.never_returns) state.error_propagate_status else null, .none);
        }
        const end_fallback = if (resolved.never_returns) c.IR_UNUSED else c._ir_END(ctx);

        // Hot path: callee is compiled, call directly
        c._ir_IF_FALSE(ctx, if_null);
        {
            const call_result = c._ir_CALL_1(ctx, c.IR_I32, callee_code_ptr, state.jit_ctx_ptr);
            emitCallbackPostCheck(state, call_result, call_result, if (resolved.never_returns) state.error_propagate_status else null, .{ .named = .{ .name = name, .line = line } });
        }
        if (resolved.never_returns) {
            state.exit_kind = .terminal_return;
        } else {
            const end_compiled = c._ir_END(ctx);
            c._ir_MERGE_2(ctx, end_fallback, end_compiled);

            // Both branches called emitCallbackPostCheck which
            // updated state.items_ptr/base_addr to branch-local
            // IR refs. Re-LOAD after the merge so subsequent
            // code uses refs that dominate this point.
            if (state.refresh_stack_fn != c.IR_UNUSED) {
                refreshCachedStackPointer(state);
            }

            if (resolved.returns_row) {
                collapseToFreshRow(state, stack, sp);
            } else {
                // Adjust abstract stack based on specialized effect
                settleRowAwareStack(state, stack, sp, effective_in, effective_out);
            }
        }
    }

    return .next;
}

/// Shared dispatch for the indexed-stack intrinsics (`pick-n`, `<rot-n`,
/// `rot-n>`, `nip-n`) over a symbolic row.
///
/// A literal depth that provably stays above the row rewrites the abstract stack
/// in place; otherwise the depth reaches into the opaque row, or below the
/// modeled entries into it, so the op is emitted against the live physical stack
/// and the abstract stack collapses to a fresh row_region, exactly as a runtime
/// depth and the inline row-underflow shuffles do. A literal depth with no row
/// present falls through to the general native emission, which resets the
/// abstract stack to mirror the physical one.
fn emitIndexedStackDispatch(ec: EmitCtx, op: IndexedStackOp) IrCodegenError!ControlFlow {
    const state = ec.state;
    const stack = ec.stack;
    const sp = ec.sp;
    const name = ec.name;

    const res = state.resolver orelse {
        state.not_compilable_reason = .unresolvable_word;
        return IrCodegenError.NotCompilable;
    };
    const resolved = res.resolve(name, res.user_data) orelse {
        state.not_compilable_reason = .unresolvable_word;
        return IrCodegenError.NotCompilable;
    };

    if (extractPrecedingLiteralDepth(ec.instructions, ec.idx)) |depth| {
        if (findRowRegionIndex(stack, sp.*)) |row_idx| {
            // After popping the depth literal, the deepest slot the op can touch is:
            //
            //     sp - 2 - depth
            //
            // The op stays above the row only when that slot is a known entry strictly
            // above the row_idx. A depth that exceeds the modeled entries (sp - 2), or
            // lands at or below the row reaches into the opaque region and must be
            // emitted live.
            const stays_above = sp.* >= 2 and depth <= sp.* - 2 and (sp.* - 2 - depth) > row_idx;
            if (stays_above) {
                try rewriteIndexedStackOp(state, op, stack, sp, depth);
                // `nip-n` keeps the top entry while dropping beneath it, leaving
                // the survivor pointing at a physical slot >= the new top;
                // reconcile so a following push does not clobber it. A no-op when
                // no strand results (`pick-n` / `rot` above a row).
                settleStrandedEntries(state, stack, sp.*);
                return .next;
            }

            if (state.aot_mode) {
                if (try emitDynamicRowFallback(state, stack, sp, name, resolved, ec.line)) return .next;
                return .stop;
            }

            state.not_compilable_reason = .indexed_access_into_row;
            return IrCodegenError.NotCompilable;
        }

        // Literal depth with no row: fall through to the general native emission,
        // which resets the abstract stack to mirror the physically-rearranged stack.
        return emitGenericResolvedNativeCall(ec, resolved);
    } else if (state.aot_mode) {
        if (try emitDynamicRowFallback(state, stack, sp, name, resolved, ec.line)) return .next;
        return .stop;
    } else {
        state.not_compilable_reason = .indexed_access_into_row;
        return IrCodegenError.NotCompilable;
    }
}

fn emitIntrinsicPickN(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitIndexedStackDispatch(ec, .pick_n);
}

fn emitIntrinsicRotNUp(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitIndexedStackDispatch(ec, .rot_up);
}

fn emitIntrinsicRotNDown(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitIndexedStackDispatch(ec, .rot_down);
}

fn emitIntrinsicNipN(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitIndexedStackDispatch(ec, .nip_n);
}

/// Compile `drop-n` / `array-n` when the count is a literal.
///
/// Their declared variadic effect (`x1..xn n --`, `...elems n -- array`) models a
/// fixed arity, so without the literal count the abstract stack cannot tell how
/// many entries the op consumes. It then collapses to a row. That is fatal when
/// concrete entries sit below the consumed span, because the row swallows them.
///
/// Folding the literal count recovers the real arity. The op consumes `depth`
/// entries plus the count literal itself, and produces `produced`. The native
/// runs against the live stack. `settleRowAwareStack` then reconciles the
/// abstract stack, preserving any row below and collapsing only when the consumed
/// span reaches into it.
///
/// `escapes` marks the produced value as a word-output escape position, so a
/// packed quotation element with an uncompiled body is force-linked to the
/// interpreter. `array-n` escapes its packed array; `drop-n` produces nothing.
///
/// A count that is not a literal keeps the pre-existing row-collapse behavior.
fn emitLiteralCountConsumingOp(ec: EmitCtx, produced: usize, escapes: bool) IrCodegenError!ControlFlow {
    const state = ec.state;
    const stack = ec.stack;
    const sp = ec.sp;
    const name = ec.name;

    const res = state.resolver orelse {
        state.not_compilable_reason = .unresolvable_word;
        return IrCodegenError.NotCompilable;
    };
    const resolved = res.resolve(name, res.user_data) orelse {
        state.not_compilable_reason = .unresolvable_word;
        return IrCodegenError.NotCompilable;
    };

    const depth = extractPrecedingLiteralDepth(ec.instructions, ec.idx) orelse {
        if (state.aot_mode) {
            if (try emitDynamicRowFallback(state, stack, sp, name, resolved, ec.line)) return .next;
            return .stop;
        }
        state.not_compilable_reason = .indexed_access_into_row;
        return IrCodegenError.NotCompilable;
    };

    // The op consumes `depth` entries beneath the count plus the count itself.
    const consumed = depth + 1;
    // The consumed span must stay above any row: the deepest consumed entry sits
    // at `sp - consumed` and must be a modeled entry strictly above the row.
    const reaches_row = if (findRowRegionIndex(stack, sp.*)) |row_idx|
        !(sp.* > consumed and sp.* - consumed > row_idx)
    else
        sp.* < consumed;
    if (reaches_row) {
        if (state.aot_mode) {
            if (try emitDynamicRowFallback(state, stack, sp, name, resolved, ec.line)) return .next;
            return .stop;
        }
        state.not_compilable_reason = .indexed_access_into_row;
        return IrCodegenError.NotCompilable;
    }

    try materializeQuotations(state, stack, sp.*, escapes);
    flushToPhysicalStack(state, stack, sp.*);
    const ctx_val = emitCallbackPreamble(state, sp.*);
    if (resolved.stack_effect_ptr) |eff_ptr| emitParamValidation(state, eff_ptr);
    emitNativeWordCall(state, ctx_val, name, resolved, ec.line);
    if (exitFallsThrough(state.exit_kind)) {
        settleRowAwareStack(state, stack, sp, consumed, produced);
    }
    return .next;
}

fn emitIntrinsicDropN(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitLiteralCountConsumingOp(ec, 0, false);
}

fn emitIntrinsicArrayN(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitLiteralCountConsumingOp(ec, 1, true);
}

fn emitIntrinsicTimes(ec: EmitCtx) IrCodegenError!ControlFlow {
    const state = ec.state;
    const stack = ec.stack;
    const sp = ec.sp;
    const ctx = state.ctx;

    if (sp.* < 2) return IrCodegenError.StackUnderflow;
    sp.* -= 2;
    const n_entry = stack[sp.*];
    const quot_entry = stack[sp.* + 1];

    const initial_n = try requireI64(n_entry, state);

    // A quotation carried in the loop-invariant region below the loop args is
    // carried unchanged across the back-edge; reify it before the loop header so
    // the slot is written once. flushToPhysicalStack skips quotation_body, and the
    // back-edge invariance check compares only rows, so without this the carried
    // entry would be rewritten to a raw_at_slot over an unwritten slot.
    try materializeQuotations(state, stack, sp.*, true);

    // Flush user stack to physical memory before the loop
    flushToPhysicalStack(state, stack, sp.*);

    // Snapshot symbolic stack state at loop entry for
    // back-edge invariance checks.
    const loop_entry_stack = state.allocator.dupe(StackEntry, stack[0..sp.*]) catch return IrCodegenError.OutOfMemory;
    defer state.allocator.free(loop_entry_stack);
    const loop_entry_sp = sp.*;

    // Write sp to memory so indirect calls can see it
    const pre_loop_sp_const = c.ir_const_addr(ctx, sp.*);
    const pre_loop_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, pre_loop_sp_const);
    c._ir_STORE(ctx, state.sp_ptr, pre_loop_sp);

    // Zero-iteration check: n > 0
    const zero = c.ir_const_i64(ctx, 0);
    const gt_zero = c.ir_fold2(ctx, c.IR_OPT(c.IR_GT, c.IR_BOOL), initial_n, zero);
    const if_skip = c._ir_IF(ctx, gt_zero);

    c._ir_IF_FALSE(ctx, if_skip);
    const skip_end = c._ir_END(ctx);

    c._ir_IF_TRUE(ctx, if_skip);
    const entry_end = c._ir_END(ctx);

    const loop_ref = c._ir_LOOP_BEGIN(ctx, entry_end);
    state.recordBlockStart(loop_ref);
    const counter_phi = c._ir_PHI_2(ctx, c.IR_I64, initial_n, c.IR_UNUSED);

    switch (quot_entry) {
        .quotation_body => |body| {
            resetStackToPhysicalPreservingRows(stack, sp.*);
            try compileInstructions(state, body, stack, sp);
            if (!symbolicShapeMatches(stack, sp.*, loop_entry_stack, loop_entry_sp)) return IrCodegenError.StackShapeMismatch;
            // Flush body results back
            flushToPhysicalStack(state, stack, sp.*);
        },
        .raw_at_slot => |s| {
            try emitIndirectQuotCall(state, stack, sp, s, ec.line);
        },
        else => {
            state.not_compilable_reason = .quotation_reification;
            return IrCodegenError.NotCompilable;
        },
    }

    // Reset stack entries after body
    resetStackToPhysicalPreservingRows(stack, sp.*);

    // Decrement counter
    const one = c.ir_const_i64(ctx, 1);
    const new_counter = c.ir_fold2(ctx, c.IR_OPT(c.IR_SUB, c.IR_I64), counter_phi, one);
    c._ir_PHI_SET_OP(ctx, counter_phi, 2, new_counter);

    // Continue if new_counter > 0
    const continue_cond = c.ir_fold2(ctx, c.IR_OPT(c.IR_GT, c.IR_BOOL), new_counter, zero);
    const if_continue = c._ir_IF(ctx, continue_cond);
    c._ir_IF_TRUE(ctx, if_continue);
    emitSafepointCall(state);
    const loop_end = c._ir_LOOP_END(ctx);
    c.ir_set_op2(ctx, loop_ref, loop_end);

    c._ir_IF_FALSE(ctx, if_continue);
    const exit_end = c._ir_END(ctx);

    c._ir_MERGE_2(ctx, skip_end, exit_end);

    // The safepoint on the loop-continue path updated
    // state.items_ptr/base_addr to IR refs that don't dominate
    // this merge point. Re-LOAD to get dominating refs.
    if (state.refresh_stack_fn != c.IR_UNUSED) {
        refreshCachedStackPointer(state);
    }
    return .next;
}

fn emitIntrinsicLoop(ec: EmitCtx) IrCodegenError!ControlFlow {
    const state = ec.state;
    const stack = ec.stack;
    const sp = ec.sp;
    const ctx = state.ctx;

    if (sp.* < 1) return IrCodegenError.StackUnderflow;
    sp.* -= 1;
    const pred_entry = stack[sp.*];

    // Reify any quotation carried below the loop args before the header; see the
    // matching note in emitIntrinsicTimes.
    try materializeQuotations(state, stack, sp.*, true);

    // Flush user stack to physical memory before the loop
    flushToPhysicalStack(state, stack, sp.*);

    // Snapshot symbolic stack state at loop entry for
    // back-edge invariance checks.
    const loop_entry_stack = state.allocator.dupe(StackEntry, stack[0..sp.*]) catch return IrCodegenError.OutOfMemory;
    defer state.allocator.free(loop_entry_stack);
    const loop_entry_sp = sp.*;

    const pre_loop_sp_const = c.ir_const_addr(ctx, sp.*);
    const pre_loop_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, pre_loop_sp_const);
    c._ir_STORE(ctx, state.sp_ptr, pre_loop_sp);

    const entry_end = c._ir_END(ctx);
    const loop_ref = c._ir_LOOP_BEGIN(ctx, entry_end);
    state.recordBlockStart(loop_ref);
    // AOT loop back-edges can arrive after callbacks moved ctx.stack.items.
    // Refresh at the header so predicate slot accesses use the live base.
    if (state.aot_mode and state.refresh_stack_fn != c.IR_UNUSED) {
        refreshCachedStackPointer(state);
    }

    // Execute predicate body
    const pre_body_sp = sp.*;
    switch (pred_entry) {
        .quotation_body => |body| {
            resetStackToPhysicalPreservingRows(stack, sp.*);
            try compileInstructions(state, body, stack, sp);
        },
        .raw_at_slot => |s| {
            try emitIndirectQuotCall(state, stack, sp, s, ec.line);
            sp.* += 1; // predicate pushes one value (bool)
            resetStackToPhysicalPreservingRows(stack, sp.*);
        },
        else => {
            state.not_compilable_reason = .quotation_reification;
            return IrCodegenError.NotCompilable;
        },
    }

    // Pred should push a boolean on top
    if (sp.* < pre_body_sp + 1) return IrCodegenError.StackShapeMismatch;
    sp.* -= 1;
    const cond_entry = stack[sp.*];
    if (!symbolicShapeMatches(stack, sp.*, loop_entry_stack, loop_entry_sp)) return IrCodegenError.StackShapeMismatch;

    const continue_cond = try emitTruthiness(state, cond_entry, state.base_addr);

    flushToPhysicalStack(state, stack, sp.*);
    resetStackToPhysicalPreservingRows(stack, sp.*);

    const if_continue = c._ir_IF(ctx, continue_cond);
    c._ir_IF_TRUE(ctx, if_continue);
    emitSafepointCall(state);
    const loop_end = c._ir_LOOP_END(ctx);
    c.ir_set_op2(ctx, loop_ref, loop_end);

    c._ir_IF_FALSE(ctx, if_continue);

    // The safepoint on the IF_TRUE (continue) path updated
    // state.items_ptr/base_addr to IR refs that don't dominate
    // this exit path. Re-LOAD to get dominating refs.
    if (state.refresh_stack_fn != c.IR_UNUSED) {
        refreshCachedStackPointer(state);
    }
    return .next;
}

fn emitIntrinsicWhile(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitPredBodyLoopOp(ec, false);
}

fn emitIntrinsicUntil(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitPredBodyLoopOp(ec, true);
}

fn emitPredBodyLoopOp(ec: EmitCtx, is_until: bool) IrCodegenError!ControlFlow {
    const stack = ec.stack;
    const sp = ec.sp;
    if (sp.* < 2) return IrCodegenError.StackUnderflow;
    sp.* -= 2;
    const pred_entry = stack[sp.*];
    const body_entry = stack[sp.* + 1];
    try compilePredBodyLoop(ec.state, stack, sp, pred_entry, body_entry, is_until);
    return .next;
}

fn emitIntrinsicRecover(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitErrorHandlerCall(ec, ec.state.recover_fn, .recover);
}

fn emitIntrinsicCleanup(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitErrorHandlerCall(ec, ec.state.cleanup_fn, .cleanup);
}

fn emitErrorHandlerCall(ec: EmitCtx, callback_fn: c.ir_ref, frame_kind: BuiltinTraceFrameKind) IrCodegenError!ControlFlow {
    const state = ec.state;
    const stack = ec.stack;
    const sp = ec.sp;
    const ctx = state.ctx;

    if (sp.* < 2) return IrCodegenError.StackUnderflow;

    try materializeQuotations(state, stack, sp.*, false);
    flushToPhysicalStack(state, stack, sp.*);
    const ctx_val = emitCallbackPreamble(state, sp.*);

    const call_result = c._ir_CALL_1(ctx, c.IR_I32, callback_fn, ctx_val);
    emitCallbackPostCheck(state, call_result, call_result, null, .{ .builtin = .{ .kind = frame_kind, .line = ec.line } });

    sp.* -= 2;
    if (state.aot_mode and ec.idx != ec.instructions.len - 1) {
        // The handler callback ran a quotation whose row-variable
        // output makes the stack opaque, like with-parameter.
        // Collapse to a fresh row so the instructions that consume
        // its result keep compiling, rather than abandoning at the
        // next instruction. When the op is last, the word returns
        // through the live-sp path below instead.
        if (exitFallsThrough(state.exit_kind)) {
            reloadBaseAfterDynamicCall(state);
            sp.* = 1;
            stack[0] = .{ .row_region = state.nextRowId() };
        }
    } else {
        state.dynamic_call_emitted = true;
        state.error_handler_terminal = true;
    }
    return .next;
}

fn emitIntrinsicGet(ec: EmitCtx) IrCodegenError!ControlFlow {
    const state = ec.state;
    const stack = ec.stack;
    const sp = ec.sp;
    const ctx = state.ctx;

    if (sp.* < 1) return IrCodegenError.StackUnderflow;

    try materializeQuotations(state, stack, sp.*, false);
    flushToPhysicalStack(state, stack, sp.*);
    const ctx_val = emitCallbackPreamble(state, sp.*);

    const call_result = c._ir_CALL_1(ctx, c.IR_I32, state.get_fn, ctx_val);
    emitCallbackPostCheck(state, call_result, call_result, null, .none);

    // get: pops 1 param, pushes 1 value (net 0)
    settleRowAwareStack(state, stack, sp, 1, 1);
    return .next;
}

fn emitIntrinsicWithParameter(ec: EmitCtx) IrCodegenError!ControlFlow {
    const state = ec.state;
    const stack = ec.stack;
    const sp = ec.sp;
    const ctx = state.ctx;

    if (sp.* < 3) return IrCodegenError.StackUnderflow;

    try materializeQuotations(state, stack, sp.*, false);
    flushToPhysicalStack(state, stack, sp.*);
    const ctx_val = emitCallbackPreamble(state, sp.*);

    const call_result = c._ir_CALL_1(ctx, c.IR_I32, state.with_parameter_fn, ctx_val);
    emitCallbackPostCheck(state, call_result, call_result, null, .none);

    // NOTE(ripta): with-parameter: The body quotation's row-variable output
    //              makes the stack opaque after the call. Collapse to a fresh
    //              row_region so instructions that consume the body's result
    //              keep compiling above it.
    if (exitFallsThrough(state.exit_kind)) {
        reloadBaseAfterDynamicCall(state);
        sp.* = 1;
        stack[0] = .{ .row_region = state.nextRowId() };
    }
    return .next;
}

fn emitIntrinsicIterNext(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitIteratorOp(ec, .next);
}

fn emitIntrinsicIterCollect(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitIteratorOp(ec, .collect);
}

fn emitIntrinsicIterCount(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitIteratorOp(ec, .count);
}

fn emitIntrinsicCloseIterator(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitIteratorOp(ec, .close_iterator);
}

fn emitIntrinsicIterTake(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitIteratorOp(ec, .take);
}

fn emitIntrinsicIterDrop(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitIteratorOp(ec, .drop);
}

fn emitIntrinsicIterEach(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitIteratorOp(ec, .each);
}

fn emitIntrinsicIterMap(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitIteratorOp(ec, .map);
}

fn emitIntrinsicIterFilter(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitIteratorOp(ec, .filter);
}

fn emitIntrinsicIterReduce(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitIteratorOp(ec, .reduce);
}

fn emitIteratorOp(ec: EmitCtx, opcode: IteratorOpcode) IrCodegenError!ControlFlow {
    const state = ec.state;
    const stack = ec.stack;
    const sp = ec.sp;
    const ctx = state.ctx;

    const effects = iteratorEffects(opcode);
    if (sp.* < effects.inputs) return IrCodegenError.StackUnderflow;

    try materializeQuotations(state, stack, sp.*, false);
    flushToPhysicalStack(state, stack, sp.*);
    const ctx_val = emitCallbackPreamble(state, sp.*);

    if (effects.dynamic) {
        if (state.interp_ctx) |ictx| {
            if (ictx.lookupWordStackEffectPtr(ec.name)) |eff_ptr| {
                emitParamValidation(state, @intFromPtr(eff_ptr));
            }
        }
    }

    const opcode_const = c.ir_const_addr(ctx, @intFromEnum(opcode));
    const call_result = c._ir_CALL_2(ctx, c.IR_I32, state.iterator_fn, ctx_val, opcode_const);
    emitCallbackPostCheck(state, call_result, call_result, null, .none);

    settleRowAwareStack(state, stack, sp, effects.inputs, effects.outputs);
    return .next;
}

fn emitIntrinsicVirtualUnwrap(ec: EmitCtx) IrCodegenError!ControlFlow {
    // The inline emitter bakes a process-local VirtualType pointer
    // constant, so it is JIT-only. In AOT mode the preceding
    // .type_val literal is routed through the runtime-image slot
    // table and the native callback handles the rest.
    if (ec.state.aot_mode or !tryEmitInlineVirtualUnwrap(ec.state, ec.instructions, ec.idx, ec.stack, ec.sp)) {
        return emitNativeCallbackOp(ec);
    }
    return .next;
}

fn emitIntrinsicStructFieldGet(ec: EmitCtx) IrCodegenError!ControlFlow {
    // JIT-only inline emitter; AOT uses the native callback because the preceding .struct_type
    // literal goes through the runtime-image slot table. The inline emitter bakes a freeze-time
    // StructType pointer that does not match the runtime-image pointer across the process boundary.
    if (ec.state.aot_mode or !tryEmitInlineStructFieldGet(ec.state, ec.instructions, ec.idx, ec.stack, ec.sp)) {
        return emitNativeCallbackOp(ec);
    }
    return .next;
}

fn emitIntrinsicStructFieldSet(ec: EmitCtx) IrCodegenError!ControlFlow {
    // JIT-only inline emitter; AOT uses the native callback for the same freeze-time vs runtime-
    // image pointer mismatch reason as native.struct-field-get above.
    if (ec.state.aot_mode or !tryEmitInlineStructFieldSet(ec.state, ec.instructions, ec.idx, ec.stack, ec.sp)) {
        return emitNativeCallbackOp(ec);
    }
    return .next;
}

fn emitIntrinsicTypedValidateAndPromote(ec: EmitCtx) IrCodegenError!ControlFlow {
    // JIT-only inline emitter; AOT uses the native callback because the preceding .type_val
    // literal goes through the slot table.
    if (ec.state.aot_mode or !tryEmitInlineTypedValidateAndPromote(ec.state, ec.instructions, ec.idx, ec.stack, ec.sp)) {
        return emitNativeCallbackOp(ec);
    }
    return .next;
}

fn emitIntrinsicStructInstanceToHash(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitNativeCallbackOp(ec);
}

fn emitIntrinsicStructTypePredicate(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitNativeCallbackOp(ec);
}

fn emitIntrinsicHashToStruct(ec: EmitCtx) IrCodegenError!ControlFlow {
    return emitNativeCallbackOp(ec);
}

fn emitNativeCallbackOp(ec: EmitCtx) IrCodegenError!ControlFlow {
    try emitResolvedNativeCallback(ec.state, ec.name, ec.stack, ec.sp, ec.line);
    return .next;
}

/// Compile a sequence of instructions, updating the abstract stack.
/// Used both for top-level word bodies and for inlined quotation bodies.
fn compileInstructions(
    state: *CompileState,
    instructions: []const Instruction,
    stack: []StackEntry,
    sp: *usize,
) IrCodegenError!void {
    const ctx = state.ctx;

    for (instructions, 0..) |instr, idx| {
        emitAotInstrTrace(state, instr, stack, sp.*);
        if (state.dynamic_call_emitted) {
            state.not_compilable_reason = .post_dynamic_call;
            return IrCodegenError.NotCompilable;
        }

        if (instr.line != 0) {
            try state.flushPendingLine(@intCast(instr.line));
        }

        switch (instr.op) {
            .push_literal => |val| {
                if (val == .fixnum) {
                    stack[sp.*] = .{ .i64_ref = c.ir_const_i64(ctx, val.fixnum) };
                    sp.* += 1;
                } else if (val == .quotation) {
                    stack[sp.*] = .{ .quotation_body = val.quotation.instructions };
                    sp.* += 1;
                } else if (val == .float) {
                    stack[sp.*] = .{ .f64_ref = c.ir_const_double(ctx, val.float) };
                    sp.* += 1;
                } else if (val == .boolean) {
                    stack[sp.*] = .{ .bool_ref = c.ir_const_bool(ctx, val.boolean) };
                    sp.* += 1;
                } else if (state.aot_mode and (val == .string or val == .symbol) and state.aot_string_literals != null) {
                    // Construct the string- or symbol-literal Value directly at
                    // its destination slot: write the tag, the slice pointer,
                    // and the length via ValueLayout offsets. The slice payload
                    // points at the `onez_lit_N` static const char[] emitted in
                    // the C preamble, so there is no boundary crossing and no
                    // per-literal allocation -- the body lives in the binary's
                    // read-only section. This shifts ownership: the literal's
                    // backing memory now outlives its containing context rather
                    // than living in the per-context arena. That is safe because
                    // strings and symbols are both immutable and any operation
                    // needing an owned mutable copy already round-trips through
                    // an explicit conversion; nothing frees a string or symbol
                    // Value's slice. A symbol Value is structurally identical to
                    // a string Value -- same slice payload at the same offsets,
                    // only the tag differs -- so the same construction applies.
                    const lits = state.aot_string_literals.?;
                    const str_data = if (val == .string) val.string else val.symbol;
                    const lit_id = lits.items.len;

                    // The slice pointer is stored into a `uintptr_t` slot, and
                    // the C backend never casts a stored value. Build the symbol
                    // reference as the C expression `(uintptr_t)onez_lit_N` so
                    // the emitted store carries an explicit cast and the array
                    // (`const char[]`) does not trip `-Wint-conversion`. The C
                    // emitter prints a func const's name verbatim, which is how
                    // the bare `onez_lit_N` reference works elsewhere.
                    var sym_buf: [48]u8 = undefined;
                    const sym_name = std.fmt.bufPrint(&sym_buf, "(uintptr_t)onez_lit_{d}", .{lit_id}) catch unreachable;
                    const sym_ref = c.ir_const_func(ctx, c.ir_strl(ctx, &sym_buf, sym_name.len), 0);
                    const len_const = c.ir_const_addr(ctx, str_data.len);

                    // Derive the destination from a fresh items_ptr load rather
                    // than the cached base. A compiled loop body that contains a
                    // reallocating call is emitted once but re-entered after the
                    // back-edge refreshes the stack pointer; the cached base is
                    // the pre-loop value and would be stale on the second
                    // iteration. The fresh load is not CSE'd across the
                    // back-edge call barrier, so each iteration writes to the
                    // live buffer.
                    const dest_off = c.ir_const_addr(ctx, sp.* * ValueLayout.value_size);
                    const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), liveBaseAddr(state).base_addr, dest_off);
                    const slice_len_offset_const = c.ir_const_addr(ctx, ValueLayout.slice_len_offset);
                    emitBoxSlice(
                        ctx,
                        dest_addr,
                        state.tag_offset_const,
                        state.payload_offset_const,
                        slice_len_offset_const,
                        if (val == .string) emitTagConst(ctx, .string) else emitTagConst(ctx, .symbol),
                        sym_ref,
                        len_const,
                    );

                    // Record the literal so the C preamble emits its static array.
                    lits.append(std.heap.page_allocator, .{
                        .data = str_data,
                        .is_symbol = val == .symbol,
                    }) catch {};

                    stack[sp.*] = .{ .raw_at_slot = sp.* };
                    sp.* += 1;
                } else if (state.aot_mode and (val == .string or val == .symbol)) {
                    // In AOT mode, string/symbol literals can't be baked as
                    // raw bytes because they contain heap pointers. Emit a
                    // callback that pushes the literal using a C string
                    // constant embedded in the AOT binary.
                    const str_data = if (val == .string) val.string else val.symbol;
                    const push_fn_name = if (val == .string) "onez_push_string" else "onez_push_symbol";

                    // Use a 3-arg prototype for (ctx, str_ptr, str_len).
                    const proto_3arg = c.ir_proto_3(ctx, 0, c.IR_I32, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR);
                    const push_fn = c.ir_const_func(ctx, c.ir_str(ctx, push_fn_name), proto_3arg);

                    // Store sp before callback.
                    const sp_const = c.ir_const_addr(ctx, sp.*);
                    const new_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, sp_const);
                    c._ir_STORE(ctx, state.sp_ptr, new_sp);

                    const ctx_val = if (state.preloaded_ctx_val != c.IR_UNUSED)
                        state.preloaded_ctx_val
                    else blk: {
                        JitContextLayout.ensureInit();
                        const ctx_off = c.ir_const_addr(ctx, JitContextLayout.ctx_offset);
                        const ctx_addr2 = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
                        break :blk c._ir_LOAD(ctx, c.IR_ADDR, ctx_addr2);
                    };

                    // Reference the string via ir_const_sym. The symbol is
                    // defined as a static const char[] in emitProgramC.
                    const lit_id = if (state.aot_string_literals) |lits| lits.items.len else 0;
                    var sym_buf: [32]u8 = undefined;
                    const sym_name = std.fmt.bufPrint(&sym_buf, "onez_lit_{d}", .{lit_id}) catch unreachable;
                    // Use ir_const_func (not ir_const_sym) so the C emitter
                    // outputs the bare symbol name without the & prefix.
                    // The symbol resolves to a char[] which decays to char*.
                    const sym_ref = c.ir_const_func(ctx, c.ir_strl(ctx, &sym_buf, sym_name.len), 0);
                    const str_len_const = c.ir_const_addr(ctx, str_data.len);

                    const call_result = c._ir_CALL_3(ctx, c.IR_I32, push_fn, ctx_val, sym_ref, str_len_const);
                    emitCallbackPostCheck(state, call_result, state.error_propagate_status, null, .none);

                    // Record the literal for emission in the C preamble.
                    if (state.aot_string_literals) |lits| {
                        lits.append(std.heap.page_allocator, .{
                            .data = str_data,
                            .is_symbol = val == .symbol,
                        }) catch {};
                    }

                    // Re-read sp after callback (it pushed one value).
                    _ = c._ir_LOAD(ctx, c.IR_ADDR, state.sp_ptr);
                    stack[sp.*] = .{ .raw_at_slot = sp.* };
                    sp.* += 1;
                } else if (resolveTypedLiteralSlot(state, val)) |slot_info| {
                    // Slot-indexed typed-literal push. The runtime image's
                    // loader patches the slot table with the live runtime
                    // pointer; the helper resolves the slot through
                    // `Context.image_*_slots` and pushes the corresponding
                    // Value variant. All AOT artifact classes route every
                    // type-carrier literal (`.type_val`, `.struct_type`,
                    // `.marker`, `.parameter`, `.tagged`) through here;
                    // type-carrier literals that the freeze-time collection
                    // failed to intern fall through to the catch-all
                    // `non_serializable_literal` NotCompilable below.
                    const proto_2arg = c.ir_proto_2(ctx, 0, c.IR_I32, c.IR_ADDR, c.IR_ADDR);
                    const push_fn = c.ir_const_func(ctx, c.ir_str(ctx, slot_info.helper_name), proto_2arg);

                    // Store sp before callback.
                    const sp_const = c.ir_const_addr(ctx, sp.*);
                    const new_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, sp_const);
                    c._ir_STORE(ctx, state.sp_ptr, new_sp);

                    const ctx_val = if (state.preloaded_ctx_val != c.IR_UNUSED)
                        state.preloaded_ctx_val
                    else blk: {
                        JitContextLayout.ensureInit();
                        const ctx_off = c.ir_const_addr(ctx, JitContextLayout.ctx_offset);
                        const ctx_addr2 = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
                        break :blk c._ir_LOAD(ctx, c.IR_ADDR, ctx_addr2);
                    };

                    const slot_const = c.ir_const_addr(ctx, slot_info.slot);
                    const call_result = c._ir_CALL_2(ctx, c.IR_I32, push_fn, ctx_val, slot_const);
                    emitCallbackPostCheck(state, call_result, state.error_propagate_status, null, .none);

                    // Re-read sp after callback (it pushed one value).
                    _ = c._ir_LOAD(ctx, c.IR_ADDR, state.sp_ptr);
                    stack[sp.*] = .{ .raw_at_slot = sp.* };
                    sp.* += 1;
                } else if (state.aot_mode and (val == .array or val == .hash)) {
                    // Array/hash literals: serialize to bytes, store in C
                    // preamble, and emit a callback to deserialize at runtime.
                    // Pass the quotation-ID map so nested branch quotations carry
                    // their compiled global ID; jitPushArray attaches the matching
                    // code_ptr when reconstructing the composite at runtime.
                    var ser_buf: std.ArrayListUnmanaged(u8) = .{};
                    serializeValueInto(&ser_buf, val, std.heap.page_allocator, state.aot_quotation_id_map) catch {
                        state.not_compilable_reason = .non_serializable_literal;
                        return IrCodegenError.NotCompilable;
                    };
                    const serialized = ser_buf.items;

                    const lit_id = if (state.aot_array_literals) |lits| lits.items.len else 0;

                    if (state.aot_array_literals) |lits| {
                        lits.append(std.heap.page_allocator, .{ .data = serialized }) catch {};
                    }

                    const proto_3arg = c.ir_proto_3(ctx, 0, c.IR_I32, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR);
                    const push_fn = c.ir_const_func(ctx, c.ir_str(ctx, "onez_push_array"), proto_3arg);

                    // Store sp before callback.
                    const sp_const = c.ir_const_addr(ctx, sp.*);
                    const new_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, sp_const);
                    c._ir_STORE(ctx, state.sp_ptr, new_sp);

                    const ctx_val = if (state.preloaded_ctx_val != c.IR_UNUSED)
                        state.preloaded_ctx_val
                    else blk: {
                        JitContextLayout.ensureInit();
                        const ctx_off = c.ir_const_addr(ctx, JitContextLayout.ctx_offset);
                        const ctx_addr2 = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
                        break :blk c._ir_LOAD(ctx, c.IR_ADDR, ctx_addr2);
                    };

                    var sym_buf: [32]u8 = undefined;
                    const sym_name = std.fmt.bufPrint(&sym_buf, "onez_arr_{d}", .{lit_id}) catch unreachable;
                    const sym_ref = c.ir_const_func(ctx, c.ir_strl(ctx, &sym_buf, sym_name.len), 0);
                    const data_len_const = c.ir_const_addr(ctx, serialized.len);

                    const call_result = c._ir_CALL_3(ctx, c.IR_I32, push_fn, ctx_val, sym_ref, data_len_const);
                    emitCallbackPostCheck(state, call_result, state.error_propagate_status, null, .none);

                    // Re-read sp after callback (it pushed one value).
                    _ = c._ir_LOAD(ctx, c.IR_ADDR, state.sp_ptr);
                    stack[sp.*] = .{ .raw_at_slot = sp.* };
                    sp.* += 1;
                } else if (state.aot_mode) {
                    // Remaining non-simple literals that cannot be
                    // reconstructed from a named word lookup.
                    state.not_compilable_reason = .non_serializable_literal;
                    return IrCodegenError.NotCompilable;
                } else {
                    const dest_addr = liveSlotAddr(state, sp.*);
                    emitPushValue(ctx, &val, dest_addr);
                    // A literal that carries a refcounted backing (a `.vector`,
                    // `.mutable_map`, or `.hash`, or an `.array`/`.set` holding
                    // one) is raw-copied here, so the new slot must retain to
                    // match the consumer's release; the dictionary release list
                    // owns the literal's own reference and frees it at teardown.
                    if (container_backing.valueCarriesBacking(val)) {
                        emitRetainSlot(state, sp.*);
                    }
                    stack[sp.*] = .{ .raw_at_slot = sp.* };
                    sp.* += 1;
                }
            },
            .call_word, .call_word_direct => {
                const name = instr.op.callTargetName().?;
                if (intrinsic_table.get(name)) |entry| {
                    switch (try entry.handler(.{
                        .state = state,
                        .instructions = instructions,
                        .idx = idx,
                        .name = name,
                        .stack = stack,
                        .sp = sp,
                        .line = instr.line,
                    })) {
                        // `next` falls out to the shared per-iteration epilogue
                        // below (the `peak_sp` update and the `exitFallsThrough`
                        // break), the same path the inline arms took.
                        .next => {},
                        .stop => break,
                    }
                } else if (
                // oh, yuck
                state.self_name != null and
                    state.loop_begin_ref != c.IR_UNUSED and
                    idx == instructions.len - 1 and
                    std.mem.eql(u8, name, state.self_name.?))
                {
                    // Self-recursive tail call: emit back-edge to LOOP_BEGIN
                    const ic = state.input_count;
                    // When a symbolic row sits under the call the physical depth
                    // is unknown, so the loop-back-edge argument copy cannot be
                    // laid out. Emit an ordinary recursive call against the live
                    // stack and collapse to a row instead.
                    if (state.aot_mode and (sp.* < ic or hasRowRegion(stack, sp.*))) {
                        // Bounded-row drift guard: a tail recursion consuming `ic` inputs cannot
                        // leave more than `ic` tracked entries above a bounded row.
                        //
                        // The surplus strands above the row and accumulates every iteration. When
                        // the abstract stack is a single row pinned at slot 0 with more than `ic`
                        // concrete entries above it, the body is not stack-neutral across the row;
                        // emitting the recursive call against the live stack would miscompile into
                        // a growing stack that faults at runtime, so reject cleanly.
                        const row_at_slot0 = sp.* > 1 and stack[0].isRowRegion() and !hasRowRegion(stack[1..sp.*], sp.* - 1);
                        if (row_at_slot0 and sp.* - 1 > @as(usize, ic)) {
                            return IrCodegenError.StackShapeMismatch;
                        }

                        // Preserved-`ic` shape: a row pinned at slot 0 with exactly `ic` concrete
                        // entries above it.
                        //
                        // This is the stack-neutral row-bearing recursion that a true loopback-edge
                        // can carry. When the row-aware loop entry is in effect (pass 2), emit the O(1)
                        // back-edge that rebases around the row; otherwise record the shape for the
                        // two-pass driver and keep the ordinary-recursion fallback.
                        //
                        // Partial collapses (`< ic` above the row) and the fully collapsed shape
                        // (`sp == 1`) keep ordinary recursion.
                        if (row_at_slot0 and sp.* - 1 == @as(usize, ic)) {
                            if (state.row_aware_loop) {
                                try emitRowAwareSelfTailCall(state, stack, sp);
                                break;
                            }
                            state.row_aware_loop_detected = true;
                        }

                        const res = state.resolver orelse {
                            state.not_compilable_reason = .unresolvable_word;
                            return IrCodegenError.NotCompilable;
                        };

                        const resolved = res.resolve(name, res.user_data) orelse {
                            state.not_compilable_reason = .unresolvable_word;
                            return IrCodegenError.NotCompilable;
                        };

                        if (try emitDynamicRowFallback(state, stack, sp, name, resolved, instr.line)) continue;
                        break;
                    }

                    if (sp.* < ic) return IrCodegenError.StackUnderflow;

                    // Bail if both if-branches already set a loop end
                    if (state.loop_end_set) {
                        state.not_compilable_reason = .nested_loop_conflict;
                        return IrCodegenError.NotCompilable;
                    }

                    // Reify a literal quotation passed as a recursive-call argument
                    // before the flush. flushToPhysicalStack skips quotation_body, so
                    // without this the argument copy below would read an unwritten slot.
                    try materializeQuotations(state, stack, sp.*, true);

                    // Flush symbolic stack to physical memory
                    flushToPhysicalStack(state, stack, sp.*);

                    // Copy new arguments to input slots (positions 0..input_count-1)
                    const arg_base = sp.* - ic;
                    if (arg_base > 0) {
                        for (0..ic) |i| {
                            emitCopySlot(ctx, state.base_addr, arg_base + i, i);
                        }
                    }

                    // Reset sp to its original value (the word always starts
                    // with sp_val items on the physical stack)
                    c._ir_STORE(ctx, state.sp_ptr, state.sp_val);

                    // Safepoint before looping back
                    emitSafepointCall(state);

                    // Emit back-edge
                    const loop_end = c._ir_LOOP_END(ctx);
                    c.ir_set_op2(ctx, state.loop_begin_ref, loop_end);
                    state.loop_end_set = true;
                    state.exit_kind = .loop_diverged;

                    // Reset abstract stack for code after this point
                    // (unreachable, but keeps state consistent)
                    sp.* = ic;
                    resetStackToPhysical(stack, sp.*);
                } else if (state.mutual_group != null and
                    idx == instructions.len - 1 and
                    isMutualGroupMember(state.mutual_group.?, name) and
                    (state.self_name == null or !std.mem.eql(u8, name, state.self_name.?)))
                {
                    // Mutual recursion trampoline: flush stack, set target, return 3
                    const ic = state.input_count;
                    if (sp.* < ic) return IrCodegenError.StackUnderflow;

                    flushToPhysicalStack(state, stack, sp.*);

                    // Copy new arguments to input slots
                    const arg_base = sp.* - ic;
                    if (arg_base > 0) {
                        for (0..ic) |i| {
                            emitCopySlot(ctx, state.base_addr, arg_base + i, i);
                        }
                    }

                    // Reset sp to original value
                    c._ir_STORE(ctx, state.sp_ptr, state.sp_val);

                    // Resolve target word_id and store on JitContext
                    const res = state.resolver orelse {
                        state.not_compilable_reason = .unresolvable_word;
                        return IrCodegenError.NotCompilable;
                    };
                    const resolved = res.resolve(name, res.user_data) orelse {
                        state.not_compilable_reason = .unresolvable_word;
                        return IrCodegenError.NotCompilable;
                    };

                    JitContextLayout.ensureInit();
                    const tramp_off = c.ir_const_addr(ctx, JitContextLayout.trampoline_target_offset);
                    const tramp_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, tramp_off);
                    const target_const = c.ir_const_u32(ctx, resolved.word_id);
                    c._ir_STORE(ctx, tramp_addr, target_const);

                    c._ir_RETURN(ctx, state.trampoline_status);
                    state.exit_kind = .terminal_return;

                    sp.* = ic;
                    resetStackToPhysical(stack, sp.*);
                } else {
                    // Unrecognized word: try dispatch table call if a resolver is available
                    const res = state.resolver orelse {
                        state.not_compilable_reason = .unresolvable_word;
                        return IrCodegenError.NotCompilable;
                    };
                    const resolved = res.resolve(name, res.user_data) orelse {
                        state.not_compilable_reason = .unresolvable_word;
                        return IrCodegenError.NotCompilable;
                    };

                    // Literal-count `array-n` folds to a concrete-arity array construction: the count
                    // names exactly how many elements the native consumes, so emit the native against
                    // the live stack and settle the abstract stack with concrete in / out counts
                    // instead of collapsing to an opaque row_region. A row sitting below the packed
                    // elements is preserved by settleRowAwareStack. A non-literal runtime count
                    // falls through to the unchanged row-variable handling below.
                    if (resolved.is_native and std.mem.eql(u8, name, "array-n")) {
                        if (extractPrecedingLiteralDepth(instructions, idx)) |count| {
                            const effective_in = count + 1;
                            if (sp.* < effective_in) return IrCodegenError.StackUnderflow;
                            try materializeQuotations(state, stack, sp.*, false);
                            flushToPhysicalStack(state, stack, sp.*);
                            const ctx_val = emitCallbackPreamble(state, sp.*);
                            emitNativeWordCall(state, ctx_val, name, resolved, instr.line);
                            if (exitFallsThrough(state.exit_kind)) {
                                settleRowAwareStack(state, stack, sp, effective_in, 1);
                            }
                            continue;
                        }
                    }

                    const ec = EmitCtx{
                        .state = state,
                        .instructions = instructions,
                        .idx = idx,
                        .name = name,
                        .stack = stack,
                        .sp = sp,
                        .line = instr.line,
                    };
                    switch (try emitGenericResolvedNativeCall(ec, resolved)) {
                        .next => {},
                        .stop => break,
                    }
                }
            },
        }

        if (sp.* > state.peak_sp) state.peak_sp = @intCast(sp.*);
        if (!exitFallsThrough(state.exit_kind)) break;
    }
}

/// Bundle of all inputs needed by a compiled function. Passed as a single
/// pointer to avoid the aarch64 IR backend miscompilation with 4+ parameters.
/// Uses extern struct for C-compatible layout with predictable field offsets.
pub const JitContext = extern struct {
    items_ptr: [*]Value,
    sp_ptr: *usize,
    capacity: usize,
    ctx: *anyopaque,
    trampoline_target: u32 = 0,
};

/// Layout offsets for JitContext fields, discovered at runtime.
const JitContextLayout = struct {
    var sp_ptr_offset: usize = 0;
    var capacity_offset: usize = 0;
    var ctx_offset: usize = 0;
    var trampoline_target_offset: usize = 0;
    var initialized: bool = false;

    fn ensureInit() void {
        if (initialized) return;

        var dummy: JitContext = undefined;
        const base: usize = @intFromPtr(&dummy);
        sp_ptr_offset = @intFromPtr(&dummy.sp_ptr) - base;
        capacity_offset = @intFromPtr(&dummy.capacity) - base;
        ctx_offset = @intFromPtr(&dummy.ctx) - base;
        trampoline_target_offset = @intFromPtr(&dummy.trampoline_target) - base;
        initialized = true;
    }
};

/// The compiled function signature: takes a single JitContext pointer.
pub const CompiledFn = *const fn (*JitContext) callconv(.c) i32;

fn isMutualGroupMember(group: []const []const u8, name: []const u8) bool {
    for (group) |member| {
        if (std.mem.eql(u8, member, name)) return true;
    }
    return false;
}

/// Check whether any tail-position instruction is a self-call.
/// "Tail position" means last instruction of the sequence, or last instruction
/// inside a quotation argument to an `if` that is itself in tail position.
fn hasSelfTailCall(instructions: []const Instruction, self_name: []const u8) bool {
    if (instructions.len == 0) return false;
    const last = instructions[instructions.len - 1];
    switch (last.op) {
        .call_word, .call_word_direct => {
            const name = last.op.callTargetName().?;
            if (std.mem.eql(u8, name, self_name)) return true;
            if (std.mem.eql(u8, name, "if")) {
                // Check the two quotation literals preceding `if`
                if (instructions.len < 3) return false;
                const true_instr = instructions[instructions.len - 3];
                const false_instr = instructions[instructions.len - 2];
                const true_body = switch (true_instr.op) {
                    .push_literal => |v| if (v == .quotation) v.quotation.instructions else return false,
                    else => return false,
                };
                const false_body = switch (false_instr.op) {
                    .push_literal => |v| if (v == .quotation) v.quotation.instructions else return false,
                    else => return false,
                };
                return hasSelfTailCall(true_body, self_name) or hasSelfTailCall(false_body, self_name);
            }
            return false;
        },
        .push_literal => return false,
    }
}

const PreScanFlags = struct {
    needs_dispatch: bool = false,
    needs_safepoint: bool = false,
    needs_error_handling: bool = false,
    needs_dynamic_vars: bool = false,
    needs_iterators: bool = false,
    needs_native_call: bool = false,
    needs_param_validation: bool = false,
    needs_poly_fallback: bool = false,
    needs_pic_dispatch: bool = false,
    needs_satisfies_dispatch: bool = false,

    fn needsErrorPropagation(self: PreScanFlags) bool {
        return self.needs_error_handling or self.needs_safepoint or
            self.needs_dynamic_vars or self.needs_iterators or
            self.needs_native_call or self.needs_dispatch or
            self.needs_param_validation or self.needs_poly_fallback or
            self.needs_satisfies_dispatch;
    }

    /// Merge an intrinsic's static pre-scan capabilities into these flags.
    fn applyCaps(self: *PreScanFlags, caps: PreScanCaps) void {
        if (caps.needs_safepoint) self.needs_safepoint = true;
        if (caps.needs_error_handling) self.needs_error_handling = true;
        if (caps.needs_dynamic_vars) self.needs_dynamic_vars = true;
        if (caps.needs_iterators) self.needs_iterators = true;
        if (caps.needs_param_validation) self.needs_param_validation = true;
        if (caps.needs_dispatch) self.needs_dispatch = true;
        if (caps.needs_poly_fallback) self.needs_poly_fallback = true;
        if (caps.needs_native_call) self.needs_native_call = true;
    }
};

/// Recursively scan instructions and quotation bodies for dispatch calls
/// and loop ops.
fn preScanInstructions(
    instructions: []const Instruction,
    resolver: ?WordResolver,
    flags: *PreScanFlags,
    in_quotation: bool,
) IrCodegenError!void {
    for (instructions) |instr| {
        switch (instr.op) {
            .push_literal => |val| {
                if (val == .quotation) {
                    try preScanInstructions(val.quotation.instructions, resolver, flags, true);
                }
            },
            .call_word, .call_word_direct => {
                const name = instr.op.callTargetName().?;
                if (intrinsic_table.get(name)) |entry| {
                    flags.applyCaps(entry.caps);
                } else {
                    if (resolver) |res| {
                        if (res.resolve(name, res.user_data)) |resolved| {
                            if (resolved.is_native) {
                                flags.needs_native_call = true;
                            } else {
                                flags.needs_dispatch = true;
                            }
                            if (resolved.stack_effect_ptr != null) {
                                flags.needs_param_validation = true;
                            }
                            if (resolved.bounded_constraint != null) {
                                flags.needs_satisfies_dispatch = true;
                            }
                        } else if (!in_quotation) {
                            return IrCodegenError.NotCompilable;
                        }
                    } else if (!in_quotation) {
                        return IrCodegenError.NotCompilable;
                    }
                }
            },
        }
    }
}

/// Whether `target` is defined by a nested `name: [ ... ] ;` statement inside
/// this flat body. `nativeSemicolon` pops the body quotation then the name
/// symbol, so a nested definition reads as `push_literal symbol(name)` ...
/// `push_literal quotation(body)` ... `call_word ";"`; the defined name is the
/// most recent symbol literal before that `;`, since the quotation, marker, and
/// doc pushes in between are not symbols. The pending name resets at each `;` so
/// it never leaks across definition statements.
fn isNestedDefinedName(instructions: []const Instruction, target: []const u8) bool {
    var pending_name: ?[]const u8 = null;
    for (instructions) |instr| {
        switch (instr.op) {
            .push_literal => |val| {
                if (val == .symbol) pending_name = val.symbol;
            },
            .call_word, .call_word_direct => {
                const cname = instr.op.callTargetName() orelse continue;
                if (std.mem.eql(u8, cname, ";")) {
                    if (pending_name) |pn| {
                        if (std.mem.eql(u8, pn, target)) return true;
                    }
                    pending_name = null;
                }
            },
        }
    }
    return false;
}

/// Find a callee in `instructions` that is defined by a nested `;` statement in
/// the same body. Returns the helper's name, or null when the body calls no
/// such helper. Drives both the per-word compile gate (the word must run
/// interpreted) and the build diagnostic that names the helper and recommends a
/// `private{ }` block. The returned slice borrows from the instruction stream.
///
/// A nested helper shadows any global word of the same name within the body, but
/// compiled codegen resolves calls through the global-only resolver and cannot
/// bind to the nested local; a same-named global (e.g. a generated struct
/// converter) would otherwise be mis-bound, silently changing behavior. So a
/// nested-defined callee is flagged even when a global namesake resolves, not
/// only when the name is otherwise unresolvable.
fn findUndiscoverableNestedDef(
    instructions: []const Instruction,
) ?[]const u8 {
    for (instructions) |instr| {
        switch (instr.op) {
            .call_word, .call_word_direct => {
                const name = instr.op.callTargetName() orelse continue;
                if (std.mem.eql(u8, name, ";")) continue;
                if (intrinsic_table.has(name) and !isIndexedStackOp(name)) continue;
                if (isNestedDefinedName(instructions, name)) return name;
            },
            .push_literal => {},
        }
    }
    return null;
}

/// Compile a word's instruction sequence into native code via the ir JIT.
/// The compiled function operates directly on the per-task Value stack.
/// Supports push_literal of any Value variant and call_word of supported
/// arithmetic ops (arithmetic still requires fixnum operands at runtime).
///
/// Runs two internal passes so the prologue capacity check can see the final
/// peak stack depth as an IR constant. Pass 1 discovers `peak_sp` by emitting
/// the body into a throwaway IR context; pass 2 emits the prologue check
/// using that peak and JIT-compiles the result.
pub fn compileWord(
    instructions: []const Instruction,
    input_count: u8,
    output_count: u8,
    resolver: ?WordResolver,
    self_name: ?[]const u8,
    interp_ctx: ?*const Context,
    mutual_group: ?[]const []const u8,
    stack_effect: ?*const StackEffect,
) IrCodegenError!CompiledWord {
    return compileWordWithPicSnapshot(instructions, input_count, output_count, resolver, self_name, null, interp_ctx, mutual_group, stack_effect);
}

pub fn compileWordWithPicSnapshot(
    instructions: []const Instruction,
    input_count: u8,
    output_count: u8,
    resolver: ?WordResolver,
    self_name: ?[]const u8,
    pic_table: ?*pic_mod.PicTable,
    interp_ctx: ?*const Context,
    mutual_group: ?[]const []const u8,
    stack_effect: ?*const StackEffect,
) IrCodegenError!CompiledWord {
    const discovered = try compileWordPass(instructions, input_count, output_count, resolver, self_name, pic_table, interp_ctx, mutual_group, stack_effect, null, false);
    const second = try compileWordPass(instructions, input_count, output_count, resolver, self_name, pic_table, interp_ctx, mutual_group, stack_effect, discovered.peak_stack_depth, discovered.row_aware_self_loop);
    return second.compiled orelse IrCodegenError.CompilationFailed;
}

const CompileWordPassResult = struct {
    compiled: ?CompiledWord,
    peak_stack_depth: u32,
    row_aware_self_loop: bool = false,
};

fn compileWordPass(
    instructions: []const Instruction,
    input_count: u8,
    output_count: u8,
    resolver: ?WordResolver,
    self_name: ?[]const u8,
    pic_table: ?*pic_mod.PicTable,
    interp_ctx: ?*const Context,
    mutual_group: ?[]const []const u8,
    stack_effect: ?*const StackEffect,
    known_peak: ?u32,
    row_aware_self_loop: bool,
) IrCodegenError!CompileWordPassResult {
    ValueLayout.ensureInit();

    // Pre-scan: check if any call_word needs dispatch table resolution
    // or contains loops (which need safepoints).
    var scan_flags = PreScanFlags{};
    try preScanInstructions(instructions, resolver, &scan_flags, false);

    var ctx: c.ir_ctx = undefined;
    c.ir_init(&ctx, c.IR_FUNCTION | c.IR_OPT_FOLDING, c.IR_CONSTS_LIMIT_MIN, c.IR_INSNS_LIMIT_MIN);
    defer c.ir_free(&ctx);

    c._ir_START(&ctx);

    JitContextLayout.ensureInit();

    // Single parameter: pointer to JitContext struct
    const jit_ctx_ptr = c._ir_PARAM(&ctx, c.IR_ADDR, "jit_ctx", 1);

    // Load fields from the JitContext struct
    const items_ptr = c._ir_LOAD(&ctx, c.IR_ADDR, jit_ctx_ptr);
    const sp_ptr_off = c.ir_const_addr(&ctx, JitContextLayout.sp_ptr_offset);
    const sp_ptr_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), jit_ctx_ptr, sp_ptr_off);
    const sp_ptr = c._ir_LOAD(&ctx, c.IR_ADDR, sp_ptr_addr);
    const cap_off = c.ir_const_addr(&ctx, JitContextLayout.capacity_offset);
    const cap_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), jit_ctx_ptr, cap_off);
    const capacity_param = c._ir_LOAD(&ctx, c.IR_ADDR, cap_addr);

    // Bake dispatch table pointer as a constant if dispatch calls are needed.
    const dispatch_ptr = if (scan_flags.needs_dispatch)
        c.ir_const_addr(&ctx, @intFromPtr(resolver.?.dispatch_table_ptr))
    else
        c.IR_UNUSED;

    // Bake safepoint function pointer as a constant if loops are present.
    const safepoint_fn = if (scan_flags.needs_safepoint)
        c.ir_const_addr(&ctx, @intFromPtr(&jitSafepoint))
    else
        c.IR_UNUSED;

    // Bake error handling callback pointers if recover/cleanup are used.
    const recover_fn = if (scan_flags.needs_error_handling)
        c.ir_const_addr(&ctx, @intFromPtr(&jitRecover))
    else
        c.IR_UNUSED;
    const cleanup_fn = if (scan_flags.needs_error_handling)
        c.ir_const_addr(&ctx, @intFromPtr(&jitCleanup))
    else
        c.IR_UNUSED;

    const get_fn = if (scan_flags.needs_dynamic_vars)
        c.ir_const_addr(&ctx, @intFromPtr(&jitGet))
    else
        c.IR_UNUSED;
    const with_parameter_fn = if (scan_flags.needs_dynamic_vars)
        c.ir_const_addr(&ctx, @intFromPtr(&jitWithParameter))
    else
        c.IR_UNUSED;

    const iterator_fn = if (scan_flags.needs_iterators)
        c.ir_const_addr(&ctx, @intFromPtr(&jitIteratorOp))
    else
        c.IR_UNUSED;

    const native_call_fn = if (scan_flags.needs_native_call or scan_flags.needs_poly_fallback)
        c.ir_const_addr(&ctx, @intFromPtr(&jitNativeCall))
    else
        c.IR_UNUSED;

    const interpreted_call_fn = if (scan_flags.needs_dispatch or scan_flags.needs_poly_fallback)
        c.ir_const_addr(&ctx, @intFromPtr(&jitInterpretedCall))
    else
        c.IR_UNUSED;

    // JIT mode never emits jitNativeWordCall: native words use jitNativeCall
    // with a baked function pointer instead. The CompileState field is
    // present for parity with AOT mode but stays IR_UNUSED here.
    const native_word_call_fn: c.ir_ref = c.IR_UNUSED;

    // Error-reporting callbacks: set jit_pending_error and return 2.
    const type_mismatch_error_fn = c.ir_const_addr(&ctx, @intFromPtr(&jitTypeMismatchError));
    const overflow_error_fn = c.ir_const_addr(&ctx, @intFromPtr(&jitOverflowError));
    const div_zero_error_fn = c.ir_const_addr(&ctx, @intFromPtr(&jitDivisionByZeroError));
    const underflow_error_fn = c.ir_const_addr(&ctx, @intFromPtr(&jitStackUnderflowError));
    const append_word_trace_frame_fn = c.ir_const_addr(&ctx, @intFromPtr(&jitAppendNamedTraceFrame));
    const append_builtin_trace_frame_fn = c.ir_const_addr(&ctx, @intFromPtr(&jitAppendBuiltinTraceFrame));

    // jitRefreshStack is emitted unconditionally: any callback in the body
    // may reallocate ctx.stack, so emitCallbackPostCheck refreshes regardless
    // of which callbacks the pre-scan flagged.
    const refresh_stack_fn = c.ir_const_addr(&ctx, @intFromPtr(&jitRefreshStack));

    // Refcount slot helpers are emitted at logical duplication / discard sites
    // for refcounted container backings. Unconditional like jitRefreshStack:
    // any `.raw_at_slot` value may carry a backing.
    const retain_slot_fn = c.ir_const_addr(&ctx, @intFromPtr(&jitRetainSlot));
    const release_slot_fn = c.ir_const_addr(&ctx, @intFromPtr(&jitReleaseSlot));

    // jitEnsureStackCapacity grows ctx.stack to cover the word's peak depth
    // when the capacity reserved by executeCompiled is insufficient. Needed
    // because compiled-to-compiled recursion bypasses executeCompiled's
    // capacity check, so each compiled entry re-validates.
    const ensure_cap_fn = c.ir_const_addr(&ctx, @intFromPtr(&jitEnsureStackCapacity));

    const validate_params_fn = if (scan_flags.needs_param_validation)
        c.ir_const_addr(&ctx, @intFromPtr(&jitValidateParamEffects))
    else
        c.IR_UNUSED;

    const satisfies_dispatch_fn = if (scan_flags.needs_satisfies_dispatch)
        c.ir_const_addr(&ctx, @intFromPtr(&jitSatisfiesAndDispatch))
    else
        c.IR_UNUSED;

    const satisfies_dispatch_combinator_fn = if (scan_flags.needs_satisfies_dispatch)
        c.ir_const_addr(&ctx, @intFromPtr(&jitSatisfiesAndDispatchCombinator))
    else
        c.IR_UNUSED;

    const bail_status = c.ir_const_i32(&ctx, 1);
    const ok_status = c.ir_const_i32(&ctx, 0);
    const error_propagate_status = c.ir_const_i32(&ctx, 2);

    // Load current stack depth
    const sp_val = c._ir_LOAD(&ctx, c.IR_ADDR, sp_ptr);

    // Prologue capacity check: unconditionally call jitEnsureStackCapacity to
    // grow the stack if sp + peak_stack_depth exceeds the current capacity.
    // The helper is a fast no-op when capacity already suffices. An
    // unconditional call avoids the PHI / diamond control flow that can
    // interact badly with the register allocator. known_peak is null on the
    // discovery pass and non-null on the emission pass.
    var items_ptr_after_check = items_ptr;
    if (known_peak) |peak| {
        if (peak > 0) {
            const peak_const = c.ir_const_addr(&ctx, peak);
            const needed = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), sp_val, peak_const);
            const ensure_status = c._ir_CALL_2(&ctx, c.IR_I32, ensure_cap_fn, jit_ctx_ptr, needed);
            const ensure_failed = c.ir_fold2(&ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), ensure_status, ok_status);
            const if_oom = c._ir_IF(&ctx, ensure_failed);
            c._ir_IF_TRUE_cold(&ctx, if_oom);
            // jitEnsureStackCapacity returns 2 (error_propagate) on OOM.
            c._ir_RETURN(&ctx, ensure_status);
            c._ir_IF_FALSE(&ctx, if_oom);
            // Re-LOAD items_ptr after the call. IR treats calls as memory
            // clobbers, so this LOAD is not CSE'd against the original.
            items_ptr_after_check = c._ir_LOAD(&ctx, c.IR_ADDR, jit_ctx_ptr);
        }
    }

    // Check stack has enough values (sp >= input_count)
    if (input_count > 0) {
        const min_sp = c.ir_const_addr(&ctx, input_count);
        const sp_too_small = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ULT, c.IR_BOOL), sp_val, min_sp);
        const if_underflow = c._ir_IF(&ctx, sp_too_small);
        c._ir_IF_TRUE_cold(&ctx, if_underflow);
        c._ir_RETURN(&ctx, bail_status);
        c._ir_IF_FALSE(&ctx, if_underflow);
    }

    // Layout constants
    const value_size_const = c.ir_const_addr(&ctx, ValueLayout.value_size);
    const tag_offset_const = c.ir_const_addr(&ctx, ValueLayout.tag_offset);
    const payload_offset_const = c.ir_const_addr(&ctx, ValueLayout.payload_offset);
    const fixnum_tag_const = emitTagConst(&ctx, .fixnum);
    const float_tag_const = emitTagConst(&ctx, .float);
    const boolean_tag_const = emitTagConst(&ctx, .boolean);
    const tagged_tag_const = emitTagConst(&ctx, .tagged);
    const struct_instance_tag_const = emitTagConst(&ctx, .struct_instance);

    // Precompute the base address for output writes:
    // base_addr = items_ptr + (sp_val - input_count) * value_size
    const input_count_const = c.ir_const_addr(&ctx, input_count);
    const base_idx = c.ir_fold2(&ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), sp_val, input_count_const);
    const base_byte_offset = c.ir_fold2(&ctx, c.IR_OPT(c.IR_MUL, c.IR_ADDR), base_idx, value_size_const);
    const base_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), items_ptr_after_check, base_byte_offset);

    // Initialize inputs as raw_at_slot entries. Tag checking and unboxing
    // happen lazily at use sites (e.g., when arithmetic needs a fixnum).
    const stack_alloc = std.heap.page_allocator;
    // The row-aware loop entry pins an extra row slot at the bottom, shifting
    // every abstract entry up by one, so its peak is one above the no-row peak
    // discovered on pass 1. Physical capacity is unchanged (the `-1` in
    // `base_idx` offsets the `+1` in sp), so only the buffer grows.
    const stack_depth: usize = (if (known_peak) |peak| @as(usize, peak) else estimateStackDepth(instructions, input_count)) + @intFromBool(row_aware_self_loop);
    const stack = stack_alloc.alloc(StackEntry, stack_depth) catch return IrCodegenError.OutOfMemory;
    defer stack_alloc.free(stack);
    var sp: usize = 0;
    for (0..input_count) |_| {
        stack[sp] = .{ .raw_at_slot = sp };
        sp += 1;
    }

    var state = CompileState{
        .allocator = stack_alloc,
        .ctx = &ctx,
        .base_addr = base_addr,
        .tag_offset_const = tag_offset_const,
        .payload_offset_const = payload_offset_const,
        .fixnum_tag_const = fixnum_tag_const,
        .float_tag_const = float_tag_const,
        .boolean_tag_const = boolean_tag_const,
        .tagged_tag_const = tagged_tag_const,
        .struct_instance_tag_const = struct_instance_tag_const,
        .bail_status = bail_status,
        .ok_status = ok_status,
        .items_ptr = items_ptr_after_check,
        .sp_ptr = sp_ptr,
        .capacity_param = capacity_param,
        .sp_val = sp_val,
        .base_idx = base_idx,
        .value_size_const = value_size_const,
        .dispatch_ptr = dispatch_ptr,
        .resolver = resolver,
        .jit_ctx_ptr = jit_ctx_ptr,
        .safepoint_fn = safepoint_fn,
        .recover_fn = recover_fn,
        .cleanup_fn = cleanup_fn,
        .get_fn = get_fn,
        .with_parameter_fn = with_parameter_fn,
        .iterator_fn = iterator_fn,
        .native_call_fn = native_call_fn,
        .interpreted_call_fn = interpreted_call_fn,
        .native_word_call_fn = native_word_call_fn,
        .refresh_stack_fn = refresh_stack_fn,
        .retain_slot_fn = retain_slot_fn,
        .release_slot_fn = release_slot_fn,
        .validate_params_fn = validate_params_fn,
        .satisfies_dispatch_fn = satisfies_dispatch_fn,
        .satisfies_dispatch_combinator_fn = satisfies_dispatch_combinator_fn,
        .interp_ctx = interp_ctx,
        .pic_table = pic_table,
        .error_propagate_status = error_propagate_status,
        .type_mismatch_error_fn = type_mismatch_error_fn,
        .overflow_error_fn = overflow_error_fn,
        .div_zero_error_fn = div_zero_error_fn,
        .underflow_error_fn = underflow_error_fn,
        .append_word_trace_frame_fn = append_word_trace_frame_fn,
        .append_builtin_trace_frame_fn = append_builtin_trace_frame_fn,
        .peak_sp = @intCast(input_count),
        .stack_effect = stack_effect,
        .quotation_slots = buildQuotationSlotMap(stack_effect) orelse return IrCodegenError.NotCompilable,
    };

    // If this word contains a self-tail-call, wrap the body in a LOOP_BEGIN
    // so the self-call becomes a back-edge instead of a recursive native call.
    if (self_name) |sn| {
        if (hasSelfTailCall(instructions, sn)) {
            const entry_end = c._ir_END(&ctx);
            state.loop_begin_ref = c._ir_LOOP_BEGIN(&ctx, entry_end);
            state.self_name = sn;
            state.input_count = input_count;
            scan_flags.needs_safepoint = true;
            if (state.safepoint_fn == c.IR_UNUSED) {
                state.safepoint_fn = c.ir_const_addr(&ctx, @intFromPtr(&jitSafepoint));
                state.error_propagate_status = c.ir_const_i32(&ctx, 2);
            }
            if (row_aware_self_loop) {
                state.row_aware_loop = true;
                setupRowAwareLoopEntry(&state, stack, &sp);
            }
        }
    }

    // Set up mutual recursion trampoline state if this word is in a group.
    if (mutual_group) |group| {
        state.mutual_group = group;
        state.input_count = input_count;
        state.trampoline_status = c.ir_const_i32(&ctx, 3);
    }

    seedNarrowedParams(&state, stack, input_count);

    try compileInstructions(&state, instructions, stack, &sp);

    if (state.exit_kind == .loop_diverged) {
        // All paths loop back (no base case fell through).
        // Emit unreachable fallback return.
        c._ir_RETURN(&ctx, ok_status);
    } else if (state.exit_kind == .terminal_return) {
        // A terminal callback or trampoline already emitted the return.
    } else if (state.dynamic_call_emitted) {
        // The callee updated sp_ptr and the physical stack directly.
        // Just return success.
        c._ir_RETURN(&ctx, ok_status);
    } else if (hasRowRegion(stack, sp)) {
        // Row region present: flush any entries above it to physical memory,
        // update sp_ptr, and return success.
        flushToPhysicalStack(&state, stack, sp);
        const final_sp_const = c.ir_const_addr(&ctx, sp);
        const final_sp = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, final_sp_const);
        c._ir_STORE(&ctx, state.sp_ptr, final_sp);
        c._ir_RETURN(&ctx, ok_status);
    } else {
        try emitEpilogue(&state, stack, sp, input_count, output_count);
    }

    // Discovery pass: the IR we just built is throwaway. Skip JIT and let
    // the caller re-run with known_peak to emit the prologue capacity check.
    if (known_peak == null) {
        return .{ .compiled = null, .peak_stack_depth = state.peak_sp, .row_aware_self_loop = state.row_aware_loop_detected };
    }

    // JIT compile
    var size: usize = 0;
    const code: ?*anyopaque = c.ir_jit_compile(&ctx, 2, &size);
    if (code) |ptr| {
        return .{
            .compiled = .{
                .code_ptr = ptr,
                .jit_buf = .{ .code = ptr, .size = size },
                .peak_stack_depth = state.peak_sp,
                .cond_select_count = state.cond_select_count,
            },
            .peak_stack_depth = state.peak_sp,
            .row_aware_self_loop = state.row_aware_loop_detected,
        };
    }
    return IrCodegenError.CompilationFailed;
}

/// Convert a 1z word name to a valid C identifier.
///
/// Alphanumerics and underscores pass through; special characters are mapped to short mnemonics;
/// everything else becomes `_xNN_` hex escapes.
///
/// The result is prefixed with `onez_w_` and null-terminated for C interop.
pub fn mangleWordName(name: []const u8, allocator: Allocator) Allocator.Error![:0]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "onez_w_");
    for (name) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => try buf.append(allocator, ch),
            '-' => try buf.append(allocator, '_'),
            '#' => try buf.appendSlice(allocator, "_H"),
            '@' => try buf.appendSlice(allocator, "_A"),
            '?' => try buf.appendSlice(allocator, "_Q"),
            '!' => try buf.appendSlice(allocator, "_B"),
            '*' => try buf.appendSlice(allocator, "_S"),
            '+' => try buf.appendSlice(allocator, "_P"),
            '/' => try buf.appendSlice(allocator, "_D"),
            '<' => try buf.appendSlice(allocator, "_L"),
            '>' => try buf.appendSlice(allocator, "_G"),
            '=' => try buf.appendSlice(allocator, "_E"),
            '.' => try buf.appendSlice(allocator, "_O"),
            ':' => try buf.appendSlice(allocator, "_C"),
            else => {
                var hex_buf: [7]u8 = undefined;
                const hex = std.fmt.bufPrint(&hex_buf, "_x{X:0>2}_", .{ch}) catch unreachable;
                try buf.appendSlice(allocator, hex);
            },
        }
    }
    return buf.toOwnedSliceSentinel(allocator, 0);
}

/// Emit a compiled word as C source code via ir_emit_c.
///
/// Currently limited to pure-arithmetic words, no callbacks, no dispatch.
pub fn emitWordC(
    instructions: []const Instruction,
    input_count: u8,
    output_count: u8,
    name: []const u8,
    allocator: Allocator,
) (IrCodegenError || ir_mod.IrError || Allocator.Error)![]u8 {
    ValueLayout.ensureInit();

    const c_name = try mangleWordName(name, allocator);
    defer allocator.free(c_name);

    // C emission does not use IR_OPT_FOLDING because the opt-level-0 pipeline
    // used by ir_emit_c / no ir_sccp pass) is incompatible with it.
    var ctx: c.ir_ctx = undefined;
    c.ir_init(&ctx, c.IR_FUNCTION, c.IR_CONSTS_LIMIT_MIN, c.IR_INSNS_LIMIT_MIN);
    defer c.ir_free(&ctx);

    // ir_init zeroes ret_type to IR_VOID. Set it to IR_I32 so the C emitter
    // generates the correct return type: compiled words return i32 status.
    ctx.ret_type = c.IR_I32;

    c._ir_START(&ctx);

    JitContextLayout.ensureInit();

    const jit_ctx_ptr = c._ir_PARAM(&ctx, c.IR_ADDR, "jit_ctx", 1);

    const items_ptr = c._ir_LOAD(&ctx, c.IR_ADDR, jit_ctx_ptr);
    const sp_ptr_off = c.ir_const_addr(&ctx, JitContextLayout.sp_ptr_offset);
    const sp_ptr_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), jit_ctx_ptr, sp_ptr_off);
    const sp_ptr = c._ir_LOAD(&ctx, c.IR_ADDR, sp_ptr_addr);

    // Capacity is not loaded for C emission. The ir_emit_c backend assigns
    // vreg 0 to unused LOAD instructions, producing undeclared d_0 in the
    // output. Capacity is loaded in the JIT path (compileWord) which uses
    // IR_OPT_FOLDING and handles dead code.
    const capacity_param = c.IR_UNUSED;

    const bail_status = c.ir_const_i32(&ctx, 1);
    const ok_status = c.ir_const_i32(&ctx, 0);
    const error_propagate_status = c.ir_const_i32(&ctx, 2);

    const proto_1arg = c.ir_proto_1(&ctx, 0, c.IR_I32, c.IR_ADDR);
    const proto_3arg = c.ir_proto_3(&ctx, 0, c.IR_I32, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR);
    const proto_4arg = c.ir_proto_4(&ctx, 0, c.IR_I32, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR);
    const type_mismatch_error_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitTypeMismatchError"), proto_1arg);
    const overflow_error_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitOverflowError"), proto_1arg);
    const div_zero_error_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitDivisionByZeroError"), proto_1arg);
    const underflow_error_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitStackUnderflowError"), proto_1arg);
    const null_code_ptr_error_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitNullCodePtrError"), proto_1arg);
    const append_word_trace_frame_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "onez_append_named_trace_frame"), proto_4arg);
    const append_builtin_trace_frame_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitAppendBuiltinTraceFrame"), proto_3arg);

    const sp_val = c._ir_LOAD(&ctx, c.IR_ADDR, sp_ptr);

    if (input_count > 0) {
        const min_sp = c.ir_const_addr(&ctx, input_count);
        const sp_too_small = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ULT, c.IR_BOOL), sp_val, min_sp);
        const if_underflow = c._ir_IF(&ctx, sp_too_small);
        c._ir_IF_TRUE_cold(&ctx, if_underflow);
        c._ir_RETURN(&ctx, bail_status);
        c._ir_IF_FALSE(&ctx, if_underflow);
    }

    const value_size_const = c.ir_const_addr(&ctx, ValueLayout.value_size);
    const tag_offset_const = c.ir_const_addr(&ctx, ValueLayout.tag_offset);
    const payload_offset_const = c.ir_const_addr(&ctx, ValueLayout.payload_offset);
    const fixnum_tag_const = emitTagConst(&ctx, .fixnum);
    const float_tag_const = emitTagConst(&ctx, .float);
    const boolean_tag_const = emitTagConst(&ctx, .boolean);
    const tagged_tag_const = emitTagConst(&ctx, .tagged);
    const struct_instance_tag_const = emitTagConst(&ctx, .struct_instance);

    const input_count_const = c.ir_const_addr(&ctx, input_count);
    const base_idx = c.ir_fold2(&ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), sp_val, input_count_const);
    const base_byte_offset = c.ir_fold2(&ctx, c.IR_OPT(c.IR_MUL, c.IR_ADDR), base_idx, value_size_const);
    const base_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), items_ptr, base_byte_offset);

    const stack_depth: usize = estimateStackDepth(instructions, input_count);
    const stack = try allocator.alloc(StackEntry, stack_depth);
    defer allocator.free(stack);
    var sp: usize = 0;
    for (0..input_count) |_| {
        stack[sp] = .{ .raw_at_slot = sp };
        sp += 1;
    }

    var state = CompileState{
        .allocator = allocator,
        .ctx = &ctx,
        .base_addr = base_addr,
        .tag_offset_const = tag_offset_const,
        .payload_offset_const = payload_offset_const,
        .fixnum_tag_const = fixnum_tag_const,
        .float_tag_const = float_tag_const,
        .boolean_tag_const = boolean_tag_const,
        .tagged_tag_const = tagged_tag_const,
        .struct_instance_tag_const = struct_instance_tag_const,
        .bail_status = bail_status,
        .ok_status = ok_status,
        .items_ptr = items_ptr,
        .sp_ptr = sp_ptr,
        .capacity_param = capacity_param,
        .sp_val = sp_val,
        .base_idx = base_idx,
        .value_size_const = value_size_const,
        .jit_ctx_ptr = jit_ctx_ptr,
        .error_propagate_status = error_propagate_status,
        .type_mismatch_error_fn = type_mismatch_error_fn,
        .overflow_error_fn = overflow_error_fn,
        .div_zero_error_fn = div_zero_error_fn,
        .underflow_error_fn = underflow_error_fn,
        .null_code_ptr_error_fn = null_code_ptr_error_fn,
        .append_word_trace_frame_fn = append_word_trace_frame_fn,
        .append_builtin_trace_frame_fn = append_builtin_trace_frame_fn,
    };

    try compileInstructions(&state, instructions, stack, &sp);

    if (state.exit_kind == .loop_diverged) {
        c._ir_RETURN(&ctx, ok_status);
    } else if (state.exit_kind == .terminal_return) {
        // Terminal control flow already emitted the return.
    } else if (state.dynamic_call_emitted) {
        c._ir_RETURN(&ctx, ok_status);
    } else if (hasRowRegion(stack, sp)) {
        flushToPhysicalStack(&state, stack, sp);
        const final_sp_const = c.ir_const_addr(&ctx, sp);
        const final_sp = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, final_sp_const);
        c._ir_STORE(&ctx, state.sp_ptr, final_sp);
        c._ir_RETURN(&ctx, ok_status);
    } else {
        try emitEpilogue(&state, stack, sp, input_count, output_count);
    }

    // emit as C source with stdint.h preamble. The JIT path does
    // not need #line directives, so no source-lines table is
    // installed; the patched ir_emit_c.c falls back to its
    // no-source-info behavior.
    const body = try ir_mod.emitC(&ctx, c_name.ptr, allocator, null);
    errdefer allocator.free(body);

    const preamble =
        "#include <stdint.h>\n#include <stdbool.h>\n\n" ++
        "extern int32_t jitTypeMismatchError(uintptr_t ctx);\n" ++
        "extern int32_t jitOverflowError(uintptr_t ctx);\n" ++
        "extern int32_t jitDivisionByZeroError(uintptr_t ctx);\n" ++
        "extern int32_t jitStackUnderflowError(uintptr_t ctx);\n" ++
        "extern int32_t jitNullCodePtrError(uintptr_t ctx);\n" ++
        "extern int32_t jitAppendNamedTraceFrame(uintptr_t ctx, uintptr_t name_ptr, uintptr_t name_len, uintptr_t line);\n" ++
        "extern int32_t jitAppendBuiltinTraceFrame(uintptr_t ctx, uintptr_t frame_kind, uintptr_t line);\n" ++
        "static int32_t onez_append_named_trace_frame(uintptr_t ctx, const char *name, uintptr_t len, uintptr_t line) { return jitAppendNamedTraceFrame(ctx, (uintptr_t)name, len, line); }\n\n";
    const result = try allocator.alloc(u8, preamble.len + body.len);
    @memcpy(result[0..preamble.len], preamble);
    @memcpy(result[preamble.len..], body);
    allocator.free(body);
    return result;
}

/// Emit a single word as a C function body for AOT compilation. Uses named
/// extern references (ir_const_func) for callbacks instead of baked addresses.
/// Does NOT include the #include preamble -- the caller (emitProgramC) adds it.
///
/// Runs two internal passes: the first discovers `peak_sp`, the second emits
/// the prologue capacity check using that peak and produces the final C.
pub fn emitWordCAot(
    instructions: []const Instruction,
    input_count: u8,
    output_count: u8,
    name: []const u8,
    resolver: ?WordResolver,
    self_name: ?[]const u8,
    aot_compiled_names: *const std.StringHashMapUnmanaged(u32),
    string_literals: ?*std.ArrayListUnmanaged(AotStringLiteral),
    quotation_literals: ?*std.ArrayListUnmanaged(AotQuotationLiteral),
    array_literals: ?*std.ArrayListUnmanaged(AotArrayLiteral),
    allocator: Allocator,
    stack_effect: ?*const StackEffect,
    inferred_param_types: []const InferredParamType,
    reason_out: ?*?NotCompilableReason,
    quotation_id_map: ?*const std.AutoHashMapUnmanaged(usize, u32),
    pic_table: ?*pic_mod.PicTable,
    interp_ctx: ?*const Context,
    pic_stats_out: ?*PicStats,
    aot_fallback_emit_count_out: ?*u32,
    aot_fallback_report_out: ?*AotFallbackReportBuilder,
    slot_maps: ?*const AotImageSlotMaps,
    emit_slot_table_literals: bool,
    source_file: ?[]const u8,
    interpreter_free: bool,
    freestanding: bool,
) (IrCodegenError || ir_mod.IrError || Allocator.Error)![]u8 {
    return emitWordCAotWithCName(instructions, input_count, output_count, name, null, resolver, self_name, aot_compiled_names, string_literals, quotation_literals, array_literals, allocator, stack_effect, inferred_param_types, reason_out, quotation_id_map, pic_table, interp_ctx, pic_stats_out, aot_fallback_emit_count_out, aot_fallback_report_out, slot_maps, emit_slot_table_literals, source_file, interpreter_free, freestanding);
}

/// Like emitWordCAot but with a pre-mangled C function name override.
/// When c_name_override is non-null, it is used directly as the C function
/// name instead of mangling `name`.
fn emitWordCAotWithCName(
    instructions: []const Instruction,
    input_count: u8,
    output_count: u8,
    name: []const u8,
    c_name_override: ?[]const u8,
    resolver: ?WordResolver,
    self_name: ?[]const u8,
    aot_compiled_names: *const std.StringHashMapUnmanaged(u32),
    string_literals: ?*std.ArrayListUnmanaged(AotStringLiteral),
    quotation_literals: ?*std.ArrayListUnmanaged(AotQuotationLiteral),
    array_literals: ?*std.ArrayListUnmanaged(AotArrayLiteral),
    allocator: Allocator,
    stack_effect: ?*const StackEffect,
    inferred_param_types: []const InferredParamType,
    reason_out: ?*?NotCompilableReason,
    quotation_id_map: ?*const std.AutoHashMapUnmanaged(usize, u32),
    pic_table: ?*pic_mod.PicTable,
    interp_ctx: ?*const Context,
    pic_stats_out: ?*PicStats,
    aot_fallback_emit_count_out: ?*u32,
    aot_fallback_report_out: ?*AotFallbackReportBuilder,
    slot_maps: ?*const AotImageSlotMaps,
    emit_slot_table_literals: bool,
    source_file: ?[]const u8,
    interpreter_free: bool,
    freestanding: bool,
) (IrCodegenError || ir_mod.IrError || Allocator.Error)![]u8 {
    var reason: ?NotCompilableReason = null;
    const discovered = emitWordCAotPass(instructions, input_count, output_count, name, c_name_override, resolver, self_name, aot_compiled_names, string_literals, quotation_literals, array_literals, allocator, stack_effect, inferred_param_types, null, &reason, quotation_id_map, pic_table, interp_ctx, null, null, null, slot_maps, emit_slot_table_literals, source_file, interpreter_free, freestanding, false) catch |err| {
        if (reason_out) |ro| ro.* = reason;
        return err;
    };
    if (discovered.body) |b| allocator.free(b);
    reason = null;
    const result = emitWordCAotPass(instructions, input_count, output_count, name, c_name_override, resolver, self_name, aot_compiled_names, string_literals, quotation_literals, array_literals, allocator, stack_effect, inferred_param_types, discovered.peak_stack_depth, &reason, quotation_id_map, pic_table, interp_ctx, pic_stats_out, aot_fallback_emit_count_out, aot_fallback_report_out, slot_maps, emit_slot_table_literals, source_file, interpreter_free, freestanding, discovered.row_aware_self_loop) catch |err| {
        if (reason_out) |ro| ro.* = reason;
        return err;
    };
    return result.body orelse return IrCodegenError.CompilationFailed;
}

const EmitWordCAotPassResult = struct {
    body: ?[]u8,
    peak_stack_depth: u32,
    /// True when the word's compiled body returns through the row / dynamic-call
    /// finalization branch rather than the concrete epilogue, so its result
    /// depth is runtime-determined. Callers consult this to collapse to a row at
    /// the call site instead of trusting the declared output count.
    returns_row: bool = false,
    /// Pass-1 discovery: the self-tail-call is reached in the preserved-`ic` row
    /// shape, so pass 2 should rebase the loop entry around the row and emit the
    /// row-aware back-edge instead of ordinary recursion.
    row_aware_self_loop: bool = false,
    /// The abstract stack depth left by the body, i.e. the output count a successful compile settled on.
    ///
    /// Used by the compile-to-discover effect search for composite-nested quotations whose effect
    /// `inferQuotationEffect` can't derive, e.g., a body using a row-variable combinator like `dip`.
    discovered_output: u8 = 0,
};

fn emitWordCAotPass(
    instructions: []const Instruction,
    input_count: u8,
    output_count: u8,
    name: []const u8,
    c_name_override: ?[]const u8,
    resolver: ?WordResolver,
    self_name: ?[]const u8,
    aot_compiled_names: *const std.StringHashMapUnmanaged(u32),
    string_literals: ?*std.ArrayListUnmanaged(AotStringLiteral),
    quotation_literals: ?*std.ArrayListUnmanaged(AotQuotationLiteral),
    array_literals: ?*std.ArrayListUnmanaged(AotArrayLiteral),
    allocator: Allocator,
    stack_effect: ?*const StackEffect,
    inferred_param_types: []const InferredParamType,
    known_peak: ?u32,
    nc_reason_out: ?*?NotCompilableReason,
    quotation_id_map: ?*const std.AutoHashMapUnmanaged(usize, u32),
    pic_table: ?*pic_mod.PicTable,
    interp_ctx_param: ?*const Context,
    pic_stats_out: ?*PicStats,
    aot_fallback_emit_count_out: ?*u32,
    aot_fallback_report_out: ?*AotFallbackReportBuilder,
    slot_maps: ?*const AotImageSlotMaps,
    emit_slot_table_literals: bool,
    source_file: ?[]const u8,
    interpreter_free: bool,
    freestanding: bool,
    row_aware_self_loop: bool,
) (IrCodegenError || ir_mod.IrError || Allocator.Error)!EmitWordCAotPassResult {
    ValueLayout.ensureInit();

    const c_name = if (c_name_override) |override|
        try allocator.dupeZ(u8, override)
    else
        try mangleWordName(name, allocator);
    defer allocator.free(c_name);

    // C emission does not use IR_OPT_FOLDING because the opt-level-0 pipeline
    // used by ir_emit_c is incompatible with it.
    var ctx: c.ir_ctx = undefined;
    c.ir_init(&ctx, c.IR_FUNCTION, c.IR_CONSTS_LIMIT_MIN, c.IR_INSNS_LIMIT_MIN);
    defer c.ir_free(&ctx);

    ctx.ret_type = c.IR_I32;

    c._ir_START(&ctx);

    JitContextLayout.ensureInit();

    const jit_ctx_ptr = c._ir_PARAM(&ctx, c.IR_ADDR, "jit_ctx", 1);

    const items_ptr = c._ir_LOAD(&ctx, c.IR_ADDR, jit_ctx_ptr);
    const sp_ptr_off = c.ir_const_addr(&ctx, JitContextLayout.sp_ptr_offset);
    const sp_ptr_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), jit_ctx_ptr, sp_ptr_off);
    const sp_ptr = c._ir_LOAD(&ctx, c.IR_ADDR, sp_ptr_addr);

    // Capacity is not loaded for C emission. The ir_emit_c backend treats
    // unused LOAD instructions as having vreg 0, which produces undeclared
    // d_0 references in the generated C. The JIT path (compileWord) loads
    // capacity unconditionally because it uses IR_OPT_FOLDING which handles
    // dead code. Stack overflow checking for AOT will be added when the
    // runtime entry points are implemented.
    const capacity_param = c.IR_UNUSED;

    // Pre-scan to determine which callbacks are needed
    var scan_flags = PreScanFlags{};
    preScanInstructions(instructions, resolver, &scan_flags, false) catch {
        if (nc_reason_out) |ro| ro.* = .pre_scan_failure;
        return IrCodegenError.NotCompilable;
    };

    // Create prototypes for callback functions
    const proto_1arg = c.ir_proto_1(&ctx, 0, c.IR_I32, c.IR_ADDR);
    const proto_2arg = c.ir_proto_2(&ctx, 0, c.IR_I32, c.IR_ADDR, c.IR_ADDR);
    const proto_3arg = c.ir_proto_3(&ctx, 0, c.IR_I32, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR);

    // Named callback references for AOT C emission
    const safepoint_fn = if (scan_flags.needs_safepoint)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitSafepoint"), proto_1arg)
    else
        c.IR_UNUSED;

    const recover_fn = if (scan_flags.needs_error_handling)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitRecover"), proto_1arg)
    else
        c.IR_UNUSED;
    const cleanup_fn = if (scan_flags.needs_error_handling)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitCleanup"), proto_1arg)
    else
        c.IR_UNUSED;

    const get_fn = if (scan_flags.needs_dynamic_vars)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitGet"), proto_1arg)
    else
        c.IR_UNUSED;
    const with_parameter_fn = if (scan_flags.needs_dynamic_vars)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitWithParameter"), proto_1arg)
    else
        c.IR_UNUSED;

    const iterator_fn = if (scan_flags.needs_iterators)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitIteratorOp"), proto_2arg)
    else
        c.IR_UNUSED;

    const native_call_fn = if (scan_flags.needs_native_call)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitNativeCall"), proto_2arg)
    else
        c.IR_UNUSED;

    const interpreted_call_fn = if (scan_flags.needs_dispatch or scan_flags.needs_native_call or scan_flags.needs_poly_fallback)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitInterpretedCall"), proto_3arg)
    else
        c.IR_UNUSED;

    // Always declare jitNativeWordCall as a named extern in AOT mode: the
    // two-pass codegen may introduce native call sites that the pre-scan
    // didn't predict, and an unset reference would let ir_emit_c emit a
    // phantom LOAD that collides with vreg 0.
    const native_word_call_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitNativeWordCall"), proto_3arg);

    const proto_4arg = c.ir_proto_4(&ctx, 0, c.IR_I32, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR);
    const proto_5arg = c.ir_proto_5(&ctx, 0, c.IR_I32, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR);

    const aot_satisfies_dispatch_fn = if (scan_flags.needs_satisfies_dispatch)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "aotSatisfiesAndDispatch"), proto_5arg)
    else
        c.IR_UNUSED;

    const aot_satisfies_dispatch_combinator_fn = if (scan_flags.needs_satisfies_dispatch)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "aotSatisfiesAndDispatchCombinator"), proto_5arg)
    else
        c.IR_UNUSED;

    // Always declared: the two-pass codegen may reach a plain generic call
    // site the pre-scan didn't predict, and an unset reference would let
    // ir_emit_c emit a phantom LOAD. Cheap when unused.
    const aot_generic_dispatch_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "aotTryDispatchGenericOrCall"), proto_3arg);

    const pic_dispatch_fn = if (scan_flags.needs_native_call or interp_ctx_param != null)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitPicDispatch"), proto_4arg)
    else
        c.IR_UNUSED;
    const pic_match_fn = if (scan_flags.needs_native_call or interp_ctx_param != null)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitPicTopTagsMatch"), proto_3arg)
    else
        c.IR_UNUSED;
    const pic_dispatch_unary_fn = if (scan_flags.needs_native_call or interp_ctx_param != null)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitPicDispatchUnary"), proto_3arg)
    else
        c.IR_UNUSED;
    const pic_match_unary_fn = if (scan_flags.needs_native_call or interp_ctx_param != null)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitPicTopTagMatch"), proto_2arg)
    else
        c.IR_UNUSED;

    // jitRefreshStack is emitted unconditionally: any callback in the body
    // may reallocate ctx.stack, so emitCallbackPostCheck refreshes regardless
    // of which callbacks the pre-scan flagged.
    const refresh_stack_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitRefreshStack"), proto_1arg);

    // Refcount slot helpers, AOT counterpart of the JIT const_addr refs.
    const retain_slot_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitRetainSlot"), proto_1arg);
    const release_slot_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitReleaseSlot"), proto_1arg);

    // jitEnsureStackCapacity is called unconditionally in the AOT prologue to
    // grow ctx.stack when the capacity reserved by executeCompiled is
    // insufficient. Unconditional (rather than branching as the JIT path does)
    // sidesteps the ir_emit_c vreg-0 bug documented at the capacity_param
    // load above. Cheap: one call per compiled-word entry, no-op when
    // capacity already suffices.
    const ensure_cap_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitEnsureStackCapacity"), proto_2arg);

    const validate_params_fn = if (scan_flags.needs_param_validation)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitValidateParamEffects"), proto_2arg)
    else
        c.IR_UNUSED;

    const call_quotation_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitCallQuotation"), proto_1arg);
    const call_code_ptr_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitCallCodePtr"), proto_2arg);
    const call_value_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitCallValue"), proto_2arg);

    // Error-reporting callbacks: set jit_pending_error and return 2.
    const type_mismatch_error_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitTypeMismatchError"), proto_1arg);
    const overflow_error_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitOverflowError"), proto_1arg);
    const div_zero_error_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitDivisionByZeroError"), proto_1arg);
    const underflow_error_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitStackUnderflowError"), proto_1arg);
    const null_code_ptr_error_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitNullCodePtrError"), proto_1arg);
    const bail_status = c.ir_const_i32(&ctx, 1);
    const ok_status = c.ir_const_i32(&ctx, 0);
    const error_propagate_status = c.ir_const_i32(&ctx, 2);

    const sp_val = c._ir_LOAD(&ctx, c.IR_ADDR, sp_ptr);

    // Pre-load the interpreter Context pointer from the JitContext struct.
    // This must happen early to avoid the ir_emit_c bug where late LOADs
    // get assigned vreg 0 without a C variable declaration.
    const ctx_off = c.ir_const_addr(&ctx, JitContextLayout.ctx_offset);
    const ctx_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), jit_ctx_ptr, ctx_off);
    const preloaded_ctx_val = c._ir_LOAD(&ctx, c.IR_ADDR, ctx_addr);

    // Prologue capacity growth (unconditional). known_peak is null on the
    // discovery pass and non-null on the emission pass.
    var items_ptr_after_check = items_ptr;
    if (known_peak) |peak| {
        if (peak > 0) {
            const peak_const = c.ir_const_addr(&ctx, peak);
            const needed = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), sp_val, peak_const);
            const ensure_status = c._ir_CALL_2(&ctx, c.IR_I32, ensure_cap_fn, jit_ctx_ptr, needed);
            const ensure_failed = c.ir_fold2(&ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), ensure_status, ok_status);
            const if_oom = c._ir_IF(&ctx, ensure_failed);
            c._ir_IF_TRUE_cold(&ctx, if_oom);
            // jitEnsureStackCapacity returns 2 (error_propagate) on OOM.
            c._ir_RETURN(&ctx, ensure_status);
            c._ir_IF_FALSE(&ctx, if_oom);
            // Re-load items_ptr from the JitContext since ensureStackCapacity
            // may have grown the backing slice and moved the pointer.
            items_ptr_after_check = c._ir_LOAD(&ctx, c.IR_ADDR, jit_ctx_ptr);
        }
    }

    if (input_count > 0) {
        const min_sp = c.ir_const_addr(&ctx, input_count);
        const sp_too_small = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ULT, c.IR_BOOL), sp_val, min_sp);
        const if_underflow = c._ir_IF(&ctx, sp_too_small);
        c._ir_IF_TRUE_cold(&ctx, if_underflow);
        c._ir_RETURN(&ctx, bail_status);
        c._ir_IF_FALSE(&ctx, if_underflow);
    }

    const value_size_const = c.ir_const_addr(&ctx, ValueLayout.value_size);
    const tag_offset_const = c.ir_const_addr(&ctx, ValueLayout.tag_offset);
    const payload_offset_const = c.ir_const_addr(&ctx, ValueLayout.payload_offset);
    const fixnum_tag_const = emitTagConst(&ctx, .fixnum);
    const float_tag_const = emitTagConst(&ctx, .float);
    const boolean_tag_const = emitTagConst(&ctx, .boolean);
    const tagged_tag_const = emitTagConst(&ctx, .tagged);
    const struct_instance_tag_const = emitTagConst(&ctx, .struct_instance);

    const input_count_const = c.ir_const_addr(&ctx, input_count);
    const base_idx = c.ir_fold2(&ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), sp_val, input_count_const);
    const base_byte_offset = c.ir_fold2(&ctx, c.IR_OPT(c.IR_MUL, c.IR_ADDR), base_idx, value_size_const);
    const base_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), items_ptr_after_check, base_byte_offset);

    // The row-aware loop entry pins an extra row slot at the bottom, so the
    // abstract peak is one above the no-row peak discovered on pass 1; physical
    // capacity is unchanged, so only the buffer grows.
    const stack_depth: usize = (if (known_peak) |peak| @as(usize, peak) else estimateStackDepth(instructions, input_count)) + @intFromBool(row_aware_self_loop);
    const stack_buf = allocator.alloc(StackEntry, stack_depth) catch return IrCodegenError.OutOfMemory;
    defer allocator.free(stack_buf);
    var sp: usize = 0;
    for (0..input_count) |_| {
        stack_buf[sp] = .{ .raw_at_slot = sp };
        sp += 1;
    }

    var state = CompileState{
        .allocator = allocator,
        .ctx = &ctx,
        .base_addr = base_addr,
        .tag_offset_const = tag_offset_const,
        .payload_offset_const = payload_offset_const,
        .fixnum_tag_const = fixnum_tag_const,
        .float_tag_const = float_tag_const,
        .boolean_tag_const = boolean_tag_const,
        .tagged_tag_const = tagged_tag_const,
        .struct_instance_tag_const = struct_instance_tag_const,
        .bail_status = bail_status,
        .ok_status = ok_status,
        .items_ptr = items_ptr_after_check,
        .sp_ptr = sp_ptr,
        .capacity_param = capacity_param,
        .sp_val = sp_val,
        .base_idx = base_idx,
        .value_size_const = value_size_const,
        .jit_ctx_ptr = jit_ctx_ptr,
        .resolver = resolver,
        .safepoint_fn = safepoint_fn,
        .recover_fn = recover_fn,
        .cleanup_fn = cleanup_fn,
        .get_fn = get_fn,
        .with_parameter_fn = with_parameter_fn,
        .iterator_fn = iterator_fn,
        .native_call_fn = native_call_fn,
        .interpreted_call_fn = interpreted_call_fn,
        .native_word_call_fn = native_word_call_fn,
        .pic_dispatch_fn = pic_dispatch_fn,
        .pic_match_fn = pic_match_fn,
        .pic_dispatch_unary_fn = pic_dispatch_unary_fn,
        .pic_match_unary_fn = pic_match_unary_fn,
        .refresh_stack_fn = refresh_stack_fn,
        .retain_slot_fn = retain_slot_fn,
        .release_slot_fn = release_slot_fn,
        .validate_params_fn = validate_params_fn,
        .aot_satisfies_dispatch_fn = aot_satisfies_dispatch_fn,
        .aot_satisfies_dispatch_combinator_fn = aot_satisfies_dispatch_combinator_fn,
        .aot_generic_dispatch_fn = aot_generic_dispatch_fn,
        .pic_table = pic_table,
        .pic_stats = pic_stats_out,
        .aot_fallback_emit_count = aot_fallback_emit_count_out,
        .aot_fallback_report = aot_fallback_report_out,
        .caller_name_for_report = name,
        .interp_ctx = interp_ctx_param,
        .error_propagate_status = error_propagate_status,
        .type_mismatch_error_fn = type_mismatch_error_fn,
        .overflow_error_fn = overflow_error_fn,
        .div_zero_error_fn = div_zero_error_fn,
        .underflow_error_fn = underflow_error_fn,
        .null_code_ptr_error_fn = null_code_ptr_error_fn,
        .append_word_trace_frame_fn = c.IR_UNUSED,
        .append_builtin_trace_frame_fn = c.IR_UNUSED,
        .aot_mode = true,
        .interpreter_free = interpreter_free,
        .freestanding = freestanding,
        .aot_compiled_names = aot_compiled_names,
        .aot_proto_1arg = proto_1arg,
        .aot_proto_2arg = proto_2arg,
        .call_quotation_fn = call_quotation_fn,
        .call_code_ptr_fn = call_code_ptr_fn,
        .call_value_fn = call_value_fn,
        .preloaded_ctx_val = preloaded_ctx_val,
        .aot_string_literals = string_literals,
        .aot_quotation_literals = quotation_literals,
        .aot_array_literals = array_literals,
        .aot_quotation_id_map = quotation_id_map,
        .aot_slot_maps = slot_maps,
        .aot_emit_slot_table_literals = emit_slot_table_literals,
        .peak_sp = @intCast(input_count),
        .stack_effect = stack_effect,
        .inferred_param_types = inferred_param_types,
        .source_file = source_file,
        .quotation_slots = buildQuotationSlotMap(stack_effect) orelse {
            if (nc_reason_out) |ro| ro.* = .quotation_slot_overflow;
            return IrCodegenError.NotCompilable;
        },
    };
    defer state.source_line_entries.deinit(allocator);

    // Self-tail-call detection for AOT
    if (self_name) |sn| {
        if (hasSelfTailCall(instructions, sn)) {
            const entry_end = c._ir_END(&ctx);
            state.loop_begin_ref = c._ir_LOOP_BEGIN(&ctx, entry_end);
            state.self_name = sn;
            state.input_count = input_count;
            if (state.safepoint_fn == c.IR_UNUSED) {
                state.safepoint_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitSafepoint"), proto_1arg);
                state.error_propagate_status = c.ir_const_i32(&ctx, 2);
            }
            if (row_aware_self_loop) {
                state.row_aware_loop = true;
                setupRowAwareLoopEntry(&state, stack_buf, &sp);
            } else if (state.refresh_stack_fn != c.IR_UNUSED) {
                // Re-derive the base address at the loop header. A nested call in the loop body
                // can reallocate ctx.stack.items, which freeze the old buffer. Without this refresh,
                // the back-edge keeps using the entry-time base pointer and reads the freed buffer
                // on the next iteration. The while/loop combinators refresh the same way at their
                // loop headers.
                refreshCachedStackPointer(&state);
            }
        }
    }

    // Built-in word bodies: emit custom IR instead of compiling the body.
    if (std.mem.eql(u8, name, "choose")) {
        emitChooseBuiltin(&state, stack_buf, &sp) catch |err| {
            if (err == IrCodegenError.NotCompilable) {
                if (nc_reason_out) |ro| ro.* = state.not_compilable_reason;
            }
            return err;
        };
    } else {
        seedNarrowedParams(&state, stack_buf, input_count);

        compileInstructions(&state, instructions, stack_buf, &sp) catch |err| {
            if (err == IrCodegenError.NotCompilable) {
                if (nc_reason_out) |ro| ro.* = state.not_compilable_reason;
            }
            return err;
        };
    }

    if (state.exit_kind == .loop_diverged) {
        // Every path loops back. In this case, the word is an infinite loop with no return, e.g.,
        // a server accept loop, so we'll need to emit no trailing RETURN.
        //
        // The loop never falls through, so a return is unreachable, and ir_emit_c backend hangs
        // generating C for that dead code after the no-exit loop.
        //
        // Leaving the loop as the function's final construct lets ir_emit_c emit a native `for(;;)`.
        //
        // The JIT path still emits an unreachable RETURN because ir_jit_compile folds it away;
        // only ir_emit_c chokes on it.
    } else if (state.exit_kind == .terminal_return) {
        // Terminal control flow already emitted the return.
    } else if (state.error_handler_terminal) {
        // The error handler callback (jitRecover/jitCleanup) updated sp_ptr
        // and the physical stack directly. Return success, matching the JIT path.
        c._ir_RETURN(&ctx, ok_status);
    } else if (state.dynamic_call_emitted or hasRowRegion(stack_buf, sp)) {
        // Dynamic quotation calls or unresolved row regions mean the
        // stack shape is determined at runtime by native callbacks.
        // Return success; the caller resolves row variables at the call
        // site and adjusts sp accordingly.
        c._ir_RETURN(&ctx, ok_status);
    } else {
        try emitEpilogue(&state, stack_buf, sp, input_count, output_count);
    }

    // A word is reported as row-returning to callers only when its runtime
    // output depth genuinely varies. A row at finalization is necessary but not
    // sufficient: a deterministic-depth row (reach-below shuffles, indexed-row
    // ops) leaves the declared output count faithful, so the caller keeps
    // trusting it. variable_arity is set only by an `if` over a row whose
    // branches leave different depths, and propagated through pass-through rows.
    const returns_row = state.variable_arity;

    const discovered_output: u8 = if (sp > 255) 255 else @intCast(sp);

    // Discovery pass: skip C emission, let the caller re-run with the peak.
    if (known_peak == null) {
        return .{ .body = null, .peak_stack_depth = state.peak_sp, .returns_row = returns_row, .row_aware_self_loop = state.row_aware_loop_detected, .discovered_output = discovered_output };
    }

    // Build the source-lines side table for the patched `ir_emit_c.c` so
    // it can emit `#line` directives at control-flow boundaries. The
    // entries list is sorted by ref ascending; the C side does a binary
    // search. Skipped when no entries were recorded or the source file
    // is unknown -- the magic-tag check in the patched emitter then
    // leaves the no-source-info behavior unchanged.
    var source_file_zbuf: ?[:0]u8 = null;
    defer if (source_file_zbuf) |zb| allocator.free(zb);
    var source_lines_value: IrCSourceLines = undefined;
    var source_lines_ptr: ?*const anyopaque = null;
    if (source_file) |sf| {
        if (state.source_line_entries.items.len > 0) {
            std.mem.sort(LineEntry, state.source_line_entries.items, {}, struct {
                fn lessThan(_: void, a: LineEntry, b: LineEntry) bool {
                    return a.ref < b.ref;
                }
            }.lessThan);
            const zbuf = try allocator.dupeZ(u8, sf);
            source_file_zbuf = zbuf;
            source_lines_value = .{
                .magic = ir_c_source_lines_magic,
                .file = zbuf.ptr,
                .entries = state.source_line_entries.items.ptr,
                .entries_count = @intCast(state.source_line_entries.items.len),
            };
            source_lines_ptr = @ptrCast(&source_lines_value);
        }
    }

    const body = try ir_mod.emitC(&ctx, c_name.ptr, allocator, source_lines_ptr);
    return .{ .body = body, .peak_stack_depth = state.peak_sp, .returns_row = returns_row, .row_aware_self_loop = state.row_aware_loop_detected, .discovered_output = discovered_output };
}

/// Append an `asm("name")` declaration attribute to `out` so the C compiler renames the linker symbol
/// to the verbatim 1z word name. `asm("...")` affects `DW_AT_linkage_name` and the ELFl / Mach-O linker
/// symbol. Tools that read those (e.g., `perf`, `samply`, `nm`) display the 1z name instead of the
/// mangled C identifier.
///
/// The 1z name is preserved byte-for-byte. The only safeguard is a hard-reject for bytes that would
/// break the C string literal, the assembler, or the linker: NUL, embedded `"`, `\`, and ASCII control
/// characters including DEL. On any hostile byte, this writes nothing, so the forward declaration falls
/// back to its mangled C identifier.
fn appendAsmNameClause(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, name: []const u8) Allocator.Error!void {
    for (name) |b| {
        if (b == 0 or b < 0x20 or b == 0x7F) return;
        if (b == '"' or b == '\\') return;
    }
    try out.appendSlice(allocator, " asm(\"");
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, "\")");
}

/// Append an asm-name clause for a generated word, formatted as `<parent>/<name>`, when `parent` is
/// non-empty and as the bare `name` otherwise.
///
/// Profile samples landing in struct accessors, enum predicates, and other type-attached generated
/// words are attributed to a symbol that names both the originating type and the synthesized word,
/// so accessors named the same across structs (e.g., `name>>` on `Person` vs `Account`) no longer
/// collide in profiler output.
///
/// The byte-level toolchain-hostile-character check is delegated to `appendAsmNameClause`, so a
/// hostile byte anywhere in either component drops the asm-name and leaves the forward declaration
/// on its mangled C identifier.
fn appendGeneratedWordAsmNameClause(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, name: []const u8, parent: ?[]const u8) Allocator.Error!void {
    if (parent) |p| {
        if (p.len > 0) {
            const formatted = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ p, name });
            defer allocator.free(formatted);
            try appendAsmNameClause(out, allocator, formatted);
            return;
        }
    }
    try appendAsmNameClause(out, allocator, name);
}

/// Append an asm-name clause for a compiled quotation, formatted as
/// `<defining-word>/quot@<line>:<col>`. Profile samples landing in the
/// quotation are attributed to a symbol that names both the enclosing
/// 1z word and the position of the opening `[`, so siblings within
/// the same defining word disambiguate by source position.
///
/// Writes nothing when the defining word is null/empty or the
/// opening-bracket position is missing -- both indicate that freeze
/// failed to attach provenance to this quotation body, and emitting a
/// malformed asm-name would be worse than leaving the symbol mangled.
/// The byte-level toolchain-hostile-character check is delegated to
/// `appendAsmNameClause`.
fn appendQuotationAsmNameClause(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, q: AotQuotationDesc) Allocator.Error!void {
    const defining = q.defining_word orelse return;
    if (defining.len == 0) return;
    if (q.source_line == 0 or q.source_column == 0) return;
    const formatted = try std.fmt.allocPrint(allocator, "{s}/quot@{d}:{d}", .{ defining, q.source_line, q.source_column });
    defer allocator.free(formatted);
    try appendAsmNameClause(out, allocator, formatted);
}

/// Append a `#line N "path"` directive to `out`. Toolchain-hostile bytes
/// (`"`, `\`, NUL, ASCII controls) in the path are escaped or stripped
/// so the directive parses cleanly under cc; legal filesystem paths
/// pass through unchanged. Callers should skip emission entirely when
/// `line == 0` or `file` is empty, since both signal absent metadata.
fn appendLineDirective(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    file: []const u8,
    line: usize,
) Allocator.Error!void {
    try out.appendSlice(allocator, "#line ");
    var num_buf: [20]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line}) catch unreachable;
    try out.appendSlice(allocator, num_str);
    try out.appendSlice(allocator, " \"");
    for (file) |b| {
        if (b == 0 or b < 0x20) continue;
        switch (b) {
            '"', '\\' => {
                try out.append(allocator, '\\');
                try out.append(allocator, b);
            },
            else => try out.append(allocator, b),
        }
    }
    try out.appendSlice(allocator, "\"\n");
}

/// Work around ir_emit_c vreg 0 bug: if the emitted C body uses `d_0` but
/// does not declare it, insert `\tuintptr_t d_0;\n` after the opening brace.
fn patchMissingD0(body: []u8, allocator: Allocator) Allocator.Error![]u8 {
    // Check if d_0 is used anywhere in the body.
    if (std.mem.indexOf(u8, body, "d_0") == null) return body;

    // Check if d_0 is already declared (pattern: "\tuintptr_t d_0")
    if (std.mem.indexOf(u8, body, "\tuintptr_t d_0") != null) return body;

    // Find the opening brace + newline to insert after.
    const brace_nl = std.mem.indexOf(u8, body, "{\n") orelse return body;
    const insert_pos = brace_nl + 2;
    const decl = "\tuintptr_t d_0;\n";

    const new = try allocator.alloc(u8, body.len + decl.len);
    @memcpy(new[0..insert_pos], body[0..insert_pos]);
    @memcpy(new[insert_pos .. insert_pos + decl.len], decl);
    @memcpy(new[insert_pos + decl.len ..], body[insert_pos..]);
    return new;
}

/// Emit a complete, compilable C source file for a set of words.
///
/// The output contains:
///   1. #include preamble
///   2. Forward declarations for all runtime callbacks (extern)
///   3. Forward declarations for all compiled word functions
///   4. One C function per word (via ir_emit_c)
///   5. A dispatch table initialization array
///   6. A main() entry point
///
/// `entry_word_id` identifies which word to call from main().
pub const InterpreterFallbackMode = enum { true, false, auto };

/// Re-export of `ArtifactClass` so external callers (inspect mode,
/// metadata emission) keep importing it from this module. The
/// definition lives in `primitives/markers.zig` next to the dynamic
/// marker family whose policy it governs.
pub const ArtifactClass = markers_mod.ArtifactClass;

/// Which image (if any) the binary ships. Metadata-only images live
/// on the interpreter-free side of the class boundary: they carry word
/// metadata for read-only introspection but no executable bodies, so
/// they do not promote the artifact to `runtime-image-aot`.
pub const ImageKind = enum {
    none,
    metadata_only,
    full_runtime,
};

/// Classify a built AOT binary by its maximum runtime capability.
/// Interpreter linkage subsumes everything: an interpreter-linked
/// binary can do dynamic eval and runtime load, so it's reported as
/// `interpreter` regardless of image. Without interpreter linkage, a
/// full runtime image lifts the binary to `runtime-image-aot`; a
/// metadata-only image (or no image at all) stays at
/// `interpreter-free-aot`.
pub fn classifyArtifact(interpreter_linked: bool, image: ImageKind) ArtifactClass {
    if (interpreter_linked) return .interpreter;
    return switch (image) {
        .none, .metadata_only => .interpreter_free_aot,
        .full_runtime => .runtime_image_aot,
    };
}

/// Core metadata embedded into every AOT binary as a single rodata
/// string. The schema-version and surrounding sentinels make the block
/// self-describing for an external inspector. The `interpreter_linked`
/// field is decided inside `emitProgramC` so it matches the compiled
/// artifact, not the user's pre-resolution intent; callers fill in the
/// other fields.
pub const AotMetadata = struct {
    /// User-facing intent passed on the build command line. Recorded
    /// verbatim to distinguish "auto" builds from "true" / "false"
    /// builds.
    interpreter_fallback_mode: InterpreterFallbackMode,
    interpreter_setting_locked: bool,
    /// Caller hands in `false`; `emitProgramC` flips it to `true` when
    /// a full runtime image (with executable body bytecode and blob
    /// entries) is emitted into the binary.
    runtime_image_present: bool,
    /// Caller hands in `false`; `emitProgramC` flips it to `true` when
    /// an interpreter-free binary emits a metadata-only image (word
    /// metadata for read-only introspection, no executable bodies).
    /// Mutually exclusive with `runtime_image_present`: interpreter-free
    /// uses the metadata-only path; `--emit-runtime-image` upgrades to
    /// the full runtime image.
    metadata_image_present: bool = false,
    /// Caller hands in `false`; `emitProgramC` flips it to `true` when
    /// the assembled C actually emits a `jitInterpretedCall` extern and
    /// at least one call site. Drives the `jit-interpreted-call-linked`
    /// inspector field.
    jit_interpreted_call_linked: bool = false,
    /// e.g. "aarch64-macos". Caller-owned slice; lifetime must outlive
    /// the call to emitProgramC.
    target_triple: []const u8,
    /// `@tagName(builtin.mode)`: "Debug" / "ReleaseSafe" / etc.
    build_mode: []const u8,
    /// build_options.version
    onez_version: []const u8,
    /// Hex-encoded SHA-256 of the prelude source bytes that fed
    /// `Context.loadPrelude` for this build, length 64.
    prelude_hash_hex: []const u8,
    /// Read only when `runtime_image_present` is true; ignored
    /// otherwise. Stays at the defaults until a binary actually
    /// embeds a runtime program image.
    runtime_image_format_version: u32 = 0,
    runtime_image_blob_present: bool = false,
    runtime_image_word_count: u32 = 0,
    /// Count of distinct StructType, Marker, and Parameter slot-table
    /// entries actually emitted. Each table is only present in the
    /// generated C when its count is non-zero; the generated main
    /// references the table only when the count is non-zero (and
    /// passes NULL otherwise).
    runtime_image_struct_type_slot_count: u32 = 0,
    runtime_image_marker_slot_count: u32 = 0,
    runtime_image_parameter_slot_count: u32 = 0,
    runtime_image_tagged_slot_count: u32 = 0,
    runtime_image_mutable_map_slot_count: u32 = 0,
    runtime_image_struct_instance_slot_count: u32 = 0,
    runtime_image_vector_slot_count: u32 = 0,
    runtime_image_protocoldescriptor_slot_count: u32 = 0,
    runtime_image_constraintcombinator_slot_count: u32 = 0,
    /// Count of method dispatch-entry rows serialized into the image. An
    /// informational tooling affordance; the loader sizes the table from the
    /// image Header's `dispatch_entry_slot_count`, not from this field.
    runtime_image_dispatch_entry_slot_count: u32 = 0,
    /// Optional toolchain provenance. An empty slice means the field
    /// was unavailable at build time and must not appear in the
    /// embedded metadata or in `1z inspect` output.
    onez_git_commit: []const u8 = "",
    zig_version: []const u8 = "",
    c_compiler_id: []const u8 = "",
    c_compiler_version: []const u8 = "",
    /// Comma-separated list of `dynamic-*` marker names reachable in the
    /// frozen call graph (e.g. `"dynamic-eval,dynamic-load"`), or `"none"`.
    /// Optional: omitted from the binary when null (older builds). Set by
    /// the build driver after a successful freeze.
    dynamic_features: ?[]const u8 = null,
    /// True when the build driver resolved a freestanding target triple
    /// (i.e. `os.tag == .freestanding`). Drives the emitted C preamble:
    /// libc headers, `int main(int argc, char **argv)`, and the
    /// `ONEZ_INTERPRETER_FALLBACK` env-var sniff are dropped in favor of
    /// a `kernel_main(void)` entry that a linker script will reference.
    freestanding: bool = false,
};

/// Emit a `--trace-aot=codegen` line for a word or quotation trial-compile.
/// `kind` is `"word"` or `"quot"`. A null `reason` is a success; otherwise the
/// reason's code and message name the rejection. No-op unless `interp_ctx`
/// carries the codegen axis.
fn emitAotCodegenTrace(interp_ctx: ?*const Context, kind: []const u8, name: []const u8, reason: ?NotCompilableReason) void {
    const ctx = interp_ctx orelse return;
    if (!ctx.trace.trace_aot.codegen) return;
    if (!trace_mod.matchesPattern(name, ctx.trace.trace_aot_word_pattern)) return;
    var tw = trace_mod.TraceWriter.init();
    if (reason) |r| {
        trace_mod.traceAotCodegen(&tw, kind, name, r.code(), r.message());
    } else {
        trace_mod.traceAotCodegen(&tw, kind, name, null, "");
    }
}

/// Emit a `--trace-aot=instr` line for one instruction as codegen steps the abstract stack.
///
/// Fires for every word, not only self-tail-recursive ones, because the name comes from
/// `caller_name_for_report`, which is always set on the AOT path. It's a noöp unless `interp_ctx`
/// carries the instr axis, and `hasRowRegion` runs only after that gate, so the trace-off cost is
/// one pointer load and one bool check.
///
/// The two-pass AOT compile runs `compileInstructions` several times per word, so a word that
/// compiles emits each line more than once. A word that fails NC.13 traces once, because it aborts
/// in the first pass before the emit passes run.
fn emitAotInstrTrace(state: *const CompileState, instr: Instruction, stack: []const StackEntry, sp: usize) void {
    const ctx = state.interp_ctx orelse return;
    if (!ctx.trace.trace_aot.instr) return;
    const word = state.caller_name_for_report orelse state.self_name orelse "<unknown>";
    if (!trace_mod.matchesPattern(word, ctx.trace.trace_aot_word_pattern)) return;
    const target = instr.op.callTargetName() orelse "-";
    var tw = trace_mod.TraceWriter.init();
    trace_mod.traceAotInstr(&tw, word, @tagName(instr.op), target, sp, hasRowRegion(stack, sp), instr.line);
}

/// Emit a `--trace-aot=effect` line for one compile-to-discover attempt at input
/// arity `in_arity`. A non-null `out_arity` is a success; otherwise `reason`
/// names the rejection for that attempt. No-op unless `interp_ctx` carries the
/// effect axis.
fn emitAotEffectTrace(interp_ctx: ?*const Context, name: []const u8, in_arity: u8, out_arity: ?u8, reason: ?NotCompilableReason) void {
    const ctx = interp_ctx orelse return;
    if (!ctx.trace.trace_aot.effect) return;
    if (!trace_mod.matchesPattern(name, ctx.trace.trace_aot_word_pattern)) return;
    var tw = trace_mod.TraceWriter.init();
    if (out_arity) |out| {
        trace_mod.traceAotEffectAttempt(&tw, name, in_arity, out, null, "");
    } else if (reason) |r| {
        trace_mod.traceAotEffectAttempt(&tw, name, in_arity, null, r.code(), r.message());
    } else {
        trace_mod.traceAotEffectAttempt(&tw, name, in_arity, null, null, "");
    }
}

pub fn emitProgramC(
    words: []const AotWordDesc,
    quotations: []AotQuotationDesc,
    entry_word_id: u32,
    max_word_id: u32,
    static_libs: []const []const u8,
    interpreter_fallback: InterpreterFallbackMode,
    lock_interpreter_setting: bool,
    metadata: AotMetadata,
    diagnostics: *CodegenDiagnostics,
    interp_ctx: ?*const Context,
    /// When true, walk `interp_ctx.module_cache_value`, build an image
    /// manifest, and emit the `onez_image_v1` runtime image alongside
    /// the dispatch table. Requires `interp_ctx` to be non-null.
    emit_runtime_image: bool,
    /// Freeze-detected non-prelude uncompiled words reachable from
    /// composite-buried quotations. Non-empty in an interpreter-linked
    /// metadata-only build rejects the build with `RuntimeImageRequired`.
    interpreted_reach: []const InterpretedReachViolation,
    allocator: Allocator,
) (IrCodegenError || ir_mod.IrError || Allocator.Error)![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);

    // Local mutable copy of the caller's metadata. The runtime-image
    // fields stay at the caller's defaults (present=false, version=0)
    // unless `emitImageC` actually emits an image below; the caller has
    // no visibility into that decision.
    var meta = metadata;

    // Build name->word_id map for compiled words, excluding native words,
    // which dispatch through `jitNativeWordCall` rather than direct C calls.
    var compiled_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compiled_names.deinit(allocator);
    for (words) |w| {
        if (w.is_native) continue;
        try compiled_names.put(allocator, w.name, w.word_id);
    }

    // 1. Preamble
    //
    // Freestanding mode targets `os.tag == .freestanding`: no libc, so the
    // stdio, stdlib, and string headers are dropped. Only the headers providing
    // fixed-width integers, bool, and size_t/NULL stay.
    if (meta.freestanding) {
        try out.appendSlice(allocator,
            \\#include <stdint.h>
            \\#include <stdbool.h>
            \\#include <stddef.h>
            \\
            \\
        );
    } else {
        try out.appendSlice(allocator,
            \\#include <stdint.h>
            \\#include <stdbool.h>
            \\#include <stddef.h>
            \\#include <stdio.h>
            \\#include <stdlib.h>
            \\#include <string.h>
            \\
            \\
        );
    }

    // Runtime entry point externs
    try out.appendSlice(allocator,
        \\
        \\extern void *onez_init(void);
        \\extern void *onez_init_no_prelude(void);
        \\extern int onez_set_args(void *ctx, int argc, char **argv);
        \\extern int onez_set_source(void *ctx, const char *data, unsigned long len);
        \\extern int32_t onez_runtime_register_compiled(void *rt, int32_t (**table)(uintptr_t), const char **names, uint32_t size);
        \\extern int32_t onez_runtime_register_quotations(void *rt, int32_t (**table)(uintptr_t), uint32_t size);
        \\extern int32_t onez_runtime_run(void *rt, uint32_t entry_word_id);
        \\extern void onez_fire_exit_hooks(void *rt, int32_t code);
        \\extern void onez_print_error(void *rt);
        \\extern void onez_deinit(void *rt);
        \\extern int onez_set_static_libs(void *rt, const char **names, unsigned int count);
        \\extern int32_t onez_set_interpreter_fallback(void *rt, _Bool allowed);
        \\extern int32_t onez_set_trace_words(void *rt, const char *pattern);
        \\extern int32_t onez_set_stdlib_path_z(void *rt, const char *path);
        \\extern int onez_load_runtime_image(void *rt, const void *header, void *typevalue_slots, void *struct_type_slots, void *marker_slots, void *parameter_slots, void *tagged_slots, void *mutable_map_slots, void *struct_instance_slots, void *vector_slots, void *protocoldescriptor_slots, void *constraintcombinator_slots);
        \\extern int onez_replay_method_dispatch(void *rt);
        \\
        \\
    );

    // Build a resolver from the AOT word list for cross-word calls
    var word_map: std.StringHashMapUnmanaged(AotWordDesc) = .{};
    defer word_map.deinit(allocator);
    for (words) |w| {
        try word_map.put(allocator, w.name, w);
    }

    // Names of words whose compiled body returns through the row / dynamic-call
    // finalization branch. Populated by the row-returning fixpoint below, before
    // Pass 1a, and consulted by the resolver so call sites collapse to a row.
    var returns_row_names: std.StringHashMapUnmanaged(void) = .{};
    defer returns_row_names.deinit(allocator);

    const AotResolverData = struct {
        map: *const std.StringHashMapUnmanaged(AotWordDesc),
        returns_row_names: *const std.StringHashMapUnmanaged(void),

        fn resolve(name_ptr: []const u8, user_data: *anyopaque) ?ResolvedWord {
            const self: *const @This() = @ptrCast(@alignCast(user_data));
            const entry = self.map.getPtr(name_ptr) orelse return null;
            var result = ResolvedWord{
                .word_id = entry.word_id,
                .input_count = entry.input_count,
                .output_count = entry.output_count,
                .never_returns = entry.never_returns,
                .is_native = entry.is_native,
                .native_fn_ptr = entry.native_fn_ptr,
                .dispatch_id = if (entry.bounded_constraint != null) entry.bounded_dispatch_id else entry.dispatch_id,
                .bounded_constraint = entry.bounded_constraint,
                .bounded_arity = entry.bounded_arity,
                .is_generic = entry.is_generic,
                .returns_row = self.returns_row_names.contains(name_ptr),
            };
            if (entry.stack_effect) |*eff| {
                if (stack_effect_mod.hasAnyRowVariable(eff.*)) {
                    result.callee_effect = eff;
                }
            }
            return result;
        }
    };

    // Build-time strict flag: an explicit `--interpreter-fallback=false` build
    // must reject any construct that would re-enter the interpreter at runtime,
    // rather than compiling a path that fatals in an interpreter-free binary.
    // Auto and permissive builds keep the row-region continuation.
    const strict_interpreter_free = interpreter_fallback == .false;

    var resolver_data = AotResolverData{ .map = &word_map, .returns_row_names = &returns_row_names };
    const resolver = WordResolver{
        .resolve = &AotResolverData.resolve,
        .user_data = @ptrCast(&resolver_data),
        .dispatch_table_ptr = undefined,
    };

    // Build the runtime-image manifest and run the slot-table
    // collection walk before Pass 1 starts, so both discovery and
    // Pass 2 codegen can consult the slot indices for typed-literal
    // pushes. The same collection is later consumed by
    // `emitImageCFromCollection` when the build decides to emit a
    // runtime or metadata-only image, so the slot indices baked into
    // compiled bodies match the indices the image emitter writes to
    // the slot tables.
    //
    // The collection is allocated only when an interpreter context
    // is available; pure-AOT builds without a frozen interpreter
    // skip both the collection and the image entirely.
    var image_manifest: ?aot_image_mod.ImageManifest = null;
    defer if (image_manifest) |*m| m.deinit(allocator);
    var image_word_lookup: std.StringHashMapUnmanaged(u32) = .{};
    defer image_word_lookup.deinit(allocator);
    var image_collection: ?aot_image_emit_mod.ImageCollection = null;
    defer if (image_collection) |*coll| coll.deinit();
    var image_slot_maps: ?AotImageSlotMaps = null;
    if (interp_ctx) |ctx| {
        image_manifest = try aot_image_mod.buildImageManifest(@constCast(ctx), allocator);
        for (words) |w| {
            try image_word_lookup.put(allocator, w.name, w.word_id);
        }
        // Post-freeze word bodies are the canonical source for any
        // type-carrier literal that lives in a user top-level word.
        // The interpreter Context's local frame has been popped by
        // this point, so internTopLevelFrameLiterals can no longer
        // see those definitions; collecting from AotWordDesc keeps
        // the slot maps in sync with what codegen will compile.
        var extra_bodies: std.ArrayListUnmanaged([]const value_mod.Instruction) = .{};
        defer extra_bodies.deinit(allocator);
        for (words) |w| {
            if (w.is_native) continue;
            try extra_bodies.append(allocator, w.instructions);
        }
        image_collection = try aot_image_emit_mod.collectImageSlots(
            allocator,
            ctx,
            image_manifest.?,
            .{ .metadata_only = false },
            extra_bodies.items,
        );
        // Intern every bounded descriptor from the word list so the slot
        // tables cover all bounded call sites in this build. Protocol bounds
        // land in the protocol slot table; combinator bounds in the combinator
        // slot table.
        for (words) |w| {
            if (w.bounded_constraint) |bc| switch (bc) {
                .protocol => |pd| _ = try image_collection.?.effect_table.internProtocol(pd),
                .combinator => |cc| _ = try image_collection.?.effect_table.internCombinator(cc),
            };
        }
        image_slot_maps = .{
            .typevalue_slot_index = &image_collection.?.effect_table.type_slot_index,
            .struct_type_slot_index = &image_collection.?.struct_index,
            .marker_slot_index = &image_collection.?.effect_table.marker_slot_index,
            .parameter_slot_index = &image_collection.?.effect_table.parameter_slot_index,
            .tagged_slot_index = &image_collection.?.effect_table.tagged_slot_index,
            .mutable_map_slot_index = &image_collection.?.effect_table.mutable_map_slot_index,
            .struct_instance_slot_index = &image_collection.?.effect_table.struct_instance_slot_index,
            .vector_slot_index = &image_collection.?.effect_table.vector_slot_index,
            .protocol_slot_index = &image_collection.?.effect_table.protocol_slot_index,
            .combinator_slot_index = &image_collection.?.effect_table.combinator_slot_index,
        };
    }
    const slot_maps_ptr: ?*const AotImageSlotMaps = if (image_slot_maps) |*m| m else null;
    // Slot tables are emitted whenever an interpreter context is
    // available. Image emission below produces at least a
    // metadata-only image in that case, so the loader can patch the
    // slot tables with runtime pointers. This keeps every AOT
    // artifact class on the slot-table path, removing the legacy
    // name-lookup fallback for type-carrier literals.
    const emit_slot_table_literals = slot_maps_ptr != null;

    // Row-returning fixpoint: discover, before Pass 1a, which words compile to a
    // row-returning body. A word's declared output count does not faithfully
    // model such a call result, so the call site must collapse to a row instead
    // of trusting the declared concrete effect (see ResolvedWord.returns_row).
    // The property is a monotonic fixpoint over the call graph: a word becomes
    // row-returning if its body reaches the row / dynamic-call finalization
    // branch, which itself can depend on a callee already being row-returning.
    // Each round trial-compiles every non-native word not yet marked; on a
    // success that returns a row, the word is added to the set, which makes more
    // callers compile and reveal their own row-returning shape on the next
    // round. The set only grows and is bounded by the word count, so the loop
    // converges. A word that fails to compile this round is simply retried next
    // round once any blocking callee is marked. The resolver reads
    // `returns_row_names` through a stable pointer, so the growing set is visible
    // to each round's trial compilations.
    {
        var changed = true;
        while (changed) {
            changed = false;
            for (words) |*w| {
                if (w.is_native) continue;
                if (returns_row_names.contains(w.name)) continue;
                var reason: ?NotCompilableReason = null;
                const discovered = emitWordCAotPass(
                    w.instructions,
                    w.input_count,
                    w.output_count,
                    w.name,
                    w.name,
                    resolver,
                    w.name,
                    &compiled_names,
                    null,
                    null,
                    null,
                    allocator,
                    if (w.stack_effect != null) &w.stack_effect.? else null,
                    w.inferred_param_types,
                    null,
                    &reason,
                    null,
                    w.pic_snapshot,
                    interp_ctx,
                    null,
                    null,
                    null,
                    slot_maps_ptr,
                    emit_slot_table_literals,
                    w.source_file,
                    strict_interpreter_free,
                    meta.freestanding,
                    false,
                ) catch continue;
                if (discovered.body) |b| allocator.free(b);
                if (discovered.returns_row) {
                    try returns_row_names.put(allocator, w.name, {});
                    changed = true;
                }
            }
        }
    }
    if (std.posix.getenv("ONEZ_DEBUG_ROWRET") != null) {
        var it = returns_row_names.keyIterator();
        while (it.next()) |k| std.debug.print("ROWRET {s}\n", .{k.*});
    }

    // 4. Two-pass compilation: first determine which words compile,
    // then re-compile with only the compilable set so that cross-word calls
    // to uncompiled compound callees use `jitInterpretedCall` (permissive
    // AOT) instead of direct calls; strict AOT rejects the build at any
    // such site.

    // Pass 1a: trial compile to discover the compilable set
    var compilable_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compilable_names.deinit(allocator);
    var failure_reasons: std.StringHashMapUnmanaged(NotCompilableReason) = .{};
    defer failure_reasons.deinit(allocator);
    for (words) |*w| {
        if (w.is_native) continue;
        // A word that calls a helper it defines via a nested `name: [ ... ] ;`
        // statement in its own body cannot be compiled correctly: codegen
        // resolves the call through the global-only resolver, which cannot see
        // the nested-local, so a name that also exists globally (e.g. a
        // generated struct converter) mis-binds to the global. Run such a word
        // interpreted, where nested-scope shadowing is honored.
        if (findUndiscoverableNestedDef(w.instructions) != null) {
            try failure_reasons.put(allocator, w.name, .nested_definition);
            emitAotCodegenTrace(interp_ctx, "word", w.name, .nested_definition);
            continue;
        }
        var reason: ?NotCompilableReason = null;
        const trial = emitWordCAot(
            w.instructions,
            w.input_count,
            w.output_count,
            w.name,
            resolver,
            w.name,
            &compiled_names,
            null,
            null,
            null,
            allocator,
            if (w.stack_effect != null) &w.stack_effect.? else null,
            w.inferred_param_types,
            &reason,
            null,
            w.pic_snapshot,
            interp_ctx,
            null,
            null,
            null,
            slot_maps_ptr,
            emit_slot_table_literals,
            w.source_file,
            strict_interpreter_free,
            meta.freestanding,
        ) catch |err| {
            const rejected: ?NotCompilableReason = if (reason) |r|
                r
            else if (err == IrCodegenError.StackUnderflow or err == IrCodegenError.StackShapeMismatch)
                .abstract_stack_underflow
            else
                null;
            if (rejected) |r| try failure_reasons.put(allocator, w.name, r);
            emitAotCodegenTrace(interp_ctx, "word", w.name, rejected orelse .unknown_reason);
            continue;
        };
        allocator.free(trial);
        emitAotCodegenTrace(interp_ctx, "word", w.name, null);
        try compilable_names.put(allocator, w.name, w.word_id);
    }

    // Pass 1b: trial compile quotation bodies to discover the compilable set
    var compilable_quotation_ids: std.AutoHashMapUnmanaged(u32, void) = .{};
    defer compilable_quotation_ids.deinit(allocator);
    for (quotations) |*q| {
        const effect = q.inferred_effect orelse blk: {
            // Compile-to-discover: `inferQuotationEffect` could not derive an effect for this
            // quotation, e.g., its body uses a row-variable combinator like `dip`, which
            // inference can't thread but codegen can via the row machinery.
            //
            // Find the smallest input arity for which the body compiles, reusing the codegen's
            // own abstract-stack tracking, and take the depth it settles on as the output count.
            // This lets a composite-nested quotation dispatched at runtime (`jitCallValue`)
            // compiled instead of left a null `code_ptr`.
            //
            // Gated on strict interpreter-free: only there does a null `code_ptr` trap rather
            // than fall back to the interpreter, so only there is it worth compiling these
            // quotations (and risking a mis-derived arity); fallback-capable builds run them
            // interpreted.
            if (!strict_interpreter_free) continue;
            var found: ?InferredEffect = null;
            var ic: u8 = 0;
            while (ic <= max_discovered_quotation_arity) : (ic += 1) {
                var dreason: ?NotCompilableReason = null;
                // No inferred types: the freeze-time pass sizes a quotation's table by its
                // `inferred_effect`, and this branch runs precisely when it has none.
                const dres = emitWordCAotPass(q.instructions, ic, 0, q.c_name, q.c_name, resolver, null, &compiled_names, null, null, null, allocator, null, &.{}, null, &dreason, null, null, interp_ctx, null, null, null, slot_maps_ptr, emit_slot_table_literals, q.source_file, strict_interpreter_free, meta.freestanding, false) catch {
                    emitAotEffectTrace(interp_ctx, q.c_name, ic, null, dreason);
                    continue;
                };
                if (dres.body) |b| allocator.free(b);
                emitAotEffectTrace(interp_ctx, q.c_name, ic, dres.discovered_output, null);
                found = .{ .input_count = ic, .output_count = dres.discovered_output };
                break;
            }
            const e = found orelse continue;
            q.inferred_effect = e;
            break :blk e;
        };
        var qreason: ?NotCompilableReason = null;
        const trial = emitWordCAotWithCName(
            q.instructions,
            effect.input_count,
            effect.output_count,
            q.c_name,
            q.c_name,
            resolver,
            null,
            &compiled_names,
            null,
            null,
            null,
            allocator,
            null,
            q.inferred_param_types,
            &qreason,
            null,
            null,
            interp_ctx,
            null,
            null,
            null,
            slot_maps_ptr,
            emit_slot_table_literals,
            q.source_file,
            strict_interpreter_free,
            meta.freestanding,
        ) catch {
            emitAotCodegenTrace(interp_ctx, "quot", q.c_name, qreason orelse .unknown_reason);
            continue;
        };
        allocator.free(trial);
        emitAotCodegenTrace(interp_ctx, "quot", q.c_name, null);
        try compilable_quotation_ids.put(allocator, q.quotation_id, {});
    }

    // Map quotation instruction body pointers to global quotation IDs so materializeQuotations
    // can pass the ID to jitPushQuotation for code_ptr attachment
    var quotation_id_map: std.AutoHashMapUnmanaged(usize, u32) = .{};
    defer quotation_id_map.deinit(allocator);
    for (quotations) |q| {
        try quotation_id_map.put(allocator, @intFromPtr(q.instructions.ptr), q.quotation_id);
    }

    // String literal table populated during pass 2.
    var string_literals: std.ArrayListUnmanaged(AotStringLiteral) = .{};
    defer string_literals.deinit(std.heap.page_allocator);

    // Quotation literal table populated during pass 2.
    var quotation_literals: std.ArrayListUnmanaged(AotQuotationLiteral) = .{};
    defer quotation_literals.deinit(std.heap.page_allocator);

    // Array/hash literal table populated during pass 2.
    var array_literals: std.ArrayListUnmanaged(AotArrayLiteral) = .{};
    defer array_literals.deinit(std.heap.page_allocator);

    // Pass 2a: compile with only the compilable set
    var compiled_bodies: std.ArrayListUnmanaged(struct { word_id: u32, body: []u8 }) = .{};
    defer {
        for (compiled_bodies.items) |item| allocator.free(item.body);
        compiled_bodies.deinit(allocator);
    }

    var actually_compiled: std.AutoHashMapUnmanaged(u32, void) = .{};
    defer actually_compiled.deinit(allocator);

    var pic_stats = PicStats{};
    var aot_fallback_emit_count: u32 = 0;
    var aot_fallback_builder = AotFallbackReportBuilder.init(allocator);
    defer aot_fallback_builder.deinit();

    for (words) |*w| {
        if (!compilable_names.contains(w.name)) continue;
        const raw_body = emitWordCAot(
            w.instructions,
            w.input_count,
            w.output_count,
            w.name,
            resolver,
            w.name,
            &compilable_names,
            &string_literals,
            &quotation_literals,
            &array_literals,
            allocator,
            if (w.stack_effect != null) &w.stack_effect.? else null,
            w.inferred_param_types,
            null,
            &quotation_id_map,
            w.pic_snapshot,
            interp_ctx,
            &pic_stats,
            &aot_fallback_emit_count,
            &aot_fallback_builder,
            slot_maps_ptr,
            emit_slot_table_literals,
            w.source_file,
            strict_interpreter_free,
            meta.freestanding,
        ) catch |err| switch (err) {
            error.NotCompilable => continue,
            else => return err,
        };
        const body = try patchMissingD0(raw_body, allocator);
        if (body.ptr != raw_body.ptr) allocator.free(raw_body);
        try compiled_bodies.append(allocator, .{ .word_id = w.word_id, .body = body });
        try actually_compiled.put(allocator, w.word_id, {});
    }

    // Pass 2b: compile quotation bodies with the compilable set
    var compiled_quotation_bodies: std.ArrayListUnmanaged(struct { id: u32, body: []u8 }) = .{};
    defer {
        for (compiled_quotation_bodies.items) |item| allocator.free(item.body);
        compiled_quotation_bodies.deinit(allocator);
    }
    for (quotations) |*q| {
        if (!compilable_quotation_ids.contains(q.quotation_id)) continue;
        const effect = q.inferred_effect.?;
        const raw_body = emitWordCAotWithCName(
            q.instructions,
            effect.input_count,
            effect.output_count,
            q.c_name,
            q.c_name,
            resolver,
            null,
            &compilable_names,
            &string_literals,
            &quotation_literals,
            &array_literals,
            allocator,
            null,
            q.inferred_param_types,
            null,
            &quotation_id_map,
            null,
            interp_ctx,
            null,
            &aot_fallback_emit_count,
            &aot_fallback_builder,
            slot_maps_ptr,
            emit_slot_table_literals,
            q.source_file,
            strict_interpreter_free,
            meta.freestanding,
        ) catch |err| switch (err) {
            error.NotCompilable => continue,
            else => return err,
        };
        const body = try patchMissingD0(raw_body, allocator);
        if (body.ptr != raw_body.ptr) allocator.free(raw_body);
        try compiled_quotation_bodies.append(allocator, .{ .id = q.quotation_id, .body = body });
        q.compiled = true;
    }

    diagnostics.pic_stats = pic_stats;

    // Enrich each `compound_uncompiled` fallback site with the callee's
    // failure reason and native flag. Recording happens during Pass 2
    // codegen, when the classification of a particular callee may not yet
    // be known; by this point Pass 1a has populated every `failure_reasons`
    // entry it is going to, and the `is_native` flag on each `AotWordDesc`
    // is final. Native callees never have a `NotCompilableReason` because
    // Pass 1a skips them; the strict-fallback diagnostic uses the flag to
    // emit a distinct message instead of saying "reason not categorized."
    var words_by_name: std.StringHashMapUnmanaged(*const AotWordDesc) = .{};
    defer words_by_name.deinit(allocator);
    for (words) |*w| {
        try words_by_name.put(allocator, w.name, w);
    }
    for (aot_fallback_builder.sites.items) |*site| {
        if (site.category != .compound_uncompiled) continue;
        site.callee_reason = failure_reasons.get(site.callee_word);
        if (words_by_name.get(site.callee_word)) |desc| {
            site.callee_is_native = desc.is_native;
        }
    }

    diagnostics.aot_fallback_report = try aot_fallback_builder.snapshot(allocator);

    // Decide jitInterpretedCall linkage from the finalized Pass 2 report.
    // The flag has to be available before the conditional callback-extern
    // emission below; the strict-mode build errors that depend on the
    // same totals still run later, after the full C source is assembled,
    // so that quotation-fallback warnings and the static cross-check are
    // populated and visible alongside the diagnostic.
    const jit_interpreted_call_linked =
        diagnostics.aot_fallback_report.totals[@intFromEnum(AotFallbackCategory.compound_uncompiled)] > 0;
    diagnostics.jit_interpreted_call_linked = jit_interpreted_call_linked;
    meta.jit_interpreted_call_linked = jit_interpreted_call_linked;

    // Collect quotation fallback warnings for all words with stack effects.
    {
        var fallbacks: std.ArrayListUnmanaged(QuotationFallbackWarning) = .{};
        for (words) |w| {
            if (w.is_native) continue;
            if (w.stack_effect == null) continue;
            const slot_map = buildQuotationSlotMap(&w.stack_effect.?) orelse continue;
            try collectQuotationFallbacks(
                &w.stack_effect.?,
                &slot_map,
                w.name,
                &fallbacks,
                allocator,
            );
        }
        if (fallbacks.items.len > 0) {
            diagnostics.quotation_fallbacks = try allocator.dupe(QuotationFallbackWarning, fallbacks.items);
        }
        fallbacks.deinit(allocator);
    }

    // Non-prelude reachable words must compile: this is the
    // "user code must compile" backstop, separate from the strict
    // compound-fallback gate above and from the strict prelude check
    // that runs in `main.zig` when `--interpreter-fallback=false`.
    // Prelude words that fail to compile are surfaced as warnings or
    // through `prelude_stats` instead of stopping the build here;
    // strict mode upgrades those surfaces into hard errors via the
    // dedicated checks, not via this gate.
    {
        var uncompiled: std.ArrayListUnmanaged(UncompiledWord) = .{};
        for (words) |w| {
            if (!w.is_prelude and !actually_compiled.contains(w.word_id)) {
                if (findUndiscoverableNestedDef(w.instructions)) |nested| {
                    try uncompiled.append(allocator, .{
                        .name = w.name,
                        .reason = .nested_definition,
                        .nested_definition = nested,
                    });
                } else {
                    const reason = failure_reasons.get(w.name) orelse .unknown_reason;
                    try uncompiled.append(allocator, .{ .name = w.name, .reason = reason });
                }
            }
        }
        if (uncompiled.items.len > 0) {
            diagnostics.uncompiled_words = try allocator.dupe(UncompiledWord, uncompiled.items);
            uncompiled.deinit(allocator);
            return error.UncompiledWords;
        }
        uncompiled.deinit(allocator);
    }

    // Serialized bytecode for reachable `method{` bodies that did not compile
    // to native code but can run via the interpreter in a full runtime image,
    // keyed by quotation_id. The image emitter renders these into the
    // dispatch-entry table so the loader registers them as interpreter-run
    // entries. Bytes are allocator-owned for the rest of this function.
    var interpreter_run_bodies: std.AutoHashMapUnmanaged(u32, []const u8) = .{};
    defer {
        var it = interpreter_run_bodies.valueIterator();
        while (it.next()) |bytes| allocator.free(bytes.*);
        interpreter_run_bodies.deinit(allocator);
    }
    // Set when at least one method body is serialized for interpreter-run
    // dispatch; forces the interpreter linked so the body has something to run
    // it (the body would otherwise be unreachable in an interpreter-free auto
    // build that emitted no other fallbacks).
    var force_interpreter_linked = false;

    // NOTE(ripta): Strict codegen: quotation bodies with inferred effects must compile.
    //              Bodies without inferred effects (row-polymorphic, e.g., `[ call ]`
    //              inside higher-order prelude words) are not yet handled, so this makes
    //              their parent words compilable by inlining the quotation at the call
    //              site. `>quotation`-constructed quotations are not in this set at all.
    //
    //              A reachable `method{` body that did not compile is handled
    //              separately: under a full runtime image with the interpreter
    //              available it is serialized to run interpreted; otherwise the
    //              build fails with a method-body-specific diagnostic.
    {
        const can_link_interpreter = !(interpreter_fallback == .false and lock_interpreter_setting);
        // Interpreter-run method bodies (e.g. generated struct field
        // getters) push a runtime `.struct_type` literal the by-value
        // serializer rejects. When a slot map is available, route them
        // through the image serializer so the literal slot-encodes and
        // the dispatch replay resolves it to the live runtime StructType;
        // otherwise such a method runs as a no-op when dispatched by an
        // interpreted quotation (`jitCallQuotation`).
        const method_slot_maps: ?ibc.SlotEncodingMaps = if (image_collection) |*coll| .{
            .typevalue_slot_index = &coll.effect_table.type_slot_index,
            .struct_type_slot_index = &coll.struct_index,
            .marker_slot_index = &coll.effect_table.marker_slot_index,
            .parameter_slot_index = &coll.effect_table.parameter_slot_index,
            .tagged_slot_index = &coll.effect_table.tagged_slot_index,
            .mutable_map_slot_index = &coll.effect_table.mutable_map_slot_index,
            .struct_instance_slot_index = &coll.effect_table.struct_instance_slot_index,
            .vector_slot_index = &coll.effect_table.vector_slot_index,
        } else null;
        // Quotation ids reified at an *escape* position (a quotation produced as a
        // word output). An escaping body that did not compile carries a null
        // `code_ptr`, so it can only run interpreted; this distinguishes it from a
        // merely-inlined or consumed-callback uncompiled quotation, which keep their
        // existing handling.
        var escaping_ids: std.AutoHashMapUnmanaged(u32, void) = .{};
        defer escaping_ids.deinit(allocator);
        for (quotation_literals.items) |lit| {
            if (lit.escape_q_id != std.math.maxInt(u32)) try escaping_ids.put(allocator, lit.escape_q_id, {});
        }
        var uncompiled_q: std.ArrayListUnmanaged(UncompiledQuotation) = .{};
        defer uncompiled_q.deinit(allocator);
        for (quotations) |q| {
            if (q.is_method_body) {
                if (q.compiled) continue;
                if (emit_runtime_image and can_link_interpreter) {
                    const maybe_bytes = if (method_slot_maps) |*sm|
                        ibc.serializeQuotationInstructionsForImage(q.instructions, allocator, sm)
                    else
                        serializeQuotationInstructions(q.instructions, allocator, null);
                    const bytes = maybe_bytes catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.NotEncodable => {
                            try uncompiled_q.append(allocator, .{
                                .quotation_id = q.quotation_id,
                                .c_name = q.c_name,
                                .method_body_reason = .non_serializable,
                            });
                            continue;
                        },
                    };
                    try interpreter_run_bodies.put(allocator, q.quotation_id, bytes);
                    force_interpreter_linked = true;
                } else {
                    try uncompiled_q.append(allocator, .{
                        .quotation_id = q.quotation_id,
                        .c_name = q.c_name,
                        .method_body_reason = if (!emit_runtime_image) .needs_runtime_image else .interpreter_locked,
                    });
                }
                continue;
            }
            // An escaping quotation whose body did not compile (Option C). The
            // reified Value carries a null `code_ptr`, so it can only run via the
            // interpreter. When the interpreter can be linked (default, auto,
            // fallback=true, or a runtime image) it is force-linked and the Value
            // runs interpreted at its `call` site; the serialized body travels
            // inside the Value itself, so no separate interpreter-run-bodies entry
            // is needed (unlike method dispatch). Only strict interpreter-free has
            // nothing to run it, so the build fails pointing at --emit-runtime-image.
            if (!q.compiled and escaping_ids.contains(q.quotation_id)) {
                if (can_link_interpreter) {
                    force_interpreter_linked = true;
                } else {
                    try uncompiled_q.append(allocator, .{
                        .quotation_id = q.quotation_id,
                        .c_name = q.c_name,
                        .method_body_reason = if (!emit_runtime_image) .needs_runtime_image else .interpreter_locked,
                        .reification = true,
                    });
                }
                continue;
            }
            // A composite-buried body keeps its callees undiscovered by design, so
            // failing to compile it is expected, not a compiler gap: it runs
            // interpreted at its dispatch site (the compiled `call` emits a
            // `jitCallQuotation` fallback that links the interpreter), or traps
            // through the interpreter-free `call` path under strict mode.
            if (!q.compiled and q.inferred_effect != null and !q.from_composite) {
                try uncompiled_q.append(allocator, .{
                    .quotation_id = q.quotation_id,
                    .c_name = q.c_name,
                });
            }
        }
        if (uncompiled_q.items.len > 0) {
            diagnostics.uncompiled_quotations = try allocator.dupe(UncompiledQuotation, uncompiled_q.items);
            return error.UncompiledQuotations;
        }
    }

    // Collect prelude compilation stats with failure reasons.
    {
        var total: u32 = 0;
        var compiled: u32 = 0;
        var uncompiled_list: std.ArrayListUnmanaged(UncompiledWord) = .{};
        for (words) |w| {
            if (!w.is_prelude or w.is_native) continue;
            total += 1;
            if (actually_compiled.contains(w.word_id)) {
                compiled += 1;
            } else {
                const reason = failure_reasons.get(w.name) orelse .unknown_reason;
                try uncompiled_list.append(allocator, .{ .name = w.name, .reason = reason });
            }
        }
        diagnostics.prelude_stats = .{
            .total = total,
            .compiled = compiled,
            .uncompiled = if (uncompiled_list.items.len > 0)
                try allocator.dupe(UncompiledWord, uncompiled_list.items)
            else
                &.{},
        };
        uncompiled_list.deinit(allocator);
    }

    // 3.5. String/symbol literal constants
    for (string_literals.items, 0..) |lit, lit_idx| {
        var idx_buf: [20]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{lit_idx}) catch unreachable;
        try out.appendSlice(allocator, "static const char onez_lit_");
        try out.appendSlice(allocator, idx_str);
        try out.appendSlice(allocator, "[] = \"");
        for (lit.data) |ch| {
            switch (ch) {
                '"' => try out.appendSlice(allocator, "\\\""),
                '\\' => try out.appendSlice(allocator, "\\\\"),
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => try out.appendSlice(allocator, "\\r"),
                '\t' => try out.appendSlice(allocator, "\\t"),
                0 => try out.appendSlice(allocator, "\\0"),
                else => {
                    const buf = [_]u8{ch};
                    try out.appendSlice(allocator, &buf);
                },
            }
        }
        try out.appendSlice(allocator, "\";\n");
    }
    if (string_literals.items.len > 0) {
        try out.appendSlice(allocator, "\n");
    }

    // 3.6. Quotation literal constants
    for (quotation_literals.items, 0..) |lit, lit_idx| {
        var idx_buf: [20]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{lit_idx}) catch unreachable;
        try out.appendSlice(allocator, "static const unsigned char onez_quot_");
        try out.appendSlice(allocator, idx_str);
        try out.appendSlice(allocator, "[] = {");
        for (lit.data, 0..) |byte, bi| {
            if (bi > 0) try out.appendSlice(allocator, ",");
            var byte_buf: [4]u8 = undefined;
            const byte_str = std.fmt.bufPrint(&byte_buf, "{d}", .{byte}) catch unreachable;
            try out.appendSlice(allocator, byte_str);
        }
        try out.appendSlice(allocator, "};\n");
    }
    if (quotation_literals.items.len > 0) {
        try out.appendSlice(allocator, "\n");
    }

    // 3.7. Array/hash literal constants
    for (array_literals.items, 0..) |lit, lit_idx| {
        var idx_buf: [20]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{lit_idx}) catch unreachable;
        try out.appendSlice(allocator, "static const unsigned char onez_arr_");
        try out.appendSlice(allocator, idx_str);
        try out.appendSlice(allocator, "[] = {");
        for (lit.data, 0..) |byte, bi| {
            if (bi > 0) try out.appendSlice(allocator, ",");
            var byte_buf: [4]u8 = undefined;
            const byte_str = std.fmt.bufPrint(&byte_buf, "{d}", .{byte}) catch unreachable;
            try out.appendSlice(allocator, byte_str);
        }
        try out.appendSlice(allocator, "};\n");
    }
    if (array_literals.items.len > 0) {
        try out.appendSlice(allocator, "\n");
    }

    // Callback extern declarations. Emitted after the linkage decision
    // is known so the `jitInterpretedCall` declaration is omitted from
    // binaries that have no `compound_uncompiled` fallback site and
    // therefore no call site to declare. Every other callback stays
    // unconditional because compiled bodies may legitimately reference
    // them in all artifact classes.
    if (jit_interpreted_call_linked) {
        try out.appendSlice(allocator, "extern int32_t jitInterpretedCall(uintptr_t ctx, uintptr_t word_id, uintptr_t line);\n");
    }
    try out.appendSlice(allocator, "extern int32_t jitSafepoint(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitRecover(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitCleanup(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitGet(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitWithParameter(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitIteratorOp(uintptr_t ctx, uintptr_t opcode);\n");
    try out.appendSlice(allocator, "extern int32_t jitNativeCall(uintptr_t ctx, uintptr_t fn_ptr);\n");
    try out.appendSlice(allocator, "extern int32_t jitPicTopTagsMatch(uintptr_t ctx, uintptr_t tag_a, uintptr_t tag_b);\n");
    try out.appendSlice(allocator, "extern int32_t jitPicDispatch(uintptr_t ctx, uintptr_t word_id, uintptr_t tag_a, uintptr_t tag_b);\n");
    try out.appendSlice(allocator, "extern int32_t jitPicTopTagMatch(uintptr_t ctx, uintptr_t tag_a);\n");
    try out.appendSlice(allocator, "extern int32_t jitPicDispatchUnary(uintptr_t ctx, uintptr_t word_id, uintptr_t tag_a);\n");
    try out.appendSlice(allocator, "extern int32_t jitNativeWordCall(uintptr_t ctx, uintptr_t word_id, uintptr_t line);\n");
    try out.appendSlice(allocator, aot_wrappers.registry_wrapper_externs);
    try out.appendSlice(allocator, "extern int32_t jitRefreshStack(uintptr_t jit_ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitRetainSlot(uintptr_t value_ptr);\n");
    try out.appendSlice(allocator, "extern int32_t jitReleaseSlot(uintptr_t value_ptr);\n");
    try out.appendSlice(allocator, "extern int32_t jitEnsureStackCapacity(uintptr_t jit_ctx, uintptr_t needed);\n");
    try out.appendSlice(allocator, "extern int32_t jitValidateParamEffects(uintptr_t ctx, uintptr_t effect_ptr);\n");
    try out.appendSlice(allocator, "extern int32_t jitCallQuotation(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitCallCodePtr(uintptr_t jit_ctx, uintptr_t code_ptr);\n");
    try out.appendSlice(allocator, "extern int32_t jitCallValue(uintptr_t jit_ctx, uintptr_t value_ptr);\n");
    try out.appendSlice(allocator, "extern int32_t jitTypeMismatchError(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitOverflowError(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitDivisionByZeroError(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitStackUnderflowError(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitNullCodePtrError(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitAppendNamedTraceFrame(uintptr_t ctx, uintptr_t name_ptr, uintptr_t name_len, uintptr_t line);\n");
    try out.appendSlice(allocator, "extern int32_t jitAppendBuiltinTraceFrame(uintptr_t ctx, uintptr_t frame_kind, uintptr_t line);\n");
    try out.appendSlice(allocator, "static int32_t onez_append_named_trace_frame(uintptr_t ctx, const char *name, uintptr_t len, uintptr_t line) { return jitAppendNamedTraceFrame(ctx, (uintptr_t)name, len, line); }\n");
    try out.appendSlice(allocator, "extern int32_t jitPushString(uintptr_t ctx, uintptr_t str_ptr, uintptr_t str_len);\n");
    try out.appendSlice(allocator, "extern int32_t jitPushSymbol(uintptr_t ctx, uintptr_t str_ptr, uintptr_t str_len);\n");
    try out.appendSlice(allocator, "extern int32_t jitPushQuotation(uintptr_t ctx, uintptr_t data, uintptr_t len, uintptr_t dest, uintptr_t quotation_id);\n");
    try out.appendSlice(allocator, "static int32_t onez_push_string(uintptr_t ctx, const char *str, uintptr_t len) { return jitPushString(ctx, (uintptr_t)str, len); }\n");
    try out.appendSlice(allocator, "static int32_t onez_push_symbol(uintptr_t ctx, const char *str, uintptr_t len) { return jitPushSymbol(ctx, (uintptr_t)str, len); }\n");
    try out.appendSlice(allocator, "static int32_t onez_push_quotation(uintptr_t ctx, const unsigned char *data, uintptr_t len, uintptr_t dest, uintptr_t quotation_id) { return jitPushQuotation(ctx, (uintptr_t)data, len, dest, quotation_id); }\n");
    try out.appendSlice(allocator, "extern int32_t jitPushArray(uintptr_t ctx, uintptr_t data_ptr, uintptr_t data_len);\n");
    try out.appendSlice(allocator, "static int32_t onez_push_array(uintptr_t ctx, const unsigned char *data, uintptr_t len) { return jitPushArray(ctx, (uintptr_t)data, len); }\n");
    // Slot-table-indexed typed-literal helpers. The runtime caches
    // each slot table's pointer on Context during image loading; the
    // jit functions index through it to recover the runtime pointer
    // and push the corresponding Value. Used for `.type_val`,
    // `.struct_type`, `.marker`, `.parameter`, and `.tagged` literals;
    // any miss surfaces as `non_serializable_literal` at codegen time
    // rather than a runtime name lookup.
    try out.appendSlice(allocator, "extern int32_t jitPushTypeValueSlot(uintptr_t ctx, uintptr_t slot);\n");
    try out.appendSlice(allocator, "static inline int32_t onez_push_typevalue_slot(uintptr_t ctx, uintptr_t slot) { return jitPushTypeValueSlot(ctx, slot); }\n");
    try out.appendSlice(allocator, "extern int32_t jitPushStructTypeSlot(uintptr_t ctx, uintptr_t slot);\n");
    try out.appendSlice(allocator, "static inline int32_t onez_push_struct_type_slot(uintptr_t ctx, uintptr_t slot) { return jitPushStructTypeSlot(ctx, slot); }\n");
    try out.appendSlice(allocator, "extern int32_t jitPushMarkerSlot(uintptr_t ctx, uintptr_t slot);\n");
    try out.appendSlice(allocator, "static inline int32_t onez_push_marker_slot(uintptr_t ctx, uintptr_t slot) { return jitPushMarkerSlot(ctx, slot); }\n");
    try out.appendSlice(allocator, "extern int32_t jitPushParameterSlot(uintptr_t ctx, uintptr_t slot);\n");
    try out.appendSlice(allocator, "static inline int32_t onez_push_parameter_slot(uintptr_t ctx, uintptr_t slot) { return jitPushParameterSlot(ctx, slot); }\n");
    try out.appendSlice(allocator, "extern int32_t jitPushTaggedSlot(uintptr_t ctx, uintptr_t slot);\n");
    try out.appendSlice(allocator, "static inline int32_t onez_push_tagged_slot(uintptr_t ctx, uintptr_t slot) { return jitPushTaggedSlot(ctx, slot); }\n");
    try out.appendSlice(allocator, "extern int32_t jitPushMutableMapSlot(uintptr_t ctx, uintptr_t slot);\n");
    try out.appendSlice(allocator, "static inline int32_t onez_push_mutable_map_slot(uintptr_t ctx, uintptr_t slot) { return jitPushMutableMapSlot(ctx, slot); }\n");
    try out.appendSlice(allocator, "extern int32_t jitPushStructInstanceSlot(uintptr_t ctx, uintptr_t slot);\n");
    try out.appendSlice(allocator, "static inline int32_t onez_push_struct_instance_slot(uintptr_t ctx, uintptr_t slot) { return jitPushStructInstanceSlot(ctx, slot); }\n");
    try out.appendSlice(allocator, "extern int32_t jitPushVectorSlot(uintptr_t ctx, uintptr_t slot);\n");
    try out.appendSlice(allocator, "static inline int32_t onez_push_vector_slot(uintptr_t ctx, uintptr_t slot) { return jitPushVectorSlot(ctx, slot); }\n");
    try out.appendSlice(allocator, "extern int32_t aotSatisfiesAndDispatch(uintptr_t ctx, uintptr_t dispatch_id, uintptr_t slot_idx, uintptr_t arity, uintptr_t line);\n");
    try out.appendSlice(allocator, "extern int32_t aotSatisfiesAndDispatchCombinator(uintptr_t ctx, uintptr_t dispatch_id, uintptr_t slot_idx, uintptr_t arity, uintptr_t line);\n");
    try out.appendSlice(allocator, "extern int32_t aotTryDispatchGenericOrCall(uintptr_t ctx, uintptr_t dispatch_id, uintptr_t word_id);\n");
    try out.appendSlice(allocator, "\n");

    // 4a. Forward declarations (only for successfully compiled words)
    for (words) |w| {
        if (!actually_compiled.contains(w.word_id)) continue;
        const mangled = try mangleWordName(w.name, allocator);
        defer allocator.free(mangled);
        try out.appendSlice(allocator, "int32_t ");
        try out.appendSlice(allocator, mangled);
        try out.appendSlice(allocator, "(uintptr_t jit_ctx)");
        if (!w.is_native) {
            if (w.is_generated) {
                try appendGeneratedWordAsmNameClause(&out, allocator, w.name, w.parent);
            } else {
                try appendAsmNameClause(&out, allocator, w.name);
            }
        }
        try out.appendSlice(allocator, ";\n");
    }
    // Forward declarations for compiled quotation bodies
    for (compiled_quotation_bodies.items) |item| {
        for (quotations) |q| {
            if (q.quotation_id == item.id) {
                try out.appendSlice(allocator, "int32_t ");
                try out.appendSlice(allocator, q.c_name);
                try out.appendSlice(allocator, "(uintptr_t jit_ctx)");
                try appendQuotationAsmNameClause(&out, allocator, q);
                try out.appendSlice(allocator, ";\n");
                break;
            }
        }
    }
    try out.appendSlice(allocator, "\n");

    // 4b. Emit compiled function bodies
    for (compiled_bodies.items) |item| {
        for (words) |w| {
            if (w.word_id != item.word_id) continue;
            if (w.source_line == 0) break;
            const sf = w.source_file orelse break;
            if (sf.len == 0) break;
            try appendLineDirective(&out, allocator, sf, w.source_line);
            break;
        }
        try out.appendSlice(allocator, item.body);
        try out.appendSlice(allocator, "\n");
    }
    // 4c. Emit compiled quotation function bodies
    for (compiled_quotation_bodies.items) |item| {
        for (quotations) |q| {
            if (q.quotation_id != item.id) continue;
            if (q.source_line == 0) break;
            const sf = q.source_file orelse break;
            if (sf.len == 0) break;
            try appendLineDirective(&out, allocator, sf, q.source_line);
            break;
        }
        try out.appendSlice(allocator, item.body);
        try out.appendSlice(allocator, "\n");
    }

    // 5. Dispatch table
    try out.appendSlice(allocator, "typedef int32_t (*onez_word_fn_t)(uintptr_t);\n");
    try out.appendSlice(allocator, "static onez_word_fn_t onez_dispatch_table[] = {\n");

    const table_size = max_word_id + 1;
    for (0..table_size) |id| {
        var found = false;
        for (words) |w| {
            if (w.word_id == id and actually_compiled.contains(w.word_id)) {
                const mangled = try mangleWordName(w.name, allocator);
                defer allocator.free(mangled);
                try out.appendSlice(allocator, "    ");
                try out.appendSlice(allocator, mangled);
                try out.appendSlice(allocator, ",\n");
                found = true;
                break;
            }
        }
        if (!found) {
            try out.appendSlice(allocator, "    NULL,\n");
        }
    }
    try out.appendSlice(allocator, "};\n\n");

    // 5b. Word name table. Read by both `jitInterpretedCall` (compound
    // fallback in permissive AOT) and `jitNativeWordCall` (native dispatch
    // and trace-frame attribution), so it is required in every AOT
    // artifact, not only those that link the interpreter.
    try out.appendSlice(allocator, "static const char *onez_word_names[] = {\n");
    for (0..table_size) |id| {
        var found = false;
        for (words) |w| {
            if (w.word_id == id) {
                try out.appendSlice(allocator, "    \"");
                try out.appendSlice(allocator, w.name);
                try out.appendSlice(allocator, "\",\n");
                found = true;
                break;
            }
        }
        if (!found) {
            try out.appendSlice(allocator, "    NULL,\n");
        }
    }
    try out.appendSlice(allocator, "};\n\n");

    // 5c. Quotation function table
    if (quotations.len > 0) {
        var max_q_id: u32 = 0;
        for (quotations) |q| {
            if (q.quotation_id >= max_q_id) max_q_id = q.quotation_id;
        }
        const q_table_size = max_q_id + 1;

        try out.appendSlice(allocator, "static onez_word_fn_t onez_quotation_table[] = {\n");
        for (0..q_table_size) |id| {
            var found = false;
            for (quotations) |q| {
                if (q.quotation_id == id and q.compiled) {
                    try out.appendSlice(allocator, "    ");
                    try out.appendSlice(allocator, q.c_name);
                    try out.appendSlice(allocator, ",\n");
                    found = true;
                    break;
                }
            }
            if (!found) {
                try out.appendSlice(allocator, "    NULL,\n");
            }
        }
        try out.appendSlice(allocator, "};\n\n");
    }

    // Interpreter-free decision: an AOT binary can drop the interpreter when
    // either the user explicitly opted out and locked the setting, or auto
    // mode confirmed no fallback was emitted. Computed here, before the
    // image emission, so the image emitter can pick metadata-only vs
    // full runtime image based on the resolved class.
    const interpreter_callbacks_emitted = aot_fallback_emit_count > 0;
    // A serialized interpreter-run method body needs the interpreter linked to
    // execute it, so it overrides an otherwise interpreter-free auto build. It
    // is only ever set when the interpreter can be linked (never under
    // `--interpreter-fallback=false --lock-interpreter-setting`), so this never
    // contradicts a locked-off setting.
    const interpreter_free = !force_interpreter_linked and switch (interpreter_fallback) {
        .true => false,
        .false => lock_interpreter_setting,
        .auto => !interpreter_callbacks_emitted,
    };

    // Image emission. Two paths produce distinct image shapes:
    //
    // 1. `--emit-runtime-image` -> full runtime image with executable
    //    body bytecode and blob entries. Produces a runtime-image-aot
    //    or interpreter binary, depending on linkage.
    // 2. Any other AOT build -> metadata-only image. The dictionary is
    //    rehydrated for read-only introspection (`>word-info`,
    //    `all-words`, stack traces); bodies stay empty. Slot tables for
    //    type-carrier literals are emitted in both shapes so compiled
    //    code never falls back to runtime name lookup for type
    //    identity. Interpreter-linked builds reuse the prelude-allocated
    //    TypeValues by name during loader patching, preserving identity
    //    with the dispatch table the prelude reload populates.
    if (interp_ctx) |ctx| {
        const want_metadata_only = !emit_runtime_image;
        const manifest = image_manifest orelse return IrCodegenError.CompilationFailed;
        const collection = if (image_collection) |*coll| coll else return IrCodegenError.CompilationFailed;

        // Map each word's dispatch id to its name so the image's dispatch-entry
        // rows can carry the generic word name; the loader replays it into the
        // runtime name -> dispatch_id map. Built from the post-freeze word list
        // because user generics are no longer in the dictionary at this point.
        var dispatch_id_names: std.AutoHashMapUnmanaged(u32, []const u8) = .{};
        defer dispatch_id_names.deinit(allocator);
        for (words) |w| {
            if (w.dispatch_id != 0) try dispatch_id_names.put(allocator, w.dispatch_id, w.name);
        }
        // The post-freeze word list above omits empty-body generated generics
        // (struct field getters/setters), whose dispatch entries still need a
        // generic name so the loader can patch the loaded word's dispatch_id
        // to match its replayed methods. Add every module-cache word carrying
        // a dispatch_id, covering those getters.
        {
            var mod_it = ctx.module_cache_value.map.valueIterator();
            while (mod_it.next()) |cached| {
                if (cached.* != .module) continue;
                var w_it = cached.*.module.words.iterator();
                while (w_it.next()) |we| {
                    if (we.value_ptr.dispatch_id != 0) {
                        try dispatch_id_names.put(allocator, we.value_ptr.dispatch_id, we.key_ptr.*);
                    }
                }
            }
        }

        const stats = aot_image_emit_mod.emitImageCFromCollection(
            &out,
            allocator,
            ctx,
            manifest,
            &image_word_lookup,
            collection,
            .{ .metadata_only = want_metadata_only },
            &quotation_id_map,
            &dispatch_id_names,
            &interpreter_run_bodies,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The freeze classifier already concluded each
            // structural body is shaped for static-C-data, so a
            // NotEncodable here points at a classifier/encoder
            // mismatch -- surface as NotCompilable so the caller
            // falls back to the existing codegen-failure pipeline.
            error.NotEncodable => return IrCodegenError.NotCompilable,
        };
        diagnostics.image_stats = stats;

        // Surface the freshly-emitted image through the embedded
        // metadata record. `format_version` is the source of truth
        // shared with `aot_image_emit.zig` and the loader, so the
        // inspector reports the same number the binary actually
        // carries in `onez_image_header.format_version`.
        if (want_metadata_only) {
            meta.metadata_image_present = true;
        } else {
            meta.runtime_image_present = true;
        }
        meta.runtime_image_format_version = aot_image_emit_mod.format_version;
        meta.runtime_image_blob_present = stats.blob_present;
        meta.runtime_image_word_count = stats.word_count;
        meta.runtime_image_struct_type_slot_count = stats.struct_type_slot_count;
        meta.runtime_image_marker_slot_count = stats.marker_slot_count;
        meta.runtime_image_mutable_map_slot_count = stats.mutable_map_slot_count;
        meta.runtime_image_struct_instance_slot_count = stats.struct_instance_slot_count;
        meta.runtime_image_vector_slot_count = stats.vector_slot_count;
        meta.runtime_image_protocoldescriptor_slot_count = stats.protocoldescriptor_slot_count;
        meta.runtime_image_constraintcombinator_slot_count = stats.constraintcombinator_slot_count;
        meta.runtime_image_dispatch_entry_slot_count = stats.dispatch_entry_slot_count;
        meta.runtime_image_parameter_slot_count = stats.parameter_slot_count;
        meta.runtime_image_tagged_slot_count = stats.tagged_slot_count;
    }

    // Static cross-check: independently scan the assembled C source for
    // `jitInterpretedCall(`, `jitNativeWordCall(`, and `jitCallQuotation(`
    // call sites and confirm the count agrees with what the build-time
    // inventory recorded. Run it after compiled bodies are appended so
    // the call sites the bodies contain are visible, and before the
    // locked-fallback return so that the diagnostic is available on
    // both the success path and the build-error path. The
    // `jit_interpreted_call_linked` flag controls whether the cross-check
    // expects an `extern` declaration in the source as part of the raw
    // `jitInterpretedCall(` count.
    diagnostics.aot_fallback_report.static_check =
        verifyAotFallbackInventory(out.items, &diagnostics.aot_fallback_report, jit_interpreted_call_linked);

    // Strict AOT cannot tolerate compound-word fallback to the interpreter:
    // a compiled caller reaching `jitInterpretedCall` for an uncompiled
    // compound callee is the exact shape this check rejects. Surface every
    // blocking site with its caller, callee, and the callee's
    // `NotCompilableReason` so the build report names the punch list to
    // fix. Fires regardless of `--lock-interpreter-setting`; the lock gate
    // below still covers the residual native / quotation cases.
    if (interpreter_fallback == .false and jit_interpreted_call_linked) {
        return IrCodegenError.CompoundFallbackRequired;
    }

    // mode=false + lock=true + an emitted fallback is a build error: the user
    // asked for a binary that can never call the interpreter, but codegen
    // needed it. Without this check the binary would crash at runtime via
    // allow_interpreted_fallback.
    if (interpreter_fallback == .false and lock_interpreter_setting and interpreter_callbacks_emitted) {
        return IrCodegenError.InterpreterRequiredButLocked;
    }

    // Assertion: if the build classified the binary as not needing
    // `jitInterpretedCall`, the assembled C source must contain zero
    // `jitInterpretedCall(` call sites. A non-zero count here means a
    // codegen path emitted a call without recording a
    // `compound_uncompiled` fallback site through `noteAotFallbackEmission`,
    // and the inventory and the final C disagree.
    if (!jit_interpreted_call_linked and
        diagnostics.aot_fallback_report.static_check.observed_jit_interpreted_calls > 0)
    {
        return IrCodegenError.JitInterpretedCallLeaked;
    }

    // A build without `--emit-runtime-image` embeds a metadata-only image whose word bodies are
    // empty. When freeze detection found a non-prelude uncompiled word reachable from a
    // composite-buried quotation, that body can never run correctly: an interpreter-linked build
    // would dispatch the quotation interpreted and run the word's empty rehydrated body as a
    // silent no-op, and an interpreter-free build cannot run it at all. The build must fail
    // instead of producing a silently wrong binary. Prelude reach stays fine: the linked
    // interpreter reloads the prelude with real bodies.
    if (interp_ctx != null and !emit_runtime_image and interpreted_reach.len > 0) {
        return IrCodegenError.RuntimeImageRequired;
    }

    // Emit the interpreter-linked sentinel as a non-static global. The linker
    // GC drops lib1z.a when this is 0; the symbol itself is a redundant marker
    // alongside the inspect-friendly string below. `interpreter_free` is
    // resolved earlier so the image emission can pick its mode.
    try out.appendSlice(allocator, if (interpreter_free)
        "int onez_interpreter_linked = 0;\n\n"
    else
        "int onez_interpreter_linked = 1;\n\n");

    // Embedded ASCII marker that `1z inspect` byte-scans for. Lives in rodata
    // so it survives `strip`, and is force-kept by `__attribute__((used))` so
    // -dead_strip / --gc-sections do not GC it. The value byte ('0' or '1')
    // mirrors onez_interpreter_linked; the surrounding sentinel keeps the
    // search needle unambiguous.
    try out.appendSlice(allocator, if (interpreter_free)
        "__attribute__((used)) static const char onez_inspect_v1[] = \"<<1Z_INSPECT_V1:interpreter_linked=0>>\";\n\n"
    else
        "__attribute__((used)) static const char onez_inspect_v1[] = \"<<1Z_INSPECT_V1:interpreter_linked=1>>\";\n\n");

    // Core metadata block. Lives in rodata next to the inspect sentinel;
    // the `<<1Z_AOT_META_V1` ... `>>` delimiters give an external
    // inspector a stable byte-scan target. Schema-version is the first
    // key after the open marker so future format changes can flip both
    // the open marker (V2) and the schema-version field together. The
    // artifact class is computed here from the post-image-emission
    // metadata so it agrees with the embedded `interpreter-linked`,
    // `runtime-image-present`, and `metadata-image-present` booleans.
    const image_kind: ImageKind = if (meta.runtime_image_present)
        .full_runtime
    else if (meta.metadata_image_present)
        .metadata_only
    else
        .none;
    const artifact_class = classifyArtifact(!interpreter_free, image_kind);
    try emitAotMetadata(allocator, &out, meta, !interpreter_free, artifact_class);

    // 6. Main entry point. Interpreter-free binaries skip prelude loading
    // since every reachable word was compiled and registered explicitly via
    // onez_runtime_register_compiled below; calling onez_init() would drag
    // the parser/tokenizer/statement processor into the binary just to
    // re-evaluate the prelude source at startup.
    //
    // Freestanding mode swaps `main` for `kernel_main` because there is no
    // libc-supplied startup to call us with argc/argv. The linker script
    // introduced by the platform layer references `kernel_main` directly.
    if (meta.freestanding) {
        try out.appendSlice(allocator, "int kernel_main(void) {\n");
    } else {
        try out.appendSlice(allocator, "int main(int argc, char **argv) {\n");
    }
    try out.appendSlice(allocator, if (interpreter_free)
        "    void *rt = onez_init_no_prelude();\n"
    else
        "    void *rt = onez_init();\n");

    // Register the compiled-quotation table before loading the runtime image.
    // The image loader decodes module-private container slot values (mutable
    // maps, struct instances, vectors), and a quotation buried in one -- e.g.
    // the lint registry's `check` quotations -- attaches its compiled code_ptr
    // from this table at decode time, so the table must be in place first.
    if (quotations.len > 0) {
        var max_q_id_pre: u32 = 0;
        for (quotations) |q| {
            if (q.quotation_id >= max_q_id_pre) max_q_id_pre = q.quotation_id;
        }
        var q_size_buf_pre: [20]u8 = undefined;
        const q_size_str_pre = std.fmt.bufPrint(&q_size_buf_pre, "{d}", .{max_q_id_pre + 1}) catch unreachable;

        try out.appendSlice(allocator, "    onez_runtime_register_quotations(rt, onez_quotation_table, ");
        try out.appendSlice(allocator, q_size_str_pre);
        try out.appendSlice(allocator, ");\n");
    }

    // Image hookup: rehydrate module-private dictionary entries (and,
    // for runtime-image mode, blob TypeValues and bodies) before user
    // code runs. Emitted by `aot_image_emit.emitImageC` above when the
    // build chose either the full runtime image or the metadata-only
    // image path. The loader handles both shapes; metadata-only entries
    // simply have empty bodies and zero typevalue_slot.
    if (meta.runtime_image_present or meta.metadata_image_present) {
        try out.appendSlice(allocator,
            \\    extern const onez_image_header_t onez_image_v1;
            \\    extern const struct onez_typevalue *onez_image_typevalue_slots[];
            \\
        );
        if (meta.runtime_image_struct_type_slot_count > 0) {
            try out.appendSlice(allocator,
                \\    extern struct onez_struct_type *onez_image_struct_type_slots[];
                \\
            );
        }
        if (meta.runtime_image_marker_slot_count > 0) {
            try out.appendSlice(allocator,
                \\    extern struct onez_marker *onez_image_marker_slots[];
                \\
            );
        }
        if (meta.runtime_image_parameter_slot_count > 0) {
            try out.appendSlice(allocator,
                \\    extern struct onez_parameter *onez_image_parameter_slots[];
                \\
            );
        }
        if (meta.runtime_image_tagged_slot_count > 0) {
            try out.appendSlice(allocator,
                \\    extern const struct onez_value *onez_image_tagged_slots[];
                \\
            );
        }
        if (meta.runtime_image_mutable_map_slot_count > 0) {
            try out.appendSlice(allocator,
                \\    extern struct onez_mutable_map *onez_image_mutable_map_slots[];
                \\
            );
        }
        if (meta.runtime_image_struct_instance_slot_count > 0) {
            try out.appendSlice(allocator,
                \\    extern struct onez_struct_instance *onez_image_struct_instance_slots[];
                \\
            );
        }
        if (meta.runtime_image_vector_slot_count > 0) {
            try out.appendSlice(allocator,
                \\    extern struct onez_vector *onez_image_vector_slots[];
                \\
            );
        }
        if (meta.runtime_image_protocoldescriptor_slot_count > 0) {
            try out.appendSlice(allocator,
                \\    extern struct onez_protocoldescriptor *onez_image_protocoldescriptor_slots[];
                \\
            );
        }
        if (meta.runtime_image_constraintcombinator_slot_count > 0) {
            try out.appendSlice(allocator,
                \\    extern struct onez_constraintcombinator *onez_image_constraintcombinator_slots[];
                \\
            );
        }

        try out.appendSlice(allocator, "    if (onez_load_runtime_image(rt, &onez_image_v1, onez_image_typevalue_slots, ");
        try out.appendSlice(allocator, if (meta.runtime_image_struct_type_slot_count > 0)
            "onez_image_struct_type_slots, "
        else
            "NULL, ");
        try out.appendSlice(allocator, if (meta.runtime_image_marker_slot_count > 0)
            "onez_image_marker_slots, "
        else
            "NULL, ");
        try out.appendSlice(allocator, if (meta.runtime_image_parameter_slot_count > 0)
            "onez_image_parameter_slots, "
        else
            "NULL, ");
        try out.appendSlice(allocator, if (meta.runtime_image_tagged_slot_count > 0)
            "onez_image_tagged_slots, "
        else
            "NULL, ");
        try out.appendSlice(allocator, if (meta.runtime_image_mutable_map_slot_count > 0)
            "onez_image_mutable_map_slots, "
        else
            "NULL, ");
        try out.appendSlice(allocator, if (meta.runtime_image_struct_instance_slot_count > 0)
            "onez_image_struct_instance_slots, "
        else
            "NULL, ");
        try out.appendSlice(allocator, if (meta.runtime_image_vector_slot_count > 0)
            "onez_image_vector_slots, "
        else
            "NULL, ");
        try out.appendSlice(allocator, if (meta.runtime_image_protocoldescriptor_slot_count > 0)
            "onez_image_protocoldescriptor_slots, "
        else
            "NULL, ");
        try out.appendSlice(allocator, if (meta.runtime_image_constraintcombinator_slot_count > 0)
            "onez_image_constraintcombinator_slots"
        else
            "NULL");
        try out.appendSlice(allocator,
            \\) != 0) {
            \\        onez_print_error(rt);
            \\        onez_deinit(rt);
            \\        return 1;
            \\    }
            \\
        );
    }

    if (!meta.freestanding) {
        // command-line-args excludes the program name, matching the
        // interpreter (where it is the args after the script path). argv[0] is
        // the program name, so program_args = argv[1..]; current_source stays
        // argv[0] for error attribution, set after onez_set_args (which would
        // otherwise derive current_source from the new argv[0]).
        try out.appendSlice(allocator,
            \\    if (argc > 0) {
            \\        onez_set_args(rt, argc - 1, argv + 1);
            \\        onez_set_source(rt, argv[0], __builtin_strlen(argv[0]));
            \\    } else {
            \\        onez_set_args(rt, 0, argv);
            \\    }
            \\
        );
    }

    // Register statically linked FFI libraries.
    if (static_libs.len > 0) {
        try out.appendSlice(allocator, "    {\n");
        try out.appendSlice(allocator, "        static const char *static_ffi_libs[] = {\n");
        for (static_libs) |lib| {
            try out.appendSlice(allocator, "            \"");
            try out.appendSlice(allocator, lib);
            try out.appendSlice(allocator, "\",\n");
        }
        try out.appendSlice(allocator, "        };\n");

        var count_buf: [20]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{static_libs.len}) catch unreachable;
        try out.appendSlice(allocator, "        onez_set_static_libs(rt, static_ffi_libs, ");
        try out.appendSlice(allocator, count_str);
        try out.appendSlice(allocator, ");\n");
        try out.appendSlice(allocator, "    }\n");
    }

    // Configure interpreter fallback setting.
    // In auto mode, the per-emission counter records each AOT-mode CALL
    // through interpreted_call_fn or call_quotation_fn; a non-zero count
    // means the interpreter is actually needed at runtime.
    const resolved_fallback: InterpreterFallbackMode = if (interpreter_fallback == .auto) blk: {
        const mode: InterpreterFallbackMode = if (interpreter_callbacks_emitted) .true else .false;
        diagnostics.resolved_interpreter_fallback = mode;
        diagnostics.has_interpreter_callbacks = interpreter_callbacks_emitted;
        break :blk mode;
    } else interpreter_fallback;
    {
        const default_allowed: u8 = switch (resolved_fallback) {
            .true => 1,
            .false => 0,
            .auto => unreachable,
        };
        const locked: u8 = if (lock_interpreter_setting) 1 else 0;

        if (meta.freestanding) {
            // No libc means no getenv/fprintf; the compile-time-resolved fallback is also the
            // runtime fallback. The `locked` bit is recorded in metadata for inspection but has
            // no effect here because there is no env-var override to lock against.
            var fb_buf: [64]u8 = undefined;
            const fb_str = std.fmt.bufPrint(
                &fb_buf,
                "    onez_set_interpreter_fallback(rt, {d});\n",
                .{default_allowed},
            ) catch unreachable;
            try out.appendSlice(allocator, fb_str);
        } else {
            var fb_buf: [128]u8 = undefined;
            const fb_str = std.fmt.bufPrint(&fb_buf, "    {{\n        int fallback_allowed = {d};\n        int setting_locked = {d};\n", .{ default_allowed, locked }) catch unreachable;
            try out.appendSlice(allocator, fb_str);
            try out.appendSlice(allocator,
                \\        const char *env = getenv("ONEZ_INTERPRETER_FALLBACK");
                \\        if (setting_locked && env) {
                \\            fprintf(stderr, "Fatal: ONEZ_INTERPRETER_FALLBACK is set but the interpreter setting is locked; remove the env var or rebuild without lock\n");
                \\            return 1;
                \\        }
                \\        if (!setting_locked && env) {
                \\            if (env[0] == '0') fallback_allowed = 0;
                \\            else if (env[0] == '1') fallback_allowed = 1;
                \\        }
                \\        onez_set_interpreter_fallback(rt, fallback_allowed);
                \\    }
                \\
            );
        }
    }

    // Word tracing. The env var mirrors the CLI's `--trace-words` flag: set
    // but empty traces every word, a non-empty value is the comma-separated
    // pattern filter. Freestanding builds have no getenv, so the knob is
    // dropped there along with the fallback sniff.
    if (!meta.freestanding) {
        try out.appendSlice(allocator,
            \\    {
            \\        const char *trace_env = getenv("ONEZ_TRACE_WORDS");
            \\        if (trace_env) onez_set_trace_words(rt, trace_env);
            \\    }
            \\
        );

        // Runtime stdlib resolution. A program that does a runtime `use` / `load`
        // (e.g. an AOT lint binary parsing a source file with its own imports)
        // resolves stdlib modules through the context's stdlib path, which the
        // AOT binary otherwise leaves unset. Honor `ONEZ_STDLIB` just as the
        // interpreter's CLI does, so such programs run without a baked-in path.
        try out.appendSlice(allocator,
            \\    {
            \\        const char *stdlib_env = getenv("ONEZ_STDLIB");
            \\        if (stdlib_env) onez_set_stdlib_path_z(rt, stdlib_env);
            \\    }
            \\
        );
    }

    // Format dispatch table size
    var size_buf: [20]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{table_size}) catch unreachable;

    try out.appendSlice(allocator, "    onez_runtime_register_compiled(rt, onez_dispatch_table, onez_word_names, ");
    try out.appendSlice(allocator, size_str);
    try out.appendSlice(allocator, ");\n");

    // The compiled-quotation table is registered earlier, before the runtime
    // image load, so container-slot quotation values decode with their
    // code_ptr attached.

    // Replay the image's method dispatch entries now that both the image
    // surfaces (modules, typevalue slots) and the quotation-function table
    // are in place. Each entry's compiled body resolves through the
    // just-registered quotation table; interpreter-run entries resolve their
    // body bytecode directly, so replay runs even with no compiled
    // quotations (a method reached only through an interpreted quotation has
    // no compiled body but still needs its dispatch entry registered).
    //
    // On freestanding the call is skipped when the image carries zero
    // entries, keeping the zero-dispatch binary free of the replay path.
    if (meta.runtime_image_present or meta.metadata_image_present) {
        if (!meta.freestanding or meta.runtime_image_dispatch_entry_slot_count > 0) {
            try out.appendSlice(allocator,
                \\    if (onez_replay_method_dispatch(rt) != 0) {
                \\        onez_print_error(rt);
                \\        onez_deinit(rt);
                \\        return 1;
                \\    }
                \\
            );
        }
    }

    var id_buf: [20]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{entry_word_id}) catch unreachable;

    try out.appendSlice(allocator, "    int32_t status = onez_runtime_run(rt, ");
    try out.appendSlice(allocator, id_str);
    try out.appendSlice(allocator, ");\n");
    try out.appendSlice(allocator, "    if (status != 0) onez_print_error(rt);\n");

    if (!interpreter_free and !meta.freestanding) {
        try out.appendSlice(allocator, "    onez_fire_exit_hooks(rt, (status != 0) ? 1 : 0);\n");
    }

    try out.appendSlice(allocator, "    onez_deinit(rt);\n");
    try out.appendSlice(allocator, "    return (status != 0) ? 1 : 0;\n");
    try out.appendSlice(allocator, "}\n");

    return out.toOwnedSlice(allocator);
}

/// Render the core metadata block as a single
/// `__attribute__((used)) static const char` rodata literal. The byte
/// shape is fixed across builds so an external inspector can scan for
/// `<<1Z_AOT_META_V1` and parse the trailing newline-delimited
/// key=value lines until `>>`.
fn emitAotMetadata(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    meta: AotMetadata,
    interpreter_linked: bool,
    artifact_class: ArtifactClass,
) !void {
    const fallback_str: []const u8 = switch (meta.interpreter_fallback_mode) {
        .true => "true",
        .false => "false",
        .auto => "auto",
    };
    const yes_no_interp_linked: []const u8 = if (interpreter_linked) "yes" else "no";
    const yes_no_jic_linked: []const u8 = if (meta.jit_interpreted_call_linked) "yes" else "no";
    const yes_no_locked: []const u8 = if (meta.interpreter_setting_locked) "yes" else "no";
    const yes_no_runtime_image: []const u8 = if (meta.runtime_image_present) "yes" else "no";
    const yes_no_metadata_image: []const u8 = if (meta.metadata_image_present) "yes" else "no";

    try out.appendSlice(allocator, "__attribute__((used)) static const char onez_aot_meta_v1[] =\n");
    try out.appendSlice(allocator, "    \"<<1Z_AOT_META_V1\\n\"\n");
    try out.appendSlice(allocator, "    \"schema-version=3\\n\"\n");
    try out.appendSlice(allocator, "    \"artifact-class=");
    try out.appendSlice(allocator, artifact_class.label());
    try out.appendSlice(allocator, "\\n\"\n");
    try out.appendSlice(allocator, "    \"interpreter-linked=");
    try out.appendSlice(allocator, yes_no_interp_linked);
    try out.appendSlice(allocator, "\\n\"\n");
    try out.appendSlice(allocator, "    \"jit-interpreted-call-linked=");
    try out.appendSlice(allocator, yes_no_jic_linked);
    try out.appendSlice(allocator, "\\n\"\n");
    try out.appendSlice(allocator, "    \"interpreter-fallback-mode=");
    try out.appendSlice(allocator, fallback_str);
    try out.appendSlice(allocator, "\\n\"\n");
    try out.appendSlice(allocator, "    \"interpreter-setting-locked=");
    try out.appendSlice(allocator, yes_no_locked);
    try out.appendSlice(allocator, "\\n\"\n");
    try out.appendSlice(allocator, "    \"runtime-image-present=");
    try out.appendSlice(allocator, yes_no_runtime_image);
    try out.appendSlice(allocator, "\\n\"\n");
    try out.appendSlice(allocator, "    \"metadata-image-present=");
    try out.appendSlice(allocator, yes_no_metadata_image);
    try out.appendSlice(allocator, "\\n\"\n");
    try out.appendSlice(allocator, "    \"target-triple=");
    try out.appendSlice(allocator, meta.target_triple);
    try out.appendSlice(allocator, "\\n\"\n");
    try out.appendSlice(allocator, "    \"build-mode=");
    try out.appendSlice(allocator, meta.build_mode);
    try out.appendSlice(allocator, "\\n\"\n");
    try out.appendSlice(allocator, "    \"onez-version=");
    try out.appendSlice(allocator, meta.onez_version);
    try out.appendSlice(allocator, "\\n\"\n");
    try out.appendSlice(allocator, "    \"prelude-hash=");
    try out.appendSlice(allocator, meta.prelude_hash_hex);
    try out.appendSlice(allocator, "\\n\"\n");

    // Image format details (`runtime-image-format-version`,
    // `runtime-image-blob-present`, `runtime-image-word-count`) apply
    // to both the full runtime image and the interpreter-free
    // metadata-only image since both share the same on-disk schema.
    // Absent when no image is embedded.
    if (meta.runtime_image_present or meta.metadata_image_present) {
        var num_buf: [32]u8 = undefined;
        const fmt_str = std.fmt.bufPrint(&num_buf, "{d}", .{meta.runtime_image_format_version}) catch unreachable;
        try out.appendSlice(allocator, "    \"runtime-image-format-version=");
        try out.appendSlice(allocator, fmt_str);
        try out.appendSlice(allocator, "\\n\"\n");

        const blob_yes_no: []const u8 = if (meta.runtime_image_blob_present) "yes" else "no";
        try out.appendSlice(allocator, "    \"runtime-image-blob-present=");
        try out.appendSlice(allocator, blob_yes_no);
        try out.appendSlice(allocator, "\\n\"\n");

        const wc_str = std.fmt.bufPrint(&num_buf, "{d}", .{meta.runtime_image_word_count}) catch unreachable;
        try out.appendSlice(allocator, "    \"runtime-image-word-count=");
        try out.appendSlice(allocator, wc_str);
        try out.appendSlice(allocator, "\\n\"\n");

        const de_str = std.fmt.bufPrint(&num_buf, "{d}", .{meta.runtime_image_dispatch_entry_slot_count}) catch unreachable;
        try out.appendSlice(allocator, "    \"runtime-image-dispatch-entry-count=");
        try out.appendSlice(allocator, de_str);
        try out.appendSlice(allocator, "\\n\"\n");
    }

    // Optional toolchain provenance. Each is included only when the
    // build environment supplied it; absent fields are omitted from
    // the embedded record entirely so the inspector can render them
    // as "not present" rather than as empty strings.
    if (meta.onez_git_commit.len > 0) {
        try out.appendSlice(allocator, "    \"onez-git-commit=");
        try out.appendSlice(allocator, meta.onez_git_commit);
        try out.appendSlice(allocator, "\\n\"\n");
    }
    if (meta.zig_version.len > 0) {
        try out.appendSlice(allocator, "    \"zig-version=");
        try out.appendSlice(allocator, meta.zig_version);
        try out.appendSlice(allocator, "\\n\"\n");
    }
    if (meta.c_compiler_id.len > 0) {
        try out.appendSlice(allocator, "    \"c-compiler-id=");
        try out.appendSlice(allocator, meta.c_compiler_id);
        try out.appendSlice(allocator, "\\n\"\n");
    }
    if (meta.c_compiler_version.len > 0) {
        try out.appendSlice(allocator, "    \"c-compiler-version=");
        try out.appendSlice(allocator, meta.c_compiler_version);
        try out.appendSlice(allocator, "\\n\"\n");
    }
    if (meta.dynamic_features) |df| {
        try out.appendSlice(allocator, "    \"dynamic-features=");
        try out.appendSlice(allocator, df);
        try out.appendSlice(allocator, "\\n\"\n");
    }

    try out.appendSlice(allocator, "    \">>\\n\";\n\n");
}

/// Emit an overflow-checked binary operation (add/sub/mul).
/// On overflow, returns bail_status. On success, returns the result ref.
fn emitOverflowCheckedBinary(
    ctx: *c.ir_ctx,
    comptime op: comptime_int,
    a: c.ir_ref,
    b: c.ir_ref,
    bail_status: c.ir_ref,
) c.ir_ref {
    const result = c.ir_fold2(ctx, c.IR_OPT(op, c.IR_I64), a, b);
    const ovf = c.ir_fold1(ctx, c.IR_OPT(c.IR_OVERFLOW, c.IR_BOOL), result);
    const if_ovf = c._ir_IF(ctx, ovf);
    c._ir_IF_TRUE_cold(ctx, if_ovf);
    c._ir_RETURN(ctx, bail_status);
    c._ir_IF_FALSE(ctx, if_ovf);
    return result;
}

/// Emit division with div-by-zero and minInt/-1 overflow guards.
fn emitDivision(
    ctx: *c.ir_ctx,
    a: c.ir_ref,
    b: c.ir_ref,
    bail_status: c.ir_ref,
) c.ir_ref {
    // Guard: b == 0 -> bail
    const zero = c.ir_const_i64(ctx, 0);
    const is_zero = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), b, zero);
    const if_zero = c._ir_IF(ctx, is_zero);
    c._ir_IF_TRUE_cold(ctx, if_zero);
    c._ir_RETURN(ctx, bail_status);
    c._ir_IF_FALSE(ctx, if_zero);

    // Guard: a == minInt and b == -1 -> bail (overflow)
    const min_val = c.ir_const_i64(ctx, std.math.minInt(i64));
    const neg_one = c.ir_const_i64(ctx, -1);
    const is_min = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), a, min_val);
    const is_neg_one = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), b, neg_one);
    const is_overflow = c.ir_fold2(ctx, c.IR_OPT(c.IR_AND, c.IR_BOOL), is_min, is_neg_one);
    const if_ov = c._ir_IF(ctx, is_overflow);
    c._ir_IF_TRUE_cold(ctx, if_ov);
    c._ir_RETURN(ctx, bail_status);
    c._ir_IF_FALSE(ctx, if_ov);

    return c.ir_fold2(ctx, c.IR_OPT(c.IR_DIV, c.IR_I64), a, b);
}

/// Emit truncating remainder with div-by-zero guard.
fn emitRemainder(
    ctx: *c.ir_ctx,
    a: c.ir_ref,
    b: c.ir_ref,
    bail_status: c.ir_ref,
) c.ir_ref {
    // Guard: b == 0 -> bail
    const zero = c.ir_const_i64(ctx, 0);
    const is_zero = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), b, zero);
    const if_zero = c._ir_IF(ctx, is_zero);
    c._ir_IF_TRUE_cold(ctx, if_zero);
    c._ir_RETURN(ctx, bail_status);
    c._ir_IF_FALSE(ctx, if_zero);

    return c.ir_fold2(ctx, c.IR_OPT(c.IR_MOD, c.IR_I64), a, b);
}

/// Emit Euclidean modulo with div-by-zero guard.
/// Matches Zig's @mod semantics: r = @rem(a,b); if r != 0 and signs differ, r += b.
fn emitEuclideanMod(
    ctx: *c.ir_ctx,
    a: c.ir_ref,
    b: c.ir_ref,
    bail_status: c.ir_ref,
) c.ir_ref {
    // Guard: b == 0 -> bail
    const zero = c.ir_const_i64(ctx, 0);
    const is_zero = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), b, zero);
    const if_zero = c._ir_IF(ctx, is_zero);
    c._ir_IF_TRUE_cold(ctx, if_zero);
    c._ir_RETURN(ctx, bail_status);
    c._ir_IF_FALSE(ctx, if_zero);

    // Compute truncating remainder (C semantics)
    const rem_val = c.ir_fold2(ctx, c.IR_OPT(c.IR_MOD, c.IR_I64), a, b);

    // Adjustment: if rem != 0 and signs of rem and b differ, add b.
    // Signs differ when (rem XOR b) < 0.
    const rem_xor_b = c.ir_fold2(ctx, c.IR_OPT(c.IR_XOR, c.IR_I64), rem_val, b);
    const signs_differ = c.ir_fold2(ctx, c.IR_OPT(c.IR_LT, c.IR_BOOL), rem_xor_b, zero);
    const rem_nonzero = c.ir_fold2(ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), rem_val, zero);
    const needs_adjust = c.ir_fold2(ctx, c.IR_OPT(c.IR_AND, c.IR_BOOL), rem_nonzero, signs_differ);

    const adjusted = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_I64), rem_val, b);
    return c.ir_fold3(ctx, c.IR_OPT(c.IR_COND, c.IR_I64), needs_adjust, adjusted, rem_val);
}

// =============================================================================
// Safepoint
// =============================================================================

/// Store the current sp to memory and load the interpreter Context pointer
/// from the JitContext struct. This is the standard preamble before calling
/// any interpreter callback from compiled code.
fn emitCallbackPreamble(state: *CompileState, sp: usize) c.ir_ref {
    const ctx = state.ctx;
    const sp_const = c.ir_const_addr(ctx, sp);
    const new_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, sp_const);
    c._ir_STORE(ctx, state.sp_ptr, new_sp);

    // In AOT mode, reuse the ctx pointer loaded in the prologue to avoid
    // the ir_emit_c bug where LOADs get assigned vreg 0 without declaration.
    if (state.preloaded_ctx_val != c.IR_UNUSED) {
        return state.preloaded_ctx_val;
    }

    JitContextLayout.ensureInit();
    const ctx_off = c.ir_const_addr(ctx, JitContextLayout.ctx_offset);
    const ctx_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
    return c._ir_LOAD(ctx, c.IR_ADDR, ctx_addr);
}

/// Check if a callback returned non-zero and bail with the callback's return
/// code if so. Used after interpreter callbacks from compiled code.
///
/// On the hot-path continue branch, also refreshes state.items_ptr and
/// state.base_addr from the JitContext via jitRefreshStack. Any callback
/// that runs Zig interpreter code (jitInterpretedCall, jitCallQuotation,
/// jitNativeCall, jitRecover, jitCleanup, jitPushString, jitPushSymbol,
/// jitPushQuotation, jitGet, jitWithParameter, jitIteratorOp,
/// jitValidateParamEffects, jitSafepoint) may push values onto ctx.stack
/// and trigger ArrayListUnmanaged.append to reallocate the backing slice.
/// Without the refresh, subsequent compiled writes through state.items_ptr
/// (or its derived state.base_addr) land in freed memory. The refresh is
/// unconditional -- cheaper than auditing every callback for push safety,
/// and keeps the invariant "items_ptr is live after any callback" trivially
/// maintained as new callbacks are added.
const CurrentTraceFrame = union(enum) {
    none,
    named: struct {
        name: []const u8,
        line: usize,
    },
    builtin: struct {
        kind: BuiltinTraceFrameKind,
        line: usize,
    },
};

fn emitBuiltinTraceFrame(state: *CompileState, kind: BuiltinTraceFrameKind, line: usize) void {
    if (state.append_builtin_trace_frame_fn == c.IR_UNUSED) return;
    const ctx_val = if (state.preloaded_ctx_val != c.IR_UNUSED)
        state.preloaded_ctx_val
    else blk: {
        JitContextLayout.ensureInit();
        const ctx_off = c.ir_const_addr(state.ctx, JitContextLayout.ctx_offset);
        const ctx_addr = c.ir_fold2(state.ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
        break :blk c._ir_LOAD(state.ctx, c.IR_ADDR, ctx_addr);
    };
    const kind_const = c.ir_const_addr(state.ctx, @intFromEnum(kind));
    const line_const = c.ir_const_addr(state.ctx, line);
    _ = c._ir_CALL_3(state.ctx, c.IR_I32, state.append_builtin_trace_frame_fn, ctx_val, kind_const, line_const);
}

fn emitWordTraceFrame(state: *CompileState, word_name: []const u8, line: usize) void {
    if (state.append_word_trace_frame_fn == c.IR_UNUSED) return;
    const ctx_val = if (state.preloaded_ctx_val != c.IR_UNUSED)
        state.preloaded_ctx_val
    else blk: {
        JitContextLayout.ensureInit();
        const ctx_off = c.ir_const_addr(state.ctx, JitContextLayout.ctx_offset);
        const ctx_addr = c.ir_fold2(state.ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
        break :blk c._ir_LOAD(state.ctx, c.IR_ADDR, ctx_addr);
    };
    const name_ptr = if (state.aot_mode) blk: {
        const lit_id = if (state.aot_string_literals) |lits| lits.items.len else 0;
        if (state.aot_string_literals) |lits| {
            lits.append(std.heap.page_allocator, .{
                .data = word_name,
                .is_symbol = false,
            }) catch return;
        }
        var sym_buf: [32]u8 = undefined;
        const sym_name = std.fmt.bufPrint(&sym_buf, "onez_lit_{d}", .{lit_id}) catch unreachable;
        break :blk c.ir_const_func(state.ctx, c.ir_strl(state.ctx, &sym_buf, sym_name.len), 0);
    } else c.ir_const_addr(state.ctx, @intFromPtr(word_name.ptr));
    const name_len_const = c.ir_const_addr(state.ctx, word_name.len);
    const line_const = c.ir_const_addr(state.ctx, line);
    _ = c._ir_CALL_4(state.ctx, c.IR_I32, state.append_word_trace_frame_fn, ctx_val, name_ptr, name_len_const, line_const);
}

fn emitActiveInlineTraceFrames(state: *CompileState) void {
    var i = state.inline_trace_frame_count;
    while (i > 0) {
        i -= 1;
        const frame = state.inline_trace_frames[i];
        emitBuiltinTraceFrame(state, frame.kind, frame.line);
    }
}

fn emitCallbackPostCheck(
    state: *CompileState,
    call_result: c.ir_ref,
    return_status: c.ir_ref,
    terminal_success_status: ?c.ir_ref,
    current_trace_frame: CurrentTraceFrame,
) void {
    const ctx = state.ctx;
    const zero_status = c.ir_const_i32(ctx, 0);
    const call_failed = c.ir_fold2(ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), call_result, zero_status);
    const if_bail = c._ir_IF(ctx, call_failed);
    c._ir_IF_TRUE_cold(ctx, if_bail);
    if (traceFramesEnabled(state)) {
        switch (current_trace_frame) {
            .none => {},
            .named => |frame| if (frame.line != 0) emitWordTraceFrame(state, frame.name, frame.line),
            .builtin => |frame| if (frame.line != 0) emitBuiltinTraceFrame(state, frame.kind, frame.line),
        }
        emitActiveInlineTraceFrames(state);
    }
    c._ir_RETURN(ctx, return_status);
    c._ir_IF_FALSE(ctx, if_bail);

    if (terminal_success_status) |status| {
        c._ir_RETURN(ctx, status);
        state.exit_kind = .terminal_return;
        return;
    }

    // Hot-path continue: refresh cached stack pointer in case the callback
    // reallocated ctx.stack.items. See refreshCachedStackPointer.
    if (state.refresh_stack_fn == c.IR_UNUSED) return;
    _ = c._ir_CALL_1(ctx, c.IR_I32, state.refresh_stack_fn, state.jit_ctx_ptr);
    refreshCachedStackPointer(state);
}

/// Fresh items_ptr and the base address derived from it.
const LiveBase = struct {
    items_ptr: c.ir_ref,
    base_addr: c.ir_ref,
};

/// Derive the physical stack base address from the live JitContext.
///
/// Physical stack addresses are derived views of the live JitContext, never
/// long-lived state: the value buffer can move whenever a nested interpreted or
/// compiled call pushes onto the shared stack and triggers an ArrayList
/// reallocation. This helper emits a fresh LOAD of items_ptr from jit_ctx_ptr
/// and computes `items_ptr + base_idx * value_size`, returning the fresh
/// items_ptr alongside the base address so callers can cache both. IR treats
/// every CALL as a memory-clobbering barrier, so the fresh LOAD is never CSE'd
/// across a preceding call; within a barrier-free region IR folds repeated
/// loads, so re-deriving more than once per region costs nothing.
///
/// The addressing contract: after any boundary that can execute arbitrary 1z
/// code, the cached base address must be re-derived from this helper before the
/// next physical slot access.
fn liveBaseAddr(state: *CompileState) LiveBase {
    const ctx = state.ctx;
    const fresh_items_ptr = c._ir_LOAD(ctx, c.IR_ADDR, state.jit_ctx_ptr);
    const base_byte_offset = c.ir_fold2(ctx, c.IR_OPT(c.IR_MUL, c.IR_ADDR), state.base_idx, state.value_size_const);
    const base_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), fresh_items_ptr, base_byte_offset);
    return .{ .items_ptr = fresh_items_ptr, .base_addr = base_addr };
}

/// Address of physical stack slot `slot` relative to the region-current base:
/// `base_addr + slot * value_size`, which is the materialized form of
/// `items_ptr + (base_idx + slot) * value_size`. Centralizes the
/// slot-byte-offset add duplicated across codegen. The base address is whatever
/// was last derived from liveBaseAddr for the current barrier-free region.
fn liveSlotAddr(state: *CompileState, slot: usize) c.ir_ref {
    const slot_byte_offset = c.ir_const_addr(state.ctx, slot * ValueLayout.value_size);
    return c.ir_fold2(state.ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_addr, slot_byte_offset);
}

/// Re-LOAD items_ptr from the JitContext struct and recompute base_addr,
/// updating state.items_ptr and state.base_addr so subsequent emissions use
/// the fresh refs. Call this immediately after any IR call that may have
/// moved ctx.stack.items (jitRefreshStack or jitEnsureStackCapacity).
fn refreshCachedStackPointer(state: *CompileState) void {
    const live = liveBaseAddr(state);
    state.items_ptr = live.items_ptr;
    state.base_addr = live.base_addr;
}

/// Emit a safepoint call at the current IR position. Loads the ctx field
/// from the JitContext struct and calls jitSafepoint.
fn emitSafepointCall(state: *CompileState) void {
    if (state.safepoint_fn == c.IR_UNUSED) return;

    const ctx_val = if (state.preloaded_ctx_val != c.IR_UNUSED)
        state.preloaded_ctx_val
    else blk: {
        JitContextLayout.ensureInit();
        const ctx_off = c.ir_const_addr(state.ctx, JitContextLayout.ctx_offset);
        const ctx_addr = c.ir_fold2(state.ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
        break :blk c._ir_LOAD(state.ctx, c.IR_ADDR, ctx_addr);
    };
    const call_result = c._ir_CALL_1(state.ctx, c.IR_I32, state.safepoint_fn, ctx_val);
    emitCallbackPostCheck(state, call_result, state.error_propagate_status, null, .none);
}

/// A compile-time-filtered PIC entry ready for inline emission.
const InlinePicEntry = struct {
    tag_a: std.meta.Tag(Value),
    tag_b: std.meta.Tag(Value),
    native_fn_ptr: usize,
};

/// Emit inline type-check-and-branch IR for a set of qualified PIC entries.
/// Shared between PIC-sourced and dispatch-table-sourced inline checks.
/// Returns true if at least one entry was emitted.
///
/// When `unary` is true the emitted checks compare only the single
/// top-of-stack operand's tag and dispatch through the unary runtime helpers;
/// `InlinePicEntry.tag_b` is ignored.
fn emitInlinePicEntries(
    state: *CompileState,
    ctx_val: c.ir_ref,
    name: []const u8,
    resolved: ResolvedWord,
    line: usize,
    qualified: []const InlinePicEntry,
    generation: u32,
    unary: bool,
) bool {
    if (qualified.len == 0) return false;

    // In AOT mode, pic_dispatch_fn is pre-allocated in the prologue
    // (emitWordCAotPass). In JIT mode, pic_native_call_fn is allocated
    // lazily here on first use.
    if (!state.aot_mode and state.pic_native_call_fn == c.IR_UNUSED) {
        state.pic_native_call_fn = c.ir_const_addr(state.ctx, @intFromPtr(&jitPicNativeCall));
    }

    const ictx = state.ctx;
    ValueLayout.ensureInit();
    DispatchGenerationLayout.ensureInit();

    // --- Generation guard ---
    // Load ctx.dispatch.generation at runtime and compare against the
    // compile-time value. If the dispatch table was modified since
    // capture, skip inline checks.
    const dispatch_off = c.ir_const_addr(ictx, DispatchGenerationLayout.dispatch_offset);
    const dispatch_addr = c.ir_fold2(ictx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), ctx_val, dispatch_off);
    const gen_off = c.ir_const_addr(ictx, DispatchGenerationLayout.generation_offset);
    const gen_addr = c.ir_fold2(ictx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), dispatch_addr, gen_off);
    const runtime_gen = c._ir_LOAD(ictx, c.IR_U32, gen_addr);
    const compile_gen = c.ir_const_u32(ictx, generation);
    const gen_matches = c.ir_fold2(ictx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), runtime_gen, compile_gen);
    const if_gen = c._ir_IF(ictx, gen_matches);

    // --- Cold path: generation mismatch → slow dispatch ---
    c._ir_IF_FALSE_cold(ictx, if_gen);
    {
        emitNativeWordCall(state, ctx_val, name, resolved, line);
    }
    const end_gen_miss = c._ir_END(ictx);

    // --- Hot path: generation matches → try entries ---
    c._ir_IF_TRUE(ictx, if_gen);

    // In AOT mode, use the pre-allocated named extern reference.
    // In JIT mode, bake the function pointer address directly.
    const pic_match_fn = if (unary) blk: {
        if (state.pic_match_unary_fn != c.IR_UNUSED) break :blk state.pic_match_unary_fn;
        break :blk c.ir_const_addr(ictx, @intFromPtr(&jitPicTopTagMatch));
    } else if (state.pic_match_fn != c.IR_UNUSED)
        state.pic_match_fn
    else
        c.ir_const_addr(ictx, @intFromPtr(&jitPicTopTagsMatch));

    // Emit nested type checks for each qualified entry. The pattern
    // is a chain of IF/TRUE/FALSE with the slow path at the innermost FALSE.
    // Collect END refs from each branch for the final MERGE.
    var end_refs: [pic_mod.max_pic_entries + 1]c.ir_ref = .{c.IR_UNUSED} ** (pic_mod.max_pic_entries + 1);
    var end_count: usize = 0;

    // Save state refs before entering branches, since each branch's
    // emitCallbackPostCheck will update them independently.
    const saved_items_ptr = state.items_ptr;
    const saved_base_addr = state.base_addr;

    for (qualified) |entry| {
        const tag_a_const = c.ir_const_addr(ictx, @intFromEnum(entry.tag_a));
        const match_status = if (unary)
            c._ir_CALL_2(ictx, c.IR_I32, pic_match_fn, ctx_val, tag_a_const)
        else
            c._ir_CALL_3(ictx, c.IR_I32, pic_match_fn, ctx_val, tag_a_const, c.ir_const_addr(ictx, @intFromEnum(entry.tag_b)));
        const matched = c.ir_fold2(ictx, c.IR_OPT(c.IR_NE, c.IR_BOOL), match_status, state.ok_status);
        const if_match = c._ir_IF(ictx, matched);

        // Hit path: call the cached native method body directly
        c._ir_IF_TRUE(ictx, if_match);
        {
            if (state.aot_mode) {
                // AOT: can't bake function pointers; dispatch via
                // jitPicDispatch(Unary) with the pre-verified type tags.
                const word_id_const = c.ir_const_addr(ictx, resolved.word_id);
                const tag_a_int = c.ir_const_addr(ictx, @intFromEnum(entry.tag_a));
                const call_result = if (unary)
                    c._ir_CALL_3(ictx, c.IR_I32, state.pic_dispatch_unary_fn, ctx_val, word_id_const, tag_a_int)
                else
                    c._ir_CALL_4(ictx, c.IR_I32, state.pic_dispatch_fn, ctx_val, word_id_const, tag_a_int, c.ir_const_addr(ictx, @intFromEnum(entry.tag_b)));
                emitCallbackPostCheck(state, call_result, state.error_propagate_status, null, .none);
            } else {
                const fn_ptr_const = c.ir_const_addr(ictx, entry.native_fn_ptr);
                const name_ptr_const = c.ir_const_addr(ictx, @intFromPtr(name.ptr));
                const name_len_const = c.ir_const_addr(ictx, name.len);
                const call_result = c._ir_CALL_4(ictx, c.IR_I32, state.pic_native_call_fn, ctx_val, fn_ptr_const, name_ptr_const, name_len_const);
                emitCallbackPostCheck(state, call_result, call_result, null, .{ .named = .{ .name = name, .line = line } });
            }
            // Restore state for next branch
            state.items_ptr = saved_items_ptr;
            state.base_addr = saved_base_addr;
        }
        end_refs[end_count] = c._ir_END(ictx);
        end_count += 1;

        // Miss path: continue to next entry (or fall through to slow path)
        c._ir_IF_FALSE(ictx, if_match);
    }

    // Innermost miss: slow path, call the generic native function
    {
        emitNativeWordCall(state, ctx_val, name, resolved, line);
        state.items_ptr = saved_items_ptr;
        state.base_addr = saved_base_addr;
    }
    end_refs[end_count] = c._ir_END(ictx);
    end_count += 1;

    // Merge all hit branches + slow path
    if (end_count == 2) {
        c._ir_MERGE_2(ictx, end_refs[0], end_refs[1]);
    } else {
        var merge_inputs: [pic_mod.max_pic_entries + 1]c.ir_ref = undefined;
        for (0..end_count) |i| merge_inputs[i] = end_refs[i];
        c._ir_MERGE_N(ictx, @intCast(end_count), &merge_inputs);
    }
    const end_gen_hot = c._ir_END(ictx);

    // --- Final merge: generation hot + generation miss ---
    c._ir_MERGE_2(ictx, end_gen_hot, end_gen_miss);

    // After merging branches that each refreshed the stack pointer
    // independently, re-LOAD to get refs that dominate this point.
    if (state.refresh_stack_fn != c.IR_UNUSED) {
        refreshCachedStackPointer(state);
    }

    if (state.pic_stats) |ps| ps.sites_emitted += 1;
    return true;
}

/// Try to emit inline PIC type checks at a generic call site. Reads the
/// interpreter PIC data for instruction `idx` and emits tag-check-and-branch
/// IR for entries that can be inlined (builtin types, native_fn bodies, no
/// unwrap). Includes the fallback slow path; returns true if emission
/// succeeded (caller should NOT emit a separate native call).
///
/// Returns false if no inline PIC is possible (no PIC data, no qualifying
/// entries, unsupported configuration). The caller then falls through to the
/// standard emitNativeWordCall path.
fn emitInlinePicCheck(
    state: *CompileState,
    idx: usize,
    ctx_val: c.ir_ref,
    name: []const u8,
    resolved: ResolvedWord,
    effective_in: u8,
    line: usize,
) bool {
    const pic_table = state.pic_table orelse return false;
    const interp_ctx = state.interp_ctx orelse return false;
    if (idx >= pic_table.entries.len) return false;
    if (resolved.never_returns) return false;
    if (effective_in < 2) return false;

    const cache = pic_table.entries[idx];
    if (cache.megamorphic or cache.count == 0) return false;

    if (state.pic_stats) |ps| ps.sites_attempted += 1;

    // Filter entries at compile time: only keep entries where both
    // types reverse-map to builtin Value tags, the body is a native
    // function, and no unwrap is needed.
    var qualified: [pic_mod.max_pic_entries]InlinePicEntry = undefined;
    var qualified_count: usize = 0;

    for (cache.entries[0..cache.count]) |entry| {
        if (entry.unwrap_a or entry.unwrap_b) continue;
        const body_fn = switch (entry.entry.body) {
            .native_fn => |f| @intFromPtr(f),
            .quotation, .host_callback => continue,
        };
        const tag_a = reverseMapDescriptorToTag(interp_ctx, entry.type_a) orelse continue;
        const tag_b = reverseMapDescriptorToTag(interp_ctx, entry.type_b) orelse continue;
        qualified[qualified_count] = .{
            .tag_a = tag_a,
            .tag_b = tag_b,
            .native_fn_ptr = body_fn,
        };
        qualified_count += 1;
    }

    return emitInlinePicEntries(state, ctx_val, name, resolved, line, qualified[0..qualified_count], cache.generation, false);
}

/// Try to emit inline dispatch-table-driven type checks at a generic call
/// site. Reads all registered methods for the word from the frozen dispatch
/// table and emits tag-check-and-branch IR for native-function entries with
/// builtin type tags. This path does not require PIC observation data and
/// works for all call sites regardless of whether they were exercised during
/// interpretation.
fn emitInlineDispatchTableCheck(
    state: *CompileState,
    ctx_val: c.ir_ref,
    name: []const u8,
    resolved: ResolvedWord,
    effective_in: u8,
    line: usize,
) bool {
    const interp_ctx = state.interp_ctx orelse return false;
    if (resolved.never_returns) return false;
    if (effective_in < 2) return false;

    const dispatch_id = interp_ctx.resolveDispatchId(name) orelse return false;

    // Skip sentinel descriptors so wildcard and unary entries are
    // excluded from inline checks (they can't be matched by binary
    // tag comparison).
    const any_desc = if (interp_ctx.getDispatchAnySentinel().descriptor) |d| d else return false;
    const unary_desc = if (interp_ctx.getDispatchUnarySentinel().descriptor) |d| d else return false;

    if (state.pic_stats) |ps| ps.sites_attempted += 1;

    // Collect native-function entries with builtin type tags from the
    // dispatch table. Cap at max_pic_entries to match PIC path behavior
    // and avoid excessive code bloat.
    var qualified: [pic_mod.max_pic_entries]InlinePicEntry = undefined;
    var qualified_count: usize = 0;

    var iter = interp_ctx.dispatch.entries.iterator();
    while (iter.next()) |entry| {
        if (qualified_count >= pic_mod.max_pic_entries) break;
        if (entry.key_ptr.dispatch_id != dispatch_id) continue;

        // Skip wildcard and unary entries
        if (entry.key_ptr.type_a == any_desc or entry.key_ptr.type_b == any_desc) continue;
        if (entry.key_ptr.type_b == unary_desc) continue;

        const body_fn = switch (entry.value_ptr.body) {
            .native_fn => |f| @intFromPtr(f),
            .quotation, .host_callback => continue,
        };
        const tag_a = reverseMapDescriptorToTag(interp_ctx, entry.key_ptr.type_a) orelse continue;
        const tag_b = reverseMapDescriptorToTag(interp_ctx, entry.key_ptr.type_b) orelse continue;
        qualified[qualified_count] = .{
            .tag_a = tag_a,
            .tag_b = tag_b,
            .native_fn_ptr = body_fn,
        };
        qualified_count += 1;
    }

    return emitInlinePicEntries(state, ctx_val, name, resolved, line, qualified[0..qualified_count], interp_ctx.dispatch.generation, false);
}

/// Unary sibling of `emitInlinePicCheck` for a strictly-unary generic native
/// such as `inspect`. Gates on `effective_in == 1` so a binary word's PIC
/// entries can never be misread as unary. Reverse-maps only `type_a`; a unary
/// entry's `type_b` is the unary sentinel, which never reverse-maps to a
/// builtin tag.
fn emitInlinePicCheckUnary(
    state: *CompileState,
    idx: usize,
    ctx_val: c.ir_ref,
    name: []const u8,
    resolved: ResolvedWord,
    effective_in: u8,
    line: usize,
) bool {
    const pic_table = state.pic_table orelse return false;
    const interp_ctx = state.interp_ctx orelse return false;
    if (idx >= pic_table.entries.len) return false;
    if (resolved.never_returns) return false;
    if (effective_in != 1) return false;

    const cache = pic_table.entries[idx];
    if (cache.megamorphic or cache.count == 0) return false;

    if (state.pic_stats) |ps| ps.sites_attempted += 1;

    var qualified: [pic_mod.max_pic_entries]InlinePicEntry = undefined;
    var qualified_count: usize = 0;

    for (cache.entries[0..cache.count]) |entry| {
        if (entry.unwrap_a or entry.unwrap_b) continue;
        const body_fn = switch (entry.entry.body) {
            .native_fn => |f| @intFromPtr(f),
            .quotation, .host_callback => continue,
        };
        const tag_a = reverseMapDescriptorToTag(interp_ctx, entry.type_a) orelse continue;
        qualified[qualified_count] = .{
            .tag_a = tag_a,
            .tag_b = tag_a,
            .native_fn_ptr = body_fn,
        };
        qualified_count += 1;
    }

    return emitInlinePicEntries(state, ctx_val, name, resolved, line, qualified[0..qualified_count], cache.generation, true);
}

/// Unary sibling of `emitInlineDispatchTableCheck`. Collects the word's
/// unary-sentinel dispatch entries (`type_b == unary_desc`) from the frozen
/// dispatch table, so `inspect`/`>string`-shaped words get an inline fast path
/// even without PIC observation data.
fn emitInlineDispatchTableCheckUnary(
    state: *CompileState,
    ctx_val: c.ir_ref,
    name: []const u8,
    resolved: ResolvedWord,
    effective_in: u8,
    line: usize,
) bool {
    const interp_ctx = state.interp_ctx orelse return false;
    if (resolved.never_returns) return false;
    if (effective_in != 1) return false;

    const dispatch_id = interp_ctx.resolveDispatchId(name) orelse return false;

    const any_desc = if (interp_ctx.getDispatchAnySentinel().descriptor) |d| d else return false;
    const unary_desc = if (interp_ctx.getDispatchUnarySentinel().descriptor) |d| d else return false;

    if (state.pic_stats) |ps| ps.sites_attempted += 1;

    var qualified: [pic_mod.max_pic_entries]InlinePicEntry = undefined;
    var qualified_count: usize = 0;

    var iter = interp_ctx.dispatch.entries.iterator();
    while (iter.next()) |entry| {
        if (qualified_count >= pic_mod.max_pic_entries) break;
        if (entry.key_ptr.dispatch_id != dispatch_id) continue;

        // Keep only unary-sentinel entries; skip wildcard operands.
        if (entry.key_ptr.type_b != unary_desc) continue;
        if (entry.key_ptr.type_a == any_desc) continue;

        const body_fn = switch (entry.value_ptr.body) {
            .native_fn => |f| @intFromPtr(f),
            .quotation, .host_callback => continue,
        };
        const tag_a = reverseMapDescriptorToTag(interp_ctx, entry.key_ptr.type_a) orelse continue;
        qualified[qualified_count] = .{
            .tag_a = tag_a,
            .tag_b = tag_a,
            .native_fn_ptr = body_fn,
        };
        qualified_count += 1;
    }

    return emitInlinePicEntries(state, ctx_val, name, resolved, line, qualified[0..qualified_count], interp_ctx.dispatch.generation, true);
}

/// Emit a native word call. In JIT mode, calls through jitNativeCall with
/// the baked function pointer. In AOT mode, calls through jitNativeWordCall
/// with the word ID since native function pointers are not available at C
/// compile time.
fn emitNativeWordCall(state: *CompileState, ctx_val: c.ir_ref, name: []const u8, resolved: ResolvedWord, line: usize) void {
    const ictx = state.ctx;
    if (state.aot_mode) {
        // Non-generic natives compile to a direct call into their generated wrapper
        // symbol instead of the runtime-resolving `jitNativeWordCall`, so they emit no
        // interpreter fallback. `registryWrapperSymbol` returns null for a generic
        // native, whose slow path must keep routing through `jitNativeWordCall` so
        // generic dispatch fires for uncached operand types. The wrapper takes the
        // call-site line so it can rebuild the native's call frame for error reporting.
        //
        // The `onez_n_*` wrapper symbols are exported by the hosted runtime only, so a
        // freestanding build routes every native through `jitNativeWordCall`, whose
        // freestanding export implements the supported set in `callFreestandingNative`
        // and errors on the rest.
        if (!state.freestanding) {
            if (aot_wrappers.registryWrapperSymbol(name)) |symbol| {
                const callee_fn = c.ir_const_func(ictx, c.ir_str(ictx, symbol.ptr), state.aot_proto_2arg);
                const line_arg = c.ir_const_addr(ictx, line);
                const call_result = c._ir_CALL_2(ictx, c.IR_I32, callee_fn, ctx_val, line_arg);
                emitCallbackPostCheck(state, call_result, state.error_propagate_status, if (resolved.never_returns) state.error_propagate_status else null, .none);
                return;
            }
        }
        const word_id_const = c.ir_const_addr(ictx, resolved.word_id);
        const line_const = c.ir_const_addr(ictx, line);
        state.noteAotFallbackEmission(.native, name, resolved.word_id, line);
        const call_result = c._ir_CALL_3(ictx, c.IR_I32, state.native_word_call_fn, ctx_val, word_id_const, line_const);
        emitCallbackPostCheck(state, call_result, state.error_propagate_status, if (resolved.never_returns) state.error_propagate_status else null, .none);
    } else {
        const fn_ptr_const = c.ir_const_addr(ictx, resolved.native_fn_ptr.?);
        const call_result = c._ir_CALL_2(ictx, c.IR_I32, state.native_call_fn, ctx_val, fn_ptr_const);
        emitCallbackPostCheck(state, call_result, call_result, if (resolved.never_returns) state.error_propagate_status else null, .{ .named = .{ .name = name, .line = line } });
    }
}

/// Emit a compound word call in AOT mode. If the target word is in the
/// compiled word set, emits a direct call by mangled name. Otherwise, falls
/// through to `jitInterpretedCall` with the word ID (permissive AOT only;
/// strict AOT fails the build at this site).
fn emitAotWordCall(state: *CompileState, ctx_val: c.ir_ref, name: []const u8, resolved: ResolvedWord, line: usize) void {
    const ictx = state.ctx;
    if (state.aot_compiled_names) |names| {
        if (names.get(name)) |_| {
            // Direct call to the compiled word's C function
            const mangled = mangleWordName(name, std.heap.page_allocator) catch unreachable;
            defer std.heap.page_allocator.free(mangled);
            const callee_fn = c.ir_const_func(ictx, c.ir_str(ictx, mangled.ptr), state.aot_proto_1arg);
            const call_result = c._ir_CALL_1(ictx, c.IR_I32, callee_fn, state.jit_ctx_ptr);
            emitCallbackPostCheck(state, call_result, call_result, if (resolved.never_returns) state.error_propagate_status else null, .{ .named = .{ .name = name, .line = line } });
            return;
        }
    }
    // Fall through to interpreter for uncompiled words
    const word_id_const = c.ir_const_addr(ictx, resolved.word_id);
    const line_const = c.ir_const_addr(ictx, line);
    state.noteAotFallbackEmission(.compound_uncompiled, name, resolved.word_id, line);
    const call_result = c._ir_CALL_3(ictx, c.IR_I32, state.interpreted_call_fn, ctx_val, word_id_const, line_const);
    emitCallbackPostCheck(state, call_result, state.error_propagate_status, if (resolved.never_returns) state.error_propagate_status else null, .none);
}

/// Emit a parameter effect validation call at the current IR position.
/// Takes a stable pointer to the word's StackEffect and calls
/// jitValidateParamEffects to check quotation arguments on the stack.
fn emitParamValidation(state: *CompileState, effect_ptr: usize) void {
    if (state.validate_params_fn == c.IR_UNUSED) return;
    // The effect_ptr is process-local; embedding it as a constant is safe
    // for in-process JIT but produces a stale address in an AOT binary
    // that runs in a fresh process. Compile-time effect tracking already
    // validated the quotation arguments, so skip the runtime double-check.
    if (state.aot_mode) return;
    const ctx_val = if (state.preloaded_ctx_val != c.IR_UNUSED)
        state.preloaded_ctx_val
    else blk: {
        JitContextLayout.ensureInit();
        const ctx_off = c.ir_const_addr(state.ctx, JitContextLayout.ctx_offset);
        const ctx_addr = c.ir_fold2(state.ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
        break :blk c._ir_LOAD(state.ctx, c.IR_ADDR, ctx_addr);
    };
    const effect_const = c.ir_const_addr(state.ctx, effect_ptr);
    const call_result = c._ir_CALL_2(state.ctx, c.IR_I32, state.validate_params_fn, ctx_val, effect_const);
    emitCallbackPostCheck(state, call_result, state.error_propagate_status, null, .none);
}

/// Emit a protocol-bounded generic dispatch call at the current IR position.
/// Calls `jitSatisfiesAndDispatch`, which satisfies-checks the dispatched
/// operand(s) against `descriptor_ptr` and then resolves and runs the
/// concrete-type method by `dispatch_id`. This replaces both the protocol
/// re-check and the ordinary dispatch at a bounded site -- no PIC is installed.
/// JIT-only: the descriptor pointer is process-local, so AOT (which runs in a
/// fresh process) keeps its own path.
fn emitSatisfiesAndDispatch(
    state: *CompileState,
    dispatch_id: u32,
    descriptor_ptr: usize,
    arity: dispatch_helpers.ProtocolArity,
    trace_name: []const u8,
    line: usize,
) void {
    if (state.satisfies_dispatch_fn == c.IR_UNUSED) return;
    if (state.aot_mode) return;
    const ctx_val = if (state.preloaded_ctx_val != c.IR_UNUSED)
        state.preloaded_ctx_val
    else blk: {
        JitContextLayout.ensureInit();
        const ctx_off = c.ir_const_addr(state.ctx, JitContextLayout.ctx_offset);
        const ctx_addr = c.ir_fold2(state.ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
        break :blk c._ir_LOAD(state.ctx, c.IR_ADDR, ctx_addr);
    };
    // The trace-name pointer is process-local memory composed and memoized at
    // compile time, so baking it as a constant is sound on the JIT-only path
    // this helper guards.
    var args = [_]c.ir_ref{
        ctx_val,
        c.ir_const_addr(state.ctx, dispatch_id),
        c.ir_const_addr(state.ctx, descriptor_ptr),
        c.ir_const_addr(state.ctx, @intFromEnum(arity)),
        c.ir_const_addr(state.ctx, @intFromPtr(trace_name.ptr)),
        c.ir_const_addr(state.ctx, trace_name.len),
        c.ir_const_addr(state.ctx, line),
    };
    const call_result = c._ir_CALL_N(state.ctx, c.IR_I32, state.satisfies_dispatch_fn, args.len, &args);
    emitCallbackPostCheck(state, call_result, state.error_propagate_status, null, .none);
}

/// Emit the plain-generic dispatch helper at an AOT call site: try the
/// dispatch table for `dispatch_id` against the operand type(s), and on a miss
/// run the generic's default body (the compiled word registered under
/// `word_id`). One call, no call-site branch -- the helper handles both paths.
fn emitAotGenericDispatch(
    state: *CompileState,
    dispatch_id: u32,
    word_id: u32,
    name: []const u8,
    line: usize,
) void {
    if (state.aot_generic_dispatch_fn == c.IR_UNUSED) return;
    const ctx_val = state.preloaded_ctx_val;
    var args = [_]c.ir_ref{
        ctx_val,
        c.ir_const_addr(state.ctx, dispatch_id),
        c.ir_const_addr(state.ctx, word_id),
    };
    const call_result = c._ir_CALL_N(state.ctx, c.IR_I32, state.aot_generic_dispatch_fn, args.len, &args);
    emitCallbackPostCheck(state, call_result, call_result, null, .{ .named = .{ .name = name, .line = line } });
}

/// AOT counterpart of emitSatisfiesAndDispatch. Looks up the protocol
/// descriptor's slot index and emits a 5-arg call to `aotSatisfiesAndDispatch`,
/// which dereferences the slot at runtime to get the descriptor. This avoids
/// baking process-local descriptor pointers into the AOT binary.
fn emitAotSatisfiesAndDispatch(
    state: *CompileState,
    dispatch_id: u32,
    protocol: *const value_mod.ProtocolDescriptor,
    arity: dispatch_helpers.ProtocolArity,
    line: usize,
) void {
    if (state.aot_satisfies_dispatch_fn == c.IR_UNUSED) return;
    const maps = state.aot_slot_maps orelse return;
    const slot_idx = maps.protocol_slot_index.get(protocol) orelse return;
    const ctx_val = state.preloaded_ctx_val;
    var args = [_]c.ir_ref{
        ctx_val,
        c.ir_const_addr(state.ctx, dispatch_id),
        c.ir_const_addr(state.ctx, slot_idx),
        c.ir_const_addr(state.ctx, @intFromEnum(arity)),
        c.ir_const_addr(state.ctx, line),
    };
    const call_result = c._ir_CALL_N(state.ctx, c.IR_I32, state.aot_satisfies_dispatch_fn, args.len, &args);
    emitCallbackPostCheck(state, call_result, state.error_propagate_status, null, .none);
}

/// Combinator-bounded counterpart of emitSatisfiesAndDispatch. Same JIT-only
/// shape, calling `jitSatisfiesAndDispatchCombinator` with a process-local
/// combinator pointer.
fn emitSatisfiesAndDispatchCombinator(
    state: *CompileState,
    dispatch_id: u32,
    combinator_ptr: usize,
    arity: dispatch_helpers.ProtocolArity,
    trace_name: []const u8,
    line: usize,
) void {
    if (state.satisfies_dispatch_combinator_fn == c.IR_UNUSED) return;
    if (state.aot_mode) return;
    const ctx_val = if (state.preloaded_ctx_val != c.IR_UNUSED)
        state.preloaded_ctx_val
    else blk: {
        JitContextLayout.ensureInit();
        const ctx_off = c.ir_const_addr(state.ctx, JitContextLayout.ctx_offset);
        const ctx_addr = c.ir_fold2(state.ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
        break :blk c._ir_LOAD(state.ctx, c.IR_ADDR, ctx_addr);
    };
    var args = [_]c.ir_ref{
        ctx_val,
        c.ir_const_addr(state.ctx, dispatch_id),
        c.ir_const_addr(state.ctx, combinator_ptr),
        c.ir_const_addr(state.ctx, @intFromEnum(arity)),
        c.ir_const_addr(state.ctx, @intFromPtr(trace_name.ptr)),
        c.ir_const_addr(state.ctx, trace_name.len),
        c.ir_const_addr(state.ctx, line),
    };
    const call_result = c._ir_CALL_N(state.ctx, c.IR_I32, state.satisfies_dispatch_combinator_fn, args.len, &args);
    emitCallbackPostCheck(state, call_result, state.error_propagate_status, null, .none);
}

/// Combinator-bounded counterpart of emitAotSatisfiesAndDispatch. Looks up the
/// combinator's slot index in the parallel combinator slot table and emits a
/// 5-arg call to `aotSatisfiesAndDispatchCombinator`.
fn emitAotSatisfiesAndDispatchCombinator(
    state: *CompileState,
    dispatch_id: u32,
    combinator: *const value_mod.ConstraintCombinator,
    arity: dispatch_helpers.ProtocolArity,
    line: usize,
) void {
    if (state.aot_satisfies_dispatch_combinator_fn == c.IR_UNUSED) return;
    const maps = state.aot_slot_maps orelse return;
    const slot_idx = maps.combinator_slot_index.get(combinator) orelse return;
    const ctx_val = state.preloaded_ctx_val;
    var args = [_]c.ir_ref{
        ctx_val,
        c.ir_const_addr(state.ctx, dispatch_id),
        c.ir_const_addr(state.ctx, slot_idx),
        c.ir_const_addr(state.ctx, @intFromEnum(arity)),
        c.ir_const_addr(state.ctx, line),
    };
    const call_result = c._ir_CALL_N(state.ctx, c.IR_I32, state.aot_satisfies_dispatch_combinator_fn, args.len, &args);
    emitCallbackPostCheck(state, call_result, state.error_propagate_status, null, .none);
}

// =============================================================================
// Trampoline
// =============================================================================

export fn jitSafepoint(ctx_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 0;
    const ctx: *Context = @ptrFromInt(ctx_raw);

    signal.checkPendingSignals(ctx) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };

    const scheduler: *Scheduler = ctx.scheduler orelse return 0;
    const should_yield = scheduler.run_queue.items.len > 0 or scheduler.sleep_queue.count() > 0;
    if (should_yield) {
        scheduler.yieldCurrentTask();
    }
    helpers.checkCancellation(ctx) catch |err| {
        if (ctx.trace.trace_jit) {
            var tw = trace_mod.TraceWriter.init();
            trace_mod.traceJitSafepoint(&tw, should_yield, true);
        }
        ctx.jit_pending_error = err;
        return 2;
    };
    if (ctx.trace.trace_jit) {
        var tw = trace_mod.TraceWriter.init();
        trace_mod.traceJitSafepoint(&tw, should_yield, false);
    }
    return 0;
}

export fn jitGet(ctx_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    dynamic_vars_mod.nativeGet(ctx) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

export fn jitWithParameter(ctx_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    dynamic_vars_mod.nativeWithParameter(ctx) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

export fn jitRecover(ctx_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    errors_mod.nativeRecover(ctx) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

export fn jitCleanup(ctx_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    errors_mod.nativeCleanup(ctx) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

export fn jitValidateParamEffects(ctx_raw: usize, effect_ptr_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const effect: *const StackEffect = @ptrFromInt(effect_ptr_raw);
    ctx.validateParameterEffects(effect) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    ctx.validateTypeAnnotations(effect) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

/// Protocol-bounded generic dispatch helper emitted at bounded call sites.
/// Satisfies-checks the dispatched operand(s) against the protocol descriptor
/// and dispatches the concrete-type method by `dispatch_id`, raising on a
/// non-satisfying operand.
export fn jitSatisfiesAndDispatch(
    ctx_raw: usize,
    dispatch_id_raw: usize,
    descriptor_ptr_raw: usize,
    arity_raw: usize,
    name_ptr_raw: usize,
    name_len_raw: usize,
    line_raw: usize,
) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const descriptor: *const value_mod.ProtocolDescriptor = @ptrFromInt(descriptor_ptr_raw);
    const arity = std.meta.intToEnum(dispatch_helpers.ProtocolArity, arity_raw) catch return 1;
    const trace_name: []const u8 = if (name_len_raw > 0 and name_ptr_raw != 0)
        @as([*]const u8, @ptrFromInt(name_ptr_raw))[0..name_len_raw]
    else
        "satisfies-and-dispatch";
    dispatch_helpers.satisfiesAndDispatch(ctx, @intCast(dispatch_id_raw), .{ .protocol = descriptor }, arity, trace_name, @intCast(line_raw)) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

/// AOT counterpart of jitSatisfiesAndDispatch. Looks up the protocol descriptor
/// through the runtime-image slot table and dispatches the concrete-type method.
/// Slot-indexed so the AOT binary does not bake process-local pointers.
/// Plain (non-bounded) generic dispatch in compiled code. Tries the dispatch
/// table for a method matching the operand type(s); on a hit it runs the
/// method and returns ok. On a miss it runs the generic's own default body --
/// the compiled function registered under `word_id_raw` -- mirroring the
/// interpreter's "dispatch, else fall through to the body" behavior for a word
/// carrying the `generic` marker. Keeps user generics dispatching under AOT
/// where the call site would otherwise call the default body directly.
export fn aotTryDispatchGenericOrCall(
    ctx_raw: usize,
    dispatch_id_raw: usize,
    word_id_raw: usize,
) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const dispatched = dispatch_helpers.tryDispatchGenericById(ctx, @intCast(dispatch_id_raw), null) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    if (dispatched) return 0;

    // Dispatch missed: run the generic's default body, the compiled function
    // registered under its word_id.
    const entry = ctx.jit_dispatch.get(@intCast(word_id_raw)) orelse return 1;
    const code_ptr = entry.code_ptr orelse return 1;
    const func: CompiledFn = @ptrCast(@alignCast(code_ptr));
    var jit_ctx = JitContext{
        .items_ptr = ctx.stack.items.items.ptr,
        .sp_ptr = &ctx.stack.items.items.len,
        .capacity = ctx.stack.items.capacity,
        .ctx = ctx,
    };
    return func(&jit_ctx);
}

export fn aotSatisfiesAndDispatch(
    ctx_raw: usize,
    dispatch_id_raw: usize,
    slot_idx_raw: usize,
    arity_raw: usize,
    line_raw: usize,
) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const slots = ctx.image_protocoldescriptor_slots orelse {
        ctx.jit_pending_error = error.UserThrown;
        return 2;
    };
    if (slot_idx_raw >= ctx.image_protocoldescriptor_slot_count) {
        ctx.jit_pending_error = error.UserThrown;
        return 2;
    }
    const descriptor = slots[slot_idx_raw] orelse {
        ctx.jit_pending_error = error.UserThrown;
        return 2;
    };
    const arity = std.meta.intToEnum(dispatch_helpers.ProtocolArity, arity_raw) catch {
        ctx.jit_pending_error = error.UserThrown;
        return 2;
    };
    var trace_buf: [128]u8 = undefined;
    const trace_name = std.fmt.bufPrint(&trace_buf, "satisfies-and-dispatch[{s}]", .{descriptor.name}) catch "satisfies-and-dispatch";
    dispatch_helpers.satisfiesAndDispatch(ctx, @intCast(dispatch_id_raw), .{ .protocol = descriptor }, arity, trace_name, @intCast(line_raw)) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

/// Combinator-bounded counterpart of jitSatisfiesAndDispatch. Satisfies-checks
/// the dispatched operand(s) against the process-local combinator descriptor and
/// dispatches the concrete-type method by `dispatch_id`.
export fn jitSatisfiesAndDispatchCombinator(
    ctx_raw: usize,
    dispatch_id_raw: usize,
    combinator_ptr_raw: usize,
    arity_raw: usize,
    name_ptr_raw: usize,
    name_len_raw: usize,
    line_raw: usize,
) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const combinator: *const value_mod.ConstraintCombinator = @ptrFromInt(combinator_ptr_raw);
    const arity = std.meta.intToEnum(dispatch_helpers.ProtocolArity, arity_raw) catch return 1;
    const trace_name: []const u8 = if (name_len_raw > 0 and name_ptr_raw != 0)
        @as([*]const u8, @ptrFromInt(name_ptr_raw))[0..name_len_raw]
    else
        "satisfies-and-dispatch";
    dispatch_helpers.satisfiesAndDispatch(ctx, @intCast(dispatch_id_raw), .{ .combinator = combinator }, arity, trace_name, @intCast(line_raw)) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

/// Combinator-bounded counterpart of aotSatisfiesAndDispatch. Resolves the
/// combinator descriptor through the runtime-image combinator slot table and
/// dispatches the concrete-type method. Slot-indexed so the AOT binary does not
/// bake process-local pointers.
export fn aotSatisfiesAndDispatchCombinator(
    ctx_raw: usize,
    dispatch_id_raw: usize,
    slot_idx_raw: usize,
    arity_raw: usize,
    line_raw: usize,
) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const slots = ctx.image_constraintcombinator_slots orelse {
        ctx.jit_pending_error = error.UserThrown;
        return 2;
    };
    if (slot_idx_raw >= ctx.image_constraintcombinator_slot_count) {
        ctx.jit_pending_error = error.UserThrown;
        return 2;
    }
    const combinator = slots[slot_idx_raw] orelse {
        ctx.jit_pending_error = error.UserThrown;
        return 2;
    };
    const arity = std.meta.intToEnum(dispatch_helpers.ProtocolArity, arity_raw) catch {
        ctx.jit_pending_error = error.UserThrown;
        return 2;
    };
    dispatch_helpers.satisfiesAndDispatch(ctx, @intCast(dispatch_id_raw), .{ .combinator = combinator }, arity, "satisfies-and-dispatch[constraint]", @intCast(line_raw)) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

export fn jitIteratorOp(ctx_raw: usize, opcode_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const opcode = std.meta.intToEnum(IteratorOpcode, opcode_raw) catch return 1;
    const func: *const fn (*Context) anyerror!void = switch (opcode) {
        .next => &iterators_mod.nativeNext,
        .collect => &iterators_mod.nativeCollect,
        .count => &iterators_mod.nativeCount,
        .close_iterator => &iterators_mod.nativeCloseIterator,
        .take => &sequences_mod.nativeTake,
        .drop => &sequences_mod.nativeDrop,
        .each => &sequences_mod.nativeEach,
        .map => &sequences_mod.nativeMap,
        .filter => &sequences_mod.nativeFilter,
        .reduce => &sequences_mod.nativeReduce,
    };
    func(ctx) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

/// Lightweight dispatch for AOT inline PIC hits. The generated C code
/// already verified operand types via tag comparison; this callback
/// converts the tags back to type descriptors and resolves the dispatch
/// entry directly, skipping the interpreter loop, stack inspection, and
/// PIC cache management that jitInterpretedCall performs.
export fn jitPicDispatch(ctx_raw: usize, word_id_raw: usize, tag_a_raw: usize, tag_b_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const tag_a: u8 = @intCast(tag_a_raw);
    const tag_b: u8 = @intCast(tag_b_raw);

    // Convert tags to type descriptors via builtin_type_array
    const desc_a = blk: {
        if (tag_a < ctx.builtin_type_array.len) {
            if (ctx.builtin_type_array[tag_a]) |tv| {
                if (tv.descriptor) |d| break :blk d;
            }
        }
        return 1;
    };
    const desc_b = blk: {
        if (tag_b < ctx.builtin_type_array.len) {
            if (ctx.builtin_type_array[tag_b]) |tv| {
                if (tv.descriptor) |d| break :blk d;
            }
        }
        return 1;
    };

    // Resolve word_id → word_name → dispatch_id
    const word_id: u32 = @intCast(word_id_raw);
    const entry = ctx.jit_dispatch.get(word_id) orelse blk: {
        var parent = ctx.parent_context;
        while (parent) |p| : (parent = p.parent_context) {
            if (p.jit_dispatch.get(word_id)) |e| break :blk e;
        }
        return 1;
    };
    const word_name = entry.word_name;
    const dispatch_id = ctx.resolveDispatchId(word_name) orelse return 1;

    // Direct dispatch table lookup with known descriptors
    const dispatch_entry = ctx.lookupBinaryDispatch(dispatch_id, desc_a, desc_b) orelse return 1;

    switch (dispatch_entry.body) {
        .native_fn => |f| {
            f(ctx) catch |err| {
                ctx.jit_pending_error = err;
                return 2;
            };
            if (ctx.trace.trace_pic) {
                var tw = trace_mod.TraceWriter.init();
                trace_mod.tracePicHit(&tw, word_name);
            }
            return 0;
        },
        .quotation, .host_callback => return 1,
    }
}

/// Unary sibling of jitPicDispatch. The generated C code already verified the
/// single top-of-stack operand's tag; this resolves the unary dispatch entry
/// directly, skipping the interpreter loop and PIC cache management.
export fn jitPicDispatchUnary(ctx_raw: usize, word_id_raw: usize, tag_a_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const tag_a: u8 = @intCast(tag_a_raw);

    const desc_a = blk: {
        if (tag_a < ctx.builtin_type_array.len) {
            if (ctx.builtin_type_array[tag_a]) |tv| {
                if (tv.descriptor) |d| break :blk d;
            }
        }
        return 1;
    };

    const word_id: u32 = @intCast(word_id_raw);
    const entry = ctx.jit_dispatch.get(word_id) orelse blk: {
        var parent = ctx.parent_context;
        while (parent) |p| : (parent = p.parent_context) {
            if (p.jit_dispatch.get(word_id)) |e| break :blk e;
        }
        return 1;
    };
    const word_name = entry.word_name;
    const dispatch_id = ctx.resolveDispatchId(word_name) orelse return 1;

    const dispatch_entry = ctx.lookupUnaryDispatch(dispatch_id, desc_a) orelse return 1;

    switch (dispatch_entry.body) {
        .native_fn => |f| {
            f(ctx) catch |err| {
                ctx.jit_pending_error = err;
                return 2;
            };
            if (ctx.trace.trace_pic) {
                var tw = trace_mod.TraceWriter.init();
                trace_mod.tracePicHit(&tw, word_name);
            }
            return 0;
        },
        .quotation, .host_callback => return 1,
    }
}

/// Lightweight PIC-hit native call for JIT mode. Same as jitNativeCall but
/// emits a PIC hit trace event when --trace-pic is enabled. The word name
/// is passed as a pointer+length pair baked into the compiled code.
export fn jitPicNativeCall(ctx_raw: usize, fn_ptr_raw: usize, name_ptr_raw: usize, name_len_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const fn_ptr: *const fn (*Context) anyerror!void = @ptrFromInt(fn_ptr_raw);
    fn_ptr(ctx) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    if (ctx.trace.trace_pic) {
        const name: []const u8 = if (name_len_raw > 0 and name_ptr_raw != 0)
            @as([*]const u8, @ptrFromInt(name_ptr_raw))[0..name_len_raw]
        else
            "<unknown>";
        var tw = trace_mod.TraceWriter.init();
        trace_mod.tracePicHit(&tw, name);
    }
    return 0;
}

export fn jitPicTopTagsMatch(ctx_raw: usize, tag_a_raw: usize, tag_b_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 0;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const items = ctx.stack.items.items;
    if (items.len < 2) return 0;
    const actual_a = @intFromEnum(std.meta.activeTag(items[items.len - 2]));
    const actual_b = @intFromEnum(std.meta.activeTag(items[items.len - 1]));
    return if (actual_a == tag_a_raw and actual_b == tag_b_raw) 1 else 0;
}

/// Unary sibling of jitPicTopTagsMatch: checks only the single top-of-stack
/// operand's tag.
export fn jitPicTopTagMatch(ctx_raw: usize, tag_a_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 0;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const items = ctx.stack.items.items;
    if (items.len < 1) return 0;
    const actual_a = @intFromEnum(std.meta.activeTag(items[items.len - 1]));
    return if (actual_a == tag_a_raw) 1 else 0;
}

export fn jitNativeCall(ctx_raw: usize, fn_ptr_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const func: *const fn (*Context) anyerror!void = @ptrFromInt(fn_ptr_raw);
    func(ctx) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

export fn jitCallQuotation(ctx_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    if (!ctx.allow_interpreted_fallback) {
        const stderr_file: std.fs.File = .stderr();
        stderr_file.writeAll("Fatal: quotation call requires interpreter fallback; rebuild with --interpreter-fallback=true\n") catch {};
        ctx.jit_pending_error = error.InterpreterFallbackDisabled;
        return 2;
    }
    control.nativeCall(ctx) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

/// Call a compiled quotation body via its code_ptr. Used in AOT mode where
/// the IR C backend cannot emit indirect calls through loaded addresses
/// (they are typed as uintptr_t). This thin wrapper casts code_ptr to the
/// proper function pointer type and dispatches.
export fn jitCallCodePtr(jit_ctx_raw: usize, code_ptr_raw: usize) callconv(.c) i32 {
    if (code_ptr_raw == 0) return 1;
    const func: *const fn (usize) callconv(.c) i32 = @ptrFromInt(code_ptr_raw);
    return func(jit_ctx_raw);
}

/// Unified interpreter-free dispatch for a runtime-selected `call`. Given the
/// pointer to the Value at the dispatched slot, it runs whatever callable it
/// holds without re-entering an interpreter:
///   - a quotation: call its code_ptr, or set a defined null-code-ptr error and
///     return 2 if the body was never compiled (the honest trap remainder);
///   - a closure (a curry/compose result over compiled bases): push each
///     segment's captured prefix onto the shared stack, then call that segment's
///     base code_ptr, stopping on the first non-zero status.
/// The captured values are pushed with a retain (the pushed stack slot becomes a
/// new owner); the owning references live in the closure body's instructions.
export fn jitCallValue(jit_ctx_raw: usize, value_ptr_raw: usize) callconv(.c) i32 {
    if (jit_ctx_raw == 0 or value_ptr_raw == 0) return 1;
    const jit_ctx: *JitContext = @ptrFromInt(jit_ctx_raw);
    const v: *const Value = @ptrFromInt(value_ptr_raw);
    switch (v.*) {
        .quotation => |q| {
            const ptr = q.code_ptr orelse {
                const ctx: *Context = @ptrCast(@alignCast(jit_ctx.ctx));
                ctx.jit_pending_error = error.NullCodePtr;
                return 2;
            };
            const func: *const fn (usize) callconv(.c) i32 = @ptrFromInt(@intFromPtr(ptr));
            return func(jit_ctx_raw);
        },
        .closure => |cl| {
            const ctx: *Context = @ptrCast(@alignCast(jit_ctx.ctx));
            // A scope-carrying closure over an uncompiled base has no segments; its body is meant
            // for the interpreter. `curry` over an uncompiled quotation used to yield a plain
            // uncompiled quotation, which traps here the same way, so trap honestly rather than
            // silently running zero segments.
            if (cl.segments.len == 0) {
                ctx.jit_pending_error = error.NullCodePtr;
                return 2;
            }
            for (cl.segments) |seg| {
                for (seg.captures) |cap| {
                    container_backing.retainValue(cap);
                    ctx.stack.push(cap) catch {
                        ctx.jit_pending_error = error.OutOfMemory;
                        return 2;
                    };
                }
                // Pushes may have reallocated the stack buffer; refresh the
                // shared view before handing control to the compiled base.
                jit_ctx.items_ptr = ctx.stack.items.items.ptr;
                jit_ctx.capacity = ctx.stack.items.capacity;
                const func: *const fn (usize) callconv(.c) i32 = @ptrFromInt(@intFromPtr(seg.base_code_ptr));
                const status = func(jit_ctx_raw);
                if (status != 0) return status;
            }
            return 0;
        },
        else => {
            const ctx: *Context = @ptrCast(@alignCast(jit_ctx.ctx));
            ctx.jit_pending_error = error.TypeMismatch;
            return 2;
        },
    }
}

/// Push a string literal onto the stack. The string data is at `str_ptr`
/// with length `str_len`. The runtime copies the data into a managed allocation.
/// Retain the refcounted backing of the Value at a physical stack slot.
/// Emitted where compiled code logically duplicates a `.raw_at_slot` entry
/// (dup, over, combinator arg-copies) so the duplicate counts as a new
/// owning reference. No-op for scalar Values. Touches only the backing
/// allocator, never ctx.stack, so callers need no sp store or stack refresh.
export fn jitRetainSlot(value_ptr: usize) callconv(.c) i32 {
    const v: *const Value = @ptrFromInt(value_ptr);
    container_backing.retainValue(v.*);
    return 0;
}

/// Release the refcounted backing of the Value at a physical stack slot.
/// Emitted where compiled code discards a `.raw_at_slot` entry that no
/// native consumes (drop, the `if` condition). Mirror of jitRetainSlot.
export fn jitReleaseSlot(value_ptr: usize) callconv(.c) i32 {
    const v: *const Value = @ptrFromInt(value_ptr);
    container_backing.releaseValue(v.*);
    return 0;
}

export fn jitPushString(ctx_raw: usize, str_ptr: usize, str_len: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const src: [*]const u8 = @ptrFromInt(str_ptr);
    const copy = ctx.quotationAllocator().dupe(u8, src[0..str_len]) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    ctx.stack.push(.{ .string = copy }) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    return 0;
}

/// Push a symbol literal onto the stack. Same mechanism as jitPushString.
export fn jitPushSymbol(ctx_raw: usize, str_ptr: usize, str_len: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const src: [*]const u8 = @ptrFromInt(str_ptr);
    const copy = ctx.quotationAllocator().dupe(u8, src[0..str_len]) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    ctx.stack.push(.{ .symbol = copy }) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    return 0;
}

/// Helper: report a typed-literal slot miss (out-of-range or NULL slot)
/// onto the Context's error_details so the runtime emits a structured
/// failure for compiled code that consulted a slot table without a live
/// entry. Used by the four slot-indexed `jitPush*Slot` callbacks.
fn recordSlotMiss(ctx: *Context, kind: []const u8, slot: usize) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} slot {d}", .{ kind, slot }) catch return;
    const owned = ctx.arena.allocator().dupe(u8, msg) catch return;
    ctx.error_details.append(ctx.allocator, .{
        .error_type = "image-slot-miss",
        .message = owned,
        .source = "<aot-runtime>",
        .line = 0,
        .word_name = owned,
    }) catch {};
}

/// Push a `.type_val` literal by reading slot `slot` from
/// `onez_image_typevalue_slots[]` (cached on Context at load time).
/// The runtime image loader patched the slot with the live `*TypeValue`
/// pointer; the helper just pushes the Value variant.
export fn jitPushTypeValueSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const table = ctx.image_typevalue_slots orelse {
        recordSlotMiss(ctx, "typevalue", slot);
        ctx.jit_pending_error = error.WordNotFound;
        return 2;
    };
    const tv_const = table[slot] orelse {
        recordSlotMiss(ctx, "typevalue", slot);
        ctx.jit_pending_error = error.WordNotFound;
        return 2;
    };
    const tv: *value_mod.TypeValue = @constCast(tv_const);
    ctx.stack.push(.{ .type_val = tv }) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    return 0;
}

/// Push a `.struct_type` literal by reading slot `slot` from
/// `onez_image_struct_type_slots[]`. The loader patched the slot during
/// runtime-image rehydration; the helper just pushes the Value variant.
export fn jitPushStructTypeSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const table = ctx.image_struct_type_slots orelse {
        recordSlotMiss(ctx, "struct-type", slot);
        ctx.jit_pending_error = error.WordNotFound;
        return 2;
    };
    const st = table[slot] orelse {
        recordSlotMiss(ctx, "struct-type", slot);
        ctx.jit_pending_error = error.WordNotFound;
        return 2;
    };
    ctx.stack.push(.{ .struct_type = st }) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    return 0;
}

/// Push a `.marker` literal by reading slot `slot` from
/// `onez_image_marker_slots[]`. The loader resolved the slot to either a
/// well-known marker singleton or a freshly-allocated `*Marker` during
/// runtime-image rehydration.
export fn jitPushMarkerSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const table = ctx.image_marker_slots orelse {
        recordSlotMiss(ctx, "marker", slot);
        ctx.jit_pending_error = error.WordNotFound;
        return 2;
    };
    const mk = table[slot] orelse {
        recordSlotMiss(ctx, "marker", slot);
        ctx.jit_pending_error = error.WordNotFound;
        return 2;
    };
    ctx.stack.push(.{ .marker = mk }) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    return 0;
}

/// Push a `.parameter` literal by reading slot `slot` from
/// `onez_image_parameter_slots[]`. The loader allocated the `*Parameter`
/// and deserialized its default quotation during runtime-image
/// rehydration.
export fn jitPushParameterSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const table = ctx.image_parameter_slots orelse {
        recordSlotMiss(ctx, "parameter", slot);
        ctx.jit_pending_error = error.WordNotFound;
        return 2;
    };
    const param = table[slot] orelse {
        recordSlotMiss(ctx, "parameter", slot);
        ctx.jit_pending_error = error.WordNotFound;
        return 2;
    };
    ctx.stack.push(.{ .parameter = param }) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    return 0;
}

/// Push a `.tagged` literal by reading slot `slot` from
/// `onez_image_tagged_slots[]`. The loader reconstructed the runtime
/// Value (tag VirtualType recovered via TypeValue.virtual_type, inner
/// deserialized from the description row's bytecode) during
/// runtime-image rehydration; the helper pushes the stored Value.
export fn jitPushTaggedSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const table = ctx.image_tagged_slots orelse {
        recordSlotMiss(ctx, "tagged", slot);
        ctx.jit_pending_error = error.WordNotFound;
        return 2;
    };
    const entry = table[slot] orelse {
        recordSlotMiss(ctx, "tagged", slot);
        ctx.jit_pending_error = error.WordNotFound;
        return 2;
    };
    ctx.stack.push(entry.*) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    return 0;
}

/// Push a `.mutable_map` literal by reading slot `slot` from
/// `onez_image_mutable_map_slots[]`. The loader allocated and populated
/// the `*MutableMap` during runtime-image rehydration; the slot holds a
/// strong reference released by the context's image-slot teardown walk.
/// `stack.push` retains, so the pushed slot owns its own reference and
/// the slot table's anchor stays intact.
export fn jitPushMutableMapSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const table = ctx.image_mutable_map_slots orelse {
        recordSlotMiss(ctx, "mutable_map", slot);
        ctx.jit_pending_error = error.WordNotFound;
        return 2;
    };
    const mmap = table[slot] orelse {
        recordSlotMiss(ctx, "mutable_map", slot);
        ctx.jit_pending_error = error.WordNotFound;
        return 2;
    };
    ctx.stack.push(.{ .mutable_map = mmap }) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    return 0;
}

/// Push the image's struct instance for `slot` onto the stack. A struct
/// instance has no refcount header of its own; `stack.push` retains its
/// field backings, balancing the release that occurs when the pushed copy
/// is dropped.
export fn jitPushStructInstanceSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const table = ctx.image_struct_instance_slots orelse {
        recordSlotMiss(ctx, "struct_instance", slot);
        ctx.jit_pending_error = error.WordNotFound;
        return 2;
    };
    const si = table[slot] orelse {
        recordSlotMiss(ctx, "struct_instance", slot);
        ctx.jit_pending_error = error.WordNotFound;
        return 2;
    };
    ctx.stack.push(.{ .struct_instance = si }) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    return 0;
}

/// Push a `.vector` literal by reading slot `slot` from
/// `onez_image_vector_slots[]`. The loader allocated the `*Vector` during
/// runtime-image rehydration; the slot holds a strong reference released by
/// the context's image-slot teardown walk. `stack.push` retains, so the
/// pushed slot owns its own reference and the slot table's anchor stays
/// intact.
export fn jitPushVectorSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const table = ctx.image_vector_slots orelse {
        recordSlotMiss(ctx, "vector", slot);
        ctx.jit_pending_error = error.WordNotFound;
        return 2;
    };
    const vec = table[slot] orelse {
        recordSlotMiss(ctx, "vector", slot);
        ctx.jit_pending_error = error.WordNotFound;
        return 2;
    };
    ctx.stack.push(.{ .vector = vec }) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    return 0;
}

/// Materialize a quotation literal at a specific memory address. The serialized
/// instruction data is at `data_ptr` with length `data_len`. The runtime
/// deserializes into an Instruction slice and writes the quotation Value to
/// `dest_ptr`. Unlike jitPushString which appends to the stack, this writes
/// to an existing slot position used by materializeQuotations.
export fn jitPushQuotation(ctx_raw: usize, data_ptr: usize, data_len: usize, dest_raw: usize, quotation_id: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const src: [*]const u8 = @ptrFromInt(data_ptr);
    const alloc = ctx.quotationAllocator();
    const instructions = deserializeQuotationInstructions(src[0..data_len], alloc, null) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    const dest: *Value = @ptrFromInt(dest_raw);
    var code_ptr: ?*const anyopaque = null;
    if (ctx.aot_quotation_fns) |fns| {
        if (quotation_id < fns.size) {
            code_ptr = fns.table[quotation_id];
        }
    }
    dest.* = .{ .quotation = .{ .instructions = instructions, .code_ptr = code_ptr } };
    return 0;
}

/// Deserialize an array or hash literal from its serialized byte representation
/// and push it onto the stack. The val_tag in the serialized data determines
/// whether an array or hash is constructed.
export fn jitPushArray(ctx_raw: usize, data_ptr: usize, data_len: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const src: [*]const u8 = @ptrFromInt(data_ptr);
    const alloc = ctx.quotationAllocator();
    var offset: usize = 0;
    // Attach compiled code_ptrs to quotations nested in the composite, indexed by
    // the build-time quotation_id stamped into the serialized form.
    const qfns: ?[]const ?*const anyopaque = if (ctx.aot_quotation_fns) |fns| fns.table[0..fns.size] else null;
    const val = deserializeValueAt(src[0..data_len], &offset, alloc, qfns) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    // The deserialized composite is freshly constructed, so its slots already
    // hold owning references; transfer them to the stack slot instead of
    // retaining a second time and stranding the construction reference.
    ctx.stack.pushMoved(val) catch {
        container_backing.releaseValue(val);
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    return 0;
}

/// Refresh cached stack-buffer pointer and capacity in the JitContext after
/// a callback that may have caused ctx.stack to reallocate. Compiled code
/// addresses the stack through JitContext.items_ptr, which becomes stale if
/// an interpreter callback (e.g. jitInterpretedCall during non-tail
/// recursion) pushes enough values to force ArrayListUnmanaged.append to
/// move the backing slice. Subsequent compiled writes through the stale
/// pointer would scribble into freed memory; this call re-reads the live
/// ptr+capacity from the Context so emitted code can re-LOAD both fields.
export fn jitRefreshStack(jit_ctx_raw: usize) callconv(.c) i32 {
    if (jit_ctx_raw == 0) return 0;
    const jc: *JitContext = @ptrFromInt(jit_ctx_raw);
    const ctx_raw: usize = @intFromPtr(jc.ctx);
    if (ctx_raw == 0 or ctx_raw % @alignOf(Context) != 0) return 0;
    const ctx: *Context = @ptrCast(@alignCast(jc.ctx));
    jc.items_ptr = ctx.stack.items.items.ptr;
    jc.capacity = ctx.stack.items.capacity;
    return 0;
}

/// Grow ctx.stack capacity to at least `needed` slots and refresh the
/// JitContext fields. Called from the compiled prologue when
/// `sp + peak_stack_depth` exceeds the capacity captured when
/// `executeCompiled` entered the initial frame. Recursive
/// compiled-to-compiled calls bypass `executeCompiled`'s capacity
/// reservation, so each compiled entry must re-check and grow the stack
/// itself. Returns 0 on success, 2 (error_propagate) on OOM.
export fn jitEnsureStackCapacity(jit_ctx_raw: usize, needed: usize) callconv(.c) i32 {
    if (jit_ctx_raw == 0) return 2;
    const jc: *JitContext = @ptrFromInt(jit_ctx_raw);
    // Fast path: capacity already suffices, so there is nothing to do and
    // ctx does not need to be dereferenced. This keeps unit tests that pass
    // a sentinel ctx working.
    if (needed <= jc.capacity) return 0;
    const ctx_raw: usize = @intFromPtr(jc.ctx);
    if (ctx_raw == 0 or ctx_raw % @alignOf(Context) != 0) return 2;
    const ctx: *Context = @ptrCast(@alignCast(jc.ctx));
    ctx.stack.items.ensureTotalCapacity(ctx.stack.allocator, needed) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    jc.items_ptr = ctx.stack.items.items.ptr;
    jc.capacity = ctx.stack.items.capacity;
    return 0;
}

/// Error-reporting callbacks for compiled code. Each sets jit_pending_error
/// and returns 2 (error_propagate) so the compiled function can propagate
/// the error without bailing.
fn setJitError(ctx_raw: usize, err: anyerror) i32 {
    if (ctx_raw == 0 or ctx_raw % @alignOf(Context) != 0) return 2;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    ctx.jit_pending_error = err;
    return 2;
}

export fn jitAppendNamedTraceFrame(
    ctx_raw: usize,
    name_ptr_raw: usize,
    name_len_raw: usize,
    line_raw: usize,
) callconv(.c) i32 {
    if (ctx_raw == 0) return 0;
    if (name_ptr_raw == 0) return 0;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const name_ptr: [*]const u8 = @ptrFromInt(name_ptr_raw);
    const word_name = name_ptr[0..name_len_raw];
    const source = ctx.jit_trace_source orelse ctx.current_source;
    ctx.appendPendingSyntheticErrorFrame(word_name, source, @intCast(line_raw));
    return 0;
}

export fn jitAppendBuiltinTraceFrame(
    ctx_raw: usize,
    frame_kind_raw: usize,
    line_raw: usize,
) callconv(.c) i32 {
    if (ctx_raw == 0) return 0;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const kind: BuiltinTraceFrameKind = std.meta.intToEnum(BuiltinTraceFrameKind, frame_kind_raw) catch return 0;
    const word_name = switch (kind) {
        .if_op => "if",
        .call => "call",
        .recover => "recover",
        .cleanup => "cleanup",
    };
    const source = ctx.jit_trace_source orelse ctx.current_source;
    ctx.appendPendingSyntheticErrorFrame(word_name, source, @intCast(line_raw));
    return 0;
}

export fn jitOverflowError(ctx_raw: usize) callconv(.c) i32 {
    return setJitError(ctx_raw, error.Overflow);
}

export fn jitDivisionByZeroError(ctx_raw: usize) callconv(.c) i32 {
    return setJitError(ctx_raw, error.DivisionByZero);
}

export fn jitStackUnderflowError(ctx_raw: usize) callconv(.c) i32 {
    return setJitError(ctx_raw, error.StackUnderflow);
}

export fn jitTypeMismatchError(ctx_raw: usize) callconv(.c) i32 {
    return setJitError(ctx_raw, error.TypeMismatch);
}

export fn jitNullCodePtrError(ctx_raw: usize) callconv(.c) i32 {
    return setJitError(ctx_raw, error.NullCodePtr);
}

const ModuleWordHit = struct {
    word: value_mod.ModuleWord,
    module: *const value_mod.Module,
};

/// Resolve a module-private word that `ctx.lookupWord` cannot see.
///
/// Two paths:
///   - Qualified `module.word`: look up the module value (which may be a
///     `const`-style word whose first instruction pushes the module
///     literal, like `native`), and return its `words.get(word)`.
///   - Bare `name`: walk the module cache and return the first
///     module that has `name` in its private `words` table.
///
/// Used by AOT runtime callbacks that must reach module-private words
/// (constructors like `make-stdio-opts`, internal helpers like
/// `(stdio-opts>native)`, qualified natives like `native.make-struct-instance`).
/// The hot path is `ctx.lookupWord`; this is the slow-path fallback.
fn lookupAnyModuleWord(ctx: *Context, word_name: []const u8) ?ModuleWordHit {
    if (std.mem.lastIndexOfScalar(u8, word_name, '.')) |dot_index| {
        const module_path = word_name[0..dot_index];
        const suffix = word_name[dot_index + 1 ..];
        if (module_path.len == 0 or suffix.len == 0) return null;

        const module_word = ctx.lookupWord(module_path) orelse return null;
        const module = switch (module_word.action) {
            .literal => |val| switch (val) {
                .module => |m| m,
                else => return null,
            },
            .native, .host_callback => return null,
            .compound => |compound| blk: {
                if (compound.len == 0) return null;
                break :blk switch (compound[0].op) {
                    .push_literal => |val| switch (val) {
                        .module => |m| m,
                        else => return null,
                    },
                    else => return null,
                };
            },
        };

        if (module.words.get(suffix)) |mw| return .{ .word = mw, .module = module };
        return null;
    }

    var iter = ctx.module_cache_value.map.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* != .module) continue;
        const module = entry.value_ptr.*.module;
        if (module.words.get(word_name)) |mw| return .{ .word = mw, .module = module };
    }
    return null;
}

/// Run a module-private word resolved via `lookupAnyModuleWord`. Pushes
/// the owning module's deps frame so any references inside the word's
/// body (other module-private helpers, struct types, etc.) resolve.
fn invokeModuleWord(ctx: *Context, hit: ModuleWordHit) !void {
    try ctx.pushModuleDepsFrame(hit.module);
    defer ctx.popModuleDepsFrameTraced(hit.module);

    // A module-private generic word resolved through this path -- a struct
    // field getter loaded from the runtime image is the standard case -- carries
    // the generic marker but only an empty stub body; its real behavior lives in
    // its dispatch methods. The global-dictionary path (`looked_up_word` above)
    // already dispatches such a word on its operand type before running the
    // body; without the same step here the stub runs as a no-op, leaving the
    // operand on the stack where the caller expects the field value. Dispatch
    // first, mirroring that path, and only fall through to the body on a miss.
    const has_generic = for (hit.word.markers) |mk| {
        if (markers_mod.isGenericMarker(mk)) break true;
    } else false;
    if (has_generic and hit.word.dispatch_id != 0) {
        const pic: ?*pic_mod.PolymorphicCache = if (hit.word.word_id) |wid| blk: {
            const em = ctx.jit_dispatch.getMut(wid) orelse break :blk null;
            if (em.dispatch_pic) |p| break :blk p;
            const p = ctx.allocator.create(pic_mod.PolymorphicCache) catch break :blk null;
            p.* = .{};
            em.dispatch_pic = p;
            break :blk p;
        } else null;
        if (try dispatch_helpers.tryDispatchGenericById(ctx, hit.word.dispatch_id, pic)) return;
    }

    switch (hit.word.action) {
        .native => |func| try func(ctx),
        .host_callback => |host| {
            const rc = host.callback(host.handle, host.user_data);
            if (rc != 0) return error.HostCallbackFailed;
        },
        .compound => |instrs| try ctx.executeQuotation(.{ .instructions = instrs }),
    }
}

/// Compiled-code entry point for native words in hosted AOT builds.
///
/// The common case -- a generic-marked global-dictionary primitive, which
/// is every word this function is routed to under the codegen-time fork in
/// `emitNativeWordCall` (`aot_wrappers.registryWrapperSymbol` returns a
/// direct-wrapper symbol for every non-generic native, so only generics
/// ever fall through here) -- is a true leaf call: `entry.native`'s
/// dispatch id, stack effect, function pointer, and source file were
/// resolved once at process startup (`onez_runtime_register_compiled` ->
/// `capi.registerNativeLeaf`) and are read here purely by word_id index, so
/// generic dispatch is attempted unconditionally with no dictionary lookup.
///
/// A second, rarer case reaches this function too: a module-private or
/// dot-qualified native (e.g. `native.virtual-struct-wrap`), which
/// `registerNativeLeaf` cannot resolve because it is never entered into
/// `ctx.dictionary`. That case falls back to the original
/// `ctx.lookupWord` / `lookupAnyModuleWord` resolution.
///
/// The C ABI mirrors `jitInterpretedCall` so callers can swap one for the
/// other in generated code.
export fn jitNativeWordCall(ctx_raw: usize, word_id_raw: usize, line_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const word_id: u32 = @intCast(word_id_raw);
    const entry = ctx.jit_dispatch.get(word_id) orelse blk: {
        var parent = ctx.parent_context;
        while (parent) |p| : (parent = p.parent_context) {
            if (p.jit_dispatch.get(word_id)) |e| break :blk e;
        }
        return 1;
    };
    const word_name = entry.word_name;

    if (bail_stats_mod.enabled) {
        bail_stats_mod.global.recordInterpretedCall(word_id, word_name);
    }

    ctx.pushCallFrame(word_name, ctx.current_source, @intCast(line_raw), 0);

    if (entry.native) |leaf| {
        if (leaf.stack_effect) |effect| {
            ctx.validateParameterEffects(effect) catch |err| {
                ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, err);
                return 2;
            };
            ctx.validateTypeAnnotations(effect) catch |err| {
                ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, err);
                return 2;
            };
        }

        const dispatch_pic: ?*pic_mod.PolymorphicCache = blk2: {
            const em = ctx.jit_dispatch.getMut(word_id) orelse break :blk2 null;
            if (em.dispatch_pic) |p| break :blk2 p;
            const p = ctx.allocator.create(pic_mod.PolymorphicCache) catch break :blk2 null;
            p.* = .{};
            em.dispatch_pic = p;
            break :blk2 p;
        };
        const dispatched = dispatch_helpers.tryDispatchGenericById(ctx, leaf.dispatch_id, dispatch_pic) catch |err| {
            ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, err);
            return 2;
        };
        if (dispatched) {
            ctx.wordSuccessCleanup(word_name, null) catch |err| {
                ctx.jit_pending_error = err;
                return 2;
            };
            return 0;
        }

        if (leaf.source_file) |sf| ctx.current_source = sf;
        const result = leaf.fn_ptr(ctx);

        if (result) |_| {
            ctx.consumePropagatedTailCall(word_name) catch |err| {
                ctx.jit_pending_error = err;
                return 2;
            };
            ctx.wordSuccessCleanup(word_name, if (leaf.stack_effect) |se| se.* else null) catch |err| {
                ctx.jit_pending_error = err;
                return 2;
            };
            return 0;
        } else |err| {
            ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, err);
            return 2;
        }
    }

    const looked_up_word = ctx.lookupWord(word_name);
    const module_hit = if (looked_up_word == null) lookupAnyModuleWord(ctx, word_name) else null;

    const result = if (looked_up_word) |word| blk: {
        if (word.stack_effect) |effect| {
            ctx.validateParameterEffects(&effect) catch |err| {
                ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, err);
                return 2;
            };
            if (!shouldSkipTypeAnnotationValidation(word)) {
                ctx.validateTypeAnnotations(&effect) catch |err| {
                    ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, err);
                    return 2;
                };
            }
        }

        const has_generic = for (word.markers) |mk| {
            if (markers_mod.isGenericMarker(mk)) break true;
        } else false;

        if (has_generic) {
            const dispatch_pic: ?*pic_mod.PolymorphicCache = blk2: {
                const em = ctx.jit_dispatch.getMut(word_id) orelse break :blk2 null;
                if (em.dispatch_pic) |p| break :blk2 p;
                const p = ctx.allocator.create(pic_mod.PolymorphicCache) catch break :blk2 null;
                p.* = .{};
                em.dispatch_pic = p;
                break :blk2 p;
            };
            const dispatched = dispatch_helpers.tryDispatchGenericWithPic(ctx, word_name, dispatch_pic) catch |err| {
                ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, err);
                return 2;
            };
            if (dispatched) {
                ctx.wordSuccessCleanup(word_name, null) catch |err| {
                    ctx.jit_pending_error = err;
                    return 2;
                };
                return 0;
            }
        }

        if (word.source_file) |sf| ctx.current_source = sf;
        switch (word.action) {
            .native => |func| break :blk func(ctx),
            .host_callback => |host| {
                const rc = host.callback(host.handle, host.user_data);
                if (rc != 0) break :blk @as(anyerror!void, error.HostCallbackFailed);
                break :blk @as(anyerror!void, {});
            },
            .compound, .literal => {
                const stderr_file: std.fs.File = .stderr();
                stderr_file.writeAll("Fatal: jitNativeWordCall invoked for non-native word '") catch {};
                stderr_file.writeAll(word_name) catch {};
                stderr_file.writeAll("'\n") catch {};
                ctx.jit_pending_error = error.InternalError;
                return 2;
            },
        }
    } else if (module_hit) |hit| blk: {
        break :blk invokeModuleWord(ctx, hit);
    } else {
        return 1;
    };

    if (result) |_| {
        ctx.consumePropagatedTailCall(word_name) catch |err| {
            ctx.jit_pending_error = err;
            return 2;
        };
        const cleanup_effect = if (looked_up_word) |word| word.stack_effect else if (module_hit) |hit| hit.word.stack_effect else null;
        ctx.wordSuccessCleanup(word_name, cleanup_effect) catch |err| {
            ctx.jit_pending_error = err;
            return 2;
        };
        return 0;
    } else |err| {
        ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, err);
        return 2;
    }
}

export fn jitInterpretedCall(ctx_raw: usize, word_id_raw: usize, line_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const word_id: u32 = @intCast(word_id_raw);
    const entry = ctx.jit_dispatch.get(word_id) orelse blk: {
        var parent = ctx.parent_context;
        while (parent) |p| : (parent = p.parent_context) {
            if (p.jit_dispatch.get(word_id)) |e| break :blk e;
        }
        return 1;
    };
    const word_name = entry.word_name;
    if (!ctx.allow_interpreted_fallback) {
        const stderr_file: std.fs.File = .stderr();
        stderr_file.writeAll("Fatal: word '") catch {};
        stderr_file.writeAll(word_name) catch {};
        stderr_file.writeAll("' requires interpreter fallback; rebuild with --interpreter-fallback=true\n") catch {};
        ctx.jit_pending_error = error.InterpreterFallbackDisabled;
        return 2;
    }
    if (bail_stats_mod.enabled) {
        bail_stats_mod.global.recordInterpretedCall(word_id, word_name);
    }

    ctx.pushCallFrame(word_name, ctx.current_source, @intCast(line_raw), 0);
    const looked_up_word = ctx.lookupWord(word_name);
    const module_hit = if (looked_up_word == null) lookupAnyModuleWord(ctx, word_name) else null;

    const result = if (looked_up_word) |word| blk: {
        if (word.stack_effect) |effect| {
            ctx.validateParameterEffects(&effect) catch |err| {
                ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, err);
                return 2;
            };
            if (!shouldSkipTypeAnnotationValidation(word)) {
                ctx.validateTypeAnnotations(&effect) catch |err| {
                    ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, err);
                    return 2;
                };
            }
        }

        if (word.action == .compound) {
            const has_generic = for (word.markers) |mk| {
                if (markers_mod.isGenericMarker(mk)) break true;
            } else false;

            if (has_generic) {
                const dispatch_pic: ?*pic_mod.PolymorphicCache = blk2: {
                    const em = ctx.jit_dispatch.getMut(word_id) orelse break :blk2 null;
                    if (em.dispatch_pic) |p| break :blk2 p;
                    const p = ctx.allocator.create(pic_mod.PolymorphicCache) catch break :blk2 null;
                    p.* = .{};
                    em.dispatch_pic = p;
                    break :blk2 p;
                };
                const dispatched = dispatch_helpers.tryDispatchGenericWithPic(ctx, word_name, dispatch_pic) catch |err| {
                    ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, err);
                    return 2;
                };
                if (dispatched) {
                    ctx.wordSuccessCleanup(word_name, null) catch |err| {
                        ctx.jit_pending_error = err;
                        return 2;
                    };
                    return 0;
                }
                if (word.action.compound.len == 0) {
                    ctx.setGenericDispatchErrorDetails(word_name, word.stack_effect);
                    ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, error.TypeError);
                    return 2;
                }
            }
        }

        if (word.source_file) |sf| ctx.current_source = sf;
        if (word.source_module) |mod| {
            switch (word.action) {
                .compound => |instrs| {
                    ctx.pushModuleDepsFrame(mod) catch |e| break :blk @as(anyerror!void, e);
                    defer ctx.popModuleDepsFrameTraced(mod);
                    break :blk ctx.executeQuotationWithPic(.{ .instructions = instrs }, entry.pic_snapshot, mod);
                },
                .native => |func| break :blk func(ctx),
                .host_callback => |host| break :blk host_result: {
                    const rc = host.callback(host.handle, host.user_data);
                    if (rc != 0) break :host_result error.HostCallbackFailed;
                    break :host_result;
                },
                .literal => |v| break :blk ctx.stack.push(v),
            }
        } else {
            break :blk switch (word.action) {
                .native => |func| func(ctx),
                .host_callback => |host| host_result: {
                    const rc = host.callback(host.handle, host.user_data);
                    if (rc != 0) break :host_result error.HostCallbackFailed;
                    break :host_result;
                },
                .compound => |instrs| ctx.executeQuotationWithPic(.{ .instructions = instrs }, entry.pic_snapshot, null),
                .literal => |v| ctx.stack.push(v),
            };
        }
    } else if (module_hit) |hit| blk: {
        break :blk invokeModuleWord(ctx, hit);
    } else {
        return 1;
    };

    if (result) |_| {
        ctx.consumePropagatedTailCall(word_name) catch |err| {
            ctx.jit_pending_error = err;
            return 2;
        };
        const cleanup_effect = if (looked_up_word) |word| word.stack_effect else if (module_hit) |hit| hit.word.stack_effect else null;
        ctx.wordSuccessCleanup(word_name, cleanup_effect) catch |err| {
            ctx.jit_pending_error = err;
            return 2;
        };
        return 0;
    } else |err| {
        ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, err);
        return 2;
    }
}

/// Result of attempting compiled execution.
pub const ExecResult = enum {
    ok,
    bail,
    error_propagate,

    /// Convert a compiled function's raw i32 return status to an ExecResult.
    /// Status 0 = ok, 2 = error_propagate, anything else = bail.
    /// Status 3 (trampoline) must be handled by the caller before calling this.
    pub fn fromStatus(status: i32) ExecResult {
        return switch (status) {
            0 => .ok,
            2 => .error_propagate,
            else => .bail,
        };
    }
};

/// Execute a JIT-compiled word. The compiled function operates directly on
/// the per-task Value stack: it reads inputs, checks fixnum tags, performs
/// arithmetic, writes the result, and adjusts the stack pointer. Returns
/// .bail if the compiled function signals a type mismatch or overflow, in
/// which case the stack is unchanged.
pub fn executeCompiled(ctx: *Context, word_id: u32) ExecResult {
    ctx.clearPendingSyntheticErrorFrames();
    const saved_trace_source = ctx.jit_trace_source;
    defer ctx.jit_trace_source = saved_trace_source;
    const entry = ctx.jit_dispatch.get(word_id) orelse blk: {
        var parent = ctx.parent_context;
        while (parent) |p| : (parent = p.parent_context) {
            if (p.jit_dispatch.get(word_id)) |e| break :blk e;
        }
        return .bail;
    };
    var code_ptr = entry.code_ptr orelse return .bail;
    if (ctx.lookupWord(entry.word_name)) |word| {
        ctx.jit_trace_source = word.source_file orelse ctx.current_source;
    } else {
        ctx.jit_trace_source = ctx.current_source;
    }

    // Compiled code writes directly to the stack array without bounds checks.
    // Ensure enough capacity for the peak stack depth reached during the compiled function's execution.
    if (entry.peak_stack_depth > 0) {
        const min_capacity = ctx.stack.items.items.len + entry.peak_stack_depth;
        if (ctx.stack.items.capacity < min_capacity) {
            ctx.stack.items.ensureTotalCapacity(ctx.stack.allocator, min_capacity) catch return .bail;
        }
    }

    const saved_sp = ctx.stack.items.items.len;
    var jit_ctx = JitContext{
        .items_ptr = ctx.stack.items.items.ptr,
        .sp_ptr = &ctx.stack.items.items.len,
        .capacity = ctx.stack.items.capacity,
        .ctx = ctx,
    };
    var func: CompiledFn = @ptrCast(@alignCast(code_ptr));
    var status = func(&jit_ctx);

    // Trampoline loop: re-dispatch while compiled functions request it.
    // Status 3 means "tail-call to trampoline_target instead of returning".
    while (status == 3) {
        const target_id = jit_ctx.trampoline_target;
        const target_entry = ctx.jit_dispatch.get(target_id) orelse blk: {
            var parent = ctx.parent_context;
            while (parent) |p| : (parent = p.parent_context) {
                if (p.jit_dispatch.get(target_id)) |e| break :blk e;
            }
            ctx.stack.items.items.len = saved_sp;
            return .bail;
        };
        code_ptr = target_entry.code_ptr orelse {
            ctx.stack.items.items.len = saved_sp;
            return .bail;
        };
        if (ctx.lookupWord(target_entry.word_name)) |word| {
            ctx.jit_trace_source = word.source_file orelse ctx.current_source;
        } else {
            ctx.jit_trace_source = ctx.current_source;
        }
        // Re-read items_ptr/capacity in case stack was reallocated
        jit_ctx.items_ptr = ctx.stack.items.items.ptr;
        jit_ctx.capacity = ctx.stack.items.capacity;
        func = @ptrCast(@alignCast(code_ptr));
        status = func(&jit_ctx);
    }

    const result = ExecResult.fromStatus(status);
    if (result == .bail) {
        ctx.clearPendingSyntheticErrorFrames();
        if (bail_stats_mod.enabled) {
            const entry_name = if (ctx.jit_dispatch.get(word_id)) |e| e.word_name else "?";
            bail_stats_mod.global.recordBail(word_id, entry_name);
        }
        ctx.stack.items.items.len = saved_sp;
    }
    if (result != .error_propagate) {
        ctx.clearPendingSyntheticErrorFrames();
    }
    return result;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Heap-allocates a `NativeLeafData` for `word_id` and stores it on the
/// entry, mirroring `capi.registerNativeLeaf`'s own allocation so
/// `JitDispatchTable.deinit`'s cleanup (which unconditionally destroys a
/// non-null `entry.native`) has something real to free.
fn registerTestNativeLeaf(ctx: *Context, word_id: u32, def: *WordDefinition) !void {
    const leaf = try ctx.allocator.create(jit_dispatch_mod.NativeLeafData);
    leaf.* = .{
        .fn_ptr = def.action.native,
        .dispatch_id = def.dispatch_id,
        .stack_effect = if (def.stack_effect != null) &def.stack_effect.? else null,
        .source_file = def.source_file,
    };
    ctx.jit_dispatch.getMut(word_id).?.native = leaf;
}

test "jitNativeWordCall: dispatch hit runs the registered override, not the native's default body" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const def = ctx.dictionary.getPtr("+").?;
    const word_id = try ctx.jit_dispatch.assignId("+");
    try registerTestNativeLeaf(&ctx, word_id, def);

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    try ctx.registerDispatch(.{
        .dispatch_id = def.dispatch_id,
        .type_a = fixnum_tv.descriptor.?,
        .type_b = fixnum_tv.descriptor.?,
    }, .{ .body = .{ .native_fn = struct {
        fn f(fn_ctx: *Context) anyerror!void {
            _ = try fn_ctx.stack.pop();
            _ = try fn_ctx.stack.pop();
            try fn_ctx.stack.push(.{ .fixnum = 999 });
        }
    }.f } }, true);

    try ctx.stack.push(.{ .fixnum = 1 });
    try ctx.stack.push(.{ .fixnum = 2 });

    const rc = jitNativeWordCall(@intFromPtr(&ctx), word_id, 1);
    try testing.expectEqual(@as(i32, 0), rc);

    const result = try ctx.stack.pop();
    try testing.expectEqual(@as(i64, 999), result.fixnum);
}

test "jitNativeWordCall: dispatch miss falls through to the cached native function pointer" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const def = ctx.dictionary.getPtr("+").?;
    const word_id = try ctx.jit_dispatch.assignId("+");
    try registerTestNativeLeaf(&ctx, word_id, def);

    // "+" has no registered dispatch entry for string operands, so this
    // reaches the cached native function pointer directly and surfaces its
    // own type-mismatch error, proving the fallthrough path runs with no
    // dictionary lookup.
    try ctx.stack.push(.{ .string = "a" });
    try ctx.stack.push(.{ .string = "b" });

    const rc = jitNativeWordCall(@intFromPtr(&ctx), word_id, 1);
    try testing.expectEqual(@as(i32, 2), rc);
    try testing.expectEqual(error.TypeMismatch, ctx.jit_pending_error.?);
}

test "jitNativeWordCall: unrecognized word_id with no cached native leaf returns 1" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const word_id = try ctx.jit_dispatch.assignId("some-compound-word");
    const rc = jitNativeWordCall(@intFromPtr(&ctx), word_id, 1);
    try testing.expectEqual(@as(i32, 1), rc);
}

/// Build a flush plan for `stack[0...sp]`, simulate it over an integer slot array where each slot
/// starts holding its own index as a marker, then assert every output slot ends up holding the
/// value its abstract entry designated.
///
/// This proves the plan never destroys a source before its dependents read it, independent of the
/// emit order chosen.
fn checkFlushPlan(stack: []const StackEntry, sp: usize) !void {
    var plan: [max_abstract_stack_depth]MoveOp = undefined;
    const n = planFlushMoves(stack, sp, &plan);

    const box_base: i64 = 1000;
    var slots: [max_abstract_stack_depth]i64 = undefined;
    for (0..max_abstract_stack_depth) |i| slots[i] = @intCast(i);
    for (plan[0..n]) |m| {
        switch (m) {
            .box_i64 => |b| slots[b.slot] = box_base + @as(i64, @intCast(b.slot)),
            .box_f64 => |b| slots[b.slot] = box_base + @as(i64, @intCast(b.slot)),
            .box_bool => |b| slots[b.slot] = box_base + @as(i64, @intCast(b.slot)),
            .copy => |cp| slots[cp.dest] = slots[cp.src],
            .swap => |sw| {
                const t = slots[sw.a];
                slots[sw.a] = slots[sw.b];
                slots[sw.b] = t;
            },
        }
    }

    for (0..sp) |i| {
        const expected: i64 = switch (stack[i]) {
            .i64_ref, .f64_ref, .bool_ref => box_base + @as(i64, @intCast(i)),
            .raw_at_slot => |s| @intCast(s),
            .quotation_body, .row_region => continue,
        };
        try testing.expectEqual(expected, slots[i]);
    }
}

test "flush planner: aliased copy is ordered before the boxing that clobbers it" {
    // stack[1] aliases slot 0, which stack[0] will box over. The copy must run
    // first. This is the shape the old hazard prepass existed to rescue.
    const stack = [_]StackEntry{ .{ .i64_ref = 0 }, .{ .raw_at_slot = 0 } };
    var plan: [max_abstract_stack_depth]MoveOp = undefined;
    const n = planFlushMoves(&stack, 2, &plan);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(plan[0] == .copy);
    try testing.expectEqual(@as(usize, 0), plan[0].copy.src);
    try testing.expectEqual(@as(usize, 1), plan[0].copy.dest);
    try testing.expect(plan[1] == .box_i64);
    try testing.expectEqual(@as(usize, 0), plan[1].box_i64.slot);
    try checkFlushPlan(&stack, 2);
}

test "flush planner: two-cycle resolves with a swap" {
    const stack = [_]StackEntry{ .{ .raw_at_slot = 1 }, .{ .raw_at_slot = 0 } };
    var plan: [max_abstract_stack_depth]MoveOp = undefined;
    const n = planFlushMoves(&stack, 2, &plan);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(plan[0] == .swap);
    try checkFlushPlan(&stack, 2);
}

test "flush planner: three-cycle (rot shape) is materialized correctly" {
    // rot-shaped permutation: slot 0 <- 1, slot 1 <- 2, slot 2 <- 0. The old
    // pass-order flush only special-cased two-cycles and corrupted this.
    const stack = [_]StackEntry{ .{ .raw_at_slot = 1 }, .{ .raw_at_slot = 2 }, .{ .raw_at_slot = 0 } };
    try checkFlushPlan(&stack, 3);
}

test "flush planner: source above the live top is read safely" {
    // raw_at_slot 2 with sp == 1 reads a slot that is never a destination.
    const stack = [_]StackEntry{ .{ .raw_at_slot = 2 }, .{ .raw_at_slot = 0 }, .{ .raw_at_slot = 0 } };
    try checkFlushPlan(&stack, 1);
}

test "flush planner: independent boxes need no ordering" {
    const stack = [_]StackEntry{ .{ .i64_ref = 0 }, .{ .f64_ref = 0 } };
    var plan: [max_abstract_stack_depth]MoveOp = undefined;
    const n = planFlushMoves(&stack, 2, &plan);
    try testing.expectEqual(@as(usize, 2), n);
    try checkFlushPlan(&stack, 2);
}

test "flush planner: identity-only stack emits no moves" {
    const stack = [_]StackEntry{ .{ .raw_at_slot = 0 }, .{ .raw_at_slot = 1 } };
    var plan: [max_abstract_stack_depth]MoveOp = undefined;
    const n = planFlushMoves(&stack, 2, &plan);
    try testing.expectEqual(@as(usize, 0), n);
    try checkFlushPlan(&stack, 2);
}

test "flush planner: fan-out duplicates one source into several slots" {
    // slot 2 is identity; slots 0 and 1 both copy from slot 2.
    const stack = [_]StackEntry{ .{ .raw_at_slot = 2 }, .{ .raw_at_slot = 2 }, .{ .raw_at_slot = 2 } };
    try checkFlushPlan(&stack, 3);
}

test "flush planner: cycle mixed with a dependent box" {
    // two-cycle on slots 0,1 plus a box at slot 2 that an alias at slot 3 reads first.
    const stack = [_]StackEntry{
        .{ .raw_at_slot = 1 },
        .{ .raw_at_slot = 0 },
        .{ .i64_ref = 0 },
        .{ .raw_at_slot = 2 },
    };
    try checkFlushPlan(&stack, 4);
}

test "ValueLayout slice offsets reconstruct a string Value" {
    // The direct string-literal codegen writes a tag, slice pointer, and slice
    // length at the discovered ValueLayout offsets. Mirror that here against a
    // raw byte buffer and confirm it reads back as the intended string. Guards
    // the offsets the codegen depends on and the fixed 40-byte layout.
    try testing.expectEqual(@as(usize, 40), @sizeOf(Value));
    ValueLayout.ensureInit();

    const body = "hello";
    var buf: [@sizeOf(Value)]u8 = undefined;

    const tag_int: u8 = @intFromEnum(@as(ValueLayout.TagType, .string));
    @memcpy(buf[ValueLayout.tag_offset .. ValueLayout.tag_offset + ValueLayout.tag_size], std.mem.asBytes(&tag_int)[0..ValueLayout.tag_size]);

    const ptr_int: usize = @intFromPtr(body.ptr);
    @memcpy(buf[ValueLayout.payload_offset .. ValueLayout.payload_offset + @sizeOf(usize)], std.mem.asBytes(&ptr_int));

    const len_val: usize = body.len;
    @memcpy(buf[ValueLayout.slice_len_offset .. ValueLayout.slice_len_offset + @sizeOf(usize)], std.mem.asBytes(&len_val));

    const reconstructed: *align(1) const Value = @ptrCast(&buf);
    try testing.expect(reconstructed.* == .string);
    try testing.expectEqualStrings("hello", reconstructed.string);
}

fn makeInstructions(comptime ops: anytype) [ops.len]Instruction {
    var instrs: [ops.len]Instruction = undefined;
    inline for (ops, 0..) |op, i| {
        instrs[i] = .{
            .op = switch (@TypeOf(op)) {
                i64, comptime_int => .{ .push_literal = .{ .fixnum = @as(i64, op) } },
                else => .{ .call_word = op },
            },
            .line = i + 1,
        };
    }
    return instrs;
}

/// Resolve the polymorphic arithmetic ops to a dummy word id for unit tests.
///
/// Arithmetic on two runtime-unknown operands emits a cold fallback arm that
/// calls the polymorphic native, so the op must resolve or the body is
/// NotCompilable. Tests that exercise the fast path with fixnum inputs never
/// take the arm, so the dummy id is never dispatched.
fn resolveArithOpForTest(name: []const u8, user_data: *anyopaque) ?ResolvedWord {
    _ = user_data;
    const ops = [_][]const u8{ "+", "-", "*", "/", "%" };
    for (ops) |op| {
        if (std.mem.eql(u8, name, op)) {
            return .{ .word_id = 0, .input_count = 2, .output_count = 1, .is_native = true };
        }
    }
    return null;
}

var arith_test_resolver_dummy: u8 = 0;

const arith_test_resolver = WordResolver{
    .resolve = &resolveArithOpForTest,
    .user_data = @ptrCast(&arith_test_resolver_dummy),
    .dispatch_table_ptr = @ptrCast(&arith_test_resolver_dummy),
};

/// Default metadata for unit tests. Static field values keep the
/// emitted C source byte-for-byte stable across hosts.
const test_aot_metadata: AotMetadata = .{
    .interpreter_fallback_mode = .auto,
    .interpreter_setting_locked = false,
    .runtime_image_present = false,
    .target_triple = "test-target",
    .build_mode = "Debug",
    .onez_version = "0.0.0-test",
    .prelude_hash_hex = "0000000000000000000000000000000000000000000000000000000000000000",
};

/// Helper to call a compiled function with a Value stack.
/// Sets up a stack with the given fixnum values, calls the function, and
/// returns the status code. On success, `result` is set to the top fixnum.
fn callCompiled(func: CompiledFn, inputs: []const i64, result: *i64) i32 {
    var values: [16]Value = undefined;
    for (inputs, 0..) |v, i| {
        values[i] = .{ .fixnum = v };
    }
    var sp: usize = inputs.len;
    var jit_ctx = JitContext{
        .items_ptr = &values,
        .sp_ptr = &sp,
        .capacity = values.len,
        .ctx = @ptrFromInt(@as(usize, 1)),
    };
    const status = func(&jit_ctx);
    if (status == 0 and sp > 0) {
        result.* = values[sp - 1].fixnum;
    }
    return status;
}

/// Helper to call a compiled function with raw Value stack for non-fixnum tests.
/// Uses a large internal buffer so the prologue capacity check never tries to
/// grow through the sentinel ctx pointer.
fn callCompiledValues(func: CompiledFn, values: []Value, sp: *usize) i32 {
    var buf: [64]Value = undefined;
    @memcpy(buf[0..values.len], values);
    var jit_ctx = JitContext{
        .items_ptr = &buf,
        .sp_ptr = sp,
        .capacity = buf.len,
        .ctx = @ptrFromInt(@as(usize, 1)),
    };
    const status = func(&jit_ctx);
    @memcpy(values, buf[0..values.len]);
    return status;
}

test "appendLineDirective: basic format" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try appendLineDirective(&out, allocator, "tests/aot/example.1z", 42);
    try testing.expectEqualStrings("#line 42 \"tests/aot/example.1z\"\n", out.items);
}

test "appendLineDirective: 1z identifier characters pass through verbatim" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try appendLineDirective(&out, allocator, "src/x-y?z!.1z", 1);
    try testing.expectEqualStrings("#line 1 \"src/x-y?z!.1z\"\n", out.items);
}

test "appendLineDirective: escapes quotes and backslashes, strips controls" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try appendLineDirective(&out, allocator, "weird\"path\\with\nnewline\x00nul.1z", 7);
    try testing.expectEqualStrings("#line 7 \"weird\\\"path\\\\withnewlinenul.1z\"\n", out.items);
}

test "appendAsmNameClause: ASCII identifier emits verbatim" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try appendAsmNameClause(&out, allocator, "double");
    try testing.expectEqualStrings(" asm(\"double\")", out.items);
}

test "appendAsmNameClause: 1z special characters pass through verbatim" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try appendAsmNameClause(&out, allocator, "parse-json?");
    try testing.expectEqualStrings(" asm(\"parse-json?\")", out.items);

    out.clearRetainingCapacity();
    try appendAsmNameClause(&out, allocator, ">foo");
    try testing.expectEqualStrings(" asm(\">foo\")", out.items);

    out.clearRetainingCapacity();
    try appendAsmNameClause(&out, allocator, "@get!");
    try testing.expectEqualStrings(" asm(\"@get!\")", out.items);
}

test "appendAsmNameClause: UTF-8 multi-byte names pass through" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try appendAsmNameClause(&out, allocator, "café");
    try testing.expectEqualStrings(" asm(\"café\")", out.items);
}

test "appendAsmNameClause: NUL byte triggers fallback" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try appendAsmNameClause(&out, allocator, "bad\x00name");
    try testing.expectEqualStrings("", out.items);
}

test "appendAsmNameClause: embedded quote triggers fallback" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try appendAsmNameClause(&out, allocator, "say\"hi");
    try testing.expectEqualStrings("", out.items);
}

test "appendAsmNameClause: backslash triggers fallback" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try appendAsmNameClause(&out, allocator, "back\\slash");
    try testing.expectEqualStrings("", out.items);
}

test "appendAsmNameClause: ASCII control character triggers fallback" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try appendAsmNameClause(&out, allocator, "tab\there");
    try testing.expectEqualStrings("", out.items);

    out.clearRetainingCapacity();
    try appendAsmNameClause(&out, allocator, "del\x7fhere");
    try testing.expectEqualStrings("", out.items);
}

test "appendQuotationAsmNameClause: formats <defining-word>/quot@<line>:<col>" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    const q = AotQuotationDesc{
        .quotation_id = 0,
        .instructions = &.{},
        .c_name = "onez_q_0",
        .defining_word = "parse-json",
        .source_line = 17,
        .source_column = 8,
    };
    try appendQuotationAsmNameClause(&out, allocator, q);
    try testing.expectEqualStrings(" asm(\"parse-json/quot@17:8\")", out.items);
}

test "appendQuotationAsmNameClause: sibling quotations get distinct line:col" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    const a = AotQuotationDesc{
        .quotation_id = 0,
        .instructions = &.{},
        .c_name = "onez_q_0",
        .defining_word = "abs",
        .source_line = 16,
        .source_column = 3,
    };
    const b = AotQuotationDesc{
        .quotation_id = 1,
        .instructions = &.{},
        .c_name = "onez_q_1",
        .defining_word = "abs",
        .source_line = 17,
        .source_column = 3,
    };
    try appendQuotationAsmNameClause(&out, allocator, a);
    try appendQuotationAsmNameClause(&out, allocator, b);
    try testing.expectEqualStrings(" asm(\"abs/quot@16:3\") asm(\"abs/quot@17:3\")", out.items);
}

test "appendQuotationAsmNameClause: defining_word null suppresses asm-name" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    const q = AotQuotationDesc{
        .quotation_id = 0,
        .instructions = &.{},
        .c_name = "onez_q_0",
        .defining_word = null,
        .source_line = 17,
        .source_column = 8,
    };
    try appendQuotationAsmNameClause(&out, allocator, q);
    try testing.expectEqualStrings("", out.items);
}

test "appendQuotationAsmNameClause: zero line/column suppresses asm-name" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    const no_line = AotQuotationDesc{
        .quotation_id = 0,
        .instructions = &.{},
        .c_name = "onez_q_0",
        .defining_word = "foo",
        .source_line = 0,
        .source_column = 8,
    };
    const no_col = AotQuotationDesc{
        .quotation_id = 0,
        .instructions = &.{},
        .c_name = "onez_q_0",
        .defining_word = "foo",
        .source_line = 17,
        .source_column = 0,
    };
    try appendQuotationAsmNameClause(&out, allocator, no_line);
    try appendQuotationAsmNameClause(&out, allocator, no_col);
    try testing.expectEqualStrings("", out.items);
}

test "appendQuotationAsmNameClause: toolchain-hostile defining word triggers fallback" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    const q = AotQuotationDesc{
        .quotation_id = 0,
        .instructions = &.{},
        .c_name = "onez_q_0",
        .defining_word = "bad\"name",
        .source_line = 17,
        .source_column = 8,
    };
    try appendQuotationAsmNameClause(&out, allocator, q);
    try testing.expectEqualStrings("", out.items);
}

test "appendGeneratedWordAsmNameClause: formats <parent>/<name>" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try appendGeneratedWordAsmNameClause(&out, allocator, "name>>", "Person");
    try testing.expectEqualStrings(" asm(\"Person/name>>\")", out.items);
}

test "appendGeneratedWordAsmNameClause: same accessor name on different parents stays distinct" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try appendGeneratedWordAsmNameClause(&out, allocator, "name>>", "Person");
    try appendGeneratedWordAsmNameClause(&out, allocator, "name>>", "Account");
    try testing.expectEqualStrings(" asm(\"Person/name>>\") asm(\"Account/name>>\")", out.items);
}

test "appendGeneratedWordAsmNameClause: null parent falls back to bare name" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try appendGeneratedWordAsmNameClause(&out, allocator, "active?", null);
    try testing.expectEqualStrings(" asm(\"active?\")", out.items);
}

test "appendGeneratedWordAsmNameClause: empty parent falls back to bare name" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try appendGeneratedWordAsmNameClause(&out, allocator, "active?", "");
    try testing.expectEqualStrings(" asm(\"active?\")", out.items);
}

test "appendGeneratedWordAsmNameClause: toolchain-hostile parent triggers fallback" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try appendGeneratedWordAsmNameClause(&out, allocator, "name>>", "bad\"parent");
    try testing.expectEqualStrings("", out.items);
}

test "appendGeneratedWordAsmNameClause: toolchain-hostile name triggers fallback" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try appendGeneratedWordAsmNameClause(&out, allocator, "bad\"name", "Person");
    try testing.expectEqualStrings("", out.items);
}

test "emitProgramC: generated word forward declaration carries qualified asm-name" {
    const body_instrs = makeInstructions(.{@as(i64, 1)});

    const words = [_]AotWordDesc{
        .{
            .name = "name>>",
            .instructions = &body_instrs,
            .input_count = 0,
            .output_count = 1,
            .word_id = 0,
            .is_generated = true,
            .parent = "Person",
        },
    };

    var diag: CodegenDiagnostics = .{};
    const source = try emitProgramC(&words, &.{}, 0, 0, &.{}, .auto, false, test_aot_metadata, &diag, null, false, &.{}, testing.allocator);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "asm(\"Person/name>>\")") != null);
}

test "emitProgramC: generated word with null parent falls back to bare asm-name" {
    const body_instrs = makeInstructions(.{@as(i64, 1)});

    const words = [_]AotWordDesc{
        .{
            .name = "lonely?",
            .instructions = &body_instrs,
            .input_count = 0,
            .output_count = 1,
            .word_id = 0,
            .is_generated = true,
            .parent = null,
        },
    };

    var diag: CodegenDiagnostics = .{};
    const source = try emitProgramC(&words, &.{}, 0, 0, &.{}, .auto, false, test_aot_metadata, &diag, null, false, &.{}, testing.allocator);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "asm(\"lonely?\")") != null);
    try testing.expect(std.mem.indexOf(u8, source, "/lonely?") == null);
}

test "emitProgramC: compiled quotation forward declaration carries asm-name" {
    const body_instrs = makeInstructions(.{@as(i64, 1)});

    const words = [_]AotWordDesc{
        .{ .name = "main", .instructions = &body_instrs, .input_count = 0, .output_count = 1, .word_id = 0 },
    };

    var quotations = [_]AotQuotationDesc{
        .{
            .quotation_id = 0,
            .instructions = &body_instrs,
            .c_name = "onez_q_0",
            .inferred_effect = .{ .input_count = 0, .output_count = 1 },
            .defining_word = "main",
            .source_line = 7,
            .source_column = 11,
        },
    };

    var diag: CodegenDiagnostics = .{};
    const source = try emitProgramC(&words, &quotations, 0, 0, &.{}, .auto, false, test_aot_metadata, &diag, null, false, &.{}, testing.allocator);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "int32_t onez_q_0(uintptr_t jit_ctx) asm(\"main/quot@7:11\");") != null);
}

test "emitProgramC: hosted preamble contains libc includes and main shim" {
    const body_instrs = makeInstructions(.{@as(i64, 1)});

    const words = [_]AotWordDesc{
        .{ .name = "main", .instructions = &body_instrs, .input_count = 0, .output_count = 1, .word_id = 0 },
    };

    var diag: CodegenDiagnostics = .{};
    const source = try emitProgramC(&words, &.{}, 0, 0, &.{}, .auto, false, test_aot_metadata, &diag, null, false, &.{}, testing.allocator);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "#include <stdio.h>") != null);
    try testing.expect(std.mem.indexOf(u8, source, "#include <stdlib.h>") != null);
    try testing.expect(std.mem.indexOf(u8, source, "#include <string.h>") != null);
    try testing.expect(std.mem.indexOf(u8, source, "int main(int argc, char **argv)") != null);
    // program_args excludes the program name (argv[0]), matching the interpreter.
    try testing.expect(std.mem.indexOf(u8, source, "onez_set_args(rt, argc - 1, argv + 1)") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_set_source(rt, argv[0]") != null);
    try testing.expect(std.mem.indexOf(u8, source, "getenv(\"ONEZ_INTERPRETER_FALLBACK\")") != null);
    try testing.expect(std.mem.indexOf(u8, source, "getenv(\"ONEZ_TRACE_WORDS\")") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_set_trace_words(rt, trace_env)") != null);
    try testing.expect(std.mem.indexOf(u8, source, "fprintf(stderr,") != null);
    try testing.expect(std.mem.indexOf(u8, source, "kernel_main") == null);
}

test "emitProgramC: freestanding preamble drops libc and emits kernel_main" {
    const body_instrs = makeInstructions(.{@as(i64, 1)});

    const words = [_]AotWordDesc{
        .{ .name = "main", .instructions = &body_instrs, .input_count = 0, .output_count = 1, .word_id = 0 },
    };

    var meta = test_aot_metadata;
    meta.freestanding = true;
    meta.target_triple = "riscv64-freestanding-none";

    var diag: CodegenDiagnostics = .{};
    const source = try emitProgramC(&words, &.{}, 0, 0, &.{}, .auto, false, meta, &diag, null, false, &.{}, testing.allocator);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "#include <stdio.h>") == null);
    try testing.expect(std.mem.indexOf(u8, source, "#include <stdlib.h>") == null);
    try testing.expect(std.mem.indexOf(u8, source, "#include <string.h>") == null);
    try testing.expect(std.mem.indexOf(u8, source, "int main(int argc") == null);
    // The extern forward declaration of onez_set_args is still emitted; we
    // only require that the call site (which references argc/argv) is gone.
    try testing.expect(std.mem.indexOf(u8, source, "onez_set_args(rt,") == null);
    try testing.expect(std.mem.indexOf(u8, source, "getenv(") == null);
    try testing.expect(std.mem.indexOf(u8, source, "fprintf(") == null);
    try testing.expect(std.mem.indexOf(u8, source, "int kernel_main(void)") != null);
    try testing.expect(std.mem.indexOf(u8, source, "#include <stdint.h>") != null);
    try testing.expect(std.mem.indexOf(u8, source, "#include <stdbool.h>") != null);
    try testing.expect(std.mem.indexOf(u8, source, "#include <stddef.h>") != null);
}

test "compile double: 2 *" {
    const instrs = makeInstructions(.{ @as(i64, 2), "*" });
    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{5}, &out));
    try testing.expectEqual(@as(i64, 10), out);
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{-3}, &out));
    try testing.expectEqual(@as(i64, -6), out);
}

test "compile (a+3)*4" {
    const instrs = makeInstructions(.{ @as(i64, 3), "+", @as(i64, 4), "*" });
    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{7}, &out));
    try testing.expectEqual(@as(i64, 40), out);
}

test "compile a+b with two inputs" {
    const instrs = makeInstructions(.{"+"});
    const result = try compileWord(&instrs, 2, 1, arith_test_resolver, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{ 17, 25 }, &out));
    try testing.expectEqual(@as(i64, 42), out);
}

test "compiled direct call preserves aliased lower stack values" {
    var dispatch = JitDispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const callee_instrs = makeInstructions(.{"+"});
    const callee = try compileWord(&callee_instrs, 2, 1, arith_test_resolver, null, null, null, null);
    const callee_id = try dispatch.assignId("sum2");
    dispatch.update(callee_id, callee.code_ptr, callee.jit_buf, callee.peak_stack_depth);

    const ResolverState = struct {
        callee_id: u32,
    };
    var resolver_state = ResolverState{ .callee_id = callee_id };
    const Resolver = struct {
        fn resolve(name: []const u8, user_data: *anyopaque) ?ResolvedWord {
            const state: *ResolverState = @ptrCast(@alignCast(user_data));
            if (!std.mem.eql(u8, name, "sum2")) return resolveArithOpForTest(name, user_data);
            return .{
                .word_id = state.callee_id,
                .input_count = 2,
                .output_count = 1,
            };
        }
    };
    const resolver = WordResolver{
        .resolve = &Resolver.resolve,
        .user_data = @ptrCast(&resolver_state),
        .dispatch_table_ptr = @ptrCast(&dispatch),
    };

    const caller_instrs = makeInstructions(.{ @as(i64, 1), "-", "over", "swap", "sum2", "*" });
    const caller = try compileWord(&caller_instrs, 2, 1, resolver, null, null, null, null);
    defer caller.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(caller.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{ 2, 4 }, &out));
    try testing.expectEqual(@as(i64, 10), out);
}

/// Run a compiled function against a real interpreter Context whose value
/// stack can actually relocate. Inputs must already be pushed onto ctx.stack;
/// the JitContext points at the live stack pointers so jitEnsureStackCapacity
/// reallocation during execution is observed through the same JitContext the
/// generated code reads. Returns the status and, on success, the top-of-stack
/// fixnum read back from the (possibly relocated) buffer.
fn runOnContext(func: CompiledFn, ctx: *Context, result: *i64) i32 {
    var jit_ctx = JitContext{
        .items_ptr = ctx.stack.items.items.ptr,
        .sp_ptr = &ctx.stack.items.items.len,
        .capacity = ctx.stack.items.capacity,
        .ctx = @ptrCast(ctx),
    };
    const status = func(&jit_ctx);
    const len = ctx.stack.items.items.len;
    if (status == 0 and len > 0) {
        result.* = ctx.stack.items.items[len - 1].fixnum;
    }
    return status;
}

test "relocation across a direct compiled call preserves a lower-stack alias" {
    // The `1 - over swap (callee) *` shape keeps `base` aliased at slot 0 while
    // the callee runs. Here the callee forces a real stack reallocation in its
    // prologue (jitEnsureStackCapacity), so the value buffer moves mid-call. The
    // caller must read its preserved slot-0 alias from the relocated buffer
    // after the call boundary, which only holds if the base address is
    // re-derived from the live JitContext rather than a stale cached pointer.
    var dispatch = JitDispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    // Callee: ( a b -- a+b ), but with a deep transient stack so its prologue
    // capacity check must grow (and relocate) the shared value buffer.
    const deep: usize = 30;
    var callee_ops: [2 * deep + 1]Instruction = undefined;
    for (0..deep) |i| callee_ops[i] = .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 1 };
    for (0..deep) |i| callee_ops[deep + i] = .{ .op = .{ .call_word = "drop" }, .line = 1 };
    callee_ops[2 * deep] = .{ .op = .{ .call_word = "+" }, .line = 1 };

    const callee = try compileWord(&callee_ops, 2, 1, arith_test_resolver, null, null, null, null);
    const callee_id = try dispatch.assignId("deepsum");
    dispatch.update(callee_id, callee.code_ptr, callee.jit_buf, callee.peak_stack_depth);

    const ResolverState = struct { callee_id: u32 };
    var resolver_state = ResolverState{ .callee_id = callee_id };
    const Resolver = struct {
        fn resolve(name: []const u8, user_data: *anyopaque) ?ResolvedWord {
            const state: *ResolverState = @ptrCast(@alignCast(user_data));
            if (!std.mem.eql(u8, name, "deepsum")) return resolveArithOpForTest(name, user_data);
            return .{ .word_id = state.callee_id, .input_count = 2, .output_count = 1 };
        }
    };
    const resolver = WordResolver{
        .resolve = &Resolver.resolve,
        .user_data = @ptrCast(&resolver_state),
        .dispatch_table_ptr = @ptrCast(&dispatch),
    };

    const caller_instrs = makeInstructions(.{ @as(i64, 1), "-", "over", "swap", "deepsum", "*" });
    const caller = try compileWord(&caller_instrs, 2, 1, resolver, null, null, null, null);
    defer caller.jit_buf.deinit();

    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.stack.push(.{ .fixnum = 2 });
    try ctx.stack.push(.{ .fixnum = 4 });
    // Reserve enough that the caller's own prologue does not relocate, so the
    // only relocation happens inside the deep callee's prologue.
    try ctx.stack.items.ensureTotalCapacityPrecise(ctx.allocator, 16);

    const func: CompiledFn = @ptrCast(@alignCast(caller.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), runOnContext(func, &ctx, &out));
    // 2 * (2 + (4 - 1)) = 2 * 5 = 10
    try testing.expectEqual(@as(i64, 10), out);
}

test "relocation across a recursive compiled call preserves a lower-stack alias" {
    // Non-tail recursive factorial: each frame keeps `n` aliased on its slot
    // for the trailing `*`, across a recursive dispatch call. A tight starting
    // capacity forces repeated reallocations as the recursion deepens, so every
    // frame must re-derive its base address from the live JitContext after the
    // recursive call returns.
    var dispatch = JitDispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const fact_id = try dispatch.assignId("fact");

    const ResolverState = struct { fact_id: u32 };
    var resolver_state = ResolverState{ .fact_id = fact_id };
    const Resolver = struct {
        fn resolve(name: []const u8, user_data: *anyopaque) ?ResolvedWord {
            const state: *ResolverState = @ptrCast(@alignCast(user_data));
            if (!std.mem.eql(u8, name, "fact")) return resolveArithOpForTest(name, user_data);
            return .{ .word_id = state.fact_id, .input_count = 1, .output_count = 1 };
        }
    };
    const resolver = WordResolver{
        .resolve = &Resolver.resolve,
        .user_data = @ptrCast(&resolver_state),
        .dispatch_table_ptr = @ptrCast(&dispatch),
    };

    const true_body = [_]Instruction{
        .{ .op = .{ .call_word = "dup" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
        .{ .op = .{ .call_word = "-" }, .line = 1 },
        .{ .op = .{ .call_word = "fact" }, .line = 1 },
        .{ .op = .{ .call_word = "*" }, .line = 1 },
    };
    const false_body = [_]Instruction{
        .{ .op = .{ .call_word = "drop" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
    };
    const fact_ops = [_]Instruction{
        .{ .op = .{ .call_word = "dup" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
        .{ .op = .{ .call_word = ">" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &true_body } } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &false_body } } }, .line = 1 },
        .{ .op = .{ .call_word = "if" }, .line = 1 },
    };

    const compiled = try compileWord(&fact_ops, 1, 1, resolver, null, null, null, null);
    dispatch.update(fact_id, compiled.code_ptr, compiled.jit_buf, compiled.peak_stack_depth);

    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.stack.push(.{ .fixnum = 5 });
    // Shrink to a tight capacity so the recursion must reallocate as it deepens.
    ctx.stack.items.shrinkAndFree(ctx.allocator, 1);

    const func: CompiledFn = @ptrCast(@alignCast(compiled.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), runOnContext(func, &ctx, &out));
    try testing.expectEqual(@as(i64, 120), out);
}

test "no relocation: swap arithmetic on a real context stays correct" {
    // Non-hazard regression guard: with ample capacity the stack never moves,
    // so the live-derivation change must reproduce the existing swap behavior.
    const instrs = makeInstructions(.{ "swap", "-" });
    const result = try compileWord(&instrs, 2, 1, arith_test_resolver, null, null, null, null);
    defer result.jit_buf.deinit();

    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.stack.push(.{ .fixnum = 10 });
    try ctx.stack.push(.{ .fixnum = 3 });
    try ctx.stack.items.ensureTotalCapacityPrecise(ctx.allocator, 16);

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), runOnContext(func, &ctx, &out));
    // swap [10 3] -> [3 10], then - is (a b -- a-b) -> 3 - 10 = -7
    try testing.expectEqual(@as(i64, -7), out);
}

test "overflow bails out on non-polymorphic path" {
    // When one operand is a compile-time i64 literal, the non-polymorphic
    // path is taken which still uses bail_status for overflow.
    const instrs = makeInstructions(.{ std.math.maxInt(i64), "+" });
    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 1), callCompiled(func, &.{1}, &out));
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{0}, &out));
    try testing.expectEqual(std.math.maxInt(i64), out);
}

test "overflow preserves sp on non-polymorphic path" {
    const instrs = makeInstructions(.{ std.math.maxInt(i64), "+" });
    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{.{ .fixnum = 1 }};
    var sp: usize = 1;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 1), status);
    try testing.expectEqual(@as(usize, 1), sp);
}

test "polymorphic division without a resolver is not compilable" {
    const instrs = makeInstructions(.{"/"});
    // The fallback arm covers div-by-zero and minInt/-1; without the
    // polymorphic native there is no correct continuation for it.
    try testing.expectError(IrCodegenError.NotCompilable, compileWord(&instrs, 2, 1, null, null, null, null, null));
}

test "bail on non-fixnum input" {
    const instrs = makeInstructions(.{ @as(i64, 1), "+" });
    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{.{ .string = "hello" }};
    var sp: usize = 1;
    const status = callCompiledValues(func, &values, &sp);
    // requireI64 tag check still bails (will be converted when comparisons
    // get polymorphic support).
    try testing.expectEqual(@as(i32, 1), status);
    try testing.expectEqual(@as(usize, 1), sp);
}

test "bail on stack underflow" {
    const instrs = makeInstructions(.{"+"});
    const result = try compileWord(&instrs, 2, 1, arith_test_resolver, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{.{ .fixnum = 42 }};
    var sp: usize = 1;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 1), status);
    try testing.expectEqual(@as(usize, 1), sp);
}

test "compile string literal" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .string = "hello" } }, .line = 1 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .string);
    try testing.expect(std.mem.eql(u8, "hello", values[0].string));
}

test "compile float literal" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 3.14 } }, .line = 1 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 3.14), values[0].float);
}

test "compile boolean literal" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .boolean);
    try testing.expectEqual(true, values[0].boolean);
}

test "compile symbol literal" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .symbol = "foo" } }, .line = 1 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .symbol);
    try testing.expect(std.mem.eql(u8, "foo", values[0].symbol));
}

test "compile unit literal" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .unit }, .line = 1 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .unit);
}

test "polymorphic arithmetic without a resolver is not compilable" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .string = "hello" } }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 2 },
    };
    // Two runtime-unknown operands take the polymorphic path, whose fallback
    // arm needs the native; without a resolver the body is not compilable.
    try testing.expectError(IrCodegenError.NotCompilable, compileWord(&instrs, 1, 1, null, null, null, null, null));
}

test "bail on float input to arithmetic" {
    const instrs = makeInstructions(.{ @as(i64, 1), "+" });
    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{.{ .float = 2.5 }};
    var sp: usize = 1;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 1), status);
    try testing.expectEqual(@as(usize, 1), sp);
}

test "bail on boolean input to arithmetic" {
    const instrs = makeInstructions(.{ @as(i64, 1), "+" });
    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{.{ .boolean = true }};
    var sp: usize = 1;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 1), status);
    try testing.expectEqual(@as(usize, 1), sp);
}

test "fixnum literal still works after refactor" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 42 } }, .line = 1 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 42), values[0].fixnum);
}

test "reject non-compilable: unsupported word" {
    const instrs = [_]Instruction{
        .{ .op = .{ .call_word = "print" }, .line = 1 },
    };
    try testing.expectError(IrCodegenError.NotCompilable, compileWord(&instrs, 1, 1, null, null, null, null, null));
}

test "compile with output_count 2" {
    const instrs = makeInstructions(.{ @as(i64, 10), @as(i64, 20) });
    const result = try compileWord(&instrs, 0, 2, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expectEqual(@as(i64, 10), values[0].fixnum);
    try testing.expectEqual(@as(i64, 20), values[1].fixnum);
}

test "rem with div-by-zero guard" {
    const instrs = makeInstructions(.{"rem"});
    const result = try compileWord(&instrs, 2, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{ 7, 3 }, &out));
    try testing.expectEqual(@as(i64, 1), out);
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{ -7, 3 }, &out));
    try testing.expectEqual(@as(i64, -1), out);
    try testing.expectEqual(@as(i32, 1), callCompiled(func, &.{ 7, 0 }, &out));
}

test "compile dup on fixnum" {
    const instrs = makeInstructions(.{"dup"});
    const result = try compileWord(&instrs, 1, 2, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    values[0] = .{ .fixnum = 7 };
    var sp: usize = 1;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expectEqual(@as(i64, 7), values[0].fixnum);
    try testing.expectEqual(@as(i64, 7), values[1].fixnum);
}

test "compile drop on fixnum" {
    const instrs = makeInstructions(.{"drop"});
    const result = try compileWord(&instrs, 2, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .fixnum = 10 }, .{ .fixnum = 20 } };
    var sp: usize = 2;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expectEqual(@as(i64, 10), values[0].fixnum);
}

test "compile swap on fixnums" {
    const instrs = makeInstructions(.{"swap"});
    const result = try compileWord(&instrs, 2, 2, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .fixnum = 10 }, .{ .fixnum = 20 } };
    var sp: usize = 2;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expectEqual(@as(i64, 20), values[0].fixnum);
    try testing.expectEqual(@as(i64, 10), values[1].fixnum);
}

test "compile over on fixnums" {
    const instrs = makeInstructions(.{"over"});
    const result = try compileWord(&instrs, 2, 3, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    values[0] = .{ .fixnum = 10 };
    values[1] = .{ .fixnum = 20 };
    var sp: usize = 2;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 3), sp);
    try testing.expectEqual(@as(i64, 10), values[0].fixnum);
    try testing.expectEqual(@as(i64, 20), values[1].fixnum);
    try testing.expectEqual(@as(i64, 10), values[2].fixnum);
}

test "compile t pushes true" {
    const instrs = makeInstructions(.{"t"});
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .boolean);
    try testing.expectEqual(true, values[0].boolean);
}

test "compile f pushes false" {
    const instrs = makeInstructions(.{"f"});
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .boolean);
    try testing.expectEqual(false, values[0].boolean);
}

test "compile abs on negative fixnum" {
    const instrs = makeInstructions(.{"abs"});
    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{-5}, &out));
    try testing.expectEqual(@as(i64, 5), out);
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{7}, &out));
    try testing.expectEqual(@as(i64, 7), out);
}

test "compile dup * (square)" {
    const instrs = makeInstructions(.{ "dup", "*" });
    const result = try compileWord(&instrs, 1, 1, arith_test_resolver, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{5}, &out));
    try testing.expectEqual(@as(i64, 25), out);
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{-3}, &out));
    try testing.expectEqual(@as(i64, 9), out);
}

test "compile swap - (reverse subtract)" {
    const instrs = makeInstructions(.{ "swap", "-" });
    const result = try compileWord(&instrs, 2, 1, arith_test_resolver, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{ 3, 10 }, &out));
    try testing.expectEqual(@as(i64, 7), out);
}

test "compile swap drop (nip)" {
    const instrs = makeInstructions(.{ "swap", "drop" });
    const result = try compileWord(&instrs, 2, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{ 3, 10 }, &out));
    try testing.expectEqual(@as(i64, 10), out);
}

test "compile non-fixnum literal dup" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .string = "hello" } }, .line = 1 },
        .{ .op = .{ .call_word = "dup" }, .line = 2 },
    };
    const result = try compileWord(&instrs, 0, 2, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expect(values[0] == .string);
    try testing.expect(std.mem.eql(u8, "hello", values[0].string));
    try testing.expect(values[1] == .string);
    try testing.expect(std.mem.eql(u8, "hello", values[1].string));
}

test "compile non-fixnum literal swap" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .string = "aaa" } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .string = "bbb" } }, .line = 2 },
        .{ .op = .{ .call_word = "swap" }, .line = 3 },
    };
    const result = try compileWord(&instrs, 0, 2, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expect(values[0] == .string);
    try testing.expect(std.mem.eql(u8, "bbb", values[0].string));
    try testing.expect(values[1] == .string);
    try testing.expect(std.mem.eql(u8, "aaa", values[1].string));
}

test "compile literal + input swap" {
    // ( n -- literal n )
    // literal boxed onto slot 0 must never destroy the input before the raw_at_slot copy reads it
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 1 },
        .{ .op = .{ .call_word = "swap" }, .line = 2 },
    };
    const result = try compileWord(&instrs, 1, 2, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    values[0] = .{ .fixnum = 42 };
    var sp: usize = 1;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expectEqual(@as(i64, 0), values[0].fixnum);
    try testing.expectEqual(@as(i64, 42), values[1].fixnum);
}

test "compile = comparison" {
    const instrs = makeInstructions(.{"="});
    const result = try compileWord(&instrs, 2, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;

    values[0] = .{ .fixnum = 5 };
    values[1] = .{ .fixnum = 5 };
    sp = 2;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .boolean);
    try testing.expectEqual(true, values[0].boolean);

    values[0] = .{ .fixnum = 3 };
    values[1] = .{ .fixnum = 5 };
    sp = 2;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .boolean);
    try testing.expectEqual(false, values[0].boolean);
}

test "compile < comparison" {
    const instrs = makeInstructions(.{"<"});
    const result = try compileWord(&instrs, 2, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;

    values[0] = .{ .fixnum = 3 };
    values[1] = .{ .fixnum = 5 };
    sp = 2;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expect(values[0] == .boolean);
    try testing.expectEqual(true, values[0].boolean);

    values[0] = .{ .fixnum = 5 };
    values[1] = .{ .fixnum = 3 };
    sp = 2;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expect(values[0] == .boolean);
    try testing.expectEqual(false, values[0].boolean);
}

test "compile > comparison" {
    const instrs = makeInstructions(.{">"});
    const result = try compileWord(&instrs, 2, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;

    values[0] = .{ .fixnum = 5 };
    values[1] = .{ .fixnum = 3 };
    sp = 2;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expect(values[0] == .boolean);
    try testing.expectEqual(true, values[0].boolean);

    values[0] = .{ .fixnum = 3 };
    values[1] = .{ .fixnum = 5 };
    sp = 2;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expect(values[0] == .boolean);
    try testing.expectEqual(false, values[0].boolean);
}

test "compile comparison on non-fixnum bails" {
    const instrs = makeInstructions(.{"="});
    const result = try compileWord(&instrs, 2, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .string = "hello" }, .{ .fixnum = 5 } };
    var sp: usize = 2;
    try testing.expectEqual(@as(i32, 1), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 2), sp);
}

test "compile if with bool condition" {
    const true_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 10 } }, .line = 1 },
    };
    const false_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 20 } }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 10), values[0].fixnum);
}

test "compile if with false condition" {
    const true_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 10 } }, .line = 1 },
    };
    const false_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 20 } }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .boolean = false } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 20), values[0].fixnum);
}

test "compile comparison + if" {
    const true_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 10 } }, .line = 1 },
    };
    const false_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 20 } }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .call_word = ">" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    const result = try compileWord(&instrs, 2, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;

    values[0] = .{ .fixnum = 5 };
    values[1] = .{ .fixnum = 3 };
    sp = 2;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expectEqual(@as(i64, 10), values[0].fixnum);

    values[0] = .{ .fixnum = 3 };
    values[1] = .{ .fixnum = 5 };
    sp = 2;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expectEqual(@as(i64, 20), values[0].fixnum);
}

test "compile if with arithmetic in branches" {
    const true_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 5 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 2 },
        .{ .op = .{ .call_word = "+" }, .line = 3 },
    };
    const false_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 5 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 2 },
        .{ .op = .{ .call_word = "-" }, .line = 3 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expectEqual(@as(i64, 8), values[0].fixnum);
}

test "compile if with stack shape mismatch fails" {
    const true_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 10 } }, .line = 1 },
    };
    const false_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 20 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 30 } }, .line = 2 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    try testing.expectError(IrCodegenError.StackShapeMismatch, compileWord(&instrs, 0, 1, null, null, null, null, null));
}

test "compile if with non-compilable body fails" {
    const true_body = &[_]Instruction{
        .{ .op = .{ .call_word = "print" }, .line = 1 },
    };
    const false_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 20 } }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    try testing.expectError(IrCodegenError.NotCompilable, compileWord(&instrs, 0, 1, null, null, null, null, null));
}

test "armBodyBranchlessEligible: arithmetic, comparison, and shuffle arms qualify" {
    const mul = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
        .{ .op = .{ .call_word = "*" }, .line = 1 },
    };
    const add = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    };
    const cmp = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
        .{ .op = .{ .call_word = ">" }, .line = 1 },
    };
    const shuffle = [_]Instruction{
        .{ .op = .{ .call_word = "dup" }, .line = 1 },
        .{ .op = .{ .call_word = "*" }, .line = 1 },
    };
    try testing.expect(armBodyBranchlessEligible(&mul));
    try testing.expect(armBodyBranchlessEligible(&add));
    try testing.expect(armBodyBranchlessEligible(&cmp));
    try testing.expect(armBodyBranchlessEligible(&shuffle));
    // An empty arm leaves the pre-`if` top unchanged; vacuously branchless.
    try testing.expect(armBodyBranchlessEligible(&[_]Instruction{}));
}

test "armBodyBranchlessEligible: side-effecting, trapping, control-flow, and non-scalar arms reject" {
    const side_effect = [_]Instruction{
        .{ .op = .{ .call_word = "print" }, .line = 1 },
    };
    const divide = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
        .{ .op = .{ .call_word = "/" }, .line = 1 },
    };
    const modulo = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 5 } }, .line = 1 },
        .{ .op = .{ .call_word = "%" }, .line = 1 },
    };
    const inner = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
    };
    const nested_if = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = inner } } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = inner } } }, .line = 1 },
        .{ .op = .{ .call_word = "if" }, .line = 1 },
    };
    const non_scalar_literal = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .string = "x" } }, .line = 1 },
    };
    // `nip` is trap-free but a prelude word, not an intrinsic: compiling it
    // flushes the abstract stack to physical slots, so it is excluded.
    const nip_arm = [_]Instruction{
        .{ .op = .{ .call_word = "nip" }, .line = 1 },
    };
    try testing.expect(!armBodyBranchlessEligible(&side_effect));
    try testing.expect(!armBodyBranchlessEligible(&divide));
    try testing.expect(!armBodyBranchlessEligible(&modulo));
    try testing.expect(!armBodyBranchlessEligible(&nested_if));
    try testing.expect(!armBodyBranchlessEligible(&non_scalar_literal));
    try testing.expect(!armBodyBranchlessEligible(&nip_arm));
}

test "armBodyHasShuffleOp: detects shuffle ops, ignores pure value ops" {
    const over_add = [_]Instruction{
        .{ .op = .{ .call_word = "over" }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    };
    const pure = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
        .{ .op = .{ .call_word = "*" }, .line = 1 },
    };
    try testing.expect(armBodyHasShuffleOp(&over_add));
    try testing.expect(!armBodyHasShuffleOp(&pure));
}

test "condSelectMergeKind: same-kind i64 and bool top-only pairs qualify" {
    // Shared lower stack [raw_at_slot 0]; arms differ only at the selected top.
    const base = [_]StackEntry{ .{ .raw_at_slot = 0 }, .{ .raw_at_slot = 1 } };
    const i64_true = [_]StackEntry{ .{ .raw_at_slot = 0 }, .{ .i64_ref = 10 } };
    const i64_false = [_]StackEntry{ .{ .raw_at_slot = 0 }, .{ .i64_ref = 20 } };
    try testing.expectEqual(@as(?CondSelectKind, .i64), condSelectMergeKind(&base, 2, &i64_true, 2, &i64_false, 2));

    const bool_true = [_]StackEntry{ .{ .raw_at_slot = 0 }, .{ .bool_ref = 10 } };
    const bool_false = [_]StackEntry{ .{ .raw_at_slot = 0 }, .{ .bool_ref = 20 } };
    try testing.expectEqual(@as(?CondSelectKind, .bool), condSelectMergeKind(&base, 2, &bool_true, 2, &bool_false, 2));
}

test "condSelectMergeKind: cross-type, f64, non-scalar, row, and shape mismatches fall back" {
    const base = [_]StackEntry{ .{ .raw_at_slot = 0 }, .{ .raw_at_slot = 1 } };

    // Cross-type top: i64 vs bool.
    const i64_top = [_]StackEntry{ .{ .raw_at_slot = 0 }, .{ .i64_ref = 10 } };
    const bool_top = [_]StackEntry{ .{ .raw_at_slot = 0 }, .{ .bool_ref = 20 } };
    try testing.expectEqual(@as(?CondSelectKind, null), condSelectMergeKind(&base, 2, &i64_top, 2, &bool_top, 2));

    // f64/f64 is excluded by the kind gate.
    const f64_true = [_]StackEntry{ .{ .raw_at_slot = 0 }, .{ .f64_ref = 10 } };
    const f64_false = [_]StackEntry{ .{ .raw_at_slot = 0 }, .{ .f64_ref = 20 } };
    try testing.expectEqual(@as(?CondSelectKind, null), condSelectMergeKind(&base, 2, &f64_true, 2, &f64_false, 2));

    // Non-scalar top: a raw_at_slot rather than an unboxed scalar.
    const raw_top = [_]StackEntry{ .{ .raw_at_slot = 0 }, .{ .raw_at_slot = 2 } };
    try testing.expectEqual(@as(?CondSelectKind, null), condSelectMergeKind(&base, 2, &i64_top, 2, &raw_top, 2));

    // A row in the shared lower stack disqualifies the merge.
    const row_base = [_]StackEntry{ .{ .row_region = 7 }, .{ .raw_at_slot = 1 } };
    const row_true = [_]StackEntry{ .{ .row_region = 7 }, .{ .i64_ref = 10 } };
    const row_false = [_]StackEntry{ .{ .row_region = 7 }, .{ .i64_ref = 20 } };
    try testing.expectEqual(@as(?CondSelectKind, null), condSelectMergeKind(&row_base, 2, &row_true, 2, &row_false, 2));

    // Depth mismatch: arms produce different stack heights (not top-only).
    const deep_false = [_]StackEntry{ .{ .raw_at_slot = 0 }, .{ .i64_ref = 20 }, .{ .i64_ref = 30 } };
    try testing.expectEqual(@as(?CondSelectKind, null), condSelectMergeKind(&base, 2, &i64_top, 2, &deep_false, 3));

    // Lower-stack mismatch: an arm rewrote a shared slot below the top.
    const moved_false = [_]StackEntry{ .{ .raw_at_slot = 9 }, .{ .i64_ref = 20 } };
    try testing.expectEqual(@as(?CondSelectKind, null), condSelectMergeKind(&base, 2, &i64_top, 2, &moved_false, 2));
}

test "compile float dup" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 2.5 } }, .line = 1 },
        .{ .op = .{ .call_word = "dup" }, .line = 2 },
    };
    const result = try compileWord(&instrs, 0, 2, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 2.5), values[0].float);
    try testing.expect(values[1] == .float);
    try testing.expectEqual(@as(f64, 2.5), values[1].float);
}

test "compile float swap" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 1.0 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 2.0 } }, .line = 2 },
        .{ .op = .{ .call_word = "swap" }, .line = 3 },
    };
    const result = try compileWord(&instrs, 0, 2, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 2.0), values[0].float);
    try testing.expect(values[1] == .float);
    try testing.expectEqual(@as(f64, 1.0), values[1].float);
}

test "compile float if-else merge" {
    const true_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 1.0 } }, .line = 1 },
    };
    const false_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 2.0 } }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 1.0), values[0].float);
}

// `x dup C < [ TRUE-ARM ] [ FALSE-ARM ] if`: the top-only same-type shape the
// branchless `IR_COND` merge selects on. The condition is computed from a
// duplicate of `x`, so `x` remains as the single top the arm replaces.
const cond_select_true_mul = &[_]Instruction{
    .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
    .{ .op = .{ .call_word = "*" }, .line = 1 },
};
const cond_select_false_mul = &[_]Instruction{
    .{ .op = .{ .push_literal = .{ .fixnum = 5 } }, .line = 1 },
    .{ .op = .{ .call_word = "*" }, .line = 1 },
};

test "cond-select: qualifying i64 merge selects branchlessly (false arm)" {
    // 4 dup 3 < -> false; false arm 5 * -> 20.
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 4 } }, .line = 1 },
        .{ .op = .{ .call_word = "dup" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 1 },
        .{ .op = .{ .call_word = "<" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = cond_select_true_mul } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = cond_select_false_mul } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();
    try testing.expectEqual(@as(u32, 1), result.cond_select_count);

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 20), values[0].fixnum);
}

test "cond-select: qualifying i64 merge selects branchlessly (true arm)" {
    // 2 dup 3 < -> true; true arm 2 * -> 4.
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
        .{ .op = .{ .call_word = "dup" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 1 },
        .{ .op = .{ .call_word = "<" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = cond_select_true_mul } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = cond_select_false_mul } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();
    try testing.expectEqual(@as(u32, 1), result.cond_select_count);

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 4), values[0].fixnum);
}

test "cond-select: shuffle arm over scalar operands selects branchlessly" {
    // 10 3 t [ over + ] [ over - ] if: arms read the sibling 10 and replace the
    // top; both operands are scalar i64_refs, so the shuffle stays pure. cond t
    // -> over + -> 3 + 10 = 13, leaving [ 10 13 ].
    const over_add = &[_]Instruction{
        .{ .op = .{ .call_word = "over" }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    };
    const over_sub = &[_]Instruction{
        .{ .op = .{ .call_word = "over" }, .line = 1 },
        .{ .op = .{ .call_word = "-" }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 10 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = over_add } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = over_sub } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    const result = try compileWord(&instrs, 0, 2, null, null, null, null, null);
    defer result.jit_buf.deinit();
    try testing.expectEqual(@as(u32, 1), result.cond_select_count);

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 10), values[0].fixnum);
    try testing.expect(values[1] == .fixnum);
    try testing.expectEqual(@as(i64, 13), values[1].fixnum);
}

test "cond-select: bool merge feeding a follow-on i64 merge selects both" {
    // 0 3 dup 5 < [ 2 > ] [ 8 > ] if  -> bool merge (3>2 = t)
    //            [ 1 + ] [ 0 + ] if   -> i64 merge over the accumulator 0 (t -> 0+1)
    const gt2 = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
        .{ .op = .{ .call_word = ">" }, .line = 1 },
    };
    const gt8 = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 8 } }, .line = 1 },
        .{ .op = .{ .call_word = ">" }, .line = 1 },
    };
    const inc = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    };
    const noinc = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 1 },
        .{ .op = .{ .call_word = "dup" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 5 } }, .line = 1 },
        .{ .op = .{ .call_word = "<" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = gt2 } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = gt8 } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = inc } } }, .line = 5 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = noinc } } }, .line = 6 },
        .{ .op = .{ .call_word = "if" }, .line = 7 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();
    try testing.expectEqual(@as(u32, 2), result.cond_select_count);

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 1), values[0].fixnum);
}

test "cond-select: f64 merge falls back to the boxed path" {
    // 1.0 dup 0.5 < -> false; false arm 1.5 * -> 1.5. f64 is excluded.
    const mul2 = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 2.0 } }, .line = 1 },
        .{ .op = .{ .call_word = "*" }, .line = 1 },
    };
    const mul1_5 = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 1.5 } }, .line = 1 },
        .{ .op = .{ .call_word = "*" }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 1.0 } }, .line = 1 },
        .{ .op = .{ .call_word = "dup" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 0.5 } }, .line = 1 },
        .{ .op = .{ .call_word = "<" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = mul2 } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = mul1_5 } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();
    try testing.expectEqual(@as(u32, 0), result.cond_select_count);

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 1.5), values[0].float);
}

test "cond-select: cross-type i64/bool merge falls back to the boxed path" {
    // 4 dup 3 < [ 2 * ] [ 1 > ] if: true arm yields i64, false arm yields bool.
    const arm_mul = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
        .{ .op = .{ .call_word = "*" }, .line = 1 },
    };
    const arm_gt = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
        .{ .op = .{ .call_word = ">" }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 4 } }, .line = 1 },
        .{ .op = .{ .call_word = "dup" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 1 },
        .{ .op = .{ .call_word = "<" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = arm_mul } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = arm_gt } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();
    try testing.expectEqual(@as(u32, 0), result.cond_select_count);

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    // 4 < 3 is false; false arm 4 > 1 is true.
    try testing.expect(values[0] == .boolean);
    try testing.expectEqual(true, values[0].boolean);
}

test "cond-select: trapping arm disqualifies the fast path" {
    // `/` is not an admitted branchless op, so the structural gate rejects.
    // 8 dup 3 < [ 4 / ] [ 2 / ] if -> false; false arm 8 / 2 -> 4.
    const div4 = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 4 } }, .line = 1 },
        .{ .op = .{ .call_word = "/" }, .line = 1 },
    };
    const div2 = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
        .{ .op = .{ .call_word = "/" }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 8 } }, .line = 1 },
        .{ .op = .{ .call_word = "dup" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 1 },
        .{ .op = .{ .call_word = "<" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = div4 } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = div2 } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();
    try testing.expectEqual(@as(u32, 0), result.cond_select_count);

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 4), values[0].fixnum);
}

test "compile float truthiness in if" {
    const true_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
    };
    const false_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 3.14 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 1), values[0].fixnum);
}

test "compile float addition" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 1.5 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 2.5 } }, .line = 2 },
        .{ .op = .{ .call_word = "+" }, .line = 3 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 4.0), values[0].float);
}

test "compile float subtraction" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 5.0 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 2.0 } }, .line = 2 },
        .{ .op = .{ .call_word = "-" }, .line = 3 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 3.0), values[0].float);
}

test "compile float multiplication" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 2.0 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 3.0 } }, .line = 2 },
        .{ .op = .{ .call_word = "*" }, .line = 3 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 6.0), values[0].float);
}

test "compile float division" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 7.0 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 2.0 } }, .line = 2 },
        .{ .op = .{ .call_word = "/" }, .line = 3 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 3.5), values[0].float);
}

test "compile float comparison =" {
    const instrs_eq = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 1.5 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 1.5 } }, .line = 2 },
        .{ .op = .{ .call_word = "=" }, .line = 3 },
    };
    const result_eq = try compileWord(&instrs_eq, 0, 1, null, null, null, null, null);
    defer result_eq.jit_buf.deinit();

    const func_eq: CompiledFn = @ptrCast(@alignCast(result_eq.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func_eq, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .boolean);
    try testing.expect(values[0].boolean == true);

    const instrs_ne = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 1.5 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 2.5 } }, .line = 2 },
        .{ .op = .{ .call_word = "=" }, .line = 3 },
    };
    const result_ne = try compileWord(&instrs_ne, 0, 1, null, null, null, null, null);
    defer result_ne.jit_buf.deinit();

    const func_ne: CompiledFn = @ptrCast(@alignCast(result_ne.code_ptr));
    sp = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func_ne, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .boolean);
    try testing.expect(values[0].boolean == false);
}

test "compile float comparison <" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 1.5 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 2.5 } }, .line = 2 },
        .{ .op = .{ .call_word = "<" }, .line = 3 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .boolean);
    try testing.expect(values[0].boolean == true);
}

test "compile float comparison >" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 2.5 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 1.5 } }, .line = 2 },
        .{ .op = .{ .call_word = ">" }, .line = 3 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .boolean);
    try testing.expect(values[0].boolean == true);
}

test "compile float + raw_at_slot input" {
    // Float literal inside compiled body + float input from caller.
    // resolveOperandPair sees f64_ref + raw_at_slot -> resolves both as f64.
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 1.5 } }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 2 },
    };
    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{.{ .float = 2.5 }};
    var sp: usize = 1;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 4.0), values[0].float);
}

test "div with float operand bails" {
    // div is integer-only; f64_ref operand should cause NotCompilable.
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 7.0 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 2.0 } }, .line = 2 },
        .{ .op = .{ .call_word = "div" }, .line = 3 },
    };
    try testing.expectError(IrCodegenError.NotCompilable, compileWord(&instrs, 0, 1, null, null, null, null, null));
}

test "% with float operand bails" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 7.0 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 2.0 } }, .line = 2 },
        .{ .op = .{ .call_word = "%" }, .line = 3 },
    };
    try testing.expectError(IrCodegenError.NotCompilable, compileWord(&instrs, 0, 1, null, null, null, null, null));
}

test "compile inline virtual-unwrap" {
    var vtype = VirtualType{ .name = "test-vt", .inner_type = "fixnum" };
    var tv = TypeValue{ .name = "test-vt", .descriptor = null, .virtual_type = &vtype };
    vtype.type_val = &tv;
    var inner_val = Value{ .fixnum = 42 };
    const tagged_val = Value{ .tagged = .{ .tag = &vtype, .inner = &inner_val } };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = tagged_val }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .type_val = &tv } }, .line = 2 },
        .{ .op = .{ .call_word = "native.virtual-unwrap" }, .line = 3 },
    };

    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 42), values[0].fixnum);
}

test "inline virtual-unwrap returns error_propagate on wrong vtype" {
    var vtype_a = VirtualType{ .name = "type-a", .inner_type = "fixnum" };
    var vtype_b = VirtualType{ .name = "type-b", .inner_type = "fixnum" };
    var tv_a = TypeValue{ .name = "type-a", .descriptor = null, .virtual_type = &vtype_a };
    var tv_b = TypeValue{ .name = "type-b", .descriptor = null, .virtual_type = &vtype_b };
    vtype_a.type_val = &tv_a;
    vtype_b.type_val = &tv_b;
    var inner_val = Value{ .fixnum = 99 };
    const tagged_val = Value{ .tagged = .{ .tag = &vtype_a, .inner = &inner_val } };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = tagged_val }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .type_val = &tv_b } }, .line = 2 },
        .{ .op = .{ .call_word = "native.virtual-unwrap" }, .line = 3 },
    };

    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 2), callCompiledValues(func, &values, &sp));
}

test "inline virtual-unwrap returns error_propagate on non-tagged value" {
    var vtype = VirtualType{ .name = "test-vt", .inner_type = "fixnum" };
    var tv = TypeValue{ .name = "test-vt", .descriptor = null, .virtual_type = &vtype };
    vtype.type_val = &tv;

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .type_val = &tv } }, .line = 1 },
        .{ .op = .{ .call_word = "native.virtual-unwrap" }, .line = 2 },
    };

    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .fixnum = 123 }, .unit, .unit, .unit };
    var sp: usize = 1;
    try testing.expectEqual(@as(i32, 2), callCompiledValues(func, &values, &sp));
}

test "inline virtual-unwrap on input parameter" {
    var vtype = VirtualType{ .name = "test-vt", .inner_type = "fixnum" };
    var tv = TypeValue{ .name = "test-vt", .descriptor = null, .virtual_type = &vtype };
    vtype.type_val = &tv;
    var inner_val = Value{ .fixnum = 77 };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .type_val = &tv } }, .line = 1 },
        .{ .op = .{ .call_word = "native.virtual-unwrap" }, .line = 2 },
    };

    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .tagged = .{ .tag = &vtype, .inner = &inner_val } }, .unit, .unit, .unit };
    var sp: usize = 1;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 77), values[0].fixnum);
}

test "inline virtual-unwrap then arithmetic" {
    var vtype = VirtualType{ .name = "test-vt", .inner_type = "fixnum" };
    var tv = TypeValue{ .name = "test-vt", .descriptor = null, .virtual_type = &vtype };
    vtype.type_val = &tv;
    var inner_val = Value{ .fixnum = 10 };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .type_val = &tv } }, .line = 1 },
        .{ .op = .{ .call_word = "native.virtual-unwrap" }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .fixnum = 5 } }, .line = 3 },
        .{ .op = .{ .call_word = "+" }, .line = 4 },
    };

    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .tagged = .{ .tag = &vtype, .inner = &inner_val } }, .unit, .unit, .unit };
    var sp: usize = 1;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 15), values[0].fixnum);
}

test "compile inline struct-field-get field 0" {
    var st = StructType{ .name = "point", .fields = &.{ "x", "y" } };
    var fields = [_]Value{ .{ .fixnum = 42 }, .{ .fixnum = 99 } };
    var instance = StructInstance{ .struct_type = &st, .fields = &fields };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .struct_instance = &instance } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .struct_type = &st } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 3 },
        .{ .op = .{ .call_word = "native.struct-field-get" }, .line = 4 },
    };

    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 42), values[0].fixnum);
}

test "compile inline struct-field-get field 1" {
    var st = StructType{ .name = "point", .fields = &.{ "x", "y" } };
    var fields = [_]Value{ .{ .fixnum = 42 }, .{ .fixnum = 99 } };
    var instance = StructInstance{ .struct_type = &st, .fields = &fields };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .struct_instance = &instance } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .struct_type = &st } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 3 },
        .{ .op = .{ .call_word = "native.struct-field-get" }, .line = 4 },
    };

    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 99), values[0].fixnum);
}

test "inline struct-field-get on input parameter" {
    var st = StructType{ .name = "point", .fields = &.{ "x", "y" } };
    var fields = [_]Value{ .{ .fixnum = 77 }, .{ .fixnum = 88 } };
    var instance = StructInstance{ .struct_type = &st, .fields = &fields };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .struct_type = &st } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 2 },
        .{ .op = .{ .call_word = "native.struct-field-get" }, .line = 3 },
    };

    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .struct_instance = &instance }, .unit, .unit, .unit };
    var sp: usize = 1;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 77), values[0].fixnum);
}

test "inline struct-field-get returns error_propagate on non-struct value" {
    var st = StructType{ .name = "point", .fields = &.{ "x", "y" } };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .struct_type = &st } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 2 },
        .{ .op = .{ .call_word = "native.struct-field-get" }, .line = 3 },
    };

    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .fixnum = 123 }, .unit, .unit, .unit };
    var sp: usize = 1;
    try testing.expectEqual(@as(i32, 2), callCompiledValues(func, &values, &sp));
}

test "inline struct-field-get returns error_propagate on wrong struct type" {
    var st_a = StructType{ .name = "point", .fields = &.{ "x", "y" } };
    var st_b = StructType{ .name = "color", .fields = &.{ "r", "g" } };
    var fields = [_]Value{ .{ .fixnum = 42 }, .{ .fixnum = 99 } };
    var instance = StructInstance{ .struct_type = &st_a, .fields = &fields };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .struct_type = &st_b } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 2 },
        .{ .op = .{ .call_word = "native.struct-field-get" }, .line = 3 },
    };

    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .struct_instance = &instance }, .unit, .unit, .unit };
    var sp: usize = 1;
    try testing.expectEqual(@as(i32, 2), callCompiledValues(func, &values, &sp));
}

test "compile inline struct-field-set field 0" {
    var st = StructType{ .name = "point", .fields = &.{ "x", "y" } };
    var fields = [_]Value{ .{ .fixnum = 42 }, .{ .fixnum = 99 } };
    var instance = StructInstance{ .struct_type = &st, .fields = &fields };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .struct_instance = &instance } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .struct_type = &st } }, .line = 3 },
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 4 },
        .{ .op = .{ .call_word = "native.struct-field-set" }, .line = 5 },
    };

    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .struct_instance);
    try testing.expectEqual(&instance, values[0].struct_instance);
    try testing.expect(fields[0] == .fixnum);
    try testing.expectEqual(@as(i64, 7), fields[0].fixnum);
    try testing.expectEqual(@as(i64, 99), fields[1].fixnum);
}

test "compile inline struct-field-set field 1" {
    var st = StructType{ .name = "point", .fields = &.{ "x", "y" } };
    var fields = [_]Value{ .{ .fixnum = 42 }, .{ .fixnum = 99 } };
    var instance = StructInstance{ .struct_type = &st, .fields = &fields };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .struct_instance = &instance } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 123 } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .struct_type = &st } }, .line = 3 },
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 4 },
        .{ .op = .{ .call_word = "native.struct-field-set" }, .line = 5 },
    };

    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .struct_instance);
    try testing.expectEqual(@as(i64, 42), fields[0].fixnum);
    try testing.expectEqual(@as(i64, 123), fields[1].fixnum);
}

test "emitWordCAotPass reports discovered_output as the body's final depth" {
    // The compile-to-discover effect search reads `discovered_output` to learn
    // the output count a successful compile settled on. Verify it reflects the
    // final abstract stack depth for a couple of fixed-depth intrinsic bodies.
    var compiled_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compiled_names.deinit(testing.allocator);
    var reason: ?NotCompilableReason = null;

    // [ dup ]: input 1 -> output 2
    const dup_instrs = [_]Instruction{
        .{ .op = .{ .call_word = "dup" }, .line = 1 },
    };
    const dup_res = try emitWordCAotPass(&dup_instrs, 1, 2, "q", "q", null, null, &compiled_names, null, null, null, testing.allocator, null, &.{}, null, &reason, null, null, null, null, null, null, null, false, null, false, false, false);
    if (dup_res.body) |b| testing.allocator.free(b);
    try testing.expectEqual(@as(u8, 2), dup_res.discovered_output);

    // [ drop ]: input 1 -> output 0
    const drop_instrs = [_]Instruction{
        .{ .op = .{ .call_word = "drop" }, .line = 1 },
    };
    const drop_res = try emitWordCAotPass(&drop_instrs, 1, 0, "q", "q", null, null, &compiled_names, null, null, null, testing.allocator, null, &.{}, null, &reason, null, null, null, null, null, null, null, false, null, false, false, false);
    if (drop_res.body) |b| testing.allocator.free(b);
    try testing.expectEqual(@as(u8, 0), drop_res.discovered_output);
}

test "inline struct-field-set returns error_propagate on non-struct value" {
    var st = StructType{ .name = "point", .fields = &.{ "x", "y" } };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .struct_type = &st } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 3 },
        .{ .op = .{ .call_word = "native.struct-field-set" }, .line = 4 },
    };

    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .fixnum = 123 }, .unit, .unit, .unit };
    var sp: usize = 1;
    try testing.expectEqual(@as(i32, 2), callCompiledValues(func, &values, &sp));
}

test "inline struct-field-set returns error_propagate on wrong struct type" {
    var st_a = StructType{ .name = "point", .fields = &.{ "x", "y" } };
    var st_b = StructType{ .name = "color", .fields = &.{ "r", "g" } };
    var fields = [_]Value{ .{ .fixnum = 42 }, .{ .fixnum = 99 } };
    var instance = StructInstance{ .struct_type = &st_a, .fields = &fields };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .struct_type = &st_b } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 3 },
        .{ .op = .{ .call_word = "native.struct-field-set" }, .line = 4 },
    };

    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .struct_instance = &instance }, .unit, .unit, .unit };
    var sp: usize = 1;
    try testing.expectEqual(@as(i32, 2), callCompiledValues(func, &values, &sp));
    // Fields must NOT have been mutated since we error before the store
    try testing.expectEqual(@as(i64, 42), fields[0].fixnum);
}

test "compile inline typed-validate-and-promote with fixnum" {
    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var type_params = [_]*const TypeValue{&fixnum_tv};
    var vt = VirtualType{ .name = "array(fixnum)", .inner_type = "array", .type_params = &type_params };
    var tv = TypeValue{ .name = "array(fixnum)", .descriptor = null, .virtual_type = &vt };
    vt.type_val = &tv;
    const vtype_ptr: Value = .{ .type_val = &tv };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 42 } }, .line = 1 },
        .{ .op = .{ .push_literal = vtype_ptr }, .line = 2 },
        .{ .op = .{ .call_word = "native.typed-validate-and-promote" }, .line = 3 },
    };

    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 42), values[0].fixnum);
}

test "compile inline typed-validate-and-promote with float" {
    var float_tv = TypeValue{ .name = "float", .descriptor = null };
    var type_params = [_]*const TypeValue{&float_tv};
    var vt = VirtualType{ .name = "array(float)", .inner_type = "array", .type_params = &type_params };
    var tv = TypeValue{ .name = "array(float)", .descriptor = null, .virtual_type = &vt };
    vt.type_val = &tv;
    const vtype_ptr: Value = .{ .type_val = &tv };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 3.14 } }, .line = 1 },
        .{ .op = .{ .push_literal = vtype_ptr }, .line = 2 },
        .{ .op = .{ .call_word = "native.typed-validate-and-promote" }, .line = 3 },
    };

    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 3.14), values[0].float);
}

test "inline typed-validate-and-promote returns error_propagate on type mismatch" {
    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var type_params = [_]*const TypeValue{&fixnum_tv};
    var vt = VirtualType{ .name = "array(fixnum)", .inner_type = "array", .type_params = &type_params };
    var tv = TypeValue{ .name = "array(fixnum)", .descriptor = null, .virtual_type = &vt };
    vt.type_val = &tv;
    const vtype_ptr: Value = .{ .type_val = &tv };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = vtype_ptr }, .line = 1 },
        .{ .op = .{ .call_word = "native.typed-validate-and-promote" }, .line = 2 },
    };

    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .float = 1.5 }, .unit, .unit, .unit };
    var sp: usize = 1;
    try testing.expectEqual(@as(i32, 2), callCompiledValues(func, &values, &sp));
}

test "inline typed-validate-and-promote no-op when no type_params" {
    var vt = VirtualType{ .name = "wrapper", .inner_type = "array" };
    var tv = TypeValue{ .name = "wrapper", .descriptor = null, .virtual_type = &vt };
    vt.type_val = &tv;
    const vtype_ptr: Value = .{ .type_val = &tv };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 99 } }, .line = 1 },
        .{ .op = .{ .push_literal = vtype_ptr }, .line = 2 },
        .{ .op = .{ .call_word = "native.typed-validate-and-promote" }, .line = 3 },
    };

    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 99), values[0].fixnum);
}

test "inline typed-validate-and-promote on input parameter" {
    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var type_params = [_]*const TypeValue{&fixnum_tv};
    var vt = VirtualType{ .name = "vector(fixnum)", .inner_type = "vector", .type_params = &type_params };
    var tv = TypeValue{ .name = "vector(fixnum)", .descriptor = null, .virtual_type = &vt };
    vt.type_val = &tv;
    const vtype_ptr: Value = .{ .type_val = &tv };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = vtype_ptr }, .line = 1 },
        .{ .op = .{ .call_word = "native.typed-validate-and-promote" }, .line = 2 },
    };

    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .fixnum = 55 }, .unit, .unit, .unit };
    var sp: usize = 1;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 55), values[0].fixnum);
}

test "inline typed-validate-and-promote then arithmetic" {
    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var type_params = [_]*const TypeValue{&fixnum_tv};
    var vt = VirtualType{ .name = "array(fixnum)", .inner_type = "array", .type_params = &type_params };
    var tv = TypeValue{ .name = "array(fixnum)", .descriptor = null, .virtual_type = &vt };
    vt.type_val = &tv;
    const vtype_ptr: Value = .{ .type_val = &tv };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 10 } }, .line = 1 },
        .{ .op = .{ .push_literal = vtype_ptr }, .line = 2 },
        .{ .op = .{ .call_word = "native.typed-validate-and-promote" }, .line = 3 },
        .{ .op = .{ .push_literal = .{ .fixnum = 5 } }, .line = 4 },
        .{ .op = .{ .call_word = "+" }, .line = 5 },
    };

    const result = try compileWord(&instrs, 0, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 15), values[0].fixnum);
}

// --- C emission tests ---

test "mangle simple word name" {
    const name = try mangleWordName("double", testing.allocator);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("onez_w_double", name);
}

test "mangle word name with special chars" {
    const name = try mangleWordName("#map", testing.allocator);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("onez_w__Hmap", name);
}

test "mangle word name with kebab-case" {
    const name = try mangleWordName("?or-else", testing.allocator);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("onez_w__Qor_else", name);
}

test "mangle word name with multiple specials" {
    const name = try mangleWordName("@set!", testing.allocator);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("onez_w__Aset_B", name);
}

test "mangle word name preserves digits and underscores" {
    const name = try mangleWordName("foo_bar2", testing.allocator);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("onez_w_foo_bar2", name);
}

test "emit C for double: 2 *" {
    const instrs = makeInstructions(.{ @as(i64, 2), "*" });
    const source = try emitWordC(&instrs, 1, 1, "double", testing.allocator);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.startsWith(u8, source, "#include <stdint.h>"));
    try testing.expect(std.mem.indexOf(u8, source, "onez_w_double") != null);
    try testing.expect(std.mem.indexOf(u8, source, "return") != null);
}

test "emit C for (a+3)*4" {
    const instrs = makeInstructions(.{ @as(i64, 3), "+", @as(i64, 4), "*" });
    const source = try emitWordC(&instrs, 1, 1, "compute", testing.allocator);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "onez_w_compute") != null);
}

test "emit C for push literal" {
    const instrs = makeInstructions(.{@as(i64, 42)});
    const source = try emitWordC(&instrs, 0, 1, "forty-two", testing.allocator);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "onez_w_forty_two") != null);
}

test "emitted C compiles with cc" {
    const instrs = makeInstructions(.{ @as(i64, 2), "*" });
    const source = try emitWordC(&instrs, 1, 1, "double", testing.allocator);
    defer testing.allocator.free(source);

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const c_file = try tmp_dir.dir.createFile("test.c", .{});
    try c_file.writeAll(source);
    c_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const c_path = try tmp_dir.dir.realpath("test.c", &path_buf);

    // invoke cc -fsyntax-only to verify the C source is valid
    var child = std.process.Child.init(
        &.{ "cc", "-fsyntax-only", "-Wno-incompatible-pointer-types", c_path },
        testing.allocator,
    );
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const result = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result);
}

test "emitWordCAot emits named callback for safepoint" {
    // A word with a loop needs a safepoint callback. In AOT mode, the
    // callback should appear as a named function call, not a hex address.
    const instrs = makeInstructions(.{ @as(i64, 10), "times" });
    var compiled_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compiled_names.deinit(testing.allocator);

    const source = emitWordCAot(
        &instrs,
        1,
        0,
        "repeat",
        null,
        null,
        &compiled_names,
        null,
        null,
        null,
        testing.allocator,
        null,
        &.{},
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        false,
        null,
        false,
        false,
    ) catch |err| {
        // times requires a quotation on stack which we don't have in this
        // minimal test -- NotCompilable is expected. Skip this test case
        // if the word is too complex for the minimal instruction set.
        if (err == error.NotCompilable) return;
        return err;
    };
    defer testing.allocator.free(source);

    // If compilation succeeded, verify named callback reference
    try testing.expect(std.mem.indexOf(u8, source, "jitSafepoint") != null);
    // Should NOT contain hex addresses like 0x
    try testing.expect(std.mem.indexOf(u8, source, "0x1") == null);
}

test "emitWordCAot basic arithmetic" {
    const instrs = makeInstructions(.{ @as(i64, 2), "*" });
    var compiled_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compiled_names.deinit(testing.allocator);

    const source = try emitWordCAot(
        &instrs,
        1,
        1,
        "double",
        null,
        null,
        &compiled_names,
        null,
        null,
        null,
        testing.allocator,
        null,
        &.{},
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        false,
        null,
        false,
        false,
    );
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "onez_w_double") != null);
    try testing.expect(std.mem.indexOf(u8, source, "return") != null);
    // No preamble -- caller adds it
    try testing.expect(!std.mem.startsWith(u8, source, "#include"));
}

test "emitWordCAot quotation call emits code_ptr dispatch" {
    // A word that takes a quotation parameter and calls it. The AOT codegen
    // should emit jitCallCodePtr for the hot path (compiled quotation) and
    // jitCallQuotation for the cold path (uncompiled fallback).
    const instrs = makeInstructions(.{"call"});
    var compiled_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compiled_names.deinit(testing.allocator);

    const source = emitWordCAot(
        &instrs,
        1,
        0,
        "apply",
        null,
        null,
        &compiled_names,
        null,
        null,
        null,
        testing.allocator,
        null,
        &.{},
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        false,
        null,
        false,
        false,
    ) catch |err| {
        if (err == error.NotCompilable) return;
        return err;
    };
    defer testing.allocator.free(source);

    // Hot path: compiled quotation dispatch via jitCallCodePtr
    try testing.expect(std.mem.indexOf(u8, source, "jitCallCodePtr") != null);
    // Cold path: interpreter fallback via jitCallQuotation
    try testing.expect(std.mem.indexOf(u8, source, "jitCallQuotation") != null);
}

test "emitWordCAot interpreter-free quotation call traps instead of interpreter fallback" {
    // A word that calls a runtime quotation parameter, compiled in
    // interpreter-free mode. The dispatch goes through the unified jitCallValue
    // helper, which handles both a quotation (calling its code_ptr, trapping
    // cleanly on a null one) and a closure -- there is no interpreter fallback
    // (jitCallQuotation) emitted. The parameter carries a concrete ( -- ) effect
    // so the word compiles cleanly (no trailing row), making the assertions
    // meaningful rather than skipped on NotCompilable.
    const empty_effect = StackEffect{
        .inputs = &[_]StackEffectParam{},
        .outputs = &[_]StackEffectParam{},
    };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "quot", .quotation_effect = &empty_effect },
        },
        .outputs = &[_]StackEffectParam{},
    };

    const instrs = makeInstructions(.{"call"});
    var compiled_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compiled_names.deinit(testing.allocator);

    const source = try emitWordCAot(
        &instrs,
        1,
        0,
        "apply",
        null,
        null,
        &compiled_names,
        null,
        null,
        null,
        testing.allocator,
        &effect,
        &.{},
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        false,
        null,
        true, // interpreter_free
        false,
    );
    defer testing.allocator.free(source);

    // Dispatch goes through the unified jitCallValue helper; no interpreter
    // fallback (jitCallQuotation) is emitted.
    try testing.expect(std.mem.indexOf(u8, source, "jitCallValue(") != null);
    try testing.expect(std.mem.indexOf(u8, source, "jitCallQuotation(") == null);
}

test "emitWordCAot freestanding routes non-generic natives through jitNativeWordCall" {
    // The `onez_n_*` direct wrapper symbols are exported by the hosted runtime
    // only, so a freestanding build must route every native through
    // `jitNativeWordCall`. A hosted build keeps the direct wrapper call.
    const Resolver = struct {
        fn resolve(name: []const u8, _: *anyopaque) ?ResolvedWord {
            if (std.mem.eql(u8, name, "stream-flush")) {
                return .{ .word_id = 0, .input_count = 1, .output_count = 0, .is_native = true };
            }
            return null;
        }
    };
    var dummy: u8 = 0;
    const resolver = WordResolver{
        .resolve = Resolver.resolve,
        .user_data = @ptrCast(&dummy),
        .dispatch_table_ptr = @ptrFromInt(1),
    };
    const instrs = makeInstructions(.{"stream-flush"});
    var compiled_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compiled_names.deinit(testing.allocator);

    const hosted = try emitWordCAot(
        &instrs,
        1,
        0,
        "flush-it",
        resolver,
        null,
        &compiled_names,
        null,
        null,
        null,
        testing.allocator,
        null,
        &.{},
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        false,
        null,
        false,
        false,
    );
    defer testing.allocator.free(hosted);

    try testing.expect(std.mem.indexOf(u8, hosted, "onez_n_stream_flush") != null);
    try testing.expect(std.mem.indexOf(u8, hosted, "jitNativeWordCall") == null);

    const freestanding = try emitWordCAot(
        &instrs,
        1,
        0,
        "flush-it",
        resolver,
        null,
        &compiled_names,
        null,
        null,
        null,
        testing.allocator,
        null,
        &.{},
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        false,
        null,
        false,
        true, // freestanding
    );
    defer testing.allocator.free(freestanding);

    try testing.expect(std.mem.indexOf(u8, freestanding, "onez_n_") == null);
    try testing.expect(std.mem.indexOf(u8, freestanding, "jitNativeWordCall") != null);
}

test "emitProgramC generates complete C source" {
    const double_instrs = makeInstructions(.{ @as(i64, 2), "*" });
    const add3_instrs = makeInstructions(.{ @as(i64, 3), "+" });

    const words = [_]AotWordDesc{
        .{ .name = "double", .instructions = &double_instrs, .input_count = 1, .output_count = 1, .word_id = 0 },
        .{ .name = "add3", .instructions = &add3_instrs, .input_count = 1, .output_count = 1, .word_id = 1 },
    };

    var diag: CodegenDiagnostics = .{};
    const source = try emitProgramC(&words, &.{}, 0, 1, &.{}, .auto, false, test_aot_metadata, &diag, null, false, &.{}, testing.allocator);
    defer testing.allocator.free(source);

    // Preamble
    try testing.expect(std.mem.indexOf(u8, source, "#include <stdint.h>") != null);
    try testing.expect(std.mem.indexOf(u8, source, "#include <stdbool.h>") != null);

    // Runtime externs
    try testing.expect(std.mem.indexOf(u8, source, "onez_init") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_set_args") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_runtime_run") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_print_error") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_deinit") != null);

    // Forward declarations now carry an asm-name clause so the linker symbol is the verbatim 1z word name.
    // The C identifier remains the mangled form.
    try testing.expect(std.mem.indexOf(u8, source, "int32_t onez_w_double(uintptr_t jit_ctx) asm(\"double\");") != null);
    try testing.expect(std.mem.indexOf(u8, source, "int32_t onez_w_add3(uintptr_t jit_ctx) asm(\"add3\");") != null);

    // Word bodies
    try testing.expect(std.mem.indexOf(u8, source, "onez_w_double") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_w_add3") != null);

    // Dispatch table
    try testing.expect(std.mem.indexOf(u8, source, "onez_dispatch_table") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_word_fn_t") != null);

    // Main entry point
    try testing.expect(std.mem.indexOf(u8, source, "int main(") != null);
}

test "emitProgramC omits legacy name-lookup typed-literal helpers" {
    // Every AOT compilation routes type-carrier literals through the
    // slot-table helpers (onez_push_*_slot). The legacy name-lookup
    // callbacks were deleted; their symbols must not reappear in the
    // generated C, otherwise a runtime dictionary lookup could sneak
    // back in for type identity.
    const double_instrs = makeInstructions(.{ @as(i64, 2), "*" });

    const words = [_]AotWordDesc{
        .{ .name = "double", .instructions = &double_instrs, .input_count = 1, .output_count = 1, .word_id = 0 },
    };

    var diag: CodegenDiagnostics = .{};
    const source = try emitProgramC(&words, &.{}, 0, 0, &.{}, .auto, false, test_aot_metadata, &diag, null, false, &.{}, testing.allocator);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "jitPushWordLiteral") == null);
    try testing.expect(std.mem.indexOf(u8, source, "jitPushStructType(") == null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_push_word_literal") == null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_push_struct_type(") == null);
}

test "emitProgramC dispatch table has correct entries" {
    const instrs = makeInstructions(.{@as(i64, 42)});

    const words = [_]AotWordDesc{
        .{ .name = "foo", .instructions = &instrs, .input_count = 0, .output_count = 1, .word_id = 0 },
        .{ .name = "bar", .instructions = &instrs, .input_count = 0, .output_count = 1, .word_id = 2 },
    };

    var diag2: CodegenDiagnostics = .{};
    const source = try emitProgramC(&words, &.{}, 0, 2, &.{}, .auto, false, test_aot_metadata, &diag2, null, false, &.{}, testing.allocator);
    defer testing.allocator.free(source);

    // word_id 0 -> onez_w_foo
    try testing.expect(std.mem.indexOf(u8, source, "onez_w_foo,") != null);
    // word_id 1 -> NULL (gap)
    try testing.expect(std.mem.indexOf(u8, source, "NULL,") != null);
    // word_id 2 -> onez_w_bar
    try testing.expect(std.mem.indexOf(u8, source, "onez_w_bar,") != null);
}

test "emitProgramC quotation table with all compiled entries" {
    const instrs = makeInstructions(.{@as(i64, 42)});

    const words = [_]AotWordDesc{
        .{ .name = "main", .instructions = &instrs, .input_count = 0, .output_count = 1, .word_id = 0 },
    };

    var quotations = [_]AotQuotationDesc{
        .{ .quotation_id = 0, .instructions = &instrs, .c_name = "onez_q_0", .compiled = true },
        .{ .quotation_id = 1, .instructions = &instrs, .c_name = "onez_q_1", .compiled = true },
        .{ .quotation_id = 2, .instructions = &instrs, .c_name = "onez_q_2", .compiled = true },
    };

    var diag: CodegenDiagnostics = .{};
    const source = try emitProgramC(&words, &quotations, 0, 0, &.{}, .auto, false, test_aot_metadata, &diag, null, false, &.{}, testing.allocator);
    defer testing.allocator.free(source);

    // Table exists with all entries
    try testing.expect(std.mem.indexOf(u8, source, "onez_quotation_table") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_q_0,") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_q_1,") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_q_2,") != null);

    // Registration call in main
    try testing.expect(std.mem.indexOf(u8, source, "onez_runtime_register_quotations(rt, onez_quotation_table, 3)") != null);

    // The quotation table must be registered before the dispatch table so that,
    // when a runtime image follows, container-slot quotation values decode with
    // their code_ptr already attached. register_quotations now precedes
    // register_compiled (which follows the image load).
    const q_idx = std.mem.indexOf(u8, source, "onez_runtime_register_quotations(rt,").?;
    const c_idx = std.mem.indexOf(u8, source, "onez_runtime_register_compiled(rt,").?;
    try testing.expect(q_idx < c_idx);
}

test "emitProgramC rejects uncompiled quotation bodies with inferred effects" {
    const good_instrs = makeInstructions(.{@as(i64, 42)});
    // Boolean + addition: effect inferable (1,1) but fails compilation
    // because bool_ref is not a numeric operand.
    const bad_instrs = makeInstructions(.{ "t", "+" });

    const words = [_]AotWordDesc{
        .{ .name = "main", .instructions = &good_instrs, .input_count = 0, .output_count = 1, .word_id = 0 },
    };

    var quotations = [_]AotQuotationDesc{
        .{ .quotation_id = 0, .instructions = &good_instrs, .c_name = "onez_q_0", .inferred_effect = .{ .input_count = 0, .output_count = 1 } },
        .{ .quotation_id = 1, .instructions = &bad_instrs, .c_name = "onez_q_1", .inferred_effect = .{ .input_count = 1, .output_count = 1 } },
        .{ .quotation_id = 2, .instructions = &good_instrs, .c_name = "onez_q_2", .inferred_effect = .{ .input_count = 0, .output_count = 1 } },
    };

    var diag: CodegenDiagnostics = .{};
    const result = emitProgramC(&words, &quotations, 0, 0, &.{}, .auto, false, test_aot_metadata, &diag, null, false, &.{}, testing.allocator);
    try testing.expectError(error.UncompiledQuotations, result);

    // Diagnostics report the uncompiled quotation
    try testing.expectEqual(@as(usize, 1), diag.uncompiled_quotations.len);
    try testing.expectEqualStrings("onez_q_1", diag.uncompiled_quotations[0].c_name);
    try testing.expectEqual(@as(u32, 1), diag.uncompiled_quotations[0].quotation_id);
    testing.allocator.free(diag.uncompiled_quotations);
}

test "emitProgramC applies Option C to an escaping uncompiled quotation" {
    // [ t + ] has an inferable effect (1,1) but fails compilation (t pushes a
    // boolean, not a numeric operand for +). A word that returns it escapes the
    // uncompilable quotation as a word output, so the epilogue reifies it.
    const bad_instrs = makeInstructions(.{ "t", "+" });
    const main_instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &bad_instrs } } }, .line = 1 },
    };
    const words = [_]AotWordDesc{
        .{ .name = "main", .instructions = &main_instrs, .input_count = 0, .output_count = 1, .word_id = 0 },
    };

    // Strict interpreter-free: the escaping null-code_ptr quotation has nothing to
    // run it, so the build fails with the reification diagnostic pointing at
    // --emit-runtime-image.
    {
        var quotations = [_]AotQuotationDesc{
            .{ .quotation_id = 0, .instructions = &bad_instrs, .c_name = "onez_q_0", .inferred_effect = .{ .input_count = 1, .output_count = 1 } },
        };
        var diag: CodegenDiagnostics = .{};
        const result = emitProgramC(&words, &quotations, 0, 0, &.{}, .false, true, test_aot_metadata, &diag, null, false, &.{}, testing.allocator);
        try testing.expectError(error.UncompiledQuotations, result);
        try testing.expectEqual(@as(usize, 1), diag.uncompiled_quotations.len);
        try testing.expectEqualStrings("onez_q_0", diag.uncompiled_quotations[0].c_name);
        try testing.expect(diag.uncompiled_quotations[0].reification);
        try testing.expectEqual(MethodBodyUncompilableReason.needs_runtime_image, diag.uncompiled_quotations[0].method_body_reason.?);
        testing.allocator.free(diag.uncompiled_quotations);
    }

    // Interpreter linkable (default .auto): the escaping quotation runs interpreted
    // via its self-carried body, so the build proceeds with no UncompiledQuotations.
    {
        var quotations = [_]AotQuotationDesc{
            .{ .quotation_id = 0, .instructions = &bad_instrs, .c_name = "onez_q_0", .inferred_effect = .{ .input_count = 1, .output_count = 1 } },
        };
        var diag: CodegenDiagnostics = .{};
        const source = try emitProgramC(&words, &quotations, 0, 0, &.{}, .auto, false, test_aot_metadata, &diag, null, false, &.{}, testing.allocator);
        defer testing.allocator.free(source);
        try testing.expectEqual(@as(usize, 0), diag.uncompiled_quotations.len);
    }
}

test "emitProgramC no quotation table when quotations empty" {
    const instrs = makeInstructions(.{@as(i64, 42)});

    const words = [_]AotWordDesc{
        .{ .name = "main", .instructions = &instrs, .input_count = 0, .output_count = 1, .word_id = 0 },
    };

    var diag: CodegenDiagnostics = .{};
    const source = try emitProgramC(&words, &.{}, 0, 0, &.{}, .auto, false, test_aot_metadata, &diag, null, false, &.{}, testing.allocator);
    defer testing.allocator.free(source);

    // No quotation table emitted (extern decl exists but table and call do not)
    try testing.expect(std.mem.indexOf(u8, source, "onez_quotation_table") == null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_runtime_register_quotations(rt,") == null);
}

test "emitProgramC output compiles with cc" {
    const double_instrs = makeInstructions(.{ @as(i64, 2), "*" });
    const lit_instrs = makeInstructions(.{@as(i64, 42)});

    const words = [_]AotWordDesc{
        .{ .name = "double", .instructions = &double_instrs, .input_count = 1, .output_count = 1, .word_id = 0 },
        .{ .name = "answer", .instructions = &lit_instrs, .input_count = 0, .output_count = 1, .word_id = 1 },
    };

    var diag3: CodegenDiagnostics = .{};
    const source = try emitProgramC(&words, &.{}, 1, 1, &.{}, .auto, false, test_aot_metadata, &diag3, null, false, &.{}, testing.allocator);
    defer testing.allocator.free(source);

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const c_file = try tmp_dir.dir.createFile("test_aot.c", .{});
    try c_file.writeAll(source);
    c_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const c_path = try tmp_dir.dir.realpath("test_aot.c", &path_buf);

    var child = std.process.Child.init(
        &.{ "cc", "-fsyntax-only", "-Wno-incompatible-pointer-types", c_path },
        testing.allocator,
    );
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const result = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result);
}

// =============================================================================
// QuotationSlotMap tests
// =============================================================================

const StackEffectParam = stack_effect_mod.StackEffectParam;

test "QuotationSlotMap add and findSlot" {
    var map = QuotationSlotMap{};
    try testing.expectEqual(@as(usize, 0), map.len);
    try testing.expect(map.findSlot(0) == null);

    try testing.expect(map.add(.{ .slot = 1, .input_count = 1, .output_count = 1 }));
    try testing.expect(map.add(.{ .slot = 3, .input_count = 2, .output_count = 0 }));
    try testing.expectEqual(@as(usize, 2), map.len);

    const info1 = map.findSlot(1).?;
    try testing.expectEqual(@as(usize, 1), info1.slot);
    try testing.expectEqual(@as(u8, 1), info1.input_count);
    try testing.expectEqual(@as(u8, 1), info1.output_count);

    const info3 = map.findSlot(3).?;
    try testing.expectEqual(@as(u8, 2), info3.input_count);
    try testing.expectEqual(@as(u8, 0), info3.output_count);

    try testing.expect(map.findSlot(0) == null);
    try testing.expect(map.findSlot(2) == null);
}

test "buildQuotationSlotMap with concrete effect" {
    // ( seq quot: ( a -- b ) -- seq' )
    const nested = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "a" }},
        .outputs = &[_]StackEffectParam{.{ .name = "b" }},
    };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "seq" },
            .{ .name = "quot", .quotation_effect = &nested },
        },
        .outputs = &[_]StackEffectParam{.{ .name = "seq'" }},
    };

    const map = buildQuotationSlotMap(&effect).?;
    try testing.expectEqual(@as(usize, 1), map.len);

    const info = map.findSlot(1).?;
    try testing.expectEqual(@as(usize, 1), info.slot);
    try testing.expectEqual(@as(u8, 1), info.input_count);
    try testing.expectEqual(@as(u8, 1), info.output_count);

    try testing.expect(map.findSlot(0) == null);
}

test "buildQuotationSlotMap skips row-variable effects" {
    // ( ..a quot: ( ..x -- ..y ) -- ..b )
    const nested = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "..x", .is_row_variable = true }},
        .outputs = &[_]StackEffectParam{.{ .name = "..y", .is_row_variable = true }},
    };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "quot", .quotation_effect = &nested },
        },
        .outputs = &[_]StackEffectParam{.{ .name = "..b", .is_row_variable = true }},
    };

    const map = buildQuotationSlotMap(&effect).?;
    try testing.expectEqual(@as(usize, 0), map.len);
}

test "buildQuotationSlotMap mixed concrete and row-variable" {
    // ( ..a pred: ( x -- ? ) transform: ( ..c -- ..d ) -- ..a seq )
    const concrete_effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "x" }},
        .outputs = &[_]StackEffectParam{.{ .name = "?" }},
    };
    const row_effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "..c", .is_row_variable = true }},
        .outputs = &[_]StackEffectParam{.{ .name = "..d", .is_row_variable = true }},
    };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "pred", .quotation_effect = &concrete_effect },
            .{ .name = "transform", .quotation_effect = &row_effect },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "seq" },
        },
    };

    const map = buildQuotationSlotMap(&effect).?;
    try testing.expectEqual(@as(usize, 1), map.len);

    // pred is concrete slot 0 (first non-row-variable input)
    const info = map.findSlot(0).?;
    try testing.expectEqual(@as(u8, 1), info.input_count);
    try testing.expectEqual(@as(u8, 1), info.output_count);

    // transform has row variables, not mapped
    try testing.expect(map.findSlot(1) == null);
}

test "buildQuotationSlotMap with null effect" {
    const map = buildQuotationSlotMap(null).?;
    try testing.expectEqual(@as(usize, 0), map.len);
}

test "concrete quotation effect continues compilation past call" {
    // ( x quot: ( x -- y ) -- y y )  body: call dup
    // Without concrete effect tracking, `dup` after `call` would return NotCompilable.
    const nested = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "x" }},
        .outputs = &[_]StackEffectParam{.{ .name = "y" }},
    };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "x" },
            .{ .name = "quot", .quotation_effect = &nested },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "y" },
            .{ .name = "y'" },
        },
    };
    const instrs = makeInstructions(.{ "call", "dup" });
    const result = try compileWord(&instrs, 2, 2, null, null, null, null, &effect);
    defer result.jit_buf.deinit();
}

test "call on raw slot without effect returns NotCompilable when dup touches row_region" {
    // ( x quot -- y y )  body: call dup -- no concrete effect, so call inserts
    // row_region; dup on the row_region entry returns NotCompilable.
    const instrs = makeInstructions(.{ "call", "dup" });
    try testing.expectError(IrCodegenError.NotCompilable, compileWord(&instrs, 2, 2, null, null, null, null, null));
}

test "concrete quotation effect adjusts sp for multi-output" {
    // ( x quot: ( x -- a b ) -- a b )  body: call
    // Effect is (1 in, 2 out), so sp goes from 1 to 2 after call.
    const nested = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "x" }},
        .outputs = &[_]StackEffectParam{
            .{ .name = "a" },
            .{ .name = "b" },
        },
    };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "x" },
            .{ .name = "quot", .quotation_effect = &nested },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "a" },
            .{ .name = "b" },
        },
    };
    const instrs = makeInstructions(.{"call"});
    const result = try compileWord(&instrs, 2, 2, null, null, null, null, &effect);
    defer result.jit_buf.deinit();
}

test "concrete quotation effect adjusts sp for consuming call" {
    // ( x y quot: ( a b -- ) -- )  body: call
    // Effect is (2 in, 0 out), so sp goes from 2 to 0 after call.
    const nested = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "a" },
            .{ .name = "b" },
        },
        .outputs = &[_]StackEffectParam{},
    };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "x" },
            .{ .name = "y" },
            .{ .name = "quot", .quotation_effect = &nested },
        },
        .outputs = &[_]StackEffectParam{},
    };
    const instrs = makeInstructions(.{"call"});
    const result = try compileWord(&instrs, 3, 0, null, null, null, null, &effect);
    defer result.jit_buf.deinit();
}

// ---------------------------------------------------------------------------
// inferQuotationEffect tests
// ---------------------------------------------------------------------------

test "inferQuotationEffect: empty body" {
    const instrs = makeInstructions(.{});
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff != null);
    try testing.expectEqual(@as(u8, 0), eff.?.input_count);
    try testing.expectEqual(@as(u8, 0), eff.?.output_count);
}

test "inferQuotationEffect: push literal only" {
    const instrs = makeInstructions(.{@as(i64, 42)});
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff != null);
    try testing.expectEqual(@as(u8, 0), eff.?.input_count);
    try testing.expectEqual(@as(u8, 1), eff.?.output_count);
}

test "inferQuotationEffect: 2 * (double)" {
    // [ 2 * ] expects one input (multiplied by 2) and produces one output.
    const instrs = makeInstructions(.{ @as(i64, 2), "*" });
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff != null);
    try testing.expectEqual(@as(u8, 1), eff.?.input_count);
    try testing.expectEqual(@as(u8, 1), eff.?.output_count);
}

test "inferQuotationEffect: dup *" {
    // [ dup * ] squares the top value: (1 -- 1).
    const instrs = makeInstructions(.{ "dup", "*" });
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff != null);
    try testing.expectEqual(@as(u8, 1), eff.?.input_count);
    try testing.expectEqual(@as(u8, 1), eff.?.output_count);
}

test "inferQuotationEffect: +" {
    // [ + ] takes two inputs and produces one: (2 -- 1).
    const instrs = makeInstructions(.{"+"});
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff != null);
    try testing.expectEqual(@as(u8, 2), eff.?.input_count);
    try testing.expectEqual(@as(u8, 1), eff.?.output_count);
}

test "inferQuotationEffect: drop" {
    // [ drop ] consumes one: (1 -- 0).
    const instrs = makeInstructions(.{"drop"});
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff != null);
    try testing.expectEqual(@as(u8, 1), eff.?.input_count);
    try testing.expectEqual(@as(u8, 0), eff.?.output_count);
}

test "inferQuotationEffect: .none ops defer to the resolver" {
    const indexed = makeInstructions(.{"nip-n"});
    try testing.expect((try inferQuotationEffect(&indexed, null)) == null);

    const dynamic_var = makeInstructions(.{"get"});
    try testing.expect((try inferQuotationEffect(&dynamic_var, null)) == null);
}

test "inferQuotationEffect: swap" {
    // [ swap ] rearranges two: (2 -- 2).
    const instrs = makeInstructions(.{"swap"});
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff != null);
    try testing.expectEqual(@as(u8, 2), eff.?.input_count);
    try testing.expectEqual(@as(u8, 2), eff.?.output_count);
}

test "inferQuotationEffect: over" {
    // [ over ] copies second: (2 -- 3).
    const instrs = makeInstructions(.{"over"});
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff != null);
    try testing.expectEqual(@as(u8, 2), eff.?.input_count);
    try testing.expectEqual(@as(u8, 3), eff.?.output_count);
}

test "inferQuotationEffect: t and f literals" {
    const instrs_t = makeInstructions(.{"t"});
    const eff_t = inferQuotationEffect(&instrs_t, null) catch unreachable;
    try testing.expect(eff_t != null);
    try testing.expectEqual(@as(u8, 0), eff_t.?.input_count);
    try testing.expectEqual(@as(u8, 1), eff_t.?.output_count);

    const instrs_f = makeInstructions(.{"f"});
    const eff_f = inferQuotationEffect(&instrs_f, null) catch unreachable;
    try testing.expect(eff_f != null);
    try testing.expectEqual(@as(u8, 0), eff_f.?.input_count);
    try testing.expectEqual(@as(u8, 1), eff_f.?.output_count);
}

test "inferQuotationEffect: abs" {
    // [ abs ] is (1 -- 1).
    const instrs = makeInstructions(.{"abs"});
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff != null);
    try testing.expectEqual(@as(u8, 1), eff.?.input_count);
    try testing.expectEqual(@as(u8, 1), eff.?.output_count);
}

test "inferQuotationEffect: comparison ops" {
    const instrs = makeInstructions(.{">"});
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff != null);
    try testing.expectEqual(@as(u8, 2), eff.?.input_count);
    try testing.expectEqual(@as(u8, 1), eff.?.output_count);
}

test "inferQuotationEffect: div and rem" {
    // [ div ] and [ rem ] are both ( a b -- result ): (2 -- 1).
    const div_instrs = makeInstructions(.{"div"});
    const div_eff = inferQuotationEffect(&div_instrs, null) catch unreachable;
    try testing.expect(div_eff != null);
    try testing.expectEqual(@as(u8, 2), div_eff.?.input_count);
    try testing.expectEqual(@as(u8, 1), div_eff.?.output_count);

    const rem_instrs = makeInstructions(.{"rem"});
    const rem_eff = inferQuotationEffect(&rem_instrs, null) catch unreachable;
    try testing.expect(rem_eff != null);
    try testing.expectEqual(@as(u8, 2), rem_eff.?.input_count);
    try testing.expectEqual(@as(u8, 1), rem_eff.?.output_count);
}

test "inferQuotationEffect: choose" {
    // [ choose ] is ( a1 a2 quot -- a ): (3 -- 1).
    const instrs = makeInstructions(.{"choose"});
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff != null);
    try testing.expectEqual(@as(u8, 3), eff.?.input_count);
    try testing.expectEqual(@as(u8, 1), eff.?.output_count);
}

test "inferQuotationEffect: call on literal quotation" {
    // [ [ 1 ] call ] pushes 1 onto the stack: (0 -- 1).
    // The inner quotation [ 1 ] has effect (0 -- 1).
    const inner = makeInstructions(.{@as(i64, 1)});
    const inner_val = Value{ .quotation = .{ .instructions = &inner } };
    const outer = [_]Instruction{
        .{ .op = .{ .push_literal = inner_val }, .line = 1 },
        .{ .op = .{ .call_word = "call" }, .line = 2 },
    };
    const eff = inferQuotationEffect(&outer, null) catch unreachable;
    try testing.expect(eff != null);
    try testing.expectEqual(@as(u8, 0), eff.?.input_count);
    try testing.expectEqual(@as(u8, 1), eff.?.output_count);
}

test "inferQuotationEffect: call on unknown quotation returns null" {
    // [ call ] alone: TOS is unknown, so we can't infer.
    const instrs = makeInstructions(.{"call"});
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff == null);
}

test "inferQuotationEffect: if with matching branches" {
    // [ 0 > [ 1 ] [ 0 ] if ] is (1 -- 1):
    //   consumes one value, pushes a comparison result, then if picks a branch.
    //   Both branches produce one value from zero inputs.
    const true_body = makeInstructions(.{@as(i64, 1)});
    const false_body = makeInstructions(.{@as(i64, 0)});
    const true_val = Value{ .quotation = .{ .instructions = &true_body } };
    const false_val = Value{ .quotation = .{ .instructions = &false_body } };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 1 },
        .{ .op = .{ .call_word = ">" }, .line = 2 },
        .{ .op = .{ .push_literal = true_val }, .line = 3 },
        .{ .op = .{ .push_literal = false_val }, .line = 4 },
        .{ .op = .{ .call_word = "if" }, .line = 5 },
    };
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff != null);
    try testing.expectEqual(@as(u8, 1), eff.?.input_count);
    try testing.expectEqual(@as(u8, 1), eff.?.output_count);
}

test "inferQuotationEffect: if with mismatched branches returns null" {
    // [ [ 1 ] [ 1 2 ] if ] -- branches have different deltas.
    const true_body = makeInstructions(.{@as(i64, 1)});
    const false_body = makeInstructions(.{ @as(i64, 1), @as(i64, 2) });
    const true_val = Value{ .quotation = .{ .instructions = &true_body } };
    const false_val = Value{ .quotation = .{ .instructions = &false_body } };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = true_val }, .line = 1 },
        .{ .op = .{ .push_literal = false_val }, .line = 2 },
        .{ .op = .{ .call_word = "if" }, .line = 3 },
    };
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff == null);
}

test "inferQuotationEffect: unknown word without resolver returns null" {
    const instrs = makeInstructions(.{"some-unknown-word"});
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff == null);
}

test "inferQuotationEffect: resolved word via resolver" {
    // Simulate a word "foo" with effect (1 -- 2) via a test resolver.
    const TestResolver = struct {
        fn resolve(name: []const u8, _: *anyopaque) ?ResolvedWord {
            if (std.mem.eql(u8, name, "foo")) {
                return .{ .word_id = 0, .input_count = 1, .output_count = 2 };
            }
            return null;
        }
    };
    var dummy: u8 = 0;
    const resolver = WordResolver{
        .resolve = TestResolver.resolve,
        .user_data = @ptrCast(&dummy),
        .dispatch_table_ptr = @ptrFromInt(1),
    };
    const instrs = makeInstructions(.{"foo"});
    const eff = inferQuotationEffect(&instrs, resolver) catch unreachable;
    try testing.expect(eff != null);
    try testing.expectEqual(@as(u8, 1), eff.?.input_count);
    try testing.expectEqual(@as(u8, 2), eff.?.output_count);
}

test "inferQuotationEffect: dup propagates quotation body" {
    // [ [ 1 ] dup call swap call + ] should be (0 -- 1):
    // Push quotation, dup it, call first copy (pushes 1), swap, call second (pushes 1), add.
    const inner = makeInstructions(.{@as(i64, 1)});
    const inner_val = Value{ .quotation = .{ .instructions = &inner } };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = inner_val }, .line = 1 },
        .{ .op = .{ .call_word = "dup" }, .line = 2 },
        .{ .op = .{ .call_word = "call" }, .line = 3 },
        .{ .op = .{ .call_word = "swap" }, .line = 4 },
        .{ .op = .{ .call_word = "call" }, .line = 5 },
        .{ .op = .{ .call_word = "+" }, .line = 6 },
    };
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff != null);
    try testing.expectEqual(@as(u8, 0), eff.?.input_count);
    try testing.expectEqual(@as(u8, 1), eff.?.output_count);
}

test "inferQuotationEffect: swap propagates quotation body" {
    // [ [ 1 ] 0 swap call ] should be (0 -- 2):
    // Push quotation, push 0, swap (quotation back on top), call (pushes 1).
    // The quotation body survives the swap, so call recurses into it.
    const inner = makeInstructions(.{@as(i64, 1)});
    const inner_val = Value{ .quotation = .{ .instructions = &inner } };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = inner_val }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 2 },
        .{ .op = .{ .call_word = "swap" }, .line = 3 },
        .{ .op = .{ .call_word = "call" }, .line = 4 },
    };
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff != null);
    try testing.expectEqual(@as(u8, 0), eff.?.input_count);
    try testing.expectEqual(@as(u8, 2), eff.?.output_count);
}

test "inferQuotationEffect: over propagates quotation body" {
    // [ [ 1 ] 0 over call ] should be (0 -- 3):
    // Push quotation, push 0, over (copies the quotation to the top), call.
    // over copies the second element, so the quotation body is preserved on
    // the copy and call recurses into it.
    const inner = makeInstructions(.{@as(i64, 1)});
    const inner_val = Value{ .quotation = .{ .instructions = &inner } };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = inner_val }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 2 },
        .{ .op = .{ .call_word = "over" }, .line = 3 },
        .{ .op = .{ .call_word = "call" }, .line = 4 },
    };
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff != null);
    try testing.expectEqual(@as(u8, 0), eff.?.input_count);
    try testing.expectEqual(@as(u8, 3), eff.?.output_count);
}

// ---------------------------------------------------------------------------
// resolveRowVariableEffect tests
// ---------------------------------------------------------------------------

test "resolveRowVariableEffect: simple apply with [ 1 + ]" {
    // my-apply: ( x quot: ( ..a -- ..b ) -- ..b )
    // Quotation [ 1 + ] has inferred effect (1 -- 1).
    // ..a = 1 - 0 = 1, ..b = 1 - 0 = 1
    // Specialized: inputs = x(1) + quot(1) = 2, outputs = ..b(1) = 1
    const quot_effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..b", .is_row_variable = true },
        },
    };
    const outer = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "x" },
            .{ .name = "quot", .quotation_effect = &quot_effect },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..b", .is_row_variable = true },
        },
    };

    const body = makeInstructions(.{ @as(i64, 1), "+" });
    var stack: [max_abstract_stack_depth]StackEntry = undefined;
    stack[0] = .{ .raw_at_slot = 0 }; // x
    stack[1] = .{ .quotation_body = &body }; // quot

    const result = resolveRowVariableEffect(&outer, &stack, 2, null) catch unreachable;
    try testing.expect(result != null);
    try testing.expectEqual(@as(u8, 2), result.?.input_count);
    try testing.expectEqual(@as(u8, 1), result.?.output_count);
}

test "resolveRowVariableEffect: keep with [ 2 * ]" {
    // keep: ( ..a x quot: ( ..a x -- ..b ) -- ..b x )
    // Quotation [ 2 * ] has inferred effect (1 -- 1).
    // quot declared: ( ..a x -- ..b ), concrete_in=1(x), concrete_out=0
    // ..a = 1 - 1 = 0, ..b = 1 - 0 = 1
    // Specialized: inputs = ..a(0) + x(1) + quot(1) = 2, outputs = ..b(1) + x(1) = 2
    const quot_effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "x" },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..b", .is_row_variable = true },
        },
    };
    const outer = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "x" },
            .{ .name = "quot", .quotation_effect = &quot_effect },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..b", .is_row_variable = true },
            .{ .name = "x" },
        },
    };

    const body = makeInstructions(.{ @as(i64, 2), "*" });
    var stack: [max_abstract_stack_depth]StackEntry = undefined;
    stack[0] = .{ .raw_at_slot = 0 }; // x
    stack[1] = .{ .quotation_body = &body }; // quot

    const result = resolveRowVariableEffect(&outer, &stack, 2, null) catch unreachable;
    try testing.expect(result != null);
    try testing.expectEqual(@as(u8, 2), result.?.input_count);
    try testing.expectEqual(@as(u8, 2), result.?.output_count);
}

test "resolveRowVariableEffect: keep with [ dup ]" {
    // keep: ( ..a x quot: ( ..a x -- ..b ) -- ..b x )
    // Quotation [ dup ] has inferred effect (1 -- 2).
    // ..a = 1 - 1 = 0, ..b = 2 - 0 = 2
    // Specialized: inputs = 0 + 1 + 1 = 2, outputs = 2 + 1 = 3
    const quot_effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "x" },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..b", .is_row_variable = true },
        },
    };
    const outer = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "x" },
            .{ .name = "quot", .quotation_effect = &quot_effect },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..b", .is_row_variable = true },
            .{ .name = "x" },
        },
    };

    const body = makeInstructions(.{"dup"});
    var stack: [max_abstract_stack_depth]StackEntry = undefined;
    stack[0] = .{ .raw_at_slot = 0 };
    stack[1] = .{ .quotation_body = &body };

    const result = resolveRowVariableEffect(&outer, &stack, 2, null) catch unreachable;
    try testing.expect(result != null);
    try testing.expectEqual(@as(u8, 2), result.?.input_count);
    try testing.expectEqual(@as(u8, 3), result.?.output_count);
}

test "resolveRowVariableEffect: try with a single-output quotation resolves" {
    // try: ( ..a quot: ( ..a -- x ) -- result )
    // Quotation [ 2 * ] has inferred effect (1 -- 1).
    // quot declared: ( ..a -- x ), concrete_in=0, concrete_out=1(x)
    // ..a = 1 - 0 = 1, output surplus = 1 - 1 = 0
    // Specialized: inputs = ..a(1) + quot(1) = 2, outputs = result(1)
    const quot_effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "x" },
        },
    };
    const outer = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "quot", .quotation_effect = &quot_effect },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "result" },
        },
    };

    const body = makeInstructions(.{ @as(i64, 2), "*" });
    var stack: [max_abstract_stack_depth]StackEntry = undefined;
    stack[0] = .{ .quotation_body = &body }; // quot

    const result = resolveRowVariableEffect(&outer, &stack, 1, null) catch unreachable;
    try testing.expect(result != null);
    try testing.expectEqual(@as(u8, 2), result.?.input_count);
    try testing.expectEqual(@as(u8, 1), result.?.output_count);
}

test "resolveRowVariableEffect: try with a multi-output quotation bails to null" {
    // try: ( ..a quot: ( ..a -- x ) -- result )
    // Quotation [ 1 2 ] has inferred effect (0 -- 2), one more output than the
    // declared single `x`. The output side carries no row variable to absorb
    // the surplus, so the effect cannot be soundly modeled and resolution bails
    // to null (interpreter fallback) rather than dropping the extra output.
    const quot_effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "x" },
        },
    };
    const outer = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "quot", .quotation_effect = &quot_effect },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "result" },
        },
    };

    const body = makeInstructions(.{ @as(i64, 1), @as(i64, 2) });
    var stack: [max_abstract_stack_depth]StackEntry = undefined;
    stack[0] = .{ .quotation_body = &body }; // quot

    const result = resolveRowVariableEffect(&outer, &stack, 1, null) catch unreachable;
    try testing.expect(result == null);
}

test "resolveRowVariableEffect: raw_at_slot quotation returns null" {
    const quot_effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "x" },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..b", .is_row_variable = true },
        },
    };
    const outer = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "x" },
            .{ .name = "quot", .quotation_effect = &quot_effect },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..b", .is_row_variable = true },
            .{ .name = "x" },
        },
    };

    var stack: [max_abstract_stack_depth]StackEntry = undefined;
    stack[0] = .{ .raw_at_slot = 0 };
    stack[1] = .{ .raw_at_slot = 1 }; // runtime value, not quotation_body

    const result = resolveRowVariableEffect(&outer, &stack, 2, null) catch unreachable;
    try testing.expect(result == null);
}

test "resolveRowVariableEffect: unresolvable quotation body returns null" {
    const quot_effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..b", .is_row_variable = true },
        },
    };
    const outer = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "x" },
            .{ .name = "quot", .quotation_effect = &quot_effect },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..b", .is_row_variable = true },
        },
    };

    const body = makeInstructions(.{"unknown-word"});
    var stack: [max_abstract_stack_depth]StackEntry = undefined;
    stack[0] = .{ .raw_at_slot = 0 };
    stack[1] = .{ .quotation_body = &body };

    const result = resolveRowVariableEffect(&outer, &stack, 2, null) catch unreachable;
    try testing.expect(result == null);
}

test "resolveRowVariableEffect: empty quotation [ ]" {
    // my-apply: ( x quot: ( ..a -- ..b ) -- ..b )
    // [ ] inferred (0 -- 0). ..a = 0, ..b = 0
    // Specialized: inputs = x(1) + quot(1) = 2, outputs = ..b(0) = 0
    const quot_effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..b", .is_row_variable = true },
        },
    };
    const outer = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "x" },
            .{ .name = "quot", .quotation_effect = &quot_effect },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "..b", .is_row_variable = true },
        },
    };

    const body = makeInstructions(.{});
    var stack: [max_abstract_stack_depth]StackEntry = undefined;
    stack[0] = .{ .raw_at_slot = 0 };
    stack[1] = .{ .quotation_body = &body };

    const result = resolveRowVariableEffect(&outer, &stack, 2, null) catch unreachable;
    try testing.expect(result != null);
    try testing.expectEqual(@as(u8, 2), result.?.input_count);
    try testing.expectEqual(@as(u8, 0), result.?.output_count);
}

test "resolveRowVariableEffect: concrete quotation effect skipped" {
    // If the quotation param has a concrete (non-row-variable) effect,
    // resolveRowVariableEffect skips it. No row vars in outer either.
    const quot_effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "a" },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "b" },
        },
    };
    const outer = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "x" },
            .{ .name = "quot", .quotation_effect = &quot_effect },
        },
        .outputs = &[_]StackEffectParam{
            .{ .name = "b" },
        },
    };

    var stack: [max_abstract_stack_depth]StackEntry = undefined;
    stack[0] = .{ .raw_at_slot = 0 };
    stack[1] = .{ .raw_at_slot = 1 };

    const result = resolveRowVariableEffect(&outer, &stack, 2, null) catch unreachable;
    try testing.expect(result != null);
    try testing.expectEqual(@as(u8, 2), result.?.input_count);
    try testing.expectEqual(@as(u8, 1), result.?.output_count);
}

// ---------------------------------------------------------------------------
// Overflow diagnostic tests
// ---------------------------------------------------------------------------

test "inferQuotationEffect: mini-stack overflow returns error" {
    // Push max_mini_stack_depth + 1 literals to exceed the mini-stack capacity.
    var instrs: [max_mini_stack_depth + 1]Instruction = undefined;
    for (&instrs, 0..) |*instr, i| {
        instr.* = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(i) } }, .line = @intCast(i + 1) };
    }
    try testing.expectError(error.EffectInferenceOverflow, inferQuotationEffect(&instrs, null));
}

test "inferQuotationEffect: exactly at mini-stack capacity succeeds" {
    // Push exactly max_mini_stack_depth literals -- should succeed.
    var instrs: [max_mini_stack_depth]Instruction = undefined;
    for (&instrs, 0..) |*instr, i| {
        instr.* = .{ .op = .{ .push_literal = .{ .fixnum = @intCast(i) } }, .line = @intCast(i + 1) };
    }
    const eff = inferQuotationEffect(&instrs, null) catch unreachable;
    try testing.expect(eff != null);
    try testing.expectEqual(@as(u8, 0), eff.?.input_count);
    try testing.expectEqual(@as(u8, 64), eff.?.output_count);
}

test "addOrCheckBinding: overflow returns error" {
    const names = [_][]const u8{ "..a", "..b", "..c", "..d", "..e", "..f", "..g", "..h", "..i", "..j", "..k", "..l", "..m", "..n", "..o", "..p" };
    comptime {
        if (names.len != max_row_var_bindings) @compileError("test name count must match max_row_var_bindings");
    }

    var bindings: [max_row_var_bindings]RowVarBinding = undefined;
    var num_bindings: usize = 0;

    // Fill all binding slots.
    for (names) |name| {
        const ok = try addOrCheckBinding(&bindings, &num_bindings, name, 1);
        try testing.expect(ok);
    }
    try testing.expectEqual(max_row_var_bindings, num_bindings);

    // Next binding should overflow.
    try testing.expectError(error.RowBindingOverflow, addOrCheckBinding(&bindings, &num_bindings, "..overflow", 1));
}

test "addOrCheckBinding: existing binding at capacity does not overflow" {
    var bindings: [max_row_var_bindings]RowVarBinding = undefined;
    var num_bindings: usize = 0;

    const names = [_][]const u8{ "..a", "..b", "..c", "..d", "..e", "..f", "..g", "..h", "..i", "..j", "..k", "..l", "..m", "..n", "..o", "..p" };

    // Fill all binding slots.
    for (names) |name| {
        const ok = try addOrCheckBinding(&bindings, &num_bindings, name, 1);
        try testing.expect(ok);
    }

    // Re-checking an existing binding with the same size should succeed.
    const ok = try addOrCheckBinding(&bindings, &num_bindings, "..a", 1);
    try testing.expect(ok);

    // Re-checking an existing binding with a different size should return false (conflict).
    const conflict = try addOrCheckBinding(&bindings, &num_bindings, "..a", 2);
    try testing.expect(!conflict);
}

// ---------------------------------------------------------------------------
// row_region tests
// ---------------------------------------------------------------------------

test "hasRowRegion: returns false when no row_region present" {
    var stack: [max_abstract_stack_depth]StackEntry = undefined;
    stack[0] = .{ .raw_at_slot = 0 };
    stack[1] = .{ .raw_at_slot = 1 };
    try testing.expect(!hasRowRegion(&stack, 2));
    try testing.expect(!hasRowRegion(&stack, 0));
}

test "hasRowRegion: returns true when row_region present" {
    var stack: [max_abstract_stack_depth]StackEntry = undefined;
    stack[0] = .{ .row_region = 0 };
    stack[1] = .{ .raw_at_slot = 1 };
    try testing.expect(hasRowRegion(&stack, 2));
    try testing.expect(hasRowRegion(&stack, 1));
}

test "row_region is distinct from other StackEntry variants" {
    const entry: StackEntry = .{ .row_region = 0 };
    try testing.expect(entry != .raw_at_slot);
    try testing.expect(entry != .quotation_body);
    try testing.expect(entry != .i64_ref);
    try testing.expect(entry != .f64_ref);
    try testing.expect(entry != .bool_ref);
}

test "call with no concrete effect inserts row_region and compiles" {
    // ( x quot -- )  body: call
    //
    // No stack effect annotation, so quotation_slots is empty. The call
    // inserts row_region instead of setting dynamic_call_emitted, and the
    // word compiles successfully via the row_region finalization path.
    const instrs = makeInstructions(.{"call"});
    const result = try compileWord(&instrs, 2, 0, null, null, null, null, null);
    defer result.jit_buf.deinit();
}

test "push after row_region compiles successfully" {
    // ( x quot -- )  body: call 42
    //
    // After call inserts row_region, the push_literal for 42 succeeds
    // because it operates above the opaque region.
    const instrs = makeInstructions(.{ "call", @as(i64, 42) });
    const result = try compileWord(&instrs, 2, 0, null, null, null, null, null);
    defer result.jit_buf.deinit();
}

test "row_region with row-variable quotation effect compiles" {
    // ( ..a quot: ( ..x -- ..y ) -- )  body: call
    //
    // Row-variable effect means buildQuotationSlotMap produces no entry;
    // call inserts row_region and the word compiles.
    const nested = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "..x", .is_row_variable = true }},
        .outputs = &[_]StackEffectParam{.{ .name = "..y", .is_row_variable = true }},
    };
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "..a", .is_row_variable = true },
            .{ .name = "quot", .quotation_effect = &nested },
        },
        .outputs = &[_]StackEffectParam{.{ .name = "..b", .is_row_variable = true }},
    };
    const instrs = makeInstructions(.{"call"});
    const result = try compileWord(&instrs, 1, 0, null, null, null, null, &effect);
    defer result.jit_buf.deinit();
}

test "push after row_region then drop compiles" {
    // ( x quot -- )  body: call 42 drop
    //
    // After call inserts row_region, push 42 adds above it, then drop
    // removes it. The row_region remains but sp is back to 1.
    const instrs = makeInstructions(.{ "call", @as(i64, 42), "drop" });
    const result = try compileWord(&instrs, 2, 0, null, null, null, null, null);
    defer result.jit_buf.deinit();
}

test "multiple pushes above row_region compile" {
    // ( x quot -- )  body: call 1 2 3
    //
    // Stacking values above the row_region succeeds.
    const instrs = makeInstructions(.{ "call", @as(i64, 1), @as(i64, 2), @as(i64, 3) });
    const result = try compileWord(&instrs, 2, 0, null, null, null, null, null);
    defer result.jit_buf.deinit();
}

test "dup on row_region entry returns NotCompilable" {
    // ( x quot -- )  body: call dup
    //
    // After call inserts row_region at slot 0 with sp=1, dup tries to
    // copy slot 0 (the row_region) which returns NotCompilable.
    const instrs = makeInstructions(.{ "call", "dup" });
    const result = compileWord(&instrs, 2, 0, null, null, null, null, null);
    try testing.expectError(IrCodegenError.NotCompilable, result);
}

test "with-parameter value-producing body inserts row_region and compiles" {
    // ( value param quot -- )  body: with-parameter 42
    //
    // with-parameter's body has a row-variable output, so the call collapses
    // the abstract stack to a row_region instead of abandoning compilation.
    // The trailing push then compiles above the region, where it previously
    // failed NC.5 (post_dynamic_call).
    const instrs = makeInstructions(.{ "with-parameter", @as(i64, 42) });
    const result = try compileWord(&instrs, 3, 0, null, null, null, null, null);
    defer result.jit_buf.deinit();
}

test "push above row_region after with-parameter then drop compiles" {
    // ( value param quot -- )  body: with-parameter 42 drop
    //
    // Stacking a value above the row_region the with-parameter left and then
    // dropping it back compiles.
    const instrs = makeInstructions(.{ "with-parameter", @as(i64, 42), "drop" });
    const result = try compileWord(&instrs, 3, 0, null, null, null, null, null);
    defer result.jit_buf.deinit();
}

test "dup on row_region entry left by with-parameter returns NotCompilable" {
    // ( value param quot -- )  body: with-parameter dup
    //
    // After with-parameter inserts row_region at slot 0 with sp=1, dup tries
    // to copy the row_region entry itself, which returns NotCompilable.
    const instrs = makeInstructions(.{ "with-parameter", "dup" });
    const result = compileWord(&instrs, 3, 0, null, null, null, null, null);
    try testing.expectError(IrCodegenError.NotCompilable, result);
}

test "NotCompilableReason: unknown_reason formatting" {
    const r: NotCompilableReason = .unknown_reason;
    try testing.expectEqualStrings("NC.18", r.code());
    try testing.expectEqualStrings("compilation failed without a categorized reason", r.message());
    try testing.expectEqualStrings("diagnostic gap; please report", r.hint().?);
}

test "NotCompilableReason: pre_scan_failure now has a hint" {
    const r: NotCompilableReason = .pre_scan_failure;
    try testing.expectEqualStrings("NC.11", r.code());
    try testing.expectEqualStrings(
        "blocked until the called word is in the AOT compilation set",
        r.hint().?,
    );
}

test "add above row_region compiles" {
    // ( x quot -- )  body: call 10 20 +
    // Push two known values above the row_region, then add them.
    const instrs = makeInstructions(.{ "call", @as(i64, 10), @as(i64, 20), "+" });
    const result = try compileWord(&instrs, 2, 0, null, null, null, null, null);
    defer result.jit_buf.deinit();
}

test "nextRowId returns sequential ids" {
    var state = CompileState{
        .ctx = undefined,
        .base_addr = c.IR_UNUSED,
        .tag_offset_const = c.IR_UNUSED,
        .payload_offset_const = c.IR_UNUSED,
        .fixnum_tag_const = c.IR_UNUSED,
        .float_tag_const = c.IR_UNUSED,
        .boolean_tag_const = c.IR_UNUSED,
        .tagged_tag_const = c.IR_UNUSED,
        .struct_instance_tag_const = c.IR_UNUSED,
        .bail_status = c.IR_UNUSED,
        .ok_status = c.IR_UNUSED,
        .items_ptr = c.IR_UNUSED,
        .sp_ptr = c.IR_UNUSED,
        .capacity_param = c.IR_UNUSED,
        .sp_val = c.IR_UNUSED,
        .base_idx = c.IR_UNUSED,
        .value_size_const = c.IR_UNUSED,
    };
    const id0 = state.nextRowId();
    const id1 = state.nextRowId();
    const id2 = state.nextRowId();
    try testing.expectEqual(@as(RowId, 0), id0);
    try testing.expectEqual(@as(RowId, 1), id1);
    try testing.expectEqual(@as(RowId, 2), id2);
}

test "isRowRegion: true for row_region, false for others" {
    const row: StackEntry = .{ .row_region = 0 };
    const slot: StackEntry = .{ .raw_at_slot = 0 };
    const fixnum: StackEntry = .{ .i64_ref = c.IR_UNUSED };
    try testing.expect(row.isRowRegion());
    try testing.expect(!slot.isRowRegion());
    try testing.expect(!fixnum.isRowRegion());
}

test "rowId: returns id for row_region, null for others" {
    const row: StackEntry = .{ .row_region = 42 };
    const slot: StackEntry = .{ .raw_at_slot = 0 };
    try testing.expectEqual(@as(?RowId, 42), row.rowId());
    try testing.expectEqual(@as(?RowId, null), slot.rowId());
}

test "row_region entries with different RowIds are distinguishable via rowId" {
    var stack: [max_abstract_stack_depth]StackEntry = undefined;
    stack[0] = .{ .row_region = 5 };
    stack[1] = .{ .row_region = 9 };
    try testing.expectEqual(@as(RowId, 5), stack[0].rowId().?);
    try testing.expectEqual(@as(RowId, 9), stack[1].rowId().?);
    try testing.expect(stack[0].rowId().? != stack[1].rowId().?);
}

test "symbolicShapeMatches: identical stacks match" {
    var a: [max_abstract_stack_depth]StackEntry = undefined;
    var b: [max_abstract_stack_depth]StackEntry = undefined;
    a[0] = .{ .row_region = 0 };
    a[1] = .{ .raw_at_slot = 1 };
    b[0] = .{ .row_region = 0 };
    b[1] = .{ .raw_at_slot = 1 };
    try testing.expect(symbolicShapeMatches(&a, 2, &b, 2));
}

test "symbolicShapeMatches: mismatched depths" {
    var a: [max_abstract_stack_depth]StackEntry = undefined;
    var b: [max_abstract_stack_depth]StackEntry = undefined;
    a[0] = .{ .raw_at_slot = 0 };
    b[0] = .{ .raw_at_slot = 0 };
    b[1] = .{ .raw_at_slot = 1 };
    try testing.expect(!symbolicShapeMatches(&a, 1, &b, 2));
}

test "symbolicShapeMatches: mismatched RowIds" {
    var a: [max_abstract_stack_depth]StackEntry = undefined;
    var b: [max_abstract_stack_depth]StackEntry = undefined;
    a[0] = .{ .row_region = 0 };
    a[1] = .{ .raw_at_slot = 1 };
    b[0] = .{ .row_region = 1 };
    b[1] = .{ .raw_at_slot = 1 };
    try testing.expect(!symbolicShapeMatches(&a, 2, &b, 2));
}

test "symbolicShapeMatches: row_region vs non-row at same position" {
    var a: [max_abstract_stack_depth]StackEntry = undefined;
    var b: [max_abstract_stack_depth]StackEntry = undefined;
    a[0] = .{ .row_region = 0 };
    a[1] = .{ .raw_at_slot = 1 };
    b[0] = .{ .raw_at_slot = 0 };
    b[1] = .{ .raw_at_slot = 1 };
    try testing.expect(!symbolicShapeMatches(&a, 2, &b, 2));
}

test "symbolicShapeMatches: empty stacks match" {
    var a: [max_abstract_stack_depth]StackEntry = undefined;
    var b: [max_abstract_stack_depth]StackEntry = undefined;
    try testing.expect(symbolicShapeMatches(&a, 0, &b, 0));
}

test "symbolicShapeMatches: no row regions, same depth" {
    var a: [max_abstract_stack_depth]StackEntry = undefined;
    var b: [max_abstract_stack_depth]StackEntry = undefined;
    a[0] = .{ .raw_at_slot = 0 };
    a[1] = .{ .raw_at_slot = 1 };
    b[0] = .{ .raw_at_slot = 0 };
    b[1] = .{ .raw_at_slot = 1 };
    try testing.expect(symbolicShapeMatches(&a, 2, &b, 2));
}

test "resetStackToPhysicalPreservingRows: preserves row_region" {
    var stack: [max_abstract_stack_depth]StackEntry = undefined;
    stack[0] = .{ .row_region = 7 };
    stack[1] = .{ .i64_ref = 42 };
    stack[2] = .{ .raw_at_slot = 5 };
    resetStackToPhysicalPreservingRows(&stack, 3);
    try testing.expectEqual(StackEntry{ .row_region = 7 }, stack[0]);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 1 }, stack[1]);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 2 }, stack[2]);
}

test "resetStackToPhysicalPreservingRows: no rows behaves like resetStackToPhysical" {
    var stack: [max_abstract_stack_depth]StackEntry = undefined;
    stack[0] = .{ .i64_ref = 10 };
    stack[1] = .{ .raw_at_slot = 5 };
    resetStackToPhysicalPreservingRows(&stack, 2);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 0 }, stack[0]);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 1 }, stack[1]);
}

// --- isIndexedStackOp tests ---

test "isIndexedStackOp: recognizes all four indexed stack ops" {
    try testing.expect(isIndexedStackOp("pick-n"));
    try testing.expect(isIndexedStackOp("<rot-n"));
    try testing.expect(isIndexedStackOp("rot-n>"));
    try testing.expect(isIndexedStackOp("nip-n"));
}

test "isIndexedStackOp: rejects non-indexed ops" {
    try testing.expect(!isIndexedStackOp("dup"));
    try testing.expect(!isIndexedStackOp("drop"));
    try testing.expect(!isIndexedStackOp("swap"));
    try testing.expect(!isIndexedStackOp("pick"));
    try testing.expect(!isIndexedStackOp("rot"));
}

fn preScanFlagsFor(comptime op: []const u8) !PreScanFlags {
    const instrs = makeInstructions(.{op});
    var flags = PreScanFlags{};
    try preScanInstructions(&instrs, null, &flags, false);
    return flags;
}

test "preScanInstructions: intrinsic caps drive flags" {
    // The indexed-stack reconciliation: pick-n et al. carry needs_native_call as
    // a static cap, matching the resolver-derived flag they got before 331.6.
    try testing.expect((try preScanFlagsFor("nip-n")).needs_native_call);
    try testing.expect((try preScanFlagsFor("pick-n")).needs_native_call);

    try testing.expect((try preScanFlagsFor("times")).needs_safepoint);
    try testing.expect((try preScanFlagsFor("recover")).needs_error_handling);
    try testing.expect((try preScanFlagsFor("get")).needs_dynamic_vars);
    try testing.expect((try preScanFlagsFor("+")).needs_poly_fallback);
    try testing.expect((try preScanFlagsFor("<")).needs_poly_fallback);
    try testing.expect((try preScanFlagsFor("native.make-struct-instance")).needs_dispatch);

    const map_flags = try preScanFlagsFor("#map");
    try testing.expect(map_flags.needs_iterators);
    try testing.expect(map_flags.needs_param_validation);

    // A non-dynamic iterator op sets needs_iterators but not param validation.
    const next_flags = try preScanFlagsFor("#next");
    try testing.expect(next_flags.needs_iterators);
    try testing.expect(!next_flags.needs_param_validation);
}

// --- findRowRegionIndex tests ---

test "findRowRegionIndex: returns null when no row_region present" {
    var stack: [max_abstract_stack_depth]StackEntry = undefined;
    stack[0] = .{ .raw_at_slot = 0 };
    stack[1] = .{ .i64_ref = 42 };
    try testing.expectEqual(@as(?usize, null), findRowRegionIndex(&stack, 2));
}

test "findRowRegionIndex: returns 0 when row_region at bottom" {
    var stack: [max_abstract_stack_depth]StackEntry = undefined;
    stack[0] = .{ .row_region = 0 };
    stack[1] = .{ .raw_at_slot = 1 };
    stack[2] = .{ .i64_ref = 10 };
    try testing.expectEqual(@as(?usize, 0), findRowRegionIndex(&stack, 3));
}

test "findRowRegionIndex: returns null for empty stack" {
    var stack: [max_abstract_stack_depth]StackEntry = undefined;
    try testing.expectEqual(@as(?usize, null), findRowRegionIndex(&stack, 0));
}

// --- extractPrecedingLiteralDepth tests ---

test "extractPrecedingLiteralDepth: extracts non-negative fixnum" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 1 },
        .{ .op = .{ .call_word = "nip-n" }, .line = 1 },
    };
    try testing.expectEqual(@as(?usize, 3), extractPrecedingLiteralDepth(&instrs, 1));
}

test "extractPrecedingLiteralDepth: returns null for negative fixnum" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = -1 } }, .line = 1 },
        .{ .op = .{ .call_word = "pick-n" }, .line = 1 },
    };
    try testing.expectEqual(@as(?usize, null), extractPrecedingLiteralDepth(&instrs, 1));
}

test "extractPrecedingLiteralDepth: returns null for non-fixnum literal" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 },
        .{ .op = .{ .call_word = "pick-n" }, .line = 1 },
    };
    try testing.expectEqual(@as(?usize, null), extractPrecedingLiteralDepth(&instrs, 1));
}

test "extractPrecedingLiteralDepth: returns null for call_word predecessor" {
    const instrs = [_]Instruction{
        .{ .op = .{ .call_word = "foo" }, .line = 1 },
        .{ .op = .{ .call_word = "pick-n" }, .line = 1 },
    };
    try testing.expectEqual(@as(?usize, null), extractPrecedingLiteralDepth(&instrs, 1));
}

test "extractPrecedingLiteralDepth: returns null at index 0" {
    const instrs = [_]Instruction{
        .{ .op = .{ .call_word = "pick-n" }, .line = 1 },
    };
    try testing.expectEqual(@as(?usize, null), extractPrecedingLiteralDepth(&instrs, 0));
}

test "extractPrecedingLiteralDepth: extracts zero depth" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 1 },
        .{ .op = .{ .call_word = "pick-n" }, .line = 1 },
    };
    try testing.expectEqual(@as(?usize, 0), extractPrecedingLiteralDepth(&instrs, 1));
}

// --- array-n fold tests ---

test "array-n fold: a literal count selects the fold path" {
    // `3 array-n` exposes its element span as a non-negative fixnum literal, so
    // the fold reads the count and consumes `count + 1` (elements + the count
    // literal) producing one array.
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 1 },
        .{ .op = .{ .call_word = "array-n" }, .line = 1 },
    };
    try testing.expectEqual(@as(?usize, 3), extractPrecedingLiteralDepth(&instrs, 1));
}

test "array-n fold: a runtime count falls through" {
    // A count produced by another word is not a literal, so the fold does not
    // fire and the call falls through to the row-variable handling.
    const instrs = [_]Instruction{
        .{ .op = .{ .call_word = "#len" }, .line = 1 },
        .{ .op = .{ .call_word = "array-n" }, .line = 1 },
    };
    try testing.expectEqual(@as(?usize, null), extractPrecedingLiteralDepth(&instrs, 1));
}

test "array-n fold: settling preserves a row below the packed elements" {
    // Abstract stack: [row(0), raw(1), raw(2), raw(3), count]  sp=5, count=3.
    // The fold settles with inputs = count + 1 = 4, outputs = 1. The pack
    // consumes only the entries above the row, so the row is preserved and a
    // single array slot is left on top: [row(0), array]  sp=2.
    var state = makeTestState();
    var stack = [_]StackEntry{
        .{ .row_region = 0 },
        .{ .raw_at_slot = 1 },
        .{ .raw_at_slot = 2 },
        .{ .raw_at_slot = 3 },
        .{ .i64_ref = @as(c.ir_ref, 3) },
    };
    var sp: usize = 5;
    settleRowAwareStack(&state, &stack, &sp, 4, 1);
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expectEqual(StackEntry{ .row_region = 0 }, stack[0]);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 1 }, stack[1]);
}

// --- row-underflow fallback tests ---

const RowUnderflowResolver = struct {
    fn resolve(name: []const u8, _: *anyopaque) ?ResolvedWord {
        if (std.mem.eql(u8, name, "swap")) {
            return .{ .word_id = 0, .input_count = 2, .output_count = 2, .is_native = true };
        }
        return null;
    }
};

test "row underflow: a word reaching below its declared inputs compiles in AOT mode" {
    // `( a -- b ) [ swap ]` -- swap needs two operands but the word declares one,
    // so it reaches one below the abstract base into the implicit caller row. AOT
    // codegen emits the op against the live stack and collapses to a row instead
    // of rejecting as an abstract underflow.
    var dummy: u8 = 0;
    const resolver = WordResolver{
        .resolve = RowUnderflowResolver.resolve,
        .user_data = @ptrCast(&dummy),
        .dispatch_table_ptr = @ptrFromInt(1),
    };
    const instrs = makeInstructions(.{"swap"});
    var compiled_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compiled_names.deinit(testing.allocator);

    const source = try emitWordCAot(
        &instrs,
        1,
        1,
        "reach-below",
        resolver,
        null,
        &compiled_names,
        null,
        null,
        null,
        testing.allocator,
        null,
        &.{},
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        false,
        null,
        false,
        false,
    );
    defer testing.allocator.free(source);
    // The word body compiled to a C function rather than being rejected.
    try testing.expect(std.mem.indexOf(u8, source, "onez_w_reach_below") != null);
}

test "row underflow: the same word is rejected in non-AOT (JIT) C emission" {
    // emitWordC does not set aot_mode, so reaching below the abstract base stays
    // a StackUnderflow -- JIT behavior is unchanged by the AOT-only fallback.
    const instrs = makeInstructions(.{"swap"});
    try testing.expectError(
        IrCodegenError.StackUnderflow,
        emitWordC(&instrs, 1, 1, "reach-below", testing.allocator),
    );
}

test "epilogue reifies an escaping quotation output instead of bailing" {
    // `( -- q ) [ [ 7 ] ]` returns a quotation as its output. The epilogue now
    // materializes the escaping quotation_body into a concrete runtime value via
    // onez_push_quotation rather than rejecting it as NotCompilable.
    const inner_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = inner_body } } }, .line = 1 },
    };
    var compiled_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compiled_names.deinit(testing.allocator);

    const source = try emitWordCAot(
        &instrs,
        0,
        1,
        "make-quot",
        null,
        null,
        &compiled_names,
        null,
        null,
        null,
        testing.allocator,
        null,
        &.{},
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        false,
        null,
        false,
        false,
    );
    defer testing.allocator.free(source);
    try testing.expect(std.mem.indexOf(u8, source, "onez_push_quotation") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_w_make_quot") != null);
}

test "branch merge reifies an escaping quotation arm instead of bailing" {
    // `( flag -- q ) [ [ [ 10 ] ] [ [ 20 ] ] if ]` selects a quotation [10]/[20]
    // through `if` and leaves it unconsumed: each arm pushes a quotation that
    // escapes the merge. The merge now materializes the surviving quotation_body
    // into a concrete runtime value via onez_push_quotation on both paths instead
    // of rewriting a raw_at_slot over an unwritten slot.
    const inner_10 = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 10 } }, .line = 1 },
    };
    const inner_20 = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 20 } }, .line = 1 },
    };
    const true_quot = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = inner_10 } } }, .line = 1 },
    };
    const false_quot = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = inner_20 } } }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_quot } } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_quot } } }, .line = 1 },
        .{ .op = .{ .call_word = "if" }, .line = 1 },
    };
    var compiled_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compiled_names.deinit(testing.allocator);

    const source = try emitWordCAot(
        &instrs,
        1,
        1,
        "pick-quot",
        null,
        null,
        &compiled_names,
        null,
        null,
        null,
        testing.allocator,
        null,
        &.{},
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        false,
        null,
        false,
        false,
    );
    defer testing.allocator.free(source);
    try testing.expect(std.mem.indexOf(u8, source, "onez_push_quotation") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_w_pick_quot") != null);
}

test "loop carry reifies an escaping quotation before the loop header" {
    // `( -- q ) [ [ 7 ] 3 [ ] times ]` carries the quotation [ 7 ] in the
    // loop-invariant region below the `times` args. The loop entry now reifies it
    // into a concrete runtime value via onez_push_quotation before the loop header,
    // so the carried slot is written instead of being rewritten to a stale
    // raw_at_slot.
    const inner_7 = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 1 },
    };
    const empty_body = &[_]Instruction{};
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = inner_7 } } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = empty_body } } }, .line = 1 },
        .{ .op = .{ .call_word = "times" }, .line = 1 },
    };
    var compiled_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compiled_names.deinit(testing.allocator);

    const source = try emitWordCAot(
        &instrs,
        0,
        1,
        "carry-quot",
        null,
        null,
        &compiled_names,
        null,
        null,
        null,
        testing.allocator,
        null,
        &.{},
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        false,
        null,
        false,
        false,
    );
    defer testing.allocator.free(source);
    try testing.expect(std.mem.indexOf(u8, source, "onez_push_quotation") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_w_carry_quot") != null);
}

test "self-tail-call carry reifies an escaping quotation argument" {
    // `( n q -- q ) [ over 0 > [ swap 1 - swap drop [ 42 ] acc ] [ swap drop ] if ]`
    // replaces its quotation argument with a fresh literal [ 42 ] on each recursive
    // self-tail-call, so the back-edge carries a quotation_body argument. The
    // back-edge now reifies it via onez_push_quotation before the argument copy
    // instead of copying from an unwritten slot. Uses only intrinsic ops so no
    // resolver is needed.
    const inner_42 = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 42 } }, .line = 1 },
    };
    const true_arm = &[_]Instruction{
        .{ .op = .{ .call_word = "swap" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
        .{ .op = .{ .call_word = "-" }, .line = 1 },
        .{ .op = .{ .call_word = "swap" }, .line = 1 },
        .{ .op = .{ .call_word = "drop" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = inner_42 } } }, .line = 1 },
        .{ .op = .{ .call_word = "acc" }, .line = 1 },
    };
    const false_arm = &[_]Instruction{
        .{ .op = .{ .call_word = "swap" }, .line = 1 },
        .{ .op = .{ .call_word = "drop" }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .call_word = "over" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 1 },
        .{ .op = .{ .call_word = ">" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_arm } } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_arm } } }, .line = 1 },
        .{ .op = .{ .call_word = "if" }, .line = 1 },
    };
    var compiled_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compiled_names.deinit(testing.allocator);

    const source = try emitWordCAot(
        &instrs,
        2,
        1,
        "acc",
        null,
        "acc",
        &compiled_names,
        null,
        null,
        null,
        testing.allocator,
        null,
        &.{},
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        false,
        null,
        false,
        false,
    );
    defer testing.allocator.free(source);
    try testing.expect(std.mem.indexOf(u8, source, "onez_push_quotation") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_w_acc") != null);
}

test "mergedVariableArity: concrete arms reset, opaque-row arms accumulate" {
    // Both arms concrete: equal depths reset the flag (the build-semantic-context
    // normalization), unequal depths set it.
    try testing.expect(!mergedVariableArity(true, 1, 1, false));
    try testing.expect(mergedVariableArity(false, 2, 1, false));
    // An opaque-row arm carries no trustworthy depth: a deeper-detected
    // difference survives even though both arms read sp 1, and an equal-depth
    // row pair never clobbers it back to false.
    try testing.expect(mergedVariableArity(true, 1, 1, true));
    try testing.expect(!mergedVariableArity(false, 1, 1, true));
    try testing.expect(mergedVariableArity(false, 2, 1, true));
}

test "swap over a row compiles in AOT mode with the row pinned at slot 0" {
    // `( a -- b ) [ swap 5 swap ]` -- the first swap reaches below the declared
    // input and collapses to a row; pushing the literal 5 and swapping it under
    // the row top now emits a native swap against the live stack and collapses to
    // a fresh row pinned at slot 0, rather than rejecting as an abstract reorder.
    var dummy: u8 = 0;
    const resolver = WordResolver{
        .resolve = RowUnderflowResolver.resolve,
        .user_data = @ptrCast(&dummy),
        .dispatch_table_ptr = @ptrFromInt(1),
    };
    const instrs = makeInstructions(.{ "swap", @as(i64, 5), "swap" });
    var compiled_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compiled_names.deinit(testing.allocator);

    const source = try emitWordCAot(
        &instrs,
        1,
        1,
        "swap-over-row",
        resolver,
        null,
        &compiled_names,
        null,
        null,
        null,
        testing.allocator,
        null,
        &.{},
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        false,
        null,
        false,
        false,
    );
    defer testing.allocator.free(source);
    // The word body compiled to a C function rather than being rejected.
    try testing.expect(std.mem.indexOf(u8, source, "onez_w_swap_over_row") != null);
}

/// Compile `( a b -- r ) [ + ]` in AOT mode and report how many interpreter
/// fallbacks it emitted.
///
/// Only a pair of narrowed operands reaches the concrete path, which records nothing. Any other
/// pair takes the polymorphic cold arm, so a zero count means both parameters were narrowed.
fn arithFallbackCount(
    stack_effect: ?*const StackEffect,
    inferred: []const InferredParamType,
) !u32 {
    const instrs = makeInstructions(.{"+"});
    var compiled_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compiled_names.deinit(testing.allocator);

    var count: u32 = 0;
    const source = try emitWordCAot(
        &instrs,
        2,
        1,
        "add-two",
        arith_test_resolver,
        null,
        &compiled_names,
        null,
        null,
        null,
        testing.allocator,
        stack_effect,
        inferred,
        null,
        null,
        null,
        null,
        null,
        &count,
        null,
        null,
        false,
        null,
        false,
        false,
    );
    testing.allocator.free(source);
    return count;
}

test "an inferred parameter type narrows an unannotated parameter" {
    try testing.expect(try arithFallbackCount(null, &.{}) > 0);
    try testing.expectEqual(@as(u32, 0), try arithFallbackCount(null, &.{ .fixnum, .fixnum }));
    try testing.expectEqual(@as(u32, 0), try arithFallbackCount(null, &.{ .float, .float }));

    // A slot the pass could not prove is left exactly as opaque as it is today.
    try testing.expect(try arithFallbackCount(null, &.{ .unknown, .unknown }) > 0);

    // A partly-proved word narrows nothing, so the pair stays on the polymorphic path rather
    // than taking the concrete one, whose tag check on the opaque side bails.
    try testing.expect(try arithFallbackCount(null, &.{ .fixnum, .unknown }) > 0);
    try testing.expect(try arithFallbackCount(null, &.{ .unknown, .float }) > 0);
}

test "a declared annotation takes precedence over an inferred type" {
    // The annotation is a user type rather than a builtin, and there is no
    // interpreter context to intern one against, so the annotated path narrows
    // nothing. The inferred path must still leave both parameters alone: a
    // declaration owns its parameter whether or not codegen can act on it.
    const custom = value_mod.TypeValue{ .name = "custom", .descriptor = null };
    const annotated = StackEffect{
        .inputs = &.{
            .{ .name = "a", .type_annotation = .{ .type = &custom } },
            .{ .name = "b", .type_annotation = .{ .type = &custom } },
        },
        .outputs = &.{.{ .name = "r" }},
    };
    const bare = StackEffect{
        .inputs = &.{ .{ .name = "a" }, .{ .name = "b" } },
        .outputs = &.{.{ .name = "r" }},
    };

    try testing.expect(try arithFallbackCount(&annotated, &.{ .fixnum, .fixnum }) > 0);
    try testing.expectEqual(@as(u32, 0), try arithFallbackCount(&bare, &.{ .fixnum, .fixnum }));
}

// --- rewriteIndexedStackOp tests ---

fn makeTestState() CompileState {
    return CompileState{
        .ctx = undefined,
        .base_addr = c.IR_UNUSED,
        .tag_offset_const = c.IR_UNUSED,
        .payload_offset_const = c.IR_UNUSED,
        .fixnum_tag_const = c.IR_UNUSED,
        .float_tag_const = c.IR_UNUSED,
        .boolean_tag_const = c.IR_UNUSED,
        .tagged_tag_const = c.IR_UNUSED,
        .struct_instance_tag_const = c.IR_UNUSED,
        .bail_status = c.IR_UNUSED,
        .ok_status = c.IR_UNUSED,
        .items_ptr = c.IR_UNUSED,
        .sp_ptr = c.IR_UNUSED,
        .capacity_param = c.IR_UNUSED,
        .sp_val = c.IR_UNUSED,
        .base_idx = c.IR_UNUSED,
        .value_size_const = c.IR_UNUSED,
    };
}

test "rewriteIndexedStackOp: pick-n duplicates entry at depth" {
    // Stack: [row(0), i64(10), i64(20), i64(30), i64(depth)]  sp=5, depth=2
    // Pop depth → sp=4, target = 4-1-2 = 1 → i64(10)
    // After: [row(0), i64(10), i64(20), i64(30), i64(10)]  sp=5
    var state = makeTestState();
    const ref_a = @as(c.ir_ref, 10);
    const ref_b = @as(c.ir_ref, 20);
    const ref_c = @as(c.ir_ref, 30);
    const ref_depth = @as(c.ir_ref, 2);

    var stack = [_]StackEntry{
        .{ .row_region = 0 },
        .{ .i64_ref = ref_a },
        .{ .i64_ref = ref_b },
        .{ .i64_ref = ref_c },
        .{ .i64_ref = ref_depth },
        undefined, // space for cloned entry
    };

    var sp: usize = 5;
    try rewriteIndexedStackOp(&state, .pick_n, &stack, &sp, 2);
    try testing.expectEqual(@as(usize, 5), sp);
    try testing.expectEqual(StackEntry{ .row_region = 0 }, stack[0]);
    try testing.expectEqual(StackEntry{ .i64_ref = ref_a }, stack[1]);
    try testing.expectEqual(StackEntry{ .i64_ref = ref_b }, stack[2]);
    try testing.expectEqual(StackEntry{ .i64_ref = ref_c }, stack[3]);
    try testing.expectEqual(StackEntry{ .i64_ref = ref_a }, stack[4]);
}

test "rewriteIndexedStackOp: pick-n depth 0 duplicates top" {
    // Stack: [row(0), i64(10), i64(depth)]  sp=3, depth=0
    // Pop depth → sp=2, target = 2-1-0 = 1 → i64(10)
    // After: [row(0), i64(10), i64(10)]  sp=3
    var state = makeTestState();
    const ref_a = @as(c.ir_ref, 10);
    const ref_depth = @as(c.ir_ref, 0);

    var stack = [_]StackEntry{
        .{ .row_region = 0 },
        .{ .i64_ref = ref_a },
        .{ .i64_ref = ref_depth },
        undefined,
    };

    var sp: usize = 3;
    try rewriteIndexedStackOp(&state, .pick_n, &stack, &sp, 0);
    try testing.expectEqual(@as(usize, 3), sp);
    try testing.expectEqual(StackEntry{ .i64_ref = ref_a }, stack[1]);
    try testing.expectEqual(StackEntry{ .i64_ref = ref_a }, stack[2]);
}

test "rewriteIndexedStackOp: <rot-n pulls entry to top" {
    // Stack: [row(0), raw(1), raw(2), raw(3), i64(depth)]  sp=5, depth=2
    // Pop depth → sp=4, target = 4-1-2 = 1 → raw(1)
    // After: [row(0), raw(2), raw(3), raw(1)]  sp=4
    var state = makeTestState();
    var stack = [_]StackEntry{
        .{ .row_region = 0 },
        .{ .raw_at_slot = 1 },
        .{ .raw_at_slot = 2 },
        .{ .raw_at_slot = 3 },
        .{ .i64_ref = @as(c.ir_ref, 2) },
    };

    var sp: usize = 5;
    try rewriteIndexedStackOp(&state, .rot_up, &stack, &sp, 2);
    try testing.expectEqual(@as(usize, 4), sp);
    try testing.expectEqual(StackEntry{ .row_region = 0 }, stack[0]);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 2 }, stack[1]);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 3 }, stack[2]);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 1 }, stack[3]);
}

test "rewriteIndexedStackOp: <rot-n depth 0 is no-op" {
    // Stack: [row(0), raw(1), raw(2), i64(depth)]  sp=4, depth=0
    // Pop depth → sp=3, no rearrangement
    var state = makeTestState();
    var stack = [_]StackEntry{
        .{ .row_region = 0 },
        .{ .raw_at_slot = 1 },
        .{ .raw_at_slot = 2 },
        .{ .i64_ref = @as(c.ir_ref, 0) },
    };

    var sp: usize = 4;
    try rewriteIndexedStackOp(&state, .rot_up, &stack, &sp, 0);
    try testing.expectEqual(@as(usize, 3), sp);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 1 }, stack[1]);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 2 }, stack[2]);
}

test "rewriteIndexedStackOp: rot-n> pushes top to depth" {
    // Stack: [row(0), raw(1), raw(2), raw(3), i64(depth)]  sp=5, depth=2
    // Pop depth → sp=4, target = 4-1-2 = 1
    // saved = stack[3] = raw(3), shift up, stack[1] = raw(3)
    // After: [row(0), raw(3), raw(1), raw(2)]  sp=4
    var state = makeTestState();
    var stack = [_]StackEntry{
        .{ .row_region = 0 },
        .{ .raw_at_slot = 1 },
        .{ .raw_at_slot = 2 },
        .{ .raw_at_slot = 3 },
        .{ .i64_ref = @as(c.ir_ref, 2) },
    };

    var sp: usize = 5;
    try rewriteIndexedStackOp(&state, .rot_down, &stack, &sp, 2);
    try testing.expectEqual(@as(usize, 4), sp);
    try testing.expectEqual(StackEntry{ .row_region = 0 }, stack[0]);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 3 }, stack[1]);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 1 }, stack[2]);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 2 }, stack[3]);
}

test "rewriteIndexedStackOp: rot-n> depth 0 is no-op" {
    // Stack: [row(0), raw(1), i64(depth)]  sp=3, depth=0
    // Pop depth → sp=2
    var state = makeTestState();
    var stack = [_]StackEntry{
        .{ .row_region = 0 },
        .{ .raw_at_slot = 1 },
        .{ .i64_ref = @as(c.ir_ref, 0) },
    };

    var sp: usize = 3;
    try rewriteIndexedStackOp(&state, .rot_down, &stack, &sp, 0);
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 1 }, stack[1]);
}

test "rewriteIndexedStackOp: nip-n keeps top and drops depth entries" {
    // Stack: [row(0), raw(1), raw(2), raw(3), i64(depth)]  sp=5, depth=2
    // Pop depth → sp=4, top = stack[3] = raw(3), sp -= 2 → sp=2
    // stack[1] = raw(3)
    // After: [row(0), raw(3)]  sp=2
    var state = makeTestState();
    var stack = [_]StackEntry{
        .{ .row_region = 0 },
        .{ .raw_at_slot = 1 },
        .{ .raw_at_slot = 2 },
        .{ .raw_at_slot = 3 },
        .{ .i64_ref = @as(c.ir_ref, 2) },
    };

    var sp: usize = 5;
    try rewriteIndexedStackOp(&state, .nip_n, &stack, &sp, 2);
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expectEqual(StackEntry{ .row_region = 0 }, stack[0]);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 3 }, stack[1]);
}

test "rewriteIndexedStackOp: nip-n depth 0 is no-op" {
    // Stack: [row(0), raw(1), i64(depth)]  sp=3, depth=0
    // Pop depth → sp=2
    var state = makeTestState();
    var stack = [_]StackEntry{
        .{ .row_region = 0 },
        .{ .raw_at_slot = 1 },
        .{ .i64_ref = @as(c.ir_ref, 0) },
    };

    var sp: usize = 3;
    try rewriteIndexedStackOp(&state, .nip_n, &stack, &sp, 0);
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 1 }, stack[1]);
}

test "rewriteIndexedStackOp: <rot-n depth 1 acts like swap" {
    // Stack: [row(0), raw(1), raw(2), i64(depth)]  sp=4, depth=1
    // Pop depth → sp=3, target = 3-1-1 = 1 → raw(1)
    // After: [row(0), raw(2), raw(1)]  sp=3
    var state = makeTestState();
    var stack = [_]StackEntry{
        .{ .row_region = 0 },
        .{ .raw_at_slot = 1 },
        .{ .raw_at_slot = 2 },
        .{ .i64_ref = @as(c.ir_ref, 1) },
    };

    var sp: usize = 4;
    try rewriteIndexedStackOp(&state, .rot_up, &stack, &sp, 1);
    try testing.expectEqual(@as(usize, 3), sp);
    try testing.expectEqual(StackEntry{ .row_region = 0 }, stack[0]);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 2 }, stack[1]);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 1 }, stack[2]);
}

test "rewriteIndexedStackOp: nip-n depth 1 preserves row_region" {
    // Stack: [row(0), raw(1), raw(2), raw(3), i64(depth)]  sp=5, depth=1
    // Pop depth → sp=4, top = stack[3] = raw(3), sp -= 1 → sp=3
    // stack[2] = raw(3)
    // After: [row(0), raw(1), raw(3)]  sp=3
    var state = makeTestState();
    var stack = [_]StackEntry{
        .{ .row_region = 0 },
        .{ .raw_at_slot = 1 },
        .{ .raw_at_slot = 2 },
        .{ .raw_at_slot = 3 },
        .{ .i64_ref = @as(c.ir_ref, 1) },
    };

    var sp: usize = 5;
    try rewriteIndexedStackOp(&state, .nip_n, &stack, &sp, 1);
    try testing.expectEqual(@as(usize, 3), sp);
    try testing.expectEqual(StackEntry{ .row_region = 0 }, stack[0]);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 1 }, stack[1]);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 3 }, stack[2]);
}

test "emitAotMetadata renders runtime-image fields when present" {
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    var meta = test_aot_metadata;
    meta.runtime_image_present = true;
    meta.runtime_image_format_version = 2;
    meta.runtime_image_blob_present = true;
    meta.runtime_image_word_count = 42;
    meta.runtime_image_dispatch_entry_slot_count = 3;

    try emitAotMetadata(testing.allocator, &out, meta, true, classifyArtifact(true, .full_runtime));

    try testing.expect(std.mem.indexOf(u8, out.items, "runtime-image-present=yes\\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "runtime-image-format-version=2\\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "runtime-image-blob-present=yes\\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "runtime-image-word-count=42\\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "runtime-image-dispatch-entry-count=3\\n") != null);
}

test "emitAotMetadata omits runtime-image conditional fields when absent" {
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    // test_aot_metadata.runtime_image_present is false by default; the
    // three conditional keys must not appear at all so the inspector
    // can keep them as nullable optional fields.
    try emitAotMetadata(testing.allocator, &out, test_aot_metadata, true, classifyArtifact(true, .none));

    try testing.expect(std.mem.indexOf(u8, out.items, "runtime-image-present=no\\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "runtime-image-format-version=") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "runtime-image-blob-present=") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "runtime-image-word-count=") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "runtime-image-dispatch-entry-count=") == null);
}

test "emitAotMetadata renders blob-present=no with non-zero word-count" {
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    var meta = test_aot_metadata;
    meta.runtime_image_present = true;
    meta.runtime_image_format_version = 2;
    meta.runtime_image_blob_present = false;
    meta.runtime_image_word_count = 7;

    try emitAotMetadata(testing.allocator, &out, meta, true, classifyArtifact(true, .full_runtime));

    try testing.expect(std.mem.indexOf(u8, out.items, "runtime-image-present=yes\\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "runtime-image-blob-present=no\\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "runtime-image-word-count=7\\n") != null);
}

test "emitAotMetadata bumps schema version and emits artifact-class" {
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    try emitAotMetadata(testing.allocator, &out, test_aot_metadata, false, .interpreter_free_aot);

    try testing.expect(std.mem.indexOf(u8, out.items, "schema-version=3\\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "artifact-class=interpreter-free-aot\\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "metadata-image-present=no\\n") != null);
}

test "emitAotMetadata renders metadata-image-present=yes for interpreter-free image" {
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);

    var meta = test_aot_metadata;
    meta.metadata_image_present = true;
    meta.runtime_image_format_version = aot_image_emit_mod.format_version;
    meta.runtime_image_blob_present = false;
    meta.runtime_image_word_count = 12;

    try emitAotMetadata(testing.allocator, &out, meta, false, classifyArtifact(false, .metadata_only));

    try testing.expect(std.mem.indexOf(u8, out.items, "artifact-class=interpreter-free-aot\\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "runtime-image-present=no\\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "metadata-image-present=yes\\n") != null);
    // Image-format fields appear regardless of which image flavor is set
    // since both modes share the same on-disk format.
    try testing.expect(std.mem.indexOf(u8, out.items, "runtime-image-word-count=12\\n") != null);
}

test "classifyArtifact prefers interpreter when both flags set" {
    try testing.expectEqual(ArtifactClass.interpreter, classifyArtifact(true, .full_runtime));
    try testing.expectEqual(ArtifactClass.interpreter, classifyArtifact(true, .none));
    try testing.expectEqual(ArtifactClass.interpreter, classifyArtifact(true, .metadata_only));
    try testing.expectEqual(ArtifactClass.runtime_image_aot, classifyArtifact(false, .full_runtime));
    try testing.expectEqual(ArtifactClass.interpreter_free_aot, classifyArtifact(false, .none));
    try testing.expectEqual(ArtifactClass.interpreter_free_aot, classifyArtifact(false, .metadata_only));
}

test "AotFallbackReportBuilder records and snapshots site categories" {
    var builder = AotFallbackReportBuilder.init(testing.allocator);
    defer builder.deinit();

    builder.record(.{
        .category = .native,
        .caller_word = "lt",
        .callee_word = "<",
        .callee_word_id = 42,
        .line = 1,
    });
    builder.record(.{
        .category = .compound_uncompiled,
        .caller_word = "stream-write-string",
        .callee_word = "stream-write",
        .callee_word_id = 99,
        .line = 484,
    });
    builder.record(.{
        .category = .native,
        .caller_word = "eq",
        .callee_word = "=",
        .callee_word_id = 43,
        .line = 1,
    });

    var report = try builder.snapshot(testing.allocator);
    defer testing.allocator.free(report.sites);

    try testing.expectEqual(@as(u32, 3), report.total());
    try testing.expectEqual(@as(u32, 2), report.totals[@intFromEnum(AotFallbackCategory.native)]);
    try testing.expectEqual(@as(u32, 1), report.totals[@intFromEnum(AotFallbackCategory.compound_uncompiled)]);
    try testing.expectEqual(@as(u32, 0), report.totals[@intFromEnum(AotFallbackCategory.per_op_native)]);
    try testing.expectEqual(@as(usize, 3), report.sites.len);
    try testing.expectEqualStrings("<", report.sites[0].callee_word);
    try testing.expectEqualStrings("stream-write", report.sites[1].callee_word);
    try testing.expectEqual(AotFallbackCategory.native, report.sites[2].category);
}

test "verifyAotFallbackInventory matches when source agrees with builder" {
    // Source includes one extern declaration plus one real call site for
    // jitInterpretedCall (compound), one extern plus two real call sites
    // for jitNativeWordCall (native and per-op-native), and one extern
    // plus one real call site for jitCallQuotation.
    const source =
        "extern int32_t jitInterpretedCall(uintptr_t, uintptr_t, uintptr_t);\n" ++
        "extern int32_t jitNativeWordCall(uintptr_t, uintptr_t, uintptr_t);\n" ++
        "extern int32_t jitCallQuotation(uintptr_t);\n" ++
        "int32_t f(void) { jitInterpretedCall(0,1,2); return 0; }\n" ++
        "int32_t h(void) { jitNativeWordCall(0,1,2); jitNativeWordCall(0,3,4); return 0; }\n" ++
        "int32_t g(void) { jitCallQuotation(0); return 0; }\n";

    var report: AotFallbackReport = .{};
    report.totals[@intFromEnum(AotFallbackCategory.native)] = 1;
    report.totals[@intFromEnum(AotFallbackCategory.per_op_native)] = 1;
    report.totals[@intFromEnum(AotFallbackCategory.compound_uncompiled)] = 1;
    report.totals[@intFromEnum(AotFallbackCategory.quotation)] = 1;

    const check = verifyAotFallbackInventory(source, &report, true);
    try testing.expect(check.populated);
    try testing.expect(check.matches());
    try testing.expectEqual(@as(u32, 1), check.expected_jit_interpreted_calls);
    try testing.expectEqual(@as(u32, 1), check.observed_jit_interpreted_calls);
    try testing.expectEqual(@as(u32, 2), check.expected_jit_native_word_calls);
    try testing.expectEqual(@as(u32, 2), check.observed_jit_native_word_calls);
    try testing.expectEqual(@as(u32, 1), check.expected_jit_call_quotation);
    try testing.expectEqual(@as(u32, 1), check.observed_jit_call_quotation);
}

test "verifyAotFallbackInventory flags mismatch when builder undercounts" {
    // Three real jitNativeWordCall sites plus the extern declaration but
    // the builder only recorded two native emissions.
    const source =
        "extern int32_t jitInterpretedCall(uintptr_t, uintptr_t, uintptr_t);\n" ++
        "extern int32_t jitNativeWordCall(uintptr_t, uintptr_t, uintptr_t);\n" ++
        "extern int32_t jitCallQuotation(uintptr_t);\n" ++
        "int32_t f(void) { jitNativeWordCall(0,1,2); jitNativeWordCall(0,3,4); jitNativeWordCall(0,5,6); return 0; }\n";

    var report: AotFallbackReport = .{};
    report.totals[@intFromEnum(AotFallbackCategory.native)] = 2;

    const check = verifyAotFallbackInventory(source, &report, true);
    try testing.expect(check.populated);
    try testing.expect(!check.matches());
    try testing.expectEqual(@as(u32, 0), check.expected_jit_interpreted_calls);
    try testing.expectEqual(@as(u32, 0), check.observed_jit_interpreted_calls);
    try testing.expectEqual(@as(u32, 2), check.expected_jit_native_word_calls);
    try testing.expectEqual(@as(u32, 3), check.observed_jit_native_word_calls);
    try testing.expectEqual(@as(u32, 0), check.expected_jit_call_quotation);
    try testing.expectEqual(@as(u32, 0), check.observed_jit_call_quotation);
}

test "verifyAotFallbackInventory ignores absent callbacks" {
    // No extern declaration, no calls -- nothing to subtract.
    const source = "int32_t f(void) { return 0; }\n";

    var report: AotFallbackReport = .{};

    const check = verifyAotFallbackInventory(source, &report, false);
    try testing.expect(check.matches());
    try testing.expectEqual(@as(u32, 0), check.observed_jit_interpreted_calls);
    try testing.expectEqual(@as(u32, 0), check.observed_jit_native_word_calls);
    try testing.expectEqual(@as(u32, 0), check.observed_jit_call_quotation);
}

test "verifyAotFallbackInventory counts call sites without an extern" {
    // Interpreter-free build dropped the extern declaration but a codegen
    // path leaked a call site. The raw count is the call-site count
    // exactly; no minus-one adjustment.
    const source = "int32_t f(void) { jitInterpretedCall(0,1,2); return 0; }\n";

    var report: AotFallbackReport = .{};

    const check = verifyAotFallbackInventory(source, &report, false);
    try testing.expect(check.populated);
    try testing.expectEqual(@as(u32, 1), check.observed_jit_interpreted_calls);
    try testing.expectEqual(@as(u32, 0), check.expected_jit_interpreted_calls);
}

test "aotSatisfiesAndDispatch dispatches through a populated slot table" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    try ctx.defineWord("describe", .{ .name = "describe", .action = .{ .compound = &[_]Instruction{} } });
    const did = ctx.resolveDispatchId("describe").?;

    const body = &[_]Instruction{
        .{ .op = .{ .call_word = "inspect" }, .line = 0 },
    };
    try ctx.registerDispatch(
        .{ .dispatch_id = did, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    const descriptor = try ctx.createProtocolDescriptor("describable", &[_]Value{.{ .symbol = "describe" }});
    var slots = [_]?*const value_mod.ProtocolDescriptor{descriptor};
    ctx.image_protocoldescriptor_slots = &slots;
    ctx.image_protocoldescriptor_slot_count = 1;

    try ctx.stack.push(.{ .fixnum = 42 });
    const rc = aotSatisfiesAndDispatch(@intFromPtr(&ctx), did, 0, @intFromEnum(dispatch_helpers.ProtocolArity.unary), 0);
    try testing.expectEqual(@as(i32, 0), rc);
    try testing.expectEqualStrings("42", (try ctx.stack.pop()).string);
}

test "aotSatisfiesAndDispatch rejects an out-of-range slot index" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const descriptor = try ctx.createProtocolDescriptor("describable", &[_]Value{.{ .symbol = "describe" }});
    var slots = [_]?*const value_mod.ProtocolDescriptor{descriptor};
    ctx.image_protocoldescriptor_slots = &slots;
    ctx.image_protocoldescriptor_slot_count = 1;

    const rc = aotSatisfiesAndDispatch(@intFromPtr(&ctx), 0, 5, @intFromEnum(dispatch_helpers.ProtocolArity.unary), 0);
    try testing.expectEqual(@as(i32, 2), rc);
    try testing.expectEqual(error.UserThrown, ctx.jit_pending_error.?);
}

test "aotSatisfiesAndDispatch rejects a null slot entry and a missing table" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // Missing table: the loader never populated the slots.
    var rc = aotSatisfiesAndDispatch(@intFromPtr(&ctx), 0, 0, @intFromEnum(dispatch_helpers.ProtocolArity.unary), 0);
    try testing.expectEqual(@as(i32, 2), rc);

    // Present table, unpatched slot.
    var slots = [_]?*const value_mod.ProtocolDescriptor{null};
    ctx.image_protocoldescriptor_slots = &slots;
    ctx.image_protocoldescriptor_slot_count = 1;
    rc = aotSatisfiesAndDispatch(@intFromPtr(&ctx), 0, 0, @intFromEnum(dispatch_helpers.ProtocolArity.unary), 0);
    try testing.expectEqual(@as(i32, 2), rc);
    try testing.expectEqual(error.UserThrown, ctx.jit_pending_error.?);
}
