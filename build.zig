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
    test_module.addOptions("build_options", options);

    const lib_unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Integration tests
    const integration_test_step = b.step("integration-test", "Run integration tests");
    integration_test_step.dependOn(&run_lib_unit_tests.step);

    // Update golden files step
    const update_golden_step = b.step("update-golden", "Update golden files for integration tests");
    var update_files = b.addUpdateSourceFiles();

    // Dynamically discover and run all .1z files in tests/integration/
    var test_dir = b.build_root.handle.openDir("tests/integration", .{ .iterate = true }) catch |err| {
        std.debug.print("Warning: Could not open tests/integration: {}\n", .{err});
        return;
    };
    defer test_dir.close();

    var iter = test_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".1z")) continue;

        const name_without_ext = entry.name[0 .. entry.name.len - 3];
        const file_path = b.fmt("tests/integration/{s}", .{entry.name});
        const stdout_golden_path = b.fmt("tests/integration/{s}.stdout.golden", .{name_without_ext});

        // Check for .stdin file as source of input for the test
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

        // Check for .flags file for extra CLI flags for the test
        const flags_path = b.fmt("tests/integration/{s}.flags", .{name_without_ext});
        var flags_lines: ?[]const u8 = null;
        var has_flags = false;
        if (test_dir.openFile(b.fmt("{s}.flags", .{name_without_ext}), .{})) |file| {
            defer file.close();
            flags_lines = file.readToEndAlloc(b.allocator, 1024 * 1024) catch null;
            has_flags = true;
        } else |_| {}

        // Check for .exitcode file to override expected exit code
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

        // Integration test: compare against golden file if it exists
        const test_run = b.addRunArtifact(exe);
        test_run.addArg("--show-stack");
        test_run.addArg(b.fmt("--stdlib-path={s}/lib", .{b.build_root.path orelse "."}));
        if (flags_lines) |fl| {
            var flag_iter = std.mem.splitScalar(u8, fl, '\n');
            while (flag_iter.next()) |flag| {
                const trimmed_flag = std.mem.trim(u8, flag, " \t\r");
                if (trimmed_flag.len > 0) {
                    test_run.addArg(trimmed_flag);
                }
            }
        }
        test_run.addFileArg(b.path(file_path));
        if (has_stdin) {
            test_run.setStdIn(.{ .bytes = stdin_content });
        }

        // Library file dependencies
        {
            var lib_dir = b.build_root.handle.openDir("lib", .{ .iterate = true }) catch |err| {
                std.debug.print("Warning: Could not open lib/: {}\n", .{err});
                return;
            };
            defer lib_dir.close();
            var lib_iter = lib_dir.iterate();
            while (lib_iter.next() catch null) |lib_entry| {
                if (lib_entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, lib_entry.name, ".1z")) continue;
                test_run.addFileInput(b.path(b.fmt("lib/{s}", .{lib_entry.name})));
            }
        }
        test_run.addFileInput(b.path("src/prelude.1z"));
        if (has_stdin) test_run.addFileInput(b.path(stdin_path));
        if (has_flags) test_run.addFileInput(b.path(flags_path));
        if (has_exitcode) test_run.addFileInput(b.path(exitcode_path));

        // Check for stderr golden file for tests with stderr output
        var has_stderr_golden = false;
        const stderr_golden_name = b.fmt("{s}.stderr.golden", .{name_without_ext});
        if (test_dir.openFile(stderr_golden_name, .{})) |file| {
            defer file.close();
            const stderr_content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            has_stderr_golden = true;
            // Track the stderr golden file as a dependency
            test_run.addFileInput(b.path(b.fmt("tests/integration/{s}", .{stderr_golden_name})));
            test_run.expectStdErrEqual(stderr_content);
        } else |_| {}

        if (!has_stderr_golden) {
            test_run.expectStdErrEqual("");
        }

        // Set expected exit code: .exitcode file > default (1 for error tests, 0 otherwise)
        test_run.expectExitCode(expected_exit_code orelse if (has_stderr_golden) 1 else 0);

        // Try to read stdout golden file for comparison
        if (test_dir.openFile(b.fmt("{s}.stdout.golden", .{name_without_ext}), .{})) |file| {
            defer file.close();
            const golden_content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            // Track the stdout golden file as a dependency
            test_run.addFileInput(b.path(stdout_golden_path));
            test_run.expectStdOutEqual(golden_content);
        } else |_| {
            test_run.expectStdOutEqual("");
        }
        integration_test_step.dependOn(&test_run.step);

        // Update golden: capture stdout and write to .stdout.golden file
        const update_run = b.addRunArtifact(exe);
        update_run.addArg("--show-stack");
        update_run.addArg(b.fmt("--stdlib-path={s}/lib", .{b.build_root.path orelse "."}));
        if (flags_lines) |fl| {
            var flag_iter2 = std.mem.splitScalar(u8, fl, '\n');
            while (flag_iter2.next()) |flag| {
                const trimmed_flag = std.mem.trim(u8, flag, " \t\r");
                if (trimmed_flag.len > 0) {
                    update_run.addArg(trimmed_flag);
                }
            }
        }
        update_run.addFileArg(b.path(file_path));
        if (has_stdin) {
            update_run.setStdIn(.{ .bytes = stdin_content });
        }

        // Library file dependencies
        {
            var lib_dir2 = b.build_root.handle.openDir("lib", .{ .iterate = true }) catch |err| {
                std.debug.print("Warning: Could not open lib/: {}\n", .{err});
                return;
            };
            defer lib_dir2.close();
            var lib_iter2 = lib_dir2.iterate();
            while (lib_iter2.next() catch null) |lib_entry| {
                if (lib_entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, lib_entry.name, ".1z")) continue;
                update_run.addFileInput(b.path(b.fmt("lib/{s}", .{lib_entry.name})));
            }
        }
        update_run.addFileInput(b.path("src/prelude.1z"));
        if (has_stdin) update_run.addFileInput(b.path(stdin_path));
        if (has_flags) update_run.addFileInput(b.path(flags_path));
        if (has_exitcode) update_run.addFileInput(b.path(exitcode_path));
        update_files.addCopyFileToSource(update_run.captureStdOut(), stdout_golden_path);

        // Set expected exit code and capture stderr for golden update
        const update_exit_code = expected_exit_code orelse if (has_stderr_golden) @as(u8, 1) else @as(u8, 0);
        if (update_exit_code != 0) {
            update_run.expectExitCode(update_exit_code);
        }
        if (has_stderr_golden) {
            const stderr_golden_path = b.fmt("tests/integration/{s}.stderr.golden", .{name_without_ext});
            update_files.addCopyFileToSource(update_run.captureStdErr(), stderr_golden_path);
        }
    }

    update_golden_step.dependOn(&update_files.step);

    // XXX(ripta): icky hack to validate that no golden files contain "FAIL:", since
    //             I seem to keep missing them when reviewing test diffs.
    const validate_golden = b.addSystemCommand(&.{
        "sh", "-c",
        \\if grep -l 'FAIL:' tests/integration/*.stdout.golden 2>/dev/null; then
        \\  echo ""
        \\  echo "ERROR: Golden files contain FAIL: - fix the failing tests before updating golden files"
        \\  exit 1
        \\fi
    });
    validate_golden.step.dependOn(&update_files.step);
    update_golden_step.dependOn(&validate_golden.step);

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
        if (fmt_test_dir.openFile(b.fmt("{s}.golden", .{name_without_ext}), .{})) |file| {
            defer file.close();
            const golden_content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            // Track the golden file as a dependency
            fmt_run.addFileInput(b.path(golden_path));
            fmt_run.expectStdOutEqual(golden_content);
        } else |_| {
            std.debug.print("Warning: No golden file for {s}\n", .{entry.name});
        }

        fmt_run.expectStdErrEqual("");
        fmt_run.expectExitCode(0);
        fmt_test_step.dependOn(&fmt_run.step);

        // Update golden: capture stdout and write to .golden file
        const update_fmt_run = b.addRunArtifact(exe);
        update_fmt_run.addArg("fmt");
        update_fmt_run.addArg("--stdout");
        update_fmt_run.addFileArg(b.path(input_path));
        update_fmt_files.addCopyFileToSource(update_fmt_run.captureStdOut(), golden_path);
    }

    update_fmt_golden_step.dependOn(&update_fmt_files.step);
}
