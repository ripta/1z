const std = @import("std");
const Allocator = std.mem.Allocator;

const dictionary_mod = @import("dictionary.zig");
const WordDefinition = dictionary_mod.WordDefinition;

/// Module represents a namespace for word definitions.
/// Modules form a tree structure where each module can have submodules.
pub const Module = struct {
    /// Full path name: "math", "math/rand", etc.
    name: []const u8,
    /// Words defined in this module (word name -> definition)
    words: std.StringHashMapUnmanaged(WordDefinition),
    /// Submodules (segment name -> module)
    submodules: std.StringHashMapUnmanaged(*Module),
    /// Parent module (null for root modules)
    parent: ?*Module,
    /// Allocator used for this module
    allocator: Allocator,

    /// Initialize a new module with the given name.
    pub fn init(allocator: Allocator, name: []const u8, parent: ?*Module) !*Module {
        const self = try allocator.create(Module);
        self.* = Module{
            .name = name,
            .words = .{},
            .submodules = .{},
            .parent = parent,
            .allocator = allocator,
        };
        return self;
    }

    /// Free all resources used by this module.
    pub fn deinit(self: *Module) void {
        // Deinit all submodules recursively
        var sub_iter = self.submodules.valueIterator();
        while (sub_iter.next()) |sub| {
            sub.*.deinit();
        }
        self.submodules.deinit(self.allocator);
        self.words.deinit(self.allocator);
        // Free the name if it was allocated (contains '/')
        if (std.mem.indexOfScalar(u8, self.name, '/') != null) {
            self.allocator.free(self.name);
        }
        self.allocator.destroy(self);
    }

    /// Define a word in this module.
    pub fn defineWord(self: *Module, name: []const u8, definition: WordDefinition) !void {
        try self.words.put(self.allocator, name, definition);
    }

    /// Look up a word in this module (not searching parent).
    pub fn getWord(self: *const Module, name: []const u8) ?WordDefinition {
        return self.words.get(name);
    }

    /// Get or create a submodule by name segment.
    pub fn getOrCreateSubmodule(self: *Module, segment: []const u8) !*Module {
        if (self.submodules.get(segment)) |existing| {
            return existing;
        }

        // Build full path for new submodule
        const full_name = if (self.name.len == 0)
            try self.allocator.dupe(u8, segment)
        else
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.name, segment });

        const sub = try Module.init(self.allocator, full_name, self);
        try self.submodules.put(self.allocator, segment, sub);
        return sub;
    }

    /// Get a submodule by name segment (returns null if not found).
    pub fn getSubmodule(self: *const Module, segment: []const u8) ?*Module {
        return self.submodules.get(segment);
    }

    /// Iterate over all exported words in this module.
    pub fn exportedWords(self: *const Module) ExportedWordsIterator {
        return ExportedWordsIterator{ .inner = self.words.iterator() };
    }

    pub const ExportedWordsIterator = struct {
        inner: std.StringHashMapUnmanaged(WordDefinition).Iterator,

        pub fn next(self: *ExportedWordsIterator) ?struct { key: []const u8, value: WordDefinition } {
            while (self.inner.next()) |entry| {
                if (entry.value_ptr.visibility == .public) {
                    return .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* };
                }
            }
            return null;
        }
    };
};

// =============================================================================
// Tests
// =============================================================================

test "module init and deinit" {
    const allocator = std.testing.allocator;

    const root = try Module.init(allocator, "math", null);
    defer root.deinit();

    try std.testing.expectEqualStrings("math", root.name);
    try std.testing.expect(root.parent == null);
}

test "module define and get word" {
    const allocator = std.testing.allocator;

    const mod = try Module.init(allocator, "test", null);
    defer mod.deinit();

    const testFn: dictionary_mod.NativeFn = struct {
        fn f(_: *@import("context.zig").Context) anyerror!void {}
    }.f;

    try mod.defineWord("foo", .{
        .name = "foo",
        .action = .{ .native = testFn },
        .visibility = .public,
    });

    const word = mod.getWord("foo");
    try std.testing.expect(word != null);
    try std.testing.expectEqualStrings("foo", word.?.name);
}

test "module submodule creation" {
    const allocator = std.testing.allocator;

    const root = try Module.init(allocator, "math", null);
    defer root.deinit();

    const rand = try root.getOrCreateSubmodule("rand");

    try std.testing.expectEqualStrings("math/rand", rand.name);
    try std.testing.expect(rand.parent == root);

    // Getting the same submodule again returns the same instance
    const rand2 = try root.getOrCreateSubmodule("rand");
    try std.testing.expect(rand == rand2);
}

test "module nested submodules" {
    const allocator = std.testing.allocator;

    const root = try Module.init(allocator, "core", null);
    defer root.deinit();

    const collections = try root.getOrCreateSubmodule("collections");
    const hash = try collections.getOrCreateSubmodule("hash");

    try std.testing.expectEqualStrings("core/collections", collections.name);
    try std.testing.expectEqualStrings("core/collections/hash", hash.name);
}
