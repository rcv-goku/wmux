//! Window placement in the session (ARCHITECTURE.md ADR-9.2, 9.4): capture
//! a window's restored rect, maximized and fullscreen state, monitor and
//! DPI for the v3 snapshot, and apply a saved placement with
//! `SetWindowPlacement`, clamped to the work area of the saved monitor (or
//! the nearest one). rcNormalPosition is in workspace coordinates; the
//! clamp happens in screen coordinates (ui/placement_state.zig), which
//! fixes the old workarea/screen drift. The old `window-state` file seeds
//! window 0's placement when a v2 session is migrated.
//!
//! WMUX_TEST_HIDDEN windows keep their fixed hidden geometry: `apply` is a
//! no-op there (ADR-12.3).

const std = @import("std");

const App = @import("../../App.zig");
const Window = @import("../../ui/Window.zig");
const WindowState = @import("../../ui/placement_state.zig");
const app_paths = @import("../../app/paths.zig");
const schema = @import("logic/schema_v3.zig");
const w32 = @import("../../platform/win32.zig");

const Rect = WindowState.Rect;

const MONITORINFOEXW = extern struct {
    cbSize: u32,
    rcMonitor: w32.RECT,
    rcWork: w32.RECT,
    dwFlags: u32,
    szDevice: [32]u16,
};

const MonitorEnumProc = *const fn (w32.HMONITOR, ?*anyopaque, ?*w32.RECT, isize) callconv(.winapi) i32;
extern "user32" fn EnumDisplayMonitors(hdc: ?*anyopaque, clip: ?*const w32.RECT, proc: MonitorEnumProc, data: isize) callconv(.winapi) i32;
extern "user32" fn MonitorFromRect(rect: *const w32.RECT, flags: u32) callconv(.winapi) ?w32.HMONITOR;

fn monitorInfo(mon: w32.HMONITOR) ?MONITORINFOEXW {
    var info: MONITORINFOEXW = undefined;
    info.cbSize = @sizeOf(MONITORINFOEXW);
    if (w32.GetMonitorInfoW(mon, @ptrCast(&info)) == 0) return null;
    return info;
}

fn rectOf(r: w32.RECT) Rect {
    return .{ .x = r.left, .y = r.top, .width = r.right - r.left, .height = r.bottom - r.top };
}

/// The primary monitor's work-area origin (the workspace-coordinate
/// offset of GetWindowPlacement).
fn primaryWorkOrigin() struct { x: i32, y: i32 } {
    const mon = w32.MonitorFromPoint(.{ .x = 0, .y = 0 }, w32.MONITOR_DEFAULTTOPRIMARY) orelse return .{ .x = 0, .y = 0 };
    const info = monitorInfo(mon) orelse return .{ .x = 0, .y = 0 };
    return .{ .x = info.rcWork.left, .y = info.rcWork.top };
}

/// The placement of `window` for the snapshot (into `arena`), or null
/// when it cannot be read.
pub fn capture(arena: std.mem.Allocator, window: *const Window) ?schema.Placement {
    const hwnd = window.hwnd orelse return null;
    var wp: w32.WINDOWPLACEMENT = undefined;
    wp.length = @sizeOf(w32.WINDOWPLACEMENT);
    if (w32.GetWindowPlacement(hwnd, &wp) == 0) return null;
    // A fullscreen window's normal rect is the monitor; keep the rect it
    // returns to (Window.saved_rect, screen coordinates).
    var r = rectOf(wp.rcNormalPosition);
    if (window.is_fullscreen and window.saved_rect.right > window.saved_rect.left) {
        const o = primaryWorkOrigin();
        r = WindowState.screenToWorkspace(rectOf(window.saved_rect), o.x, o.y);
    }
    var p: schema.Placement = .{
        .x = r.x,
        .y = r.y,
        .w = r.width,
        .h = r.height,
        .maximized = wp.showCmd == @as(u32, @intCast(w32.SW_SHOWMAXIMIZED)),
        .fullscreen = window.is_fullscreen,
    };
    const dpi = w32.GetDpiForWindow(hwnd);
    if (dpi != 0) p.dpi = dpi;
    if (monitorInfo(w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST))) |info| {
        const len = std.mem.indexOfScalar(u16, &info.szDevice, 0) orelse info.szDevice.len;
        p.monitor = std.unicode.wtf16LeToWtf8Alloc(arena, info.szDevice[0..len]) catch null;
    }
    return p;
}

