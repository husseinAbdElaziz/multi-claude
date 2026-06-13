const std = @import("std");
const Allocator = std.mem.Allocator;

/// One row in the resources catalog: a single file or directory under
/// CLAUDE_CONFIG_DIR and the policy for whether to share it across
/// profiles by default.
pub const Resource = struct {
    /// Path relative to the claude config root, e.g. "settings.json" or
    /// "sessions".
    path: []const u8,
    /// True if this entry is a directory (needs `mkdirAll`), false for a
    /// file (we don't pre-create those — claude creates them on first use).
    is_dir: bool,

    /// Default sharing policy. When the profile is shared (the default),
    /// entries with `default_shared = true` are symlinked to ~/.claude;
    /// entries with `default_shared = false` get a per-profile private
    /// dir. With `--no-share`, every entry is private regardless.
    default_shared: bool,
};

/// Catalog of every file/directory under CLAUDE_CONFIG_DIR that mcc
/// knows about, with the default sharing policy for each.
///
/// This is the single source of truth for "what's in a claude config dir
/// and should it be shared with other profiles". Adding a new claude
/// resource that's safe to share is a one-line change here; making a
/// previously-shared resource private is a one-line change too (flip
/// `default_shared`).
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

/// Resolve the effective sharing policy for a resource in a profile with
/// the given sharing mode:
///
///   profile_shared = false  → always false (--no-share means nothing shared)
///   profile_shared = true   → resource's own `default_shared`
pub fn policy(resource: Resource, profile_shared: bool) bool {
    if (!profile_shared) return false; // --no-share: nothing is shared
    return resource.default_shared;
}
