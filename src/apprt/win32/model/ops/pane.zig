//! Pane (split-tree leaf) operations of the window model (ARCHITECTURE.md
//! ADR-1.8 W0-A2 step 2): splits, navigation, swap, resize, equalize,
//! predefined layouts and zoom. Moved out of Window.zig in W0-A2.

const std = @import("std");

const apprt = @import("../../../../apprt.zig");
const BrowserPane = @import("../../web/BrowserPane.zig");
const Pane = @import("../Pane.zig");
const SplitTree = @import("../../../../datastruct/split_tree.zig").SplitTree;
const Surface = @import("../../Surface.zig");
const Tab = @import("../Tab.zig");
const Window = @import("../../ui/Window.zig");
const Workspace = @import("../Workspace.zig");
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
/// single `tab` (whose one reference moves into the new pane). On failure
/// the tab's reference is released.
fn splitWithTab(
    alloc: std.mem.Allocator,
    ws: *Workspace,
    src_handle: SplitTree(Pane).Node.Handle,
    direction: SplitTree(Pane).Split.Direction,
    tab: *Tab,
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

    const new_tab = try ops_surface.createTerminalTab(self, .split, command, null);
    ops_surface.initTitle(alloc, new_tab, null, ops_surface.terminal_default_title) catch |err| {
        new_tab.unref(alloc);
        return err;
    };

    const is_visible = focus and ws_idx == self.activeIndex();
    if (!is_visible) {
        if (new_tab.hwnd()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
    }

    const new_container = try splitWithTab(alloc, ws, src_handle, direction, new_tab);

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
    const browser_tab = Tab.createBrowser(alloc, browser) catch |err| {
        browser.destroy(alloc);
        return err;
    };
    _ = browser_tab.ref(alloc) catch unreachable;
    ops_surface.initTitle(alloc, browser_tab, null, ops_surface.browser_default_title) catch |err| {
        browser_tab.unref(alloc);
        return err;
    };

    const new_container = try splitWithTab(alloc, ws, src_handle, direction, browser_tab);

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

    const new_tree = ws.tree.swap(alloc, src_handle, dst_handle) catch return;
    installTree(ws, new_tree);
    self.layoutSplits();

    const new_handle = ws.paneHandle(focused) orelse return;
    switch (ws.tree.nodes[new_handle.idx()]) {
        .leaf => |container| container.focus(),
        .split => {},
    }
}

/// Resize the nearest split in the given direction by the given pixel amount.
pub fn resizeSplit(self: *Window, rs: apprt.action.ResizeSplit) void {
    const ws = self.activeWorkspace();
    const alloc = self.app.core_app.alloc;
    const focused = ws.focusedPaneOrFirst() orelse return;
    const handle = ws.paneHandle(focused) orelse return;

    const layout: SplitTree(Pane).Split.Layout = switch (rs.direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };

    const rect = self.surfaceRect();
    const dimension: f32 = switch (layout) {
        .horizontal => @floatFromInt(@max(rect.right - rect.left, 1)),
        .vertical => @floatFromInt(@max(rect.bottom - rect.top, 1)),
    };
    const sign: f32 = switch (rs.direction) {
        .left, .up => -1.0,
        .right, .down => 1.0,
    };
    const delta: f16 = @floatCast(sign * @as(f32, @floatFromInt(rs.amount)) / dimension);

    const new_tree = ws.tree.resize(alloc, handle, layout, delta) catch return;
    installTree(ws, new_tree);
    self.layoutSplits();
}

/// Equalize all splits in the active workspace.
pub fn equalizeSplits(self: *Window) void {
    const ws = self.activeWorkspace();
    if (ws.tree.isEmpty()) return;
    const alloc = self.app.core_app.alloc;

    const new_tree = ws.tree.equalize(alloc) catch return;
    installTree(ws, new_tree);
    self.layoutSplits();
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
