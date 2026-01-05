const std = @import("std");
const Context = @import("context.zig").Context;
const Value = @import("value.zig").Value;
const Dictionary = @import("dictionary.zig").Dictionary;
const WordDefinition = @import("dictionary.zig").WordDefinition;
const NativeFn = @import("dictionary.zig").NativeFn;

pub const InterpreterError = error{
    StackUnderflow,
    TypeError,
    DivisionByZero,
};

const Primitive = struct {
    name: []const u8,
    stack_effect: ?[]const u8 = null,
    func: NativeFn,
};

const Instruction = @import("value.zig").Instruction;

const primitives = [_]Primitive{
    .{ .name = "dup", .stack_effect = "a -- a a", .func = nativeDup },
    .{ .name = "drop", .stack_effect = "a --", .func = nativeDrop },
    .{ .name = "+", .stack_effect = "a b -- a+b", .func = nativeAdd },
    .{ .name = "-", .stack_effect = "a b -- a-b", .func = nativeSub },
    .{ .name = "call", .stack_effect = "quot --", .func = nativeCall },
    .{ .name = ";", .stack_effect = "name quot --", .func = nativeSemicolon },
    .{ .name = "t", .stack_effect = "-- t", .func = nativeTrue },
    .{ .name = "f", .stack_effect = "-- f", .func = nativeFalse },
    .{ .name = "=", .stack_effect = "a b -- ?", .func = nativeEq },
    .{ .name = "<", .stack_effect = "a b -- ?", .func = nativeLt },
    .{ .name = ">", .stack_effect = "a b -- ?", .func = nativeGt },
    .{ .name = "if", .stack_effect = "? true-quot false-quot --", .func = nativeIf },
    .{ .name = "when", .stack_effect = "? quot --", .func = nativeWhen },
    .{ .name = "unless", .stack_effect = "? quot --", .func = nativeUnless },
    .{ .name = "print", .stack_effect = "a --", .func = nativePrint },
    .{ .name = ".", .stack_effect = "a --", .func = nativePrint },
    .{ .name = "help", .stack_effect = "name --", .func = nativeHelp },
    .{ .name = "recover", .stack_effect = "try-quot recover-quot --", .func = nativeRecover },
    .{ .name = "ignore-errors", .stack_effect = "quot --", .func = nativeIgnoreErrors },
};

pub fn registerPrimitives(dict: *Dictionary) !void {
    for (primitives) |p| {
        try dict.put(p.name, WordDefinition{
            .name = p.name,
            .stack_effect = p.stack_effect,
            .action = .{ .native = p.func },
        });
    }
}

// =============================================================================
// Primitive implementations
// =============================================================================

/// dup ( a -- a a ) - Duplicate top of stack
fn nativeDup(ctx: *Context) anyerror!void {
    const val = try ctx.stack.peek();
    try ctx.stack.push(val);
}

/// drop ( a -- ) - Remove top of stack
fn nativeDrop(ctx: *Context) anyerror!void {
    _ = try ctx.stack.pop();
}

/// + ( a b -- a+b ) - Add two integers
fn nativeAdd(ctx: *Context) anyerror!void {
    const b = try popInteger(ctx);
    const a = try popInteger(ctx);
    try ctx.stack.push(.{ .integer = a + b });
}

/// - ( a b -- a-b ) - Subtract: a minus b
fn nativeSub(ctx: *Context) anyerror!void {
    const b = try popInteger(ctx);
    const a = try popInteger(ctx);
    try ctx.stack.push(.{ .integer = a - b });
}

/// call ( quot -- ) - Execute a quotation
fn nativeCall(ctx: *Context) anyerror!void {
    const instrs = try popQuotation(ctx);
    try ctx.executeQuotation(instrs);
}

/// ; ( name: quot -- ) or ( name: ( effect ) quot -- ) - Define a new word
fn nativeSemicolon(ctx: *Context) anyerror!void {
    const instrs = try popQuotation(ctx);

    // Check if there's a stack effect between symbol and quotation
    var stack_effect_str: ?[]const u8 = null;
    const next_val = try ctx.stack.peek();
    switch (next_val) {
        .stack_effect => |se| {
            _ = try ctx.stack.pop();
            stack_effect_str = se;
        },
        else => {},
    }

    const name = try popSymbol(ctx);
    // Copy name to arena so it persists after input buffer is reused
    const name_copy = try ctx.quotationAllocator().dupe(u8, name);

    // Copy stack effect if present
    var effect_copy: ?[]const u8 = null;
    if (stack_effect_str) |se| {
        effect_copy = try ctx.quotationAllocator().dupe(u8, se);
    }

    try ctx.dictionary.put(name_copy, WordDefinition{
        .name = name_copy,
        .stack_effect = effect_copy,
        .action = .{ .compound = instrs },
    });
}

