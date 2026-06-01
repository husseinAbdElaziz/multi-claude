const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const composer = @import("composer.zig");
const manifest = @import("manifest.zig");
const lock = @import("lock.zig");
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

    // Build argv: claude <extra_args>
    var argv_list = std.ArrayList([]const u8).initCapacity(allocator, extra_args.len + 1) catch unreachable;
    defer argv_list.deinit(allocator);

    try argv_list.append(allocator, "claude");
    for (extra_args) |arg| {
        try argv_list.append(allocator, arg);
    }
    const argv = try argv_list.toOwnedSlice(allocator);
    defer allocator.free(argv);

    // Build environment: clone parent + set CLAUDE_CONFIG_DIR
    var env_map = try std.process.Environ.createMap(init.environ, allocator);
    defer env_map.deinit();
    try env_map.put("CLAUDE_CONFIG_DIR", profile_config);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &env_map,
    });
    propagateTerm(child.wait(io) catch return);
}

fn propagateTerm(term: std.process.Child.Term) noreturn {
    switch (term) {
        .exited => |code| std.process.exit(code),
        .signal => |sig| std.process.exit(@as(u8, @intCast(128 + @intFromEnum(sig)))),
        .stopped => |sig| std.process.exit(@as(u8, @intCast(128 + @intFromEnum(sig)))),
        .unknown => |code| std.process.exit(@as(u8, @intCast(code))),
    }
}
