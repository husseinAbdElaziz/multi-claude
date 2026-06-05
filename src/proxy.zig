/// Local HTTP proxy that routes model requests to configured providers.
/// claude-* models → api.anthropic.com (passthrough, swap key)
/// other models → configured provider (anthropic_compat or openai_compat)
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;
const Log = @import("log.zig").Log;
const providers_mod = @import("providers.zig");
const translator = @import("translator.zig");
const config = @import("config.zig");

const ANTHROPIC_API_BASE = "https://api.anthropic.com";
const ANTHROPIC_VERSION = "2023-06-01";
const INTERNAL_TOKEN_PREFIX = "mcc-proxy-internal-";

pub fn run(
    allocator: Allocator,
    logger: Log,
    io: Io,
    profile_name: []const u8,
    port: u16,
    anthropic_api_key: []const u8,
) !void {
    var providers_cfg = providers_mod.load(allocator, profile_name) catch null;
    defer if (providers_cfg) |*c| c.deinit(allocator);

    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    var server = try net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);

    logger.info("proxy listening on port {d}", .{port});

    while (true) {
        var stream = server.accept(io) catch |err| {
            logger.warn("proxy accept: {}", .{err});
            continue;
        };
        defer stream.close(io);
        handleConn(allocator, io, &stream, providers_cfg, anthropic_api_key, logger) catch |err| {
            logger.warn("proxy conn: {}", .{err});
        };
    }
}

fn handleConn(
    allocator: Allocator,
    io: Io,
    stream: *net.Stream,
    providers_cfg: ?providers_mod.Config,
    anthropic_api_key: []const u8,
    logger: Log,
) !void {
    _ = logger;
    var rbuf: [8192]u8 = undefined;
    var wbuf: [65536]u8 = undefined;
    var nr = net.Stream.Reader.init(stream.*, io, &rbuf);
    var nw = net.Stream.Writer.init(stream.*, io, &wbuf);
    var srv = std.http.Server.init(&nr.interface, &nw.interface);
    var req = srv.receiveHead() catch return;

    const method = req.head.method;
    const target = req.head.target;
    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..path_end];

    if (method == .OPTIONS) {
        try req.respond("", .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "access-control-allow-origin", .value = "*" },
                .{ .name = "access-control-allow-methods", .value = "GET, POST, OPTIONS" },
                .{ .name = "access-control-allow-headers", .value = "content-type, authorization, x-api-key, anthropic-version" },
            },
        });
        return;
    }

    if (method == .GET and std.mem.eql(u8, path, "/v1/models")) {
        try handleModels(allocator, io, &req, providers_cfg);
        return;
    }

    if (method == .POST and (std.mem.eql(u8, path, "/v1/messages") or
        std.mem.eql(u8, path, "/v1/messages/count_tokens")))
    {
        try handleMessages(allocator, io, &req, path, providers_cfg, anthropic_api_key);
        return;
    }

    try req.respond("not found", .{ .status = .not_found, .keep_alive = false });
}

