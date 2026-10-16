//! Window chrome (ARCHITECTURE.md ADR-1.8 W0-A2 step 4): the geometry of
//! the tab bar, the sidebars and the re-show strip, the surface rect, pane
//! layout and the split dividers (paint, hit-test, drag), invalidation,
//! WM_PAINT dispatch, theme, fullscreen and decorations. Moved out of
//! Window.zig in W0-A2.

const std = @import("std");

const Pane = @import("../model/Pane.zig");
const RightSidebar = @import("right_sidebar/legacy_strip.zig");
const Sidebar = @import("sidebar/legacy_gdi.zig");
const SplitTree = @import("../../../datastruct/split_tree.zig").SplitTree;
const Window = @import("Window.zig");
const layout = @import("../model/layout.zig");
const tabbar_paint = @import("tabbar/paint.zig");
const titles = @import("../model/logic/titles.zig");
const w32 = @import("../platform/win32.zig");

/// Width (unscaled px) of the thin re-show strip painted at the window's
/// left edge while the sidebar is runtime-hidden. Clicking it (or Ctrl+B)
/// brings the sidebar back. Kept narrow so it barely covers the surface.
pub const RESHOW_STRIP_BASE: f32 = 8.0;

/// Apply DWM dark/light + caption color based on the configured
/// background. Light vs dark is decided by luminance; CAPTION_COLOR
/// is silently ignored on Windows 10.
pub fn applyChromeTheme(hwnd: w32.HWND, bg: anytype) void {
    const luminance: f32 = (0.2126 * @as(f32, @floatFromInt(bg.r)) +
        0.7152 * @as(f32, @floatFromInt(bg.g)) +
        0.0722 * @as(f32, @floatFromInt(bg.b))) / 255.0;
    const dark_mode: u32 = if (luminance < 0.5) 1 else 0;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    const caption_color: u32 = (@as(u32, bg.r)) | (@as(u32, bg.g) << 8) | (@as(u32, bg.b) << 16);
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_CAPTION_COLOR,
        @ptrCast(&caption_color),
        @sizeOf(u32),
    );
}

/// Called from App.config_change so the title bar tracks live config
/// reloads (background color in particular).
pub fn onConfigChange(self: *Window) void {
    if (self.hwnd) |hwnd| {
        applyChromeTheme(hwnd, self.app.config.background);
    }
    // window-show-sidebar / window-sidebar-width may have changed:
    // drop any drag-resize override so the config value re-applies,
    // then recompute chrome layout and repaint. The runtime hide is
    // session-only and re-asserts the configured visibility on reload.
    self.sidebar_width_override = null;
    self.sidebar_hidden = false;
    // Right sidebar: re-assert configured visibility on reload.
    self.right_sidebar_hidden = false;
    self.right_sidebar_focused = false;
    self.updateTabBarVisibility();
    self.handleResize();
    self.invalidateSidebar();
    self.invalidateRightSidebar();
}

/// Returns the tab bar height in pixels, accounting for DPI scale.
/// Returns 0 if the tab bar is not visible.
pub fn tabBarHeight(self: *const Window) i32 {
    if (!self.tab_bar_visible) return 0;
    return @intFromFloat(@round(32.0 * self.scale));
}

/// Returns the sidebar width in pixels, accounting for DPI scale.
/// Returns 0 when the sidebar is disabled, for quick terminals, or
/// once the window is closing.
pub fn sidebarWidth(self: *const Window) i32 {
    if (self.closing or self.is_quick_terminal) return 0;
    if (!self.app.config.@"window-show-sidebar") return 0;
    if (self.sidebar_hidden) return 0;
    const unscaled = self.sidebar_width_override orelse self.app.config.@"window-sidebar-width";
    const width = std.math.clamp(unscaled, Sidebar.MIN_WIDTH, Sidebar.MAX_WIDTH);
    return @intFromFloat(@round(@as(f32, @floatFromInt(width)) * self.scale));
}

