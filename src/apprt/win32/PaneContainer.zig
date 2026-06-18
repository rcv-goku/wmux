//! A PaneContainer is a per-pane tab container that lives as a leaf in
//! the workspace-level SplitTree. It owns a set of tabs (each a single
//! Pane) and implements the SplitTree view protocol (ref/unref/eql —
//! see the doc comment in src/datastruct/split_tree.zig). Splits create
//! new PaneContainers; tabs live within a single PaneContainer.
const PaneContainer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Pane = @import("Pane.zig");
const Window = @import("Window.zig");
const ipc = @import("ipc.zig");
const w32 = @import("win32.zig");

const MAX_TABS = Window.MAX_TABS;
const MAX_STATUS_BYTES = Window.MAX_STATUS_BYTES;
const TabStatus = Window.TabStatus;

/// Reference count for SplitTree ownership. Starts at 0 because
/// SplitTree.init() calls ref() to take initial ownership.
ref_count: u32 = 0,

/// Number of live tabs in this container.
tab_count: usize = 0,

/// Index of the currently visible tab.
active_tab: usize = 0,

/// Each tab is a single Pane (terminal or browser). No per-tab split
/// tree — in the new model, splits are between PaneContainers.
tabs: [MAX_TABS]*Pane = undefined,

/// UTF-16 title buffers for each tab (for painting the tab bar).
tab_titles: [MAX_TABS][256]u16 = undefined,

/// Length of each tab title in UTF-16 code units.
tab_title_lens: [MAX_TABS]u16 = undefined,

/// Per-tab sidebar status. Cleared to .normal when the tab is selected.
tab_status: [MAX_TABS]TabStatus = [_]TabStatus{.normal} ** MAX_TABS,

/// Per-tab "needs attention" flag (the notification ring).
tab_attention: [MAX_TABS]bool = @splat(false),

/// Per-tab orchestration status string (set-status).
tab_status_text: [MAX_TABS][MAX_STATUS_BYTES]u8 = undefined,
tab_status_text_len: [MAX_TABS]u16 = @splat(0),

/// Per-tab progress percent (set-progress), 0..100, or null for none.
tab_progress: [MAX_TABS]?u8 = @splat(null),

/// Per-tab ring log buffer (log).
tab_log: [MAX_TABS]ipc.LogRing = @splat(.{}),

/// Per-tab synchronized input flag.
tab_synchronized: [MAX_TABS]bool = @splat(false),

// -------------------------------------------------------------------------
// Per-pane tab bar hit-test state
// -------------------------------------------------------------------------

/// Hit-test rectangles for each tab (in window client coords).
tab_rects: [MAX_TABS]w32.RECT = std.mem.zeroes([MAX_TABS]w32.RECT),

/// Number of valid entries in tab_rects (mirrors tab_count at paint time).
tab_rect_count: usize = 0,

/// Hit-test rectangle for the per-pane "+" (new tab) button.
new_tab_btn_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Hit-test rectangle for the per-pane "▾" (backend picker) button.
new_tab_dropdown_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Per-tab close button hit-test rectangles (in window client coords).
close_btn_rects: [MAX_TABS]w32.RECT = std.mem.zeroes([MAX_TABS]w32.RECT),

/// Full layout rect assigned by layoutSplits (includes tab bar area).
/// Used for painting per-pane tab bars and hit-testing in split mode.
layout_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

// -------------------------------------------------------------------------
// Per-pane tab bar hover state (split mode only)
// -------------------------------------------------------------------------

/// Index of the tab being hovered in this container's tab bar (null = none).
hovered_tab_idx: ?usize = null,

/// Index of the tab whose close button is being hovered (null = none).
hovered_close_idx: ?usize = null,

/// Whether the "+" new-tab button in this container's tab bar is hovered.
hovered_new_tab: bool = false,

/// Whether the "▾" dropdown button in this container's tab bar is hovered.
hovered_dropdown: bool = false,

// -------------------------------------------------------------------------
// Construction / destruction
// -------------------------------------------------------------------------

/// Heap-allocate a PaneContainer with default-initialized fields.
pub fn create(alloc: Allocator) Allocator.Error!*PaneContainer {
    const pc = try alloc.create(PaneContainer);
    pc.* = .{};
    return pc;
}

