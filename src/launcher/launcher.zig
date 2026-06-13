const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("../shared/config.zig");
const composer = @import("../profile/composer.zig");
const manifest = @import("../profile/manifest.zig");
const lock = @import("../profile/lock.zig");
const provider_mod = @import("../provider/provider.zig");
const providers_mod = @import("../provider/providers.zig");
const proxy_mod = @import("../proxy/proxy.zig");
const update = @import("../commands/update.zig");
const fsx = @import("../shared/fsx.zig");
const proc = @import("../shared/proc.zig");
const Log = @import("../shared/log.zig").Log;

const propagateTerm = proc.propagateTerm;

const Init = std.process.Init.Minimal;
const Io = std.Io;

/// Build a properly-initialized threaded Io for spawning child processes.
///
/// The global `Io.Threaded.global_single_threaded` instance uses a
/// *failing* allocator, so any `std.process.spawn` through it returns
/// `OutOfMemory`. Spawning needs a real allocator, and the parent
/// `environ` is required so `argv[0]` (e.g. "claude") can be resolved
/// against `PATH`.
fn spawnIo(allocator: Allocator, init: Init) Io.Threaded {
    return Io.Threaded.init(allocator, .{ .environ = init.environ });
}

/// Resolve the provider config for `profile_name` (null = global default)
/// and, when a provider is configured, materialize a `providers.json` so
/// the proxy has something to route against. Also surfaces the configured
/// model id via `model_arg` (transferred ownership — the caller frees it).
///
/// Three outcomes:
///   - No provider configured: clean up any stale synthesized
///     providers.json (a previous openai_compat run may have left one
///     that would now point the launcher at a phantom proxy), set
///     `model_arg` to null, return.
///   - Provider configured without an api_url: record the model id in
///     `model_arg` (for --model) but don't synthesize providers.json
///     (no proxy is needed when there's no URL to route through).
///   - Provider configured with an api_url: synthesize providers.json so
///     the launcher can spawn the proxy, set `model_arg` to the model
///     (or "*" when none, so the proxy can match any non-claude model
///     that Claude Code sends).
fn applyProvider(
    allocator: Allocator,
    logger: Log,
    profile_name: ?[]const u8,
    model_arg: *?[]u8,
) !void {
    const maybe_prov = provider_mod.load(allocator, profile_name) catch null;
    if (maybe_prov) |p| {
        var pp = p;
        defer pp.deinit(allocator);

        // Disown model so deinit doesn't free it; we track lifetime via model_arg.
        if (pp.model) |m| {
            pp.model = null;
            model_arg.* = m;
        }

        if (pp.api_url) |url| {
            // Route through proxy for both compat types. This keeps ANTHROPIC_API_KEY
            // out of Claude's env (avoids "Detected a custom API key" prompt) and
            // handles Anthropic→OpenAI translation for openai_compat endpoints.
            // Always re-synthesize providers.json so URL/model/key changes take effect immediately.
            const ptype: providers_mod.ProviderType = if (pp.openai_compat) .openai_compat else .anthropic_compat;
            // Dupe model string into cfg so cfg.deinit owns it independently of model_arg.
            // Wildcard "*" when no model set so proxy can match any non-claude model sent by Claude Code.
            const model_str = if (model_arg.*) |m| try allocator.dupe(u8, m) else try allocator.dupe(u8, "*");
            var models_buf = [1][]u8{model_str};
            const owned_models = try allocator.dupe([]u8, &models_buf);
            const entry = providers_mod.ProviderEntry{
                .name = try allocator.dupe(u8, "provider"),
                .provider_type = ptype,
                .api_url = try allocator.dupe(u8, url),
                .api_key = if (pp.api_key) |k| try allocator.dupe(u8, k) else null,
                .models = owned_models,
            };
            const entries = try allocator.alloc(providers_mod.ProviderEntry, 1);
            entries[0] = entry;
            var cfg = providers_mod.Config{ .entries = entries };
            try providers_mod.save(allocator, profile_name, cfg);
            cfg.deinit(allocator);
            logger.info("configured {s} provider proxy", .{@tagName(ptype)});
        }
    } else {
        // No provider configured for this profile (or globally). A previous
        // openai_compat run may have left a synthesized providers.json behind
        // that would now point the launcher at a phantom proxy. Clean it up
        // so the next launch is a true passthrough.
        providers_mod.deleteConfig(allocator, profile_name) catch {};
    }
}

