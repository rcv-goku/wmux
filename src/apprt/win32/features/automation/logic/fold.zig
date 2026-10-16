//! Locale-independent case-insensitive comparison for automation selectors
//! and `where` predicates. Folding is a fixed simple (1:1) mapping: ASCII,
//! Latin-1, Latin Extended-A, Greek and Cyrillic capitals fold to their small
//! letters; everything else compares by code point. No locale is consulted
//! (Turkish dotted/dotless i are not special). Invalid UTF-8 bytes compare
//! as themselves.

const std = @import("std");

/// Simple case fold of one code point. Every mapping keeps the UTF-8 length
/// of the code point (`endsWith` relies on it; a test checks every input).
pub fn foldCp(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + 32,
        0xC0...0xD6, 0xD8...0xDE => cp + 32,
        // Latin Extended-A: capital/small pairs (even = capital), except the
        // ranges where the pairing is odd/even.
        0x0100...0x012F, 0x0132...0x0137, 0x014A...0x0177 => if (cp % 2 == 0) cp + 1 else cp,
        0x0139...0x0148, 0x0179...0x017E => if (cp % 2 == 1) cp + 1 else cp,
        0x0178 => 0xFF,
        0x0391...0x03A1, 0x03A3...0x03AB => cp + 32,
        0x03C2 => 0x03C3, // final sigma
        0x0410...0x042F => cp + 32,
        0x0400...0x040F => cp + 80,
        else => cp,
    };
}

const Iter = struct {
    s: []const u8,
    i: usize = 0,

    /// Next folded code point, or null at the end. An invalid byte yields
    /// itself offset past the Unicode range so it never equals a real code point.
    fn next(self: *Iter) ?u21 {
        if (self.i >= self.s.len) return null;
        const b = self.s[self.i];
        if (b < 0x80) {
            self.i += 1;
            return foldCp(b);
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch {
            self.i += 1;
            return 0x110000 + @as(u21, b);
        };
        if (self.i + n <= self.s.len) {
            if (std.unicode.utf8Decode(self.s[self.i .. self.i + n])) |cp| {
                self.i += n;
                return foldCp(cp);
            } else |_| {}
        }
        self.i += 1;
        return 0x110000 + @as(u21, b);
    }
};

pub fn eql(a: []const u8, b: []const u8) bool {
    var ia: Iter = .{ .s = a };
    var ib: Iter = .{ .s = b };
    while (true) {
        const ca = ia.next();
        const cb = ib.next();
        if (ca == null or cb == null) return ca == null and cb == null;
        if (ca.? != cb.?) return false;
    }
}

/// True when `hay` starts with `needle` (both folded). Returns the byte
/// length of the matched prefix of `hay` through `len`.
fn prefixLen(hay: []const u8, needle: []const u8) ?usize {
    var ih: Iter = .{ .s = hay };
    var in: Iter = .{ .s = needle };
    while (in.next()) |cn| {
        const ch = ih.next() orelse return null;
        if (ch != cn) return null;
    }
    return ih.i;
}

pub fn startsWith(hay: []const u8, needle: []const u8) bool {
    return prefixLen(hay, needle) != null;
}

/// Linear time. `foldCp` maps every code point to one with the same UTF-8
/// length (and an invalid byte only matches itself), so a folded match
/// spans exactly as many bytes as `needle`: the suffix can only start
/// `needle.len` bytes before the end, and only on a code-point boundary.
pub fn endsWith(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    const start = hay.len - needle.len;
    var i: usize = 0;
    while (i < start) i += boundaryStep(hay, i);
    if (i != start) return false;
    const n = prefixLen(hay[start..], needle) orelse return false;
    return start + n == hay.len;
}

/// Naive scan: O(len(hay) × len(needle)) in the worst case. Callers keep
/// both bounded (rule text and event payload values).
pub fn contains(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i < hay.len) {
        if (prefixLen(hay[i..], needle) != null) return true;
        i += boundaryStep(hay, i);
    }
    return false;
}

fn boundaryStep(s: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return 1;
    if (i + n > s.len) return 1;
    _ = std.unicode.utf8Decode(s[i .. i + n]) catch return 1;
    return n;
}

const testing = std.testing;

