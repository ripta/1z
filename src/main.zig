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
const debugger_mod = @import("debugger/mod.zig");
const pascalToKebabRuntime = @import("primitives/errors.zig").pascalToKebabRuntime;
const hooks = @import("primitives/hooks.zig");
const LineEditor = @import("line_editor.zig").LineEditor;
const BenchmarkStats = benchmark.BenchmarkStats;
const BenchmarkConfig = benchmark.BenchmarkConfig;
const CountingAllocator = benchmark.CountingAllocator;
const memory_limit = @import("memory_limit.zig");
const MemoryLimitAllocator = memory_limit.MemoryLimitAllocator;
const trace_mod = @import("trace.zig");
const call_graph = @import("call_graph.zig");
const effect_inference = @import("effect_inference.zig");
const aot_freeze = @import("aot_freeze.zig");
const ir_codegen = @import("ir_codegen.zig");

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

    switch (processor.feedLine(ctx.quotationAllocator(), statement, ctx)) {
        .complete => |instrs| {
            if (instrs.len > 0) {
                adjustInstructionLines(instrs, 1);
            }

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

fn printUsage() void {
    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writer(&stdout_buf);
    const w = &stdout.interface;

    w.writeAll(
        \\Usage: 1z [options] [file] [args...]
        \\       1z build <file.1z> [-o <output>] [options]
        \\       1z fmt [files...]
        \\
        \\General:
        \\  -h, --help              Show this help and exit
        \\  -q, --quiet             Suppress REPL banner
        \\  -qq, --silent           Suppress banner, prompts, stack, and goodbye
        \\  --show-stack            Print the stack after execution
        \\  --max-memory=SIZE       Set memory limit (e.g. 128M, 1G; default 256M)
        \\  --load-path=PATH        Add a module search path (repeatable)
        \\  --stdlib-path=PATH      Override standard library path
        \\  --prelude=PATH          Override prelude file path
        \\
        \\Debugging:
        \\  --debug                 Start in interactive debugger
        \\  --break=WORD            Set a breakpoint on WORD (implies --debug)
        \\  --check                 Run static analysis without executing
        \\  --allow-all-recursion   Suppress non-tail recursion warnings
        \\
        \\Tracing:
        \\  --trace-words[=PAT]     Trace word execution (optional pattern filter)
        \\  --trace-resolve[=PAT]   Trace word resolution (optional pattern filter)
        \\  --trace-modules         Trace module loading
        \\  --trace-jit             Trace JIT compilation
        \\  --dump-scope=WORD       Dump scope after loading WORD
        \\
        \\Scheduling:
        \\  --deadlock-detect[=SECS]  Enable deadlock detection (default 5s)
        \\  --test-timeout=SECS     Set test timeout in seconds
        \\
        \\Compilation:
        \\  --compile=MODE          Set compile mode: off, eager, hybrid
        \\
        \\Benchmarking:
        \\  -b, --benchmark         Enable benchmarking
        \\  --benchmark=verbose     Benchmark with human-readable output
        \\  --benchmark=json        Benchmark with JSON output
        \\
        \\Environment variables:
        \\  ONEZ_MAX_MEMORY         Default memory limit (overridden by --max-memory)
        \\  ONEZ_COMPILE            Default compile mode (overridden by --compile)
        \\  ONEZ_PRELUDE            Default prelude path (overridden by --prelude)
        \\
    ) catch {};
    w.flush() catch {};
}

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();

    // Use GPA for initial arg parsing
    const args = std.process.argsAlloc(gpa_allocator) catch return 1;
    defer std.process.argsFree(gpa_allocator, args);

    // Check for --help/-h before anything else
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return 0;
        }
    }

    // Check for subcommands first
    if (args.len > 1 and std.mem.eql(u8, args[1], "fmt")) {
        return handleFmt(gpa_allocator, args[2..]);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "build")) {
        return handleBuild(gpa_allocator, args[2..]);
    }

    // Parse flags
    var show_stack = false;
    var verbosity: Verbosity = .normal;
    var file_path: ?[]const u8 = null;
    var bench_config = BenchmarkConfig{};
    var max_memory_bytes: usize = 256 * 1024 * 1024;
    var cli_set_max_memory = false;

    var program_args: std.ArrayListUnmanaged([]const u8) = .{};
    defer program_args.deinit(gpa_allocator);

    var cli_load_paths: std.ArrayListUnmanaged([]const u8) = .{};
    defer cli_load_paths.deinit(gpa_allocator);

    var cli_stdlib_path: ?[]const u8 = null;
    var cli_prelude_path: ?[]const u8 = null;
    var debug_mode = false;
    var initial_breakpoints: [16][]const u8 = undefined;
    var initial_breakpoint_count: usize = 0;
    var trace_config = trace_mod.TraceConfig{};
    var deadlock_detect_ns: ?i128 = null;
    var test_timeout_ns: ?u64 = null;
    var check_mode = false;
    var allow_all_recursion = false;
    var compile_mode: context.CompileMode = .off;
    var cli_set_compile = false;

    // TODO(ripta): bit hacky arg parsing, improve later?
    for (args[1..]) |arg| {
        if (file_path != null) {
            program_args.append(gpa_allocator, arg) catch return 1;
        } else if (std.mem.eql(u8, arg, "--show-stack")) {
            show_stack = true;
        } else if (std.mem.eql(u8, arg, "-qq") or std.mem.eql(u8, arg, "--silent")) {
            verbosity = .silent;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            verbosity = .quiet;
        } else if (std.mem.eql(u8, arg, "--benchmark") or std.mem.eql(u8, arg, "-b")) {
            bench_config.enabled = true;
        } else if (std.mem.eql(u8, arg, "--benchmark=verbose")) {
            bench_config.enabled = true;
            bench_config.output = .human;
        } else if (std.mem.eql(u8, arg, "--benchmark=json")) {
            bench_config.enabled = true;
            bench_config.output = .json;
        } else if (std.mem.startsWith(u8, arg, "--max-memory=")) {
            const value = arg["--max-memory=".len..];
            if (memory_limit.parseSize(value)) |bytes| {
                max_memory_bytes = bytes;
                cli_set_max_memory = true;
            } else {
                const stderr_file: File = .stderr();
                var stderr_buf: [4096]u8 = undefined;
                var stderr = stderr_file.writer(&stderr_buf);
                stderr.interface.print("Error: invalid value for --max-memory: '{s}'\n", .{value}) catch {};
                stderr.interface.flush() catch {};
                return 1;
            }
        } else if (std.mem.startsWith(u8, arg, "--load-path=")) {
            const value = arg["--load-path=".len..];
            cli_load_paths.append(gpa_allocator, value) catch return 1;
        } else if (std.mem.startsWith(u8, arg, "--stdlib-path=")) {
            cli_stdlib_path = arg["--stdlib-path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--prelude=")) {
            cli_prelude_path = arg["--prelude=".len..];
        } else if (std.mem.eql(u8, arg, "--debug")) {
            debug_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--break=")) {
            debug_mode = true;
            const word = arg["--break=".len..];
            if (initial_breakpoint_count < 16) {
                initial_breakpoints[initial_breakpoint_count] = word;
                initial_breakpoint_count += 1;
            }
        } else if (std.mem.eql(u8, arg, "--trace-words")) {
            trace_config.trace_words = true;
        } else if (std.mem.startsWith(u8, arg, "--trace-words=")) {
            trace_config.trace_words = true;
            trace_config.trace_words_pattern = arg["--trace-words=".len..];
        } else if (std.mem.eql(u8, arg, "--trace-resolve")) {
            trace_config.trace_resolve = true;
        } else if (std.mem.startsWith(u8, arg, "--trace-resolve=")) {
            trace_config.trace_resolve = true;
            trace_config.trace_resolve_pattern = arg["--trace-resolve=".len..];
        } else if (std.mem.eql(u8, arg, "--trace-modules")) {
            trace_config.trace_modules = true;
        } else if (std.mem.eql(u8, arg, "--trace-jit")) {
            trace_config.trace_jit = true;
        } else if (std.mem.startsWith(u8, arg, "--dump-scope=")) {
            trace_config.dump_scope = arg["--dump-scope=".len..];
        } else if (std.mem.eql(u8, arg, "--deadlock-detect")) {
            deadlock_detect_ns = 5 * std.time.ns_per_s;
        } else if (std.mem.startsWith(u8, arg, "--deadlock-detect=")) {
            const value = arg["--deadlock-detect=".len..];
            const secs = std.fmt.parseInt(u64, value, 10) catch {
                const stderr_file: File = .stderr();
                var stderr_buf2: [4096]u8 = undefined;
                var stderr2 = stderr_file.writer(&stderr_buf2);
                stderr2.interface.print("Error: invalid value for --deadlock-detect: '{s}'\n", .{value}) catch {};
                stderr2.interface.flush() catch {};
                return 1;
            };
            deadlock_detect_ns = @as(i128, secs) * std.time.ns_per_s;
        } else if (std.mem.eql(u8, arg, "--test-timeout")) {
            const stderr_file: File = .stderr();
            var stderr_buf2: [4096]u8 = undefined;
            var stderr2 = stderr_file.writer(&stderr_buf2);
            stderr2.interface.print("Error: --test-timeout requires a value (e.g. --test-timeout=5)\n", .{}) catch {};
            stderr2.interface.flush() catch {};
            return 1;
        } else if (std.mem.startsWith(u8, arg, "--test-timeout=")) {
            const value = arg["--test-timeout=".len..];
            const secs = std.fmt.parseInt(u64, value, 10) catch {
                const stderr_file: File = .stderr();
                var stderr_buf2: [4096]u8 = undefined;
                var stderr2 = stderr_file.writer(&stderr_buf2);
                stderr2.interface.print("Error: invalid value for --test-timeout: '{s}'\n", .{value}) catch {};
                stderr2.interface.flush() catch {};
                return 1;
            };
            test_timeout_ns = secs * std.time.ns_per_s;
        } else if (std.mem.eql(u8, arg, "--check")) {
            check_mode = true;
        } else if (std.mem.eql(u8, arg, "--allow-all-recursion")) {
            allow_all_recursion = true;
        } else if (std.mem.startsWith(u8, arg, "--compile=")) {
            const value = arg["--compile=".len..];
            if (std.mem.eql(u8, value, "off")) {
                compile_mode = .off;
            } else if (std.mem.eql(u8, value, "eager")) {
                compile_mode = .eager;
            } else if (std.mem.eql(u8, value, "hybrid")) {
                compile_mode = .hybrid;
            } else {
                const stderr_file: File = .stderr();
                var stderr_buf: [4096]u8 = undefined;
                var stderr = stderr_file.writer(&stderr_buf);
                stderr.interface.print("Error: invalid value for --compile: '{s}' (expected 'off', 'eager', or 'hybrid')\n", .{value}) catch {};
                stderr.interface.flush() catch {};
                return 1;
            }
            cli_set_compile = true;
        } else {
            file_path = arg;
        }
    }

    // Check environment variable if CLI flag was not set
    if (!cli_set_max_memory) {
        if (std.posix.getenv("ONEZ_MAX_MEMORY")) |env_val| {
            if (memory_limit.parseSize(env_val)) |bytes| {
                max_memory_bytes = bytes;
            }
            // Silently ignore invalid env var values
        }
    }

    if (!cli_set_compile) {
        if (std.posix.getenv("ONEZ_COMPILE")) |env_val| {
            if (std.mem.eql(u8, env_val, "off")) {
                compile_mode = .off;
            } else if (std.mem.eql(u8, env_val, "eager")) {
                compile_mode = .eager;
            } else if (std.mem.eql(u8, env_val, "hybrid")) {
                compile_mode = .hybrid;
            }
            // Silently ignore invalid env var values
        }
    }

    // Create memory limit allocator (wraps GPA, enforces cap)
    var mem_limit = MemoryLimitAllocator.init(gpa_allocator, max_memory_bytes);
    const mem_limit_allocator = mem_limit.allocator();

    // Create benchmark stats and counting allocator if benchmarking enabled
    var bench_stats = BenchmarkStats{};
    var counting_allocator = CountingAllocator.init(mem_limit_allocator, &bench_stats);

    // Use counting allocator when benchmarking, memory limit allocator otherwise
    const allocator = if (bench_config.enabled) counting_allocator.allocator() else mem_limit_allocator;

    if (bench_config.enabled) {
        bench_stats.start();
    }

    // Initialize context with the program arguments
    var ctx = Context.init(allocator);
    ctx.program_args = program_args.items;
    ctx.trace = trace_config;
    ctx.deadlock_detect_ns = deadlock_detect_ns;
    defer ctx.deinit();

    // Configure load paths: CLI flags, then env var
    for (cli_load_paths.items) |lp| {
        const duped = ctx.quotationAllocator().dupe(u8, lp) catch return 1;
        ctx.load_paths.append(ctx.allocator, duped) catch return 1;
    }
    if (std.posix.getenv("ONEZ_LOAD_PATH")) |env_val| {
        var it = std.mem.splitScalar(u8, env_val, ':');
        while (it.next()) |segment| {
            if (segment.len > 0) {
                const duped = ctx.quotationAllocator().dupe(u8, segment) catch return 1;
                ctx.load_paths.append(ctx.allocator, duped) catch return 1;
            }
        }
    }

    // Configure stdlib path: CLI flag, then env var, then default relative to binary
    if (cli_stdlib_path) |sp| {
        ctx.stdlib_path = ctx.quotationAllocator().dupe(u8, sp) catch return 1;
    } else if (std.posix.getenv("ONEZ_STDLIB")) |env_val| {
        ctx.stdlib_path = ctx.quotationAllocator().dupe(u8, env_val) catch return 1;
    } else {
        // TODO(ripta): more robust way to find default stdlib path?
        //              Defaults to <bin_dir>/../lib
        var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fs.selfExeDirPath(&self_exe_buf)) |exe_dir| {
            const default_lib = std.fs.path.join(ctx.quotationAllocator(), &.{ exe_dir, "../lib" }) catch null;
            if (default_lib) |lib_path| {
                var real_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (std.fs.cwd().realpath(lib_path, &real_buf)) |real| {
                    ctx.stdlib_path = ctx.quotationAllocator().dupe(u8, real) catch null;
                } else |_| {}
            }
        } else |_| {}
    }

    if (bench_config.enabled) {
        ctx.benchmark = &bench_stats;
    }

    // Resolve prelude source: CLI flag, then env var, and lastly the embedded default
    const prelude_path = cli_prelude_path orelse std.posix.getenv("ONEZ_PRELUDE");
    var external_prelude: ?[]const u8 = null;
    if (prelude_path) |path| {
        external_prelude = std.fs.cwd().readFileAlloc(gpa_allocator, path, 10 * 1024 * 1024) catch |err| {
            const stderr_file: File = .stderr();
            var stderr_buf: [4096]u8 = undefined;
            var stderr = stderr_file.writer(&stderr_buf);
            stderr.interface.print("Error: cannot read prelude '{s}': {any}\n", .{ path, err }) catch {};
            stderr.interface.flush() catch {};
            return 1;
        };
    }
    defer if (external_prelude) |ep| gpa_allocator.free(ep);

    ctx.loadPrelude(external_prelude) catch |err| {
        std.debug.panic("Failed to load prelude: {any}", .{err});
    };
    ctx.compile_mode = compile_mode;
    ctx.check_mode = check_mode;
    ctx.allow_all_recursion = allow_all_recursion;
    if (bench_config.enabled) {
        bench_stats.collectPreludeInventory(
            if (ctx.local_frames.items.len > 0) ctx.local_frames.items[0].count() else 0,
            ctx.dispatch.entries.count(),
            ctx.dispatch.native_entries.count(),
            ctx.builtin_type_values.count(),
            if (ctx.type_registry_frames.items.len > 0) ctx.type_registry_frames.items[0].enum_registry.count() else 0,
            ctx.pragma_registry.count(),
            ctx.virtual_type_count,
            ctx.struct_type_count,
        );
        bench_stats.markPreludeEnd();
    }

    var dbg: ?debugger_mod.Debugger = if (debug_mode) debugger_mod.Debugger.init(allocator) else null;
    defer if (dbg != null) dbg.?.deinit();

    if (dbg != null) {
        ctx.debugger = &dbg.?;
        for (initial_breakpoints[0..initial_breakpoint_count]) |bp| {
            _ = dbg.?.breakpoints.addWord(bp);
        }
        if (initial_breakpoint_count > 0) {
            // Start in continue mode so execution runs until a breakpoint hits
            dbg.?.stepper.mode = .continue_running;
        }
    }

    // Spawn watchdog thread for --test-timeout (batch mode only)
    const watchdog_thread: ?std.Thread = if (test_timeout_ns != null and file_path != null)
        std.Thread.spawn(.{}, testTimeoutWatchdog, .{ test_timeout_ns.?, &ctx }) catch null
    else
        null;
    defer if (watchdog_thread) |t| t.detach();

    signal.install();

    // If a file path is provided, run in batch mode, which executes the file
    // and exits. Errors print to stderr, and cause a non-zero exit code.
    // Otherwise, interactive REPL starts.
    const result = if (file_path) |path|
        batch(&ctx, path, show_stack)
    else blk: {
        repl(&ctx, verbosity, max_memory_bytes);
        break :blk @as(u8, 0);
    };

    hooks.fireHooks(&ctx, "on:exit", &.{.{ .fixnum = @intCast(result) }});

    // Stop benchmark timer if enabled
    if (bench_config.enabled) {
        bench_stats.collectVariantHistogram(allocator, ctx.stack.items.items) catch {};
        bench_stats.stop();
    }

    defer if (bench_config.enabled) bench_stats.deinit(allocator);

    if (bench_config.output != .none) {
        var buf: [8192]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();

        switch (bench_config.output) {
            .human => bench_stats.formatHuman(writer) catch {},
            .json => bench_stats.formatJson(writer) catch {},
            .none => {},
        }

        const data = stream.getWritten();
        var written: usize = 0;
        while (written < data.len) {
            written += std.posix.write(std.posix.STDOUT_FILENO, data[written..]) catch break;
        }
    }

    return result;
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

