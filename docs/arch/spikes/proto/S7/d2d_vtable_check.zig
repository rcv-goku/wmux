//! S7 spike: Zig 0.15.2 check of the hand-written Direct2D vtable pattern the
//! W1-8a bindings will use, in particular the struct-return ABI rule:
//! COM methods that return a struct (ID2D1RenderTarget::GetSize/GetPixelSize/
//! GetPixelFormat, ID2D1Bitmap::GetSize, ...) are C++ instance methods, so on
//! x64 the result travels through a hidden out-pointer passed after `this`.
//! Declaring them as `fn (*This) callconv(.winapi) D2D1_SIZE_F` (what a
//! naive translation of the C header gives) reads garbage or crashes.
//!
//! Standalone; never shows a window (the HWND is created without WS_VISIBLE).
//!   zig run d2d_vtable_check.zig -target x86_64-windows-gnu -ld2d1 -luser32
const std = @import("std");
const w = std.os.windows;

const HRESULT = w.HRESULT;
const GUID = w.GUID;
const Pad = *const fn () callconv(.winapi) void;

pub const D2D1_SIZE_F = extern struct { width: f32, height: f32 };
pub const D2D1_SIZE_U = extern struct { width: u32, height: u32 };
pub const D2D1_PIXEL_FORMAT = extern struct { format: u32, alpha_mode: u32 };
pub const D2D1_COLOR_F = extern struct { r: f32, g: f32, b: f32, a: f32 };
pub const D2D1_RENDER_TARGET_PROPERTIES = extern struct {
    type: u32 = 0, // D2D1_RENDER_TARGET_TYPE_DEFAULT
    pixel_format: D2D1_PIXEL_FORMAT = .{ .format = 87, .alpha_mode = 3 }, // B8G8R8A8_UNORM, IGNORE
    dpi_x: f32,
    dpi_y: f32,
    usage: u32 = 0,
    min_level: u32 = 0,
};
pub const D2D1_HWND_RENDER_TARGET_PROPERTIES = extern struct {
    hwnd: w.HWND,
    pixel_size: D2D1_SIZE_U,
    present_options: u32 = 2, // D2D1_PRESENT_OPTIONS_IMMEDIATELY
};
pub const D2DERR_RECREATE_TARGET: HRESULT = @bitCast(@as(u32, 0x8899000C));

pub const ID2D1Factory = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: Pad,
        AddRef: Pad,
        Release: *const fn (*ID2D1Factory) callconv(.winapi) u32,
        _3_13: [11]Pad, // ReloadSystemMetrics .. CreateWicBitmapRenderTarget
        CreateHwndRenderTarget: *const fn (
            *ID2D1Factory,
            *const D2D1_RENDER_TARGET_PROPERTIES,
            *const D2D1_HWND_RENDER_TARGET_PROPERTIES,
            *?*ID2D1HwndRenderTarget,
        ) callconv(.winapi) HRESULT, // 14
        CreateDxgiSurfaceRenderTarget: Pad, // 15
        CreateDCRenderTarget: Pad, // 16
    };
};

/// ID2D1HwndRenderTarget = IUnknown(0-2) + ID2D1Resource(3) +
/// ID2D1RenderTarget(4-56) + CheckWindowState(57), Resize(58), GetHwnd(59).
pub const ID2D1HwndRenderTarget = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: Pad,
        AddRef: Pad,
        Release: *const fn (*ID2D1HwndRenderTarget) callconv(.winapi) u32,
        GetFactory: Pad, // 3
        _4_46: [43]Pad, // CreateBitmap .. PopAxisAlignedClip
        Clear: *const fn (*ID2D1HwndRenderTarget, ?*const D2D1_COLOR_F) callconv(.winapi) void, // 47
        BeginDraw: *const fn (*ID2D1HwndRenderTarget) callconv(.winapi) void, // 48
        EndDraw: *const fn (*ID2D1HwndRenderTarget, ?*u64, ?*u64) callconv(.winapi) HRESULT, // 49
        // Struct returns: hidden out-pointer after `this`, returns that pointer.
        GetPixelFormat: *const fn (*ID2D1HwndRenderTarget, *D2D1_PIXEL_FORMAT) callconv(.winapi) *D2D1_PIXEL_FORMAT, // 50
        SetDpi: *const fn (*ID2D1HwndRenderTarget, f32, f32) callconv(.winapi) void, // 51
        GetDpi: *const fn (*ID2D1HwndRenderTarget, *f32, *f32) callconv(.winapi) void, // 52
        GetSize: *const fn (*ID2D1HwndRenderTarget, *D2D1_SIZE_F) callconv(.winapi) *D2D1_SIZE_F, // 53
        GetPixelSize: *const fn (*ID2D1HwndRenderTarget, *D2D1_SIZE_U) callconv(.winapi) *D2D1_SIZE_U, // 54
        GetMaximumBitmapSize: *const fn (*ID2D1HwndRenderTarget) callconv(.winapi) u32, // 55
        IsSupported: Pad, // 56
        CheckWindowState: *const fn (*ID2D1HwndRenderTarget) callconv(.winapi) u32, // 57
        Resize: *const fn (*ID2D1HwndRenderTarget, *const D2D1_SIZE_U) callconv(.winapi) HRESULT, // 58
        GetHwnd: *const fn (*ID2D1HwndRenderTarget) callconv(.winapi) w.HWND, // 59
    };

    pub fn getSize(self: *ID2D1HwndRenderTarget) D2D1_SIZE_F {
        var out: D2D1_SIZE_F = undefined;
        _ = self.vtable.GetSize(self, &out);
        return out;
    }
    pub fn getPixelSize(self: *ID2D1HwndRenderTarget) D2D1_SIZE_U {
        var out: D2D1_SIZE_U = undefined;
        _ = self.vtable.GetPixelSize(self, &out);
        return out;
    }
};

