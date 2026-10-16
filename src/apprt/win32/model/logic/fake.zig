//! Fake model graphs for unit tests (ARCHITECTURE.md §12): real
//! Workspace/Pane/Tab objects without HWNDs (tabs hold `.placeholder`
//! content), a window's model part (the workspace list and the selected
//! workspace) and hand-built split trees. Model structs keep their HWND
//! and content pointers optional, so everything that only walks the model
//! (pane order, lookups, layout, aggregation, the explicit-target tab ops)
//! runs here.
//!
//! Test support, not std-only like the rest of logic/: it builds model
//! objects. It never calls Tab.unref, Pane.unref, SplitTree.deinit or
//! Workspace.destroy, which would pull the terminal teardown graph
//! (Surface.deinit, the renderer, ...) into the test build: trees are
//! built and freed by hand and teardown frees each object directly.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Pane = @import("../Pane.zig");
const SplitTree = @import("../../../../datastruct/split_tree.zig").SplitTree;
const Tab = @import("../Tab.zig");
const Workspace = @import("../Workspace.zig");
const layout = @import("../layout.zig");
const ops_surface = @import("../ops/surface.zig");

const Tree = SplitTree(Pane);

/// A fake window: the model part of ui/Window.zig.
pub const Graph = struct {
    gpa: Allocator,
    workspaces: std.ArrayList(*Workspace) = .empty,
    selected: ?*Workspace = null,

    pub fn init(gpa: Allocator) Graph {
        return .{ .gpa = gpa };
    }

    /// Free every workspace, pane, tab and tree of the graph.
    pub fn deinit(self: *Graph) void {
        for (self.workspaces.items) |ws| freeWorkspace(self.gpa, ws);
        self.workspaces.deinit(self.gpa);
        self.* = undefined;
    }

    /// Append a workspace whose panes hold `pane_tabs[i]` placeholder tabs
    /// each (pane i of `pane_tabs.len` in pane index order), arranged in a
    /// balanced tree of horizontal splits at ratio 0.5. The first workspace
    /// becomes the selected one; the first pane is focused.
    pub fn addWorkspace(self: *Graph, pane_tabs: []const usize) !*Workspace {
        const ws = try self.gpa.create(Workspace);
        ws.* = .{ .window = undefined };
        errdefer freeWorkspace(self.gpa, ws);
        if (pane_tabs.len > 0) {
            const panes = try self.gpa.alloc(*Pane, pane_tabs.len);
            defer self.gpa.free(panes);
            var made: usize = 0;
            errdefer for (panes[0..made]) |p| freePane(self.gpa, p);
            for (pane_tabs, 0..) |n, i| {
                panes[i] = try makePane(self.gpa, ws, n);
                made += 1;
            }
            ws.tree = try buildTree(self.gpa, panes);
            ws.focused_pane = panes[0];
        }
        try self.workspaces.append(self.gpa, ws);
        if (self.selected == null) self.selected = ws;
        return ws;
    }
};

/// A heap pane of `workspace` holding `n` placeholder tabs.
pub fn makePane(gpa: Allocator, workspace: ?*Workspace, n: usize) !*Pane {
    const pane = try Pane.create(gpa);
    pane.workspace = workspace;
    errdefer freePane(gpa, pane);
    for (0..n) |_| {
        const tab = try gpa.create(Tab);
        tab.* = .{ .content = .placeholder, .ref_count = 1 };
        ops_surface.insert(gpa, pane, tab, pane.tabCount()) catch |err| {
            gpa.destroy(tab);
            return err;
        };
    }
    return pane;
}

/// Free a pane built by makePane and its tabs (without unref).
pub fn freePane(gpa: Allocator, pane: *Pane) void {
    for (pane.tabs.items) |tab| {
        tab.title.deinit(gpa);
        if (tab.cwd) |cwd| gpa.free(cwd);
        gpa.destroy(tab);
    }
    pane.tabs.deinit(gpa);
    gpa.destroy(pane);
}

