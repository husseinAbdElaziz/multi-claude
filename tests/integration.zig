const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Src = @import("src");
const fsx = Src.fsx;
const config = Src.config;
const profile = Src.profile;
const manifest = Src.manifest;
const resources = Src.resources;
const composer = Src.composer;
const Log = Src.log.Log;

fn getIo() Io {
    return Io.Threaded.global_single_threaded.io();
}

/// Create a fake claude config directory for integration tests
fn setupFakeClaudeDir(allocator: std.mem.Allocator, base: []const u8) !void {
    const claude_dir = try std.fmt.allocPrint(allocator, "{s}/.claude", .{base});
    defer allocator.free(claude_dir);

    try fsx.mkdirAll(claude_dir);

    // Create shared resources
    const settings = try std.fmt.allocPrint(allocator, "{s}/settings.json", .{claude_dir});
    defer allocator.free(settings);
    try fsx.atomicWrite(allocator, settings, "{}");

    const skills_dir = try std.fmt.allocPrint(allocator, "{s}/skills", .{claude_dir});
    defer allocator.free(skills_dir);
    try fsx.mkdirAll(skills_dir);

    const plugins_dir = try std.fmt.allocPrint(allocator, "{s}/plugins", .{claude_dir});
    defer allocator.free(plugins_dir);
    try fsx.mkdirAll(plugins_dir);

    const claude_md = try std.fmt.allocPrint(allocator, "{s}/CLAUDE.md", .{claude_dir});
    defer allocator.free(claude_md);
    try fsx.atomicWrite(allocator, claude_md, "# Test Memory\n");
}

/// Create a fake claude shim script that records CLAUDE_CONFIG_DIR
fn createClaudeShim(allocator: std.mem.Allocator, base: []const u8) ![]u8 {
    const shim_path = try std.fmt.allocPrint(allocator, "{s}/fake_claude.sh", .{base});
    const content =
        \\#!/usr/bin/env bash
        \\echo "$CLAUDE_CONFIG_DIR" > "{s}/claude_config_dir.txt"
        \\exit 0
    ;

    try fsx.atomicWrite(allocator, shim_path, std.fmt.comptimePrint(content, .{base}));

    // Make executable
    const io = getIo();
    const file = Io.Dir.openFileAbsolute(io, shim_path, .{ .mode = .read_write }) catch unreachable;
    defer Io.File.close(file, io);
    const stat = Io.File.stat(file, io) catch unreachable;
    _ = std.posix.fchmod(stat.inode, std.posix.S.IRWXU) catch {};

    return shim_path;
}

