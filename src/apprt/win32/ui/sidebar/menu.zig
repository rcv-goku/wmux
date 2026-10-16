//! The sidebar's workspace row menu items (ARCHITECTURE.md ADR-1.6, site
//! `workspace_row`): rename, edit the description, close, new workspace.
//! The target workspace is captured by pointer when the menu opens
//! (ui/menus.zig Context) and its row index is looked up again after the
//! modal loop, so a reorder or a close meanwhile cannot redirect the
//! command to another row.

const menus = @import("../menus.zig");
const ops_window = @import("../../model/ops/window.zig");
const rename_ui = @import("../rename.zig");

const Context = menus.Context;

pub const menu_items = [_]menus.MenuItem{
    .{ .site = .workspace_row, .group = 0, .order = 0, .title = "Rename Workspace", .callback = rename },
    .{ .site = .workspace_row, .group = 0, .order = 1, .title = "Edit Description", .callback = editDescription },
    .{ .site = .workspace_row, .group = 0, .order = 2, .title = "Close Workspace", .callback = close },
    .{ .site = .workspace_row, .group = 1, .order = 0, .title = "New Workspace", .callback = newWorkspace },
};

/// The row index of the captured workspace (resolve() checked it is
/// still one of the window's).
fn rowIndex(ctx: *const Context) ?usize {
    const ws = ctx.workspace orelse return null;
    const idx = ctx.window.workspaceIndex(ws);
    if (idx >= ctx.window.workspaces.items.len) return null;
    return idx;
}

fn rename(ctx: *Context, arg: usize) void {
    _ = arg;
    rename_ui.renameWorkspace(ctx.window, rowIndex(ctx) orelse return);
}

fn editDescription(ctx: *Context, arg: usize) void {
    _ = arg;
    rename_ui.editWorkspaceDescription(ctx.window, rowIndex(ctx) orelse return);
}

fn close(ctx: *Context, arg: usize) void {
    _ = arg;
    ops_window.closeWorkspace(ctx.window, rowIndex(ctx) orelse return);
}

fn newWorkspace(ctx: *Context, arg: usize) void {
    _ = arg;
    ops_window.newWorkspace(ctx.window);
}
