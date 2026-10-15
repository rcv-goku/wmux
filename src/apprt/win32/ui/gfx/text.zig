//! DirectWrite text system for the gfx layer (ARCHITECTURE ADR-11.2, 11.4):
//! text formats cached per font identity (with comma-separated family
//! fallback lists), text layouts cached in an LRU keyed by text + style +
//! box, measurement for row layout (`TextMeasurer`), and layout queries
//! (extent, hit testing, range rectangles, caret points).
//!
//! DirectWrite objects are device-independent: nothing here is lost when a
//! Direct2D device goes away. Formats and layouts are in layout units
//! (DIPs by default), so a DPI change does not invalidate them.
//!
//! Single-threaded: use a `TextSystem` from one (UI) thread.
const std = @import("std");
const com = @import("../../platform/com.zig");
const dwrite = @import("../../platform/dwrite.zig");
const geometry = @import("logic/geometry.zig");
const style_mod = @import("logic/text_style.zig");
const utf16 = @import("logic/utf16_map.zig");
const LruCache = @import("logic/lru.zig").LruCache;

const log = std.log.scoped(.gfx);
const Allocator = std.mem.Allocator;

const Rect = geometry.Rect;
const Point = geometry.Point;
pub const TextStyle = style_mod.TextStyle;
pub const TextExtent = style_mod.TextExtent;
pub const TextMeasurer = style_mod.TextMeasurer;

pub const Error = com.Error || Allocator.Error;

/// Box extent meaning "unconstrained". Layouts created with it get top
/// paragraph alignment (vertical alignment is then the caller's job, see
/// `Canvas.text`), so measuring and drawing share one cache entry.
pub const unbounded: f32 = 1.0e6;

/// Longer texts get uncached layouts (the cache key holds the text).
pub const max_cached_text = 4096;

fn sanitizeExtent(v: f32) f32 {
    if (std.math.isNan(v) or v < 0) return 0;
    return @min(v, unbounded);
}

/// Encode UTF-8 into `buf` as NUL-terminated UTF-16; null if it does not fit.
fn toUtf16Z(text: []const u8, buf: []u16) ?[:0]const u16 {
    if (buf.len == 0) return null;
    const out = utf16.encodeLossy(text, buf[0 .. buf.len - 1]) orelse return null;
    buf[out.len] = 0;
    return buf[0..out.len :0];
}

