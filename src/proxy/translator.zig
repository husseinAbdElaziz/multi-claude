/// Translates between Anthropic Messages API and OpenAI Chat Completions API.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const jsonw = @import("../shared/jsonw.zig");

const writeStr = jsonw.writeStr;
const getStr = jsonw.getStr;
const getInt = jsonw.getInt;
const valueToJson = jsonw.valueToJson;

// ─── Request: Anthropic → OpenAI ─────────────────────────────────────────────

pub fn anthropicToOpenAI(allocator: Allocator, body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;
    const src = &parsed.value.object;

    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    try w.writeByte('{');

    // model
    if (getStr(src, "model")) |m| {
        try w.writeAll("\"model\":");
        try writeStr(w, m);
    }

    // messages (system prepended + message array)
    try w.writeAll(",\"messages\":[");
    var first = true;

    if (src.get("system")) |sys_v| {
        var sys_alloc: ?[]u8 = null;
        defer if (sys_alloc) |s| allocator.free(s);
        const sys_text: []const u8 = switch (sys_v) {
            .string => |s| s,
            .array => blk: {
                var sb: Io.Writer.Allocating = .init(allocator);
                defer sb.deinit();
                for (sys_v.array.items) |item| {
                    if (item != .object) continue;
                    if (!std.mem.eql(u8, getStr(&item.object, "type") orelse "", "text")) continue;
                    if (getStr(&item.object, "text")) |t| try sb.writer.writeAll(t);
                }
                sys_alloc = try sb.toOwnedSlice();
                break :blk sys_alloc.?;
            },
            else => "",
        };
        if (sys_text.len > 0) {
            try w.writeAll("{\"role\":\"system\",\"content\":");
            try writeStr(w, sys_text);
            try w.writeByte('}');
            first = false;
        }
    }

    if (src.get("messages")) |msgs_v| if (msgs_v == .array) {
        for (msgs_v.array.items) |msg| {
            if (msg != .object) continue;
            const role = getStr(&msg.object, "role") orelse continue;
            const cv = msg.object.get("content");

            if (std.mem.eql(u8, role, "user")) {
                // May contain tool_result blocks → emit as "tool" role messages
                if (cv) |c| if (c == .array) {
                    // Scan for tool_result blocks first
                    for (c.array.items) |blk| {
                        if (blk != .object) continue;
                        if (!std.mem.eql(u8, getStr(&blk.object, "type") orelse "", "tool_result")) continue;
                        if (!first) try w.writeByte(',');
                        first = false;
                        const tool_id = getStr(&blk.object, "tool_use_id") orelse "";
                        var result_text: []const u8 = "";
                        if (blk.object.get("content")) |rc| switch (rc) {
                            .string => |s| result_text = s,
                            .array => if (rc.array.items.len > 0) {
                                if (rc.array.items[0] == .object) {
                                    result_text = getStr(&rc.array.items[0].object, "text") orelse "";
                                }
                            },
                            else => {},
                        };
                        try w.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
                        try writeStr(w, tool_id);
                        try w.writeAll(",\"content\":");
                        try writeStr(w, result_text);
                        try w.writeByte('}');
                    }
                    // Then emit user text
                    for (c.array.items) |blk| {
                        if (blk != .object) continue;
                        if (!std.mem.eql(u8, getStr(&blk.object, "type") orelse "", "text")) continue;
                        const txt = getStr(&blk.object, "text") orelse continue;
                        if (!first) try w.writeByte(',');
                        first = false;
                        try w.writeAll("{\"role\":\"user\",\"content\":");
                        try writeStr(w, txt);
                        try w.writeByte('}');
                        break;
                    }
                    continue;
                };

                // Simple string or fallback
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll("{\"role\":\"user\",\"content\":");
                if (cv) |c| switch (c) {
                    .string => |s| try writeStr(w, s),
                    else => try w.writeAll("\"\""),
                } else try w.writeAll("\"\"");
                try w.writeByte('}');

            } else if (std.mem.eql(u8, role, "assistant")) {
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll("{\"role\":\"assistant\"");

                var text_out: Io.Writer.Allocating = .init(allocator);
                defer text_out.deinit();
                var tc_out: Io.Writer.Allocating = .init(allocator);
                defer tc_out.deinit();
                var tc_first = true;

                if (cv) |c| {
                    if (c == .string) {
                        try text_out.writer.writeAll(c.string);
                    } else if (c == .array) {
                        for (c.array.items) |blk| {
                            if (blk != .object) continue;
                            const btype = getStr(&blk.object, "type") orelse continue;
                            if (std.mem.eql(u8, btype, "text")) {
                                if (getStr(&blk.object, "text")) |t| try text_out.writer.writeAll(t);
                            } else if (std.mem.eql(u8, btype, "tool_use")) {
                                const tc_id = getStr(&blk.object, "id") orelse "call_0";
                                const tc_name = getStr(&blk.object, "name") orelse "";
                                if (!tc_first) try tc_out.writer.writeByte(',');
                                tc_first = false;
                                try tc_out.writer.writeAll("{\"id\":");
                                try writeStr(&tc_out.writer, tc_id);
                                try tc_out.writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                                try writeStr(&tc_out.writer, tc_name);
                                try tc_out.writer.writeAll(",\"arguments\":");
                                if (blk.object.get("input")) |inp| {
                                    const inp_json = try valueToJson(allocator, inp);
                                    defer allocator.free(inp_json);
                                    try writeStr(&tc_out.writer, inp_json);
                                } else {
                                    try tc_out.writer.writeAll("\"{}\"");
                                }
                                try tc_out.writer.writeAll("}}");
                            }
                        }
                    }
                }

                const text_bytes = try text_out.toOwnedSlice();
                defer allocator.free(text_bytes);
                try w.writeAll(",\"content\":");
                if (text_bytes.len > 0) {
                    try writeStr(w, text_bytes);
                } else {
                    try w.writeAll("null");
                }

                const tc_bytes = try tc_out.toOwnedSlice();
                defer allocator.free(tc_bytes);
                if (tc_bytes.len > 0) {
                    try w.writeAll(",\"tool_calls\":[");
                    try w.writeAll(tc_bytes);
                    try w.writeByte(']');
                }
                try w.writeByte('}');
            }
        }
    };
    try w.writeByte(']');

    // max_tokens
    if (src.get("max_tokens")) |v| if (v == .integer) {
        try w.print(",\"max_tokens\":{d}", .{v.integer});
    };

    // temperature
    if (src.get("temperature")) |v| switch (v) {
        .float => |f| try w.print(",\"temperature\":{d}", .{f}),
        .integer => |i| try w.print(",\"temperature\":{d}", .{i}),
        else => {},
    };

    // stream
    if (src.get("stream")) |v| if (v == .bool) {
        try w.print(",\"stream\":{s}", .{if (v.bool) "true" else "false"});
    };

    // tools
    if (src.get("tools")) |tools_v| if (tools_v == .array and tools_v.array.items.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (tools_v.array.items, 0..) |tool, ti| {
            if (tool != .object) continue;
            if (ti > 0) try w.writeByte(',');
            const name = getStr(&tool.object, "name") orelse continue;
            try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
            try writeStr(w, name);
            if (getStr(&tool.object, "description")) |d| {
                try w.writeAll(",\"description\":");
                try writeStr(w, d);
            }
            if (tool.object.get("input_schema")) |schema| {
                const s = try valueToJson(allocator, schema);
                defer allocator.free(s);
                try w.writeAll(",\"parameters\":");
                try w.writeAll(s);
            }
            try w.writeAll("}}");
        }
        try w.writeByte(']');
    };

    // tool_choice
    if (src.get("tool_choice")) |tc| if (tc == .object) {
        if (getStr(&tc.object, "type")) |t| {
            if (std.mem.eql(u8, t, "auto")) try w.writeAll(",\"tool_choice\":\"auto\"");
            if (std.mem.eql(u8, t, "any")) try w.writeAll(",\"tool_choice\":\"required\"");
            if (std.mem.eql(u8, t, "tool")) {
                if (getStr(&tc.object, "name")) |n| {
                    try w.writeAll(",\"tool_choice\":{\"type\":\"function\",\"function\":{\"name\":");
                    try writeStr(w, n);
                    try w.writeAll("}}");
                }
            }
        }
    };

    try w.writeByte('}');
    return out.toOwnedSlice();
}

