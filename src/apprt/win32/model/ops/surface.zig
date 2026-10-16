//! Tab ("surface") operations of the window model (ARCHITECTURE.md ADR-1.8
//! W0-A2 step 2): create, close, select, reorder, title, status and
//! attention of the tabs of a pane. Moved out of Window.zig in W0-A2; the
//! functions still take the *Window they act on (call sites use the W0
//! aliases in ui/Window.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../../../../apprt.zig");
const BrowserPane = @import("../../web/BrowserPane.zig");
const Pane = @import("../Pane.zig");
const SplitTree = @import("../../../../datastruct/split_tree.zig").SplitTree;
const Surface = @import("../../Surface.zig");
const Tab = @import("../Tab.zig");
const Window = @import("../../ui/Window.zig");
const Workspace = @import("../Workspace.zig");
const app_foreground = @import("../../app/foreground.zig");
const arith = @import("../logic/arith.zig");
const titles = @import("../logic/titles.zig");
const w32 = @import("../../platform/win32.zig");

const log = std.log.scoped(.win32);

const TabStatus = Tab.TabStatus;
const capUtf8 = titles.capUtf8;
const closeTabActiveFixup = arith.closeTabActiveFixup;
const newTabInsertPos = arith.newTabInsertPos;
const titleForCommand = titles.titleForCommand;

/// Default title of a new terminal tab (until the shell's OSC title).
pub const terminal_default_title = "Ghostty";
/// Default title of a new browser tab (until the document title).
pub const browser_default_title = "Browser";

/// Set a new tab's initial title: `title` when given (capped at 255 bytes
/// on a code-point boundary; invalid or empty text falls back), else
/// `default`. Mirrors the 255-unit UTF-16 title slots of the former
/// PaneContainer.
pub fn initTitle(alloc: Allocator, tab: *Tab, title: ?[]const u8, default: []const u8) Allocator.Error!void {
    const value: []const u8 = if (title) |t| blk: {
        const capped = capUtf8(t, 255);
        break :blk if (capped.len > 0 and std.unicode.utf8ValidateSlice(capped)) capped else default;
    } else default;
    try tab.title.setAuto(alloc, value, .auto, false);
}

/// The focused pane of `ws`, creating the workspace's first pane (and its
/// split tree) when the workspace is still empty.
fn focusedOrFirstPane(alloc: Allocator, ws: *Workspace) !*Pane {
    if (ws.focusedPaneOrFirst()) |pane| return pane;
    // Empty workspace — create the first Pane and init the workspace
    // split tree with it.
    const pc = try Pane.create(alloc);
    errdefer alloc.destroy(pc);
    const tree = try SplitTree(Pane).init(alloc, pc);
    pc.workspace = ws;
    ws.tree = tree;
    ws.syncZoomed();
    ws.focused_pane = pc;
    return pc;
}

/// Create a terminal tab running `command` (null = the configured default)
/// in `cwd`, holding the reference its pane will own. On failure nothing
/// is left behind.
pub fn createTerminalTab(
    self: *Window,
    context: apprt.surface.NewSurfaceContext,
    command: ?[]const []const u8,
    cwd: ?[]const u8,
) !*Tab {
    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);
    try surface.init(self.app, self, context, command, cwd);
    errdefer surface.deinit();
    const tab = try Tab.create(alloc, surface);
    // The tab is owned by its pane's tab list; ref it for that ownership.
    _ = tab.ref(alloc) catch unreachable;
    return tab;
}

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
        const container = ws.focusedPaneOrFirst() orelse break :blk null;
        const src = container.selectedTab() orelse break :blk null;
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
    const container = try focusedOrFirstPane(alloc, ws);

    const tab = try createTerminalTab(self, .tab, command, ws.cwd);
    errdefer tab.unref(alloc);
    const surface = tab.surface().?;
    try initTitle(alloc, tab, title, terminal_default_title);

    const pos: usize = newTabInsertPos(self.app.config.@"window-new-tab-position", container.tabCount(), container.selected);
    try container.tabs.insert(alloc, pos, tab);
    tab.pane = container;

    if (container.tabCount() == 1) {
        if (!self.is_quick_terminal) {
            if (self.hwnd) |h| {
                const cmd: i32 = if (self.restore_maximized) w32.SW_SHOWMAXIMIZED else w32.SW_SHOW;
                self.restore_maximized = false;
                app_foreground.showTopLevel(self.app, h, cmd);
                _ = w32.UpdateWindow(h);
            }
        }
        container.selected = pos;
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
    if (ws_idx >= self.workspaces.items.len) return error.NoWindow;
    if (ws_idx == self.activeIndex()) {
        _ = try self.addTabWithCommand(command, title);
        const container = self.activeWorkspace().focusedPaneOrFirst() orelse return error.NoWindow;
        return container.selected;
    }

    const ws = self.workspaces.items[ws_idx];
    self.cancelTabRename();

    const alloc = self.app.core_app.alloc;

    const container = try focusedOrFirstPane(alloc, ws);

    const tab = try createTerminalTab(self, .tab, command, ws.cwd);
    errdefer tab.unref(alloc);
    try initTitle(alloc, tab, title, terminal_default_title);

    if (tab.hwnd()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);

    const pos: usize = newTabInsertPos(self.app.config.@"window-new-tab-position", container.tabCount(), container.selected);
    try container.tabs.insert(alloc, pos, tab);
    tab.pane = container;

    container.selected = pos;
    self.invalidateSidebar();
    return pos;
}

