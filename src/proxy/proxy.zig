/// Local HTTP proxy that routes model requests to configured providers.
///
/// Routing rule:
///   - `claude-*` models   → passthrough to api.anthropic.com (with the
///                           user's real ANTHROPIC_API_KEY swapped in for
///                           the secret the launcher injected)
///   - any other model     → look up the configured provider for that
///                           model id and forward to it, translating
///                           request/response shape as needed
///     - `anthropic_compat` → same shape as Anthropic Messages, just a
///                            different base URL
///     - `openai_compat`    → translate Anthropic Messages ↔ OpenAI Chat
///                            Completions on the way through
///
/// The proxy is the `mcc __proxy__` subcommand. It's spawned by the
/// launcher with a per-run secret in its env, and serves on a random
/// localhost port. It also implements `/v1/models` so Claude Code can
/// enumerate available models without ever talking to a real provider.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;
const Log = @import("../shared/log.zig").Log;
const providers_mod = @import("../provider/providers.zig");
const translator = @import("translator.zig");
const httpx = @import("../shared/httpx.zig");

const ANTHROPIC_API_BASE = "https://api.anthropic.com";
const ANTHROPIC_VERSION = "2023-06-01";

/// Top-level entry: load the providers config, listen on `port`, and
/// handle connections in a loop. Returns on error (the launcher will
/// notice the child died and proceed without the proxy).
pub fn run(
    allocator: Allocator,
    logger: Log,
    io: Io,
    profile_name: []const u8,
    port: u16,
    anthropic_api_key: []const u8,
    proxy_secret: []const u8,
) !void {
    var providers_cfg = providers_mod.load(allocator, profile_name) catch null;
    defer if (providers_cfg) |*c| c.deinit(allocator);

    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    var server = try net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
    defer server.deinit(io);

    logger.info("proxy listening on port {d}", .{port});

    while (true) {
        var stream = server.accept(io) catch |err| {
            logger.warn("proxy accept: {}", .{err});
            continue;
        };
        defer stream.close(io);
        handleConn(allocator, io, &stream, providers_cfg, anthropic_api_key, proxy_secret, logger) catch |err| {
            logger.warn("proxy conn: {}", .{err});
        };
    }
}

/// Header carrying the per-run gate secret. Kept separate from the auth header
/// so Claude Code's real Anthropic credential passes through untouched.
const SECRET_HEADER = "x-mcc-proxy-secret";

/// Authorize a request by checking the per-run gate secret in
/// `SECRET_HEADER`. The launcher injects this header into every Claude
/// Code request via `ANTHROPIC_CUSTOM_HEADERS`; any other local process
/// (browsers, scripts) that hits the proxy port will be missing it and
/// rejected. Returns true (open) when no secret is configured (manual
/// `mcc __proxy__` invocation for debugging).
fn requestAuthorized(req: *std.http.Server.Request, secret: []const u8) bool {
    if (secret.len == 0) return true; // not configured (e.g. manual run) → no gate
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, SECRET_HEADER) and constEql(h.value, secret)) return true;
    }
    return false;
}

