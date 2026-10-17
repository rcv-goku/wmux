//! The core `wmux.debug.*` test hooks (ARCHITECTURE.md ADR-12.3,
//! Appendix B.3, AF-14, AF-19; W1-1a). They exist only in WMUX_TEST_MODE
//! (`test_only`, never listed or served otherwise) and drive or observe
//! the app the way a user would, without touching the OS foreground:
//!
//! | method | lane | what |
//! |---|---|---|
//! | `ready` | ui | `{ready}` once a window exists (the harness polls it) |
//! | `app.quit` | ui | graceful quit: close the windows, wait for WebView2 to exit, quit |
//! | `dialogs.list` / `dialogs.answer` | ui | auto-answered message boxes; queue the next answers |
//! | `clipboard.get` / `clipboard.set` | ui | the fake in-process clipboard |
//! | `focus_state` | ui | logical focus: window, workspace, pane, surface, rename edit, modal depth, hotkeys |
//! | `layout` | ui | windows → workspaces (display order) → panes → surfaces, with pids |
//! | `type` / `key` | ui | text and keys delivered to the focused (or selected) control |
//! | `menu.list` / `menu.invoke` | ui | MenuBuilder introspection of a menu site |
//! | `timers` | ui | the running `app.timers` |
//! | `external_open.list` / `sounds.list` | worker | the W0-A4 test sinks |
//!
//! `focus_state.hotkeys` comes from a provider other features register with
//! `setHotkeysProvider` (W1-5b fills it), so they never edit this file.
//! Feature-specific hooks live in each owner's `features/<id>/debug.zig`
//! (`debug_methods`, aggregated by rpc/registry.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");

const App = @import("../../App.zig");
const Pane = @import("../../model/Pane.zig");
const Tab = @import("../../model/Tab.zig");
const Window = @import("../../ui/Window.zig");
const Workspace = @import("../../model/Workspace.zig");
const dialogs = @import("../../app/dialogs.zig");
const env_identity = @import("../env_identity/api.zig");
const menus = @import("../../ui/menus.zig");
const rpc = @import("../../rpc/types.zig");
const router = @import("../../rpc/router.zig");
const single_instance = @import("../../app/single_instance.zig");
const tasks = @import("../../app/tasks.zig");
const w32 = @import("../../platform/win32.zig");
const web_env = @import("../../web/env.zig");

const Ctx = rpc.Ctx;
const Error = rpc.Error;
const Uuid = proto.uuid.Uuid;
const Ref = proto.handles.Ref;

const log = std.log.scoped(.debug);

fn oom(ctx: *Ctx) Error {
    return ctx.fail(.internal_error, "Out of memory", null);
}

// ---------------------------------------------------------------------------
// Hotkeys provider (W1-5b)
// ---------------------------------------------------------------------------

/// Fills `focus_state.hotkeys` (UI thread): any JSON value allocated in
/// `arena`, e.g. the effective bindings of the focused context.
pub const HotkeysProvider = *const fn (app: *App, arena: Allocator) anyerror!std.json.Value;

var hotkeys_provider: ?HotkeysProvider = null;

/// Registers (or clears, with null) the `focus_state.hotkeys` provider.
/// UI thread (a feature's `init`).
pub fn setHotkeysProvider(provider: ?HotkeysProvider) void {
    hotkeys_provider = provider;
}

// ---------------------------------------------------------------------------
// ready, app.quit
// ---------------------------------------------------------------------------

fn openWindows(app: *App) usize {
    var n: usize = 0;
    for (app.windows.items) |w| {
        if (!w.closing) n += 1;
    }
    return n;
}

pub fn ready(ctx: *Ctx) Error!void {
    const n = openWindows(ctx.app);
    ctx.ok(.{ .ready = n > 0, .windows = n, .pid = w32.GetCurrentProcessId(), .protocol = 2 });
}

/// The longest `app.quit` waits for the WebView2 browser process.
pub const browser_exit_timeout_ms: u32 = 10_000;

