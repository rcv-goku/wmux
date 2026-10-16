//! Legacy wmux-v1 JSON commands of the `notifications` feature: notify
//! (ring/clear/next/toggle-read/mark-oldest-next) and flash-pane
//! (`wmux +notify ...`).
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8). W2-5
//! re-points them to the v2 notification/attention methods (Appendix B.4).

const std = @import("std");

const App = @import("../../App.zig");
const ipc = @import("../../rpc/compat/legacy_json.zig");
const LegacyCommand = @import("../../rpc/types.zig").LegacyCommand;
const targets = @import("../../rpc/compat/legacy_targets.zig");
const ring = @import("legacy_ring.zig");

const IpcError = targets.IpcError;

/// Read a required string field from the request args.
const ipcArgString = ipc.argString;

/// Read an optional u32 index field ("index"/"workspace"/"tab").
const ipcArgU32 = ipc.argU32;

pub const commands = [_]LegacyCommand{
    .{ .cmd = "notify", .handler = &ipcNotify },
    .{ .cmd = "flash-pane", .handler = &ipcFlashPane },
};

/// notify {action: "ring"|"clear"|"next", [workspace], [tab]} →
///   * "ring"/"clear": set or clear the notification-ring attention flag on
///     the active pane of the addressed (or active) workspace's addressed
///     (or active) tab. The explicit, reliable counterpart to the attention
///     OSC: an agent that can't emit an escape (or a wrapper script) rings
///     the pane it runs in via `ghostty +notify ring`. Browser panes have
///     no terminal surface and answer NotATerminal. Targeting the currently
///     visible+focused pane is accepted but the ring overlay won't draw on
///     it (you'd be ringed around what you're looking at); the cross-level
///     sidebar/tab dots still update.
///   * "next": jump to the most-recent UNREAD notification's surface
///     (cross-workspace, via jumpToSurface), mark that one Read, and reply
///     {jumped:true, surface:<id>}. With no unread entries, replies
///     {jumped:false}. Ignores workspace/tab (the target is the notifying
///     pane, wherever it lives).
fn ipcNotify(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const action = ipcArgString(req, "action") orelse return IpcError.MissingAction;

    if (std.mem.eql(u8, action, "next")) {
        try ipcNotifyNext(self, req);
        return;
    }

    if (std.mem.eql(u8, action, "toggle-read")) {
        try ipcNotifyToggleRead(self, req);
        return;
    }

    if (std.mem.eql(u8, action, "mark-oldest-next")) {
        try ipcNotifyMarkOldestNext(self, req);
        return;
    }

    const on = if (std.mem.eql(u8, action, "ring"))
        true
    else if (std.mem.eql(u8, action, "clear"))
        false
    else
        return IpcError.BadAction;

    const target = try targets.ipcResolveWorkspace(self, req);
    const container = if (ipcArgU32(req, "pane")) |p|
        target.ws.paneAt(p) orelse return IpcError.UnknownPane
    else
        target.ws.focusedPaneOrFirst() orelse return IpcError.UnknownTab;
    const tab_idx: usize = if (ipcArgU32(req, "tab")) |t| t else container.selected;
    if (tab_idx >= container.tabCount()) return IpcError.UnknownTab;

    const pane = container.tabs.items[tab_idx];
    const surface = pane.surface() orelse return IpcError.NotATerminal;
    target.window.setAttentionForSurface(surface, on);
    server.sendOk(req.id, null) catch {};
}