/// A balanced split tree over `panes` (pane index order = `panes`
/// order), built without touching the views' reference counts.
pub fn buildTree(gpa: Allocator, panes: []const *Pane) !Tree {
    if (panes.len == 0) return .empty;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    // n leaves need n - 1 splits.
    const nodes = try arena.allocator().alloc(Tree.Node, 2 * panes.len - 1);
    var next: usize = 0;
    _ = fill(nodes, &next, panes);
    std.debug.assert(next == nodes.len);
    return .{ .arena = arena, .nodes = nodes, .zoomed = null };
}

/// Write the subtree over `panes` in pre-order at `next.*` (the root of
/// the whole tree lands at index 0) and return its handle.
fn fill(nodes: []Tree.Node, next: *usize, panes: []const *Pane) Tree.Node.Handle {
    const handle: Tree.Node.Handle = @enumFromInt(next.*);
    next.* += 1;
    if (panes.len == 1) {
        nodes[handle.idx()] = .{ .leaf = panes[0] };
        return handle;
    }
    const half = panes.len / 2;
    const left = fill(nodes, next, panes[0..half]);
    const right = fill(nodes, next, panes[half..]);
    nodes[handle.idx()] = .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = left, .right = right } };
    return handle;
}

/// Free a tree built by buildTree (its arena only; the panes are freed
/// separately).
pub fn freeTree(tree: *Tree) void {
    if (tree.nodes.len > 0) tree.arena.deinit();
    tree.* = .empty;
}

/// Free a workspace of a fake graph: its panes and tabs, its tree and
/// its strings.
pub fn freeWorkspace(gpa: Allocator, ws: *Workspace) void {
    var it = ws.tree.iterator();
    while (it.next()) |entry| freePane(gpa, entry.view);
    freeTree(&ws.tree);
    ws.title.deinit(gpa);
    if (ws.description) |d| gpa.free(d);
    if (ws.cwd) |c| gpa.free(c);
    ws.env.deinit(gpa);
    gpa.destroy(ws);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: model: fake graph panes come in depth-first index order" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    const ws = try g.addWorkspace(&.{ 1, 2, 3, 4, 5 });
    try testing.expectEqual(@as(usize, 5), ws.paneCount());
    for (0..5) |i| {
        // Pane i was built with i + 1 tabs.
        try testing.expectEqual(i + 1, ws.paneAt(i).?.tabCount());
        try testing.expectEqual(ws, ws.paneAt(i).?.workspace.?);
    }
    try testing.expectEqual(@as(?*Pane, null), ws.paneAt(5));
    try testing.expectEqual(ws.paneAt(0).?, ws.focusedPaneOrFirst().?);
    try testing.expectEqual(ws, g.selected.?);
}

test "unit: model: every tab of a fake graph is located in its pane" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    _ = try g.addWorkspace(&.{ 2, 1 });
    const second = try g.addWorkspace(&.{ 3, 1, 2 });
    for (g.workspaces.items) |ws| {
        var it = ws.tree.iterator();
        while (it.next()) |entry| {
            const pane = entry.view;
            try testing.expectEqual(entry.handle, ws.paneHandle(pane).?);
            for (pane.tabs.items, 0..) |tab, i| {
                const loc = Workspace.locate(g.workspaces.items, tab).?;
                try testing.expectEqual(ws, loc.ws);
                try testing.expectEqual(pane, loc.pane);
                try testing.expectEqual(i, loc.index);
                try testing.expectEqual(pane, ws.findPaneOfTab(tab).?);
                try testing.expectEqual(pane, tab.pane.?);
            }
        }
    }
    // A tab of another graph is in none of these workspaces.
    var stranger: Tab = .{ .content = .placeholder };
    try testing.expectEqual(@as(?Workspace.Loc, null), Workspace.locate(g.workspaces.items, &stranger));
    try testing.expectEqual(@as(?*Pane, null), second.findPaneOfTab(&stranger));
    // Placeholder tabs have no surface, so no surface lookup matches.
    try testing.expectEqual(@as(?Workspace.Loc, null), Workspace.locateSurface(g.workspaces.items, @ptrFromInt(0x1000)));
}

