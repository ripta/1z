const std = @import("std");
const File = std.fs.File;

const context = @import("context.zig");
const Context = context.Context;
const ErrorDetail = context.ErrorDetail;
const ParseDiagnostics = context.ParseDiagnostics;
const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const Quotation = value_mod.Quotation;
const ErrorObject = value_mod.ErrorObject;
const StackFrame = value_mod.StackFrame;
const Value = value_mod.Value;
const StatementProcessor = @import("statement.zig").StatementProcessor;
const formatter = @import("formatter.zig");
const benchmark = @import("benchmark.zig");
const profile = @import("profile.zig");
const debugger_mod = @import("debugger/mod.zig");
const pascalToKebabRuntime = @import("primitives/errors.zig").pascalToKebabRuntime;
const hooks = @import("primitives/hooks.zig");
const LineEditor = @import("line_editor.zig").LineEditor;
const BenchmarkStats = benchmark.BenchmarkStats;
const BenchmarkConfig = benchmark.BenchmarkConfig;
const ProfileStats = profile.ProfileStats;
const ProfileConfig = profile.ProfileConfig;
const CountingAllocator = benchmark.CountingAllocator;
const memory_limit = @import("memory_limit.zig");
const MemoryLimitAllocator = memory_limit.MemoryLimitAllocator;
const trace_mod = @import("trace.zig");
const call_graph = @import("call_graph.zig");
const effect_inference = @import("effect_inference.zig");
const aot_freeze = @import("aot_freeze.zig");
const ir_codegen = @import("ir_codegen.zig");
const bail_stats_mod = @import("bail_stats.zig");

const signal = @import("signal.zig");
const build_options = @import("build_options");
pub const version = build_options.version;

/// Verbosity level for REPL output.
const Verbosity = enum(u8) {
    // Full output: banner, prompts, stack, goodbye
    normal = 0,
    // Quiet: no banner
    quiet = 1,
    // Silent: no banner, no prompts, no stack, and no goodbye
    silent = 2,
};

/// Print error details from the context's error stack.
/// Format: source:line: error.TYPE message at word 'WORD'
fn printErrorDetails(ctx: *Context, writer: anytype, err: anyerror) void {
    if (ctx.thrown_error) |thrown| {
        hooks.fireHooks(ctx, "on:unhandled-error", &.{.{ .error_value = thrown }});
    } else {
        const alloc = ctx.quotationAllocator();
        var stack_trace: ?[]const StackFrame = null;

        if (ctx.error_details.items.len > 0) {
            const frames = alloc.alloc(StackFrame, ctx.error_details.items.len) catch null;
            if (frames) |f| {
                for (ctx.error_details.items, 0..) |detail, i| {
                    f[i] = .{
                        .word_name = detail.word_name orelse detail.message,
                        .source = detail.source,
                        .line = detail.line,
                    };
                }
                stack_trace = f;
            }
        }

        var kebab_buf: [128]u8 = undefined;
        const kebab_name = pascalToKebabRuntime(@errorName(err), &kebab_buf);
        const duped_name = alloc.dupe(u8, kebab_name) catch @errorName(err);
        const error_obj = ErrorObject{
            .error_type = duped_name,
            .message = duped_name,
            .data = null,
            .stack_trace = stack_trace,
        };
        hooks.fireHooks(ctx, "on:unhandled-error", &.{.{ .error_value = error_obj }});
    }

    const details = ctx.error_details.items;
    if (details.len > 0) {
        // print first (innermost) error location
        const detail = details[0];
        writer.print("{s}:{d}: error '{s}'", .{ detail.source, detail.line, detail.error_type }) catch return;

        if (detail.word_name != null and !std.mem.eql(u8, detail.message, detail.word_name.?)) {
            writer.print(" {s}", .{detail.message}) catch return;
        }

        if (detail.word_name) |word_name| {
            writer.print(" at word '{s}'", .{word_name}) catch return;
        }
        writer.writeAll("\n") catch return;

        if (detail.stack_effect_str) |se| {
            writer.print("  stack effect: {s}\n", .{se}) catch return;
        }
        if (detail.hint) |hint| {
            writer.print("  hint: {s}\n", .{hint}) catch return;
        }
        if (detail.dispatch_actual_types) |types| {
            writer.print("  got method arguments: {s}\n", .{types}) catch return;
        }
        if (detail.dispatch_available_methods) |methods| {
            if (std.mem.eql(u8, methods, "none")) {
                writer.writeAll("  available methods: none\n") catch return;
            } else {
                writer.print("  available methods:\n{s}\n", .{methods}) catch return;
            }
        }

        // print remaining caller chain
        if (details.len > 1) {
            for (details[1..]) |frame| {
                writer.print("  called from {s}:{d}: {s}\n", .{
                    frame.source,
                    frame.line,
                    frame.word_name orelse frame.message,
                }) catch return;
            }
        }
    } else {
        // fallback if no details captured
        var kebab_buf: [128]u8 = undefined;
        const kebab_name = pascalToKebabRuntime(@errorName(err), &kebab_buf);
        writer.print("error.{s}\n", .{kebab_name}) catch return;
    }
    ctx.clearExecutionDetails();
}

/// Print parse error details from parse_diagnostics.
/// Format matches runtime errors: source:line: error 'TYPE' MESSAGE
/// The start_line parameter converts tokenizer-relative opening_line to file-relative.
fn printParseDiagnostics(ctx: *Context, writer: anytype, source: []const u8, line: usize, start_line: usize) void {
    const diag = ctx.parse_diagnostics orelse return;
    if (diag.error_type) |error_type| {
        var kebab_buf: [128]u8 = undefined;
        const kebab_name = pascalToKebabRuntime(error_type, &kebab_buf);
        writer.print("{s}:{d}: error '{s}'", .{ source, line, kebab_name }) catch return;
        if (diag.message) |msg| {
            writer.print(" {s}", .{msg}) catch return;
        }
        if (diag.opening_line) |ol| {
            const file_line = if (start_line > 0) ol + start_line - 1 else ol;
            writer.print(" opened at line {d}", .{file_line}) catch return;
        }
        writer.writeAll("\n") catch return;
    }
    ctx.parse_diagnostics = null;
}

/// Check whether the current error is a signal interrupt, e.g., SIGINT.
/// Used by the REPL to print a short notice instead of a full error trace.
fn isInterruptError(ctx: *const Context) bool {
    if (ctx.thrown_error) |thrown| {
        return std.mem.eql(u8, thrown.error_type, "interrupted");
    }
    return false;
}

fn runReplStartupStatement(ctx: *Context, writer: anytype, statement: []const u8) void {
    var processor: StatementProcessor = .{};
    defer processor.deinit();
    processor.trackLine(1);

    switch (processor.feedLine(ctx.quotationAllocator(), statement, ctx)) {
        .complete => |instrs| {
            ctx.executeQuotation(.{ .instructions = instrs }) catch |err| {
                printErrorDetails(ctx, writer, err);
            };
            processor.reset();
        },
        .parse_error => |err| {
            if (err == error.DebuggerQuit) return;
            if (ctx.parse_diagnostics != null) {
                printParseDiagnostics(ctx, writer, ctx.current_source, 1, processor.start_line);
            } else {
                writer.print("Error: {any}\n", .{err}) catch {};
            }
            ctx.clearExecutionDetails();
            processor.reset();
        },
        .needs_more_input => {
            processor.reset();
        },
    }
}

/// Shared state for flags that affect the runtime environment regardless of
/// which subcommand is running (paths, memory cap, prelude override).
const GlobalFlags = struct {
    max_memory_bytes: usize = 256 * 1024 * 1024,
    cli_set_max_memory: bool = false,
    load_paths: std.ArrayListUnmanaged([]const u8) = .{},
    stdlib_path: ?[]const u8 = null,
    prelude_path: ?[]const u8 = null,

    fn deinit(self: *GlobalFlags, allocator: std.mem.Allocator) void {
        self.load_paths.deinit(allocator);
    }
};

/// Shared state for flags that affect the runtime environment regardless of which subcommand is running.
const ExecutionFlags = struct {
    show_stack: bool = false,
    verbosity: Verbosity = .normal,
    bench_config: BenchmarkConfig = .{},
    profile_config: ProfileConfig = .{},
    debug_mode: bool = false,
    initial_breakpoints: [16][]const u8 = undefined,
    initial_breakpoint_count: usize = 0,
    trace_config: trace_mod.TraceConfig = .{},
    deadlock_detect_ns: ?i128 = null,
    test_timeout_ns: ?u64 = null,
    allow_all_recursion: bool = false,
    compile_mode: context.CompileMode = .off,
    cli_set_compile: bool = false,
    cli_set_profile_top: bool = false,
    allow_interpreter_fallback: bool = false,
};

/// Result of attempting to parse a single argument as a flag.
const FlagParseResult = enum { consumed, not_mine };

/// Attempts to parse `arg` as a global flag and, if recognized, applies it to
/// `state`. Returns `.consumed` on a match, `.not_mine` otherwise. On a
/// malformed value, prints an error to `err_writer` and returns
/// `error.InvalidFlagValue`.
fn parseGlobalFlag(
    arg: []const u8,
    state: *GlobalFlags,
    allocator: std.mem.Allocator,
    err_writer: anytype,
) !FlagParseResult {
    if (std.mem.startsWith(u8, arg, "--max-memory=")) {
        const value = arg["--max-memory=".len..];
        if (memory_limit.parseSize(value)) |bytes| {
            state.max_memory_bytes = bytes;
            state.cli_set_max_memory = true;
            return .consumed;
        }
        err_writer.print("Error: invalid value for --max-memory: '{s}'\n", .{value}) catch {};
        err_writer.flush() catch {};
        return error.InvalidFlagValue;
    }
    if (std.mem.startsWith(u8, arg, "--load-path=")) {
        const value = arg["--load-path=".len..];
        state.load_paths.append(allocator, value) catch {
            err_writer.writeAll("Error: out of memory\n") catch {};
            err_writer.flush() catch {};
            return error.OutOfMemory;
        };
        return .consumed;
    }
    if (std.mem.startsWith(u8, arg, "--stdlib-path=")) {
        state.stdlib_path = arg["--stdlib-path=".len..];
        return .consumed;
    }
    if (std.mem.startsWith(u8, arg, "--prelude=")) {
        state.prelude_path = arg["--prelude=".len..];
        return .consumed;
    }
    return .not_mine;
}

