//! Text styles and the `TextMeasurer` interface (ARCHITECTURE ADR-11.2:
//! row layout measures through a TextMeasurer, DirectWrite in the app and a
//! fake with fixed advances in tests).
//!
//! The enums use DirectWrite's numeric values so `ui/gfx/text.zig` maps them
//! with `@intFromEnum`. std-only: runs in `zig build test-fast`.
const std = @import("std");
const utf16_map = @import("utf16_map.zig");

/// Comma-separated family fallback lists: the first installed family wins.
/// Segoe UI Variable ships with Windows 11; Segoe UI is everywhere.
pub const ui_family = "Segoe UI Variable Text, Segoe UI";
/// Icon glyphs (ADR-11.4): Segoe Fluent Icons on Windows 11, MDL2 on 10.
pub const icon_family = "Segoe Fluent Icons, Segoe MDL2 Assets";
pub const mono_family = "Cascadia Mono, Consolas";
pub const emoji_family = "Segoe UI Emoji";

/// DWRITE_FONT_WEIGHT values.
pub const FontWeight = enum(u16) {
    thin = 100,
    extra_light = 200,
    light = 300,
    semi_light = 350,
    normal = 400,
    medium = 500,
    semi_bold = 600,
    bold = 700,
    extra_bold = 800,
    black = 900,
    extra_black = 950,
    _,
};

/// DWRITE_FONT_STYLE values.
pub const FontSlant = enum(u8) { normal = 0, oblique = 1, italic = 2 };

/// DWRITE_FONT_STRETCH values.
pub const FontStretch = enum(u8) {
    ultra_condensed = 1,
    extra_condensed = 2,
    condensed = 3,
    semi_condensed = 4,
    normal = 5,
    semi_expanded = 6,
    expanded = 7,
    extra_expanded = 8,
    ultra_expanded = 9,
};

/// DWRITE_TEXT_ALIGNMENT values (leading/trailing follow reading direction).
pub const HAlign = enum(u8) { leading = 0, trailing = 1, center = 2, justified = 3 };

/// DWRITE_PARAGRAPH_ALIGNMENT values (near, far, center).
pub const VAlign = enum(u8) { top = 0, bottom = 1, center = 2 };

pub const Wrap = enum(u8) {
    /// Single line per paragraph; overflow is trimmed (see `Trim`).
    none,
    /// Break at word boundaries.
    word,
    /// Break between any characters (paths, URLs).
    character,
};

pub const Trim = enum(u8) {
    none,
    /// Trim at a character boundary.
    character,
    /// Trim at a word boundary.
    word,
};

pub const TextStyle = struct {
    /// Comma-separated fallback list; see `families`.
    family: []const u8 = ui_family,
    /// Font size in layout units (DIPs by default).
    size: f32 = 12,
    weight: FontWeight = .normal,
    slant: FontSlant = .normal,
    stretch: FontStretch = .normal,
    h_align: HAlign = .leading,
    v_align: VAlign = .top,
    wrap: Wrap = .none,
    trim: Trim = .character,
    /// Draw "…" where text is trimmed.
    ellipsis: bool = true,
    /// Trimming keeps the text after the last `trim_delimiter_count`
    /// occurrences of this code point visible (e.g. '\\' keeps a path's file
    /// name: "C:\Users\…\main.zig"); 0 = trim at the end.
    trim_delimiter: u21 = 0,
    trim_delimiter_count: u8 = 1,
    underline: bool = false,
    strikethrough: bool = false,
    /// Maximum visible lines (wrapped lines and explicit line breaks); 0 =
    /// only the box height limits.
    max_lines: u16 = 0,
    /// Uniform line height in layout units; 0 = the font's natural spacing.
    line_height: f32 = 0,
    /// BCP-47 locale for shaping and line breaking.
    locale: []const u8 = "en-us",

    /// Hash of the font identity (what a DirectWrite text format caches).
    pub fn fontHash(self: *const TextStyle) u64 {
        var h = std.hash.Wyhash.init(0x6766_7874); // "gfxt"
        h.update(self.family);
        h.update(&.{0});
        h.update(self.locale);
        h.update(std.mem.asBytes(&self.size));
        h.update(std.mem.asBytes(&@intFromEnum(self.weight)));
        h.update(&.{ @intFromEnum(self.slant), @intFromEnum(self.stretch) });
        return h.final();
    }

    /// Hash of everything that affects layout (font identity + paragraph).
    pub fn layoutHash(self: *const TextStyle) u64 {
        var h = std.hash.Wyhash.init(self.fontHash());
        h.update(&self.paragraphKey());
        return h.final();
    }

    /// Bytes of every paragraph-level setting (alignment, wrapping,
    /// trimming, decorations, line limits), for exact cache keys.
    pub fn paragraphKey(self: *const TextStyle) [16]u8 {
        var out: [16]u8 = undefined;
        out[0] = @intFromEnum(self.h_align);
        out[1] = @intFromEnum(self.v_align);
        out[2] = @intFromEnum(self.wrap);
        out[3] = @intFromEnum(self.trim);
        out[4] = @as(u8, @intFromBool(self.ellipsis)) | (@as(u8, @intFromBool(self.underline)) << 1) | (@as(u8, @intFromBool(self.strikethrough)) << 2);
        out[5] = self.trim_delimiter_count;
        std.mem.writeInt(u16, out[6..8], self.max_lines, .little);
        std.mem.writeInt(u32, out[8..12], @bitCast(self.line_height), .little);
        std.mem.writeInt(u32, out[12..16], self.trim_delimiter, .little);
        return out;
    }
};

