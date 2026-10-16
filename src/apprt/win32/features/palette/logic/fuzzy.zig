//! Fuzzy subsequence matcher for the command palette (ADR-8.8, W2-7).
//!
//! A query token matches a haystack when its code points appear in order
//! (case-insensitive). Among all alignments the matcher picks the highest
//! scoring one with an affine-gap dynamic program:
//!
//! - every matched code point scores `score_match`, plus `bonus_case` when the
//!   case is identical;
//! - matches at word starts score a boundary bonus: after whitespace, after a
//!   kebab/snake/path/dot delimiter, after a symbol (emoji, "•"), at a camelCase
//!   hump or at a letter→digit transition; the first query code point earns
//!   that bonus twice and an extra `bonus_prefix` at haystack position 0;
//! - runs of consecutive matches keep the bonus of their first code point
//!   (at least `bonus_consecutive`);
//! - gaps between matched code points cost `penalty_gap_start` plus
//!   `penalty_gap_extension` per extra skipped code point; leading and
//!   trailing unmatched text is free.
//!
//! A query is split on whitespace into tokens that must all match (in any
//! order). A token that fails can still match with a single edit (one deleted
//! or substituted code point, or one adjacent transposition): see
//! `Matcher.matchTokenTypo`. Match ranges are byte offsets into the haystack
//! for highlighting; `rangesToUtf16` converts them for DirectWrite.
//!
//! Pure std; no allocation per call once the `Matcher` scratch has grown.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const score_match: i32 = 16;
pub const bonus_case: i32 = 1;
pub const bonus_boundary_white: i32 = 10;
pub const bonus_boundary_delimiter: i32 = 9;
pub const bonus_boundary: i32 = 8;
pub const bonus_camel: i32 = 7;
pub const bonus_consecutive: i32 = 4;
pub const bonus_prefix: i32 = 12;
pub const first_char_multiplier: i32 = 2;
pub const penalty_gap_start: i32 = -3;
pub const penalty_gap_extension: i32 = -1;
/// Subtracted from the score of a single-edit (typo) match.
pub const penalty_typo: i32 = 16;
/// Tokens shorter than this (in code points) never match with a typo.
pub const typo_min_len: usize = 3;
/// Tokens longer than this (in code points) never match with a typo.
pub const typo_max_len: usize = 32;

/// Haystack text past this many code points is not searched (G6 cap).
pub const max_haystack_cps: usize = 2048;
/// Tokens longer than this many code points never match.
pub const max_token_cps: usize = 128;

const neg: i32 = std.math.minInt(i32) / 4;
const none: u32 = std.math.maxInt(u32);

/// Half-open byte range `[start, end)` into the haystack.
pub const Range = struct {
    start: u32,
    end: u32,
};

const Class = enum { white, delimiter, symbol, lower, upper, digit };

fn isWordClass(c: Class) bool {
    return c == .lower or c == .upper or c == .digit;
}

/// Simple case folding: ASCII, Latin-1, Latin Extended-A pairs, Greek and
/// Cyrillic. Other code points fold to themselves.
pub fn foldCase(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + 32,
        0xC0...0xD6, 0xD8...0xDE => cp + 32,
        0x100...0x137, 0x14A...0x177 => cp | 1,
        0x139...0x148, 0x179...0x17E => if (cp & 1 == 1) cp + 1 else cp,
        0x391...0x3A1, 0x3A3...0x3AB => cp + 32,
        0x400...0x40F => cp + 80,
        0x410...0x42F => cp + 32,
        else => cp,
    };
}

fn classify(cp: u21) Class {
    if (cp < 0x80) return switch (@as(u8, @intCast(cp))) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C => .white,
        'a'...'z' => .lower,
        'A'...'Z' => .upper,
        '0'...'9' => .digit,
        '/', '\\', '-', '_', '.', ':', ',', ';', '|', '@', '#', '=', '+' => .delimiter,
        else => .symbol,
    };
    return switch (cp) {
        0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => .white,
        // Latin-1 punctuation, ×, ÷, general punctuation through misc symbols
        // and arrows, CJK punctuation, variation selectors, emoji planes.
        0xA1...0xBF, 0xD7, 0xF7, 0x200B...0x2027, 0x2030...0x205E, 0x2060...0x2BFF => .symbol,
        0x3001...0x303F, 0xFE00...0xFE0F, 0xFFFD, 0x1F000...0x1FAFF => .symbol,
        else => if (foldCase(cp) != cp) .upper else .lower,
    };
}

