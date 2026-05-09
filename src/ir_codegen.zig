const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const Value = value_mod.Value;
const VirtualType = value_mod.VirtualType;
const StructInstance = value_mod.StructInstance;
const StructType = value_mod.StructType;
const TypeValue = value_mod.TypeValue;
const HashTable = value_mod.HashTable;

const ir_mod = @import("ffi/ir.zig");
const JitBuffer = ir_mod.JitBuffer;
const c = ir_mod.ir;

const jit_dispatch_mod = @import("jit_dispatch.zig");
const JitDispatchTable = jit_dispatch_mod.JitDispatchTable;
const JitEntry = jit_dispatch_mod.JitEntry;

const pic_mod = @import("pic.zig");
const dispatch_mod = @import("dispatch.zig");

const Context = @import("context.zig").Context;
const bail_stats_mod = @import("bail_stats.zig");
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
const AotQuotationDesc = @import("aot_freeze.zig").AotQuotationDesc;

pub const IrCodegenError = error{
    NotCompilable,
    CompilationFailed,
    StackUnderflow,
    StackShapeMismatch,
    UncompiledWords,
    UncompiledQuotations,
    InterpreterRequiredButLocked,
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
};

pub const PreludeStats = struct {
    total: u32 = 0,
    compiled: u32 = 0,
    uncompiled: []const UncompiledWord = &.{},
};

pub const UncompiledQuotation = struct {
    quotation_id: u32,
    c_name: []const u8,
};

pub const PicStats = struct {
    sites_attempted: u32 = 0,
    sites_emitted: u32 = 0,
};

pub const CodegenDiagnostics = struct {
    uncompiled_words: []const UncompiledWord = &.{},
    uncompiled_quotations: []const UncompiledQuotation = &.{},
    quotation_fallbacks: []const QuotationFallbackWarning = &.{},
    prelude_stats: PreludeStats = .{},
    pic_stats: PicStats = .{},
    resolved_interpreter_fallback: ?InterpreterFallbackMode = null,
    has_interpreter_callbacks: bool = false,
};

pub const CompiledWord = struct {
    code_ptr: *const anyopaque,
    jit_buf: JitBuffer,
    peak_stack_depth: u32 = 0,
};

fn shouldSkipTypeAnnotationValidation(word: WordDefinition) bool {
    const has_generic = for (word.markers) |mk| {
        if (markers_mod.isGenericMarker(mk)) break true;
    } else false;
    if (!has_generic) return false;

    return switch (word.action) {
        .compound => |instrs| instrs.len == 0,
        .native, .host_callback => false,
    };
}

/// Description of a word to be compiled for AOT C emission.
pub const AotWordDesc = struct {
    name: []const u8,
    instructions: []const Instruction,
    input_count: u8,
    output_count: u8,
    word_id: u32,
    /// Prelude words are available in the AOT runtime dictionary and can
    /// safely fall back to jitInterpretedCall if codegen fails.
    is_prelude: bool = false,
    /// Native words have no compound instructions and must always use
    /// jitInterpretedCall at runtime. They are included in the resolver
    /// so that non-prelude words calling them are not rejected, but they
    /// must not enter compiled_names or be trial-compiled.
    is_native: bool = false,
    /// Address of the native function for native generic words.
    /// Used by the AOT resolver to populate ResolvedWord.native_fn_ptr
    /// so emitInlinePicCheck can fire at generic call sites.
    native_fn_ptr: ?usize = null,
    /// Full stack effect declaration for this word. Used by the compiler
    /// to track stack shapes through quotation calls.
    stack_effect: ?StackEffect = null,
    /// When true, the word never returns to its caller (has the
    /// never-returns marker). The compiler emits terminal control flow
    /// instead of continuing in the current block after the call.
    never_returns: bool = false,
    /// Snapshot of interpreter PIC data for this word's instructions.
    /// Captured during freeze so the AOT compiler can emit inline type
    /// checks preseeded from interpreter profiling.
    pic_snapshot: ?*pic_mod.PicTable = null,
};

const supported_binary_ops = [_][]const u8{ "+", "-", "*", "/", "div", "rem", "%" };
const supported_unary_ops = [_][]const u8{"abs"};
const supported_comparison_ops = [_][]const u8{ "=", "<", ">" };