/// Attempts to parse `arg` as an execution flag (run/eval/repl flags).
/// Same contract as `parseGlobalFlag`.
fn parseExecutionFlag(
    arg: []const u8,
    state: *ExecutionFlags,
    err_writer: anytype,
) !FlagParseResult {
    if (std.mem.eql(u8, arg, "--show-stack")) {
        state.show_stack = true;
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "-qq") or std.mem.eql(u8, arg, "--silent")) {
        state.verbosity = .silent;
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
        state.verbosity = .quiet;
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--benchmark") or std.mem.eql(u8, arg, "-b")) {
        state.bench_config.enabled = true;
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--benchmark=verbose")) {
        state.bench_config.enabled = true;
        state.bench_config.output = .human;
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--benchmark=json")) {
        state.bench_config.enabled = true;
        state.bench_config.output = .json;
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--profile")) {
        state.profile_config.enabled = true;
        return .consumed;
    }
    if (std.mem.startsWith(u8, arg, "--profile-top=")) {
        const value = arg["--profile-top=".len..];
        const n = std.fmt.parseInt(usize, value, 10) catch {
            err_writer.print("Error: invalid value for --profile-top: '{s}'\n", .{value}) catch {};
            err_writer.flush() catch {};
            return error.InvalidFlagValue;
        };
        if (n == 0) {
            err_writer.print("Error: invalid value for --profile-top: '{s}' (must be > 0)\n", .{value}) catch {};
            err_writer.flush() catch {};
            return error.InvalidFlagValue;
        }
        state.profile_config.top_n = n;
        state.cli_set_profile_top = true;
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--debug")) {
        state.debug_mode = true;
        return .consumed;
    }
    if (std.mem.startsWith(u8, arg, "--break=")) {
        state.debug_mode = true;
        const word = arg["--break=".len..];
        if (state.initial_breakpoint_count < state.initial_breakpoints.len) {
            state.initial_breakpoints[state.initial_breakpoint_count] = word;
            state.initial_breakpoint_count += 1;
        }
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--trace-words")) {
        state.trace_config.trace_words = true;
        return .consumed;
    }
    if (std.mem.startsWith(u8, arg, "--trace-words=")) {
        state.trace_config.trace_words = true;
        state.trace_config.trace_words_pattern = arg["--trace-words=".len..];
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--trace-resolve")) {
        state.trace_config.trace_resolve = true;
        return .consumed;
    }
    if (std.mem.startsWith(u8, arg, "--trace-resolve=")) {
        state.trace_config.trace_resolve = true;
        state.trace_config.trace_resolve_pattern = arg["--trace-resolve=".len..];
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--trace-modules")) {
        state.trace_config.trace_modules = true;
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--trace-jit")) {
        state.trace_config.trace_jit = true;
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--trace-pic")) {
        state.trace_config.trace_pic = true;
        return .consumed;
    }
    if (std.mem.startsWith(u8, arg, "--dump-scope=")) {
        state.trace_config.dump_scope = arg["--dump-scope=".len..];
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--deadlock-detect")) {
        state.deadlock_detect_ns = 5 * std.time.ns_per_s;
        return .consumed;
    }
    if (std.mem.startsWith(u8, arg, "--deadlock-detect=")) {
        const value = arg["--deadlock-detect=".len..];
        const secs = std.fmt.parseInt(u64, value, 10) catch {
            err_writer.print("Error: invalid value for --deadlock-detect: '{s}'\n", .{value}) catch {};
            err_writer.flush() catch {};
            return error.InvalidFlagValue;
        };
        state.deadlock_detect_ns = @as(i128, secs) * std.time.ns_per_s;
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--test-timeout")) {
        err_writer.print("Error: --test-timeout requires a value (e.g. --test-timeout=5)\n", .{}) catch {};
        err_writer.flush() catch {};
        return error.InvalidFlagValue;
    }
    if (std.mem.startsWith(u8, arg, "--test-timeout=")) {
        const value = arg["--test-timeout=".len..];
        const secs = std.fmt.parseInt(u64, value, 10) catch {
            err_writer.print("Error: invalid value for --test-timeout: '{s}'\n", .{value}) catch {};
            err_writer.flush() catch {};
            return error.InvalidFlagValue;
        };
        state.test_timeout_ns = secs * std.time.ns_per_s;
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--allow-all-recursion")) {
        state.allow_all_recursion = true;
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--allow-interpreter-fallback")) {
        state.allow_interpreter_fallback = true;
        return .consumed;
    }
    if (std.mem.startsWith(u8, arg, "--compile=")) {
        const value = arg["--compile=".len..];
        if (std.mem.eql(u8, value, "off")) {
            state.compile_mode = .off;
        } else if (std.mem.eql(u8, value, "eager")) {
            state.compile_mode = .eager;
        } else if (std.mem.eql(u8, value, "hybrid")) {
            state.compile_mode = .hybrid;
        } else {
            err_writer.print("Error: invalid value for --compile: '{s}' (expected 'off', 'eager', or 'hybrid')\n", .{value}) catch {};
            err_writer.flush() catch {};
            return error.InvalidFlagValue;
        }
        state.cli_set_compile = true;
        return .consumed;
    }
    return .not_mine;
}

/// Write the version string to `w`. Extracted from `printVersion` so it can
/// be unit-tested without touching stdout.
fn writeVersion(w: anytype) !void {
    try w.print("1z {s}\n", .{version});
}

fn printVersion() void {
    const stdout_file: File = .stdout();
    var stdout_buf: [128]u8 = undefined;
    var stdout = stdout_file.writerStreaming(&stdout_buf);
    writeVersion(&stdout.interface) catch {};
    stdout.interface.flush() catch {};
}

fn printUsage() void {
    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(&stdout_buf);
    const w = &stdout.interface;

    w.writeAll(
        \\Usage: 1z [<subcommand>] [options] [args...]
        \\
        \\Subcommands:
        \\  run <file> [args...]   Execute a 1z source file
        \\  eval '<expr>'          Evaluate an expression string
        \\  check <file>           Run static analysis without executing
        \\  repl                   Start the interactive REPL (default)
        \\  fmt [files...]         Format 1z source files
        \\  lint [files...]        Check code style and conventions
        \\  highlight [file]       Highlight 1z source code
        \\  build <file>           Compile a 1z file to a native executable
        \\  version                Print version and exit
        \\
        \\Global options (available to all subcommands):
        \\  -h, --help              Show help
        \\  -V, --version           Show version
        \\  --max-memory=SIZE       Set memory limit (e.g. 128M, 1G; default 256M)
        \\  --load-path=PATH        Add a module search path (repeatable)
        \\  --stdlib-path=PATH      Override standard library path
        \\  --prelude=PATH          Override prelude file path
        \\
        \\Bare forms:
        \\  1z                      Enter the REPL (same as `1z repl`)
        \\  1z <file>               Alias for `1z run <file>`
        \\
        \\Environment variables:
        \\  ONEZ_MAX_MEMORY         Default memory limit (overridden by --max-memory)
        \\  ONEZ_COMPILE            Default compile mode (overridden by --compile)
        \\  ONEZ_PRELUDE            Default prelude path (overridden by --prelude)
        \\  ONEZ_LOAD_PATH          Colon-separated module search paths
        \\  ONEZ_STDLIB             Default standard library path
        \\
        \\Run '1z <subcommand> --help' for subcommand-specific options.
        \\
    ) catch {};
    w.flush() catch {};
}

const execution_flags_help =
    \\  --show-stack              Print the stack after execution
    \\  --debug                   Start in the interactive debugger
    \\  --break=WORD              Set a breakpoint on WORD (implies --debug)
    \\  --allow-all-recursion     Suppress non-tail recursion warnings
    \\  --allow-interpreter-fallback  Suppress quotation fallback warnings in AOT builds
    \\  --compile=MODE            Set compile mode: off, eager, hybrid
    \\  --trace-words[=PAT]       Trace word execution (optional pattern filter)
    \\  --trace-resolve[=PAT]     Trace word resolution (optional pattern filter)
    \\  --trace-modules           Trace module loading
    \\  --trace-jit               Trace JIT compilation
    \\  --trace-pic               Trace inline PIC hits
    \\  --dump-scope=WORD         Dump scope after loading WORD
    \\  --deadlock-detect[=SECS]  Enable deadlock detection (default 5s)
    \\  --test-timeout=SECS       Set test timeout in seconds
    \\  -b, --benchmark           Enable benchmarking
    \\  --benchmark=verbose       Benchmark with human-readable output
    \\  --benchmark=json          Benchmark with JSON output
    \\  --profile                 Collect per-word wall-time samples
    \\  --profile-top=N           Limit the profile table to N rows (default 20)
;

const global_flags_help =
    \\  --max-memory=SIZE         Set memory limit (e.g. 128M, 1G; default 256M)
    \\  --load-path=PATH          Add a module search path (repeatable)
    \\  --stdlib-path=PATH        Override standard library path
    \\  --prelude=PATH            Override prelude file path
;

fn printRunHelp() void {
    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(&stdout_buf);
    const w = &stdout.interface;
    w.writeAll("Usage: 1z run [options] <file> [args...]\n\n") catch {};
    w.writeAll("Execute a 1z source file.\n\n") catch {};
    w.writeAll("Global options:\n") catch {};
    w.writeAll(global_flags_help) catch {};
    w.writeAll("\n\nExecution options:\n") catch {};
    w.writeAll(execution_flags_help) catch {};
    w.writeAll("\n") catch {};
    w.flush() catch {};
}

fn printEvalHelp() void {
    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(&stdout_buf);
    const w = &stdout.interface;
    w.writeAll("Usage: 1z eval [options] '<expression>'\n\n") catch {};
    w.writeAll("Evaluate an expression string.\n\n") catch {};
    w.writeAll("Exit codes:\n") catch {};
    w.writeAll("  0   Evaluation succeeded, and top of stack is truthy or stack is empty\n") catch {};
    w.writeAll("  1   Evaluation succeeded, but top of stack is falsy\n") catch {};
    w.writeAll("  2   Runtime or parse error\n\n") catch {};
    w.writeAll("Eval options:\n") catch {};
    w.writeAll("  -p                        Print top of stack via `inspect` after evaluation\n\n") catch {};
    w.writeAll("Global options:\n") catch {};
    w.writeAll(global_flags_help) catch {};
    w.writeAll("\n\nExecution options:\n") catch {};
    w.writeAll(execution_flags_help) catch {};
    w.writeAll("\n") catch {};
    w.flush() catch {};
}

fn printCheckHelp() void {
    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(&stdout_buf);
    const w = &stdout.interface;
    w.writeAll("Usage: 1z check [options] <file>\n\n") catch {};
    w.writeAll("Run static analysis on a 1z source file without executing it.\n\n") catch {};
    w.writeAll("The following execution flags are NOT accepted by `check`:\n") catch {};
    w.writeAll("  --compile=MODE, --benchmark, --benchmark=verbose, --benchmark=json, --profile, --profile-top=N\n\n") catch {};
    w.writeAll("Global options:\n") catch {};
    w.writeAll(global_flags_help) catch {};
    w.writeAll("\n") catch {};
    w.flush() catch {};
}

fn printReplHelp() void {
    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(&stdout_buf);
    const w = &stdout.interface;
    w.writeAll("Usage: 1z repl [options]\n\n") catch {};
    w.writeAll("Start the interactive REPL.\n\n") catch {};
    w.writeAll("REPL options:\n") catch {};
    w.writeAll("  -q, --quiet               Suppress banner\n") catch {};
    w.writeAll("  -qq, --silent             Suppress banner, prompts, stack, and goodbye\n\n") catch {};
    w.writeAll("Global options:\n") catch {};
    w.writeAll(global_flags_help) catch {};
    w.writeAll("\n\nExecution options:\n") catch {};
    w.writeAll(execution_flags_help) catch {};
    w.writeAll("\n") catch {};
    w.flush() catch {};
}

fn printLintHelp() void {
    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(&stdout_buf);
    const w = &stdout.interface;
    w.writeAll("Usage: 1z lint [options] <file|dir...>\n\n") catch {};
    w.writeAll("Check code style and conventions.\n\n") catch {};
    w.writeAll("Exit codes:\n") catch {};
    w.writeAll("  0   No findings\n") catch {};
    w.writeAll("  1   Lint findings present\n") catch {};
    w.writeAll("  2   Invocation error\n\n") catch {};
    w.writeAll("Global options:\n") catch {};
    w.writeAll(global_flags_help) catch {};
    w.writeAll("\n") catch {};
    w.flush() catch {};
}

