//! Session restore (ARCHITECTURE.md ADR-9.4, 9.6, ADR-2.7): rebuild the
//! windows, workspaces, groups, panes and tabs of a v3 session with their
//! saved identities (`HandleRegistry.adopt`: UUIDs and refs survive), the
//! feature `ext` state, then bring the content up staggered.
//!
//! Order: windows and their structure first, every tab as a placeholder
//! (no process yet); then the terminals of each window's shown workspace
//! spawn at once and the rest follow one every 30 ms (app.timers), so a
//! big session never starts dozens of shells in one go. Every tab is
//! spawned with its saved surface UUID (`CMUX_SURFACE_ID`, ADR-3.9) in
//! the tab cwd, else the workspace cwd, else %USERPROFILE% when the saved
//! directory is gone (ADR-9.6). The queue holds UUIDs and re-resolves
//! them (a tab closed meanwhile is skipped).
//!
//! Restore replaces state: window 0 (created by App.run) takes the first
//! saved window, its first workspace object takes the first saved
//! workspace (re-keyed) and loses its throwaway terminal; nothing is
//! appended into an existing window. Old terminals are torn down before
//! any new one exists and the core mailbox is drained right after, so a
//! stale `close`/child-exited message for a freed surface can never land
//! on a new surface allocated at the same address (the W0-ST "workspace 1
//! disappears after restore" bug of the legacy restore).

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("../../App.zig");
const BrowserPane = @import("../../web/BrowserPane.zig");
const Group = @import("../../model/Group.zig");
const Pane = @import("../../model/Pane.zig");
const SplitTree = @import("../../../../datastruct/split_tree.zig").SplitTree;
const Surface = @import("../../Surface.zig");
const Tab = @import("../../model/Tab.zig");
const Window = @import("../../ui/Window.zig");
const Workspace = @import("../../model/Workspace.zig");
const autosave = @import("autosave.zig");
const emit = @import("../../model/ops/lifecycle_events.zig");
const handle_registry = @import("../../model/logic/handle_registry.zig");
const ids = @import("../../model/ids.zig");
const integrity = @import("logic/integrity.zig");
const markers = @import("markers.zig");
const ops_pane = @import("../../model/ops/pane.zig");
const ops_surface = @import("../../model/ops/surface.zig");
const ops_window = @import("../../model/ops/window.zig");
const placement_io = @import("placement_io.zig");
const schema = @import("logic/schema_v3.zig");
const settings = @import("../../settings/api.zig");
const app_tasks = @import("../../app/tasks.zig");
const app_timers = @import("../../app/timers.zig");
const w32 = @import("../../platform/win32.zig");

const log = std.log.scoped(.session);

/// The stagger step between two deferred spawns (ADR-9.4).
pub const stagger_ms: u32 = 30;

const SW_SHOWNA: i32 = 8;

extern "user32" fn IsWindowVisible(hwnd: w32.HWND) callconv(.winapi) i32;

pub const Options = struct {
    /// Spawn the hidden workspaces' content one every `stagger_ms`.
    stagger: bool = true,
    /// Apply the saved window placements.
    placement: bool = true,
    /// Restore every saved window (false: only the first, into window 0).
    all_windows: bool = true,
};

// ── Entry points ────────────────────────────────────────────────────

/// The feature's `init` (App.init, before the first window): create the
/// session runtime, seed the handle registry, decide whether this launch
/// restores (ADR-9.4: WMUX/CMUX_DISABLE_SESSION_RESTORE, test mode without
/// WMUX_TEST_SESSION_RESTORE, an explicit launch intent, or a crashed
/// previous restore skip it), load or migrate the session, mark the
/// restore in progress (`session.restoring`) and schedule it; then start
/// the autosave.
pub fn launchInit(app: *App) void {
    const core = autosave.create(app) orelse return;
    const gpa = core.gpa;
    const dir = core.session_dir;
    autosave.seedHandles(core);

    // An instance that did not exit cleanly (ADR-9.8): its marker remains
    // and its process is gone. Scrollback merge and agent recovery come
    // with W1-7b/W3-5; the notice tells the user what happened.
    if (markers.readRunning(gpa, dir)) |m| {
        const owner = markers.liveness(m);
        if (owner == .alive_same and m.pid != markers.currentPid()) {
            log.warn("session state is in use by process {d}; this instance neither restores nor autosaves", .{m.pid});
            autosave.destroyKeepRunning(app);
            return;
        }
        if (integrity.isUncleanExit(m, owner)) autosave.deferNotice(core, .{
            .id = "session.unclean_exit",
            .level = .warning,
            .title = "wmux did not exit cleanly last time",
            .body = "The last saved session is restored.",
        });
    }
    markers.writeRunning(dir);

    core.saving = settings.get(app, "wmux.session.autosave");
    const decision = integrity.decideLaunch(.{
        .restore_disabled = app.runtime_env.disable_session_restore or !settings.get(app, "wmux.session.restoreOnLaunch"),
        .test_mode = app.runtime_env.test_mode,
        .test_session_restore = app.runtime_env.test_session_restore,
        .explicit_intent = explicitLaunchIntent(gpa),
        .restoring_marker = markers.exists(dir, integrity.restoring_marker),
    });
    if (decision.rotate_crashed) {
        var buf: [64]u8 = undefined;
        const name = markers.rotateCrashed(dir, &buf);
        log.warn("the previous session restore crashed; skipped restore, snapshot moved to {s}", .{name orelse "(none)"});
        if (decision.crash_notice) showCrashNotice(core, name);
    }
    if (decision.restore) {
        if (@import("migrate.zig").loadForLaunch(core)) |parsed| {
            if (parsed.session.windows.len > 0) {
                autosave.seedFromSession(app, &parsed.session);
                core.pending = parsed;
                core.restoring = true;
                markers.writeRestoring(dir);
                // Runs as the first task of the message loop (below).
            } else parsed.deinit();
        }
    }
    autosave.startTimer(core);
    autosave.registerRestart(app);
    // The first task of the message loop: the startup notices, then the
    // restore (when one is pending).
    postLaunchRestore(app);
}

