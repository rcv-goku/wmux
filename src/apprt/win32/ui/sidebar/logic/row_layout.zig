//! Pure sidebar row layout (ARCHITECTURE ADR-11.2 step 2, ADR-11.5).
//!
//! Measures rows from `row_model.zig` through the gfx `TextMeasurer`
//! (DirectWrite in the app, `FakeMeasurer` in tests) and produces one
//! `RowGeom{top, height, elements}` per row: the single geometry source for
//! paint, hit-testing, drag targets and tooltips.
//!
//! Units are DIPs (the render target runs at the window DPI, spike S7).
//! Every rectangle and row height is snapped to device pixels for the
//! current `Dpi`, so rows stay crisp at 1.25x/1.5x and row tops never drift
//! off the pixel grid. Element rectangles are relative to the row: x from
//! the sidebar's left edge, y from the row's top.
//!
//! Sizes derive from `sidebar.fontSize` (DIPs, default 12.5) times
//! `app.globalFontMagnification`, so a larger font makes rows taller.
//!
//! `Cache` keeps per-row results keyed by (content hash, width, DPI,
//! metrics); a model change produces new hashes, so stale entries simply
//! age out of the LRU.
const std = @import("std");
const geometry = @import("../../gfx/logic/geometry.zig");
const text_style = @import("../../gfx/logic/text_style.zig");
const lru = @import("../../gfx/logic/lru.zig");
const utf16_map = @import("../../gfx/logic/utf16_map.zig");
const model = @import("row_model.zig");

const Allocator = std.mem.Allocator;
pub const Rect = geometry.Rect;
pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Dpi = geometry.Dpi;
pub const TextStyle = text_style.TextStyle;
pub const TextMeasurer = text_style.TextMeasurer;

pub const default_font_size: f32 = 12.5;
const base_font: f32 = default_font_size;
const ellipsis = "\u{2026}";

/// Layout inputs that are not row content.
pub const Params = struct {
    /// Sidebar client width in DIPs.
    width: f32,
    dpi: Dpi = .default,
    metrics: Metrics = .{},
};

pub const Metrics = struct {
    /// `sidebar.fontSize` (DIPs; macOS points map 1:1 to DIPs).
    font_size: f32 = default_font_size,
    /// `app.globalFontMagnification` / 100.
    magnification: f32 = 1,

    /// Effective font size, sanitized (NaN/0 = default) and clamped to
    /// [6, 72] DIPs.
    pub fn fontSize(self: Metrics) f32 {
        const fs = if (std.math.isFinite(self.font_size) and self.font_size > 0) self.font_size else default_font_size;
        const mag = if (std.math.isFinite(self.magnification) and self.magnification > 0) std.math.clamp(self.magnification, 0.25, 4) else 1;
        return std.math.clamp(fs * mag, 6, 72);
    }

    pub fn hash(self: Metrics) u64 {
        const f = self.fontSize();
        return std.hash.Wyhash.hash(0x6d74_7263, std.mem.asBytes(&f));
    }

    pub fn resolve(self: Metrics) Resolved {
        const f = self.fontSize();
        const k = f / base_font;
        return .{
            .font = f,
            .pad_x = 10 * k,
            .pad_top = 7 * k,
            .pad_bottom = 7 * k,
            .line_gap = 3 * k,
            .gap = 5 * k,
            .icon = 14 * k,
            .detail_icon = 12 * k,
            .badge_h = 16 * k,
            .badge_pad = 5 * k,
            .close = 16 * k,
            .dot = 8 * k,
            .rail_w = 3 * k,
            .progress_h = 4 * k,
            .header_pad_top = 9 * k,
            .header_pad_bottom = 4 * k,
            .pill = .{ .pad_x = 6 * k, .pad_y = 2 * k, .icon = 0, .gap = 4 * k },
            .chip = .{ .pad_x = 5 * k, .pad_y = 1 * k, .icon = 0, .gap = 0 },
            .flow_gap = 4 * k,
        };
    }
};

/// Metrics in DIPs for one font size.
pub const Resolved = struct {
    font: f32,
    pad_x: f32,
    pad_top: f32,
    pad_bottom: f32,
    line_gap: f32,
    gap: f32,
    icon: f32,
    detail_icon: f32,
    badge_h: f32,
    badge_pad: f32,
    close: f32,
    dot: f32,
    rail_w: f32,
    progress_h: f32,
    header_pad_top: f32,
    header_pad_bottom: f32,
    pill: geometry.PillMetrics,
    chip: geometry.PillMetrics,
    flow_gap: f32,
};

/// Which text style an element is drawn with (shared by layout and paint).
pub const TextRole = enum(u8) { none, title, detail, header, badge, hint, pill, chip, toggle, progress_label };

