const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("../shared/config.zig");
const fsx = @import("../shared/fsx.zig");
const resources = @import("resources.zig");
const Log = @import("../shared/log.zig").Log;

/// Compose the config directory for a profile.
/// Creates symlinks for shared resources, creates empty dirs/files for private ones.
/// Idempotent: safe to run multiple times.
pub fn compose(allocator: Allocator, logger: Log, profile_name: []const u8, shared: bool) !void {
    const claude_dir = try config.canonicalClaudeDir(allocator);
    defer allocator.free(claude_dir);

    const profile_config = try config.profileConfigDir(allocator, profile_name);
    defer allocator.free(profile_config);

    try composeInto(allocator, logger, claude_dir, profile_config, shared);

    logger.info("composed config for profile '{s}' ({s})", .{
        profile_name,
        if (shared) "shared" else "isolated",
    });
}

/// Core composition: link/create every catalog resource from `claude_dir` into
/// `profile_config`, honoring the sharing policy. Split out from `compose` so
/// it can be driven directly in tests with arbitrary directories, without
/// depending on HOME / CLAUDE_CONFIG_DIR. Idempotent.
pub fn composeInto(
    allocator: Allocator,
    logger: Log,
    claude_dir: []const u8,
    profile_config: []const u8,
    shared: bool,
) !void {
    // Ensure the config directory exists
    try fsx.mkdirAll(profile_config);

    for (resources.resources) |resource| {
        const should_share = resources.policy(resource, shared);
        const target_path = std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{profile_config, resource.path},
        ) catch continue;
        defer allocator.free(target_path);

        const source_path = std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{claude_dir, resource.path},
        ) catch continue;
        defer allocator.free(source_path);

        if (should_share) {
            // Symlink to the default profile's resource
            // Only if the source exists (don't create dangling symlinks)
            if (fsx.exists(source_path)) {
                // Remove existing symlink/file if it exists
                try fsx.remove(target_path);
                try fsx.symlinkCreate(source_path, target_path);
                logger.debug("symlinked {s} -> {s}", .{ target_path, source_path });
            }
        } else {
            // Create a private directory or touch a file
            if (resource.is_dir) {
                try fsx.mkdirAll(target_path);
            }
            // For private files, we don't create them upfront — claude will create them on first run
        }
    }
}
