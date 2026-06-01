const std = @import("std");
const cli = @import("src").cli;
const profile = @import("src").profile;

test "cli: parse empty args returns run_default" {
    const gpa = std.testing.allocator;
    const parsed = try cli.parse(gpa, &.{});
    defer cli.deinit(parsed, gpa);

    try std.testing.expectEqual(cli.Command.run_default, parsed.command);
    try std.testing.expect(parsed.profile == null);
}

test "cli: parse --help" {
    const gpa = std.testing.allocator;
    const parsed = try cli.parse(gpa, &.{ "--help" });
    defer cli.deinit(parsed, gpa);

    try std.testing.expectEqual(cli.Command.help, parsed.command);
}

test "cli: parse -h" {
    const gpa = std.testing.allocator;
    const parsed = try cli.parse(gpa, &.{ "-h" });
    defer cli.deinit(parsed, gpa);

    try std.testing.expectEqual(cli.Command.help, parsed.command);
}

test "cli: parse --version" {
    const gpa = std.testing.allocator;
    const parsed = try cli.parse(gpa, &.{ "--version" });
    defer cli.deinit(parsed, gpa);

    try std.testing.expectEqual(cli.Command.version, parsed.command);
}

test "cli: parse -v" {
    const gpa = std.testing.allocator;
    const parsed = try cli.parse(gpa, &.{ "-v" });
    defer cli.deinit(parsed, gpa);

    try std.testing.expectEqual(cli.Command.version, parsed.command);
}

test "cli: parse doctor" {
    const gpa = std.testing.allocator;
    const parsed = try cli.parse(gpa, &.{ "doctor" });
    defer cli.deinit(parsed, gpa);

    try std.testing.expectEqual(cli.Command.doctor, parsed.command);
}

test "cli: parse ls" {
    const gpa = std.testing.allocator;
    const parsed = try cli.parse(gpa, &.{ "ls" });
    defer cli.deinit(parsed, gpa);

    try std.testing.expectEqual(cli.Command.ls, parsed.command);
}

test "cli: parse new <profile>" {
    const gpa = std.testing.allocator;
    const parsed = try cli.parse(gpa, &.{ "new", "personal" });
    defer cli.deinit(parsed, gpa);

    try std.testing.expectEqual(cli.Command.new, parsed.command);
    try std.testing.expect(parsed.profile != null);
    try std.testing.expectEqualStrings("personal", parsed.profile.?);
    try std.testing.expect(!parsed.no_share);
}

test "cli: parse new <profile> --no-share" {
    const gpa = std.testing.allocator;
    const parsed = try cli.parse(gpa, &.{ "new", "work", "--no-share" });
    defer cli.deinit(parsed, gpa);

    try std.testing.expectEqual(cli.Command.new, parsed.command);
    try std.testing.expectEqualStrings("work", parsed.profile.?);
    try std.testing.expect(parsed.no_share);
}

test "cli: parse delete <profile>" {
    const gpa = std.testing.allocator;
    const parsed = try cli.parse(gpa, &.{ "delete", "personal" });
    defer cli.deinit(parsed, gpa);

    try std.testing.expectEqual(cli.Command.delete, parsed.command);
    try std.testing.expectEqualStrings("personal", parsed.profile.?);
}

test "cli: parse which <profile>" {
    const gpa = std.testing.allocator;
    const parsed = try cli.parse(gpa, &.{ "which", "personal" });
    defer cli.deinit(parsed, gpa);

    try std.testing.expectEqual(cli.Command.which, parsed.command);
    try std.testing.expectEqualStrings("personal", parsed.profile.?);
}

test "cli: parse run_profile" {
    const gpa = std.testing.allocator;
    const parsed = try cli.parse(gpa, &.{ "personal" });
    defer cli.deinit(parsed, gpa);

    try std.testing.expectEqual(cli.Command.run_profile, parsed.command);
    try std.testing.expectEqualStrings("personal", parsed.profile.?);
}

test "cli: parse run_profile with extra args" {
    const gpa = std.testing.allocator;
    const parsed = try cli.parse(gpa, &.{ "personal", "--", "--resume" });
    defer cli.deinit(parsed, gpa);

    try std.testing.expectEqual(cli.Command.run_profile, parsed.command);
    try std.testing.expectEqualStrings("personal", parsed.profile.?);
    try std.testing.expectEqual(1, parsed.extra_args.len);
    try std.testing.expectEqualStrings("--resume", parsed.extra_args[0]);
}

test "cli: parse doctor --verbose" {
    const gpa = std.testing.allocator;
    const parsed = try cli.parse(gpa, &.{ "doctor", "--verbose" });
    defer cli.deinit(parsed, gpa);

    try std.testing.expectEqual(cli.Command.doctor, parsed.command);
    try std.testing.expect(parsed.verbose);
}

test "cli: parse ls -vv" {
    const gpa = std.testing.allocator;
    const parsed = try cli.parse(gpa, &.{ "ls", "-vv" });
    defer cli.deinit(parsed, gpa);

    try std.testing.expectEqual(cli.Command.ls, parsed.command);
    try std.testing.expect(parsed.verbose);
}

test "cli: parse new with no profile leaves profile null" {
    const gpa = std.testing.allocator;
    const parsed = try cli.parse(gpa, &.{"new"});
    defer cli.deinit(parsed, gpa);

    try std.testing.expectEqual(cli.Command.new, parsed.command);
    try std.testing.expect(parsed.profile == null);
}

test "cli: parse new --no-share with no profile leaves profile null" {
    const gpa = std.testing.allocator;
    const parsed = try cli.parse(gpa, &.{ "new", "--no-share" });
    defer cli.deinit(parsed, gpa);

    try std.testing.expectEqual(cli.Command.new, parsed.command);
    try std.testing.expect(parsed.profile == null);
    try std.testing.expect(parsed.no_share);
}

test "cli: parse delete with no profile leaves profile null" {
    const gpa = std.testing.allocator;
    const parsed = try cli.parse(gpa, &.{"delete"});
    defer cli.deinit(parsed, gpa);

    try std.testing.expectEqual(cli.Command.delete, parsed.command);
    try std.testing.expect(parsed.profile == null);
}

test "profile: validateName accepts simple names" {
    try std.testing.expect(profile.validateName("personal"));
    try std.testing.expect(profile.validateName("work-2"));
    try std.testing.expect(profile.validateName("my_profile"));
    try std.testing.expect(profile.validateName("default"));
}

test "profile: validateName rejects traversal and unsafe names" {
    try std.testing.expect(!profile.validateName(""));
    try std.testing.expect(!profile.validateName("."));
    try std.testing.expect(!profile.validateName(".."));
    try std.testing.expect(!profile.validateName("../etc"));
    try std.testing.expect(!profile.validateName("a/b"));
    try std.testing.expect(!profile.validateName(".hidden"));
    try std.testing.expect(!profile.validateName("has space"));
    try std.testing.expect(!profile.validateName("a" ** 65));
}