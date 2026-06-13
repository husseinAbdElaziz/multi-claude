const std = @import("std");
const Allocator = std.mem.Allocator;

/// Resource types that can be shared or kept private per profile
pub const Resource = struct {
    /// Relative path within CLAUDE_CONFIG_DIR
    path: []const u8,
    /// Whether this is a directory (vs a file)
    is_dir: bool,

    /// Default policy: shared across profiles (symlinked to ~/.claude)
    default_shared: bool,
};

/// Catalog of all claude config resources and their default sharing policy
pub const resources: []const Resource = &.{
    // Shared by default (symlinked to ~/.claude)
    Resource{ .path = "settings.json", .is_dir = false, .default_shared = true },
    Resource{ .path = "CLAUDE.md", .is_dir = false, .default_shared = true },
    Resource{ .path = "skills", .is_dir = true, .default_shared = true },
    Resource{ .path = "plugins", .is_dir = true, .default_shared = true },

    // Private by default (per-profile)
    Resource{ .path = "sessions", .is_dir = true, .default_shared = false },
    Resource{ .path = "history.jsonl", .is_dir = false, .default_shared = false },
    Resource{ .path = "shell-snapshots", .is_dir = true, .default_shared = false },
    Resource{ .path = "todos", .is_dir = true, .default_shared = false },
    Resource{ .path = "projects", .is_dir = true, .default_shared = false },
    Resource{ .path = "file-history", .is_dir = true, .default_shared = false },
    Resource{ .path = "paste-cache", .is_dir = true, .default_shared = false },
    Resource{ .path = "telemetry", .is_dir = true, .default_shared = false },
    Resource{ .path = "statsig", .is_dir = true, .default_shared = false },
    Resource{ .path = ".credentials.json", .is_dir = false, .default_shared = false },
};

/// Get the sharing policy for a resource given whether the profile is shared
pub fn policy(resource: Resource, profile_shared: bool) bool {
    if (!profile_shared) return false; // --no-share: nothing is shared
    return resource.default_shared;
}
