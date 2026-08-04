const std = @import("std");
const builtin = @import("builtin");
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
const container_backing = @import("container_backing.zig");
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
const container_limits = @import("container_limits.zig");
const trace_mod = @import("trace.zig");
const call_graph = @import("call_graph.zig");
const effect_inference = @import("effect_inference.zig");
const aot_freeze = @import("aot_freeze.zig");
const aot_type_inference = @import("aot_type_inference.zig");
const markers_mod = @import("primitives/markers.zig");
const aot_image = @import("aot_image.zig");
const aot_image_emit = @import("aot_image_emit.zig");
const ir_codegen = @import("ir_codegen.zig");
const bail_stats_mod = @import("bail_stats.zig");

const signal = @import("signal.zig");
const build_options = @import("build_options");
pub const version = build_options.version;
pub const git_commit = build_options.git_commit;

/// Debug builds use the safety-checked allocator for leak and use-after-free detection. Optimized
/// builds use libc malloc, which recycles freed regions in process instead of mapping and unmapping
/// pages from the OS per allocation.
const root_allocator_is_debug = builtin.mode == .Debug;

/// Compile-time-rendered Zig compiler version string. Format matches
/// `<major>.<minor>.<patch>`, with `-pre.<n>` appended only when the
/// running Zig is a pre-release build.
const zig_version_str: []const u8 = blk: {
    const v = builtin.zig_version;
    break :blk if (v.pre) |pre|
        std.fmt.comptimePrint("{d}.{d}.{d}-{s}", .{ v.major, v.minor, v.patch, pre })
    else
        std.fmt.comptimePrint("{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
};

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
        var error_obj = ErrorObject{
            .error_type = duped_name,
            .message = duped_name,
            .data = null,
            .stack_trace = stack_trace,
        };
        hooks.fireHooks(ctx, "on:unhandled-error", &.{.{ .error_value = &error_obj }});
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

/// Resolve the default memory cap when --max-memory was not given on the CLI.
/// ONEZ_MAX_MEMORY wins over cgroup detection; cgroup detection wins over the
/// 256 MiB hard default already in `max_memory_bytes`.
fn resolveMemoryDefault(global: *GlobalFlags, trace_enabled: bool) void {
    if (global.cli_set_max_memory) return;
    if (std.posix.getenv("ONEZ_MAX_MEMORY")) |env_val| {
        if (memory_limit.parseSize(env_val)) |bytes| {
            global.max_memory_bytes = bytes;
        }
        // env var present: honor the user's intent, skip cgroup detection
        return;
    }
    const det = container_limits.detectMemory(trace_enabled);
    if (det.source != .fallback) global.max_memory_bytes = det.cap;
}

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
    worker_count: usize = 0,
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

/// Parse a `--sampling-tick` duration into nanoseconds.
///
/// A bare integer is seconds. An `ms` suffix is milliseconds. Returns null on malformed input.
fn parseSamplingTick(value: []const u8) ?i128 {
    if (std.mem.endsWith(u8, value, "ms")) {
        const num = value[0 .. value.len - 2];
        const millis = std.fmt.parseInt(u64, num, 10) catch return null;
        return @as(i128, millis) * std.time.ns_per_ms;
    }
    const secs = std.fmt.parseInt(u64, value, 10) catch return null;
    return @as(i128, secs) * std.time.ns_per_s;
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
    if (std.mem.startsWith(u8, arg, "--profile-out=")) {
        const value = arg["--profile-out=".len..];
        if (value.len == 0) {
            err_writer.writeAll("Error: invalid value for --profile-out: path is empty\n") catch {};
            err_writer.flush() catch {};
            return error.InvalidFlagValue;
        }
        state.profile_config.out_path = value;
        state.profile_config.enabled = true;
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
        state.trace_config.trace_modules = trace_mod.ModuleTraceCategories.all();
        return .consumed;
    }
    if (std.mem.startsWith(u8, arg, "--trace-modules=")) {
        const value = arg["--trace-modules=".len..];
        state.trace_config.trace_modules = trace_mod.parseModuleTraceCategories(value) catch {
            err_writer.print(
                "Error: invalid value for --trace-modules: '{s}' (expected comma list of: lifecycle, source, define, import, deps)\n",
                .{value},
            ) catch {};
            err_writer.flush() catch {};
            return error.InvalidFlagValue;
        };
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
    if (std.mem.eql(u8, arg, "--trace-container-detect")) {
        state.trace_config.trace_container_detect = true;
        return .consumed;
    }
    if (std.mem.startsWith(u8, arg, "--dump-scope=")) {
        state.trace_config.dump_scope = arg["--dump-scope=".len..];
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--dump-jit-bytes")) {
        state.trace_config.dump_jit_bytes = true;
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--dump-jit-bin-dir")) {
        err_writer.print("Error: --dump-jit-bin-dir requires a value (e.g. --dump-jit-bin-dir=DIR)\n", .{}) catch {};
        err_writer.flush() catch {};
        return error.InvalidFlagValue;
    }
    if (std.mem.startsWith(u8, arg, "--dump-jit-bin-dir=")) {
        const value = arg["--dump-jit-bin-dir=".len..];
        if (value.len == 0) {
            err_writer.print("Error: --dump-jit-bin-dir requires a non-empty directory\n", .{}) catch {};
            err_writer.flush() catch {};
            return error.InvalidFlagValue;
        }
        state.trace_config.dump_jit_bin_dir = value;
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--dump-jit-word")) {
        err_writer.print("Error: --dump-jit-word requires a value (e.g. --dump-jit-word=my-word)\n", .{}) catch {};
        err_writer.flush() catch {};
        return error.InvalidFlagValue;
    }
    if (std.mem.startsWith(u8, arg, "--dump-jit-word=")) {
        const value = arg["--dump-jit-word=".len..];
        if (value.len == 0) {
            err_writer.print("Error: --dump-jit-word requires a non-empty pattern\n", .{}) catch {};
            err_writer.flush() catch {};
            return error.InvalidFlagValue;
        }
        state.trace_config.dump_jit_word_pattern = value;
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
    if (std.mem.eql(u8, arg, "--sample-tasks")) {
        state.trace_config.sample_tasks = true;
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--sample-memory")) {
        state.trace_config.sample_memory = true;
        return .consumed;
    }
    if (std.mem.eql(u8, arg, "--sampling-tick")) {
        err_writer.print("Error: --sampling-tick requires a value (e.g. --sampling-tick=1000ms)\n", .{}) catch {};
        err_writer.flush() catch {};
        return error.InvalidFlagValue;
    }
    if (std.mem.startsWith(u8, arg, "--sampling-tick=")) {
        const value = arg["--sampling-tick=".len..];
        state.trace_config.sampling_tick_ns = parseSamplingTick(value) orelse {
            err_writer.print("Error: invalid value for --sampling-tick: '{s}'\n", .{value}) catch {};
            err_writer.flush() catch {};
            return error.InvalidFlagValue;
        };
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
    if (std.mem.startsWith(u8, arg, "--threads=")) {
        const value = arg["--threads=".len..];
        if (std.mem.eql(u8, value, "auto")) {
            state.worker_count = 0; // 0 means auto-detect from CPU/cgroup count
            return .consumed;
        }
        const n = std.fmt.parseUnsigned(usize, value, 10) catch {
            err_writer.print("Error: invalid value for --threads: '{s}'\n", .{value}) catch {};
            err_writer.flush() catch {};
            return error.InvalidFlagValue;
        };
        if (n == 0) {
            err_writer.print("Error: --threads must be at least 1\n", .{}) catch {};
            err_writer.flush() catch {};
            return error.InvalidFlagValue;
        }
        state.worker_count = n;
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
        \\  test <file>            Run `test-` words discovered in a *_test.1z file
        \\  check <file>           Run static analysis without executing
        \\  repl                   Start the interactive REPL (default)
        \\  fmt [files...]         Format 1z source files
        \\  lint [files...]        Check code style and conventions
        \\  highlight [file]       Highlight 1z source code
        \\  build <file>           Compile a 1z file to a native executable
        \\  inspect <binary>       Report metadata embedded in an AOT binary
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
        \\Execution options (run, eval, repl, check):
        \\  --threads=N|auto        Worker threads, or 'auto' to detect (default: auto)
        \\  (see `1z <subcommand> --help` for more)
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
    \\  --threads=N|auto          Worker threads, or 'auto' to detect (default: auto)
    \\  --debug                   Start in the interactive debugger
    \\  --break=WORD              Set a breakpoint on WORD (implies --debug)
    \\  --allow-all-recursion     Suppress non-tail recursion warnings
    \\  --allow-interpreter-fallback  Suppress quotation fallback warnings in AOT builds
    \\  --compile=MODE            Set compile mode: off, eager, hybrid
    \\  --trace-words[=PAT]       Trace word execution (optional pattern filter)
    \\  --trace-resolve[=PAT]     Trace word resolution (optional pattern filter)
    \\  --trace-modules[=CATS]    Trace module loading (CATS: lifecycle,source,define,import,deps; bare=all)
    \\  --trace-jit               Trace JIT compilation
    \\  --trace-pic               Trace inline PIC hits
    \\  --trace-container-detect  Trace container CPU/memory detection fallbacks
    \\  --dump-scope=WORD         Dump scope after loading WORD
    \\  --dump-jit-bytes          Dump JIT native code bytes to stderr (xxd format)
    \\  --dump-jit-bin-dir=DIR    Write per-word JIT native code to DIR/ID-name.bin
    \\  --dump-jit-word=PAT       Restrict JIT dumps to comma-separated word names
    \\  --deadlock-detect[=SECS]  Enable deadlock detection (default 5s)
    \\  --test-timeout=SECS       Set test timeout in seconds
    \\  -b, --benchmark           Enable benchmarking
    \\  --benchmark=verbose       Benchmark with human-readable output
    \\  --benchmark=json          Benchmark with JSON output
    \\  --profile                 Collect per-word wall-time samples
    \\  --profile-top=N           Limit the profile table to N rows (default 20)
    \\  --profile-out=FILE        Write a gzipped pprof profile to FILE (implies --profile)
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
    w.writeAll("  --compile=MODE, --benchmark, --benchmark=verbose, --benchmark=json, --profile, --profile-top=N, --profile-out=FILE\n\n") catch {};
    w.writeAll("Execution options:\n") catch {};
    w.writeAll("  --threads=N|auto          Worker threads, or 'auto' to detect (default: auto)\n\n") catch {};
    w.writeAll("Global options:\n") catch {};
    w.writeAll(global_flags_help) catch {};
    w.writeAll("\n") catch {};
    w.flush() catch {};
}

fn printTestHelp() void {
    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(&stdout_buf);
    const w = &stdout.interface;
    w.writeAll("Usage: 1z test [options] <file>\n\n") catch {};
    w.writeAll("Run every `test-` prefixed word defined in <file>.\n\n") catch {};
    w.writeAll("The file is loaded as a module so its imports (e.g. `assert=` from\n") catch {};
    w.writeAll("the testing library) resolve correctly when each test word runs.\n\n") catch {};
    w.writeAll("Exit codes:\n") catch {};
    w.writeAll("  0   All assertions passed\n") catch {};
    w.writeAll("  1   One or more assertions failed\n") catch {};
    w.writeAll("  2   Parse or runtime error\n\n") catch {};
    w.writeAll("Global options:\n") catch {};
    w.writeAll(global_flags_help) catch {};
    w.writeAll("\n\nExecution options:\n") catch {};
    w.writeAll(execution_flags_help) catch {};
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

fn printInspectHelp() void {
    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(&stdout_buf);
    const w = &stdout.interface;
    w.writeAll("Usage: 1z inspect <binary>\n") catch {};
    w.writeAll("       1z inspect --reach FEATURE <source.1z>\n\n") catch {};
    w.writeAll("Without --reach: report metadata embedded in a 1z AOT binary,\n") catch {};
    w.writeAll("including target, build mode, artifact class, interpreter linkage\n") catch {};
    w.writeAll("and fallback policy, runtime image presence, dynamic-feature\n") catch {};
    w.writeAll("touchpoints, 1z version, and prelude content hash.\n\n") catch {};
    w.writeAll("With --reach FEATURE: freeze the source file with the interpreter\n") catch {};
    w.writeAll("artifact class (no bans) and report every compound word that\n") catch {};
    w.writeAll("transitively calls a native carrying the named dynamic-capability\n") catch {};
    w.writeAll("marker, with the full call chain to the native.\n\n") catch {};
    w.writeAll("FEATURE is one of: eval, load, compile, quotation-construction\n") catch {};
    w.writeAll("The 'dynamic-' prefix is also accepted (e.g. dynamic-eval).\n\n") catch {};
    w.writeAll("Artifact classes:\n") catch {};
    w.writeAll("  interpreter          binary links the full interpreter; dynamic\n") catch {};
    w.writeAll("                       runtime code features (eval-string, runtime\n") catch {};
    w.writeAll("                       load, compile!) are available.\n") catch {};
    w.writeAll("  runtime-image-aot    AOT binary with no interpreter but a\n") catch {};
    w.writeAll("                       runtime program image; may rehydrate the\n") catch {};
    w.writeAll("                       dictionary but cannot evaluate new source.\n") catch {};
    w.writeAll("  interpreter-free-aot AOT binary with neither the interpreter nor\n") catch {};
    w.writeAll("                       a runtime image; executes only the frozen\n") catch {};
    w.writeAll("                       compiled graph.\n\n") catch {};
    w.writeAll("Classification rule: interpreter-linked binaries are reported as\n") catch {};
    w.writeAll("`interpreter` even when a runtime image is also present; the class\n") catch {};
    w.writeAll("reflects the binary's maximum runtime capability.\n") catch {};
    w.flush() catch {};
}

fn printFmtHelp() void {
    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(&stdout_buf);
    const w = &stdout.interface;
    w.writeAll("Usage: 1z fmt [options] <file...>\n") catch {};
    w.writeAll("       1z fmt [--check] .\n\n") catch {};
    w.writeAll("Format 1z source files in place.\n\n") catch {};
    w.writeAll("Fmt options:\n") catch {};
    w.writeAll("  --check                   Report files needing formatting; exit 1 if any do\n") catch {};
    w.writeAll("  --stdout                  Write formatted output to stdout instead of in place\n\n") catch {};
    w.writeAll("Global options:\n") catch {};
    w.writeAll(global_flags_help) catch {};
    w.writeAll("\n") catch {};
    w.flush() catch {};
}

fn printBuildHelp() void {
    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(&stdout_buf);
    const w = &stdout.interface;
    w.writeAll("Usage: 1z build [options] <file.1z>\n\n") catch {};
    w.writeAll("Compile a 1z file to a native executable.\n\n") catch {};
    w.writeAll("Build options:\n") catch {};
    w.writeAll("  -o <output>                   Output path (default: source with .1z stripped)\n") catch {};
    w.writeAll("  --save-temps                  Keep intermediate C source and object files\n") catch {};
    w.writeAll("  --compilation-stats           Print compilation statistics\n") catch {};
    w.writeAll("  --compile-all-prelude         Compile every prelude word, not just reachable ones\n") catch {};
    w.writeAll("  --allow-interpreter-fallback  Suppress quotation fallback warnings\n") catch {};
    w.writeAll("  --interpreter-fallback=MODE   Interpreter fallback policy: true, false, auto (default: auto)\n") catch {};
    w.writeAll("  --lock-interpreter-setting    Lock the fallback policy into the binary\n") catch {};
    w.writeAll("  --link-static=LIB             Statically link library LIB (repeatable)\n") catch {};
    w.writeAll("  --link-object=PATH            Link an extra object or archive PATH (repeatable)\n") catch {};
    w.writeAll("  --linker-script=PATH          Linker script for bare-metal/freestanding targets\n") catch {};
    w.writeAll("  --dump-aot-image-classification  Print AOT image word classification\n") catch {};
    w.writeAll("  --dump-aot-image-c            Print the generated runtime-image C source\n") catch {};
    w.writeAll("  --emit-runtime-image          Embed a runtime program image in the binary\n") catch {};
    w.writeAll("  --target=TRIPLE               Cross-compilation target (e.g. riscv64-freestanding-none)\n") catch {};
    w.writeAll("  --trace-aot[=CATS]            Trace the AOT compiler (CATS: freeze, codegen, effect, instr; bare=freeze,codegen,effect)\n") catch {};
    w.writeAll("  --trace-aot-word=PAT          Filter --trace-aot to words matching PAT (comma-separated exact names)\n\n") catch {};
    w.writeAll("  --opt-level=N                 Optimize generated C: 0 1 2 3 s z (default: 2; freestanding: 0)\n") catch {};
    w.writeAll("Global options:\n") catch {};
    w.writeAll(global_flags_help) catch {};
    w.writeAll("\n") catch {};
    w.flush() catch {};
}

fn printVersionHelp() void {
    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(&stdout_buf);
    const w = &stdout.interface;
    w.writeAll("Usage: 1z version\n\n") catch {};
    w.writeAll("Print the 1z version string and exit. Takes no options.\n\n") catch {};
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
    profile_out_path: ?[]const u8,

    fn init(
        gpa: std.mem.Allocator,
        global: *GlobalFlags,
        exec: *ExecutionFlags,
        err_writer: anytype,
    ) !*ExecutionContext {
        resolveMemoryDefault(global, exec.trace_config.trace_container_detect);
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

        if (exec.compile_mode == .off and
            (exec.trace_config.dump_jit_bytes or exec.trace_config.dump_jit_bin_dir != null))
        {
            err_writer.print("Note: JIT dump flags require --compile=eager or --compile=hybrid; no dumps will be produced.\n", .{}) catch {};
            err_writer.flush() catch {};
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
            // Enable live-backing accounting before any prelude container is
            // created so the count does not undershoot.
            container_backing.setBenchEnabled(true);
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
            .profile_out_path = exec.profile_config.out_path,
        };
        errdefer ec.ctx.deinit();

        ec.ctx.trace = exec.trace_config;
        ec.ctx.deadlock_detect_ns = exec.deadlock_detect_ns;
        ec.ctx.worker_count = exec.worker_count;
        ec.ctx.mem_limit = mem_limit_ptr;

        if (exec.trace_config.sample_memory) mem_limit_ptr.setPeakTracking(true);

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
        // Snapshot while ctx.stack is still alive, so the live count reflects
        // backings still referenced at program end.
        self.bench_stats.live_container_backings = container_backing.liveBackingCount();
        self.bench_stats.peak_container_backings = container_backing.peakBackingCount();
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
        if (!self.profile_stats.hasSamples()) return;

        var buf: [8192]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        self.profile_stats.formatHuman(self.gpa, stream.writer(), self.profile_top) catch {};
        const data = stream.getWritten();
        var written: usize = 0;
        while (written < data.len) {
            written += std.posix.write(std.posix.STDOUT_FILENO, data[written..]) catch break;
        }

        if (self.profile_out_path) |path| self.writePprof(path);
    }

    /// Encode the samples as a gzipped pprof profile and write it to `path`.
    /// The human table already went to stdout; this file is additive.
    fn writePprof(self: *ExecutionContext, path: []const u8) void {
        var err_buf: [256]u8 = undefined;
        var err_stream = std.io.fixedBufferStream(&err_buf);

        const bytes = self.profile_stats.exportPprof(self.gpa) catch {
            const msg = "Error: failed to encode pprof profile\n";
            _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch {};
            return;
        };
        defer self.gpa.free(bytes);

        const file = std.fs.cwd().createFile(path, .{}) catch |err| {
            err_stream.writer().print("Error: cannot write pprof profile to '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
            _ = std.posix.write(std.posix.STDERR_FILENO, err_stream.getWritten()) catch {};
            return;
        };
        defer file.close();

        file.writeAll(bytes) catch |err| {
            err_stream.writer().print("Error: cannot write pprof profile to '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
            _ = std.posix.write(std.posix.STDERR_FILENO, err_stream.getWritten()) catch {};
        };
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
    var debug_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_allocator, const using_debug_gpa = alloc: {
        break :alloc switch (builtin.mode) {
            .Debug => .{ debug_gpa.allocator(), true },
            else => .{ std.heap.c_allocator, false },
        };
    };
    defer if (using_debug_gpa) {
        _ = debug_gpa.deinit();
    };

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
    if (std.mem.eql(u8, first, "test")) return handleTest(gpa_allocator, args[2..]);
    if (std.mem.eql(u8, first, "check")) return handleCheck(gpa_allocator, args[2..]);
    if (std.mem.eql(u8, first, "repl")) return handleRepl(gpa_allocator, args[2..]);
    if (std.mem.eql(u8, first, "fmt")) return handleFmt(gpa_allocator, args[2..]);
    if (std.mem.eql(u8, first, "lint")) return handleLint(gpa_allocator, args[2..]);
    if (std.mem.eql(u8, first, "highlight")) return handleHighlight(gpa_allocator, args[2..]);
    if (std.mem.eql(u8, first, "build")) return handleBuild(gpa_allocator, args[2..]);
    if (std.mem.eql(u8, first, "inspect")) return handleInspect(gpa_allocator, args[2..]);
    if (std.mem.eql(u8, first, "version")) {
        if (hasHelpFlag(args[2..])) {
            printVersionHelp();
            return 0;
        }
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
        defer container_backing.releaseValue(inspected);
        switch (inspected) {
            .string => |s| {
                out.writeAll(s.bytes) catch {};
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

fn handleTest(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(&stderr_buf);
    const err_writer = &stderr.interface;

    if (hasHelpFlag(args)) {
        printTestHelp();
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
            err_writer.writeAll("Error: `test` accepts a single file argument\n") catch {};
            err_writer.flush() catch {};
            return 1;
        }
        file_path = arg;
    }

    const path = file_path orelse {
        err_writer.writeAll("Usage: 1z test [options] <file>\n") catch {};
        err_writer.flush() catch {};
        return 1;
    };

    const ec = ExecutionContext.init(gpa, &global, &exec, err_writer) catch return 2;
    defer ec.deinit();

    if (exec.test_timeout_ns) |timeout_ns| {
        ec.armWatchdog(timeout_ns);
    }

    const result = runTest(&ec.ctx, path, err_writer);
    ec.fireExitHooks(result);
    ec.finalizeBenchmark(&exec);
    ec.finalizeProfile();
    return result;
}

/// Exit codes: 0 = all tests passed, 1 = one or more tests failed,
/// 2 = parse/runtime error in the runner or test file.
fn runTest(ctx: *Context, file_path: []const u8, err_writer: anytype) u8 {
    ctx.current_source = "<test>";

    ctx.pushLocalFrame() catch return 2;
    defer ctx.popLocalFrame();
    ctx.pushPragmaFrame() catch return 2;
    defer ctx.popPragmaFrame();

    const old_import_frame = ctx.import_frame_index;
    ctx.import_frame_index = ctx.local_frames.items.len - 1;
    defer ctx.import_frame_index = old_import_frame;

    const alloc = ctx.quotationAllocator();

    const path_owned = alloc.dupe(u8, file_path) catch {
        err_writer.writeAll("Error: out of memory\n") catch {};
        err_writer.flush() catch {};
        return 2;
    };
    ctx.stack.push(value_mod.stringValue(path_owned)) catch {
        err_writer.writeAll("Error: out of memory\n") catch {};
        err_writer.flush() catch {};
        return 2;
    };

    const code =
        \\use "test-runner" ;
        \\run-test-file
        \\
    ;

    var processor: StatementProcessor = .{};
    defer processor.deinit();

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

    const top = ctx.stack.pop() catch {
        err_writer.writeAll("Error: test runner left no result on the stack\n") catch {};
        err_writer.flush() catch {};
        return 2;
    };
    switch (top) {
        .fixnum => |n| return if (n == 0) 0 else 1,
        else => {
            err_writer.writeAll("Error: test runner produced a non-fixnum result\n") catch {};
            err_writer.flush() catch {};
            return 2;
        },
    }
}

fn testTimeoutWatchdog(timeout_ns: u64, ctx: *Context) void {
    std.Thread.sleep(timeout_ns);
    var tw = trace_mod.TraceWriter.init();
    const secs = @as(f64, @floatFromInt(timeout_ns)) /
        @as(f64, @floatFromInt(@as(u64, std.time.ns_per_s)));
    tw.print("TEST-TIMEOUT: {d:.1}s limit reached\n", .{secs});
    // Prefer the pool dump so tasks pinned to background workers appear
    // alongside primary tasks. Fall back to the active scheduler for
    // contexts that run outside a `task-scope` (REPL, eval).
    if (ctx.active_worker_pool.load(.acquire)) |pool| {
        pool.dumpAllTasks();
    } else if (ctx.active_scheduler.load(.acquire)) |sched| {
        sched.dumpAllTasks();
    }
    std.process.exit(124);
}

fn handleFmt(base_allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(&stderr_buf);
    const err_writer = &stderr.interface;

    if (hasHelpFlag(args)) {
        printFmtHelp();
        return 0;
    }

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

    resolveMemoryDefault(&global, false);

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

    resolveMemoryDefault(&global, false);

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

/// Derive the freeze-time artifact class from the build's CLI flags.
///
/// `--interpreter-fallback=true` definitely links the interpreter, so the
/// binary will have full runtime capability and freeze can apply the
/// permissive `interpreter` policy. For `.false` and `.auto` the artifact
/// might still end up interpreter-linked (codegen may emit fallback
/// calls), but freeze stays conservative and picks the strictest
/// applicable class: `runtime_image_aot` when the runtime image is
/// emitted, otherwise `interpreter_free_aot`. `lock_interpreter_setting`
/// is intentionally not consulted here: it only governs whether codegen
/// fallback is rejected, which is a downstream concern.
fn inferFreezeArtifactClass(
    interpreter_fallback: ir_codegen.InterpreterFallbackMode,
    emit_runtime_image: bool,
) ir_codegen.ArtifactClass {
    if (interpreter_fallback == .true) return .interpreter;
    if (emit_runtime_image) return .runtime_image_aot;
    return .interpreter_free_aot;
}

/// Report every parameter type the freeze-time inference proved, on the `freeze` trace axis.
///
/// A quotation has no name of its own, so it reports under its emitted C symbol.
fn traceInferredParamTypes(freeze_result: *const aot_freeze.FreezeResult, ctx: *const Context) void {
    if (!ctx.trace.trace_aot.freeze) return;

    var tw = trace_mod.TraceWriter.init();
    for (freeze_result.words) |w| {
        if (!trace_mod.matchesPattern(w.name, ctx.trace.trace_aot_word_pattern)) continue;
        for (w.inferred_param_types, 0..) |t, i| {
            if (t == .unknown) continue;
            trace_mod.traceAotFreezeParam(&tw, w.name, i, @tagName(t));
        }
    }
    for (freeze_result.quotations) |q| {
        if (!trace_mod.matchesPattern(q.c_name, ctx.trace.trace_aot_word_pattern)) continue;
        for (q.inferred_param_types, 0..) |t, i| {
            if (t == .unknown) continue;
            trace_mod.traceAotFreezeParam(&tw, q.c_name, i, @tagName(t));
        }
    }
}

fn unresolvedReasonLabel(reason: aot_freeze.UnresolvedReason) []const u8 {
    return switch (reason) {
        .not_in_dictionary => "absent from the freeze-time dictionary",
        .skipped_parse_time_only => "marked parse-time-only",
        .skipped_no_stack_effect => "discovered without a stack effect",
    };
}

fn printInterpreterLinkSummary(
    interpreter_fallback: ir_codegen.InterpreterFallbackMode,
    lock_interpreter_setting: bool,
    emit_runtime_image: bool,
    diagnostics: *const ir_codegen.CodegenDiagnostics,
    err_writer: anytype,
) void {
    const interpreter_free = switch (interpreter_fallback) {
        .true => false,
        .false => lock_interpreter_setting,
        .auto => !diagnostics.has_interpreter_callbacks,
    };
    // Build summary mirrors the artifact-class decision in
    // `emitProgramC`. `diagnostics.image_stats` is set for both the
    // full runtime image and the metadata-only image; only `--emit-runtime-image`
    // produces the full image, so the build flag is the disambiguator.
    const image_kind: ir_codegen.ImageKind = if (diagnostics.image_stats == null)
        .none
    else if (emit_runtime_image)
        .full_runtime
    else
        .metadata_only;
    const artifact_class = ir_codegen.classifyArtifact(!interpreter_free, image_kind);
    err_writer.print("artifact: {s}\n", .{artifact_class.label()}) catch {};
    const status: []const u8 = if (interpreter_free) "not linked" else "linked";
    const reason: []const u8 = switch (interpreter_fallback) {
        .true => "--interpreter-fallback=true",
        .false => if (lock_interpreter_setting)
            "--interpreter-fallback=false --lock-interpreter-setting"
        else
            "--interpreter-fallback=false without --lock-interpreter-setting",
        .auto => if (interpreter_free)
            "auto: all reachable code compiled"
        else
            "auto: compiled code calls interpreter",
    };
    err_writer.print("interpreter: {s} ({s})\n", .{ status, reason }) catch {};
    const jic_status: []const u8 = if (diagnostics.jit_interpreted_call_linked) "linked" else "not linked";
    err_writer.print("jitInterpretedCall: {s}\n", .{jic_status}) catch {};
    err_writer.flush() catch {};
}

fn printPicStats(
    diagnostics: *const ir_codegen.CodegenDiagnostics,
    err_writer: anytype,
) void {
    const stats = &diagnostics.pic_stats;
    if (stats.sites_attempted == 0 and stats.sites_emitted == 0 and stats.monomorphized == 0 and stats.inlined == 0) return;
    if (stats.sites_attempted != 0 or stats.sites_emitted != 0) {
        err_writer.print("Inline PIC sites: {d}/{d} generic call sites preseeded\n", .{
            stats.sites_emitted,
            stats.sites_attempted,
        }) catch {};
    }
    if (stats.monomorphized != 0) {
        err_writer.print("Monomorphized dispatch sites: {d}\n", .{stats.monomorphized}) catch {};
    }
    if (stats.inlined != 0) {
        err_writer.print("Inlined call sites: {d}\n", .{stats.inlined}) catch {};
    }
    err_writer.flush() catch {};
}

fn printAotFallbackReport(
    report: *const ir_codegen.AotFallbackReport,
    err_writer: anytype,
) void {
    if (report.total() == 0) return;
    err_writer.print("AOT interpreter fallbacks: {d} total\n", .{report.total()}) catch {};
    inline for (@typeInfo(ir_codegen.AotFallbackCategory).@"enum".fields) |field| {
        const cat: ir_codegen.AotFallbackCategory = @enumFromInt(field.value);
        const count = report.totals[field.value];
        if (count != 0) {
            err_writer.print("  {s}: {d}\n", .{ cat.label(), count }) catch {};
        }
    }
    const max_sites: usize = 16;
    const shown = @min(report.sites.len, max_sites);
    if (shown > 0) {
        err_writer.writeAll("  sites:\n") catch {};
        for (report.sites[0..shown]) |site| {
            err_writer.print("    {s}: {s} -> {s} (line {d})\n", .{
                site.category.label(),
                site.caller_word,
                site.callee_word,
                site.line,
            }) catch {};
        }
        if (report.sites.len > shown) {
            err_writer.print("    ... {d} more\n", .{report.sites.len - shown}) catch {};
        }
    }
    printAotFallbackStaticCheck(&report.static_check, err_writer);
    err_writer.flush() catch {};
}

/// One-line per-category roll-up plus static-check parity. Emitted on
/// every successful AOT build when the report has any sites; the
/// verbose `printAotFallbackReport` is reserved for `--compilation-stats`
/// and the locked-fallback error path. This is the "AOT build report
/// line summarizing remaining fallbacks per category" called out by
/// 255.2.
fn printAotFallbackSummary(
    report: *const ir_codegen.AotFallbackReport,
    err_writer: anytype,
) void {
    if (report.total() == 0) {
        // Skip emitting anything for builds that never reached the
        // interpreter. The static-check parity is also implicitly zero
        // and would only add noise to clean builds. A mismatch will
        // still surface through `warnAotFallbackMismatch`.
        return;
    }
    err_writer.print("AOT interpreter fallbacks: {d} total (", .{report.total()}) catch {};
    var emitted: u32 = 0;
    inline for (@typeInfo(ir_codegen.AotFallbackCategory).@"enum".fields) |field| {
        const cat: ir_codegen.AotFallbackCategory = @enumFromInt(field.value);
        const count = report.totals[field.value];
        if (count != 0) {
            if (emitted > 0) err_writer.writeAll(" ") catch {};
            err_writer.print("{s}={d}", .{ cat.label(), count }) catch {};
            emitted += 1;
        }
    }
    err_writer.writeAll(")\n") catch {};
    printAotFallbackStaticCheck(&report.static_check, err_writer);
    err_writer.flush() catch {};
}

fn printAotFallbackStaticCheck(
    check: *const ir_codegen.AotFallbackStaticCheck,
    err_writer: anytype,
) void {
    if (!check.populated) return;
    err_writer.print(
        "  static-check: jitInterpretedCall={d}/{d} jitNativeWordCall={d}/{d} jitCallQuotation={d}/{d} ({s})\n",
        .{
            check.observed_jit_interpreted_calls,
            check.expected_jit_interpreted_calls,
            check.observed_jit_native_word_calls,
            check.expected_jit_native_word_calls,
            check.observed_jit_call_quotation,
            check.expected_jit_call_quotation,
            if (check.matches()) "matches build-time inventory" else "MISMATCH",
        },
    ) catch {};
}

/// Emit a warning line when the static cross-check disagrees with the
/// build-time inventory. The build still succeeds: the goal at this
/// stage is observability so codegen drift surfaces in normal builds
/// without breaking unrelated work.
fn warnAotFallbackMismatch(
    check: *const ir_codegen.AotFallbackStaticCheck,
    err_writer: anytype,
) void {
    if (!check.populated or check.matches()) return;
    err_writer.print(
        "Warning: AOT fallback inventory mismatch: " ++
            "jitInterpretedCall observed={d} expected={d}, " ++
            "jitNativeWordCall observed={d} expected={d}, " ++
            "jitCallQuotation observed={d} expected={d}; " ++
            "a codegen path is emitting an interpreter callback without classifying it.\n",
        .{
            check.observed_jit_interpreted_calls,
            check.expected_jit_interpreted_calls,
            check.observed_jit_native_word_calls,
            check.expected_jit_native_word_calls,
            check.observed_jit_call_quotation,
            check.expected_jit_call_quotation,
        },
    ) catch {};
}

/// Render the strict-AOT compound-fallback build error. Lists every
/// `compound_uncompiled` site with its caller, callee, line, and the
/// callee's `NotCompilableReason` (when known) so the build report names
/// exactly which compound words still need to compile before strict AOT
/// can succeed. Native and quotation fallbacks are still surfaced by the
/// summary line that the tail of the error handler emits.
fn printCompoundFallbackRequiredError(
    report: *const ir_codegen.AotFallbackReport,
    err_writer: anytype,
) void {
    const total = report.totals[@intFromEnum(ir_codegen.AotFallbackCategory.compound_uncompiled)];
    err_writer.print(
        "Error: --interpreter-fallback=false rejects compound-fallback dispatch; " ++
            "{d} callsite{s} still route{s} through the interpreter\n",
        .{
            total,
            if (total == 1) @as([]const u8, "") else "s",
            if (total == 1) @as([]const u8, "s") else "",
        },
    ) catch {};
    for (report.sites) |site| {
        if (site.category != .compound_uncompiled) continue;
        err_writer.print("  '{s}' -> '{s}' (line {d})\n", .{
            site.caller_word,
            site.callee_word,
            site.line,
        }) catch {};
        if (site.callee_reason) |reason| {
            err_writer.print("      callee uncompiled: {s}: {s}\n", .{
                reason.code(),
                reason.message(),
            }) catch {};
            if (reason.hint()) |h| {
                err_writer.print("      hint: {s}\n", .{h}) catch {};
            }
        } else if (site.callee_is_native) {
            err_writer.writeAll(
                "      callee is a native primitive without compiled AOT dispatch\n" ++
                    "      hint: blocked until the AOT resolver provides a compiled native entry for this word\n",
            ) catch {};
        } else {
            err_writer.writeAll("      callee uncompiled: NC.?: reason not categorized\n") catch {};
        }
    }
}

/// Render the `JitInterpretedCallLeaked` build error. The classifier
/// said no `compound_uncompiled` site was emitted, so the binary should
/// have zero `jitInterpretedCall(` references; the assembled C disagrees.
/// The static cross-check counts give the user enough to spot the
/// mismatch, and the message names the most likely cause so the codegen
/// path can be fixed.
fn printJitInterpretedCallLeakedError(
    report: *const ir_codegen.AotFallbackReport,
    err_writer: anytype,
) void {
    const observed = report.static_check.observed_jit_interpreted_calls;
    err_writer.print(
        "Error: generated AOT C contains {d} jitInterpretedCall reference{s} " ++
            "but no compound-fallback sites were recorded; a codegen path emitted " ++
            "a call without calling noteAotFallbackEmission.\n",
        .{ observed, if (observed == 1) @as([]const u8, "") else "s" },
    ) catch {};
}

/// Render the `RuntimeImageRequired` build error: a metadata-only image would drop the interpreter-
/// runnable bodies of the named words, so the build is rejected rather than producing a silently
/// wrong binary.
fn printRuntimeImageRequiredError(
    violations: []const ir_codegen.InterpretedReachViolation,
    err_writer: anytype,
) void {
    const n = violations.len;
    err_writer.print(
        "Error: interpreted quotations reach {d} non-prelude word{s} the compiler did not compile\n",
        .{ n, if (n == 1) @as([]const u8, "") else "s" },
    ) catch {};
    for (violations) |v| {
        if (v.line == 0) {
            err_writer.print(
                "  '{s}' reached from a quotation in '{s}'\n",
                .{ v.callee_name, v.caller_word },
            ) catch {};
        } else {
            err_writer.print(
                "  '{s}' reached from a quotation in '{s}' (line {d})\n",
                .{ v.callee_name, v.caller_word, v.line },
            ) catch {};
        }
    }
    err_writer.writeAll(
        "      hint: the build embeds a metadata-only image whose word bodies are empty; " ++
            "rebuild with --emit-runtime-image\n",
    ) catch {};
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

    resolveMemoryDefault(&global, false);

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

    if (hasHelpFlag(args)) {
        printBuildHelp();
        return 0;
    }

    // Parse build-specific args.
    var global = GlobalFlags{};
    defer global.deinit(base_allocator);

    var source_file: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var allow_interpreter_fallback = false;
    var trace_aot_cats: trace_mod.AotTraceCategories = .{};
    var trace_aot_word_pattern: ?[]const u8 = null;
    var compilation_stats = false;
    var compile_all_prelude = false;
    var save_temps = false;
    var dump_image_classification = false;
    var dump_image_c = false;
    var emit_runtime_image_flag = false;
    var interpreter_fallback: ir_codegen.InterpreterFallbackMode = .auto;
    var lock_interpreter_setting = false;
    var opt_token: []const u8 = "-O2";
    var opt_token_explicit = false;
    var target_triple_override: ?[]const u8 = null;
    var target_os_override: ?std.Target.Os.Tag = null;
    var target_arch_override: ?std.Target.Cpu.Arch = null;
    var target_is_freestanding = false;
    var linker_script: ?[]const u8 = null;
    var static_libs: std.ArrayListUnmanaged([]const u8) = .{};
    defer static_libs.deinit(base_allocator);
    var link_objects: std.ArrayListUnmanaged([]const u8) = .{};
    defer link_objects.deinit(base_allocator);

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
        if (std.mem.eql(u8, arg, "--trace-aot")) {
            trace_aot_cats = trace_mod.AotTraceCategories.perWordAxes();
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--trace-aot=")) {
            const value = arg["--trace-aot=".len..];
            trace_aot_cats = trace_mod.parseAotTraceCategories(value) catch {
                err_writer.print(
                    "Error: invalid value for --trace-aot: '{s}' (expected comma list of: freeze, codegen, effect, instr; bare=freeze,codegen,effect)\n",
                    .{value},
                ) catch {};
                err_writer.flush() catch {};
                return 1;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--trace-aot-word")) {
            err_writer.print("Error: --trace-aot-word requires a value (e.g. --trace-aot-word=my-word)\n", .{}) catch {};
            err_writer.flush() catch {};
            return 1;
        }
        if (std.mem.startsWith(u8, arg, "--trace-aot-word=")) {
            trace_aot_word_pattern = arg["--trace-aot-word=".len..];
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
        if (std.mem.eql(u8, arg, "--dump-aot-image-classification")) {
            dump_image_classification = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dump-aot-image-c")) {
            dump_image_c = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--emit-runtime-image")) {
            emit_runtime_image_flag = true;
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
        if (std.mem.startsWith(u8, arg, "--link-object=")) {
            link_objects.append(base_allocator, arg["--link-object=".len..]) catch {
                err_writer.writeAll("Error: out of memory\n") catch {};
                err_writer.flush() catch {};
                return 1;
            };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--linker-script=")) {
            linker_script = arg["--linker-script=".len..];
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
        if (std.mem.startsWith(u8, arg, "--opt-level=")) {
            const value = arg["--opt-level=".len..];
            if (std.mem.eql(u8, value, "0")) {
                opt_token = "-O0";
            } else if (std.mem.eql(u8, value, "1")) {
                opt_token = "-O1";
            } else if (std.mem.eql(u8, value, "2")) {
                opt_token = "-O2";
            } else if (std.mem.eql(u8, value, "3")) {
                opt_token = "-O3";
            } else if (std.mem.eql(u8, value, "s")) {
                opt_token = "-Os";
            } else if (std.mem.eql(u8, value, "z")) {
                opt_token = "-Oz";
            } else {
                err_writer.print("Error: --opt-level must be one of '0', '1', '2', '3', 's', or 'z', got '{s}'\n", .{value}) catch {};
                err_writer.flush() catch {};
                return 1;
            }
            opt_token_explicit = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--target=")) {
            const value = arg["--target=".len..];
            const query = std.Target.Query.parse(.{ .arch_os_abi = value }) catch |err| {
                err_writer.print(
                    "Error: --target='{s}' is not a valid target triple: {s}\n",
                    .{ value, @errorName(err) },
                ) catch {};
                err_writer.flush() catch {};
                return 1;
            };
            target_triple_override = value;
            target_os_override = query.os_tag;
            target_arch_override = query.cpu_arch;
            if (query.os_tag) |tag| {
                target_is_freestanding = (tag == .freestanding);
            }
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

    resolveMemoryDefault(&global, false);

    // Wrap the allocator in a memory limit for the rest of the build.
    var mem_limit = MemoryLimitAllocator.init(base_allocator, global.max_memory_bytes);
    const allocator = mem_limit.allocator();

    const source = source_file orelse {
        err_writer.writeAll("Usage: 1z build <file.1z> [-o <output>] [--save-temps] [--compilation-stats] [--compile-all-prelude] [--interpreter-fallback=true|false|auto] [--lock-interpreter-setting] [--dump-aot-image-classification] [--dump-aot-image-c] [--emit-runtime-image]\n") catch {};
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

    // Trace axes for `--trace-aot`. Read by the freeze BFS and, via `interp_ctx`, by the codegen
    // passes in `emitProgramC`. The `--trace-aot-word` filter scopes whichever axes are enabled.
    ctx.trace.trace_aot = trace_aot_cats;
    ctx.trace.trace_aot_word_pattern = trace_aot_word_pattern;

    // Resolve the build target for the parse-time `target-os` / `target-arch`
    // accessors before the module graph is frozen. A `--target` cross build
    // overrides the host default so the accessors read the build target.
    if (target_os_override) |os| ctx.target_os = os;
    if (target_arch_override) |arch| ctx.target_arch = arch;

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
        .artifact_class = inferFreezeArtifactClass(interpreter_fallback, emit_runtime_image_flag),
        .strict_interpreter_free = interpreter_fallback == .false,
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
                if (std.mem.eql(u8, feature_use.feature_name, "compile!")) {
                    err_writer.print(
                        "Error: 'compile!' in '{s}' is not available in AOT builds; runtime code compilation is incompatible with every AOT artifact class. Run under the interpreter if your program needs 'compile!'.\n",
                        .{feature_use.caller_name},
                    ) catch {};
                } else if (std.mem.eql(u8, feature_use.feature_name, ">quotation")) {
                    err_writer.print(
                        "Error: '>quotation' in '{s}' is not available in interpreter-free AOT; runtime-constructed quotations require dictionary lookup machinery that interpreter-free binaries omit. If the word name is known at compile time, use a literal quotation '[ word-name ]' instead. Otherwise build with --emit-runtime-image to produce a runtime-image AOT binary, or run under the interpreter.\n",
                        .{feature_use.caller_name},
                    ) catch {};
                } else {
                    err_writer.print(
                        "Error: dynamic feature '{s}' in '{s}' is not available in interpreter-free AOT; this feature requires runtime code-loading machinery that interpreter-free binaries omit. Build with --emit-runtime-image to produce a runtime-image AOT binary, or run under the interpreter, if you need '{s}'.\n",
                        .{ feature_use.feature_name, feature_use.caller_name, feature_use.feature_name },
                    ) catch {};
                }
                if (freeze_diagnostics.unresolved_callee_hint) |hint| {
                    err_writer.print(
                        "  hint: callee '{s}' was {s} at freeze time, so the call site has no concrete runtime word id; the marker fired because the parse-time definition was visible, but no runtime word backs this name.\n",
                        .{ hint.callee_name, unresolvedReasonLabel(hint.reason) },
                    ) catch {};
                }
            } else {
                err_writer.writeAll("Error: AOT build rejected an unidentified dynamic feature\n") catch {};
            }
        } else if (err == error.DisallowedNativeInterpreterDependency) {
            if (freeze_diagnostics.fatal_native_interpreter_dependency) |feature_use| {
                err_writer.print(
                    "Error: native primitive '{s}' reachable from '{s}' carries the 'interpreter-dependent' marker; its runtime path uses interpreter machinery (dictionary lookup, instruction-array execution, or runtime parsing) that interpreter-free AOT does not provide. Build with --emit-runtime-image to produce a runtime-image AOT binary, or run under the interpreter.\n",
                    .{ feature_use.feature_name, feature_use.caller_name },
                ) catch {};
            } else {
                err_writer.writeAll("Error: AOT build rejected an unidentified interpreter-dependent native\n") catch {};
            }
        } else if (err == error.ExecutionFailed and ctx.parse_diagnostics != null) {
            // A parse-time word threw while the entry file was being executed during freeze. The
            // rich diagnostic it computed lives in `parse_diagnostics`, so we'll need tto surface
            // it separately instead of the generic `ExecutionFailed` errorName.
            const diag = ctx.parse_diagnostics.?;
            if (diag.error_type) |error_type| {
                var kebab_buf: [128]u8 = undefined;
                const kebab_name = pascalToKebabRuntime(error_type, &kebab_buf);
                if (diag.source_file) |sf| {
                    err_writer.print("{s}: error '{s}'", .{ sf, kebab_name }) catch {};
                } else {
                    err_writer.print("error '{s}'", .{kebab_name}) catch {};
                }
                if (diag.message) |msg| {
                    err_writer.print(" {s}", .{msg}) catch {};
                }
                err_writer.writeAll("\n") catch {};
            } else {
                err_writer.print("Error freezing module graph: {s}\n", .{@errorName(err)}) catch {};
            }
            ctx.parse_diagnostics = null;
        } else {
            err_writer.print("Error freezing module graph: {s}\n", .{@errorName(err)}) catch {};
        }
        err_writer.flush() catch {};
        return 1;
    };
    defer freeze_result.deinit(allocator);
    // Freeze leaves the entry file's pragma frame pushed; balance it after emission.
    defer ctx.popPragmaFrame();

    // The freeze-side entry-import snapshot in the emitter's input shape.
    var entry_import_inputs: std.ArrayListUnmanaged(aot_image_emit.EntryImportInput) = .{};
    defer entry_import_inputs.deinit(allocator);
    for (freeze_result.entry_imports) |ei| {
        entry_import_inputs.append(allocator, .{
            .name = ei.name,
            .source_module_name = ei.source_module_name,
        }) catch {
            err_writer.writeAll("Error: out of memory while collecting entry imports\n") catch {};
            err_writer.flush() catch {};
            return 1;
        };
    }

    if (dump_image_classification) {
        var manifest = aot_image.buildImageManifest(ctx, allocator) catch |err| {
            err_writer.print("Error building image manifest: {s}\n", .{@errorName(err)}) catch {};
            err_writer.flush() catch {};
            return 1;
        };
        defer manifest.deinit(allocator);

        var dump_buf: std.ArrayListUnmanaged(u8) = .{};
        defer dump_buf.deinit(allocator);
        aot_image.writeManifestDump(&dump_buf, allocator, manifest) catch {
            err_writer.writeAll("Error: out of memory rendering image manifest\n") catch {};
            err_writer.flush() catch {};
            return 1;
        };
        err_writer.writeAll(dump_buf.items) catch {};
        err_writer.flush() catch {};

        // Touch the output path so build pipelines that declare it as an
        // output (test frameworks, make rules) see a file. The dump flag is
        // a diagnostic mode -- no real binary is produced.
        if (std.fs.cwd().createFile(output, .{ .truncate = true })) |f| f.close() else |_| {}

        return 0;
    }

    if (dump_image_c) {
        var manifest = aot_image.buildImageManifest(ctx, allocator) catch |err| {
            err_writer.print("Error building image manifest: {s}\n", .{@errorName(err)}) catch {};
            err_writer.flush() catch {};
            return 1;
        };
        defer manifest.deinit(allocator);

        var image_word_lookup: std.StringHashMapUnmanaged(u32) = .{};
        defer image_word_lookup.deinit(allocator);
        for (freeze_result.words) |w| {
            image_word_lookup.put(allocator, w.identityOf(), w.word_id) catch {
                err_writer.writeAll("Error: out of memory while building word-id lookup\n") catch {};
                err_writer.flush() catch {};
                return 1;
            };
        }

        var dump_buf: std.ArrayListUnmanaged(u8) = .{};
        defer dump_buf.deinit(allocator);
        _ = aot_image_emit.emitImageC(&dump_buf, allocator, ctx, manifest, &image_word_lookup, .{}, entry_import_inputs.items) catch {
            err_writer.writeAll("Error: out of memory rendering image C\n") catch {};
            err_writer.flush() catch {};
            return 1;
        };
        err_writer.writeAll(dump_buf.items) catch {};
        err_writer.flush() catch {};

        if (std.fs.cwd().createFile(output, .{ .truncate = true })) |f| f.close() else |_| {}

        return 0;
    }

    var codegen_diagnostics: ir_codegen.CodegenDiagnostics = .{};
    defer if (codegen_diagnostics.prelude_stats.uncompiled.len > 0)
        allocator.free(codegen_diagnostics.prelude_stats.uncompiled);
    defer if (codegen_diagnostics.aot_fallback_report.sites.len > 0)
        allocator.free(codegen_diagnostics.aot_fallback_report.sites);

    // Hash the embedded prelude source unconditionally: the build path's
    // `--prelude=` handling above passes the path string directly to
    // loadPrelude, which expects content, so external preludes are not
    // currently honored in build mode.
    var prelude_hash_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(context.prelude_source, &prelude_hash_bytes, .{});
    const prelude_hash_hex_buf = std.fmt.bytesToHex(prelude_hash_bytes, .lower);

    const target_triple = std.fmt.allocPrint(
        allocator,
        "{s}-{s}",
        .{ @tagName(builtin.target.cpu.arch), @tagName(builtin.target.os.tag) },
    ) catch {
        err_writer.writeAll("Error: out of memory\n") catch {};
        err_writer.flush() catch {};
        return 1;
    };
    defer allocator.free(target_triple);

    const cc_probe = probeCCompiler(allocator);
    defer cc_probe.deinit(allocator);

    const touched_features = computeTouchedDynamicFeatures(&freeze_result, ctx, allocator) catch null;
    defer if (touched_features) |tf| allocator.free(tf);

    // Call-site parameter type inference needs a closed world: every call site must be visible at
    // freeze time. Only the interpreter-free artifact class gives that, since the other classes let
    // `eval-string` or a runtime `load` introduce one later. An allocation failure here costs the
    // narrowing, not the build.
    if (inferFreezeArtifactClass(interpreter_fallback, emit_runtime_image_flag) == .interpreter_free_aot) {
        // Declared-output trust needs every call site compiled, and only the lock guarantees
        // that: an unlocked strict build still runs residual quotation fallbacks interpreted. It
        // also needs the call-site tag checks, which a relaxed type-check pragma disables.
        const locked_strict = interpreter_fallback == .false and lock_interpreter_setting;
        const trust_annotations = locked_strict and !ir_codegen.typeCheckRelaxed(ctx);
        aot_type_inference.inferParamTypes(&freeze_result, .{
            .arithmetic_result_types = locked_strict,
            .fixnum_type = if (trust_annotations) ctx.lookupBuiltinTypeValue("fixnum") else null,
            .float_type = if (trust_annotations) ctx.lookupBuiltinTypeValue("float") else null,
        }, allocator) catch {};
        traceInferredParamTypes(&freeze_result, ctx);
    }

    const aot_metadata: ir_codegen.AotMetadata = .{
        .interpreter_fallback_mode = interpreter_fallback,
        .interpreter_setting_locked = lock_interpreter_setting,
        .runtime_image_present = false,
        .target_triple = target_triple_override orelse target_triple,
        .build_mode = @tagName(builtin.mode),
        .onez_version = version,
        .prelude_hash_hex = &prelude_hash_hex_buf,
        .onez_git_commit = git_commit,
        .zig_version = zig_version_str,
        .c_compiler_id = cc_probe.id,
        .c_compiler_version = cc_probe.banner,
        .dynamic_features = touched_features,
        .freestanding = target_is_freestanding,
    };

    const c_source = ir_codegen.emitProgramC(
        freeze_result.words,
        freeze_result.quotations,
        freeze_result.entry_word_id,
        freeze_result.max_word_id,
        static_libs.items,
        interpreter_fallback,
        lock_interpreter_setting,
        aot_metadata,
        &codegen_diagnostics,
        ctx,
        emit_runtime_image_flag,
        freeze_result.interpreted_reach,
        entry_import_inputs.items,
        freeze_result.callee_scopes,
        allocator,
    ) catch |err| {
        printQuotationFallbackWarnings(&codegen_diagnostics, allow_interpreter_fallback, err_writer, allocator);
        const printed_full_report =
            err == error.InterpreterRequiredButLocked or compilation_stats;
        if (compilation_stats) {
            printPreludeStats(&codegen_diagnostics.prelude_stats, err_writer);
            printQuotationStats(freeze_result.quotations, err_writer);
            printPicStats(&codegen_diagnostics, err_writer);
            printAotFallbackReport(&codegen_diagnostics.aot_fallback_report, err_writer);
        }
        if (err == error.UncompiledWords) {
            const items = codegen_diagnostics.uncompiled_words;
            err_writer.print(
                "Error: {d} word{s} could not be compiled to C\n",
                .{ items.len, if (items.len == 1) @as([]const u8, "") else "s" },
            ) catch {};
            for (items) |entry| {
                if (entry.nested_definition) |helper| {
                    err_writer.print(
                        "  word '{s}': {s}: defines nested helper '{s}', which AOT compilation cannot discover\n",
                        .{ entry.name, entry.reason.code(), helper },
                    ) catch {};
                    err_writer.print(
                        "      hint: move '{s}' into a private{{ }} block at module scope\n",
                        .{helper},
                    ) catch {};
                    continue;
                }
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
                if (q.method_body_reason) |reason| {
                    const noun: []const u8 = if (q.reification) "quotation body" else "method body";
                    err_writer.print(
                        "Error: {s} '{s}' could not be compiled to native code\n",
                        .{ noun, q.c_name },
                    ) catch {};
                    const h: []const u8 = switch (reason) {
                        .needs_runtime_image => if (q.reification)
                            "rebuild with --emit-runtime-image to run this quotation body under the interpreter"
                        else
                            "rebuild with --emit-runtime-image to run this method body under the interpreter",
                        .interpreter_locked => if (q.reification)
                            "the interpreter is locked off; drop --lock-interpreter-setting or --interpreter-fallback=false so this quotation body can run"
                        else
                            "the interpreter is locked off; drop --lock-interpreter-setting or --interpreter-fallback=false so this method body can run",
                        .non_serializable => if (q.reification)
                            "the quotation body embeds a value that cannot be serialized into the runtime image"
                        else
                            "the method body embeds a value that cannot be serialized into the runtime image",
                    };
                    err_writer.print("      hint: {s}\n", .{h}) catch {};
                } else {
                    err_writer.print(
                        "Error: quotation body '{s}' could not be compiled\n",
                        .{q.c_name},
                    ) catch {};
                }
            }
            allocator.free(codegen_diagnostics.uncompiled_quotations);
        } else if (err == error.InterpreterRequiredButLocked) {
            err_writer.writeAll(
                "Error: --interpreter-fallback=false --lock-interpreter-setting was set, " ++
                    "but at least one compiled word emitted an interpreter fallback call.\n" ++
                    "      hint: drop --lock-interpreter-setting, switch to --interpreter-fallback=true, " ++
                    "or rewrite the offending words so they compile without fallback.\n",
            ) catch {};
            if (!compilation_stats) {
                printAotFallbackReport(&codegen_diagnostics.aot_fallback_report, err_writer);
            }
        } else if (err == error.CompoundFallbackRequired) {
            printCompoundFallbackRequiredError(
                &codegen_diagnostics.aot_fallback_report,
                err_writer,
            );
        } else if (err == error.JitInterpretedCallLeaked) {
            printJitInterpretedCallLeakedError(
                &codegen_diagnostics.aot_fallback_report,
                err_writer,
            );
        } else if (err == error.RuntimeImageRequired) {
            printRuntimeImageRequiredError(freeze_result.interpreted_reach, err_writer);
        } else {
            err_writer.print("Error generating C source: {s}\n", .{@errorName(err)}) catch {};
        }
        if (!printed_full_report) {
            printAotFallbackSummary(&codegen_diagnostics.aot_fallback_report, err_writer);
        }
        warnAotFallbackMismatch(&codegen_diagnostics.aot_fallback_report.static_check, err_writer);
        err_writer.flush() catch {};
        return 1;
    };
    defer allocator.free(c_source);

    if (compilation_stats) {
        printPreludeStats(&codegen_diagnostics.prelude_stats, err_writer);
        printQuotationStats(freeze_result.quotations, err_writer);
        printPicStats(&codegen_diagnostics, err_writer);
        printAotFallbackReport(&codegen_diagnostics.aot_fallback_report, err_writer);
    } else {
        printAotFallbackSummary(&codegen_diagnostics.aot_fallback_report, err_writer);
    }
    warnAotFallbackMismatch(&codegen_diagnostics.aot_fallback_report.static_check, err_writer);

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

    printInterpreterLinkSummary(interpreter_fallback, lock_interpreter_setting, emit_runtime_image_flag, &codegen_diagnostics, err_writer);

    if (codegen_diagnostics.image_stats) |stats| {
        err_writer.print("runtime-image: words={d} stack-effects={d} typevalue-slots={d} blob-present={s}\n", .{
            stats.word_count,
            stats.stack_effect_count,
            stats.typevalue_slot_count,
            if (stats.blob_present) "true" else "false",
        }) catch {};
        err_writer.flush() catch {};
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

    // Discover lib1z.a path relative to this executable. Freestanding builds
    // do not link the host runtime; the caller supplies a freestanding runtime
    // archive (and the bare-metal platform archives) via --link-object.
    const lib1z_path = if (!target_is_freestanding)
        (if (exe_dir_slice) |exe_dir|
            std.fs.path.join(allocator, &.{ exe_dir, "../clib/lib1z.a" }) catch null
        else
            null)
    else
        null;
    defer if (lib1z_path) |p| allocator.free(p);

    if (!target_is_freestanding and lib1z_path == null) {
        err_writer.writeAll("Error: cannot locate lib1z.a\n") catch {};
        err_writer.flush() catch {};
        return 1;
    }

    // Stage 2: Invoke C compiler.
    // Default to zig cc since lib1z.a is built with Zig's C backend and may
    // contain sanitizer references that system cc doesn't resolve.
    const cc_env = std.posix.getenv("CC");
    const cc_cmd = cc_env orelse "zig";

    // Runtime-formatted flags must outlive the child process; free them once
    // the commands have finished.
    var owned_flags: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (owned_flags.items) |f| allocator.free(f);
        owned_flags.deinit(allocator);
    }

    // Set by the hosted two-stage path to the intermediate object; freed and removed alongside
    // the generated C.
    var obj_path: ?[]const u8 = null;
    defer if (obj_path) |p| allocator.free(p);

    // Reclaim the generated C and the intermediate object on every exit, including the compile and
    // link failure paths, unless --save-temps keeps them. Report the C before the object so a
    // `Saved:` consumer that reads the first line gets the source.
    defer {
        if (save_temps) {
            err_writer.print("Saved: {s}\n", .{tmp_path}) catch {};
            if (obj_path) |p| err_writer.print("Saved: {s}\n", .{p}) catch {};
            err_writer.flush() catch {};
        } else {
            std.fs.cwd().deleteFile(tmp_path) catch {};
            if (obj_path) |p| std.fs.cwd().deleteFile(p) catch {};
        }
    }

    if (target_is_freestanding) {
        // Cross-link a bare-metal ELF in one step: target the requested triple, drop the hosted C
        // runtime, and link only what the caller passes in plus the linker script that places the
        // kernel.
        //
        // There is no host archive to link and UBSan is disabled, so -O needs no compile/link split
        // here.
        var cc_argv: std.ArrayListUnmanaged([]const u8) = .{};
        defer cc_argv.deinit(allocator);
        cc_argv.append(allocator, cc_cmd) catch return 1;
        if (cc_env == null) cc_argv.append(allocator, "cc") catch return 1;
        cc_argv.append(allocator, "-o") catch return 1;
        cc_argv.append(allocator, output) catch return 1;
        cc_argv.append(allocator, tmp_path) catch return 1;
        // Default bare metal to -O0 so the audited freestanding codegen stays identical to the prior
        // no-flag build. An explicit --opt-level still applies, so a size-tuned image can pick -Os
        // or -Oz.
        cc_argv.append(allocator, if (opt_token_explicit) opt_token else "-O0") catch return 1;
        cc_argv.append(allocator, "-target") catch return 1;
        cc_argv.append(allocator, target_triple_override.?) catch return 1;
        cc_argv.append(allocator, "-ffreestanding") catch return 1;
        cc_argv.append(allocator, "-nostdlib") catch return 1;
        // zig cc instruments C with UBSan by default, which would pull in the
        // hosted UBSan runtime; there is no such runtime on bare metal.
        cc_argv.append(allocator, "-fno-sanitize=undefined") catch return 1;
        // Bare-metal kernels load high in the address space (e.g. the riscv64
        // virt OpenSBI handoff at 0x80200000), beyond what the default medlow
        // code model can reach with absolute lui/HI20 relocations.
        if (std.mem.startsWith(u8, target_triple_override.?, "riscv")) {
            cc_argv.append(allocator, "-mcmodel=medany") catch return 1;
        }
        cc_argv.append(allocator, "-ffunction-sections") catch return 1;
        cc_argv.append(allocator, "-fdata-sections") catch return 1;
        cc_argv.append(allocator, "-Wl,--gc-sections") catch return 1;
        for (link_objects.items) |obj| {
            cc_argv.append(allocator, obj) catch return 1;
        }
        if (linker_script) |script| {
            const flag = std.fmt.allocPrint(allocator, "-Wl,-T,{s}", .{script}) catch return 1;
            owned_flags.append(allocator, flag) catch return 1;
            cc_argv.append(allocator, flag) catch return 1;
        }

        if (runCcCommand(allocator, cc_argv.items, cc_cmd, err_writer) != 0) return 1;
    } else {
        // Hosted build in two stages: compile the generated C to an object at the requested -O
        // level, then link that object with the runtime archive.
        //
        // Keeping -O on the compile stage only means the link never re-derives a release link mode
        // from it. A debug lib1z.a references the UBSan minimal runtime, which an -O>=1 link would
        // drop, breaking the link. The split makes every -O level link against both a debug and a
        // release archive.
        obj_path = std.fmt.allocPrint(allocator, "{s}/1z_aot_{d}.o", .{ tmpdir, pid }) catch {
            err_writer.writeAll("Error: out of memory\n") catch {};
            err_writer.flush() catch {};
            return 1;
        };

        var compile_argv: std.ArrayListUnmanaged([]const u8) = .{};
        defer compile_argv.deinit(allocator);
        compile_argv.append(allocator, cc_cmd) catch return 1;
        if (cc_env == null) compile_argv.append(allocator, "cc") catch return 1;
        compile_argv.append(allocator, opt_token) catch return 1;
        // Section flags belong on the compile stage so the link stage's --gc-sections can drop the
        // unreferenced generated functions.
        if (builtin.os.tag == .linux) {
            compile_argv.append(allocator, "-ffunction-sections") catch return 1;
            compile_argv.append(allocator, "-fdata-sections") catch return 1;
        }
        compile_argv.append(allocator, "-c") catch return 1;
        compile_argv.append(allocator, tmp_path) catch return 1;
        compile_argv.append(allocator, "-o") catch return 1;
        compile_argv.append(allocator, obj_path.?) catch return 1;

        if (runCcCommand(allocator, compile_argv.items, cc_cmd, err_writer) != 0) return 1;

        var link_argv: std.ArrayListUnmanaged([]const u8) = .{};
        defer link_argv.deinit(allocator);
        link_argv.append(allocator, cc_cmd) catch return 1;
        if (cc_env == null) link_argv.append(allocator, "cc") catch return 1;
        link_argv.append(allocator, "-o") catch return 1;
        link_argv.append(allocator, output) catch return 1;
        link_argv.append(allocator, obj_path.?) catch return 1;
        link_argv.append(allocator, lib1z_path.?) catch return 1;
        // XXX(ripta): linker GC when the binary is interpreter-free (no jitInterpretedCall / jitCallQuotation),
        //             the linker drops the unreferenced interpreter code. Harmless when the interpreter is in
        //             use because the symbols are still referenced.
        switch (builtin.os.tag) {
            .macos => {
                link_argv.append(allocator, "-Wl,-dead_strip") catch return 1;
            },
            .linux => {
                link_argv.append(allocator, "-Wl,--gc-sections") catch return 1;
            },
            else => {},
        }
        link_argv.append(allocator, "-lffi") catch return 1;
        for (static_libs.items) |lib_name| {
            const flag = std.fmt.allocPrint(allocator, "-l{s}", .{lib_name}) catch return 1;
            owned_flags.append(allocator, flag) catch return 1;
            link_argv.append(allocator, flag) catch return 1;
        }
        for (link_objects.items) |obj| {
            link_argv.append(allocator, obj) catch return 1;
        }

        if (runCcCommand(allocator, link_argv.items, cc_cmd, err_writer) != 0) return 1;
    }

    return 0;
}

/// Spawn `argv` as a C-compiler invocation, drain its stderr, and wait. Returns 0 on a clean exit.
/// On a spawn failure, a non-zero exit, or a wait error it prints a diagnostic to `err_writer` and
/// returns 1.
fn runCcCommand(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cc_cmd: []const u8,
    err_writer: anytype,
) u8 {
    var child = std.process.Child.init(argv, allocator);
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

    return 0;
}

/// Result of probing the C compiler for its self-reported identity.
/// Both fields default to the empty slice when the probe could not
/// reach the compiler or could not parse a usable banner.
const CCompilerProbe = struct {
    id: []const u8 = "",
    banner: []const u8 = "",
    /// Allocation backing `banner` (a slice of captured stdout).
    raw: []u8 = &.{},
    /// Allocation backing `id` (always owned separately so we can prefix
    /// `zig ` when we invoked `zig cc`).
    id_buf: []u8 = &.{},

    fn deinit(self: CCompilerProbe, allocator: std.mem.Allocator) void {
        if (self.raw.len > 0) allocator.free(self.raw);
        if (self.id_buf.len > 0) allocator.free(self.id_buf);
    }
};

/// Run `<cc> --version` (matching the cc invocation `1z build` will use)
/// and synthesize a (`id`, `banner`) pair. Failure modes -- spawn error,
/// non-zero exit, empty output, parse miss -- all collapse to an empty
/// probe; the caller treats both fields as advisory provenance.
fn probeCCompiler(allocator: std.mem.Allocator) CCompilerProbe {
    const cc_env = std.posix.getenv("CC");
    const cc_cmd = cc_env orelse "zig";

    var argv: std.ArrayListUnmanaged([]const u8) = .{};
    defer argv.deinit(allocator);
    argv.append(allocator, cc_cmd) catch return .{};
    if (cc_env == null) argv.append(allocator, "cc") catch return .{};
    argv.append(allocator, "--version") catch return .{};

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 4096,
    }) catch return .{};
    allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        allocator.free(result.stdout);
        return .{};
    }

    const newline_idx = std.mem.indexOfScalar(u8, result.stdout, '\n') orelse result.stdout.len;
    const banner = std.mem.trim(u8, result.stdout[0..newline_idx], &std.ascii.whitespace);
    if (banner.len == 0) {
        allocator.free(result.stdout);
        return .{};
    }

    const family_id: []const u8 =
        if (std.mem.indexOf(u8, banner, "Apple clang") != null)
            "Apple clang"
        else if (std.mem.indexOf(u8, banner, "clang") != null)
            "clang"
        else if (std.mem.indexOf(u8, banner, "gcc") != null or std.mem.indexOf(u8, banner, "GCC") != null)
            "gcc"
        else blk: {
            const first_space = std.mem.indexOfScalar(u8, banner, ' ') orelse banner.len;
            break :blk banner[0..first_space];
        };

    // When we invoked `zig cc`, prefix the family so the metadata
    // distinguishes the bundled clang from a system clang.
    const id_buf: []u8 = if (cc_env == null) blk: {
        const buf = std.fmt.allocPrint(allocator, "zig {s}", .{family_id}) catch {
            allocator.free(result.stdout);
            return .{};
        };
        break :blk buf;
    } else blk: {
        const buf = allocator.dupe(u8, family_id) catch {
            allocator.free(result.stdout);
            return .{};
        };
        break :blk buf;
    };

    return .{
        .id = id_buf,
        .banner = banner,
        .raw = result.stdout,
        .id_buf = id_buf,
    };
}

const inspect_meta_open = "<<1Z_AOT_META_V1\n";
const inspect_meta_close = ">>";
const inspect_max_bytes: usize = 256 * 1024 * 1024;

const AotInspectFields = struct {
    schema_version: []const u8,
    interpreter_linked: []const u8,
    interpreter_fallback_mode: []const u8,
    interpreter_setting_locked: []const u8,
    runtime_image_present: []const u8,
    target_triple: []const u8,
    build_mode: []const u8,
    onez_version: []const u8,
    prelude_hash: []const u8,
    // Artifact class names the binary's maximum semantic capability
    // (`interpreter`, `runtime-image-aot`, or `interpreter-free-aot`).
    // Required at schema-version=2; absent on legacy v1 binaries, in
    // which case the inspector derives the class from
    // `interpreter_linked` and `runtime_image_present`.
    artifact_class: ?[]const u8 = null,
    // Per-callback linkage breakdown. Optional so binaries built
    // before the field existed parse cleanly; absent values are
    // omitted from the rendered report rather than printed as
    // "unknown."
    jit_interpreted_call_linked: ?[]const u8 = null,
    // Metadata-image presence indicates an interpreter-free AOT
    // binary that carries the read-only introspection surface
    // (word metadata, no executable bodies). Absent on v1/v2 binaries;
    // populated at schema-version=3+.
    metadata_image_present: ?[]const u8 = null,
    // Runtime-image fields are populated when the binary embeds an
    // image -- either the full runtime image or the metadata-only
    // image. Both shapes share the same on-disk format, so the
    // format-version / blob-present / word-count fields apply to
    // both. Absent when no image is embedded.
    runtime_image_format_version: ?[]const u8 = null,
    runtime_image_blob_present: ?[]const u8 = null,
    runtime_image_word_count: ?[]const u8 = null,
    // Count of method dispatch-entry rows the image replays. Informational;
    // absent on binaries built before this field was added.
    runtime_image_dispatch_entry_count: ?[]const u8 = null,
    // Optional toolchain provenance. Present only when the build
    // environment captured the corresponding value.
    onez_git_commit: ?[]const u8 = null,
    zig_version: ?[]const u8 = null,
    c_compiler_id: ?[]const u8 = null,
    c_compiler_version: ?[]const u8 = null,
    // Comma-separated list of dynamic-* marker names reachable in the
    // frozen call graph, or "none". Absent on binaries built before this
    // field was added; present on current and future builds.
    dynamic_features: ?[]const u8 = null,
};

const AotInspectError = error{
    MarkerNotFound,
    Truncated,
    MalformedLine,
    UnsupportedSchemaVersion,
    MissingField,
};

const AotInspectErrorContext = struct {
    missing_field: []const u8 = "",
    schema_version: []const u8 = "",
};

fn parseAotMetadata(
    contents: []const u8,
    err_ctx: *AotInspectErrorContext,
) AotInspectError!AotInspectFields {
    const open_idx = std.mem.indexOf(u8, contents, inspect_meta_open) orelse
        return error.MarkerNotFound;
    const payload_start = open_idx + inspect_meta_open.len;
    const close_rel = std.mem.indexOf(u8, contents[payload_start..], inspect_meta_close) orelse
        return error.Truncated;
    const payload = contents[payload_start .. payload_start + close_rel];

    var schema_version: ?[]const u8 = null;
    var interpreter_linked: ?[]const u8 = null;
    var interpreter_fallback_mode: ?[]const u8 = null;
    var interpreter_setting_locked: ?[]const u8 = null;
    var runtime_image_present: ?[]const u8 = null;
    var target_triple: ?[]const u8 = null;
    var build_mode: ?[]const u8 = null;
    var onez_version: ?[]const u8 = null;
    var prelude_hash: ?[]const u8 = null;
    var artifact_class: ?[]const u8 = null;
    var jit_interpreted_call_linked: ?[]const u8 = null;
    var metadata_image_present: ?[]const u8 = null;
    var runtime_image_format_version: ?[]const u8 = null;
    var runtime_image_blob_present: ?[]const u8 = null;
    var runtime_image_word_count: ?[]const u8 = null;
    var runtime_image_dispatch_entry_count: ?[]const u8 = null;
    var onez_git_commit: ?[]const u8 = null;
    var zig_version: ?[]const u8 = null;
    var c_compiler_id: ?[]const u8 = null;
    var c_compiler_version: ?[]const u8 = null;
    var dynamic_features: ?[]const u8 = null;

    var line_it = std.mem.splitScalar(u8, payload, '\n');
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.MalformedLine;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "schema-version")) {
            schema_version = value;
        } else if (std.mem.eql(u8, key, "interpreter-linked")) {
            interpreter_linked = value;
        } else if (std.mem.eql(u8, key, "artifact-class")) {
            artifact_class = value;
        } else if (std.mem.eql(u8, key, "jit-interpreted-call-linked")) {
            jit_interpreted_call_linked = value;
        } else if (std.mem.eql(u8, key, "interpreter-fallback-mode")) {
            interpreter_fallback_mode = value;
        } else if (std.mem.eql(u8, key, "interpreter-setting-locked")) {
            interpreter_setting_locked = value;
        } else if (std.mem.eql(u8, key, "runtime-image-present")) {
            runtime_image_present = value;
        } else if (std.mem.eql(u8, key, "metadata-image-present")) {
            metadata_image_present = value;
        } else if (std.mem.eql(u8, key, "target-triple")) {
            target_triple = value;
        } else if (std.mem.eql(u8, key, "build-mode")) {
            build_mode = value;
        } else if (std.mem.eql(u8, key, "onez-version")) {
            onez_version = value;
        } else if (std.mem.eql(u8, key, "prelude-hash")) {
            prelude_hash = value;
        } else if (std.mem.eql(u8, key, "runtime-image-format-version")) {
            runtime_image_format_version = value;
        } else if (std.mem.eql(u8, key, "runtime-image-blob-present")) {
            runtime_image_blob_present = value;
        } else if (std.mem.eql(u8, key, "runtime-image-word-count")) {
            runtime_image_word_count = value;
        } else if (std.mem.eql(u8, key, "runtime-image-dispatch-entry-count")) {
            runtime_image_dispatch_entry_count = value;
        } else if (std.mem.eql(u8, key, "onez-git-commit")) {
            onez_git_commit = value;
        } else if (std.mem.eql(u8, key, "zig-version")) {
            zig_version = value;
        } else if (std.mem.eql(u8, key, "c-compiler-id")) {
            c_compiler_id = value;
        } else if (std.mem.eql(u8, key, "c-compiler-version")) {
            c_compiler_version = value;
        } else if (std.mem.eql(u8, key, "dynamic-features")) {
            dynamic_features = value;
        }
        // Unknown keys are ignored so the parser can read newer
        // binaries that add forward-compatible optional fields.
    }

    const sv = schema_version orelse {
        err_ctx.missing_field = "schema-version";
        return error.MissingField;
    };
    // Schema v1 omits `artifact-class`; the inspector derives it from
    // the other fields. v2 adds `artifact-class` as a required key.
    // v3 adds `metadata-image-present` for interpreter-free binaries
    // that ship the read-only introspection surface.
    const is_v2 = std.mem.eql(u8, sv, "2");
    const is_v3 = std.mem.eql(u8, sv, "3");
    if (!std.mem.eql(u8, sv, "1") and !is_v2 and !is_v3) {
        err_ctx.schema_version = sv;
        return error.UnsupportedSchemaVersion;
    }

    const required_fields = [_]struct { name: []const u8, value: ?[]const u8 }{
        .{ .name = "interpreter-linked", .value = interpreter_linked },
        .{ .name = "interpreter-fallback-mode", .value = interpreter_fallback_mode },
        .{ .name = "interpreter-setting-locked", .value = interpreter_setting_locked },
        .{ .name = "runtime-image-present", .value = runtime_image_present },
        .{ .name = "target-triple", .value = target_triple },
        .{ .name = "build-mode", .value = build_mode },
        .{ .name = "onez-version", .value = onez_version },
        .{ .name = "prelude-hash", .value = prelude_hash },
    };
    for (required_fields) |f| {
        if (f.value == null) {
            err_ctx.missing_field = f.name;
            return error.MissingField;
        }
    }
    if ((is_v2 or is_v3) and artifact_class == null) {
        err_ctx.missing_field = "artifact-class";
        return error.MissingField;
    }
    if (is_v3 and metadata_image_present == null) {
        err_ctx.missing_field = "metadata-image-present";
        return error.MissingField;
    }

    return AotInspectFields{
        .schema_version = sv,
        .interpreter_linked = interpreter_linked.?,
        .interpreter_fallback_mode = interpreter_fallback_mode.?,
        .interpreter_setting_locked = interpreter_setting_locked.?,
        .runtime_image_present = runtime_image_present.?,
        .target_triple = target_triple.?,
        .build_mode = build_mode.?,
        .onez_version = onez_version.?,
        .prelude_hash = prelude_hash.?,
        .artifact_class = artifact_class,
        .jit_interpreted_call_linked = jit_interpreted_call_linked,
        .metadata_image_present = metadata_image_present,
        .runtime_image_format_version = runtime_image_format_version,
        .runtime_image_blob_present = runtime_image_blob_present,
        .runtime_image_word_count = runtime_image_word_count,
        .runtime_image_dispatch_entry_count = runtime_image_dispatch_entry_count,
        .onez_git_commit = onez_git_commit,
        .zig_version = zig_version,
        .c_compiler_id = c_compiler_id,
        .c_compiler_version = c_compiler_version,
        .dynamic_features = dynamic_features,
    };
}

/// Scan `freeze_result.call_targets` and return a comma-separated list of
/// `dynamic-*` marker names reachable through resolved native calls, or
/// `"none"`. The returned slice is allocated from `allocator`. The list
/// preserves the order of `dynamic_marker_policy` (compile, eval, load,
/// quotation-construction) and omits markers not touched.
fn computeTouchedDynamicFeatures(
    freeze_result: *const aot_freeze.FreezeResult,
    ctx: *const Context,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error![]const u8 {
    // Build word_id → name map for native words.
    var id_to_name = std.AutoHashMapUnmanaged(u32, []const u8){};
    defer id_to_name.deinit(allocator);
    for (freeze_result.words) |w| {
        if (w.is_native) try id_to_name.put(allocator, w.word_id, w.name);
    }

    // Track which dynamic markers are touched.
    var touched = [4]bool{ false, false, false, false };
    const policy = &[_]*const value_mod.Marker{
        &markers_mod.dynamic_compile_marker,
        &markers_mod.dynamic_eval_marker,
        &markers_mod.dynamic_load_marker,
        &markers_mod.dynamic_quotation_construction_marker,
    };

    for (freeze_result.call_targets) |entry| {
        switch (entry.resolved) {
            .native => |nid| {
                const name = id_to_name.get(nid) orelse continue;
                if (ctx.lookupWord(name)) |def| {
                    for (def.markers) |mk| {
                        for (policy, 0..) |pm, pi| {
                            if (mk == pm) touched[pi] = true;
                        }
                    }
                }
            },
            else => {},
        }
    }

    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);
    const names = [4][]const u8{
        "dynamic-compile",
        "dynamic-eval",
        "dynamic-load",
        "dynamic-quotation-construction",
    };
    for (touched, names) |t, nm| {
        if (!t) continue;
        if (out.items.len > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, nm);
    }
    if (out.items.len == 0) return try allocator.dupe(u8, "none");
    return out.toOwnedSlice(allocator);
}

/// Resolve a feature name (short or full `dynamic-` prefix) to the
/// corresponding well-known marker constant, or return null for unknown names.
fn resolveReachFeature(name: []const u8) ?*const value_mod.Marker {
    const n = if (std.mem.startsWith(u8, name, "dynamic-")) name["dynamic-".len..] else name;
    if (std.mem.eql(u8, n, "eval")) return &markers_mod.dynamic_eval_marker;
    if (std.mem.eql(u8, n, "load")) return &markers_mod.dynamic_load_marker;
    if (std.mem.eql(u8, n, "compile")) return &markers_mod.dynamic_compile_marker;
    if (std.mem.eql(u8, n, "quotation-construction")) return &markers_mod.dynamic_quotation_construction_marker;
    return null;
}

/// Write the reachability report for a single feature to `w`.
fn writeReachReport(
    w: anytype,
    feature_name: []const u8,
    chains: []const aot_freeze.ReachChain,
) !void {
    try w.print("feature: dynamic-{s}\n\n", .{
        if (std.mem.startsWith(u8, feature_name, "dynamic-"))
            feature_name["dynamic-".len..]
        else
            feature_name,
    });
    if (chains.len == 0) {
        try w.writeAll("  (none)\n");
        return;
    }
    for (chains) |chain| {
        try w.writeAll("  ");
        for (chain.compound_chain, 0..) |word, i| {
            if (i > 0) try w.writeAll(" \xe2\x86\x92 ");
            try w.writeAll(word);
        }
        try w.writeAll(" \xe2\x86\x92 ");
        try w.writeAll(chain.native_name);
        try w.writeAll("\n");
    }
}

/// Handle `1z inspect --reach FEATURE <source.1z>`: freeze the source file
/// (with the most permissive artifact class so no bans fire), then walk the
/// call-target map to find every compound word that transitively calls a
/// native carrying the named dynamic-capability marker.
fn handleInspectReach(
    gpa: std.mem.Allocator,
    global: *GlobalFlags,
    feature_name: []const u8,
    source_file: []const u8,
) u8 {
    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(&stdout_buf);
    const out_writer = &stdout.interface;

    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(&stderr_buf);
    const err_writer = &stderr.interface;

    const target_marker = resolveReachFeature(feature_name) orelse {
        err_writer.print(
            "Error: unknown feature '{s}'; valid names: eval, load, compile, quotation-construction\n",
            .{feature_name},
        ) catch {};
        err_writer.flush() catch {};
        return 1;
    };

    var mem_limit = MemoryLimitAllocator.init(gpa, global.max_memory_bytes);
    const allocator = mem_limit.allocator();

    var ctx_obj = Context.init(allocator);
    defer ctx_obj.deinit();
    const ctx = &ctx_obj;

    var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.selfExeDirPath(&self_exe_buf)) |exe_dir| {
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
        if (global.stdlib_path) |sp| ctx.stdlib_path = sp;
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

    var freeze_diagnostics: aot_freeze.FreezeDiagnostics = .{};
    var freeze_result = aot_freeze.freezeModuleGraphOpts(ctx, source_file, &freeze_diagnostics, allocator, .{
        .artifact_class = .interpreter,
    }) catch |err| {
        switch (err) {
            error.FileNotFound => err_writer.print("Error: file not found: '{s}'\n", .{source_file}) catch {},
            error.FileReadFailed => err_writer.print("Error: failed to read '{s}'\n", .{source_file}) catch {},
            error.ExecutionFailed => err_writer.writeAll("Error: execution failed\n") catch {},
            error.OutOfMemory => err_writer.writeAll("Error: out of memory\n") catch {},
            else => err_writer.print("Error: {s}\n", .{@errorName(err)}) catch {},
        }
        err_writer.flush() catch {};
        return 1;
    };
    defer freeze_result.deinit(allocator);
    // Freeze leaves the entry file's pragma frame pushed; balance it here.
    defer ctx.popPragmaFrame();

    const chains = aot_freeze.computeReachabilityForMarker(
        &freeze_result,
        ctx,
        target_marker,
        allocator,
    ) catch {
        err_writer.writeAll("Error: out of memory computing reachability\n") catch {};
        err_writer.flush() catch {};
        return 1;
    };
    defer {
        for (chains) |c| c.deinit(allocator);
        allocator.free(chains);
    }

    writeReachReport(out_writer, feature_name, chains) catch {};
    out_writer.flush() catch {};
    return 0;
}

fn handleInspect(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(&stderr_buf);
    const err_writer = &stderr.interface;

    if (hasHelpFlag(args)) {
        printInspectHelp();
        return 0;
    }

    // Parse flags. --reach requires a source file; all others take a binary.
    var global = GlobalFlags{};
    defer global.deinit(gpa);

    var reach_feature: ?[]const u8 = null;
    var path_arg: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const g = parseGlobalFlag(arg, &global, gpa, err_writer) catch return 1;
        if (g == .consumed) continue;
        if (std.mem.eql(u8, arg, "--reach")) {
            i += 1;
            if (i >= args.len) {
                err_writer.writeAll("Error: --reach requires a feature name argument\n") catch {};
                err_writer.flush() catch {};
                return 1;
            }
            reach_feature = args[i];
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') {
            err_writer.print("Error: unknown flag '{s}'\n", .{arg}) catch {};
            err_writer.flush() catch {};
            return 1;
        }
        if (path_arg != null) {
            err_writer.writeAll("Error: 1z inspect takes exactly one path\n") catch {};
            err_writer.flush() catch {};
            return 1;
        }
        path_arg = arg;
    }

    if (reach_feature) |feature| {
        const source = path_arg orelse {
            err_writer.writeAll("Usage: 1z inspect --reach FEATURE <source.1z>\n") catch {};
            err_writer.flush() catch {};
            return 1;
        };
        return handleInspectReach(gpa, &global, feature, source);
    }

    const path = path_arg orelse {
        err_writer.writeAll("Usage: 1z inspect <binary>\n") catch {};
        err_writer.flush() catch {};
        return 1;
    };

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        err_writer.print("Error opening '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
        err_writer.flush() catch {};
        return 1;
    };
    defer file.close();

    const contents = file.readToEndAlloc(gpa, inspect_max_bytes) catch |err| {
        err_writer.print("Error reading '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
        err_writer.flush() catch {};
        return 1;
    };
    defer gpa.free(contents);

    var err_ctx: AotInspectErrorContext = .{};
    const fields = parseAotMetadata(contents, &err_ctx) catch |err| switch (err) {
        error.MarkerNotFound => {
            err_writer.print("Error: '{s}': not a 1z AOT binary or unsupported version\n", .{path}) catch {};
            err_writer.flush() catch {};
            return 1;
        },
        error.Truncated => {
            err_writer.print("Error: '{s}': truncated 1z metadata block\n", .{path}) catch {};
            err_writer.flush() catch {};
            return 1;
        },
        error.MalformedLine => {
            err_writer.print("Error: '{s}': malformed 1z metadata line\n", .{path}) catch {};
            err_writer.flush() catch {};
            return 1;
        },
        error.UnsupportedSchemaVersion => {
            err_writer.print("Error: '{s}': unsupported metadata schema version '{s}'\n", .{ path, err_ctx.schema_version }) catch {};
            err_writer.flush() catch {};
            return 1;
        },
        error.MissingField => {
            err_writer.print("Error: '{s}': metadata missing field '{s}'\n", .{ path, err_ctx.missing_field }) catch {};
            err_writer.flush() catch {};
            return 1;
        },
    };

    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(&stdout_buf);
    const out_writer = &stdout.interface;

    writeInspectReport(out_writer, fields) catch {};
    out_writer.flush() catch {};
    return 0;
}

/// Resolve the artifact-class string for the inspect report. v2
/// binaries embed the class directly; v1 binaries don't, so the
/// inspector recomputes it from the boolean fields using the same
/// "interpreter wins" rule the build uses.
fn deriveArtifactClass(fields: AotInspectFields) []const u8 {
    if (fields.artifact_class) |v| return v;
    const interp_linked = std.mem.eql(u8, fields.interpreter_linked, "yes");
    const image_present = std.mem.eql(u8, fields.runtime_image_present, "yes");
    if (interp_linked) return "interpreter";
    if (image_present) return "runtime-image-aot";
    return "interpreter-free-aot";
}

fn writeInspectReport(w: anytype, fields: AotInspectFields) !void {
    try w.writeAll("kind: aot-binary\n");
    try w.print("artifact: {s}\n", .{deriveArtifactClass(fields)});
    try w.print("target: {s}\n", .{fields.target_triple});
    try w.print("build-mode: {s}\n", .{fields.build_mode});
    try w.print(
        "interpreter: linked={s}, fallback={s}, locked={s}\n",
        .{ fields.interpreter_linked, fields.interpreter_fallback_mode, fields.interpreter_setting_locked },
    );
    if (fields.jit_interpreted_call_linked) |v| {
        try w.print("aot-callbacks: jit-interpreted-call={s}\n", .{v});
    }
    if (std.mem.eql(u8, fields.runtime_image_present, "yes") and
        fields.runtime_image_format_version != null and
        fields.runtime_image_blob_present != null and
        fields.runtime_image_word_count != null)
    {
        try w.print(
            "runtime-image: present=yes, format-version={s}, blob-present={s}, word-count={s}\n",
            .{
                fields.runtime_image_format_version.?,
                fields.runtime_image_blob_present.?,
                fields.runtime_image_word_count.?,
            },
        );
    } else {
        try w.print("runtime-image: present={s}\n", .{fields.runtime_image_present});
    }
    if (fields.runtime_image_dispatch_entry_count) |v| {
        // Informational; omitted when zero to keep the common no-method-dispatch
        // binary's report unchanged. The blob always carries the count.
        if (!std.mem.eql(u8, v, "0")) {
            try w.print("dispatch-entries: {s}\n", .{v});
        }
    }
    if (fields.dynamic_features) |v| {
        try w.print("dynamic-features: {s}\n", .{v});
    }
    try w.print("1z-version: {s}\n", .{fields.onez_version});
    try w.print("prelude-hash: {s}\n", .{fields.prelude_hash});
    if (fields.onez_git_commit) |v| {
        try w.print("1z-git-commit: {s}\n", .{v});
    }
    if (fields.zig_version) |v| {
        try w.print("zig-version: {s}\n", .{v});
    }
    if (fields.c_compiler_id) |v| {
        try w.print("c-compiler-id: {s}\n", .{v});
    }
    if (fields.c_compiler_version) |v| {
        try w.print("c-compiler-version: {s}\n", .{v});
    }
}

fn repl(ctx: *Context, verbosity: Verbosity, max_memory_bytes: usize) void {
    ctx.setPragma("redefinition-arity-mismatch", value_mod.stringValue("warning")) catch {};

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

        var engine = effect_inference.InferenceEngine.init(&ctx.dictionary, &ctx.dispatch, ctx.local_frames.items, ctx.quotationAllocator(), pragma_settings.severity_override, pragma_settings.suppressed, pragma_settings.suppress_undeclared, &ctx.builtin_type_values, ctx.getAnyTypeSentinel(), pragma_settings.type_check_mode, pragma_settings.arity_check_mode, pragma_settings.default_arm_mode, pragma_settings.never_returns_mode, ctx);
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
    _ = @import("quotation_stamp_store.zig");
    _ = @import("atomic_slot_map.zig");
    _ = @import("reified_decode_cache.zig");
    _ = @import("tokenizer.zig");
    _ = @import("dictionary.zig");
    _ = @import("primitives.zig");
    _ = @import("parser.zig");
    _ = @import("statement.zig");
    _ = @import("formatter.zig");
    _ = @import("benchmark.zig");
    _ = @import("profile.zig");
    _ = @import("pprof.zig");
    _ = @import("memory_limit.zig");
    _ = @import("container_limits.zig");
    _ = @import("container_backing.zig");
    _ = @import("line_editor.zig");
    _ = @import("debugger/mod.zig");
    _ = @import("multiplexer.zig");
    _ = @import("trace.zig");
    _ = @import("call_graph.zig");
    _ = @import("effect_inference.zig");
    _ = @import("lsp/mod.zig");
    _ = @import("simd.zig");
    _ = @import("aot_freeze.zig");
    _ = @import("aot_type_inference.zig");
    _ = @import("aot_image.zig");
    _ = @import("aot_image_emit.zig");
    _ = @import("aot_image_loader.zig");
    _ = @import("embedded_stdlib.zig");
}

test "root allocator gate selects the debug allocator under Debug builds" {
    try std.testing.expectEqual(builtin.mode == .Debug, root_allocator_is_debug);
    // The unit test suite runs under Debug, so the safety-checked allocator is
    // active and its leak / use-after-free detection covers every test.
    try std.testing.expect(root_allocator_is_debug);
}

test "writeVersion emits '1z <version>\\n'" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeVersion(fbs.writer());
    const expected = "1z " ++ version ++ "\n";
    try std.testing.expectEqualStrings(expected, fbs.getWritten());
}

test "parseSamplingTick: bare seconds and ms suffix" {
    try std.testing.expectEqual(@as(?i128, 2 * std.time.ns_per_s), parseSamplingTick("2"));
    try std.testing.expectEqual(@as(?i128, 0), parseSamplingTick("0"));
    try std.testing.expectEqual(@as(?i128, 500 * std.time.ns_per_ms), parseSamplingTick("500ms"));
    try std.testing.expectEqual(@as(?i128, std.time.ns_per_s), parseSamplingTick("1000ms"));
}

test "parseSamplingTick: malformed input returns null" {
    try std.testing.expectEqual(@as(?i128, null), parseSamplingTick("abc"));
    try std.testing.expectEqual(@as(?i128, null), parseSamplingTick(""));
    try std.testing.expectEqual(@as(?i128, null), parseSamplingTick("ms"));
    try std.testing.expectEqual(@as(?i128, null), parseSamplingTick("5x"));
    try std.testing.expectEqual(@as(?i128, null), parseSamplingTick("1.5"));
    try std.testing.expectEqual(@as(?i128, null), parseSamplingTick("-1"));
}

test "parseExecutionFlag: sample axes and sampling-tick" {
    var buf: [256]u8 = undefined;

    {
        var w = std.Io.Writer.fixed(&buf);
        var state = ExecutionFlags{};
        try std.testing.expectEqual(FlagParseResult.consumed, try parseExecutionFlag("--sample-tasks", &state, &w));
        try std.testing.expect(state.trace_config.sample_tasks);
        try std.testing.expect(!state.trace_config.sample_memory);
        try std.testing.expectEqual(@as(?i128, null), state.trace_config.sampling_tick_ns);
    }

    {
        var w = std.Io.Writer.fixed(&buf);
        var state = ExecutionFlags{};
        try std.testing.expectEqual(FlagParseResult.consumed, try parseExecutionFlag("--sample-memory", &state, &w));
        try std.testing.expect(state.trace_config.sample_memory);
        try std.testing.expect(!state.trace_config.sample_tasks);
    }

    {
        // A tick with neither axis enabled parses fine and stays a no-op: the
        // interval is recorded but both axes remain off.
        var w = std.Io.Writer.fixed(&buf);
        var state = ExecutionFlags{};
        try std.testing.expectEqual(FlagParseResult.consumed, try parseExecutionFlag("--sampling-tick=250ms", &state, &w));
        try std.testing.expectEqual(@as(?i128, 250 * std.time.ns_per_ms), state.trace_config.sampling_tick_ns);
        try std.testing.expect(!state.trace_config.sample_tasks);
        try std.testing.expect(!state.trace_config.sample_memory);
    }
}

test "parseExecutionFlag: malformed and missing sampling-tick value" {
    var buf: [256]u8 = undefined;

    {
        var w = std.Io.Writer.fixed(&buf);
        var state = ExecutionFlags{};
        try std.testing.expectError(error.InvalidFlagValue, parseExecutionFlag("--sampling-tick=abc", &state, &w));
        try std.testing.expectEqualStrings("Error: invalid value for --sampling-tick: 'abc'\n", w.buffered());
    }

    {
        var w = std.Io.Writer.fixed(&buf);
        var state = ExecutionFlags{};
        try std.testing.expectError(error.InvalidFlagValue, parseExecutionFlag("--sampling-tick", &state, &w));
        try std.testing.expectEqualStrings("Error: --sampling-tick requires a value (e.g. --sampling-tick=1000ms)\n", w.buffered());
    }
}

test "parseExecutionFlag: JIT dump flags" {
    var buf: [256]u8 = undefined;

    {
        var w = std.Io.Writer.fixed(&buf);
        var state = ExecutionFlags{};
        try std.testing.expectEqual(FlagParseResult.consumed, try parseExecutionFlag("--dump-jit-bytes", &state, &w));
        try std.testing.expect(state.trace_config.dump_jit_bytes);
        try std.testing.expectEqual(@as(?[]const u8, null), state.trace_config.dump_jit_bin_dir);
    }

    {
        var w = std.Io.Writer.fixed(&buf);
        var state = ExecutionFlags{};
        try std.testing.expectEqual(FlagParseResult.consumed, try parseExecutionFlag("--dump-jit-bin-dir=/tmp/x", &state, &w));
        try std.testing.expectEqualStrings("/tmp/x", state.trace_config.dump_jit_bin_dir.?);
        try std.testing.expect(!state.trace_config.dump_jit_bytes);
    }
}

test "parseExecutionFlag: malformed and missing --dump-jit-bin-dir value" {
    var buf: [256]u8 = undefined;

    {
        var w = std.Io.Writer.fixed(&buf);
        var state = ExecutionFlags{};
        try std.testing.expectError(error.InvalidFlagValue, parseExecutionFlag("--dump-jit-bin-dir", &state, &w));
        try std.testing.expectEqualStrings("Error: --dump-jit-bin-dir requires a value (e.g. --dump-jit-bin-dir=DIR)\n", w.buffered());
    }

    {
        var w = std.Io.Writer.fixed(&buf);
        var state = ExecutionFlags{};
        try std.testing.expectError(error.InvalidFlagValue, parseExecutionFlag("--dump-jit-bin-dir=", &state, &w));
        try std.testing.expectEqualStrings("Error: --dump-jit-bin-dir requires a non-empty directory\n", w.buffered());
    }
}

test "parseExecutionFlag: --dump-jit-word filter" {
    var buf: [256]u8 = undefined;

    {
        var w = std.Io.Writer.fixed(&buf);
        var state = ExecutionFlags{};
        try std.testing.expectEqual(FlagParseResult.consumed, try parseExecutionFlag("--dump-jit-word=double,triple", &state, &w));
        try std.testing.expectEqualStrings("double,triple", state.trace_config.dump_jit_word_pattern.?);
    }

    {
        var w = std.Io.Writer.fixed(&buf);
        var state = ExecutionFlags{};
        try std.testing.expectError(error.InvalidFlagValue, parseExecutionFlag("--dump-jit-word", &state, &w));
        try std.testing.expectEqualStrings("Error: --dump-jit-word requires a value (e.g. --dump-jit-word=my-word)\n", w.buffered());
    }

    {
        var w = std.Io.Writer.fixed(&buf);
        var state = ExecutionFlags{};
        try std.testing.expectError(error.InvalidFlagValue, parseExecutionFlag("--dump-jit-word=", &state, &w));
        try std.testing.expectEqualStrings("Error: --dump-jit-word requires a non-empty pattern\n", w.buffered());
    }
}

test "parseAotMetadata happy path" {
    const sample =
        "leading garbage bytes\x00\x00" ++
        "<<1Z_AOT_META_V1\n" ++
        "schema-version=1\n" ++
        "interpreter-linked=no\n" ++
        "interpreter-fallback-mode=auto\n" ++
        "interpreter-setting-locked=no\n" ++
        "runtime-image-present=no\n" ++
        "target-triple=aarch64-macos\n" ++
        "build-mode=ReleaseSafe\n" ++
        "onez-version=0.1.0-dev\n" ++
        "prelude-hash=" ++ ("0123456789abcdef" ** 4) ++ "\n" ++
        ">>\ntrailing\n";
    var err_ctx: AotInspectErrorContext = .{};
    const fields = try parseAotMetadata(sample, &err_ctx);
    try std.testing.expectEqualStrings("1", fields.schema_version);
    try std.testing.expectEqualStrings("no", fields.interpreter_linked);
    try std.testing.expectEqualStrings("auto", fields.interpreter_fallback_mode);
    try std.testing.expectEqualStrings("no", fields.interpreter_setting_locked);
    try std.testing.expectEqualStrings("no", fields.runtime_image_present);
    try std.testing.expectEqualStrings("aarch64-macos", fields.target_triple);
    try std.testing.expectEqualStrings("ReleaseSafe", fields.build_mode);
    try std.testing.expectEqualStrings("0.1.0-dev", fields.onez_version);
    try std.testing.expectEqualStrings("0123456789abcdef" ** 4, fields.prelude_hash);
    try std.testing.expectEqual(@as(?[]const u8, null), fields.artifact_class);
    try std.testing.expectEqual(@as(?[]const u8, null), fields.runtime_image_format_version);
    try std.testing.expectEqual(@as(?[]const u8, null), fields.runtime_image_blob_present);
    try std.testing.expectEqual(@as(?[]const u8, null), fields.runtime_image_word_count);
    try std.testing.expectEqual(@as(?[]const u8, null), fields.onez_git_commit);
    try std.testing.expectEqual(@as(?[]const u8, null), fields.zig_version);
    try std.testing.expectEqual(@as(?[]const u8, null), fields.c_compiler_id);
    try std.testing.expectEqual(@as(?[]const u8, null), fields.c_compiler_version);
}

test "parseAotMetadata captures toolchain provenance when present" {
    const sample =
        "<<1Z_AOT_META_V1\n" ++
        "schema-version=1\n" ++
        "interpreter-linked=no\n" ++
        "interpreter-fallback-mode=auto\n" ++
        "interpreter-setting-locked=no\n" ++
        "runtime-image-present=no\n" ++
        "target-triple=aarch64-macos\n" ++
        "build-mode=ReleaseSafe\n" ++
        "onez-version=0.1.0-dev\n" ++
        "prelude-hash=" ++ ("0123456789abcdef" ** 4) ++ "\n" ++
        "onez-git-commit=" ++ ("ab" ** 20) ++ "\n" ++
        "zig-version=0.15.2\n" ++
        "c-compiler-id=zig clang\n" ++
        "c-compiler-version=Homebrew clang version 20.1.8\n" ++
        ">>\n";
    var err_ctx: AotInspectErrorContext = .{};
    const fields = try parseAotMetadata(sample, &err_ctx);
    try std.testing.expectEqualStrings("ab" ** 20, fields.onez_git_commit.?);
    try std.testing.expectEqualStrings("0.15.2", fields.zig_version.?);
    try std.testing.expectEqualStrings("zig clang", fields.c_compiler_id.?);
    try std.testing.expectEqualStrings("Homebrew clang version 20.1.8", fields.c_compiler_version.?);
    // Runtime-image fields stay absent when present=no.
    try std.testing.expectEqual(@as(?[]const u8, null), fields.runtime_image_format_version);
}

test "parseAotMetadata captures runtime-image conditional fields" {
    const sample =
        "<<1Z_AOT_META_V1\n" ++
        "schema-version=1\n" ++
        "interpreter-linked=no\n" ++
        "interpreter-fallback-mode=auto\n" ++
        "interpreter-setting-locked=no\n" ++
        "runtime-image-present=yes\n" ++
        "target-triple=aarch64-macos\n" ++
        "build-mode=ReleaseSafe\n" ++
        "onez-version=0.1.0-dev\n" ++
        "prelude-hash=" ++ ("0123456789abcdef" ** 4) ++ "\n" ++
        "runtime-image-format-version=3\n" ++
        "runtime-image-blob-present=yes\n" ++
        "runtime-image-word-count=412\n" ++
        ">>\n";
    var err_ctx: AotInspectErrorContext = .{};
    const fields = try parseAotMetadata(sample, &err_ctx);
    try std.testing.expectEqualStrings("yes", fields.runtime_image_present);
    try std.testing.expectEqualStrings("3", fields.runtime_image_format_version.?);
    try std.testing.expectEqualStrings("yes", fields.runtime_image_blob_present.?);
    try std.testing.expectEqualStrings("412", fields.runtime_image_word_count.?);
}

test "parseAotMetadata ignores unknown forward-compat keys" {
    const sample =
        "<<1Z_AOT_META_V1\n" ++
        "schema-version=1\n" ++
        "interpreter-linked=yes\n" ++
        "interpreter-fallback-mode=true\n" ++
        "interpreter-setting-locked=yes\n" ++
        "runtime-image-present=no\n" ++
        "target-triple=x86_64-linux\n" ++
        "build-mode=Debug\n" ++
        "onez-version=99.99.99\n" ++
        "prelude-hash=" ++ ("ff" ** 32) ++ "\n" ++
        "future-conditional-field=hello\n" ++
        ">>\n";
    var err_ctx: AotInspectErrorContext = .{};
    const fields = try parseAotMetadata(sample, &err_ctx);
    try std.testing.expectEqualStrings("yes", fields.interpreter_linked);
    try std.testing.expectEqualStrings("Debug", fields.build_mode);
}

test "parseAotMetadata reports unsupported schema version" {
    const sample =
        "<<1Z_AOT_META_V1\n" ++
        "schema-version=99\n" ++
        ">>\n";
    var err_ctx: AotInspectErrorContext = .{};
    const result = parseAotMetadata(sample, &err_ctx);
    try std.testing.expectError(error.UnsupportedSchemaVersion, result);
    try std.testing.expectEqualStrings("99", err_ctx.schema_version);
}

test "parseAotMetadata parses schema v2 with artifact-class" {
    const sample =
        "<<1Z_AOT_META_V1\n" ++
        "schema-version=2\n" ++
        "artifact-class=interpreter-free-aot\n" ++
        "interpreter-linked=no\n" ++
        "interpreter-fallback-mode=false\n" ++
        "interpreter-setting-locked=yes\n" ++
        "runtime-image-present=no\n" ++
        "target-triple=aarch64-macos\n" ++
        "build-mode=ReleaseSafe\n" ++
        "onez-version=0.1.0-dev\n" ++
        "prelude-hash=" ++ ("0123456789abcdef" ** 4) ++ "\n" ++
        ">>\n";
    var err_ctx: AotInspectErrorContext = .{};
    const fields = try parseAotMetadata(sample, &err_ctx);
    try std.testing.expectEqualStrings("2", fields.schema_version);
    try std.testing.expectEqualStrings("interpreter-free-aot", fields.artifact_class.?);
}

test "parseAotMetadata reports missing artifact-class at schema v2" {
    const sample =
        "<<1Z_AOT_META_V1\n" ++
        "schema-version=2\n" ++
        "interpreter-linked=no\n" ++
        "interpreter-fallback-mode=false\n" ++
        "interpreter-setting-locked=yes\n" ++
        "runtime-image-present=no\n" ++
        "target-triple=aarch64-macos\n" ++
        "build-mode=ReleaseSafe\n" ++
        "onez-version=0.1.0-dev\n" ++
        "prelude-hash=" ++ ("0123456789abcdef" ** 4) ++ "\n" ++
        ">>\n";
    var err_ctx: AotInspectErrorContext = .{};
    const result = parseAotMetadata(sample, &err_ctx);
    try std.testing.expectError(error.MissingField, result);
    try std.testing.expectEqualStrings("artifact-class", err_ctx.missing_field);
}

test "parseAotMetadata parses schema v3 metadata-image-present" {
    const sample =
        "<<1Z_AOT_META_V1\n" ++
        "schema-version=3\n" ++
        "artifact-class=interpreter-free-aot\n" ++
        "interpreter-linked=no\n" ++
        "interpreter-fallback-mode=false\n" ++
        "interpreter-setting-locked=yes\n" ++
        "runtime-image-present=no\n" ++
        "metadata-image-present=yes\n" ++
        "target-triple=aarch64-macos\n" ++
        "build-mode=ReleaseSafe\n" ++
        "onez-version=0.1.0-dev\n" ++
        "prelude-hash=" ++ ("0123456789abcdef" ** 4) ++ "\n" ++
        ">>\n";
    var err_ctx: AotInspectErrorContext = .{};
    const fields = try parseAotMetadata(sample, &err_ctx);
    try std.testing.expectEqualStrings("3", fields.schema_version);
    try std.testing.expectEqualStrings("interpreter-free-aot", fields.artifact_class.?);
    try std.testing.expectEqualStrings("no", fields.runtime_image_present);
    try std.testing.expectEqualStrings("yes", fields.metadata_image_present.?);
}

test "parseAotMetadata reports missing metadata-image-present at schema v3" {
    const sample =
        "<<1Z_AOT_META_V1\n" ++
        "schema-version=3\n" ++
        "artifact-class=interpreter-free-aot\n" ++
        "interpreter-linked=no\n" ++
        "interpreter-fallback-mode=false\n" ++
        "interpreter-setting-locked=yes\n" ++
        "runtime-image-present=no\n" ++
        "target-triple=aarch64-macos\n" ++
        "build-mode=ReleaseSafe\n" ++
        "onez-version=0.1.0-dev\n" ++
        "prelude-hash=" ++ ("0123456789abcdef" ** 4) ++ "\n" ++
        ">>\n";
    var err_ctx: AotInspectErrorContext = .{};
    const result = parseAotMetadata(sample, &err_ctx);
    try std.testing.expectError(error.MissingField, result);
    try std.testing.expectEqualStrings("metadata-image-present", err_ctx.missing_field);
}

test "writeInspectReport omits metadata-image-present line for interpreter-free with metadata image" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const fields: AotInspectFields = .{
        .schema_version = "3",
        .artifact_class = "interpreter-free-aot",
        .interpreter_linked = "no",
        .interpreter_fallback_mode = "false",
        .interpreter_setting_locked = "yes",
        .runtime_image_present = "no",
        .metadata_image_present = "yes",
        .target_triple = "aarch64-macos",
        .build_mode = "ReleaseSafe",
        .onez_version = "0.1.0-dev",
        .prelude_hash = test_prelude_hash,
    };
    try writeInspectReport(fbs.writer(), fields);

    const written = fbs.getWritten();
    // The metadata-image sub-flag stays in the binary metadata block
    // (readable via raw parse) but is intentionally not echoed as a new
    // inspect line; the `artifact:` line is the user-facing summary.
    try std.testing.expect(std.mem.indexOf(u8, written, "metadata-image") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "artifact: interpreter-free-aot\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "runtime-image: present=no\n") != null);
}

test "parseAotMetadata reports missing required field" {
    const sample =
        "<<1Z_AOT_META_V1\n" ++
        "schema-version=1\n" ++
        "interpreter-linked=no\n" ++
        "interpreter-fallback-mode=auto\n" ++
        "interpreter-setting-locked=no\n" ++
        "runtime-image-present=no\n" ++
        "target-triple=aarch64-macos\n" ++
        "build-mode=ReleaseSafe\n" ++
        "onez-version=0.1.0\n" ++
        ">>\n";
    var err_ctx: AotInspectErrorContext = .{};
    const result = parseAotMetadata(sample, &err_ctx);
    try std.testing.expectError(error.MissingField, result);
    try std.testing.expectEqualStrings("prelude-hash", err_ctx.missing_field);
}

test "parseAotMetadata reports missing open marker" {
    const sample = "no marker anywhere in this buffer";
    var err_ctx: AotInspectErrorContext = .{};
    const result = parseAotMetadata(sample, &err_ctx);
    try std.testing.expectError(error.MarkerNotFound, result);
}

test "parseAotMetadata reports truncated payload" {
    const sample =
        "<<1Z_AOT_META_V1\n" ++
        "schema-version=1\n" ++
        "interpreter-linked=no\n";
    var err_ctx: AotInspectErrorContext = .{};
    const result = parseAotMetadata(sample, &err_ctx);
    try std.testing.expectError(error.Truncated, result);
}

test "parseAotMetadata reports malformed line" {
    const sample =
        "<<1Z_AOT_META_V1\n" ++
        "schema-version=1\n" ++
        "no-equals-sign-here\n" ++
        ">>\n";
    var err_ctx: AotInspectErrorContext = .{};
    const result = parseAotMetadata(sample, &err_ctx);
    try std.testing.expectError(error.MalformedLine, result);
}

const test_prelude_hash = "0123456789abcdef" ** 4;

fn baseInspectFields() AotInspectFields {
    return .{
        .schema_version = "1",
        .interpreter_linked = "yes",
        .interpreter_fallback_mode = "auto",
        .interpreter_setting_locked = "no",
        .runtime_image_present = "no",
        .target_triple = "aarch64-macos",
        .build_mode = "ReleaseSafe",
        .onez_version = "0.1.0-dev",
        .prelude_hash = test_prelude_hash,
    };
}

test "writeInspectReport renders required fields with runtime-image absent" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeInspectReport(fbs.writer(), baseInspectFields());
    const expected = "kind: aot-binary\n" ++
        "artifact: interpreter\n" ++
        "target: aarch64-macos\n" ++
        "build-mode: ReleaseSafe\n" ++
        "interpreter: linked=yes, fallback=auto, locked=no\n" ++
        "runtime-image: present=no\n" ++
        "1z-version: 0.1.0-dev\n" ++
        "prelude-hash: " ++ test_prelude_hash ++ "\n";
    try std.testing.expectEqualStrings(expected, fbs.getWritten());
}

test "writeInspectReport renders runtime-image with blob present" {
    var fields = baseInspectFields();
    fields.interpreter_linked = "no";
    fields.runtime_image_present = "yes";
    fields.runtime_image_format_version = "3";
    fields.runtime_image_blob_present = "yes";
    fields.runtime_image_word_count = "8";

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeInspectReport(fbs.writer(), fields);
    const expected = "kind: aot-binary\n" ++
        "artifact: runtime-image-aot\n" ++
        "target: aarch64-macos\n" ++
        "build-mode: ReleaseSafe\n" ++
        "interpreter: linked=no, fallback=auto, locked=no\n" ++
        "runtime-image: present=yes, format-version=3, blob-present=yes, word-count=8\n" ++
        "1z-version: 0.1.0-dev\n" ++
        "prelude-hash: " ++ test_prelude_hash ++ "\n";
    try std.testing.expectEqualStrings(expected, fbs.getWritten());
}

test "writeInspectReport renders runtime-image without blob" {
    var fields = baseInspectFields();
    fields.runtime_image_present = "yes";
    fields.runtime_image_format_version = "3";
    fields.runtime_image_blob_present = "no";
    fields.runtime_image_word_count = "0";

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeInspectReport(fbs.writer(), fields);
    const expected = "kind: aot-binary\n" ++
        "artifact: interpreter\n" ++
        "target: aarch64-macos\n" ++
        "build-mode: ReleaseSafe\n" ++
        "interpreter: linked=yes, fallback=auto, locked=no\n" ++
        "runtime-image: present=yes, format-version=3, blob-present=no, word-count=0\n" ++
        "1z-version: 0.1.0-dev\n" ++
        "prelude-hash: " ++ test_prelude_hash ++ "\n";
    try std.testing.expectEqualStrings(expected, fbs.getWritten());
}

test "writeInspectReport renders optional toolchain provenance when present" {
    var fields = baseInspectFields();
    fields.onez_git_commit = "ab" ** 20;
    fields.zig_version = "0.15.2";
    fields.c_compiler_id = "zig clang";
    fields.c_compiler_version = "Homebrew clang version 20.1.8";

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeInspectReport(fbs.writer(), fields);
    const expected = "kind: aot-binary\n" ++
        "artifact: interpreter\n" ++
        "target: aarch64-macos\n" ++
        "build-mode: ReleaseSafe\n" ++
        "interpreter: linked=yes, fallback=auto, locked=no\n" ++
        "runtime-image: present=no\n" ++
        "1z-version: 0.1.0-dev\n" ++
        "prelude-hash: " ++ test_prelude_hash ++ "\n" ++
        "1z-git-commit: " ++ ("ab" ** 20) ++ "\n" ++
        "zig-version: 0.15.2\n" ++
        "c-compiler-id: zig clang\n" ++
        "c-compiler-version: Homebrew clang version 20.1.8\n";
    try std.testing.expectEqualStrings(expected, fbs.getWritten());
}

test "writeInspectReport falls back to short form when conditional fields missing" {
    var fields = baseInspectFields();
    fields.runtime_image_present = "yes";
    // format-version, blob-present, and word-count remain null.

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeInspectReport(fbs.writer(), fields);
    const expected = "kind: aot-binary\n" ++
        "artifact: interpreter\n" ++
        "target: aarch64-macos\n" ++
        "build-mode: ReleaseSafe\n" ++
        "interpreter: linked=yes, fallback=auto, locked=no\n" ++
        "runtime-image: present=yes\n" ++
        "1z-version: 0.1.0-dev\n" ++
        "prelude-hash: " ++ test_prelude_hash ++ "\n";
    try std.testing.expectEqualStrings(expected, fbs.getWritten());
}

test "writeInspectReport renders fields in the documented order" {
    var fields = baseInspectFields();
    fields.interpreter_linked = "no";
    fields.interpreter_fallback_mode = "false";
    fields.interpreter_setting_locked = "yes";
    fields.runtime_image_present = "yes";
    fields.runtime_image_format_version = "3";
    fields.runtime_image_blob_present = "yes";
    fields.runtime_image_word_count = "412";
    fields.onez_git_commit = "cd" ** 20;
    fields.zig_version = "0.15.2";
    fields.c_compiler_id = "zig clang";
    fields.c_compiler_version = "Homebrew clang version 20.1.8";

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeInspectReport(fbs.writer(), fields);
    const expected = "kind: aot-binary\n" ++
        "artifact: runtime-image-aot\n" ++
        "target: aarch64-macos\n" ++
        "build-mode: ReleaseSafe\n" ++
        "interpreter: linked=no, fallback=false, locked=yes\n" ++
        "runtime-image: present=yes, format-version=3, blob-present=yes, word-count=412\n" ++
        "1z-version: 0.1.0-dev\n" ++
        "prelude-hash: " ++ test_prelude_hash ++ "\n" ++
        "1z-git-commit: " ++ ("cd" ** 20) ++ "\n" ++
        "zig-version: 0.15.2\n" ++
        "c-compiler-id: zig clang\n" ++
        "c-compiler-version: Homebrew clang version 20.1.8\n";
    try std.testing.expectEqualStrings(expected, fbs.getWritten());
}

test "writeInspectReport prefers embedded artifact-class over derived" {
    var fields = baseInspectFields();
    fields.schema_version = "2";
    fields.artifact_class = "interpreter-free-aot";
    // Note: interpreter_linked=yes would normally derive to "interpreter",
    // but the embedded class overrides the derivation.

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeInspectReport(fbs.writer(), fields);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "artifact: interpreter-free-aot\n") != null);
}

test "writeInspectReport derives interpreter-free-aot when neither flag set" {
    var fields = baseInspectFields();
    fields.interpreter_linked = "no";
    fields.runtime_image_present = "no";

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeInspectReport(fbs.writer(), fields);
    try std.testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "artifact: interpreter-free-aot\n") != null);
}
