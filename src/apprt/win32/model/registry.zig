//! Handles of the model objects (ARCHITECTURE.md ADR-2.2, ADR-2.4).
//!
//! `HandleRegistry` (pure, model/logic/handle_registry.zig) lives once in
//! `App.handles`. This file registers model objects in it (each object
//! keeps its `handle` and the `registry` it was minted in, and retires it
//! when destroyed) and resolves the three handle forms back to objects:
//!
//! - UUID and ref: through the registry, for every kind;
//! - legacy Ghostty core surface id: through the registry, surfaces only;
//! - index: positional and contextual (ADR-2.4): a window index counts in
//!   `App.windows` (creation order); a workspace index in its window's
//!   sidebar order (the `workspaces` list: pinning and groups have no
//!   behavior before W4-5, see W0-A4's display order); a pane index in
//!   the workspace's split-tree leaves, depth-first, left before right
//!   (the legacy `pane` index keeps `Workspace.paneAt`'s node order); a
//!   surface index in its pane's tab order, or for a workspace in pane
//!   order then tab order.
//!
//! An explicit handle never falls back to anything (fail closed); the
//! caller-context and active-window fallbacks are the router's (W1-1).

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("../App.zig");
const Group = @import("Group.zig");
const Pane = @import("Pane.zig");
const SplitTree = @import("../../../datastruct/split_tree.zig").SplitTree;
const Tab = @import("Tab.zig");
const Window = @import("../ui/Window.zig");
const Workspace = @import("Workspace.zig");
const handle_registry = @import("logic/handle_registry.zig");
const ids = @import("ids.zig");

pub const HandleRegistry = handle_registry.HandleRegistry;
pub const Entry = handle_registry.Entry;
pub const Kind = ids.Kind;
pub const HandleText = ids.HandleText;
pub const Uuid = ids.Uuid;

/// The handle kind of a model object type.
pub fn kindOf(comptime T: type) Kind {
    return switch (T) {
        Window => .window,
        Workspace => .workspace,
        Group => .workspace_group,
        Pane => .pane,
        Tab => .surface,
        else => @compileError("not a model object type: " ++ @typeName(T)),
    };
}

/// Mint `obj`'s handle with a fresh UUID (`obj` is a *Window, *Workspace,
/// *Group, *Pane or *Tab) and remember the registry for `unregister`.
pub fn register(reg: *HandleRegistry, gpa: Allocator, obj: anytype) handle_registry.Error!void {
    return registerUuid(reg, gpa, obj, Uuid.nil);
}

/// Like `register`, keeping `uuid` when it is free (a terminal's spawn
/// identity, `ids.SpawnIdentity`).
pub fn registerUuid(reg: *HandleRegistry, gpa: Allocator, obj: anytype, uuid: Uuid) handle_registry.Error!void {
    const T = @typeInfo(@TypeOf(obj)).pointer.child;
    std.debug.assert(obj.registry == null);
    obj.handle = try reg.mintUuid(gpa, kindOf(T), uuid, obj);
    obj.registry = reg;
}

/// Retire `obj`'s handle (no-op when it was never registered). Called by
/// the objects' own destroy paths.
pub fn unregister(obj: anytype) void {
    const r = obj.registry orelse return;
    r.retire(obj.handle.uuid);
    obj.registry = null;
    obj.handle = ids.no_handle;
}

// ---------------------------------------------------------------------------
// Resolution against the app
// ---------------------------------------------------------------------------

/// The window `h` names (an index counts in `App.windows`).
pub fn resolveWindow(app: *App, h: HandleText) ?*Window {
    return windowIn(&app.handles, app.windows.items, h);
}

/// The workspace `h` names; an index counts in `window` (null: an index
/// resolves nothing).
pub fn resolveWorkspace(app: *App, window: ?*Window, h: HandleText) ?*Workspace {
    return workspaceIn(&app.handles, if (window) |w| w.workspaces.items else null, h);
}

