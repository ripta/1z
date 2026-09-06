const std = @import("std");
const version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_case_timeout_secs = b.option(u32, "test-case-timeout", "Per-test timeout in seconds") orelse 10;
    const aot_build_timeout_secs = b.option(u32, "aot-build-timeout", "Per-AOT-build-step timeout in seconds (default: 4x test-case-timeout)") orelse test_case_timeout_secs * 4;
    const test_filter = b.option([]const u8, "test-filter", "Comma-separated substring filter for test names");
    const test_threads = b.option([]const u8, "test-threads", "Default --threads=<value> for integration tests; overridable per-test via .flags") orelse "1";
    const verbose_test_reporting = envFlagIsSet(b, "VERBOSE");
    const slow_test_threshold_ms: u64 = 1000;
    const bail_stats = b.option(bool, "bail-stats", "Enable bail frequency instrumentation (writes stats to stderr on exit)") orelse false;
    const embed_stdlib = b.option(bool, "embed-stdlib", "Embed lib/ stdlib source as a fallback module backing store") orelse false;
    const freestanding_heap_mib = b.option(u32, "freestanding-heap-mib", "Static-region size for the bare-metal freestanding allocator in MiB (wasm targets use a real growable allocator instead)") orelse 16;
    const alloc_stack_traces = b.option(bool, "alloc-stack-traces", "Capture allocation stack traces in Debug builds, so leak reports name the allocation site") orelse false;

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "git_commit", captureGitCommit(b));
    options.addOption(u32, "test_case_timeout_secs", test_case_timeout_secs);
    options.addOption(bool, "verbose_test_reporting", verbose_test_reporting);
    options.addOption(u64, "slow_test_threshold_ms", slow_test_threshold_ms);
    options.addOption(bool, "bail_stats", bail_stats);
    options.addOption(bool, "embed_stdlib", embed_stdlib);
    options.addOption(u32, "freestanding_heap_mib", freestanding_heap_mib);
    options.addOption(bool, "alloc_stack_traces", alloc_stack_traces);

    const embedded_stdlib_path = generateEmbeddedStdlib(b, embed_stdlib);

    const build_target = resolveBuildTarget(target);
    const is_freestanding = !build_target.has_filesystem;

    // A target that resolves `use` imports at runtime but has no filesystem to load lib/ from
    // needs the embedded stdlib fallback backing store.
    if (build_target.needs_stdlib_at_runtime and !build_target.has_filesystem and !embed_stdlib) {
        std.debug.print(
            "Error: this target has no filesystem and requires -Dembed-stdlib=true to resolve `use` imports at runtime\n",
            .{},
        );
        @panic("build requires -Dembed-stdlib=true");
    }

    // Freestanding builds only emit the static capi library; the executables
    // and shared library both require an OS-level entry point and dynamic
    // linker that the bare-metal target lacks.
    var maybe_exe: ?*std.Build.Step.Compile = null;
    var maybe_install_exe: ?*std.Build.Step.InstallArtifact = null;
    var maybe_lsp_exe: ?*std.Build.Step.Compile = null;
    var maybe_install_lsp: ?*std.Build.Step.InstallArtifact = null;
    if (!is_freestanding) {
        const root_module = createCommonModule(b, target, optimize, options, b.path("src/main.zig"), embedded_stdlib_path);

        // zig-out/bin/1z
        const e = b.addExecutable(.{
            .name = "1z",
            .root_module = root_module,
        });
        const install_exe = b.addInstallArtifact(e, .{});
        b.getInstallStep().dependOn(&install_exe.step);
        maybe_exe = e;
        maybe_install_exe = install_exe;

        // zig-out/bin/1z-lsp
        const lsp_module = createCommonModule(b, target, optimize, options, b.path("src/lsp_main.zig"), embedded_stdlib_path);

        const lsp_exe = b.addExecutable(.{
            .name = "1z-lsp",
            .root_module = lsp_module,
        });
        const install_lsp = b.addInstallArtifact(lsp_exe, .{});
        b.getInstallStep().dependOn(&install_lsp.step);
        maybe_lsp_exe = lsp_exe;
        maybe_install_lsp = install_lsp;
    }

    // zig-out/clib/lib1z.a (static library)
    // Installed to clib/ instead of lib/ because zig-out/lib is symlinked
    // to the stdlib directory.
    const capi_static_root = b.path(build_target.capi_root);
    const capi_static_module = createCommonModule(b, target, optimize, options, capi_static_root, embedded_stdlib_path);

    const static_lib = b.addLibrary(.{
        .name = "1z",
        .root_module = capi_static_module,
        .linkage = .static,
    });

    // XXX(ripta): Per-function and per-data sections let the linker GC unused interpreter code at
    //             function granularity when an AOT binary is built interpreter-free. Mach-O strips
    //             the per-symbol natively so this is a noüop, but ELF needs it for `--gc-sections`.
    static_lib.link_function_sections = true;
    static_lib.link_data_sections = true;

    const install_static = b.addInstallArtifact(static_lib, .{
        .dest_dir = .{ .override = .{ .custom = "clib" } },
    });
    b.getInstallStep().dependOn(&install_static.step);

    if (!is_freestanding) {
        // zig-out/clib/lib1z.dylib (shared library)
        const capi_shared_module = createCommonModule(b, target, optimize, options, b.path("src/capi.zig"), embedded_stdlib_path);

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
        if (maybe_install_exe) |ie| symlink_step.step.dependOn(&ie.step);
        b.getInstallStep().dependOn(&symlink_step.step);
    }

    const is_wasm_target = target.result.cpu.arch == .wasm32 and target.result.os.tag == .freestanding;
    if (is_wasm_target) {
        // Compile-check the wasm clock host import, the no-op multiplexer, and a real
        // Context/loadPrelude construction against the real wasm32-freestanding target. Built as
        // a static library (like capi_wasm.zig itself), not `b.addTest`, because the default
        // test runner needs posix I/O to report results and does not compile for this target --
        // unrelated to whether our own code is portable. See src/wasm_compile_probe.zig for what
        // this covers.
        const wasm_probe_module = createCommonModule(b, target, optimize, options, b.path("src/wasm_compile_probe.zig"), embedded_stdlib_path);
        const wasm_probe_lib = b.addLibrary(.{
            .name = "wasm-clock-check",
            .root_module = wasm_probe_module,
            .linkage = .static,
        });
        const wasm_clock_check_step = b.step(
            "wasm-clock-check",
            "Compile-check the wasm clock, no-op multiplexer, and interpreter Context for wasm32-freestanding",
        );
        wasm_clock_check_step.dependOn(&wasm_probe_lib.step);
        b.getInstallStep().dependOn(wasm_clock_check_step);
    }

    if (is_freestanding) {
        // The freestanding build is only the static library; no executables to
        // run, document, or test against. Bail before the rest of the wiring.
        return;
    }
    const exe = maybe_exe.?;
    const install_exe = maybe_install_exe.?;
    const lsp_exe = maybe_lsp_exe.?;
    const install_lsp = maybe_install_lsp.?;

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

    const helper_module = b.createModule(.{
        .root_source_file = b.path("src/test_case_helper.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const test_case_helper = b.addExecutable(.{
        .name = "test-case-helper",
        .root_module = helper_module,
    });

    // Unit tests
    const test_module = createCommonModule(b, target, optimize, options, b.path("src/main.zig"), embedded_stdlib_path);

    const lib_unit_tests = b.addTest(.{
        .name = "1z-unit-test",
        .root_module = test_module,
        .test_runner = .{
            .path = b.path("src/unit_test_runner.zig"),
            .mode = .simple,
        },
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    run_lib_unit_tests.setName("unit tests");
    // `zig build` does not forward the ambient environment to a Run step, so the
    // -Dtest-filter option is plumbed to the custom runner (which reads
    // ONEZ_TEST_FILTER) explicitly. Same comma-separated substring semantics as
    // the integration/fmt/aot/lsp filters.
    if (test_filter) |filter| run_lib_unit_tests.setEnvironmentVariable("ONEZ_TEST_FILTER", filter);

    // Expose the unit-test binary at a stable path so external coverage
    // tooling such as kcov can wrap it. Installed under zig-out/test/ to keep
    // clear of the zig-out/lib stdlib symlink.
    const install_unit_test_bin = b.addInstallArtifact(lib_unit_tests, .{
        .dest_dir = .{ .override = .{ .custom = "test" } },
    });
    const unit_test_bin_step = b.step("unit-test-bin", "Build the unit-test binary to zig-out/test/ for coverage tooling");
    unit_test_bin_step.dependOn(&install_unit_test_bin.step);

    const freestanding_capi_test_module = createCommonModule(b, target, optimize, options, b.path("src/capi_freestanding.zig"), embedded_stdlib_path);
    const freestanding_capi_unit_tests = b.addTest(.{
        .root_module = freestanding_capi_test_module,
        .test_runner = .{
            .path = b.path("src/unit_test_runner.zig"),
            .mode = .simple,
        },
    });
    const run_freestanding_capi_unit_tests = b.addRunArtifact(freestanding_capi_unit_tests);
    run_freestanding_capi_unit_tests.setName("freestanding capi unit tests");
    run_freestanding_capi_unit_tests.setEnvironmentVariable("ONEZ_TEST_FILTER", test_filter orelse "freestanding");

    // Hosted C-API (embedding library) unit tests. Exposed under its own
    // `capi-test` step rather than `test` because several tests load stdlib
    // modules and need -Dembed-stdlib=true to resolve them without a disk
    // stdlib symlink relative to the test binary.
    const hosted_capi_test_module = createCommonModule(b, target, optimize, options, b.path("src/capi.zig"), embedded_stdlib_path);
    const hosted_capi_unit_tests = b.addTest(.{
        .root_module = hosted_capi_test_module,
        .test_runner = .{
            .path = b.path("src/unit_test_runner.zig"),
            .mode = .simple,
        },
    });
    const run_hosted_capi_unit_tests = b.addRunArtifact(hosted_capi_unit_tests);
    run_hosted_capi_unit_tests.setName("hosted capi unit tests");
    if (test_filter) |filter| run_hosted_capi_unit_tests.setEnvironmentVariable("ONEZ_TEST_FILTER", filter);

    // wasm C-API surface, host-compiled and run natively so its eval/stack/register-word logic
    // is verified by a real test run; the actual wasm32-freestanding cross-compile is checked
    // separately (wasm-freestanding-build), since no wasm runtime exists in this test setup.
    // Needs -Dembed-stdlib=true for the same reason as the hosted capi tests above: onez_init
    // calls ctx.loadPrelude(null), which resolves through the same stdlib-lookup path.
    const wasm_capi_test_module = createCommonModule(b, target, optimize, options, b.path("src/capi_wasm.zig"), embedded_stdlib_path);
    const wasm_capi_unit_tests = b.addTest(.{
        .root_module = wasm_capi_test_module,
        .test_runner = .{
            .path = b.path("src/unit_test_runner.zig"),
            .mode = .simple,
        },
    });
    const run_wasm_capi_unit_tests = b.addRunArtifact(wasm_capi_unit_tests);
    run_wasm_capi_unit_tests.setName("wasm capi unit tests");
    if (test_filter) |filter| run_wasm_capi_unit_tests.setEnvironmentVariable("ONEZ_TEST_FILTER", filter);

    const capi_test_step = b.step("capi-test", "Run hosted C-API embedding-library unit tests");
    capi_test_step.dependOn(&run_hosted_capi_unit_tests.step);
    capi_test_step.dependOn(&run_wasm_capi_unit_tests.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_freestanding_capi_unit_tests.step);

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

    // zig-out/ext/liblua5.4.{dylib,so}: the vendored Lua library, driven through the dynamic FFI
    // by lib/lua.1z.
    //
    // Built as a standalone shared library on the toy pattern rather than compiled into the
    // interpreter, so a program that never loads lib/lua.1z pays nothing.
    //
    // Installed on the default step so an installed interpreter finds it as a sibling.
    const lua_shared_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // Vendored third-party C; disable UBSan so Lua's own benign patterns do
        // not trap in the Debug default build. Not ours to fix.
        .sanitize_c = .off,
    });
    addLuaSources(b, lua_shared_module);
    const lua_shared = b.addLibrary(.{
        .name = "lua5.4",
        .root_module = lua_shared_module,
        .linkage = .dynamic,
    });
    const install_lua_shared = b.addInstallArtifact(lua_shared, .{
        .dest_dir = .{ .override = .{ .custom = "ext" } },
    });
    b.getInstallStep().dependOn(&install_lua_shared.step);

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
    integration_test_step.dependOn(&install_toy_shared.step);
    integration_test_step.dependOn(&install_lua_shared.step);
    var integration_status_files = std.ArrayListUnmanaged(std.Build.LazyPath){};

    // Update golden files step
    const update_golden_step = b.step("update-golden", "Update golden files for integration tests");
    update_golden_step.dependOn(&install_toy_shared.step);
    update_golden_step.dependOn(&install_lua_shared.step);
    var update_files = b.addUpdateSourceFiles();

    addIntegrationTests(b, exe, test_case_helper, integration_test_step, &update_files, &integration_status_files, test_entries, has_diff, false, test_case_timeout_secs, verbose_test_reporting, slow_test_threshold_ms, test_filter, test_threads);
    if (verbose_test_reporting) addVerboseSummary(b, test_case_helper, integration_test_step, "integration", integration_status_files.items);

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
    eager_test_step.dependOn(&install_lua_shared.step);
    var eager_status_files = std.ArrayListUnmanaged(std.Build.LazyPath){};

    addIntegrationTests(b, exe, test_case_helper, eager_test_step, null, &eager_status_files, test_entries, has_diff, true, test_case_timeout_secs, verbose_test_reporting, slow_test_threshold_ms, test_filter, test_threads);
    if (verbose_test_reporting) addVerboseSummary(b, test_case_helper, eager_test_step, "eager integration", eager_status_files.items);

    // Formatter tests
    const fmt_test_step = b.step("fmt-test", "Run formatter tests");
    const update_fmt_golden_step = b.step("update-fmt-golden", "Update golden files for formatter tests");
    var update_fmt_files = b.addUpdateSourceFiles();
    var fmt_status_files = std.ArrayListUnmanaged(std.Build.LazyPath){};

    // Dynamically discover and run all .txt files in tests/formatting/
    var fmt_test_dir = b.build_root.handle.openDir("tests/formatting", .{ .iterate = true }) catch |err| {
        std.debug.print("Warning: Could not open tests/formatting: {}\n", .{err});
        return;
    };
    defer fmt_test_dir.close();

    var fmt_iter = fmt_test_dir.iterate();
    var fmt_total_count: usize = 0;
    var fmt_matched_count: usize = 0;
    while (fmt_iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;
        fmt_total_count += 1;

        const name_without_ext = entry.name[0 .. entry.name.len - 4];
        if (test_filter) |filter| {
            if (!matchesFilter(name_without_ext, filter)) continue;
        }
        fmt_matched_count += 1;
        const input_path = b.fmt("tests/formatting/{s}", .{entry.name});
        const golden_path = b.fmt("tests/formatting/{s}.golden", .{name_without_ext});

        // Formatter test: run formatter and compare against golden file
        const fmt_label = b.fmt("fmt: {s}", .{name_without_ext});
        const fmt_run = addWrappedCommand(
            b,
            test_case_helper,
            fmt_label,
            test_case_timeout_secs,
            verbose_test_reporting,
            slow_test_threshold_ms,
            null,
            &fmt_status_files,
            &.{},
            false,
        );
        fmt_run.addArtifactArg(exe);
        fmt_run.addArg("fmt");
        fmt_run.addArg("--stdout");
        fmt_run.addFileArg(b.path(input_path));
        fmt_run.setName(fmt_label);

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
            addGoldenDiff(b, fmt_test_step, fmt_run.captureStdOut(), golden_path, input_path);
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

    if (test_filter) |filter| {
        const fmt_summary_cmd = b.addSystemCommand(&.{ "echo", b.fmt("Filter active: {d}/{d} fmt tests match '{s}'", .{ fmt_matched_count, fmt_total_count, filter }) });
        fmt_test_step.dependOn(&fmt_summary_cmd.step);
    }

    update_fmt_golden_step.dependOn(&update_fmt_files.step);
    if (verbose_test_reporting) addVerboseSummary(b, test_case_helper, fmt_test_step, "fmt", fmt_status_files.items);

    // 1z-formatter tests
    //
    // Each case runs both formatters over one input from the fmt corpus and diffs their captured
    // output, so the comparison needs no golden files of its own. `ONEZ_FMT_PHASE` holds the Zig
    // side to the phase the 1z formatter has reached. Retired with the Zig formatter.
    const fmt_1z_test_step = b.step("fmt-1z-test", "Compare the 1z formatter against the Zig formatter's token-level phase");
    var fmt_1z_status_files = std.ArrayListUnmanaged(std.Build.LazyPath){};

    var fmt_1z_iter = fmt_test_dir.iterate();
    while (fmt_1z_iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;

        const name_without_ext = entry.name[0 .. entry.name.len - 4];
        if (test_filter) |filter| {
            if (!matchesFilter(name_without_ext, filter)) continue;
        }
        const input_path = b.fmt("tests/formatting/{s}", .{entry.name});

        const actual_label = b.fmt("fmt-1z: {s}", .{name_without_ext});
        const actual_run = addWrappedCommand(
            b,
            test_case_helper,
            actual_label,
            test_case_timeout_secs,
            verbose_test_reporting,
            slow_test_threshold_ms,
            null,
            &fmt_1z_status_files,
            &.{},
            false,
        );
        actual_run.addArtifactArg(exe);
        actual_run.addArg("tools/fmt.1z");
        actual_run.addFileArg(b.path(input_path));
        actual_run.addFileInput(b.path("tools/fmt.1z"));
        addCommonFileDeps(b, actual_run);
        // The interpreter runs out of the cache directory, where the zig-out/lib symlink it
        // normally resolves the standard library through does not exist.
        actual_run.setEnvironmentVariable("ONEZ_STDLIB", b.fmt("{s}/lib", .{b.build_root.path orelse "."}));
        actual_run.setEnvironmentVariable("ONEZ_NO_STARTUP", "1");
        actual_run.expectStdErrEqual("");
        actual_run.expectExitCode(0);
        actual_run.setName(actual_label);

        const expected_run = b.addRunArtifact(exe);
        expected_run.setEnvironmentVariable("ONEZ_FMT_PHASE", "1");
        expected_run.addArg("fmt");
        expected_run.addArg("--stdout");
        expected_run.addFileArg(b.path(input_path));
        expected_run.setName(b.fmt("fmt-zig-phase1: {s}", .{name_without_ext}));

        addCapturedDiff(
            b,
            fmt_1z_test_step,
            expected_run.captureStdOut(),
            actual_run.captureStdOut(),
            b.fmt("zig token-level: {s}", .{input_path}),
            b.fmt("1z formatter: {s}", .{input_path}),
        );
    }

    if (verbose_test_reporting) addVerboseSummary(b, test_case_helper, fmt_1z_test_step, "fmt-1z", fmt_1z_status_files.items);

    // AOT build integration tests
    const aot_test_step = b.step("aot-test", "Run AOT build integration tests");
    aot_test_step.dependOn(b.getInstallStep());
    var aot_status_files = std.ArrayListUnmanaged(std.Build.LazyPath){};

    const update_aot_golden_step = b.step("update-aot-golden", "Update AOT test golden files");
    var update_aot_files = b.addUpdateSourceFiles();

    {
        var aot_dir = b.build_root.handle.openDir("tests/aot", .{ .iterate = true }) catch |err| {
            std.debug.print("Warning: Could not open tests/aot: {}\n", .{err});
            return;
        };
        defer aot_dir.close();

        const aot_entries = collectAotTestEntries(b, &aot_dir) catch return;
        addAotTests(b, exe, test_case_helper, aot_test_step, &update_aot_files, &aot_status_files, aot_entries, has_diff, test_case_timeout_secs, aot_build_timeout_secs, verbose_test_reporting, slow_test_threshold_ms, test_filter);
    }

    update_aot_golden_step.dependOn(&update_aot_files.step);
    if (verbose_test_reporting) addVerboseSummary(b, test_case_helper, aot_test_step, "aot", aot_status_files.items);

    // LSP server tests
    const lsp_test_step = b.step("lsp-test", "Run LSP server tests");
    lsp_test_step.dependOn(&install_lsp.step);
    var lsp_status_files = std.ArrayListUnmanaged(std.Build.LazyPath){};

    const update_lsp_golden_step = b.step("update-lsp-golden", "Update LSP test golden files");
    var update_lsp_files = b.addUpdateSourceFiles();

    {
        var lsp_dir = b.build_root.handle.openDir("tests/lsp", .{ .iterate = true }) catch |err| {
            std.debug.print("Warning: Could not open tests/lsp: {}\n", .{err});
            return;
        };
        defer lsp_dir.close();

        const lsp_entries = collectLspTestEntries(b, &lsp_dir) catch return;
        addLspTests(b, lsp_exe, test_case_helper, lsp_test_step, &update_lsp_files, &lsp_status_files, lsp_entries, has_diff, test_case_timeout_secs, verbose_test_reporting, slow_test_threshold_ms, test_filter);
    }

    update_lsp_golden_step.dependOn(&update_lsp_files.step);
    if (verbose_test_reporting) addVerboseSummary(b, test_case_helper, lsp_test_step, "lsp", lsp_status_files.items);

    // The baremetal step needs no QEMU, so aot-test carries the freestanding
    // link and symbol-verify in the default test path.
    const baremetal_step = addBaremetalRiscv64VirtTest(b, exe, optimize, options, embedded_stdlib_path);
    aot_test_step.dependOn(baremetal_step);

    _ = addWasmBuild(b, optimize, options);
}

const BuildTarget = struct {
    has_filesystem: bool,
    needs_stdlib_at_runtime: bool,
    single_threaded: ?bool,
    capi_root: []const u8,
};

fn resolveBuildTarget(target: std.Build.ResolvedTarget) BuildTarget {
    if (target.result.cpu.arch == .wasm32 and target.result.os.tag == .freestanding) {
        return .{
            .has_filesystem = false,
            .needs_stdlib_at_runtime = true,
            // wasm32-freestanding has no native threading model, so Mutex/RwLock already fall
            // back to their no-op single-threaded impls; this makes that fallback the default.
            .single_threaded = true,
            .capi_root = "src/capi_wasm.zig",
        };
    }
    if (target.result.os.tag == .freestanding) {
        // The riscv64 AOT-replay root never resolves `use` imports at runtime, so it has no
        // stdlib dependency despite also lacking a filesystem.
        return .{
            .has_filesystem = false,
            .needs_stdlib_at_runtime = false,
            .single_threaded = null,
            .capi_root = "src/capi_freestanding.zig",
        };
    }
    return .{
        .has_filesystem = true,
        .needs_stdlib_at_runtime = true,
        .single_threaded = null,
        .capi_root = "src/capi.zig",
    };
}

fn addBaremetalRiscv64VirtTest(
    b: *std.Build,
    host_exe: *std.Build.Step.Compile,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
    embedded_stdlib_path: std.Build.LazyPath,
) *std.Build.Step {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const platform_module = b.createModule(.{
        .root_source_file = b.path("src/baremetal/riscv64/virt/platform.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .single_threaded = true,
        .stack_check = false,
        .stack_protector = false,
        .pic = false,
        .red_zone = false,
        .code_model = .medium, // The kernel loads high (0x80200000), beyond medlow's reach
        .sanitize_c = .off, // No UBSan runtime on bare metal, since its objects are not medany-built.
    });
    platform_module.addAssemblyFile(b.path("src/baremetal/riscv64/virt/boot.S"));

    const platform_lib = b.addLibrary(.{
        .name = "1z-riscv64-virt",
        .root_module = platform_module,
        .linkage = .static,
    });

    const runtime_module = createCommonModule(b, target, optimize, options, b.path("src/capi_freestanding.zig"), embedded_stdlib_path);
    runtime_module.single_threaded = true;
    runtime_module.stack_check = false;
    runtime_module.stack_protector = false;
    runtime_module.pic = false;
    runtime_module.red_zone = false;
    runtime_module.code_model = .medium;
    runtime_module.sanitize_c = .off;

    const runtime_lib = b.addLibrary(.{
        .name = "1z-riscv64-freestanding-runtime",
        .root_module = runtime_module,
        .linkage = .static,
    });
    runtime_lib.link_function_sections = true;
    runtime_lib.link_data_sections = true;

    // Production bare-metal entry shim (onez_baremetal_main + UART writer),
    // kept out of the test-stub modules that define their own entry point.
    const entry_module = b.createModule(.{
        .root_source_file = b.path("src/baremetal/riscv64/virt/runtime_entry.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .single_threaded = true,
        .stack_check = false,
        .stack_protector = false,
        .pic = false,
        .red_zone = false,
        .code_model = .medium,
        .sanitize_c = .off,
    });

    const entry_lib = b.addLibrary(.{
        .name = "1z-riscv64-virt-entry",
        .root_module = entry_module,
        .linkage = .static,
    });
    entry_lib.link_function_sections = true;
    entry_lib.link_data_sections = true;

    const stub_module = b.createModule(.{
        .root_source_file = b.path("tests/baremetal/riscv64/uart_stub.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .single_threaded = true,
        .stack_check = false,
        .stack_protector = false,
        .pic = false,
        .red_zone = false,
        .code_model = .medium,
        .sanitize_c = .off,
    });
    stub_module.addImport("virt-platform", platform_module);

    const uart_stub = b.addExecutable(.{
        .name = "1z-riscv64-virt-uart-stub",
        .root_module = stub_module,
    });
    uart_stub.linkLibrary(platform_lib);
    uart_stub.setLinkerScript(b.path("src/baremetal/riscv64/virt/linker.ld"));
    uart_stub.link_gc_sections = true;

    const runtime_stub_module = b.createModule(.{
        .root_source_file = b.path("tests/baremetal/riscv64/freestanding_runtime_stub.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .single_threaded = true,
        .stack_check = false,
        .stack_protector = false,
        .pic = false,
        .red_zone = false,
        .code_model = .medium,
        .sanitize_c = .off,
    });
    runtime_stub_module.addImport("virt-platform", platform_module);

    const runtime_stub = b.addExecutable(.{
        .name = "1z-riscv64-freestanding-runtime-stub",
        .root_module = runtime_stub_module,
    });
    runtime_stub.linkLibrary(platform_lib);
    runtime_stub.linkLibrary(runtime_lib);
    runtime_stub.setLinkerScript(b.path("src/baremetal/riscv64/virt/linker.ld"));
    runtime_stub.link_gc_sections = true;

    // NOTE(ripta): AOT-compile a noöp 1z program to a freestanding riscv64 ELF, driving the host
    //              `1z` as a cross-link front end against the platform, entry, and runtime archives
    //              plus the platform linker script.
    const aot_build = b.addRunArtifact(host_exe);
    aot_build.setName("baremetal aot build: noop");
    aot_build.addArg("build");
    aot_build.addArg("--target=riscv64-freestanding-none");
    aot_build.addArg("--interpreter-fallback=false");
    aot_build.addPrefixedFileArg("--linker-script=", b.path("src/baremetal/riscv64/virt/linker.ld"));
    aot_build.addPrefixedFileArg("--link-object=", entry_lib.getEmittedBin());
    aot_build.addPrefixedFileArg("--link-object=", platform_lib.getEmittedBin());
    aot_build.addPrefixedFileArg("--link-object=", runtime_lib.getEmittedBin());
    aot_build.addArg("-o");
    const kernel_elf = aot_build.addOutputFileArg("kernel.elf");
    aot_build.addFileArg(b.path("tests/baremetal/riscv64/noop.1z"));

    // NOTE(ripta): Verify the linked ELF carries the expected boot symbols and imports no hosted libc. The
    //              freestanding link is -nostdlib, so a successful link already proves there are no stray
    //              libc references. The symbol assertions pin the bare-metal entry surface in place.
    const verify = b.addSystemCommand(&.{ "sh", "-c", baremetal_verify_script, "baremetal-verify" });
    verify.addFileArg(kernel_elf);
    verify.setName("baremetal aot verify: symbols and no libc");
    verify.expectExitCode(0);

    // NOTE(ripta): AOT-compile the hello-world program against the same archives and install the
    //              ELF at a stable prefix path. The Makefile target boots this ELF under qemu and
    //              compares its serial output. The emulation run lives in the Makefile so the qemu
    //              dependency is opt-in and a missing emulator surfaces as an actionable message
    //              rather than an opaque build-step failure.
    const hello_build = b.addRunArtifact(host_exe);
    hello_build.setName("baremetal aot build: hello");
    hello_build.addArg("build");
    hello_build.addArg("--target=riscv64-freestanding-none");
    hello_build.addArg("--interpreter-fallback=false");
    hello_build.addPrefixedFileArg("--linker-script=", b.path("src/baremetal/riscv64/virt/linker.ld"));
    hello_build.addPrefixedFileArg("--link-object=", entry_lib.getEmittedBin());
    hello_build.addPrefixedFileArg("--link-object=", platform_lib.getEmittedBin());
    hello_build.addPrefixedFileArg("--link-object=", runtime_lib.getEmittedBin());
    hello_build.addArg("-o");
    const hello_elf = hello_build.addOutputFileArg("1z-hello.elf");
    hello_build.addFileArg(b.path("tests/baremetal/riscv64/hello.1z"));

    const install_hello = b.addInstallFile(hello_elf, "baremetal/riscv64/1z-hello.elf");

    // NOTE(ripta): AOT-compile the generic-dispatch program the same way. Its image carries
    //              method-dispatch entries, so the link additionally pulls the freestanding
    //              dispatch replay and `aotTryDispatchGenericOrCall` bodies.
    const dispatch_build = b.addRunArtifact(host_exe);
    dispatch_build.setName("baremetal aot build: dispatch");
    dispatch_build.addArg("build");
    dispatch_build.addArg("--target=riscv64-freestanding-none");
    dispatch_build.addArg("--interpreter-fallback=false");
    dispatch_build.addPrefixedFileArg("--linker-script=", b.path("src/baremetal/riscv64/virt/linker.ld"));
    dispatch_build.addPrefixedFileArg("--link-object=", entry_lib.getEmittedBin());
    dispatch_build.addPrefixedFileArg("--link-object=", platform_lib.getEmittedBin());
    dispatch_build.addPrefixedFileArg("--link-object=", runtime_lib.getEmittedBin());
    dispatch_build.addArg("-o");
    const dispatch_elf = dispatch_build.addOutputFileArg("1z-dispatch.elf");
    dispatch_build.addFileArg(b.path("tests/baremetal/riscv64/dispatch.1z"));

    const dispatch_verify = b.addSystemCommand(&.{ "sh", "-c", baremetal_verify_script, "baremetal-verify" });
    dispatch_verify.addFileArg(dispatch_elf);
    dispatch_verify.setName("baremetal aot verify: dispatch symbols and no libc");
    dispatch_verify.expectExitCode(0);

    const install_dispatch = b.addInstallFile(dispatch_elf, "baremetal/riscv64/1z-dispatch.elf");

    // NOTE(ripta): AOT-compile the mixed-operand program the same way. Its arithmetic sites take
    //              the polymorphic tag branch, whose cold arm pulls in the freestanding
    //              full-lookup dispatch and its named miss trap.
    const mixed_build = b.addRunArtifact(host_exe);
    mixed_build.setName("baremetal aot build: mixed-operand");
    mixed_build.addArg("build");
    mixed_build.addArg("--target=riscv64-freestanding-none");
    mixed_build.addArg("--interpreter-fallback=false");
    mixed_build.addPrefixedFileArg("--linker-script=", b.path("src/baremetal/riscv64/virt/linker.ld"));
    mixed_build.addPrefixedFileArg("--link-object=", entry_lib.getEmittedBin());
    mixed_build.addPrefixedFileArg("--link-object=", platform_lib.getEmittedBin());
    mixed_build.addPrefixedFileArg("--link-object=", runtime_lib.getEmittedBin());
    mixed_build.addArg("-o");
    const mixed_elf = mixed_build.addOutputFileArg("1z-mixed-operand.elf");
    mixed_build.addFileArg(b.path("tests/baremetal/riscv64/mixed_operand.1z"));

    const mixed_verify = b.addSystemCommand(&.{ "sh", "-c", baremetal_verify_script, "baremetal-verify" });
    mixed_verify.addFileArg(mixed_elf);
    mixed_verify.setName("baremetal aot verify: mixed-operand symbols and no libc");
    mixed_verify.expectExitCode(0);

    const install_mixed = b.addInstallFile(mixed_elf, "baremetal/riscv64/1z-mixed-operand.elf");

    const test_step = b.step("baremetal-riscv64-test", "Compile riscv64 virt platform library, stubs, and AOT freestanding ELFs");
    test_step.dependOn(&platform_lib.step);
    test_step.dependOn(&runtime_lib.step);
    test_step.dependOn(&entry_lib.step);
    test_step.dependOn(&uart_stub.step);
    test_step.dependOn(&runtime_stub.step);
    test_step.dependOn(&verify.step);
    test_step.dependOn(&install_hello.step);
    test_step.dependOn(&dispatch_verify.step);
    test_step.dependOn(&install_dispatch.step);
    test_step.dependOn(&mixed_verify.step);
    test_step.dependOn(&install_mixed.step);

    return test_step;
}

// Resolves its own wasm32-freestanding target and always embeds the real stdlib, so `zig build
// wasm` works standalone with no top-level flags.
fn addWasmBuild(b: *std.Build, optimize: std.builtin.OptimizeMode, options: *std.Build.Step.Options) *std.Build.Step {
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_embedded_stdlib_path = generateEmbeddedStdlib(b, true);
    const wasm_module = createCommonModule(b, wasm_target, optimize, options, b.path("src/capi_wasm.zig"), wasm_embedded_stdlib_path);

    const wasm_exe = b.addExecutable(.{
        .name = "1z",
        .root_module = wasm_module,
    });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;

    const install_wasm = b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });

    const wasm_step = b.step("wasm", "Build the wasm32-freestanding browser REPL module");
    wasm_step.dependOn(&install_wasm.step);
    return wasm_step;
}

const baremetal_verify_script =
    \\set -e
    \\elf="$1"
    \\for sym in _start kernel_main onez_baremetal_main onez_virt_uart_writer; do
    \\    if ! nm "$elf" | grep -qE "[Tt] $sym$"; then
    \\        echo "FAIL: linked ELF is missing symbol '$sym'"
    \\        nm "$elf" | grep -E "$sym" || true
    \\        exit 1
    \\    fi
    \\done
    \\banned=$(nm -u "$elf" 2>/dev/null | grep -E '(printf|fprintf|malloc|free|getenv|fopen|fwrite|memcpy|memset|memmove|memcmp)' || true)
    \\if [ -n "$banned" ]; then
    \\    echo "FAIL: linked ELF references hosted libc symbols:"
    \\    echo "$banned"
    \\    exit 1
    \\fi
    \\echo "PASS: linked freestanding ELF carries _start/kernel_main/onez_baremetal_main/onez_virt_uart_writer and no hosted libc imports"
;

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
    const StdioExpectMode = enum {
        diff_capture,
        direct_expect,
    };

    const Metadata = struct {
        stdio_expect: StdioExpectMode = .diff_capture,
        serial: bool = false,
        direct_run: bool = false,
    };

    name_without_ext: []const u8,
    file_path: []const u8,
    stdout_golden_path: []const u8,
    args_path: []const u8,
    args_lines: ?[]const u8,
    has_args: bool,
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
    stdio_expect_mode: StdioExpectMode,
    serial: bool,
    direct_run: bool,
};

fn collectTestEntries(b: *std.Build, test_dir: *std.fs.Dir) ![]const TestEntry {
    var entries: std.ArrayListUnmanaged(TestEntry) = .{};

    var iter = test_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".1z")) continue;

        const name_without_ext = b.dupe(entry.name[0 .. entry.name.len - 3]);
        const file_path = b.fmt("tests/integration/{s}", .{entry.name});
        const stdout_golden_path = b.fmt("tests/integration/{s}.stdout.golden", .{name_without_ext});
        const zon_path = b.fmt("tests/integration/{s}.zon", .{name_without_ext});

        const args_path = b.fmt("tests/integration/{s}.args", .{name_without_ext});
        var args_lines: ?[]const u8 = null;
        var has_args = false;
        if (test_dir.openFile(b.fmt("{s}.args", .{name_without_ext}), .{})) |file| {
            defer file.close();
            args_lines = file.readToEndAlloc(b.allocator, 1024 * 1024) catch null;
            has_args = true;
        } else |_| {}

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

        var stdio_expect_mode: TestEntry.StdioExpectMode = .diff_capture;
        var serial = false;
        var direct_run = false;
        if (test_dir.openFile(b.fmt("{s}.zon", .{name_without_ext}), .{})) |file| {
            defer file.close();
            const zon_content = file.readToEndAlloc(b.allocator, 4096) catch return error.OutOfMemory;
            const zon_content_z = b.allocator.dupeZ(u8, zon_content) catch return error.OutOfMemory;
            var diag: std.zon.parse.Diagnostics = .{};
            defer diag.deinit(b.allocator);

            const metadata = std.zon.parse.fromSlice(TestEntry.Metadata, b.allocator, zon_content_z, &diag, .{}) catch |err| {
                switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ParseZon => {
                        std.debug.print("Error parsing {s}\n", .{zon_path});
                        var stderr_buffer: [4096]u8 = undefined;
                        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
                        diag.format(&stderr_writer.interface) catch {};
                        stderr_writer.interface.flush() catch {};
                        return err;
                    },
                }
            };
            stdio_expect_mode = metadata.stdio_expect;
            serial = metadata.serial;
            direct_run = metadata.direct_run;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        entries.append(b.allocator, .{
            .name_without_ext = name_without_ext,
            .file_path = file_path,
            .stdout_golden_path = stdout_golden_path,
            .args_path = args_path,
            .args_lines = args_lines,
            .has_args = has_args,
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
            .stdio_expect_mode = stdio_expect_mode,
            .serial = serial,
            .direct_run = direct_run,
        }) catch return error.OutOfMemory;
    }

    return entries.items;
}