fn bonusFor(prev: ?Class, cur: Class) i32 {
    const p = prev orelse return if (cur == .white) 0 else bonus_boundary_white;
    if (isWordClass(cur)) return switch (p) {
        .white => bonus_boundary_white,
        .delimiter => bonus_boundary_delimiter,
        .symbol => bonus_boundary,
        .lower => if (cur == .upper or cur == .digit) bonus_camel else 0,
        .upper => if (cur == .digit) bonus_camel else 0,
        .digit => 0,
    };
    // A symbol (emoji, "•") that starts a word is a word start itself.
    if (cur == .symbol and p == .white) return bonus_boundary_white;
    return 0;
}

/// Decodes one code point at `s[i.*]`, advancing `i`; invalid bytes decode to
/// U+FFFD one byte at a time.
fn nextCodepoint(s: []const u8, i: *usize) u21 {
    const len = std.unicode.utf8ByteSequenceLength(s[i.*]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    if (i.* + len > s.len) {
        i.* += 1;
        return 0xFFFD;
    }
    const cp = std.unicode.utf8Decode(s[i.* .. i.* + len]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    i.* += len;
    return cp;
}

/// Iterates the whitespace-separated tokens of a query.
pub const TokenIterator = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(self: *TokenIterator) ?[]const u8 {
        while (self.pos < self.text.len and isSpaceByte(self.text[self.pos])) self.pos += 1;
        if (self.pos >= self.text.len) return null;
        const start = self.pos;
        while (self.pos < self.text.len and !isSpaceByte(self.text[self.pos])) self.pos += 1;
        return self.text[start..self.pos];
    }
};

fn isSpaceByte(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r' or b == 0x0B or b == 0x0C;
}

pub fn tokenize(query: []const u8) TokenIterator {
    return .{ .text = query };
}

/// Reusable matcher. `setHaystack` once per text, then match any number of
/// tokens against it. Not thread-safe; one per palette.
pub const Matcher = struct {
    gpa: Allocator,
    hay_orig: std.ArrayList(u21) = .empty,
    hay_fold: std.ArrayList(u21) = .empty,
    hay_bonus: std.ArrayList(i8) = .empty,
    /// Byte offset of each haystack code point, plus one trailing entry.
    hay_off: std.ArrayList(u32) = .empty,
    ndl_orig: std.ArrayList(u21) = .empty,
    ndl_fold: std.ArrayList(u21) = .empty,
    var_orig: std.ArrayList(u21) = .empty,
    var_fold: std.ArrayList(u21) = .empty,
    score_m: std.ArrayList(i32) = .empty,
    chunk_m: std.ArrayList(i8) = .empty,
    from_m: std.ArrayList(u32) = .empty,
    positions: std.ArrayList(u32) = .empty,

    pub fn init(gpa: Allocator) Matcher {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Matcher) void {
        const gpa = self.gpa;
        self.hay_orig.deinit(gpa);
        self.hay_fold.deinit(gpa);
        self.hay_bonus.deinit(gpa);
        self.hay_off.deinit(gpa);
        self.ndl_orig.deinit(gpa);
        self.ndl_fold.deinit(gpa);
        self.var_orig.deinit(gpa);
        self.var_fold.deinit(gpa);
        self.score_m.deinit(gpa);
        self.chunk_m.deinit(gpa);
        self.from_m.deinit(gpa);
        self.positions.deinit(gpa);
        self.* = undefined;
    }

    pub fn setHaystack(self: *Matcher, text: []const u8) Allocator.Error!void {
        const gpa = self.gpa;
        self.hay_orig.clearRetainingCapacity();
        self.hay_fold.clearRetainingCapacity();
        self.hay_bonus.clearRetainingCapacity();
        self.hay_off.clearRetainingCapacity();
        var prev: ?Class = null;
        var i: usize = 0;
        while (i < text.len and self.hay_orig.items.len < max_haystack_cps) {
            const start = i;
            const cp = nextCodepoint(text, &i);
            const class = classify(cp);
            try self.hay_orig.append(gpa, cp);
            try self.hay_fold.append(gpa, foldCase(cp));
            try self.hay_bonus.append(gpa, @intCast(bonusFor(prev, class)));
            try self.hay_off.append(gpa, @intCast(start));
            prev = class;
        }
        try self.hay_off.append(gpa, @intCast(i));
    }

    fn setNeedle(self: *Matcher, token: []const u8) Allocator.Error!bool {
        self.ndl_orig.clearRetainingCapacity();
        self.ndl_fold.clearRetainingCapacity();
        var i: usize = 0;
        while (i < token.len) {
            if (self.ndl_orig.items.len >= max_token_cps) return false;
            const cp = nextCodepoint(token, &i);
            try self.ndl_orig.append(self.gpa, cp);
            try self.ndl_fold.append(self.gpa, foldCase(cp));
        }
        return self.ndl_orig.items.len > 0;
    }

    /// Exact (non-typo) fuzzy match of one token. Returns the score, or null
    /// when the token is not a subsequence. When `ranges` is given, the
    /// matched byte ranges are appended (merged, ascending).
    pub fn matchToken(self: *Matcher, token: []const u8, ranges: ?*std.ArrayList(Range)) Allocator.Error!?i32 {
        if (!try self.setNeedle(token)) return null;
        const s = try self.run(self.ndl_orig.items, self.ndl_fold.items) orelse return null;
        if (ranges) |r| try self.appendRanges(r);
        return s;
    }

    /// Single-edit match of one token: tries every variant with one code point
    /// deleted (covers an extra or a mistyped character) and every adjacent
    /// transposition. A variant only counts when its first match sits on a
    /// word start and its matched span is at most three times its length.
    /// Returns the best variant score minus `penalty_typo`.
    pub fn matchTokenTypo(self: *Matcher, token: []const u8, ranges: ?*std.ArrayList(Range)) Allocator.Error!?i32 {
        if (!try self.setNeedle(token)) return null;
        const n = self.ndl_orig.items.len;
        if (n < typo_min_len or n > typo_max_len) return null;
        var best: ?i32 = null;
        var best_variant: usize = 0;
        const variant_count = n + (n - 1);
        var v: usize = 0;
        while (v < variant_count) : (v += 1) {
            try self.buildVariant(v);
            const s = try self.run(self.var_orig.items, self.var_fold.items) orelse continue;
            const pos = self.positions.items;
            if (self.hay_bonus.items[pos[0]] < bonus_boundary) continue;
            if (pos[pos.len - 1] - pos[0] + 1 > 3 * pos.len) continue;
            if (best == null or s > best.?) {
                best = s;
                best_variant = v;
            }
        }
        const b = best orelse return null;
        if (ranges) |r| {
            try self.buildVariant(best_variant);
            _ = try self.run(self.var_orig.items, self.var_fold.items);
            try self.appendRanges(r);
        }
        return b - penalty_typo;
    }

    /// Variant `v` of the needle: v < n deletes code point v; otherwise it
    /// swaps code points (v - n) and (v - n + 1).
    fn buildVariant(self: *Matcher, v: usize) Allocator.Error!void {
        const n = self.ndl_orig.items.len;
        self.var_orig.clearRetainingCapacity();
        self.var_fold.clearRetainingCapacity();
        try self.var_orig.appendSlice(self.gpa, self.ndl_orig.items);
        try self.var_fold.appendSlice(self.gpa, self.ndl_fold.items);
        if (v < n) {
            _ = self.var_orig.orderedRemove(v);
            _ = self.var_fold.orderedRemove(v);
        } else {
            const k = v - n;
            std.mem.swap(u21, &self.var_orig.items[k], &self.var_orig.items[k + 1]);
            std.mem.swap(u21, &self.var_fold.items[k], &self.var_fold.items[k + 1]);
        }
    }

    fn appendRanges(self: *Matcher, ranges: *std.ArrayList(Range)) Allocator.Error!void {
        for (self.positions.items) |p| {
            try addRange(self.gpa, ranges, .{ .start = self.hay_off.items[p], .end = self.hay_off.items[p + 1] });
        }
    }

    /// Core DP; on success fills `positions` with the matched code point
    /// indexes of the best alignment.
    fn run(self: *Matcher, orig: []const u21, fold: []const u21) Allocator.Error!?i32 {
        const n = fold.len;
        const m = self.hay_fold.items.len;
        if (n == 0 or n > m) return null;
        const hay = self.hay_fold.items;
        // Greedy prefilter: is the needle a subsequence at all?
        {
            var j: usize = 0;
            for (fold) |c| {
                while (j < m and hay[j] != c) j += 1;
                if (j == m) return null;
                j += 1;
            }
        }
        const gpa = self.gpa;
        try self.score_m.resize(gpa, n * m);
        try self.chunk_m.resize(gpa, n * m);
        try self.from_m.resize(gpa, n * m);
        const S = self.score_m.items;
        const C = self.chunk_m.items;
        const F = self.from_m.items;
        const bonus = self.hay_bonus.items;
        const hay_orig = self.hay_orig.items;

        for (0..n) |i| {
            var g: i32 = neg;
            var gk: u32 = none;
            const row = i * m;
            const prev_row = if (i > 0) (i - 1) * m else 0;
            for (0..m) |j| {
                if (i > 0 and j >= 2) {
                    if (g != neg) g += penalty_gap_extension;
                    const p = S[prev_row + j - 2];
                    if (p != neg and p + penalty_gap_start >= g) {
                        g = p + penalty_gap_start;
                        gk = @intCast(j - 2);
                    }
                }
                const idx = row + j;
                if (j < i or hay[j] != fold[i]) {
                    S[idx] = neg;
                    continue;
                }
                const b: i32 = bonus[j];
                const base = score_match + (if (hay_orig[j] == orig[i]) bonus_case else 0);
                if (i == 0) {
                    S[idx] = base + b * first_char_multiplier + (if (j == 0) bonus_prefix else 0);
                    C[idx] = @intCast(b);
                    F[idx] = none;
                    continue;
                }
                var consec: i32 = neg;
                var consec_chunk: i32 = 0;
                if (j >= 1 and S[prev_row + j - 1] != neg) {
                    const cb: i32 = C[prev_row + j - 1];
                    consec = S[prev_row + j - 1] + base + @max(b, cb, bonus_consecutive);
                    consec_chunk = if (b >= bonus_boundary) b else cb;
                }
                const gapped: i32 = if (g != neg) g + base + b else neg;
                if (consec != neg and consec >= gapped) {
                    S[idx] = consec;
                    C[idx] = @intCast(consec_chunk);
                    F[idx] = @intCast(j - 1);
                } else if (gapped != neg) {
                    S[idx] = gapped;
                    C[idx] = @intCast(b);
                    F[idx] = gk;
                } else {
                    S[idx] = neg;
                }
            }
        }

        const last = (n - 1) * m;
        var best: i32 = neg;
        var best_j: usize = 0;
        for (0..m) |j| {
            if (S[last + j] > best) {
                best = S[last + j];
                best_j = j;
            }
        }
        if (best == neg) return null;
        try self.positions.resize(gpa, n);
        var j: u32 = @intCast(best_j);
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            self.positions.items[i] = j;
            j = F[i * m + j];
        }
        return best;
    }
};

