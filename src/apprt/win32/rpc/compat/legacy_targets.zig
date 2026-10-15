//! Shared target resolution for the legacy wmux-v1 JSON commands: the
//! IPC target window, workspace/tab/container addressing by index, stable
//! surface-id lookup, and the shared error set. Every
//! `features/<id>/legacy.zig` handler resolves its target through these.
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8). W1-1
//! replaces this with `rpc/router.zig` (ADR-2.6) for v2 methods; the legacy
//! adapters keep these semantics until wmux 2.0 (ADR-3.7).

const std = @import("std");

const App = @import("../../App.zig");
const Pane = @import("../../Pane.zig");
const PaneContainer = @import("../../PaneContainer.zig");
const Surface = @import("../../Surface.zig");
const Window = @import("../../Window.zig");
const w32 = @import("../../platform/win32.zig");
const ipc = @import("legacy_json.zig");

/// Read an optional u32 index field ("index"/"workspace"/"tab").
const ipcArgU32 = ipc.argU32;

/// Request-level failures surfaced to the client as the error response
/// message (via @errorName). Window/pane operations can also fail with
/// allocation/Win32/SplitTree errors, so the ipc* handlers return
/// anyerror and the dispatcher names whatever propagates.
pub const IpcError = error{
    NoWindow,
    MissingUrl,
    MissingScript,
    MissingRef,
    MissingText,
    UnknownId,
    UrlTooLong,
    MissingIndex,
    UnknownWorkspace,
    UnknownTab,
    NotATerminal,
    QuickTerminal,
    MissingAction,
    BadAction,
    // Orchestration verbs.
    UnknownPane,
    UnknownSurface,
    MissingDirection,
    BadDirection,
    MissingAgent,
    MissingSession,
    NoSession,
    NoResumeRecipe,
    BadProgress,
    CoreNotReady,
};

/// Resolve the IPC target window: the foreground Ghostty window if one
/// is, else the first live window. Null only when no windows exist.
pub fn ipcTargetWindow(self: *App) ?*Window {
    const fg = w32.GetForegroundWindow();
    for (self.windows.items) |w| {
        if (!w.closing and w.hwnd == fg) return w;
    }
    for (self.windows.items) |w| {
        if (!w.closing) return w;
    }
    return null;
}

/// Resolve the workspace addressed by an optional "workspace" arg in the
/// target window, defaulting to the active workspace when absent. Returns
/// the window, the workspace pointer, and its index. UnknownWorkspace if
/// an explicit index is out of range; NoWindow if no window exists.
pub const IpcWorkspaceTarget = struct {
    window: *Window,
    ws: *Window.Workspace,
    ws_idx: usize,
};

pub fn ipcResolveWorkspace(self: *App, req: *ipc.Request) IpcError!IpcWorkspaceTarget {
    const window = ipcTargetWindow(self) orelse return IpcError.NoWindow;
    const ws_idx: usize = if (ipcArgU32(req, "workspace")) |w| w else window.active_workspace;
    if (ws_idx >= window.workspace_count) return IpcError.UnknownWorkspace;
    return .{
        .window = window,
        .ws = &window.workspaces[ws_idx],
        .ws_idx = ws_idx,
    };
}

/// Append a JSON string for a UTF-16 slice (a workspace name or tab
/// title), escaping via std.json so embedded quotes/control chars are
/// safe. Lossy on invalid UTF-16 (each bad unit becomes U+FFFD), which
/// only affects display text, never protocol framing.
pub fn ipcWriteJsonUtf16(
    self: *App,
    w: *std.ArrayList(u8),
    utf16: []const u16,
) !void {
    const alloc = self.core_app.alloc;
    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, utf16) catch
        try alloc.dupe(u8, "");
    defer alloc.free(utf8);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try std.json.Stringify.value(utf8, .{}, &aw.writer);
    try w.appendSlice(alloc, aw.written());
}

/// A resolved (workspace, tab) target within the IPC target window. tab
/// defaults to the workspace's active tab when "tab" is absent, and is
/// range-validated. Workspace resolution reuses ipcResolveWorkspace.
pub const IpcTabTarget = struct {
    window: *Window,
    ws: *Window.Workspace,
    ws_idx: usize,
    container: *PaneContainer,
    tab_idx: usize,
};

pub fn ipcResolveTab(self: *App, req: *ipc.Request) IpcError!IpcTabTarget {
    const t = try ipcResolveWorkspace(self, req);
    const container = if (ipcArgU32(req, "pane")) |p|
        t.ws.containerAtIndex(p) orelse return IpcError.UnknownPane
    else
        t.ws.focusedContainerOrFirst() orelse return IpcError.UnknownTab;
    const tab_idx: usize = if (ipcArgU32(req, "tab")) |tab| tab else container.active_tab;
    if (tab_idx >= container.tab_count) return IpcError.UnknownTab;
    return .{ .window = t.window, .ws = t.ws, .ws_idx = t.ws_idx, .container = container, .tab_idx = tab_idx };
}

/// A pane located across every live window, with the coordinates that
/// address it. Returned by ipcFindSurfaceById.
pub const SurfaceLoc = struct {
    window: *Window,
    ws_idx: usize,
    container: *PaneContainer,
    tab_idx: usize,
    surface: *Surface,
};

/// Find a terminal surface by its stable core id (GHOSTTY_SURFACE_ID)
/// across all live windows. Only surfaces whose core is initialized have
/// a valid id; the id is read WITHOUT touching unready cores. Returns the
/// owning window + workspace/container/tab indices so callers can focus it.
pub fn ipcFindSurfaceById(self: *App, want: u64) ?SurfaceLoc {
    for (self.windows.items) |w| {
        if (w.closing) continue;
        for (w.workspaces[0..w.workspace_count], 0..) |*ws, wi| {
            var tree_it = ws.split_tree.iterator();
            while (tree_it.next()) |tree_entry| {
                const container = tree_entry.view;
                for (container.tabs[0..container.tab_count], 0..) |tab_pane, t| {
                    const surface = switch (tab_pane.content) {
                        .terminal => |s| s,
                        .browser => continue,
                    };
                    if (!surface.core_surface_initialized) continue;
                    if (surface.core_surface.id == want) {
                        return .{ .window = w, .ws_idx = wi, .container = container, .tab_idx = t, .surface = surface };
                    }
                }
            }
        }
    }
    return null;
}

/// The stable surface id of a terminal pane, or null if it is a browser
/// or its core is not yet initialized (no id assigned).
pub fn ipcSurfaceId(pane: *Pane) ?u64 {
    const surface = pane.surface() orelse return null;
    if (!surface.core_surface_initialized) return null;
    return surface.core_surface.id;
}
