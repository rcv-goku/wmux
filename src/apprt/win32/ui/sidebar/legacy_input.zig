//! Mouse input of the legacy GDI sidebar (ARCHITECTURE.md ADR-1.8 W0-A2
//! step 4): clicks, hover, the edge drag-resize and the row drag-reorder.
//! Moved out of Window.zig in W0-A2; W1-8 replaces it with the input
//! handling of the sidebar child window (ADR-11).

const std = @import("std");

const Sidebar = @import("legacy_gdi.zig");
const Window = @import("../Window.zig");
const w32 = @import("../../platform/win32.zig");

const log = std.log.scoped(.win32);

/// True when x is inside the drag-resize grab band along the sidebar's
/// right edge. A hidden sidebar has no band.
pub fn hitTestSidebarEdge(self: *const Window, x: i32) bool {
    return Sidebar.hitTestEdge(x, self.sidebarWidth(), Sidebar.edgeBandWidth(self.scale));
}

pub fn startSidebarDrag(self: *Window) void {
    if (self.closing) return;
    self.dragging_sidebar = true;
    if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
}

pub fn updateSidebarDrag(self: *Window, x: i32) void {
    if (!self.dragging_sidebar or self.closing) return;
    const unscaled = std.math.clamp(
        @round(@as(f32, @floatFromInt(x)) / self.scale),
        @as(f32, @floatFromInt(Sidebar.MIN_WIDTH)),
        @as(f32, @floatFromInt(Sidebar.MAX_WIDTH)),
    );
    const new_width: u32 = @intFromFloat(unscaled);
    if (self.sidebar_width_override) |cur| if (cur == new_width) return;
    self.sidebar_width_override = new_width;
    // Same live relayout as the divider drag: move the surfaces and
    // repaint the chrome strips immediately.
    self.handleResize();
    if (self.hwnd) |h| _ = w32.UpdateWindow(h);
}

pub fn endSidebarDrag(self: *Window) void {
    if (!self.dragging_sidebar) return;
    self.dragging_sidebar = false;
    _ = w32.ReleaseCapture();
}

/// End an in-progress sidebar row drag-reorder, releasing capture if
/// one was held. Idempotent: a no-op when no row drag is active.
pub fn endSidebarRowDrag(self: *Window) void {
    if (self.sidebar_drag_row < 0) return;
    self.sidebar_drag_row = -1;
    self.sidebar_drag_active = false;
    _ = w32.ReleaseCapture();
}

/// Compute the target workspace row index for a sidebar row drag at
/// client y. Mirrors the tab bar's midpoint rule: the slot whose
/// midpoint the cursor has passed. Clamped to the valid workspace row
/// range (the sidebar lists workspaces, one row each).
pub fn sidebarDragTarget(self: *const Window, y: i32) usize {
    if (self.workspace_count == 0) return 0;
    const item_h = self.sidebarItemHeight();
    if (item_h <= 0) return 0;
    var target: usize = 0;
    for (0..self.workspace_count) |i| {
        const slot_top: i32 = @as(i32, @intCast(i)) * item_h;
        const slot_mid = slot_top + @divTrunc(item_h, 2);
        if (y >= slot_mid) target = i;
    }
    if (target >= self.workspace_count) target = self.workspace_count - 1;
    return target;
}

/// Handle a middle-button click in the sidebar region: close the
/// clicked workspace row through the same closeWorkspace path as the
/// row's close 'x' (the 'x' band is part of the row, so it closes
/// too). Every other target — "+ New workspace", its "▾" segment, the
/// notification panel, and the footer icons — is a no-op.
pub fn handleSidebarMiddleClick(self: *Window, x: i32, y: i32) void {
    if (self.closing) return;
    switch (self.sidebarHitTest(x, y)) {
        .workspace, .row_close => |i| self.closeWorkspace(i),
        else => {},
    }
}

/// Hit-test a client point against the sidebar with this window's
/// current geometry and notification state.
pub fn sidebarHitTest(self: *Window, x: i32, y: i32) Sidebar.HitTarget {
    const hwnd = self.hwnd orelse return .none;
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) return .none;
    return Sidebar.hitTest(x, y, .{
        .item_h = self.sidebarItemHeight(),
        // The sidebar renders one row per workspace.
        .workspace_count = self.workspace_count,
        .client_h = rect.bottom - rect.top,
        .width = self.sidebarWidth(),
        .scale = self.scale,
        .panel_open = self.notif_panel_open,
        .notif_count = self.app.notifCount(),
    });
}