/// Inserts `r` into the sorted, non-overlapping `ranges`, merging touching or
/// overlapping neighbors.
pub fn addRange(gpa: Allocator, ranges: *std.ArrayList(Range), r: Range) Allocator.Error!void {
    if (r.end <= r.start) return;
    var i: usize = 0;
    while (i < ranges.items.len and ranges.items[i].end < r.start) i += 1;
    var merged = r;
    var j = i;
    while (j < ranges.items.len and ranges.items[j].start <= merged.end) : (j += 1) {
        merged.start = @min(merged.start, ranges.items[j].start);
        merged.end = @max(merged.end, ranges.items[j].end);
    }
    try ranges.replaceRange(gpa, i, j - i, &.{merged});
}

pub const Match = struct {
    score: i32,
    /// True when at least one token needed a single-edit (typo) match.
    typo: bool,
    ranges: []Range,

    pub fn deinit(self: *Match, gpa: Allocator) void {
        gpa.free(self.ranges);
        self.* = undefined;
    }
};

/// Matches every whitespace-separated token of `query` against `text`.
/// Returns null when the query has no tokens or any token fails (even with a
/// typo). Convenience wrapper over `Matcher`; the caller owns `ranges`.
pub fn match(gpa: Allocator, query: []const u8, text: []const u8) Allocator.Error!?Match {
    var m = Matcher.init(gpa);
    defer m.deinit();
    try m.setHaystack(text);
    var ranges: std.ArrayList(Range) = .empty;
    errdefer ranges.deinit(gpa);
    var total: i32 = 0;
    var typo = false;
    var any = false;
    var it = tokenize(query);
    while (it.next()) |tok| {
        any = true;
        if (try m.matchToken(tok, &ranges)) |s| {
            total += s;
        } else if (try m.matchTokenTypo(tok, &ranges)) |s| {
            total += s;
            typo = true;
        } else {
            ranges.deinit(gpa);
            return null;
        }
    }
    if (!any) {
        ranges.deinit(gpa);
        return null;
    }
    return .{ .score = total, .typo = typo, .ranges = try ranges.toOwnedSlice(gpa) };
}

