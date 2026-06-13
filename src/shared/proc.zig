/// Child-process helpers shared across launch paths.
const std = @import("std");

/// Exit this process mirroring how a child terminated, so callers of `mcc`
/// observe the same exit/signal status as the wrapped `claude` (or installer).
pub fn propagateTerm(term: std.process.Child.Term) noreturn {
    switch (term) {
        .exited => |code| std.process.exit(code),
        .signal => |sig| std.process.exit(@as(u8, @intCast(128 + @intFromEnum(sig)))),
        .stopped => |sig| std.process.exit(@as(u8, @intCast(128 + @intFromEnum(sig)))),
        .unknown => |code| std.process.exit(@as(u8, @intCast(code))),
    }
}
