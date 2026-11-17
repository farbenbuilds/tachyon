const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zslay = b.dependency("zslay", .{
        .target = target,
        .optimize = optimize,
    }).module("zslay");

    const mod = b.addModule("tachyon", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zslay", .module = zslay },
        },
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "tachyon",
        .root_module = mod,
    });
    b.installArtifact(lib);

    const test_debug = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "zslay", .module = zslay },
            },
        }),
    });
    const test_safe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "zslay", .module = zslay },
            },
        }),
    });

    const run_test_debug = b.addRunArtifact(test_debug);
    const run_test_safe = b.addRunArtifact(test_safe);

    const test_step = b.step("test", "Run the Debug and ReleaseSafe test suites");
    test_step.dependOn(&run_test_debug.step);
    test_step.dependOn(&run_test_safe.step);

    const check_step = b.step("check", "Type-check the library and tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&test_debug.step);
    check_step.dependOn(&test_safe.step);
}