/// Whether wmux was launched to open something specific (ADR-9.4): a
/// path or URL argument, `-e`, `--command` or `--working-directory`.
/// Configuration flags (`--config-file=...`) are not an intent.
fn explicitLaunchIntent(gpa: Allocator) bool {
    const args = std.process.argsAlloc(gpa) catch return false;
    defer std.process.argsFree(gpa, args);
    return isExplicitIntent(args[@min(1, args.len)..]);
}

pub fn isExplicitIntent(args: []const []const u8) bool {
    for (args) |a| {
        if (a.len == 0) continue;
        if (std.mem.eql(u8, a, "-e")) return true;
        if (std.mem.startsWith(u8, a, "--command") or std.mem.startsWith(u8, a, "--working-directory")) return true;
        if (std.mem.eql(u8, a, "--restore")) continue;
        if (a[0] != '-' and a[0] != '+') return true;
    }
    return false;
}

/// The launch restore (feature init found a session to restore): runs as
/// the first task of the message loop, once App.run created window 0.
pub fn postLaunchRestore(app: *App) void {
    const gpa = app.core_app.alloc;
    const t = gpa.create(LaunchTask) catch {
        log.err("session restore could not be scheduled (out of memory)", .{});
        return;
    };
    t.* = .{ .gpa = gpa };
    app.tasks.post(&t.task);
}

const LaunchTask = struct {
    task: app_tasks.Task = .{ .run = run, .destroy = destroy },
    gpa: Allocator,

    fn run(app: *App, task: *app_tasks.Task) void {
        _ = task;
        autosave.flushNotices(app);
        runLaunch(app);
    }

    fn destroy(task: *app_tasks.Task) void {
        const self: *LaunchTask = @fieldParentPtr("task", task);
        self.gpa.destroy(self);
    }
};

fn runLaunch(app: *App) void {
    const core = autosave.get(app) orelse return;
    const parsed = core.pending orelse return;
    log.info("restoring the session: {d} window(s)", .{parsed.session.windows.len});
    apply(app, &parsed.session, .{}) catch |err| {
        log.err("session restore failed err={}", .{err});
        finish(app);
    };
}

/// Restore `s` into the app (UI thread): replaces window 0's content and
/// creates the other windows. With `opts.stagger` the hidden content
/// follows from a timer and the restore finishes (`finish`) when the last
/// tab is up; otherwise everything spawns before this returns.
pub fn apply(app: *App, s: *const schema.Session, opts: Options) !void {
    const gpa = app.core_app.alloc;
    var plan: Plan = .{ .gpa = gpa };
    errdefer plan.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Windows: window 0 is App.run's; the others are created here.
    const count = if (opts.all_windows) s.windows.len else @min(s.windows.len, 1);
    const targets = try arena.alloc(*Window, count);
    var built: usize = 0;
    for (s.windows[0..count], 0..) |*sw, i| {
        const window = if (i == 0) (try firstWindow(app)) else (newWindow(app) catch |err| {
            log.warn("could not create restored window {d} err={}", .{ i, err });
            break;
        });
        targets[i] = window;
        built = i + 1;
        plan.window_index = i;
        try buildWindow(app, window, sw, &plan);
    }

    // The replaced terminals are gone: drain their queued core messages
    // before any new surface can be allocated where an old one lived.
    app.core_app.tick(app) catch |err| log.warn("core tick after teardown failed err={}", .{err});

    // Placement and showing.
    for (targets[0..built], s.windows[0..built], 0..) |window, *sw, i| {
        showWindow(app, window, sw, i == 0, opts.placement);
    }

    // Content: the shown workspaces now, the rest staggered (or now).
    const order = try schema.spawnOrder(arena, s);
    for (order) |r| {
        if (r.window >= built) continue;
        const idx = plan.indexOf(r) orelse continue;
        const item = &plan.items.items[idx];
        item.handled = true;
        if (r.immediate or !opts.stagger) {
            _ = spawn(app, item);
        } else {
            try plan.deferred.append(gpa, item.*);
            item.owned_by_deferred = true;
        }
    }
    // Tabs the order does not name (the terminal an empty saved workspace
    // gets) come up now.
    for (plan.items.items) |*item| if (!item.handled) {
        item.handled = true;
        _ = spawn(app, item);
    };
    for (targets[0..built]) |window| refreshWindow(window, true);

    const core = autosave.get(app);
    if (plan.deferred.items.len == 0 or core == null) {
        // Nothing deferred (or no runtime to own a timer queue): done.
        for (plan.deferred.items) |*item| spawnDeferred(app, item);
        plan.deinit();
        finish(app);
        return;
    }
    // The deferred items now own their strings; the plan keeps only them.
    const sp = try gpa.create(Spawner);
    sp.* = .{ .gpa = gpa, .items = plan.deferred };
    plan.deferred = .empty;
    plan.deinit();
    if (core.?.spawner) |old| old.destroy();
    core.?.spawner = sp;
    sp.schedule(app);
}

