const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const Log = @import("log.zig").Log;
const config = @import("config.zig");
const fsx = @import("fsx.zig");

const Init = std.process.Init.Minimal;
const Io = std.Io;

/// URL of the canonical installer, which already handles OS/arch detection,
/// release resolution, checksum verification, and PATH placement.
const install_url = "https://raw.githubusercontent.com/husseinAbdElaziz/multi-claude/main/install.sh";

/// GitHub API endpoint for the latest release (used for the version check).
const latest_api = "https://api.github.com/repos/husseinAbdElaziz/multi-claude/releases/latest";

/// Same Homebrew heuristic as `uninstall`: a managed binary resolves under a
/// Cellar path, and should be upgraded with `brew upgrade` instead.
fn isBrewManaged(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/Cellar/") != null or
        std.mem.indexOf(u8, path, "/.linuxbrew/") != null or
        std.mem.indexOf(u8, path, "/homebrew/Cellar/") != null;
}

/// Extract the value of `"tag_name"` from a GitHub release JSON payload,
/// returning a slice into `body` (e.g. "v0.2.0"). Avoids a full JSON parse.
pub fn extractTag(body: []const u8) ?[]const u8 {
    const key = "\"tag_name\"";
    const idx = std.mem.indexOf(u8, body, key) orelse return null;
    var i = idx + key.len;
    while (i < body.len and (body[i] == ' ' or body[i] == ':')) : (i += 1) {}
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < body.len and body[i] != '"') : (i += 1) {}
    if (i >= body.len) return null;
    return body[start..i];
}

/// Query GitHub for the latest release version (without a leading "v").
/// Returns null if it can't be determined (offline, rate-limited, etc.).
fn fetchLatestVersion(allocator: Allocator, io: Io, env_map: *const std.process.Environ.Map) ?[]u8 {
    const cmd = "{ curl -fsSL --max-time 3 -A mcc-update " ++ latest_api ++ " || wget -qO- --timeout=3 --tries=1 " ++ latest_api ++ " ; } 2>/dev/null";
    const res = std.process.run(allocator, io, .{
        .argv = &.{ "bash", "-c", cmd },
        .environ_map = env_map,
        .stdout_limit = .limited(1 << 20),
    }) catch return null;
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    const tag = extractTag(res.stdout) orelse return null;
    const normalized = std.mem.trimStart(u8, tag, "v");
    if (normalized.len == 0) return null;
    return allocator.dupe(u8, normalized) catch null;
}

/// Path of the throttle/cache file: "<epoch_seconds>\n<latest_version>".
fn checkCachePath(allocator: Allocator) ![]u8 {
    const dir = try config.mccDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/.update_check", .{dir});
}

/// Ask "Update now? [y/N]" on the terminal. Returns true only on explicit
/// "y"/"yes"; any read error or empty input is "no". Mirrors uninstall.confirm.
fn promptUpdate(io: Io, current: []const u8, latest: []const u8) bool {
    const out = Io.File.stdout();
    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Update mcc v{s} -> v{s} now? [y/N] ", .{ current, latest }) catch "Update mcc now? [y/N] ";
    Io.File.writeStreamingAll(out, io, msg) catch {};

    var buf: [16]u8 = undefined;
    const in = Io.File.stdin();
    const n = Io.File.readStreaming(in, io, &.{buf[0..]}) catch return false;
    if (n == 0) return false;
    const line = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return line.len > 0 and (line[0] == 'y' or line[0] == 'Y');
}