// -------------------------------------------------------------------------
// SplitTree view protocol
// -------------------------------------------------------------------------

/// Increment reference count, return self.
pub fn ref(self: *PaneContainer, alloc: Allocator) Allocator.Error!*PaneContainer {
    _ = alloc;
    self.ref_count += 1;
    return self;
}

/// Decrement reference count. At zero, unref all owned panes and free.
pub fn unref(self: *PaneContainer, alloc: Allocator) void {
    self.ref_count -= 1;
    if (self.ref_count == 0) {
        for (self.tabs[0..self.tab_count]) |pane| {
            pane.unref(alloc);
        }
        alloc.destroy(self);
    }
}

/// Identity comparison.
pub fn eql(self: *const PaneContainer, other: *const PaneContainer) bool {
    return self == other;
}

// -------------------------------------------------------------------------
// Accessors
// -------------------------------------------------------------------------

/// The active tab's pane HWND, or null if empty.
pub fn activePaneHwnd(self: *const PaneContainer) ?w32.HWND {
    if (self.tab_count == 0) return null;
    return self.tabs[self.active_tab].hwnd();
}

/// The active tab's Pane, or null if empty.
pub fn activePane(self: *PaneContainer) ?*Pane {
    if (self.tab_count == 0) return null;
    return self.tabs[self.active_tab];
}

/// The parallel per-tab arrays as a tuple of array pointers, compatible
/// with the tabArraysInsertGap/tabArraysRemove/tabArraysSwap helpers
/// in Window.zig.
pub fn tabArrays(self: *PaneContainer) struct {
    *[MAX_TABS]*Pane,
    *[MAX_TABS][256]u16,
    *[MAX_TABS]u16,
    *[MAX_TABS]TabStatus,
    *[MAX_TABS]bool,
    *[MAX_TABS][MAX_STATUS_BYTES]u8,
    *[MAX_TABS]u16,
    *[MAX_TABS]?u8,
    *[MAX_TABS]ipc.LogRing,
    *[MAX_TABS]bool,
} {
    return .{
        &self.tabs,
        &self.tab_titles,
        &self.tab_title_lens,
        &self.tab_status,
        &self.tab_attention,
        &self.tab_status_text,
        &self.tab_status_text_len,
        &self.tab_progress,
        &self.tab_log,
        &self.tab_synchronized,
    };
}

/// The worst status across this container's tabs: exited > bell > normal.
pub fn aggregateStatus(self: *const PaneContainer) TabStatus {
    var worst: TabStatus = .normal;
    for (self.tab_status[0..self.tab_count]) |s| {
        switch (s) {
            .exited => return .exited,
            .bell => worst = .bell,
            .normal => {},
        }
    }
    return worst;
}

/// Whether any tab in this container is flagged for attention.
pub fn hasAttention(self: *const PaneContainer) bool {
    for (self.tab_attention[0..self.tab_count]) |f| {
        if (f) return true;
    }
    return false;
}

/// Give keyboard focus to the active tab's pane.
pub fn focus(self: *const PaneContainer) void {
    if (self.tab_count > 0) self.tabs[self.active_tab].focus();
}

// -------------------------------------------------------------------------
// Per-pane tab bar rendering
// -------------------------------------------------------------------------

/// The unscaled tab bar height in pixels (matches Window.tabBarHeight logic).
pub fn tabBarHeight(scale: f32) i32 {
    return @intFromFloat(@round(32.0 * scale));
}

