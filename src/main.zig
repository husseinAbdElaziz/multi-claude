const std = @import("std");
pub const cli = @import("cli.zig");
pub const config = @import("config.zig");
pub const profile = @import("profile.zig");
pub const manifest = @import("manifest.zig");
pub const resources = @import("resources.zig");
pub const composer = @import("composer.zig");
pub const launcher = @import("launcher.zig");
pub const lock = @import("lock.zig");
pub const fsx = @import("fsx.zig");
pub const log = @import("log.zig");
pub const doctor = @import("doctor.zig");

/// Calculate simple Levenshtein distance between two strings
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

/// Find similar profile names and suggest them
fn suggestProfiles(allocator: std.mem.Allocator, logger: log.Log, target: []const u8) !void {
    const mcc_dir = config.mccDir(allocator) catch return;
    defer allocator.free(mcc_dir);

    const profiles_dir = std.fmt.allocPrint(allocator, "{s}/profiles", .{mcc_dir}) catch return;
    defer allocator.free(profiles_dir);

    if (!fsx.exists(profiles_dir)) return;

    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = std.Io.Dir.openDirAbsolute(io, profiles_dir, .{ .iterate = true }) catch return;
    defer std.Io.Dir.close(dir, io);

    var best_distance: usize = 3;
    var best_name: []const u8 = "";

    var it = std.Io.Dir.iterate(dir);
    while (it.next(io) catch return) |entry| {
        if (entry.kind == .directory) {
            const dist = levenshtein(target, entry.name);
            if (dist < best_distance and dist > 0) {
                best_distance = dist;
                best_name = entry.name;
            }
        }
    }

    if (best_name.len > 0) {
        logger.err("did you mean '{s}'?", .{best_name});
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;

    // Collect command-line args (skip the program name)
    var args_it = std.process.Args.Iterator.init(init.args);
    _ = args_it.next(); // skip program name

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

    switch (parsed.command) {
        .run_default => {
            try launcher.runDefault(gpa, logger, init);
        },
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
        .new => {
            const pname = parsed.profile orelse {
                logger.err("profile name required", .{});
                std.process.exit(1);
            };
            try profile.create(gpa, logger, pname, parsed.no_share);
        },
        .delete => {
            const pname = parsed.profile orelse {
                logger.err("profile name required", .{});
                std.process.exit(1);
            };
            try profile.delete(gpa, logger, pname);
        },
        .ls => {
            try profile.list(gpa, logger);
        },
        .which => {
            const pname = parsed.profile orelse {
                logger.err("profile name required", .{});
                std.process.exit(1);
            };
            try profile.which(gpa, logger, pname);
        },
        .doctor => {
            try doctor.check(gpa, logger);
        },
        .help => {
            printUsage();
        },
        .version => {
            printVersion();
        },
    }
}

fn printUsage() void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const out = std.Io.File.stdout();
    const msg =
        \\Usage: mcc [command] [profile] [options]
        \\
        \\Commands:
        \\  <profile>              Run claude with the specified profile
        \\  new <profile>          Create a new profile (shared by default)
        \\  new <profile> --no-share  Create an isolated profile
        \\  delete <profile>       Delete a profile
        \\  ls                     List all profiles
        \\  which <profile>        Show config directory for a profile
        \\  doctor                 Check environment configuration
        \\
        \\Options:
        \\  --help, -h             Show this help message
        \\  --version, -v          Show version
        \\
        \\Running with no arguments runs claude with the default profile.
        \\
    ;
    _ = std.Io.File.writeStreamingAll(out, io, msg) catch {};
}

fn printVersion() void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const out = std.Io.File.stdout();
    _ = std.Io.File.writeStreamingAll(out, io, "mcc 0.1.0\n") catch {};
}