fn handleModels(allocator: Allocator, io: Io, req: *std.http.Server.Request, cfg: ?providers_mod.Config) !void {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\"object\":\"list\",\"data\":[");
    var first = true;

    // Standard Claude models always available
    const claude_models = [_][]const u8{
        "claude-opus-4-8",
        "claude-sonnet-4-6",
        "claude-haiku-4-5",
    };
    for (claude_models) |m| {
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("{{\"id\":\"{s}\",\"object\":\"model\",\"owned_by\":\"anthropic\"}}", .{m});
    }

    if (cfg) |c| {
        for (c.entries) |e| {
            // Empty models list or sole "*" → auto-discover from provider
            const auto_discover = e.models.len == 0 or
                (e.models.len == 1 and std.mem.eql(u8, e.models[0], "*"));

            if (auto_discover) {
                const fetched = fetchProviderModels(allocator, io, e.api_url, e.api_key);
                defer {
                    for (fetched) |m| allocator.free(m);
                    allocator.free(fetched);
                }
                for (fetched) |m| {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try w.print("{{\"id\":\"{s}\",\"object\":\"model\",\"owned_by\":\"{s}\"}}", .{ m, e.name });
                }
            } else {
                for (e.models) |m| {
                    if (std.mem.eql(u8, m, "*")) continue;
                    if (!first) try w.writeByte(',');
                    first = false;
                    try w.print("{{\"id\":\"{s}\",\"object\":\"model\",\"owned_by\":\"{s}\"}}", .{ m, e.name });
                }
            }
        }
    }

    try w.writeAll("]}");
    const body = try out.toOwnedSlice();
    defer allocator.free(body);
    try req.respond(body, .{
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

/// Fetch model IDs from a provider's /models endpoint. Never fails — returns empty on any error.
/// Caller frees each string and the slice itself.
fn fetchProviderModels(allocator: Allocator, io: Io, api_url: []const u8, api_key: ?[]u8) [][]u8 {
    return fetchProviderModelsInner(allocator, io, api_url, api_key) catch &.{};
}

fn fetchProviderModelsInner(allocator: Allocator, io: Io, api_url: []const u8, api_key: ?[]u8) ![][]u8 {
    const base = std.mem.trimEnd(u8, api_url, "/");
    const url = try std.fmt.allocPrint(allocator, "{s}/models", .{base});
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const auth: ?[]u8 = if (api_key) |k| try std.fmt.allocPrint(allocator, "Bearer {s}", .{k}) else null;
    defer if (auth) |a| allocator.free(a);

    const hdrs: []const std.http.Header = if (auth) |a|
        &[_]std.http.Header{.{ .name = "authorization", .value = a }}
    else
        &[_]std.http.Header{};

    var upstream = try client.request(.GET, uri, .{
        .extra_headers = hdrs,
        .keep_alive = false,
    });
    defer upstream.deinit();

    upstream.transfer_encoding = .{ .content_length = 0 };
    var bw = try upstream.sendBodyUnflushed(&.{});
    bw.end() catch {};
    if (upstream.connection) |conn| conn.flush() catch {};

    var redir_buf: [4096]u8 = undefined;
    var response = try upstream.receiveHead(&redir_buf);
    if (response.head.status != .ok) return error.ProviderError;

    var tbuf: [4096]u8 = undefined;
    var rdr = response.reader(&tbuf);
    var resp_out: Io.Writer.Allocating = .init(allocator);
    defer resp_out.deinit();
    _ = rdr.streamRemaining(&resp_out.writer) catch 0;
    const resp_body = try resp_out.toOwnedSlice();
    defer allocator.free(resp_body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp_body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    const data_v = parsed.value.object.get("data") orelse return error.InvalidResponse;
    if (data_v != .array) return error.InvalidResponse;

    var models: std.ArrayList([]u8) = .empty;
    errdefer {
        for (models.items) |m| allocator.free(m);
        models.deinit(allocator);
    }
    for (data_v.array.items) |item| {
        if (item != .object) continue;
        const id_v = item.object.get("id") orelse continue;
        if (id_v != .string) continue;
        try models.append(allocator, try allocator.dupe(u8, id_v.string));
    }
    return try models.toOwnedSlice(allocator);
}

fn handleMessages(
    allocator: Allocator,
    io: Io,
    req: *std.http.Server.Request,
    path: []const u8,
    cfg: ?providers_mod.Config,
    anthropic_api_key: []const u8,
) !void {
    // Collect headers BEFORE reading body — iterateHeaders asserts received_head state.
    // Gather all client headers; auth is replaced, low-level transport headers are dropped.
    var client_auth_hdr: []const u8 = "";
    var client_auth_name: []const u8 = "authorization";
    var passthrough_headers = std.ArrayList(std.http.Header).empty;
    defer passthrough_headers.deinit(allocator);
    {
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "authorization") or
                std.ascii.eqlIgnoreCase(h.name, "x-api-key"))
            {
                if (!std.mem.startsWith(u8, h.value, INTERNAL_TOKEN_PREFIX)) {
                    client_auth_hdr = h.value;
                    client_auth_name = h.name;
                }
                continue; // auth handled separately
            }
            // Drop transport-level headers; keep everything else (anthropic-version, anthropic-beta, etc.)
            if (std.ascii.eqlIgnoreCase(h.name, "host") or
                std.ascii.eqlIgnoreCase(h.name, "content-length") or
                std.ascii.eqlIgnoreCase(h.name, "connection") or
                std.ascii.eqlIgnoreCase(h.name, "transfer-encoding")) continue;
            try passthrough_headers.append(allocator, h);
        }
    }

    // Read request body
    const body_len: usize = @intCast(req.head.content_length orelse 0);
    if (body_len == 0 or body_len > 1024 * 1024) {
        try req.respond("{\"error\":\"bad body\"}", .{ .status = .bad_request, .keep_alive = false });
        return;
    }
    var body_rbuf: [4096]u8 = undefined;
    var body_reader = req.readerExpectNone(&body_rbuf);
    const body = try body_reader.readAlloc(allocator, body_len);
    defer allocator.free(body);

    // Extract model from body
    const model = extractModel(allocator, body) catch "claude-sonnet-4-6";

    const is_streaming = isStreaming(body);

    // Route: claude-* → Anthropic passthrough; others → configured provider
    const is_claude = std.mem.startsWith(u8, model, "claude-");
    const provider: ?*const providers_mod.ProviderEntry = if (!is_claude) blk: {
        if (cfg) |*c| break :blk c.findProvider(model);
        break :blk null;
    } else null;

    if (is_claude or provider == null) {
        // Anthropic passthrough
        try forwardToAnthropic(allocator, io, req, path, body, anthropic_api_key, client_auth_hdr, client_auth_name, passthrough_headers.items, model, is_streaming);
    } else {
        const p = provider.?;
        switch (p.provider_type) {
            .anthropic_compat => {
                const key = p.api_key orelse anthropic_api_key;
                try forwardToAnthropicCompat(allocator, io, req, p.api_url, body, key, model, is_streaming);
            },
            .openai_compat => {
                const key = p.api_key orelse "";
                try forwardToOpenAICompat(allocator, io, req, p.api_url, body, key, model, is_streaming);
            },
        }
    }
}

