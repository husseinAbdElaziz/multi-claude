const std = @import("std");
const Allocator = std.mem.Allocator;
const cfgstore = @import("../shared/cfgstore.zig");

const FILE = "provider.json";

/// One provider's configuration, persisted as `provider.json`.
///
/// This is the "simple" provider model: a profile (or the global
/// default) can have at most one provider, and the launcher uses
/// `openai_compat` to decide whether to set env vars directly
/// (anthropic_compat) or route through the proxy with translation
/// (openai_compat).
///
/// All string fields are owned slices — `deinit` frees them.
pub const Provider = struct {
    /// Base URL of the provider (e.g. "https://openrouter.ai/api" or
    /// "http://localhost:1234/v1").
    api_url: ?[]u8 = null,
    /// API key for the provider. Null is meaningful for local servers
    /// (LM Studio / Ollama) that don't require auth.
    api_key: ?[]u8 = null,
    /// Model id to request. When null, the proxy will pass through
    /// whatever model Claude Code asks for.
    model: ?[]u8 = null,
    /// True when the provider speaks OpenAI Chat Completions API. The
    /// proxy then translates Anthropic↔OpenAI on the wire. False means
    /// the provider speaks the Anthropic Messages API directly and
    /// translation is skipped.
    openai_compat: bool = false,

    /// Free all owned string fields. Safe to call multiple times on
    /// different subsets (each field is independently nulled by
    /// ownership transfers elsewhere in the launcher).
    pub fn deinit(self: *Provider, allocator: Allocator) void {
        if (self.api_url) |s| allocator.free(s);
        if (self.api_key) |s| allocator.free(s);
        if (self.model) |s| allocator.free(s);
    }

    /// Serialize to pretty-printed JSON (2-space indent) for
    /// human-readable provider.json files. The `type` field is
    /// `"openai_compat"` or `"anthropic_compat"`.
    pub fn toJson(self: Provider, allocator: Allocator) ![]u8 {
        const type_str: []const u8 = if (self.openai_compat) "openai_compat" else "anthropic_compat";
        return std.json.Stringify.valueAlloc(allocator, .{
            .api_url = self.api_url,
            .api_key = self.api_key,
            .model = self.model,
            .type = type_str,
        }, .{ .whitespace = .indent_2 });
    }

    /// Parse provider.json. Missing fields default to null/false, so a
    /// minimal `{"api_url": "...", "type": "openai_compat"}` is valid.
    /// Unknown fields are ignored.
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

/// Build the filesystem path to a profile's `provider.json`. Null
/// `profile_name` resolves to the global default
/// (`~/.multi-claude/provider.json`).
pub fn providerPath(allocator: Allocator, profile_name: ?[]const u8) ![]u8 {
    return cfgstore.profilePath(allocator, profile_name, FILE);
}

/// Load provider config with fallback: profile-specific → global default
/// → null. The launcher uses this to pick up the right provider for
/// the active profile.
pub fn load(allocator: Allocator, profile_name: ?[]const u8) !?Provider {
    return cfgstore.load(Provider, allocator, profile_name, FILE);
}

/// Load provider config directly (no fallback). The web UI uses this
/// to show whether THIS profile has its own provider (vs. inheriting
/// the global default).
pub fn loadDirect(allocator: Allocator, profile_name: ?[]const u8) !?Provider {
    return cfgstore.loadDirect(Provider, allocator, profile_name, FILE);
}

pub fn save(allocator: Allocator, profile_name: ?[]const u8, p: Provider) !void {
    return cfgstore.save(Provider, allocator, profile_name, FILE, p);
}

pub fn deleteConfig(allocator: Allocator, profile_name: ?[]const u8) !void {
    return cfgstore.delete(allocator, profile_name, FILE);
}