test "unit: automation: case folding is locale independent" {
    try testing.expect(eql("Triage", "tRIAGE"));
    try testing.expect(eql("", ""));
    try testing.expect(!eql("a", ""));
    try testing.expect(!eql("ab", "a"));
    try testing.expect(eql("ÉCOLE", "école"));
    try testing.expect(eql("ΣΟΦΙΑ", "σοφια"));
    try testing.expect(eql("ΟΔΟΣ", "οδος") and eql("οδος", "οδοσ"));
    try testing.expect(eql("ПРИВЕТ Ёж", "привет ёж"));
    try testing.expect(eql("Łódź", "łÓDŹ"));
    try testing.expect(eql("Ÿ", "ÿ"));
    // No Turkish special-casing; no multi-char folds.
    try testing.expect(eql("I", "i"));
    try testing.expect(!eql("İ", "i"));
    try testing.expect(!eql("ß", "ss"));
    // Invalid UTF-8 never equals valid text but equals itself.
    try testing.expect(eql("\xff", "\xff"));
    try testing.expect(!eql("\xff", "ÿ"));
    try testing.expect(!eql("\xc3", "\xc3\xa9"));
}

test "unit: automation: case-insensitive prefix, suffix and contains" {
    try testing.expect(startsWith("Workspace.Created", "workspace."));
    try testing.expect(!startsWith("work", "workspace"));
    try testing.expect(startsWith("x", ""));
    try testing.expect(endsWith("Workspace.CREATED", ".created"));
    try testing.expect(endsWith("x", ""));
    try testing.expect(endsWith("", ""));
    try testing.expect(!endsWith("", "a"));
    try testing.expect(endsWith("Grüße", "SSE") == false);
    try testing.expect(endsWith("café", "É"));
    try testing.expect(contains("Build FAILED on main", "failed on"));
    try testing.expect(contains("ÉCOLE", "col"));
    try testing.expect(contains("", ""));
    try testing.expect(!contains("", "a"));
    try testing.expect(!contains("abc", "abcd"));
    try testing.expect(contains("a\xffb", "\xffB"));
}

test "unit: automation: case folding keeps the UTF-8 length of every code point" {
    var cp: u21 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        if (cp >= 0xD800 and cp <= 0xDFFF) continue;
        const f = foldCp(cp);
        try testing.expect(f <= 0x10FFFF and !(f >= 0xD800 and f <= 0xDFFF));
        try testing.expectEqual(try std.unicode.utf8CodepointSequenceLength(cp), try std.unicode.utf8CodepointSequenceLength(f));
    }
}

/// The original boundary-by-boundary suffix search, kept as a test oracle.
fn endsWithOracle(hay: []const u8, needle: []const u8) bool {
    var i: usize = 0;
    while (i <= hay.len) {
        if (prefixLen(hay[i..], needle)) |n| {
            if (i + n == hay.len) return true;
        }
        if (i == hay.len) break;
        i += boundaryStep(hay, i);
    }
    return false;
}

test "unit: automation: case-insensitive suffix agrees with the boundary oracle" {
    // Pieces mix case, multi-byte letters, stray lead and continuation bytes.
    const pieces = [_][]const u8{ "", "a", "A", "é", "É", "\xC3", "\xA9", "ς", "Σ", "\xFF", "Ÿ", "ÿ", "日" };
    var hay_buf: [16]u8 = undefined;
    var needle_buf: [8]u8 = undefined;
    for (pieces) |h1| for (pieces) |h2| for (pieces) |h3| {
        const hay = try std.fmt.bufPrint(&hay_buf, "{s}{s}{s}", .{ h1, h2, h3 });
        for (pieces) |n1| for (pieces) |n2| {
            const needle = try std.fmt.bufPrint(&needle_buf, "{s}{s}", .{ n1, n2 });
            try testing.expectEqual(endsWithOracle(hay, needle), endsWith(hay, needle));
        };
    };
}

test "unit: automation: case-insensitive suffix is linear on huge values" {
    // A quadratic scan would compare the needle at every one of 256k offsets.
    const gpa = testing.allocator;
    const hay = try gpa.alloc(u8, 256 * 1024);
    defer gpa.free(hay);
    @memset(hay, 'a');
    const needle = try gpa.alloc(u8, 4096);
    defer gpa.free(needle);
    @memset(needle, 'A');
    needle[0] = 'b';
    try testing.expect(!endsWith(hay, needle));
    needle[0] = 'A';
    try testing.expect(endsWith(hay, needle));
    try testing.expect(endsWith(hay, hay));
}
