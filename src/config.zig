const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("stdlib.h");
});

/// Get the HOME directory path
pub fn homeDir(allocator: Allocator) ![]u8 {
    const name: [*:0]const u8 = "HOME";
    const home_ptr = c.getenv(name);
    if (home_ptr) |ptr| {
        return allocator.dupe(u8, std.mem.span(ptr));
    }
    return error.HomeDirectoryNotFound;
}

/// Returns the canonical path to the default claude config dir (~/.claude)
/// Respects CLAUDE_CONFIG_DIR if set.
pub fn canonicalClaudeDir(allocator: Allocator) ![]u8 {
    const custom = try getEnvVar(allocator, "CLAUDE_CONFIG_DIR");
    if (custom) |path| return path;

    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.claude", .{home});
}

/// Returns the path to ~/.multi-claude (our tool's config root)
pub fn mccDir(allocator: Allocator) ![]u8 {
    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.multi-claude", .{home});
}

/// Returns the path to ~/.multi-claude/config.zon
pub fn mccConfigPath(allocator: Allocator) ![]u8 {
    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.multi-claude/config.zon", .{home});
}

/// Returns the path to ~/.multi-claude/profiles/<name>
pub fn profileDir(allocator: Allocator, profile_name: []const u8) ![]u8 {
    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.multi-claude/profiles/{s}", .{
        home,
        profile_name,
    });
}

/// Returns the composed CLAUDE_CONFIG_DIR for a profile
pub fn profileConfigDir(allocator: Allocator, profile_name: []const u8) ![]u8 {
    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.multi-claude/profiles/{s}/config", .{
        home,
        profile_name,
    });
}

/// Returns the path to a profile's manifest
pub fn profileManifestPath(allocator: Allocator, profile_name: []const u8) ![]u8 {
    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.multi-claude/profiles/{s}/manifest.zon", .{
        home,
        profile_name,
    });
}

/// Returns the path to a profile's lock file
pub fn profileLockPath(allocator: Allocator, profile_name: []const u8) ![]u8 {
    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.multi-claude/profiles/{s}/run.lock", .{
        home,
        profile_name,
    });
}

/// Helper to get an optional env var
pub fn getEnvVar(allocator: Allocator, name: []const u8) !?[]u8 {
    // c.getenv needs a null-terminated string
    var buf: [65]u8 = undefined;
    if (name.len >= buf.len) return error.EnvironmentVariableNameTooLong;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const ptr = c.getenv(buf[0..name.len :0]);
    if (ptr) |p| {
        const val = try allocator.dupe(u8, std.mem.span(p));
        return val;
    }
    return null;
}
