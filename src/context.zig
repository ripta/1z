const std = @import("std");
const Allocator = std.mem.Allocator;

const Stack = @import("stack.zig").Stack;
const dict_mod = @import("dictionary.zig");
const Dictionary = dict_mod.Dictionary;
const container_backing = @import("container_backing.zig");

const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const Quotation = value_mod.Quotation;
const Value = value_mod.Value;

const debugger_mod = @import("debugger/mod.zig");

const dispatch_helpers = @import("primitives/dispatch_helpers.zig");
const protocols_mod = @import("primitives/protocols.zig");

const dispatch_mod = @import("dispatch.zig");
const DispatchEntry = dispatch_mod.DispatchEntry;
const DispatchKey = dispatch_mod.DispatchKey;
const DispatchFrame = dispatch_mod.DispatchFrame;
const DispatchTable = dispatch_mod.DispatchTable;

const pic_mod = @import("pic.zig");
const PicTable = pic_mod.PicTable;
const PolymorphicCache = pic_mod.PolymorphicCache;
const JitDispatchTable = @import("jit_dispatch.zig").JitDispatchTable;
const ir_codegen = @import("ir_codegen.zig");
const bail_stats_mod = @import("bail_stats.zig");
const Scheduler = @import("scheduler.zig").Scheduler;
const WorkerPool = @import("worker.zig").WorkerPool;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const types_mod = @import("primitives/types.zig");
const Capability = types_mod.Capability;
const SandboxSpec = types_mod.SandboxSpec;
const primitives = @import("primitives.zig");
const parser = @import("parser.zig");
const BenchmarkStats = @import("benchmark.zig").BenchmarkStats;
const ProfileStats = @import("profile.zig").ProfileStats;
const StatementProcessor = @import("statement.zig").StatementProcessor;

const trace_mod = @import("trace.zig");
const TraceConfig = trace_mod.TraceConfig;

const pascalToKebabRuntime = @import("primitives/errors.zig").pascalToKebabRuntime;
const markers_mod = @import("primitives/markers.zig");
const HookRegistry = @import("primitives/hooks.zig").HookRegistry;

const stack_effect_mod = @import("stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;
const StackEffectParam = stack_effect_mod.StackEffectParam;

const lock_order = @import("lock_order.zig");
const LockOrderTracker = lock_order.LockOrderTracker;

const signal = @import("signal.zig");
const control = @import("primitives/control.zig");
const nativeSuppressChecksValidator = @import("effect_inference.zig").nativeSuppressChecksValidator;
const helpers = @import("primitives/helpers.zig");

/// Embedded prelude source code
pub const prelude_source = @embedFile("prelude.1z");

pub const CompileMode = enum { off, eager, hybrid };

/// Scope for `validateTypeAnnotationsScoped`: `all` validates every annotation,
/// `except_protocols` skips protocol bounds (used at compiled protocol-bounded
/// dispatch sites, where the dispatch helper checks the bound itself).
pub const AnnotationScope = enum { all, except_protocols };

pub const ExecutionError = error{
    UnknownWord,
    StackUnderflow,
    OutOfMemory,
};

/// CallFrame represents a single frame in the call stack.
pub const CallFrame = struct {
    word_name: []const u8,
    source: []const u8,
    line: usize,
    column: usize = 0,
};

/// ParameterFrame holds parameter bindings for dynamic scoping.
/// Each frame is a mapping from parameter name to its bound value.
pub const ParameterFrame = std.StringHashMapUnmanaged(Value);

/// LocalFrame holds word definitions for lexical scoping within quotations.
/// Each frame is a mapping from word name to its definition.
pub const LocalFrame = std.StringHashMapUnmanaged(WordDefinition);
const WordDefinition = @import("dictionary.zig").WordDefinition;

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

/// PragmaRegistration holds metadata for a registered pragma key.
/// If both validators are null, the pragma accepts only boolean values.
/// If validator is a quotation, it is called with the value on the stack
/// and must push validated_value t (success) or error_msg f (failure).
/// If native_validator is set, it is called instead of the quotation validator
/// with the same protocol.
pub const PragmaRegistration = struct {
    validator: ?value_mod.Quotation = null,
    native_validator: ?*const fn (*Context) anyerror!void = null,
};

/// PragmaFrame holds pragma values for the current file scope.
pub const PragmaFrame = std.StringHashMapUnmanaged(Value);

/// TypeRegistryFrame holds type descriptor and enum registry entries for
/// a single scope. Pushed/popped by `with-isolation` to enable rollback
/// of type registrations.
pub const TypeRegistryFrame = struct {
    type_descriptors: std.StringHashMapUnmanaged(*value_mod.TypeDescriptor) = .{},
    enum_registry: std.AutoHashMapUnmanaged(*const value_mod.TypeValue, []const *const value_mod.VirtualType) = .{},

    pub fn deinit(self: *TypeRegistryFrame, allocator: Allocator) void {
        self.type_descriptors.deinit(allocator);
        self.enum_registry.deinit(allocator);
    }
};

pub const ParameterizedTypeKey = struct {
    base: *const value_mod.TypeValue,
    element: *const value_mod.TypeValue,
};

pub const ParameterizedTypeKeyContext = struct {
    pub fn hash(_: @This(), key: ParameterizedTypeKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&@intFromPtr(key.base)));
        h.update(std.mem.asBytes(&@intFromPtr(key.element)));
        return h.final();
    }

    pub fn eql(_: @This(), a: ParameterizedTypeKey, b: ParameterizedTypeKey) bool {
        return a.base == b.base and a.element == b.element;
    }
};

pub const StructDescriptorKey = struct {
    fields: []const []const u8,
    field_types: []const ?*const value_mod.TypeValue = &.{},
    mutable: bool,
};

pub const StructDescriptorKeyContext = struct {
    pub fn hash(_: @This(), key: StructDescriptorKey) u64 {
        var h = std.hash.Wyhash.init(0);
        const mutable_byte: u8 = if (key.mutable) 1 else 0;
        h.update(&[_]u8{mutable_byte});
        for (key.fields) |field| {
            h.update(field);
            h.update(&[_]u8{0});
        }
        h.update(std.mem.asBytes(&key.field_types.len));
        for (key.field_types) |field_type| {
            const ptr_value: usize = if (field_type) |tv| @intFromPtr(tv) else 0;
            h.update(std.mem.asBytes(&ptr_value));
        }
        return h.final();
    }

    pub fn eql(_: @This(), a: StructDescriptorKey, b: StructDescriptorKey) bool {
        if (a.mutable != b.mutable or a.fields.len != b.fields.len or a.field_types.len != b.field_types.len) return false;
        for (a.fields, b.fields) |a_field, b_field| {
            if (!std.mem.eql(u8, a_field, b_field)) return false;
        }
        for (a.field_types, b.field_types) |a_field_type, b_field_type| {
            if (a_field_type != b_field_type) return false;
        }
        return true;
    }
};

/// Key for anonymous union interning, represented by the sorted unique member set.
pub const AnonymousUnionKey = struct {
    members: []const *const value_mod.TypeValue,
};

/// Context for anonymous union interning keys.
pub const AnonymousUnionKeyContext = struct {
    pub fn hash(_: @This(), key: AnonymousUnionKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&key.members.len));
        for (key.members) |member| {
            const ptr_value = @intFromPtr(member);
            h.update(std.mem.asBytes(&ptr_value));
        }
        return h.final();
    }

    pub fn eql(_: @This(), a: AnonymousUnionKey, b: AnonymousUnionKey) bool {
        if (a.members.len != b.members.len) return false;
        for (a.members, b.members) |a_member, b_member| {
            if (a_member != b_member) return false;
        }
        return true;
    }
};

/// A deferred protocol obligation recorded during module loading.
///
/// Validated after all definitions in the module have been processed.
///
/// The descriptor pointer is the durable handle to the protocol's methods and name; resolving the
/// type's `TypeValue` happens at validation time.
pub const ProtocolObligation = struct {
    type_name: []const u8,
    descriptor: *const value_mod.ProtocolDescriptor,
};

/// Key for the per-context protocol satisfies-check memo.
///
/// It's keyed on the pointer pair of the implementing type's descriptor and the protocol descriptor.
/// Both pointers are stable for the lifetime of the `Context`.
pub const ProtocolSatisfiesKey = struct {
    type_descriptor: *const value_mod.TypeDescriptor,
    protocol_descriptor: *const value_mod.ProtocolDescriptor,
};

pub const ProtocolSatisfiesKeyContext = struct {
    pub fn hash(_: @This(), key: ProtocolSatisfiesKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&@intFromPtr(key.type_descriptor)));
        h.update(std.mem.asBytes(&@intFromPtr(key.protocol_descriptor)));
        return h.final();
    }

    pub fn eql(_: @This(), a: ProtocolSatisfiesKey, b: ProtocolSatisfiesKey) bool {
        return a.type_descriptor == b.type_descriptor and
            a.protocol_descriptor == b.protocol_descriptor;
    }
};

/// ErrorDetail captures information about an error for debugging purposes.
pub const ErrorDetail = struct {
    error_type: []const u8,
    message: []const u8,
    source: []const u8,
    line: usize,
    word_name: ?[]const u8,
    stack_effect_str: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    dispatch_actual_types: ?[]const u8 = null,
    dispatch_available_methods: ?[]const u8 = null,
};

/// Structured context for parse-time errors, populated by the parser's catch
/// blocks and consumed by the display sites in main.zig. Separates parse error
/// context from runtime error_details to avoid cross-contamination.
pub const ParseDiagnostics = struct {
    message: ?[]const u8 = null,
    error_type: ?[]const u8 = null,
    opening_line: ?usize = null,
    source_file: ?[]const u8 = null,
};

pub const AotQuotationFnTable = struct {
    table: [*]const ?*const anyopaque,
    size: u32,
};