/// The one place text styles are defined: layout measures with exactly
/// what paint draws. Single-line roles cap at one line, so an explicit
/// line break (DirectWrite breaks lines there even without wrapping) is
/// trimmed instead of growing the element. Paint uses `elementStyle`,
/// which also applies the title's wrap mode and a detail line's overflow.
pub fn textStyle(role: TextRole, r: Resolved) TextStyle {
    const f = r.font;
    return switch (role) {
        .none, .detail => .{ .size = f * 0.88 },
        .progress_label => .{ .size = f * 0.88, .max_lines = 1 },
        .title => .{ .size = f, .weight = .medium, .max_lines = 1 },
        .header => .{ .size = f * 0.85, .weight = .semi_bold, .max_lines = 1 },
        .badge => .{ .size = f * 0.78, .weight = .semi_bold, .h_align = .center, .max_lines = 1 },
        .hint => .{ .size = f * 0.78, .weight = .medium, .h_align = .center, .max_lines = 1 },
        .pill => .{ .size = f * 0.82, .max_lines = 1 },
        .chip => .{ .size = f * 0.82, .family = text_style.mono_family, .max_lines = 1 },
        .toggle => .{ .size = f * 0.82, .weight = .medium, .max_lines = 1 },
    };
}

/// Style of a workspace title: one line unless `sidebar.wrapWorkspaceTitles`
/// is on (then word wrap without a line limit).
pub fn titleStyle(t: *const model.TitleLine, r: Resolved) TextStyle {
    var st = textStyle(.title, r);
    if (t.wrap) {
        st.wrap = .word;
        st.max_lines = 0;
    }
    return st;
}

/// Style of a detail line's text: exactly one line for the truncating
/// overflow modes (line breaks included), else word wrap up to
/// `Line.max_lines` (0 = unlimited).
pub fn lineStyle(l: *const model.Line, r: Resolved) TextStyle {
    var st = textStyle(.detail, r);
    switch (l.overflow) {
        .truncate_end, .truncate_start => {
            st.wrap = .none;
            st.max_lines = 1;
        },
        .wrap => {
            st.wrap = .word;
            st.max_lines = l.max_lines;
        },
    }
    return st;
}

/// The style element `e` of `row` was measured with: paint draws its text
/// (or `text_override`) with it.
pub fn elementStyle(row: *const model.Row, e: Element, r: Resolved) TextStyle {
    switch (row.body) {
        .workspace => |*w| switch (e.kind) {
            .title => return titleStyle(&w.title, r),
            .text, .link => if (e.item < w.items.len) switch (w.items[e.item].body) {
                .line => |*l| return lineStyle(l, r),
                else => {},
            },
            else => {},
        },
        .group_header => {},
    }
    return textStyle(e.role, r);
}

pub const ElementKind = enum(u8) {
    /// Workspace/group color rail (full row height at the left edge).
    rail,
    spinner,
    badge,
    unseen_dot,
    pin,
    mute,
    media,
    glyph,
    title,
    close,
    hint,
    /// Detail line icon.
    icon,
    /// Detail line text block.
    text,
    /// Clickable run inside a single-line text block.
    link,
    pill,
    pill_icon,
    pill_text,
    progress_track,
    progress_label,
    chip,
    toggle,
    chevron,
};

pub const Action = enum(u8) {
    none,
    select,
    close,
    open_link,
    toggle_expand,
    toggle_group,
    /// Wrapped text with links: resolve the run under the cursor with the
    /// DirectWrite layout's hit test, then `row_model.runAtOffset`.
    text_links,
};

/// When an element is drawn and hit-testable.
pub const Show = enum(u8) {
    always,
    /// Only while the pointer is over the row (close button).
    hover,
    /// Hidden while the pointer is over the row (trailing badge/spinner).
    not_hover,
    /// Only while the shortcut modifier is held (hint pill).
    modifier_hold,
    /// Like `hover`, but hidden while the shortcut modifier is held: the
    /// close button of a row whose hint pill is drawn over it, so a click
    /// on the visible hint (e.g. a Ctrl/Shift multi-select click) never
    /// closes the workspace.
    hover_no_modifier,

    pub fn visible(self: Show, hovered: bool, modifier_held: bool) bool {
        return switch (self) {
            .always => true,
            .hover => hovered,
            .not_hover => !hovered,
            .modifier_hold => modifier_held,
            .hover_no_modifier => hovered and !modifier_held,
        };
    }
};

pub const no_item: u16 = std.math.maxInt(u16);

pub const Element = struct {
    kind: ElementKind,
    rect: Rect,
    action: Action = .none,
    show: Show = .always,
    role: TextRole = .none,
    /// Index into the row's `items` (no_item for title-line elements).
    item: u16 = no_item,
    /// Sub-index: run, pill, chip, media icon; badge/spinner 0 = leading,
    /// 1 = trailing; toggle = slot value.
    sub: u16 = 0,
    /// Text did not fit (draw with ellipsis; show a tooltip).
    truncated: bool = false,
    /// Display text computed by layout (start-ellipsized paths).
    text_override: ?[]const u8 = null,
};

pub const RowGeom = struct {
    top: f32,
    height: f32,
    kind: model.RowKind,
    elements: []const Element,

    pub fn bottom(self: RowGeom) f32 {
        return self.top + self.height;
    }

    /// Element rectangle in sidebar content coordinates.
    pub fn absRect(self: RowGeom, e: Element) Rect {
        return e.rect.offset(0, self.top);
    }

    pub fn bounds(self: RowGeom, width: f32) Rect {
        return Rect.xywh(0, self.top, width, self.height);
    }
};

pub const Layout = struct {
    rows: []RowGeom,
    content_height: f32,
    width: f32,
    dpi: Dpi,
};

// ─── Measuring helpers ──────────────────────────────────────────────────