fn matchesFilter(name: []const u8, filter: []const u8) bool {
    var iter = std.mem.splitScalar(u8, filter, ',');
    while (iter.next()) |pattern| {
        const trimmed = std.mem.trim(u8, pattern, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOf(u8, name, trimmed) != null) return true;
    }
    return false;
}

fn hasExcludedJitFlag(flags_lines: ?[]const u8) bool {
    const fl = flags_lines orelse return false;
    var flag_iter = std.mem.splitScalar(u8, fl, '\n');
    while (flag_iter.next()) |flag| {
        const trimmed = std.mem.trim(u8, flag, " \t\r");
        if (std.mem.eql(u8, trimmed, "--debug") or
            std.mem.eql(u8, trimmed, "--no-jit") or
            std.mem.startsWith(u8, trimmed, "--trace-") or
            std.mem.startsWith(u8, trimmed, "--break=") or
            std.mem.startsWith(u8, trimmed, "--dump-scope=") or
            std.mem.startsWith(u8, trimmed, "--dump-jit-"))
        {
            return true;
        }
    }
    return false;
}

fn isSubcommandWord(line: []const u8) bool {
    return std.mem.eql(u8, line, "run") or
        std.mem.eql(u8, line, "eval") or
        std.mem.eql(u8, line, "test") or
        std.mem.eql(u8, line, "check") or
        std.mem.eql(u8, line, "repl") or
        std.mem.eql(u8, line, "version") or
        std.mem.eql(u8, line, "fmt") or
        std.mem.eql(u8, line, "lint") or
        std.mem.eql(u8, line, "build");
}