test "unit: model: layout leaves are the panes in pane index order" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    const ws = try g.addWorkspace(&.{ 1, 1, 1, 1 });
    var lay = try layout.compute(Pane, testing.allocator, &ws.tree, .{ .left = 0, .top = 0, .right = 800, .bottom = 400 }, 1.0);
    defer lay.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), lay.leaves.len);
    try testing.expectEqual(@as(usize, 3), lay.dividers.len);
    var right_edge: i32 = 0;
    for (lay.leaves, 0..) |leaf, i| {
        try testing.expectEqual(ws.paneAt(i).?, leaf.view);
        // Horizontal splits only: the panes run left to right.
        try testing.expect(leaf.rect.left >= right_edge);
        right_edge = leaf.rect.right;
        try testing.expectEqual(leaf.rect, lay.leafOf(leaf.view).?.rect);
    }
}

test "unit: model: syncZoomed follows the zoomed leaf" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    const ws = try g.addWorkspace(&.{ 1, 1, 1 });
    ws.syncZoomed();
    try testing.expectEqual(@as(?*Pane, null), ws.zoomed_pane);
    const third = ws.paneAt(2).?;
    ws.tree.zoomed = ws.paneHandle(third).?;
    ws.syncZoomed();
    try testing.expectEqual(third, ws.zoomed_pane.?);
    // Zooming a split (not a leaf) zooms no pane.
    ws.tree.zoomed = .root;
    ws.syncZoomed();
    try testing.expectEqual(@as(?*Pane, null), ws.zoomed_pane);
}

test "unit: model: workspace status and attention aggregate over every pane" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    const ws = try g.addWorkspace(&.{ 2, 2, 2 });
    try testing.expectEqual(Tab.TabStatus.normal, ws.aggregateStatus());
    try testing.expect(!ws.hasAttention());
    ws.paneAt(2).?.tabs.items[1].legacy.status = .bell;
    try testing.expectEqual(Tab.TabStatus.bell, ws.aggregateStatus());
    ws.paneAt(0).?.tabs.items[0].legacy.status = .exited;
    try testing.expectEqual(Tab.TabStatus.exited, ws.aggregateStatus());
    ws.paneAt(1).?.tabs.items[1].legacy.attention = true;
    try testing.expect(ws.hasAttention());
}

test "unit: model: tab state follows the tab through insert, move and remove" {
    // Per-tab state lives on the tab now (the former parallel per-tab
    // arrays had to be shifted in lockstep), past the former 64-tab cap.
    const gpa = testing.allocator;
    const pane = try makePane(gpa, null, 70);
    defer freePane(gpa, pane);
    for (pane.tabs.items, 0..) |tab, i| {
        var buf: [8]u8 = undefined;
        tab.legacy.setStatusText(std.fmt.bufPrint(&buf, "t{d}", .{i}) catch unreachable);
    }
    const first = pane.tabs.items[0];
    const last = pane.tabs.items[69];

    // Move the first tab to the end and the last one to the front.
    try testing.expect(ops_surface.moveInPane(pane, 0, 69));
    try testing.expect(ops_surface.moveInPane(pane, 68, 0));
    try testing.expectEqual(last, pane.tabs.items[0]);
    try testing.expectEqual(first, pane.tabs.items[69]);
    try testing.expectEqualStrings("t69", pane.tabs.items[0].legacy.statusText());
    try testing.expectEqualStrings("t0", pane.tabs.items[69].legacy.statusText());

    // Remove one from the middle and re-insert it at the front.
    const mid = ops_surface.remove(pane, 35);
    try testing.expectEqual(@as(usize, 69), pane.tabCount());
    try ops_surface.insert(gpa, pane, mid, 0);
    try testing.expectEqual(mid, pane.tabs.items[0]);
    try testing.expectEqualStrings(mid.legacy.statusText(), pane.tabs.items[0].legacy.statusText());
    for (pane.tabs.items) |tab| try testing.expectEqual(pane, tab.pane.?);
}

test "unit: model: fake graph has no workspace or tab cap" {
    // 20 workspaces (the former MAX_WORKSPACES was 16) of one pane each.
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    for (0..20) |_| _ = try g.addWorkspace(&.{1});
    try testing.expectEqual(@as(usize, 20), g.workspaces.items.len);
    try testing.expectEqual(g.workspaces.items[0], g.selected.?);
}
