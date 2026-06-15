/// Standalone manual smoke test for the WebView2 bindings in webview2.zig.
/// NOT part of the ghostty build graph — build it directly:
///
///   zig build-exe src\apprt\win32\webview2_scratch.zig ^
///       -target x86_64-windows-gnu -lole32 -luser32
///
/// then place WebView2Loader.dll (from the Microsoft.Web.WebView2 NuGet
/// package, build/native/x64) next to the exe and run it. It opens a
/// topmost 800x600 window, creates a WebView2 environment/controller,
/// navigates to https://example.com, exercises every bound vtable slot it
/// reasonably can (bounds, zoom, focus, events, ExecuteScript, CDP), and
/// closes itself cleanly after a timeout so it can be screenshot-verified
/// by automation.
const std = @import("std");
const windows = std.os.windows;
const wv2 = @import("webview2.zig");

const L = std.unicode.utf8ToUtf16LeStringLiteral;

// ─── Win32 declarations (not provided by std.os.windows) ───────────────

const HWND = windows.HWND;
const HINSTANCE = windows.HINSTANCE;
const WPARAM = windows.WPARAM;
const LPARAM = windows.LPARAM;
const LRESULT = windows.LRESULT;
const RECT = windows.RECT;
const POINT = windows.POINT;
const BOOL = windows.BOOL;

const WNDCLASSEXW = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};

const MSG = extern struct {
    hwnd: ?HWND,
    message: u32,
    wParam: WPARAM,
    lParam: LPARAM,
    time: u32,
    pt: POINT,
};

const WS_OVERLAPPEDWINDOW: u32 = 0x00CF_0000;
const WS_VISIBLE: u32 = 0x1000_0000;
const WS_EX_TOPMOST: u32 = 0x0000_0008;
const WM_MOVE: u32 = 0x0003;
const WM_SIZE: u32 = 0x0005;
const WM_DESTROY: u32 = 0x0002;
const WM_TIMER: u32 = 0x0113;
const SW_SHOW: i32 = 5;
const IDC_ARROW: usize = 32512;
const COINIT_APARTMENTTHREADED: u32 = 0x2;

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?HWND, ?*anyopaque, ?HINSTANCE, ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) BOOL;
extern "user32" fn UpdateWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn GetMessageW(*MSG, ?HWND, u32, u32) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
extern "user32" fn SetTimer(?HWND, usize, u32, ?*anyopaque) callconv(.winapi) usize;
extern "user32" fn KillTimer(?HWND, usize) callconv(.winapi) BOOL;
extern "user32" fn LoadCursorW(?HINSTANCE, usize) callconv(.winapi) ?*anyopaque;
extern "user32" fn SetProcessDpiAwarenessContext(isize) callconv(.winapi) BOOL;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) windows.HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;

const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;

// How long the window stays open before auto-closing (cleanly, through
// WM_DESTROY → controller.Close) so automated runs always terminate.
const auto_close_ms: u32 = 15_000;

// ─── App state ──────────────────────────────────────────────────────────

const App = struct {
    alloc: std.mem.Allocator = std.heap.page_allocator,
    hwnd: ?HWND = null,
    controller: ?*wv2.ICoreWebView2Controller = null,
    webview: ?*wv2.ICoreWebView2 = null,
    nav_token: wv2.EventRegistrationToken = .{},
    title_token: wv2.EventRegistrationToken = .{},
    focus_token: wv2.EventRegistrationToken = .{},
    key_token: wv2.EventRegistrationToken = .{},
    first_nav_done: bool = false,
    failures: u32 = 0,
};

var app: App = .{};

const EnvHandler = wv2.EnvironmentCompletedHandler(App);
const CtrlHandler = wv2.ControllerCompletedHandler(App);
const NavHandler = wv2.NavigationCompletedEventHandler(App);
const TitleHandler = wv2.DocumentTitleChangedEventHandler(App);
const ScriptHandler = wv2.ExecuteScriptCompletedHandler(App);
const CdpHandler = wv2.CallDevToolsProtocolMethodCompletedHandler(App);
const KeyHandler = wv2.AcceleratorKeyPressedEventHandler(App);
const FocusHandler = wv2.FocusChangedEventHandler(App);
const CdpEventHandler = wv2.DevToolsProtocolEventReceivedEventHandler(App);

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[scratch] " ++ fmt ++ "\n", args);
}

