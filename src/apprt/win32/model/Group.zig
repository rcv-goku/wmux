//! A workspace group (cmux "workspace group"; ARCHITECTURE.md §0.2,
//! ADR-2.3): a named, collapsible run of sidebar rows in one window.
//! Groups are heap objects owned by their window's `groups` list; a member
//! workspace points at its group (`Workspace.group`). The order of
//! `Window.workspaces`, `pinned` and `group` decide the workspace indexes
//! (ADR-2.4). No group is created before W4-5 (`groups` feature), which
//! adds the operations (model/ops/group.zig) and their events; the
//! display style (color, icon) lives in feature state, so a group has no
//! `ext`.

const Group = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Window = @import("../ui/Window.zig");
const Workspace = @import("Workspace.zig");
const ids = @import("ids.zig");
const handle_registry = @import("logic/handle_registry.zig");

/// Identity (`group_id`, `workspace_group:N`), minted at creation.
handle: ids.Handle = ids.no_handle,

/// The registry `handle` is minted in (null while unregistered).
registry: ?*handle_registry.HandleRegistry = null,

/// The window whose `groups` list owns this group.
window: *Window,

/// Display name (owned UTF-8).
name: []u8 = &.{},

/// Collapsed groups show only their header row.
collapsed: bool = false,

/// Pinned groups sort with the pinned workspaces.
pinned: bool = false,

/// The member the group was created from (its header follows it), if
/// any.
anchor: ?*Workspace = null,

/// Heap-allocate a group named `name` (copied) in `window`.
pub fn create(gpa: Allocator, window: *Window, name: []const u8) Allocator.Error!*Group {
    const group = try gpa.create(Group);
    errdefer gpa.destroy(group);
    group.* = .{ .window = window, .name = try gpa.dupe(u8, name) };
    return group;
}

/// Retire the handle and free the group (members must already point
/// elsewhere).
pub fn destroy(self: *Group, gpa: Allocator) void {
    if (self.registry) |r| r.retire(self.handle.uuid);
    gpa.free(self.name);
    gpa.destroy(self);
}

/// Replace the name with a copy of `name`.
pub fn rename(self: *Group, gpa: Allocator, name: []const u8) Allocator.Error!void {
    const copy = try gpa.dupe(u8, name);
    gpa.free(self.name);
    self.name = copy;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: model: group create, rename and destroy retire the handle" {
    const gpa = testing.allocator;
    var reg: handle_registry.HandleRegistry = .{};
    defer reg.deinit(gpa);

    const group = try Group.create(gpa, undefined, "backend");
    group.handle = try reg.mint(gpa, .workspace_group, group);
    group.registry = &reg;
    try testing.expectEqualStrings("backend", group.name);
    try testing.expect(!group.collapsed and !group.pinned);
    try testing.expectEqual(@as(?*Workspace, null), group.anchor);
    try group.rename(gpa, "api");
    try testing.expectEqualStrings("api", group.name);
    try testing.expectEqual(group, reg.get(Group, .workspace_group, group.handle.uuid).?);

    const uuid = group.handle.uuid;
    group.destroy(gpa);
    try testing.expectEqual(@as(?*Group, null), reg.get(Group, .workspace_group, uuid));
}