const Ctx = struct {
    arena: Allocator,
    m: TextMeasurer,
    r: Resolved,
    scale: f32,
    width: f32,
    out: std.ArrayList(Element) = .empty,

    fn measure(self: *Ctx, text: []const u8, style: *const TextStyle, max_w: f32) text_style.TextExtent {
        return self.m.measure(text, style, max_w);
    }

    fn lineHeight(self: *Ctx, role: TextRole) f32 {
        const st = textStyle(role, self.r);
        const e = self.measure("Ag", &st, std.math.inf(f32));
        return if (e.height > 0) e.height else st.size * 1.25;
    }

    fn textWidth(self: *Ctx, role: TextRole, text: []const u8) f32 {
        const st = textStyle(role, self.r);
        return self.measure(text, &st, std.math.inf(f32)).width;
    }

    fn add(self: *Ctx, e: Element) Allocator.Error!void {
        var el = e;
        el.rect = geometry.snapRect(e.rect, self.scale);
        try self.out.append(self.arena, el);
    }
};

/// `text` shortened at the end so `text ++ "…"` fits `max_w`; returns
/// `text` unchanged when it fits. Cuts on code-point boundaries.
pub fn ellipsizeEnd(arena: Allocator, m: TextMeasurer, text: []const u8, style: *const TextStyle, max_w: f32) Allocator.Error![]const u8 {
    var st = style.*;
    st.wrap = .none;
    st.max_lines = 0;
    const inf = std.math.inf(f32);
    if (m.measure(text, &st, inf).width <= max_w) return text;
    const bounds = try boundaries(arena, text);
    // Largest prefix length (in boundaries) that fits with the ellipsis.
    var lo: usize = 0;
    var hi: usize = bounds.len - 1;
    var buf: std.ArrayList(u8) = .empty;
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        buf.clearRetainingCapacity();
        try buf.appendSlice(arena, text[0..bounds[mid]]);
        try buf.appendSlice(arena, ellipsis);
        if (m.measure(buf.items, &st, inf).width <= max_w) lo = mid else hi = mid - 1;
    }
    return std.mem.concat(arena, u8, &.{ text[0..bounds[lo]], ellipsis });
}

/// `text` shortened from the start, keeping the end visible: prefers
/// "…/" + whole trailing path segments ('/' or '\\'), else "…" + the
/// longest code-point suffix that fits. Returns `text` when it fits.
pub fn ellipsizeStart(arena: Allocator, m: TextMeasurer, text: []const u8, style: *const TextStyle, max_w: f32) Allocator.Error![]const u8 {
    var st = style.*;
    st.wrap = .none;
    st.max_lines = 0;
    const inf = std.math.inf(f32);
    if (m.measure(text, &st, inf).width <= max_w) return text;
    // Path segments: try the longest suffix after a separator first.
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '/' and text[i] != '\\') continue;
        if (i + 1 >= text.len) break;
        const cand = try std.mem.concat(arena, u8, &.{ ellipsis, text[i..] });
        if (m.measure(cand, &st, inf).width <= max_w) return cand;
    }
    const bounds = try boundaries(arena, text);
    // Smallest start boundary whose suffix fits after the ellipsis.
    var lo: usize = 0;
    var hi: usize = bounds.len - 1;
    var buf: std.ArrayList(u8) = .empty;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        buf.clearRetainingCapacity();
        try buf.appendSlice(arena, ellipsis);
        try buf.appendSlice(arena, text[bounds[mid]..]);
        if (m.measure(buf.items, &st, inf).width <= max_w) hi = mid else lo = mid + 1;
    }
    return std.mem.concat(arena, u8, &.{ ellipsis, text[bounds[lo]..] });
}

/// Byte offsets of every code-point boundary, including 0 and len.
fn boundaries(arena: Allocator, text: []const u8) Allocator.Error![]usize {
    var list: std.ArrayList(usize) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        try list.append(arena, i);
        i += utf16_map.decodeLossy(text, i).len;
    }
    try list.append(arena, text.len);
    return list.items;
}

// ─── Row layout ─────────────────────────────────────────────────────────

pub const RowResult = struct {
    height: f32,
    elements: []Element,
};

/// Lay out one row at y = 0. Elements and override strings go to `arena`.
pub fn layoutRow(arena: Allocator, row: *const model.Row, m: TextMeasurer, params: Params) Allocator.Error!RowResult {
    const scale = params.dpi.scale();
    var cx: Ctx = .{
        .arena = arena,
        .m = m,
        .r = params.metrics.resolve(),
        .scale = scale,
        .width = sanitizeWidth(params.width),
    };
    const raw_h = switch (row.body) {
        .workspace => |*w| try layoutWorkspace(&cx, w),
        .group_header => |*g| try layoutGroup(&cx, g),
    };
    // Whole device pixels, rounded up so content is never clipped.
    const h = @ceil(raw_h * scale - 0.001) / scale;
    // Rails span the final height.
    for (cx.out.items) |*e| if (e.kind == .rail) {
        e.rect.bottom = h;
    };
    return .{ .height = h, .elements = cx.out.items };
}

fn sanitizeWidth(w: f32) f32 {
    if (!std.math.isFinite(w) or w < 0) return 0;
    return w;
}

