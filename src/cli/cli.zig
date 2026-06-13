/// Command-line argument parser for `mcc`.
///
/// The parser is hand-written (no library) because the surface is small and
/// the routing is best expressed as a chain of `if std.mem.eql(...)` checks
/// against the first positional arg. Anything that needs flags gets
/// dispatched to `parseFlags` or `parseProfileCommand`.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The set of high-level commands the CLI knows about. One is selected by
/// `parse()` and the rest of the args are interpreted accordingly.
pub const Command = enum {
    run_default, // `mcc` with no args → run claude with the default profile
    run_profile, // `mcc <name>`        → run claude with the named profile
    new, // `mcc new <name>`    → create a profile
    delete, // `mcc delete <name>` → delete a profile
    ls, // `mcc ls`            → list profiles
    which, // `mcc which <name>`  → print the profile's config dir
    doctor, // `mcc doctor`        → check environment
    update, // `mcc update`        → self-update
    uninstall, // `mcc uninstall`     → remove mcc
    ui, // `mcc ui`            → serve the provider config web UI
    proxy, // `mcc __proxy__ ...` → INTERNAL: spawned by the launcher
    help, // `mcc --help`        → show usage
    version, // `mcc --version`     → show version
};

/// Result of parsing the command line. The `profile` string, if any, is
/// owned by the allocator passed to `parse` — `deinit` frees it. All other
/// fields are value types or borrowed slices.
pub const ParsedCli = struct {
    command: Command,

    /// Profile name (for `run_profile`, `new`, `delete`, `which`, `proxy`).
    /// Null when no name was supplied and the caller should error out.
    profile: ?[]u8 = null,

    /// `mcc new <name> --no-share` — make the profile fully isolated (no
    /// symlinks to ~/.claude). Only meaningful for the `new` command.
    no_share: bool = false,

    /// `--verbose` / `-vv` — enable debug logging.
    verbose: bool = false,

    /// `--yes` / `-y` / `--force` / `-f` — skip "are you sure?" prompts
    /// (used by `update`, `uninstall`).
    yes: bool = false,

    /// `--port <n>` for `ui` (default 8989), or the proxy port for `proxy`.
    port: u16 = 8989,

    /// Args after `--` to be passed through to claude. Borrowed from the
    /// original `args` slice, so the caller doesn't need to free them.
    extra_args: []const []const u8 = &.{},
};

/// Parse `args` (already with the program name stripped) into a `ParsedCli`.
///
/// The dispatch is on `args[0]`:
///   - `--help` / `-h`             → help
///   - `--version` / `-v`          → version
///   - `doctor` / `ls` / `update`  → command with optional flags
///   - `uninstall`                 → command with `--yes`
///   - `__proxy__`                 → INTERNAL launcher-spawned proxy
///   - `ui`                        → web UI, with optional `--port <n>`
///   - `new` / `delete` / `which`  → command taking a profile name
///   - anything else               → run_profile, with `args[0]` as the name
///
/// `args[0]` is treated as the profile name on the `run_profile` path even
/// when it looks like a flag; this matches the user's mental model that
/// `mcc personal` runs the "personal" profile.
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

    // mcc update
    if (std.mem.eql(u8, first, "update")) {
        var result: ParsedCli = .{ .command = .update };
        parseFlags(&result, args[1..]);
        return result;
    }

    // mcc uninstall [--yes]
    if (std.mem.eql(u8, first, "uninstall")) {
        var result: ParsedCli = .{ .command = .uninstall };
        parseFlags(&result, args[1..]);
        return result;
    }

    // mcc __proxy__ <profile> <port>  (internal — spawned by launcher)
    if (std.mem.eql(u8, first, "__proxy__")) {
        var result: ParsedCli = .{ .command = .proxy };
        if (args.len >= 2) result.profile = try allocator.dupe(u8, args[1]);
        if (args.len >= 3) result.port = std.fmt.parseInt(u16, args[2], 10) catch 0;
        return result;
    }

    // mcc ui [--port <n>]
    if (std.mem.eql(u8, first, "ui")) {
        var result: ParsedCli = .{ .command = .ui };
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
                result.port = std.fmt.parseInt(u16, args[i + 1], 10) catch 8989;
                i += 1;
            } else if (std.mem.startsWith(u8, args[i], "--port=")) {
                result.port = std.fmt.parseInt(u16, args[i][7..], 10) catch 8989;
            }
        }
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
    //
    // Anything that didn't match a known subcommand is treated as a profile
    // name. The first positional arg becomes the profile; everything after a
    // `--` separator is passed through to claude; `--verbose` is the only
    // flag recognized here.
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

/// Apply the flags we recognize anywhere in `args` to `result`. Unknown
/// flags are silently ignored — the user will get an error later from
/// whatever subcommand they actually invoked.
fn parseFlags(result: *ParsedCli, args: []const []const u8) void {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-vv")) {
            result.verbose = true;
        }
        if (std.mem.eql(u8, arg, "--no-share")) {
            result.no_share = true;
        }
        if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y") or
            std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f"))
        {
            result.yes = true;
        }
    }
}

/// Free everything `parse` allocated. Currently just the `profile` string
/// (the only owned slice in `ParsedCli`).
pub fn deinit(parsed: ParsedCli, allocator: Allocator) void {
    if (parsed.profile) |p| {
        allocator.free(p);
    }
}
