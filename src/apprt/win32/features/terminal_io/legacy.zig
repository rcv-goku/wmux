//! Legacy wmux-v1 JSON commands of the `terminal_io` feature: send,
//! read-screen, capture-pane (`wmux +send|+read-screen|+capture-pane`).
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8). W2-3
//! re-points them to the v2 `surface.send_text`/`surface.read_text`
//! methods (Appendix B.4).

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

/// Read an optional bool field (send's "enter").
const ipcArgBool = ipc.argBool;

pub const commands = [_]LegacyCommand{
    .{ .cmd = "send", .handler = &ipcSend },
    .{ .cmd = "read-screen", .handler = &ipcReadScreen, .read_only = true },
    .{ .cmd = "capture-pane", .handler = &ipcCapturePaneCmd, .read_only = true },
};

/// send {text, [workspace], [tab], [enter]} → write `text` to the child
/// PTY of the active pane of the addressed (or active) workspace's
/// addressed (or active) tab, exactly as typed input would, optionally
/// appending a carriage return (`enter`). Browser panes have no PTY and
/// answer NotATerminal.
fn ipcSend(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const text = ipcArgString(req, "text") orelse return IpcError.MissingText;
    const target = try targets.ipcResolveWorkspace(self, req);
    const container = if (ipcArgU32(req, "pane")) |p|
        target.ws.paneAt(p) orelse return IpcError.UnknownPane
    else
        target.ws.focusedPaneOrFirst() orelse return IpcError.UnknownTab;

    const tab_idx: usize = if (ipcArgU32(req, "tab")) |t| t else container.selected;
    if (tab_idx >= container.tabCount()) return IpcError.UnknownTab;

    const pane = container.tabs.items[tab_idx];
    const surface = pane.surface() orelse return IpcError.NotATerminal;

    const enter = ipcArgBool(req, "enter") orelse false;
    try surface.ipcSendText(text, enter);
    server.sendOk(req.id, null) catch {};
}

/// read-screen {[workspace],[tab],[lines],[scrollback]} → the addressed
/// (or active) pane terminal's screen text as UTF-8. By default the visible
/// active screen; with `scrollback:true` the full screen including
/// scrollback history. The terminal screen is locked under the renderer
/// mutex while it is dumped. The framer's 1 MiB cap bounds very long
/// scrollback (truncated by the wire layer). This is the agent-reads-agent
/// verb. `lines` (when given) keeps only the last N non-empty-trimmed
/// physical lines of the dump (a cheap tail; v1 limitation noted in the
/// CLI help).
fn ipcReadScreen(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try targets.ipcResolveTab(self, req);
    const container = target.container;
    const pane = container.tabs.items[target.tab_idx];
    const surface = pane.surface() orelse return IpcError.NotATerminal;
    if (!surface.core_surface_ready) return IpcError.CoreNotReady;

    const alloc = self.core_app.alloc;
    const scrollback = ipcArgBool(req, "scrollback") orelse false;

    // Dump under the renderer mutex: the screen is shared with the
    // renderer/IO threads. dumpStringAlloc walks the active screen
    // (visible) or the full screen (scrollback) as plain UTF-8.
    const dump: []const u8 = dump: {
        const cs = &surface.core_surface;
        cs.renderer_state.mutex.lock();
        defer cs.renderer_state.mutex.unlock();
        // ScreenSet.active is already a *Screen.
        const screen = cs.io.terminal.screens.active;
        const point: @import("../../../../terminal/main.zig").point.Point =
            if (scrollback) .{ .screen = .{ .x = 0, .y = 0 } } else .{ .active = .{ .x = 0, .y = 0 } };
        break :dump try screen.dumpStringAlloc(alloc, point);
    };
    defer alloc.free(dump);

    // Optional tail: keep only the last N lines.
    const text: []const u8 = if (ipcArgU32(req, "lines")) |n| blk: {
        if (n == 0) break :blk dump;
        var count: usize = 0;
        var i: usize = dump.len;
        // Walk back over up to N newline-separated lines.
        while (i > 0) {
            const nl = std.mem.lastIndexOfScalar(u8, dump[0..i], '\n') orelse {
                break;
            };
            count += 1;
            if (count >= n) {
                break :blk dump[nl + 1 ..];
            }
            i = nl;
        }
        break :blk dump;
    } else dump;

    // Reply as a JSON string (escaped). The dump can be large; cap it
    // generously below the framer's 1 MiB so the response (with escaping
    // overhead) still fits.
    const max_payload: usize = 768 * 1024;
    const clipped = if (text.len > max_payload) text[text.len - max_payload ..] else text;

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try std.json.Stringify.value(clipped, .{}, &aw.writer);
    server.sendOk(req.id, aw.written()) catch {};
}

/// capture-pane {[workspace],[tab],[scrollback:bool],[file:path]} — the
/// tmux `capture-pane` equivalent. Dumps the addressed (or active) pane's
/// screen text, optionally including the scrollback buffer. When `file` is
/// given the dump is written there instead of returned as the IPC response.
/// The dump is plain UTF-8 text (no ANSI escapes) — matching read-screen's
/// format — so it can be piped back into a terminal for session restore.
fn ipcCapturePaneCmd(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try targets.ipcResolveTab(self, req);
    const container = target.container;
    const pane = container.tabs.items[target.tab_idx];
    const surface = pane.surface() orelse return IpcError.NotATerminal;
    if (!surface.core_surface_ready) return IpcError.CoreNotReady;

    const alloc = self.core_app.alloc;
    const scrollback = ipcArgBool(req, "scrollback") orelse false;

    // Dump under the renderer mutex: the screen is shared with the
    // renderer/IO threads.
    const dump: []const u8 = dump: {
        const cs = &surface.core_surface;
        cs.renderer_state.mutex.lock();
        defer cs.renderer_state.mutex.unlock();
        const screen = cs.io.terminal.screens.active;
        const point: @import("../../../../terminal/main.zig").point.Point =
            if (scrollback) .{ .screen = .{ .x = 0, .y = 0 } } else .{ .active = .{ .x = 0, .y = 0 } };
        break :dump try screen.dumpStringAlloc(alloc, point);
    };
    defer alloc.free(dump);

    // If a file path was given, write the dump there and reply with the
    // path; otherwise return the text as the IPC data (JSON-escaped, same
    // as read-screen).
    if (ipcArgString(req, "file")) |file_path| {
        // Ensure parent directory exists.
        if (std.fs.path.dirname(file_path)) |parent| {
            std.fs.cwd().makePath(parent) catch {};
        }
        const file = std.fs.cwd().createFile(file_path, .{ .truncate = true }) catch
            return error.CreateFileFailed;
        defer file.close();
        file.writeAll(dump) catch return error.WriteFileFailed;

        // Reply with the path we wrote.
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        try std.json.Stringify.value(file_path, .{}, &aw.writer);
        server.sendOk(req.id, aw.written()) catch {};
    } else {
        const max_payload: usize = 768 * 1024;
        const clipped = if (dump.len > max_payload) dump[dump.len - max_payload ..] else dump;

        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        try std.json.Stringify.value(clipped, .{}, &aw.writer);
        server.sendOk(req.id, aw.written()) catch {};
    }
}