/// Score only (no typo fallback, no ranges); null when not a match.
pub fn score(gpa: Allocator, query: []const u8, text: []const u8) Allocator.Error!?i32 {
    var m = Matcher.init(gpa);
    defer m.deinit();
    try m.setHaystack(text);
    var total: i32 = 0;
    var any = false;
    var it = tokenize(query);
    while (it.next()) |tok| {
        any = true;
        total += try m.matchToken(tok, null) orelse return null;
    }
    return if (any) total else null;
}

/// Converts byte ranges over `text` to UTF-16 code unit ranges (for
/// DirectWrite highlighting). Offsets inside a sequence round down to its
/// start. Invalid bytes count as one unit (U+FFFD).
pub fn rangesToUtf16(gpa: Allocator, text: []const u8, ranges: []const Range) Allocator.Error![]Range {
    const out = try gpa.alloc(Range, ranges.len);
    var byte: usize = 0;
    var unit: u32 = 0;
    for (ranges, out) |r, *o| {
        o.start = advanceUnits(text, &byte, &unit, r.start);
        o.end = advanceUnits(text, &byte, &unit, r.end);
    }
    return out;
}

fn advanceUnits(text: []const u8, byte: *usize, unit: *u32, target: u32) u32 {
    const t = @min(@as(usize, target), text.len);
    while (byte.* < t) {
        var i = byte.*;
        const cp = nextCodepoint(text, &i);
        if (i > t) break;
        byte.* = i;
        unit.* += if (cp >= 0x10000) 2 else 1;
    }
    return unit.*;
}

