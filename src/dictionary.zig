const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("context.zig").Context;

/// Native function signature: takes context, can return errors.
pub const NativeFn = *const fn (ctx: *Context) anyerror!void;

/// Word definition: either a native function or compound quotation.
pub const WordDefinition = struct {
    name: []const u8,
    parse_time: bool = false,
    action: union(enum) {
        native: NativeFn,
    },
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