fn flagsContainRaw(flags_lines: ?[]const u8) bool {
    const fl = flags_lines orelse return false;
    var flag_iter = std.mem.splitScalar(u8, fl, '\n');
    while (flag_iter.next()) |flag| {
        const trimmed = std.mem.trim(u8, flag, " \t\r");
        if (std.mem.eql(u8, trimmed, "@raw")) return true;
    }
    return false;
}

fn flagsContainSubcommand(flags_lines: ?[]const u8, sub: []const u8) bool {
    const fl = flags_lines orelse return false;
    var flag_iter = std.mem.splitScalar(u8, fl, '\n');
    while (flag_iter.next()) |flag| {
        const trimmed = std.mem.trim(u8, flag, " \t\r");
        if (std.mem.eql(u8, trimmed, sub)) return true;
    }
    return false;
}

fn envLinesSetKey(env_lines: ?[]const u8, key: []const u8) bool {
    const el = env_lines orelse return false;
    var env_iter = std.mem.splitScalar(u8, el, '\n');
    while (env_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (std.mem.eql(u8, trimmed[0..eq_pos], key)) return true;
    }
    return false;
}

fn hasTestTimeoutFlag(flags_lines: ?[]const u8) bool {
    const fl = flags_lines orelse return false;
    var flag_iter = std.mem.splitScalar(u8, fl, '\n');
    while (flag_iter.next()) |flag| {
        const trimmed = std.mem.trim(u8, flag, " \t\r");
        if (std.mem.eql(u8, trimmed, "--test-timeout") or std.mem.startsWith(u8, trimmed, "--test-timeout=")) {
            return true;
        }
    }
    return false;
}