/// Best-effort update check for launch paths. Never errors and never blocks
/// non-interactively: hits GitHub at most once per 24h (cached in
/// ~/.multi-claude), otherwise reads the cached result. When a newer release
/// exists it asks the user — on a TTY — whether to update now (runs `mcc
/// update` and exits, which the user then relaunches). On any other shell it
/// just prints a one-line notice and continues. Updating is never automatic.
pub fn notifyIfOutdated(allocator: Allocator, logger: Log, init: Init) void {
    const path = checkCachePath(allocator) catch return;
    defer allocator.free(path);

    var threaded = Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();

    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const now: i64 = @intCast(ts.sec);
    const day = 24 * 60 * 60;

    // Try the cache first; reuse it when younger than a day.
    var latest: ?[]u8 = null;
    defer if (latest) |l| allocator.free(l);

    if (fsx.readFile(allocator, path)) |raw| {
        defer allocator.free(raw);
        if (std.mem.indexOfScalar(u8, raw, '\n')) |nl| {
            const epoch = std.fmt.parseInt(i64, std.mem.trim(u8, raw[0..nl], " \r\n"), 10) catch -day - 1;
            const ver = std.mem.trim(u8, raw[nl + 1 ..], " \r\n");
            if (now - epoch < day and ver.len > 0) {
                latest = allocator.dupe(u8, ver) catch null;
            }
        }
    } else |_| {}

    // Cache missing or stale: query GitHub (bounded by curl/wget timeouts),
    // then persist the result so we don't re-hit the network for a day.
    if (latest == null) {
        var env_map = std.process.Environ.createMap(init.environ, allocator) catch return;
        defer env_map.deinit();

        const fetched = fetchLatestVersion(allocator, io, &env_map);
        // On failure, cache the current version so no notice shows and we still
        // back off for a day.
        const to_cache = fetched orelse (allocator.dupe(u8, build_options.version) catch return);
        latest = to_cache;

        const contents = std.fmt.allocPrint(allocator, "{d}\n{s}", .{ now, to_cache }) catch return;
        defer allocator.free(contents);
        fsx.atomicWrite(allocator, path, contents) catch {};
    }

    const l = latest orelse return;
    if (l.len == 0 or std.mem.eql(u8, l, build_options.version)) return;

    // Only prompt on an interactive terminal; piped/CI launches must not block
    // on stdin. There we just print the notice and carry on.
    const interactive = Io.File.isTty(Io.File.stdin(), io) catch false;
    if (!interactive) {
        logger.warn("update available: v{s} -> v{s}  (run: mcc update)", .{ build_options.version, l });
        return;
    }

    if (promptUpdate(io, build_options.version, l)) {
        // run() resolves the latest, downloads, and replaces this binary, then
        // exits the process. The user relaunches into the new version. If it
        // returns (an error), fall through and launch the current build.
        run(allocator, logger, init, false) catch {};
    } else {
        logger.info("skipping update — run `mcc update` later to upgrade", .{});
    }
}

fn propagateTerm(term: std.process.Child.Term) noreturn {
    switch (term) {
        .exited => |code| std.process.exit(code),
        .signal => |sig| std.process.exit(@as(u8, @intCast(128 + @intFromEnum(sig)))),
        .stopped => |sig| std.process.exit(@as(u8, @intCast(128 + @intFromEnum(sig)))),
        .unknown => |code| std.process.exit(@as(u8, @intCast(code))),
    }
}

/// Update mcc to the latest release in place. Skips the download when already
/// on the latest version (unless `force`). Homebrew installs defer to brew.
pub fn run(allocator: Allocator, logger: Log, init: Init, force: bool) !void {
    var threaded = Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const exe_path: ?[]u8 = std.process.executablePathAlloc(io, allocator) catch null;
    defer if (exe_path) |p| allocator.free(p);

    if (exe_path) |p| {
        if (isBrewManaged(p)) {
            logger.info("mcc is managed by Homebrew. Update with:", .{});
            logger.info("  brew update && brew upgrade mcc", .{});
            return;
        }
    }

    var env_map = try std.process.Environ.createMap(init.environ, allocator);
    defer env_map.deinit();

    // Resolve the latest release and short-circuit when already current.
    const latest: ?[]u8 = fetchLatestVersion(allocator, io, &env_map);
    defer if (latest) |l| allocator.free(l);

    if (latest) |l| {
        if (!force and std.mem.eql(u8, l, build_options.version)) {
            logger.info("mcc is already up to date (v{s})", .{l});
            return;
        }
        logger.info("Updating mcc v{s} -> v{s}...", .{ build_options.version, l });
        // Pin the installer to exactly the version we checked.
        try env_map.put("MCC_VERSION", l);
    } else {
        logger.warn("could not determine the latest version; installing latest release", .{});
        logger.info("Updating mcc (current: v{s})...", .{build_options.version});
    }

    // Install over the currently-running binary's location so the update
    // replaces the right copy regardless of where it lives on PATH.
    if (exe_path) |p| {
        if (std.fs.path.dirname(p)) |dir| {
            try env_map.put("MCC_INSTALL_DIR", dir);
        }
    }

    // Prefer curl, fall back to wget; pipe the installer into bash. The braces
    // group the download so the `| bash` applies to whichever succeeds.
    const cmd = "{ curl -fsSL " ++ install_url ++ " || wget -qO- " ++ install_url ++ " ; } | bash";

    var child = try std.process.spawn(io, .{
        .argv = &.{ "bash", "-c", cmd },
        .environ_map = &env_map,
    });
    propagateTerm(child.wait(io) catch |err| {
        logger.err("update failed: {}", .{err});
        std.process.exit(1);
    });
}