/// Constant-time string equality to avoid leaking secret length / prefix
/// info through timing. Not a meaningful defense against a determined
/// local attacker but cheap and correct.
fn constEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// Handle a single HTTP connection (one or more requests, but we only
/// service one before closing — `keep_alive = false`).
///
/// Routing:
///   - GET  /v1/models               → handleModels
///   - POST /v1/messages             → handleMessages
///   - POST /v1/messages/count_tokens → handleMessages (same forward path)
///   - anything else                 → 404
fn handleConn(
    allocator: Allocator,
    io: Io,
    stream: *net.Stream,
    providers_cfg: ?providers_mod.Config,
    anthropic_api_key: []const u8,
    proxy_secret: []const u8,
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

    // Authenticate every request against the per-run secret. No CORS:
    // this proxy serves Claude Code only, never a browser, so
    // cross-origin access is denied by simply not emitting
    // Access-Control-Allow-Origin.
    if (!requestAuthorized(&req, proxy_secret)) {
        try httpx.respondError(&req, .unauthorized, "unauthorized");
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

/// Handle GET /v1/models. Synthesizes an OpenAI-style `{"data": [...]}` list:
///
///   - the three hard-coded current Claude model ids (always available via
///     the Anthropic passthrough)
///   - plus, for every configured provider entry, either the provider's
///     static model list OR the result of GET {api_url}/models when the
///     list is empty (auto-discovery, useful for LM Studio / Ollama which
///     expose whatever you've actually downloaded)
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
                const fetched = httpx.fetchModelIds(allocator, io, e.api_url, e.api_key) catch &.{};
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
    try httpx.respondJson(req, body);
}

/// Handle POST /v1/messages and /v1/messages/count_tokens. This is the
/// hot path — every Claude Code request lands here.
///
/// High-level flow:
///   1. Capture client headers (auth, anything that should pass through).
///   2. Read the request body (capped at 1 MiB).
///   3. Parse the body once for the model + streaming flag (substring
///      matching "stream" caused false positives in user content, so
///      we always go through the parsed JSON).
///   4. Route:
///        claude-*  or no provider match → Anthropic passthrough
///        other + provider match         → forward to provider,
///                                          translating shape for openai_compat
fn handleMessages(
    allocator: Allocator,
    io: Io,
    req: *std.http.Server.Request,
    path: []const u8,
    cfg: ?providers_mod.Config,
    anthropic_api_key: []const u8,
) !void {
    // Collect headers BEFORE reading body — iterateHeaders asserts
    // received_head state. We split client headers into three buckets:
    //   1. auth (authorization / x-api-key) → captured separately so we
    //      can replace it with our own credential for Anthropic
    //      passthrough, then re-inject the user's real one upstream
    //   2. low-level transport (host, content-length, connection, etc.)
    //      → dropped, std.http rebuilds them
    //   3. everything else (anthropic-version, anthropic-beta, etc.)
    //      → forwarded as-is
    // The internal x-mcc-proxy-secret is dropped from the upstream set.
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
                // The client's real Anthropic credential — capture for claude-*
                // passthrough (used when no provider key overrides it).
                client_auth_hdr = h.value;
                client_auth_name = h.name;
                continue; // auth handled separately
            }
            // Never forward the internal gate header upstream.
            if (std.ascii.eqlIgnoreCase(h.name, SECRET_HEADER)) continue;
            // Drop transport-level headers; keep everything else (anthropic-version, anthropic-beta, etc.)
            if (std.ascii.eqlIgnoreCase(h.name, "host") or
                std.ascii.eqlIgnoreCase(h.name, "content-length") or
                std.ascii.eqlIgnoreCase(h.name, "connection") or
                std.ascii.eqlIgnoreCase(h.name, "transfer-encoding")) continue;
            try passthrough_headers.append(allocator, h);
        }
    }

    // Read request body. We use the body length advertised by the
    // client (Content-Length) to allocate exactly that many bytes.
    const body_len: usize = @intCast(req.head.content_length orelse 0);
    if (body_len == 0) {
        try httpx.respondError(req, .bad_request, "empty body");
        return;
    }
    if (body_len > 1024 * 1024) {
        // Distinguish too-large from malformed so the caller can react
        // appropriately (e.g. split a long conversation).
        try httpx.respondError(req, .payload_too_large, "body too large");
        return;
    }
    var body_rbuf: [4096]u8 = undefined;
    var body_reader = req.readerExpectNone(&body_rbuf);
    const body = try body_reader.readAlloc(allocator, body_len);
    defer allocator.free(body);

    // Parse the body once. extractModel/isStreaming pull their fields out of
    // the same parse; doing it twice was both redundant and prone to
    // substring-matching user content (a message body containing the literal
    // `"stream":true` would have toggled streaming on by accident).
    const parsed_body = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch null;
    defer if (parsed_body) |p| p.deinit();

    // extractModel always returns an owned string, even on parse failure (it
    // dupes the default in that case), so the caller can safely free.
    const model = try extractModel(allocator, parsed_body);
    defer allocator.free(model);

    const is_streaming = streamingFromParsed(parsed_body);

    // Route: claude-* → Anthropic passthrough; others → configured provider
    const is_claude = std.mem.startsWith(u8, model, "claude-");
    const provider: ?*const providers_mod.ProviderEntry = if (!is_claude) blk: {
        if (cfg) |*c| break :blk c.findProvider(model);
        break :blk null;
    } else null;

    if (is_claude or provider == null) {
        // Anthropic passthrough (real Anthropic models, or requests for
        // a model we don't have a provider configured for)
        try forwardToAnthropic(allocator, io, req, path, body, anthropic_api_key, client_auth_hdr, client_auth_name, passthrough_headers.items, model, is_streaming);
    } else {
        const p = provider.?;
        // Claude Code may prepend routing prefixes (e.g. "anthropic/lmstudio/")
        // to the model id. Rewrite the body to the configured bare id before
        // forwarding; keep the original `model` for response echo so Claude Code
        // sees back the id it asked for.
        const upstream_model = p.resolveModel(model);
        const fwd_body: []const u8 = if (!std.mem.eql(u8, upstream_model, model))
            bodyWithModel(allocator, body, upstream_model) catch body
        else
            body;
        defer if (fwd_body.ptr != body.ptr) allocator.free(fwd_body);
        switch (p.provider_type) {
            .anthropic_compat => {
                const key = p.api_key orelse anthropic_api_key;
                try forwardToAnthropicCompat(allocator, io, req, p.api_url, fwd_body, key, model, is_streaming);
            },
            .openai_compat => {
                const key = p.api_key orelse "";
                try forwardToOpenAICompat(allocator, io, req, p.api_url, fwd_body, key, model, is_streaming);
            },
        }
    }
}

