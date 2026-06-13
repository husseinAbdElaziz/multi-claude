const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Io = std.Io;
const Allocator = std.mem.Allocator;

fn getIo() Io {
    return Io.Threaded.global_single_threaded.io();
}

/// Create a symbolic link: link_path -> target_path
pub fn symlinkCreate(target: []const u8, link_path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        return error.SymlinkUnsupported;
    }
    var target_buf: [4096:0]u8 = undefined;
    var link_buf: [4096:0]u8 = undefined;
    if (target.len >= target_buf.len) return error.NameTooLong;
    if (link_path.len >= link_buf.len) return error.NameTooLong;
    @memcpy(target_buf[0..target.len], target);
    target_buf[target.len] = 0;
    @memcpy(link_buf[0..link_path.len], link_path);
    link_buf[link_path.len] = 0;
    const rc = std.c.symlink(&target_buf, &link_buf);
    if (rc != 0) return std.posix.unexpectedErrno(std.posix.errno(rc));
}

/// Check if a path is a symlink
pub fn isSymlink(path: []const u8) bool {
    const io = getIo();
    var buf: [256]u8 = undefined;
    if (std.fs.path.isAbsolute(path)) {
        return (Io.Dir.readLinkAbsolute(io, path, &buf) catch return false) > 0;
    } else {
        return (Io.Dir.cwd().readLink(io, path, &buf) catch return false) > 0;
    }
}

/// Create a directory and all parent directories as needed
pub fn mkdirAll(path: []const u8) !void {
    const io = getIo();
    Io.Dir.createDirPath(Io.Dir.cwd(), io, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Check if a path exists (file or directory). Any access error (not found,
/// permission, etc.) is treated as "does not exist".
pub fn exists(path: []const u8) bool {
    const io = getIo();
    if (std.fs.path.isAbsolute(path)) {
        Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    } else {
        _ = Io.Dir.statFile(Io.Dir.cwd(), io, path, .{}) catch return false;
    }
    return true;
}

/// Delete a file or symlink (idempotent - ignores if not found)
pub fn remove(path: []const u8) !void {
    const io = getIo();
    if (std.fs.path.isAbsolute(path)) {
        Io.Dir.deleteFileAbsolute(io, path) catch {};
    } else {
        Io.Dir.cwd().deleteFile(io, path) catch {};
    }
}

/// Remove a directory and all its contents recursively (idempotent - ignores if not found)
pub fn removeAll(path: []const u8) !void {
    const io = getIo();
    if (std.fs.path.isAbsolute(path)) {
        const parent = std.fs.path.dirname(path) orelse return;
        const basename = std.fs.path.basename(path);
        const dir = Io.Dir.openDirAbsolute(io, parent, .{}) catch return;
        defer Io.Dir.close(dir, io);
        dir.deleteTree(io, basename) catch {};
    } else {
        Io.Dir.cwd().deleteTree(io, path) catch {};
    }
}

/// Write content to a file atomically (write to temp, then rename)
pub fn atomicWrite(allocator: Allocator, full_path: []const u8, content: []const u8) !void {
    const io = getIo();
    const tmp_path = try std.mem.concat(allocator, u8, &.{ full_path, ".tmp" });
    defer allocator.free(tmp_path);

    const file = if (std.fs.path.isAbsolute(tmp_path))
        try Io.Dir.createFileAbsolute(io, tmp_path, .{})
    else
        try Io.Dir.createFile(Io.Dir.cwd(), io, tmp_path, .{});
    defer Io.File.close(file, io);

    try Io.File.writeStreamingAll(file, io, content);

    // 0600: config files may hold provider API keys — keep them owner-only.
    // Applied to the temp file so the final path inherits it through rename
    // (no window where the secret sits world-readable).
    if (builtin.os.tag != .windows and tmp_path.len < 4096) {
        var pbuf: [4096:0]u8 = undefined;
        @memcpy(pbuf[0..tmp_path.len], tmp_path);
        pbuf[tmp_path.len] = 0;
        _ = std.c.chmod(&pbuf, 0o600);
    }

    Io.Dir.renameAbsolute(tmp_path, full_path, io) catch |err| {
        remove(tmp_path) catch {};
        return err;
    };
}

/// List the names of immediate subdirectories of `path`. Returns an owned slice
/// of owned names (caller frees each name and the slice). Yields an empty slice
/// when `path` is missing or cannot be opened — never errors on those.
pub fn listSubdirs(allocator: Allocator, path: []const u8) ![][]u8 {
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    const io = getIo();
    const dir = (if (std.fs.path.isAbsolute(path))
        Io.Dir.openDirAbsolute(io, path, .{ .iterate = true })
    else
        Io.Dir.cwd().openDir(io, path, .{ .iterate = true })) catch
        return names.toOwnedSlice(allocator);
    defer Io.Dir.close(dir, io);

    var it = Io.Dir.iterate(dir);
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return names.toOwnedSlice(allocator);
}

/// Read a file to string
pub fn readFile(allocator: Allocator, path: []const u8) ![]u8 {
    const io = getIo();
    const file = if (std.fs.path.isAbsolute(path))
        try Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only })
    else
        try Io.Dir.openFile(Io.Dir.cwd(), io, path, .{ .mode = .read_only });
    defer Io.File.close(file, io);

    const stat_buf = try Io.File.stat(file, io);
    const file_size = @as(usize, @intCast(stat_buf.size));
    const buffer = try allocator.alloc(u8, file_size);
    _ = try Io.File.readPositionalAll(file, io, buffer, 0);
    return buffer;
}
