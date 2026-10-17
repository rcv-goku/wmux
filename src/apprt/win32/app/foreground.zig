//! The G4 choke point (ARCHITECTURE.md ADR-1.6, ADR-3.11): the ONLY code
//! that calls SetForegroundWindow, SetActiveWindow, BringWindowToTop,
//! FlashWindowEx or AllowSetForegroundWindow. Socket, CLI and automation
//! paths never activate a window; programmatic raises only move the OS
//! foreground when it already belongs to us.
//!
//! With WMUX_TEST_HIDDEN nothing here ever activates, raises or flashes a
//! window, so a test instance can never take the OS foreground. The
//! top-level window helpers at the bottom implement ADR-12.3 (amended
//! 2026-10-15 per spike S2, docs/arch/spikes/S2-hidden-instances.md):
//! every top-level window is WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE (out of
//! the taskbar and Alt-Tab), created without WS_VISIBLE with a 1600x1000
//! client area clamped to the primary monitor's work area at the
//! work-area origin, cloaked with DWMWA_CLOAK before its first show (so
//! GL presents still reach DWM and PrintWindow captures them, while the
//! window stays invisible and click-through), and shown only with
//! SW_SHOWNOACTIVATE. Only when cloaking fails is it moved to
//! (-32000, -32000) instead. A thread-local WH_CBT hook on the UI thread
//! refuses every activation, applies the S2 focus policy "gate" (SetFocus
//! only when the target's root window is already active, W0-A4) and moves
//! unowned top-level windows created by user32 itself (MessageBox, menus,
//! tooltips) off-screen.

const std = @import("std");

const App = @import("../App.zig");
const w32 = @import("../platform/win32.zig");

const log = std.log.scoped(.app_foreground);

/// WMUX_TEST_HIDDEN top-level geometry (ARCHITECTURE.md ADR-12.3): the
/// client size before clamping to the work area, and the off-screen
/// fallback position used when a window cannot be cloaked.
pub const hidden_offscreen: i32 = -32000;
pub const hidden_client_width: i32 = 1600;
pub const hidden_client_height: i32 = 1000;

/// Whether the current foreground window belongs to THIS process. The
/// guard for every OS-foreground raise (forceForegroundWindow and the
/// present_terminal raise): we only ever steal/move OS foreground when we
/// already own it — switching between our own windows is fine, but we
/// must NEVER yank the user out of another app (VS Code, Slack, the app
/// an agent orchestrator is driving). Returns false when there is no
/// foreground window (treat as "not ours" — don't grab it).
pub fn foregroundIsOurs() bool {
    const fg = w32.GetForegroundWindow() orelse return false;
    var fg_pid: u32 = 0;
    _ = w32.GetWindowThreadProcessId(fg, &fg_pid);
    return fg_pid == w32.GetCurrentProcessId();
}

/// Raise a window of THIS process to the foreground, but ONLY when the
/// current foreground window already belongs to us. When another
/// application is foreground this is a no-op: the caller may still have
/// restored/shown the window (it will flash its taskbar button) but we
/// never steal OS foreground from another app. See foregroundIsOurs.
/// This is the gate for every PROGRAMMATIC/notification raise
/// (present_terminal, jumpToSurface, +notify next, --focus). The
/// interactive QuickTerminal summon uses the ungated raiseForegroundWindow
/// (user-pressed hotkey == explicit intent to come forward over any app).
/// Never activates in WMUX_TEST_HIDDEN.
pub fn forceForegroundWindow(app: *const App, hwnd: w32.HWND) void {
    if (app.runtime_env.test_hidden) return;
    if (!foregroundIsOurs()) return;
    raiseForegroundWindow(app, hwnd);
}