/// Whether the re-show edge strip (the thin affordance that brings the
/// sidebar back when it is runtime-hidden) should be painted/hit-tested
/// right now: the sidebar is enabled by config but hidden this session.
/// QuickTerminals have no sidebar so never show the strip.
pub fn sidebarReshowStripVisible(self: *const Window) bool {
    if (self.closing or self.is_quick_terminal) return false;
    if (!self.app.config.@"window-show-sidebar") return false;
    return self.sidebar_hidden;
}

/// Width of the re-show edge strip in DPI-scaled pixels. Kept thin (8px)
/// so it barely eats surface width; surfaceRect reserves exactly this much
/// at the left edge while hidden so the GL/WebView2 child does not occlude
/// the parent-painted strip.
pub fn sidebarReshowStripWidth(self: *const Window) i32 {
    return @intFromFloat(@round(@as(f32, RESHOW_STRIP_BASE) * self.scale));
}

/// Toggle the runtime (session-only) sidebar hide. No-op on a quick
/// terminal (it has no sidebar). Flips the bool, cancels any in-flight
/// edge drag, then relays out the panes + repaints chrome + re-glues the
/// overlays (handleResize routes through layoutSplits). Distinct from the
/// `window-show-sidebar` config: a config reload re-asserts the
/// configured visibility (onConfigChange resets sidebar_hidden).
pub fn toggleSidebar(self: *Window) void {
    if (self.is_quick_terminal) return;
    self.sidebar_hidden = !self.sidebar_hidden;
    // Abort any half-finished edge drag: the grab band disappears when
    // the width is 0, so a captured drag would otherwise dangle.
    self.dragging_sidebar = false;
    // Switching to/from a 0 width changes surfaceRect; relayout panes,
    // repaint the tab bar + sidebar, and re-glue the over-GL overlays.
    self.handleResize();
    // The re-show strip lives over the surface's left edge (paintChrome
    // draws it when hidden); force a full repaint so it appears/clears.
    if (self.hwnd) |h| _ = w32.InvalidateRect(h, null, 0);
}

/// Returns the right sidebar width in pixels, accounting for DPI scale.
/// Returns 0 when the right sidebar is disabled, for quick terminals, or
/// once the window is closing.
pub fn rightSidebarWidth(self: *const Window) i32 {
    if (self.closing or self.is_quick_terminal) return 0;
    if (!self.app.config.@"window-show-right-sidebar") return 0;
    if (self.right_sidebar_hidden) return 0;
    const unscaled = self.app.config.@"window-right-sidebar-width";
    const width = std.math.clamp(unscaled, RightSidebar.MIN_WIDTH, RightSidebar.MAX_WIDTH);
    return @intFromFloat(@round(@as(f32, @floatFromInt(width)) * self.scale));
}

/// Toggle the runtime (session-only) right sidebar hide. No-op on a
/// quick terminal. Flips the bool, then relays out the panes + repaints.
pub fn toggleRightSidebar(self: *Window) void {
    if (self.is_quick_terminal) return;
    self.right_sidebar_hidden = !self.right_sidebar_hidden;
    // When hiding the right sidebar, also drop focus from it.
    if (self.right_sidebar_hidden) self.right_sidebar_focused = false;
    self.handleResize();
    if (self.hwnd) |h| _ = w32.InvalidateRect(h, null, 0);
}

/// Toggle focus between the right sidebar and the terminal. If the
/// right sidebar is not visible, this is a no-op.
pub fn focusRightSidebar(self: *Window) void {
    if (self.rightSidebarWidth() <= 0) return;
    self.right_sidebar_focused = !self.right_sidebar_focused;
    if (self.hwnd) |h| _ = w32.InvalidateRect(h, null, 0);
}

/// Invalidate the right sidebar region so it gets repainted.
pub fn invalidateRightSidebar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const rs_w = self.rightSidebarWidth();
    if (rs_w <= 0) return;
    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client_rect) == 0) return;
    var rect = w32.RECT{
        .left = client_rect.right - rs_w,
        .top = 0,
        .right = client_rect.right,
        .bottom = 32767,
    };
    _ = w32.InvalidateRect(hwnd, &rect, 0);
}

