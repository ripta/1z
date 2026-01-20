const std = @import("std");
const Allocator = std.mem.Allocator;

const Context = @import("context.zig").Context;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const HashTable = value_mod.HashTable;
const ErrorObject = value_mod.ErrorObject;
const StackFrame = value_mod.StackFrame;

const Dictionary = @import("dictionary.zig").Dictionary;
const WordDefinition = @import("dictionary.zig").WordDefinition;
const NativeFn = @import("dictionary.zig").NativeFn;
const StackEffect = @import("stack_effect.zig").StackEffect;
const StackEffectParam = @import("stack_effect.zig").StackEffectParam;
const StatementProcessor = @import("statement.zig").StatementProcessor;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const parser = @import("parser.zig");

pub const InterpreterError = error{
    StackUnderflow,
    TypeError,
    DivisionByZero,
    IntegerOverflow,
    FileNotFound,
    FileReadError,
    NoTokenizerAvailable,
    InvalidHashSyntax,
    RethrowError,
};

/// Helper to create a stack effect from a raw string at runtime.
/// Supports quotation annotations like "seq quot: ( elem -- elem' ) -- seq'"
fn makeSimpleEffect(allocator: Allocator, raw: []const u8) !StackEffect {
    var inputs: std.ArrayListUnmanaged(StackEffectParam) = .{};
    errdefer inputs.deinit(allocator);
    var outputs: std.ArrayListUnmanaged(StackEffectParam) = .{};
    errdefer outputs.deinit(allocator);

    var iter = std.mem.splitScalar(u8, raw, ' ');
    var current_list = &inputs;
    var pending_name: ?[]const u8 = null;

    while (iter.next()) |token| {
        if (token.len == 0) continue;

        if (std.mem.eql(u8, token, "--")) {
            // Flush pending parameter
            if (pending_name) |name| {
                try current_list.append(allocator, .{ .name = name });
                pending_name = null;
            }
            current_list = &outputs;
            continue;
        }

        if (std.mem.eql(u8, token, "(")) {
            // Start of nested effect - parse until matching )
            if (pending_name) |name| {
                var nested_tokens: std.ArrayListUnmanaged([]const u8) = .{};
                defer nested_tokens.deinit(allocator);
                var depth: usize = 1;

                while (iter.next()) |nested_token| {
                    if (std.mem.eql(u8, nested_token, "(")) {
                        depth += 1;
                        try nested_tokens.append(allocator, nested_token);
                    } else if (std.mem.eql(u8, nested_token, ")")) {
                        depth -= 1;
                        if (depth == 0) break;
                        try nested_tokens.append(allocator, nested_token);
                    } else {
                        try nested_tokens.append(allocator, nested_token);
                    }
                }

                // Join and recursively parse (don't free nested_str - arena will handle it)
                const nested_str = try std.mem.join(allocator, " ", nested_tokens.items);
                const nested_effect = try makeSimpleEffect(allocator, nested_str);
                const nested_ptr = try allocator.create(StackEffect);
                nested_ptr.* = nested_effect;

                try current_list.append(allocator, .{
                    .name = name,
                    .quotation_effect = nested_ptr,
                });
                pending_name = null;
            }
            continue;
        }

        // Flush previous pending parameter
        if (pending_name) |name| {
            try current_list.append(allocator, .{ .name = name });
        }

        // Check if this token ends with : (annotation marker)
        if (token.len > 1 and token[token.len - 1] == ':') {
            pending_name = token[0 .. token.len - 1];
        } else {
            pending_name = token;
        }
    }

    // Flush final pending parameter
    if (pending_name) |name| {
        try current_list.append(allocator, .{ .name = name });
    }

    return StackEffect{
        .inputs = try inputs.toOwnedSlice(allocator),
        .outputs = try outputs.toOwnedSlice(allocator),
    };
}

const Primitive = struct {
    name: []const u8,
    stack_effect: ?[]const u8 = null,
    func: NativeFn,
    parse_time: bool = false,
};

const Instruction = @import("value.zig").Instruction;