/// The Context holds all interpreter state.
pub const Context = struct {
    stack: Stack,
    dictionary: Dictionary,
    arena: std.heap.ArenaAllocator,
    /// Instruction slices belonging to quotations the parser or `curry`
    /// allocated on this context's `arena`, recorded so the captured
    /// container literals can be released before the arena tears down.
    /// Only quotations whose body contains at least one container
    /// `push_literal` are recorded; the scan happens once at
    /// construction.
    container_release_list: std.ArrayListUnmanaged([]const Instruction) = .{},
    allocator: Allocator,
    call_stack: std.ArrayListUnmanaged(CallFrame),
    error_details: std.ArrayListUnmanaged(ErrorDetail),
    /// Parameter environment frames for dynamic scoping
    parameter_env: std.ArrayListUnmanaged(ParameterFrame),
    /// Local definition frames for lexical scoping within quotations
    local_frames: std.ArrayListUnmanaged(LocalFrame),
    /// Tokenizer for parse-time word access (set during parsing, null otherwise)
    parse_tokenizer: ?*Tokenizer = null,
    /// Deferred call_word emissions requested by parse-time words via `emit-call`
    parse_time_deferred_calls: std.ArrayListUnmanaged([]const u8) = .{},
    /// Optional benchmark stats (null when benchmarking is disabled)
    benchmark: ?*BenchmarkStats = null,
    /// Optional word-attributed profile stats (null when --profile is unset)
    profile: ?*ProfileStats = null,
    /// Counters for unique VirtualType/StructType allocations, used by
    /// --benchmark to report prelude output inventory.
    virtual_type_count: usize = 0,
    struct_type_count: usize = 0,
    /// Current source file name for error reporting (defaults to "<repl>")
    current_source: []const u8 = "<repl>",
    /// Tail call target for TCO, which is set by executeInstructions and consumed by executeQuotation
    tail_call_instructions: ?[]const Instruction = null,
    /// Module whose deps frame should be pushed for the tail call target.
    /// Set alongside tail_call_instructions when the tail-called word has a source_module.
    tail_call_module: ?*const value_mod.Module = null,
    /// Source file of the tail call target, for execution-source tracking.
    /// Set alongside tail_call_instructions when the tail-called word has a source_file.
    tail_call_source: ?[]const u8 = null,
    /// Directory of the currently executing source file for relative path resolution
    current_source_dir: ?[]const u8 = null,
    /// User-configured load paths for search-mode module resolution
    load_paths: std.ArrayListUnmanaged([]const u8) = .{},
    /// Standard library path, which is resolved last
    stdlib_path: ?[]const u8 = null,
    /// Program arguments passed after the file path on the command line
    program_args: []const []const u8 = &.{},
    /// Library names registered as statically linked into the executable.
    /// When lib-open encounters one of these names, it uses dlopen(NULL)
    /// instead of loading a shared library.
    static_ffi_libs: []const []const u8 = &.{},
    /// Target frame index for `import` to write definitions into.
    /// Set by `load` to its local frame index so that `import` (which may run
    /// inside combinator frames like `if`) writes to the load frame, not to
    /// an ephemeral combinator frame. When null, `import` writes to the
    /// global dictionary.
    import_frame_index: ?usize = null,
    /// True while a `load` call is executing. Blocking primitives (yield,
    /// sleep, await, await-all, send, receive, select) check this flag and
    /// throw an error to prevent yielding mid-load, which would expose
    /// half-defined module frames to other tasks via ancestor traversal.
    in_module_load: bool = false,
    /// Re-entrancy guard for scoped hooks (e.g., word-defined).
    firing_scoped_hooks: bool = false,
    /// Deferred protocol obligations collected during module loading.
    /// Validated at module load completion so that methods defined after the
    /// protocol declaration in the same file are still found.
    protocol_obligations: std.ArrayListUnmanaged(ProtocolObligation) = .{},
    /// True while parsing a definition body that has a parse-time or
    /// parse-time-only marker. Used by the parser to allow parse-time-only
    /// words inside parse-time definitions.
    parsing_parse_time_def: bool = false,
    /// Source file of the current parse-time word invocation.
    /// Set by the parser before invoking a parse-time word body (before any
    /// compound-word execution-source tracking can change current_source).
    parse_time_source_file: []const u8 = "",
    /// Source line of the current parse-time word invocation (file-relative).
    /// Set by executeParseTimeWord with save/restore for nesting.
    parse_time_source_line: usize = 0,
    /// Source column of the current parse-time word invocation.
    parse_time_source_column: usize = 0,
    /// Source file of the file currently being loaded by nativeLoadImpl.
    /// Set and restored via save-restore in nativeLoadImpl so that runtime words,
    /// like `reexport`, which execute inside the loaded file's body, can record
    /// the correct import source, even after execution-source tracking updates
    /// current_source to their own defining file.
    load_file_source: ?[]const u8 = null,
    /// Offset to convert tokenizer-relative line numbers to file-relative.
    /// The tokenizer restarts at line 1 for each statement. This offset is
    /// the file line where the current statement starts minus 1.
    parse_line_offset: usize = 0,
    /// Accumulated import records from `use` and `reexport` calls.
    import_history: std.ArrayListUnmanaged(Value) = .{},
    /// Cache of loaded modules keyed by canonical file path.
    /// Prevents redundant loading when multiple files `use` the same module.
    /// Stored as an M{} value so it can be exposed as a dynamic parameter.
    module_cache_value: *value_mod.MutableMap = undefined,
    /// Stashed error object from user `throw`, consumed by `recover`.
    /// Arena-allocated; owned by the context arena and freed at context
    /// teardown. The `recover` primitive can clear the slot but does not
    /// individually free the box because the arena does not support it.
    thrown_error: ?*value_mod.ErrorObject = null,
    /// Parse-time error diagnostics, populated by the parser catch blocks
    /// and consumed by the display sites in main.zig.
    parse_diagnostics: ?ParseDiagnostics = null,
    /// Pending error message set by primitives before returning an error.
    /// Used by captureCallStackOnError for the innermost frame's message.
    pending_error_message: ?[]const u8 = null,
    /// Pending error hint set by primitives before returning an error.
    /// Consumed by captureCallStackOnError for the innermost frame's hint.
    pending_error_hint: ?[]const u8 = null,
    /// Pending generic-dispatch argument type tuple for the innermost frame.
    pending_dispatch_actual_types: ?[]const u8 = null,
    /// Pending generic-dispatch method list for the innermost frame.
    pending_dispatch_available_methods: ?[]const u8 = null,
    /// Error captured by the FFI callback trampoline when a 1z quotation throws.
    /// Checked and cleared by nativeFfiCall after ffi_call returns.
    callback_error: ?anyerror = null,
    /// Human-readable context string for the callback error.
    callback_error_context: ?[]const u8 = null,
    /// Optional debugger. When non-null, the execution loop checks whether to
    /// pause before each instruction. When null (the default), the cost is a
    /// single pointer check per instruction.
    ///
    /// TODO(ripta): Consider making this a comptime flag to eliminate the pointer check.
    debugger: ?*debugger_mod.Debugger = null,
    /// Execution tracing configuration, parsed from CLI flags.
    trace: TraceConfig = .{},
    /// Wall-clock stall detection threshold in nanoseconds, parsed from --deadlock-detect[=N].
    deadlock_detect_ns: ?i128 = null,
    /// Monotonic counter for assigning unique dispatch IDs to word definitions.
    /// Atomic for future thread-safety requirements.
    next_dispatch_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Monotonic counter for assigning unique IDs to protocol descriptors.
    /// Atomic for future thread-safety requirements (M:N scheduler).
    next_protocol_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Dispatch table for user-defined operator/method dispatch.
    dispatch: DispatchTable,
    /// JIT dispatch table mapping word IDs to compiled code pointers.
    jit_dispatch: JitDispatchTable,
    /// AOT quotation function pointers, indexed by quotation_id.
    /// Registered at startup by onez_runtime_register_quotations.
    aot_quotation_fns: ?AotQuotationFnTable = null,
    /// Runtime-image slot tables, cached at load time so the
    /// compiled-code helpers (`jitPushTypeValueSlot`,
    /// `jitPushStructTypeSlot`, etc.) can resolve typed-literal
    /// pushes without a runtime dictionary lookup. Each pointer is
    /// null when the corresponding table was not emitted (zero
    /// slots). Populated by `aot_image_loader.loadIntoContext`.
    image_typevalue_slots: ?[*]?*const value_mod.TypeValue = null,
    image_struct_type_slots: ?[*]?*value_mod.StructType = null,
    image_marker_slots: ?[*]?*value_mod.Marker = null,
    image_parameter_slots: ?[*]?*value_mod.Parameter = null,
    image_tagged_slots: ?[*]?*const value_mod.Value = null,
    image_mutable_map_slots: ?[*]?*value_mod.MutableMap = null,
    image_typevalue_slot_count: u32 = 0,
    image_struct_type_slot_count: u32 = 0,
    image_marker_slot_count: u32 = 0,
    image_parameter_slot_count: u32 = 0,
    image_tagged_slot_count: u32 = 0,
    image_mutable_map_slot_count: u32 = 0,
    /// Set true when `aot_image_loader.loadIntoContext` has populated
    /// this context from an AOT runtime image. Gates the module-cache
    /// fallback in `lookupWordForExecution` so the fallback only fires
    /// for runtime-image-loaded modules, where the loader places every
    /// word -- public and module-private -- into `module.words`.
    /// Normal interpreter sessions and `load`-based module loading
    /// leave this false, so the fallback stays inert and module
    /// privacy holds.
    runtime_image_loaded: bool = false,
    /// Pending error from a JIT error-handling callback (recover/cleanup).
    /// Set by the callback when it returns error_propagate status, consumed
    /// by the interpreter dispatch loop.
    jit_pending_error: ?anyerror = null,
    /// Defining source file for the currently executing compiled word.
    /// Used by JIT error callbacks so synthetic frames do not depend on the
    /// mutable runtime current_source.
    jit_trace_source: ?[]const u8 = null,
    /// Synthetic frames accumulated by compiled code on a cold error path.
    /// These are folded into error_details by captureCallStackOnError so the
    /// interpreter can still append its outer frames afterward.
    jit_pending_trace_frames: std.ArrayListUnmanaged(CallFrame) = .{},
    /// PIC cache mapping instruction slice pointers to their PIC tables.
    /// Lazily populated on first generic dispatch through a compound word body.
    pic_cache: std.AutoHashMapUnmanaged(usize, *PicTable) = .{},
    /// PIC entry for the current instruction, threaded through so native
    /// operators (arithmetic, comparison) can use it without signature changes.
    current_pic_entry: ?*PolymorphicCache = null,
    /// Shared scheduler for green thread contexts. Null for the root context.
    scheduler: ?*Scheduler = null,
    /// Atomic scheduler pointer for cross-thread diagnostic access.
    /// Set by task-scope on entry, cleared on exit. Read by the
    /// test-timeout watchdog thread as a fallback when no worker pool
    /// is active (REPL, single-eval, or unit-test paths).
    active_scheduler: std.atomic.Value(?*Scheduler) = std.atomic.Value(?*Scheduler).init(null),
    /// Atomic pool pointer for cross-thread diagnostic access. Set by
    /// the outermost `task-scope` on entry, cleared on exit. Preferred
    /// over `active_scheduler` by the test-timeout watchdog so dumps
    /// aggregate state across every worker.
    active_worker_pool: std.atomic.Value(?*WorkerPool) = std.atomic.Value(?*WorkerPool).init(null),
    /// Worker pool backing the M:N scheduler. Set by the outermost
    /// `task-scope` and read by `spawn` to pick a least-loaded worker.
    /// Null outside any `task-scope`.
    worker_pool: ?*WorkerPool = null,
    /// Stack of type registry frames for scoped type descriptor and enum
    /// registry entries. The bottom frame holds boot-time registrations;
    /// additional frames are pushed by `with-isolation`.
    type_registry_frames: std.ArrayListUnmanaged(TypeRegistryFrame) = .{},
    /// Stack of dispatch frames layered on top of `dispatch.entries`.
    /// Pushed by `with-isolation` for scoped method registrations.
    dispatch_frames: std.ArrayListUnmanaged(DispatchFrame) = .{},
    /// Mapping from type name to registered TypeValue for built-in types.
    /// Populated by `define-builtin-type`; used by `type-of` for lookup.
    builtin_type_values: std.StringHashMapUnmanaged(*value_mod.TypeValue) = .{},
    /// O(1) lookup of builtin TypeValue by Value discriminant index.
    /// Populated at init time for all discriminants. The three dynamic
    /// variants (.tagged, .struct_instance, .resource) have entries here
    /// but callers should prefer the TypeValue embedded in those values.
    builtin_type_array: []?*value_mod.TypeValue = &.{},
    /// Runtime-initialized dispatch wildcard TypeValue.
    dispatch_any_sentinel: ?*value_mod.TypeValue = null,
    /// Runtime-initialized unary dispatch sentinel TypeValue.
    dispatch_unary_sentinel: ?*value_mod.TypeValue = null,
    /// Runtime-initialized protocol `self` type sentinel.
    self_type_sentinel: ?*value_mod.TypeValue = null,
    /// Runtime-initialized protocol `any` type sentinel.
    any_type_sentinel: ?*value_mod.TypeValue = null,
    /// Cache of TypeValues for resource types, keyed by resource type name.
    /// Lazily populated by `type-of` when encountering a resource.
    resource_type_values: std.StringHashMapUnmanaged(*value_mod.TypeValue) = .{},
    /// Interned descriptors for parameterized types, keyed by
    /// (base TypeValue pointer, element TypeValue pointer).
    parameterized_type_descriptors: std.HashMapUnmanaged(
        ParameterizedTypeKey,
        *value_mod.TypeDescriptor,
        ParameterizedTypeKeyContext,
        80,
    ) = .{},
    /// Interned descriptors for bare structs, keyde by ordered field names and by mutability.
    struct_descriptors: std.HashMapUnmanaged(
        StructDescriptorKey,
        *value_mod.TypeDescriptor,
        StructDescriptorKeyContext,
        80,
    ) = .{},
    /// Interned anonymous union TypeValues keyed by sorted unique member pointers.
    anonymous_union_type_values: std.HashMapUnmanaged(
        AnonymousUnionKey,
        *value_mod.TypeValue,
        AnonymousUnionKeyContext,
        80,
    ) = .{},
    /// Owned storage for ProtocolDescriptor records allocated via
    /// createProtocolDescriptor. Each protocol{ definition produces a fresh
    /// descriptor; the list keeps stable pointers for the lifetime of the
    /// Context and lets deinit release the list header.
    protocol_descriptors: std.ArrayListUnmanaged(*value_mod.ProtocolDescriptor) = .{},
    /// Memo of protocol satisfies-check results keyed on the
    /// (implementing type descriptor, protocol descriptor) pointer pair.
    /// Populated lazily on first check, and coarsely invalidated on any
    /// dispatch-table mutation (method registration or dispatch-frame pop)
    /// so a `(type, protocol)` answer cannot stay stale across a REPL or
    /// runtime `method{` binding.
    protocol_satisfies_cache: std.HashMapUnmanaged(
        ProtocolSatisfiesKey,
        bool,
        ProtocolSatisfiesKeyContext,
        80,
    ) = .{},
    /// Memo of the diagnostic identity (`satisfies-and-dispatch[<protocol>]`)
    /// shown for protocol-bounded dispatch sites in word traces, scheduler
    /// dumps, and error backtraces. Keyed by protocol descriptor so all call
    /// sites bound by the same protocol share one program-lifetime string;
    /// populated during compilation, never on the runtime hot path.
    bounded_dispatch_trace_names: std.AutoHashMapUnmanaged(
        *const value_mod.ProtocolDescriptor,
        []const u8,
    ) = .{},
    /// Registry of known pragma keys and their validation rules.
    pragma_registry: std.StringHashMapUnmanaged(PragmaRegistration) = .{},
    /// Stack of pragma frames for file-scoped pragma values.
    pragma_frames: std.ArrayListUnmanaged(PragmaFrame) = .{},
    /// When true, only definition statements (ending with `;`) are executed
    /// at the top level. All other runtime statements are skipped. Parse-time
    /// words still execute during parsing.
    check_mode: bool = false,
    /// When true, disables both definition-time non-tail-recursion analysis
    /// and the runtime marker consistency check.
    allow_all_recursion: bool = false,
    stack_limit: usize = 0,
    stack_high: usize = 0,
    /// Parent context for dictionary and dispatch table lookup chaining.
    /// Task contexts walk this chain to find words and methods defined in
    /// ancestor scopes, up to the root context which holds primitives and
    /// prelude words.
    parent_context: ?*const Context = null,
    /// RwLock protecting shared registries. Heap-allocated by the root context
    /// and shared by reference to all child task contexts.
    shared_lock: *std.Thread.RwLock = undefined,
    /// Debug-only tracker that asserts lock acquisition respects the ordering
    /// hierarchy: context > channel > tz. Heap-allocated by the root context.
    lock_order_tracker: *LockOrderTracker = undefined,
    /// Runtime gate for the permissive AOT fallback path. When false,
    /// `jitInterpretedCall` and `jitCallQuotation` crash with a diagnostic
    /// instead of falling back to the interpreter. Set by
    /// `onez_set_interpreter_fallback` in AOT binaries. Interpreter-free
    /// binaries do not link `jitInterpretedCall` at all, so this field is
    /// only consulted in builds where the extern was emitted.
    allow_interpreted_fallback: bool = true,
    /// Controls automatic JIT compilation of word definitions.
    /// When .eager, every word defined via defineWord is automatically
    /// compiled. Compilation failures are silently ignored and the
    /// word falls back to the interpreter.
    compile_mode: CompileMode = .off,
    hybrid_threshold: u32 = 100,
    hybrid_effective_threshold: u32 = 100,
    hybrid_recent_compilations: u32 = 0,
    /// Active sandbox spec restricting which capabilities are available.
    /// When non-null, word lookup checks the word's capability against
    /// this spec and rejects words whose capability is not granted.
    active_sandbox: ?*const SandboxSpec = null,
    /// Number of OS threads for the scheduler. 0 means auto-detect from CPU count.
    worker_count: usize = 0,
    /// Shared hook registry for lifecycle event callbacks.
    /// Allocated on the container arena by the root context and shared by
    /// pointer to all child task contexts.
    hook_registry: *HookRegistry = undefined,

    /// Returns true when the instruction sequence ends with a call to `;`,
    /// which means it is a word definition and should be executed even in
    /// check mode.
    pub fn isDefinitionStatement(instrs: []const Instruction) bool {
        if (instrs.len == 0) return false;
        return switch (instrs[instrs.len - 1].op) {
            .call_word => |name| std.mem.eql(u8, name, ";"),
            .call_word_direct => |slot| std.mem.eql(u8, slot.name, ";"),
            .push_literal => false,
        };
    }

    fn builtinDescriptorFlags(comptime tag: std.meta.Tag(value_mod.Value)) value_mod.DescriptorFlags {
        return switch (tag) {
            .fixnum, .bignum => .{ .numeric = true, .exact = true, .integer = true },
            .float => .{ .numeric = true },
            .vector, .byte_array, .mutable_map, .stream, .channel => .{ .mutable = true },
            else => .{},
        };
    }

    fn initSentinelTypeValues(self: *Context) !void {
        const alloc = self.arena.allocator();

        const dispatch_any_desc = try value_mod.createSentinelTypeDescriptor(alloc);
        const dispatch_any = try alloc.create(value_mod.TypeValue);
        dispatch_any.* = .{ .name = "*", .descriptor = dispatch_any_desc };
        self.dispatch_any_sentinel = dispatch_any;

        const dispatch_unary_desc = try value_mod.createSentinelTypeDescriptor(alloc);
        const dispatch_unary = try alloc.create(value_mod.TypeValue);
        dispatch_unary.* = .{ .name = "", .descriptor = dispatch_unary_desc };
        self.dispatch_unary_sentinel = dispatch_unary;

        const type_sentinel_desc = try value_mod.createSentinelTypeDescriptor(alloc);

        const self_sentinel = try alloc.create(value_mod.TypeValue);
        self_sentinel.* = .{ .name = "self", .descriptor = type_sentinel_desc };
        self.self_type_sentinel = self_sentinel;

        const any_sentinel = try alloc.create(value_mod.TypeValue);
        any_sentinel.* = .{ .name = "any", .descriptor = type_sentinel_desc };
        self.any_type_sentinel = any_sentinel;
    }

    /// Pre-create TypeValue objects for all builtin Value discriminants.
    /// Called during init() before registerNativeDispatch().
    fn initBuiltinTypeValues(self: *Context) !void {
        const alloc = self.arena.allocator();
        const num_variants = comptime @typeInfo(value_mod.Value).@"union".fields.len;

        const arr = try alloc.alloc(?*value_mod.TypeValue, num_variants);
        @memset(arr, null);
        self.builtin_type_array = arr;

        inline for (0..num_variants) |i| {
            const tag: std.meta.Tag(value_mod.Value) = @enumFromInt(i);
            const name = dispatch_mod.builtinTypeName(tag);

            // Umbrella type names (e.g. `constraint`) cover more than one
            // variant tag. Reuse an already-allocated TypeValue when its
            // name matches so `type-of` returns the same pointer and a
            // single entry survives in `builtin_type_values`.
            const tv = if (self.builtin_type_values.get(name)) |existing| existing else blk: {
                const desc = try value_mod.createBuiltinTypeDescriptor(
                    alloc,
                    builtinDescriptorFlags(tag),
                );
                const new_tv = try alloc.create(value_mod.TypeValue);
                new_tv.* = .{ .name = name, .descriptor = desc };
                try self.builtin_type_values.put(self.allocator, name, new_tv);
                break :blk new_tv;
            };

            self.builtin_type_array[i] = tv;
        }
    }

    /// Initialize a new interpreter context with an empty stack and primitives.
    /// Note: This does NOT load the prelude. Call loadPrelude() separately.
    pub fn init(allocator: Allocator) Context {
        var ctx = Context{
            .stack = Stack.init(allocator),
            .dictionary = Dictionary.init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
            .allocator = allocator,
            .call_stack = .{},
            .error_details = .{},
            .parameter_env = .{},
            .local_frames = .{},
            .parse_tokenizer = null,
            .benchmark = null,
            .dispatch = DispatchTable.init(allocator),
            .jit_dispatch = JitDispatchTable.init(allocator),
        };

        ctx.shared_lock = allocator.create(std.Thread.RwLock) catch |err| {
            std.debug.panic("Failed to allocate shared lock: {any}", .{err});
        };
        ctx.shared_lock.* = .{};

        ctx.lock_order_tracker = allocator.create(LockOrderTracker) catch |err| {
            std.debug.panic("Failed to allocate lock order tracker: {any}", .{err});
        };
        ctx.lock_order_tracker.* = .{};

        // Allocate the module cache M{} via the refcounted container path so
        // it survives cross-worker mutation and is freed deterministically
        // during root-context teardown.
        ctx.module_cache_value = value_mod.MutableMap.create(allocator) catch |err| {
            std.debug.panic("Failed to allocate module cache: {any}", .{err});
        };

        // Allocate the shared hook registry on the long-lived allocator; the
        // root context frees it in deinit.
        ctx.hook_registry = allocator.create(HookRegistry) catch |err| {
            std.debug.panic("Failed to allocate hook registry: {any}", .{err});
        };
        ctx.hook_registry.* = .{};

        // Push base parameter frame so scoped hooks can be registered at top level.
        ctx.parameter_env.append(allocator, .{}) catch |err| {
            std.debug.panic("Failed to push base parameter frame: {any}", .{err});
        };

        // Push the base type registry frame so boot-time registrations have a target.
        ctx.type_registry_frames.append(allocator, .{}) catch |err| {
            std.debug.panic("Failed to push base type registry frame: {any}", .{err});
        };

        ctx.initSentinelTypeValues() catch |err| {
            std.debug.panic("Failed to init sentinel type values: {any}", .{err});
        };

        ctx.initBuiltinTypeValues() catch |err| {
            std.debug.panic("Failed to init builtin type values: {any}", .{err});
        };

        primitives.registerPrimitives(&ctx.dictionary, ctx.arena.allocator(), &ctx.next_dispatch_id) catch |err| {
            std.debug.panic("Failed to register primitives: {any}", .{err});
        };

        primitives.createNativeModule(&ctx.dictionary, ctx.arena.allocator(), &ctx.next_dispatch_id) catch |err| {
            std.debug.panic("Failed to create native module: {any}", .{err});
        };

        primitives.registerNativeDispatch(&ctx.dispatch, &ctx) catch |err| {
            std.debug.panic("Failed to register native dispatch: {any}", .{err});
        };

        return ctx;
    }

    /// Initialize context and load prelude. Convenience method for non-benchmark use.
    pub fn initWithPrelude(allocator: Allocator) Context {
        var ctx = init(allocator);
        ctx.loadPrelude(null) catch |err| {
            std.debug.panic("Failed to load prelude: {any}", .{err});
        };
        return ctx;
    }

    /// Create a lightweight Context for a spawned task. Primitives and the
    /// prelude are not registered here; they are resolved at lookup time
    /// by walking up the parent_context chain. Per-task state like the stack,
    /// dictionary, and arena are freshly allocated.
    pub fn initForTask(
        allocator: Allocator,
        parent: *Context,
        scheduler: *Scheduler,
    ) !Context {
        var ctx = Context{
            .stack = Stack.init(allocator),
            .dictionary = Dictionary.init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
            .allocator = allocator,
            .call_stack = .{},
            .error_details = .{},
            .parameter_env = .{},
            .local_frames = .{},
            .dispatch = DispatchTable.init(allocator),
            .jit_dispatch = JitDispatchTable.init(allocator),
            .scheduler = scheduler,
            .worker_pool = parent.worker_pool,
            .parent_context = parent,

            .trace = parent.trace,
            .deadlock_detect_ns = parent.deadlock_detect_ns,
            .current_source = parent.current_source,
            .current_source_dir = parent.current_source_dir,
            .load_paths = parent.load_paths,
            .stdlib_path = parent.stdlib_path,
            .program_args = parent.program_args,
            .static_ffi_libs = parent.static_ffi_libs,
            .builtin_type_array = parent.builtin_type_array,
            .dispatch_any_sentinel = parent.dispatch_any_sentinel,
            .dispatch_unary_sentinel = parent.dispatch_unary_sentinel,
            .self_type_sentinel = parent.self_type_sentinel,
            .any_type_sentinel = parent.any_type_sentinel,
        };

        // Share the parent's lock so all tasks use the same RwLock.
        ctx.shared_lock = parent.shared_lock;
        ctx.lock_order_tracker = parent.lock_order_tracker;

        // Share the parent's module cache so tasks don't re-load from disk.
        ctx.module_cache_value = parent.module_cache_value;

        // Inherit AOT runtime-image state from the parent so spawned tasks
        // can resolve image-backed literals (typed values, parameters,
        // markers, struct types, tagged values, mutable maps) and fall
        // through to the module-cache word table in `lookupWordForExecution`.
        // These tables and the gate flag are populated by
        // `aot_image_loader.loadIntoContext` on the parent only; without
        // propagation, the spawned task hits `image-slot-miss` for any
        // compiled body that references a slot.
        ctx.runtime_image_loaded = parent.runtime_image_loaded;
        ctx.image_typevalue_slots = parent.image_typevalue_slots;
        ctx.image_struct_type_slots = parent.image_struct_type_slots;
        ctx.image_marker_slots = parent.image_marker_slots;
        ctx.image_parameter_slots = parent.image_parameter_slots;
        ctx.image_tagged_slots = parent.image_tagged_slots;
        ctx.image_mutable_map_slots = parent.image_mutable_map_slots;
        ctx.image_typevalue_slot_count = parent.image_typevalue_slot_count;
        ctx.image_struct_type_slot_count = parent.image_struct_type_slot_count;
        ctx.image_marker_slot_count = parent.image_marker_slot_count;
        ctx.image_parameter_slot_count = parent.image_parameter_slot_count;
        ctx.image_tagged_slot_count = parent.image_tagged_slot_count;
        ctx.image_mutable_map_slot_count = parent.image_mutable_map_slot_count;

        // Inherit AOT-emitted quotation code pointer table so quotation
        // literals constructed in the task ctx via `jitPushQuotation`
        // pick up their compiled bodies, matching the parent.
        ctx.aot_quotation_fns = parent.aot_quotation_fns;

        // Share the parent's hook registry so all contexts fire the same hooks.
        ctx.hook_registry = parent.hook_registry;

        // Inherit the parent's active sandbox, if any. Allocate a copy on the
        // task's arena so the pointer outlives the parent's stack frame.
        if (parent.active_sandbox) |sandbox| {
            const copy = try ctx.arena.allocator().create(SandboxSpec);
            copy.* = sandbox.*;
            ctx.active_sandbox = copy;
        }

        // Snapshot the parent's dynamic variable bindings into the task context.
        for (parent.parameter_env.items) |parent_frame| {
            var cloned_frame = ParameterFrame{};
            var iter = parent_frame.iterator();
            while (iter.next()) |entry| {
                // The cloned task context co-owns the shared container backing,
                // so it takes its own owning reference.
                container_backing.retainValue(entry.value_ptr.*);
                try cloned_frame.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
            }
            try ctx.parameter_env.append(allocator, cloned_frame);
        }

        return ctx;
    }

    pub fn getDispatchAnySentinel(self: *const Context) *const value_mod.TypeValue {
        if (self.dispatch_any_sentinel) |tv| return tv;
        return self.parent_context.?.getDispatchAnySentinel();
    }

    pub fn getDispatchUnarySentinel(self: *const Context) *const value_mod.TypeValue {
        if (self.dispatch_unary_sentinel) |tv| return tv;
        return self.parent_context.?.getDispatchUnarySentinel();
    }

    pub fn getSelfTypeSentinel(self: *const Context) *const value_mod.TypeValue {
        if (self.self_type_sentinel) |tv| return tv;
        return self.parent_context.?.getSelfTypeSentinel();
    }

    pub fn getAnyTypeSentinel(self: *const Context) *const value_mod.TypeValue {
        if (self.any_type_sentinel) |tv| return tv;
        return self.parent_context.?.getAnyTypeSentinel();
    }

    /// Load the prelude source. When external_source is non-null, it is used
    /// instead of the compiled-in embedded prelude.
    pub fn loadPrelude(self: *Context, external_source: ?[]const u8) !void {
        var processor: StatementProcessor = .{};

        const old_source = self.current_source;
        self.current_source = if (external_source != null) "<prelude>" else "src/prelude.1z";
        defer self.current_source = old_source;

        // Push an initial frame so that the prelude definitions land in a local
        // frame instead of the global dictionary
        try self.pushLocalFrame();
        self.import_frame_index = self.local_frames.items.len - 1;

        // Push the base pragma frame for file-scoped pragmas
        try self.pushPragmaFrame();

        // Register require-doc pragma with a native validator so enforcement
        // does not depend on prelude definitions.
        try self.pragma_registry.put(self.allocator, "require-doc", .{
            .native_validator = &control.nativeRequireDocValidator,
        });

        try self.pragma_registry.put(self.allocator, "suppress-checks", .{
            .native_validator = &nativeSuppressChecksValidator,
        });

        try self.pragma_registry.put(self.allocator, "suppress-undeclared", .{});

        try self.pragma_registry.put(self.allocator, "redefinition-arity-mismatch", .{
            .native_validator = &control.nativeRedefinitionArityMismatchValidator,
        });

        try self.pragma_registry.put(self.allocator, "type-check", .{
            .native_validator = &control.nativeTypeCheckValidator,
        });

        try self.pragma_registry.put(self.allocator, "callsite-arity-mismatch", .{
            .native_validator = &control.nativeCallsiteArityMismatchValidator,
        });

        // Split prelude into lines and process incrementally
        const source = external_source orelse prelude_source;
        var lines = std.mem.splitScalar(u8, source, '\n');
        var line_num: usize = 0;
        while (lines.next()) |line| {
            line_num += 1;
            processor.trackLine(line_num);
            const parse_start = if (self.benchmark != null) std.time.nanoTimestamp() else 0;
            const result = processor.feedLine(self.arena.allocator(), line, self);
            if (self.benchmark) |b| b.prelude_parse_ns += std.time.nanoTimestamp() - parse_start;
            switch (result) {
                .needs_more_input => continue,
                .complete => |instrs| {
                    if (instrs.len > 0) {
                        const exec_start = if (self.benchmark != null) std.time.nanoTimestamp() else 0;
                        try self.executeQuotation(.{ .instructions = instrs });
                        if (self.benchmark) |b| b.prelude_exec_ns += std.time.nanoTimestamp() - exec_start;
                    }
                    processor.reset();
                },
                .parse_error => |err| return err,
            }
        }

        // Flush any remaining buffered content
        const flush_parse_start = if (self.benchmark != null) std.time.nanoTimestamp() else 0;
        const flush_result = processor.flush(self.arena.allocator(), self);
        if (self.benchmark) |b| b.prelude_parse_ns += std.time.nanoTimestamp() - flush_parse_start;
        switch (flush_result) {
            .complete => |instrs| {
                if (instrs.len > 0) {
                    const exec_start = if (self.benchmark != null) std.time.nanoTimestamp() else 0;
                    try self.executeQuotation(.{ .instructions = instrs });
                    if (self.benchmark) |b| b.prelude_exec_ns += std.time.nanoTimestamp() - exec_start;
                }
            },
            .parse_error => |err| return err,
            .needs_more_input => {},
        }
    }

    /// Free all resources used by the context.
    pub fn deinit(self: *Context) void {
        for (self.parameter_env.items) |*frame| {
            self.deinitParameterFrame(frame);
        }
        self.parameter_env.deinit(self.allocator);
        for (self.local_frames.items) |*frame| {
            frame.deinit(self.allocator);
        }
        self.local_frames.deinit(self.allocator);
        self.call_stack.deinit(self.allocator);
        self.error_details.deinit(self.allocator);
        self.jit_pending_trace_frames.deinit(self.allocator);
        self.load_paths.deinit(self.allocator);
        for (self.pragma_frames.items) |*frame| {
            frame.deinit(self.allocator);
        }
        self.pragma_frames.deinit(self.allocator);
        self.pragma_registry.deinit(self.allocator);
        self.parse_time_deferred_calls.deinit(self.allocator);
        self.import_history.deinit(self.allocator);
        for (self.type_registry_frames.items) |*frame| {
            frame.deinit(self.allocator);
        }
        self.type_registry_frames.deinit(self.allocator);
        for (self.dispatch_frames.items) |*frame| {
            frame.deinit(self.allocator);
        }
        self.dispatch_frames.deinit(self.allocator);
        self.builtin_type_values.deinit(self.allocator);
        self.resource_type_values.deinit(self.allocator);
        self.parameterized_type_descriptors.deinit(self.allocator);
        self.struct_descriptors.deinit(self.allocator);
        self.anonymous_union_type_values.deinit(self.allocator);
        self.protocol_descriptors.deinit(self.allocator);
        self.protocol_satisfies_cache.deinit(self.allocator);
        self.bounded_dispatch_trace_names.deinit(self.allocator);
        self.dispatch.deinit();
        self.jit_dispatch.deinit();
        var pic_iter = self.pic_cache.iterator();
        while (pic_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.pic_cache.deinit(self.allocator);
        // thrown_error, error_value boxes, bignum boxes (header and limbs),
        // and task error_obj boxes are all arena-allocated; they are
        // reclaimed by arena.deinit. The refcounted backing carried in an
        // unrecovered error's `data` field is not arena-owned, so release it
        // here before discarding the stash.
        if (self.thrown_error) |thrown| {
            if (thrown.data) |data| container_backing.releaseValue(data.*);
        }
        self.thrown_error = null;

        // Drop owning references in lifecycle order: residual stack
        // slots first, then captured container literals in word bodies
        // (dictionary) and arena-owned quotations. All releases must
        // happen before the arena that owns the quotation instructions
        // is torn down.
        self.stack.clear();
        self.dictionary.walkContainerReleaseList();
        self.walkContainerReleaseList();
        self.container_release_list.deinit(self.allocator);

        self.arena.deinit();
        self.dictionary.deinit();
        if (self.parent_context == null) {
            // Release the refcounted module cache before tearing down the
            // root-owned allocators it sits in front of. Child contexts share
            // the parent's pointer without retaining and skip this branch.
            container_backing.releaseValue(.{ .mutable_map = self.module_cache_value });
            self.hook_registry.deinit(self.allocator);
            self.allocator.destroy(self.hook_registry);
            self.allocator.destroy(self.lock_order_tracker);
            self.allocator.destroy(self.shared_lock);
        }
        self.stack.deinit();
    }

    /// Allocator for quotations and other parsed data.
    pub fn quotationAllocator(self: *Context) Allocator {
        return self.arena.allocator();
    }

    /// If `instructions` contains any container-variant `push_literal`,
    /// record the slice on this context's release list. The walk at
    /// `deinit` invokes `releaseInstructionsContainerLiterals` on every
    /// recorded slice before the arena that owns the instructions is
    /// torn down, keeping captured container backings alive until the
    /// quotation that captured them is freed.
    pub fn registerQuotationContainerLiterals(self: *Context, instructions: []const Instruction) !void {
        if (!container_backing.instructionsHaveContainerLiteral(instructions)) return;
        try self.container_release_list.append(self.allocator, instructions);
    }

    /// Release the container literals captured by every quotation
    /// registered on this context. Idempotent across calls because the
    /// list is cleared after walking.
    pub fn walkContainerReleaseList(self: *Context) void {
        for (self.container_release_list.items) |instrs| {
            container_backing.releaseInstructionsContainerLiterals(instrs);
        }
        self.container_release_list.clearRetainingCapacity();
    }

    /// Remove every entry from this context's release list whose slice
    /// pointer matches `instructions`. Called by `defineWord` when a
    /// parsed quotation is about to become a word body so the dictionary
    /// becomes the sole owner of the release callback and we don't
    /// double-release at teardown.
    pub fn unregisterQuotationContainerLiterals(self: *Context, instructions: []const Instruction) void {
        var i: usize = 0;
        while (i < self.container_release_list.items.len) {
            if (self.container_release_list.items[i].ptr == instructions.ptr) {
                _ = self.container_release_list.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Clear all error details and call stack.
    pub fn clearExecutionDetails(self: *Context) void {
        self.error_details.clearRetainingCapacity();
        self.call_stack.clearRetainingCapacity();
        self.pending_error_message = null;
        self.pending_error_hint = null;
        self.pending_dispatch_actual_types = null;
        self.pending_dispatch_available_methods = null;
    }

    pub fn ownedCurrentSource(self: *Context) []const u8 {
        return self.arena.allocator().dupe(u8, self.current_source) catch self.current_source;
    }

    /// Queue a synthetic frame for compiled error propagation. This is a
    /// targeted parity fix for current JIT trace gaps, not a general JIT frame
    /// model. If broader compiled trace fidelity becomes important later, build
    /// a runtime frame stack for inlined combinators instead of extending this.
    pub fn appendPendingSyntheticErrorFrame(self: *Context, word_name: []const u8, source: []const u8, line: usize) void {
        self.jit_pending_trace_frames.append(self.allocator, .{
            .word_name = word_name,
            .source = source,
            .line = line,
            .column = 0,
        }) catch {};
    }

    pub fn clearPendingSyntheticErrorFrames(self: *Context) void {
        self.jit_pending_trace_frames.clearRetainingCapacity();
    }

    /// Get the current binding for a parameter by name.
    /// Searches frames from top (innermost) to bottom (outermost).
    /// Returns null if the parameter is not bound in any frame.
    pub fn getParameterBinding(self: *Context, name: []const u8) ?Value {
        // Search from top (innermost) to bottom (outermost)
        var i = self.parameter_env.items.len;
        while (i > 0) {
            i -= 1;
            if (self.parameter_env.items[i].get(name)) |value| {
                return value;
            }
        }
        return null;
    }

    /// Push a new empty parameter frame onto the environment stack.
    pub fn pushParameterFrame(self: *Context) !void {
        try self.parameter_env.append(self.allocator, ParameterFrame{});
    }

    /// Release the owning reference each binding in a parameter frame holds
    /// over its container value, then free the frame's storage. A frame slot
    /// is an owning reference, so tearing the frame down drops those refs.
    fn deinitParameterFrame(self: *Context, frame: *ParameterFrame) void {
        var iter = frame.iterator();
        while (iter.next()) |entry| {
            container_backing.releaseValue(entry.value_ptr.*);
        }
        frame.deinit(self.allocator);
    }

    /// Pop the top parameter frame from the environment stack.
    pub fn popParameterFrame(self: *Context) void {
        if (self.parameter_env.items.len > 0) {
            const last_idx = self.parameter_env.items.len - 1;
            self.deinitParameterFrame(&self.parameter_env.items[last_idx]);
            self.parameter_env.items.len -= 1;
        }
    }

    /// Bind a parameter name to a value in the top frame.
    /// Assumes there is at least one frame on the stack.
    pub fn setParameterInTopFrame(self: *Context, name: []const u8, value: Value) !void {
        if (self.parameter_env.items.len == 0) {
            return error.OutOfMemory; // Should never happen if pushParameterFrame was called
        }
        const top_index = self.parameter_env.items.len - 1;
        // The frame slot takes an owning reference; release any value it
        // displaces so a rebinding within the same frame does not leak.
        const gop = try self.parameter_env.items[top_index].getOrPut(self.allocator, name);
        if (gop.found_existing) {
            container_backing.releaseValue(gop.value_ptr.*);
        }
        container_backing.retainValue(value);
        gop.value_ptr.* = value;
    }

    // =========================================================================
    // Local frame methods (lexical scoping for quotation-local definitions)
    // =========================================================================

    /// Push a new empty local frame onto the frame stack.
    pub fn pushLocalFrame(self: *Context) !void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        try self.pushLocalFrameLocked();
    }

    fn pushLocalFrameLocked(self: *Context) !void {
        try self.local_frames.append(self.allocator, LocalFrame{});
    }

    /// Pop the top local frame from the frame stack.
    pub fn popLocalFrame(self: *Context) void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        self.popLocalFrameLocked();
    }

    fn popLocalFrameLocked(self: *Context) void {
        if (self.local_frames.items.len > 0) {
            const last_idx = self.local_frames.items.len - 1;
            self.local_frames.items[last_idx].deinit(self.allocator);
            self.local_frames.items.len -= 1;
        }
    }

    /// Push a local frame populated with a module's deps and words.
    /// This makes the module's dependencies available for late-binding
    /// resolution when executing the module's own words.
    ///
    /// The module's own words take precedence over its dependencies.
    pub fn pushModuleDepsFrame(self: *Context, module: *const value_mod.Module) !void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();

        try self.pushLocalFrameLocked();
        const frame_idx = self.local_frames.items.len - 1;
        var frame = &self.local_frames.items[frame_idx];

        var dep_iter = module.deps.iterator();
        while (dep_iter.next()) |entry| {
            try frame.put(self.allocator, entry.key_ptr.*, .{
                .name = entry.key_ptr.*,
                .stack_effect = entry.value_ptr.*.stack_effect,
                .markers = entry.value_ptr.*.markers,
                .source_module = entry.value_ptr.*.source_module orelse module,
                .capability = entry.value_ptr.*.capability,
                .dispatch_id = entry.value_ptr.*.dispatch_id,
                .action = switch (entry.value_ptr.*.action) {
                    .compound => |instrs| .{ .compound = instrs },
                    .native => |func| .{ .native = func },
                    .host_callback => |host| .{ .host_callback = host },
                },
            });
        }

        var word_iter = module.words.iterator();
        while (word_iter.next()) |entry| {
            try frame.put(self.allocator, entry.key_ptr.*, .{
                .name = entry.key_ptr.*,
                .stack_effect = entry.value_ptr.*.stack_effect,
                .markers = entry.value_ptr.*.markers,
                .source_module = entry.value_ptr.*.source_module orelse module,
                .capability = entry.value_ptr.*.capability,
                .dispatch_id = entry.value_ptr.*.dispatch_id,
                .action = switch (entry.value_ptr.*.action) {
                    .compound => |instrs| .{ .compound = instrs },
                    .native => |func| .{ .native = func },
                    .host_callback => |host| .{ .host_callback = host },
                },
            });
        }

        if (self.trace.trace_modules.deps) {
            var tw = trace_mod.TraceWriter.init();
            trace_mod.traceModuleDepsPush(&tw, module.name, &module.words, &module.deps, 5);
        }
    }

    // =========================================================================
    // Lock helpers (instrument lock_order_tracker for debug assertions)
    // =========================================================================

    fn acquireSharedRead(self: *const Context) void {
        self.lock_order_tracker.acquire(.context_rw);
        self.shared_lock.lockShared();
    }

    fn releaseSharedRead(self: *const Context) void {
        self.shared_lock.unlockShared();
        self.lock_order_tracker.release(.context_rw);
    }

    fn acquireSharedWrite(self: *const Context) void {
        self.lock_order_tracker.acquire(.context_rw);
        self.shared_lock.lock();
    }

    fn releaseSharedWrite(self: *const Context) void {
        self.shared_lock.unlock();
        self.lock_order_tracker.release(.context_rw);
    }

    // =========================================================================
    // Pragma frame methods (file-scoped pragma values)
    // =========================================================================

    /// Push a new empty pragma frame onto the frame stack.
    pub fn pushPragmaFrame(self: *Context) !void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        return self.pushPragmaFrameLocked();
    }

    fn pushPragmaFrameLocked(self: *Context) !void {
        try self.pragma_frames.append(self.allocator, PragmaFrame{});
    }

    /// Pop the top pragma frame from the frame stack.
    pub fn popPragmaFrame(self: *Context) void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        return self.popPragmaFrameLocked();
    }

    fn popPragmaFrameLocked(self: *Context) void {
        if (self.pragma_frames.items.len > 0) {
            const last_idx = self.pragma_frames.items.len - 1;
            self.pragma_frames.items[last_idx].deinit(self.allocator);
            self.pragma_frames.items.len -= 1;
        }
    }

    /// Set a pragma value in the top frame.
    pub fn setPragma(self: *Context, name: []const u8, value: Value) !void {
        if (self.pragma_frames.items.len == 0) return error.OutOfMemory;
        const top_index = self.pragma_frames.items.len - 1;
        try self.pragma_frames.items[top_index].put(self.allocator, name, value);
    }

    /// Get the current value of a pragma, searching frames top-to-bottom
    /// and then walking the parent context chain.
    pub fn getPragma(self: *const Context, name: []const u8) ?Value {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.getPragmaLocked(name);
    }

    fn getPragmaLocked(self: *const Context, name: []const u8) ?Value {
        var i = self.pragma_frames.items.len;
        while (i > 0) {
            i -= 1;
            if (self.pragma_frames.items[i].get(name)) |value| {
                return value;
            }
        }

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            var j = ctx.pragma_frames.items.len;
            while (j > 0) {
                j -= 1;
                if (ctx.pragma_frames.items[j].get(name)) |value| {
                    return value;
                }
            }
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Look up a pragma registration by name, walking the parent context chain.
    pub fn lookupPragmaRegistration(self: *const Context, name: []const u8) ?PragmaRegistration {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupPragmaRegistrationLocked(name);
    }

    fn lookupPragmaRegistrationLocked(self: *const Context, name: []const u8) ?PragmaRegistration {
        if (self.pragma_registry.get(name)) |reg| return reg;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            if (ctx.pragma_registry.get(name)) |reg| return reg;
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Define a word in the current local frame if one exists, otherwise
    /// in global dictionary.
    pub fn defineWord(self: *Context, name: []const u8, definition: WordDefinition) !void {
        {
            self.acquireSharedWrite();
            defer self.releaseSharedWrite();
            try self.defineWordLocked(name, definition);
        }

        // NOTE(ripta): auto-compile runs after the lock is released so JIT callbacks can acquire their own locks
        if (self.compile_mode == .eager) {
            self.tryAutoCompile(name, definition);
        } else if (self.compile_mode == .hybrid) {
            self.tryAssignWordId(name, definition);
        }
    }

    /// Remove a word from the top-level dictionary under the shared write lock.
    pub fn removeWord(self: *Context, name: []const u8) bool {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        return self.dictionary.remove(name);
    }

    fn defineWordLocked(self: *Context, name: []const u8, definition: WordDefinition) !void {
        if (self.lookupWordLocked(name)) |existing| {
            for (existing.markers) |mk| {
                if (markers_mod.isConstMarker(mk)) {
                    self.pending_error_message = std.fmt.allocPrint(
                        self.arena.allocator(),
                        "cannot redefine const word '{s}'",
                        .{name},
                    ) catch "cannot redefine const word";
                    return error.CannotRedefineConst;
                }
            }
        }

        const same_scope_existing = if (self.local_frames.items.len > 0)
            self.local_frames.items[self.local_frames.items.len - 1].get(name)
        else
            self.dictionary.get(name);
        if (same_scope_existing) |existing| {
            // XXX(ripta): Skip arity check for auto-generated words, e.g., `virtual{`, `struct{`,
            //             since users legitly override generated constructors
            if (existing.provenance == null) {
                if (existing.stack_effect) |old_effect| {
                    if (definition.stack_effect) |new_effect| {
                        if (old_effect.concreteInputCount() != new_effect.concreteInputCount() or
                            old_effect.concreteOutputCount() != new_effect.concreteOutputCount())
                        {
                            const msg = std.fmt.allocPrint(self.arena.allocator(), "arity mismatch on redefinition of '{s}' (was {d} -> {d}, now {d} -> {d})", .{ name, old_effect.concreteInputCount(), old_effect.concreteOutputCount(), new_effect.concreteInputCount(), new_effect.concreteOutputCount() }) catch "arity mismatch on redefinition";
                            const pragma_val = self.getPragmaLocked("redefinition-arity-mismatch");
                            const is_warning = if (pragma_val) |pv| switch (pv) {
                                .string => |s| std.mem.eql(u8, s, "warning"),
                                else => false,
                            } else false;
                            if (is_warning) {
                                var tw = trace_mod.TraceWriter.init();
                                tw.print("warning: {s}\n", .{msg});
                            } else {
                                self.pending_error_message = msg;
                                return error.ArityMismatch;
                            }
                        }
                    } else {
                        var tw = trace_mod.TraceWriter.init();
                        tw.print("warning: redefinition of '{s}' drops stack effect declaration\n", .{name});
                    }
                } else {
                    if (definition.stack_effect != null) {
                        var tw = trace_mod.TraceWriter.init();
                        tw.print("warning: redefinition of '{s}' adds stack effect declaration not present on original\n", .{name});
                    }
                }
            }
        }

        if (same_scope_existing) |existing| {
            if (existing.word_id) |wid| {
                self.jit_dispatch.invalidate(wid);
            }
        }

        var def = definition;
        def.dispatch_id = self.next_dispatch_id.fetchAdd(1, .monotonic);
        if (def.source_file == null) {
            def.source_file = self.current_source;
            if (self.call_stack.items.len > 0) {
                const frame = self.call_stack.items[self.call_stack.items.len - 1];
                def.source_line = frame.line;
                def.source_column = frame.column;
            }
        }

        if (self.local_frames.items.len > 0) {
            const top_index = self.local_frames.items.len - 1;
            try self.local_frames.items[top_index].put(self.allocator, name, def);
        } else {
            try self.dictionary.put(name, def);
        }

        // Compound bodies that capture container literals must be
        // tracked so the captured backings can be released when the
        // dictionary tears down. A parsed quotation literal already sits
        // on the context's release list; transfer ownership by removing
        // it there before re-registering on the dictionary so teardown
        // doesn't double-release.
        switch (def.action) {
            .compound => |instrs| {
                self.unregisterQuotationContainerLiterals(instrs);
                try self.dictionary.registerCompoundBody(instrs);
            },
            .native, .host_callback => {},
        }
    }

    /// Attempt JIT compilation of a newly defined word. Silently ignores
    /// all errors so the word falls back to the interpreter.
    fn tryAutoCompile(self: *Context, name: []const u8, def: WordDefinition) void {
        const instrs = switch (def.action) {
            .compound => |i| i,
            .native, .host_callback => return,
        };

        const effect = def.stack_effect orelse return;

        for (def.markers) |mk| {
            if (markers_mod.isParseTimeOnlyMarker(mk)) return;
            if (markers_mod.isParseTimeMarker(mk)) return;
            if (markers_mod.isGenericMarker(mk)) return;
        }

        if (stack_effect_mod.hasAnyRowVariable(effect)) return;

        const input_count: u8 = @intCast(effect.inputs.len);
        const output_count: u8 = @intCast(effect.outputs.len);

        var resolver_ctx = ResolverState{ .context = self };
        const resolver = ir_codegen.WordResolver{
            .resolve = &resolveWordForDispatch,
            .user_data = @ptrCast(&resolver_ctx),
            .dispatch_table_ptr = @ptrCast(&self.jit_dispatch),
        };

        const pic_snapshot = self.clonePicSnapshotForInstructions(instrs);
        var pic_snapshot_owned = true;
        defer if (pic_snapshot_owned) {
            if (pic_snapshot) |ps| {
                ps.deinit();
                self.allocator.destroy(ps);
            }
        };

        const compiled = ir_codegen.compileWordWithPicSnapshot(instrs, input_count, output_count, resolver, name, pic_snapshot, self, null, &effect) catch return;

        const final_id = if (def.word_id) |existing_id| blk: {
            if (self.jit_dispatch.get(existing_id) != null) {
                self.jit_dispatch.update(existing_id, compiled.code_ptr, compiled.jit_buf, compiled.peak_stack_depth);
                break :blk existing_id;
            }
            const new_id = self.jit_dispatch.assignId(name) catch {
                compiled.jit_buf.deinit();
                return;
            };
            self.jit_dispatch.update(new_id, compiled.code_ptr, compiled.jit_buf, compiled.peak_stack_depth);
            propagateWordId(self, name, new_id);
            break :blk new_id;
        } else blk: {
            const new_id = self.jit_dispatch.assignId(name) catch {
                compiled.jit_buf.deinit();
                return;
            };
            self.jit_dispatch.update(new_id, compiled.code_ptr, compiled.jit_buf, compiled.peak_stack_depth);
            propagateWordId(self, name, new_id);
            break :blk new_id;
        };

        self.jit_dispatch.replacePicSnapshot(final_id, pic_snapshot);
        pic_snapshot_owned = false;

        if (self.trace.trace_jit) {
            var tw = trace_mod.TraceWriter.init();
            trace_mod.traceJitCompile(&tw, name, final_id);
        }
    }

    /// Assign a word_id without compiling. Used in hybrid mode so the dispatch
    /// table entry exists for call counting when the word is later executed.
    fn tryAssignWordId(self: *Context, name: []const u8, def: WordDefinition) void {
        switch (def.action) {
            .compound => {},
            .native, .host_callback => return,
        }

        if (def.stack_effect == null) return;
        const effect = def.stack_effect.?;

        for (def.markers) |mk| {
            if (markers_mod.isParseTimeOnlyMarker(mk)) return;
            if (markers_mod.isParseTimeMarker(mk)) return;
            if (markers_mod.isGenericMarker(mk)) return;
            if (markers_mod.isNoCompileMarker(mk)) return;
        }

        if (stack_effect_mod.hasAnyRowVariable(effect)) return;

        if (def.word_id != null) return;

        const new_id = self.jit_dispatch.assignId(name) catch return;
        propagateWordId(self, name, new_id);
    }

    /// In hybrid mode, increment the call counter for a word and compile it
    /// when the counter exceeds the effective threshold.
    fn tryHybridCompile(self: *Context, word_id: u32, name: []const u8, word: WordDefinition) void {
        const entry = self.jit_dispatch.getMut(word_id) orelse return;
        if (entry.uncompilable or entry.code_ptr != null) return;

        entry.call_count += 1;
        if (entry.call_count < self.hybrid_effective_threshold) return;

        self.tryAutoCompile(name, word);

        if (self.jit_dispatch.get(word_id)) |updated| {
            if (updated.code_ptr == null) {
                self.jit_dispatch.markUncompilable(word_id);
            } else {
                self.updateBackpressure();
            }
        }
    }

    fn updateBackpressure(self: *Context) void {
        self.hybrid_recent_compilations += 1;
        if (self.hybrid_recent_compilations >= 10) {
            const max_threshold = self.hybrid_threshold * 8;
            if (self.hybrid_effective_threshold < max_threshold) {
                self.hybrid_effective_threshold = @min(self.hybrid_effective_threshold * 2, max_threshold);
            }
            self.hybrid_recent_compilations = 0;
        } else if (self.hybrid_recent_compilations < 5) {
            if (self.hybrid_effective_threshold > self.hybrid_threshold) {
                if (self.hybrid_effective_threshold > self.hybrid_threshold * 2) {
                    self.hybrid_effective_threshold -= self.hybrid_threshold;
                } else {
                    self.hybrid_effective_threshold = self.hybrid_threshold;
                }
            }
        }
    }

    /// Define a word via `import`. Writes to the import frame tracked by
    /// `import_frame_index`, which is always set in every execution context,
    /// i.e., prelude, batch, REPL, module load.
    pub fn defineImportedWord(self: *Context, name: []const u8, definition: WordDefinition) !void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        return self.defineImportedWordLocked(name, definition);
    }

    fn defineImportedWordLocked(self: *Context, name: []const u8, definition: WordDefinition) !void {
        // Check only the target frame for dedup, not the full lookup chain.
        // The full lookupWord traverses parent frames, which would suppress
        // imports that the current module needs captured in its own frame
        // for later deps resolution.
        const idx = self.import_frame_index orelse unreachable;
        const target_frame = &self.local_frames.items[idx];

        if (target_frame.get(name)) |existing| {
            if (existing.imported and existing.source_module != null and definition.source_module != null) {
                if (existing.source_module == definition.source_module) {
                    return;
                }
            }

            const existing_generic = for (existing.markers) |mk| {
                if (markers_mod.isGenericMarker(mk)) break true;
            } else false;
            const incoming_generic = for (definition.markers) |mk| {
                if (markers_mod.isGenericMarker(mk)) break true;
            } else false;
            if (existing_generic and incoming_generic) {
                return;
            }

            for (existing.markers) |mk| {
                if (markers_mod.isConstMarker(mk)) {
                    self.pending_error_message = std.fmt.allocPrint(
                        self.arena.allocator(),
                        "cannot redefine const word '{s}'",
                        .{name},
                    ) catch "cannot redefine const word";
                    return error.CannotRedefineConst;
                }
            }

            if (existing.word_id) |wid| {
                self.jit_dispatch.invalidate(wid);
            }
        }

        var def = definition;
        if (def.source_file == null) {
            def.source_file = self.current_source;
            if (self.call_stack.items.len > 0) {
                const frame = self.call_stack.items[self.call_stack.items.len - 1];
                def.source_line = frame.line;
                def.source_column = frame.column;
            }
        }

        try target_frame.put(self.allocator, name, def);
    }

    /// Look up a word by name by searching in the following order:
    ///
    /// 1. local frames from innermost (topmost) to outermost (bottommost);
    /// 2. the global dictionary of the current context;
    /// 3. the parent dictionary if this is a task context that inherits from a parent.
    pub fn lookupWord(self: *const Context, name: []const u8) ?WordDefinition {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupWordLocked(name);
    }

    /// Like `lookupWord`, but falls through to the AOT runtime-image module cache when the
    /// in-context lookup misses and an image is loaded. Use this at interpreter call sites
    /// that have to resolve module-private names living only inside a loaded runtime image,
    /// e.g. a parameter's default quotation that calls a module-private helper.
    ///
    /// The fallback is gated on `runtime_image_loaded` so normal `load`-based module sessions
    /// keep their privacy boundary. The AOT loader places every word -- public and module-
    /// private -- into `module.words`, but a source-level `load` keeps private helpers in
    /// `module.deps`. Only the AOT case wants the `words`-only sweep to reach in.
    ///
    /// Definition- and parse-time callers must stick to `lookupWord` so they never see
    /// sibling modules' words.
    pub fn lookupWordForExecution(self: *const Context, name: []const u8) ?WordDefinition {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        if (self.lookupWordLocked(name)) |def| return def;
        if (!self.runtime_image_loaded) return null;
        if (self.lookupModuleCacheWordLocked(name)) |def| return def;
        return self.lookupAotCompiledWordLocked(name);
    }

    /// Final fallback for AOT runtimes: a user word may live only in `jit_dispatch` with no entry in
    /// any dictionary or module cache. This is the shape of top-level user words in interpreter-class
    /// AOT binaries that did not embed a full runtime image.
    ///
    /// Walks `self` and the `parent_context` chain, scanning each `jit_dispatch` for a registered name.
    /// On hit, synthesizes a `WordDefinition` carrying the entry's `word_id` so `executeResolvedWord`'s
    /// JIT path dispatches via `executeCompiled`. Action is a sentinel that errors out if the compiled
    /// call bails, since there is no interpretable body to fall back to.
    ///
    /// Gated by the caller on `runtime_image_loaded` so non-AOT sessions keep `jit_dispatch` opaque.
    /// In interpreter sessions the same table can carry library-private words promoted to JIT,
    /// and a name-based sweep would leak them across module boundaries.
    fn lookupAotCompiledWordLocked(self: *const Context, name: []const u8) ?WordDefinition {
        var ctx_opt: ?*const Context = self;
        while (ctx_opt) |ctx| : (ctx_opt = ctx.parent_context) {
            for (ctx.jit_dispatch.entries.items, 0..) |entry, idx| {
                if (entry.code_ptr == null) continue;
                if (!std.mem.eql(u8, entry.word_name, name)) continue;
                return .{
                    .name = entry.word_name,
                    .word_id = @intCast(idx),
                    .action = .{ .native = aotCompiledOnlyBailSentinel },
                };
            }
        }
        return null;
    }

    fn lookupWordLocked(self: *const Context, name: []const u8) ?WordDefinition {
        var i = self.local_frames.items.len;
        while (i > 0) {
            i -= 1;
            if (self.local_frames.items[i].get(name)) |def| {
                return def;
            }
        }

        if (self.dictionary.get(name)) |def| return def;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            var j = ctx.local_frames.items.len;
            while (j > 0) {
                j -= 1;
                if (ctx.local_frames.items[j].get(name)) |def| return def;
            }
            if (ctx.dictionary.get(name)) |def| return def;
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Scan every cached module's public `words` table for `name`.
    /// Module `deps` are deliberately skipped: deps hold a module's
    /// private imports, and `load`-ing a 1z module surfaces public
    /// API through `words` only. Checking deps would leak names out
    /// of their owning module's privacy boundary (see the
    /// `local_scope` integration test). The AOT runtime-image
    /// loader places every word -- public or module-private -- into
    /// `words`, so the words-only sweep is enough for both cases.
    fn lookupModuleCacheWordLocked(self: *const Context, name: []const u8) ?WordDefinition {
        var iter = self.module_cache_value.map.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* != .module) continue;
            const module = entry.value_ptr.*.module;
            if (module.words.get(name)) |mod_word| {
                return wordDefFromModuleWord(name, mod_word, module);
            }
        }
        return null;
    }

    /// Sentinel `.native` action for AOT-compiled-only words synthesized
    /// by `lookupAotCompiledWordLocked`. The intended dispatch path is
    /// the JIT one in `executeResolvedWord`, driven by the word's
    /// `word_id`. This sentinel runs only if the JIT path bails, in
    /// which case there is no interpretable body to fall back to and we
    /// surface the failure as an unknown-word error.
    fn aotCompiledOnlyBailSentinel(_: *Context) anyerror!void {
        return ExecutionError.UnknownWord;
    }

    fn wordDefFromModuleWord(
        name: []const u8,
        mod_word: value_mod.ModuleWord,
        module: *const value_mod.Module,
    ) WordDefinition {
        return .{
            .name = name,
            .stack_effect = mod_word.stack_effect,
            .markers = mod_word.markers,
            .doc = mod_word.doc,
            .source_file = mod_word.source_file,
            .source_line = mod_word.source_line,
            .source_column = mod_word.source_column,
            .source_module = mod_word.source_module orelse module,
            .provenance = mod_word.provenance,
            .capability = mod_word.capability,
            .word_id = mod_word.word_id,
            .dispatch_id = mod_word.dispatch_id,
            .action = switch (mod_word.action) {
                .compound => |instrs| .{ .compound = instrs },
                .native => |func| .{ .native = func },
                .host_callback => |host| .{ .host_callback = host },
            },
        };
    }

    /// Resolve a parse-time call reference to a stable dictionary slot
    /// when it provably matches the runtime lookup. Returns the slot only
    /// when the name lives in this context's global dictionary and can
    /// never be shadowed by a local frame: it must be absent from every
    /// current frame here and in every ancestor context, and absent from
    /// every loaded module's `words` and `deps` so that a runtime
    /// module-deps frame push cannot replace the binding. Coverage is
    /// traded for a provable parse-time == runtime guarantee.
    pub fn preResolveCallTarget(self: *const Context, name: []const u8) ?*dict_mod.WordSlot {
        self.acquireSharedRead();
        defer self.releaseSharedRead();

        const slot = self.dictionary.getSlot(name) orelse return null;

        for (self.local_frames.items) |frame| {
            if (frame.contains(name)) return null;
        }

        var ancestor = self.parent_context;
        while (ancestor) |ctx| : (ancestor = ctx.parent_context) {
            for (ctx.local_frames.items) |frame| {
                if (frame.contains(name)) return null;
            }
        }

        var iter = self.module_cache_value.map.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* != .module) continue;
            const module = entry.value_ptr.*.module;
            if (module.words.contains(name)) return null;
            if (module.deps.contains(name)) return null;
        }

        return slot;
    }

    /// Look up a word and return a stable pointer to its stack effect field.
    /// Used by the JIT compiler to bake effect pointers as compile-time constants.
    pub fn lookupWordStackEffectPtr(self: *const Context, name: []const u8) ?*const StackEffect {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupWordStackEffectPtrLocked(name);
    }

    fn lookupWordStackEffectPtrLocked(self: *const Context, name: []const u8) ?*const StackEffect {
        var i = self.local_frames.items.len;
        while (i > 0) {
            i -= 1;
            if (self.local_frames.items[i].getPtr(name)) |def| {
                if (def.stack_effect) |*eff| return eff;
                return null;
            }
        }

        if (self.dictionary.getPtr(name)) |def| {
            if (def.stack_effect) |*eff| return eff;
            return null;
        }

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            var j = ctx.local_frames.items.len;
            while (j > 0) {
                j -= 1;
                if (ctx.local_frames.items[j].getPtr(name)) |def| {
                    if (def.stack_effect) |*eff| return eff;
                    return null;
                }
            }
            if (ctx.dictionary.getPtr(name)) |def| {
                if (def.stack_effect) |*eff| return eff;
                return null;
            }
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Get or lazily allocate a PIC table for an instruction slice.
    /// The instruction slice pointer serves as a stable identity key,
    /// since compound word bodies are arena-allocated and never move.
    fn getOrAllocPicTable(self: *Context, instrs: []const Instruction) ?*PicTable {
        if (instrs.len == 0) return null;
        const key = @intFromPtr(instrs.ptr);
        if (self.pic_cache.get(key)) |pt| return pt;

        const pt = self.allocator.create(PicTable) catch return null;
        pt.* = PicTable.init(self.allocator, instrs.len) catch {
            self.allocator.destroy(pt);
            return null;
        };
        self.pic_cache.put(self.allocator, key, pt) catch {
            pt.deinit();
            self.allocator.destroy(pt);
            return null;
        };
        return pt;
    }

    pub fn clonePicSnapshotForInstructions(self: *const Context, instrs: []const Instruction) ?*PicTable {
        if (instrs.len == 0) return null;
        const key = @intFromPtr(instrs.ptr);
        const pt = self.pic_cache.get(key) orelse return null;
        const cloned = self.allocator.create(pic_mod.PicTable) catch return null;
        cloned.* = pt.clone(self.allocator) catch {
            self.allocator.destroy(cloned);
            return null;
        };
        return cloned;
    }

    /// Determine where a word was found during lookup, mirroring the
    /// search order of `lookupWord`. Used only when trace_resolve is active.
    fn lookupWordSource(self: *const Context, name: []const u8) trace_mod.ResolveSource {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupWordSourceLocked(name);
    }

    fn lookupWordSourceLocked(self: *const Context, name: []const u8) trace_mod.ResolveSource {
        var i = self.local_frames.items.len;
        while (i > 0) {
            i -= 1;
            if (self.local_frames.items[i].get(name) != null) {
                return .{ .local_frame = i };
            }
        }

        if (self.dictionary.get(name) != null) return .global_dict;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            var j = ctx.local_frames.items.len;
            while (j > 0) {
                j -= 1;
                if (ctx.local_frames.items[j].get(name) != null) {
                    return .{ .parent_local_frame = j };
                }
            }
            if (ctx.dictionary.get(name) != null) return .parent_global_dict;
            ancestor = ctx.parent_context;
        }

        return .not_found;
    }

    /// Dump the full scope chain to stderr for `--dump-scope`.
    fn dumpScope(self: *const Context, name: []const u8, source: []const u8, line: usize) void {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.dumpScopeLocked(name, source, line);
    }

    fn dumpScopeLocked(self: *const Context, name: []const u8, source: []const u8, line: usize) void {
        var tw = trace_mod.TraceWriter.init();
        trace_mod.traceDumpScopeHeader(&tw, name, source, line);

        var i = self.local_frames.items.len;
        while (i > 0) {
            i -= 1;
            const label: ?[]const u8 = if (self.import_frame_index != null and i == self.import_frame_index.?)
                "import-frame"
            else if (i == 0)
                "prelude"
            else
                null;
            trace_mod.traceDumpScopeFrame(&tw, "", i, self.local_frames.items[i].count(), label);
        }

        trace_mod.traceDumpScopeDict(&tw, "", self.dictionary.entries.count());

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            var j = ctx.local_frames.items.len;
            while (j > 0) {
                j -= 1;
                trace_mod.traceDumpScopeFrame(&tw, "parent: ", j, ctx.local_frames.items[j].count(), null);
            }
            trace_mod.traceDumpScopeDict(&tw, "parent: ", ctx.dictionary.entries.count());
            ancestor = ctx.parent_context;
        }
    }

    /// Look up a word by name, searching only user visible frames; this skips
    /// transient frames above `import_frame_index`, e.g., module deps frames
    /// and combinator frames, so that introspection words see the some definitions
    /// that the user would write at the top level.
    pub fn lookupUserVisibleWord(self: *const Context, name: []const u8) ?WordDefinition {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupUserVisibleWordLocked(name);
    }

    fn lookupUserVisibleWordLocked(self: *const Context, name: []const u8) ?WordDefinition {
        const frame_cap = if (self.import_frame_index) |idx| idx + 1 else 0;

        var i = frame_cap;
        while (i > 0) {
            i -= 1;
            if (self.local_frames.items[i].get(name)) |def| {
                return def;
            }
        }

        if (self.dictionary.get(name)) |def| return def;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            const anc_cap = if (ctx.import_frame_index) |idx| idx + 1 else 0;

            var j = anc_cap;
            while (j > 0) {
                j -= 1;
                if (ctx.local_frames.items[j].get(name)) |def| return def;
            }

            if (ctx.dictionary.get(name)) |def| return def;
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Look up a binary dispatch entry by walking dispatch frames (top to
    /// bottom), then the base dispatch table, then the parent context chain.
    pub fn lookupBinaryDispatch(self: *const Context, dispatch_id: u32, type_a: *const value_mod.TypeDescriptor, type_b: *const value_mod.TypeDescriptor) ?DispatchEntry {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupBinaryDispatchLocked(dispatch_id, type_a, type_b);
    }

    fn lookupBinaryDispatchLocked(self: *const Context, dispatch_id: u32, type_a: *const value_mod.TypeDescriptor, type_b: *const value_mod.TypeDescriptor) ?DispatchEntry {
        const any_sentinel = self.getDispatchAnySentinel().descriptor.?;
        // Walk dispatch frames top-to-bottom
        var i = self.dispatch_frames.items.len;
        while (i > 0) {
            i -= 1;
            if (dispatch_mod.lookupBinaryInEntries(&self.dispatch_frames.items[i].entries, dispatch_id, type_a, type_b, any_sentinel)) |entry| return entry;
        }
        // Base dispatch table
        if (self.dispatch.lookupBinary(dispatch_id, type_a, type_b, any_sentinel)) |entry| return entry;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            var j = ctx.dispatch_frames.items.len;
            while (j > 0) {
                j -= 1;
                if (dispatch_mod.lookupBinaryInEntries(&ctx.dispatch_frames.items[j].entries, dispatch_id, type_a, type_b, ctx.getDispatchAnySentinel().descriptor.?)) |entry| return entry;
            }
            if (ctx.dispatch.lookupBinary(dispatch_id, type_a, type_b, ctx.getDispatchAnySentinel().descriptor.?)) |entry| return entry;
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Look up a unary dispatch entry by walking dispatch frames (top to
    /// bottom), then the base dispatch table, then the parent context chain.
    pub fn lookupUnaryDispatch(self: *const Context, dispatch_id: u32, type_a: *const value_mod.TypeDescriptor) ?DispatchEntry {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupUnaryDispatchLocked(dispatch_id, type_a);
    }

    fn lookupUnaryDispatchLocked(self: *const Context, dispatch_id: u32, type_a: *const value_mod.TypeDescriptor) ?DispatchEntry {
        const any_sentinel = self.getDispatchAnySentinel().descriptor.?;
        const unary_sentinel = self.getDispatchUnarySentinel().descriptor.?;
        // Walk dispatch frames top-to-bottom
        var i = self.dispatch_frames.items.len;
        while (i > 0) {
            i -= 1;
            if (dispatch_mod.lookupUnaryInEntries(&self.dispatch_frames.items[i].entries, dispatch_id, type_a, any_sentinel, unary_sentinel)) |entry| return entry;
        }
        // Base dispatch table
        if (self.dispatch.lookupUnary(dispatch_id, type_a, any_sentinel, unary_sentinel)) |entry| return entry;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            var j = ctx.dispatch_frames.items.len;
            while (j > 0) {
                j -= 1;
                if (dispatch_mod.lookupUnaryInEntries(&ctx.dispatch_frames.items[j].entries, dispatch_id, type_a, ctx.getDispatchAnySentinel().descriptor.?, ctx.getDispatchUnarySentinel().descriptor.?)) |entry| return entry;
            }
            if (ctx.dispatch.lookupUnary(dispatch_id, type_a, ctx.getDispatchAnySentinel().descriptor.?, ctx.getDispatchUnarySentinel().descriptor.?)) |entry| return entry;
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Resolve a word name to its dispatch ID by looking up the word definition.
    pub fn resolveDispatchId(self: *const Context, word_name: []const u8) ?u32 {
        if (self.lookupWord(word_name)) |def| return def.dispatch_id;
        return null;
    }

    /// Look up a binary dispatch entry in the native-only shadow table,
    /// walking the parent context chain.
    pub fn lookupNativeBinaryDispatch(self: *const Context, dispatch_id: u32, type_a: *const value_mod.TypeDescriptor, type_b: *const value_mod.TypeDescriptor) ?DispatchEntry {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupNativeBinaryDispatchLocked(dispatch_id, type_a, type_b);
    }

    fn lookupNativeBinaryDispatchLocked(self: *const Context, dispatch_id: u32, type_a: *const value_mod.TypeDescriptor, type_b: *const value_mod.TypeDescriptor) ?DispatchEntry {
        if (self.dispatch.lookupNativeBinary(dispatch_id, type_a, type_b, self.getDispatchAnySentinel().descriptor.?)) |entry| return entry;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            if (ctx.dispatch.lookupNativeBinary(dispatch_id, type_a, type_b, ctx.getDispatchAnySentinel().descriptor.?)) |entry| return entry;
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Look up a unary dispatch entry in the native-only shadow table,
    /// walking the parent context chain.
    pub fn lookupNativeUnaryDispatch(self: *const Context, dispatch_id: u32, type_a: *const value_mod.TypeDescriptor) ?DispatchEntry {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupNativeUnaryDispatchLocked(dispatch_id, type_a);
    }

    fn lookupNativeUnaryDispatchLocked(self: *const Context, dispatch_id: u32, type_a: *const value_mod.TypeDescriptor) ?DispatchEntry {
        if (self.dispatch.lookupNativeUnary(dispatch_id, type_a, self.getDispatchAnySentinel().descriptor.?, self.getDispatchUnarySentinel().descriptor.?)) |entry| return entry;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            if (ctx.dispatch.lookupNativeUnary(dispatch_id, type_a, ctx.getDispatchAnySentinel().descriptor.?, ctx.getDispatchUnarySentinel().descriptor.?)) |entry| return entry;
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Look up enum variant types by enum name, walking type registry frames
    /// (top to bottom), then the parent context chain.
    pub fn lookupEnumVariants(self: *const Context, enum_tv: *const value_mod.TypeValue) ?[]const *const value_mod.VirtualType {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupEnumVariantsLocked(enum_tv);
    }

    fn lookupEnumVariantsLocked(self: *const Context, enum_tv: *const value_mod.TypeValue) ?[]const *const value_mod.VirtualType {
        var i = self.type_registry_frames.items.len;
        while (i > 0) {
            i -= 1;
            if (self.type_registry_frames.items[i].enum_registry.get(enum_tv)) |variants| return variants;
        }

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            var j = ctx.type_registry_frames.items.len;
            while (j > 0) {
                j -= 1;
                if (ctx.type_registry_frames.items[j].enum_registry.get(enum_tv)) |variants| return variants;
            }
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Look up a type descriptor by type name, walking type registry frames
    /// (top to bottom), then the parent context chain.
    pub fn lookupTypeDescriptor(self: *const Context, name: []const u8) ?*value_mod.TypeDescriptor {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupTypeDescriptorLocked(name);
    }

    fn lookupTypeDescriptorLocked(self: *const Context, name: []const u8) ?*value_mod.TypeDescriptor {
        var i = self.type_registry_frames.items.len;
        while (i > 0) {
            i -= 1;
            if (self.type_registry_frames.items[i].type_descriptors.get(name)) |desc| return desc;
        }

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            var j = ctx.type_registry_frames.items.len;
            while (j > 0) {
                j -= 1;
                if (ctx.type_registry_frames.items[j].type_descriptors.get(name)) |desc| return desc;
            }
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Look up a built-in type value by type name, walking the parent context chain.
    pub fn lookupBuiltinTypeValue(self: *const Context, name: []const u8) ?*value_mod.TypeValue {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupBuiltinTypeValueLocked(name);
    }

    fn lookupBuiltinTypeValueLocked(self: *const Context, name: []const u8) ?*value_mod.TypeValue {
        if (self.builtin_type_values.get(name)) |tv| return tv;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            if (ctx.builtin_type_values.get(name)) |tv| return tv;
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Look up a builtin TypeValue by Value discriminant tag, O(1) array index.
    /// Walks the parent context chain if the local array is unpopulated,
    /// e.g., on task contexts.
    pub fn lookupBuiltinTypeValueByTag(self: *const Context, tag: std.meta.Tag(value_mod.Value)) ?*value_mod.TypeValue {
        const idx = @intFromEnum(tag);
        if (idx < self.builtin_type_array.len) {
            if (self.builtin_type_array[idx]) |tv| return tv;
        }

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            if (idx < ctx.builtin_type_array.len) {
                if (ctx.builtin_type_array[idx]) |tv| return tv;
            }
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Look up a resource type value by type name, walking the parent context chain.
    pub fn lookupResourceTypeValue(self: *const Context, name: []const u8) ?*value_mod.TypeValue {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupResourceTypeValueLocked(name);
    }

    /// Look up a TypeValue by name, searching builtins, resources, and type words.
    /// This is the general-purpose lookup for resolving a type name string to a
    /// TypeValue pointer, covering both builtin and user-defined types.
    pub fn lookupTypeValueByName(self: *const Context, name: []const u8) ?*value_mod.TypeValue {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        if (self.lookupBuiltinTypeValueLocked(name)) |tv| return tv;
        if (self.lookupResourceTypeValueLocked(name)) |tv| return tv;
        // Fall back to dictionary: type words push a single .type_val literal,
        // and enum variant constructors push a single .tagged literal whose
        // VirtualType carries a .type_val.
        const word = self.lookupWordLocked(name) orelse return null;
        switch (word.action) {
            .compound => |instrs| {
                if (instrs.len == 1) {
                    switch (instrs[0].op) {
                        .push_literal => |val| switch (val) {
                            .type_val => |tv| return tv,
                            .tagged => |t| return t.tag.type_val,
                            else => return null,
                        },
                        else => return null,
                    }
                }
                return null;
            },
            .native, .host_callback => return null,
        }
    }

    pub fn lookupTypeNameByDescriptor(self: *const Context, desc: *const value_mod.TypeDescriptor) ?[]const u8 {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupTypeNameByDescriptorLocked(desc);
    }

    fn lookupTypeNameByDescriptorLocked(self: *const Context, desc: *const value_mod.TypeDescriptor) ?[]const u8 {
        const sentinels = [_]*const value_mod.TypeValue{
            self.dispatch_any_sentinel orelse unreachable,
            self.dispatch_unary_sentinel orelse unreachable,
            self.self_type_sentinel orelse unreachable,
            self.any_type_sentinel orelse unreachable,
        };
        for (sentinels) |tv| {
            if (tv.descriptor) |tv_desc| {
                if (tv_desc == desc) return tv.name;
            }
        }

        var builtin_iter = self.builtin_type_values.iterator();
        while (builtin_iter.next()) |entry| {
            if (entry.value_ptr.*.descriptor) |tv_desc| {
                if (tv_desc == desc) return entry.key_ptr.*;
            }
        }

        var resource_iter = self.resource_type_values.iterator();
        while (resource_iter.next()) |entry| {
            if (entry.value_ptr.*.descriptor) |tv_desc| {
                if (tv_desc == desc) return entry.key_ptr.*;
            }
        }

        var ancestor = self;
        while (true) {
            var frame_idx = ancestor.local_frames.items.len;
            while (frame_idx > 0) {
                frame_idx -= 1;
                var frame_iter = ancestor.local_frames.items[frame_idx].iterator();
                while (frame_iter.next()) |entry| {
                    switch (entry.value_ptr.action) {
                        .compound => |instrs| {
                            if (instrs.len != 1 or instrs[0].op != .push_literal) continue;
                            switch (instrs[0].op.push_literal) {
                                .type_val => |tv| if (tv.descriptor) |tv_desc| {
                                    if (tv_desc == desc) return tv.name;
                                },
                                .tagged => |t| {
                                    const tv = t.tag.type_val orelse continue;
                                    if (tv.descriptor) |tv_desc| {
                                        if (tv_desc == desc) return tv.name;
                                    }
                                },
                                else => {},
                            }
                        },
                        .native, .host_callback => {},
                    }
                }
            }

            var dict_iter = ancestor.dictionary.entries.iterator();
            while (dict_iter.next()) |entry| {
                const def = dict_mod.loadSlot(entry.value_ptr.*);
                switch (def.action) {
                    .compound => |instrs| {
                        if (instrs.len != 1 or instrs[0].op != .push_literal) continue;
                        switch (instrs[0].op.push_literal) {
                            .type_val => |tv| if (tv.descriptor) |tv_desc| {
                                if (tv_desc == desc) return tv.name;
                            },
                            .tagged => |t| {
                                const tv = t.tag.type_val orelse continue;
                                if (tv.descriptor) |tv_desc| {
                                    if (tv_desc == desc) return tv.name;
                                }
                            },
                            else => {},
                        }
                    },
                    .native, .host_callback => {},
                }
            }

            ancestor = ancestor.parent_context orelse break;
        }

        return null;
    }

    fn lookupResourceTypeValueLocked(self: *const Context, name: []const u8) ?*value_mod.TypeValue {
        if (self.resource_type_values.get(name)) |tv| return tv;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            if (ctx.resource_type_values.get(name)) |tv| return tv;
            ancestor = ctx.parent_context;
        }

        return null;
    }

    pub fn lookupParameterizedTypeDescriptor(
        self: *const Context,
        base: *const value_mod.TypeValue,
        element: *const value_mod.TypeValue,
    ) ?*value_mod.TypeDescriptor {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupParameterizedTypeDescriptorLocked(base, element);
    }

    fn lookupParameterizedTypeDescriptorLocked(
        self: *const Context,
        base: *const value_mod.TypeValue,
        element: *const value_mod.TypeValue,
    ) ?*value_mod.TypeDescriptor {
        const key = ParameterizedTypeKey{ .base = base, .element = element };
        if (self.parameterized_type_descriptors.get(key)) |desc| return desc;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            if (ctx.parameterized_type_descriptors.get(key)) |desc| return desc;
            ancestor = ctx.parent_context;
        }

        return null;
    }

    pub fn lookupStructDescriptor(
        self: *const Context,
        fields: []const []const u8,
        field_types: []const ?*const value_mod.TypeValue,
        mutable: bool,
    ) ?*value_mod.TypeDescriptor {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupStructDescriptorLocked(fields, field_types, mutable);
    }

    fn lookupStructDescriptorLocked(
        self: *const Context,
        fields: []const []const u8,
        field_types: []const ?*const value_mod.TypeValue,
        mutable: bool,
    ) ?*value_mod.TypeDescriptor {
        const key = StructDescriptorKey{ .fields = fields, .field_types = field_types, .mutable = mutable };
        if (self.struct_descriptors.get(key)) |desc| return desc;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            if (ctx.struct_descriptors.get(key)) |desc| return desc;
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Look up an interned anonymous union type value by its sorted unique members.
    pub fn lookupAnonymousUnionTypeValue(
        self: *const Context,
        members: []const *const value_mod.TypeValue,
    ) ?*value_mod.TypeValue {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupAnonymousUnionTypeValueLocked(members);
    }

    fn lookupAnonymousUnionTypeValueLocked(
        self: *const Context,
        members: []const *const value_mod.TypeValue,
    ) ?*value_mod.TypeValue {
        const key = AnonymousUnionKey{ .members = members };
        if (self.anonymous_union_type_values.get(key)) |tv| return tv;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            if (ctx.anonymous_union_type_values.get(key)) |tv| return tv;
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Register a built-in type value by name (write-locked).
    pub fn registerBuiltinTypeValue(self: *Context, name: []const u8, tv: *value_mod.TypeValue) !void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        try self.builtin_type_values.put(self.allocator, name, tv);
    }

    /// Register a resource type value by name (write-locked).
    pub fn registerResourceTypeValue(self: *Context, name: []const u8, tv: *value_mod.TypeValue) !void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        try self.resource_type_values.put(self.allocator, name, tv);
    }

    /// Look up a resource TypeValue by name, creating and registering one if it does not exist yet.
    /// This centralizes the lazy-creation pattern used by `type-of` and `dispatchTypeValue`.
    pub fn getOrCreateResourceTypeValue(self: *Context, name: []const u8) !*value_mod.TypeValue {
        if (self.lookupResourceTypeValue(name)) |tv| return tv;

        const alloc = self.quotationAllocator();
        const desc = try value_mod.createTypeDescriptor(
            alloc,
            .{ .resource = .{ .resource_kind = name } },
            .{ .mutable = true },
        );
        // TODO(ripta): investigate per-resource mutability instead of assuming all resources are mutable.
        const tv = try alloc.create(value_mod.TypeValue);
        tv.* = .{ .name = name, .descriptor = desc };

        try self.registerResourceTypeValue(name, tv);
        return tv;
    }

    /// Allocate a fresh ProtocolDescriptor owned by this Context. Each call
    /// produces a distinct descriptor with a unique monotonic protocol_id;
    /// there is no structural interning by name, mirroring the word-identity
    /// semantics already in place for dispatch IDs. The descriptor body lives
    /// in the quotation arena. The list header is freed by deinit.
    pub fn createProtocolDescriptor(
        self: *Context,
        name: []const u8,
        methods: []const value_mod.Value,
    ) !*value_mod.ProtocolDescriptor {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();

        const alloc = self.quotationAllocator();
        const desc = try alloc.create(value_mod.ProtocolDescriptor);
        const name_dup = try alloc.dupe(u8, name);
        const methods_dup = try alloc.alloc(value_mod.Value, methods.len);
        @memcpy(methods_dup, methods);
        desc.* = .{
            .name = name_dup,
            .methods = methods_dup,
            .protocol_id = self.next_protocol_id.fetchAdd(1, .monotonic),
        };
        try self.protocol_descriptors.append(self.allocator, desc);
        return desc;
    }

    /// Return the diagnostic identity for a protocol-bounded dispatch site
    /// bound by `descriptor`: `satisfies-and-dispatch[<protocol>]`. Composed
    /// once per protocol with the program-lifetime quotation allocator and
    /// memoized, so every bounded call site shares the string and no runtime
    /// allocation occurs. Returns a stable fallback if composition fails.
    pub fn boundedDispatchTraceName(
        self: *Context,
        descriptor: *const value_mod.ProtocolDescriptor,
    ) []const u8 {
        if (self.bounded_dispatch_trace_names.get(descriptor)) |name| return name;
        const alloc = self.quotationAllocator();
        const name = std.fmt.allocPrint(
            alloc,
            "satisfies-and-dispatch[{s}]",
            .{descriptor.name},
        ) catch return "satisfies-and-dispatch";
        self.bounded_dispatch_trace_names.put(self.allocator, descriptor, name) catch return name;
        return name;
    }

    /// Look up a cached satisfies-check result for `(type_desc, protocol_desc)`.
    /// Returns `null` if no entry exists yet or the cache was invalidated
    /// since the last write. The lock-free read pattern matches `pic_cache`.
    pub fn lookupProtocolSatisfies(self: *const Context, key: ProtocolSatisfiesKey) ?bool {
        return self.protocol_satisfies_cache.get(key);
    }

    /// Store the outcome of a satisfies-check. Best-effort: on allocation
    /// failure the cache simply does not learn the entry, matching the
    /// pattern in `getOrAllocPicTable`.
    pub fn storeProtocolSatisfies(self: *Context, key: ProtocolSatisfiesKey, value: bool) void {
        self.protocol_satisfies_cache.put(self.allocator, key, value) catch {};
    }

    pub fn getOrCreateParameterizedTypeDescriptor(
        self: *Context,
        base: *const value_mod.TypeValue,
        element: *const value_mod.TypeValue,
    ) !*value_mod.TypeDescriptor {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();

        if (self.lookupParameterizedTypeDescriptorLocked(base, element)) |desc| return desc;

        const alloc = self.quotationAllocator();
        const type_params = try alloc.alloc(*const value_mod.TypeValue, 1);
        type_params[0] = element;
        const desc = try value_mod.createTypeDescriptor(
            alloc,
            .{ .virtual = .{
                .inner_type = base,
                .type_params = type_params,
            } },
            .{},
        );

        try self.parameterized_type_descriptors.put(
            self.allocator,
            .{ .base = base, .element = element },
            desc,
        );
        return desc;
    }

    pub fn getOrCreateStructDescriptor(
        self: *Context,
        fields: []const []const u8,
        field_types: []const ?*const value_mod.TypeValue,
        mutable: bool,
    ) !*value_mod.TypeDescriptor {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();

        if (self.lookupStructDescriptorLocked(fields, field_types, mutable)) |desc| return desc;

        const alloc = self.quotationAllocator();
        // Own a copy of the field-name slice in the descriptor so it
        // outlives the caller's transient slice.
        const owned_fields = try alloc.alloc([]const u8, fields.len);
        for (fields, 0..) |field, i| owned_fields[i] = field;
        const owned_field_types: []const ?*const value_mod.TypeValue = if (field_types.len != 0) blk: {
            const buf = try alloc.alloc(?*const value_mod.TypeValue, field_types.len);
            for (field_types, 0..) |ft, i| buf[i] = ft;
            break :blk buf;
        } else &.{};
        const desc = try value_mod.createTypeDescriptor(
            alloc,
            .{ .struct_ = .{
                .fields = owned_fields,
                .field_types = owned_field_types,
            } },
            .{ .mutable = mutable },
        );

        try self.struct_descriptors.put(
            self.allocator,
            .{ .fields = fields, .field_types = field_types, .mutable = mutable },
            desc,
        );
        return desc;
    }

    fn lessThanTypeValuePtr(_: void, a: *const value_mod.TypeValue, b: *const value_mod.TypeValue) bool {
        return @intFromPtr(a) < @intFromPtr(b);
    }

    fn lessThanTypeValueName(_: void, a: *const value_mod.TypeValue, b: *const value_mod.TypeValue) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }

    fn inferUnionDescriptorFlags(members: []const *const value_mod.TypeValue) value_mod.DescriptorFlags {
        std.debug.assert(members.len != 0);

        var flags = value_mod.DescriptorFlags{
            .numeric = true,
            .exact = true,
            .integer = true,
            .mutable = true,
        };

        for (members) |member| {
            const desc = member.descriptor orelse {
                flags = .{};
                break;
            };

            flags.numeric = flags.numeric and desc.numeric;
            flags.exact = flags.exact and desc.exact;
            flags.integer = flags.integer and desc.integer;
            flags.mutable = flags.mutable and desc.mutable;
        }

        return flags;
    }

    /// Return the canonical type value for an anonymous union member set.
    /// Member order does not matter; duplicates are removed before interning.
    pub fn getOrCreateAnonymousUnionTypeValue(
        self: *Context,
        members: []const *const value_mod.TypeValue,
    ) !*value_mod.TypeValue {
        std.debug.assert(members.len != 0);

        self.acquireSharedWrite();
        defer self.releaseSharedWrite();

        const alloc = self.quotationAllocator();
        var sorted_members = try alloc.alloc(*const value_mod.TypeValue, members.len);
        @memcpy(sorted_members, members);
        std.sort.pdq(*const value_mod.TypeValue, sorted_members, {}, lessThanTypeValuePtr);

        var unique_len: usize = 0;
        for (sorted_members) |member| {
            if (unique_len == 0 or sorted_members[unique_len - 1] != member) {
                sorted_members[unique_len] = member;
                unique_len += 1;
            }
        }
        sorted_members = sorted_members[0..unique_len];

        if (sorted_members.len == 1) {
            return @constCast(sorted_members[0]);
        }

        if (self.lookupAnonymousUnionTypeValueLocked(sorted_members)) |tv| return tv;

        const display_members = try alloc.alloc(*const value_mod.TypeValue, sorted_members.len);
        @memcpy(display_members, sorted_members);
        std.sort.pdq(*const value_mod.TypeValue, display_members, {}, lessThanTypeValueName);

        var name_len: usize = 0;
        for (display_members, 0..) |member, i| {
            name_len += member.name.len;
            if (i + 1 < display_members.len) name_len += 1;
        }
        const union_name = try alloc.alloc(u8, name_len);
        var cursor: usize = 0;
        for (display_members, 0..) |member, i| {
            @memcpy(union_name[cursor .. cursor + member.name.len], member.name);
            cursor += member.name.len;
            if (i + 1 < display_members.len) {
                union_name[cursor] = '|';
                cursor += 1;
            }
        }

        const desc = try value_mod.createTypeDescriptor(
            alloc,
            .{ .union_ = {} },
            inferUnionDescriptorFlags(sorted_members),
        );
        const tv = try alloc.create(value_mod.TypeValue);
        tv.* = .{
            .name = union_name,
            .descriptor = desc,
            .member_types = sorted_members,
        };

        try self.anonymous_union_type_values.put(
            self.allocator,
            .{ .members = sorted_members },
            tv,
        );
        return tv;
    }

    // =========================================================================
    // Type registry frame methods
    // =========================================================================

    /// Push a new empty type registry frame onto the stack.
    pub fn pushTypeRegistryFrame(self: *Context) !void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        return self.pushTypeRegistryFrameLocked();
    }

    fn pushTypeRegistryFrameLocked(self: *Context) !void {
        try self.type_registry_frames.append(self.allocator, .{});
    }

    /// Pop the top type registry frame, discarding its entries.
    pub fn popTypeRegistryFrame(self: *Context) void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        return self.popTypeRegistryFrameLocked();
    }

    fn popTypeRegistryFrameLocked(self: *Context) void {
        if (self.type_registry_frames.items.len > 0) {
            const last = self.type_registry_frames.items.len - 1;
            self.type_registry_frames.items[last].deinit(self.allocator);
            self.type_registry_frames.items.len -= 1;
        }
    }

    /// Register a type descriptor into the topmost type registry frame.
    pub fn registerTypeDescriptor(self: *Context, name: []const u8, desc: *value_mod.TypeDescriptor) !void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        return self.registerTypeDescriptorLocked(name, desc);
    }

    fn registerTypeDescriptorLocked(self: *Context, name: []const u8, desc: *value_mod.TypeDescriptor) !void {
        if (self.type_registry_frames.items.len == 0) return error.OutOfMemory;
        const top = self.type_registry_frames.items.len - 1;
        try self.type_registry_frames.items[top].type_descriptors.put(self.allocator, name, desc);
    }

    /// Register enum variants into the topmost type registry frame.
    pub fn registerEnumVariants(self: *Context, enum_tv: *const value_mod.TypeValue, variants: []const *const value_mod.VirtualType) !void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        return self.registerEnumVariantsLocked(enum_tv, variants);
    }

    fn registerEnumVariantsLocked(self: *Context, enum_tv: *const value_mod.TypeValue, variants: []const *const value_mod.VirtualType) !void {
        if (self.type_registry_frames.items.len == 0) return error.OutOfMemory;
        const top = self.type_registry_frames.items.len - 1;
        try self.type_registry_frames.items[top].enum_registry.put(self.allocator, enum_tv, variants);
    }

    // =========================================================================
    // Dispatch frame methods
    // =========================================================================

    /// Push a new empty dispatch frame onto the stack.
    pub fn pushDispatchFrame(self: *Context) !void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        return self.pushDispatchFrameLocked();
    }

    fn pushDispatchFrameLocked(self: *Context) !void {
        try self.dispatch_frames.append(self.allocator, .{});
    }

    /// Pop the top dispatch frame, discarding its entries.
    /// Bumps the dispatch generation counter to invalidate PICs.
    pub fn popDispatchFrame(self: *Context) void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        return self.popDispatchFrameLocked();
    }

    fn popDispatchFrameLocked(self: *Context) void {
        if (self.dispatch_frames.items.len > 0) {
            const last = self.dispatch_frames.items.len - 1;
            self.dispatch_frames.items[last].deinit(self.allocator);
            self.dispatch_frames.items.len -= 1;
            self.dispatch.generation +%= 1;
            self.protocol_satisfies_cache.clearRetainingCapacity();
        }
    }

    /// Register a dispatch entry into the topmost dispatch frame, or the
    /// base `dispatch.entries` if no frames are pushed.
    pub fn registerDispatch(self: *Context, key: DispatchKey, entry: DispatchEntry, allow_overwrite: bool) !void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        return self.registerDispatchLocked(key, entry, allow_overwrite);
    }

    fn registerDispatchLocked(self: *Context, key: DispatchKey, entry: DispatchEntry, allow_overwrite: bool) !void {
        if (self.dispatch_frames.items.len > 0) {
            const top = self.dispatch_frames.items.len - 1;
            const gop = try self.dispatch_frames.items[top].entries.getOrPut(self.allocator, key);
            if (gop.found_existing and !allow_overwrite) {
                return error.DuplicateMethod;
            }
            gop.value_ptr.* = entry;
            self.dispatch.generation +%= 1;
        } else {
            try self.dispatch.register(key, entry, allow_overwrite);
        }
        // Any new method binding may flip a satisfies-check answer; clear
        // coarsely. (Reached only on a successful register.)
        self.protocol_satisfies_cache.clearRetainingCapacity();
    }

    /// Look up a dispatch entry by key, walking frames then base table.
    /// Used for duplicate/provenance checks during method registration.
    pub fn getDispatchEntry(self: *const Context, key: DispatchKey) ?DispatchEntry {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.getDispatchEntryLocked(key);
    }

    fn getDispatchEntryLocked(self: *const Context, key: DispatchKey) ?DispatchEntry {
        // Walk dispatch frames top-to-bottom
        var i = self.dispatch_frames.items.len;
        while (i > 0) {
            i -= 1;
            if (self.dispatch_frames.items[i].entries.get(key)) |entry| return entry;
        }
        // Base dispatch table
        return self.dispatch.entries.get(key);
    }

    /// Collect all dispatch key-entry pairs for a given dispatch ID, including
    /// entries from all frames, the base table, and parent contexts.
    pub fn dispatchEntriesForId(self: *const Context, dispatch_id: u32, alloc: Allocator) ![]DispatchTable.KeyEntryPair {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.dispatchEntriesForIdLocked(dispatch_id, alloc);
    }

    /// Convenience wrapper: resolve word name to dispatch ID, then collect entries.
    pub fn dispatchEntriesForWord(self: *const Context, word_name: []const u8, alloc: Allocator) ![]DispatchTable.KeyEntryPair {
        const did = self.resolveDispatchId(word_name) orelse return &.{};
        return self.dispatchEntriesForId(did, alloc);
    }

    fn dispatchEntriesForIdLocked(self: *const Context, dispatch_id: u32, alloc: Allocator) ![]DispatchTable.KeyEntryPair {
        var results: std.ArrayListUnmanaged(DispatchTable.KeyEntryPair) = .{};
        // Walk dispatch frames top-to-bottom
        var i = self.dispatch_frames.items.len;
        while (i > 0) {
            i -= 1;
            try dispatch_mod.collectEntriesForDispatchId(&self.dispatch_frames.items[i].entries, dispatch_id, &results, alloc);
        }
        // Base dispatch table
        try dispatch_mod.collectEntriesForDispatchId(&self.dispatch.entries, dispatch_id, &results, alloc);

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            var j = ctx.dispatch_frames.items.len;
            while (j > 0) {
                j -= 1;
                try dispatch_mod.collectEntriesForDispatchId(&ctx.dispatch_frames.items[j].entries, dispatch_id, &results, alloc);
            }
            try dispatch_mod.collectEntriesForDispatchId(&ctx.dispatch.entries, dispatch_id, &results, alloc);
            ancestor = ctx.parent_context;
        }
        const slice = try results.toOwnedSlice(alloc);
        std.mem.sort(DispatchTable.KeyEntryPair, slice, self, struct {
            fn lessThan(ctx: *const Context, a: DispatchTable.KeyEntryPair, b: DispatchTable.KeyEntryPair) bool {
                const a_name = ctx.lookupTypeNameByDescriptorLocked(a.key.type_a) orelse "";
                const b_name = ctx.lookupTypeNameByDescriptorLocked(b.key.type_a) orelse "";
                const cmp_a = std.mem.order(u8, a_name, b_name);
                if (cmp_a != .eq) return cmp_a == .lt;
                const a_b_name = ctx.lookupTypeNameByDescriptorLocked(a.key.type_b) orelse "";
                const b_b_name = ctx.lookupTypeNameByDescriptorLocked(b.key.type_b) orelse "";
                return std.mem.order(u8, a_b_name, b_b_name) == .lt;
            }
        }.lessThan);
        return slice;
    }

    /// Collect all dispatch keys for a given dispatch ID, including
    /// entries from all frames, the base table, and parent contexts.
    pub fn dispatchKeysForId(self: *const Context, dispatch_id: u32, alloc: Allocator) ![]DispatchKey {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.dispatchKeysForIdLocked(dispatch_id, alloc);
    }

    /// Convenience wrapper: resolve word name to dispatch ID, then collect keys.
    pub fn dispatchKeysForWord(self: *const Context, word_name: []const u8, alloc: Allocator) ![]DispatchKey {
        const did = self.resolveDispatchId(word_name) orelse return &.{};
        return self.dispatchKeysForId(did, alloc);
    }

    fn dispatchKeysForIdLocked(self: *const Context, dispatch_id: u32, alloc: Allocator) ![]DispatchKey {
        var results: std.ArrayListUnmanaged(DispatchKey) = .{};
        // Walk dispatch frames top-to-bottom
        var i = self.dispatch_frames.items.len;
        while (i > 0) {
            i -= 1;
            try dispatch_mod.collectKeysForDispatchId(&self.dispatch_frames.items[i].entries, dispatch_id, &results, alloc);
        }
        // Base dispatch table
        try dispatch_mod.collectKeysForDispatchId(&self.dispatch.entries, dispatch_id, &results, alloc);

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            var j = ctx.dispatch_frames.items.len;
            while (j > 0) {
                j -= 1;
                try dispatch_mod.collectKeysForDispatchId(&ctx.dispatch_frames.items[j].entries, dispatch_id, &results, alloc);
            }
            try dispatch_mod.collectKeysForDispatchId(&ctx.dispatch.entries, dispatch_id, &results, alloc);
            ancestor = ctx.parent_context;
        }
        const slice = try results.toOwnedSlice(alloc);
        std.mem.sort(DispatchKey, slice, self, struct {
            fn lessThan(ctx: *const Context, a: DispatchKey, b: DispatchKey) bool {
                const a_name = ctx.lookupTypeNameByDescriptorLocked(a.type_a) orelse "";
                const b_name = ctx.lookupTypeNameByDescriptorLocked(b.type_a) orelse "";
                const cmp_a = std.mem.order(u8, a_name, b_name);
                if (cmp_a != .eq) return cmp_a == .lt;
                const a_b_name = ctx.lookupTypeNameByDescriptorLocked(a.type_b) orelse "";
                const b_b_name = ctx.lookupTypeNameByDescriptorLocked(b.type_b) orelse "";
                return std.mem.order(u8, a_b_name, b_b_name) == .lt;
            }
        }.lessThan);
        return slice;
    }

    /// Check if a name is a qualified name (contains a dot).
    fn isQualifiedName(name: []const u8) bool {
        return std.mem.indexOfScalar(u8, name, '.') != null;
    }

    /// Execute a qualified name like "math.double".
    /// Splits on the rightmost dot, executes the module word to get a module,
    /// then looks up and executes the word in that module.
    fn executeQualifiedName(self: *Context, name: []const u8, line: usize, column: usize) anyerror!void {
        const dot_index = std.mem.lastIndexOfScalar(u8, name, '.') orelse return ExecutionError.UnknownWord;

        const module_path = name[0..dot_index];
        const word_name = name[dot_index + 1 ..];
        if (module_path.len == 0 or word_name.len == 0) {
            return ExecutionError.UnknownWord;
        }

        if (self.lookupWord(module_path)) |module_word| {
            self.pushCallFrame(module_path, self.current_source, line, column);
            defer self.popCallFrame();

            switch (module_word.action) {
                .native => |func| try func(self),
                .host_callback => |host| {
                    const rc = host.callback(host.handle, host.user_data);
                    if (rc != 0) return error.HostCallbackFailed;
                },
                .compound => |instrs| try self.executeInstructions(instrs, null),
            }
        } else {
            return ExecutionError.UnknownWord;
        }

        const module_val = self.stack.pop() catch return ExecutionError.UnknownWord;
        const module = switch (module_val) {
            .module => |m| m,
            else => return error.TypeMismatch,
        };

        if (module.words.get(word_name)) |mod_word| {
            if (self.active_sandbox) |sandbox| {
                if (!sandbox.allows(mod_word.capability)) {
                    self.pushCallFrame(name, self.current_source, line, column);
                    self.pending_error_message = std.fmt.allocPrint(
                        self.arena.allocator(),
                        "'{s}' requires capability '{s}' which is not granted by the active sandbox",
                        .{ name, mod_word.capability.displayName() },
                    ) catch "word denied by sandbox";
                    self.captureCallStackOnError(error.PermissionDenied);
                    self.popCallFrame();
                    return error.PermissionDenied;
                }
            }

            if (self.trace.trace_resolve and trace_mod.matchesPattern(name, self.trace.trace_resolve_pattern)) {
                var tw = trace_mod.TraceWriter.init();
                trace_mod.traceResolve(&tw, name, .{ .qualified_found = .{ .module = module_path, .word = word_name } });
            }

            self.pushCallFrame(name, self.current_source, line, column);
            if (self.trace.trace_words and trace_mod.matchesPattern(name, self.trace.trace_words_pattern)) {
                var tw = trace_mod.TraceWriter.init();
                trace_mod.traceWord(&tw, name, self.current_source, line, &self.stack);
            }
            defer self.popCallFrame();

            switch (mod_word.action) {
                .compound => |instrs| {
                    try self.pushModuleDepsFrame(module);
                    defer {
                        if (self.trace.trace_modules.deps) {
                            var tw = trace_mod.TraceWriter.init();
                            trace_mod.traceModuleDepsPop(&tw, module.name);
                        }
                        self.popLocalFrame();
                    }

                    const has_generic = for (mod_word.markers) |mk| {
                        if (markers_mod.isGenericMarker(mk)) break true;
                    } else false;

                    if (has_generic) {
                        if (try dispatch_helpers.tryDispatchGenericById(self, mod_word.dispatch_id, null)) return;

                        if (instrs.len == 0) {
                            self.setGenericDispatchErrorDetails(name, mod_word.stack_effect);
                            return error.TypeError;
                        }
                    }

                    // NOTE(ripta): Route through the TCO loop rather than executeInstructions directly,
                    //              because a body whose final word tail-calls one of the module's deps
                    //              must have that tail call resolved here, while this module-deps frame
                    //              is still live, instead of leaking a pending tail call past the
                    //              deps-frame teardown.
                    try self.executeQuotationWithPic(.{ .instructions = instrs }, null);
                },
                .native => |func| try func(self),
                .host_callback => |host| {
                    const rc = host.callback(host.handle, host.user_data);
                    if (rc != 0) return error.HostCallbackFailed;
                },
            }
        } else {
            if (self.trace.trace_resolve and trace_mod.matchesPattern(name, self.trace.trace_resolve_pattern)) {
                var tw = trace_mod.TraceWriter.init();
                trace_mod.traceResolve(&tw, name, .{ .qualified_not_found = .{ .module = module_path, .word = word_name } });
            }
            return ExecutionError.UnknownWord;
        }
    }

    /// Push a call frame onto the call stack.
    pub fn pushCallFrame(self: *Context, word_name: []const u8, source: []const u8, line: usize, column: usize) void {
        self.call_stack.append(self.allocator, .{
            .word_name = word_name,
            .source = source,
            .line = line,
            .column = column,
        }) catch {};
    }

    /// Pop a call frame from the call stack.
    pub fn popCallFrame(self: *Context) void {
        if (self.call_stack.items.len > 0) {
            _ = self.call_stack.pop();
        }
    }

    const MAX_INFERENCE_DEPTH = 8;

    const RowVarBinding = struct {
        name: []const u8,
    };

    const RowVarConstraint = struct {
        row_a: []const u8,
        row_b: []const u8,
        diff: i64,
    };

    const RowVarEnv = struct {
        constraints: [8]RowVarConstraint = undefined,
        len: usize = 0,

        /// Record a constraint that row_b - row_a = diff.
        /// Returns false if it conflicts with an existing constraint.
        fn record(self: *RowVarEnv, a: []const u8, b: []const u8, diff: i64) bool {
            if (self.lookup(a, b)) |existing| {
                return existing == diff;
            }
            if (self.len < 8) {
                self.constraints[self.len] = .{ .row_a = a, .row_b = b, .diff = diff };
                self.len += 1;
            }
            return true;
        }

        /// Look up the size difference between two row vars (b - a).
        fn lookup(self: *const RowVarEnv, a: []const u8, b: []const u8) ?i64 {
            for (self.constraints[0..self.len]) |c| {
                if (std.mem.eql(u8, c.row_a, a) and std.mem.eql(u8, c.row_b, b)) {
                    return c.diff;
                }
                if (std.mem.eql(u8, c.row_a, b) and std.mem.eql(u8, c.row_b, a)) {
                    return -c.diff;
                }
            }

            return null;
        }
    };

    const SlotType = union(enum) {
        known: *const StackEffect,
        inferred_delta: i64,
        row_var: RowVarBinding,
        unknown,
    };

    /// Infer a quotation's stack delta by statically analyzing its instructions.
    /// Returns null if the delta cannot be determined (e.g., unknown words, control flow).
    fn inferQuotationDelta(self: *Context, quot: Quotation, enclosing_effect: ?*const StackEffect) ?i64 {
        return self.inferQuotationDeltaImpl(quot, 0, enclosing_effect);
    }

    fn inferQuotationDeltaImpl(self: *Context, quot: Quotation, depth: u32, enclosing_effect: ?*const StackEffect) ?i64 {
        if (depth >= MAX_INFERENCE_DEPTH) return null;

        var delta: i64 = 0;
        var shadow = std.ArrayListUnmanaged(SlotType){};
        defer shadow.deinit(self.allocator);

        if (enclosing_effect) |eff| {
            for (eff.inputs) |param| {
                if (param.is_row_variable) continue;
                const slot: SlotType = if (param.quotation_effect) |qe|
                    .{ .known = qe }
                else
                    .unknown;
                shadow.append(self.allocator, slot) catch {};
            }
        }

        for (quot.instructions) |instr| {
            switch (instr.op) {
                .push_literal => |val| {
                    delta += 1;

                    const slot: SlotType = switch (val) {
                        .quotation => |q| blk: {
                            if (q.effect) |eff| {
                                break :blk .{ .known = eff };
                            }
                            if (self.inferQuotationDeltaImpl(q, depth + 1, null)) |d| {
                                break :blk .{ .inferred_delta = d };
                            }
                            break :blk .unknown;
                        },
                        else => .unknown,
                    };
                    shadow.append(self.allocator, slot) catch {
                        shadow.clearRetainingCapacity();
                    };
                },
                .call_word, .call_word_direct => {
                    const name = instr.op.callTargetName().?;
                    if (matchShuffleWord(name)) |shuffle| {
                        if (self.lookupWord(name)) |word| {
                            if (word.stack_effect) |word_effect| {
                                const word_delta = word_effect.concreteDelta();
                                if (applyShuffleShadow(&shadow, self.allocator, shuffle)) {
                                    delta += word_delta;
                                    continue;
                                }
                                delta += word_delta;
                                self.adjustShadowStack(&shadow, word_delta);
                                continue;
                            }
                        }
                        return null;
                    }
                    if (self.lookupWord(name)) |word| {
                        if (word.effect_transparent) {
                            if (self.resolveTransparentDelta(word, &shadow)) |resolved| {
                                delta += resolved.delta;
                                if (word.stack_effect) |word_effect| {
                                    self.adjustShadowForTransparent(&shadow, word_effect, resolved.quot_delta);
                                }
                            } else {
                                return null;
                            }
                        } else if (word.stack_effect) |word_effect| {
                            if (!word_effect.hasBalancedRowVariables()) {
                                if (self.resolveUnbalancedDelta(word_effect, &shadow)) |resolved_delta| {
                                    delta += resolved_delta;
                                    self.adjustShadowStack(&shadow, resolved_delta);
                                } else {
                                    return null;
                                }
                            } else {
                                const word_delta = word_effect.concreteDelta();
                                delta += word_delta;
                                self.adjustShadowStack(&shadow, word_delta);
                            }
                        } else {
                            return null;
                        }
                    } else {
                        return null;
                    }
                },
            }
        }

        return delta;
    }

    const TransparentResolution = struct {
        delta: i64,
        quot_delta: i64,
    };

    fn resolveTransparentDelta(self: *Context, word: WordDefinition, shadow: *const std.ArrayListUnmanaged(SlotType)) ?TransparentResolution {
        _ = self;
        const effect = word.stack_effect orelse return null;

        const concrete_inputs = effect.concreteInputCount();
        const concrete_outputs = effect.concreteOutputCount();

        var quot_concrete_idx: ?usize = null;
        var concrete_idx: usize = 0;
        for (effect.inputs) |param| {
            if (param.is_row_variable) continue;
            if (param.quotation_effect != null) {
                quot_concrete_idx = concrete_idx;
                break;
            }
            concrete_idx += 1;
        }

        const qi = quot_concrete_idx orelse return null;

        const offset_from_tos = concrete_inputs - 1 - qi;
        if (offset_from_tos >= shadow.items.len) return null;

        const slot = shadow.items[shadow.items.len - 1 - offset_from_tos];
        const quot_delta: i64 = switch (slot) {
            .known => |eff| eff.concreteDelta(),
            .inferred_delta => |d| d,
            .row_var => return null,
            .unknown => return null,
        };

        const ci: i64 = @intCast(concrete_inputs);
        const co: i64 = @intCast(concrete_outputs);
        return .{
            .delta = -ci + co + quot_delta,
            .quot_delta = quot_delta,
        };
    }

    /// Resolve the stack delta of a word with unbalanced row variables by
    /// examining the shadow stack for known quotation arguments and computing
    /// row variable constraints from their inferred deltas.
    fn resolveUnbalancedDelta(self: *Context, word_effect: StackEffect, shadow: *const std.ArrayListUnmanaged(SlotType)) ?i64 {
        _ = self;
        const concrete_inputs = word_effect.concreteInputCount();

        var row_env = RowVarEnv{};

        var concrete_idx: usize = 0;
        for (word_effect.inputs) |param| {
            if (param.is_row_variable) continue;

            if (param.quotation_effect) |quot_effect| {
                const offset_from_tos = concrete_inputs - 1 - concrete_idx;
                if (offset_from_tos < shadow.items.len) {
                    const slot = shadow.items[shadow.items.len - 1 - offset_from_tos];
                    const inferred_delta: i64 = switch (slot) {
                        .known => |eff| eff.concreteDelta(),
                        .inferred_delta => |d| d,
                        .row_var, .unknown => {
                            concrete_idx += 1;
                            continue;
                        },
                    };

                    const input_rvs = quot_effect.inputRowVariableNames();
                    const output_rvs = quot_effect.outputRowVariableNames();
                    const quot_concrete_delta = quot_effect.concreteDelta();

                    if (input_rvs.len == 1 and output_rvs.len == 1) {
                        const diff = inferred_delta - quot_concrete_delta;
                        if (!row_env.record(input_rvs.items[0], output_rvs.items[0], diff)) {
                            return null;
                        }
                    } else if (input_rvs.len == 1 and output_rvs.len == 0) {
                        // Input-only row var without output counterpart; cannot resolve
                        concrete_idx += 1;
                        continue;
                    } else if (input_rvs.len == 0 and output_rvs.len == 1) {
                        concrete_idx += 1;
                        continue;
                    }
                }
            }

            concrete_idx += 1;
        }

        const input_rvs = word_effect.inputRowVariableNames();
        const output_rvs = word_effect.outputRowVariableNames();

        if (input_rvs.len == 1 and output_rvs.len == 1) {
            if (row_env.lookup(input_rvs.items[0], output_rvs.items[0])) |rv_diff| {
                return word_effect.concreteDelta() + rv_diff;
            }
        } else if (input_rvs.len == 0 and output_rvs.len == 0) {
            // No row vars in the word's own effect; the quotation constraints
            // were checked for consistency, and concrete delta is sufficient
            return word_effect.concreteDelta();
        }

        return null;
    }

    fn adjustShadowStack(self: *Context, shadow: *std.ArrayListUnmanaged(SlotType), delta: i64) void {
        if (delta < 0) {
            const to_remove: usize = @intCast(@min(-delta, @as(i64, @intCast(shadow.items.len))));
            shadow.shrinkRetainingCapacity(shadow.items.len - to_remove);
        } else if (delta > 0) {
            const to_add: usize = @intCast(delta);
            for (0..to_add) |_| {
                shadow.append(self.allocator, .unknown) catch {
                    shadow.clearRetainingCapacity();
                    return;
                };
            }
        }
    }

    fn adjustShadowForTransparent(self: *Context, shadow: *std.ArrayListUnmanaged(SlotType), effect: StackEffect, quot_delta: i64) void {
        const concrete_inputs = effect.concreteInputCount();
        const concrete_outputs = effect.concreteOutputCount();
        const pass_throughs = stack_effect_mod.passThroughParams(effect);

        if (pass_throughs.len == 0) {
            const total_delta = -@as(i64, @intCast(concrete_inputs)) + @as(i64, @intCast(concrete_outputs)) + quot_delta;
            self.adjustShadowStack(shadow, total_delta);
            return;
        }

        var saved: [8]SlotType = undefined;
        for (pass_throughs.slice()) |pt| {
            const pos = shadow.items.len -| (concrete_inputs - pt.input_concrete_idx);
            if (pos < shadow.items.len) {
                saved[pt.input_concrete_idx] = shadow.items[pos];
            } else {
                saved[pt.input_concrete_idx] = .unknown;
            }
        }

        const to_pop = @min(concrete_inputs, shadow.items.len);
        shadow.shrinkRetainingCapacity(shadow.items.len - to_pop);

        if (quot_delta < 0) {
            const to_remove: usize = @intCast(@min(-quot_delta, @as(i64, @intCast(shadow.items.len))));
            shadow.shrinkRetainingCapacity(shadow.items.len - to_remove);
        } else if (quot_delta > 0) {
            const to_add: usize = @intCast(quot_delta);
            for (0..to_add) |_| {
                shadow.append(self.allocator, .unknown) catch {
                    shadow.clearRetainingCapacity();
                    return;
                };
            }
        }

        var out_idx: usize = 0;
        for (effect.outputs) |out_param| {
            if (out_param.is_row_variable) continue;

            var slot: SlotType = .unknown;
            for (pass_throughs.slice()) |pt| {
                if (pt.output_concrete_idx == out_idx) {
                    slot = saved[pt.input_concrete_idx];
                    break;
                }
            }

            shadow.append(self.allocator, slot) catch {
                shadow.clearRetainingCapacity();
                return;
            };
            out_idx += 1;
        }
    }

    const ShuffleOp = enum {
        swap,
        dup_,
        drop_,
        over,
        rot,
        neg_rot,
    };

    fn matchShuffleWord(name: []const u8) ?ShuffleOp {
        const map = .{
            .{ "swap", ShuffleOp.swap },
            .{ "dup", ShuffleOp.dup_ },
            .{ "drop", ShuffleOp.drop_ },
            .{ "over", ShuffleOp.over },
            .{ "<rot-", ShuffleOp.rot },
            .{ "-rot>", ShuffleOp.neg_rot },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return null;
    }

    fn applyShuffleShadow(shadow: *std.ArrayListUnmanaged(SlotType), allocator: Allocator, op: ShuffleOp) bool {
        const len = shadow.items.len;
        switch (op) {
            .swap => {
                if (len < 2) return false;
                const tmp = shadow.items[len - 1];
                shadow.items[len - 1] = shadow.items[len - 2];
                shadow.items[len - 2] = tmp;
            },
            .dup_ => {
                if (len < 1) return false;
                const top = shadow.items[len - 1];
                shadow.append(allocator, top) catch return false;
            },
            .drop_ => {
                if (len < 1) return false;
                shadow.shrinkRetainingCapacity(len - 1);
            },
            .over => {
                if (len < 2) return false;
                const second = shadow.items[len - 2];
                shadow.append(allocator, second) catch return false;
            },
            .rot => {
                // a b c -- b c a
                if (len < 3) return false;
                const a = shadow.items[len - 3];
                shadow.items[len - 3] = shadow.items[len - 2];
                shadow.items[len - 2] = shadow.items[len - 1];
                shadow.items[len - 1] = a;
            },
            .neg_rot => {
                // a b c -- c a b
                if (len < 3) return false;
                const c = shadow.items[len - 1];
                shadow.items[len - 1] = shadow.items[len - 2];
                shadow.items[len - 2] = shadow.items[len - 3];
                shadow.items[len - 3] = c;
            },
        }
        return true;
    }

    /// Validate a quotation against an expected effect by inferring its delta.
    /// Returns an error if the quotation doesn't match the expected effect.
    /// When a RowVarEnv is provided, it is used to compute the expected delta
    /// for effects with unbalanced row variables.
    fn validateQuotationEffect(self: *Context, quot: Quotation, expected_effect: *const StackEffect, param_name: []const u8, enclosing_effect: ?*const StackEffect, row_env: ?*const RowVarEnv) !void {
        var expected_delta: i64 = undefined;

        if (expected_effect.hasBalancedRowVariables()) {
            expected_delta = expected_effect.concreteDelta();
        } else if (row_env) |env| {
            const input_rvs = expected_effect.inputRowVariableNames();
            const output_rvs = expected_effect.outputRowVariableNames();
            if (input_rvs.len == 1 and output_rvs.len == 1) {
                if (env.lookup(input_rvs.items[0], output_rvs.items[0])) |rv_diff| {
                    expected_delta = expected_effect.concreteDelta() + rv_diff;
                } else {
                    return;
                }
            } else {
                return;
            }
        } else {
            return;
        }

        // Infer actual delta from quotation instructions
        const inferred_delta = self.inferQuotationDelta(quot, enclosing_effect);

        if (inferred_delta) |actual_delta| {
            if (actual_delta != expected_delta) {
                var effect_buf: [128]u8 = undefined;
                var effect_fbs = std.io.fixedBufferStream(&effect_buf);
                expected_effect.write(effect_fbs.writer()) catch {};
                const effect_str = effect_fbs.getWritten();

                const diff = actual_delta - expected_delta;
                var buf: [512]u8 = undefined;
                const msg = if (diff > 0)
                    std.fmt.bufPrint(&buf, "parameter '{s}' expects {s} but quotation leaves {d} extra value{s} on the stack", .{
                        param_name,
                        effect_str,
                        diff,
                        if (diff == 1) @as([]const u8, "") else "s",
                    }) catch "stack effect mismatch"
                else
                    std.fmt.bufPrint(&buf, "parameter '{s}' expects {s} but quotation consumes {d} extra value{s} from the stack", .{
                        param_name,
                        effect_str,
                        -diff,
                        if (diff == -1) @as([]const u8, "") else "s",
                    }) catch "stack effect mismatch";

                const msg_copy = self.arena.allocator().dupe(u8, msg) catch return primitives.InterpreterError.StackEffectMismatch;

                self.error_details.append(self.allocator, .{
                    .error_type = "stack-effect-mismatch",
                    .message = msg_copy,
                    .source = self.ownedCurrentSource(),
                    .line = 0,
                    .word_name = param_name,
                }) catch {};

                return primitives.InterpreterError.StackEffectMismatch;
            }
        }
        // If we can't infer the delta, don't error - allow dynamic validation
    }

    /// Check if a row variable name is defined in a word's effect (inputs or outputs).
    fn isRowVariableDefined(row_var: []const u8, word_effect: *const StackEffect) bool {
        for (word_effect.inputs) |param| {
            if (std.mem.eql(u8, param.name, row_var)) return true;
        }
        for (word_effect.outputs) |param| {
            if (std.mem.eql(u8, param.name, row_var)) return true;
        }
        return false;
    }

    /// Validate that all row variables in a quotation effect are defined in the
    /// word's effect or in the quotation's own effect.
    fn validateRowVariables(self: *Context, quot_effect: *const StackEffect, word_effect: *const StackEffect, param_name: []const u8) !void {
        // Check all row variables in quotation effect inputs
        for (quot_effect.inputs) |param| {
            if (param.is_row_variable and !isRowVariableDefined(param.name, word_effect) and !isRowVariableDefined(param.name, quot_effect)) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "parameter '{s}' uses undefined row variable '{s}'", .{
                    param_name,
                    param.name,
                }) catch "undefined row variable";

                const msg_copy = self.arena.allocator().dupe(u8, msg) catch return primitives.InterpreterError.StackEffectMismatch;

                self.error_details.append(self.allocator, .{
                    .error_type = "stack-effect-mismatch",
                    .message = msg_copy,
                    .source = self.ownedCurrentSource(),
                    .line = 0,
                    .word_name = param_name,
                }) catch {};

                return primitives.InterpreterError.StackEffectMismatch;
            }
        }

        // Check all row variables in quotation effect outputs
        for (quot_effect.outputs) |param| {
            if (param.is_row_variable and !isRowVariableDefined(param.name, word_effect) and !isRowVariableDefined(param.name, quot_effect)) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "parameter '{s}' uses undefined row variable '{s}'", .{
                    param_name,
                    param.name,
                }) catch "undefined row variable";

                const msg_copy = self.arena.allocator().dupe(u8, msg) catch return primitives.InterpreterError.StackEffectMismatch;

                self.error_details.append(self.allocator, .{
                    .error_type = "stack-effect-mismatch",
                    .message = msg_copy,
                    .source = self.ownedCurrentSource(),
                    .line = 0,
                    .word_name = param_name,
                }) catch {};

                return primitives.InterpreterError.StackEffectMismatch;
            }
        }
    }

    /// Validate quotation parameters against their declared effects.
    /// Uses static analysis to infer the quotation's stack delta and compares
    /// against the expected effect from the parameter annotation.
    /// Also validates that row variables in quotation effects are defined in the word's effect.
    pub fn validateParameterEffects(self: *Context, effect: *const StackEffect) !void {
        // First, validate that all row variables in quotation effects are defined
        for (effect.inputs) |param| {
            if (param.quotation_effect) |quot_effect| {
                try self.validateRowVariables(quot_effect, effect, param.name);
            }
        }

        const concrete_params = effect.concreteInputCount();

        if (concrete_params == 0 or self.stack.depth() < concrete_params) return;

        // Build row variable constraints from quotation parameters that have
        // unbalanced row variables. This lets us validate consistency between
        // related quotation parameters like while's pred and body.
        //
        // XXX(ripta): Ew, so much nesting.
        var row_env = RowVarEnv{};
        var row_env_valid = true;
        {
            var ci: usize = 0;
            for (effect.inputs) |param| {
                if (param.is_row_variable) continue;
                if (param.quotation_effect) |expected_effect| {
                    if (!expected_effect.hasBalancedRowVariables()) {
                        const offset_from_top = concrete_params - 1 - ci;
                        const stack_index = self.stack.depth() - 1 - offset_from_top;
                        if (self.stack.items.items[stack_index] == .quotation) {
                            const quot = self.stack.items.items[stack_index].quotation;
                            if (self.inferQuotationDelta(quot, effect)) |inferred_delta| {
                                const input_rvs = expected_effect.inputRowVariableNames();
                                const output_rvs = expected_effect.outputRowVariableNames();
                                if (input_rvs.len == 1 and output_rvs.len == 1) {
                                    const diff = inferred_delta - expected_effect.concreteDelta();
                                    if (!row_env.record(input_rvs.items[0], output_rvs.items[0], diff)) {
                                        // Conflict means we can't determine the correct
                                        // row var relationship, so skip validation for all
                                        // unbalanced params. This handles valid patterns like
                                        // `when` where one branch is intentionally a no-op.
                                        row_env_valid = false;
                                    }
                                }
                            }
                        }
                    }
                }
                ci += 1;
            }
        }

        // Validate quotation effects on stack
        // The top concrete_params items on the stack are the parameters
        // Stack layout: [...other values] [param_0] [param_1] ... [param_n-1]
        // param_n-1 is on top (offset 0 from top), param_0 is at offset n-1 from top
        var concrete_index: usize = 0;
        for (effect.inputs) |param| {
            // Skip row variables
            if (param.is_row_variable) {
                continue;
            }

            // If this parameter has a quotation effect annotation
            if (param.quotation_effect) |expected_effect| {
                // Calculate offset from top of stack: rightmost concrete param is on top
                const offset_from_top = concrete_params - 1 - concrete_index;

                // Get the stack value at this offset and validate if it's a quotation
                const stack_index = self.stack.depth() - 1 - offset_from_top;
                if (self.stack.items.items[stack_index] == .quotation) {
                    const quot = self.stack.items.items[stack_index].quotation;
                    const env: ?*const RowVarEnv = if (row_env_valid and row_env.len > 0) &row_env else null;

                    try self.validateQuotationEffect(quot, expected_effect, param.name, effect, env);
                }
            }

            concrete_index += 1;
        }
    }

    /// Validate type annotations on stack effect input parameters.
    /// For each annotated input, check that the actual stack value's type
    /// matches the declared TypeValue via pointer identity.
    pub fn validateTypeAnnotations(self: *Context, effect: *const StackEffect) !void {
        return self.validateTypeAnnotationsScoped(effect, .all);
    }

    /// Validate type annotations, optionally skipping protocol bounds. Compiled
    /// code at a protocol-bounded generic dispatch site performs the satisfies-
    /// check inside the dispatch helper, so it validates the remaining (concrete
    /// type) annotations with `.except_protocols` to avoid checking the bound
    /// twice.
    pub fn validateTypeAnnotationsScoped(self: *Context, effect: *const StackEffect, scope: AnnotationScope) !void {
        // Check pragma for opt-out
        if (self.getPragma("type-check")) |pv| {
            if (pv == .string and std.mem.eql(u8, pv.string, "off")) return;
        }

        const concrete_params = effect.concreteInputCount();
        if (concrete_params == 0 or self.stack.depth() < concrete_params) return;

        var concrete_index: usize = 0;
        for (effect.inputs) |param| {
            if (param.is_row_variable) continue;
            defer concrete_index += 1;

            const ann = param.type_annotation orelse continue;

            const offset_from_top = concrete_params - 1 - concrete_index;
            const stack_index = self.stack.depth() - 1 - offset_from_top;
            const val = self.stack.items.items[stack_index];

            switch (ann) {
                .type => |expected_tv| {
                    if (self.any_type_sentinel) |any_tv| {
                        if (expected_tv == any_tv) continue;
                    }

                    const val_tv = helpers.resolveValueTypeValue(self, val) orelse continue;
                    if (helpers.valueMatchesType(self, val, expected_tv)) continue;

                    const actual_name = val_tv.name;
                    const msg = std.fmt.allocPrint(self.arena.allocator(), "type mismatch for parameter '{s}': expected {s}, got {s}", .{ param.name, expected_tv.name, actual_name }) catch "type mismatch";

                    const is_warning = if (self.getPragma("type-check")) |pv2| switch (pv2) {
                        .string => |s| std.mem.eql(u8, s, "warning"),
                        else => false,
                    } else false;

                    if (is_warning) {
                        var tw = trace_mod.TraceWriter.init();
                        tw.print("warning: {s}\n", .{msg});
                    } else {
                        self.pending_error_message = msg;
                        return error.TypeError;
                    }
                },
                .protocol => |descriptor| {
                    if (scope == .except_protocols) continue;

                    const val_tv = helpers.resolveValueTypeValue(self, val) orelse continue;
                    if (val_tv.descriptor == null) continue;

                    const satisfies = try protocols_mod.satisfiesByDescriptor(self, val_tv, descriptor);
                    if (satisfies) continue;

                    const actual_name = val_tv.name;
                    const msg = std.fmt.allocPrint(self.arena.allocator(), "parameter '{s}': type '{s}' does not satisfy protocol '{s}'", .{ param.name, actual_name, descriptor.name }) catch "protocol mismatch";

                    const is_warning = if (self.getPragma("type-check")) |pv2| switch (pv2) {
                        .string => |s| std.mem.eql(u8, s, "warning"),
                        else => false,
                    } else false;

                    if (is_warning) {
                        var tw = trace_mod.TraceWriter.init();
                        tw.print("warning: {s}\n", .{msg});
                    } else {
                        return protocols_mod.raiseProtocolError(self, msg);
                    }
                },
            }
        }
    }

    /// Capture the current call stack to error_details.
    /// Only captures if error_details is empty (first error).
    fn captureCallStackOnError(self: *Context, err: anyerror) void {
        // Only capture on first error
        if (self.error_details.items.len > 0) return;

        // For user-thrown errors, use the ErrorObject's type and message
        // instead of the generic "user-thrown" Zig error name.
        const error_type: []const u8 = blk: {
            if (err == error.UserThrown) {
                if (self.thrown_error) |thrown| {
                    break :blk self.arena.allocator().dupe(u8, thrown.error_type) catch thrown.error_type;
                }
            }
            var kebab_buf: [128]u8 = undefined;
            const kebab_name = pascalToKebabRuntime(@errorName(err), &kebab_buf);
            break :blk self.arena.allocator().dupe(u8, kebab_name) catch @errorName(err);
        };

        const thrown_msg: ?[]const u8 = blk: {
            if (err == error.UserThrown) {
                if (self.thrown_error) |thrown| {
                    break :blk self.arena.allocator().dupe(u8, thrown.message) catch thrown.message;
                }
            }
            break :blk null;
        };

        // Consume any pending error message for the innermost frame
        const pending_msg = self.pending_error_message;
        self.pending_error_message = null;

        // Consume any pending error hint for the innermost frame
        const pending_hint = self.pending_error_hint;
        self.pending_error_hint = null;

        const pending_dispatch_actual_types = self.pending_dispatch_actual_types;
        self.pending_dispatch_actual_types = null;

        const pending_dispatch_available_methods = self.pending_dispatch_available_methods;
        self.pending_dispatch_available_methods = null;

        var is_innermost = true;

        var pending_i: usize = 0;
        while (pending_i < self.jit_pending_trace_frames.items.len) : (pending_i += 1) {
            const frame = self.jit_pending_trace_frames.items[pending_i];
            const message = if (is_innermost and thrown_msg != null)
                thrown_msg.?
            else if (is_innermost and pending_msg != null)
                pending_msg.?
            else
                frame.word_name;

            const se_str: ?[]const u8 = if (is_innermost) blk: {
                if (self.lookupWord(frame.word_name)) |defn| {
                    if (defn.stack_effect) |se| {
                        var buf: [256]u8 = undefined;
                        var fbs = std.io.fixedBufferStream(&buf);
                        se.write(fbs.writer()) catch break :blk null;
                        break :blk self.arena.allocator().dupe(u8, fbs.getWritten()) catch null;
                    }
                }
                break :blk null;
            } else null;

            self.error_details.append(self.allocator, .{
                .error_type = error_type,
                .message = message,
                .source = frame.source,
                .line = frame.line,
                .word_name = frame.word_name,
                .stack_effect_str = se_str,
                .hint = if (is_innermost) pending_hint else null,
                .dispatch_actual_types = if (is_innermost) pending_dispatch_actual_types else null,
                .dispatch_available_methods = if (is_innermost) pending_dispatch_available_methods else null,
            }) catch {};
            is_innermost = false;
        }

        self.clearPendingSyntheticErrorFrames();

        // Iterate call_stack in reverse (innermost first for display)
        var i = self.call_stack.items.len;
        while (i > 0) {
            i -= 1;
            const frame = self.call_stack.items[i];
            const message = if (is_innermost and thrown_msg != null)
                thrown_msg.?
            else if (is_innermost and pending_msg != null)
                pending_msg.?
            else
                frame.word_name;

            const se_str: ?[]const u8 = if (is_innermost) blk: {
                if (self.lookupWord(frame.word_name)) |defn| {
                    if (defn.stack_effect) |se| {
                        var buf: [256]u8 = undefined;
                        var fbs = std.io.fixedBufferStream(&buf);
                        se.write(fbs.writer()) catch break :blk null;
                        break :blk self.arena.allocator().dupe(u8, fbs.getWritten()) catch null;
                    }
                }
                break :blk null;
            } else null;

            self.error_details.append(self.allocator, .{
                .error_type = error_type,
                .message = message,
                .source = frame.source,
                .line = frame.line,
                .word_name = frame.word_name,
                .stack_effect_str = se_str,
                .hint = if (is_innermost) pending_hint else null,
                .dispatch_actual_types = if (is_innermost) pending_dispatch_actual_types else null,
                .dispatch_available_methods = if (is_innermost) pending_dispatch_available_methods else null,
            }) catch {};
            is_innermost = false;
        }
    }

    fn formatDispatchTypeName(self: *const Context, desc: *const value_mod.TypeDescriptor) []const u8 {
        if (desc == self.getDispatchAnySentinel().descriptor.?) return "any";
        return self.lookupTypeNameByDescriptor(desc) orelse "<unknown>";
    }

    fn renderDispatchArgumentTypes(self: *Context, arity: usize) ?[]const u8 {
        const alloc = self.arena.allocator();
        switch (arity) {
            2 => {
                if (self.stack.depth() < 2) return alloc.dupe(u8, "(<missing>, <missing>)") catch null;
                const a = self.stack.peekN(1) catch return alloc.dupe(u8, "(<missing>, <missing>)") catch null;
                const b = self.stack.peek() catch return alloc.dupe(u8, "(<missing>, <missing>)") catch null;
                const a_name = self.formatDispatchTypeName(dispatch_mod.dispatchDescriptor(a, self));
                const b_name = self.formatDispatchTypeName(dispatch_mod.dispatchDescriptor(b, self));
                return std.fmt.allocPrint(alloc, "({s}, {s})", .{ a_name, b_name }) catch null;
            },
            else => {
                if (self.stack.depth() < 1) return alloc.dupe(u8, "(<missing>)") catch null;
                const a = self.stack.peek() catch return alloc.dupe(u8, "(<missing>)") catch null;
                const a_name = self.formatDispatchTypeName(dispatch_mod.dispatchDescriptor(a, self));
                return std.fmt.allocPrint(alloc, "({s})", .{a_name}) catch null;
            },
        }
    }

    fn renderDispatchMethodSignature(self: *Context, key: DispatchKey, writer: anytype) !void {
        const type_a_name = self.formatDispatchTypeName(key.type_a);
        const unary_sentinel = self.getDispatchUnarySentinel().descriptor.?;
        if (key.type_b == unary_sentinel) {
            try writer.print("method{{ {s} }}", .{type_a_name});
            return;
        }

        const type_b_name = self.formatDispatchTypeName(key.type_b);
        try writer.print("method{{ {s} {s} }}", .{ type_a_name, type_b_name });
    }

    fn inferGenericDispatchArity(self: *Context, word_name: []const u8, stack_effect: ?StackEffect) usize {
        const alloc = self.arena.allocator();
        const entries = self.dispatchEntriesForWord(word_name, alloc) catch &.{};
        for (entries) |pair| {
            if (pair.key.type_b != self.getDispatchUnarySentinel().descriptor.?) return 2;
        }
        if (stack_effect) |effect| {
            if (effect.inputs.len >= 2) return 2;
        }
        return 1;
    }

    pub fn setGenericDispatchErrorDetails(self: *Context, word_name: []const u8, stack_effect: ?StackEffect) void {
        self.pending_error_message = "no method found for generic word";
        self.pending_dispatch_actual_types = self.renderDispatchArgumentTypes(self.inferGenericDispatchArity(word_name, stack_effect));

        const alloc = self.arena.allocator();
        const entries = self.dispatchEntriesForWord(word_name, alloc) catch &.{};
        if (entries.len == 0) {
            self.pending_dispatch_available_methods = "none";
            return;
        }

        var list: std.ArrayListUnmanaged(u8) = .{};
        defer list.deinit(alloc);

        for (entries, 0..) |pair, i| {
            if (i > 0) list.append(alloc, '\n') catch return;
            list.appendSlice(alloc, "    ") catch return;
            self.renderDispatchMethodSignature(pair.key, list.writer(alloc)) catch return;
        }

        self.pending_dispatch_available_methods = list.toOwnedSlice(alloc) catch null;
    }

    /// Capture stack effect mismatch details for error reporting.
    fn captureStackEffectMismatch(
        self: *Context,
        word_name: []const u8,
        effect: StackEffect,
        actual_depth: usize,
    ) void {
        // Only capture on first error
        if (self.error_details.items.len > 0) return;

        // Format the declared effect and explanation
        var buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        // Write declared effect
        writer.writeAll("declared ") catch {};
        effect.write(writer) catch {};

        // Write explanation
        writer.print(", requires {d} output(s) but stack has {d}", .{
            effect.outputs.len,
            actual_depth,
        }) catch {};

        // Store the message (copy to arena so it outlives the buffer)
        const msg_copy = self.arena.allocator().dupe(u8, fbs.getWritten()) catch return;
        const source = if (self.call_stack.items.len > 0)
            self.call_stack.items[self.call_stack.items.len - 1].source
        else
            self.ownedCurrentSource();
        const line = if (self.call_stack.items.len > 0)
            self.call_stack.items[self.call_stack.items.len - 1].line
        else
            0;

        self.error_details.append(self.allocator, .{
            .error_type = "stack-effect-mismatch",
            .message = msg_copy,
            .source = source,
            .line = line,
            .word_name = word_name,
        }) catch {};
    }

    /// Execute a quotation's instructions with optional effect validation.
    /// Contains the TCO loop: when executeInstructions signals a tail call,
    /// this function pops the dangling call frame and loops with new instructions.
    pub fn executeQuotation(self: *Context, quotation: Quotation) anyerror!void {
        return self.executeQuotationWithPic(quotation, null);
    }

    /// Execute a quotation with an optional PIC table for inline caching.
    pub fn executeQuotationWithPic(self: *Context, quotation: Quotation, pic_table: ?*PicTable) anyerror!void {
        const saved_source = self.current_source;
        defer self.current_source = saved_source;

        var current_instructions = quotation.instructions;
        var current_pic = pic_table;
        var current_module: ?*const value_mod.Module = null;
        var owns_frame = false;

        while (true) {
            // Record depth before execution for validation
            const depth_before = self.stack.depth();
            self.tail_call_instructions = null;
            self.tail_call_module = null;
            self.tail_call_source = null;

            // Push module deps frame on first entry into a module context. On
            // subsequent iterations, the frame persists so that runtime-defined
            // local words, e.g. a recursive helper inside a module word, remain
            // visible across tail calls.
            if (current_module != null and !owns_frame) {
                try self.pushModuleDepsFrame(current_module.?);
                owns_frame = true;
            }

            const exec_result = self.executeInstructions(current_instructions, current_pic);
            exec_result catch |err| {
                if (owns_frame) {
                    if (self.trace.trace_modules.deps) {
                        if (current_module) |cm| {
                            var tw = trace_mod.TraceWriter.init();
                            trace_mod.traceModuleDepsPop(&tw, cm.name);
                        }
                    }
                    self.popLocalFrame();
                }
                return err;
            };

            // Tail call case: pop the call frame that was pushed by the tail-calling
            // `executeInstructions`, then loop around
            if (self.tail_call_instructions) |tci| {
                self.popCallFrame();
                current_instructions = tci;
                self.tail_call_instructions = null;
                // PIC table is per-word-body; on tail call to a different word,
                // the PIC table no longer applies.
                current_pic = null;

                if (self.tail_call_source) |tcs| self.current_source = tcs;
                self.tail_call_source = null;

                const new_module = self.tail_call_module;
                self.tail_call_module = null;

                if (new_module) |new_mod| {
                    if (owns_frame and current_module.? != new_mod) {
                        if (self.trace.trace_modules.deps) {
                            var tw = trace_mod.TraceWriter.init();
                            trace_mod.traceModuleDepsPop(&tw, current_module.?.name);
                        }
                        self.popLocalFrame();
                        owns_frame = false;
                    }
                    current_module = new_mod;
                }
                continue;
            }

            // Normal terminatio:n pop frame before validation
            if (owns_frame) {
                if (self.trace.trace_modules.deps) {
                    if (current_module) |cm| {
                        var tw = trace_mod.TraceWriter.init();
                        trace_mod.traceModuleDepsPop(&tw, cm.name);
                    }
                }
                self.popLocalFrame();
                owns_frame = false;
            }

            // Non-tail call: validate quotation's stack effect
            if (quotation.effect) |effect| {
                const depth_after = self.stack.depth();
                const expected_delta = effect.concreteDelta();
                const actual_delta: i64 = @as(i64, @intCast(depth_after)) - @as(i64, @intCast(depth_before));

                if (expected_delta != actual_delta) {
                    self.captureQuotationEffectMismatch(effect.*, expected_delta, actual_delta);
                    return primitives.InterpreterError.StackEffectMismatch;
                }
            }
            break;
        }
    }

    /// Execute a quotation with a new local frame for *lexical* scoping.
    /// If the quotation has a compiled code_ptr, dispatches to the compiled
    /// function instead of interpreting instructions.
    pub fn executeQuotationWithFrame(self: *Context, quotation: Quotation) anyerror!void {
        try self.pushLocalFrame();
        defer self.popLocalFrame();

        if (quotation.code_ptr) |ptr| {
            const saved_sp = self.stack.items.items.len;
            var jit_ctx = ir_codegen.JitContext{
                .items_ptr = self.stack.items.items.ptr,
                .sp_ptr = &self.stack.items.items.len,
                .capacity = self.stack.items.capacity,
                .ctx = self,
            };
            const func: ir_codegen.CompiledFn = @ptrCast(@alignCast(ptr));
            switch (ir_codegen.ExecResult.fromStatus(func(&jit_ctx))) {
                .ok => return,
                .error_propagate => {
                    const err = self.jit_pending_error orelse error.UserThrown;
                    self.jit_pending_error = null;
                    return err;
                },
                .bail => {
                    if (bail_stats_mod.enabled) {
                        bail_stats_mod.global.recordQuotationBail();
                    }
                    self.stack.items.items.len = saved_sp;
                },
            }
        }

        try self.executeQuotation(quotation);
    }

    /// Execute a quotation with a local frame but WITHOUT the TCO loop.
    ///
    /// Tail call "flag" propagates upward to the caller's executeQuotation loop.
    /// Used only by `if` so that tail calls in conditional branches propagate
    /// through to the enclosing word's TCO loop (e.g., times -> if -> times).
    pub fn executeQuotationInline(self: *Context, quotation: Quotation) anyerror!void {
        try self.pushLocalFrame();
        defer self.popLocalFrame();

        const depth_before = self.stack.depth();
        try self.executeInstructions(quotation.instructions, null);

        // If tail call is pending, skip the stack-effect validation and propagate upward
        if (self.tail_call_instructions != null) {
            return;
        }

        if (quotation.effect) |effect| {
            const depth_after = self.stack.depth();
            const expected_delta = effect.concreteDelta();
            const actual_delta: i64 = @as(i64, @intCast(depth_after)) - @as(i64, @intCast(depth_before));

            if (expected_delta != actual_delta) {
                self.captureQuotationEffectMismatch(effect.*, expected_delta, actual_delta);
                return primitives.InterpreterError.StackEffectMismatch;
            }
        }
    }

    /// End benchmark profiling, capture the call stack, pop the call frame,
    /// and propagate the error.
    pub fn wordErrorCleanup(self: *Context, name: []const u8, err: anyerror) anyerror {
        if (self.benchmark) |b| b.endWordProfile(self.allocator, name);
        if (self.profile) |p| p.recordWordEnd(self.allocator, name);
        self.captureCallStackOnError(err);
        self.popCallFrame();
        return err;
    }

    /// Validate the stack effect (if declared), end benchmark profiling with
    /// peak-depth update, and pop the call frame.
    pub fn wordSuccessCleanup(self: *Context, name: []const u8, stack_effect: ?StackEffect) !void {
        if (stack_effect) |effect| {
            const depth_after = self.stack.depth();
            if (depth_after < effect.concreteOutputCount()) {
                self.captureStackEffectMismatch(name, effect, depth_after);
                if (self.benchmark) |b| b.endWordProfile(self.allocator, name);
                if (self.profile) |p| p.recordWordEnd(self.allocator, name);
                self.popCallFrame();
                return primitives.InterpreterError.StackEffectMismatch;
            }
        }
        if (self.benchmark) |b| {
            b.endWordProfile(self.allocator, name);
            b.updatePeakStackDepth(self.stack.depth());
        }
        if (self.profile) |p| p.recordWordEnd(self.allocator, name);
        self.popCallFrame();
    }

    /// Pop a module deps local frame, emitting a trace log when module
    /// tracing is enabled.
    pub fn popModuleDepsFrameTraced(self: *Context, mod: *const value_mod.Module) void {
        if (self.trace.trace_modules.deps) {
            var tw = trace_mod.TraceWriter.init();
            trace_mod.traceModuleDepsPop(&tw, mod.name);
        }
        self.popLocalFrame();
    }

    /// Emit trace output for word execution, resolve source, and scope dump.
    fn traceWordExecution(self: *Context, name: []const u8, instr: Instruction) void {
        if (self.trace.trace_words and trace_mod.matchesPattern(name, self.trace.trace_words_pattern)) {
            var tw = trace_mod.TraceWriter.init();
            trace_mod.traceWord(&tw, name, self.current_source, instr.line, &self.stack);
        }
        if (self.trace.trace_resolve and trace_mod.matchesPattern(name, self.trace.trace_resolve_pattern)) {
            var tw = trace_mod.TraceWriter.init();
            trace_mod.traceResolve(&tw, name, self.lookupWordSource(name));
        }
        if (self.trace.dump_scope) |scope_word| {
            if (std.mem.eql(u8, name, scope_word)) {
                self.dumpScope(name, self.current_source, instr.line);
            }
        }
    }

    /// When a native word in non-tail position propagated a tail call flag
    /// via executeQuotationInline, consume it: pop the dangling call frame
    /// and execute the deferred instructions normally. This prevents invalid
    /// call stack frames from accumulating without bound.
    pub fn consumePropagatedTailCall(self: *Context, name: []const u8) anyerror!void {
        const tci = self.tail_call_instructions orelse return;
        self.popCallFrame();
        self.tail_call_instructions = null;

        const tci_module = self.tail_call_module;
        self.tail_call_module = null;

        if (tci_module) |mod| {
            self.pushModuleDepsFrame(mod) catch |e| return self.wordErrorCleanup(name, e);
        }

        self.executeQuotation(.{ .instructions = tci }) catch |err| {
            if (tci_module) |mod| self.popModuleDepsFrameTraced(mod);
            return self.wordErrorCleanup(name, err);
        };

        if (tci_module) |mod| self.popModuleDepsFrameTraced(mod);
    }

    /// Signal returned by `executeResolvedWord` to the dispatch loop.
    const ResolvedWordResult = enum {
        /// Advance to the next instruction (`continue` at the call site).
        proceed,
        /// The tail-call slot has been set; the caller must return so the
        /// outer dispatch loop replays the trampolined body.
        tail_call_set,
    };

    /// Shared body of the `call_word` and `call_word_direct` dispatch arms,
    /// taking the resolved name and definition. Caller is responsible for the
    /// signal check, profiling start, and (for `call_word`) the lookup or
    /// fallback path; this helper handles sandbox, parse-time-only,
    /// JIT dispatch, generic dispatch, recursion-marker check, tail-call
    /// setup, stack-limit check, and the native/host/compound call itself.
    fn executeResolvedWord(
        self: *Context,
        name: []const u8,
        word: WordDefinition,
        instr: Instruction,
        idx: usize,
        pic_table: ?*PicTable,
        is_last: bool,
    ) anyerror!ResolvedWordResult {
        if (self.active_sandbox) |sandbox| {
            if (!sandbox.allows(word.capability)) {
                self.pushCallFrame(name, self.current_source, instr.line, instr.column);
                self.pending_error_message = std.fmt.allocPrint(
                    self.arena.allocator(),
                    "'{s}' requires capability '{s}' which is not granted by the active sandbox",
                    .{ name, word.capability.displayName() },
                ) catch "word denied by sandbox";
                return self.wordErrorCleanup(name, error.PermissionDenied);
            }
        }

        if (word.parse_time_only and self.parse_tokenizer == null) {
            self.pushCallFrame(name, self.current_source, instr.line, instr.column);
            self.pending_error_message = "parse-time-only word cannot be called at runtime";
            return self.wordErrorCleanup(name, error.ParseError);
        }

        // Try JIT-compiled dispatch before interpreter path
        if (word.word_id) |wid| {
            if (word.stack_effect) |effect| {
                self.validateParameterEffects(&effect) catch |err| {
                    self.pushCallFrame(name, self.current_source, instr.line, instr.column);
                    return self.wordErrorCleanup(name, err);
                };
                if (!shouldSkipTypeAnnotationValidation(word)) {
                    self.validateTypeAnnotations(&effect) catch |err| {
                        self.pushCallFrame(name, self.current_source, instr.line, instr.column);
                        return self.wordErrorCleanup(name, err);
                    };
                }
            }
            const saved_source = self.current_source;
            if (word.source_file) |sf| self.current_source = sf;
            const jit_result = if (word.source_module) |mod| blk: {
                self.pushModuleDepsFrame(mod) catch |err| {
                    self.current_source = saved_source;
                    self.pushCallFrame(name, self.current_source, instr.line, instr.column);
                    return self.wordErrorCleanup(name, err);
                };
                defer self.popModuleDepsFrameTraced(mod);
                break :blk ir_codegen.executeCompiled(self, wid);
            } else ir_codegen.executeCompiled(self, wid);
            self.current_source = saved_source;
            if (self.trace.trace_jit) {
                var tw = trace_mod.TraceWriter.init();
                trace_mod.traceJitDispatch(&tw, name, wid, jit_result != .bail);
            }
            switch (jit_result) {
                .ok => {
                    if (self.benchmark) |bm| bm.endWordProfile(self.allocator, name);
                    if (self.profile) |p| p.recordWordEnd(self.allocator, name);
                    return .proceed;
                },
                .error_propagate => {
                    const err = self.jit_pending_error orelse error.UserThrown;
                    self.jit_pending_error = null;
                    return err;
                },
                .bail => {
                    if (self.compile_mode == .hybrid) {
                        self.tryHybridCompile(wid, name, word);
                    }
                },
            }
        }

        self.pushCallFrame(name, self.current_source, instr.line, instr.column);
        self.traceWordExecution(name, instr);

        if (word.stack_effect) |effect| {
            self.validateParameterEffects(&effect) catch |err|
                return self.wordErrorCleanup(name, err);
            if (!shouldSkipTypeAnnotationValidation(word)) {
                self.validateTypeAnnotations(&effect) catch |err|
                    return self.wordErrorCleanup(name, err);
            }
        }

        if (word.action == .compound) {
            const has_generic = blk: {
                for (word.markers) |mk| {
                    if (markers_mod.isGenericMarker(mk)) break :blk true;
                }
                break :blk false;
            };

            if (has_generic) {
                const pic_entry = if (pic_table) |pt| pt.get(idx) else null;
                const dispatched = dispatch_helpers.tryDispatchGenericById(self, word.dispatch_id, pic_entry) catch |err|
                    return self.wordErrorCleanup(name, err);

                if (dispatched) {
                    try self.wordSuccessCleanup(name, null);
                    return .proceed;
                }

                if (word.action.compound.len == 0) {
                    self.setGenericDispatchErrorDetails(name, word.stack_effect);
                    return self.wordErrorCleanup(name, error.TypeError);
                }
            }

            if (!self.allow_all_recursion) {
                const has_non_tco = for (word.markers) |mk| {
                    if (mk == &markers_mod.recursive_non_tco_marker) break true;
                } else false;

                if (has_non_tco) {
                    const has_stack_recursive = for (word.markers) |mk| {
                        if (markers_mod.isStackRecursiveMarker(mk)) break true;
                    } else false;

                    if (!has_stack_recursive) {
                        self.pending_error_message = "word has recursive-non-tco marker but lacks stack-recursive marker";
                        return self.wordErrorCleanup(name, error.NonTailRecursion);
                    }
                }
            }
        }

        if (is_last) {
            switch (word.action) {
                .compound => |instrs| {
                    if (self.benchmark) |b| b.endWordProfile(self.allocator, name);
                    if (self.profile) |p| p.recordWordEnd(self.allocator, name);
                    self.tail_call_instructions = instrs;
                    self.tail_call_module = word.source_module;
                    self.tail_call_source = word.source_file;
                    return .tail_call_set;
                },
                .native => |func| {
                    self.tail_call_instructions = null;
                    self.current_pic_entry = if (pic_table) |pt| pt.get(idx) else null;
                    defer self.current_pic_entry = null;
                    if (func(self)) |_| {
                        try self.wordSuccessCleanup(name, word.stack_effect);
                    } else |err| {
                        return self.wordErrorCleanup(name, err);
                    }
                },
                .host_callback => |host| {
                    self.tail_call_instructions = null;
                    self.current_pic_entry = if (pic_table) |pt| pt.get(idx) else null;
                    defer self.current_pic_entry = null;
                    const result: anyerror!void = blk: {
                        const rc = host.callback(host.handle, host.user_data);
                        if (rc != 0) break :blk error.HostCallbackFailed;
                    };
                    if (result) |_| {
                        try self.wordSuccessCleanup(name, word.stack_effect);
                    } else |err| {
                        return self.wordErrorCleanup(name, err);
                    }
                },
            }
        } else {
            if (self.stack_limit != 0) {
                const sp = @frameAddress();
                const usage = self.stack_high -| sp;
                if (self.scheduler) |sched| {
                    if (sched.current_task) |task| {
                        if (usage > task.peak_stack_usage) {
                            task.peak_stack_usage = usage;
                        }
                    }
                }
                if (sp <= self.stack_limit) {
                    const used = self.stack_high -| sp;
                    const total = self.stack_high -| self.stack_limit +| (32 * 1024);
                    self.pending_error_message = std.fmt.allocPrint(
                        self.arena.allocator(),
                        "stack overflow: {} of {} bytes used",
                        .{ used, total },
                    ) catch "stack overflow";
                    return self.wordErrorCleanup(name, error.StackOverflow);
                }
            }

            const callee_pic = if (word.action == .compound) self.getOrAllocPicTable(word.action.compound) else null;

            if (word.isNativeLike()) {
                self.current_pic_entry = if (pic_table) |pt| pt.get(idx) else null;
            }
            defer self.current_pic_entry = null;

            const result = blk: {
                const saved_source = self.current_source;
                defer self.current_source = saved_source;
                if (word.source_file) |sf| self.current_source = sf;
                if (word.source_module) |mod| {
                    switch (word.action) {
                        .compound => |instrs| {
                            self.pushModuleDepsFrame(mod) catch |e| break :blk @as(anyerror!void, e);
                            defer self.popModuleDepsFrameTraced(mod);
                            break :blk self.executeQuotationWithPic(.{ .instructions = instrs }, callee_pic);
                        },
                        .native => |func| break :blk func(self),
                        .host_callback => |host| break :blk host_result: {
                            const rc = host.callback(host.handle, host.user_data);
                            if (rc != 0) break :host_result error.HostCallbackFailed;
                            break :host_result;
                        },
                    }
                } else {
                    break :blk switch (word.action) {
                        .native => |func| func(self),
                        .host_callback => |host| host_result: {
                            const rc = host.callback(host.handle, host.user_data);
                            if (rc != 0) break :host_result error.HostCallbackFailed;
                            break :host_result;
                        },
                        .compound => |instrs| self.executeQuotationWithPic(.{ .instructions = instrs }, callee_pic),
                    };
                }
            };

            if (result) |_| {
                try self.consumePropagatedTailCall(name);
                try self.wordSuccessCleanup(name, word.stack_effect);
            } else |err| {
                return self.wordErrorCleanup(name, err);
            }
        }

        return .proceed;
    }

    /// Execute raw instructions without stack-effect validation.
    ///
    /// Supports generic word dispatch.
    ///
    /// Supports tail call optimization: i.e., when the last instruction is a
    /// compound `call_word`, sets `tail_call_instructions` instead of recursing.
    fn executeInstructions(self: *Context, instructions: []const Instruction, pic_table: ?*PicTable) anyerror!void {
        for (instructions, 0..) |instr, idx| {
            if (self.debugger) |dbg| {
                if (try dbg.shouldPause(instr, self)) {
                    if (dbg.hasCCallback()) {
                        dbg.handleCPause(self);
                    } else {
                        try dbg.enterPrompt(instr, self);
                    }
                }
            }

            const is_last = (idx == instructions.len - 1);

            switch (instr.op) {
                .push_literal => |val| {
                    try self.stack.push(val);
                    if (self.benchmark) |b| {
                        b.recordPushLiteral();
                        b.updatePeakStackDepth(self.stack.depth());
                    }
                },
                .call_word => |name| {
                    signal.checkPendingSignals(self) catch |err| {
                        self.pushCallFrame(name, self.current_source, instr.line, instr.column);
                        return self.wordErrorCleanup(name, err);
                    };

                    if (self.benchmark) |b| {
                        b.recordCallWord();
                        b.beginWordProfile();
                    }
                    if (self.profile) |p| p.recordWordStart(self.allocator);

                    if (self.lookupWordForExecution(name)) |word| {
                        switch (try self.executeResolvedWord(name, word, instr, idx, pic_table, is_last)) {
                            .proceed => {},
                            .tail_call_set => return,
                        }
                    } else if (isQualifiedName(name)) {
                        self.executeQualifiedName(name, instr.line, instr.column) catch |err| {
                            self.pushCallFrame(name, self.current_source, instr.line, instr.column);
                            self.captureCallStackOnError(err);
                            self.popCallFrame();
                            return err;
                        };
                        if (self.benchmark) |b| {
                            b.updatePeakStackDepth(self.stack.depth());
                        }
                    } else {
                        if (self.trace.trace_resolve and trace_mod.matchesPattern(name, self.trace.trace_resolve_pattern)) {
                            var tw = trace_mod.TraceWriter.init();
                            trace_mod.traceResolve(&tw, name, .not_found);
                        }
                        self.pushCallFrame(name, self.current_source, instr.line, instr.column);
                        self.captureCallStackOnError(ExecutionError.UnknownWord);
                        self.popCallFrame();
                        return ExecutionError.UnknownWord;
                    }
                },
                .call_word_direct => |slot| {
                    const name = slot.name;
                    signal.checkPendingSignals(self) catch |err| {
                        self.pushCallFrame(name, self.current_source, instr.line, instr.column);
                        return self.wordErrorCleanup(name, err);
                    };

                    if (self.benchmark) |b| {
                        b.recordCallWord();
                        b.beginWordProfile();
                    }
                    if (self.profile) |p| p.recordWordStart(self.allocator);

                    const word = dict_mod.loadSlot(slot).*;
                    switch (try self.executeResolvedWord(name, word, instr, idx, pic_table, is_last)) {
                        .proceed => {},
                        .tail_call_set => return,
                    }
                },
            }
        }
    }

    /// Capture quotation effect mismatch details for error reporting.
    fn captureQuotationEffectMismatch(
        self: *Context,
        effect: StackEffect,
        expected_delta: i64,
        actual_delta: i64,
    ) void {
        // Only capture on first error
        if (self.error_details.items.len > 0) return;

        // Format the declared effect and explanation
        var buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        // Write declared effect
        writer.writeAll("quotation declared ") catch {};
        effect.write(writer) catch {};

        // Write explanation
        writer.print(", expected delta {d} but got {d}", .{
            expected_delta,
            actual_delta,
        }) catch {};

        // Store the message (copy to arena so it outlives the buffer)
        const msg_copy = self.arena.allocator().dupe(u8, fbs.getWritten()) catch return;

        const line = if (self.call_stack.items.len > 0)
            self.call_stack.items[self.call_stack.items.len - 1].line
        else
            0;

        self.error_details.append(self.allocator, .{
            .error_type = "stack-effect-mismatch",
            .message = msg_copy,
            .source = self.ownedCurrentSource(),
            .line = line,
            .word_name = "<quotation>",
        }) catch {};
    }
};

