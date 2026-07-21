const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("ch_fixedwidth", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

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
    const wasm = b.addExecutable(.{
        .name = "ch_fixedwidth",
        .root_module = wasm_mod,
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    // Export C ABI symbols for JS / host loaders.
    wasm.root_module.export_symbol_names = &.{
        "ch_parse_snapshot",
        "ch_parse_result_free",
        "ch_buffer_free",
        "ch_alloc",
        "ch_free",
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
