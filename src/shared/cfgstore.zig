/// Generic store for profile-scoped JSON config files under ~/.multi-claude.
///
/// Both `provider.json` (single provider) and `providers.json` (multi-provider
/// routing table) share the exact same path layout and read/write lifecycle;
/// only the filename and the serialized type differ. This module captures that
/// shared logic, parameterized by a type `T` that exposes:
///   - `pub fn fromJson(allocator, []const u8) !T`
///   - `pub fn toJson(self, allocator) ![]u8`
const std = @import("std");
const Allocator = std.mem.Allocator;
const fsx = @import("fsx.zig");
const config = @import("config.zig");

/// Path to `filename` for a profile. null profile_name → global default
/// (~/.multi-claude/<filename>); otherwise the per-profile copy.
pub fn profilePath(allocator: Allocator, profile_name: ?[]const u8, filename: []const u8) ![]u8 {
    const home = try config.homeDir(allocator);
    defer allocator.free(home);
    if (profile_name) |name| {
        return std.fmt.allocPrint(allocator, "{s}/.multi-claude/profiles/{s}/{s}", .{ home, name, filename });
    }
    return std.fmt.allocPrint(allocator, "{s}/.multi-claude/{s}", .{ home, filename });
}

/// Load with fallback: profile-specific → global default → null.
pub fn load(comptime T: type, allocator: Allocator, profile_name: ?[]const u8, filename: []const u8) !?T {
    if (profile_name) |name| {
        if (try readAt(T, allocator, name, filename)) |v| return v;
    }
    return readAt(T, allocator, null, filename);
}

/// Load the exact path (no fallback). Returns null if the file is absent.
pub fn loadDirect(comptime T: type, allocator: Allocator, profile_name: ?[]const u8, filename: []const u8) !?T {
    return readAt(T, allocator, profile_name, filename);
}

fn readAt(comptime T: type, allocator: Allocator, profile_name: ?[]const u8, filename: []const u8) !?T {
    const path = try profilePath(allocator, profile_name, filename);
    defer allocator.free(path);
    if (!fsx.exists(path)) return null;
    const data = try fsx.readFile(allocator, path);
    defer allocator.free(data);
    return try T.fromJson(allocator, data);
}

/// Serialize `value` and write it atomically, creating parent dirs as needed.
pub fn save(comptime T: type, allocator: Allocator, profile_name: ?[]const u8, filename: []const u8, value: T) !void {
    const path = try profilePath(allocator, profile_name, filename);
    defer allocator.free(path);
    const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try fsx.mkdirAll(dir);
    const json = try value.toJson(allocator);
    defer allocator.free(json);
    try fsx.atomicWrite(allocator, path, json);
}

/// Remove the config file (idempotent).
pub fn delete(allocator: Allocator, profile_name: ?[]const u8, filename: []const u8) !void {
    const path = try profilePath(allocator, profile_name, filename);
    defer allocator.free(path);
    try fsx.remove(path);
}
