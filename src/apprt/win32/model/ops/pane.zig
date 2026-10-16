//! Pane (split-tree leaf) operations of the window model (ARCHITECTURE.md
//! ADR-1.8 W0-A2 step 2): splits, navigation, swap, resize, equalize,
//! predefined layouts and zoom. Moved out of Window.zig in W0-A2. The
//! operations emit their pane.*/surface.* lifecycle events (ADR-3.10).

const std = @import("std");

const apprt = @import("../../../../apprt.zig");
const BrowserPane = @import("../../web/BrowserPane.zig");
const Pane = @import("../Pane.zig");
const SplitTree = @import("../../../../datastruct/split_tree.zig").SplitTree;
const Surface = @import("../../Surface.zig");
const Tab = @import("../Tab.zig");
const Window = @import("../../ui/Window.zig");
const Workspace = @import("../Workspace.zig");
const emit = @import("lifecycle_events.zig");
const ids = @import("../ids.zig");
const model_registry = @import("../registry.zig");
const pane_layout = @import("../layout.zig");
const ops_surface = @import("surface.zig");
const w32 = @import("../../platform/win32.zig");

/// Replace the split tree of `ws` with `new_tree`: publish the new tree
/// (and the derived zoomed pane) first, then drop the old one, so
/// re-entrant window procedures never observe a tree being torn down.
pub fn installTree(ws: *Workspace, new_tree: SplitTree(Pane)) void {
    var old_tree = ws.tree;
    ws.tree = new_tree;
    ws.syncZoomed();
    old_tree.deinit();
}

/// Split `src_handle` of `ws` in `direction` with a new pane holding the
/// single `tab` (whose one reference moves into the new pane), registered
/// in `reg` with `pane_uuid` (a fresh UUID when nil or taken). On failure
/// the tab's reference is released.
fn splitWithTab(
    alloc: std.mem.Allocator,
    reg: *model_registry.HandleRegistry,
    ws: *Workspace,
    src_handle: SplitTree(Pane).Node.Handle,
    direction: SplitTree(Pane).Split.Direction,
    tab: *Tab,
    pane_uuid: ids.Uuid,
) !*Pane {
    const new_container = Pane.create(alloc) catch |err| {
        tab.unref(alloc);
        return err;
    };
    ops_surface.insert(alloc, new_container, tab, 0) catch |err| {
        alloc.destroy(new_container);
        tab.unref(alloc);
        return err;
    };
    new_container.selected = 0;
    new_container.workspace = ws;

    // From here the throwaway insert tree owns the pane (and through it
    // the tab): its deinit releases both if the split fails.
    var insert_tree = SplitTree(Pane).init(alloc, new_container) catch |err| {
        _ = ops_surface.remove(new_container, 0);
        new_container.tabs.deinit(alloc);
        alloc.destroy(new_container);
        tab.unref(alloc);
        return err;
    };
    defer insert_tree.deinit();

    // A failure from here on unrefs the pane through insert_tree, whose
    // destroy path retires the handle.
    try model_registry.registerUuid(reg, alloc, new_container, pane_uuid);

    const new_tree = try ws.tree.split(
        alloc,
        src_handle,
        direction,
        @as(f16, 0.5),
        &insert_tree,
    );
    installTree(ws, new_tree);
    return new_container;
}

/// Create a new split in the active workspace. Splits inherit the source
/// pane's backend: a split off a WSL or PowerShell tab opens the same shell.
/// Browser panes have no terminal surface, so a split off one falls back to
/// the configured default. Creates a new Pane as a sibling leaf.
pub fn newSplit(self: *Window, direction: SplitTree(Pane).Split.Direction) !void {
    const ws = self.activeWorkspace();
    const container = ws.focusedPaneOrFirst() orelse return;
    const command: ?[]const []const u8 = if (container.selectedTab()) |p|
        if (p.surface()) |src| src.spawn_command else null
    else
        null;
    return self.newSplitWithCommand(direction, command);
}

/// Like newSplit, but with an explicit command override (the backend
/// picker) instead of inheriting the source pane's backend.
pub fn newSplitWithCommand(
    self: *Window,
    direction: SplitTree(Pane).Split.Direction,
    command: ?[]const []const u8,
) !void {
    _ = try self.newSplitInWorkspace(self.activeIndex(), direction, command, true);
}

