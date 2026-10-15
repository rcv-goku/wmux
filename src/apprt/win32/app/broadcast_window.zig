//! The hidden broadcast window (ARCHITECTURE.md ADR-1.6): a never-shown
//! TOP-LEVEL window, because message-only windows (msg_hwnd) do not
//! receive broadcasts. It gets WM_QUERYENDSESSION, WM_ENDSESSION,
//! WM_POWERBROADCAST, WM_SETTINGCHANGE, WM_DISPLAYCHANGE and the
//! registered "TaskbarCreated"/"TaskbarButtonCreated" messages (mapped
//! onto hooks.WM_TASKBAR_CREATED / WM_TASKBAR_BUTTON_CREATED), offers
//! every message to the app hooks, and lets DefWindowProc answer the rest
//! (so logoff and shutdown proceed exactly as before).
//!
//! It is created without WS_VISIBLE and never shown; WS_EX_TOOLWINDOW
//! keeps it out of the taskbar and Alt-Tab, WS_EX_NOACTIVATE out of
//! activation.

const std = @import("std");

const App = @import("../App.zig");
const hooks = @import("hooks.zig");
const w32 = @import("../platform/win32.zig");

const log = std.log.scoped(.app_broadcast);

pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("WmuxBroadcast");

pub const BroadcastWindow = struct {
    hwnd: ?w32.HWND = null,
    class_atom: u16 = 0,

    /// RegisterWindowMessageW ids (0 when registration failed).
    taskbar_created: u32 = 0,
    taskbar_button_created: u32 = 0,

    /// Register the class and create the hidden window. Failure only
    /// costs the broadcast hooks, so it is logged rather than fatal.
    pub fn create(self: *BroadcastWindow, app: *App, hinstance: w32.HINSTANCE) void {
        self.taskbar_created = w32.RegisterWindowMessageW(
            std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated"),
        );
        self.taskbar_button_created = w32.RegisterWindowMessageW(
            std.unicode.utf8ToUtf16LeStringLiteral("TaskbarButtonCreated"),
        );

        const wc = w32.WNDCLASSEXW{
            .cbSize = @sizeOf(w32.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = &wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = CLASS_NAME,
            .hIconSm = null,
        };
        self.class_atom = w32.RegisterClassExW(&wc);
        if (self.class_atom == 0) {
            log.warn("failed to register the broadcast window class", .{});
            return;
        }

        const hwnd = w32.CreateWindowExW(
            w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
            CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral("WmuxBroadcast"),
            w32.WS_POPUP, // no WS_VISIBLE: never shown
            0,
            0,
            0,
            0,
            null,
            null,
            hinstance,
            null,
        ) orelse {
            log.warn("failed to create the broadcast window", .{});
            return;
        };
        self.hwnd = hwnd;
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(app)));
    }

    /// Destroy the window and unregister the class (App.terminate).
    pub fn destroy(self: *BroadcastWindow, hinstance: w32.HINSTANCE) void {
        if (self.hwnd) |hwnd| {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            _ = w32.DestroyWindow(hwnd);
            self.hwnd = null;
        }
        if (self.class_atom != 0) {
            _ = w32.UnregisterClassW(CLASS_NAME, hinstance);
            self.class_atom = 0;
        }
    }
};

fn wndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const app: *App = @ptrFromInt(@as(usize, @bitCast(userdata)));

    // Registered messages get their virtual hook ids.
    const hook_msg: u32 = if (msg != 0 and msg == app.broadcast.taskbar_created)
        hooks.WM_TASKBAR_CREATED
    else if (msg != 0 and msg == app.broadcast.taskbar_button_created)
        hooks.WM_TASKBAR_BUTTON_CREATED
    else
        msg;

    if (hooks.dispatchApp(&hooks.app_hooks, app, hook_msg, wparam, lparam)) |result| return result;
    return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
}
