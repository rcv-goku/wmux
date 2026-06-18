//! Persisted session layout for the Win32 runtime (tmux-resurrect style).
//!
//! Saves the entire workspace/PaneContainer/tab layout with working
//! directories to `%LOCALAPPDATA%\ghostty\session-state.json` so it can
//! be restored on restart.
//!
//! ## Data model (v2)
//!
//! The JSON hierarchy mirrors the runtime model:
//!
//!   SessionData
//!     └─ WorkspaceData[]
//!          ├─ name, working_dir, active_container
//!          └─ split_tree: SplitNodeData (recursive)
//!               ├─ leaf → PaneContainerData { tabs[], active_tab }
//!               └─ split → { direction, ratio, left, right }
//!
//! v1 files (tabs[] with split trees) are detected and migrated on load.

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const Pane = @import("Pane.zig");
const PaneContainer = @import("PaneContainer.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const w32 = @import("win32.zig");

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

// ── JSON model types (v2) ──────────────────────────────────────────

pub const PaneKind = enum { terminal, browser };

/// A serializable tab snapshot (v2: one pane per tab, no split tree).
pub const TabData = struct {
    title: ?[]const u8 = null,
    kind: PaneKind = .terminal,
    cwd: ?[]const u8 = null,
};

/// A serializable PaneContainer snapshot.
pub const PaneContainerData = struct {
    tabs: []TabData = &.{},
    active_tab: usize = 0,
};

pub const NodeType = enum { leaf, split };
pub const SplitDirection = enum { horizontal, vertical };

/// A serializable split-tree node. Leaves hold a PaneContainerData;
/// internal nodes hold direction + ratio + left/right children.
pub const SplitNodeData = struct {
    node_type: NodeType,
    // Leaf fields.
    container: ?PaneContainerData = null,
    // Split fields.
    direction: ?SplitDirection = null,
    ratio: ?f32 = null,
    left: ?*SplitNodeData = null,
    right: ?*SplitNodeData = null,
};

/// A serializable workspace snapshot (v2).
pub const WorkspaceData = struct {
    name: ?[]const u8 = null,
    split_tree: ?SplitNodeData = null,
    active_container: usize = 0,
    working_dir: ?[]const u8 = null,
};

/// The full session state.
pub const SessionData = struct {
    version: u32 = 2,
    workspaces: []WorkspaceData = &.{},
    active_workspace: usize = 0,
};

// ── Save ────────────────────────────────────────────────────────────

/// Build a PaneContainerData from a live PaneContainer.
fn containerDataFrom(a: Allocator, container: *PaneContainer) !PaneContainerData {
    const tab_count = container.tab_count;
    const tabs = try a.alloc(TabData, tab_count);

    for (0..tab_count) |ti| {
        var td: TabData = .{};

        const title_len = container.tab_title_lens[ti];
        if (title_len > 0) {
            const utf16 = container.tab_titles[ti][0..title_len];
            td.title = std.unicode.utf16LeToUtf8Alloc(a, utf16) catch null;
        }

        const pane = container.tabs[ti];
        switch (pane.content) {
            .terminal => |surface| {
                td.kind = .terminal;
                if (surface.core_surface_ready) {
                    td.cwd = surface.core_surface.pwd(a) catch null;
                }
            },
            .browser => {
                td.kind = .browser;
            },
        }

        tabs[ti] = td;
    }

    return .{
        .tabs = tabs,
        .active_tab = container.active_tab,
    };
}

/// Recursively serialize a SplitTree node into a SplitNodeData.
fn serializeNode(
    a: Allocator,
    tree: SplitTree(PaneContainer),
    handle: SplitTree(PaneContainer).Node.Handle,
) !SplitNodeData {
    switch (tree.nodes[handle.idx()]) {
        .leaf => |container| {
            return .{
                .node_type = .leaf,
                .container = try containerDataFrom(a, container),
            };
        },
        .split => |s| {
            const left = try a.create(SplitNodeData);
            left.* = try serializeNode(a, tree, s.left);
            const right = try a.create(SplitNodeData);
            right.* = try serializeNode(a, tree, s.right);
            return .{
                .node_type = .split,
                .direction = switch (s.layout) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                },
                .ratio = @floatCast(s.ratio),
                .left = left,
                .right = right,
            };
        },
    }
}

/// Find the index of the focused container within the tree's leaf
/// iteration order, for serializing `active_container`.
fn focusedContainerIndex(ws: *const Window.Workspace) usize {
    const focused = ws.focused_container orelse return 0;
    var it = ws.split_tree.iterator();
    var idx: usize = 0;
    while (it.next()) |entry| {
        if (entry.view.eql(focused)) return idx;
        idx += 1;
    }
    return 0;
}

