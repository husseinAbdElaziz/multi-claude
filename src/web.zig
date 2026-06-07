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

    // CSRF: the API mutates on-disk provider configs (API keys). Reject any
    // cross-site browser request before it can touch them.
    if (std.mem.startsWith(u8, path, "/api/") and !csrfOk(&request)) {
        try request.respond("{\"error\":\"forbidden\"}", .{
            .status = .forbidden,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
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
            if (!validProfileName(n)) {
                try request.respond("{\"error\":\"invalid profile name\"}", .{
                    .status = .bad_request,
                    .keep_alive = false,
                    .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
                });
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

fn jsonResponse(request: *std.http.Server.Request, body: []const u8) !void {
    try request.respond(body, .{
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

fn handleFetchModels(allocator: Allocator, io: Io, request: *std.http.Server.Request, query: []const u8) !void {
    const raw_url = getQueryParam(query, "url") orelse {
        return jsonResponse(request, "{\"error\":\"missing url\"}");
    };
    const raw_key = getQueryParam(query, "key");

    const url = try percentDecode(allocator, raw_url);
    defer allocator.free(url);
    const key: ?[]u8 = if (raw_key) |k| try percentDecode(allocator, k) else null;
    defer if (key) |k| allocator.free(k);

    const base = std.mem.trimEnd(u8, url, "/");
    const models_url = try std.fmt.allocPrint(allocator, "{s}/models", .{base});
    defer allocator.free(models_url);

    const uri = std.Uri.parse(models_url) catch {
        return jsonResponse(request, "{\"error\":\"invalid url\"}");
    };

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const auth: ?[]u8 = if (key) |k| (if (k.len > 0) try std.fmt.allocPrint(allocator, "Bearer {s}", .{k}) else null) else null;
    defer if (auth) |a| allocator.free(a);

    const hdrs: []const std.http.Header = if (auth) |a|
        &[_]std.http.Header{.{ .name = "authorization", .value = a }}
    else
        &[_]std.http.Header{};

    var get_req = client.request(.GET, uri, .{
        .extra_headers = hdrs,
        .keep_alive = false,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    }) catch {
        return jsonResponse(request, "{\"error\":\"connect failed\"}");
    };
    defer get_req.deinit();

    get_req.sendBodiless() catch {
        return jsonResponse(request, "{\"error\":\"request failed\"}");
    };

    var redir_buf: [4096]u8 = undefined;
    var response = get_req.receiveHead(&redir_buf) catch {
        return jsonResponse(request, "{\"error\":\"no response\"}");
    };

    if (response.head.status != .ok) {
        const msg = try std.fmt.allocPrint(allocator, "{{\"error\":\"provider returned {d}\"}}", .{@intFromEnum(response.head.status)});
        defer allocator.free(msg);
        return jsonResponse(request, msg);
    }

    var resp_out: Io.Writer.Allocating = .init(allocator);
    defer resp_out.deinit();
    var rdr_buf: [4096]u8 = undefined;
    var rdr = response.reader(&rdr_buf);
    _ = rdr.streamRemaining(&resp_out.writer) catch 0;
    const resp_body = try resp_out.toOwnedSlice();
    defer allocator.free(resp_body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp_body, .{}) catch {
        return jsonResponse(request, "{\"error\":\"invalid provider response\"}");
    };
    defer parsed.deinit();

    if (parsed.value != .object) return jsonResponse(request, "{\"error\":\"unexpected response format\"}");
    const data_v = parsed.value.object.get("data") orelse return jsonResponse(request, "{\"error\":\"no models data in response\"}");
    if (data_v != .array) return jsonResponse(request, "{\"error\":\"invalid models data\"}");

    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeByte('[');
    var first = true;
    for (data_v.array.items) |item| {
        if (item != .object) continue;
        const id_v = item.object.get("id") orelse continue;
        if (id_v != .string) continue;
        if (!first) try out.writer.writeByte(',');
        first = false;
        try out.writer.writeByte('"');
        for (id_v.string) |c| {
            if (c == '"' or c == '\\') try out.writer.writeByte('\\');
            try out.writer.writeByte(c);
        }
        try out.writer.writeByte('"');
    }
    try out.writer.writeByte(']');
    const json = try out.toOwnedSlice();
    defer allocator.free(json);
    return jsonResponse(request, json);
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

/// Allowlist a profile name to a single path segment. Rejects empty, overly
/// long, traversal (".", ".."), and anything outside [A-Za-z0-9._-] — which
/// also blocks "/" and "\" path separators and NUL. Note: query params are not
/// URL-decoded, so percent-escapes can never re-introduce a separator later.
fn validProfileName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |ch| {
        const ok = (ch >= 'A' and ch <= 'Z') or
            (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or
            ch == '.' or ch == '_' or ch == '-';
        if (!ok) return false;
    }
    return true;
}

fn resolveProfileName(name: ?[]const u8) ?[]const u8 {
    const n = name orelse return null;
    if (std.mem.eql(u8, n, "default")) return null;
    return n;
}