fn layoutGroup(cx: *Ctx, g: *const model.GroupHeaderRow) Allocator.Error!f32 {
    const r = cx.r;
    const lh = cx.lineHeight(.header);
    const box = @max(lh, r.icon);
    const y0 = r.header_pad_top;
    const cy = y0 + box / 2;
    var x = r.pad_x;
    const right = @max(cx.width - r.pad_x, x);
    if (g.color != null) try cx.add(.{ .kind = .rail, .rect = Rect.xywh(0, 0, r.rail_w, 0) });
    try cx.add(.{ .kind = .chevron, .rect = iconBox(x, cy, r.icon), .action = .toggle_group });
    x += r.icon + r.gap;
    if (g.pinned) {
        try cx.add(.{ .kind = .pin, .rect = iconBox(x, cy, r.icon) });
        x += r.icon + r.gap;
    }
    var title_right = right;
    if (g.badge) |b| {
        const br = badgeBox(cx, right, cy, b);
        try cx.add(.{ .kind = .badge, .rect = br, .role = .badge, .sub = 1 });
        title_right = br.left - r.gap;
    }
    const st = textStyle(.header, r);
    const avail = @max(title_right - x, 0);
    const ext = cx.measure(g.title, &st, avail);
    try cx.add(.{ .kind = .title, .rect = Rect.xywh(x, cy - lh / 2, avail, lh), .role = .header, .truncated = ext.truncated });
    return y0 + box + r.header_pad_bottom;
}

fn iconBox(x: f32, cy: f32, size: f32) Rect {
    return Rect.xywh(x, cy - size / 2, size, size);
}

/// Badge right-aligned at `right` (circle for short counts).
fn badgeBox(cx: *Ctx, right: f32, cy: f32, label: []const u8) Rect {
    const w = cx.textWidth(.badge, label);
    return geometry.badgeRect(right, cy, w, cx.r.badge_h, cx.r.badge_pad);
}

fn layoutWorkspace(cx: *Ctx, w: *const model.WorkspaceRow) Allocator.Error!f32 {
    const r = cx.r;
    const t = &w.title;
    const lh = cx.lineHeight(.title);
    const box = @max(lh, @max(r.badge_h, r.icon));
    const y0 = r.pad_top;
    const cy = y0 + box / 2;
    var x = r.pad_x;
    const right = @max(cx.width - r.pad_x, x);

    if (w.rail != null) try cx.add(.{ .kind = .rail, .rect = Rect.xywh(0, 0, r.rail_w, 0) });

    // Leading slot.
    if (t.leading.spinner) {
        try cx.add(.{ .kind = .spinner, .rect = iconBox(x, cy, r.icon), .sub = 0 });
        x += r.icon + r.gap;
    }
    if (t.leading.badge) |b| {
        const lw = cx.textWidth(.badge, b);
        const bw = @max(r.badge_h, lw + 2 * r.badge_pad);
        try cx.add(.{ .kind = .badge, .rect = Rect.xywh(x, cy - r.badge_h / 2, bw, r.badge_h), .role = .badge, .sub = 0 });
        x += bw + r.gap;
    }
    if (t.leading.unseen_dot) {
        try cx.add(.{ .kind = .unseen_dot, .rect = iconBox(x, cy, r.dot) });
        x += r.dot + r.gap;
    }
    if (t.pinned) {
        try cx.add(.{ .kind = .pin, .rect = iconBox(x, cy, r.icon) });
        x += r.icon + r.gap;
    }
    if (t.muted) {
        try cx.add(.{ .kind = .mute, .rect = iconBox(x, cy, r.icon) });
        x += r.icon + r.gap;
    }
    for (t.media, 0..) |_, i| {
        try cx.add(.{ .kind = .media, .rect = iconBox(x, cy, r.icon), .sub = @intCast(@min(i, no_item - 1)) });
        x += r.icon + r.gap;
    }
    if (t.glyph != null) {
        try cx.add(.{ .kind = .glyph, .rect = iconBox(x, cy, r.icon) });
        x += r.icon + r.gap;
    }

    // Trailing slot: badge/spinner hide on hover, the close button shows.
    var reserve: f32 = 0;
    var tx = right;
    if (t.trailing.badge) |b| {
        const br = badgeBox(cx, tx, cy, b);
        try cx.add(.{ .kind = .badge, .rect = br, .role = .badge, .sub = 1, .show = .not_hover });
        tx = br.left - r.gap;
        reserve = right - br.left;
    }
    if (t.trailing.spinner) {
        const sr = Rect.xywh(tx - r.icon, cy - r.icon / 2, r.icon, r.icon);
        try cx.add(.{ .kind = .spinner, .rect = sr, .sub = 1, .show = .not_hover });
        reserve = right - sr.left;
    }
    if (t.trailing.close) {
        // The hint pill below overlays the trailing area without reserving
        // width; while it shows, the close button under it is hidden.
        const show: Show = if (t.hint != null) .hover_no_modifier else .hover;
        try cx.add(.{ .kind = .close, .rect = Rect.xywh(right - r.close, cy - r.close / 2, r.close, r.close), .action = .close, .show = show });
        reserve = @max(reserve, r.close);
    }
    if (t.hint) |hint| {
        const hw = cx.textWidth(.hint, hint) + 2 * r.badge_pad;
        const hh = r.badge_h;
        try cx.add(.{ .kind = .hint, .rect = Rect.xywh(right - hw, cy - hh / 2, hw, hh), .role = .hint, .show = .modifier_hold });
    }

    // Title.
    const st = titleStyle(t, r);
    const title_right = if (reserve > 0) right - reserve - r.gap else right;
    const avail = @max(title_right - x, 0);
    const ext = cx.measure(t.title, &st, avail);
    const th = @max(ext.height, lh);
    const title_top = cy - lh / 2;
    try cx.add(.{ .kind = .title, .rect = Rect.xywh(x, title_top, avail, th), .role = .title, .truncated = ext.truncated });
    var y = @max(y0 + box, title_top + th);

    // Detail items.
    const left = r.pad_x;
    for (w.items, 0..) |*it, idx| {
        y += r.line_gap;
        const item: u16 = @intCast(@min(idx, no_item - 1));
        const h = switch (it.body) {
            .line => |*l| try layoutLine(cx, l, item, left, right, y),
            .pills => |ps| try layoutPills(cx, ps, item, left, right, y),
            .chips => |cs| try layoutChips(cx, cs, item, left, right, y),
            .progress => |*p| try layoutProgress(cx, p, item, left, right, y),
            .toggle => |*tg| try layoutToggle(cx, tg, item, left, right, y),
        };
        y += h;
    }
    return y + r.pad_bottom;
}