// ─── Response: OpenAI → Anthropic (non-streaming) ────────────────────────────

pub fn openAIToAnthropic(allocator: Allocator, body: []const u8, model: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const src = &parsed.value.object;

    const id = getStr(src, "id") orelse "msg_000";
    const choices_v = src.get("choices") orelse return error.NoChoices;
    if (choices_v != .array or choices_v.array.items.len == 0) return error.NoChoices;
    const choice = choices_v.array.items[0];
    if (choice != .object) return error.InvalidChoice;
    const msg_v = choice.object.get("message") orelse return error.NoMessage;
    if (msg_v != .object) return error.InvalidMessage;

    const finish = getStr(&choice.object, "finish_reason") orelse "stop";
    const stop_reason = if (std.mem.eql(u8, finish, "tool_calls")) "tool_use" else "end_turn";

    const input_tok = if (src.get("usage")) |u| if (u == .object) getInt(&u.object, "prompt_tokens") orelse 0 else 0 else 0;
    const output_tok = if (src.get("usage")) |u| if (u == .object) getInt(&u.object, "completion_tokens") orelse 0 else 0 else 0;

    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\"id\":");
    try writeStr(w, id);
    try w.writeAll(",\"type\":\"message\",\"role\":\"assistant\",\"model\":");
    try writeStr(w, model);
    try w.print(",\"stop_reason\":\"{s}\",\"stop_sequence\":null", .{stop_reason});
    try w.print(",\"usage\":{{\"input_tokens\":{d},\"output_tokens\":{d}}}", .{ input_tok, output_tok });
    try w.writeAll(",\"content\":[");
    var cidx: usize = 0;

    // text content
    if (getStr(&msg_v.object, "content")) |text| if (text.len > 0) {
        try w.writeAll("{\"type\":\"text\",\"text\":");
        try writeStr(w, text);
        try w.writeByte('}');
        cidx += 1;
    };

    // tool_calls
    if (msg_v.object.get("tool_calls")) |tcs| if (tcs == .array) {
        for (tcs.array.items) |tc| {
            if (tc != .object) continue;
            if (cidx > 0) try w.writeByte(',');
            cidx += 1;
            const tc_id = getStr(&tc.object, "id") orelse "call_0";
            const func = tc.object.get("function") orelse continue;
            if (func != .object) continue;
            const tc_name = getStr(&func.object, "name") orelse "";
            const tc_args = getStr(&func.object, "arguments") orelse "{}";
            try w.writeAll("{\"type\":\"tool_use\",\"id\":");
            try writeStr(w, tc_id);
            try w.writeAll(",\"name\":");
            try writeStr(w, tc_name);
            try w.writeAll(",\"input\":");
            try w.writeAll(tc_args); // args is already a JSON object string
            try w.writeByte('}');
        }
    };

    try w.writeAll("]}");
    return out.toOwnedSlice();
}