const QuitTask = struct {
    task: tasks.Task = .{ .run = run, .destroy = destroy },
    gpa: Allocator,

    fn run(app: *App, task: *tasks.Task) void {
        _ = task;
        const gpa = app.core_app.alloc;
        // Window.close destroys the window (and drops it from the list):
        // close a snapshot of the list.
        const list = gpa.dupe(*Window, app.windows.items) catch &.{};
        defer if (list.len > 0) gpa.free(list);
        for (list) |w| {
            if (!w.closing) w.close();
        }
        if (!web_env.waitForBrowserExit(app, browser_exit_timeout_ms))
            log.warn("app.quit: the WebView2 browser process did not exit within {d} ms", .{browser_exit_timeout_ms});
        app.quit_requested = true;
        w32.PostQuitMessage(0);
    }

    fn destroy(task: *tasks.Task) void {
        const self: *QuitTask = @fieldParentPtr("task", task);
        self.gpa.destroy(self);
    }
};

/// Replies `{quitting:true}`, then (on the next UI-thread turn) closes
/// every window without confirmation or session save, waits for the
/// WebView2 browser process to exit (AF-5) and quits the message loop.
pub fn appQuit(ctx: *Ctx) Error!void {
    const gpa = ctx.app.core_app.alloc;
    const t = gpa.create(QuitTask) catch return oom(ctx);
    t.* = .{ .gpa = gpa };
    ctx.app.tasks.post(&t.task);
    ctx.ok(.{ .quitting = true });
}

// ---------------------------------------------------------------------------
// dialogs, clipboard
// ---------------------------------------------------------------------------

pub fn dialogsList(ctx: *Ctx) Error!void {
    const list = dialogs.testRecords(ctx.arena) catch return oom(ctx);
    ctx.ok(.{ .dialogs = list });
}

/// `{answer: "ok"|"cancel"|"yes"|"no"|... | <button id>}`: the next
/// test-mode message box returns it instead of its default button.
pub fn dialogsAnswer(ctx: *Ctx) Error!void {
    const v = ctx.raw_params.get("answer") orelse return ctx.fail(.invalid_params, "Missing answer", .{ .param = "answer" });
    const id: i32 = switch (v) {
        .integer => |i| std.math.cast(i32, i) orelse return ctx.fail(.invalid_params, "Invalid answer", .{ .param = "answer" }),
        .string => |s| dialogs.answerIdByName(s) orelse return ctx.fail(.invalid_params, "Invalid answer", .{ .param = "answer" }),
        else => return ctx.fail(.invalid_params, "Invalid answer", .{ .param = "answer" }),
    };
    const queued = dialogs.presetAnswer(id) catch return oom(ctx);
    ctx.ok(.{ .answer = id, .queued = queued });
}

fn requireFakeClipboard(ctx: *Ctx) Error!void {
    if (!ctx.app.clipboard.fake) return ctx.fail(.invalid_state, "The fake clipboard exists only in WMUX_TEST_MODE", null);
}

pub fn clipboardGet(ctx: *Ctx) Error!void {
    try requireFakeClipboard(ctx);
    const text = ctx.app.clipboard.readText(ctx.arena, null);
    ctx.ok(.{ .text = text });
}

pub fn clipboardSet(ctx: *Ctx) Error!void {
    try requireFakeClipboard(ctx);
    const text = (try ctx.param([]const u8, "text")) orelse return ctx.fail(.invalid_params, "Missing text", .{ .param = "text" });
    ctx.app.clipboard.writeText(ctx.arena, null, text) catch return oom(ctx);
    ctx.ok(.{ .text = text });
}

// ---------------------------------------------------------------------------
// focus_state, layout
// ---------------------------------------------------------------------------

const FocusState = struct {
    window_id: ?Uuid = null,
    window_ref: ?Ref = null,
    workspace_id: ?Uuid = null,
    workspace_ref: ?Ref = null,
    /// Display index (ADR-2.4).
    workspace_index: ?usize = null,
    pane_id: ?Uuid = null,
    pane_ref: ?Ref = null,
    surface_id: ?Uuid = null,
    surface_ref: ?Ref = null,
    surface_type: ?[]const u8 = null,
    /// An inline rename edit is open.
    edit: bool = false,
    /// What it renames: "tab", "workspace" or "description".
    edit_target: ?[]const u8 = null,
    modal_depth: u32 = 0,
    hotkeys: ?std.json.Value = null,
};