fn nativeTrue(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .boolean = true });
}

fn nativeFalse(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .boolean = false });
}

/// = ( a b -- ? ) - Equality comparison
fn nativeEq(ctx: *Context) anyerror!void {
    const b = try popInteger(ctx);
    const a = try popInteger(ctx);
    try ctx.stack.push(.{ .boolean = a == b });
}

/// < ( a b -- ? ) - Less than
fn nativeLt(ctx: *Context) anyerror!void {
    const b = try popInteger(ctx);
    const a = try popInteger(ctx);
    try ctx.stack.push(.{ .boolean = a < b });
}

/// > ( a b -- ? ) - Greater than
fn nativeGt(ctx: *Context) anyerror!void {
    const b = try popInteger(ctx);
    const a = try popInteger(ctx);
    try ctx.stack.push(.{ .boolean = a > b });
}

/// if ( ? true-quot false-quot -- ) - Conditional execution
fn nativeIf(ctx: *Context) anyerror!void {
    const false_quot = try popQuotation(ctx);
    const true_quot = try popQuotation(ctx);
    const cond = try popBoolean(ctx);
    try ctx.executeQuotation(if (cond) true_quot else false_quot);
}

/// when ( ? quot -- ) - Execute quotation if true
fn nativeWhen(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const cond = try popBoolean(ctx);
    if (cond) try ctx.executeQuotation(quot);
}

/// unless ( ? quot -- ) - Execute quotation if false
fn nativeUnless(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const cond = try popBoolean(ctx);
    if (!cond) try ctx.executeQuotation(quot);
}

/// print ( a -- ) - Print top of stack to stdout
fn nativePrint(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const stdout_file: std.fs.File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writer(&stdout_buf);
    try val.format(&stdout.interface);
    try stdout.interface.writeAll("\n");
    try stdout.interface.flush();
}

/// help ( symbol -- ) - Display help for a word
fn nativeHelp(ctx: *Context) anyerror!void {
    const name = try popSymbol(ctx);

    const stdout_file: std.fs.File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writer(&stdout_buf);
    const writer = &stdout.interface;

    if (ctx.dictionary.get(name)) |word| {
        try writer.print("{s}", .{word.name});
        if (word.stack_effect) |effect| {
            try writer.print(" ( {s} )", .{effect});
        }

        switch (word.action) {
            .native => try writer.writeAll(" \\native\n"),
            .compound => try writer.writeAll(" [compound]\n"),
        }
    } else {
        try writer.print("{s}: no such word\n", .{name});
    }

    try stdout.interface.flush();
}

/// recover ( try-quot recover-quot -- ) - Execute try quotation; if error,
/// execute recover quotation with error on stack
fn nativeRecover(ctx: *Context) anyerror!void {
    const recover_quot = try popQuotation(ctx);
    const try_quot = try popQuotation(ctx);

    // Execute try quotation with error catching
    ctx.executeQuotation(try_quot) catch |err| {
        // Convert error to string and push as error value
        const error_msg = @errorName(err);
        try ctx.stack.push(.{ .error_value = error_msg });

        // Execute recovery quotation
        try ctx.executeQuotation(recover_quot);
        return;
    };

    // If no error, continue normally
}

/// ignore-errors ( quot -- ) - Execute quotation and suppress any errors
fn nativeIgnoreErrors(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);

    // Execute quotation, ignoring any errors
    ctx.executeQuotation(quot) catch {
        // Silently ignore the error
    };
}

// =============================================================================
// Helper functions
// =============================================================================

fn popInteger(ctx: *Context) !i64 {
    const val = try ctx.stack.pop();
    return switch (val) {
        .integer => |i| i,
        .boolean, .string, .symbol, .array, .quotation, .stack_effect, .error_value => error.TypeError,
    };
}

