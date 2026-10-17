//! Public API of the settings layer (ARCHITECTURE.md ADR-5): the
//! `cmux.json`/`wmux.json` layering, the typed snapshot, the watcher and
//! the Ghostty overlay. App.init calls `init` once the app struct exists
//! and before any window is created; App.terminate calls `deinit`.
//!
//! Layer stack, lowest first (ADR-5.1): spec defaults < explicitly set
//! legacy Ghostty keys < cmux.json < wmux.json (each file's packs just
//! below it) < the project file < managed policy. `init` loads it once on
//! the UI thread (rev 1); the watcher thread (settings/watcher.zig)
//! re-reads it on change and posts the result, which `onReload` publishes:
//! the snapshot swap, the log lines `settings reloaded rev=N source=X`
//! and one `settings key <path>=<json> source=<layer>` per change in
//! STATE\logs\wmux.log, every feature's `onSettingsChanged(diff)`, and the
//! `wmux.settings.changed` and `config.reloaded` events. A parse error
//! keeps the last good snapshot and raises the `settings.parse_error`
//! notice with the first three errors.
//!
//! The settings state is process-wide (one App per process; App.zig has
//! no settings field and is not owned by this layer).

const std = @import("std");
const proto = @import("wmux_proto");

const App = @import("../App.zig");
const app_logger = @import("../app/logger.zig");
const app_paths = @import("../app/paths.zig");
const config_files = @import("legacy_config_files.zig");
const debounce = @import("logic/debounce.zig");
const events = @import("../model/events.zig");
const ghostty_layer = @import("ghostty_layer.zig");
const layers = @import("logic/layers.zig");
const legacy_keys = @import("legacy_keys.zig");
const lifecycle = @import("../features/lifecycle.zig");
const loader = @import("loader.zig");
const notice = @import("../ui/notice.zig");
const policy = @import("policy.zig");
const snapshot = @import("snapshot.zig");
const w32 = @import("../platform/win32.zig");
const watcher_mod = @import("watcher.zig");

const Allocator = std.mem.Allocator;
const Spec = proto.settings.spec.Spec;
const specs_manifest = proto.settings.specs_manifest;
const resolve = proto.settings.resolve;

const log = std.log.scoped(.settings);

pub const Snapshot = snapshot.Snapshot;
pub const Change = layers.Change;
pub const Source = layers.Source;

/// Notice ids raised by the settings layer.
pub const parse_error_notice = "settings.parse_error";
pub const invalid_values_notice = "settings.invalid_values";

/// What `onSettingsChanged(app, diff)` receives after a reload.
pub const Diff = struct {
    /// Revision of the new snapshot.
    rev: u64,
    /// Settings whose value, source or policy lock changed.
    changes: []const Change,
    /// The new snapshot (valid for the duration of the call).
    snapshot: *const Snapshot,

    pub fn changed(self: *const Diff, path: []const u8) bool {
        for (self.changes) |c| if (std.mem.eql(u8, c.path, path)) return true;
        return false;
    }
};

const State = struct {
    gpa: ?Allocator = null,
    app: ?*App = null,
    holder: snapshot.Holder = .{},
    watcher: ?*watcher_mod.Watcher = null,
    /// The thread timer that starts the watcher from the message loop.
    ready_timer: usize = 0,
};

var state: State = .{};