/// Whether the sidebar should render the metadata second line on its rows
/// right now: the config toggle is on AND at least one workspace has
/// metadata to show. Computed once and used to pick the row height so the
/// taller stride is uniform across all rows (the index-based hit-testing /
/// drag math assumes a single fixed row height).
pub fn sidebarShowMetadata(self: *const Window) bool {
    if (!self.app.config.@"sidebar-metadata") return false;
    for (self.workspaces.items) |ws| {
        if (ws.hasMetadata()) return true;
    }
    return false;
}

/// The current sidebar row height: the taller two-line height when the
/// metadata line is active, else the compact single-line height. THE
/// single source of truth for the row stride — every sidebar geometry call
/// site (hitTest, itemRect, drag target, paint) routes through this so
/// painting and hit-testing always agree.
pub fn sidebarItemHeight(self: *const Window) i32 {
    return if (self.sidebarShowMetadata())
        Sidebar.itemHeightMeta(self.scale)
    else
        Sidebar.itemHeight(self.scale);
}

/// Returns the client rect available for the active surface, which is
/// the full client area minus the tab bar height from the top, the
/// sidebar width from the left, and the right sidebar width from the right.
pub fn surfaceRect(self: *const Window) w32.RECT {
    const hwnd = self.hwnd orelse return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) {
        return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }
    rect.top += self.tabBarHeight();
    rect.left += self.sidebarWidth();
    rect.right -= self.rightSidebarWidth();
    // While the sidebar is runtime-hidden, reserve the thin re-show strip
    // at the left edge so the GL/WebView2 child does not cover it (a
    // parent-window GDI strip painted inside the surface rect would be
    // occluded by the child HWND). Only 8px, so it barely shrinks the
    // surface; the WM_LBUTTONDOWN handler hit-tests the strip first.
    if (self.sidebarReshowStripVisible()) rect.left += self.sidebarReshowStripWidth();
    return rect;
}

/// Lay out the active workspace's split tree over `rect` (model/layout.zig)
/// with `gpa` (callers pass a stack-fallback allocator); deinit the result
/// with the same allocator. Null on allocation failure.
fn computeActiveLayout(self: *Window, gpa: std.mem.Allocator, rect: w32.RECT) ?layout.LayoutResult(Pane) {
    const ws = self.activeWorkspace();
    return layout.computeLayout(gpa, &ws.tree, rect, self.scale) catch null;
}