// ─── Streaming: OpenAI SSE → Anthropic SSE ───────────────────────────────────

pub const StreamState = struct {
    sent_start: bool = false,
    sent_text_block: bool = false,
    tool_started: [16]bool = [_]bool{false} ** 16,
    output_tokens: u32 = 0,
};

/// Translate one "data: ..." line from OpenAI SSE to zero or more Anthropic SSE events.
/// Caller frees result. Returns null if chunk produces no output.
pub fn translateChunk(
    allocator: Allocator,
    data: []const u8,
    state: *StreamState,
    msg_id: []const u8,
    model: []const u8,
) !?[]u8 {
    const trimmed = std.mem.trim(u8, data, " \t\r\n");

    // [DONE] → emit message_stop sequence
    if (std.mem.eql(u8, trimmed, "[DONE]")) {
        var out: Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        if (state.sent_text_block) {
            try sseEvent(w, "content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}");
        }
        for (state.tool_started, 0..) |started, i| {
            if (!started) continue;
            const j = try std.fmt.allocPrint(allocator, "{{\"type\":\"content_block_stop\",\"index\":{d}}}", .{i + 1});
            defer allocator.free(j);
            try sseEvent(w, "content_block_stop", j);
        }
        const md = try std.fmt.allocPrint(allocator,
            "{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"end_turn\",\"stop_sequence\":null}},\"usage\":{{\"output_tokens\":{d}}}}}",
            .{state.output_tokens},
        );
        defer allocator.free(md);
        try sseEvent(w, "message_delta", md);
        try sseEvent(w, "message_stop", "{\"type\":\"message_stop\"}");
        const res = try out.toOwnedSlice();
        return if (res.len > 0) res else null;
    }

    if (trimmed.len == 0) return null;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const src = &parsed.value.object;
    const choices_v = src.get("choices") orelse return null;
    if (choices_v != .array or choices_v.array.items.len == 0) return null;
    const choice = choices_v.array.items[0];
    if (choice != .object) return null;

    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    // First chunk: emit message_start + ping
    if (!state.sent_start) {
        state.sent_start = true;
        const ms = try std.fmt.allocPrint(allocator,
            "{{\"type\":\"message_start\",\"message\":{{\"id\":\"{s}\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"{s}\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{{\"input_tokens\":0,\"output_tokens\":0}}}}}}",
            .{ msg_id, model },
        );
        defer allocator.free(ms);
        try sseEvent(w, "message_start", ms);
        try sseEvent(w, "ping", "{\"type\":\"ping\"}");
    }

    const delta_v = choice.object.get("delta") orelse return null;
    if (delta_v != .object) return null;
    const finish_v = choice.object.get("finish_reason");
    const is_done = if (finish_v) |f| f != .null else false;

    // Text delta
    if (getStr(&delta_v.object, "content")) |text| if (text.len > 0) {
        if (!state.sent_text_block) {
            state.sent_text_block = true;
            try sseEvent(w, "content_block_start",
                "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}");
        }
        var dout: Io.Writer.Allocating = .init(allocator);
        defer dout.deinit();
        const dw = &dout.writer;
        try dw.writeAll("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":");
        try writeStr(dw, text);
        try dw.writeAll("}}");
        const dj = try dout.toOwnedSlice();
        defer allocator.free(dj);
        try sseEvent(w, "content_block_delta", dj);
        state.output_tokens +|= 1;
    };

    // Tool calls delta
    if (delta_v.object.get("tool_calls")) |tcs| if (tcs == .array) {
        for (tcs.array.items) |tc| {
            if (tc != .object) continue;
            const idx_v = tc.object.get("index") orelse continue;
            const idx: usize = if (idx_v == .integer) @intCast(idx_v.integer) else continue;
            if (idx >= state.tool_started.len) continue;

            if (!state.tool_started[idx]) {
                state.tool_started[idx] = true;
                if (state.sent_text_block) {
                    try sseEvent(w, "content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}");
                    state.sent_text_block = false;
                }
                const tc_id = getStr(&tc.object, "id") orelse "call_0";
                const func = tc.object.get("function");
                const tc_name = if (func) |f| if (f == .object) getStr(&f.object, "name") orelse "" else "" else "";
                const cs = try std.fmt.allocPrint(allocator,
                    "{{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{{}}}}}}",
                    .{ idx + 1, tc_id, tc_name },
                );
                defer allocator.free(cs);
                try sseEvent(w, "content_block_start", cs);
            }

            const func = delta_v.object.get("tool_calls");
            _ = func;
            if (tc.object.get("function")) |f| if (f == .object) {
                if (getStr(&f.object, "arguments")) |args| if (args.len > 0) {
                    var dout: Io.Writer.Allocating = .init(allocator);
                    defer dout.deinit();
                    const dw = &dout.writer;
                    try dw.print("{{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":", .{idx + 1});
                    try writeStr(dw, args);
                    try dw.writeAll("}}");
                    const dj = try dout.toOwnedSlice();
                    defer allocator.free(dj);
                    try sseEvent(w, "content_block_delta", dj);
                };
            };
        }
    };

    // Finish
    if (is_done) {
        if (state.sent_text_block) {
            try sseEvent(w, "content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}");
        }
        for (state.tool_started, 0..) |started, i| {
            if (!started) continue;
            const j = try std.fmt.allocPrint(allocator,
                "{{\"type\":\"content_block_stop\",\"index\":{d}}}", .{i + 1});
            defer allocator.free(j);
            try sseEvent(w, "content_block_stop", j);
        }
        const finish = if (finish_v) |f| if (f == .string) f.string else "stop" else "stop";
        const stop_reason = if (std.mem.eql(u8, finish, "tool_calls")) "tool_use" else "end_turn";
        const md = try std.fmt.allocPrint(allocator,
            "{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\",\"stop_sequence\":null}},\"usage\":{{\"output_tokens\":{d}}}}}",
            .{ stop_reason, state.output_tokens },
        );
        defer allocator.free(md);
        try sseEvent(w, "message_delta", md);
        try sseEvent(w, "message_stop", "{\"type\":\"message_stop\"}");
    }

    const res = try out.toOwnedSlice();
    return if (res.len > 0) res else blk: {
        allocator.free(res);
        break :blk null;
    };
}

fn sseEvent(w: *Io.Writer, event: []const u8, data: []const u8) !void {
    try w.print("event: {s}\ndata: {s}\n\n", .{ event, data });
}
