const std = @import("std");
const Allocator = std.mem.Allocator;

const Stack = @import("stack.zig").Stack;
const Dictionary = @import("dictionary.zig").Dictionary;
const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const debugger_mod = @import("debugger/mod.zig");
const dispatch_helpers = @import("primitives/dispatch_helpers.zig");
const dispatch_mod = @import("dispatch.zig");
const DispatchEntry = dispatch_mod.DispatchEntry;
const DispatchTable = dispatch_mod.DispatchTable;
const Scheduler = @import("scheduler.zig").Scheduler;
const Quotation = value_mod.Quotation;
const Value = value_mod.Value;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const primitives = @import("primitives.zig");
const parser = @import("parser.zig");
const BenchmarkStats = @import("benchmark.zig").BenchmarkStats;
const trace_mod = @import("trace.zig");
const TraceConfig = trace_mod.TraceConfig;
const StackEffect = @import("stack_effect.zig").StackEffect;
const StackEffectParam = @import("stack_effect.zig").StackEffectParam;
const pascalToKebabRuntime = @import("primitives/errors.zig").pascalToKebabRuntime;
const markers_mod = @import("primitives/markers.zig");

/// Embedded prelude source code
const prelude_source = @embedFile("prelude.1z");

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
/// If validator is null, the pragma accepts only boolean values.
/// If validator is a quotation, it is called with the value on the stack
/// and must return a result:ok or result:err.
pub const PragmaRegistration = struct {
    validator: ?value_mod.Quotation,
};