fn fail(a: *App, comptime fmt: []const u8, args: anytype) void {
    a.failures += 1;
    std.debug.print("[scratch] FAIL: " ++ fmt ++ "\n", args);
}

/// Log a CoTaskMem-owned UTF-16 string and free it.
fn logCoString(comptime label: []const u8, ws: wv2.LPWSTR) void {
    defer wv2.CoTaskMemFree(ws);
    const utf8 = std.unicode.utf16LeToUtf8Alloc(app.alloc, std.mem.span(ws)) catch {
        log(label ++ ": <utf16 conversion failed>", .{});
        return;
    };
    defer app.alloc.free(utf8);
    log(label ++ ": {s}", .{utf8});
}

// ─── WebView2 callbacks ─────────────────────────────────────────────────

fn onEnvironmentCreated(a: *App, error_code: wv2.HRESULT, env_opt: ?*wv2.ICoreWebView2Environment) void {
    log("environment completed: hr=0x{x:0>8}", .{@as(u32, @bitCast(error_code))});
    const env = env_opt orelse {
        fail(a, "environment creation failed (hr=0x{x:0>8})", .{@as(u32, @bitCast(error_code))});
        PostQuitMessage(1);
        return;
    };

    // Slot 5 check: get_BrowserVersionString.
    if (env.getBrowserVersionString()) |ver| {
        logCoString("browser version (env)", ver);
    } else |_| fail(a, "env.get_BrowserVersionString", .{});

    // Slot 3: CreateCoreWebView2Controller.
    const handler = CtrlHandler.create(a.alloc, a, onControllerCreated) catch {
        fail(a, "out of memory creating controller handler", .{});
        PostQuitMessage(1);
        return;
    };
    defer handler.unref();
    env.createController(a.hwnd.?, handler) catch {
        fail(a, "env.CreateCoreWebView2Controller", .{});
        PostQuitMessage(1);
    };
}

fn onControllerCreated(a: *App, error_code: wv2.HRESULT, controller_opt: ?*wv2.ICoreWebView2Controller) void {
    log("controller completed: hr=0x{x:0>8}", .{@as(u32, @bitCast(error_code))});
    const controller = controller_opt orelse {
        fail(a, "controller creation failed (hr=0x{x:0>8})", .{@as(u32, @bitCast(error_code))});
        PostQuitMessage(1);
        return;
    };

    // Keep the controller beyond this callback.
    controller.addRef();
    a.controller = controller;

    // Slots 3/4: visibility round-trip.
    controller.putIsVisible(true) catch fail(a, "put_IsVisible", .{});
    if (controller.getIsVisible()) |visible| {
        log("is_visible={}", .{visible});
        if (!visible) fail(a, "controller not visible after put_IsVisible(TRUE)", .{});
    } else |_| fail(a, "get_IsVisible", .{});

    // Slots 5/6: bounds round-trip against the client rect.
    var client: RECT = undefined;
    _ = GetClientRect(a.hwnd.?, &client);
    controller.putBounds(client) catch fail(a, "put_Bounds", .{});
    if (controller.getBounds()) |bounds| {
        log("bounds=({},{})-({},{})", .{ bounds.left, bounds.top, bounds.right, bounds.bottom });
        if (bounds.right != client.right or bounds.bottom != client.bottom)
            fail(a, "get_Bounds mismatch after put_Bounds", .{});
    } else |_| fail(a, "get_Bounds", .{});

    // Slots 7/8: zoom factor round-trip.
    if (controller.getZoomFactor()) |zoom| {
        log("zoom_factor={d}", .{zoom});
    } else |_| fail(a, "get_ZoomFactor", .{});
    controller.putZoomFactor(1.0) catch fail(a, "put_ZoomFactor", .{});

    // Slot 15: add_GotFocus.
    if (FocusHandler.create(a.alloc, a, onGotFocus)) |h| {
        defer h.unref();
        a.focus_token = controller.addGotFocus(h) catch blk: {
            fail(a, "add_GotFocus", .{});
            break :blk .{};
        };
    } else |_| fail(a, "oom focus handler", .{});

    // Slot 19: add_AcceleratorKeyPressed.
    if (KeyHandler.create(a.alloc, a, onAcceleratorKey)) |h| {
        defer h.unref();
        a.key_token = controller.addAcceleratorKeyPressed(h) catch blk: {
            fail(a, "add_AcceleratorKeyPressed", .{});
            break :blk .{};
        };
    } else |_| fail(a, "oom key handler", .{});

    // Slot 23: NotifyParentWindowPositionChanged.
    controller.notifyParentWindowPositionChanged() catch
        fail(a, "NotifyParentWindowPositionChanged", .{});

    // Slot 25: get_CoreWebView2.
    const webview = controller.getCoreWebView2() catch {
        fail(a, "get_CoreWebView2", .{});
        PostQuitMessage(1);
        return;
    };
    a.webview = webview;

    // ICoreWebView2 slot 15: add_NavigationCompleted.
    if (NavHandler.create(a.alloc, a, onNavigationCompleted)) |h| {
        defer h.unref();
        a.nav_token = webview.addNavigationCompleted(h) catch blk: {
            fail(a, "add_NavigationCompleted", .{});
            break :blk .{};
        };
    } else |_| fail(a, "oom nav handler", .{});

    // ICoreWebView2 slot 46: add_DocumentTitleChanged.
    if (TitleHandler.create(a.alloc, a, onDocumentTitleChanged)) |h| {
        defer h.unref();
        a.title_token = webview.addDocumentTitleChanged(h) catch blk: {
            fail(a, "add_DocumentTitleChanged", .{});
            break :blk .{};
        };
    } else |_| fail(a, "oom title handler", .{});

    // ICoreWebView2 slot 5: Navigate.
    webview.navigate(L("https://example.com/")) catch fail(a, "Navigate", .{});
    log("navigation started", .{});

    // Slot 12: MoveFocus (should also fire the GotFocus event).
    controller.moveFocus(.programmatic) catch fail(a, "MoveFocus", .{});
}

