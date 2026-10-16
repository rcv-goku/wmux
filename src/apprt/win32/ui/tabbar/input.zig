//! Tab bar mouse input (ARCHITECTURE.md ADR-1.8 W0-A2 step 4): clicks,
//! middle clicks, right clicks, hover and drag reorder in the window-top
//! bar and in the per-pane bars of a split workspace. Moved out of
//! Window.zig in W0-A2. Every hit-test uses the bar geometry the painter
//! uses (paint.barGeometry, logic/geometry.zig).

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

/// Select tab `i` of the focused pane and arm a potential drag reorder.
fn selectAndArmDrag(self: *Window, i: usize, x: i16) void {
    self.selectTabIndex(i);
    self.drag_tab = @intCast(i);
    self.drag_start_x = x;
    self.drag_active = false;
    if (self.hwnd) |h| _ = w32.SetCapture(h);
    self.invalidateTabBar();
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

        const geo = tabbar_paint.barGeometry(self, container) orelse return;
        switch (geo.hit(x)) {
            .dropdown => {
                self.showBackendMenu(geo.newTabSpan().left, container.layout_rect.top + geo.bar_h, .new_tab);
                return;
            },
            .new_tab => {
                _ = self.addTabInherit() catch |err| {
                    log.err("failed to create new tab: {}", .{err});
                    return;
                };
                return;
            },
            .close => |i| {
                self.closeTabByIndex(i);
                return;
            },
            .tab => |i| {
                selectAndArmDrag(self, i, x);
                return;
            },
            .none => {},
        }
        self.invalidateTabBar();
        return;
    }

    // Single-pane mode: the window-top tab bar.
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;

    const container = ws.focusedContainerOrFirst() orelse return;
    const geo = tabbar_paint.barGeometry(self, container) orelse return;
    switch (geo.hit(x)) {
        .dropdown => self.showBackendMenu(geo.newTabSpan().left, self.tabBarHeight(), .new_tab),
        .new_tab => {
            _ = self.addTabInherit() catch |err| {
                log.err("failed to create new tab: {}", .{err});
                return;
            };
        },
        .close => |i| self.closeTabByIndex(i),
        .tab => |i| selectAndArmDrag(self, i, x),
        .none => {},
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
        const geo = tabbar_paint.barGeometry(self, container) orelse return;
        if (geo.tabAt(x)) |i| self.closeTabByIndex(i);
        return;
    }

    // Single-pane mode.
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;
    const container = ws.focusedContainerOrFirst() orelse return;
    const geo = tabbar_paint.barGeometry(self, container) orelse return;
    if (geo.tabAt(x)) |i| self.closeTabByIndex(i);
}

/// The hover state a point over a tab bar maps to.
const Hover = struct {
    tab: ?usize = null,
    close: ?usize = null,
    new_tab: bool = false,
    dropdown: bool = false,
};