/// Like addTabBackground but inherits the source tab's backend, the
/// non-focus counterpart to addTabInherit. The backend is read from the
/// TARGET workspace's active tab (not the window's active workspace), so
/// a background `+tab new` follows the shell of the workspace it lands in.
pub fn addTabInheritBackground(self: *Window, ws_idx: usize) !usize {
    if (ws_idx >= self.workspaces.items.len) return error.NoWindow;
    const command: ?[]const []const u8 = blk: {
        const ws = self.workspaces.items[ws_idx];
        const container = ws.focusedPaneOrFirst() orelse break :blk null;
        const src = container.selectedTab() orelse break :blk null;
        const surface = src.surface() orelse break :blk null;
        break :blk surface.spawn_command;
    };
    const title: ?[]const u8 = if (command) |argv| titleForCommand(argv) else null;
    return self.addTabBackground(ws_idx, command, title);
}

/// Add a browser (WebView2) pane as a new tab. Mirrors
/// addTabWithCommand's bookkeeping with a BrowserPane tab instead of a
/// terminal surface; the title is "Browser" until the first
/// DocumentTitleChanged. Closing it never prompts (no core surface, so no
/// running-process check applies).
pub fn addBrowserTab(self: *Window) !void {
    if (self.closing) return error.WindowClosing;
    if (self.is_quick_terminal) return error.QuickTerminal;
    const ws = self.activeWorkspace();
    self.cancelTabRename();

    const alloc = self.app.core_app.alloc;

    const container = try focusedOrFirstPane(alloc, ws);

    const browser = try BrowserPane.create(alloc, self.app, self);
    errdefer browser.destroy(alloc);
    const browser_tab = try Tab.createBrowser(alloc, browser);
    _ = browser_tab.ref(alloc) catch |err| {
        alloc.destroy(browser_tab);
        return err;
    };
    errdefer browser_tab.unref(alloc);
    try initTitle(alloc, browser_tab, null, browser_default_title);

    const pos: usize = newTabInsertPos(self.app.config.@"window-new-tab-position", container.tabCount(), container.selected);
    try container.tabs.insert(alloc, pos, browser_tab);
    browser_tab.pane = container;

    if (container.tabCount() == 1) {
        if (self.hwnd) |h| {
            app_foreground.showTopLevel(self.app, h, w32.SW_SHOW);
            _ = w32.UpdateWindow(h);
        }
        container.selected = pos;
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
        browser_tab.focus();
    }
}

/// Close a tab by pointer. Removes it from its pane, tears down an
/// emptied pane, and adjusts the selected tab index.
pub fn closeTab(self: *Window, tab: *Tab) void {
    const loc = self.findLoc(tab) orelse return;
    log.debug("closeTab called for tab={x} tab_count={}", .{ @intFromPtr(tab), loc.pane.tabCount() });
    // The tab may live in a NON-active workspace (a background shell
    // exiting, an IPC-addressed browser closing): close the tab in the
    // pane that actually owns it.
    self.closeTabInContainer(self.workspaceIndex(loc.ws), loc.pane, loc.index);
}

