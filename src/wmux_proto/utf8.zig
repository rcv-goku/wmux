//! UTF-8 helpers: `truncateUtf8` on code-point boundaries and checked UTF-16
//! conversion with explicit caps (G6). Zig 0.15's unchecked
//! `utf8ToUtf16Le`/`utf16LeToUtf8` must not be fed unbounded input; every
//! conversion here either allocates exactly or fails with `error.TooLong`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const replacement_character: u21 = 0xFFFD;

fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// Longest prefix of `s` that is at most `max_bytes` long and does not split
/// a UTF-8 sequence. Invalid input never panics: when the bytes around the
/// cut are not a well-formed sequence, the cut stays at `max_bytes`.
pub fn truncateUtf8(s: []const u8, max_bytes: usize) []const u8 {
    if (s.len <= max_bytes) return s;
    if (!isContinuation(s[max_bytes])) return s[0..max_bytes];
    // s[max_bytes] continues a sequence: find its lead byte (at most 3 back).
    var back: usize = 1;
    while (back <= 3 and back <= max_bytes) : (back += 1) {
        const i = max_bytes - back;
        const b = s[i];
        if (isContinuation(b)) continue;
        const need = std.unicode.utf8ByteSequenceLength(b) catch return s[0..max_bytes];
        // The sequence starting at i extends past the cut: drop it whole.
        if (i + need > max_bytes) return s[0..i];
        return s[0..max_bytes];
    }
    return s[0..max_bytes];
}

/// Heap copy of `truncateUtf8(s, max_bytes)`.
pub fn dupeTruncated(gpa: Allocator, s: []const u8, max_bytes: usize) Allocator.Error![]u8 {
    return gpa.dupe(u8, truncateUtf8(s, max_bytes));
}

/// Truncates to at most `max_bytes` and appends "…" (U+2026) when anything was
/// cut; the ellipsis counts toward the cap. Returns a heap copy.
pub fn dupeTruncatedEllipsis(gpa: Allocator, s: []const u8, max_bytes: usize) Allocator.Error![]u8 {
    if (s.len <= max_bytes) return gpa.dupe(u8, s);
    const ellipsis = "\u{2026}";
    if (max_bytes < ellipsis.len) return gpa.dupe(u8, truncateUtf8(s, max_bytes));
    const head = truncateUtf8(s, max_bytes - ellipsis.len);
    return std.mem.concat(gpa, u8, &.{ head, ellipsis });
}

pub fn isValid(s: []const u8) bool {
    return std.unicode.utf8ValidateSlice(s);
}

/// Number of code points in valid UTF-8.
pub fn codepointCount(s: []const u8) error{InvalidUtf8}!usize {
    return std.unicode.utf8CountCodepoints(s) catch error.InvalidUtf8;
}

pub const ToUtf16Error = error{ InvalidUtf8, TooLong, OutOfMemory };

/// UTF-8 → UTF-16LE, failing with `TooLong` when the result would exceed
/// `max_units` code units (terminator not counted).
pub fn utf8ToUtf16LeAlloc(gpa: Allocator, s: []const u8, max_units: usize) ToUtf16Error![]u16 {
    const n = std.unicode.calcUtf16LeLen(s) catch return error.InvalidUtf8;
    if (n > max_units) return error.TooLong;
    const out = try gpa.alloc(u16, n);
    errdefer gpa.free(out);
    const written = std.unicode.utf8ToUtf16Le(out, s) catch return error.InvalidUtf8;
    std.debug.assert(written == n);
    return out;
}

/// Same as `utf8ToUtf16LeAlloc` with a NUL terminator (for Win32 `LPCWSTR`).
/// Embedded NULs are rejected (`InvalidUtf8`) since Win32 would truncate there.
pub fn utf8ToUtf16LeAllocZ(gpa: Allocator, s: []const u8, max_units: usize) ToUtf16Error![:0]u16 {
    if (std.mem.indexOfScalar(u8, s, 0) != null) return error.InvalidUtf8;
    const n = std.unicode.calcUtf16LeLen(s) catch return error.InvalidUtf8;
    if (n > max_units) return error.TooLong;
    const out = try gpa.allocSentinel(u16, n, 0);
    errdefer gpa.free(out);
    const written = std.unicode.utf8ToUtf16Le(out, s) catch return error.InvalidUtf8;
    std.debug.assert(written == n);
    return out;
}

