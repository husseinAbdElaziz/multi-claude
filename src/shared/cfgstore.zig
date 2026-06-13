/// Generic on-disk store for profile-scoped JSON config files.
///
/// Each profile (or the global default) keeps a small set of JSON files
/// under `~/.multi-claude/`:
///   - `provider.json`  — single-provider override (see `provider.zig`)
///   - `providers.json` — multi-provider routing table (see `providers.zig`)
///
/// Both files share the same path layout, the same read/write/delete
/// lifecycle, and the same per-profile-vs-global lookup rules. This module
/// factors that shared logic into one place, parameterized by a type `T`
/// that must expose:
///   - `pub fn fromJson(allocator, []const u8) !T`  — parse
///   - `pub fn toJson(self, allocator) ![]u8`        — serialize
const std = @import("std");
const Allocator = std.mem.Allocator;
const fsx = @import("fsx.zig");
const config = @import("config.zig");

/// Build the filesystem path to `filename` for `profile_name`.
///
///   profile_name == null  →  ~/.multi-claude/<filename>          (global)
///   profile_name == "foo" →  ~/.multi-claude/profiles/foo/<filename>
///
/// Caller owns the returned slice and must `allocator.free` it.
pub fn profilePath(allocator: Allocator, profile_name: ?[]const u8, filename: []const u8) ![]u8 {
    const home = try config.homeDir(allocator);
    defer allocator.free(home);
    if (profile_name) |name| {
        return std.fmt.allocPrint(allocator, "{s}/.multi-claude/profiles/{s}/{s}", .{ home, name, filename });
    }
    return std.fmt.allocPrint(allocator, "{s}/.multi-claude/{s}", .{ home, filename });
}

/// Load `filename` with fallback: first try the profile-specific file, then
/// the global default. Returns null if neither exists. The "profile wins,
/// global is the default" rule is how per-profile overrides interact with a
/// shared machine-wide configuration.
pub fn load(comptime T: type, allocator: Allocator, profile_name: ?[]const u8, filename: []const u8) !?T {
    if (profile_name) |name| {
        if (try readAt(T, allocator, name, filename)) |v| return v;
    }
    return readAt(T, allocator, null, filename);
}

/// Load the exact path for `profile_name` (no fallback to global). Returns
/// null if that file doesn't exist. Use this when the caller needs to know
/// whether *this profile* has its own copy.
pub fn loadDirect(comptime T: type, allocator: Allocator, profile_name: ?[]const u8, filename: []const u8) !?T {
    return readAt(T, allocator, profile_name, filename);
}

/// Internal: read a specific file and parse it via `T.fromJson`. Returns
/// null on missing files; surfaces parse errors so a corrupt config crashes
/// loud rather than silently falling back to an empty default.
fn readAt(comptime T: type, allocator: Allocator, profile_name: ?[]const u8, filename: []const u8) !?T {
    const path = try profilePath(allocator, profile_name, filename);
    defer allocator.free(path);
    if (!fsx.exists(path)) return null;
    const data = try fsx.readFile(allocator, path);
    defer allocator.free(data);
    return try T.fromJson(allocator, data);
}

/// Serialize `value` to JSON, create any missing parent directories, and
/// write atomically (write-temp-then-rename) so a crash mid-write can't
/// corrupt an existing config.
pub fn save(comptime T: type, allocator: Allocator, profile_name: ?[]const u8, filename: []const u8, value: T) !void {
    const path = try profilePath(allocator, profile_name, filename);
    defer allocator.free(path);
    const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try fsx.mkdirAll(dir);
    const json = try value.toJson(allocator);
    defer allocator.free(json);
    try fsx.atomicWrite(allocator, path, json);
}

/// Delete the file for `profile_name`/`filename`. Idempotent — missing files
/// are not an error, since the caller is just trying to ensure it doesn't
/// exist.
pub fn delete(allocator: Allocator, profile_name: ?[]const u8, filename: []const u8) !void {
    const path = try profilePath(allocator, profile_name, filename);
    defer allocator.free(path);
    try fsx.remove(path);
}