/// Layout split panes for the active workspace.
pub fn layoutSplits(self: *Window) void {
    const ws = self.activeWorkspace();
    const tree = &ws.tree;
    if (tree.isEmpty()) return;
    const rect = self.surfaceRect();
    if (tree.zoomed) |zoomed_handle| {
        var it = tree.iterator();
        while (it.next()) |entry| {
            entry.view.layout_rect = rect;
            if (entry.handle == zoomed_handle) {
                if (entry.view.selectedHwnd()) |h| {
                    const w = @max(rect.right - rect.left, 1);
                    const ht = @max(rect.bottom - rect.top, 1);
                    _ = w32.MoveWindow(h, rect.left, rect.top, @intCast(w), @intCast(ht), 1);
                    _ = w32.ShowWindow(h, w32.SW_SHOW);
                }
            } else {
                if (entry.view.selectedHwnd()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
            }
        }
        return;
    }

    {
        var sfa = std.heap.stackFallback(layout.stack_bytes, self.app.core_app.alloc);
        const gpa = sfa.get();
        var lay = computeActiveLayout(self, gpa, rect) orelse return;
        defer lay.deinit(gpa);
        const split = tree.isSplit();
        for (lay.leaves) |leaf| {
            const pane = leaf.view;
            pane.layout_rect = leaf.rect;

            // A split pane with 2+ tabs shows its own tab bar on top.
            var content_rect = leaf.rect;
            if (split and pane.tabCount() > 1) {
                content_rect.top += tabbar_paint.barHeight(self.scale);
            }

            if (pane.selectedHwnd()) |h| {
                const w = @max(content_rect.right - content_rect.left, 1);
                const ht = @max(content_rect.bottom - content_rect.top, 1);
                _ = w32.MoveWindow(h, content_rect.left, content_rect.top, @intCast(w), @intCast(ht), 1);
                _ = w32.ShowWindow(h, w32.SW_SHOW);
            }
        }
    }

    // Paint divider lines directly using GetDC (not BeginPaint, which
    // clips to the invalid region and misses the content area gaps).
    if (self.hwnd) |hwnd| {
        const hdc = w32.GetDC(hwnd);
        if (hdc) |dc| {
            self.paintDividers(dc);
            _ = w32.ReleaseDC(hwnd, dc);
        }
    }

    // Keep the notification rings glued to the just-laid-out panes
    // (resize/split/zoom all flow through here).
    self.updateAttentionRings();
    // Re-glue the per-pane corner buttons too (after the rings so the
    // clickable cluster is never occluded by a ring popup).
    self.updatePaneButtons();
}

/// Paint divider lines between split panes in the active tab,
/// plus a colored border around the focused pane.
pub fn paintDividers(self: *Window, hdc: w32.HDC) void {
    const ws = self.activeWorkspace();
    const tree = &ws.tree;
    if (tree.isEmpty()) return;
    if (!tree.isSplit()) return;
    if (tree.zoomed != null) return;
    paint: {
        var sfa = std.heap.stackFallback(layout.stack_bytes, self.app.core_app.alloc);
        const gpa = sfa.get();
        var lay = computeActiveLayout(self, gpa, self.surfaceRect()) orelse break :paint;
        defer lay.deinit(gpa);

        const pen = w32.CreatePen(0, layout.lineWidth(self.scale), 0x00808080) orelse break :paint;
        defer _ = w32.DeleteObject(pen);
        const old_pen = w32.SelectObject(hdc, pen);
        defer _ = w32.SelectObject(hdc, old_pen);

        for (lay.dividers) |d| {
            const r = d.node_rect;
            switch (d.layout) {
                .horizontal => {
                    _ = w32.MoveToEx(hdc, d.pos, r.top, null);
                    _ = w32.LineTo(hdc, d.pos, r.bottom);
                },
                .vertical => {
                    _ = w32.MoveToEx(hdc, r.left, d.pos, null);
                    _ = w32.LineTo(hdc, r.right, d.pos);
                },
            }
        }
    }
    self.paintFocusBorder(hdc);
}

/// Paint a thin accent border in the divider gaps around the focused pane.
pub fn paintFocusBorder(self: *Window, hdc: w32.HDC) void {
    const active = self.getActiveTab() orelse return;
    const active_hwnd = active.hwnd() orelse return;
    const parent_hwnd = self.hwnd orelse return;

    var wr: w32.RECT = undefined;
    if (w32.GetWindowRect(active_hwnd, &wr) == 0) return;
    var tl = w32.POINT{ .x = wr.left, .y = wr.top };
    var br = w32.POINT{ .x = wr.right, .y = wr.bottom };
    _ = w32.ScreenToClient(parent_hwnd, &tl);
    _ = w32.ScreenToClient(parent_hwnd, &br);

    const bw: i32 = @max(@as(i32, @intFromFloat(@round(2.0 * self.scale))), 2);
    const accent: u32 = 0x00C88030; // COLORREF 0x00BBGGRR — muted teal
    const brush = w32.CreateSolidBrush(accent) orelse return;
    defer _ = w32.DeleteObject(brush);

    var r: w32.RECT = undefined;
    // left
    r = .{ .left = tl.x - bw, .top = tl.y - bw, .right = tl.x, .bottom = br.y + bw };
    _ = w32.FillRect(hdc, &r, brush);
    // right
    r = .{ .left = br.x, .top = tl.y - bw, .right = br.x + bw, .bottom = br.y + bw };
    _ = w32.FillRect(hdc, &r, brush);
    // top
    r = .{ .left = tl.x, .top = tl.y - bw, .right = br.x, .bottom = tl.y };
    _ = w32.FillRect(hdc, &r, brush);
    // bottom
    r = .{ .left = tl.x, .top = br.y, .right = br.x, .bottom = br.y + bw };
    _ = w32.FillRect(hdc, &r, brush);
}

/// Repaint divider lines and the focus border. Called from focus change
/// handlers so the accent border follows the active pane immediately.
pub fn repaintDividers(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const ws = self.activeWorkspace();
    const tree = &ws.tree;
    if (tree.isEmpty()) return;
    if (!tree.isSplit()) return;
    if (tree.zoomed != null) return;
    const hdc = w32.GetDC(hwnd) orelse return;
    defer _ = w32.ReleaseDC(hwnd, hdc);
    // Clear the entire surface rect with the background so old focus
    // borders in the gap area are erased before we repaint.
    if (self.app.bg_brush) |brush| {
        var sr = self.surfaceRect();
        _ = w32.FillRect(hdc, &sr, brush);
    }
    self.paintDividers(hdc);
}

/// A split divider under the cursor.
pub const DividerHit = struct {
    handle: SplitTree(Pane).Node.Handle,
    layout: SplitTree(Pane).Split.Layout,
    /// The split node's own rect (what a drag of this divider measures
    /// against).
    rect: w32.RECT,
};

pub fn hitTestDivider(self: *Window, x: i32, y: i32) ?DividerHit {
    const ws = self.activeWorkspace();
    const tree = &ws.tree;
    if (tree.isEmpty()) return null;
    if (!tree.isSplit()) return null;
    if (tree.zoomed != null) return null;
    var sfa = std.heap.stackFallback(layout.stack_bytes, self.app.core_app.alloc);
    const gpa = sfa.get();
    var lay = computeActiveLayout(self, gpa, self.surfaceRect()) orelse return null;
    defer lay.deinit(gpa);
    const d = lay.hitTest(x, y, self.scale) orelse return null;
    return .{ .handle = d.handle, .layout = d.layout, .rect = d.node_rect };
}

/// Start dragging the divider `hit`. The drag measures the cursor against
/// the dragged split's own rect, so nested dividers track the cursor
/// (ui-model 8.1 #2: the whole surface rect was used, which made every
/// non-root divider jump).
pub fn startDividerDrag(self: *Window, hit: DividerHit) void {
    self.dragging_split = true;
    self.drag_split_handle = hit.handle;
    self.drag_split_layout = hit.layout;
    self.drag_split_rect = hit.rect;
    if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
}

pub fn updateDividerDrag(self: *Window, x: i32, y: i32) void {
    if (!self.dragging_split) return;
    const ws = self.activeWorkspace();
    const handle = self.drag_split_handle;
    // The tree may have been replaced since the drag started (a pane
    // closed under it): only resize a split of the dragged orientation.
    if (handle.idx() >= ws.tree.nodes.len) return;
    switch (ws.tree.nodes[handle.idx()]) {
        .split => |s| if (s.layout != self.drag_split_layout) return,
        .leaf => return,
    }
    ws.tree.resizeInPlace(handle, layout.dragRatio(self.drag_split_layout, self.drag_split_rect, x, y));
    self.layoutSplits();
}

pub fn endDividerDrag(self: *Window) void {
    if (!self.dragging_split) return;
    self.dragging_split = false;
    _ = w32.ReleaseCapture();
}

/// Update the top-level window title to match the active tab's title.
pub fn updateWindowTitle(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const ws = self.activeWorkspace();
    const pane = ws.focusedPaneOrFirst() orelse return;
    const tab = pane.selectedTab() orelse return;
    var buf: [257]u16 = undefined;
    const len = titles.toUtf16(buf[0..256], tab.titleText());
    buf[len] = 0;
    _ = w32.SetWindowTextW(hwnd, @ptrCast(&buf));
}

/// Update tab bar visibility based on config and tab count.
pub fn updateTabBarVisibility(self: *Window) void {
    if (self.is_quick_terminal) {
        self.tab_bar_visible = false;
        return;
    }
    // When splits exist, the window-level tab bar is hidden — each
    // Pane paints its own tab bar within its layout_rect.
    const ws = self.activeWorkspace();
    if (ws.tree.isSplit()) {
        if (self.tab_bar_visible) {
            self.tab_bar_visible = false;
            self.handleResize();
        }
        return;
    }
    const show_config = self.app.config.@"window-show-tab-bar";
    // The top tab bar now COEXISTS with the sidebar: workspaces live in
    // the sidebar, and the tab bar shows the active workspace's tabs
    // (offset right by the sidebar width, see paintTabBar). Visibility
    // is purely a function of the tab count, never suppressed by the
    // sidebar.
    const should_show = switch (show_config) {
        .always => true,
        // wmux always shows the tab bar so the "+" new-tab button is
        // reachable even with a single tab.
        .auto => true,
        .never => false,
    };
    if (should_show != self.tab_bar_visible) {
        self.tab_bar_visible = should_show;
        self.handleResize();
    }
}

/// Invalidate the tab bar region so it gets repainted.
pub fn invalidateTabBar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const ws = self.activeWorkspace();

    if (ws.tree.isSplit()) {
        var it = ws.tree.iterator();
        while (it.next()) |entry| {
            const container = entry.view;
            if (container.tabCount() > 1) {
                const bar_h = tabbar_paint.barHeight(self.scale);
                var r = w32.RECT{
                    .left = container.layout_rect.left,
                    .top = container.layout_rect.top,
                    .right = container.layout_rect.right,
                    .bottom = container.layout_rect.top + bar_h,
                };
                _ = w32.InvalidateRect(hwnd, &r, 0);
            }
        }
        return;
    }

    var rect = w32.RECT{
        .left = 0,
        .top = 0,
        .right = 10000,
        .bottom = self.tabBarHeight(),
    };
    _ = w32.InvalidateRect(hwnd, &rect, 0);
}