// =============================================================================
// JIT auto-compile helpers (used by Context.tryAutoCompile)
// =============================================================================

const ResolverState = struct {
    context: *Context,
};

fn hasNeverReturnsMarker(markers: []const *const value_mod.Marker) bool {
    for (markers) |mk| {
        if (markers_mod.isNeverReturnsMarker(mk)) return true;
    }
    return false;
}

fn resolveWordForDispatch(name: []const u8, user_data: *anyopaque) ?ir_codegen.ResolvedWord {
    const state: *ResolverState = @ptrCast(@alignCast(user_data));
    const ctx = state.context;
    const callee = ctx.lookupWord(name) orelse return null;

    switch (callee.action) {
        .compound => {},
        .native => |func| {
            const effect = callee.stack_effect orelse return null;
            var result = ir_codegen.ResolvedWord{
                .word_id = 0,
                .input_count = @intCast(effect.inputs.len),
                .output_count = @intCast(effect.outputs.len),
                .is_native = true,
                .native_fn_ptr = @intFromPtr(func),
                .never_returns = hasNeverReturnsMarker(callee.markers),
                .dispatch_id = callee.dispatch_id,
            };
            if (stack_effect_mod.hasAnyRowVariable(effect)) {
                result.callee_effect = ctx.lookupWordStackEffectPtr(name);
            }
            return result;
        },
        .host_callback => return null,
    }

    const effect = callee.stack_effect orelse return null;

    const word_id = if (callee.word_id) |id| id else blk: {
        const id = ctx.jit_dispatch.assignId(name) catch return null;
        propagateWordId(ctx, name, id);
        break :blk id;
    };

    const bounded = dispatch_helpers.boundedDispatchFor(&effect, callee.markers, name);

    var result = ir_codegen.ResolvedWord{
        .word_id = word_id,
        .input_count = @intCast(effect.inputs.len),
        .output_count = @intCast(effect.outputs.len),
        .never_returns = hasNeverReturnsMarker(callee.markers),
        .dispatch_id = callee.dispatch_id,
        .bounded_protocol = if (bounded) |b| b.descriptor else null,
        .bounded_arity = if (bounded) |b| b.arity else .unary,
        .bounded_trace_name = if (bounded) |b| ctx.boundedDispatchTraceName(b.descriptor) else null,
    };
    if (stack_effect_mod.hasAnyRowVariable(effect)) {
        result.callee_effect = ctx.lookupWordStackEffectPtr(name);
    }
    return result;
}

