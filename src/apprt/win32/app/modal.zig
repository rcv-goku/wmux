//! Modal-loop accounting (ARCHITECTURE.md ADR-1.6, ADR-12.3).
//! `app.modal.enter()`/`leave()` bracket every modal loop
//! (TrackPopupMenuEx, MessageBox, file dialogs, DoDragDrop,
//! WM_ENTERSIZEMOVE ... WM_EXITSIZEMOVE); from W1-1 on the RPC dispatcher
//! holds mutating UI-lane requests while `depth > 0`.
//!
//! The message box and file dialog choke point, with its WMUX_TEST_MODE
//! auto-answers, is app/dialogs.zig (moved there in W0-A4); it brackets
//! every dialog it shows with this counter.

const std = @import("std");

pub const Modal = struct {
    /// Number of modal loops currently running on the UI thread.
    depth: u32 = 0,

    pub fn enter(self: *Modal) void {
        self.depth += 1;
    }

    pub fn leave(self: *Modal) void {
        std.debug.assert(self.depth > 0);
        self.depth -|= 1;
    }

    pub fn active(self: *const Modal) bool {
        return self.depth > 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: app: modal depth brackets nest" {
    var m: Modal = .{};
    try testing.expect(!m.active());
    m.enter();
    m.enter();
    try testing.expect(m.active());
    m.leave();
    try testing.expect(m.active());
    m.leave();
    try testing.expect(!m.active());
}
