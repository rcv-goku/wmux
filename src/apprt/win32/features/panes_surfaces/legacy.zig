//! Legacy wmux-v1 JSON commands of the `panes_surfaces` feature: tab-list,
//! tab-new, tab-select, tab-close, surface-list, surface-focus, new-split,
//! swap-split, break-pane, move-pane (`wmux +tab|+surface|+split ...`).
//!
//! Tab commands operate on the focused Pane (split-tree leaf) of
//! the addressed workspace; an optional "pane" arg overrides with a
//! container index. Indices are window-local to the IPC target window.
//! The Window mutators act on the *active* workspace, so handlers that
//! target a non-active workspace select it first.
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8). W2-2
//! re-points them to the v2 `surface.*`/`pane.*` methods (Appendix B.4).

const std = @import("std");

const apprt = @import("../../../../apprt.zig");
const App = @import("../../App.zig");
const Pane = @import("../../model/Pane.zig");
const SplitTree = @import("../../../../datastruct/split_tree.zig").SplitTree;
const ipc = @import("../../rpc/compat/legacy_json.zig");
const LegacyCommand = @import("../../rpc/compat/legacy_table.zig").LegacyCommand;
const targets = @import("../../rpc/compat/legacy_targets.zig");

const IpcError = targets.IpcError;

/// Read a required string field from the request args.
const ipcArgString = ipc.argString;

/// Read an optional u32 index field ("index"/"workspace"/"tab").
const ipcArgU32 = ipc.argU32;

/// Read an optional bool field (send's "enter").
const ipcArgBool = ipc.argBool;

/// Read the optional u64 "surface" arg: a stable surface id
/// (GHOSTTY_SURFACE_ID). Pure logic in legacy_json.zig so the protocol tests cover it.
const ipcArgU64 = ipc.argU64;

pub const commands = [_]LegacyCommand{
    .{ .cmd = "tab-list", .handler = &ipcTabList, .read_only = true },
    .{ .cmd = "tab-new", .handler = &ipcTabNew },
    .{ .cmd = "tab-select", .handler = &ipcTabSelect },
    .{ .cmd = "tab-close", .handler = &ipcTabClose },
    .{ .cmd = "surface-list", .handler = &ipcSurfaceList, .read_only = true },
    .{ .cmd = "surface-focus", .handler = &ipcSurfaceFocus },
    .{ .cmd = "new-split", .handler = &ipcNewSplit },
    .{ .cmd = "swap-split", .handler = &ipcSwapSplit },
    .{ .cmd = "break-pane", .handler = &ipcBreakPane },
    .{ .cmd = "move-pane", .handler = &ipcMovePaneToTab },
};

/// tab-list {[workspace], [pane]} → [{index, title, active}] for the
/// focused Pane (or the one at `pane` index) of the addressed
/// (or active) workspace.
fn ipcTabList(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try targets.ipcResolveWorkspace(self, req);
    const container = if (ipcArgU32(req, "pane")) |p|
        target.ws.paneAt(p) orelse return IpcError.UnknownPane
    else
        target.ws.focusedPaneOrFirst() orelse {
            server.sendOk(req.id, "[]") catch {};
            return;
        };
    const alloc = self.core_app.alloc;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (container.tabs.items, 0..) |tab, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.writer(alloc).print("{{\"index\":{d},\"title\":", .{i});
        try targets.ipcWriteJsonText(self, &buf, tab.titleText());
        try buf.writer(alloc).print(
            ",\"active\":{}}}",
            .{i == container.selected},
        );
    }
    try buf.append(alloc, ']');
    server.sendOk(req.id, buf.items) catch {};
}