fn hasThreadsFlag(flags_lines: ?[]const u8) bool {
    const fl = flags_lines orelse return false;
    var flag_iter = std.mem.splitScalar(u8, fl, '\n');
    while (flag_iter.next()) |flag| {
        const trimmed = std.mem.trim(u8, flag, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "--threads=")) return true;
    }
    return false;
}

fn testTimeoutSeconds(flags_lines: ?[]const u8) ?u32 {
    const fl = flags_lines orelse return null;
    var flag_iter = std.mem.splitScalar(u8, fl, '\n');
    while (flag_iter.next()) |flag| {
        const trimmed = std.mem.trim(u8, flag, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "--test-timeout=")) {
            return std.fmt.parseInt(u32, trimmed["--test-timeout=".len..], 10) catch null;
        }
    }
    return null;
}

fn envFlagIsSet(b: *std.Build, name: []const u8) bool {
    const value = b.graph.env_map.get(name) orelse return false;
    return value.len != 0 and !std.mem.eql(u8, value, "0");
}

/// Best-effort capture of the toolchain's current git commit. Returns
/// the empty string when git is unavailable, the source tree is not a
/// git checkout, or the command fails for any other reason; the build
/// must not fail because provenance metadata could not be captured.
fn captureGitCommit(b: *std.Build) []const u8 {
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "git", "rev-parse", "HEAD" },
        .cwd = b.build_root.path,
    }) catch return "";
    defer b.allocator.free(result.stderr);
    defer b.allocator.free(result.stdout);
    if (result.term != .Exited or result.term.Exited != 0) return "";
    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (trimmed.len == 0) return "";
    return b.allocator.dupe(u8, trimmed) catch "";
}

fn addWrappedCommand(
    b: *std.Build,
    helper: *std.Build.Step.Compile,
    label: []const u8,
    timeout_secs: u32,
    print_slow: bool,
    slow_ms: u64,
    stdin_file: ?std.Build.LazyPath,
    status_files: *std.ArrayListUnmanaged(std.Build.LazyPath),
    extra_inputs: []const std.Build.LazyPath,
    stderr_on_failure: bool,
) *std.Build.Step.Run {
    const run = std.Build.Step.Run.create(b, label);
    run.addArtifactArg(helper);
    run.addArg("run");
    run.addArg("--label");
    run.addArg(label);
    run.addArg("--timeout-secs");
    run.addArg(b.fmt("{d}", .{timeout_secs}));
    run.addArg("--slow-ms");
    run.addArg(b.fmt("{d}", .{slow_ms}));
    if (print_slow) {
        run.addArg("--print-slow");
    }
    if (stderr_on_failure) {
        run.addArg("--stderr-on-failure");
    }
    run.addArg("--status-file");
    const status_file = run.addOutputFileArg(b.fmt("status_{d}.tsv", .{status_files.items.len}));
    status_files.append(b.allocator, status_file) catch @panic("OOM");
    if (stdin_file) |file| {
        run.addArg("--stdin-file");
        run.addFileArg(file);
    }
    run.addArg("--");
    for (extra_inputs) |input| run.addFileInput(input);
    run.setName(label);
    return run;
}

fn addVerboseSummary(
    b: *std.Build,
    helper: *std.Build.Step.Compile,
    test_step: *std.Build.Step,
    suite_name: []const u8,
    status_files: []const std.Build.LazyPath,
) void {
    if (status_files.len == 0) return;
    const summary = std.Build.Step.Run.create(b, b.fmt("{s} summary", .{suite_name}));
    summary.addArtifactArg(helper);
    summary.addArg("summarize");
    for (status_files) |status_file| {
        summary.addFileArg(status_file);
    }
    test_step.dependOn(&summary.step);
}

fn addIntegrationTests(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    helper: *std.Build.Step.Compile,
    test_step: *std.Build.Step,
    update_files: ?**std.Build.Step.UpdateSourceFiles,
    status_files: *std.ArrayListUnmanaged(std.Build.LazyPath),
    test_entries: []const TestEntry,
    has_diff: bool,
    jit_mode: bool,
    timeout_secs: u32,
    verbose_test_reporting: bool,
    slow_test_threshold_ms: u64,
    test_filter: ?[]const u8,
    test_threads: []const u8,
) void {
    var previous_serial_test_run: ?*std.Build.Step = null;
    var matched_count: usize = 0;
    var previous_serial_update_run: ?*std.Build.Step = null;

    for (test_entries) |te| {
        if (test_filter) |filter| {
            if (!matchesFilter(te.name_without_ext, filter)) continue;
        }
        if (jit_mode and hasExcludedJitFlag(te.flags_lines)) continue;
        if (jit_mode and flagsContainSubcommand(te.flags_lines, "check")) continue;
        if (jit_mode and flagsContainRaw(te.flags_lines)) continue;
        matched_count += 1;

        const label = if (jit_mode)
            b.fmt("eager integration: {s}", .{te.name_without_ext})
        else
            b.fmt("integration: {s}", .{te.name_without_ext});
        const effective_timeout_secs = testTimeoutSeconds(te.flags_lines) orelse timeout_secs;
        const wrapper_timeout_secs = effective_timeout_secs +| 1;
        const test_run = if (te.direct_run)
            b.addRunArtifact(artifact)
        else
            addWrappedCommand(
                b,
                helper,
                label,
                wrapper_timeout_secs,
                verbose_test_reporting,
                slow_test_threshold_ms,
                if (te.has_stdin) b.path(te.stdin_path) else null,
                status_files,
                &.{artifact.getEmittedBin()},
                false,
            );
        if (!te.direct_run) {
            test_run.addArtifactArg(artifact);
        } else if (te.has_stdin) {
            test_run.setStdIn(.{ .bytes = te.stdin_content });
        }
        test_run.setName(label);
        if (te.serial) {
            if (previous_serial_test_run) |prev| {
                test_run.step.dependOn(prev);
            }
            previous_serial_test_run = &test_run.step;
        }
        configureIntegrationRun(b, test_run, te, timeout_secs, jit_mode, test_threads, artifact);

        if (te.has_stderr_golden) {
            test_run.addFileInput(b.path(te.stderr_golden_path));
        }
        if (te.has_stdout_golden) {
            test_run.addFileInput(b.path(te.stdout_golden_path));
        }

        test_run.expectExitCode(te.expected_exit_code orelse 0);

        if (has_diff and te.stdio_expect_mode == .diff_capture) {
            addGoldenDiff(b, test_step, test_run.captureStdOut(), if (te.has_stdout_golden) te.stdout_golden_path else null, te.file_path);
            addGoldenDiff(b, test_step, normalizeStderr(b, test_run.captureStdErr()), if (te.has_stderr_golden) te.stderr_golden_path else null, te.file_path);
        } else {
            if (te.has_stdout_golden) {
                test_run.expectStdOutEqual(te.stdout_content);
            } else {
                test_run.expectStdOutEqual("");
            }
            if (te.has_stderr_golden) {
                const normalize = b.addSystemCommand(&.{ "sed", stderr_normalize_script });
                normalize.addFileArg(test_run.captureStdErr());
                normalize.expectStdOutEqual(te.stderr_content);
                test_step.dependOn(&normalize.step);
            } else {
                test_run.expectStdErrEqual("");
            }
            test_step.dependOn(&test_run.step);
        }

        // Update golden (only for non-JIT mode)
        if (update_files) |uf_ptr| {
            const update_label = b.fmt("update-golden: {s}", .{te.name_without_ext});
            const update_timeout_secs = effective_timeout_secs +| 1;
            const update_run = std.Build.Step.Run.create(b, update_label);
            update_run.addArtifactArg(helper);
            update_run.addArg("run");
            update_run.addArg("--label");
            update_run.addArg(update_label);
            update_run.addArg("--timeout-secs");
            update_run.addArg(b.fmt("{d}", .{update_timeout_secs}));
            update_run.addArg("--slow-ms");
            update_run.addArg(b.fmt("{d}", .{slow_test_threshold_ms}));
            update_run.addArg("--print-slow");
            update_run.addArg("--status-file");
            update_run.addArg(b.fmt("/tmp/1z-update-golden-{s}.status.tsv", .{te.name_without_ext}));
            if (te.serial) {
                if (previous_serial_update_run) |prev| {
                    update_run.step.dependOn(prev);
                }
                previous_serial_update_run = &update_run.step;
            }
            if (te.has_stdin) {
                update_run.addArg("--stdin-file");
                update_run.addFileArg(b.path(te.stdin_path));
            }
            update_run.addArg("--");
            update_run.addFileInput(artifact.getEmittedBin());
            update_run.addArtifactArg(artifact);
            configureIntegrationRun(b, update_run, te, timeout_secs, false, test_threads, artifact);
            uf_ptr.*.addCopyFileToSource(update_run.captureStdOut(), te.stdout_golden_path);

            const update_exit_code = te.expected_exit_code orelse 0;
            if (update_exit_code != 0) {
                update_run.expectExitCode(update_exit_code);
            }
            if (te.has_stderr_golden or update_exit_code != 0 or te.has_exitcode) {
                uf_ptr.*.addCopyFileToSource(normalizeStderr(b, update_run.captureStdErr()), te.stderr_golden_path);
            }
        }
    }

    if (test_filter) |filter| {
        const label = if (jit_mode) "eager integration" else "integration";
        const summary_cmd = b.addSystemCommand(&.{ "echo", b.fmt("Filter active: {d}/{d} {s} tests match '{s}'", .{ matched_count, test_entries.len, label, filter }) });
        test_step.dependOn(&summary_cmd.step);
    }
}

