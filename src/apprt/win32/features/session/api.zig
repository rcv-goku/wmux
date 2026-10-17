//! Public API of the `session` feature (ARCHITECTURE.md ADR-9). Other
//! features and the layers reach the session only through this file
//! (ADR-1.2).
//!
//! Stubs written by W0-A3 (pre-wiring); W1-7 implements them (session v3,
//! autosave, restore, scrollback replay). `onWindowClose` was added by the
//! W1 kickoff interface commit (W1-IF): ui/Window.zig's `WM_CLOSE` calls it
//! instead of saving the legacy session itself, so W1-7a replaces the
//! per-window overwrite here without touching the frozen Window.zig.

const Surface = @import("../../Surface.zig");
const Window = @import("../../ui/Window.zig");
const legacy_v2 = @import("legacy_v2.zig");

/// The saved scrollback (VT text) to replay into `surface`'s terminal
/// before its shell starts (ADR-9.5), borrowed until the core surface's
/// Termio.init returns, or null. Nothing to replay yet.
pub fn restoreHistory(surface: *Surface) ?[]const u8 {
    _ = surface;
    return null;
}

/// `window` received `WM_CLOSE` and is about to close (its geometry is
/// saved already; the HWND still exists). Today: the legacy save of the
/// session layout (workspaces, tabs, cwds) to `session-state.json`,
/// skipped in test mode unless `WMUX_TEST_SESSION_RESTORE` asks for it
/// (ADR-12.3: only automatic saves are gated). W1-7a replaces it with the
/// v3 full-save rules (no per-window overwrite).
pub fn onWindowClose(window: *Window) void {
    if (window.app.runtime_env.sessionSaveOnCloseAllowed()) {
        legacy_v2.save(window.app.core_app.alloc, window) catch {};
    }
}

test {
    _ = &onWindowClose;
}