fn onNavigationCompleted(a: *App, sender: ?*wv2.ICoreWebView2, args_opt: ?*wv2.ICoreWebView2NavigationCompletedEventArgs) void {
    if (a.first_nav_done) return;
    a.first_nav_done = true;

    const webview = sender orelse a.webview.?;
    if (args_opt) |args| {
        const success = args.getIsSuccess() catch blk: {
            fail(a, "get_IsSuccess", .{});
            break :blk false;
        };
        const status = args.getWebErrorStatus() catch blk: {
            fail(a, "get_WebErrorStatus", .{});
            break :blk -1;
        };
        log("navigation completed: success={} web_error_status={}", .{ success, status });
        if (!success) fail(a, "navigation reported failure (web_error_status={})", .{status});
    } else fail(a, "navigation completed args is null", .{});

    // Slot 4: get_Source.
    if (webview.getSource()) |uri| {
        logCoString("source", uri);
    } else |_| fail(a, "get_Source", .{});

    // Slot 48: get_DocumentTitle.
    if (webview.getDocumentTitle()) |title| {
        logCoString("document title", title);
    } else |_| fail(a, "get_DocumentTitle", .{});

    // Slot 29: ExecuteScript.
    if (ScriptHandler.create(a.alloc, a, onScriptCompleted)) |h| {
        defer h.unref();
        webview.executeScript(L("document.querySelector('h1').textContent"), h) catch
            fail(a, "ExecuteScript", .{});
    } else |_| fail(a, "oom script handler", .{});

    // Slot 36: CallDevToolsProtocolMethod.
    if (CdpHandler.create(a.alloc, a, onCdpMethodCompleted)) |h| {
        defer h.unref();
        webview.callDevToolsProtocolMethod(
            L("Runtime.evaluate"),
            L("{\"expression\":\"1+41\",\"returnByValue\":true}"),
            h,
        ) catch fail(a, "CallDevToolsProtocolMethod", .{});
    } else |_| fail(a, "oom cdp handler", .{});

    // Slot 42: GetDevToolsProtocolEventReceiver, then receiver slots 3/4
    // (add/remove_DevToolsProtocolEventReceived).
    if (webview.getDevToolsProtocolEventReceiver(L("Log.entryAdded"))) |receiver| {
        defer receiver.release();
        if (CdpEventHandler.create(a.alloc, a, onCdpEvent)) |h| {
            defer h.unref();
            if (receiver.addDevToolsProtocolEventReceived(h)) |token| {
                receiver.removeDevToolsProtocolEventReceived(token) catch
                    fail(a, "remove_DevToolsProtocolEventReceived", .{});
                log("CDP event receiver add/remove ok", .{});
            } else |_| fail(a, "add_DevToolsProtocolEventReceived", .{});
        } else |_| fail(a, "oom cdp event handler", .{});
    } else |_| fail(a, "GetDevToolsProtocolEventReceiver", .{});

    // Slot 43: Stop is a harmless no-op after completion.
    webview.stop() catch fail(a, "Stop", .{});
}

