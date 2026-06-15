//! Persisted session layout for the Win32 runtime (tmux-resurrect style).
//!
//! Saves the entire workspace/tab/split layout with working directories
//! to `%LOCALAPPDATA%\ghostty\session-state.json` so it can be restored
//! on restart. Modeled after `WindowState.zig` for file I/O patterns.
//!
//! ## Limitations (v1)
//!
//! Restore recreates one tab per saved tab using the first pane's working
//! directory. Complex split trees are NOT reconstructed — each saved tab
//! becomes a single-pane tab. This matches the pragmatic approach of
//! tmux-resurrect.

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const Pane = @import("Pane.zig");
const Window = @import("Window.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;

const log = std.log.scoped(.win32);

/// Name of the persisted session-state file, under %LOCALAPPDATA%\ghostty.
const SESSION_STATE_FILE = "session-state.json";

/// Build the absolute path to the session-state file. Mirrors the
/// `window-state` convention used elsewhere in this runtime.
fn sessionStatePath(alloc: Allocator) ![]u8 {
    const dir = try std.process.getEnvVarOwned(alloc, "LOCALAPPDATA");
    defer alloc.free(dir);
    return std.fs.path.join(alloc, &.{ dir, "ghostty", SESSION_STATE_FILE });
}

// ── JSON model types ────────────────────────────────────────────────

/// A serializable pane snapshot.
pub const PaneData = struct {
    kind: PaneKind = .terminal,
    cwd: ?[]const u8 = null,
};

pub const PaneKind = enum { terminal, browser };

/// A serializable split-tree node.
pub const SplitNodeData = struct {
    node_type: NodeType,
    // Leaf fields.
    pane: ?PaneData = null,
    // Split fields.
    direction: ?SplitDirection = null,
    ratio: ?f32 = null,
    left: ?*SplitNodeData = null,
    right: ?*SplitNodeData = null,
};

pub const NodeType = enum { leaf, split };
pub const SplitDirection = enum { horizontal, vertical };

/// A serializable tab snapshot.
pub const TabData = struct {
    title: ?[]const u8 = null,
    tree: ?SplitNodeData = null,
};

/// A serializable workspace snapshot.
pub const WorkspaceData = struct {
    name: ?[]const u8 = null,
    tabs: []TabData = &.{},
    active_tab: usize = 0,
    working_dir: ?[]const u8 = null,
};

/// The full session state.
pub const SessionData = struct {
    workspaces: []WorkspaceData = &.{},
    active_workspace: usize = 0,
};

// ── Save ────────────────────────────────────────────────────────────

/// Walk a SplitTree and produce a SplitNodeData tree. Allocates into
/// `alloc` (caller-owned lifetime, typically an arena).
fn walkTree(alloc: Allocator, tree: *const SplitTree(Pane)) !SplitNodeData {
    if (tree.nodes.len == 0) {
        // Empty tree: return a leaf with no pane data.
        return .{ .node_type = .leaf, .pane = .{} };
    }
    return walkNode(alloc, tree.nodes, .root);
}

fn walkNode(
    alloc: Allocator,
    nodes: []const SplitTree(Pane).Node,
    handle: SplitTree(Pane).Node.Handle,
) !SplitNodeData {
    const idx = handle.idx();
    if (idx >= nodes.len) return .{ .node_type = .leaf, .pane = .{} };

    return switch (nodes[idx]) {
        .leaf => |pane| blk: {
            var pd: PaneData = .{};
            switch (pane.content) {
                .terminal => |surface| {
                    pd.kind = .terminal;
                    // Grab the pwd from the terminal. The core surface's
                    // pwd() locks the renderer mutex and copies, so we
                    // need an allocator. We'll dupe into the provided alloc.
                    if (surface.core_surface_ready) {
                        pd.cwd = surface.core_surface.pwd(alloc) catch null;
                    }
                },
                .browser => {
                    pd.kind = .browser;
                },
            }
            break :blk .{ .node_type = .leaf, .pane = pd };
        },
        .split => |s| blk: {
            const left_node = try alloc.create(SplitNodeData);
            left_node.* = try walkNode(alloc, nodes, s.left);
            const right_node = try alloc.create(SplitNodeData);
            right_node.* = try walkNode(alloc, nodes, s.right);

            break :blk .{
                .node_type = .split,
                .direction = switch (s.layout) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                },
                .ratio = @floatCast(s.ratio),
                .left = left_node,
                .right = right_node,
            };
        },
    };
}

