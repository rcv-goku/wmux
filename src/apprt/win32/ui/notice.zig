//! Non-modal notices (ARCHITECTURE.md ADR-5.3, ADR-8.9): the bar a window
//! shows for a settings parse error with its first three errors and
//! "Open", the one-time "keymap changed" notice with a link to the
//! presets, the crash-recovery notice of session restore. A notice never
//! takes focus (G4); `wmux.debug.notices` lists them (W1-4b).
//!
//! The store keeps one entry per id (a later `show` with the same id
//! replaces it and moves it to the end). Every top-level window shows the
//! notices in a child panel at the top-right of its client area: one row
//! per notice with its title, body lines, the action button and a close
//! button. The panel is a WS_CHILD that refuses activation
//! (WM_MOUSEACTIVATE -> MA_NOACTIVATE), so it is cloaked with a hidden
//! test window and never becomes foreground. While notices exist a 500 ms
//! app timer keeps the panels anchored when a window is resized (the
//! panel cannot hook the window's own WM_SIZE). Every `show` is logged
//! (`notice <id>: <title> <body>`), which the e2e suites read from
//! STATE\logs\wmux.log.

const std = @import("std");
const builtin = @import("builtin");

const App = @import("../App.zig");
const dialogs = @import("../app/dialogs.zig");
const input_actions = @import("../input/actions.zig");
const timers = @import("../app/timers.zig");
const w32 = @import("../platform/win32.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.notice);

pub const Level = enum { info, warning, @"error" };

/// What the notice's button does.
pub const Action = struct {
    /// Button text (English, through ui/strings.zig `tr` in W7).
    label: []const u8,
    target: Target,

    pub const Target = union(enum) {
        /// Run a catalog action (`input/actions.zig`), e.g. a preset.
        action: []const u8,
        /// Open a URL or a file through `app/dialogs.openExternal`.
        open: []const u8,
    };
};

pub const Notice = struct {
    /// Stable id (`settings.parse_error`, `shortcuts.keymap_changed`,
    /// `session.crashed`): a later notice with the same id replaces it.
    id: []const u8,
    level: Level = .info,
    title: []const u8,
    body: []const u8 = "",
    action: ?Action = null,
};

// ---------------------------------------------------------------------------
// Store (pure; unit-tested)

/// The notices shown now, oldest first, each with its own copy of the
/// strings.
pub const Store = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// `list` view, rebuilt on change.
    views: std.ArrayList(Notice) = .empty,

    const Entry = struct {
        arena: std.heap.ArenaAllocator,
        notice: Notice,
    };

    pub fn deinit(self: *Store, gpa: Allocator) void {
        for (self.entries.items) |*e| e.arena.deinit();
        self.entries.deinit(gpa);
        self.views.deinit(gpa);
        self.* = .{};
    }

    /// Adds `n` (copied), replacing an entry with the same id.
    pub fn show(self: *Store, gpa: Allocator, n: Notice) Allocator.Error!void {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var copy: Notice = .{
            .id = try a.dupe(u8, n.id),
            .level = n.level,
            .title = try a.dupe(u8, n.title),
            .body = try a.dupe(u8, n.body),
        };
        if (n.action) |act| {
            copy.action = .{
                .label = try a.dupe(u8, act.label),
                .target = switch (act.target) {
                    .action => |s| .{ .action = try a.dupe(u8, s) },
                    .open => |s| .{ .open = try a.dupe(u8, s) },
                },
            };
        }
        try self.entries.ensureUnusedCapacity(gpa, 1);
        try self.views.ensureTotalCapacity(gpa, self.entries.items.len + 1);
        _ = self.remove(n.id);
        self.entries.appendAssumeCapacity(.{ .arena = arena, .notice = copy });
        self.rebuild();
    }

    /// Removes the entry `id`; true when there was one.
    pub fn dismiss(self: *Store, id: []const u8) bool {
        const removed = self.remove(id);
        if (removed) self.rebuild();
        return removed;
    }

    fn remove(self: *Store, id: []const u8) bool {
        for (self.entries.items, 0..) |*e, i| {
            if (!std.mem.eql(u8, e.notice.id, id)) continue;
            var gone = self.entries.orderedRemove(i);
            gone.arena.deinit();
            return true;
        }
        return false;
    }

    fn rebuild(self: *Store) void {
        self.views.clearRetainingCapacity();
        // Capacity was reserved by `show`; `dismiss` only shrinks.
        for (self.entries.items) |e| self.views.appendAssumeCapacity(e.notice);
    }

    pub fn list(self: *const Store) []const Notice {
        return self.views.items;
    }
};

