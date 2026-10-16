//! Tab bar mouse input (ARCHITECTURE.md ADR-1.8 W0-A2 step 4): clicks,
//! middle clicks, right clicks, hover and drag reorder in the window-top
//! bar and in the per-pane bars of a split workspace. Moved out of
//! Window.zig in W0-A2.

const std = @import("std");

const Pane = @import("../../model/Pane.zig");
const Window = @import("../Window.zig");
const tabbar_paint = @import("paint.zig");
const w32 = @import("../../platform/win32.zig");

const log = std.log.scoped(.win32);

/// Hit-test a client point against per-pane tab bars in split mode.
/// Returns the Pane whose tab bar strip contains (x, y), or
/// null if no container's bar is at that point (or no splits exist).
pub fn hitTestSplitTabBar(self: *Window, x: i32, y: i32) ?*Pane {
    const ws = self.activeWorkspace();
    if (!ws.split_tree.isSplit()) return null;
    const bar_h = tabbar_paint.barHeight(self.scale);
    var it = ws.split_tree.iterator();
    while (it.next()) |entry| {
        const container = entry.view;
        if (container.tab_count <= 1) continue;
        const lr = container.layout_rect;
        if (x >= lr.left and x < lr.right and y >= lr.top and y < lr.top + bar_h) {
            return container;
        }
    }
    return null;
}

/// Clear per-container hover state on all Pane leaves.
pub fn clearAllContainerHover(self: *Window) void {
    const ws = self.activeWorkspace();
    var it = ws.split_tree.iterator();
    while (it.next()) |entry| {
        const c = entry.view;
        c.hovered_tab_idx = null;
        c.hovered_close_idx = null;
        c.hovered_new_tab = false;
        c.hovered_dropdown = false;
    }
}

/// Handle a left-button click in the tab bar region.
/// Dispatches to addTab, closeTab, or selectTabIndex depending on hit position.
pub fn handleTabBarClick(self: *Window, x: i16, y: i16) void {
    const ws = self.activeWorkspace();

    // Split mode: route click to the correct Pane's tab bar.
    if (ws.split_tree.isSplit()) {
        const container = self.hitTestSplitTabBar(x, y) orelse return;
        ws.focused_container = container;
        self.clearTabAttention(container, container.active_tab);

        if (x >= container.new_tab_dropdown_rect.left and x < container.new_tab_dropdown_rect.right) {
            const bar_h = tabbar_paint.barHeight(self.scale);
            self.showBackendMenu(container.new_tab_btn_rect.left, container.layout_rect.top + bar_h, .new_tab);
            return;
        }

        if (x >= container.new_tab_btn_rect.left and x < container.new_tab_btn_rect.right) {
            _ = self.addTabInherit() catch |err| {
                log.err("failed to create new tab: {}", .{err});
                return;
            };
            return;
        }

        for (0..container.tab_rect_count) |i| {
            const rect = container.tab_rects[i];
            if (x >= rect.left and x < rect.right) {
                const close_btn_w: i32 = @intFromFloat(@round(20.0 * self.scale));
                const text_pad: i32 = @intFromFloat(@round(10.0 * self.scale));
                const close_left = rect.right - close_btn_w - @divTrunc(text_pad, 2);
                if (x >= close_left) {
                    self.closeTabByIndex(i);
                } else {
                    self.selectTabIndex(i);
                    self.drag_tab = @intCast(i);
                    self.drag_start_x = x;
                    self.drag_active = false;
                    if (self.hwnd) |h| _ = w32.SetCapture(h);
                    self.invalidateTabBar();
                }
                return;
            }
        }
        self.invalidateTabBar();
        return;
    }

    // Single-pane mode: existing window-top tab bar hit-testing.
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;

    if (x >= self.new_tab_dropdown_rect.left and x < self.new_tab_dropdown_rect.right) {
        self.showBackendMenu(self.new_tab_rect.left, self.tabBarHeight(), .new_tab);
        return;
    }

    if (x >= self.new_tab_rect.left and x < self.new_tab_rect.right) {
        _ = self.addTabInherit() catch |err| {
            log.err("failed to create new tab: {}", .{err});
            return;
        };
        return;
    }

    const close_btn_w: i32 = @intFromFloat(@round(20.0 * self.scale));
    const text_pad: i32 = @intFromFloat(@round(10.0 * self.scale));
    const container = ws.focusedContainerOrFirst() orelse return;
    for (0..container.tab_count) |i| {
        const rect = self.tab_rects[i];
        if (x >= rect.left and x < rect.right) {
            const close_left = rect.right - close_btn_w - @divTrunc(text_pad, 2);
            if (x >= close_left) {
                self.closeTabByIndex(i);
            } else {
                self.selectTabIndex(i);
                self.drag_tab = @intCast(i);
                self.drag_start_x = x;
                self.drag_active = false;
                if (self.hwnd) |h| _ = w32.SetCapture(h);
                self.invalidateTabBar();
            }
            return;
        }
    }
}