fn propagateWordId(ctx: *Context, name: []const u8, word_id: u32) void {
    var i = ctx.local_frames.items.len;
    while (i > 0) {
        i -= 1;
        if (ctx.local_frames.items[i].getPtr(name)) |entry| {
            entry.word_id = word_id;
            return;
        }
    }
    if (ctx.dictionary.entries.get(name)) |slot| {
        dict_mod.loadSlot(slot).word_id = word_id;
        return;
    }
    var ancestor = ctx.parent_context;
    while (ancestor) |anc| {
        var j = anc.local_frames.items.len;
        while (j > 0) {
            j -= 1;
            if (anc.local_frames.items[j].getPtr(name)) |entry| {
                entry.word_id = word_id;
                return;
            }
        }
        if (anc.dictionary.entries.get(name)) |slot| {
            dict_mod.loadSlot(slot).word_id = word_id;
            return;
        }
        ancestor = anc.parent_context;
    }
}

// =============================================================================
// Tests
// =============================================================================

test "init and deinit" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
}

test "stack operations through context" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(Value{ .fixnum = 42 });
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());

    const val = try ctx.stack.pop();
    try std.testing.expectEqual(@as(i64, 42), val.fixnum);
}

test "quotation allocator frees on deinit" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const alloc = ctx.quotationAllocator();
    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 0 };
    instrs[2] = .{ .op = .{ .call_word = "+" }, .line = 0 };

    try ctx.dictionary.put("test-word", .{
        .name = "test-word",
        .action = .{ .compound = instrs },
    });
}