const testing = std.testing;

fn expectRanges(text: []const u8, ranges: []const Range, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, ranges.len);
    for (ranges, expected) |r, e| try testing.expectEqualStrings(e, text[r.start..r.end]);
}

test "unit: palette: fuzzy matches subsequences case-insensitively" {
    try testing.expect(try score(testing.allocator, "splt", "Split Right") != null);
    try testing.expect(try score(testing.allocator, "SPLIT", "split right") != null);
    try testing.expect(try score(testing.allocator, "tilps", "Split Right") == null);
    try testing.expect(try score(testing.allocator, "splitx", "Split") == null);
}

test "unit: palette: fuzzy empty and whitespace queries never match" {
    try testing.expect(try score(testing.allocator, "", "Split Right") == null);
    try testing.expect(try score(testing.allocator, "   \t", "Split Right") == null);
    try testing.expect(try match(testing.allocator, "", "x") == null);
    try testing.expect(try score(testing.allocator, "a", "") == null);
}

test "unit: palette: fuzzy prefers word starts and contiguity" {
    const gpa = testing.allocator;
    // Word-start match beats mid-word match.
    try testing.expect((try score(gpa, "sr", "Split Right")).? > (try score(gpa, "sr", "User Mirror")).?);
    // Contiguous beats scattered.
    try testing.expect((try score(gpa, "new", "New Window")).? > (try score(gpa, "new", "Next Edit Window")).?);
    // Prefix beats a later word start.
    try testing.expect((try score(gpa, "zoom", "Zoom In")).? > (try score(gpa, "zoom", "Toggle Zoom")).?);
    // Exact case scores a little higher.
    try testing.expect((try score(gpa, "Split", "Split")).? > (try score(gpa, "split", "Split")).?);
}

