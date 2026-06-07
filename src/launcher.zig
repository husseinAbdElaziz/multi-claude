const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const composer = @import("composer.zig");
const manifest = @import("manifest.zig");
const lock = @import("lock.zig");
const provider_mod = @import("provider.zig");
const providers_mod = @import("providers.zig");
const proxy_mod = @import("proxy.zig");
const fsx = @import("fsx.zig");
const Log = @import("log.zig").Log;

const Init = std.process.Init.Minimal;
const Io = std.Io;

/// Build a properly-initialized threaded Io for spawning child processes.
///
/// The global `Io.Threaded.global_single_threaded` instance uses a *failing*
/// allocator, so any `std.process.spawn` through it returns `OutOfMemory`.
/// Spawning needs a real allocator, and the parent `environ` is required so
/// `argv[0]` (e.g. "claude") can be resolved against `PATH`.
fn spawnIo(allocator: Allocator, init: Init) Io.Threaded {
    return Io.Threaded.init(allocator, .{ .environ = init.environ });
}

/// Run the default profile (equivalent to running `claude` directly)
pub fn runDefault(allocator: Allocator, logger: Log, init: Init) !void {
    _ = logger;

    var threaded = spawnIo(allocator, init);
    defer threaded.deinit();
    const io = threaded.io();

    // Build env map with parent environment
    var env_map = try std.process.Environ.createMap(init.environ, allocator);
    defer env_map.deinit();

    var child = try std.process.spawn(io, .{
        .argv = &.{ "claude" },
        .environ_map = &env_map,
    });
    propagateTerm(child.wait(io) catch return);
}