/// Invalidate the sidebar region so it gets repainted.
pub fn invalidateSidebar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var rect = w32.RECT{
        .left = 0,
        .top = 0,
        .right = self.sidebarWidth(),
        .bottom = 32767,
    };
    _ = w32.InvalidateRect(hwnd, &rect, 0);
}

/// Handle WM_PAINT: paint the window chrome (tab bar and sidebar)
/// with a single BeginPaint/EndPaint pair.
pub fn paintChrome(self: *Window) void {
    const hwnd = self.hwnd orelse return;

    var ps: w32.PAINTSTRUCT = undefined;
    const hdc_screen = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);

    self.paintTabBar(hdc_screen);
    if (self.sidebarWidth() > 0) Sidebar.paint(self, hdc_screen);
    if (self.sidebarReshowStripVisible()) self.paintReshowStrip(hdc_screen);
    if (self.rightSidebarWidth() > 0) RightSidebar.paint(self, hdc_screen);
}

/// Paint the thin re-show strip at the window's left edge while the
/// sidebar is runtime-hidden: a narrow accent band with a "›" chevron so
/// the user can click to bring the sidebar back (Ctrl+B also works). Sits
/// below the tab bar so it doesn't fight the tab chrome. Direct GDI on the
/// parent window (the strip is over the surface's left edge, but the GL
/// child only repaints on its own; this floats on top until the next pane
/// repaint — acceptable for a static affordance, and toggling it off
/// relayouts/repaints the pane).
pub fn paintReshowStrip(self: *Window, hdc: w32.HDC) void {
    const hwnd = self.hwnd orelse return;
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0) return;
    const top = self.tabBarHeight();
    const w = self.sidebarReshowStripWidth();
    if (w <= 0 or client.bottom <= top) return;

    const bg = self.app.config.background;
    // Strip background: terminal bg + 30 per channel so it reads as a
    // grabbable edge against the surface.
    const sr: u8 = @min(@as(u16, bg.r) + 30, 255);
    const sg: u8 = @min(@as(u16, bg.g) + 30, 255);
    const sb: u8 = @min(@as(u16, bg.b) + 30, 255);
    var strip = w32.RECT{ .left = 0, .top = top, .right = w, .bottom = client.bottom };
    if (w32.CreateSolidBrush(w32.RGB(sr, sg, sb))) |brush| {
        _ = w32.FillRect(hdc, &strip, brush);
        _ = w32.DeleteObject(@ptrCast(brush));
    }

    // A "›" chevron centered vertically near the top of the strip hints
    // at "click to expand". Strip is narrow so it just fits the glyph.
    var old_font: ?*anyopaque = null;
    if (self.tab_font) |font| old_font = w32.SelectObject(hdc, font);
    defer {
        if (old_font) |f| _ = w32.SelectObject(hdc, f);
    }
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    _ = w32.SetTextColor(hdc, w32.RGB(200, 200, 200));
    var glyph_rect = w32.RECT{ .left = 0, .top = top, .right = w, .bottom = top + @as(i32, @intFromFloat(@round(40.0 * self.scale))) };
    if (glyph_rect.bottom > client.bottom) glyph_rect.bottom = client.bottom;
    const chevron = std.unicode.utf8ToUtf16LeStringLiteral("\u{203A}"); // ›
    _ = w32.DrawTextW(
        hdc,
        chevron,
        chevron.len,
        &glyph_rect,
        w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
    );
}

