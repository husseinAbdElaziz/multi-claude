const std = @import("std");
const Manifest = @import("src").manifest.Manifest;

test "manifest: toZon produces valid ZON" {
    const gpa = std.testing.allocator;
    var m: Manifest = .{
        .name = gpa.dupe(u8, "test-profile") catch unreachable,
        .shared = true,
        .created_at = 12345,
    };
    defer gpa.free(m.name);

    const zon = try m.toZon(gpa);
    defer gpa.free(zon);

    try std.testing.expect(std.mem.indexOf(u8, zon, ".name = \".test-profile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".shared = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".created_at = 0x3039") != null);
}

test "manifest: toZon with shared=false" {
    const gpa = std.testing.allocator;
    var m: Manifest = .{
        .name = gpa.dupe(u8, "isolated") catch unreachable,
        .shared = false,
        .created_at = 0,
    };
    defer gpa.free(m.name);

    const zon = try m.toZon(gpa);
    defer gpa.free(zon);

    try std.testing.expect(std.mem.indexOf(u8, zon, ".shared = false") != null);
}

test "manifest: fromZon parses shared manifest" {
    const gpa = std.testing.allocator;
    const data =
        \\{
        \\    .name = ".test-profile",
        \\    .shared = true,
        \\    .created_at = 0x3039,
        \\}
    ;

    const m = try Manifest.fromZon(gpa, data);
    defer gpa.free(m.name);

    try std.testing.expectEqualStrings("test-profile", m.name);
    try std.testing.expect(m.shared);
    try std.testing.expectEqual(@as(u64, 12345), m.created_at);
}

test "manifest: fromZon parses isolated manifest" {
    const gpa = std.testing.allocator;
    const data =
        \\{
        \\    .name = ".work",
        \\    .shared = false,
        \\    .created_at = 0x0,
        \\}
    ;

    const m = try Manifest.fromZon(gpa, data);
    defer gpa.free(m.name);

    try std.testing.expectEqualStrings("work", m.name);
    try std.testing.expect(!m.shared);
    try std.testing.expectEqual(@as(u64, 0), m.created_at);
}

test "manifest: round-trip" {
    const gpa = std.testing.allocator;
    var original: Manifest = .{
        .name = gpa.dupe(u8, "roundtrip") catch unreachable,
        .shared = true,
        .created_at = 99999,
    };
    defer gpa.free(original.name);

    const zon = try original.toZon(gpa);
    defer gpa.free(zon);

    const parsed = try Manifest.fromZon(gpa, zon);
    defer gpa.free(parsed.name);

    try std.testing.expectEqualStrings(original.name, parsed.name);
    try std.testing.expectEqual(original.shared, parsed.shared);
    try std.testing.expectEqual(original.created_at, parsed.created_at);
}

test "manifest: round-trip with no-share" {
    const gpa = std.testing.allocator;
    var original: Manifest = .{
        .name = gpa.dupe(u8, "isolated-trip") catch unreachable,
        .shared = false,
        .created_at = 0xdeadbeef,
    };
    defer gpa.free(original.name);

    const zon = try original.toZon(gpa);
    defer gpa.free(zon);

    const parsed = try Manifest.fromZon(gpa, zon);
    defer gpa.free(parsed.name);

    try std.testing.expectEqualStrings(original.name, parsed.name);
    try std.testing.expectEqual(original.shared, parsed.shared);
    try std.testing.expectEqual(original.created_at, parsed.created_at);
}