const AotEnvEntry = struct {
    key: []const u8,
    value: []const u8,
};

const AotReachEntry = struct {
    feature: []const u8,
    golden_path: []const u8,
    content: []const u8,
    has_golden: bool,
    reach_features_path: []const u8,
};

const AotTestEntry = struct {
    name_without_ext: []const u8,
    file_path: []const u8,
    has_build_stdout_golden: bool,
    build_stdout_golden_path: []const u8,
    build_stdout_content: []const u8,
    has_build_stderr_golden: bool,
    build_stderr_golden_path: []const u8,
    build_stderr_content: []const u8,
    has_build_exitcode: bool,
    build_exitcode_path: []const u8,
    expected_build_exit_code: ?u8,
    has_stdout_golden: bool,
    stdout_golden_path: []const u8,
    stdout_content: []const u8,
    has_stderr_golden: bool,
    stderr_golden_path: []const u8,
    stderr_content: []const u8,
    has_exitcode: bool,
    exitcode_path: []const u8,
    expected_exit_code: ?u8,
    has_inspect_stdout_golden: bool,
    inspect_stdout_golden_path: []const u8,
    inspect_stdout_content: []const u8,
    reach_entries: []const AotReachEntry,
    build_flags: []const []const u8,
    build_flags_path: []const u8,
    env_entries: []const AotEnvEntry,
    env_path: []const u8,
    flags_lines: ?[]const u8,
    flags_path: []const u8,
    /// True for a `.source`-redirected entry, whose stderr golden and exit code live beside the
    /// redirected file and are owned by that suite.
    ///
    /// `update-aot-golden` never rewrites a shared golden, so a divergence fails this suite as the
    /// parity check.
    ///
    /// The per-entry stdout golden is still updated: stdout is never shared, because the
    /// integration harness injects `--show-stack`.
    golden_shared: bool,
    /// True for a redirect entry carrying a hand-written `.exitcode` beside its `.source` sidecar.
    ///
    /// The marker pins a rendering that diverges from the redirected suite's: the stderr golden
    /// and exit code switch to per-entry files in tests/aot, and `update-aot-golden` owns that
    /// stderr golden. Deleting the `.exitcode` and `.stderr.golden` pair restores the shared
    /// binding.
    override_pinned: bool,
};

fn collectAotTestEntries(b: *std.Build, aot_dir: *std.fs.Dir) ![]const AotTestEntry {
    var entries: std.ArrayListUnmanaged(AotTestEntry) = .{};

    var iter = aot_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const is_redirect = std.mem.endsWith(u8, entry.name, ".source");
        if (!is_redirect and !std.mem.endsWith(u8, entry.name, ".1z")) continue;

        const ext_len: usize = if (is_redirect) ".source".len else ".1z".len;
        const name_without_ext = b.dupe(entry.name[0 .. entry.name.len - ext_len]);

        // A `.source` sidecar holds a build-root-relative path to a test file owned by another
        // suite. The entry builds that file and diffs stderr and exit code against the sidecars
        // beside it, so one golden serves both suites.
        //
        // A hand-written `.exitcode` beside the `.source` sidecar overrides that sharing; see
        // `override_pinned`.
        //
        // Stdout is not shareable: the integration harness injects `--show-stack`, whose output a
        // standalone binary never prints, so stdout stays keyed in tests/aot.
        var file_path = b.fmt("tests/aot/{s}", .{entry.name});
        var run_golden_base = b.fmt("tests/aot/{s}", .{name_without_ext});
        var override_pinned = false;
        if (is_redirect) {
            const raw = blk: {
                const file = aot_dir.openFile(entry.name, .{}) catch break :blk "";
                defer file.close();
                break :blk file.readToEndAlloc(b.allocator, 4096) catch "";
            };
            const redirected = std.mem.trim(u8, raw, " \t\r\n");
            if (!std.mem.endsWith(u8, redirected, ".1z")) {
                std.debug.print("Warning: tests/aot/{s} does not name a .1z file; skipping\n", .{entry.name});
                continue;
            }
            file_path = b.dupe(redirected);
            run_golden_base = b.dupe(redirected[0 .. redirected.len - 3]);

            if (aot_dir.access(b.fmt("{s}.exitcode", .{name_without_ext}), .{})) |_| {
                override_pinned = true;
                run_golden_base = b.fmt("tests/aot/{s}", .{name_without_ext});
            } else |_| {}
        }

        var has_build_stdout_golden = false;
        var build_stdout_content: []const u8 = "";
        const build_stdout_golden_path = b.fmt("tests/aot/{s}.build.stdout.golden", .{name_without_ext});
        if (aot_dir.openFile(b.fmt("{s}.build.stdout.golden", .{name_without_ext}), .{})) |file| {
            defer file.close();
            build_stdout_content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            has_build_stdout_golden = true;
        } else |_| {}

        var has_build_stderr_golden = false;
        var build_stderr_content: []const u8 = "";
        const build_stderr_golden_path = b.fmt("tests/aot/{s}.build.stderr.golden", .{name_without_ext});
        if (aot_dir.openFile(b.fmt("{s}.build.stderr.golden", .{name_without_ext}), .{})) |file| {
            defer file.close();
            build_stderr_content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            has_build_stderr_golden = true;
        } else |_| {}

        var has_build_exitcode = false;
        var expected_build_exit_code: ?u8 = null;
        const build_exitcode_path = b.fmt("tests/aot/{s}.build.exitcode", .{name_without_ext});
        if (aot_dir.openFile(b.fmt("{s}.build.exitcode", .{name_without_ext}), .{})) |file| {
            defer file.close();
            has_build_exitcode = true;
            const code_str = file.readToEndAlloc(b.allocator, 64) catch "";
            const trimmed_code = std.mem.trim(u8, code_str, " \t\r\n");
            if (trimmed_code.len > 0) {
                expected_build_exit_code = std.fmt.parseInt(u8, trimmed_code, 10) catch null;
            }
        } else |_| {}

        var has_stdout_golden = false;
        var stdout_content: []const u8 = "";
        const stdout_golden_path = b.fmt("tests/aot/{s}.stdout.golden", .{name_without_ext});
        if (aot_dir.openFile(b.fmt("{s}.stdout.golden", .{name_without_ext}), .{})) |file| {
            defer file.close();
            stdout_content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            has_stdout_golden = true;
        } else |_| {}

        var has_stderr_golden = false;
        var stderr_content: []const u8 = "";
        const stderr_golden_path = b.fmt("{s}.stderr.golden", .{run_golden_base});
        if (b.build_root.handle.openFile(stderr_golden_path, .{})) |file| {
            defer file.close();
            stderr_content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            has_stderr_golden = true;
        } else |_| {}

        var has_exitcode = false;
        var expected_exit_code: ?u8 = null;
        const exitcode_path = b.fmt("{s}.exitcode", .{run_golden_base});
        if (b.build_root.handle.openFile(exitcode_path, .{})) |file| {
            defer file.close();
            has_exitcode = true;
            const code_str = file.readToEndAlloc(b.allocator, 64) catch "";
            const trimmed_code = std.mem.trim(u8, code_str, " \t\r\n");
            if (trimmed_code.len > 0) {
                expected_exit_code = std.fmt.parseInt(u8, trimmed_code, 10) catch null;
            }
        } else |_| {}

        var has_inspect_stdout_golden = false;
        var inspect_stdout_content: []const u8 = "";
        const inspect_stdout_golden_path = b.fmt("tests/aot/{s}.inspect.stdout.golden", .{name_without_ext});
        if (aot_dir.openFile(b.fmt("{s}.inspect.stdout.golden", .{name_without_ext}), .{})) |file| {
            defer file.close();
            inspect_stdout_content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            has_inspect_stdout_golden = true;
        } else |_| {}

        var reach_entries: std.ArrayListUnmanaged(AotReachEntry) = .{};
        const reach_features_path = b.fmt("tests/aot/{s}.reach-features", .{name_without_ext});
        if (aot_dir.openFile(b.fmt("{s}.reach-features", .{name_without_ext}), .{})) |features_file| {
            defer features_file.close();
            const features_content = features_file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            var lines = std.mem.splitScalar(u8, features_content, '\n');
            while (lines.next()) |line| {
                const feature = std.mem.trim(u8, line, " \t\r");
                if (feature.len == 0 or feature[0] == '#') continue;
                const golden_name = b.fmt("{s}.reach-{s}.stdout.golden", .{ name_without_ext, feature });
                const golden_path = b.fmt("tests/aot/{s}", .{golden_name});
                var has_golden = false;
                var golden_content: []const u8 = "";
                if (aot_dir.openFile(golden_name, .{})) |golden_file| {
                    defer golden_file.close();
                    golden_content = golden_file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
                    has_golden = true;
                } else |_| {}
                reach_entries.append(b.allocator, .{
                    .feature = b.dupe(feature),
                    .golden_path = golden_path,
                    .content = golden_content,
                    .has_golden = has_golden,
                    .reach_features_path = reach_features_path,
                }) catch {};
            }
        } else |_| {}

        var build_flags: std.ArrayListUnmanaged([]const u8) = .{};
        const build_flags_path = b.fmt("tests/aot/{s}.build-flags", .{name_without_ext});
        if (aot_dir.openFile(b.fmt("{s}.build-flags", .{name_without_ext}), .{})) |file| {
            defer file.close();
            const content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len > 0) {
                    build_flags.append(b.allocator, trimmed) catch {};
                }
            }
        } else |_| {}

        var env_entries: std.ArrayListUnmanaged(AotEnvEntry) = .{};
        const env_path = b.fmt("tests/aot/{s}.env", .{name_without_ext});
        if (aot_dir.openFile(b.fmt("{s}.env", .{name_without_ext}), .{})) |file| {
            defer file.close();
            const content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;
                if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_idx| {
                    env_entries.append(b.allocator, .{
                        .key = trimmed[0..eq_idx],
                        .value = trimmed[eq_idx + 1 ..],
                    }) catch {};
                }
            }
        } else |_| {}

        // The `.flags` sidecar is parsed only for `--test-timeout=N`, which
        // raises this test's run-wrapper timeout. The flags are not passed to
        // the standalone binary, which takes no such argument.
        var flags_lines: ?[]const u8 = null;
        const flags_path = b.fmt("tests/aot/{s}.flags", .{name_without_ext});
        if (aot_dir.openFile(b.fmt("{s}.flags", .{name_without_ext}), .{})) |file| {
            defer file.close();
            flags_lines = file.readToEndAlloc(b.allocator, 1024 * 1024) catch null;
        } else |_| {}

        entries.append(b.allocator, .{
            .name_without_ext = name_without_ext,
            .file_path = file_path,
            .has_build_stdout_golden = has_build_stdout_golden,
            .build_stdout_golden_path = build_stdout_golden_path,
            .build_stdout_content = build_stdout_content,
            .has_build_stderr_golden = has_build_stderr_golden,
            .build_stderr_golden_path = build_stderr_golden_path,
            .build_stderr_content = build_stderr_content,
            .has_build_exitcode = has_build_exitcode,
            .build_exitcode_path = build_exitcode_path,
            .expected_build_exit_code = expected_build_exit_code,
            .has_stdout_golden = has_stdout_golden,
            .stdout_golden_path = stdout_golden_path,
            .stdout_content = stdout_content,
            .has_stderr_golden = has_stderr_golden,
            .stderr_golden_path = stderr_golden_path,
            .stderr_content = stderr_content,
            .has_exitcode = has_exitcode,
            .exitcode_path = exitcode_path,
            .expected_exit_code = expected_exit_code,
            .has_inspect_stdout_golden = has_inspect_stdout_golden,
            .inspect_stdout_golden_path = inspect_stdout_golden_path,
            .inspect_stdout_content = inspect_stdout_content,
            .reach_entries = reach_entries.items,
            .build_flags = build_flags.items,
            .build_flags_path = build_flags_path,
            .env_entries = env_entries.items,
            .env_path = env_path,
            .flags_lines = flags_lines,
            .flags_path = flags_path,
            .golden_shared = is_redirect,
            .override_pinned = override_pinned,
        }) catch return error.OutOfMemory;
    }

    return entries.items;
}