/// Logical focus (ADR-12.3: the asserted truth, never GetFocus): the
/// active window, its selected workspace, focused pane and selected tab.
pub fn focusState(ctx: *Ctx) Error!void {
    const app = ctx.app;
    var st: FocusState = .{ .modal_depth = app.modal.depth };
    if (hotkeys_provider) |p| st.hotkeys = p(app, ctx.arena) catch |err| blk: {
        log.warn("hotkeys provider failed: {}", .{err});
        break :blk null;
    };
    if (router.activeWindow(app)) |w| {
        st.window_id = w.handle.uuid;
        st.window_ref = w.handle.refOf(.window);
        st.edit = w.rename_edit != null;
        if (st.edit) st.edit_target = @tagName(w.rename_target);
        if (w.selected) |ws| {
            st.workspace_id = ws.handle.uuid;
            st.workspace_ref = ws.handle.refOf(.workspace);
            st.workspace_index = router.displayIndexOf(ctx.arena, ws) catch return oom(ctx);
            if (ws.focusedPaneOrFirst()) |pane| {
                st.pane_id = pane.handle.uuid;
                st.pane_ref = pane.handle.refOf(.pane);
                if (pane.selectedTab()) |tab| {
                    st.surface_id = tab.handle.uuid;
                    st.surface_ref = tab.handle.refOf(.surface);
                    st.surface_type = tab.content.kindName();
                }
            }
        }
    }
    ctx.ok(st);
}

const SurfaceJson = struct {
    surface_id: Uuid,
    surface_ref: Ref,
    index: usize,
    type: []const u8,
    title: ?[]const u8,
    selected: bool,
    pids: []const u32,
};

const PaneJson = struct {
    pane_id: Uuid,
    pane_ref: Ref,
    index: usize,
    focused: bool,
    surfaces: []const SurfaceJson,
};

const WorkspaceJson = struct {
    workspace_id: Uuid,
    workspace_ref: Ref,
    index: usize,
    title: ?[]const u8,
    cwd: ?[]const u8,
    pinned: bool,
    selected: bool,
    panes: []const PaneJson,
};

const WindowJson = struct {
    window_id: Uuid,
    window_ref: Ref,
    index: usize,
    active: bool,
    workspaces: []const WorkspaceJson,
};

fn paneJson(arena: Allocator, pane: *Pane, index: usize, focused: bool) Allocator.Error!PaneJson {
    const surfaces = try arena.alloc(SurfaceJson, pane.tabs.items.len);
    for (pane.tabs.items, surfaces, 0..) |tab, *s, i| {
        const pids: []const u32 = if (tab.surface()) |surface| try env_identity.processIds(arena, surface) else &.{};
        s.* = .{
            .surface_id = tab.handle.uuid,
            .surface_ref = tab.handle.refOf(.surface),
            .index = i,
            .type = tab.content.kindName(),
            .title = tab.titleText(),
            .selected = i == pane.selected,
            .pids = pids,
        };
    }
    return .{ .pane_id = pane.handle.uuid, .pane_ref = pane.handle.refOf(.pane), .index = index, .focused = focused, .surfaces = surfaces };
}

fn workspaceJson(arena: Allocator, ws: *Workspace, display_index: usize, selected: bool) Allocator.Error!WorkspaceJson {
    var panes: std.ArrayList(PaneJson) = .empty;
    const focused = ws.focusedPaneOrFirst();
    var i: usize = 0;
    while (@import("../../model/registry.zig").paneAtDepthFirst(ws, i)) |pane| : (i += 1) {
        try panes.append(arena, try paneJson(arena, pane, i, pane == focused));
    }
    return .{
        .workspace_id = ws.handle.uuid,
        .workspace_ref = ws.handle.refOf(.workspace),
        .index = display_index,
        .title = ws.name(),
        .cwd = ws.cwd,
        .pinned = ws.pinned,
        .selected = selected,
        .panes = panes.items,
    };
}

