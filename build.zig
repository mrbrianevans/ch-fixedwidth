const std = @import("std");

/// Keep in sync with `build.zig.zon`, `CHANGELOG.md`, and package.json versions.
const library_version = "0.1.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const git_commit = resolveGitCommit(b);

    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "version", library_version);
    build_opts.addOption([]const u8, "git_commit", git_commit);

    const mod = b.addModule("ch_fixedwidth", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", build_opts);

    // --- CLI ---
    const exe = b.addExecutable(.{
        .name = "parser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ch_fixedwidth", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the parser CLI");
    run_step.dependOn(&run_cmd.step);

    // --- Static library (C ABI) ---
    const static_lib = b.addLibrary(.{
        .name = "ch_fixedwidth",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    static_lib.root_module.addOptions("build_options", build_opts);
    static_lib.root_module.link_libc = false;
    b.installArtifact(static_lib);

    // --- Shared library (C ABI) when the target supports it ---
    if (target.result.os.tag != .wasi and target.result.cpu.arch != .wasm32) {
        const shared_lib = b.addLibrary(.{
            .name = "ch_fixedwidth",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/c_api.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        shared_lib.root_module.addOptions("build_options", build_opts);
        b.installArtifact(shared_lib);
    }

    // Install C header next to libraries
    const install_header = b.addInstallFile(
        b.path("include/ch_fixedwidth.h"),
        "include/ch_fixedwidth.h",
    );
    b.getInstallStep().dependOn(&install_header.step);

    // --- Freestanding WASM module (parse only, no WASI I/O) ---
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    wasm_mod.addOptions("build_options", build_opts);
    const wasm = b.addExecutable(.{
        .name = "ch_fixedwidth",
        .root_module = wasm_mod,
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    // Export C ABI symbols for JS / host loaders.
    wasm.root_module.export_symbol_names = &.{
        "ch_parse",
        "ch_parse_result_free",
        "ch_buffer_free",
        "ch_alloc",
        "ch_free",
        "ch_supported_formats",
        "ch_library_info",
        "ch_stream_create",
        "ch_stream_destroy",
        "ch_stream_feed",
        "ch_stream_finish",
        "ch_stream_next_batch",
        "ch_csv_batch_free",
        "ch_stream_stats",
    };

    const install_wasm = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .prefix },
    });
    const wasm_step = b.step("wasm", "Build freestanding WASM parse module");
    wasm_step.dependOn(&install_wasm.step);

    // --- Tests ---
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

/// Short git SHA at configure time, overridable with `-Dgit-commit=…`.
fn resolveGitCommit(b: *std.Build) []const u8 {
    if (b.option([]const u8, "git-commit", "Short git commit SHA embedded in the library")) |override| {
        if (override.len > 0) return override;
    }

    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "git", "rev-parse", "--short=12", "HEAD" },
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(256),
    }) catch return "unknown";
    defer {
        b.allocator.free(result.stdout);
        b.allocator.free(result.stderr);
    }

    switch (result.term) {
        .exited => |code| if (code != 0) return "unknown",
        else => return "unknown",
    }

    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (trimmed.len == 0) return "unknown";
    return b.dupe(trimmed);
}
