//! The G4 choke point (ARCHITECTURE.md ADR-1.6, ADR-3.11): the ONLY code
//! that calls SetForegroundWindow, SetActiveWindow, BringWindowToTop,
//! FlashWindowEx or AllowSetForegroundWindow. Socket, CLI and automation
//! paths never activate a window; programmatic raises only move the OS
//! foreground when it already belongs to us.
//!
//! With WMUX_TEST_HIDDEN nothing here ever activates, raises or flashes a
//! window, so a test instance can never take the OS foreground
//! (ADR-12.3); the top-level window helpers at the bottom make every
//! top-level window WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE at (-32000,
//! -32000) with a fixed 1600x1000 client area, shown only with
//! SW_SHOWNOACTIVATE (still "visible" for ConPTY, GL and PrintWindow, but
//! off-screen and out of the taskbar and Alt-Tab).

const std = @import("std");

const App = @import("../App.zig");
const w32 = @import("../platform/win32.zig");

/// WMUX_TEST_HIDDEN top-level geometry (ARCHITECTURE.md ADR-12.3).
pub const hidden_origin: i32 = -32000;
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

/// The parameters to create a top-level window with: `requested`
/// unchanged normally; under WMUX_TEST_HIDDEN, WS_EX_TOOLWINDOW |
/// WS_EX_NOACTIVATE at (hidden_origin, hidden_origin) sized for a
/// hidden_client_width x hidden_client_height client area.
pub fn topLevelCreateParams(app: *const App, requested: TopLevelCreate) TopLevelCreate {
    if (!app.runtime_env.test_hidden) return requested;
    const ex_style = requested.ex_style | w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE;
    var rect: w32.RECT = .{
        .left = 0,
        .top = 0,
        .right = hidden_client_width,
        .bottom = hidden_client_height,
    };
    _ = w32.AdjustWindowRectEx(&rect, requested.style, 0, ex_style);
    return .{
        .ex_style = ex_style,
        .style = requested.style,
        .x = hidden_origin,
        .y = hidden_origin,
        .width = rect.right - rect.left,
        .height = rect.bottom - rect.top,
    };
}

/// Call right after a top-level window's WndProc can see its owner
/// (GWLP_USERDATA set). Under WMUX_TEST_HIDDEN, CreateWindowExW has
/// clamped the size to the default maximum track size (smaller than
/// 1600x1000 on small screens) before the WndProc could answer
/// WM_GETMINMAXINFO: raise the window's max-track limits and re-apply the
/// fixed geometry without activating. No-op otherwise.
pub fn finishTopLevelCreate(
    app: *const App,
    hwnd: w32.HWND,
    create: TopLevelCreate,
    max_track_w: *i32,
    max_track_h: *i32,
) void {
    if (!app.runtime_env.test_hidden) return;
    max_track_w.* = @max(max_track_w.*, create.width);
    max_track_h.* = @max(max_track_h.*, create.height);
    _ = w32.SetWindowPos(
        hwnd,
        null,
        create.x,
        create.y,
        create.width,
        create.height,
        w32.SWP_NOZORDER | w32.SWP_NOACTIVATE,
    );
}

/// Extended style of an owned top-level popup (the terminal search and
/// command palette bars): WS_EX_NOACTIVATE is added under
/// WMUX_TEST_HIDDEN. (Such popups follow their owner window, which is
/// already off-screen.)
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
