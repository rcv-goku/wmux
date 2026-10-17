//! The session runtime (ARCHITECTURE.md ADR-9.1-9.4, 9.8, ADR-2.2): the
//! `Core` the feature's `init` creates, the 8 s autosave, the full saves
//! and the model -> schema v3 snapshot.
//!
//! - Every 8 s an app timer serializes the whole app on the UI thread into an
//!   arena, fingerprints the document without its volatile fields
//!   (schema_v3.fingerprint, Wyhash) and hands the bytes to the writer
//!   thread only when the fingerprint changed, so an idle app never writes
//!   and a busy one writes at most once per tick. Model events set `dirty`
//!   (mod.zig `onEvent`), but the tick fingerprints even without it: many
//!   changes emit no event (a shell's cwd or title, a description, a
//!   divider drag), and serializing a session is cheap next to 8 s.
//! - Full saves (`fullSave`): the last window's WM_CLOSE, quit, and
//!   WM_ENDSESSION (synchronous, the one UI-thread write G3 allows). The
//!   per-window WM_CLOSE overwrite of the legacy file is gone.
//! - In test mode every automatic save is off unless
//!   WMUX_TEST_SESSION_RESTORE=1 (ADR-12.3, owner decision 2026-10-17 b):
//!   without it there is no Core at all.
//! - Handle reservations persist in `STATE\run\handles.json` through the
//!   registry's `on_reserve` hook, and seed the registry at startup.

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("../../App.zig");
const Pane = @import("../../model/Pane.zig");
const SplitTree = @import("../../../../datastruct/split_tree.zig").SplitTree;
const Tab = @import("../../model/Tab.zig");
const Window = @import("../../ui/Window.zig");
const Workspace = @import("../../model/Workspace.zig");
const app_timers = @import("../../app/timers.zig");
const build_config = @import("../../../../build_config.zig");
const features_ext = @import("../ext.zig");
const handle_registry = @import("../../model/logic/handle_registry.zig");
const ids = @import("../../model/ids.zig");
const limits = @import("logic/limits.zig");
const markers = @import("markers.zig");
const placement_io = @import("placement_io.zig");
const restore = @import("restore.zig");
const notice = @import("../../ui/notice.zig");
const schema = @import("logic/schema_v3.zig");
const Writer = @import("writer.zig").Writer;

const log = std.log.scoped(.session);

/// The autosave period (ADR-9.3, cmux's SessionAutosaveCoordinator).
pub const tick_ms: u32 = 8000;

pub const Core = struct {
    gpa: Allocator,
    app: *App,
    /// `STATE\session` and `STATE\run` (owned).
    session_dir: []u8,
    run_dir: []u8,
    writer: Writer,

    timer: app_timers.TimerId = 0,
    ticks: u64 = 0,
    /// A model event arrived since the last serialization (diagnostics;
    /// the tick fingerprints either way).
    dirty: bool = true,
    /// Fingerprint of the last document handed to the writer.
    last_fingerprint: ?u64 = null,
    /// `wmux.session.autosave`: false keeps the file as it is.
    saving: bool = true,
    /// The final save ran (last window closed, quit, logoff): later ticks
    /// would only see a dismantled app and must not overwrite it.
    final_saved: bool = false,

    /// The session the launch restore applies (owned), until it ran.
    pending: ?schema.Parsed = null,
    /// A restore is in progress (`session.restoring` exists).
    restoring: bool = false,
    /// The deferred spawns of that restore (restore.zig).
    spawner: ?*restore.Spawner = null,
    /// Notices raised during `init`, shown once the message loop runs
    /// (the first window exists and STATEogswmux.log is open).
    notices: std.ArrayList(notice.Notice) = .empty,

    pub fn deinit(self: *Core) void {
        self.writer.deinit();
        for (self.notices.items) |n| self.gpa.free(n.body);
        self.notices.deinit(self.gpa);
        if (self.spawner) |sp| sp.destroy();
        self.spawner = null;
        if (self.pending) |p| p.deinit();
        self.pending = null;
        self.gpa.free(self.session_dir);
        self.gpa.free(self.run_dir);
    }
};