/// Forward a request to api.anthropic.com.
///
/// Auth decision:
///   - If `api_key` is non-empty (the launcher passed a real key), use
///     it as `x-api-key` (server-to-server API key auth).
///   - Otherwise, pass through whatever auth header the client sent
///     (typically an OAuth bearer token from claude.ai).
///
/// All other client headers (anthropic-version, anthropic-beta, custom
/// plugin headers, etc.) are forwarded as-is so behavior matches a
/// direct call to Anthropic.
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

/// Forward a request to a non-Anthropic provider that still speaks the
/// Anthropic Messages shape (OpenRouter, Anthropic-format proxies). Same
/// body, different base URL, with `Authorization: Bearer <key>` instead
/// of `x-api-key`. The anthropic-version header is set explicitly
/// because the provider may not default to the same version as
/// api.anthropic.com.
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

/// Translate a request into OpenAI Chat Completions shape, forward it,
/// and translate the response back to Anthropic shape on the way out.
/// Streaming responses are translated incrementally via
/// `translator.translateChunk` so the SSE frames stay well-formed.
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
        try httpx.respondError(req, .bad_request, "translation failed");
        return;
    };
    defer allocator.free(openai_body);

    try forwardPassthrough(allocator, io, req, url, openai_body, &.{
        .{ .name = "authorization", .value = auth },
        .{ .name = "content-type", .value = "application/json" },
    }, model, is_streaming, true);
}

/// Core HTTP forwarding logic. Handles three responsibilities that are
/// the same regardless of which upstream we're talking to:
///   1. POST the body, manually following up to 3 redirects (the std
///      client can't follow once the body has been streamed).
///   2. Decompress the response if the upstream used content-encoding
///      (gzip/br/zstd) so we can inspect / translate the body.
///   3. Stream or buffer the response back to the client, applying
///      OpenAI→Anthropic SSE translation when `do_translate` is set.
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
    var client = httpx.newClient(allocator, io);
    defer client.deinit();

    // Forward the POST, following up to 3 redirects ourselves. ngrok
    // and many gateways answer a plain-HTTP api_url with a 307 to
    // HTTPS. std.http.Client can't follow that once the body has been
    // streamed — it returns error.RedirectRequiresResend — so we
    // replay the in-memory body to the new URL each hop.
    var current_url: []const u8 = url;
    var url_buf: ?[]u8 = null;
    defer if (url_buf) |b| allocator.free(b);

    var upstream: std.http.Client.Request = undefined;
    var response: std.http.Client.Response = undefined;
    var hops: u8 = 0;
    while (true) {
        const uri = std.Uri.parse(current_url) catch {
            try httpx.respondError(req, .bad_request, "bad url");
            return;
        };
        upstream = client.request(.POST, uri, .{
            .extra_headers = headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
        }) catch {
            try httpx.respondError(req, .bad_gateway, "upstream connect failed");
            return;
        };

        upstream.transfer_encoding = .{ .content_length = body.len };
        var bw = upstream.sendBodyUnflushed(&.{}) catch {
            upstream.deinit();
            try httpx.respondError(req, .bad_gateway, "upstream send failed");
            return;
        };
        bw.writer.writeAll(body) catch {
            upstream.deinit();
            try httpx.respondError(req, .bad_gateway, "upstream write failed");
            return;
        };
        bw.end() catch {};
        if (upstream.connection) |conn| conn.flush() catch {};

        var redir_buf: [8192]u8 = undefined;
        response = upstream.receiveHead(&redir_buf) catch {
            upstream.deinit();
            try httpx.respondError(req, .bad_gateway, "upstream response failed");
            return;
        };

        if (response.head.status.class() == .redirect and hops < 3) {
            if (response.head.location) |loc| {
                const next = resolveLocation(allocator, current_url, loc) catch {
                    // Malformed redirect (e.g. relative Location on a base
                    // URL with no authority). Don't leak the 3xx to the
                    // client — surface it as a gateway error.
                    upstream.deinit();
                    try httpx.respondError(req, .bad_gateway, "bad upstream redirect");
                    return;
                };
                if (url_buf) |b| allocator.free(b);
                url_buf = next;
                current_url = next;
                hops += 1;
                upstream.deinit();
                continue;
            }
        }
        break;
    }
    defer upstream.deinit();

    const status: std.http.Status = @enumFromInt(@intFromEnum(response.head.status));

    // Build a reader that transparently decompresses if the upstream
    // used content-encoding. Some gateways gzip responses even when the
    // client didn't ask for it, and we need to see the plaintext body
    // for the translation step below.
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

        // Read in 4 KiB chunks and split on '\n'. The previous version
        // read one byte at a time, which was a syscall per byte and a
        // major perf hazard for long OpenAI→Anthropic SSE translations.
        // The line-state machine is the same: any partial line is
        // preserved in `line_buf` and prefixed onto the next chunk.
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = rdr.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            for (chunk[0..n]) |c| {
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
        try httpx.respondJsonStatus(req, status, anthropic_body);
    } else {
        try httpx.respondJsonStatus(req, status, resp_body);
    }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Resolve a redirect Location against the request URL. Absolute URLs are used
