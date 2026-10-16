//! Window-level workspace operations (ARCHITECTURE.md ADR-1.8 W0-A2 step
//! 2): create, select, close and reorder the workspaces of a window. Moved
//! out of Window.zig in W0-A2. Workspaces are heap objects in
//! `Window.workspaces` and the selected one is `Window.selected`, so a
//! close or a reorder never moves a workspace in memory.

const std = @import("std");

const Window = @import("../../ui/Window.zig");
const Workspace = @import("../Workspace.zig");
const arith_logic = @import("../logic/arith.zig");
const w32 = @import("../../platform/win32.zig");

const log = std.log.scoped(.win32);

const canCreateWorkspace = arith_logic.canCreateWorkspace;
const closeWorkspaceArith = arith_logic.closeWorkspaceArith;

/// Switch to the workspace at the given index. Hides the outgoing
/// workspace's visible panes BEFORE making the new one active (so two
/// workspaces never show panes at once), then lays out and focuses the
/// new workspace's active tab. QuickTerminal is single-workspace and
/// early-returns. No-op when the workspace is already active.
pub fn selectWorkspace(self: *Window, idx: usize) void {
    if (self.is_quick_terminal) return;
    if (idx >= self.workspaces.items.len) return;
    if (idx == self.activeIndex()) return;
    self.cancelTabRename();

    // Clear any in-progress tab or sidebar-row drag (mirrors
    // selectTabIndex): an async switch (notif click, IPC jump) mid-drag
    // must not leave a captured drag reordering the new workspace's
    // tabs or the shifted rows. handleSidebarClick sets its drag state
    // AFTER calling selectWorkspace, so click-then-drag is unaffected.
    if (self.drag_tab >= 0) {
        self.drag_tab = -1;
        self.drag_active = false;
        _ = w32.ReleaseCapture();
    }
    if (self.sidebar_drag_row >= 0) {
        self.sidebar_drag_row = -1;
        self.sidebar_drag_active = false;
        _ = w32.ReleaseCapture();
    }

    // Hide the outgoing workspace's visible panes (each pane's selected
    // tab) before switching, mirroring selectTabIndex's hide-before-show
    // ordering.
    const old_ws = self.activeWorkspace();
    {
        var it = old_ws.tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.selectedHwnd()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        }
    }

    self.selected = self.workspaces.items[idx];

    // The incoming workspace's focused pane's selected tab is now
    // visible: clear its bell/exited status and attention ring.
    const new_ws = self.activeWorkspace();
    if (new_ws.focusedPaneOrFirst()) |fc| {
        if (fc.selectedTab()) |tab| tab.legacy.status = .normal;
        self.clearTabAttention(fc, fc.selected);
    }

    // The new workspace may have a different tab count, so the tab bar's
    // visibility can change. This may resize (changing surfaceRect), so
    // run it before laying out the new active tab.
    self.updateTabBarVisibility();
    self.layoutSplits();
    if (self.getActiveTab()) |tab| tab.focus();
    self.updateWindowTitle();
    self.invalidateTabBar();
    self.invalidateSidebar();
    self.updateAttentionRings();
    self.updatePaneButtons();

    // Refresh the now-visible workspace's sidebar metadata off-thread (the
    // periodic timer only scans the active workspace, so a freshly-focused
    // one would otherwise wait a full tick — and background ones never
    // refresh until focused).
    self.app.refreshWorkspaceMetadataNow(self, idx);
}

/// Append a new, empty workspace to the window's list. Returns its index,
/// or null for QuickTerminal (single-workspace) or when it cannot be
/// allocated. There is no workspace cap (G7). Also used by session
/// restore, which appends one workspace per saved one.
pub fn appendWorkspace(self: *Window) ?usize {
    if (!canCreateWorkspace(self.is_quick_terminal)) return null;
    const alloc = self.app.core_app.alloc;
    const ws = Workspace.create(alloc, self) catch return null;
    self.workspaces.append(alloc, ws) catch {
        ws.destroy(alloc);
        return null;
    };
    return self.workspaces.items.len - 1;
}