/// The app's session Core, or null (test mode without
/// WMUX_TEST_SESSION_RESTORE, or before `init`).
pub fn get(app: *const App) ?*Core {
    const p = app.features.session.core orelse return null;
    return @ptrCast(@alignCast(p));
}

/// Create the Core and start the writer (feature init). Null when
/// automatic saves are off or the state directory is unknown.
pub fn create(app: *App) ?*Core {
    if (!app.runtime_env.sessionSaveOnCloseAllowed()) return null;
    const gpa = app.core_app.alloc;
    const session_dir = markers.sessionDir(gpa, &app.runtime_env) catch |err| {
        log.warn("no session directory err={}", .{err});
        return null;
    };
    const run_dir = markers.runDir(gpa, &app.runtime_env) catch {
        gpa.free(session_dir);
        return null;
    };
    const core = gpa.create(Core) catch {
        gpa.free(session_dir);
        gpa.free(run_dir);
        return null;
    };
    const writer = Writer.init(gpa, session_dir) catch {
        gpa.destroy(core);
        gpa.free(session_dir);
        gpa.free(run_dir);
        return null;
    };
    core.* = .{ .gpa = gpa, .app = app, .session_dir = session_dir, .run_dir = run_dir, .writer = writer };
    std.fs.cwd().makePath(session_dir) catch {};
    core.writer.start();
    app.features.session.core = core;
    return core;
}

/// Stop the timer, flush the writer, free the Core (feature deinit).
pub fn destroy(app: *App) void {
    destroyImpl(app, true);
}

/// Like `destroy`, leaving `session.running` alone (another live instance
/// owns this state directory).
pub fn destroyKeepRunning(app: *App) void {
    destroyImpl(app, false);
}

fn destroyImpl(app: *App, clear_running: bool) void {
    const core = get(app) orelse return;
    if (core.timer != 0) app.timers.stop(core.timer);
    core.timer = 0;
    if (app.handles.on_reserve) |hook| {
        if (hook.ctx == @as(*anyopaque, core)) app.handles.on_reserve = null;
    }
    core.writer.stop();
    if (clear_running) markers.clearRunning(core.session_dir);
    core.deinit();
    app.features.session.core = null;
    core.gpa.destroy(core);
}

// ── Handle reservations (ADR-2.2) ───────────────────────────────────

/// Seed the registry from `STATE\run\handles.json` and install the
/// reservation hook. Before the first object is minted.
pub fn seedHandles(core: *Core) void {
    const app = core.app;
    if (markers.readFile(core.gpa, core.run_dir, markers.handles_file, 64 * 1024)) |bytes| {
        defer core.gpa.free(bytes);
        const p = markers.parseHandles(core.gpa, bytes);
        app.handles.seed(p.next, p.reserved);
    }
    app.handles.on_reserve = .{ .ctx = core, .call = onReserve };
}

/// Seed with a session's `handles.next` (the next ref per kind).
pub fn seedFromSession(app: *App, s: *const schema.Session) void {
    var high: markers.Marks = .initFill(0);
    inline for (comptime std.enums.values(schema.Kind)) |k| {
        const n = s.handles.next.get(k);
        high.set(@field(handle_registry.Kind, @tagName(k)), if (n > 0) n - 1 else 0);
    }
    app.handles.seed(high, .initFill(0));
    // Seeding may raise ceilings without a mint: persist them now.
    if (get(app)) |core| markers.writeHandles(core.run_dir, &app.handles);
}

fn onReserve(ctx: *anyopaque, reg: *const handle_registry.HandleRegistry) void {
    const core: *Core = @ptrCast(@alignCast(ctx));
    markers.writeHandles(core.run_dir, reg);
}

// ── Autosave ────────────────────────────────────────────────────────

pub fn startTimer(core: *Core) void {
    if (core.timer != 0) return;
    core.timer = core.app.timers.start(tick_ms, .{ .repeat = true }, 0, onTick);
}

/// A model change: the next tick serializes.
pub fn markDirty(app: *const App) void {
    if (get(app)) |core| core.dirty = true;
}

