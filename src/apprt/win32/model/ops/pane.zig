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
const w32 = @import("../../platform/win32.zig");

/// Create a new split in the active workspace. Splits inherit the source
/// pane's backend: a split off a WSL or PowerShell tab opens the same shell.
/// Browser panes have no terminal surface, so a split off one falls back to
/// the configured default. Creates a new Pane as a sibling leaf.
pub fn newSplit(self: *Window, direction: SplitTree(Pane).Split.Direction) !void {
    const ws = self.activeWorkspace();
    const container = ws.focusedContainerOrFirst() orelse return;
    const command: ?[]const []const u8 = if (container.activeTab()) |p|
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
    _ = try self.newSplitInWorkspace(self.active_workspace, direction, command, true);
}

/// Split the focused Pane of workspace `ws_idx` in `direction`,
/// creating a new Pane with one terminal pane as a sibling leaf
/// in the workspace split tree. With `focus` true, the new container is
/// focused and laid out (interactive UX). With `focus` false, the new
/// container is created hidden (agent `+split` without `--focus`).
/// Returns the new pane.
pub fn newSplitInWorkspace(
    self: *Window,
    ws_idx: usize,
    direction: SplitTree(Pane).Split.Direction,
    command: ?[]const []const u8,
    focus: bool,
) !*Tab {
    if (self.closing) return error.WindowClosing;
    if (ws_idx >= self.workspace_count) return error.NoWindow;
    const ws = &self.workspaces[ws_idx];
    const alloc = self.app.core_app.alloc;

    const src_container = ws.focusedContainerOrFirst() orelse return error.UnknownPane;
    const src_handle = ws.findContainerHandle(src_container) orelse return error.UnknownPane;

    const new_surface = try alloc.create(Surface);
    errdefer {
        new_surface.deinit();
        alloc.destroy(new_surface);
    }
    try new_surface.init(self.app, self, .split, command, null);

    const is_visible = focus and ws_idx == self.active_workspace;
    if (!is_visible) {
        if (new_surface.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
    }

    const new_pane = try Tab.create(alloc, new_surface);
    _ = new_pane.ref(alloc) catch |err| {
        alloc.destroy(new_pane);
        return err;
    };
    errdefer new_pane.unref(alloc);

    const new_container = try Pane.create(alloc);
    errdefer alloc.destroy(new_container);
    new_container.tabs[0] = new_pane;
    new_container.tab_count = 1;
    new_container.active_tab = 0;
    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(new_container.tab_titles[0][0..default_title.len], default_title);
    new_container.tab_title_lens[0] = @intCast(default_title.len);

    var insert_tree = try SplitTree(Pane).init(alloc, new_container);
    defer insert_tree.deinit();

    const new_tree = try ws.split_tree.split(
        alloc,
        src_handle,
        direction,
        @as(f16, 0.5),
        &insert_tree,
    );

    var old_tree = ws.split_tree;
    old_tree.deinit();
    ws.split_tree = new_tree;

    if (focus) {
        ws.focused_container = new_container;
        if (is_visible) {
            self.updateTabBarVisibility();
            self.layoutSplits();
        }
        new_pane.focus();
    } else {
        if (ws_idx == self.active_workspace) {
            self.updateTabBarVisibility();
            self.layoutSplits();
        }
    }
    self.invalidateSidebar();
    return new_pane;
}

/// Create a new browser (WebView2) split in the active workspace, in
/// the given direction off the focused container. Creates a new
/// Pane with the browser pane as its sole tab.
pub fn newBrowserSplit(self: *Window, direction: SplitTree(Pane).Split.Direction) !void {
    if (self.closing) return;
    const ws = self.activeWorkspace();
    const src_container = ws.focusedContainerOrFirst() orelse return;
    const src_handle = ws.findContainerHandle(src_container) orelse return;
    self.cancelTabRename();

    const alloc = self.app.core_app.alloc;

    const browser = try BrowserPane.create(alloc, self.app, self);
    errdefer browser.destroy(alloc);
    const browser_pane = try Tab.createBrowser(alloc, browser);
    _ = browser_pane.ref(alloc) catch |err| {
        alloc.destroy(browser_pane);
        return err;
    };
    errdefer browser_pane.unref(alloc);

    const new_container = try Pane.create(alloc);
    errdefer alloc.destroy(new_container);
    new_container.tabs[0] = browser_pane;
    new_container.tab_count = 1;
    new_container.active_tab = 0;
    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Browser");
    @memcpy(new_container.tab_titles[0][0..default_title.len], default_title);
    new_container.tab_title_lens[0] = @intCast(default_title.len);

    var insert_tree = try SplitTree(Pane).init(alloc, new_container);
    defer insert_tree.deinit();

    const new_tree = try ws.split_tree.split(
        alloc,
        src_handle,
        direction,
        @as(f16, 0.5),
        &insert_tree,
    );

    var old_tree = ws.split_tree;
    old_tree.deinit();
    ws.split_tree = new_tree;

    ws.focused_container = new_container;
    self.clearTabAttention(new_container, new_container.active_tab);
    self.updateTabBarVisibility();
    self.layoutSplits();

    browser.startCreation();

    if (browser.address_edit) |edit| {
        _ = w32.SetFocus(edit);
    } else {
        browser_pane.focus();
    }
}

/// Navigate to a split in the given direction.
pub fn gotoSplit(self: *Window, goto_target: apprt.action.GotoSplit) void {
    const ws = self.activeWorkspace();
    const alloc = self.app.core_app.alloc;
    const focused = ws.focusedContainerOrFirst() orelse return;
    const handle = ws.findContainerHandle(focused) orelse return;
    var tree = &ws.split_tree;

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
            ws.focused_container = container;
            container.focus();
        },
        .split => {},
    }
}