fn addAotTests(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    helper: *std.Build.Step.Compile,
    test_step: *std.Build.Step,
    update_files: **std.Build.Step.UpdateSourceFiles,
    status_files: *std.ArrayListUnmanaged(std.Build.LazyPath),
    aot_entries: []const AotTestEntry,
    has_diff: bool,
    timeout_secs: u32,
    build_timeout_secs: u32,
    verbose_test_reporting: bool,
    slow_test_threshold_ms: u64,
    test_filter: ?[]const u8,
) void {
    const exe_path = b.fmt("{s}/bin/1z", .{b.install_path});
    var matched_count: usize = 0;

    for (aot_entries) |te| {
        if (test_filter) |filter| {
            if (!matchesFilter(te.name_without_ext, filter)) continue;
        }
        matched_count += 1;
        const is_build_only = te.has_build_stdout_golden or te.has_build_stderr_golden or te.has_build_exitcode;
        const expected_build_exit: u8 = te.expected_build_exit_code orelse 0;
        const expected_exit: u8 = te.expected_exit_code orelse 0;

        // Compile: 1z build <file.1z> -o <output>
        //
        // AOT builds are categorically heavier than runs (freeze, C emission, C compilation), so
        // they get their own timeout budget rather than the per-case run timeout.
        const compile_label = b.fmt("aot build: {s}", .{te.name_without_ext});
        const compile_run = addWrappedCommand(
            b,
            helper,
            compile_label,
            build_timeout_secs,
            verbose_test_reporting,
            slow_test_threshold_ms,
            null,
            status_files,
            &.{artifact.getEmittedBin()},
            !is_build_only,
        );
        compile_run.addArg(exe_path);
        compile_run.setName(compile_label);
        compile_run.addArg("build");
        compile_run.addArg(b.fmt("--stdlib-path={s}/lib", .{b.build_root.path orelse "."}));
        compile_run.addFileArg(b.path(te.file_path));
        compile_run.addArg("-o");
        const aot_binary = compile_run.addOutputFileArg(b.fmt("aot_{s}", .{te.name_without_ext}));
        compile_run.expectExitCode(if (is_build_only) expected_build_exit else 0);
        compile_run.step.dependOn(b.getInstallStep());
        compile_run.addFileInput(artifact.getEmittedBin());

        addCommonFileDeps(b, compile_run);
        for (te.build_flags) |flag| compile_run.addArg(flag);
        if (te.build_flags.len > 0) compile_run.addFileInput(b.path(te.build_flags_path));

        const build_succeeds = !(is_build_only and expected_build_exit != 0);

        if (te.has_inspect_stdout_golden and build_succeeds) {
            const inspect_run = b.addSystemCommand(&.{ exe_path, "inspect" });
            inspect_run.addFileArg(aot_binary);
            inspect_run.step.dependOn(b.getInstallStep());
            inspect_run.addFileInput(artifact.getEmittedBin());
            inspect_run.expectExitCode(0);

            const normalize_inspect = b.addSystemCommand(&.{
                "sed",
                "-e",
                "s|^target: .*|target: <target>|",
                "-e",
                "s|^build-mode: .*|build-mode: <build-mode>|",
                "-e",
                "s|^1z-version: .*|1z-version: <version>|",
                "-e",
                "s|^prelude-hash: .*|prelude-hash: <prelude-hash>|",
                "-e",
                "/^1z-git-commit:/d",
                "-e",
                "/^zig-version:/d",
                "-e",
                "/^c-compiler-id:/d",
                "-e",
                "/^c-compiler-version:/d",
            });
            normalize_inspect.addFileArg(inspect_run.captureStdOut());

            if (has_diff) {
                addGoldenDiff(b, test_step, normalize_inspect.captureStdOut(), te.inspect_stdout_golden_path, te.file_path);
            } else {
                normalize_inspect.expectStdOutEqual(te.inspect_stdout_content);
                test_step.dependOn(&normalize_inspect.step);
            }

            const update_compile_inspect = b.addSystemCommand(&.{exe_path});
            update_compile_inspect.addArg("build");
            update_compile_inspect.addArg(b.fmt("--stdlib-path={s}/lib", .{b.build_root.path orelse "."}));
            update_compile_inspect.addFileArg(b.path(te.file_path));
            update_compile_inspect.addArg("-o");
            const update_inspect_binary = update_compile_inspect.addOutputFileArg(b.fmt("aot_inspect_{s}", .{te.name_without_ext}));
            update_compile_inspect.step.dependOn(b.getInstallStep());
            update_compile_inspect.addFileInput(artifact.getEmittedBin());

            addCommonFileDeps(b, update_compile_inspect);
            for (te.build_flags) |flag| update_compile_inspect.addArg(flag);
            if (te.build_flags.len > 0) update_compile_inspect.addFileInput(b.path(te.build_flags_path));

            const update_inspect_run = b.addSystemCommand(&.{ exe_path, "inspect" });
            update_inspect_run.addFileArg(update_inspect_binary);
            update_inspect_run.step.dependOn(b.getInstallStep());
            update_inspect_run.addFileInput(artifact.getEmittedBin());

            const update_normalize_inspect = b.addSystemCommand(&.{
                "sed",
                "-e",
                "s|^target: .*|target: <target>|",
                "-e",
                "s|^build-mode: .*|build-mode: <build-mode>|",
                "-e",
                "s|^1z-version: .*|1z-version: <version>|",
                "-e",
                "s|^prelude-hash: .*|prelude-hash: <prelude-hash>|",
                "-e",
                "/^1z-git-commit:/d",
                "-e",
                "/^zig-version:/d",
                "-e",
                "/^c-compiler-id:/d",
                "-e",
                "/^c-compiler-version:/d",
            });
            update_normalize_inspect.addFileArg(update_inspect_run.captureStdOut());
            update_files.*.addCopyFileToSource(update_normalize_inspect.captureStdOut(), te.inspect_stdout_golden_path);
        }

        for (te.reach_entries) |re| {
            if (re.has_golden) {
                const reach_run = b.addSystemCommand(&.{ exe_path, "inspect", "--reach", re.feature });
                reach_run.addFileArg(b.path(te.file_path));
                reach_run.step.dependOn(b.getInstallStep());
                reach_run.addFileInput(artifact.getEmittedBin());
                reach_run.addFileInput(b.path(re.reach_features_path));
                reach_run.expectExitCode(0);
                addCommonFileDeps(b, reach_run);
                if (has_diff) {
                    addGoldenDiff(b, test_step, reach_run.captureStdOut(), re.golden_path, te.file_path);
                } else {
                    reach_run.expectStdOutEqual(re.content);
                    test_step.dependOn(&reach_run.step);
                }
            }

            const update_reach = b.addSystemCommand(&.{ exe_path, "inspect", "--reach", re.feature });
            update_reach.addFileArg(b.path(te.file_path));
            update_reach.step.dependOn(b.getInstallStep());
            update_reach.addFileInput(artifact.getEmittedBin());
            update_reach.addFileInput(b.path(re.reach_features_path));
            addCommonFileDeps(b, update_reach);
            update_files.*.addCopyFileToSource(update_reach.captureStdOut(), re.golden_path);
        }

        if (is_build_only) {
            if (has_diff) {
                addGoldenDiff(b, test_step, compile_run.captureStdOut(), if (te.has_build_stdout_golden) te.build_stdout_golden_path else null, te.file_path);

                const normalize_build_stderr = b.addSystemCommand(&.{
                    "sed", "/^error(gpa):/,$d",
                });
                normalize_build_stderr.addFileArg(compile_run.captureStdErr());
                addGoldenDiff(b, test_step, normalize_build_stderr.captureStdOut(), if (te.has_build_stderr_golden) te.build_stderr_golden_path else null, te.file_path);
            } else {
                if (te.has_build_stdout_golden) {
                    compile_run.expectStdOutEqual(te.build_stdout_content);
                } else {
                    compile_run.expectStdOutEqual("");
                }
                if (te.has_build_stderr_golden) {
                    const captured_build_stderr = compile_run.captureStdErr();
                    const normalize_build_stderr = b.addSystemCommand(&.{
                        "sed", "/^error(gpa):/,$d",
                    });
                    normalize_build_stderr.addFileArg(captured_build_stderr);
                    normalize_build_stderr.expectStdOutEqual(te.build_stderr_content);
                } else {
                    compile_run.expectStdErrEqual("");
                }
                test_step.dependOn(&compile_run.step);
            }

            {
                const update_compile = b.addSystemCommand(&.{exe_path});
                update_compile.addArg("build");
                update_compile.addArg(b.fmt("--stdlib-path={s}/lib", .{b.build_root.path orelse "."}));
                update_compile.addFileArg(b.path(te.file_path));
                update_compile.addArg("-o");
                _ = update_compile.addOutputFileArg(b.fmt("aot_{s}", .{te.name_without_ext}));
                update_compile.step.dependOn(b.getInstallStep());
                update_compile.addFileInput(artifact.getEmittedBin());

                addCommonFileDeps(b, update_compile);
                for (te.build_flags) |flag| update_compile.addArg(flag);
                if (te.build_flags.len > 0) update_compile.addFileInput(b.path(te.build_flags_path));
                if (expected_build_exit != 0) {
                    update_compile.expectExitCode(expected_build_exit);
                }

                update_files.*.addCopyFileToSource(update_compile.captureStdOut(), te.build_stdout_golden_path);
                if (te.has_build_stderr_golden or expected_build_exit != 0 or te.has_build_exitcode) {
                    const update_build_stderr = update_compile.captureStdErr();
                    const normalize_update_build_stderr = b.addSystemCommand(&.{
                        "sed", "/^error(gpa):/,$d",
                    });
                    normalize_update_build_stderr.addFileArg(update_build_stderr);
                    update_files.*.addCopyFileToSource(normalize_update_build_stderr.captureStdOut(), te.build_stderr_golden_path);
                }
            }
            continue;
        }

        // chmod +x the compiled binary
        const chmod = b.addSystemCommand(&.{ "chmod", "+x" });
        chmod.addFileArg(aot_binary);

        // Execute the compiled binary. A `.flags` sidecar may raise this
        // test's run-wrapper timeout via `--test-timeout=N` (wrapper gets the
        // +1 buffer that the integration harness uses); absent a sidecar the
        // global per-case timeout is unchanged.
        const run_timeout_secs = if (testTimeoutSeconds(te.flags_lines)) |t| t +| 1 else timeout_secs;
        const exec_label = b.fmt("aot run: {s}", .{te.name_without_ext});
        const exec_run = addWrappedCommand(
            b,
            helper,
            exec_label,
            run_timeout_secs,
            verbose_test_reporting,
            slow_test_threshold_ms,
            null,
            status_files,
            &.{aot_binary},
            false,
        );
        exec_run.addFileArg(aot_binary);
        exec_run.setName(exec_label);
        exec_run.step.dependOn(&chmod.step);
        exec_run.expectExitCode(expected_exit);
        for (te.env_entries) |env| exec_run.setEnvironmentVariable(env.key, env.value);
        if (te.env_entries.len > 0) exec_run.addFileInput(b.path(te.env_path));
        if (te.flags_lines != null) exec_run.addFileInput(b.path(te.flags_path));

        if (has_diff) {
            addGoldenDiff(b, test_step, exec_run.captureStdOut(), if (te.has_stdout_golden) te.stdout_golden_path else null, te.file_path);

            const normalize_stderr = b.addSystemCommand(&.{
                "sed", "s|[^ ]*\\.zig-cache[^ :]*|<aot>|g",
            });
            normalize_stderr.addFileArg(exec_run.captureStdErr());
            addGoldenDiff(b, test_step, normalize_stderr.captureStdOut(), if (te.has_stderr_golden) te.stderr_golden_path else null, te.file_path);
        } else {
            if (te.has_stdout_golden) {
                exec_run.expectStdOutEqual(te.stdout_content);
            } else {
                exec_run.expectStdOutEqual("");
            }
            // Stderr normalization requires sed; without diff, use sed + expectStdOutEqual
            if (te.has_stderr_golden) {
                const captured_stderr = exec_run.captureStdErr();
                const normalize_stderr = b.addSystemCommand(&.{
                    "sed", "s|[^ ]*\\.zig-cache[^ :]*|<aot>|g",
                });
                normalize_stderr.addFileArg(captured_stderr);
                normalize_stderr.expectStdOutEqual(te.stderr_content);
                test_step.dependOn(&normalize_stderr.step);
            } else {
                test_step.dependOn(&exec_run.step);
            }
        }

        // Update golden. A shared stderr golden is owned by the suite the `.source` sidecar
        // points into, so this suite rewrites stderr only for its own entries and for
        // override-pinned redirects. The per-entry stdout golden is always this suite's.
        {
            const update_compile = b.addSystemCommand(&.{exe_path});
            update_compile.addArg("build");
            update_compile.addArg(b.fmt("--stdlib-path={s}/lib", .{b.build_root.path orelse "."}));
            update_compile.addFileArg(b.path(te.file_path));
            update_compile.addArg("-o");
            const update_binary = update_compile.addOutputFileArg(b.fmt("aot_{s}", .{te.name_without_ext}));
            update_compile.step.dependOn(b.getInstallStep());
            update_compile.addFileInput(artifact.getEmittedBin());

            addCommonFileDeps(b, update_compile);
            for (te.build_flags) |flag| update_compile.addArg(flag);
            if (te.build_flags.len > 0) update_compile.addFileInput(b.path(te.build_flags_path));

            const update_chmod = b.addSystemCommand(&.{ "chmod", "+x" });
            update_chmod.addFileArg(update_binary);

            const update_exec = std.Build.Step.Run.create(b, b.fmt("update aot: {s}", .{te.name_without_ext}));
            update_exec.addFileArg(update_binary);
            update_exec.step.dependOn(&update_chmod.step);
            for (te.env_entries) |env| update_exec.setEnvironmentVariable(env.key, env.value);

            if (expected_exit != 0) {
                update_exec.expectExitCode(expected_exit);
            }

            update_files.*.addCopyFileToSource(update_exec.captureStdOut(), te.stdout_golden_path);

            const owns_stderr = if (te.golden_shared)
                te.override_pinned
            else
                te.has_stderr_golden or expected_exit != 0;
            if (owns_stderr) {
                const update_stderr = update_exec.captureStdErr();
                const update_normalize = b.addSystemCommand(&.{
                    "sed", "s|[^ ]*\\.zig-cache[^ :]*|<aot>|g",
                });
                update_normalize.addFileArg(update_stderr);
                update_files.*.addCopyFileToSource(update_normalize.captureStdOut(), te.stderr_golden_path);
            }
        }
    }

    if (test_filter) |filter| {
        const summary_cmd = b.addSystemCommand(&.{ "echo", b.fmt("Filter active: {d}/{d} aot tests match '{s}'", .{ matched_count, aot_entries.len, filter }) });
        test_step.dependOn(&summary_cmd.step);
    }
}

