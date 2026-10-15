//! S2 hidden-instance probe (W0-D-S2). Standalone Win32 + WGL + GDI program
//! that reproduces the WMUX_TEST_HIDDEN window recipe without the rest of
//! wmux, so the focus / GL / PrintWindow questions can be answered cheaply
//! (and on an alternate desktop for the fallback evaluation).
//!
//! Build (from anywhere; output goes wherever -femit-bin points):
//!   zig build-exe hidden_probe.zig -target x86_64-windows-gnu -O Debug \
//!     -lc -luser32 -lgdi32 -lopengl32 -ldwmapi -femit-bin=<out>\hidden_probe.exe
//!
//! Flags:
//!   --ex=<hex>     extended style of the top-level window (default
//!                  0x08000080 = WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW;
//!                  --ex=0 is the taskbar/Alt-Tab positive control)
//!   --focus        call SetFocus(child) after showing (activation probe)
//!   --hold=<ms>    keep the window alive (pumping + rendering) for <ms>
//!   --out=<path>   write PrintWindow captures as <path>-full.bmp etc.
//!   --gdi          paint the pattern with GDI (WM_PAINT) instead of GL
//!   --readback     log a glReadPixels sample of the back buffer
//!   --x=<n> --y=<n> window position (default -32000,-32000)
//!   --cloak        DwmSetWindowAttribute(DWMWA_CLOAK) before showing
//!   --cbt          thread-local WH_CBT hook: hidden ex-styles + cloak (or
//!                  off-screen) for every top-level window, block HCBT_ACTIVATE
//!   --msgbox       show a MessageBox (requires --cbt), auto-closed after 1.5 s
//!
//! Every step checks GetForegroundWindow(); if it ever belongs to this
//! process the probe destroys its window and exits with code 3 at once.
//! Output is line-oriented `key=value` text on stderr.

const std = @import("std");
const W = std.os.windows;

const HWND = W.HWND;
const HDC = W.HDC;
const HGLRC = W.HGLRC;
const BOOL = W.BOOL;
const RECT = W.RECT;

// ---------------------------------------------------------------- externs

const WNDPROC = *const fn (HWND, u32, W.WPARAM, W.LPARAM) callconv(.winapi) W.LRESULT;

const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?W.HINSTANCE = null,
    hIcon: ?W.HICON = null,
    hCursor: ?W.HCURSOR = null,
    hbrBackground: ?W.HBRUSH = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?W.HICON = null,
};

const MSG = extern struct {
    hwnd: ?HWND,
    message: u32,
    wParam: W.WPARAM,
    lParam: W.LPARAM,
    time: u32,
    pt: W.POINT,
    lPrivate: u32,
};

const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16 = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: u16 = 1,
    dwFlags: u32 = 0,
    iPixelType: u8 = 0,
    cColorBits: u8 = 0,
    cRedBits: u8 = 0,
    cRedShift: u8 = 0,
    cGreenBits: u8 = 0,
    cGreenShift: u8 = 0,
    cBlueBits: u8 = 0,
    cBlueShift: u8 = 0,
    cAlphaBits: u8 = 0,
    cAlphaShift: u8 = 0,
    cAccumBits: u8 = 0,
    cAccumRedBits: u8 = 0,
    cAccumGreenBits: u8 = 0,
    cAccumBlueBits: u8 = 0,
    cAccumAlphaBits: u8 = 0,
    cDepthBits: u8 = 0,
    cStencilBits: u8 = 0,
    cAuxBuffers: u8 = 0,
    iLayerType: u8 = 0,
    bReserved: u8 = 0,
    dwLayerMask: u32 = 0,
    dwVisibleMask: u32 = 0,
    dwDamageMask: u32 = 0,
};

