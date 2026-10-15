//! Legacy wmux-v1 JSON command of the `layouts` feature: select-layout.
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8). W2-2
//! re-points it to `wmux.layout.select` (Appendix B.4).

const std = @import("std");

const apprt = @import("../../../../apprt.zig");
const App = @import("../../App.zig");
const ipc = @import("../../rpc/compat/legacy_json.zig");
const LegacyCommand = @import("../../rpc/compat/legacy_table.zig").LegacyCommand;
const targets = @import("../../rpc/compat/legacy_targets.zig");

const IpcError = targets.IpcError;

pub const commands = [_]LegacyCommand{
    .{ .cmd = "select-layout", .handler = &ipcSelectLayout },
};

/// select-layout {layout} → rearrange splits into a predefined layout.
/// Without a window the request fails with NoWindow (it used to return
/// without replying, leaving the client blocked forever).
fn ipcSelectLayout(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const name = ipc.argString(req, "layout") orelse
        return server.sendError(req.id, "missing \"layout\" argument") catch {};
    const layout = std.meta.stringToEnum(apprt.action.SelectLayout, name) orelse
        return server.sendError(req.id, "unknown layout") catch {};
    const window = targets.ipcTargetWindow(self) orelse return IpcError.NoWindow;
    window.selectLayout(layout);
    server.sendOk(req.id, null) catch {};
}
