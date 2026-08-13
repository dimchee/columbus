const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("columbus", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    {
        const exe = b.addExecutable(.{
            .name = "app",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/4_gpu.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "columbus", .module = mod },
                },
            }),
        });
        exe.root_module.link_libc = true;
        b.installArtifact(exe);
        const run_step = b.step("run", "Run the app");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);
    }
    {
        const scanner = b.addExecutable(.{
            .name = "scanner",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/scanner.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "columbus", .module = mod },
                },
            }),
        });
        b.installArtifact(scanner);
        const run_step = b.step("scan", "Run the app");
        const run_cmd = b.addRunArtifact(scanner);
        run_step.dependOn(&run_cmd.step);
        if (b.args) |args| run_cmd.addArgs(args);
    }
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
