const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("context.zig").Context;
const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const Marker = value_mod.Marker;
const Value = value_mod.Value;
const StackEffect = @import("stack_effect.zig").StackEffect;
const container_backing = @import("container_backing.zig");
const word_slot_mod = @import("word_slot.zig");
pub const WordSlot = word_slot_mod.WordSlot;
pub const Capability = @import("primitives/types.zig").Capability;

/// Native function signature: takes context, can return errors.
pub const NativeFn = *const fn (ctx: *Context) anyerror!void;

/// Host callback function signature: takes opaque context and user data, returns C int status code.
pub const HostCallbackFn = *const fn (ctx: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) c_int;
pub const HostCallback = struct {
    handle: ?*anyopaque,
    callback: HostCallbackFn,
    user_data: ?*anyopaque,
};

/// Provenance metadata for generated words, e.g., constructors, predicates, accessors.
pub const WordProvenance = struct {
    generator: []const u8,
    parent: []const u8,
    role: []const u8,
};

/// Precomputed constant-per-word facts, a derived cache of `markers` and
/// `action` populated at definition time. Distinct from the primary fields:
/// these are recomputed whenever the definition is finalized.
pub const ExecFlags = packed struct {
    /// Word carries the generic marker.
    is_generic: bool = false,
    /// Word carries the recursive-non-tco marker.
    recursive_non_tco: bool = false,
    /// Word carries the stack-recursive marker.
    stack_recursive: bool = false,
    /// Compound word with an empty body.
    empty_compound_body: bool = false,
    /// Type-annotation validation is skippable (generic + empty body).
    skip_type_validation: bool = false,
    /// Some input parameter carries a quotation effect worth validating.
    has_param_effects: bool = false,
    /// Some input parameter carries a type annotation worth validating.
    has_type_annotations: bool = false,
};

/// Word definition: either a native function or compound quotation.
pub const WordDefinition = struct {
    /// The word itself.
    name: []const u8,
    /// Whether this word is a parse-time word.
    parse_time: bool = false,
    /// Whether this word can only be called during parse time.
    parse_time_only: bool = false,
    /// Whether this word was imported from another module.
    imported: bool = false,
    /// Stack effect annotation for this word, if any.
    stack_effect: ?StackEffect = null,
    /// Whether this word is effect-transparent, meaning its stack effect
    /// depends on a quotation argument rather than being fixed.
    effect_transparent: bool = false,
    /// Markers associated with this word.
    markers: []const *Marker = &.{},
    // Documentation string for this word, if any.
    doc: ?[]const u8 = null,
    /// Source file where this word was defined, or null for native primitives.
    source_file: ?[]const u8 = null,
    /// Source line where this word was defined, or 0 if unknown.
    source_line: usize = 0,
    /// Source column where this word was defined, or 0 if unknown.
    source_column: usize = 0,
    /// Module this word was imported from. When set, executing this word
    /// pushes the module's deps as a local frame so that late-bound
    /// references to the module's dependencies resolve correctly.
    source_module: ?*const value_mod.Module = null,
    /// Provenance metadata for generated words, or null for hand-written words.
    provenance: ?WordProvenance = null,
    /// Capability category for sandboxing.
    capability: Capability = .none,
    /// JIT dispatch table ID, assigned when this word is registered for JIT compilation.
    word_id: ?u32 = null,
    /// Monotonic dispatch ID assigned by Context.defineWord. Used as the
    /// identity component of DispatchKey so that same-named words in
    /// different modules get separate dispatch entries.
    dispatch_id: u32 = 0,
    /// Precomputed per-call facts. Derived cache; see `ExecFlags`. Populated at
    /// definition finalization, defaults to the "nothing special" all-false case.
    exec_flags: ExecFlags = .{},
    /// The action performed by this word: either a native function or a
    /// compound quotation. Unfortunate naming.
    action: Action,

    /// Either a native function, a host callback, a compound quotation body,
    /// or a directly-bound literal value. Named so it can be built by a
    /// standalone helper (`literalOrCompoundAction`) instead of only as an
    /// inline struct-literal field.
    pub const Action = union(enum) {
        native: NativeFn,
        host_callback: HostCallback,
        compound: []const Instruction,
        /// A `name: swap ;`-style local or marker definition bound to a
        /// non-refcounted value, stored directly with no `Instruction`
        /// slice allocated. See `literalOrCompoundAction` for the
        /// eligibility rule and the container-backed fallback.
        literal: Value,
    };

    /// Builds the action for a plain (non-quotation) bound value, keyed on
    /// whether the value needs retain/release bookkeeping:
    /// `container_backing.valueCarriesBacking` is the same dispatch already
    /// used at every other storage boundary to decide this. A non-refcounted
    /// value stores directly as `.literal`, with no allocation. A
    /// container-backed value (array, hash, vector, set, mutable-map,
    /// byte-array, etc.) keeps the one-instruction `push_literal` wrapper as
    /// `.compound`, unchanged from before this variant existed.
    pub fn literalOrCompoundAction(alloc: Allocator, value: Value) !Action {
        if (!container_backing.valueCarriesBacking(value)) {
            return .{ .literal = value };
        }
        const instrs = try alloc.alloc(Instruction, 1);
        instrs[0] = .{ .op = .{ .push_literal = value }, .line = 0 };
        return .{ .compound = instrs };
    }

    /// Returns true if this word is a native function or host callback, i.e., not a compound quotation.
    pub fn isNativeLike(self: WordDefinition) bool {
        return switch (self.action) {
            .native, .host_callback => true,
            .compound, .literal => false,
        };
    }

    /// Returns true if this word is a built-in native function.
    pub fn isBuiltinNative(self: WordDefinition) bool {
        return switch (self.action) {
            .native => true,
            .host_callback, .compound, .literal => false,
        };
    }

    /// Invokes this word's action. For native functions, calls the function with the given context.
    pub fn invoke(self: WordDefinition, ctx: *Context) anyerror!void {
        switch (self.action) {
            .native => |func| try func(ctx),
            .host_callback => |host| {
                const rc = host.callback(host.handle, host.user_data);
                if (rc != 0) return error.HostCallbackFailed;
            },
            .compound, .literal => unreachable,
        }
    }
};

