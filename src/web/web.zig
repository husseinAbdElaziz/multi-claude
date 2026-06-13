const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;
const Log = @import("../shared/log.zig").Log;
const config = @import("../shared/config.zig");
const provider_mod = @import("../provider/provider.zig");
const profile = @import("../profile/profile.zig");
const fsx = @import("../shared/fsx.zig");
const httpx = @import("../shared/httpx.zig");
const jsonw = @import("../shared/jsonw.zig");

const Init = std.process.Init.Minimal;

const HTML = @embedFile("resources/ui.html");

pub fn serve(allocator: Allocator, logger: Log, init: Init, port: u16) !void {
    var threaded = Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    var server = try net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
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

    // CSRF: the API mutates on-disk provider configs (API keys). Reject any
    // cross-site browser request before it can touch them.
    if (std.mem.startsWith(u8, path, "/api/") and !csrfOk(&request)) {
        try httpx.respondError(&request, .forbidden, "forbidden");
        return;
    }

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

    if (std.mem.eql(u8, path, "/api/fetch-models") and method == .GET) {
        try handleFetchModels(allocator, io, &request, query);
        return;
    }

    if (std.mem.eql(u8, path, "/api/provider")) {
        const name = getQueryParam(query, "name");
        // Reject path-traversal / unexpected characters before the name ever
        // reaches providerPath() (which interpolates it into a filesystem path).
        if (name) |n| {
            if (!profile.validateName(n)) {
                try httpx.respondError(&request, .bad_request, "invalid profile name");
                return;
            }
        }
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

fn percentDecode(allocator: Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch { try out.append(allocator, s[i]); i += 1; continue; };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch { try out.append(allocator, s[i]); i += 1; continue; };
            try out.append(allocator, (hi << 4) | lo);
            i += 3;
        } else if (s[i] == '+') {
            try out.append(allocator, ' ');
            i += 1;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn getQueryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, query, '&');
    while (it.next()) |param| {
        const eq = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        if (std.mem.eql(u8, param[0..eq], key)) return param[eq + 1 ..];
    }
    return null;
}

fn handleFetchModels(allocator: Allocator, io: Io, request: *std.http.Server.Request, query: []const u8) !void {
    const raw_url = getQueryParam(query, "url") orelse {
        return httpx.respondJson(request, "{\"error\":\"missing url\"}");
    };
    const raw_key = getQueryParam(query, "key");

    const url = try percentDecode(allocator, raw_url);
    defer allocator.free(url);
    const key: ?[]u8 = if (raw_key) |k| try percentDecode(allocator, k) else null;
    defer if (key) |k| allocator.free(k);

    // Errors (bad url, connection, non-200, malformed body) all collapse to one
    // message — this endpoint is a convenience probe, not a diagnostic tool.
    const ids = httpx.fetchModelIds(allocator, io, url, key) catch {
        return httpx.respondJson(request, "{\"error\":\"could not fetch models from provider\"}");
    };
    defer {
        for (ids) |m| allocator.free(m);
        allocator.free(ids);
    }

    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeByte('[');
    for (ids, 0..) |id, i| {
        if (i > 0) try out.writer.writeByte(',');
        try jsonw.writeStr(&out.writer, id);
    }
    try out.writer.writeByte(']');
    const json = try out.toOwnedSlice();
    defer allocator.free(json);
    return httpx.respondJson(request, json);
}

fn handleGetProfiles(allocator: Allocator, request: *std.http.Server.Request) !void {
    const mcc_dir = try config.mccDir(allocator);
    defer allocator.free(mcc_dir);

    const profiles_dir = try std.fmt.allocPrint(allocator, "{s}/profiles", .{mcc_dir});
    defer allocator.free(profiles_dir);

    const names = try fsx.listSubdirs(allocator, profiles_dir);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "[");
    for (names, 0..) |name, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");

        var p: ?provider_mod.Provider = provider_mod.loadDirect(allocator, name) catch null;
        defer if (p) |*pp| pp.deinit(allocator);

        try buf.print(allocator, "{{\"name\":\"{s}\",\"hasProvider\":{s}}}", .{
            name,
            if (p != null) "true" else "false",
        });
    }
    try buf.appendSlice(allocator, "]");

    const body = try buf.toOwnedSlice(allocator);
    defer allocator.free(body);
    try httpx.respondJson(request, body);
}

fn handleGetProvider(allocator: Allocator, request: *std.http.Server.Request, name: ?[]const u8) !void {
    const profile_name: ?[]const u8 = resolveProfileName(name);

    const p = try provider_mod.loadDirect(allocator, profile_name);
    if (p) |pp| {
        var mpp = pp;
        defer mpp.deinit(allocator);
        const json = try pp.toJson(allocator);
        defer allocator.free(json);
        return httpx.respondJson(request, json);
    }

    try httpx.respondJson(request, "{\"api_url\":null,\"api_key\":null,\"model\":null}");
}

fn handlePostProvider(allocator: Allocator, request: *std.http.Server.Request, name: ?[]const u8) !void {
    const body_len: usize = @intCast(request.head.content_length orelse 0);
    if (body_len == 0 or body_len > 4096) {
        try httpx.respondError(request, .bad_request, "invalid body");
        return;
    }

    var body_buf: [512]u8 = undefined;
    var body_reader = request.readerExpectNone(&body_buf);
    const body = try body_reader.readAlloc(allocator, body_len);
    defer allocator.free(body);

    const profile_name: ?[]const u8 = resolveProfileName(name);

    var p = provider_mod.Provider.fromJson(allocator, body) catch {
        try httpx.respondError(request, .bad_request, "invalid JSON");
        return;
    };
    defer p.deinit(allocator);

    provider_mod.save(allocator, profile_name, p) catch {
        try httpx.respondError(request, .internal_server_error, "failed to save");
        return;
    };

    try httpx.respondJson(request, "{\"ok\":true}");
}

fn handleDeleteProvider(allocator: Allocator, request: *std.http.Server.Request, name: ?[]const u8) !void {
    const profile_name: ?[]const u8 = resolveProfileName(name);
    provider_mod.deleteConfig(allocator, profile_name) catch {};
    try httpx.respondJson(request, "{\"ok\":true}");
}

/// Cross-site request protection. Modern browsers send Sec-Fetch-Site on every
/// request and JS cannot forge it; we allow only same-origin/none. If that
/// header is absent we fall back to an Origin host check; if neither is present
/// (curl, old clients) we allow — the threat is the browser, not the CLI.
fn csrfOk(request: *std.http.Server.Request) bool {
    var sec_fetch_site: ?[]const u8 = null;
    var origin: ?[]const u8 = null;
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "sec-fetch-site")) sec_fetch_site = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "origin")) origin = h.value;
    }
    if (sec_fetch_site) |s| {
        return std.mem.eql(u8, s, "same-origin") or std.mem.eql(u8, s, "none");
    }
    if (origin) |o| {
        return std.mem.startsWith(u8, o, "http://localhost:") or
            std.mem.startsWith(u8, o, "http://127.0.0.1:") or
            std.mem.startsWith(u8, o, "http://[::1]:");
    }
    return true;
}

fn resolveProfileName(name: ?[]const u8) ?[]const u8 {
    const n = name orelse return null;
    if (std.mem.eql(u8, n, "default")) return null;
    return n;
}
