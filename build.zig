const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const aecs = b.addModule("root", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const test_step = b.step("test", "Run arion-ecs tests");

    const tests = b.addTest(.{
        .name = "arion-ecs-tests",
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    tests.root_module.addImport("aecs", aecs);

    b.installArtifact(tests);

    test_step.dependOn(&b.addRunArtifact(tests).step);
}