/// The pane `h` names, optionally scoped to `ws` (an index needs it; a
/// UUID or ref of a pane of another workspace resolves nothing).
pub fn resolvePane(app: *App, ws: ?*Workspace, h: HandleText) ?*Pane {
    return paneIn(&app.handles, ws, h);
}

/// What a surface index counts in.
pub const SurfaceScope = union(enum) {
    none,
    workspace: *Workspace,
    pane: *Pane,
};

/// The tab (surface) `h` names, scoped like `resolvePane`.
pub fn resolveSurface(app: *App, scope: SurfaceScope, h: HandleText) ?*Tab {
    return surfaceIn(&app.handles, scope, h);
}

// ---------------------------------------------------------------------------
// Resolution over explicit context (unit-tested on fake graphs)
// ---------------------------------------------------------------------------

pub fn windowIn(reg: *const HandleRegistry, windows: []const *Window, h: HandleText) ?*Window {
    return switch (h) {
        .index => |i| if (i < windows.len) windows[i] else null,
        else => objectOf(Window, reg, h),
    };
}

pub fn workspaceIn(reg: *const HandleRegistry, workspaces: ?[]const *Workspace, h: HandleText) ?*Workspace {
    switch (h) {
        .index => |i| {
            const list = workspaces orelse return null;
            return if (i < list.len) list[i] else null;
        },
        else => {
            const ws = objectOf(Workspace, reg, h) orelse return null;
            if (workspaces) |list| {
                if (std.mem.indexOfScalar(*Workspace, list, ws) == null) return null;
            }
            return ws;
        },
    }
}

pub fn paneIn(reg: *const HandleRegistry, ws: ?*const Workspace, h: HandleText) ?*Pane {
    switch (h) {
        .index => |i| return paneAtDepthFirst(ws orelse return null, i),
        else => {
            const pane = objectOf(Pane, reg, h) orelse return null;
            if (ws) |w| {
                if (pane.workspace != w) return null;
            }
            return pane;
        },
    }
}

pub fn surfaceIn(reg: *const HandleRegistry, scope: SurfaceScope, h: HandleText) ?*Tab {
    switch (h) {
        .index => |i| return switch (scope) {
            .none => null,
            .pane => |p| p.tabAt(i),
            .workspace => |w| surfaceAtInWorkspace(w, i),
        },
        else => {
            const tab = objectOf(Tab, reg, h) orelse return null;
            // A tab that left the model (closed, kept alive only by an
            // in-flight WebView2 creation) is not addressable.
            const pane = tab.pane orelse return null;
            switch (scope) {
                .none => {},
                .pane => |p| if (pane != p) return null,
                .workspace => |w| if (pane.workspace != w) return null,
            }
            return tab;
        },
    }
}

/// The `n`th pane of `ws` in depth-first leaf order, left before right
/// (the on-screen order of model/layout.zig, ADR-2.4).
pub fn paneAtDepthFirst(ws: *const Workspace, n: usize) ?*Pane {
    if (ws.tree.nodes.len == 0) return null;
    var seen: usize = 0;
    return leafAt(&ws.tree, .root, n, &seen);
}

fn leafAt(tree: *const SplitTree(Pane), handle: SplitTree(Pane).Node.Handle, n: usize, seen: *usize) ?*Pane {
    switch (tree.nodes[handle.idx()]) {
        .leaf => |pane| {
            if (seen.* == n) return pane;
            seen.* += 1;
            return null;
        },
        .split => |s| return leafAt(tree, s.left, n, seen) orelse leafAt(tree, s.right, n, seen),
    }
}

/// The `n`th surface of `ws`: pane order (depth-first), then tab order.
pub fn surfaceAtInWorkspace(ws: *const Workspace, n: usize) ?*Tab {
    var remaining = n;
    var i: usize = 0;
    while (paneAtDepthFirst(ws, i)) |pane| : (i += 1) {
        if (remaining < pane.tabCount()) return pane.tabs.items[remaining];
        remaining -= pane.tabCount();
    }
    return null;
}