/// Load the settings layers (rev 1), write the Ghostty overrides file,
/// re-load the Ghostty configuration with the overlay and overrides when
/// they hold settings, and prepare the watcher. The watcher thread starts
/// from the first message-loop turn, once `app.tasks` can deliver (App.init
/// creates the task queue after this call).
pub fn init(app: *App) !void {
    const gpa = app.core_app.alloc;
    state = .{ .gpa = gpa, .app = app };
    // The log file before the first settings line (idempotent; the first
    // window would start it otherwise).
    app_logger.start(gpa, &app.runtime_env);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const base = try baseInputs(a, app);
    var pol = try policy.read(gpa, base.policy_file);
    var pol_owned = true;
    defer if (pol_owned) pol.deinit();
    const pairs = try legacy_keys.collect(a, &app.config);

    var outcome = try loader.load(gpa, .{
        .cmux_path = base.cmux_path,
        .wmux_path = base.wmux_path,
        .project_cwd = base.project_cwd,
        .home = base.home,
        .ghostty_pairs = pairs,
        .policy = pol.items,
        .policy_file = base.policy_file,
    });
    const snap: *Snapshot = switch (outcome) {
        .ok => |s| s,
        .failed => |*f| failed: {
            defer f.deinit();
            reportFailure(app, f.errors, .{});
            // No last good snapshot yet: start from defaults, the legacy
            // Ghostty keys and policy until the files are fixed. The
            // records keep the broken files watched.
            const fallback = try loader.load(gpa, .{ .ghostty_pairs = pairs, .policy = pol.items, .policy_file = base.policy_file });
            const s = fallback.ok;
            const sa = s.allocator();
            const recs = try sa.alloc(snapshot.FileRecord, f.files.len);
            for (f.files, recs) |r, *o| o.* = .{ .kind = r.kind, .path = try sa.dupe(u8, r.path), .hash = r.hash };
            s.files = recs;
            break :failed s;
        },
    };

    // The overrides file of this snapshot, then the Ghostty configuration
    // with the overlay and overrides when either holds a setting.
    if (ghostty_layer.overridesPath(gpa, &app.runtime_env)) |path| {
        defer gpa.free(path);
        _ = ghostty_layer.writeIfChanged(gpa, path, snap.ghostty_overrides) catch |err|
            log.warn("settings overrides write failed: {}", .{err});
    } else |_| {}
    if (ghostty_layer.extrasPresent(gpa, &app.runtime_env)) {
        if (ghostty_layer.loadConfig(gpa, &app.runtime_env)) |cfg| {
            app.config.deinit();
            app.config = cfg;
            log.info("ghostty config loaded with the wmux overlay and settings overrides", .{});
        } else |err| log.warn("ghostty config with overlay failed to load: {}", .{err});
    }
    ghostty_layer.reportDiagnostics(app, &app.config);

    publish(app, snap, .{});

    const gfiles = try ghostty_layer.watchedFiles(gpa, &app.config, &app.runtime_env);
    defer ghostty_layer.freeWatched(gpa, gfiles);
    state.watcher = watcher_mod.Watcher.create(gpa, app, base, snap.files, pairs, gfiles, pol) catch |err| blk: {
        log.warn("settings watcher unavailable: {}", .{err});
        break :blk null;
    };
    if (state.watcher != null) pol_owned = false;
    state.ready_timer = w32.SetTimer(null, 0, 10, @ptrCast(&onReady));
}

/// The message loop runs: start the watcher and show startup notices.
fn onReady(hwnd: ?w32.HWND, msg: u32, id: usize, time: u32) callconv(.winapi) void {
    _ = hwnd;
    _ = msg;
    _ = time;
    const app = state.app orelse return;
    // Only from App.run's loop (msg_hwnd and app.tasks exist), never from
    // a modal loop inside App.init.
    if (app.msg_hwnd == null) return;
    _ = w32.KillTimer(null, id);
    state.ready_timer = 0;
    if (state.watcher) |w| w.start();
    notice.refresh(app);
}

fn baseInputs(a: Allocator, app: *App) !watcher_mod.BaseInputs {
    const home = std.process.getEnvVarOwned(a, "USERPROFILE") catch null;
    const xdg = std.process.getEnvVarOwned(a, "XDG_CONFIG_HOME") catch null;
    const cmux = try resolve.cmuxGlobalPath(a, .{ .xdg_config_home = xdg, .home = home });
    const wmux = if (app_paths.configDir(a, &app.runtime_env)) |dir|
        try std.fs.path.join(a, &.{ dir, "wmux.json" })
    else |_|
        null;
    const cwd = std.process.getCwdAlloc(a) catch null;
    return .{
        .cmux_path = cmux,
        .wmux_path = wmux,
        .project_cwd = cwd,
        .home = home,
        .policy_file = policy.testFilePath(a, app.runtime_env.test_mode),
    };
}

/// Stop the watcher and free the settings.
pub fn deinit(app: *App) void {
    if (state.ready_timer != 0) _ = w32.KillTimer(null, state.ready_timer);
    if (state.watcher) |w| w.destroy();
    if (state.holder.swap(null)) |s| s.release();
    notice.deinit(app);
    state = .{};
}

/// The current snapshot, borrowed (UI thread; valid until the next
/// reload task runs). Null before `init`.
pub fn current(app: *const App) ?*const Snapshot {
    _ = app;
    return state.holder.current();
}

/// The current snapshot with a reference for a worker thread, which
/// calls `release` when done. Any thread.
pub fn acquire(app: *const App) ?*Snapshot {
    _ = app;
    return state.holder.acquire();
}

/// Re-read every JSON layer now (`config reload`, reloadConfiguration).
pub fn reload(app: *App) void {
    _ = app;
    if (state.watcher) |w| w.requestReload();
}