// The `.flags` sidecar drives how the harness invokes `1z`. A line equal
// to `@raw` puts the test in full control of argv: no default subcommand,
// no injected `--show-stack`/`--stdlib-path`/`--test-timeout`, and no file
// append. A literal `{file}` line is substituted with the resolved `.1z`
// file path. Otherwise, a line matching a subcommand word
// (run|eval|check|repl|version|fmt|build) sets the subcommand used by the
// harness; if no such line is present, the harness defaults to `run`.
//
// A line equal to `@self-exe` appends the interpreter artifact's own binary path as the final
// argv element, letting a test that spawns child interpreters read its own path from
// `command-line-args`.
fn configureIntegrationRun(
    b: *std.Build,
    run: *std.Build.Step.Run,
    te: TestEntry,
    timeout_secs: u32,
    jit_mode: bool,
    test_threads: []const u8,
    artifact: *std.Build.Step.Compile,
) void {
    // The suite must not read a developer's own startup file.
    //
    // This sets the variable rather than passing `--no-startup`. A test that spawns child
    // interpreters builds their argv by hand, so a flag would never reach them. A case naming
    // `ONEZ_STARTUP` in its `.env` supplies its own fixture, so the skip stays out of its way.
    if (!envLinesSetKey(te.env_lines, "ONEZ_STARTUP")) {
        run.setEnvironmentVariable("ONEZ_NO_STARTUP", "1");
    }

    var raw_mode = false;
    var detected_subcommand: ?[]const u8 = null;
    if (te.flags_lines) |fl| {
        var classify_iter = std.mem.splitScalar(u8, fl, '\n');
        while (classify_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (std.mem.eql(u8, trimmed, "@raw")) {
                raw_mode = true;
            } else if (detected_subcommand == null and isSubcommandWord(trimmed)) {
                detected_subcommand = trimmed;
            }
        }
    }

    if (raw_mode) {
        run.setEnvironmentVariable("ONEZ_STDLIB", b.fmt("{s}/lib", .{b.build_root.path orelse "."}));
        if (te.env_lines) |el| {
            var env_iter = std.mem.splitScalar(u8, el, '\n');
            while (env_iter.next()) |line| {
                const trimmed_line = std.mem.trim(u8, line, " \t\r");
                if (trimmed_line.len == 0) continue;
                if (std.mem.indexOfScalar(u8, trimmed_line, '=')) |eq_pos| {
                    run.setEnvironmentVariable(trimmed_line[0..eq_pos], trimmed_line[eq_pos + 1 ..]);
                }
            }
        }
        if (te.flags_lines) |fl| {
            var flag_iter = std.mem.splitScalar(u8, fl, '\n');
            while (flag_iter.next()) |flag| {
                const trimmed = std.mem.trim(u8, flag, " \t\r");
                if (trimmed.len == 0) continue;
                if (std.mem.eql(u8, trimmed, "@raw")) continue;
                if (std.mem.eql(u8, trimmed, "@self-exe")) continue;
                // A valid `--test-timeout=N` only drives the wrapper timeout
                // (computed separately via testTimeoutSeconds); it is not a
                // flag the raw subcommand accepts, so keep it out of the
                // assembled argv. An invalid value is left in place so a test
                // can verify that 1z itself rejects it.
                if (std.mem.startsWith(u8, trimmed, "--test-timeout=")) {
                    const parsed = std.fmt.parseInt(u32, trimmed["--test-timeout=".len..], 10) catch null;
                    if (parsed != null) continue;
                }
                if (std.mem.eql(u8, trimmed, "{file}")) {
                    run.addFileArg(b.path(te.file_path));
                } else {
                    run.addArg(trimmed);
                }
            }
        }
        if (flagsContainSubcommand(te.flags_lines, "@self-exe")) run.addArtifactArg(artifact);
        addCommonFileDeps(b, run);
        if (te.has_flags) run.addFileInput(b.path(te.flags_path));
        if (te.has_stdin) run.addFileInput(b.path(te.stdin_path));
        if (te.has_exitcode) run.addFileInput(b.path(te.exitcode_path));
        if (te.has_env) run.addFileInput(b.path(te.env_path));
        return;
    }

    run.addArg(detected_subcommand orelse "run");
    if (te.show_stack) {
        run.addArg("--show-stack");
    }
    run.addArg(b.fmt("--stdlib-path={s}/lib", .{b.build_root.path orelse "."}));
    if (jit_mode) {
        run.addArg("--compile=eager");
    }
    if (!hasTestTimeoutFlag(te.flags_lines)) {
        run.addArg(b.fmt("--test-timeout={d}", .{timeout_secs}));
    }
    if (!hasThreadsFlag(te.flags_lines) and !std.mem.eql(u8, test_threads, "auto")) {
        run.addArg(b.fmt("--threads={s}", .{test_threads}));
    }
    if (te.flags_lines) |fl| {
        var flag_iter = std.mem.splitScalar(u8, fl, '\n');
        while (flag_iter.next()) |flag| {
            const trimmed_flag = std.mem.trim(u8, flag, " \t\r");
            if (trimmed_flag.len == 0) continue;
            if (std.mem.eql(u8, trimmed_flag, "--no-show-stack")) continue;
            if (std.mem.eql(u8, trimmed_flag, "--no-jit")) continue;
            if (std.mem.eql(u8, trimmed_flag, "@raw")) continue;
            if (std.mem.eql(u8, trimmed_flag, "@self-exe")) continue;
            if (isSubcommandWord(trimmed_flag)) continue;
            run.addArg(trimmed_flag);
        }
    }
    if (te.env_lines) |el| {
        var env_iter = std.mem.splitScalar(u8, el, '\n');
        while (env_iter.next()) |line| {
            const trimmed_line = std.mem.trim(u8, line, " \t\r");
            if (trimmed_line.len == 0) continue;
            if (std.mem.indexOfScalar(u8, trimmed_line, '=')) |eq_pos| {
                run.setEnvironmentVariable(trimmed_line[0..eq_pos], trimmed_line[eq_pos + 1 ..]);
            }
        }
    }
    run.addFileArg(b.path(te.file_path));
    if (te.args_lines) |al| {
        var arg_iter = std.mem.splitScalar(u8, al, '\n');
        while (arg_iter.next()) |arg| {
            const trimmed_arg = std.mem.trimRight(u8, arg, "\r");
            if (trimmed_arg.len > 0) {
                run.addArg(trimmed_arg);
            }
        }
    }
    if (flagsContainSubcommand(te.flags_lines, "@self-exe")) run.addArtifactArg(artifact);
    addCommonFileDeps(b, run);
    if (te.has_args) run.addFileInput(b.path(te.args_path));
    if (te.has_stdin) run.addFileInput(b.path(te.stdin_path));
    if (te.has_flags) run.addFileInput(b.path(te.flags_path));
    if (te.has_exitcode) run.addFileInput(b.path(te.exitcode_path));
    if (te.has_env) run.addFileInput(b.path(te.env_path));
}

/// The scheduler's task dump names the raw descriptor a parked task waits on. The multiplexer
/// holds descriptors of its own, and kqueue and epoll take a different number of them, so the
/// value differs between platforms.
///
/// The dump's scope grouping token is a raw pointer, so ASLR makes it differ between runs.
const stderr_normalize_script = "s|blocked_fd=[0-9][0-9]*|blocked_fd=<fd>|g;s|scope=0x[0-9a-f][0-9a-f]*|scope=<scope>|g";

/// Rewrite stderr fields a golden cannot pin. Applied on both the comparison and the
/// update-golden path so the two agree.
fn normalizeStderr(b: *std.Build, captured: std.Build.LazyPath) std.Build.LazyPath {
    const normalize = b.addSystemCommand(&.{ "sed", stderr_normalize_script });
    normalize.addFileArg(captured);
    return normalize.captureStdOut();
}

fn addGoldenDiff(
    b: *std.Build,
    test_step: *std.Build.Step,
    captured: std.Build.LazyPath,
    golden_path: ?[]const u8,
    actual_label: []const u8,
) void {
    const expected_label = golden_path orelse "(empty)";
    const diff = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            "diff -u -L 'expected: {s}' -L 'actual: {s}' -- \"$1\" \"$2\" >&2",
            .{ expected_label, actual_label },
        ),
        "sh",
    });
    if (golden_path) |gp| {
        diff.addFileArg(b.path(gp));
    } else {
        diff.addArg("/dev/null");
    }
    diff.addFileArg(captured);
    test_step.dependOn(&diff.step);
}

/// Diff two captured outputs against each other, for a comparison that has no golden file.
fn addCapturedDiff(
    b: *std.Build,
    test_step: *std.Build.Step,
    expected: std.Build.LazyPath,
    actual: std.Build.LazyPath,
    expected_label: []const u8,
    actual_label: []const u8,
) void {
    const diff = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            "diff -u -L 'expected: {s}' -L 'actual: {s}' -- \"$1\" \"$2\" >&2",
            .{ expected_label, actual_label },
        ),
        "sh",
    });
    diff.addFileArg(expected);
    diff.addFileArg(actual);
    test_step.dependOn(&diff.step);
}

fn addCommonFileDeps(b: *std.Build, run: *std.Build.Step.Run) void {
    addDirFileDeps(b, run, "lib");
    addDirFileDeps(b, run, "examples");
    run.addFileInput(b.path("src/prelude.1z"));
}

fn addDirFileDeps(b: *std.Build, run: *std.Build.Step.Run, dir_name: []const u8) void {
    var dir = b.build_root.handle.openDir(dir_name, .{ .iterate = true }) catch |err| {
        std.debug.print("Warning: Could not open {s}/: {}\n", .{ dir_name, err });
        return;
    };
    defer dir.close();
    var walker = dir.walk(b.allocator) catch |err| {
        std.debug.print("Warning: Could not walk {s}/: {}\n", .{ dir_name, err });
        return;
    };
    defer walker.deinit();
    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".1z")) continue;
        run.addFileInput(b.path(b.fmt("{s}/{s}", .{ dir_name, entry.path })));
    }
}

const LspTestEntry = struct {
    name_without_ext: []const u8,
    jsonl_path: []const u8,
    formatted_stdin: []const u8,
    has_stdout_golden: bool,
    stdout_golden_path: []const u8,
    stdout_content: []const u8,
    has_stderr_golden: bool,
    stderr_golden_path: []const u8,
    stderr_content: []const u8,
    has_exitcode: bool,
    exitcode_path: []const u8,
    expected_exit_code: ?u8,
};

