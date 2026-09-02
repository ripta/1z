const std = @import("std");
const builtin = @import("builtin");
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
const scheduler_mod = @import("scheduler.zig");
const Scheduler = scheduler_mod.Scheduler;
const WorkerPool = @import("worker.zig").WorkerPool;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const types_mod = @import("primitives/types.zig");
const Capability = types_mod.Capability;
const SandboxSpec = types_mod.SandboxSpec;
const primitives = @import("primitives.zig");
const parser = @import("parser.zig");
const BenchmarkStats = @import("benchmark.zig").BenchmarkStats;
const MemoryLimitAllocator = @import("memory_limit.zig").MemoryLimitAllocator;
const ProfileStats = @import("profile.zig").ProfileStats;
const StatementProcessor = @import("statement.zig").StatementProcessor;

const trace_mod = @import("trace.zig");
const jit_dump = @import("jit_dump.zig");
const TraceConfig = trace_mod.TraceConfig;

const pascalToKebabRuntime = @import("primitives/errors.zig").pascalToKebabRuntime;
const markers_mod = @import("primitives/markers.zig");
const HookRegistry = @import("primitives/hooks.zig").HookRegistry;

const stack_effect_mod = @import("stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;
const StackEffectParam = stack_effect_mod.StackEffectParam;

const lock_order = @import("lock_order.zig");
const LockOrderTracker = lock_order.LockOrderTracker;

const QuotationStampStore = @import("quotation_stamp_store.zig").QuotationStampStore;
const QuotationSourceStore = @import("quotation_source_store.zig").QuotationSourceStore;
const CarryableScopeGate = @import("carryable_scope_gate.zig").CarryableScopeGate;
const closure_body_registry = @import("closure_body_registry.zig");
const LoadLock = @import("load_lock.zig").LoadLock;
const ReifiedDecodeCache = @import("reified_decode_cache.zig").ReifiedDecodeCache;

const signal = @import("signal.zig");
const control = @import("primitives/control.zig");
const nativeSuppressChecksValidator = @import("effect_inference.zig").nativeSuppressChecksValidator;
const helpers = @import("primitives/helpers.zig");

// The JIT is unavailable on freestanding targets (no `ir` link, see build.zig); every call site
// that would reach into ir_codegen.zig is comptime-gated below and falls back to plain
// interpretation, which is already what happens at runtime on every target when compile_mode
// stays .off (the default, and the only mode reachable without a CLI --compile flag).
const is_freestanding = builtin.os.tag == .freestanding;

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
///
/// `definition_located` marks a frame positioned at the word's definition rather than a call
/// site. A compiled entry trap pushes one because it cannot know whether its call site also
/// queued a frame; when one did, the capture fold drops the definition-located twin so the word
/// renders once, at the call site, matching the interpreter.
pub const CallFrame = struct {
    word_name: []const u8,
    source: []const u8,
    line: usize,
    column: usize = 0,
    definition_located: bool = false,
    /// The named word's own declared effect, set at push from the definition in hand, so the
    /// error renderer never resolves `word_name` through a ladder a shadowing binding can answer.
    stack_effect: ?*const StackEffect = null,
};

/// ParameterFrame holds parameter bindings for dynamic scoping.
/// Each frame is a mapping from parameter name to its bound value.
pub const ParameterFrame = std.StringHashMapUnmanaged(Value);

/// LocalFrame holds word definitions for lexical scoping within quotations.
/// Each frame is a mapping from word name to its definition.
pub const LocalFrame = std.StringHashMapUnmanaged(WordDefinition);
const WordDefinition = @import("dictionary.zig").WordDefinition;

/// A module's pre-built deps-and-words map, hung off the `Module` and cloned
/// into a fresh per-task frame by `pushModuleDepsFrame` on each module-word call.
///
/// Cloning the backing directly avoids re-hashing every entry, the cost the
/// per-call rebuild used to pay. The contents are a pure function of the module,
/// so the template is immutable after build and shared read-only across tasks.
pub const DepsFrameTemplate = struct {
    frame: LocalFrame,
};

/// The purposes a `LocalFrame` serves on the shared `local_frames` stack:
///
/// - `lexical` frames hold genuine top-level / quotation-local words. The closure-local bindings
///    a quotation legitimately closes over.
/// - `module_deps` frames are the transient frames that `pushModuleDepsFrame` puts up during a
///    module's tail calls. They hold that module's deps and words and are recoverable from the
///    module pointer alone.
///
/// The tag exists so lexical-closure capture can snapshot only the small lexical frames and
/// reference the (large) module by pointer, rather than deep-copying a module-deps frame on every
/// quotation creation.
pub const FrameKind = enum { lexical, module_deps };

/// What `.module_deps` frames the executing body may resolve bare words against, so a stored
/// quotation `call`ed while an unrelated library's frame is live does not resolve against it.
///
/// A `.module_deps` frame for module M is visible iff M is the body's own defining module or M was
/// ambient (a live deps frame) when the body was created. A body with neither reference sees no
/// deps frame and falls through to the durable import frame.
pub const ModuleDepsVisibility = struct {
    deps_modules: []const *const value_mod.Module,
    defining_module: ?*const value_mod.Module,

    fn admits(self: ModuleDepsVisibility, module: *const value_mod.Module) bool {
        if (self.defining_module) |dm| {
            if (dm == module) return true;
        }
        for (self.deps_modules) |m| {
            if (m == module) return true;
        }
        return false;
    }
};

/// A synthetic scope module is an ephemeral scope snapshot, not a loaded module: `<local-scope>`
/// (`private{ }` / `local-scope`) and `<scope>` (`current-scope`). By convention these are the only
/// module names prefixed with `<`; a loaded module's name is a file path and never is.
///
/// A body defined in one is exempt from the `.module_deps` visibility filter. It is a helper
/// lexically nested in a real module, and its scope module deliberately captures only imports and
/// sibling privates, not the enclosing module's own public words -- those resolve against the
/// enclosing frame, which the filter would otherwise reject. A private helper is never a stored
/// foreign quotation, so resolving it unfiltered, as before this filter existed, cannot reopen the
/// shadowing bug.
pub fn isSyntheticScopeModule(module: ?*const value_mod.Module) bool {
    const m = module orelse return false;
    return m.name.len > 0 and m.name[0] == '<';
}

/// The lexical scope captured at a quotation's creation site, keyed off the quotation body's
/// instruction-slice pointer.
///
/// Bare words inside the quotation resolve against this, not the live frame stack the quotation
/// happens to execute against, so a closure means the same thing wherever it runs.
///
/// `lexical_frames` is an owned snapshot of the genuine lexical frames live at creation.
///
/// `deps_modules` is an owned snapshot of the modules whose `.module_deps` frame was live at
/// creation. Bare-word resolution consults it (via `ModuleDepsVisibility`) to admit a frame the
/// quotation legitimately closed over while rejecting a foreign one. A quotation created with no such
/// frame live records no entry at all; resolution treats that absence as an empty ambient-deps set
/// and leans on the entry's `defining_module` stamp to tell a module-less quotation apart from a
/// word body.
///
/// Module-scope resolution for a quotation's own defining module still flows through the entry's
/// `defining_module` stamp; `deps_modules` covers only frames ambient at creation.
///
/// Two lifetimes share this type. A map-owned ("tier-1") scope lives in a `Context`'s
/// `quotation_scope_info`, heap-allocated on that context's durable allocator, and is
/// refcounted: `captureQuotationScope` supersedes it with a fresh capture on every push of the
/// same body, freeing the old one once every in-flight reader has released it (an
/// `executeInstructions` call holding it for the call's duration, or a descendant task reached
/// through `findCapturedScopeForBody`'s ancestor walk).
///
/// A closure-owned ("tier-2") scope is an independent deep copy the owning closure releases from
/// its destroy path when its `owns_scope` flag is set (its creation reference is the only one, so
/// that release frees it). `promoteToClosure` and `curry`/`compose` (`functional.zig`) build one
/// of these via `dupeCapturedScope` whenever they hand a scope to something that can meaningfully
/// outlive the map's current entry for the body it came from -- see `promoteToClosure`'s doc
/// comment for why copying here is load-bearing, not merely defensive.
/// `findCapturedScopeForBody` builds its copy on whatever allocator the caller passes, so its
/// result is tier-2 when `curry`/`compose` pass the context allocator for a closure to own and
/// tier-1 when the body-entry fill passes the durable allocator and installs the copy into the
/// map. A task-boundary deep copy's scope is tier-2 as well, owned by the copied closure.
///
/// `retain`/`release` mirror `container_backing.ContainerHeader`'s pattern, minus the mutex --
/// `lexical_frames` is immutable after construction, so no lock is needed for reads.
pub const CapturedScope = struct {
    lexical_frames: []LocalFrame,
    deps_modules: []const *const value_mod.Module = &.{},
    refcount: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    allocator: Allocator,

    /// Increment the refcount. Cheap, monotonic; safe to call from any thread that already
    /// holds a live reference.
    pub fn retain(self: *CapturedScope) void {
        _ = self.refcount.fetchAdd(1, .monotonic);
    }

    /// Decrement the refcount. On the last drop, drop each binding's owning reference, then free
    /// `lexical_frames` and this scope itself using the allocator it was built with.
    ///
    /// `.acq_rel` ordering on the decrement gives release semantics to any preceding writes the
    /// dropping thread made, and acquire semantics on the returned previous value so the freeing
    /// thread observes every other holder's prior reads as complete.
    pub fn release(self: *CapturedScope) void {
        const prev = self.refcount.fetchSub(1, .acq_rel);
        std.debug.assert(prev != 0);
        if (prev == 1) {
            for (self.lexical_frames) |*f| {
                releaseFrameBindings(f);
                f.deinit(self.allocator);
            }
            self.allocator.free(self.lexical_frames);
            self.allocator.free(self.deps_modules);
            self.allocator.destroy(self);
        }
    }

    /// Snapshot the current refcount. For diagnostics and tests only; the value is racy in the
    /// presence of other holders.
    pub fn refcountValue(self: *const CapturedScope) u32 {
        return self.refcount.load(.monotonic);
    }
};

/// Claim a second owning reference to every bound value in a freshly cloned frame.
///
/// A frame clone outlives the frame it was copied from, so it cannot borrow.
///
/// Retaining the whole clone once its entries are copied, rather than per entry as they go, keeps a
/// half-built clone's error path free of releases.
pub fn retainFrameBindings(frame: *const LocalFrame) void {
    var it = frame.iterator();
    while (it.next()) |e| {
        if (ownedBinding(e.value_ptr.*)) |v| container_backing.retainValue(v);
    }
}

/// Drop the owning references a frame's bindings hold, for a frame that is about to die.
pub fn releaseFrameBindings(frame: *const LocalFrame) void {
    var it = frame.iterator();
    while (it.next()) |e| {
        if (ownedBinding(e.value_ptr.*)) |v| container_backing.releaseValue(v);
    }
}

/// The value `def` owns a reference to, or null when it owns none.
///
/// The action tag is checked rather than trusted from `owns_literal` alone: a definition can be
/// copied and rewritten to another action, and reading an inactive union field would panic in a
/// safe build and read garbage in a fast one.
fn ownedBinding(def: WordDefinition) ?Value {
    if (!def.owns_literal) return null;
    return switch (def.action) {
        .literal => |v| v,
        .native, .host_callback, .compound => null,
    };
}

/// Everything resolution knows about one quotation/word body, keyed in `quotation_scope_info` by
/// the body's instruction-slice pointer.
///
/// The two halves have independent writers and lifetimes. The authoritative defining-module
/// stamp lives in the process-shared `quotation_stamp_store`; `defining_module` here is a
/// per-context read-through cache of it, filled from the store whenever an entry is created, so
/// it is authoritative -- a null included -- whenever the entry exists. The one rewrite is
/// `stampQuotationBodies`, which repairs a null cached before it stamped the store. `scope` is
/// recorded at quotation push and closure execution, inherited from an ancestor context's map at
/// body entry, refcounted, and superseded freely. They share one entry so the body-entry hot path
/// pays a single map probe for both.
pub const QuotationScopeInfo = struct {
    defining_module: ?*const value_mod.Module = null,
    scope: ?*CapturedScope = null,
};

/// Compute the constant-per-word `ExecFlags` from a definition's markers and
/// action. Called at definition finalization so the flags ride the by-value
/// execution copy that `executeResolvedWord` reads on the hot path.
fn computeExecFlags(def: WordDefinition) dict_mod.ExecFlags {
    var flags: dict_mod.ExecFlags = .{};
    for (def.markers) |mk| {
        if (markers_mod.isGenericMarker(mk)) flags.is_generic = true;
        if (mk == &markers_mod.recursive_non_tco_marker) flags.recursive_non_tco = true;
        if (markers_mod.isStackRecursiveMarker(mk)) flags.stack_recursive = true;
    }
    flags.empty_compound_body = switch (def.action) {
        .compound => |b| b.len == 0,
        .native, .host_callback, .literal => false,
    };
    flags.skip_type_validation = flags.is_generic and flags.empty_compound_body;
    if (def.stack_effect) |eff| {
        for (eff.inputs) |param| {
            if (param.quotation_effect != null) flags.has_param_effects = true;
            if (param.type_annotation != null) flags.has_type_annotations = true;
        }
    }
    return flags;
}

/// Whether a definition's marker slice carries the `generic` marker.
fn markersContainGeneric(markers: []const *value_mod.Marker) bool {
    for (markers) |mk| {
        if (markers_mod.isGenericMarker(mk)) return true;
    }
    return false;
}

/// PragmaRegistration holds metadata for a registered pragma key.
/// If both validators are null, the pragma accepts only boolean values.
/// If validator is a quotation, it is called with the value on the stack
/// and must push validated_value t (success) or error_msg f (failure).
/// If native_validator is set, it is called instead of the quotation validator
/// with the same protocol.
pub const PragmaRegistration = struct {
    validator: ?value_mod.Quotation = null,

    /// The closure behind `validator`, for a body it owns. Borrowed: registration parked the
    /// owning reference on the dictionary's teardown list and kept only the view, so the pointer
    /// is what carries the body's captured scope and defining module to the call below.
    validator_owner: ?*const value_mod.Closure = null,

    native_validator: ?*const fn (*Context) anyerror!void = null,
};

/// PragmaFrame holds pragma values for the current file scope.
pub const PragmaFrame = std.StringHashMapUnmanaged(Value);

/// TypeRegistryFrame holds type descriptor and enum registry entries for
/// a single scope. Pushed/popped by `with-isolation` to enable rollback
/// of type registrations.
pub const TypeRegistryFrame = struct {
    type_descriptors: std.StringHashMapUnmanaged(*value_mod.TypeDescriptor) = .{},
    // Insertion-ordered so first-match by-name scans over variants resolve
    // deterministically; a pointer-keyed hash map iterates in allocation-address
    // order, which varies run to run.
    enum_registry: std.AutoArrayHashMapUnmanaged(*const value_mod.TypeValue, []const *const value_mod.VirtualType) = .{},

    pub fn deinit(self: *TypeRegistryFrame, allocator: Allocator) void {
        self.type_descriptors.deinit(allocator);
        self.enum_registry.deinit(allocator);
    }
};

pub const ParameterizedTypeKey = struct {
    base: *const value_mod.TypeValue,
    /// Ordered parameter tuple bound to the base. Position is significant, so
    /// the tuple is compared positionally and never sorted.
    params: []const *const value_mod.TypeValue,
};

pub const ParameterizedTypeKeyContext = struct {
    pub fn hash(_: @This(), key: ParameterizedTypeKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&@intFromPtr(key.base)));
        h.update(std.mem.asBytes(&key.params.len));
        for (key.params) |param| {
            h.update(std.mem.asBytes(&@intFromPtr(param)));
        }
        return h.final();
    }

    pub fn eql(_: @This(), a: ParameterizedTypeKey, b: ParameterizedTypeKey) bool {
        if (a.base != b.base or a.params.len != b.params.len) return false;
        for (a.params, b.params) |a_param, b_param| {
            if (a_param != b_param) return false;
        }
        return true;
    }
};

pub const StructDescriptorKey = struct {
    fields: []const []const u8,
    field_types: []const ?value_mod.ConstraintCombinator.Element = &.{},
    mutable: bool,
};

/// Pointer carried by a constraint element, tagged by kind, so a field
/// annotation can be hashed and compared by pointer identity. A null element
/// (untyped field) hashes to 0/0.
fn elementIdentity(element: ?value_mod.ConstraintCombinator.Element) struct { tag: u8, ptr: usize } {
    const e = element orelse return .{ .tag = 0, .ptr = 0 };
    return switch (e) {
        .type => |tv| .{ .tag = 1, .ptr = @intFromPtr(tv) },
        .protocol => |pd| .{ .tag = 2, .ptr = @intFromPtr(pd) },
        .combinator => |cc| .{ .tag = 3, .ptr = @intFromPtr(cc) },
    };
}

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
            const id = elementIdentity(field_type);
            h.update(&[_]u8{id.tag});
            h.update(std.mem.asBytes(&id.ptr));
        }
        return h.final();
    }

    pub fn eql(_: @This(), a: StructDescriptorKey, b: StructDescriptorKey) bool {
        if (a.mutable != b.mutable or a.fields.len != b.fields.len or a.field_types.len != b.field_types.len) return false;
        for (a.fields, b.fields) |a_field, b_field| {
            if (!std.mem.eql(u8, a_field, b_field)) return false;
        }
        for (a.field_types, b.field_types) |a_field_type, b_field_type| {
            const ai = elementIdentity(a_field_type);
            const bi = elementIdentity(b_field_type);
            if (ai.tag != bi.tag or ai.ptr != bi.ptr) return false;
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
/// The constraint pointer is the durable handle to the obligation; resolving the type's `TypeValue`
/// happens at validation time. A bare protocol bound carries a `ProtocolDescriptor`; a combinator
/// bound (`comparable & stringable`, `fixnum | comparable`) carries a `ConstraintCombinator`.
pub const ProtocolObligation = struct {
    type_name: []const u8,
    constraint: Constraint,

    pub const Constraint = union(enum) {
        protocol: *const value_mod.ProtocolDescriptor,
        combination: *const value_mod.ConstraintCombinator,
    };
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

/// Key for the per-context memo of an annotated quotation parameter's inferred stack delta: one
/// entry per call site and parameter position.
///
/// `body` is the caller's instruction-slice pointer and `index` the call's position in it. `param`
/// is the parameter's position among the callee's concrete inputs, so a word with two annotated
/// quotation parameters holds two entries at one site.
pub const ParamEffectSiteKey = struct {
    body: usize,
    index: usize,
    param: usize,
};

pub const ParamEffectSiteKeyContext = struct {
    pub fn hash(_: @This(), key: ParamEffectSiteKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&key.body));
        h.update(std.mem.asBytes(&key.index));
        h.update(std.mem.asBytes(&key.param));
        return h.final();
    }

    pub fn eql(_: @This(), a: ParamEffectSiteKey, b: ParamEffectSiteKey) bool {
        return a.body == b.body and a.index == b.index and a.param == b.param;
    }
};

/// A memoized inference, guarded by what it was derived from.
///
/// `arg_body` is the argument quotation's instruction-slice pointer. `effect` is the callee's boxed
/// effect, whose inputs prefill the inference's shadow stack, so a different callee resolving at
/// the same site cannot read a delta derived under another prefill. A read that fails either
/// compare falls through to the walk.
pub const ParamEffectEntry = struct {
    arg_body: usize,
    effect: *const StackEffect,
    delta: i64,
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
};

pub const AotQuotationFnTable = struct {
    table: [*]const ?*const anyopaque,
    size: u32,
};

/// A deferred parse-time emission requested by a parse-time word, drained in
/// order by `executeParseTimeWord` after the word runs. `emit-call` records a
/// `.call`; `emit-body` records a `.body`. A single ordered queue keeps
/// interleaved emissions in their requested order.
pub const DeferredEmission = union(enum) {
    /// A word name to emit as a `call_word` / `call_word_direct` instruction.
    call: []const u8,
    /// A quotation's instructions to splice inline into the parse stream.
    body: SplicedBody,

    /// A quotation body queued for splicing, and whether `emit-body` took a reference on its
    /// container literals on the splice's behalf.
    ///
    /// It does so when the source is a closure, which owns those literals and outlives the
    /// emission. The splice hands that reference to the enclosing body's own registered release.
    /// Every other drain outcome -- a rollback that discards the emission, or the array context
    /// that runs the body instead of copying it -- gives the reference back itself.
    pub const SplicedBody = struct {
        instructions: []const Instruction,
        retained_literals: bool,
    };
};

/// The base scope an AOT binary bakes for the redefinition guards: the names the interpreted
/// probes find in the frames below the durable floor, each with its defining source and marker
/// bits. Three parallel arrays borrowed from the binary's rodata, sorted by name at emission.
/// Flag bit 0 is the generic marker, bit 1 the const marker.
pub const AotBaseScope = struct {
    names: [*]const [*:0]const u8,
    sources: [*]const ?[*:0]const u8,
    flags: [*]const u8,
    count: u32,
};

/// The Context holds all interpreter state.
pub const Context = struct {
    stack: Stack,
    dictionary: Dictionary,
    /// Heap-boxed, so the `Allocator` handle it hands out survives a by-value `Context` copy.
    ///
    /// `quotationAllocator` returns an `Allocator` whose `ptr` is this arena's address. An inline
    /// arena would make that address part of the enclosing `Context`, so a constructor that builds
    /// a context, allocates through it, and then returns the context by value would strand every
    /// handle taken before the return. Boxing keeps the identity stable wherever the struct moves.
    arena: *std.heap.ArenaAllocator,
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
    /// Per-frame kind tag, kept index-parallel with `local_frames`. Every push and pop of a local
    /// frame maintains both arrays together; the debug-only `assertFrameKindsParity` checks the
    /// lengths stay equal.
    local_frame_kinds: std.ArrayListUnmanaged(FrameKind) = .{},
    /// The module each `.module_deps` frame was pushed for, kept index-parallel with `local_frames`
    /// and `local_frame_kinds`. A `.lexical` frame stores `null`. `captureQuotationScope` reads this
    /// to snapshot which modules had a live deps frame at a quotation's creation, so bare-word
    /// resolution can later reject a foreign module's frame that merely happens to be live where the
    /// quotation runs. Module pointers are process-lifetime stable, so a cloned entry stays valid
    /// across a spawn boundary.
    local_frame_modules: std.ArrayListUnmanaged(?*const value_mod.Module) = .{},
    /// Count of live `.module_deps` frames on the stack. A fast-path gate for
    /// `captureQuotationScope`: when zero, a pushed quotation has no ambient deps frame to snapshot,
    /// so a quotation that also closes over no lexical binding needs no capture at all and the push
    /// stays on the pre-capture fast path. Maintained at the module-deps push, pop, and spawn-clone
    /// sites, index-free of the frame arrays since only the count matters.
    live_module_deps_frames: usize = 0,
    /// The deps-visibility filter of the body currently executing, saved and restored around each
    /// `executeInstructions` call.
    ///
    /// `defineWordLocked` targets the topmost frame this filter admits, so a body's runtime
    /// definitions land in a frame the body's own filtered lookups can see. A body whose filter
    /// rejects the top `.module_deps` frame would otherwise define its named locals into that
    /// frame and immediately fail to resolve them.
    active_deps_vis: ?ModuleDepsVisibility = null,
    /// Count of live transient lexical frames (above `import_frame_index`, kind `.lexical`) that
    /// currently hold at least one definition. A fast-path gate for `captureQuotationScope`: when
    /// zero, no quotation push has anything to close over, so the capture scan is skipped.
    ///
    /// Maintained task-privately at the define, remove, pop, and spawn-clone sites, so no atomic is
    /// needed. A wrong-high count only falls through to the existing scan, so the sole correctness
    /// duty is to never undercount.
    nonempty_transient_lexical_frames: usize = 0,
    /// Tokenizer for parse-time word access (set during parsing, null otherwise)
    parse_tokenizer: ?*Tokenizer = null,
    /// Deferred emissions requested by parse-time words via `emit-call` /
    /// `emit-body`, drained in order after the parse-time word runs.
    parse_time_deferred_emissions: std.ArrayListUnmanaged(DeferredEmission) = .{},
    /// Optional benchmark stats (null when benchmarking is disabled)
    benchmark: ?*BenchmarkStats = null,
    /// Optional word-attributed profile stats (null when --profile is unset)
    profile: ?*ProfileStats = null,
    /// True when this Context owns `profile` and must free it in `deinit`. Task Contexts own a
    /// fresh buffer; the main context borrows one owned by main.zig.
    profile_owned: bool = false,
    /// Counters for unique VirtualType/StructType allocations, used by
    /// --benchmark to report prelude output inventory.
    virtual_type_count: usize = 0,
    struct_type_count: usize = 0,
    /// Current source file name for error reporting (defaults to "<repl>")
    current_source: []const u8 = "<repl>",
    /// Resolved path of the user startup file, once one has been opened. Borrowed from the
    /// context arena.
    ///
    /// An environment-only pragma compares `current_source` against this to tell a set the user
    /// made for themselves from one a source file makes for its readers.
    startup_source: ?[]const u8 = null,
    /// Tail call target for TCO, which is set by executeInstructions and consumed by executeQuotation
    tail_call_instructions: ?[]const Instruction = null,
    /// Module whose deps frame should be pushed for the tail call target.
    /// Set alongside tail_call_instructions when the tail-called word has a source_module.
    tail_call_module: ?*const value_mod.Module = null,
    /// Source file of the tail call target, for execution-source tracking.
    /// Set alongside tail_call_instructions when the tail-called word has a source_file.
    tail_call_source: ?[]const u8 = null,
    /// Closure behind the tail call target's body, for a body it owns. Set alongside
    /// `tail_call_instructions` from the callee's `body_owner`, so a `;`- or `>module`-adopted
    /// closure body reached in tail position resolves off its own value rather than the caller's.
    tail_call_body_owner: ?*const value_mod.Closure = null,
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
    /// Index of the durable import frame: the top of the stable scope a descendant context may
    /// read through the ancestor walk, and the point the spawn-time frame clone starts above.
    ///
    /// Mirrors `import_frame_index` at every site except a runtime load, which moves only the
    /// import target. The load's transient frame stays above this floor, invisible to other
    /// tasks, until the finalized module publishes through the cache. Written only at
    /// pre-worker-pool or single-context sites, so cross-task readers race with nothing.
    durable_frame_floor: ?usize = null,
    /// Name of the innermost native primitive whose Zig function is running, with no compiled-code
    /// or host-callback frame in between. Null outside one.
    ///
    /// Bookkeeping for `assertDefiningNativeDeclared`, which is what keeps the `defines_word`
    /// table complete. Written by `withCurrentNative` at every site that invokes a `NativeFn`.
    ///
    /// Cleared on entry to compiled code and to a host callback. Neither runs through a native the
    /// assertion could name, so a definition made under one is left unattributed.
    ///
    /// The field is present in every build, but only a Debug build writes or reads it.
    current_native: ?[]const u8 = null,
    /// True while a `load` call is executing. Blocking primitives (yield, sleep, await,
    /// await-all, send, receive, select) check this flag and throw an error to prevent yielding
    /// mid-load, which would park the loader with the module's globally visible registry writes
    /// half-done.
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
    /// The file whose tokens the parser is currently reading, when that differs from
    /// `current_source`. Body stamps read this first.
    ///
    /// The outermost parse-time invocation sets it, because executing the parse-time word's body
    /// points `current_source` at the word's defining file while the parser keeps reading the
    /// invoking file (e.g. through `parse-until`). A nested invocation inherits it. A nested parse
    /// session reading a different source -- a module load, an eval string -- saves and clears it
    /// so its own `current_source` governs. Null outside parse-time invocations.
    parse_stamp_source: ?[]const u8 = null,
    /// Source line of the current parse-time word invocation (file-relative).
    /// Set by executeParseTimeWord with save/restore for nesting.
    parse_time_source_line: usize = 0,
    /// Source column of the current parse-time word invocation.
    parse_time_source_column: usize = 0,
    /// Declaration site of the type definition currently generating words.
    ///
    /// Set with save/restore by `define-struct`, `define-enum`, `define-virtual`, and
    /// `define-protocol` from the `src-loc` their descriptor carries, and read by `defineWord` for
    /// every word they generate, including the ones they generate through a shared helper. Without
    /// it a generated word records the prelude quotation that ran the `define-*` native.
    generated_src_loc: ?dict_mod.GenSrcLoc = null,
    /// Resolved build-target OS / architecture for the parse-time `target-os`
    /// and `target-arch` accessors. Defaults to the host's `builtin.target`,
    /// which is correct for `1z run` / `eval` / the REPL and non-cross AOT
    /// builds. An AOT build with `--target` overrides these before the module
    /// graph is frozen, so a parse-time accessor reads the build target rather
    /// than the host under cross-compilation.
    target_os: std.Target.Os.Tag = builtin.os.tag,
    target_arch: std.Target.Cpu.Arch = builtin.cpu.arch,
    /// Source file of the file currently being loaded by nativeLoadImpl.
    /// Set and restored via save-restore in nativeLoadImpl so that runtime words,
    /// like `reexport`, which execute inside the loaded file's body, can record
    /// the correct import source, even after execution-source tracking updates
    /// current_source to their own defining file.
    load_file_source: ?[]const u8 = null,
    /// The module currently being assembled by nativeLoadImpl, available while
    /// its file body executes so method registrations can record their defining
    /// module. Set and restored via save-restore in nativeLoadImpl. Null outside
    /// a module load (top-level script, REPL).
    loading_module: ?*const value_mod.Module = null,
    /// Offset to convert tokenizer-relative line numbers to file-relative.
    /// The tokenizer restarts at line 1 for each statement. This offset is
    /// the file line where the current statement starts minus 1.
    parse_line_offset: usize = 0,
    /// Accumulated import records from `use` and `reexport` calls.
    import_history: std.ArrayListUnmanaged(Value) = .{},
    /// Cache of loaded modules keyed by canonical file path.
    /// Prevents redundant loading when multiple files `use` the same module.
    /// Stored as an M{} value so it can be exposed as a dynamic parameter.
    ///
    /// A load inserts while resolution scans and cache probes read on every worker, so every
    /// runtime access takes the backing's header mutex around its probe or iteration. The startup
    /// image loader and the AOT build-time passes run before scheduler workers exist and access
    /// the map bare.
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
    /// Used by finalizeErrorDetails for the innermost frame's message.
    pending_error_message: ?[]const u8 = null,
    /// Pending error hint set by primitives before returning an error.
    /// Consumed by finalizeErrorDetails for the innermost frame's hint.
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
    /// The error state the failing callback produced, lifted off the live channels by
    /// `detachErrorStateForCallback` and re-installed by whichever drain takes the courier.
    callback_error_state: ?DetachedErrorState = null,
    /// True while a callback error-hook is being invoked. A hook that never
    /// returns (a longjmp such as lua_error) leaves it set, marking the stashed
    /// callback error as owned by the C library's error protocol: the automatic
    /// drains skip it, and the binding reconciles it against the library's own
    /// status via take-callback-error.
    callback_error_hook_raised: bool = false,
    /// Optional debugger. When non-null, the execution loop checks whether to
    /// pause before each instruction. When null (the default), the cost is a
    /// single pointer check per instruction.
    ///
    /// TODO(ripta): Consider making this a comptime flag to eliminate the pointer check.
    debugger: ?*debugger_mod.Debugger = null,
    /// Execution tracing configuration, parsed from CLI flags.
    trace: TraceConfig = .{},
    /// Wall-clock no-progress threshold in nanoseconds, tuned by --deadlock-detect[=SECS] and
    /// cleared by --no-deadlock-detect. Null disables both verdicts.
    deadlock_detect_ns: ?i128 = scheduler_mod.startup_deadlock_detect_ns,
    /// Report the bare no-progress stall when the deadlock gate refuses. Opt-in under
    /// --deadlock-detect, because a pool running one long non-yielding task satisfies the
    /// threshold on its own.
    report_stall_verdict: bool = false,
    /// The process-wide memory-cap allocator, so the periodic sampler can read current and peak
    /// live bytes. Null when no cap allocator is active.
    mem_limit: ?*MemoryLimitAllocator = null,
    /// Monotonic counter for assigning unique dispatch IDs to word definitions.
    /// Atomic for future thread-safety requirements.
    next_dispatch_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// The dispatch id each identity-carrying native's entries were registered under, indexed by
    /// `NativeDispatchWord`.
    ///
    /// Populated once by `captureNativeDispatchIds` during init and immutable after; task contexts
    /// inherit the values by copy in `initForTask`. Reading this instead of resolving the native's
    /// name keeps a shadowing binding from capturing the native's entries.
    native_dispatch_ids: std.enums.EnumArray(dispatch_mod.NativeDispatchWord, u32) = std.enums.EnumArray(dispatch_mod.NativeDispatchWord, u32).initFill(0),
    /// Monotonic counter for assigning unique IDs to protocol descriptors.
    /// Atomic for future thread-safety requirements (M:N scheduler).
    next_protocol_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Monotonic counter for assigning unique IDs to constraint combinators.
    /// Atomic for future thread-safety requirements (M:N scheduler).
    next_combinator_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
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
    image_struct_instance_slots: ?[*]?*value_mod.StructInstance = null,
    image_vector_slots: ?[*]?*value_mod.Vector = null,
    image_protocoldescriptor_slots: ?[*]?*const value_mod.ProtocolDescriptor = null,
    image_constraintcombinator_slots: ?[*]?*const value_mod.ConstraintCombinator = null,
    image_typevalue_slot_count: u32 = 0,
    image_struct_type_slot_count: u32 = 0,
    image_marker_slot_count: u32 = 0,
    image_parameter_slot_count: u32 = 0,
    image_tagged_slot_count: u32 = 0,
    image_mutable_map_slot_count: u32 = 0,
    image_struct_instance_slot_count: u32 = 0,
    image_vector_slot_count: u32 = 0,
    image_protocoldescriptor_slot_count: u32 = 0,
    image_constraintcombinator_slot_count: u32 = 0,
    /// One loader-owned `WordSlot` per build-time-resolved call target, addressed by the slot
    /// index a `call_word_module` instruction carries.
    image_call_target_slots: ?[*]?*dict_mod.WordSlot = null,
    image_call_target_slot_count: u32 = 0,
    /// AOT method-dispatch replay table, stashed by `loadIntoContext` and
    /// consumed by `aot_image_loader.replayMethodDispatch` after the
    /// quotation-function table is registered. Stored opaquely to avoid an
    /// import cycle; the loader casts it to `[*]const DispatchEntryDescription`.
    image_dispatch_entry_descriptions: ?*const anyopaque = null,
    image_dispatch_entry_count: u32 = 0,
    /// Defining module per reified quotation literal, keyed by the static
    /// serialized-data pointer `jitPushQuotation` receives. Built once by the
    /// image loader on process-lifetime storage and shared by pointer with
    /// spawned task contexts.
    image_reified_quotation_modules: ?*const std.AutoHashMapUnmanaged(usize, *const value_mod.Module) = null,
    /// Index of the durable entry frame `onez_push_entry_frame` pushed at AOT boot, which holds
    /// the entry file's restored `use` imports. Null on interpreter drivers and embedders, whose
    /// boot never calls the push. Guards the entry-import restore and the replay dispatch_id
    /// patch so neither touches the prelude frame.
    image_entry_import_frame: ?usize = null,
    /// Decoded-instruction cache for reified quotation pushes, keyed by the same static data
    /// pointer. Root-owned and process-shared; slices live on the cache's own arena, so the keys
    /// the decode path stamps into `quotation_stamp_store` are process-lifetime. One decode and
    /// one defining-module stamp per push site serve every context. See `ReifiedDecodeCache`.
    reified_decode_cache: *ReifiedDecodeCache = undefined,
    /// name -> dispatch_id for user generic words, replayed from the AOT image
    /// dispatch-entry table at startup. The AOT runtime keeps user generics
    /// only in compiled form, so `resolveDispatchId` consults this to resolve a
    /// generic by name (e.g. the protocol satisfies-check on a user type).
    /// Keys borrow the image's static strings. Populated only on the context
    /// the loader runs on; reads walk the parent chain.
    aot_generic_dispatch_ids: std.StringHashMapUnmanaged(u32) = .{},
    /// name -> dispatch_id for `struct{`-generated field getters, field setters, and hash
    /// converters, independent of interpreter lexical scope. `struct{` may run in an unrelated
    /// module or script scope each time a field of a given name is first seen, which would
    /// otherwise mint a fresh, disjoint dispatch table per scope for the same generated name
    /// (e.g. two unrelated structs each defining a `tick` field). This registry makes every
    /// occurrence of a given generated name share one dispatch table program-wide, regardless of
    /// which scope's `struct{` happened to define it first. Unrelated to `aot_generic_dispatch_ids`
    /// above, which reconstitutes dispatch_ids lost to AOT image serialization.
    generic_accessor_dispatch_ids: std.StringHashMapUnmanaged(u32) = .{},
    /// Set true when `aot_image_loader.loadIntoContext` has populated
    /// this context from an AOT runtime image. Gates the module-cache
    /// fallback in `lookupWordForExecution` so the fallback only fires
    /// for runtime-image-loaded modules; the loader routes public rows
    /// into `module.words` and private-flagged rows into `module.deps`.
    /// Normal interpreter sessions and `load`-based module loading
    /// leave this false, so the fallback stays inert and module
    /// privacy holds.
    runtime_image_loaded: bool = false,
    /// The freeze-time base scope baked into an AOT binary, registered once at boot by the
    /// generated `main`. The shadow probe's baked rung and the const guard read it, so a
    /// redefinition reports from a binary exactly as it does under `1z run`.
    ///
    /// Null in interpreter sessions, which keeps both readers inert there.
    aot_base_scope: ?AotBaseScope = null,
    /// Pending error from a JIT error-handling callback (recover/cleanup).
    /// Set by the callback when it returns error_propagate status, consumed
    /// by the interpreter dispatch loop.
    jit_pending_error: ?anyerror = null,
    /// Defining source file for the currently executing compiled word.
    /// Used by JIT error callbacks so synthetic frames do not depend on the
    /// mutable runtime current_source.
    jit_trace_source: ?[]const u8 = null,
    /// Frames pended during an error unwind, in unwind order: the raise site first, then
    /// each compiled or interpreted caller as it unwinds.
    ///
    /// finalizeErrorDetails folds the list into error_details at the consumption point
    /// that owns the error.
    jit_pending_trace_frames: std.ArrayListUnmanaged(CallFrame) = .{},
    /// PIC cache mapping instruction slice pointers to their PIC tables.
    /// Lazily populated on first generic dispatch through a compound word body.
    pic_cache: std.AutoHashMapUnmanaged(usize, *PicTable) = .{},
    /// One inferred delta per annotated-quotation-parameter call site.
    ///
    /// Keyed on the caller's body and instruction index, and guarded by the argument body the delta
    /// was derived from. Admits no closure-owned body on either side; `paramEffectSlot` decides.
    ///
    /// Every other body this context runs lives at least as long as the context, and the map dies
    /// with it.
    param_effect_cache: std.HashMapUnmanaged(
        ParamEffectSiteKey,
        ParamEffectEntry,
        ParamEffectSiteKeyContext,
        80,
    ) = .{},
    /// Maps a quotation/word body instruction-slice pointer to everything resolution knows about
    /// the body: the module it was written in and the scope captured where it was created. The
    /// authoritative stamp half lives in the shared `quotation_stamp_store`; this map's stamp
    /// half is a read-through cache of it, filled -- a null included -- whenever an entry is
    /// created, by the body-entry probe on a complete miss and by the scope writers, and
    /// repaired in place by `stampQuotationBodies` for an entry that cached a null before the
    /// stamp. The scope half is populated at quotation push and closure execution, and inherited
    /// from an ancestor context's map by the body-entry fill. One map, so a body entry pays a
    /// single probe for both halves.
    quotation_scope_info: std.AutoHashMapUnmanaged(usize, QuotationScopeInfo) = .{},
    /// Guards `quotation_scope_info` against the one cross-task access it has: a descendant
    /// task reading this context's map through `findCapturedScopeForBody`'s parent walk while this
    /// context's own task inserts into it. It is per-context, so a task inserting into its own map
    /// contends with nothing unless a descendant is walking that exact context, which keeps the
    /// common leaf-task stamp lock-free of cross-task serialization. Self-only reads stay unlocked,
    /// since a context's map has a single writer: its own task.
    captured_scope_mu: std.Thread.Mutex = .{},
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
    /// Interned single-character strings for ASCII codepoints 0..127, each a
    /// stable one-byte slice indexed by its byte value. `>char` and the
    /// single-codepoint string accessors return the shared slice instead of
    /// allocating a fresh single-character string per call, the dominant
    /// allocation in the tokenizer hot path. Strings are immutable and
    /// content-compared, so sharing is transparent. Allocated in the root
    /// arena and inherited by-pointer by task contexts.
    single_char_strings: []const []const u8 = &.{},
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
    /// Mapping from struct name to its canonical StructType, populated when a `struct{ }` is defined.
    /// The runtime-image loader consults this so a compiled `make-struct-instance` reuses the same
    /// StructType the interpreter (prelude) created, rather than allocating a second one whose
    /// `type_val` would be unlinked, which would split struct dispatch identity.
    struct_types_by_name: std.StringHashMapUnmanaged(*value_mod.StructType) = .{},
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
    /// Owned storage for ConstraintCombinator records allocated via
    /// createConstraintCombinator. Each combinator expression produces a fresh
    /// descriptor; the list keeps stable pointers for the lifetime of the
    /// Context and lets deinit release the list header.
    constraint_combinators: std.ArrayListUnmanaged(*value_mod.ConstraintCombinator) = .{},
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
    /// Companion of `bounded_dispatch_trace_names` for combinator-bounded sites,
    /// keyed by combinator descriptor. Combinators are anonymous, so the shared
    /// string names the constraint generically.
    bounded_dispatch_combinator_trace_names: std.AutoHashMapUnmanaged(
        *const value_mod.ConstraintCombinator,
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
    /// Mutable pointer to the root context, captured at task creation. Null on
    /// the root itself; resolve through `rootContext`. `parent_context` is
    /// const and points at the spawning context, which may itself be a task,
    /// so it cannot serve writers that must reach the root.
    root_context: ?*Context = null,
    /// Durable-state target for module loads. Null means self.
    ///
    /// A module load must produce process-lifetime state no matter which
    /// context runs it: the module cache and the quotation-stamp store retain
    /// what the load builds. The load entries point this at the root for the
    /// load's duration, and every writer of teardown-walked or ancestor-walked
    /// state resolves its target through `stateTarget`. A registry added later
    /// joins the redirected unit by following the same rule.
    load_target: ?*Context = null,
    /// RwLock protecting shared registries. Heap-allocated by the root context
    /// and shared by reference to all child task contexts.
    shared_lock: *std.Thread.RwLock = undefined,
    /// Debug-only tracker that asserts lock acquisition respects the ordering
    /// hierarchy in `lock_order.zig`. Heap-allocated by the root context.
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
    /// Process-shared defining-module stamps for quotation bodies, keyed by instruction-slice
    /// pointer. Heap-allocated by the root context and shared by pointer to all child task
    /// contexts.
    ///
    /// A body's defining module outlives any one context, so a per-context map loses it the
    /// moment a spawned task executes a stored quotation. The per-execution captured-scope half
    /// stays in `quotation_scope_info`, which is genuinely per-context.
    quotation_stamp_store: *QuotationStampStore = undefined,
    /// Process-shared source files for parsed bodies, keyed by instruction-slice pointer.
    /// Heap-allocated by the root context and shared by pointer to all child task contexts.
    ///
    /// A body's file is fixed when it is parsed, and a body outlives the context that parsed it
    /// once it is stored in a word or spawned onto a task. So this cannot be a per-context map
    /// either.
    quotation_source_store: *QuotationSourceStore = undefined,
    /// Process-shared set of bodies that have ever had a carryable captured scope installed in
    /// some context's `quotation_scope_info`. Heap-allocated by the root context and shared by
    /// pointer to all child task contexts.
    ///
    /// An absent body cannot have a carryable scope anywhere on the ancestor chain, so a body
    /// entry that misses can skip `findCapturedScopeForBody` rather than locking every ancestor's
    /// `captured_scope_mu` to learn the same thing.
    carryable_scope_gate: *CarryableScopeGate = undefined,
    /// Process-wide lock serializing module loads. Heap-allocated by the root context and
    /// shared by pointer to all child task contexts.
    ///
    /// The load entries hold it for a load's whole duration, across suspension, so only one
    /// load at a time writes the root state a load targets.
    load_lock: *LoadLock = undefined,

    /// Returns true when the instruction sequence ends with a call to `;`,
    /// which means it is a word definition and should be executed even in
    /// check mode.
    pub fn isDefinitionStatement(instrs: []const Instruction) bool {
        if (instrs.len == 0) return false;
        return switch (instrs[instrs.len - 1].op) {
            .call_word => |name| std.mem.eql(u8, name, ";"),
            .call_word_direct, .call_word_module => |slot| std.mem.eql(u8, slot.name, ";"),
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

    /// Pre-allocate the interned single-character strings for ASCII codepoints
    /// 0..127. Each entry is a stable one-byte slice whose content is the byte
    /// itself (ASCII is its own UTF-8 encoding), so `>char` / string `#nth` /
    /// string `#first` can return a shared slice instead of duping. Allocated
    /// in the arena like `builtin_type_array`; freed in bulk at deinit.
    fn initSingleCharStrings(self: *Context) !void {
        const alloc = self.arena.allocator();
        const count = 128;
        const bytes = try alloc.alloc(u8, count);
        const table = try alloc.alloc([]const u8, count);
        for (0..count) |b| {
            bytes[b] = @intCast(b);
            table[b] = bytes[b .. b + 1];
        }
        self.single_char_strings = table;
    }

    /// Return the interned one-byte string for an ASCII byte, or null when the
    /// byte is outside the interned range or the table is unpopulated (in which
    /// case the caller allocates a fresh string).
    pub fn internedAsciiByte(self: *const Context, byte: u8) ?[]const u8 {
        if (byte < self.single_char_strings.len) return self.single_char_strings[byte];
        return null;
    }

    /// Initialize a new interpreter context with an empty stack and primitives.
    /// Note: This does NOT load the prelude. Call loadPrelude() separately.
    pub fn init(allocator: Allocator) Context {
        const arena = allocator.create(std.heap.ArenaAllocator) catch |err| {
            std.debug.panic("Failed to allocate context arena: {any}", .{err});
        };
        arena.* = std.heap.ArenaAllocator.init(allocator);

        var ctx = Context{
            .stack = Stack.init(allocator),
            .dictionary = Dictionary.init(allocator),
            .arena = arena,
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

        // Allocate the shared quotation stamp store on the long-lived allocator; the root
        // context frees it in deinit.
        ctx.quotation_stamp_store = QuotationStampStore.create(allocator) catch |err| {
            std.debug.panic("Failed to allocate quotation stamp store: {any}", .{err});
        };

        // Allocate the shared quotation source store on the long-lived allocator; the root
        // context frees it in deinit.
        ctx.quotation_source_store = QuotationSourceStore.create(allocator) catch |err| {
            std.debug.panic("Failed to allocate quotation source store: {any}", .{err});
        };

        // Allocate the shared carryable-scope gate on the long-lived allocator; the root context
        // frees it in deinit.
        ctx.carryable_scope_gate = CarryableScopeGate.create(allocator) catch |err| {
            std.debug.panic("Failed to allocate carryable scope gate: {any}", .{err});
        };

        // Allocate the shared reified-quotation decode cache on the long-lived allocator; the
        // root context frees it in deinit.
        ctx.reified_decode_cache = ReifiedDecodeCache.create(allocator) catch |err| {
            std.debug.panic("Failed to allocate reified decode cache: {any}", .{err});
        };

        // Allocate the shared module-load lock on the long-lived allocator; the root context
        // frees it in deinit.
        ctx.load_lock = LoadLock.create(allocator) catch |err| {
            std.debug.panic("Failed to allocate load lock: {any}", .{err});
        };

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

        ctx.initSingleCharStrings() catch |err| {
            std.debug.panic("Failed to init single-char strings: {any}", .{err});
        };

        primitives.registerPrimitives(&ctx.dictionary, ctx.arena.allocator(), &ctx.next_dispatch_id) catch |err| {
            std.debug.panic("Failed to register primitives: {any}", .{err});
        };

        primitives.createNativeModule(&ctx.dictionary, ctx.arena.allocator(), &ctx.next_dispatch_id) catch |err| {
            std.debug.panic("Failed to create native module: {any}", .{err});
        };

        ctx.captureNativeDispatchIds();

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

    /// Arm the native-stack overflow guard with the calling OS thread's stack bounds.
    ///
    /// Spawned tasks and the parser coroutine set `stack_high` / `stack_limit` from their own
    /// stack regions, but nothing sets them for runtime execution on the root context, so deep
    /// recursion on the main thread runs off the end of the OS stack and segfaults. The reserve
    /// is an eighth of the stack, matching the task and coroutine guards. A no-op on platforms
    /// with no way to query the current thread's stack region.
    pub fn setStackBoundsFromCurrentThread(self: *Context) void {
        const bounds = currentThreadStackBounds() orelse return;
        self.stack_high = bounds.high;
        self.stack_limit = bounds.low + (bounds.high - bounds.low) / 8;
    }

    /// Create a lightweight Context for a spawned task. Primitives and the prelude are not
    /// registered here. They are resolved at lookup time by walking up the parent_context chain.
    /// Per-task state like the stack, dictionary, and arena are freshly allocated.
    pub fn initForTask(allocator: Allocator, parent: *Context, scheduler: *Scheduler) !Context {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        var ctx = Context{
            .stack = Stack.init(allocator),
            .dictionary = Dictionary.init(allocator),
            .arena = arena,
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
            .report_stall_verdict = parent.report_stall_verdict,
            .mem_limit = parent.mem_limit,
            .current_source = parent.current_source,
            .startup_source = parent.startup_source,
            .current_source_dir = parent.current_source_dir,
            .load_paths = parent.load_paths,
            .stdlib_path = parent.stdlib_path,
            .program_args = parent.program_args,
            .static_ffi_libs = parent.static_ffi_libs,
            .builtin_type_array = parent.builtin_type_array,
            .native_dispatch_ids = parent.native_dispatch_ids,
            .single_char_strings = parent.single_char_strings,
            .dispatch_any_sentinel = parent.dispatch_any_sentinel,
            .dispatch_unary_sentinel = parent.dispatch_unary_sentinel,
            .self_type_sentinel = parent.self_type_sentinel,
            .any_type_sentinel = parent.any_type_sentinel,
        };

        // Share the parent's lock so all tasks use the same RwLock.
        ctx.shared_lock = parent.shared_lock;
        ctx.lock_order_tracker = parent.lock_order_tracker;

        // Chain to the same root as the parent, so a nested spawn still
        // resolves the process-lifetime context a module load targets.
        ctx.root_context = parent.root_context orelse parent;

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
        ctx.image_struct_instance_slots = parent.image_struct_instance_slots;
        ctx.image_vector_slots = parent.image_vector_slots;
        ctx.image_typevalue_slot_count = parent.image_typevalue_slot_count;
        ctx.image_struct_type_slot_count = parent.image_struct_type_slot_count;
        ctx.image_marker_slot_count = parent.image_marker_slot_count;
        ctx.image_parameter_slot_count = parent.image_parameter_slot_count;
        ctx.image_tagged_slot_count = parent.image_tagged_slot_count;
        ctx.image_mutable_map_slot_count = parent.image_mutable_map_slot_count;
        ctx.image_struct_instance_slot_count = parent.image_struct_instance_slot_count;
        ctx.image_vector_slot_count = parent.image_vector_slot_count;
        ctx.image_call_target_slots = parent.image_call_target_slots;
        ctx.image_call_target_slot_count = parent.image_call_target_slot_count;

        // Inherit AOT-emitted quotation code pointer table so quotation
        // literals constructed in the task ctx via `jitPushQuotation`
        // pick up their compiled bodies, matching the parent.
        ctx.aot_quotation_fns = parent.aot_quotation_fns;

        // Share the loader-built reified-quotation module table so a task's
        // `jitPushQuotation` stamps decoded bodies the same way the root does.
        ctx.image_reified_quotation_modules = parent.image_reified_quotation_modules;

        // Share the parent's hook registry so all contexts fire the same hooks.
        ctx.hook_registry = parent.hook_registry;

        // Share the parent's quotation stamp store so a stored quotation executing here resolves
        // against its own defining module. Aliased, never retained: the root owns it.
        ctx.quotation_stamp_store = parent.quotation_stamp_store;

        // Share the parent's quotation source store so a body parsed there keeps its own file in
        // the error frames a raise here produces. Aliased, never retained: the root owns it.
        ctx.quotation_source_store = parent.quotation_source_store;

        // Share the parent's carryable-scope gate so a body marked anywhere is visible here.
        // Aliased, never retained: the root owns it.
        ctx.carryable_scope_gate = parent.carryable_scope_gate;

        // Share the parent's reified-quotation decode cache so a task's `jitPushQuotation`
        // reuses the process-wide decode instead of decoding onto its own arena. Aliased, never
        // retained: the root owns it.
        ctx.reified_decode_cache = parent.reified_decode_cache;

        // Share the parent's module-load lock so loads serialize process-wide. Aliased, never
        // retained: the root owns it.
        ctx.load_lock = parent.load_lock;

        // Inherit the parent's active sandbox, if any. Allocate a copy on the
        // task's arena so the pointer outlives the parent's stack frame.
        if (parent.active_sandbox) |sandbox| {
            const copy = try ctx.arena.allocator().create(SandboxSpec);
            copy.* = sandbox.*;
            ctx.active_sandbox = copy;
        }

        // Push the base type registry frame so a type defined inside the task has a target, the
        // same frame `init` establishes for the primary context.
        //
        // The frame stays empty rather than cloning the parent's, since descriptor lookup already
        // walks `parent_context`. It must also be the task's own frame: a descriptor built here is
        // allocated on the task arena, so registering it into the root's frame would leave a
        // dangling pointer once the task is reaped.
        try ctx.type_registry_frames.append(allocator, .{});

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

        // Clone the parent's in-scope transient local frames at spawn, the same snapshot-at-spawn
        // discipline the parameter environment above uses.
        //
        // The transient frames are those above the parent's durable floor: the floor and below are
        // the durable scope a descendant reaches by walking `parent_context`, while the frames
        // above it (module-deps and combinator frames, any quotation-local definitions they hold,
        // and a runtime load's live import frame) are per-task execution state a descendant has no
        // live window into once cross-context resolution is task-private.
        //
        // A task parent has no durable frame, so all of its frames are transient; the primary
        // context contributes only frames above its floor. In the common case this set is empty,
        // since top-level and word-body definitions land in the stable import frame. A spawn during
        // a runtime load captures the load frame here, so module top-level code that spawns still
        // resolves the module's already-defined words, from a frozen copy rather than the live
        // frame.
        //
        // Per-quotation lexical capture sits in front of this clone: a spawned closure or plain
        // quotation carries its own captured scope, which `executeInstructions` resolves ahead of
        // the frame stack, so a local binding is no longer silently shadowed by an unrelated
        // same-named module word. The clone is therefore not redundant.
        //
        // Captured scope attaches only to a quotation *literal*, so a top-level local *word* whose
        // body references a sibling local (e.g., `net/server`'s handler calling a local word that
        // reads a local channel) still resolves that sibling through the live frame stack. This
        // clone is what keeps that sibling frame live in the spawned task, which captured scope
        // can't cover.
        //
        // A `WordDefinition` borrows its name, effect, markers, and body slice, so the entries copy
        // directly. Its bound value is the one thing it can own, and the clone outlives the frame it
        // came from, so the clone takes references of its own.
        const transient_start = if (parent.durable_frame_floor) |idx| idx + 1 else 0;
        for (parent.local_frames.items[transient_start..], transient_start..) |parent_frame, src_idx| {
            var cloned_frame = LocalFrame{};
            var iter = parent_frame.iterator();
            while (iter.next()) |entry| {
                try cloned_frame.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
            }
            try ctx.local_frames.append(allocator, cloned_frame);
            // Retained after the append, so a failing append leaves no reference stranded on a
            // frame the context never took over.
            retainFrameBindings(&ctx.local_frames.items[ctx.local_frames.items.len - 1]);
            const kind: FrameKind = if (src_idx < parent.local_frame_kinds.items.len)
                parent.local_frame_kinds.items[src_idx]
            else
                .lexical;
            try ctx.local_frame_kinds.append(allocator, kind);

            const frame_module: ?*const value_mod.Module = if (src_idx < parent.local_frame_modules.items.len)
                parent.local_frame_modules.items[src_idx]
            else
                null;
            try ctx.local_frame_modules.append(allocator, frame_module);

            if (kind == .module_deps) ctx.live_module_deps_frames += 1;

            const new_idx = ctx.local_frames.items.len - 1;
            if (ctx.isTransientLexicalFrame(new_idx) and ctx.local_frames.items[new_idx].count() > 0) {
                ctx.nonempty_transient_lexical_frames += 1;
            }
        }

        // Propagate the profile-enabled state without sharing the parent's buffer. Each task
        // records into its own ProfileStats, so concurrent workers never mutate one buffer and
        // each buffer's interval nesting stays consistent.
        if (parent.profile != null) {
            const p = try allocator.create(ProfileStats);
            p.* = .{};
            ctx.profile = p;
            ctx.profile_owned = true;
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

    /// Whether `type_tv` satisfies a constraint element. Thin wrapper over the
    /// protocol satisfies-check so the parser's constraint analysis never has to
    /// import the protocols primitive directly.
    pub fn constraintTypeSatisfies(
        self: *Context,
        type_tv: *const value_mod.TypeValue,
        element: value_mod.ConstraintCombinator.Element,
    ) anyerror!bool {
        return protocols_mod.typeSatisfiesConstraint(self, type_tv, element);
    }

    /// Whether the `allow-uninhabited-constraint` pragma is set and truthy in
    /// the current scope. When true, the constraint analyzer demotes its
    /// fatal uninhabited-constraint errors to warnings.
    pub fn pragmaAllowsUninhabited(self: *const Context) bool {
        const v = self.getPragma("allow-uninhabited-constraint") orelse return false;
        return switch (v) {
            .boolean => |b| b,
            else => true,
        };
    }

    /// Whether the code executing right now may set an environment-only pragma. True at a REPL
    /// prompt and inside the user startup file, false everywhere else, source files included.
    ///
    /// The comparison is against the startup path rather than a flag saying the startup file is
    /// running, because a module the startup file loads points `current_source` at the module. A
    /// module is a source file whoever loads it.
    pub fn pragmaEnvironmentSetSite(self: *const Context) bool {
        if (std.mem.eql(u8, self.current_source, "<repl>")) return true;
        const startup = self.startup_source orelse return false;
        return std.mem.eql(u8, self.current_source, startup);
    }

    /// Emit a non-fatal constraint diagnostic to stderr. Matches the
    /// redefinition / type-check warning convention: an immediate `warning:`
    /// line rather than a collected diagnostic.
    pub fn emitConstraintWarning(self: *const Context, msg: []const u8) void {
        _ = self;
        var tw = trace_mod.TraceWriter.init();
        tw.print("warning: {s}\n", .{msg});
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
        self.durable_frame_floor = self.import_frame_index;

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

        try self.pragma_registry.put(self.allocator, "missing-default-arm", .{
            .native_validator = &control.nativeMissingDefaultArmValidator,
        });

        try self.pragma_registry.put(self.allocator, "never-returns-consistency", .{
            .native_validator = &control.nativeNeverReturnsConsistencyValidator,
        });

        try self.pragma_registry.put(self.allocator, "dictionary-shadow", .{
            .native_validator = &control.nativeDictionaryShadowValidator,
        });

        try self.pragma_registry.put(self.allocator, "import-collision", .{
            .native_validator = &control.nativeImportCollisionValidator,
        });

        try self.pragma_registry.put(self.allocator, "allow-uninhabited-constraint", .{});

        // Split prelude into lines and process incrementally
        const source = external_source orelse prelude_source;
        var lines = std.mem.splitScalar(u8, source, '\n');
        var line_num: usize = 0;
        while (lines.next()) |line| {
            line_num += 1;
            processor.trackLine(line_num);
            const parse_start = if (self.benchmark != null) scheduler_mod.elapsedTimerNowNs() else 0;
            const result = processor.feedLine(self.arena.allocator(), line, self);
            if (self.benchmark) |b| b.prelude_parse_ns += scheduler_mod.elapsedTimerNowNs() - parse_start;
            switch (result) {
                .needs_more_input => continue,
                .complete => |instrs| {
                    if (instrs.len > 0) {
                        const exec_start = if (self.benchmark != null) scheduler_mod.elapsedTimerNowNs() else 0;
                        try self.executeQuotation(.{ .instructions = instrs });
                        if (self.benchmark) |b| b.prelude_exec_ns += scheduler_mod.elapsedTimerNowNs() - exec_start;
                    }
                    processor.reset();
                },
                .parse_error => |err| return err,
            }
        }

        // Flush any remaining buffered content
        const flush_parse_start = if (self.benchmark != null) scheduler_mod.elapsedTimerNowNs() else 0;
        const flush_result = processor.flush(self.arena.allocator(), self);
        if (self.benchmark) |b| b.prelude_parse_ns += scheduler_mod.elapsedTimerNowNs() - flush_parse_start;
        switch (flush_result) {
            .complete => |instrs| {
                if (instrs.len > 0) {
                    const exec_start = if (self.benchmark != null) scheduler_mod.elapsedTimerNowNs() else 0;
                    try self.executeQuotation(.{ .instructions = instrs });
                    if (self.benchmark) |b| b.prelude_exec_ns += scheduler_mod.elapsedTimerNowNs() - exec_start;
                }
            },
            .parse_error => |err| return err,
            .needs_more_input => {},
        }
    }

    /// Free all resources used by the context.
    pub fn deinit(self: *Context) void {
        if (self.profile_owned) {
            if (self.profile) |p| {
                p.deinit(self.allocator);
                self.allocator.destroy(p);
            }
        }
        self.aot_generic_dispatch_ids.deinit(self.allocator);
        self.generic_accessor_dispatch_ids.deinit(self.allocator);
        for (self.parameter_env.items) |*frame| {
            self.deinitParameterFrame(frame);
        }
        self.parameter_env.deinit(self.allocator);
        for (self.local_frames.items) |*frame| {
            releaseFrameBindings(frame);
            frame.deinit(self.allocator);
        }
        self.local_frames.deinit(self.allocator);
        self.local_frame_kinds.deinit(self.allocator);
        self.local_frame_modules.deinit(self.allocator);
        self.deinitCapturedScopes();
        self.call_stack.deinit(self.allocator);
        self.error_details.deinit(self.allocator);
        self.jit_pending_trace_frames.deinit(self.allocator);
        self.load_paths.deinit(self.allocator);
        for (self.pragma_frames.items) |*frame| {
            var pragma_vals = frame.valueIterator();
            while (pragma_vals.next()) |v| container_backing.releaseValue(v.*);
            frame.deinit(self.allocator);
        }
        self.pragma_frames.deinit(self.allocator);
        self.pragma_registry.deinit(self.allocator);
        self.parse_time_deferred_emissions.deinit(self.allocator);
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
        self.struct_types_by_name.deinit(self.allocator);
        self.parameterized_type_descriptors.deinit(self.allocator);
        self.struct_descriptors.deinit(self.allocator);
        self.anonymous_union_type_values.deinit(self.allocator);
        self.protocol_descriptors.deinit(self.allocator);
        self.constraint_combinators.deinit(self.allocator);
        self.protocol_satisfies_cache.deinit(self.allocator);
        self.bounded_dispatch_trace_names.deinit(self.allocator);
        self.bounded_dispatch_combinator_trace_names.deinit(self.allocator);
        self.dispatch.deinit();
        self.jit_dispatch.deinit();
        var pic_iter = self.pic_cache.iterator();
        while (pic_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.pic_cache.deinit(self.allocator);
        self.param_effect_cache.deinit(self.allocator);
        // thrown_error, error_value boxes, null-backed bignum boxes, and task
        // error_obj boxes are all arena-allocated; they are reclaimed by
        // arena.deinit. The refcounted backing carried in an unrecovered
        // error's `data` field is not arena-owned, so release it here before
        // discarding the stash.
        if (self.thrown_error) |thrown| {
            if (thrown.data) |data| container_backing.releaseValue(data.*);
        }
        self.thrown_error = null;

        // An undrained callback courier holds a stash of its own, on the same terms.
        self.dropCallbackErrorState();

        // Drop owning references in lifecycle order: residual stack
        // slots first, then captured container literals in word bodies
        // (dictionary) and arena-owned quotations. All releases must
        // happen before the arena that owns the quotation instructions
        // is torn down. Task contexts share the image slot tables with
        // their root, so only the root walks them.
        self.stack.clear();
        // The process-global signal handler table owns its entries; the root releases them here,
        // before the allocators behind the handler bodies go away.
        if (self.parent_context == null) signal.releaseUserHandlers();
        self.dictionary.releaseRetainedValues();
        self.dictionary.walkContainerReleaseList();
        self.walkContainerReleaseList();
        self.container_release_list.deinit(self.allocator);
        if (self.parent_context == null) self.releaseImageSlotReferences();

        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.dictionary.deinit();
        if (self.parent_context == null) {
            // Release the refcounted module cache before tearing down the
            // root-owned allocators it sits in front of. Child contexts share
            // the parent's pointer without retaining and skip this branch.
            container_backing.releaseValue(.{ .mutable_map = self.module_cache_value });
            self.hook_registry.deinit(self.allocator);
            self.allocator.destroy(self.hook_registry);
            self.quotation_stamp_store.destroy();
            self.quotation_source_store.destroy();
            self.carryable_scope_gate.destroy();
            self.reified_decode_cache.destroy();
            self.load_lock.destroy();
            self.allocator.destroy(self.lock_order_tracker);
            self.allocator.destroy(self.shared_lock);
        }
        self.stack.deinit();
    }

    /// The root of this context's ancestor chain: self for the root context,
    /// the process-lifetime root for any task context.
    pub fn rootContext(self: *Context) *Context {
        return self.root_context orelse self;
    }

    /// The context whose durable state writes should land on. Self outside a
    /// module load; the root while one is running, so everything a load
    /// produces outlives the executing task.
    pub fn stateTarget(self: *Context) *Context {
        return self.load_target orelse self;
    }

    /// Allocator for quotations and other parsed data. During a module load
    /// this is the target context's arena, so parse-time products and module
    /// bodies share the lifetime of the registries that retain them.
    pub fn quotationAllocator(self: *Context) Allocator {
        return self.stateTarget().arena.allocator();
    }

    /// Record the file `instructions` was parsed from, so a call frame pushed while the body runs
    /// names the file its line belongs to rather than the innermost executing word's file.
    ///
    /// The parser calls this for every body it finishes. The file being read is `current_source`,
    /// except while a parse-time word executes: its body execution points `current_source` at the
    /// word's own file, and `parse_stamp_source` holds the invoking file the parser is still
    /// reading. Bodies built at runtime, by `curry` or an image decode, carry no record and fall
    /// back to `current_source`.
    ///
    /// Stamps are permanent, so only a body the root arena owns may enter: a body parsed onto a
    /// task or scoped-eval arena dies with it, and its key would then falsely match a later
    /// unrelated allocation at the same address.
    pub fn stampQuotationBodySource(self: *Context, instructions: []const Instruction) !void {
        if (instructions.len == 0) return;
        if (self.stateTarget() != self.rootContext()) return;
        const source = self.parse_stamp_source orelse self.current_source;
        try self.quotation_source_store.stamp(@intFromPtr(instructions.ptr), source);
    }

    /// The file `instructions` was parsed from, or null for a body that was never stamped.
    pub fn quotationBodySource(self: *const Context, instructions: []const Instruction) ?[]const u8 {
        if (instructions.len == 0) return null;
        return self.quotation_source_store.lookup(@intFromPtr(instructions.ptr));
    }

    /// The file `def`'s compound body was parsed in, from the body stamps. Null when the action
    /// carries no instructions or the body was built at runtime and never stamped.
    ///
    /// Definition sites prefer this over `current_source`. A definition executed inside a
    /// runtime-built quotation, which carries no source stamp, runs under the executing word's
    /// file and would freeze that as its own. A `private{` helper would record the prelude,
    /// whose `(import-locals-checked)` composes and calls the block.
    fn defBodyParseSource(self: *const Context, def: WordDefinition) ?[]const u8 {
        return switch (def.action) {
            .compound => |instrs| self.quotationBodySource(instrs),
            .native, .host_callback, .literal => null,
        };
    }

    /// If `instructions` contains any container-variant `push_literal`,
    /// record the slice on this context's release list. The walk at
    /// `deinit` invokes `releaseInstructionsContainerLiterals` on every
    /// recorded slice before the arena that owns the instructions is
    /// torn down, keeping captured container backings alive until the
    /// quotation that captured them is freed.
    pub fn registerQuotationContainerLiterals(self: *Context, instructions: []const Instruction) !void {
        if (!container_backing.instructionsHaveContainerLiteral(instructions)) return;
        const target = self.stateTarget();
        try target.container_release_list.append(target.allocator, instructions);
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

    /// Release the owning references the image loader donated to the slot
    /// tables, before the arena that owns the container structs is torn
    /// down. Tagged inner values release once each; struct-instance,
    /// mutable-map, and vector slots drop their donated header reference,
    /// so the destroy that runs on last drop releases the elements runtime
    /// code stored into them.
    fn releaseImageSlotReferences(self: *Context) void {
        if (self.image_struct_instance_slots) |table| {
            var i: u32 = 0;
            while (i < self.image_struct_instance_slot_count) : (i += 1) {
                const si = table[i] orelse continue;
                si.header.?.release();
            }
        }
        if (self.image_tagged_slots) |table| {
            var i: u32 = 0;
            while (i < self.image_tagged_slot_count) : (i += 1) {
                const tv = table[i] orelse continue;
                container_backing.releaseValue(tv.*);
            }
        }
        if (self.image_mutable_map_slots) |table| {
            var i: u32 = 0;
            while (i < self.image_mutable_map_slot_count) : (i += 1) {
                const m = table[i] orelse continue;
                m.header.release();
            }
        }
        if (self.image_vector_slots) |table| {
            var i: u32 = 0;
            while (i < self.image_vector_slot_count) : (i += 1) {
                const v = table[i] orelse continue;
                v.header.release();
            }
        }
    }

    /// Remove every entry from this context's release list whose slice
    /// pointer matches `instructions`. Called by `defineWord` when a
    /// parsed quotation is about to become a word body so the dictionary
    /// becomes the sole owner of the release callback and we don't
    /// double-release at teardown.
    pub fn unregisterQuotationContainerLiterals(self: *Context, instructions: []const Instruction) void {
        const target = self.stateTarget();
        var i: usize = 0;
        while (i < target.container_release_list.items.len) {
            if (target.container_release_list.items[i].ptr == instructions.ptr) {
                _ = target.container_release_list.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Adopt an owning reference that must survive until teardown, on the
    /// durable-state target's dictionary.
    pub fn retainValueForTeardown(self: *Context, val: Value) !void {
        try self.stateTarget().dictionary.retainValueForTeardown(val);
    }

    /// Record a compound body's container literals on the durable-state
    /// target's dictionary release list.
    pub fn registerCompoundBody(self: *Context, instructions: []const Instruction) !void {
        try self.stateTarget().dictionary.registerCompoundBody(instructions);
    }

    /// Remove a compound body recorded by `registerCompoundBody`, for a body
    /// whose embedded literals a retained value's own destroy releases instead.
    pub fn unregisterCompoundBody(self: *Context, instructions: []const Instruction) void {
        self.stateTarget().dictionary.unregisterCompoundBody(instructions);
    }

    /// Clear all error details and call stack.
    pub fn clearExecutionDetails(self: *Context) void {
        self.error_details.clearRetainingCapacity();
        self.call_stack.clearRetainingCapacity();
        self.clearPendingSyntheticErrorFrames();
        self.pending_error_message = null;
        self.pending_error_hint = null;
        self.pending_dispatch_actual_types = null;
        self.pending_dispatch_available_methods = null;
    }

    pub fn ownedCurrentSource(self: *Context) []const u8 {
        return self.arena.allocator().dupe(u8, self.current_source) catch self.current_source;
    }

    /// Resolve a trace frame's source from the per-call arguments, falling back to the
    /// per-entry `jit_trace_source` when the emission site had no source to bake.
    pub fn traceFrameSource(self: *Context, src_ptr_raw: usize, src_len_raw: usize) []const u8 {
        if (src_ptr_raw != 0 and src_len_raw != 0) {
            const src_ptr: [*]const u8 = @ptrFromInt(src_ptr_raw);
            return src_ptr[0..src_len_raw];
        }
        return self.jit_trace_source orelse self.current_source;
    }

    /// Queue a synthetic frame built from parts, for raise sites that never pushed a
    /// live `CallFrame` to convert.
    pub fn appendPendingSyntheticErrorFrame(self: *Context, word_name: []const u8, source: []const u8, line: usize, effect: ?*const StackEffect) void {
        self.appendPendingErrorFrame(.{
            .word_name = word_name,
            .source = source,
            .line = line,
            .column = 0,
            .stack_effect = effect,
        });
    }

    /// Queue an already-built frame, preserving every field, including the
    /// definition-located mark the fold's dedupe reads.
    pub fn appendPendingErrorFrame(self: *Context, frame: CallFrame) void {
        self.jit_pending_trace_frames.append(self.allocator, frame) catch {};
    }

    pub fn clearPendingSyntheticErrorFrames(self: *Context) void {
        self.jit_pending_trace_frames.clearRetainingCapacity();
    }

    /// Drop pending unwind frames above `mark`, keeping any an enclosing unwind owns.
    ///
    /// The guard covers a nested consumer having already cleared the whole list.
    pub fn truncatePendingErrorFrames(self: *Context, mark: usize) void {
        if (self.jit_pending_trace_frames.items.len > mark) {
            self.jit_pending_trace_frames.shrinkRetainingCapacity(mark);
        }
    }

    /// The in-flight error channels as they stood before an execution whose failure the
    /// caller discards.
    ///
    /// The scalars are held by value and the two lists by mark, so a restore can only
    /// shrink them. That is what lets shields nest: an inner restore lands on the
    /// pre-execution state exactly, and can never reach below an enclosing shield's mark.
    pub const ErrorStateSnapshot = struct {
        message: ?[]const u8,
        hint: ?[]const u8,
        dispatch_actual_types: ?[]const u8,
        dispatch_available_methods: ?[]const u8,
        thrown: ?*value_mod.ErrorObject,
        pending_frame_mark: usize,
        detail_mark: usize,
    };

    /// Record everything a raise can write, ahead of an execution whose error is swallowed.
    pub fn saveErrorState(self: *Context) ErrorStateSnapshot {
        return .{
            .message = self.pending_error_message,
            .hint = self.pending_error_hint,
            .dispatch_actual_types = self.pending_dispatch_actual_types,
            .dispatch_available_methods = self.pending_dispatch_available_methods,
            .thrown = self.thrown_error,
            .pending_frame_mark = self.jit_pending_trace_frames.items.len,
            .detail_mark = self.error_details.items.len,
        };
    }

    /// Give back the state a swallowed error overwrote, so the next error renders only its
    /// own chain.
    ///
    /// A thrown box the swallowed execution installed is discarded here. The box is
    /// arena-owned, but a refcounted `data` payload is not, so its reference is released.
    /// The identity check is what keeps an unchanged stash from being released twice, once
    /// here and once at `deinit`.
    pub fn restoreErrorState(self: *Context, saved: ErrorStateSnapshot) void {
        if (self.thrown_error) |thrown| {
            if (thrown != saved.thrown) {
                if (thrown.data) |data| container_backing.releaseValue(data.*);
            }
        }

        self.resetErrorStateTo(saved);
    }

    /// Put the channels back to `saved` without releasing the stash being displaced.
    ///
    /// Only a caller that hands the displaced stash to a new owner may use this directly;
    /// everything else goes through `restoreErrorState`.
    fn resetErrorStateTo(self: *Context, saved: ErrorStateSnapshot) void {
        self.pending_error_message = saved.message;
        self.pending_error_hint = saved.hint;
        self.pending_dispatch_actual_types = saved.dispatch_actual_types;
        self.pending_dispatch_available_methods = saved.dispatch_available_methods;
        self.thrown_error = saved.thrown;
        self.truncatePendingErrorFrames(saved.pending_frame_mark);
        if (self.error_details.items.len > saved.detail_mark) {
            self.error_details.shrinkRetainingCapacity(saved.detail_mark);
        }
    }

    /// An error's in-flight state lifted off the live channels, to be re-installed elsewhere.
    ///
    /// An FFI callback raises inside a C call, and the courier it leaves behind may not be
    /// drained until arbitrary 1z code has run. Holding the state here rather than on the live
    /// channels is what keeps that intervening code rendering its own errors.
    ///
    /// The struct owns the thrown box's refcounted payload and the two slices.
    pub const DetachedErrorState = struct {
        message: ?[]const u8,
        hint: ?[]const u8,
        dispatch_actual_types: ?[]const u8,
        dispatch_available_methods: ?[]const u8,
        thrown: ?*value_mod.ErrorObject,
        frames: []CallFrame,
        details: []ErrorDetail,
    };

    /// Lift the callback's own contribution off the live channels and restore `saved`.
    ///
    /// A prior stash is dropped, matching how the outer failure already overwrites
    /// `callback_error` when one callback fails inside another.
    ///
    /// An allocation failure leaves the state live, which is the behavior that predates the
    /// detach. The trampoline has no C caller to propagate to.
    pub fn detachErrorStateForCallback(self: *Context, saved: ErrorStateSnapshot) void {
        self.dropCallbackErrorState();

        const pending = self.jit_pending_trace_frames.items[saved.pending_frame_mark..];
        const rows = self.error_details.items[saved.detail_mark..];

        const frames = self.allocator.dupe(CallFrame, pending) catch return;
        const details = self.allocator.dupe(ErrorDetail, rows) catch {
            self.allocator.free(frames);
            return;
        };

        self.callback_error_state = .{
            .message = self.pending_error_message,
            .hint = self.pending_error_hint,
            .dispatch_actual_types = self.pending_dispatch_actual_types,
            .dispatch_available_methods = self.pending_dispatch_available_methods,
            .thrown = self.thrown_error,
            .frames = frames,
            .details = details,
        };

        // The stash moves into the detached state, so its payload must not be released here.
        self.resetErrorStateTo(saved);
    }

    /// Put a detached callback error's state back on the live channels, above whatever is
    /// already there, so the drain that consumes the courier folds the rows it would have.
    pub fn reattachCallbackErrorState(self: *Context) void {
        const detached = self.callback_error_state orelse return;
        self.callback_error_state = null;

        self.pending_error_message = detached.message;
        self.pending_error_hint = detached.hint;
        self.pending_dispatch_actual_types = detached.dispatch_actual_types;
        self.pending_dispatch_available_methods = detached.dispatch_available_methods;
        self.thrown_error = detached.thrown;
        self.jit_pending_trace_frames.appendSlice(self.allocator, detached.frames) catch {};
        self.error_details.appendSlice(self.allocator, detached.details) catch {};

        self.allocator.free(detached.frames);
        self.allocator.free(detached.details);
    }

    /// Discard a detached callback error nobody drained, releasing what it owns.
    fn dropCallbackErrorState(self: *Context) void {
        const detached = self.callback_error_state orelse return;
        self.callback_error_state = null;

        if (detached.thrown) |thrown| {
            if (thrown.data) |data| container_backing.releaseValue(data.*);
        }
        self.allocator.free(detached.frames);
        self.allocator.free(detached.details);
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
            return error.NoParameterFrame;
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

    /// Grow the three parallel frame arrays under the shared write lock when the next push
    /// would move their backing.
    ///
    /// A push itself is task-private, but the backing array is shared storage: a descendant's
    /// ancestor walk reads this context's durable frames from the same buffer under the shared
    /// read lock, and a capacity-exceeding append frees that buffer under the reader. Taking
    /// the write lock for the realloc alone excludes readers during the move, while the common
    /// within-capacity push stays lock-free.
    fn ensureFrameCapacityForPush(self: *Context) !void {
        const needs_growth =
            self.local_frames.items.len == self.local_frames.capacity or
            self.local_frame_kinds.items.len == self.local_frame_kinds.capacity or
            self.local_frame_modules.items.len == self.local_frame_modules.capacity;
        if (!needs_growth) return;

        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        try self.local_frames.ensureUnusedCapacity(self.allocator, 1);
        try self.local_frame_kinds.ensureUnusedCapacity(self.allocator, 1);
        try self.local_frame_modules.ensureUnusedCapacity(self.allocator, 1);
    }

    /// Push a new empty local frame onto the frame stack.
    ///
    /// No lock on the push itself: a context's frames above `durable_frame_floor` are
    /// task-private, including a runtime load's import frame. Only the owning task ever mutates
    /// them, and cross-task resolution reads only an ancestor's stable scope, capped at the
    /// floor, never its live frames above it. Growth of the shared backing is the one locked
    /// step; see `ensureFrameCapacityForPush`.
    pub fn pushLocalFrame(self: *Context) !void {
        try self.ensureFrameCapacityForPush();
        self.local_frames.appendAssumeCapacity(LocalFrame{});
        self.local_frame_kinds.appendAssumeCapacity(.lexical);
        self.local_frame_modules.appendAssumeCapacity(null);
        self.assertFrameKindsParity();
    }

    /// Pop the top local frame from the frame stack. Lock-free for the same
    /// reason as `pushLocalFrame`.
    pub fn popLocalFrame(self: *Context) void {
        if (self.local_frames.items.len > 0) {
            const last_idx = self.local_frames.items.len - 1;
            if (self.local_frames.items[last_idx].count() > 0 and self.isTransientLexicalFrame(last_idx) and
                self.nonempty_transient_lexical_frames > 0)
            {
                // Production stays balanced by construction. The guard tolerates test code that
                // hand-builds a non-empty frame without going through `defineWordLocked`.
                self.nonempty_transient_lexical_frames -= 1;
            }
            if (last_idx < self.local_frame_kinds.items.len and
                self.local_frame_kinds.items[last_idx] == .module_deps and
                self.live_module_deps_frames > 0)
            {
                self.live_module_deps_frames -= 1;
            }
            releaseFrameBindings(&self.local_frames.items[last_idx]);
            self.local_frames.items[last_idx].deinit(self.allocator);
            self.local_frames.items.len -= 1;
            if (self.local_frame_kinds.items.len > 0) {
                self.local_frame_kinds.items.len -= 1;
            }
            if (self.local_frame_modules.items.len > 0) {
                self.local_frame_modules.items.len -= 1;
            }
            self.assertFrameKindsParity();
        }
    }

    /// Pop local frames until only `mark` remain. Shrink-only.
    ///
    /// A compiled body brackets a spliced quotation that may define in a transient lexical frame.
    /// An error return or a bail leaves before the closing pop, so the compiled-entry boundary
    /// restores the depth through here. Each frame goes through `popLocalFrame`, so its bindings
    /// are released and the two fast-path counters stay true.
    pub fn truncateLocalFrames(self: *Context, mark: usize) void {
        while (self.local_frames.items.len > mark) {
            self.popLocalFrame();
        }
    }

    /// Debug-only invariant: the kind tag array stays index-parallel with the frame array.
    ///
    /// A desync means a push or pop touched one without the other.
    fn assertFrameKindsParity(self: *const Context) void {
        std.debug.assert(self.local_frame_kinds.items.len == self.local_frames.items.len);
        std.debug.assert(self.local_frame_modules.items.len == self.local_frames.items.len);
    }

    /// True when frame `idx` is a transient lexical frame: strictly above the durable import frame
    /// and of `.lexical` kind. The floor matches the one the capture scan uses.
    fn isTransientLexicalFrame(self: *const Context, idx: usize) bool {
        const floor = if (self.import_frame_index) |i| i + 1 else 0;
        if (idx < floor) return false;
        return idx < self.local_frame_kinds.items.len and self.local_frame_kinds.items[idx] == .lexical;
    }

    /// True when `instructions`' own top-level `call_word` names -- not recursing into a nested
    /// quotation literal's body, which decides independently when its own `push_literal` later runs
    /// -- match a binding in any currently-live transient lexical frame at or above `floor`.
    ///
    /// Sound, not a heuristic. `preResolveCallTarget` (used by the parser to emit `call_word_direct`)
    /// only ever pre-resolves a name it can prove is absent from every current local frame, so a
    /// name that could possibly resolve to a lexical local always stays a plain `call_word`
    /// instruction; `executeInstructions`'s captured-scope lookup likewise only ever consults it on
    /// the `call_word` path, never `call_word_direct`. A quotation with no matching name therefore
    /// cannot resolve any bare word against a captured scope, so skipping capture for it cannot
    /// reintroduce staleness -- it only skips work that would have produced an unused scope.
    ///
    /// `call_word_module` is scanned alongside `call_word` because its arm does consult the
    /// captured scope: an image body's build-time module resolution yields to a lexical binding,
    /// so the name must be able to trigger capture in the first place.
    fn quotationReferencesLiveFrame(self: *const Context, instructions: []const Instruction, floor: usize) bool {
        var i = floor;
        while (i < self.local_frames.items.len) : (i += 1) {
            if (i < self.local_frame_kinds.items.len and self.local_frame_kinds.items[i] != .lexical) continue;
            const frame = &self.local_frames.items[i];
            if (frame.count() == 0) continue;
            for (instructions) |instr| {
                switch (instr.op) {
                    .call_word => |name| if (frame.contains(name)) return true,
                    .call_word_module => |slot| if (frame.contains(slot.name)) return true,
                    else => {},
                }
            }
        }
        return false;
    }

    /// Capture the lexical scope visible at a quotation's creation, keyed off the quotation body's
    /// instruction-slice pointer. A fresh scope is built on every call, so a quotation literal
    /// re-executed inside a loop closes over the *current* iteration's locals, not a frozen first
    /// snapshot.
    ///
    /// Returns the scope associated with this execution, or null when there is nothing to close
    /// over. The caller (`executeInstructions`'s `push_literal` handling) uses a non-null return to
    /// promote the pushed value to a `.closure` carrying this scope directly.
    ///
    /// Bare words inside the quotation resolve to their definition-site bindings rather than to
    /// same-named words that merely happen to be live on the frame stack where the quotation later
    /// executes.
    ///
    /// Only the transient lexical frames above the durable import frame are snapshotted; the
    /// durable scope and the module are reached the normal way. A module whose `.module_deps` frame
    /// is live at creation is recorded in `deps_modules` so resolution can later admit a
    /// legitimately closed-over deps frame while rejecting a foreign one. A push with no such frame
    /// live and nothing to close over records nothing and stays on the pre-capture fast path.
    ///
    /// The return value drives promotion only: a non-null return means the pushed quotation carries
    /// live lexical bindings and is promoted to a `.closure`; a null return means either nothing was
    /// recorded or only a deps-and-empty-lexical entry was recorded, and the raw quotation is pushed
    /// unchanged. Recording a `deps_modules` entry is therefore decoupled from promotion: a
    /// module-less quotation still gets its (possibly empty) `deps_modules` recorded in the side map
    /// without being turned into a closure, so the per-push closure cost stays scoped to quotations
    /// that actually close over a lexical local.
    ///
    /// A fresh capture supersedes the map's previous entry for this body under `captured_scope_mu`,
    /// then releases the superseded scope. Release only frees it once every in-flight reader --
    /// an `executeInstructions` call still holding it, or a descendant task reached through
    /// `findCapturedScopeForBody`'s ancestor walk -- has released its own hold, so a live reader
    /// never sees a freed scope even though the map itself moved on.
    ///
    /// `nonempty_transient_lexical_frames` only answers "is anything live anywhere in this task,"
    /// not "does this specific quotation reference any of it," so it alone is not enough to skip
    /// the expensive lexical case: once any word is defined anywhere in a long-running task's frame
    /// stack, every quotation literal pushed anywhere in that task afterward would otherwise pay full
    /// capture, whether or not it references that binding. `quotationReferencesLiveFrame` narrows
    /// this further. It only gates the *lexical* snapshot; the deps snapshot is gated instead by
    /// `live_module_deps_frames`, so a push with no ambient deps frame and no captured local records
    /// nothing.
    ///
    /// An unchanged deps-and-empty-lexical entry is left in place rather than superseded, so a body
    /// re-pushed in a loop with a stable ambient-deps set pays a lookup and a compare, not a fresh
    /// allocation.
    fn captureQuotationScope(self: *Context, instructions: []const Instruction) !?*const CapturedScope {
        if (instructions.len == 0) return null;
        const floor = if (self.import_frame_index) |idx| idx + 1 else 0;

        // Lexical snapshot: gated by the fast-path counter and the per-body reference check, exactly
        // as before. `frames` stays empty when no live lexical binding is closed over.
        var frames: std.ArrayListUnmanaged(LocalFrame) = .{};
        errdefer {
            for (frames.items) |*f| {
                releaseFrameBindings(f);
                f.deinit(self.allocator);
            }
            frames.deinit(self.allocator);
        }

        if (self.nonempty_transient_lexical_frames != 0 and
            self.local_frames.items.len > floor and
            self.quotationReferencesLiveFrame(instructions, floor))
        {
            var i = floor;
            while (i < self.local_frames.items.len) : (i += 1) {
                if (i < self.local_frame_kinds.items.len and self.local_frame_kinds.items[i] != .lexical) continue;
                const src = &self.local_frames.items[i];
                if (src.count() == 0) continue;
                var clone: LocalFrame = .{};
                errdefer clone.deinit(self.allocator);
                var it = src.iterator();
                while (it.next()) |e| try clone.put(self.allocator, e.key_ptr.*, e.value_ptr.*);
                retainFrameBindings(&clone);
                errdefer releaseFrameBindings(&clone);
                try frames.append(self.allocator, clone);
            }
        }

        const has_lexical = frames.items.len > 0;

        // Fast path: with no live `.module_deps` frame and nothing closed over lexically, the pushed
        // quotation's ambient-deps set is empty and it captures no local, so there is nothing to
        // record. Return without touching the side map, exactly as the pre-capture path did. A
        // quotation that later runs where no `.module_deps` frame it did not capture is live is
        // unaffected; the one that could be shadowed is a quotation created while such a frame was
        // live, which takes the recording path below.
        if (!has_lexical and self.live_module_deps_frames == 0) {
            frames.deinit(self.allocator);
            return null;
        }

        const key = @intFromPtr(instructions.ptr);

        // Equality-skip: a deps-and-empty-lexical push whose recorded entry already carries the same
        // ambient deps needs no new scope. The live frames are compared against the entry in place,
        // so the stable re-push case (a library word pushing the same quotation each iteration)
        // allocates nothing. Lexical-bearing pushes always supersede, matching the per-execution
        // freshness a loop-nested closure relies on.
        //
        // This read is unlocked: only this task writes its own map, and it is not writing anywhere
        // else while running here synchronously, so the only possible concurrent access is a
        // descendant's `findCapturedScopeForBody` read. Two reads never conflict, and a supersede on
        // this key can only come from this same task, which is right here.
        if (!has_lexical) {
            if (self.quotation_scope_info.get(key)) |info| {
                if (info.scope) |old| {
                    if (old.lexical_frames.len == 0 and self.liveDepsMatch(floor, old.deps_modules)) {
                        frames.deinit(self.allocator);
                        return null;
                    }
                }
            }
        }

        // Deps snapshot: which modules have a live `.module_deps` frame above the floor. Built only
        // now that a fresh entry is definitely being recorded, so the equality-skip above pays no
        // allocation. Empty when no such frame is live (a lexical-only capture).
        var deps_list: std.ArrayListUnmanaged(*const value_mod.Module) = .{};
        errdefer deps_list.deinit(self.allocator);
        if (self.live_module_deps_frames > 0) {
            var j = floor;
            while (j < self.local_frames.items.len) : (j += 1) {
                if (j >= self.local_frame_kinds.items.len or self.local_frame_kinds.items[j] != .module_deps) continue;
                if (j < self.local_frame_modules.items.len) {
                    if (self.local_frame_modules.items[j]) |m| try deps_list.append(self.allocator, m);
                }
            }
        }

        const lexical_frames = try frames.toOwnedSlice(self.allocator);
        errdefer {
            for (lexical_frames) |*f| {
                releaseFrameBindings(f);
                f.deinit(self.allocator);
            }
            self.allocator.free(lexical_frames);
        }

        const deps_modules = try deps_list.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(deps_modules);

        const scope = try self.allocator.create(CapturedScope);
        errdefer self.allocator.destroy(scope);
        scope.* = .{
            .lexical_frames = lexical_frames,
            .deps_modules = deps_modules,
            .allocator = self.allocator,
        };

        // The push-literal caller holds no closure, and a pushed literal's body is module-owned,
        // so the carrier is truthfully null here.
        _ = try self.publishQuotationScopeEntry(instructions, scope, null, .supersede);
        return if (has_lexical) scope else null;
    }

    /// How `publishQuotationScopeEntry` resolves a collision. `.supersede` replaces the entry's
    /// scope and releases the one it displaced. `.fill_if_absent` keeps a collision's existing
    /// entry and releases the offered scope instead, which is the read-through fill's
    /// first-write-wins.
    const ScopePublishMode = enum { supersede, fill_if_absent };

    /// The one writer of `quotation_scope_info` and the one marker of `carryable_scope_gate`.
    ///
    /// Every production insert funnels through here, so the admission rule has a single choke
    /// point: a body a closure owns never enters either structure, because its address dies with
    /// the closure and its resolution data rides the value. The carrier assert re-checks what the
    /// caller already decided. The live-body registry answers independently off the closure
    /// lifecycle, so it also catches a writer that threads no carrier at all.
    ///
    /// Ownership of `scope` transfers in, resolved per `mode`. The gate is marked before the
    /// entry is published whenever the installed scope carries a lexical frame; a deps-only
    /// scope is invisible to the ancestor walk and does not mark. A fresh entry's module half is
    /// filled from the shared stamp store, keeping every entry's module half authoritative: the
    /// body-entry probe trusts a map hit without a store probe. The lookup is lock-free, so
    /// taking it under the mutex costs one probe on creation only.
    ///
    /// A descendant task may read this map through `findCapturedScopeForBody`'s parent walk, so
    /// the publish is taken under this context's map mutex to exclude a concurrent read during a
    /// rehash. The displaced scope is released after unlocking, since a free should not run
    /// while the mutex is held. The mutex is also released on the `getOrPut` error path (e.g. an
    /// OOM rehash), so a failed publish can't leave a live descendant-task read permanently
    /// blocked on this context's mutex.
    fn publishQuotationScopeEntry(
        self: *Context,
        instructions: []const Instruction,
        scope: ?*CapturedScope,
        owner: ?*const value_mod.Closure,
        mode: ScopePublishMode,
    ) !QuotationScopeInfo {
        const key = @intFromPtr(instructions.ptr);

        if (comptime builtin.mode == .Debug) {
            if (owner) |c| std.debug.assert(!c.ownsBody(instructions));
            closure_body_registry.assertNotLive(key);
        }

        const carryable = if (scope) |s| s.lexical_frames.len > 0 else false;
        if (carryable) _ = try self.carryable_scope_gate.mark(key);

        self.captured_scope_mu.lock();
        errdefer self.captured_scope_mu.unlock();
        const gop = try self.quotation_scope_info.getOrPut(self.allocator, key);
        const fresh = !gop.found_existing;
        if (fresh)
            gop.value_ptr.* = .{ .defining_module = self.quotation_stamp_store.lookup(key) };

        var displaced: ?*CapturedScope = null;
        switch (mode) {
            .supersede => {
                displaced = gop.value_ptr.scope;
                gop.value_ptr.scope = scope;
            },
            .fill_if_absent => {
                if (fresh) gop.value_ptr.scope = scope else displaced = scope;
            },
        }

        const info = gop.value_ptr.*;
        self.captured_scope_mu.unlock();
        if (displaced) |old| old.release();
        return info;
    }

    /// Append the modules whose `.module_deps` frame is currently live above the import floor.
    ///
    /// `curry`/`compose` use this to recover a base body's ambient deps when the base was pushed by
    /// compiled code: a compiled push never runs `captureQuotationScope`, so the base records no
    /// deps. `curry` runs where the base was pushed, so the live frames are the ones the curried
    /// body needs. Mirrors the deps scan in `captureQuotationScope`.
    pub fn appendLiveDepsModules(self: *const Context, list: *std.ArrayListUnmanaged(*const value_mod.Module), alloc: Allocator) !void {
        if (self.live_module_deps_frames == 0) return;
        const floor = if (self.import_frame_index) |idx| idx + 1 else 0;
        var j = floor;
        while (j < self.local_frames.items.len) : (j += 1) {
            if (j >= self.local_frame_kinds.items.len or self.local_frame_kinds.items[j] != .module_deps) continue;
            if (j < self.local_frame_modules.items.len) {
                if (self.local_frame_modules.items[j]) |m| try list.append(alloc, m);
            }
        }
    }

    /// True when the live `.module_deps` frames above `floor` list exactly `expected`, in order. Used
    /// by the equality-skip to compare against a recorded entry without allocating a snapshot: the
    /// scan mirrors the recording scan, so a body re-pushed against an unchanged frame stack matches.
    fn liveDepsMatch(self: *const Context, floor: usize, expected: []const *const value_mod.Module) bool {
        var idx: usize = 0;
        var j = floor;
        while (j < self.local_frames.items.len) : (j += 1) {
            if (j >= self.local_frame_kinds.items.len or self.local_frame_kinds.items[j] != .module_deps) continue;
            const m = if (j < self.local_frame_modules.items.len) self.local_frame_modules.items[j] else null;
            if (m) |mod| {
                if (idx >= expected.len or expected[idx] != mod) return false;
                idx += 1;
            }
        }
        return idx == expected.len;
    }

    /// Build a `.closure` wrapping `quot`'s existing instructions/effect plus a copy of `scope`,
    /// for a capturing quotation-literal push.
    ///
    /// The scope is deep-copied onto the closure's own allocator rather than shared with the
    /// map's entry: the map's copy is refcounted and can be superseded (and eventually freed) by a
    /// later push of the same body, but a closure holding it directly has no such lifecycle hook, so
    /// it needs its own independently-owned copy that the closure's destroy releases. This
    /// is load-bearing, not defensive: `curry`, `compose`, and `spawn` can all hand a closure to a
    /// task that keeps running after the pushing context has moved on and superseded the entry this
    /// closure was built from (e.g. a `spawn-detached` per-connection handler in a server's
    /// tail-recursive accept loop, which is exactly the shape that crashed with a shared pointer
    /// here during this fix's own development, `tests/integration/server_max_concurrent_connections.1z`).
    ///
    /// This is affordable only because `captureQuotationScope` no longer captures indiscriminately:
    /// `quotationReferencesLiveFrame` (see its doc comment) means a quotation that references no
    /// local at all is never captured or promoted in the first place, regardless of what else is
    /// live elsewhere in the task's frame stack. Without that gate, a naive whole-context capture
    /// trigger combined with a per-embed copy was confirmed to blow an existing integration test's
    /// memory budget (`tests/integration/serve_loop_bounded.1z`) under idiomatic 1z networking code
    /// (`lib/net/server.1z`, `lib/net/tcp.1z`), which curries almost every quotation immediately
    /// after pushing it.
    ///
    /// A non-null `quot.code_ptr` becomes a one-entry compiled segment so a compiled fast path is
    /// not silently dropped by the promotion; otherwise the closure is uncompiled.
    fn promoteToClosure(self: *Context, quot: Quotation, scope: *const CapturedScope) !*value_mod.Closure {
        const alloc = self.allocator;
        const segments: []const value_mod.Segment = if (quot.code_ptr) |cp| blk: {
            const segs = try alloc.alloc(value_mod.Segment, 1);
            segs[0] = .{ .captures = &.{}, .base_code_ptr = cp };
            break :blk segs;
        } else &.{};
        errdefer alloc.free(segments);

        const scope_copy = try dupeCapturedScope(alloc, scope);
        errdefer scope_copy.release();

        // The body aliases the module-owned quotation literal, so the closure
        // owns only the segments and the scope copy. It carries no defining
        // module either: an aliased body is not closure-owned, so body entry
        // keeps reading the map, whose key is the literal's own address.
        return try value_mod.Closure.create(alloc, .{
            .instructions = quot.instructions,
            .effect = quot.effect,
            .segments = segments,
            .captured_scope = scope_copy,
            .header = undefined,
            .owns_segments = true,
            .owns_scope = true,
        });
    }

    /// Resolve `name` against a captured lexical scope's transient frames, most-recently-pushed
    /// frame first.
    ///
    /// Returns null when the captured scope does not bind the name, so the caller falls back to
    /// normal resolution.
    fn lookupInCapturedScope(scope: *const CapturedScope, name: []const u8) ?WordDefinition {
        var i = scope.lexical_frames.len;
        while (i > 0) {
            i -= 1;
            if (scope.lexical_frames[i].get(name)) |def| return def;
        }
        return null;
    }

    /// Release every scope still in the map at context teardown.
    ///
    /// Structured concurrency (`task-scope` waiting for every child to reach terminal status
    /// before returning) guarantees no descendant task still holds a retained reference to any of
    /// this context's scopes by the time its own teardown runs, so each entry's refcount is
    /// exactly 1 here and `release()` frees it.
    fn deinitCapturedScopes(self: *Context) void {
        var it = self.quotation_scope_info.valueIterator();
        while (it.next()) |info| if (info.scope) |s| s.release();
        self.quotation_scope_info.deinit(self.allocator);
    }

    /// Deep-copy a captured scope with `alloc`. Each `LocalFrame` is cloned entry-by-entry, the
    /// same shallow copy `captureQuotationScope` uses, then retained: a definition's bound value
    /// is the one thing a `WordDefinition` can own, and the clone outlives its source.
    ///
    /// The allocator is a parameter so `promoteToClosure` and `curry`/`compose` can allocate the
    /// closure-carried copy on the quotation arena, while the execution stamp and the body-entry
    /// fill allocate the map-owned copy on the durable allocator. `findCapturedScopeForBody`
    /// serves both shapes and passes its caller's allocator through. Every copy is released with
    /// `CapturedScope.release`, including one on an arena: the arena frees are noöps, but the
    /// bindings' references are not.
    pub fn dupeCapturedScope(alloc: Allocator, src: *const CapturedScope) !*CapturedScope {
        const frames = try alloc.alloc(LocalFrame, src.lexical_frames.len);
        var built: usize = 0;
        errdefer {
            for (frames[0..built]) |*f| {
                releaseFrameBindings(f);
                f.deinit(alloc);
            }
            alloc.free(frames);
        }

        for (src.lexical_frames, 0..) |*sf, i| {
            var clone: LocalFrame = .{};
            errdefer clone.deinit(alloc);
            var it = sf.iterator();
            while (it.next()) |e| try clone.put(alloc, e.key_ptr.*, e.value_ptr.*);
            retainFrameBindings(&clone);
            frames[i] = clone;
            built = i + 1;
        }

        const deps = try alloc.dupe(*const value_mod.Module, src.deps_modules);
        errdefer alloc.free(deps);

        const scope = try alloc.create(CapturedScope);
        scope.* = .{ .lexical_frames = frames, .deps_modules = deps, .allocator = alloc };
        return scope;
    }

    /// Find the captured scope for a body pointer and return an independently owned copy: this
    /// context's map first, then each ancestor context's map under that ancestor's
    /// `captured_scope_mu`, mirroring `lookupWordLocked`'s parent walk.
    ///
    /// `curry`/`compose` running in a descendant task use this to source a scope that an ancestor
    /// task captured where the source quotation literal was created. The body-entry fill in
    /// `executeInstructions` uses it the same way, caching the copy into this context's map so a
    /// stored quotation reached indirectly in a child task keeps its parent-recorded lexical
    /// captures.
    ///
    /// The result is always a fresh `dupeCapturedScope` copy on `alloc`, never a shared pointer
    /// into either map: the ancestor's entry is a refcounted, supersedable map entry
    /// (`captureQuotationScope`), so embedding it directly into a closure that may outlive the
    /// current call would risk a later use-after-free once the ancestor supersedes and frees it --
    /// see `promoteToClosure`'s doc comment for why this is load-bearing, not merely defensive.
    ///
    /// The self read needs no lock (single-writer-self, synchronous within one task, so nothing can
    /// supersede the entry mid-call). The ancestor read retains the found scope while still holding
    /// that ancestor's map mutex, so a concurrent supersede on the ancestor's side cannot free it
    /// between the read and the retain; the retain is released right after the copy completes.
    pub fn findCapturedScopeForBody(self: *Context, alloc: Allocator, body_ptr: usize) !?*CapturedScope {
        // A deps-only entry (empty lexical frames) carries nothing `curry`/`compose` consume, so it is
        // invisible here: a caller sourcing a lexical scope must fall through exactly as it would if no
        // entry had been recorded, or it would spuriously wrap the result in a closure.
        if (self.quotation_scope_info.get(body_ptr)) |info| {
            if (info.scope) |s| {
                if (s.lexical_frames.len > 0) return try dupeCapturedScope(alloc, s);
            }
        }

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            // The mutex is logically mutable through a `*const Context`: locking guards the map, it
            // does not mutate the context's value. `@constCast` is the standard lock-in-const idiom.
            const mu: *std.Thread.Mutex = @constCast(&ctx.captured_scope_mu);
            mu.lock();
            const found: ?*CapturedScope = if (ctx.quotation_scope_info.get(body_ptr)) |info| info.scope else null;
            const carryable = if (found) |s| s.lexical_frames.len > 0 else false;
            if (carryable) found.?.retain();
            mu.unlock();
            if (carryable) {
                defer found.?.release();
                return try dupeCapturedScope(alloc, found.?);
            }
            ancestor = ctx.parent_context;
        }
        return null;
    }

    /// Deep-copy `scope` into this context's map keyed by the body pointer, superseding whatever
    /// this key currently holds.
    ///
    /// Called at the execution choke point (`popQuotation`) so a curried/composed closure that
    /// carries its own scope resolves through the existing `executeInstructions` lookup, in
    /// whatever task later runs it. The copy is map-owned (released by `deinitCapturedScopes`, or
    /// superseded and released by a later call here or by `captureQuotationScope` for the same
    /// body), so a closure and the executing context never share one scope allocation.
    ///
    /// Superseding unconditionally, rather than skipping when the key is already present, is
    /// required for correctness, not just symmetry with `captureQuotationScope`. `promoteToClosure`
    /// reuses a quotation literal's own static `instructions` pointer rather than allocating a
    /// fresh one, so every closure built from repeated executions of the same loop-nested literal
    /// shares that one key while each carries its own distinct captured scope. Two such closures
    /// invoked in the same context -- built across iterations and stored for later invocation, or
    /// simply invoked out of build order -- would otherwise have their second stamp silently
    /// dropped, leaving `executeInstructions`'s lookup resolving the second closure's bare words
    /// against the first closure's stale scope.
    ///
    /// `scope` (the source being copied) is always either an independently-owned closure copy or
    /// a map entry read and consumed synchronously within the same native call (e.g. `spawn`).
    /// It cannot be superseded out from under this call, so no retain of `scope` itself is
    /// needed here.
    ///
    /// `owner` is the closure the body came out of, when there is one. A body that closure owns is
    /// refused: its address dies with the closure, so a permanent entry under it would outlive its
    /// own key, and it carries `scope` on the value already. A push-time promotion aliases a module
    /// literal rather than allocating, so it is not owned and still stamps.
    pub fn stampCapturedScopeForExecution(
        self: *Context,
        instructions: []const Instruction,
        scope: *const CapturedScope,
        owner: ?*const value_mod.Closure,
    ) !void {
        if (instructions.len == 0) return;
        if (owner) |c| if (c.ownsBody(instructions)) return;

        const dup = try dupeCapturedScope(self.allocator, scope);
        errdefer dup.release();

        _ = try self.publishQuotationScopeEntry(instructions, dup, owner, .supersede);
    }

    /// Record `module` as the defining module of this body and every quotation
    /// literal nested inside it, keyed by the body's instruction-slice pointer.
    /// Called at module finalization so a `use`-imported word called inside the
    /// body can be re-resolved against the defining module's deps even after the
    /// frame stack has moved on. Empty slices share a sentinel pointer and have
    /// no words to resolve, so they are skipped.
    pub fn stampQuotationBodies(self: *Context, instructions: []const Instruction, module: *const value_mod.Module) error{OutOfMemory}!void {
        if (instructions.len == 0) return;

        // The store applies first-stamp-wins: the first module to stamp a body is its original
        // defining module.
        //
        // That matters because a body's instruction slice is shared when a module reexports
        // another's word. The reexporting module reprocesses the same pointers, and the body's
        // private helpers live in the module it was written in, not the one reexporting it.
        //
        // A false return means this body and everything nested under it were already stamped, so
        // stop here. The store's writer mutex is not held across the recursion below.
        if (!try self.quotation_stamp_store.stamp(@intFromPtr(instructions.ptr), module)) return;

        // Repair this context's own read-through entry. Stamped-before-reachable covers other
        // executors only: the loading context itself can push or execute this body before
        // finalization reaches here, creating a map entry whose module half cached the store miss.
        // A map hit is authoritative at body entry, so a stale null would lose the stamp exactly
        // where the module's own top-level code stored the quotation. Only the first-stamp writer
        // repairs: an entry created after the stamp was filled correctly at creation.
        if (self.quotation_scope_info.count() != 0) {
            self.captured_scope_mu.lock();
            if (self.quotation_scope_info.getPtr(@intFromPtr(instructions.ptr))) |info| {
                if (info.defining_module == null) info.defining_module = module;
            }
            self.captured_scope_mu.unlock();
        }

        for (instructions) |instr| {
            switch (instr.op) {
                .push_literal => |val| try self.stampValueQuotations(val, module),
                else => {},
            }
        }
    }

    /// Stamp every quotation reachable through a pushed literal value, descending into container
    /// literals as well as a bare `.quotation`.
    ///
    /// A collection parse-time word (`H{`, `V{`, `{`, `S{`, `M{`) emits its whole literal as one
    /// `push_literal`, so a quotation embedded in it (`H{ prefix: [ (expr-prefix) ] }`) never reaches
    /// `stampQuotationBodies` on its own. Without a stamp such a quotation has no defining module, so
    /// the `.module_deps` visibility filter cannot admit its own module's frame and mis-resolves a
    /// bare word that also exists in the global dictionary.
    ///
    /// At module finalization the value is the as-parsed literal, immutable and acyclic, so the
    /// recursion terminates.
    ///
    /// A closure also takes the stamp onto the value, when it has none yet. Its body may be one
    /// the closure owns. Body entry reads that off the value rather than out of the map, so the
    /// two have to agree.
    pub fn stampValueQuotations(self: *Context, val: Value, module: *const value_mod.Module) error{OutOfMemory}!void {
        switch (val) {
            .quotation => |q| try self.stampQuotationBodies(q.instructions, module),
            .closure => |c| {
                if (c.defining_module == null) c.defining_module = module;
                try self.stampQuotationBodies(c.instructions, module);
            },
            .parameter => |p| try self.stampQuotationBodies(p.default_quotation.instructions, module),
            .array => |a| for (a.items) |item| try self.stampValueQuotations(item, module),
            .vector => |v| for (v.list.items) |item| try self.stampValueQuotations(item, module),
            .set => |s| for (s.map.keys()) |item| try self.stampValueQuotations(item, module),
            .hash => |h| {
                var it = h.map.valueIterator();
                while (it.next()) |vp| try self.stampValueQuotations(vp.*, module);
            },
            .mutable_map => |m| {
                var it = m.map.valueIterator();
                while (it.next()) |vp| try self.stampValueQuotations(vp.*, module);
            },
            .struct_instance => |si| for (si.fields) |f| try self.stampValueQuotations(f, module),
            .tagged => |t| try self.stampValueQuotations(t.inner.*, module),
            else => {},
        }
    }

    /// Build the module entry for a frame definition, the direction opposite `moduleWordFrameDef`.
    ///
    /// `ModuleWord` has no `.literal` counterpart, so a directly-bound value becomes the
    /// one-instruction body it replaced. A module outlives the frame that defined its words, so a
    /// frame-owned value needs a reference of its own here; the dictionary's teardown list holds it,
    /// which is the same lifetime a durable binding's own definition would have given it.
    ///
    /// Every path that promotes a frame into a module goes through here: a file's own words at load
    /// finalization, `private{ }`'s scope capture, and `>module`.
    pub fn moduleWordFor(self: *Context, alloc: Allocator, def: WordDefinition) !value_mod.ModuleWord {
        return .{
            .stack_effect = def.stack_effect,
            .markers = def.markers,
            .source_module = def.source_module,
            .dispatch_id = def.dispatch_id,
            .doc = def.doc,
            .source_file = def.source_file,
            .source_line = def.source_line,
            .source_column = def.source_column,
            .provenance = def.provenance,
            .body_owner = def.body_owner,
            .action = switch (def.action) {
                .compound => |instrs| .{ .compound = instrs },
                .native => |func| .{ .native = func },
                .host_callback => |host| .{ .host_callback = host },
                .literal => |v| blk: {
                    const instrs = try alloc.alloc(Instruction, 1);
                    instrs[0] = .{ .op = .{ .push_literal = v }, .line = 0 };
                    if (def.owns_literal) {
                        container_backing.retainValue(v);
                        errdefer container_backing.releaseValue(v);
                        try self.retainValueForTeardown(v);
                    }
                    break :blk .{ .compound = instrs };
                },
            },
        };
    }

    /// Build the frame `WordDefinition` for a module dep/word entry. The
    /// synthesized definition carries computed `exec_flags` so the hot
    /// `executeResolvedWord` path reads correct bits for module-frame words,
    /// which are resolved here rather than through the definition finalization
    /// points.
    fn moduleWordFrameDef(
        name: []const u8,
        mod_word: value_mod.ModuleWord,
        module: *const value_mod.Module,
    ) WordDefinition {
        var def: WordDefinition = .{
            .name = name,
            .stack_effect = mod_word.stack_effect,
            .markers = mod_word.markers,
            .source_module = mod_word.source_module orelse module,
            .capability = mod_word.capability,
            .dispatch_id = mod_word.dispatch_id,
            // Compiled functions and image word rows are keyed per (module, word), so the row's
            // id names this entry's own body and a frame or probe hit dispatches compiled.
            .word_id = mod_word.word_id,
            .body_owner = mod_word.body_owner,
            .action = switch (mod_word.action) {
                .compound => |instrs| .{ .compound = instrs },
                .native => |func| .{ .native = func },
                .host_callback => |host| .{ .host_callback = host },
            },
        };
        def.exec_flags = computeExecFlags(def);
        return def;
    }

    /// Restore one image-serialized entry-file import into the durable entry frame at
    /// `image_entry_import_frame`. The definition goes through the module-word conversion and is
    /// marked `imported`, matching what the interpreter's `use` records there.
    ///
    /// Writes the frame without the shared lock: the only caller runs during image load, before
    /// any worker thread exists. The target is `image_entry_import_frame` rather than
    /// `import_frame_index` because only the boot's `onez_push_entry_frame` sets it, while the
    /// prelude load also sets the latter. A null value is a boot that never pushed, an embedder's
    /// shape, and writing an entry import into an embedder's prelude frame would plant it in the
    /// base scope the shadow probe reads.
    pub fn defineImageEntryImport(
        self: *Context,
        name: []const u8,
        mod_word: value_mod.ModuleWord,
        source: *const value_mod.Module,
    ) !void {
        const idx = self.image_entry_import_frame orelse return;
        var def = moduleWordFrameDef(name, mod_word, source);
        def.imported = true;
        try self.local_frames.items[idx].put(self.allocator, name, def);
    }

    /// Marker slices for a seeded entry word whose original definition carried the const or
    /// generic marker. Const keeps `CannotRedefineConst` refusing a runtime redefinition, and
    /// generic keeps the binding's derived exec flags and introspected markers faithful.
    const seeded_const_markers = [_]*value_mod.Marker{@constCast(&markers_mod.const_marker)};
    const seeded_generic_markers = [_]*value_mod.Marker{@constCast(&markers_mod.generic_marker)};
    const seeded_const_generic_markers = [_]*value_mod.Marker{
        @constCast(&markers_mod.const_marker),
        @constCast(&markers_mod.generic_marker),
    };

    /// One baked seed row for `seedEntryWord`, decoded from the tables the freeze emitted.
    pub const EntryWordSeed = struct {
        name: []const u8,
        effect: ?*const StackEffect,
        word_id: ?u32,
        dispatch_id: u32,
        generated: bool,
        is_const: bool,
        is_generic: bool,
    };

    /// Advance the root mint counter past a freeze-time dispatch id installed at boot.
    ///
    /// Replayed method entries and seeded entry words carry ids the freeze's counter issued, not
    /// this process's. Without the advance a later runtime definition can mint an id equal to one
    /// of them and inherit that identity's registered methods.
    pub fn advanceDispatchIdPast(self: *Context, id: u32) void {
        _ = self.rootContext().next_dispatch_id.fetchMax(id +| 1, .monotonic);
    }

    /// Debug-only choke-point check for the id-uniqueness invariant: a freshly-minted dispatch id
    /// must carry no dispatch state installed under a freeze-time id. Boot reconciles the counter
    /// through `advanceDispatchIdPast`; this catches a future install site that forgets to.
    fn assertMintedDispatchIdFresh(self: *Context, id: u32) void {
        if (builtin.mode != .Debug) return;

        const keys = self.dispatchKeysForIdLocked(id, self.arena.allocator()) catch return;
        std.debug.assert(keys.len == 0);

        var it = self.rootContext().aot_generic_dispatch_ids.valueIterator();
        while (it.next()) |baked| std.debug.assert(baked.* != id);
    }

    /// Seed one of the entry file's own top-level names into the durable entry frame at AOT boot,
    /// so a runtime redefinition finds the name where an interpreter driver would put it and
    /// takes the same guard path: not `imported`, so it routes to the arity check rather than the
    /// import-conflict guard, with the declared effect the check compares.
    ///
    /// The word's body is not restorable -- it was executed at the freeze and lives only in the
    /// compiled dispatch table -- so the binding takes the shape `lookupAotCompiledWordLocked`
    /// synthesizes for the same words today: `word_id` drives the compiled dispatch in
    /// `executeResolvedWord`, and the bail sentinel raises rather than silently no-opping when no
    /// compiled body exists.
    ///
    /// The dispatch_id is the word's own freeze-time id, baked into the seed row. Replayed method
    /// entries and compiled call sites carry freeze-time ids verbatim, so a minted id would be a
    /// fresh identity none of them reference: a seeded generic would lose its own replayed
    /// methods. The counter is also advanced past every baked id, seeded or skipped, so a later
    /// runtime mint cannot alias one.
    ///
    /// Writes the frame without the shared lock: the only caller runs during boot, before any
    /// worker thread exists. A name already present -- a restored entry import -- is left alone,
    /// since whatever the loader wrote is more faithful than this stub.
    ///
    /// A name the base scope below the entry frame resolves -- a prelude binding or a dictionary
    /// native -- is not seeded either. Such a definition existed at freeze only through
    /// `override`, and the binary's by-name resolution for it is anchored below this frame; a
    /// stub in front would shadow the binding execution still reaches, and its effect would
    /// replace the one error frames render. The cost is one corner: redefining such a name at
    /// runtime renders the shadow guard rather than the interpreted arity check, loud either way.
    pub fn seedEntryWord(self: *Context, seed: EntryWordSeed) !void {
        self.advanceDispatchIdPast(seed.dispatch_id);

        const idx = self.image_entry_import_frame orelse return;
        const frame = &self.local_frames.items[idx];
        if (frame.contains(seed.name)) return;

        for (self.local_frames.items[0..idx]) |below| {
            if (below.contains(seed.name)) return;
        }
        if (self.dictionary.getSlot(seed.name) != null) return;

        var def: WordDefinition = .{
            .name = seed.name,
            .stack_effect = seed.effect,
            .word_id = seed.word_id,
            .dispatch_id = seed.dispatch_id,
            .provenance = if (seed.generated) .{ .generator = "entry-seed", .parent = "", .role = "" } else null,
            .markers = if (seed.is_const and seed.is_generic)
                &seeded_const_generic_markers
            else if (seed.is_const)
                &seeded_const_markers
            else if (seed.is_generic)
                &seeded_generic_markers
            else
                &.{},
            .action = .{ .native = aotCompiledOnlyBailSentinel },
        };
        def.exec_flags = computeExecFlags(def);
        try frame.put(self.allocator, seed.name, def);
    }

    /// Seed one of the entry file's `use` imports into the durable entry frame at AOT boot, on the
    /// tiers whose image carries no entry-import rows. The binding exists for the collision
    /// guards: `imported` routes a runtime definition of the name to the import-conflict guard,
    /// and the source module supplies the origin that guard's message names.
    ///
    /// The body is deliberately not restored, which is what separates this from
    /// `defineImageEntryImport`. A metadata-only image rehydrates compound words with empty
    /// instruction streams, so installing one here would shadow the module-cache scan an
    /// interpreted call otherwise falls through to, turning a working call into a silent no-op.
    /// The action is the compiled-only bail sentinel instead, so such a reach raises. `word_id`
    /// still carries the freeze-time id, so a compiled call site dispatches the real body.
    ///
    /// Writes the frame without the shared lock: the only caller runs during boot, before any
    /// worker thread exists. A name already present is left alone, since a binding the loader
    /// restored carries a real body this one cannot.
    pub fn seedEntryImport(self: *Context, name: []const u8, source_name: []const u8) !void {
        const idx = self.image_entry_import_frame orelse return;
        const frame = &self.local_frames.items[idx];
        if (frame.contains(name)) return;

        const cached = self.module_cache_value.map.get(source_name) orelse return;
        if (cached != .module) return;
        const mod_word = cached.module.words.get(name) orelse return;

        var def: WordDefinition = .{
            .name = name,
            .stack_effect = mod_word.stack_effect,
            .markers = mod_word.markers,
            .source_module = mod_word.source_module orelse cached.module,
            .capability = mod_word.capability,
            .dispatch_id = mod_word.dispatch_id,
            .word_id = mod_word.word_id,
            .imported = true,
            .action = .{ .native = aotCompiledOnlyBailSentinel },
        };
        def.exec_flags = computeExecFlags(def);
        try frame.put(self.allocator, name, def);
    }

    /// Fill `frame` with `module`'s deps then words (words override same-named
    /// deps), synthesizing a `WordDefinition` per entry with `allocator`. Shared
    /// by the template builder and the un-templated fallback in
    /// `pushModuleDepsFrame`.
    fn populateModuleDepsFrame(frame: *LocalFrame, module: *const value_mod.Module, allocator: Allocator) !void {
        var dep_iter = module.deps.iterator();
        while (dep_iter.next()) |entry| {
            try frame.put(allocator, entry.key_ptr.*, moduleWordFrameDef(entry.key_ptr.*, entry.value_ptr.*, module));
        }

        var word_iter = module.words.iterator();
        while (word_iter.next()) |entry| {
            try frame.put(allocator, entry.key_ptr.*, moduleWordFrameDef(entry.key_ptr.*, entry.value_ptr.*, module));
        }
    }

    /// Build `module`'s immutable deps-and-words template with `allocator`, which
    /// must outlive the module. Callers pass the module's own arena, so the
    /// template is freed wholesale with it and needs no explicit deinit.
    ///
    /// This overwrites any prior template without freeing it, so `allocator` must
    /// be arena-scoped. The AOT loader relies on the overwrite: it rebuilds after
    /// patching dispatch_ids that an earlier build missed.
    ///
    /// Called where a module's `words`/`deps` are finalized, such as load and reload
    /// (`nativeLoadImpl`), ad-hoc `>module`, and runtime-image load. A module that reaches
    /// `pushModuleDepsFrame` without a template, such as one built by `current-scope` or
    /// `local-scope`, falls back to the per-entry rebuild. The template needs no invalidation
    /// once built; see the immutability invariant on `Module.deps_template`. A future feature
    /// that mutates a templated module in place must call this again to rebuild.
    pub fn buildModuleDepsTemplate(module: *value_mod.Module, allocator: Allocator) !void {
        var frame: LocalFrame = .{};
        errdefer frame.deinit(allocator);
        try populateModuleDepsFrame(&frame, module, allocator);
        module.deps_template = .{ .frame = frame };
    }

    /// Copy a word frame's single backing allocation directly, without
    /// re-hashing any key. `StringHashMapUnmanaged` stores one allocation laid
    /// out as `[Header][metadata][keys][values]`; this duplicates that buffer at
    /// the source capacity and rebases the header's absolute `keys`/`values`
    /// pointers to the new base. The result is an ordinary mutable map: a later
    /// `put`, iteration, and `deinit(allocator)` all behave normally. This
    /// reaches into std layout internals and is guarded by a unit test.
    fn cloneWordFrameCapacityMatched(src: LocalFrame, allocator: Allocator) !LocalFrame {
        if (src.metadata == null or src.size == 0) return .{};

        // Mirror the private layout of `std.HashMapUnmanaged`: a single
        // allocation of `[Header][metadata][keys][values]`, one metadata byte
        // per slot. `Header` must match std's field order so the copied header's
        // `keys`/`values` fields sit at the same offsets we overwrite below.
        const Metadata = u8;
        const K = []const u8;
        const V = WordDefinition;
        const Header = struct { values: [*]V, keys: [*]K, capacity: u32 };

        const header_align = @alignOf(Header);
        const key_align = @alignOf(K);
        const val_align = @alignOf(V);
        const max_align: std.mem.Alignment = comptime .fromByteUnits(@max(header_align, key_align, val_align));

        const cap: usize = src.capacity();
        const meta_size = @sizeOf(Header) + cap * @sizeOf(Metadata);
        const keys_start = std.mem.alignForward(usize, meta_size, key_align);
        const keys_end = keys_start + cap * @sizeOf(K);
        const vals_start = std.mem.alignForward(usize, keys_end, val_align);
        const vals_end = vals_start + cap * @sizeOf(V);
        const total_size = max_align.forward(vals_end);

        const src_base: [*]const u8 = @as([*]const u8, @ptrCast(src.metadata.?)) - @sizeOf(Header);
        const dst_slice = try allocator.alignedAlloc(u8, max_align, total_size);
        @memcpy(dst_slice, src_base[0..total_size]);

        const dst_base: [*]u8 = dst_slice.ptr;
        const hdr: *Header = @ptrCast(@alignCast(dst_base));
        hdr.keys = @ptrCast(@alignCast(dst_base + keys_start));
        hdr.values = @ptrCast(@alignCast(dst_base + vals_start));

        var dst: LocalFrame = .{};
        dst.metadata = @ptrCast(@alignCast(dst_base + @sizeOf(Header)));
        dst.size = src.size;
        dst.available = src.available;
        return dst;
    }

    /// Push a local frame populated with a module's deps and words.
    /// This makes the module's dependencies available for late-binding
    /// resolution when executing the module's own words.
    ///
    /// The module's own words take precedence over its dependencies.
    /// No lock on the push itself: a module-deps frame is a transient frame like a combinator
    /// frame, task-private and never read cross-task. Growth of the shared backing is the one
    /// locked step; see `ensureFrameCapacityForPush`.
    ///
    /// A module with a pre-built template gets a direct clone of it, avoiding a
    /// per-entry rehash. A module without one is rebuilt entry by entry. The
    /// empty frame is appended first so that a clone or populate failure unwinds
    /// through the same errdefer, with no owned allocation stranded.
    pub fn pushModuleDepsFrame(self: *Context, module: *const value_mod.Module) !void {
        try self.ensureFrameCapacityForPush();
        self.local_frames.appendAssumeCapacity(LocalFrame{});
        errdefer {
            self.local_frames.items[self.local_frames.items.len - 1].deinit(self.allocator);
            self.local_frames.items.len -= 1;
        }

        self.local_frame_kinds.appendAssumeCapacity(.module_deps);
        errdefer self.local_frame_kinds.items.len -= 1;
        self.local_frame_modules.appendAssumeCapacity(module);
        errdefer self.local_frame_modules.items.len -= 1;
        self.live_module_deps_frames += 1;
        errdefer self.live_module_deps_frames -= 1;
        self.assertFrameKindsParity();

        const frame_idx = self.local_frames.items.len - 1;
        if (module.deps_template) |tmpl| {
            self.local_frames.items[frame_idx] = try cloneWordFrameCapacityMatched(tmpl.frame, self.allocator);
        } else {
            try populateModuleDepsFrame(&self.local_frames.items[frame_idx], module, self.allocator);
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
            var pragma_vals = self.pragma_frames.items[last_idx].valueIterator();
            while (pragma_vals.next()) |v| container_backing.releaseValue(v.*);
            self.pragma_frames.items[last_idx].deinit(self.allocator);
            self.pragma_frames.items.len -= 1;
        }
    }

    /// Set a pragma value in the top frame.
    /// Takes ownership of `value`'s reference; the frame releases it on overwrite,
    /// frame pop, or context teardown.
    pub fn setPragma(self: *Context, name: []const u8, value: Value) !void {
        if (self.pragma_frames.items.len == 0) return error.NoPragmaFrame;
        const top_index = self.pragma_frames.items.len - 1;
        const gop = try self.pragma_frames.items[top_index].getOrPut(self.allocator, name);
        if (gop.found_existing) container_backing.releaseValue(gop.value_ptr.*);
        gop.value_ptr.* = value;
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

    /// How one of the redefinition collision guards reports a name.
    const CollisionGuardMode = enum { err, warning, off };

    /// Read the environment pragma `key` and decide how a collision on `name` is reported. An
    /// unset key is `error`, which is the severity both guards ship with.
    ///
    /// An allowlist relaxes exactly the names on it, so a word the user meant to shadow is silent
    /// while one they mistyped still throws. The validator has already proven the value is a
    /// severity word or an array of symbols, so anything else here is `error`.
    ///
    /// Callers hold the write lock, so the read goes through `getPragmaLocked`.
    fn collisionGuardMode(self: *const Context, key: []const u8, name: []const u8) CollisionGuardMode {
        const val = self.getPragmaLocked(key) orelse return .err;
        switch (val) {
            .string => |s| {
                if (std.mem.eql(u8, s.bytes, "warning")) return .warning;
                if (std.mem.eql(u8, s.bytes, "off")) return .off;
                return .err;
            },
            .array => |a| {
                for (a.items) |item| {
                    if (item == .symbol and std.mem.eql(u8, item.symbol.bytes, name)) return .off;
                }
                return .err;
            },
            else => return .err,
        }
    }

    /// Report a collision one of the guards has just confirmed: warn and let the definition stand,
    /// or throw.
    ///
    /// The caller reads the mode and formats `msg` only when it is not `.off`, so a relaxed name
    /// costs no allocation. That gating is why `.off` is a no-op here rather than unreachable.
    fn reportCollisionGuard(self: *Context, mode: CollisionGuardMode, msg: []const u8) error{ImportConflict}!void {
        switch (mode) {
            .off => {},
            .warning => {
                // No `override` hint: a user who asked for a warning chose the relaxation and is
                // not looking for the marker.
                var tw = trace_mod.TraceWriter.init();
                tw.print("warning: {s}\n", .{msg});
            },
            .err => {
                self.pending_error_hint = "add the 'override' marker if intentional";
                self.pending_error_message = msg;
                return error.ImportConflict;
            },
        }
    }

    /// Register a pragma key on the durable-state target, so a registration
    /// made during a module load outlives the loading context.
    pub fn registerPragmaKey(self: *Context, name: []const u8, registration: PragmaRegistration) !void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        const target = self.stateTarget();
        try target.pragma_registry.put(target.allocator, name, registration);
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

    /// Record `name` as the native in flight for the duration of the caller's scope, restoring
    /// whatever was in flight before. Definers nest: `;` runs a descriptor's `define:` quotation,
    /// which calls `define-struct`. The assertion wants the innermost one.
    ///
    /// Pass null on entry to compiled code or a host callback. Leaving a stale outer name in place
    /// there would blame it for a define it did not make.
    pub fn withCurrentNative(self: *Context, name: ?[]const u8) ?[]const u8 {
        if (comptime builtin.mode != .Debug) return null;
        const saved = self.current_native;
        self.current_native = name;
        return saved;
    }

    /// Restore what `withCurrentNative` returned.
    pub fn restoreCurrentNative(self: *Context, saved: ?[]const u8) void {
        if (comptime builtin.mode != .Debug) return;
        self.current_native = saved;
    }

    /// The `current_native` value an action runs under. A native names itself. A host callback
    /// clears the slot, since the assertion cannot attribute what host code defines. A body keeps
    /// whatever is already in flight, so an inner native still names itself.
    ///
    /// Takes `anytype` because `WordDefinition.Action` and `ModuleWord.Action` are separate unions
    /// over the same executable shapes.
    fn currentNativeFor(action: anytype, name: []const u8, in_flight: ?[]const u8) ?[]const u8 {
        return switch (action) {
            .native => name,
            .host_callback => null,
            else => in_flight,
        };
    }

    /// Every word installed while a native is in flight must come from a native that declared
    /// `defines_word`. The compiled tier reads that flag to decide whether a quotation body needs
    /// the interpreter's transient lexical frame, so an unflagged definer silently drops a binding
    /// into the durable frame the interpreter keeps it out of.
    ///
    /// The two define choke points are `defineWordLocked` and `defineImportedWordLocked`. A define
    /// with nothing in flight is out of scope: prelude registration, the C API, the image loader,
    /// and anything reached from compiled code all arrive that way.
    fn assertDefiningNativeDeclared(self: *const Context) void {
        if (comptime builtin.mode != .Debug) return;
        const native = self.current_native orelse return;
        if (primitives.nativeNameDefinesWord(native)) return;
        std.debug.panic("native '{s}' defines a word but is not marked defines_word", .{native});
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

    /// The topmost local frame the currently executing body may define into: the frame walk skips
    /// exactly the `.module_deps` frames `lookupWordLocked` skips under `active_deps_vis`, so a
    /// definition never lands in a frame the defining body's own filtered lookups cannot see. Null
    /// when no local frame is live.
    fn defineTargetFrameIndex(self: *const Context) ?usize {
        var i = self.local_frames.items.len;
        while (i > 0) {
            i -= 1;
            if (self.active_deps_vis) |v| {
                if (i < self.local_frame_kinds.items.len and self.local_frame_kinds.items[i] == .module_deps) {
                    const m = if (i < self.local_frame_modules.items.len) self.local_frame_modules.items[i] else null;
                    if (m) |module| {
                        if (!v.admits(module)) continue;
                    }
                }
            }
            return i;
        }
        return null;
    }

    /// Remove a word from the same scope `defineWordLocked` writes to: the
    /// topmost visible local frame when one exists, otherwise the dictionary.
    pub fn removeWord(self: *Context, name: []const u8) bool {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        if (self.defineTargetFrameIndex()) |top_index| {
            const entry = self.local_frames.items[top_index].fetchRemove(name);
            if (entry) |e| {
                if (e.value.owns_literal) container_backing.releaseValue(e.value.action.literal);
            }
            const removed = entry != null;
            if (removed and self.local_frames.items[top_index].count() == 0 and
                self.isTransientLexicalFrame(top_index) and self.nonempty_transient_lexical_frames > 0)
            {
                // Saturating: hand-built test frames may empty a frame the increment path never
                // counted. Production stays balanced by construction.
                self.nonempty_transient_lexical_frames -= 1;
            }
            return removed;
        }
        return self.dictionary.remove(name);
    }

    /// Whether `name` is a const-marked word in the baked base scope, walking the ancestor chain
    /// the way the const guard's lookup does. Read only when that lookup misses, so a visible
    /// binding keeps answering for the name first.
    fn bakedBaseScopeConstLocked(self: *const Context, name: []const u8) bool {
        var ctx_iter: ?*const Context = self;
        while (ctx_iter) |c| : (ctx_iter = c.parent_context) {
            const scope = c.aot_base_scope orelse continue;
            for (0..scope.count) |i| {
                if (!std.mem.eql(u8, std.mem.span(scope.names[i]), name)) continue;
                return scope.flags[i] & 2 != 0;
            }
        }
        return false;
    }

    fn defineWordLocked(self: *Context, name: []const u8, definition: WordDefinition) !void {
        self.assertDefiningNativeDeclared();

        // The const guard looks through an empty visibility, which admits no module and so skips
        // every `module_deps` frame. A deps frame is execution context for a module's bodies, not
        // a scope definitions land in. A const word visible only through such a frame, e.g.,
        // while a check-mode load runs from inside a module word whose module imports that const,
        // must not block the loaded file's own definitions.
        const const_guard_vis: ModuleDepsVisibility = .{ .deps_modules = &.{}, .defining_module = null };
        const visible_existing = self.lookupWordLocked(name, const_guard_vis);
        const existing_is_const = blk: {
            if (visible_existing) |existing| {
                for (existing.markers) |mk| {
                    if (markers_mod.isConstMarker(mk)) break :blk true;
                }
                break :blk false;
            }
            // In an AOT binary a const prelude binding lives in no frame and no dictionary, so
            // the baked base scope completes this guard's storage. A visible non-const binding
            // above it shadows it here as interpreted, since the lookup answered first.
            break :blk self.bakedBaseScopeConstLocked(name);
        };
        if (existing_is_const) {
            self.pending_error_message = std.fmt.allocPrint(
                self.arena.allocator(),
                "cannot redefine const word '{s}'",
                .{name},
            ) catch "cannot redefine const word";
            return error.CannotRedefineConst;
        }

        const target_frame_index = self.defineTargetFrameIndex();

        const same_scope_existing = if (target_frame_index) |ti|
            self.local_frames.items[ti].get(name)
        else
            self.dictionary.get(name);

        const claims_override = for (definition.markers) |mk| {
            if (markers_mod.isOverrideMarker(mk)) break true;
        } else false;

        // Both guards below skip when the existing and incoming words are both generic: two
        // generics of one name are one extension point.
        //
        // Unlike the import sink, the exemption skips the guard rather than the write, so the
        // definition still defines.
        const incoming_generic = markersContainGeneric(definition.markers);

        // The definition-side half of the import/definition collision guard: the import side is
        // `assert-no-shadow` in the prelude.
        //
        // Same-scope only. The dictionary is never the target of an import, so this fires only on
        // frame bindings.
        if (same_scope_existing) |existing| {
            if (existing.imported and !(incoming_generic and markersContainGeneric(existing.markers))) {
                if (!claims_override) {
                    // Read once the collision is confirmed, so an ordinary redefinition pays no
                    // pragma walk.
                    const mode = self.collisionGuardMode("import-collision", name);
                    if (mode != .off) {
                        const msg = if (existing.source_module) |sm|
                            std.fmt.allocPrint(
                                self.arena.allocator(),
                                "defining '{s}' would overwrite a word imported from \"{s}\"",
                                .{ name, sm.name },
                            ) catch "definition would overwrite an imported word"
                        else
                            std.fmt.allocPrint(
                                self.arena.allocator(),
                                "defining '{s}' would overwrite an imported word",
                                .{name},
                            ) catch "definition would overwrite an imported word";

                        try self.reportCollisionGuard(mode, msg);
                    }
                }
            }
        }

        // The dictionary-shadow half of the collision guard: a top-level definition whose name is
        // absent from its own frame but resolves in the base scope, in whatever form the tier
        // stores it: the frames below the durable floor, today the prelude frame, the native
        // dictionary, and an AOT binary's baked base scope.
        //
        // The gate is the import-target frame rather than the floor itself. A runtime load moves
        // only the import target and leaves the floor behind, so a module's own top level is
        // guarded, while the floor bounds the probe so the entry file's frame stays out of it. A
        // module defining a name the loading file also defines is therefore not a collision.
        // Word-body and quotation frames sit above the import target, so a transient binding named
        // like a prelude word stays legal.
        //
        // The probe walks the ancestor chain the way `lookupWordLocked` does, because a task
        // context has a null floor and an empty dictionary: a load inside a spawned task reaches
        // the prelude and the natives only through its ancestors, and its module is
        // process-lifetime, so the shadow is as durable as one made on the main task.
        if (same_scope_existing == null and !claims_override) {
            if (target_frame_index) |ti| {
                if (self.import_frame_index) |ifi| {
                    if (ti == ifi) {
                        var shadowed: ?WordDefinition = null;
                        var shadowed_is_native = false;
                        var ctx_iter: ?*const Context = self;
                        probe: while (ctx_iter) |c| : (ctx_iter = c.parent_context) {
                            if (c.durable_frame_floor) |floor| {
                                for (c.local_frames.items[0..floor]) |frame| {
                                    if (frame.get(name)) |d| {
                                        shadowed = d;
                                        break :probe;
                                    }
                                }
                            }
                            if (c.dictionary.get(name)) |d| {
                                shadowed = d;
                                shadowed_is_native = true;
                                break :probe;
                            }

                            // The baked base scope: an AOT binary loads no prelude frame, so the
                            // freeze bakes that frame's content instead, reachable or not. Only
                            // an AOT boot registers the tables, which keeps this rung inert in
                            // interpreter and eager sessions.
                            if (c.aot_base_scope) |scope| {
                                for (0..scope.count) |i| {
                                    if (!std.mem.eql(u8, std.mem.span(scope.names[i]), name)) continue;
                                    shadowed = .{
                                        .name = name,
                                        .source_file = if (scope.sources[i]) |src| std.mem.span(src) else null,
                                        .markers = if (scope.flags[i] & 1 != 0) &seeded_generic_markers else &.{},
                                        .action = .{ .native = aotCompiledOnlyBailSentinel },
                                    };
                                    break :probe;
                                }
                            }
                        }

                        if (shadowed) |sh| {
                            if (!(incoming_generic and markersContainGeneric(sh.markers))) {
                                // Read after the probe rather than before it, so an ordinary
                                // top-level definition pays no pragma walk.
                                const mode = self.collisionGuardMode("dictionary-shadow", name);
                                if (mode != .off) {
                                    const msg = if (shadowed_is_native)
                                        std.fmt.allocPrint(
                                            self.arena.allocator(),
                                            "defining '{s}' would shadow a native word",
                                            .{name},
                                        ) catch "definition would shadow a native word"
                                    else if (sh.source_file) |src|
                                        std.fmt.allocPrint(
                                            self.arena.allocator(),
                                            "defining '{s}' would shadow a word from \"{s}\"",
                                            .{ name, src },
                                        ) catch "definition would shadow an existing word"
                                    else
                                        std.fmt.allocPrint(
                                            self.arena.allocator(),
                                            "defining '{s}' would shadow an existing word",
                                            .{name},
                                        ) catch "definition would shadow an existing word";

                                    try self.reportCollisionGuard(mode, msg);
                                }
                            }
                        }
                    }
                }
            }
        }

        // A redefinition mints a fresh dispatch id, stranding the entries registered under the
        // old one with no later diagnostic. Dropping registered methods is reported here instead;
        // `override` claims the replacement deliberate.
        //
        // A generated existing word is exempt, matching the arity check below: overriding a
        // generated constructor is legitimate, and its entries are the generator's scaffolding.
        //
        // The table scan is gated on the existing word being able to receive methods at all,
        // which `define-method` limits to native-like words and generic-marked ones. A plain
        // word's redefinition, the common case, never walks the dispatch table.
        if (same_scope_existing) |existing| {
            if (existing.provenance == null and !claims_override and
                (existing.isNativeLike() or markersContainGeneric(existing.markers)))
            {
                const dropped = (try self.dispatchKeysForIdLocked(existing.dispatch_id, self.arena.allocator())).len;
                if (dropped > 0) {
                    self.pending_error_hint = "add the 'override' marker if intentional";
                    self.pending_error_message = std.fmt.allocPrint(
                        self.arena.allocator(),
                        "redefining '{s}' would drop {d} registered method{s}",
                        .{ name, dropped, if (dropped == 1) @as([]const u8, "") else "s" },
                    ) catch "redefinition would drop registered methods";
                    return error.OrphanedMethods;
                }
            }
        }

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
                                .string => |s| std.mem.eql(u8, s.bytes, "warning"),
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

        // Minted from the root so ids are process-globally unique
        def.dispatch_id = self.rootContext().next_dispatch_id.fetchAdd(1, .monotonic);
        self.assertMintedDispatchIdFresh(def.dispatch_id);
        if (def.source_file == null) {
            if (self.generated_src_loc) |gen| {
                def.source_file = gen.file;
                def.source_line = gen.line;
                def.source_column = gen.column;
            } else {
                def.source_file = self.defBodyParseSource(def) orelse self.current_source;
                if (self.call_stack.items.len > 0) {
                    const frame = self.call_stack.items[self.call_stack.items.len - 1];
                    def.source_line = frame.line;
                    def.source_column = frame.column;
                }
            }
        }
        def.exec_flags = computeExecFlags(def);

        // A bound value arrives owned: `;` popped it, so the definition inherits that reference.
        // A binding in a transient lexical frame keeps the reference on the frame, so the call
        // that created the binding reclaims it when its frame pops. A durable binding -- the
        // import frame or the dictionary -- has no such point, so it hands the reference to the
        // dictionary's teardown list below.
        //
        // Only a leaf backing takes frame ownership. A container would be reclaimed by a frame it
        // can outlive through a captured scope that also owns it; see `valueCarriesLeafBacking`.
        def.owns_literal = switch (def.action) {
            .literal => |val| target_frame_index != null and
                self.isTransientLexicalFrame(target_frame_index.?) and
                container_backing.valueCarriesLeafBacking(val),
            .native, .host_callback, .compound => false,
        };

        if (target_frame_index) |top_index| {
            const was_empty = self.local_frames.items[top_index].count() == 0;
            try self.local_frames.items[top_index].put(self.allocator, name, def);
            if (same_scope_existing) |displaced| {
                if (displaced.owns_literal) container_backing.releaseValue(displaced.action.literal);
            }
            if (was_empty and self.isTransientLexicalFrame(top_index)) {
                self.nonempty_transient_lexical_frames += 1;
            }
        } else {
            try self.dictionary.put(name, def);
        }

        // A definition of a name that already named a word strands the dispatch entries keyed to
        // the id that name used to carry.
        //
        // A displaced same-scope word loses its own id. A definition landing above a lower-scope
        // word instead changes which id an already-warm call site resolves to. Either way a warm
        // cache answers for a word the scope no longer names, and the satisfies memo counts those
        // same entries.
        if (visible_existing != null or same_scope_existing != null) {
            const target = self.stateTarget();
            target.dispatch.generation +%= 1;
            target.protocol_satisfies_cache.clearRetainingCapacity();
            if (target != self) {
                self.dispatch.generation +%= 1;
                self.protocol_satisfies_cache.clearRetainingCapacity();
            }
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
                try self.registerCompoundBody(instrs);
            },
            .literal => |val| {
                // The teardown list is the same lifetime the compound-body release list gave a
                // bound container before bindings stopped allocating a body.
                if (!def.owns_literal and container_backing.valueCarriesBacking(val)) {
                    try self.retainValueForTeardown(val);
                }
            },
            .native, .host_callback => {},
        }
    }

    /// Overwrite the `dispatch_id` of an already-defined word in place, in the same scope
    /// `defineWordLocked` just wrote to (the topmost local frame, or the dictionary when no frame
    /// is active). `defineWordLocked` always mints a fresh monotonic id for a newly-defined word;
    /// this lets a caller then force it onto a dispatch_id shared across scopes instead, e.g. a
    /// `struct{`-generated field accessor that must dispatch through the same table as an
    /// identically-named accessor a different, mutually-invisible scope already defined.
    pub fn overrideWordDispatchId(self: *Context, name: []const u8, dispatch_id: u32) void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        if (self.local_frames.items.len > 0) {
            const top = &self.local_frames.items[self.local_frames.items.len - 1];
            if (top.getPtr(name)) |def| def.dispatch_id = dispatch_id;
        } else if (self.dictionary.getPtr(name)) |def| {
            def.dispatch_id = dispatch_id;
        }
    }

    /// Attempt JIT compilation of a newly defined word. Silently ignores
    /// all errors so the word falls back to the interpreter.
    fn tryAutoCompile(self: *Context, name: []const u8, def: WordDefinition) void {
        if (comptime is_freestanding) return;

        const instrs = switch (def.action) {
            .compound => |i| i,
            // No JIT/hybrid integration for literal words yet; they have
            // no instruction body to compile.
            .native, .host_callback, .literal => return,
        };

        const effect = def.stack_effect orelse return;

        for (def.markers) |mk| {
            if (markers_mod.isParseTimeOnlyMarker(mk)) return;
            if (markers_mod.isParseTimeMarker(mk)) return;
            if (markers_mod.isGenericMarker(mk)) return;
        }

        if (stack_effect_mod.hasAnyRowVariable(effect.*)) return;

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

        const compiled = ir_codegen.compileWordWithPicSnapshot(instrs, input_count, output_count, resolver, name, pic_snapshot, self, null, effect, def.source_file) catch return;

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
        if (self.jit_dispatch.getMut(final_id)) |em| em.stack_effect = def.stack_effect;

        if (self.trace.trace_jit) {
            var tw = trace_mod.TraceWriter.init();
            trace_mod.traceJitCompile(&tw, name, final_id);
        }

        const dump_cfg = jit_dump.DumpConfig{ .dump_bytes = self.trace.dump_jit_bytes, .bin_dir = self.trace.dump_jit_bin_dir };
        if (dump_cfg.enabled() and trace_mod.matchesPattern(name, self.trace.dump_jit_word_pattern))
            jit_dump.dumpJitCode(dump_cfg, name, final_id, compiled.code_ptr, compiled.jit_buf.size);
    }

    /// Assign a word_id without compiling. Used in hybrid mode so the dispatch
    /// table entry exists for call counting when the word is later executed.
    fn tryAssignWordId(self: *Context, name: []const u8, def: WordDefinition) void {
        switch (def.action) {
            .compound => {},
            .native, .host_callback, .literal => return,
        }

        if (def.stack_effect == null) return;
        const effect = def.stack_effect.?;

        for (def.markers) |mk| {
            if (markers_mod.isParseTimeOnlyMarker(mk)) return;
            if (markers_mod.isParseTimeMarker(mk)) return;
            if (markers_mod.isGenericMarker(mk)) return;
            if (markers_mod.isNoCompileMarker(mk)) return;
        }

        if (stack_effect_mod.hasAnyRowVariable(effect.*)) return;

        if (def.word_id != null) return;

        const new_id = self.jit_dispatch.assignId(name) catch return;
        if (self.jit_dispatch.getMut(new_id)) |em| em.stack_effect = def.stack_effect;
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
        self.assertDefiningNativeDeclared();

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

            if (markersContainGeneric(existing.markers) and markersContainGeneric(definition.markers)) {
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
            def.source_file = self.defBodyParseSource(def) orelse self.current_source;
            if (self.call_stack.items.len > 0) {
                const frame = self.call_stack.items[self.call_stack.items.len - 1];
                def.source_line = frame.line;
                def.source_column = frame.column;
            }
        }
        def.exec_flags = computeExecFlags(def);

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
        return self.lookupWordLocked(name, null);
    }

    /// Like `lookupWord`, but `vis` filters which transient `.module_deps` frames the lookup may
    /// see (see `ModuleDepsVisibility`). AOT freeze-time discovery uses this so a body's bare words
    /// resolve only against its own module's frame, not a sibling module's frame that discovery
    /// happens to have pushed. Unlike `lookupWordForExecution`, it does not consult the runtime-image
    /// module cache; freeze runs before any image is loaded.
    pub fn lookupWordFiltered(self: *const Context, name: []const u8, vis: ?ModuleDepsVisibility) ?WordDefinition {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupWordLocked(name, vis);
    }

    /// Like `lookupWord`, but falls through to the AOT runtime-image module cache when the
    /// in-context lookup misses and an image is loaded. Use this at interpreter call sites
    /// that have to resolve module-private names living only inside a loaded runtime image,
    /// e.g. a parameter's default quotation that calls a module-private helper.
    ///
    /// The fallback is gated on `runtime_image_loaded` so normal `load`-based module sessions
    /// keep their privacy boundary. Both the AOT loader and a source-level `load` keep private
    /// helpers in `module.deps`, so the `words`-only sweep reaches a loaded image's public
    /// surface without crossing into any module's private names.
    ///
    /// Definition- and parse-time callers must stick to `lookupWord` so they never see
    /// sibling modules' words.
    pub fn lookupWordForExecution(self: *const Context, name: []const u8) ?WordDefinition {
        return self.lookupWordForExecutionFiltered(name, null, null);
    }

    /// Like `lookupWordForExecution`, but `vis` filters the executing body's view of transient
    /// `.module_deps` frames (see `ModuleDepsVisibility`), and `defining_module` is the executing
    /// body's defining module when it has one.
    ///
    /// The runtime-image fallback is scoped by `defining_module`. A module-less body takes the
    /// module-cache scan as its by-name last resort. A body with a defining module skips it and
    /// misses on any module-owned name outside its scope; see `moduleCacheContainsWordLocked`.
    pub fn lookupWordForExecutionFiltered(
        self: *const Context,
        name: []const u8,
        vis: ?ModuleDepsVisibility,
        defining_module: ?*const value_mod.Module,
    ) ?WordDefinition {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        if (self.lookupWordLocked(name, vis)) |def| return def;
        if (!self.runtime_image_loaded) return null;
        if (defining_module == null) {
            if (self.lookupModuleCacheWordLocked(name)) |def| return def;
        } else if (self.moduleCacheContainsWordLocked(name)) {
            return null;
        }
        return self.lookupAotCompiledWordLocked(name);
    }

    /// `lookupWordForExecutionFiltered` with the executing body's own module scope probed first,
    /// ahead of the transient frame walk, all under one shared-read acquisition. A body written
    /// inside a module thereby resolves a bare word against that module's scope even when the
    /// module's frame is not live and an unrelated frame binds the same name.
    ///
    /// The probe consults `own_module`'s `words` then `deps`, then each `ambient_deps` module the
    /// same way; first hit wins. `words` before `deps` mirrors `populateModuleDepsFrame`, so a
    /// module's own definition beats its import of the same name. A hit pushes no frame and
    /// allocates nothing, and is synthesized in the same shape the module's own deps frame would
    /// hold, so a probe hit executes exactly like a frame hit. See `lookupModuleScopeWord` for the
    /// one addition, source attribution.
    ///
    /// A body with an `own_module` skips the module-cache scan and misses on any module-owned
    /// name outside its scope; see `moduleCacheContainsWordLocked`.
    pub fn lookupWordForExecutionOwnScope(
        self: *const Context,
        name: []const u8,
        vis: ?ModuleDepsVisibility,
        own_module: ?*const value_mod.Module,
        ambient_deps: []const *const value_mod.Module,
    ) ?WordDefinition {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        if (lookupOwnScopeLocked(name, own_module, ambient_deps)) |def| return def;
        if (self.lookupWordLocked(name, vis)) |def| return def;
        if (!self.runtime_image_loaded) return null;
        if (own_module == null) {
            if (self.lookupModuleCacheWordLocked(name)) |def| return def;
        } else if (self.moduleCacheContainsWordLocked(name)) {
            return null;
        }
        return self.lookupAotCompiledWordLocked(name);
    }

    fn lookupOwnScopeLocked(
        name: []const u8,
        own_module: ?*const value_mod.Module,
        ambient_deps: []const *const value_mod.Module,
    ) ?WordDefinition {
        if (own_module) |m| {
            if (lookupModuleScopeWord(name, m)) |def| return def;
        }
        for (ambient_deps) |m| {
            if (m == own_module) continue;
            if (lookupModuleScopeWord(name, m)) |def| return def;
        }
        return null;
    }

    /// Build the `WordDefinition` a body sees when its own module scope resolves `name`, without
    /// performing the lookup. The AOT image loader uses this to fill a build-time-resolved call
    /// target's slot with exactly what the runtime probe would have produced for the same hit.
    pub fn moduleScopeWordDef(
        name: []const u8,
        mod_word: value_mod.ModuleWord,
        module: *const value_mod.Module,
    ) WordDefinition {
        var def = moduleWordFrameDef(name, mod_word, module);

        // Carry the recorded definition site so `executeResolvedWord` attributes the body's error
        // frames to the file the word is written in, matching a durable-frame resolution. A
        // `private{ }` helper is the exception: its recorded source points at the machinery that
        // defined it, not the module file, so the fields stay null and the caller's source stands,
        // which for a helper is the enclosing module's own file.
        if (!isSyntheticScopeModule(mod_word.source_module)) {
            def.source_file = mod_word.source_file;
            def.source_line = mod_word.source_line;
            def.source_column = mod_word.source_column;
        }
        return def;
    }

    fn lookupModuleScopeWord(name: []const u8, module: *const value_mod.Module) ?WordDefinition {
        // The deps template is the pristine words-over-deps merge of the two maps probed below, so
        // a name absent from it is absent from both. Most probes are misses -- every prelude word
        // called inside a module body probes here first -- and the template makes a miss cost one
        // map get instead of two.
        if (module.deps_template) |tmpl| {
            if (tmpl.frame.get(name) == null) return null;
        }

        const mod_word = module.words.get(name) orelse module.deps.get(name) orelse return null;
        return moduleScopeWordDef(name, mod_word, module);
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

    /// `vis`, when non-null, filters this context's own transient frames: a `.module_deps` frame the
    /// executing body may not see is skipped, so a stored quotation does not resolve against a
    /// foreign library's frame that merely happens to be live. Only the self walk is filtered; the
    /// ancestor walk visits durable frames below the durable floor, which are never `.module_deps`.
    fn lookupWordLocked(self: *const Context, name: []const u8, vis: ?ModuleDepsVisibility) ?WordDefinition {
        var i = self.local_frames.items.len;
        while (i > 0) {
            i -= 1;
            if (vis) |v| {
                if (i < self.local_frame_kinds.items.len and self.local_frame_kinds.items[i] == .module_deps) {
                    const m = if (i < self.local_frame_modules.items.len) self.local_frame_modules.items[i] else null;
                    if (m) |module| {
                        if (!v.admits(module)) continue;
                    }
                }
            }
            if (self.local_frames.items[i].get(name)) |def| {
                return def;
            }
        }

        if (self.dictionary.get(name)) |def| return def;

        var ancestor = self.parent_context;
        while (ancestor) |ctx| {
            const anc_cap = if (ctx.durable_frame_floor) |idx| idx + 1 else 0;
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

    /// Scan every cached module's public `words` table for `name`.
    /// Module `deps` are deliberately skipped: deps hold a module's
    /// private imports, and `load`-ing a 1z module surfaces public
    /// API through `words` only. Checking deps would leak names out
    /// of their owning module's privacy boundary (see the
    /// `local_scope` integration test). The AOT runtime-image
    /// loader routes its private-flagged rows into `deps` too, so
    /// the words-only sweep holds the same boundary for both cases.
    ///
    /// This is the last-resort by-name rung, reachable only by a body with no defining module:
    /// dynamic-eval'd code and unstamped quotations. When two cached modules export the same
    /// name, the hit from the lexicographically smallest `Module.name` wins. Two runtime loads
    /// of same-named files from different directories carry equal names, so the cache key, a
    /// unique resolved path, breaks the tie. The answer is independent of hash-iteration order.
    fn lookupModuleCacheWordLocked(self: *const Context, name: []const u8) ?WordDefinition {
        const Candidate = struct {
            mod_word: value_mod.ModuleWord,
            module: *const value_mod.Module,
            cache_key: []const u8,
        };
        var best: ?Candidate = null;
        self.module_cache_value.header.lock();
        var iter = self.module_cache_value.map.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* != .module) continue;
            const module = entry.value_ptr.*.module;
            const mod_word = module.words.get(name) orelse continue;
            const better = if (best) |b| switch (std.mem.order(u8, module.name, b.module.name)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.lessThan(u8, entry.key_ptr.*, b.cache_key),
            } else true;
            if (better) {
                best = .{ .mod_word = mod_word, .module = module, .cache_key = entry.key_ptr.* };
            }
        }
        self.module_cache_value.header.unlock();
        const hit = best orelse return null;
        return wordDefFromModuleWord(name, hit.mod_word, hit.module);
    }

    /// True when any cached module's public `words` holds `name`.
    ///
    /// This is the module-word veto for a body with a defining module. Such a body resolves
    /// everything it may legitimately see through its own module scope, the frame walk, and the
    /// dictionary, so a hit anywhere else could only be a foreign module's unimported word.
    /// Skipping the scan alone would not make that name miss: a public module word in an image
    /// build is normally compiled and bare-name registered in `jit_dispatch`, so the sweep below
    /// the scan would resolve it. A module-owned name therefore resolves nowhere for such a body,
    /// matching the interpreter.
    ///
    /// A name owned by no module still falls through to the sweep, so a stamped body keeps
    /// reaching an entry-file top-level word. That parity is partial: a module export colliding
    /// with the entry word's name trips the veto, where the interpreter's durable frame would
    /// resolve the entry word. The pre-gate scan resolved the module's word on that path too, so
    /// nothing that worked is lost.
    fn moduleCacheContainsWordLocked(self: *const Context, name: []const u8) bool {
        self.module_cache_value.header.lock();
        defer self.module_cache_value.header.unlock();
        var iter = self.module_cache_value.map.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* != .module) continue;
            if (entry.value_ptr.*.module.words.contains(name)) return true;
        }
        return false;
    }

    /// Find a cached module by its exact name.
    ///
    /// Used during AOT freeze to re-establish a callee's defining-module scope while discovering
    /// its body.
    pub fn moduleByNameInCache(self: *const Context, name: []const u8) ?*const value_mod.Module {
        self.module_cache_value.header.lock();
        defer self.module_cache_value.header.unlock();
        var iter = self.module_cache_value.map.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* != .module) continue;
            const module = entry.value_ptr.*.module;
            if (std.mem.eql(u8, module.name, name)) return module;
        }
        return null;
    }

    /// Resolve a compiled word's registered module segment to its cached module.
    ///
    /// The segment is an exact `Module.name`. Two cached modules can share one name; the hit
    /// from the lexicographically smallest cache key wins, mirroring
    /// `lookupModuleCacheWordLocked`'s tie-break, so the answer is independent of
    /// hash-iteration order. A freeze-discriminated segment carries a `#rank` suffix that
    /// matches no cached module, so a colliding pair's entries miss here and the caller falls
    /// back to its bare-name ladder.
    fn cachedModuleBySegmentLocked(self: *const Context, segment: []const u8) ?*const value_mod.Module {
        const Candidate = struct {
            module: *const value_mod.Module,
            cache_key: []const u8,
        };
        var best: ?Candidate = null;
        self.module_cache_value.header.lock();
        var iter = self.module_cache_value.map.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* != .module) continue;
            const module = entry.value_ptr.*.module;
            if (!std.mem.eql(u8, module.name, segment)) continue;
            const better = if (best) |b| std.mem.lessThan(u8, entry.key_ptr.*, b.cache_key) else true;
            if (better) {
                best = .{ .module = module, .cache_key = entry.key_ptr.* };
            }
        }
        self.module_cache_value.header.unlock();
        const hit = best orelse return null;
        return hit.module;
    }

    /// `cachedModuleBySegmentLocked` under its own shared-read acquisition, for callers outside
    /// the lookup ladder such as AOT startup registration.
    pub fn cachedModuleBySegment(self: *const Context, segment: []const u8) ?*const value_mod.Module {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.cachedModuleBySegmentLocked(segment);
    }

    /// Resolve `name` through the module scope of the cached module `segment` names, under one
    /// shared-read acquisition. This is the exact resolution for a `JitEntry` carrying a module.
    ///
    /// Returns null when the segment resolves no cached module or the module's scope does not
    /// hold `name`; the caller keeps its bare-name ladder for that case.
    pub fn lookupWordViaModuleSegment(self: *const Context, segment: []const u8, name: []const u8) ?WordDefinition {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        const module = self.cachedModuleBySegmentLocked(segment) orelse return null;
        return lookupModuleScopeWord(name, module);
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
        var def: WordDefinition = .{
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
            .body_owner = mod_word.body_owner,
            .action = switch (mod_word.action) {
                .compound => |instrs| .{ .compound = instrs },
                .native => |func| .{ .native = func },
                .host_callback => |host| .{ .host_callback = host },
            },
        };
        // Module-cache words are synthesized fresh on each lookup rather than
        // stored through the finalization points, so compute the flags here so
        // `executeResolvedWord` reads correct bits for module-private words.
        def.exec_flags = computeExecFlags(def);
        return def;
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
            const anc_cap = if (ctx.durable_frame_floor) |idx| idx + 1 else 0;
            for (ctx.local_frames.items[0..anc_cap]) |frame| {
                if (frame.contains(name)) return null;
            }
        }

        self.module_cache_value.header.lock();
        defer self.module_cache_value.header.unlock();
        var iter = self.module_cache_value.map.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* != .module) continue;
            const module = entry.value_ptr.*.module;
            if (module.words.contains(name)) return null;
            if (module.deps.contains(name)) return null;
        }

        return slot;
    }

    /// Look up a word and return its stack effect pointer, which the JIT compiler bakes as a
    /// compile-time constant. The address is the definition's own boxed effect, so it stays
    /// valid for the process however the definition is copied around.
    pub fn lookupWordStackEffectPtr(self: *const Context, name: []const u8) ?*const StackEffect {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupWordStackEffectPtrLocked(name);
    }

    fn lookupWordStackEffectPtrLocked(self: *const Context, name: []const u8) ?*const StackEffect {
        const def = self.lookupWordLocked(name, null) orelse return null;
        return def.stack_effect;
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
            const anc_cap = if (ctx.durable_frame_floor) |idx| idx + 1 else 0;
            var j = anc_cap;
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
            // Only the ancestor's stable scope is resolvable from a descendant
            // task; its transient frames are task-private execution state we do
            // not walk across the spawn boundary.
            const anc_cap = if (ctx.durable_frame_floor) |idx| idx + 1 else 0;
            var j = anc_cap;
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
            const anc_cap = if (ctx.durable_frame_floor) |idx| idx + 1 else 0;

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
        var c: ?*const Context = self;
        while (c) |cur| {
            if (cur.aot_generic_dispatch_ids.get(word_name)) |did| return did;
            c = cur.parent_context;
        }
        return null;
    }

    /// The dispatch id `word`'s native entries were registered under.
    ///
    /// This is the native's own identity, so a shadowing binding of the name never answers in
    /// its place.
    pub fn nativeDispatchId(self: *const Context, word: dispatch_mod.NativeDispatchWord) u32 {
        return self.native_dispatch_ids.get(word);
    }

    /// Record every identity-carrying native's own dispatch id.
    ///
    /// Called once from `init`, after the primitives are in the dictionary and before any frame
    /// exists, so each by-name resolution reaches the dictionary definition its entries key off.
    /// A word that resolves to nothing panics here rather than leaving a zero behind, since zero
    /// is a real primitive's id and would silently dispatch under that word's identity.
    ///
    /// The sweep covers the whole enum rather than each module capturing its own, because several
    /// of these natives have no entries at init: `freeze!` has none at all, and `>symbol` and the
    /// typed-container mutators get theirs when an `enum{` or a parameterized type is defined.
    pub fn captureNativeDispatchIds(self: *Context) void {
        for (std.enums.values(dispatch_mod.NativeDispatchWord)) |word| {
            const did = self.resolveDispatchId(word.wordName()) orelse
                std.debug.panic("Native dispatch word '{s}' is not a primitive", .{word.wordName()});
            self.native_dispatch_ids.set(word, did);
        }
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
        const word = self.lookupWordLocked(name, null) orelse return null;
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
            .literal => |val| switch (val) {
                .type_val => |tv| return tv,
                .tagged => |t| return t.tag.type_val,
                else => return null,
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
            // Self reads all its frames; an ancestor is read only through its
            // stable scope (the durable floor and below), never its live
            // transient frames, so this walk stays clear of another task's
            // lockless combinator push/pop and of a runtime load's live frame.
            var frame_idx = if (ancestor == self)
                ancestor.local_frames.items.len
            else if (ancestor.durable_frame_floor) |idx| idx + 1 else 0;
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
                        .literal => |val| switch (val) {
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
                    .literal => |val| switch (val) {
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
        params: []const *const value_mod.TypeValue,
    ) ?*value_mod.TypeDescriptor {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupParameterizedTypeDescriptorLocked(base, params);
    }

    fn lookupParameterizedTypeDescriptorLocked(
        self: *const Context,
        base: *const value_mod.TypeValue,
        params: []const *const value_mod.TypeValue,
    ) ?*value_mod.TypeDescriptor {
        const key = ParameterizedTypeKey{ .base = base, .params = params };
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
        field_types: []const ?value_mod.ConstraintCombinator.Element,
        mutable: bool,
    ) ?*value_mod.TypeDescriptor {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.lookupStructDescriptorLocked(fields, field_types, mutable);
    }

    fn lookupStructDescriptorLocked(
        self: *const Context,
        fields: []const []const u8,
        field_types: []const ?value_mod.ConstraintCombinator.Element,
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
        const target = self.stateTarget();
        try target.resource_type_values.put(target.allocator, name, tv);
    }

    /// Register a struct type by name.
    ///
    /// Called when a `struct{ }` is defined so the runtime-image loader can recover the canonical
    /// StructType for a compiled-construction instance.
    pub fn registerStructType(self: *Context, name: []const u8, st: *value_mod.StructType) !void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        try self.struct_types_by_name.put(self.allocator, name, st);
    }

    /// Look up a struct type by name, or null if none is registered.
    pub fn lookupStructTypeByName(self: *const Context, name: []const u8) ?*value_mod.StructType {
        self.acquireSharedRead();
        defer self.releaseSharedRead();
        return self.struct_types_by_name.get(name);
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

    /// Allocate a fresh ConstraintCombinator owned by this Context. Each call
    /// produces a distinct descriptor with a unique monotonic combinator_id;
    /// there is no structural interning, mirroring createProtocolDescriptor.
    /// The element list is copied into the quotation arena. The list header is
    /// freed by deinit.
    pub fn createConstraintCombinator(
        self: *Context,
        kind: value_mod.ConstraintCombinator.Kind,
        elements: []const value_mod.ConstraintCombinator.Element,
    ) !*value_mod.ConstraintCombinator {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();

        const alloc = self.quotationAllocator();
        const desc = try alloc.create(value_mod.ConstraintCombinator);
        const elements_dup = try alloc.alloc(value_mod.ConstraintCombinator.Element, elements.len);
        @memcpy(elements_dup, elements);
        desc.* = .{
            .kind = kind,
            .elements = elements_dup,
            .combinator_id = self.next_combinator_id.fetchAdd(1, .monotonic),
        };
        try self.constraint_combinators.append(self.allocator, desc);
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

    /// Diagnostic identity for a combinator-bounded dispatch site:
    /// `satisfies-and-dispatch[constraint]`. Combinators have no stored name, so
    /// the identity is generic; composed once per combinator and memoized.
    pub fn boundedCombinatorTraceName(
        self: *Context,
        cc: *const value_mod.ConstraintCombinator,
    ) []const u8 {
        if (self.bounded_dispatch_combinator_trace_names.get(cc)) |name| return name;
        const name = "satisfies-and-dispatch[constraint]";
        self.bounded_dispatch_combinator_trace_names.put(self.allocator, cc, name) catch return name;
        return name;
    }

    /// Diagnostic identity for a bounded dispatch site, dispatching on whether the
    /// bound is a protocol or a constraint combinator.
    pub fn boundedConstraintTraceName(
        self: *Context,
        constraint: dispatch_helpers.BoundedConstraint,
    ) []const u8 {
        return switch (constraint) {
            .protocol => |pd| self.boundedDispatchTraceName(pd),
            .combinator => |cc| self.boundedCombinatorTraceName(cc),
        };
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

    /// Walk a base TypeValue to the struct that ultimately backs it, following virtual descriptors
    /// through to their inner type.
    ///
    /// Returns the struct's TypeValue, or null when the root is not a struct. `self` is unused.
    /// The method form keeps the parameter-binding helpers.
    pub fn rootStructTypeValue(_: *const Context, tv: *const value_mod.TypeValue) ?*const value_mod.TypeValue {
        var cur = tv;
        while (true) {
            const desc = cur.descriptor orelse return null;
            switch (desc.kind) {
                .struct_ => return cur,
                .virtual => |vd| cur = vd.inner_type orelse return null,
                else => return null,
            }
        }
    }

    /// A base type's parameter view for binding:
    ///
    /// - the `declared` list carries the canonical parameter names and positions; and
    /// - `current` carries the base's present bound/unbound tuple.
    ///
    /// For a bare struct the two coïncide.
    ///
    /// For a partially-bound virtual base, `current` is the wrapper's `type_params` and
    /// `declared` is the root struct's.
    pub const BaseParams = struct {
        declared: []const *const value_mod.TypeValue,
        current: []const *const value_mod.TypeValue,
    };

    pub fn resolveBaseParams(self: *const Context, base_tv: *const value_mod.TypeValue) BaseParams {
        const desc = base_tv.descriptor orelse return .{ .declared = &.{}, .current = &.{} };
        switch (desc.kind) {
            .struct_ => |sd| return .{ .declared = sd.type_params, .current = sd.type_params },
            .enum_ => |ed| return .{ .declared = ed.type_params, .current = ed.type_params },
            .virtual => |vd| {
                const root = self.rootStructTypeValue(base_tv) orelse
                    return .{ .declared = &.{}, .current = vd.type_params };
                const declared = switch (root.descriptor.?.kind) {
                    .struct_ => |sd| sd.type_params,
                    else => &[_]*const value_mod.TypeValue{},
                };
                return .{ .declared = declared, .current = vd.type_params };
            },
            else => return .{ .declared = &.{}, .current = &.{} },
        }
    }

    pub fn getOrCreateParameterizedTypeDescriptor(
        self: *Context,
        base: *const value_mod.TypeValue,
        params: []const *const value_mod.TypeValue,
    ) !*value_mod.TypeDescriptor {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();

        if (self.lookupParameterizedTypeDescriptorLocked(base, params)) |desc| return desc;

        const alloc = self.quotationAllocator();
        // One durable copy backs both the descriptor's type_params and the
        // interning key, so the stored key outlives the caller's slice.
        const owned_params = try alloc.dupe(*const value_mod.TypeValue, params);
        const desc = try value_mod.createTypeDescriptor(
            alloc,
            .{ .virtual = .{
                .inner_type = base,
                .type_params = owned_params,
            } },
            .{},
        );

        try self.parameterized_type_descriptors.put(
            self.allocator,
            .{ .base = base, .params = owned_params },
            desc,
        );
        return desc;
    }

    /// Collect the distinct type parameters referenced by a struct's field
    /// types. Delegates to `value_mod.deriveStructTypeParams`; kept on Context
    /// as the hosted-facing entry point.
    pub fn deriveStructTypeParams(alloc: std.mem.Allocator, field_types: []const ?value_mod.ConstraintCombinator.Element) ![]const *const value_mod.TypeValue {
        return value_mod.deriveStructTypeParams(alloc, field_types);
    }

    /// Collect the distinct enum-level type parameters referenced by a list of
    /// variant type values. Delegates to `value_mod.deriveEnumTypeParams`; kept
    /// on Context as the hosted-facing entry point.
    pub fn deriveEnumTypeParams(alloc: std.mem.Allocator, variant_tvs: []const *const value_mod.TypeValue) ![]const *const value_mod.TypeValue {
        return value_mod.deriveEnumTypeParams(alloc, variant_tvs);
    }

    pub fn getOrCreateStructDescriptor(
        self: *Context,
        fields: []const []const u8,
        field_types: []const ?value_mod.ConstraintCombinator.Element,
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
        const owned_field_types: []const ?value_mod.ConstraintCombinator.Element = if (field_types.len != 0) blk: {
            const buf = try alloc.alloc(?value_mod.ConstraintCombinator.Element, field_types.len);
            for (field_types, 0..) |ft, i| buf[i] = ft;
            break :blk buf;
        } else &.{};

        // Project the declared type parameters out of the field types, ordered by
        // first appearance (which is position order). A parameter shared across
        // several fields appears once. `field_types` stays the source of truth.
        const type_params = try deriveStructTypeParams(alloc, owned_field_types);

        const desc = try value_mod.createTypeDescriptor(
            alloc,
            .{ .struct_ = .{
                .fields = owned_fields,
                .field_types = owned_field_types,
                .type_params = type_params,
            } },
            .{ .mutable = mutable },
        );

        const target = self.stateTarget();
        try target.struct_descriptors.put(
            target.allocator,
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
        const target = self.stateTarget();
        if (target.type_registry_frames.items.len == 0) return error.NoTypeRegistryFrame;
        const top = target.type_registry_frames.items.len - 1;
        try target.type_registry_frames.items[top].type_descriptors.put(target.allocator, name, desc);
    }

    /// Register enum variants into the topmost type registry frame.
    pub fn registerEnumVariants(self: *Context, enum_tv: *const value_mod.TypeValue, variants: []const *const value_mod.VirtualType) !void {
        self.acquireSharedWrite();
        defer self.releaseSharedWrite();
        return self.registerEnumVariantsLocked(enum_tv, variants);
    }

    fn registerEnumVariantsLocked(self: *Context, enum_tv: *const value_mod.TypeValue, variants: []const *const value_mod.VirtualType) !void {
        const target = self.stateTarget();
        if (target.type_registry_frames.items.len == 0) return error.NoTypeRegistryFrame;
        const top = target.type_registry_frames.items.len - 1;
        try target.type_registry_frames.items[top].enum_registry.put(target.allocator, enum_tv, variants);
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
        const target = self.stateTarget();
        if (target.dispatch_frames.items.len > 0) {
            const top = target.dispatch_frames.items.len - 1;
            const gop = try target.dispatch_frames.items[top].entries.getOrPut(target.allocator, key);
            if (gop.found_existing and !allow_overwrite) {
                return error.DuplicateMethod;
            }
            gop.value_ptr.* = entry;
            target.dispatch.generation +%= 1;
        } else {
            try target.dispatch.register(key, entry, allow_overwrite);
        }
        // Any new method binding may flip a satisfies-check answer; clear
        // coarsely. (Reached only on a successful register.) A redirected
        // register is observable through the executing context's ancestor
        // walk too, so its cache and PIC generation invalidate as well.
        target.protocol_satisfies_cache.clearRetainingCapacity();
        if (target != self) {
            self.dispatch.generation +%= 1;
            self.protocol_satisfies_cache.clearRetainingCapacity();
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
        if (self.dispatch.entries.get(key)) |entry| return entry;
        // A redirected load registers on the target, so a duplicate check
        // during the load must see what was just written there.
        if (self.load_target) |target| {
            if (@as(*const Context, target) != self) return target.getDispatchEntryLocked(key);
        }
        return null;
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
                const cmp_b = std.mem.order(u8, a_b_name, b_b_name);
                if (cmp_b != .eq) return cmp_b == .lt;

                // Two descriptors resolving to the same name, or to no name at all, would
                // otherwise keep raw hash-collection order. Registration sequence breaks the tie
                // for base-table entries. A tie between frame entries keeps collection order,
                // which is hash order; that residual cannot reach emission, since dispatch frames
                // are popped before freeze collects.
                return a.entry.sequence < b.entry.sequence;
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

    /// A dot-qualified name split into its module path and word name.
    pub const QualifiedName = struct {
        module_path: []const u8,
        word_name: []const u8,
    };

    /// Split a name on its rightmost dot. Returns null when there is no dot
    /// or either half is empty.
    ///
    /// This is the canonical qualified-name split. Every resolver that
    /// handles dot-qualified names must go through it so the rules cannot
    /// drift between the interpreter, introspection, and analysis passes.
    pub fn splitQualifiedName(name: []const u8) ?QualifiedName {
        const dot_index = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
        const module_path = name[0..dot_index];
        const word_name = name[dot_index + 1 ..];
        if (module_path.len == 0 or word_name.len == 0) return null;
        return .{ .module_path = module_path, .word_name = word_name };
    }

    /// Extract the module literal from a `load`-produced binding: a compound
    /// whose single instruction pushes a module value. Does not execute any
    /// code, so a binding that computes its module is not resolvable here.
    pub fn moduleLiteralFromWordDef(def: WordDefinition) ?*value_mod.Module {
        switch (def.action) {
            .literal => |val| return switch (val) {
                .module => |m| m,
                else => null,
            },
            .native, .host_callback => return null,
            .compound => {},
        }
        const instrs = def.action.compound;
        if (instrs.len != 1) return null;
        return switch (instrs[0].op) {
            .push_literal => |val| switch (val) {
                .module => |m| m,
                else => null,
            },
            else => null,
        };
    }

    /// Resolve a dot-qualified name to its ModuleWord by inspecting the
    /// module binding's literal, without executing it.
    pub fn resolveQualifiedModuleWord(self: *const Context, name: []const u8) ?value_mod.ModuleWord {
        const qn = splitQualifiedName(name) orelse return null;
        const binding = self.lookupWord(qn.module_path) orelse return null;
        const module = moduleLiteralFromWordDef(binding) orelse return null;
        return module.words.get(qn.word_name);
    }

    /// Execute a qualified name like "math.double".
    /// Splits on the rightmost dot, executes the module word to get a module,
    /// then looks up and executes the word in that module.
    fn executeQualifiedName(self: *Context, name: []const u8, line: usize, column: usize) anyerror!void {
        const qn = splitQualifiedName(name) orelse return ExecutionError.UnknownWord;
        const module_path = qn.module_path;
        const word_name = qn.word_name;

        if (self.lookupWord(module_path)) |module_word| {
            self.pushCallFrame(module_path, self.current_source, line, column, module_word.stack_effect);
            defer self.popCallFrame();

            const saved_native = self.withCurrentNative(currentNativeFor(module_word.action, module_path, self.current_native));
            defer self.restoreCurrentNative(saved_native);

            switch (module_word.action) {
                .native => |func| try func(self),
                .host_callback => |host| {
                    const rc = host.callback(host.handle, host.user_data);
                    if (rc != 0) return error.HostCallbackFailed;
                },
                .compound => |instrs| try self.executeInstructions(instrs, null, null, module_word.body_owner),
                .literal => |v| try self.stack.push(v),
            }
        } else {
            return ExecutionError.UnknownWord;
        }

        // Release is a no-op for the module hit; it covers the mismatch drop.
        const module_val = self.stack.pop() catch return ExecutionError.UnknownWord;
        defer container_backing.releaseValue(module_val);
        const module = switch (module_val) {
            .module => |m| m,
            else => return error.TypeMismatch,
        };

        if (module.words.get(word_name)) |mod_word| {
            if (self.active_sandbox) |sandbox| {
                if (!sandbox.allows(mod_word.capability)) {
                    self.pending_error_message = std.fmt.allocPrint(
                        self.arena.allocator(),
                        "'{s}' requires capability '{s}' which is not granted by the active sandbox",
                        .{ name, mod_word.capability.displayName() },
                    ) catch "word denied by sandbox";
                    self.appendPendingErrorFrame(.{
                        .word_name = name,
                        .source = self.current_source,
                        .line = line,
                        .column = column,
                        .stack_effect = mod_word.stack_effect,
                    });
                    return error.PermissionDenied;
                }
            }

            if (self.trace.trace_resolve and trace_mod.matchesPattern(name, self.trace.trace_resolve_pattern)) {
                var tw = trace_mod.TraceWriter.init();
                trace_mod.traceResolve(&tw, name, .{ .qualified_found = .{ .module = module_path, .word = word_name } });
            }

            self.pushCallFrame(name, self.current_source, line, column, mod_word.stack_effect);
            if (self.trace.trace_words and trace_mod.matchesPattern(name, self.trace.trace_words_pattern)) {
                var tw = trace_mod.TraceWriter.init();
                trace_mod.traceWord(&tw, name, self.current_source, line, &self.stack);
            }
            defer self.popCallFrame();

            // The bare name, which is how a `native`-module registry entry is keyed.
            const saved_word_native = self.withCurrentNative(currentNativeFor(mod_word.action, word_name, self.current_native));
            defer self.restoreCurrentNative(saved_word_native);

            // On error, pend this frame before the defer pops it, so a raise inside the
            // body keeps its qualified row.
            //
            // The effect is dropped deliberately: the innermost qualified row has never
            // rendered a stack-effect line, and pinned goldens hold that shape.
            errdefer {
                if (self.call_stack.items.len > 0) {
                    var frame = self.call_stack.items[self.call_stack.items.len - 1];
                    frame.stack_effect = null;
                    self.appendPendingErrorFrame(frame);
                }
            }

            // A qualified call reaches the body without going through `executeResolvedWord`, so
            // the callee's file is installed here instead.
            const saved_source = self.current_source;
            defer self.current_source = saved_source;
            if (mod_word.source_file) |sf| self.current_source = sf;

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
                    try self.executeQuotationWithPic(.{ .instructions = instrs }, null, module, mod_word.body_owner);
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
    ///
    /// `effect` is the named word's own declared effect when the caller has its definition in
    /// hand, and null otherwise.
    pub fn pushCallFrame(self: *Context, word_name: []const u8, source: []const u8, line: usize, column: usize, effect: ?*const StackEffect) void {
        self.call_stack.append(self.allocator, .{
            .word_name = word_name,
            .source = source,
            .line = line,
            .column = column,
            .stack_effect = effect,
        }) catch {};
    }

    /// Push a frame located at the word's definition rather than a call site, marked so the
    /// capture fold can drop it beside a same-word call-site row.
    pub fn pushDefinitionLocatedCallFrame(self: *Context, word_name: []const u8, source: []const u8, line: usize, effect: ?*const StackEffect) void {
        self.call_stack.append(self.allocator, .{
            .word_name = word_name,
            .source = source,
            .line = line,
            .definition_located = true,
            .stack_effect = effect,
        }) catch {};
    }

    /// Set the topmost frame's effect, for the shims that resolve their word only after pushing.
    pub fn setTopCallFrameEffect(self: *Context, effect: ?*const StackEffect) void {
        if (self.call_stack.items.len > 0) {
            self.call_stack.items[self.call_stack.items.len - 1].stack_effect = effect;
        }
    }

    /// Pop a call frame from the call stack.
    pub fn popCallFrame(self: *Context) void {
        if (self.call_stack.items.len > 0) {
            _ = self.call_stack.pop();
        }
    }

    /// Memory-limit abort hook: write the aborting thread's call stack to stderr, innermost
    /// frame first.
    ///
    /// Runs on the abort path, so it must not allocate; each line is formatted into a stack
    /// buffer and written with a raw `write`.
    pub fn memoryAbortReport(opaque_ctx: *anyopaque) void {
        const ctx: *Context = @ptrCast(@alignCast(opaque_ctx));
        const frames = ctx.call_stack.items;
        var buf: [512]u8 = undefined;
        var i = frames.len;
        while (i > 0) {
            i -= 1;
            const line = formatAbortFrame(&buf, frames[i], i == frames.len - 1);
            writeRawStderr(line);
        }
    }

    /// Render one call frame for the memory-limit abort report into `buf`.
    /// The innermost frame names the word; caller frames mirror the error
    /// renderer's "called from" lines.
    fn formatAbortFrame(buf: []u8, frame: CallFrame, innermost: bool) []const u8 {
        if (innermost) {
            if (frame.column > 0) {
                return std.fmt.bufPrint(buf, "  at word '{s}' ({s}:{d}:{d})\n", .{ frame.word_name, frame.source, frame.line, frame.column }) catch "";
            }
            return std.fmt.bufPrint(buf, "  at word '{s}' ({s}:{d})\n", .{ frame.word_name, frame.source, frame.line }) catch "";
        }
        return std.fmt.bufPrint(buf, "  called from {s}:{d}: {s}\n", .{ frame.source, frame.line, frame.word_name }) catch "";
    }

    fn writeRawStderr(msg: []const u8) void {
        var written: usize = 0;
        while (written < msg.len) {
            written += std.posix.write(std.posix.STDERR_FILENO, msg[written..]) catch break;
        }
    }

    const MAX_INFERENCE_DEPTH = 8;

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
        unknown,
    };

    // The inline shadow buffer below is sized off this. A wider slot multiplies across every
    // inference frame on the task stack, so a variant that widens the union changes this
    // assertion deliberately.
    comptime {
        if (@sizeOf(usize) == 8) {
            std.debug.assert(@sizeOf(SlotType) == 16);
        }
    }

    /// The inference's shadow stack.
    ///
    /// Slots live in a fixed inline buffer until the body's depth exceeds it, so the common walk
    /// allocates nothing. Past that the slots spill to a heap list, which then owns every slot for
    /// the rest of the walk.
    ///
    /// A shrink after the spill stays on the heap. The verdict is the same on either side.
    const ShadowStack = struct {
        const inline_capacity = 16;

        allocator: Allocator,
        inline_slots: [inline_capacity]SlotType = undefined,
        inline_len: usize = 0,
        spilled: ?std.ArrayListUnmanaged(SlotType) = null,

        fn deinit(self: *ShadowStack) void {
            if (self.spilled) |*list| list.deinit(self.allocator);
        }

        fn len(self: *const ShadowStack) usize {
            if (self.spilled) |*list| return list.items.len;
            return self.inline_len;
        }

        fn slice(self: *ShadowStack) []SlotType {
            if (self.spilled) |*list| return list.items;
            return self.inline_slots[0..self.inline_len];
        }

        fn constSlice(self: *const ShadowStack) []const SlotType {
            if (self.spilled) |*list| return list.items;
            return self.inline_slots[0..self.inline_len];
        }

        /// Fails only on the spill allocation itself.
        fn append(self: *ShadowStack, slot: SlotType) Allocator.Error!void {
            if (self.spilled) |*list| return list.append(self.allocator, slot);

            if (self.inline_len < inline_capacity) {
                self.inline_slots[self.inline_len] = slot;
                self.inline_len += 1;
                return;
            }

            var list = std.ArrayListUnmanaged(SlotType){};
            try list.ensureTotalCapacity(self.allocator, inline_capacity * 2);
            list.appendSliceAssumeCapacity(self.inline_slots[0..self.inline_len]);
            list.appendAssumeCapacity(slot);
            self.spilled = list;
        }

        fn shrinkTo(self: *ShadowStack, new_len: usize) void {
            if (self.spilled) |*list| return list.shrinkRetainingCapacity(new_len);
            self.inline_len = new_len;
        }

        fn clear(self: *ShadowStack) void {
            self.shrinkTo(0);
        }
    };

    /// Infer a quotation's stack delta by statically analyzing its instructions.
    /// Returns null if the delta cannot be determined (e.g., unknown words, control flow).
    fn inferQuotationDelta(self: *Context, quot: Quotation, enclosing_effect: ?*const StackEffect) ?i64 {
        return self.inferQuotationDeltaImpl(quot, 0, enclosing_effect);
    }

    /// `inferQuotationDelta` through the per-call-site memo.
    ///
    /// A hit is an entry at `slot` whose guards match the argument body and the enclosing effect. A
    /// miss walks, and a successful walk fills the entry, displacing whatever was there, so a site
    /// that alternates arguments walks each time. A walk that cannot infer is never recorded: it
    /// skips validation today, and recording that would freeze the skip at a site whose argument
    /// may become inferable later.
    ///
    /// The caller has already decided admissibility. Both keys are checked against the live
    /// closure-body registry at the write, which is the independent check on that decision.
    fn inferQuotationDeltaAt(self: *Context, quot: Quotation, enclosing_effect: *const StackEffect, slot: ?ParamEffectSiteKey) ?i64 {
        const arg_body = @intFromPtr(quot.instructions.ptr);

        if (slot) |key| {
            if (self.param_effect_cache.get(key)) |entry| {
                if (entry.arg_body == arg_body and entry.effect == enclosing_effect) return entry.delta;
            }
        }

        const delta = self.inferQuotationDelta(quot, enclosing_effect) orelse return null;

        if (slot) |key| {
            if (comptime builtin.mode == .Debug) {
                closure_body_registry.assertNotLive(key.body);
                closure_body_registry.assertNotLive(arg_body);
            }

            self.param_effect_cache.put(self.allocator, key, .{
                .arg_body = arg_body,
                .effect = enclosing_effect,
                .delta = delta,
            }) catch {};
        }

        return delta;
    }

    fn inferQuotationDeltaImpl(self: *Context, quot: Quotation, depth: u32, enclosing_effect: ?*const StackEffect) ?i64 {
        if (depth >= MAX_INFERENCE_DEPTH) return null;

        var delta: i64 = 0;
        var shadow = ShadowStack{ .allocator = self.allocator };
        defer shadow.deinit();

        if (enclosing_effect) |eff| {
            for (eff.inputs) |param| {
                if (param.is_row_variable) continue;
                const slot: SlotType = if (param.quotation_effect) |qe|
                    .{ .known = qe }
                else
                    .unknown;
                shadow.append(slot) catch {};
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
                    shadow.append(slot) catch {
                        shadow.clear();
                    };
                },
                .call_word, .call_word_direct, .call_word_module => {
                    const name = instr.op.callTargetName().?;
                    if (matchShuffleWord(name)) |shuffle| {
                        if (self.lookupWord(name)) |word| {
                            if (word.stack_effect) |word_effect| {
                                const word_delta = word_effect.concreteDelta();
                                if (applyShuffleShadow(&shadow, shuffle)) {
                                    delta += word_delta;
                                    continue;
                                }
                                delta += word_delta;
                                adjustShadowStack(&shadow, word_delta);
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
                                    adjustShadowForTransparent(&shadow, word_effect.*, resolved.quot_delta);
                                }
                            } else {
                                return null;
                            }
                        } else if (word.stack_effect) |word_effect| {
                            if (!word_effect.hasBalancedRowVariables()) {
                                if (self.resolveUnbalancedDelta(word_effect.*, &shadow)) |resolved_delta| {
                                    delta += resolved_delta;
                                    adjustShadowStack(&shadow, resolved_delta);
                                } else {
                                    return null;
                                }
                            } else {
                                const word_delta = word_effect.concreteDelta();
                                delta += word_delta;
                                adjustShadowStack(&shadow, word_delta);
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

    fn resolveTransparentDelta(self: *Context, word: WordDefinition, shadow: *const ShadowStack) ?TransparentResolution {
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

        const slots = shadow.constSlice();
        const offset_from_tos = concrete_inputs - 1 - qi;
        if (offset_from_tos >= slots.len) return null;

        const slot = slots[slots.len - 1 - offset_from_tos];
        const quot_delta: i64 = switch (slot) {
            .known => |eff| eff.concreteDelta(),
            .inferred_delta => |d| d,
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
    fn resolveUnbalancedDelta(self: *Context, word_effect: StackEffect, shadow: *const ShadowStack) ?i64 {
        _ = self;
        const concrete_inputs = word_effect.concreteInputCount();
        const slots = shadow.constSlice();

        var row_env = RowVarEnv{};

        var concrete_idx: usize = 0;
        for (word_effect.inputs) |param| {
            if (param.is_row_variable) continue;

            if (param.quotation_effect) |quot_effect| {
                const offset_from_tos = concrete_inputs - 1 - concrete_idx;
                if (offset_from_tos < slots.len) {
                    const slot = slots[slots.len - 1 - offset_from_tos];
                    const inferred_delta: i64 = switch (slot) {
                        .known => |eff| eff.concreteDelta(),
                        .inferred_delta => |d| d,
                        .unknown => {
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

    fn adjustShadowStack(shadow: *ShadowStack, delta: i64) void {
        if (delta < 0) {
            const to_remove: usize = @intCast(@min(-delta, @as(i64, @intCast(shadow.len()))));
            shadow.shrinkTo(shadow.len() - to_remove);
        } else if (delta > 0) {
            const to_add: usize = @intCast(delta);
            for (0..to_add) |_| {
                shadow.append(.unknown) catch {
                    shadow.clear();
                    return;
                };
            }
        }
    }

    fn adjustShadowForTransparent(shadow: *ShadowStack, effect: StackEffect, quot_delta: i64) void {
        const concrete_inputs = effect.concreteInputCount();
        const concrete_outputs = effect.concreteOutputCount();
        const pass_throughs = stack_effect_mod.passThroughParams(effect);

        if (pass_throughs.len == 0) {
            const total_delta = -@as(i64, @intCast(concrete_inputs)) + @as(i64, @intCast(concrete_outputs)) + quot_delta;
            adjustShadowStack(shadow, total_delta);
            return;
        }

        var saved: [8]SlotType = undefined;
        for (pass_throughs.slice()) |pt| {
            const pos = shadow.len() -| (concrete_inputs - pt.input_concrete_idx);
            if (pos < shadow.len()) {
                saved[pt.input_concrete_idx] = shadow.constSlice()[pos];
            } else {
                saved[pt.input_concrete_idx] = .unknown;
            }
        }

        const to_pop = @min(concrete_inputs, shadow.len());
        shadow.shrinkTo(shadow.len() - to_pop);

        if (quot_delta < 0) {
            const to_remove: usize = @intCast(@min(-quot_delta, @as(i64, @intCast(shadow.len()))));
            shadow.shrinkTo(shadow.len() - to_remove);
        } else if (quot_delta > 0) {
            const to_add: usize = @intCast(quot_delta);
            for (0..to_add) |_| {
                shadow.append(.unknown) catch {
                    shadow.clear();
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

            shadow.append(slot) catch {
                shadow.clear();
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

    fn applyShuffleShadow(shadow: *ShadowStack, op: ShuffleOp) bool {
        const items = shadow.slice();
        const len = items.len;
        switch (op) {
            .swap => {
                if (len < 2) return false;
                const tmp = items[len - 1];
                items[len - 1] = items[len - 2];
                items[len - 2] = tmp;
            },
            .dup_ => {
                if (len < 1) return false;
                const top = items[len - 1];
                shadow.append(top) catch return false;
            },
            .drop_ => {
                if (len < 1) return false;
                shadow.shrinkTo(len - 1);
            },
            .over => {
                if (len < 2) return false;
                const second = items[len - 2];
                shadow.append(second) catch return false;
            },
            .rot => {
                // a b c -- b c a
                if (len < 3) return false;
                const a = items[len - 3];
                items[len - 3] = items[len - 2];
                items[len - 2] = items[len - 1];
                items[len - 1] = a;
            },
            .neg_rot => {
                // a b c -- c a b
                if (len < 3) return false;
                const c = items[len - 1];
                items[len - 1] = items[len - 2];
                items[len - 2] = items[len - 3];
                items[len - 3] = c;
            },
        }
        return true;
    }

    /// Validate a quotation against an expected effect by inferring its delta.
    /// Returns an error if the quotation doesn't match the expected effect.
    ///
    /// An effect with unbalanced row variables is skipped before inferring: its expected delta
    /// could only come from the same inference, so the comparison cannot report a mismatch.
    ///
    /// `slot` names the call-site memo entry the inference may read or fill, or null when the site
    /// is not cacheable.
    fn validateQuotationEffect(self: *Context, quot: Quotation, expected_effect: *const StackEffect, param_name: []const u8, enclosing_effect: *const StackEffect, slot: ?ParamEffectSiteKey) !void {
        if (!expected_effect.hasBalancedRowVariables()) return;

        const expected_delta = expected_effect.concreteDelta();

        const inferred_delta = self.inferQuotationDeltaAt(quot, enclosing_effect, slot);

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

    /// The executable body behind a callable stack value, or null for anything
    /// else. Curry and compose products are closures, so the parameter-effect
    /// validation must see through both forms.
    fn callableView(val: Value) ?Quotation {
        return switch (val) {
            .quotation => |q| q,
            .closure => |c| c.asQuotation(),
            else => null,
        };
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

    /// The interpreter call site a parameter-effect validation runs for: the caller's body, the
    /// call's index in it, and the carrier for that body. A compiled call site has no body pointer
    /// and index in hand, so it passes none and takes the walk.
    pub const ParamEffectSite = struct {
        instructions: []const Instruction,
        index: usize,
        owner: ?*const value_mod.Closure,
    };

    /// The memo key for parameter `param` of the call at `site`, or null when nothing may be
    /// recorded there.
    ///
    /// A closure-owned body is refused on either side, the caller's through its carrier and the
    /// argument's through the value itself. A push-time promotion aliases a durable body and passes.
    /// An empty argument body is refused too: every zero-length slice shares one address, so the
    /// guard could not tell two apart.
    fn paramEffectSlot(site: ?ParamEffectSite, val: Value, quot: Quotation, param: usize) ?ParamEffectSiteKey {
        const s = site orelse return null;

        if (s.owner) |c| {
            if (c.ownsBody(s.instructions)) return null;
        }
        if (quot.instructions.len == 0) return null;
        if (val == .closure and val.closure.ownsBody(quot.instructions)) return null;

        return .{ .body = @intFromPtr(s.instructions.ptr), .index = s.index, .param = param };
    }

    /// Validate quotation parameters against their declared effects.
    /// Uses static analysis to infer the quotation's stack delta and compares
    /// against the expected effect from the parameter annotation.
    /// Also validates that row variables in quotation effects are defined in the word's effect.
    ///
    /// When `site` is given, each inference goes through the per-call-site memo under the key
    /// `paramEffectSlot` admits.
    pub fn validateParameterEffects(self: *Context, effect: *const StackEffect, site: ?ParamEffectSite) !void {
        // First, validate that all row variables in quotation effects are defined
        for (effect.inputs) |param| {
            if (param.quotation_effect) |quot_effect| {
                try self.validateRowVariables(quot_effect, effect, param.name);
            }
        }

        const concrete_params = effect.concreteInputCount();

        if (concrete_params == 0 or self.stack.depth() < concrete_params) return;

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

                // Get the stack value at this offset and validate if it's a callable
                const stack_index = self.stack.depth() - 1 - offset_from_top;
                const val = self.stack.items.items[stack_index];
                if (callableView(val)) |quot| {
                    const slot = paramEffectSlot(site, val, quot, concrete_index);
                    try self.validateQuotationEffect(quot, expected_effect, param.name, effect, slot);
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
            if (pv == .string and std.mem.eql(u8, pv.string.bytes, "off")) return;
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
                        .string => |s| std.mem.eql(u8, s.bytes, "warning"),
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
                        .string => |s| std.mem.eql(u8, s.bytes, "warning"),
                        else => false,
                    } else false;

                    if (is_warning) {
                        var tw = trace_mod.TraceWriter.init();
                        tw.print("warning: {s}\n", .{msg});
                    } else {
                        return protocols_mod.raiseProtocolError(self, msg);
                    }
                },
                .combination => |cc| {
                    if (scope == .except_protocols) continue;

                    const val_tv = helpers.resolveValueTypeValue(self, val) orelse continue;
                    if (val_tv.descriptor == null) continue;

                    const satisfies = try protocols_mod.typeSatisfiesConstraint(self, val_tv, .{ .combinator = cc });
                    if (satisfies) continue;

                    const actual_name = val_tv.name;
                    const msg = std.fmt.allocPrint(self.arena.allocator(), "parameter '{s}': type '{s}' does not satisfy the required constraint", .{ param.name, actual_name }) catch "constraint mismatch";

                    const is_warning = if (self.getPragma("type-check")) |pv2| switch (pv2) {
                        .string => |s| std.mem.eql(u8, s.bytes, "warning"),
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

    /// Report an unresolved runtime-image slot as an `image-slot-miss` detail row.
    ///
    /// One condition, one name: the bytecode decoder's callers and the compiled `jitPush*Slot`
    /// callbacks both report a slot miss through this helper, so the row shape stays identical
    /// whether the miss was reached at load or through compiled code.
    pub fn recordImageSlotMiss(self: *Context, kind: []const u8, slot: usize) void {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s} slot {d}", .{ kind, slot }) catch return;
        const owned = self.arena.allocator().dupe(u8, msg) catch return;
        self.error_details.append(self.allocator, .{
            .error_type = "image-slot-miss",
            .message = owned,
            .source = "<aot-runtime>",
            .line = 0,
            .word_name = owned,
        }) catch {};
    }

    /// Fold everything in flight. A reader at the outermost boundary owns every row and frame
    /// there is, so it takes no mark.
    pub fn finalizeErrorDetails(self: *Context, err: anyerror) void {
        self.finalizeErrorDetailsAbove(err, 0, 0);
    }

    /// Fold the pending compiled frames and the live call stack into error_details, attaching
    /// the pending message, hint, and dispatch diagnostics to the innermost row.
    ///
    /// Idempotent, so every reader of error_details calls it before reading.
    ///
    /// The two marks come from a mid-chain consumer's entry snapshot and bound the fold to the
    /// state that consumer's own subtree produced. Rows and frames below them belong to an
    /// enclosing unwind and are left where they are. `call_stack` takes no mark: its frames are
    /// live callers, and they are the caught error's outer rows.
    ///
    /// A chain already present above `detail_mark` is the first error's. Frames queued after its
    /// capture still describe that error's unwind, so they are dropped rather than surfacing as
    /// another error's frames.
    ///
    /// With nothing to fold, no pending state is consumed, so a pending message survives for
    /// the readers that render it without frames.
    pub fn finalizeErrorDetailsAbove(self: *Context, err: anyerror, detail_mark: usize, pending_frame_mark: usize) void {
        if (self.error_details.items.len > detail_mark) {
            self.truncatePendingErrorFrames(pending_frame_mark);
            return;
        }

        if (self.jit_pending_trace_frames.items.len <= pending_frame_mark and self.call_stack.items.len == 0) {
            return;
        }

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

        var pending_i: usize = pending_frame_mark;
        while (pending_i < self.jit_pending_trace_frames.items.len) : (pending_i += 1) {
            const frame = self.jit_pending_trace_frames.items[pending_i];

            // A definition-located frame whose call site queued its own frame for the same word
            // would render that word twice. Drop it and let the call-site row take the message,
            // carrying the effect along when the surviving row has none of its own.
            if (frame.definition_located and pending_i + 1 < self.jit_pending_trace_frames.items.len and
                std.mem.eql(u8, self.jit_pending_trace_frames.items[pending_i + 1].word_name, frame.word_name))
            {
                if (self.jit_pending_trace_frames.items[pending_i + 1].stack_effect == null) {
                    self.jit_pending_trace_frames.items[pending_i + 1].stack_effect = frame.stack_effect;
                }
                continue;
            }

            const message = if (is_innermost and thrown_msg != null)
                thrown_msg.?
            else if (is_innermost and pending_msg != null)
                pending_msg.?
            else
                frame.word_name;

            const se_str: ?[]const u8 = if (is_innermost) self.renderFrameStackEffect(frame) else null;

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

        self.truncatePendingErrorFrames(pending_frame_mark);

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

            const se_str: ?[]const u8 = if (is_innermost) self.renderFrameStackEffect(frame) else null;

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

    /// Render the frame's carried effect for an error row.
    ///
    /// The frame's own pointer is the only source consulted. Resolving `frame.word_name` here
    /// would answer with whichever binding holds the name now, which is the misattribution the
    /// carried effect exists to remove.
    fn renderFrameStackEffect(self: *Context, frame: CallFrame) ?[]const u8 {
        const se = frame.stack_effect orelse return null;
        var buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        se.write(fbs.writer()) catch return null;
        return self.arena.allocator().dupe(u8, fbs.getWritten()) catch null;
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

    fn inferGenericDispatchArity(self: *Context, word_name: []const u8, stack_effect: ?*const StackEffect) usize {
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

    pub fn setGenericDispatchErrorDetails(self: *Context, word_name: []const u8, stack_effect: ?*const StackEffect) void {
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
    ///
    /// This is the entry point for a body reached as a value rather than as a word: a quotation
    /// passed to a combinator, a top-level statement, a tail-called body replayed by the
    /// debugger. A word body enters through `executeQuotationWithPic` directly, with
    /// `current_source` already set from the word's own file.
    pub fn executeQuotation(self: *Context, quotation: Quotation) anyerror!void {
        return self.executeQuotationWithOwner(quotation, null);
    }

    /// `executeQuotation` for a body reached through a value that may own it.
    ///
    /// `owner` is the closure the body belongs to, or null. A body a closure owns carries its
    /// captured scope and defining module on that closure instead of in `quotation_scope_info`,
    /// which is keyed by an address the closure frees on release. Threading the value through is
    /// what lets body entry read them.
    ///
    /// A sibling rather than a widened `executeQuotation`, because the hundred-odd call sites of
    /// that name almost all run a word body or a synthesized one and have no owner to state.
    pub fn executeQuotationWithOwner(self: *Context, quotation: Quotation, owner: ?*const value_mod.Closure) anyerror!void {
        const saved_source = self.current_source;
        defer self.current_source = saved_source;
        self.enterBodySource(quotation.instructions);

        return self.executeQuotationWithPic(quotation, null, null, owner);
    }

    /// Point `current_source` at the file `instructions` was parsed from, leaving it alone for a
    /// body with no recorded file. The caller owns the save and restore.
    ///
    /// A frame pushed while the body runs then names the file its line belongs to. Without this a
    /// quotation written in one file and called by a word defined in another reports the word's
    /// file against the quotation's line.
    ///
    /// Every entry point that runs a body reached as a value owes this call. A word body is
    /// exempt: `executeResolvedWord` installs the word's own file before it runs the body.
    pub fn enterBodySource(self: *Context, instructions: []const Instruction) void {
        if (self.quotationBodySource(instructions)) |src| self.current_source = src;
    }

    /// Execute a quotation with an optional PIC table for inline caching.
    ///
    /// `initial_module` names the defining module of a module-word body, threaded into the
    /// `.module_deps` visibility filter so the body may resolve against its own module's frame even
    /// where the pointer-keyed stamp is absent (e.g. a spawned child whose stamp map is empty). It is
    /// distinct from `current_module`, which tracks frame *ownership*: a body-module hint never pushes
    /// a frame.
    ///
    /// `owner` is the closure `quotation` came out of, when the body may be one that closure
    /// owns. See `executeQuotationWithOwner`.
    ///
    /// This does not install the body's source file. Callers arrive with it already pointed at the
    /// right file: a word body from the word's own `source_file`, a body reached as a value from
    /// `enterBodySource`. Probing here instead would put a lookup on every word call to recompute
    /// what the caller already knows.
    pub fn executeQuotationWithPic(self: *Context, quotation: Quotation, pic_table: ?*PicTable, initial_module: ?*const value_mod.Module, owner: ?*const value_mod.Closure) anyerror!void {
        const saved_source = self.current_source;
        defer self.current_source = saved_source;

        var current_instructions = quotation.instructions;
        var current_pic = pic_table;
        var current_module: ?*const value_mod.Module = null;
        var body_module: ?*const value_mod.Module = initial_module;
        var current_owner = owner;
        var owns_frame = false;

        while (true) {
            // Record depth before execution for validation
            const depth_before = self.stack.depth();
            self.tail_call_instructions = null;
            self.tail_call_module = null;
            self.tail_call_source = null;
            self.tail_call_body_owner = null;

            // Push module deps frame on first entry into a module context. On
            // subsequent iterations, the frame persists so that runtime-defined
            // local words, e.g. a recursive helper inside a module word, remain
            // visible across tail calls.
            if (current_module != null and !owns_frame) {
                try self.pushModuleDepsFrame(current_module.?);
                owns_frame = true;
            }

            const exec_result = self.executeInstructions(current_instructions, current_pic, body_module, current_owner);
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

                // The carrier follows the body, so it is replaced rather than inherited: the
                // callee names its own closure when it has one, and null when it does not. A tail
                // call back into the same body still resolves, because `;` records that closure on
                // the word it defines.
                current_owner = self.tail_call_body_owner;
                self.tail_call_body_owner = null;

                const new_module = self.tail_call_module;
                self.tail_call_module = null;

                // The tail-called word's body resolves as its own module (or as a module-less local
                // when null), regardless of frame ownership below.
                body_module = new_module;

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
    ///
    /// `owner` is the closure `quotation` came out of, when the body may be one that closure
    /// owns. See `executeQuotationWithOwner`.
    pub fn executeQuotationWithFrame(self: *Context, quotation: Quotation, owner: ?*const value_mod.Closure) anyerror!void {
        try self.pushLocalFrame();
        // Truncation before the pop, not instead of it: a spliced quotation body inside the
        // compiled arm can leave its own transient frame open on an error return, and
        // `popLocalFrame` pops the top.
        const frame_mark = self.local_frames.items.len;
        defer self.popLocalFrame();
        defer self.truncateLocalFrames(frame_mark);

        // quotation.code_ptr is never set on freestanding targets.
        if (comptime !is_freestanding) {
            if (quotation.code_ptr) |ptr| {
                const saved_sp = self.stack.items.items.len;
                var jit_ctx = ir_codegen.JitContext{
                    .items_ptr = self.stack.items.items.ptr,
                    .sp_ptr = &self.stack.items.items.len,
                    .capacity = self.stack.items.capacity,
                    .ctx = self,
                };
                const saved_native = self.withCurrentNative(null);
                defer self.restoreCurrentNative(saved_native);
                const func: ir_codegen.CompiledFn = @ptrCast(@alignCast(ptr));
                switch (ir_codegen.ExecResult.fromStatus(func(&jit_ctx))) {
                    .ok => return,
                    .error_propagate => {
                        const err = self.jit_pending_error orelse error.UserThrown;
                        self.jit_pending_error = null;

                        // A quotation has no word name and the interpreter renders no frame
                        // for one, so pend a stand-in frame only when the fold would otherwise
                        // see zero frames and silently drop the pending message.
                        const bare = self.jit_pending_trace_frames.items.len == 0 and
                            self.call_stack.items.len == 0;
                        if (bare) {
                            const line = if (quotation.instructions.len > 0) quotation.instructions[0].line else 0;
                            const source = self.quotationBodySource(quotation.instructions) orelse self.current_source;
                            self.appendPendingSyntheticErrorFrame("quotation", source, line, null);
                        }
                        return err;
                    },
                    .bail => {
                        if (bail_stats_mod.enabled) {
                            bail_stats_mod.global.recordQuotationBail();
                        }
                        self.stack.items.items.len = saved_sp;
                        // The re-run below repeats the attempt from where it began, so a transient
                        // frame the bailed body opened is discarded here. Leaving it to the
                        // deferred truncation would keep it live for the whole re-run.
                        self.truncateLocalFrames(frame_mark);
                    },
                }
            }
        }

        try self.executeQuotationWithOwner(quotation, owner);
    }

    /// Execute a quotation with a local frame but WITHOUT the TCO loop.
    ///
    /// Tail call "flag" propagates upward to the caller's executeQuotation loop.
    /// Used only by `if` so that tail calls in conditional branches propagate
    /// through to the enclosing word's TCO loop (e.g., times -> if -> times).
    ///
    /// `owner` is the closure `quotation` came out of, when the body may be one that closure
    /// owns. See `executeQuotationWithOwner`.
    pub fn executeQuotationInline(self: *Context, quotation: Quotation, owner: ?*const value_mod.Closure) anyerror!void {
        try self.pushLocalFrame();
        defer self.popLocalFrame();

        // Restoring before a pending tail call is replayed is correct: the enclosing
        // `executeQuotationWithPic` loop reinstalls the callee's file from `tail_call_source`.
        const saved_source = self.current_source;
        defer self.current_source = saved_source;
        self.enterBodySource(quotation.instructions);

        const depth_before = self.stack.depth();
        try self.executeInstructions(quotation.instructions, null, null, owner);

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

    /// End profiling, convert the frame this caller pushed into a pending unwind frame,
    /// pop it, and propagate the error.
    ///
    /// Nothing captures here. Every unwinding frame pends, so the compiled ancestors and
    /// interpreted callers appended later during the unwind still land in the chain, and the
    /// fold runs once at the consumption point that owns the error.
    pub fn wordErrorCleanup(self: *Context, name: []const u8, err: anyerror) anyerror {
        if (self.benchmark) |b| b.endWordProfile(self.allocator, name);
        if (self.profile) |p| p.recordWordEnd(self.allocator, name);
        if (self.call_stack.items.len > 0) {
            const frame = self.call_stack.items[self.call_stack.items.len - 1];
            self.appendPendingErrorFrame(frame);
            self.popCallFrame();
        }
        return err;
    }

    /// Validate the stack effect (if declared), end benchmark profiling with
    /// peak-depth update, and pop the call frame.
    pub fn wordSuccessCleanup(self: *Context, name: []const u8, stack_effect: ?*const StackEffect) !void {
        if (stack_effect) |effect| {
            const depth_after = self.stack.depth();
            if (depth_after < effect.concreteOutputCount()) {
                self.captureStackEffectMismatch(name, effect.*, depth_after);
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

        const tci_owner = self.tail_call_body_owner;
        self.tail_call_body_owner = null;

        if (tci_module) |mod| {
            self.pushModuleDepsFrame(mod) catch |e| return self.wordErrorCleanup(name, e);
        }

        self.executeQuotationWithOwner(.{ .instructions = tci }, tci_owner) catch |err| {
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
    ///
    /// `caller_body` is the body the call at `idx` sits in, and `caller_owner` its carrier. Together
    /// with `idx` they name the call site for the parameter-effect memo.
    fn executeResolvedWord(
        self: *Context,
        name: []const u8,
        word: WordDefinition,
        instr: Instruction,
        idx: usize,
        pic_table: ?*PicTable,
        is_last: bool,
        caller_body: []const Instruction,
        caller_owner: ?*const value_mod.Closure,
    ) anyerror!ResolvedWordResult {
        if (self.active_sandbox) |sandbox| {
            if (!sandbox.allows(word.capability)) {
                self.pushCallFrame(name, self.current_source, instr.line, instr.column, word.stack_effect);
                self.pending_error_message = std.fmt.allocPrint(
                    self.arena.allocator(),
                    "'{s}' requires capability '{s}' which is not granted by the active sandbox",
                    .{ name, word.capability.displayName() },
                ) catch "word denied by sandbox";
                return self.wordErrorCleanup(name, error.PermissionDenied);
            }
        }

        if (word.parse_time_only and self.parse_tokenizer == null) {
            self.pushCallFrame(name, self.current_source, instr.line, instr.column, word.stack_effect);
            self.pending_error_message = "parse-time-only word cannot be called at runtime";
            return self.wordErrorCleanup(name, error.ParseError);
        }

        // Try JIT-compiled dispatch before interpreter path. A word that compiled
        // to native and had its interpretable body dropped (an empty compound body)
        // must dispatch compiled: interpreting the empty body is a silent no-op that
        // leaks the caller's inputs. When its dictionary word_id is null but a
        // compiled function exists in jit_dispatch, backfill the id so the compiled
        // function runs. Restricted to empty bodies so real-bodied words -- including
        // quotation-calling combinators -- stay on the interpreter path unchanged.
        // Restricted to module-less words too; `backfillCompiledWordId` documents why.
        // On freestanding targets word.word_id is never assigned and runtime_image_loaded is
        // never set, so effective_word_id would always resolve to null anyway.
        if (comptime !is_freestanding) {
            const effective_word_id: ?u32 = word.word_id orelse blk: {
                if (word.source_module == null and word.exec_flags.empty_compound_body and self.runtime_image_loaded) {
                    break :blk backfillCompiledWordId(self, name);
                }
                break :blk null;
            };
            if (effective_word_id) |wid| {
                if (word.stack_effect) |effect| {
                    if (word.exec_flags.has_param_effects) {
                        self.validateParameterEffects(effect, .{ .instructions = caller_body, .index = idx, .owner = caller_owner }) catch |err| {
                            self.pushCallFrame(name, self.current_source, instr.line, instr.column, word.stack_effect);
                            return self.wordErrorCleanup(name, err);
                        };
                    }
                    if (word.exec_flags.has_type_annotations and !word.exec_flags.skip_type_validation) {
                        self.validateTypeAnnotations(effect) catch |err| {
                            self.pushCallFrame(name, self.current_source, instr.line, instr.column, word.stack_effect);
                            return self.wordErrorCleanup(name, err);
                        };
                    }
                }
                const saved_source = self.current_source;
                if (word.source_file) |sf| self.current_source = sf;
                const jit_result = if (word.source_module) |mod| blk: {
                    self.pushModuleDepsFrame(mod) catch |err| {
                        self.current_source = saved_source;
                        self.pushCallFrame(name, self.current_source, instr.line, instr.column, word.stack_effect);
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

                        if (self.benchmark) |b| b.endWordProfile(self.allocator, name);
                        if (self.profile) |p| p.recordWordEnd(self.allocator, name);

                        // A non-tail call always pends this word's frame: the interpreted run
                        // of the same call shows the row whether or not interpreted callers
                        // sit above.
                        //
                        // The interpreter elides tail-call frames, so a tail call pends only
                        // when nothing else carries the pending message.
                        const pend = !is_last or
                            (self.jit_pending_trace_frames.items.len == 0 and self.call_stack.items.len == 0);
                        if (pend) {
                            self.appendPendingErrorFrame(.{
                                .word_name = name,
                                .source = self.current_source,
                                .line = instr.line,
                                .column = instr.column,
                                .stack_effect = word.stack_effect,
                            });
                        }
                        return err;
                    },
                    .bail => {
                        if (self.compile_mode == .hybrid) {
                            self.tryHybridCompile(wid, name, word);
                        }
                    },
                }
            }
        }

        self.pushCallFrame(name, self.current_source, instr.line, instr.column, word.stack_effect);
        self.traceWordExecution(name, instr);

        if (word.stack_effect) |effect| {
            if (word.exec_flags.has_param_effects) {
                self.validateParameterEffects(effect, .{ .instructions = caller_body, .index = idx, .owner = caller_owner }) catch |err|
                    return self.wordErrorCleanup(name, err);
            }
            if (word.exec_flags.has_type_annotations and !word.exec_flags.skip_type_validation) {
                self.validateTypeAnnotations(effect) catch |err|
                    return self.wordErrorCleanup(name, err);
            }
        }

        if (word.action == .compound) {
            if (word.exec_flags.is_generic) {
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
                if (word.exec_flags.recursive_non_tco) {
                    if (!word.exec_flags.stack_recursive) {
                        self.pending_error_message = "word has recursive-non-tco marker but lacks stack-recursive marker";
                        return self.wordErrorCleanup(name, error.NonTailRecursion);
                    }
                }
            }
        }

        const saved_native = self.withCurrentNative(currentNativeFor(word.action, name, self.current_native));
        defer self.restoreCurrentNative(saved_native);

        if (is_last) {
            switch (word.action) {
                .compound => |instrs| {
                    if (self.benchmark) |b| b.endWordProfile(self.allocator, name);
                    if (self.profile) |p| p.recordWordEnd(self.allocator, name);
                    self.tail_call_instructions = instrs;
                    self.tail_call_module = word.source_module;
                    self.tail_call_source = word.source_file;
                    self.tail_call_body_owner = word.body_owner;
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
                .literal => |v| {
                    // No tail-call setup: a literal push has nothing further
                    // to call into, so it finishes like a native word does.
                    self.tail_call_instructions = null;
                    self.current_pic_entry = if (pic_table) |pt| pt.get(idx) else null;
                    defer self.current_pic_entry = null;
                    if (self.stack.push(v)) |_| {
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
                            break :blk self.executeQuotationWithPic(.{ .instructions = instrs }, callee_pic, mod, word.body_owner);
                        },
                        .native => |func| break :blk func(self),
                        .host_callback => |host| break :blk host_result: {
                            const rc = host.callback(host.handle, host.user_data);
                            if (rc != 0) break :host_result error.HostCallbackFailed;
                            break :host_result;
                        },
                        // A literal has no body that could reference
                        // module-private bare words, so there is nothing
                        // to push a module-deps frame for.
                        .literal => |v| break :blk self.stack.push(v),
                    }
                } else {
                    break :blk switch (word.action) {
                        .native => |func| func(self),
                        .host_callback => |host| host_result: {
                            const rc = host.callback(host.handle, host.user_data);
                            if (rc != 0) break :host_result error.HostCallbackFailed;
                            break :host_result;
                        },
                        .compound => |instrs| self.executeQuotationWithPic(.{ .instructions = instrs }, callee_pic, null, word.body_owner),
                        .literal => |v| self.stack.push(v),
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
    ///
    /// `owner` is a closure that may own `instructions`; see `executeQuotationWithOwner`. It is a
    /// hint, validated where it is admitted below.
    fn executeInstructions(self: *Context, instructions: []const Instruction, pic_table: ?*PicTable, body_module: ?*const value_mod.Module, owner: ?*const value_mod.Closure) anyerror!void {
        // Holds this body's creation-site module deps frames after a lazy re-resolution of a
        // `use`-imported word: its captured ambient-deps modules plus its defining-module stamp.
        // These are the frames the body could reach at creation but that may not be live where it
        // runs, so a word available only through one of them still resolves. Pushed at most once and
        // held for the rest of the body; popped in reverse on every exit.
        var lazy_pushed: std.ArrayListUnmanaged(*const value_mod.Module) = .{};
        var lazy_tried = false;
        defer {
            var li = lazy_pushed.items.len;
            while (li > 0) {
                li -= 1;
                self.popModuleDepsFrameTraced(lazy_pushed.items[li]);
            }
            lazy_pushed.deinit(self.allocator);
        }

        // Everything resolution knows about this body, fetched with one map probe: the scope
        // captured where the body was created, and the read-through cache of the defining-module
        // stamp. The probe runs for module-less bodies too -- the accepted hot-path cost --
        // because a wrong binding used to win exactly when no deps frame was live and the
        // miss-only lazy re-resolve never ran.
        //
        // A complete miss for a value-invoked body probes the shared stamp store once and caches
        // the result into the map, a null included. The negative cache is sound because a body is
        // stamped before any other executor can reach it, so a body probed with no stamp never
        // gains one. Every entry-creating writer fills the module half the same way, so a map hit
        // is authoritative and the steady state is one lock-free probe. The fill is skipped when
        // `body_module` is threaded -- the stamp would go unread, and word bodies are the common
        // case -- and for the shared empty-body sentinel, which is never stamped.
        //
        // The same miss also walks the ancestor chain for the scope half, through
        // `findCapturedScopeForBody`, so a stored quotation whose lexical captures were recorded
        // in a parent context resolves them here. The walk's result is cached alongside the stamp,
        // hit or null, which keeps a map hit final. That makes the cached scope a deliberate
        // snapshot at first execution in this context: a later supersede in the ancestor is not
        // observed through the walk. What bounds the staleness is that local writers still
        // supersede this entry -- a literal pushed here recaptures, and a closure popped here
        // restamps its carried scope. The walk covers the parent chain only; captures recorded in
        // a sibling task stay unreachable.
        //
        // The walk runs only for a body the carryable-scope gate has marked. Every other body
        // takes a second lock-free probe in place of an ancestor chain of mutex acquisitions,
        // which is what keeps a task-heavy first-visit shape off the root context's map mutex.
        //
        // The scope is retained for the full duration of this call and released via `defer`, so a
        // nested or recursive `executeInstructions` call made from within this one (e.g. through
        // `if`/`when`) is free to supersede the map's entry for this same body without freeing the
        // scope this outer frame still holds. `own_ambient_deps` below rides the retained scope,
        // which is what keeps it alive for the whole body.
        //
        // A body its closure owns takes none of that. Its address is freed when the closure is
        // released, so it never enters the map, and both halves ride the value instead.
        //
        // `ownsBody` is what makes `owner` a hint rather than an assertion. It admits the closure
        // only for the body the closure names, so a splice, a tail call into an unrelated word, and
        // a caller threading a stale value all fall through to the map instead of borrowing a scope
        // that belongs to different code.
        const from_closure = if (owner) |c| c.ownsBody(instructions) else false;

        const scope_info: QuotationScopeInfo = if (from_closure) .{
            // The store still has the last word where the value has none: `;` turns a closure into
            // a compound word over its own body, and module finalization stamps that slice.
            .defining_module = owner.?.defining_module orelse
                self.quotation_stamp_store.lookup(@intFromPtr(instructions.ptr)),
            .scope = @constCast(owner.?.captured_scope),
        } else blk: {
            const key = @intFromPtr(instructions.ptr);
            if (self.quotation_scope_info.count() != 0) {
                if (self.quotation_scope_info.get(key)) |info| break :blk info;
            }
            if (body_module != null or instructions.len == 0) break :blk .{};

            // The ancestor walk runs before the publish takes this context's map mutex: it takes
            // one ancestor mutex at a time and never this context's own, and self is the map's
            // only writer, so the miss above cannot be raced.
            //
            // Skipping the walk on an unmarked body is exactly equivalent to running it. The walk
            // returns non-null only when a context on the chain holds a carryable entry for this
            // body, and every writer that installs one marks the key before publishing the entry.
            // A probe that lands before a concurrent writer's mark caches a null, which is what
            // the walk itself would have found at that instant.
            const inherited = if (self.carryable_scope_gate.isMarked(key))
                try self.findCapturedScopeForBody(self.allocator, key)
            else
                null;
            errdefer if (inherited) |s| s.release();

            break :blk try self.publishQuotationScopeEntry(instructions, inherited, owner, .fill_if_absent);
        };
        // A map entry is supersedable, so the map path holds its own reference for the call. A
        // closure-carried scope needs none: the caller holds the closure across the execution,
        // which is what keeps the body memory alive in the first place.
        const captured_scope: ?*CapturedScope = scope_info.scope;
        if (!from_closure) if (captured_scope) |cs| cs.retain();
        defer if (!from_closure) if (captured_scope) |cs| cs.release();

        // The body's own module scope, consulted by resolution ahead of the transient frame walk:
        // its defining module plus the ambient-deps modules captured at its creation. The defining
        // module comes from `body_module` for a module-word body (threaded from
        // `executeResolvedWord`), then the map's cached stamp -- which is what lets a stored
        // quotation resolve its module in a spawned child whose own map starts empty. A quotation
        // spawned onto a child, where neither is present, rides its captured `deps_modules`, which
        // `curry`/`compose` propagate and `spawn` copies into the child.
        //
        // A synthetic scope body (`<local-scope>`, `<scope>`) is exempt from the probe and the
        // visibility filter alike; see `isSyntheticScopeModule`.
        const defining_raw: ?*const value_mod.Module = body_module orelse scope_info.defining_module;
        const stamp_synthetic = isSyntheticScopeModule(defining_raw);
        const own_module: ?*const value_mod.Module = if (stamp_synthetic) null else defining_raw;
        const own_ambient_deps: []const *const value_mod.Module = if (stamp_synthetic)
            &.{}
        else if (captured_scope) |cs|
            cs.deps_modules
        else
            &.{};

        // When a `.module_deps` frame is live, the frame walk admits only the frames this body may
        // legitimately see: its defining module's and its captured ambient-deps modules'. Both sets
        // are fixed for the body's lifetime; the filter is applied to whatever frames are live at
        // each call site. Null when no deps frame is live, keeping the common path free of the
        // filter.
        const deps_vis: ?ModuleDepsVisibility =
            if (self.live_module_deps_frames > 0 and !stamp_synthetic)
                .{ .deps_modules = own_ambient_deps, .defining_module = defining_raw }
            else
                null;

        // Published for `defineWordLocked`, which targets the topmost frame this body can see. The
        // slices inside ride `captured_scope`, retained above for at least as long as this call.
        const saved_deps_vis = self.active_deps_vis;
        self.active_deps_vis = deps_vis;
        defer self.active_deps_vis = saved_deps_vis;

        for (instructions, 0..) |instr, idx| {
            // The stepwise debugger is wired up only from capi.zig (C debugger API) and main.zig
            // (--debug), neither built for freestanding targets, so ctx.debugger is always null
            // there. Comptime-excluded so debugger.zig's interactive-prompt machinery (which
            // assumes a real stdin/stdout terminal, same as the line editor) never needs to
            // compile for that target.
            if (comptime !is_freestanding) {
                if (self.debugger) |dbg| {
                    if (try dbg.shouldPause(instr, self)) {
                        if (dbg.hasCCallback()) {
                            dbg.handleCPause(self);
                        } else {
                            try dbg.enterPrompt(instr, self);
                        }
                    }
                }
            }

            const is_last = (idx == instructions.len - 1);

            switch (instr.op) {
                .push_literal => |val| {
                    // Capture the lexical scope at the moment a quotation literal is created. A
                    // non-null scope promotes the pushed value to a `.closure` carrying it
                    // directly; a non-capturing push (the common case) is pushed unchanged.
                    if (val == .quotation) {
                        if (try self.captureQuotationScope(val.quotation.instructions)) |scope| {
                            // The promotion's creation reference transfers into the slot.
                            const promoted = try self.promoteToClosure(val.quotation, scope);
                            self.stack.pushMoved(.{ .closure = promoted }) catch |err| {
                                container_backing.releaseValue(.{ .closure = promoted });
                                return err;
                            };
                        } else {
                            try self.stack.push(val);
                        }
                    } else {
                        try self.stack.push(val);
                    }
                    if (self.benchmark) |b| {
                        b.recordPushLiteral();
                        b.updatePeakStackDepth(self.stack.depth());
                    }
                },
                .call_word => |name| {
                    signal.checkPendingSignals(self) catch |err| {
                        self.pushCallFrame(name, self.current_source, instr.line, instr.column, null);
                        return self.wordErrorCleanup(name, err);
                    };

                    if (self.benchmark) |b| {
                        b.recordCallWord();
                        b.beginWordProfile();
                    }
                    if (self.profile) |p| p.recordWordStart(self.allocator);

                    if (captured_scope) |scope| {
                        if (lookupInCapturedScope(scope, name)) |word| {
                            switch (try self.executeResolvedWord(name, word, instr, idx, pic_table, is_last, instructions, owner)) {
                                .proceed => {},
                                .tail_call_set => return,
                            }
                            continue;
                        }
                    }

                    if (self.lookupWordForExecutionOwnScope(name, deps_vis, own_module, own_ambient_deps)) |word| {
                        switch (try self.executeResolvedWord(name, word, instr, idx, pic_table, is_last, instructions, owner)) {
                            .proceed => {},
                            .tail_call_set => return,
                        }
                    } else if (splitQualifiedName(name) != null) {
                        // The call site pends its own row only when the callee pended nothing,
                        // which is resolution failing before any frame was armed: the module
                        // binding missing, the binding not yielding a module, or the name not
                        // in the module. A raise past resolution pends the qualified row itself.
                        const pend_mark = self.jit_pending_trace_frames.items.len;
                        self.executeQualifiedName(name, instr.line, instr.column) catch |err| {
                            if (self.jit_pending_trace_frames.items.len == pend_mark) {
                                self.appendPendingErrorFrame(.{
                                    .word_name = name,
                                    .source = self.current_source,
                                    .line = instr.line,
                                    .column = instr.column,
                                    .stack_effect = null,
                                });
                            }
                            return err;
                        };
                        if (self.benchmark) |b| {
                            b.updatePeakStackDepth(self.stack.depth());
                        }
                    } else lazy_resolve: {
                        // The executing body may reference a word available only through one of its
                        // creation-site module frames, none of which are live here (e.g. a body
                        // called after a cross-module tail call popped its frame). Push those frames
                        // once -- the captured ambient-deps modules and the defining-module stamp --
                        // and re-resolve under a visibility that admits exactly them; hold them for
                        // the rest of the body. One-shot per body.
                        if (!lazy_tried) {
                            lazy_tried = true;

                            // The body's scope info, fetched fresh here so this rare path sees an
                            // entry superseded since body entry, and works even when no deps frame
                            // was live then (`deps_vis` null). The store fallback covers the shape
                            // the body-entry fill skips: a word body (`body_module` threaded) may
                            // have no map entry, and its stamp is still needed for the deps-frame
                            // push below. A value-invoked body always hits the filled entry.
                            //
                            // A closure-owned body has no entry to fetch, so it reuses what body
                            // entry already read off the value. Without that it would push no
                            // creation-site frame at all and fail the re-resolve this block exists
                            // for.
                            const lazy_info: QuotationScopeInfo = if (from_closure)
                                scope_info
                            else
                                self.quotation_scope_info.get(@intFromPtr(instructions.ptr)) orelse .{};
                            const lazy_deps: []const *const value_mod.Module = if (deps_vis) |v|
                                v.deps_modules
                            else if (lazy_info.scope) |cs|
                                cs.deps_modules
                            else
                                &.{};
                            const stamp_module = lazy_info.defining_module orelse
                                self.quotation_stamp_store.lookup(@intFromPtr(instructions.ptr));

                            // Reserve up front so a `pushModuleDepsFrame` success is always paired
                            // with a tracking append that cannot then OOM, leaving no untracked live
                            // frame with a skewed counter.
                            try lazy_pushed.ensureTotalCapacity(self.allocator, lazy_deps.len + 1);
                            for (lazy_deps) |mod| {
                                try self.pushModuleDepsFrame(mod);
                                lazy_pushed.appendAssumeCapacity(mod);
                            }
                            if (stamp_module) |mod| {
                                try self.pushModuleDepsFrame(mod);
                                lazy_pushed.appendAssumeCapacity(mod);
                            }

                            if (lazy_pushed.items.len > 0) {
                                const lazy_module = body_module orelse stamp_module;
                                // `lazy_pushed`, not `lazy_deps`: the stamp frame is pushed here too,
                                // and a synthetic-scope `body_module` would otherwise make
                                // `defining_module` name the scope rather than the stamp, so the
                                // filter rejected the stamp frame this block had just pushed.
                                const lazy_vis: ModuleDepsVisibility = .{
                                    .deps_modules = lazy_pushed.items,
                                    .defining_module = lazy_module,
                                };
                                // A synthetic-scope stamp counts as module-less for the scan gate,
                                // mirroring the body-entry probe's exemption.
                                const gate_module = if (isSyntheticScopeModule(lazy_module)) null else lazy_module;
                                if (self.lookupWordForExecutionFiltered(name, lazy_vis, gate_module)) |word| {
                                    switch (try self.executeResolvedWord(name, word, instr, idx, pic_table, is_last, instructions, owner)) {
                                        .proceed => {},
                                        .tail_call_set => return,
                                    }
                                    break :lazy_resolve;
                                }
                            }
                        }
                        if (self.trace.trace_resolve and trace_mod.matchesPattern(name, self.trace.trace_resolve_pattern)) {
                            var tw = trace_mod.TraceWriter.init();
                            trace_mod.traceResolve(&tw, name, .not_found);
                        }
                        self.appendPendingErrorFrame(.{
                            .word_name = name,
                            .source = self.current_source,
                            .line = instr.line,
                            .column = instr.column,
                            .stack_effect = null,
                        });
                        return ExecutionError.UnknownWord;
                    }
                },
                .call_word_direct => |slot| {
                    const name = slot.name;
                    signal.checkPendingSignals(self) catch |err| {
                        self.pushCallFrame(name, self.current_source, instr.line, instr.column, dict_mod.loadSlot(slot).stack_effect);
                        return self.wordErrorCleanup(name, err);
                    };

                    if (self.benchmark) |b| {
                        b.recordCallWord();
                        b.beginWordProfile();
                    }
                    if (self.profile) |p| p.recordWordStart(self.allocator);

                    const word = dict_mod.loadSlot(slot).*;
                    switch (try self.executeResolvedWord(name, word, instr, idx, pic_table, is_last, instructions, owner)) {
                        .proceed => {},
                        .tail_call_set => return,
                    }
                },
                .call_word_module => |slot| {
                    const name = slot.name;
                    signal.checkPendingSignals(self) catch |err| {
                        self.pushCallFrame(name, self.current_source, instr.line, instr.column, dict_mod.loadSlot(slot).stack_effect);
                        return self.wordErrorCleanup(name, err);
                    };

                    if (self.benchmark) |b| {
                        b.recordCallWord();
                        b.beginWordProfile();
                    }
                    if (self.profile) |p| p.recordWordStart(self.allocator);

                    // The build-time resolution stands in for rung 2 of the ladder and everything
                    // below it, but rung 1 is still live: a lexical binding closed over at this
                    // quotation's creation site outranks the body's own module scope.
                    if (captured_scope) |scope| {
                        if (lookupInCapturedScope(scope, name)) |word| {
                            switch (try self.executeResolvedWord(name, word, instr, idx, pic_table, is_last, instructions, owner)) {
                                .proceed => {},
                                .tail_call_set => return,
                            }
                            continue;
                        }
                    }

                    const word = dict_mod.loadSlot(slot).*;
                    switch (try self.executeResolvedWord(name, word, instr, idx, pic_table, is_last, instructions, owner)) {
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

const ThreadStackBounds = struct {
    low: usize,
    high: usize,
};

extern "c" fn pthread_get_stackaddr_np(thread: std.c.pthread_t) *anyopaque;
extern "c" fn pthread_get_stacksize_np(thread: std.c.pthread_t) usize;
extern "c" fn pthread_getattr_np(thread: std.c.pthread_t, attr: *std.c.pthread_attr_t) c_int;
extern "c" fn pthread_attr_getstack(
    attr: *const std.c.pthread_attr_t,
    stackaddr: *?*anyopaque,
    stacksize: *usize,
) c_int;

/// The stack region of the calling OS thread, or null where the platform offers no query.
fn currentThreadStackBounds() ?ThreadStackBounds {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => {
            // Darwin reports the high end of the stack; the region grows down from it.
            const self_thread = std.c.pthread_self();
            const high = @intFromPtr(pthread_get_stackaddr_np(self_thread));
            const size = pthread_get_stacksize_np(self_thread);
            return .{ .low = high - size, .high = high };
        },
        .linux => {
            var attr: std.c.pthread_attr_t = undefined;
            if (pthread_getattr_np(std.c.pthread_self(), &attr) != 0) return null;
            defer _ = std.c.pthread_attr_destroy(&attr);
            var addr: ?*anyopaque = null;
            var size: usize = 0;
            if (pthread_attr_getstack(&attr, &addr, &size) != 0) return null;
            const low = @intFromPtr(addr orelse return null);
            return .{ .low = low, .high = low + size };
        },
        else => return null,
    }
}

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

    // The param slices outlive this resolution inside the returned `ResolvedWord`. They are safe
    // to borrow because a definition owns its effect outright, parameters included.
    const output_params: ?[]const stack_effect_mod.StackEffectParam =
        if (callee.stack_effect) |eff| eff.outputs else null;
    const input_params: ?[]const stack_effect_mod.StackEffectParam =
        if (callee.stack_effect) |eff| eff.inputs else null;

    switch (callee.action) {
        // A literal has no instruction body (`ResolvedWord.body` stays null),
        // so it resolves exactly like a bodiless compound word from this
        // point on.
        .compound, .literal => {},
        .native => |func| {
            const effect = callee.stack_effect orelse return null;
            var result = ir_codegen.ResolvedWord{
                .word_id = 0,
                .input_count = @intCast(effect.inputs.len),
                .output_count = @intCast(effect.outputs.len),
                .is_native = true,
                .native_fn_ptr = @intFromPtr(func),
                .defines_word = primitives.nativeDefinesWord(func),
                .never_returns = hasNeverReturnsMarker(callee.markers),
                .dispatch_id = callee.dispatch_id,
                .output_params = output_params,
                .input_params = input_params,
            };
            if (stack_effect_mod.hasAnyRowVariable(effect.*)) {
                result.callee_effect = effect;
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
    if (ctx.jit_dispatch.getMut(word_id)) |em| {
        if (em.stack_effect == null) em.stack_effect = callee.stack_effect;
    }

    const bounded = dispatch_helpers.boundedDispatchFor(effect, callee.markers, name);

    var result = ir_codegen.ResolvedWord{
        .word_id = word_id,
        .input_count = @intCast(effect.inputs.len),
        .output_count = @intCast(effect.outputs.len),
        .never_returns = hasNeverReturnsMarker(callee.markers),
        .dispatch_id = callee.dispatch_id,
        .bounded_constraint = if (bounded) |b| b.constraint else null,
        .bounded_arity = if (bounded) |b| b.arity else .unary,
        .bounded_trace_name = if (bounded) |b| ctx.boundedConstraintTraceName(b.constraint) else null,
        .output_params = output_params,
        .input_params = input_params,
        .body = if (callee.action == .compound) callee.action.compound else null,
        .source_file = if (callee.action == .compound) callee.source_file else null,
    };
    if (stack_effect_mod.hasAnyRowVariable(effect.*)) {
        result.callee_effect = effect;
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
        // Match `lookupWordLocked`'s bounded ancestor walk: a descendant only
        // resolves an ancestor's stable scope (the durable floor and below),
        // so back-writing a word_id into an ancestor's transient frame would
        // land where resolution never looks, and would race the ancestor's
        // lockless combinator push/pop.
        const anc_cap = if (anc.durable_frame_floor) |idx| idx + 1 else 0;
        var j = anc_cap;
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

/// A word that compiled to native in an AOT runtime image has its interpretable
/// body dropped -- the runtime image serializes an empty body because the
/// `code_ptr` is the intended execution path. If such a word is then reached
/// through the interpreter (its startup-parsed dictionary entry carries
/// `word_id = null` while the compiled function lives only in `jit_dispatch`),
/// interpreting its empty body silently does nothing, corrupting the caller's
/// stack. This resolves the word's real `word_id` from `jit_dispatch` (self +
/// parent chain, the same scan `lookupAotCompiledWordLocked` and `executeCompiled`
/// use) so it dispatches compiled, and writes the id back onto the live
/// dictionary/frame slot via `propagateWordId` so the scan runs at most once per
/// word.
///
/// The caller restricts this to empty-bodied, module-less words.
///
/// A word with a real body is interpretable and must stay on the interpreter
/// path. A module word carries its own per-(module, word) id from its image
/// row, so it never needs the sweep, and a bare-name match could name another
/// module's body.
///
/// Gated on `runtime_image_loaded`, matching `lookupAotCompiledWordLocked`, so
/// interpreter sessions never name-sweep `jit_dispatch`.
fn backfillCompiledWordId(self: *Context, name: []const u8) ?u32 {
    var ctx_opt: ?*const Context = self;
    while (ctx_opt) |ctx| : (ctx_opt = ctx.parent_context) {
        for (ctx.jit_dispatch.entries.items, 0..) |entry, idx| {
            if (entry.code_ptr == null) continue;
            if (!std.mem.eql(u8, entry.word_name, name)) continue;
            const wid: u32 = @intCast(idx);
            propagateWordId(self, name, wid);
            return wid;
        }
    }
    return null;
}

// =============================================================================
// Tests
// =============================================================================

test "init and deinit" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
}

test "pragmaEnvironmentSetSite accepts a prompt and the startup file, and refuses a source file" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try std.testing.expect(ctx.pragmaEnvironmentSetSite());

    ctx.current_source = "app.1z";
    try std.testing.expect(!ctx.pragmaEnvironmentSetSite());

    ctx.startup_source = "/home/u/.config/1z/startup.1z";
    try std.testing.expect(!ctx.pragmaEnvironmentSetSite());

    ctx.current_source = "/home/u/.config/1z/startup.1z";
    try std.testing.expect(ctx.pragmaEnvironmentSetSite());

    // A module the startup file loads points current_source at the module, which is a source file
    // whoever loads it.
    ctx.current_source = "lib/math.1z";
    try std.testing.expect(!ctx.pragmaEnvironmentSetSite());
}

test "collisionGuardMode maps each accepted value, and defaults to error" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.pushPragmaFrame();

    try std.testing.expectEqual(Context.CollisionGuardMode.err, ctx.collisionGuardMode("dictionary-shadow", "dup"));

    try ctx.setPragma("dictionary-shadow", value_mod.stringValue("error"));
    try std.testing.expectEqual(Context.CollisionGuardMode.err, ctx.collisionGuardMode("dictionary-shadow", "dup"));

    try ctx.setPragma("dictionary-shadow", value_mod.stringValue("warning"));
    try std.testing.expectEqual(Context.CollisionGuardMode.warning, ctx.collisionGuardMode("dictionary-shadow", "dup"));

    try ctx.setPragma("dictionary-shadow", value_mod.stringValue("off"));
    try std.testing.expectEqual(Context.CollisionGuardMode.off, ctx.collisionGuardMode("dictionary-shadow", "dup"));

    // The validator refuses this, so reaching it means the value came from somewhere else.
    try ctx.setPragma("dictionary-shadow", value_mod.stringValue("quiet"));
    try std.testing.expectEqual(Context.CollisionGuardMode.err, ctx.collisionGuardMode("dictionary-shadow", "dup"));

    const names = try std.testing.allocator.alloc(Value, 1);
    names[0] = value_mod.symbolValue("dup");
    const allowlist = try value_mod.Array.fromOwnedSlice(std.testing.allocator, names);
    try ctx.setPragma("dictionary-shadow", .{ .array = allowlist });
    try std.testing.expectEqual(Context.CollisionGuardMode.off, ctx.collisionGuardMode("dictionary-shadow", "dup"));
    try std.testing.expectEqual(Context.CollisionGuardMode.err, ctx.collisionGuardMode("dictionary-shadow", "nip"));

    // Each key is read on its own, so relaxing one guard leaves the other at its default.
    try std.testing.expectEqual(Context.CollisionGuardMode.err, ctx.collisionGuardMode("import-collision", "dup"));
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

test "unwind pends the chain for an unknown word and the fold orders it innermost first" {
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

    // Nothing folds at the raise; the consumer folds the pended chain.
    try std.testing.expectEqual(@as(usize, 0), ctx.error_details.items.len);
    ctx.finalizeErrorDetails(ExecutionError.UnknownWord);
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

test "wordErrorCleanup pends the pushed frame and the consumer's fold renders it" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    ctx.pushCallFrame("boom", "<test>", 7, 0, null);
    ctx.pending_error_message = "boom went wrong";

    const err = ctx.wordErrorCleanup("boom", error.TypeMismatch);
    try std.testing.expectEqual(error.TypeMismatch, err);

    try std.testing.expectEqual(@as(usize, 0), ctx.call_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.error_details.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.jit_pending_trace_frames.items.len);
    try std.testing.expectEqualStrings("boom", ctx.jit_pending_trace_frames.items[0].word_name);
    try std.testing.expectEqual(@as(usize, 7), ctx.jit_pending_trace_frames.items[0].line);
    try std.testing.expectEqualStrings("boom went wrong", ctx.pending_error_message.?);

    ctx.finalizeErrorDetails(err);

    try std.testing.expectEqual(@as(usize, 1), ctx.error_details.items.len);
    try std.testing.expectEqualStrings("boom", ctx.error_details.items[0].word_name.?);
    try std.testing.expectEqualStrings("boom went wrong", ctx.error_details.items[0].message);
    try std.testing.expectEqual(@as(usize, 0), ctx.jit_pending_trace_frames.items.len);
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.pending_error_message);
}

test "finalizeErrorDetails is idempotent: a second fold keeps the chain and clears late frames" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    ctx.pushCallFrame("inner", "<test>", 3, 0, null);
    ctx.finalizeErrorDetails(error.TypeMismatch);

    try std.testing.expectEqual(@as(usize, 1), ctx.error_details.items.len);

    ctx.appendPendingSyntheticErrorFrame("late", "<test>", 9, null);
    ctx.finalizeErrorDetails(error.TypeMismatch);

    try std.testing.expectEqual(@as(usize, 1), ctx.error_details.items.len);
    try std.testing.expectEqualStrings("inner", ctx.error_details.items[0].word_name.?);
    try std.testing.expectEqual(@as(usize, 0), ctx.jit_pending_trace_frames.items.len);
}

test "finalizeErrorDetailsAbove folds only the frames above the mark" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    ctx.appendPendingSyntheticErrorFrame("enclosing", "<test>", 2, null);
    const mark = ctx.jit_pending_trace_frames.items.len;
    ctx.appendPendingSyntheticErrorFrame("mine", "<test>", 5, null);
    ctx.pending_error_message = "mine went wrong";

    ctx.finalizeErrorDetailsAbove(error.TypeMismatch, 0, mark);

    try std.testing.expectEqual(@as(usize, 1), ctx.error_details.items.len);
    try std.testing.expectEqualStrings("mine", ctx.error_details.items[0].word_name.?);
    try std.testing.expectEqualStrings("mine went wrong", ctx.error_details.items[0].message);

    try std.testing.expectEqual(@as(usize, 1), ctx.jit_pending_trace_frames.items.len);
    try std.testing.expectEqualStrings("enclosing", ctx.jit_pending_trace_frames.items[0].word_name);
}

test "finalizeErrorDetailsAbove reads the first-error gate against its own mark" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.error_details.append(ctx.allocator, .{
        .error_type = "body-error",
        .message = "body failed",
        .source = "<test>",
        .line = 2,
        .word_name = "enclosing",
    });
    const mark = ctx.error_details.items.len;
    ctx.appendPendingSyntheticErrorFrame("mine", "<test>", 5, null);

    ctx.finalizeErrorDetailsAbove(error.TypeMismatch, mark, 0);

    try std.testing.expectEqual(@as(usize, 2), ctx.error_details.items.len);
    try std.testing.expectEqualStrings("enclosing", ctx.error_details.items[0].word_name.?);
    try std.testing.expectEqualStrings("mine", ctx.error_details.items[1].word_name.?);
}

test "finalizeErrorDetails with nothing to fold preserves the pending message" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    ctx.pending_error_message = "kept for the frameless fallback";
    ctx.pending_error_hint = "kept too";

    ctx.finalizeErrorDetails(error.TypeMismatch);

    try std.testing.expectEqual(@as(usize, 0), ctx.error_details.items.len);
    try std.testing.expectEqualStrings("kept for the frameless fallback", ctx.pending_error_message.?);
    try std.testing.expectEqualStrings("kept too", ctx.pending_error_hint.?);
}

test "capture drops a definition-located frame when the call site queued the same word" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    ctx.appendPendingErrorFrame(.{
        .word_name = "take",
        .source = "<test>",
        .line = 0,
        .definition_located = true,
    });
    ctx.appendPendingSyntheticErrorFrame("take", "<test>", 15, null);
    ctx.pending_error_message = "expected fixnum, got bignum";

    ctx.finalizeErrorDetails(error.TypeMismatch);

    try std.testing.expectEqual(@as(usize, 1), ctx.error_details.items.len);
    try std.testing.expectEqualStrings("take", ctx.error_details.items[0].word_name.?);
    try std.testing.expectEqual(@as(usize, 15), ctx.error_details.items[0].line);
    try std.testing.expectEqualStrings("expected fixnum, got bignum", ctx.error_details.items[0].message);
}

test "capture keeps a definition-located frame with no same-word call-site row" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    ctx.appendPendingErrorFrame(.{
        .word_name = "take",
        .source = "<test>",
        .line = 0,
        .definition_located = true,
    });
    ctx.appendPendingSyntheticErrorFrame("caller", "<test>", 9, null);
    ctx.pending_error_message = "expected fixnum, got bignum";

    ctx.finalizeErrorDetails(error.TypeMismatch);

    try std.testing.expectEqual(@as(usize, 2), ctx.error_details.items.len);
    try std.testing.expectEqualStrings("take", ctx.error_details.items[0].word_name.?);
    try std.testing.expectEqualStrings("expected fixnum, got bignum", ctx.error_details.items[0].message);
    try std.testing.expectEqualStrings("caller", ctx.error_details.items[1].word_name.?);
}

test "capture renders the frame's carried effect, not a visible binding's" {
    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;
    const native_effect = StackEffect{
        .inputs = &[_]StackEffectParam{ .{ .name = "a" }, .{ .name = "b" } },
        .outputs = &[_]StackEffectParam{.{ .name = "a-b" }},
    };
    const binding_effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "q" }},
        .outputs = &[_]StackEffectParam{.{ .name = "r" }},
    };

    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // A live binding of the same name, which the old by-name resolution would have reported.
    try ctx.pushLocalFrame();
    try ctx.local_frames.items[ctx.local_frames.items.len - 1].put(ctx.allocator, "shadowed-op", .{
        .name = "shadowed-op",
        .stack_effect = &binding_effect,
        .action = .{ .native = noop },
    });

    ctx.pushCallFrame("shadowed-op", "<test>", 3, 0, &native_effect);
    ctx.finalizeErrorDetails(error.TypeMismatch);
    ctx.popCallFrame();
    ctx.popLocalFrame();

    try std.testing.expectEqual(@as(usize, 1), ctx.error_details.items.len);
    try std.testing.expectEqualStrings("( a b -- a-b )", ctx.error_details.items[0].stack_effect_str.?);
}

test "capture renders no effect for a frame that carries none" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    ctx.pushCallFrame("dup", "<test>", 1, 0, null);
    ctx.finalizeErrorDetails(error.StackUnderflow);
    ctx.popCallFrame();

    try std.testing.expectEqual(@as(usize, 1), ctx.error_details.items.len);
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.error_details.items[0].stack_effect_str);
}

test "capture dedupe carries the dropped definition-located frame's effect" {
    const trap_effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "m" }},
    };

    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    ctx.appendPendingErrorFrame(.{
        .word_name = "take",
        .source = "<test>",
        .line = 0,
        .definition_located = true,
        .stack_effect = &trap_effect,
    });
    ctx.appendPendingSyntheticErrorFrame("take", "<test>", 15, null);
    ctx.pending_error_message = "expected fixnum, got bignum";

    ctx.finalizeErrorDetails(error.TypeMismatch);

    try std.testing.expectEqual(@as(usize, 1), ctx.error_details.items.len);
    try std.testing.expectEqual(@as(usize, 15), ctx.error_details.items[0].line);
    try std.testing.expectEqualStrings("( n -- m )", ctx.error_details.items[0].stack_effect_str.?);
}

test "restoreErrorState gives back every channel a swallowed error overwrote" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const outer_thrown = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = "body-error",
        .message = "body failed",
    });

    ctx.pending_error_message = "body failed";
    ctx.pending_error_hint = "try a fixnum";
    ctx.pending_dispatch_actual_types = "( string )";
    ctx.pending_dispatch_available_methods = "fixnum, float";
    ctx.thrown_error = outer_thrown;
    ctx.appendPendingSyntheticErrorFrame("boom", "<test>", 6, null);
    try ctx.error_details.append(ctx.allocator, .{
        .error_type = "body-error",
        .message = "body failed",
        .source = "<test>",
        .line = 6,
        .word_name = "boom",
    });

    const saved = ctx.saveErrorState();

    const inner_thrown = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = "cleanup-error",
        .message = "cleanup failed",
    });

    ctx.pending_error_message = "cleanup failed";
    ctx.pending_error_hint = null;
    ctx.pending_dispatch_actual_types = null;
    ctx.pending_dispatch_available_methods = "symbol";
    ctx.thrown_error = inner_thrown;
    ctx.appendPendingSyntheticErrorFrame("spoil", "<test>", 7, null);
    try ctx.error_details.append(ctx.allocator, .{
        .error_type = "cleanup-error",
        .message = "cleanup failed",
        .source = "<test>",
        .line = 7,
        .word_name = "spoil",
    });

    ctx.restoreErrorState(saved);

    try std.testing.expectEqualStrings("body failed", ctx.pending_error_message.?);
    try std.testing.expectEqualStrings("try a fixnum", ctx.pending_error_hint.?);
    try std.testing.expectEqualStrings("( string )", ctx.pending_dispatch_actual_types.?);
    try std.testing.expectEqualStrings("fixnum, float", ctx.pending_dispatch_available_methods.?);
    try std.testing.expectEqual(outer_thrown, ctx.thrown_error.?);

    try std.testing.expectEqual(@as(usize, 1), ctx.jit_pending_trace_frames.items.len);
    try std.testing.expectEqualStrings("boom", ctx.jit_pending_trace_frames.items[0].word_name);
    try std.testing.expectEqual(@as(usize, 1), ctx.error_details.items.len);
    try std.testing.expectEqualStrings("boom", ctx.error_details.items[0].word_name.?);
}

test "restoreErrorState releases a discarded thrown box's refcounted payload" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // One reference for the box's own claim, one to keep the count inspectable afterwards.
    const vec = try value_mod.Vector.create(std.testing.allocator);
    defer vec.header.release();
    vec.header.retain();

    const saved = ctx.saveErrorState();

    const data = try ctx.quotationAllocator().create(Value);
    data.* = .{ .vector = vec };
    ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = "cleanup-error",
        .message = "cleanup failed",
        .data = data,
    });

    ctx.restoreErrorState(saved);

    try std.testing.expectEqual(@as(?*value_mod.ErrorObject, null), ctx.thrown_error);
    try std.testing.expectEqual(@as(u32, 1), vec.header.refcountValue());
}

test "restoreErrorState keeps the payload of a stash the execution never replaced" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const vec = try value_mod.Vector.create(std.testing.allocator);
    defer vec.header.release();
    vec.header.retain();

    const data = try ctx.quotationAllocator().create(Value);
    data.* = .{ .vector = vec };
    ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = "body-error",
        .message = "body failed",
        .data = data,
    });

    const saved = ctx.saveErrorState();
    ctx.restoreErrorState(saved);

    try std.testing.expectEqual(@as(u32, 2), vec.header.refcountValue());
}

test "a detached callback error leaves the enclosing state live and comes back whole" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const enclosing_thrown = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = "body-error",
        .message = "body failed",
    });
    ctx.pending_error_message = "body failed";
    ctx.thrown_error = enclosing_thrown;
    ctx.appendPendingSyntheticErrorFrame("enclosing", "<test>", 2, null);

    const saved = ctx.saveErrorState();

    const callback_thrown = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = "callback-error",
        .message = "callback failed",
    });
    ctx.pending_error_message = "callback failed";
    ctx.pending_error_hint = "check the signature";
    ctx.thrown_error = callback_thrown;
    ctx.appendPendingSyntheticErrorFrame("throw", "<test>", 9, null);

    ctx.detachErrorStateForCallback(saved);

    try std.testing.expectEqualStrings("body failed", ctx.pending_error_message.?);
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.pending_error_hint);
    try std.testing.expectEqual(enclosing_thrown, ctx.thrown_error.?);
    try std.testing.expectEqual(@as(usize, 1), ctx.jit_pending_trace_frames.items.len);
    try std.testing.expectEqualStrings("enclosing", ctx.jit_pending_trace_frames.items[0].word_name);

    ctx.reattachCallbackErrorState();

    try std.testing.expectEqualStrings("callback failed", ctx.pending_error_message.?);
    try std.testing.expectEqualStrings("check the signature", ctx.pending_error_hint.?);
    try std.testing.expectEqual(callback_thrown, ctx.thrown_error.?);
    try std.testing.expectEqual(@as(usize, 2), ctx.jit_pending_trace_frames.items.len);
    try std.testing.expectEqualStrings("throw", ctx.jit_pending_trace_frames.items[1].word_name);
    try std.testing.expectEqual(@as(?Context.DetachedErrorState, null), ctx.callback_error_state);
}

test "dropping an undrained callback error releases its stash's payload" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const vec = try value_mod.Vector.create(std.testing.allocator);
    defer vec.header.release();
    vec.header.retain();

    const saved = ctx.saveErrorState();

    const data = try ctx.quotationAllocator().create(Value);
    data.* = .{ .vector = vec };
    ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = "callback-error",
        .message = "callback failed",
        .data = data,
    });

    ctx.detachErrorStateForCallback(saved);
    try std.testing.expectEqual(@as(u32, 2), vec.header.refcountValue());

    ctx.dropCallbackErrorState();
    try std.testing.expectEqual(@as(u32, 1), vec.header.refcountValue());
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
        .stack_effect = try stack_effect_mod.box(alloc, .{
            .inputs = &[_]StackEffectParam{},
            .outputs = outputs,
        }),
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

test "ShadowStack spills past its inline buffer and keeps every slot in order" {
    var shadow = Context.ShadowStack{ .allocator = std.testing.allocator };
    defer shadow.deinit();

    const capacity = Context.ShadowStack.inline_capacity;
    for (0..capacity) |i| {
        try shadow.append(.{ .inferred_delta = @intCast(i) });
    }
    try std.testing.expect(shadow.spilled == null);

    const total = capacity + 3;
    for (capacity..total) |i| {
        try shadow.append(.{ .inferred_delta = @intCast(i) });
    }
    try std.testing.expect(shadow.spilled != null);
    try std.testing.expectEqual(@as(usize, total), shadow.len());
    for (shadow.constSlice(), 0..) |slot, i| {
        try std.testing.expectEqual(@as(i64, @intCast(i)), slot.inferred_delta);
    }

    shadow.shrinkTo(2);
    try std.testing.expectEqual(@as(usize, 2), shadow.len());
    try std.testing.expectEqual(@as(i64, 1), shadow.constSlice()[1].inferred_delta);

    try shadow.append(.unknown);
    try std.testing.expectEqual(@as(usize, 3), shadow.len());
    try std.testing.expect(shadow.constSlice()[2] == .unknown);
}

/// ( n quot: ( n -- n n ) -- n n ), boxed on `alloc`: the annotated parameter expects delta +1.
fn testAnnotatedQuotationEffect(alloc: Allocator) !*const StackEffect {
    const quot_effect = try stack_effect_mod.box(alloc, .{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{ .{ .name = "n" }, .{ .name = "n" } },
    });

    const inputs = try alloc.alloc(StackEffectParam, 2);
    inputs[0] = .{ .name = "n" };
    inputs[1] = .{ .name = "quot", .quotation_effect = quot_effect };

    return stack_effect_mod.box(alloc, .{
        .inputs = inputs,
        .outputs = &[_]StackEffectParam{ .{ .name = "n" }, .{ .name = "n" } },
    });
}

test "param_effect_cache: one entry per site, guarded on the argument body" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const alloc = ctx.quotationAllocator();
    const effect = try testAnnotatedQuotationEffect(alloc);

    const caller = try alloc.alloc(Instruction, 1);
    caller[0] = .{ .op = .{ .call_word = "annotated" }, .line = 1 };
    const site: Context.ParamEffectSite = .{ .instructions = caller, .index = 0, .owner = null };
    const key: ParamEffectSiteKey = .{ .body = @intFromPtr(caller.ptr), .index = 0, .param = 1 };

    const one = try alloc.alloc(Instruction, 1);
    one[0] = .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 };
    const two = try alloc.alloc(Instruction, 2);
    two[0] = one[0];
    two[1] = one[0];

    try ctx.stack.push(.{ .fixnum = 5 });
    try ctx.stack.push(.{ .quotation = .{ .instructions = one } });

    try ctx.validateParameterEffects(effect, site);
    try ctx.validateParameterEffects(effect, site);
    try std.testing.expectEqual(@as(u32, 1), ctx.param_effect_cache.count());
    const entry = ctx.param_effect_cache.get(key).?;
    try std.testing.expectEqual(@intFromPtr(one.ptr), entry.arg_body);
    try std.testing.expectEqual(@as(i64, 1), entry.delta);
    try std.testing.expect(entry.effect == effect);

    // A different body at the same site misses the guard, is walked, and is reported. The walk's
    // own result displaces the entry.
    ctx.stack.items.items[1] = .{ .quotation = .{ .instructions = two } };
    try std.testing.expectError(primitives.InterpreterError.StackEffectMismatch, ctx.validateParameterEffects(effect, site));
    try std.testing.expectEqual(@as(u32, 1), ctx.param_effect_cache.count());
    try std.testing.expectEqual(@intFromPtr(two.ptr), ctx.param_effect_cache.get(key).?.arg_body);

    ctx.stack.items.items[1] = .{ .quotation = .{ .instructions = one } };
    try ctx.validateParameterEffects(effect, site);
    try std.testing.expectEqual(@intFromPtr(one.ptr), ctx.param_effect_cache.get(key).?.arg_body);
}

test "param_effect_cache: closure-owned bodies, site-less calls, and empty arguments write nothing" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const alloc = ctx.quotationAllocator();
    const effect = try testAnnotatedQuotationEffect(alloc);

    const caller = try alloc.alloc(Instruction, 1);
    caller[0] = .{ .op = .{ .call_word = "annotated" }, .line = 1 };
    const site: Context.ParamEffectSite = .{ .instructions = caller, .index = 0, .owner = null };

    const literal = try alloc.alloc(Instruction, 1);
    literal[0] = .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 };

    // A curry product owns its body.
    const owned_body = try std.testing.allocator.alloc(Instruction, 1);
    owned_body[0] = literal[0];
    const arg_closure = try value_mod.Closure.create(std.testing.allocator, .{
        .instructions = owned_body,
        .segments = &.{},
        .owns_body = true,
        .header = undefined,
    });
    defer container_backing.releaseValue(.{ .closure = arg_closure });

    try ctx.stack.push(.{ .fixnum = 5 });
    try ctx.stack.push(.{ .closure = arg_closure });
    try ctx.validateParameterEffects(effect, site);
    try std.testing.expectEqual(@as(u32, 0), ctx.param_effect_cache.count());
    try ctx.stack.popAndRelease();

    // A caller body a closure owns is not a durable site either.
    const owned_caller = try std.testing.allocator.alloc(Instruction, 1);
    owned_caller[0] = caller[0];
    const caller_closure = try value_mod.Closure.create(std.testing.allocator, .{
        .instructions = owned_caller,
        .segments = &.{},
        .owns_body = true,
        .header = undefined,
    });
    defer container_backing.releaseValue(.{ .closure = caller_closure });

    try ctx.stack.push(.{ .quotation = .{ .instructions = literal } });
    try ctx.validateParameterEffects(effect, .{ .instructions = owned_caller, .index = 0, .owner = caller_closure });
    try std.testing.expectEqual(@as(u32, 0), ctx.param_effect_cache.count());

    // A compiled call site names no site.
    try ctx.validateParameterEffects(effect, null);
    try std.testing.expectEqual(@as(u32, 0), ctx.param_effect_cache.count());

    // An empty body's pointer is the shared zero-length sentinel, so the verdict is reported but
    // never recorded.
    const empty = try alloc.alloc(Instruction, 0);
    ctx.stack.items.items[1] = .{ .quotation = .{ .instructions = empty } };
    try std.testing.expectError(primitives.InterpreterError.StackEffectMismatch, ctx.validateParameterEffects(effect, site));
    try std.testing.expectEqual(@as(u32, 0), ctx.param_effect_cache.count());
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

    const desc1 = try ctx.getOrCreateParameterizedTypeDescriptor(array_tv, &.{fixnum_tv});
    const desc2 = try ctx.getOrCreateParameterizedTypeDescriptor(array_tv, &.{fixnum_tv});
    try std.testing.expect(desc1 == desc2);

    const desc3 = try ctx.getOrCreateParameterizedTypeDescriptor(array_tv, &.{string_tv});
    try std.testing.expect(desc1 != desc3);
}

test "parameterized type descriptor interning distinguishes multi-parameter tuples" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const pair_tv = ctx.lookupBuiltinTypeValue("array").?;
    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;

    // Same base and same tuple reuse the descriptor.
    const desc_fs = try ctx.getOrCreateParameterizedTypeDescriptor(pair_tv, &.{ fixnum_tv, string_tv });
    const desc_fs2 = try ctx.getOrCreateParameterizedTypeDescriptor(pair_tv, &.{ fixnum_tv, string_tv });
    try std.testing.expect(desc_fs == desc_fs2);

    // Position is significant: swapping the tuple order yields a distinct key.
    const desc_sf = try ctx.getOrCreateParameterizedTypeDescriptor(pair_tv, &.{ string_tv, fixnum_tv });
    try std.testing.expect(desc_fs != desc_sf);

    // Arity is significant: a one-element tuple differs from a two-element one.
    const desc_f = try ctx.getOrCreateParameterizedTypeDescriptor(pair_tv, &.{fixnum_tv});
    try std.testing.expect(desc_fs != desc_f);
}

test "struct descriptor interning reuses descriptor for same shape" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fields_xy = [_][]const u8{ "x", "y" };
    const fields_yx = [_][]const u8{ "y", "x" };
    const no_field_types = [_]?value_mod.ConstraintCombinator.Element{};
    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;
    const typed_fixnum_fixnum = [_]?value_mod.ConstraintCombinator.Element{ .{ .type = fixnum_tv }, .{ .type = fixnum_tv } };
    const typed_fixnum_string = [_]?value_mod.ConstraintCombinator.Element{ .{ .type = fixnum_tv }, .{ .type = string_tv } };

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

    const methods_a = [_]value_mod.Value{value_mod.symbolValue("cmp")};
    const methods_b = [_]value_mod.Value{value_mod.symbolValue("inspect")};

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

    const methods = [_]value_mod.Value{ value_mod.symbolValue("cmp"), value_mod.symbolValue(">string") };
    const desc = try ctx.createProtocolDescriptor("ordered-stringable", &methods);

    try std.testing.expectEqualStrings("ordered-stringable", desc.name);
    try std.testing.expectEqual(@as(usize, 2), desc.methods.len);
    try std.testing.expectEqualStrings("cmp", desc.methods[0].symbol.bytes);
    try std.testing.expectEqualStrings(">string", desc.methods[1].symbol.bytes);
}

test "createProtocolDescriptor assigns monotonic protocol_id" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const methods = [_]value_mod.Value{value_mod.symbolValue("cmp")};
    const desc0 = try ctx.createProtocolDescriptor("p0", &methods);
    const desc1 = try ctx.createProtocolDescriptor("p1", &methods);
    const desc2 = try ctx.createProtocolDescriptor("p2", &methods);

    try std.testing.expectEqual(@as(u32, 0), desc0.protocol_id);
    try std.testing.expectEqual(@as(u32, 1), desc1.protocol_id);
    try std.testing.expectEqual(@as(u32, 2), desc2.protocol_id);
}

test "createConstraintCombinator returns stable distinct pointers" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const methods = [_]value_mod.Value{value_mod.symbolValue("cmp")};
    const proto = try ctx.createProtocolDescriptor("comparable", &methods);

    const elements = [_]value_mod.ConstraintCombinator.Element{
        .{ .type = fixnum_tv },
        .{ .protocol = proto },
    };

    const cc1 = try ctx.createConstraintCombinator(.@"union", &elements);
    const cc2 = try ctx.createConstraintCombinator(.intersection, &elements);
    try std.testing.expect(cc1 != cc2);

    // Same kind and elements still produce a distinct descriptor; there is no
    // structural interning.
    const cc3 = try ctx.createConstraintCombinator(.@"union", &elements);
    try std.testing.expect(cc1 != cc3);
}

test "createConstraintCombinator populates kind and elements" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const methods = [_]value_mod.Value{value_mod.symbolValue("cmp")};
    const proto = try ctx.createProtocolDescriptor("comparable", &methods);

    const elements = [_]value_mod.ConstraintCombinator.Element{
        .{ .type = fixnum_tv },
        .{ .protocol = proto },
    };
    const cc = try ctx.createConstraintCombinator(.intersection, &elements);

    try std.testing.expectEqual(value_mod.ConstraintCombinator.Kind.intersection, cc.kind);
    try std.testing.expectEqual(@as(usize, 2), cc.elements.len);
    try std.testing.expectEqual(fixnum_tv, cc.elements[0].type);
    try std.testing.expectEqual(proto, cc.elements[1].protocol);

    // A nested combinator element composes recursively.
    const nested_elements = [_]value_mod.ConstraintCombinator.Element{.{ .combinator = cc }};
    const outer = try ctx.createConstraintCombinator(.@"union", &nested_elements);
    try std.testing.expectEqual(value_mod.ConstraintCombinator.Kind.@"union", outer.kind);
    try std.testing.expectEqual(cc, outer.elements[0].combinator);
}

test "createConstraintCombinator assigns monotonic combinator_id" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const elements = [_]value_mod.ConstraintCombinator.Element{.{ .type = fixnum_tv }};

    const cc0 = try ctx.createConstraintCombinator(.intersection, &elements);
    const cc1 = try ctx.createConstraintCombinator(.intersection, &elements);
    const cc2 = try ctx.createConstraintCombinator(.@"union", &elements);

    try std.testing.expectEqual(@as(u32, 0), cc0.combinator_id);
    try std.testing.expectEqual(@as(u32, 1), cc1.combinator_id);
    try std.testing.expectEqual(@as(u32, 2), cc2.combinator_id);
}

test "protocol satisfies cache returns stored hits" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const string_tv = ctx.lookupBuiltinTypeValue("string").?;
    const methods = [_]value_mod.Value{value_mod.symbolValue("cmp")};
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
    const methods = [_]value_mod.Value{value_mod.symbolValue("cmp")};
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

    const methods = [_]value_mod.Value{value_mod.symbolValue("no-such-method")};
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
    const methods = [_]value_mod.Value{value_mod.symbolValue("cmp")};
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
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    try std.testing.expectEqual(@as(?bool, null), ctx.lookupProtocolSatisfies(key));
}

test "protocol satisfies cache invalidated by dispatch frame pop" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const methods = [_]value_mod.Value{value_mod.symbolValue("cmp")};
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

test "protocol satisfies cache invalidated by redefinition" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const methods = [_]value_mod.Value{value_mod.symbolValue("cmp")};
    const desc = try ctx.createProtocolDescriptor("comparable", &methods);

    const key = ProtocolSatisfiesKey{
        .type_descriptor = fixnum_tv.descriptor.?,
        .protocol_descriptor = desc,
    };

    try ctx.defineWord("cmp", .{ .name = "cmp", .action = .{ .literal = .{ .fixnum = 1 } } });
    ctx.storeProtocolSatisfies(key, true);
    try std.testing.expectEqual(@as(?bool, true), ctx.lookupProtocolSatisfies(key));

    // The memo counts entries keyed by the protocol word's dispatch id, and the redefinition
    // mints a new one, so the answer it holds no longer describes the word named `cmp`.
    try ctx.defineWord("cmp", .{ .name = "cmp", .action = .{ .literal = .{ .fixnum = 2 } } });
    try std.testing.expectEqual(@as(?bool, null), ctx.lookupProtocolSatisfies(key));
}

test "defineWordLocked: the dispatch generation moves only when the name already named a word" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const fresh_before = ctx.dispatch.generation;
    try ctx.defineWord("w", .{ .name = "w", .action = .{ .literal = .{ .fixnum = 1 } } });
    try std.testing.expectEqual(fresh_before, ctx.dispatch.generation);

    const redef_before = ctx.dispatch.generation;
    try ctx.defineWord("w", .{ .name = "w", .action = .{ .literal = .{ .fixnum = 2 } } });
    try std.testing.expect(ctx.dispatch.generation != redef_before);

    // A definition landing above an existing word changes which definition an already-warm
    // call site resolves to, so it strands cached entries the same way a redefinition does.
    try ctx.pushLocalFrame();
    defer ctx.popLocalFrame();

    const shadow_before = ctx.dispatch.generation;
    try ctx.defineWord("w", .{ .name = "w", .action = .{ .literal = .{ .fixnum = 3 } } });
    try std.testing.expect(ctx.dispatch.generation != shadow_before);

    const unrelated_before = ctx.dispatch.generation;
    try ctx.defineWord("v", .{ .name = "v", .action = .{ .literal = .{ .fixnum = 4 } } });
    try std.testing.expectEqual(unrelated_before, ctx.dispatch.generation);
}

test "defineWordLocked: a redefinition dropping registered methods reports unless override is claimed" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.defineWord("area", .{
        .name = "area",
        .action = .{ .literal = .{ .fixnum = 1 } },
        .markers = &.{@constCast(&markers_mod.generic_marker)},
    });
    const old_id = ctx.lookupWord("area").?.dispatch_id;

    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const body = [_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 0 }};
    try ctx.registerDispatch(
        .{ .dispatch_id = old_id, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = &body } } },
        false,
    );

    try std.testing.expectError(error.OrphanedMethods, ctx.defineWord("area", .{ .name = "area", .action = .{ .literal = .{ .fixnum = 2 } } }));
    try std.testing.expectEqualStrings("redefining 'area' would drop 1 registered method", ctx.pending_error_message.?);

    // A definition in a fresh frame is a shadow, not a same-scope redefinition.
    {
        try ctx.pushLocalFrame();
        defer ctx.popLocalFrame();
        try ctx.defineWord("area", .{ .name = "area", .action = .{ .literal = .{ .fixnum = 3 } } });
    }

    try ctx.defineWord("area", .{
        .name = "area",
        .action = .{ .literal = .{ .fixnum = 4 } },
        .markers = &.{@constCast(&markers_mod.override_marker)},
    });

    // A generated existing word is exempt even when its id owns entries.
    try ctx.defineWord("gen", .{
        .name = "gen",
        .action = .{ .literal = .{ .fixnum = 5 } },
        .markers = &.{@constCast(&markers_mod.generic_marker)},
        .provenance = .{ .generator = "struct", .parent = "gen-type", .role = "constructor" },
    });
    const gen_id = ctx.lookupWord("gen").?.dispatch_id;
    try ctx.registerDispatch(
        .{ .dispatch_id = gen_id, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = &body } } },
        false,
    );
    try ctx.defineWord("gen", .{ .name = "gen", .action = .{ .literal = .{ .fixnum = 6 } } });

    // A word that cannot receive methods is never scanned, so a Zig-side registration under a
    // plain word's id stays outside the guard's reach.
    try ctx.defineWord("plain", .{ .name = "plain", .action = .{ .literal = .{ .fixnum = 7 } } });
    const plain_id = ctx.lookupWord("plain").?.dispatch_id;
    try ctx.registerDispatch(
        .{ .dispatch_id = plain_id, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = &body } } },
        false,
    );
    try ctx.defineWord("plain", .{ .name = "plain", .action = .{ .literal = .{ .fixnum = 8 } } });
}

test "defineWordLocked: a durable-frame shadow leaves the native's dictionary slot intact" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // A clobbering `Dictionary.put` reuses the existing slot and swaps its boxed definition, so
    // the detector is the loaded definition still being the native. The slot-identity check pins
    // the shape baked call sites depend on: they hold this pointer.
    const native_slot = ctx.dictionary.getSlot("dup").?;
    const native_fn = ctx.dictionary.get("dup").?.action.native;

    // The durable entry frame every AOT binary pushes at boot, in the interpreter-free shape:
    // frame 0, no prelude frame below it.
    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    ctx.image_entry_import_frame = 0;

    try ctx.defineWord("dup", .{
        .name = "dup",
        .action = .{ .literal = .{ .fixnum = 1 } },
        .markers = &.{@constCast(&markers_mod.override_marker)},
    });

    try std.testing.expectEqual(native_slot, ctx.dictionary.getSlot("dup").?);
    try std.testing.expectEqual(native_fn, ctx.dictionary.get("dup").?.action.native);
    try std.testing.expect(ctx.lookupWord("dup").?.action == .literal);
}

test "defineWordLocked: the shadow guard fires from the durable frame with no prelude frame below" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    ctx.image_entry_import_frame = 0;

    // The probe's frame rung walks `[0..floor]`, which is empty here, so the dictionary rung is
    // what finds the native.
    try std.testing.expectError(error.ImportConflict, ctx.defineWord("dup", .{
        .name = "dup",
        .action = .{ .literal = .{ .fixnum = 1 } },
    }));
    try std.testing.expectEqualStrings("defining 'dup' would shadow a native word", ctx.pending_error_message.?);
}

/// One durable entry frame at index 0, the interpreter-free boot shape the baked-rung tests
/// share, with a baked base scope attached.
fn setupBakedScopeProbe(ctx: *Context, scope: AotBaseScope) !void {
    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    ctx.image_entry_import_frame = 0;
    ctx.aot_base_scope = scope;
}

const baked_scope_names = [_][*:0]const u8{"baked-prelude-word"};
const baked_scope_sources = [_]?[*:0]const u8{"src/prelude.1z"};
const baked_scope_no_sources = [_]?[*:0]const u8{null};
const baked_scope_plain_flags = [_]u8{0};
const baked_scope_generic_flags = [_]u8{1};
const baked_scope_const_flags = [_]u8{2};

test "defineWordLocked: the baked base-scope rung reports a shadow with its baked source" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try setupBakedScopeProbe(&ctx, .{
        .names = &baked_scope_names,
        .sources = &baked_scope_sources,
        .flags = &baked_scope_plain_flags,
        .count = 1,
    });

    try std.testing.expectError(error.ImportConflict, ctx.defineWord("baked-prelude-word", .{
        .name = "baked-prelude-word",
        .action = .{ .literal = .{ .fixnum = 1 } },
    }));
    try std.testing.expectEqualStrings(
        "defining 'baked-prelude-word' would shadow a word from \"src/prelude.1z\"",
        ctx.pending_error_message.?,
    );
}

test "defineWordLocked: a sourceless baked row degrades to the no-origin message" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try setupBakedScopeProbe(&ctx, .{
        .names = &baked_scope_names,
        .sources = &baked_scope_no_sources,
        .flags = &baked_scope_plain_flags,
        .count = 1,
    });

    try std.testing.expectError(error.ImportConflict, ctx.defineWord("baked-prelude-word", .{
        .name = "baked-prelude-word",
        .action = .{ .literal = .{ .fixnum = 1 } },
    }));
    try std.testing.expectEqualStrings(
        "defining 'baked-prelude-word' would shadow an existing word",
        ctx.pending_error_message.?,
    );
}

test "defineWordLocked: no baked scope leaves the rung inert" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // The interpreter-session shape: nothing registers the tables, so a fresh definition of a
    // name outside the frames and the dictionary stays silent.
    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    ctx.image_entry_import_frame = 0;

    try ctx.defineWord("baked-prelude-word", .{
        .name = "baked-prelude-word",
        .action = .{ .literal = .{ .fixnum = 1 } },
    });
}

test "defineWordLocked: the baked rung honors the generic-merge exemption" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try setupBakedScopeProbe(&ctx, .{
        .names = &baked_scope_names,
        .sources = &baked_scope_sources,
        .flags = &baked_scope_generic_flags,
        .count = 1,
    });

    // A non-generic incoming definition still collides with the generic row.
    try std.testing.expectError(error.ImportConflict, ctx.defineWord("baked-prelude-word", .{
        .name = "baked-prelude-word",
        .action = .{ .literal = .{ .fixnum = 1 } },
    }));

    // Generic over generic merges interpreted, so the rung stays silent for it too.
    try ctx.defineWord("baked-prelude-word", .{
        .name = "baked-prelude-word",
        .action = .{ .literal = .{ .fixnum = 1 } },
        .markers = &.{@constCast(&markers_mod.generic_marker)},
    });
}

test "defineWordLocked: a const-marked baked row refuses through the const guard" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try setupBakedScopeProbe(&ctx, .{
        .names = &baked_scope_names,
        .sources = &baked_scope_sources,
        .flags = &baked_scope_const_flags,
        .count = 1,
    });

    try std.testing.expectError(error.CannotRedefineConst, ctx.defineWord("baked-prelude-word", .{
        .name = "baked-prelude-word",
        .action = .{ .literal = .{ .fixnum = 1 } },
    }));
    try std.testing.expectEqualStrings(
        "cannot redefine const word 'baked-prelude-word'",
        ctx.pending_error_message.?,
    );
}

test "seedEntryWord: the baked dispatch id keeps another word's replayed methods out of the guard" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    ctx.image_entry_import_frame = 0;

    // A replayed generic's method, registered under a freeze-time id the runtime counter was
    // never advanced past -- the shape the image loader's dispatch replay leaves.
    const fixnum_tv = ctx.lookupBuiltinTypeValue("fixnum").?;
    const body = [_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 0 }};
    try ctx.registerDispatch(
        .{ .dispatch_id = 950, .type_a = fixnum_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = &body } } },
        false,
    );

    // A plain seeded word carries its own freeze-time id, so its redefinition reaches the arity
    // check instead of reporting the unrelated methods a minted id could alias.
    const one_out = [_]StackEffectParam{.{ .name = "n" }};
    const seed_effect = StackEffect{ .inputs = &.{}, .outputs = &one_out };
    try ctx.seedEntryWord(.{
        .name = "p1",
        .effect = &seed_effect,
        .word_id = null,
        .dispatch_id = 951,
        .generated = false,
        .is_const = false,
        .is_generic = false,
    });

    const two_in = [_]StackEffectParam{ .{ .name = "x" }, .{ .name = "y" } };
    const redef_effect = StackEffect{ .inputs = &two_in, .outputs = &one_out };
    try std.testing.expectError(error.ArityMismatch, ctx.defineWord("p1", .{
        .name = "p1",
        .stack_effect = &redef_effect,
        .action = .{ .literal = .{ .fixnum = 1 } },
    }));
    try std.testing.expectEqualStrings(
        "arity mismatch on redefinition of 'p1' (was 0 -> 1, now 2 -> 1)",
        ctx.pending_error_message.?,
    );

    // A seeded generic reuses the id its own replayed methods registered under, so an unguarded
    // redefinition reports dropping them, as interpreted.
    try ctx.seedEntryWord(.{
        .name = "gen1",
        .effect = null,
        .word_id = null,
        .dispatch_id = 950,
        .generated = false,
        .is_const = false,
        .is_generic = true,
    });
    ctx.pending_error_message = null;
    try std.testing.expectError(error.OrphanedMethods, ctx.defineWord("gen1", .{
        .name = "gen1",
        .action = .{ .literal = .{ .fixnum = 2 } },
    }));
    try std.testing.expectEqualStrings("redefining 'gen1' would drop 1 registered method", ctx.pending_error_message.?);

    // `override` stays the escape, exactly as for an interpreted generic's redefinition.
    try ctx.defineWord("gen1", .{
        .name = "gen1",
        .action = .{ .literal = .{ .fixnum = 3 } },
        .markers = &.{@constCast(&markers_mod.override_marker)},
    });
}

test "seedEntryWord: seeding advances the mint counter past the baked id" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    ctx.image_entry_import_frame = 0;

    try ctx.seedEntryWord(.{
        .name = "p1",
        .effect = null,
        .word_id = null,
        .dispatch_id = 5000,
        .generated = false,
        .is_const = false,
        .is_generic = false,
    });

    try std.testing.expect(ctx.next_dispatch_id.load(.monotonic) > 5000);

    // A later runtime mint lands above every baked id, so it can never inherit a
    // replayed or seeded identity's registered methods.
    try ctx.defineWord("q1", .{ .name = "q1", .action = .{ .literal = .{ .fixnum = 1 } } });
    const def = ctx.local_frames.items[0].get("q1") orelse return error.TestExpectedDefinition;
    try std.testing.expect(def.dispatch_id > 5000);
}

/// Stand in for the prelude frame `loadPrelude` pushes and the entry frame
/// `onez_push_entry_frame` builds at boot, plus one cached module holding `word_name`.
fn seedEntryImportFixture(ctx: *Context, module_name: []const u8, word_name: []const u8) !void {
    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try ctx.pushLocalFrame();
    try ctx.pushLocalFrame();
    ctx.import_frame_index = 1;
    ctx.durable_frame_floor = 1;
    ctx.image_entry_import_frame = 1;

    const arena_alloc = ctx.arena.allocator();
    const module = try arena_alloc.create(value_mod.Module);
    module.* = .{ .name = module_name, .words = .{} };
    try module.words.put(arena_alloc, word_name, .{ .word_id = 42, .action = .{ .native = noop } });

    const cache_alloc = ctx.module_cache_value.header.allocator;
    try ctx.module_cache_value.map.put(
        cache_alloc,
        try cache_alloc.dupe(u8, module_name),
        .{ .module = module },
    );
}

test "seedEntryImport: the seeded binding carries what the import-collision guard reads" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try seedEntryImportFixture(&ctx, "modc", "probe");
    try ctx.seedEntryImport("probe", "modc");

    const def = ctx.local_frames.items[1].get("probe") orelse return error.TestExpectedImport;
    try std.testing.expect(def.imported);
    try std.testing.expectEqualStrings("modc", (def.source_module orelse return error.TestExpectedModule).name);
    try std.testing.expectEqual(@as(?u32, 42), def.word_id);

    // The body is deliberately the bail sentinel rather than the module word's action, so an
    // interpreted reach raises instead of running a metadata-only image's empty stream.
    try std.testing.expectEqual(Context.aotCompiledOnlyBailSentinel, def.action.native);
}

test "seedEntryImport: a definition over a seeded import reports the import conflict" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try seedEntryImportFixture(&ctx, "modc", "probe");
    try ctx.seedEntryImport("probe", "modc");

    try std.testing.expectError(error.ImportConflict, ctx.defineWord("probe", .{
        .name = "probe",
        .action = .{ .literal = .{ .fixnum = 1 } },
    }));
    try std.testing.expect(std.mem.indexOf(u8, ctx.pending_error_message.?, "\"modc\"") != null);
}

test "seedEntryImport: an unresolvable row and an occupied name are both skipped" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try seedEntryImportFixture(&ctx, "modc", "probe");

    // Neither an absent module nor an absent word is guessed at.
    try ctx.seedEntryImport("probe", "nowhere");
    try ctx.seedEntryImport("ghost", "modc");
    try std.testing.expectEqual(@as(usize, 0), ctx.local_frames.items[1].count());

    // A binding the loader already restored wins: it carries a real body this stub cannot.
    try ctx.local_frames.items[1].put(ctx.allocator, "probe", .{
        .name = "probe",
        .action = .{ .literal = .{ .fixnum = 9 } },
    });
    try ctx.seedEntryImport("probe", "modc");
    const def = ctx.local_frames.items[1].get("probe") orelse return error.TestExpectedImport;
    try std.testing.expect(!def.imported);
}

test "seedEntryImport: a boot that never pushed the entry frame seeds nothing" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try seedEntryImportFixture(&ctx, "modc", "probe");
    ctx.image_entry_import_frame = null;

    try ctx.seedEntryImport("probe", "modc");
    try std.testing.expectEqual(@as(usize, 0), ctx.local_frames.items[1].count());
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

test "enum registry iterates in registration order" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const alloc = ctx.arena.allocator();
    var tvs: [3]*value_mod.TypeValue = undefined;
    const names = [_][]const u8{ "reg-order-a:", "reg-order-b:", "reg-order-c:" };
    for (&tvs, names) |*slot, name| {
        const tv = try alloc.create(value_mod.TypeValue);
        tv.* = .{ .name = name, .descriptor = null };
        slot.* = tv;
        try ctx.registerEnumVariants(tv, &.{});
    }

    const reg = &ctx.type_registry_frames.items[ctx.type_registry_frames.items.len - 1].enum_registry;
    const keys = reg.keys();
    try std.testing.expect(keys.len >= 3);
    const base = keys.len - 3;
    for (tvs, 0..) |tv, i| {
        try std.testing.expectEqual(@as(*const value_mod.TypeValue, tv), keys[base + i]);
    }
}

test "deriveEnumTypeParams orders distinct parameters by first appearance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const t = try value_mod.mintTypeParameter(alloc, "T", 0);
    const e = try value_mod.mintTypeParameter(alloc, "E", 1);

    // Two variant bases, each a virtual carrying one enum parameter.
    const ok_desc = try value_mod.createTypeDescriptor(alloc, .{ .virtual = .{ .type_params = &.{t} } }, .{});
    const ok_tv = try alloc.create(value_mod.TypeValue);
    ok_tv.* = .{ .name = "okv(T)", .descriptor = ok_desc };
    const err_desc = try value_mod.createTypeDescriptor(alloc, .{ .virtual = .{ .type_params = &.{e} } }, .{});
    const err_tv = try alloc.create(value_mod.TypeValue);
    err_tv.* = .{ .name = "errv(E)", .descriptor = err_desc };

    const params = try Context.deriveEnumTypeParams(alloc, &.{ ok_tv, err_tv });
    try std.testing.expectEqual(@as(usize, 2), params.len);
    try std.testing.expect(params[0] == t);
    try std.testing.expect(params[1] == e);
}

test "deriveEnumTypeParams shares a parameter used by several variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const t = try value_mod.mintTypeParameter(alloc, "T", 0);
    const left_desc = try value_mod.createTypeDescriptor(alloc, .{ .virtual = .{ .type_params = &.{t} } }, .{});
    const left_tv = try alloc.create(value_mod.TypeValue);
    left_tv.* = .{ .name = "lpay(T)", .descriptor = left_desc };
    const right_desc = try value_mod.createTypeDescriptor(alloc, .{ .virtual = .{ .type_params = &.{t} } }, .{});
    const right_tv = try alloc.create(value_mod.TypeValue);
    right_tv.* = .{ .name = "rpay(T)", .descriptor = right_desc };

    const params = try Context.deriveEnumTypeParams(alloc, &.{ left_tv, right_tv });
    try std.testing.expectEqual(@as(usize, 1), params.len);
    try std.testing.expect(params[0] == t);
}

test "resolveBaseParams returns an enum's declared type parameters" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    const alloc = ctx.arena.allocator();

    const t = try value_mod.mintTypeParameter(alloc, "T", 0);
    const e = try value_mod.mintTypeParameter(alloc, "E", 1);
    const enum_desc = try value_mod.createTypeDescriptor(alloc, .{ .enum_ = .{ .type_params = &.{ t, e } } }, .{});
    const enum_tv = try alloc.create(value_mod.TypeValue);
    enum_tv.* = .{ .name = "outcome", .descriptor = enum_desc };

    const base = ctx.resolveBaseParams(enum_tv);
    try std.testing.expectEqual(@as(usize, 2), base.declared.len);
    try std.testing.expectEqual(@as(usize, 2), base.current.len);
    try std.testing.expect(base.declared[0] == t);
    try std.testing.expect(base.current[1] == e);
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
        .{ .body = .{ .quotation = .{ .instructions = body } } },
        false,
    );

    try std.testing.expect(ctx.lookupUnaryDispatch(did, fixnum_tv.descriptor.?) != null);

    // Push a frame and register a new entry
    try ctx.pushDispatchFrame();
    const body2 = &[_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 99 } }, .line = 0 }};
    try ctx.registerDispatch(
        .{ .dispatch_id = did, .type_a = string_tv.descriptor.?, .type_b = ctx.getDispatchUnarySentinel().descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = body2 } } },
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
        .{ .body = .{ .quotation = .{ .instructions = body1 } } },
        false,
    );

    // Push frame and shadow
    try ctx.pushDispatchFrame();
    try ctx.registerDispatch(
        .{ .dispatch_id = did, .type_a = duration_tv.descriptor.?, .type_b = duration_tv.descriptor.? },
        .{ .body = .{ .quotation = .{ .instructions = body2 } } },
        false,
    );

    // Inner should win
    const entry = ctx.lookupBinaryDispatch(did, duration_tv.descriptor.?, duration_tv.descriptor.?).?;
    try std.testing.expectEqual(@as(i64, 2), entry.body.quotation.instructions[0].op.push_literal.fixnum);

    // Pop; outer visible again
    ctx.popDispatchFrame();
    const entry2 = ctx.lookupBinaryDispatch(did, duration_tv.descriptor.?, duration_tv.descriptor.?).?;
    try std.testing.expectEqual(@as(i64, 1), entry2.body.quotation.instructions[0].op.push_literal.fixnum);
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
        .{ .body = .{ .quotation = .{ .instructions = body } } },
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

test "constraint_combinator and protocol_descriptor share the constraint TypeValue" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const cc_tv = ctx.lookupBuiltinTypeValueByTag(.constraint_combinator);
    const pd_tv = ctx.lookupBuiltinTypeValueByTag(.protocol_descriptor);
    try std.testing.expect(cc_tv != null);
    try std.testing.expect(pd_tv != null);
    try std.testing.expect(cc_tv.? == pd_tv.?);
    try std.testing.expectEqualStrings("constraint", cc_tv.?.name);
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

test "lookupWordLocked: descendant reads ancestor stable scope, not transient frames" {
    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    // Frame 0 is the parent's import frame: its durable scope.
    try parent.pushLocalFrame();
    parent.import_frame_index = parent.local_frames.items.len - 1;
    parent.durable_frame_floor = parent.import_frame_index;
    try parent.local_frames.items[parent.import_frame_index.?].put(parent.allocator, "stable-word", .{
        .name = "stable-word",
        .action = .{ .native = noop },
    });

    // A combinator frame above the import frame: transient execution state.
    try parent.pushLocalFrame();
    try parent.local_frames.items[parent.local_frames.items.len - 1].put(parent.allocator, "transient-word", .{
        .name = "transient-word",
        .action = .{ .native = noop },
    });

    var child = Context.init(std.testing.allocator);
    defer child.deinit();
    // Wire the ancestor link only for the lookups; restore null before deinit
    // so each context frees its own root-owned allocators.
    child.parent_context = &parent;
    defer child.parent_context = null;

    try std.testing.expect(child.lookupWordLocked("stable-word", null) != null);
    try std.testing.expect(child.lookupWordLocked("transient-word", null) == null);
}

test "lookupWordLocked: ancestor walk caps at the durable floor, not the moved import frame" {
    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    // Mid-load shape: frame 0 is the durable scope, frame 1 is a runtime load's live import
    // frame. The load moves `import_frame_index` but not the floor, so a descendant must not
    // resolve the load frame's words.
    try parent.pushLocalFrame();
    parent.import_frame_index = 0;
    parent.durable_frame_floor = 0;
    try parent.local_frames.items[0].put(parent.allocator, "stable-word", .{
        .name = "stable-word",
        .action = .{ .native = noop },
    });

    try parent.pushLocalFrame();
    parent.import_frame_index = 1;
    try parent.local_frames.items[1].put(parent.allocator, "load-word", .{
        .name = "load-word",
        .action = .{ .native = noop },
    });

    var child = Context.init(std.testing.allocator);
    defer child.deinit();
    child.parent_context = &parent;
    defer child.parent_context = null;

    try std.testing.expect(child.lookupWordLocked("stable-word", null) != null);
    try std.testing.expect(child.lookupWordLocked("load-word", null) == null);
}

test "lookupWordStackEffectPtrLocked: descendant skips ancestor transient frames" {
    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;
    const empty_effect = StackEffect{
        .inputs = &[_]StackEffectParam{},
        .outputs = &[_]StackEffectParam{},
    };

    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    try parent.pushLocalFrame();
    parent.import_frame_index = parent.local_frames.items.len - 1;
    parent.durable_frame_floor = parent.import_frame_index;
    try parent.local_frames.items[parent.import_frame_index.?].put(parent.allocator, "stable-eff", .{
        .name = "stable-eff",
        .stack_effect = &empty_effect,
        .action = .{ .native = noop },
    });

    try parent.pushLocalFrame();
    try parent.local_frames.items[parent.local_frames.items.len - 1].put(parent.allocator, "transient-eff", .{
        .name = "transient-eff",
        .stack_effect = &empty_effect,
        .action = .{ .native = noop },
    });

    var child = Context.init(std.testing.allocator);
    defer child.deinit();
    child.parent_context = &parent;
    defer child.parent_context = null;

    try std.testing.expect(child.lookupWordStackEffectPtrLocked("stable-eff") != null);
    try std.testing.expect(child.lookupWordStackEffectPtrLocked("transient-eff") == null);
}

test "pushLocalFrame: growth keeps the three frame arrays in parity" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try ctx.pushLocalFrame();
        try std.testing.expectEqual(ctx.local_frames.items.len, ctx.local_frame_kinds.items.len);
        try std.testing.expectEqual(ctx.local_frames.items.len, ctx.local_frame_modules.items.len);
    }

    while (i > 0) : (i -= 1) ctx.popLocalFrame();
}

test "pushLocalFrame: capacity growth excludes a concurrent ancestor walk" {
    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    // Each iteration starts from a fresh, tiny frame array so every deepening push
    // reallocates the backing while the reader thread walks the durable frame under
    // the shared read lock. Without the locked growth this dereferences the freed
    // buffer, which the testing allocator's freed-memory poisoning turns into a crash.
    const Reader = struct {
        fn run(c: *Context, done: *std.atomic.Value(bool)) void {
            while (!done.load(.acquire)) {
                std.debug.assert(c.lookupWord("stable-word") != null);
            }
        }
    };

    var iter_n: usize = 0;
    while (iter_n < 100) : (iter_n += 1) {
        var parent = Context.init(std.testing.allocator);
        defer parent.deinit();

        try parent.pushLocalFrame();
        parent.import_frame_index = 0;
        parent.durable_frame_floor = 0;
        try parent.local_frames.items[0].put(parent.allocator, "stable-word", .{
            .name = "stable-word",
            .action = .{ .native = noop },
        });

        var child = Context.init(std.testing.allocator);
        defer child.deinit();
        child.parent_context = &parent;
        defer child.parent_context = null;

        // Mirror `initForTask`: the walk and the growth must contend on one lock.
        // The child's own lock is restored before deinit so each context still
        // destroys the one it allocated.
        const child_lock = child.shared_lock;
        const child_tracker = child.lock_order_tracker;
        child.shared_lock = parent.shared_lock;
        child.lock_order_tracker = parent.lock_order_tracker;
        defer {
            child.shared_lock = child_lock;
            child.lock_order_tracker = child_tracker;
        }

        var done = std.atomic.Value(bool).init(false);
        const reader = try std.Thread.spawn(.{}, Reader.run, .{ &child, &done });

        var depth: usize = 0;
        while (depth < 2048) : (depth += 1) try parent.pushLocalFrame();
        while (depth > 0) : (depth -= 1) parent.popLocalFrame();

        done.store(true, .release);
        reader.join();
    }
}

test "preResolveCallTarget: ancestor transient frame no longer blocks, stable frame still does" {
    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    try parent.pushLocalFrame();
    parent.import_frame_index = parent.local_frames.items.len - 1;
    parent.durable_frame_floor = parent.import_frame_index;
    // A stable-scope binding on an ancestor must still veto pre-resolution.
    try parent.local_frames.items[parent.import_frame_index.?].put(parent.allocator, "stable-claim", .{
        .name = "stable-claim",
        .action = .{ .native = noop },
    });
    // A transient-scope binding on an ancestor is task-private and must not.
    try parent.pushLocalFrame();
    try parent.local_frames.items[parent.local_frames.items.len - 1].put(parent.allocator, "transient-claim", .{
        .name = "transient-claim",
        .action = .{ .native = noop },
    });

    var child = Context.init(std.testing.allocator);
    defer child.deinit();
    try child.dictionary.put("stable-claim", .{ .name = "stable-claim", .action = .{ .native = noop } });
    try child.dictionary.put("transient-claim", .{ .name = "transient-claim", .action = .{ .native = noop } });

    child.parent_context = &parent;
    defer child.parent_context = null;

    // Shadowed by the ancestor's stable frame: not pre-resolvable.
    try std.testing.expectEqual(@as(?*dict_mod.WordSlot, null), child.preResolveCallTarget("stable-claim"));
    // Only in the ancestor's transient frame, which the descendant no longer
    // reads: pre-resolves to the child's dictionary slot.
    try std.testing.expectEqual(
        child.dictionary.getSlot("transient-claim").?,
        child.preResolveCallTarget("transient-claim").?,
    );
}

test "propagateWordId: back-writes ancestor stable slot, not transient frame" {
    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    // The import frame (stable scope) and a transient frame above it both bind
    // the same name. A descendant's back-write must land on the stable slot.
    try parent.pushLocalFrame();
    parent.import_frame_index = parent.local_frames.items.len - 1;
    parent.durable_frame_floor = parent.import_frame_index;
    try parent.local_frames.items[parent.import_frame_index.?].put(parent.allocator, "back-word", .{
        .name = "back-word",
        .action = .{ .native = noop },
    });
    try parent.pushLocalFrame();
    try parent.local_frames.items[parent.local_frames.items.len - 1].put(parent.allocator, "back-word", .{
        .name = "back-word",
        .action = .{ .native = noop },
    });

    var child = Context.init(std.testing.allocator);
    defer child.deinit();
    child.parent_context = &parent;
    defer child.parent_context = null;

    propagateWordId(&child, "back-word", 4242);

    try std.testing.expectEqual(
        @as(?u32, 4242),
        parent.local_frames.items[parent.import_frame_index.?].get("back-word").?.word_id,
    );
    try std.testing.expectEqual(
        @as(?u32, null),
        parent.local_frames.items[parent.local_frames.items.len - 1].get("back-word").?.word_id,
    );
}

test "lookupTypeNameByDescriptorLocked: descendant reads ancestor stable type, not transient" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    const alloc = parent.arena.allocator();

    const stable_desc = try value_mod.createBuiltinTypeDescriptor(alloc, .{});
    const stable_tv = try alloc.create(value_mod.TypeValue);
    stable_tv.* = .{ .name = "stable-type", .descriptor = stable_desc };
    const stable_instrs = try alloc.alloc(Instruction, 1);
    stable_instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = stable_tv } }, .line = 0 };

    const transient_desc = try value_mod.createBuiltinTypeDescriptor(alloc, .{});
    const transient_tv = try alloc.create(value_mod.TypeValue);
    transient_tv.* = .{ .name = "transient-type", .descriptor = transient_desc };
    const transient_instrs = try alloc.alloc(Instruction, 1);
    transient_instrs[0] = .{ .op = .{ .push_literal = .{ .type_val = transient_tv } }, .line = 0 };

    try parent.pushLocalFrame();
    parent.import_frame_index = parent.local_frames.items.len - 1;
    parent.durable_frame_floor = parent.import_frame_index;
    try parent.local_frames.items[parent.import_frame_index.?].put(parent.allocator, "stable-type", .{
        .name = "stable-type",
        .action = .{ .compound = stable_instrs },
    });
    try parent.pushLocalFrame();
    try parent.local_frames.items[parent.local_frames.items.len - 1].put(parent.allocator, "transient-type", .{
        .name = "transient-type",
        .action = .{ .compound = transient_instrs },
    });

    var child = Context.init(std.testing.allocator);
    defer child.deinit();
    child.parent_context = &parent;
    defer child.parent_context = null;

    // The stable-frame type resolves through the ancestor's import frame.
    try std.testing.expectEqualStrings(
        "stable-type",
        child.lookupTypeNameByDescriptorLocked(stable_desc).?,
    );
    // The transient-frame type is above the import frame: not read cross-task.
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        child.lookupTypeNameByDescriptorLocked(transient_desc),
    );
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

test "lookupModuleCacheWordLocked: smallest module name wins a public-name collision" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    const arena_alloc = ctx.arena.allocator();
    const zeta = try arena_alloc.create(value_mod.Module);
    zeta.* = .{ .name = "zeta-mod", .words = .{} };
    try zeta.words.put(arena_alloc, "probe", .{
        .source_module = zeta,
        .action = .{ .native = noop },
    });

    const alpha = try arena_alloc.create(value_mod.Module);
    alpha.* = .{ .name = "alpha-mod", .words = .{} };
    try alpha.words.put(arena_alloc, "probe", .{
        .source_module = alpha,
        .action = .{ .native = noop },
    });

    // Inserted zeta-first so insertion order disagrees with name order; the
    // winner must not depend on either insertion or hash-iteration order.
    const cache_alloc = ctx.module_cache_value.header.allocator;
    try ctx.module_cache_value.map.put(
        cache_alloc,
        try cache_alloc.dupe(u8, "zeta-mod"),
        .{ .module = zeta },
    );
    try ctx.module_cache_value.map.put(
        cache_alloc,
        try cache_alloc.dupe(u8, "alpha-mod"),
        .{ .module = alpha },
    );

    ctx.runtime_image_loaded = true;
    const found = ctx.lookupWordForExecution("probe") orelse return error.TestExpectedLookup;
    try std.testing.expectEqual(@as(?*const value_mod.Module, alpha), found.source_module);
}

test "lookupModuleCacheWordLocked: cache key breaks a tie between same-named modules" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    // Two runtime loads of same-named files from different directories: equal
    // `Module.name`, distinct resolved-path cache keys.
    const arena_alloc = ctx.arena.allocator();
    const first = try arena_alloc.create(value_mod.Module);
    first.* = .{ .name = "helpers", .words = .{} };
    try first.words.put(arena_alloc, "probe", .{
        .source_module = first,
        .action = .{ .native = noop },
    });

    const second = try arena_alloc.create(value_mod.Module);
    second.* = .{ .name = "helpers", .words = .{} };
    try second.words.put(arena_alloc, "probe", .{
        .source_module = second,
        .action = .{ .native = noop },
    });

    const cache_alloc = ctx.module_cache_value.header.allocator;
    try ctx.module_cache_value.map.put(
        cache_alloc,
        try cache_alloc.dupe(u8, "/z/helpers.1z"),
        .{ .module = first },
    );
    try ctx.module_cache_value.map.put(
        cache_alloc,
        try cache_alloc.dupe(u8, "/a/helpers.1z"),
        .{ .module = second },
    );

    ctx.runtime_image_loaded = true;
    const found = ctx.lookupWordForExecution("probe") orelse return error.TestExpectedLookup;
    try std.testing.expectEqual(@as(?*const value_mod.Module, second), found.source_module);
}

test "lookupWordViaModuleSegment resolves the named module's word, not the scan winner" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    const arena_alloc = ctx.arena.allocator();
    const zeta = try arena_alloc.create(value_mod.Module);
    zeta.* = .{ .name = "zeta-mod", .words = .{} };
    try zeta.words.put(arena_alloc, "probe", .{
        .source_module = zeta,
        .action = .{ .native = noop },
    });

    const alpha = try arena_alloc.create(value_mod.Module);
    alpha.* = .{ .name = "alpha-mod", .words = .{} };
    try alpha.words.put(arena_alloc, "probe", .{
        .source_module = alpha,
        .action = .{ .native = noop },
    });

    const cache_alloc = ctx.module_cache_value.header.allocator;
    try ctx.module_cache_value.map.put(
        cache_alloc,
        try cache_alloc.dupe(u8, "zeta-mod"),
        .{ .module = zeta },
    );
    try ctx.module_cache_value.map.put(
        cache_alloc,
        try cache_alloc.dupe(u8, "alpha-mod"),
        .{ .module = alpha },
    );

    // The by-name scan's winner is alpha; the segment must override it.
    const found = ctx.lookupWordViaModuleSegment("zeta-mod", "probe") orelse return error.TestExpectedLookup;
    try std.testing.expectEqual(@as(?*const value_mod.Module, zeta), found.source_module);

    try std.testing.expectEqual(
        @as(?WordDefinition, null),
        ctx.lookupWordViaModuleSegment("zeta-mod", "absent"),
    );
}

test "lookupWordViaModuleSegment: cache key breaks a same-named tie, discriminated segment misses" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    const arena_alloc = ctx.arena.allocator();
    const first = try arena_alloc.create(value_mod.Module);
    first.* = .{ .name = "helpers", .words = .{} };
    try first.words.put(arena_alloc, "probe", .{
        .source_module = first,
        .action = .{ .native = noop },
    });

    const second = try arena_alloc.create(value_mod.Module);
    second.* = .{ .name = "helpers", .words = .{} };
    try second.words.put(arena_alloc, "probe", .{
        .source_module = second,
        .action = .{ .native = noop },
    });

    const cache_alloc = ctx.module_cache_value.header.allocator;
    try ctx.module_cache_value.map.put(
        cache_alloc,
        try cache_alloc.dupe(u8, "/z/helpers.1z"),
        .{ .module = first },
    );
    try ctx.module_cache_value.map.put(
        cache_alloc,
        try cache_alloc.dupe(u8, "/a/helpers.1z"),
        .{ .module = second },
    );

    const found = ctx.lookupWordViaModuleSegment("helpers", "probe") orelse return error.TestExpectedLookup;
    try std.testing.expectEqual(@as(?*const value_mod.Module, second), found.source_module);

    // A freeze-discriminated segment names no cached module.
    try std.testing.expectEqual(
        @as(?WordDefinition, null),
        ctx.lookupWordViaModuleSegment("helpers#0", "probe"),
    );
}

test "module-cache scan is skipped for a body with a defining module" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    const arena_alloc = ctx.arena.allocator();
    const foreign = try arena_alloc.create(value_mod.Module);
    foreign.* = .{ .name = "foreign-mod", .words = .{} };
    try foreign.words.put(arena_alloc, "probe", .{
        .source_module = foreign,
        .action = .{ .native = noop },
    });

    const own = try arena_alloc.create(value_mod.Module);
    own.* = .{ .name = "own-mod", .words = .{} };

    const cache_alloc = ctx.module_cache_value.header.allocator;
    try ctx.module_cache_value.map.put(
        cache_alloc,
        try cache_alloc.dupe(u8, "foreign-mod"),
        .{ .module = foreign },
    );
    ctx.runtime_image_loaded = true;

    // A live compiled entry for the module-owned name sits in jit_dispatch below the scan. The
    // veto must decide the miss before the sweep can resolve it.
    const fake_code: *const anyopaque = @ptrCast(&fakeAotCodeMarker);
    const probe_wid = try ctx.jit_dispatch.assignId("probe");
    ctx.jit_dispatch.setCodePtr(probe_wid, fake_code);

    // A module-owned name outside the stamped body's scope must miss. Neither the foreign
    // module's export nor its compiled function may resolve.
    try std.testing.expectEqual(
        @as(?WordDefinition, null),
        ctx.lookupWordForExecutionOwnScope("probe", null, own, &.{}),
    );
    try std.testing.expectEqual(
        @as(?WordDefinition, null),
        ctx.lookupWordForExecutionFiltered("probe", null, own),
    );

    // A compiled name owned by no module (an entry-file top-level word) still
    // reaches the stamped body through the sweep.
    const top_wid = try ctx.jit_dispatch.assignId("top-level");
    ctx.jit_dispatch.setCodePtr(top_wid, fake_code);
    const swept = ctx.lookupWordForExecutionOwnScope("top-level", null, own, &.{}) orelse
        return error.TestExpectedLookup;
    try std.testing.expectEqual(@as(?u32, top_wid), swept.word_id);

    // A module-less body keeps the scan as its by-name last resort.
    const scanned = ctx.lookupWordForExecutionOwnScope("probe", null, null, &.{}) orelse
        return error.TestExpectedLookup;
    try std.testing.expectEqual(@as(?*const value_mod.Module, foreign), scanned.source_module);
    const filtered = ctx.lookupWordForExecutionFiltered("probe", null, null) orelse
        return error.TestExpectedLookup;
    try std.testing.expectEqual(@as(?*const value_mod.Module, foreign), filtered.source_module);
}

test "call_word_module executes its baked target, and a captured lexical binding still outranks it" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const push_baked: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 1 });
        }
    }.f;
    const push_lexical: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 2 });
        }
    }.f;

    const alloc = ctx.arena.allocator();
    const slot = try dict_mod.createDetachedSlot(alloc, "probe", .{
        .name = "probe",
        .action = .{ .native = push_baked },
    });
    const inner = try alloc.alloc(Instruction, 1);
    inner[0] = .{ .op = .{ .call_word_module = slot }, .line = 1 };

    // The scope is captured where the quotation literal is pushed, so the call has to run through
    // a push-then-`call` body rather than a direct execute.
    const outer = try alloc.alloc(Instruction, 2);
    outer[0] = .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = inner } } }, .line = 1 };
    outer[1] = .{ .op = .{ .call_word = "call" }, .line = 1 };

    // With nothing closed over, the baked slot decides the call.
    try ctx.executeQuotation(.{ .instructions = outer });
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).fixnum);

    // A lexical binding live at the push site is rung 1 of the ladder, so it outranks the
    // build-time module resolution the slot carries.
    try ctx.pushLocalFrame();
    defer ctx.popLocalFrame();
    try ctx.defineWord("probe", .{ .name = "probe", .action = .{ .native = push_lexical } });
    try ctx.executeQuotation(.{ .instructions = outer });
    try std.testing.expectEqual(@as(i64, 2), (try ctx.stack.pop()).fixnum);
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

test "backfillCompiledWordId: resolves a compiled word_id from jit_dispatch and writes it back" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // A word whose compiled body was dropped is parsed into the dictionary with an
    // empty body and a null word_id, while its compiled function lives in
    // jit_dispatch. The backfill resolves the id and stamps it onto the slot.
    try ctx.dictionary.put("compiled-word", .{
        .name = "compiled-word",
        .action = .{ .compound = &.{} },
    });
    try std.testing.expectEqual(@as(?u32, null), ctx.dictionary.get("compiled-word").?.word_id);

    const fake_code: *const anyopaque = @ptrCast(&fakeAotCodeMarker);
    const wid = try ctx.jit_dispatch.assignId("compiled-word");
    ctx.jit_dispatch.setCodePtr(wid, fake_code);

    try std.testing.expectEqual(@as(?u32, wid), backfillCompiledWordId(&ctx, "compiled-word"));
    try std.testing.expectEqual(@as(?u32, wid), ctx.dictionary.get("compiled-word").?.word_id);
}

test "backfillCompiledWordId: no live compiled entry returns null" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // A registered-but-uncompiled entry (null code_ptr) is not a live match, so a
    // genuinely empty-bodied no-op word without a compiled function stays put.
    _ = try ctx.jit_dispatch.assignId("pending-word");

    try std.testing.expectEqual(@as(?u32, null), backfillCompiledWordId(&ctx, "pending-word"));
    try std.testing.expectEqual(@as(?u32, null), backfillCompiledWordId(&ctx, "absent-word"));
}

test "executeResolvedWord: a module word with an empty body does not backfill by bare name" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.runtime_image_loaded = true;

    const arena_alloc = ctx.arena.allocator();
    const mod = try arena_alloc.create(value_mod.Module);
    mod.* = .{ .name = "img-mod", .words = .{} };

    // A live entry under the word's bare name. The retired sweep would resolve it
    // and jump to the fake pointer, so surviving the call pins the guard.
    const fake_code: *const anyopaque = @ptrCast(&fakeAotCodeMarker);
    const wid = try ctx.jit_dispatch.assignId("mword");
    ctx.jit_dispatch.setCodePtr(wid, fake_code);

    var def: WordDefinition = .{
        .name = "mword",
        .source_module = mod,
        .action = .{ .compound = &.{} },
    };
    def.exec_flags = computeExecFlags(def);
    try std.testing.expect(def.exec_flags.empty_compound_body);
    try ctx.dictionary.put("mword", def);

    const body = try arena_alloc.alloc(Instruction, 1);
    body[0] = .{ .op = .{ .call_word = "mword" }, .line = 1 };
    try ctx.executeQuotation(.{ .instructions = body });

    // The empty body interpreted as a no-op, and no swept id was written back.
    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
    try std.testing.expectEqual(@as(?u32, null), ctx.dictionary.get("mword").?.word_id);
}

test "moduleScopeWordDef: carries the module word's compiled id" {
    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    const module: value_mod.Module = .{ .name = "m", .words = .{} };
    const def = Context.moduleScopeWordDef("probe", .{ .word_id = 17, .action = .{ .native = noop } }, &module);
    try std.testing.expectEqual(@as(?u32, 17), def.word_id);
}

test "init: the root context owns an empty quotation stamp store" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(usize, 0), ctx.quotation_stamp_store.count());
    try std.testing.expectEqual(
        @as(?*const value_mod.Module, null),
        ctx.quotation_stamp_store.lookup(0x1000),
    );
}

test "initForTask: shares the parent's quotation stamp store" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const module: value_mod.Module = .{ .name = "m", .words = .{} };
    _ = try parent.quotation_stamp_store.stamp(0x1000, &module);

    {
        var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
        defer task_ctx.deinit();

        // A stamp written before the spawn is what a stored quotation executing here needs.
        try std.testing.expectEqual(parent.quotation_stamp_store, task_ctx.quotation_stamp_store);
        try std.testing.expectEqual(
            @as(?*const value_mod.Module, &module),
            task_ctx.quotation_stamp_store.lookup(0x1000),
        );
    }

    // The task aliased the store without retaining, so its teardown left the root's intact.
    try std.testing.expectEqual(
        @as(?*const value_mod.Module, &module),
        parent.quotation_stamp_store.lookup(0x1000),
    );
}

test "initForTask: shares the parent's quotation source store" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    try parent.quotation_source_store.stamp(0x1000, "parent.1z");

    {
        var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
        defer task_ctx.deinit();

        // A body parsed on the parent keeps its own file in the frames a raise here produces.
        try std.testing.expectEqual(parent.quotation_source_store, task_ctx.quotation_source_store);
        try std.testing.expectEqualStrings("parent.1z", task_ctx.quotation_source_store.lookup(0x1000).?);
    }

    // The task aliased the store without retaining, so its teardown left the root's intact.
    try std.testing.expectEqualStrings("parent.1z", parent.quotation_source_store.lookup(0x1000).?);
}

test "init: the root context owns an empty carryable scope gate" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(usize, 0), ctx.carryable_scope_gate.count());
    try std.testing.expect(!ctx.carryable_scope_gate.isMarked(0x1000));
}

test "initForTask: shares the parent's carryable scope gate" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    _ = try parent.carryable_scope_gate.mark(0x1000);

    {
        var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
        defer task_ctx.deinit();

        // A mark written before the spawn is what tells a body entry here to walk the chain.
        try std.testing.expectEqual(parent.carryable_scope_gate, task_ctx.carryable_scope_gate);
        try std.testing.expect(task_ctx.carryable_scope_gate.isMarked(0x1000));

        // A mark written inside the task is visible to the parent, which is what makes the gate
        // exact per body rather than per context.
        _ = try task_ctx.carryable_scope_gate.mark(0x2000);
    }

    // The task aliased the gate without retaining, so its teardown left the root's intact.
    try std.testing.expect(parent.carryable_scope_gate.isMarked(0x1000));
    try std.testing.expect(parent.carryable_scope_gate.isMarked(0x2000));
}

test "initForTask: shares the parent's module-load lock" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();

    try std.testing.expectEqual(parent.load_lock, task_ctx.load_lock);
}

test "initForTask: chains root_context through a nested spawn" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    try std.testing.expectEqual(@as(?*Context, null), parent.root_context);
    try std.testing.expectEqual(&parent, parent.rootContext());

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();
    try std.testing.expectEqual(&parent, task_ctx.rootContext());

    var nested_ctx = try Context.initForTask(std.testing.allocator, &task_ctx, scheduler);
    defer nested_ctx.deinit();
    try std.testing.expectEqual(&parent, nested_ctx.rootContext());
}

test "stateTarget: defaults to self and follows load_target" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();

    try std.testing.expectEqual(&task_ctx, task_ctx.stateTarget());
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(task_ctx.arena)),
        task_ctx.quotationAllocator().ptr,
    );

    task_ctx.load_target = task_ctx.rootContext();
    defer task_ctx.load_target = null;

    try std.testing.expectEqual(&parent, task_ctx.stateTarget());
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(parent.arena)),
        task_ctx.quotationAllocator().ptr,
    );
}

test "retainValueForTeardown: a redirected retain lands on the target's dictionary" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();

    task_ctx.load_target = task_ctx.rootContext();
    defer task_ctx.load_target = null;

    try task_ctx.retainValueForTeardown(.{ .fixnum = 42 });

    try std.testing.expectEqual(@as(usize, 0), task_ctx.dictionary.retained_values.items.len);
    try std.testing.expectEqual(@as(usize, 1), parent.dictionary.retained_values.items.len);
}

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

test "initForTask: gives each task its own profile buffer when profiling is enabled" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    // The parent stands in for the main context: it borrows a profile buffer the test owns.
    var parent_stats: ProfileStats = .{};
    defer parent_stats.deinit(std.testing.allocator);
    parent.profile = &parent_stats;

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();

    const task_profile = task_ctx.profile orelse return error.TestExpectedProfile;
    try std.testing.expect(task_ctx.profile_owned);
    // A fresh buffer, not the parent's.
    try std.testing.expect(task_profile != &parent_stats);

    // Task-body dispatches land in the task's own buffer, where today they drop.
    task_profile.recordWordStart(std.testing.allocator);
    task_profile.recordWordEnd(std.testing.allocator, "+");
    try std.testing.expectEqual(@as(usize, 1), task_profile.samples.items.len);
    try std.testing.expectEqual(@as(usize, 0), parent_stats.samples.items.len);
}

test "initForTask: leaves the task profile null when profiling is disabled" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();

    try std.testing.expectEqual(@as(?*ProfileStats, null), task_ctx.profile);
    try std.testing.expect(!task_ctx.profile_owned);
}

test "initForTask: captures parent transient local frames at spawn" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    // Task-parent semantics: no import frame, so every parent frame is transient and captured into
    // the child as a private, frozen prefix. The clone carries lexical frames because a top-level
    // local word's body resolves sibling locals through the live frame stack, which per-quotation
    // captured scope does not cover.
    try parent.pushLocalFrame();
    try parent.local_frames.items[0].put(std.testing.allocator, "quo-local", .{
        .name = "quo-local",
        .action = .{ .compound = &.{} },
    });

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();

    // The transient frame is cloned into the child, resolvable in the child's own frames without
    // walking the parent.
    try std.testing.expectEqual(@as(usize, 1), task_ctx.local_frames.items.len);
    const found = task_ctx.local_frames.items[0].get("quo-local") orelse return error.TestExpectedLookup;
    try std.testing.expectEqualStrings("quo-local", found.name);
}

test "initForTask: the cloned frame takes its own reference to a frame-owned binding" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    try parent.pushLocalFrame();

    const bytes = try std.testing.allocator.dupe(u8, "computed");
    const str = try value_mod.ownedStringValue(std.testing.allocator, bytes);
    const backing = str.string.backing.?;
    try parent.defineWord("s", .{ .name = "s", .action = .{ .literal = str } });

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    {
        var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
        defer task_ctx.deinit();
        try std.testing.expectEqual(@as(u32, 2), backing.header.refcountValue());
    }

    // The child's teardown drops only what its own clone claimed, so the parent's binding is
    // still readable afterward.
    try std.testing.expectEqual(@as(u32, 1), backing.header.refcountValue());
    const found = parent.lookupWord("s") orelse return error.TestExpectedLookup;
    try std.testing.expectEqualStrings("computed", found.action.literal.string.bytes);
}

test "initForTask: captures only frames above the parent's durable floor" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    // Primary-context semantics: frame 0 is the stable import frame the child reaches live by
    // walking the parent chain, frame 1 is transient and must be captured. Only the transient frame
    // is cloned.
    try parent.pushLocalFrame();
    try parent.local_frames.items[0].put(std.testing.allocator, "stable-w", .{
        .name = "stable-w",
        .action = .{ .compound = &.{} },
    });
    parent.import_frame_index = 0;
    parent.durable_frame_floor = 0;
    try parent.pushLocalFrame();
    try parent.local_frames.items[1].put(std.testing.allocator, "transient-w", .{
        .name = "transient-w",
        .action = .{ .compound = &.{} },
    });

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();

    try std.testing.expectEqual(@as(usize, 1), task_ctx.local_frames.items.len);
    try std.testing.expect(task_ctx.local_frames.items[0].get("transient-w") != null);
    try std.testing.expect(task_ctx.local_frames.items[0].get("stable-w") == null);
}

test "initForTask: an interpreter-free boot clones nothing and reads the entry frame via the ancestor walk" {
    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    // The shape `onez_push_entry_frame` leaves on a no-prelude boot: one durable frame at floor 0
    // holding the entry file's bindings, and nothing above it. The spawn snapshot starts at
    // floor + 1, so there is nothing to clone, and the entry frame stays reachable only through
    // the ancestor walk.
    try parent.pushLocalFrame();
    parent.import_frame_index = 0;
    parent.durable_frame_floor = 0;
    try parent.local_frames.items[0].put(parent.allocator, "entry-word", .{
        .name = "entry-word",
        .action = .{ .native = noop },
    });

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();

    try std.testing.expectEqual(@as(usize, 0), task_ctx.local_frames.items.len);
    try std.testing.expect(task_ctx.lookupWordLocked("entry-word", null) != null);
}

test "initForTask: a prelude boot with the entry frame at floor 1 clones nothing and reads both frames" {
    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    // The shape `onez_push_entry_frame` leaves on a prelude boot: the prelude frame at 0, the
    // entry frame at floor 1, nothing above. Both sit at or below the floor, so the clone is
    // empty and both resolve through the ancestor walk.
    try parent.pushLocalFrame();
    try parent.local_frames.items[0].put(parent.allocator, "prelude-word", .{
        .name = "prelude-word",
        .action = .{ .native = noop },
    });
    try parent.pushLocalFrame();
    parent.import_frame_index = 1;
    parent.durable_frame_floor = 1;
    try parent.local_frames.items[1].put(parent.allocator, "entry-word", .{
        .name = "entry-word",
        .action = .{ .native = noop },
    });

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();

    try std.testing.expectEqual(@as(usize, 0), task_ctx.local_frames.items.len);
    try std.testing.expect(task_ctx.lookupWordLocked("prelude-word", null) != null);
    try std.testing.expect(task_ctx.lookupWordLocked("entry-word", null) != null);
}

test "truncateLocalFrames: pops down to the mark and releases what it pops" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;

    const mark = ctx.local_frames.items.len;

    // Two transient lexical frames above the mark, the shape an error return through nested
    // bracketed splices leaves behind. Only a non-empty one moves the counter.
    try ctx.pushLocalFrame();
    try ctx.defineWord("stray", .{ .name = "stray", .action = .{ .compound = &.{} } });
    try ctx.pushLocalFrame();

    try std.testing.expectEqual(mark + 2, ctx.local_frames.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.nonempty_transient_lexical_frames);

    ctx.truncateLocalFrames(mark);

    try std.testing.expectEqual(mark, ctx.local_frames.items.len);
    try std.testing.expectEqual(mark, ctx.local_frame_kinds.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.nonempty_transient_lexical_frames);
    try std.testing.expect(ctx.lookupWordLocked("stray", null) == null);
}

test "truncateLocalFrames: a mark at or above the current depth changes nothing" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.pushLocalFrame();
    try ctx.pushLocalFrame();

    ctx.truncateLocalFrames(2);
    try std.testing.expectEqual(@as(usize, 2), ctx.local_frames.items.len);

    ctx.truncateLocalFrames(9);
    try std.testing.expectEqual(@as(usize, 2), ctx.local_frames.items.len);
}

test "initForTask: a spawn during a load captures the load frame as a frozen prefix" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    // Mid-load shape: the load moved `import_frame_index` onto its live frame while the floor
    // stayed at the durable scope. A child spawned by the module's top level captures the load
    // frame, so the module's already-defined words resolve from the snapshot.
    try parent.pushLocalFrame();
    try parent.local_frames.items[0].put(std.testing.allocator, "stable-w", .{
        .name = "stable-w",
        .action = .{ .compound = &.{} },
    });
    parent.import_frame_index = 0;
    parent.durable_frame_floor = 0;
    try parent.pushLocalFrame();
    parent.import_frame_index = 1;
    try parent.local_frames.items[1].put(std.testing.allocator, "load-w", .{
        .name = "load-w",
        .action = .{ .compound = &.{} },
    });

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();

    try std.testing.expectEqual(@as(usize, 1), task_ctx.local_frames.items.len);
    try std.testing.expect(task_ctx.local_frames.items[0].get("load-w") != null);
    try std.testing.expect(task_ctx.local_frames.items[0].get("stable-w") == null);
}

test "initForTask: seeds the gate counter from cloned non-empty transient frames" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    // The stable import frame at index 0 is not cloned; only the non-empty transient frame is. The
    // child must start with a counter reflecting that clone, or a quotation the child later pushes
    // that closes over the cloned binding would be wrongly gated off.
    try parent.pushLocalFrame();
    try parent.local_frames.items[0].put(std.testing.allocator, "stable-w", .{
        .name = "stable-w",
        .action = .{ .compound = &.{} },
    });
    parent.import_frame_index = 0;
    parent.durable_frame_floor = 0;
    try parent.pushLocalFrame();
    try parent.local_frames.items[1].put(std.testing.allocator, "transient-w", .{
        .name = "transient-w",
        .action = .{ .compound = &.{} },
    });

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();

    try std.testing.expectEqual(@as(usize, 1), task_ctx.nonempty_transient_lexical_frames);
}

test "computeExecFlags: generic word with empty compound body" {
    const def = WordDefinition{
        .name = "gen-empty",
        .markers = &.{@constCast(&markers_mod.generic_marker)},
        .action = .{ .compound = &.{} },
    };
    const flags = computeExecFlags(def);
    try std.testing.expect(flags.is_generic);
    try std.testing.expect(flags.empty_compound_body);
    try std.testing.expect(flags.skip_type_validation);
    try std.testing.expect(!flags.recursive_non_tco);
    try std.testing.expect(!flags.stack_recursive);
}

test "computeExecFlags: recursive-non-tco plus stack-recursive with non-empty body" {
    const body = [_]Instruction{.{ .op = .{ .call_word = "noop" }, .line = 0 }};
    const def = WordDefinition{
        .name = "rec",
        .markers = &.{
            @constCast(&markers_mod.recursive_non_tco_marker),
            @constCast(&markers_mod.stack_recursive_marker),
        },
        .action = .{ .compound = &body },
    };
    const flags = computeExecFlags(def);
    try std.testing.expect(flags.recursive_non_tco);
    try std.testing.expect(flags.stack_recursive);
    try std.testing.expect(!flags.is_generic);
    try std.testing.expect(!flags.empty_compound_body);
    try std.testing.expect(!flags.skip_type_validation);
}

test "computeExecFlags: plain compound word has no flags set" {
    const body = [_]Instruction{.{ .op = .{ .call_word = "noop" }, .line = 0 }};
    const def = WordDefinition{
        .name = "plain",
        .action = .{ .compound = &body },
    };
    const flags = computeExecFlags(def);
    try std.testing.expect(!flags.is_generic);
    try std.testing.expect(!flags.recursive_non_tco);
    try std.testing.expect(!flags.stack_recursive);
    try std.testing.expect(!flags.empty_compound_body);
    try std.testing.expect(!flags.skip_type_validation);
}

test "computeExecFlags: native word has no flags set" {
    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;
    const def = WordDefinition{
        .name = "nat",
        .action = .{ .native = noop },
    };
    const flags = computeExecFlags(def);
    try std.testing.expect(!flags.is_generic);
    try std.testing.expect(!flags.empty_compound_body);
    try std.testing.expect(!flags.skip_type_validation);
}

test "computeExecFlags: generic word with non-empty body does not skip validation" {
    const body = [_]Instruction{.{ .op = .{ .call_word = "noop" }, .line = 0 }};
    const def = WordDefinition{
        .name = "gen-nonempty",
        .markers = &.{@constCast(&markers_mod.generic_marker)},
        .action = .{ .compound = &body },
    };
    const flags = computeExecFlags(def);
    try std.testing.expect(flags.is_generic);
    try std.testing.expect(!flags.empty_compound_body);
    try std.testing.expect(!flags.skip_type_validation);
}

test "computeExecFlags: input with a quotation effect sets has_param_effects only" {
    const quot_effect = StackEffect{ .inputs = &.{}, .outputs = &.{} };
    const inputs = [_]StackEffectParam{.{ .name = "q", .quotation_effect = &quot_effect }};
    const body = [_]Instruction{.{ .op = .{ .call_word = "noop" }, .line = 0 }};
    const def = WordDefinition{
        .name = "with-quot",
        .stack_effect = &.{ .inputs = &inputs, .outputs = &.{} },
        .action = .{ .compound = &body },
    };
    const flags = computeExecFlags(def);
    try std.testing.expect(flags.has_param_effects);
    try std.testing.expect(!flags.has_type_annotations);
}

test "computeExecFlags: input with a type annotation sets has_type_annotations only" {
    const dummy_tv = value_mod.TypeValue{ .name = "dummy", .descriptor = null };
    const inputs = [_]StackEffectParam{.{ .name = "n", .type_annotation = .{ .type = &dummy_tv } }};
    const body = [_]Instruction{.{ .op = .{ .call_word = "noop" }, .line = 0 }};
    const def = WordDefinition{
        .name = "with-type",
        .stack_effect = &.{ .inputs = &inputs, .outputs = &.{} },
        .action = .{ .compound = &body },
    };
    const flags = computeExecFlags(def);
    try std.testing.expect(flags.has_type_annotations);
    try std.testing.expect(!flags.has_param_effects);
}

test "computeExecFlags: plain untyped inputs set neither validation flag" {
    const inputs = [_]StackEffectParam{ .{ .name = "a" }, .{ .name = "b" } };
    const body = [_]Instruction{.{ .op = .{ .call_word = "noop" }, .line = 0 }};
    const def = WordDefinition{
        .name = "untyped",
        .stack_effect = &.{ .inputs = &inputs, .outputs = &.{} },
        .action = .{ .compound = &body },
    };
    const flags = computeExecFlags(def);
    try std.testing.expect(!flags.has_param_effects);
    try std.testing.expect(!flags.has_type_annotations);
}

test "computeExecFlags: no stack effect sets neither validation flag" {
    const body = [_]Instruction{.{ .op = .{ .call_word = "noop" }, .line = 0 }};
    const def = WordDefinition{
        .name = "no-effect",
        .action = .{ .compound = &body },
    };
    const flags = computeExecFlags(def);
    try std.testing.expect(!flags.has_param_effects);
    try std.testing.expect(!flags.has_type_annotations);
}

test "defineWord: exec_flags populated and recomputed on redefinition" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const body = [_]Instruction{.{ .op = .{ .call_word = "noop" }, .line = 0 }};
    try ctx.defineWord("w", .{
        .name = "w",
        .action = .{ .compound = &body },
    });
    const first = ctx.lookupWordForExecution("w") orelse return error.TestExpectedLookup;
    try std.testing.expect(!first.exec_flags.is_generic);
    try std.testing.expect(!first.exec_flags.skip_type_validation);

    try ctx.defineWord("w", .{
        .name = "w",
        .markers = &.{@constCast(&markers_mod.generic_marker)},
        .action = .{ .compound = &.{} },
    });
    const second = ctx.lookupWordForExecution("w") orelse return error.TestExpectedLookup;
    try std.testing.expect(second.exec_flags.is_generic);
    try std.testing.expect(second.exec_flags.empty_compound_body);
    try std.testing.expect(second.exec_flags.skip_type_validation);
}

test "defineWord: a stamped body's parse file outranks the ambient current_source" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const body = [_]Instruction{.{ .op = .{ .call_word = "noop" }, .line = 0 }};
    ctx.current_source = "mod.1z";
    try ctx.stampQuotationBodySource(&body);

    // A definition made while another word's body executes, e.g. a `private{` helper defined
    // inside the composed quotation the prelude calls, sees that word's file here.
    ctx.current_source = "src/prelude.1z";
    try ctx.defineWord("w", .{
        .name = "w",
        .action = .{ .compound = &body },
    });

    const def = ctx.lookupWordForExecution("w") orelse return error.TestExpectedLookup;
    try std.testing.expectEqualStrings("mod.1z", def.source_file.?);
}

test "defineWord: an unstamped body falls back to current_source" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const body = [_]Instruction{.{ .op = .{ .call_word = "noop" }, .line = 0 }};
    ctx.current_source = "app.1z";
    try ctx.defineWord("w", .{
        .name = "w",
        .action = .{ .compound = &body },
    });

    const def = ctx.lookupWordForExecution("w") orelse return error.TestExpectedLookup;
    try std.testing.expectEqualStrings("app.1z", def.source_file.?);
}

test "stampQuotationBodySource: parse_stamp_source outranks current_source" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // While a parse-time word executes, `current_source` names the word's own file, and the
    // parser's saved invoking file is what the tokens being read belong to.
    const body = [_]Instruction{.{ .op = .{ .call_word = "noop" }, .line = 0 }};
    ctx.current_source = "src/prelude.1z";
    ctx.parse_stamp_source = "mod.1z";
    try ctx.stampQuotationBodySource(&body);

    try std.testing.expectEqualStrings("mod.1z", ctx.quotationBodySource(&body).?);
}

test "wordDefFromModuleWord: synthesized definition carries computed exec_flags" {
    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;
    var module: value_mod.Module = .{ .name = "m", .words = .{} };

    // A generic, empty-bodied module word must skip type validation, matching
    // computeExecFlags rather than the all-false default.
    const gen_def = Context.wordDefFromModuleWord("gen", .{
        .source_module = &module,
        .markers = &.{@constCast(&markers_mod.generic_marker)},
        .action = .{ .compound = &.{} },
    }, &module);
    try std.testing.expect(gen_def.exec_flags.is_generic);
    try std.testing.expect(gen_def.exec_flags.empty_compound_body);
    try std.testing.expect(gen_def.exec_flags.skip_type_validation);

    // A plain native module word has no flags set.
    const nat_def = Context.wordDefFromModuleWord("nat", .{
        .source_module = &module,
        .action = .{ .native = noop },
    }, &module);
    try std.testing.expect(!nat_def.exec_flags.is_generic);
    try std.testing.expect(!nat_def.exec_flags.empty_compound_body);
    try std.testing.expect(!nat_def.exec_flags.skip_type_validation);
}

test "frame-kind tag: pushLocalFrame is lexical, pushModuleDepsFrame is module_deps" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var module: value_mod.Module = .{ .name = "m", .words = .{} };

    try ctx.pushLocalFrame();
    try ctx.pushModuleDepsFrame(&module);
    try ctx.pushLocalFrame();

    try std.testing.expectEqual(@as(usize, 3), ctx.local_frames.items.len);
    try std.testing.expectEqual(@as(usize, 3), ctx.local_frame_kinds.items.len);
    try std.testing.expectEqual(@as(usize, 3), ctx.local_frame_modules.items.len);
    try std.testing.expectEqual(FrameKind.lexical, ctx.local_frame_kinds.items[0]);
    try std.testing.expectEqual(FrameKind.module_deps, ctx.local_frame_kinds.items[1]);
    try std.testing.expectEqual(FrameKind.lexical, ctx.local_frame_kinds.items[2]);

    // Only the module-deps frame records a module; lexical frames record null.
    try std.testing.expect(ctx.local_frame_modules.items[0] == null);
    try std.testing.expectEqual(@as(?*const value_mod.Module, &module), ctx.local_frame_modules.items[1]);
    try std.testing.expect(ctx.local_frame_modules.items[2] == null);

    // The single module-deps frame is counted; the two lexical frames are not.
    try std.testing.expectEqual(@as(usize, 1), ctx.live_module_deps_frames);

    // Popping keeps all three arrays index-parallel.
    ctx.popLocalFrame();
    try std.testing.expectEqual(@as(usize, 2), ctx.local_frames.items.len);
    try std.testing.expectEqual(@as(usize, 2), ctx.local_frame_kinds.items.len);
    try std.testing.expectEqual(@as(usize, 2), ctx.local_frame_modules.items.len);

    // Popping the top lexical frame leaves the module-deps count untouched.
    try std.testing.expectEqual(@as(usize, 1), ctx.live_module_deps_frames);
    ctx.popLocalFrame();
    try std.testing.expectEqual(@as(usize, 0), ctx.live_module_deps_frames);
}

test "cloneWordFrameCapacityMatched: copies every entry and stays a mutable map" {
    const alloc = std.testing.allocator;

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    var src: LocalFrame = .{};
    defer src.deinit(alloc);

    const names = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" };
    for (names, 0..) |n, i| {
        try src.put(alloc, n, .{ .name = n, .dispatch_id = @intCast(i + 1), .action = .{ .native = noop } });
    }

    var dst = try Context.cloneWordFrameCapacityMatched(src, alloc);
    defer dst.deinit(alloc);

    try std.testing.expectEqual(src.count(), dst.count());
    for (names, 0..) |n, i| {
        const d = dst.get(n) orelse return error.MissingKey;
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), d.dispatch_id);
        try std.testing.expectEqualStrings(n, d.name);
    }

    // A put into the clone and a subsequent deinit must not leak or double-free
    // (testing.allocator asserts), proving the copied backing is a valid map.
    try dst.put(alloc, "zeta", .{ .name = "zeta", .action = .{ .native = noop } });
    try std.testing.expectEqual(src.count() + 1, dst.count());
    try std.testing.expect(dst.get("alpha") != null);
}

test "cloneWordFrameCapacityMatched: empty frame clones to empty" {
    const alloc = std.testing.allocator;
    var src: LocalFrame = .{};
    defer src.deinit(alloc);

    var dst = try Context.cloneWordFrameCapacityMatched(src, alloc);
    defer dst.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), dst.count());
}

test "pushModuleDepsFrame: clones the template, word overrides same-named dep" {
    const alloc = std.testing.allocator;
    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    var module: value_mod.Module = .{ .name = "m", .words = .{} };
    defer {
        module.words.deinit(alloc);
        module.deps.deinit(alloc);
        if (module.deps_template) |*t| t.frame.deinit(alloc);
    }

    try module.deps.put(alloc, "shared", .{ .dispatch_id = 10, .action = .{ .native = noop } });
    try module.deps.put(alloc, "dep-only", .{ .dispatch_id = 11, .word_id = 31, .action = .{ .native = noop } });
    try module.words.put(alloc, "shared", .{ .dispatch_id = 20, .action = .{ .native = noop } });
    try module.words.put(alloc, "word-only", .{ .dispatch_id = 21, .word_id = 41, .action = .{ .native = noop } });

    try Context.buildModuleDepsTemplate(&module, alloc);
    try std.testing.expect(module.deps_template != null);

    try ctx.pushModuleDepsFrame(&module);
    defer ctx.popLocalFrame();

    const idx = ctx.local_frames.items.len - 1;
    try std.testing.expectEqual(FrameKind.module_deps, ctx.local_frame_kinds.items[idx]);

    const frame = ctx.local_frames.items[idx];
    try std.testing.expectEqual(@as(u32, 20), (frame.get("shared") orelse return error.Missing).dispatch_id);
    try std.testing.expectEqual(@as(u32, 11), (frame.get("dep-only") orelse return error.Missing).dispatch_id);
    try std.testing.expectEqual(@as(u32, 21), (frame.get("word-only") orelse return error.Missing).dispatch_id);

    // The frame entries carry the module word's compiled id, so a frame hit
    // dispatches compiled.
    try std.testing.expectEqual(@as(?u32, 31), (frame.get("dep-only") orelse return error.Missing).word_id);
    try std.testing.expectEqual(@as(?u32, 41), (frame.get("word-only") orelse return error.Missing).word_id);
    try std.testing.expectEqual(@as(?u32, null), (frame.get("shared") orelse return error.Missing).word_id);
}

test "defineWordLocked: a definition skips a module-deps frame the active visibility rejects" {
    const alloc = std.testing.allocator;
    var ctx = Context.init(alloc);
    defer ctx.deinit();

    var module: value_mod.Module = .{ .name = "m", .words = .{} };
    defer {
        module.words.deinit(alloc);
        module.deps.deinit(alloc);
        if (module.deps_template) |*t| t.frame.deinit(alloc);
    }

    try ctx.pushLocalFrame();
    try ctx.pushModuleDepsFrame(&module);
    defer {
        ctx.popLocalFrame();
        ctx.popLocalFrame();
    }

    // A body whose visibility filter rejects m's frame defines below it, into the lexical
    // frame, so its own filtered lookup can resolve the binding it just made.
    ctx.active_deps_vis = .{ .deps_modules = &.{}, .defining_module = null };
    try ctx.defineWord("local-binding", .{ .name = "local-binding", .action = .{ .literal = .{ .fixnum = 7 } } });

    try std.testing.expect(ctx.local_frames.items[1].get("local-binding") == null);
    try std.testing.expect(ctx.local_frames.items[0].get("local-binding") != null);
    try std.testing.expect(ctx.lookupWordFiltered("local-binding", ctx.active_deps_vis) != null);

    // A body whose filter admits m keeps defining into the top deps frame, preserving the
    // nested-definition lifetime for module-word bodies.
    ctx.active_deps_vis = .{ .deps_modules = &.{}, .defining_module = &module };
    try ctx.defineWord("deps-binding", .{ .name = "deps-binding", .action = .{ .literal = .{ .fixnum = 8 } } });
    try std.testing.expect(ctx.local_frames.items[1].get("deps-binding") != null);

    ctx.active_deps_vis = null;
}

test "defineWordLocked: const guard skips module-deps frames but not lexical frames" {
    const alloc = std.testing.allocator;
    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;
    const const_markers: []const *value_mod.Marker = &.{@constCast(&markers_mod.const_marker)};

    var module: value_mod.Module = .{ .name = "m", .words = .{} };
    defer {
        module.words.deinit(alloc);
        module.deps.deinit(alloc);
        if (module.deps_template) |*t| t.frame.deinit(alloc);
    }
    try module.deps.put(alloc, "shielded", .{ .markers = const_markers, .action = .{ .native = noop } });

    // A const word visible only through a foreign module's live deps frame must not block a
    // definition, matching a check-mode load running under a module word.
    try ctx.pushModuleDepsFrame(&module);
    try ctx.pushLocalFrame();
    defer {
        ctx.popLocalFrame();
        ctx.popLocalFrame();
    }
    try ctx.defineWord("shielded", .{ .name = "shielded", .action = .{ .literal = .{ .fixnum = 7 } } });

    try ctx.local_frames.items[ctx.local_frames.items.len - 1].put(alloc, "blocking", .{
        .name = "blocking",
        .markers = const_markers,
        .action = .{ .native = noop },
    });
    try std.testing.expectError(
        error.CannotRedefineConst,
        ctx.defineWord("blocking", .{ .name = "blocking", .action = .{ .literal = .{ .fixnum = 8 } } }),
    );
}

test "captureQuotationScope: snapshots a lexical local, skips a module-deps frame" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    // Frame 0 is the durable import frame; captures start above it.
    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;

    // A module-deps frame carrying a `shadow` word that must NOT be captured.
    var module: value_mod.Module = .{ .name = "m", .words = .{} };
    try module.words.put(std.testing.allocator, "shadow", .{ .action = .{ .native = noop } });
    defer module.words.deinit(std.testing.allocator);
    try ctx.pushModuleDepsFrame(&module);

    // A genuine lexical frame binding `shadow` to a distinct local definition.
    try ctx.pushLocalFrame();
    try ctx.local_frames.items[ctx.local_frames.items.len - 1].put(ctx.allocator, "shadow", .{
        .name = "shadow",
        .source_file = "local-site",
        .action = .{ .compound = &.{} },
    });
    // The direct put bypasses `defineWordLocked`, so the gate counter is set by hand here.
    ctx.nonempty_transient_lexical_frames = 1;

    const body = [_]Instruction{.{ .op = .{ .call_word = "shadow" }, .line = 0 }};
    const scope = (try ctx.captureQuotationScope(&body)) orelse return error.TestExpectedCapture;
    // Only the lexical frame is snapshotted; the module-deps frame is skipped.
    try std.testing.expectEqual(@as(usize, 1), scope.lexical_frames.len);
    const resolved = Context.lookupInCapturedScope(scope, "shadow") orelse return error.TestExpectedResolution;
    try std.testing.expectEqualStrings("local-site", resolved.source_file.?);

    // The ambient module-deps frame is recorded in deps_modules, alongside the lexical snapshot.
    try std.testing.expectEqual(@as(usize, 1), scope.deps_modules.len);
    try std.testing.expectEqual(@as(*const value_mod.Module, &module), scope.deps_modules[0]);
}

test "captureQuotationScope: records ambient module-deps modules without promoting a module-less quotation" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;

    var module: value_mod.Module = .{ .name = "m", .words = .{} };
    try module.words.put(std.testing.allocator, "foo", .{ .action = .{ .native = noop } });
    defer module.words.deinit(std.testing.allocator);
    try ctx.pushModuleDepsFrame(&module);

    // A body with no live lexical binding to close over: the deps set is still recorded, but the
    // quotation is not promoted, so the return is null.
    const body = [_]Instruction{.{ .op = .{ .call_word = "foo" }, .line = 0 }};
    try std.testing.expect((try ctx.captureQuotationScope(&body)) == null);

    const info = ctx.quotation_scope_info.get(@intFromPtr(&body)) orelse return error.TestExpectedEntry;
    const entry = info.scope orelse return error.TestExpectedScope;
    try std.testing.expectEqual(@as(usize, 0), entry.lexical_frames.len);
    try std.testing.expectEqual(@as(usize, 1), entry.deps_modules.len);
    try std.testing.expectEqual(@as(*const value_mod.Module, &module), entry.deps_modules[0]);
}

test "captureQuotationScope: equality-skip leaves an unchanged deps-only entry in place" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;

    var module: value_mod.Module = .{ .name = "m", .words = .{} };
    try module.words.put(std.testing.allocator, "foo", .{ .action = .{ .native = noop } });
    defer module.words.deinit(std.testing.allocator);
    try ctx.pushModuleDepsFrame(&module);

    const body = [_]Instruction{.{ .op = .{ .call_word = "foo" }, .line = 0 }};
    try std.testing.expect((try ctx.captureQuotationScope(&body)) == null);
    const first = (ctx.quotation_scope_info.get(@intFromPtr(&body)) orelse return error.TestExpectedEntry).scope;

    // Re-pushing the same body against the same ambient deps must not supersede the entry: the
    // stored pointer is identical, so no fresh scope was allocated.
    try std.testing.expect((try ctx.captureQuotationScope(&body)) == null);
    const second = (ctx.quotation_scope_info.get(@intFromPtr(&body)) orelse return error.TestExpectedEntry).scope;
    try std.testing.expectEqual(first, second);
}

test "captureQuotationScope: no live module-deps frame and no local records nothing" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;

    // Neither a live `.module_deps` frame nor a captured local: the push must stay on the fast path,
    // recording no side-map entry, so the common hot-loop case pays no per-push map cost.
    try std.testing.expectEqual(@as(usize, 0), ctx.live_module_deps_frames);
    const body = [_]Instruction{.{ .op = .{ .call_word = "foo" }, .line = 0 }};
    try std.testing.expect((try ctx.captureQuotationScope(&body)) == null);
    try std.testing.expectEqual(@as(usize, 0), ctx.quotation_scope_info.count());
}

test "lookupWordLocked: visibility filter admits or skips a module-deps frame by module" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    // The durable import frame holds one binding of `shadowed`; a foreign module's deps frame,
    // pushed on top, holds a different binding of the same name.
    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    try ctx.local_frames.items[0].put(ctx.allocator, "shadowed", .{
        .name = "shadowed",
        .source_file = "durable",
        .action = .{ .native = noop },
    });

    var module: value_mod.Module = .{ .name = "m", .words = .{} };
    try module.words.put(std.testing.allocator, "shadowed", .{ .action = .{ .native = noop } });
    defer module.words.deinit(std.testing.allocator);
    try ctx.pushModuleDepsFrame(&module);

    // Unfiltered: the topmost (module-deps) frame's binding wins.
    const unfiltered = ctx.lookupWordLocked("shadowed", null) orelse return error.TestExpectedResolution;
    try std.testing.expectEqual(@as(?*const value_mod.Module, &module), unfiltered.source_module);

    // Admitted by defining-module match: the module frame is still visible.
    const by_defining = ctx.lookupWordLocked("shadowed", .{ .deps_modules = &.{}, .defining_module = &module }) orelse return error.TestExpectedResolution;
    try std.testing.expectEqual(@as(?*const value_mod.Module, &module), by_defining.source_module);

    // Admitted by deps-set membership: likewise visible.
    const deps = [_]*const value_mod.Module{&module};
    const by_deps = ctx.lookupWordLocked("shadowed", .{ .deps_modules = &deps, .defining_module = null }) orelse return error.TestExpectedResolution;
    try std.testing.expectEqual(@as(?*const value_mod.Module, &module), by_deps.source_module);

    // Neither: the module frame is skipped, so resolution falls through to the durable binding.
    const rejected = ctx.lookupWordLocked("shadowed", .{ .deps_modules = &.{}, .defining_module = null }) orelse return error.TestExpectedResolution;
    try std.testing.expectEqualStrings("durable", rejected.source_file.?);
}

test "lookupWordForExecutionOwnScope: words beat deps, defining module beats ambient deps" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    // The durable import frame binds `shared` and `frame-only`; no module frame is live, so any
    // module-scope hit below comes from the probe alone.
    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    try ctx.local_frames.items[0].put(ctx.allocator, "shared", .{
        .name = "shared",
        .source_file = "durable",
        .action = .{ .native = noop },
    });
    try ctx.local_frames.items[0].put(ctx.allocator, "frame-only", .{
        .name = "frame-only",
        .source_file = "durable",
        .action = .{ .native = noop },
    });

    var mod_a: value_mod.Module = .{ .name = "a", .words = .{} };
    defer {
        mod_a.words.deinit(std.testing.allocator);
        mod_a.deps.deinit(std.testing.allocator);
    }
    try mod_a.words.put(std.testing.allocator, "shared", .{ .dispatch_id = 20, .action = .{ .native = noop } });
    try mod_a.deps.put(std.testing.allocator, "shared", .{ .dispatch_id = 10, .action = .{ .native = noop } });
    try mod_a.deps.put(std.testing.allocator, "dep-only", .{ .dispatch_id = 11, .action = .{ .native = noop } });

    var mod_b: value_mod.Module = .{ .name = "b", .words = .{} };
    defer {
        mod_b.words.deinit(std.testing.allocator);
        mod_b.deps.deinit(std.testing.allocator);
    }
    try mod_b.words.put(std.testing.allocator, "shared", .{ .dispatch_id = 30, .action = .{ .native = noop } });
    try mod_b.words.put(std.testing.allocator, "b-only", .{ .dispatch_id = 31, .action = .{ .native = noop } });
    try mod_b.deps.put(std.testing.allocator, "b-dep-only", .{ .dispatch_id = 32, .action = .{ .native = noop } });

    const ambient = [_]*const value_mod.Module{&mod_b};

    // The defining module's `words` wins over its own `deps`, every ambient module, and the
    // durable frame; the synthesized definition matches what the module's deps frame would hold.
    const shared = ctx.lookupWordForExecutionOwnScope("shared", null, &mod_a, &ambient) orelse return error.TestExpectedResolution;
    try std.testing.expectEqual(@as(u32, 20), shared.dispatch_id);
    try std.testing.expectEqual(@as(?*const value_mod.Module, &mod_a), shared.source_module);
    try std.testing.expectEqual(@as(?[]const u8, null), shared.source_file);

    // The defining module's `deps` is probed when `words` misses.
    const dep_only = ctx.lookupWordForExecutionOwnScope("dep-only", null, &mod_a, &ambient) orelse return error.TestExpectedResolution;
    try std.testing.expectEqual(@as(u32, 11), dep_only.dispatch_id);

    // With no defining module, an ambient-deps module's binding still outranks the durable frame.
    const ambient_shared = ctx.lookupWordForExecutionOwnScope("shared", null, null, &ambient) orelse return error.TestExpectedResolution;
    try std.testing.expectEqual(@as(u32, 30), ambient_shared.dispatch_id);

    // An ambient module is reached for names the defining module lacks, its `deps` included.
    const b_only = ctx.lookupWordForExecutionOwnScope("b-only", null, &mod_a, &ambient) orelse return error.TestExpectedResolution;
    try std.testing.expectEqual(@as(u32, 31), b_only.dispatch_id);
    const b_dep_only = ctx.lookupWordForExecutionOwnScope("b-dep-only", null, &mod_a, &ambient) orelse return error.TestExpectedResolution;
    try std.testing.expectEqual(@as(u32, 32), b_dep_only.dispatch_id);

    // A probe miss falls through to the ordinary ladder.
    const frame_only = ctx.lookupWordForExecutionOwnScope("frame-only", null, null, &.{}) orelse return error.TestExpectedResolution;
    try std.testing.expectEqualStrings("durable", frame_only.source_file.?);
}

test "executeInstructions: a stamped body resolves its own module ahead of the durable frame" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const push_durable: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 1 });
        }
    }.f;
    const push_module: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 2 });
        }
    }.f;

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    try ctx.local_frames.items[0].put(ctx.allocator, "probe-word", .{
        .name = "probe-word",
        .action = .{ .native = push_durable },
    });

    const arena_alloc = ctx.arena.allocator();
    const module = try arena_alloc.create(value_mod.Module);
    module.* = .{ .name = "m", .words = .{} };
    try module.words.put(arena_alloc, "probe-word", .{ .action = .{ .native = push_module } });

    // Stamped before it is reachable, matching every production stamp site, the body resolves
    // the module's binding ahead of the durable frame.
    const instrs = try arena_alloc.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .call_word = "probe-word" }, .line = 1 };
    _ = try ctx.quotation_stamp_store.stamp(@intFromPtr(instrs.ptr), module);
    try ctx.executeQuotation(.{ .instructions = instrs });
    try std.testing.expectEqual(@as(i64, 2), (try ctx.stack.pop()).fixnum);

    // The body-entry fill cached the store hit into the per-context map.
    const info = ctx.quotation_scope_info.get(@intFromPtr(instrs.ptr)) orelse return error.TestExpectedEntry;
    try std.testing.expectEqual(@as(?*const value_mod.Module, module), info.defining_module);

    // An unstamped body keeps resolving the durable frame's binding.
    const bare = try arena_alloc.alloc(Instruction, 1);
    bare[0] = .{ .op = .{ .call_word = "probe-word" }, .line = 1 };
    try ctx.executeQuotation(.{ .instructions = bare });
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).fixnum);
}

test "executeInstructions: a store miss is cached, so a late stamp is not observed" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const push_durable: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 1 });
        }
    }.f;
    const push_module: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 2 });
        }
    }.f;

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    try ctx.local_frames.items[0].put(ctx.allocator, "probe-word", .{
        .name = "probe-word",
        .action = .{ .native = push_durable },
    });

    const arena_alloc = ctx.arena.allocator();
    const module = try arena_alloc.create(value_mod.Module);
    module.* = .{ .name = "m", .words = .{} };
    try module.words.put(arena_alloc, "probe-word", .{ .action = .{ .native = push_module } });

    const instrs = try arena_alloc.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .call_word = "probe-word" }, .line = 1 };

    // The first execution caches the store miss as a null module half.
    try ctx.executeQuotation(.{ .instructions = instrs });
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).fixnum);
    const info = ctx.quotation_scope_info.get(@intFromPtr(instrs.ptr)) orelse return error.TestExpectedEntry;
    try std.testing.expectEqual(@as(?*const value_mod.Module, null), info.defining_module);

    // A stamp arriving only now violates stamped-before-reachable, which production sites never
    // do. The cached null stays authoritative: no store re-probe, the durable binding still wins.
    _ = try ctx.quotation_stamp_store.stamp(@intFromPtr(instrs.ptr), module);
    try ctx.executeQuotation(.{ .instructions = instrs });
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).fixnum);
}

test "executeInstructions: the fill skips word bodies and empty bodies" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var module: value_mod.Module = .{ .name = "m", .words = .{} };

    // A word body arrives with `body_module` threaded, so its stamp would go unread: no entry.
    const arena_alloc = ctx.arena.allocator();
    const instrs = try arena_alloc.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = 42 } }, .line = 1 };
    try ctx.executeInstructions(instrs, null, &module, null);
    try std.testing.expectEqual(@as(i64, 42), (try ctx.stack.pop()).fixnum);
    try std.testing.expectEqual(@as(usize, 0), ctx.quotation_scope_info.count());

    // Empty bodies share a sentinel pointer and are never stamped: no entry either.
    const empty: []const Instruction = &.{};
    try ctx.executeInstructions(empty, null, null, null);
    try std.testing.expectEqual(@as(usize, 0), ctx.quotation_scope_info.count());
}

/// Build a closure that owns a one-instruction body calling `probe-word`, the shape `curry` and
/// `compose` produce. The caller releases it.
fn closureOwnedProbeBody(ctx: *Context, module: ?*const value_mod.Module, scope: ?*const CapturedScope) !*value_mod.Closure {
    const body = try ctx.allocator.alloc(Instruction, 1);
    body[0] = .{ .op = .{ .call_word = "probe-word" }, .line = 1 };
    return value_mod.Closure.create(ctx.allocator, .{
        .instructions = body,
        .segments = &.{},
        .captured_scope = scope,
        .defining_module = module,
        .header = undefined,
        .owns_body = true,
        .owns_scope = scope != null,
    });
}

/// A durable-frame `probe-word` pushing 1 and a module one pushing 2, so which of the two a body
/// resolved is readable off the stack. Returns the module.
fn installProbeWordRivals(ctx: *Context) !*value_mod.Module {
    const push_durable: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 1 });
        }
    }.f;
    const push_module: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 2 });
        }
    }.f;

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    try ctx.local_frames.items[0].put(ctx.allocator, "probe-word", .{
        .name = "probe-word",
        .action = .{ .native = push_durable },
    });

    const arena_alloc = ctx.arena.allocator();
    const module = try arena_alloc.create(value_mod.Module);
    module.* = .{ .name = "m", .words = .{} };
    try module.words.put(arena_alloc, "probe-word", .{ .action = .{ .native = push_module } });
    return module;
}

test "executeInstructions: a closure-owned body reads its defining module off the carrier" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const module = try installProbeWordRivals(&ctx);
    const cl = try closureOwnedProbeBody(&ctx, module, null);
    defer container_backing.releaseValue(.{ .closure = cl });

    // A map entry for the same key claims the body has no module. The carrier outranks it, so the
    // entry the leak used to leave behind can no longer answer for a body it does not describe.
    try ctx.quotation_scope_info.put(ctx.allocator, @intFromPtr(cl.instructions.ptr), .{});

    try ctx.executeQuotationWithOwner(cl.asQuotation(), cl);
    try std.testing.expectEqual(@as(i64, 2), (try ctx.stack.pop()).fixnum);
}

test "executeInstructions: the carrier is ignored for a body it does not name" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const module = try installProbeWordRivals(&ctx);
    const cl = try closureOwnedProbeBody(&ctx, module, null);
    defer container_backing.releaseValue(.{ .closure = cl });

    // A different body threaded with the same carrier: a splice, a tail call into another word, or
    // a caller passing a stale value. It must resolve as itself, not as the closure.
    const other = try ctx.arena.allocator().alloc(Instruction, 1);
    other[0] = .{ .op = .{ .call_word = "probe-word" }, .line = 1 };

    try ctx.executeQuotationWithOwner(.{ .instructions = other }, cl);
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).fixnum);
}

test "executeInstructions: a push-time promotion keeps the map path" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const module = try installProbeWordRivals(&ctx);

    // A promotion aliases the module-owned literal rather than allocating, so its body address is
    // process-lifetime and the map is still the right home for it.
    const body = try ctx.arena.allocator().alloc(Instruction, 1);
    body[0] = .{ .op = .{ .call_word = "probe-word" }, .line = 1 };
    const cl = try value_mod.Closure.create(ctx.allocator, .{
        .instructions = body,
        .segments = &.{},
        .header = undefined,
    });
    defer container_backing.releaseValue(.{ .closure = cl });

    try ctx.quotation_scope_info.put(ctx.allocator, @intFromPtr(body.ptr), .{ .defining_module = module });

    try ctx.executeQuotationWithOwner(cl.asQuotation(), cl);
    try std.testing.expectEqual(@as(i64, 2), (try ctx.stack.pop()).fixnum);
}

test "executeInstructions: a tail call out of a closure-owned body resolves as the callee" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const module = try installProbeWordRivals(&ctx);

    const callee_body = try ctx.arena.allocator().alloc(Instruction, 1);
    callee_body[0] = .{ .op = .{ .call_word = "probe-word" }, .line = 1 };
    try ctx.local_frames.items[0].put(ctx.allocator, "callee", .{
        .name = "callee",
        .action = .{ .compound = callee_body },
    });

    const body = try ctx.allocator.alloc(Instruction, 1);
    body[0] = .{ .op = .{ .call_word = "callee" }, .line = 1 };
    const cl = try value_mod.Closure.create(ctx.allocator, .{
        .instructions = body,
        .segments = &.{},
        .defining_module = module,
        .header = undefined,
        .owns_body = true,
    });
    defer container_backing.releaseValue(.{ .closure = cl });

    // The call is the body's last instruction, so the TCO loop runs the callee's own body on its
    // next turn with the carrier still in hand. The callee is module-less, so it must reach the
    // durable frame rather than borrowing the closure's module.
    try ctx.executeQuotationWithOwner(cl.asQuotation(), cl);
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).fixnum);
}

test "executeInstructions: a closure-owned body with no carried module falls back to the stamp store" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const module = try installProbeWordRivals(&ctx);
    const cl = try closureOwnedProbeBody(&ctx, null, null);
    defer container_backing.releaseValue(.{ .closure = cl });

    // `;` turns a closure into a compound word over its own body, which module finalization then
    // stamps. The value never learns of that stamp, so the store keeps the last word.
    _ = try ctx.quotation_stamp_store.stamp(@intFromPtr(cl.instructions.ptr), module);

    try ctx.executeQuotationWithOwner(cl.asQuotation(), cl);
    try std.testing.expectEqual(@as(i64, 2), (try ctx.stack.pop()).fixnum);
}

test "executeInstructions: a closure-owned body reads its captured scope off the carrier" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const module = try installProbeWordRivals(&ctx);

    const push_scope: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 3 });
        }
    }.f;
    var frame: LocalFrame = .{};
    try frame.put(ctx.allocator, "probe-word", .{ .name = "probe-word", .action = .{ .native = push_scope } });
    const frames = try ctx.allocator.alloc(LocalFrame, 1);
    frames[0] = frame;
    const scope = try ctx.allocator.create(CapturedScope);
    scope.* = .{ .lexical_frames = frames, .allocator = ctx.allocator };

    const cl = try closureOwnedProbeBody(&ctx, module, scope);
    defer container_backing.releaseValue(.{ .closure = cl });

    // The captured scope is consulted ahead of the defining module, and the map holds nothing for
    // this body, so the binding can only have come off the value.
    try ctx.executeQuotationWithOwner(cl.asQuotation(), cl);
    try std.testing.expectEqual(@as(i64, 3), (try ctx.stack.pop()).fixnum);
    try std.testing.expectEqual(@as(usize, 0), ctx.quotation_scope_info.count());

    // The closure holds the only reference. Body entry takes none of its own, because the caller's
    // hold on the closure is what keeps the scope alive for the call.
    try std.testing.expectEqual(@as(u32, 1), scope.refcountValue());
}

test "executeInstructions: a stored quotation resolves its stamp in a child task" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const push_durable: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 1 });
        }
    }.f;
    const push_module: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 2 });
        }
    }.f;

    // A same-named durable binding in the parent's import frame is what the child would silently
    // resolve if the stamp were unreachable there -- the shadowing half of the bug, not just
    // unknown-word.
    try parent.pushLocalFrame();
    parent.import_frame_index = 0;
    parent.durable_frame_floor = 0;
    try parent.local_frames.items[0].put(parent.allocator, "probe-word", .{
        .name = "probe-word",
        .action = .{ .native = push_durable },
    });

    const arena_alloc = parent.arena.allocator();
    const module = try arena_alloc.create(value_mod.Module);
    module.* = .{ .name = "m", .words = .{} };
    try module.words.put(arena_alloc, "probe-word", .{ .action = .{ .native = push_module } });

    const instrs = try arena_alloc.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .call_word = "probe-word" }, .line = 1 };
    _ = try parent.quotation_stamp_store.stamp(@intFromPtr(instrs.ptr), module);

    // The child's own map starts empty; the fill reaches the stamp through the shared store.
    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();
    try task_ctx.executeQuotation(.{ .instructions = instrs });
    try std.testing.expectEqual(@as(i64, 2), (try task_ctx.stack.pop()).fixnum);
}

/// Install a carryable scope into `ctx`'s map the way a production writer does: mark the gate,
/// then publish the entry.
///
/// A test that hand-builds an ancestor entry bypasses `captureQuotationScope`, which is what marks
/// in production, and an unmarked entry is a state the gate's invariant forbids.
fn putCarryableScopeForTest(ctx: *Context, key: usize, scope: *CapturedScope) !void {
    _ = try ctx.carryable_scope_gate.mark(key);
    try ctx.quotation_scope_info.put(ctx.allocator, key, .{ .scope = scope });
}

test "executeInstructions: a stored quotation resolves a parent-captured lexical binding in a child task" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const push_durable: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 1 });
        }
    }.f;
    const push_captured: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 2 });
        }
    }.f;
    const push_module: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 3 });
        }
    }.f;

    // A same-named durable binding is what the child would resolve if the parent-recorded scope
    // were unreachable there -- the shadowing half of the gap, not just unknown-word.
    try parent.pushLocalFrame();
    parent.import_frame_index = 0;
    parent.durable_frame_floor = 0;
    try parent.local_frames.items[0].put(parent.allocator, "probe-word", .{
        .name = "probe-word",
        .action = .{ .native = push_durable },
    });

    const arena_alloc = parent.arena.allocator();
    const instrs = try arena_alloc.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .call_word = "probe-word" }, .line = 1 };

    // The parent's map holds the body's captured scope; no live frame carries the binding, so an
    // `initForTask` frame clone cannot mask the walk.
    var frame: LocalFrame = .{};
    try frame.put(parent.allocator, "probe-word", .{ .name = "probe-word", .action = .{ .native = push_captured } });
    const frames = try parent.allocator.alloc(LocalFrame, 1);
    frames[0] = frame;
    const parent_scope = try parent.allocator.create(CapturedScope);
    parent_scope.* = .{ .lexical_frames = frames, .allocator = parent.allocator };
    try putCarryableScopeForTest(&parent, @intFromPtr(instrs.ptr), parent_scope);

    const module = try arena_alloc.create(value_mod.Module);
    module.* = .{ .name = "m", .words = .{} };
    try module.words.put(arena_alloc, "probe-word", .{ .action = .{ .native = push_module } });
    _ = try parent.quotation_stamp_store.stamp(@intFromPtr(instrs.ptr), module);

    // The child's fill walks to the parent's entry; the captured binding outranks both the durable
    // one and the stamped module's.
    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();
    try task_ctx.executeQuotation(.{ .instructions = instrs });
    try std.testing.expectEqual(@as(i64, 2), (try task_ctx.stack.pop()).fixnum);

    // Both halves land in one entry, and the scope is an independent copy, not the parent's.
    const info = task_ctx.quotation_scope_info.get(@intFromPtr(instrs.ptr)) orelse return error.TestExpectedEntry;
    try std.testing.expectEqual(@as(?*const value_mod.Module, module), info.defining_module);
    const inherited = info.scope orelse return error.TestExpectedScope;
    try std.testing.expect(inherited != parent_scope);
}

test "executeInstructions: the inherited scope copy survives the ancestor's entry being superseded" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const push_first: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 2 });
        }
    }.f;
    const push_second: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 3 });
        }
    }.f;

    try parent.pushLocalFrame();
    parent.import_frame_index = 0;
    parent.durable_frame_floor = 0;

    const arena_alloc = parent.arena.allocator();
    const instrs = try arena_alloc.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .call_word = "probe-word" }, .line = 1 };

    const makeScope = struct {
        fn f(ctx: *Context, action: dict_mod.NativeFn) !*CapturedScope {
            var frame: LocalFrame = .{};
            try frame.put(ctx.allocator, "probe-word", .{ .name = "probe-word", .action = .{ .native = action } });
            const frames = try ctx.allocator.alloc(LocalFrame, 1);
            frames[0] = frame;
            const scope = try ctx.allocator.create(CapturedScope);
            scope.* = .{ .lexical_frames = frames, .allocator = ctx.allocator };
            return scope;
        }
    }.f;

    const first = try makeScope(&parent, push_first);
    try putCarryableScopeForTest(&parent, @intFromPtr(instrs.ptr), first);

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();
    try task_ctx.executeQuotation(.{ .instructions = instrs });
    try std.testing.expectEqual(@as(i64, 2), (try task_ctx.stack.pop()).fixnum);

    // Superseding the parent's entry frees the original scope, since only the parent's map owned
    // it. The child's cached copy is a snapshot at first execution: still valid, and the newer
    // capture is deliberately not observed.
    const entry = parent.quotation_scope_info.getPtr(@intFromPtr(instrs.ptr)).?;
    entry.scope.?.release();
    entry.scope = try makeScope(&parent, push_second);

    try task_ctx.executeQuotation(.{ .instructions = instrs });
    try std.testing.expectEqual(@as(i64, 2), (try task_ctx.stack.pop()).fixnum);
}

test "executeInstructions: a deps-only ancestor entry is not carried by the fill" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const push_durable: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 1 });
        }
    }.f;

    try parent.pushLocalFrame();
    parent.import_frame_index = 0;
    parent.durable_frame_floor = 0;
    try parent.local_frames.items[0].put(parent.allocator, "probe-word", .{
        .name = "probe-word",
        .action = .{ .native = push_durable },
    });

    const arena_alloc = parent.arena.allocator();
    const instrs = try arena_alloc.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .call_word = "probe-word" }, .line = 1 };

    const dep_module = try arena_alloc.create(value_mod.Module);
    dep_module.* = .{ .name = "dep", .words = .{} };

    // An entry with deps modules but no lexical frames carries nothing the walk considers
    // carryable, mirroring `findCapturedScopeForBody`'s rule for `curry`/`compose`.
    const frames = try parent.allocator.alloc(LocalFrame, 0);
    const deps = try parent.allocator.dupe(*const value_mod.Module, &.{dep_module});
    const parent_scope = try parent.allocator.create(CapturedScope);
    parent_scope.* = .{ .lexical_frames = frames, .deps_modules = deps, .allocator = parent.allocator };
    try parent.quotation_scope_info.put(parent.allocator, @intFromPtr(instrs.ptr), .{ .scope = parent_scope });

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();
    try task_ctx.executeQuotation(.{ .instructions = instrs });
    try std.testing.expectEqual(@as(i64, 1), (try task_ctx.stack.pop()).fixnum);

    const info = task_ctx.quotation_scope_info.get(@intFromPtr(instrs.ptr)) orelse return error.TestExpectedEntry;
    try std.testing.expectEqual(@as(?*CapturedScope, null), info.scope);
}

test "executeInstructions: a walk miss caches a null scope, so a late ancestor capture is not observed" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const push_durable: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 1 });
        }
    }.f;
    const push_captured: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 2 });
        }
    }.f;

    try parent.pushLocalFrame();
    parent.import_frame_index = 0;
    parent.durable_frame_floor = 0;
    try parent.local_frames.items[0].put(parent.allocator, "probe-word", .{
        .name = "probe-word",
        .action = .{ .native = push_durable },
    });

    const arena_alloc = parent.arena.allocator();
    const instrs = try arena_alloc.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .call_word = "probe-word" }, .line = 1 };

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();
    try task_ctx.executeQuotation(.{ .instructions = instrs });
    try std.testing.expectEqual(@as(i64, 1), (try task_ctx.stack.pop()).fixnum);

    // A capture arriving only after the child's first execution mirrors the late-stamp shape: the
    // child's entry already caches the walk's null, and a map hit is final.
    var frame: LocalFrame = .{};
    try frame.put(parent.allocator, "probe-word", .{ .name = "probe-word", .action = .{ .native = push_captured } });
    const frames = try parent.allocator.alloc(LocalFrame, 1);
    frames[0] = frame;
    const parent_scope = try parent.allocator.create(CapturedScope);
    parent_scope.* = .{ .lexical_frames = frames, .allocator = parent.allocator };
    try parent.quotation_scope_info.put(parent.allocator, @intFromPtr(instrs.ptr), .{ .scope = parent_scope });

    try task_ctx.executeQuotation(.{ .instructions = instrs });
    try std.testing.expectEqual(@as(i64, 1), (try task_ctx.stack.pop()).fixnum);
}

test "captureQuotationScope: a fresh entry's module half is filled from the stamp store" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;

    var dep_module: value_mod.Module = .{ .name = "dep", .words = .{} };
    try dep_module.words.put(std.testing.allocator, "foo", .{ .action = .{ .native = noop } });
    defer dep_module.words.deinit(std.testing.allocator);
    try ctx.pushModuleDepsFrame(&dep_module);

    var def_module: value_mod.Module = .{ .name = "def", .words = .{} };
    const body = [_]Instruction{.{ .op = .{ .call_word = "foo" }, .line = 0 }};
    _ = try ctx.quotation_stamp_store.stamp(@intFromPtr(&body), &def_module);

    // The deps-only recording path creates the entry; its module half must carry the stamp, so a
    // body-entry map hit stays authoritative.
    try std.testing.expect((try ctx.captureQuotationScope(&body)) == null);
    const info = ctx.quotation_scope_info.get(@intFromPtr(&body)) orelse return error.TestExpectedEntry;
    try std.testing.expectEqual(@as(?*const value_mod.Module, &def_module), info.defining_module);
    try std.testing.expect(info.scope != null);
}

test "stampCapturedScopeForExecution: a fresh entry's module half is filled from the stamp store" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var def_module: value_mod.Module = .{ .name = "def", .words = .{} };
    const body = [_]Instruction{.{ .op = .{ .call_word = "w" }, .line = 0 }};
    _ = try ctx.quotation_stamp_store.stamp(@intFromPtr(&body), &def_module);

    var scope: CapturedScope = .{ .lexical_frames = &.{}, .deps_modules = &.{}, .allocator = ctx.allocator };
    try ctx.stampCapturedScopeForExecution(&body, &scope, null);
    const info = ctx.quotation_scope_info.get(@intFromPtr(&body)) orelse return error.TestExpectedEntry;
    try std.testing.expectEqual(@as(?*const value_mod.Module, &def_module), info.defining_module);
    try std.testing.expect(info.scope != null);

    // A supersede rewrites only the scope half; the cached stamp stays.
    try ctx.stampCapturedScopeForExecution(&body, &scope, null);
    const again = ctx.quotation_scope_info.get(@intFromPtr(&body)) orelse return error.TestExpectedEntry;
    try std.testing.expectEqual(@as(?*const value_mod.Module, &def_module), again.defining_module);
}

test "stampCapturedScopeForExecution: a closure-owned body enters neither the map nor the gate" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // A lexical frame, so a stamp that went through would mark the gate as well as the map.
    var frame: LocalFrame = .{};
    try frame.put(ctx.allocator, "local", .{ .name = "local", .action = .{ .compound = &.{} } });
    const frames = try ctx.allocator.alloc(LocalFrame, 1);
    frames[0] = frame;
    defer {
        frames[0].deinit(ctx.allocator);
        ctx.allocator.free(frames);
    }
    var scope: CapturedScope = .{ .lexical_frames = frames, .deps_modules = &.{}, .allocator = ctx.allocator };

    const cl = try closureOwnedProbeBody(&ctx, null, null);
    defer container_backing.releaseValue(.{ .closure = cl });

    try ctx.stampCapturedScopeForExecution(cl.instructions, &scope, cl);
    try std.testing.expectEqual(@as(usize, 0), ctx.quotation_scope_info.count());
    try std.testing.expect(!ctx.carryable_scope_gate.isMarked(@intFromPtr(cl.instructions.ptr)));
}

test "stampCapturedScopeForExecution: a push-time promotion still stamps" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // A promotion aliases the module-owned literal rather than allocating, so its body address is
    // process-lifetime and the map is still the right home for it.
    const body = try ctx.arena.allocator().alloc(Instruction, 1);
    body[0] = .{ .op = .{ .call_word = "w" }, .line = 1 };
    const cl = try value_mod.Closure.create(ctx.allocator, .{
        .instructions = body,
        .segments = &.{},
        .header = undefined,
    });
    defer container_backing.releaseValue(.{ .closure = cl });

    var scope: CapturedScope = .{ .lexical_frames = &.{}, .deps_modules = &.{}, .allocator = ctx.allocator };
    try ctx.stampCapturedScopeForExecution(cl.instructions, &scope, cl);
    try std.testing.expect(ctx.quotation_scope_info.get(@intFromPtr(body.ptr)) != null);
}

test "stampCapturedScopeForExecution: a carrier naming a different body does not exempt it" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const cl = try closureOwnedProbeBody(&ctx, null, null);
    defer container_backing.releaseValue(.{ .closure = cl });

    const other = try ctx.arena.allocator().alloc(Instruction, 1);
    other[0] = .{ .op = .{ .call_word = "w" }, .line = 1 };

    var scope: CapturedScope = .{ .lexical_frames = &.{}, .deps_modules = &.{}, .allocator = ctx.allocator };
    try ctx.stampCapturedScopeForExecution(other, &scope, cl);
    try std.testing.expect(ctx.quotation_scope_info.get(@intFromPtr(other.ptr)) != null);
}

test "captureQuotationScope: a lexical capture marks the carryable scope gate" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;

    try ctx.pushLocalFrame();
    try ctx.defineWord("local", .{ .name = "local", .action = .{ .compound = &.{} } });

    const body = [_]Instruction{.{ .op = .{ .call_word = "local" }, .line = 0 }};
    try std.testing.expect(!ctx.carryable_scope_gate.isMarked(@intFromPtr(&body)));

    _ = (try ctx.captureQuotationScope(&body)) orelse return error.TestExpectedCapture;
    try std.testing.expect(ctx.carryable_scope_gate.isMarked(@intFromPtr(&body)));
}

test "captureQuotationScope: a deps-only entry leaves the gate unmarked" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;

    var dep_module: value_mod.Module = .{ .name = "dep", .words = .{} };
    try dep_module.words.put(std.testing.allocator, "foo", .{ .action = .{ .native = noop } });
    defer dep_module.words.deinit(std.testing.allocator);
    try ctx.pushModuleDepsFrame(&dep_module);

    // The entry is recorded, but it carries no lexical frame, so the walk would step past it. A
    // mark here would send every descendant's first visit to this body up the chain for nothing.
    const body = [_]Instruction{.{ .op = .{ .call_word = "foo" }, .line = 0 }};
    try std.testing.expect((try ctx.captureQuotationScope(&body)) == null);
    try std.testing.expect(ctx.quotation_scope_info.get(@intFromPtr(&body)) != null);
    try std.testing.expect(!ctx.carryable_scope_gate.isMarked(@intFromPtr(&body)));
}

test "stampCapturedScopeForExecution: marks the gate only for a scope with a lexical frame" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    const deps_body = [_]Instruction{.{ .op = .{ .call_word = "w" }, .line = 0 }};
    var empty: CapturedScope = .{ .lexical_frames = &.{}, .deps_modules = &.{}, .allocator = ctx.allocator };
    try ctx.stampCapturedScopeForExecution(&deps_body, &empty, null);
    try std.testing.expect(!ctx.carryable_scope_gate.isMarked(@intFromPtr(&deps_body)));

    var frame: LocalFrame = .{};
    try frame.put(ctx.allocator, "local", .{ .name = "local", .action = .{ .native = noop } });
    const frames = try ctx.allocator.alloc(LocalFrame, 1);
    frames[0] = frame;
    defer {
        frames[0].deinit(ctx.allocator);
        ctx.allocator.free(frames);
    }
    var lexical: CapturedScope = .{ .lexical_frames = frames, .deps_modules = &.{}, .allocator = ctx.allocator };

    const lexical_body = [_]Instruction{.{ .op = .{ .call_word = "local" }, .line = 0 }};
    try ctx.stampCapturedScopeForExecution(&lexical_body, &lexical, null);
    try std.testing.expect(ctx.carryable_scope_gate.isMarked(@intFromPtr(&lexical_body)));
}

/// Give `parent` a durable `probe-word` pushing 1 and a carryable scope binding the same name to a
/// word pushing 2, keyed by the returned body. A child executing that body resolves 2 when the
/// walk reaches the scope and 1 when it does not, so the two gate tests below differ only in
/// whether the entry is published with a mark.
fn setupGateFillParent(parent: *Context, mark: bool) ![]Instruction {
    const push_durable: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 1 });
        }
    }.f;
    const push_captured: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 2 });
        }
    }.f;

    try parent.pushLocalFrame();
    parent.import_frame_index = 0;
    parent.durable_frame_floor = 0;
    try parent.local_frames.items[0].put(parent.allocator, "probe-word", .{
        .name = "probe-word",
        .action = .{ .native = push_durable },
    });

    const arena_alloc = parent.arena.allocator();
    const instrs = try arena_alloc.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .call_word = "probe-word" }, .line = 1 };

    var frame: LocalFrame = .{};
    try frame.put(parent.allocator, "probe-word", .{ .name = "probe-word", .action = .{ .native = push_captured } });
    const frames = try parent.allocator.alloc(LocalFrame, 1);
    frames[0] = frame;
    const scope = try parent.allocator.create(CapturedScope);
    scope.* = .{ .lexical_frames = frames, .allocator = parent.allocator };

    const key = @intFromPtr(instrs.ptr);
    if (mark) {
        try putCarryableScopeForTest(parent, key, scope);
    } else {
        try parent.quotation_scope_info.put(parent.allocator, key, .{ .scope = scope });
    }
    return instrs;
}

test "executeInstructions: the fill walks to a marked ancestor entry and caches it" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const instrs = try setupGateFillParent(&parent, true);

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();
    try task_ctx.executeQuotation(.{ .instructions = instrs });
    try std.testing.expectEqual(@as(i64, 2), (try task_ctx.stack.pop()).fixnum);

    const info = task_ctx.quotation_scope_info.get(@intFromPtr(instrs.ptr)) orelse return error.TestExpectedEntry;
    try std.testing.expect(info.scope != null);
}

test "executeInstructions: the fill skips the walk for an unmarked body" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    var scheduler = try std.testing.allocator.create(Scheduler);
    defer std.testing.allocator.destroy(scheduler);
    scheduler.* = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    // Publishing the entry without a mark is a state no production writer produces. Constructing
    // it is the only way to observe that the walk was skipped, since a skipped walk and a walk
    // that found nothing are otherwise indistinguishable.
    const instrs = try setupGateFillParent(&parent, false);

    var task_ctx = try Context.initForTask(std.testing.allocator, &parent, scheduler);
    defer task_ctx.deinit();
    try task_ctx.executeQuotation(.{ .instructions = instrs });

    // The durable binding won, so the ancestor's scope was never reached.
    try std.testing.expectEqual(@as(i64, 1), (try task_ctx.stack.pop()).fixnum);

    const info = task_ctx.quotation_scope_info.get(@intFromPtr(instrs.ptr)) orelse return error.TestExpectedEntry;
    try std.testing.expectEqual(@as(?*CapturedScope, null), info.scope);
}

test "stampQuotationBodies: repairs an entry created before the stamp" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const noop: dict_mod.NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;

    var dep_module: value_mod.Module = .{ .name = "dep", .words = .{} };
    try dep_module.words.put(std.testing.allocator, "foo", .{ .action = .{ .native = noop } });
    defer dep_module.words.deinit(std.testing.allocator);
    try ctx.pushModuleDepsFrame(&dep_module);

    // The module's own top-level code pushes the literal before finalization stamps it, so the
    // entry's module half caches the store miss.
    const body = [_]Instruction{.{ .op = .{ .call_word = "foo" }, .line = 0 }};
    try std.testing.expect((try ctx.captureQuotationScope(&body)) == null);
    const before = ctx.quotation_scope_info.get(@intFromPtr(&body)) orelse return error.TestExpectedEntry;
    try std.testing.expectEqual(@as(?*const value_mod.Module, null), before.defining_module);

    // Finalization stamps the store and repairs the loading context's stale null in place, so the
    // now-authoritative map hit carries the stamp.
    var def_module: value_mod.Module = .{ .name = "def", .words = .{} };
    try ctx.stampQuotationBodies(&body, &def_module);
    const after = ctx.quotation_scope_info.get(@intFromPtr(&body)) orelse return error.TestExpectedEntry;
    try std.testing.expectEqual(@as(?*const value_mod.Module, &def_module), after.defining_module);
    try std.testing.expect(after.scope != null);
}

test "executeInstructions: a synthetic-scope stamp leaves the own-module probe off" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const push_durable: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 1 });
        }
    }.f;
    const push_module: dict_mod.NativeFn = struct {
        fn f(c: *Context) anyerror!void {
            try c.stack.push(.{ .fixnum = 2 });
        }
    }.f;

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    try ctx.local_frames.items[0].put(ctx.allocator, "probe-word", .{
        .name = "probe-word",
        .action = .{ .native = push_durable },
    });

    // A `<local-scope>` module deliberately captures only imports and sibling privates, so a body
    // stamped with one keeps resolving against the enclosing frames, not the synthetic module.
    const arena_alloc = ctx.arena.allocator();
    const module = try arena_alloc.create(value_mod.Module);
    module.* = .{ .name = "<local-scope>", .words = .{} };
    try module.words.put(arena_alloc, "probe-word", .{ .action = .{ .native = push_module } });

    const instrs = try arena_alloc.alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .call_word = "probe-word" }, .line = 1 };
    _ = try ctx.quotation_stamp_store.stamp(@intFromPtr(instrs.ptr), module);

    try ctx.executeQuotation(.{ .instructions = instrs });
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).fixnum);
}

test "nonempty_transient_lexical_frames: define, remove, and pop stay balanced" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Frame 0 is the durable import frame; only frames above it are counted.
    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;

    try ctx.pushLocalFrame();
    try std.testing.expectEqual(@as(usize, 0), ctx.nonempty_transient_lexical_frames);

    // First definition makes the frame non-empty.
    try ctx.defineWord("a", .{ .name = "a", .action = .{ .compound = &.{} } });
    try std.testing.expectEqual(@as(usize, 1), ctx.nonempty_transient_lexical_frames);

    // A second definition in the same frame does not change the count.
    try ctx.defineWord("b", .{ .name = "b", .action = .{ .compound = &.{} } });
    try std.testing.expectEqual(@as(usize, 1), ctx.nonempty_transient_lexical_frames);

    // Removing one word leaves the frame non-empty.
    try std.testing.expect(ctx.removeWord("a"));
    try std.testing.expectEqual(@as(usize, 1), ctx.nonempty_transient_lexical_frames);

    // Removing the last word empties the frame.
    try std.testing.expect(ctx.removeWord("b"));
    try std.testing.expectEqual(@as(usize, 0), ctx.nonempty_transient_lexical_frames);

    // A definition followed by a pop of the whole frame nets back to zero.
    try ctx.defineWord("c", .{ .name = "c", .action = .{ .compound = &.{} } });
    try std.testing.expectEqual(@as(usize, 1), ctx.nonempty_transient_lexical_frames);
    ctx.popLocalFrame();
    try std.testing.expectEqual(@as(usize, 0), ctx.nonempty_transient_lexical_frames);
}

test "captureQuotationScope: empty combinator frames leave the counter zero and skip capture" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;

    // Two empty lexical frames stand in for combinator frames that define no locals.
    try ctx.pushLocalFrame();
    try ctx.pushLocalFrame();
    try std.testing.expectEqual(@as(usize, 0), ctx.nonempty_transient_lexical_frames);

    const body = [_]Instruction{.{ .op = .{ .call_word = "x" }, .line = 0 }};
    try std.testing.expect(try ctx.captureQuotationScope(&body) == null);
}

test "captureQuotationScope: a live local still captures through the gate" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;

    try ctx.pushLocalFrame();
    try ctx.defineWord("local", .{ .name = "local", .source_file = "local-site", .action = .{ .compound = &.{} } });
    try std.testing.expectEqual(@as(usize, 1), ctx.nonempty_transient_lexical_frames);

    const body = [_]Instruction{.{ .op = .{ .call_word = "local" }, .line = 0 }};
    const scope = (try ctx.captureQuotationScope(&body)) orelse return error.TestExpectedCapture;
    const resolved = Context.lookupInCapturedScope(scope, "local") orelse return error.TestExpectedResolution;
    try std.testing.expectEqualStrings("local-site", resolved.source_file.?);
}

test "captureQuotationScope: a second call for the same body supersedes with a fresh scope" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;

    try ctx.pushLocalFrame();
    try ctx.defineWord("local", .{ .name = "local", .source_file = "local-site", .action = .{ .compound = &.{} } });

    const body = [_]Instruction{.{ .op = .{ .call_word = "local" }, .line = 0 }};
    const first = (try ctx.captureQuotationScope(&body)) orelse return error.TestExpectedCapture;
    const first_addr = @intFromPtr(first);
    const second = (try ctx.captureQuotationScope(&body)) orelse return error.TestExpectedCapture;

    // A fresh push builds a new scope rather than reusing the cached one. Compare addresses only:
    // `first` is superseded and released by this second call, so it must not be dereferenced.
    try std.testing.expect(first_addr != @intFromPtr(second));
    const resolved = Context.lookupInCapturedScope(second, "local") orelse return error.TestExpectedResolution;
    try std.testing.expectEqualStrings("local-site", resolved.source_file.?);
}

test "defineWordLocked: a leaf-backed binding in a transient frame is released when the frame pops" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    try ctx.pushLocalFrame();

    const bytes = try std.testing.allocator.dupe(u8, "computed");
    const str = try value_mod.ownedStringValue(std.testing.allocator, bytes);
    const backing = str.string.backing.?;

    // A second reference stands in for the caller that outlives the binding, so the refcount is
    // observable after the frame drops its own.
    container_backing.retainValue(str);
    defer container_backing.releaseValue(str);

    try ctx.defineWord("s", .{ .name = "s", .action = .{ .literal = str } });
    const def = ctx.lookupWord("s") orelse return error.TestExpectedWord;
    try std.testing.expect(def.owns_literal);
    try std.testing.expectEqual(@as(u32, 2), backing.header.refcountValue());

    ctx.popLocalFrame();
    try std.testing.expectEqual(@as(u32, 1), backing.header.refcountValue());
}

test "defineWordLocked: a container binding keeps the durable path even inside a transient frame" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    try ctx.pushLocalFrame();

    const vec = try value_mod.Vector.create(std.testing.allocator);
    try ctx.defineWord("v", .{ .name = "v", .action = .{ .literal = .{ .vector = vec } } });

    // Frame ownership would let a captured scope holding this same binding outlive the reclamation
    // and close a cycle through any closure the vector comes to hold, so the dictionary keeps the
    // reference until teardown instead.
    const def = ctx.lookupWord("v") orelse return error.TestExpectedWord;
    try std.testing.expect(!def.owns_literal);
    try std.testing.expectEqual(@as(u32, 1), vec.header.refcountValue());

    ctx.popLocalFrame();
    try std.testing.expectEqual(@as(u32, 1), vec.header.refcountValue());
}

test "defineWordLocked: rebinding a name in the same frame releases the displaced value" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    try ctx.pushLocalFrame();

    const first_bytes = try std.testing.allocator.dupe(u8, "first");
    const first = try value_mod.ownedStringValue(std.testing.allocator, first_bytes);
    const first_backing = first.string.backing.?;
    container_backing.retainValue(first);
    defer container_backing.releaseValue(first);

    const second_bytes = try std.testing.allocator.dupe(u8, "second");
    const second = try value_mod.ownedStringValue(std.testing.allocator, second_bytes);

    try ctx.defineWord("s", .{ .name = "s", .action = .{ .literal = first } });
    try std.testing.expectEqual(@as(u32, 2), first_backing.header.refcountValue());

    try ctx.defineWord("s", .{ .name = "s", .action = .{ .literal = second } });
    try std.testing.expectEqual(@as(u32, 1), first_backing.header.refcountValue());
}

test "captureQuotationScope: a cloned binding outlives the frame it was captured from" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    try ctx.pushLocalFrame();

    const bytes = try std.testing.allocator.dupe(u8, "captured");
    const str = try value_mod.ownedStringValue(std.testing.allocator, bytes);
    const backing = str.string.backing.?;
    try ctx.defineWord("s", .{ .name = "s", .action = .{ .literal = str } });

    const body = [_]Instruction{.{ .op = .{ .call_word = "s" }, .line = 0 }};
    const scope: *CapturedScope = @constCast((try ctx.captureQuotationScope(&body)) orelse
        return error.TestExpectedCapture);
    scope.retain();
    try std.testing.expectEqual(@as(u32, 2), backing.header.refcountValue());

    // The frame's own reference goes, and the scope's keeps the bytes readable.
    ctx.popLocalFrame();
    try std.testing.expectEqual(@as(u32, 1), backing.header.refcountValue());
    const resolved = Context.lookupInCapturedScope(scope, "s") orelse return error.TestExpectedResolution;
    try std.testing.expectEqualStrings("captured", resolved.action.literal.string.bytes);

    scope.release();
}

test "captureQuotationScope: superseding an unretained scope frees it immediately" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    try ctx.pushLocalFrame();
    try ctx.defineWord("local", .{ .name = "local", .action = .{ .compound = &.{} } });

    const body = [_]Instruction{.{ .op = .{ .call_word = "local" }, .line = 0 }};
    const first = (try ctx.captureQuotationScope(&body)) orelse return error.TestExpectedCapture;
    try std.testing.expectEqual(@as(u32, 1), first.refcountValue());

    // Nothing retained `first` beyond the map's own hold, so superseding it here frees it
    // immediately. Verified by `std.testing.allocator`'s leak detection at `ctx.deinit`, not by
    // dereferencing `first`, which is dangling after this call.
    _ = (try ctx.captureQuotationScope(&body)) orelse return error.TestExpectedCapture;
}

test "captureQuotationScope: a retained scope survives a supersede, frees only after release" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    try ctx.pushLocalFrame();
    try ctx.defineWord("local", .{ .name = "local", .action = .{ .compound = &.{} } });

    const body = [_]Instruction{.{ .op = .{ .call_word = "local" }, .line = 0 }};
    // `@constCast` mirrors the existing lock-in-const idiom in this file: `captureQuotationScope`
    // returns `*const` for ordinary callers, but a test simulating a reader's retain/release needs
    // the mutable methods.
    const first: *CapturedScope = @constCast((try ctx.captureQuotationScope(&body)) orelse return error.TestExpectedCapture);

    // Simulate an in-flight `executeInstructions` reader retaining the scope for the duration of
    // its call.
    first.retain();
    try std.testing.expectEqual(@as(u32, 2), first.refcountValue());

    _ = (try ctx.captureQuotationScope(&body)) orelse return error.TestExpectedCapture;

    // Superseding dropped the map's own hold, but the simulated reader's retain keeps `first` alive
    // and readable.
    try std.testing.expectEqual(@as(u32, 1), first.refcountValue());
    const resolved = Context.lookupInCapturedScope(first, "local") orelse return error.TestExpectedResolution;
    try std.testing.expectEqualStrings("local", resolved.name);

    // Releasing the simulated reader's hold frees it.
    first.release();
}

test "captureQuotationScope + promoteToClosure: a dropped promotion is reclaimed, so repeated capture-and-drop stays flat" {
    var mem_limit = MemoryLimitAllocator.init(std.testing.allocator, 0);
    var ctx = Context.init(mem_limit.allocator());
    defer ctx.deinit();

    try ctx.pushLocalFrame();
    ctx.import_frame_index = 0;
    ctx.durable_frame_floor = 0;
    try ctx.pushLocalFrame();
    try ctx.defineWord("local", .{ .name = "local", .action = .{ .compound = &.{} } });

    const body = [_]Instruction{.{ .op = .{ .call_word = "local" }, .line = 0 }};
    const quot: Quotation = .{ .instructions = &body };

    // The binding stays fixed across the loop so this test isolates the closure-capture mechanism
    // from the cost of redefining the local itself, which is covered by its own tests elsewhere.
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        const scope = (try ctx.captureQuotationScope(&body)) orelse return error.TestExpectedCapture;
        const cl = try ctx.promoteToClosure(quot, scope);
        container_backing.releaseValue(.{ .closure = cl });
    }
    const first_batch_bytes = mem_limit.currentBytes();

    while (i < 8192) : (i += 1) {
        const scope = (try ctx.captureQuotationScope(&body)) orelse return error.TestExpectedCapture;
        const cl = try ctx.promoteToClosure(quot, scope);
        container_backing.releaseValue(.{ .closure = cl });
    }
    const second_batch_bytes = mem_limit.currentBytes();

    // `captureQuotationScope`'s own map entry is refcounted and freed on supersede (proven
    // bounded by the tests above), and a promoted closure now carries a refcounted header whose
    // release frees the struct, its segments, and its owned scope copy. Dropping every promotion
    // must therefore leave live bytes flat across the second batch.
    try std.testing.expect(first_batch_bytes > 0);
    try std.testing.expect(second_batch_bytes <= first_batch_bytes);
}

test "dupeCapturedScope: deep-copies into an independent scope resolving the same binding" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var frame: LocalFrame = .{};
    try frame.put(ctx.allocator, "w", .{ .name = "w", .source_file = "src", .action = .{ .compound = &.{} } });
    const frames = try ctx.allocator.alloc(LocalFrame, 1);
    frames[0] = frame;
    var src: CapturedScope = .{ .lexical_frames = frames, .allocator = ctx.allocator };
    defer {
        for (src.lexical_frames) |*f| f.deinit(ctx.allocator);
        ctx.allocator.free(src.lexical_frames);
    }

    const dup = try Context.dupeCapturedScope(ctx.allocator, &src);
    defer dup.release();

    try std.testing.expectEqual(@as(usize, 1), dup.lexical_frames.len);
    try std.testing.expect(dup.lexical_frames.ptr != src.lexical_frames.ptr);
    const resolved = Context.lookupInCapturedScope(dup, "w") orelse return error.TestExpectedResolution;
    try std.testing.expectEqualStrings("src", resolved.source_file.?);
}

test "stampCapturedScopeForExecution: a second stamp with a different scope supersedes the first" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var frame1: LocalFrame = .{};
    try frame1.put(ctx.allocator, "w", .{ .name = "w", .source_file = "first", .action = .{ .compound = &.{} } });
    const frames1 = try ctx.allocator.alloc(LocalFrame, 1);
    frames1[0] = frame1;
    var scope1: CapturedScope = .{ .lexical_frames = frames1, .allocator = ctx.allocator };
    defer {
        for (scope1.lexical_frames) |*f| f.deinit(ctx.allocator);
        ctx.allocator.free(scope1.lexical_frames);
    }

    var frame2: LocalFrame = .{};
    try frame2.put(ctx.allocator, "w", .{ .name = "w", .source_file = "second", .action = .{ .compound = &.{} } });
    const frames2 = try ctx.allocator.alloc(LocalFrame, 1);
    frames2[0] = frame2;
    var scope2: CapturedScope = .{ .lexical_frames = frames2, .allocator = ctx.allocator };
    defer {
        for (scope2.lexical_frames) |*f| f.deinit(ctx.allocator);
        ctx.allocator.free(scope2.lexical_frames);
    }

    const body = [_]Instruction{.{ .op = .{ .call_word = "w" }, .line = 0 }};
    try ctx.stampCapturedScopeForExecution(&body, &scope1, null);

    const stamped = (ctx.quotation_scope_info.get(@intFromPtr(&body)) orelse return error.TestExpectedStamp).scope orelse
        return error.TestExpectedStamp;
    // The map owns a distinct copy, not the source pointer.
    try std.testing.expect(stamped != &scope1);
    var resolved = Context.lookupInCapturedScope(stamped, "w") orelse return error.TestExpectedResolution;
    try std.testing.expectEqualStrings("first", resolved.source_file.?);

    // A second stamp under the same key, sourced from a different scope, supersedes the first
    // rather than leaving it in place: two closures sharing this key (the common case for closures
    // built by repeated executions of the same loop-nested literal, via `promoteToClosure`) must
    // each resolve against their own carried scope, not whichever was stamped first.
    try ctx.stampCapturedScopeForExecution(&body, &scope2, null);
    const again = ctx.quotation_scope_info.get(@intFromPtr(&body)).?.scope.?;
    // Compare addresses only: `stamped` is superseded and released by this second call, so it
    // must not be dereferenced.
    try std.testing.expect(again != stamped);
    resolved = Context.lookupInCapturedScope(again, "w") orelse return error.TestExpectedResolution;
    try std.testing.expectEqualStrings("second", resolved.source_file.?);
}

test "stampCapturedScopeForExecution: a retained scope survives a supersede, frees only after release" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var frame1: LocalFrame = .{};
    try frame1.put(ctx.allocator, "w", .{ .name = "w", .source_file = "first", .action = .{ .compound = &.{} } });
    const frames1 = try ctx.allocator.alloc(LocalFrame, 1);
    frames1[0] = frame1;
    var scope1: CapturedScope = .{ .lexical_frames = frames1, .allocator = ctx.allocator };
    defer {
        for (scope1.lexical_frames) |*f| f.deinit(ctx.allocator);
        ctx.allocator.free(scope1.lexical_frames);
    }

    var frame2: LocalFrame = .{};
    try frame2.put(ctx.allocator, "w", .{ .name = "w", .source_file = "second", .action = .{ .compound = &.{} } });
    const frames2 = try ctx.allocator.alloc(LocalFrame, 1);
    frames2[0] = frame2;
    var scope2: CapturedScope = .{ .lexical_frames = frames2, .allocator = ctx.allocator };
    defer {
        for (scope2.lexical_frames) |*f| f.deinit(ctx.allocator);
        ctx.allocator.free(scope2.lexical_frames);
    }

    const body = [_]Instruction{.{ .op = .{ .call_word = "w" }, .line = 0 }};
    try ctx.stampCapturedScopeForExecution(&body, &scope1, null);
    const first: *CapturedScope = (ctx.quotation_scope_info.get(@intFromPtr(&body)) orelse return error.TestExpectedStamp).scope orelse
        return error.TestExpectedStamp;

    // Simulate an in-flight `executeInstructions` reader retaining the scope for the duration of
    // its call.
    first.retain();
    try std.testing.expectEqual(@as(u32, 2), first.refcountValue());

    try ctx.stampCapturedScopeForExecution(&body, &scope2, null);

    // Superseding dropped the map's own hold, but the simulated reader's retain keeps `first` alive
    // and readable.
    try std.testing.expectEqual(@as(u32, 1), first.refcountValue());
    const resolved = Context.lookupInCapturedScope(first, "w") orelse return error.TestExpectedResolution;
    try std.testing.expectEqualStrings("first", resolved.source_file.?);

    // Releasing the simulated reader's hold frees it.
    first.release();
}

test "findCapturedScopeForBody: finds in self, then parent-walks to an ancestor" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    var frame: LocalFrame = .{};
    try frame.put(parent.allocator, "w", .{ .name = "w", .source_file = "anc", .action = .{ .compound = &.{} } });
    const frames = try parent.allocator.alloc(LocalFrame, 1);
    frames[0] = frame;
    const scope = try parent.allocator.create(CapturedScope);
    scope.* = .{ .lexical_frames = frames, .allocator = parent.allocator };
    const body = [_]Instruction{.{ .op = .{ .call_word = "w" }, .line = 0 }};
    try parent.quotation_scope_info.put(parent.allocator, @intFromPtr(&body), .{ .scope = scope });

    var child = Context.init(std.testing.allocator);
    defer child.deinit();
    child.parent_context = &parent;
    defer child.parent_context = null;

    // Child misses in its own map and walks to the ancestor. The result is an independently owned
    // copy on the allocator passed in, not the ancestor's own map entry, so it is released here
    // rather than at either context's teardown.
    const found = (try child.findCapturedScopeForBody(std.testing.allocator, @intFromPtr(&body))) orelse
        return error.TestExpectedFind;
    defer found.release();
    try std.testing.expect(found != scope);
    const resolved = Context.lookupInCapturedScope(found, "w") orelse return error.TestExpectedResolution;
    try std.testing.expectEqualStrings("anc", resolved.source_file.?);

    // A body in no map returns null.
    const other = [_]Instruction{.{ .op = .{ .call_word = "x" }, .line = 0 }};
    try std.testing.expect(try child.findCapturedScopeForBody(std.testing.allocator, @intFromPtr(&other)) == null);
}

test "findCapturedScopeForBody: the returned copy survives the ancestor's entry being superseded" {
    var parent = Context.init(std.testing.allocator);
    defer parent.deinit();

    try parent.pushLocalFrame();
    parent.import_frame_index = 0;
    parent.durable_frame_floor = 0;
    try parent.pushLocalFrame();
    try parent.defineWord("w", .{ .name = "w", .action = .{ .compound = &.{} } });

    const body = [_]Instruction{.{ .op = .{ .call_word = "w" }, .line = 0 }};
    _ = (try parent.captureQuotationScope(&body)) orelse return error.TestExpectedCapture;

    var child = Context.init(std.testing.allocator);
    defer child.deinit();
    child.parent_context = &parent;
    defer child.parent_context = null;

    const found = (try child.findCapturedScopeForBody(std.testing.allocator, @intFromPtr(&body))) orelse
        return error.TestExpectedFind;
    defer found.release();

    // Superseding the ancestor's own entry for the same body -- which frees the ancestor's original
    // scope, since nothing else retained it -- does not disturb the child's independent copy. This
    // is the exact class of bug (a scope read across a supersede without a protecting copy) that
    // crashed real server code during this fix's own development; see `promoteToClosure`'s doc
    // comment.
    _ = (try parent.captureQuotationScope(&body)) orelse return error.TestExpectedCapture;

    const resolved = Context.lookupInCapturedScope(found, "w") orelse return error.TestExpectedResolution;
    try std.testing.expectEqualStrings("w", resolved.name);
}

test "deinit releases runtime-created values stored into image container slots" {
    const alloc = std.testing.allocator;
    var ctx = Context.init(alloc);

    // Mimic the image loader: slot containers on the context arena, one
    // donated reference each. The vector receives a runtime-created hash
    // (as a compiled `#push!` would store it); the map receives a
    // runtime-created value under a runtime `@set!`.
    const vec = try value_mod.Vector.create(ctx.quotationAllocator());
    var vec_slots = [_]?*value_mod.Vector{vec};
    ctx.image_vector_slots = &vec_slots;
    ctx.image_vector_slot_count = 1;

    const mmap = try value_mod.MutableMap.create(ctx.quotationAllocator());
    var map_slots = [_]?*value_mod.MutableMap{mmap};
    ctx.image_mutable_map_slots = &map_slots;
    ctx.image_mutable_map_slot_count = 1;

    const h = try value_mod.HashTable.create(alloc);
    try h.map.put(alloc, try alloc.dupe(u8, "k"), .{ .fixnum = 42 });
    try vec.list.append(ctx.quotationAllocator(), .{ .hash = h });

    const h2 = try value_mod.HashTable.create(alloc);
    const key = try ctx.quotationAllocator().dupe(u8, "r");
    try mmap.map.put(ctx.quotationAllocator(), key, .{ .hash = h2 });

    // deinit's image-slot walk drops the donated references; the destroys
    // release the stored hashes. testing.allocator reports them if not.
    ctx.deinit();
}

test "dispatchEntriesForId breaks type-name ties by registration sequence" {
    const alloc = std.testing.allocator;
    var ctx = Context.init(alloc);
    defer ctx.deinit();

    // Descriptors with no registry name all sort as the empty name, so the sort's name keys tie
    // for every pair and only the sequence tie-break orders them.
    var tds: [4]*value_mod.TypeDescriptor = undefined;
    for (&tds) |*td| {
        td.* = try alloc.create(value_mod.TypeDescriptor);
        td.*.* = .{ .kind = .builtin };
    }
    defer for (tds) |td| alloc.destroy(td);
    const td_sentinel = try alloc.create(value_mod.TypeDescriptor);
    defer alloc.destroy(td_sentinel);
    td_sentinel.* = .{ .kind = .sentinel };

    const body = [_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 }};
    const did: u32 = 9001;
    for (tds) |td| {
        try ctx.registerDispatch(
            .{ .dispatch_id = did, .type_a = td, .type_b = td_sentinel },
            .{ .body = .{ .quotation = .{ .instructions = &body } } },
            false,
        );
    }

    const pairs = try ctx.dispatchEntriesForId(did, alloc);
    defer alloc.free(pairs);

    try std.testing.expectEqual(@as(usize, 4), pairs.len);
    for (pairs, tds) |pair, td| {
        try std.testing.expectEqual(@as(*const value_mod.TypeDescriptor, td), pair.key.type_a);
    }
}

test "formatAbortFrame renders innermost and caller frames" {
    var buf: [512]u8 = undefined;

    const inner = Context.formatAbortFrame(&buf, .{ .word_name = "boom", .source = "main.1z", .line = 12, .column = 3 }, true);
    try std.testing.expectEqualStrings("  at word 'boom' (main.1z:12:3)\n", inner);

    const inner_no_col = Context.formatAbortFrame(&buf, .{ .word_name = "boom", .source = "main.1z", .line = 12 }, true);
    try std.testing.expectEqualStrings("  at word 'boom' (main.1z:12)\n", inner_no_col);

    const caller = Context.formatAbortFrame(&buf, .{ .word_name = "outer", .source = "lib/util.1z", .line = 20 }, false);
    try std.testing.expectEqualStrings("  called from lib/util.1z:20: outer\n", caller);
}
