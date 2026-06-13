const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const Log = @import("../shared/log.zig").Log;
const config = @import("../shared/config.zig");
const fsx = @import("../shared/fsx.zig");
const proc = @import("../shared/proc.zig");

const Init = std.process.Init.Minimal;
const Io = std.Io;

const propagateTerm = proc.propagateTerm;

/// URL of the canonical installer, which already handles OS/arch
/// detection, release resolution, checksum verification, and PATH
/// placement. The update command delegates to it via `bash <(curl ...)`;
/// the only thing we add is pinning MCC_VERSION so the installer
/// installs the exact version we just checked.
const install_url = "https://raw.githubusercontent.com/husseinAbdElaziz/multi-claude/main/install.sh";

/// GitHub API endpoint for the latest release. We hit this to learn the
/// current released version (one short GET, no auth, fits in 1 MiB).
const latest_api = "https://api.github.com/repos/husseinAbdElaziz/multi-claude/releases/latest";

/// Detect a Homebrew-managed binary: a path under a Cellar means we
/// shouldn't touch the binary ourselves — `brew upgrade mcc` does it.
/// Same heuristic as `uninstall.zig`.
fn isBrewManaged(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/Cellar/") != null or
        std.mem.indexOf(u8, path, "/.linuxbrew/") != null or
        std.mem.indexOf(u8, path, "/homebrew/Cellar/") != null;
}

/// Extract the value of `"tag_name"` from a GitHub release JSON
/// payload, returning a slice into `body` (e.g. "v0.2.0"). We hand-scan
/// rather than parse the whole response — `tag_name` is always near
/// the top of the response and a full JSON parse would be wasteful for
/// a 1 MiB response we mostly don't care about.
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

/// Compare two dotted version strings (e.g. "0.5.1") numerically,
/// segment by segment. Returns true only when `latest` is strictly
/// greater than `current`, so a stale GitHub "latest" release can never
/// trigger a downgrade prompt. Missing trailing segments are treated as
/// 0 (e.g. "1.2" == "1.2.0").
pub fn isNewer(latest: []const u8, current: []const u8) bool {
    var lit = std.mem.splitScalar(u8, latest, '.');
    var cit = std.mem.splitScalar(u8, current, '.');
    while (true) {
        const ls = lit.next();
        const cs = cit.next();
        if (ls == null and cs == null) return false;
        const lv = std.fmt.parseInt(u32, ls orelse "0", 10) catch 0;
        const cv = std.fmt.parseInt(u32, cs orelse "0", 10) catch 0;
        if (lv != cv) return lv > cv;
    }
}

/// Query GitHub for the latest release version (without a leading
/// "v"). Returns null if it can't be determined (offline,
/// rate-limited, malformed response). Uses whichever of curl or wget
/// is available, with a 3-second timeout so a stalled network can't
/// block the launch path.
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

/// Path of the throttle/cache file at `~/.multi-claude/.update_check`.
/// Contents: `"<epoch_seconds>\n<latest_version>"`. Used to rate-limit
/// GitHub API calls to once per 24h.
fn checkCachePath(allocator: Allocator) ![]u8 {
    const dir = try config.mccDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/.update_check", .{dir});
}

/// Ask "Update mcc v<current> -> v<latest> now? [y/N]" on the terminal.
/// Returns true only on an explicit "y"/"yes"; any read error or
/// empty input is "no". Mirrors `uninstall.confirm` — same buffer
/// size, same line semantics.
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

/// Best-effort, low-friction update check for the launch path
/// (called from `runDefault` and `runProfile`).
///
/// Rules of engagement:
///   - Never errors, never blocks non-interactively. If anything goes
///     wrong (offline, rate-limited, malformed cache, etc.) the
///     function just returns and the launch proceeds normally.
///   - Hits GitHub at most once per 24h, via the
///     `~/.multi-claude/.update_check` cache file.
///   - On a TTY: prompts the user once; saying "yes" runs `mcc update`
///     which replaces the binary in place and exits. The user
///     relaunches into the new version.
///   - On a non-TTY (piped input, CI, scripts): prints a one-line
///     notice and continues. No prompt, no automatic update.
///
/// Updating is NEVER automatic.
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

    // Cache missing or stale: query GitHub (bounded by curl/wget
    // timeouts), then persist the result so we don't re-hit the
    // network for a day.
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
    if (l.len == 0 or !isNewer(l, build_options.version)) return;

    // Only prompt on an interactive terminal; piped/CI launches must
    // not block on stdin. There we just print the notice and carry on.
    const interactive = Io.File.isTty(Io.File.stdin(), io) catch false;
    if (!interactive) {
        logger.warn("update available: v{s} -> v{s}  (run: mcc update)", .{ build_options.version, l });
        return;
    }

    if (promptUpdate(io, build_options.version, l)) {
        // run() resolves the latest, downloads, and replaces this
        // binary, then exits the process. The user relaunches into
        // the new version. If it returns (an error), fall through and
        // launch the current build.
        run(allocator, logger, init, false) catch {};
    } else {
        logger.info("skipping update — run `mcc update` later to upgrade", .{});
    }
}

/// Explicit `mcc update [--force]` entry point. Resolves the latest
/// release, short-circuits when already current (unless `force` is
/// set), and otherwise delegates to the upstream install.sh with
/// `MCC_VERSION` pinned to the version we just checked.
///
/// Homebrew installs are detected and punted to `brew upgrade mcc` —
/// we never overwrite a Cellar binary ourselves.
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
        if (!force and !isNewer(l, build_options.version)) {
            logger.info("mcc is already up to date (v{s})", .{build_options.version});
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
