//! Pure geometry for the Direct2D UI layer (ARCHITECTURE ADR-11.2, 11.5):
//! rectangles in layout units, DPI scaling and device-pixel snapping, and the
//! shape math behind pills, badges, progress bars, spinners, flowing chip
//! rows and scrolling.
//!
//! std-only, no Win32 types: runs in `zig build test-fast`. `Point`, `Rect`
//! are layout-compatible with D2D1_POINT_2F / D2D1_RECT_F.
//!
//! Units: "layout units" are whatever the render target draws in. With the
//! gfx default (render-target DPI = window DPI) they are DIPs and `scale` =
//! dpi / 96 device pixels per unit; in pixel mode scale is 1.
const std = @import("std");
const math = std.math;

pub const Point = extern struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn init(x: f32, y: f32) Point {
        return .{ .x = x, .y = y };
    }

    pub fn add(a: Point, b: Point) Point {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Point, b: Point) Point {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn scale(p: Point, s: f32) Point {
        return .{ .x = p.x * s, .y = p.y * s };
    }

    pub fn distance(a: Point, b: Point) f32 {
        return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
    }
};

pub const Size = extern struct {
    w: f32 = 0,
    h: f32 = 0,

    pub fn init(w: f32, h: f32) Size {
        return .{ .w = w, .h = h };
    }
};

pub const Insets = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,

    pub fn all(v: f32) Insets {
        return .{ .left = v, .top = v, .right = v, .bottom = v };
    }

    pub fn symmetric(horizontal_: f32, vertical_: f32) Insets {
        return .{ .left = horizontal_, .top = vertical_, .right = horizontal_, .bottom = vertical_ };
    }

    pub fn horizontal(self: Insets) f32 {
        return self.left + self.right;
    }

    pub fn vertical(self: Insets) f32 {
        return self.top + self.bottom;
    }

    pub fn scale(self: Insets, s: f32) Insets {
        return .{ .left = self.left * s, .top = self.top * s, .right = self.right * s, .bottom = self.bottom * s };
    }
};

pub const Align = enum { start, center, end };

fn alignOffset(free: f32, a: Align) f32 {
    return switch (a) {
        .start => 0,
        .center => free / 2,
        .end => free,
    };
}

