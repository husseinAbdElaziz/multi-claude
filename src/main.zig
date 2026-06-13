const std = @import("std");
const build_options = @import("build_options");
pub const cli = @import("cli/cli.zig");
pub const config = @import("shared/config.zig");
pub const profile = @import("profile/profile.zig");
pub const manifest = @import("profile/manifest.zig");
pub const resources = @import("profile/resources.zig");
pub const composer = @import("profile/composer.zig");
pub const launcher = @import("launcher/launcher.zig");
pub const lock = @import("profile/lock.zig");
pub const fsx = @import("shared/fsx.zig");
pub const log = @import("shared/log.zig");
pub const doctor = @import("commands/doctor.zig");
pub const update = @import("commands/update.zig");
pub const uninstall = @import("commands/uninstall.zig");
pub const web = @import("web/web.zig");
pub const proxy = @import("proxy/proxy.zig");
pub const provider = @import("provider/provider.zig");
pub const providers = @import("provider/providers.zig");
pub const translator = @import("proxy/translator.zig");
pub const httpx = @import("shared/httpx.zig");
pub const jsonw = @import("shared/jsonw.zig");
pub const cfgstore = @import("shared/cfgstore.zig");
pub const proc = @import("shared/proc.zig");

/// Edit distance (Levenshtein) between two short strings, used to suggest
/// a near-match when the user types a profile name that doesn't exist
/// (e.g. "peronal" → "personal"). Returns 0 if either string is too long
/// for the fixed-size scratch buffers (>63 chars).
pub fn levenshtein(a: []const u8, b: []const u8) usize {
    const m = a.len;
    const n = b.len;

    var row_a: [64]usize = undefined;
    var row_b: [64]usize = undefined;

    if (m >= 64 or n >= 64) return 0;

    for (0..n + 1) |i| row_a[i] = i;

    var i: usize = 1;
    while (i <= m) : (i += 1) {
        row_b[0] = i;
        var j: usize = 1;
        while (j <= n) : (j += 1) {
            const cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;
            row_b[j] = @min(
                row_a[j] + 1,
                @min(
                    row_b[j - 1] + 1,
                    row_a[j - 1] + cost,
                ),
            );
        }
        for (0 ..n + 1) |k| row_a[k] = row_b[k];
    }

    return row_a[n];
}

/// When the user references a profile that doesn't exist, scan the
/// profiles dir and print "did you mean '<name>'?" if one is within edit
/// distance 3. Best-effort: any error reading the dir or scoring is
/// silently ignored — the suggestion is a courtesy, not a requirement.
fn suggestProfiles(allocator: std.mem.Allocator, logger: log.Log, target: []const u8) !void {
    const mcc_dir = config.mccDir(allocator) catch return;
    defer allocator.free(mcc_dir);

    const profiles_dir = std.fmt.allocPrint(allocator, "{s}/profiles", .{mcc_dir}) catch return;
    defer allocator.free(profiles_dir);

    if (!fsx.exists(profiles_dir)) return;

    const names = fsx.listSubdirs(allocator, profiles_dir) catch return;
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    var best_distance: usize = 3;
    var best_name: []const u8 = "";

    for (names) |name| {
        const dist = levenshtein(target, name);
        if (dist < best_distance and dist > 0) {
            best_distance = dist;
            best_name = name;
        }
    }

    if (best_name.len > 0) {
        logger.err("did you mean '{s}'?", .{best_name});
    }
}

