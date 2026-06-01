const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Single shared module for all source files
    const src_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "mcc",
        .root_module = src_module,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the mcc tool");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run all tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/all_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add a single 'src' import that gives tests access to the entire src/ directory
    tests.root_module.addImport("src", src_module);

    const test_run = b.addRunArtifact(tests);
    test_step.dependOn(&test_run.step);
}
