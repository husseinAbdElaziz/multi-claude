const std = @import("std");
const Io = std.Io;

pub const Level = enum(u2) {
    debug,
    info,
    warn,
    error_,
};

pub const Log = struct {
    min_level: Level,

    pub fn init(verbose: bool) Log {
        return .{
            .min_level = if (verbose) .debug else .info,
        };
    }

    pub fn log(self: *const Log, level: Level, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(self.min_level)) return;

        const prefix = switch (level) {
            .error_ => "\x1b[31m[ERROR]\x1b[0m ",
            .warn => "\x1b[33m[WARN]\x1b[0m ",
            .info => "\x1b[34m[INFO]\x1b[0m ",
            .debug => "\x1b[2m[DEBUG]\x1b[0m ",
        };

        const io = Io.Threaded.global_single_threaded.io();
        const out = Io.File.stderr();
        Io.File.writeStreamingAll(out, io, prefix) catch {};
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        Io.File.writeStreamingAll(out, io, msg) catch {};
        Io.File.writeStreamingAll(out, io, "\n") catch {};
    }

    pub fn err(self: *const Log, comptime fmt: []const u8, args: anytype) void {
        self.log(.error_, fmt, args);
    }

    pub fn warn(self: *const Log, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub fn info(self: *const Log, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub fn debug(self: *const Log, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }
};