/// Whether client point (x, y) lies within the re-show edge strip (the
/// affordance that brings a runtime-hidden sidebar back). Pure-ish (reads
/// only the strip's visibility + width + tab bar height), so the WndProc
/// can route the click before the surface/divider checks.
pub fn hitTestReshowStrip(self: *const Window, x: i32, y: i32) bool {
    if (!self.sidebarReshowStripVisible()) return false;
    return x >= 0 and x < self.sidebarReshowStripWidth() and y >= self.tabBarHeight();
}

/// Toggle fullscreen mode on the top-level window.
/// Saves/restores window style and placement.
pub fn toggleFullscreen(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (!self.is_fullscreen) {
        self.saved_style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
        _ = w32.GetWindowRect(hwnd, &self.saved_rect);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, w32.WS_POPUP | w32.WS_VISIBLE_STYLE);
        const monitor = w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST);
        var mi: w32.MONITORINFO = undefined;
        mi.cbSize = @sizeOf(w32.MONITORINFO);
        if (w32.GetMonitorInfoW(monitor, &mi) != 0) {
            _ = w32.SetWindowPos(hwnd, null, mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
        }
    } else {
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, self.saved_style);
        _ = w32.SetWindowPos(hwnd, null, self.saved_rect.left, self.saved_rect.top, self.saved_rect.right - self.saved_rect.left, self.saved_rect.bottom - self.saved_rect.top, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
    }
    self.is_fullscreen = !self.is_fullscreen;
}

/// Toggle window decorations (title bar + borders) on/off.
pub fn toggleWindowDecorations(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
    const has_decorations = (style & w32.WS_CAPTION) != 0;

    if (has_decorations) {
        // Remove decorations: strip caption and thick frame.
        const new_style = style & ~@as(u32, w32.WS_CAPTION | w32.WS_THICKFRAME);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    } else {
        // Restore decorations.
        const new_style = style | w32.WS_CAPTION | w32.WS_THICKFRAME;
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    }
    // Force frame recalculation.
    _ = w32.SetWindowPos(hwnd, null, 0, 0, 0, 0, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED | w32.SWP_NOMOVE | w32.SWP_NOSIZE);
}

/// Handle WM_SIZE: re-layout the active tab's split panes and repaint
/// the tab bar and sidebar.
pub fn handleResize(self: *Window) void {
    self.layoutSplits();
    self.invalidateTabBar();
    self.invalidateSidebar();
}
