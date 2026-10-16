//! The per-window overlay pools (ARCHITECTURE.md ADR-1.8 W0-A2 step 4):
//! attention rings, pane corner buttons and the flash overlay, positioned
//! over the laid-out panes. Moved out of Window.zig in W0-A2.

const std = @import("std");

const AttentionRing = @import("AttentionRing.zig").AttentionRing;
const FlashOverlay = @import("FlashOverlay.zig").FlashOverlay;
const Pane = @import("../../model/Pane.zig");
const PaneButtonsMod = @import("PaneButtons.zig");
const PaneButtons = PaneButtonsMod.PaneButtons;
const SplitTree = @import("../../../../datastruct/split_tree.zig").SplitTree;
const Tab = @import("../../model/Tab.zig");
const Window = @import("../Window.zig");
const w32 = @import("../../platform/win32.zig");

const log = std.log.scoped(.win32);

/// Reconcile the notification-ring overlays with the current attention
/// state and layout. A ring is drawn around each pane of the ACTIVE
/// workspace's ACTIVE tab whose Surface.attention is set AND which is not
/// the focused/visible-active pane — you are never ringed around what you
/// are already looking at. Panes in other tabs/workspaces are not visible,
/// so they carry no ring; the sidebar row dot and top tab dot surface
/// those instead. Rings are reused from a pool; surplus rings are hidden.
/// Safe to call after any layout/attention/focus change; cheap when no
/// pane needs a ring (every existing ring is simply hidden).
pub fn updateAttentionRings(self: *Window) void {
    const hwnd = self.hwnd orelse return self.hideAllRings();
    if (self.closing) return self.hideAllRings();
    const ws = self.activeWorkspace();
    const tree = ws.tree;
    if (tree.isEmpty()) return self.hideAllRings();
    if (tree.zoomed != null) return self.hideAllRings();

    const focused_container = ws.focusedPaneOrFirst() orelse return self.hideAllRings();
    const focused = focused_container.selectedTab() orelse return self.hideAllRings();
    var next: usize = 0;
    self.attentionRingNode(hwnd, tree, .root, self.surfaceRect(), focused, &next);

    var i = next;
    while (i < self.attention_rings.items.len) : (i += 1) {
        self.attention_rings.items[i].hide();
    }
}

/// Hide every ring in the pool (no visible attention pane).
pub fn hideAllRings(self: *Window) void {
    for (self.attention_rings.items) |ring| ring.hide();
}

/// Borrow ring slot `idx` from the pool, growing it (creating a new
/// layered popup) on demand. Returns null if creation fails (the ring is
/// then simply skipped — attention still surfaces via the sidebar/tab
/// dots, so a GDI handle shortage degrades gracefully).
pub fn ringAt(self: *Window, idx: usize, hwnd: w32.HWND) ?*AttentionRing {
    if (idx < self.attention_rings.items.len) {
        const ring = self.attention_rings.items[idx];
        ring.setScale(self.scale);
        return ring;
    }
    const ring = AttentionRing.create(self.app.core_app.alloc, self.app.hinstance, hwnd) catch return null;
    ring.setScale(self.scale);
    self.attention_rings.append(self.app.core_app.alloc, ring) catch {
        ring.destroy();
        return null;
    };
    return ring;
}

/// Walk the workspace split tree mirroring layoutNode's geometry; for each
/// leaf container whose active pane is attention-flagged and not the focused
/// pane, position a pool ring around its client rect (screen coords).
pub fn attentionRingNode(
    self: *Window,
    hwnd: w32.HWND,
    tree: SplitTree(Pane),
    handle: SplitTree(Pane).Node.Handle,
    rect: w32.RECT,
    focused: *Tab,
    next: *usize,
) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => |container| {
            const pane = container.selectedTab() orelse return;
            if (pane == focused) return;
            const surface = pane.surface() orelse return;
            if (!surface.attention) return;
            const ring = self.ringAt(next.*, hwnd) orelse return;
            // Client rect → screen rect (the popup lives in screen coords).
            var tl = w32.POINT{ .x = rect.left, .y = rect.top };
            var br = w32.POINT{ .x = rect.right, .y = rect.bottom };
            _ = w32.ClientToScreen(hwnd, &tl);
            _ = w32.ClientToScreen(hwnd, &br);
            ring.positionAround(.{ .left = tl.x, .top = tl.y, .right = br.x, .bottom = br.y });
            next.* += 1;
        },
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.attentionRingNode(hwnd, tree, s.left, left_rect, focused, next);
                self.attentionRingNode(hwnd, tree, s.right, right_rect, focused, next);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.attentionRingNode(hwnd, tree, s.left, top_rect, focused, next);
                self.attentionRingNode(hwnd, tree, s.right, bottom_rect, focused, next);
            }
        },
    }
}

