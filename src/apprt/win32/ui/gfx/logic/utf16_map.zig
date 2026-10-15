//! UTF-8 → UTF-16 conversion and offset mapping for DirectWrite (whose text
//! positions are UTF-16 code units) without ever failing on bad input
//! (ARCHITECTURE G6: titles and status text come from terminals and agents).
//!
//! Invalid, truncated, overlong or surrogate-encoding sequences decode to
//! U+FFFD one byte at a time, consistently in every function here, so
//! lengths and offsets always agree with `encodeLossy`. std-only.
const std = @import("std");

pub const replacement: u21 = 0xFFFD;

pub const Decoded = struct {
    cp: u21,
    /// Bytes consumed (1..4).
    len: u3,
};

/// Decode the code point starting at `bytes[i]` (`i < bytes.len`).
pub fn decodeLossy(bytes: []const u8, i: usize) Decoded {
    const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return .{ .cp = replacement, .len = 1 };
    if (i + n > bytes.len) return .{ .cp = replacement, .len = 1 };
    const cp = std.unicode.utf8Decode(bytes[i .. i + n]) catch return .{ .cp = replacement, .len = 1 };
    return .{ .cp = cp, .len = n };
}

fn unitsFor(cp: u21) usize {
    return if (cp >= 0x10000) 2 else 1;
}

/// Number of code points (`decodeLossy` steps).
pub fn codepointCount(utf8: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < utf8.len) {
        i += decodeLossy(utf8, i).len;
        n += 1;
    }
    return n;
}

/// UTF-16 length of `encodeLossy(utf8)`.
pub fn utf16Len(utf8: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < utf8.len) {
        const d = decodeLossy(utf8, i);
        i += d.len;
        n += unitsFor(d.cp);
    }
    return n;
}

/// Encode into `out`; returns the written prefix, or null when `out` is too
/// small (nothing useful is written then).
pub fn encodeLossy(utf8: []const u8, out: []u16) ?[]u16 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < utf8.len) {
        const d = decodeLossy(utf8, i);
        i += d.len;
        if (d.cp >= 0x10000) {
            if (o + 2 > out.len) return null;
            const v = d.cp - 0x10000;
            out[o] = @intCast(0xD800 + (v >> 10));
            out[o + 1] = @intCast(0xDC00 + (v & 0x3FF));
            o += 2;
        } else {
            if (o + 1 > out.len) return null;
            out[o] = @intCast(d.cp);
            o += 1;
        }
    }
    return out[0..o];
}

/// Exact-size UTF-16 copy; caller frees.
pub fn encodeLossyAlloc(gpa: std.mem.Allocator, utf8: []const u8) std.mem.Allocator.Error![]u16 {
    const out = try gpa.alloc(u16, utf16Len(utf8));
    _ = encodeLossy(utf8, out).?;
    return out;
}

/// NUL-terminated UTF-16 copy (for `LPCWSTR` parameters); caller frees.
pub fn encodeLossyAllocZ(gpa: std.mem.Allocator, utf8: []const u8) std.mem.Allocator.Error![:0]u16 {
    const len = utf16Len(utf8);
    const out = try gpa.allocSentinel(u16, len, 0);
    _ = encodeLossy(utf8, out[0..len]).?;
    return out;
}

/// UTF-16 offset of byte offset `byte_index` (clamped to the end). A byte
/// in the middle of a sequence maps to the start of its code point.
pub fn utf16Offset(utf8: []const u8, byte_index: usize) usize {
    var i: usize = 0;
    var units: usize = 0;
    while (i < utf8.len) {
        const d = decodeLossy(utf8, i);
        if (i + d.len > byte_index) return units;
        i += d.len;
        units += unitsFor(d.cp);
    }
    return units;
}