const primitives = [_]Primitive{
    .{ .name = "dup", .stack_effect = "a -- a a", .func = nativeDup },
    .{ .name = "drop", .stack_effect = "a --", .func = nativeDrop },
    .{ .name = "swap", .stack_effect = "a b -- b a", .func = nativeSwap },
    .{ .name = "over", .stack_effect = "x y -- x y x", .func = nativeOver },
    .{ .name = "dip", .stack_effect = "x quot -- x", .func = nativeDip },
    .{ .name = "+", .stack_effect = "a b -- a+b", .func = nativeAdd },
    .{ .name = "-", .stack_effect = "a b -- a-b", .func = nativeSub },
    .{ .name = "*", .stack_effect = "a b -- a*b", .func = nativeMul },
    .{ .name = "/", .stack_effect = "a b -- a/b", .func = nativeDiv },
    .{ .name = "%", .stack_effect = "a b -- a%b", .func = nativeMod },
    .{ .name = "+%", .stack_effect = "a b -- a+b", .func = nativeAddWrap },
    .{ .name = "-%", .stack_effect = "a b -- a-b", .func = nativeSubWrap },
    .{ .name = "*%", .stack_effect = "a b -- a*b", .func = nativeMulWrap },
    .{ .name = "call", .stack_effect = "quot --", .func = nativeCall },
    .{ .name = ";", .stack_effect = "name quot --", .func = nativeSemicolon },
    .{ .name = "t", .stack_effect = "-- t", .func = nativeTrue },
    .{ .name = "f", .stack_effect = "-- f", .func = nativeFalse },
    .{ .name = "=", .stack_effect = "a b -- ?", .func = nativeEq },
    .{ .name = "<", .stack_effect = "a b -- ?", .func = nativeLt },
    .{ .name = ">", .stack_effect = "a b -- ?", .func = nativeGt },
    .{ .name = "if", .stack_effect = "? true-quot false-quot --", .func = nativeIf },
    .{ .name = "print", .stack_effect = "str --", .func = nativePrint },
    .{ .name = ".", .stack_effect = "a --", .func = nativeDot },
    .{ .name = "help", .stack_effect = "name --", .func = nativeHelp },
    .{ .name = "recover", .stack_effect = "try-quot recover-quot: ( error -- ) --", .func = nativeRecover },
    .{ .name = "cleanup", .stack_effect = "body-quot cleanup-quot --", .func = nativeCleanup },
    .{ .name = "rethrow", .stack_effect = "error --", .func = nativeRethrow },
    .{ .name = "load", .stack_effect = "filename --", .func = nativeLoad },
    .{ .name = "parse-time", .stack_effect = "-- marker", .func = nativeParseTime },
    .{ .name = "parse-until", .stack_effect = "delimiter -- quotation", .func = nativeParseUntil },
    .{ .name = "make-hash", .stack_effect = "quotation -- hash", .func = nativeMakeHash },
};