/// Iterator over a comma-separated family list ("A, B"), trimming spaces
/// and skipping empty entries.
pub const FamilyIterator = struct {
    rest: []const u8,

    pub fn next(self: *FamilyIterator) ?[]const u8 {
        while (self.rest.len > 0) {
            const comma = std.mem.indexOfScalar(u8, self.rest, ',') orelse self.rest.len;
            const item = std.mem.trim(u8, self.rest[0..comma], " \t");
            self.rest = if (comma < self.rest.len) self.rest[comma + 1 ..] else self.rest[self.rest.len..];
            if (item.len > 0) return item;
        }
        return null;
    }
};

pub fn families(list: []const u8) FamilyIterator {
    return .{ .rest = list };
}

pub const TextExtent = struct {
    /// Width of the laid-out (possibly trimmed) text.
    width: f32 = 0,
    height: f32 = 0,
    /// Distance from the top of the first line to its baseline.
    baseline: f32 = 0,
    /// Visible lines.
    line_count: u32 = 0,
    /// Text was trimmed or lines were dropped (show a tooltip).
    truncated: bool = false,
};

/// Measures text for layout code that must stay free of DirectWrite.
pub const TextMeasurer = struct {
    ctx: *anyopaque,
    measure_fn: *const fn (ctx: *anyopaque, text: []const u8, style: *const TextStyle, max_width: f32) TextExtent,

    /// Extent of `text` laid out in `style` within `max_width` (use
    /// `std.math.inf(f32)` for unconstrained; zero, negative or NaN leave no
    /// room, so the text is truncated). Never fails: implementations fall
    /// back to an estimate.
    pub fn measure(self: TextMeasurer, text: []const u8, style: *const TextStyle, max_width: f32) TextExtent {
        return self.measure_fn(self.ctx, text, style, max_width);
    }
};

