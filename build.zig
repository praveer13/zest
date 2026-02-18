const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zig-xet dependency: complete Xet protocol implementation
    const xet_dep = b.dependency("xet", .{
        .target = target,
        .optimize = optimize,
    });
    const xet_module = xet_dep.module("xet");

    // Library module (for consumers of zest as a dependency)
    const lib_mod = b.addModule("zest", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "xet", .module = xet_module },
        },
    });

    // Executable
    const exe = b.addExecutable(.{
        .name = "zest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "xet", .module = xet_module },
                .{ .name = "zest", .module = lib_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const lib_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Integration tests (shell scripts, depend on install so binary is built first)
    const verify_model = b.addSystemCommand(&.{"./test/local/verify-model.sh"});
    verify_model.step.dependOn(b.getInstallStep());
    const verify_step = b.step("integration-test", "Pull model with zest, load with transformers, verify inference");
    verify_step.dependOn(&verify_model.step);

    const p2p_docker = b.addSystemCommand(&.{"./test/local/p2p-docker-test.sh"});
    p2p_docker.step.dependOn(b.getInstallStep());
    const p2p_step = b.step("p2p-test", "Docker-based P2P test (seeder + leecher, requires docker)");
    p2p_step.dependOn(&p2p_docker.step);
}