// ---------------------------------------------------------------------------
// App state (UI thread only)

const State = struct {
    store: Store = .{},
    gpa: ?Allocator = null,
    app: ?*App = null,
    panels: std.ArrayList(Panel) = .empty,
    class_registered: bool = false,
    timer: timers.TimerId = 0,
};

const Panel = struct { parent: w32.HWND, hwnd: w32.HWND };

var state: State = .{};

/// Show `notice` in every window (UI thread); the strings are copied.
pub fn show(app: *App, notice: Notice) void {
    switch (notice.level) {
        .info => log.info("notice {s}: {s} {s}", .{ notice.id, notice.title, notice.body }),
        .warning => log.warn("notice {s}: {s} {s}", .{ notice.id, notice.title, notice.body }),
        .@"error" => log.err("notice {s}: {s} {s}", .{ notice.id, notice.title, notice.body }),
    }
    const gpa = app.core_app.alloc;
    state.gpa = gpa;
    state.app = app;
    state.store.show(gpa, notice) catch {
        log.warn("notice {s}: out of memory", .{notice.id});
        return;
    };
    refresh(app);
}

/// Remove the notice `id` if it is shown.
pub fn dismiss(app: *App, id: []const u8) void {
    if (!state.store.dismiss(id)) return;
    log.info("notice {s}: dismissed", .{id});
    refresh(app);
}

/// The notices shown now, oldest first, borrowed until the next `show` or
/// `dismiss` (UI thread).
pub fn list(app: *const App) []const Notice {
    _ = app;
    return state.store.list();
}

/// Free the store and the panels (App.terminate through settings.deinit).
pub fn deinit(app: *App) void {
    if (state.timer != 0) app.timers.stop(state.timer);
    for (state.panels.items) |p| {
        if (IsWindow(p.hwnd) != 0) _ = w32.DestroyWindow(p.hwnd);
    }
    if (state.gpa) |gpa| {
        state.panels.deinit(gpa);
        state.store.deinit(gpa);
    }
    state = .{};
}

/// Create, update or remove the panels of every window to match the
/// store (UI thread). Called after every change and once the first
/// window exists (notices raised during startup).
pub fn refresh(app: *App) void {
    if (comptime builtin.os.tag != .windows) return;
    const gpa = app.core_app.alloc;
    state.gpa = gpa;
    state.app = app;
    // Drop panels whose window is gone.
    var i: usize = 0;
    while (i < state.panels.items.len) {
        const p = state.panels.items[i];
        if (IsWindow(p.parent) == 0 or IsWindow(p.hwnd) == 0) {
            _ = state.panels.swapRemove(i);
        } else i += 1;
    }
    if (state.store.list().len == 0) {
        for (state.panels.items) |p| _ = w32.DestroyWindow(p.hwnd);
        state.panels.clearRetainingCapacity();
        if (state.timer != 0) app.timers.stop(state.timer);
        state.timer = 0;
        return;
    }
    if (!registerClass(app)) return;
    for (app.windows.items) |win| {
        const parent = win.hwnd orelse continue;
        const panel = for (state.panels.items) |p| {
            if (p.parent == parent) break p.hwnd;
        } else create: {
            const h = w32.CreateWindowExW(
                0,
                class_name,
                std.unicode.utf8ToUtf16LeStringLiteral(""),
                w32.WS_CHILD | w32.WS_CLIPSIBLINGS,
                0,
                0,
                1,
                1,
                parent,
                null,
                app.hinstance,
                null,
            ) orelse continue;
            state.panels.append(gpa, .{ .parent = parent, .hwnd = h }) catch {
                _ = w32.DestroyWindow(h);
                continue;
            };
            break :create h;
        };
        place(panel, parent);
        _ = w32.InvalidateRect(panel, null, 1);
    }
    if (state.timer == 0) state.timer = app.timers.start(500, .{ .repeat = true }, 0, onTimer);
}

