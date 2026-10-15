//! Pure color math for the Direct2D UI layer (ARCHITECTURE ADR-11.4: theme
//! tokens derive from the terminal background/foreground plus an accent,
//! with a WCAG 4.5:1 contrast floor).
//!
//! `Color` holds straight (non-premultiplied) sRGB components in [0, 1] and
//! is layout-compatible with D2D1_COLOR_F (Direct2D brushes take straight
//! alpha). std-only: runs in `zig build test-fast`.
const std = @import("std");
const math = std.math;

/// WCAG 2.x AA minimum contrast for normal text.
pub const min_text_contrast: f32 = 4.5;
/// WCAG 2.x minimum contrast for large text and UI component boundaries.
pub const min_ui_contrast: f32 = 3.0;

pub const Color = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Color = .{ .r = 1, .g = 1, .b = 1 };

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return rgba(r, g, b, 255);
    }

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = @as(f32, @floatFromInt(a)) / 255.0,
        };
    }

    /// 0xRRGGBB.
    pub fn hex(v: u24) Color {
        return rgb(@truncate(v >> 16), @truncate(v >> 8), @truncate(v));
    }

    /// 0xRRGGBBAA.
    pub fn hexa(v: u32) Color {
        return rgba(@truncate(v >> 24), @truncate(v >> 16), @truncate(v >> 8), @truncate(v));
    }

    pub const ParseError = error{InvalidColor};

    /// "#rgb", "#rgba", "#rrggbb" or "#rrggbbaa" (CSS channel order; the
    /// leading '#' is optional; surrounding spaces are ignored).
    pub fn parse(text: []const u8) ParseError!Color {
        var s = std.mem.trim(u8, text, " \t");
        if (s.len > 0 and s[0] == '#') s = s[1..];
        switch (s.len) {
            3, 4 => {
                var ch: [4]u8 = .{ 0, 0, 0, 255 };
                for (s, 0..) |c, i| {
                    const d = std.fmt.charToDigit(c, 16) catch return error.InvalidColor;
                    ch[i] = d * 17;
                }
                return rgba(ch[0], ch[1], ch[2], ch[3]);
            },
            6, 8 => {
                var ch: [4]u8 = .{ 0, 0, 0, 255 };
                var i: usize = 0;
                while (i < s.len) : (i += 2) {
                    ch[i / 2] = std.fmt.parseInt(u8, s[i .. i + 2], 16) catch return error.InvalidColor;
                }
                return rgba(ch[0], ch[1], ch[2], ch[3]);
            },
            else => return error.InvalidColor,
        }
    }

    pub fn withAlpha(c: Color, a: f32) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = clamp01(a) };
    }

    /// Channels rounded to bytes (clamped).
    pub fn toRgba8(c: Color) [4]u8 {
        return .{ toByte(c.r), toByte(c.g), toByte(c.b), toByte(c.a) };
    }

    /// GDI COLORREF (0x00BBGGRR) for interop with the GDI chrome.
    pub fn toColorref(c: Color) u32 {
        const v = c.toRgba8();
        return @as(u32, v[0]) | (@as(u32, v[1]) << 8) | (@as(u32, v[2]) << 16);
    }

    pub fn fromColorref(v: u32) Color {
        return rgb(@truncate(v), @truncate(v >> 8), @truncate(v >> 16));
    }

    /// Linear interpolation in sRGB space (alpha too); `t` is clamped.
    pub fn mix(a: Color, b: Color, t: f32) Color {
        const k = clamp01(t);
        return .{
            .r = a.r + (b.r - a.r) * k,
            .g = a.g + (b.g - a.g) * k,
            .b = a.b + (b.b - a.b) * k,
            .a = a.a + (b.a - a.a) * k,
        };
    }

    /// Mix toward white by `t`, keeping alpha.
    pub fn lighten(c: Color, t: f32) Color {
        return mix(c, white.withAlpha(c.a), t);
    }

    /// Mix toward black by `t`, keeping alpha.
    pub fn darken(c: Color, t: f32) Color {
        return mix(c, black.withAlpha(c.a), t);
    }

    /// Add `delta` (in 1/255 steps) to each color channel, clamped; the
    /// GDI chrome derives its strips this way (terminal background + 12).
    pub fn offset(c: Color, delta: i32) Color {
        const d = @as(f32, @floatFromInt(delta)) / 255.0;
        return .{ .r = clamp01(c.r + d), .g = clamp01(c.g + d), .b = clamp01(c.b + d), .a = c.a };
    }

    /// Composite `src` over `dst` (straight alpha, sRGB space).
    pub fn over(src: Color, dst: Color) Color {
        const a = src.a + dst.a * (1 - src.a);
        if (a <= 0) return transparent;
        return .{
            .r = (src.r * src.a + dst.r * dst.a * (1 - src.a)) / a,
            .g = (src.g * src.a + dst.g * dst.a * (1 - src.a)) / a,
            .b = (src.b * src.a + dst.b * dst.a * (1 - src.a)) / a,
            .a = a,
        };
    }

    /// Premultiplied components (what Direct2D writes into PBGRA pixels).
    pub fn premultiplied(c: Color) Color {
        return .{ .r = c.r * c.a, .g = c.g * c.a, .b = c.b * c.a, .a = c.a };
    }

    /// WCAG relative luminance of the color (alpha ignored).
    pub fn luminance(c: Color) f32 {
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
    }

    /// True when white text reads better on this color than black text.
    pub fn isDark(c: Color) bool {
        return contrastRatio(white, c) >= contrastRatio(black, c);
    }

    pub fn approxEql(a: Color, b: Color, eps: f32) bool {
        return @abs(a.r - b.r) <= eps and @abs(a.g - b.g) <= eps and @abs(a.b - b.b) <= eps and @abs(a.a - b.a) <= eps;
    }
};

