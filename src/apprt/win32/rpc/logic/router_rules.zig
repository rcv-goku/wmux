//! Pure routing rules of the v2 router (ARCHITECTURE.md ADR-2.4, ADR-2.6),
//! used by rpc/router.zig. Std and wmux_proto only.
//!
//! - Precedence: an explicit selector wins in the order window_id →
//!   group_id → workspace_id → surface_id (aliases terminal_id, tab_id) →
//!   pane_id; without one the caller context (`params.caller`, ADR-3.9)
//!   decides, then the active window (the most recently activated wmux
//!   window, never `GetForegroundWindow()`).
//! - Workspace indexes are display positions (pinned rows first, groups
//!   flattened in display order: model/logic/display_order.zig); the
//!   router maps a display index to the `Window.workspaces` position with
//!   `listIndexOfDisplay`.
//! - An explicit selector that does not resolve fails closed: it never
//!   falls back to the caller or the active window.

const std = @import("std");
const proto = @import("wmux_proto");

const Selectors = proto.selectors.Selectors;
const Caller = proto.selectors.Caller;

/// What decides the target of a request (ADR-2.6), strongest first.
pub const Source = enum { window, group, workspace, surface, pane, caller, active };

/// The strongest source present in `sel`, else the caller context, else
/// the active window.
pub fn primary(sel: Selectors, caller: ?Caller) Source {
    if (sel.window != null) return .window;
    if (sel.group != null) return .group;
    if (sel.workspace != null) return .workspace;
    if (sel.surface != null) return .surface;
    if (sel.pane != null) return .pane;
    if (caller) |c| {
        if (c.workspace != null or c.surface != null) return .caller;
    }
    return .active;
}

/// The selector that scopes a workspace index (`workspace_id: 3`): an
/// explicit window, else the caller's window, else the active window.
pub const IndexScope = enum { window, caller, active };

pub fn workspaceIndexScope(sel: Selectors, caller: ?Caller) IndexScope {
    if (sel.window != null) return .window;
    if (caller) |c| {
        if (c.workspace != null or c.surface != null) return .caller;
    }
    return .active;
}

/// The `Window.workspaces` position shown at display index `display` of
/// `order` (`display_order.compute`: element i = list position of display
/// row i), or null when out of range.
pub fn listIndexOfDisplay(order: []const usize, display: usize) ?usize {
    if (display >= order.len) return null;
    return order[display];
}

/// The display index of list position `list_index`, or null.
pub fn displayOfListIndex(order: []const usize, list_index: usize) ?usize {
    return std.mem.indexOfScalar(usize, order, list_index);
}

/// The routing failure message for a selector of `kind` that did not
/// resolve (cmux's exact strings for workspace and surface).
pub fn notFoundMessage(kind: proto.handles.Kind) []const u8 {
    return proto.errors.notFoundMessage(kind);
}