fn isSupportedOp(name: []const u8) bool {
    for (supported_binary_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    for (supported_unary_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    for (supported_comparison_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }

    // HACK(ripta): include some non-primitive ops as "supported" so they can be compiled with the same fast path
    //              as primitives instead of going through dynamic dispatch
    if (std.mem.eql(u8, name, "if")) return true;
    if (std.mem.eql(u8, name, "call")) return true;
    if (std.mem.eql(u8, name, "choose")) return true;
    if (std.mem.eql(u8, name, "t") or std.mem.eql(u8, name, "f")) return true;

    if (isLoopOp(name)) return true;
    if (isErrorHandlingOp(name)) return true;
    if (isDynamicVarOp(name)) return true;
    if (isIteratorOp(name)) return true;

    // HACK(ripta): not technically native, but treat certain native core library words as harcoded
    //              instrinsics so they can be compiled with the same fast path instead of dynamic dispatch
    if (std.mem.eql(u8, name, "native.virtual-unwrap")) return true;
    if (std.mem.eql(u8, name, "native.struct-field-get")) return true;
    if (std.mem.eql(u8, name, "native.struct-field-set")) return true;
    if (std.mem.eql(u8, name, "native.typed-validate-and-promote")) return true;
    if (std.mem.eql(u8, name, "native.make-struct-instance")) return true;
    if (std.mem.eql(u8, name, "native.struct-instance-destructure")) return true;
    if (std.mem.eql(u8, name, "native.struct-instance-to-hash")) return true;
    if (std.mem.eql(u8, name, "native.struct-type-predicate")) return true;
    if (std.mem.eql(u8, name, "native.hash-to-struct")) return true;

    return false;
}

/// Struct native ops that need jitInterpretedCall at runtime.
fn isStructNativeOp(name: []const u8) bool {
    return std.mem.eql(u8, name, "native.make-struct-instance") or
        std.mem.eql(u8, name, "native.struct-instance-destructure") or
        std.mem.eql(u8, name, "native.struct-instance-to-hash") or
        std.mem.eql(u8, name, "native.struct-type-predicate") or
        std.mem.eql(u8, name, "native.hash-to-struct");
}

/// Native helpers whose preceding fixnum literal is a process-local
/// VirtualType pointer. In AOT, those pointers are baked from the build
/// process and become invalid in the generated binary's runtime process, so
/// callers must fall back to the interpreter.
fn isRuntimeVirtualPtrNative(name: []const u8) bool {
    return std.mem.eql(u8, name, "native.virtual-wrap") or
        std.mem.eql(u8, name, "native.virtual-unwrap") or
        std.mem.eql(u8, name, "native.virtual-type-predicate") or
        std.mem.eql(u8, name, "native.virtual-struct-wrap") or
        std.mem.eql(u8, name, "native.virtual-struct-unwrap") or
        std.mem.eql(u8, name, "native.virtual-struct-to-hash") or
        std.mem.eql(u8, name, "native.virtual-struct-hash-wrap") or
        std.mem.eql(u8, name, "native.virtual-parameterized-wrap") or
        std.mem.eql(u8, name, "native.typed-validate-and-promote") or
        std.mem.eql(u8, name, "native.typed-validate-seq-elements") or
        std.mem.eql(u8, name, "native.typed-nth-mut-dispatch") or
        std.mem.eql(u8, name, "native.typed-at-set-mut-dispatch") or
        std.mem.eql(u8, name, "native.typed-at-remove-mut-dispatch") or
        std.mem.eql(u8, name, "native.typed-freeze-dispatch");
}

fn isBinaryOp(name: []const u8) bool {
    for (supported_binary_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

fn isComparisonOp(name: []const u8) bool {
    for (supported_comparison_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

/// Map a binary op name to a PolyArithOp for polymorphic fixnum/float handling.
/// Returns null for integer-only ops (div, rem) that have no float path.
fn polyArithOpFromName(name: []const u8) ?PolyArithOp {
    if (std.mem.eql(u8, name, "+")) return .add;
    if (std.mem.eql(u8, name, "-")) return .sub;
    if (std.mem.eql(u8, name, "*")) return .mul;
    if (std.mem.eql(u8, name, "/")) return .div;
    if (std.mem.eql(u8, name, "%")) return .mod;
    return null;
}

const supported_stack_ops = [_][]const u8{ "dup", "drop", "swap", "over" };

fn isStackOp(name: []const u8) bool {
    for (supported_stack_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

const supported_indexed_stack_ops = [_][]const u8{ "pick-n", "<rot-n", "rot-n>", "nip-n" };

fn isIndexedStackOp(name: []const u8) bool {
    for (supported_indexed_stack_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

const supported_loop_ops = [_][]const u8{ "times", "loop", "while", "until" };

fn isLoopOp(name: []const u8) bool {
    for (supported_loop_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

fn isErrorHandlingOp(name: []const u8) bool {
    return std.mem.eql(u8, name, "recover") or std.mem.eql(u8, name, "cleanup");
}

fn isDynamicVarOp(name: []const u8) bool {
    return std.mem.eql(u8, name, "get") or std.mem.eql(u8, name, "with-parameter");
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

fn isIteratorOp(name: []const u8) bool {
    return iteratorOpcodeFromName(name) != null;
}

fn iteratorOpcodeFromName(name: []const u8) ?IteratorOpcode {
    // >iterator is a generic compound word in the prelude, not a pure
    // native. Calling nativeToIterator directly would bypass generic
    // dispatch, breaking user-defined >iterator methods on virtual types.
    if (std.mem.eql(u8, name, "#next")) return .next;
    if (std.mem.eql(u8, name, "#collect")) return .collect;
    if (std.mem.eql(u8, name, "#count")) return .count;
    if (std.mem.eql(u8, name, "close-iterator")) return .close_iterator;
    if (std.mem.eql(u8, name, "#take")) return .take;
    if (std.mem.eql(u8, name, "#drop")) return .drop;
    if (std.mem.eql(u8, name, "#each")) return .each;
    if (std.mem.eql(u8, name, "#map")) return .map;
    if (std.mem.eql(u8, name, "#filter")) return .filter;
    if (std.mem.eql(u8, name, "#reduce")) return .reduce;
    return null;
}

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
            .hash, .vector, .byte_array, .set, .mutable_map, .stream, .resource, .parameter, .module, .marker, .struct_type, .struct_instance, .benchmark_report, .task, .channel, .iterator, .type_val, .sandbox_spec => .ptr,
            .string, .symbol, .array, .doc_string, .template => .slice,
            .tagged => .dual_ptr,
            .bignum, .quotation, .stack_effect, .error_value => .inline_,
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
    descriptor: *const HashTable,
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
/// If the resolver is unavailable or cannot resolve the operation, emits a bail return instead..
fn emitPerOperationFallback(
    state: *CompileState,
    op_name: []const u8,
    slot_a: usize,
    slot_b: usize,
    line: usize,
) void {
    const ctx = state.ctx;

    // Without a resolver, report a type error.
    const res = state.resolver orelse {
        if (state.type_mismatch_error_fn != c.IR_UNUSED) {
            emitErrorReturn(state, state.type_mismatch_error_fn);
        } else {
            c._ir_RETURN(ctx, state.bail_status);
        }
        return;
    };
    const resolved = res.resolve(op_name, res.user_data) orelse {
        if (state.type_mismatch_error_fn != c.IR_UNUSED) {
            emitErrorReturn(state, state.type_mismatch_error_fn);
        } else {
            c._ir_RETURN(ctx, state.bail_status);
        }
        return;
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
    // is available (JIT mode), jitInterpretedCall with word_id otherwise (AOT).
    if (!state.aot_mode and resolved.native_fn_ptr != null) {
        const fn_ptr_const = c.ir_const_addr(ctx, resolved.native_fn_ptr.?);
        const call_result = c._ir_CALL_2(ctx, c.IR_I32, state.native_call_fn, ctx_val, fn_ptr_const);
        emitCallbackPostCheck(state, call_result, call_result, null, .{ .named = .{ .name = op_name, .line = line } });
    } else {
        const word_id_const = c.ir_const_addr(ctx, resolved.word_id);
        const line_const = c.ir_const_addr(ctx, line);
        state.noteAotFallbackEmission();
        const call_result = c._ir_CALL_3(ctx, c.IR_I32, state.interpreted_call_fn, ctx_val, word_id_const, line_const);
        emitCallbackPostCheck(state, call_result, state.error_propagate_status, null, .none);
    }

    // After the native returns, SP = base_idx + slot_a + 1 and the result
    // is at physical slot slot_a. The caller sets the abstract stack entry
    // to raw_at_slot(dest_slot).
    _ = slot_a;
}

/// Emit polymorphic binary arithmetic that handles both fixnum and float
/// operands at runtime via tag-check branching. Non-numeric operands fall
/// back to the polymorphic native via jitInterpretedCall for just that
/// operation, then continue compiled execution. The result is written as a
/// boxed Value at dest_slot.
fn emitPolymorphicBinaryArith(
    state: *CompileState,
    slot_a: usize,
    slot_b: usize,
    dest_slot: usize,
    op: PolyArithOp,
    line: usize,
) void {
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
        const dest_byte_offset = c.ir_const_addr(ctx, dest_slot * ValueLayout.value_size);
        const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_addr, dest_byte_offset);

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
        emitPerOperationFallback(state, op_name, slot_a, slot_b, line);
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
    /// Reference to jitRefreshStack: re-LOADs ctx.stack.items.items.ptr and
    /// capacity into the JitContext after a callback may have reallocated
    /// the stack. Emitted from emitCallbackPostCheck on the hot-path continue
    /// branch.
    refresh_stack_fn: c.ir_ref = c.IR_UNUSED,
    validate_params_fn: c.ir_ref = c.IR_UNUSED,
    interp_ctx: ?*const Context = null,
    /// Interpreter PIC table for the word being compiled. Each instruction
    /// index maps to a PolymorphicCache recording observed type pairs.
    /// Read at compile time to emit inline type-check-and-branch IR.
    pic_table: ?*pic_mod.PicTable = null,
    pic_dispatch_fn: c.ir_ref = c.IR_UNUSED,
    pic_native_call_fn: c.ir_ref = c.IR_UNUSED,
    pic_match_fn: c.ir_ref = c.IR_UNUSED,
    pic_stats: ?*PicStats = null,
    /// Counts AOT-mode emissions of CALLs through interpreted_call_fn or
    /// call_quotation_fn. The substring scan that decides interpreter-free
    /// linking reads this counter instead of grepping the generated C.
    aot_fallback_emit_count: ?*u32 = null,
    error_propagate_status: c.ir_ref = c.IR_UNUSED,
    self_name: ?[]const u8 = null,
    loop_begin_ref: c.ir_ref = c.IR_UNUSED,
    input_count: u8 = 0,
    exit_kind: ExitKind = .falls_through,
    loop_end_set: bool = false,
    mutual_group: ?[]const []const u8 = null,
    trampoline_status: c.ir_ref = c.IR_UNUSED,
    /// When true, callback references use named extern symbols (ir_const_func)
    /// instead of baked function pointer addresses (ir_const_addr). This is
    /// required for AOT C emission where addresses are not known at compile time.
    aot_mode: bool = false,
    /// Set of compiled word names available in AOT mode. Used to decide whether
    /// a compound word call can be a direct function call or must fall through
    /// to jitInterpretedCall.
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
    /// Error-reporting callbacks that set jit_pending_error and return 2.
    /// Used to replace bail_status returns with proper error propagation.
    type_mismatch_error_fn: c.ir_ref = c.IR_UNUSED,
    overflow_error_fn: c.ir_ref = c.IR_UNUSED,
    div_zero_error_fn: c.ir_ref = c.IR_UNUSED,
    underflow_error_fn: c.ir_ref = c.IR_UNUSED,
    append_word_trace_frame_fn: c.ir_ref = c.IR_UNUSED,
    append_builtin_trace_frame_fn: c.ir_ref = c.IR_UNUSED,
    /// Pre-loaded interpreter Context pointer from JitContext. In AOT mode,
    /// this is loaded once in the prologue to avoid the ir_emit_c d_0 bug
    /// where unused LOADs get assigned vreg 0 without a declaration.
    preloaded_ctx_val: c.ir_ref = c.IR_UNUSED,
    /// Accumulator for string/symbol literals encountered during AOT compilation.
    /// Each entry gets emitted as a `static const char[]` in the C preamble.
    aot_string_literals: ?*std.ArrayListUnmanaged(AotStringLiteral) = null,
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
    /// Mapping from input slot indices to concrete quotation effects.
    /// Populated when stack_effect is available and quotation parameters
    /// have fixed (non-row-variable) arities.
    quotation_slots: QuotationSlotMap = .{},
    inline_trace_frames: [max_inline_trace_frames]InlineTraceFrame = undefined,
    inline_trace_frame_count: usize = 0,
    /// Monotonic counter for allocating unique RowId values.
    next_row_id: RowId = 0,

    /// Allocate a fresh RowId, unique within this compilation.
    fn nextRowId(state: *CompileState) RowId {
        const id = state.next_row_id;
        state.next_row_id += 1;
        return id;
    }

    /// Record an AOT-mode CALL through interpreted_call_fn or
    /// call_quotation_fn. Only AOT-mode emissions produce textual
    /// `jitInterpretedCall` / `jitCallQuotation` references in the
    /// generated C; JIT mode bakes addresses instead.
    fn noteAotFallbackEmission(state: *CompileState) void {
        if (!state.aot_mode) return;
        if (state.aot_fallback_emit_count) |counter| counter.* += 1;
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

/// Entry in the lightweight mini-stack used during quotation effect inference.
/// Tracks whether a position holds a known quotation body (for resolving
/// `call` and `if` within the body) or an opaque value.
const MiniStackEntry = union(enum) {
    quotation: []const Instruction,
    other,
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
            .call_word => |name| {
                if (try inferBuiltinEffect(name, &mini_stack, &sp, &delta, &min_delta, resolver)) |ok| {
                    if (!ok) return null;
                } else {
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
/// Returns `true` if the word was handled successfully, `false` if inference
/// should abort (bail), or `null` if the word is not a built-in (caller should
/// try the WordResolver).
fn inferBuiltinEffect(
    name: []const u8,
    mini_stack: *[max_mini_stack_depth]MiniStackEntry,
    sp: *usize,
    delta: *i32,
    min_delta: *i32,
    resolver: ?WordResolver,
) error{EffectInferenceOverflow}!?bool {
    // Stack shufflers need special mini-stack handling to propagate
    // quotation-body knowledge through shuffles.
    if (std.mem.eql(u8, name, "dup")) {
        // ( a -- a a ): net +1, needs 1 input.
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
    if (std.mem.eql(u8, name, "drop")) {
        delta.* -= 1;
        min_delta.* = @min(min_delta.*, delta.*);
        if (sp.* > 0) sp.* -= 1;
        return true;
    }
    if (std.mem.eql(u8, name, "swap")) {
        // ( a b -- b a ): net 0, needs 2 inputs.
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
    if (std.mem.eql(u8, name, "over")) {
        // ( a b -- a b a ): net +1, needs 2 inputs.
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

    // Boolean literals.
    if (std.mem.eql(u8, name, "t") or std.mem.eql(u8, name, "f")) {
        try applyFixedEffect(mini_stack, sp, delta, min_delta, 0, 1);
        return true;
    }

    // abs: ( n -- n )
    if (std.mem.eql(u8, name, "abs")) {
        try applyFixedEffect(mini_stack, sp, delta, min_delta, 1, 1);
        return true;
    }

    // Binary ops: ( a b -- result )
    if (isBinaryOp(name)) {
        try applyFixedEffect(mini_stack, sp, delta, min_delta, 2, 1);
        return true;
    }

    // Comparison ops: ( a b -- bool )
    if (isComparisonOp(name)) {
        try applyFixedEffect(mini_stack, sp, delta, min_delta, 2, 1);
        return true;
    }

    // `call`: pop quotation, apply its effect.
    if (std.mem.eql(u8, name, "call")) {
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

    // `if`: ( cond true-quot false-quot -- results... )
    if (std.mem.eql(u8, name, "if")) {
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

    // choose: ( a1 a2 quot -- a )
    if (std.mem.eql(u8, name, "choose")) {
        try applyFixedEffect(mini_stack, sp, delta, min_delta, 3, 1);
        return true;
    }

    // Not a recognized built-in.
    return null;
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
        for (qe.inputs) |qp| {
            if (!qp.is_row_variable) continue;
            if (!(try addOrCheckBinding(&bindings, &num_bindings, qp.name, row_in_size))) return null;
        }

        // Bind row variables from the quotation's output side.
        for (qe.outputs) |qp| {
            if (!qp.is_row_variable) continue;
            if (!(try addOrCheckBinding(&bindings, &num_bindings, qp.name, row_out_size))) return null;
        }
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
            const slot_byte_offset = c.ir_const_addr(ctx, s * ValueLayout.value_size);
            const elem_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_addr, slot_byte_offset);
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
            const slot_byte_offset = c.ir_const_addr(ctx, s * ValueLayout.value_size);
            const elem_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_addr, slot_byte_offset);
            emitTagCheck(ctx, elem_addr, state.float_tag_const, state.tag_offset_const, state.bail_status);
            return emitUnboxF64(ctx, elem_addr, state.payload_offset_const);
        },
        else => {
            state.not_compilable_reason = .non_numeric_operand;
            return IrCodegenError.NotCompilable;
        },
    };
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
};

const AotArrayLiteral = struct {
    data: []const u8,
};

/// Serialize a quotation's instruction slice into a portable byte array
/// suitable for embedding as a C constant. The format is:
///   [u32 instruction_count]
///   per instruction:
///     [u32 line] [u32 column] [u8 op_tag: 0=push_literal, 1=call_word]
///     push_literal: [u8 value_tag] + payload
///       0=fixnum: [i64]  1=float: [f64]  2=bool: [u8]
///       3=string: [u32 len][bytes]  4=symbol: [u32 len][bytes]
///       5=quotation: [recursive]
///       6=array: [u32 elem_count][recursive values...]
///       7=hash: [u32 entry_count][per entry: u32 key_len, key_bytes, recursive value]
///     call_word: [u32 name_len][bytes]
fn serializeQuotationInstructions(instructions: []const Instruction, allocator: Allocator) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);
    try serializeInstructionsInto(&buf, instructions, allocator);
    return buf.toOwnedSlice(allocator);
}

const SerializeError = Allocator.Error || error{NotCompilable};

fn serializeInstructionsInto(buf: *std.ArrayListUnmanaged(u8), instructions: []const Instruction, allocator: Allocator) SerializeError!void {
    const count: u32 = @intCast(instructions.len);
    try buf.appendSlice(allocator, std.mem.asBytes(&count));
    for (instructions) |instr| {
        const line: u32 = @intCast(instr.line);
        const col: u32 = @intCast(instr.column);
        try buf.appendSlice(allocator, std.mem.asBytes(&line));
        try buf.appendSlice(allocator, std.mem.asBytes(&col));
        switch (instr.op) {
            .push_literal => |val| {
                // Non-simple literals (type values, enum variants, parameter
                // definitions) are rewritten as call_word instructions so the
                // quotation body dispatches to the named word at runtime.
                if (val == .type_val) {
                    const name = val.type_val.name;
                    try buf.append(allocator, 1); // op tag: call_word
                    const len: u32 = @intCast(name.len);
                    try buf.appendSlice(allocator, std.mem.asBytes(&len));
                    try buf.appendSlice(allocator, name);
                } else if (val == .tagged) {
                    const name = val.tagged.tag.name;
                    try buf.append(allocator, 1); // op tag: call_word
                    const len: u32 = @intCast(name.len);
                    try buf.appendSlice(allocator, std.mem.asBytes(&len));
                    try buf.appendSlice(allocator, name);
                } else if (val == .parameter) {
                    const name = val.parameter.name;
                    try buf.append(allocator, 1); // op tag: call_word
                    const len: u32 = @intCast(name.len);
                    try buf.appendSlice(allocator, std.mem.asBytes(&len));
                    try buf.appendSlice(allocator, name);
                } else if (val == .marker) {
                    const name = val.marker.name;
                    try buf.append(allocator, 1); // op tag: call_word
                    const len: u32 = @intCast(name.len);
                    try buf.appendSlice(allocator, std.mem.asBytes(&len));
                    try buf.appendSlice(allocator, name);
                } else {
                    try buf.append(allocator, 0); // op tag: push_literal
                    try serializeValueInto(buf, val, allocator);
                }
            },
            .call_word => |name| {
                try buf.append(allocator, 1); // op tag: call_word
                const len: u32 = @intCast(name.len);
                try buf.appendSlice(allocator, std.mem.asBytes(&len));
                try buf.appendSlice(allocator, name);
            },
        }
    }
}

fn serializeValueInto(buf: *std.ArrayListUnmanaged(u8), val: Value, allocator: Allocator) SerializeError!void {
    switch (val) {
        .fixnum => |v| {
            try buf.append(allocator, 0);
            try buf.appendSlice(allocator, std.mem.asBytes(&v));
        },
        .float => |v| {
            try buf.append(allocator, 1);
            try buf.appendSlice(allocator, std.mem.asBytes(&v));
        },
        .boolean => |v| {
            try buf.append(allocator, 2);
            try buf.append(allocator, @intFromBool(v));
        },
        .string => |v| {
            try buf.append(allocator, 3);
            const len: u32 = @intCast(v.len);
            try buf.appendSlice(allocator, std.mem.asBytes(&len));
            try buf.appendSlice(allocator, v);
        },
        .symbol => |v| {
            try buf.append(allocator, 4);
            const len: u32 = @intCast(v.len);
            try buf.appendSlice(allocator, std.mem.asBytes(&len));
            try buf.appendSlice(allocator, v);
        },
        .quotation => |q| {
            try buf.append(allocator, 5);
            try serializeInstructionsInto(buf, q.instructions, allocator);
        },
        .array => |elems| {
            try buf.append(allocator, 6);
            const elem_count: u32 = @intCast(elems.len);
            try buf.appendSlice(allocator, std.mem.asBytes(&elem_count));
            for (elems) |elem| {
                try serializeValueInto(buf, elem, allocator);
            }
        },
        .hash => |h| {
            try buf.append(allocator, 7);
            const entry_count: u32 = @intCast(h.count());
            try buf.appendSlice(allocator, std.mem.asBytes(&entry_count));
            var iter = h.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const key_len: u32 = @intCast(key.len);
                try buf.appendSlice(allocator, std.mem.asBytes(&key_len));
                try buf.appendSlice(allocator, key);
                try serializeValueInto(buf, entry.value_ptr.*, allocator);
            }
        },
        else => return IrCodegenError.NotCompilable, // D.4: non-simple AOT literal
    }
}

fn deserializeQuotationInstructions(data: []const u8, allocator: Allocator) ![]Instruction {
    var offset: usize = 0;
    return deserializeInstructionsAt(data, &offset, allocator);
}

fn deserializeInstructionsAt(data: []const u8, offset: *usize, allocator: Allocator) Allocator.Error![]Instruction {
    if (offset.* + 4 > data.len) return error.OutOfMemory;
    const count = std.mem.readInt(u32, data[offset.*..][0..4], .little);
    offset.* += 4;
    const instructions = try allocator.alloc(Instruction, count);
    for (instructions) |*instr| {
        if (offset.* + 9 > data.len) return error.OutOfMemory; // line(4)+col(4)+op_tag(1)
        const line = std.mem.readInt(u32, data[offset.*..][0..4], .little);
        offset.* += 4;
        const col = std.mem.readInt(u32, data[offset.*..][0..4], .little);
        offset.* += 4;
        const op_tag = data[offset.*];
        offset.* += 1;
        if (op_tag == 0) {
            // push_literal
            const val = try deserializeValueAt(data, offset, allocator);
            instr.* = .{ .op = .{ .push_literal = val }, .line = line, .column = col };
        } else if (op_tag == 1) {
            // call_word
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const nlen = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            if (offset.* + nlen > data.len) return error.OutOfMemory;
            const name_copy = try allocator.dupe(u8, data[offset.*..][0..nlen]);
            offset.* += nlen;
            instr.* = .{ .op = .{ .call_word = name_copy }, .line = line, .column = col };
        } else {
            return error.OutOfMemory;
        }
    }
    return instructions;
}

fn deserializeValueAt(data: []const u8, offset: *usize, allocator: Allocator) Allocator.Error!Value {
    if (offset.* >= data.len) return error.OutOfMemory;
    const val_tag = data[offset.*];
    offset.* += 1;
    return switch (val_tag) {
        0 => blk: { // fixnum
            if (offset.* + 8 > data.len) return error.OutOfMemory;
            const v = std.mem.readInt(i64, data[offset.*..][0..8], .little);
            offset.* += 8;
            break :blk .{ .fixnum = v };
        },
        1 => blk: { // float
            if (offset.* + 8 > data.len) return error.OutOfMemory;
            const v = @as(f64, @bitCast(std.mem.readInt(u64, data[offset.*..][0..8], .little)));
            offset.* += 8;
            break :blk .{ .float = v };
        },
        2 => blk: { // bool
            if (offset.* >= data.len) return error.OutOfMemory;
            const v = data[offset.*] != 0;
            offset.* += 1;
            break :blk .{ .boolean = v };
        },
        3 => blk: { // string
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const slen = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            if (offset.* + slen > data.len) return error.OutOfMemory;
            const copy = try allocator.dupe(u8, data[offset.*..][0..slen]);
            offset.* += slen;
            break :blk .{ .string = copy };
        },
        4 => blk: { // symbol
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const slen = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            if (offset.* + slen > data.len) return error.OutOfMemory;
            const copy = try allocator.dupe(u8, data[offset.*..][0..slen]);
            offset.* += slen;
            break :blk .{ .symbol = copy };
        },
        5 => blk: { // quotation
            const nested = try deserializeInstructionsAt(data, offset, allocator);
            break :blk .{ .quotation = .{ .instructions = nested } };
        },
        6 => blk: { // array
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const elem_count = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            const elems = try allocator.alloc(Value, elem_count);
            for (elems) |*elem| {
                elem.* = try deserializeValueAt(data, offset, allocator);
            }
            break :blk .{ .array = elems };
        },
        7 => blk: { // hash
            if (offset.* + 4 > data.len) return error.OutOfMemory;
            const entry_count = std.mem.readInt(u32, data[offset.*..][0..4], .little);
            offset.* += 4;
            var h = HashTable{};
            try h.ensureTotalCapacity(allocator, entry_count);
            for (0..entry_count) |_| {
                if (offset.* + 4 > data.len) return error.OutOfMemory;
                const klen = std.mem.readInt(u32, data[offset.*..][0..4], .little);
                offset.* += 4;
                if (offset.* + klen > data.len) return error.OutOfMemory;
                const key = try allocator.dupe(u8, data[offset.*..][0..klen]);
                offset.* += klen;
                const value = try deserializeValueAt(data, offset, allocator);
                h.putAssumeCapacity(key, value);
            }
            const h_ptr = try allocator.create(HashTable);
            h_ptr.* = h;
            break :blk .{ .hash = h_ptr };
        },
        else => return error.OutOfMemory,
    };
}

/// Materialize any quotation_body entries as raw Values on the physical stack.
/// flushToPhysicalStack skips quotation_body since it's normally consumed by
/// `if`/`call`, but callback-based ops need them as proper Values for the
/// interpreter to pop.
///
/// In AOT mode, quotation bodies are serialized to byte arrays and pushed
/// via the jitPushQuotation callback, avoiding dangling instruction pointers.
fn materializeQuotations(state: *CompileState, stack: []StackEntry, sp: usize) IrCodegenError!void {
    const ctx = state.ctx;
    const base_addr = state.base_addr;
    for (0..sp) |qi| {
        switch (stack[qi]) {
            .quotation_body => |body| {
                if (state.aot_mode) {
                    // Serialize the instruction body and record it for C emission.
                    const serialized = serializeQuotationInstructions(body, std.heap.page_allocator) catch {
                        state.not_compilable_reason = .non_serializable_literal;
                        return IrCodegenError.NotCompilable;
                    };

                    const lit_id = if (state.aot_quotation_literals) |lits| lits.items.len else 0;

                    if (state.aot_quotation_literals) |lits| {
                        lits.append(std.heap.page_allocator, .{ .data = serialized }) catch {
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

                    // Look up the global quotation_id for this body.
                    const q_id: usize = if (state.aot_quotation_id_map) |m|
                        m.get(@intFromPtr(body.ptr)) orelse std.math.maxInt(u32)
                    else
                        std.math.maxInt(u32);
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
    const byte_off = c.ir_fold2(ctx, c.IR_OPT(c.IR_MUL, c.IR_ADDR), adjusted, state.value_size_const);
    const new_base = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.items_ptr, byte_off);
    state.base_addr = new_base;
    state.base_idx = adjusted;
    state.sp_val = new_sp_val;
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
fn rewriteIndexedStackOp(
    state: *CompileState,
    name: []const u8,
    stack: []StackEntry,
    sp: *usize,
    depth: usize,
) IrCodegenError!void {
    // Pop the depth literal from the abstract stack.
    sp.* -= 1;

    if (std.mem.eql(u8, name, "pick-n")) {
        // ( ... x_n ... x_0 n -- ... x_n ... x_0 x_n )
        // clone the entry at depth to the top
        const target = sp.* - 1 - depth;
        stack[sp.*] = try cloneStackEntry(state, state.base_addr, stack[target], sp.*);
        sp.* += 1;
    } else if (std.mem.eql(u8, name, "<rot-n")) {
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
    } else if (std.mem.eql(u8, name, "rot-n>")) {
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
    } else if (std.mem.eql(u8, name, "nip-n")) {
        // ( ...x1..xn y n -- y )
        // keep the top entry, drop depth entries beneath it
        if (depth == 0) return;
        const top = stack[sp.* - 1];
        sp.* -= depth;
        stack[sp.* - 1] = top;
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

/// Write all pending symbolic stack entries to their physical memory slots.
/// After this, every entry is materialized in the Value array at base_addr.
fn flushToPhysicalStack(state: *CompileState, stack: []StackEntry, sp: usize) void {
    const ctx = state.ctx;
    const base_addr = state.base_addr;

    // Preserve raw aliases whose source slot would be overwritten by
    // first-pass boxing before they get a chance to copy from it.
    for (0..sp) |i| {
        switch (stack[i]) {
            .raw_at_slot => |s| {
                if (s == i or s >= sp) continue;
                switch (stack[s]) {
                    .i64_ref, .f64_ref, .bool_ref => {
                        emitCopySlot(ctx, base_addr, s, i);
                        stack[i] = .{ .raw_at_slot = i };
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    // First pass: handle non-raw entries and detect swap patterns.
    for (0..sp) |i| {
        switch (stack[i]) {
            .i64_ref => |ref| {
                const slot_byte_offset = c.ir_const_addr(ctx, i * ValueLayout.value_size);
                const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                emitBoxPayload(ctx, dest_addr, state.tag_offset_const, state.payload_offset_const, state.fixnum_tag_const, ref);
                stack[i] = .{ .raw_at_slot = i };
            },
            .f64_ref => |ref| {
                const slot_byte_offset = c.ir_const_addr(ctx, i * ValueLayout.value_size);
                const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                emitBoxPayload(ctx, dest_addr, state.tag_offset_const, state.payload_offset_const, state.float_tag_const, ref);
                stack[i] = .{ .raw_at_slot = i };
            },
            .bool_ref => |ref| {
                const slot_byte_offset = c.ir_const_addr(ctx, i * ValueLayout.value_size);
                const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                emitBoxPayload(ctx, dest_addr, state.tag_offset_const, state.payload_offset_const, state.boolean_tag_const, ref);
                stack[i] = .{ .raw_at_slot = i };
            },
            .quotation_body => {},
            .raw_at_slot => {},
            .row_region => {},
        }
    }

    // Second pass: resolve raw_at_slot entries, using swap for cross-references.
    for (0..sp) |i| {
        switch (stack[i]) {
            .raw_at_slot => |s| {
                if (s != i) {
                    // Check for swap pattern: stack[i] -> s and stack[s] -> i
                    if (s < sp and stack[s].isAtSlot() and stack[s].slotIndex().? == i) {
                        emitSwapSlots(ctx, base_addr, i, s);
                        stack[i] = .{ .raw_at_slot = i };
                        stack[s] = .{ .raw_at_slot = s };
                    } else {
                        emitCopySlot(ctx, base_addr, s, i);
                        stack[i] = .{ .raw_at_slot = i };
                    }
                }
            },
            else => {},
        }
    }
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

    // Two-pass epilogue: relocate `raw_at_slot` entries first so copies read original physical
    // slot values before unboxing overwrites them.
    for (0..sp) |i| {
        switch (stack[i]) {
            .raw_at_slot => |s| {
                if (s != i) {
                    if (s < sp and stack[s].isAtSlot() and stack[s].slotIndex().? == i) {
                        emitSwapSlots(ctx, base_addr, i, s);
                        stack[s] = .{ .raw_at_slot = s };
                    } else {
                        emitCopySlot(ctx, base_addr, s, i);
                    }
                }
            },
            else => {},
        }
    }

    for (0..sp) |i| {
        switch (stack[i]) {
            .i64_ref => |ref| {
                const slot_byte_offset = c.ir_const_addr(ctx, i * ValueLayout.value_size);
                const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                emitBoxPayload(ctx, dest_addr, state.tag_offset_const, state.payload_offset_const, state.fixnum_tag_const, ref);
            },
            .f64_ref => |ref| {
                const slot_byte_offset = c.ir_const_addr(ctx, i * ValueLayout.value_size);
                const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                emitBoxPayload(ctx, dest_addr, state.tag_offset_const, state.payload_offset_const, state.float_tag_const, ref);
            },
            .bool_ref => |ref| {
                const slot_byte_offset = c.ir_const_addr(ctx, i * ValueLayout.value_size);
                const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                emitBoxPayload(ctx, dest_addr, state.tag_offset_const, state.payload_offset_const, state.boolean_tag_const, ref);
            },
            .quotation_body, .row_region => {
                state.not_compilable_reason = .quotation_truthiness;
                return IrCodegenError.NotCompilable;
            },
            .raw_at_slot => {},
        }
    }

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

    if (resolved.native_fn_ptr != null) {
        if (sp.* < resolved.input_count) return IrCodegenError.StackUnderflow;

        try materializeQuotations(state, stack, sp.*);
        flushToPhysicalStack(state, stack, sp.*);
        const ctx_val = emitCallbackPreamble(state, sp.*);

        if (resolved.stack_effect_ptr) |eff_ptr| {
            emitParamValidation(state, eff_ptr);
        }

        emitNativeWordCall(state, ctx_val, name, resolved, line);

        if (exitFallsThrough(state.exit_kind)) {
            sp.* = sp.* - resolved.input_count + resolved.output_count;
            resetStackToPhysical(stack, sp.*);
        }
    } else if (state.aot_mode) {
        // AOT mode: native_fn_ptr is unavailable; fall back to
        // jitInterpretedCall via the AOT word call path.
        if (sp.* < resolved.input_count) return IrCodegenError.StackUnderflow;

        try materializeQuotations(state, stack, sp.*);
        flushToPhysicalStack(state, stack, sp.*);
        const ctx_val = emitCallbackPreamble(state, sp.*);

        if (resolved.stack_effect_ptr) |eff_ptr| {
            emitParamValidation(state, eff_ptr);
        }

        emitAotWordCall(state, ctx_val, name, resolved, line);

        if (exitFallsThrough(state.exit_kind)) {
            sp.* = sp.* - resolved.input_count + resolved.output_count;
            resetStackToPhysical(stack, sp.*);
        }
    } else {
        state.not_compilable_reason = .unresolvable_word;
        return IrCodegenError.NotCompilable;
    }
}

/// Emit a polymorphic struct native call (make-struct-instance or
/// struct-instance-destructure). Derives input/output counts from the
/// struct_type in the preceding push_literal instruction.
fn emitStructNativeCall(
    state: *CompileState,
    instructions: []const Instruction,
    idx: usize,
    name: []const u8,
    stack: []StackEntry,
    sp: *usize,
    line: usize,
) IrCodegenError!void {
    // Extract struct_type from the preceding push_literal(.struct_type)
    if (idx < 1) {
        state.not_compilable_reason = .pre_scan_failure;
        return IrCodegenError.NotCompilable;
    }
    const struct_type_ptr: *const StructType = switch (instructions[idx - 1].op) {
        .push_literal => |v| if (v == .struct_type) v.struct_type else {
            state.not_compilable_reason = .pre_scan_failure;
            return IrCodegenError.NotCompilable;
        },
        else => {
            state.not_compilable_reason = .pre_scan_failure;
            return IrCodegenError.NotCompilable;
        },
    };

    const num_fields: u8 = @intCast(struct_type_ptr.fields.len);
    const is_constructor = std.mem.eql(u8, name, "native.make-struct-instance");

    // make-struct-instance: ( field1..fieldN struct_type -- instance )
    // struct-instance-destructure: ( instance struct_type -- field1..fieldN )
    const effective_in: u8 = if (is_constructor) num_fields + 1 else 2;
    const effective_out: u8 = if (is_constructor) 1 else num_fields;

    if (sp.* < effective_in) return IrCodegenError.StackUnderflow;

    try materializeQuotations(state, stack, sp.*);
    flushToPhysicalStack(state, stack, sp.*);
    const ctx_val = emitCallbackPreamble(state, sp.*);

    const res = state.resolver orelse {
        state.not_compilable_reason = .unresolvable_word;
        return IrCodegenError.NotCompilable;
    };
    const resolved = res.resolve(name, res.user_data) orelse {
        state.not_compilable_reason = .unresolvable_word;
        return IrCodegenError.NotCompilable;
    };

    emitAotWordCall(state, ctx_val, name, resolved, line);

    if (exitFallsThrough(state.exit_kind)) {
        sp.* = sp.* - effective_in + effective_out;
        resetStackToPhysical(stack, sp.*);
    }
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
    const payload_val = c._ir_LOAD(ctx, c.IR_BOOL, payload_addr);
    const false_const = c.ir_const_bool(ctx, false);
    const is_false_payload = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), payload_val, false_const);
    const is_falsy = c.ir_fold2(ctx, c.IR_OPT(c.IR_AND, c.IR_BOOL), is_bool_tag, is_false_payload);
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
        state.noteAotFallbackEmission();
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
        state.noteAotFallbackEmission();
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
    const base_addr = state.base_addr;

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

    const truthy = try emitTruthiness(state, cond_entry, base_addr);
    const continue_cond = if (negate_cond)
        c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), truthy, c.ir_const_bool(ctx, false))
    else
        truthy;

    flushToPhysicalStack(state, stack, sp.*);

    const if_continue = c._ir_IF(ctx, continue_cond);

    c._ir_IF_TRUE(ctx, if_continue);

    // Execute body
    switch (body_entry) {
        .quotation_body => |body| {
            resetStackToPhysicalPreservingRows(stack, sp.*);
            try compileInstructions(state, body, stack, sp);
            if (!symbolicShapeMatches(stack, sp.*, loop_entry_stack, loop_entry_sp)) return IrCodegenError.StackShapeMismatch;
            flushToPhysicalStack(state, stack, sp.*);
        },
        .raw_at_slot => |s| {
            try emitIndirectQuotCall(state, stack, sp, s, 0);
        },
        else => {
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
/// Recognizes the pattern: push_literal(fixnum=vtypePtr) + call_word("native.virtual-unwrap").
/// Returns true if inlined; false to fall back to runtime callback.
fn tryEmitInlineVirtualUnwrap(
    state: *CompileState,
    instructions: []const Instruction,
    idx: usize,
    stack: []StackEntry,
    sp: *usize,
) bool {
    if (sp.* < 2) return false;

    // virtual type pointer must be a constant fixnum from the preceding instruction
    const vtype_fixnum: i64 = if (idx > 0) blk: {
        break :blk switch (instructions[idx - 1].op) {
            .push_literal => |v| if (v == .fixnum) v.fixnum else return false,
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
    const expected_vtype = c.ir_const_addr(ctx, @as(usize, @intCast(vtype_fixnum)));
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
/// Recognizes the pattern: push_literal(fixnum=vtypePtr) + call_word("native.typed-validate-and-promote").
/// Returns true if inlined; false to fall back to runtime callback.
fn tryEmitInlineTypedValidateAndPromote(
    state: *CompileState,
    instructions: []const Instruction,
    idx: usize,
    stack: []StackEntry,
    sp: *usize,
) bool {
    if (sp.* < 2) return false;

    // virtual type pointer must be a constant fixnum from the preceding instruction
    const vtype_fixnum: i64 = if (idx > 0) blk: {
        break :blk switch (instructions[idx - 1].op) {
            .push_literal => |v| if (v == .fixnum) v.fixnum else return false,
            else => return false,
        };
    } else return false;

    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(vtype_fixnum)));

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
    materializeQuotations(state, stack, sp.*) catch return false;
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

    // Copy a1 to slot 2, a2 to slot 3 (quotation consumption copies).
    emitCopySlot(ctx, base_addr, a1_slot, 2);
    emitCopySlot(ctx, base_addr, a2_slot, 3);
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
        state.noteAotFallbackEmission();
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
    // a1 already at output_slot — no copy needed.
    const true_end = c._ir_END(ctx);

    c._ir_IF_FALSE(ctx, if_ref);
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

/// Compile a sequence of instructions, updating the abstract stack.
/// Used both for top-level word bodies and for inlined quotation bodies.
fn compileInstructions(
    state: *CompileState,
    instructions: []const Instruction,
    stack: []StackEntry,
    sp: *usize,
) IrCodegenError!void {
    const ctx = state.ctx;
    const base_addr = state.base_addr;
    const bail_status = state.bail_status;

    for (instructions, 0..) |instr, idx| {
        if (state.dynamic_call_emitted) {
            state.not_compilable_reason = .post_dynamic_call;
            return IrCodegenError.NotCompilable;
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
                } else if (state.aot_mode and (val == .type_val or val == .tagged or val == .parameter or val == .marker)) {
                    // Non-simple literals from named words (type values, enum
                    // variants, parameter definitions, markers). Emit a callback
                    // that looks up the word at runtime and pushes its literal value.
                    const lit_name = switch (val) {
                        .type_val => |tv| tv.name,
                        .tagged => |t| t.tag.name,
                        .parameter => |p| p.name,
                        .marker => |mk| mk.name,
                        else => unreachable,
                    };

                    const proto_3arg = c.ir_proto_3(ctx, 0, c.IR_I32, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR);
                    const push_fn = c.ir_const_func(ctx, c.ir_str(ctx, "onez_push_word_literal"), proto_3arg);

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

                    const lit_id = if (state.aot_string_literals) |lits| lits.items.len else 0;
                    var sym_buf: [32]u8 = undefined;
                    const sym_name = std.fmt.bufPrint(&sym_buf, "onez_lit_{d}", .{lit_id}) catch unreachable;
                    const sym_ref = c.ir_const_func(ctx, c.ir_strl(ctx, &sym_buf, sym_name.len), 0);
                    const name_len_const = c.ir_const_addr(ctx, lit_name.len);

                    const call_result = c._ir_CALL_3(ctx, c.IR_I32, push_fn, ctx_val, sym_ref, name_len_const);
                    emitCallbackPostCheck(state, call_result, state.error_propagate_status, null, .none);

                    if (state.aot_string_literals) |lits| {
                        lits.append(std.heap.page_allocator, .{
                            .data = lit_name,
                            .is_symbol = false,
                        }) catch {};
                    }

                    // Re-read sp after callback (it pushed one value).
                    _ = c._ir_LOAD(ctx, c.IR_ADDR, state.sp_ptr);
                    stack[sp.*] = .{ .raw_at_slot = sp.* };
                    sp.* += 1;
                } else if (state.aot_mode and val == .struct_type) {
                    // struct_type literals: look up the constructor word at
                    // runtime to recover the runtime struct_type pointer.
                    const struct_name = val.struct_type.name;

                    const proto_3arg = c.ir_proto_3(ctx, 0, c.IR_I32, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR);
                    const push_fn = c.ir_const_func(ctx, c.ir_str(ctx, "onez_push_struct_type"), proto_3arg);

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

                    const lit_id = if (state.aot_string_literals) |lits| lits.items.len else 0;
                    var sym_buf: [32]u8 = undefined;
                    const sym_name = std.fmt.bufPrint(&sym_buf, "onez_lit_{d}", .{lit_id}) catch unreachable;
                    const sym_ref = c.ir_const_func(ctx, c.ir_strl(ctx, &sym_buf, sym_name.len), 0);
                    const name_len_const = c.ir_const_addr(ctx, struct_name.len);

                    const call_result = c._ir_CALL_3(ctx, c.IR_I32, push_fn, ctx_val, sym_ref, name_len_const);
                    emitCallbackPostCheck(state, call_result, state.error_propagate_status, null, .none);

                    if (state.aot_string_literals) |lits| {
                        lits.append(std.heap.page_allocator, .{
                            .data = struct_name,
                            .is_symbol = false,
                        }) catch {};
                    }

                    // Re-read sp after callback (it pushed one value).
                    _ = c._ir_LOAD(ctx, c.IR_ADDR, state.sp_ptr);
                    stack[sp.*] = .{ .raw_at_slot = sp.* };
                    sp.* += 1;
                } else if (state.aot_mode and (val == .array or val == .hash)) {
                    // Array/hash literals: serialize to bytes, store in C
                    // preamble, and emit a callback to deserialize at runtime.
                    var ser_buf: std.ArrayListUnmanaged(u8) = .{};
                    serializeValueInto(&ser_buf, val, std.heap.page_allocator) catch {
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
                    const sp_byte_offset = c.ir_const_addr(ctx, sp.* * ValueLayout.value_size);
                    const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, sp_byte_offset);
                    emitPushValue(ctx, &val, dest_addr);
                    stack[sp.*] = .{ .raw_at_slot = sp.* };
                    sp.* += 1;
                }
            },
            .call_word => |name| {
                if (std.mem.eql(u8, name, "dup")) {
                    if (sp.* < 1) return IrCodegenError.StackUnderflow;
                    stack[sp.*] = try cloneStackEntry(state, base_addr, stack[sp.* - 1], sp.*);
                    sp.* += 1;
                } else if (std.mem.eql(u8, name, "drop")) {
                    if (sp.* < 1) return IrCodegenError.StackUnderflow;
                    sp.* -= 1;
                } else if (std.mem.eql(u8, name, "swap")) {
                    if (sp.* < 2) return IrCodegenError.StackUnderflow;
                    const top = stack[sp.* - 1];
                    const second = stack[sp.* - 2];
                    // Track swap abstractly without physical modification.
                    // flushToPhysicalStack resolves cross-references later.
                    stack[sp.* - 2] = top;
                    stack[sp.* - 1] = second;
                } else if (std.mem.eql(u8, name, "over")) {
                    if (sp.* < 2) return IrCodegenError.StackUnderflow;
                    stack[sp.*] = try cloneStackEntry(state, base_addr, stack[sp.* - 2], sp.*);
                    sp.* += 1;
                } else if (std.mem.eql(u8, name, "t")) {
                    stack[sp.*] = .{ .bool_ref = c.ir_const_bool(ctx, true) };
                    sp.* += 1;
                } else if (std.mem.eql(u8, name, "f")) {
                    stack[sp.*] = .{ .bool_ref = c.ir_const_bool(ctx, false) };
                    sp.* += 1;
                } else if (std.mem.eql(u8, name, "abs")) {
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
                } else if (isComparisonOp(name)) {
                    if (sp.* < 2) return IrCodegenError.StackUnderflow;
                    sp.* -= 2;

                    // When both operands are runtime unknowns and a resolver
                    // is available, delegate to the polymorphic native
                    // directly. resolveOperandPair would optimistically assume
                    // i64 and emit a fixnum tag check that bails for
                    // non-numeric types (type values, strings, etc.).
                    if (stack[sp.*] == .raw_at_slot and stack[sp.* + 1] == .raw_at_slot and state.resolver != null) {
                        sp.* += 2;
                        try emitResolvedNativeCallback(state, name, stack, sp, instr.line);
                        continue;
                    }

                    const resolved = resolveOperandPair(stack[sp.*], stack[sp.* + 1], state) catch |err| switch (err) {
                        IrCodegenError.NotCompilable => {
                            // Operands are not numeric (e.g., bool_ref vs raw_at_slot).
                            // Fall back to the polymorphic native comparison.
                            sp.* += 2;
                            try emitResolvedNativeCallback(state, name, stack, sp, instr.line);
                            continue;
                        },
                        else => return err,
                    };

                    const ir_op: c_uint = if (std.mem.eql(u8, name, "="))
                        c.IR_EQ
                    else if (std.mem.eql(u8, name, "<"))
                        c.IR_LT
                    else
                        c.IR_GT;

                    const result = switch (resolved) {
                        .i64_pair => |p| c.ir_fold2(ctx, c.IR_OPT(ir_op, c.IR_BOOL), p.a, p.b),
                        .f64_pair => |p| c.ir_fold2(ctx, c.IR_OPT(ir_op, c.IR_BOOL), p.a, p.b),
                    };
                    stack[sp.*] = .{ .bool_ref = result };
                    sp.* += 1;
                } else if (std.mem.eql(u8, name, "if")) {
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
                            continue;
                        },
                        .raw_at_slot => |s| emitSlotTruthiness(ctx, base_addr, s, state),
                        .row_region => {
                            state.not_compilable_reason = .quotation_truthiness;
                            return IrCodegenError.NotCompilable;
                        },
                    };

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
                    state.exit_kind = .falls_through;
                    const saved_inline_trace_frame_count = state.inline_trace_frame_count;
                    if (traceFramesEnabled(state) and state.inline_trace_frame_count < max_inline_trace_frames) {
                        state.inline_trace_frames[state.inline_trace_frame_count] = .{
                            .kind = .if_op,
                            .line = instr.line,
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
                        flushToPhysicalStack(state, stack, sp.*);
                        end_true = c._ir_END(ctx);
                    }

                    // Restore items_ptr/base_addr before the false branch so
                    // it uses refs from before the IF that dominate both paths.
                    state.items_ptr = saved_items_ptr;
                    state.base_addr = saved_base_addr;

                    // Emit false branch
                    c._ir_IF_FALSE(ctx, if_ref);
                    var false_sp = saved_sp;
                    state.exit_kind = .falls_through;
                    if (traceFramesEnabled(state)) state.inline_trace_frame_count = saved_inline_trace_frame_count;
                    if (traceFramesEnabled(state) and state.inline_trace_frame_count < max_inline_trace_frames) {
                        state.inline_trace_frames[state.inline_trace_frame_count] = .{
                            .kind = .if_op,
                            .line = instr.line,
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
                        const end_false = c._ir_END(ctx);
                        c._ir_MERGE_2(ctx, end_true, end_false);
                        if (!symbolicShapeMatches(stack, sp.*, saved_stack, false_sp)) return IrCodegenError.StackShapeMismatch;
                        if (state.refresh_stack_fn != c.IR_UNUSED) {
                            refreshCachedStackPointer(state);
                        }
                        resetStackToPhysicalPreservingRows(stack, sp.*);
                        state.exit_kind = saved_exit_kind;
                        state.loop_end_set = saved_loop_end_set;
                    }
                } else if (std.mem.eql(u8, name, "call")) {
                    if (sp.* < 1) return IrCodegenError.StackUnderflow;
                    sp.* -= 1;
                    const entry = stack[sp.*];
                    switch (entry) {
                        .quotation_body => |body| {
                            const saved_inline_trace_frame_count = state.inline_trace_frame_count;
                            if (traceFramesEnabled(state) and state.inline_trace_frame_count < max_inline_trace_frames) {
                                state.inline_trace_frames[state.inline_trace_frame_count] = .{
                                    .kind = .call,
                                    .line = instr.line,
                                };
                                state.inline_trace_frame_count += 1;
                            }
                            try compileInstructions(state, body, stack, sp);
                            if (traceFramesEnabled(state)) state.inline_trace_frame_count = saved_inline_trace_frame_count;
                        },
                        .raw_at_slot => |s| {
                            {
                                const slot_byte_offset = c.ir_const_addr(ctx, s * ValueLayout.value_size);
                                const elem_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);

                                // Check tag is quotation
                                const quotation_tag_const = emitTagConst(ctx, .quotation);
                                emitTagCheck(ctx, elem_addr, quotation_tag_const, state.tag_offset_const, bail_status);

                                // Load code_ptr from the quotation's payload
                                const code_ptr_off = c.ir_const_addr(ctx, ValueLayout.quotation_code_ptr_offset);
                                const code_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, code_ptr_off);
                                const code_ptr_val = c._ir_LOAD(ctx, c.IR_ADDR, code_ptr_addr);

                                // Null-check code_ptr
                                const null_addr = c.ir_const_addr(ctx, 0);
                                const is_null = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), code_ptr_val, null_addr);
                                const if_null = c._ir_IF(ctx, is_null);

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
                                    state.noteAotFallbackEmission();
                                    const fb_result = c._ir_CALL_1(ctx, c.IR_I32, call_quot_fn, ctx_val);
                                    emitCallbackPostCheck(state, fb_result, state.error_propagate_status, null, .{ .builtin = .{ .kind = .call, .line = instr.line } });
                                }
                                const end_fallback = c._ir_END(ctx);

                                // Hot path: quotation is compiled, call directly
                                c._ir_IF_FALSE(ctx, if_null);
                                {
                                    flushToPhysicalStack(state, stack, sp.*);

                                    const new_sp_const = c.ir_const_addr(ctx, sp.*);
                                    const new_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, new_sp_const);
                                    c._ir_STORE(ctx, state.sp_ptr, new_sp);

                                    const call_result = if (state.aot_mode)
                                        c._ir_CALL_2(ctx, c.IR_I32, state.call_code_ptr_fn, state.jit_ctx_ptr, code_ptr_val)
                                    else
                                        c._ir_CALL_1(ctx, c.IR_I32, code_ptr_val, state.jit_ctx_ptr);
                                    emitCallbackPostCheck(state, call_result, call_result, null, .{ .builtin = .{ .kind = .call, .line = instr.line } });
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
                                // continue compiling.
                                reloadBaseAfterDynamicCall(state);
                                sp.* = 1;
                                stack[0] = .{ .row_region = state.nextRowId() };
                            }
                        },
                        .i64_ref, .f64_ref, .bool_ref, .row_region => {
                            state.not_compilable_reason = .quotation_reification;
                            return IrCodegenError.NotCompilable;
                        },
                    }
                } else if (std.mem.eql(u8, name, "times")) {
                    if (sp.* < 2) return IrCodegenError.StackUnderflow;
                    sp.* -= 2;
                    const n_entry = stack[sp.*];
                    const quot_entry = stack[sp.* + 1];

                    const initial_n = try requireI64(n_entry, state);

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
                            try emitIndirectQuotCall(state, stack, sp, s, instr.line);
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
                } else if (std.mem.eql(u8, name, "loop")) {
                    if (sp.* < 1) return IrCodegenError.StackUnderflow;
                    sp.* -= 1;
                    const pred_entry = stack[sp.*];

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

                    // Execute predicate body
                    const pre_body_sp = sp.*;
                    switch (pred_entry) {
                        .quotation_body => |body| {
                            resetStackToPhysicalPreservingRows(stack, sp.*);
                            try compileInstructions(state, body, stack, sp);
                        },
                        .raw_at_slot => |s| {
                            try emitIndirectQuotCall(state, stack, sp, s, instr.line);
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

                    const continue_cond = try emitTruthiness(state, cond_entry, base_addr);

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
                } else if (std.mem.eql(u8, name, "while") or std.mem.eql(u8, name, "until")) {
                    if (sp.* < 2) return IrCodegenError.StackUnderflow;
                    sp.* -= 2;
                    const pred_entry = stack[sp.*];
                    const body_entry = stack[sp.* + 1];
                    try compilePredBodyLoop(state, stack, sp, pred_entry, body_entry, std.mem.eql(u8, name, "until"));
                } else if (std.mem.eql(u8, name, "choose")) {
                    // choose: ( a1 a2 quot -- a )
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

                            // Copy a1/a2 for quotation consumption.
                            emitCopySlot(ctx, base_addr, output_slot, output_slot + 2);
                            emitCopySlot(ctx, base_addr, output_slot + 1, output_slot + 3);
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
                            const cond_ref = try emitTruthiness(state, result_entry, base_addr);

                            // Branch: truthy keeps a1, falsy keeps a2.
                            const if_ref = c._ir_IF(ctx, cond_ref);

                            c._ir_IF_TRUE(ctx, if_ref);
                            // a1 already at output_slot — nothing to copy.
                            const true_end = c._ir_END(ctx);

                            c._ir_IF_FALSE(ctx, if_ref);
                            emitCopySlot(ctx, base_addr, output_slot + 1, output_slot);
                            const false_end = c._ir_END(ctx);

                            c._ir_MERGE_2(ctx, true_end, false_end);

                            sp.* = output_slot + 1;
                            stack[output_slot] = .{ .raw_at_slot = output_slot };
                        },
                        .raw_at_slot => |quot_slot| {
                            // Dynamic quotation: load code_ptr before rearranging.
                            const quot_byte_offset = c.ir_const_addr(ctx, quot_slot * ValueLayout.value_size);
                            const quot_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, quot_byte_offset);

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

                            // Copy a1/a2 for quotation consumption.
                            emitCopySlot(ctx, base_addr, output_slot, output_slot + 2);
                            emitCopySlot(ctx, base_addr, output_slot + 1, output_slot + 3);
                            // Copy quotation to slot after the copies.
                            emitCopySlot(ctx, base_addr, quot_slot, output_slot + 4);

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
                                state.noteAotFallbackEmission();
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
                            const true_end = c._ir_END(ctx);

                            c._ir_IF_FALSE(ctx, if_ref);
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
                } else if (isBinaryOp(name)) {
                    if (sp.* < 2) return IrCodegenError.StackUnderflow;
                    sp.* -= 2;

                    const entry_a = stack[sp.*];
                    const entry_b = stack[sp.* + 1];

                    // When both operands are raw_at_slot (runtime unknowns) and the
                    // operation supports float, emit polymorphic code that branches
                    // on fixnum vs float at runtime instead of bailing on type mismatch.
                    const poly_op: ?PolyArithOp = if (entry_a == .raw_at_slot and entry_b == .raw_at_slot)
                        polyArithOpFromName(name)
                    else
                        null;

                    if (poly_op) |op| {
                        // Polymorphic arith writes directly to a physical slot. If any entry below the operands
                        // aliases `dest_slot`, save dest_slot to a scratch slot first so the write doesn't
                        // clobber the aliased value.
                        const dest_slot = sp.*;
                        const scratch = @max(dest_slot, @max(entry_a.raw_at_slot, entry_b.raw_at_slot)) + 1;
                        for (0..sp.*) |j| {
                            if (stack[j] == .raw_at_slot and stack[j].raw_at_slot == dest_slot) {
                                emitCopySlot(ctx, base_addr, dest_slot, scratch);
                                stack[j] = .{ .raw_at_slot = scratch };
                                break;
                            }
                        }
                        emitPolymorphicBinaryArith(state, entry_a.raw_at_slot, entry_b.raw_at_slot, dest_slot, op, instr.line);
                        stack[sp.*] = .{ .raw_at_slot = sp.* };
                        sp.* += 1;
                    } else if (std.mem.eql(u8, name, "div")) {
                        // div and rem are integer-only; resolve both operands as i64.
                        const a = try requireI64(entry_a, state);
                        const b = try requireI64(entry_b, state);
                        stack[sp.*] = .{ .i64_ref = emitDivision(ctx, a, b, bail_status) };
                        sp.* += 1;
                    } else if (std.mem.eql(u8, name, "rem")) {
                        const a = try requireI64(entry_a, state);
                        const b = try requireI64(entry_b, state);
                        stack[sp.*] = .{ .i64_ref = emitRemainder(ctx, a, b, bail_status) };
                        sp.* += 1;
                    } else if (std.mem.eql(u8, name, "%")) {
                        const a = try requireI64(entry_a, state);
                        const b = try requireI64(entry_b, state);
                        stack[sp.*] = .{ .i64_ref = emitEuclideanMod(ctx, a, b, bail_status) };
                        sp.* += 1;
                    } else {
                        // +, -, *, / support both i64 and f64 operands.
                        const resolved = try resolveOperandPair(entry_a, entry_b, state);
                        switch (resolved) {
                            .i64_pair => |p| {
                                if (std.mem.eql(u8, name, "+")) {
                                    stack[sp.*] = .{ .i64_ref = emitOverflowCheckedBinary(ctx, c.IR_ADD_OV, p.a, p.b, bail_status) };
                                } else if (std.mem.eql(u8, name, "-")) {
                                    stack[sp.*] = .{ .i64_ref = emitOverflowCheckedBinary(ctx, c.IR_SUB_OV, p.a, p.b, bail_status) };
                                } else if (std.mem.eql(u8, name, "*")) {
                                    stack[sp.*] = .{ .i64_ref = emitOverflowCheckedBinary(ctx, c.IR_MUL_OV, p.a, p.b, bail_status) };
                                } else {
                                    // "/"
                                    stack[sp.*] = .{ .i64_ref = emitDivision(ctx, p.a, p.b, bail_status) };
                                }
                            },
                            .f64_pair => |p| {
                                const ir_op: c_uint = if (std.mem.eql(u8, name, "+"))
                                    c.IR_ADD
                                else if (std.mem.eql(u8, name, "-"))
                                    c.IR_SUB
                                else if (std.mem.eql(u8, name, "*"))
                                    c.IR_MUL
                                else
                                    c.IR_DIV;
                                stack[sp.*] = .{ .f64_ref = c.ir_fold2(ctx, c.IR_OPT(ir_op, c.IR_DOUBLE), p.a, p.b) };
                            },
                        }
                        sp.* += 1;
                    }
                } else if (isErrorHandlingOp(name)) {
                    if (sp.* < 2) return IrCodegenError.StackUnderflow;

                    try materializeQuotations(state, stack, sp.*);
                    flushToPhysicalStack(state, stack, sp.*);
                    const ctx_val = emitCallbackPreamble(state, sp.*);

                    const callback_fn = if (std.mem.eql(u8, name, "recover"))
                        state.recover_fn
                    else
                        state.cleanup_fn;

                    const call_result = c._ir_CALL_1(ctx, c.IR_I32, callback_fn, ctx_val);
                    const frame_kind: BuiltinTraceFrameKind = if (std.mem.eql(u8, name, "recover")) .recover else .cleanup;
                    emitCallbackPostCheck(state, call_result, call_result, null, .{ .builtin = .{ .kind = frame_kind, .line = instr.line } });

                    sp.* -= 2;
                    state.dynamic_call_emitted = true;
                    state.error_handler_terminal = true;
                } else if (isDynamicVarOp(name)) {
                    const is_get = std.mem.eql(u8, name, "get");
                    const required: usize = if (is_get) 1 else 3;
                    if (sp.* < required) return IrCodegenError.StackUnderflow;

                    try materializeQuotations(state, stack, sp.*);
                    flushToPhysicalStack(state, stack, sp.*);
                    const ctx_val = emitCallbackPreamble(state, sp.*);

                    const callback_fn = if (is_get) state.get_fn else state.with_parameter_fn;
                    const call_result = c._ir_CALL_1(ctx, c.IR_I32, callback_fn, ctx_val);
                    emitCallbackPostCheck(state, call_result, call_result, null, .none);

                    if (is_get) {
                        // get: pops 1 param, pushes 1 value (net 0)
                        resetStackToPhysical(stack, sp.*);
                    } else {
                        // with-parameter: body quotation has unknown stack effects
                        sp.* -= 3;
                        state.dynamic_call_emitted = true;
                    }
                } else if (isIteratorOp(name)) {
                    const opcode = iteratorOpcodeFromName(name).?;
                    const effects = iteratorEffects(opcode);
                    if (sp.* < effects.inputs) return IrCodegenError.StackUnderflow;

                    try materializeQuotations(state, stack, sp.*);
                    flushToPhysicalStack(state, stack, sp.*);
                    const ctx_val = emitCallbackPreamble(state, sp.*);

                    if (effects.dynamic) {
                        if (state.interp_ctx) |ictx| {
                            if (ictx.lookupWordStackEffectPtr(name)) |eff_ptr| {
                                emitParamValidation(state, @intFromPtr(eff_ptr));
                            }
                        }
                    }

                    const opcode_const = c.ir_const_addr(ctx, @intFromEnum(opcode));
                    const call_result = c._ir_CALL_2(ctx, c.IR_I32, state.iterator_fn, ctx_val, opcode_const);
                    emitCallbackPostCheck(state, call_result, call_result, null, .none);

                    sp.* = sp.* - effects.inputs + effects.outputs;
                    resetStackToPhysical(stack, sp.*);
                } else if (
                // oh, yuck
                state.self_name != null and
                    state.loop_begin_ref != c.IR_UNUSED and
                    idx == instructions.len - 1 and
                    std.mem.eql(u8, name, state.self_name.?))
                {
                    // Self-recursive tail call: emit back-edge to LOOP_BEGIN
                    const ic = state.input_count;
                    if (sp.* < ic) return IrCodegenError.StackUnderflow;

                    // Bail if both if-branches already set a loop end
                    if (state.loop_end_set) {
                        state.not_compilable_reason = .nested_loop_conflict;
                        return IrCodegenError.NotCompilable;
                    }

                    // Flush symbolic stack to physical memory
                    flushToPhysicalStack(state, stack, sp.*);

                    // Copy new arguments to input slots (positions 0..input_count-1)
                    const arg_base = sp.* - ic;
                    if (arg_base > 0) {
                        for (0..ic) |i| {
                            emitCopySlot(ctx, base_addr, arg_base + i, i);
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
                            emitCopySlot(ctx, base_addr, arg_base + i, i);
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
                } else if (std.mem.eql(u8, name, "native.virtual-unwrap")) {
                    if (state.aot_mode) {
                        state.not_compilable_reason = .non_serializable_literal;
                        return IrCodegenError.NotCompilable;
                    }
                    if (!tryEmitInlineVirtualUnwrap(state, instructions, idx, stack, sp)) {
                        try emitResolvedNativeCallback(state, name, stack, sp, instr.line);
                    }
                } else if (std.mem.eql(u8, name, "native.struct-field-get")) {
                    if (!tryEmitInlineStructFieldGet(state, instructions, idx, stack, sp)) {
                        try emitResolvedNativeCallback(state, name, stack, sp, instr.line);
                    }
                } else if (std.mem.eql(u8, name, "native.struct-field-set")) {
                    if (!tryEmitInlineStructFieldSet(state, instructions, idx, stack, sp)) {
                        try emitResolvedNativeCallback(state, name, stack, sp, instr.line);
                    }
                } else if (std.mem.eql(u8, name, "native.typed-validate-and-promote")) {
                    if (state.aot_mode) {
                        state.not_compilable_reason = .non_serializable_literal;
                        return IrCodegenError.NotCompilable;
                    }
                    if (!tryEmitInlineTypedValidateAndPromote(state, instructions, idx, stack, sp)) {
                        try emitResolvedNativeCallback(state, name, stack, sp, instr.line);
                    }
                } else if (std.mem.eql(u8, name, "native.make-struct-instance") or
                    std.mem.eql(u8, name, "native.struct-instance-destructure"))
                {
                    // Polymorphic struct operations: derive input/output counts
                    // from the struct_type in the preceding push_literal.
                    try emitStructNativeCall(state, instructions, idx, name, stack, sp, instr.line);
                } else if (std.mem.eql(u8, name, "native.struct-instance-to-hash") or
                    std.mem.eql(u8, name, "native.struct-type-predicate") or
                    std.mem.eql(u8, name, "native.hash-to-struct"))
                {
                    try emitResolvedNativeCallback(state, name, stack, sp, instr.line);
                } else if (state.aot_mode and isRuntimeVirtualPtrNative(name)) {
                    state.not_compilable_reason = .non_serializable_literal;
                    return IrCodegenError.NotCompilable;
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

                    // Indexed stack ops: reject when the literal depth targets the symbolic row interior.
                    // When a row_region exists and the access is legal, do a compile-time symbolic rewrite
                    // instead of the native callback, which would lose the row_region.
                    if (isIndexedStackOp(name)) {
                        const depth = extractPrecedingLiteralDepth(instructions, idx) orelse {
                            state.not_compilable_reason = .indexed_access_into_row;
                            return IrCodegenError.NotCompilable;
                        };
                        // The depth argument is on top of the abstract stack.
                        // After popping it, the deepest position the operation
                        // can touch is sp - 2 - depth (0-indexed from bottom).
                        if (sp.* >= 2 and depth <= sp.* - 2) {
                            const target = sp.* - 2 - depth;
                            if (findRowRegionIndex(stack, sp.*)) |row_idx| {
                                if (target <= row_idx) {
                                    state.not_compilable_reason = .indexed_access_into_row;
                                    return IrCodegenError.NotCompilable;
                                }
                                // Row exists but access targets known slots.
                                // Rewrite the StackEntry array directly
                                // instead of calling the native function.
                                try rewriteIndexedStackOp(state, name, stack, sp, depth);
                                continue;
                            }
                        }
                    }

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
                            try materializeQuotations(state, stack, sp.*);
                            flushToPhysicalStack(state, stack, sp.*);
                            const ctx_val = emitCallbackPreamble(state, sp.*);
                            emitAotWordCall(state, ctx_val, name, resolved, instr.line);
                            if (exitFallsThrough(state.exit_kind)) {
                                reloadBaseAfterDynamicCall(state);
                                sp.* = 1;
                                stack[0] = .{ .row_region = state.nextRowId() };
                                continue;
                            }
                            break;
                        } else {
                            state.not_compilable_reason = .unresolvable_word;
                            return IrCodegenError.NotCompilable;
                        }
                    }

                    if (resolved.native_fn_ptr != null) {
                        // Generic native word callback
                        if (sp.* < effective_in) return IrCodegenError.StackUnderflow;

                        try materializeQuotations(state, stack, sp.*);
                        flushToPhysicalStack(state, stack, sp.*);
                        const ctx_val = emitCallbackPreamble(state, sp.*);

                        if (resolved.stack_effect_ptr) |eff_ptr| {
                            emitParamValidation(state, eff_ptr);
                        }

                        // Try inline PIC (from interpreter profiling) or
                        // dispatch-table-driven inline checks (from frozen
                        // dispatch table) before falling back to generic
                        // native call. Both include the slow-path fallback
                        // internally, so when either succeeds no separate
                        // call is needed.
                        if (!emitInlinePicCheck(state, idx, ctx_val, name, resolved, effective_in, instr.line) and
                            !emitInlineDispatchTableCheck(state, ctx_val, name, resolved, effective_in, instr.line))
                        {
                            emitNativeWordCall(state, ctx_val, name, resolved, instr.line);
                        }

                        if (exitFallsThrough(state.exit_kind)) {
                            // Adjust abstract stack by specialized effect
                            const had_row = sp.* > 0 and stack[0].isRowRegion();
                            sp.* = sp.* - effective_in + effective_out;
                            if (had_row and sp.* == 0) {
                                // The call consumed all known entries above
                                // the row_region. Reload physical sp and
                                // keep the row_region for subsequent code.
                                reloadBaseAfterDynamicCall(state);
                                sp.* = 1;
                            } else {
                                resetStackToPhysical(stack, sp.*);
                            }
                        }
                    } else if (state.aot_mode) {
                        // AOT mode: direct call by name or interpreter fallback
                        if (sp.* < effective_in) return IrCodegenError.StackUnderflow;

                        try materializeQuotations(state, stack, sp.*);
                        flushToPhysicalStack(state, stack, sp.*);
                        const ctx_val = emitCallbackPreamble(state, sp.*);

                        if (resolved.stack_effect_ptr) |eff_ptr| {
                            emitParamValidation(state, eff_ptr);
                        }

                        emitAotWordCall(state, ctx_val, name, resolved, instr.line);

                        if (exitFallsThrough(state.exit_kind)) {
                            const had_row = sp.* > 0 and stack[0].isRowRegion();
                            sp.* = sp.* - effective_in + effective_out;
                            if (had_row and sp.* == 0) {
                                reloadBaseAfterDynamicCall(state);
                                sp.* = 1;
                            } else {
                                resetStackToPhysical(stack, sp.*);
                            }
                        }
                    } else {
                        // Compound word: dispatch table indirect call
                        DispatchLayout.ensureInit();

                        if (sp.* < effective_in) return IrCodegenError.StackUnderflow;

                        try materializeQuotations(state, stack, sp.*);
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
                            const line_const = c.ir_const_addr(ctx, instr.line);
                            state.noteAotFallbackEmission();
                            const fb_result = c._ir_CALL_3(ctx, c.IR_I32, state.interpreted_call_fn, ctx_val2, word_id_const, line_const);
                            emitCallbackPostCheck(state, fb_result, state.error_propagate_status, if (resolved.never_returns) state.error_propagate_status else null, .none);
                        }
                        const end_fallback = if (resolved.never_returns) c.IR_UNUSED else c._ir_END(ctx);

                        // Hot path: callee is compiled, call directly
                        c._ir_IF_FALSE(ctx, if_null);
                        {
                            const call_result = c._ir_CALL_1(ctx, c.IR_I32, callee_code_ptr, state.jit_ctx_ptr);
                            emitCallbackPostCheck(state, call_result, call_result, if (resolved.never_returns) state.error_propagate_status else null, .{ .named = .{ .name = name, .line = instr.line } });
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

                            // Adjust abstract stack based on specialized effect
                            sp.* = sp.* - effective_in + effective_out;
                            resetStackToPhysical(stack, sp.*);
                        }
                    }
                }
            },
        }

        if (sp.* > state.peak_sp) state.peak_sp = @intCast(sp.*);
        if (!exitFallsThrough(state.exit_kind)) break;
    }
}

/// Merge two stack entries from the true and false branches of an if.
/// After an ir MERGE of two branches, a PHI node selects which branch's
/// value to use based on which path was actually taken at runtime.
/// For raw_at_slot merging is limited to same-slot cases: if both branches
/// wrote to the same physical slot, no copy is needed since the taken branch
/// already placed its value there.
fn mergeEntries(
    ctx: *c.ir_ctx,
    true_entry: StackEntry,
    false_entry: StackEntry,
    slot: usize,
    base_addr: c.ir_ref,
) IrCodegenError!StackEntry {
    switch (true_entry) {
        .i64_ref => |true_ref| switch (false_entry) {
            .i64_ref => |false_ref| return .{ .i64_ref = c._ir_PHI_2(ctx, c.IR_I64, true_ref, false_ref) },
            else => return IrCodegenError.NotCompilable,
        },
        .f64_ref => |true_ref| switch (false_entry) {
            .f64_ref => |false_ref| return .{ .f64_ref = c._ir_PHI_2(ctx, c.IR_DOUBLE, true_ref, false_ref) },
            else => return IrCodegenError.NotCompilable,
        },
        .bool_ref => |true_ref| switch (false_entry) {
            .bool_ref => |false_ref| return .{ .bool_ref = c._ir_PHI_2(ctx, c.IR_BOOL, true_ref, false_ref) },
            else => return IrCodegenError.NotCompilable,
        },
        .raw_at_slot => |true_slot| switch (false_entry) {
            .raw_at_slot => |false_slot| {
                if (true_slot == slot and false_slot == slot) {
                    return .{ .raw_at_slot = slot };
                }
                // Both wrote to physical slots but at different positions;
                // the last write from the taken branch is at the correct
                // location since only one branch executes. However, we
                // can't statically know which, so copy to canonical slot.
                _ = base_addr;
                return IrCodegenError.NotCompilable;
            },
            else => return IrCodegenError.NotCompilable,
        },
        .quotation_body, .row_region => return IrCodegenError.NotCompilable,
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
        .call_word => |name| {
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

    fn needsErrorPropagation(self: PreScanFlags) bool {
        return self.needs_error_handling or self.needs_safepoint or
            self.needs_dynamic_vars or self.needs_iterators or
            self.needs_native_call or self.needs_dispatch or
            self.needs_param_validation or self.needs_poly_fallback;
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
            .call_word => |name| {
                if (polyArithOpFromName(name) != null or isComparisonOp(name)) {
                    flags.needs_poly_fallback = true;
                }
                if (isLoopOp(name)) {
                    flags.needs_safepoint = true;
                } else if (isErrorHandlingOp(name)) {
                    flags.needs_error_handling = true;
                } else if (isDynamicVarOp(name)) {
                    flags.needs_dynamic_vars = true;
                } else if (isIteratorOp(name)) {
                    flags.needs_iterators = true;
                    const opcode = iteratorOpcodeFromName(name).?;
                    if (iteratorEffects(opcode).dynamic) {
                        flags.needs_param_validation = true;
                    }
                } else if (isStructNativeOp(name)) {
                    flags.needs_dispatch = true;
                } else if (!isSupportedOp(name) and !isStackOp(name)) {
                    if (resolver) |res| {
                        if (res.resolve(name, res.user_data)) |resolved| {
                            if (resolved.native_fn_ptr != null) {
                                flags.needs_native_call = true;
                            } else {
                                flags.needs_dispatch = true;
                            }
                            if (resolved.stack_effect_ptr != null) {
                                flags.needs_param_validation = true;
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
    const discovered = try compileWordPass(instructions, input_count, output_count, resolver, self_name, pic_table, interp_ctx, mutual_group, stack_effect, null);
    const second = try compileWordPass(instructions, input_count, output_count, resolver, self_name, pic_table, interp_ctx, mutual_group, stack_effect, discovered.peak_stack_depth);
    return second.compiled orelse IrCodegenError.CompilationFailed;
}

const CompileWordPassResult = struct {
    compiled: ?CompiledWord,
    peak_stack_depth: u32,
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

    // jitEnsureStackCapacity grows ctx.stack to cover the word's peak depth
    // when the capacity reserved by executeCompiled is insufficient. Needed
    // because compiled-to-compiled recursion bypasses executeCompiled's
    // capacity check, so each compiled entry re-validates.
    const ensure_cap_fn = c.ir_const_addr(&ctx, @intFromPtr(&jitEnsureStackCapacity));

    const validate_params_fn = if (scan_flags.needs_param_validation)
        c.ir_const_addr(&ctx, @intFromPtr(&jitValidateParamEffects))
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
    const stack_depth: usize = if (known_peak) |peak| @as(usize, peak) else estimateStackDepth(instructions, input_count);
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
        .refresh_stack_fn = refresh_stack_fn,
        .validate_params_fn = validate_params_fn,
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
        }
    }

    // Set up mutual recursion trampoline state if this word is in a group.
    if (mutual_group) |group| {
        state.mutual_group = group;
        state.input_count = input_count;
        state.trampoline_status = c.ir_const_i32(&ctx, 3);
    }

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
        return .{ .compiled = null, .peak_stack_depth = state.peak_sp };
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
            },
            .peak_stack_depth = state.peak_sp,
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

    // emit as C source with stdint.h preamble
    const body = try ir_mod.emitC(&ctx, c_name.ptr, allocator);
    errdefer allocator.free(body);

    const preamble =
        "#include <stdint.h>\n#include <stdbool.h>\n\n" ++
        "extern int32_t jitTypeMismatchError(uintptr_t ctx);\n" ++
        "extern int32_t jitOverflowError(uintptr_t ctx);\n" ++
        "extern int32_t jitDivisionByZeroError(uintptr_t ctx);\n" ++
        "extern int32_t jitStackUnderflowError(uintptr_t ctx);\n" ++
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
    reason_out: ?*?NotCompilableReason,
    quotation_id_map: ?*const std.AutoHashMapUnmanaged(usize, u32),
    pic_table: ?*pic_mod.PicTable,
    interp_ctx: ?*const Context,
    pic_stats_out: ?*PicStats,
    aot_fallback_emit_count_out: ?*u32,
) (IrCodegenError || ir_mod.IrError || Allocator.Error)![]u8 {
    return emitWordCAotWithCName(instructions, input_count, output_count, name, null, resolver, self_name, aot_compiled_names, string_literals, quotation_literals, array_literals, allocator, stack_effect, reason_out, quotation_id_map, pic_table, interp_ctx, pic_stats_out, aot_fallback_emit_count_out);
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
    reason_out: ?*?NotCompilableReason,
    quotation_id_map: ?*const std.AutoHashMapUnmanaged(usize, u32),
    pic_table: ?*pic_mod.PicTable,
    interp_ctx: ?*const Context,
    pic_stats_out: ?*PicStats,
    aot_fallback_emit_count_out: ?*u32,
) (IrCodegenError || ir_mod.IrError || Allocator.Error)![]u8 {
    var reason: ?NotCompilableReason = null;
    const discovered = emitWordCAotPass(instructions, input_count, output_count, name, c_name_override, resolver, self_name, aot_compiled_names, string_literals, quotation_literals, array_literals, allocator, stack_effect, null, &reason, quotation_id_map, pic_table, interp_ctx, null, null) catch |err| {
        if (reason_out) |ro| ro.* = reason;
        return err;
    };
    if (discovered.body) |b| allocator.free(b);
    reason = null;
    const result = emitWordCAotPass(instructions, input_count, output_count, name, c_name_override, resolver, self_name, aot_compiled_names, string_literals, quotation_literals, array_literals, allocator, stack_effect, discovered.peak_stack_depth, &reason, quotation_id_map, pic_table, interp_ctx, pic_stats_out, aot_fallback_emit_count_out) catch |err| {
        if (reason_out) |ro| ro.* = reason;
        return err;
    };
    return result.body orelse return IrCodegenError.CompilationFailed;
}

const EmitWordCAotPassResult = struct {
    body: ?[]u8,
    peak_stack_depth: u32,
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
    known_peak: ?u32,
    nc_reason_out: ?*?NotCompilableReason,
    quotation_id_map: ?*const std.AutoHashMapUnmanaged(usize, u32),
    pic_table: ?*pic_mod.PicTable,
    interp_ctx_param: ?*const Context,
    pic_stats_out: ?*PicStats,
    aot_fallback_emit_count_out: ?*u32,
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

    const proto_4arg = c.ir_proto_4(&ctx, 0, c.IR_I32, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR);
    const pic_dispatch_fn = if (scan_flags.needs_native_call or interp_ctx_param != null)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitPicDispatch"), proto_4arg)
    else
        c.IR_UNUSED;
    const pic_match_fn = if (scan_flags.needs_native_call or interp_ctx_param != null)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitPicTopTagsMatch"), proto_3arg)
    else
        c.IR_UNUSED;

    // jitRefreshStack is emitted unconditionally: any callback in the body
    // may reallocate ctx.stack, so emitCallbackPostCheck refreshes regardless
    // of which callbacks the pre-scan flagged.
    const refresh_stack_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitRefreshStack"), proto_1arg);

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

    // Error-reporting callbacks: set jit_pending_error and return 2.
    const type_mismatch_error_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitTypeMismatchError"), proto_1arg);
    const overflow_error_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitOverflowError"), proto_1arg);
    const div_zero_error_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitDivisionByZeroError"), proto_1arg);
    const underflow_error_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitStackUnderflowError"), proto_1arg);
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

    const stack_depth: usize = if (known_peak) |peak| @as(usize, peak) else estimateStackDepth(instructions, input_count);
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
        .pic_dispatch_fn = pic_dispatch_fn,
        .pic_match_fn = pic_match_fn,
        .refresh_stack_fn = refresh_stack_fn,
        .validate_params_fn = validate_params_fn,
        .pic_table = pic_table,
        .pic_stats = pic_stats_out,
        .aot_fallback_emit_count = aot_fallback_emit_count_out,
        .interp_ctx = interp_ctx_param,
        .error_propagate_status = error_propagate_status,
        .type_mismatch_error_fn = type_mismatch_error_fn,
        .overflow_error_fn = overflow_error_fn,
        .div_zero_error_fn = div_zero_error_fn,
        .underflow_error_fn = underflow_error_fn,
        .append_word_trace_frame_fn = c.IR_UNUSED,
        .append_builtin_trace_frame_fn = c.IR_UNUSED,
        .aot_mode = true,
        .aot_compiled_names = aot_compiled_names,
        .aot_proto_1arg = proto_1arg,
        .aot_proto_2arg = proto_2arg,
        .call_quotation_fn = call_quotation_fn,
        .call_code_ptr_fn = call_code_ptr_fn,
        .preloaded_ctx_val = preloaded_ctx_val,
        .aot_string_literals = string_literals,
        .aot_quotation_literals = quotation_literals,
        .aot_array_literals = array_literals,
        .aot_quotation_id_map = quotation_id_map,
        .peak_sp = @intCast(input_count),
        .stack_effect = stack_effect,
        .quotation_slots = buildQuotationSlotMap(stack_effect) orelse {
            if (nc_reason_out) |ro| ro.* = .quotation_slot_overflow;
            return IrCodegenError.NotCompilable;
        },
    };

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
        compileInstructions(&state, instructions, stack_buf, &sp) catch |err| {
            if (err == IrCodegenError.NotCompilable) {
                if (nc_reason_out) |ro| ro.* = state.not_compilable_reason;
            }
            return err;
        };
    }

    if (state.exit_kind == .loop_diverged) {
        c._ir_RETURN(&ctx, ok_status);
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

    // Discovery pass: skip C emission, let the caller re-run with the peak.
    if (known_peak == null) {
        return .{ .body = null, .peak_stack_depth = state.peak_sp };
    }

    const body = try ir_mod.emitC(&ctx, c_name.ptr, allocator);
    return .{ .body = body, .peak_stack_depth = state.peak_sp };
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
    /// Hard-coded false until a runtime image is actually emitted.
    runtime_image_present: bool,
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
};

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
    allocator: Allocator,
) (IrCodegenError || ir_mod.IrError || Allocator.Error)![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);

    // Build name->word_id map for compiled words, excluding native words, which must always use jitInterpretedCall
    var compiled_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compiled_names.deinit(allocator);
    for (words) |w| {
        if (w.is_native) continue;
        try compiled_names.put(allocator, w.name, w.word_id);
    }

    // 1. Preamble
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

    // 2. Callback extern declarations -- emit all unconditionally since the
    // two-pass compilation may introduce interpreter fallback calls that
    // weren't predicted by the pre-scan.
    try out.appendSlice(allocator, "extern int32_t jitSafepoint(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitRecover(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitCleanup(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitGet(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitWithParameter(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitIteratorOp(uintptr_t ctx, uintptr_t opcode);\n");
    try out.appendSlice(allocator, "extern int32_t jitNativeCall(uintptr_t ctx, uintptr_t fn_ptr);\n");
    try out.appendSlice(allocator, "extern int32_t jitPicTopTagsMatch(uintptr_t ctx, uintptr_t tag_a, uintptr_t tag_b);\n");
    try out.appendSlice(allocator, "extern int32_t jitPicDispatch(uintptr_t ctx, uintptr_t word_id, uintptr_t tag_a, uintptr_t tag_b);\n");
    try out.appendSlice(allocator, "extern int32_t jitInterpretedCall(uintptr_t ctx, uintptr_t word_id, uintptr_t line);\n");
    try out.appendSlice(allocator, "extern int32_t jitRefreshStack(uintptr_t jit_ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitEnsureStackCapacity(uintptr_t jit_ctx, uintptr_t needed);\n");
    try out.appendSlice(allocator, "extern int32_t jitValidateParamEffects(uintptr_t ctx, uintptr_t effect_ptr);\n");
    try out.appendSlice(allocator, "extern int32_t jitCallQuotation(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitCallCodePtr(uintptr_t jit_ctx, uintptr_t code_ptr);\n");
    try out.appendSlice(allocator, "extern int32_t jitTypeMismatchError(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitOverflowError(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitDivisionByZeroError(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitStackUnderflowError(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitAppendNamedTraceFrame(uintptr_t ctx, uintptr_t name_ptr, uintptr_t name_len, uintptr_t line);\n");
    try out.appendSlice(allocator, "extern int32_t jitAppendBuiltinTraceFrame(uintptr_t ctx, uintptr_t frame_kind, uintptr_t line);\n");
    try out.appendSlice(allocator, "static int32_t onez_append_named_trace_frame(uintptr_t ctx, const char *name, uintptr_t len, uintptr_t line) { return jitAppendNamedTraceFrame(ctx, (uintptr_t)name, len, line); }\n");
    try out.appendSlice(allocator, "extern int32_t jitPushString(uintptr_t ctx, uintptr_t str_ptr, uintptr_t str_len);\n");
    try out.appendSlice(allocator, "extern int32_t jitPushSymbol(uintptr_t ctx, uintptr_t str_ptr, uintptr_t str_len);\n");
    try out.appendSlice(allocator, "extern int32_t jitPushQuotation(uintptr_t ctx, uintptr_t data, uintptr_t len, uintptr_t dest, uintptr_t quotation_id);\n");
    try out.appendSlice(allocator, "static int32_t onez_push_string(uintptr_t ctx, const char *str, uintptr_t len) { return jitPushString(ctx, (uintptr_t)str, len); }\n");
    try out.appendSlice(allocator, "static int32_t onez_push_symbol(uintptr_t ctx, const char *str, uintptr_t len) { return jitPushSymbol(ctx, (uintptr_t)str, len); }\n");
    try out.appendSlice(allocator, "static int32_t onez_push_quotation(uintptr_t ctx, const unsigned char *data, uintptr_t len, uintptr_t dest, uintptr_t quotation_id) { return jitPushQuotation(ctx, (uintptr_t)data, len, dest, quotation_id); }\n");
    try out.appendSlice(allocator, "extern int32_t jitPushWordLiteral(uintptr_t ctx, uintptr_t name_ptr, uintptr_t name_len);\n");
    try out.appendSlice(allocator, "static int32_t onez_push_word_literal(uintptr_t ctx, const char *name, uintptr_t len) { return jitPushWordLiteral(ctx, (uintptr_t)name, len); }\n");
    try out.appendSlice(allocator, "extern int32_t jitPushStructType(uintptr_t ctx, uintptr_t name_ptr, uintptr_t name_len);\n");
    try out.appendSlice(allocator, "static int32_t onez_push_struct_type(uintptr_t ctx, const char *name, uintptr_t len) { return jitPushStructType(ctx, (uintptr_t)name, len); }\n");
    try out.appendSlice(allocator, "extern int32_t jitPushArray(uintptr_t ctx, uintptr_t data_ptr, uintptr_t data_len);\n");
    try out.appendSlice(allocator, "static int32_t onez_push_array(uintptr_t ctx, const unsigned char *data, uintptr_t len) { return jitPushArray(ctx, (uintptr_t)data, len); }\n");

    // Runtime entry point externs
    try out.appendSlice(allocator,
        \\
        \\extern void *onez_init(void);
        \\extern void *onez_init_no_prelude(void);
        \\extern int onez_set_args(void *ctx, int argc, char **argv);
        \\extern int32_t onez_runtime_register_compiled(void *rt, int32_t (**table)(uintptr_t), const char **names, uint32_t size);
        \\extern int32_t onez_runtime_register_quotations(void *rt, int32_t (**table)(uintptr_t), uint32_t size);
        \\extern int32_t onez_runtime_run(void *rt, uint32_t entry_word_id);
        \\extern void onez_print_error(void *rt);
        \\extern void onez_deinit(void *rt);
        \\extern int onez_set_static_libs(void *rt, const char **names, unsigned int count);
        \\extern int32_t onez_set_interpreter_fallback(void *rt, _Bool allowed);
        \\
        \\
    );

    // Build a resolver from the AOT word list for cross-word calls
    var word_map: std.StringHashMapUnmanaged(AotWordDesc) = .{};
    defer word_map.deinit(allocator);
    for (words) |w| {
        try word_map.put(allocator, w.name, w);
    }

    const AotResolverData = struct {
        map: *const std.StringHashMapUnmanaged(AotWordDesc),

        fn resolve(name_ptr: []const u8, user_data: *anyopaque) ?ResolvedWord {
            const self: *const @This() = @ptrCast(@alignCast(user_data));
            const entry = self.map.getPtr(name_ptr) orelse return null;
            var result = ResolvedWord{
                .word_id = entry.word_id,
                .input_count = entry.input_count,
                .output_count = entry.output_count,
                .never_returns = entry.never_returns,
                .native_fn_ptr = entry.native_fn_ptr,
            };
            if (entry.stack_effect) |*eff| {
                if (stack_effect_mod.hasAnyRowVariable(eff.*)) {
                    result.callee_effect = eff;
                }
            }
            return result;
        }
    };

    var resolver_data = AotResolverData{ .map = &word_map };
    const resolver = WordResolver{
        .resolve = &AotResolverData.resolve,
        .user_data = @ptrCast(&resolver_data),
        .dispatch_table_ptr = undefined,
    };

    // 4. Two-pass compilation: first determine which words compile,
    // then re-compile with only the compilable set so that cross-word calls
    // to uncompilable words use jitInterpretedCall instead of direct calls.

    // Pass 1a: trial compile to discover the compilable set
    var compilable_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compilable_names.deinit(allocator);
    var failure_reasons: std.StringHashMapUnmanaged(NotCompilableReason) = .{};
    defer failure_reasons.deinit(allocator);
    for (words) |*w| {
        if (w.is_native) continue;
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
            &reason,
            null,
            w.pic_snapshot,
            interp_ctx,
            null,
            null,
        ) catch |err| {
            if (reason) |r| {
                try failure_reasons.put(allocator, w.name, r);
            } else if (err == IrCodegenError.StackUnderflow or err == IrCodegenError.StackShapeMismatch) {
                try failure_reasons.put(allocator, w.name, .abstract_stack_underflow);
            }
            continue;
        };
        allocator.free(trial);
        try compilable_names.put(allocator, w.name, w.word_id);
    }

    // Pass 1b: trial compile quotation bodies to discover the compilable set
    var compilable_quotation_ids: std.AutoHashMapUnmanaged(u32, void) = .{};
    defer compilable_quotation_ids.deinit(allocator);
    for (quotations) |*q| {
        const effect = q.inferred_effect orelse continue;
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
            null,
            null,
            null,
            interp_ctx,
            null,
            null,
        ) catch continue;
        allocator.free(trial);
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
            null,
            &quotation_id_map,
            w.pic_snapshot,
            interp_ctx,
            &pic_stats,
            &aot_fallback_emit_count,
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
            null,
            &quotation_id_map,
            null,
            interp_ctx,
            null,
            &aot_fallback_emit_count,
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

    // Strict codegen: verify all non-prelude input words were compiled.
    // Prelude words can safely fall back to jitInterpretedCall since they
    // exist in the AOT runtime dictionary.
    {
        var uncompiled: std.ArrayListUnmanaged(UncompiledWord) = .{};
        for (words) |w| {
            if (!w.is_prelude and !actually_compiled.contains(w.word_id)) {
                const reason = failure_reasons.get(w.name) orelse .unknown_reason;
                try uncompiled.append(allocator, .{ .name = w.name, .reason = reason });
            }
        }
        if (uncompiled.items.len > 0) {
            diagnostics.uncompiled_words = try allocator.dupe(UncompiledWord, uncompiled.items);
            uncompiled.deinit(allocator);
            return error.UncompiledWords;
        }
        uncompiled.deinit(allocator);
    }

    // NOTE(ripta): Strict codegen: quotation bodies with inferred effects must compile.
    //              Bodies without inferred effects (row-polymorphic, e.g., `[ call ]`
    //              inside higher-order prelude words) are not yet handled, so this makes
    //              their parent words compilable by inlining the quotation at the call
    //              site. `>quotation`-constructed quotations are not in this set at all.
    {
        var uncompiled_q: std.ArrayListUnmanaged(UncompiledQuotation) = .{};
        for (quotations) |q| {
            if (!q.compiled and q.inferred_effect != null) {
                try uncompiled_q.append(allocator, .{
                    .quotation_id = q.quotation_id,
                    .c_name = q.c_name,
                });
            }
        }
        if (uncompiled_q.items.len > 0) {
            diagnostics.uncompiled_quotations = try allocator.dupe(UncompiledQuotation, uncompiled_q.items);
            uncompiled_q.deinit(allocator);
            return error.UncompiledQuotations;
        }
        uncompiled_q.deinit(allocator);
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

    // 4a. Forward declarations (only for successfully compiled words)
    for (words) |w| {
        if (!actually_compiled.contains(w.word_id)) continue;
        const mangled = try mangleWordName(w.name, allocator);
        defer allocator.free(mangled);
        try out.appendSlice(allocator, "int32_t ");
        try out.appendSlice(allocator, mangled);
        try out.appendSlice(allocator, "(uintptr_t jit_ctx);\n");
    }
    // Forward declarations for compiled quotation bodies
    for (compiled_quotation_bodies.items) |item| {
        for (quotations) |q| {
            if (q.quotation_id == item.id) {
                try out.appendSlice(allocator, "int32_t ");
                try out.appendSlice(allocator, q.c_name);
                try out.appendSlice(allocator, "(uintptr_t jit_ctx);\n");
                break;
            }
        }
    }
    try out.appendSlice(allocator, "\n");

    // 4b. Emit compiled function bodies
    for (compiled_bodies.items) |item| {
        try out.appendSlice(allocator, item.body);
        try out.appendSlice(allocator, "\n");
    }
    // 4c. Emit compiled quotation function bod ies
    for (compiled_quotation_bodies.items) |item| {
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

    // 5b. Word name table (for interpreter fallback)
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
    // mode confirmed no fallback was emitted.
    const interpreter_callbacks_emitted = aot_fallback_emit_count > 0;

    // mode=false + lock=true + an emitted fallback is a build error: the user
    // asked for a binary that can never call the interpreter, but codegen
    // needed it. Without this check the binary would crash at runtime via
    // allow_interpreted_fallback.
    if (interpreter_fallback == .false and lock_interpreter_setting and interpreter_callbacks_emitted) {
        return IrCodegenError.InterpreterRequiredButLocked;
    }

    // Emit the interpreter-linked sentinel as a non-static global. The linker
    // GC drops lib1z.a when this is 0; the symbol itself is a redundant marker
    // alongside the inspect-friendly string below.
    const interpreter_free = switch (interpreter_fallback) {
        .true => false,
        .false => lock_interpreter_setting,
        .auto => !interpreter_callbacks_emitted,
    };
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
    // the open marker (V2) and the schema-version field together.
    try emitAotMetadata(allocator, &out, metadata, !interpreter_free);

    // 6. Main entry point. Interpreter-free binaries skip prelude loading
    // since every reachable word was compiled and registered explicitly via
    // onez_runtime_register_compiled below; calling onez_init() would drag
    // the parser/tokenizer/statement processor into the binary just to
    // re-evaluate the prelude source at startup.
    try out.appendSlice(allocator, "int main(int argc, char **argv) {\n");
    try out.appendSlice(allocator, if (interpreter_free)
        "    void *rt = onez_init_no_prelude();\n"
    else
        "    void *rt = onez_init();\n");
    try out.appendSlice(allocator, "    onez_set_args(rt, argc, argv);\n");

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

    // Format dispatch table size
    var size_buf: [20]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{table_size}) catch unreachable;

    try out.appendSlice(allocator, "    onez_runtime_register_compiled(rt, onez_dispatch_table, onez_word_names, ");
    try out.appendSlice(allocator, size_str);
    try out.appendSlice(allocator, ");\n");

    if (quotations.len > 0) {
        var max_q_id: u32 = 0;
        for (quotations) |q| {
            if (q.quotation_id >= max_q_id) max_q_id = q.quotation_id;
        }
        var q_size_buf: [20]u8 = undefined;
        const q_size_str = std.fmt.bufPrint(&q_size_buf, "{d}", .{max_q_id + 1}) catch unreachable;

        try out.appendSlice(allocator, "    onez_runtime_register_quotations(rt, onez_quotation_table, ");
        try out.appendSlice(allocator, q_size_str);
        try out.appendSlice(allocator, ");\n");
    }

    var id_buf: [20]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{entry_word_id}) catch unreachable;

    try out.appendSlice(allocator, "    int32_t status = onez_runtime_run(rt, ");
    try out.appendSlice(allocator, id_str);
    try out.appendSlice(allocator, ");\n");
    try out.appendSlice(allocator, "    if (status != 0) onez_print_error(rt);\n");
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
) !void {
    const fallback_str: []const u8 = switch (meta.interpreter_fallback_mode) {
        .true => "true",
        .false => "false",
        .auto => "auto",
    };
    const yes_no_interp_linked: []const u8 = if (interpreter_linked) "yes" else "no";
    const yes_no_locked: []const u8 = if (meta.interpreter_setting_locked) "yes" else "no";
    const yes_no_runtime_image: []const u8 = if (meta.runtime_image_present) "yes" else "no";

    try out.appendSlice(allocator, "__attribute__((used)) static const char onez_aot_meta_v1[] =\n");
    try out.appendSlice(allocator, "    \"<<1Z_AOT_META_V1\\n\"\n");
    try out.appendSlice(allocator, "    \"schema-version=1\\n\"\n");
    try out.appendSlice(allocator, "    \"interpreter-linked=");
    try out.appendSlice(allocator, yes_no_interp_linked);
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

/// Re-LOAD items_ptr from the JitContext struct and recompute base_addr,
/// updating state.items_ptr and state.base_addr so subsequent emissions use
/// the fresh refs. Call this immediately after any IR call that may have
/// moved ctx.stack.items (jitRefreshStack or jitEnsureStackCapacity).
/// IR treats calls as memory-clobbering barriers, so the fresh LOAD will
/// not be CSE'd across the preceding call.
fn refreshCachedStackPointer(state: *CompileState) void {
    const ctx = state.ctx;
    const fresh_items_ptr = c._ir_LOAD(ctx, c.IR_ADDR, state.jit_ctx_ptr);
    const base_byte_offset = c.ir_fold2(ctx, c.IR_OPT(c.IR_MUL, c.IR_ADDR), state.base_idx, state.value_size_const);
    const fresh_base_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), fresh_items_ptr, base_byte_offset);
    state.items_ptr = fresh_items_ptr;
    state.base_addr = fresh_base_addr;
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
fn emitInlinePicEntries(
    state: *CompileState,
    ctx_val: c.ir_ref,
    name: []const u8,
    resolved: ResolvedWord,
    line: usize,
    qualified: []const InlinePicEntry,
    generation: u32,
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
    const pic_match_fn = if (state.pic_match_fn != c.IR_UNUSED)
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
        const tag_b_const = c.ir_const_addr(ictx, @intFromEnum(entry.tag_b));
        const match_status = c._ir_CALL_3(ictx, c.IR_I32, pic_match_fn, ctx_val, tag_a_const, tag_b_const);
        const matched = c.ir_fold2(ictx, c.IR_OPT(c.IR_NE, c.IR_BOOL), match_status, state.ok_status);
        const if_match = c._ir_IF(ictx, matched);

        // Hit path: call the cached native method body directly
        c._ir_IF_TRUE(ictx, if_match);
        {
            if (state.aot_mode) {
                // AOT: can't bake function pointers; dispatch via
                // jitPicDispatch with the pre-verified type tags.
                const word_id_const = c.ir_const_addr(ictx, resolved.word_id);
                const tag_a_int = c.ir_const_addr(ictx, @intFromEnum(entry.tag_a));
                const tag_b_int = c.ir_const_addr(ictx, @intFromEnum(entry.tag_b));
                const call_result = c._ir_CALL_4(ictx, c.IR_I32, state.pic_dispatch_fn, ctx_val, word_id_const, tag_a_int, tag_b_int);
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

    return emitInlinePicEntries(state, ctx_val, name, resolved, line, qualified[0..qualified_count], cache.generation);
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

    return emitInlinePicEntries(state, ctx_val, name, resolved, line, qualified[0..qualified_count], interp_ctx.dispatch.generation);
}

/// Emit a native word call. In JIT mode, calls through jitNativeCall with
/// the baked function pointer. In AOT mode, calls through jitInterpretedCall
/// with the word ID since native function pointers are not available at C
/// compile time.
fn emitNativeWordCall(state: *CompileState, ctx_val: c.ir_ref, name: []const u8, resolved: ResolvedWord, line: usize) void {
    const ictx = state.ctx;
    if (state.aot_mode) {
        const word_id_const = c.ir_const_addr(ictx, resolved.word_id);
        const line_const = c.ir_const_addr(ictx, line);
        state.noteAotFallbackEmission();
        const call_result = c._ir_CALL_3(ictx, c.IR_I32, state.interpreted_call_fn, ctx_val, word_id_const, line_const);
        emitCallbackPostCheck(state, call_result, state.error_propagate_status, if (resolved.never_returns) state.error_propagate_status else null, .none);
    } else {
        const fn_ptr_const = c.ir_const_addr(ictx, resolved.native_fn_ptr.?);
        const call_result = c._ir_CALL_2(ictx, c.IR_I32, state.native_call_fn, ctx_val, fn_ptr_const);
        emitCallbackPostCheck(state, call_result, call_result, if (resolved.never_returns) state.error_propagate_status else null, .{ .named = .{ .name = name, .line = line } });
    }
}

/// Emit a compound word call in AOT mode. If the target word is in the
/// compiled word set, emits a direct call by mangled name. Otherwise, falls
/// through to jitInterpretedCall with the word ID.
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
    state.noteAotFallbackEmission();
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

/// Push a string literal onto the stack. The string data is at `str_ptr`
/// with length `str_len`. The runtime copies the data into a managed allocation.
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

/// Record a structured `word-not-found` failure so `onez_print_error` can
/// surface the missing name. Used by AOT push-literal callbacks where the
/// runtime lookup helper returned null. The name is duplicated into the
/// arena allocator so its lifetime tracks the context, matching the
/// convention used by other error_details producers.
fn recordWordNotFound(ctx: *Context, name: []const u8) void {
    const msg = ctx.arena.allocator().dupe(u8, name) catch return;
    ctx.error_details.append(ctx.allocator, .{
        .error_type = "word-not-found",
        .message = msg,
        .source = "<aot-runtime>",
        .line = 0,
        .word_name = msg,
    }) catch {};
}

/// Look up a word by name, falling through to the module cache for
/// module-private words that plain `lookupWord` cannot reach. Returns
/// the compound body's instructions, or null when not found / not
/// compound. Shared by AOT runtime callbacks that need to read literal
/// payloads out of word definitions.
fn lookupWordCompoundInstrs(ctx: *Context, name: []const u8) ?[]const Instruction {
    if (ctx.lookupWord(name)) |word| {
        switch (word.action) {
            .compound => |instrs| return instrs,
            .native, .host_callback => {},
        }
    }
    var iter = ctx.module_cache_value.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* != .module) continue;
        const module = entry.value_ptr.*.module;
        if (module.words.get(name)) |mw| {
            switch (mw.action) {
                .compound => |instrs| return instrs,
                .native, .host_callback => {},
            }
        }
    }
    return null;
}

/// Push a word's literal value onto the stack. The word must be a single
/// push_literal instruction (type words, enum variants, parameter definitions).
/// The name is at `name_ptr` with length `name_len`. The runtime looks up the
/// word in the dictionary and pushes its literal value.
///
/// Falls through to `module_cache_value` on `lookupWord` miss because
/// enum variants and parameter words for module-private definitions live in
/// `module.words` and are not visible to plain `lookupWord` from inside
/// AOT-to-AOT direct calls.
export fn jitPushWordLiteral(ctx_raw: usize, name_ptr: usize, name_len: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const src: [*]const u8 = @ptrFromInt(name_ptr);
    const name = src[0..name_len];
    const instrs = lookupWordCompoundInstrs(ctx, name) orelse {
        recordWordNotFound(ctx, name);
        ctx.jit_pending_error = error.WordNotFound;
        return 2;
    };
    if (instrs.len == 1) {
        switch (instrs[0].op) {
            .push_literal => |val| {
                ctx.stack.push(val) catch {
                    ctx.jit_pending_error = error.OutOfMemory;
                    return 2;
                };
                return 0;
            },
            else => {},
        }
    }
    ctx.jit_pending_error = error.TypeMismatch;
    return 2;
}

/// Push a struct_type value onto the stack by looking up the constructor word
/// "make-{name}" and extracting the struct_type from its first instruction.
/// Used by AOT-compiled struct words whose struct_type pointer is only valid
/// at compile time.
///
/// Falls through to `module_cache_value` on `lookupWord` miss because
/// constructor words for module-private struct definitions live in
/// `module.words` and are not visible to plain `lookupWord` from inside
/// AOT-to-AOT direct calls.
export fn jitPushStructType(ctx_raw: usize, name_ptr: usize, name_len: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const src: [*]const u8 = @ptrFromInt(name_ptr);
    const struct_name = src[0..name_len];

    // Build "make-{name}" to look up the constructor word
    var buf: [256]u8 = undefined;
    const ctor_name = std.fmt.bufPrint(&buf, "make-{s}", .{struct_name}) catch {
        ctx.jit_pending_error = error.Overflow;
        return 2;
    };

    const ctor_instrs = lookupWordCompoundInstrs(ctx, ctor_name) orelse {
        recordWordNotFound(ctx, ctor_name);
        ctx.jit_pending_error = error.WordNotFound;
        return 2;
    };

    if (ctor_instrs.len >= 1) {
        switch (ctor_instrs[0].op) {
            .push_literal => |val| {
                if (val == .struct_type) {
                    ctx.stack.push(val) catch {
                        ctx.jit_pending_error = error.OutOfMemory;
                        return 2;
                    };
                    return 0;
                }
            },
            else => {},
        }
    }
    ctx.jit_pending_error = error.TypeMismatch;
    return 2;
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
    const instructions = deserializeQuotationInstructions(src[0..data_len], alloc) catch {
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
    const val = deserializeValueAt(src[0..data_len], &offset, alloc) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    ctx.stack.push(val) catch {
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
        const instrs = switch (module_word.action) {
            .compound => |compound| compound,
            .native, .host_callback => return null,
        };
        if (instrs.len == 0) return null;

        const module = switch (instrs[0].op) {
            .push_literal => |val| switch (val) {
                .module => |m| m,
                else => return null,
            },
            else => return null,
        };

        if (module.words.get(suffix)) |mw| return .{ .word = mw, .module = module };
        return null;
    }

    var iter = ctx.module_cache_value.iterator();
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
    switch (hit.word.action) {
        .native => |func| try func(ctx),
        .host_callback => |host| {
            const rc = host.callback(host.handle, host.user_data);
            if (rc != 0) return error.HostCallbackFailed;
        },
        .compound => |instrs| try ctx.executeQuotation(.{ .instructions = instrs }),
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
                    break :blk ctx.executeQuotationWithPic(.{ .instructions = instrs }, entry.pic_snapshot);
                },
                .native => |func| break :blk func(ctx),
                .host_callback => |host| break :blk host_result: {
                    const rc = host.callback(host.handle, host.user_data);
                    if (rc != 0) break :host_result error.HostCallbackFailed;
                    break :host_result;
                },
            }
        } else {
            break :blk switch (word.action) {
                .native => |func| func(ctx),
                .host_callback => |host| host_result: {
                    const rc = host.callback(host.handle, host.user_data);
                    if (rc != 0) break :host_result error.HostCallbackFailed;
                    break :host_result;
                },
                .compound => |instrs| ctx.executeQuotationWithPic(.{ .instructions = instrs }, entry.pic_snapshot),
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
    const result = try compileWord(&instrs, 2, 1, null, null, null, null, null);
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
    const callee = try compileWord(&callee_instrs, 2, 1, null, null, null, null, null);
    const callee_id = try dispatch.assignId("sum2");
    dispatch.update(callee_id, callee.code_ptr, callee.jit_buf, callee.peak_stack_depth);

    const ResolverState = struct {
        callee_id: u32,
    };
    var resolver_state = ResolverState{ .callee_id = callee_id };
    const Resolver = struct {
        fn resolve(name: []const u8, user_data: *anyopaque) ?ResolvedWord {
            const state: *ResolverState = @ptrCast(@alignCast(user_data));
            if (!std.mem.eql(u8, name, "sum2")) return null;
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

test "division by zero returns error_propagate" {
    const instrs = makeInstructions(.{"/"});
    const result = try compileWord(&instrs, 2, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    // Div-by-zero goes to native fallback; without a resolver it returns error_propagate (2).
    try testing.expectEqual(@as(i32, 2), callCompiled(func, &.{ 10, 0 }, &out));
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{ 10, 2 }, &out));
    try testing.expectEqual(@as(i64, 5), out);
}

test "division minInt/-1 returns error_propagate" {
    const instrs = makeInstructions(.{"/"});
    const result = try compileWord(&instrs, 2, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    // minInt/-1 overflow goes to native fallback; without a resolver it returns error_propagate (2).
    try testing.expectEqual(@as(i32, 2), callCompiled(func, &.{ std.math.minInt(i64), -1 }, &out));
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
    const result = try compileWord(&instrs, 2, 1, null, null, null, null, null);
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

test "arithmetic on opaque operand returns error_propagate" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .string = "hello" } }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 2 },
    };
    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    values[0] = .{ .fixnum = 1 };
    var sp: usize = 1;
    const status = callCompiledValues(func, &values, &sp);
    // Non-numeric operand goes to native fallback; without a resolver returns error_propagate.
    try testing.expectEqual(@as(i32, 2), status);
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

test "compile dup * (square)" {
    const instrs = makeInstructions(.{ "dup", "*" });
    const result = try compileWord(&instrs, 1, 1, null, null, null, null, null);
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
    const result = try compileWord(&instrs, 2, 1, null, null, null, null, null);
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
    var inner_val = Value{ .fixnum = 42 };
    const tagged_val = Value{ .tagged = .{ .tag = &vtype, .inner = &inner_val } };
    const vtype_ptr: i64 = @intCast(@intFromPtr(&vtype));

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = tagged_val }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = vtype_ptr } }, .line = 2 },
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
    var inner_val = Value{ .fixnum = 99 };
    const tagged_val = Value{ .tagged = .{ .tag = &vtype_a, .inner = &inner_val } };
    const vtype_b_ptr: i64 = @intCast(@intFromPtr(&vtype_b));

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = tagged_val }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = vtype_b_ptr } }, .line = 2 },
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
    const vtype_ptr: i64 = @intCast(@intFromPtr(&vtype));

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = vtype_ptr } }, .line = 1 },
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
    var inner_val = Value{ .fixnum = 77 };
    const vtype_ptr: i64 = @intCast(@intFromPtr(&vtype));

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = vtype_ptr } }, .line = 1 },
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
    var inner_val = Value{ .fixnum = 10 };
    const vtype_ptr: i64 = @intCast(@intFromPtr(&vtype));

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = vtype_ptr } }, .line = 1 },
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
    const vtype_ptr: Value = .{ .fixnum = @intCast(@intFromPtr(&vt)) };

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
    const vtype_ptr: Value = .{ .fixnum = @intCast(@intFromPtr(&vt)) };

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
    const vtype_ptr: Value = .{ .fixnum = @intCast(@intFromPtr(&vt)) };

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
    const vtype_ptr: Value = .{ .fixnum = @intCast(@intFromPtr(&vt)) };

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
    const vtype_ptr: Value = .{ .fixnum = @intCast(@intFromPtr(&vt)) };

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
    const vtype_ptr: Value = .{ .fixnum = @intCast(@intFromPtr(&vt)) };

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
        null,
        null,
        null,
        null,
        null,
        null,
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
        null,
        null,
        null,
        null,
        null,
        null,
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
        null,
        null,
        null,
        null,
        null,
        null,
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

test "emitProgramC generates complete C source" {
    const double_instrs = makeInstructions(.{ @as(i64, 2), "*" });
    const add3_instrs = makeInstructions(.{ @as(i64, 3), "+" });

    const words = [_]AotWordDesc{
        .{ .name = "double", .instructions = &double_instrs, .input_count = 1, .output_count = 1, .word_id = 0 },
        .{ .name = "add3", .instructions = &add3_instrs, .input_count = 1, .output_count = 1, .word_id = 1 },
    };

    var diag: CodegenDiagnostics = .{};
    const source = try emitProgramC(&words, &.{}, 0, 1, &.{}, .auto, false, test_aot_metadata, &diag, null, testing.allocator);
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

    // Forward declarations
    try testing.expect(std.mem.indexOf(u8, source, "int32_t onez_w_double(uintptr_t jit_ctx);") != null);
    try testing.expect(std.mem.indexOf(u8, source, "int32_t onez_w_add3(uintptr_t jit_ctx);") != null);

    // Word bodies
    try testing.expect(std.mem.indexOf(u8, source, "onez_w_double") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_w_add3") != null);

    // Dispatch table
    try testing.expect(std.mem.indexOf(u8, source, "onez_dispatch_table") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_word_fn_t") != null);

    // Main entry point
    try testing.expect(std.mem.indexOf(u8, source, "int main(") != null);
}

test "emitProgramC dispatch table has correct entries" {
    const instrs = makeInstructions(.{@as(i64, 42)});

    const words = [_]AotWordDesc{
        .{ .name = "foo", .instructions = &instrs, .input_count = 0, .output_count = 1, .word_id = 0 },
        .{ .name = "bar", .instructions = &instrs, .input_count = 0, .output_count = 1, .word_id = 2 },
    };

    var diag2: CodegenDiagnostics = .{};
    const source = try emitProgramC(&words, &.{}, 0, 2, &.{}, .auto, false, test_aot_metadata, &diag2, null, testing.allocator);
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
    const source = try emitProgramC(&words, &quotations, 0, 0, &.{}, .auto, false, test_aot_metadata, &diag, null, testing.allocator);
    defer testing.allocator.free(source);

    // Table exists with all entries
    try testing.expect(std.mem.indexOf(u8, source, "onez_quotation_table") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_q_0,") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_q_1,") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_q_2,") != null);

    // Registration call in main
    try testing.expect(std.mem.indexOf(u8, source, "onez_runtime_register_quotations(rt, onez_quotation_table, 3)") != null);
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
    const result = emitProgramC(&words, &quotations, 0, 0, &.{}, .auto, false, test_aot_metadata, &diag, null, testing.allocator);
    try testing.expectError(error.UncompiledQuotations, result);

    // Diagnostics report the uncompiled quotation
    try testing.expectEqual(@as(usize, 1), diag.uncompiled_quotations.len);
    try testing.expectEqualStrings("onez_q_1", diag.uncompiled_quotations[0].c_name);
    try testing.expectEqual(@as(u32, 1), diag.uncompiled_quotations[0].quotation_id);
    testing.allocator.free(diag.uncompiled_quotations);
}

test "emitProgramC no quotation table when quotations empty" {
    const instrs = makeInstructions(.{@as(i64, 42)});

    const words = [_]AotWordDesc{
        .{ .name = "main", .instructions = &instrs, .input_count = 0, .output_count = 1, .word_id = 0 },
    };

    var diag: CodegenDiagnostics = .{};
    const source = try emitProgramC(&words, &.{}, 0, 0, &.{}, .auto, false, test_aot_metadata, &diag, null, testing.allocator);
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
    const source = try emitProgramC(&words, &.{}, 1, 1, &.{}, .auto, false, test_aot_metadata, &diag3, null, testing.allocator);
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
// Quotation serialization/deserialization tests
// ---------------------------------------------------------------------------

test "serializeQuotationInstructions: roundtrip fixnum push + call" {
    const instrs = makeInstructions(.{ @as(i64, 1), "+" });
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer {
        for (decoded) |instr| {
            switch (instr.op) {
                .call_word => |n| testing.allocator.free(n),
                else => {},
            }
        }
        testing.allocator.free(decoded);
    }
    try testing.expectEqual(@as(usize, 2), decoded.len);
    try testing.expect(decoded[0].op == .push_literal);
    try testing.expectEqual(@as(i64, 1), decoded[0].op.push_literal.fixnum);
    try testing.expect(decoded[1].op == .call_word);
    try testing.expectEqualStrings("+", decoded[1].op.call_word);
}

test "serializeQuotationInstructions: roundtrip string literal" {
    const str_val = Value{ .string = "hello" };
    const instrs = [_]Instruction{.{ .op = .{ .push_literal = str_val }, .line = 1 }};
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer {
        for (decoded) |instr| {
            switch (instr.op) {
                .push_literal => |v| {
                    if (v == .string) testing.allocator.free(v.string);
                },
                .call_word => |n| testing.allocator.free(n),
            }
        }
        testing.allocator.free(decoded);
    }
    try testing.expectEqual(@as(usize, 1), decoded.len);
    try testing.expect(decoded[0].op.push_literal == .string);
    try testing.expectEqualStrings("hello", decoded[0].op.push_literal.string);
}

test "serializeQuotationInstructions: roundtrip empty body" {
    const instrs: [0]Instruction = .{};
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer testing.allocator.free(decoded);
    try testing.expectEqual(@as(usize, 0), decoded.len);
}

test "serializeQuotationInstructions: roundtrip bool and float" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 3.14 } }, .line = 2 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer testing.allocator.free(decoded);
    try testing.expectEqual(@as(usize, 2), decoded.len);
    try testing.expectEqual(true, decoded[0].op.push_literal.boolean);
    try testing.expectEqual(@as(f64, 3.14), decoded[1].op.push_literal.float);
}

test "serializeQuotationInstructions: preserves line and column" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 42 } }, .line = 5, .column = 10 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer testing.allocator.free(decoded);
    try testing.expectEqual(@as(usize, 5), decoded[0].line);
    try testing.expectEqual(@as(usize, 10), decoded[0].column);
}

test "serializeQuotationInstructions: roundtrip empty array" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .array = &.{} } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer testing.allocator.free(decoded);
    try testing.expectEqual(@as(usize, 1), decoded.len);
    try testing.expect(decoded[0].op.push_literal == .array);
    try testing.expectEqual(@as(usize, 0), decoded[0].op.push_literal.array.len);
}

test "serializeQuotationInstructions: roundtrip array with elements" {
    const elems = [_]Value{
        .{ .fixnum = 42 },
        .{ .string = "hello" },
        .{ .boolean = true },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .array = &elems } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer {
        for (decoded) |instr| {
            switch (instr.op) {
                .push_literal => |v| {
                    if (v == .array) {
                        for (v.array) |elem| {
                            if (elem == .string) testing.allocator.free(elem.string);
                        }
                        testing.allocator.free(v.array);
                    }
                },
                .call_word => |n| testing.allocator.free(n),
            }
        }
        testing.allocator.free(decoded);
    }
    try testing.expectEqual(@as(usize, 1), decoded.len);
    const arr = decoded[0].op.push_literal.array;
    try testing.expectEqual(@as(usize, 3), arr.len);
    try testing.expectEqual(@as(i64, 42), arr[0].fixnum);
    try testing.expectEqualStrings("hello", arr[1].string);
    try testing.expectEqual(true, arr[2].boolean);
}

test "serializeQuotationInstructions: roundtrip nested array" {
    const inner1 = [_]Value{ .{ .fixnum = 1 }, .{ .fixnum = 2 } };
    const inner2 = [_]Value{.{ .fixnum = 3 }};
    const outer = [_]Value{
        .{ .array = &inner1 },
        .{ .array = &inner2 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .array = &outer } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer {
        for (decoded) |instr| {
            switch (instr.op) {
                .push_literal => |v| {
                    if (v == .array) {
                        for (v.array) |elem| {
                            if (elem == .array) testing.allocator.free(elem.array);
                        }
                        testing.allocator.free(v.array);
                    }
                },
                .call_word => |n| testing.allocator.free(n),
            }
        }
        testing.allocator.free(decoded);
    }
    const arr = decoded[0].op.push_literal.array;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqual(@as(usize, 2), arr[0].array.len);
    try testing.expectEqual(@as(i64, 1), arr[0].array[0].fixnum);
    try testing.expectEqual(@as(i64, 2), arr[0].array[1].fixnum);
    try testing.expectEqual(@as(usize, 1), arr[1].array.len);
    try testing.expectEqual(@as(i64, 3), arr[1].array[0].fixnum);
}

test "serializeQuotationInstructions: roundtrip empty hash" {
    const h = HashTable{};
    const h_ptr = try testing.allocator.create(HashTable);
    h_ptr.* = h;
    defer testing.allocator.destroy(h_ptr);
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .hash = h_ptr } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer {
        for (decoded) |instr| {
            switch (instr.op) {
                .push_literal => |v| {
                    if (v == .hash) {
                        v.hash.deinit(testing.allocator);
                        testing.allocator.destroy(v.hash);
                    }
                },
                .call_word => |n| testing.allocator.free(n),
            }
        }
        testing.allocator.free(decoded);
    }
    try testing.expect(decoded[0].op.push_literal == .hash);
    try testing.expectEqual(@as(u32, 0), decoded[0].op.push_literal.hash.count());
}

test "serializeQuotationInstructions: roundtrip hash with entries" {
    var h = HashTable{};
    try h.put(testing.allocator, "x", .{ .fixnum = 10 });
    try h.put(testing.allocator, "y", .{ .boolean = false });
    defer h.deinit(testing.allocator);
    const h_ptr = try testing.allocator.create(HashTable);
    h_ptr.* = h;
    defer testing.allocator.destroy(h_ptr);
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .hash = h_ptr } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer {
        for (decoded) |instr| {
            switch (instr.op) {
                .push_literal => |v| {
                    if (v == .hash) {
                        var iter = v.hash.iterator();
                        while (iter.next()) |entry| {
                            testing.allocator.free(entry.key_ptr.*);
                        }
                        v.hash.deinit(testing.allocator);
                        testing.allocator.destroy(v.hash);
                    }
                },
                .call_word => |n| testing.allocator.free(n),
            }
        }
        testing.allocator.free(decoded);
    }
    const dh = decoded[0].op.push_literal.hash;
    try testing.expectEqual(@as(u32, 2), dh.count());
    try testing.expectEqual(@as(i64, 10), dh.get("x").?.fixnum);
    try testing.expectEqual(false, dh.get("y").?.boolean);
}

test "serializeQuotationInstructions: roundtrip array containing symbol" {
    // Matches the `{ cond: }` pattern from prelude.1z
    const elems = [_]Value{.{ .symbol = "cond" }};
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .array = &elems } }, .line = 1 },
    };
    const data = try serializeQuotationInstructions(&instrs, testing.allocator);
    defer testing.allocator.free(data);
    const decoded = try deserializeQuotationInstructions(data, testing.allocator);
    defer {
        for (decoded) |instr| {
            switch (instr.op) {
                .push_literal => |v| {
                    if (v == .array) {
                        for (v.array) |elem| {
                            if (elem == .symbol) testing.allocator.free(elem.symbol);
                        }
                        testing.allocator.free(v.array);
                    }
                },
                .call_word => |n| testing.allocator.free(n),
            }
        }
        testing.allocator.free(decoded);
    }
    const arr = decoded[0].op.push_literal.array;
    try testing.expectEqual(@as(usize, 1), arr.len);
    try testing.expectEqualStrings("cond", arr[0].symbol);
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
    // No stack effect annotation, so quotation_slots is empty. The call
    // inserts row_region instead of setting dynamic_call_emitted, and the
    // word compiles successfully via the row_region finalization path.
    const instrs = makeInstructions(.{"call"});
    const result = try compileWord(&instrs, 2, 0, null, null, null, null, null);
    defer result.jit_buf.deinit();
}