fn handleFmt(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writer(&stderr_buf);
    const err_writer = &stderr.interface;

    var check_only = false;
    var stdout_mode = false;
    var paths: std.ArrayListUnmanaged([]const u8) = .{};
    defer paths.deinit(allocator);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check_only = true;
        } else if (std.mem.eql(u8, arg, "--stdout")) {
            stdout_mode = true;
        } else {
            paths.append(allocator, arg) catch {
                err_writer.writeAll("Error: out of memory\n") catch {};
                err_writer.flush() catch {};
                return 1;
            };
        }
    }

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
        var stdout = stdout_file.writer(&stdout_buf);
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

fn handleBuild(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const stderr_file: File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writer(&stderr_buf);
    const err_writer = &stderr.interface;

    // Parse build-specific args.
    var source_file: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var cli_stdlib_path: ?[]const u8 = null;
    var cli_prelude_path: ?[]const u8 = null;
    var cli_load_paths: std.ArrayListUnmanaged([]const u8) = .{};
    defer cli_load_paths.deinit(allocator);

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
        } else if (std.mem.startsWith(u8, arg, "--stdlib-path=")) {
            cli_stdlib_path = arg["--stdlib-path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--prelude=")) {
            cli_prelude_path = arg["--prelude=".len..];
        } else if (std.mem.startsWith(u8, arg, "--load-path=")) {
            cli_load_paths.append(allocator, arg["--load-path=".len..]) catch {
                err_writer.writeAll("Error: out of memory\n") catch {};
                err_writer.flush() catch {};
                return 1;
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            err_writer.print("Error: unknown flag '{s}'\n", .{arg}) catch {};
            err_writer.flush() catch {};
            return 1;
        } else {
            if (source_file != null) {
                err_writer.writeAll("Error: multiple source files not supported\n") catch {};
                err_writer.flush() catch {};
                return 1;
            }
            source_file = arg;
        }
    }

    const source = source_file orelse {
        err_writer.writeAll("Usage: 1z build <file.1z> [-o <output>]\n") catch {};
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
        if (cli_stdlib_path) |sp| {
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
        if (cli_stdlib_path) |sp| {
            ctx.stdlib_path = sp;
        }
    }

    for (cli_load_paths.items) |lp| {
        const duped = ctx.quotationAllocator().dupe(u8, lp) catch continue;
        ctx.load_paths.append(allocator, duped) catch continue;
    }

    ctx.loadPrelude(cli_prelude_path) catch |err| {
        err_writer.print("Error loading prelude: {s}\n", .{@errorName(err)}) catch {};
        err_writer.flush() catch {};
        return 1;
    };

    // Stage 1: Freeze module graph and emit C source.
    var freeze_diagnostics: aot_freeze.FreezeDiagnostics = .{};
    var freeze_result = aot_freeze.freezeModuleGraph(ctx, source, &freeze_diagnostics, allocator) catch |err| {
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
    const c_source = ir_codegen.emitProgramC(
        freeze_result.words,
        freeze_result.entry_word_id,
        freeze_result.max_word_id,
        &codegen_diagnostics,
        allocator,
    ) catch |err| {
        if (err == error.UncompiledWords) {
            for (codegen_diagnostics.uncompiled_words) |name| {
                err_writer.print(
                    "Error: word '{s}' could not be compiled to C\n",
                    .{name},
                ) catch {};
            }
            allocator.free(codegen_diagnostics.uncompiled_words);
        } else {
            err_writer.print("Error generating C source: {s}\n", .{@errorName(err)}) catch {};
        }
        err_writer.flush() catch {};
        return 1;
    };
    defer allocator.free(c_source);

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
    std.fs.cwd().deleteFile(tmp_path) catch {};

    return 0;
}

fn repl(ctx: *Context, verbosity: Verbosity, max_memory_bytes: usize) void {
    ctx.setPragma("redefinition-arity-mismatch", .{ .string = "warning" }) catch {};

    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writer(&stdout_buf);
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

                if (instrs.len > 0) {
                    adjustInstructionLines(instrs, processor.start_line);
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
    var stderr = stderr_file.writer(&stderr_buf);
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
                if (instrs.len > 0) {
                    adjustInstructionLines(instrs, processor.start_line);
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
    var stderr = stderr_file.writer(&stderr_buf);
    const err_writer = &stderr.interface;

    // For --show-stack, prepare stdout writer
    const stdout_file: File = .stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writer(&stdout_buf);
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
                            adjustInstructionLines(instrs, processor.start_line);
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
                    adjustInstructionLines(instrs, processor.start_line);
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

        var severity_override: ?effect_inference.Severity = null;
        var suppressed = false;
        if (ctx.getPragma("suppress-checks")) |pragma_val| {
            switch (pragma_val) {
                .string => |s| {
                    if (std.mem.eql(u8, s, "warn-only")) {
                        severity_override = .warning;
                    } else if (std.mem.eql(u8, s, "all")) {
                        suppressed = true;
                    }
                },
                else => {},
            }
        }

        var suppress_undeclared = false;
        if (ctx.getPragma("suppress-undeclared")) |pragma_val| {
            switch (pragma_val) {
                .boolean => |b| {
                    suppress_undeclared = b;
                },
                else => {},
            }
        }

        var type_check_mode: effect_inference.InferenceEngine.TypeCheckMode = .err;
        if (ctx.getPragma("type-check")) |pragma_val| {
            switch (pragma_val) {
                .string => |s| {
                    if (std.mem.eql(u8, s, "off")) {
                        type_check_mode = .off;
                    } else if (std.mem.eql(u8, s, "warning")) {
                        type_check_mode = .warning;
                    }
                },
                else => {},
            }
        }

        var arity_check_mode: effect_inference.InferenceEngine.ArityCheckMode = .err;
        if (ctx.getPragma("callsite-arity-mismatch")) |pragma_val| {
            switch (pragma_val) {
                .string => |s| {
                    if (std.mem.eql(u8, s, "off")) {
                        arity_check_mode = .off;
                    } else if (std.mem.eql(u8, s, "warning")) {
                        arity_check_mode = .warning;
                    }
                },
                else => {},
            }
        }

        var engine = effect_inference.InferenceEngine.init(&ctx.dictionary, &ctx.dispatch, ctx.local_frames.items, ctx.quotationAllocator(), severity_override, suppressed, suppress_undeclared, &ctx.builtin_type_values, type_check_mode, arity_check_mode);
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

/// Adjust line numbers in instructions by adding an offset.
fn adjustInstructionLines(instrs: []const Instruction, line_offset: usize) void {
    if (line_offset == 0) return;
    for (instrs) |*instr| {
        const ptr = @constCast(instr);
        ptr.line += line_offset - 1; // -1 because tokenizer starts at line 1
        // Recursively adjust nested quotations
        switch (instr.op) {
            .push_literal => |val| {
                switch (val) {
                    .quotation => |nested| adjustInstructionLines(nested.instructions, line_offset),
                    else => {},
                }
            },
            else => {},
        }
    }
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