pub const TextSystem = struct {
    gpa: Allocator,
    factory: *dwrite.IDWriteFactory,
    fonts: *dwrite.IDWriteFontCollection,
    formats: std.StringHashMapUnmanaged(*FormatEntry) = .empty,
    /// Family list (as written in styles) → resolved installed family.
    families: std.StringHashMapUnmanaged([:0]u16) = .empty,
    layouts: LruCache(*dwrite.IDWriteTextLayout),
    font_key: std.ArrayListUnmanaged(u8) = .empty,
    layout_key: std.ArrayListUnmanaged(u8) = .empty,
    text16: std.ArrayListUnmanaged(u16) = .empty,

    pub const Options = struct {
        /// Cached text layouts (one per distinct text + style + box).
        layout_cache_capacity: usize = 512,
    };

    const FormatEntry = struct {
        format: *dwrite.IDWriteTextFormat,
        /// "…" sign drawn with this format's font; created on first use.
        ellipsis: ?*dwrite.IDWriteInlineObject = null,
    };

    pub fn init(gpa: Allocator, opts: Options) Error!TextSystem {
        const factory = try dwrite.createFactory(.shared);
        errdefer factory.release();
        const fonts = try factory.getSystemFontCollection(false);
        return .{
            .gpa = gpa,
            .factory = factory,
            .fonts = fonts,
            .layouts = LruCache(*dwrite.IDWriteTextLayout).init(gpa, opts.layout_cache_capacity, null, releaseLayout),
        };
    }

    fn releaseLayout(_: ?*anyopaque, layout_: *dwrite.IDWriteTextLayout) void {
        layout_.release();
    }

    pub fn deinit(self: *TextSystem) void {
        self.layouts.deinit();
        self.clearFormats();
        self.formats.deinit(self.gpa);
        self.clearFamilies();
        self.families.deinit(self.gpa);
        self.font_key.deinit(self.gpa);
        self.layout_key.deinit(self.gpa);
        self.text16.deinit(self.gpa);
        self.fonts.release();
        self.factory.release();
        self.* = undefined;
    }

    /// Drop every cached layout and format (font settings changed).
    pub fn clearCaches(self: *TextSystem) void {
        self.layouts.clear();
        self.clearFormats();
    }

    /// Re-read the system font collection (fonts installed or removed) and
    /// drop everything derived from it.
    pub fn refreshFonts(self: *TextSystem) com.Error!void {
        const fresh = try self.factory.getSystemFontCollection(true);
        self.clearCaches();
        self.clearFamilies();
        self.fonts.release();
        self.fonts = fresh;
    }

    fn clearFormats(self: *TextSystem) void {
        var it = self.formats.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (entry.ellipsis) |sign| sign.release();
            entry.format.release();
            self.gpa.destroy(entry);
            self.gpa.free(e.key_ptr.*);
        }
        self.formats.clearRetainingCapacity();
    }

    fn clearFamilies(self: *TextSystem) void {
        var it = self.families.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.families.clearRetainingCapacity();
    }

    /// Whether one family name (not a list) is installed.
    pub fn hasFamily(self: *TextSystem, family: []const u8) bool {
        var buf: [128]u16 = undefined;
        const name = toUtf16Z(family, &buf) orelse return false;
        const found = self.fonts.findFamilyName(name) catch return false;
        return found != null;
    }

    /// First installed family of a comma-separated list; when none is
    /// installed, the last entry (DirectWrite then substitutes a fallback).
    /// The result is cached and owned by the text system.
    pub fn resolveFamily(self: *TextSystem, list: []const u8) Allocator.Error![:0]const u16 {
        if (self.families.get(list)) |v| return v;
        var chosen: []const u8 = "";
        var it = style_mod.families(list);
        while (it.next()) |name| {
            chosen = name;
            if (self.hasFamily(name)) break;
        }
        if (chosen.len == 0) chosen = "Segoe UI";
        const value = try utf16.encodeLossyAllocZ(self.gpa, chosen);
        errdefer self.gpa.free(value);
        const key = try self.gpa.dupe(u8, list);
        errdefer self.gpa.free(key);
        try self.families.put(self.gpa, key, value);
        return value;
    }

    fn appendFontIdentity(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, style: *const TextStyle) Allocator.Error!void {
        try list.appendSlice(gpa, style.family);
        try list.append(gpa, 0);
        try list.appendSlice(gpa, style.locale);
        try list.append(gpa, 0);
        try list.appendSlice(gpa, std.mem.asBytes(&style.size));
        try list.appendSlice(gpa, std.mem.asBytes(&@intFromEnum(style.weight)));
        try list.appendSlice(gpa, &.{ @intFromEnum(style.slant), @intFromEnum(style.stretch) });
    }

    /// The cached format for `style`'s font identity (owned by the cache;
    /// valid until `clearCaches`/`deinit`).
    pub fn format(self: *TextSystem, style: *const TextStyle) Error!*dwrite.IDWriteTextFormat {
        return (try self.formatEntry(style)).format;
    }

    fn formatEntry(self: *TextSystem, style: *const TextStyle) Error!*FormatEntry {
        if (!(style.size > 0) or !std.math.isFinite(style.size)) return error.InvalidArg;
        self.font_key.clearRetainingCapacity();
        try appendFontIdentity(&self.font_key, self.gpa, style);
        if (self.formats.get(self.font_key.items)) |e| return e;

        const family = try self.resolveFamily(style.family);
        var locale_buf: [86]u16 = undefined; // LOCALE_NAME_MAX_LENGTH + 1
        const locale = toUtf16Z(style.locale, &locale_buf) orelse std.unicode.utf8ToUtf16LeStringLiteral("en-us");
        const fmt = try self.factory.createTextFormat(
            family.ptr,
            self.fonts,
            @enumFromInt(@intFromEnum(style.weight)),
            @enumFromInt(@intFromEnum(style.slant)),
            @enumFromInt(@intFromEnum(style.stretch)),
            style.size,
            locale.ptr,
        );
        errdefer fmt.release();
        const entry = try self.gpa.create(FormatEntry);
        errdefer self.gpa.destroy(entry);
        entry.* = .{ .format = fmt };
        const key = try self.gpa.dupe(u8, self.font_key.items);
        errdefer self.gpa.free(key);
        try self.formats.put(self.gpa, key, entry);
        return entry;
    }

    fn ellipsisFor(self: *TextSystem, entry: *FormatEntry) com.Error!*dwrite.IDWriteInlineObject {
        if (entry.ellipsis) |sign| return sign;
        const sign = try self.factory.createEllipsisTrimmingSign(entry.format);
        entry.ellipsis = sign;
        return sign;
    }

    /// Text layout for `text` (UTF-8; invalid bytes render as U+FFFD) in
    /// `style` within a `max_width` x `max_height` box. Cached; the returned
    /// handle holds its own reference: call `deinit`. Pass `unbounded` for
    /// an unconstrained side; zero, negative or NaN extents leave no room.
    /// The layout object is shared with the cache: never modify it (range
    /// formatting, drawing effects, max size); use `createLayout` for a
    /// private one.
    pub fn layout(self: *TextSystem, text: []const u8, style_in: *const TextStyle, max_width: f32, max_height: f32) Error!TextLayout {
        const w = sanitizeExtent(max_width);
        const h = sanitizeExtent(max_height);
        var style = style_in.*;
        if (h >= unbounded) style.v_align = .top;

        // The cache key embeds the text; do not pin huge strings.
        if (text.len > max_cached_text) return .{ .raw = try self.createLayout(text, &style, w, h) };

        self.layout_key.clearRetainingCapacity();
        try appendFontIdentity(&self.layout_key, self.gpa, &style);
        try self.layout_key.appendSlice(self.gpa, &style.paragraphKey());
        try self.layout_key.appendSlice(self.gpa, std.mem.asBytes(&w));
        try self.layout_key.appendSlice(self.gpa, std.mem.asBytes(&h));
        try self.layout_key.appendSlice(self.gpa, text);

        if (self.layouts.get(self.layout_key.items)) |cached| return .{ .raw = com.addRef(cached) };

        const raw = try self.createLayout(text, &style, w, h);
        errdefer raw.release();
        // The cache keeps one reference, the handle gets another.
        self.layouts.put(self.layout_key.items, raw) catch |err| {
            log.debug("text layout cache insert failed: {s}", .{@errorName(err)});
            return .{ .raw = raw };
        };
        return .{ .raw = com.addRef(raw) };
    }

    /// An uncached layout (for text that changes every frame, e.g. timers).
    pub fn createLayout(self: *TextSystem, text: []const u8, style: *const TextStyle, max_width: f32, max_height: f32) Error!*dwrite.IDWriteTextLayout {
        const entry = try self.formatEntry(style);
        var stack: [256]u16 = undefined;
        const text16 = utf16.encodeLossy(text, &stack) orelse blk: {
            try self.text16.resize(self.gpa, utf16.utf16Len(text));
            break :blk utf16.encodeLossy(text, self.text16.items).?;
        };
        const raw = try self.factory.createTextLayout(text16, entry.format, sanitizeExtent(max_width), sanitizeExtent(max_height));
        errdefer raw.release();

        try raw.setTextAlignment(@enumFromInt(@intFromEnum(style.h_align)));
        try raw.setParagraphAlignment(@enumFromInt(@intFromEnum(style.v_align)));
        try raw.setWordWrapping(switch (style.wrap) {
            .none => .no_wrap,
            .word => .wrap,
            .character => .character,
        });
        switch (style.trim) {
            .none => {},
            .character, .word => {
                const sign: ?*dwrite.IDWriteInlineObject = if (style.ellipsis) try self.ellipsisFor(entry) else null;
                try raw.setTrimming(.{
                    .granularity = if (style.trim == .word) .word else .character,
                    .delimiter = style.trim_delimiter,
                    .delimiterCount = if (style.trim_delimiter != 0) style.trim_delimiter_count else 0,
                }, sign);
            },
        }
        if (style.underline) try raw.setUnderline(true, .all);
        if (style.strikethrough) try raw.setStrikethrough(true, .all);
        if (style.line_height > 0 and std.math.isFinite(style.line_height))
            try raw.setLineSpacing(.uniform, style.line_height, style.line_height * 0.8);
        // Also for `.none`: explicit line breaks still make lines.
        if (style.max_lines > 0) try self.limitLines(raw, style.max_lines);
        return raw;
    }

    /// Cap a layout at `max_lines` by shrinking its box height to those
    /// lines. With trimming, DirectWrite hides the rest and trims the last
    /// visible line (with the ellipsis when enabled); without it the rest
    /// overflows the box, where drawing clips it and `extent` ignores it.
    fn limitLines(self: *TextSystem, raw: *dwrite.IDWriteTextLayout, max_lines: u16) Error!void {
        const count = try raw.getLineCount();
        if (count <= max_lines) return;
        var stack: [64]dwrite.DWRITE_LINE_METRICS = undefined;
        const heap: ?[]dwrite.DWRITE_LINE_METRICS = if (count > stack.len) try self.gpa.alloc(dwrite.DWRITE_LINE_METRICS, count) else null;
        defer if (heap) |b| self.gpa.free(b);
        const lines = try raw.getLineMetrics(heap orelse stack[0..]);
        var h: f32 = 0;
        for (lines[0..@min(lines.len, max_lines)]) |l| h += l.height;
        // A hair of slack so float rounding never hides the last line.
        try raw.setMaxHeight(@min(raw.getMaxHeight(), h + 0.01));
    }

    /// Extent of `text` in `style` within `max_width` (unbounded height;
    /// width semantics as in `TextMeasurer.measure`). Never fails: on error
    /// it logs at debug level and returns an estimate.
    pub fn measure(self: *TextSystem, text: []const u8, style: *const TextStyle, max_width: f32) TextExtent {
        const l = self.layout(text, style, max_width, unbounded) catch |err| return fallbackExtent(text, style, max_width, err);
        defer l.deinit();
        return l.extent() catch |err| fallbackExtent(text, style, max_width, err);
    }

    fn fallbackExtent(text: []const u8, style: *const TextStyle, max_width: f32, err: anyerror) TextExtent {
        log.debug("text measurement failed ({s}); using an estimate", .{@errorName(err)});
        const fake: style_mod.FakeMeasurer = .{ .advance_em = 0.55, .line_em = 1.33, .ascent_em = 1.06 };
        return fake.measure(text, style, max_width);
    }

    /// `TextMeasurer` backed by this system (keep the system at a stable
    /// address while the measurer is in use).
    pub fn measurer(self: *TextSystem) TextMeasurer {
        return .{ .ctx = self, .measure_fn = measureErased };
    }

    fn measureErased(ctx: *anyopaque, text: []const u8, style: *const TextStyle, max_width: f32) TextExtent {
        const self: *TextSystem = @ptrCast(@alignCast(ctx));
        return self.measure(text, style, max_width);
    }
};

