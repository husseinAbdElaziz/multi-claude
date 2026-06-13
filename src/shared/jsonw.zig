/// Small JSON helpers shared by the translator and the web/proxy servers:
/// streaming string escaping plus typed reads off a parsed object.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Write `s` as a JSON string literal (quotes + escaping) to `w`.
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

/// Read a string field off a JSON object, or null if absent / not a string.
pub fn getStr(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Read an integer field off a JSON object, or null if absent / not an integer.
pub fn getInt(obj: *const std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return if (v == .integer) v.integer else null;
}

/// Serialize a parsed JSON value back to an owned string.
pub fn valueToJson(allocator: Allocator, v: std.json.Value) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, v, .{});
}