/// `+notify next`: jump to the most-recent unread notification's surface.
/// Resolves the freshest Unread entry, validates its (window, surface) by
/// address via jumpToSurface (the entry pointers may dangle), marks it Read
/// (Unread→Read lifecycle, which also lowers the taskbar badge), and replies
/// {jumped, surface}. The display index is recomputed against
/// firstUnreadNotif so markNotifEntryRead targets the same entry we jumped to.
fn ipcNotifyNext(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;

    const display_idx = ring.firstUnreadNotif(self) orelse {
        server.sendOk(req.id, "{\"jumped\":false}") catch {};
        return;
    };
    const entry = ring.notifAt(self, display_idx) orelse {
        server.sendOk(req.id, "{\"jumped\":false}") catch {};
        return;
    };
    const window = entry.window;
    const surface = entry.surface;

    // The entry's (window, surface) pointers may dangle: dropDesktopNotifsForWindow
    // scrubs entries only when their whole *window* is destroyed, NOT when an
    // individual pane/tab closes inside a surviving window. So validate the
    // surface by address BEFORE dereferencing it (mirrors jumpToSurface's own
    // re-find). A stale entry is a clean no-op, never a use-after-free.
    const live = blk: {
        for (self.windows.items) |w| {
            if (w == window) {
                if (w.closing) break :blk false;
                break :blk w.findLocOfSurface(surface) != null;
            }
        }
        break :blk false;
    };
    if (!live) {
        server.sendOk(req.id, "{\"jumped\":false}") catch {};
        return;
    }

    // Now safe to read: snapshot the surface id before jumping (jumpToSurface
    // may re-layout the pane tree, but the Surface object itself is stable).
    const surface_id: u64 = if (surface.core_surface_initialized)
        surface.core_surface.id
    else
        0;

    const jumped = ring.jumpToSurface(self, window, surface);
    if (jumped) _ = ring.markNotifEntryRead(self, display_idx);

    var buf: [64]u8 = undefined;
    const reply = std.fmt.bufPrint(
        &buf,
        "{{\"jumped\":{s},\"surface\":{d}}}",
        .{ if (jumped) "true" else "false", surface_id },
    ) catch "{\"jumped\":false}";
    server.sendOk(req.id, reply) catch {};
}

/// `+notify toggle-read`: toggle the most recent notification's read state.
/// Replies {toggled:true, read:<new_state>} or {toggled:false}.
fn ipcNotifyToggleRead(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const toggled = ring.toggleNotifRead(self, 0);
    if (toggled) {
        const entry = ring.notifAt(self, 0);
        const is_read = if (entry) |e| e.read else true;
        var buf: [48]u8 = undefined;
        const reply = std.fmt.bufPrint(
            &buf,
            "{{\"toggled\":true,\"read\":{s}}}",
            .{if (is_read) "true" else "false"},
        ) catch "{\"toggled\":false}";
        server.sendOk(req.id, reply) catch {};
    } else {
        server.sendOk(req.id, "{\"toggled\":false}") catch {};
    }
}

/// `+notify mark-oldest-next`: mark the oldest unread notification as read
/// and jump to the next unread entry's source pane. Replies
/// {jumped:true, surface:<id>} or {jumped:false}.
fn ipcNotifyMarkOldestNext(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;

    // Find the oldest unread entry and mark it read.
    const oldest_idx = self.notif_log.lastUnread() orelse {
        server.sendOk(req.id, "{\"jumped\":false}") catch {};
        return;
    };
    _ = ring.markNotifEntryRead(self, oldest_idx);

    // Now find the next unread (newest first, like ipcNotifyNext).
    const next_idx = ring.firstUnreadNotif(self) orelse {
        server.sendOk(req.id, "{\"jumped\":false}") catch {};
        return;
    };
    const entry = ring.notifAt(self, next_idx) orelse {
        server.sendOk(req.id, "{\"jumped\":false}") catch {};
        return;
    };
    const window = entry.window;
    const surface = entry.surface;

    // Validate liveness (mirrors ipcNotifyNext).
    const live = blk: {
        for (self.windows.items) |w| {
            if (w == window) {
                if (w.closing) break :blk false;
                break :blk w.findLocOfSurface(surface) != null;
            }
        }
        break :blk false;
    };
    if (!live) {
        server.sendOk(req.id, "{\"jumped\":false}") catch {};
        return;
    }

    const surface_id: u64 = if (surface.core_surface_initialized)
        surface.core_surface.id
    else
        0;

    const jumped = ring.jumpToSurface(self, window, surface);
    if (jumped) _ = ring.markNotifEntryRead(self, next_idx);

    var buf: [64]u8 = undefined;
    const reply = std.fmt.bufPrint(
        &buf,
        "{{\"jumped\":{s},\"surface\":{d}}}",
        .{ if (jumped) "true" else "false", surface_id },
    ) catch "{\"jumped\":false}";
    server.sendOk(req.id, reply) catch {};
}

/// flash-pane → flash the focused pane of the target window (brief visual
/// highlight). Args are ignored. (Formerly inline in App.handleIpcRequest.)
fn ipcFlashPane(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    // Flash the focused pane of the target window.
    if (targets.ipcTargetWindow(self)) |win| {
        win.flashFocusedPane();
    }
    server.sendOk(req.id, null) catch {};
}
