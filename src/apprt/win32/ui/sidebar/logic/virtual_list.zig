//! Pure sidebar list behavior (ARCHITECTURE ADR-11.2 step 4, ADR-11.4):
//! scroll offset and clamping, visible-range virtualization, wheel deltas,
//! the overlay scroll thumb, keyboard focus mode, hit testing, selection on
//! mouse-up with drag detection, drop insertion and auto-scroll.
//!
//! Works on `row_layout.RowGeom` slices (content coordinates in DIPs; the
//! viewport top is `Scroll.offset`). No Win32: the sidebar HWND feeds in
//! points, keys and timestamps.
const std = @import("std");
const geometry = @import("../../gfx/logic/geometry.zig");
const layout = @import("row_layout.zig");
const model = @import("row_model.zig");

const Rect = geometry.Rect;
const Point = geometry.Point;
pub const RowGeom = layout.RowGeom;

// ─── Visible range and row lookup ───────────────────────────────────────

/// Half-open row index range.
pub const Range = struct {
    start: usize,
    end: usize,

    pub fn len(self: Range) usize {
        return self.end - self.start;
    }

    pub fn contains(self: Range, i: usize) bool {
        return i >= self.start and i < self.end;
    }
};

/// First row whose bottom is below `y` (binary search; rows are sorted and
/// contiguous). Returns rows.len when `y` is past the content.
fn firstEndingAfter(rows: []const RowGeom, y: f32) usize {
    var lo: usize = 0;
    var hi: usize = rows.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (rows[mid].bottom() <= y) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Rows intersecting [offset, offset + viewport): the only rows paint
/// touches.
pub fn visibleRange(rows: []const RowGeom, offset: f32, viewport: f32) Range {
    if (rows.len == 0 or !(viewport > 0)) return .{ .start = 0, .end = 0 };
    const top = if (std.math.isNan(offset)) 0 else offset;
    const start = firstEndingAfter(rows, top);
    var end = start;
    const bottom = top + viewport;
    while (end < rows.len and rows[end].top < bottom) end += 1;
    return .{ .start = start, .end = end };
}

/// Row containing content y (half-open: a boundary belongs to the lower row).
pub fn rowAtY(rows: []const RowGeom, y: f32) ?usize {
    if (std.math.isNan(y) or y < 0) return null;
    const i = firstEndingAfter(rows, y);
    if (i >= rows.len or y < rows[i].top) return null;
    return i;
}

// ─── Hit testing ────────────────────────────────────────────────────────

pub const Hit = struct {
    row: usize,
    /// Element index within the row; null = the row background.
    element: ?usize,
    action: layout.Action,
};

pub const PointerState = struct {
    /// Row under the pointer (drives hover-only elements).
    hovered_row: ?usize = null,
    modifier_held: bool = false,
};

/// Element under content point `p`. Topmost (last laid out) visible
/// element with an action wins; otherwise the row itself (workspace rows
/// select, group headers toggle collapse). Points outside the sidebar's
/// width or below the last row return null.
pub fn hitTest(rows: []const RowGeom, width: f32, p: Point, state: PointerState) ?Hit {
    if (!(p.x >= 0 and p.x < width)) return null;
    const ri = rowAtY(rows, p.y) orelse return null;
    const g = rows[ri];
    const local: Point = .{ .x = p.x, .y = p.y - g.top };
    const hovered = state.hovered_row != null and state.hovered_row.? == ri;
    var i = g.elements.len;
    while (i > 0) {
        i -= 1;
        const e = g.elements[i];
        if (e.action == .none) continue;
        if (!e.show.visible(hovered, state.modifier_held)) continue;
        if (e.rect.contains(local)) return .{ .row = ri, .element = i, .action = e.action };
    }
    return .{ .row = ri, .element = null, .action = switch (g.kind) {
        .workspace => .select,
        .group_header => .toggle_group,
    } };
}

/// Element whose rectangle contains `p` regardless of action (tooltips:
/// truncated titles, glyphs, mute icon).
pub fn elementAt(rows: []const RowGeom, p: Point, state: PointerState) ?struct { row: usize, element: usize } {
    const ri = rowAtY(rows, p.y) orelse return null;
    const g = rows[ri];
    const local: Point = .{ .x = p.x, .y = p.y - g.top };
    const hovered = state.hovered_row != null and state.hovered_row.? == ri;
    var i = g.elements.len;
    while (i > 0) {
        i -= 1;
        const e = g.elements[i];
        if (e.kind == .rail) continue;
        if (!e.show.visible(hovered, state.modifier_held)) continue;
        if (e.rect.contains(local)) return .{ .row = ri, .element = i };
    }
    return null;
}

// ─── Scrolling ──────────────────────────────────────────────────────────

pub const Scroll = struct {
    /// Content y at the viewport top.
    offset: f32 = 0,
    content: f32 = 0,
    viewport: f32 = 0,

    pub fn maxOffset(self: Scroll) f32 {
        return @max(self.content - self.viewport, 0);
    }

    /// The scrollbar is hidden when the content fits.
    pub fn scrollable(self: Scroll) bool {
        return self.content > self.viewport + 0.01;
    }

    /// New content/viewport size. The offset is kept (closing workspaces
    /// keeps the scroll position) and only re-clamped.
    pub fn resize(self: *Scroll, content: f32, viewport: f32) void {
        self.content = if (std.math.isFinite(content)) @max(content, 0) else 0;
        self.viewport = if (std.math.isFinite(viewport)) @max(viewport, 0) else 0;
        self.offset = geometry.clampScroll(self.offset, self.content, self.viewport);
    }

    /// Returns true when the offset changed.
    pub fn scrollTo(self: *Scroll, offset: f32) bool {
        const next = geometry.clampScroll(offset, self.content, self.viewport);
        const changed = next != self.offset;
        self.offset = next;
        return changed;
    }

    pub fn scrollBy(self: *Scroll, delta: f32) bool {
        if (!std.math.isFinite(delta)) return false;
        return self.scrollTo(self.offset + delta);
    }

    /// Scroll the minimum needed to show row `index` (ensureRowVisible).
    pub fn ensureVisible(self: *Scroll, rows: []const RowGeom, index: usize) bool {
        if (index >= rows.len) return false;
        const g = rows[index];
        return self.scrollTo(geometry.scrollToReveal(self.offset, self.viewport, g.top, g.bottom()));
    }

    pub fn visible(self: Scroll, rows: []const RowGeom) Range {
        return visibleRange(rows, self.offset, self.viewport);
    }

    /// Viewport point (relative to the sidebar client top) to content.
    pub fn toContent(self: Scroll, p: Point) Point {
        return .{ .x = p.x, .y = p.y + self.offset };
    }
};

/// `WHEEL_DELTA` (one detent).
pub const wheel_delta: i32 = 120;
/// `SPI_GETWHEELSCROLLLINES` value meaning "one page per detent".
pub const wheel_page_scroll: u32 = std.math.maxInt(u32);

/// Content offset change for a `WM_MOUSEWHEEL` delta (positive = wheel
/// away from the user = scroll up = negative offset change). High-resolution
/// wheels send fractions of 120 and scroll proportionally (smooth deltas).
pub fn wheelOffsetDelta(delta: i32, lines_per_notch: u32, line_height: f32, viewport: f32) f32 {
    if (delta == 0 or lines_per_notch == 0) return 0;
    const notches = @as(f32, @floatFromInt(delta)) / @as(f32, @floatFromInt(wheel_delta));
    const per_notch: f32 = if (lines_per_notch == wheel_page_scroll)
        @max(viewport, 0)
    else
        @as(f32, @floatFromInt(lines_per_notch)) * @max(line_height, 0);
    return -notches * per_notch;
}

/// Exponential smoothing toward a target offset for animated scrolling
/// (disabled when `SPI_GETCLIENTAREAANIMATION` is off: jump instead).
pub const SmoothScroll = struct {
    target: f32 = 0,
    /// Time constant in ms; ~63% of the remaining distance per tau.
    tau_ms: f32 = 60,

    /// Next offset after `dt_ms`; snaps when within half a device pixel.
    pub fn step(self: SmoothScroll, current: f32, dt_ms: f32, scale: f32) f32 {
        if (!(dt_ms > 0)) return current;
        const k = 1 - @exp(-dt_ms / @max(self.tau_ms, 1));
        const next = current + (self.target - current) * k;
        if (@abs(self.target - next) * @max(scale, 0.1) < 0.5) return self.target;
        return next;
    }

    pub fn done(self: SmoothScroll, current: f32) bool {
        return current == self.target;
    }
};

/// Overlay scroll thumb in `track` (viewport coordinates), or null when the
/// content fits. The thumb is at least `min_thumb` long.
pub fn thumbRect(track: Rect, s: Scroll, min_thumb: f32) ?Rect {
    if (!s.scrollable() or track.isEmpty()) return null;
    const th = track.height();
    const len = std.math.clamp(th * s.viewport / s.content, @min(min_thumb, th), th);
    const max_off = s.maxOffset();
    const frac = if (max_off > 0) s.offset / max_off else 0;
    const top = track.top + (th - len) * frac;
    return .{ .left = track.left, .top = top, .right = track.right, .bottom = top + len };
}

/// Show-while-scrolling fade of the overlay thumb.
pub const IndicatorFade = struct {
    last_activity_ms: ?i64 = null,
    hold_ms: i64 = 700,
    fade_ms: i64 = 300,

    pub fn poke(self: *IndicatorFade, now_ms: i64) void {
        self.last_activity_ms = now_ms;
    }

    /// Opacity in [0, 1].
    pub fn alpha(self: IndicatorFade, now_ms: i64) f32 {
        const t0 = self.last_activity_ms orelse return 0;
        const dt = now_ms - t0;
        if (dt < 0) return 1;
        if (dt <= self.hold_ms) return 1;
        const f = dt - self.hold_ms;
        if (f >= self.fade_ms or self.fade_ms <= 0) return 0;
        return 1 - @as(f32, @floatFromInt(f)) / @as(f32, @floatFromInt(self.fade_ms));
    }

    /// Whether the fade timer must keep running.
    pub fn animating(self: IndicatorFade, now_ms: i64) bool {
        return self.alpha(now_ms) > 0;
    }
};

// ─── Keyboard focus mode ────────────────────────────────────────────────

pub const Key = enum { up, down, page_up, page_down, home, end, enter, escape, f2, other };

pub const Command = union(enum) {
    none,
    /// Move the focus ring to this row (and scroll it into view).
    focus: usize,
    /// Enter: select the workspace and focus its pane, or toggle a group.
    activate: usize,
    /// Esc: return focus to the terminal.
    exit,
    /// F2: rename the row's workspace or group.
    rename: usize,
    /// Ctrl+Up/Down: move the row by one.
    reorder: struct { index: usize, up: bool },
};

pub const FocusMove = enum { up, down, page_up, page_down, home, end };

/// New focus row. With no current focus, Down/Home start at the first row
/// and Up/End at the last. Page moves go by viewport height. Clamps at the
/// ends (no wrap).
pub fn moveFocus(rows: []const RowGeom, current: ?usize, move: FocusMove, viewport: f32) ?usize {
    if (rows.len == 0) return null;
    const last = rows.len - 1;
    const cur = current orelse return switch (move) {
        .down, .home, .page_down => 0,
        .up, .end, .page_up => last,
    };
    const c = @min(cur, last);
    return switch (move) {
        .up => if (c == 0) 0 else c - 1,
        .down => @min(c + 1, last),
        .home => 0,
        .end => last,
        .page_down => blk: {
            const target = rows[c].top + @max(viewport, 0);
            const i = rowAtY(rows, target) orelse last;
            break :blk @max(@min(i, last), @min(c + 1, last));
        },
        .page_up => blk: {
            const target = rows[c].top - @max(viewport, 0);
            const i = if (target <= 0) 0 else (rowAtY(rows, target) orelse 0);
            break :blk @min(i, if (c == 0) 0 else c - 1);
        },
    };
}

/// Focus-mode key handling (ADR-11.4): Up/Down move, Enter activates, Esc
/// exits, F2 renames, Ctrl+Up/Down reorders (workspace rows only).
pub fn handleKey(rows: []const RowGeom, focus: ?usize, key: Key, ctrl: bool, viewport: f32) Command {
    switch (key) {
        .escape => return .exit,
        .other => return .none,
        .enter => return if (validFocus(rows, focus)) |f| .{ .activate = f } else .none,
        .f2 => return if (validFocus(rows, focus)) |f| .{ .rename = f } else .none,
        .up, .down => if (ctrl) {
            const f = validFocus(rows, focus) orelse return .none;
            if (rows[f].kind != .workspace) return .none;
            const up = key == .up;
            if ((up and f == 0) or (!up and f + 1 >= rows.len)) return .none;
            return .{ .reorder = .{ .index = f, .up = up } };
        },
        else => {},
    }
    const move: FocusMove = switch (key) {
        .up => .up,
        .down => .down,
        .page_up => .page_up,
        .page_down => .page_down,
        .home => .home,
        .end => .end,
        else => unreachable,
    };
    const next = moveFocus(rows, focus, move, viewport) orelse return .none;
    return .{ .focus = next };
}

fn validFocus(rows: []const RowGeom, focus: ?usize) ?usize {
    const f = focus orelse return null;
    return if (f < rows.len) f else null;
}

// ─── Mouse: selection on mouse-up, drag, drop ───────────────────────────

/// Selection lands on mouse-up (ADR-11.4): a press that turns into a drag
/// or is cancelled (Esc, capture lost, released elsewhere) never selects.
pub const PressTracker = struct {
    pub const State = enum { idle, pressed, dragging };

    state: State = .idle,
    row: usize = 0,
    start: Point = .{},
    /// Movement (DIPs) that turns a press into a drag (SM_CXDRAG / DPI).
    threshold: f32 = 4,

    pub const Outcome = union(enum) {
        none,
        /// Click completed on the pressed row: select it.
        select: usize,
        /// Drag finished: move `row` to insertion index `to`.
        drop: struct { row: usize, to: usize },
    };

    /// Button down on `row` (null = empty area: nothing to track).
    pub fn press(self: *PressTracker, row: ?usize, p: Point) void {
        if (row) |r| {
            self.state = .pressed;
            self.row = r;
            self.start = p;
        } else self.state = .idle;
    }

    /// Pointer moved; returns true when a drag starts on this move.
    pub fn move(self: *PressTracker, p: Point) bool {
        if (self.state != .pressed) return false;
        if (@abs(p.x - self.start.x) > self.threshold or @abs(p.y - self.start.y) > self.threshold) {
            self.state = .dragging;
            return true;
        }
        return false;
    }

    /// Button up. `row_here` is the row under the pointer; `insertion` the
    /// drop index (only used when dragging).
    pub fn release(self: *PressTracker, row_here: ?usize, insertion: ?usize) Outcome {
        defer self.state = .idle;
        return switch (self.state) {
            .idle => .none,
            .pressed => if (row_here != null and row_here.? == self.row) .{ .select = self.row } else .none,
            .dragging => if (insertion) |to| (if (to == self.row or to == self.row + 1) .none else .{ .drop = .{ .row = self.row, .to = to } }) else .none,
        };
    }

    /// Esc or WM_CAPTURECHANGED: abandon without selecting or dropping.
    pub fn cancel(self: *PressTracker) void {
        self.state = .idle;
    }

    pub fn dragging(self: PressTracker) bool {
        return self.state == .dragging;
    }
};

pub const Insertion = struct {
    /// Insert before this row index (rows.len = at the end).
    index: usize,
    /// Content y of the insertion line.
    line_y: f32,
};

/// Drop position for content y: before the row whose upper half contains
/// `y`, after it for the lower half.
pub fn insertionAt(rows: []const RowGeom, y: f32) Insertion {
    if (rows.len == 0) return .{ .index = 0, .line_y = 0 };
    if (std.math.isNan(y) or y <= rows[0].top) return .{ .index = 0, .line_y = rows[0].top };
    const i = rowAtY(rows, y) orelse return .{ .index = rows.len, .line_y = rows[rows.len - 1].bottom() };
    const g = rows[i];
    if (y < g.top + g.height / 2) return .{ .index = i, .line_y = g.top };
    return .{ .index = i + 1, .line_y = g.bottom() };
}

/// Auto-scroll speed (DIPs per second) while dragging near an edge:
/// proportional to the depth into the `edge` band, up to `max_speed`,
/// negative near the top. `y` is in viewport coordinates.
pub fn autoScrollVelocity(y: f32, viewport: f32, edge: f32, max_speed: f32) f32 {
    if (!(edge > 0) or !(viewport > 0) or std.math.isNan(y)) return 0;
    const band = @min(edge, viewport / 2);
    if (y < band) return -max_speed * @min((band - y) / band, 1);
    if (y > viewport - band) return max_speed * @min((y - (viewport - band)) / band, 1);
    return 0;
}

// ─── Multi-select (groupSelectedWorkspaces) ─────────────────────────────

pub const ClickMods = struct { ctrl: bool = false, shift: bool = false };

/// Apply a click to a selection mask over rows: plain click selects only
/// `index`, Ctrl toggles it, Shift selects the range from the anchor.
/// Only workspace rows are selectable. Returns the new anchor.
pub fn applyClick(rows: []const RowGeom, selected: []bool, anchor: ?usize, index: usize, mods: ClickMods) ?usize {
    std.debug.assert(selected.len == rows.len);
    if (index >= rows.len or rows[index].kind != .workspace) return anchor;
    if (mods.shift) {
        const a = if (anchor) |x| @min(x, rows.len - 1) else index;
        if (!mods.ctrl) @memset(selected, false);
        const lo = @min(a, index);
        const hi = @max(a, index);
        for (lo..hi + 1) |i| if (rows[i].kind == .workspace) {
            selected[i] = true;
        };
        return a;
    }
    if (mods.ctrl) {
        selected[index] = !selected[index];
        return index;
    }
    @memset(selected, false);
    selected[index] = true;
    return index;
}