pub const FromUtf16Error = error{ InvalidUtf16, TooLong, OutOfMemory };

fn isHighSurrogate(u: u16) bool {
    return u >= 0xD800 and u <= 0xDBFF;
}

fn isLowSurrogate(u: u16) bool {
    return u >= 0xDC00 and u <= 0xDFFF;
}

/// Decodes the code point at `w[i.*]`, advancing `i`; unpaired surrogates
/// yield null.
fn nextUtf16(w: []const u16, i: *usize) ?u21 {
    const u = std.mem.littleToNative(u16, w[i.*]);
    i.* += 1;
    if (isHighSurrogate(u)) {
        if (i.* < w.len) {
            const lo = std.mem.littleToNative(u16, w[i.*]);
            if (isLowSurrogate(lo)) {
                i.* += 1;
                return 0x10000 + ((@as(u21, u - 0xD800) << 10) | (lo - 0xDC00));
            }
        }
        return null;
    }
    if (isLowSurrogate(u)) return null;
    return u;
}

fn utf16ToUtf8Impl(gpa: Allocator, w: []const u16, max_bytes: usize, lossy: bool) FromUtf16Error![]u8 {
    // Pass 1: exact length, so the cap is enforced before allocating.
    var len: usize = 0;
    var i: usize = 0;
    while (i < w.len) {
        const cp = nextUtf16(w, &i) orelse blk: {
            if (!lossy) return error.InvalidUtf16;
            break :blk replacement_character;
        };
        len += std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
        if (len > max_bytes) return error.TooLong;
    }
    const out = try gpa.alloc(u8, len);
    var o: usize = 0;
    i = 0;
    while (i < w.len) {
        const cp = nextUtf16(w, &i) orelse replacement_character;
        o += std.unicode.utf8Encode(cp, out[o..]) catch unreachable;
    }
    std.debug.assert(o == len);
    return out;
}

/// UTF-16LE → UTF-8, strict: unpaired surrogates fail with `InvalidUtf16`.
pub fn utf16LeToUtf8Alloc(gpa: Allocator, w: []const u16, max_bytes: usize) FromUtf16Error![]u8 {
    return utf16ToUtf8Impl(gpa, w, max_bytes, false);
}

/// UTF-16LE → UTF-8, lossy: unpaired surrogates (common in Win32 file names
/// and console input) become U+FFFD.
pub fn utf16LeToUtf8AllocLossy(gpa: Allocator, w: []const u16, max_bytes: usize) error{ TooLong, OutOfMemory }![]u8 {
    return utf16ToUtf8Impl(gpa, w, max_bytes, true) catch |err| switch (err) {
        error.InvalidUtf16 => unreachable,
        else => |e| e,
    };
}

/// Length of a NUL-terminated UTF-16 string, scanning at most `max_units`
/// units (a missing terminator fails instead of reading past the cap).
pub fn spanUtf16Z(p: [*:0]const u16, max_units: usize) error{TooLong}![]const u16 {
    var n: usize = 0;
    while (p[n] != 0) : (n += 1) {
        if (n >= max_units) return error.TooLong;
    }
    return p[0..n];
}

/// Heap copy of `s` keeping only printable text: invalid sequences become
/// U+FFFD, tabs and newlines become a space, other C0/C1 controls, DEL and
/// bidi/format controls that can spoof terminal output are dropped.
pub fn sanitizePrintableAlloc(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try appendCodepoint(gpa, &out, replacement_character);
            i += 1;
            continue;
        };
        if (i + n > s.len) {
            try appendCodepoint(gpa, &out, replacement_character);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + n]) catch {
            try appendCodepoint(gpa, &out, replacement_character);
            i += 1;
            continue;
        };
        i += n;
        switch (cp) {
            '\t', '\n', '\r' => try out.append(gpa, ' '),
            0...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F...0x9F => {},
            0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069 => {},
            else => try appendCodepoint(gpa, &out, cp),
        }
    }
    return out.toOwnedSlice(gpa);
}

fn appendCodepoint(gpa: Allocator, out: *std.ArrayList(u8), cp: u21) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
    try out.appendSlice(gpa, buf[0..n]);
}

const testing = std.testing;

