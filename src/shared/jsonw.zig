/// Small JSON helpers shared by the translator and the web/proxy servers.
///
/// The translator hand-builds JSON in streaming form (it's a small fixed shape
/// and zig's json.Stringify would re-parse what we just parsed), so it needs
/// a tiny set of utilities: escape a string, read a typed field off a parsed
/// object, and re-serialize a parsed value. Those live here.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Write `s` to `w` as a JSON string literal — including the surrounding
/// double quotes — escaping the JSON-required characters (`"`, `\`, control
/// chars) and `\u` escaping everything else in 0x00–0x1F.
pub fn writeStr(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x00...0x08, 0x0b...0x0c, 0x0e...0x1f => try w.print("\\u{x:04}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Read a string field off a JSON object. Returns null if the key is missing
/// OR present but not a string (e.g. number, null, object) — the caller
/// doesn't need to know which.
pub fn getStr(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Read an integer field off a JSON object. Returns null for missing keys
/// and for any non-integer JSON value. JSON `float`s are NOT accepted here —
/// the OpenAI→Anthropic translator only needs `prompt_tokens` /
/// `completion_tokens` which the OpenAI spec defines as integers.
pub fn getInt(obj: *const std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return if (v == .integer) v.integer else null;
}

/// Re-serialize a parsed `std.json.Value` into a fresh, owned JSON string
/// using zig's built-in stringify (with default settings, no whitespace).
pub fn valueToJson(allocator: Allocator, v: std.json.Value) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, v, .{});
}
