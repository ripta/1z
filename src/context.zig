const std = @import("std");
const Allocator = std.mem.Allocator;

const Stack = @import("stack.zig").Stack;
const Dictionary = @import("dictionary.zig").Dictionary;

const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const Quotation = value_mod.Quotation;
const Value = value_mod.Value;

const debugger_mod = @import("debugger/mod.zig");

const dispatch_helpers = @import("primitives/dispatch_helpers.zig");

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
const Scheduler = @import("scheduler.zig").Scheduler;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const types_mod = @import("primitives/types.zig");
const Capability = types_mod.Capability;
const SandboxSpec = types_mod.SandboxSpec;
const primitives = @import("primitives.zig");
const parser = @import("parser.zig");
const BenchmarkStats = @import("benchmark.zig").BenchmarkStats;
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

/// Embedded prelude source code
const prelude_source = @embedFile("prelude.1z");

pub const CompileMode = enum { off, eager, hybrid };

pub const ExecutionError = error{
    UnknownWord,
    StackUnderflow,
    OutOfMemory,
};

/// CallFrame represents a single frame in the call stack.
pub const CallFrame = struct {
    word_name: []const u8,
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
    type_descriptors: std.StringHashMapUnmanaged(*value_mod.HashTable) = .{},
    enum_registry: std.StringHashMapUnmanaged([]const *const value_mod.VirtualType) = .{},

    pub fn deinit(self: *TypeRegistryFrame, allocator: Allocator) void {
        self.type_descriptors.deinit(allocator);
        self.enum_registry.deinit(allocator);
    }
};

pub const ParameterizedTypeKey = struct {
    base: *const value_mod.TypeValue,
    element: *const value_mod.TypeValue,
};