/// The restore is complete: drop `session.restoring`, free the pending
/// session, let the autosave run (and save the restored state once).
pub fn finish(app: *App) void {
    const core = autosave.get(app) orelse return;
    core.dirty = true;
    // An explicit (legacy) restore while no launch restore runs.
    if (!core.restoring) return;
    markers.clearRestoring(core.session_dir);
    core.restoring = false;
    if (core.pending) |p| p.deinit();
    core.pending = null;
    if (core.spawner) |sp| sp.destroy();
    core.spawner = null;
    log.info("session restore finished", .{});
}

// ── Windows ─────────────────────────────────────────────────────────

fn firstWindow(app: *App) !*Window {
    for (app.windows.items) |w| if (!w.is_quick_terminal and !w.closing) return w;
    return newWindow(app);
}

fn newWindow(app: *App) !*Window {
    const gpa = app.core_app.alloc;
    const window = try gpa.create(Window);
    errdefer gpa.destroy(window);
    try window.init(app, .{});
    app.windows.append(gpa, window) catch |err| {
        window.deinit();
        return err;
    };
    return window;
}

fn showWindow(app: *App, window: *Window, sw: *const schema.Window, is_first: bool, placement: bool) void {
    const hwnd = window.hwnd orelse return;
    const visible = IsWindowVisible(hwnd) != 0;
    if (placement and !app.runtime_env.test_hidden) {
        if (sw.placement) |p| {
            placement_io.apply(app, window, p, if (is_first or visible) SW_SHOWNA else w32.SW_SHOWNOACTIVATE);
            return;
        }
    }
    if (!visible) app_foregroundShow(app, hwnd);
}

fn app_foregroundShow(app: *App, hwnd: w32.HWND) void {
    @import("../../app/foreground.zig").showTopLevel(app, hwnd, w32.SW_SHOWNOACTIVATE);
}

/// Lay out the shown workspace after its content changed.
fn refreshWindow(window: *Window, focus: bool) void {
    if (window.closing) return;
    window.updateTabBarVisibility();
    window.layoutSplits();
    if (focus) {
        if (window.getActiveTab()) |tab| tab.focus();
    }
    window.updateWindowTitle();
    window.invalidateTabBar();
    window.invalidateSidebar();
    window.updateAttentionRings();
    window.updatePaneButtons();
}

/// Give `window` the saved window `sw`: identity, chrome state, then its
/// workspaces (re-keying the first existing one, creating the others,
/// closing existing ones the session does not have).
fn buildWindow(app: *App, window: *Window, sw: *const schema.Window, plan: *Plan) !void {
    const gpa = app.core_app.alloc;
    try adoptHandle(app, window, .window, sw.id, sw.ref);
    try restoreObjectExt(gpa, &window.ext, sw.ext);
    window.sidebar_hidden = !sw.sidebar.visible;
    if (sw.sidebar.width != window.app.config.@"window-sidebar-width") window.sidebar_width_override = @intCast(sw.sidebar.width);
    if (window.app.config.@"window-show-right-sidebar") window.right_sidebar_hidden = !sw.right_sidebar.visible;

    // Groups the session does not know are dropped (restore replaces).
    for (window.workspaces.items) |ws| ws.group = null;
    for (window.groups.items) |g| g.destroy(gpa);
    window.groups.clearRetainingCapacity();
    for (sw.groups) |*sg| {
        const g = try Group.create(gpa, window, sg.name);
        adoptHandle(app, g, .workspace_group, sg.id, sg.ref) catch |err| {
            g.destroy(gpa);
            return err;
        };
        g.collapsed = sg.collapsed;
        g.pinned = sg.pinned;
        window.groups.append(gpa, g) catch |err| {
            g.destroy(gpa);
            return err;
        };
    }

    const old_count = window.workspaces.items.len;
    const previous = window.selected;
    var first_reused = false;
    for (sw.workspaces, 0..) |*sws, j| {
        var ws: *Workspace = undefined;
        var is_new = true;
        if (j == 0 and old_count > 0) {
            ws = window.workspaces.items[0];
            is_new = false;
            first_reused = true;
            try adoptHandle(app, ws, .workspace, sws.id, sws.ref);
            resetWorkspace(gpa, ws);
        } else {
            ws = try Workspace.create(gpa, window);
            adoptHandle(app, ws, .workspace, sws.id, sws.ref) catch |err| {
                ws.destroy(gpa);
                return err;
            };
            window.workspaces.append(gpa, ws) catch |err| {
                ws.destroy(gpa);
                return err;
            };
        }
        try fillWorkspace(gpa, window, ws, sws);
        if (is_new) emit.workspace(window, ws, "workspace.created");
        const tree = try buildTree(app, window, ws, sws, plan, j);
        // The old tree (window 0's throwaway terminal) goes; the new one
        // announces its panes and tabs.
        ws.focused_pane = null;
        ops_pane.installRestoredTree(window, ws, tree);
        selectInWorkspace(ws, sws);
    }

    // Existing workspaces past the reused one are not in the session.
    const keep = if (first_reused) @as(usize, 1) else 0;
    var drop = old_count -| keep;
    while (drop > 0) : (drop -= 1) {
        if (window.workspaces.items.len <= 1) break;
        ops_window.closeWorkspace(window, keep);
    }

    // Selection.
    if (schema.selectedWorkspaceIndex(sw)) |i| {
        if (i < window.workspaces.items.len) window.selected = window.workspaces.items[i];
    }
    if (window.selected == null and window.workspaces.items.len > 0) window.selected = window.workspaces.items[0];
    // Hide what a previously shown workspace still shows.
    for (window.workspaces.items) |ws| {
        if (ws == window.selected) continue;
        var it = ws.tree.iterator();
        while (it.next()) |entry| if (entry.view.selectedHwnd()) |h| {
            _ = w32.ShowWindow(h, w32.SW_HIDE);
        };
    }
    if (window.selected) |sel| if (previous != sel) emit.workspaceSelected(window, sel, previous);

    // Group references.
    for (sw.workspaces, 0..) |*sws, j| {
        if (j >= window.workspaces.items.len) break;
        const ws = window.workspaces.items[j];
        if (sws.group) |gid| ws.group = findGroup(window, gid);
    }
    for (sw.groups, 0..) |*sg, gi| {
        if (gi >= window.groups.items.len) break;
        if (sg.anchor) |aid| window.groups.items[gi].anchor = findWorkspace(window, aid);
    }
}