/// Typed view onto a `WordSlot`'s current definition pointer. The slot
/// itself stores the pointer as `*word_slot.WordDefinition` (an opaque type
/// declared in `word_slot.zig`) so that `value.zig` can reference
/// `*WordSlot` without dragging the dictionary's full type graph into Value's
/// resolution path. Use these helpers anywhere a typed `*WordDefinition` is
/// expected.
pub fn loadSlot(slot: *const WordSlot) *WordDefinition {
    return @ptrCast(@alignCast(slot.load()));
}

fn storeSlot(slot: *WordSlot, def: *WordDefinition) void {
    slot.store(@ptrCast(def));
}

/// Allocate a slot and its boxed definition outside any dictionary.
///
/// The AOT runtime-image loader owns these: a build-time-resolved call target names a module word,
/// which lives in a `Module`'s map rather than in the dictionary, so it has no slot of its own. The
/// caller replaces the definition in place through `loadSlot`, keeping the slot address stable for
/// the instructions that already reference it. Both allocations belong to `allocator` and are
/// freed with it, so the caller must pass one that outlives every referencing instruction.
pub fn createDetachedSlot(allocator: Allocator, name: []const u8, definition: WordDefinition) !*WordSlot {
    const def_box = try allocator.create(WordDefinition);
    errdefer allocator.destroy(def_box);
    def_box.* = definition;

    const slot = try allocator.create(WordSlot);
    slot.* = .{
        .name = name,
        .definition = std.atomic.Value(*word_slot_mod.WordDefinition).init(@ptrCast(def_box)),
    };
    return slot;
}

