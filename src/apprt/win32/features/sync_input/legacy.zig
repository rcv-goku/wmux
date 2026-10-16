//! Legacy wmux-v1 JSON command of the `sync_input` feature: sync-input.
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8). W2-2
//! re-points it to `wmux.sync_input.set` (Appendix B.4).

const std = @import("std");

const App = @import("../../App.zig");
const ipc = @import("../../rpc/compat/legacy_json.zig");
const LegacyCommand = @import("../../rpc/compat/legacy_table.zig").LegacyCommand;
const targets = @import("../../rpc/compat/legacy_targets.zig");

const IpcError = targets.IpcError;

/// Read a required string field from the request args.
const ipcArgString = ipc.argString;

/// Read an optional u32 index field ("index"/"workspace"/"tab").
const ipcArgU32 = ipc.argU32;

pub const commands = [_]LegacyCommand{
    .{ .cmd = "sync-input", .handler = &ipcSyncInput },
};

/// sync-input {action:"toggle"|"on"|"off", [workspace], [tab], [pane]} →
/// toggle or set synchronized input for the addressed tab. Defaults to
/// active workspace and focused Pane's active tab.
fn ipcSyncInput(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const action_str = ipcArgString(req, "action") orelse "toggle";
    const target = try targets.ipcResolveWorkspace(self, req);
    const container = if (ipcArgU32(req, "pane")) |p|
        target.ws.containerAtIndex(p) orelse return IpcError.UnknownPane
    else
        target.ws.focusedContainerOrFirst() orelse return IpcError.UnknownTab;
    const tab_idx: usize = if (ipcArgU32(req, "tab")) |t| t else container.active_tab;
    if (tab_idx >= container.tab_count) return IpcError.UnknownTab;

    if (std.mem.eql(u8, action_str, "toggle")) {
        container.tab_synchronized[tab_idx] = !container.tab_synchronized[tab_idx];
    } else if (std.mem.eql(u8, action_str, "on")) {
        container.tab_synchronized[tab_idx] = true;
    } else if (std.mem.eql(u8, action_str, "off")) {
        container.tab_synchronized[tab_idx] = false;
    } else {
        return IpcError.BadAction;
    }
    target.window.invalidateTabBar();
    server.sendOk(req.id, null) catch {};
}