test "registerQuotationContainerLiterals: skips scalar-only quotations" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const instrs = try ctx.quotationAllocator().alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 };
    instrs[1] = .{ .op = .{ .call_word = "drop" }, .line = 0 };

    try ctx.registerQuotationContainerLiterals(instrs);
    try std.testing.expectEqual(@as(usize, 0), ctx.container_release_list.items.len);
}

test "registerQuotationContainerLiterals: records quotations with container literals" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const dummy_vec = try value_mod.Vector.create(std.testing.allocator);
    // Two registrations of the same instrs slice means the walk will
    // release the embedded vector twice. Bump refcount once so total
    // refs after create+retain (=2) match the two walk-releases.
    dummy_vec.header.retain();
    const instrs = try ctx.quotationAllocator().alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 0 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .vector = dummy_vec } }, .line = 0 };

    try ctx.registerQuotationContainerLiterals(instrs);
    try ctx.registerQuotationContainerLiterals(instrs);
    try std.testing.expectEqual(@as(usize, 2), ctx.container_release_list.items.len);

    ctx.walkContainerReleaseList();
    try std.testing.expectEqual(@as(usize, 0), ctx.container_release_list.items.len);
    // walkContainerReleaseList consumed both refs and destroyed dummy_vec.
}

test "Context.deinit walks release list before arena teardown" {
    // Asserts the wiring does not crash and the testing allocator does
    // not flag a leak through the release-list storage itself.
    var ctx = Context.init(std.testing.allocator);

    const dummy_vec = try value_mod.Vector.create(std.testing.allocator);
    // One registration of the slice; the deinit walk releases the
    // embedded vector once. The create's rc=1 balances that single
    // release, so the vec is destroyed cleanly by deinit.
    const instrs = try ctx.quotationAllocator().alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .push_literal = .{ .vector = dummy_vec } }, .line = 0 };
    try ctx.registerQuotationContainerLiterals(instrs);

    ctx.deinit();
}