/// The `.reload_config` action: a soft reload re-applies the Ghostty
/// configuration; a hard one (reloadConfiguration, Ctrl+Shift+,) reloads
/// the Ghostty files and every JSON layer.
pub fn reloadConfiguration(app: *App, soft: bool) void {
    if (soft) {
        _ = config_files.reloadConfig(app, true);
        return;
    }
    reloadGhostty(app, "manual");
    reload(app);
}

/// Hard-reloads the Ghostty configuration (with the overlay and the
/// overrides) and hands its files and legacy keys to the watcher. UI thread.
pub fn reloadGhostty(app: *App, reason: []const u8) void {
    if (!config_files.reloadConfig(app, false)) return;
    log.info("ghostty config reloaded reason={s}", .{reason});
    afterGhosttyLoad(app);
}

fn afterGhosttyLoad(app: *App) void {
    const gpa = app.core_app.alloc;
    ghostty_layer.reportDiagnostics(app, &app.config);
    const w = state.watcher orelse return;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const pairs = legacy_keys.collect(arena_state.allocator(), &app.config) catch return;
    const files = ghostty_layer.watchedFiles(gpa, &app.config, &app.runtime_env) catch return;
    defer ghostty_layer.freeWatched(gpa, files);
    w.setGhostty(files, pairs);
}

/// A watcher result (UI thread, from its app.tasks task).
pub fn onReload(app: *App, task: *watcher_mod.ReloadTask) void {
    if (state.gpa == null) return;
    switch (task.outcome) {
        .failed => |f| reportFailure(app, f.errors, task.triggers),
        .ok => |s| {
            publish(app, s.retain(), task.triggers);
            if (task.overrides_changed) reloadGhostty(app, "settings-overrides");
        },
    }
}

fn reportFailure(app: *App, errors: []const layers.FileError, triggers: debounce.Triggers) void {
    const gpa = app.core_app.alloc;
    var buf: [64]u8 = undefined;
    const rev: u64 = if (state.holder.current()) |s| s.rev else 0;
    log.warn("settings reload failed source={s} errors={d}; keeping rev={d}", .{ triggers.format(&buf), errors.len, rev });
    for (errors[0..@min(errors.len, layers.max_notice_errors)]) |e| {
        if (e.pos) |p| {
            log.warn("settings error {s}:{d}:{d}: {s}", .{ e.path, p.line, p.col, e.message });
        } else log.warn("settings error {s}: {s}", .{ e.path, e.message });
    }
    const body = layers.noticeBody(gpa, errors) catch return;
    defer gpa.free(body);
    notice.show(app, .{
        .id = parse_error_notice,
        .level = .@"error",
        .title = "Settings file has errors; the last good settings stay in effect",
        .body = body,
        .action = if (errors.len > 0) .{ .label = "Open", .target = .{ .open = errors[0].path } } else null,
    });
}

/// Publishes `snap` (taking over its reference) as the next revision.
fn publish(app: *App, snap: *Snapshot, triggers: debounce.Triggers) void {
    const gpa = app.core_app.alloc;
    const prev_rev: u64 = if (state.holder.current()) |p| p.rev else 0;
    snap.rev = prev_rev + 1;
    const old = state.holder.swap(snap);
    defer if (old) |o| o.release();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const changes = layers.diff(a, if (old) |o| &o.resolved else null, &snap.resolved) catch &.{};

    var buf: [64]u8 = undefined;
    const label = triggers.format(&buf);
    if (old == null) {
        log.info("settings loaded rev={d} source={s} keys={d} configured={d}", .{ snap.rev, label, snap.resolved.entries.len, changes.len });
    } else {
        log.info("settings reloaded rev={d} source={s} changed={d}", .{ snap.rev, label, changes.len });
    }
    for (changes) |c| {
        log.info("settings key {s}={s} source={s}{s}", .{ c.path, c.json, c.source.label(), if (c.locked) " locked" else "" });
    }
    for (snap.warnings) |wr| {
        if (wr.pos) |p| {
            log.warn("settings warning {s}:{d}:{d}: {s}", .{ wr.path, p.line, p.col, wr.message });
        } else log.warn("settings warning {s}: {s}", .{ wr.path, wr.message });
    }
    for (snap.resolved.rejected) |r| {
        log.warn("settings value rejected {s} source={s}: {s}", .{ r.path, r.source.label(), r.message });
    }

    notice.dismiss(app, parse_error_notice);
    if (snap.resolved.rejected.len > 0) {
        const errs = a.alloc(layers.FileError, snap.resolved.rejected.len) catch return;
        for (snap.resolved.rejected[0..errs.len], errs) |r, *e| e.* = .{
            .path = std.fmt.allocPrint(a, "{s} ({s})", .{ r.path, r.source.label() }) catch r.path,
            .pos = r.pos,
            .message = r.message,
        };
        if (layers.noticeBody(gpa, errs)) |body| {
            defer gpa.free(body);
            notice.show(app, .{ .id = invalid_values_notice, .level = .warning, .title = "Some settings have invalid values and use the next layer", .body = body });
        } else |_| {}
    } else notice.dismiss(app, invalid_values_notice);

    if (old == null) return;
    // Fan-out (ADR-5.4): features, then the events.
    if (app.features_initialized) {
        const diff: Diff = .{ .rev = snap.rev, .changes = changes, .snapshot = snap };
        lifecycle.onSettingsChanged(app, &diff);
    }
    const keys = a.alloc([]const u8, changes.len) catch return;
    for (changes[0..keys.len], keys) |c, *k| k.* = c.path;
    const Payload = struct { changed_keys: []const []const u8 };
    const payload: Payload = .{ .changed_keys = keys };
    var ev = events.Event.of("wmux.settings.changed");
    ev.payload = events.Payload.of(Payload, &payload);
    events.emit(app, ev);
    const Empty = struct {};
    const empty: Empty = .{};
    var reloaded = events.Event.of("config.reloaded");
    reloaded.source = "settings.watcher";
    reloaded.payload = events.Payload.of(Empty, &empty);
    events.emit(app, reloaded);
}

