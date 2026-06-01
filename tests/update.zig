const std = @import("std");
const update = @import("src").update;

test "extractTag: parses tag_name from release JSON" {
    const json =
        \\{"url":"https://api.github.com/...","tag_name":"v0.2.0","name":"0.2.0"}
    ;
    const tag = update.extractTag(json) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("v0.2.0", tag);
}

test "extractTag: tolerates spaces around colon" {
    const json =
        \\{ "tag_name" :  "v1.4.2" }
    ;
    const tag = update.extractTag(json) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("v1.4.2", tag);
}

test "extractTag: returns null when key is absent" {
    const json =
        \\{"message":"Not Found","documentation_url":"https://docs.github.com"}
    ;
    try std.testing.expect(update.extractTag(json) == null);
}

test "extractTag: normalized version matches a same-version compare" {
    const json =
        \\{"tag_name":"v0.1.0"}
    ;
    const tag = update.extractTag(json) orelse return error.TestUnexpectedNull;
    const normalized = std.mem.trimStart(u8, tag, "v");
    try std.testing.expectEqualStrings("0.1.0", normalized);
}
