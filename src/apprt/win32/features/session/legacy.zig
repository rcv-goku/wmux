//! Legacy wmux-v1 JSON commands of the `session` feature: session-capture,
//! session-resume, session-list, session-save, session-restore
//! (`wmux +session ...`).
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8). W1-7
//! and W3-5 re-point them to the v2 session/resume methods (Appendix B.4).

const std = @import("std");

const agent_session = @import("../../agent_session.zig");
const App = @import("../../App.zig");
const SessionState = @import("../../SessionState.zig");
const Surface = @import("../../Surface.zig");
const ipc = @import("../../rpc/compat/legacy_json.zig");
const LegacyCommand = @import("../../rpc/compat/legacy_table.zig").LegacyCommand;
const targets = @import("../../rpc/compat/legacy_targets.zig");

const IpcError = targets.IpcError;

/// Read a required string field from the request args.
const ipcArgString = ipc.argString;

/// Read the optional u64 "surface" arg: a stable surface id
/// (GHOSTTY_SURFACE_ID). Pure logic in legacy_json.zig so the protocol tests cover it.
const ipcArgU64 = ipc.argU64;

pub const commands = [_]LegacyCommand{
    .{ .cmd = "session-capture", .handler = &ipcSessionCapture },
    .{ .cmd = "session-resume", .handler = &ipcSessionResume },
    .{ .cmd = "session-list", .handler = &ipcSessionList, .read_only = true },
    .{ .cmd = "session-save", .handler = &ipcSessionSave },
    .{ .cmd = "session-restore", .handler = &ipcSessionRestore },
};

/// Resolve the surface a session verb targets: an explicit `surface` id, or
/// the addressed (or active) tab's active terminal pane. Returns the surface
/// id and a pointer to the surface (for relaunch). The id is the core
/// Surface.id (stable, == GHOSTTY_SURFACE_ID).
const SessionTarget = struct { id: u64, surface: *Surface };

fn ipcResolveSessionTarget(self: *App, req: *ipc.Request) IpcError!SessionTarget {
    if (ipcArgU64(req, "surface")) |sid| {
        const loc = targets.ipcFindSurfaceById(self, sid) orelse return IpcError.UnknownSurface;
        return .{ .id = sid, .surface = loc.surface };
    }
    const target = try targets.ipcResolveTab(self, req);
    const pane = target.container.activeTab() orelse return IpcError.UnknownPane;
    const surface = pane.surface() orelse return IpcError.NotATerminal;
    if (!surface.core_surface_initialized) return IpcError.CoreNotReady;
    return .{ .id = surface.core_surface.id, .surface = surface };
}

/// session-capture {agent, session, [surface]|[workspace,tab]} → record the
/// (surface → agent + native session id) association in the store. Default
/// target is the calling pane (the pane whose shell ran the hook); an
/// explicit `surface` (GHOSTTY_SURFACE_ID, the hook's own pane) wins and
/// removes the active-pane race.
fn ipcSessionCapture(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const agent_name = ipcArgString(req, "agent") orelse return IpcError.MissingAgent;
    const session = ipcArgString(req, "session") orelse return IpcError.MissingSession;
    const target = try ipcResolveSessionTarget(self, req);

    const kind = agent_session.AgentKind.parse(agent_name);
    // put returns SessionIdTooLong for an oversized (hostile/garbled) id;
    // surface it verbatim to the client rather than masking it as OOM.
    try self.session_store.put(target.id, kind, session);
    // Repaint so a sidebar "resumable" affordance (Stage 2) can reflect it.
    if (targets.ipcFindSurfaceById(self, target.id)) |loc| loc.window.invalidateSidebar();

    // 20 (u64 max digits) + agent tag + JSON scaffold; 96 is ample.
    var data_buf: [96]u8 = undefined;
    const data = std.fmt.bufPrint(&data_buf, "{{\"surface\":{d},\"agent\":\"{s}\"}}", .{ target.id, @tagName(kind) }) catch
        return error.NoSpaceLeft;
    server.sendOk(req.id, data) catch {};
}

/// session-resume {[surface]|[workspace,tab]} → look up the target surface's
/// captured agent + id and replay the agent's resume argv into that pane via
/// the keystroke path (ipcSendText, +CR), so the agent relaunches in place.
/// NoSession if nothing was captured for the surface; NoResumeRecipe if the
/// captured agent has no resume command (`.unknown`).
fn ipcSessionResume(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try ipcResolveSessionTarget(self, req);
    const entry = self.session_store.get(target.id) orelse return IpcError.NoSession;

    var argv_buf: [agent_session.max_resume_argv][]const u8 = undefined;
    const n = entry.agent.resumeArgv(entry.session_id, &argv_buf) catch
        return IpcError.NoResumeRecipe;

    // Join argv into a single shell command line. The pieces are an exe
    // name + flags + a session id (UUID/token), none of which contain
    // spaces in the supported agents, so a plain space join is safe.
    const alloc = self.core_app.alloc;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    for (argv_buf[0..n], 0..) |part, i| {
        if (i > 0) try line.append(alloc, ' ');
        try line.appendSlice(alloc, part);
    }
    try target.surface.ipcSendText(line.items, true);
    server.sendOk(req.id, null) catch {};
}

/// session-list → dump the whole agent-session store as JSON
/// `[{surface, agent, session}]`.
fn ipcSessionList(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const alloc = self.core_app.alloc;
    const json = try self.session_store.serialize(alloc);
    defer alloc.free(json);
    server.sendOk(req.id, json) catch {};
}

/// session-save → persist the first window's layout (SessionState.save).
/// (Formerly inline in App.handleIpcRequest.)
fn ipcSessionSave(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const alloc = self.core_app.alloc;
    if (self.windows.items.len > 0) {
        try SessionState.save(alloc, self.windows.items[0]);
    }
    server.sendOk(req.id, null) catch {};
}

/// session-restore → restore the saved layout (SessionState.restore).
/// (Formerly inline in App.handleIpcRequest.)
fn ipcSessionRestore(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const alloc = self.core_app.alloc;
    try SessionState.restore(alloc, self);
    server.sendOk(req.id, null) catch {};
}
