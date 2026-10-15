//! Legacy wmux-v1 JSON command of the `chrome` feature:
//! toggle-right-sidebar.
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8). W1-8
//! re-points it to `wmux.right_sidebar.toggle` (Appendix B.4).

const App = @import("../../App.zig");
const ipc = @import("../../rpc/compat/legacy_json.zig");
const LegacyCommand = @import("../../rpc/compat/legacy_table.zig").LegacyCommand;

pub const commands = [_]LegacyCommand{
    .{ .cmd = "toggle-right-sidebar", .handler = &ipcToggleRightSidebar },
};

/// toggle-right-sidebar → toggle the right sidebar. Args are ignored.
/// (Formerly inline in App.handleIpcRequest.)
fn ipcToggleRightSidebar(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    // Toggle the right sidebar on the first window (or the window
    // owning the active surface). A simple toggle: no args needed.
    if (self.windows.items.len > 0) {
        self.windows.items[0].toggleRightSidebar();
    }
    server.sendOk(req.id, null) catch {};
}
