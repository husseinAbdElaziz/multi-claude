const std = @import("std");
const Src = @import("src");
const providers = Src.providers;
const proxy = Src.proxy;

test "routing: prefixed model resolves to configured bare id" {
    const t = std.testing;
    var exact = [_][]u8{@constCast("cyankiwi/Qwen3.6-27B-AWQ-INT4")};
    const pe = providers.ProviderEntry{
        .name = @constCast("p"),
        .provider_type = .openai_compat,
        .api_url = @constCast("http://x/v1"),
        .api_key = null,
        .models = &exact,
    };
    try t.expect(pe.matchesModel("anthropic/lmstudio/cyankiwi/Qwen3.6-27B-AWQ-INT4"));
    try t.expectEqualStrings(
        "cyankiwi/Qwen3.6-27B-AWQ-INT4",
        pe.resolveModel("anthropic/lmstudio/cyankiwi/Qwen3.6-27B-AWQ-INT4"),
    );
}

test "routing: bodyWithModel rewrites model, preserves messages" {
    const t = std.testing;
    const alloc = t.allocator;
    const body =
        \\{"model":"anthropic/lmstudio/cyankiwi/Qwen3.6-27B-AWQ-INT4","messages":[{"role":"user","content":"hi"}],"max_tokens":5}
    ;
    const out = try proxy.bodyWithModel(alloc, body, "cyankiwi/Qwen3.6-27B-AWQ-INT4");
    defer alloc.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();
    try t.expect(parsed.value == .object);
    const m = parsed.value.object.get("model").?;
    try t.expectEqualStrings("cyankiwi/Qwen3.6-27B-AWQ-INT4", m.string);
    // messages preserved
    const msgs = parsed.value.object.get("messages").?;
    try t.expect(msgs == .array);
    try t.expectEqual(@as(usize, 1), msgs.array.items.len);
}