pub const Rect = extern struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,

    pub fn xywh(x: f32, y: f32, w: f32, h: f32) Rect {
        return .{ .left = x, .top = y, .right = x + w, .bottom = y + h };
    }

    pub fn fromPointSize(p: Point, s: Size) Rect {
        return xywh(p.x, p.y, s.w, s.h);
    }

    pub fn width(r: Rect) f32 {
        return r.right - r.left;
    }

    pub fn height(r: Rect) f32 {
        return r.bottom - r.top;
    }

    pub fn size(r: Rect) Size {
        return .{ .w = r.width(), .h = r.height() };
    }

    pub fn origin(r: Rect) Point {
        return .{ .x = r.left, .y = r.top };
    }

    pub fn center(r: Rect) Point {
        return .{ .x = (r.left + r.right) / 2, .y = (r.top + r.bottom) / 2 };
    }

    /// True for zero/negative area and for NaN edges.
    pub fn isEmpty(r: Rect) bool {
        return !(r.right > r.left and r.bottom > r.top);
    }

    /// Half-open containment: left/top edges inside, right/bottom outside,
    /// so adjacent rows never both claim a point.
    pub fn contains(r: Rect, p: Point) bool {
        return p.x >= r.left and p.x < r.right and p.y >= r.top and p.y < r.bottom;
    }

    pub fn containsRect(r: Rect, o: Rect) bool {
        return o.left >= r.left and o.top >= r.top and o.right <= r.right and o.bottom <= r.bottom;
    }

    pub fn intersects(a: Rect, b: Rect) bool {
        return a.left < b.right and b.left < a.right and a.top < b.bottom and b.top < a.bottom;
    }

    /// Overlap of `a` and `b`; empty (zero-size) when they are disjoint.
    pub fn intersect(a: Rect, b: Rect) Rect {
        const l = @max(a.left, b.left);
        const t = @max(a.top, b.top);
        return .{ .left = l, .top = t, .right = @max(l, @min(a.right, b.right)), .bottom = @max(t, @min(a.bottom, b.bottom)) };
    }

    /// Bounding box of both; empty operands are ignored.
    pub fn unionWith(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        return .{ .left = @min(a.left, b.left), .top = @min(a.top, b.top), .right = @max(a.right, b.right), .bottom = @max(a.bottom, b.bottom) };
    }

    pub fn offset(r: Rect, dx: f32, dy: f32) Rect {
        return .{ .left = r.left + dx, .top = r.top + dy, .right = r.right + dx, .bottom = r.bottom + dy };
    }

    /// Shrink by `dx` on the left and right and `dy` on the top and bottom.
    /// A side that would invert collapses to the center line.
    pub fn inset(r: Rect, dx: f32, dy: f32) Rect {
        return r.insetBy(.{ .left = dx, .top = dy, .right = dx, .bottom = dy });
    }

    pub fn insetBy(r: Rect, in: Insets) Rect {
        var out: Rect = .{ .left = r.left + in.left, .top = r.top + in.top, .right = r.right - in.right, .bottom = r.bottom - in.bottom };
        if (out.right < out.left) {
            const cx = (out.left + out.right) / 2;
            out.left = cx;
            out.right = cx;
        }
        if (out.bottom < out.top) {
            const cy = (out.top + out.bottom) / 2;
            out.top = cy;
            out.bottom = cy;
        }
        return out;
    }

    pub fn outset(r: Rect, dx: f32, dy: f32) Rect {
        return .{ .left = r.left - dx, .top = r.top - dy, .right = r.right + dx, .bottom = r.bottom + dy };
    }

    pub fn scaled(r: Rect, s: f32) Rect {
        return .{ .left = r.left * s, .top = r.top * s, .right = r.right * s, .bottom = r.bottom * s };
    }

    /// Slice `w` units off the left side (clamped to the rect) and shrink
    /// `r` to the remainder.
    pub fn takeLeft(r: *Rect, w: f32) Rect {
        const x = @min(r.right, r.left + @max(w, 0));
        const out: Rect = .{ .left = r.left, .top = r.top, .right = x, .bottom = r.bottom };
        r.left = x;
        return out;
    }

    pub fn takeRight(r: *Rect, w: f32) Rect {
        const x = @max(r.left, r.right - @max(w, 0));
        const out: Rect = .{ .left = x, .top = r.top, .right = r.right, .bottom = r.bottom };
        r.right = x;
        return out;
    }

    pub fn takeTop(r: *Rect, h: f32) Rect {
        const y = @min(r.bottom, r.top + @max(h, 0));
        const out: Rect = .{ .left = r.left, .top = r.top, .right = r.right, .bottom = y };
        r.top = y;
        return out;
    }

    pub fn takeBottom(r: *Rect, h: f32) Rect {
        const y = @max(r.top, r.bottom - @max(h, 0));
        const out: Rect = .{ .left = r.left, .top = y, .right = r.right, .bottom = r.bottom };
        r.bottom = y;
        return out;
    }

    /// Position a box of size `s` inside `r` (it may overflow when larger).
    pub fn place(r: Rect, s: Size, h: Align, v: Align) Rect {
        return xywh(r.left + alignOffset(r.width() - s.w, h), r.top + alignOffset(r.height() - s.h, v), s.w, s.h);
    }

    pub fn approxEql(a: Rect, b: Rect, eps: f32) bool {
        return @abs(a.left - b.left) <= eps and @abs(a.top - b.top) <= eps and
            @abs(a.right - b.right) <= eps and @abs(a.bottom - b.bottom) <= eps;
    }
};

/// A rectangle in whole device pixels (Win32 RECT layout: i32 edges).
pub const PixelRect = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,

    pub fn width(r: PixelRect) i32 {
        return r.right - r.left;
    }

    pub fn height(r: PixelRect) i32 {
        return r.bottom - r.top;
    }

    pub fn isEmpty(r: PixelRect) bool {
        return r.right <= r.left or r.bottom <= r.top;
    }
};

fn toI32(v: f32) i32 {
    if (math.isNan(v)) return 0;
    const lo: f32 = @floatFromInt(math.minInt(i32));
    const hi: f32 = @floatFromInt(math.maxInt(i32));
    return @intFromFloat(math.clamp(v, lo, hi));
}