fn onDocumentTitleChanged(a: *App, sender: ?*wv2.ICoreWebView2, args: ?*wv2.IUnknown) void {
    _ = args; // Always null per the IDL.
    const webview = sender orelse return;
    if (webview.getDocumentTitle()) |title| {
        logCoString("title changed", title);
    } else |_| fail(a, "get_DocumentTitle (title changed)", .{});
}

fn onScriptCompleted(a: *App, error_code: wv2.HRESULT, json_opt: ?wv2.LPCWSTR) void {
    if (error_code != wv2.S_OK) {
        fail(a, "ExecuteScript completed with hr=0x{x:0>8}", .{@as(u32, @bitCast(error_code))});
        return;
    }
    const json = json_opt orelse return;
    const utf8 = std.unicode.utf16LeToUtf8Alloc(a.alloc, std.mem.span(json)) catch return;
    defer a.alloc.free(utf8);
    log("ExecuteScript result: {s}", .{utf8});
}

fn onCdpMethodCompleted(a: *App, error_code: wv2.HRESULT, json_opt: ?wv2.LPCWSTR) void {
    if (error_code != wv2.S_OK) {
        fail(a, "CallDevToolsProtocolMethod completed with hr=0x{x:0>8}", .{@as(u32, @bitCast(error_code))});
        return;
    }
    const json = json_opt orelse return;
    const utf8 = std.unicode.utf16LeToUtf8Alloc(a.alloc, std.mem.span(json)) catch return;
    defer a.alloc.free(utf8);
    log("CDP Runtime.evaluate result: {s}", .{utf8});
}

fn onCdpEvent(a: *App, sender: ?*wv2.ICoreWebView2, args_opt: ?*wv2.ICoreWebView2DevToolsProtocolEventReceivedEventArgs) void {
    _ = sender;
    const args = args_opt orelse return;
    if (args.getParameterObjectAsJson()) |json| {
        logCoString("CDP event", json);
    } else |_| fail(a, "get_ParameterObjectAsJson", .{});
}

fn onGotFocus(a: *App, sender: ?*wv2.ICoreWebView2Controller, args: ?*wv2.IUnknown) void {
    _ = sender;
    _ = args;
    _ = a;
    log("got focus event", .{});
}

fn onAcceleratorKey(a: *App, sender: ?*wv2.ICoreWebView2Controller, args_opt: ?*wv2.ICoreWebView2AcceleratorKeyPressedEventArgs) void {
    _ = sender;
    const args = args_opt orelse return;
    const kind = args.getKeyEventKind() catch return;
    const vk = args.getVirtualKey() catch return;
    const status = args.getPhysicalKeyStatus() catch return;
    log("accelerator key: kind={} vk={} scan={}", .{ kind, vk, status.ScanCode });
    args.putHandled(false) catch fail(a, "put_Handled", .{});
}

// ─── Window procedure ───────────────────────────────────────────────────