fn printHighlightHelp() void {
    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(&stdout_buf);
    const w = &stdout.interface;
    w.writeAll("Usage: 1z highlight [options] [file]\n\n") catch {};
    w.writeAll("Syntax highlight 1z source code.\n\n") catch {};
    w.writeAll("Reads from stdin when no file is given.\n\n") catch {};
    w.writeAll("Options:\n") catch {};
    w.writeAll("  --html              Output as HTML spans (default: ANSI)\n") catch {};
    w.writeAll("  --theme=PATH        Load a custom theme from a config file\n\n") catch {};
    w.writeAll("Global options:\n") catch {};
    w.writeAll(global_flags_help) catch {};
    w.writeAll("\n") catch {};
    w.flush() catch {};
}

const ExecutionContext = struct {
    gpa: std.mem.Allocator,
    mem_limit: *MemoryLimitAllocator,
    bench_stats: *BenchmarkStats,
    profile_stats: *ProfileStats,
    counting_allocator: *CountingAllocator,
    allocator: std.mem.Allocator,
    ctx: Context,
    dbg: ?debugger_mod.Debugger,
    watchdog: ?std.Thread,
    external_prelude: ?[]const u8,
    bench_enabled: bool,
    profile_enabled: bool,
    profile_top: usize,

    fn init(
        gpa: std.mem.Allocator,
        global: *GlobalFlags,
        exec: *ExecutionFlags,
        err_writer: anytype,
    ) !*ExecutionContext {
        if (!global.cli_set_max_memory) {
            if (std.posix.getenv("ONEZ_MAX_MEMORY")) |env_val| {
                if (memory_limit.parseSize(env_val)) |bytes| {
                    global.max_memory_bytes = bytes;
                }
            }
        }
        if (!exec.cli_set_compile) {
            if (std.posix.getenv("ONEZ_COMPILE")) |env_val| {
                if (std.mem.eql(u8, env_val, "off")) {
                    exec.compile_mode = .off;
                } else if (std.mem.eql(u8, env_val, "eager")) {
                    exec.compile_mode = .eager;
                } else if (std.mem.eql(u8, env_val, "hybrid")) {
                    exec.compile_mode = .hybrid;
                }
            }
        }

        const ec = gpa.create(ExecutionContext) catch {
            err_writer.writeAll("Error: out of memory\n") catch {};
            err_writer.flush() catch {};
            return error.ExecutionContextInitFailed;
        };
        errdefer gpa.destroy(ec);

        const mem_limit_ptr = gpa.create(MemoryLimitAllocator) catch {
            err_writer.writeAll("Error: out of memory\n") catch {};
            err_writer.flush() catch {};
            return error.ExecutionContextInitFailed;
        };
        errdefer gpa.destroy(mem_limit_ptr);
        mem_limit_ptr.* = MemoryLimitAllocator.init(gpa, global.max_memory_bytes);

        const bench_stats_ptr = gpa.create(BenchmarkStats) catch {
            err_writer.writeAll("Error: out of memory\n") catch {};
            err_writer.flush() catch {};
            return error.ExecutionContextInitFailed;
        };
        errdefer gpa.destroy(bench_stats_ptr);
        bench_stats_ptr.* = .{};

        const profile_stats_ptr = gpa.create(ProfileStats) catch {
            err_writer.writeAll("Error: out of memory\n") catch {};
            err_writer.flush() catch {};
            return error.ExecutionContextInitFailed;
        };
        errdefer gpa.destroy(profile_stats_ptr);
        profile_stats_ptr.* = .{};

        const counting_ptr = gpa.create(CountingAllocator) catch {
            err_writer.writeAll("Error: out of memory\n") catch {};
            err_writer.flush() catch {};
            return error.ExecutionContextInitFailed;
        };
        errdefer gpa.destroy(counting_ptr);
        counting_ptr.* = CountingAllocator.init(mem_limit_ptr.allocator(), bench_stats_ptr);

        const bench_enabled = exec.bench_config.enabled;
        const alloc: std.mem.Allocator = if (bench_enabled)
            counting_ptr.allocator()
        else
            mem_limit_ptr.allocator();

        if (bench_enabled) {
            bench_stats_ptr.start();
        }

        ec.* = .{
            .gpa = gpa,
            .mem_limit = mem_limit_ptr,
            .bench_stats = bench_stats_ptr,
            .profile_stats = profile_stats_ptr,
            .counting_allocator = counting_ptr,
            .allocator = alloc,
            .ctx = Context.init(alloc),
            .dbg = null,
            .watchdog = null,
            .external_prelude = null,
            .bench_enabled = bench_enabled,
            .profile_enabled = exec.profile_config.enabled,
            .profile_top = exec.profile_config.top_n,
        };
        errdefer ec.ctx.deinit();

        ec.ctx.trace = exec.trace_config;
        ec.ctx.deadlock_detect_ns = exec.deadlock_detect_ns;

        for (global.load_paths.items) |lp| {
            const duped = ec.ctx.quotationAllocator().dupe(u8, lp) catch {
                err_writer.writeAll("Error: out of memory\n") catch {};
                err_writer.flush() catch {};
                return error.ExecutionContextInitFailed;
            };
            ec.ctx.load_paths.append(ec.ctx.allocator, duped) catch {
                err_writer.writeAll("Error: out of memory\n") catch {};
                err_writer.flush() catch {};
                return error.ExecutionContextInitFailed;
            };
        }
        if (std.posix.getenv("ONEZ_LOAD_PATH")) |env_val| {
            var it = std.mem.splitScalar(u8, env_val, ':');
            while (it.next()) |segment| {
                if (segment.len > 0) {
                    const duped = ec.ctx.quotationAllocator().dupe(u8, segment) catch {
                        err_writer.writeAll("Error: out of memory\n") catch {};
                        err_writer.flush() catch {};
                        return error.ExecutionContextInitFailed;
                    };
                    ec.ctx.load_paths.append(ec.ctx.allocator, duped) catch {
                        err_writer.writeAll("Error: out of memory\n") catch {};
                        err_writer.flush() catch {};
                        return error.ExecutionContextInitFailed;
                    };
                }
            }
        }

        if (global.stdlib_path) |sp| {
            ec.ctx.stdlib_path = ec.ctx.quotationAllocator().dupe(u8, sp) catch null;
        } else if (std.posix.getenv("ONEZ_STDLIB")) |env_val| {
            ec.ctx.stdlib_path = ec.ctx.quotationAllocator().dupe(u8, env_val) catch null;
        } else {
            var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (std.fs.selfExeDirPath(&self_exe_buf)) |exe_dir| {
                const default_lib = std.fs.path.join(ec.ctx.quotationAllocator(), &.{ exe_dir, "../lib" }) catch null;
                if (default_lib) |lib_path| {
                    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
                    if (std.fs.cwd().realpath(lib_path, &real_buf)) |real| {
                        ec.ctx.stdlib_path = ec.ctx.quotationAllocator().dupe(u8, real) catch null;
                    } else |_| {}
                }
            } else |_| {}
        }

        if (bench_enabled) {
            ec.ctx.benchmark = bench_stats_ptr;
        }
        if (ec.profile_enabled) {
            ec.ctx.profile = profile_stats_ptr;
        }

        const prelude_path = global.prelude_path orelse std.posix.getenv("ONEZ_PRELUDE");
        if (prelude_path) |path| {
            ec.external_prelude = std.fs.cwd().readFileAlloc(gpa, path, 10 * 1024 * 1024) catch |err| {
                err_writer.print("Error: cannot read prelude '{s}': {any}\n", .{ path, err }) catch {};
                err_writer.flush() catch {};
                return error.ExecutionContextInitFailed;
            };
        }
        errdefer if (ec.external_prelude) |ep| gpa.free(ep);

        ec.ctx.loadPrelude(ec.external_prelude) catch |err| {
            std.debug.panic("Failed to load prelude: {any}", .{err});
        };
        ec.ctx.compile_mode = exec.compile_mode;
        ec.ctx.allow_all_recursion = exec.allow_all_recursion;

        if (bench_enabled) {
            bench_stats_ptr.collectPreludeInventory(
                if (ec.ctx.local_frames.items.len > 0) ec.ctx.local_frames.items[0].count() else 0,
                ec.ctx.dispatch.entries.count(),
                ec.ctx.dispatch.native_entries.count(),
                ec.ctx.builtin_type_values.count(),
                if (ec.ctx.type_registry_frames.items.len > 0) ec.ctx.type_registry_frames.items[0].enum_registry.count() else 0,
                ec.ctx.pragma_registry.count(),
                ec.ctx.virtual_type_count,
                ec.ctx.struct_type_count,
            );
            bench_stats_ptr.markPreludeEnd();
        }

        if (exec.debug_mode) {
            ec.dbg = debugger_mod.Debugger.init(alloc);
            ec.ctx.debugger = &ec.dbg.?;
            for (exec.initial_breakpoints[0..exec.initial_breakpoint_count]) |bp| {
                _ = ec.dbg.?.breakpoints.addWord(bp);
            }
            if (exec.initial_breakpoint_count > 0) {
                ec.dbg.?.stepper.mode = .continue_running;
            }
        }

        signal.install();
        return ec;
    }

    fn armWatchdog(self: *ExecutionContext, timeout_ns: u64) void {
        self.watchdog = std.Thread.spawn(.{}, testTimeoutWatchdog, .{ timeout_ns, &self.ctx }) catch null;
    }

    fn fireExitHooks(self: *ExecutionContext, exit_code: u8) void {
        hooks.fireHooks(&self.ctx, "on:exit", &.{.{ .fixnum = @intCast(exit_code) }});
    }

    fn finalizeBenchmark(self: *ExecutionContext, exec: *const ExecutionFlags) void {
        if (!self.bench_enabled) return;
        self.bench_stats.collectVariantHistogram(self.allocator, self.ctx.stack.items.items) catch {};
        self.bench_stats.stop();

        if (exec.bench_config.output != .none) {
            var buf: [8192]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buf);
            const writer = stream.writer();
            switch (exec.bench_config.output) {
                .human => self.bench_stats.formatHuman(writer) catch {},
                .json => self.bench_stats.formatJson(writer) catch {},
                .none => {},
            }
            const data = stream.getWritten();
            var written: usize = 0;
            while (written < data.len) {
                written += std.posix.write(std.posix.STDOUT_FILENO, data[written..]) catch break;
            }
        }

        self.bench_stats.deinit(self.allocator);
    }

    fn finalizeProfile(self: *ExecutionContext) void {
        if (!self.profile_enabled) return;
        if (self.profile_stats.samples.items.len == 0) return;

        var buf: [8192]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        self.profile_stats.formatHuman(self.gpa, stream.writer(), self.profile_top) catch {};
        const data = stream.getWritten();
        var written: usize = 0;
        while (written < data.len) {
            written += std.posix.write(std.posix.STDOUT_FILENO, data[written..]) catch break;
        }
    }

    fn deinit(self: *ExecutionContext) void {
        bail_stats_mod.deinitGlobal();
        if (self.watchdog) |t| t.detach();
        if (self.dbg != null) self.dbg.?.deinit();
        self.ctx.deinit();
        if (self.external_prelude) |ep| self.gpa.free(ep);
        self.profile_stats.deinit(self.allocator);
        self.gpa.destroy(self.counting_allocator);
        self.gpa.destroy(self.bench_stats);
        self.gpa.destroy(self.profile_stats);
        self.gpa.destroy(self.mem_limit);
        self.gpa.destroy(self);
    }
};

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();

    const args = std.process.argsAlloc(gpa_allocator) catch return 1;
    defer std.process.argsFree(gpa_allocator, args);

    if (args.len <= 1) return handleRepl(gpa_allocator, &.{});

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            printVersion();
            return 0;
        }
    }

    const first = args[1];

    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        printUsage();
        return 0;
    }

    if (std.mem.eql(u8, first, "run")) return handleRun(gpa_allocator, args[2..]);
    if (std.mem.eql(u8, first, "eval")) return handleEval(gpa_allocator, args[2..]);
    if (std.mem.eql(u8, first, "check")) return handleCheck(gpa_allocator, args[2..]);
    if (std.mem.eql(u8, first, "repl")) return handleRepl(gpa_allocator, args[2..]);
    if (std.mem.eql(u8, first, "fmt")) return handleFmt(gpa_allocator, args[2..]);
    if (std.mem.eql(u8, first, "lint")) return handleLint(gpa_allocator, args[2..]);
    if (std.mem.eql(u8, first, "highlight")) return handleHighlight(gpa_allocator, args[2..]);
    if (std.mem.eql(u8, first, "build")) return handleBuild(gpa_allocator, args[2..]);
    if (std.mem.eql(u8, first, "version")) {
        printVersion();
        return 0;
    }

    if (first.len > 0 and first[0] != '-') {
        if (std.fs.cwd().access(first, .{})) |_| {
            return handleRun(gpa_allocator, args[1..]);
        } else |_| {}
    }

    const stderr_file: File = .stderr();
    var stderr_buf: [1024]u8 = undefined;
    var stderr = stderr_file.writerStreaming(&stderr_buf);
    stderr.interface.print(
        "Error: unknown subcommand or file: '{s}'\nRun '1z --help' for usage.\n",
        .{first},
    ) catch {};
    stderr.interface.flush() catch {};
    return 1;
}

