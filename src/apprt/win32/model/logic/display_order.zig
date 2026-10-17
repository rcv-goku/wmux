//! Workspace display order (ARCHITECTURE.md ADR-2.4, AF-22): the order
//! of a window's sidebar rows, which is what a workspace index means.
//! Pinned rows come first, then the rest; a group is one row of its own
//! (its header) that expands to its members in place, so the groups are
//! flattened in display order.
//!
//! The rules, in this order:
//!
//! 1. Every ungrouped workspace is one entry at its position in
//!    `Window.workspaces`. Every group with at least one member is one
//!    entry at the position of its anchor when the anchor is a member,
//!    else at the position of its first member. Groups without members
//!    show no workspace and contribute nothing.
//! 2. Pinned entries (a pinned ungrouped workspace, or a pinned group)
//!    come before unpinned ones; both runs keep their relative order.
//! 3. A group entry expands to its members in `Window.workspaces` order,
//!    pinned members first (the same stable rule inside the group).
//!
//! Collapsing a group only hides rows: collapsed members keep their
//! indexes. The `pinned` flag of a workspace inside a group only orders
//! it within the group (rule 3).
//!
//! Std-only (ADR-1.2): the model types reach it through `fromModel`,
//! which takes any workspace/group pointer slices with the ADR-2.3 fields
//! (`Workspace.pinned`, `Workspace.group`, `Group.pinned`,
//! `Group.anchor`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One workspace, by its position in `Window.workspaces`.
pub const WorkspaceKey = struct {
    pinned: bool = false,
    /// Index into the group list, or null when ungrouped.
    group: ?usize = null,
};

/// One group, by its position in `Window.groups`.
pub const GroupKey = struct {
    pinned: bool = false,
    /// Index into the workspace list of the workspace the group was
    /// created from (its header follows it), if any.
    anchor: ?usize = null,
};

pub const Error = Allocator.Error || error{InvalidGroup};

/// The display order: element `i` is the `Window.workspaces` index of the
/// workspace shown at display index `i`. Every workspace appears exactly
/// once. Caller owns the result. Fails with InvalidGroup when a
/// workspace names a group index out of range.
pub fn compute(gpa: Allocator, workspaces: []const WorkspaceKey, groups: []const GroupKey) Error![]usize {
    for (workspaces) |ws| {
        if (ws.group) |g| if (g >= groups.len) return error.InvalidGroup;
    }

    // Rule 1: the position of every group entry (null = no members).
    const group_pos = try gpa.alloc(?usize, groups.len);
    defer gpa.free(group_pos);
    @memset(group_pos, null);
    for (workspaces, 0..) |ws, i| {
        const g = ws.group orelse continue;
        if (group_pos[g] == null) group_pos[g] = i;
    }
    for (groups, 0..) |group, g| {
        const anchor = group.anchor orelse continue;
        if (group_pos[g] == null) continue;
        if (anchor < workspaces.len and workspaces[anchor].group == g) group_pos[g] = anchor;
    }

    const out = try gpa.alloc(usize, workspaces.len);
    errdefer gpa.free(out);
    var n: usize = 0;

    // Rule 2: pinned entries first, then the rest. Entries are visited in
    // workspace order; a group entry is visited at its position.
    for ([_]bool{ true, false }) |want_pinned| {
        for (workspaces, 0..) |ws, i| {
            if (ws.group) |g| {
                if (group_pos[g] != i or groups[g].pinned != want_pinned) continue;
                // Rule 3: the members, pinned first.
                for ([_]bool{ true, false }) |member_pinned| {
                    for (workspaces, 0..) |m, j| {
                        if (m.group != g or m.pinned != member_pinned) continue;
                        out[n] = j;
                        n += 1;
                    }
                }
            } else if (ws.pinned == want_pinned) {
                out[n] = i;
                n += 1;
            }
        }
    }
    std.debug.assert(n == workspaces.len);
    return out;
}

/// The display index of the workspace at `Window.workspaces` index
/// `ws_index` in `order` (from `compute`), or null when absent.
pub fn displayIndexOf(order: []const usize, ws_index: usize) ?usize {
    return std.mem.indexOfScalar(usize, order, ws_index);
}

/// `compute` over model objects: `workspaces` and `groups` are slices of
/// pointers to structs with the ADR-2.3 fields (`pinned: bool`,
/// `group: ?*G` on workspaces; `pinned: bool`, `anchor: ?*W` on groups),
/// e.g. `window.workspaces.items` and `window.groups.items`. A workspace
/// whose group is not in `groups` counts as ungrouped; an anchor that is
/// not in `workspaces` is ignored.
pub fn fromModel(gpa: Allocator, workspaces: anytype, groups: anytype) Allocator.Error![]usize {
    const ws_keys = try gpa.alloc(WorkspaceKey, workspaces.len);
    defer gpa.free(ws_keys);
    for (workspaces, ws_keys) |ws, *key| {
        key.* = .{
            .pinned = ws.pinned,
            .group = if (ws.group) |g| indexOfPtr(groups, g) else null,
        };
    }
    const group_keys = try gpa.alloc(GroupKey, groups.len);
    defer gpa.free(group_keys);
    for (groups, group_keys) |group, *key| {
        key.* = .{
            .pinned = group.pinned,
            .anchor = if (group.anchor) |a| indexOfPtr(workspaces, a) else null,
        };
    }
    return compute(gpa, ws_keys, group_keys) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // Group indexes come from indexOfPtr, so they are in range.
        error.InvalidGroup => unreachable,
    };
}