/// Dictionary maps word names to their definitions.
pub const Dictionary = struct {
    entries: std.StringHashMapUnmanaged(*WordSlot),
    allocator: Allocator,
    /// Instruction slices belonging to compound word bodies whose
    /// `push_literal` operands include at least one container variant.
    /// Walked at teardown so captured container backings can be
    /// released before the arena that owns the instructions is freed.
    container_release_list: std.ArrayListUnmanaged([]const Instruction) = .{},
    /// Heap-boxed `WordDefinition` values displaced by redefinition. Each
    /// entry was once the current definition for some slot; after an atomic
    /// swap there may still be readers holding the pointer, so the box stays
    /// allocated for the dictionary's lifetime and is freed in `deinit`.
    retired: std.ArrayListUnmanaged(*WordDefinition) = .{},

    pub fn init(allocator: Allocator) Dictionary {
        return .{
            .entries = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Dictionary) void {
        var it = self.entries.valueIterator();
        while (it.next()) |slot_ptr| {
            const slot = slot_ptr.*;
            self.allocator.destroy(loadSlot(slot));
            self.allocator.destroy(slot);
        }
        self.entries.deinit(self.allocator);
        for (self.retired.items) |def| self.allocator.destroy(def);
        self.retired.deinit(self.allocator);
        self.container_release_list.deinit(self.allocator);
    }

    pub fn put(self: *Dictionary, name: []const u8, definition: WordDefinition) !void {
        const def_box = try self.allocator.create(WordDefinition);
        def_box.* = definition;
        const gop = try self.entries.getOrPut(self.allocator, name);
        if (gop.found_existing) {
            const slot = gop.value_ptr.*;
            const old = loadSlot(slot);
            storeSlot(slot, def_box);
            self.retired.append(self.allocator, old) catch |err| {
                storeSlot(slot, old);
                self.allocator.destroy(def_box);
                return err;
            };
        } else {
            const slot = self.allocator.create(WordSlot) catch |err| {
                self.allocator.destroy(def_box);
                _ = self.entries.remove(name);
                return err;
            };
            slot.* = .{
                .name = name,
                .definition = std.atomic.Value(*word_slot_mod.WordDefinition).init(@ptrCast(def_box)),
            };
            gop.value_ptr.* = slot;
        }
    }

    pub fn get(self: *const Dictionary, name: []const u8) ?WordDefinition {
        const slot = self.entries.get(name) orelse return null;
        return loadSlot(slot).*;
    }

    pub fn getPtr(self: *const Dictionary, name: []const u8) ?*WordDefinition {
        const slot = self.entries.get(name) orelse return null;
        return loadSlot(slot);
    }

    /// Return the heap-stable `WordSlot` for `name`, or null if absent. The
    /// pointer is stable across rehash and across redefinition; pre-resolved
    /// callers carry it as the operand of a direct-call instruction.
    pub fn getSlot(self: *const Dictionary, name: []const u8) ?*WordSlot {
        return self.entries.get(name);
    }

    pub fn remove(self: *Dictionary, name: []const u8) bool {
        const removed = self.entries.fetchRemove(name) orelse return false;
        const slot = removed.value;
        const def = loadSlot(slot);
        self.retired.append(self.allocator, def) catch {
            // Reclamation is best-effort; on OOM the box stays leaked but
            // the slot itself is destroyed and the entry is gone.
        };
        self.allocator.destroy(slot);
        return true;
    }

    /// If `instructions` contains any container-variant `push_literal`,
    /// record the slice on the dictionary's release list.
    ///
    /// A word defined inside a parse-time body is re-defined with the same
    /// instruction slice on every invocation, but the captured literals carry
    /// one creation reference, so each distinct slice is recorded and
    /// released exactly once.
    pub fn registerCompoundBody(self: *Dictionary, instructions: []const Instruction) !void {
        if (!container_backing.instructionsHaveContainerLiteral(instructions)) return;
        for (self.container_release_list.items) |existing| {
            if (existing.ptr == instructions.ptr) return;
        }
        try self.container_release_list.append(self.allocator, instructions);
    }

    /// Release captured container literals from every registered
    /// compound body, then clear the list. Must be called before the
    /// arena that owns the instruction memory tears down.
    pub fn walkContainerReleaseList(self: *Dictionary) void {
        for (self.container_release_list.items) |instrs| {
            container_backing.releaseInstructionsContainerLiterals(instrs);
        }
        self.container_release_list.clearRetainingCapacity();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "dictionary put and get" {
    const allocator = std.testing.allocator;
    var dict = Dictionary.init(allocator);
    defer dict.deinit();

    // Create a simple test word
    const testFn: NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("test-word", .{
        .name = "test-word",
        .action = .{ .native = testFn },
    });

    const entry = dict.get("test-word");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("test-word", entry.?.name);
}

test "dictionary returns null for unknown word" {
    const allocator = std.testing.allocator;
    var dict = Dictionary.init(allocator);
    defer dict.deinit();

    try std.testing.expectEqual(null, dict.get("nonexistent"));
}

test "dictionary remove" {
    const allocator = std.testing.allocator;
    var dict = Dictionary.init(allocator);
    defer dict.deinit();

    const testFn: NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("removable", .{
        .name = "removable",
        .action = .{ .native = testFn },
    });
    try std.testing.expect(dict.get("removable") != null);

    try std.testing.expect(dict.remove("removable"));
    try std.testing.expectEqual(null, dict.get("removable"));

    try std.testing.expect(!dict.remove("nonexistent"));
}

test "parse_time flag defaults to false" {
    const testFn: NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    // Create word without specifying parse_time
    const word: WordDefinition = .{
        .name = "regular-word",
        .action = .{ .native = testFn },
    };

    try std.testing.expectEqual(false, word.parse_time);
}

test "parse_time flag can be set to true" {
    const testFn: NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    // Create parse-time word
    const word: WordDefinition = .{
        .name = "parse-time-word",
        .parse_time = true,
        .action = .{ .native = testFn },
    };

    try std.testing.expectEqual(true, word.parse_time);
}

test "registerCompoundBody: skips scalar-only bodies" {
    const allocator = std.testing.allocator;
    var dict = Dictionary.init(allocator);
    defer dict.deinit();

    const body = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0 },
        .{ .op = .{ .call_word = "drop" }, .line = 0 },
    };
    try dict.registerCompoundBody(&body);
    try std.testing.expectEqual(@as(usize, 0), dict.container_release_list.items.len);
}

test "dictionary slot address is stable across rehash" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const name_alloc = arena.allocator();

    var dict = Dictionary.init(allocator);
    defer dict.deinit();

    const testFn: NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("anchor", .{ .name = "anchor", .action = .{ .native = testFn } });
    const anchor_slot = dict.getSlot("anchor").?;

    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const name = try std.fmt.allocPrint(name_alloc, "filler-{d}", .{i});
        try dict.put(name, .{ .name = name, .action = .{ .native = testFn } });
    }

    try std.testing.expectEqual(anchor_slot, dict.getSlot("anchor").?);
}