/// Byte offset of UTF-16 offset `unit_index` (clamped to the end). An index
/// between the halves of a surrogate pair maps to the pair's start.
pub fn utf8Offset(utf8: []const u8, unit_index: usize) usize {
    var i: usize = 0;
    var units: usize = 0;
    while (i < utf8.len) {
        const d = decodeLossy(utf8, i);
        const u = unitsFor(d.cp);
        if (units + u > unit_index) return i;
        i += d.len;
        units += u;
    }
    return utf8.len;
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "unit: gfx: utf16 encoding of BMP, astral and invalid input" {
    var buf: [16]u16 = undefined;
    const ascii = encodeLossy("ab", &buf).?;
    try testing.expectEqualSlices(u16, &.{ 'a', 'b' }, ascii);

    // "é" (2 bytes), "€" (3 bytes), "😀" (4 bytes -> surrogate pair).
    const s = "\u{e9}\u{20ac}\u{1F600}";
    try testing.expectEqual(@as(usize, 4), utf16Len(s));
    try testing.expectEqual(@as(usize, 3), codepointCount(s));
    try testing.expectEqualSlices(u16, &.{ 0xE9, 0x20AC, 0xD83D, 0xDE00 }, encodeLossy(s, &buf).?);

    // Stray continuation byte, truncated sequence, overlong '/', encoded
    // surrogate: each bad byte becomes U+FFFD.
    const bad = "a\x80b\xE2\x82";
    try testing.expectEqualSlices(u16, &.{ 'a', 0xFFFD, 'b', 0xFFFD, 0xFFFD }, encodeLossy(bad, &buf).?);
    try testing.expectEqual(@as(usize, 5), utf16Len(bad));
    try testing.expectEqualSlices(u16, &.{ 0xFFFD, 0xFFFD }, encodeLossy("\xC0\xAF", &buf).?);
    try testing.expectEqualSlices(u16, &.{ 0xFFFD, 0xFFFD, 0xFFFD }, encodeLossy("\xED\xA0\x80", &buf).?);

    // Too-small buffer.
    var tiny: [3]u16 = undefined;
    try testing.expect(encodeLossy(s, &tiny) == null);
}

test "unit: gfx: utf16 allocating encoders" {
    const z = try encodeLossyAllocZ(testing.allocator, "x\u{1F600}");
    defer testing.allocator.free(z);
    try testing.expectEqual(@as(usize, 3), z.len);
    try testing.expectEqual(@as(u16, 0), z[z.len]);
    const a = try encodeLossyAlloc(testing.allocator, "");
    defer testing.allocator.free(a);
    try testing.expectEqual(@as(usize, 0), a.len);
}

test "unit: gfx: utf8 and utf16 offsets map both ways" {
    const s = "a\u{e9}\u{1F600}z"; // bytes: a(0) é(1,2) 😀(3..6) z(7); units: a0 é1 😀2,3 z4
    try testing.expectEqual(@as(usize, 0), utf16Offset(s, 0));
    try testing.expectEqual(@as(usize, 1), utf16Offset(s, 1));
    try testing.expectEqual(@as(usize, 1), utf16Offset(s, 2)); // inside é
    try testing.expectEqual(@as(usize, 2), utf16Offset(s, 3));
    try testing.expectEqual(@as(usize, 4), utf16Offset(s, 7));
    try testing.expectEqual(@as(usize, 5), utf16Offset(s, 8));
    try testing.expectEqual(@as(usize, 5), utf16Offset(s, 100));

    try testing.expectEqual(@as(usize, 0), utf8Offset(s, 0));
    try testing.expectEqual(@as(usize, 1), utf8Offset(s, 1));
    try testing.expectEqual(@as(usize, 3), utf8Offset(s, 2));
    try testing.expectEqual(@as(usize, 3), utf8Offset(s, 3)); // between surrogates
    try testing.expectEqual(@as(usize, 7), utf8Offset(s, 4));
    try testing.expectEqual(@as(usize, 8), utf8Offset(s, 5));
    try testing.expectEqual(@as(usize, 8), utf8Offset(s, 99));

    // Round trip at every code point boundary.
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        const back = utf8Offset(s, utf16Offset(s, i));
        try testing.expect(back <= i);
    }
}
