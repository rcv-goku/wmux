//! The v2 router (ARCHITECTURE.md ADR-2.4, ADR-2.6, ADR-3.9): resolves the
//! selectors of a request (UUID, ref or index) to model objects on the UI
//! thread. `Ctx.resolveWindow/Workspace/Pane/Tab` (rpc/types.zig) call
//! these.
//!
//! - Explicit selectors win in the order window_id → group_id →
//!   workspace_id → surface_id (terminal_id, tab_id) → pane_id and fail
//!   closed (`not_found` with cmux's strings) when they do not resolve.
//! - Without an explicit selector the caller context (`params.caller`
//!   workspace/surface, validated: a stale caller fails closed) decides,
//!   then the active window: the most recently activated wmux window
//!   (tracked from WM_ACTIVATE by features/system), never
//!   `GetForegroundWindow()`; before any activation (hidden test
//!   instances never activate) the first open window.
//! - A workspace index is its display position (model/logic/
//!   display_order.zig, AF-22) in the explicit window, else the caller's
//!   window, else the active window. Pane and surface indexes follow
//!   ADR-2.4 (model/registry.zig).
//!
//! W1-1b adds the client-PID caller (the surface job of the connecting
//! process) on top of `params.caller`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");

const App = @import("../App.zig");
const Group = @import("../model/Group.zig");
const Pane = @import("../model/Pane.zig");
const Tab = @import("../model/Tab.zig");
const Window = @import("../ui/Window.zig");
const Workspace = @import("../model/Workspace.zig");
const display_order = @import("../model/logic/display_order.zig");
const model_registry = @import("../model/registry.zig");
const rules = @import("logic/router_rules.zig");
const types = @import("types.zig");

const Ctx = types.Ctx;
const Error = types.Error;
const Selectors = types.Selectors;
const HandleText = types.HandleText;
const Kind = proto.handles.Kind;
const Uuid = proto.uuid.Uuid;

// ---------------------------------------------------------------------------
// Active window (UI thread only)
// ---------------------------------------------------------------------------

var last_activated: ?Uuid = null;

/// WM_ACTIVATE of `window` (features/system window hook).
pub fn noteActivated(window: *const Window) void {
    if (window.is_quick_terminal) return;
    last_activated = window.handle.uuid;
}

fn usable(w: *const Window) bool {
    return !w.closing and !w.is_quick_terminal and w.selected != null;
}

/// The active window: the most recently activated open window, else the
/// first open window; null when none is open.
pub fn activeWindow(app: *App) ?*Window {
    if (last_activated) |id| {
        if (app.handles.get(Window, .window, id)) |w| {
            if (usable(w)) return w;
        }
    }
    for (app.windows.items) |w| if (usable(w)) return w;
    return null;
}

// ---------------------------------------------------------------------------
// Display order
// ---------------------------------------------------------------------------

/// The display order of `window`'s workspaces (element i = position in
/// `window.workspaces` of display row i), allocated in `arena`.
pub fn displayOrder(arena: Allocator, window: *const Window) Allocator.Error![]usize {
    return display_order.fromModel(arena, window.workspaces.items, window.groups.items);
}

/// The workspace at display index `index` of `window`.
pub fn workspaceAtDisplay(arena: Allocator, window: *const Window, index: usize) Allocator.Error!?*Workspace {
    const order = try displayOrder(arena, window);
    const i = rules.listIndexOfDisplay(order, index) orelse return null;
    return window.workspaces.items[i];
}

/// The display index of `ws` in its window, or null.
pub fn displayIndexOf(arena: Allocator, ws: *const Workspace) Allocator.Error!?usize {
    const window = ws.window;
    const list_index = window.workspaceIndex(ws);
    if (list_index >= window.workspaces.items.len) return null;
    const order = try displayOrder(arena, window);
    return rules.displayOfListIndex(order, list_index);
}

// ---------------------------------------------------------------------------
// Resolution
// ---------------------------------------------------------------------------

fn notFound(ctx: *Ctx, kind: Kind) Error {
    return ctx.fail(.not_found, rules.notFoundMessage(kind), .{ .selector = rules.selectorKey(kind) });
}

fn oom(ctx: *Ctx) Error {
    return ctx.fail(.internal_error, "Out of memory", null);
}

fn noTarget(ctx: *Ctx) Error {
    return ctx.fail(.not_found, proto.errors.msg.no_focused_surface, null);
}

/// The window an explicit window_id names (an index counts in
/// `App.windows`, creation order).
fn explicitWindow(ctx: *Ctx, h: HandleText) Error!*Window {
    const w = model_registry.resolveWindow(ctx.app, h) orelse return notFound(ctx, .window);
    if (w.closing) return notFound(ctx, .window);
    return w;
}

