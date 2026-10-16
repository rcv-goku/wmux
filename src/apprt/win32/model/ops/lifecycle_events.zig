//! Lifecycle event emission shared by the model ops (ARCHITECTURE.md
//! ADR-3.10): each helper builds one catalog event and its payload for a
//! model object and emits it on the bus. Only model/ops/* call these, so
//! each lifecycle operation emits exactly once whatever path triggered it
//! (UI, shortcut, CLI, restore, startup). Emission never fails an
//! operation: a payload list that cannot be allocated drops the payload.
//!
//! Origins use cmux's values where cmux defines one for the same path
//! (`terminal_tab`, `browser_split`, `tab_close`, `pane_close`, ...);
//! W2-1/W2-2 (owners of the ops) and W2-4 (events) refine them.

const std = @import("std");

const Pane = @import("../Pane.zig");
const Tab = @import("../Tab.zig");
const Window = @import("../../ui/Window.zig");
const Workspace = @import("../Workspace.zig");
const events = @import("../events.zig");
const ids = @import("../ids.zig");

const log = std.log.scoped(.model_events);

const Uuid = ids.Uuid;
const Event = events.Event;
const Payload = events.Payload;

/// `window.created` / `window.closed` for `window`.
pub fn window(win: *Window, comptime name: []const u8, origin: []const u8) void {
    const selected = win.selected;
    const value: events.WindowPayload = .{
        .window_id = win.handle.uuid,
        .workspace_id = if (selected) |ws| ws.handle.uuid else null,
        .workspace_count = win.workspaces.items.len,
        .selected_workspace_index = if (selected != null) win.activeIndex() else null,
        .is_key_window = false,
        .is_main_window = !win.is_quick_terminal,
        .origin = origin,
    };
    var ev = Event.of(name);
    ev.window_id = win.handle.uuid;
    ev.workspace_id = value.workspace_id;
    ev.payload = Payload.of(events.WindowPayload, &value);
    events.emit(win.app, ev);
}

/// `workspace.created` / `workspace.closed` / `workspace.renamed`.
pub fn workspace(win: *Window, ws: *Workspace, comptime name: []const u8) void {
    const value: events.WorkspacePayload = .{
        .workspace_id = ws.handle.uuid,
        .title = ws.name() orelse "",
        .custom_title = ws.title.custom,
        .cwd = ws.cwd,
        .selected = win.selected == ws,
    };
    var ev = Event.of(name);
    ev.window_id = win.handle.uuid;
    ev.workspace_id = ws.handle.uuid;
    ev.payload = Payload.of(events.WorkspacePayload, &value);
    events.emit(win.app, ev);
}

/// `workspace.selected` (the window's selection changed to `ws`).
pub fn workspaceSelected(win: *Window, ws: *Workspace, previous: ?*Workspace) void {
    var tab_count: usize = 0;
    var it = ws.tree.iterator();
    while (it.next()) |entry| tab_count += entry.view.tabCount();
    const value: events.WorkspaceSelectedPayload = .{
        .workspace_id = ws.handle.uuid,
        .previous_workspace_id = if (previous) |p| p.handle.uuid else null,
        .index = win.workspaceIndex(ws),
        .tab_count = tab_count,
    };
    var ev = Event.of("workspace.selected");
    ev.window_id = win.handle.uuid;
    ev.workspace_id = ws.handle.uuid;
    ev.payload = Payload.of(events.WorkspaceSelectedPayload, &value);
    events.emit(win.app, ev);
}

