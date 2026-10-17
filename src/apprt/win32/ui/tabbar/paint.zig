//! Tab bar painting (ARCHITECTURE.md ADR-1.8 W0-A2 step 4): the window-top
//! bar of a single-pane workspace and the per-pane bars of a split one,
//! double-buffered GDI. Moved out of Window.zig and model/Pane.zig in
//! W0-A2.

const std = @import("std");

const Pane = @import("../../model/Pane.zig");
const Window = @import("../Window.zig");
const geometry = @import("logic/geometry.zig");
const hints = @import("hints.zig");
const titles = @import("../../model/logic/titles.zig");
const w32 = @import("../../platform/win32.zig");

/// Paint the tab bar by dispatching to Pane rendering.
/// In split mode, each container paints its own tab bar within its layout_rect.
/// In single-pane mode, the focused container paints at the window-top position.
pub fn paintTabBar(self: *Window, hdc_screen: w32.HDC) void {
    const ws = self.activeWorkspace();

    // When splits exist, each Pane paints its own tab bar
    // within its layout_rect. The window-top bar is hidden.
    if (ws.tree.isSplit()) {
        var it = ws.tree.iterator();
        while (it.next()) |entry| {
            const container = entry.view;
            const is_focused = if (ws.focused_pane) |fc| container.eql(fc) else false;
            _ = paintPane(
                container,
                hdc_screen,
                container.layout_rect,
                self.scale,
                self.app.config,
                is_focused,
                self.tab_font,
                container.hovered_tab_idx,
                container.hovered_close_idx,
                false,
                container.hovered_new_tab,
                container.hovered_dropdown,
            );
        }
        return;
    }

    // Single-pane mode: delegate to the container's paintTabBar using
    // the window-top rect (offset by the sidebar width).
    const container = ws.focusedPaneOrFirst() orelse return;
    if (!self.tab_bar_visible) return;

    const hwnd = self.hwnd orelse return;
    const sidebar_w = self.sidebarWidth();

    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client_rect) == 0) return;

    const bar_h = self.tabBarHeight();
    const top_rect = w32.RECT{
        .left = sidebar_w,
        .top = 0,
        .right = client_rect.right,
        .bottom = bar_h,
    };

    // Convert Window hover state to Pane-compatible format.
    const ht: ?usize = if (self.hover_tab >= 0) @as(usize, @intCast(self.hover_tab)) else null;
    const hc: ?usize = if (self.hover_close and self.hover_tab >= 0) @as(usize, @intCast(self.hover_tab)) else null;

    _ = paintPane(
        container,
        hdc_screen,
        top_rect,
        self.scale,
        self.app.config,
        true,
        self.tab_font,
        ht,
        hc,
        true,
        self.hover_new_tab,
        self.hover_new_tab_dropdown,
    );
}

/// The geometry of the tab bar `pane` shows right now, or null when it
/// shows none: in a split workspace each pane with more than one tab has a
/// bar across the top of its layout rect; otherwise the window-top bar
/// (right of the sidebar) belongs to the focused pane. Every hit-test uses
/// this, so input always agrees with what paintTabBar draws.
pub fn barGeometry(self: *Window, pane: *const Pane) ?geometry.Geometry {
    const ws = self.activeWorkspace();
    if (ws.tree.isSplit()) {
        if (pane.tabCount() <= 1) return null;
        const lr = pane.layout_rect;
        return geometry.compute(lr.left, lr.top, lr.right - lr.left, pane.tabCount(), self.scale);
    }
    if (!self.tab_bar_visible) return null;
    const hwnd = self.hwnd orelse return null;
    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client_rect) == 0) return null;
    const sidebar_w = self.sidebarWidth();
    return geometry.compute(sidebar_w, 0, client_rect.right - sidebar_w, pane.tabCount(), self.scale);
}

/// The client rect of tab `index` in `pane`'s bar (inline rename overlay).
pub fn tabRect(self: *Window, pane: *const Pane, index: usize) ?w32.RECT {
    const geo = barGeometry(self, pane) orelse return null;
    if (index >= geo.tab_count) return null;
    const span = geo.tabSpan(index);
    return .{ .left = span.left, .top = geo.top, .right = span.right, .bottom = geo.top + geo.bar_h };
}

// -------------------------------------------------------------------------
// Per-pane tab bar rendering
// -------------------------------------------------------------------------

/// The tab bar height in pixels at `scale` (matches Window.tabBarHeight).
pub const barHeight = geometry.barHeight;