pub const StructDescriptorKey = struct {
    fields: []const []const u8,
    field_types: []const ?*const value_mod.TypeValue = &.{},
    mutable: bool,
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

/// A deferred protocol obligation recorded during module loading.
/// Validated after all definitions in the module have been processed.
pub const ProtocolObligation = struct {
    type_name: []const u8,
    methods_array: []const Value,
    protocol_name: []const u8,
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

/// The Context holds all interpreter state.
pub const Context = struct {
    stack: Stack,
    dictionary: Dictionary,
    arena: std.heap.ArenaAllocator,
    /// Shared arena for mutable container backing storage. Owned by the root
    /// context and shared by pointer to all child task contexts so that
    /// container allocations outlive any individual task's arena.
    container_arena: *std.heap.ArenaAllocator,
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
    /// Directory of the currently executing source file for relative path resolution
    current_source_dir: ?[]const u8 = null,
    /// User-configured load paths for search-mode module resolution
    load_paths: std.ArrayListUnmanaged([]const u8) = .{},
    /// Standard library path, which is resolved last
    stdlib_path: ?[]const u8 = null,
    /// Program arguments passed after the file path on the command line
    program_args: []const []const u8 = &.{},
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
    /// Cache of loaded modules keyed by canonical file path.
    /// Prevents redundant loading when multiple files `use` the same module.
    /// Stored as an M{} value so it can be exposed as a dynamic parameter.
    module_cache_value: *value_mod.MutableMap = undefined,
    /// Stashed error object from user `throw`, consumed by `recover`.
    thrown_error: ?value_mod.ErrorObject = null,
    /// Parse-time error diagnostics, populated by the parser catch blocks
    /// and consumed by the display sites in main.zig.
    parse_diagnostics: ?ParseDiagnostics = null,
    /// Pending error message set by primitives before returning an error.
    /// Used by captureCallStackOnError for the innermost frame's message.
    pending_error_message: ?[]const u8 = null,
    /// Pending error hint set by primitives before returning an error.
    /// Consumed by captureCallStackOnError for the innermost frame's hint.
    pending_error_hint: ?[]const u8 = null,
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
    /// Dispatch table for user-defined operator/method dispatch.
    dispatch: DispatchTable,
    /// JIT dispatch table mapping word IDs to compiled code pointers.
    jit_dispatch: JitDispatchTable,
    /// Pending error from a JIT error-handling callback (recover/cleanup).
    /// Set by the callback when it returns error_propagate status, consumed
    /// by the interpreter dispatch loop.
    jit_pending_error: ?anyerror = null,
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
    /// test-timeout watchdog thread.
    active_scheduler: std.atomic.Value(?*Scheduler) = std.atomic.Value(?*Scheduler).init(null),
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
        *value_mod.HashTable,
        ParameterizedTypeKeyContext,
        80,
    ) = .{},
    /// Interned descriptors for bare structs, keyde by ordered field names and by mutability.
    struct_descriptors: std.HashMapUnmanaged(
        StructDescriptorKey,
        *value_mod.HashTable,
        StructDescriptorKeyContext,
        80,
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

        const dispatch_any_desc: *value_mod.HashTable = @ptrCast(try value_mod.createSentinelTypeDescriptor(alloc));
        const dispatch_any = try alloc.create(value_mod.TypeValue);
        dispatch_any.* = .{ .name = "*", .descriptor = dispatch_any_desc };
        self.dispatch_any_sentinel = dispatch_any;

        const dispatch_unary_desc: *value_mod.HashTable = @ptrCast(try value_mod.createSentinelTypeDescriptor(alloc));
        const dispatch_unary = try alloc.create(value_mod.TypeValue);
        dispatch_unary.* = .{ .name = "", .descriptor = dispatch_unary_desc };
        self.dispatch_unary_sentinel = dispatch_unary;

        const type_sentinel_desc: *value_mod.HashTable = @ptrCast(try value_mod.createSentinelTypeDescriptor(alloc));

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
            const desc: *value_mod.HashTable = @ptrCast(try value_mod.createBuiltinTypeDescriptor(
                alloc,
                builtinDescriptorFlags(tag),
            ));

            const tv = try alloc.create(value_mod.TypeValue);
            tv.* = .{ .name = name, .descriptor = desc };

            self.builtin_type_array[i] = tv;
            try self.builtin_type_values.put(self.allocator, name, tv);
        }
    }

    /// Initialize a new interpreter context with an empty stack and primitives.
    /// Note: This does NOT load the prelude. Call loadPrelude() separately.
    pub fn init(allocator: Allocator) Context {
        const ca = allocator.create(std.heap.ArenaAllocator) catch |err| {
            std.debug.panic("Failed to allocate container arena: {any}", .{err});
        };
        ca.* = std.heap.ArenaAllocator.init(allocator);

        var ctx = Context{
            .stack = Stack.init(allocator),
            .dictionary = Dictionary.init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
            .container_arena = ca,
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

        // Allocate the module cache M{} on the arena.
        ctx.module_cache_value = ctx.arena.allocator().create(value_mod.MutableMap) catch |err| {
            std.debug.panic("Failed to allocate module cache: {any}", .{err});
        };
        ctx.module_cache_value.* = .{};

        // Allocate the shared hook registry on the container arena.
        ctx.hook_registry = ca.allocator().create(HookRegistry) catch |err| {
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

        primitives.registerPrimitives(&ctx.dictionary, ctx.arena.allocator()) catch |err| {
            std.debug.panic("Failed to register primitives: {any}", .{err});
        };

        primitives.createNativeModule(&ctx.dictionary, ctx.arena.allocator()) catch |err| {
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
            .container_arena = parent.container_arena,
            .allocator = allocator,
            .call_stack = .{},
            .error_details = .{},
            .parameter_env = .{},
            .local_frames = .{},
            .dispatch = DispatchTable.init(allocator),
            .jit_dispatch = JitDispatchTable.init(allocator),
            .scheduler = scheduler,
            .parent_context = parent,

            .trace = parent.trace,
            .deadlock_detect_ns = parent.deadlock_detect_ns,
            .current_source = parent.current_source,
            .current_source_dir = parent.current_source_dir,
            .load_paths = parent.load_paths,
            .stdlib_path = parent.stdlib_path,
            .program_args = parent.program_args,
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
        while (lines.next()) |line| {
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
            frame.deinit(self.allocator);
        }
        self.parameter_env.deinit(self.allocator);
        for (self.local_frames.items) |*frame| {
            frame.deinit(self.allocator);
        }
        self.local_frames.deinit(self.allocator);
        self.call_stack.deinit(self.allocator);
        self.error_details.deinit(self.allocator);
        self.load_paths.deinit(self.allocator);
        for (self.pragma_frames.items) |*frame| {
            frame.deinit(self.allocator);
        }
        self.pragma_frames.deinit(self.allocator);
        self.pragma_registry.deinit(self.allocator);
        self.parse_time_deferred_calls.deinit(self.allocator);
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
        self.dispatch.deinit();
        self.jit_dispatch.deinit();
        var pic_iter = self.pic_cache.iterator();
        while (pic_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.pic_cache.deinit(self.allocator);
        self.arena.deinit();
        if (self.parent_context == null) {
            self.allocator.destroy(self.lock_order_tracker);
            self.allocator.destroy(self.shared_lock);
            self.container_arena.deinit();
            self.allocator.destroy(self.container_arena);
        }
        self.dictionary.deinit();
        self.stack.deinit();
    }

    /// Allocator for quotations and other parsed data.
    pub fn quotationAllocator(self: *Context) Allocator {
        return self.arena.allocator();
    }

    /// Allocator for mutable container backing storage. Shared across all
    /// task contexts so that container data outlives any individual task's arena.
    pub fn containerAllocator(self: *Context) Allocator {
        return self.container_arena.allocator();
    }

    /// Clear all error details and call stack.
    pub fn clearExecutionDetails(self: *Context) void {
        self.error_details.clearRetainingCapacity();
        self.call_stack.clearRetainingCapacity();
        self.pending_error_message = null;
        self.pending_error_hint = null;
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

    /// Pop the top parameter frame from the environment stack.
    pub fn popParameterFrame(self: *Context) void {
        if (self.parameter_env.items.len > 0) {
            const last_idx = self.parameter_env.items.len - 1;
            self.parameter_env.items[last_idx].deinit(self.allocator);
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
        try self.parameter_env.items[top_index].put(self.allocator, name, value);
    }

    // =========================================================================
    // Local frame methods (lexical scoping for quotation-local definitions)
    // =========================================================================

    /// Push a new empty local frame onto the frame stack.
    pub fn pushLocalFrame(self: *Context) !void {
        try self.local_frames.append(self.allocator, LocalFrame{});
    }

    /// Pop the top local frame from the frame stack.
    pub fn popLocalFrame(self: *Context) void {
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
        try self.pushLocalFrame();
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
                .action = switch (entry.value_ptr.*.action) {
                    .compound => |instrs| .{ .compound = instrs },
                    .native => |func| .{ .native = func },
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
                .action = switch (entry.value_ptr.*.action) {
                    .compound => |instrs| .{ .compound = instrs },
                    .native => |func| .{ .native = func },
                },
            });
        }

        if (self.trace.trace_modules) {
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
    }

    /// Attempt JIT compilation of a newly defined word. Silently ignores
    /// all errors so the word falls back to the interpreter.
    fn tryAutoCompile(self: *Context, name: []const u8, def: WordDefinition) void {
        const instrs = switch (def.action) {
            .compound => |i| i,
            .native => return,
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

        const compiled = ir_codegen.compileWord(instrs, input_count, output_count, resolver, name, self, null) catch return;

        const final_id = if (def.word_id) |existing_id| blk: {
            if (self.jit_dispatch.get(existing_id) != null) {
                self.jit_dispatch.update(existing_id, compiled.code_ptr, compiled.jit_buf);
                break :blk existing_id;
            }
            const new_id = self.jit_dispatch.assignId(name) catch {
                compiled.jit_buf.deinit();
                return;
            };
            self.jit_dispatch.update(new_id, compiled.code_ptr, compiled.jit_buf);
            propagateWordId(self, name, new_id);
            break :blk new_id;
        } else blk: {
            const new_id = self.jit_dispatch.assignId(name) catch {
                compiled.jit_buf.deinit();
                return;
            };
            self.jit_dispatch.update(new_id, compiled.code_ptr, compiled.jit_buf);
            propagateWordId(self, name, new_id);
            break :blk new_id;
        };

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
            .native => return,
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
    /// 1. local frames from innermost (topmost) to outermost (bottommost);
    /// 2. the global dictionary of the current context;
    /// 3. the parent dictionary if this is a task context that inherits from a parent.
    pub fn lookupWord(self: *const Context, name: []const u8) ?WordDefinition {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupWordLocked(name);
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
    pub fn lookupBinaryDispatch(self: *const Context, word_name: []const u8, type_a: *const value_mod.HashTable, type_b: *const value_mod.HashTable) ?DispatchEntry {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupBinaryDispatchLocked(word_name, type_a, type_b);
    }

    fn lookupBinaryDispatchLocked(self: *const Context, word_name: []const u8, type_a: *const value_mod.HashTable, type_b: *const value_mod.HashTable) ?DispatchEntry {
        const any_sentinel = self.getDispatchAnySentinel().descriptor.?;
        // Walk dispatch frames top-to-bottom
        var i = self.dispatch_frames.items.len;
        while (i > 0) {
            i -= 1;
            if (dispatch_mod.lookupBinaryInEntries(&self.dispatch_frames.items[i].entries, word_name, type_a, type_b, any_sentinel)) |entry| return entry;
        }
        // Base dispatch table
        if (self.dispatch.lookupBinary(word_name, type_a, type_b, any_sentinel)) |entry| return entry;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            var j = ctx.dispatch_frames.items.len;
            while (j > 0) {
                j -= 1;
                if (dispatch_mod.lookupBinaryInEntries(&ctx.dispatch_frames.items[j].entries, word_name, type_a, type_b, ctx.getDispatchAnySentinel().descriptor.?)) |entry| return entry;
            }
            if (ctx.dispatch.lookupBinary(word_name, type_a, type_b, ctx.getDispatchAnySentinel().descriptor.?)) |entry| return entry;
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Look up a unary dispatch entry by walking dispatch frames (top to
    /// bottom), then the base dispatch table, then the parent context chain.
    pub fn lookupUnaryDispatch(self: *const Context, word_name: []const u8, type_a: *const value_mod.HashTable) ?DispatchEntry {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupUnaryDispatchLocked(word_name, type_a);
    }

    fn lookupUnaryDispatchLocked(self: *const Context, word_name: []const u8, type_a: *const value_mod.HashTable) ?DispatchEntry {
        const any_sentinel = self.getDispatchAnySentinel().descriptor.?;
        const unary_sentinel = self.getDispatchUnarySentinel().descriptor.?;
        // Walk dispatch frames top-to-bottom
        var i = self.dispatch_frames.items.len;
        while (i > 0) {
            i -= 1;
            if (dispatch_mod.lookupUnaryInEntries(&self.dispatch_frames.items[i].entries, word_name, type_a, any_sentinel, unary_sentinel)) |entry| return entry;
        }
        // Base dispatch table
        if (self.dispatch.lookupUnary(word_name, type_a, any_sentinel, unary_sentinel)) |entry| return entry;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            var j = ctx.dispatch_frames.items.len;
            while (j > 0) {
                j -= 1;
                if (dispatch_mod.lookupUnaryInEntries(&ctx.dispatch_frames.items[j].entries, word_name, type_a, ctx.getDispatchAnySentinel().descriptor.?, ctx.getDispatchUnarySentinel().descriptor.?)) |entry| return entry;
            }
            if (ctx.dispatch.lookupUnary(word_name, type_a, ctx.getDispatchAnySentinel().descriptor.?, ctx.getDispatchUnarySentinel().descriptor.?)) |entry| return entry;
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Look up a binary dispatch entry in the native-only shadow table,
    /// walking the parent context chain.
    pub fn lookupNativeBinaryDispatch(self: *const Context, word_name: []const u8, type_a: *const value_mod.HashTable, type_b: *const value_mod.HashTable) ?DispatchEntry {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupNativeBinaryDispatchLocked(word_name, type_a, type_b);
    }

    fn lookupNativeBinaryDispatchLocked(self: *const Context, word_name: []const u8, type_a: *const value_mod.HashTable, type_b: *const value_mod.HashTable) ?DispatchEntry {
        if (self.dispatch.lookupNativeBinary(word_name, type_a, type_b, self.getDispatchAnySentinel().descriptor.?)) |entry| return entry;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            if (ctx.dispatch.lookupNativeBinary(word_name, type_a, type_b, ctx.getDispatchAnySentinel().descriptor.?)) |entry| return entry;
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Look up a unary dispatch entry in the native-only shadow table,
    /// walking the parent context chain.
    pub fn lookupNativeUnaryDispatch(self: *const Context, word_name: []const u8, type_a: *const value_mod.HashTable) ?DispatchEntry {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupNativeUnaryDispatchLocked(word_name, type_a);
    }

    fn lookupNativeUnaryDispatchLocked(self: *const Context, word_name: []const u8, type_a: *const value_mod.HashTable) ?DispatchEntry {
        if (self.dispatch.lookupNativeUnary(word_name, type_a, self.getDispatchAnySentinel().descriptor.?, self.getDispatchUnarySentinel().descriptor.?)) |entry| return entry;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            if (ctx.dispatch.lookupNativeUnary(word_name, type_a, ctx.getDispatchAnySentinel().descriptor.?, ctx.getDispatchUnarySentinel().descriptor.?)) |entry| return entry;
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Look up enum variant types by enum name, walking type registry frames
    /// (top to bottom), then the parent context chain.
    pub fn lookupEnumVariants(self: *const Context, enum_name: []const u8) ?[]const *const value_mod.VirtualType {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupEnumVariantsLocked(enum_name);
    }

    fn lookupEnumVariantsLocked(self: *const Context, enum_name: []const u8) ?[]const *const value_mod.VirtualType {
        var i = self.type_registry_frames.items.len;
        while (i > 0) {
            i -= 1;
            if (self.type_registry_frames.items[i].enum_registry.get(enum_name)) |variants| return variants;
        }

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            var j = ctx.type_registry_frames.items.len;
            while (j > 0) {
                j -= 1;
                if (ctx.type_registry_frames.items[j].enum_registry.get(enum_name)) |variants| return variants;
            }
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Look up a type descriptor by type name, walking type registry frames
    /// (top to bottom), then the parent context chain.
    pub fn lookupTypeDescriptor(self: *const Context, name: []const u8) ?*value_mod.HashTable {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupTypeDescriptorLocked(name);
    }

    fn lookupTypeDescriptorLocked(self: *const Context, name: []const u8) ?*value_mod.HashTable {
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
            .native => return null,
        }
    }

    pub fn lookupTypeNameByDescriptor(self: *const Context, desc: *const value_mod.HashTable) ?[]const u8 {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupTypeNameByDescriptorLocked(desc);
    }

    fn lookupTypeNameByDescriptorLocked(self: *const Context, desc: *const value_mod.HashTable) ?[]const u8 {
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
                        .native => {},
                    }
                }
            }

            var dict_iter = ancestor.dictionary.entries.iterator();
            while (dict_iter.next()) |entry| {
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
                    .native => {},
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
    ) ?*value_mod.HashTable {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupParameterizedTypeDescriptorLocked(base, element);
    }

    fn lookupParameterizedTypeDescriptorLocked(
        self: *const Context,
        base: *const value_mod.TypeValue,
        element: *const value_mod.TypeValue,
    ) ?*value_mod.HashTable {
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
    ) ?*value_mod.HashTable {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupStructDescriptorLocked(fields, field_types, mutable);
    }

    fn lookupStructDescriptorLocked(
        self: *const Context,
        fields: []const []const u8,
        field_types: []const ?*const value_mod.TypeValue,
        mutable: bool,
    ) ?*value_mod.HashTable {
        const key = StructDescriptorKey{ .fields = fields, .field_types = field_types, .mutable = mutable };
        if (self.struct_descriptors.get(key)) |desc| return desc;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            if (ctx.struct_descriptors.get(key)) |desc| return desc;
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
        const desc_map = try value_mod.createTypeDescriptor(
            alloc,
            "resource-type:",
            .{ .mutable = true },
        );
        try desc_map.put(alloc, "resource-kind", .{ .string = name });
        // TODO(ripta): investigate per-resource mutability instead of assuming all resources are mutable.
        const tv = try alloc.create(value_mod.TypeValue);
        tv.* = .{ .name = name, .descriptor = @ptrCast(desc_map) };

        try self.registerResourceTypeValue(name, tv);
        return tv;
    }

    pub fn getOrCreateParameterizedTypeDescriptor(
        self: *Context,
        base: *const value_mod.TypeValue,
        element: *const value_mod.TypeValue,
    ) !*value_mod.HashTable {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();

        if (self.lookupParameterizedTypeDescriptorLocked(base, element)) |desc| return desc;

        const alloc = self.quotationAllocator();
        const desc_map = try value_mod.createTypeDescriptor(alloc, "virtual:", .{});
        try desc_map.put(alloc, "inner-type", .{ .type_val = @constCast(base) });
        try desc_map.put(alloc, "element-type", .{ .type_val = @constCast(element) });

        try self.parameterized_type_descriptors.put(
            self.allocator,
            .{ .base = base, .element = element },
            @ptrCast(desc_map),
        );
        return @ptrCast(desc_map);
    }

    pub fn getOrCreateStructDescriptor(
        self: *Context,
        fields: []const []const u8,
        field_types: []const ?*const value_mod.TypeValue,
        mutable: bool,
    ) !*value_mod.HashTable {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();

        if (self.lookupStructDescriptorLocked(fields, field_types, mutable)) |desc| return desc;

        const alloc = self.quotationAllocator();
        const desc_map = try value_mod.createTypeDescriptor(
            alloc,
            "struct-descriptor:",
            .{ .mutable = mutable },
        );
        const desc_fields = try alloc.alloc(value_mod.Value, fields.len);
        for (fields, 0..) |field, i| {
            desc_fields[i] = .{ .string = field };
        }
        try desc_map.put(alloc, "fields", .{ .array = desc_fields });
        if (field_types.len != 0) {
            const desc_field_types = try alloc.alloc(value_mod.Value, field_types.len);
            for (field_types, 0..) |field_type, i| {
                desc_field_types[i] = .{ .type_val = @constCast(field_type orelse unreachable) };
            }
            try desc_map.put(alloc, "field-types", .{ .array = desc_field_types });
        }

        try self.struct_descriptors.put(
            self.allocator,
            .{ .fields = fields, .field_types = field_types, .mutable = mutable },
            @ptrCast(desc_map),
        );
        return @ptrCast(desc_map);
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
    pub fn registerTypeDescriptor(self: *Context, name: []const u8, desc: *value_mod.HashTable) !void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        return self.registerTypeDescriptorLocked(name, desc);
    }

    fn registerTypeDescriptorLocked(self: *Context, name: []const u8, desc: *value_mod.HashTable) !void {
        if (self.type_registry_frames.items.len == 0) return error.OutOfMemory;
        const top = self.type_registry_frames.items.len - 1;
        try self.type_registry_frames.items[top].type_descriptors.put(self.allocator, name, desc);
    }

    /// Register enum variants into the topmost type registry frame.
    pub fn registerEnumVariants(self: *Context, name: []const u8, variants: []const *const value_mod.VirtualType) !void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        return self.registerEnumVariantsLocked(name, variants);
    }

    fn registerEnumVariantsLocked(self: *Context, name: []const u8, variants: []const *const value_mod.VirtualType) !void {
        if (self.type_registry_frames.items.len == 0) return error.OutOfMemory;
        const top = self.type_registry_frames.items.len - 1;
        try self.type_registry_frames.items[top].enum_registry.put(self.allocator, name, variants);
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

    /// Collect all dispatch key-entry pairs for a given word name, including
    /// entries from all frames, the base table, and parent contexts.
    pub fn dispatchEntriesForWord(self: *const Context, word_name: []const u8, alloc: Allocator) ![]DispatchTable.KeyEntryPair {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.dispatchEntriesForWordLocked(word_name, alloc);
    }

    fn dispatchEntriesForWordLocked(self: *const Context, word_name: []const u8, alloc: Allocator) ![]DispatchTable.KeyEntryPair {
        var results: std.ArrayListUnmanaged(DispatchTable.KeyEntryPair) = .{};
        // Walk dispatch frames top-to-bottom
        var i = self.dispatch_frames.items.len;
        while (i > 0) {
            i -= 1;
            try dispatch_mod.collectEntriesForWord(&self.dispatch_frames.items[i].entries, word_name, &results, alloc);
        }
        // Base dispatch table
        try dispatch_mod.collectEntriesForWord(&self.dispatch.entries, word_name, &results, alloc);

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            var j = ctx.dispatch_frames.items.len;
            while (j > 0) {
                j -= 1;
                try dispatch_mod.collectEntriesForWord(&ctx.dispatch_frames.items[j].entries, word_name, &results, alloc);
            }
            try dispatch_mod.collectEntriesForWord(&ctx.dispatch.entries, word_name, &results, alloc);
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

    /// Collect all dispatch keys for a given word name, including
    /// entries from all frames, the base table, and parent contexts.
    pub fn dispatchKeysForWord(self: *const Context, word_name: []const u8, alloc: Allocator) ![]DispatchKey {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.dispatchKeysForWordLocked(word_name, alloc);
    }

    fn dispatchKeysForWordLocked(self: *const Context, word_name: []const u8, alloc: Allocator) ![]DispatchKey {
        var results: std.ArrayListUnmanaged(DispatchKey) = .{};
        // Walk dispatch frames top-to-bottom
        var i = self.dispatch_frames.items.len;
        while (i > 0) {
            i -= 1;
            try dispatch_mod.collectKeysForWord(&self.dispatch_frames.items[i].entries, word_name, &results, alloc);
        }
        // Base dispatch table
        try dispatch_mod.collectKeysForWord(&self.dispatch.entries, word_name, &results, alloc);

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            var j = ctx.dispatch_frames.items.len;
            while (j > 0) {
                j -= 1;
                try dispatch_mod.collectKeysForWord(&ctx.dispatch_frames.items[j].entries, word_name, &results, alloc);
            }
            try dispatch_mod.collectKeysForWord(&ctx.dispatch.entries, word_name, &results, alloc);
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
            self.pushCallFrame(module_path, line, column);
            defer self.popCallFrame();

            switch (module_word.action) {
                .native => |func| try func(self),
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
                    self.pushCallFrame(name, line, column);
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

            self.pushCallFrame(name, line, column);
            if (self.trace.trace_words and trace_mod.matchesPattern(name, self.trace.trace_words_pattern)) {
                var tw = trace_mod.TraceWriter.init();
                trace_mod.traceWord(&tw, name, self.current_source, line, &self.stack);
            }
            defer self.popCallFrame();

            switch (mod_word.action) {
                .compound => |instrs| {
                    try self.pushModuleDepsFrame(module);
                    defer {
                        if (self.trace.trace_modules) {
                            var tw = trace_mod.TraceWriter.init();
                            trace_mod.traceModuleDepsPop(&tw, module.name);
                        }
                        self.popLocalFrame();
                    }

                    const has_generic = for (mod_word.markers) |mk| {
                        if (markers_mod.isGenericMarker(mk)) break true;
                    } else false;

                    if (has_generic) {
                        if (try dispatch_helpers.tryDispatchGeneric(self, word_name)) return;

                        if (instrs.len == 0) {
                            self.pending_error_message = "no method found for given argument types";
                            return error.TypeError;
                        }
                    }

                    try self.executeInstructions(instrs, null);
                },
                .native => |func| try func(self),
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
    pub fn pushCallFrame(self: *Context, word_name: []const u8, line: usize, column: usize) void {
        self.call_stack.append(self.allocator, .{
            .word_name = word_name,
            .line = line,
            .column = column,
        }) catch {};
    }

    /// Pop a call frame from the call stack.
    fn popCallFrame(self: *Context) void {
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
                .call_word => |name| {
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
                    .source = self.current_source,
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
                    .source = self.current_source,
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
                    .source = self.current_source,
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

            const expected_tv = param.type_annotation orelse continue;
            if (self.any_type_sentinel) |any_tv| {
                if (expected_tv == any_tv) continue;
            }

            const offset_from_top = concrete_params - 1 - concrete_index;
            const stack_index = self.stack.depth() - 1 - offset_from_top;
            const val = self.stack.items.items[stack_index];

            const val_tv: *const value_mod.TypeValue = dispatch_mod.dispatchTypeValue(val, self);

            // Regular types: direct pointer match
            if (val_tv == expected_tv) continue;

            // Tagged values: check parent_type for parameterized types and base_type for enum variant matching
            //
            // TODO(ripta): This is a tad ad-hoc, but it allows us to support common patterns like `list of int` parameters,
            //              and enum variants without requiring explicit type annotations on the tagged value itself.
            if (val == .tagged) {
                if (val.tagged.tag.parent_type) |pt| {
                    if (pt == expected_tv) continue;
                }
                if (val.tagged.tag.base_type) |bt| {
                    if (bt == expected_tv) continue;
                }
            }

            // Type mismatch
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
                if (self.thrown_error) |thrown| break :blk thrown.error_type;
            }
            var kebab_buf: [128]u8 = undefined;
            const kebab_name = pascalToKebabRuntime(@errorName(err), &kebab_buf);
            break :blk self.arena.allocator().dupe(u8, kebab_name) catch @errorName(err);
        };

        const thrown_msg: ?[]const u8 = blk: {
            if (err == error.UserThrown) {
                if (self.thrown_error) |thrown| break :blk thrown.message;
            }
            break :blk null;
        };

        // Consume any pending error message for the innermost frame
        const pending_msg = self.pending_error_message;
        self.pending_error_message = null;

        // Consume any pending error hint for the innermost frame
        const pending_hint = self.pending_error_hint;
        self.pending_error_hint = null;

        // Iterate call_stack in reverse (innermost first for display)
        var i = self.call_stack.items.len;
        var is_innermost = true;
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
                .source = self.current_source,
                .line = frame.line,
                .word_name = frame.word_name,
                .stack_effect_str = se_str,
                .hint = if (is_innermost) pending_hint else null,
            }) catch {};
            is_innermost = false;
        }
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

        const line = if (self.call_stack.items.len > 0)
            self.call_stack.items[self.call_stack.items.len - 1].line
        else
            0;

        self.error_details.append(self.allocator, .{
            .error_type = "stack-effect-mismatch",
            .message = msg_copy,
            .source = self.current_source,
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
        var current_instructions = quotation.instructions;
        var current_pic = pic_table;
        var current_module: ?*const value_mod.Module = null;
        var owns_frame = false;

        while (true) {
            // Record depth before execution for validation
            const depth_before = self.stack.depth();
            self.tail_call_instructions = null;
            self.tail_call_module = null;

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
                    if (self.trace.trace_modules) {
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

                const new_module = self.tail_call_module;
                self.tail_call_module = null;

                if (new_module) |new_mod| {
                    if (owns_frame and current_module.? != new_mod) {
                        if (self.trace.trace_modules) {
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
                if (self.trace.trace_modules) {
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
    pub fn executeQuotationWithFrame(self: *Context, quotation: Quotation) anyerror!void {
        try self.pushLocalFrame();
        defer self.popLocalFrame();

        // TODO(ripta): I think executeQuotation is *always* necessary to get TCO loop?
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
                self.popCallFrame();
                return primitives.InterpreterError.StackEffectMismatch;
            }
        }
        if (self.benchmark) |b| {
            b.endWordProfile(self.allocator, name);
            b.updatePeakStackDepth(self.stack.depth());
        }
        self.popCallFrame();
    }

    /// Pop a module deps local frame, emitting a trace log when module
    /// tracing is enabled.
    pub fn popModuleDepsFrameTraced(self: *Context, mod: *const value_mod.Module) void {
        if (self.trace.trace_modules) {
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
                    try dbg.enterPrompt(instr, self);
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
                        self.pushCallFrame(name, instr.line, instr.column);
                        return self.wordErrorCleanup(name, err);
                    };

                    if (self.benchmark) |b| {
                        b.recordCallWord();
                        b.beginWordProfile();
                    }

                    if (self.lookupWord(name)) |word| {
                        if (self.active_sandbox) |sandbox| {
                            if (!sandbox.allows(word.capability)) {
                                self.pushCallFrame(name, instr.line, instr.column);
                                self.pending_error_message = std.fmt.allocPrint(
                                    self.arena.allocator(),
                                    "'{s}' requires capability '{s}' which is not granted by the active sandbox",
                                    .{ name, word.capability.displayName() },
                                ) catch "word denied by sandbox";
                                return self.wordErrorCleanup(name, error.PermissionDenied);
                            }
                        }

                        if (word.parse_time_only and self.parse_tokenizer == null) {
                            self.pushCallFrame(name, instr.line, instr.column);
                            self.pending_error_message = "parse-time-only word cannot be called at runtime";
                            return self.wordErrorCleanup(name, error.ParseError);
                        }

                        // Try JIT-compiled dispatch before interpreter path
                        if (word.word_id) |wid| {
                            if (word.stack_effect) |effect| {
                                self.validateParameterEffects(&effect) catch |err| {
                                    self.pushCallFrame(name, instr.line, instr.column);
                                    return self.wordErrorCleanup(name, err);
                                };
                                self.validateTypeAnnotations(&effect) catch |err| {
                                    self.pushCallFrame(name, instr.line, instr.column);
                                    return self.wordErrorCleanup(name, err);
                                };
                            }
                            const jit_result = ir_codegen.executeCompiled(self, wid);
                            if (self.trace.trace_jit) {
                                var tw = trace_mod.TraceWriter.init();
                                trace_mod.traceJitDispatch(&tw, name, wid, jit_result != .bail);
                            }
                            switch (jit_result) {
                                .ok => {
                                    if (self.benchmark) |bm| bm.endWordProfile(self.allocator, name);
                                    continue;
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

                        self.pushCallFrame(name, instr.line, instr.column);
                        self.traceWordExecution(name, instr);

                        if (word.stack_effect) |effect| {
                            self.validateParameterEffects(&effect) catch |err|
                                return self.wordErrorCleanup(name, err);
                            self.validateTypeAnnotations(&effect) catch |err|
                                return self.wordErrorCleanup(name, err);
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
                                const dispatched = dispatch_helpers.tryDispatchGenericWithPic(self, name, pic_entry) catch |err|
                                    return self.wordErrorCleanup(name, err);

                                if (dispatched) {
                                    try self.wordSuccessCleanup(name, null);
                                    continue;
                                }

                                if (word.action.compound.len == 0) {
                                    self.pending_error_message = "no method found for given argument types";
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
                                    self.tail_call_instructions = instrs;
                                    self.tail_call_module = word.source_module;
                                    return;
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

                            if (word.action == .native) {
                                self.current_pic_entry = if (pic_table) |pt| pt.get(idx) else null;
                            }
                            defer self.current_pic_entry = null;

                            const result = blk: {
                                if (word.source_module) |mod| {
                                    switch (word.action) {
                                        .compound => |instrs| {
                                            self.pushModuleDepsFrame(mod) catch |e| break :blk @as(anyerror!void, e);
                                            defer self.popModuleDepsFrameTraced(mod);
                                            break :blk self.executeQuotationWithPic(.{ .instructions = instrs }, callee_pic);
                                        },
                                        .native => |func| break :blk func(self),
                                    }
                                } else {
                                    break :blk switch (word.action) {
                                        .native => |func| func(self),
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
                    } else if (isQualifiedName(name)) {
                        self.executeQualifiedName(name, instr.line, instr.column) catch |err| {
                            self.pushCallFrame(name, instr.line, instr.column);
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
                        self.pushCallFrame(name, instr.line, instr.column);
                        self.captureCallStackOnError(ExecutionError.UnknownWord);
                        self.popCallFrame();
                        return ExecutionError.UnknownWord;
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
            .source = self.current_source,
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

fn resolveWordForDispatch(name: []const u8, user_data: *anyopaque) ?ir_codegen.ResolvedWord {
    const state: *ResolverState = @ptrCast(@alignCast(user_data));
    const ctx = state.context;
    const callee = ctx.lookupWord(name) orelse return null;

    switch (callee.action) {
        .compound => {},
        .native => |func| {
            const effect = callee.stack_effect orelse return null;
            if (stack_effect_mod.hasAnyRowVariable(effect)) return null;
            return ir_codegen.ResolvedWord{
                .word_id = 0,
                .input_count = @intCast(effect.inputs.len),
                .output_count = @intCast(effect.outputs.len),
                .native_fn_ptr = @intFromPtr(func),
            };
        },
    }

    const effect = callee.stack_effect orelse return null;
    if (stack_effect_mod.hasAnyRowVariable(effect)) return null;

    const word_id = if (callee.word_id) |id| id else blk: {
        const id = ctx.jit_dispatch.assignId(name) catch return null;
        propagateWordId(ctx, name, id);
        break :blk id;
    };

    return ir_codegen.ResolvedWord{
        .word_id = word_id,
        .input_count = @intCast(effect.inputs.len),
        .output_count = @intCast(effect.outputs.len),
    };
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
    if (ctx.dictionary.entries.getPtr(name)) |entry| {
        entry.word_id = word_id;
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
        if (anc.dictionary.entries.getPtr(name)) |entry| {
            entry.word_id = word_id;
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
    ctx.call_stack.append(ctx.allocator, .{ .word_name = "test", .line = 1 }) catch {};
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
    const desc = try alloc.create(value_mod.HashTable);
    desc.* = .{};
    try ctx.registerTypeDescriptor("test-type", desc);

    // Visible through base frame
    try std.testing.expect(ctx.lookupTypeDescriptor("test-type") != null);

    // Push a new frame, register in it
    try ctx.pushTypeRegistryFrame();
    const desc2 = try alloc.create(value_mod.HashTable);
    desc2.* = .{};
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

    // Register in base frame
    const desc1 = try alloc.create(value_mod.HashTable);
    desc1.* = .{};
    try desc1.put(alloc, "marker", .{ .fixnum = 1 });
    try ctx.registerTypeDescriptor("shadowed", desc1);

    // Push a frame and shadow the same name
    try ctx.pushTypeRegistryFrame();
    const desc2 = try alloc.create(value_mod.HashTable);
    desc2.* = .{};
    try desc2.put(alloc, "marker", .{ .fixnum = 2 });
    try ctx.registerTypeDescriptor("shadowed", desc2);

    // Inner wins
    const found = ctx.lookupTypeDescriptor("shadowed").?;
    try std.testing.expectEqual(@as(i64, 2), found.get("marker").?.fixnum);

    // Pop; outer visible again
    ctx.popTypeRegistryFrame();
    const found2 = ctx.lookupTypeDescriptor("shadowed").?;
    try std.testing.expectEqual(@as(i64, 1), found2.get("marker").?.fixnum);
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

test "enum registry frame push/pop" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const alloc = ctx.arena.allocator();
    const vt = try alloc.create(value_mod.VirtualType);
    vt.* = .{ .name = "red", .inner_type = "symbol" };
    const variants: []const *const value_mod.VirtualType = &.{vt};
    try ctx.registerEnumVariants("color", variants);

    try std.testing.expect(ctx.lookupEnumVariants("color") != null);

    try ctx.pushTypeRegistryFrame();
    const vt2 = try alloc.create(value_mod.VirtualType);
    vt2.* = .{ .name = "small", .inner_type = "symbol" };
    const variants2: []const *const value_mod.VirtualType = &.{vt2};
    try ctx.registerEnumVariants("size", variants2);

    try std.testing.expect(ctx.lookupEnumVariants("size") != null);
    try std.testing.expect(ctx.lookupEnumVariants("color") != null);

    ctx.popTypeRegistryFrame();
    try std.testing.expect(ctx.lookupEnumVariants("size") == null);
    try std.testing.expect(ctx.lookupEnumVariants("color") != null);
}

// =============================================================================
// Dispatch frame tests
// =============================================================================

test "dispatch frame push/pop with lookup visibility" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;

    const body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 42 } }, .line = 0 }};

    // Register in base dispatch table
    try ctx.dispatch.register(
        .{ .word_name = "show", .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = body } },
        false,
    );

    try std.testing.expect(ctx.lookupUnaryDispatch("show", fixnum_tv.descriptor.?) != null);

    // Push a frame and register a new entry
    try ctx.pushDispatchFrame();
    const body2 = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 99 } }, .line = 0 }};
    try ctx.registerDispatch(
        .{ .word_name = "show", .type_a = string_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = body2 } },
        false,
    );

    try std.testing.expect(ctx.lookupUnaryDispatch("show", string_tv.descriptor.?) != null);
    try std.testing.expect(ctx.lookupUnaryDispatch("show", fixnum_tv.descriptor.?) != null);

    // Pop; string entry should vanish
    ctx.popDispatchFrame();
    try std.testing.expect(ctx.lookupUnaryDispatch("show", string_tv.descriptor.?) == null);
    try std.testing.expect(ctx.lookupUnaryDispatch("show", fixnum_tv.descriptor.?) != null);
}

test "dispatch frame shadowing" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const duration_desc = try value_mod.createTypeDescriptor(std.testing.allocator, "test:", .{});
    defer value_mod.destroyTypeDescriptor(std.testing.allocator, duration_desc);
    const duration_tv = value_mod.TypeValue{ .name = "duration", .descriptor = @ptrCast(duration_desc) };

    const body1 = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 }};
    const body2 = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 0 }};

    // Register in base table
    try ctx.dispatch.register(
        .{ .word_name = "+", .type_a = duration_tv.descriptor.?, .type_b = duration_tv.descriptor.? },
        .{ .body = .{ .quotation = body1 } },
        false,
    );

    // Push frame and shadow
    try ctx.pushDispatchFrame();
    try ctx.registerDispatch(
        .{ .word_name = "+", .type_a = duration_tv.descriptor.?, .type_b = duration_tv.descriptor.? },
        .{ .body = .{ .quotation = body2 } },
        false,
    );

    // Inner should win
    const entry = ctx.lookupBinaryDispatch("+", duration_tv.descriptor.?, duration_tv.descriptor.?).?;
    try std.testing.expectEqual(@as(i64, 2), entry.body.quotation[0].op.push_literal.fixnum);

    // Pop; outer visible again
    ctx.popDispatchFrame();
    const entry2 = ctx.lookupBinaryDispatch("+", duration_tv.descriptor.?, duration_tv.descriptor.?).?;
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
    const body = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 0 }};
    try ctx.registerDispatch(
        .{ .word_name = "test-op", .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = body } },
        false,
    );

    // Should be findable via both the new API and the raw dispatch table
    try std.testing.expect(ctx.lookupUnaryDispatch("test-op", fixnum_tv.descriptor.?) != null);
    try std.testing.expect(ctx.dispatch.lookupUnary("test-op", fixnum_tv.descriptor.?, ctx.getDispatchAnySentinel().descriptor.?, ctx.getDispatchUnarySentinel().descriptor.?) != null);
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
    try std.testing.expectEqualStrings("builtin-type:", desc.get("type").?.symbol);
    try std.testing.expect(desc.get("numeric").?.boolean);
    try std.testing.expect(desc.get("exact").?.boolean);
    try std.testing.expect(desc.get("integer").?.boolean);
    try std.testing.expect(!desc.get("mutable").?.boolean);
}