pub fn registerPrimitives(dict: *Dictionary, allocator: Allocator) !void {
    for (primitives) |p| {
        const effect: ?StackEffect = if (p.stack_effect) |raw|
            try makeSimpleEffect(allocator, raw)
        else
            null;

        try dict.put(p.name, WordDefinition{
            .name = p.name,
            .parse_time = p.parse_time,
            .stack_effect = effect,
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

/// swap ( a b -- b a ) - Swap top two items
fn nativeSwap(ctx: *Context) anyerror!void {
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    try ctx.stack.push(b);
    try ctx.stack.push(a);
}

/// over ( x y -- x y x ) - Copy second item to top
fn nativeOver(ctx: *Context) anyerror!void {
    const y = try ctx.stack.pop();
    const x = try ctx.stack.peek();
    try ctx.stack.push(y);
    try ctx.stack.push(x);
}

/// dip ( x quot -- x ) - Execute quotation with x temporarily removed
fn nativeDip(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);
    const x = try ctx.stack.pop();
    try ctx.executeQuotation(quot);
    try ctx.stack.push(x);
}

/// + ( a b -- a+b ) - Add two integers
fn nativeAdd(ctx: *Context) anyerror!void {
    const b = try popInteger(ctx);
    const a = try popInteger(ctx);
    const result = @addWithOverflow(a, b);
    if (result[1] != 0) return error.IntegerOverflow;
    try ctx.stack.push(.{ .integer = result[0] });
}

/// - ( a b -- a-b ) - Subtract: a minus b
fn nativeSub(ctx: *Context) anyerror!void {
    const b = try popInteger(ctx);
    const a = try popInteger(ctx);
    const result = @subWithOverflow(a, b);
    if (result[1] != 0) return error.IntegerOverflow;
    try ctx.stack.push(.{ .integer = result[0] });
}

/// * ( a b -- a*b ) - Multiply two integers
fn nativeMul(ctx: *Context) anyerror!void {
    const b = try popInteger(ctx);
    const a = try popInteger(ctx);
    const result = @mulWithOverflow(a, b);
    if (result[1] != 0) return error.IntegerOverflow;
    try ctx.stack.push(.{ .integer = result[0] });
}

/// / ( a b -- a/b ) - Integer division
fn nativeDiv(ctx: *Context) anyerror!void {
    const b = try popInteger(ctx);
    const a = try popInteger(ctx);
    if (b == 0) return error.DivisionByZero;
    if (a == std.math.minInt(i64) and b == -1) return error.IntegerOverflow;
    try ctx.stack.push(.{ .integer = @divTrunc(a, b) });
}

/// % ( a b -- a%b ) - Modulo (remainder)
fn nativeMod(ctx: *Context) anyerror!void {
    const b = try popInteger(ctx);
    const a = try popInteger(ctx);
    if (b == 0) return error.DivisionByZero;
    try ctx.stack.push(.{ .integer = @mod(a, b) });
}

/// +% ( a b -- a+b ) - Add two integers with wraparound on overflow
fn nativeAddWrap(ctx: *Context) anyerror!void {
    const b = try popInteger(ctx);
    const a = try popInteger(ctx);
    try ctx.stack.push(.{ .integer = a +% b });
}

/// -% ( a b -- a-b ) - Subtract with wraparound on overflow
fn nativeSubWrap(ctx: *Context) anyerror!void {
    const b = try popInteger(ctx);
    const a = try popInteger(ctx);
    try ctx.stack.push(.{ .integer = a -% b });
}

/// *% ( a b -- a*b ) - Multiply with wraparound on overflow
fn nativeMulWrap(ctx: *Context) anyerror!void {
    const b = try popInteger(ctx);
    const a = try popInteger(ctx);
    try ctx.stack.push(.{ .integer = a *% b });
}

/// call ( quot -- ) - Execute a quotation
fn nativeCall(ctx: *Context) anyerror!void {
    const instrs = try popQuotation(ctx);
    try ctx.executeQuotation(instrs);
}

/// ; ( name: quot -- ) or ( name: ( effect ) quot -- ) or ( name: parse-time quot -- ) - Define a new word
fn nativeSemicolon(ctx: *Context) anyerror!void {
    const instrs = try popQuotation(ctx);

    // Check for optional metadata (stack effect and/or parse-time marker)
    // Stack could be: symbol quot
    //            or: symbol stack-effect quot
    //            or: symbol parse-time quot
    //            or: symbol parse-time stack-effect quot
    var stack_effect_val: ?StackEffect = null;
    var is_parse_time = false;

    // Loop to collect metadata until we find the symbol
    while (true) {
        const next_val = try ctx.stack.peek();
        switch (next_val) {
            .stack_effect => |se| {
                _ = try ctx.stack.pop();
                stack_effect_val = se;
            },
            .parse_time_marker => {
                _ = try ctx.stack.pop();
                is_parse_time = true;
            },
            .symbol => break, // Found the name, stop
            else => return error.TypeError, // Invalid definition syntax
        }
    }

    const name = try popSymbol(ctx);
    // Copy name to arena so it persists after input buffer is reused
    const name_copy = try ctx.quotationAllocator().dupe(u8, name);

    try ctx.dictionary.put(name_copy, WordDefinition{
        .name = name_copy,
        .parse_time = is_parse_time,
        .stack_effect = stack_effect_val,
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

/// . ( a -- ) - Print any value to stdout (with type formatting)
fn nativeDot(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const stdout_file: std.fs.File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writer(&stdout_buf);
    try val.write(&stdout.interface);
    try stdout.interface.writeAll("\n");
    try stdout.interface.flush();
}

/// print ( str -- ) - Print a string to stdout (unquoted, strings only)
fn nativePrint(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .string => |s| {
            const stdout_file: std.fs.File = .stdout();
            var stdout_buf: [4096]u8 = undefined;
            var stdout = stdout_file.writer(&stdout_buf);
            try stdout.interface.writeAll(s);
            try stdout.interface.writeAll("\n");
            try stdout.interface.flush();
        },
        else => return error.TypeError,
    }
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
            try writer.writeAll(" ");
            try effect.write(writer);
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

    // Execute try quotation with error-catching
    ctx.executeQuotation(try_quot) catch |err| {
        const alloc = ctx.quotationAllocator();
        var stack_trace: ?[]const StackFrame = null;

        if (ctx.error_details.items.len > 0) {
            const frames = alloc.alloc(StackFrame, ctx.error_details.items.len) catch null;
            if (frames) |f| {
                for (ctx.error_details.items, 0..) |detail, i| {
                    f[i] = .{
                        .word_name = detail.word_name orelse detail.message,
                        .line = detail.line,
                    };
                }
                stack_trace = f;
            }
        }

        const error_obj = ErrorObject{
            .error_type = @errorName(err),
            .message = @errorName(err),
            .stack_trace = stack_trace,
        };
        try ctx.stack.push(.{ .error_value = error_obj });

        // Clear error details after capturing, and execute recovery
        ctx.clearExecutionDetails();
        try ctx.executeQuotation(recover_quot);
        return;
    };
}

/// cleanup ( body-quot cleanup-quot -- ) - Execute body, always run cleanup,
/// then re-throw any error from body
fn nativeCleanup(ctx: *Context) anyerror!void {
    const cleanup_quot = try popQuotation(ctx);
    const body_quot = try popQuotation(ctx);

    // Execute body quotation, capturing any error
    const body_result = ctx.executeQuotation(body_quot);

    // Always execute cleanup quotation, even if body failed
    // If cleanup also fails, we ignore that error and prioritize the body error
    ctx.executeQuotation(cleanup_quot) catch {
        // Cleanup error is suppressed; body error takes priority
    };

    // Re-throw original error if body failed
    try body_result;
}

/// rethrow ( error -- ) - Re-raise an error value as an actual error
fn nativeRethrow(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .error_value => |err_obj| {
            // Restore the error details from the ErrorObject's stack trace
            if (err_obj.stack_trace) |trace| {
                // Clear any existing error details and restore from the error object
                ctx.error_details.clearRetainingCapacity();
                for (trace) |frame| {
                    ctx.error_details.append(ctx.allocator, .{
                        .error_type = err_obj.error_type,
                        .message = err_obj.message,
                        .line = frame.line,
                        .word_name = frame.word_name,
                    }) catch {};
                }
            }
            return error.RethrowError;
        },
        else => return error.TypeError,
    }
}

/// load ( filename -- ) - Load and execute a 1z source file
fn nativeLoad(ctx: *Context) anyerror!void {
    const filename = try popString(ctx);

    const file = std.fs.cwd().openFile(filename, .{}) catch {
        return error.FileNotFound;
    };
    defer file.close();

    var file_buf: [4096]u8 = undefined;
    var reader = file.reader(&file_buf);

    var processor: StatementProcessor = .{};

    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                // Try to execute any remaining buffered content
                switch (processor.flush(ctx.quotationAllocator(), ctx)) {
                    .needs_more_input => {},
                    .parse_error => |e| return e,
                    .complete => |instrs| {
                        if (instrs.len > 0) {
                            try ctx.executeQuotation(instrs);
                        }
                    },
                }
                break;
            },
            else => return error.FileReadError,
        };

        switch (processor.feedLine(ctx.quotationAllocator(), line, ctx)) {
            .needs_more_input => continue,
            .parse_error => |err| return err,
            .complete => |instrs| {
                if (instrs.len > 0) {
                    try ctx.executeQuotation(instrs);
                }
                processor.reset();
            },
        }
    }
}

/// parse-time ( -- marker ) - Push parse-time marker onto stack
/// When `;` sees this marker, it will set the word's parse_time flag
fn nativeParseTime(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .parse_time_marker = {} });
}

