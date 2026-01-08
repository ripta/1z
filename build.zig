const std = @import("std");
const version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
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
    b.installArtifact(exe);

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

        // Integration test: compare against golden file if it exists
        const test_run = b.addRunArtifact(exe);
        test_run.addArg("--show-stack");
        test_run.addArg(file_path);

        // Check for stderr golden file (error tests)
        var has_stderr_golden = false;
        if (test_dir.openFile(b.fmt("{s}.stderr.golden", .{name_without_ext}), .{})) |file| {
            defer file.close();
            const stderr_content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            if (stderr_content.len > 0) {
                has_stderr_golden = true;
                test_run.expectStdErrEqual(stderr_content);
                test_run.expectExitCode(1); // Error tests should fail
            }
        } else |_| {}

        if (!has_stderr_golden) {
            test_run.expectStdErrEqual("");
            test_run.expectExitCode(0);
        }

        // Try to read stdout golden file for comparison
        if (test_dir.openFile(b.fmt("{s}.stdout.golden", .{name_without_ext}), .{})) |file| {
            defer file.close();
            const golden_content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            test_run.expectStdOutEqual(golden_content);
        } else |_| {
            // No golden file - just check exit code (already done above)
        }
        integration_test_step.dependOn(&test_run.step);

        // Update golden: capture stdout and write to .stdout.golden file
        const update_run = b.addRunArtifact(exe);
        update_run.addArg("--show-stack");
        update_run.addArg(file_path);
        update_files.addCopyFileToSource(update_run.captureStdOut(), stdout_golden_path);
    }

    update_golden_step.dependOn(&update_files.step);
}