fn explicitGroup(ctx: *Ctx, h: HandleText, window: ?*Window) Error!*Group {
    switch (h) {
        .index => |i| {
            const w = window orelse (activeWindow(ctx.app) orelse return notFound(ctx, .workspace_group));
            if (i >= w.groups.items.len) return notFound(ctx, .workspace_group);
            return w.groups.items[i];
        },
        else => {
            const e = ctx.app.handles.lookup(.workspace_group, h) orelse return notFound(ctx, .workspace_group);
            const g: *Group = @ptrCast(@alignCast(e.ptr));
            if (window) |w| if (g.window != w) return notFound(ctx, .workspace_group);
            return g;
        },
    }
}

/// The tab an explicit surface selector names. An index counts in the
/// explicit pane, else the explicit or contextual workspace.
fn explicitTab(ctx: *Ctx, sel: Selectors, h: HandleText) Error!*Tab {
    switch (h) {
        .index => {
            const scope: model_registry.SurfaceScope = if (sel.pane != null)
                .{ .pane = try resolvePane(ctx, .{ .window = sel.window, .workspace = sel.workspace, .pane = sel.pane }) }
            else
                .{ .workspace = try resolveWorkspace(ctx, .{ .window = sel.window, .workspace = sel.workspace }) };
            return model_registry.resolveSurface(ctx.app, scope, h) orelse notFound(ctx, .surface);
        },
        else => {
            const tab = model_registry.resolveSurface(ctx.app, .none, h) orelse return notFound(ctx, .surface);
            // Explicit outer selectors must agree with the surface.
            if (sel.workspace != null or sel.window != null) {
                const ws = try resolveWorkspace(ctx, .{ .window = sel.window, .workspace = sel.workspace });
                const pane = tab.pane orelse return notFound(ctx, .surface);
                if (pane.workspace != ws) return notFound(ctx, .surface);
            }
            return tab;
        },
    }
}

/// The caller context's workspace (`params.caller`): its surface's
/// workspace, else its workspace. A caller that names a gone object fails
/// closed. Null when the request has no caller.
fn callerWorkspace(ctx: *Ctx) Error!?*Workspace {
    const c = ctx.caller orelse return null;
    if (c.surface) |h| {
        const tab = model_registry.resolveSurface(ctx.app, .none, h) orelse return notFound(ctx, .surface);
        const pane = tab.pane orelse return notFound(ctx, .surface);
        return pane.workspace orelse notFound(ctx, .surface);
    }
    if (c.workspace) |h| {
        if (h == .index) {
            const w = activeWindow(ctx.app) orelse return notFound(ctx, .workspace);
            return (workspaceAtDisplay(ctx.arena, w, h.index) catch return oom(ctx)) orelse notFound(ctx, .workspace);
        }
        return model_registry.resolveWorkspace(ctx.app, null, h) orelse notFound(ctx, .workspace);
    }
    return null;
}

fn callerTab(ctx: *Ctx) Error!?*Tab {
    const c = ctx.caller orelse return null;
    const h = c.surface orelse return null;
    return model_registry.resolveSurface(ctx.app, .none, h) orelse notFound(ctx, .surface);
}

/// The window a workspace index counts in (rules.workspaceIndexScope).
fn indexWindow(ctx: *Ctx, sel: Selectors) Error!*Window {
    return switch (rules.workspaceIndexScope(sel, ctx.caller)) {
        .window => explicitWindow(ctx, sel.window.?),
        .caller => if (try callerWorkspace(ctx)) |ws| ws.window else (activeWindow(ctx.app) orelse notFound(ctx, .window)),
        .active => activeWindow(ctx.app) orelse notFound(ctx, .window),
    };
}

fn explicitWorkspace(ctx: *Ctx, sel: Selectors, h: HandleText) Error!*Workspace {
    switch (h) {
        .index => |i| {
            const w = try indexWindow(ctx, sel);
            return (workspaceAtDisplay(ctx.arena, w, i) catch return oom(ctx)) orelse notFound(ctx, .workspace);
        },
        else => {
            const window: ?*Window = if (sel.window) |wh| try explicitWindow(ctx, wh) else null;
            const ws = model_registry.resolveWorkspace(ctx.app, window, h) orelse return notFound(ctx, .workspace);
            if (ws.window.closing) return notFound(ctx, .workspace);
            return ws;
        },
    }
}