/// Run a specific profile
pub fn runProfile(allocator: Allocator, logger: Log, profile_name: []const u8, extra_args: []const []const u8, init: Init) !void {
    var threaded = spawnIo(allocator, init);
    defer threaded.deinit();
    const io = threaded.io();

    const profile_config = try config.profileConfigDir(allocator, profile_name);
    defer allocator.free(profile_config);

    // Compose the config directory (idempotent), honoring the profile's
    // sharing policy from its manifest. Fall back to shared if missing.
    const shared = blk: {
        const m = manifest.Manifest.load(allocator, profile_name) catch break :blk true;
        defer allocator.free(m.name);
        break :blk m.shared;
    };
    try composer.compose(allocator, logger, profile_name, shared);

    // Acquire an advisory lock for the profile and hold it for the entire
    // lifetime of the child `claude`. We deliberately do NOT release it in this
    // function: the lock must stay held until `claude` exits, and
    // `propagateTerm` ends this process via `std.process.exit` (which skips
    // `defer`s). The kernel releases the flock when our fd is closed on exit.
    const lock_path = try config.profileLockPath(allocator, profile_name);
    defer allocator.free(lock_path);

    const lock_file = lock.tryAcquire(lock_path) catch |err| blk: {
        logger.warn("could not lock profile '{s}': {} — launching anyway", .{ profile_name, err });
        break :blk null;
    };
    if (lock_file == null) {
        logger.warn("profile '{s}' appears to be running already; launching anyway", .{profile_name});
    }

    // Build environment: clone parent + set CLAUDE_CONFIG_DIR + provider vars
    var env_map = try std.process.Environ.createMap(init.environ, allocator);
    defer env_map.deinit();
    try env_map.put("CLAUDE_CONFIG_DIR", profile_config);

    // Load single-provider config (provider.json). For openai_compat endpoints (e.g. LM Studio)
    // synthesize a providers.json so the proxy handles Anthropic→OpenAI translation.
    // For anthropic_compat endpoints set env vars directly (no proxy needed).
    // model_arg is owned here and outlives spawn (argv holds a reference into it).
    var model_arg: ?[]u8 = null;
    defer if (model_arg) |m| allocator.free(m);

    {
        const maybe_prov = provider_mod.load(allocator, profile_name) catch null;
        if (maybe_prov) |p| {
            var pp = p;
            defer pp.deinit(allocator);

            // Disown model so deinit doesn't free it; we track lifetime via model_arg.
            if (pp.model) |m| {
                pp.model = null;
                model_arg = m;
            }

            if (pp.openai_compat) {
                // Always re-synthesize providers.json from provider.json so URL/model changes
                // take effect immediately. startProxyIfNeeded will find it.
                var models_list = std.ArrayList([]u8).empty;
                defer models_list.deinit(allocator);
                if (model_arg) |m| try models_list.append(allocator, m);
                const owned_models = try models_list.toOwnedSlice(allocator);
                const entry = providers_mod.ProviderEntry{
                    .name = try allocator.dupe(u8, "provider"),
                    .provider_type = .openai_compat,
                    .api_url = try allocator.dupe(u8, pp.api_url orelse ""),
                    .api_key = if (pp.api_key) |k| try allocator.dupe(u8, k) else null,
                    .models = owned_models,
                };
                const entries = try allocator.alloc(providers_mod.ProviderEntry, 1);
                entries[0] = entry;
                var cfg = providers_mod.Config{ .entries = entries };
                try providers_mod.save(allocator, profile_name, cfg);
                cfg.entries[0].models = &.{}; // model_arg owns the strings, prevent double-free
                cfg.deinit(allocator);
                logger.info("configured openai_compat provider proxy", .{});
            } else {
                // anthropic_compat: pass through directly, no translation needed.
                if (pp.api_url) |url| try env_map.put("ANTHROPIC_BASE_URL", url);
                if (pp.api_key) |key| try env_map.put("ANTHROPIC_API_KEY", key);
            }
        }
    }

    // Start proxy if multi-provider config exists (providers.json) — including synthesized above.
    var proxy_child: ?std.process.Child = null;
    const proxy_port = startProxyIfNeeded(allocator, logger, io, init, profile_name, &env_map, &proxy_child) catch |err| blk: {
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

/// If providers.json exists for the profile, spawn the proxy subprocess and
/// update env_map with ANTHROPIC_BASE_URL + internal token.
/// Returns the proxy port (0 if no proxy started). Sets child_out on success.
fn startProxyIfNeeded(
    allocator: Allocator,
    logger: Log,
    io: Io,
    init: Init,
    profile_name: []const u8,
    env_map: *std.process.Environ.Map,
    child_out: *?std.process.Child,
) !u16 {
    var pcfg = providers_mod.load(allocator, profile_name) catch return 0;
    if (pcfg == null) return 0;
    const entry_count = pcfg.?.entries.len;
    pcfg.?.deinit(allocator);
    if (entry_count == 0) return 0;

    var port_io = Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer port_io.deinit();
    const port = proxy_mod.findFreePort(port_io.io()) catch return 0;
    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_str);

    logger.info("starting provider proxy on port {d}", .{port});

    // Random per-run secret: injected as Claude Code's ANTHROPIC_API_KEY and
    // required by the proxy on every request, so no other local process or
    // browser page can drive the proxy with the user's real key.
    const secret = try proxy_mod.generateSecret(allocator, io);
    defer allocator.free(secret);

    // Proxy inherits original environ so it has the real ANTHROPIC_API_KEY.
    var proxy_env = try std.process.Environ.createMap(init.environ, allocator);
    defer proxy_env.deinit();
    try proxy_env.put("MCC_PROXY_SECRET", secret);

    var exe_io = Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer exe_io.deinit();
    const self_exe = std.process.executablePathAlloc(exe_io.io(), allocator) catch null;
    defer if (self_exe) |p| allocator.free(p);

    // Use the caller's io so kill/wait on the child work with the same io.
    const child = try std.process.spawn(io, .{
        .argv = &.{ self_exe orelse return error.SelfExeNotFound, "__proxy__", profile_name, port_str },
        .environ_map = &proxy_env,
    });
    child_out.* = child;

    // Give proxy time to bind the port before Claude Code starts.
    const ts = std.c.timespec{ .sec = 0, .nsec = 200_000_000 };
    _ = std.c.nanosleep(&ts, null);

    const proxy_url = try std.fmt.allocPrint(allocator, "http://localhost:{d}", .{port});
    defer allocator.free(proxy_url);

    try env_map.put("ANTHROPIC_BASE_URL", proxy_url);
    // Gate the proxy with a secret in a CUSTOM header, not the auth header, so
    // Claude Code's own Anthropic credential (OAuth token or API key) still
    // flows through untouched — needed to pass claude-* requests upstream.
    // Dropping any inherited ANTHROPIC_API_KEY makes Claude use its own stored
    // login and avoids the "Detected a custom API key" prompt.
    _ = env_map.swapRemove("ANTHROPIC_API_KEY");
    const custom_hdr = try std.fmt.allocPrint(allocator, "X-Mcc-Proxy-Secret: {s}", .{secret});
    defer allocator.free(custom_hdr);
    try env_map.put("ANTHROPIC_CUSTOM_HEADERS", custom_hdr);
    return port;
}

fn propagateTerm(term: std.process.Child.Term) noreturn {
    switch (term) {
        .exited => |code| std.process.exit(code),
        .signal => |sig| std.process.exit(@as(u8, @intCast(128 + @intFromEnum(sig)))),
        .stopped => |sig| std.process.exit(@as(u8, @intCast(128 + @intFromEnum(sig)))),
        .unknown => |code| std.process.exit(@as(u8, @intCast(code))),
    }
}
