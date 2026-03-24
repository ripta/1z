const std = @import("std");
const version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addCSourceFile(.{ .file = b.path("ext/toy/toy.c"), .flags = &.{} });
    root_module.addIncludePath(b.path("ext/toy"));
    root_module.linkSystemLibrary("ffi", .{});
    addFfiIncludePath(b, root_module, target);
    addIrSources(b, root_module);

    // Set version as a build option
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    root_module.addOptions("build_options", options);

    // zig-out/bin/1z
    const exe = b.addExecutable(.{
        .name = "1z",
        .root_module = root_module,
    });
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    // zig-out/bin/1z-lsp
    const lsp_module = b.createModule(.{
        .root_source_file = b.path("src/lsp_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lsp_module.addCSourceFile(.{ .file = b.path("ext/toy/toy.c"), .flags = &.{} });
    lsp_module.addIncludePath(b.path("ext/toy"));
    lsp_module.linkSystemLibrary("ffi", .{});
    addIrSources(b, lsp_module);
    lsp_module.addOptions("build_options", options);

    const lsp_exe = b.addExecutable(.{
        .name = "1z-lsp",
        .root_module = lsp_module,
    });
    const install_lsp = b.addInstallArtifact(lsp_exe, .{});
    b.getInstallStep().dependOn(&install_lsp.step);

    // zig-out/clib/lib1z.a (static library)
    // Installed to clib/ instead of lib/ because zig-out/lib is symlinked
    // to the stdlib directory.
    const capi_static_module = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    capi_static_module.addCSourceFile(.{ .file = b.path("ext/toy/toy.c"), .flags = &.{} });
    capi_static_module.addIncludePath(b.path("ext/toy"));
    capi_static_module.linkSystemLibrary("ffi", .{});
    addIrSources(b, capi_static_module);
    capi_static_module.addOptions("build_options", options);

    const static_lib = b.addLibrary(.{
        .name = "1z",
        .root_module = capi_static_module,
        .linkage = .static,
    });
    const install_static = b.addInstallArtifact(static_lib, .{
        .dest_dir = .{ .override = .{ .custom = "clib" } },
    });
    b.getInstallStep().dependOn(&install_static.step);

    // zig-out/clib/lib1z.dylib (shared library)
    const capi_shared_module = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    capi_shared_module.addCSourceFile(.{ .file = b.path("ext/toy/toy.c"), .flags = &.{} });
    capi_shared_module.addIncludePath(b.path("ext/toy"));
    capi_shared_module.linkSystemLibrary("ffi", .{});
    addIrSources(b, capi_shared_module);
    capi_shared_module.addOptions("build_options", options);

    const shared_lib = b.addLibrary(.{
        .name = "1z",
        .root_module = capi_shared_module,
        .linkage = .dynamic,
    });
    const install_shared = b.addInstallArtifact(shared_lib, .{
        .dest_dir = .{ .override = .{ .custom = "clib" } },
    });
    b.getInstallStep().dependOn(&install_shared.step);

    // zig-out/lib -> lib/
    //
    // TODO(ripta): A bit hacky, but otherwise the stdlib path has to be
    //              specified manually on every invocation.
    const symlink_step = b.addSystemCommand(&.{ "ln", "-sfn" });
    symlink_step.addDirectoryArg(b.path("lib"));
    symlink_step.addArg(b.fmt("{s}/lib", .{b.install_path}));
    symlink_step.step.dependOn(&install_exe.step);
    b.getInstallStep().dependOn(&symlink_step.step);

    // zig-out/docs
    const docs = b.addInstallDirectory(.{
        .source_dir = exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Install documentation");
    docs_step.dependOn(&docs.step);

    // zig build run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the 1z interpreter");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addCSourceFile(.{ .file = b.path("ext/toy/toy.c"), .flags = &.{} });
    test_module.addIncludePath(b.path("ext/toy"));
    test_module.linkSystemLibrary("ffi", .{});
    addFfiIncludePath(b, test_module, target);
    addIrSources(b, test_module);
    test_module.addOptions("build_options", options);

    const lib_unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Shared library build for dynamic FFI tests
    const toy_shared_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    toy_shared_module.addCSourceFile(.{ .file = b.path("ext/toy/toy.c"), .flags = &.{} });
    toy_shared_module.addIncludePath(b.path("ext/toy"));
    const toy_shared = b.addLibrary(.{
        .name = "toy",
        .root_module = toy_shared_module,
        .linkage = .dynamic,
    });
    const install_toy_shared = b.addInstallArtifact(toy_shared, .{
        .dest_dir = .{ .override = .{ .custom = "ext" } },
    });

    const has_diff: bool = (b.findProgram(&.{"diff"}, &.{}) catch null) != null;

    // Open the test directory once for both integration test steps
    var test_dir = b.build_root.handle.openDir("tests/integration", .{ .iterate = true }) catch |err| {
        std.debug.print("Warning: Could not open tests/integration: {}\n", .{err});
        return;
    };
    defer test_dir.close();

    // Collect test metadata so we can iterate it multiple times
    const test_entries = collectTestEntries(b, &test_dir) catch return;

    // Integration tests
    const integration_test_step = b.step("integration-test", "Run integration tests");
    integration_test_step.dependOn(&run_lib_unit_tests.step);
    integration_test_step.dependOn(&install_toy_shared.step);

    // Update golden files step
    const update_golden_step = b.step("update-golden", "Update golden files for integration tests");
    var update_files = b.addUpdateSourceFiles();

    addIntegrationTests(b, exe, integration_test_step, &update_files, test_entries, has_diff, false);

    update_golden_step.dependOn(&update_files.step);

    // XXX(ripta): icky hack to validate that no golden files contain "FAIL", since
    //             I seem to keep missing them when reviewing test diffs.
    const validate_golden = b.addSystemCommand(&.{
        "sh", "-c",
        \\if grep -l 'FAIL' tests/integration/*.stdout.golden 2>/dev/null; then
        \\  echo ""
        \\  echo "ERROR: Golden files contain FAIL - fix the failing tests before updating golden files"
        \\  exit 1
        \\fi
    });
    validate_golden.step.dependOn(&update_files.step);
    update_golden_step.dependOn(&validate_golden.step);

    // Eager compilation integration tests: same exe with --compile=eager
    const eager_test_step = b.step("eager-integration-test", "Run integration tests with eager compilation");
    eager_test_step.dependOn(&install_exe.step);
    eager_test_step.dependOn(&install_toy_shared.step);

    addIntegrationTests(b, exe, eager_test_step, null, test_entries, has_diff, true);

    // Formatter tests
    const fmt_test_step = b.step("fmt-test", "Run formatter tests");
    const update_fmt_golden_step = b.step("update-fmt-golden", "Update golden files for formatter tests");
    var update_fmt_files = b.addUpdateSourceFiles();

    // Dynamically discover and run all .txt files in tests/formatting/
    var fmt_test_dir = b.build_root.handle.openDir("tests/formatting", .{ .iterate = true }) catch |err| {
        std.debug.print("Warning: Could not open tests/formatting: {}\n", .{err});
        return;
    };
    defer fmt_test_dir.close();

    var fmt_iter = fmt_test_dir.iterate();
    while (fmt_iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;

        const name_without_ext = entry.name[0 .. entry.name.len - 4];
        const input_path = b.fmt("tests/formatting/{s}", .{entry.name});
        const golden_path = b.fmt("tests/formatting/{s}.golden", .{name_without_ext});

        // Formatter test: run formatter and compare against golden file
        const fmt_run = b.addRunArtifact(exe);
        fmt_run.addArg("fmt");
        fmt_run.addArg("--stdout");
        fmt_run.addFileArg(b.path(input_path));

        // Try to read golden file for comparison
        var has_fmt_golden = false;
        var fmt_golden_content: []const u8 = "";
        if (fmt_test_dir.openFile(b.fmt("{s}.golden", .{name_without_ext}), .{})) |file| {
            defer file.close();
            fmt_golden_content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            has_fmt_golden = true;
            fmt_run.addFileInput(b.path(golden_path));
        } else |_| {
            std.debug.print("Warning: No golden file for {s}\n", .{entry.name});
        }

        fmt_run.expectStdErrEqual("");
        fmt_run.expectExitCode(0);

        if (has_diff and has_fmt_golden) {
            const captured_fmt_stdout = fmt_run.captureStdOut();
            const fmt_diff = b.addSystemCommand(&.{
                "sh", "-c",
                b.fmt(
                    "diff -u -L 'expected: {s}' -L 'actual: {s}' -- \"$1\" \"$2\" >&2",
                    .{ golden_path, input_path },
                ),
                "sh",
            });
            fmt_diff.addFileArg(b.path(golden_path));
            fmt_diff.addFileArg(captured_fmt_stdout);
            fmt_test_step.dependOn(&fmt_diff.step);
        } else {
            if (has_fmt_golden) {
                fmt_run.expectStdOutEqual(fmt_golden_content);
            }
            fmt_test_step.dependOn(&fmt_run.step);
        }

        // Update golden: capture stdout and write to .golden file
        const update_fmt_run = b.addRunArtifact(exe);
        update_fmt_run.addArg("fmt");
        update_fmt_run.addArg("--stdout");
        update_fmt_run.addFileArg(b.path(input_path));
        update_fmt_files.addCopyFileToSource(update_fmt_run.captureStdOut(), golden_path);
    }

    update_fmt_golden_step.dependOn(&update_fmt_files.step);
}

fn addFfiIncludePath(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    // @cInclude("ffi.h") needs an extra include path on macOS where the
    // SDK places ffi.h under <sysroot>/usr/include/ffi/.  On Linux the
    // header is already in the default multiarch search path.
    if (target.result.os.tag.isDarwin()) {
        if (std.zig.system.darwin.getSdk(b.allocator, &target.result)) |sdk| {
            module.addSystemIncludePath(.{
                .cwd_relative = b.fmt("{s}/usr/include/ffi", .{sdk}),
            });
        }
    }
}

const TestEntry = struct {
    name_without_ext: []const u8,
    file_path: []const u8,
    stdout_golden_path: []const u8,
    stdin_path: []const u8,
    has_stdin: bool,
    stdin_content: []const u8,
    flags_path: []const u8,
    flags_lines: ?[]const u8,
    has_flags: bool,
    exitcode_path: []const u8,
    has_exitcode: bool,
    expected_exit_code: ?u8,
    env_path: []const u8,
    has_env: bool,
    env_lines: ?[]const u8,
    show_stack: bool,
    has_stderr_golden: bool,
    stderr_golden_path: []const u8,
    stderr_content: []const u8,
    has_stdout_golden: bool,
    stdout_content: []const u8,
};

fn collectTestEntries(b: *std.Build, test_dir: *std.fs.Dir) ![]const TestEntry {
    var entries: std.ArrayListUnmanaged(TestEntry) = .{};

    var iter = test_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".1z")) continue;

        const name_without_ext = entry.name[0 .. entry.name.len - 3];
        const file_path = b.fmt("tests/integration/{s}", .{entry.name});
        const stdout_golden_path = b.fmt("tests/integration/{s}.stdout.golden", .{name_without_ext});

        const stdin_path = b.fmt("tests/integration/{s}.stdin", .{name_without_ext});
        var has_stdin = false;
        var stdin_content: []const u8 = "";
        if (test_dir.openFile(b.fmt("{s}.stdin", .{name_without_ext}), .{})) |file| {
            defer file.close();
            stdin_content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            if (stdin_content.len > 0) {
                has_stdin = true;
            }
        } else |_| {}

        const flags_path = b.fmt("tests/integration/{s}.flags", .{name_without_ext});
        var flags_lines: ?[]const u8 = null;
        var has_flags = false;
        if (test_dir.openFile(b.fmt("{s}.flags", .{name_without_ext}), .{})) |file| {
            defer file.close();
            flags_lines = file.readToEndAlloc(b.allocator, 1024 * 1024) catch null;
            has_flags = true;
        } else |_| {}

        const exitcode_path = b.fmt("tests/integration/{s}.exitcode", .{name_without_ext});
        var has_exitcode = false;
        var expected_exit_code: ?u8 = null;
        if (test_dir.openFile(b.fmt("{s}.exitcode", .{name_without_ext}), .{})) |file| {
            defer file.close();
            has_exitcode = true;
            const code_str = file.readToEndAlloc(b.allocator, 64) catch "";
            const trimmed_code = std.mem.trim(u8, code_str, " \t\r\n");
            if (trimmed_code.len > 0) {
                expected_exit_code = std.fmt.parseInt(u8, trimmed_code, 10) catch null;
            }
        } else |_| {}

        const env_path = b.fmt("tests/integration/{s}.env", .{name_without_ext});
        var has_env = false;
        var env_lines: ?[]const u8 = null;
        if (test_dir.openFile(b.fmt("{s}.env", .{name_without_ext}), .{})) |file| {
            defer file.close();
            env_lines = file.readToEndAlloc(b.allocator, 1024 * 1024) catch null;
            has_env = true;
        } else |_| {}

        var show_stack = true;
        if (flags_lines) |fl| {
            var flag_check = std.mem.splitScalar(u8, fl, '\n');
            while (flag_check.next()) |flag| {
                const trimmed = std.mem.trim(u8, flag, " \t\r");
                if (std.mem.eql(u8, trimmed, "--no-show-stack")) {
                    show_stack = false;
                }
            }
        }

        var has_stderr_golden = false;
        const stderr_golden_name = b.fmt("{s}.stderr.golden", .{name_without_ext});
        const stderr_golden_path = b.fmt("tests/integration/{s}", .{stderr_golden_name});
        var stderr_content: []const u8 = "";
        if (test_dir.openFile(stderr_golden_name, .{})) |file| {
            defer file.close();
            stderr_content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            has_stderr_golden = true;
        } else |_| {}

        var has_stdout_golden = false;
        var stdout_content: []const u8 = "";
        if (test_dir.openFile(b.fmt("{s}.stdout.golden", .{name_without_ext}), .{})) |file| {
            defer file.close();
            stdout_content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            has_stdout_golden = true;
        } else |_| {}

        entries.append(b.allocator, .{
            .name_without_ext = name_without_ext,
            .file_path = file_path,
            .stdout_golden_path = stdout_golden_path,
            .stdin_path = stdin_path,
            .has_stdin = has_stdin,
            .stdin_content = stdin_content,
            .flags_path = flags_path,
            .flags_lines = flags_lines,
            .has_flags = has_flags,
            .exitcode_path = exitcode_path,
            .has_exitcode = has_exitcode,
            .expected_exit_code = expected_exit_code,
            .env_path = env_path,
            .has_env = has_env,
            .env_lines = env_lines,
            .show_stack = show_stack,
            .has_stderr_golden = has_stderr_golden,
            .stderr_golden_path = stderr_golden_path,
            .stderr_content = stderr_content,
            .has_stdout_golden = has_stdout_golden,
            .stdout_content = stdout_content,
        }) catch return error.OutOfMemory;
    }

    return entries.items;
}

fn hasExcludedJitFlag(flags_lines: ?[]const u8) bool {
    const fl = flags_lines orelse return false;
    var flag_iter = std.mem.splitScalar(u8, fl, '\n');
    while (flag_iter.next()) |flag| {
        const trimmed = std.mem.trim(u8, flag, " \t\r");
        if (std.mem.eql(u8, trimmed, "--check") or
            std.mem.eql(u8, trimmed, "--debug") or
            std.mem.eql(u8, trimmed, "--no-jit") or
            std.mem.startsWith(u8, trimmed, "--trace-") or
            std.mem.startsWith(u8, trimmed, "--break=") or
            std.mem.startsWith(u8, trimmed, "--dump-scope="))
        {
            return true;
        }
    }
    return false;
}

fn addIntegrationTests(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    test_step: *std.Build.Step,
    update_files: ?**std.Build.Step.UpdateSourceFiles,
    test_entries: []const TestEntry,
    has_diff: bool,
    jit_mode: bool,
) void {
    for (test_entries) |te| {
        if (jit_mode and hasExcludedJitFlag(te.flags_lines)) continue;

        const test_run = b.addRunArtifact(artifact);
        if (te.show_stack) {
            test_run.addArg("--show-stack");
        }
        test_run.addArg(b.fmt("--stdlib-path={s}/lib", .{b.build_root.path orelse "."}));
        if (jit_mode) {
            test_run.addArg("--compile=eager");
        }
        if (te.flags_lines) |fl| {
            var flag_iter = std.mem.splitScalar(u8, fl, '\n');
            while (flag_iter.next()) |flag| {
                const trimmed_flag = std.mem.trim(u8, flag, " \t\r");
                if (trimmed_flag.len > 0 and !std.mem.eql(u8, trimmed_flag, "--no-show-stack") and !std.mem.eql(u8, trimmed_flag, "--no-jit")) {
                    test_run.addArg(trimmed_flag);
                }
            }
        }
        if (te.env_lines) |el| {
            var env_iter = std.mem.splitScalar(u8, el, '\n');
            while (env_iter.next()) |line| {
                const trimmed_line = std.mem.trim(u8, line, " \t\r");
                if (trimmed_line.len == 0) continue;
                if (std.mem.indexOfScalar(u8, trimmed_line, '=')) |eq_pos| {
                    const key = trimmed_line[0..eq_pos];
                    const value = trimmed_line[eq_pos + 1 ..];
                    test_run.setEnvironmentVariable(key, value);
                }
            }
        }
        test_run.addFileArg(b.path(te.file_path));
        if (te.has_stdin) {
            test_run.setStdIn(.{ .bytes = te.stdin_content });
        }

        // Library file dependencies (recursive)
        {
            var lib_dir = b.build_root.handle.openDir("lib", .{ .iterate = true }) catch |err| {
                std.debug.print("Warning: Could not open lib/: {}\n", .{err});
                return;
            };
            defer lib_dir.close();
            var walker = lib_dir.walk(b.allocator) catch |err| {
                std.debug.print("Warning: Could not walk lib/: {}\n", .{err});
                return;
            };
            defer walker.deinit();
            while (walker.next() catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.path, ".1z")) continue;
                test_run.addFileInput(b.path(b.fmt("lib/{s}", .{entry.path})));
            }
        }
        test_run.addFileInput(b.path("src/prelude.1z"));
        if (te.has_stdin) test_run.addFileInput(b.path(te.stdin_path));
        if (te.has_flags) test_run.addFileInput(b.path(te.flags_path));
        if (te.has_exitcode) test_run.addFileInput(b.path(te.exitcode_path));
        if (te.has_env) test_run.addFileInput(b.path(te.env_path));

        if (te.has_stderr_golden) {
            test_run.addFileInput(b.path(te.stderr_golden_path));
        }
        if (te.has_stdout_golden) {
            test_run.addFileInput(b.path(te.stdout_golden_path));
        }

        test_run.expectExitCode(te.expected_exit_code orelse if (te.has_stderr_golden) 1 else 0);

        if (has_diff) {
            const captured_stdout = test_run.captureStdOut();
            const stdout_diff = b.addSystemCommand(&.{
                "sh", "-c",
                b.fmt(
                    "diff -u -L 'expected: {s}' -L 'actual: {s}' -- \"$1\" \"$2\" >&2",
                    .{ if (te.has_stdout_golden) te.stdout_golden_path else "(empty)", te.file_path },
                ),
                "sh",
            });
            if (te.has_stdout_golden) {
                stdout_diff.addFileArg(b.path(te.stdout_golden_path));
            } else {
                stdout_diff.addArg("/dev/null");
            }
            stdout_diff.addFileArg(captured_stdout);

            const captured_stderr = test_run.captureStdErr();
            const stderr_diff = b.addSystemCommand(&.{
                "sh", "-c",
                b.fmt(
                    "diff -u -L 'expected: {s}' -L 'actual: {s}' -- \"$1\" \"$2\" >&2",
                    .{ if (te.has_stderr_golden) te.stderr_golden_path else "(empty)", te.file_path },
                ),
                "sh",
            });
            if (te.has_stderr_golden) {
                stderr_diff.addFileArg(b.path(te.stderr_golden_path));
            } else {
                stderr_diff.addArg("/dev/null");
            }
            stderr_diff.addFileArg(captured_stderr);

            test_step.dependOn(&stdout_diff.step);
            test_step.dependOn(&stderr_diff.step);
        } else {
            if (te.has_stdout_golden) {
                test_run.expectStdOutEqual(te.stdout_content);
            } else {
                test_run.expectStdOutEqual("");
            }
            if (te.has_stderr_golden) {
                test_run.expectStdErrEqual(te.stderr_content);
            } else {
                test_run.expectStdErrEqual("");
            }
            test_step.dependOn(&test_run.step);
        }

        // Update golden (only for non-JIT mode)
        if (update_files) |uf_ptr| {
            const update_run = b.addRunArtifact(artifact);
            if (te.show_stack) {
                update_run.addArg("--show-stack");
            }
            update_run.addArg(b.fmt("--stdlib-path={s}/lib", .{b.build_root.path orelse "."}));
            if (te.flags_lines) |fl| {
                var flag_iter2 = std.mem.splitScalar(u8, fl, '\n');
                while (flag_iter2.next()) |flag| {
                    const trimmed_flag = std.mem.trim(u8, flag, " \t\r");
                    if (trimmed_flag.len > 0 and !std.mem.eql(u8, trimmed_flag, "--no-show-stack") and !std.mem.eql(u8, trimmed_flag, "--no-jit")) {
                        update_run.addArg(trimmed_flag);
                    }
                }
            }
            if (te.env_lines) |el| {
                var env_iter2 = std.mem.splitScalar(u8, el, '\n');
                while (env_iter2.next()) |line| {
                    const trimmed_line = std.mem.trim(u8, line, " \t\r");
                    if (trimmed_line.len == 0) continue;
                    if (std.mem.indexOfScalar(u8, trimmed_line, '=')) |eq_pos| {
                        const key = trimmed_line[0..eq_pos];
                        const value = trimmed_line[eq_pos + 1 ..];
                        update_run.setEnvironmentVariable(key, value);
                    }
                }
            }
            update_run.addFileArg(b.path(te.file_path));
            if (te.has_stdin) {
                update_run.setStdIn(.{ .bytes = te.stdin_content });
            }

            // Library file dependencies (recursive)
            {
                var lib_dir2 = b.build_root.handle.openDir("lib", .{ .iterate = true }) catch |err| {
                    std.debug.print("Warning: Could not open lib/: {}\n", .{err});
                    return;
                };
                defer lib_dir2.close();
                var walker2 = lib_dir2.walk(b.allocator) catch |err| {
                    std.debug.print("Warning: Could not walk lib/: {}\n", .{err});
                    return;
                };
                defer walker2.deinit();
                while (walker2.next() catch null) |entry| {
                    if (entry.kind != .file) continue;
                    if (!std.mem.endsWith(u8, entry.path, ".1z")) continue;
                    update_run.addFileInput(b.path(b.fmt("lib/{s}", .{entry.path})));
                }
            }
            update_run.addFileInput(b.path("src/prelude.1z"));
            if (te.has_stdin) update_run.addFileInput(b.path(te.stdin_path));
            if (te.has_flags) update_run.addFileInput(b.path(te.flags_path));
            if (te.has_exitcode) update_run.addFileInput(b.path(te.exitcode_path));
            if (te.has_env) update_run.addFileInput(b.path(te.env_path));
            uf_ptr.*.addCopyFileToSource(update_run.captureStdOut(), te.stdout_golden_path);

            const update_exit_code = te.expected_exit_code orelse if (te.has_stderr_golden) @as(u8, 1) else @as(u8, 0);
            if (update_exit_code != 0) {
                update_run.expectExitCode(update_exit_code);
            }
            if (te.has_stderr_golden or update_exit_code != 0 or te.has_exitcode) {
                uf_ptr.*.addCopyFileToSource(update_run.captureStdErr(), te.stderr_golden_path);
            }
        }
    }
}

fn addIrSources(b: *std.Build, module: *std.Build.Module) void {
    const arch_flag: []const u8 = switch (module.resolved_target.?.result.cpu.arch) {
        .aarch64 => "-DIR_TARGET_AARCH64",
        .x86_64 => "-DIR_TARGET_X64",
        .x86 => "-DIR_TARGET_X86",
        else => @panic("unsupported architecture for ir JIT"),
    };

    const ir_c_files = [_][]const u8{
        "ir.c",
        "ir_strtab.c",
        "ir_cfg.c",
        "ir_sccp.c",
        "ir_gcm.c",
        "ir_ra.c",
        "ir_emit.c",
        "ir_save.c",
        "ir_dump.c",
        "ir_load.c",
        "ir_emit_c.c",
        "ir_emit_llvm.c",
        "ir_check.c",
        "ir_cpuinfo.c",
        "ir_gdb.c",
        "ir_perf.c",
        "ir_patch.c",
        "ir_mem2ssa.c",
        "ir_disasm_stub.c",
    };

    const flags: []const []const u8 = &.{
        arch_flag,
        "-Wno-sign-compare",
        "-Wno-unused-parameter",
    };

    for (ir_c_files) |name| {
        module.addCSourceFile(.{
            .file = b.path(b.fmt("ext/ir/{s}", .{name})),
            .flags = flags,
        });
    }

    module.addIncludePath(b.path("ext/ir"));
    module.addIncludePath(b.path("ext/ir/dynasm"));
    module.addIncludePath(b.path("ext/ir/generated"));
}
