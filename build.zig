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

    // Test: no memory leaks when defining words
    const leak_test = b.addRunArtifact(exe);
    leak_test.setStdIn(.{ .bytes = "foo: [ 1 2 + ] ;\nbar: [ foo foo ] ;\n.q\n" });
    leak_test.expectStdErrEqual("");
    integration_test_step.dependOn(&leak_test.step);

    // Test: strings and arrays don't leak memory
    const string_test = b.addRunArtifact(exe);
    string_test.setStdIn(.{ .bytes = "\"hello world\" print\n{ 1 2 3 } print\n{ \"a\" { 1 } } print\n.q\n" });
    string_test.expectStdErrEqual("");
    integration_test_step.dependOn(&string_test.step);
}