/// Save the current session state from `window` to disk.
pub fn save(alloc: Allocator, window: *Window) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ws_count = window.workspace_count;
    const ws_data = try a.alloc(WorkspaceData, ws_count);

    for (0..ws_count) |wi| {
        const ws = &window.workspaces[wi];
        var wsd: WorkspaceData = .{
            .active_container = focusedContainerIndex(ws),
        };

        if (ws.name_len > 0) {
            const utf16 = ws.name[0..ws.name_len];
            wsd.name = std.unicode.utf16LeToUtf8Alloc(a, utf16) catch null;
        }

        wsd.working_dir = ws.working_dir;

        if (!ws.split_tree.isEmpty()) {
            wsd.split_tree = try serializeNode(a, ws.split_tree, .root);
        }

        ws_data[wi] = wsd;
    }

    const session: SessionData = .{
        .workspaces = ws_data,
        .active_workspace = window.active_workspace,
    };

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try std.json.Stringify.value(session, .{}, &aw.writer);
    const json = aw.written();

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
/// to match the saved layout.
///
/// Supports both v2 (split_tree of PaneContainers) and v1 (flat tabs[])
/// formats — v1 files are migrated to one PaneContainer per workspace.
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
    const version: usize = jsonUsize(root_obj.get("version")) orelse 1;

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

        if (jsonString(ws_obj.get("name"))) |name| {
            window.setWorkspaceName(target_ws_idx, name);
        }

        if (jsonString(ws_obj.get("working_dir"))) |wd| {
            window.workspaces[target_ws_idx].setWorkingDir(alloc, wd) catch {};
        }

        if (version >= 2) {
            restoreV2Workspace(alloc, window, target_ws_idx, ws_obj);
        } else {
            restoreV1Workspace(alloc, window, target_ws_idx, ws_obj);
        }
    }

    if (active_ws < window.workspace_count) {
        window.selectWorkspace(active_ws);
    }

    window.invalidateSidebar();
}

/// Restore a v2 workspace: parse the split_tree and recursively rebuild
/// the PaneContainer hierarchy with tabs. Builds the SplitTree bottom-up
/// to faithfully reconstruct the exact tree topology that was saved.
fn restoreV2Workspace(
    alloc: Allocator,
    window: *Window,
    ws_idx: usize,
    ws_obj: std.json.ObjectMap,
) void {
    const tree_val = ws_obj.get("split_tree") orelse return;
    const tree_obj = switch (tree_val) {
        .object => |o| o,
        else => return,
    };

    const ws = &window.workspaces[ws_idx];
    const is_bg = ws_idx != window.active_workspace;

    // Recursively build the SplitTree from the serialized JSON.
    const tree = buildSplitTree(alloc, window, ws, is_bg, tree_obj) orelse return;

    // Replace any existing tree on the workspace.
    if (!ws.split_tree.isEmpty()) {
        ws.split_tree.deinit();
    }
    ws.split_tree = tree;

    // Set the focused container.
    const active_container = jsonUsize(ws_obj.get("active_container")) orelse 0;
    if (ws.containerAtIndex(active_container)) |container| {
        ws.focused_container = container;
    } else {
        var it = ws.split_tree.iterator();
        if (it.next()) |entry| {
            ws.focused_container = entry.view;
        }
    }
}

/// Recursively build a SplitTree from a JSON node. For leaf nodes,
/// creates a PaneContainer with tabs and returns a single-leaf tree.
/// For split nodes, recursively builds left and right subtrees and
/// combines them via SplitTree.split to preserve the exact topology.
fn buildSplitTree(
    alloc: Allocator,
    window: *Window,
    ws: *Window.Workspace,
    is_bg: bool,
    node_obj: std.json.ObjectMap,
) ?SplitTree(PaneContainer) {
    const node_type = jsonString(node_obj.get("node_type")) orelse return null;

    if (std.mem.eql(u8, node_type, "leaf")) {
        return buildLeafTree(alloc, window, ws, is_bg, node_obj);
    } else if (std.mem.eql(u8, node_type, "split")) {
        return buildSplitNode(alloc, window, ws, is_bg, node_obj);
    }
    return null;
}