/// tab-new {[workspace], [command], [pane]} → add a tab to the focused
/// Pane (or the one at `pane` index) of the addressed (or
/// active) workspace and reply with its index. With `command` the tab
/// runs that shell (split on spaces); without it the tab inherits the
/// active pane's backend (matching the "+" new-tab UX). The Window tab
/// mutators act on the active workspace, so a non-active target workspace
/// is selected first.
fn ipcTabNew(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try targets.ipcResolveWorkspace(self, req);
    const window = target.window;
    const ws_idx = target.ws_idx;
    if (window.is_quick_terminal) return IpcError.QuickTerminal;

    // Programmatic creation defaults to NON-FOCUS: the tab is added to the
    // target workspace in the background; the active workspace/tab does not
    // change. `--focus` (focus:true) switches to the target workspace and
    // selects the new tab. Matches cmux #3215 (applied to all create verbs)
    // and the "create != focus" policy.
    //
    // The returned index is the new tab's index WITHIN THE TARGET
    // Pane, the same index `+tab list --workspace <ws>` shows and
    // `+tab close --workspace <ws>` accepts.
    const focus = ipcArgBool(req, "focus") orelse false;

    // --pane targets a specific Pane by index. The tab creation
    // functions read the workspace's focused container, so redirect it.
    if (ipcArgU32(req, "pane")) |p| {
        const ws = window.workspaces.items[ws_idx];
        ws.focused_pane = ws.paneAt(p) orelse return IpcError.UnknownPane;
    }

    if (focus and ws_idx != window.activeIndex())
        window.selectWorkspace(ws_idx);

    // Parse an optional explicit command (split on whitespace) once; an
    // empty/whitespace-only command falls through to the inherit path.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(self.core_app.alloc);
    if (ipcArgString(req, "command")) |command_str| {
        var it = std.mem.tokenizeAny(u8, command_str, &std.ascii.whitespace);
        while (it.next()) |tok| try argv.append(self.core_app.alloc, tok);
    }
    const command: ?[]const []const u8 = if (argv.items.len > 0) argv.items else null;

    const idx: usize = if (focus) blk: {
        // After the (optional) selectWorkspace above, ws_idx is the active
        // workspace; the interactive add-tab paths switch to and focus the
        // new tab, and return its index.
        if (command) |c| {
            _ = try window.addTabWithCommand(c, null);
        } else {
            _ = try window.addTabInherit();
        }
        break :blk if (window.activeWorkspace().focusedPaneOrFirst()) |c| c.selected else 0;
    } else if (command) |c|
        try window.addTabBackground(ws_idx, c, null)
    else
        try window.addTabInheritBackground(ws_idx);

    var data_buf: [32]u8 = undefined;
    const data = std.fmt.bufPrint(&data_buf, "{{\"index\":{d}}}", .{idx}) catch
        return error.NoSpaceLeft;
    server.sendOk(req.id, data) catch {};
}

/// tab-select {index, [workspace], [pane]} → make tab `index` active in
/// the focused Pane (or the one at `pane` index) of the
/// addressed (or active) workspace. selectTabIndex acts on the active
/// workspace, so a non-active target is selected first.
fn ipcTabSelect(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try targets.ipcResolveWorkspace(self, req);
    const idx = ipcArgU32(req, "index") orelse return IpcError.MissingIndex;

    if (ipcArgU32(req, "pane")) |p| {
        target.ws.focused_pane = target.ws.paneAt(p) orelse return IpcError.UnknownPane;
    }

    const container = target.ws.focusedPaneOrFirst() orelse return IpcError.UnknownTab;
    if (idx >= container.tabCount()) return IpcError.UnknownTab;

    if (target.ws_idx != target.window.activeIndex())
        target.window.selectWorkspace(target.ws_idx);
    target.window.selectTabIndex(idx);
    server.sendOk(req.id, null) catch {};
}

/// tab-close {index, [workspace], [pane]} → close tab `index` in the
/// focused Pane (or the one at `pane` index) of the addressed
/// (or active) workspace.
fn ipcTabClose(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try targets.ipcResolveWorkspace(self, req);
    const idx = ipcArgU32(req, "index") orelse return IpcError.MissingIndex;

    if (ipcArgU32(req, "pane")) |p| {
        target.ws.focused_pane = target.ws.paneAt(p) orelse return IpcError.UnknownPane;
    }

    const container = target.ws.focusedPaneOrFirst() orelse return IpcError.UnknownTab;
    if (idx >= container.tabCount()) return IpcError.UnknownTab;
    target.window.closeTabInWorkspaceForIpc(target.ws_idx, idx);
    server.sendOk(req.id, null) catch {};
}