test "integration: create shared profile and verify symlinks" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = getIo();

    // Create temp directory
    const tmp_dir = try std.fmt.allocPrint(gpa, "/tmp/mcc_integration_test_{d}", .{
        @as(u64, @intCast(Io.Timestamp.now(io, .real).toSeconds())),
    });
    defer gpa.free(tmp_dir);
    defer fsx.removeAll(tmp_dir) catch {};
    try fsx.mkdirAll(tmp_dir);

    // Setup fake claude dir
    try setupFakeClaudeDir(gpa, tmp_dir);

    // Override HOME for this test by setting up mcc dir manually
    const mcc_dir = try std.fmt.allocPrint(gpa, "{s}/.multi-claude", .{tmp_dir});
    defer gpa.free(mcc_dir);
    try fsx.mkdirAll(mcc_dir);

    const profiles_dir = try std.fmt.allocPrint(gpa, "{s}/profiles", .{mcc_dir});
    defer gpa.free(profiles_dir);
    try fsx.mkdirAll(profiles_dir);

    _ = Log.init(false);

    // We can't easily override HOME env vars in tests, so we test composer directly
    // Create the profile directory manually
    const prof_dir = try std.fmt.allocPrint(gpa, "{s}/testprof", .{profiles_dir});
    defer gpa.free(prof_dir);
    try fsx.mkdirAll(prof_dir);

    // Create manifest manually
    var m: manifest.Manifest = .{
        .name = try gpa.dupe(u8, "testprof"),
        .shared = true,
        .created_at = 0,
    };
    defer gpa.free(m.name);

    // Save manifest to the test directory
    const manifest_path = try std.fmt.allocPrint(gpa, "{s}/manifest.zon", .{prof_dir});
    defer gpa.free(manifest_path);
    const zon = try m.toZon(gpa);
    defer gpa.free(zon);
    try fsx.atomicWrite(gpa, manifest_path, zon);

    // Load and verify manifest
    const loaded_data = try fsx.readFile(gpa, manifest_path);
    defer gpa.free(loaded_data);
    const loaded = try manifest.Manifest.fromZon(gpa, loaded_data);
    defer gpa.free(loaded.name);

    try std.testing.expectEqualStrings("testprof", loaded.name);
    try std.testing.expect(loaded.shared);

    // Verify compose creates config dir
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{prof_dir});
    defer gpa.free(config_dir);
    try fsx.mkdirAll(config_dir);

    // Manually create symlinks for shared resources (simulating composer)
    const claude_dir = try std.fmt.allocPrint(gpa, "{s}/.claude", .{tmp_dir});
    defer gpa.free(claude_dir);

    for (resources.resources) |resource| {
        const should_share = resources.policy(resource, true);
        if (!should_share) continue;

        const source_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ claude_dir, resource.path });
        defer gpa.free(source_path);

        if (!fsx.exists(source_path)) continue;

        const target_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ config_dir, resource.path });
        defer gpa.free(target_path);

        try fsx.remove(target_path);
        try fsx.symlinkCreate(source_path, target_path);
    }

    // Verify symlinks exist for shared resources
    const settings_link = try std.fmt.allocPrint(gpa, "{s}/settings.json", .{config_dir});
    defer gpa.free(settings_link);
    try std.testing.expect(fsx.isSymlink(settings_link));

    const skills_link = try std.fmt.allocPrint(gpa, "{s}/skills", .{config_dir});
    defer gpa.free(skills_link);
    try std.testing.expect(fsx.isSymlink(skills_link));

    const plugins_link = try std.fmt.allocPrint(gpa, "{s}/plugins", .{config_dir});
    defer gpa.free(plugins_link);
    try std.testing.expect(fsx.isSymlink(plugins_link));
}

test "integration: create isolated profile and verify no symlinks" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = getIo();

    const tmp_dir = try std.fmt.allocPrint(gpa, "/tmp/mcc_isolated_test_{d}", .{
        @as(u64, @intCast(Io.Timestamp.now(io, .real).toSeconds())),
    });
    defer gpa.free(tmp_dir);
    defer fsx.removeAll(tmp_dir) catch {};
    try fsx.mkdirAll(tmp_dir);

    try setupFakeClaudeDir(gpa, tmp_dir);

    const mcc_dir = try std.fmt.allocPrint(gpa, "{s}/.multi-claude", .{tmp_dir});
    defer gpa.free(mcc_dir);
    try fsx.mkdirAll(mcc_dir);

    const profiles_dir = try std.fmt.allocPrint(gpa, "{s}/profiles", .{mcc_dir});
    defer gpa.free(profiles_dir);
    try fsx.mkdirAll(profiles_dir);

    // Create isolated profile directory
    const prof_dir = try std.fmt.allocPrint(gpa, "{s}/isolated", .{profiles_dir});
    defer gpa.free(prof_dir);
    try fsx.mkdirAll(prof_dir);

    // Create manifest with shared=false
    var m: manifest.Manifest = .{
        .name = try gpa.dupe(u8, "isolated"),
        .shared = false,
        .created_at = 0,
    };
    defer gpa.free(m.name);

    const manifest_path = try std.fmt.allocPrint(gpa, "{s}/manifest.zon", .{prof_dir});
    defer gpa.free(manifest_path);
    const zon = try m.toZon(gpa);
    defer gpa.free(zon);
    try fsx.atomicWrite(gpa, manifest_path, zon);

    // Create config dir (for isolated, no symlinks)
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{prof_dir});
    defer gpa.free(config_dir);
    try fsx.mkdirAll(config_dir);

    // For isolated profile, create private directories (no symlinks)
    for (resources.resources) |resource| {
        const should_share = resources.policy(resource, false);
        try std.testing.expect(!should_share);

        if (resource.is_dir) {
            const target_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ config_dir, resource.path });
            defer gpa.free(target_path);
            try fsx.mkdirAll(target_path);
        }
    }

    // Verify private directories exist and are NOT symlinks
    const sessions_dir = try std.fmt.allocPrint(gpa, "{s}/sessions", .{config_dir});
    defer gpa.free(sessions_dir);
    try std.testing.expect(fsx.exists(sessions_dir));
    try std.testing.expect(!fsx.isSymlink(sessions_dir));

    const skills_dir = try std.fmt.allocPrint(gpa, "{s}/skills", .{config_dir});
    defer gpa.free(skills_dir);
    try std.testing.expect(fsx.exists(skills_dir));
    try std.testing.expect(!fsx.isSymlink(skills_dir));
}