/// Forward request as-is to Anthropic.
/// If api_key is non-empty, use it as x-api-key (API key auth).
/// Otherwise forward client_auth_hdr/client_auth_name (claude.ai OAuth passthrough).
fn forwardToAnthropic(
    allocator: Allocator,
    io: Io,
    req: *std.http.Server.Request,
    path: []const u8,
    body: []const u8,
    api_key: []const u8,
    client_auth_hdr: []const u8,
    client_auth_name: []const u8,
    passthrough: []const std.http.Header,
    model: []const u8,
    is_streaming: bool,
) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ ANTHROPIC_API_BASE, path });
    defer allocator.free(url);

    const auth_name = if (api_key.len > 0) "x-api-key" else client_auth_name;
    const auth_val = if (api_key.len > 0) api_key else client_auth_hdr;

    // Build headers: auth + all passthrough headers from client (preserves anthropic-version, anthropic-beta, etc.)
    const hdrs = try allocator.alloc(std.http.Header, 1 + passthrough.len);
    defer allocator.free(hdrs);
    hdrs[0] = .{ .name = auth_name, .value = auth_val };
    @memcpy(hdrs[1..], passthrough);

    try forwardPassthrough(allocator, io, req, url, body, hdrs, model, is_streaming, false);
}

/// Forward request as-is to an Anthropic-compatible provider (OpenRouter etc.).
fn forwardToAnthropicCompat(
    allocator: Allocator,
    io: Io,
    req: *std.http.Server.Request,
    api_url: []const u8,
    body: []const u8,
    api_key: []const u8,
    model: []const u8,
    is_streaming: bool,
) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}/v1/messages", .{std.mem.trimEnd(u8, api_url, "/")});
    defer allocator.free(url);
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth);

    try forwardPassthrough(allocator, io, req, url, body, &.{
        .{ .name = "authorization", .value = auth },
        .{ .name = "anthropic-version", .value = ANTHROPIC_VERSION },
        .{ .name = "content-type", .value = "application/json" },
    }, model, is_streaming, false);
}

/// Translate to OpenAI format and forward; translate response back.
fn forwardToOpenAICompat(
    allocator: Allocator,
    io: Io,
    req: *std.http.Server.Request,
    api_url: []const u8,
    body: []const u8,
    api_key: []const u8,
    model: []const u8,
    is_streaming: bool,
) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{std.mem.trimEnd(u8, api_url, "/")});
    defer allocator.free(url);
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth);

    const openai_body = translator.anthropicToOpenAI(allocator, body) catch {
        try req.respond("{\"error\":\"translation failed\"}", .{ .status = .bad_request, .keep_alive = false });
        return;
    };
    defer allocator.free(openai_body);

    try forwardPassthrough(allocator, io, req, url, openai_body, &.{
        .{ .name = "authorization", .value = auth },
        .{ .name = "content-type", .value = "application/json" },
    }, model, is_streaming, true);
}