/// Per-monitor DPI (96 = 100%).
pub const Dpi = struct {
    value: u32 = 96,

    pub const default: Dpi = .{};

    /// 0 (an API failure) is treated as 96.
    pub fn init(value: u32) Dpi {
        return .{ .value = if (value == 0) 96 else value };
    }

    pub fn fromScale(s: f32) Dpi {
        return init(@intFromFloat(@round(@max(s, 0.1) * 96)));
    }

    /// Device pixels per DIP.
    pub fn scale(self: Dpi) f32 {
        return @as(f32, @floatFromInt(self.value)) / 96.0;
    }

    pub fn toPx(self: Dpi, dip: f32) f32 {
        return dip * self.scale();
    }

    pub fn toDip(self: Dpi, px: f32) f32 {
        return px / self.scale();
    }

    /// Round a DIP length to whole device pixels; identical to the GDI
    /// chrome's `scaled(base, scale)` helper (`@round(base * scale)`).
    pub fn pxRound(self: Dpi, dip: f32) i32 {
        return toI32(@round(dip * self.scale()));
    }

    /// A device-pixel position (e.g. mouse lParam) in DIPs.
    pub fn pointToDip(self: Dpi, x_px: i32, y_px: i32) Point {
        const s = self.scale();
        return .{ .x = @as(f32, @floatFromInt(x_px)) / s, .y = @as(f32, @floatFromInt(y_px)) / s };
    }

    pub fn rectToDip(self: Dpi, r: PixelRect) Rect {
        const s = self.scale();
        return .{
            .left = @as(f32, @floatFromInt(r.left)) / s,
            .top = @as(f32, @floatFromInt(r.top)) / s,
            .right = @as(f32, @floatFromInt(r.right)) / s,
            .bottom = @as(f32, @floatFromInt(r.bottom)) / s,
        };
    }

    /// Device pixels covering `r`, rounded outward, so an invalidation of
    /// the result repaints every pixel `r` touches.
    pub fn rectToPx(self: Dpi, r: Rect) PixelRect {
        const s = self.scale();
        return .{
            .left = toI32(@floor(r.left * s)),
            .top = toI32(@floor(r.top * s)),
            .right = toI32(@ceil(r.right * s)),
            .bottom = toI32(@ceil(r.bottom * s)),
        };
    }
};

// ─── Pixel snapping ─────────────────────────────────────────────────────

/// Round `v` to the nearest device-pixel boundary (`scale` = device pixels
/// per layout unit).
pub fn snap(v: f32, scale: f32) f32 {
    return @round(v * scale) / scale;
}

/// Snap every edge to a device-pixel boundary (crisp fills).
pub fn snapRect(r: Rect, scale: f32) Rect {
    return .{ .left = snap(r.left, scale), .top = snap(r.top, scale), .right = snap(r.right, scale), .bottom = snap(r.bottom, scale) };
}

/// One device pixel in layout units.
pub fn hairline(scale: f32) f32 {
    return 1.0 / scale;
}

/// Center of the device pixel containing `v`: where a line one device pixel
/// wide must sit to cover exactly one pixel row or column.
pub fn pixelCenter(v: f32, scale: f32) f32 {
    return (@floor(v * scale) + 0.5) / scale;
}

/// Rectangle to stroke so a border `stroke_px` device pixels wide lands
/// exactly on the pixels just inside `r` (edges snapped, then pulled in by
/// half the stroke).
pub fn strokeRect(r: Rect, scale: f32, stroke_px: f32) Rect {
    const half = stroke_px / scale / 2;
    return snapRect(r, scale).inset(half, half);
}

// ─── Shapes ─────────────────────────────────────────────────────────────

/// Corner radius clamped so the corners never overlap (NaN/negative = 0).
pub fn clampRadius(r: Rect, radius: f32) f32 {
    if (math.isNan(radius) or radius <= 0 or r.isEmpty()) return 0;
    return @min(radius, @min(r.width(), r.height()) / 2);
}

/// Radius that turns `r` into a capsule.
pub fn pillRadius(r: Rect) f32 {
    return clampRadius(r, math.inf(f32));
}

pub const PillMetrics = struct {
    pad_x: f32 = 6,
    pad_y: f32 = 2,
    /// Square icon box before the label; 0 = no icon.
    icon: f32 = 0,
    /// Space between the icon and the label.
    gap: f32 = 4,
    min_width: f32 = 0,
};

pub const PillLayout = struct {
    bounds: Rect,
    icon: ?Rect,
    text: Rect,
    radius: f32,
    /// The label was narrowed to respect the maximum width (draw it with
    /// ellipsis trimming).
    truncated: bool,
};

