//! Tab bar geometry: the one source of truth for where each tab, its close
//! glyph, the "+" button and the "▾" backend-picker segment sit in a tab
//! bar (ARCHITECTURE.md ADR-11.1: "tab bars stay GDI, with one shared
//! geometry"). The painter (ui/tabbar/paint.zig) and every hit-test (click,
//! middle click, right click, hover, drag reorder, inline rename) compute it
//! from the bar's current rect and tab count, so they can never disagree
//! and nothing is cached between a paint and the next input event.
//!
//! Pure (std only, ADR-1.2). x values are window client coordinates unless
//! a name says "local" (relative to the bar's left edge, as painted into the
//! bar's offscreen bitmap).

const std = @import("std");

/// Unscaled layout constants (DPI-scaled with `scaled`).
const BAR_H_BASE: f32 = 32.0;
const NEW_TAB_W_BASE: f32 = 36.0;
const DROPDOWN_W_BASE: f32 = 20.0;
const CLOSE_W_BASE: f32 = 20.0;
const TEXT_PAD_BASE: f32 = 10.0;
const MIN_TAB_W_BASE: f32 = 60.0;
const MAX_TAB_W_BASE: f32 = 200.0;

fn scaled(base: f32, scale: f32) i32 {
    return @intFromFloat(@round(base * scale));
}

/// Tab bar height in pixels at `scale`.
pub fn barHeight(scale: f32) i32 {
    return scaled(BAR_H_BASE, scale);
}

/// A half-open horizontal span [left, right) in client coordinates.
pub const Span = struct {
    left: i32,
    right: i32,

    pub fn contains(self: Span, x: i32) bool {
        return x >= self.left and x < self.right;
    }
};

/// What a point in the bar hits.
pub const Hit = union(enum) {
    none,
    /// The "▾" backend-picker segment.
    dropdown,
    /// The "+" new-tab button.
    new_tab,
    /// The body of tab `index` (selects / starts a drag).
    tab: usize,
    /// The close glyph band of tab `index`.
    close: usize,
};

pub const Geometry = struct {
    /// Bar left edge and top, in client coordinates.
    left: i32,
    top: i32,
    /// Bar height and width in pixels.
    bar_h: i32,
    width: i32,
    tab_count: usize,
    /// Width of every tab but the last one.
    tab_w: i32,
    /// Width available to the tabs (the bar minus "+" and "▾").
    available_w: i32,
    min_tab_w: i32,
    close_w: i32,
    text_pad: i32,
    new_tab_w: i32,
    dropdown_w: i32,

    /// Local x of tab `i`'s left edge.
    pub fn tabLocalLeft(self: Geometry, i: usize) i32 {
        return @as(i32, @intCast(i)) * self.tab_w;
    }

    /// Width of tab `i`: the last tab stretches over the remaining
    /// available width (never below the minimum tab width).
    pub fn tabWidth(self: Geometry, i: usize) i32 {
        if (self.tab_count > 0 and i == self.tab_count - 1) {
            return @max(self.available_w - self.tabLocalLeft(i), self.min_tab_w);
        }
        return self.tab_w;
    }

    /// Client-coordinate span of tab `i`.
    pub fn tabSpan(self: Geometry, i: usize) Span {
        const l = self.left + self.tabLocalLeft(i);
        return .{ .left = l, .right = l + self.tabWidth(i) };
    }

    /// Local x of tab `i`'s close glyph box (as painted).
    pub fn closeLocalLeft(self: Geometry, i: usize) i32 {
        return self.tabLocalLeft(i) + self.tabWidth(i) - self.close_w - @divTrunc(self.text_pad, 2);
    }

    /// Client x from which a point inside tab `i` hits its close band.
    pub fn closeLeft(self: Geometry, i: usize) i32 {
        return self.left + self.closeLocalLeft(i);
    }

    /// Local x right after the last tab.
    pub fn tabsLocalRight(self: Geometry) i32 {
        if (self.tab_count == 0) return 0;
        const last = self.tab_count - 1;
        return self.tabLocalLeft(last) + self.tabWidth(last);
    }

    /// Client-coordinate span of the "+" new-tab button.
    pub fn newTabSpan(self: Geometry) Span {
        const l = self.left + self.tabsLocalRight();
        return .{ .left = l, .right = l + self.new_tab_w };
    }

    /// Client-coordinate span of the "▾" backend-picker segment.
    pub fn dropdownSpan(self: Geometry) Span {
        const l = self.newTabSpan().right;
        return .{ .left = l, .right = l + self.dropdown_w };
    }

    /// The tab whose span contains client x, if any.
    pub fn tabAt(self: Geometry, x: i32) ?usize {
        for (0..self.tab_count) |i| {
            if (self.tabSpan(i).contains(x)) return i;
        }
        return null;
    }

    /// The slot a dragged tab lands in at client x: the last uniform slot
    /// (`tab_w` wide, from the bar's left edge) whose midpoint x has
    /// passed, clamped to the last tab. Uniform widths, not the painted
    /// ones: the stretched last tab would skew its midpoint.
    pub fn dragTarget(self: Geometry, x: i32) usize {
        if (self.tab_count == 0) return 0;
        var target: usize = 0;
        for (0..self.tab_count) |i| {
            const slot_left = self.left + @as(i32, @intCast(i)) * self.tab_w;
            if (x >= slot_left + @divTrunc(self.tab_w, 2)) target = i;
        }
        return @min(target, self.tab_count - 1);
    }

    /// What client x hits. Only x decides: callers check that the point
    /// is inside the bar vertically first.
    pub fn hit(self: Geometry, x: i32) Hit {
        if (self.dropdownSpan().contains(x)) return .dropdown;
        if (self.newTabSpan().contains(x)) return .new_tab;
        const i = self.tabAt(x) orelse return .none;
        return if (x >= self.closeLeft(i)) .{ .close = i } else .{ .tab = i };
    }
};