/// The canonical selector key a failure names in `data.selector`.
pub fn selectorKey(kind: proto.handles.Kind) []const u8 {
    return switch (kind) {
        .window => "window_id",
        .workspace_group => "group_id",
        .workspace => "workspace_id",
        .pane => "pane_id",
        .surface => "surface_id",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseSel(arena: std.mem.Allocator, json: []const u8) !Selectors {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    var failure: proto.selectors.Failure = undefined;
    return proto.selectors.parse(arena, &v.object, &failure);
}

test "unit: rpc: router precedence is window, group, workspace, surface, pane, caller, active" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const all = try parseSel(a, "{\"pane_id\":\"pane:1\",\"surface_id\":\"surface:2\",\"workspace_id\":\"workspace:3\",\"group_id\":\"workspace_group:4\",\"window_id\":\"window:5\"}");
    try testing.expectEqual(Source.window, primary(all, null));
    try testing.expectEqual(Source.group, primary(try parseSel(a, "{\"pane_id\":1,\"group_id\":\"workspace_group:1\",\"workspace_id\":2}"), null));
    try testing.expectEqual(Source.workspace, primary(try parseSel(a, "{\"pane_id\":1,\"surface_id\":0,\"workspace_id\":2}"), null));
    // terminal_id and tab_id are surface aliases and beat pane_id.
    try testing.expectEqual(Source.surface, primary(try parseSel(a, "{\"pane_id\":1,\"tab_id\":\"tab:2\"}"), null));
    try testing.expectEqual(Source.surface, primary(try parseSel(a, "{\"terminal_id\":\"surface:9\"}"), null));
    try testing.expectEqual(Source.pane, primary(try parseSel(a, "{\"pane_id\":0}"), null));
    const caller: Caller = .{ .surface = .{ .ref = .{ .kind = .surface, .n = 3 } } };
    try testing.expectEqual(Source.caller, primary(.{}, caller));
    // An explicit selector beats the caller context.
    try testing.expectEqual(Source.pane, primary(try parseSel(a, "{\"pane_id\":0}"), caller));
    try testing.expectEqual(Source.active, primary(.{}, null));
    try testing.expectEqual(Source.active, primary(.{}, .{}));
}

test "unit: rpc: router scopes a workspace index by window, then caller, then active window" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqual(IndexScope.window, workspaceIndexScope(try parseSel(a, "{\"window_id\":0,\"workspace_id\":1}"), null));
    const caller: Caller = .{ .workspace = .{ .index = 0 } };
    try testing.expectEqual(IndexScope.caller, workspaceIndexScope(try parseSel(a, "{\"workspace_id\":1}"), caller));
    try testing.expectEqual(IndexScope.active, workspaceIndexScope(try parseSel(a, "{\"workspace_id\":1}"), null));
}

test "unit: rpc: router workspace index is the display position" {
    // Two pinned rows first, then a group of two, then an ungrouped row
    // (model/logic/display_order.zig computes `order`).
    const order = [_]usize{ 3, 1, 0, 4, 2 };
    try testing.expectEqual(@as(?usize, 3), listIndexOfDisplay(&order, 0));
    try testing.expectEqual(@as(?usize, 2), listIndexOfDisplay(&order, 4));
    try testing.expectEqual(@as(?usize, null), listIndexOfDisplay(&order, 5));
    try testing.expectEqual(@as(?usize, 0), displayOfListIndex(&order, 3));
    try testing.expectEqual(@as(?usize, 4), displayOfListIndex(&order, 2));
    try testing.expectEqual(@as(?usize, null), displayOfListIndex(&order, 7));
    try testing.expectEqual(@as(?usize, null), listIndexOfDisplay(&.{}, 0));
}

test "unit: rpc: router errors use cmux strings and canonical keys" {
    try testing.expectEqualStrings("Workspace not found", notFoundMessage(.workspace));
    try testing.expectEqualStrings("Surface not found for the given surface_id", notFoundMessage(.surface));
    try testing.expectEqualStrings("workspace_id", selectorKey(.workspace));
    try testing.expectEqualStrings("group_id", selectorKey(.workspace_group));
}

test "unit: rpc: non-canonical workspaceId fails with the cmux message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"title\":\"x\",\"workspaceId\":\"workspace:1\"}", .{});
    var failure: proto.selectors.Failure = undefined;
    try testing.expectError(error.Rejected, proto.selectors.parse(a, &v.object, &failure));
    try testing.expectEqual(proto.errors.Code.invalid_params, failure.code);
    try testing.expectEqualStrings("Unsupported parameter 'workspaceId'; use 'workspace_id'", failure.message);
    try testing.expectEqualStrings("workspaceId", failure.key);
    // Other spellings that differ only by case or underscores fail too.
    const w = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"Surface_ID\":\"surface:1\"}", .{});
    try testing.expectError(error.Rejected, proto.selectors.parse(a, &w.object, &failure));
    try testing.expectEqualStrings("Unsupported parameter 'Surface_ID'; use 'surface_id'", failure.message);
}