/// Lay out a capsule at `origin` holding an optional icon and a label of
/// natural size `label`. Height = max(label height, icon) + 2 * pad_y. When
/// the pill would exceed `max_width` the label shrinks; when `min_width`
/// widens it, the content is centered.
pub fn layoutPill(origin: Point, label: Size, m: PillMetrics, max_width: f32) PillLayout {
    const content_h = @max(label.h, m.icon);
    const h = content_h + 2 * m.pad_y;
    const has_icon = m.icon > 0;
    const icon_w: f32 = if (has_icon) m.icon + (if (label.w > 0) m.gap else 0) else 0;
    const chrome = 2 * m.pad_x + icon_w;

    var text_w = label.w;
    var truncated = false;
    const limit = @max(max_width, 0);
    var w = @max(chrome + text_w, m.min_width);
    if (w > limit) {
        const avail = @max(limit - chrome, 0);
        if (text_w > avail) {
            truncated = true;
            text_w = avail;
        }
        w = limit;
    }

    const extra = @max(w - (chrome + text_w), 0);
    const x0 = origin.x + m.pad_x + extra / 2;
    const bounds = Rect.xywh(origin.x, origin.y, w, h);
    const icon: ?Rect = if (has_icon) Rect.xywh(x0, origin.y + (h - m.icon) / 2, m.icon, m.icon) else null;
    const text = Rect.xywh(x0 + icon_w, origin.y + m.pad_y + (content_h - label.h) / 2, text_w, label.h);
    return .{ .bounds = bounds, .icon = icon, .text = text, .radius = pillRadius(bounds), .truncated = truncated };
}

/// Count badge right-aligned to `right` and centered on `center_y`: a
/// circle of diameter `height` for short labels, a capsule for longer ones.
pub fn badgeRect(right: f32, center_y: f32, label_w: f32, height: f32, pad_x: f32) Rect {
    const w = @max(height, label_w + 2 * pad_x);
    return Rect.xywh(right - w, center_y - height / 2, w, height);
}

/// Clamp a progress fraction to [0, 1]; NaN reads as 0.
pub fn clampFraction(fraction: f32) f32 {
    if (math.isNan(fraction)) return 0;
    return math.clamp(fraction, 0, 1);
}

/// Filled part of a horizontal progress track. A non-zero fraction is at
/// least `min_fill` wide (e.g. the track height, so rounded ends stay round).
pub fn progressFill(track: Rect, fraction: f32, min_fill: f32) Rect {
    const f = clampFraction(fraction);
    if (f == 0 or track.isEmpty()) return .{ .left = track.left, .top = track.top, .right = track.left, .bottom = track.bottom };
    const w = @min(@max(track.width() * f, min_fill), track.width());
    return .{ .left = track.left, .top = track.top, .right = track.left + w, .bottom = track.bottom };
}

/// Sliding segment of an indeterminate progress track. `phase` (in turns,
/// wrapped to [0, 1)) moves a segment `segment` (fraction of the track width)
/// from just left of the track to just right of it; the result is clipped
/// to the track and may be empty.
pub fn indeterminateSegment(track: Rect, phase: f32, segment: f32) Rect {
    const w = track.width();
    const seg_w = w * clampFraction(segment);
    const p = if (math.isNan(phase)) 0 else phase - @floor(phase);
    const x0 = track.left - seg_w + p * (w + seg_w);
    const l = @max(x0, track.left);
    return .{ .left = l, .top = track.top, .right = @max(l, @min(x0 + seg_w, track.right)), .bottom = track.bottom };
}

pub const Arc = struct {
    start: Point,
    end: Point,
    /// Clockwise sweep in radians, in (0, 2π).
    sweep: f32,
    /// More than half a turn (D2D1_ARC_SIZE_LARGE).
    large: bool,
};

/// Point on a circle. Angle in radians: 0 = 3 o'clock, positive turns
/// clockwise on screen (y points down).
pub fn pointOnCircle(c: Point, radius: f32, angle: f32) Point {
    return .{ .x = c.x + radius * @cos(angle), .y = c.y + radius * @sin(angle) };
}

/// Spinner arc at animation `phase` (turns, wrapped) covering
/// `sweep_fraction` of the circle (clamped to [0.01, 0.99] so the arc never
/// degenerates); phase 0 starts at 12 o'clock.
pub fn spinnerArc(c: Point, radius: f32, phase: f32, sweep_fraction: f32) Arc {
    const turn = 2 * math.pi;
    const p = if (math.isNan(phase)) 0 else phase - @floor(phase);
    const sweep_frac = if (math.isNan(sweep_fraction)) 0.25 else math.clamp(sweep_fraction, 0.01, 0.99);
    const sweep: f32 = sweep_frac * turn;
    const start: f32 = -math.pi / 2.0 + p * turn;
    return .{
        .start = pointOnCircle(c, radius, start),
        .end = pointOnCircle(c, radius, start + sweep),
        .sweep = sweep,
        .large = sweep > math.pi,
    };
}

