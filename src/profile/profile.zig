const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("../shared/config.zig");
const fsx = @import("../shared/fsx.zig");
const manifest = @import("manifest.zig");
const composer = @import("composer.zig");
const Log = @import("../shared/log.zig").Log;

/// Validate a profile name. Only allows characters that are safe inside a
/// single path component — letters, digits, '-', '_' — and caps the length
/// at 64. This prevents path traversal (e.g. "../../etc") and rejects
/// hidden/relative names (".", "..") as well as any name containing
/// slashes or NULs.
pub fn validateName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// Create a new profile named `name` and compose its CLAUDE_CONFIG_DIR.
///
/// Steps:
///   1. Validate the name (refuses "default" and any invalid characters).
///   2. Make sure no profile with that name already exists.
///   3. Write a manifest.zon (the profile's metadata: name, sharing policy,
///      creation timestamp).
///   4. Compose the config directory (symlinks for shared resources, empty
///      dirs for private ones) via `composer.compose`.
///
/// `no_share` flips the sharing policy — `--no-share` profiles get a fully
/// independent config dir with no symlinks to ~/.claude at all.
pub fn create(allocator: Allocator, logger: Log, name: []const u8, no_share: bool) !void {
    if (!validateName(name)) {
        logger.err("invalid profile name '{s}': use letters, digits, '-' or '_' (max 64)", .{name});
        std.process.exit(1);
    }

    // Guard: cannot create 'default' profile
    if (std.mem.eql(u8, name, "default")) {
        logger.err("'default' is a reserved profile name", .{});
        std.process.exit(1);
    }

    // Check if profile already exists
    const profile_dir = try config.profileDir(allocator, name);
    defer allocator.free(profile_dir);

    if (fsx.exists(profile_dir)) {
        logger.err("profile '{s}' already exists", .{name});
        std.process.exit(1);
    }

    // Create manifest
    var m: manifest.Manifest = .{
        .name = try allocator.dupe(u8, name),
        .shared = !no_share,
        .created_at = @as(u64, @intCast(Io.Timestamp.now(Io.Threaded.global_single_threaded.io(), .real).toSeconds())),
    };
    defer allocator.free(m.name);

    try m.save(allocator);

    // Compose config directory
    try composer.compose(allocator, logger, name, !no_share);

    logger.info("created profile '{s}' ({s})", .{
        name,
        if (no_share) "isolated" else "shared",
    });
}

/// Delete the profile directory and everything in it.
///
/// Hard guards: "default" can't be deleted (it IS ~/.claude — see README),
/// the name must be valid, and the profile must actually exist. The
/// underlying filesystem deletion is recursive (`fsx.removeAll`); shared
/// resources in ~/.claude are NEVER touched because they're symlinks into
/// the user's real config, and unlinking the symlink here just removes the
/// symlink, not the file it points to.
pub fn delete(allocator: Allocator, logger: Log, name: []const u8) !void {
    if (!validateName(name)) {
        logger.err("invalid profile name '{s}': use letters, digits, '-' or '_' (max 64)", .{name});
        std.process.exit(1);
    }

    // Guard: cannot delete 'default' profile
    if (std.mem.eql(u8, name, "default")) {
        logger.err("cannot delete the 'default' profile", .{});
        std.process.exit(1);
    }

    const profile_dir = try config.profileDir(allocator, name);
    defer allocator.free(profile_dir);

    if (!fsx.exists(profile_dir)) {
        logger.err("profile '{s}' does not exist", .{name});
        std.process.exit(1);
    }

    try fsx.removeAll(profile_dir);

    logger.info("deleted profile '{s}'", .{name});
}

/// Print one line per profile, each showing the name and the sharing mode
/// (shared / isolated) read from the profile's manifest. If the profiles
/// dir doesn't exist yet (no profiles have been created), prints a single
/// "no profiles created yet" info line.
pub fn list(allocator: Allocator, logger: Log) !void {
    const mcc_dir = try config.mccDir(allocator);
    defer allocator.free(mcc_dir);

    const profiles_dir = try std.fmt.allocPrint(allocator, "{s}/profiles", .{mcc_dir});
    defer allocator.free(profiles_dir);

    if (!fsx.exists(profiles_dir)) {
        logger.info("no profiles created yet", .{});
        return;
    }

    const names = try fsx.listSubdirs(allocator, profiles_dir);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    for (names) |name| {
        const manifest_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/manifest.zon",
            .{ profiles_dir, name },
        );
        defer allocator.free(manifest_path);

        if (fsx.exists(manifest_path)) {
            const m = manifest.Manifest.load(allocator, name) catch continue;
            defer allocator.free(m.name);
            const mode = if (m.shared) "shared" else "isolated";
            logger.info("  {s}  ({s})", .{ name, mode });
        }
    }
}

/// Print the CLAUDE_CONFIG_DIR path mcc would set when launching `name`.
///
/// For "default" this is the user's real ~/.claude (or $CLAUDE_CONFIG_DIR
/// if set). For any other profile this is the composed config dir under
/// ~/.multi-claude/profiles/<name>/config. Useful for shells and scripts
/// that want to run claude against a specific profile directly.
pub fn which(allocator: Allocator, logger: Log, name: []const u8) !void {
    const io = Io.Threaded.global_single_threaded.io();
    const out = Io.File.stdout();

    if (std.mem.eql(u8, name, "default")) {
        const default_dir = try config.canonicalClaudeDir(allocator);
        defer allocator.free(default_dir);
        Io.File.writeStreamingAll(out, io, default_dir) catch {};
        Io.File.writeStreamingAll(out, io, "\n") catch {};
        return;
    }

    if (!validateName(name)) {
        logger.err("invalid profile name '{s}': use letters, digits, '-' or '_' (max 64)", .{name});
        std.process.exit(1);
    }

    const profile_config = try config.profileConfigDir(allocator, name);
    defer allocator.free(profile_config);

    Io.File.writeStreamingAll(out, io, profile_config) catch {};
    Io.File.writeStreamingAll(out, io, "\n") catch {};
}