/// parse-until ( delimiter -- quotation ) - Read tokens until delimiter, return as quotation
/// This is a parse-time primitive that reads from the active tokenizer.
fn nativeParseUntil(ctx: *Context) anyerror!void {
    const delimiter = try popString(ctx);

    // Get the tokenizer from parse-time context
    const tokenizer = ctx.parse_tokenizer orelse return error.NoTokenizerAvailable;

    // Collect tokens until we hit the delimiter
    var tokens: std.ArrayListUnmanaged([]const u8) = .{};
    defer tokens.deinit(ctx.allocator);

    while (tokenizer.next()) |tok| {
        // Skip comments
        if (tok.kind == .comment or tok.kind == .newline) continue;

        if (std.mem.eql(u8, tok.text, delimiter)) {
            break;
        }
        tokens.append(ctx.allocator, tok.text) catch return error.OutOfMemory;
    }

    // Join tokens into a single string and parse as a quotation body
    const joined = std.mem.join(ctx.quotationAllocator(), " ", tokens.items) catch return error.OutOfMemory;

    // Parse the tokens as a quotation body (without enclosing brackets)
    // We add a closing bracket so parseQuotation can work correctly
    const with_bracket = std.fmt.allocPrint(ctx.quotationAllocator(), "{s} ]", .{joined}) catch return error.OutOfMemory;

    var inner_tokenizer = Tokenizer.init(with_bracket);
    const instrs = parser.parseQuotation(ctx.quotationAllocator(), &inner_tokenizer, ctx) catch return error.OutOfMemory;

    try ctx.stack.push(.{ .quotation = instrs });
}

/// make-hash ( quotation -- hash ) - Create a hash table from key: value pairs
/// The quotation should contain alternating symbol keys and values.
/// Example: [ name: "Alice" age: 30 ] make-hash
fn nativeMakeHash(ctx: *Context) anyerror!void {
    const instrs = try popQuotation(ctx);

    // Create a new hash table
    const hash = ctx.quotationAllocator().create(HashTable) catch return error.OutOfMemory;
    hash.* = HashTable{};

    // Parse instructions as key: value pairs
    var i: usize = 0;
    while (i < instrs.len) {
        // Expect a symbol key
        const key_instr = instrs[i];
        const key = switch (key_instr.op) {
            .push_literal => |v| switch (v) {
                .symbol => |s| s,
                else => return error.InvalidHashSyntax,
            },
            .call_word => return error.InvalidHashSyntax,
        };
        i += 1;

        if (i >= instrs.len) return error.InvalidHashSyntax;

        // Get the value - could be a literal or need execution
        const val_instr = instrs[i];
        const val = switch (val_instr.op) {
            .push_literal => |v| v,
            .call_word => blk: {
                // Execute the remaining instructions to get the value
                // TODO(ripta): figure out supporting beyond single-words
                try ctx.executeQuotation(instrs[i .. i + 1]);
                break :blk ctx.stack.pop() catch return error.InvalidHashSyntax;
            },
        };
        i += 1;

        // Copy key to arena for persistence
        const key_copy = ctx.quotationAllocator().dupe(u8, key) catch return error.OutOfMemory;
        hash.put(ctx.quotationAllocator(), key_copy, val) catch return error.OutOfMemory;
    }

    try ctx.stack.push(.{ .hash = hash });
}