fn indexOfPtr(items: anytype, ptr: anytype) ?usize {
    for (items, 0..) |item, i| {
        if (item == ptr) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectOrder(expected: []const usize, workspaces: []const WorkspaceKey, groups: []const GroupKey) !void {
    const got = try compute(testing.allocator, workspaces, groups);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(usize, expected, got);
}

test "unit: model: display order without pins or groups is the workspace order" {
    try expectOrder(&.{ 0, 1, 2 }, &.{ .{}, .{}, .{} }, &.{});
    try expectOrder(&.{}, &.{}, &.{});
}

test "unit: model: display order lists pinned workspaces first, keeping their order" {
    try expectOrder(
        &.{ 1, 3, 0, 2, 4 },
        &.{ .{}, .{ .pinned = true }, .{}, .{ .pinned = true }, .{} },
        &.{},
    );
}

test "unit: model: display order flattens a group at its first member" {
    // Workspaces: 0 ungrouped, 1 in g0, 2 ungrouped, 3 in g0.
    try expectOrder(
        &.{ 0, 1, 3, 2 },
        &.{ .{}, .{ .group = 0 }, .{}, .{ .group = 0 } },
        &.{.{}},
    );
}

test "unit: model: display order places a group at its anchor and pins members first" {
    // g0 = {1, 3, 4}, anchored at 3; member 4 is pinned inside the group.
    try expectOrder(
        &.{ 0, 2, 4, 1, 3 },
        &.{ .{}, .{ .group = 0 }, .{}, .{ .group = 0 }, .{ .group = 0, .pinned = true } },
        &.{.{ .anchor = 3 }},
    );
    // An anchor that is not a member falls back to the first member.
    try expectOrder(
        &.{ 0, 1, 3, 2 },
        &.{ .{}, .{ .group = 0 }, .{}, .{ .group = 0 } },
        &.{.{ .anchor = 2 }},
    );
}

test "unit: model: display order sorts pinned groups with the pinned workspaces" {
    // 0 unpinned, g0 = {1, 2} unpinned, 3 pinned, g1 = {4} pinned, 5 unpinned.
    try expectOrder(
        &.{ 3, 4, 0, 1, 2, 5 },
        &.{ .{}, .{ .group = 0 }, .{ .group = 0 }, .{ .pinned = true }, .{ .group = 1 }, .{} },
        &.{ .{}, .{ .pinned = true } },
    );
}

test "unit: model: display order skips empty groups and rejects bad group indexes" {
    try expectOrder(&.{ 0, 1 }, &.{ .{}, .{} }, &.{ .{ .pinned = true }, .{} });
    try testing.expectError(error.InvalidGroup, compute(testing.allocator, &.{.{ .group = 2 }}, &.{.{}}));
}

test "unit: model: display order maps workspace indexes to display indexes" {
    const order = [_]usize{ 3, 0, 2, 1 };
    try testing.expectEqual(@as(?usize, 1), displayIndexOf(&order, 0));
    try testing.expectEqual(@as(?usize, 0), displayIndexOf(&order, 3));
    try testing.expectEqual(@as(?usize, null), displayIndexOf(&order, 9));
}

/// Model-shaped test structs (the ADR-2.3 fields only).
const TestGroup = struct { pinned: bool = false, anchor: ?*const TestWorkspace = null };
const TestWorkspace = struct { pinned: bool = false, group: ?*const TestGroup = null };

test "unit: model: display order from model-shaped structs" {
    const G = TestGroup;
    const W = TestWorkspace;
    var g0: G = .{};
    const g1: G = .{ .pinned = true };
    // 0 in g0, 1 ungrouped, 2 pinned, 3 in the pinned g1, 4 in g0.
    const ws = [_]W{ .{ .group = &g0 }, .{}, .{ .pinned = true }, .{ .group = &g1 }, .{ .group = &g0 } };
    const ws_ptrs = [_]*const W{ &ws[0], &ws[1], &ws[2], &ws[3], &ws[4] };
    const ws_slice: []const *const W = &ws_ptrs;
    const group_ptrs = [_]*const G{ &g0, &g1 };
    const group_slice: []const *const G = &group_ptrs;

    const plain = try fromModel(testing.allocator, ws_slice, group_slice);
    defer testing.allocator.free(plain);
    try testing.expectEqualSlices(usize, &.{ 2, 3, 0, 4, 1 }, plain);

    // Anchored at its second member, g0 moves after workspace 1.
    g0.anchor = &ws[4];
    const anchored = try fromModel(testing.allocator, ws_slice, group_slice);
    defer testing.allocator.free(anchored);
    try testing.expectEqualSlices(usize, &.{ 2, 3, 1, 0, 4 }, anchored);

    // An anchor outside the list is ignored.
    const other: W = .{};
    g0.anchor = &other;
    const ignored = try fromModel(testing.allocator, ws_slice, group_slice);
    defer testing.allocator.free(ignored);
    try testing.expectEqualSlices(usize, &.{ 2, 3, 0, 4, 1 }, ignored);
}