test "call stack captured on error, calling an unknown word" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Create a word that calls an unknown word, with a non-tail-call
    // structure so TCO doesn't eliminate intermediate frames.
    const alloc = ctx.quotationAllocator();
    const inner_instrs = try alloc.alloc(Instruction, 2);
    inner_instrs[0] = .{ .op = .{ .call_word = "nonexistent" }, .line = 10 };
    inner_instrs[1] = .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 10 };

    try ctx.dictionary.put("inner", .{
        .name = "inner",
        .action = .{ .compound = inner_instrs },
    });

    const outer_instrs = try alloc.alloc(Instruction, 2);
    outer_instrs[0] = .{ .op = .{ .call_word = "inner" }, .line = 20 };
    outer_instrs[1] = .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 20 };

    try ctx.dictionary.put("outer", .{
        .name = "outer",
        .action = .{ .compound = outer_instrs },
    });

    // Execute outer -> inner -> nonexistent (error)
    // Add a trailing push so call_word("outer") is not in tail position
    const top_instrs = try alloc.alloc(Instruction, 2);
    top_instrs[0] = .{ .op = .{ .call_word = "outer" }, .line = 30 };
    top_instrs[1] = .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 30 };

    const result = ctx.executeQuotation(.{ .instructions = top_instrs });
    try std.testing.expectError(ExecutionError.UnknownWord, result);

    // Check error_details captured the call stack (innermost first)
    try std.testing.expectEqual(@as(usize, 3), ctx.error_details.items.len);

    // First entry: nonexistent (innermost, where error occurred)
    try std.testing.expectEqualStrings("nonexistent", ctx.error_details.items[0].word_name.?);
    try std.testing.expectEqual(@as(usize, 10), ctx.error_details.items[0].line);

    // Second entry: inner
    try std.testing.expectEqualStrings("inner", ctx.error_details.items[1].word_name.?);
    try std.testing.expectEqual(@as(usize, 20), ctx.error_details.items[1].line);

    // Third entry: outer (outermost)
    try std.testing.expectEqualStrings("outer", ctx.error_details.items[2].word_name.?);
    try std.testing.expectEqual(@as(usize, 30), ctx.error_details.items[2].line);
}