/// The whole model: windows (creation order) → workspaces (display order)
/// → panes (depth-first) → surfaces (tab order), plus the launches the
/// launch pipe received.
pub fn layout(ctx: *Ctx) Error!void {
    const app = ctx.app;
    const arena = ctx.arena;
    const active = router.activeWindow(app);
    var windows: std.ArrayList(WindowJson) = .empty;
    for (app.windows.items, 0..) |w, wi| {
        if (w.closing) continue;
        const order = router.displayOrder(arena, w) catch return oom(ctx);
        const wss = arena.alloc(WorkspaceJson, order.len) catch return oom(ctx);
        for (order, wss, 0..) |list_index, *out, di| {
            const ws = w.workspaces.items[list_index];
            out.* = workspaceJson(arena, ws, di, w.selected == ws) catch return oom(ctx);
        }
        windows.append(arena, .{
            .window_id = w.handle.uuid,
            .window_ref = w.handle.refOf(.window),
            .index = wi,
            .active = active == w,
            .workspaces = wss,
        }) catch return oom(ctx);
    }
    const launches = single_instance.recentLaunches();
    ctx.ok(.{ .windows = windows.items, .launches = launches.items, .launch_count = launches.total });
}

// ---------------------------------------------------------------------------
// type, key
// ---------------------------------------------------------------------------

const Target = struct { hwnd: w32.HWND, kind: []const u8 };

/// Where typed input goes: the selected surface when a selector is given,
/// else the open rename edit of the active window, else its selected
/// surface (logical focus, never GetFocus).
fn inputTarget(ctx: *Ctx) Error!Target {
    const sel = try ctx.selectors();
    if (sel.isEmpty()) {
        const w = router.activeWindow(ctx.app) orelse return ctx.fail(.not_found, proto.errors.msg.no_focused_surface, null);
        if (w.rename_edit) |edit| return .{ .hwnd = edit, .kind = "rename_edit" };
    }
    const tab = try ctx.resolveTab(sel);
    const hwnd = tab.hwnd() orelse return ctx.fail(.surface_unavailable, "Surface has no window yet", null);
    return .{ .hwnd = hwnd, .kind = tab.content.kindName() };
}

/// `{text}` → one WM_CHAR per UTF-16 unit to the input target.
pub fn typeText(ctx: *Ctx) Error!void {
    const text = (try ctx.param([]const u8, "text")) orelse return ctx.fail(.invalid_params, "Missing text", .{ .param = "text" });
    const target = try inputTarget(ctx);
    const units = std.unicode.utf8ToUtf16LeAlloc(ctx.arena, text) catch return ctx.fail(.invalid_params, "Invalid text: not UTF-8", .{ .param = "text" });
    for (units) |u| _ = w32.SendMessageW(target.hwnd, w32.WM_CHAR, u, 1);
    ctx.ok(.{ .sent = units.len, .target = target.kind });
}

extern "user32" fn SetKeyboardState(lpKeyState: *const [256]u8) callconv(.winapi) i32;
extern "user32" fn MapVirtualKeyW(uCode: u32, uMapType: u32) callconv(.winapi) u32;

/// One parsed key chord (`ctrl+shift+t`, `enter`, `f5`, `a`).
pub const Chord = struct {
    vk: u16,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    /// The WM_CHAR the key produces, if any (after modifiers).
    char: ?u16 = null,
    extended: bool = false,
};