// ---------------------------------------------------------------------------
// Typed access (ADR-5.2)

/// The Zig type `get` returns for the setting at `path` (a compile error
/// for an unknown path): `bool` for booleans, `i64` for integers, `f64`
/// for numbers, the string (without quotes) for strings, enumerations,
/// colors and paths, and the JSON text for string lists, objects and
/// strokes.
pub fn Value(comptime path: []const u8) type {
    return ValueIn(specs_manifest.all, path);
}

/// The effective value of the setting at `path` for `app` (UI thread;
/// worker threads `acquire` a snapshot). A path that no spec declares is a
/// compile error. Strings borrow from the current snapshot: valid on the
/// UI thread until the next reload task runs. Before `init` (and in
/// tests) it returns the spec default.
pub fn get(app: *const App, comptime path: []const u8) Value(path) {
    _ = app;
    return getIn(specs_manifest.all, state.holder.current(), path);
}

/// `get` over an explicit spec list and snapshot (tests).
pub fn getIn(comptime specs: []const Spec, snap: ?*const Snapshot, comptime path: []const u8) ValueIn(specs, path) {
    const fallback = comptime defaultIn(specs, path);
    const s = snap orelse return fallback;
    const e = s.get(path) orelse return fallback;
    const spec = comptime findSpec(specs, path);
    return switch (spec.ty) {
        .boolean => e.value.asBool() orelse fallback,
        .integer => e.value.asInt() orelse fallback,
        .number => e.value.asFloat() orelse fallback,
        .string, .enumeration, .color, .path => e.value.asString() orelse fallback,
        .string_list, .object, .strokes => e.json,
    };
}

/// `Value` over an explicit spec list (tests).
pub fn ValueIn(comptime specs: []const Spec, comptime path: []const u8) type {
    const s = comptime findSpec(specs, path);
    return switch (s.ty) {
        .boolean => bool,
        .integer => i64,
        .number => f64,
        .string, .enumeration, .color, .path => []const u8,
        .string_list, .object, .strokes => []const u8,
    };
}

/// The default of the setting at `path` in `specs`, typed as `ValueIn`.
pub fn defaultIn(comptime specs: []const Spec, comptime path: []const u8) ValueIn(specs, path) {
    comptime {
        const s = findSpec(specs, path);
        const lit = std.mem.trim(u8, s.default, " \t\r\n");
        return switch (s.ty) {
            .boolean => std.mem.eql(u8, lit, "true"),
            .integer => std.fmt.parseInt(i64, lit, 10) catch @compileError("settings: integer default of '" ++ path ++ "'"),
            .number => std.fmt.parseFloat(f64, lit) catch @compileError("settings: number default of '" ++ path ++ "'"),
            .string, .enumeration, .color, .path => unquote(path, lit),
            .string_list, .object, .strokes => lit,
        };
    }
}