/// Core HTTP forwarding. translate=true means OpenAI→Anthropic response translation.
fn forwardPassthrough(
    allocator: Allocator,
    io: Io,
    req: *std.http.Server.Request,
    url: []const u8,
    body: []const u8,
    headers: []const std.http.Header,
    model: []const u8,
    is_streaming: bool,
    do_translate: bool,
) !void {
    const uri = std.Uri.parse(url) catch {
        try req.respond("{\"error\":\"bad url\"}", .{ .status = .bad_request, .keep_alive = false });
        return;
    };

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var upstream = client.request(.POST, uri, .{
        .extra_headers = headers,
        .keep_alive = false,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    }) catch {
        try req.respond("{\"error\":\"upstream connect failed\"}", .{ .status = .bad_gateway, .keep_alive = false });
        return;
    };
    defer upstream.deinit();

    upstream.transfer_encoding = .{ .content_length = body.len };
    var bw = upstream.sendBodyUnflushed(&.{}) catch {
        try req.respond("{\"error\":\"upstream send failed\"}", .{ .status = .bad_gateway, .keep_alive = false });
        return;
    };
    bw.writer.writeAll(body) catch {
        try req.respond("{\"error\":\"upstream write failed\"}", .{ .status = .bad_gateway, .keep_alive = false });
        return;
    };
    bw.end() catch {};
    if (upstream.connection) |conn| conn.flush() catch {};

    var redir_buf: [8192]u8 = undefined;
    var response = upstream.receiveHead(&redir_buf) catch {
        try req.respond("{\"error\":\"upstream response failed\"}", .{ .status = .bad_gateway, .keep_alive = false });
        return;
    };

    const status: std.http.Status = @enumFromInt(@intFromEnum(response.head.status));

    // Build a reader that transparently decompresses if the upstream used content-encoding.
    const ce = response.head.content_encoding;
    const decompress_buf_len = ce.minBufferCapacity();
    const decompress_buf = if (decompress_buf_len > 0)
        try allocator.alloc(u8, decompress_buf_len)
    else
        try allocator.alloc(u8, 0);
    defer allocator.free(decompress_buf);
    var decompress: std.http.Decompress = undefined;
    var tbuf: [8192]u8 = undefined;
    const rdr = if (decompress_buf_len > 0)
        response.readerDecompressing(&tbuf, &decompress, decompress_buf)
    else
        response.reader(&tbuf);

    if (is_streaming and !do_translate) {
        // Pure SSE passthrough
        var stream_buf: [512]u8 = undefined;
        var sbw = try req.respondStreaming(&stream_buf, .{
            .respond_options = .{
                .status = status,
                .keep_alive = false,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/event-stream" },
                    .{ .name = "cache-control", .value = "no-cache" },
                },
            },
        });
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = rdr.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            sbw.writer.writeAll(chunk[0..n]) catch break;
            sbw.flush() catch break;
        }
        sbw.end() catch {};
        return;
    }

    if (is_streaming and do_translate) {
        // OpenAI SSE → Anthropic SSE translation
        var stream_buf: [512]u8 = undefined;
        var sbw = try req.respondStreaming(&stream_buf, .{
            .respond_options = .{
                .status = status,
                .keep_alive = false,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/event-stream" },
                    .{ .name = "cache-control", .value = "no-cache" },
                },
            },
        });

        var state = translator.StreamState{};
        var line_buf: [8192]u8 = undefined;
        var line_len: usize = 0;

        // Read SSE line by line
        while (true) {
            var byte_buf: [1]u8 = undefined;
            const n = rdr.readSliceShort(&byte_buf) catch break;
            if (n == 0) break;
            const c = byte_buf[0];
            if (c == '\n') {
                const line = line_buf[0..line_len];
                line_len = 0;
                // Parse "data: ..." lines
                if (std.mem.startsWith(u8, line, "data: ")) {
                    const data = line[6..];
                    const translated = translator.translateChunk(
                        allocator, data, &state, "msg_proxy", model,
                    ) catch null;
                    if (translated) |t| {
                        defer allocator.free(t);
                        sbw.writer.writeAll(t) catch break;
                        sbw.flush() catch break;
                    }
                }
            } else if (c != '\r') {
                if (line_len < line_buf.len - 1) {
                    line_buf[line_len] = c;
                    line_len += 1;
                }
            }
        }
        sbw.end() catch {};
        return;
    }

    // Non-streaming: collect full response body
    var resp_out: Io.Writer.Allocating = .init(allocator);
    defer resp_out.deinit();
    _ = rdr.streamRemaining(&resp_out.writer) catch 0;
    const resp_body = try resp_out.toOwnedSlice();
    defer allocator.free(resp_body);

    if (do_translate and status == .ok) {
        const anthropic_body = translator.openAIToAnthropic(allocator, resp_body, model) catch resp_body;
        defer if (anthropic_body.ptr != resp_body.ptr) allocator.free(anthropic_body);
        try req.respond(anthropic_body, .{
            .status = status,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    } else {
        try req.respond(resp_body, .{
            .status = status,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn extractModel(allocator: Allocator, body: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return "claude-sonnet-4-6";
    const m = parsed.value.object.get("model") orelse return "claude-sonnet-4-6";
    if (m != .string) return "claude-sonnet-4-6";
    return try allocator.dupe(u8, m.string);
}

fn isStreaming(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "\"stream\":true") != null or
        std.mem.indexOf(u8, body, "\"stream\": true") != null;
}

/// Find a free local port by trying to listen on ports starting at 49152.
pub fn findFreePort(io: Io) !u16 {
    var port: u16 = 49152;
    while (port < 65535) : (port += 1) {
        const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
        var srv = net.IpAddress.listen(&addr, io, .{}) catch continue;
        srv.deinit(io);
        return port;
    }
    return error.NoFreePort;
}

/// Generate the internal token used between Claude Code and the proxy.
pub fn internalToken(allocator: Allocator, port: u16) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{d}", .{ INTERNAL_TOKEN_PREFIX, port });
}