fn findGroup(window: *Window, id: []const u8) ?*Group {
    const u = ids.Uuid.parse(id) catch return null;
    for (window.groups.items) |g| if (g.handle.uuid.eql(u)) return g;
    return null;
}

fn findWorkspace(window: *Window, id: []const u8) ?*Workspace {
    const u = ids.Uuid.parse(id) catch return null;
    for (window.workspaces.items) |ws| if (ws.handle.uuid.eql(u)) return ws;
    return null;
}

/// Clear what the re-keyed workspace carried before (its title, cwd,
/// description, environment); its tree is replaced by installRestoredTree.
fn resetWorkspace(gpa: Allocator, ws: *Workspace) void {
    ws.title.deinit(gpa);
    if (ws.description) |d| gpa.free(d);
    ws.description = null;
    ws.freeCwd(gpa);
    var it = ws.env.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        gpa.free(e.value_ptr.*);
    }
    ws.env.clearRetainingCapacity();
    ws.pinned = false;
}

fn fillWorkspace(gpa: Allocator, window: *Window, ws: *Workspace, sws: *const schema.Workspace) !void {
    _ = window;
    try setTitle(gpa, &ws.title, sws.title, null);
    if (sws.description) |d| try ws.setDescriptionUtf8(gpa, d);
    if (sws.cwd) |c| if (c.len > 0) try ws.setCwd(gpa, c);
    for (sws.env) |e| {
        const k = try gpa.dupe(u8, e.name);
        errdefer gpa.free(k);
        const v = try gpa.dupe(u8, e.value);
        errdefer gpa.free(v);
        const gop = try ws.env.getOrPut(gpa, k);
        if (gop.found_existing) {
            gpa.free(k);
            gpa.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = v;
    }
    ws.pinned = sws.pinned;
    try restoreObjectExt(gpa, &ws.ext, sws.ext);
}

/// Focused pane, zoom and each pane's selected tab of a built workspace.
fn selectInWorkspace(ws: *Workspace, sws: *const schema.Workspace) void {
    ws.focused_pane = null;
    if (sws.focused_pane) |fid| ws.focused_pane = paneById(ws, fid);
    if (ws.focused_pane == null) {
        var it = ws.tree.iterator();
        if (it.next()) |entry| ws.focused_pane = entry.view;
    }
    if (sws.zoomed_pane) |zid| {
        if (paneById(ws, zid)) |p| {
            if (ws.tree.isSplit()) if (ws.paneHandle(p)) |h| ws.tree.zoom(h);
        }
    }
    ws.syncZoomed();
}

fn paneById(ws: *Workspace, id: []const u8) ?*Pane {
    const u = ids.Uuid.parse(id) catch return null;
    var it = ws.tree.iterator();
    while (it.next()) |entry| if (entry.view.handle.uuid.eql(u)) return entry.view;
    return null;
}

// ── Tree, panes, tabs ───────────────────────────────────────────────

fn buildTree(app: *App, window: *Window, ws: *Workspace, sws: *const schema.Workspace, plan: *Plan, ws_index: usize) !SplitTree(Pane) {
    if (sws.layout) |layout| return buildNode(app, window, ws, sws, layout, plan, ws_index);
    // A saved workspace without panes still gets one terminal (every
    // workspace has a tab), in the workspace's directory.
    const gpa = app.core_app.alloc;
    const synthetic = [_]schema.Pane{.{ .tabs = @constCast(&[_]schema.Tab{.{}}) }};
    const empty: schema.Workspace = .{ .cwd = sws.cwd, .panes = @constCast(&synthetic) };
    const pane = try buildPane(app, window, ws, &empty, 0, plan, std.math.maxInt(usize));
    return SplitTree(Pane).init(gpa, pane) catch |err| {
        freeDetachedPane(gpa, pane);
        return err;
    };
}

fn buildNode(app: *App, window: *Window, ws: *Workspace, sws: *const schema.Workspace, l: schema.Layout, plan: *Plan, ws_index: usize) anyerror!SplitTree(Pane) {
    const gpa = app.core_app.alloc;
    switch (l) {
        .pane => |id| {
            const pi = paneIndex(sws, id) orelse return error.UnknownPane;
            const pane = try buildPane(app, window, ws, sws, pi, plan, ws_index);
            return SplitTree(Pane).init(gpa, pane) catch |err| {
                freeDetachedPane(gpa, pane);
                return err;
            };
        },
        .split => |s| {
            var a = try buildNode(app, window, ws, sws, s.a, plan, ws_index);
            defer a.deinit();
            var b = try buildNode(app, window, ws, sws, s.b, plan, ws_index);
            defer b.deinit();
            const dir: SplitTree(Pane).Split.Direction = switch (s.dir) {
                .horizontal => .right,
                .vertical => .down,
            };
            return a.split(gpa, .root, dir, @floatCast(schema.sanitizeRatio(s.ratio)), &b);
        },
    }
}

fn paneIndex(sws: *const schema.Workspace, id: []const u8) ?usize {
    for (sws.panes, 0..) |p, i| if (p.id) |pid| if (std.mem.eql(u8, pid, id)) return i;
    return null;
}

/// A pane whose tree failed to take it: release its tabs and free it.
fn freeDetachedPane(gpa: Allocator, pane: *Pane) void {
    while (pane.tabCount() > 0) ops_surface.remove(pane, pane.tabCount() - 1).unref(gpa);
    if (pane.registry) |r| r.retire(pane.handle.uuid);
    pane.ext.session.deinit(gpa);
    pane.tabs.deinit(gpa);
    gpa.destroy(pane);
}

fn buildPane(app: *App, window: *Window, ws: *Workspace, sws: *const schema.Workspace, pi: usize, plan: *Plan, ws_index: usize) !*Pane {
    _ = window;
    const gpa = app.core_app.alloc;
    const sp = &sws.panes[pi];
    const pane = try Pane.create(gpa);
    errdefer freeDetachedPane(gpa, pane);
    try adoptHandle(app, pane, .pane, sp.id, sp.ref);
    pane.workspace = ws;
    try restoreObjectExt(gpa, &pane.ext, sp.ext);
    for (sp.tabs, 0..) |*st, ti| {
        const tab = try placeholderTab(app, st);
        ops_surface.insert(gpa, pane, tab, pane.tabCount()) catch |err| {
            tab.unref(gpa);
            return err;
        };
        try plan.add(gpa, tab, st, .{ .window = plan.window_index, .workspace = ws_index, .pane = pi, .tab = ti, .immediate = false }, sws.cwd);
    }
    pane.selected = 0;
    if (sp.selected_tab) |sel| {
        for (sp.tabs, 0..) |t, i| if (t.id) |id| if (std.mem.eql(u8, id, sel)) {
            pane.selected = @min(i, pane.tabCount() -| 1);
        };
    }
    return pane;
}

/// A detached tab without content holding the reference its pane will
/// own, registered with the saved identity.
fn placeholderTab(app: *App, st: *const schema.Tab) !*Tab {
    const gpa = app.core_app.alloc;
    const tab = try gpa.create(Tab);
    tab.* = .{ .content = .{ .placeholder = .{} } };
    _ = tab.ref(gpa) catch unreachable;
    errdefer tab.unref(gpa);
    try adoptHandle(app, tab, .surface, st.id, st.ref);
    const default_title: []const u8 = switch (st.panel) {
        .browser => ops_surface.browser_default_title,
        else => ops_surface.terminal_default_title,
    };
    try setTitle(gpa, &tab.title, st.title, default_title);
    tab.pinned = st.pinned;
    try restoreObjectExt(gpa, &tab.ext, st.ext);
    // Panels this build cannot bring back stay placeholders and keep their
    // saved object for the next save.
    switch (st.panel) {
        .terminal, .browser => {},
        .placeholder => {},
        .web, .unknown => {
            const raw = try panelText(gpa, st.panel);
            defer gpa.free(raw);
            try tab.ext.session.setPanel(gpa, raw);
        },
    }
    return tab;
}

fn panelText(gpa: Allocator, panel: schema.Panel) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    switch (panel) {
        .unknown => |o| try jw.write(std.json.Value{ .object = o }),
        .web => |p| {
            try jw.beginObject();
            try jw.objectField("kind");
            try jw.write("web");
            try jw.objectField("app");
            try jw.write(p.app);
            try jw.objectField("params");
            try jw.write(p.params);
            try jw.objectField("state");
            try jw.write(p.state);
            try jw.endObject();
        },
        else => try jw.write(null),
    }
    return aw.toOwnedSlice();
}

