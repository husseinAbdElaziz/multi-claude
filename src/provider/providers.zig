const std = @import("std");
const Allocator = std.mem.Allocator;
const cfgstore = @import("../shared/cfgstore.zig");

const FILE = "providers.json";

pub const ProviderType = enum {
    anthropic_compat, // speaks Anthropic Messages API (e.g. OpenRouter, any Anthropic-format proxy)
    openai_compat,    // speaks OpenAI Chat Completions API (Ollama, LM Studio, OpenAI, Groq, etc.)
};

pub const ProviderEntry = struct {
    name: []u8,
    provider_type: ProviderType,
    api_url: []u8,
    api_key: ?[]u8,
    /// Model names this provider handles. "*" matches anything.
    models: [][]u8,

    pub fn deinit(self: *ProviderEntry, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.api_url);
        if (self.api_key) |k| allocator.free(k);
        for (self.models) |m| allocator.free(m);
        allocator.free(self.models);
    }

    pub fn matchesModel(self: *const ProviderEntry, model: []const u8) bool {
        for (self.models) |m| {
            if (std.mem.eql(u8, m, "*")) return true;
            if (std.mem.eql(u8, m, model)) return true;
            // prefix glob: "llama*" matches "llama3.2:latest"
            if (m.len > 0 and m[m.len - 1] == '*') {
                if (std.mem.startsWith(u8, model, m[0 .. m.len - 1])) return true;
            }
            // provider-prefixed id: Claude Code may prepend routing segments,
            // e.g. "anthropic/lmstudio/<configured>". Match the bare suffix
            // at a '/' boundary.
            if (m.len < model.len and std.mem.endsWith(u8, model, m) and
                model[model.len - m.len - 1] == '/') return true;
        }
        return false;
    }

    /// Model id to send upstream. Strips provider-routing prefixes Claude Code
    /// may prepend (e.g. "anthropic/lmstudio/<model>") down to the configured
    /// id. Returns `requested` unchanged for exact matches, globs, and "*".
    pub fn resolveModel(self: *const ProviderEntry, requested: []const u8) []const u8 {
        for (self.models) |m| {
            if (std.mem.eql(u8, m, "*")) continue; // wildcard: pass through
            if (std.mem.eql(u8, m, requested)) return requested; // exact
            if (m.len > 0 and m[m.len - 1] == '*') { // glob: pass through
                if (std.mem.startsWith(u8, requested, m[0 .. m.len - 1])) return requested;
            }
            if (m.len < requested.len and std.mem.endsWith(u8, requested, m) and
                requested[requested.len - m.len - 1] == '/') return m; // strip prefix
        }
        return requested;
    }
};

test "matchesModel: exact, wildcard, glob, prefix-boundary, non-match" {
    const t = std.testing;
    var exact = [_][]u8{@constCast("cyankiwi/Qwen3.6-27B-AWQ-INT4")};
    const pe = ProviderEntry{
        .name = @constCast("p"),
        .provider_type = .openai_compat,
        .api_url = @constCast("http://x/v1"),
        .api_key = null,
        .models = &exact,
    };
    try t.expect(pe.matchesModel("cyankiwi/Qwen3.6-27B-AWQ-INT4"));
    try t.expect(pe.matchesModel("anthropic/lmstudio/cyankiwi/Qwen3.6-27B-AWQ-INT4"));
    try t.expect(!pe.matchesModel("claude-sonnet-4-6"));

    var star = [_][]u8{@constCast("*")};
    const pw = ProviderEntry{ .name = @constCast("w"), .provider_type = .openai_compat, .api_url = @constCast("u"), .api_key = null, .models = &star };
    try t.expect(pw.matchesModel("anything"));

    var glob = [_][]u8{@constCast("llama*")};
    const pg = ProviderEntry{ .name = @constCast("g"), .provider_type = .openai_compat, .api_url = @constCast("u"), .api_key = null, .models = &glob };
    try t.expect(pg.matchesModel("llama3.2:latest"));

    // substring without a '/' boundary must NOT match
    var bar = [_][]u8{@constCast("bar")};
    const pb = ProviderEntry{ .name = @constCast("b"), .provider_type = .openai_compat, .api_url = @constCast("u"), .api_key = null, .models = &bar };
    try t.expect(!pb.matchesModel("foobar"));
}