fn hasRunLinks(runs: []const model.Run) bool {
    for (runs) |run| if (run.link != null) return true;
    return false;
}

fn layoutLine(cx: *Ctx, l: *const model.Line, item: u16, left: f32, right: f32, y: f32) Allocator.Error!f32 {
    const r = cx.r;
    const lh = cx.lineHeight(.detail);
    var x = left;
    if (l.icon != null) {
        try cx.add(.{ .kind = .icon, .rect = Rect.xywh(x, y + (lh - r.detail_icon) / 2, r.detail_icon, r.detail_icon), .item = item });
        x += r.detail_icon + r.gap;
    }
    const st = lineStyle(l, r);
    const avail = @max(right - x, 0);
    const text = try model.joinRuns(cx.arena, l.runs);
    const ext = cx.measure(text, &st, avail);
    var override: ?[]const u8 = null;
    var truncated = ext.truncated;
    if (l.overflow == .truncate_start and ext.truncated and !l.emphasis) {
        override = try ellipsizeStart(cx.arena, cx.m, text, &st, avail);
        truncated = true;
    }
    const h = @max(ext.height, lh);
    const run_links = hasRunLinks(l.runs) and override == null;
    // Per-run link rectangles need all text on one visible line and no run
    // that paint draws wider or narrower than measured here (bold, italic,
    // code). Otherwise the text element gets `text_links` and the app
    // hit-tests its DirectWrite layout.
    const rect_links = run_links and ext.line_count <= 1 and
        std.mem.indexOfScalar(u8, text, '\n') == null and !hasStyledRuns(l.runs);
    const action: Action = if (l.link != null) .open_link else if (run_links and !rect_links) .text_links else .none;
    const text_rect = Rect.xywh(x, y, avail, h);
    try cx.add(.{ .kind = .text, .rect = text_rect, .action = action, .role = .detail, .item = item, .truncated = truncated, .text_override = override });

    if (rect_links and l.link == null) {
        var single = st;
        single.wrap = .none;
        const inf = std.math.inf(f32);
        var end: usize = 0;
        for (l.runs, 0..) |run, i| {
            end += run.text.len;
            if (run.link == null) continue;
            // A link ends where the text through it ends and starts its own
            // width before that. Measuring prefixes, not single runs, keeps
            // the whitespace in front of the link: DirectWrite widths leave
            // out trailing whitespace ("see " measures as "see").
            const lx_end = x + cx.measure(text[0..end], &single, inf).width;
            const lx = @max(lx_end - cx.measure(run.text, &single, inf).width, x);
            if (lx >= text_rect.right) break;
            const lr = Rect{ .left = lx, .top = y, .right = @min(lx_end, text_rect.right), .bottom = y + lh };
            try cx.add(.{ .kind = .link, .rect = lr, .action = .open_link, .role = .detail, .item = item, .sub = @intCast(@min(i, no_item - 1)) });
        }
    }
    return h;
}

fn hasStyledRuns(runs: []const model.Run) bool {
    for (runs) |run| if (run.style.bold or run.style.italic or run.style.code) return true;
    return false;
}

fn flowBoxes(cx: *Ctx, labels: []const Size, pm: geometry.PillMetrics, left: f32, right: f32, y: f32) Allocator.Error!struct { rects: []Rect, height: f32 } {
    const avail = @max(right - left, 0);
    const sizes = try cx.arena.alloc(Size, labels.len);
    for (labels, sizes) |lb, *s| s.* = geometry.layoutPill(.{}, lb, pm, std.math.inf(f32)).bounds.size();
    const rects = try cx.arena.alloc(Rect, labels.len);
    const res = geometry.flow(.{ .x = left, .y = y }, sizes, .{ .max_width = avail, .gap_x = cx.r.flow_gap, .gap_y = cx.r.flow_gap }, rects);
    return .{ .rects = rects[0..res.placed], .height = res.size.h };
}