fn setTitle(gpa: Allocator, title: anytype, saved: schema.Title, default: ?[]const u8) !void {
    const source: @TypeOf(title.source) = switch (saved.source) {
        inline else => |tag| @field(@TypeOf(title.source), @tagName(tag)),
    };
    if (saved.auto) |a| {
        if (a.len > 0) try title.setAuto(gpa, a, if (source == .user) .auto else source, false);
    } else if (default) |d| {
        try title.setAuto(gpa, d, .auto, false);
    }
    if (saved.custom) |c| if (c.len > 0) try title.setCustom(gpa, c);
}

/// Keep a restored object's `ext` text in its session state (copied
/// there) and restore the feature states that declare `restore`.
fn restoreObjectExt(gpa: Allocator, ext_ptr: anytype, saved: schema.Ext) !void {
    const text = try autosave.extText(gpa, saved);
    defer if (text) |t| gpa.free(t);
    if (comptime @hasDecl(@TypeOf(ext_ptr.session), "setExt")) {
        try ext_ptr.session.setExt(gpa, text);
    } else {
        try ext_ptr.session.set(gpa, text);
    }
    autosave.restoreExt(gpa, ext_ptr, saved);
}

// ── Identity ────────────────────────────────────────────────────────

/// Register `obj` (a *Window, *Workspace, *Group, *Pane or *Tab) with
/// its saved identity (ADR-2.7): an already registered object is re-keyed
/// (its current handle retired first). A malformed, missing or live UUID
/// gets a fresh one, a missing or taken ref a fresh ref
/// (HandleRegistry.adopt).
pub fn adoptHandle(app: *App, obj: anytype, kind: ids.Kind, id: ?[]const u8, ref: u32) !void {
    return adoptIn(&app.handles, app.core_app.alloc, obj, kind, id, ref);
}