fn hasHelpFlag(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;
    }
    return false;
}

fn handleRun(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(&stderr_buf);
    const err_writer = &stderr.interface;

    if (hasHelpFlag(args)) {
        printRunHelp();
        return 0;
    }

    var global = GlobalFlags{};
    defer global.deinit(gpa);
    var exec = ExecutionFlags{};

    var file_path: ?[]const u8 = null;
    var program_args: std.ArrayListUnmanaged([]const u8) = .{};
    defer program_args.deinit(gpa);

    for (args) |arg| {
        if (file_path != null) {
            program_args.append(gpa, arg) catch return 1;
            continue;
        }
        const g = parseGlobalFlag(arg, &global, gpa, err_writer) catch return 1;
        if (g == .consumed) continue;
        const e = parseExecutionFlag(arg, &exec, err_writer) catch return 1;
        if (e == .consumed) continue;
        if (arg.len > 0 and arg[0] == '-') {
            err_writer.print("Error: unknown flag '{s}'\n", .{arg}) catch {};
            err_writer.flush() catch {};
            return 1;
        }
        file_path = arg;
    }

    const path = file_path orelse {
        err_writer.writeAll("Usage: 1z run [options] <file> [args...]\n") catch {};
        err_writer.flush() catch {};
        return 1;
    };

    const ec = ExecutionContext.init(gpa, &global, &exec, err_writer) catch return 1;
    defer ec.deinit();

    ec.ctx.program_args = program_args.items;

    if (exec.test_timeout_ns) |timeout_ns| {
        ec.armWatchdog(timeout_ns);
    }

    const result = batch(&ec.ctx, path, exec.show_stack);
    ec.fireExitHooks(result);
    ec.finalizeBenchmark(&exec);
    ec.finalizeProfile();
    return result;
}

fn handleCheck(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(&stderr_buf);
    const err_writer = &stderr.interface;

    if (hasHelpFlag(args)) {
        printCheckHelp();
        return 0;
    }

    var global = GlobalFlags{};
    defer global.deinit(gpa);
    var exec = ExecutionFlags{};

    var file_path: ?[]const u8 = null;

    for (args) |arg| {
        const g = parseGlobalFlag(arg, &global, gpa, err_writer) catch return 1;
        if (g == .consumed) continue;
        const e = parseExecutionFlag(arg, &exec, err_writer) catch return 1;
        if (e == .consumed) continue;
        if (arg.len > 0 and arg[0] == '-') {
            err_writer.print("Error: unknown flag '{s}'\n", .{arg}) catch {};
            err_writer.flush() catch {};
            return 1;
        }
        if (file_path != null) {
            err_writer.writeAll("Error: `check` accepts a single file argument\n") catch {};
            err_writer.flush() catch {};
            return 1;
        }
        file_path = arg;
    }

    if (exec.cli_set_compile) {
        err_writer.writeAll("Error: 'check' does not accept --compile\n") catch {};
        err_writer.flush() catch {};
        return 1;
    }
    if (exec.bench_config.enabled) {
        err_writer.writeAll("Error: 'check' does not accept --benchmark\n") catch {};
        err_writer.flush() catch {};
        return 1;
    }
    if (exec.profile_config.enabled) {
        err_writer.writeAll("Error: 'check' does not accept --profile\n") catch {};
        err_writer.flush() catch {};
        return 1;
    }
    if (exec.cli_set_profile_top) {
        err_writer.writeAll("Error: 'check' does not accept --profile-top\n") catch {};
        err_writer.flush() catch {};
        return 1;
    }

    const path = file_path orelse {
        err_writer.writeAll("Usage: 1z check [options] <file>\n") catch {};
        err_writer.flush() catch {};
        return 1;
    };

    const ec = ExecutionContext.init(gpa, &global, &exec, err_writer) catch return 1;
    defer ec.deinit();

    ec.ctx.check_mode = true;

    if (exec.test_timeout_ns) |timeout_ns| {
        ec.armWatchdog(timeout_ns);
    }

    const result = batch(&ec.ctx, path, exec.show_stack);
    ec.fireExitHooks(result);
    ec.finalizeBenchmark(&exec);
    return result;
}

fn handleRepl(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(&stderr_buf);
    const err_writer = &stderr.interface;

    if (hasHelpFlag(args)) {
        printReplHelp();
        return 0;
    }

    var global = GlobalFlags{};
    defer global.deinit(gpa);
    var exec = ExecutionFlags{};

    for (args) |arg| {
        const g = parseGlobalFlag(arg, &global, gpa, err_writer) catch return 1;
        if (g == .consumed) continue;
        const e = parseExecutionFlag(arg, &exec, err_writer) catch return 1;
        if (e == .consumed) continue;
        if (arg.len > 0 and arg[0] == '-') {
            err_writer.print("Error: unknown flag '{s}'\n", .{arg}) catch {};
            err_writer.flush() catch {};
            return 1;
        }
        err_writer.print("Error: 'repl' does not accept positional arguments: '{s}'\n", .{arg}) catch {};
        err_writer.flush() catch {};
        return 1;
    }

    const ec = ExecutionContext.init(gpa, &global, &exec, err_writer) catch return 1;
    defer ec.deinit();

    repl(&ec.ctx, exec.verbosity, global.max_memory_bytes);
    ec.fireExitHooks(0);
    ec.finalizeBenchmark(&exec);
    ec.finalizeProfile();
    return 0;
}

fn handleEval(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(&stderr_buf);
    const err_writer = &stderr.interface;

    if (hasHelpFlag(args)) {
        printEvalHelp();
        return 0;
    }

    var global = GlobalFlags{};
    defer global.deinit(gpa);
    var exec = ExecutionFlags{};

    var expression: ?[]const u8 = null;
    var print_top: bool = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-p")) {
            print_top = true;
            continue;
        }
        const g = parseGlobalFlag(arg, &global, gpa, err_writer) catch return 1;
        if (g == .consumed) continue;
        const e = parseExecutionFlag(arg, &exec, err_writer) catch return 1;
        if (e == .consumed) continue;
        if (arg.len > 0 and arg[0] == '-') {
            err_writer.print("Error: unknown flag '{s}'\n", .{arg}) catch {};
            err_writer.flush() catch {};
            return 1;
        }
        if (expression != null) {
            err_writer.writeAll("Error: `eval` accepts a single expression string\n") catch {};
            err_writer.flush() catch {};
            return 1;
        }
        expression = arg;
    }

    const code = expression orelse {
        err_writer.writeAll("Usage: 1z eval [options] '<expression>'\n") catch {};
        err_writer.flush() catch {};
        return 1;
    };

    const ec = ExecutionContext.init(gpa, &global, &exec, err_writer) catch return 2;
    defer ec.deinit();

    if (exec.test_timeout_ns) |timeout_ns| {
        ec.armWatchdog(timeout_ns);
    }

    const result = runEval(&ec.ctx, code, print_top, exec.show_stack, err_writer);
    ec.fireExitHooks(result);
    ec.finalizeBenchmark(&exec);
    ec.finalizeProfile();
    return result;
}

/// Exit codes: 0 = truthy/empty, 1 = TOS is `f`, 2 = parse/runtime error.
fn runEval(
    ctx: *Context,
    code: []const u8,
    print_top: bool,
    show_stack: bool,
    err_writer: anytype,
) u8 {
    ctx.current_source = "<eval>";

    ctx.pushLocalFrame() catch return 2;
    defer ctx.popLocalFrame();
    ctx.pushPragmaFrame() catch return 2;
    defer ctx.popPragmaFrame();

    const old_import_frame = ctx.import_frame_index;
    ctx.import_frame_index = ctx.local_frames.items.len - 1;
    defer ctx.import_frame_index = old_import_frame;

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    const alloc = ctx.quotationAllocator();

    var start: usize = 0;
    var line_num: usize = 0;
    while (start < code.len) {
        const end = std.mem.indexOfScalarPos(u8, code, start, '\n') orelse code.len;
        const line = code[start..end];
        start = end + 1;
        line_num += 1;
        processor.trackLine(line_num);

        switch (processor.feedLine(alloc, line, ctx)) {
            .needs_more_input => continue,
            .parse_error => |err| {
                if (ctx.parse_diagnostics != null) {
                    printParseDiagnostics(ctx, err_writer, ctx.current_source, line_num, processor.start_line);
                } else {
                    err_writer.print("Error: {any}\n", .{err}) catch {};
                }
                err_writer.flush() catch {};
                ctx.clearExecutionDetails();
                return 2;
            },
            .complete => |instrs| {
                if (instrs.len > 0) {
                    ctx.executeQuotation(.{ .instructions = instrs }) catch |err| {
                        printErrorDetails(ctx, err_writer, err);
                        err_writer.flush() catch {};
                        return 2;
                    };
                }
                processor.reset();
            },
        }
    }

    switch (processor.flush(alloc, ctx)) {
        .needs_more_input => {},
        .parse_error => |err| {
            if (ctx.parse_diagnostics != null) {
                printParseDiagnostics(ctx, err_writer, ctx.current_source, line_num, processor.start_line);
            } else {
                err_writer.print("Error: {any}\n", .{err}) catch {};
            }
            err_writer.flush() catch {};
            ctx.clearExecutionDetails();
            return 2;
        },
        .complete => |instrs| {
            if (instrs.len > 0) {
                ctx.executeQuotation(.{ .instructions = instrs }) catch |err| {
                    printErrorDetails(ctx, err_writer, err);
                    err_writer.flush() catch {};
                    return 2;
                };
            }
        },
    }

    const stack_items = ctx.stack.items.items;
    const exit_code: u8 = blk: {
        if (stack_items.len == 0) break :blk 0;
        const top = stack_items[stack_items.len - 1];
        switch (top) {
            .boolean => |b| break :blk if (b) 0 else 1,
            else => break :blk 0,
        }
    };

    if (print_top and ctx.stack.items.items.len > 0) {
        const top_copy = ctx.stack.items.items[ctx.stack.items.items.len - 1];
        ctx.stack.push(top_copy) catch return 2;

        const instrs = [_]Instruction{.{ .op = .{ .call_word = "inspect" }, .line = 0 }};
        ctx.executeQuotation(.{ .instructions = &instrs }) catch |err| {
            printErrorDetails(ctx, err_writer, err);
            err_writer.flush() catch {};
            return 2;
        };

        const stdout_file: File = .stdout();
        var stdout_buf: [4096]u8 = undefined;
        var stdout = stdout_file.writerStreaming(&stdout_buf);
        const out = &stdout.interface;

        const inspected = ctx.stack.pop() catch return 2;
        switch (inspected) {
            .string => |s| {
                out.writeAll(s) catch {};
                out.writeAll("\n") catch {};
            },
            else => {
                inspected.write(out) catch {};
                out.writeAll("\n") catch {};
            },
        }
        out.flush() catch {};
    }

    if (show_stack) {
        const stdout_file: File = .stdout();
        var stdout_buf: [4096]u8 = undefined;
        var stdout = stdout_file.writerStreaming(&stdout_buf);
        const out = &stdout.interface;
        out.writeAll("Stack: ") catch {};
        ctx.stack.dump(out) catch {};
        out.writeAll("\n") catch {};
        out.flush() catch {};
    }

    return exit_code;
}