/// Handle a left-button click in the sidebar region.
/// Selects the clicked workspace row or creates a new workspace.
pub fn handleSidebarClick(self: *Window, x: i32, y: i32) void {
    if (self.closing) return;
    switch (self.sidebarHitTest(x, y)) {
        .none => {},
        .workspace => |i| {
            // Switch to the clicked workspace, then begin tracking a
            // potential row drag-reorder (moveWorkspaceTo). The drag only
            // activates past the threshold in WM_MOUSEMOVE, so a plain
            // click stays a select. selectWorkspace must run FIRST: it
            // clears any in-progress row drag, which would otherwise wipe
            // the state we set here.
            self.selectWorkspace(i);
            self.sidebar_drag_row = @intCast(i);
            self.sidebar_drag_start_y = y;
            self.sidebar_drag_active = false;
            if (self.hwnd) |h| _ = w32.SetCapture(h);
        },
        .row_close => |i| self.closeWorkspace(i),
        .new_session => self.newWorkspace(),
        .new_session_dropdown => {
            // Anchor the picker under the "+ New workspace" row (Windows
            // Terminal dropdown feel) rather than at the click point. The
            // row sits at index workspace_count (below the workspace rows).
            // The picked backend becomes the FIRST TAB of a NEW WORKSPACE
            // (this row creates workspaces; the tab bar's ▾ is the
            // new-tab-in-active-workspace picker).
            const row = Sidebar.itemRect(
                self.workspace_count,
                self.sidebarWidth(),
                self.sidebarItemHeight(),
            );
            self.showBackendMenu(row.left, row.bottom, .new_workspace);
        },
        .bell_icon => {
            self.notif_panel_open = !self.notif_panel_open;
            self.app.markNotifsRead();
            self.invalidateSidebar();
        },
        .gear_icon => self.app.openConfigFile(),
        .browser_icon => self.newBrowserSplit(.right) catch |err| {
            log.err("failed to open browser split: {}", .{err});
        },
        .collapse_toggle => self.toggleSidebar(),
        .notif_entry => |i| {
            if (self.app.notifAt(i)) |entry| {
                const window = entry.window;
                const surface = entry.surface;
                if (self.app.jumpToSurface(window, surface)) {
                    // Unread → Read for the clicked entry (and lower the
                    // taskbar badge). Opening the panel already marks all
                    // entries Read, but a click is an explicit per-entry view.
                    _ = self.app.markNotifEntryRead(i);
                }
            }
        },
        .notif_clear => {
            self.app.clearNotifs();
            self.invalidateSidebar();
        },
    }
}

/// Handle a right-button click in the sidebar region: show the tab
/// context menu for the active workspace's active tab when a workspace
/// row is clicked, or the settings menu for the gear icon. STEP 3
/// replaces the row context with a workspace context menu (rename, etc.).
pub fn handleSidebarRightClick(self: *Window, x: i32, y: i32) void {
    if (self.closing) return;
    switch (self.sidebarHitTest(x, y)) {
        // A workspace row (or its close 'x' band) opens the workspace
        // context menu (rename / close / new workspace).
        .workspace => |i| self.showWorkspaceContextMenu(i, x, y),
        .row_close => |i| self.showWorkspaceContextMenu(i, x, y),
        .gear_icon => self.showGearContextMenu(x, y),
        // Right-clicking the "+ New workspace" row (or its ▾ chevron)
        // opens the picker with the same new-workspace target as the
        // chevron's left-click.
        .new_session, .new_session_dropdown => self.showBackendMenu(x, y, .new_workspace),
        else => {},
    }
}

/// Handle mouse movement over the sidebar for hover effects.
/// Registers TrackMouseEvent on first move so we get WM_MOUSELEAVE.
pub fn handleSidebarMouseMove(self: *Window, x: i32, y: i32) void {
    if (self.closing) return;

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

    const new_hover = self.sidebarHitTest(x, y);
    if (!std.meta.eql(new_hover, self.sidebar_hover)) {
        self.sidebar_hover = new_hover;
        self.invalidateSidebar();
    }
}

/// Reset sidebar hover state when the mouse leaves the sidebar.
pub fn clearSidebarHover(self: *Window) void {
    if (self.sidebar_hover != .none) {
        self.sidebar_hover = .none;
        self.invalidateSidebar();
    }
}
