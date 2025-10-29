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

    // Dynamically discover and run all .1z files in tests/integration/
    const test_dir = b.build_root.handle.openDir("tests/integration", .{ .iterate = true }) catch |err| {
        std.debug.print("Warning: Could not open tests/integration: {}\n", .{err});
        return;
    };

    var iter = test_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".1z")) continue;

        const test_run = b.addRunArtifact(exe);
        const file_path = b.fmt("tests/integration/{s}", .{entry.name});
        const content = b.build_root.handle.readFileAlloc(b.allocator, file_path, 1024 * 1024) catch |err| {
            std.debug.print("Warning: Could not read {s}: {}\n", .{ file_path, err });
            continue;
        };
        test_run.setStdIn(.{ .bytes = content });
        test_run.expectStdErrEqual("");
        integration_test_step.dependOn(&test_run.step);
    }
}