fn testTimeoutWatchdog(timeout_ns: u64, ctx: *Context) void {
    std.Thread.sleep(timeout_ns);
    var tw = trace_mod.TraceWriter.init();
    const secs = @as(f64, @floatFromInt(timeout_ns)) /
        @as(f64, @floatFromInt(@as(u64, std.time.ns_per_s)));
    tw.print("TEST-TIMEOUT: {d:.1}s limit reached\n", .{secs});
    if (ctx.active_scheduler.load(.acquire)) |sched| {
        sched.dumpAllTasks();
    }
    std.process.exit(124);
}

fn handleFmt(base_allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(&stderr_buf);
    const err_writer = &stderr.interface;

    var global = GlobalFlags{};
    defer global.deinit(base_allocator);

    var check_only = false;
    var stdout_mode = false;
    var paths: std.ArrayListUnmanaged([]const u8) = .{};
    defer paths.deinit(base_allocator);

    for (args) |arg| {
        const g = parseGlobalFlag(arg, &global, base_allocator, err_writer) catch return 1;
        if (g == .consumed) continue;
        if (std.mem.eql(u8, arg, "--check")) {
            check_only = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--stdout")) {
            stdout_mode = true;
            continue;
        }
        paths.append(base_allocator, arg) catch {
            err_writer.writeAll("Error: out of memory\n") catch {};
            err_writer.flush() catch {};
            return 1;
        };
    }

    if (!global.cli_set_max_memory) {
        if (std.posix.getenv("ONEZ_MAX_MEMORY")) |env_val| {
            if (memory_limit.parseSize(env_val)) |bytes| {
                global.max_memory_bytes = bytes;
            }
            // Silently ignore invalid env var values.
        }
    }

    var mem_limit = MemoryLimitAllocator.init(base_allocator, global.max_memory_bytes);
    const allocator = mem_limit.allocator();

    if (paths.items.len == 0) {
        err_writer.writeAll("Usage: 1z fmt [--check] [--stdout] <file...>\n") catch {};
        err_writer.writeAll("       1z fmt [--check] .\n") catch {};
        err_writer.flush() catch {};
        return 1;
    }

    // --stdout mode: format files and print to stdout
    if (stdout_mode) {
        const stdout_file: File = .stdout();
        var stdout_buf: [4096]u8 = undefined;
        var stdout = stdout_file.writerStreaming(&stdout_buf);
        const out_writer = &stdout.interface;

        for (paths.items) |path| {
            const content = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
                err_writer.print("Error reading '{s}': {any}\n", .{ path, err }) catch {};
                err_writer.flush() catch {};
                return 1;
            };
            defer allocator.free(content);

            const formatted = formatter.formatString(allocator, content) catch |err| {
                err_writer.print("Error formatting '{s}': {any}\n", .{ path, err }) catch {};
                err_writer.flush() catch {};
                return 1;
            };
            defer allocator.free(formatted);

            out_writer.writeAll(formatted) catch {};
        }

        out_writer.flush() catch {};
        return 0;
    }

    var any_changes = false;
    var any_errors = false;

    for (paths.items) |path| {
        // Check if path is a directory
        const stat = std.fs.cwd().statFile(path) catch |err| {
            err_writer.print("Error accessing '{s}': {any}\n", .{ path, err }) catch {};
            any_errors = true;
            continue;
        };

        if (stat.kind == .directory) {
            const result = formatDirectory(allocator, path, check_only, err_writer);
            if (result.had_errors) any_errors = true;
            if (result.had_changes) any_changes = true;
        } else {
            const result = formatSingleFile(allocator, path, check_only, err_writer);
            if (result.had_errors) any_errors = true;
            if (result.had_changes) any_changes = true;
        }
    }

    err_writer.flush() catch {};

    if (any_errors) return 1;
    if (check_only and any_changes) return 1;
    return 0;
}

const FormatResult = struct {
    had_errors: bool,
    had_changes: bool,
};

fn formatSingleFile(allocator: std.mem.Allocator, path: []const u8, check_only: bool, err_writer: anytype) FormatResult {
    if (check_only) {
        const is_formatted = formatter.checkFile(allocator, path) catch |err| {
            err_writer.print("Error checking '{s}': {any}\n", .{ path, err }) catch {};
            return .{ .had_errors = true, .had_changes = false };
        };
        if (!is_formatted) {
            err_writer.print("{s} needs formatting\n", .{path}) catch {};
            return .{ .had_errors = false, .had_changes = true };
        }
        return .{ .had_errors = false, .had_changes = false };
    } else {
        formatter.formatFile(allocator, path) catch |err| {
            err_writer.print("Error formatting '{s}': {any}\n", .{ path, err }) catch {};
            return .{ .had_errors = true, .had_changes = false };
        };
        return .{ .had_errors = false, .had_changes = false };
    }
}

fn formatDirectory(allocator: std.mem.Allocator, dir_path: []const u8, check_only: bool, err_writer: anytype) FormatResult {
    var result = FormatResult{ .had_errors = false, .had_changes = false };

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        err_writer.print("Error opening directory '{s}': {any}\n", .{ dir_path, err }) catch {};
        return .{ .had_errors = true, .had_changes = false };
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".1z")) continue;

        // Build full path
        const full_path = if (std.mem.eql(u8, dir_path, "."))
            allocator.dupe(u8, entry.name) catch {
                result.had_errors = true;
                continue;
            }
        else
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name }) catch {
                result.had_errors = true;
                continue;
            };
        defer allocator.free(full_path);

        const file_result = formatSingleFile(allocator, full_path, check_only, err_writer);
        if (file_result.had_errors) result.had_errors = true;
        if (file_result.had_changes) result.had_changes = true;
    }

    return result;
}

fn handleLint(base_allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(&stderr_buf);
    const err_writer = &stderr.interface;

    if (hasHelpFlag(args)) {
        printLintHelp();
        return 0;
    }

    var global = GlobalFlags{};
    defer global.deinit(base_allocator);

    var paths: std.ArrayListUnmanaged([]const u8) = .{};
    defer paths.deinit(base_allocator);

    for (args) |arg| {
        const g = parseGlobalFlag(arg, &global, base_allocator, err_writer) catch return 2;
        if (g == .consumed) continue;
        if (arg.len > 0 and arg[0] == '-') {
            err_writer.print("Error: unknown flag '{s}'\n", .{arg}) catch {};
            err_writer.flush() catch {};
            return 2;
        }
        paths.append(base_allocator, arg) catch {
            err_writer.writeAll("Error: out of memory\n") catch {};
            err_writer.flush() catch {};
            return 2;
        };
    }

    if (!global.cli_set_max_memory) {
        if (std.posix.getenv("ONEZ_MAX_MEMORY")) |env_val| {
            if (memory_limit.parseSize(env_val)) |bytes| {
                global.max_memory_bytes = bytes;
            }
        }
    }

    if (paths.items.len == 0) {
        err_writer.writeAll("Usage: 1z lint [options] <file|dir...>\n") catch {};
        err_writer.flush() catch {};
        return 2;
    }

    // Resolve file paths: expand directories to .1z files
    var resolved: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (resolved.items) |p| base_allocator.free(p);
        resolved.deinit(base_allocator);
    }

    for (paths.items) |path| {
        const stat = std.fs.cwd().statFile(path) catch |err| {
            err_writer.print("Error: cannot access '{s}': {any}\n", .{ path, err }) catch {};
            err_writer.flush() catch {};
            return 2;
        };

        if (stat.kind == .directory) {
            if (!collectLintFiles(base_allocator, path, &resolved, err_writer)) return 2;
        } else {
            const duped = base_allocator.dupe(u8, path) catch {
                err_writer.writeAll("Error: out of memory\n") catch {};
                err_writer.flush() catch {};
                return 2;
            };
            resolved.append(base_allocator, duped) catch {
                base_allocator.free(duped);
                err_writer.writeAll("Error: out of memory\n") catch {};
                err_writer.flush() catch {};
                return 2;
            };
        }
    }

    if (resolved.items.len == 0) {
        err_writer.writeAll("Error: no .1z files found\n") catch {};
        err_writer.flush() catch {};
        return 2;
    }

    // Set up execution context to run the 1z lint library
    var exec = ExecutionFlags{};
    if (std.posix.getenv("ONEZ_COMPILE")) |env_val| {
        if (std.mem.eql(u8, env_val, "eager")) {
            exec.compile_mode = .eager;
        } else if (std.mem.eql(u8, env_val, "hybrid")) {
            exec.compile_mode = .hybrid;
        }
    }

    const ec = ExecutionContext.init(base_allocator, &global, &exec, err_writer) catch return 2;
    defer ec.deinit();

    ec.ctx.program_args = resolved.items;

    const code = "use \"lint\" ; use \"lint-rules\" ; command-line-args run-lint";
    const result = runEval(&ec.ctx, code, false, false, err_writer);
    ec.fireExitHooks(result);
    return result;
}

fn collectLintFiles(allocator: std.mem.Allocator, dir_path: []const u8, list: *std.ArrayListUnmanaged([]const u8), err_writer: anytype) bool {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        err_writer.print("Error: cannot open directory '{s}': {any}\n", .{ dir_path, err }) catch {};
        err_writer.flush() catch {};
        return false;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        // Skip hidden entries
        if (entry.name.len > 0 and entry.name[0] == '.') continue;

        if (entry.kind == .directory) {
            const sub_path = if (std.mem.eql(u8, dir_path, "."))
                allocator.dupe(u8, entry.name) catch return false
            else
                std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name }) catch return false;
            defer allocator.free(sub_path);
            if (!collectLintFiles(allocator, sub_path, list, err_writer)) return false;
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".1z")) {
            const full_path = if (std.mem.eql(u8, dir_path, "."))
                allocator.dupe(u8, entry.name) catch return false
            else
                std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name }) catch return false;
            list.append(allocator, full_path) catch {
                allocator.free(full_path);
                return false;
            };
        }
    }

    return true;
}