fn onTick(app: *App, ctx: usize) void {
    _ = ctx;
    const core = get(app) orelse return;
    core.ticks += 1;
    if (core.final_saved or core.restoring) return;
    autosaveNow(core);
}

/// Serialize now and submit when the document changed (the tick body).
pub fn autosaveNow(core: *Core) void {
    if (!core.saving) return;
    if (!hasSavableWindow(core.app)) return;
    core.dirty = false;
    const bytes = serialize(core.gpa, core.app, false) catch |err| {
        log.warn("session snapshot failed err={}", .{err});
        return;
    };
    if (core.last_fingerprint) |fp| if (fp == bytes.fingerprint) {
        core.gpa.free(bytes.json);
        return;
    };
    core.last_fingerprint = bytes.fingerprint;
    core.writer.submit(bytes.json);
}

pub const SaveMode = enum {
    /// Hand to the writer thread (flushed at exit by `destroy`).
    background,
    /// Write on the calling thread (WM_ENDSESSION).
    sync,
};

/// The full save (ADR-9.3): the whole app with `clean_exit`, written even
/// when unchanged; later ticks stop. Scrollback joins it with W1-7b.
pub fn fullSave(core: *Core, mode: SaveMode) void {
    if (!core.saving) return;
    if (core.final_saved or core.restoring) return;
    if (!hasSavableWindow(core.app)) return;
    const bytes = serialize(core.gpa, core.app, true) catch |err| {
        log.warn("session full save failed err={}", .{err});
        return;
    };
    core.final_saved = true;
    core.last_fingerprint = bytes.fingerprint;
    switch (mode) {
        .background => core.writer.submit(bytes.json),
        .sync => {
            defer core.gpa.free(bytes.json);
            core.writer.writeSync(bytes.json) catch |err| log.warn("session save failed err={}", .{err});
        },
    }
}

/// Whether any window would go into a snapshot (an app whose last window
/// is gone keeps the file it has).
fn hasSavableWindow(app: *const App) bool {
    for (app.windows.items) |w| if (isSavable(w)) return true;
    return false;
}

fn isSavable(w: *const Window) bool {
    return !w.is_quick_terminal and !w.closing and w.hwnd != null and w.workspaces.items.len > 0;
}

// ── Snapshot ────────────────────────────────────────────────────────

pub const Serialized = struct {
    /// The document (owned by the caller's allocator).
    json: []u8,
    fingerprint: u64,
};

/// The v3 document of the whole app.
pub fn serialize(gpa: Allocator, app: *App, clean_exit: bool) !Serialized {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = try buildSession(arena, app, clean_exit);
    _ = try limits.apply(arena, &s);
    return .{
        .json = try schema.writeAlloc(gpa, &s, .{}),
        .fingerprint = schema.fingerprint(&s),
    };
}

fn uuidText(arena: Allocator, u: ids.Uuid) ![]const u8 {
    const t = u.toText();
    return arena.dupe(u8, &t);
}

fn optUuid(arena: Allocator, h: ids.Handle) !?[]const u8 {
    if (!ids.isRegistered(h)) return null;
    return try uuidText(arena, h.uuid);
}

/// The snapshot of the live model (strings in `arena`).
pub fn buildSession(arena: Allocator, app: *App, clean_exit: bool) !schema.Session {
    var stamp: [24]u8 = undefined;
    var s: schema.Session = .{
        .app_version = build_config.version_string,
        .channel = "",
        .created_at = try arena.dupe(u8, schema.formatTimestamp(std.time.milliTimestamp(), &stamp)),
        .clean_exit = clean_exit,
    };
    inline for (comptime std.enums.values(schema.Kind)) |k| {
        const last = app.handles.next.get(@field(handle_registry.Kind, @tagName(k)));
        s.handles.next.set(k, last +| 1);
    }
    var windows: std.ArrayList(schema.Window) = .empty;
    for (app.windows.items) |w| {
        if (!isSavable(w)) continue;
        try windows.append(arena, try buildWindow(arena, w));
    }
    s.windows = try windows.toOwnedSlice(arena);
    return s;
}