// =============================================================================
// Helper functions
// =============================================================================

fn popInteger(ctx: *Context) !i64 {
    const val = try ctx.stack.pop();
    return switch (val) {
        .integer => |i| i,
        .boolean, .string, .symbol, .array, .quotation, .hash, .stack_effect, .parse_time_marker, .error_value => error.TypeError,
    };
}

fn popBoolean(ctx: *Context) !bool {
    const val = try ctx.stack.pop();
    return switch (val) {
        .boolean => |b| b,
        .integer => |i| i != 0,
        .string, .symbol, .array, .quotation, .hash, .stack_effect, .parse_time_marker, .error_value => error.TypeError,
    };
}

fn popQuotation(ctx: *Context) ![]const Instruction {
    const val = try ctx.stack.pop();
    return switch (val) {
        .quotation => |q| q,
        .integer, .boolean, .string, .symbol, .array, .hash, .stack_effect, .parse_time_marker, .error_value => error.TypeError,
    };
}

fn popSymbol(ctx: *Context) ![]const u8 {
    const val = try ctx.stack.pop();
    return switch (val) {
        .symbol => |s| s,
        .integer, .boolean, .string, .array, .quotation, .hash, .stack_effect, .parse_time_marker, .error_value => error.TypeError,
    };
}

fn popString(ctx: *Context) ![]const u8 {
    const val = try ctx.stack.pop();
    return switch (val) {
        .string => |s| s,
        .integer, .boolean, .symbol, .array, .quotation, .hash, .stack_effect, .parse_time_marker, .error_value => error.TypeError,
    };
}

fn popStackEffect(ctx: *Context) !StackEffect {
    const val = try ctx.stack.pop();
    return switch (val) {
        .stack_effect => |se| se,
        .integer, .boolean, .string, .symbol, .array, .quotation, .hash, .parse_time_marker, .error_value => error.TypeError,
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

test "swap" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 1 });
    try ctx.stack.push(.{ .integer = 2 });
    try nativeSwap(&ctx);

    try std.testing.expectEqual(@as(usize, 2), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 2), (try ctx.stack.pop()).integer);
}

test "over" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 1 });
    try ctx.stack.push(.{ .integer = 2 });
    try nativeOver(&ctx);

    try std.testing.expectEqual(@as(usize, 3), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 2), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).integer);
}

test "dip executes quotation with top item hidden" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Stack: 10 20, then dip with [ 1 + ]
    // Should: hide 20, execute [ 1 + ] on 10 -> 11, restore 20
    // Result: 11 20
    const quot = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .integer = 1 } }, .line = 0 },
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    try ctx.stack.push(.{ .integer = 10 });
    try ctx.stack.push(.{ .integer = 20 });
    try ctx.stack.push(.{ .quotation = &quot });
    try nativeDip(&ctx);

    try std.testing.expectEqual(@as(usize, 2), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 20), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 11), (try ctx.stack.pop()).integer);
}

test "dip with empty quotation" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Stack: 1 2, dip with [ ] should just restore 2
    const quot = [_]Instruction{};
    try ctx.stack.push(.{ .integer = 1 });
    try ctx.stack.push(.{ .integer = 2 });
    try ctx.stack.push(.{ .quotation = &quot });
    try nativeDip(&ctx);

    try std.testing.expectEqual(@as(usize, 2), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 2), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).integer);
}

test "dip with quotation that pushes multiple values" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Stack: 5, dip with [ 1 2 3 ]
    // Should: hide 5, push 1 2 3, restore 5
    // Result: 1 2 3 5
    const quot = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .integer = 1 } }, .line = 0 },
        .{ .op = .{ .push_literal = .{ .integer = 2 } }, .line = 0 },
        .{ .op = .{ .push_literal = .{ .integer = 3 } }, .line = 0 },
    };
    try ctx.stack.push(.{ .integer = 5 });
    try ctx.stack.push(.{ .quotation = &quot });
    try nativeDip(&ctx);

    try std.testing.expectEqual(@as(usize, 4), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 5), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 3), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 2), (try ctx.stack.pop()).integer);
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

test "add overflow" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = std.math.maxInt(i64) });
    try ctx.stack.push(.{ .integer = 1 });

    const result = nativeAdd(&ctx);
    try std.testing.expectError(error.IntegerOverflow, result);
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

test "sub overflow" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = std.math.minInt(i64) });
    try ctx.stack.push(.{ .integer = 1 });

    const result = nativeSub(&ctx);
    try std.testing.expectError(error.IntegerOverflow, result);
}

test "mul" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 3 });
    try ctx.stack.push(.{ .integer = 4 });
    try nativeMul(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 12), (try ctx.stack.pop()).integer);
}

test "mul overflow" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = std.math.maxInt(i64) });
    try ctx.stack.push(.{ .integer = 2 });

    const result = nativeMul(&ctx);
    try std.testing.expectError(error.IntegerOverflow, result);
}

