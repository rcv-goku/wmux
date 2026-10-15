//! Scrollback snapshot save/restore helpers (`%LOCALAPPDATA%\ghostty\
//! scrollback\<surface_id>.txt`). Currently unreferenced (no caller saves
//! or restores scrollback); kept compiling until W1-7 replaces them with
//! terminal-side replay (ARCHITECTURE.md ADR-9.5).
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8).

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("../../App.zig");
const Surface = @import("../../Surface.zig");

/// Capture the scrollback + visible screen of every terminal pane and save
/// each to `%LOCALAPPDATA%\ghostty\scrollback\<surface_id>.txt`. Called
/// during session save so that session restore can repopulate the panes.
/// Best-effort: errors on individual panes are swallowed.
pub fn saveAllScrollback(self: *App) void {
    const alloc = self.core_app.alloc;
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return;
    defer alloc.free(dir);
    const scrollback_dir = std.fs.path.join(alloc, &.{ dir, "ghostty", "scrollback" }) catch return;
    defer alloc.free(scrollback_dir);

    std.fs.cwd().makePath(scrollback_dir) catch return;

    for (self.windows.items) |w| {
        if (w.closing) continue;
        for (w.workspaces[0..w.workspace_count]) |*ws| {
            var tree_it = ws.split_tree.iterator();
            while (tree_it.next()) |tree_entry| {
                const ctr = tree_entry.view;
                for (ctr.tabs[0..ctr.tab_count]) |tab_pane| {
                    const surface = switch (tab_pane.content) {
                        .terminal => |s| s,
                        .browser => continue,
                    };
                    if (!surface.core_surface_ready) continue;
                    saveOnePaneScrollback(self, alloc, scrollback_dir, surface) catch continue;
                }
            }
        }
    }
}

/// Save one pane's screen (scrollback + visible) to a file.
fn saveOnePaneScrollback(
    self: *App,
    alloc: Allocator,
    scrollback_dir: []const u8,
    surface: *Surface,
) !void {
    _ = self;
    const cs = &surface.core_surface;
    const sid = cs.id;

    // Dump the full screen (scrollback + visible) under the renderer mutex.
    const dump: []const u8 = dump: {
        cs.renderer_state.mutex.lock();
        defer cs.renderer_state.mutex.unlock();
        const screen = cs.io.terminal.screens.active;
        break :dump try screen.dumpStringAlloc(alloc, .{ .screen = .{ .x = 0, .y = 0 } });
    };
    defer alloc.free(dump);

    // Build filename: <scrollback_dir>/<surface_id>.txt
    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{d}.txt", .{sid}) catch return;
    const path = try std.fs.path.join(alloc, &.{ scrollback_dir, name });
    defer alloc.free(path);

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(dump);
}

/// Restore saved scrollback into a pane by writing the text to the
/// terminal's PTY as if it were program output, which naturally populates
/// the scrollback buffer. The file is
/// `%LOCALAPPDATA%\ghostty\scrollback\<surface_id>.txt`.
pub fn restoreScrollback(self: *App, surface: *Surface) void {
    const alloc = self.core_app.alloc;
    if (!surface.core_surface_ready) return;

    const sid = surface.core_surface.id;

    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return;
    defer alloc.free(dir);

    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{d}.txt", .{sid}) catch return;
    const path = std.fs.path.join(alloc, &.{ dir, "ghostty", "scrollback", name }) catch return;
    defer alloc.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();

    // Read the saved scrollback (cap at 1 MiB to avoid unbounded allocs).
    const max_restore: usize = 1024 * 1024;
    const content = file.readToEndAlloc(alloc, max_restore) catch return;
    defer alloc.free(content);

    if (content.len == 0) return;

    // Write the content to the terminal's PTY input as if it were program
    // output. This populates the scrollback naturally.
    const termio_mod = @import("../../../../termio.zig");
    const msg = termio_mod.Message.writeReq(alloc, content) catch return;
    surface.core_surface.io.queueMessage(msg, .unlocked);
}