/// `workspace.reordered` after `moved` changed position.
pub fn workspaceReordered(win: *Window, moved: *Workspace) void {
    var ev = Event.of("workspace.reordered");
    ev.window_id = win.handle.uuid;
    ev.workspace_id = moved.handle.uuid;
    var sfa = std.heap.stackFallback(32 * @sizeOf(Uuid), win.app.core_app.alloc);
    const gpa = sfa.get();
    const order: ?[]Uuid = gpa.alloc(Uuid, win.workspaces.items.len) catch null;
    defer if (order) |o| gpa.free(o);
    const moved_ids = [_]Uuid{moved.handle.uuid};
    var value: events.WorkspaceReorderedPayload = undefined;
    if (order) |o| {
        var pinned: usize = 0;
        for (win.workspaces.items, 0..) |w, i| {
            o[i] = w.handle.uuid;
            if (w.pinned) pinned += 1;
        }
        // The pinned workspaces, in order (none before W4-5 adds pinning).
        const pinned_ids: ?[]Uuid = gpa.alloc(Uuid, pinned) catch null;
        defer if (pinned_ids) |p| gpa.free(p);
        if (pinned_ids) |p| {
            var n: usize = 0;
            for (win.workspaces.items) |w| {
                if (!w.pinned) continue;
                p[n] = w.handle.uuid;
                n += 1;
            }
            value = .{ .workspace_ids = o, .moved_workspace_ids = &moved_ids, .pinned_workspace_ids = p, .count = o.len };
            ev.payload = Payload.of(events.WorkspaceReorderedPayload, &value);
        }
    }
    if (ev.payload == null) log.warn("workspace.reordered without payload (out of memory)", .{});
    events.emit(win.app, ev);
}

/// `pane.created` / `pane.broken` for a new `pane` of `ws`.
pub fn paneCreated(
    win: *Window,
    ws: *Workspace,
    pane: *Pane,
    comptime name: []const u8,
    source: ?*Pane,
    orientation: ?[]const u8,
    origin: []const u8,
) void {
    const first = pane.tabAt(0);
    const value: events.PaneCreatedPayload = .{
        .pane_id = pane.handle.uuid,
        .source_pane_id = if (source) |s| s.handle.uuid else null,
        .orientation = orientation,
        .surface_id = if (first) |t| t.handle.uuid else null,
        .origin = origin,
    };
    var ev = Event.of(name);
    ev.window_id = win.handle.uuid;
    ev.workspace_id = ws.handle.uuid;
    ev.pane_id = pane.handle.uuid;
    ev.surface_id = value.surface_id;
    ev.payload = Payload.of(events.PaneCreatedPayload, &value);
    events.emit(win.app, ev);
}

/// `pane.closed` for the (already removed) pane `pane_id` of `ws`.
pub fn paneClosed(win: *Window, ws: *Workspace, pane_id: Uuid, closed_surface_ids: []const Uuid, origin: []const u8) void {
    const value: events.PaneClosedPayload = .{ .pane_id = pane_id, .closed_surface_ids = closed_surface_ids, .origin = origin };
    var ev = Event.of("pane.closed");
    ev.window_id = win.handle.uuid;
    ev.workspace_id = ws.handle.uuid;
    ev.pane_id = pane_id;
    ev.payload = Payload.of(events.PaneClosedPayload, &value);
    events.emit(win.app, ev);
}

/// `pane.focused` (the workspace's focused pane changed to `pane`).
pub fn paneFocused(win: *Window, ws: *Workspace, pane: *Pane, origin: []const u8) void {
    const selected = pane.selectedTab();
    const value: events.PaneFocusedPayload = .{
        .pane_id = pane.handle.uuid,
        .selected_surface_id = if (selected) |t| t.handle.uuid else null,
        .origin = origin,
    };
    var ev = Event.of("pane.focused");
    ev.window_id = win.handle.uuid;
    ev.workspace_id = ws.handle.uuid;
    ev.pane_id = pane.handle.uuid;
    ev.surface_id = value.selected_surface_id;
    ev.payload = Payload.of(events.PaneFocusedPayload, &value);
    events.emit(win.app, ev);
}

/// `pane.swapped` / `pane.resized` for `pane` of `ws`.
pub fn paneChanged(win: *Window, ws: *Workspace, pane: *Pane, comptime name: []const u8, other: ?*Pane, origin: []const u8) void {
    const value: events.PaneChangedPayload = .{
        .pane_id = pane.handle.uuid,
        .other_pane_id = if (other) |o| o.handle.uuid else null,
        .origin = origin,
    };
    var ev = Event.of(name);
    ev.window_id = win.handle.uuid;
    ev.workspace_id = ws.handle.uuid;
    ev.pane_id = pane.handle.uuid;
    ev.payload = Payload.of(events.PaneChangedPayload, &value);
    events.emit(win.app, ev);
}

