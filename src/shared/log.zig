/// Tiny stderr logger with level filtering and color-coded prefixes.
///
/// All output goes to stderr (stdout is reserved for things the user
/// pipes elsewhere, like `mcc which <name>`). `--verbose` / `-vv`
/// enables the `debug` level; otherwise debug lines are silently
/// dropped.
const std = @import("std");
const Io = std.Io;

/// Severity levels, ordered. `error_` is the trailing underscore
/// because `error` is a zig keyword.
pub const Level = enum(u2) {
    debug,
    info,
    warn,
    error_,
};

/// Logger handle. Cheap to pass by value; just a `min_level`.
pub const Log = struct {
    min_level: Level,

    /// Build a logger. `verbose = true` enables debug output
    /// (`--verbose` / `-vv` flag), otherwise debug is filtered out.
    pub fn init(verbose: bool) Log {
        return .{
            .min_level = if (verbose) .debug else .info,
        };
    }

    /// Emit one log line at `level`. Filters by `min_level` first;
    /// emits a color-coded `[LEVEL]` prefix, then the formatted
    /// message, then a newline, all to stderr.
    ///
    /// Formatting tries a 1 KiB stack buffer first; on overflow it
    /// falls back to a heap allocation so very long messages aren't
    /// silently truncated.
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
        // 1 KiB covers realistic error messages (paths included) without
        // an allocation. For very long messages the allocator is used as a
        // fallback so nothing is silently truncated.
        var stack_buf: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&stack_buf, fmt, args)) |msg| {
            Io.File.writeStreamingAll(out, io, msg) catch {};
        } else |_| {
            const msg = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
            defer std.heap.page_allocator.free(msg);
            Io.File.writeStreamingAll(out, io, msg) catch {};
        }
        Io.File.writeStreamingAll(out, io, "\n") catch {};
    }

    /// Convenience: log at the `error_` level.
    pub fn err(self: *const Log, comptime fmt: []const u8, args: anytype) void {
        self.log(.error_, fmt, args);
    }

    /// Convenience: log at the `warn` level.
    pub fn warn(self: *const Log, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    /// Convenience: log at the `info` level.
    pub fn info(self: *const Log, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    /// Convenience: log at the `debug` level. Only emitted when the
    /// logger was built with `verbose = true`.
    pub fn debug(self: *const Log, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }
};