/// Swap the focused split with the split in the given direction.
pub fn swapSplit(self: *Window, swap_target: apprt.action.GotoSplit) void {
    const ws = self.activeWorkspace();
    const alloc = self.app.core_app.alloc;
    const focused = ws.focusedContainerOrFirst() orelse return;
    const src_handle = ws.findContainerHandle(focused) orelse return;

    const target: SplitTree(Pane).Goto = switch (swap_target) {
        .previous => .previous,
        .next => .next,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    };

    const dst_handle = (ws.split_tree.goto(alloc, src_handle, target) catch return) orelse return;

    const new_tree = ws.split_tree.swap(alloc, src_handle, dst_handle) catch return;
    var old_tree = ws.split_tree;
    old_tree.deinit();
    ws.split_tree = new_tree;
    self.layoutSplits();

    const new_handle = ws.findContainerHandle(focused) orelse return;
    switch (ws.split_tree.nodes[new_handle.idx()]) {
        .leaf => |container| container.focus(),
        .split => {},
    }
}

/// Resize the nearest split in the given direction by the given pixel amount.
pub fn resizeSplit(self: *Window, rs: apprt.action.ResizeSplit) void {
    const ws = self.activeWorkspace();
    const alloc = self.app.core_app.alloc;
    const focused = ws.focusedContainerOrFirst() orelse return;
    const handle = ws.findContainerHandle(focused) orelse return;

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

    const new_tree = ws.split_tree.resize(alloc, handle, layout, delta) catch return;
    var old_tree = ws.split_tree;
    old_tree.deinit();
    ws.split_tree = new_tree;
    self.layoutSplits();
}

/// Equalize all splits in the active workspace.
pub fn equalizeSplits(self: *Window) void {
    const ws = self.activeWorkspace();
    if (ws.split_tree.isEmpty()) return;
    const alloc = self.app.core_app.alloc;

    const new_tree = ws.split_tree.equalize(alloc) catch return;
    var old_tree = ws.split_tree;
    old_tree.deinit();
    ws.split_tree = new_tree;
    self.layoutSplits();
}

/// Rearrange all splits in the active workspace into a predefined layout.
pub fn selectLayout(self: *Window, layout: apprt.action.SelectLayout) void {
    const ws = self.activeWorkspace();
    if (ws.split_tree.isEmpty()) return;
    const alloc = self.app.core_app.alloc;

    const Tree = SplitTree(Pane);
    const tree_layout: Tree.PredefinedLayout = switch (layout) {
        inline else => |tag| @field(Tree.PredefinedLayout, @tagName(tag)),
    };
    const new_tree = ws.split_tree.selectLayout(alloc, tree_layout) catch return;
    var old_tree = ws.split_tree;
    old_tree.deinit();
    ws.split_tree = new_tree;
    self.layoutSplits();
}

/// Toggle zoom on the focused split container.
pub fn toggleSplitZoom(self: *Window) void {
    const ws = self.activeWorkspace();
    var tree = &ws.split_tree;
    if (tree.isEmpty()) return;
    if (!tree.isSplit()) return;

    const focused = ws.focusedContainerOrFirst() orelse return;
    const handle = ws.findContainerHandle(focused) orelse return;

    if (tree.zoomed) |z| {
        if (z == handle) {
            tree.zoom(null);
        } else {
            tree.zoom(handle);
        }
    } else {
        tree.zoom(handle);
    }
    self.layoutSplits();
}