/// Run claude with the DEFAULT profile (i.e. `mcc` with no args).
///
/// Conceptually this is the "drop-in replacement for `claude`" path:
/// there's no CLAUDE_CONFIG_DIR override, no profile dir, no symlinks —
/// claude runs against the user's real ~/.claude. The only thing mcc
/// adds here is provider routing: if a global provider.json is
/// configured, we start the local proxy and point claude at it via
/// ANTHROPIC_BASE_URL + ANTHROPIC_CUSTOM_HEADERS, exactly as for a named
/// profile. With no provider configured this is effectively equivalent
/// to running `claude` directly.
pub fn runDefault(allocator: Allocator, logger: Log, init: Init) !void {
    update.notifyIfOutdated(allocator, logger, init);

    var threaded = spawnIo(allocator, init);
    defer threaded.deinit();
    const io = threaded.io();

    // Build env map with parent environment
    var env_map = try std.process.Environ.createMap(init.environ, allocator);
    defer env_map.deinit();

    // model_arg is owned here and outlives spawn (argv holds a reference into it).
    var model_arg: ?[]u8 = null;
    defer if (model_arg) |m| allocator.free(m);

    applyProvider(allocator, logger, null, &model_arg) catch |err| {
        logger.warn("provider setup failed: {} — launching vanilla", .{err});
    };

    var proxy_child: ?std.process.Child = null;
    _ = startProxyIfNeeded(allocator, logger, io, init.environ, null, &env_map, &proxy_child) catch |err| blk: {
        logger.warn("proxy start failed: {} — launching without proxy", .{err});
        break :blk @as(u16, 0);
    };

    var argv_list = std.ArrayList([]const u8).empty;
    defer argv_list.deinit(allocator);
    try argv_list.append(allocator, "claude");
    if (model_arg) |m| try argv_list.appendSlice(allocator, &.{ "--model", m });
    const argv = try argv_list.toOwnedSlice(allocator);
    defer allocator.free(argv);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &env_map,
    });

    const term = child.wait(io) catch {
        if (proxy_child) |*pc| pc.kill(io);
        return;
    };
    if (proxy_child) |*pc| pc.kill(io);
    propagateTerm(term);
}

/// Run claude with a NAMED profile (`mcc <name>`).
///
/// The flow:
///   1. Check for updates (cached, non-blocking on the hot path).
///   2. Make sure the profile's CLAUDE_CONFIG_DIR is composed (idempotent).
///   3. Acquire an advisory lock on `<profile-dir>/run.lock` so two
///      instances of the same profile can't fight over the same
///      sessions / history files.
///   4. Build a clean env: parent env + CLAUDE_CONFIG_DIR pointing at
///      the profile's composed dir + provider routing (proxy env vars).
///   5. Spawn the proxy if the profile has providers.json (or one was
///      just synthesized from a single provider.json).
///   6. Spawn claude as a child with that env.
///   7. Wait for it, propagate the exit code, then kill the proxy (if
///      any). The lock is intentionally NOT released here — see the
///      comment in the body about why.
pub fn runProfile(allocator: Allocator, logger: Log, profile_name: []const u8, extra_args: []const []const u8, init: Init) !void {
    update.notifyIfOutdated(allocator, logger, init);

    var threaded = spawnIo(allocator, init);
    defer threaded.deinit();
    const io = threaded.io();

    const profile_config = try config.profileConfigDir(allocator, profile_name);
    defer allocator.free(profile_config);

    // Compose the config directory (idempotent), honoring the profile's
    // sharing policy from its manifest. Fall back to shared if the manifest
    // is missing — this handles profiles created by older mcc versions that
    // didn't always write a manifest.
    const shared = blk: {
        const m = manifest.Manifest.load(allocator, profile_name) catch break :blk true;
        defer allocator.free(m.name);
        break :blk m.shared;
    };
    try composer.compose(allocator, logger, profile_name, shared);

    // Acquire an advisory lock for the profile and hold it for the entire
    // lifetime of the child `claude`. We deliberately do NOT release it
    // in this function: the lock must stay held until `claude` exits,
    // and `propagateTerm` ends this process via `std.process.exit` (which
    // skips `defer`s). The kernel releases the flock when our fd is
    // closed on exit, so there's no leak.
    const lock_path = try config.profileLockPath(allocator, profile_name);
    defer allocator.free(lock_path);

    const lock_file = lock.tryAcquire(lock_path) catch |err| {
        logger.err("could not lock profile '{s}': {} — refusing to launch", .{ profile_name, err });
        std.process.exit(1);
    };
    if (lock_file == null) {
        logger.err("profile '{s}' is already running — refusing to launch a second instance", .{profile_name});
        std.process.exit(1);
    }

    // Build the child's environment: clone the parent's env and add the
    // variables mcc is responsible for setting:
    //   CLAUDE_CONFIG_DIR       — points claude at the composed profile dir
    //   ANTHROPIC_BASE_URL      — set by startProxyIfNeeded if a proxy runs
    //   ANTHROPIC_API_KEY       — stripped by startProxyIfNeeded (so claude
    //                             uses its own login, not the user's real key)
    //   ANTHROPIC_CUSTOM_HEADERS — set by startProxyIfNeeded (carries the
    //                              per-run gate secret for the proxy)
    var env_map = try std.process.Environ.createMap(init.environ, allocator);
    defer env_map.deinit();
    try env_map.put("CLAUDE_CONFIG_DIR", profile_config);

    // Load provider config (provider.json) and synthesize a providers.json
    // when a URL is configured (so the proxy can route). `model_arg` is
    // owned here and outlives the spawn call — argv holds a reference
    // into it, and we free it after `wait` returns.
    var model_arg: ?[]u8 = null;
    defer if (model_arg) |m| allocator.free(m);

    try applyProvider(allocator, logger, profile_name, &model_arg);

    // Start the local proxy if a providers.json is in effect (including
    // one we just synthesized from a single-provider config). The proxy
    // gets the real ANTHROPIC_API_KEY from the original env so it can
    // forward to api.anthropic.com when needed.
    var proxy_child: ?std.process.Child = null;
    const proxy_port = startProxyIfNeeded(allocator, logger, io, init.environ, profile_name, &env_map, &proxy_child) catch |err| blk: {
        logger.warn("proxy start failed: {} — launching without proxy", .{err});
        break :blk 0;
    };
    _ = proxy_port;

    var argv_list = std.ArrayList([]const u8).empty;
    defer argv_list.deinit(allocator);
    try argv_list.append(allocator, "claude");
    if (model_arg) |m| try argv_list.appendSlice(allocator, &.{ "--model", m });
    for (extra_args) |arg| try argv_list.append(allocator, arg);
    const argv = try argv_list.toOwnedSlice(allocator);
    defer allocator.free(argv);

    var claude_child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &env_map,
    });

    const term = claude_child.wait(io) catch {
        if (proxy_child) |*pc| { pc.kill(io); }
        return;
    };
    if (proxy_child) |*pc| { pc.kill(io); }
    propagateTerm(term);
}

