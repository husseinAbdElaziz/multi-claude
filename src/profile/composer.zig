const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("../shared/config.zig");
const fsx = @import("../shared/fsx.zig");
const resources = @import("resources.zig");
const Log = @import("../shared/log.zig").Log;

/// Compose (build / refresh) the CLAUDE_CONFIG_DIR for a profile.
///
/// For every entry in `resources.resources` we either:
///   - symlink it from the default ~/.claude (shared resource, profile
///     sharing enabled), or
///   - create an empty directory in the profile's config dir (private
///     resource, or profile sharing disabled).
///
/// Idempotent: re-running is safe. Existing symlinks are unlinked and
/// re-created so a user changing the default ~/.claude is picked up on
/// the next run.
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

/// Core composition logic, factored out of `compose` so tests can drive
/// it with arbitrary directories (no dependency on $HOME or
/// $CLAUDE_CONFIG_DIR).
///
/// For every catalog resource we decide via `resources.policy(...)`
/// whether it should be a symlink to the default or a private dir, then
/// do whichever is appropriate. Symlinks are only created when the source
/// exists — we never leave dangling symlinks behind for resources the
/// user hasn't initialized in their real ~/.claude yet.
pub fn composeInto(
    allocator: Allocator,
    logger: Log,
    claude_dir: []const u8,
    profile_config: []const u8,
    shared: bool,
) !void {
    // Ensure the config directory exists
    try fsx.mkdirAll(profile_config);

    // Walk the catalog of known claude config resources and create each
    // one in the profile's config dir.
    for (resources.resources) |resource| {
        const should_share = resources.policy(resource, shared);
        // Propagate OOM. The previous `catch continue` silently dropped
        // resources on allocation failure, leaving the profile half-composed
        // with no diagnostic. On a GPA that is fatal anyway; surface it.
        const target_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{profile_config, resource.path},
        );
        defer allocator.free(target_path);

        const source_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{claude_dir, resource.path},
        );
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