const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0, // BI_RGB
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?W.HINSTANCE;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
extern "kernel32" fn ExitProcess(u32) callconv(.winapi) noreturn;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?HWND, ?*anyopaque, ?W.HINSTANCE, ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(HWND, u32, W.WPARAM, W.LPARAM) callconv(.winapi) W.LRESULT;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) BOOL;
extern "user32" fn UpdateWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn PeekMessageW(*MSG, ?HWND, u32, u32, u32) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) W.LRESULT;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
extern "user32" fn GetWindowThreadProcessId(HWND, ?*u32) callconv(.winapi) u32;
extern "user32" fn AllowSetForegroundWindow(u32) callconv(.winapi) BOOL;
extern "user32" fn SetFocus(?HWND) callconv(.winapi) ?HWND;
extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
extern "user32" fn GetActiveWindow() callconv(.winapi) ?HWND;
extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.winapi) BOOL;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
extern "user32" fn AdjustWindowRectEx(*RECT, u32, BOOL, u32) callconv(.winapi) BOOL;
extern "user32" fn PrintWindow(HWND, HDC, u32) callconv(.winapi) BOOL;
extern "user32" fn GetDC(?HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(?HWND, HDC) callconv(.winapi) i32;
extern "user32" fn IsWindowVisible(HWND) callconv(.winapi) BOOL;
extern "user32" fn GetWindowLongW(HWND, i32) callconv(.winapi) i32;

extern "gdi32" fn ChoosePixelFormat(HDC, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) i32;
extern "gdi32" fn SetPixelFormat(HDC, i32, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
extern "gdi32" fn SwapBuffers(HDC) callconv(.winapi) BOOL;
extern "gdi32" fn CreateCompatibleDC(?HDC) callconv(.winapi) ?HDC;
extern "gdi32" fn CreateDIBSection(?HDC, *const BITMAPINFOHEADER, u32, *?*anyopaque, ?W.HANDLE, u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn SelectObject(HDC, *anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(*anyopaque) callconv(.winapi) BOOL;
extern "gdi32" fn DeleteDC(HDC) callconv(.winapi) BOOL;
extern "gdi32" fn GdiFlush() callconv(.winapi) BOOL;

extern "opengl32" fn wglCreateContext(HDC) callconv(.winapi) ?HGLRC;
extern "opengl32" fn wglMakeCurrent(?HDC, ?HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglDeleteContext(HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglGetProcAddress([*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "opengl32" fn glGetString(u32) callconv(.winapi) ?[*:0]const u8;
extern "opengl32" fn glClearColor(f32, f32, f32, f32) callconv(.winapi) void;
extern "opengl32" fn glClear(u32) callconv(.winapi) void;
extern "opengl32" fn glEnable(u32) callconv(.winapi) void;
extern "opengl32" fn glDisable(u32) callconv(.winapi) void;
extern "opengl32" fn glScissor(i32, i32, i32, i32) callconv(.winapi) void;
extern "opengl32" fn glViewport(i32, i32, i32, i32) callconv(.winapi) void;
extern "opengl32" fn glFinish() callconv(.winapi) void;

extern "opengl32" fn glReadBuffer(u32) callconv(.winapi) void;
extern "opengl32" fn glReadPixels(i32, i32, i32, i32, u32, u32, *anyopaque) callconv(.winapi) void;

const PAINTSTRUCT = extern struct {
    hdc: ?HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};
extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) ?HDC;
extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn FillRect(HDC, *const RECT, *anyopaque) callconv(.winapi) i32;
extern "user32" fn InvalidateRect(?HWND, ?*const RECT, BOOL) callconv(.winapi) BOOL;
extern "user32" fn WindowFromPoint(W.POINT) callconv(.winapi) ?HWND;

// Thread-local WH_CBT hook (--cbt): one choke point for every window the UI
// thread creates, including user32-internal ones (MessageBox, menus).
const HOOKPROC = *const fn (i32, W.WPARAM, W.LPARAM) callconv(.winapi) W.LRESULT;
const TIMERPROC = *const fn (?HWND, u32, usize, u32) callconv(.winapi) void;
const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque,
    hInstance: ?W.HINSTANCE,
    hMenu: ?*anyopaque,
    hwndParent: ?HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: i32,
    lpszName: ?[*:0]const u16,
    lpszClass: ?*const anyopaque,
    dwExStyle: u32,
};
const CBT_CREATEWNDW = extern struct { lpcs: *CREATESTRUCTW, hwndInsertAfter: ?HWND };
extern "user32" fn SetWindowsHookExW(i32, HOOKPROC, ?W.HINSTANCE, u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn UnhookWindowsHookEx(*anyopaque) callconv(.winapi) BOOL;
extern "user32" fn CallNextHookEx(?*anyopaque, i32, W.WPARAM, W.LPARAM) callconv(.winapi) W.LRESULT;
extern "user32" fn MessageBoxW(?HWND, [*:0]const u16, [*:0]const u16, u32) callconv(.winapi) i32;
extern "user32" fn SetTimer(?HWND, usize, u32, ?TIMERPROC) callconv(.winapi) usize;
extern "user32" fn KillTimer(?HWND, usize) callconv(.winapi) BOOL;
extern "user32" fn PostMessageW(?HWND, u32, W.WPARAM, W.LPARAM) callconv(.winapi) BOOL;
extern "user32" fn SetWindowLongW(HWND, i32, i32) callconv(.winapi) i32;
extern "user32" fn GetClassNameW(HWND, [*]u16, i32) callconv(.winapi) i32;
extern "gdi32" fn CreateSolidBrush(u32) callconv(.winapi) ?*anyopaque;
extern "dwmapi" fn DwmSetWindowAttribute(HWND, u32, *const anyopaque, u32) callconv(.winapi) i32;
extern "dwmapi" fn DwmGetWindowAttribute(HWND, u32, *anyopaque, u32) callconv(.winapi) i32;
extern "dwmapi" fn DwmFlush() callconv(.winapi) i32;

const WglCreateContextAttribsARB = *const fn (HDC, ?HGLRC, [*]const i32) callconv(.winapi) ?HGLRC;

// --------------------------------------------------------------- constants

const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
const WS_CLIPCHILDREN: u32 = 0x02000000;
const WS_CHILD: u32 = 0x40000000;
const WS_VISIBLE: u32 = 0x10000000;
const WS_EX_TOOLWINDOW: u32 = 0x00000080;
const WS_EX_NOACTIVATE: u32 = 0x08000000;
const SW_SHOWNOACTIVATE: i32 = 4;
const CS_OWNDC: u32 = 0x0020;
const PM_REMOVE: u32 = 0x0001;
const PW_CLIENTONLY: u32 = 0x1;
const PW_RENDERFULLCONTENT: u32 = 0x2;
const DWMWA_CLOAKED: u32 = 14;
const GWL_EXSTYLE: i32 = -20;

const PFD_DRAW_TO_WINDOW: u32 = 0x4;
const PFD_SUPPORT_OPENGL: u32 = 0x20;
const PFD_DOUBLEBUFFER: u32 = 0x1;

const GL_VENDOR: u32 = 0x1F00;
const GL_RENDERER: u32 = 0x1F01;
const GL_VERSION: u32 = 0x1F02;
const GL_COLOR_BUFFER_BIT: u32 = 0x4000;
const GL_SCISSOR_TEST: u32 = 0x0C11;

const WGL_CONTEXT_MAJOR_VERSION_ARB: i32 = 0x2091;
const WGL_CONTEXT_MINOR_VERSION_ARB: i32 = 0x2092;
const WGL_CONTEXT_PROFILE_MASK_ARB: i32 = 0x9126;
const WGL_CONTEXT_CORE_PROFILE_BIT_ARB: i32 = 0x1;

const WM_SETFOCUS: u32 = 0x0007;
const WM_KILLFOCUS: u32 = 0x0008;
const WM_ACTIVATE: u32 = 0x0006;
const WM_ACTIVATEAPP: u32 = 0x001C;
const WM_NCACTIVATE: u32 = 0x0086;
const WM_PAINT: u32 = 0x000F;
const DWMWA_CLOAK: u32 = 13;
const GL_BACK: u32 = 0x0405;
const GL_RGBA: u32 = 0x1908;
const GL_UNSIGNED_BYTE: u32 = 0x1401;

const CLIENT_W: i32 = 1600;
const CLIENT_H: i32 = 1000;
const HIDDEN_POS: i32 = -32000;

// ------------------------------------------------------------------ state

var g_top: ?HWND = null;
var g_child: ?HWND = null;
var g_pid: u32 = 0;
var g_activate_msgs: u32 = 0;
var g_setfocus_msgs: u32 = 0;
var g_gdi = false;
var g_readback = false;
var g_readback_done = false;
var g_cbt_cloak = false;
var g_cbt_created: u32 = 0;
var g_cbt_blocked_activate: u32 = 0;
var g_last_dialog: ?HWND = null;
var g_msgbox_timer: usize = 0;

const WH_CBT: i32 = 5;
const HCBT_CREATEWND: i32 = 3;
const HCBT_ACTIVATE: i32 = 5;
const HWND_MESSAGE_VAL: usize = @bitCast(@as(isize, -3));
const WM_CLOSE: u32 = 0x0010;

fn className(hwnd: HWND, buf: *[64]u8) []const u8 {
    var wbuf: [64]u16 = undefined;
    const n = GetClassNameW(hwnd, &wbuf, 64);
    var i: usize = 0;
    while (i < @as(usize, @intCast(@max(n, 0))) and i < buf.len) : (i += 1) buf[i] = if (wbuf[i] < 128) @intCast(wbuf[i]) else '?';
    return buf[0..i];
}

/// WH_CBT hook: give every top-level window the hidden ex-styles, cloak it
/// (or push it off-screen if cloaking is refused), and block activation.
fn cbtProc(code: i32, wp: W.WPARAM, lp: W.LPARAM) callconv(.winapi) W.LRESULT {
    if (code == HCBT_CREATEWND) {
        const hwnd: HWND = @ptrFromInt(wp);
        const cw: *CBT_CREATEWNDW = @ptrFromInt(@as(usize, @bitCast(lp)));
        const cs = cw.lpcs;
        const style: u32 = @bitCast(cs.style);
        const parent_val: usize = if (cs.hwndParent) |p| @intFromPtr(p) else 0;
        if (style & WS_CHILD == 0 and parent_val != HWND_MESSAGE_VAL) {
            g_cbt_created += 1;
            cs.dwExStyle |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
            const ex_now: u32 = @bitCast(GetWindowLongW(hwnd, GWL_EXSTYLE));
            _ = SetWindowLongW(hwnd, GWL_EXSTYLE, @bitCast(ex_now | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE));
            var hr: i32 = 0;
            if (g_cbt_cloak) {
                const on: u32 = 1;
                hr = DwmSetWindowAttribute(hwnd, DWMWA_CLOAK, &on, 4);
            }
            if (!g_cbt_cloak or hr != 0) {
                cs.x = HIDDEN_POS;
                cs.y = HIDDEN_POS;
            }
            var cb: [64]u8 = undefined;
            const cls = className(hwnd, &cb);
            if (std.mem.eql(u8, cls, "#32770")) g_last_dialog = hwnd;
            log("cbt create hwnd=0x{x} class={s} cloak_hr=0x{x:0>8}", .{ @intFromPtr(hwnd), cls, @as(u32, @bitCast(hr)) });
        }
    } else if (code == HCBT_ACTIVATE) {
        g_cbt_blocked_activate += 1;
        log("cbt blocked activate hwnd=0x{x}", .{wp});
        return 1;
    }
    return CallNextHookEx(null, code, wp, lp);
}

/// Fires inside MessageBox's modal loop: report the dialog's state, close it.
fn msgboxTimer(_: ?HWND, _: u32, id: usize, _: u32) callconv(.winapi) void {
    _ = KillTimer(null, id);
    fgCheck("msgbox");
    const dlg = g_last_dialog orelse {
        log("msgbox dialog not seen by hook", .{});
        return;
    };
    var r: RECT = undefined;
    _ = GetWindowRect(dlg, &r);
    var cloaked: u32 = 0;
    _ = DwmGetWindowAttribute(dlg, DWMWA_CLOAKED, &cloaked, 4);
    log("msgbox dialog hwnd=0x{x} visible={d} cloaked={d} rect=({d},{d})-({d},{d}) exstyle=0x{x:0>8} active_is_dialog={}", .{ @intFromPtr(dlg), IsWindowVisible(dlg), cloaked, r.left, r.top, r.right, r.bottom, @as(u32, @bitCast(GetWindowLongW(dlg, GWL_EXSTYLE))), GetActiveWindow() == dlg });
    _ = PostMessageW(dlg, WM_CLOSE, 0, 0);
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

/// Abort immediately if the foreground window belongs to this process.
fn fgCheck(step: []const u8) void {
    const fg = GetForegroundWindow();
    var fg_pid: u32 = 0;
    if (fg) |h| _ = GetWindowThreadProcessId(h, &fg_pid);
    if (fg_pid == g_pid) {
        log("FOREGROUND_STOLEN step={s} hwnd=0x{x}", .{ step, if (fg) |h| @intFromPtr(h) else 0 });
        if (g_top) |t| _ = DestroyWindow(t);
        ExitProcess(3);
    }
}

fn wndProc(hwnd: HWND, msg: u32, wp: W.WPARAM, lp: W.LPARAM) callconv(.winapi) W.LRESULT {
    switch (msg) {
        WM_PAINT => if (g_gdi and g_child != null and hwnd == g_child.?) {
            var ps: PAINTSTRUCT = undefined;
            const dc = BeginPaint(hwnd, &ps) orelse return 0;
            const bg = CreateSolidBrush(0x004D1A1A).?; // RGB(26,26,77) as COLORREF 0x00BBGGRR
            const red = CreateSolidBrush(0x000000FF).?;
            const green = CreateSolidBrush(0x0000FF00).?;
            const white = CreateSolidBrush(0x00FFFFFF).?;
            _ = FillRect(dc, &.{ .left = 0, .top = 0, .right = CLIENT_W, .bottom = CLIENT_H }, bg);
            _ = FillRect(dc, &.{ .left = 50, .top = 50, .right = 250, .bottom = 150 }, red);
            _ = FillRect(dc, &.{ .left = 300, .top = 50, .right = 500, .bottom = 150 }, green);
            _ = FillRect(dc, &.{ .left = 550, .top = 50, .right = 750, .bottom = 150 }, white);
            for ([_]*anyopaque{ bg, red, green, white }) |b| _ = DeleteObject(b);
            _ = EndPaint(hwnd, &ps);
            return 0;
        },
        WM_ACTIVATE, WM_ACTIVATEAPP, WM_NCACTIVATE => {
            g_activate_msgs += 1;
            log("msg hwnd=0x{x} msg=0x{x:0>4} wparam={d}", .{ @intFromPtr(hwnd), msg, wp });
        },
        WM_SETFOCUS, WM_KILLFOCUS => {
            if (msg == WM_SETFOCUS) g_setfocus_msgs += 1;
            log("msg hwnd=0x{x} msg=0x{x:0>4}", .{ @intFromPtr(hwnd), msg });
        },
        else => {},
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

fn pump(step: []const u8) void {
    var m: MSG = undefined;
    while (PeekMessageW(&m, null, 0, 0, PM_REMOVE) != 0) {
        _ = TranslateMessage(&m);
        _ = DispatchMessageW(&m);
    }
    fgCheck(step);
}

fn drawPattern(hdc: HDC, w: i32, h: i32) void {
    glViewport(0, 0, w, h);
    glDisable(GL_SCISSOR_TEST);
    glClearColor(0.10, 0.10, 0.30, 1.0); // dark blue background
    glClear(GL_COLOR_BUFFER_BIT);
    glEnable(GL_SCISSOR_TEST);
    const rects = [_]struct { x: i32, c: [3]f32 }{
        .{ .x = 50, .c = .{ 1, 0, 0 } }, // red
        .{ .x = 300, .c = .{ 0, 1, 0 } }, // green
        .{ .x = 550, .c = .{ 1, 1, 1 } }, // white
    };
    for (rects) |r| {
        glScissor(r.x, h - 150, 200, 100);
        glClearColor(r.c[0], r.c[1], r.c[2], 1.0);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    glDisable(GL_SCISSOR_TEST);
    glFinish();
    if (g_readback and !g_readback_done) {
        // Back-buffer readback inside the red rect: proves GL rasterized
        // even when nothing reaches the window/DWM.
        var px: [4]u8 = @splat(0);
        glReadBuffer(GL_BACK);
        glReadPixels(150, h - 100, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &px);
        log("readback back_buffer_rgba={d},{d},{d},{d}", .{ px[0], px[1], px[2], px[3] });
        g_readback_done = true;
    }
    _ = SwapBuffers(hdc);
}

const Stats = struct { ok: bool, w: i32, h: i32, red: usize, green: usize, white: usize, bg: usize, black: usize, other: usize };

/// PrintWindow `hwnd` into a top-down 32bpp DIB and classify pixels.
fn capture(hwnd: HWND, flags: u32, out_base: ?[]const u8, suffix: []const u8) Stats {
    var r: RECT = undefined;
    if (flags & PW_CLIENTONLY != 0) _ = GetClientRect(hwnd, &r) else _ = GetWindowRect(hwnd, &r);
    const w = r.right - r.left;
    const h = r.bottom - r.top;
    var st: Stats = .{ .ok = false, .w = w, .h = h, .red = 0, .green = 0, .white = 0, .bg = 0, .black = 0, .other = 0 };
    const screen = GetDC(null) orelse return st;
    defer _ = ReleaseDC(null, screen);
    const mem = CreateCompatibleDC(screen) orelse return st;
    defer _ = DeleteDC(mem);
    const bih: BITMAPINFOHEADER = .{ .biWidth = w, .biHeight = -h };
    var bits: ?*anyopaque = null;
    const bmp = CreateDIBSection(mem, &bih, 0, &bits, null, 0) orelse return st;
    defer _ = DeleteObject(bmp);
    const old = SelectObject(mem, bmp);
    st.ok = PrintWindow(hwnd, mem, flags) != 0;
    if (!st.ok) log("PrintWindow failed flags={d} err={d}", .{ flags, GetLastError() });
    _ = GdiFlush();
    const px: [*]const u32 = @ptrCast(@alignCast(bits.?));
    const n: usize = @intCast(w * h);
    for (px[0..n]) |p| {
        const rgb = p & 0x00FFFFFF;
        const rr = (rgb >> 16) & 0xFF;
        const gg = (rgb >> 8) & 0xFF;
        const bb = rgb & 0xFF;
        if (rr > 240 and gg < 16 and bb < 16) st.red += 1 else if (gg > 240 and rr < 16 and bb < 16) st.green += 1 else if (rr > 240 and gg > 240 and bb > 240) st.white += 1 else if (rr < 40 and gg < 40 and bb > 60 and bb < 90) st.bg += 1 else if (rgb == 0) st.black += 1 else st.other += 1;
    }
    if (out_base) |base| saveBmp(base, suffix, px[0..n], w, h);
    if (old) |o| _ = SelectObject(mem, o);
    return st;
}

fn saveBmp(base: []const u8, suffix: []const u8, px: []const u32, w: i32, h: i32) void {
    var path_buf: [600]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}-{s}.bmp", .{ base, suffix }) catch return;
    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();
    const img_bytes: u32 = @intCast(px.len * 4);
    var hdr: [54]u8 = @splat(0);
    hdr[0] = 'B';
    hdr[1] = 'M';
    std.mem.writeInt(u32, hdr[2..6], 54 + img_bytes, .little);
    std.mem.writeInt(u32, hdr[10..14], 54, .little);
    std.mem.writeInt(u32, hdr[14..18], 40, .little);
    std.mem.writeInt(i32, hdr[18..22], w, .little);
    std.mem.writeInt(i32, hdr[22..26], -h, .little);
    std.mem.writeInt(u16, hdr[26..28], 1, .little);
    std.mem.writeInt(u16, hdr[28..30], 32, .little);
    file.writeAll(&hdr) catch return;
    file.writeAll(std.mem.sliceAsBytes(px)) catch return;
}

fn logStats(name: []const u8, s: Stats) void {
    log("capture={s} ok={} size={d}x{d} red={d} green={d} white={d} bg={d} black={d} other={d}", .{ name, s.ok, s.w, s.h, s.red, s.green, s.white, s.bg, s.black, s.other });
}

pub fn main() !void {
    var ex: u32 = WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
    var do_focus = false;
    var cloak = false;
    var use_cbt = false;
    var do_msgbox = false;
    var hold_ms: u64 = 0;
    var pos_x: i32 = HIDDEN_POS;
    var pos_y: i32 = HIDDEN_POS;
    var out_base: ?[]const u8 = null;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try std.process.argsAlloc(arena);
    for (args[1..]) |a| {
        if (std.mem.startsWith(u8, a, "--ex=")) {
            ex = try std.fmt.parseInt(u32, a[5..], 0);
        } else if (std.mem.eql(u8, a, "--focus")) {
            do_focus = true;
        } else if (std.mem.eql(u8, a, "--gdi")) {
            g_gdi = true;
        } else if (std.mem.eql(u8, a, "--cloak")) {
            cloak = true;
        } else if (std.mem.eql(u8, a, "--cbt")) {
            use_cbt = true;
        } else if (std.mem.eql(u8, a, "--msgbox")) {
            do_msgbox = true;
        } else if (std.mem.eql(u8, a, "--readback")) {
            g_readback = true;
        } else if (std.mem.startsWith(u8, a, "--x=")) {
            pos_x = try std.fmt.parseInt(i32, a[4..], 10);
        } else if (std.mem.startsWith(u8, a, "--y=")) {
            pos_y = try std.fmt.parseInt(i32, a[4..], 10);
        } else if (std.mem.startsWith(u8, a, "--hold=")) {
            hold_ms = try std.fmt.parseInt(u64, a[7..], 10);
        } else if (std.mem.startsWith(u8, a, "--out=")) {
            out_base = a[6..];
        }
    }

    g_pid = GetCurrentProcessId();
    const fg0 = GetForegroundWindow();
    var fg0_pid: u32 = 0;
    if (fg0) |h| _ = GetWindowThreadProcessId(h, &fg0_pid);
    // Probe whether this process may set the foreground window right now
    // (AllowSetForegroundWindow requires that right; granting it to
    // ourselves changes nothing if we already hold it).
    const can_fg = AllowSetForegroundWindow(g_pid);
    const can_fg_err = if (can_fg == 0) GetLastError() else 0;
    log("start pid={d} tid={d} ex=0x{x:0>8} pos={d},{d} gdi={} cloak={} focus={} fg0_pid={d} can_set_foreground={d} err={d}", .{ g_pid, GetCurrentThreadId(), ex, pos_x, pos_y, g_gdi, cloak, do_focus, fg0_pid, can_fg, can_fg_err });
    fgCheck("start");

    if (do_msgbox and !use_cbt) {
        log("refusing --msgbox without --cbt (the dialog would be visible)", .{});
        ExitProcess(5);
    }
    var hook: ?*anyopaque = null;
    if (use_cbt) {
        g_cbt_cloak = cloak;
        hook = SetWindowsHookExW(WH_CBT, cbtProc, null, GetCurrentThreadId());
        log("cbt hook installed={}", .{hook != null});
        if (hook == null) ExitProcess(6);
    }
    defer if (hook) |h| {
        _ = UnhookWindowsHookEx(h);
    };

    const hinst = GetModuleHandleW(null);
    const top_class = std.unicode.utf8ToUtf16LeStringLiteral("S2ProbeTop");
    const gl_class = std.unicode.utf8ToUtf16LeStringLiteral("S2ProbeGL");
    _ = RegisterClassExW(&.{ .lpfnWndProc = wndProc, .hInstance = hinst, .lpszClassName = top_class });
    _ = RegisterClassExW(&.{ .style = CS_OWNDC, .lpfnWndProc = wndProc, .hInstance = hinst, .lpszClassName = gl_class });

    const style: u32 = WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN;
    var wr: RECT = .{ .left = 0, .top = 0, .right = CLIENT_W, .bottom = CLIENT_H };
    _ = AdjustWindowRectEx(&wr, style, 0, ex);
    const top = CreateWindowExW(ex, top_class, std.unicode.utf8ToUtf16LeStringLiteral("S2 hidden probe"), style, pos_x, pos_y, wr.right - wr.left, wr.bottom - wr.top, null, null, hinst, null) orelse {
        log("CreateWindowExW(top) failed err={d}", .{GetLastError()});
        return error.CreateWindow;
    };
    g_top = top;
    if (cloak) {
        const on: u32 = 1;
        const hr = DwmSetWindowAttribute(top, DWMWA_CLOAK, &on, 4);
        var state: u32 = 0;
        _ = DwmGetWindowAttribute(top, DWMWA_CLOAKED, &state, 4);
        log("cloak hr=0x{x:0>8} cloaked_state={d}", .{ @as(u32, @bitCast(hr)), state });
        // Safety: an on-screen window must never be shown uncloaked.
        if (hr != 0 or state == 0) {
            log("cloak failed; refusing to show", .{});
            _ = DestroyWindow(top);
            ExitProcess(4);
        }
    }
    const child = CreateWindowExW(0, gl_class, std.unicode.utf8ToUtf16LeStringLiteral(""), WS_CHILD | WS_VISIBLE, 0, 0, CLIENT_W, CLIENT_H, top, null, hinst, null) orelse {
        log("CreateWindowExW(child) failed err={d}", .{GetLastError()});
        return error.CreateWindow;
    };
    g_child = child;
    fgCheck("create");

    // WGL: legacy context first (needed to get wglCreateContextAttribsARB),
    // then a 4.3 core context like Ghostty's renderer requires.
    const hdc = GetDC(child) orelse return error.GetDC;
    var ctx: ?HGLRC = null;
    if (!g_gdi) {
        const pfd: PIXELFORMATDESCRIPTOR = .{ .dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER, .cColorBits = 32, .cAlphaBits = 8, .cDepthBits = 24, .cStencilBits = 8 };
        const fmt = ChoosePixelFormat(hdc, &pfd);
        if (fmt == 0 or SetPixelFormat(hdc, fmt, &pfd) == 0) {
            log("pixel format failed fmt={d} err={d}", .{ fmt, GetLastError() });
            return error.PixelFormat;
        }
        const legacy = wglCreateContext(hdc) orelse {
            log("wglCreateContext failed err={d}", .{GetLastError()});
            return error.Wgl;
        };
        _ = wglMakeCurrent(hdc, legacy);
        log("gl_legacy vendor=\"{s}\" renderer=\"{s}\" version=\"{s}\"", .{ glGetString(GL_VENDOR) orelse "?", glGetString(GL_RENDERER) orelse "?", glGetString(GL_VERSION) orelse "?" });
        ctx = legacy;
        if (wglGetProcAddress("wglCreateContextAttribsARB")) |p| {
            const create_attribs: WglCreateContextAttribsARB = @ptrCast(p);
            const attribs = [_]i32{ WGL_CONTEXT_MAJOR_VERSION_ARB, 4, WGL_CONTEXT_MINOR_VERSION_ARB, 3, WGL_CONTEXT_PROFILE_MASK_ARB, WGL_CONTEXT_CORE_PROFILE_BIT_ARB, 0 };
            if (create_attribs(hdc, null, &attribs)) |core| {
                _ = wglMakeCurrent(hdc, core);
                _ = wglDeleteContext(legacy);
                ctx = core;
                log("gl_core43 ok=true version=\"{s}\" renderer=\"{s}\"", .{ glGetString(GL_VERSION) orelse "?", glGetString(GL_RENDERER) orelse "?" });
            } else log("gl_core43 ok=false err={d}", .{GetLastError()});
        } else log("gl_core43 ok=false reason=no_wglCreateContextAttribsARB", .{});
    }

    _ = ShowWindow(top, SW_SHOWNOACTIVATE);
    _ = UpdateWindow(top);
    pump("show");

    if (do_focus) {
        _ = SetFocus(child);
        pump("setfocus");
    }
    log("after_show active_is_top={} focus_is_child={} activate_msgs={d} setfocus_msgs={d}", .{ GetActiveWindow() == top, GetFocus() == child, g_activate_msgs, g_setfocus_msgs });
    {
        // Hit-test probe: would a user click at the window's centre land
        // on our (invisible) window? WindowFromPoint is a pure query.
        var wr2: RECT = undefined;
        _ = GetWindowRect(top, &wr2);
        const pt: W.POINT = .{ .x = @divTrunc(wr2.left + wr2.right, 2), .y = @divTrunc(wr2.top + wr2.bottom, 2) };
        const hit = WindowFromPoint(pt);
        var hit_pid: u32 = 0;
        if (hit) |hh| _ = GetWindowThreadProcessId(hh, &hit_pid);
        log("hittest x={d} y={d} hit_is_ours={}", .{ pt.x, pt.y, hit_pid == g_pid });
    }

    var frame: u32 = 0;
    while (frame < 20) : (frame += 1) {
        if (g_gdi) {
            _ = InvalidateRect(child, null, 0);
        } else drawPattern(hdc, CLIENT_W, CLIENT_H);
        pump("render");
        Sleep(16);
    }
    _ = DwmFlush();

    var r: RECT = undefined;
    _ = GetWindowRect(top, &r);
    var cr: RECT = undefined;
    _ = GetClientRect(top, &cr);
    var cloaked: u32 = 0;
    _ = DwmGetWindowAttribute(top, DWMWA_CLOAKED, &cloaked, 4);
    log("window rect=({d},{d})-({d},{d}) client={d}x{d} visible={d} cloaked={d} exstyle=0x{x:0>8}", .{ r.left, r.top, r.right, r.bottom, cr.right, cr.bottom, IsWindowVisible(top), cloaked, @as(u32, @bitCast(GetWindowLongW(top, GWL_EXSTYLE))) });

    logStats("top_full", capture(top, PW_RENDERFULLCONTENT, out_base, "full"));
    logStats("top_client", capture(top, PW_RENDERFULLCONTENT | PW_CLIENTONLY, out_base, "client"));
    logStats("top_legacy", capture(top, 0, out_base, "legacy"));
    logStats("child_full", capture(child, PW_RENDERFULLCONTENT, null, "child"));

    if (do_msgbox) {
        // A user32-internal window (the MessageBox dialog) must also stay
        // hidden and never activate; only the CBT hook can reach it.
        g_msgbox_timer = SetTimer(null, 0, 1500, msgboxTimer);
        const rc = MessageBoxW(top, std.unicode.utf8ToUtf16LeStringLiteral("S2 probe dialog"), std.unicode.utf8ToUtf16LeStringLiteral("S2"), 0);
        log("msgbox returned={d} cbt_created={d} cbt_blocked_activate={d}", .{ rc, g_cbt_created, g_cbt_blocked_activate });
        fgCheck("msgbox_done");
    }
    fgCheck("capture");

    if (hold_ms > 0) {
        log("READY hold_ms={d}", .{hold_ms});
        const end = GetTickCount64() + hold_ms;
        while (GetTickCount64() < end) {
            if (g_gdi) {
                _ = InvalidateRect(child, null, 0);
            } else drawPattern(hdc, CLIENT_W, CLIENT_H);
            pump("hold");
            Sleep(50);
        }
    }

    if (ctx) |c| {
        _ = wglMakeCurrent(null, null);
        _ = wglDeleteContext(c);
    }
    _ = ReleaseDC(child, hdc);
    _ = DestroyWindow(top);
    pump("destroy");
    log("done activate_msgs={d} setfocus_msgs={d}", .{ g_activate_msgs, g_setfocus_msgs });
}
