//! Window and app message hooks (ARCHITECTURE.md ADR-1.6). Instead of
//! editing `windowWndProc`/`msgWndProc` for every new message, layers and
//! features declare hooks. All hooks for a message run in declaration
//! order; the first non-null result is returned and ends dispatch (null =
//! not handled: the WndProc carries on with its own handling or
//! DefWindowProc).
//!
//! W0-A1 provides the hook types, the dispatch helpers and a TEMPORARY
//! app-hook list. W0-A3 replaces `app_hooks` with the `ui/contrib.zig`
//! registry aggregating `app_hooks`/`window_hooks` from every
//! `features/<id>/mod.zig`, and ui/Window.zig starts dispatching
//! `window_hooks`.

const std = @import("std");

const App = @import("../App.zig");
const Window = @import("../Window.zig");
const notifications = @import("../features/notifications/api.zig");
const updater = @import("../features/updater/legacy_check.zig");
const w32 = @import("../platform/win32.zig");

/// A top-level window message hook (dispatched by ui/Window.zig from
/// W0-A2/A3 on).
pub const WindowHook = struct {
    msg: u32,
    handler: *const fn (*Window, usize, isize) ?isize,
};

/// An app message hook: messages delivered to msg_hwnd that msgWndProc
/// does not handle itself, and every message of the hidden broadcast
/// window (app/broadcast_window.zig).
pub const AppHook = struct {
    msg: u32,
    handler: *const fn (*App, usize, isize) ?isize,
};

/// The Shell_NotifyIcon callback message (uCallbackMessage) of every tray
/// balloon, delivered to msg_hwnd: wparam = the icon's uID, lparam =
/// NIN_* event. Each balloon owner claims its own uIDs in an app hook.
pub const WM_APP_TRAY: u32 = w32.WM_APP + 3;

/// Virtual ids (never posted) onto which the broadcast window maps the
/// registered "TaskbarCreated" (Explorer restarted: re-add tray icons)
/// and "TaskbarButtonCreated" messages, so app hooks can match them with
/// a comptime `msg`.
pub const WM_TASKBAR_CREATED: u32 = w32.WM_APP + 0x3FFE;
pub const WM_TASKBAR_BUTTON_CREATED: u32 = w32.WM_APP + 0x3FFF;

/// TEMPORARY aggregation of the app hooks (W0-A1); W0-A3 replaces it with
/// the ui/contrib.zig registry. Order is dispatch order.
pub const app_hooks = [_]AppHook{
    .{ .msg = WM_APP_TRAY, .handler = &updater.onTrayCallback },
    .{ .msg = WM_APP_TRAY, .handler = &notifications.onTrayCallback },
};

/// Run the hooks registered for `msg`; the first non-null result wins.
pub fn dispatchApp(
    hooks: []const AppHook,
    app: *App,
    msg: u32,
    wparam: usize,
    lparam: isize,
) ?isize {
    for (hooks) |hook| {
        if (hook.msg != msg) continue;
        if (hook.handler(app, wparam, lparam)) |result| return result;
    }
    return null;
}

/// Run the window hooks registered for `msg`; the first non-null result
/// wins.
pub fn dispatchWindow(
    hooks: []const WindowHook,
    window: *Window,
    msg: u32,
    wparam: usize,
    lparam: isize,
) ?isize {
    for (hooks) |hook| {
        if (hook.msg != msg) continue;
        if (hook.handler(window, wparam, lparam)) |result| return result;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestHooks = struct {
    var calls: usize = 0;

    fn decline(app: *App, wparam: usize, lparam: isize) ?isize {
        _ = app;
        _ = wparam;
        _ = lparam;
        calls += 1;
        return null;
    }

    fn claim(app: *App, wparam: usize, lparam: isize) ?isize {
        _ = app;
        _ = lparam;
        calls += 1;
        return @intCast(wparam);
    }
};

test "unit: app: hooks run in order and the first non-null result wins" {
    const hooks = [_]AppHook{
        .{ .msg = 10, .handler = &TestHooks.decline },
        .{ .msg = 11, .handler = &TestHooks.claim },
        .{ .msg = 10, .handler = &TestHooks.claim },
        .{ .msg = 10, .handler = &TestHooks.claim },
    };

    TestHooks.calls = 0;
    // msg 10: decline, then the first claim answers; the second never runs.
    try testing.expectEqual(@as(?isize, 7), dispatchApp(&hooks, undefined, 10, 7, 0));
    try testing.expectEqual(@as(usize, 2), TestHooks.calls);

    // No hook for msg 12: not handled.
    TestHooks.calls = 0;
    try testing.expectEqual(@as(?isize, null), dispatchApp(&hooks, undefined, 12, 7, 0));
    try testing.expectEqual(@as(usize, 0), TestHooks.calls);
}
