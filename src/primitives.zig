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
    func: NativeFn,
};

const Instruction = @import("value.zig").Instruction;

const primitives = [_]Primitive{
    .{ .name = "dup", .func = nativeDup },
    .{ .name = "drop", .func = nativeDrop },
    .{ .name = "+", .func = nativeAdd },
    .{ .name = "-", .func = nativeSub },
    .{ .name = "call", .func = nativeCall },
    .{ .name = ";", .func = nativeSemicolon },
    .{ .name = "t", .func = nativeTrue },
    .{ .name = "f", .func = nativeFalse },
    .{ .name = "=", .func = nativeEq },
    .{ .name = "<", .func = nativeLt },
    .{ .name = ">", .func = nativeGt },
    .{ .name = "if", .func = nativeIf },
    .{ .name = "when", .func = nativeWhen },
    .{ .name = "unless", .func = nativeUnless },
};

pub fn registerPrimitives(dict: *Dictionary) !void {
    for (primitives) |p| {
        try dict.put(p.name, WordDefinition{
            .name = p.name,
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

/// ; ( name: quot -- ) - Define a new word
fn nativeSemicolon(ctx: *Context) anyerror!void {
    const instrs = try popQuotation(ctx);
    const name = try popSymbol(ctx);
    try ctx.dictionary.put(name, WordDefinition{
        .name = name,
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

// =============================================================================
// Helper functions
// =============================================================================

fn popInteger(ctx: *Context) !i64 {
    const val = try ctx.stack.pop();
    return switch (val) {
        .integer => |i| i,
        .boolean, .symbol, .quotation => error.TypeError,
    };
}

fn popBoolean(ctx: *Context) !bool {
    const val = try ctx.stack.pop();
    return switch (val) {
        .boolean => |b| b,
        .integer => |i| i != 0,
        .symbol, .quotation => error.TypeError,
    };
}

fn popQuotation(ctx: *Context) ![]const Instruction {
    const val = try ctx.stack.pop();
    return switch (val) {
        .quotation => |q| q,
        .integer, .boolean, .symbol => error.TypeError,
    };
}

fn popSymbol(ctx: *Context) ![]const u8 {
    const val = try ctx.stack.pop();
    return switch (val) {
        .symbol => |s| s,
        .integer, .boolean, .quotation => error.TypeError,
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
}