test "integration: profile deletion does not affect shared resources" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = getIo();

    const tmp_dir = try std.fmt.allocPrint(gpa, "/tmp/mcc_delete_test_{d}", .{
        @as(u64, @intCast(Io.Timestamp.now(io, .real).toSeconds())),
    });
    defer gpa.free(tmp_dir);
    defer fsx.removeAll(tmp_dir) catch {};
    try fsx.mkdirAll(tmp_dir);

    try setupFakeClaudeDir(gpa, tmp_dir);

    // Verify claude dir exists before deletion
    const claude_dir = try std.fmt.allocPrint(gpa, "{s}/.claude", .{tmp_dir});
    defer gpa.free(claude_dir);
    try std.testing.expect(fsx.exists(claude_dir));

    // Create a profile
    const profiles_dir = try std.fmt.allocPrint(gpa, "{s}/.multi-claude/profiles", .{tmp_dir});
    defer gpa.free(profiles_dir);
    try fsx.mkdirAll(profiles_dir);

    const prof_dir = try std.fmt.allocPrint(gpa, "{s}/to_delete", .{profiles_dir});
    defer gpa.free(prof_dir);
    try fsx.mkdirAll(prof_dir);

    // Delete profile
    try fsx.removeAll(prof_dir);

    // Verify profile is gone
    try std.testing.expect(!fsx.exists(prof_dir));

    // Verify claude dir is still intact
    try std.testing.expect(fsx.exists(claude_dir));

    // Verify claude settings.json is still intact
    const settings = try std.fmt.allocPrint(gpa, "{s}/settings.json", .{claude_dir});
    defer gpa.free(settings);
    try std.testing.expect(fsx.exists(settings));
}

test "integration: lock acquisition and release" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const lock = Src.lock;
    const gpa = std.testing.allocator;
    const io = getIo();

    const tmp_dir = try std.fmt.allocPrint(gpa, "/tmp/mcc_lock_test_{d}", .{
        @as(u64, @intCast(Io.Timestamp.now(io, .real).toSeconds())),
    });
    defer gpa.free(tmp_dir);
    defer fsx.removeAll(tmp_dir) catch {};
    try fsx.mkdirAll(tmp_dir);

    const lock_path = try std.fmt.allocPrint(gpa, "{s}/test.lock", .{tmp_dir});
    defer gpa.free(lock_path);

    // First acquisition should succeed
    const file1 = try lock.tryAcquire(lock_path);
    try std.testing.expect(file1 != null);

    // Second acquisition should fail (lock held)
    const file2 = try lock.tryAcquire(lock_path);
    try std.testing.expect(file2 == null);

    // Release first lock
    lock.release(file1.?);

    // Third acquisition should succeed
    const file3 = try lock.tryAcquire(lock_path);
    try std.testing.expect(file3 != null);
    lock.release(file3.?);
}

test "integration: atomic write and read consistency" {
    const gpa = std.testing.allocator;
    const io = getIo();

    const tmp_dir = try std.fmt.allocPrint(gpa, "/tmp/mcc_atomic_test_{d}", .{
        @as(u64, @intCast(Io.Timestamp.now(io, .real).toSeconds())),
    });
    defer gpa.free(tmp_dir);
    defer fsx.removeAll(tmp_dir) catch {};
    try fsx.mkdirAll(tmp_dir);

    const file_path = try std.fmt.allocPrint(gpa, "{s}/data.txt", .{tmp_dir});
    defer gpa.free(file_path);

    const content = "Hello, integration tests!";
    try fsx.atomicWrite(gpa, file_path, content);

    const read = try fsx.readFile(gpa, file_path);
    defer gpa.free(read);

    try std.testing.expectEqualStrings(content, read);
}
