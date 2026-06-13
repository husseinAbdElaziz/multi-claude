/// Helpers for translating the termination status of a child process into
/// our own exit status. Used by the launcher and update command so callers
/// of `mcc` see the same exit code/signal as the wrapped program.
const std = @import("std");

/// Exit this process mirroring how the child terminated:
///
///   - `.exited(n)`     → exit with code `n`
///   - `.signal(s)`     → exit 128 + signal (POSIX convention for signal kills)
///   - `.stopped(s)`    → exit 128 + signal (same convention for SIGSTOP)
///   - `.unknown(code)` → exit with the raw status code
///
/// This never returns — it always calls `std.process.exit`.
pub fn propagateTerm(term: std.process.Child.Term) noreturn {
    switch (term) {
        .exited => |code| std.process.exit(code),
        .signal => |sig| std.process.exit(@as(u8, @intCast(128 + @intFromEnum(sig)))),
        .stopped => |sig| std.process.exit(@as(u8, @intCast(128 + @intFromEnum(sig)))),
        .unknown => |code| std.process.exit(@as(u8, @intCast(code))),
    }
}
