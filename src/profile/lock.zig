const std = @import("std");
const Io = std.Io;

fn getIo() Io {
    return Io.Threaded.global_single_threaded.io();
}

/// Try to acquire an exclusive, non-blocking advisory lock on `lock_path`.
///
/// Returns the open file handle on success (the caller is responsible for
/// holding it for as long as the lock should stay held) or null when
/// another process already holds the lock. The same path is what the
/// launcher uses to prevent two `mcc <profile>` invocations from stepping
/// on each other's session state.
pub fn tryAcquire(lock_path: []const u8) !?Io.File {
    const io = getIo();
    const absolute = std.fs.path.isAbsolute(lock_path);
    // Create the lock file if it doesn't exist, or open it if it does
    const file = if (absolute)
        Io.Dir.openFileAbsolute(io, lock_path, .{
            .mode = .write_only,
        }) catch |err| switch (err) {
            error.FileNotFound => Io.Dir.createFileAbsolute(io, lock_path, .{}) catch |create_err| return create_err,
            else => return err,
        }
    else
        Io.Dir.openFile(Io.Dir.cwd(), io, lock_path, .{
            .mode = .write_only,
        }) catch |err| switch (err) {
            error.FileNotFound => Io.Dir.createFile(Io.Dir.cwd(), io, lock_path, .{}) catch |create_err| return create_err,
            else => return err,
        };

    // Try to acquire an exclusive, non-blocking lock
    const acquired = Io.File.tryLock(file, io, .exclusive) catch |err| {
        Io.File.close(file, io);
        return err;
    };

    if (!acquired) {
        Io.File.close(file, io);
        return null;
    }

    return file;
}

/// Release the lock and close the file handle. The kernel also drops the
/// flock when the fd is closed at process exit, so a crash won't leave
/// the lock held forever.
pub fn release(file: Io.File) void {
    const io = getIo();
    Io.File.unlock(file, io);
    Io.File.close(file, io);
}