fn printQuotationFallbackWarnings(
    diagnostics: *ir_codegen.CodegenDiagnostics,
    allow_interpreter_fallback: bool,
    err_writer: anytype,
    allocator: std.mem.Allocator,
) void {
    if (diagnostics.quotation_fallbacks.len == 0) return;
    if (!allow_interpreter_fallback) {
        for (diagnostics.quotation_fallbacks) |w| {
            err_writer.print("Warning: '{s}' parameter '{s}' has {s}; quotation call falls back to interpreter\n", .{
                w.word_name,
                w.param_name,
                @as([]const u8, switch (w.reason) {
                    .row_variables => "row-variable effect",
                    .no_annotation => "no effect annotation",
                }),
            }) catch {};
        }
        err_writer.flush() catch {};
    }
    allocator.free(diagnostics.quotation_fallbacks);
    diagnostics.quotation_fallbacks = &.{};
}

fn printPreludeStats(
    stats: *const ir_codegen.PreludeStats,
    err_writer: anytype,
) void {
    if (stats.total == 0) return;
    const pct = @as(f64, @floatFromInt(stats.compiled)) / @as(f64, @floatFromInt(stats.total)) * 100.0;
    err_writer.print("Prelude compilation: {d}/{d} words compiled ({d:.1}%)\n", .{
        stats.compiled,
        stats.total,
        pct,
    }) catch {};
    for (stats.uncompiled) |entry| {
        err_writer.print("  word '{s}' cannot be compiled\n", .{entry.name}) catch {};
        err_writer.print("      {s}: {s}\n", .{ entry.reason.code(), entry.reason.message() }) catch {};
        if (entry.reason.hint()) |h| {
            err_writer.print("      hint: {s}\n", .{h}) catch {};
        }
    }
    err_writer.flush() catch {};
}

fn printQuotationStats(
    quotations: []const aot_freeze.AotQuotationDesc,
    err_writer: anytype,
) void {
    var compiled_count: usize = 0;
    for (quotations) |q| {
        if (q.compiled) compiled_count += 1;
    }
    if (quotations.len > 0) {
        const pct = @as(f64, @floatFromInt(compiled_count)) / @as(f64, @floatFromInt(quotations.len)) * 100.0;
        err_writer.print("Quotation bodies compiled: {d}/{d} ({d:.1}%)\n", .{ compiled_count, quotations.len, pct }) catch {};
    } else {
        err_writer.print("Quotation bodies compiled: 0\n", .{}) catch {};
    }
    err_writer.flush() catch {};
}

fn printInterpreterFallbackDecision(
    diagnostics: *const ir_codegen.CodegenDiagnostics,
    err_writer: anytype,
) void {
    const resolved = diagnostics.resolved_interpreter_fallback orelse return;
    switch (resolved) {
        .true => {
            err_writer.writeAll("Interpreter fallback: included (auto: compiled code calls interpreter)\n") catch {};
        },
        .false => {
            err_writer.writeAll("Interpreter fallback: not needed (auto: all code fully compiled)\n") catch {};
        },
        .auto => unreachable,
    }
    err_writer.flush() catch {};
}

fn printPicStats(
    diagnostics: *const ir_codegen.CodegenDiagnostics,
    err_writer: anytype,
) void {
    const stats = &diagnostics.pic_stats;
    if (stats.sites_attempted == 0 and stats.sites_emitted == 0) return;
    err_writer.print("Inline PIC sites: {d}/{d} generic call sites preseeded\n", .{
        stats.sites_emitted,
        stats.sites_attempted,
    }) catch {};
    err_writer.flush() catch {};
}

fn handleHighlight(base_allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(&stderr_buf);
    const err_writer = &stderr.interface;

    if (hasHelpFlag(args)) {
        printHighlightHelp();
        return 0;
    }

    var global = GlobalFlags{};
    defer global.deinit(base_allocator);

    var html_mode = false;
    var theme_path: []const u8 = "";
    var file_path: ?[]const u8 = null;

    for (args) |arg| {
        const g = parseGlobalFlag(arg, &global, base_allocator, err_writer) catch return 2;
        if (g == .consumed) continue;
        if (std.mem.eql(u8, arg, "--html")) {
            html_mode = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--theme=")) {
            theme_path = arg["--theme=".len..];
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') {
            err_writer.print("Error: unknown flag '{s}'\n", .{arg}) catch {};
            err_writer.flush() catch {};
            return 2;
        }
        if (file_path != null) {
            err_writer.writeAll("Error: only one file argument is allowed\n") catch {};
            err_writer.flush() catch {};
            return 2;
        }
        file_path = arg;
    }

    if (!global.cli_set_max_memory) {
        if (std.posix.getenv("ONEZ_MAX_MEMORY")) |env_val| {
            if (memory_limit.parseSize(env_val)) |bytes| {
                global.max_memory_bytes = bytes;
            }
        }
    }

    // program_args: [path-or-"-", "ansi"/"html", theme-path-or-""]
    const path_arg = file_path orelse "-";
    const format_arg: []const u8 = if (html_mode) "html" else "ansi";
    const program_args = [_][]const u8{ path_arg, format_arg, theme_path };

    var exec = ExecutionFlags{};
    if (std.posix.getenv("ONEZ_COMPILE")) |env_val| {
        if (std.mem.eql(u8, env_val, "eager")) {
            exec.compile_mode = .eager;
        } else if (std.mem.eql(u8, env_val, "hybrid")) {
            exec.compile_mode = .hybrid;
        }
    }

    const ec = ExecutionContext.init(base_allocator, &global, &exec, err_writer) catch return 2;
    defer ec.deinit();

    ec.ctx.program_args = &program_args;

    const code = "use \"highlight\" ; command-line-args run-highlight-cli";
    const result = runEval(&ec.ctx, code, false, false, err_writer);
    ec.fireExitHooks(result);
    return result;
}

