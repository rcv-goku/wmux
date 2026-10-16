//! Tab ("surface") operations of the window model (ARCHITECTURE.md ADR-1.8
//! W0-A2 step 2): create, close, select, reorder, title, status and
//! attention of the tabs of a pane. Moved out of Window.zig in W0-A2; the
//! functions still take the *Window they act on (call sites use the W0
//! aliases in ui/Window.zig).

const std = @import("std");

const apprt = @import("../../../../apprt.zig");
const BrowserPane = @import("../../web/BrowserPane.zig");
const Pane = @import("../Pane.zig");
const SplitTree = @import("../../../../datastruct/split_tree.zig").SplitTree;
const Surface = @import("../../Surface.zig");
const Tab = @import("../Tab.zig");
const Window = @import("../../ui/Window.zig");
const app_foreground = @import("../../app/foreground.zig");
const arith = @import("../logic/arith.zig");
const titles = @import("../logic/titles.zig");
const w32 = @import("../../platform/win32.zig");

const log = std.log.scoped(.win32);

const MAX_TABS = Pane.MAX_TABS;
const TabStatus = Tab.TabStatus;
const capUtf8 = titles.capUtf8;
const closeTabActiveFixup = arith.closeTabActiveFixup;
const newTabInsertPos = arith.newTabInsertPos;
const tabArraysInsertGap = arith.tabArraysInsertGap;
const tabArraysMove = arith.tabArraysMove;
const tabArraysRemove = arith.tabArraysRemove;
const tabArraysSwap = arith.tabArraysSwap;
const titleForCommand = titles.titleForCommand;

/// Add a new tab surface to this window. The surface is created,
/// initialized, and inserted at the position dictated by config.
pub fn addTab(self: *Window) !*Surface {
    return self.addTabWithCommand(null, null);
}

/// Like addTab, but the new tab inherits the active pane's backend
/// ("follow the current console", mirroring how splits inherit via
/// newSplit): a new tab opened from a WSL or PowerShell tab runs the
/// same shell. Used by the plain new-tab UX paths — the tab bar "+"
/// button, the new_tab binding action, and the New Tab context-menu
/// entries. The backend picker stays an explicit override
/// (addTabWithCommand), and window/workspace creation keeps the
/// configured default (addTab). A null spawn_command (the default
/// shell) or a browser pane (no terminal surface) falls back to the
/// default, matching addTab. Surface.init deep copies the argv, so
/// borrowing the source surface's copy is fine (same as newSplit).
pub fn addTabInherit(self: *Window) !*Surface {
    const command: ?[]const []const u8 = blk: {
        const ws = self.activeWorkspace();
        const container = ws.focusedContainerOrFirst() orelse break :blk null;
        const src = container.activeTab() orelse break :blk null;
        const surface = src.surface() orelse break :blk null;
        break :blk surface.spawn_command;
    };
    const title: ?[]const u8 = if (command) |argv| titleForCommand(argv) else null;
    return self.addTabWithCommand(command, title);
}

