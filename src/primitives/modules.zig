const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Module = @import("../module.zig").Module;
const WordDefinition = @import("../dictionary.zig").WordDefinition;
const Visibility = @import("../dictionary.zig").Visibility;
const Tokenizer = @import("../tokenizer.zig").Tokenizer;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;
const InterpreterError = @import("types.zig").InterpreterError;

const popString = helpers.popString;
const popSymbol = helpers.popSymbol;

pub const primitives = [_]Primitive{
    .{ .name = "module:", .stack_effect = "--", .func = nativeModuleDecl, .parse_time = true },
    .{ .name = "use:", .stack_effect = "--", .func = nativeUse, .parse_time = true },
    .{ .name = "exported", .stack_effect = "-- marker", .func = nativeExported },
};

/// Get the next token from the parse stream, skipping comments and newlines.
fn nextParseToken(tokenizer: *Tokenizer) ?[]const u8 {
    while (tokenizer.next()) |tok| {
        if (tok.kind == .comment or tok.kind == .newline) {
            continue;
        }
        return tok.text;
    }
    return null;
}

/// module: ( -- ) - Declare a module and switch to it (parse-time)
/// Consumes the next token as the module name.
/// Example: module: math ;
fn nativeModuleDecl(ctx: *Context) anyerror!void {
    // Get the tokenizer for parse-time token consumption
    const tokenizer = ctx.parse_tokenizer orelse return InterpreterError.NoTokenizerAvailable;

    // Get the next token as the module name
    const name = nextParseToken(tokenizer) orelse return InterpreterError.TypeError;

    // Get or create the module
    const mod = try ctx.getOrCreateModule(name);

    // Set as current module for subsequent definitions
    ctx.current_module = mod;
}

/// use: ( -- ) - Import exported words from modules (parse-time)
/// Consumes an array literal from the parse stream.
/// Example: use: [ "math" "io" ]
fn nativeUse(ctx: *Context) anyerror!void {
    // Get the tokenizer for parse-time token consumption
    const tokenizer = ctx.parse_tokenizer orelse return InterpreterError.NoTokenizerAvailable;

    // Expect '[' to start the array
    const open_bracket = nextParseToken(tokenizer) orelse return InterpreterError.TypeError;
    if (!std.mem.eql(u8, open_bracket, "[")) {
        return InterpreterError.TypeError;
    }

    // Parse module names until we hit ']'
    while (true) {
        const token = nextParseToken(tokenizer) orelse return InterpreterError.TypeError;

        if (std.mem.eql(u8, token, "]")) {
            break;
        }

        // Expect a string literal (quoted)
        if (token.len >= 2 and token[0] == '"' and token[token.len - 1] == '"') {
            const mod_name = token[1 .. token.len - 1];
            try importModule(ctx, mod_name);
        } else {
            return InterpreterError.TypeError;
        }
    }
}

/// Import all exported words from a module into the global dictionary.
fn importModule(ctx: *Context, mod_name: []const u8) !void {
    // First try to find an already-loaded module
    if (ctx.getModule(mod_name)) |mod| {
        try importModuleWords(ctx, mod);
        return;
    }

    // Module not found - try to load it from lib/
    try loadModuleFromFile(ctx, mod_name);

    // Now import the module's words
    if (ctx.getModule(mod_name)) |mod| {
        try importModuleWords(ctx, mod);
    }
}

/// Import all exported words from a loaded module into the global dictionary.
fn importModuleWords(ctx: *Context, mod: *Module) !void {
    var iter = mod.words.iterator();
    while (iter.next()) |entry| {
        const word = entry.value_ptr.*;
        if (word.visibility == .public) {
            // Import the word into the global dictionary
            try ctx.dictionary.put(entry.key_ptr.*, word);
        }
    }
}

/// Load a module from lib/<name>.1z
fn loadModuleFromFile(ctx: *Context, mod_name: []const u8) !void {
    const alloc = ctx.quotationAllocator();

    // Build the file path: lib/<mod_name>.1z
    // Replace / with directory separators for hierarchical modules
    var path_buf: [512]u8 = undefined;
    var path_len: usize = 0;

    // Start with "lib/"
    const prefix = "lib/";
    @memcpy(path_buf[0..prefix.len], prefix);
    path_len = prefix.len;

    // Copy module name
    @memcpy(path_buf[path_len..][0..mod_name.len], mod_name);
    path_len += mod_name.len;

    // Add ".1z" extension
    const suffix = ".1z";
    @memcpy(path_buf[path_len..][0..suffix.len], suffix);
    path_len += suffix.len;

    const file_path = path_buf[0..path_len];

    // Try to open and read the file
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => return InterpreterError.FileNotFound,
            else => return InterpreterError.FileReadError,
        }
    };
    defer file.close();

    const source = file.readToEndAlloc(alloc, 1024 * 1024) catch {
        return InterpreterError.FileReadError;
    };

    // Save and restore current module
    const saved_module = ctx.current_module;
    defer ctx.current_module = saved_module;

    // Parse and execute the module file
    const StatementProcessor = @import("../statement.zig").StatementProcessor;
    var processor: StatementProcessor = .{};

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const result = processor.feedLine(alloc, line, ctx);
        switch (result) {
            .needs_more_input => continue,
            .complete => |instrs| {
                if (instrs.len > 0) {
                    try ctx.executeQuotation(.{ .instructions = instrs });
                }
                processor.reset();
            },
            .parse_error => return InterpreterError.FileReadError,
        }
    }

    // Flush any remaining buffered content
    switch (processor.flush(alloc, ctx)) {
        .complete => |instrs| {
            if (instrs.len > 0) {
                try ctx.executeQuotation(.{ .instructions = instrs });
            }
        },
        .parse_error => return InterpreterError.FileReadError,
        .needs_more_input => {},
    }
}

/// exported ( -- marker ) - Push an exported marker onto the stack
/// Used before ; to mark a word as public
/// Example: double: exported [ 2 * ] ;
fn nativeExported(ctx: *Context) anyerror!void {
    try ctx.stack.push(.{ .exported_marker = {} });
}