/// Handle a middle-button click in the tab bar region: close the
/// clicked tab (the browser / Windows Terminal convention), through
/// the same closeTabByIndex path as the tab's close 'x'. The "+"
/// button, its "▾" segment, and the empty strip are no-ops. Fires on
/// the button-down press, matching how handleTabBarClick fires the
/// close 'x' on WM_LBUTTONDOWN.
pub fn handleTabBarMiddleClick(self: *Window, x: i16, y: i16) void {
    const ws = self.activeWorkspace();

    // Split mode: route to the correct container's tab bar.
    if (ws.split_tree.isSplit()) {
        const container = self.hitTestSplitTabBar(x, y) orelse return;
        ws.focused_container = container;
        self.clearTabAttention(container, container.active_tab);
        self.invalidateTabBar();
        for (0..container.tab_rect_count) |i| {
            const rect = container.tab_rects[i];
            if (x >= rect.left and x < rect.right) {
                self.closeTabByIndex(i);
                return;
            }
        }
        return;
    }

    // Single-pane mode.
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;
    const container = ws.focusedContainerOrFirst() orelse return;
    for (0..container.tab_count) |i| {
        const rect = self.tab_rects[i];
        if (x >= rect.left and x < rect.right) {
            self.closeTabByIndex(i);
            return;
        }
    }
}

/// Handle mouse movement over the tab bar for hover effects.
/// Registers TrackMouseEvent on first move so we get WM_MOUSELEAVE.
pub fn handleTabBarMouseMove(self: *Window, x: i16, y: i16) void {
    // Register for WM_MOUSELEAVE if not already tracking.
    if (!self.tracking_mouse) {
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.hwnd.?,
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
        self.tracking_mouse = true;
    }

    const ws = self.activeWorkspace();

    // Split mode: find which container's tab bar the mouse is over and
    // update per-container hover state; clear hover on all others.
    if (ws.split_tree.isSplit()) {
        const hit_container = self.hitTestSplitTabBar(x, y);
        var changed = false;
        var it = ws.split_tree.iterator();
        while (it.next()) |entry| {
            const c = entry.view;
            if (hit_container != null and c.eql(hit_container.?)) {
                var new_tab: ?usize = null;
                var new_close: ?usize = null;
                var new_new_tab = false;
                var new_dropdown = false;

                if (x >= c.new_tab_btn_rect.left and x < c.new_tab_btn_rect.right) {
                    new_new_tab = true;
                } else if (x >= c.new_tab_dropdown_rect.left and x < c.new_tab_dropdown_rect.right) {
                    new_dropdown = true;
                } else {
                    const close_btn_w: i32 = @intFromFloat(@round(20.0 * self.scale));
                    const text_pad: i32 = @intFromFloat(@round(10.0 * self.scale));
                    for (0..c.tab_rect_count) |i| {
                        const rect = c.tab_rects[i];
                        if (x >= rect.left and x < rect.right) {
                            new_tab = i;
                            const close_left = rect.right - close_btn_w - @divTrunc(text_pad, 2);
                            if (x >= close_left) new_close = i;
                            break;
                        }
                    }
                }

                if (new_tab != c.hovered_tab_idx or new_close != c.hovered_close_idx or
                    new_new_tab != c.hovered_new_tab or new_dropdown != c.hovered_dropdown)
                {
                    c.hovered_tab_idx = new_tab;
                    c.hovered_close_idx = new_close;
                    c.hovered_new_tab = new_new_tab;
                    c.hovered_dropdown = new_dropdown;
                    changed = true;
                }
            } else {
                if (c.hovered_tab_idx != null or c.hovered_close_idx != null or
                    c.hovered_new_tab or c.hovered_dropdown)
                {
                    c.hovered_tab_idx = null;
                    c.hovered_close_idx = null;
                    c.hovered_new_tab = false;
                    c.hovered_dropdown = false;
                    changed = true;
                }
            }
        }
        if (changed) self.invalidateTabBar();
        return;
    }

    // Single-pane mode: existing window-top hover logic.
    if (!self.tab_bar_visible) return;

    var new_hover: isize = -1;
    var new_close = false;
    var new_new_tab = false;
    var new_dropdown = false;

    if (y < self.tabBarHeight()) {
        if (x >= self.new_tab_rect.left and x < self.new_tab_rect.right) {
            new_new_tab = true;
        } else if (x >= self.new_tab_dropdown_rect.left and x < self.new_tab_dropdown_rect.right) {
            new_dropdown = true;
        } else {
            const close_btn_w: i32 = @intFromFloat(@round(20.0 * self.scale));
            const text_pad: i32 = @intFromFloat(@round(10.0 * self.scale));
            const container = ws.focusedContainerOrFirst() orelse return;
            for (0..container.tab_count) |i| {
                const rect = self.tab_rects[i];
                if (x >= rect.left and x < rect.right) {
                    new_hover = @intCast(i);
                    const close_left = rect.right - close_btn_w - @divTrunc(text_pad, 2);
                    new_close = x >= close_left;
                    break;
                }
            }
        }
    }

    if (new_hover != self.hover_tab or new_close != self.hover_close or
        new_new_tab != self.hover_new_tab or new_dropdown != self.hover_new_tab_dropdown)
    {
        self.hover_tab = new_hover;
        self.hover_close = new_close;
        self.hover_new_tab = new_new_tab;
        self.hover_new_tab_dropdown = new_dropdown;
        self.invalidateTabBar();
    }
}