// ─── Flow layout (chips, pills) ─────────────────────────────────────────

pub const FlowOptions = struct {
    max_width: f32,
    gap_x: f32 = 4,
    gap_y: f32 = 4,
    /// 0 = unlimited.
    max_lines: u32 = 0,
};

pub const FlowResult = struct {
    /// Items placed: a prefix of the input. Fewer than requested means the
    /// line limit (or `out`) ran out; show an overflow chip such as "+3".
    placed: usize,
    lines: u32,
    /// Bounding size of the placed items.
    size: Size,
};

/// Place boxes left to right from `origin`, wrapping at `max_width`. Boxes
/// wider than a line are clamped to the line width. Writes one rectangle per
/// placed item into `out`.
pub fn flow(origin: Point, items: []const Size, opts: FlowOptions, out: []Rect) FlowResult {
    const max_w = @max(opts.max_width, 0);
    var x: f32 = 0;
    var y: f32 = 0;
    var line_h: f32 = 0;
    var lines: u32 = 0;
    var widest: f32 = 0;
    var placed: usize = 0;
    for (items) |item| {
        if (placed == out.len) break;
        const w = @min(item.w, max_w);
        if (lines == 0) {
            lines = 1;
        } else if (x > 0 and x + w > max_w) {
            if (opts.max_lines != 0 and lines >= opts.max_lines) break;
            y += line_h + opts.gap_y;
            x = 0;
            line_h = 0;
            lines += 1;
        }
        out[placed] = Rect.xywh(origin.x + x, origin.y + y, w, item.h);
        placed += 1;
        widest = @max(widest, x + w);
        x += w + opts.gap_x;
        line_h = @max(line_h, item.h);
    }
    return .{ .placed = placed, .lines = lines, .size = .{ .w = widest, .h = if (lines == 0) 0 else y + line_h } };
}

// ─── Scrolling ──────────────────────────────────────────────────────────

/// Clamp a scroll offset to [0, max(0, content - viewport)].
pub fn clampScroll(offset: f32, content: f32, viewport: f32) f32 {
    const max_off = @max(content - viewport, 0);
    if (math.isNan(offset)) return 0;
    return math.clamp(offset, 0, max_off);
}

