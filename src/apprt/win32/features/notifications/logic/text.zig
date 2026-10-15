//! Text helpers for notification strings (G6): code-point-safe truncation and
//! sanitizing of untrusted terminal text. Local to the notifications feature
//! until `wmux_proto/utf8.zig` (W0-P1) provides `truncateUtf8`.

const std = @import("std");

/// Longest prefix of `s` that is at most `max` bytes and does not split a
/// UTF-8 sequence. Invalid bytes are treated as one-byte units.
pub fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var cut = max;
    // Back off over at most 3 continuation bytes to the start of a sequence.
    var back: usize = 0;
    while (cut > 0 and back < 3 and isContinuation(s[cut])) : (back += 1) cut -= 1;
    if (cut < max and !isContinuation(s[cut])) {
        // s[cut] starts a sequence: keep it only if it fits entirely (any
        // continuation bytes beyond its length are stray one-byte units).
        const len = std.unicode.utf8ByteSequenceLength(s[cut]) catch return s[0..max];
        if (cut + len <= max) return s[0..max];
        return s[0..cut];
    }
    return s[0..max];
}

fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// Copies `s` into a new allocation of at most `max_bytes` bytes: invalid UTF-8
/// becomes U+FFFD, C0/C1 controls and DEL are dropped (except tab and LF), and
/// the result is cut on a code-point boundary.
pub fn sanitizeAlloc(gpa: std.mem.Allocator, s: []const u8, max_bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, @min(s.len, max_bytes));
    var i: usize = 0;
    while (i < s.len) {
        var cp_buf: [4]u8 = undefined;
        var piece: []const u8 = undefined;
        var advance: usize = 1;
        const lead = s[i];
        if (std.unicode.utf8ByteSequenceLength(lead)) |len| {
            if (i + len <= s.len) {
                if (std.unicode.utf8Decode(s[i .. i + len])) |cp| {
                    advance = len;
                    if (isDroppedControl(cp)) {
                        i += advance;
                        continue;
                    }
                    piece = s[i .. i + len];
                } else |_| {
                    piece = replacement(&cp_buf);
                }
            } else {
                piece = replacement(&cp_buf);
            }
        } else |_| {
            piece = replacement(&cp_buf);
        }
        if (out.items.len + piece.len > max_bytes) break;
        try out.appendSlice(gpa, piece);
        i += advance;
    }
    return out.toOwnedSlice(gpa);
}

fn replacement(buf: *[4]u8) []const u8 {
    const n = std.unicode.utf8Encode(0xFFFD, buf) catch unreachable;
    return buf[0..n];
}

fn isDroppedControl(cp: u21) bool {
    if (cp == '\t' or cp == '\n') return false;
    return cp < 0x20 or cp == 0x7F or (cp >= 0x80 and cp <= 0x9F);
}

test "unit: notifications: truncateUtf8 keeps ascii prefix" {
    try std.testing.expectEqualStrings("hel", truncateUtf8("hello", 3));
    try std.testing.expectEqualStrings("hello", truncateUtf8("hello", 10));
    try std.testing.expectEqualStrings("", truncateUtf8("hello", 0));
    try std.testing.expectEqualStrings("", truncateUtf8("", 0));
}

test "unit: notifications: truncateUtf8 never splits a code point" {
    const s = "a\u{00E9}\u{20AC}\u{1F600}"; // 1 + 2 + 3 + 4 bytes
    try std.testing.expectEqualStrings("a", truncateUtf8(s, 2));
    try std.testing.expectEqualStrings("a\u{00E9}", truncateUtf8(s, 3));
    try std.testing.expectEqualStrings("a\u{00E9}", truncateUtf8(s, 5));
    try std.testing.expectEqualStrings("a\u{00E9}\u{20AC}", truncateUtf8(s, 6));
    try std.testing.expectEqualStrings("a\u{00E9}\u{20AC}", truncateUtf8(s, 9));
    try std.testing.expectEqualStrings(s, truncateUtf8(s, 10));
    for (0..s.len + 1) |n| {
        const t = truncateUtf8(s, n);
        try std.testing.expect(t.len <= n);
        try std.testing.expect(std.unicode.utf8ValidateSlice(t));
    }
}

test "unit: notifications: truncateUtf8 tolerates invalid bytes" {
    const s = [_]u8{ 'a', 0x80, 0x80, 0x80, 0x80, 'b' };
    try std.testing.expectEqual(@as(usize, 3), truncateUtf8(&s, 3).len);
    const lone_lead = [_]u8{ 'a', 0xF0 };
    try std.testing.expectEqual(@as(usize, 1), truncateUtf8(&lone_lead, 1).len);
}

test "unit: notifications: sanitizeAlloc replaces invalid utf8 and drops controls" {
    const gpa = std.testing.allocator;
    const out = try sanitizeAlloc(gpa, "a\x1b[31mb\x00c\td\ne\xffz\x7f\u{0085}", 1024);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("a[31mbc\td\ne\u{FFFD}z", out);
}

test "unit: notifications: sanitizeAlloc rejects surrogates and overlongs" {
    const gpa = std.testing.allocator;
    const out = try sanitizeAlloc(gpa, "\xed\xa0\x80|\xc0\xaf|\xe2\x82", 1024);
    defer gpa.free(out);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    try std.testing.expect(std.mem.indexOf(u8, out, "|") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\u{FFFD}"));
}

test "unit: notifications: sanitizeAlloc caps on code-point boundaries" {
    const gpa = std.testing.allocator;
    const big = "\u{1F600}" ** 1000;
    const out = try sanitizeAlloc(gpa, big, 1023);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 1020), out.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    const empty = try sanitizeAlloc(gpa, "", 10);
    defer gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