/// Close a tab by index within the focused Pane of the ACTIVE
/// workspace (tab bar / context menu paths).
pub fn closeTabByIndex(self: *Window, idx: usize) void {
    const ws = self.activeWorkspace();
    const container = ws.focusedPaneOrFirst() orelse return;
    self.closeTabInContainer(self.activeIndex(), container, idx);
}

/// Close the tab at `idx` within the given Pane in workspace
/// `ws_idx`. If the pane empties, it is removed from the workspace
/// split tree (or the workspace/window is closed if nothing remains).
pub fn closeTabInContainer(self: *Window, ws_idx: usize, container: *Pane, idx: usize) void {
    if (ws_idx >= self.workspaces.items.len) return;
    const ws = self.workspaces.items[ws_idx];
    if (idx >= container.tabCount()) return;
    const alloc = self.app.core_app.alloc;
    self.cancelTabRename();

    // Detach the tab BEFORE unreffing: the unref can destroy a
    // browser host HWND, which moves focus synchronously and
    // re-enters our wndprocs. They must not see the dying tab.
    const tab = container.tabs.orderedRemove(idx);
    tab.pane = null;

    if (container.tabCount() == 0) {
        // Pane is empty — remove it from the workspace split tree.
        tab.unref(alloc);
        const handle = ws.paneHandle(container);
        if (handle) |h| {
            const new_tree = ws.tree.remove(alloc, h) catch {
                log.err("failed to remove container from split tree", .{});
                return;
            };
            var old_tree = ws.tree;
            ws.tree = new_tree;
            ws.syncZoomed();
            // Pick a new focused container before deiniting old tree.
            ws.focused_pane = ws.focusedPaneOrFirst();
            if (ws.focused_pane) |fc| self.clearTabAttention(fc, fc.selected);
            old_tree.deinit();
        } else {
            // Pane not in tree (shouldn't happen); unref it directly.
            container.unref(alloc);
        }

        if (ws.paneCount() == 0) {
            if (self.workspaces.items.len > 1) {
                self.closeWorkspace(ws_idx);
                return;
            }
            self.closing = true;
            if (self.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
            return;
        }

        if (ws_idx == self.activeIndex()) {
            self.layoutSplits();
            if (ws.focused_pane) |fc| fc.focus();
            self.updateTabBarVisibility();
            self.updateWindowTitle();
            self.invalidateTabBar();
        }
        self.invalidateSidebar();
        return;
    }

    container.selected = closeTabActiveFixup(container.tabCount(), container.selected, idx);
    tab.unref(alloc);
    if (ws_idx == self.activeIndex()) {
        self.selectTabIndex(container.selected);
        self.updateTabBarVisibility();
    } else {
        self.invalidateSidebar();
    }
}

/// Public wrapper over closeTabInContainer for the agent IPC `tab-close`,
/// which addresses a tab by (workspace index, tab index). Resolves the
/// focused container of the target workspace.
pub fn closeTabInWorkspaceForIpc(self: *Window, ws_idx: usize, idx: usize) void {
    if (ws_idx >= self.workspaces.items.len) return;
    const ws = self.workspaces.items[ws_idx];
    const container = ws.focusedPaneOrFirst() orelse return;
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
            const container = loc.pane;
            var current = loc.index;
            var i: usize = container.tabCount();
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
            const container = loc.pane;
            const current = loc.index;
            var i: usize = container.tabCount();
            while (i > current + 1) {
                i -= 1;
                self.closeTabInContainer(ws_idx, container, i);
            }
        },
    }
}

/// Close a single terminal surface's tab. See closeSplitPane.
pub fn closeSplitSurface(self: *Window, surface: *Surface) void {
    const tab = surface.tab orelse return;
    self.closeSplitPane(tab);
}

/// Close a single tab. Each tab is a single content (splits are between
/// Panes, not within tabs), so this just closes the tab in its pane.
pub fn closeSplitPane(self: *Window, tab: *Tab) void {
    const loc = self.findLoc(tab) orelse {
        log.debug("closeSplitPane: tab not found in any pane", .{});
        return;
    };
    log.debug("closeSplitPane: closing tab={} in container", .{loc.index});
    self.closeTabInContainer(self.workspaceIndex(loc.ws), loc.pane, loc.index);
}