fn popBoolean(ctx: *Context) !bool {
    const val = try ctx.stack.pop();
    return switch (val) {
        .boolean => |b| b,
        .integer => |i| i != 0,
        .string, .symbol, .array, .quotation, .stack_effect, .error_value => error.TypeError,
    };
}

fn popQuotation(ctx: *Context) ![]const Instruction {
    const val = try ctx.stack.pop();
    return switch (val) {
        .quotation => |q| q,
        .integer, .boolean, .string, .symbol, .array, .stack_effect, .error_value => error.TypeError,
    };
}

fn popSymbol(ctx: *Context) ![]const u8 {
    const val = try ctx.stack.pop();
    return switch (val) {
        .symbol => |s| s,
        .integer, .boolean, .string, .array, .quotation, .stack_effect, .error_value => error.TypeError,
    };
}

fn popStackEffect(ctx: *Context) ![]const u8 {
    const val = try ctx.stack.pop();
    return switch (val) {
        .stack_effect => |se| se,
        .integer, .boolean, .string, .symbol, .array, .quotation, .error_value => error.TypeError,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "dup" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 42 });
    try nativeDup(&ctx);

    try std.testing.expectEqual(@as(usize, 2), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 42), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 42), (try ctx.stack.pop()).integer);
}

test "drop" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 1 });
    try ctx.stack.push(.{ .integer = 2 });
    try nativeDrop(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).integer);
}

test "add" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 3 });
    try ctx.stack.push(.{ .integer = 4 });
    try nativeAdd(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 7), (try ctx.stack.pop()).integer);
}

test "sub" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 10 });
    try ctx.stack.push(.{ .integer = 3 });
    try nativeSub(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 7), (try ctx.stack.pop()).integer);
}

test "call executes quotation" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const instrs = [_]Instruction{
        .{ .push_literal = .{ .integer = 1 } },
        .{ .push_literal = .{ .integer = 2 } },
        .{ .call_word = "+" },
    };
    try ctx.stack.push(.{ .quotation = &instrs });
    try nativeCall(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 3), (try ctx.stack.pop()).integer);
}

test "semicolon defines word" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const instrs = [_]Instruction{
        .{ .push_literal = .{ .integer = 2 } },
        .{ .call_word = "+" },
    };
    try ctx.stack.push(.{ .symbol = "add2" });
    try ctx.stack.push(.{ .quotation = &instrs });
    try nativeSemicolon(&ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
    const word = ctx.dictionary.get("add2");
    try std.testing.expect(word != null);
    try std.testing.expectEqual(@as(?[]const u8, null), word.?.stack_effect);
}

test "semicolon defines word with stack effect" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const instrs = [_]Instruction{
        .{ .push_literal = .{ .integer = 2 } },
        .{ .call_word = "+" },
    };
    try ctx.stack.push(.{ .symbol = "add2" });
    try ctx.stack.push(.{ .stack_effect = "n -- n" });
    try ctx.stack.push(.{ .quotation = &instrs });
    try nativeSemicolon(&ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
    const word = ctx.dictionary.get("add2");
    try std.testing.expect(word != null);
    try std.testing.expect(word.?.stack_effect != null);
    try std.testing.expectEqualStrings("n -- n", word.?.stack_effect.?);
}

test "if true branch" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const true_quot = [_]Instruction{.{ .push_literal = .{ .integer = 1 } }};
    const false_quot = [_]Instruction{.{ .push_literal = .{ .integer = 2 } }};
    try ctx.stack.push(.{ .boolean = true });
    try ctx.stack.push(.{ .quotation = &true_quot });
    try ctx.stack.push(.{ .quotation = &false_quot });
    try nativeIf(&ctx);

    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).integer);
}

test "if false branch" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const true_quot = [_]Instruction{.{ .push_literal = .{ .integer = 1 } }};
    const false_quot = [_]Instruction{.{ .push_literal = .{ .integer = 2 } }};
    try ctx.stack.push(.{ .boolean = false });
    try ctx.stack.push(.{ .quotation = &true_quot });
    try ctx.stack.push(.{ .quotation = &false_quot });
    try nativeIf(&ctx);

    try std.testing.expectEqual(@as(i64, 2), (try ctx.stack.pop()).integer);
}