fn clamp01(v: f32) f32 {
    if (math.isNan(v)) return 0;
    return math.clamp(v, 0, 1);
}

fn toByte(v: f32) u8 {
    return @intFromFloat(@round(clamp01(v) * 255.0));
}

/// sRGB transfer function inverse (IEC 61966-2-1).
fn linear(c: f32) f32 {
    const v = clamp01(c);
    return if (v <= 0.04045) v / 12.92 else math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

/// WCAG contrast ratio between two opaque colors, in [1, 21].
pub fn contrastRatio(a: Color, b: Color) f32 {
    const la = a.luminance();
    const lb = b.luminance();
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

/// `fg` adjusted toward white or black (whichever contrasts more with `bg`)
/// just enough to reach `min_ratio` against `bg`. Colors that already pass
/// are returned unchanged; if even pure white/black falls short, that
/// extreme is returned. `bg` is treated as opaque (composite first); `fg`
/// keeps its alpha.
pub fn ensureContrast(fg: Color, bg: Color, min_ratio: f32) Color {
    if (contrastRatio(fg, bg) >= min_ratio) return fg;
    const target = if (contrastRatio(Color.white, bg) >= contrastRatio(Color.black, bg)) Color.white else Color.black;
    if (contrastRatio(target, bg) < min_ratio) return target.withAlpha(fg.a);
    var lo: f32 = 0;
    var hi: f32 = 1;
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        const mid = (lo + hi) / 2;
        if (contrastRatio(Color.mix(fg, target, mid), bg) >= min_ratio) hi = mid else lo = mid;
    }
    return Color.mix(fg, target, hi).withAlpha(fg.a);
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "unit: gfx: color constructors and byte round trips" {
    const c = Color.hex(0x3D8EF8);
    try testing.expectEqual([4]u8{ 0x3D, 0x8E, 0xF8, 0xFF }, c.toRgba8());
    try testing.expectEqual([4]u8{ 1, 2, 3, 4 }, Color.hexa(0x01020304).toRgba8());
    try testing.expectEqual([4]u8{ 10, 20, 30, 255 }, Color.rgb(10, 20, 30).toRgba8());
    // GDI COLORREF is 0x00BBGGRR.
    try testing.expectEqual(@as(u32, 0x00F88E3D), c.toColorref());
    try testing.expect(Color.fromColorref(0x00F88E3D).approxEql(c, 1e-6));
    try testing.expectEqual([4]u8{ 255, 0, 0, 128 }, (Color{ .r = 2, .g = -1, .b = math.nan(f32), .a = 0.5 }).toRgba8());
}

test "unit: gfx: color parsing" {
    try testing.expectEqual([4]u8{ 0x11, 0x22, 0x33, 0xFF }, (try Color.parse("#123")).toRgba8());
    try testing.expectEqual([4]u8{ 0x11, 0x22, 0x33, 0x44 }, (try Color.parse("1234")).toRgba8());
    try testing.expectEqual([4]u8{ 0xAB, 0xCD, 0xEF, 0xFF }, (try Color.parse(" #abcdef ")).toRgba8());
    try testing.expectEqual([4]u8{ 0xAB, 0xCD, 0xEF, 0x80 }, (try Color.parse("#ABCDEF80")).toRgba8());
    try testing.expectError(error.InvalidColor, Color.parse("#12"));
    try testing.expectError(error.InvalidColor, Color.parse("#ggg"));
    try testing.expectError(error.InvalidColor, Color.parse("#1234567"));
    try testing.expectError(error.InvalidColor, Color.parse(""));
}

test "unit: gfx: color mixing, offsets and compositing" {
    const a = Color.rgb(0, 0, 0);
    const b = Color.rgb(255, 255, 255);
    try testing.expectEqual([4]u8{ 128, 128, 128, 255 }, Color.mix(a, b, 0.5).toRgba8());
    try testing.expectEqual(a, Color.mix(a, b, -1));
    // The GDI sidebar strip: terminal background + 12 per channel, clamped.
    try testing.expectEqual([4]u8{ 42, 42, 46, 255 }, Color.rgb(30, 30, 34).offset(12).toRgba8());
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, Color.rgb(250, 250, 250).offset(12).toRgba8());
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, Color.rgb(5, 5, 5).offset(-12).toRgba8());
    // 128/255 halfway to white = 191.5/255, rounds to 192.
    try testing.expectEqual([4]u8{ 192, 192, 192, 255 }, Color.rgb(128, 128, 128).lighten(0.5).toRgba8());
    try testing.expectEqual([4]u8{ 64, 64, 64, 255 }, Color.rgb(128, 128, 128).darken(0.5).toRgba8());
    // 50% white over black is mid gray; over transparent stays the source.
    const half_white = Color.white.withAlpha(0.5);
    try testing.expectEqual([4]u8{ 128, 128, 128, 255 }, half_white.over(Color.black).toRgba8());
    try testing.expect(half_white.over(Color.transparent).approxEql(half_white, 1e-6));
    try testing.expect(Color.transparent.over(Color.transparent).approxEql(Color.transparent, 0));
    try testing.expect(half_white.premultiplied().approxEql(.{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 0.5 }, 1e-6));
}