test "push after row_region compiles successfully" {
    // ( x quot -- )  body: call 42
    // After call inserts row_region, the push_literal for 42 succeeds
    // because it operates above the opaque region.
    const instrs = makeInstructions(.{ "call", @as(i64, 42) });
    const result = try compileWord(&instrs, 2, 0, null, null, null, null, null);
    defer result.jit_buf.deinit();
}

test "row_region with row-variable quotation effect compiles" {
    // ( ..a quot: ( ..x -- ..y ) -- )  body: call
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
    // After call inserts row_region, push 42 adds above it, then drop
    // removes it. The row_region remains but sp is back to 1.
    const instrs = makeInstructions(.{ "call", @as(i64, 42), "drop" });
    const result = try compileWord(&instrs, 2, 0, null, null, null, null, null);
    defer result.jit_buf.deinit();
}

test "multiple pushes above row_region compile" {
    // ( x quot -- )  body: call 1 2 3
    // Stacking values above the row_region succeeds.
    const instrs = makeInstructions(.{ "call", @as(i64, 1), @as(i64, 2), @as(i64, 3) });
    const result = try compileWord(&instrs, 2, 0, null, null, null, null, null);
    defer result.jit_buf.deinit();
}

test "dup on row_region entry returns NotCompilable" {
    // ( x quot -- )  body: call dup
    // After call inserts row_region at slot 0 with sp=1, dup tries to
    // copy slot 0 (the row_region) which returns NotCompilable.
    const instrs = makeInstructions(.{ "call", "dup" });
    const result = compileWord(&instrs, 2, 0, null, null, null, null, null);
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
    try rewriteIndexedStackOp(&state, "pick-n", &stack, &sp, 2);
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
    try rewriteIndexedStackOp(&state, "pick-n", &stack, &sp, 0);
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
    try rewriteIndexedStackOp(&state, "<rot-n", &stack, &sp, 2);
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
    try rewriteIndexedStackOp(&state, "<rot-n", &stack, &sp, 0);
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
    try rewriteIndexedStackOp(&state, "rot-n>", &stack, &sp, 2);
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
    try rewriteIndexedStackOp(&state, "rot-n>", &stack, &sp, 0);
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
    try rewriteIndexedStackOp(&state, "nip-n", &stack, &sp, 2);
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
    try rewriteIndexedStackOp(&state, "nip-n", &stack, &sp, 0);
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
    try rewriteIndexedStackOp(&state, "<rot-n", &stack, &sp, 1);
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
    try rewriteIndexedStackOp(&state, "nip-n", &stack, &sp, 1);
    try testing.expectEqual(@as(usize, 3), sp);
    try testing.expectEqual(StackEntry{ .row_region = 0 }, stack[0]);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 1 }, stack[1]);
    try testing.expectEqual(StackEntry{ .raw_at_slot = 3 }, stack[2]);
}
