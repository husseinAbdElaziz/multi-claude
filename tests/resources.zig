const std = @import("std");
const resources = @import("src").resources;

test "resources: settings.json is shared by default" {
    const res = resources.resources[0];
    try std.testing.expectEqualStrings("settings.json", res.path);
    try std.testing.expect(!res.is_dir);
    try std.testing.expect(res.default_shared);
}

test "resources: skills is shared directory" {
    const res = resources.resources[2];
    try std.testing.expectEqualStrings("skills", res.path);
    try std.testing.expect(res.is_dir);
    try std.testing.expect(res.default_shared);
}

test "resources: sessions is private by default" {
    const res = resources.resources[4];
    try std.testing.expectEqualStrings("sessions", res.path);
    try std.testing.expect(res.is_dir);
    try std.testing.expect(!res.default_shared);
}

test "resources: plugins is shared" {
    const res = resources.resources[3];
    try std.testing.expectEqualStrings("plugins", res.path);
    try std.testing.expect(res.is_dir);
    try std.testing.expect(res.default_shared);
}

test "resources: credentials is private" {
    // Locate by path rather than index so the test survives catalog reordering.
    const res = findResource(".credentials.json").?;
    try std.testing.expect(!res.is_dir);
    try std.testing.expect(!res.default_shared);
}

fn findResource(path: []const u8) ?resources.Resource {
    for (resources.resources) |res| {
        if (std.mem.eql(u8, res.path, path)) return res;
    }
    return null;
}

test "resources: policy returns shared for shared profile" {
    const res = resources.resources[0]; // settings.json
    try std.testing.expect(resources.policy(res, true));
}

test "resources: policy returns false for no-share profile" {
    const res = resources.resources[0]; // settings.json (normally shared)
    try std.testing.expectEqual(false, resources.policy(res, false));
}

test "resources: policy preserves private resources even for shared profile" {
    const res = resources.resources[4]; // sessions (normally private)
    try std.testing.expectEqual(false, resources.policy(res, true));
}

test "resources: private files vs directories are consistent" {
    // Private file resources (credentials + session history log) are not
    // directories; every other private resource is a directory.
    for (resources.resources) |res| {
        if (res.default_shared) continue;
        const is_known_file = std.mem.eql(u8, res.path, ".credentials.json") or
            std.mem.eql(u8, res.path, "history.jsonl");
        if (is_known_file) {
            try std.testing.expect(!res.is_dir);
        } else {
            try std.testing.expect(res.is_dir);
        }
    }
}

test "resources: resource count" {
    // 4 shared + 10 private = 14 resources
    try std.testing.expectEqual(@as(usize, 14), resources.resources.len);
}