/// Split the focused Pane of workspace `ws_idx` in `direction`,
/// creating a new Pane with one terminal tab as a sibling leaf
/// in the workspace split tree. With `focus` true, the new pane is
/// focused and laid out (interactive UX). With `focus` false, the new
/// pane is created hidden (agent `+split` without `--focus`).
/// Returns the new tab.
pub fn newSplitInWorkspace(
    self: *Window,
    ws_idx: usize,
    direction: SplitTree(Pane).Split.Direction,
    command: ?[]const []const u8,
    focus: bool,
) !*Tab {
    if (self.closing) return error.WindowClosing;
    if (ws_idx >= self.workspaces.items.len) return error.NoWindow;
    const ws = self.workspaces.items[ws_idx];
    const alloc = self.app.core_app.alloc;

    const src_container = ws.focusedPaneOrFirst() orelse return error.UnknownPane;
    const src_handle = ws.paneHandle(src_container) orelse return error.UnknownPane;

    // The new pane is created after the tab; its UUID is fixed now so the
    // terminal is spawned with it.
    const pane_uuid = ids.Uuid.v4();
    const new_tab = try ops_surface.createTerminalTab(self, ws, pane_uuid, .split, command, null);
    ops_surface.initTitle(alloc, new_tab, null, ops_surface.terminal_default_title) catch |err| {
        new_tab.unref(alloc);
        return err;
    };

    const is_visible = focus and ws_idx == self.activeIndex();
    if (!is_visible) {
        if (new_tab.hwnd()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
    }

    const new_container = try splitWithTab(alloc, &self.app.handles, ws, src_handle, direction, new_tab, pane_uuid);
    emit.paneCreated(self, ws, new_container, "pane.created", src_container, @tagName(direction), "terminal_split");
    emit.surfaceCreated(self, ws, new_container, new_tab, "terminal_split", focus);

    if (focus) {
        ws.focused_pane = new_container;
        if (is_visible) {
            self.updateTabBarVisibility();
            self.layoutSplits();
        }
        new_tab.focus();
    } else {
        if (ws_idx == self.activeIndex()) {
            self.updateTabBarVisibility();
            self.layoutSplits();
        }
    }
    self.invalidateSidebar();
    if (focus) emit.paneFocused(self, ws, new_container, "terminal_split");
    return new_tab;
}

/// Create a new browser (WebView2) split in the active workspace, in
/// the given direction off the focused pane. Creates a new
/// Pane with the browser tab as its sole tab.
pub fn newBrowserSplit(self: *Window, direction: SplitTree(Pane).Split.Direction) !void {
    if (self.closing) return;
    const ws = self.activeWorkspace();
    const src_container = ws.focusedPaneOrFirst() orelse return;
    const src_handle = ws.paneHandle(src_container) orelse return;
    self.cancelTabRename();

    const alloc = self.app.core_app.alloc;

    const browser = try BrowserPane.create(alloc, self.app, self);
    // From here the tab owns the browser: releasing the tab destroys it.
    const browser_tab = try ops_surface.createBrowserTab(self, browser);
    ops_surface.initTitle(alloc, browser_tab, null, ops_surface.browser_default_title) catch |err| {
        browser_tab.unref(alloc);
        return err;
    };

    const new_container = try splitWithTab(alloc, &self.app.handles, ws, src_handle, direction, browser_tab, ids.Uuid.nil);
    emit.paneCreated(self, ws, new_container, "pane.created", src_container, @tagName(direction), "browser_split");
    emit.surfaceCreated(self, ws, new_container, browser_tab, "browser_split", true);
    defer emit.paneFocused(self, ws, new_container, "browser_split");

    ws.focused_pane = new_container;
    self.clearTabAttention(new_container, new_container.selected);
    self.updateTabBarVisibility();
    self.layoutSplits();

    browser.startCreation();

    if (browser.address_edit) |edit| {
        _ = w32.SetFocus(edit);
    } else {
        browser_tab.focus();
    }
}

/// Navigate to a split in the given direction.
pub fn gotoSplit(self: *Window, goto_target: apprt.action.GotoSplit) void {
    const ws = self.activeWorkspace();
    const alloc = self.app.core_app.alloc;
    const focused = ws.focusedPaneOrFirst() orelse return;
    const handle = ws.paneHandle(focused) orelse return;
    var tree = &ws.tree;

    const target: SplitTree(Pane).Goto = switch (goto_target) {
        .previous => .previous,
        .next => .next,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    };

    const dest_handle = (tree.goto(alloc, handle, target) catch return) orelse return;

    switch (tree.nodes[dest_handle.idx()]) {
        .leaf => |container| {
            ws.focused_pane = container;
            container.focus();
            if (container != focused) emit.paneFocused(self, ws, container, "goto_split");
        },
        .split => {},
    }
}

/// Swap the focused split with the split in the given direction.
pub fn swapSplit(self: *Window, swap_target: apprt.action.GotoSplit) void {
    const ws = self.activeWorkspace();
    const alloc = self.app.core_app.alloc;
    const focused = ws.focusedPaneOrFirst() orelse return;
    const src_handle = ws.paneHandle(focused) orelse return;

    const target: SplitTree(Pane).Goto = switch (swap_target) {
        .previous => .previous,
        .next => .next,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    };

    const dst_handle = (ws.tree.goto(alloc, src_handle, target) catch return) orelse return;

    const other: ?*Pane = switch (ws.tree.nodes[dst_handle.idx()]) {
        .leaf => |p| p,
        .split => null,
    };
    const new_tree = ws.tree.swap(alloc, src_handle, dst_handle) catch return;
    installTree(ws, new_tree);
    self.layoutSplits();
    emit.paneChanged(self, ws, focused, "pane.swapped", other, "swap_split");

    const new_handle = ws.paneHandle(focused) orelse return;
    switch (ws.tree.nodes[new_handle.idx()]) {
        .leaf => |container| container.focus(),
        .split => {},
    }
}

/// Resize the nearest split in the given direction by the given pixel
/// amount: the divider of the nearest enclosing split of that orientation
/// moves by `amount` pixels of THAT split's own rect (model/layout.zig;
/// ui-model 8.1 #2, it used to divide by the whole surface and rely on
/// SplitTree.resize's gapless spatial estimate).
pub fn resizeSplit(self: *Window, rs: apprt.action.ResizeSplit) void {
    const ws = self.activeWorkspace();
    const focused = ws.focusedPaneOrFirst() orelse return;
    const handle = ws.paneHandle(focused) orelse return;

    const split_layout: SplitTree(Pane).Split.Layout = switch (rs.direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };
    const sign: i32 = switch (rs.direction) {
        .left, .up => -1,
        .right, .down => 1,
    };

    var sfa = std.heap.stackFallback(pane_layout.stack_bytes, self.app.core_app.alloc);
    const gpa = sfa.get();
    var lay = pane_layout.computeLayout(gpa, &ws.tree, self.surfaceRect(), self.scale) catch return;
    defer lay.deinit(gpa);
    const split = lay.parentSplit(&ws.tree, handle, split_layout) orelse return;
    const ratio = ws.tree.nodes[split.idx()].split.ratio;
    const node_rect = lay.node_rects[split.idx()];
    ws.tree.resizeInPlace(split, pane_layout.resizedRatio(split_layout, node_rect, ratio, sign * @as(i32, rs.amount)));
    self.layoutSplits();
    emit.paneChanged(self, ws, focused, "pane.resized", null, "resize_split");
}

/// Equalize all splits in the active workspace.
pub fn equalizeSplits(self: *Window) void {
    const ws = self.activeWorkspace();
    if (ws.tree.isEmpty()) return;
    const alloc = self.app.core_app.alloc;

    const new_tree = ws.tree.equalize(alloc) catch return;
    installTree(ws, new_tree);
    self.layoutSplits();
    if (ws.focusedPaneOrFirst()) |p| emit.paneChanged(self, ws, p, "pane.resized", null, "equalize_splits");
}

/// Rearrange all splits in the active workspace into a predefined layout.
pub fn selectLayout(self: *Window, layout: apprt.action.SelectLayout) void {
    const ws = self.activeWorkspace();
    if (ws.tree.isEmpty()) return;
    const alloc = self.app.core_app.alloc;

    const Tree = SplitTree(Pane);
    const tree_layout: Tree.PredefinedLayout = switch (layout) {
        inline else => |tag| @field(Tree.PredefinedLayout, @tagName(tag)),
    };
    const new_tree = ws.tree.selectLayout(alloc, tree_layout) catch return;
    installTree(ws, new_tree);
    self.layoutSplits();
    if (ws.focusedPaneOrFirst()) |p| emit.paneChanged(self, ws, p, "pane.resized", null, "select_layout");
}

/// Replace the split tree of `ws` with `new_tree`, which session restore
/// built directly (features/session/legacy_v2.zig), announcing what goes
/// and what comes: `surface.closed` and `pane.closed` for the panes and
/// tabs of the old tree, then `pane.created` and `surface.created` for
/// the new ones, in split-tree order. The caller cleared `focused_pane`.
pub fn installRestoredTree(self: *Window, ws: *Workspace, new_tree: SplitTree(Pane)) void {
    var sfa = std.heap.stackFallback(32 * @sizeOf(ids.Uuid), self.app.core_app.alloc);
    const gpa = sfa.get();
    var old_it = ws.tree.iterator();
    while (old_it.next()) |entry| {
        const pane = entry.view;
        const closed: []ids.Uuid = gpa.alloc(ids.Uuid, pane.tabCount()) catch &.{};
        defer gpa.free(closed);
        for (pane.tabs.items, 0..) |tab, i| {
            if (i < closed.len) closed[i] = tab.handle.uuid;
            emit.surfaceClosed(self, ws, pane.handle.uuid, tab.handle.uuid, tab.content.kindName(), "session_restore");
        }
        emit.paneClosed(self, ws, pane.handle.uuid, closed, "session_restore");
    }
    installTree(ws, new_tree);
    var it = ws.tree.iterator();
    while (it.next()) |entry| {
        const pane = entry.view;
        emit.paneCreated(self, ws, pane, "pane.created", null, null, "session_restore");
        for (pane.tabs.items) |tab| emit.surfaceCreated(self, ws, pane, tab, "session_restore", false);
    }
}

/// Toggle zoom on the focused split pane.
pub fn toggleSplitZoom(self: *Window) void {
    const ws = self.activeWorkspace();
    var tree = &ws.tree;
    if (tree.isEmpty()) return;
    if (!tree.isSplit()) return;

    const focused = ws.focusedPaneOrFirst() orelse return;
    const handle = ws.paneHandle(focused) orelse return;

    if (tree.zoomed) |z| {
        if (z == handle) {
            tree.zoom(null);
        } else {
            tree.zoom(handle);
        }
    } else {
        tree.zoom(handle);
    }
    ws.syncZoomed();
    self.layoutSplits();
}