test "unit: proto: utf8 truncate keeps short input" {
    try testing.expectEqualStrings("", truncateUtf8("", 0));
    try testing.expectEqualStrings("", truncateUtf8("", 10));
    try testing.expectEqualStrings("abc", truncateUtf8("abc", 3));
    try testing.expectEqualStrings("abc", truncateUtf8("abc", 100));
    try testing.expectEqualStrings("", truncateUtf8("abc", 0));
    try testing.expectEqualStrings("ab", truncateUtf8("abc", 2));
}

test "unit: proto: utf8 truncate never splits a code point" {
    const s = "a\u{e9}\u{20ac}\u{1F600}z"; // 1 + 2 + 3 + 4 + 1 bytes
    const expect = [_][]const u8{
        "",                "a",               "a",                        "a\u{e9}",
        "a\u{e9}",         "a\u{e9}",         "a\u{e9}\u{20ac}",          "a\u{e9}\u{20ac}",
        "a\u{e9}\u{20ac}", "a\u{e9}\u{20ac}", "a\u{e9}\u{20ac}\u{1F600}", s,
    };
    for (expect, 0..) |e, cap| {
        const got = truncateUtf8(s, cap);
        try testing.expectEqualStrings(e, got);
        try testing.expect(isValid(got));
    }
}

test "unit: proto: utf8 truncate exhaustive boundary property" {
    const s = "\u{1F600}x\u{10FFFF}\u{7FF}\u{800}\u{FFFF}\u{80}";
    for (0..s.len + 2) |cap| {
        const got = truncateUtf8(s, cap);
        try testing.expect(got.len <= cap);
        try testing.expect(isValid(got));
        // Maximality: the next code point would not have fit.
        if (got.len < s.len) {
            const n = try std.unicode.utf8ByteSequenceLength(s[got.len]);
            try testing.expect(got.len + n > cap);
        }
    }
}

test "unit: proto: utf8 truncate tolerates invalid input" {
    const bad = [_][]const u8{ "\x80\x80\x80\x80\x80", "ab\xff\xfe", "\xe2\x82", "a\xf0\x9f\x98", "\xc3" };
    for (bad) |s| {
        for (0..s.len + 1) |cap| {
            const got = truncateUtf8(s, cap);
            try testing.expect(got.len <= cap);
        }
    }
    try testing.expectEqualStrings("a", truncateUtf8("a\xf0\x9f\x98", 3));
}

test "unit: proto: utf8 truncate huge input" {
    const big = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(big);
    var i: usize = 0;
    while (i + 3 <= big.len) : (i += 3) @memcpy(big[i..][0..3], "\u{20ac}");
    @memset(big[i..], 'x');
    const got = truncateUtf8(big, 1000);
    try testing.expectEqual(@as(usize, 999), got.len);
    const copy = try dupeTruncated(testing.allocator, big, 65536);
    defer testing.allocator.free(copy);
    try testing.expect(isValid(copy));
}

test "unit: proto: utf8 truncate with ellipsis" {
    const gpa = testing.allocator;
    const a = try dupeTruncatedEllipsis(gpa, "hello world", 8);
    defer gpa.free(a);
    try testing.expectEqualStrings("hello\u{2026}", a);
    const b = try dupeTruncatedEllipsis(gpa, "short", 8);
    defer gpa.free(b);
    try testing.expectEqualStrings("short", b);
    const c = try dupeTruncatedEllipsis(gpa, "\u{e9}\u{e9}\u{e9}\u{e9}", 6);
    defer gpa.free(c);
    try testing.expectEqualStrings("\u{e9}\u{2026}", c);
    const d = try dupeTruncatedEllipsis(gpa, "abcdef", 2);
    defer gpa.free(d);
    try testing.expectEqualStrings("ab", d);
}

test "unit: proto: utf8 to utf16 round trip with unicode" {
    const gpa = testing.allocator;
    const s = "C:\\Users\\J\u{f6}rg\\\u{1F600}\u{4e2d}";
    const w = try utf8ToUtf16LeAlloc(gpa, s, 64);
    defer gpa.free(w);
    try testing.expectEqual(@as(usize, 17), w.len);
    const back = try utf16LeToUtf8Alloc(gpa, w, 64);
    defer gpa.free(back);
    try testing.expectEqualStrings(s, back);
}