test "div" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 10 });
    try ctx.stack.push(.{ .integer = 3 });
    try nativeDiv(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 3), (try ctx.stack.pop()).integer);
}

test "div by zero" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 10 });
    try ctx.stack.push(.{ .integer = 0 });

    const result = nativeDiv(&ctx);
    try std.testing.expectError(error.DivisionByZero, result);
}

test "div overflow" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // MIN_INT / -1 would overflow because -MIN_INT > MAX_INT
    try ctx.stack.push(.{ .integer = std.math.minInt(i64) });
    try ctx.stack.push(.{ .integer = -1 });

    const result = nativeDiv(&ctx);
    try std.testing.expectError(error.IntegerOverflow, result);
}

test "mod" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 10 });
    try ctx.stack.push(.{ .integer = 3 });
    try nativeMod(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 1), (try ctx.stack.pop()).integer);
}

test "mod by zero" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .integer = 10 });
    try ctx.stack.push(.{ .integer = 0 });

    const result = nativeMod(&ctx);
    try std.testing.expectError(error.DivisionByZero, result);
}

test "+% wrapping addition" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // MAX_INT +w 1 should wrap to MIN_INT
    try ctx.stack.push(.{ .integer = std.math.maxInt(i64) });
    try ctx.stack.push(.{ .integer = 1 });
    try nativeAddWrap(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(std.math.minInt(i64), (try ctx.stack.pop()).integer);
}

test "-% wrapping subtraction" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // MIN_INT -w 1 should wrap to MAX_INT
    try ctx.stack.push(.{ .integer = std.math.minInt(i64) });
    try ctx.stack.push(.{ .integer = 1 });
    try nativeSubWrap(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(std.math.maxInt(i64), (try ctx.stack.pop()).integer);
}

test "*% wrapping multiplication" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // MAX_INT *w 2 should wrap
    try ctx.stack.push(.{ .integer = std.math.maxInt(i64) });
    try ctx.stack.push(.{ .integer = 2 });
    try nativeMulWrap(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, -2), (try ctx.stack.pop()).integer);
}

test "call executes quotation" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .integer = 1 } }, .line = 0 },
        .{ .op = .{ .push_literal = .{ .integer = 2 } }, .line = 0 },
        .{ .op = .{ .call_word = "+" }, .line = 0 },
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
        .{ .op = .{ .push_literal = .{ .integer = 2 } }, .line = 0 },
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    try ctx.stack.push(.{ .symbol = "add2" });
    try ctx.stack.push(.{ .quotation = &instrs });
    try nativeSemicolon(&ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
    const word = ctx.dictionary.get("add2");
    try std.testing.expect(word != null);
    try std.testing.expect(word.?.stack_effect == null);
}

test "semicolon defines word with stack effect" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .integer = 2 } }, .line = 0 },
        .{ .op = .{ .call_word = "+" }, .line = 0 },
    };
    try ctx.stack.push(.{ .symbol = "add2" });
    try ctx.stack.push(.{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    } });
    try ctx.stack.push(.{ .quotation = &instrs });
    try nativeSemicolon(&ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
    const word = ctx.dictionary.get("add2");
    try std.testing.expect(word != null);
    try std.testing.expect(word.?.stack_effect != null);
    try std.testing.expectEqual(@as(usize, 1), word.?.stack_effect.?.inputs.len);
    try std.testing.expectEqualStrings("n", word.?.stack_effect.?.inputs[0].name);
}

test "if true branch" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const true_quot = [_]Instruction{.{ .op = .{ .push_literal = .{ .integer = 1 } }, .line = 0 }};
    const false_quot = [_]Instruction{.{ .op = .{ .push_literal = .{ .integer = 2 } }, .line = 0 }};
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

    const true_quot = [_]Instruction{.{ .op = .{ .push_literal = .{ .integer = 1 } }, .line = 0 }};
    const false_quot = [_]Instruction{.{ .op = .{ .push_literal = .{ .integer = 2 } }, .line = 0 }};
    try ctx.stack.push(.{ .boolean = false });
    try ctx.stack.push(.{ .quotation = &true_quot });
    try ctx.stack.push(.{ .quotation = &false_quot });
    try nativeIf(&ctx);

    try std.testing.expectEqual(@as(i64, 2), (try ctx.stack.pop()).integer);
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
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var dict = Dictionary.init(allocator);
    defer dict.deinit();

    try registerPrimitives(&dict, arena.allocator());

    try std.testing.expect(dict.get("dup") != null);
    try std.testing.expect(dict.get("drop") != null);
    try std.testing.expect(dict.get("swap") != null);
    try std.testing.expect(dict.get("over") != null);
    try std.testing.expect(dict.get("dip") != null);
    try std.testing.expect(dict.get("+") != null);
    try std.testing.expect(dict.get("-") != null);
    try std.testing.expect(dict.get("*") != null);
    try std.testing.expect(dict.get("/") != null);
    try std.testing.expect(dict.get("%") != null);
    try std.testing.expect(dict.get("+%") != null);
    try std.testing.expect(dict.get("-%") != null);
    try std.testing.expect(dict.get("*%") != null);
    try std.testing.expect(dict.get("call") != null);
    try std.testing.expect(dict.get(";") != null);
    try std.testing.expect(dict.get("if") != null);
    try std.testing.expect(dict.get("print") != null);
    try std.testing.expect(dict.get(".") != null);
    try std.testing.expect(dict.get("recover") != null);
    try std.testing.expect(dict.get("cleanup") != null);
    try std.testing.expect(dict.get("rethrow") != null);
}