/// Reconcile the per-pane corner-button overlays with the current layout.
/// Policy: show a cluster on EVERY visible leaf pane of the active
/// workspace's active tab (every pane gets its action icons, always — not
/// just the focused one). Panes in other tabs/workspaces are not visible,
/// so they carry no cluster. A zoomed tab shows only its focused pane, so
/// it gets a single cluster. Cheap to call after any layout/focus change.
/// Runs AFTER updateAttentionRings each pass (called second in layoutSplits)
/// so the clickable cluster's popup is never occluded by a ring popup at the
/// shared top-right corner. Safe to call repeatedly; surplus overlays in
/// the pool are hidden.
pub fn updatePaneButtons(self: *Window) void {
    const hwnd = self.hwnd orelse return self.hideAllPaneButtons();
    if (self.closing) return self.hideAllPaneButtons();
    if (self.is_quick_terminal) return self.hideAllPaneButtons();
    const ws = self.activeWorkspace();
    const tree = ws.tree;
    if (tree.isEmpty()) return self.hideAllPaneButtons();

    const focused_container = ws.focusedPaneOrFirst() orelse return self.hideAllPaneButtons();
    const focused = focused_container.selectedTab() orelse return self.hideAllPaneButtons();

    var next: usize = 0;

    if (tree.zoomed) |zoomed_handle| {
        _ = zoomed_handle;
        self.placePaneButton(hwnd, focused, self.surfaceRect(), &next);
    } else {
        self.paneButtonsNode(hwnd, tree, .root, self.surfaceRect(), &next);
    }

    var i = next;
    while (i < self.pane_buttons.items.len) : (i += 1) {
        self.pane_buttons.items[i].hide();
    }
}

/// Hide every corner-button overlay in the pool.
pub fn hideAllPaneButtons(self: *Window) void {
    for (self.pane_buttons.items) |pb| pb.hide();
}

/// Borrow overlay slot `idx` from the pool, growing it (creating a new
/// layered popup) on demand. Returns null if creation fails (the cluster
/// is then simply skipped — a GDI handle shortage degrades to "no corner
/// icons", which is non-fatal).
pub fn paneButtonsAt(self: *Window, idx: usize, hwnd: w32.HWND) ?*PaneButtons {
    if (idx < self.pane_buttons.items.len) {
        const pb = self.pane_buttons.items[idx];
        pb.setScale(self.scale);
        return pb;
    }
    const pb = PaneButtons.create(self.app.core_app.alloc, self.app.hinstance, hwnd) catch return null;
    pb.setScale(self.scale);
    self.pane_buttons.append(self.app.core_app.alloc, pb) catch {
        pb.destroy();
        return null;
    };
    return pb;
}

/// Position one corner-button overlay around `pane`'s client rect (in
/// client coords; converted to screen here), binding it to the pane and
/// this window. `next` is the running count of overlays used this pass.
pub fn placePaneButton(self: *Window, hwnd: w32.HWND, pane: *Tab, rect: w32.RECT, next: *usize) void {
    const pb = self.paneButtonsAt(next.*, hwnd) orelse return;
    var tl = w32.POINT{ .x = rect.left, .y = rect.top };
    var br = w32.POINT{ .x = rect.right, .y = rect.bottom };
    _ = w32.ClientToScreen(hwnd, &tl);
    _ = w32.ClientToScreen(hwnd, &br);
    pb.positionAt(
        .{ .left = tl.x, .top = tl.y, .right = br.x, .bottom = br.y },
        pane,
        @ptrCast(self),
    );
    next.* += 1;
}