fn buildWindow(arena: Allocator, w: *Window) !schema.Window {
    var out: schema.Window = .{
        .id = try optUuid(arena, w.handle),
        .ref = w.handle.ref,
        .placement = placement_io.capture(arena, w),
        .sidebar = .{
            .visible = !w.sidebar_hidden,
            .width = @intCast(w.sidebar_width_override orelse w.app.config.@"window-sidebar-width"),
        },
        .right_sidebar = .{ .visible = !w.right_sidebar_hidden and w.app.config.@"window-show-right-sidebar" },
        .selected_workspace = if (w.selected) |ws| try optUuid(arena, ws.handle) else null,
        .ext = try extObject(arena, &w.ext, w.ext.session.ext_json),
    };
    var groups: std.ArrayList(schema.Group) = .empty;
    for (w.groups.items) |g| {
        try groups.append(arena, .{
            .id = try optUuid(arena, g.handle),
            .ref = g.handle.ref,
            .name = try arena.dupe(u8, g.name),
            .collapsed = g.collapsed,
            .pinned = g.pinned,
            .anchor = if (g.anchor) |a| try optUuid(arena, a.handle) else null,
        });
    }
    out.groups = try groups.toOwnedSlice(arena);
    var wss: std.ArrayList(schema.Workspace) = .empty;
    for (w.workspaces.items) |ws| try wss.append(arena, try buildWorkspace(arena, ws));
    out.workspaces = try wss.toOwnedSlice(arena);
    return out;
}

fn titleOf(arena: Allocator, t: anytype) !schema.Title {
    return .{
        .custom = if (t.custom) |c| try validText(arena, c) else null,
        .auto = if (t.auto) |a| try validText(arena, a) else null,
        .source = switch (t.source) {
            inline else => |tag| @field(schema.TitleSource, @tagName(tag)),
        },
    };
}

/// UTF-8 text for the file: a WTF-8 rename (an unpaired surrogate) is
/// written with replacement characters instead of invalid JSON text.
fn validText(arena: Allocator, text: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(text)) return arena.dupe(u8, text);
    var out: std.ArrayList(u8) = .empty;
    var view = std.unicode.Wtf8View.initUnchecked(text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const c: u21 = if (cp >= 0xD800 and cp <= 0xDFFF) 0xFFFD else cp;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &buf) catch continue;
        try out.appendSlice(arena, buf[0..n]);
    }
    return out.toOwnedSlice(arena);
}

fn buildWorkspace(arena: Allocator, ws: *Workspace) !schema.Workspace {
    var out: schema.Workspace = .{
        .id = try optUuid(arena, ws.handle),
        .ref = ws.handle.ref,
        .title = try titleOf(arena, ws.title),
        .description = if (ws.description) |d| try validText(arena, d) else null,
        .cwd = if (ws.cwd) |c| try arena.dupe(u8, c) else null,
        .group = if (ws.group) |g| try optUuid(arena, g.handle) else null,
        .pinned = ws.pinned,
        .focused_pane = if (ws.focused_pane) |p| try optUuid(arena, p.handle) else null,
        .zoomed_pane = if (ws.zoomed_pane) |p| try optUuid(arena, p.handle) else null,
        .ext = try extObject(arena, &ws.ext, ws.ext.session.ext_json),
    };
    var env: std.ArrayList(schema.EnvVar) = .empty;
    var it = ws.env.iterator();
    while (it.next()) |e| try env.append(arena, .{ .name = try arena.dupe(u8, e.key_ptr.*), .value = try arena.dupe(u8, e.value_ptr.*) });
    out.env = try env.toOwnedSlice(arena);

    if (!ws.tree.isEmpty()) {
        out.layout = try layoutOf(arena, &ws.tree, .root);
        var panes: std.ArrayList(schema.Pane) = .empty;
        try collectPanes(arena, &ws.tree, .root, &panes);
        out.panes = try panes.toOwnedSlice(arena);
    }
    return out;
}