fn wndProc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_SIZE => {
            if (app.controller) |controller| {
                var client: RECT = undefined;
                if (GetClientRect(hwnd, &client) != 0) {
                    controller.putBounds(client) catch {};
                }
            }
            return 0;
        },
        WM_MOVE => {
            if (app.controller) |controller| {
                controller.notifyParentWindowPositionChanged() catch {};
            }
            return 0;
        },
        WM_TIMER => {
            log("auto-close timer fired", .{});
            _ = KillTimer(hwnd, wparam);
            _ = DestroyWindow(hwnd);
            return 0;
        },
        WM_DESTROY => {
            // Clean shutdown: unregister events, close the controller,
            // release everything.
            if (app.webview) |webview| {
                webview.removeNavigationCompleted(app.nav_token) catch
                    fail(&app, "remove_NavigationCompleted", .{});
                webview.removeDocumentTitleChanged(app.title_token) catch
                    fail(&app, "remove_DocumentTitleChanged", .{});
                webview.release();
                app.webview = null;
            }
            if (app.controller) |controller| {
                controller.removeGotFocus(app.focus_token) catch
                    fail(&app, "remove_GotFocus", .{});
                controller.removeAcceleratorKeyPressed(app.key_token) catch
                    fail(&app, "remove_AcceleratorKeyPressed", .{});
                controller.close() catch fail(&app, "controller.Close", .{});
                controller.release();
                app.controller = null;
            }
            log("cleaned up controller/webview", .{});
            PostQuitMessage(if (app.failures == 0) 0 else 1);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ─── Entry point ────────────────────────────────────────────────────────

pub fn main() !u8 {
    const alloc = app.alloc;

    // Physical-pixel coordinates so external screenshot tooling can find
    // the window precisely regardless of display scaling.
    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    const hr_init = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
    if (hr_init != wv2.S_OK and hr_init != 1) { // S_OK or S_FALSE
        log("CoInitializeEx failed: 0x{x:0>8}", .{@as(u32, @bitCast(hr_init))});
        return 1;
    }
    defer CoUninitialize();

    if (!wv2.isRuntimeAvailable()) {
        log("WebView2 runtime or WebView2Loader.dll NOT available", .{});
        return 1;
    }
    log("WebView2 runtime available", .{});

    const loader = try wv2.loadLoader();
    {
        var version: ?wv2.LPWSTR = null;
        if (loader.GetAvailableCoreWebView2BrowserVersionString(null, &version) == wv2.S_OK) {
            if (version) |v| logCoString("runtime version (loader)", v);
        }
    }

    // User data folder: %LOCALAPPDATA%\ghostty\webview2-scratch.
    const local_app_data = try std.process.getEnvVarOwned(alloc, "LOCALAPPDATA");
    defer alloc.free(local_app_data);
    const ghostty_dir = try std.fs.path.join(alloc, &.{ local_app_data, "ghostty" });
    defer alloc.free(ghostty_dir);
    const user_data_dir = try std.fs.path.join(alloc, &.{ ghostty_dir, "webview2-scratch" });
    defer alloc.free(user_data_dir);
    std.fs.makeDirAbsolute(ghostty_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(user_data_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    log("user data folder: {s}", .{user_data_dir});
    const user_data_dir_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, user_data_dir);
    defer alloc.free(user_data_dir_w);

    // Bare window class + visible window.
    const hinstance = GetModuleHandleW(null);
    const class_name = L("GhosttyWebView2Scratch");
    var wc: WNDCLASSEXW = .{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = wndProc,
        .hInstance = hinstance,
        .hCursor = LoadCursorW(null, IDC_ARROW),
        .lpszClassName = class_name,
    };
    if (RegisterClassExW(&wc) == 0) {
        log("RegisterClassExW failed", .{});
        return 1;
    }

    const hwnd = CreateWindowExW(
        WS_EX_TOPMOST,
        class_name,
        L("ghostty webview2 scratch"),
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        100,
        100,
        800,
        600,
        null,
        null,
        hinstance,
        null,
    ) orelse {
        log("CreateWindowExW failed", .{});
        return 1;
    };
    app.hwnd = hwnd;
    _ = ShowWindow(hwnd, SW_SHOW);
    _ = UpdateWindow(hwnd);
    _ = SetTimer(hwnd, 1, auto_close_ms, null);

    // Kick off async environment creation; everything else happens in the
    // completion callbacks on this thread's message pump.
    const env_handler = try EnvHandler.create(alloc, &app, onEnvironmentCreated);
    loader.createEnvironment(null, user_data_dir_w.ptr, env_handler) catch {
        env_handler.unref();
        log("CreateCoreWebView2EnvironmentWithOptions failed", .{});
        return 1;
    };
    env_handler.unref();

    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }

    log("exiting: failures={}", .{app.failures});
    return if (app.failures == 0) 0 else 1;
}
