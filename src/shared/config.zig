const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("stdlib.h");
});

/// Read $HOME and return it as an allocated string. Errors with
/// `error.HomeDirectoryNotFound` when the env var is unset (extremely
/// unusual on macOS/Linux, can happen in stripped-down containers).
pub fn homeDir(allocator: Allocator) ![]u8 {
    const name: [*:0]const u8 = "HOME";
    const home_ptr = c.getenv(name);
    if (home_ptr) |ptr| {
        return allocator.dupe(u8, std.mem.span(ptr));
    }
    return error.HomeDirectoryNotFound;
}

/// Resolve the user's "real" claude config dir:
///
///   $CLAUDE_CONFIG_DIR (if set and non-empty) → used as-is
///   $HOME/.claude                              → fallback
///
/// This is the dir the "default" profile is. The launcher never
/// modifies it — only non-default profiles are under mcc's control.
pub fn canonicalClaudeDir(allocator: Allocator) ![]u8 {
    const custom = try getEnvVar(allocator, "CLAUDE_CONFIG_DIR");
    if (custom) |path| return path;

    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.claude", .{home});
}

/// Path to mcc's own config root (`~/.multi-claude`). Holds the
/// `profiles/`, the global `provider.json`, the update-check cache,
/// etc. Created lazily by `mcc new` or `mcc ui`.
pub fn mccDir(allocator: Allocator) ![]u8 {
    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.multi-claude", .{home});
}

/// Path to mcc's reserved config file (`~/.multi-claude/config.zon`).
/// Currently unused by the launcher but reserved for future global
/// settings; surfaced so the install / update commands don't collide
/// with it.
pub fn mccConfigPath(allocator: Allocator) ![]u8 {
    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.multi-claude/config.zon", .{home});
}

/// Internal helper: build `<home>/.multi-claude/profiles/<name><suffix>`.
/// `suffix` is "" for the profile root, "/config" for the composed
/// CLAUDE_CONFIG_DIR, "/manifest.zon" for the metadata file, etc.
/// Every per-profile path in the project is expressed in terms of
/// this function so the layout is defined in one place.
fn profileSubpath(allocator: Allocator, profile_name: []const u8, suffix: []const u8) ![]u8 {
    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.multi-claude/profiles/{s}{s}", .{
        home,
        profile_name,
        suffix,
    });
}

/// Root directory of a profile (`~/.multi-claude/profiles/<name>`).
/// Contains the manifest, the composed `config/`, the run lock, and
/// any provider config.
pub fn profileDir(allocator: Allocator, profile_name: []const u8) ![]u8 {
    return profileSubpath(allocator, profile_name, "");
}

/// The composed CLAUDE_CONFIG_DIR for a profile — what mcc sets
/// `CLAUDE_CONFIG_DIR` to when launching that profile. Inside, shared
/// resources are symlinks to ~/.claude, private resources are empty
/// dirs ready for claude to populate.
pub fn profileConfigDir(allocator: Allocator, profile_name: []const u8) ![]u8 {
    return profileSubpath(allocator, profile_name, "/config");
}

/// Path to a profile's metadata file (`manifest.zon`).
pub fn profileManifestPath(allocator: Allocator, profile_name: []const u8) ![]u8 {
    return profileSubpath(allocator, profile_name, "/manifest.zon");
}

/// Path to a profile's advisory run lock (`run.lock`). Held by the
/// launcher for the duration of the child `claude` process; prevents
/// two instances of the same profile from clobbering each other's
/// sessions.
pub fn profileLockPath(allocator: Allocator, profile_name: []const u8) ![]u8 {
    return profileSubpath(allocator, profile_name, "/run.lock");
}

/// Read an environment variable by name, returning an allocated copy
/// of its value or null when unset. `name` must be ≤ 64 chars (a
/// defensive cap; real env names are much shorter).
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
