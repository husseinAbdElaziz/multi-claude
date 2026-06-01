const std = @import("std");
const Src = @import("src");

// Force compilation of every source module so type errors surface in `zig build test`.
test "source modules compile" {
    std.testing.refAllDecls(Src);
    std.testing.refAllDecls(Src.fsx);
    std.testing.refAllDecls(Src.cli);
    std.testing.refAllDecls(Src.config);
    std.testing.refAllDecls(Src.profile);
    std.testing.refAllDecls(Src.manifest);
    std.testing.refAllDecls(Src.resources);
    std.testing.refAllDecls(Src.composer);
    std.testing.refAllDecls(Src.launcher);
    std.testing.refAllDecls(Src.lock);
    std.testing.refAllDecls(Src.log);
    std.testing.refAllDecls(Src.doctor);
    std.testing.refAllDecls(Src.update);
    std.testing.refAllDecls(Src.uninstall);
}

// Pull in the actual test suites by importing their files so their `test`
// blocks are discovered and executed by the test runner.
comptime {
    _ = @import("cli.zig");
    _ = @import("manifest.zig");
    _ = @import("resources.zig");
    _ = @import("levenshtein.zig");
    _ = @import("integration.zig");
    _ = @import("update.zig");
}