test "recover catches error and executes recovery" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Try quotation that causes stack underflow, recovery pushes 42
    const try_quot = [_]Instruction{.{ .op = .{ .call_word = "drop" }, .line = 0 }}; // Stack underflow
    const recover_quot = [_]Instruction{
        .{ .op = .{ .call_word = "drop" }, .line = 0 }, // Drop the error value
        .{ .op = .{ .push_literal = .{ .integer = 42 } }, .line = 0 },
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
    const try_quot = [_]Instruction{.{ .op = .{ .push_literal = .{ .integer = 100 } }, .line = 0 }};
    const recover_quot = [_]Instruction{.{ .op = .{ .push_literal = .{ .integer = 42 } }, .line = 0 }};
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
    const try_quot = [_]Instruction{.{ .op = .{ .call_word = "drop" }, .line = 0 }}; // Stack underflow
    const recover_quot = [_]Instruction{}; // Do nothing, leave error on stack
    try ctx.stack.push(.{ .quotation = &try_quot });
    try ctx.stack.push(.{ .quotation = &recover_quot });
    try nativeRecover(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const val = try ctx.stack.pop();

    try std.testing.expectEqualStrings("StackUnderflow", val.error_value.error_type);
    try std.testing.expectEqualStrings("StackUnderflow", val.error_value.message);

    try std.testing.expect(val.error_value.stack_trace != null);
    try std.testing.expectEqual(@as(usize, 1), val.error_value.stack_trace.?.len);
    try std.testing.expectEqualStrings("drop", val.error_value.stack_trace.?[0].word_name);
}

test "cleanup runs on success" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Body pushes 10, cleanup pushes 20
    const body_quot = [_]Instruction{.{ .op = .{ .push_literal = .{ .integer = 10 } }, .line = 0 }};
    const cleanup_quot = [_]Instruction{.{ .op = .{ .push_literal = .{ .integer = 20 } }, .line = 0 }};
    try ctx.stack.push(.{ .quotation = &body_quot });
    try ctx.stack.push(.{ .quotation = &cleanup_quot });
    try nativeCleanup(&ctx);

    // Both should have run: stack has 10, then 20
    try std.testing.expectEqual(@as(usize, 2), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 20), (try ctx.stack.pop()).integer);
    try std.testing.expectEqual(@as(i64, 10), (try ctx.stack.pop()).integer);
}

test "cleanup runs on error and rethrows" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Body fails (stack underflow), cleanup pushes 99
    const body_quot = [_]Instruction{.{ .op = .{ .call_word = "drop" }, .line = 0 }};
    const cleanup_quot = [_]Instruction{.{ .op = .{ .push_literal = .{ .integer = 99 } }, .line = 0 }};
    try ctx.stack.push(.{ .quotation = &body_quot });
    try ctx.stack.push(.{ .quotation = &cleanup_quot });

    // cleanup should rethrow the error
    const result = nativeCleanup(&ctx);
    try std.testing.expectError(error.StackUnderflow, result);

    // But cleanup should have run - 99 is on the stack
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    try std.testing.expectEqual(@as(i64, 99), (try ctx.stack.pop()).integer);
}

test "cleanup error is suppressed if body fails" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Both body and cleanup fail
    const body_quot = [_]Instruction{.{ .op = .{ .call_word = "drop" }, .line = 0 }};
    const cleanup_quot = [_]Instruction{.{ .op = .{ .call_word = "drop" }, .line = 0 }};
    try ctx.stack.push(.{ .quotation = &body_quot });
    try ctx.stack.push(.{ .quotation = &cleanup_quot });

    // Body error should be rethrown (cleanup error suppressed)
    const result = nativeCleanup(&ctx);
    try std.testing.expectError(error.StackUnderflow, result);
}

test "rethrow re-raises error value" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Create an error object and push it
    const error_obj = ErrorObject{
        .error_type = "StackUnderflow",
        .message = "StackUnderflow",
        .stack_trace = null,
    };
    try ctx.stack.push(.{ .error_value = error_obj });

    // rethrow should return RethrowError
    const result = nativeRethrow(&ctx);
    try std.testing.expectError(error.RethrowError, result);
}

