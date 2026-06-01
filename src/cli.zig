const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Command = enum {
    run_default,
    run_profile,
    new,
    delete,
    ls,
    which,
    doctor,
    help,
    version,
};

pub const ParsedCli = struct {
    command: Command,
    profile: ?[]u8 = null,
    no_share: bool = false,
    verbose: bool = false,
    extra_args: []const []const u8 = &.{},
};

pub fn parse(allocator: Allocator, args: []const []const u8) !ParsedCli {
    if (args.len == 0) {
        return ParsedCli{ .command = .run_default };
    }

    const first = args[0];

    // mcc --help
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        return ParsedCli{ .command = .help };
    }

    // mcc --version
    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-v")) {
        return ParsedCli{ .command = .version };
    }

    // mcc doctor
    if (std.mem.eql(u8, first, "doctor")) {
        var result: ParsedCli = .{ .command = .doctor };
        parseFlags(&result, args[1..]);
        return result;
    }

    // mcc ls
    if (std.mem.eql(u8, first, "ls")) {
        var result: ParsedCli = .{ .command = .ls };
        parseFlags(&result, args[1..]);
        return result;
    }

    // mcc new <profile> [--no-share]
    if (std.mem.eql(u8, first, "new")) {
        return parseProfileCommand(allocator, .new, args);
    }

    // mcc delete <profile>
    if (std.mem.eql(u8, first, "delete")) {
        return parseProfileCommand(allocator, .delete, args);
    }

    // mcc which <profile>
    if (std.mem.eql(u8, first, "which")) {
        return parseProfileCommand(allocator, .which, args);
    }

    // mcc <profile> [-- ...extra_args]
    var result: ParsedCli = .{
        .command = .run_profile,
        .profile = try allocator.dupe(u8, first),
    };

    // Look for -- separator to pass extra args to claude
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            result.extra_args = args[i + 1 ..];
            break;
        }
        if (std.mem.eql(u8, args[i], "--verbose") or std.mem.eql(u8, args[i], "-vv")) {
            result.verbose = true;
        }
    }

    return result;
}

/// Parse a subcommand that takes an optional profile name as its first
/// positional argument (the first non-flag token after the subcommand).
/// Leaves `profile` null when no name is supplied so the caller can report
/// "profile name required" instead of misinterpreting a flag as a name.
fn parseProfileCommand(allocator: Allocator, command: Command, args: []const []const u8) !ParsedCli {
    var result: ParsedCli = .{ .command = command };
    if (args.len >= 2 and !std.mem.startsWith(u8, args[1], "-")) {
        result.profile = try allocator.dupe(u8, args[1]);
        parseFlags(&result, args[2..]);
    } else {
        parseFlags(&result, args[1..]);
    }
    return result;
}

fn parseFlags(result: *ParsedCli, args: []const []const u8) void {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-vv")) {
            result.verbose = true;
        }
        if (std.mem.eql(u8, arg, "--no-share")) {
            result.no_share = true;
        }
    }
}

pub fn deinit(parsed: ParsedCli, allocator: Allocator) void {
    if (parsed.profile) |p| {
        allocator.free(p);
    }
}
