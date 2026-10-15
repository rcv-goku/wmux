//! Synchronized input: replay a key or char event from the focused surface
//! to every other tab of its PaneContainer while the active tab's sync
//! flag is on. Called from App.surfaceWndProc.
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8).

const input = @import("../../../../input.zig");
const Surface = @import("../../Surface.zig");

/// Broadcast a key event (WM_KEYDOWN/WM_KEYUP) from the focused surface
/// to all other tabs in the same PaneContainer when synchronized input is
/// active. Skipped when the surface is already receiving a broadcast (the
/// sync_broadcast guard prevents infinite loops).
pub fn broadcastKeyEvent(source: *Surface, wparam: usize, lparam: isize, action: input.Action) void {
    const pw = source.parent_window;
    const ws = pw.activeWorkspace();
    const container = ws.focusedContainerOrFirst() orelse return;
    if (!container.tab_synchronized[container.active_tab]) return;

    // In the new model each tab is a single pane, so "synchronized"
    // broadcasts across all tabs of this container.
    for (container.tabs[0..container.tab_count]) |tab_pane| {
        const sibling = tab_pane.surface() orelse continue;
        if (sibling == source) continue;
        sibling.sync_broadcast = true;
        _ = sibling.handleKeyEvent(wparam, lparam, action);
        sibling.sync_broadcast = false;
    }
}

/// Broadcast a WM_CHAR event to synchronized sibling panes.
pub fn broadcastCharEvent(source: *Surface, wparam: usize) void {
    const pw = source.parent_window;
    const ws = pw.activeWorkspace();
    const container = ws.focusedContainerOrFirst() orelse return;
    if (!container.tab_synchronized[container.active_tab]) return;

    for (container.tabs[0..container.tab_count]) |tab_pane| {
        const sibling = tab_pane.surface() orelse continue;
        if (sibling == source) continue;
        sibling.sync_broadcast = true;
        sibling.handleCharEvent(wparam);
        sibling.sync_broadcast = false;
    }
}
