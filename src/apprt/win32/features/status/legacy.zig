//! Legacy wmux-v1 JSON commands of the `status` feature: set-status,
//! set-progress, log (`wmux +status|+log ...`).
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8). W2-6
//! re-points them to the v2 `wmux.sidebar.*` methods (Appendix B.4).

const std = @import("std");

const App = @import("../../App.zig");
const Window = @import("../../Window.zig");
const ipc = @import("../../rpc/compat/legacy_json.zig");
const LegacyCommand = @import("../../rpc/compat/legacy_table.zig").LegacyCommand;
const targets = @import("../../rpc/compat/legacy_targets.zig");

const IpcError = targets.IpcError;

/// Read a required string field from the request args.
const ipcArgString = ipc.argString;

pub const commands = [_]LegacyCommand{
    .{ .cmd = "set-status", .handler = &ipcSetStatus },
    .{ .cmd = "set-progress", .handler = &ipcSetProgress },
    .{ .cmd = "log", .handler = &ipcLog },
};

/// set-status {[workspace],[tab],[text]} → set (or clear, when text is
/// empty/absent) the addressed tab's orchestration status string. Stored on
/// the workspace; the sidebar renders it (Stage 2). Repaints the sidebar.
fn ipcSetStatus(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try targets.ipcResolveTab(self, req);
    const text = ipcArgString(req, "text") orelse "";
    const container = target.container;
    const n: u16 = @intCast(@min(text.len, Window.MAX_STATUS_BYTES));
    @memcpy(container.tab_status_text[target.tab_idx][0..n], text[0..n]);
    container.tab_status_text_len[target.tab_idx] = n;
    target.window.invalidateSidebar();
    server.sendOk(req.id, null) catch {};
}

/// set-progress {[workspace],[tab], value} → set the addressed tab's
/// progress percent (0..100), or clear it with value -1 (or absent).
fn ipcSetProgress(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try targets.ipcResolveTab(self, req);
    const container = target.container;
    const value = ipc.argI64Named(req, "value") orelse -1;
    if (value < 0) {
        container.tab_progress[target.tab_idx] = null;
    } else if (value <= 100) {
        container.tab_progress[target.tab_idx] = @intCast(value);
    } else {
        return IpcError.BadProgress;
    }
    target.window.invalidateSidebar();
    server.sendOk(req.id, null) catch {};
}

/// log {[workspace],[tab], text} → append a line to the addressed tab's
/// ring log buffer (and the global notification panel). Repaints the
/// sidebar. The line is truncated to the ring's per-line cap.
fn ipcLog(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const text = ipcArgString(req, "text") orelse return IpcError.MissingText;
    const target = try targets.ipcResolveTab(self, req);
    const container = target.container;
    container.tab_log[target.tab_idx].push(text);

    // Also surface it in the global notif panel (reuses pushNotif), tied
    // to the addressed tab's pane when it is a terminal.
    const pane = container.tabs[target.tab_idx];
    if (pane.surface()) |surface| {
        const alloc = self.core_app.alloc;
        const body_w = std.unicode.utf8ToUtf16LeAlloc(alloc, text[0..@min(text.len, 128)]) catch null;
        defer if (body_w) |bw| alloc.free(bw);
        const title_w = std.unicode.utf8ToUtf16LeStringLiteral("log");
        self.pushNotif(.osc, target.window, surface, title_w, if (body_w) |bw| bw else &.{});
    } else {
        target.window.invalidateSidebar();
    }
    server.sendOk(req.id, null) catch {};
}