/// Smallest change of `offset` (the viewport top) that brings
/// [item_top, item_bottom) into view. Items taller than the viewport align
/// to their top.
pub fn scrollToReveal(offset: f32, viewport: f32, item_top: f32, item_bottom: f32) f32 {
    if (item_top < offset) return item_top;
    if (item_bottom - item_top > viewport) return item_top;
    if (item_bottom > offset + viewport) return item_bottom - viewport;
    return offset;
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectRect(expected: Rect, actual: Rect) !void {
    if (!expected.approxEql(actual, 1e-4)) {
        std.debug.print("expected {any}, got {any}\n", .{ expected, actual });
        return error.TestExpectedEqual;
    }
}

test "unit: gfx: rect basics and half-open containment" {
    const r = Rect.xywh(10, 20, 100, 50);
    try testing.expectEqual(@as(f32, 100), r.width());
    try testing.expectEqual(@as(f32, 50), r.height());
    try testing.expect(r.contains(.{ .x = 10, .y = 20 }));
    try testing.expect(!r.contains(.{ .x = 110, .y = 40 }));
    try testing.expect(!r.contains(.{ .x = 50, .y = 70 }));
    try testing.expect(!r.isEmpty());
    try testing.expect((Rect{}).isEmpty());
    try testing.expect((Rect{ .left = 0, .top = 0, .right = math.nan(f32), .bottom = 1 }).isEmpty());
    try expectRect(Rect.xywh(60, 20, 50, 50), r.intersect(Rect.xywh(60, 0, 100, 100)));
    try testing.expect(r.intersect(Rect.xywh(500, 500, 1, 1)).isEmpty());
    try testing.expect(!r.intersects(Rect.xywh(110, 20, 5, 5)));
    try expectRect(Rect.xywh(0, 0, 110, 70), r.unionWith(Rect.xywh(0, 0, 5, 5)));
    try expectRect(r, r.unionWith(.{}));
    try testing.expect(r.containsRect(Rect.xywh(20, 30, 10, 10)));
}

test "unit: gfx: inset collapses to the center line" {
    const r = Rect.xywh(0, 0, 10, 4);
    try expectRect(Rect.xywh(2, 1, 6, 2), r.inset(2, 1));
    const c = r.inset(8, 0);
    try testing.expectEqual(@as(f32, 5), c.left);
    try testing.expectEqual(@as(f32, 5), c.right);
    try testing.expect(c.isEmpty());
    try expectRect(Rect.xywh(1, 2, 6, 1), r.insetBy(.{ .left = 1, .top = 2, .right = 3, .bottom = 1 }));
    try expectRect(Rect.xywh(-1, -1, 12, 6), r.outset(1, 1));
}

test "unit: gfx: take slices a row into columns" {
    var row = Rect.xywh(0, 0, 200, 30);
    const badge = row.takeLeft(24);
    const close = row.takeRight(20);
    try expectRect(Rect.xywh(0, 0, 24, 30), badge);
    try expectRect(Rect.xywh(180, 0, 20, 30), close);
    try expectRect(Rect.xywh(24, 0, 156, 30), row);
    // Over-asking clamps to what is left.
    var small = Rect.xywh(0, 0, 10, 10);
    const all = small.takeTop(50);
    try expectRect(Rect.xywh(0, 0, 10, 10), all);
    try testing.expect(small.isEmpty());
    var col = Rect.xywh(0, 0, 10, 100);
    try expectRect(Rect.xywh(0, 80, 10, 20), col.takeBottom(20));
    try testing.expectEqual(@as(f32, 80), col.height());
}

test "unit: gfx: place aligns a box inside a rect" {
    const r = Rect.xywh(0, 0, 100, 40);
    try expectRect(Rect.xywh(40, 10, 20, 20), r.place(.{ .w = 20, .h = 20 }, .center, .center));
    try expectRect(Rect.xywh(80, 0, 20, 20), r.place(.{ .w = 20, .h = 20 }, .end, .start));
    try expectRect(Rect.xywh(0, 20, 20, 20), r.place(.{ .w = 20, .h = 20 }, .start, .end));
}

test "unit: gfx: dpi scaling at 1.0, 1.25, 1.5 and 2.0" {
    const cases = [_]struct { dpi: u32, scale: f32, row: i32 }{
        .{ .dpi = 96, .scale = 1.0, .row = 36 },
        .{ .dpi = 120, .scale = 1.25, .row = 45 },
        .{ .dpi = 144, .scale = 1.5, .row = 54 },
        .{ .dpi = 192, .scale = 2.0, .row = 72 },
    };
    for (cases) |c| {
        const d = Dpi.init(c.dpi);
        try testing.expectEqual(c.scale, d.scale());
        // Same rounding as the GDI sidebar's ITEM_HEIGHT_BASE = 36.
        try testing.expectEqual(c.row, d.pxRound(36));
        try testing.expectApproxEqAbs(@as(f32, 10), d.toDip(d.toPx(10)), 1e-5);
        try testing.expectEqual(c.dpi, Dpi.fromScale(c.scale).value);
    }
    try testing.expectEqual(@as(u32, 96), Dpi.init(0).value);
    const d = Dpi.init(120);
    const p = d.pointToDip(125, 250);
    try testing.expectApproxEqAbs(@as(f32, 100), p.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 200), p.y, 1e-4);
    // Outward rounding covers partially touched pixels.
    const px = d.rectToPx(Rect.xywh(0.5, 0.5, 10, 10));
    try testing.expectEqual(PixelRect{ .left = 0, .top = 0, .right = 14, .bottom = 14 }, px);
    try expectRect(Rect.xywh(0, 0, 80, 40), d.rectToDip(.{ .left = 0, .top = 0, .right = 100, .bottom = 50 }));
}

