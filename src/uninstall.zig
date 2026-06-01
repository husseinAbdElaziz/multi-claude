const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const fsx = @import("fsx.zig");
const Log = @import("log.zig").Log;

/// Heuristically detect a Homebrew-managed binary path. Homebrew installs the
/// real file under a Cellar and symlinks it onto PATH; `executablePathAlloc`
/// follows symlinks, so we see the Cellar path here.
fn isBrewManaged(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/Cellar/") != null or
        std.mem.indexOf(u8, path, "/.linuxbrew/") != null or
        std.mem.indexOf(u8, path, "/homebrew/Cellar/") != null;
}

/// Ask the user to confirm a destructive action. Returns true only on an
/// explicit "y"/"yes". Any read error or empty input is treated as "no".
fn confirm(io: Io) bool {
    const out = Io.File.stdout();
    Io.File.writeStreamingAll(out, io, "Continue? [y/N] ") catch {};

    var buf: [16]u8 = undefined;
    const in = Io.File.stdin();
    const n = Io.File.readStreaming(in, io, &.{buf[0..]}) catch return false;
    if (n == 0) return false;

    const line = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return line.len > 0 and (line[0] == 'y' or line[0] == 'Y');
}

/// Remove mcc's data directory and (unless Homebrew-managed) the binary itself.
/// Never touches `~/.claude`.
pub fn run(allocator: Allocator, logger: Log, assume_yes: bool) !void {
    const io = Io.Threaded.global_single_threaded.io();

    const mcc_dir = try config.mccDir(allocator);
    defer allocator.free(mcc_dir);
    const data_exists = fsx.exists(mcc_dir);

    // Best-effort resolution of our own path; uninstall still proceeds for the
    // data dir even if this fails.
    const exe_path: ?[]u8 = std.process.executablePathAlloc(io, allocator) catch null;
    defer if (exe_path) |p| allocator.free(p);

    const brew_managed = if (exe_path) |p| isBrewManaged(p) else false;

    logger.info("The following will be removed:", .{});
    if (data_exists) {
        logger.info("  - data:   {s}  (all profiles; ~/.claude is untouched)", .{mcc_dir});
    } else {
        logger.info("  - data:   none ({s} does not exist)", .{mcc_dir});
    }
    if (exe_path) |p| {
        if (brew_managed) {
            logger.info("  - binary: {s}  (Homebrew-managed — will NOT be deleted)", .{p});
        } else {
            logger.info("  - binary: {s}", .{p});
        }
    }
    if (brew_managed) {
        logger.warn("mcc was installed via Homebrew; run 'brew uninstall mcc' to remove the binary.", .{});
    }

    if (!assume_yes and !confirm(io)) {
        logger.info("uninstall cancelled", .{});
        return;
    }

    if (data_exists) {
        fsx.removeAll(mcc_dir) catch |err| {
            logger.err("failed to remove {s}: {}", .{ mcc_dir, err });
        };
        logger.info("removed {s}", .{mcc_dir});
    }

    if (exe_path) |p| {
        if (brew_managed) {
            logger.info("left binary in place (use 'brew uninstall mcc')", .{});
        } else {
            // Unlinking a running executable is fine on POSIX: the inode stays
            // alive until this process exits.
            Io.Dir.deleteFileAbsolute(io, p) catch |err| {
                logger.err("could not remove binary {s}: {} — remove it manually (you may need sudo)", .{ p, err });
                return;
            };
            logger.info("removed {s}", .{p});
        }
    }

    logger.info("mcc uninstalled.", .{});
}
