const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const fsx = @import("fsx.zig");
const Log = @import("log.zig").Log;

/// Check the environment and report issues
pub fn check(allocator: Allocator, logger: Log) !void {
    var ok = true;

    // 1. Check claude is on PATH
    const claude_path = try findExecutable(allocator, "claude");
    if (claude_path) |path| {
        logger.info("✓ claude found at {s}", .{path});
        allocator.free(path);
    } else {
        logger.err("✗ claude not found on PATH", .{});
        ok = false;
    }

    // 2. Report the CLAUDE_CONFIG_DIR mechanism (set per-profile at launch)
    const ccd = try config.getEnvVar(allocator, "CLAUDE_CONFIG_DIR");
    if (ccd) |val| {
        defer allocator.free(val);
        logger.info("ℹ CLAUDE_CONFIG_DIR is set in this shell: {s}", .{val});
    } else {
        logger.info("ℹ CLAUDE_CONFIG_DIR not set (default profile uses ~/.claude)", .{});
    }

    // 3. Check ~/.claude exists
    const claude_dir = try config.canonicalClaudeDir(allocator);
    defer allocator.free(claude_dir);

    if (fsx.exists(claude_dir)) {
        logger.info("✓ ~/.claude exists at {s}", .{claude_dir});
    } else {
        logger.warn("⚠ ~/.claude not found at {s} (run 'claude' first to initialize)", .{claude_dir});
    }

    // 4. Check ~/.multi-claude exists
    const mcc_dir = try config.mccDir(allocator);
    defer allocator.free(mcc_dir);

    if (fsx.exists(mcc_dir)) {
        logger.info("✓ ~/.multi-claude exists", .{});
    } else {
        logger.info("ℹ ~/.multi-claude not found (will be created on first 'mcc new')", .{});
    }

    // 5. Check for broken symlinks in profiles
    const profiles_dir = try std.fmt.allocPrint(allocator, "{s}/profiles", .{mcc_dir});
    defer allocator.free(profiles_dir);

    if (fsx.exists(profiles_dir)) {
        const io = Io.Threaded.global_single_threaded.io();
        const dir = Io.Dir.openDirAbsolute(io, profiles_dir, .{ .iterate = true }) catch return;
        defer Io.Dir.close(dir, io);

        var broken_total: usize = 0;
        var it = Io.Dir.iterate(dir);
        while (it.next(io) catch return) |entry| {
            if (entry.kind == .directory) {
                const config_dir = try std.fmt.allocPrint(
                    allocator,
                    "{s}/{s}/config",
                    .{profiles_dir, entry.name},
                );
                defer allocator.free(config_dir);

                broken_total += checkBrokenSymlinks(allocator, config_dir);
            }
        }

        if (broken_total == 0) {
            logger.info("✓ no broken symlinks in profiles", .{});
        } else {
            logger.err("✗ {d} broken symlink(s) found in profiles", .{broken_total});
            ok = false;
        }
    }

    if (ok) {
        logger.info("doctor: all checks passed", .{});
    } else {
        logger.err("doctor: some checks failed", .{});
        std.process.exit(1);
    }
}

fn checkBrokenSymlinks(allocator: Allocator, dir_path: []const u8) usize {
    var count: usize = 0;
    const io = Io.Threaded.global_single_threaded.io();

    if (!fsx.exists(dir_path)) return 0;

    const dir = Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return 0;
    defer Io.Dir.close(dir, io);

    var it = Io.Dir.iterate(dir);
    while (it.next(io) catch return 0) |entry| {
        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{dir_path, entry.name}) catch continue;
        defer allocator.free(full_path);

        if (fsx.isSymlink(full_path)) {
            // Check if the target exists
            var buf: [4096]u8 = undefined;
            const len = Io.Dir.readLinkAbsolute(io, full_path, &buf) catch continue;
            const target = buf[0..len];

            if (!fsx.exists(target)) {
                count += 1;
            }
        }
    }

    return count;
}

fn findExecutable(allocator: Allocator, name: []const u8) !?[]u8 {
    const path_var = try config.getEnvVar(allocator, "PATH");
    defer if (path_var) |p| allocator.free(p);

    if (path_var) |path| {
        var iter = std.mem.tokenizeScalar(u8, path, ':');
        while (iter.next()) |dir| {
            const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{dir, name});
            if (fsx.exists(full)) {
                return full;
            }
            allocator.free(full);
        }
    }

    return null;
}