fn onTimer(app: *App, ctx: usize) void {
    _ = ctx;
    for (state.panels.items) |p| {
        if (IsWindow(p.parent) != 0 and IsWindow(p.hwnd) != 0) place(p.hwnd, p.parent);
    }
    // New windows get their panel too.
    if (countWindows(app) != state.panels.items.len) refresh(app);
}

fn countWindows(app: *App) usize {
    var n: usize = 0;
    for (app.windows.items) |win| {
        if (win.hwnd != null) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Panel window

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("WmuxNoticePanel");

const WM_MOUSEACTIVATE: u32 = 0x0021;
const MA_NOACTIVATE: isize = 3;

extern "user32" fn IsWindow(hWnd: ?w32.HWND) callconv(.winapi) i32;

fn registerClass(app: *App) bool {
    if (state.class_registered) return true;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &panelWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = app.hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) {
        log.warn("notice panel class registration failed", .{});
        return false;
    }
    state.class_registered = true;
    return true;
}

/// Layout metrics at a DPI scale.
const Metrics = struct {
    scale: f32,

    fn px(self: Metrics, v: f32) i32 {
        return @intFromFloat(@round(v * self.scale));
    }
    fn width(self: Metrics) i32 {
        return self.px(440);
    }
    fn line(self: Metrics) i32 {
        return self.px(18);
    }
    fn pad(self: Metrics) i32 {
        return self.px(8);
    }
    fn button(self: Metrics) i32 {
        return self.px(56);
    }
};

fn metricsFor(hwnd: w32.HWND) Metrics {
    const dpi = w32.GetDpiForWindow(hwnd);
    return .{ .scale = if (dpi == 0) 1.0 else @as(f32, @floatFromInt(dpi)) / 96.0 };
}

fn bodyLines(body: []const u8) i32 {
    if (body.len == 0) return 0;
    return @intCast(@min(std.mem.count(u8, body, "\n") + 1, 8));
}

fn rowHeight(m: Metrics, n: *const Notice) i32 {
    return m.pad() * 2 + m.line() * (1 + bodyLines(n.body));
}

fn panelHeight(m: Metrics) i32 {
    var h: i32 = 0;
    for (state.store.list()) |*n| h += rowHeight(m, n);
    return h;
}

/// Anchors the panel at the top-right of `parent`'s client area, below
/// the tab strip, and keeps it above its siblings without activating.
fn place(panel: w32.HWND, parent: w32.HWND) void {
    const m = metricsFor(parent);
    var rc: w32.RECT = undefined;
    if (w32.GetClientRect(parent, &rc) == 0) return;
    const client_w = rc.right - rc.left;
    const w = @min(m.width(), @max(m.px(160), client_w - 2 * m.pad()));
    const h = panelHeight(m);
    const x = @max(0, client_w - w - m.pad());
    const y = m.px(40);
    _ = w32.SetWindowPos(panel, null, x, y, w, h, w32.SWP_NOACTIVATE | w32.SWP_SHOWWINDOW);
}

/// The notice and button under client point (x, y), if any.
const Hit = struct { index: usize, what: enum { row, action, close } };

fn hitTest(m: Metrics, panel_w: i32, x: i32, y: i32) ?Hit {
    var top: i32 = 0;
    for (state.store.list(), 0..) |*n, i| {
        const h = rowHeight(m, n);
        if (y >= top and y < top + h) {
            const title_top = top + m.pad();
            if (y >= title_top and y < title_top + m.line()) {
                const close_left = panel_w - m.pad() - m.line();
                if (x >= close_left) return .{ .index = i, .what = .close };
                if (n.action != null and x >= close_left - m.button() - m.pad()) return .{ .index = i, .what = .action };
            }
            return .{ .index = i, .what = .row };
        }
        top += h;
    }
    return null;
}

fn levelColor(level: Level) u32 {
    return switch (level) {
        .info => w32.RGB(0x3B, 0x82, 0xF6),
        .warning => w32.RGB(0xF5, 0x9E, 0x0B),
        .@"error" => w32.RGB(0xEF, 0x44, 0x44),
    };
}

fn drawText(hdc: w32.HDC, text: []const u8, rc: *w32.RECT, flags: u32) void {
    var buf: [512]u16 = undefined;
    // Cap first (G6): utf8ToUtf16Le does not bounds-check in ReleaseFast.
    var end = @min(text.len, buf.len / 2);
    while (end > 0 and end < text.len and (text[end] & 0xC0) == 0x80) end -= 1;
    const n = std.unicode.utf8ToUtf16Le(&buf, text[0..end]) catch return;
    if (n == 0) return;
    _ = w32.DrawTextW(hdc, &buf, @intCast(n), rc, flags | w32.DT_NOPREFIX);
}

fn paint(hwnd: w32.HWND) void {
    var ps: w32.PAINTSTRUCT = undefined;
    const hdc = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);
    const m = metricsFor(hwnd);
    var rc: w32.RECT = undefined;
    _ = w32.GetClientRect(hwnd, &rc);
    const bg = w32.CreateSolidBrush(w32.RGB(0x26, 0x26, 0x2B)) orelse return;
    defer _ = w32.DeleteObject(@ptrCast(bg));
    _ = w32.FillRect(hdc, &rc, bg);
    const font = w32.CreateFontW(-m.px(12), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"));
    const bold = w32.CreateFontW(-m.px(12), 0, 0, 0, 700, 0, 0, 0, 1, 0, 0, 5, 0, std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"));
    defer if (font) |f| {
        _ = w32.DeleteObject(f);
    };
    defer if (bold) |f| {
        _ = w32.DeleteObject(f);
    };
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    var top: i32 = 0;
    for (state.store.list()) |*n| {
        const h = rowHeight(m, n);
        if (w32.CreateSolidBrush(levelColor(n.level))) |stripe| {
            defer _ = w32.DeleteObject(@ptrCast(stripe));
            _ = w32.FillRect(hdc, &.{ .left = 0, .top = top, .right = m.px(4), .bottom = top + h }, stripe);
        }
        const left = m.px(4) + m.pad();
        const close_left = rc.right - m.pad() - m.line();
        // Title row: title, action button, close button.
        _ = w32.SelectObject(hdc, bold);
        _ = w32.SetTextColor(hdc, w32.RGB(0xF2, 0xF2, 0xF2));
        var title_rc: w32.RECT = .{ .left = left, .top = top + m.pad(), .right = close_left - m.button() - m.pad(), .bottom = top + m.pad() + m.line() };
        drawText(hdc, n.title, &title_rc, w32.DT_LEFT | w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
        _ = w32.SelectObject(hdc, font);
        if (n.action) |act| {
            _ = w32.SetTextColor(hdc, w32.RGB(0x93, 0xC5, 0xFD));
            var b: w32.RECT = .{ .left = close_left - m.button() - m.pad(), .top = top + m.pad(), .right = close_left - m.pad(), .bottom = top + m.pad() + m.line() };
            drawText(hdc, act.label, &b, w32.DT_RIGHT | w32.DT_SINGLELINE | w32.DT_VCENTER);
        }
        _ = w32.SetTextColor(hdc, w32.RGB(0xB0, 0xB0, 0xB8));
        var x_rc: w32.RECT = .{ .left = close_left, .top = top + m.pad(), .right = rc.right - m.pad(), .bottom = top + m.pad() + m.line() };
        drawText(hdc, "x", &x_rc, w32.DT_CENTER | w32.DT_SINGLELINE | w32.DT_VCENTER);
        // Body lines.
        _ = w32.SetTextColor(hdc, w32.RGB(0xD4, 0xD4, 0xD8));
        var it = std.mem.splitScalar(u8, n.body, '\n');
        var line_top = top + m.pad() + m.line();
        var count: i32 = 0;
        while (it.next()) |l| : (count += 1) {
            if (count >= bodyLines(n.body)) break;
            var lr: w32.RECT = .{ .left = left, .top = line_top, .right = rc.right - m.pad(), .bottom = line_top + m.line() };
            drawText(hdc, std.mem.trimRight(u8, l, "\r"), &lr, w32.DT_LEFT | w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
            line_top += m.line();
        }
        top += h;
    }
}

fn click(hwnd: w32.HWND, lparam: isize) void {
    const app = state.app orelse return;
    const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
    const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
    var rc: w32.RECT = undefined;
    _ = w32.GetClientRect(hwnd, &rc);
    const hit = hitTest(metricsFor(hwnd), rc.right, x, y) orelse return;
    const items = state.store.list();
    if (hit.index >= items.len) return;
    const n = items[hit.index];
    // Copy what the handlers need: dismiss frees the entry.
    var id_buf: [128]u8 = undefined;
    const id_len = @min(n.id.len, id_buf.len);
    @memcpy(id_buf[0..id_len], n.id[0..id_len]);
    switch (hit.what) {
        .row => {},
        .close => dismiss(app, id_buf[0..id_len]),
        .action => if (n.action) |act| switch (act.target) {
            .open => |target| _ = dialogs.openExternal(app, "notice", "open", target),
            .action => |action_id| _ = input_actions.invoke(app, .{ .app = {} }, action_id),
        },
    }
}

fn panelWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    switch (msg) {
        // Never take focus or activate the window (G4).
        WM_MOUSEACTIVATE => return MA_NOACTIVATE,
        w32.WM_ERASEBKGND => return 1,
        w32.WM_PAINT => {
            paint(hwnd);
            return 0;
        },
        w32.WM_LBUTTONUP => {
            click(hwnd, lparam);
            return 0;
        },
        else => {},
    }
    return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

// ---------------------------------------------------------------------------
// Tests

test "unit: ui: notice store replaces by id and lists oldest first" {
    const gpa = std.testing.allocator;
    var s: Store = .{};
    defer s.deinit(gpa);
    var body = [_]u8{ 'a', 'b' };
    try s.show(gpa, .{ .id = "settings.parse_error", .level = .@"error", .title = "t1", .body = &body, .action = .{ .label = "Open", .target = .{ .open = "C:\\cfg\\wmux.json" } } });
    body[0] = 'X'; // the store copied the strings
    try s.show(gpa, .{ .id = "session.crashed", .title = "t2" });
    try std.testing.expectEqual(@as(usize, 2), s.list().len);
    try std.testing.expectEqualStrings("ab", s.list()[0].body);
    try std.testing.expectEqualStrings("C:\\cfg\\wmux.json", s.list()[0].action.?.target.open);
    // Same id replaces and moves to the end.
    try s.show(gpa, .{ .id = "settings.parse_error", .title = "t3" });
    try std.testing.expectEqual(@as(usize, 2), s.list().len);
    try std.testing.expectEqualStrings("session.crashed", s.list()[0].id);
    try std.testing.expectEqualStrings("t3", s.list()[1].title);
    try std.testing.expect(s.list()[1].action == null);
    try std.testing.expect(s.dismiss("session.crashed"));
    try std.testing.expect(!s.dismiss("session.crashed"));
    try std.testing.expectEqual(@as(usize, 1), s.list().len);
}

test "unit: ui: notice rows size from their body lines" {
    const m: Metrics = .{ .scale = 1.0 };
    const one: Notice = .{ .id = "a", .title = "t" };
    const three: Notice = .{ .id = "b", .title = "t", .body = "x\ny\nz" };
    try std.testing.expectEqual(@as(i32, 16 + 18), rowHeight(m, &one));
    try std.testing.expectEqual(@as(i32, 16 + 18 * 4), rowHeight(m, &three));
    try std.testing.expectEqual(@as(i32, 0), bodyLines(""));
    try std.testing.expectEqual(@as(i32, 8), bodyLines("1\n2\n3\n4\n5\n6\n7\n8\n9\n10"));
}