test "unit: palette: fuzzy camel, kebab, snake and path boundaries" {
    const gpa = testing.allocator;
    try testing.expect((try score(gpa, "cp", "commandPalette")).? > (try score(gpa, "cp", "scrap")).?);
    try testing.expect((try score(gpa, "fb", "feature-branch")).? > (try score(gpa, "fb", "fabric")).?);
    try testing.expect((try score(gpa, "fb", "feature_branch")).? > (try score(gpa, "fb", "offbeat")).?);
    try testing.expect((try score(gpa, "rm", "C:\\src\\readme.md")).? > (try score(gpa, "rm", "C:\\src\\farm")).?);
    try testing.expect((try score(gpa, "v2", "api.v2")).? > (try score(gpa, "v2", "av2")).?);
}

test "unit: palette: fuzzy ranges highlight the best alignment" {
    const gpa = testing.allocator;
    var m = (try match(gpa, "sr", "Split Right")).?;
    defer m.deinit(gpa);
    try expectRanges("Split Right", m.ranges, &.{ "S", "R" });

    var m2 = (try match(gpa, "right", "Split Right")).?;
    defer m2.deinit(gpa);
    try expectRanges("Split Right", m2.ranges, &.{"Right"});

    // Prefers the word-start alignment over the earliest one.
    var m3 = (try match(gpa, "wo", "New Workspace")).?;
    defer m3.deinit(gpa);
    try expectRanges("New Workspace", m3.ranges, &.{"Wo"});

    // Multiple tokens merge into sorted ranges.
    var m4 = (try match(gpa, "right split", "Split Right")).?;
    defer m4.deinit(gpa);
    try expectRanges("Split Right", m4.ranges, &.{ "Split", "Right" });
}

test "unit: palette: fuzzy tokens are an AND in any order" {
    const gpa = testing.allocator;
    try testing.expect(try score(gpa, "right split", "Split Right") != null);
    try testing.expect(try score(gpa, "split left", "Split Right") == null);
    try testing.expect(try score(gpa, "  split   right  ", "Split Right") != null);
}

test "unit: palette: fuzzy single-edit typo matches" {
    const gpa = testing.allocator;
    var m = Matcher.init(gpa);
    defer m.deinit();
    try m.setHaystack("Split Right");
    // Exact path misses these, typo path finds them.
    for ([_][]const u8{ "slpit", "spkit", "splixt", "rihgt", "xsplit" }) |tok| {
        try testing.expect(try m.matchToken(tok, null) == null);
        try testing.expect(try m.matchTokenTypo(tok, null) != null);
    }
    // Two edits or short tokens do not match.
    try testing.expect(try m.matchTokenTypo("spxqit", null) == null);
    try testing.expect(try m.matchTokenTypo("xq", null) == null);
    // A typo match scores below the corresponding exact match.
    const exact = (try m.matchToken("split", null)).?;
    const typo = (try m.matchTokenTypo("slpit", null)).?;
    try testing.expect(typo < exact);

    var full = (try match(gpa, "slpit rght", "Split Right")).?;
    defer full.deinit(gpa);
    try testing.expect(full.typo);
}