fn layoutPills(cx: *Ctx, ps: []const model.Pill, item: u16, left: f32, right: f32, y: f32) Allocator.Error!f32 {
    const r = cx.r;
    const st = textStyle(.pill, r);
    const labels = try cx.arena.alloc(Size, ps.len);
    const metrics = try cx.arena.alloc(geometry.PillMetrics, ps.len);
    // Labels cut to one line (a line break) are truncated too.
    const cut = try cx.arena.alloc(bool, ps.len);
    for (ps, labels, metrics, cut) |p, *lb, *pm, *c| {
        const e = cx.measure(p.text, &st, std.math.inf(f32));
        lb.* = .{ .w = e.width, .h = e.height };
        c.* = e.truncated;
        pm.* = r.pill;
        if (p.icon != null) pm.icon = r.detail_icon;
    }
    // Icons widen pills unevenly: flow with each pill's own metrics.
    const sizes = try cx.arena.alloc(Size, ps.len);
    for (labels, metrics, sizes) |lb, pm, *s| s.* = geometry.layoutPill(.{}, lb, pm, std.math.inf(f32)).bounds.size();
    const rects = try cx.arena.alloc(Rect, ps.len);
    const res = geometry.flow(.{ .x = left, .y = y }, sizes, .{ .max_width = @max(right - left, 0), .gap_x = r.flow_gap, .gap_y = r.flow_gap }, rects);
    for (rects[0..res.placed], 0..) |pr, i| {
        const pl = geometry.layoutPill(pr.origin(), labels[i], metrics[i], pr.width());
        const sub: u16 = @intCast(@min(i, no_item - 1));
        try cx.add(.{ .kind = .pill, .rect = pl.bounds, .action = if (ps[i].link != null) .open_link else .none, .item = item, .sub = sub });
        if (pl.icon) |ir| try cx.add(.{ .kind = .pill_icon, .rect = ir, .item = item, .sub = sub });
        try cx.add(.{ .kind = .pill_text, .rect = pl.text, .role = .pill, .item = item, .sub = sub, .truncated = pl.truncated or cut[i] });
    }
    return res.size.h;
}

fn layoutChips(cx: *Ctx, cs: []const model.Chip, item: u16, left: f32, right: f32, y: f32) Allocator.Error!f32 {
    const r = cx.r;
    const st = textStyle(.chip, r);
    const labels = try cx.arena.alloc(Size, cs.len);
    const cut = try cx.arena.alloc(bool, cs.len);
    for (cs, labels, cut) |c, *lb, *k| {
        const e = cx.measure(c.text, &st, std.math.inf(f32));
        lb.* = .{ .w = e.width, .h = e.height };
        k.* = e.truncated;
    }
    const fl = try flowBoxes(cx, labels, r.chip, left, right, y);
    for (fl.rects, 0..) |cr, i| {
        const pl = geometry.layoutPill(cr.origin(), labels[i], r.chip, cr.width());
        try cx.add(.{
            .kind = .chip,
            .rect = pl.bounds,
            .action = if (cs[i].link != null) .open_link else .none,
            .role = .chip,
            .item = item,
            .sub = @intCast(@min(i, no_item - 1)),
            .truncated = pl.truncated or cut[i],
        });
    }
    return fl.height;
}

fn layoutProgress(cx: *Ctx, p: *const model.Progress, item: u16, left: f32, right: f32, y: f32) Allocator.Error!f32 {
    const r = cx.r;
    const avail = @max(right - left, 0);
    const lh = cx.lineHeight(.progress_label);
    var bar_right = right;
    if (p.label) |label| if (label.len > 0) {
        const st = textStyle(.progress_label, r);
        // The label takes at most half the row; the bar keeps the rest.
        const max_label = avail / 2;
        const e = cx.measure(label, &st, max_label);
        const lw = @min(e.width, max_label);
        try cx.add(.{ .kind = .progress_label, .rect = Rect.xywh(right - lw, y, lw, lh), .role = .progress_label, .item = item, .truncated = e.truncated });
        bar_right = right - lw - r.gap;
    };
    const h = @max(lh, r.progress_h);
    try cx.add(.{ .kind = .progress_track, .rect = Rect{ .left = left, .top = y + (h - r.progress_h) / 2, .right = @max(bar_right, left), .bottom = y + (h + r.progress_h) / 2 }, .item = item });
    return h;
}

fn layoutToggle(cx: *Ctx, tg: *const model.Toggle, item: u16, left: f32, right: f32, y: f32) Allocator.Error!f32 {
    const st = textStyle(.toggle, cx.r);
    const avail = @max(right - left, 0);
    const e = cx.measure(tg.label, &st, avail);
    const lh = @max(e.height, cx.lineHeight(.toggle));
    try cx.add(.{
        .kind = .toggle,
        .rect = Rect.xywh(left, y, @min(e.width, avail), lh),
        .action = .toggle_expand,
        .role = .toggle,
        .item = item,
        .sub = @intFromEnum(tg.slot),
        .truncated = e.truncated,
    });
    return lh;
}

// ─── Whole list + cache ─────────────────────────────────────────────────