/// The target window (ADR-2.6 precedence).
pub fn resolveWindow(ctx: *Ctx, sel: Selectors) Error!*Window {
    return switch (rules.primary(sel, ctx.caller)) {
        .window => explicitWindow(ctx, sel.window.?),
        .group => (try explicitGroup(ctx, sel.group.?, null)).window,
        .workspace => (try explicitWorkspace(ctx, sel, sel.workspace.?)).window,
        .surface => blk: {
            const tab = try explicitTab(ctx, sel, sel.surface.?);
            const pane = tab.pane orelse return notFound(ctx, .surface);
            const ws = pane.workspace orelse return notFound(ctx, .surface);
            break :blk ws.window;
        },
        .pane => blk: {
            const pane = try resolvePane(ctx, sel);
            const ws = pane.workspace orelse return notFound(ctx, .pane);
            break :blk ws.window;
        },
        .caller => if (try callerWorkspace(ctx)) |ws| ws.window else (activeWindow(ctx.app) orelse noTarget(ctx)),
        .active => activeWindow(ctx.app) orelse noTarget(ctx),
    };
}

/// The target workspace: the explicit one, else the workspace of the
/// explicit surface/pane, else the anchor (or first member) of the explicit
/// group, else the selected workspace of the explicit window, else the
/// caller's workspace, else the active window's selected workspace.
pub fn resolveWorkspace(ctx: *Ctx, sel: Selectors) Error!*Workspace {
    if (sel.workspace) |h| return explicitWorkspace(ctx, sel, h);
    if (sel.surface) |h| {
        const tab = try explicitTab(ctx, sel, h);
        const pane = tab.pane orelse return notFound(ctx, .surface);
        return pane.workspace orelse notFound(ctx, .surface);
    }
    if (sel.pane) |h| {
        // A pane index counts in the contextual workspace, which it is in.
        if (h == .index) {
            const ws = try resolveWorkspace(ctx, .{ .window = sel.window, .group = sel.group });
            _ = model_registry.resolvePane(ctx.app, ws, h) orelse return notFound(ctx, .pane);
            return ws;
        }
        const window: ?*Window = if (sel.window) |wh| try explicitWindow(ctx, wh) else null;
        const pane = model_registry.resolvePane(ctx.app, null, h) orelse return notFound(ctx, .pane);
        const ws = pane.workspace orelse return notFound(ctx, .pane);
        if (window) |w| if (ws.window != w) return notFound(ctx, .pane);
        return ws;
    }
    if (sel.group) |h| {
        const window: ?*Window = if (sel.window) |wh| try explicitWindow(ctx, wh) else null;
        const g = try explicitGroup(ctx, h, window);
        if (g.anchor) |a| if (a.group == g) return a;
        for (g.window.workspaces.items) |ws| if (ws.group == g) return ws;
        return notFound(ctx, .workspace);
    }
    if (sel.window) |wh| {
        const w = try explicitWindow(ctx, wh);
        return w.selected orelse notFound(ctx, .workspace);
    }
    if (try callerWorkspace(ctx)) |ws| return ws;
    const w = activeWindow(ctx.app) orelse return noTarget(ctx);
    return w.selected orelse noTarget(ctx);
}

/// The target pane: the explicit one (an index counts in the resolved
/// workspace), else the pane of the explicit surface, else the caller's
/// surface's pane, else the focused pane of the resolved workspace.
pub fn resolvePane(ctx: *Ctx, sel: Selectors) Error!*Pane {
    if (sel.pane) |h| {
        if (h == .index) {
            const ws = try resolveWorkspace(ctx, .{ .window = sel.window, .group = sel.group, .workspace = sel.workspace });
            return model_registry.resolvePane(ctx.app, ws, h) orelse notFound(ctx, .pane);
        }
        const pane = model_registry.resolvePane(ctx.app, null, h) orelse return notFound(ctx, .pane);
        if (sel.workspace != null or sel.window != null) {
            const ws = try resolveWorkspace(ctx, .{ .window = sel.window, .workspace = sel.workspace });
            if (pane.workspace != ws) return notFound(ctx, .pane);
        }
        return pane;
    }
    if (sel.surface) |h| {
        const tab = try explicitTab(ctx, sel, h);
        return tab.pane orelse notFound(ctx, .surface);
    }
    if (sel.isEmpty()) {
        if (try callerTab(ctx)) |tab| return tab.pane orelse notFound(ctx, .surface);
    }
    const ws = try resolveWorkspace(ctx, sel);
    return ws.focusedPaneOrFirst() orelse noTarget(ctx);
}

/// The target surface (tab): the explicit one, else the caller's surface,
/// else the selected tab of the resolved pane.
pub fn resolveTab(ctx: *Ctx, sel: Selectors) Error!*Tab {
    if (sel.surface) |h| return explicitTab(ctx, sel, h);
    if (sel.isEmpty()) {
        if (try callerTab(ctx)) |tab| return tab;
    }
    const pane = try resolvePane(ctx, sel);
    return pane.selectedTab() orelse noTarget(ctx);
}
