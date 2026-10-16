//! Workspace operations (ARCHITECTURE.md ADR-1.8 W0-A2 step 2): name and
//! description. Moved out of Window.zig in W0-A2.

const std = @import("std");

const Window = @import("../../ui/Window.zig");

/// Set workspace `idx`'s sidebar name from a UTF-8 string, mirroring the
/// inline-rename write path (capped at Workspace.NAME_MAX_UNITS bytes on a
/// code-point boundary; invalid UTF-8 leaves the name unchanged). Used by
/// the agent IPC `workspace-new --name` and session restore. No-op for an
/// out-of-range index.
pub fn setWorkspaceName(self: *Window, idx: usize, name: []const u8) void {
    if (idx >= self.workspaces.items.len) return;
    const wsp = self.workspaces.items[idx];
    wsp.setNameUtf8(self.app.core_app.alloc, name) catch return;
    self.invalidateSidebar();
}

/// Set workspace `idx`'s sidebar description from a UTF-8 string,
/// mirroring setWorkspaceName (capped at Workspace.DESCRIPTION_MAX_UNITS
/// bytes; invalid UTF-8 leaves the description unchanged; empty clears
/// it). Used by the IPC `workspace-set-description` command. No-op for an
/// out-of-range index.
pub fn setWorkspaceDescription(self: *Window, idx: usize, text: []const u8) void {
    if (idx >= self.workspaces.items.len) return;
    const wsp = self.workspaces.items[idx];
    wsp.setDescriptionUtf8(self.app.core_app.alloc, text) catch return;
    self.invalidateSidebar();
}