test "unit: palette: fuzzy typo variants must start on a word and stay compact" {
    const gpa = testing.allocator;
    var m = Matcher.init(gpa);
    defer m.deinit();
    // "qrst" -> deleting 'q' gives "rst", which only matches mid-word here.
    try m.setHaystack("first");
    try testing.expect(try m.matchTokenTypo("qrst", null) == null);
    // Scattered over a long haystack: span too wide.
    try m.setHaystack("a........................b........................c");
    try testing.expect(try m.matchTokenTypo("abxc", null) == null);
}

test "unit: palette: fuzzy unicode, emoji and case folding" {
    const gpa = testing.allocator;
    try testing.expect(try score(gpa, "ÉCOLE", "école") != null);
    try testing.expect(try score(gpa, "мир", "Привет Мир") != null);
    try testing.expect(try score(gpa, "ΑΒΓ", "αβγ") != null);
    var m = (try match(gpa, "🚀", "Deploy 🚀 now")).?;
    defer m.deinit(gpa);
    try expectRanges("Deploy 🚀 now", m.ranges, &.{"🚀"});
    var m2 = (try match(gpa, "мир", "Привет Мир")).?;
    defer m2.deinit(gpa);
    try expectRanges("Привет Мир", m2.ranges, &.{"Мир"});
}

test "unit: palette: fuzzy tolerates malformed utf-8" {
    const gpa = testing.allocator;
    const bad = "ab\xffcd\xe2\x82";
    var m = (try match(gpa, "cd", bad)).?;
    defer m.deinit(gpa);
    try expectRanges(bad, m.ranges, &.{"cd"});
    try testing.expect(try score(gpa, "\xff", "x") == null);
    try testing.expect(try score(gpa, "zz\xc3", bad) == null);
}

test "unit: palette: fuzzy caps huge haystacks and tokens" {
    const gpa = testing.allocator;
    const big = try gpa.alloc(u8, max_haystack_cps + 100);
    defer gpa.free(big);
    @memset(big, 'a');
    big[big.len - 1] = 'z';
    // 'z' sits past the cap and is not searched.
    try testing.expect(try score(gpa, "z", big) == null);
    try testing.expect(try score(gpa, "aaaa", big) != null);
    const long_tok = try gpa.alloc(u8, max_token_cps + 1);
    defer gpa.free(long_tok);
    @memset(long_tok, 'a');
    try testing.expect(try score(gpa, long_tok, big) == null);
    try testing.expect(try score(gpa, long_tok[0..max_token_cps], big) != null);
}

test "unit: palette: fuzzy addRange merges and sorts" {
    const gpa = testing.allocator;
    var r: std.ArrayList(Range) = .empty;
    defer r.deinit(gpa);
    try addRange(gpa, &r, .{ .start = 5, .end = 6 });
    try addRange(gpa, &r, .{ .start = 0, .end = 1 });
    try addRange(gpa, &r, .{ .start = 6, .end = 8 });
    try addRange(gpa, &r, .{ .start = 2, .end = 2 });
    try addRange(gpa, &r, .{ .start = 1, .end = 2 });
    try testing.expectEqualSlices(Range, &.{ .{ .start = 0, .end = 2 }, .{ .start = 5, .end = 8 } }, r.items);
    try addRange(gpa, &r, .{ .start = 0, .end = 10 });
    try testing.expectEqualSlices(Range, &.{.{ .start = 0, .end = 10 }}, r.items);
}

test "unit: palette: fuzzy ranges convert to utf-16 units" {
    const gpa = testing.allocator;
    const text = "é🚀ab";
    // bytes: é=0..2, 🚀=2..6, a=6, b=7
    const out = try rangesToUtf16(gpa, text, &.{ .{ .start = 2, .end = 6 }, .{ .start = 7, .end = 8 } });
    defer gpa.free(out);
    try testing.expectEqualSlices(Range, &.{ .{ .start = 1, .end = 3 }, .{ .start = 4, .end = 5 } }, out);
    const empty = try rangesToUtf16(gpa, "", &.{});
    defer gpa.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}
