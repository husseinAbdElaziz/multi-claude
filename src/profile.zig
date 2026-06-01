const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const fsx = @import("fsx.zig");
const manifest = @import("manifest.zig");
const composer = @import("composer.zig");
const Log = @import("log.zig").Log;

/// Validate a profile name. Only allows characters that are safe inside a
/// single path component, preventing path traversal (e.g. "../../etc") and
/// hidden/relative names ("." / "..").
pub fn validateName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// Create a new profile
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

/// Delete a profile
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

/// List all profiles
pub fn list(allocator: Allocator, logger: Log) !void {
    const mcc_dir = try config.mccDir(allocator);
    defer allocator.free(mcc_dir);

    const profiles_dir = try std.fmt.allocPrint(allocator, "{s}/profiles", .{mcc_dir});
    defer allocator.free(profiles_dir);

    if (!fsx.exists(profiles_dir)) {
        logger.info("no profiles created yet", .{});
        return;
    }

    const io = Io.Threaded.global_single_threaded.io();
    const dir = Io.Dir.openDirAbsolute(io, profiles_dir, .{ .iterate = true }) catch return;
    defer Io.Dir.close(dir, io);

    var it = Io.Dir.iterate(dir);
    while (it.next(io) catch |err| return err) |entry| {
        if (entry.kind == .directory) {
            const manifest_path = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}/manifest.zon",
                .{profiles_dir, entry.name},
            );
            defer allocator.free(manifest_path);

            if (fsx.exists(manifest_path)) {
                const m = manifest.Manifest.load(allocator, entry.name) catch continue;
                defer allocator.free(m.name);
                const mode = if (m.shared) "shared" else "isolated";
                logger.info("  {s}  ({s})", .{ entry.name, mode });
            }
        }
    }
}

/// Print the composed CLAUDE_CONFIG_DIR for a profile
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