const IID_ID2D1Factory = GUID.parse("{06152247-6f50-465a-9245-118bfd3b6007}");

extern "d2d1" fn D2D1CreateFactory(t: u32, riid: *const GUID, opts: ?*const anyopaque, out: *?*anyopaque) callconv(.winapi) HRESULT;
extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?w.HWND, ?*anyopaque, ?w.HINSTANCE, ?*anyopaque) callconv(.winapi) ?w.HWND;
extern "user32" fn DestroyWindow(w.HWND) callconv(.winapi) w.BOOL;
extern "user32" fn DefWindowProcW(w.HWND, u32, w.WPARAM, w.LPARAM) callconv(.winapi) w.LRESULT;
extern "user32" fn SetProcessDpiAwarenessContext(isize) callconv(.winapi) w.BOOL;
extern "user32" fn GetDpiForWindow(w.HWND) callconv(.winapi) u32;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?w.HINSTANCE;

const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: *const fn (w.HWND, u32, w.WPARAM, w.LPARAM) callconv(.winapi) w.LRESULT,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?w.HINSTANCE,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};

fn wndProc(h: w.HWND, m: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    return DefWindowProcW(h, m, wp, lp);
}

pub fn main() !void {
    _ = SetProcessDpiAwarenessContext(-4); // PER_MONITOR_AWARE_V2
    const inst = GetModuleHandleW(null);
    const cls = std.unicode.utf8ToUtf16LeStringLiteral("S7ZigCheck");
    _ = RegisterClassExW(&.{ .lpfnWndProc = wndProc, .hInstance = inst, .lpszClassName = cls });
    // WS_POPUP, never shown: an HWND render target works on a hidden window.
    const hwnd = CreateWindowExW(0x08000080, cls, cls, 0x80000000, -32000, -32000, 300, 200, null, null, inst, null) orelse
        return error.CreateWindow;
    defer _ = DestroyWindow(hwnd);

    var fac_raw: ?*anyopaque = null;
    if (D2D1CreateFactory(0, &IID_ID2D1Factory, null, &fac_raw) != 0) return error.D2D1CreateFactory;
    const fac: *ID2D1Factory = @ptrCast(@alignCast(fac_raw.?));
    defer _ = fac.vtable.Release(fac);

    const dpi: f32 = @floatFromInt(GetDpiForWindow(hwnd));
    var rt_opt: ?*ID2D1HwndRenderTarget = null;
    const hr = fac.vtable.CreateHwndRenderTarget(
        fac,
        &.{ .dpi_x = dpi, .dpi_y = dpi },
        &.{ .hwnd = hwnd, .pixel_size = .{ .width = 300, .height = 200 } },
        &rt_opt,
    );
    if (hr != 0) return error.CreateHwndRenderTarget;
    const rt = rt_opt.?;
    defer _ = rt.vtable.Release(rt);

    rt.vtable.BeginDraw(rt);
    rt.vtable.Clear(rt, &.{ .r = 0.125, .g = 0.188, .b = 0.376, .a = 1 });
    const end_hr = rt.vtable.EndDraw(rt, null, null);

    const size = rt.getSize();
    const px = rt.getPixelSize();
    var dx: f32 = 0;
    var dy: f32 = 0;
    rt.vtable.GetDpi(rt, &dx, &dy);
    var pf: D2D1_PIXEL_FORMAT = undefined;
    _ = rt.vtable.GetPixelFormat(rt, &pf);
    const resize_hr = rt.vtable.Resize(rt, &.{ .width = 450, .height = 300 });
    const px2 = rt.getPixelSize();
    const same_hwnd = rt.vtable.GetHwnd(rt) == hwnd;

    var buf: [512]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &buf,
        "{{\"t\":\"zig_vtable_check\",\"window_dpi\":{d},\"rt_dpi\":[{d},{d}],\"GetSize_dip\":[{d:.2},{d:.2}]," ++
            "\"GetPixelSize\":[{d},{d}],\"pixel_format\":[{d},{d}],\"end_draw_hr\":\"0x{x:0>8}\"," ++
            "\"resize_hr\":\"0x{x:0>8}\",\"GetPixelSize_after_resize\":[{d},{d}],\"GetHwnd_matches\":{},\"window_state\":{d}}}\n",
        .{ dpi, dx, dy, size.width, size.height, px.width, px.height, pf.format, pf.alpha_mode, @as(u32, @bitCast(end_hr)), @as(u32, @bitCast(resize_hr)), px2.width, px2.height, same_hwnd, rt.vtable.CheckWindowState(rt) },
    );
    try std.fs.File.stdout().writeAll(line);
}
