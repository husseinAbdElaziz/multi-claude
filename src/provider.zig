const std = @import("std");
const Allocator = std.mem.Allocator;
const fsx = @import("fsx.zig");
const config = @import("config.zig");

pub const Provider = struct {
    api_url: ?[]u8 = null,
    api_key: ?[]u8 = null,
    model: ?[]u8 = null,
    /// true when the provider speaks OpenAI Chat Completions API (needs Anthropic→OpenAI translation)
    openai_compat: bool = false,

    pub fn deinit(self: *Provider, allocator: Allocator) void {
        if (self.api_url) |s| allocator.free(s);
        if (self.api_key) |s| allocator.free(s);
        if (self.model) |s| allocator.free(s);
    }

    pub fn toJson(self: Provider, allocator: Allocator) ![]u8 {
        const type_str: []const u8 = if (self.openai_compat) "openai_compat" else "anthropic_compat";
        return std.json.Stringify.valueAlloc(allocator, .{
            .api_url = self.api_url,
            .api_key = self.api_key,
            .model = self.model,
            .type = type_str,
        }, .{ .whitespace = .indent_2 });
    }

    pub fn fromJson(allocator: Allocator, data: []const u8) !Provider {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
        defer parsed.deinit();

        var p = Provider{};
        errdefer p.deinit(allocator);

        if (parsed.value == .object) {
            if (parsed.value.object.get("api_url")) |v| {
                if (v == .string) p.api_url = try allocator.dupe(u8, v.string);
            }
            if (parsed.value.object.get("api_key")) |v| {
                if (v == .string) p.api_key = try allocator.dupe(u8, v.string);
            }
            if (parsed.value.object.get("model")) |v| {
                if (v == .string) p.model = try allocator.dupe(u8, v.string);
            }
            if (parsed.value.object.get("type")) |v| {
                if (v == .string) p.openai_compat = std.mem.eql(u8, v.string, "openai_compat");
            }
        }
        return p;
    }
};

/// Path to provider config. null profile_name = global default (~/.multi-claude/provider.json).
pub fn providerPath(allocator: Allocator, profile_name: ?[]const u8) ![]u8 {
    const home = try config.homeDir(allocator);
    defer allocator.free(home);
    if (profile_name) |name| {
        return std.fmt.allocPrint(allocator, "{s}/.multi-claude/profiles/{s}/provider.json", .{ home, name });
    }
    return std.fmt.allocPrint(allocator, "{s}/.multi-claude/provider.json", .{home});
}

/// Load provider for a profile with fallback: profile-specific → global default → null.
pub fn load(allocator: Allocator, profile_name: ?[]const u8) !?Provider {
    if (profile_name) |name| {
        const path = try providerPath(allocator, name);
        defer allocator.free(path);
        if (fsx.exists(path)) {
            const data = try fsx.readFile(allocator, path);
            defer allocator.free(data);
            return try Provider.fromJson(allocator, data);
        }
    }
    const global_path = try providerPath(allocator, null);
    defer allocator.free(global_path);
    if (fsx.exists(global_path)) {
        const data = try fsx.readFile(allocator, global_path);
        defer allocator.free(data);
        return try Provider.fromJson(allocator, data);
    }
    return null;
}

/// Load provider config directly (no fallback). Returns null if file absent.
pub fn loadDirect(allocator: Allocator, profile_name: ?[]const u8) !?Provider {
    const path = try providerPath(allocator, profile_name);
    defer allocator.free(path);
    if (!fsx.exists(path)) return null;
    const data = try fsx.readFile(allocator, path);
    defer allocator.free(data);
    return try Provider.fromJson(allocator, data);
}

pub fn save(allocator: Allocator, profile_name: ?[]const u8, p: Provider) !void {
    const path = try providerPath(allocator, profile_name);
    defer allocator.free(path);
    const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try fsx.mkdirAll(dir);
    const json = try p.toJson(allocator);
    defer allocator.free(json);
    try fsx.atomicWrite(allocator, path, json);
}

pub fn deleteConfig(allocator: Allocator, profile_name: ?[]const u8) !void {
    const path = try providerPath(allocator, profile_name);
    defer allocator.free(path);
    try fsx.remove(path);
}
