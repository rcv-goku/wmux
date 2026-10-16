//! Window-level workspace operations (ARCHITECTURE.md ADR-1.8 W0-A2 step
//! 2): create, select, close and reorder the workspaces of a window. Moved
//! out of Window.zig in W0-A2.

const std = @import("std");

const Window = @import("../../ui/Window.zig");
const arith_logic = @import("../logic/arith.zig");
const w32 = @import("../../platform/win32.zig");

const log = std.log.scoped(.win32);

const canCreateWorkspace = arith_logic.canCreateWorkspace;
const closeWorkspaceArith = arith_logic.closeWorkspaceArith;
const moveActiveFixup = arith_logic.moveActiveFixup;

/// Switch to the workspace at the given index. Hides the outgoing
/// workspace's visible panes BEFORE making the new one active (so two
/// workspaces never show panes at once), then lays out and focuses the
/// new workspace's active tab. QuickTerminal is single-workspace and
/// early-returns. No-op when the workspace is already active.
pub fn selectWorkspace(self: *Window, idx: usize) void {
    if (self.is_quick_terminal) return;
    if (idx >= self.workspace_count) return;
    if (idx == self.active_workspace) return;
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

    // Hide the outgoing workspace's visible panes (each container's
    // active tab) before switching, mirroring selectTabIndex's
    // hide-before-show ordering.
    const old_ws = self.activeWorkspace();
    {
        var it = old_ws.split_tree.iterator();
        while (it.next()) |entry| {
            const c = entry.view;
            if (c.tab_count > 0) {
                if (c.tabs[c.active_tab].hwnd()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
            }
        }
    }

    self.active_workspace = idx;

    // The incoming workspace's focused container's active tab is now
    // visible: clear its bell/exited status and attention ring.
    const new_ws = self.activeWorkspace();
    if (new_ws.focusedContainerOrFirst()) |fc| {
        fc.tab_status[fc.active_tab] = .normal;
        self.clearTabAttention(fc, fc.active_tab);
    }

    // The new workspace may have a different tab count, so the tab bar's
    // visibility can change. This may resize (changing surfaceRect), so
    // run it before laying out the new active tab.
    self.updateTabBarVisibility();
    self.layoutSplits();
    if (self.getActiveTab()) |pane| pane.focus();
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

/// Create a new workspace slot (a new sidebar row) and make it active,
/// WITHOUT giving it a tab. Returns the new index, or null for
/// QuickTerminal (single-workspace) or when the MAX_WORKSPACES cap is
/// reached. The slot is value-initialized (`= .{}`) so tab_status
/// starts .normal and name_len starts 0 (see Workspace).
///
/// Callers MUST immediately populate the workspace with one tab — and
/// collapse it via closeWorkspace(idx) if that fails — so the "every
/// workspace has at least one tab" invariant holds. Shared by
/// newWorkspace (default tab) and showBackendMenu's .new_workspace
/// target (picked-backend tab).
pub fn createAndSelectWorkspace(self: *Window) ?usize {
    if (!canCreateWorkspace(self.is_quick_terminal, self.workspace_count)) return null;
    self.cancelTabRename();

    const idx = self.workspace_count;
    self.workspaces[idx] = .{};
    self.workspace_count += 1;

    // selectWorkspace runs the hide-before-show switch onto the (empty)
    // new workspace; the caller's tab creation then populates it.
    self.selectWorkspace(idx);
    return idx;
}

/// Create a new workspace (a new sidebar row), make it active, and give
/// it one tab. No-op for QuickTerminal (single-workspace) or when the
/// MAX_WORKSPACES cap is reached.
pub fn newWorkspace(self: *Window) void {
    const idx = self.createAndSelectWorkspace() orelse return;
    _ = self.addTab() catch |err| {
        // The slot exists but has no tab. Collapse it back so the window
        // never shows an empty workspace.
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
/// (QuickTerminal, MAX_WORKSPACES) or its first tab failed to spawn (the
/// slot is collapsed back, matching newWorkspace). The working_dir copy
/// is freed by the workspace teardown paths (closeWorkspace /
/// cleanupAllSurfaces).
pub fn newWorkspaceWithDir(self: *Window, working_dir: []const u8) ?usize {
    const idx = self.createAndSelectWorkspace() orelse return null;
    // Bind the directory before addTab: addTabWithCommand reads
    // workspaces[active].working_dir to build the surface config clone.
    self.workspaces[idx].setWorkingDir(self.app.core_app.alloc, working_dir) catch {
        // Couldn't even copy the path; collapse the empty slot.
        self.closeWorkspace(idx);
        return null;
    };
    _ = self.addTab() catch |err| {
        log.err("failed to create first tab for new worktree workspace: {}", .{err});
        // closeWorkspace frees the binding we just set.
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

/// Create a new workspace slot (a new sidebar row) WITHOUT selecting it
/// and WITHOUT touching the active workspace. The counterpart to
/// createAndSelectWorkspace's create-half, kept separate so the agent IPC
/// (`+workspace new` without `--focus`) can create a background workspace
/// the user is NOT yanked into. Returns the new index, or null for
/// QuickTerminal or when MAX_WORKSPACES is reached. Callers MUST populate
/// it with one tab (and collapse via collapseEmptyWorkspaceSlot on
/// failure) so the "every workspace has at least one tab" invariant holds.
pub fn createWorkspaceSlot(self: *Window) ?usize {
    if (!canCreateWorkspace(self.is_quick_terminal, self.workspace_count)) return null;
    self.cancelTabRename();
    const idx = self.workspace_count;
    self.workspaces[idx] = .{};
    self.workspace_count += 1;
    return idx;
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
/// workspace could not be created (QuickTerminal, MAX_WORKSPACES) or its
/// first tab failed to spawn (the slot is collapsed back).
pub fn newWorkspaceBackground(self: *Window, working_dir: ?[]const u8, command: ?[]const []const u8) ?usize {
    const idx = self.createWorkspaceSlot() orelse return null;
    if (working_dir) |dir| {
        self.workspaces[idx].setWorkingDir(self.app.core_app.alloc, dir) catch {
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
    // (matches newWorkspaceWithDir); harmless for a plain background slot.
    if (working_dir != null) self.app.refreshWorkspaceMetadataNow(self, idx);
    return idx;
}

/// Drop a background workspace slot whose first tab failed to spawn,
/// WITHOUT going through closeWorkspace (which would re-select a survivor
/// and could close the window when this is the last slot — neither is
/// wanted for a never-shown background slot). The slot is the last one
/// (createWorkspaceSlot appends), is empty (tab_count == 0), and is not
/// the active workspace, so dropping it is pure bookkeeping: free its
/// worktree binding and decrement the count.
pub fn collapseEmptyWorkspaceSlot(self: *Window, idx: usize) void {
    if (idx + 1 != self.workspace_count) return;
    if (idx == self.active_workspace) return;
    self.workspaces[idx].freeWorkingDir(self.app.core_app.alloc);
    self.workspaces[idx] = .{};
    self.workspace_count -= 1;
    self.invalidateSidebar();
}

/// Close the workspace at `idx`: deinit all its tab trees (each unrefs
/// its panes), then either close the window (if it was the only
/// workspace) or shift the survivors down and select a neighbor.
pub fn closeWorkspace(self: *Window, idx: usize) void {
    if (self.is_quick_terminal) return;
    if (idx >= self.workspace_count) return;
    self.cancelTabRename();

    const arith = closeWorkspaceArith(self.workspace_count, self.active_workspace, idx);

    // Last workspace → close the whole window. Mirror closeTabByIndex's
    // last-tab path: flag closing FIRST so re-entrant input/focus
    // messages are dropped while the trees tear down, then post WM_CLOSE.
    if (arith == .close_window) {
        self.closing = true;
        const ws = &self.workspaces[idx];
        ws.split_tree.deinit();
        ws.split_tree = .empty;
        ws.focused_container = null;
        if (self.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
        return;
    }

    // If we are closing the active workspace, hide its visible panes
    // first (like selectWorkspace's hide-before-show) so no torn-down
    // panes linger on screen during the deinit.
    if (idx == self.active_workspace) {
        const ws = &self.workspaces[idx];
        var it = ws.split_tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.activeTabHwnd()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        }
    }

    // The survivor to focus AFTER the shift: the workspace that ends up
    // where this one was, clamped to the new last index. If the active
    // workspace sat after the removed one, its index shifts down. All
    // computed by closeWorkspaceArith above.
    const new_count = arith.survivors.new_count;
    const survivor = arith.survivors.new_active;

    // PUBLISH the post-shift workspaces array + active_workspace BEFORE
    // deiniting the closed workspace's trees: the deinit can destroy a
    // browser host HWND, which moves focus synchronously and re-enters
    // wndprocs that read workspaces/active_workspace. They must observe
    // the shifted, survivor-active state, never the dying workspace.
    // Move the closed workspace's struct OUT first (a value copy) so the
    // shift can overwrite its slot; deinit the copy afterward.
    var dying = self.workspaces[idx];
    for (idx..new_count) |i| {
        self.workspaces[i] = self.workspaces[i + 1];
    }
    // The shift leaves a duplicate of the last workspace past the new
    // count, whose split_tree aliases the live workspace's heap data;
    // value-init the slot so nothing can ever walk it (mirrors
    // closeTabByIndex clearing its duplicated tab slot).
    self.workspaces[new_count] = .{};
    self.workspace_count = new_count;
    self.active_workspace = survivor;

    // Tear down the closed workspace's split tree from the value copy now
    // that the live array no longer references it. Free its worktree
    // binding here too: the shift moved every survivor's working_dir
    // pointer down by value, so only this removed slot's copy is
    // unreferenced.
    dying.split_tree.deinit();
    dying.freeWorkingDir(self.app.core_app.alloc);

    // Lay out and focus the survivor. updateTabBarVisibility first (the
    // survivor may have a different tab count, changing surfaceRect).
    self.updateTabBarVisibility();
    self.layoutSplits();
    if (self.getActiveTab()) |pane| pane.focus();
    self.updateWindowTitle();
    self.invalidateTabBar();
    self.invalidateSidebar();
}

/// Move the workspace at `from` to `to`, shifting the workspaces between
/// them. Fixes up active_workspace so the same workspace stays active.
/// Analogous to moveTabTo. No-op for QuickTerminal or out-of-range.
pub fn moveWorkspaceTo(self: *Window, from: usize, to: usize) void {
    if (self.is_quick_terminal) return;
    if (from == to) return;
    if (from >= self.workspace_count or to >= self.workspace_count) return;
    self.cancelTabRename();

    // Lift the source workspace out, shift the workspaces between, drop
    // it at the destination (value shuffle of the whole struct).
    const saved = self.workspaces[from];
    if (from < to) {
        var i: usize = from;
        while (i < to) : (i += 1) self.workspaces[i] = self.workspaces[i + 1];
    } else {
        var i: usize = from;
        while (i > to) : (i -= 1) self.workspaces[i] = self.workspaces[i - 1];
    }
    self.workspaces[to] = saved;

    // Fix up active_workspace so the same workspace stays active across
    // the shuffle (pure arithmetic mirroring the shift above).
    self.active_workspace = moveActiveFixup(self.active_workspace, from, to);

    self.invalidateSidebar();
}
