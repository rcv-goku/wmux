//! Workspace group operations (ARCHITECTURE.md ADR-2.3, ADR-3.10): create,
//! rename and close the groups of a window, and move a workspace in or out
//! of a group. Creating a group mints its handle (`workspace_group:N`) and
//! closing one retires it; each operation emits its `wmux.workspace_group.*`
//! event. Written by W0-A3 so the model is complete before W4-5 (groups,
//! pins, the sidebar group headers) gives the operations their callers.

const std = @import("std");

const Group = @import("../Group.zig");
const Window = @import("../../ui/Window.zig");
const Workspace = @import("../Workspace.zig");
const events = @import("../events.zig");
const model_registry = @import("../registry.zig");

/// Create a group named `name` in `self`, its header anchored at `anchor`
/// (which joins it) when given, and append it to `self.groups`.
pub fn createGroup(self: *Window, name: []const u8, anchor: ?*Workspace) !*Group {
    const gpa = self.app.core_app.alloc;
    const group = try Group.create(gpa, self, name);
    errdefer group.destroy(gpa);
    try model_registry.register(&self.app.handles, gpa, group);
    try self.groups.append(gpa, group);
    if (anchor) |ws| {
        group.anchor = ws;
        ws.group = group;
    }
    emitGroup(self, group, "wmux.workspace_group.created");
    return group;
}

/// Rename `group` (a group of `self`).
pub fn renameGroup(self: *Window, group: *Group, name: []const u8) !void {
    try group.rename(self.app.core_app.alloc, name);
    emitGroup(self, group, "wmux.workspace_group.renamed");
}

/// Close `group`: its members leave it (they stay in the window), it
/// leaves `self.groups` and is destroyed. No-op for a group of another
/// window.
pub fn closeGroup(self: *Window, group: *Group) void {
    const idx = std.mem.indexOfScalar(*Group, self.groups.items, group) orelse return;
    for (self.workspaces.items) |ws| {
        if (ws.group == group) ws.group = null;
    }
    _ = self.groups.orderedRemove(idx);
    emitGroup(self, group, "wmux.workspace_group.closed");
    group.destroy(self.app.core_app.alloc);
}

/// Put `ws` into `group`, or out of any group with null.
pub fn setWorkspaceGroup(self: *Window, ws: *Workspace, group: ?*Group) void {
    _ = self;
    if (ws.group) |old| {
        if (old.anchor == ws) old.anchor = null;
    }
    ws.group = group;
}

const GroupPayload = struct {
    group_id: events.Uuid,
    name: []const u8,
};

fn emitGroup(self: *Window, group: *Group, comptime name: []const u8) void {
    const value: GroupPayload = .{ .group_id = group.handle.uuid, .name = group.name };
    var ev = events.Event.of(name);
    ev.window_id = self.handle.uuid;
    ev.payload = events.Payload.of(GroupPayload, &value);
    events.emit(self.app, ev);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const App = @import("../../App.zig");
const CoreApp = @import("../../../../App.zig");

test "unit: model: group ops mint, rename and retire group handles" {
    // Only the fields the group ops touch are set: the allocator, the
    // registry, the window's lists and handle.
    var core: CoreApp = undefined;
    core.alloc = testing.allocator;
    var app: App = undefined;
    app.core_app = &core;
    app.handles = .{};
    defer app.handles.deinit(testing.allocator);
    var win: Window = undefined;
    win.app = &app;
    win.handle = .{ .uuid = events.Uuid.v4(), .ref = 1 };
    win.groups = .empty;
    defer win.groups.deinit(testing.allocator);
    var ws: Workspace = .{ .window = &win };
    win.workspaces = .empty;
    defer win.workspaces.deinit(testing.allocator);
    try win.workspaces.append(testing.allocator, &ws);

    const group = try createGroup(&win, "backend", &ws);
    try testing.expectEqual(@as(u32, 1), group.handle.ref);
    try testing.expectEqual(group, app.handles.get(Group, .workspace_group, group.handle.uuid).?);
    try testing.expectEqual(group, ws.group.?);
    try testing.expectEqual(&ws, group.anchor.?);
    try renameGroup(&win, group, "api");
    try testing.expectEqualStrings("api", group.name);

    const second = try createGroup(&win, "web", null);
    try testing.expectEqual(@as(u32, 2), second.handle.ref);
    setWorkspaceGroup(&win, &ws, second);
    try testing.expectEqual(second, ws.group.?);
    try testing.expectEqual(@as(?*Workspace, null), group.anchor);

    const uuid = group.handle.uuid;
    closeGroup(&win, group);
    try testing.expectEqual(@as(?*Group, null), app.handles.get(Group, .workspace_group, uuid));
    try testing.expectEqual(@as(usize, 1), win.groups.items.len);
    closeGroup(&win, second);
    try testing.expectEqual(@as(?*Group, null), ws.group);
    try testing.expectEqual(@as(usize, 0), app.handles.count());
}