test "unit: gfx: snapping lands on device pixels" {
    // At 125% a DIP is 1.25 px: 10.3 DIP = 12.875 px -> 13 px = 10.4 DIP.
    try testing.expectApproxEqAbs(@as(f32, 10.4), snap(10.3, 1.25), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.8), hairline(1.25), 1e-6);
    // Pixel 12 spans [9.6, 10.4) DIP; its center is 10.0.
    try testing.expectApproxEqAbs(@as(f32, 10.0), pixelCenter(10.3, 1.25), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 5.5), pixelCenter(5.2, 1.0), 1e-6);
    const s = snapRect(Rect.xywh(0.3, 0.3, 9.6, 9.6), 2.0);
    try expectRect(.{ .left = 0.5, .top = 0.5, .right = 10.0, .bottom = 10.0 }, s);
    // A 1 px border inside a 10 px box at 100%: stroke centered on the
    // outermost pixel ring.
    try expectRect(.{ .left = 0.5, .top = 0.5, .right = 9.5, .bottom = 9.5 }, strokeRect(Rect.xywh(0, 0, 10, 10), 1.0, 1.0));
    try expectRect(.{ .left = 0.25, .top = 0.25, .right = 9.75, .bottom = 9.75 }, strokeRect(Rect.xywh(0, 0, 10, 10), 2.0, 1.0));
}

test "unit: gfx: corner radius clamps" {
    const r = Rect.xywh(0, 0, 40, 10);
    try testing.expectEqual(@as(f32, 4), clampRadius(r, 4));
    try testing.expectEqual(@as(f32, 5), clampRadius(r, 50));
    try testing.expectEqual(@as(f32, 0), clampRadius(r, -1));
    try testing.expectEqual(@as(f32, 0), clampRadius(r, math.nan(f32)));
    try testing.expectEqual(@as(f32, 5), pillRadius(r));
    try testing.expectEqual(@as(f32, 0), pillRadius(.{}));
}

test "unit: gfx: pill layout with icon, truncation and minimum width" {
    const m: PillMetrics = .{ .pad_x = 6, .pad_y = 2, .icon = 12, .gap = 4 };
    const p = layoutPill(.{ .x = 10, .y = 5 }, .{ .w = 40, .h = 14 }, m, 1000);
    try expectRect(Rect.xywh(10, 5, 6 + 12 + 4 + 40 + 6, 18), p.bounds);
    try expectRect(Rect.xywh(16, 8, 12, 12), p.icon.?);
    try expectRect(Rect.xywh(32, 7, 40, 14), p.text);
    try testing.expectEqual(@as(f32, 9), p.radius);
    try testing.expect(!p.truncated);

    const t = layoutPill(.{}, .{ .w = 100, .h = 14 }, m, 60);
    try testing.expectEqual(@as(f32, 60), t.bounds.width());
    try testing.expectEqual(@as(f32, 60 - 28), t.text.width());
    try testing.expect(t.truncated);

    // No icon: the gap disappears too.
    const n = layoutPill(.{}, .{ .w = 20, .h = 10 }, .{ .pad_x = 5, .pad_y = 1 }, 1000);
    try expectRect(Rect.xywh(0, 0, 30, 12), n.bounds);
    try testing.expect(n.icon == null);

    // Minimum width centers the content.
    const c = layoutPill(.{}, .{ .w = 10, .h = 10 }, .{ .pad_x = 5, .pad_y = 0, .min_width = 40 }, 1000);
    try testing.expectEqual(@as(f32, 40), c.bounds.width());
    try testing.expectApproxEqAbs(@as(f32, 15), c.text.left, 1e-5);

    // A maximum smaller than the chrome leaves no room for text.
    const z = layoutPill(.{}, .{ .w = 10, .h = 10 }, m, 8);
    try testing.expectEqual(@as(f32, 8), z.bounds.width());
    try testing.expectEqual(@as(f32, 0), z.text.width());
}

test "unit: gfx: badge is a circle for short labels and a capsule otherwise" {
    const one = badgeRect(100, 10, 6, 16, 4);
    try expectRect(Rect.xywh(84, 2, 16, 16), one);
    const many = badgeRect(100, 10, 20, 16, 4);
    try expectRect(Rect.xywh(72, 2, 28, 16), many);
}

test "unit: gfx: progress fill clamps and keeps a minimum width" {
    const track = Rect.xywh(0, 0, 200, 4);
    try testing.expectEqual(@as(f32, 50), progressFill(track, 0.25, 4).width());
    try testing.expectEqual(@as(f32, 200), progressFill(track, 1.5, 4).width());
    try testing.expectEqual(@as(f32, 0), progressFill(track, -1, 4).width());
    try testing.expectEqual(@as(f32, 0), progressFill(track, math.nan(f32), 4).width());
    try testing.expectEqual(@as(f32, 4), progressFill(track, 0.001, 4).width());
    try testing.expectEqual(@as(f32, 3), progressFill(Rect.xywh(0, 0, 3, 4), 0.1, 4).width());
}

