const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_mod = b.addModule("kurotty_core", .{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const abi_mod = b.createModule(.{
        .root_source_file = b.path("src/abi.zig"),
        .target = target,
        .optimize = optimize,
    });
    abi_mod.addImport("kurotty_core", core_mod);

    const static_lib = b.addLibrary(.{
        .name = "kurotty_core",
        .root_module = abi_mod,
        .linkage = .static,
    });
    b.installArtifact(static_lib);

    const dynamic_lib = b.addLibrary(.{
        .name = "kurotty_core",
        .root_module = abi_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(dynamic_lib);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/core_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("kurotty_core", core_mod);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run Zig core tests");
    test_step.dependOn(&run_unit_tests.step);

    const bench = b.addExecutable(.{
        .name = "kurotty-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench.root_module.addImport("kurotty_core", core_mod);
    b.installArtifact(bench);

    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run parser/grid/scrollback benchmark smoke checks");
    bench_step.dependOn(&run_bench.step);

    const scrollback_stress = b.addExecutable(.{
        .name = "kurotty-scrollback-million",
        .root_module = b.createModule(.{
            .root_source_file = b.path("stress/scrollback_million.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    scrollback_stress.root_module.addImport("kurotty_core", core_mod);
    const run_scrollback_stress = b.addRunArtifact(scrollback_stress);
    const stress_step = b.step("stress-scrollback", "Run the one-million-line scrollback stress test");
    stress_step.dependOn(&run_scrollback_stress.step);

    const leak_check = b.addExecutable(.{
        .name = "kurotty-leak-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/leak_check.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    leak_check.root_module.addImport("kurotty_core", core_mod);
    leak_check.root_module.linkLibrary(static_lib);
    const run_leak_check = b.addRunArtifact(leak_check);
    const leak_step = b.step("leak-check", "Run allocator-backed leak checks for core paths");
    leak_step.dependOn(&run_leak_check.step);
}