test "unit: proto: utf8 to utf16 caps and errors" {
    const gpa = testing.allocator;
    try testing.expectError(error.TooLong, utf8ToUtf16LeAlloc(gpa, "abcd", 3));
    try testing.expectError(error.TooLong, utf8ToUtf16LeAlloc(gpa, "\u{1F600}", 1));
    const ok = try utf8ToUtf16LeAlloc(gpa, "\u{1F600}", 2);
    gpa.free(ok);
    try testing.expectError(error.InvalidUtf8, utf8ToUtf16LeAlloc(gpa, "a\xffb", 10));
    try testing.expectError(error.InvalidUtf8, utf8ToUtf16LeAlloc(gpa, "\xed\xa0\x80", 10));
    const empty = try utf8ToUtf16LeAlloc(gpa, "", 0);
    defer gpa.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "unit: proto: utf8 to utf16 nul terminated" {
    const gpa = testing.allocator;
    const z = try utf8ToUtf16LeAllocZ(gpa, "ab\u{e9}", 3);
    defer gpa.free(z);
    try testing.expectEqual(@as(usize, 3), z.len);
    try testing.expectEqual(@as(u16, 0), z[3]);
    try testing.expectError(error.TooLong, utf8ToUtf16LeAllocZ(gpa, "abcd", 3));
    try testing.expectError(error.InvalidUtf8, utf8ToUtf16LeAllocZ(gpa, "a\x00b", 10));
    const span = try spanUtf16Z(z.ptr, 10);
    try testing.expectEqual(@as(usize, 3), span.len);
    try testing.expectError(error.TooLong, spanUtf16Z(z.ptr, 2));
}

test "unit: proto: utf16 to utf8 surrogates strict and lossy" {
    const gpa = testing.allocator;
    const lone_high = [_]u16{ 'a', 0xD83D, 'b' };
    const lone_low = [_]u16{0xDE00};
    const trailing_high = [_]u16{ 'x', 0xD83D };
    try testing.expectError(error.InvalidUtf16, utf16LeToUtf8Alloc(gpa, &lone_high, 100));
    try testing.expectError(error.InvalidUtf16, utf16LeToUtf8Alloc(gpa, &lone_low, 100));
    const a = try utf16LeToUtf8AllocLossy(gpa, &lone_high, 100);
    defer gpa.free(a);
    try testing.expectEqualStrings("a\u{FFFD}b", a);
    const b = try utf16LeToUtf8AllocLossy(gpa, &trailing_high, 100);
    defer gpa.free(b);
    try testing.expectEqualStrings("x\u{FFFD}", b);
    const pair = [_]u16{ std.mem.nativeToLittle(u16, 0xD83D), std.mem.nativeToLittle(u16, 0xDE00) };
    try testing.expectError(error.TooLong, utf16LeToUtf8Alloc(gpa, &pair, 3));
    const c = try utf16LeToUtf8Alloc(gpa, &pair, 4);
    defer gpa.free(c);
    try testing.expectEqualStrings("\u{1F600}", c);
    try testing.expectError(error.TooLong, utf16LeToUtf8AllocLossy(gpa, &lone_high, 4));
}

test "unit: proto: utf8 codepoint count" {
    try testing.expectEqual(@as(usize, 0), try codepointCount(""));
    try testing.expectEqual(@as(usize, 3), try codepointCount("a\u{e9}\u{1F600}"));
    try testing.expectError(error.InvalidUtf8, codepointCount("\xff"));
}

test "unit: proto: utf8 sanitize printable" {
    const gpa = testing.allocator;
    const s = try sanitizePrintableAlloc(gpa, "ok\x1b[31mred\x07\tline\nnext\xff\u{202E}x\u{e9}\u{1F600}\x7f\u{85}");
    defer gpa.free(s);
    try testing.expectEqualStrings("ok[31mred line next\u{FFFD}x\u{e9}\u{1F600}", s);
    const e = try sanitizePrintableAlloc(gpa, "");
    defer gpa.free(e);
    try testing.expectEqualStrings("", e);
    const t = try sanitizePrintableAlloc(gpa, "a\xe2\x82");
    defer gpa.free(t);
    try testing.expectEqualStrings("a\u{FFFD}\u{FFFD}", t);
}