fn handleBuild(base_allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(&stderr_buf);
    const err_writer = &stderr.interface;

    // Parse build-specific args.
    var global = GlobalFlags{};
    defer global.deinit(base_allocator);

    var source_file: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var allow_interpreter_fallback = false;
    var compilation_stats = false;
    var compile_all_prelude = false;
    var save_temps = false;
    var interpreter_fallback: ir_codegen.InterpreterFallbackMode = .auto;
    var lock_interpreter_setting = false;
    var static_libs: std.ArrayListUnmanaged([]const u8) = .{};
    defer static_libs.deinit(base_allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                err_writer.writeAll("Error: -o requires an argument\n") catch {};
                err_writer.flush() catch {};
                return 1;
            }
            output_path = args[i];
            continue;
        }
        const g = parseGlobalFlag(arg, &global, base_allocator, err_writer) catch return 1;
        if (g == .consumed) continue;
        if (std.mem.eql(u8, arg, "--allow-interpreter-fallback")) {
            allow_interpreter_fallback = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--compilation-stats")) {
            compilation_stats = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--compile-all-prelude")) {
            compile_all_prelude = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--save-temps")) {
            save_temps = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--link-static=")) {
            static_libs.append(base_allocator, arg["--link-static=".len..]) catch {
                err_writer.writeAll("Error: out of memory\n") catch {};
                err_writer.flush() catch {};
                return 1;
            };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--interpreter-fallback=")) {
            const value = arg["--interpreter-fallback=".len..];
            if (std.mem.eql(u8, value, "true")) {
                interpreter_fallback = .true;
            } else if (std.mem.eql(u8, value, "false")) {
                interpreter_fallback = .false;
            } else if (std.mem.eql(u8, value, "auto")) {
                interpreter_fallback = .auto;
            } else {
                err_writer.print("Error: --interpreter-fallback must be 'true', 'false', or 'auto', got '{s}'\n", .{value}) catch {};
                err_writer.flush() catch {};
                return 1;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--lock-interpreter-setting")) {
            lock_interpreter_setting = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            err_writer.print("Error: unknown flag '{s}'\n", .{arg}) catch {};
            err_writer.flush() catch {};
            return 1;
        }
        if (source_file != null) {
            err_writer.writeAll("Error: multiple source files not supported\n") catch {};
            err_writer.flush() catch {};
            return 1;
        }
        source_file = arg;
    }

    // Validate flag combinations.
    if (lock_interpreter_setting and interpreter_fallback == .auto) {
        err_writer.writeAll("Error: --lock-interpreter-setting requires --interpreter-fallback=true or --interpreter-fallback=false\n") catch {};
        err_writer.flush() catch {};
        return 1;
    }

    // Apply ONEZ_MAX_MEMORY fallback if --max-memory was not set.
    if (!global.cli_set_max_memory) {
        if (std.posix.getenv("ONEZ_MAX_MEMORY")) |env_val| {
            if (memory_limit.parseSize(env_val)) |bytes| {
                global.max_memory_bytes = bytes;
            }
            // Silently ignore invalid env var values.
        }
    }

    // Wrap the allocator in a memory limit for the rest of the build.
    var mem_limit = MemoryLimitAllocator.init(base_allocator, global.max_memory_bytes);
    const allocator = mem_limit.allocator();

    const source = source_file orelse {
        err_writer.writeAll("Usage: 1z build <file.1z> [-o <output>] [--save-temps] [--compilation-stats] [--compile-all-prelude] [--interpreter-fallback=true|false|auto] [--lock-interpreter-setting]\n") catch {};
        err_writer.flush() catch {};
        return 1;
    };

    // Default output path: strip .1z extension.
    const output = output_path orelse blk: {
        if (std.mem.endsWith(u8, source, ".1z")) {
            break :blk source[0 .. source.len - 3];
        }
        break :blk "a.out";
    };

    // Initialize context for module graph freezing.
    var ctx_obj = Context.init(allocator);
    defer ctx_obj.deinit();
    const ctx = &ctx_obj;

    // Discover stdlib path.
    var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    var exe_dir_slice: ?[]const u8 = null;
    if (std.fs.selfExeDirPath(&self_exe_buf)) |exe_dir| {
        exe_dir_slice = exe_dir;
        if (global.stdlib_path) |sp| {
            ctx.stdlib_path = sp;
        } else {
            const lib_path = std.fs.path.join(allocator, &.{ exe_dir, "../lib" }) catch null;
            if (lib_path) |lp| {
                var real_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (std.fs.cwd().realpath(lp, &real_buf)) |real| {
                    ctx.stdlib_path = ctx.quotationAllocator().dupe(u8, real) catch null;
                } else |_| {}
                allocator.free(lp);
            }
        }
    } else |_| {
        if (global.stdlib_path) |sp| {
            ctx.stdlib_path = sp;
        }
    }

    for (global.load_paths.items) |lp| {
        const duped = ctx.quotationAllocator().dupe(u8, lp) catch continue;
        ctx.load_paths.append(allocator, duped) catch continue;
    }

    ctx.loadPrelude(global.prelude_path) catch |err| {
        err_writer.print("Error loading prelude: {s}\n", .{@errorName(err)}) catch {};
        err_writer.flush() catch {};
        return 1;
    };

    // Stage 1: Freeze module graph and emit C source.
    var freeze_diagnostics: aot_freeze.FreezeDiagnostics = .{};
    var freeze_result = aot_freeze.freezeModuleGraphOpts(ctx, source, &freeze_diagnostics, allocator, .{
        .compile_all_prelude = compile_all_prelude,
    }) catch |err| {
        if (err == error.MissingStackEffects) {
            for (freeze_diagnostics.missing_stack_effects) |name| {
                err_writer.print(
                    "Error: word '{s}' has no stack effect declaration\n",
                    .{name},
                ) catch {};
            }
            allocator.free(freeze_diagnostics.missing_stack_effects);
        } else if (err == error.DisallowedDynamicFeature) {
            if (freeze_diagnostics.fatal_dynamic_feature) |feature_use| {
                err_writer.print(
                    "Error: AOT build disallows dynamic feature '{s}' in '{s}'\n",
                    .{ feature_use.feature_name, feature_use.caller_name },
                ) catch {};
            } else {
                err_writer.writeAll("Error: AOT build disallows a dynamic feature\n") catch {};
            }
        } else {
            err_writer.print("Error freezing module graph: {s}\n", .{@errorName(err)}) catch {};
        }
        err_writer.flush() catch {};
        return 1;
    };
    defer freeze_result.deinit(allocator);

    if (freeze_result.warnings.len > 0) {
        for (freeze_result.warnings) |warning| {
            err_writer.print(
                "Warning: AOT build may diverge at runtime: '{s}' in '{s}'\n",
                .{ warning.feature_name, warning.caller_name },
            ) catch {};
        }
        err_writer.flush() catch {};
    }

    var codegen_diagnostics: ir_codegen.CodegenDiagnostics = .{};
    defer if (codegen_diagnostics.prelude_stats.uncompiled.len > 0)
        allocator.free(codegen_diagnostics.prelude_stats.uncompiled);
    const c_source = ir_codegen.emitProgramC(
        freeze_result.words,
        freeze_result.quotations,
        freeze_result.entry_word_id,
        freeze_result.max_word_id,
        static_libs.items,
        interpreter_fallback,
        lock_interpreter_setting,
        &codegen_diagnostics,
        ctx,
        allocator,
    ) catch |err| {
        printQuotationFallbackWarnings(&codegen_diagnostics, allow_interpreter_fallback, err_writer, allocator);
        if (compilation_stats) {
            printPreludeStats(&codegen_diagnostics.prelude_stats, err_writer);
            printQuotationStats(freeze_result.quotations, err_writer);
            printPicStats(&codegen_diagnostics, err_writer);
        }
        if (err == error.UncompiledWords) {
            const items = codegen_diagnostics.uncompiled_words;
            err_writer.print(
                "Error: {d} word{s} could not be compiled to C\n",
                .{ items.len, if (items.len == 1) @as([]const u8, "") else "s" },
            ) catch {};
            for (items) |entry| {
                err_writer.print("  word '{s}': {s}: {s}\n", .{
                    entry.name,
                    entry.reason.code(),
                    entry.reason.message(),
                }) catch {};
                if (entry.reason.hint()) |h| {
                    err_writer.print("      hint: {s}\n", .{h}) catch {};
                }
            }
            allocator.free(items);
        } else if (err == error.UncompiledQuotations) {
            for (codegen_diagnostics.uncompiled_quotations) |q| {
                err_writer.print(
                    "Error: quotation body '{s}' could not be compiled\n",
                    .{q.c_name},
                ) catch {};
            }
            allocator.free(codegen_diagnostics.uncompiled_quotations);
        } else {
            err_writer.print("Error generating C source: {s}\n", .{@errorName(err)}) catch {};
        }
        err_writer.flush() catch {};
        return 1;
    };
    defer allocator.free(c_source);

    if (compilation_stats) {
        printPreludeStats(&codegen_diagnostics.prelude_stats, err_writer);
        printQuotationStats(freeze_result.quotations, err_writer);
        printPicStats(&codegen_diagnostics, err_writer);
        printInterpreterFallbackDecision(&codegen_diagnostics, err_writer);
    }

    printQuotationFallbackWarnings(&codegen_diagnostics, allow_interpreter_fallback, err_writer, allocator);

    // When fallback=false, require all words to compile including prelude words.
    // Non-prelude failures are already caught by emitProgramC (error.UncompiledWords).
    if (interpreter_fallback == .false) {
        const stats = &codegen_diagnostics.prelude_stats;
        if (stats.uncompiled.len > 0) {
            err_writer.print(
                "Error: --interpreter-fallback=false requires all words to compile; {d} word{s} need the interpreter\n",
                .{ stats.uncompiled.len, if (stats.uncompiled.len == 1) @as([]const u8, "") else "s" },
            ) catch {};
            for (stats.uncompiled) |entry| {
                const module = if (std.mem.indexOfScalar(u8, entry.name, '.')) |dot_idx|
                    entry.name[0..dot_idx]
                else
                    "prelude";
                err_writer.print("  word '{s}' ({s}): {s}: {s}\n", .{
                    entry.name,
                    module,
                    entry.reason.code(),
                    entry.reason.message(),
                }) catch {};
                if (entry.reason.hint()) |h| {
                    err_writer.print("      hint: {s}\n", .{h}) catch {};
                }
            }
            err_writer.flush() catch {};
            return 1;
        }
    }

    // Write C source to a temp file.
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    const pid = std.c.getpid();
    const tmp_path = std.fmt.allocPrint(allocator, "{s}/1z_aot_{d}.c", .{ tmpdir, pid }) catch {
        err_writer.writeAll("Error: out of memory\n") catch {};
        err_writer.flush() catch {};
        return 1;
    };
    defer allocator.free(tmp_path);

    const tmp_file = std.fs.cwd().createFile(tmp_path, .{}) catch |err| {
        err_writer.print("Error creating temp file '{s}': {s}\n", .{ tmp_path, @errorName(err) }) catch {};
        err_writer.flush() catch {};
        return 1;
    };
    tmp_file.writeAll(c_source) catch |err| {
        tmp_file.close();
        err_writer.print("Error writing temp file: {s}\n", .{@errorName(err)}) catch {};
        err_writer.flush() catch {};
        return 1;
    };
    tmp_file.close();
    // Temp file cleanup is at the end, after we know the cc result.

    // Discover lib1z.a path relative to this executable.
    const lib1z_path = if (exe_dir_slice) |exe_dir|
        std.fs.path.join(allocator, &.{ exe_dir, "../clib/lib1z.a" }) catch null
    else
        null;
    defer if (lib1z_path) |p| allocator.free(p);

    const resolved_lib = lib1z_path orelse {
        err_writer.writeAll("Error: cannot locate lib1z.a\n") catch {};
        err_writer.flush() catch {};
        return 1;
    };

    // Stage 2: Invoke C compiler.
    // Default to zig cc since lib1z.a is built with Zig's C backend and may
    // contain sanitizer references that system cc doesn't resolve.
    const cc_env = std.posix.getenv("CC");
    const cc_cmd = cc_env orelse "zig";

    var cc_argv: std.ArrayListUnmanaged([]const u8) = .{};
    defer cc_argv.deinit(allocator);
    cc_argv.append(allocator, cc_cmd) catch return 1;
    if (cc_env == null) cc_argv.append(allocator, "cc") catch return 1;
    cc_argv.append(allocator, "-o") catch return 1;
    cc_argv.append(allocator, output) catch return 1;
    cc_argv.append(allocator, tmp_path) catch return 1;
    cc_argv.append(allocator, resolved_lib) catch return 1;
    cc_argv.append(allocator, "-lffi") catch return 1;
    for (static_libs.items) |lib_name| {
        const flag = std.fmt.allocPrint(allocator, "-l{s}", .{lib_name}) catch return 1;
        cc_argv.append(allocator, flag) catch return 1;
    }

    var child = std.process.Child.init(cc_argv.items, allocator);
    child.stderr_behavior = .Pipe;
    child.spawn() catch |err| {
        err_writer.print("Error spawning C compiler '{s}': {s}\n", .{ cc_cmd, @errorName(err) }) catch {};
        err_writer.flush() catch {};
        return 1;
    };

    // Read stderr before wait() to avoid pipe buffer filling.
    var cc_stderr_output: []u8 = &.{};
    defer if (cc_stderr_output.len > 0) allocator.free(cc_stderr_output);
    if (child.stderr) |stderr_pipe| {
        var cc_err_list: std.ArrayListUnmanaged(u8) = .{};
        defer cc_err_list.deinit(allocator);
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = stderr_pipe.read(&read_buf) catch break;
            if (n == 0) break;
            cc_err_list.appendSlice(allocator, read_buf[0..n]) catch break;
        }
        if (cc_err_list.items.len > 0) {
            cc_stderr_output = cc_err_list.toOwnedSlice(allocator) catch &.{};
        }
    }

    const result = child.wait() catch |err| {
        err_writer.print("Error waiting for C compiler: {s}\n", .{@errorName(err)}) catch {};
        err_writer.flush() catch {};
        return 1;
    };

    if (result.Exited != 0) {
        if (cc_stderr_output.len > 0) {
            err_writer.writeAll(cc_stderr_output) catch {};
        }
        err_writer.print("Error: C compiler exited with status {d}\n", .{result.Exited}) catch {};
        err_writer.flush() catch {};
        return 1;
    }

    // Clean up temp file on success.
    if (save_temps) {
        err_writer.print("Saved: {s}\n", .{tmp_path}) catch {};
        err_writer.flush() catch {};
    } else {
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    return 0;
}

fn repl(ctx: *Context, verbosity: Verbosity, max_memory_bytes: usize) void {
    ctx.setPragma("redefinition-arity-mismatch", .{ .string = "warning" }) catch {};

    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(&stdout_buf);
    const writer = &stdout.interface;

    if (verbosity == .normal) {
        const mem_str = MemoryLimitAllocator.formatBytesStatic(max_memory_bytes);
        writer.print("1z interpreter v{s} ({s} max)\n", .{ version, mem_str }) catch return;
        writer.writeAll("Press ^D to quit\n\n") catch return;
        writer.flush() catch return;
    }

    if (std.posix.isatty(std.posix.STDIN_FILENO)) {
        replInteractive(ctx, verbosity, writer);
    } else {
        replPiped(ctx, verbosity, writer);
    }
}

fn replInteractive(ctx: *Context, verbosity: Verbosity, writer: anytype) void {
    var editor = LineEditor.init(ctx.allocator) catch {
        // Fall back to piped mode if terminal setup fails
        replPiped(ctx, verbosity, writer);
        return;
    };
    defer editor.deinit();

    const history_path = editor.resolveHistoryPath();
    defer if (history_path) |p| editor.allocator.free(p);

    if (history_path) |path| {
        editor.loadHistory(path);
    }

    editor.dictionary = &ctx.dictionary;

    ctx.pushLocalFrame() catch return;
    defer ctx.popLocalFrame();

    ctx.pushPragmaFrame() catch return;
    defer ctx.popPragmaFrame();

    const old_import_frame = ctx.import_frame_index;
    ctx.import_frame_index = ctx.local_frames.items.len - 1;
    defer ctx.import_frame_index = old_import_frame;

    autoloadReplModules(ctx);

    var processor: StatementProcessor = .{};
    defer processor.deinit();
    var repl_line: usize = 0;
    while (true) {
        const prompt: []const u8 = if (verbosity == .silent)
            ""
        else if (processor.isAccumulating())
            "+ "
        else
            "> ";

        const maybe_line = editor.readLine(prompt) catch {
            writer.writeAll("Error reading input\n") catch {};
            writer.flush() catch {};
            continue;
        };

        const line = maybe_line orelse {
            if (history_path) |path| {
                editor.saveHistory(path);
            }
            if (verbosity != .silent) {
                writer.writeAll("Goodbye!\n") catch {};
                writer.flush() catch {};
            }
            return;
        };

        repl_line += 1;
        processor.trackLine(repl_line);

        switch (processor.feedLine(ctx.quotationAllocator(), line, ctx)) {
            .needs_more_input => continue,
            .parse_error => |err| {
                if (err == error.DebuggerQuit) return;
                if (ctx.parse_diagnostics != null) {
                    printParseDiagnostics(ctx, writer, ctx.current_source, repl_line, processor.start_line);
                } else {
                    writer.print("Error: {any}\n", .{err}) catch {};
                }
                writer.flush() catch {};
                ctx.clearExecutionDetails();
                processor.reset();
            },
            .complete => |instrs| {
                // Add the full statement to history
                const stmt = processor.getStatement();
                if (stmt.len > 0) {
                    editor.addHistory(stmt);
                }

                var had_error = false;
                ctx.executeQuotation(.{ .instructions = instrs }) catch |err| {
                    if (isInterruptError(ctx)) {
                        writer.writeAll("Interrupted.\n") catch {};
                        ctx.thrown_error = null;
                        ctx.clearExecutionDetails();
                    } else {
                        printErrorDetails(ctx, writer, err);
                    }
                    had_error = true;
                };
                signal.reset();

                if (!had_error and verbosity != .silent) {
                    writer.writeAll("Stack: ") catch {};
                    ctx.stack.dump(writer) catch {};
                    writer.writeAll("\n") catch {};
                }

                writer.flush() catch {};
                processor.reset();
            },
        }
    }
}

