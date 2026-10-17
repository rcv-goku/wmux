//! The legacy (v2) session file for the Win32 runtime: the read-only v2
//! reader plus the explicit legacy `session-save` writer.
//!
//! Session v3 (W1-7a, ARCHITECTURE.md ADR-9) owns persistence now:
//! automatic saves (autosave, full saves, WM_CLOSE) write
//! `STATE\session\session.json` and never this file. What stays here:
//!
//! - `save`: the explicit legacy `session-save` command (and the
//!   `save_session` keybind action) still write
//!   `%LOCALAPPDATA%\ghostty\session-state.json` (or
//!   `<WMUX_STATE_DIR>\session-state.json`) in the v2 shape, in test mode
//!   too (owner decision 2026-10-17 b), until W1-7b flips the command to
//!   `wmux.session.save`;
//! - `restore`: the explicit legacy `session-restore` reads that file
//!   through logic/migrate_v2.zig (the same v2/v1 reader the launch
//!   migration uses) and applies it with the v3 restorer into window 0,
//!   so every workspace keeps its splits and none is lost (the W0-ST
//!   multi-workspace bug).
//!
//! ## Data model (v2)
//!
//!   SessionData
//!     └─ WorkspaceData[]
//!          ├─ name, working_dir, active_container
//!          └─ split_tree: SplitNodeData (recursive)
//!               ├─ leaf → PaneContainerData { tabs[], active_tab }
//!               └─ split → { direction, ratio, left, right }

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("../../App.zig");
const Pane = @import("../../model/Pane.zig");
const Window = @import("../../ui/Window.zig");
const SplitTree = @import("../../../../datastruct/split_tree.zig").SplitTree;
const app_paths = @import("../../app/paths.zig");
const RuntimeEnv = @import("../../app/runtime_env.zig").RuntimeEnv;

const log = std.log.scoped(.session);

/// Build the absolute path to the session-state file:
/// %LOCALAPPDATA%\ghostty\session-state.json, or
/// <WMUX_STATE_DIR>\session-state.json (app/paths.zig).
fn sessionStatePath(alloc: Allocator, env: *const RuntimeEnv) ![]u8 {
    return app_paths.sessionStatePath(alloc, env);
}

// ── JSON model types (v2) ──────────────────────────────────────────

pub const PaneKind = enum { terminal, browser };

/// A serializable tab snapshot (v2: one pane per tab, no split tree).
pub const TabData = struct {
    title: ?[]const u8 = null,
    kind: PaneKind = .terminal,
    cwd: ?[]const u8 = null,
};

/// A serializable Pane snapshot.
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

/// A title or name as it is written to the session file: null when empty
/// or not valid UTF-8 (a rename holding an unpaired surrogate), as when
/// the former UTF-16 slots failed to transcode.
fn sessionText(text: ?[]const u8) ?[]const u8 {
    const t = text orelse return null;
    if (t.len == 0 or !std.unicode.utf8ValidateSlice(t)) return null;
    return t;
}

/// Build a PaneContainerData from a live Pane.
fn containerDataFrom(a: Allocator, container: *const Pane) !PaneContainerData {
    const tabs = try a.alloc(TabData, container.tabCount());

    for (container.tabs.items, 0..) |tab, ti| {
        var td: TabData = .{};

        td.title = sessionText(tab.title.text());

        switch (tab.content) {
            .terminal => |surface| {
                td.kind = .terminal;
                if (surface.core_surface_ready) {
                    td.cwd = surface.core_surface.pwd(a) catch null;
                }
            },
            .browser => {
                td.kind = .browser;
            },
            // The v2 file has no web panels (session v3, W1-7, does).
            .web, .placeholder => {},
        }

        tabs[ti] = td;
    }

    return .{
        .tabs = tabs,
        .active_tab = container.selected,
    };
}

