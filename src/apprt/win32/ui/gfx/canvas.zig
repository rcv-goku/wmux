//! Drawing surface for one frame (ARCHITECTURE ADR-11): the primitives the
//! D2D sidebar, palette, right-sidebar mode bar and (W5) tab bars paint
//! with — rectangles, rounded rectangles, pills, badges, progress bars,
//! spinners, crisp hairlines, text, icon glyphs, clipping and opacity
//! layers.
//!
//! A `Canvas` is handed out by a render-target host (`target.zig`,
//! `offscreen.zig`) between BeginDraw and EndDraw. Drawing calls never fail:
//! Direct2D reports errors at EndDraw (the host turns device loss into a
//! recreate), and text problems are logged at debug level and skipped.
//! Every push (clip, layer) must be popped before the frame ends.
const std = @import("std");
const com = @import("../../platform/com.zig");
const d2d = @import("../../platform/d2d.zig");
const geometry = @import("logic/geometry.zig");
const color_mod = @import("logic/color.zig");
const style_mod = @import("logic/text_style.zig");
const text_mod = @import("text.zig");
const Context = @import("context.zig").Context;

const log = std.log.scoped(.gfx);

const Rect = geometry.Rect;
const Point = geometry.Point;
const Color = color_mod.Color;
const TextStyle = style_mod.TextStyle;
const TextExtent = style_mod.TextExtent;
const TextLayout = text_mod.TextLayout;

pub fn rectF(r: Rect) d2d.D2D1_RECT_F {
    return .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
}

pub fn pointF(p: Point) d2d.D2D1_POINT_2F {
    return .{ .x = p.x, .y = p.y };
}