fn layoutOf(arena: Allocator, tree: *const SplitTree(Pane), handle: SplitTree(Pane).Node.Handle) !schema.Layout {
    switch (tree.nodes[handle.idx()]) {
        .leaf => |pane| return .{ .pane = try uuidText(arena, pane.handle.uuid) },
        .split => |sp| {
            const split = try arena.create(schema.Split);
            split.* = .{
                .dir = switch (sp.layout) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                },
                .ratio = schema.sanitizeRatio(@floatCast(sp.ratio)),
                .a = try layoutOf(arena, tree, sp.left),
                .b = try layoutOf(arena, tree, sp.right),
            };
            return .{ .split = split };
        },
    }
}

/// The panes of a tree in depth-first order (ADR-2.4).
fn collectPanes(arena: Allocator, tree: *const SplitTree(Pane), handle: SplitTree(Pane).Node.Handle, out: *std.ArrayList(schema.Pane)) !void {
    switch (tree.nodes[handle.idx()]) {
        .leaf => |pane| try out.append(arena, try buildPane(arena, pane)),
        .split => |sp| {
            try collectPanes(arena, tree, sp.left, out);
            try collectPanes(arena, tree, sp.right, out);
        },
    }
}

fn buildPane(arena: Allocator, pane: *Pane) !schema.Pane {
    var tabs: std.ArrayList(schema.Tab) = .empty;
    for (pane.tabs.items) |tab| try tabs.append(arena, try buildTab(arena, tab));
    return .{
        .id = try uuidText(arena, pane.handle.uuid),
        .ref = pane.handle.ref,
        .selected_tab = if (pane.selectedTab()) |t| try optUuid(arena, t.handle) else null,
        .tabs = try tabs.toOwnedSlice(arena),
        .ext = try extObject(arena, &pane.ext, pane.ext.session.ext_json),
    };
}

fn buildTab(arena: Allocator, tab: *Tab) !schema.Tab {
    return .{
        .id = try optUuid(arena, tab.handle),
        .ref = tab.handle.ref,
        .title = try titleOf(arena, tab.title),
        .pinned = tab.pinned,
        .panel = try panelOf(arena, tab),
        .ext = try extObject(arena, &tab.ext, tab.ext.session.ext_json),
    };
}

fn panelOf(arena: Allocator, tab: *Tab) !schema.Panel {
    switch (tab.content) {
        .terminal => |surface| {
            var t: schema.Terminal = .{ .cwd = try terminalCwd(arena, tab) };
            if (surface.spawn_command) |argv| {
                const copy = try arena.alloc([]const u8, argv.len);
                for (argv, 0..) |a, i| copy[i] = try arena.dupe(u8, a);
                t.spawn = .{ .argv = copy };
            }
            return .{ .terminal = t };
        },
        .browser => |b| return .{ .browser = .{ .url = try browserUrl(arena, b) } },
        .web, .placeholder => {
            // A panel this build restored as a placeholder keeps its file
            // object; a live web panel writes its kind (its owner adds the
            // rest, ADR-6.9).
            if (tab.ext.session.panel_json) |raw| {
                const v = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch null;
                if (v) |val| if (val == .object) return .{ .unknown = val.object };
            }
            return switch (tab.content) {
                .web => |p| .{ .web = .{ .app = p.kind.id } },
                else => .{ .placeholder = .{ .reason = "restored" } },
            };
        },
    }
}

/// The working directory of a terminal tab (ADR-9.6): what the shell last
/// reported (OSC 7 / OSC 9;9), else Tab.cwd (meta.api.onPwd), else the
/// directory it was spawned in.
fn terminalCwd(arena: Allocator, tab: *Tab) !?[]const u8 {
    if (tab.surface()) |surface| {
        if (surface.core_surface_ready) {
            if (try surface.core_surface.pwd(arena)) |p| if (p.len > 0) return p;
        }
    }
    if (tab.cwd) |c| return try arena.dupe(u8, c);
    if (tab.ext.session.spawn_cwd) |c| return try arena.dupe(u8, c);
    return null;
}