/// `surface.created` for the new `tab` of `pane`.
pub fn surfaceCreated(win: *Window, ws: *Workspace, pane: *Pane, tab: *Tab, origin: []const u8, focused: bool) void {
    const value: events.SurfaceCreatedPayload = .{
        .surface_id = tab.handle.uuid,
        .pane_id = pane.handle.uuid,
        .kind = tab.content.kindName(),
        .origin = origin,
        .focused = focused,
    };
    var ev = Event.of("surface.created");
    ev.window_id = win.handle.uuid;
    ev.workspace_id = ws.handle.uuid;
    ev.pane_id = pane.handle.uuid;
    ev.surface_id = tab.handle.uuid;
    ev.payload = Payload.of(events.SurfaceCreatedPayload, &value);
    events.emit(win.app, ev);
}

/// `surface.selected` (the selected tab of `pane` changed to `tab`).
pub fn surfaceSelected(win: *Window, ws: *Workspace, pane: *Pane, tab: *Tab, previous_id: ?Uuid, focused: bool, origin: []const u8) void {
    const value: events.SurfaceSelectedPayload = .{
        .surface_id = tab.handle.uuid,
        .pane_id = pane.handle.uuid,
        .kind = tab.content.kindName(),
        .previous_surface_id = previous_id,
        .focused = focused,
        .origin = origin,
    };
    var ev = Event.of("surface.selected");
    ev.window_id = win.handle.uuid;
    ev.workspace_id = ws.handle.uuid;
    ev.pane_id = pane.handle.uuid;
    ev.surface_id = tab.handle.uuid;
    ev.payload = Payload.of(events.SurfaceSelectedPayload, &value);
    events.emit(win.app, ev);
}

/// `surface.closed` for a tab already removed from pane `pane_id` (its
/// identity read before it was released).
pub fn surfaceClosed(win: *Window, ws: *Workspace, pane_id: Uuid, surface_id: Uuid, kind: []const u8, origin: []const u8) void {
    const value: events.SurfaceClosedPayload = .{ .surface_id = surface_id, .pane_id = pane_id, .kind = kind, .origin = origin };
    var ev = Event.of("surface.closed");
    ev.window_id = win.handle.uuid;
    ev.workspace_id = ws.handle.uuid;
    ev.pane_id = pane_id;
    ev.surface_id = surface_id;
    ev.payload = Payload.of(events.SurfaceClosedPayload, &value);
    events.emit(win.app, ev);
}

/// `surface.reordered` after `moved` changed position within `pane`.
pub fn surfaceReordered(win: *Window, ws: *Workspace, pane: *Pane, moved: *Tab) void {
    var ev = Event.of("surface.reordered");
    ev.window_id = win.handle.uuid;
    ev.workspace_id = ws.handle.uuid;
    ev.pane_id = pane.handle.uuid;
    ev.surface_id = moved.handle.uuid;
    var sfa = std.heap.stackFallback(32 * @sizeOf(Uuid), win.app.core_app.alloc);
    const gpa = sfa.get();
    const order: ?[]Uuid = gpa.alloc(Uuid, pane.tabCount()) catch null;
    defer if (order) |o| gpa.free(o);
    var value: events.SurfaceReorderedPayload = undefined;
    if (order) |o| {
        for (pane.tabs.items, 0..) |t, i| o[i] = t.handle.uuid;
        value = .{ .pane_id = pane.handle.uuid, .surface_ids = o, .moved_surface_id = moved.handle.uuid };
        ev.payload = Payload.of(events.SurfaceReorderedPayload, &value);
    } else log.warn("surface.reordered without payload (out of memory)", .{});
    events.emit(win.app, ev);
}