fn findSpec(comptime specs: []const Spec, comptime path: []const u8) Spec {
    comptime {
        @setEvalBranchQuota(100_000);
        for (specs) |s| {
            if (std.mem.eql(u8, s.path, path)) return s;
        }
        @compileError("settings: no spec declares '" ++ path ++ "' (wmux_proto/settings/specs/*.zig)");
    }
}

/// A JSON string literal without its quotes (spec defaults are validated
/// at comptime; escapes are not expected in string defaults).
fn unquote(comptime path: []const u8, comptime lit: []const u8) []const u8 {
    comptime {
        if (lit.len < 2 or lit[0] != '"' or lit[lit.len - 1] != '"')
            @compileError("settings: string default of '" ++ path ++ "' is not a JSON string");
        const inner = lit[1 .. lit.len - 1];
        if (std.mem.indexOfScalar(u8, inner, '\\') != null)
            @compileError("settings: escaped string default of '" ++ path ++ "' (extend unquote)");
        return inner;
    }
}

test {
    _ = @import("ghostty_layer.zig");
    _ = @import("legacy_keys.zig");
    _ = @import("loader.zig");
    _ = @import("policy.zig");
    _ = @import("snapshot.zig");
    _ = @import("watcher.zig");
    _ = @import("logic/tests.zig");
}

const fixture_specs: []const Spec = &proto.settings.validate.test_fixture_specs;

test "unit: settings: get returns spec defaults until the layer lands" {
    const specs = [_]Spec{
        .{ .path = "sidebar.showPorts", .ty = .boolean, .default = "true", .section = "sidebarAppearance", .label = "Show ports", .doc = "" },
        .{ .path = "wmux.sidebar.width", .ty = .{ .integer = .{ .min = 120, .max = 600 } }, .default = "220", .section = "sidebarAppearance", .label = "Width", .doc = "", .cmux_compat = false },
        .{ .path = "app.appearance", .ty = .{ .enumeration = &.{ "system", "light", "dark" } }, .default = "\"system\"", .section = "app", .label = "Theme", .doc = "" },
        .{ .path = "x.opacity", .ty = .{ .number = .{ .min = 0, .max = 1 } }, .default = "0.5", .section = "app", .label = "Opacity", .doc = "" },
        .{ .path = "x.list", .ty = .string_list, .default = "[\"a\"]", .section = "app", .label = "List", .doc = "" },
    };
    const testing = std.testing;
    try testing.expect(ValueIn(&specs, "sidebar.showPorts") == bool);
    try testing.expectEqual(true, comptime defaultIn(&specs, "sidebar.showPorts"));
    try testing.expectEqual(@as(i64, 220), comptime defaultIn(&specs, "wmux.sidebar.width"));
    try testing.expectEqualStrings("system", comptime defaultIn(&specs, "app.appearance"));
    try testing.expectEqual(@as(f64, 0.5), comptime defaultIn(&specs, "x.opacity"));
    try testing.expectEqualStrings("[\"a\"]", comptime defaultIn(&specs, "x.list"));
    try testing.expectEqual(true, getIn(&specs, null, "sidebar.showPorts"));
}

test "unit: settings: get reads the current snapshot" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const root = try proto.jsonc.parseInto(arena_state.allocator(),
        \\{"app": {"appearance": "dark", "paneResizeStepPixels": 42}, "terminal": {"scrollSpeed": 2.5},
        \\ "browser": {"urlAllowlist": ["localhost"]}, "wmux": {"sidebar": {"visible": false}}}
    , .{}, null);
    const snap = try Snapshot.create(gpa, try resolve.resolve(gpa, fixture_specs, &.{.{ .source = .wmux_json, .root = &root }}, &.{}));
    defer snap.release();
    try testing.expectEqualStrings("dark", getIn(fixture_specs, snap, "app.appearance"));
    try testing.expectEqual(@as(i64, 42), getIn(fixture_specs, snap, "app.paneResizeStepPixels"));
    try testing.expectEqual(@as(f64, 2.5), getIn(fixture_specs, snap, "terminal.scrollSpeed"));
    try testing.expectEqual(false, getIn(fixture_specs, snap, "wmux.sidebar.visible"));
    try testing.expectEqualStrings("[\"localhost\"]", getIn(fixture_specs, snap, "browser.urlAllowlist"));
    try testing.expectEqual(false, getIn(fixture_specs, snap, "app.minimalMode")); // default
    var d: Diff = .{ .rev = 2, .changes = &.{.{ .path = "app.appearance", .json = "\"dark\"", .old_json = null, .source = .wmux_json, .locked = false }}, .snapshot = snap };
    try testing.expect(d.changed("app.appearance"));
    try testing.expect(!d.changed("app.minimalMode"));
}
