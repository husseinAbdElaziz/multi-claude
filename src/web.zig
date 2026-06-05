const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;
const Log = @import("log.zig").Log;
const config = @import("config.zig");
const provider_mod = @import("provider.zig");
const fsx = @import("fsx.zig");

const Init = std.process.Init.Minimal;

const HTML = @embedFile("resources/ui.html");

pub fn serve(allocator: Allocator, logger: Log, init: Init, port: u16) !void {
    var threaded = Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    var server = try net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);

    logger.info("UI server at http://localhost:{d} — Ctrl+C to stop", .{port});

    openBrowser(allocator, logger, io, port) catch |err| {
        logger.warn("could not open browser: {}", .{err});
        logger.info("open http://localhost:{d} manually", .{port});
    };

    while (true) {
        var stream = server.accept(io) catch |err| {
            logger.warn("accept: {}", .{err});
            continue;
        };
        defer stream.close(io);
        handleConnection(allocator, io, &stream, logger) catch |err| {
            logger.warn("request error: {}", .{err});
        };
    }
}

fn openBrowser(allocator: Allocator, logger: Log, io: Io, port: u16) !void {
    _ = logger;
    const url = try std.fmt.allocPrint(allocator, "http://localhost:{d}", .{port});
    defer allocator.free(url);

    const open_cmd: []const u8 = switch (builtin.os.tag) {
        .macos => "open",
        .windows => "cmd",
        else => "xdg-open",
    };

    var child = try std.process.spawn(io, .{
        .argv = &.{ open_cmd, url },
    });
    _ = child.wait(io) catch {};
}

fn handleConnection(allocator: Allocator, io: Io, stream: *net.Stream, logger: Log) !void {
    _ = logger;

    var read_buf: [8192]u8 = undefined;
    var write_buf: [65536]u8 = undefined;

    var net_reader = net.Stream.Reader.init(stream.*, io, &read_buf);
    var net_writer = net.Stream.Writer.init(stream.*, io, &write_buf);

    var http_srv = std.http.Server.init(&net_reader.interface, &net_writer.interface);

    var request = http_srv.receiveHead() catch return;

    const method = request.head.method;
    const target = request.head.target;

    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..path_end];
    const query = if (path_end < target.len) target[path_end + 1 ..] else "";

    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        try request.respond(HTML, .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            },
        });
        return;
    }

    if (std.mem.eql(u8, path, "/api/profiles") and method == .GET) {
        try handleGetProfiles(allocator, &request);
        return;
    }

    if (std.mem.eql(u8, path, "/api/provider")) {
        const name = getQueryParam(query, "name");
        switch (method) {
            .GET => {
                try handleGetProvider(allocator, &request, name);
                return;
            },
            .POST => {
                try handlePostProvider(allocator, &request, name);
                return;
            },
            .DELETE => {
                try handleDeleteProvider(allocator, &request, name);
                return;
            },
            .OPTIONS => {
                try request.respond("", .{
                    .keep_alive = false,
                    .extra_headers = &.{
                        .{ .name = "access-control-allow-methods", .value = "GET, POST, DELETE, OPTIONS" },
                        .{ .name = "access-control-allow-headers", .value = "content-type" },
                    },
                });
                return;
            },
            else => {},
        }
    }

    try request.respond("Not Found", .{
        .status = .not_found,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
}

fn getQueryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, query, '&');
    while (it.next()) |param| {
        const eq = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        if (std.mem.eql(u8, param[0..eq], key)) return param[eq + 1 ..];
    }
    return null;
}

fn jsonResponse(request: *std.http.Server.Request, body: []const u8) !void {
    try request.respond(body, .{
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

fn handleGetProfiles(allocator: Allocator, request: *std.http.Server.Request) !void {
    const mcc_dir = try config.mccDir(allocator);
    defer allocator.free(mcc_dir);

    const profiles_dir = try std.fmt.allocPrint(allocator, "{s}/profiles", .{mcc_dir});
    defer allocator.free(profiles_dir);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "[");
    var first = true;

    if (fsx.exists(profiles_dir)) {
        const io = Io.Threaded.global_single_threaded.io();
        const dir = Io.Dir.openDirAbsolute(io, profiles_dir, .{ .iterate = true }) catch {
            try buf.appendSlice(allocator, "]");
            const body = try buf.toOwnedSlice(allocator);
            defer allocator.free(body);
            return jsonResponse(request, body);
        };
        defer Io.Dir.close(dir, io);

        var it = Io.Dir.iterate(dir);
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;

            if (!first) try buf.appendSlice(allocator, ",");
            first = false;

            const name = entry.name;
            var p: ?provider_mod.Provider = provider_mod.loadDirect(allocator, name) catch null;
            defer if (p) |*pp| pp.deinit(allocator);

            try buf.print(allocator, "{{\"name\":\"{s}\",\"hasProvider\":{s}}}", .{
                name,
                if (p != null) "true" else "false",
            });
        }
    }

    try buf.appendSlice(allocator, "]");
    const body = try buf.toOwnedSlice(allocator);
    defer allocator.free(body);
    try jsonResponse(request, body);
}

fn handleGetProvider(allocator: Allocator, request: *std.http.Server.Request, name: ?[]const u8) !void {
    const profile_name: ?[]const u8 = resolveProfileName(name);

    const p = try provider_mod.loadDirect(allocator, profile_name);
    if (p) |pp| {
        var mpp = pp;
        defer mpp.deinit(allocator);
        const json = try pp.toJson(allocator);
        defer allocator.free(json);
        return jsonResponse(request, json);
    }

    try jsonResponse(request, "{\"api_url\":null,\"api_key\":null,\"model\":null}");
}

fn handlePostProvider(allocator: Allocator, request: *std.http.Server.Request, name: ?[]const u8) !void {
    const body_len: usize = @intCast(request.head.content_length orelse 0);
    if (body_len == 0 or body_len > 4096) {
        try request.respond("{\"error\":\"invalid body\"}", .{
            .status = .bad_request,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
        return;
    }

    var body_buf: [512]u8 = undefined;
    var body_reader = request.readerExpectNone(&body_buf);
    const body = try body_reader.readAlloc(allocator, body_len);
    defer allocator.free(body);

    const profile_name: ?[]const u8 = resolveProfileName(name);

    var p = provider_mod.Provider.fromJson(allocator, body) catch {
        try request.respond("{\"error\":\"invalid JSON\"}", .{
            .status = .bad_request,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
        return;
    };
    defer p.deinit(allocator);

    provider_mod.save(allocator, profile_name, p) catch {
        try request.respond("{\"error\":\"failed to save\"}", .{
            .status = .internal_server_error,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
        return;
    };

    try jsonResponse(request, "{\"ok\":true}");
}

fn handleDeleteProvider(allocator: Allocator, request: *std.http.Server.Request, name: ?[]const u8) !void {
    const profile_name: ?[]const u8 = resolveProfileName(name);
    provider_mod.deleteConfig(allocator, profile_name) catch {};
    try jsonResponse(request, "{\"ok\":true}");
}

fn resolveProfileName(name: ?[]const u8) ?[]const u8 {
    const n = name orelse return null;
    if (std.mem.eql(u8, n, "default")) return null;
    return n;
}
