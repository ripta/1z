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

/// Source location of a type declaration, stamped on every word the declaration generates so
/// introspection and the linter see the declaration site rather than the prelude quotation that
/// runs the `define-*` native.
pub const GenSrcLoc = struct {
    file: ?[]const u8 = null,
    line: usize = 0,
    column: usize = 0,
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
    /// The word itself. Borrowed, never owned: a native's is a static literal, a `;`-defined word's
    /// is the interned slice the context's `BindingNameStore` keeps until the root's teardown, and a
    /// generated word's is an arena copy.
    name: []const u8,
    /// Whether this word is a parse-time word.
    parse_time: bool = false,
    /// Whether this word can only be called during parse time.
    parse_time_only: bool = false,
    /// Whether this word was imported from another module.
    imported: bool = false,
    /// Stack effect annotation for this word, if any.
    ///
    /// Boxed so the address is stable however the definition is copied. A definition lives by
    /// value in `LocalFrame` and in a module's word map, where an interior pointer dies on the
    /// next rehash, and it is passed by value to `executeResolvedWord`, where one dies on return.
    ///
    /// The definition owns what the box points at too, so a holder may borrow the parameters.
    stack_effect: ?*const StackEffect = null,
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
    /// The closure a `.compound` body came out of, for a body it owns. Set by `;` and by
    /// `>module`, the two ways a closure becomes a word body. Borrowed: both park the owning
    /// reference on the dictionary's teardown list and keep only the instruction slice, so this
    /// pointer is what carries the body's captured scope and defining module to the call. Null for
    /// every body a module or the dictionary arena owns.
    body_owner: ?*const value_mod.Closure = null,
    /// The action performed by this word: either a native function or a
    /// compound quotation. Unfortunate naming.
    action: Action,

    /// Whether this definition holds an owning reference to `action.literal`.
    ///
    /// Set for a `name: swap ;` binding in a transient lexical frame, where the frame is the owner
    /// and drops the reference when it dies. Any copy of such a definition that outlives that frame
    /// takes a reference of its own and carries the flag with it.
    ///
    /// Every other definition leaves it false: a durable binding transfers its reference to the
    /// dictionary's teardown list instead, and no other action variant carries a value at all.
    owns_literal: bool = false,

    /// Either a native function, a host callback, a compound quotation body,
    /// or a directly-bound literal value.
    pub const Action = union(enum) {
        native: NativeFn,
        host_callback: HostCallback,
        compound: []const Instruction,
        /// A `name: swap ;`-style local or marker definition's bound value, stored directly with
        /// no `Instruction` slice allocated. A refcounted value is stored the same way; who owns
        /// its reference is recorded in `owns_literal` and decided by `Context.defineWordLocked`.
        literal: Value,
    };

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
        const saved_native = ctx.withCurrentNative(switch (self.action) {
            .native => self.name,
            .host_callback, .compound, .literal => null,
        });
        defer ctx.restoreCurrentNative(saved_native);

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
    /// Owning references adopted by word definitions whose memory must stay
    /// alive for the dictionary's lifetime -- a closure whose body became a
    /// word's compound action. Released at teardown alongside the container
    /// release list.
    retained_values: std.ArrayListUnmanaged(Value) = .{},

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
        self.retained_values.deinit(self.allocator);
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

    /// Remove a compound body recorded by `registerCompoundBody`, for a body
    /// whose embedded literals a retained value's own destroy releases instead.
    pub fn unregisterCompoundBody(self: *Dictionary, instructions: []const Instruction) void {
        var i: usize = 0;
        while (i < self.container_release_list.items.len) {
            if (self.container_release_list.items[i].ptr == instructions.ptr) {
                _ = self.container_release_list.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Adopt an owning reference that must survive until teardown. The caller
    /// transfers its reference; `releaseRetainedValues` drops it.
    pub fn retainValueForTeardown(self: *Dictionary, val: Value) !void {
        try self.retained_values.append(self.allocator, val);
    }

    /// Release every reference adopted by `retainValueForTeardown`, then clear
    /// the list. Called at context teardown alongside the release-list walk.
    pub fn releaseRetainedValues(self: *Dictionary) void {
        for (self.retained_values.items) |v| {
            container_backing.releaseValue(v);
        }
        self.retained_values.clearRetainingCapacity();
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

test "a definition defaults to not owning its literal" {
    const word = WordDefinition{
        .name = "x",
        .action = .{ .literal = .{ .fixnum = 5 } },
    };

    try std.testing.expectEqual(false, word.owns_literal);
}