/// The geometry of a bar whose top-left corner is (`left`, `top`) in client
/// coordinates, `width` pixels wide, holding `tab_count` tabs, at `scale`.
pub fn compute(left: i32, top: i32, width: i32, tab_count: usize, scale: f32) Geometry {
    const new_tab_w = scaled(NEW_TAB_W_BASE, scale);
    const dropdown_w = scaled(DROPDOWN_W_BASE, scale);
    const available_w = width - new_tab_w - dropdown_w;
    const min_tab_w = scaled(MIN_TAB_W_BASE, scale);
    const max_tab_w = scaled(MAX_TAB_W_BASE, scale);

    var tab_w: i32 = if (tab_count > 0)
        @divTrunc(available_w, @as(i32, @intCast(tab_count)))
    else
        0;
    tab_w = @max(tab_w, min_tab_w);
    tab_w = @min(tab_w, max_tab_w);

    return .{
        .left = left,
        .top = top,
        .bar_h = barHeight(scale),
        .width = width,
        .tab_count = tab_count,
        .tab_w = tab_w,
        .available_w = available_w,
        .min_tab_w = min_tab_w,
        .close_w = scaled(CLOSE_W_BASE, scale),
        .text_pad = scaled(TEXT_PAD_BASE, scale),
        .new_tab_w = new_tab_w,
        .dropdown_w = dropdown_w,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: ui: tabbar geometry bar height scales" {
    try testing.expectEqual(@as(i32, 32), barHeight(1.0));
    try testing.expectEqual(@as(i32, 48), barHeight(1.5));
    try testing.expectEqual(@as(i32, 64), barHeight(2.0));
    try testing.expectEqual(@as(i32, 0), barHeight(0.0));
}

test "unit: ui: tabbar geometry splits the available width and stretches the last tab" {
    // 800 wide at 1.0: available = 800 - 36 - 20 = 744; 3 tabs of 200
    // (744/3 = 248 clamped to the 200 max), the last one stretched to 344.
    const g = compute(100, 0, 800, 3, 1.0);
    try testing.expectEqual(@as(i32, 200), g.tab_w);
    try testing.expectEqual(Span{ .left = 100, .right = 300 }, g.tabSpan(0));
    try testing.expectEqual(Span{ .left = 300, .right = 500 }, g.tabSpan(1));
    try testing.expectEqual(Span{ .left = 500, .right = 844 }, g.tabSpan(2));
    // "+" right after the last tab, "▾" right after "+".
    try testing.expectEqual(Span{ .left = 844, .right = 880 }, g.newTabSpan());
    try testing.expectEqual(Span{ .left = 880, .right = 900 }, g.dropdownSpan());
}

test "unit: ui: tabbar geometry close band is the last close_w + pad/2 of a tab" {
    const g = compute(0, 0, 800, 2, 1.0);
    // Tab 0 spans [0, 200): close glyph at 200 - 20 - 5 = 175.
    try testing.expectEqual(@as(i32, 175), g.closeLeft(0));
    try testing.expectEqual(Hit{ .tab = 0 }, g.hit(174));
    try testing.expectEqual(Hit{ .close = 0 }, g.hit(175));
    try testing.expectEqual(Hit{ .close = 0 }, g.hit(199));
    try testing.expectEqual(Hit{ .tab = 1 }, g.hit(200));
}

test "unit: ui: tabbar geometry hit order covers the buttons and the empty strip" {
    const g = compute(0, 0, 800, 1, 1.0);
    // One tab stretched over the whole available width (744).
    try testing.expectEqual(Span{ .left = 0, .right = 744 }, g.tabSpan(0));
    try testing.expectEqual(Hit.new_tab, g.hit(744));
    try testing.expectEqual(Hit.new_tab, g.hit(779));
    try testing.expectEqual(Hit.dropdown, g.hit(780));
    try testing.expectEqual(Hit.dropdown, g.hit(799));
    try testing.expectEqual(Hit.none, g.hit(800));
    try testing.expectEqual(Hit.none, g.hit(-1));
}

test "unit: ui: tabbar geometry overflowing tabs keep the minimum width" {
    // 40 tabs in 800px: 744/40 = 18 < min 60, so every tab is 60 wide and
    // the "+" lands far past the bar (the known overflow, 8.1 #11).
    const g = compute(0, 0, 800, 40, 1.0);
    try testing.expectEqual(@as(i32, 60), g.tab_w);
    try testing.expectEqual(@as(i32, 60), g.tabWidth(39));
    try testing.expectEqual(@as(i32, 40 * 60), g.newTabSpan().left);
    try testing.expectEqual(@as(?usize, 13), g.tabAt(13 * 60 + 1));
}

test "unit: ui: tabbar geometry with no tabs puts the buttons at the bar start" {
    const g = compute(50, 7, 300, 0, 1.0);
    try testing.expectEqual(@as(?usize, null), g.tabAt(60));
    try testing.expectEqual(Span{ .left = 50, .right = 86 }, g.newTabSpan());
    try testing.expectEqual(Span{ .left = 86, .right = 106 }, g.dropdownSpan());
    try testing.expectEqual(@as(i32, 7), g.top);
}

test "unit: ui: tabbar geometry scales with DPI" {
    const g = compute(0, 0, 1600, 2, 2.0);
    // available = 1600 - 72 - 40 = 1488; 1488/2 = 744 clamped to 400.
    try testing.expectEqual(@as(i32, 400), g.tab_w);
    try testing.expectEqual(@as(i32, 64), g.bar_h);
    try testing.expectEqual(@as(i32, 40), g.close_w);
    try testing.expectEqual(@as(i32, 20), g.text_pad);
    // Tab 0 close glyph at 400 - 40 - 10.
    try testing.expectEqual(@as(i32, 350), g.closeLeft(0));
}

test "unit: ui: tabbar geometry drag target follows uniform slot midpoints" {
    // Uniform 200px slots from x=100 (the stretched last tab is ignored):
    // slot i covers [100+200i, 300+200i) and is the target once x passes
    // its midpoint 200+200i.
    const g = compute(100, 0, 800, 3, 1.0);
    try testing.expectEqual(@as(usize, 0), g.dragTarget(0));
    try testing.expectEqual(@as(usize, 0), g.dragTarget(399));
    try testing.expectEqual(@as(usize, 1), g.dragTarget(400));
    try testing.expectEqual(@as(usize, 1), g.dragTarget(599));
    try testing.expectEqual(@as(usize, 2), g.dragTarget(600));
    // Far right clamps to the last tab.
    try testing.expectEqual(@as(usize, 2), g.dragTarget(5000));
}
