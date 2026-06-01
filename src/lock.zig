const std = @import("std");
const Io = std.Io;

fn getIo() Io {
    return Io.Threaded.global_single_threaded.io();
}

/// Try to acquire an advisory lock on a file. Returns the file handle on success,
/// null if the lock is already held (same profile running elsewhere).
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

/// Release a lock
pub fn release(file: Io.File) void {
    const io = getIo();
    Io.File.unlock(file, io);
    Io.File.close(file, io);
}
