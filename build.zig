/// Build script for the `mcc` binary. Single executable, one shared
/// root module containing every source file, plus a `build_options`
/// module that injects the version string compiled into the binary.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Single shared module for all source files. `link_libc` is
    // required: config.zig uses libc `getenv` and fsx.zig uses
    // `std.c.symlink`. macOS links libc implicitly, but Linux does
    // not, so without this the build fails on Linux CI.
    const src_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Version baked into the binary. CI release builds pass
    // `-Dversion=<tag>` so `mcc --version` matches the released tag.
    // Local builds default to the latest released version so a
    // `zig build` checkout still reports a meaningful version instead
    // of a stale placeholder.
    const version = b.option([]const u8, "version", "Version string reported by `mcc --version`") orelse "0.1.0";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    src_module.addImport("build_options", build_options.createModule());

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

    // Expose the entire `src/` tree to the test module as a single
    // `src` import, so tests can `@import("src/main.zig")` to reach
    // the production code under test.
    tests.root_module.addImport("src", src_module);

    const test_run = b.addRunArtifact(tests);
    test_step.dependOn(&test_run.step);
}