test "unit: gfx: WCAG luminance and contrast" {
    try testing.expectApproxEqAbs(@as(f32, 0), Color.black.luminance(), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), Color.white.luminance(), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 21), contrastRatio(Color.white, Color.black), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1), contrastRatio(Color.hex(0x777777), Color.hex(0x777777)), 1e-6);
    // Reference value: #777777 on white is about 4.48:1 (just below AA).
    try testing.expectApproxEqAbs(@as(f32, 4.48), contrastRatio(Color.hex(0x777777), Color.white), 0.01);
    try testing.expect(Color.hex(0x1E1E1E).isDark());
    try testing.expect(!Color.hex(0xF3F3F3).isDark());
}

test "unit: gfx: ensureContrast lifts text to the floor" {
    const bg = Color.hex(0x1E1E1E);
    // The GDI sidebar's metadata gray (120,120,120) on a dark background is
    // too dim for AA; it gets lightened just enough.
    const dim = Color.rgb(120, 120, 120);
    try testing.expect(contrastRatio(dim, bg) < min_text_contrast);
    const fixed = ensureContrast(dim, bg, min_text_contrast);
    try testing.expect(contrastRatio(fixed, bg) >= min_text_contrast);
    try testing.expect(contrastRatio(fixed, bg) < min_text_contrast + 0.1);
    try testing.expect(fixed.luminance() > dim.luminance());

    // Light theme: darkened instead.
    const light_bg = Color.hex(0xFAFAFA);
    const pale = Color.hex(0xBBBBBB);
    const darker = ensureContrast(pale, light_bg, min_text_contrast);
    try testing.expect(contrastRatio(darker, light_bg) >= min_text_contrast);
    try testing.expect(darker.luminance() < pale.luminance());

    // Already fine: unchanged; alpha preserved when adjusted.
    try testing.expectEqual(Color.white, ensureContrast(Color.white, bg, min_text_contrast));
    try testing.expectEqual(@as(f32, 0.5), ensureContrast(dim.withAlpha(0.5), bg, min_text_contrast).a);

    // Impossible floor: best extreme.
    const mid = Color.hex(0x808080);
    const best = ensureContrast(mid, mid, 21);
    try testing.expect(best.approxEql(Color.black, 1e-6) or best.approxEql(Color.white, 1e-6));
}