const FindMonitor = struct {
    name: []const u16,
    found: ?w32.HMONITOR = null,

    fn proc(mon: w32.HMONITOR, _: ?*anyopaque, _: ?*w32.RECT, data: isize) callconv(.winapi) i32 {
        const self: *FindMonitor = @ptrFromInt(@as(usize, @bitCast(data)));
        const info = monitorInfo(mon) orelse return 1;
        const len = std.mem.indexOfScalar(u16, &info.szDevice, 0) orelse info.szDevice.len;
        if (std.mem.eql(u16, info.szDevice[0..len], self.name)) {
            self.found = mon;
            return 0;
        }
        return 1;
    }
};

/// The monitor named `name` (`\\.\DISPLAY1`), if it is attached.
fn monitorByName(name: []const u8) ?w32.HMONITOR {
    var buf: [64]u16 = undefined;
    if (name.len == 0 or name.len > buf.len) return null;
    const n = std.unicode.wtf8ToWtf16Le(&buf, name) catch return null;
    var finder: FindMonitor = .{ .name = buf[0..n] };
    _ = EnumDisplayMonitors(null, null, FindMonitor.proc, @bitCast(@intFromPtr(&finder)));
    return finder.found;
}

/// The saved rect in screen coordinates, clamped to the work area of its
/// monitor (by name, else the one nearest to the rect).
pub fn clampedScreenRect(p: schema.Placement) Rect {
    const o = primaryWorkOrigin();
    const screen = WindowState.workspaceToScreen(.{ .x = p.x, .y = p.y, .width = p.w, .height = p.h }, o.x, o.y);
    const mon: ?w32.HMONITOR = (if (p.monitor) |name| monitorByName(name) else null) orelse blk: {
        const r: w32.RECT = .{ .left = screen.x, .top = screen.y, .right = screen.right(), .bottom = screen.bottom() };
        break :blk MonitorFromRect(&r, w32.MONITOR_DEFAULTTONEAREST);
    };
    const info = (if (mon) |m| monitorInfo(m) else null) orelse return screen;
    return WindowState.clampToWorkArea(screen, rectOf(info.rcWork));
}

/// Apply `p` to `window` with SetWindowPlacement: the clamped rect, shown
/// with `show_cmd` (SW_SHOWMAXIMIZED when saved maximized). No-op in
/// WMUX_TEST_HIDDEN and for a degenerate placement.
pub fn apply(app: *const App, window: *Window, p: schema.Placement, show_cmd: i32) void {
    if (app.runtime_env.test_hidden) return;
    const hwnd = window.hwnd orelse return;
    if (p.w < WindowState.State.min_dim or p.h < WindowState.State.min_dim) return;
    const r = clampedScreenRect(p);
    const o = primaryWorkOrigin();
    const ws = WindowState.screenToWorkspace(r, o.x, o.y);
    var wp: w32.WINDOWPLACEMENT = undefined;
    wp.length = @sizeOf(w32.WINDOWPLACEMENT);
    if (w32.GetWindowPlacement(hwnd, &wp) == 0) return;
    wp.flags = 0;
    wp.showCmd = @intCast(if (p.maximized and show_cmd != w32.SW_HIDE) w32.SW_SHOWMAXIMIZED else show_cmd);
    wp.rcNormalPosition = .{ .left = ws.x, .top = ws.y, .right = ws.right(), .bottom = ws.bottom() };
    _ = w32.SetWindowPlacement(hwnd, &wp);
}

/// The CreateWindowExW geometry for a window about to be restored with
/// `p` (screen coordinates, clamped), so the window is created where it
/// ends up (ui/placement.zig restorePlacement).
pub fn initialState(p: schema.Placement) ?WindowState.State {
    if (p.w < WindowState.State.min_dim or p.h < WindowState.State.min_dim) return null;
    const r = clampedScreenRect(p);
    return .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height, .maximized = p.maximized };
}

/// Window 0's placement from the legacy `window-state` file (v2 migration
/// seed, ADR-9.8), or null.
pub fn legacyPlacement(app: *const App) ?schema.Placement {
    const gpa = app.core_app.alloc;
    const path = app_paths.windowStatePath(gpa, &app.runtime_env) catch return null;
    defer gpa.free(path);
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    var buf: [512]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const s = WindowState.State.parse(buf[0..n]) orelse return null;
    return .{ .x = s.x, .y = s.y, .w = s.width, .h = s.height, .maximized = s.maximized };
}
