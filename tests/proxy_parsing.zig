const std = @import("std");
const proxy = @import("src").proxy;

test "extractModel: returns owned string for valid body" {
    const alloc = std.testing.allocator;
    const body =
        \\{"model":"claude-opus-4-8","messages":[]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const m = try proxy.extractModel(alloc, parsed);
    defer alloc.free(m);
    try std.testing.expectEqualStrings("claude-opus-4-8", m);
}

test "extractModel: returns default on unparseable body (null parsed)" {
    const alloc = std.testing.allocator;
    const m = try proxy.extractModel(alloc, null);
    defer alloc.free(m);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", m);
}

test "extractModel: returns default when model field is missing" {
    const alloc = std.testing.allocator;
    const body =
        \\{"messages":[]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const m = try proxy.extractModel(alloc, parsed);
    defer alloc.free(m);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", m);
}

test "extractModel: returns default when model is not a string" {
    const alloc = std.testing.allocator;
    const body =
        \\{"model":42}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const m = try proxy.extractModel(alloc, parsed);
    defer alloc.free(m);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", m);
}

test "streamingFromParsed: false for null" {
    try std.testing.expect(!proxy.streamingFromParsed(null));
}

test "streamingFromParsed: false for plain body without stream" {
    const alloc = std.testing.allocator;
    const body =
        \\{"model":"claude-opus-4-8"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(!proxy.streamingFromParsed(parsed));
}

test "streamingFromParsed: true for stream:true" {
    const alloc = std.testing.allocator;
    const body =
        \\{"model":"x","stream":true}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(proxy.streamingFromParsed(parsed));
}

test "streamingFromParsed: false for stream:false" {
    const alloc = std.testing.allocator;
    const body =
        \\{"model":"x","stream":false}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(!proxy.streamingFromParsed(parsed));
}

// Regression: a user message body containing the literal `"stream":true`
// must NOT be detected as a streaming request. The old substring matcher
// misclassified this; the new parsed-value lookup cannot.
test "streamingFromParsed: user content containing stream:true is not streaming" {
    const alloc = std.testing.allocator;
    const body =
        \\{"model":"x","messages":[{"role":"user","content":"set stream:true for me"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(!proxy.streamingFromParsed(parsed));
}