pub fn colorF(c: Color) d2d.D2D1_COLOR_F {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

/// Device-dependent objects of one render target. Released (and recreated
/// on demand) whenever the target is discarded after device loss.
pub const DeviceResources = struct {
    /// One solid brush reused for every fill/stroke (`SetColor` per call is
    /// the cheapest way to draw many colors).
    brush: ?*d2d.ID2D1SolidColorBrush = null,
    /// Layer objects for Direct2D 1.0 targets; 1.1 device contexts push
    /// null layers and never fill this.
    layers: [max_layers]?*d2d.ID2D1Layer = .{null} ** max_layers,

    pub const max_layers = 16;

    pub fn ensure(self: *DeviceResources, rt: *d2d.ID2D1RenderTarget) com.Error!void {
        if (self.brush == null) self.brush = try rt.createSolidColorBrush(.{ .r = 0, .g = 0, .b = 0 }, null);
    }

    pub fn release(self: *DeviceResources) void {
        com.releaseAndNull(&self.brush);
        for (&self.layers) |*slot| com.releaseAndNull(slot);
    }
};

pub const Canvas = struct {
    ctx: *Context,
    rt: *d2d.ID2D1RenderTarget,
    res: *DeviceResources,
    /// Device pixels per layout unit (DIP mode: dpi / 96; pixel mode: 1).
    scale: f32,
    /// Base options for text draws (color fonts on Direct2D 1.1).
    text_options: d2d.D2D1_DRAW_TEXT_OPTIONS,
    /// Open clips and layers, in push order (Direct2D requires pops in
    /// reverse order across both kinds).
    pushes: [max_pushes]Push = undefined,
    push_depth: u8 = 0,
    /// Clip pushes beyond `max_pushes` that were not sent to Direct2D; their
    /// pops are skipped so pairing stays intact. (A layer push that does not
    /// fit returns an error instead and must not be popped.)
    skipped_pushes: u16 = 0,
    clip_depth: u16 = 0,
    layer_depth: u16 = 0,
    /// Geometry masks of pushed layers, released on pop.
    layer_masks: [DeviceResources.max_layers]?*d2d.ID2D1Geometry = .{null} ** DeviceResources.max_layers,

    pub const max_pushes = 32;
    const Push = enum(u8) { clip, layer };

    /// Hosts call this right after BeginDraw (resources already ensured).
    pub fn init(ctx: *Context, rt: *d2d.ID2D1RenderTarget, res: *DeviceResources, scale: f32) Canvas {
        rt.setTransform(.identity);
        return .{
            .ctx = ctx,
            .rt = rt,
            .res = res,
            .scale = if (scale > 0) scale else 1,
            .text_options = .{ .enable_color_font = ctx.d2d_1_1 },
        };
    }

    /// Hosts call this before EndDraw: unbalanced pushes are a bug (they
    /// fail EndDraw), so leftovers are logged and popped in reverse order.
    pub fn finish(self: *Canvas) void {
        if (self.push_depth != 0 or self.skipped_pushes != 0)
            log.warn("canvas: {d} clip(s)/layer(s) left pushed at end of frame", .{@as(u32, self.push_depth) + self.skipped_pushes});
        self.skipped_pushes = 0;
        while (self.push_depth > 0) {
            switch (self.pushes[self.push_depth - 1]) {
                .clip => self.popClip(),
                .layer => self.popLayer(),
            }
        }
    }

    /// Record a push; false when the stack is full (the caller then skips
    /// the Direct2D push and the matching pop is skipped too).
    fn beginPush(self: *Canvas, kind: Push) bool {
        if (self.push_depth >= max_pushes) {
            self.skipped_pushes += 1;
            log.debug("canvas: push stack full; {s} ignored", .{@tagName(kind)});
            return false;
        }
        self.pushes[self.push_depth] = kind;
        self.push_depth += 1;
        return true;
    }

    /// Pop bookkeeping; false when this pop matches a skipped push.
    fn endPush(self: *Canvas, kind: Push) bool {
        if (self.skipped_pushes > 0) {
            self.skipped_pushes -= 1;
            return false;
        }
        if (self.push_depth == 0) {
            std.debug.assert(false); // pop without push
            return false;
        }
        std.debug.assert(self.pushes[self.push_depth - 1] == kind); // pops must mirror pushes
        self.push_depth -= 1;
        return true;
    }

    fn brush(self: *Canvas, c: Color) *d2d.ID2D1Brush {
        const b = self.res.brush.?;
        b.setColor(colorF(c));
        return b.brush();
    }

    // ─── DPI helpers ────────────────────────────────────────────────────

    /// `v` rounded to a device-pixel boundary.
    pub fn snap(self: *const Canvas, v: f32) f32 {
        return geometry.snap(v, self.scale);
    }

    pub fn snapRect(self: *const Canvas, r: Rect) Rect {
        return geometry.snapRect(r, self.scale);
    }

    /// One device pixel in layout units.
    pub fn hairline(self: *const Canvas) f32 {
        return geometry.hairline(self.scale);
    }

    // ─── State ──────────────────────────────────────────────────────────

    pub fn clear(self: *Canvas, c: Color) void {
        self.rt.clear(colorF(c));
    }

    pub fn getTransform(self: *Canvas) d2d.D2D1_MATRIX_3X2_F {
        return self.rt.getTransform();
    }

    pub fn setTransform(self: *Canvas, m: d2d.D2D1_MATRIX_3X2_F) void {
        self.rt.setTransform(m);
    }

    /// Shift subsequent drawing (e.g. by the negative scroll offset of a
    /// virtualized list). Save/restore with get/setTransform.
    pub fn translate(self: *Canvas, dx: f32, dy: f32) void {
        self.rt.setTransform(d2d.D2D1_MATRIX_3X2_F.multiply(d2d.D2D1_MATRIX_3X2_F.translation(dx, dy), self.rt.getTransform()));
    }

    // ─── Shapes ─────────────────────────────────────────────────────────

    pub fn fillRect(self: *Canvas, r: Rect, c: Color) void {
        self.rt.fillRectangle(rectF(r), self.brush(c));
    }

    /// Stroke centered on the edges of `r` (see `strokeRectCrisp`).
    pub fn strokeRect(self: *Canvas, r: Rect, c: Color, width: f32) void {
        self.rt.drawRectangle(rectF(r), self.brush(c), width, null);
    }

    /// Border exactly `px` device pixels wide on the pixels just inside `r`.
    pub fn strokeRectCrisp(self: *Canvas, r: Rect, c: Color, px: f32) void {
        self.rt.drawRectangle(rectF(geometry.strokeRect(r, self.scale, px)), self.brush(c), px / self.scale, null);
    }

    pub fn fillRoundedRect(self: *Canvas, r: Rect, radius: f32, c: Color) void {
        const rad = geometry.clampRadius(r, radius);
        if (rad == 0) return self.fillRect(r, c);
        self.rt.fillRoundedRectangle(.{ .rect = rectF(r), .radiusX = rad, .radiusY = rad }, self.brush(c));
    }

    pub fn strokeRoundedRect(self: *Canvas, r: Rect, radius: f32, c: Color, width: f32) void {
        const rad = geometry.clampRadius(r, radius);
        self.rt.drawRoundedRectangle(.{ .rect = rectF(r), .radiusX = rad, .radiusY = rad }, self.brush(c), width, null);
    }

    /// Capsule (radius = half the shorter side).
    pub fn fillPill(self: *Canvas, r: Rect, c: Color) void {
        self.fillRoundedRect(r, geometry.pillRadius(r), c);
    }

    pub fn strokePill(self: *Canvas, r: Rect, c: Color, width: f32) void {
        self.strokeRoundedRect(r, geometry.pillRadius(r), c, width);
    }

    pub fn fillCircle(self: *Canvas, center: Point, radius: f32, c: Color) void {
        self.rt.fillEllipse(.{ .point = pointF(center), .radiusX = radius, .radiusY = radius }, self.brush(c));
    }

    pub fn strokeCircle(self: *Canvas, center: Point, radius: f32, c: Color, width: f32) void {
        self.rt.drawEllipse(.{ .point = pointF(center), .radiusX = radius, .radiusY = radius }, self.brush(c), width, null);
    }

    pub fn fillEllipse(self: *Canvas, r: Rect, c: Color) void {
        self.rt.fillEllipse(.{ .point = pointF(r.center()), .radiusX = r.width() / 2, .radiusY = r.height() / 2 }, self.brush(c));
    }

    pub fn line(self: *Canvas, a: Point, b: Point, c: Color, width: f32) void {
        self.rt.drawLine(pointF(a), pointF(b), self.brush(c), width, null);
    }

    /// Horizontal line exactly one device pixel tall (separators, dividers).
    pub fn hline(self: *Canvas, x0: f32, x1: f32, y: f32, c: Color) void {
        const yc = geometry.pixelCenter(y, self.scale);
        self.rt.drawLine(.{ .x = x0, .y = yc }, .{ .x = x1, .y = yc }, self.brush(c), self.hairline(), null);
    }

    /// Vertical line exactly one device pixel wide.
    pub fn vline(self: *Canvas, x: f32, y0: f32, y1: f32, c: Color) void {
        const xc = geometry.pixelCenter(x, self.scale);
        self.rt.drawLine(.{ .x = xc, .y = y0 }, .{ .x = xc, .y = y1 }, self.brush(c), self.hairline(), null);
    }

    pub fn fillGeometry(self: *Canvas, g: *d2d.ID2D1Geometry, c: Color) void {
        self.rt.fillGeometry(g, self.brush(c), null);
    }

    pub fn strokeGeometry(self: *Canvas, g: *d2d.ID2D1Geometry, c: Color, width: f32, style: ?*d2d.ID2D1StrokeStyle) void {
        self.rt.drawGeometry(g, self.brush(c), width, style);
    }

    /// Rounded progress track with its fill (`fraction` clamped to [0, 1]).
    pub fn progressBar(self: *Canvas, track: Rect, fraction: f32, track_color: Color, fill_color: Color) void {
        self.fillPill(track, track_color);
        const fill = geometry.progressFill(track, fraction, track.height());
        if (!fill.isEmpty()) self.fillPill(fill, fill_color);
    }

    /// Indeterminate progress: a segment sliding through the rounded track
    /// (`phase` in turns, advanced by the caller's animation timer).
    pub fn indeterminateBar(self: *Canvas, track: Rect, phase: f32, track_color: Color, fill_color: Color) void {
        self.fillPill(track, track_color);
        const seg = geometry.indeterminateSegment(track, phase, 0.3);
        if (seg.isEmpty()) return;
        self.pushRoundedClip(track, geometry.pillRadius(track)) catch {
            self.pushClip(track);
            self.fillPill(seg, fill_color);
            self.popClip();
            return;
        };
        self.fillRect(seg, fill_color);
        self.popLayer();
    }

    /// Spinner arc (`phase` in turns) of radius `radius` and stroke
    /// `thickness`, with round caps.
    pub fn spinner(self: *Canvas, center: Point, radius: f32, thickness: f32, phase: f32, c: Color) void {
        const arc = geometry.spinnerArc(center, radius, phase, 0.28);
        const path = self.ctx.factory.createPathGeometry() catch return;
        defer path.release();
        const sink = path.open() catch return;
        sink.beginFigure(pointF(arc.start), .hollow);
        sink.addArc(.{
            .point = pointF(arc.end),
            .size = .{ .width = radius, .height = radius },
            .sweepDirection = .clockwise,
            .arcSize = if (arc.large) .large else .small,
        });
        sink.endFigure(.open);
        const closed = sink.close();
        sink.release();
        closed catch return;
        self.rt.drawGeometry(path.geometry(), self.brush(c), thickness, self.ctx.round_caps);
    }

    // ─── Text ───────────────────────────────────────────────────────────

    /// Draw `str` inside `rect`. Single-line and line-limited text is
    /// aligned vertically by the canvas, so it shares its cached layout with
    /// `TextSystem.measure`; other wrapping text fills the box.
    pub fn text(self: *Canvas, str: []const u8, rect: Rect, style: *const TextStyle, c: Color) void {
        const fill_box = style.wrap != .none and style.max_lines == 0;
        const h = if (fill_box) rect.height() else text_mod.unbounded;
        const l = self.ctx.text.layout(str, style, rect.width(), h) catch |err| {
            log.debug("canvas text skipped: {s}", .{@errorName(err)});
            return;
        };
        defer l.deinit();
        var origin = rect.origin();
        if (!fill_box and style.v_align != .top) {
            const ext = l.extent() catch TextExtent{};
            const free = rect.height() - ext.height;
            origin.y += if (style.v_align == .center) free / 2 else free;
        }
        self.textLayout(l, origin, c);
    }

    /// Draw a prepared layout with its top-left at `origin`.
    pub fn textLayout(self: *Canvas, l: TextLayout, origin: Point, c: Color) void {
        var opts = self.text_options;
        opts.clip = true;
        self.rt.drawTextLayout(pointF(origin), l.raw, self.brush(c), opts);
    }

    /// Icon glyph `cp` from the icon font (Segoe Fluent Icons, falling back
    /// to Segoe MDL2 Assets) at `size`, centered in `rect`.
    pub fn icon(self: *Canvas, cp: u21, rect: Rect, size: f32, c: Color) void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        const style: TextStyle = .{
            .family = style_mod.icon_family,
            .size = size,
            .h_align = .center,
            .v_align = .center,
            .trim = .none,
        };
        self.text(buf[0..n], rect, &style, c);
    }

    pub const PillStyle = struct {
        metrics: geometry.PillMetrics = .{},
        text: TextStyle = .{ .size = 11 },
        background: Color,
        foreground: Color,
        /// Optional icon glyph (needs `metrics.icon > 0`).
        icon: ?u21 = null,
        icon_size: f32 = 11,
    };

    /// Pill with an optional icon and a label, its top-left at `origin`, at
    /// most `max_width` wide (the label is trimmed with an ellipsis).
    /// Returns the layout so callers can hit-test and advance.
    pub fn pill(self: *Canvas, label: []const u8, origin: Point, max_width: f32, s: PillStyle) geometry.PillLayout {
        var ts = s.text;
        ts.wrap = .none;
        const ext = self.ctx.text.measure(label, &ts, text_mod.unbounded);
        const pl = geometry.layoutPill(origin, .{ .w = ext.width, .h = ext.height }, s.metrics, max_width);
        self.fillRoundedRect(pl.bounds, pl.radius, s.background);
        if (pl.icon) |ir| if (s.icon) |cp| self.icon(cp, ir, s.icon_size, s.foreground);
        if (pl.text.width() > 0) self.text(label, pl.text, &ts, s.foreground);
        return pl;
    }

    /// Count badge (circle or capsule) right-aligned at `right`, centered on
    /// `center_y`; returns its bounds.
    pub fn badge(self: *Canvas, label: []const u8, right: f32, center_y: f32, height: f32, style: *const TextStyle, bg: Color, fg: Color) Rect {
        var ts = style.*;
        ts.wrap = .none;
        ts.h_align = .center;
        ts.v_align = .center;
        ts.trim = .none;
        const ext = self.ctx.text.measure(label, &ts, text_mod.unbounded);
        const r = geometry.badgeRect(right, center_y, ext.width, height, height * 0.3);
        self.fillPill(r, bg);
        self.text(label, r, &ts, fg);
        return r;
    }

    // ─── Clipping and layers ────────────────────────────────────────────

    /// Clip to an axis-aligned rectangle (cheap; pixel-aligned edges stay
    /// crisp). Pop with `popClip`.
    pub fn pushClip(self: *Canvas, r: Rect) void {
        if (!self.beginPush(.clip)) return;
        self.rt.pushAxisAlignedClip(rectF(r), .per_primitive);
        self.clip_depth += 1;
    }

    pub fn popClip(self: *Canvas) void {
        if (!self.endPush(.clip)) return;
        self.rt.popAxisAlignedClip();
        self.clip_depth -= 1;
    }

    /// Clip to a rounded rectangle (a layer with a geometric mask). Pop with
    /// `popLayer`.
    pub fn pushRoundedClip(self: *Canvas, r: Rect, radius: f32) com.Error!void {
        const rad = geometry.clampRadius(r, radius);
        const g = try self.ctx.factory.createRoundedRectangleGeometry(.{ .rect = rectF(r), .radiusX = rad, .radiusY = rad });
        errdefer g.release();
        try self.pushLayerWith(.{ .contentBounds = rectF(r), .geometricMask = g.geometry() }, g.geometry());
    }

    /// Composite subsequent drawing at `opacity` (fades, drag ghosts). Pop
    /// with `popLayer`.
    pub fn pushOpacity(self: *Canvas, opacity: f32) com.Error!void {
        const o: f32 = if (std.math.isNan(opacity)) 1 else std.math.clamp(opacity, 0, 1);
        try self.pushLayerWith(.{ .opacity = o }, null);
    }

    /// On error nothing is pushed (do not pop) and `mask` stays the
    /// caller's to release.
    fn pushLayerWith(self: *Canvas, params: d2d.D2D1_LAYER_PARAMETERS, mask: ?*d2d.ID2D1Geometry) com.Error!void {
        const depth = self.layer_depth;
        if (depth >= DeviceResources.max_layers or self.push_depth >= max_pushes) return error.WrongState;
        var layer: ?*d2d.ID2D1Layer = null;
        if (!self.ctx.d2d_1_1) {
            if (self.res.layers[depth] == null) self.res.layers[depth] = try self.rt.createLayer(null);
            layer = self.res.layers[depth];
        }
        const recorded = self.beginPush(.layer);
        std.debug.assert(recorded); // room was checked above
        self.rt.pushLayer(params, layer);
        self.layer_masks[depth] = mask;
        self.layer_depth = depth + 1;
    }

    pub fn popLayer(self: *Canvas) void {
        if (!self.endPush(.layer)) return;
        self.rt.popLayer();
        self.layer_depth -= 1;
        com.releaseAndNull(&self.layer_masks[self.layer_depth]);
    }

    // ─── Bitmaps ────────────────────────────────────────────────────────

    /// Draw a bitmap created from this frame's target (`dst` null = at the
    /// origin, natural size).
    pub fn bitmap(self: *Canvas, bmp: *d2d.ID2D1Bitmap, dst: ?Rect, opacity: f32) void {
        self.rt.drawBitmap(bmp, if (dst) |r| rectF(r) else null, opacity, .linear, null);
    }
};