test "when executes on true" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const quot = [_]Instruction{.{ .push_literal = .{ .integer = 42 } }};
    try ctx.stack.push(.{ .boolean = true });
    try ctx.stack.push(.{ .quotation = &quot });
    try nativeWhen(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 42), (try ctx.stack.pop()).integer);
}

test "when skips on false" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const quot = [_]Instruction{.{ .push_literal = .{ .integer = 42 } }};
    try ctx.stack.push(.{ .boolean = false });
    try ctx.stack.push(.{ .quotation = &quot });
    try nativeWhen(&ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
}

test "comparison operators" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 5 });
    try ctx.stack.push(.{ .integer = 5 });
    try nativeEq(&ctx);
    try std.testing.expectEqual(true, (try ctx.stack.pop()).boolean);

    try ctx.stack.push(.{ .integer = 3 });
    try ctx.stack.push(.{ .integer = 5 });
    try nativeLt(&ctx);
    try std.testing.expectEqual(true, (try ctx.stack.pop()).boolean);

    try ctx.stack.push(.{ .integer = 5 });
    try ctx.stack.push(.{ .integer = 3 });
    try nativeGt(&ctx);
    try std.testing.expectEqual(true, (try ctx.stack.pop()).boolean);
}

test "register primitives" {
    const allocator = std.testing.allocator;
    var dict = Dictionary.init(allocator);
    defer dict.deinit();

    try registerPrimitives(&dict);

    try std.testing.expect(dict.get("dup") != null);
    try std.testing.expect(dict.get("+") != null);
    try std.testing.expect(dict.get("-") != null);
    try std.testing.expect(dict.get("drop") != null);
    try std.testing.expect(dict.get("call") != null);
    try std.testing.expect(dict.get(";") != null);
    try std.testing.expect(dict.get("if") != null);
    try std.testing.expect(dict.get("when") != null);
    try std.testing.expect(dict.get("unless") != null);
    try std.testing.expect(dict.get("print") != null);
    try std.testing.expect(dict.get(".") != null);
    try std.testing.expect(dict.get("recover") != null);
    try std.testing.expect(dict.get("ignore-errors") != null);
}

test "recover catches error and executes recovery" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Try quotation that causes stack underflow, recovery pushes 42
    const try_quot = [_]Instruction{.{ .call_word = "drop" }}; // Stack underflow
    const recover_quot = [_]Instruction{
        .{ .call_word = "drop" }, // Drop the error value
        .{ .push_literal = .{ .integer = 42 } },
    };
    try ctx.stack.push(.{ .quotation = &try_quot });
    try ctx.stack.push(.{ .quotation = &recover_quot });
    try nativeRecover(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 42), (try ctx.stack.pop()).integer);
}

test "recover succeeds without error" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Try quotation succeeds
    const try_quot = [_]Instruction{.{ .push_literal = .{ .integer = 100 } }};
    const recover_quot = [_]Instruction{.{ .push_literal = .{ .integer = 42 } }};
    try ctx.stack.push(.{ .quotation = &try_quot });
    try ctx.stack.push(.{ .quotation = &recover_quot });
    try nativeRecover(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 100), (try ctx.stack.pop()).integer);
}

test "recover pushes error value on failure" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Try quotation fails, recovery just leaves error on stack
    const try_quot = [_]Instruction{.{ .call_word = "drop" }}; // Stack underflow
    const recover_quot = [_]Instruction{}; // Do nothing, leave error on stack
    try ctx.stack.push(.{ .quotation = &try_quot });
    try ctx.stack.push(.{ .quotation = &recover_quot });
    try nativeRecover(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const val = try ctx.stack.pop();
    try std.testing.expectEqualStrings("StackUnderflow", val.error_value);
}

test "ignore-errors suppresses error" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Quotation that causes stack underflow
    const quot = [_]Instruction{.{ .call_word = "drop" }};
    try ctx.stack.push(.{ .quotation = &quot });
    try nativeIgnoreErrors(&ctx);

    // Stack should be empty, no error propagated
    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
}

test "ignore-errors allows success" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Quotation that succeeds
    const quot = [_]Instruction{.{ .push_literal = .{ .integer = 42 } }};
    try ctx.stack.push(.{ .quotation = &quot });
    try nativeIgnoreErrors(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 42), (try ctx.stack.pop()).integer);
}