/// Parses a chord: modifiers `ctrl`/`control`, `shift`, `alt` joined with
/// `+`, then one key: a letter, a digit, `enter`, `escape`, `tab`,
/// `backspace`, `space`, `delete`, `insert`, `home`, `end`, `pageup`,
/// `pagedown`, `left`, `right`, `up`, `down` or `f1`..`f12`. Null when
/// malformed. Pure (unit-tested).
pub fn parseChord(text: []const u8) ?Chord {
    var c: Chord = .{ .vk = 0 };
    var it = std.mem.splitScalar(u8, text, '+');
    var key_name: ?[]const u8 = null;
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " ");
        if (part.len == 0) return null;
        if (key_name != null) return null; // the key must be last
        if (std.ascii.eqlIgnoreCase(part, "ctrl") or std.ascii.eqlIgnoreCase(part, "control")) {
            c.ctrl = true;
        } else if (std.ascii.eqlIgnoreCase(part, "shift")) {
            c.shift = true;
        } else if (std.ascii.eqlIgnoreCase(part, "alt")) {
            c.alt = true;
        } else key_name = part;
    }
    const k = key_name orelse return null;
    if (k.len == 1 and std.ascii.isAlphanumeric(k[0])) {
        const ch = std.ascii.toLower(k[0]);
        c.vk = std.ascii.toUpper(ch);
        if (c.alt) return c;
        if (c.ctrl) {
            if (std.ascii.isAlphabetic(ch)) c.char = ch - 'a' + 1;
        } else if (std.ascii.isAlphabetic(ch)) {
            c.char = if (c.shift) std.ascii.toUpper(ch) else ch;
        } else if (!c.shift) c.char = ch;
        return c;
    }
    const Named = struct { []const u8, u16, ?u16, bool };
    const named = [_]Named{
        .{ "enter", 0x0D, '\r', false },   .{ "return", 0x0D, '\r', false }, .{ "escape", 0x1B, 0x1B, false },
        .{ "esc", 0x1B, 0x1B, false },     .{ "tab", 0x09, '\t', false },    .{ "backspace", 0x08, 0x08, false },
        .{ "space", 0x20, ' ', false },    .{ "delete", 0x2E, null, true },  .{ "insert", 0x2D, null, true },
        .{ "home", 0x24, null, true },     .{ "end", 0x23, null, true },     .{ "pageup", 0x21, null, true },
        .{ "pagedown", 0x22, null, true }, .{ "left", 0x25, null, true },    .{ "up", 0x26, null, true },
        .{ "right", 0x27, null, true },    .{ "down", 0x28, null, true },
    };
    for (named) |n| {
        if (!std.ascii.eqlIgnoreCase(n[0], k)) continue;
        c.vk = n[1];
        c.extended = n[3];
        if (!c.ctrl and !c.alt) c.char = n[2];
        return c;
    }
    if ((k[0] == 'f' or k[0] == 'F') and k.len >= 2 and k.len <= 3) {
        const n = std.fmt.parseInt(u8, k[1..], 10) catch return null;
        if (n < 1 or n > 12) return null;
        c.vk = 0x70 + @as(u16, n - 1);
        return c;
    }
    return null;
}

/// `{key: "ctrl+shift+t"}` → WM_KEYDOWN (+ WM_CHAR) + WM_KEYUP to the input
/// target, with the modifiers set in this (UI) thread's keyboard state for
/// the duration (GetKeyState sees them; other processes never do).
pub fn key(ctx: *Ctx) Error!void {
    const text = (try ctx.param([]const u8, "key")) orelse return ctx.fail(.invalid_params, "Missing key", .{ .param = "key" });
    const chord = parseChord(text) orelse return ctx.fail(.invalid_params, "Invalid key", .{ .param = "key" });
    const target = try inputTarget(ctx);

    var saved: [256]u8 = undefined;
    const have_state = w32.GetKeyboardState(&saved) != 0;
    if (have_state) {
        var state = saved;
        const down: u8 = 0x80;
        if (chord.ctrl) {
            state[w32.VK_CONTROL] = down;
            state[w32.VK_LCONTROL] = down;
        }
        if (chord.shift) {
            state[w32.VK_SHIFT] = down;
            state[0xA0] = down; // VK_LSHIFT
        }
        if (chord.alt) {
            state[w32.VK_MENU] = down;
            state[0xA4] = down; // VK_LMENU
        }
        _ = SetKeyboardState(&state);
    }
    defer if (have_state) {
        _ = SetKeyboardState(&saved);
    };

    const scan: isize = @intCast(MapVirtualKeyW(chord.vk, 0) & 0xFF);
    var lparam: isize = 1 | (scan << 16);
    if (chord.extended) lparam |= 1 << 24;
    const down_msg: u32 = if (chord.alt) 0x0104 else w32.WM_KEYDOWN; // WM_SYSKEYDOWN
    const up_msg: u32 = if (chord.alt) 0x0105 else w32.WM_KEYUP; // WM_SYSKEYUP
    _ = w32.SendMessageW(target.hwnd, down_msg, chord.vk, lparam);
    if (chord.char) |ch| _ = w32.SendMessageW(target.hwnd, w32.WM_CHAR, ch, lparam);
    _ = w32.SendMessageW(target.hwnd, up_msg, chord.vk, lparam | (1 << 30) | (1 << 31));
    ctx.ok(.{ .key = text, .target = target.kind });
}