test "call stack empty after successful execution" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Execute some successful operations
    const alloc = ctx.quotationAllocator();
    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 2 };
    instrs[2] = .{ .op = .{ .call_word = "+" }, .line = 3 };

    try ctx.executeQuotation(.{ .instructions = instrs });

    // Call stack should be empty after successful execution
    try std.testing.expectEqual(@as(usize, 0), ctx.call_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.error_details.items.len);
}

test "clearExecutionDetails clears both call stack and error details" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Manually add some data to test clearing
    ctx.call_stack.append(ctx.allocator, .{ .word_name = "test", .source = "<test>", .line = 1 }) catch {};
    ctx.error_details.append(ctx.allocator, .{
        .error_type = "test-error",
        .message = "test",
        .source = "<test>",
        .line = 1,
        .word_name = "test",
    }) catch {};

    try std.testing.expectEqual(@as(usize, 1), ctx.call_stack.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.error_details.items.len);

    ctx.clearExecutionDetails();

    try std.testing.expectEqual(@as(usize, 0), ctx.call_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.error_details.items.len);
}

test "stack effect validation passes for correct effect" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // dup has effect ( a -- a a ), which is correct
    // Push 1, call dup, should have 2 items
    const alloc = ctx.quotationAllocator();
    const instrs = try alloc.alloc(Instruction, 2);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = 5 } }, .line = 1 };
    instrs[1] = .{ .op = .{ .call_word = "dup" }, .line = 2 };

    try ctx.executeQuotation(.{ .instructions = instrs });
    try std.testing.expectEqual(@as(usize, 2), ctx.stack.depth());
}

test "stack effect validation fails when word produces fewer outputs than declared" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const alloc = ctx.quotationAllocator();

    // Create a word that claims to produce 2 outputs but actually produces 0
    // Effect: ( -- a b ) but body is empty
    const empty_instrs = try alloc.alloc(Instruction, 0);
    const outputs = try alloc.alloc(StackEffectParam, 2);
    outputs[0] = .{ .name = "a" };
    outputs[1] = .{ .name = "b" };

    try ctx.dictionary.put("bad-word", .{
        .name = "bad-word",
        .stack_effect = .{
            .inputs = &[_]StackEffectParam{},
            .outputs = outputs,
        },
        .action = .{ .compound = empty_instrs },
    });

    // Call bad-word then push a value so bad-word is NOT in tail position
    // (tail position skips post-validation as a known TCO limitation)
    const call_instrs = try alloc.alloc(Instruction, 2);
    call_instrs[0] = .{ .op = .{ .call_word = "bad-word" }, .line = 1 };
    call_instrs[1] = .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 2 };

    const result = ctx.executeQuotation(.{ .instructions = call_instrs });
    try std.testing.expectError(primitives.InterpreterError.StackEffectMismatch, result);
}

test "stack effect validation passes for combinator calling quotation" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // if ( ? true-quot false-quot -- ) calls a quotation
    // Both branches must have matching deltas for row var validation
    const alloc = ctx.quotationAllocator();
    const instrs = try alloc.alloc(Instruction, 4);
    instrs[0] = .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 42 } }, .line = 0 },
    } } } }, .line = 2 };
    instrs[2] = .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 0 },
    } } } }, .line = 3 };
    instrs[3] = .{ .op = .{ .call_word = "if" }, .line = 4 };

    try ctx.executeQuotation(.{ .instructions = instrs });
    // if consumed 3, quotation produced 1, so stack has 1
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
}

test "quotation with correct declared effect passes" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Create a quotation with effect ( n -- n ) that actually preserves stack depth
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    };

    // [ ( n -- n ) dup drop ] - takes 1, produces 1 (correct)
    const alloc = ctx.quotationAllocator();
    const dup_drop_instrs = try alloc.alloc(Instruction, 2);
    dup_drop_instrs[0] = .{ .op = .{ .call_word = "dup" }, .line = 1 };
    dup_drop_instrs[1] = .{ .op = .{ .call_word = "drop" }, .line = 1 };

    const quot = Quotation{
        .instructions = dup_drop_instrs,
        .effect = &effect,
    };

    // Push initial value and execute
    try ctx.stack.push(.{ .fixnum = 42 });
    try ctx.executeQuotation(quot);

    // Should have 1 value on stack
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
}

