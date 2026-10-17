//! Public API of the `session` feature (ARCHITECTURE.md ADR-9). Other
//! features and the layers reach the session only through this file
//! (ADR-1.2).
//!
//! W1-7a implements session v3: the autosave, the full saves, restore on
//! launch, crash markers, the v2 migration, placement and cwd
//! (autosave.zig, writer.zig, restore.zig, markers.zig, migrate.zig,
//! placement_io.zig). `restoreHistory` (scrollback replay) stays W1-7b's.

const std = @import("std");

const App = @import("../../App.zig");
const Surface = @import("../../Surface.zig");
const Window = @import("../../ui/Window.zig");
const autosave = @import("autosave.zig");
const placement_io = @import("placement_io.zig");
const WindowState = @import("../../ui/placement_state.zig");

/// The saved scrollback (VT text) to replay into `surface`'s terminal
/// before its shell starts (ADR-9.5), borrowed until the core surface's
/// Termio.init returns, or null. Nothing to replay yet (W1-7b).
pub fn restoreHistory(surface: *Surface) ?[]const u8 {
    _ = surface;
    return null;
}

/// `window` received `WM_CLOSE` and is about to close (its geometry is
/// saved already; the HWND still exists). Session v3 rules (ADR-9.3): the
/// last window's close is a full save of the whole app (written before
/// the process exits); closing any other window only marks the session
/// dirty, so the next autosave drops it (no per-window overwrite: the
/// last-closed-window-wins bug of the legacy file is gone). Nothing is
/// saved in test mode without WMUX_TEST_SESSION_RESTORE (no Core).
pub fn onWindowClose(window: *Window) void {
    const core = autosave.get(window.app) orelse return;
    if (window.is_quick_terminal) return;
    var others: usize = 0;
    for (window.app.windows.items) |w| {
        if (w != window and !w.is_quick_terminal and !w.closing) others += 1;
    }
    if (others == 0) autosave.fullSave(core, .background) else core.dirty = true;
}

/// The app is quitting (`quit`, `close_all_windows`; CCR W1-7a-1 wires the
/// call from app/perform_action.zig): a full save while every window still
/// exists.
pub fn onQuit(app: *App) void {
    const core = autosave.get(app) orelse return;
    autosave.fullSave(core, .background);
}

/// The model changed in a way no lifecycle event reports (a window moved
/// or resized, a cwd or title changed): the next autosave tick serializes.
pub fn markDirty(app: *const App) void {
    autosave.markDirty(app);
}

/// The geometry the first window is created with while a launch restore
/// is pending (ui/placement.zig `restorePlacement`): the saved window 0
/// placement, clamped to its monitor's work area. Null when no restore is
/// pending or it has no placement.
pub fn pendingFirstPlacement(app: *const App) ?WindowState.State {
    const core = autosave.get(app) orelse return null;
    const parsed = core.pending orelse return null;
    if (parsed.session.windows.len == 0) return null;
    const p = parsed.session.windows[0].placement orelse return null;
    return placement_io.initialState(p);
}

/// Whether a launch restore is pending or running.
pub fn restoreInProgress(app: *const App) bool {
    const core = autosave.get(app) orelse return false;
    return core.restoring;
}

test {
    _ = &onWindowClose;
    _ = &onQuit;
    _ = &markDirty;
    _ = &pendingFirstPlacement;
}