// ---------------------------------------------------------------------------
// menu.list, menu.invoke
// ---------------------------------------------------------------------------

fn siteParam(ctx: *Ctx) Error!menus.MenuSite {
    const name = (try ctx.param([]const u8, "site")) orelse return ctx.fail(.invalid_params, "Missing site", .{ .param = "site" });
    return menus.siteByName(name) orelse ctx.fail(.invalid_params, "Unknown menu site", .{ .param = "site" });
}

/// The menu context of `site` for the request's selectors (the active
/// window's selection without any).
fn menuContext(ctx: *Ctx, site: menus.MenuSite) Error!menus.Context {
    const sel = try ctx.selectors();
    const window = try ctx.resolveWindow(sel);
    var c: menus.Context = .{ .app = ctx.app, .window = window };
    switch (site) {
        .workspace_row => c.workspace = try ctx.resolveWorkspace(sel),
        .tab => {
            const tab = try ctx.resolveTab(sel);
            const pane = tab.pane orelse return ctx.fail(.not_found, proto.errors.msg.surface_not_found_for_id, null);
            c.workspace = pane.workspace;
            c.pane = pane;
            c.tab = tab;
        },
        .terminal => {
            const tab = try ctx.resolveTab(sel);
            c.surface = tab.surface() orelse return ctx.fail(.invalid_params, "Surface is not a terminal", .{ .selector = "surface_id" });
        },
        else => {},
    }
    if (c.workspace) |ws| if (ws.window != window) return ctx.fail(.not_found, proto.errors.msg.workspace_not_found, .{ .selector = "workspace_id" });
    return c;
}

const ItemJson = struct {
    index: usize,
    title: []const u8,
    accelerator: ?[]const u8,
    group: u8,
    enabled: bool,
    checked: bool,
    separator_before: bool,
};

/// `{site, <selectors>}` → `{site, items:[{index, title, accelerator,
/// group, enabled, checked, separator_before}]}` in display order, built by
/// the same MenuBuilder as the popup.
pub fn menuList(ctx: *Ctx) Error!void {
    const site = try siteParam(ctx);
    var mctx = try menuContext(ctx, site);
    var b = menus.buildForInspection(ctx.app.core_app.alloc, site, &mctx) catch return oom(ctx);
    defer b.deinit();
    const items = ctx.arena.alloc(ItemJson, b.entries.items.len) catch return oom(ctx);
    for (b.entries.items, items, 0..) |e, *o, i| {
        const label = menus.labelOf(e.title);
        o.* = .{
            .index = i,
            .title = ctx.arena.dupe(u8, label) catch return oom(ctx),
            .accelerator = if (label.len < e.title.len) (ctx.arena.dupe(u8, e.title[label.len + 1 ..]) catch return oom(ctx)) else null,
            .group = e.group,
            .enabled = e.enabled,
            .checked = e.checked,
            .separator_before = b.separatorBefore(i),
        };
    }
    ctx.ok(.{ .site = @tagName(site), .items = items });
}