fn hoverAt(geo: anytype, x: i32) Hover {
    return switch (geo.hit(x)) {
        .none => .{},
        .new_tab => .{ .new_tab = true },
        .dropdown => .{ .dropdown = true },
        .tab => |i| .{ .tab = i },
        .close => |i| .{ .tab = i, .close = i },
    };
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
            const hover: Hover = if (hit_container != null and c.eql(hit_container.?))
                if (tabbar_paint.barGeometry(self, c)) |geo| hoverAt(geo, x) else .{}
            else
                .{};

            if (hover.tab != c.hovered_tab_idx or hover.close != c.hovered_close_idx or
                hover.new_tab != c.hovered_new_tab or hover.dropdown != c.hovered_dropdown)
            {
                c.hovered_tab_idx = hover.tab;
                c.hovered_close_idx = hover.close;
                c.hovered_new_tab = hover.new_tab;
                c.hovered_dropdown = hover.dropdown;
                changed = true;
            }
        }
        if (changed) self.invalidateTabBar();
        return;
    }

    // Single-pane mode: the window-top bar's hover state lives on Window.
    if (!self.tab_bar_visible) return;

    var hover: Hover = .{};
    if (y < self.tabBarHeight()) {
        const container = ws.focusedContainerOrFirst() orelse return;
        if (tabbar_paint.barGeometry(self, container)) |geo| hover = hoverAt(geo, x);
    }
    const new_hover: isize = if (hover.tab) |i| @intCast(i) else -1;
    const new_close = hover.close != null;

    if (new_hover != self.hover_tab or new_close != self.hover_close or
        hover.new_tab != self.hover_new_tab or hover.dropdown != self.hover_new_tab_dropdown)
    {
        self.hover_tab = new_hover;
        self.hover_close = new_close;
        self.hover_new_tab = hover.new_tab;
        self.hover_new_tab_dropdown = hover.dropdown;
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

        const geo = tabbar_paint.barGeometry(self, container) orelse return;
        if (geo.newTabSpan().contains(x) or geo.dropdownSpan().contains(x)) {
            self.showBackendMenu(x, y, .new_tab);
            return;
        }
        self.showTabContextMenu(geo.tabAt(x), x, y);
        return;
    }

    // Single-pane mode.
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;

    const ctx_container = ws.focusedContainerOrFirst() orelse return;
    const geo = tabbar_paint.barGeometry(self, ctx_container) orelse return;
    if (geo.newTabSpan().contains(x) or geo.dropdownSpan().contains(x)) {
        self.showBackendMenu(x, y, .new_tab);
        return;
    }
    self.showTabContextMenu(geo.tabAt(x), x, y);
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

/// Drag-reorder step of WM_MOUSEMOVE while a tab of the focused pane is
/// held: the target slot comes from that pane's own bar geometry (so a
/// drag in a split pane's bar tracks that bar).
pub fn updateTabDrag(self: *Window, x: i32) void {
    const xi16: i16 = @truncate(x);
    const dx = if (xi16 > self.drag_start_x) xi16 - self.drag_start_x else self.drag_start_x - xi16;
    if (!self.drag_active and dx > 5) {
        self.drag_active = true;
    }
    const drag_container = self.activeWorkspace().focusedContainerOrFirst() orelse return;
    if (!self.drag_active or drag_container.tab_count <= 1) return;
    const geo = tabbar_paint.barGeometry(self, drag_container) orelse return;
    const from: usize = @intCast(self.drag_tab);
    const target = geo.dragTarget(x);
    if (target != from) {
        self.moveTabTo(from, target);
        self.drag_tab = @intCast(target);
        if (self.hwnd) |h| _ = w32.UpdateWindow(h);
    }
}

/// Handle WM_LBUTTONDBLCLK over a tab bar: a double-click on a tab starts
/// its inline rename. Returns true when the point was over a tab bar (the
/// split pane bar it hit, or the window-top bar), whether or not a tab was
/// under it, so the caller stops routing.
pub fn handleTabBarDoubleClick(self: *Window, x: i32, y: i32) bool {
    // Split mode: check per-container tab bars.
    if (self.hitTestSplitTabBar(x, y)) |dbl_container| {
        const ws = self.activeWorkspace();
        ws.focused_container = dbl_container;
        self.clearTabAttention(dbl_container, dbl_container.active_tab);
        self.invalidateTabBar();
        const geo = tabbar_paint.barGeometry(self, dbl_container) orelse return true;
        if (geo.tabAt(x)) |i| self.startTabRename(i);
        return true;
    }
    // Single-pane mode: window-top tab bar.
    if (y < self.tabBarHeight()) {
        const dbl_container = self.activeWorkspace().focusedContainerOrFirst() orelse return true;
        const geo = tabbar_paint.barGeometry(self, dbl_container) orelse return true;
        if (geo.tabAt(x)) |i| self.startTabRename(i);
        return true;
    }
    return false;
}
