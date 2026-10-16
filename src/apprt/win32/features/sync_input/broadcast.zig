//! Synchronized input: replay a key or char event from the focused surface
//! to every other tab of its Pane while the active tab's sync
//! flag is on. Called from App.surfaceWndProc.
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8).

const input = @import("../../../../input.zig");
const Pane = @import("../../model/Pane.zig");
const Surface = @import("../../Surface.zig");

/// The focused pane of the source's window when its selected tab has
/// synchronized input on, else null.
fn syncedPane(source: *Surface) ?*Pane {
    const ws = source.parent_window.activeWorkspace();
    const pane = ws.focusedPaneOrFirst() orelse return null;
    const selected = pane.selectedTab() orelse return null;
    if (!selected.legacy.synchronized) return null;
    return pane;
}

/// Broadcast a key event (WM_KEYDOWN/WM_KEYUP) from the focused surface
/// to all other tabs in the same Pane when synchronized input is
/// active. Skipped when the surface is already receiving a broadcast (the
/// sync_broadcast guard prevents infinite loops).
pub fn broadcastKeyEvent(source: *Surface, wparam: usize, lparam: isize, action: input.Action) void {
    const pane = syncedPane(source) orelse return;

    // In the new model each tab is a single pane, so "synchronized"
    // broadcasts across all tabs of this pane. Indexed (the list is
    // re-read every step): a replayed key can run a binding that adds or
    // closes a tab, which may reallocate the list.
    var i: usize = 0;
    while (i < pane.tabs.items.len) : (i += 1) {
        const sibling = pane.tabs.items[i].surface() orelse continue;
        if (sibling == source) continue;
        sibling.sync_broadcast = true;
        _ = sibling.handleKeyEvent(wparam, lparam, action);
        sibling.sync_broadcast = false;
    }
}

/// Broadcast a WM_CHAR event to synchronized sibling panes.
pub fn broadcastCharEvent(source: *Surface, wparam: usize) void {
    const pane = syncedPane(source) orelse return;

    var i: usize = 0;
    while (i < pane.tabs.items.len) : (i += 1) {
        const sibling = pane.tabs.items[i].surface() orelse continue;
        if (sibling == source) continue;
        sibling.sync_broadcast = true;
        sibling.handleCharEvent(wparam);
        sibling.sync_broadcast = false;
    }
}