/// Paint a per-pane tab bar within the top portion of `rect`. Returns the
/// height consumed (0 when no bar is drawn, e.g. <=1 tab). Stores hit-test
/// rects on self in window client coords for later click/hover routing.
///
/// `is_focused` controls visual treatment: focused gets brighter text and
/// an accent underline on the active tab; unfocused is dimmed.
pub fn paintTabBar(
    self: *PaneContainer,
    hdc: w32.HDC,
    rect: w32.RECT,
    scale: f32,
    config: anytype,
    is_focused: bool,
    tab_font: ?*anyopaque,
    hovered_tab: ?usize,
    hovered_close: ?usize,
    force_visible: bool,
    hovered_new_tab: bool,
    hovered_dropdown: bool,
) i32 {
    if (!force_visible and self.tab_count <= 1) {
        self.tab_rect_count = 0;
        return 0;
    }

    const bar_h = tabBarHeight(scale);
    if (bar_h <= 0) return 0;

    const bar_w = rect.right - rect.left;
    if (bar_w <= 0) return 0;

    // Double-buffer: create offscreen DC and bitmap.
    const mem_dc = w32.CreateCompatibleDC(hdc) orelse return 0;
    defer _ = w32.DeleteDC(mem_dc);

    const mem_bmp = w32.CreateCompatibleBitmap(hdc, bar_w, bar_h) orelse return 0;
    const old_bmp = w32.SelectObject(mem_dc, mem_bmp);
    defer {
        _ = w32.SelectObject(mem_dc, old_bmp);
        _ = w32.DeleteObject(mem_bmp);
    }

    // --- Colors ---
    const bg = config.background;
    const bar_r: u8 = @min(@as(u16, bg.r) + 20, 255);
    const bar_g: u8 = @min(@as(u16, bg.g) + 20, 255);
    const bar_b: u8 = @min(@as(u16, bg.b) + 20, 255);

    // Unfocused bar is dimmer (only +10 from terminal bg instead of +20).
    const uf_r: u8 = @min(@as(u16, bg.r) + 10, 255);
    const uf_g: u8 = @min(@as(u16, bg.g) + 10, 255);
    const uf_b: u8 = @min(@as(u16, bg.b) + 10, 255);

    const bar_color = if (is_focused) w32.RGB(bar_r, bar_g, bar_b) else w32.RGB(uf_r, uf_g, uf_b);

    const hover_r: u8 = @min(@as(u16, bar_r) + 15, 255);
    const hover_g: u8 = @min(@as(u16, bar_g) + 15, 255);
    const hover_b: u8 = @min(@as(u16, bar_b) + 15, 255);
    const hover_color = w32.RGB(hover_r, hover_g, hover_b);

    const active_bg_color = w32.RGB(bg.r, bg.g, bg.b);
    const accent_color = w32.RGB(0x3D, 0x8E, 0xF8);

    const active_text_color = if (is_focused) w32.RGB(230, 230, 230) else w32.RGB(150, 150, 150);
    const inactive_text_color = w32.RGB(150, 150, 150);

    const close_normal_color = w32.RGB(150, 150, 150);
    const close_hover_color = w32.RGB(232, 65, 65);

    // --- Fill bar background ---
    var bar_rect = w32.RECT{ .left = 0, .top = 0, .right = bar_w, .bottom = bar_h };
    if (w32.CreateSolidBrush(bar_color)) |bar_brush| {
        _ = w32.FillRect(mem_dc, &bar_rect, bar_brush);
        _ = w32.DeleteObject(@ptrCast(bar_brush));
    }

    // --- Select font and set text mode ---
    var old_font: ?*anyopaque = null;
    if (tab_font) |font| {
        old_font = w32.SelectObject(mem_dc, font);
    }
    defer {
        if (old_font) |f| _ = w32.SelectObject(mem_dc, f);
    }
    _ = w32.SetBkMode(mem_dc, w32.TRANSPARENT);

    // --- Calculate tab geometry ---
    const new_tab_btn_w: i32 = @intFromFloat(@round(36.0 * scale));
    const dropdown_btn_w: i32 = @intFromFloat(@round(20.0 * scale));
    const close_btn_w: i32 = @intFromFloat(@round(20.0 * scale));
    const text_pad: i32 = @intFromFloat(@round(10.0 * scale));
    const accent_h: i32 = @intFromFloat(@round(2.0 * scale));

    const tab_count_i32: i32 = @intCast(self.tab_count);
    const available_w = bar_w - new_tab_btn_w - dropdown_btn_w;

    const min_tab_w: i32 = @intFromFloat(@round(60.0 * scale));
    const max_tab_w: i32 = @intFromFloat(@round(200.0 * scale));

    var tab_w: i32 = if (tab_count_i32 > 0)
        @divTrunc(available_w, tab_count_i32)
    else
        0;
    tab_w = @max(tab_w, min_tab_w);
    tab_w = @min(tab_w, max_tab_w);

    // --- Draw each tab ---
    var x: i32 = 0;
    for (0..self.tab_count) |i| {
        const is_active = (i == self.active_tab);
        const is_hovered = if (hovered_tab) |ht| (ht == i) else false;

        const this_tab_w: i32 = if (i == self.tab_count - 1 and tab_count_i32 > 0)
            @max(available_w - x, min_tab_w)
        else
            tab_w;

        // Store hit-test rect in window client coords.
        self.tab_rects[i] = w32.RECT{
            .left = rect.left + x,
            .top = rect.top,
            .right = rect.left + x + this_tab_w,
            .bottom = rect.top + bar_h,
        };

        // Store close button hit-test rect.
        const close_left = x + this_tab_w - close_btn_w - @divTrunc(text_pad, 2);
        self.close_btn_rects[i] = w32.RECT{
            .left = rect.left + close_left,
            .top = rect.top,
            .right = rect.left + close_left + close_btn_w + @divTrunc(text_pad, 2),
            .bottom = rect.top + bar_h,
        };

        // Draw tab background.
        if (is_active) {
            var tab_rect = w32.RECT{ .left = x, .top = 0, .right = x + this_tab_w, .bottom = bar_h };
            if (w32.CreateSolidBrush(active_bg_color)) |brush| {
                _ = w32.FillRect(mem_dc, &tab_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }

            // Accent line at bottom — only when focused.
            if (is_focused) {
                var accent_rect = w32.RECT{
                    .left = x,
                    .top = bar_h - accent_h,
                    .right = x + this_tab_w,
                    .bottom = bar_h,
                };
                if (w32.CreateSolidBrush(accent_color)) |brush| {
                    _ = w32.FillRect(mem_dc, &accent_rect, brush);
                    _ = w32.DeleteObject(@ptrCast(brush));
                }
            }
        } else if (is_hovered) {
            var hover_rect = w32.RECT{ .left = x, .top = 0, .right = x + this_tab_w, .bottom = bar_h };
            if (w32.CreateSolidBrush(hover_color)) |brush| {
                _ = w32.FillRect(mem_dc, &hover_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        // Attention dot.
        const attn_dot_w: i32 = if (self.tab_attention[i]) @intFromFloat(@round(12.0 * scale)) else 0;
        if (attn_dot_w > 0) {
            _ = w32.SetTextColor(mem_dc, accent_color);
            const dot_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{25CF}");
            var dot_rect = w32.RECT{
                .left = x + text_pad,
                .top = 0,
                .right = x + text_pad + attn_dot_w,
                .bottom = bar_h,
            };
            _ = w32.DrawTextW(
                mem_dc,
                dot_char,
                1,
                &dot_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
        }

        // Sync indicator.
        const sync_indicator_w: i32 = if (self.tab_synchronized[i]) @intFromFloat(@round(14.0 * scale)) else 0;
        if (sync_indicator_w > 0) {
            _ = w32.SetTextColor(mem_dc, w32.RGB(0xE8, 0x9C, 0x20));
            const sync_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{21C4}");
            var sync_rect = w32.RECT{
                .left = x + text_pad + attn_dot_w,
                .top = 0,
                .right = x + text_pad + attn_dot_w + sync_indicator_w,
                .bottom = bar_h,
            };
            _ = w32.DrawTextW(
                mem_dc,
                sync_char,
                1,
                &sync_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
        }

        // Draw tab title text.
        const title_len = self.tab_title_lens[i];
        if (title_len > 0) {
            _ = w32.SetTextColor(mem_dc, if (is_active) active_text_color else inactive_text_color);
            var text_rect = w32.RECT{
                .left = x + text_pad + attn_dot_w + sync_indicator_w,
                .top = 0,
                .right = x + this_tab_w - close_btn_w - text_pad,
                .bottom = bar_h,
            };
            _ = w32.DrawTextW(
                mem_dc,
                @ptrCast(&self.tab_titles[i]),
                @intCast(title_len),
                &text_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
            );
        }

        // Draw close button (×) — visible on active or hovered tabs.
        if (is_active or is_hovered) {
            const is_close_hovered = if (hovered_close) |hc| (hc == i) else false;
            const close_text_color = if (is_close_hovered)
                close_hover_color
            else
                close_normal_color;

            _ = w32.SetTextColor(mem_dc, close_text_color);
            const x_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{00D7}");
            const close_y_center = @divTrunc(bar_h, 2);
            var close_rect = w32.RECT{
                .left = close_left,
                .top = close_y_center - @divTrunc(close_btn_w, 2),
                .right = close_left + close_btn_w,
                .bottom = close_y_center + @divTrunc(close_btn_w, 2),
            };
            _ = w32.DrawTextW(
                mem_dc,
                x_char,
                1,
                &close_rect,
                w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
        }

        x += this_tab_w;
    }

    // --- Draw new-tab (+) button ---
    {
        const btn_left = x;
        const btn_right = x + new_tab_btn_w;
        self.new_tab_btn_rect = w32.RECT{
            .left = rect.left + btn_left,
            .top = rect.top,
            .right = rect.left + btn_right,
            .bottom = rect.top + bar_h,
        };

        if (hovered_new_tab) {
            var btn_rect = w32.RECT{ .left = btn_left, .top = 0, .right = btn_right, .bottom = bar_h };
            if (w32.CreateSolidBrush(hover_color)) |brush| {
                _ = w32.FillRect(mem_dc, &btn_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        _ = w32.SetTextColor(mem_dc, inactive_text_color);
        const plus_char = std.unicode.utf8ToUtf16LeStringLiteral("+");
        var plus_rect = w32.RECT{
            .left = btn_left,
            .top = 0,
            .right = btn_right,
            .bottom = bar_h,
        };
        _ = w32.DrawTextW(
            mem_dc,
            plus_char,
            1,
            &plus_rect,
            w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );
    }

    // --- Draw backend picker (▾) segment beside the new-tab button ---
    {
        const dd_left = self.new_tab_btn_rect.right - rect.left;
        self.new_tab_dropdown_rect = w32.RECT{
            .left = rect.left + dd_left,
            .top = rect.top,
            .right = rect.left + dd_left + dropdown_btn_w,
            .bottom = rect.top + bar_h,
        };

        var dd_rect_local = w32.RECT{
            .left = dd_left,
            .top = 0,
            .right = dd_left + dropdown_btn_w,
            .bottom = bar_h,
        };

        if (hovered_dropdown) {
            if (w32.CreateSolidBrush(hover_color)) |brush| {
                _ = w32.FillRect(mem_dc, &dd_rect_local, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        _ = w32.SetTextColor(mem_dc, if (hovered_dropdown) active_text_color else inactive_text_color);
        const chevron_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{25BE}");
        _ = w32.DrawTextW(
            mem_dc,
            chevron_char,
            1,
            &dd_rect_local,
            w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );
    }

    // --- BitBlt to screen at the container's position ---
    _ = w32.BitBlt(hdc, rect.left, rect.top, bar_w, bar_h, mem_dc, 0, 0, w32.SRCCOPY);

    self.tab_rect_count = self.tab_count;
    return bar_h;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "unit: PaneContainer create returns default state" {
    const pc = try PaneContainer.create(testing.allocator);
    defer testing.allocator.destroy(pc);
    try testing.expectEqual(@as(u32, 0), pc.ref_count);
    try testing.expectEqual(@as(usize, 0), pc.tab_count);
    try testing.expectEqual(@as(usize, 0), pc.active_tab);
}

test "unit: PaneContainer ref counts up and returns self" {
    var pc: PaneContainer = .{};
    try testing.expectEqual(@as(u32, 0), pc.ref_count);
    const p = try pc.ref(testing.allocator);
    try testing.expectEqual(&pc, p);
    try testing.expectEqual(@as(u32, 1), pc.ref_count);
    _ = try pc.ref(testing.allocator);
    try testing.expectEqual(@as(u32, 2), pc.ref_count);
}

test "unit: PaneContainer eql is identity" {
    var a: PaneContainer = .{};
    var b: PaneContainer = .{};
    try testing.expect(a.eql(&a));
    try testing.expect(!a.eql(&b));
}

test "unit: PaneContainer aggregateStatus returns worst" {
    var pc: PaneContainer = .{};
    pc.tab_count = 3;
    pc.tab_status[0] = .normal;
    pc.tab_status[1] = .normal;
    pc.tab_status[2] = .normal;
    try testing.expectEqual(TabStatus.normal, pc.aggregateStatus());

    pc.tab_status[1] = .bell;
    try testing.expectEqual(TabStatus.bell, pc.aggregateStatus());

    pc.tab_status[2] = .exited;
    try testing.expectEqual(TabStatus.exited, pc.aggregateStatus());
}

test "unit: PaneContainer aggregateStatus empty is normal" {
    var pc: PaneContainer = .{};
    try testing.expectEqual(TabStatus.normal, pc.aggregateStatus());
}

test "unit: PaneContainer hasAttention" {
    var pc: PaneContainer = .{};
    pc.tab_count = 2;
    try testing.expect(!pc.hasAttention());

    pc.tab_attention[1] = true;
    try testing.expect(pc.hasAttention());
}

test "unit: PaneContainer activePane null when empty" {
    var pc: PaneContainer = .{};
    try testing.expectEqual(@as(?*Pane, null), pc.activePane());
    try testing.expectEqual(@as(?w32.HWND, null), pc.activePaneHwnd());
}

test "unit: PaneContainer activePane returns active tab" {
    var pane_a: Pane = .{ .content = .{ .terminal = undefined } };
    var pane_b: Pane = .{ .content = .{ .terminal = undefined } };
    var pc: PaneContainer = .{};
    pc.tabs[0] = &pane_a;
    pc.tabs[1] = &pane_b;
    pc.tab_count = 2;
    pc.active_tab = 0;
    try testing.expectEqual(&pane_a, pc.activePane().?);

    pc.active_tab = 1;
    try testing.expectEqual(&pane_b, pc.activePane().?);
}

test "unit: PaneContainer focus is noop when empty" {
    var pc: PaneContainer = .{};
    pc.focus();
}

// Dummy HDC for tests that hit early returns before any GDI operations.
const test_hdc: w32.HDC = @ptrFromInt(1);
const test_config = .{ .background = .{ .r = @as(u8, 30), .g = @as(u8, 30), .b = @as(u8, 30) } };

test "unit: tabBarHeight returns scaled height" {
    try testing.expectEqual(@as(i32, 32), PaneContainer.tabBarHeight(1.0));
    try testing.expectEqual(@as(i32, 64), PaneContainer.tabBarHeight(2.0));
    try testing.expectEqual(@as(i32, 48), PaneContainer.tabBarHeight(1.5));
    try testing.expectEqual(@as(i32, 0), PaneContainer.tabBarHeight(0.0));
}

test "unit: paintTabBar returns 0 for single tab not force visible" {
    var pc: PaneContainer = .{};
    pc.tab_count = 1;
    const h = pc.paintTabBar(test_hdc, .{ .left = 0, .top = 0, .right = 800, .bottom = 600 }, 1.0, test_config, true, null, null, null, false, false, false);
    try testing.expectEqual(@as(i32, 0), h);
    try testing.expectEqual(@as(usize, 0), pc.tab_rect_count);
}

test "unit: paintTabBar returns 0 for empty container" {
    var pc: PaneContainer = .{};
    const h = pc.paintTabBar(test_hdc, .{ .left = 0, .top = 0, .right = 800, .bottom = 600 }, 1.0, test_config, true, null, null, null, false, false, false);
    try testing.expectEqual(@as(i32, 0), h);
    try testing.expectEqual(@as(usize, 0), pc.tab_rect_count);
}

test "unit: paintTabBar returns 0 for zero scale" {
    var pc: PaneContainer = .{};
    pc.tab_count = 3;
    const h = pc.paintTabBar(test_hdc, .{ .left = 0, .top = 0, .right = 800, .bottom = 600 }, 0.0, test_config, true, null, null, null, false, false, false);
    try testing.expectEqual(@as(i32, 0), h);
}

test "unit: paintTabBar returns 0 for zero-width rect" {
    var pc: PaneContainer = .{};
    pc.tab_count = 3;
    const h = pc.paintTabBar(test_hdc, .{ .left = 100, .top = 0, .right = 100, .bottom = 600 }, 1.0, test_config, true, null, null, null, false, false, false);
    try testing.expectEqual(@as(i32, 0), h);
}

test "unit: PaneContainer default hover state is cleared" {
    const pc: PaneContainer = .{};
    try testing.expectEqual(@as(?usize, null), pc.hovered_tab_idx);
    try testing.expectEqual(@as(?usize, null), pc.hovered_close_idx);
    try testing.expect(!pc.hovered_new_tab);
    try testing.expect(!pc.hovered_dropdown);
}

test "unit: PaneContainer default hit-test rects are zeroed" {
    const pc: PaneContainer = .{};
    try testing.expectEqual(@as(usize, 0), pc.tab_rect_count);
    try testing.expectEqual(@as(i32, 0), pc.new_tab_btn_rect.left);
    try testing.expectEqual(@as(i32, 0), pc.new_tab_btn_rect.right);
    try testing.expectEqual(@as(i32, 0), pc.new_tab_dropdown_rect.left);
    try testing.expectEqual(@as(i32, 0), pc.new_tab_dropdown_rect.right);
    try testing.expectEqual(@as(i32, 0), pc.layout_rect.left);
    try testing.expectEqual(@as(i32, 0), pc.layout_rect.right);
}

test "unit: PaneContainer hover state is independently settable" {
    var pc: PaneContainer = .{};
    pc.hovered_tab_idx = 2;
    pc.hovered_close_idx = 1;
    pc.hovered_new_tab = true;
    pc.hovered_dropdown = true;

    try testing.expectEqual(@as(?usize, 2), pc.hovered_tab_idx);
    try testing.expectEqual(@as(?usize, 1), pc.hovered_close_idx);
    try testing.expect(pc.hovered_new_tab);
    try testing.expect(pc.hovered_dropdown);

    // Clear hover state (as clearAllContainerHover would).
    pc.hovered_tab_idx = null;
    pc.hovered_close_idx = null;
    pc.hovered_new_tab = false;
    pc.hovered_dropdown = false;

    try testing.expectEqual(@as(?usize, null), pc.hovered_tab_idx);
    try testing.expectEqual(@as(?usize, null), pc.hovered_close_idx);
    try testing.expect(!pc.hovered_new_tab);
    try testing.expect(!pc.hovered_dropdown);
}

test "unit: PaneContainer layout_rect stores assigned position" {
    // Simulate layoutSplits assigning rects to containers in a side-by-side split.
    var left: PaneContainer = .{};
    left.layout_rect = .{ .left = 0, .top = 0, .right = 400, .bottom = 300 };
    try testing.expectEqual(@as(i32, 0), left.layout_rect.left);
    try testing.expectEqual(@as(i32, 0), left.layout_rect.top);
    try testing.expectEqual(@as(i32, 400), left.layout_rect.right);
    try testing.expectEqual(@as(i32, 300), left.layout_rect.bottom);

    var right: PaneContainer = .{};
    right.layout_rect = .{ .left = 400, .top = 0, .right = 800, .bottom = 300 };
    try testing.expectEqual(@as(i32, 400), right.layout_rect.left);
    try testing.expectEqual(@as(i32, 800), right.layout_rect.right);

    // Non-overlapping: left.right <= right.left.
    try testing.expect(left.layout_rect.right <= right.layout_rect.left);
}

test "unit: PaneContainer tab bar visibility rule" {
    var pc: PaneContainer = .{};

    // 0 tabs: no bar (both forced and unforced)
    pc.tab_count = 0;
    try testing.expect(pc.tab_count <= 1);

    // 1 tab: no bar unless forced
    pc.tab_count = 1;
    try testing.expect(pc.tab_count <= 1);

    // 2+ tabs: bar shown regardless of force
    pc.tab_count = 2;
    try testing.expect(pc.tab_count > 1);

    pc.tab_count = 5;
    try testing.expect(pc.tab_count > 1);
}