pub fn adoptIn(reg: *handle_registry.HandleRegistry, gpa: Allocator, obj: anytype, kind: ids.Kind, id: ?[]const u8, ref: u32) !void {
    const saved: ids.Uuid = if (id) |t| (ids.Uuid.parse(t) catch ids.Uuid.nil) else ids.Uuid.nil;
    if (obj.registry) |r| {
        if (!saved.isNil() and obj.handle.uuid.eql(saved) and (ref == 0 or obj.handle.ref == ref)) return;
        r.retire(obj.handle.uuid);
        obj.registry = null;
        obj.handle = ids.no_handle;
    }
    obj.handle = try reg.adopt(gpa, kind, .{ .uuid = saved, .ref = ref }, obj);
    obj.registry = reg;
}

// ── Spawning ────────────────────────────────────────────────────────

const ContentKind = enum { terminal, browser, none };

/// What one placeholder tab becomes (owned strings).
const Item = struct {
    ref: schema.SpawnRef,
    tab: ids.Uuid,
    kind: ContentKind,
    cwd: ?[]u8 = null,
    ws_cwd: ?[]u8 = null,
    argv: ?[][]u8 = null,
    url: ?[]u8 = null,
    owned_by_deferred: bool = false,
    handled: bool = false,

    fn deinit(self: *Item, gpa: Allocator) void {
        if (self.cwd) |c| gpa.free(c);
        if (self.ws_cwd) |c| gpa.free(c);
        if (self.url) |u| gpa.free(u);
        if (self.argv) |argv| {
            for (argv) |a| gpa.free(a);
            gpa.free(argv);
        }
        self.* = undefined;
    }
};

const Plan = struct {
    gpa: Allocator,
    window_index: usize = 0,
    items: std.ArrayList(Item) = .empty,
    deferred: std.ArrayList(Item) = .empty,

    fn add(self: *Plan, gpa: Allocator, tab: *Tab, st: *const schema.Tab, ref: schema.SpawnRef, ws_cwd: ?[]const u8) !void {
        var item: Item = .{ .ref = ref, .tab = tab.handle.uuid, .kind = .none };
        errdefer item.deinit(gpa);
        switch (st.panel) {
            .terminal => |t| {
                item.kind = .terminal;
                if (t.cwd) |c| if (c.len > 0) {
                    item.cwd = try gpa.dupe(u8, c);
                };
                if (t.spawn) |sp| if (sp.argv.len > 0) {
                    const argv = try gpa.alloc([]u8, sp.argv.len);
                    var n: usize = 0;
                    errdefer {
                        for (argv[0..n]) |a| gpa.free(a);
                        gpa.free(argv);
                    }
                    for (sp.argv) |a| {
                        argv[n] = try gpa.dupe(u8, a);
                        n += 1;
                    }
                    item.argv = argv;
                };
            },
            .browser => |b| {
                item.kind = .browser;
                item.url = try gpa.dupe(u8, b.url);
            },
            else => {},
        }
        if (ws_cwd) |c| if (c.len > 0) {
            item.ws_cwd = try gpa.dupe(u8, c);
        };
        try self.items.append(gpa, item);
    }

    fn indexOf(self: *const Plan, r: schema.SpawnRef) ?usize {
        for (self.items.items, 0..) |it, i| {
            if (it.ref.window == r.window and it.ref.workspace == r.workspace and it.ref.pane == r.pane and it.ref.tab == r.tab) return i;
        }
        return null;
    }

    fn deinit(self: *Plan) void {
        for (self.items.items) |*it| if (!it.owned_by_deferred) it.deinit(self.gpa);
        self.items.deinit(self.gpa);
        for (self.deferred.items) |*it| it.deinit(self.gpa);
        self.deferred.deinit(self.gpa);
    }
};

