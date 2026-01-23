const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("context.zig").Context;
const Instruction = @import("value.zig").Instruction;
const StackEffect = @import("stack_effect.zig").StackEffect;

/// Native function signature: takes context, can return errors.
pub const NativeFn = *const fn (ctx: *Context) anyerror!void;

/// Visibility of a word within a module.
pub const Visibility = enum {
    /// Private words are only accessible within the module where they are defined.
    private,
    /// Public words can be accessed from other modules via use: or qualified names.
    public,
};

/// Word definition: either a native function or compound quotation.
pub const WordDefinition = struct {
    name: []const u8,
    parse_time: bool = false,
    stack_effect: ?StackEffect = null,
    visibility: Visibility = .private,
    action: union(enum) {
        native: NativeFn,
        compound: []const Instruction,
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