/// Recursively serialize a SplitTree node into a SplitNodeData.
fn serializeNode(
    a: Allocator,
    tree: SplitTree(Pane),
    handle: SplitTree(Pane).Node.Handle,
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
    const focused = ws.focused_pane orelse return 0;
    var it = ws.tree.iterator();
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

    const ws_data = try a.alloc(WorkspaceData, window.workspaces.items.len);

    for (window.workspaces.items, 0..) |ws, wi| {
        var wsd: WorkspaceData = .{
            .active_container = focusedContainerIndex(ws),
        };

        wsd.name = sessionText(ws.name());

        wsd.working_dir = ws.cwd;

        if (!ws.tree.isEmpty()) {
            wsd.split_tree = try serializeNode(a, ws.tree, .root);
        }

        ws_data[wi] = wsd;
    }

    const session: SessionData = .{
        .workspaces = ws_data,
        .active_workspace = window.activeIndex(),
    };

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try std.json.Stringify.value(session, .{}, &aw.writer);
    const json = aw.written();

    const path = try sessionStatePath(a, &window.app.runtime_env);
    if (std.fs.path.dirname(path)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(json);
}

// ── Restore ─────────────────────────────────────────────────────────

/// The explicit legacy `session-restore`: read the v2 (or v1) file and
/// restore it into window 0 with the v3 restorer (replacing window 0's
/// workspaces; terminals spawn in their saved directories). A missing or
/// unreadable file is not an error (the legacy reply stays `ok`).
pub fn restore(alloc: Allocator, app: *App) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const path = sessionStatePath(a, &app.runtime_env) catch return;
    const contents = std.fs.cwd().readFileAlloc(a, path, 4 * 1024 * 1024) catch return;
    const session = @import("migrate.zig").readLegacy(a, contents) catch |err| {
        log.warn("legacy session-restore: unreadable session file err={}", .{err});
        return;
    };
    if (app.windows.items.len == 0) return;
    try @import("restore.zig").apply(app, &session, .{ .stagger = false, .placement = false, .all_windows = false, .launch = false });
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

/// A one-leaf SplitTree(Pane) built without SplitTree.init/deinit (W0-ST): those reference
/// Pane.unref -> Tab.unref -> Surface.deinit -> the renderer, whose apprt switch names
/// apprt.gtk, which pulls the GTK apprt's tests (and its missing adw/gtk modules) into the
/// unfiltered win32 test build. Free it with freeTestLeafTree.
fn testLeafTree(alloc: Allocator, pane: *Pane) Allocator.Error!SplitTree(Pane) {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const nodes = try arena.allocator().alloc(SplitTree(Pane).Node, 1);
    nodes[0] = .{ .leaf = pane };
    pane.ref_count += 1;
    return .{ .arena = arena, .nodes = nodes, .zoomed = null };
}

fn freeTestLeafTree(alloc: Allocator, tree: SplitTree(Pane), pane: *Pane) void {
    var t = tree;
    t.arena.deinit();
    alloc.destroy(pane);
}
test "SessionState: PaneContainerData defaults" {
    const d: PaneContainerData = .{};
    try testing.expectEqual(@as(usize, 0), d.tabs.len);
    try testing.expectEqual(@as(usize, 0), d.active_tab);
}

test "SessionState: TabData defaults to terminal with no title or cwd" {
    const t: TabData = .{};
    try testing.expect(t.title == null);
    try testing.expect(t.cwd == null);
    try testing.expect(t.kind == .terminal);
}

test "SessionState: SplitNodeData leaf vs split discriminant" {
    const leaf: SplitNodeData = .{ .node_type = .leaf };
    try testing.expect(leaf.node_type == .leaf);
    try testing.expect(leaf.container == null);
    try testing.expect(leaf.left == null);
    try testing.expect(leaf.right == null);

    const split: SplitNodeData = .{ .node_type = .split, .direction = .horizontal, .ratio = 0.5 };
    try testing.expect(split.node_type == .split);
    try testing.expect(split.direction.? == .horizontal);
}

test "SessionState: WorkspaceData defaults" {
    const w: WorkspaceData = .{};
    try testing.expect(w.name == null);
    try testing.expect(w.split_tree == null);
    try testing.expectEqual(@as(usize, 0), w.active_container);
    try testing.expect(w.working_dir == null);
}

test "SessionState: SessionData defaults to version 2" {
    const s: SessionData = .{};
    try testing.expectEqual(@as(u32, 2), s.version);
    try testing.expectEqual(@as(usize, 0), s.workspaces.len);
    try testing.expectEqual(@as(usize, 0), s.active_workspace);
}

test "SessionState: focusedContainerIndex returns 0 for empty workspace" {
    const ws: Window.Workspace = .{ .window = undefined };
    try testing.expectEqual(@as(usize, 0), focusedContainerIndex(&ws));
}

test "SessionState: focusedContainerIndex returns 0 when focused is null" {
    var ws: Window.Workspace = .{ .window = undefined };
    ws.focused_pane = null;
    try testing.expectEqual(@as(usize, 0), focusedContainerIndex(&ws));
}

test "SessionState: focusedContainerIndex finds correct leaf in single-node tree" {
    const alloc = testing.allocator;
    const pc = try Pane.create(alloc);
    const tree = testLeafTree(alloc, pc) catch |err| {
        alloc.destroy(pc);
        return err;
    };
    defer freeTestLeafTree(alloc, tree, pc);
    var ws: Window.Workspace = .{ .window = undefined };
    ws.tree = tree;
    ws.focused_pane = pc;
    try testing.expectEqual(@as(usize, 0), focusedContainerIndex(&ws));
}

test "SessionState: containerDataFrom produces correct tab count and active index" {
    const alloc = testing.allocator;
    var pc: Pane = .{};
    pc.selected = 0;

    const data = try containerDataFrom(alloc, &pc);
    defer alloc.free(data.tabs);
    try testing.expectEqual(@as(usize, 0), data.tabs.len);
    try testing.expectEqual(@as(usize, 0), data.active_tab);
}

test "SessionState: serializeNode round-trips a single-leaf tree" {
    const alloc = testing.allocator;
    const pc = try Pane.create(alloc);
    const tree = testLeafTree(alloc, pc) catch |err| {
        alloc.destroy(pc);
        return err;
    };
    defer freeTestLeafTree(alloc, tree, pc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const node = try serializeNode(a, tree, .root);
    try testing.expect(node.node_type == .leaf);
    try testing.expect(node.container != null);
    try testing.expectEqual(@as(usize, 0), node.container.?.tabs.len);
    try testing.expect(node.left == null);
    try testing.expect(node.right == null);
}