/// PragmaFrame holds pragma values for the current file scope.
pub const PragmaFrame = std.StringHashMapUnmanaged(Value);

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
    allocator: Allocator,
    call_stack: std.ArrayListUnmanaged(CallFrame),
    error_details: std.ArrayListUnmanaged(ErrorDetail),
    /// Parameter environment frames for dynamic scoping
    parameter_env: std.ArrayListUnmanaged(ParameterFrame),
    /// Local definition frames for lexical scoping within quotations
    local_frames: std.ArrayListUnmanaged(LocalFrame),
    /// Tokenizer for parse-time word access (set during parsing, null otherwise)
    parse_tokenizer: ?*Tokenizer = null,
    /// Optional benchmark stats (null when benchmarking is disabled)
    benchmark: ?*BenchmarkStats = null,
    /// Current source file name for error reporting (defaults to "<repl>")
    current_source: []const u8 = "<repl>",
    /// Tail call target for TCO — set by executeInstructions, consumed by executeQuotation
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
    /// Cache of loaded modules keyed by canonical file path.
    /// Prevents redundant loading when multiple files `use` the same module.
    module_cache: std.StringHashMapUnmanaged(*value_mod.Module) = .{},
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
    /// Shared scheduler for green thread contexts. Null for the root context.
    scheduler: ?*Scheduler = null,
    /// Enum registry mapping enum names to their variant VirtualType pointers.
    enum_registry: std.StringHashMapUnmanaged([]const *const value_mod.VirtualType) = .{},
    /// Registry of known pragma keys and their validation rules.
    pragma_registry: std.StringHashMapUnmanaged(PragmaRegistration) = .{},
    /// Stack of pragma frames for file-scoped pragma values.
    pragma_frames: std.ArrayListUnmanaged(PragmaFrame) = .{},
    /// Parent context for dictionary and dispatch table lookup chaining.
    /// Task contexts walk this chain to find words and methods defined in
    /// ancestor scopes, up to the root context which holds primitives and
    /// prelude words.
    parent_context: ?*const Context = null,

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
        };

        primitives.registerPrimitives(&ctx.dictionary, ctx.arena.allocator()) catch |err| {
            std.debug.panic("Failed to register primitives: {any}", .{err});
        };

        primitives.createNativeModule(&ctx.dictionary, ctx.arena.allocator()) catch |err| {
            std.debug.panic("Failed to create native module: {any}", .{err});
        };

        return ctx;
    }

    /// Initialize context and load prelude. Convenience method for non-benchmark use.
    pub fn initWithPrelude(allocator: Allocator) Context {
        var ctx = init(allocator);
        ctx.loadPrelude() catch |err| {
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
            .scheduler = scheduler,
            .parent_context = parent,

            .trace = parent.trace,
            .deadlock_detect_ns = parent.deadlock_detect_ns,
            .current_source = parent.current_source,
            .current_source_dir = parent.current_source_dir,
            .load_paths = parent.load_paths,
            .stdlib_path = parent.stdlib_path,
            .program_args = parent.program_args,
        };

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

    /// Load the embedded prelude source.
    /// Processes definitions incrementally so that parse-time words defined
    /// earlier in the prelude are available when parsing later definitions.
    pub fn loadPrelude(self: *Context) !void {
        const StatementProcessor = @import("statement.zig").StatementProcessor;
        var processor: StatementProcessor = .{};

        // Push an initial frame so that the prelude definitions land in a local
        // frame instead of the global dictionary
        try self.pushLocalFrame();
        self.import_frame_index = self.local_frames.items.len - 1;

        // Push the base pragma frame and register built-in pragmas
        try self.pushPragmaFrame();
        try self.pragma_registry.put(self.allocator, "require-doc", .{ .validator = null });

        // Split prelude into lines and process incrementally
        var lines = std.mem.splitScalar(u8, prelude_source, '\n');
        while (lines.next()) |line| {
            const result = processor.feedLine(self.arena.allocator(), line, self);
            switch (result) {
                .needs_more_input => continue,
                .complete => |instrs| {
                    if (instrs.len > 0) {
                        try self.executeQuotation(.{ .instructions = instrs });
                    }
                    processor.reset();
                },
                .parse_error => |err| return err,
            }
        }

        // Flush any remaining buffered content
        switch (processor.flush(self.arena.allocator(), self)) {
            .complete => |instrs| {
                if (instrs.len > 0) {
                    try self.executeQuotation(.{ .instructions = instrs });
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
        self.module_cache.deinit(self.arena.allocator());
        for (self.pragma_frames.items) |*frame| {
            frame.deinit(self.allocator);
        }
        self.pragma_frames.deinit(self.allocator);
        self.pragma_registry.deinit(self.allocator);
        self.enum_registry.deinit(self.allocator);
        self.dispatch.deinit();
        self.arena.deinit();
        self.dictionary.deinit();
        self.stack.deinit();
    }

    /// Allocator for quotations and other parsed data.
    pub fn quotationAllocator(self: *Context) Allocator {
        return self.arena.allocator();
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
                .source_module = module,
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
    // Pragma frame methods (file-scoped pragma values)
    // =========================================================================

    /// Push a new empty pragma frame onto the frame stack.
    pub fn pushPragmaFrame(self: *Context) !void {
        try self.pragma_frames.append(self.allocator, PragmaFrame{});
    }

    /// Pop the top pragma frame from the frame stack.
    pub fn popPragmaFrame(self: *Context) void {
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
        if (self.lookupWord(name)) |existing| {
            for (existing.markers) |mk| {
                if (markers_mod.isConstMarker(mk)) {
                    self.pending_error_message = "cannot redefine const word";
                    return error.CannotRedefineConst;
                }
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

    /// Define a word via `import`. Writes to the import frame tracked by
    /// `import_frame_index`, which is always set in every execution context,
    /// i.e., prelude, batch, REPL, module load.
    pub fn defineImportedWord(self: *Context, name: []const u8, definition: WordDefinition) !void {
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
            for (existing.markers) |mk| {
                if (markers_mod.isConstMarker(mk)) {
                    self.pending_error_message = "cannot redefine const word";
                    return error.CannotRedefineConst;
                }
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

    /// Determine where a word was found during lookup, mirroring the
    /// search order of `lookupWord`. Used only when trace_resolve is active.
    fn lookupWordSource(self: *const Context, name: []const u8) trace_mod.ResolveSource {
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

    /// Look up a binary dispatch entry by walking upthe parent context chain.
    pub fn lookupBinaryDispatch(self: *const Context, word_name: []const u8, type_a: []const u8, type_b: []const u8) ?DispatchEntry {
        if (self.dispatch.lookupBinary(word_name, type_a, type_b)) |entry| return entry;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            if (ctx.dispatch.lookupBinary(word_name, type_a, type_b)) |entry| return entry;
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Look up a unary dispatch entry by walking u pthe parent context chain.
    pub fn lookupUnaryDispatch(self: *const Context, word_name: []const u8, type_a: []const u8) ?DispatchEntry {
        if (self.dispatch.lookupUnary(word_name, type_a)) |entry| return entry;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            if (ctx.dispatch.lookupUnary(word_name, type_a)) |entry| return entry;
            ancestor = ctx.parent_context;
        }

        return null;
    }

    /// Look up enum variant types by enum name, walking the parent context chain.
    pub fn lookupEnumVariants(self: *const Context, enum_name: []const u8) ?[]const *const value_mod.VirtualType {
        if (self.enum_registry.get(enum_name)) |variants| return variants;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            if (ctx.enum_registry.get(enum_name)) |variants| return variants;
            ancestor = ctx.parent_context;
        }

        return null;
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
                .compound => |instrs| try self.executeInstructions(instrs),
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

                    try self.executeInstructions(instrs);
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
    fn pushCallFrame(self: *Context, word_name: []const u8, line: usize, column: usize) void {
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

    /// Infer a quotation's stack delta by statically analyzing its instructions.
    /// Returns null if the delta cannot be determined (e.g., unknown words, control flow).
    fn inferQuotationDelta(self: *Context, quot: Quotation) ?i64 {
        var delta: i64 = 0;

        for (quot.instructions) |instr| {
            switch (instr.op) {
                .push_literal => |val| {
                    // Pushing a value increases stack by 1
                    delta += 1;

                    // If it's a quotation, we can't know its effect without calling it
                    // But we're just counting the push, not its execution
                    _ = val;
                },
                .call_word => |name| {
                    if (self.lookupWord(name)) |word| {
                        if (word.stack_effect) |word_effect| {
                            // Count only concrete parameters (skip row variables)
                            var concrete_inputs: i64 = 0;
                            var concrete_outputs: i64 = 0;

                            for (word_effect.inputs) |param| {
                                if (!isRowVariable(param.name)) {
                                    concrete_inputs += 1;
                                }
                            }
                            for (word_effect.outputs) |param| {
                                if (!isRowVariable(param.name)) {
                                    concrete_outputs += 1;
                                }
                            }

                            delta = delta - concrete_inputs + concrete_outputs;
                        } else {
                            // Word has no declared effect, can't infer
                            return null;
                        }
                    } else {
                        // Unknown word
                        return null;
                    }
                },
            }
        }

        return delta;
    }

    /// Validate a quotation against an expected effect by inferring its delta.
    /// Returns an error if the quotation doesn't match the expected effect.
    fn validateQuotationEffect(self: *Context, quot: Quotation, expected_effect: *const StackEffect, param_name: []const u8) !void {
        // If the effect has unbalanced row variables (row vars that appear only in
        // inputs or only in outputs), we can't determine a fixed expected delta.
        // Skip validation in this case since the effect is polymorphic.
        if (hasUnbalancedRowVariables(expected_effect)) {
            return;
        }

        // Compute expected delta from effect
        var expected_concrete_inputs: i64 = 0;
        var expected_concrete_outputs: i64 = 0;

        for (expected_effect.inputs) |param| {
            if (!isRowVariable(param.name)) {
                expected_concrete_inputs += 1;
            }
        }
        for (expected_effect.outputs) |param| {
            if (!isRowVariable(param.name)) {
                expected_concrete_outputs += 1;
            }
        }

        const expected_delta = expected_concrete_outputs - expected_concrete_inputs;

        // Infer actual delta from quotation instructions
        const inferred_delta = self.inferQuotationDelta(quot);

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

    /// Check if an effect has row variables that appear only in inputs or only in outputs.
    /// Such effects are polymorphic and their delta cannot be determined statically.
    fn hasUnbalancedRowVariables(effect: *const StackEffect) bool {
        // Collect row variables from inputs
        var input_row_vars: [8][]const u8 = undefined;
        var input_count: usize = 0;
        for (effect.inputs) |param| {
            if (isRowVariable(param.name) and input_count < 8) {
                input_row_vars[input_count] = param.name;
                input_count += 1;
            }
        }

        // Collect row variables from outputs
        var output_row_vars: [8][]const u8 = undefined;
        var output_count: usize = 0;
        for (effect.outputs) |param| {
            if (isRowVariable(param.name) and output_count < 8) {
                output_row_vars[output_count] = param.name;
                output_count += 1;
            }
        }

        // Check if any input row var is missing from outputs
        for (input_row_vars[0..input_count]) |input_var| {
            var found = false;
            for (output_row_vars[0..output_count]) |output_var| {
                if (std.mem.eql(u8, input_var, output_var)) {
                    found = true;
                    break;
                }
            }
            if (!found) return true;
        }

        // Check if any output row var is missing from inputs
        for (output_row_vars[0..output_count]) |output_var| {
            var found = false;
            for (input_row_vars[0..input_count]) |input_var| {
                if (std.mem.eql(u8, output_var, input_var)) {
                    found = true;
                    break;
                }
            }
            if (!found) return true;
        }

        return false;
    }

    /// Check if a name is a row variable (starts with "..")
    fn isRowVariable(name: []const u8) bool {
        return name.len >= 2 and name[0] == '.' and name[1] == '.';
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

    /// Validate that all row variables in a quotation effect are defined in the word's effect.
    fn validateRowVariables(self: *Context, quot_effect: *const StackEffect, word_effect: *const StackEffect, param_name: []const u8) !void {
        // Check all row variables in quotation effect inputs
        for (quot_effect.inputs) |param| {
            if (isRowVariable(param.name) and !isRowVariableDefined(param.name, word_effect)) {
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
            if (isRowVariable(param.name) and !isRowVariableDefined(param.name, word_effect)) {
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
    fn validateParameterEffects(self: *Context, effect: *const StackEffect) !void {
        // First, validate that all row variables in quotation effects are defined
        for (effect.inputs) |param| {
            if (param.quotation_effect) |quot_effect| {
                try self.validateRowVariables(quot_effect, effect, param.name);
            }
        }

        // Count concrete parameters (skip row variables starting with "..")
        var concrete_params: usize = 0;
        for (effect.inputs) |param| {
            if (!isRowVariable(param.name)) {
                concrete_params += 1;
            }
        }

        if (concrete_params == 0 or self.stack.depth() < concrete_params) return;

        // Validate quotation effects on stack
        // The top concrete_params items on the stack are the parameters
        // Stack layout: [...other values] [param_0] [param_1] ... [param_n-1]
        // param_n-1 is on top (offset 0 from top), param_0 is at offset n-1 from top
        var concrete_index: usize = 0;
        for (effect.inputs) |param| {
            // Skip row variables
            if (isRowVariable(param.name)) {
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
                    try self.validateQuotationEffect(quot, expected_effect, param.name);
                }
            }

            concrete_index += 1;
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
        var current_instructions = quotation.instructions;
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

            const exec_result = self.executeInstructions(current_instructions);
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
                const expected_delta: i64 = @as(i64, @intCast(effect.outputs.len)) - @as(i64, @intCast(effect.inputs.len));
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
        try self.executeInstructions(quotation.instructions);

        // If tail call is pending, skip the stack-effect validation and propagate upward
        if (self.tail_call_instructions != null) {
            return;
        }

        if (quotation.effect) |effect| {
            const depth_after = self.stack.depth();
            const expected_delta: i64 = @as(i64, @intCast(effect.outputs.len)) - @as(i64, @intCast(effect.inputs.len));
            const actual_delta: i64 = @as(i64, @intCast(depth_after)) - @as(i64, @intCast(depth_before));

            if (expected_delta != actual_delta) {
                self.captureQuotationEffectMismatch(effect.*, expected_delta, actual_delta);
                return primitives.InterpreterError.StackEffectMismatch;
            }
        }
    }

    /// End benchmark profiling, capture the call stack, pop the call frame,
    /// and propagate the error.
    fn wordErrorCleanup(self: *Context, name: []const u8, err: anyerror) anyerror {
        if (self.benchmark) |b| b.endWordProfile(self.allocator, name);
        self.captureCallStackOnError(err);
        self.popCallFrame();
        return err;
    }

    /// Validate the stack effect (if declared), end benchmark profiling with
    /// peak-depth update, and pop the call frame.
    fn wordSuccessCleanup(self: *Context, name: []const u8, stack_effect: ?StackEffect) !void {
        if (stack_effect) |effect| {
            const depth_after = self.stack.depth();
            if (depth_after < effect.outputs.len) {
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
    fn popModuleDepsFrameTraced(self: *Context, mod: *const value_mod.Module) void {
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
    fn consumePropagatedTailCall(self: *Context, name: []const u8) anyerror!void {
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
    fn executeInstructions(self: *Context, instructions: []const Instruction) anyerror!void {
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
                    if (self.benchmark) |b| {
                        b.recordCallWord();
                        b.beginWordProfile();
                    }

                    if (self.lookupWord(name)) |word| {
                        self.pushCallFrame(name, instr.line, instr.column);
                        self.traceWordExecution(name, instr);

                        if (word.stack_effect) |effect| {
                            self.validateParameterEffects(&effect) catch |err|
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
                                const dispatched = dispatch_helpers.tryDispatchGeneric(self, name) catch |err|
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
                                    if (func(self)) |_| {
                                        try self.wordSuccessCleanup(name, word.stack_effect);
                                    } else |err| {
                                        return self.wordErrorCleanup(name, err);
                                    }
                                },
                            }
                        } else {
                            const result = blk: {
                                if (word.source_module) |mod| {
                                    switch (word.action) {
                                        .compound => |instrs| {
                                            self.pushModuleDepsFrame(mod) catch |e| break :blk @as(anyerror!void, e);
                                            defer self.popModuleDepsFrameTraced(mod);
                                            break :blk self.executeQuotation(.{ .instructions = instrs });
                                        },
                                        .native => |func| break :blk func(self),
                                    }
                                } else {
                                    break :blk switch (word.action) {
                                        .native => |func| func(self),
                                        .compound => |instrs| self.executeQuotation(.{ .instructions = instrs }),
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
    // The quotation can produce outputs, which is allowed
    const alloc = ctx.quotationAllocator();
    const instrs = try alloc.alloc(Instruction, 4);
    instrs[0] = .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 };
    instrs[1] = .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 42 } }, .line = 0 },
    } } } }, .line = 2 };
    instrs[2] = .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = &[_]Instruction{} } } }, .line = 3 };
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