/// Walk the workspace split tree mirroring layoutNode's geometry; place a
/// corner cluster on EVERY leaf container's active pane.
pub fn paneButtonsNode(
    self: *Window,
    hwnd: w32.HWND,
    tree: SplitTree(Pane),
    handle: SplitTree(Pane).Node.Handle,
    rect: w32.RECT,
    next: *usize,
) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => |container| {
            const pane = container.selectedTab() orelse return;
            self.placePaneButton(hwnd, pane, rect, next);
        },
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.paneButtonsNode(hwnd, tree, s.left, left_rect, next);
                self.paneButtonsNode(hwnd, tree, s.right, right_rect, next);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.paneButtonsNode(hwnd, tree, s.left, top_rect, next);
                self.paneButtonsNode(hwnd, tree, s.right, bottom_rect, next);
            }
        },
    }
}

/// Routed from a corner-button overlay click (PaneButtons.on_click). The
/// `window` opaque is this *Window; `pane` is validated by address before
/// any action runs (it may have been closed since the overlay was
/// positioned). All four actions (New Terminal / New Browser / Split Right
/// / Split Down) operate on the active pane, so the target pane is brought
/// to the foreground and focused first.
pub fn onPaneButtonClick(window: *anyopaque, pane: *Tab, action: PaneButtonsMod.Action) void {
    const self: *Window = @ptrCast(@alignCast(window));
    if (self.closing) return;
    // Validate the pane still exists in this window (by address) and
    // bring its workspace/container to the foreground so the active-pane
    // actions (New Terminal/Browser/Split Right/Split Down) target it.
    const loc = self.findLoc(pane) orelse return;
    const ws_idx = self.workspaceIndex(loc.ws);
    if (ws_idx != self.activeIndex()) self.selectWorkspace(ws_idx);
    if (loc.pane.selected != loc.index) self.selectTabIndex(loc.index);
    // Focus the pane that owns the clicked tab.
    loc.ws.focused_pane = loc.pane;
    pane.focus();

    switch (action) {
        .new_terminal => _ = self.addTabInherit() catch |err| {
            log.err("corner New Terminal failed: {}", .{err});
        },
        .new_browser => self.newBrowserSplit(.right) catch |err| {
            log.err("corner New Browser failed: {}", .{err});
        },
        .split_right => self.newSplit(.right) catch |err| {
            log.err("corner Split Right failed: {}", .{err});
        },
        .split_down => self.newSplit(.down) catch |err| {
            log.err("corner Split Down failed: {}", .{err});
        },
    }
}

/// Flash the currently focused pane with a brief semi-transparent
/// border highlight. The flash auto-dismisses after ~200ms via a
/// WM_TIMER on the overlay's own HWND. Creates the overlay lazily
/// on first use. Safe to call repeatedly (re-triggers reset the timer).
pub fn flashFocusedPane(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const pane = self.getActiveTab() orelse return;
    const pane_hwnd = pane.hwnd() orelse return;

    // Get the focused pane's client rect in screen coordinates.
    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(pane_hwnd, &client_rect) == 0) return;
    var tl = w32.POINT{ .x = client_rect.left, .y = client_rect.top };
    var br = w32.POINT{ .x = client_rect.right, .y = client_rect.bottom };
    _ = w32.ClientToScreen(pane_hwnd, &tl);
    _ = w32.ClientToScreen(pane_hwnd, &br);
    const screen_rect = w32.RECT{
        .left = tl.x,
        .top = tl.y,
        .right = br.x,
        .bottom = br.y,
    };

    // Lazily create the flash overlay.
    if (self.flash_overlay == null) {
        self.flash_overlay = FlashOverlay.create(
            self.app.core_app.alloc,
            self.app.hinstance,
            hwnd,
        ) catch return;
    }
    const fo = self.flash_overlay.?;
    fo.setScale(self.scale);
    fo.flash(screen_rect);
}
