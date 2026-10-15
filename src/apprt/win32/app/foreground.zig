//! The G4 choke point (ARCHITECTURE.md ADR-1.6, ADR-3.11): the ONLY code
//! that calls SetForegroundWindow, SetActiveWindow, BringWindowToTop,
//! FlashWindowEx or AllowSetForegroundWindow. Socket, CLI and automation
//! paths never activate a window; programmatic raises only move the OS
//! foreground when it already belongs to us.
//!
//! With WMUX_TEST_HIDDEN nothing here ever activates, raises or flashes a
//! window, so a test instance can never take the OS foreground
//! (ADR-12.3).

const std = @import("std");

const App = @import("../App.zig");
const w32 = @import("../platform/win32.zig");

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