/// Per-row layout cache (ADR-11.2): keyed by content hash, width, DPI and
/// metrics. Owns its entries; `Layout`s copy out of it, so eviction never
/// invalidates a layout already returned.
pub const Cache = struct {
    const Entry = struct {
        height: f32,
        elements: []Element,
        /// Owns the elements and their override strings.
        arena: std.heap.ArenaAllocator,
    };

    lru: lru.LruCache(*Entry),
    gpa: Allocator,

    pub fn init(gpa: Allocator, capacity: usize) Cache {
        return .{ .lru = lru.LruCache(*Entry).init(gpa, capacity, null, evict), .gpa = gpa };
    }

    /// Entries own their arena, so eviction needs no context.
    fn evict(_: ?*anyopaque, e: *Entry) void {
        const child = e.arena.child_allocator;
        e.arena.deinit();
        child.destroy(e);
    }

    pub fn deinit(self: *Cache) void {
        self.lru.deinit();
    }

    /// Drop everything (font family or theme metric change).
    pub fn clear(self: *Cache) void {
        self.lru.clear();
    }

    pub fn count(self: *const Cache) usize {
        return self.lru.count();
    }

    fn key(row: *const model.Row, params: Params) [24]u8 {
        var k: [24]u8 = undefined;
        std.mem.writeInt(u64, k[0..8], row.content_hash, .little);
        const w = sanitizeWidth(params.width);
        std.mem.writeInt(u32, k[8..12], @bitCast(w), .little);
        std.mem.writeInt(u32, k[12..16], params.dpi.value, .little);
        std.mem.writeInt(u64, k[16..24], params.metrics.hash(), .little);
        return k;
    }

    fn lookup(self: *Cache, row: *const model.Row, params: Params) ?*Entry {
        const k = key(row, params);
        return self.lru.get(&k);
    }

    fn store(self: *Cache, row: *const model.Row, params: Params, res: RowResult) Allocator.Error!void {
        const e = try self.gpa.create(Entry);
        e.arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer evict(null, e);
        e.height = res.height;
        e.elements = try copyElements(e.arena.allocator(), res.elements);
        const k = key(row, params);
        try self.lru.put(&k, e);
    }
};

fn copyElements(a: Allocator, src: []const Element) Allocator.Error![]Element {
    const out = try a.dupe(Element, src);
    for (out) |*e| if (e.text_override) |s| {
        e.text_override = try a.dupe(u8, s);
    };
    return out;
}

/// Lay out every row (variable heights; tops accumulate on the pixel
/// grid). Results live in `arena`; `cache` (optional) skips re-measuring
/// unchanged rows.
pub fn layoutRows(arena: Allocator, cache: ?*Cache, rows: []const model.Row, m: TextMeasurer, params: Params) Allocator.Error!Layout {
    const geoms = try arena.alloc(RowGeom, rows.len);
    var top: f32 = 0;
    for (rows, geoms) |*row, *g| {
        var height: f32 = undefined;
        var elements: []const Element = undefined;
        if (cache) |c| {
            if (c.lookup(row, params)) |hit| {
                height = hit.height;
                elements = try copyElements(arena, hit.elements);
            } else {
                var scratch = std.heap.ArenaAllocator.init(c.gpa);
                defer scratch.deinit();
                const res = try layoutRow(scratch.allocator(), row, m, params);
                try c.store(row, params, res);
                height = res.height;
                elements = try copyElements(arena, res.elements);
            }
        } else {
            const res = try layoutRow(arena, row, m, params);
            height = res.height;
            elements = res.elements;
        }
        g.* = .{ .top = top, .height = height, .kind = row.kind(), .elements = elements };
        top += height;
    }
    return .{ .rows = geoms, .content_height = top, .width = sanitizeWidth(params.width), .dpi = params.dpi };
}

// ─── Resolving element content ──────────────────────────────────────────

pub const ElementText = union(enum) {
    none,
    plain: []const u8,
    runs: []const model.Run,
};

/// Text an element draws (paint, tooltips, snapshot).
pub fn elementText(row: *const model.Row, e: Element) ElementText {
    if (e.text_override) |s| return .{ .plain = s };
    switch (row.body) {
        .group_header => |g| return switch (e.kind) {
            .title => .{ .plain = g.title },
            .badge => if (g.badge) |b| .{ .plain = b } else .none,
            else => .none,
        },
        .workspace => |w| {
            const t = &w.title;
            switch (e.kind) {
                .title => return .{ .plain = t.title },
                .badge => {
                    const b = if (e.sub == 0) t.leading.badge else t.trailing.badge;
                    return if (b) |s| .{ .plain = s } else .none;
                },
                .hint => return if (t.hint) |h| .{ .plain = h } else .none,
                else => {},
            }
            if (e.item >= w.items.len) return .none;
            const it = w.items[e.item];
            return switch (it.body) {
                .line => |l| switch (e.kind) {
                    .text => .{ .runs = l.runs },
                    .link => if (e.sub < l.runs.len) .{ .plain = l.runs[e.sub].text } else .none,
                    else => .none,
                },
                .pills => |ps| if (e.kind == .pill_text and e.sub < ps.len) .{ .plain = ps[e.sub].text } else .none,
                .chips => |cs| if (e.kind == .chip and e.sub < cs.len) .{ .plain = cs[e.sub].text } else .none,
                .progress => |p| if (e.kind == .progress_label) (if (p.label) |s| ElementText{ .plain = s } else .none) else .none,
                .toggle => |tg| if (e.kind == .toggle) .{ .plain = tg.label } else .none,
            };
        },
    }
}