/// Save the current session state from `window` to disk.
pub fn save(alloc: Allocator, window: *Window) !void {
    // Use an arena for all intermediate allocations.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ws_count = window.workspace_count;
    const ws_data = try a.alloc(WorkspaceData, ws_count);

    for (0..ws_count) |wi| {
        const ws = &window.workspaces[wi];
        const tab_count = ws.tab_count;
        const tabs = try a.alloc(TabData, tab_count);

        for (0..tab_count) |ti| {
            var td: TabData = .{};

            // Tab title: convert from UTF-16 to UTF-8.
            const title_len = ws.tab_title_lens[ti];
            if (title_len > 0) {
                const utf16 = ws.tab_titles[ti][0..title_len];
                td.title = std.unicode.utf16LeToUtf8Alloc(a, utf16) catch null;
            }

            // Walk the split tree.
            td.tree = walkTree(a, &ws.tab_trees[ti]) catch null;
            tabs[ti] = td;
        }

        var wsd: WorkspaceData = .{
            .tabs = tabs,
            .active_tab = ws.active_tab,
        };

        // Workspace name: convert from UTF-16 to UTF-8.
        if (ws.name_len > 0) {
            const utf16 = ws.name[0..ws.name_len];
            wsd.name = std.unicode.utf16LeToUtf8Alloc(a, utf16) catch null;
        }

        // Workspace working_dir (already UTF-8).
        wsd.working_dir = ws.working_dir;

        ws_data[wi] = wsd;
    }

    const session: SessionData = .{
        .workspaces = ws_data,
        .active_workspace = window.active_workspace,
    };

    // Serialize to JSON via std.json.Stringify into an allocating writer.
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try std.json.Stringify.value(session, .{}, &aw.writer);
    const json = aw.written();

    // Write to disk.
    const path = try sessionStatePath(a);
    if (std.fs.path.dirname(path)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(json);
}

// ── Restore ─────────────────────────────────────────────────────────

/// Restore a session from disk into the app. Creates workspaces and tabs
/// to match the saved layout. This should be called during startup or
/// via IPC.
///
/// Parses the JSON using `std.json.Value` (dynamic tree) rather than
/// typed deserialization, which avoids issues with recursive pointer
/// types (`?*SplitNodeData`) and keeps the restore side simple.
pub fn restore(alloc: Allocator, app: *App) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const path = sessionStatePath(a) catch return;
    const file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();

    const max_size = 4 * 1024 * 1024;
    const contents = file.readToEndAlloc(a, max_size) catch return;

    const parsed = std.json.parseFromSlice(std.json.Value, a, contents, .{}) catch return;
    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };

    const workspaces_val = root_obj.get("workspaces") orelse return;
    const workspaces_arr = switch (workspaces_val) {
        .array => |arr| arr,
        else => return,
    };
    const active_ws: usize = jsonUsize(root_obj.get("active_workspace")) orelse 0;

    // We need a window to populate.
    if (app.windows.items.len == 0) return;
    const window = app.windows.items[0];

    for (workspaces_arr.items, 0..) |ws_val, ws_idx| {
        const ws_obj = switch (ws_val) {
            .object => |o| o,
            else => continue,
        };

        if (ws_idx > 0) {
            if (window.workspace_count >= window.workspaces.len) break;
            window.workspaces[window.workspace_count] = .{};
            window.workspace_count += 1;
        }

        const target_ws_idx: usize = if (ws_idx == 0) 0 else window.workspace_count - 1;

        // Set workspace name.
        if (jsonString(ws_obj.get("name"))) |name| {
            window.setWorkspaceName(target_ws_idx, name);
        }

        // Set workspace working_dir.
        if (jsonString(ws_obj.get("working_dir"))) |wd| {
            window.workspaces[target_ws_idx].setWorkingDir(alloc, wd) catch {};
        }

        // Create tabs.
        const tabs_arr = switch (ws_obj.get("tabs") orelse continue) {
            .array => |arr| arr,
            else => continue,
        };

        for (tabs_arr.items) |tab_val| {
            const tab_obj = switch (tab_val) {
                .object => |o| o,
                else => continue,
            };

            const title = jsonString(tab_obj.get("title"));

            // Create a tab in the target workspace.
            if (target_ws_idx == window.active_workspace) {
                _ = window.addTabWithCommand(null, title) catch |err| {
                    log.warn("session restore: failed to create tab: {}", .{err});
                    continue;
                };
            } else {
                _ = window.addTabBackground(target_ws_idx, null, title) catch |err| {
                    log.warn("session restore: failed to create background tab: {}", .{err});
                    continue;
                };
            }
        }
    }

    // Switch to the saved active workspace.
    if (active_ws < window.workspace_count) {
        window.selectWorkspace(active_ws);
    }

    window.invalidateSidebar();
}

// ── JSON helpers ────────────────────────────────────────────────────

/// Extract a string from a `std.json.Value`, returning null for non-string values.
fn jsonString(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Extract a usize from a `std.json.Value` integer, returning null for non-integer values.
fn jsonUsize(v: ?std.json.Value) ?usize {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}