fn collectLspTestEntries(b: *std.Build, lsp_dir: *std.fs.Dir) ![]const LspTestEntry {
    var entries: std.ArrayListUnmanaged(LspTestEntry) = .{};

    var iter = lsp_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        const name_without_ext = b.dupe(entry.name[0 .. entry.name.len - 6]);
        const jsonl_path = b.fmt("tests/lsp/{s}", .{entry.name});

        var formatted_stdin: []const u8 = "";
        if (lsp_dir.openFile(entry.name, .{})) |file| {
            defer file.close();
            const content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            formatted_stdin = formatLspStdin(b, content);
        } else |_| {}

        var has_stdout_golden = false;
        var stdout_content: []const u8 = "";
        const stdout_golden_path = b.fmt("tests/lsp/{s}.stdout.golden", .{name_without_ext});
        if (lsp_dir.openFile(b.fmt("{s}.stdout.golden", .{name_without_ext}), .{})) |file| {
            defer file.close();
            stdout_content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            has_stdout_golden = true;
        } else |_| {}

        var has_stderr_golden = false;
        var stderr_content: []const u8 = "";
        const stderr_golden_path = b.fmt("tests/lsp/{s}.stderr.golden", .{name_without_ext});
        if (lsp_dir.openFile(b.fmt("{s}.stderr.golden", .{name_without_ext}), .{})) |file| {
            defer file.close();
            stderr_content = file.readToEndAlloc(b.allocator, 1024 * 1024) catch "";
            has_stderr_golden = true;
        } else |_| {}

        var has_exitcode = false;
        var expected_exit_code: ?u8 = null;
        const exitcode_path = b.fmt("tests/lsp/{s}.exitcode", .{name_without_ext});
        if (lsp_dir.openFile(b.fmt("{s}.exitcode", .{name_without_ext}), .{})) |file| {
            defer file.close();
            has_exitcode = true;
            const code_str = file.readToEndAlloc(b.allocator, 64) catch "";
            const trimmed_code = std.mem.trim(u8, code_str, " \t\r\n");
            if (trimmed_code.len > 0) {
                expected_exit_code = std.fmt.parseInt(u8, trimmed_code, 10) catch null;
            }
        } else |_| {}

        entries.append(b.allocator, .{
            .name_without_ext = name_without_ext,
            .jsonl_path = jsonl_path,
            .formatted_stdin = formatted_stdin,
            .has_stdout_golden = has_stdout_golden,
            .stdout_golden_path = stdout_golden_path,
            .stdout_content = stdout_content,
            .has_stderr_golden = has_stderr_golden,
            .stderr_golden_path = stderr_golden_path,
            .stderr_content = stderr_content,
            .has_exitcode = has_exitcode,
            .exitcode_path = exitcode_path,
            .expected_exit_code = expected_exit_code,
        }) catch return error.OutOfMemory;
    }

    return entries.items;
}

fn formatLspStdin(b: *std.Build, jsonl_content: []const u8) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    var line_iter = std.mem.splitScalar(u8, jsonl_content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const header = b.fmt("Content-Length: {d}\r\n\r\n", .{trimmed.len});
        buf.appendSlice(b.allocator, header) catch continue;
        buf.appendSlice(b.allocator, trimmed) catch continue;
    }
    return buf.toOwnedSlice(b.allocator) catch "";
}

fn addLspTests(
    b: *std.Build,
    lsp_artifact: *std.Build.Step.Compile,
    helper: *std.Build.Step.Compile,
    test_step: *std.Build.Step,
    update_files: **std.Build.Step.UpdateSourceFiles,
    status_files: *std.ArrayListUnmanaged(std.Build.LazyPath),
    lsp_entries: []const LspTestEntry,
    has_diff: bool,
    timeout_secs: u32,
    verbose_test_reporting: bool,
    slow_test_threshold_ms: u64,
    test_filter: ?[]const u8,
) void {
    var stdin_files = b.addWriteFiles();
    var matched_count: usize = 0;
    for (lsp_entries) |te| {
        if (test_filter) |filter| {
            if (!matchesFilter(te.name_without_ext, filter)) continue;
        }
        matched_count += 1;
        const expected_exit: u8 = te.expected_exit_code orelse 0;
        const stdin_file = stdin_files.add(b.fmt("lsp_{s}.stdin", .{te.name_without_ext}), te.formatted_stdin);

        const label = b.fmt("lsp: {s}", .{te.name_without_ext});
        const test_run = addWrappedCommand(
            b,
            helper,
            label,
            timeout_secs,
            verbose_test_reporting,
            slow_test_threshold_ms,
            stdin_file,
            status_files,
            &.{lsp_artifact.getEmittedBin()},
            false,
        );
        test_run.addArtifactArg(lsp_artifact);
        test_run.setName(label);
        test_run.expectExitCode(expected_exit);

        test_run.addFileInput(b.path(te.jsonl_path));
        if (te.has_stdout_golden) test_run.addFileInput(b.path(te.stdout_golden_path));
        if (te.has_stderr_golden) test_run.addFileInput(b.path(te.stderr_golden_path));
        if (te.has_exitcode) test_run.addFileInput(b.path(te.exitcode_path));

        if (has_diff) {
            addGoldenDiff(b, test_step, test_run.captureStdOut(), if (te.has_stdout_golden) te.stdout_golden_path else null, te.jsonl_path);
            if (te.has_stderr_golden) {
                addGoldenDiff(b, test_step, test_run.captureStdErr(), te.stderr_golden_path, te.jsonl_path);
            }
        } else {
            if (te.has_stdout_golden) {
                test_run.expectStdOutEqual(te.stdout_content);
            } else {
                test_run.expectStdOutEqual("");
            }
            if (te.has_stderr_golden) {
                test_run.expectStdErrEqual(te.stderr_content);
            }
            test_step.dependOn(&test_run.step);
        }

        // Update golden
        {
            const update_run = b.addRunArtifact(lsp_artifact);
            update_run.setStdIn(.{ .bytes = te.formatted_stdin });

            if (expected_exit != 0) {
                update_run.expectExitCode(expected_exit);
            }

            update_files.*.addCopyFileToSource(update_run.captureStdOut(), te.stdout_golden_path);
            if (te.has_stderr_golden or expected_exit != 0) {
                update_files.*.addCopyFileToSource(update_run.captureStdErr(), te.stderr_golden_path);
            }
        }
    }

    if (test_filter) |filter| {
        const summary_cmd = b.addSystemCommand(&.{ "echo", b.fmt("Filter active: {d}/{d} lsp tests match '{s}'", .{ matched_count, lsp_entries.len, filter }) });
        test_step.dependOn(&summary_cmd.step);
    }
}

fn createCommonModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
    root_source_file: std.Build.LazyPath,
    embedded_stdlib_path: std.Build.LazyPath,
) *std.Build.Module {
    const build_target = resolveBuildTarget(target);
    const is_freestanding = !build_target.has_filesystem;
    const module = b.createModule(.{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
        .link_libc = !is_freestanding,
        .single_threaded = build_target.single_threaded,
    });
    // Freestanding builds skip the C dependencies (libffi, toy tokenizer,
    // minicoro coroutines, ir JIT backend). The native words that would
    // reach into them are capability-gated and throw BuildUnsupported on
    // freestanding; the bare-metal program never invokes them.
    if (!is_freestanding) {
        module.addCSourceFile(.{ .file = b.path("ext/toy/toy.c"), .flags = &.{} });
        module.addIncludePath(b.path("ext/toy"));
        module.addCSourceFile(.{ .file = b.path("ext/minicoro/minicoro.c"), .flags = &.{} });
        module.addIncludePath(b.path("ext/minicoro"));
        module.linkSystemLibrary("ffi", .{});
        addFfiIncludePath(b, module, target);
        addIrSources(b, module);
    }
    module.addOptions("build_options", options);
    module.addAnonymousImport("embedded_stdlib_data", .{
        .root_source_file = embedded_stdlib_path,
    });
    return module;
}

/// Emit a Zig source file containing the embedded stdlib lookup table.
/// The table is always present so runtime imports stay unconditional;
/// it is empty when -Dembed-stdlib is false. When -Dembed-stdlib is true,
/// walk lib/**/*.1z and emit one @embedFile entry per source file, keyed
/// by hierarchical module names (lib/ prefix and .1z suffix stripped,
/// path separators normalized to '/').
fn generateEmbeddedStdlib(b: *std.Build, embed: bool) std.Build.LazyPath {
    const wf = b.addWriteFiles();

    var source: std.ArrayListUnmanaged(u8) = .{};
    source.appendSlice(b.allocator,
        \\pub const Entry = struct {
        \\    name: []const u8,
        \\    source: []const u8,
        \\};
        \\
        \\pub const entries: []const Entry = &.{
        \\
    ) catch @panic("OOM");

    if (embed) appendEmbeddedStdlibEntries(b, wf, &source);

    source.appendSlice(b.allocator,
        \\};
        \\
    ) catch @panic("OOM");

    return wf.add("embedded_stdlib.zig", source.items);
}

const EmbedStdlibEntry = struct {
    module_name: []const u8,
    rel_path: []const u8,

    fn lessThan(_: void, a: EmbedStdlibEntry, c: EmbedStdlibEntry) bool {
        return std.mem.lessThan(u8, a.module_name, c.module_name);
    }
};

fn appendEmbeddedStdlibEntries(
    b: *std.Build,
    wf: *std.Build.Step.WriteFile,
    source: *std.ArrayListUnmanaged(u8),
) void {
    var lib_dir = b.build_root.handle.openDir("lib", .{ .iterate = true }) catch |err| {
        std.debug.print("Error: -Dembed-stdlib=true requires lib/ to be readable: {}\n", .{err});
        @panic("lib/ open failed");
    };
    defer lib_dir.close();

    var walker = lib_dir.walk(b.allocator) catch |err| {
        std.debug.print("Error: walking lib/ failed: {}\n", .{err});
        @panic("lib/ walk failed");
    };
    defer walker.deinit();

    var entries: std.ArrayListUnmanaged(EmbedStdlibEntry) = .{};

    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".1z")) continue;

        const rel_path = b.dupe(entry.path);
        for (rel_path) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        const module_name = rel_path[0 .. rel_path.len - ".1z".len];
        entries.append(b.allocator, .{
            .module_name = module_name,
            .rel_path = rel_path,
        }) catch @panic("OOM");
    }

    std.mem.sort(EmbedStdlibEntry, entries.items, {}, EmbedStdlibEntry.lessThan);

    for (entries.items) |e| {
        _ = wf.addCopyFile(b.path(b.fmt("lib/{s}", .{e.rel_path})), e.rel_path);
        source.print(b.allocator, "    .{{ .name = \"{s}\", .source = @embedFile(\"{s}\") }},\n", .{
            e.module_name, e.rel_path,
        }) catch @panic("OOM");
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

fn addLuaSources(b: *std.Build, module: *std.Build.Module) void {
    // The platform define selects Lua's OS integration (dlopen-based require,
    // POSIX os/io behavior). It matches the canonical upstream build per target.
    const platform_flag: []const u8 = switch (module.resolved_target.?.result.os.tag) {
        .macos => "-DLUA_USE_MACOSX",
        .linux => "-DLUA_USE_LINUX",
        else => "-DLUA_USE_POSIX",
    };

    // Every core and standard-library source under ext/lua/. The standalone
    // interpreter (lua.c) and the bytecode compiler (luac.c) are not vendored.
    const lua_c_files = [_][]const u8{
        "lapi.c",     "lauxlib.c", "lbaselib.c", "lcode.c",   "lcorolib.c",
        "lctype.c",   "ldblib.c",  "ldebug.c",   "ldo.c",     "ldump.c",
        "lfunc.c",    "lgc.c",     "linit.c",    "liolib.c",  "llex.c",
        "lmathlib.c", "lmem.c",    "loadlib.c",  "lobject.c", "lopcodes.c",
        "loslib.c",   "lparser.c", "lstate.c",   "lstring.c", "lstrlib.c",
        "ltable.c",   "ltablib.c", "ltm.c",      "lundump.c", "lutf8lib.c",
        "lvm.c",      "lzio.c",
    };

    const flags: []const []const u8 = &.{platform_flag};

    for (lua_c_files) |name| {
        module.addCSourceFile(.{
            .file = b.path(b.fmt("ext/lua/{s}", .{name})),
            .flags = flags,
        });
    }

    // Local shim, not vendored: the ffi-callback error hook lib/lua.1z resolves
    // from the same dylib handle.
    module.addCSourceFile(.{
        .file = b.path("ext/lua/onez_shim.c"),
        .flags = flags,
    });

    module.addIncludePath(b.path("ext/lua"));
}