fn autoloadReplModules(ctx: *Context) void {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(&stderr_buf);
    const writer = &stderr.interface;

    runReplStartupStatement(ctx, writer, "use \"runtime/introspect\" ;");
    writer.flush() catch {};
}

fn replPiped(ctx: *Context, verbosity: Verbosity, writer: anytype) void {
    const stdin_file: File = .stdin();
    var stdin_buf: [4096]u8 = undefined;
    var stdin = stdin_file.reader(&stdin_buf);
    const reader = &stdin.interface;

    ctx.pushLocalFrame() catch return;
    defer ctx.popLocalFrame();

    ctx.pushPragmaFrame() catch return;
    defer ctx.popPragmaFrame();

    const old_import_frame = ctx.import_frame_index;
    ctx.import_frame_index = ctx.local_frames.items.len - 1;
    defer ctx.import_frame_index = old_import_frame;

    autoloadReplModules(ctx);

    var processor: StatementProcessor = .{};
    defer processor.deinit();
    var repl_line: usize = 0;
    while (true) {
        if (verbosity != .silent) {
            if (processor.isAccumulating()) {
                writer.writeAll("+ ") catch return;
            } else {
                writer.writeAll("> ") catch return;
            }
            writer.flush() catch return;
        }

        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                if (verbosity != .silent) {
                    writer.writeAll("\nGoodbye!\n") catch {};
                    writer.flush() catch {};
                }
                return;
            },
            else => {
                writer.print("\nError reading input: {any}\n", .{err}) catch {};
                writer.flush() catch {};
                continue;
            },
        };

        repl_line += 1;
        processor.trackLine(repl_line);

        switch (processor.feedLine(ctx.quotationAllocator(), line, ctx)) {
            .needs_more_input => continue,
            .parse_error => |err| {
                if (err == error.DebuggerQuit) return;
                if (ctx.parse_diagnostics != null) {
                    printParseDiagnostics(ctx, writer, ctx.current_source, repl_line, processor.start_line);
                } else {
                    writer.print("Error: {any}\n", .{err}) catch {};
                }
                writer.flush() catch return;
                ctx.clearExecutionDetails();
                processor.reset();
            },
            .complete => |instrs| {
                var had_error = false;
                ctx.executeQuotation(.{ .instructions = instrs }) catch |err| {
                    if (isInterruptError(ctx)) {
                        writer.writeAll("Interrupted.\n") catch {};
                        ctx.thrown_error = null;
                        ctx.clearExecutionDetails();
                    } else {
                        printErrorDetails(ctx, writer, err);
                    }
                    had_error = true;
                };
                signal.reset();

                if (!had_error and verbosity != .silent) {
                    writer.writeAll("Stack: ") catch return;
                    ctx.stack.dump(writer) catch return;
                    writer.writeAll("\n") catch return;
                }

                writer.flush() catch return;
                processor.reset();
            },
        }
    }
}

fn batch(ctx: *Context, file_path: []const u8, show_stack: bool) u8 {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(&stderr_buf);
    const err_writer = &stderr.interface;

    // For --show-stack, prepare stdout writer
    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(&stdout_buf);
    const out_writer = &stdout.interface;

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        err_writer.print("Error opening file '{s}': {any}\n", .{ file_path, err }) catch {};
        err_writer.flush() catch {};
        return 1;
    };
    defer file.close();

    // Set source filename for error reporting
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    ctx.current_source = if (std.fs.cwd().realpath(".", &cwd_buf)) |cwd_path| blk: {
        if (std.mem.startsWith(u8, file_path, cwd_path) and file_path.len > cwd_path.len and file_path[cwd_path.len] == '/') {
            break :blk file_path[cwd_path.len + 1 ..];
        }
        break :blk file_path;
    } else |_| file_path;

    // Set current_source_dir for relative path resolution in load/use
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.cwd().realpath(file_path, &abs_buf)) |abs_path| {
        if (std.fs.path.dirname(abs_path)) |dir| {
            ctx.current_source_dir = ctx.quotationAllocator().dupe(u8, dir) catch null;
        }
    } else |_| {
        if (std.fs.path.dirname(file_path)) |dir| {
            ctx.current_source_dir = dir;
        }
    }

    var file_buf: [4096]u8 = undefined;
    var reader = file.reader(&file_buf);

    ctx.pushLocalFrame() catch return 1;
    defer ctx.popLocalFrame();

    ctx.pushPragmaFrame() catch return 1;
    defer ctx.popPragmaFrame();

    const old_import_frame = ctx.import_frame_index;
    ctx.import_frame_index = ctx.local_frames.items.len - 1;
    defer ctx.import_frame_index = old_import_frame;

    var processor: StatementProcessor = .{};
    defer processor.deinit();
    var file_line: usize = 0;
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                // Try to execute any remaining buffered content
                switch (processor.flush(ctx.quotationAllocator(), ctx)) {
                    .needs_more_input => {},
                    .parse_error => |e| {
                        if (e == error.DebuggerQuit) return 0;
                        if (ctx.parse_diagnostics != null) {
                            printParseDiagnostics(ctx, err_writer, ctx.current_source, file_line, processor.start_line);
                        } else {
                            err_writer.print("Error: {any}\n", .{e}) catch {};
                        }
                        err_writer.flush() catch {};
                        return 1;
                    },
                    .complete => |instrs| {
                        if (instrs.len > 0 and (!ctx.check_mode or Context.isDefinitionStatement(instrs))) {
                            ctx.executeQuotation(.{ .instructions = instrs }) catch |e| {
                                if (e == debugger_mod.DebuggerQuit.DebuggerQuit) return 0;
                                printErrorDetails(ctx, err_writer, e);
                                err_writer.flush() catch {};
                                return 1;
                            };
                            if (show_stack) {
                                out_writer.writeAll("Stack: ") catch {};
                                ctx.stack.dump(out_writer) catch {};
                                out_writer.writeAll("\n") catch {};
                                out_writer.flush() catch {};
                            }
                        }
                    },
                }
                break;
            },
            else => {
                err_writer.print("Error reading file: {any}\n", .{err}) catch {};
                err_writer.flush() catch {};
                return 1;
            },
        };

        file_line += 1;
        processor.trackLine(file_line);
        if (processor.start_line > 0) {
            ctx.parse_line_offset = processor.start_line - 1;
        }

        switch (processor.feedLine(ctx.quotationAllocator(), line, ctx)) {
            .needs_more_input => continue,
            .parse_error => |err| {
                if (err == error.DebuggerQuit) return 0;
                if (ctx.parse_diagnostics != null) {
                    printParseDiagnostics(ctx, err_writer, ctx.current_source, file_line, processor.start_line);
                } else {
                    err_writer.print("Error at line {d}: {any}\n", .{ file_line, err }) catch {};
                }
                err_writer.flush() catch {};
                ctx.clearExecutionDetails();
                return 1;
            },
            .complete => |instrs| {
                if (instrs.len > 0 and (!ctx.check_mode or Context.isDefinitionStatement(instrs))) {
                    ctx.executeQuotation(.{ .instructions = instrs }) catch |err| {
                        if (err == debugger_mod.DebuggerQuit.DebuggerQuit) return 0;
                        printErrorDetails(ctx, err_writer, err);
                        err_writer.flush() catch {};
                        return 1;
                    };
                    if (show_stack) {
                        out_writer.writeAll("Stack: ") catch {};
                        ctx.stack.dump(out_writer) catch {};
                        out_writer.writeAll("\n") catch {};
                        out_writer.flush() catch {};
                    }
                }
                processor.reset();
            },
        }
    }

    if (ctx.check_mode) {
        _ = call_graph.build(&ctx.dictionary, &ctx.dispatch, ctx.quotationAllocator()) catch |err| {
            err_writer.print("Error building call graph: {any}\n", .{err}) catch {};
            err_writer.flush() catch {};
            return 1;
        };

        const pragma_settings = effect_inference.readCheckPragmas(ctx);

        var engine = effect_inference.InferenceEngine.init(&ctx.dictionary, &ctx.dispatch, ctx.local_frames.items, ctx.quotationAllocator(), pragma_settings.severity_override, pragma_settings.suppressed, pragma_settings.suppress_undeclared, &ctx.builtin_type_values, ctx.getAnyTypeSentinel(), pragma_settings.type_check_mode, pragma_settings.arity_check_mode);
        defer engine.deinit();
        engine.analyzeAll(ctx.current_source) catch |err| {
            err_writer.print("Error during effect inference: {any}\n", .{err}) catch {};
            err_writer.flush() catch {};
            return 1;
        };

        for (engine.getDiagnostics()) |diag| {
            if (diag.source_file) |src| {
                err_writer.print("{s}:{d}: {s}: {s}: {s}\n", .{
                    src,
                    diag.source_line,
                    @tagName(diag.severity),
                    diag.word_name,
                    diag.message,
                }) catch {};
            } else {
                err_writer.print("{s}: {s}: {s}\n", .{
                    @tagName(diag.severity),
                    diag.word_name,
                    diag.message,
                }) catch {};
            }
        }
        err_writer.flush() catch {};

        if (engine.hasErrors()) return 1;
    }

    return 0;
}

// =============================================================================
// Tests - import other modules to run their tests
// =============================================================================

test {
    _ = @import("value.zig");
    _ = @import("stack.zig");
    _ = @import("context.zig");
    _ = @import("tokenizer.zig");
    _ = @import("dictionary.zig");
    _ = @import("primitives.zig");
    _ = @import("parser.zig");
    _ = @import("statement.zig");
    _ = @import("formatter.zig");
    _ = @import("benchmark.zig");
    _ = @import("profile.zig");
    _ = @import("memory_limit.zig");
    _ = @import("line_editor.zig");
    _ = @import("debugger/mod.zig");
    _ = @import("multiplexer.zig");
    _ = @import("trace.zig");
    _ = @import("call_graph.zig");
    _ = @import("effect_inference.zig");
    _ = @import("lsp/mod.zig");
    _ = @import("simd.zig");
    _ = @import("aot_freeze.zig");
}

test "writeVersion emits '1z <version>\\n'" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeVersion(fbs.writer());
    const expected = "1z " ++ version ++ "\n";
    try std.testing.expectEqualStrings(expected, fbs.getWritten());
}