/// `{site, title | index, <selectors>}` → runs that row as if it had been
/// chosen in the popup (no popup, no modal loop). `title` matches exactly,
/// else as the unique case-insensitive prefix ("Rename").
pub fn menuInvoke(ctx: *Ctx) Error!void {
    const site = try siteParam(ctx);
    var mctx = try menuContext(ctx, site);
    var b = menus.buildForInspection(ctx.app.core_app.alloc, site, &mctx) catch return oom(ctx);
    defer b.deinit();
    const index: usize = if (try ctx.param(usize, "index")) |i| i else blk: {
        const title = (try ctx.param([]const u8, "title")) orelse return ctx.fail(.invalid_params, "Missing title or index", .{ .param = "title" });
        break :blk menus.findEntry(&b, title) orelse return ctx.fail(.not_found, "Menu item not found", .{ .param = "title" });
    };
    if (index >= b.entries.items.len) return ctx.fail(.not_found, "Menu item not found", .{ .param = "index" });
    const title = ctx.arena.dupe(u8, menus.labelOf(b.entries.items[index].title)) catch return oom(ctx);
    if (!menus.invokeEntry(&b, index)) return ctx.fail(.invalid_state, "Menu item is disabled or its target is gone", .{ .index = index });
    ctx.ok(.{ .site = @tagName(site), .index = index, .title = title });
}

// ---------------------------------------------------------------------------
// timers, sinks
// ---------------------------------------------------------------------------

pub fn timers(ctx: *Ctx) Error!void {
    const Entry = struct { id: usize, repeat: bool };
    const entries = ctx.app.timers.registry.entries.items;
    const out = ctx.arena.alloc(Entry, entries.len) catch return oom(ctx);
    for (entries, out) |e, *o| o.* = .{ .id = e.id, .repeat = e.repeat };
    ctx.ok(.{ .timers = out });
}

/// The JSON lines of a test sink file (worker lane: file I/O stays off the
/// UI thread). A missing file is empty; a torn last line is skipped.
fn sinkLines(arena: Allocator, path: ?[]const u8) Allocator.Error![]const std.json.Value {
    const p = path orelse return &.{};
    const bytes = std.fs.cwd().readFileAlloc(arena, p, 16 * 1024 * 1024) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    var out: std.ArrayList(std.json.Value) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
        try out.append(arena, v);
    }
    return out.items;
}

/// `{opens:[{kind, verb, target, timestamp_ms}]}` from WMUX_TEST_EXTERNAL_SINK.
pub fn externalOpenList(ctx: *Ctx) Error!void {
    const lines = sinkLines(ctx.arena, ctx.app.runtime_env.test_external_sink) catch return oom(ctx);
    ctx.ok(.{ .opens = lines });
}

/// `{sounds:[{kind, source, type, sound, timestamp_ms}]}` from WMUX_TEST_SOUND_SINK.
pub fn soundsList(ctx: *Ctx) Error!void {
    const lines = sinkLines(ctx.arena, ctx.app.runtime_env.test_sound_sink) catch return oom(ctx);
    ctx.ok(.{ .sounds = lines });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: debug: key chords parse modifiers, named keys and characters" {
    const enter = parseChord("enter").?;
    try testing.expectEqual(@as(u16, 0x0D), enter.vk);
    try testing.expectEqual(@as(?u16, '\r'), enter.char);
    const t = parseChord("Ctrl+Shift+T").?;
    try testing.expect(t.ctrl and t.shift and !t.alt);
    try testing.expectEqual(@as(u16, 'T'), t.vk);
    try testing.expectEqual(@as(?u16, 20), t.char); // Ctrl+T = 0x14
    const a = parseChord("a").?;
    try testing.expectEqual(@as(u16, 'A'), a.vk);
    try testing.expectEqual(@as(?u16, 'a'), a.char);
    try testing.expectEqual(@as(?u16, 'A'), parseChord("shift+a").?.char);
    try testing.expectEqual(@as(?u16, null), parseChord("alt+x").?.char);
    const f5 = parseChord("f5").?;
    try testing.expectEqual(@as(u16, 0x74), f5.vk);
    try testing.expect(parseChord("left").?.extended);
    try testing.expect(parseChord("") == null);
    try testing.expect(parseChord("ctrl+") == null);
    try testing.expect(parseChord("a+ctrl") == null);
    try testing.expect(parseChord("f13") == null);
    try testing.expect(parseChord("hyper+a") == null);
}