/// as-is; relative ones are joined to the original scheme+authority. Caller frees.
fn resolveLocation(allocator: Allocator, base: []const u8, loc: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, loc, "http://") or std.mem.startsWith(u8, loc, "https://"))
        return allocator.dupe(u8, loc);
    const scheme_end = std.mem.indexOf(u8, base, "://") orelse return error.BadRedirect;
    const auth_start = scheme_end + 3;
    const path_start = std.mem.indexOfScalarPos(u8, base, auth_start, '/') orelse base.len;
    const origin = base[0..path_start];
    return if (loc.len > 0 and loc[0] == '/')
        std.fmt.allocPrint(allocator, "{s}{s}", .{ origin, loc })
    else
        std.fmt.allocPrint(allocator, "{s}/{s}", .{ origin, loc });
}

/// Re-emit an Anthropic request body with the `model` field replaced.
///
/// NOTE: The `defer parsed.deinit()` is intentional and load-bearing. The
/// new `model` string is stored in the parse arena, so it is only valid
/// until the arena is deinited. `Stringify.valueAlloc` must run *before*
/// the defer fires — it copies the string into the returned owned slice,
/// which is then independent of the arena. Don't insert an early `return`
/// between the `put` and the `valueAlloc` call or hoist the defer.
pub fn bodyWithModel(allocator: Allocator, body: []const u8, new_model: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;
    try parsed.value.object.put(parsed.arena.allocator(), "model", .{ .string = new_model });
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
}

/// Always returns an owned string so the caller can safely `allocator.free`
/// the result regardless of whether the body parsed successfully. Returning
/// a mix of owned and static-literal strings here caused a latent crash
/// whenever a future caller added a `defer allocator.free(model)`.
pub fn extractModel(allocator: Allocator, parsed: ?std.json.Parsed(std.json.Value)) ![]u8 {
    const default_model = "claude-sonnet-4-6";
    const p = parsed orelse return allocator.dupe(u8, default_model);
    if (p.value != .object) return allocator.dupe(u8, default_model);
    const m = p.value.object.get("model") orelse return allocator.dupe(u8, default_model);
    if (m != .string) return allocator.dupe(u8, default_model);
    return try allocator.dupe(u8, m.string);
}

/// Read the top-level `"stream":true` boolean off an already-parsed body. The
/// old `isStreaming` did naive substring matching and would falsely trigger
/// on user message content that happened to contain the literal `"stream":true`.
pub fn streamingFromParsed(parsed: ?std.json.Parsed(std.json.Value)) bool {
    const p = parsed orelse return false;
    if (p.value != .object) return false;
    const v = p.value.object.get("stream") orelse return false;
    return v == .bool and v.bool;
}

/// Find a free local TCP port. We start at 49152 (the start of the
/// IANA dynamic/private port range) and scan upward, returning as soon
/// as a port accepts a connection. The race between this returning and
/// the proxy actually binding is small enough that a 200 ms sleep in
/// the launcher covers it in practice.
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

/// Generate the per-run gate secret. The launcher injects this as
/// `ANTHROPIC_API_KEY` (so every Claude Code request carries it
/// indirectly) and the proxy requires it via the custom
/// `x-mcc-proxy-secret` header. 24 bytes of secure randomness → 192
/// bits of entropy, more than enough for a localhost-only gate.
pub fn generateSecret(allocator: Allocator, io: Io) ![]u8 {
    var raw: [24]u8 = undefined;
    try io.randomSecure(&raw);
    return std.fmt.allocPrint(allocator, "mcc-proxy-{x}", .{&raw});
}