test "rethrow restores stack trace" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Create an error object with stack trace
    const frames = [_]StackFrame{
        .{ .word_name = "inner", .line = 10 },
        .{ .word_name = "outer", .line = 20 },
    };
    const error_obj = ErrorObject{
        .error_type = "TestError",
        .message = "test message",
        .stack_trace = &frames,
    };
    try ctx.stack.push(.{ .error_value = error_obj });

    // rethrow should restore error_details
    _ = nativeRethrow(&ctx) catch {};

    // Check that error_details were restored
    try std.testing.expectEqual(@as(usize, 2), ctx.error_details.items.len);
    try std.testing.expectEqualStrings("inner", ctx.error_details.items[0].word_name.?);
    try std.testing.expectEqual(@as(usize, 10), ctx.error_details.items[0].line);
    try std.testing.expectEqualStrings("outer", ctx.error_details.items[1].word_name.?);
    try std.testing.expectEqual(@as(usize, 20), ctx.error_details.items[1].line);
}

test "rethrow fails on non-error value" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Push a non-error value
    try ctx.stack.push(.{ .integer = 42 });

    // rethrow should return TypeError
    const result = nativeRethrow(&ctx);
    try std.testing.expectError(error.TypeError, result);
}

test "parse-time pushes marker onto stack" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try nativeParseTime(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const val = try ctx.stack.pop();
    try std.testing.expectEqual(Value.parse_time_marker, std.meta.activeTag(val));
}

test "semicolon defines parse-time word when marker is present" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .integer = 42 } }, .line = 0 },
    };
    // Stack: symbol, parse-time marker, quotation
    try ctx.stack.push(.{ .symbol = "my-macro" });
    try ctx.stack.push(.{ .parse_time_marker = {} });
    try ctx.stack.push(.{ .quotation = &instrs });
    try nativeSemicolon(&ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
    const word = ctx.dictionary.get("my-macro");
    try std.testing.expect(word != null);
    try std.testing.expectEqual(true, word.?.parse_time);
}

test "semicolon defines non-parse-time word by default" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .integer = 42 } }, .line = 0 },
    };
    // Stack: symbol, quotation (no parse-time marker)
    try ctx.stack.push(.{ .symbol = "regular-word" });
    try ctx.stack.push(.{ .quotation = &instrs });
    try nativeSemicolon(&ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
    const word = ctx.dictionary.get("regular-word");
    try std.testing.expect(word != null);
    try std.testing.expectEqual(false, word.?.parse_time);
}

test "semicolon defines parse-time word with stack effect" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .integer = 42 } }, .line = 0 },
    };
    // Stack: symbol, parse-time marker, stack effect, quotation
    try ctx.stack.push(.{ .symbol = "my-macro" });
    try ctx.stack.push(.{ .parse_time_marker = {} });
    try ctx.stack.push(.{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{},
        .outputs = &[_]StackEffectParam{.{ .name = "x" }},
    } });
    try ctx.stack.push(.{ .quotation = &instrs });
    try nativeSemicolon(&ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.stack.depth());
    const word = ctx.dictionary.get("my-macro");
    try std.testing.expect(word != null);
    try std.testing.expectEqual(true, word.?.parse_time);
    try std.testing.expect(word.?.stack_effect != null);
    try std.testing.expectEqual(@as(usize, 0), word.?.stack_effect.?.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), word.?.stack_effect.?.outputs.len);
}

test "parse-until reads tokens until delimiter" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Set up a tokenizer as if we're in parse-time context
    var tokenizer = Tokenizer.init("1 2 + }");
    ctx.parse_tokenizer = &tokenizer;

    // Push the delimiter
    try ctx.stack.push(.{ .string = "}" });

    // Call parse-until
    try nativeParseUntil(&ctx);

    // Should have a quotation on the stack
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const val = try ctx.stack.pop();
    try std.testing.expectEqual(Value.quotation, std.meta.activeTag(val));

    // The quotation should contain: push 1, push 2, call +
    const quot = val.quotation;
    try std.testing.expectEqual(@as(usize, 3), quot.len);
    try std.testing.expectEqual(@as(i64, 1), quot[0].op.push_literal.integer);
    try std.testing.expectEqual(@as(i64, 2), quot[1].op.push_literal.integer);
    try std.testing.expectEqualStrings("+", quot[2].op.call_word);
}

test "parse-until with empty content" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Set up a tokenizer with just the delimiter
    var tokenizer = Tokenizer.init("}");
    ctx.parse_tokenizer = &tokenizer;

    // Push the delimiter
    try ctx.stack.push(.{ .string = "}" });

    // Call parse-until
    try nativeParseUntil(&ctx);

    // Should have an empty quotation on the stack
    try std.testing.expectEqual(@as(usize, 1), ctx.stack.depth());
    const val = try ctx.stack.pop();
    const quot = val.quotation;
    try std.testing.expectEqual(@as(usize, 0), quot.len);
}

test "parse-until fails without tokenizer" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // No tokenizer set (parse_tokenizer is null)
    try ctx.stack.push(.{ .string = "}" });

    // Should fail with NoTokenizerAvailable
    const result = nativeParseUntil(&ctx);
    try std.testing.expectError(error.NoTokenizerAvailable, result);
}