/// A reference to a DirectWrite text layout. Positions and lengths are
/// UTF-16 code units (convert with `logic/utf16_map.zig`); coordinates are
/// relative to the layout origin. Layouts from `TextSystem.layout` are
/// shared with its cache: treat `raw` as read-only.
pub const TextLayout = struct {
    raw: *dwrite.IDWriteTextLayout,

    pub fn deinit(self: TextLayout) void {
        self.raw.release();
    }

    pub fn metrics(self: TextLayout) com.Error!dwrite.DWRITE_TEXT_METRICS {
        return self.raw.getMetrics();
    }

    /// Visible extent: lines hidden by a height limit do not count, and
    /// `truncated` reports trimming or overflow of the layout box.
    pub fn extent(self: TextLayout) com.Error!TextExtent {
        const m = try self.raw.getMetrics();
        var buf: [256]dwrite.DWRITE_LINE_METRICS = undefined;
        var out: TextExtent = .{ .width = m.width, .height = m.height, .line_count = m.lineCount };
        const overflow = m.width > m.layoutWidth + 0.01 or m.height > m.layoutHeight + 0.01;
        if (self.raw.getLineMetrics(&buf)) |lines| {
            // With trimming, DirectWrite gives the lines below the box zero
            // height. Without it they keep their height and overflow the box
            // (drawing clips them), so only lines that fit count; the first
            // line always does.
            var visible: u32 = 0;
            var visible_height: f32 = 0;
            var hidden = false;
            var trimmed = false;
            for (lines) |l| {
                if (l.isTrimmed != com.FALSE) trimmed = true;
                if (hidden or !(l.height > 0)) continue;
                if (visible > 0 and visible_height + l.height > m.layoutHeight + 0.01) {
                    hidden = true;
                    continue;
                }
                visible += 1;
                visible_height += l.height;
            }
            out.line_count = visible;
            if (hidden) out.height = visible_height;
            out.truncated = trimmed or overflow;
            if (lines.len > 0) out.baseline = lines[0].baseline;
        } else |err| switch (err) {
            // More than 256 lines: report what the metrics know.
            error.BufferTooSmall => out.truncated = overflow,
            else => return err,
        }
        return out;
    }

    pub const Hit = struct {
        /// UTF-16 position of the hit cluster.
        position: u32,
        /// The point is on the trailing half: the caret goes after it.
        trailing: bool,
        /// The point is inside the text bounds.
        inside: bool,
        /// Bounds of the hit cluster.
        rect: Rect,
    };

    pub fn hitTest(self: TextLayout, p: Point) com.Error!Hit {
        const h = try self.raw.hitTestPoint(p.x, p.y);
        return .{
            .position = h.metrics.textPosition,
            .trailing = h.is_trailing,
            .inside = h.is_inside,
            .rect = Rect.xywh(h.metrics.left, h.metrics.top, h.metrics.width, h.metrics.height),
        };
    }

    /// Caret position for a UTF-16 position (leading or trailing edge).
    pub fn caretPoint(self: TextLayout, position: u32, trailing: bool) com.Error!Point {
        const h = try self.raw.hitTestTextPosition(position, trailing);
        return .{ .x = h.x, .y = h.y };
    }

    /// Rectangles covering a UTF-16 range, offset by `origin` (link hover
    /// areas, selection, highlights). Returns the filled prefix of `out`.
    pub fn rangeRects(self: TextLayout, position: u32, length: u32, origin: Point, out: []Rect) com.Error![]Rect {
        var buf: [32]dwrite.DWRITE_HIT_TEST_METRICS = undefined;
        const cap = @min(out.len, buf.len);
        const hits = try self.raw.hitTestTextRange(position, length, origin.x, origin.y, buf[0..cap]);
        for (hits, 0..) |h, i| out[i] = Rect.xywh(h.left, h.top, h.width, h.height);
        return out[0..hits.len];
    }
};