fn objectOf(comptime T: type, reg: *const HandleRegistry, h: HandleText) ?*T {
    const e = reg.lookup(kindOf(T), h) orelse return null;
    return @ptrCast(@alignCast(e.ptr));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const fake = @import("logic/fake.zig");

/// Register every workspace, pane and tab of a fake graph in `reg`.
fn registerGraph(reg: *HandleRegistry, g: *fake.Graph) !void {
    for (g.workspaces.items) |ws| {
        try register(reg, testing.allocator, ws);
        var it = ws.tree.iterator();
        while (it.next()) |entry| {
            try register(reg, testing.allocator, entry.view);
            for (entry.view.tabs.items) |tab| try register(reg, testing.allocator, tab);
        }
    }
}

/// Retire everything registerGraph registered (fake graphs free their
/// objects without the destroy paths).
fn unregisterGraph(g: *fake.Graph) void {
    for (g.workspaces.items) |ws| {
        var it = ws.tree.iterator();
        while (it.next()) |entry| {
            for (entry.view.tabs.items) |tab| unregister(tab);
            unregister(entry.view);
        }
        unregister(ws);
    }
}

test "unit: model: handles resolve workspaces by uuid, ref and index" {
    var reg: HandleRegistry = .{};
    defer reg.deinit(testing.allocator);
    var g = fake.Graph.init(testing.allocator);
    defer g.deinit();
    const a = try g.addWorkspace(&.{1});
    const b = try g.addWorkspace(&.{ 1, 2 });
    try registerGraph(&reg, &g);
    defer unregisterGraph(&g);

    const list = g.workspaces.items;
    try testing.expectEqual(b, workspaceIn(&reg, list, .{ .uuid = b.handle.uuid }).?);
    try testing.expectEqual(a, workspaceIn(&reg, list, .{ .ref = .{ .kind = .workspace, .n = a.handle.ref } }).?);
    try testing.expectEqual(b, workspaceIn(&reg, list, .{ .index = 1 }).?);
    try testing.expectEqual(@as(?*Workspace, null), workspaceIn(&reg, list, .{ .index = 2 }));
    // An index needs a window; a UUID does not.
    try testing.expectEqual(@as(?*Workspace, null), workspaceIn(&reg, null, .{ .index = 0 }));
    try testing.expectEqual(a, workspaceIn(&reg, null, .{ .uuid = a.handle.uuid }).?);
    // A workspace outside the given window resolves nothing (fail closed).
    try testing.expectEqual(@as(?*Workspace, null), workspaceIn(&reg, list[0..1], .{ .uuid = b.handle.uuid }));
    // A pane's UUID is not a workspace.
    const pane_uuid = a.paneAt(0).?.handle.uuid;
    try testing.expectEqual(@as(?*Workspace, null), workspaceIn(&reg, list, .{ .uuid = pane_uuid }));
}

test "unit: model: handles resolve panes depth-first and surfaces in context" {
    var reg: HandleRegistry = .{};
    defer reg.deinit(testing.allocator);
    var g = fake.Graph.init(testing.allocator);
    defer g.deinit();
    const ws = try g.addWorkspace(&.{ 2, 1, 3 });
    const other = try g.addWorkspace(&.{1});
    try registerGraph(&reg, &g);
    defer unregisterGraph(&g);

    // Fake graphs are built in pre-order, so depth-first order is pane
    // index order here.
    for (0..3) |i| try testing.expectEqual(ws.paneAt(i).?, paneIn(&reg, ws, .{ .index = @intCast(i) }).?);
    try testing.expectEqual(@as(?*Pane, null), paneIn(&reg, ws, .{ .index = 3 }));
    const p1 = ws.paneAt(1).?;
    try testing.expectEqual(p1, paneIn(&reg, ws, .{ .uuid = p1.handle.uuid }).?);
    try testing.expectEqual(p1, paneIn(&reg, null, .{ .ref = .{ .kind = .pane, .n = p1.handle.ref } }).?);
    try testing.expectEqual(@as(?*Pane, null), paneIn(&reg, other, .{ .uuid = p1.handle.uuid }));

    // Surfaces: tab order in a pane; pane order then tab order in a workspace.
    const p2 = ws.paneAt(2).?;
    try testing.expectEqual(p2.tabs.items[1], surfaceIn(&reg, .{ .pane = p2 }, .{ .index = 1 }).?);
    try testing.expectEqual(ws.paneAt(0).?.tabs.items[1], surfaceIn(&reg, .{ .workspace = ws }, .{ .index = 1 }).?);
    try testing.expectEqual(p1.tabs.items[0], surfaceIn(&reg, .{ .workspace = ws }, .{ .index = 2 }).?);
    try testing.expectEqual(p2.tabs.items[2], surfaceIn(&reg, .{ .workspace = ws }, .{ .index = 5 }).?);
    try testing.expectEqual(@as(?*Tab, null), surfaceIn(&reg, .{ .workspace = ws }, .{ .index = 6 }));
    try testing.expectEqual(@as(?*Tab, null), surfaceIn(&reg, .none, .{ .index = 0 }));
    const tab = p2.tabs.items[0];
    try testing.expectEqual(tab, surfaceIn(&reg, .none, .{ .uuid = tab.handle.uuid }).?);
    try testing.expectEqual(tab, surfaceIn(&reg, .{ .workspace = ws }, .{ .ref = .{ .kind = .surface, .n = tab.handle.ref } }).?);
    try testing.expectEqual(@as(?*Tab, null), surfaceIn(&reg, .{ .pane = p1 }, .{ .uuid = tab.handle.uuid }));
    try testing.expectEqual(@as(?*Tab, null), surfaceIn(&reg, .{ .workspace = other }, .{ .uuid = tab.handle.uuid }));
}

test "unit: model: handles of a split-grown tree count panes depth-first" {
    // SplitTree.split stores the new pane before the original, so the
    // node order (Workspace.paneAt) and the depth-first order differ.
    const gpa = testing.allocator;
    const left = try fake.makePane(gpa, null, 1);
    defer fake.freePane(gpa, left);
    const right = try fake.makePane(gpa, null, 1);
    defer fake.freePane(gpa, right);
    // The tree SplitTree.split builds when `right` splits off `left`: a
    // root split whose right child is node 1 and left child node 2.
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const T = SplitTree(Pane);
    const nodes = try arena.allocator().alloc(T.Node, 3);
    nodes[0] = .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = @enumFromInt(2), .right = @enumFromInt(1) } };
    nodes[1] = .{ .leaf = right };
    nodes[2] = .{ .leaf = left };
    var ws: Workspace = .{ .window = undefined, .tree = .{ .arena = arena, .nodes = nodes, .zoomed = null } };
    defer fake.freeTree(&ws.tree);

    try testing.expectEqual(right, ws.paneAt(0).?);
    try testing.expectEqual(left, paneAtDepthFirst(&ws, 0).?);
    try testing.expectEqual(right, paneAtDepthFirst(&ws, 1).?);
    try testing.expectEqual(@as(?*Pane, null), paneAtDepthFirst(&ws, 2));
    try testing.expectEqual(left.tabs.items[0], surfaceAtInWorkspace(&ws, 0).?);
}

test "unit: model: handles of destroyed objects stop resolving" {
    var reg: HandleRegistry = .{};
    defer reg.deinit(testing.allocator);
    var g = fake.Graph.init(testing.allocator);
    defer g.deinit();
    const ws = try g.addWorkspace(&.{2});
    try registerGraph(&reg, &g);
    defer unregisterGraph(&g);

    const tab = ws.paneAt(0).?.tabs.items[1];
    const uuid = tab.handle.uuid;
    unregister(tab);
    try testing.expect(!ids.isRegistered(tab.handle));
    try testing.expectEqual(@as(?*Tab, null), surfaceIn(&reg, .none, .{ .uuid = uuid }));
    // The pane and workspace still resolve.
    try testing.expect(paneIn(&reg, ws, .{ .index = 0 }) != null);
    try testing.expect(workspaceIn(&reg, null, .{ .uuid = ws.handle.uuid }) != null);
}
