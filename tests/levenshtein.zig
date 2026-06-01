const std = @import("std");

// Test the real implementation shipped in main.zig.
const levenshtein = @import("src").levenshtein;

test "levenshtein: identical strings" {
    try std.testing.expectEqual(@as(usize, 0), levenshtein("hello", "hello"));
}

test "levenshtein: single character difference" {
    try std.testing.expectEqual(@as(usize, 1), levenshtein("hello", "hallo"));
}

test "levenshtein: one character insertion" {
    try std.testing.expectEqual(@as(usize, 1), levenshtein("hell", "hello"));
}

test "levenshtein: one character deletion" {
    try std.testing.expectEqual(@as(usize, 1), levenshtein("hello", "hell"));
}

test "levenshtein: completely different strings" {
    try std.testing.expectEqual(@as(usize, 4), levenshtein("abcd", "xyza"));
}

test "levenshtein: empty string" {
    try std.testing.expectEqual(@as(usize, 5), levenshtein("", "hello"));
    try std.testing.expectEqual(@as(usize, 5), levenshtein("hello", ""));
}

test "levenshtein: both empty" {
    try std.testing.expectEqual(@as(usize, 0), levenshtein("", ""));
}

test "levenshtein: personal vs persnl (2 char diff)" {
    try std.testing.expectEqual(@as(usize, 2), levenshtein("personal", "persnl"));
}

test "levenshtein: work vs wrk (1 char diff)" {
    try std.testing.expectEqual(@as(usize, 1), levenshtein("work", "wrk"));
}

test "levenshtein: long strings exceed buffer" {
    const long = "a" ** 64;
    try std.testing.expectEqual(@as(usize, 0), levenshtein(long, long));
}
