//! Workspace operations (ARCHITECTURE.md ADR-1.8 W0-A2 step 2): name and
//! description. Moved out of Window.zig in W0-A2.

const std = @import("std");

const Window = @import("../../ui/Window.zig");

/// Set workspace `idx`'s sidebar name from a UTF-8 string, mirroring the
/// inline-rename write path (truncated to the name buffer; invalid UTF-8
/// leaves the name unchanged). Used by the agent IPC `workspace-new
/// --name`. No-op for an out-of-range index.
pub fn setWorkspaceName(self: *Window, idx: usize, name: []const u8) void {
    if (idx >= self.workspace_count) return;
    const wsp = &self.workspaces[idx];
    const nlen = std.unicode.utf8ToUtf16Le(
        &wsp.name,
        name[0..@min(name.len, wsp.name.len)],
    ) catch return;
    wsp.name_len = @intCast(@min(nlen, wsp.name.len));
    self.invalidateSidebar();
}

/// Set workspace `idx`'s sidebar description from a UTF-8 string,
/// mirroring setWorkspaceName (truncated to the description buffer;
/// invalid UTF-8 leaves the description unchanged). Used by the IPC
/// `workspace-set-description` command. No-op for an out-of-range index.
pub fn setWorkspaceDescription(self: *Window, idx: usize, text: []const u8) void {
    if (idx >= self.workspace_count) return;
    const wsp = &self.workspaces[idx];
    const dlen = std.unicode.utf8ToUtf16Le(
        &wsp.description,
        text[0..@min(text.len, wsp.description.len)],
    ) catch return;
    wsp.description_len = @intCast(@min(dlen, wsp.description.len));
    self.invalidateSidebar();
}
