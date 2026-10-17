//! Modal-loop accounting (ARCHITECTURE.md ADR-1.6, ADR-12.3).
//! `app.modal.enter()`/`leave()` bracket every modal loop
//! (TrackPopupMenuEx, MessageBox, file dialogs, DoDragDrop,
//! WM_ENTERSIZEMOVE ... WM_EXITSIZEMOVE); the RPC dispatcher holds
//! mutating UI-lane requests while `depth > 0` (W1-1a, rpc/lanes.zig) and
//! releases them from the idle hook when the last loop ends.
//!
//! The message box and file dialog choke point, with its WMUX_TEST_MODE
//! auto-answers, is app/dialogs.zig (moved there in W0-A4); it brackets
//! every dialog it shows with this counter.

const std = @import("std");

/// Called on the UI thread when `depth` drops back to 0.
pub const IdleHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque) void,
};

pub const Modal = struct {
    /// Number of modal loops currently running on the UI thread.
    depth: u32 = 0,

    /// Runs when the last modal loop ends (the RPC dispatcher's modal
    /// hold; set while the control server runs).
    idle_hook: ?IdleHook = null,

    pub fn enter(self: *Modal) void {
        self.depth += 1;
    }

    pub fn leave(self: *Modal) void {
        std.debug.assert(self.depth > 0);
        self.depth -|= 1;
        if (self.depth == 0) {
            if (self.idle_hook) |h| h.f(h.ctx);
        }
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

test "unit: app: modal idle hook runs once when the last loop ends" {
    const Counter = struct {
        n: u32 = 0,
        fn hit(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.n += 1;
        }
    };
    var c: Counter = .{};
    var m: Modal = .{ .idle_hook = .{ .ctx = &c, .f = Counter.hit } };
    m.enter();
    m.enter();
    m.leave();
    try testing.expectEqual(@as(u32, 0), c.n);
    m.leave();
    try testing.expectEqual(@as(u32, 1), c.n);
}