/// Unconditionally raise `hwnd` to the OS foreground. Uses
/// AttachThreadInput to work around the Win32 SetForegroundWindow
/// restriction when the current foreground window belongs to another
/// thread/process. The UNGATED primitive: only the interactive
/// QuickTerminal summon (an explicit user hotkey) calls this directly;
/// every programmatic/notification path goes through forceForegroundWindow
/// so it can never yank the user out of another app. Never activates in
/// WMUX_TEST_HIDDEN.
pub fn raiseForegroundWindow(app: *const App, hwnd: w32.HWND) void {
    if (app.runtime_env.test_hidden) return;
    const fg = w32.GetForegroundWindow();
    if (fg) |fg_hwnd| {
        const fg_tid = w32.GetWindowThreadProcessId(fg_hwnd, null);
        const our_tid = w32.GetCurrentThreadId();
        if (fg_tid != our_tid) {
            _ = w32.AttachThreadInput(our_tid, fg_tid, 1);
            _ = w32.SetForegroundWindow(hwnd);
            _ = w32.AttachThreadInput(our_tid, fg_tid, 0);
        } else {
            _ = w32.SetForegroundWindow(hwnd);
        }
    } else {
        _ = w32.SetForegroundWindow(hwnd);
    }
}

/// Flash `hwnd`'s taskbar button `count` times until it comes to the
/// foreground (FLASHW_ALL | FLASHW_TIMERNOFG): the visual bell and the
/// failed-command cue. No-op in WMUX_TEST_HIDDEN.
pub fn flashWindow(app: *const App, hwnd: w32.HWND, count: u32) void {
    if (app.runtime_env.test_hidden) return;
    var fwi: w32.FLASHWINFO = .{
        .cbSize = @sizeOf(w32.FLASHWINFO),
        .hwnd = hwnd,
        .dwFlags = w32.FLASHW_ALL | w32.FLASHW_TIMERNOFG,
        .uCount = count,
        .dwTimeout = 0,
    };
    _ = w32.FlashWindowEx(&fwi);
}

// ---------------------------------------------------------------------------
// Top-level windows under WMUX_TEST_HIDDEN
// ---------------------------------------------------------------------------