const BrowserPane = @import("../../web/BrowserPane.zig");
const wv2 = @import("../../platform/webview2.zig");

fn browserUrl(arena: Allocator, b: *BrowserPane) ![]const u8 {
    if (b.webview) |webview| {
        if (webview.getSource()) |uri| {
            defer wv2.CoTaskMemFree(uri);
            const span = std.mem.span(uri);
            const capped = span[0..@min(span.len, limits.max_text_bytes)];
            if (std.unicode.wtf16LeToWtf8Alloc(arena, capped)) |u| return u else |_| {}
        } else |_| {}
    }
    if (b.pending_url_len > 0) {
        if (std.unicode.wtf16LeToWtf8Alloc(arena, b.pending_url[0..b.pending_url_len])) |u| return u else |_| {}
    }
    return "about:blank";
}

/// The `ext` object of a model object: the JSON it was restored with
/// (unknown feature keys round-trip), overlaid with the `snapshot` of
/// every feature state that declares one (ADR-1.3), keyed by feature id.
fn extObject(arena: Allocator, ext_ptr: anytype, restored: ?[]const u8) !schema.Ext {
    var ext: schema.Ext = null;
    if (restored) |raw| {
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch null;
        if (v) |val| if (val == .object) {
            ext = val.object;
        };
    }
    const T = @typeInfo(@TypeOf(ext_ptr)).pointer.child;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (comptime @hasDecl(f.type, "snapshot")) {
            if (snapshotValue(arena, &@field(ext_ptr, f.name), f.name)) |v| try schema.extPut(arena, &ext, f.name, v);
        }
    }
    return ext;
}

/// One feature state's `snapshot` as a JSON value (null when it failed).
fn snapshotValue(arena: Allocator, state: anytype, name: []const u8) ?std.json.Value {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    state.snapshot(&jw) catch |err| {
        log.warn("ext snapshot of {s} failed err={}", .{ name, err });
        return null;
    };
    return std.json.parseFromSliceLeaky(std.json.Value, arena, aw.written(), .{}) catch null;
}

/// Write an `ext` value back as text (owned by `gpa`) for the model
/// object's session state, or null when empty.
pub fn extText(gpa: Allocator, ext: schema.Ext) !?[]u8 {
    const m = ext orelse return null;
    if (m.count() == 0) return null;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try jw.write(std.json.Value{ .object = m });
    return try aw.toOwnedSlice();
}

/// Restore the feature states of `ext_ptr` that declare `restore` from
/// `ext` (ADR-1.3), keyed by feature id.
pub fn restoreExt(gpa: Allocator, ext_ptr: anytype, ext: schema.Ext) void {
    const m = ext orelse return;
    const T = @typeInfo(@TypeOf(ext_ptr)).pointer.child;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (comptime @hasDecl(f.type, "restore")) {
            if (m.get(f.name)) |v| {
                @field(ext_ptr, f.name).restore(v, gpa) catch |err|
                    log.warn("ext restore of {s} failed err={}", .{ f.name, err });
            }
        }
    }
}

test "unit: session: ext merge keeps unknown feature keys and adds snapshots" {
    const State = struct {
        n: u8 = 7,
        pub fn snapshot(self: *const @This(), w: *std.json.Stringify) !void {
            try w.beginObject();
            try w.objectField("n");
            try w.write(self.n);
            try w.endObject();
        }
        pub fn restore(self: *@This(), v: std.json.Value, gpa: Allocator) !void {
            _ = gpa;
            self.n = @intCast(v.object.get("n").?.integer);
        }
    };
    const Ext = struct { alpha: State = .{}, plain: struct { x: u8 = 0 } = .{} };
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var e: Ext = .{};
    const ext = try extObject(arena, &e, "{\"future_feature\":{\"k\":1},\"alpha\":{\"n\":1}}");
    try std.testing.expectEqual(@as(i64, 1), ext.?.get("future_feature").?.object.get("k").?.integer);
    try std.testing.expectEqual(@as(i64, 7), ext.?.get("alpha").?.object.get("n").?.integer);
    var back: Ext = .{ .alpha = .{ .n = 0 } };
    restoreExt(std.testing.allocator, &back, ext);
    try std.testing.expectEqual(@as(u8, 7), back.alpha.n);
    const text = (try extText(std.testing.allocator, ext)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "future_feature") != null);
}