test "unit: gfx: indeterminate segment slides through the track" {
    const track = Rect.xywh(0, 0, 100, 4);
    try testing.expect(indeterminateSegment(track, 0, 0.3).isEmpty());
    const mid = indeterminateSegment(track, 0.5, 0.3);
    try expectRect(.{ .left = 35, .top = 0, .right = 65, .bottom = 4 }, mid);
    // Partially visible near the start, clipped to the track.
    const early = indeterminateSegment(track, 0.1, 0.3);
    try testing.expectEqual(@as(f32, 0), early.left);
    try testing.expectApproxEqAbs(@as(f32, 13), early.right, 1e-4);
    // Phase wraps.
    try expectRect(mid, indeterminateSegment(track, 1.5, 0.3));
}

test "unit: gfx: spinner arc starts at twelve o'clock and sweeps clockwise" {
    const c: Point = .{ .x = 10, .y = 10 };
    const a = spinnerArc(c, 5, 0, 0.25);
    try testing.expectApproxEqAbs(@as(f32, 10), a.start.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 5), a.start.y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 15), a.end.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 10), a.end.y, 1e-4);
    try testing.expect(!a.large);
    const b = spinnerArc(c, 5, 0.25, 0.75);
    try testing.expectApproxEqAbs(@as(f32, 15), b.start.x, 1e-4);
    try testing.expect(b.large);
    // Sweep never reaches a full turn (D2D cannot draw a closed arc).
    try testing.expect(spinnerArc(c, 5, 0, 1).sweep < 2 * math.pi);
    try testing.expectApproxEqAbs(a.start.x, spinnerArc(c, 5, 3, 0.25).start.x, 1e-3);
}

test "unit: gfx: flow wraps chips and honors the line limit" {
    const items = [_]Size{ .{ .w = 40, .h = 16 }, .{ .w = 40, .h = 16 }, .{ .w = 40, .h = 20 }, .{ .w = 300, .h = 16 }, .{ .w = 10, .h = 16 } };
    var out: [items.len]Rect = undefined;
    const r = flow(.{ .x = 5, .y = 5 }, &items, .{ .max_width = 100, .gap_x = 4, .gap_y = 2 }, &out);
    try testing.expectEqual(@as(usize, 5), r.placed);
    try testing.expectEqual(@as(u32, 4), r.lines);
    try expectRect(Rect.xywh(5, 5, 40, 16), out[0]);
    try expectRect(Rect.xywh(49, 5, 40, 16), out[1]);
    try expectRect(Rect.xywh(5, 23, 40, 20), out[2]);
    // Too wide for a line: clamped and alone on its line.
    try expectRect(Rect.xywh(5, 45, 100, 16), out[3]);
    try expectRect(Rect.xywh(5, 63, 10, 16), out[4]);
    try testing.expectEqual(@as(f32, 100), r.size.w);
    try testing.expectEqual(@as(f32, 74), r.size.h);

    const limited = flow(.{}, &items, .{ .max_width = 100, .max_lines = 1 }, &out);
    try testing.expectEqual(@as(usize, 2), limited.placed);
    try testing.expectEqual(@as(u32, 1), limited.lines);

    const empty = flow(.{}, &.{}, .{ .max_width = 100 }, &out);
    try testing.expectEqual(@as(usize, 0), empty.placed);
    try testing.expectEqual(@as(f32, 0), empty.size.h);
}

test "unit: gfx: scroll helpers clamp and reveal rows" {
    try testing.expectEqual(@as(f32, 0), clampScroll(-5, 500, 200));
    try testing.expectEqual(@as(f32, 300), clampScroll(1000, 500, 200));
    try testing.expectEqual(@as(f32, 0), clampScroll(50, 100, 200));
    try testing.expectEqual(@as(f32, 0), clampScroll(math.nan(f32), 500, 200));
    // Row below the viewport scrolls just enough.
    try testing.expectEqual(@as(f32, 140), scrollToReveal(0, 200, 300, 340));
    // Row above scrolls to its top.
    try testing.expectEqual(@as(f32, 40), scrollToReveal(100, 200, 40, 80));
    // Visible row: unchanged.
    try testing.expectEqual(@as(f32, 100), scrollToReveal(100, 200, 120, 160));
    // Taller than the viewport: align top.
    try testing.expectEqual(@as(f32, 400), scrollToReveal(0, 200, 400, 700));
}