/// Build a single-leaf SplitTree from a leaf JSON node.
fn buildLeafTree(
    alloc: Allocator,
    window: *Window,
    ws: *Window.Workspace,
    is_bg: bool,
    node_obj: std.json.ObjectMap,
) ?SplitTree(PaneContainer) {
    const container_val = node_obj.get("container") orelse return null;
    const container_obj = switch (container_val) {
        .object => |o| o,
        else => return null,
    };

    const tabs_val = container_obj.get("tabs") orelse return null;
    const tabs_arr = switch (tabs_val) {
        .array => |arr| arr,
        else => return null,
    };
    if (tabs_arr.items.len == 0) return null;

    // Create a PaneContainer and populate its tabs.
    const container = PaneContainer.create(alloc) catch return null;

    for (tabs_arr.items, 0..) |tab_val, ti| {
        if (ti >= 64) break; // MAX_TABS
        const tab_obj = switch (tab_val) {
            .object => |o| o,
            else => continue,
        };

        const title = jsonString(tab_obj.get("title"));

        const surface = alloc.create(Surface) catch continue;
        surface.init(window.app, window, .tab, null, ws.working_dir) catch {
            surface.deinit();
            alloc.destroy(surface);
            continue;
        };

        const pane = Pane.create(alloc, surface) catch {
            surface.deinit();
            alloc.destroy(surface);
            continue;
        };
        _ = pane.ref(alloc) catch {
            alloc.destroy(pane);
            surface.deinit();
            alloc.destroy(surface);
            continue;
        };

        if (is_bg) {
            if (surface.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        }

        const pos = container.tab_count;
        container.tabs[pos] = pane;
        container.tab_status[pos] = .normal;
        container.tab_status_text_len[pos] = 0;
        container.tab_progress[pos] = null;
        container.tab_log[pos].clear();
        container.tab_count += 1;

        const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
        @memcpy(container.tab_titles[pos][0..default_title.len], default_title);
        container.tab_title_lens[pos] = @intCast(default_title.len);
        if (title) |t| {
            const wlen = std.unicode.utf8ToUtf16Le(
                &container.tab_titles[pos],
                t[0..@min(t.len, 255)],
            ) catch 0;
            if (wlen > 0) container.tab_title_lens[pos] = @intCast(@min(wlen, 255));
        }
    }

    if (container.tab_count == 0) {
        alloc.destroy(container);
        return null;
    }

    // Restore the active tab within this container.
    const active_tab = jsonUsize(container_obj.get("active_tab")) orelse 0;
    container.active_tab = @min(active_tab, container.tab_count - 1);

    return SplitTree(PaneContainer).init(alloc, container) catch null;
}

/// Build a SplitTree from a split JSON node by recursively building
/// left and right subtrees and combining them.
fn buildSplitNode(
    alloc: Allocator,
    window: *Window,
    ws: *Window.Workspace,
    is_bg: bool,
    node_obj: std.json.ObjectMap,
) ?SplitTree(PaneContainer) {
    const left_val = node_obj.get("left") orelse return null;
    const left_obj = switch (left_val) {
        .object => |o| o,
        else => return null,
    };
    const right_val = node_obj.get("right") orelse return null;
    const right_obj = switch (right_val) {
        .object => |o| o,
        else => return null,
    };

    var left_tree = buildSplitTree(alloc, window, ws, is_bg, left_obj) orelse return null;
    var right_tree = buildSplitTree(alloc, window, ws, is_bg, right_obj) orelse {
        left_tree.deinit();
        return null;
    };
    defer right_tree.deinit();

    const dir_str = jsonString(node_obj.get("direction")) orelse "horizontal";
    const direction: SplitTree(PaneContainer).Split.Direction = if (std.mem.eql(u8, dir_str, "vertical"))
        .down
    else
        .right;

    const ratio_val = jsonFloat(node_obj.get("ratio")) orelse 0.5;
    const ratio: f16 = @floatCast(ratio_val);

    const combined = left_tree.split(alloc, .root, direction, ratio, &right_tree) catch {
        left_tree.deinit();
        return null;
    };

    left_tree.deinit();
    return combined;
}

/// Restore a v1 workspace: flat tabs array, one PaneContainer for all.
fn restoreV1Workspace(
    alloc: Allocator,
    window: *Window,
    ws_idx: usize,
    ws_obj: std.json.ObjectMap,
) void {
    _ = alloc;
    const tabs_arr = switch (ws_obj.get("tabs") orelse return) {
        .array => |arr| arr,
        else => return,
    };

    if (tabs_arr.items.len == 0) return;

    log.warn("session restore: migrating v1 session format to v2", .{});

    for (tabs_arr.items) |tab_val| {
        const tab_obj = switch (tab_val) {
            .object => |o| o,
            else => continue,
        };

        const title = jsonString(tab_obj.get("title"));

        if (ws_idx == window.active_workspace) {
            _ = window.addTabWithCommand(null, title) catch |err| {
                log.warn("session restore: failed to create tab: {}", .{err});
                continue;
            };
        } else {
            _ = window.addTabBackground(ws_idx, null, title) catch |err| {
                log.warn("session restore: failed to create bg tab: {}", .{err});
                continue;
            };
        }
    }
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

/// Extract a usize from a `std.json.Value` (integer only).
fn jsonUsize(v: ?std.json.Value) ?usize {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

/// Extract an f64 from a `std.json.Value` (float or integer).
fn jsonFloat(v: ?std.json.Value) ?f64 {
    const val = v orelse return null;
    return switch (val) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}
