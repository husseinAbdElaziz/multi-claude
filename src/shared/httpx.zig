/// Shared HTTP helpers used by the proxy (outbound) and the web UI /
/// proxy (inbound):
///   - `newClient`     — build a std.http.Client with the CA bundle pre-loaded
///   - `fetchModelIds` — call GET /v1/models on a provider and parse the
///                       `data[].id` list (used by both the proxy and the UI
///                       "fetch models" button)
///   - `respondJson*`  — canned 200 / status / error responses for our local
///                       servers
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Build a new `std.http.Client` with the system CA bundle already loaded.
///
/// Why pre-load: `std.http.Client` only loads the CA bundle the first time
/// it makes an HTTPS request. If the first request is plain HTTP and the
/// server redirects to HTTPS, the redirect's TLS handshake reads
/// `client.now` (set alongside the bundle) while it's still null and
/// panics. Pre-loading it here makes `http://` → `https://` redirects
/// safe.
///
/// Caller owns the returned client and must call `.deinit()` on it.
pub fn newClient(allocator: Allocator, io: Io) std.http.Client {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    const now = Io.Clock.real.now(io);
    client.ca_bundle.rescan(allocator, io, now) catch {};
    client.now = now;
    return client;
}

/// GET `{base_url}/models` and return the list of model ids in the response.
///
/// `api_key`, when non-empty, is sent as a `Bearer` token. An empty key is
/// the same as no key (some local servers like LM Studio accept unauth'd
/// requests). Caller owns the returned strings AND the outer slice and must
/// free each.
///
/// Returns `error.ProviderError` for non-200 responses and
/// `error.InvalidResponse` when the JSON is missing the expected
/// `{ "data": [{ "id": "..." }] }` shape.
pub fn fetchModelIds(allocator: Allocator, io: Io, base_url: []const u8, api_key: ?[]const u8) ![][]u8 {
    const base = std.mem.trimEnd(u8, base_url, "/");
    const url = try std.fmt.allocPrint(allocator, "{s}/models", .{base});
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);

    var client = newClient(allocator, io);
    defer client.deinit();

    const auth: ?[]u8 = if (api_key) |k|
        (if (k.len > 0) try std.fmt.allocPrint(allocator, "Bearer {s}", .{k}) else null)
    else
        null;
    defer if (auth) |a| allocator.free(a);

    const hdrs: []const std.http.Header = if (auth) |a|
        &[_]std.http.Header{.{ .name = "authorization", .value = a }}
    else
        &[_]std.http.Header{};

    var upstream = try client.request(.GET, uri, .{
        .extra_headers = hdrs,
        .keep_alive = false,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    });
    defer upstream.deinit();

    try upstream.sendBodiless();

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

// ─── Inbound server responses ────────────────────────────────────────────────
//
// Convenience wrappers over `std.http.Server.Request.respond` that always:
//   1. set `Content-Type: application/json`
//   2. close the connection after the response
// so callers don't have to remember either of those for every response.

const json_ct = std.http.Header{ .name = "content-type", .value = "application/json" };

/// Respond 200 OK with `body` as JSON.
pub fn respondJson(req: *std.http.Server.Request, body: []const u8) !void {
    try req.respond(body, .{ .keep_alive = false, .extra_headers = &.{json_ct} });
}

/// Respond with an explicit HTTP status and `body` as JSON.
pub fn respondJsonStatus(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try req.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = &.{json_ct} });
}

/// Respond with a status and a `{"error":"<msg>"}` JSON body.
///
/// `msg` must be a plain ASCII message with no characters that need JSON
/// escaping (no `"`, no control chars). Every call site in this codebase
/// passes a string literal that satisfies that.
pub fn respondError(req: *std.http.Server.Request, status: std.http.Status, msg: []const u8) !void {
    var buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{msg}) catch "{\"error\":\"error\"}";
    try respondJsonStatus(req, status, body);
}
