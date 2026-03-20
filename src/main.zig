const std = @import("std");
const File = std.fs.File;

const context = @import("context.zig");
const Context = context.Context;
const ErrorDetail = context.ErrorDetail;
const ParseDiagnostics = context.ParseDiagnostics;
const Quotation = @import("value.zig").Quotation;
const StatementProcessor = @import("statement.zig").StatementProcessor;
const formatter = @import("formatter.zig");
const benchmark = @import("benchmark.zig");
const debugger_mod = @import("debugger/mod.zig");
const pascalToKebabRuntime = @import("primitives/errors.zig").pascalToKebabRuntime;
const LineEditor = @import("line_editor.zig").LineEditor;
const BenchmarkStats = benchmark.BenchmarkStats;
const BenchmarkConfig = benchmark.BenchmarkConfig;
const CountingAllocator = benchmark.CountingAllocator;
const memory_limit = @import("memory_limit.zig");
const MemoryLimitAllocator = memory_limit.MemoryLimitAllocator;
const trace_mod = @import("trace.zig");
const call_graph = @import("call_graph.zig");
const effect_inference = @import("effect_inference.zig");

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
    const details = ctx.error_details.items;
    if (details.len > 0) {
        // Print first detail (innermost error location) in single-line format
        const detail = details[0];
        writer.print("{s}:{d}: error '{s}'", .{ detail.source, detail.line, detail.error_type }) catch return;

        // Print message if different from word name
        if (detail.word_name != null and !std.mem.eql(u8, detail.message, detail.word_name.?)) {
            writer.print(" {s}", .{detail.message}) catch return;
        }

        // Print word name
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

        // Print remaining call stack (caller chain)
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
        // Fallback if no details captured
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

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();

    // Use GPA for initial arg parsing
    const args = std.process.argsAlloc(gpa_allocator) catch return 1;
    defer std.process.argsFree(gpa_allocator, args);

    // Check for fmt subcommand first
    if (args.len > 1 and std.mem.eql(u8, args[1], "fmt")) {
        return handleFmt(gpa_allocator, args[2..]);
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
    ctx.compile_all = build_options.jit_all;
    ctx.check_mode = check_mode;
    ctx.allow_all_recursion = allow_all_recursion;
    if (bench_config.enabled) {
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
        std.Thread.spawn(.{}, testTimeoutWatchdog, .{test_timeout_ns.?}) catch null
    else
        null;
    defer if (watchdog_thread) |t| t.detach();

    // If a file path is provided, run in batch mode, which executes the file
    // and exits. Errors print to stderr, and cause a non-zero exit code.
    // Otherwise, interactive REPL starts.
    const result = if (file_path) |path|
        batch(&ctx, path, show_stack)
    else blk: {
        repl(&ctx, verbosity, max_memory_bytes);
        break :blk @as(u8, 0);
    };

    // Stop benchmark timer if enabled
    if (bench_config.enabled) {
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

fn testTimeoutWatchdog(timeout_ns: u64) void {
    std.Thread.sleep(timeout_ns);
    var tw = trace_mod.TraceWriter.init();
    const secs = @as(f64, @floatFromInt(timeout_ns)) /
        @as(f64, @floatFromInt(@as(u64, std.time.ns_per_s)));
    tw.print("TEST-TIMEOUT: {d:.1}s limit reached\n", .{secs});
    const scheduler_mod = @import("scheduler.zig");
    if (scheduler_mod.active_scheduler.load(.acquire)) |sched| {
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

fn repl(ctx: *Context, verbosity: Verbosity, max_memory_bytes: usize) void {
    ctx.setPragma("arity-mismatch", .{ .string = "warning" }) catch {};

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
                    printErrorDetails(ctx, writer, err);
                    had_error = true;
                };

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
    var processor: StatementProcessor = .{};
    defer processor.deinit();

    switch (processor.feedLine(ctx.quotationAllocator(), "use \"introspect\" ;", ctx)) {
        .complete => |instrs| {
            ctx.executeQuotation(.{ .instructions = instrs }) catch {};
            processor.reset();
        },
        .needs_more_input, .parse_error => {
            processor.reset();
        },
    }
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
                    printErrorDetails(ctx, writer, err);
                    had_error = true;
                };

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

        var engine = effect_inference.InferenceEngine.init(&ctx.dictionary, &ctx.dispatch, ctx.local_frames.items, ctx.quotationAllocator(), severity_override, suppressed, suppress_undeclared, &ctx.builtin_type_values, type_check_mode);
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
fn adjustInstructionLines(instrs: []const @import("value.zig").Instruction, line_offset: usize) void {
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
}