test "quotation with incorrect declared effect fails" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Create a quotation with effect ( n -- n ) but actually does dup (adds 1)
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    };

    // [ ( n -- n ) dup ] - claims (1 in, 1 out) but actually (1 in, 2 out)
    const alloc = ctx.quotationAllocator();
    const dup_instrs = try alloc.alloc(Instruction, 1);
    dup_instrs[0] = .{ .op = .{ .call_word = "dup" }, .line = 1 };

    const quot = Quotation{
        .instructions = dup_instrs,
        .effect = &effect,
    };

    // Push initial value and execute
    try ctx.stack.push(.{ .fixnum = 42 });
    const result = ctx.executeQuotation(quot);

    // Should fail with StackEffectMismatch
    try std.testing.expectError(primitives.InterpreterError.StackEffectMismatch, result);
}

// =============================================================================
// Type registry frame tests
// =============================================================================

test "type registry frame push/pop with lookup visibility" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const alloc = ctx.arena.allocator();
    const desc = try value_mod.createBuiltinTypeDescriptor(alloc, .{});
    try ctx.registerTypeDescriptor("test-type", desc);

    // Visible through base frame
    try std.testing.expect(ctx.lookupTypeDescriptor("test-type") != null);

    // Push a new frame, register in it
    try ctx.pushTypeRegistryFrame();
    const desc2 = try value_mod.createBuiltinTypeDescriptor(alloc, .{});
    try ctx.registerTypeDescriptor("inner-type", desc2);

    try std.testing.expect(ctx.lookupTypeDescriptor("inner-type") != null);
    try std.testing.expect(ctx.lookupTypeDescriptor("test-type") != null);

    // Pop the frame; inner-type should vanish
    ctx.popTypeRegistryFrame();
    try std.testing.expect(ctx.lookupTypeDescriptor("inner-type") == null);
    try std.testing.expect(ctx.lookupTypeDescriptor("test-type") != null);
}

test "type registry frame shadowing" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const alloc = ctx.arena.allocator();

    // Register in base frame; use `mutable` as a distinguishing marker.
    const desc1 = try value_mod.createBuiltinTypeDescriptor(alloc, .{ .mutable = false });
    try ctx.registerTypeDescriptor("shadowed", desc1);

    // Push a frame and shadow the same name
    try ctx.pushTypeRegistryFrame();
    const desc2 = try value_mod.createBuiltinTypeDescriptor(alloc, .{ .mutable = true });
    try ctx.registerTypeDescriptor("shadowed", desc2);

    // Inner wins
    const found = ctx.lookupTypeDescriptor("shadowed").?;
    try std.testing.expect(found.mutable);

    // Pop; outer visible again
    ctx.popTypeRegistryFrame();
    const found2 = ctx.lookupTypeDescriptor("shadowed").?;
    try std.testing.expect(!found2.mutable);
}

test "parameterized type descriptor interning reuses descriptor for same key" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const array_tv = ctx.lookupBuiltinTypeValue("array").?;
    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;

    const desc1 = try ctx.getOrCreateParameterizedTypeDescriptor(array_tv, fixnum_tv);
    const desc2 = try ctx.getOrCreateParameterizedTypeDescriptor(array_tv, fixnum_tv);
    try std.testing.expect(desc1 == desc2);

    const desc3 = try ctx.getOrCreateParameterizedTypeDescriptor(array_tv, string_tv);
    try std.testing.expect(desc1 != desc3);
}

test "struct descriptor interning reuses descriptor for same shape" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fields_xy = [_][]const u8{ "x", "y" };
    const fields_yx = [_][]const u8{ "y", "x" };
    const no_field_types = [_]?*const value_mod.TypeValue{};
    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;
    const typed_fixnum_fixnum = [_]?*const value_mod.TypeValue{ fixnum_tv, fixnum_tv };
    const typed_fixnum_string = [_]?*const value_mod.TypeValue{ fixnum_tv, string_tv };

    const desc1 = try ctx.getOrCreateStructDescriptor(&fields_xy, &no_field_types, false);
    const desc2 = try ctx.getOrCreateStructDescriptor(&fields_xy, &no_field_types, false);
    try std.testing.expect(desc1 == desc2);

    const desc3 = try ctx.getOrCreateStructDescriptor(&fields_yx, &no_field_types, false);
    try std.testing.expect(desc1 != desc3);

    const desc4 = try ctx.getOrCreateStructDescriptor(&fields_xy, &no_field_types, true);
    try std.testing.expect(desc1 != desc4);

    const desc5 = try ctx.getOrCreateStructDescriptor(&fields_xy, &typed_fixnum_fixnum, false);
    const desc6 = try ctx.getOrCreateStructDescriptor(&fields_xy, &typed_fixnum_fixnum, false);
    try std.testing.expect(desc5 == desc6);
    try std.testing.expect(desc1 != desc5);

    const desc7 = try ctx.getOrCreateStructDescriptor(&fields_xy, &typed_fixnum_string, false);
    try std.testing.expect(desc5 != desc7);
}

test "anonymous union interning reuses type value for same member set" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;
    const bignum_tv = ctx.lookupBuiltinTypeValue("bignum").?;

    const union1 = try ctx.getOrCreateAnonymousUnionTypeValue(&.{ fixnum_tv, string_tv, bignum_tv });
    const union2 = try ctx.getOrCreateAnonymousUnionTypeValue(&.{ string_tv, bignum_tv, fixnum_tv });
    const union3 = try ctx.getOrCreateAnonymousUnionTypeValue(&.{ string_tv, fixnum_tv, string_tv, bignum_tv });

    try std.testing.expect(union1 == union2);
    try std.testing.expect(union1 == union3);
    try std.testing.expectEqualStrings("bignum|fixnum|string", union1.name);
    try std.testing.expect(union1.member_types != null);
    try std.testing.expectEqual(@as(usize, 3), union1.member_types.?.len);
}

test "createProtocolDescriptor returns stable distinct pointers" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const methods_a = [_]value_mod.Value{.{ .symbol = "cmp" }};
    const methods_b = [_]value_mod.Value{.{ .symbol = "inspect" }};

    const desc1 = try ctx.createProtocolDescriptor("comparable", &methods_a);
    const desc2 = try ctx.createProtocolDescriptor("inspectable", &methods_b);
    try std.testing.expect(desc1 != desc2);

    // Re-defining a protocol with the same name still produces a distinct
    // descriptor; no structural interning by name.
    const desc3 = try ctx.createProtocolDescriptor("comparable", &methods_a);
    try std.testing.expect(desc1 != desc3);
}

test "createProtocolDescriptor populates name and methods" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const methods = [_]value_mod.Value{ .{ .symbol = "cmp" }, .{ .symbol = ">string" } };
    const desc = try ctx.createProtocolDescriptor("ordered-stringable", &methods);

    try std.testing.expectEqualStrings("ordered-stringable", desc.name);
    try std.testing.expectEqual(@as(usize, 2), desc.methods.len);
    try std.testing.expectEqualStrings("cmp", desc.methods[0].symbol);
    try std.testing.expectEqualStrings(">string", desc.methods[1].symbol);
}

test "createProtocolDescriptor assigns monotonic protocol_id" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const methods = [_]value_mod.Value{.{ .symbol = "cmp" }};
    const desc0 = try ctx.createProtocolDescriptor("p0", &methods);
    const desc1 = try ctx.createProtocolDescriptor("p1", &methods);
    const desc2 = try ctx.createProtocolDescriptor("p2", &methods);

    try std.testing.expectEqual(@as(u32, 0), desc0.protocol_id);
    try std.testing.expectEqual(@as(u32, 1), desc1.protocol_id);
    try std.testing.expectEqual(@as(u32, 2), desc2.protocol_id);
}

test "protocol satisfies cache returns stored hits" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;
    const methods = [_]value_mod.Value{.{ .symbol = "cmp" }};
    const desc = try ctx.createProtocolDescriptor("comparable", &methods);

    const key_yes = ProtocolSatisfiesKey{
        .type_descriptor = fixnum_tv.descriptor.?,
        .protocol_descriptor = desc,
    };
    const key_no = ProtocolSatisfiesKey{
        .type_descriptor = string_tv.descriptor.?,
        .protocol_descriptor = desc,
    };

    ctx.storeProtocolSatisfies(key_yes, true);
    ctx.storeProtocolSatisfies(key_no, false);

    try std.testing.expectEqual(@as(?bool, true), ctx.lookupProtocolSatisfies(key_yes));
    try std.testing.expectEqual(@as(?bool, false), ctx.lookupProtocolSatisfies(key_no));
}

test "protocol satisfies cache miss returns null" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const methods = [_]value_mod.Value{.{ .symbol = "cmp" }};
    const desc = try ctx.createProtocolDescriptor("comparable", &methods);

    const key = ProtocolSatisfiesKey{
        .type_descriptor = fixnum_tv.descriptor.?,
        .protocol_descriptor = desc,
    };

    try std.testing.expectEqual(@as(?bool, null), ctx.lookupProtocolSatisfies(key));
}

test "validateTypeAnnotationsScoped except_protocols skips protocol bounds" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const methods = [_]value_mod.Value{.{ .symbol = "no-such-method" }};
    const desc = try ctx.createProtocolDescriptor("needy", &methods);

    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "x", .type_annotation = .{ .protocol = desc } },
        },
        .outputs = &[_]StackEffectParam{.{ .name = "y" }},
    };

    try ctx.stack.push(.{ .fixnum = 42 });

    // `.all` checks the bound; fixnum does not satisfy `needy`, so it raises.
    try std.testing.expectError(error.UserThrown, ctx.validateTypeAnnotationsScoped(&effect, .all));

    // `.except_protocols` skips the bound, so the same input passes.
    try ctx.validateTypeAnnotationsScoped(&effect, .except_protocols);
}

test "validateTypeAnnotationsScoped except_protocols still checks concrete types" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const string_tv = ctx.lookupBuiltinTypeValue("string").?;
    const effect = StackEffect{
        .inputs = &[_]StackEffectParam{
            .{ .name = "x", .type_annotation = .{ .type = string_tv } },
        },
        .outputs = &[_]StackEffectParam{.{ .name = "y" }},
    };

    try ctx.stack.push(.{ .fixnum = 42 });

    // Concrete-type annotations are still validated under `.except_protocols`.
    try std.testing.expectError(error.TypeError, ctx.validateTypeAnnotationsScoped(&effect, .except_protocols));
}

test "protocol satisfies cache invalidated by method registration" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const methods = [_]value_mod.Value{.{ .symbol = "cmp" }};
    const desc = try ctx.createProtocolDescriptor("comparable", &methods);

    const key = ProtocolSatisfiesKey{
        .type_descriptor = fixnum_tv.descriptor.?,
        .protocol_descriptor = desc,
    };
    ctx.storeProtocolSatisfies(key, true);
    try std.testing.expectEqual(@as(?bool, true), ctx.lookupProtocolSatisfies(key));

    const body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 0 }};
    try ctx.registerDispatch(
        .{ .dispatch_id = 7777, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = body } },
        false,
    );

    try std.testing.expectEqual(@as(?bool, null), ctx.lookupProtocolSatisfies(key));
}

test "protocol satisfies cache invalidated by dispatch frame pop" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const methods = [_]value_mod.Value{.{ .symbol = "cmp" }};
    const desc = try ctx.createProtocolDescriptor("comparable", &methods);

    const key = ProtocolSatisfiesKey{
        .type_descriptor = fixnum_tv.descriptor.?,
        .protocol_descriptor = desc,
    };

    try ctx.pushDispatchFrame();
    ctx.storeProtocolSatisfies(key, true);
    try std.testing.expectEqual(@as(?bool, true), ctx.lookupProtocolSatisfies(key));

    ctx.popDispatchFrame();
    try std.testing.expectEqual(@as(?bool, null), ctx.lookupProtocolSatisfies(key));
}

test "anonymous union descriptor flags are inferred by intersection" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const bignum_tv = ctx.lookupBuiltinTypeValue("bignum").?;
    const float_tv = ctx.lookupBuiltinTypeValue("float").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;

    const numeric_union = try ctx.getOrCreateAnonymousUnionTypeValue(&.{ fixnum_tv, bignum_tv, float_tv });
    const mixed_union = try ctx.getOrCreateAnonymousUnionTypeValue(&.{ fixnum_tv, string_tv });

    const numeric_desc = numeric_union.descriptor.?;
    try std.testing.expect(numeric_desc.numeric);
    try std.testing.expect(!numeric_desc.exact);
    try std.testing.expect(!numeric_desc.integer);

    const mixed_desc = mixed_union.descriptor.?;
    try std.testing.expect(!mixed_desc.numeric);
    try std.testing.expect(!mixed_desc.exact);
    try std.testing.expect(!mixed_desc.integer);
}

test "enum registry frame push/pop" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const alloc = ctx.arena.allocator();
    const color_tv = try alloc.create(value_mod.TypeValue);
    color_tv.* = .{ .name = "color:", .descriptor = null };
    const vt = try alloc.create(value_mod.VirtualType);
    vt.* = .{ .name = "red", .inner_type = "symbol" };
    const variants: []const *const value_mod.VirtualType = &.{vt};
    try ctx.registerEnumVariants(color_tv, variants);

    try std.testing.expect(ctx.lookupEnumVariants(color_tv) != null);

    try ctx.pushTypeRegistryFrame();
    const size_tv = try alloc.create(value_mod.TypeValue);
    size_tv.* = .{ .name = "size:", .descriptor = null };
    const vt2 = try alloc.create(value_mod.VirtualType);
    vt2.* = .{ .name = "small", .inner_type = "symbol" };
    const variants2: []const *const value_mod.VirtualType = &.{vt2};
    try ctx.registerEnumVariants(size_tv, variants2);

    try std.testing.expect(ctx.lookupEnumVariants(size_tv) != null);
    try std.testing.expect(ctx.lookupEnumVariants(color_tv) != null);

    ctx.popTypeRegistryFrame();
    try std.testing.expect(ctx.lookupEnumVariants(size_tv) == null);
    try std.testing.expect(ctx.lookupEnumVariants(color_tv) != null);
}

// =============================================================================
// Dispatch frame tests
// =============================================================================

test "dispatch frame push/pop with lookup visibility" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;
    const did: u32 = 1000;

    const body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 42 } }, .line = 0 }};

    // Register in base dispatch table
    try ctx.dispatch.register(
        .{ .dispatch_id = did, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = body } },
        false,
    );

    try std.testing.expect(ctx.lookupUnaryDispatch(did, fixnum_tv.descriptor.?) != null);

    // Push a frame and register a new entry
    try ctx.pushDispatchFrame();
    const body2 = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 99 } }, .line = 0 }};
    try ctx.registerDispatch(
        .{ .dispatch_id = did, .type_a = string_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = body2 } },
        false,
    );

    try std.testing.expect(ctx.lookupUnaryDispatch(did, string_tv.descriptor.?) != null);
    try std.testing.expect(ctx.lookupUnaryDispatch(did, fixnum_tv.descriptor.?) != null);

    // Pop; string entry should vanish
    ctx.popDispatchFrame();
    try std.testing.expect(ctx.lookupUnaryDispatch(did, string_tv.descriptor.?) == null);
    try std.testing.expect(ctx.lookupUnaryDispatch(did, fixnum_tv.descriptor.?) != null);
}

test "dispatch frame shadowing" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const duration_desc = try value_mod.createBuiltinTypeDescriptor(std.testing.allocator, .{});
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, duration_desc);
    const duration_tv = value_mod.TypeValue{ .name = "duration", .descriptor = duration_desc };
    const did: u32 = 1001;

    const body1 = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 }};
    const body2 = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 0 }};

    // Register in base table
    try ctx.dispatch.register(
        .{ .dispatch_id = did, .type_a = duration_tv.descriptor.?, .type_b = duration_tv.descriptor.? },
        .{ .body = .{ .quotation = body1 } },
        false,
    );

    // Push frame and shadow
    try ctx.pushDispatchFrame();
    try ctx.registerDispatch(
        .{ .dispatch_id = did, .type_a = duration_tv.descriptor.?, .type_b = duration_tv.descriptor.? },
        .{ .body = .{ .quotation = body2 } },
        false,
    );

    // Inner should win
    const entry = ctx.lookupBinaryDispatch(did, duration_tv.descriptor.?, duration_tv.descriptor.?).?;
    try std.testing.expectEqual(@as(i64, 2), entry.body.quotation[0].op.push_literal.fixnum);

    // Pop; outer visible again
    ctx.popDispatchFrame();
    const entry2 = ctx.lookupBinaryDispatch(did, duration_tv.descriptor.?, duration_tv.descriptor.?).?;
    try std.testing.expectEqual(@as(i64, 1), entry2.body.quotation[0].op.push_literal.fixnum);
}

test "dispatch generation bumped on frame pop" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const gen_before = ctx.dispatch.generation;
    try ctx.pushDispatchFrame();
    ctx.popDispatchFrame();
    try std.testing.expect(ctx.dispatch.generation > gen_before);
}

test "base behavior with no extra frames matches original" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;

    // No extra frames pushed, so registerDispatch goes to base dispatch table
    const did: u32 = 1002;
    const body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 0 }};
    try ctx.registerDispatch(
        .{ .dispatch_id = did, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = body } },
        false,
    );

    // Should be findable via both the new API and the raw dispatch table
    try std.testing.expect(ctx.lookupUnaryDispatch(did, fixnum_tv.descriptor.?) != null);
    try std.testing.expect(ctx.dispatch.lookupUnary(did, fixnum_tv.descriptor.?, ctx.getDispatchAnySentinel().descriptor.?, ctx.getDispatchUnarySentinel().descriptor.?) != null);
}

test "initBuiltinTypeValues populates all array slots" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    for (ctx.builtin_type_array) |slot| {
        try std.testing.expect(slot != null);
    }
}

test "initBuiltinTypeValues names match builtinTypeName" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const num_variants = comptime @typeInfo(value_mod.Value).@"union".fields.len;
    inline for (0..num_variants) |i| {
        const tag: std.meta.Tag(value_mod.Value) = @enumFromInt(i);
        const expected = dispatch_mod.builtinTypeName(tag);
        const tv = ctx.builtin_type_array[i].?;
        try std.testing.expectEqualStrings(expected, tv.name);
    }
}

test "lookupBuiltinTypeValueByTag returns same pointer as name lookup" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const num_variants = comptime @typeInfo(value_mod.Value).@"union".fields.len;
    inline for (0..num_variants) |i| {
        const tag: std.meta.Tag(value_mod.Value) = @enumFromInt(i);
        const by_tag = ctx.lookupBuiltinTypeValueByTag(tag);
        const by_name = ctx.lookupBuiltinTypeValue(dispatch_mod.builtinTypeName(tag));
        try std.testing.expect(by_tag != null);
        try std.testing.expect(by_name != null);
        try std.testing.expect(by_tag.? == by_name.?);
    }
}

test "initBuiltinTypeValues creates TypeValues with normalized descriptors" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const tv = ctx.lookupBuiltinTypeValue("fixnum");
    try std.testing.expect(tv != null);
    const desc = tv.?.descriptor orelse unreachable;
    try std.testing.expect(desc.kind == .builtin);
    try std.testing.expect(desc.numeric);
    try std.testing.expect(desc.exact);
    try std.testing.expect(desc.integer);
    try std.testing.expect(!desc.mutable);
}

test "preResolveCallTarget: returns slot for dictionary-only name" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;
    try ctx.dictionary.put("dict-only", .{ .name = "dict-only", .action = .{ .native = noop } });

    const slot = ctx.preResolveCallTarget("dict-only");
    try std.testing.expect(slot != null);
    try std.testing.expectEqual(ctx.dictionary.getSlot("dict-only").?, slot.?);
}

test "preResolveCallTarget: returns null for unknown name" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(?*dict_mod.WordSlot, null), ctx.preResolveCallTarget("never-defined"));
}

test "preResolveCallTarget: returns null when shadowed by a local frame" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;
    try ctx.dictionary.put("shadowed", .{ .name = "shadowed", .action = .{ .native = noop } });

    try ctx.pushLocalFrame();
    const top_idx = ctx.local_frames.items.len - 1;
    try ctx.local_frames.items[top_idx].put(ctx.allocator, "shadowed", .{
        .name = "shadowed",
        .action = .{ .native = noop },
    });

    try std.testing.expectEqual(@as(?*dict_mod.WordSlot, null), ctx.preResolveCallTarget("shadowed"));
}

test "preResolveCallTarget: returns null when a loaded module exposes the name in words" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;
    try ctx.dictionary.put("module-claimed", .{ .name = "module-claimed", .action = .{ .native = noop } });

    const arena_alloc = ctx.arena.allocator();
    const module = try arena_alloc.create(value_mod.Module);
    module.* = .{ .name = "fake-words", .words = .{} };
    try module.words.put(arena_alloc, "module-claimed", .{ .action = .{ .native = noop } });

    const cache_alloc = ctx.module_cache_value.header.allocator;
    try ctx.module_cache_value.map.put(
        cache_alloc,
        try cache_alloc.dupe(u8, "fake-words"),
        .{ .module = module },
    );

    try std.testing.expectEqual(@as(?*dict_mod.WordSlot, null), ctx.preResolveCallTarget("module-claimed"));
}

test "preResolveCallTarget: returns null when a loaded module carries the name as a dep" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;
    try ctx.dictionary.put("dep-claimed", .{ .name = "dep-claimed", .action = .{ .native = noop } });

    const arena_alloc = ctx.arena.allocator();
    const module = try arena_alloc.create(value_mod.Module);
    module.* = .{ .name = "fake-deps", .words = .{} };
    try module.deps.put(arena_alloc, "dep-claimed", .{ .action = .{ .native = noop } });

    const cache_alloc = ctx.module_cache_value.header.allocator;
    try ctx.module_cache_value.map.put(
        cache_alloc,
        try cache_alloc.dupe(u8, "fake-deps"),
        .{ .module = module },
    );

    try std.testing.expectEqual(@as(?*dict_mod.WordSlot, null), ctx.preResolveCallTarget("dep-claimed"));
}

test "lookupWordForExecution: finds a module-cache words entry on dictionary miss when an image is loaded" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const push77: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 77 });
        }
    }.f;

    const arena_alloc = ctx.arena.allocator();
    const module = try arena_alloc.create(value_mod.Module);
    module.* = .{ .name = "fake-runtime-image", .words = .{} };
    try module.words.put(arena_alloc, "(private-default)", .{
        .source_module = module,
        .action = .{ .native = push77 },
    });

    const cache_alloc = ctx.module_cache_value.header.allocator;
    try ctx.module_cache_value.map.put(
        cache_alloc,
        try cache_alloc.dupe(u8, "fake-runtime-image"),
        .{ .module = module },
    );

    // Stand in for `aot_image_loader.loadIntoContext`.
    ctx.runtime_image_loaded = true;

    // The strict in-context lookup must not see the cached module.
    try std.testing.expectEqual(@as(?WordDefinition, null), ctx.lookupWord("(private-default)"));

    // The execution-time lookup falls through to the module cache.
    const found = ctx.lookupWordForExecution("(private-default)") orelse return error.TestExpectedLookup;
    try std.testing.expectEqual(module, found.source_module.?);

    const instrs = try arena_alloc.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .call_word = "(private-default)" }, .line = 1 };
    try ctx.executeQuotation(.{ .instructions = instrs });

    const value = try ctx.stack.pop();
    try std.testing.expectEqual(@as(i64, 77), value.fixnum);
}

test "lookupWordForExecution: stays inert without a loaded runtime image" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    const arena_alloc = ctx.arena.allocator();
    const module = try arena_alloc.create(value_mod.Module);
    module.* = .{ .name = "load-time-module", .words = .{} };
    try module.words.put(arena_alloc, "exported-only", .{
        .source_module = module,
        .action = .{ .native = noop },
    });

    const cache_alloc = ctx.module_cache_value.header.allocator;
    try ctx.module_cache_value.map.put(
        cache_alloc,
        try cache_alloc.dupe(u8, "load-time-module"),
        .{ .module = module },
    );

    // No image has been loaded, so the fallback must not reach into another module's
    // words. Otherwise normal `load`/`use` sessions lose their privacy boundary.
    try std.testing.expectEqual(@as(?WordDefinition, null), ctx.lookupWordForExecution("exported-only"));
}

test "lookupWordForExecution: does not leak module deps across modules" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    const arena_alloc = ctx.arena.allocator();
    const dep_module = try arena_alloc.create(value_mod.Module);
    dep_module.* = .{ .name = "dep-source", .words = .{} };

    const module = try arena_alloc.create(value_mod.Module);
    module.* = .{ .name = "dep-holder", .words = .{} };
    try module.deps.put(arena_alloc, "dep-only", .{
        .source_module = dep_module,
        .action = .{ .native = noop },
    });

    const cache_alloc = ctx.module_cache_value.header.allocator;
    try ctx.module_cache_value.map.put(
        cache_alloc,
        try cache_alloc.dupe(u8, "dep-holder"),
        .{ .module = module },
    );

    // Even with an image-loaded gate flipped on, a name living only in another
    // module's `deps` is private to that module and must not be visible.
    ctx.runtime_image_loaded = true;
    try std.testing.expectEqual(@as(?WordDefinition, null), ctx.lookupWordForExecution("dep-only"));
}

test "lookupWordForExecution: walks parent jit_dispatch for AOT-compiled-only words" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    // The fallback is gated on runtime_image_loaded: the AOT runtime sets
    // this flag at startup, and interpreter sessions leave it false so that
    // a library-private word promoted to JIT can't leak across module
    // boundaries via a name sweep of jit_dispatch.
    parent.runtime_image_loaded = true;

    // Register a fake AOT-compiled word in the parent's jit_dispatch. The
    // code_ptr is non-null so the entry is considered live; we never invoke
    // it in this test (we only check that the lookup synthesizes a
    // WordDefinition with the correct word_id).
    const fake_code: *const anyopaque = @ptrCast(&fakeAotCodeMarker);
    const wid = try parent.jit_dispatch.assignId("ghost-word");
    parent.jit_dispatch.setCodePtr(wid, fake_code);

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();

    // Strict in-context lookup must not find it (no dictionary entry exists
    // anywhere in the chain).
    try std.testing.expectEqual(@as(?WordDefinition, null), task_ctx.lookupWord("ghost-word"));

    // Execution-time lookup falls through to the jit_dispatch sweep across
    // the parent chain.
    const found = task_ctx.lookupWordForExecution("ghost-word") orelse return error.TestExpectedLookup;
    try std.testing.expectEqual(@as(?u32, wid), found.word_id);
    try std.testing.expectEqualStrings("ghost-word", found.name);
}

var fakeAotCodeMarker: u8 = 0;

test "initForTask: inherits AOT runtime-image state from parent" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    // Mark the parent as having an image loaded with bogus-but-non-null
    // slot tables and counts. The task should inherit each field verbatim
    // so compiled bodies in spawned tasks can resolve image-backed literals.
    parent.runtime_image_loaded = true;
    parent.image_typevalue_slot_count = 7;
    parent.image_parameter_slot_count = 3;

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();

    try std.testing.expectEqual(true, task_ctx.runtime_image_loaded);
    try std.testing.expectEqual(@as(u32, 7), task_ctx.image_typevalue_slot_count);
    try std.testing.expectEqual(@as(u32, 3), task_ctx.image_parameter_slot_count);
}