/// Create a new workspace (a new sidebar row) and make it active,
/// WITHOUT giving it a tab. Returns the new index, or null for
/// QuickTerminal (single-workspace) or on allocation failure.
///
/// Callers MUST immediately populate the workspace with one tab — and
/// collapse it via closeWorkspace(idx) if that fails — so the "every
/// workspace has at least one tab" invariant holds. Shared by
/// newWorkspace (default tab) and showBackendMenu's .new_workspace
/// target (picked-backend tab).
pub fn createAndSelectWorkspace(self: *Window) ?usize {
    if (!canCreateWorkspace(self.is_quick_terminal)) return null;
    self.cancelTabRename();

    const idx = appendWorkspace(self) orelse return null;

    // selectWorkspace runs the hide-before-show switch onto the (empty)
    // new workspace; the caller's tab creation then populates it.
    self.selectWorkspace(idx);
    return idx;
}

/// Create a new workspace (a new sidebar row), make it active, and give
/// it one tab. No-op for QuickTerminal (single-workspace).
pub fn newWorkspace(self: *Window) void {
    const idx = self.createAndSelectWorkspace() orelse return;
    _ = self.addTab() catch |err| {
        // The workspace exists but has no tab. Collapse it back so the
        // window never shows an empty workspace.
        log.err("failed to create first tab for new workspace: {}", .{err});
        self.closeWorkspace(idx);
    };
    self.invalidateSidebar();
}

/// Like newWorkspace, but binds the new workspace to `working_dir` (an
/// owned-by-caller path; copied here) BEFORE spawning its first tab, so
/// that tab — and every later tab of this workspace — opens in that
/// directory. Used by `+workspace new --worktree`. Returns the new
/// workspace index, or null when the workspace could not be created
/// (QuickTerminal) or its first tab failed to spawn (the workspace is
/// collapsed back, matching newWorkspace).
pub fn newWorkspaceWithDir(self: *Window, working_dir: []const u8) ?usize {
    const idx = self.createAndSelectWorkspace() orelse return null;
    // Bind the directory before addTab: addTabWithCommand reads the
    // active workspace's cwd to build the surface config clone.
    self.workspaces.items[idx].setCwd(self.app.core_app.alloc, working_dir) catch {
        // Couldn't even copy the path; collapse the empty workspace.
        self.closeWorkspace(idx);
        return null;
    };
    _ = self.addTab() catch |err| {
        log.err("failed to create first tab for new worktree workspace: {}", .{err});
        self.closeWorkspace(idx);
        return null;
    };
    self.invalidateSidebar();
    // Surface the git branch for the freshly-bound worktree right away
    // rather than waiting for the first periodic tick. The child shell may
    // not have a PID yet (ports come on a later tick), but rev-parse only
    // needs the directory.
    self.app.refreshWorkspaceMetadataNow(self, idx);
    return idx;
}

/// Create a new workspace (a new sidebar row) WITHOUT selecting it
/// and WITHOUT touching the active workspace. The counterpart to
/// createAndSelectWorkspace's create-half, kept separate so the agent IPC
/// (`+workspace new` without `--focus`) can create a background workspace
/// the user is NOT yanked into. Returns the new index, or null for
/// QuickTerminal or on allocation failure. Callers MUST populate it with
/// one tab (and collapse via collapseEmptyWorkspaceSlot on failure) so the
/// "every workspace has at least one tab" invariant holds.
pub fn createWorkspaceSlot(self: *Window) ?usize {
    if (!canCreateWorkspace(self.is_quick_terminal)) return null;
    self.cancelTabRename();
    return appendWorkspace(self);
}

/// Like newWorkspace / newWorkspaceWithDir, but creates the workspace in
/// the BACKGROUND: the active workspace does not change and the user is
/// not pulled in. Used by the agent IPC `+workspace new` (no `--focus`),
/// the non-focus default for programmatic creation. `working_dir` (an
/// owned-by-caller path; copied here) binds the workspace to a git
/// worktree like newWorkspaceWithDir; null keeps the configured cwd.
/// `command` (an argv slice; borrowed, NOT owned) is passed to the first
/// tab's surface.init so the tab runs that command instead of the default
/// shell. Used by `+ssh --workspace` to create a workspace whose first
/// tab runs `ssh user@host`. Returns the new index, or null when the
/// workspace could not be created (QuickTerminal) or its first tab failed
/// to spawn (the workspace is collapsed back).
pub fn newWorkspaceBackground(self: *Window, working_dir: ?[]const u8, command: ?[]const []const u8) ?usize {
    const idx = self.createWorkspaceSlot() orelse return null;
    if (working_dir) |dir| {
        self.workspaces.items[idx].setCwd(self.app.core_app.alloc, dir) catch {
            self.collapseEmptyWorkspaceSlot(idx);
            return null;
        };
    }
    self.addFirstTabBackground(idx, command) catch |err| {
        log.err("failed to create first tab for background workspace: {}", .{err});
        self.collapseEmptyWorkspaceSlot(idx);
        return null;
    };
    self.invalidateSidebar();
    // Surface git/port metadata for a worktree-bound workspace right away
    // (matches newWorkspaceWithDir); harmless for a plain background one.
    if (working_dir != null) self.app.refreshWorkspaceMetadataNow(self, idx);
    return idx;
}