/// Link an element opens (null when it has none).
pub fn elementLink(row: *const model.Row, e: Element) ?[]const u8 {
    const w = switch (row.body) {
        .workspace => |w| w,
        .group_header => return null,
    };
    if (e.item >= w.items.len) return null;
    return switch (w.items[e.item].body) {
        .line => |l| switch (e.kind) {
            .text => l.link,
            .link => if (e.sub < l.runs.len) l.runs[e.sub].link else null,
            else => null,
        },
        .pills => |ps| if (e.sub < ps.len) ps[e.sub].link else null,
        .chips => |cs| if (e.sub < cs.len) cs[e.sub].link else null,
        else => null,
    };
}

/// Tooltip for an element: explicit tooltips, else the full text of
/// truncated elements (ADR-11.4: tooltips only for truncated text).
pub fn elementTooltip(arena: Allocator, row: *const model.Row, e: Element) Allocator.Error!?[]const u8 {
    switch (row.body) {
        .workspace => |w| {
            if (e.kind == .glyph) if (w.title.glyph) |g| return g.tooltip;
            if (e.kind == .mute) return "Notifications muted for this workspace";
            if (e.item < w.items.len) switch (w.items[e.item].body) {
                .line => |l| if (l.tooltip) |t| return t,
                .pills => |ps| if (e.sub < ps.len) if (ps[e.sub].tooltip) |t| return t,
                .chips => |cs| if (e.sub < cs.len) if (cs[e.sub].tooltip) |t| return t,
                else => {},
            };
        },
        .group_header => {},
    }
    if (!e.truncated) return null;
    if (e.text_override != null) {
        // Show the original, not the ellipsized display text.
        var plain = e;
        plain.text_override = null;
        return elementTooltip(arena, row, plain);
    }
    return switch (elementText(row, e)) {
        .none => null,
        .plain => |s| s,
        .runs => |runs| try model.joinRuns(arena, runs),
    };
}

// ─── Debug snapshot (wmux.debug.sidebar.snapshot) ───────────────────────

fn rowKindName(k: model.RowKind) []const u8 {
    return @tagName(k);
}

/// JSON of the row model and geometry (assert data, not pixels).
pub fn writeSnapshot(arena: Allocator, w: *std.Io.Writer, rows: []const model.Row, layout: Layout) (std.Io.Writer.Error || Allocator.Error)!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("width");
    try s.write(layout.width);
    try s.objectField("dpi");
    try s.write(layout.dpi.value);
    try s.objectField("content_height");
    try s.write(layout.content_height);
    try s.objectField("rows");
    try s.beginArray();
    for (rows, layout.rows) |*row, g| {
        try s.beginObject();
        try s.objectField("kind");
        try s.write(rowKindName(row.kind()));
        try s.objectField("id");
        const id_text = row.id().toText();
        try s.write(@as([]const u8, &id_text));
        try s.objectField("top");
        try s.write(g.top);
        try s.objectField("height");
        try s.write(g.height);
        try s.objectField("elements");
        try s.beginArray();
        for (g.elements) |e| {
            try s.beginObject();
            try s.objectField("kind");
            try s.write(@tagName(e.kind));
            try s.objectField("rect");
            try s.write([4]f32{ e.rect.left, e.rect.top + g.top, e.rect.right, e.rect.bottom + g.top });
            if (e.action != .none) {
                try s.objectField("action");
                try s.write(@tagName(e.action));
            }
            if (e.show != .always) {
                try s.objectField("show");
                try s.write(@tagName(e.show));
            }
            if (e.truncated) {
                try s.objectField("truncated");
                try s.write(true);
            }
            switch (elementText(row, e)) {
                .none => {},
                .plain => |t| {
                    try s.objectField("text");
                    try s.write(t);
                },
                .runs => |runs| {
                    try s.objectField("text");
                    try s.write(try model.joinRuns(arena, runs));
                },
            }
            if (elementLink(row, e)) |l| {
                try s.objectField("link");
                try s.write(l);
            }
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

/// Compact text dump of a layout for golden tests.
pub fn dumpLayout(w: *std.Io.Writer, rows: []const model.Row, layout: Layout) std.Io.Writer.Error!void {
    try w.print("content {d:.2}\n", .{layout.content_height});
    for (rows, layout.rows, 0..) |*row, g, i| {
        try w.print("row {d} {s} top={d:.2} h={d:.2}\n", .{ i, rowKindName(row.kind()), g.top, g.height });
        for (g.elements) |e| {
            try w.print("  {s} [{d:.2} {d:.2} {d:.2} {d:.2}]", .{ @tagName(e.kind), e.rect.left, e.rect.top, e.rect.right, e.rect.bottom });
            if (e.action != .none) try w.print(" {s}", .{@tagName(e.action)});
            if (e.show != .always) try w.print(" show={s}", .{@tagName(e.show)});
            if (e.truncated) try w.writeAll(" trunc");
            if (e.text_override) |s| try w.print(" \"{s}\"", .{s});
            try w.writeByte('\n');
        }
    }
}