/// surface-list {[workspace]} → [{pane, tab, id, type, focused, title}]
/// for every tab in every Pane (split tree leaf) of the
/// addressed (or active) workspace.
fn ipcSurfaceList(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const ws_target = try targets.ipcResolveWorkspace(self, req);
    const ws = ws_target.ws;
    const focused_container = ws.focusedPaneOrFirst();
    const alloc = self.core_app.alloc;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    var first = true;
    var tree_it = ws.tree.iterator();
    var pane_idx: usize = 0;
    while (tree_it.next()) |tree_entry| {
        const container = tree_entry.view;
        const is_focused_container = if (focused_container) |fc| container == fc else false;
        const active_pane = container.selectedTab();
        for (container.tabs.items, 0..) |pane, t| {
            if (!first) try buf.append(alloc, ',');
            first = false;
            const is_focused = is_focused_container and (if (active_pane) |ap| pane == ap else false);
            switch (pane.content) {
                .terminal => |surface| {
                    const sid: u64 = if (surface.core_surface_initialized) surface.core_surface.id else 0;
                    try buf.writer(alloc).print(
                        "{{\"pane\":{d},\"tab\":{d},\"id\":{d},\"type\":\"terminal\",\"focused\":{},\"title\":",
                        .{ pane_idx, t, sid, is_focused },
                    );
                    try targets.ipcWriteJsonText(self, &buf, pane.titleText());
                    try buf.append(alloc, '}');
                },
                .browser => |browser| {
                    try buf.writer(alloc).print(
                        "{{\"pane\":{d},\"tab\":{d},\"id\":{d},\"type\":\"browser\",\"focused\":{},\"title\":",
                        .{ pane_idx, t, browser.ipc_id, is_focused },
                    );
                    try targets.ipcWriteJsonText(self, &buf, pane.titleText());
                    try buf.append(alloc, '}');
                },
                // Placeholder tabs exist only in the model tests.
                .placeholder => {},
            }
        }
        pane_idx += 1;
    }
    try buf.append(alloc, ']');
    server.sendOk(req.id, buf.items) catch {};
}

/// surface-focus {surface} | {workspace, pane, tab} → focus a surface.
/// With a `surface` id the owning window/workspace/container is found
/// via `ipcFindSurfaceById`, the container is set as focused, and the
/// tab is selected. Otherwise `pane` (container index) and `tab` (tab
/// index within that container) address the target directly.
fn ipcSurfaceFocus(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;

    if (ipcArgU64(req, "surface")) |sid| {
        const loc = targets.ipcFindSurfaceById(self, sid) orelse return IpcError.UnknownSurface;
        loc.window.selectWorkspace(loc.ws_idx);
        if (loc.ws_idx < loc.window.workspaces.items.len) {
            const ws = loc.window.workspaces.items[loc.ws_idx];
            ws.focused_pane = loc.container;
        }
        loc.window.selectTabIndex(loc.tab_idx);
        (loc.surface.tab orelse return IpcError.UnknownSurface).focus();
        server.sendOk(req.id, null) catch {};
        return;
    }

    // Address by (workspace, pane, tab) — pane is the container index in
    // the split tree, tab is the tab index within that container.
    const ws_target = try targets.ipcResolveWorkspace(self, req);
    const pane_idx = ipcArgU32(req, "pane") orelse return IpcError.MissingIndex;
    const container = ws_target.ws.paneAt(pane_idx) orelse return IpcError.UnknownPane;
    const tab_idx: usize = ipcArgU32(req, "tab") orelse container.selected;
    if (tab_idx >= container.tabCount()) return IpcError.UnknownTab;
    const pane = container.tabs.items[tab_idx];
    ws_target.window.selectWorkspace(ws_target.ws_idx);
    ws_target.ws.focused_pane = container;
    container.selected = tab_idx;
    pane.focus();
    server.sendOk(req.id, null) catch {};
}