/// Entry point. The runtime hands us a `process.Init.Minimal` which
/// provides the process arguments and environment in the new zig 0.16 Io
/// world; the rest of the program works against the global page allocator.
///
/// Flow:
///   1. Materialize args into a slice the parser can index.
///   2. Parse into a `ParsedCli`.
///   3. Dispatch on the command, exiting with non-zero status on errors
///      (using `std.process.exit` so deferred frees don't run — the OS
///      reclaims everything anyway).
pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;

    // Collect command-line args (skip the program name)
    var args_it = std.process.Args.Iterator.init(init.args);
    _ = args_it.next(); // skip program name (argv[0])

    var args_list = std.ArrayList([]const u8).initCapacity(gpa, 0) catch unreachable;
    defer args_list.deinit(gpa);

    while (args_it.next()) |arg| {
        try args_list.append(gpa, arg);
    }
    const args_slice = args_list.items;

    // Parse CLI
    const parsed = try cli.parse(gpa, args_slice);
    defer cli.deinit(parsed, gpa);

    const logger: log.Log = log.Log.init(parsed.verbose);

    // Dispatch on the selected command. The `process.exit(1)` calls are
    // deliberate — `defer`s won't run on a hard exit, but the OS reclaims
    // all of the gpa-allocated memory when the process dies.
    switch (parsed.command) {
        // `mcc` with no args → run claude with the default profile. This is
        // the "drop-in replacement for `claude`" path.
        .run_default => {
            try launcher.runDefault(gpa, logger, init);
        },
        // `mcc <name>` → run claude with the named profile. We validate the
        // name (no path traversal) and the directory's existence up front so
        // the user gets a friendly error before any claude-spawning setup
        // happens. On a missing profile we offer a "did you mean?" hint.
        .run_profile => {
            const pname = parsed.profile orelse {
                logger.err("profile name required", .{});
                std.process.exit(1);
            };
            if (!profile.validateName(pname)) {
                logger.err("invalid profile name '{s}': use letters, digits, '-' or '_' (max 64)", .{pname});
                std.process.exit(1);
            }
            const profile_dir = config.profileDir(gpa, pname) catch {
                logger.err("profile '{s}' does not exist", .{pname});
                suggestProfiles(gpa, logger, pname) catch {};
                std.process.exit(1);
            };
            defer gpa.free(profile_dir);

            if (!fsx.exists(profile_dir)) {
                logger.err("profile '{s}' does not exist", .{pname});
                suggestProfiles(gpa, logger, pname) catch {};
                std.process.exit(1);
            }

            try launcher.runProfile(gpa, logger, pname, parsed.extra_args, init);
        },
        // `mcc new <name>` → create a new profile. `--no-share` is parsed
        // earlier and read from `parsed.no_share`.
        .new => {
            const pname = parsed.profile orelse {
                logger.err("profile name required", .{});
                std.process.exit(1);
            };
            try profile.create(gpa, logger, pname, parsed.no_share);
        },
        // `mcc delete <name>` → remove a profile's directory.
        .delete => {
            const pname = parsed.profile orelse {
                logger.err("profile name required", .{});
                std.process.exit(1);
            };
            try profile.delete(gpa, logger, pname);
        },
        // `mcc ls` → list profile names + their shared/isolated mode.
        .ls => {
            try profile.list(gpa, logger);
        },
        // `mcc which <name>` → print the CLAUDE_CONFIG_DIR mcc would set
        // for the named profile (the value of the env var it injects).
        .which => {
            const pname = parsed.profile orelse {
                logger.err("profile name required", .{});
                std.process.exit(1);
            };
            try profile.which(gpa, logger, pname);
        },
        // `mcc doctor` → run environment + profile health checks.
        .doctor => {
            try doctor.check(gpa, logger);
        },
        // `mcc update [--force]` → check GitHub for a newer release and
        // self-install over the running binary.
        .update => {
            try update.run(gpa, logger, init, parsed.yes);
        },
        // `mcc uninstall [--yes]` → remove mcc's data dir and binary.
        .uninstall => {
            try uninstall.run(gpa, logger, parsed.yes);
        },
        // `mcc ui [--port N]` → serve the provider config web UI on
        // localhost. Defaults to port 8989.
        .ui => {
            try web.serve(gpa, logger, init, parsed.port);
        },
        // `mcc __proxy__ <profile> <port>` → INTERNAL. The launcher spawns
        // this subcommand to host the local routing proxy. We carry the
        // real ANTHROPIC_API_KEY through env so the proxy can swap it onto
        // upstream requests, and the per-run secret that the launcher
        // injects via ANTHROPIC_CUSTOM_HEADERS.
        .proxy => {
            const pname = parsed.profile orelse {
                logger.err("proxy: profile required", .{});
                std.process.exit(1);
            };
            const port = parsed.port;
            if (port == 0) {
                logger.err("proxy: invalid port", .{});
                std.process.exit(1);
            }
            const api_key = config.getEnvVar(gpa, "ANTHROPIC_API_KEY") catch null orelse try gpa.dupe(u8, "");
            defer gpa.free(api_key);
            const proxy_secret = config.getEnvVar(gpa, "MCC_PROXY_SECRET") catch null orelse try gpa.dupe(u8, "");
            defer gpa.free(proxy_secret);

            var threaded = std.Io.Threaded.init(gpa, .{ .environ = init.environ });
            defer threaded.deinit();
            try proxy.run(gpa, logger, threaded.io(), pname, port, api_key, proxy_secret);
        },
        .help => {
            printUsage();
        },
        .version => {
            printVersion();
        },
    }
}

/// Print the user-facing help text. Uses the single-threaded Io because we
/// don't have one yet at the help/version path and the output is small
/// enough that we don't need thread-pool overhead.
fn printUsage() void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const out = std.Io.File.stdout();
    const msg =
        \\Usage: mcc [command] [profile] [options]
        \\
        \\Commands:
        \\  <profile>              Run claude with the specified profile
        \\  <profile> -- <args>    Pass extra args through to claude
        \\  new <profile>          Create a new profile (shared by default)
        \\  new <profile> --no-share  Create an isolated profile
        \\  delete <profile>       Delete a profile
        \\  ls                     List all profiles
        \\  which <profile>        Show config directory for a profile
        \\  doctor                 Check environment configuration
        \\  ui [--port <n>]        Open provider config UI (default port 8989)
        \\  update [--force]       Update mcc to the latest release
        \\  uninstall [--yes|-y]   Remove mcc data (~/.multi-claude) and the binary
        \\
        \\Options:
        \\  --help, -h             Show this help message
        \\  --version, -v          Show version
        \\  --verbose, -vv         Enable debug logging
        \\
        \\Running with no arguments runs claude with the default profile.
        \\
    ;
    _ = std.Io.File.writeStreamingAll(out, io, msg) catch {};
}

/// Print the version compiled into the binary (see build.zig's
/// `-Dversion` option — the CI release build passes the release tag here).
fn printVersion() void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const out = std.Io.File.stdout();
    _ = std.Io.File.writeStreamingAll(out, io, "mcc " ++ build_options.version ++ "\n") catch {};
}