/// Drop a background workspace whose first tab failed to spawn, WITHOUT
/// going through closeWorkspace (which would re-select a survivor and
/// could close the window when this is the last one — neither is wanted
/// for a never-shown background workspace). It is the last one
/// (createWorkspaceSlot appends), is empty, and is not the active
/// workspace, so dropping it is pure bookkeeping.
pub fn collapseEmptyWorkspaceSlot(self: *Window, idx: usize) void {
    if (idx + 1 != self.workspaces.items.len) return;
    if (idx == self.activeIndex()) return;
    const ws = self.workspaces.pop().?;
    ws.destroy(self.app.core_app.alloc);
    self.invalidateSidebar();
}

/// Close the workspace at `idx`: tear down its split tree (which unrefs
/// its panes and tabs), then either close the window (if it was the only
/// workspace) or remove it and select a neighbor.
pub fn closeWorkspace(self: *Window, idx: usize) void {
    if (self.is_quick_terminal) return;
    if (idx >= self.workspaces.items.len) return;
    self.cancelTabRename();

    const arith = closeWorkspaceArith(self.workspaces.items.len, self.activeIndex(), idx);

    // Last workspace → close the whole window. Mirror closeTabByIndex's
    // last-tab path: flag closing FIRST so re-entrant input/focus
    // messages are dropped while the trees tear down, then post WM_CLOSE.
    // The (now empty) workspace object stays until the window is freed.
    if (arith == .close_window) {
        self.closing = true;
        const ws = self.workspaces.items[idx];
        ws.tree.deinit();
        ws.tree = .empty;
        ws.syncZoomed();
        ws.focused_pane = null;
        if (self.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
        return;
    }

    // If we are closing the active workspace, hide its visible panes
    // first (like selectWorkspace's hide-before-show) so no torn-down
    // panes linger on screen during the teardown.
    if (idx == self.activeIndex()) {
        const ws = self.workspaces.items[idx];
        var it = ws.tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.selectedHwnd()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        }
    }

    // PUBLISH the post-removal list + selected workspace BEFORE tearing
    // down the closed workspace: the teardown can destroy a browser host
    // HWND, which moves focus synchronously and re-enters wndprocs that
    // read workspaces/selected. They must observe the survivor-active
    // state, never the dying workspace. The survivor is the workspace that
    // ends up where this one was, clamped to the new last index (computed
    // by closeWorkspaceArith above).
    const dying = self.workspaces.orderedRemove(idx);
    self.selected = self.workspaces.items[arith.survivors.new_active];
    dying.destroy(self.app.core_app.alloc);

    // Lay out and focus the survivor. updateTabBarVisibility first (the
    // survivor may have a different tab count, changing surfaceRect).
    self.updateTabBarVisibility();
    self.layoutSplits();
    if (self.getActiveTab()) |tab| tab.focus();
    self.updateWindowTitle();
    self.invalidateTabBar();
    self.invalidateSidebar();
}

/// Move the workspace at `from` to `to`, shifting the workspaces between
/// them. The selected workspace stays selected (it is held by pointer).
/// Analogous to moveTabTo. No-op for QuickTerminal or out-of-range.
pub fn moveWorkspaceTo(self: *Window, from: usize, to: usize) void {
    if (self.is_quick_terminal) return;
    if (from == to) return;
    if (from >= self.workspaces.items.len or to >= self.workspaces.items.len) return;
    self.cancelTabRename();

    // Lift the source workspace out and drop it at the destination.
    const ws = self.workspaces.orderedRemove(from);
    self.workspaces.insertAssumeCapacity(to, ws);

    self.invalidateSidebar();
}