/// Switch to the tab at the given index in the focused Pane of
/// the active workspace. Hides the old tab's pane and shows the new one.
pub fn selectTabIndex(self: *Window, idx: usize) void {
    const ws = self.activeWorkspace();
    const container = ws.focusedPaneOrFirst() orelse return;
    if (idx >= container.tabCount()) return;
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
    if (container.selectedHwnd()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
    container.selected = idx;
    const tab = container.tabs.items[idx];
    tab.legacy.status = .normal;
    // The tab is now visible: clear any pending attention ring on it.
    self.clearTabAttention(container, idx);
    self.layoutSplits();
    tab.focus();
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
/// closeSplitPane. The new tab becomes the workspace's own selected tab
/// (index 0) so a later switch lands on it.
pub fn addFirstTabBackground(self: *Window, ws_idx: usize, command: ?[]const []const u8) !void {
    if (self.closing) return error.WindowClosing;
    if (ws_idx >= self.workspaces.items.len) return error.NoWindow;
    const ws = self.workspaces.items[ws_idx];
    std.debug.assert(ws.paneCount() == 0);

    const alloc = self.app.core_app.alloc;
    const tab = try createTerminalTab(self, .tab, command, ws.cwd);
    errdefer tab.unref(alloc);
    try initTitle(alloc, tab, null, terminal_default_title);

    const container = try Pane.create(alloc);
    errdefer alloc.destroy(container);
    try container.tabs.append(alloc, tab);
    errdefer container.tabs.deinit(alloc);
    const tree = try SplitTree(Pane).init(alloc, container);
    tab.pane = container;
    container.workspace = ws;
    container.selected = 0;
    ws.tree = tree;
    ws.syncZoomed();
    ws.focused_pane = container;

    if (tab.hwnd()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);

    self.invalidateSidebar();
}

pub fn toggleSynchronizedInput(self: *Window) void {
    const ws = self.activeWorkspace();
    const container = ws.focusedPaneOrFirst() orelse return;
    const tab = container.selectedTab() orelse return;
    tab.legacy.synchronized = !tab.legacy.synchronized;
    self.invalidateTabBar();
}

/// Navigate to a tab by GotoTab target (previous, next, last, or index).
pub fn selectTab(self: *Window, target: apprt.action.GotoTab) bool {
    const ws = self.activeWorkspace();
    const container = ws.focusedPaneOrFirst() orelse return false;
    const count = container.tabCount();
    if (count <= 1) return false;
    const idx: usize = switch (target) {
        .previous => if (container.selected > 0) container.selected - 1 else count - 1,
        .next => if (container.selected + 1 < count) container.selected + 1 else 0,
        .last => count - 1,
        _ => blk: {
            const raw = @intFromEnum(target);
            if (raw < 0) return false;
            const n: usize = @intCast(raw);
            break :blk if (n < count) n else return false;
        },
    };
    self.selectTabIndex(idx);
    self.invalidateTabBar();
    return true;
}

/// Move the active tab by a relative offset, wrapping cyclically.
pub fn moveTab(self: *Window, amount: isize) void {
    const ws = self.activeWorkspace();
    const container = ws.focusedPaneOrFirst() orelse return;
    if (container.tabCount() <= 1) return;
    const n: isize = @intCast(container.selected);
    const count: isize = @intCast(container.tabCount());
    const new_index: usize = @intCast(@mod(n + amount, count));
    if (new_index == container.selected) return;

    std.mem.swap(*Tab, &container.tabs.items[container.selected], &container.tabs.items[new_index]);
    container.selected = new_index;
    self.invalidateTabBar();
    self.invalidateSidebar();
}

/// Called when a terminal surface's title changes. Delegates to the
/// tab variant.
pub fn onTabTitleChanged(self: *Window, surface: *Surface, title: [:0]const u8) void {
    const tab = surface.tab orelse return;
    self.onPaneTitleChanged(tab, title);
}

/// Called when a tab's content title changes (OSC 0/2, document title).
/// Updates the stored title and refreshes the window title bar / tab bar
/// if needed. The title is capped at 255 bytes on a code-point boundary
/// (the former 256-unit title slots); undecodable text clears it. It
/// replaces a user rename, as before W0-A2 (renames do not stick yet,
/// ui-model 8.1 #12).
pub fn onPaneTitleChanged(self: *Window, tab: *Tab, title: [:0]const u8) void {
    const loc = self.findLoc(tab) orelse return;
    const capped = capUtf8(title, 255);
    const value: []const u8 = if (std.unicode.utf8ValidateSlice(capped)) capped else "";
    tab.title.setAuto(self.app.core_app.alloc, value, .process, true) catch return;
    const container = loc.pane;
    if (loc.ws == self.activeWorkspace() and container == loc.ws.focused_pane and loc.index == container.selected) self.updateWindowTitle();
    self.invalidateTabBar();
    self.invalidateSidebar();
}

/// Set the sidebar status indicator for the tab containing a surface.
/// No-op if the surface is not in any tab of this window.
pub fn setTabStatusForSurface(self: *Window, surface: *Surface, status: TabStatus) void {
    const loc = self.findLocOfSurface(surface) orelse return;
    const tab = loc.pane.tabs.items[loc.index];
    if (tab.legacy.status == status) return;
    tab.legacy.status = status;
    self.invalidateSidebar();
}

/// Recompute the attention aggregate of tab `tab` of `container` from its
/// content: a tab shows attention iff its Surface has the attention flag
/// set. Called after any surface flag flips so the per-tab aggregate the
/// sidebar/tab paint reads stays consistent with the per-surface source
/// of truth. The ring overlay reads the Surface flags directly.
pub fn recomputeTabAttention(self: *Window, container: *Pane, tab: usize) void {
    _ = self;
    const t = container.tabs.items[tab];
    t.legacy.attention = if (t.surface()) |s| s.attention else false;
}

/// Flag (or clear) the notification ring on the tab wrapping `surface`.
/// Sets the per-surface flag, recomputes its tab's aggregate, and
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
    self.recomputeTabAttention(loc.pane, loc.index);
    // If the user is already looking at this tab (selected tab of the
    // focused pane in the active workspace), clear immediately — no
    // point flagging something the user can already see.
    if (on) {
        const ws = self.activeWorkspace();
        if (loc.ws == ws) {
            if (ws.focused_pane) |fc| {
                if (loc.pane == fc and loc.index == fc.selected) {
                    self.clearTabAttention(fc, loc.index);
                }
            }
        }
    }
    self.invalidateSidebar();
    self.invalidateTabBar();
    self.updateAttentionRings();
}

/// Clear the notification ring on the tab wrapping `surface` (the pane
/// gained focus / the user is now looking at it). Thin wrapper over
/// setAttentionForSurface(false) so the focus path reads clearly.
pub fn clearAttentionForSurface(self: *Window, surface: *Surface) void {
    self.setAttentionForSurface(surface, false);
}

/// Clear attention on a tab and its aggregate. Used when a tab becomes
/// the visible selected tab (selectTabIndex/selectWorkspace): the user is
/// now looking at it, so its pending ring is satisfied. Repainting/ring
/// refresh is the caller's job (the select paths already invalidate +
/// layout).
pub fn clearTabAttention(self: *Window, container: *Pane, tab: usize) void {
    _ = self;
    const t = container.tabAt(tab) orelse return;
    if (t.surface()) |s| s.attention = false;
    t.legacy.attention = false;
}

/// Move a tab from one index to another, shifting intermediate tabs.
pub fn moveTabTo(self: *Window, from: usize, to: usize) void {
    const ws = self.activeWorkspace();
    const container = ws.focusedPaneOrFirst() orelse return;
    if (from == to) return;
    if (from >= container.tabCount() or to >= container.tabCount()) return;

    // Cancel any in-progress rename: the edit control's tab index
    // would otherwise point at the wrong tab after the move.
    self.cancelTabRename();

    // Lift the source tab out, shift the tabs between, drop it at the
    // destination.
    const moved = container.tabs.orderedRemove(from);
    container.tabs.insertAssumeCapacity(to, moved);

    container.selected = to;
    self.invalidateTabBar();
    self.invalidateSidebar();
}