/// Handle a right-button click in the tab bar region.
/// Shows a context menu for the clicked tab.
pub fn handleTabBarRightClick(self: *Window, x: i16, y: i16) void {
    const ws = self.activeWorkspace();

    // Split mode: route to the correct container's tab bar.
    if (ws.split_tree.isSplit()) {
        const container = self.hitTestSplitTabBar(x, y) orelse return;
        ws.focused_container = container;
        self.clearTabAttention(container, container.active_tab);
        self.invalidateTabBar();

        if ((x >= container.new_tab_btn_rect.left and x < container.new_tab_btn_rect.right) or
            (x >= container.new_tab_dropdown_rect.left and x < container.new_tab_dropdown_rect.right))
        {
            self.showBackendMenu(x, y, .new_tab);
            return;
        }

        var clicked_tab: ?usize = null;
        for (0..container.tab_rect_count) |i| {
            const rect = container.tab_rects[i];
            if (x >= rect.left and x < rect.right) {
                clicked_tab = i;
                break;
            }
        }
        self.showTabContextMenu(clicked_tab, x, y);
        return;
    }

    // Single-pane mode.
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;

    if ((x >= self.new_tab_rect.left and x < self.new_tab_rect.right) or
        (x >= self.new_tab_dropdown_rect.left and x < self.new_tab_dropdown_rect.right))
    {
        self.showBackendMenu(x, y, .new_tab);
        return;
    }

    const ctx_container = ws.focusedContainerOrFirst() orelse return;
    var clicked_tab: ?usize = null;
    for (0..ctx_container.tab_count) |i| {
        const rect = self.tab_rects[i];
        if (x >= rect.left and x < rect.right) {
            clicked_tab = i;
            break;
        }
    }

    self.showTabContextMenu(clicked_tab, x, y);
}

/// Handle WM_MOUSELEAVE: reset all hover state and repaint.
pub fn handleTabBarMouseLeave(self: *Window) void {
    self.tracking_mouse = false;
    var needs_repaint = false;
    if (self.hover_tab != -1 or self.hover_new_tab or self.hover_new_tab_dropdown) {
        self.hover_tab = -1;
        self.hover_close = false;
        self.hover_new_tab = false;
        self.hover_new_tab_dropdown = false;
        needs_repaint = true;
    }
    // Clear per-container hover state (split mode).
    const ws = self.activeWorkspace();
    if (ws.split_tree.isSplit()) {
        var it = ws.split_tree.iterator();
        while (it.next()) |entry| {
            const c = entry.view;
            if (c.hovered_tab_idx != null or c.hovered_close_idx != null or
                c.hovered_new_tab or c.hovered_dropdown)
            {
                c.hovered_tab_idx = null;
                c.hovered_close_idx = null;
                c.hovered_new_tab = false;
                c.hovered_dropdown = false;
                needs_repaint = true;
            }
        }
    }
    if (needs_repaint) self.invalidateTabBar();
}