/// new-split {dir:"right"|"down"|"left"|"up", [workspace],[tab],[pane],[command]}
/// → split the focused Pane (or the one at `pane` index) of the
/// addressed (or active) workspace and reply with the new pane's surface
/// id. With `command`, the split runs that shell (split on whitespace);
/// without it, it inherits the source pane's backend (matching the UI
/// split UX).
fn ipcNewSplit(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const dir_str = ipcArgString(req, "dir") orelse
        ipcArgString(req, "direction") orelse return IpcError.MissingDirection;
    const direction: SplitTree(Pane).Split.Direction = if (std.mem.eql(u8, dir_str, "right"))
        .right
    else if (std.mem.eql(u8, dir_str, "down"))
        .down
    else if (std.mem.eql(u8, dir_str, "left"))
        .left
    else if (std.mem.eql(u8, dir_str, "up"))
        .up
    else
        return IpcError.BadDirection;

    const target = try targets.ipcResolveWorkspace(self, req);
    const window = target.window;
    if (window.is_quick_terminal) return IpcError.QuickTerminal;

    if (ipcArgU32(req, "pane")) |p| {
        target.ws.focused_pane = target.ws.paneAt(p) orelse return IpcError.UnknownPane;
    }

    // Programmatic split defaults to NON-FOCUS: the split is created in the
    // target workspace's focused Pane but the active workspace/tab
    // and OS foreground are NOT changed (a background pane). `--focus`
    // (focus:true) selects the target workspace and focuses the new pane,
    // the interactive split UX. Matches the "create != focus" policy.
    const focus = ipcArgBool(req, "focus") orelse false;
    if (focus) {
        if (target.ws_idx != window.activeIndex()) window.selectWorkspace(target.ws_idx);
    }

    // Parse an optional explicit command once (split on whitespace); an
    // empty/whitespace-only command inherits the source pane's backend.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(self.core_app.alloc);
    if (ipcArgString(req, "command")) |command_str| {
        var it = std.mem.tokenizeAny(u8, command_str, &std.ascii.whitespace);
        while (it.next()) |tok| try argv.append(self.core_app.alloc, tok);
    }
    const explicit: ?[]const []const u8 = if (argv.items.len > 0) argv.items else null;
    const command: ?[]const []const u8 = explicit orelse blk: {
        const src_container = target.ws.focusedPaneOrFirst() orelse break :blk null;
        const src_pane = src_container.selectedTab() orelse break :blk null;
        const src = src_pane.surface() orelse break :blk null;
        break :blk src.spawn_command;
    };

    const new_pane = try window.newSplitInWorkspace(
        target.ws_idx,
        direction,
        command,
        focus,
    );

    const sid: u64 = targets.ipcSurfaceId(new_pane) orelse 0;
    var data_buf: [32]u8 = undefined;
    const data = std.fmt.bufPrint(&data_buf, "{{\"id\":{d}}}", .{sid}) catch
        return error.NoSpaceLeft;
    server.sendOk(req.id, data) catch {};
}

/// swap-split → swap the target window's focused split with the previous
/// one. Args are ignored. (Formerly inline in App.handleIpcRequest.)
fn ipcSwapSplit(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    if (targets.ipcTargetWindow(self)) |win| {
        win.swapSplit(.previous);
    }
    server.sendOk(req.id, null) catch {};
}

/// break-pane: break the active pane of the addressed (or active) tab
/// out of its split into a new tab.
fn ipcBreakPane(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try targets.ipcResolveTab(self, req);
    const pane = target.container.tabs.items[target.tab_idx];
    target.window.breakPane(pane);
    server.sendOk(req.id, null) catch {};
}

/// move-pane: move the active pane of the addressed (or active) tab to
/// an adjacent tab. Args: {direction:"next"|"prev"|"new", [workspace],
/// [tab]}.
fn ipcMovePaneToTab(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try targets.ipcResolveTab(self, req);
    const pane = target.container.tabs.items[target.tab_idx];

    const dir_str: ?[]const u8 = if (req.args == .object)
        if (req.args.object.get("direction")) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null
    else
        null;
    const move_target: apprt.action.MovePaneTarget = if (dir_str) |d| blk: {
        if (std.mem.eql(u8, d, "next")) break :blk .next_tab;
        if (std.mem.eql(u8, d, "prev")) break :blk .prev_tab;
        if (std.mem.eql(u8, d, "new")) break :blk .new_tab;
        return IpcError.BadDirection;
    } else .next_tab;

    target.window.movePaneToTab(pane, move_target);
    server.sendOk(req.id, null) catch {};
}