/// Like addTab, but optionally overrides the command the new tab runs
/// (the new-session backend picker) and its initial title. The argv
/// and title are copied as needed, so the caller's memory may be freed
/// once this returns. Null command/title behave exactly like addTab.
pub fn addTabWithCommand(
    self: *Window,
    command: ?[]const []const u8,
    title: ?[]const u8,
) !*Surface {
    if (self.closing) return error.WindowClosing;
    const ws = self.activeWorkspace();
    self.cancelTabRename();

    const alloc = self.app.core_app.alloc;

    // Resolve or create the target container.
    const container = ws.focusedContainerOrFirst() orelse blk: {
        // Empty workspace — create the first Pane and init the
        // workspace split tree with it.
        const pc = try Pane.create(alloc);
        errdefer alloc.destroy(pc);
        const tree = try SplitTree(Pane).init(alloc, pc);
        ws.split_tree = tree;
        ws.focused_container = pc;
        break :blk pc;
    };
    if (container.tab_count >= MAX_TABS) return error.TooManyTabs;

    const surface = try alloc.create(Surface);
    try surface.init(self.app, self, .tab, command, ws.working_dir);
    const pane = Tab.create(alloc, surface) catch |err| {
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    // The pane is owned by the container's tabs array; ref it for that
    // ownership (matching the old SplitTree.init ref path).
    _ = pane.ref(alloc) catch |err| {
        alloc.destroy(pane);
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    errdefer pane.unref(alloc);

    const pos: usize = newTabInsertPos(self.app.config.@"window-new-tab-position", container.tab_count, container.active_tab);

    tabArraysInsertGap(container.tabArrays(), container.tab_count, pos);
    container.tabs[pos] = pane;
    container.tab_status[pos] = .normal;
    container.tab_status_text_len[pos] = 0;
    container.tab_progress[pos] = null;
    container.tab_log[pos].clear();
    container.tab_count += 1;

    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(container.tab_titles[pos][0..default_title.len], default_title);
    container.tab_title_lens[pos] = @intCast(default_title.len);
    if (title) |t| {
        const wlen = std.unicode.utf8ToUtf16Le(
            &container.tab_titles[pos],
            t[0..@min(t.len, 255)],
        ) catch 0;
        if (wlen > 0) container.tab_title_lens[pos] = @intCast(@min(wlen, 255));
    }

    if (container.tab_count == 1) {
        if (!self.is_quick_terminal) {
            if (self.hwnd) |h| {
                const cmd: i32 = if (self.restore_maximized) w32.SW_SHOWMAXIMIZED else w32.SW_SHOW;
                self.restore_maximized = false;
                app_foreground.showTopLevel(self.app, h, cmd);
                _ = w32.UpdateWindow(h);
            }
        }
        container.active_tab = pos;
        self.updateWindowTitle();
        if (!self.is_quick_terminal) {
            if (surface.hwnd) |h| _ = w32.SetFocus(h);
        }
    } else {
        self.selectTabIndex(pos);
    }
    self.updateTabBarVisibility();
    self.invalidateSidebar();
    return surface;
}

/// Add a tab to a workspace that need not be the active one, WITHOUT
/// switching to it or moving focus. Mirrors addTabWithCommand's per-tab
/// bookkeeping but targets `ws_idx` and keeps the background workspace's
/// panes hidden (the freshly created child HWND is hidden right after
/// Surface.init shows it). When `ws_idx` IS the active workspace this
/// delegates to addTabWithCommand so the active-tab switch/focus behaves
/// exactly as the interactive "+" path. `command` mirrors
/// addTabWithCommand (null = the configured default shell). Used by the
/// agent IPC `+tab new` (no `--focus`): the new tab exists in the
/// background and `selectTabIndex`/`selectWorkspace` shows it later.
/// Returns the new tab's index within `ws_idx`.
pub fn addTabBackground(
    self: *Window,
    ws_idx: usize,
    command: ?[]const []const u8,
    title: ?[]const u8,
) !usize {
    if (self.closing) return error.WindowClosing;
    if (ws_idx >= self.workspace_count) return error.NoWindow;
    if (ws_idx == self.active_workspace) {
        _ = try self.addTabWithCommand(command, title);
        const container = self.activeWorkspace().focusedContainerOrFirst() orelse return error.NoWindow;
        return container.active_tab;
    }

    const ws = &self.workspaces[ws_idx];
    self.cancelTabRename();

    const alloc = self.app.core_app.alloc;

    const container = ws.focusedContainerOrFirst() orelse blk: {
        const pc = try Pane.create(alloc);
        errdefer alloc.destroy(pc);
        const tree = try SplitTree(Pane).init(alloc, pc);
        ws.split_tree = tree;
        ws.focused_container = pc;
        break :blk pc;
    };
    if (container.tab_count >= MAX_TABS) return error.TooManyTabs;

    const surface = try alloc.create(Surface);
    try surface.init(self.app, self, .tab, command, ws.working_dir);
    const pane = Tab.create(alloc, surface) catch |err| {
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    _ = pane.ref(alloc) catch |err| {
        alloc.destroy(pane);
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    errdefer pane.unref(alloc);

    if (surface.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);

    const pos: usize = newTabInsertPos(self.app.config.@"window-new-tab-position", container.tab_count, container.active_tab);

    tabArraysInsertGap(container.tabArrays(), container.tab_count, pos);
    container.tabs[pos] = pane;
    container.tab_status[pos] = .normal;
    container.tab_status_text_len[pos] = 0;
    container.tab_progress[pos] = null;
    container.tab_log[pos].clear();
    container.tab_count += 1;

    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(container.tab_titles[pos][0..default_title.len], default_title);
    container.tab_title_lens[pos] = @intCast(default_title.len);
    if (title) |t| {
        const wlen = std.unicode.utf8ToUtf16Le(
            &container.tab_titles[pos],
            t[0..@min(t.len, 255)],
        ) catch 0;
        if (wlen > 0) container.tab_title_lens[pos] = @intCast(@min(wlen, 255));
    }

    container.active_tab = pos;
    self.invalidateSidebar();
    return pos;
}

/// Like addTabBackground but inherits the source tab's backend, the
/// non-focus counterpart to addTabInherit. The backend is read from the
/// TARGET workspace's active tab (not the window's active workspace), so
/// a background `+tab new` follows the shell of the workspace it lands in.
pub fn addTabInheritBackground(self: *Window, ws_idx: usize) !usize {
    if (ws_idx >= self.workspace_count) return error.NoWindow;
    const command: ?[]const []const u8 = blk: {
        const ws = &self.workspaces[ws_idx];
        const container = ws.focusedContainerOrFirst() orelse break :blk null;
        const src = container.activeTab() orelse break :blk null;
        const surface = src.surface() orelse break :blk null;
        break :blk surface.spawn_command;
    };
    const title: ?[]const u8 = if (command) |argv| titleForCommand(argv) else null;
    return self.addTabBackground(ws_idx, command, title);
}

/// Add a browser (WebView2) pane as a new tab. Mirrors
/// addTabWithCommand's tab-array bookkeeping with a BrowserPane leaf
/// instead of a terminal surface; the title is "Browser" until the
/// first DocumentTitleChanged. Closing it never prompts (no core
/// surface, so no running-process check applies).
pub fn addBrowserTab(self: *Window) !void {
    if (self.closing) return error.WindowClosing;
    if (self.is_quick_terminal) return error.QuickTerminal;
    const ws = self.activeWorkspace();
    self.cancelTabRename();

    const alloc = self.app.core_app.alloc;

    const container = ws.focusedContainerOrFirst() orelse blk: {
        const pc = try Pane.create(alloc);
        errdefer alloc.destroy(pc);
        const tree = try SplitTree(Pane).init(alloc, pc);
        ws.split_tree = tree;
        ws.focused_container = pc;
        break :blk pc;
    };
    if (container.tab_count >= MAX_TABS) return error.TooManyTabs;

    const browser = try BrowserPane.create(alloc, self.app, self);
    errdefer browser.destroy(alloc);
    const browser_pane = try Tab.createBrowser(alloc, browser);
    _ = browser_pane.ref(alloc) catch |err| {
        alloc.destroy(browser_pane);
        return err;
    };
    errdefer browser_pane.unref(alloc);

    const pos: usize = newTabInsertPos(self.app.config.@"window-new-tab-position", container.tab_count, container.active_tab);

    tabArraysInsertGap(container.tabArrays(), container.tab_count, pos);
    container.tabs[pos] = browser_pane;
    container.tab_status[pos] = .normal;
    container.tab_status_text_len[pos] = 0;
    container.tab_progress[pos] = null;
    container.tab_log[pos].clear();
    container.tab_count += 1;

    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Browser");
    @memcpy(container.tab_titles[pos][0..default_title.len], default_title);
    container.tab_title_lens[pos] = @intCast(default_title.len);

    if (container.tab_count == 1) {
        if (self.hwnd) |h| {
            app_foreground.showTopLevel(self.app, h, w32.SW_SHOW);
            _ = w32.UpdateWindow(h);
        }
        container.active_tab = pos;
        self.updateWindowTitle();
        self.layoutSplits();
    } else {
        self.selectTabIndex(pos);
    }
    self.updateTabBarVisibility();
    self.invalidateSidebar();

    browser.startCreation();

    if (browser.address_edit) |edit| {
        _ = w32.SetFocus(edit);
    } else {
        browser_pane.focus();
    }
}

/// Close a tab by pane pointer. Removes from the tab list,
/// deinits the tree, and adjusts the active tab index.
pub fn closeTab(self: *Window, pane: *Tab) void {
    const loc = self.findLoc(pane) orelse return;
    log.debug("closeTab called for pane={x} tab_count={}", .{ @intFromPtr(pane), loc.container.tab_count });
    // The pane may live in a NON-active workspace (a background shell
    // exiting, an IPC-addressed browser closing): close the tab in the
    // container that actually owns it.
    self.closeTabInContainer(self.workspaceIndex(loc.ws), loc.container, loc.tab);
}

/// Close a tab by index within the focused Pane of the ACTIVE
/// workspace (tab bar / context menu paths).
pub fn closeTabByIndex(self: *Window, idx: usize) void {
    const ws = &self.workspaces[self.active_workspace];
    const container = ws.focusedContainerOrFirst() orelse return;
    self.closeTabInContainer(self.active_workspace, container, idx);
}

/// Close the tab at `idx` within the given Pane in workspace
/// `ws_idx`. If the container empties, it is removed from the workspace
/// split tree (or the workspace/window is closed if nothing remains).
pub fn closeTabInContainer(self: *Window, ws_idx: usize, container: *Pane, idx: usize) void {
    if (ws_idx >= self.workspace_count) return;
    const ws = &self.workspaces[ws_idx];
    if (idx >= container.tab_count) return;
    const alloc = self.app.core_app.alloc;
    self.cancelTabRename();

    // Detach the pane BEFORE unreffing: the unref can destroy a
    // browser host HWND, which moves focus synchronously and
    // re-enters our wndprocs. They must not see the dying pane.
    const pane = container.tabs[idx];
    tabArraysRemove(container.tabArrays(), container.tab_count, idx);
    container.tab_count -= 1;

    if (container.tab_count == 0) {
        // Container is empty — remove it from the workspace split tree.
        pane.unref(alloc);
        const handle = ws.findContainerHandle(container);
        if (handle) |h| {
            const new_tree = ws.split_tree.remove(alloc, h) catch {
                log.err("failed to remove container from split tree", .{});
                return;
            };
            var old_tree = ws.split_tree;
            ws.split_tree = new_tree;
            // Pick a new focused container before deiniting old tree.
            ws.focused_container = ws.focusedContainerOrFirst();
            if (ws.focused_container) |fc| self.clearTabAttention(fc, fc.active_tab);
            old_tree.deinit();
        } else {
            // Container not in tree (shouldn't happen); unref it directly.
            container.unref(alloc);
        }

        if (ws.containerCount() == 0) {
            if (self.workspace_count > 1) {
                self.closeWorkspace(ws_idx);
                return;
            }
            self.closing = true;
            if (self.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
            return;
        }

        if (ws_idx == self.active_workspace) {
            self.layoutSplits();
            if (ws.focused_container) |fc| fc.focus();
            self.updateTabBarVisibility();
            self.updateWindowTitle();
            self.invalidateTabBar();
        }
        self.invalidateSidebar();
        return;
    }

    container.active_tab = closeTabActiveFixup(container.tab_count, container.active_tab, idx);
    pane.unref(alloc);
    if (ws_idx == self.active_workspace) {
        self.selectTabIndex(container.active_tab);
        self.updateTabBarVisibility();
    } else {
        self.invalidateSidebar();
    }
}

/// Public wrapper over closeTabInContainer for the agent IPC `tab-close`,
/// which addresses a tab by (workspace index, tab index). Resolves the
/// focused container of the target workspace.
pub fn closeTabInWorkspaceForIpc(self: *Window, ws_idx: usize, idx: usize) void {
    if (ws_idx >= self.workspace_count) return;
    const ws = &self.workspaces[ws_idx];
    const container = ws.focusedContainerOrFirst() orelse return;
    self.closeTabInContainer(ws_idx, container, idx);
}

/// Close tabs based on mode: this (current), other (all but current), right (all after current).
pub fn closeTabMode(self: *Window, mode: apprt.action.CloseTabMode, surface: *Surface) void {
    switch (mode) {
        .this => self.closeSplitSurface(surface),
        .other => {
            // Operate on the container that owns the surface. The loop
            // never empties the container (current survives).
            const loc = self.findLocOfSurface(surface) orelse return;
            const ws_idx = self.workspaceIndex(loc.ws);
            const container = loc.container;
            var current = loc.tab;
            var i: usize = container.tab_count;
            while (i > 0) {
                i -= 1;
                if (i != current) {
                    self.closeTabInContainer(ws_idx, container, i);
                    if (i < current) current -= 1;
                }
            }
        },
        .right => {
            const loc = self.findLocOfSurface(surface) orelse return;
            const ws_idx = self.workspaceIndex(loc.ws);
            const container = loc.container;
            const current = loc.tab;
            var i: usize = container.tab_count;
            while (i > current + 1) {
                i -= 1;
                self.closeTabInContainer(ws_idx, container, i);
            }
        },
    }
}

/// Close a single terminal surface's pane. See closeSplitPane.
pub fn closeSplitSurface(self: *Window, surface: *Surface) void {
    const pane = surface.tab orelse return;
    self.closeSplitPane(pane);
}

/// Close a single pane. In the new model, each tab is a single pane
/// (splits are between Panes, not within tabs), so this just
/// closes the tab in the owning container.
pub fn closeSplitPane(self: *Window, pane: *Tab) void {
    const loc = self.findLoc(pane) orelse {
        log.debug("closeSplitPane: pane not found in any container", .{});
        return;
    };
    log.debug("closeSplitPane: closing tab={} in container", .{loc.tab});
    self.closeTabInContainer(self.workspaceIndex(loc.ws), loc.container, loc.tab);
}

/// Switch to the tab at the given index in the focused Pane of
/// the active workspace. Hides the old tab's pane and shows the new one.
pub fn selectTabIndex(self: *Window, idx: usize) void {
    const ws = self.activeWorkspace();
    const container = ws.focusedContainerOrFirst() orelse return;
    if (idx >= container.tab_count) return;
    self.cancelTabRename();
    // Clear any in-progress tab drag
    if (self.drag_tab >= 0) {
        self.drag_tab = -1;
        self.drag_active = false;
        _ = w32.ReleaseCapture();
    }
    // Clear any in-progress sidebar row drag (e.g. a goto_tab keybind
    // fired mid-drag). handleSidebarClick sets this AFTER its own
    // selectTabIndex call, so the click-then-drag path is unaffected.
    if (self.sidebar_drag_row >= 0) {
        self.sidebar_drag_row = -1;
        self.sidebar_drag_active = false;
        _ = w32.ReleaseCapture();
    }
    if (container.active_tab < container.tab_count) {
        if (container.tabs[container.active_tab].hwnd()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
    }
    container.active_tab = idx;
    container.tab_status[idx] = .normal;
    // The tab is now visible: clear any pending attention ring on it.
    self.clearTabAttention(container, idx);
    const pane = container.tabs[idx];
    self.layoutSplits();
    pane.focus();
    self.updateWindowTitle();
    self.invalidateSidebar();
    self.invalidateTabBar();
    self.updateAttentionRings();
    self.updatePaneButtons();
}

/// Add the first tab to a workspace that is NOT the active one, keeping
/// the active workspace visible and focused. Mirrors addTabWithCommand's
/// per-tab bookkeeping but targets `ws_idx` explicitly and, crucially,
/// HIDES the freshly created surface's child HWND: Surface.init shows the
/// child (it needs a visible, sized window to spawn its ConPTY), which
/// would otherwise paint the background workspace's pane over the visible
/// one. The hidden pane is laid out and shown the first time
/// selectWorkspace switches to this workspace, matching the
/// background-workspace discipline used by closeTabInContainer /
/// closeSplitPane. The new tab becomes the workspace's own active_tab
/// (index 0) so a later switch lands on it.
pub fn addFirstTabBackground(self: *Window, ws_idx: usize, command: ?[]const []const u8) !void {
    if (self.closing) return error.WindowClosing;
    if (ws_idx >= self.workspace_count) return error.NoWindow;
    const ws = &self.workspaces[ws_idx];
    std.debug.assert(ws.containerCount() == 0);

    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    try surface.init(self.app, self, .tab, command, ws.working_dir);
    const pane = Tab.create(alloc, surface) catch |err| {
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    _ = pane.ref(alloc) catch |err| {
        alloc.destroy(pane);
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    errdefer pane.unref(alloc);

    const container = try Pane.create(alloc);
    errdefer alloc.destroy(container);
    const tree = try SplitTree(Pane).init(alloc, container);
    ws.split_tree = tree;
    ws.focused_container = container;

    if (surface.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);

    container.tabs[0] = pane;
    container.tab_status[0] = .normal;
    container.tab_count = 1;
    container.active_tab = 0;
    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(container.tab_titles[0][0..default_title.len], default_title);
    container.tab_title_lens[0] = @intCast(default_title.len);

    self.invalidateSidebar();
}

pub fn toggleSynchronizedInput(self: *Window) void {
    const ws = self.activeWorkspace();
    const container = ws.focusedContainerOrFirst() orelse return;
    container.tab_synchronized[container.active_tab] = !container.tab_synchronized[container.active_tab];
    self.invalidateTabBar();
}

/// Navigate to a tab by GotoTab target (previous, next, last, or index).
pub fn selectTab(self: *Window, target: apprt.action.GotoTab) bool {
    const ws = self.activeWorkspace();
    const container = ws.focusedContainerOrFirst() orelse return false;
    if (container.tab_count <= 1) return false;
    const idx: usize = switch (target) {
        .previous => if (container.active_tab > 0) container.active_tab - 1 else container.tab_count - 1,
        .next => if (container.active_tab + 1 < container.tab_count) container.active_tab + 1 else 0,
        .last => container.tab_count - 1,
        _ => blk: {
            const raw = @intFromEnum(target);
            if (raw < 0) return false;
            const n: usize = @intCast(raw);
            break :blk if (n < container.tab_count) n else return false;
        },
    };
    self.selectTabIndex(idx);
    self.invalidateTabBar();
    return true;
}

/// Move the active tab by a relative offset, wrapping cyclically.
pub fn moveTab(self: *Window, amount: isize) void {
    const ws = self.activeWorkspace();
    const container = ws.focusedContainerOrFirst() orelse return;
    if (container.tab_count <= 1) return;
    const n: isize = @intCast(container.active_tab);
    const count: isize = @intCast(container.tab_count);
    const new_index: usize = @intCast(@mod(n + amount, count));
    if (new_index == container.active_tab) return;

    tabArraysSwap(container.tabArrays(), container.active_tab, new_index);
    container.active_tab = new_index;
    self.invalidateTabBar();
    self.invalidateSidebar();
}

/// Called when a terminal surface's title changes. Delegates to the
/// pane variant.
pub fn onTabTitleChanged(self: *Window, surface: *Surface, title: [:0]const u8) void {
    const pane = surface.tab orelse return;
    self.onPaneTitleChanged(pane, title);
}

/// Called when a pane's title changes. Updates the stored title
/// and refreshes the window title bar / tab bar if needed.
pub fn onPaneTitleChanged(self: *Window, pane: *Tab, title: [:0]const u8) void {
    const loc = self.findLoc(pane) orelse return;
    const container = loc.container;
    const tab_idx = loc.tab;
    var wbuf: [256]u16 = undefined;
    // utf8ToUtf16Le ASSERTS the destination is large enough (no
    // DestTooSmall error in std 0.15) and titles can exceed 256
    // UTF-16 units (browser titles are website-controlled; OSC titles
    // up to 511 bytes). One UTF-8 byte produces at most one UTF-16
    // unit, so capping the input at 255 bytes makes the worst case
    // fit.
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, capUtf8(title, 255)) catch 0;
    const len: u16 = @intCast(@min(wlen, 255));
    @memcpy(container.tab_titles[tab_idx][0..len], wbuf[0..len]);
    container.tab_title_lens[tab_idx] = len;
    if (loc.ws == self.activeWorkspace() and container == loc.ws.focused_container and tab_idx == container.active_tab) self.updateWindowTitle();
    self.invalidateTabBar();
    self.invalidateSidebar();
}

/// Set the sidebar status indicator for the tab containing a surface.
/// No-op if the surface is not in any tab of this window.
pub fn setTabStatusForSurface(self: *Window, surface: *Surface, status: TabStatus) void {
    const loc = self.findLocOfSurface(surface) orelse return;
    if (loc.container.tab_status[loc.tab] == status) return;
    loc.container.tab_status[loc.tab] = status;
    self.invalidateSidebar();
}

/// Recompute `tab_attention[tab]` from the pane of that tab: a tab
/// shows attention iff its pane's Surface has the attention flag set.
/// Called after any surface flag flips so the per-tab aggregate the
/// sidebar/tab paint reads stays consistent with the per-pane source of
/// truth. The ring overlay reads the Surface flags directly.
pub fn recomputeTabAttention(self: *Window, container: *Pane, tab: usize) void {
    _ = self;
    container.tab_attention[tab] = if (container.tabs[tab].surface()) |s| s.attention else false;
}

/// Flag (or clear) the notification ring on the pane wrapping `surface`.
/// Sets the per-pane Surface flag, recomputes its tab's aggregate, and
/// repaints the chrome (sidebar row + top tab dot) and the ring overlays.
/// A request to ring a pane in the currently visible+focused position is
/// honored at the data level but the ring overlay only DRAWS on panes
/// that are not the focused/visible-active pane (see updateAttentionRings),
/// so the user is never ringed around what they are already looking at.
/// No-op if the surface is not in any tab of this window.
pub fn setAttentionForSurface(self: *Window, surface: *Surface, on: bool) void {
    const loc = self.findLocOfSurface(surface) orelse return;
    if (surface.attention == on) return;
    surface.attention = on;
    self.recomputeTabAttention(loc.container, loc.tab);
    // If the user is already looking at this tab (active tab of the
    // focused container in the active workspace), clear immediately —
    // no point flagging something the user can already see.
    if (on) {
        const ws = self.activeWorkspace();
        if (loc.ws == ws) {
            if (ws.focused_container) |fc| {
                if (loc.container == fc and loc.tab == fc.active_tab) {
                    self.clearTabAttention(fc, loc.tab);
                }
            }
        }
    }
    self.invalidateSidebar();
    self.invalidateTabBar();
    self.updateAttentionRings();
}

/// Clear the notification ring on the pane wrapping `surface` (the pane
/// gained focus / the user is now looking at it). Thin wrapper over
/// setAttentionForSurface(false) so the focus path reads clearly.
pub fn clearAttentionForSurface(self: *Window, surface: *Surface) void {
    self.setAttentionForSurface(surface, false);
}

/// Clear attention on every pane of a tab and its aggregate. Used when a
/// tab becomes the visible active tab (selectTabIndex/selectWorkspace):
/// the user is now looking at the whole tab, so any pane's pending ring
/// is satisfied. Repainting/ring refresh is the caller's job (the select
/// paths already invalidate + layout).
pub fn clearTabAttention(self: *Window, container: *Pane, tab: usize) void {
    _ = self;
    if (tab >= container.tab_count) return;
    if (container.tabs[tab].surface()) |s| s.attention = false;
    container.tab_attention[tab] = false;
}

/// Move a tab from one index to another, shifting intermediate tabs.
pub fn moveTabTo(self: *Window, from: usize, to: usize) void {
    const ws = self.activeWorkspace();
    const container = ws.focusedContainerOrFirst() orelse return;
    if (from == to) return;
    if (from >= container.tab_count or to >= container.tab_count) return;

    // Cancel any in-progress rename: the edit control's tab index
    // would otherwise point at the wrong tab after the move.
    self.cancelTabRename();

    // Lift the source tab out, shift the tabs between, drop it at the
    // destination.
    tabArraysMove(container.tabArrays(), from, to);

    container.active_tab = to;
    self.invalidateTabBar();
    self.invalidateSidebar();
}
