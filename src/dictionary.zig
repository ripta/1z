const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("context.zig").Context;
const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const Marker = value_mod.Marker;
const StackEffect = @import("stack_effect.zig").StackEffect;
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
    /// The action performed by this word: either a native function or a
    /// compound quotation. Unfortunate naming.
    action: union(enum) {
        native: NativeFn,
        host_callback: HostCallback,
        compound: []const Instruction,
    },

    /// Returns true if this word is a native function or host callback, i.e., not a compound quotation.
    pub fn isNativeLike(self: WordDefinition) bool {
        return switch (self.action) {
            .native, .host_callback => true,
            .compound => false,
        };
    }

    /// Returns true if this word is a built-in native function.
    pub fn isBuiltinNative(self: WordDefinition) bool {
        return switch (self.action) {
            .native => true,
            .host_callback, .compound => false,
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
            .compound => unreachable,
        }
    }
};

/// Dictionary maps word names to their definitions.
pub const Dictionary = struct {
    entries: std.StringHashMapUnmanaged(WordDefinition),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Dictionary {
        return .{
            .entries = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Dictionary) void {
        self.entries.deinit(self.allocator);
    }

    pub fn put(self: *Dictionary, name: []const u8, definition: WordDefinition) !void {
        try self.entries.put(self.allocator, name, definition);
    }

    pub fn get(self: *const Dictionary, name: []const u8) ?WordDefinition {
        return self.entries.get(name);
    }

    pub fn getPtr(self: *const Dictionary, name: []const u8) ?*WordDefinition {
        return self.entries.getPtr(name);
    }

    pub fn remove(self: *Dictionary, name: []const u8) bool {
        return self.entries.remove(name);
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