/// Spawn the local proxy subprocess for `profile_name` if a
/// `providers.json` is in effect, and inject the env vars claude needs
/// to talk to it (ANTHROPIC_BASE_URL, ANTHROPIC_CUSTOM_HEADERS).
///
/// Returns the port the proxy is listening on (0 if no proxy was
/// started). On success, `child_out` is set to the spawned child — the
/// caller MUST `kill` it before exiting, otherwise the proxy outlives
/// claude and binds the port forever.
fn startProxyIfNeeded(
    allocator: Allocator,
    logger: Log,
    io: Io,
    environ: std.process.Environ,
    profile_name: ?[]const u8,
    env_map: *std.process.Environ.Map,
    child_out: *?std.process.Child,
) !u16 {
    var pcfg = providers_mod.load(allocator, profile_name) catch return 0;
    if (pcfg == null) return 0;
    const entry_count = pcfg.?.entries.len;
    pcfg.?.deinit(allocator);
    if (entry_count == 0) return 0;

    // Reuse the caller's `io` for findFreePort + executablePathAlloc. The
    // earlier code spun up two extra `Io.Threaded` instances (each
    // spawning worker threads) on the hot path of every provider-backed
    // launch.
    const port = proxy_mod.findFreePort(io) catch return 0;
    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_str);

    logger.info("starting provider proxy on port {d}", .{port});

    // Random per-run secret: injected as Claude Code's
    // ANTHROPIC_API_KEY and required by the proxy on every request, so
    // no other local process or browser page can drive the proxy with
    // the user's real key.
    const secret = try proxy_mod.generateSecret(allocator, io);
    defer allocator.free(secret);

    // Proxy inherits original environ so it has the real ANTHROPIC_API_KEY.
    var proxy_env = try std.process.Environ.createMap(environ, allocator);
    defer proxy_env.deinit();
    try proxy_env.put("MCC_PROXY_SECRET", secret);

    const self_exe = std.process.executablePathAlloc(io, allocator) catch null;
    defer if (self_exe) |p| allocator.free(p);

    // Use the caller's io so kill/wait on the child work with the same io.
    const child = try std.process.spawn(io, .{
        // Empty profile name → proxy's providers_mod.load falls back to the
        // global ~/.multi-claude/providers.json (synthesized for the default run).
        .argv = &.{ self_exe orelse return error.SelfExeNotFound, "__proxy__", profile_name orelse "", port_str },
        .environ_map = &proxy_env,
    });
    child_out.* = child;

    // Give proxy time to bind the port before Claude Code starts.
    const ts = std.c.timespec{ .sec = 0, .nsec = 200_000_000 };
    _ = std.c.nanosleep(&ts, null);

    const proxy_url = try std.fmt.allocPrint(allocator, "http://localhost:{d}", .{port});
    defer allocator.free(proxy_url);

    try env_map.put("ANTHROPIC_BASE_URL", proxy_url);

    // Gate the proxy with a secret in a CUSTOM header, not the auth
    // header, so Claude Code's own Anthropic credential (OAuth token or
    // API key) still flows through untouched — needed to pass claude-*
    // requests upstream. Dropping any inherited ANTHROPIC_API_KEY makes
    // Claude use its own stored login and avoids the "Detected a custom
    // API key" prompt.
    _ = env_map.swapRemove("ANTHROPIC_API_KEY");
    const custom_hdr = try std.fmt.allocPrint(allocator, "X-Mcc-Proxy-Secret: {s}", .{secret});
    defer allocator.free(custom_hdr);
    try env_map.put("ANTHROPIC_CUSTOM_HEADERS", custom_hdr);
    return port;
}