/// Deterministic measurer for pure tests: every code point advances
/// `size * advance_em`, lines are `size * line_em` tall (or the style's
/// `line_height`), spaces are break opportunities.
pub const FakeMeasurer = struct {
    advance_em: f32 = 0.5,
    line_em: f32 = 1.25,
    ascent_em: f32 = 1.0,

    pub fn measurer(self: *FakeMeasurer) TextMeasurer {
        return .{ .ctx = self, .measure_fn = measureErased };
    }

    fn measureErased(ctx: *anyopaque, text: []const u8, style: *const TextStyle, max_width: f32) TextExtent {
        const self: *FakeMeasurer = @ptrCast(@alignCast(ctx));
        return self.measure(text, style, max_width);
    }

    pub fn measure(self: *const FakeMeasurer, text: []const u8, style: *const TextStyle, max_width: f32) TextExtent {
        const adv = style.size * self.advance_em;
        const line_h = if (style.line_height > 0 and std.math.isFinite(style.line_height)) style.line_height else style.size * self.line_em;
        // Same clamping as the DirectWrite measurer: no room at all.
        const max_w: f32 = if (std.math.isNan(max_width) or max_width < 0) 0 else max_width;

        var lines: u32 = 0;
        var widest: f32 = 0;
        var truncated = false;
        var paragraphs = std.mem.splitScalar(u8, text, '\n');
        while (paragraphs.next()) |para| {
            const p = self.layoutParagraph(para, adv, max_w, style.wrap);
            lines += p.lines;
            widest = @max(widest, p.width);
            truncated = truncated or p.overflow;
        }
        if (style.max_lines > 0 and lines > style.max_lines) {
            lines = style.max_lines;
            truncated = true;
        }
        if (truncated and style.trim != .none) widest = @min(widest, max_w);
        return .{
            .width = widest,
            .height = @as(f32, @floatFromInt(lines)) * line_h,
            .baseline = @min(line_h, style.size * self.ascent_em),
            .line_count = lines,
            .truncated = truncated,
        };
    }

    const Para = struct { lines: u32, width: f32, overflow: bool };

    fn layoutParagraph(self: *const FakeMeasurer, para: []const u8, adv: f32, max_w: f32, wrap: Wrap) Para {
        _ = self;
        const n: f32 = @floatFromInt(utf16_map.codepointCount(para));
        switch (wrap) {
            .none => {
                const w = n * adv;
                return .{ .lines = 1, .width = w, .overflow = w > max_w };
            },
            .character => {
                const per_line = @max(@floor(max_w / adv), 1);
                if (n == 0) return .{ .lines = 1, .width = 0, .overflow = false };
                const lines = @ceil(n / per_line);
                const w = @min(n, per_line) * adv;
                // A line narrower than one character still holds one.
                return .{ .lines = @intFromFloat(lines), .width = w, .overflow = w > max_w };
            },
            .word => {
                var lines: u32 = 1;
                var cur: f32 = 0;
                var widest: f32 = 0;
                var words = std.mem.splitScalar(u8, para, ' ');
                while (words.next()) |word| {
                    var ww = @as(f32, @floatFromInt(utf16_map.codepointCount(word))) * adv;
                    const needed = if (cur == 0) ww else cur + adv + ww;
                    if (needed <= max_w) {
                        cur = needed;
                        continue;
                    }
                    if (cur > 0) {
                        widest = @max(widest, cur);
                        lines += 1;
                        cur = 0;
                    }
                    // A word longer than the line breaks by characters (at
                    // least one per line, even when the line is narrower).
                    const chunk = @max(@floor(max_w / adv), 1) * adv;
                    while (ww > chunk) {
                        widest = @max(widest, chunk);
                        lines += 1;
                        ww -= chunk;
                    }
                    cur = ww;
                }
                widest = @max(widest, cur);
                return .{ .lines = lines, .width = widest, .overflow = widest > max_w };
            },
        }
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "unit: gfx: family lists iterate in order and skip blanks" {
    var it = families(" Segoe UI Variable Text , ,Segoe UI,");
    try testing.expectEqualStrings("Segoe UI Variable Text", it.next().?);
    try testing.expectEqualStrings("Segoe UI", it.next().?);
    try testing.expect(it.next() == null);
    var one = families("Consolas");
    try testing.expectEqualStrings("Consolas", one.next().?);
    try testing.expect(one.next() == null);
    var none = families("");
    try testing.expect(none.next() == null);
}

test "unit: gfx: style hashes separate font identity from paragraph settings" {
    const a: TextStyle = .{};
    var b: TextStyle = .{};
    b.h_align = .center;
    try testing.expectEqual(a.fontHash(), b.fontHash());
    try testing.expect(a.layoutHash() != b.layoutHash());
    var c: TextStyle = .{};
    c.size = 13;
    try testing.expect(a.fontHash() != c.fontHash());
    var d: TextStyle = .{};
    d.weight = .semi_bold;
    try testing.expect(a.fontHash() != d.fontHash());
    // Every paragraph setting changes the paragraph key.
    var e: TextStyle = .{};
    e.underline = true;
    try testing.expect(!std.mem.eql(u8, &a.paragraphKey(), &e.paragraphKey()));
    var f: TextStyle = .{};
    f.trim_delimiter = '\\';
    try testing.expect(!std.mem.eql(u8, &a.paragraphKey(), &f.paragraphKey()));
    try testing.expect(a.layoutHash() != f.layoutHash());
    var g: TextStyle = .{};
    g.max_lines = 2;
    try testing.expect(!std.mem.eql(u8, &a.paragraphKey(), &g.paragraphKey()));
}

test "unit: gfx: fake measurer single line and trimming" {
    var fake: FakeMeasurer = .{};
    const m = fake.measurer();
    const style: TextStyle = .{ .size = 10 };
    const e = m.measure("hello", &style, 1000);
    try testing.expectEqual(@as(f32, 25), e.width);
    try testing.expectEqual(@as(f32, 12.5), e.height);
    try testing.expectEqual(@as(u32, 1), e.line_count);
    try testing.expect(!e.truncated);
    // Code points, not bytes.
    try testing.expectEqual(@as(f32, 15), m.measure("\u{e9}\u{e9}\u{1F600}", &style, 1000).width);

    const t = m.measure("hello world", &style, 20);
    try testing.expect(t.truncated);
    try testing.expectEqual(@as(f32, 20), t.width);
    var no_trim = style;
    no_trim.trim = .none;
    try testing.expectEqual(@as(f32, 55), m.measure("hello world", &no_trim, 20).width);

    // Empty text still has one line.
    try testing.expectEqual(@as(u32, 1), m.measure("", &style, 100).line_count);
    // Unconstrained width.
    try testing.expect(!m.measure("hello", &style, std.math.inf(f32)).truncated);
    // No room (zero, negative, NaN): truncated, as with DirectWrite.
    const no_room = m.measure("hello", &style, 0);
    try testing.expect(no_room.truncated);
    try testing.expectEqual(@as(f32, 0), no_room.width);
    try testing.expect(m.measure("hello", &style, -1).truncated);
    try testing.expect(m.measure("hello", &style, std.math.nan(f32)).truncated);
    try testing.expect(!m.measure("", &style, 0).truncated);
    // A line limit also caps explicit line breaks of single-line text.
    var one_line = style;
    one_line.max_lines = 1;
    const capped = m.measure("first\nsecond", &one_line, 1000);
    try testing.expectEqual(@as(u32, 1), capped.line_count);
    try testing.expect(capped.truncated);
}

test "unit: gfx: fake measurer wraps lines narrower than one character" {
    var fake: FakeMeasurer = .{};
    const m = fake.measurer();
    // Advance 5 in a 3-wide box: one character per line, flagged as overflow.
    const word: TextStyle = .{ .size = 10, .wrap = .word, .trim = .none };
    const w = m.measure("abc", &word, 3);
    try testing.expectEqual(@as(u32, 3), w.line_count);
    try testing.expect(w.truncated);
    try testing.expectEqual(@as(f32, 5), w.width);
    const chars: TextStyle = .{ .size = 10, .wrap = .character, .trim = .none };
    const c = m.measure("abc", &chars, 3);
    try testing.expectEqual(@as(u32, 3), c.line_count);
    try testing.expect(c.truncated);
    // Non-finite line heights fall back to the font's spacing.
    const bad_lh: TextStyle = .{ .size = 10, .line_height = std.math.inf(f32) };
    try testing.expectEqual(@as(f32, 12.5), m.measure("x", &bad_lh, 100).height);
}

test "unit: gfx: fake measurer word and character wrapping" {
    var fake: FakeMeasurer = .{};
    const m = fake.measurer();
    var style: TextStyle = .{ .size = 10, .wrap = .word };
    // Advance 5: "aaa bbb ccc" = 3 words of 15 at width 40 -> 2 lines.
    const e = m.measure("aaa bbb ccc", &style, 40);
    try testing.expectEqual(@as(u32, 2), e.line_count);
    try testing.expectEqual(@as(f32, 35), e.width);
    try testing.expectEqual(@as(f32, 25), e.height);
    // A long word breaks by characters.
    try testing.expectEqual(@as(u32, 3), m.measure("abcdefghijkl", &style, 25).line_count);
    // Paragraph breaks.
    try testing.expectEqual(@as(u32, 3), m.measure("a\nb\nc", &style, 100).line_count);
    // Line limit.
    style.max_lines = 1;
    const limited = m.measure("aaa bbb ccc", &style, 40);
    try testing.expectEqual(@as(u32, 1), limited.line_count);
    try testing.expect(limited.truncated);

    var chars: TextStyle = .{ .size = 10, .wrap = .character, .line_height = 20 };
    const c = m.measure("abcdefghij", &chars, 22);
    try testing.expectEqual(@as(u32, 3), c.line_count);
    try testing.expectEqual(@as(f32, 60), c.height);
    try testing.expectEqual(@as(f32, 20), c.width);
}