/// CreateWindowExW parameters of a top-level window.
pub const TopLevelCreate = struct {
    ex_style: u32,
    style: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

/// Outer window rect of a hidden top-level window.
pub const Geometry = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

/// The hidden-window rect for work area `work` and frame insets `frame`
/// (AdjustWindowRectEx of an empty client rect for the final styles):
/// a hidden_client_width x hidden_client_height client area, shrunk to
/// what fits in the work area (at least 1x1), with the outer rect placed
/// at the work-area origin so the whole window lies on the monitor (GL
/// presents are clipped to window ∩ monitors). Pure (unit-tested).
pub fn hiddenGeometry(work: w32.RECT, frame: w32.RECT) Geometry {
    const frame_w = frame.right - frame.left;
    const frame_h = frame.bottom - frame.top;
    const client_w = std.math.clamp(work.right - work.left - frame_w, 1, hidden_client_width);
    const client_h = std.math.clamp(work.bottom - work.top - frame_h, 1, hidden_client_height);
    return .{
        .x = work.left,
        .y = work.top,
        .width = client_w + frame_w,
        .height = client_h + frame_h,
    };
}

/// The primary monitor's work area, or an unclamped rect at (0, 0) when
/// it cannot be queried.
fn primaryWorkArea() w32.RECT {
    const fallback: w32.RECT = .{ .left = 0, .top = 0, .right = 0x7FFF, .bottom = 0x7FFF };
    const mon = w32.MonitorFromPoint(.{ .x = 0, .y = 0 }, w32.MONITOR_DEFAULTTOPRIMARY) orelse
        return fallback;
    var mi: w32.MONITORINFO = .{
        .cbSize = @sizeOf(w32.MONITORINFO),
        .rcMonitor = undefined,
        .rcWork = undefined,
        .dwFlags = 0,
    };
    if (w32.GetMonitorInfoW(mon, &mi) == 0) return fallback;
    return mi.rcWork;
}

/// The parameters to create a top-level window with: `requested`
/// unchanged normally; under WMUX_TEST_HIDDEN, WS_EX_TOOLWINDOW |
/// WS_EX_NOACTIVATE added, WS_VISIBLE removed, and the hiddenGeometry rect
/// on the primary monitor (sized with AdjustWindowRectEx for the FINAL
/// styles). finishTopLevelCreate must follow the CreateWindowExW.
pub fn topLevelCreateParams(app: *const App, requested: TopLevelCreate) TopLevelCreate {
    if (!app.runtime_env.test_hidden) return requested;
    const ex_style = requested.ex_style | w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE;
    const style = requested.style & ~w32.WS_VISIBLE_STYLE;
    var frame: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.AdjustWindowRectEx(&frame, style, 0, ex_style);
    const geometry = hiddenGeometry(primaryWorkArea(), frame);
    return .{
        .ex_style = ex_style,
        .style = style,
        .x = geometry.x,
        .y = geometry.y,
        .width = geometry.width,
        .height = geometry.height,
    };
}

/// Call right after a top-level window's WndProc can see its owner
/// (GWLP_USERDATA set) and before its first show. Under WMUX_TEST_HIDDEN:
/// cloak the window (or, when cloaking fails, fall back to the off-screen
/// position), raise its max-track limits (CreateWindowExW clamped the size
/// to the default maximum track size before the WndProc could answer
/// WM_GETMINMAXINFO) and apply the fixed geometry without activating.
/// (The WH_CBT hook created it off-screen.) No-op otherwise.
pub fn finishTopLevelCreate(
    app: *const App,
    hwnd: w32.HWND,
    create: TopLevelCreate,
    max_track_w: *i32,
    max_track_h: *i32,
) void {
    if (!app.runtime_env.test_hidden) return;
    const cloaked = cloak(hwnd);
    max_track_w.* = @max(max_track_w.*, create.width);
    max_track_h.* = @max(max_track_h.*, create.height);
    _ = w32.SetWindowPos(
        hwnd,
        null,
        if (cloaked) create.x else hidden_offscreen,
        if (cloaked) create.y else hidden_offscreen,
        create.width,
        create.height,
        w32.SWP_NOZORDER | w32.SWP_NOACTIVATE,
    );
}

/// Cloak `hwnd` with DWMWA_CLOAK and verify it with DWMWA_CLOAKED.
/// Returns false (and logs) when the window is not cloaked; the caller
/// then keeps it off-screen. (Cloaking inside the WH_CBT HCBT_CREATEWND
/// callback fails with E_HANDLE, hence after CreateWindowExW.)
pub fn cloak(hwnd: w32.HWND) bool {
    const on: i32 = 1;
    const hr = w32.DwmSetWindowAttribute(hwnd, w32.DWMWA_CLOAK, &on, @sizeOf(i32));
    if (isCloaked(hwnd)) return true;
    log.warn("DWMWA_CLOAK failed hr=0x{x:0>8}; keeping the hidden window off-screen", .{@as(u32, @bitCast(hr))});
    return false;
}

/// Whether DWM reports `hwnd` as cloaked (by us, the shell, or an
/// owner).
pub fn isCloaked(hwnd: w32.HWND) bool {
    var state: u32 = 0;
    if (w32.DwmGetWindowAttribute(hwnd, w32.DWMWA_CLOAKED, &state, @sizeOf(u32)) != 0) return false;
    return state != 0;
}

/// Under WMUX_TEST_HIDDEN, whether a top-level window must be kept
/// off-screen because it is not cloaked (cloaked windows may sit on the
/// monitor: they are invisible and click-through). Always false outside
/// WMUX_TEST_HIDDEN.
pub fn keepOffscreen(app: *const App, hwnd: ?w32.HWND) bool {
    if (!app.runtime_env.test_hidden) return false;
    const h = hwnd orelse return true;
    return !isCloaked(h);
}

/// Extended style of an owned top-level popup (the terminal search and
/// command palette bars): WS_EX_NOACTIVATE is added under
/// WMUX_TEST_HIDDEN. (Such popups follow their owner window and inherit
/// its cloak.)
pub fn popupExStyle(app: *const App, ex_style: u32) u32 {
    return if (app.runtime_env.test_hidden) ex_style | w32.WS_EX_NOACTIVATE else ex_style;
}

/// ShowWindow for top-level windows: under WMUX_TEST_HIDDEN every show
/// command except SW_HIDE becomes SW_SHOWNOACTIVATE.
pub fn showTopLevel(app: *const App, hwnd: w32.HWND, cmd: i32) void {
    const effective = if (app.runtime_env.test_hidden and cmd != w32.SW_HIDE)
        w32.SW_SHOWNOACTIVATE
    else
        cmd;
    _ = w32.ShowWindow(hwnd, effective);
}

// ---------------------------------------------------------------------------
// The WMUX_TEST_HIDDEN WH_CBT hook (UI thread)
// ---------------------------------------------------------------------------

/// The installed hook (UI thread only; the hook procedure has no context
/// argument, hence a module-level handle).
var cbt_hook: ?w32.HHOOK = null;

/// Under WMUX_TEST_HIDDEN, install the thread-local WH_CBT hook on the
/// calling (UI) thread. Call from App.init before any window exists. A
/// failure is logged; the other hidden-mode rules still apply.
pub fn installHiddenHooks(app: *const App) void {
    if (!app.runtime_env.test_hidden or cbt_hook != null) return;
    cbt_hook = w32.SetWindowsHookExW(w32.WH_CBT, &cbtProc, null, w32.GetCurrentThreadId());
    if (cbt_hook == null) log.warn("failed to install the WMUX_TEST_HIDDEN WH_CBT hook", .{});
}

/// Remove the hook installed by installHiddenHooks (App.terminate).
pub fn uninstallHiddenHooks() void {
    const hook = cbt_hook orelse return;
    _ = w32.UnhookWindowsHookEx(hook);
    cbt_hook = null;
}

/// Whether a CreateWindowExW with `style` and `parent` makes an unowned
/// top-level window (no WS_CHILD, no owner; message-only windows have the
/// HWND_MESSAGE parent and are therefore excluded). Pure (unit-tested).
pub fn isUnownedTopLevel(style: u32, parent: ?w32.HWND) bool {
    return style & w32.WS_CHILD == 0 and parent == null;
}

/// The S2 focus policy "gate": SetFocus(`target`) may run only when the
/// target's root window is already the thread's active window, because
/// SetFocus on a child of an inactive top-level window activates that
/// window first (spike S2 p6). `root` and `active` are
/// GetAncestor(target, GA_ROOT) and GetActiveWindow(). Pure
/// (unit-tested). Under WMUX_TEST_HIDDEN nothing is ever active, so every
/// SetFocus is refused; logical focus (`wmux.debug.focus_state`) stays the
/// asserted truth.
pub fn setFocusAllowed(root: ?w32.HWND, active: ?w32.HWND) bool {
    const r = root orelse return true; // focus removal (SetFocus(null))
    return active == r;
}

/// HCBT_ACTIVATE: nothing on the UI thread may activate (returning
/// nonzero refuses it). HCBT_SETFOCUS: the focus gate (setFocusAllowed),
/// so no SetFocus call anywhere in the apprt can activate a window.
/// HCBT_CREATEWND: unowned top-level windows start off-screen; our own
/// top-level windows are then placed and cloaked by finishTopLevelCreate,
/// while user32's own (MessageBox, menus, tooltips) stay off any monitor.
/// Owned windows inherit their owner's cloak.
fn cbtProc(code: i32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    if (code == w32.HCBT_ACTIVATE) return 1;
    if (code == w32.HCBT_SETFOCUS and wparam != 0) {
        const target: w32.HWND = @ptrFromInt(wparam);
        if (!setFocusAllowed(w32.GetAncestor(target, w32.GA_ROOT), w32.GetActiveWindow())) return 1;
    }
    if (code == w32.HCBT_CREATEWND) {
        const cbt: *w32.CBT_CREATEWNDW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const cs = cbt.lpcs;
        if (isUnownedTopLevel(@bitCast(cs.style), cs.hwndParent)) {
            cs.x = hidden_offscreen;
            cs.y = hidden_offscreen;
        }
    }
    return w32.CallNextHookEx(null, code, wparam, lparam);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: app: foreground hidden geometry keeps 1600x1000 on a large work area" {
    // A 2560x1440 monitor with a 40 px taskbar at the bottom; an
    // overlapped frame of 8 px sides and a 31 px caption.
    const frame: w32.RECT = .{ .left = -8, .top = -31, .right = 8, .bottom = 8 };
    const g = hiddenGeometry(.{ .left = 0, .top = 0, .right = 2560, .bottom = 1400 }, frame);
    try testing.expectEqual(@as(i32, 0), g.x);
    try testing.expectEqual(@as(i32, 0), g.y);
    try testing.expectEqual(@as(i32, 1600 + 16), g.width);
    try testing.expectEqual(@as(i32, 1000 + 39), g.height);
}

test "unit: app: foreground hidden geometry clamps the client to a small work area" {
    // A CI-sized 1024x768 display with a 40 px taskbar on top: the window
    // fills the work area exactly and starts at its origin.
    const frame: w32.RECT = .{ .left = -8, .top = -31, .right = 8, .bottom = 8 };
    const g = hiddenGeometry(.{ .left = 0, .top = 40, .right = 1024, .bottom = 768 }, frame);
    try testing.expectEqual(@as(i32, 0), g.x);
    try testing.expectEqual(@as(i32, 40), g.y);
    try testing.expectEqual(@as(i32, 1024), g.width);
    try testing.expectEqual(@as(i32, 728), g.height);

    // A frameless popup on a work area smaller than the frame keeps a
    // 1x1 client.
    const tiny = hiddenGeometry(.{ .left = 5, .top = 5, .right = 5, .bottom = 5 }, .{ .left = 0, .top = 0, .right = 0, .bottom = 0 });
    try testing.expectEqual(@as(i32, 1), tiny.width);
    try testing.expectEqual(@as(i32, 1), tiny.height);
}

test "unit: app: hidden placement clamps a 1600x1000 client into a 1024x768 work area on the primary monitor" {
    // A CI-sized display: the primary monitor is (0,0)-(1024,768) and has
    // no taskbar, so the work area is the whole monitor. Overlapped frame
    // at 96 DPI: 8 px sides and bottom, a 31 px caption.
    const monitor: w32.RECT = .{ .left = 0, .top = 0, .right = 1024, .bottom = 768 };
    const frame: w32.RECT = .{ .left = -8, .top = -31, .right = 8, .bottom = 8 };
    const g = hiddenGeometry(monitor, frame);

    // The client is clamped to what fits (1008x729 instead of 1600x1000)...
    const client_w = g.width - (frame.right - frame.left);
    const client_h = g.height - (frame.bottom - frame.top);
    try testing.expectEqual(@as(i32, 1024 - 16), client_w);
    try testing.expectEqual(@as(i32, 768 - 39), client_h);
    try testing.expect(client_w < hidden_client_width and client_h < hidden_client_height);

    // ...and the whole outer rect stays on the primary monitor (GL
    // presents are clipped to window ∩ monitors, spike S2 p5).
    try testing.expect(g.x >= monitor.left and g.y >= monitor.top);
    try testing.expect(g.x + g.width <= monitor.right);
    try testing.expect(g.y + g.height <= monitor.bottom);
}

test "unit: app: foreground focus gate allows SetFocus only inside the active root" {
    const root: w32.HWND = @ptrFromInt(0x1000);
    const other: w32.HWND = @ptrFromInt(0x2000);
    try testing.expect(setFocusAllowed(root, root));
    try testing.expect(!setFocusAllowed(root, other));
    try testing.expect(!setFocusAllowed(root, null)); // nothing active (hidden mode)
    try testing.expect(setFocusAllowed(null, null)); // SetFocus(null) removes focus
}

test "unit: app: foreground CBT hook moves only unowned top-level creations" {
    const owner: w32.HWND = @ptrFromInt(0x1000);
    try testing.expect(isUnownedTopLevel(0, null));
    try testing.expect(isUnownedTopLevel(0x80000000, null)); // WS_POPUP
    try testing.expect(!isUnownedTopLevel(0x80000000, owner)); // owned popup
    try testing.expect(!isUnownedTopLevel(w32.WS_CHILD, owner)); // child
    try testing.expect(!isUnownedTopLevel(0, w32.HWND_MESSAGE)); // message-only
}