// ── Logoff / shutdown (broadcast-window app hooks, ADR-1.6) ─────────

const AppHook = @import("../../app/hooks.zig").AppHook;
const w32 = @import("../../platform/win32.zig");

const WM_QUERYENDSESSION: u32 = 0x0011;
const WM_ENDSESSION: u32 = 0x0016;

extern "user32" fn ShutdownBlockReasonCreate(hwnd: w32.HWND, reason: [*:0]const u16) callconv(.winapi) i32;
extern "user32" fn ShutdownBlockReasonDestroy(hwnd: w32.HWND) callconv(.winapi) i32;
extern "kernel32" fn RegisterApplicationRestart(cmdline: ?[*:0]const u16, flags: u32) callconv(.winapi) i32;

const RESTART_NO_CRASH: u32 = 1;
const RESTART_NO_HANG: u32 = 2;

/// The broadcast window's logoff/shutdown hooks (mod.zig `app_hooks`).
pub const app_hooks = [_]AppHook{
    .{ .msg = WM_QUERYENDSESSION, .handler = onQueryEndSession },
    .{ .msg = WM_ENDSESSION, .handler = onEndSession },
};

/// The window the shutdown UI names while the session is saved.
fn blockWindow(app: *App) ?w32.HWND {
    for (app.windows.items) |w| if (w.hwnd) |h| return h;
    return app.broadcast.hwnd;
}

/// WM_QUERYENDSESSION: name the pending save in the shutdown UI
/// ("Saving wmux session") and let the session end (DefWindowProc
/// answers TRUE).
fn onQueryEndSession(app: *App, wparam: usize, lparam: isize) ?isize {
    _ = wparam;
    _ = lparam;
    const core = get(app) orelse return null;
    if (core.final_saved) return null;
    if (blockWindow(app)) |h| _ = ShutdownBlockReasonCreate(h, std.unicode.utf8ToUtf16LeStringLiteral("Saving wmux session"));
    return null;
}

/// WM_ENDSESSION (wparam TRUE: the session really ends): the synchronous
/// full save, the one UI-thread write G3 allows, before Windows ends the
/// process.
fn onEndSession(app: *App, wparam: usize, lparam: isize) ?isize {
    _ = lparam;
    const core = get(app) orelse return null;
    if (wparam != 0) fullSave(core, .sync);
    if (blockWindow(app)) |h| _ = ShutdownBlockReasonDestroy(h);
    return null;
}

/// RegisterApplicationRestart (ADR-9.3): Windows relaunches wmux after an
/// update or a restart-capable reboot; the relaunch restores the session
/// by default, so no argument is passed (Appendix E: "--restore" is not a
/// wmux argument until W1-2's argv routing knows it). Not in test mode.
pub fn registerRestart(app: *const App) void {
    if (app.runtime_env.test_mode) return;
    const hr = RegisterApplicationRestart(null, RESTART_NO_CRASH | RESTART_NO_HANG);
    if (hr != 0) log.warn("RegisterApplicationRestart failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
}

// ── Notices raised at startup ───────────────────────────────────────

/// Queue `n` (its body is copied; id and title are static strings) until
/// `flushNotices` runs from the first task of the message loop.
pub fn deferNotice(core: *Core, n: notice.Notice) void {
    var copy = n;
    copy.body = core.gpa.dupe(u8, n.body) catch "";
    core.notices.append(core.gpa, copy) catch {
        if (copy.body.len > 0) core.gpa.free(copy.body);
        notice.show(core.app, n);
    };
}

/// Show the queued startup notices (UI thread, message loop running).
pub fn flushNotices(app: *App) void {
    const core = get(app) orelse return;
    for (core.notices.items) |n| {
        notice.show(app, n);
        if (n.body.len > 0) core.gpa.free(n.body);
    }
    core.notices.clearRetainingCapacity();
}
