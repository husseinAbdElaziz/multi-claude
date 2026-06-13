const std = @import("std");
const Allocator = std.mem.Allocator;
const fsx = @import("../shared/fsx.zig");
const config = @import("../shared/config.zig");

pub const Manifest = struct {
    /// Profile name
    name: []u8,
    /// Whether this profile shares resources with the default profile
    shared: bool,
    /// Creation timestamp (unix epoch seconds)
    created_at: u64,

    /// Serialize to ZON format
    pub fn toZon(self: Manifest, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\{{
            \\    .name = ".{s}",
            \\    .shared = {s},
            \\    .created_at = 0x{x},
            \\}}
        , .{
            self.name,
            if (self.shared) "true" else "false",
            self.created_at,
        });
    }

    /// Parse from ZON format (simple parser)
    pub fn fromZon(allocator: Allocator, data: []const u8) !Manifest {
        // `name` starts as an owned empty string so it is never `undefined`:
        // a corrupt manifest missing `.name` still yields a value that callers
        // can safely `allocator.free`.
        var manifest: Manifest = .{
            .name = try allocator.dupe(u8, ""),
            .shared = true,
            .created_at = 0,
        };
        errdefer allocator.free(manifest.name);

        // Parse .name field
        const name_idx = std.mem.indexOf(u8, data, ".name");
        if (name_idx) |idx| {
            const rest = data[idx..];
            const eq_idx = std.mem.indexOf(u8, rest, "=");
            if (eq_idx) |eidx| {
                var value = parseZonValue(rest[eidx + 1..]);
                // Remove surrounding quotes first, then dot
                if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                    value = value[1..value.len - 1];
                }
                if (value.len >= 1 and value[0] == '.') {
                    value = value[1..];
                }
                allocator.free(manifest.name);
                manifest.name = try allocator.dupe(u8, value);
            }
        }

        // Parse .shared field
        const shared_idx = std.mem.indexOf(u8, data, ".shared");
        if (shared_idx) |idx| {
            const rest = data[idx..];
            const eq_idx = std.mem.indexOf(u8, rest, "=");
            if (eq_idx) |eidx| {
                const value = parseZonValue(rest[eidx + 1..]);
                manifest.shared = std.mem.eql(u8, value, "true");
            }
        }

        // Parse .created_at field
        const created_idx = std.mem.indexOf(u8, data, ".created_at");
        if (created_idx) |idx| {
            const rest = data[idx..];
            const eq_idx = std.mem.indexOf(u8, rest, "=");
            if (eq_idx) |eidx| {
                const value = parseZonValue(rest[eidx + 1..]);
                // base 0 auto-detects the "0x" prefix written by toZon.
                manifest.created_at = std.fmt.parseUnsigned(u64, value, 0) catch 0;
            }
        }

        return manifest;
    }

    /// Extract a single ZON value from a string starting after the '=' sign
    fn parseZonValue(data: []const u8) []const u8 {
        var trimmed = std.mem.trim(u8, data, " \t");
        // Stop at comma, newline, or closing brace
        const end = std.mem.indexOfAny(u8, trimmed, ",\n}");
        if (end) |e| {
            trimmed = std.mem.trim(u8, trimmed[0..e], " \t");
        }
        return trimmed;
    }

    /// Save to disk
    pub fn save(self: Manifest, allocator: Allocator) !void {
        const path = try config.profileManifestPath(allocator, self.name);
        defer allocator.free(path);

        const content = try self.toZon(allocator);
        defer allocator.free(content);

        // Ensure directory exists
        const dir_end = std.fs.path.dirname(path).?.len;
        try fsx.mkdirAll(path[0..dir_end]);

        try fsx.atomicWrite(allocator, path, content);
    }

    /// Load from disk
    pub fn load(allocator: Allocator, profile_name: []const u8) !Manifest {
        const path = try config.profileManifestPath(allocator, profile_name);
        defer allocator.free(path);

        const data = try fsx.readFile(allocator, path);
        defer allocator.free(data);

        return fromZon(allocator, data);
    }
};