/// The deferred spawns of a launch restore, one per timer tick.
pub const Spawner = struct {
    gpa: Allocator,
    items: std.ArrayList(Item),
    next: usize = 0,
    timer: app_timers.TimerId = 0,

    fn schedule(self: *Spawner, app: *App) void {
        self.timer = app.timers.start(stagger_ms, .{}, 0, onTimer);
        if (self.timer == 0) {
            // No timer: bring everything up now rather than never.
            while (self.next < self.items.items.len) : (self.next += 1) spawnDeferred(app, &self.items.items[self.next]);
            finish(app);
        }
    }

    fn onTimer(app: *App, ctx: usize) void {
        _ = ctx;
        const core = autosave.get(app) orelse return;
        const self = core.spawner orelse return;
        self.timer = 0;
        if (self.next < self.items.items.len) {
            spawnDeferred(app, &self.items.items[self.next]);
            self.next += 1;
        }
        if (self.next < self.items.items.len) {
            self.schedule(app);
        } else {
            finish(app);
        }
    }

    pub fn destroy(self: *Spawner) void {
        for (self.items.items) |*it| it.deinit(self.gpa);
        self.items.deinit(self.gpa);
        self.gpa.destroy(self);
    }
};

fn spawnDeferred(app: *App, item: *const Item) void {
    const window = spawn(app, item) orelse return;
    // A deferred tab is hidden unless the user switched to its workspace
    // meanwhile: then lay it out (without moving keyboard focus).
    refreshWindow(window, false);
}

/// Bring up one placeholder tab. Returns its window when the tab is shown.
fn spawn(app: *App, item: *const Item) ?*Window {
    const tab = app.handles.get(Tab, .surface, item.tab) orelse return null;
    if (tab.content != .placeholder) return null;
    const pane = tab.pane orelse return null;
    const ws = pane.workspace orelse return null;
    const window = ws.window;
    if (window.closing) return null;
    switch (item.kind) {
        .terminal => spawnTerminal(app, window, ws, pane, tab, item) catch |err| {
            log.warn("restored terminal failed to start err={}", .{err});
            return null;
        },
        .browser => spawnBrowser(app, window, tab, item) catch |err| {
            log.warn("restored browser tab failed to start err={}", .{err});
            return null;
        },
        .none => return null,
    }
    const shown = window.selected == ws and pane.selectedTab() == tab;
    if (!shown) {
        tab.content.setVisible(false);
        return null;
    }
    return window;
}

fn spawnTerminal(app: *App, window: *Window, ws: *Workspace, pane: *Pane, tab: *Tab, item: *const Item) !void {
    const gpa = app.core_app.alloc;
    var home_buf: ?[]u8 = null;
    defer if (home_buf) |h| gpa.free(h);
    const cwd = resolveCwd(gpa, item.cwd, item.ws_cwd orelse ws.cwd, &home_buf);
    const spawn_id: ids.SpawnIdentity = .{
        .window = window.handle.uuid,
        .workspace = ws.handle.uuid,
        .pane = pane.handle.uuid,
        .surface = tab.handle.uuid,
        .lifecycle = ids.Uuid.v4(),
    };
    const surface = try gpa.create(Surface);
    errdefer gpa.destroy(surface);
    const argv: ?[]const []const u8 = if (item.argv) |a| a else null;
    try surface.init(app, window, .tab, argv, cwd, spawn_id);
    tab.content = .{ .terminal = surface };
    surface.tab = tab;
    tab.lifecycle_id = spawn_id.lifecycle;
    app.handles.bindCoreId(gpa, tab.handle.uuid, surface.core_surface.id) catch |err|
        log.warn("failed to bind the core surface id err={}", .{err});
    tab.ext.session.setSpawnCwd(gpa, cwd) catch {};
}

fn spawnBrowser(app: *App, window: *Window, tab: *Tab, item: *const Item) !void {
    const gpa = app.core_app.alloc;
    const browser = try BrowserPane.create(gpa, app, window);
    tab.content = .{ .browser = browser };
    browser.tab = tab;
    if (item.url) |url| {
        if (std.unicode.wtf8ToWtf16LeAllocZ(gpa, url)) |w| {
            defer gpa.free(w);
            browser.navigateUrl(w.ptr) catch {};
        } else |_| {}
    }
    browser.startCreation();
}

/// ADR-9.6: the tab's directory, else the workspace's, else the user
/// profile when a saved directory is gone; null (the configured default)
/// when nothing was saved.
pub fn resolveCwd(gpa: Allocator, tab_cwd: ?[]const u8, ws_cwd: ?[]const u8, home_buf: *?[]u8) ?[]const u8 {
    if (tab_cwd) |c| if (isDir(c)) return c;
    if (ws_cwd) |c| if (isDir(c)) return c;
    if (tab_cwd == null and ws_cwd == null) return null;
    home_buf.* = std.process.getEnvVarOwned(gpa, "USERPROFILE") catch return null;
    return home_buf.*;
}

fn isDir(path: []const u8) bool {
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return false;
    var d = std.fs.cwd().openDir(path, .{}) catch return false;
    d.close();
    return true;
}

// ── Crash notice ────────────────────────────────────────────────────