test "resolveModel: strips prefix, preserves exact/glob/wildcard" {
    const t = std.testing;
    var exact = [_][]u8{@constCast("cyankiwi/Qwen3.6-27B-AWQ-INT4")};
    const pe = ProviderEntry{ .name = @constCast("p"), .provider_type = .openai_compat, .api_url = @constCast("u"), .api_key = null, .models = &exact };
    try t.expectEqualStrings("cyankiwi/Qwen3.6-27B-AWQ-INT4", pe.resolveModel("anthropic/lmstudio/cyankiwi/Qwen3.6-27B-AWQ-INT4"));
    try t.expectEqualStrings("cyankiwi/Qwen3.6-27B-AWQ-INT4", pe.resolveModel("cyankiwi/Qwen3.6-27B-AWQ-INT4"));

    var star = [_][]u8{@constCast("*")};
    const pw = ProviderEntry{ .name = @constCast("w"), .provider_type = .openai_compat, .api_url = @constCast("u"), .api_key = null, .models = &star };
    try t.expectEqualStrings("anthropic/foo", pw.resolveModel("anthropic/foo"));

    var glob = [_][]u8{@constCast("llama*")};
    const pg = ProviderEntry{ .name = @constCast("g"), .provider_type = .openai_compat, .api_url = @constCast("u"), .api_key = null, .models = &glob };
    try t.expectEqualStrings("llama3.2:latest", pg.resolveModel("llama3.2:latest"));
}

pub const Config = struct {
    entries: []ProviderEntry,

    pub fn deinit(self: *Config, allocator: Allocator) void {
        for (self.entries) |*e| e.deinit(allocator);
        allocator.free(self.entries);
    }

    pub fn findProvider(self: *const Config, model: []const u8) ?*const ProviderEntry {
        for (self.entries) |*e| {
            if (e.matchesModel(model)) return e;
        }
        return null;
    }

    pub fn toJson(self: Config, allocator: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("[\n");
        for (self.entries, 0..) |e, i| {
            if (i > 0) try w.writeAll(",\n");
            try w.writeAll("  {\n");
            try w.print("    \"name\": \"{s}\",\n", .{e.name});
            try w.print("    \"type\": \"{s}\",\n", .{@tagName(e.provider_type)});
            try w.print("    \"api_url\": \"{s}\",\n", .{e.api_url});
            if (e.api_key) |k| {
                try w.print("    \"api_key\": \"{s}\",\n", .{k});
            } else {
                try w.writeAll("    \"api_key\": null,\n");
            }
            try w.writeAll("    \"models\": [");
            for (e.models, 0..) |m, j| {
                if (j > 0) try w.writeAll(", ");
                try w.print("\"{s}\"", .{m});
            }
            try w.writeAll("]\n  }");
        }
        try w.writeAll("\n]");
        return out.toOwnedSlice();
    }

    pub fn fromJson(allocator: Allocator, data: []const u8) !Config {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
        defer parsed.deinit();

        if (parsed.value != .array) return error.InvalidConfig;
        const arr = &parsed.value.array;

        var entries: std.ArrayList(ProviderEntry) = .empty;
        errdefer {
            for (entries.items) |*e| e.deinit(allocator);
            entries.deinit(allocator);
        }

        for (arr.items) |item| {
            if (item != .object) continue;
            const obj = &item.object;

            const name_v = obj.get("name") orelse continue;
            if (name_v != .string) continue;

            const type_v = obj.get("type") orelse continue;
            if (type_v != .string) continue;
            const ptype: ProviderType = if (std.mem.eql(u8, type_v.string, "openai_compat"))
                .openai_compat
            else
                .anthropic_compat;

            const url_v = obj.get("api_url") orelse continue;
            if (url_v != .string) continue;

            var api_key: ?[]u8 = null;
            if (obj.get("api_key")) |kv| {
                if (kv == .string) api_key = try allocator.dupe(u8, kv.string);
            }

            var models_list: std.ArrayList([]u8) = .empty;
            errdefer {
                for (models_list.items) |m| allocator.free(m);
                models_list.deinit(allocator);
            }
            if (obj.get("models")) |mv| {
                if (mv == .array) {
                    for (mv.array.items) |mi| {
                        if (mi == .string) {
                            try models_list.append(allocator, try allocator.dupe(u8, mi.string));
                        }
                    }
                }
            }

            try entries.append(allocator, .{
                .name = try allocator.dupe(u8, name_v.string),
                .provider_type = ptype,
                .api_url = try allocator.dupe(u8, url_v.string),
                .api_key = api_key,
                .models = try models_list.toOwnedSlice(allocator),
            });
        }

        return Config{ .entries = try entries.toOwnedSlice(allocator) };
    }
};

pub fn providersPath(allocator: Allocator, profile_name: ?[]const u8) ![]u8 {
    return cfgstore.profilePath(allocator, profile_name, FILE);
}

/// Load providers config with fallback: profile-specific → global default → null.
pub fn load(allocator: Allocator, profile_name: ?[]const u8) !?Config {
    return cfgstore.load(Config, allocator, profile_name, FILE);
}

pub fn loadDirect(allocator: Allocator, profile_name: ?[]const u8) !?Config {
    return cfgstore.loadDirect(Config, allocator, profile_name, FILE);
}

pub fn save(allocator: Allocator, profile_name: ?[]const u8, cfg: Config) !void {
    return cfgstore.save(Config, allocator, profile_name, FILE, cfg);
}

pub fn deleteConfig(allocator: Allocator, profile_name: ?[]const u8) !void {
    return cfgstore.delete(allocator, profile_name, FILE);
}