test "dictionary redefinition swaps slot contents" {
    const allocator = std.testing.allocator;
    var dict = Dictionary.init(allocator);
    defer dict.deinit();

    const fnA: NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;
    const fnB: NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("target", .{ .name = "target", .action = .{ .native = fnA } });
    const slot_before = dict.getSlot("target").?;
    const def_before = loadSlot(slot_before);
    try std.testing.expectEqual(fnA, def_before.action.native);

    try dict.put("target", .{ .name = "target", .action = .{ .native = fnB } });
    const slot_after = dict.getSlot("target").?;
    try std.testing.expectEqual(slot_before, slot_after);
    try std.testing.expectEqual(fnB, loadSlot(slot_after).action.native);
    try std.testing.expectEqual(@as(usize, 1), dict.retired.items.len);
}

test "dictionary redefinition keeps retired definitions until deinit" {
    const allocator = std.testing.allocator;
    var dict = Dictionary.init(allocator);
    defer dict.deinit();

    const testFn: NativeFn = struct {
        fn f(_: *Context) anyerror!void {}
    }.f;

    try dict.put("churn", .{ .name = "churn", .action = .{ .native = testFn } });
    try dict.put("churn", .{ .name = "churn", .action = .{ .native = testFn } });
    try dict.put("churn", .{ .name = "churn", .action = .{ .native = testFn } });

    try std.testing.expectEqual(@as(usize, 2), dict.retired.items.len);
    try std.testing.expect(dict.get("churn") != null);
}

test "registerCompoundBody: records bodies with container literals" {
    const allocator = std.testing.allocator;
    var dict = Dictionary.init(allocator);
    defer dict.deinit();

    const dummy_vec = try value_mod.Vector.create(allocator);
    // One registration; walkContainerReleaseList will release the
    // embedded vector once. The create's rc=1 balances that release,
    // so dummy_vec is destroyed cleanly by the walk.
    const body = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .vector = dummy_vec } }, .line = 0 },
    };
    try dict.registerCompoundBody(&body);
    try std.testing.expectEqual(@as(usize, 1), dict.container_release_list.items.len);

    dict.walkContainerReleaseList();
    try std.testing.expectEqual(@as(usize, 0), dict.container_release_list.items.len);
}

test "literal action is not native-like or builtin-native" {
    const word: WordDefinition = .{
        .name = "x",
        .action = .{ .literal = .{ .fixnum = 5 } },
    };

    try std.testing.expectEqual(false, word.isNativeLike());
    try std.testing.expectEqual(false, word.isBuiltinNative());
}

test "literalOrCompoundAction picks .literal for a non-refcounted value" {
    const action = try WordDefinition.literalOrCompoundAction(std.testing.allocator, .{ .fixnum = 5 });
    switch (action) {
        .literal => |v| try std.testing.expectEqual(@as(i64, 5), v.fixnum),
        .compound, .native, .host_callback => try std.testing.expect(false),
    }
}

test "literalOrCompoundAction falls back to .compound for a container-backed value" {
    const allocator = std.testing.allocator;
    const dummy_vec = try value_mod.Vector.create(allocator);
    defer container_backing.releaseValue(.{ .vector = dummy_vec });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const action = try WordDefinition.literalOrCompoundAction(arena.allocator(), .{ .vector = dummy_vec });
    switch (action) {
        .compound => |instrs| {
            try std.testing.expectEqual(@as(usize, 1), instrs.len);
            try std.testing.expect(instrs[0].op.push_literal == .vector);
        },
        .literal, .native, .host_callback => try std.testing.expect(false),
    }
}