/// ADR-9.4: the previous restore crashed; the snapshot was set aside.
pub fn showCrashNotice(core: *autosave.Core, crashed_name: ?[]const u8) void {
    var buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "The previous session restore did not finish; the snapshot was moved to {s} and this launch starts fresh.", .{crashed_name orelse "(nothing to move)"}) catch "The previous session restore did not finish.";
    autosave.deferNotice(core, .{
        .id = "session.crashed",
        .level = .warning,
        .title = "wmux did not restore the previous session",
        .body = body,
    });
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "unit: session: restore order and adopt() keep ids and refs" {
    const doc =
        \\{"schema":"wmux-session","version":3,
        \\ "handles":{"next":{"window":4,"workspace":9,"workspace_group":1,"pane":21,"surface":31}},
        \\ "windows":[{"id":"00000000-0000-4000-8000-000000000003","ref":3,
        \\  "selected_workspace":"00000000-0000-4000-8000-0000000000B8",
        \\  "workspaces":[
        \\   {"id":"00000000-0000-4000-8000-0000000000B7","ref":7,"panes":[{"id":"00000000-0000-4000-8000-0000000000C1","ref":12,"tabs":[{"id":"00000000-0000-4000-8000-0000000000D1","ref":30}]}]},
        \\   {"id":"00000000-0000-4000-8000-0000000000B8","ref":8,"panes":[{"id":"00000000-0000-4000-8000-0000000000C2","ref":20,"tabs":[{"id":"00000000-0000-4000-8000-0000000000D2","ref":29}]}]}]}]}
    ;
    var p = try schema.parse(testing.allocator, doc, .{}, null);
    defer p.deinit();
    const s = &p.session;

    // A fresh process: seed with the file's high-water marks, then the
    // initial window of App.run mints above them.
    var reg: handle_registry.HandleRegistry = .{};
    defer reg.deinit(testing.allocator);
    var high: markers.Marks = .initFill(0);
    inline for (comptime std.enums.values(schema.Kind)) |k| high.set(@field(handle_registry.Kind, @tagName(k)), s.handles.next.get(k) - 1);
    reg.seed(high, .initFill(0));

    const Obj = struct { handle: ids.Handle = ids.no_handle, registry: ?*handle_registry.HandleRegistry = null };
    var initial: Obj = .{};
    initial.handle = try reg.mint(testing.allocator, .window, &initial);
    initial.registry = &reg;
    try testing.expectEqual(@as(u32, 4), initial.handle.ref);

    // Re-keying the initial window adopts the saved identity.
    try adoptIn(&reg, testing.allocator, &initial, .window, s.windows[0].id, s.windows[0].ref);
    try testing.expectEqualStrings(s.windows[0].id.?, &initial.handle.uuid.toText());
    try testing.expectEqual(@as(u32, 3), initial.handle.ref);

    // Tabs restored in spawn order keep their UUIDs and refs.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const order = try schema.spawnOrder(arena.allocator(), s);
    try testing.expectEqual(@as(usize, 2), order.len);
    // The selected workspace (B8) comes first.
    try testing.expectEqual(@as(usize, 1), order[0].workspace);
    try testing.expect(order[0].immediate and !order[1].immediate);
    var tabs: [2]Obj = .{ .{}, .{} };
    for (order, 0..) |r, i| {
        const st = &s.windows[r.window].workspaces[r.workspace].panes[r.pane].tabs[r.tab];
        try adoptIn(&reg, testing.allocator, &tabs[i], .surface, st.id, st.ref);
        try testing.expectEqualStrings(st.id.?, &tabs[i].handle.uuid.toText());
        try testing.expectEqual(st.ref, tabs[i].handle.ref);
    }
    // The next minted surface passes every adopted ref.
    var fresh: Obj = .{};
    const h = try reg.mint(testing.allocator, .surface, &fresh);
    try testing.expectEqual(@as(u32, 31), h.ref);

    // A saved UUID that is already live (restoring twice) gets a fresh one.
    var dup: Obj = .{};
    try adoptIn(&reg, testing.allocator, &dup, .surface, s.windows[0].workspaces[0].panes[0].tabs[0].id, 30);
    try testing.expect(!dup.handle.uuid.eql(tabs[1].handle.uuid));
    try testing.expect(dup.handle.ref != 30);
}

test "unit: session: restore cwd falls back from tab to workspace to the profile" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    var home: ?[]u8 = null;
    defer if (home) |h| testing.allocator.free(h);
    try testing.expectEqualStrings(dir, resolveCwd(testing.allocator, dir, null, &home).?);
    try testing.expectEqualStrings(dir, resolveCwd(testing.allocator, "C:\\no\\such\\wmux-dir", dir, &home).?);
    try testing.expect(resolveCwd(testing.allocator, null, null, &home) == null);
    const fallback = resolveCwd(testing.allocator, "C:\\no\\such\\wmux-dir", null, &home);
    if (std.process.getEnvVarOwned(testing.allocator, "USERPROFILE")) |up| {
        defer testing.allocator.free(up);
        try testing.expectEqualStrings(up, fallback.?);
    } else |_| try testing.expect(fallback == null);
}

test "unit: session: explicit launch intents skip the restore" {
    try testing.expect(!isExplicitIntent(&.{ "--config-default-files=false", "--config-file=C:/x/ghostty.conf" }));
    try testing.expect(!isExplicitIntent(&.{"--restore"}));
    try testing.expect(!isExplicitIntent(&.{}));
    try testing.expect(isExplicitIntent(&.{ "-e", "pwsh.exe" }));
    try testing.expect(isExplicitIntent(&.{"--working-directory=C:/src"}));
    try testing.expect(isExplicitIntent(&.{"C:/src/project"}));
    try testing.expect(isExplicitIntent(&.{"https://example.com"}));
}