/// Paint a per-pane tab bar within the top portion of `rect`. Returns the
/// height consumed (0 when no bar is drawn, e.g. <=1 tab). Hit-testing
/// recomputes the same geometry (logic/geometry.zig) from the bar rect.
///
/// `is_focused` controls visual treatment: focused gets brighter text and
/// an accent underline on the active tab; unfocused is dimmed.
pub fn paintPane(
    self: *const Pane,
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
    if (!force_visible and self.tabCount() <= 1) return 0;

    const bar_h = barHeight(scale);
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

    // --- Tab geometry (shared with every hit-test: logic/geometry.zig) ---
    const geo = geometry.compute(rect.left, rect.top, bar_w, self.tabCount(), scale);
    const close_btn_w = geo.close_w;
    const text_pad = geo.text_pad;
    const accent_h: i32 = @intFromFloat(@round(2.0 * scale));

    // --- Draw each tab ---
    for (self.tabs.items, 0..) |tab, i| {
        const is_active = (i == self.selected);
        const is_hovered = if (hovered_tab) |ht| (ht == i) else false;

        // Local (bitmap) coordinates of this tab and its close glyph.
        const x = geo.tabLocalLeft(i);
        const this_tab_w = geo.tabWidth(i);
        const close_left = geo.closeLocalLeft(i);

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
        const attn_dot_w: i32 = if (tab.ext.notifications.attention) @intFromFloat(@round(12.0 * scale)) else 0;
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
        const sync_indicator_w: i32 = if (tab.ext.sync_input.synchronized) @intFromFloat(@round(14.0 * scale)) else 0;
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
        var title_buf: [256]u16 = undefined;
        const title_len = titles.toUtf16(&title_buf, tab.titleText());
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
                @ptrCast(&title_buf),
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
    }

    // --- Draw new-tab (+) button ---
    {
        const btn_left = geo.newTabSpan().left - rect.left;
        const btn_right = geo.newTabSpan().right - rect.left;

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
        var dd_rect_local = w32.RECT{
            .left = geo.dropdownSpan().left - rect.left,
            .top = 0,
            .right = geo.dropdownSpan().right - rect.left,
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

    // --- Modifier-hold hint chips (ui/tabbar/hints.zig, W1-5b) ---
    hints.paintPane(self, mem_dc, geo, scale, is_focused);

    // --- BitBlt to screen at the container's position ---
    _ = w32.BitBlt(hdc, rect.left, rect.top, bar_w, bar_h, mem_dc, 0, 0, w32.SRCCOPY);

    return bar_h;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// Dummy HDC for tests that hit early returns before any GDI operations.
const test_hdc: w32.HDC = @ptrFromInt(1);
const test_config = .{ .background = .{ .r = @as(u8, 30), .g = @as(u8, 30), .b = @as(u8, 30) } };

const Tab = @import("../../model/Tab.zig");

/// A pane over caller-owned placeholder tabs (read-only list).
fn testPane(tabs: []Tab, ptrs: []*Tab) Pane {
    for (tabs, 0..) |*t, i| ptrs[i] = t;
    return .{ .tabs = .{ .items = ptrs[0..tabs.len], .capacity = tabs.len } };
}

test "unit: tabBarHeight returns scaled height" {
    try testing.expectEqual(@as(i32, 32), barHeight(1.0));
    try testing.expectEqual(@as(i32, 64), barHeight(2.0));
    try testing.expectEqual(@as(i32, 48), barHeight(1.5));
    try testing.expectEqual(@as(i32, 0), barHeight(0.0));
}

test "unit: paintTabBar returns 0 for single tab not force visible" {
    var tabs: [1]Tab = @splat(.{ .content = .{ .placeholder = .{} } });
    var ptrs: [1]*Tab = undefined;
    const pc = testPane(&tabs, &ptrs);
    const h = paintPane(&pc, test_hdc, .{ .left = 0, .top = 0, .right = 800, .bottom = 600 }, 1.0, test_config, true, null, null, null, false, false, false);
    try testing.expectEqual(@as(i32, 0), h);
}

test "unit: paintTabBar returns 0 for empty container" {
    const pc: Pane = .{};
    const h = paintPane(&pc, test_hdc, .{ .left = 0, .top = 0, .right = 800, .bottom = 600 }, 1.0, test_config, true, null, null, null, false, false, false);
    try testing.expectEqual(@as(i32, 0), h);
}

test "unit: paintTabBar returns 0 for zero scale" {
    var tabs: [3]Tab = @splat(.{ .content = .{ .placeholder = .{} } });
    var ptrs: [3]*Tab = undefined;
    const pc = testPane(&tabs, &ptrs);
    const h = paintPane(&pc, test_hdc, .{ .left = 0, .top = 0, .right = 800, .bottom = 600 }, 0.0, test_config, true, null, null, null, false, false, false);
    try testing.expectEqual(@as(i32, 0), h);
}

test "unit: paintTabBar returns 0 for zero-width rect" {
    var tabs: [3]Tab = @splat(.{ .content = .{ .placeholder = .{} } });
    var ptrs: [3]*Tab = undefined;
    const pc = testPane(&tabs, &ptrs);
    const h = paintPane(&pc, test_hdc, .{ .left = 100, .top = 0, .right = 100, .bottom = 600 }, 1.0, test_config, true, null, null, null, false, false, false);
    try testing.expectEqual(@as(i32, 0), h);
}
