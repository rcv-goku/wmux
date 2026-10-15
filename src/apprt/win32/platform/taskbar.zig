//! ITaskbarList3 COM binding for the taskbar-button unread-count overlay
//! (the Windows analog of cmux's dock badge). Hand-rolled vtable in the
//! same style as webview2.zig / the DirectWrite bindings: an `extern
//! struct` whose vtable matches ShObjIdl.h's MIDL layout exactly, with
//! padding entries for the methods we don't call.
//!
//! Usage: create one TaskbarList per process (lazily), HrInit() it once,
//! then call setOverlayCount(hwnd, n) to draw a numeric badge on the
//! window's taskbar button (n==0 clears it). The overlay HICON is built
//! with GDI (a small DIB + CreateIconIndirect) so no external resources
//! are needed.

const std = @import("std");
const windows = std.os.windows;
const w32 = @import("win32.zig");

const log = std.log.scoped(.taskbar);

pub const HRESULT = windows.HRESULT;
pub const S_OK: HRESULT = 0;
pub const GUID = windows.GUID;
pub const HWND = windows.HWND;

const PadFn = *const fn () callconv(.winapi) void;

// CLSID_TaskbarList and IID_ITaskbarList3, verified against ShObjIdl_core.h.
pub const CLSID_TaskbarList = GUID.parse("{56FDF344-FD6D-11d0-958A-006097C9A090}");
pub const IID_ITaskbarList3 = GUID.parse("{ea1afb91-9e28-4b86-90e9-9e9f8a5eefaf}");

// CLSCTX_INPROC_SERVER
const CLSCTX_INPROC_SERVER: u32 = 0x1;

extern "ole32" fn CoCreateInstance(
    rclsid: *const GUID,
    pUnkOuter: ?*anyopaque,
    dwClsContext: u32,
    riid: *const GUID,
    ppv: *?*anyopaque,
) callconv(.winapi) HRESULT;

/// ITaskbarList3 (inherits ITaskbarList2 ← ITaskbarList ← IUnknown). The
/// vtable order is the cumulative MIDL layout; methods we don't use are
/// `PadFn` entries with a comment naming the slot they stand in for.
pub const ITaskbarList3 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0-2)
        QueryInterface: *const fn (*const ITaskbarList3, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ITaskbarList3) callconv(.winapi) u32,
        Release: *const fn (*const ITaskbarList3) callconv(.winapi) u32,
        // ITaskbarList (3-7)
        HrInit: *const fn (*const ITaskbarList3) callconv(.winapi) HRESULT,
        AddTab: PadFn,
        DeleteTab: PadFn,
        ActivateTab: PadFn,
        SetActiveAlt: PadFn,
        // ITaskbarList2 (8)
        MarkFullscreenWindow: PadFn,
        // ITaskbarList3 (9+)
        SetProgressValue: PadFn,
        SetProgressState: PadFn,
        RegisterTab: PadFn,
        UnregisterTab: PadFn,
        SetTabOrder: PadFn,
        SetTabActive: PadFn,
        ThumbBarAddButtons: PadFn,
        ThumbBarUpdateButtons: PadFn,
        ThumbBarSetImageList: PadFn,
        SetOverlayIcon: *const fn (*const ITaskbarList3, HWND, ?w32.HICON, ?[*:0]const u16) callconv(.winapi) HRESULT,
        SetThumbnailTooltip: PadFn,
        SetThumbnailClip: PadFn,
    };

    pub fn release(self: *ITaskbarList3) void {
        _ = self.vtable.Release(self);
    }

    pub fn hrInit(self: *ITaskbarList3) HRESULT {
        return self.vtable.HrInit(self);
    }

    pub fn setOverlayIcon(self: *ITaskbarList3, hwnd: HWND, icon: ?w32.HICON, desc: ?[*:0]const u16) HRESULT {
        return self.vtable.SetOverlayIcon(self, hwnd, icon, desc);
    }
};

/// Lazily-created process-wide taskbar list. CoCreateInstance requires COM
/// to be initialized on the calling (UI) thread, which App.init already
/// does (CoInitializeEx) for WebView2; the taskbar list shares that
/// apartment. Returns null if COM isn't available (then badges are a
/// silent no-op).
pub const TaskbarList = struct {
    iface: *ITaskbarList3,

    pub fn create() ?TaskbarList {
        var ptr: ?*anyopaque = null;
        const hr = CoCreateInstance(
            &CLSID_TaskbarList,
            null,
            CLSCTX_INPROC_SERVER,
            &IID_ITaskbarList3,
            &ptr,
        );
        if (hr != S_OK or ptr == null) {
            log.warn("CoCreateInstance(TaskbarList) failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return null;
        }
        const iface: *ITaskbarList3 = @ptrCast(@alignCast(ptr.?));
        // HrInit must be called once before any other method.
        if (iface.hrInit() != S_OK) {
            log.warn("ITaskbarList3.HrInit failed", .{});
            iface.release();
            return null;
        }
        return .{ .iface = iface };
    }

    pub fn deinit(self: *TaskbarList) void {
        self.iface.release();
    }

    /// Set the unread-count overlay on `hwnd`'s taskbar button. `count==0`
    /// clears the overlay; otherwise a small badge with the count (saturated
    /// to "9+") is drawn and applied. The badge HICON is owned by the OS
    /// after SetOverlayIcon copies it, so we destroy our copy afterward.
    pub fn setOverlayCount(self: *TaskbarList, hwnd: HWND, count: usize) void {
        if (count == 0) {
            _ = self.iface.setOverlayIcon(hwnd, null, null);
            return;
        }
        const icon = buildCountIcon(count) orelse {
            // Couldn't build the badge; fall back to clearing so we never
            // leave a stale count.
            _ = self.iface.setOverlayIcon(hwnd, null, null);
            return;
        };
        defer _ = w32.DestroyIcon(icon);
        const desc = std.unicode.utf8ToUtf16LeStringLiteral("Unread notifications");
        _ = self.iface.setOverlayIcon(hwnd, icon, desc);
    }
};

/// Format the badge label for an unread count, saturating at "9+". Pure so
/// the saturation rule is unit-testable. Writes into `buf` and returns the
/// written slice.
pub fn countLabel(buf: []u8, count: usize) []const u8 {
    if (count == 0) return buf[0..0];
    if (count > 9) {
        const s = "9+";
        @memcpy(buf[0..s.len], s);
        return buf[0..s.len];
    }
    buf[0] = '0' + @as(u8, @intCast(count));
    return buf[0..1];
}

/// Build a 16x16 ARGB overlay icon showing the count as white text on an
/// amber filled circle (drawn as a filled rounded square via FillRect for
/// simplicity). Returns null on any GDI failure. Caller owns the returned
/// HICON and must DestroyIcon it.
fn buildCountIcon(count: usize) ?w32.HICON {
    const size: i32 = 16;

    const screen_dc = w32.GetDC(null) orelse return null;
    defer _ = w32.ReleaseDC(null, screen_dc);
    const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return null;
    defer _ = w32.DeleteDC(mem_dc);

    // Top-down 32-bit DIB so we can build the color bitmap for the icon.
    var bmi: w32.BITMAPINFO = .{ .bmiHeader = .{
        .biWidth = size,
        .biHeight = -size, // top-down
        .biPlanes = 1,
        .biBitCount = 32,
        .biCompression = w32.BI_RGB,
    } };
    var bits: ?*anyopaque = null;
    const dib = w32.CreateDIBSection(mem_dc, &bmi, 0, &bits, null, 0) orelse return null;
    defer _ = w32.DeleteObject(dib);

    const old_bmp = w32.SelectObject(mem_dc, dib);
    defer _ = w32.SelectObject(mem_dc, old_bmp);

    // Fill the badge background (amber, matching the sidebar bell badge).
    const bg = w32.RGB(255, 185, 0);
    var rect = w32.RECT{ .left = 0, .top = 0, .right = size, .bottom = size };
    if (w32.CreateSolidBrush(bg)) |brush| {
        _ = w32.FillRect(mem_dc, &rect, brush);
        _ = w32.DeleteObject(brush);
    }

    // Draw the count text centered in black for contrast on amber.
    _ = w32.SetBkMode(mem_dc, w32.TRANSPARENT);
    _ = w32.SetTextColor(mem_dc, w32.RGB(0, 0, 0));
    const font = w32.CreateFontW(
        13, // height
        0,
        0,
        0,
        700, // bold
        0,
        0,
        0,
        w32.DEFAULT_CHARSET,
        0,
        0,
        0,
        0,
        null,
    );
    const old_font = if (font) |f| w32.SelectObject(mem_dc, f) else null;
    defer if (font) |f| {
        _ = w32.SelectObject(mem_dc, old_font);
        _ = w32.DeleteObject(f);
    };

    var label_buf: [4]u8 = undefined;
    const label = countLabel(&label_buf, count);
    var label_w: [4]u16 = undefined;
    const wn = std.unicode.utf8ToUtf16Le(&label_w, label) catch 0;
    _ = w32.DrawTextW(
        mem_dc,
        &label_w,
        @intCast(wn),
        &rect,
        w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
    );

    // Force the DIB's alpha to opaque (FillRect/DrawText leave alpha at 0
    // in a 32-bit DIB, which the shell would render fully transparent).
    if (bits) |p| {
        const px: [*]u8 = @ptrCast(p);
        const n: usize = @intCast(size * size);
        var i: usize = 0;
        while (i < n) : (i += 1) px[i * 4 + 3] = 0xFF;
    }

    // A monochrome AND mask is required by ICONINFO even for a color icon;
    // all-zero (opaque) is fine since the color bitmap carries full alpha.
    const mask = w32.CreateBitmap(size, size, 1, 1, null) orelse return null;
    defer _ = w32.DeleteObject(mask);

    var ii: w32.ICONINFO = .{
        .fIcon = 1,
        .xHotspot = 0,
        .yHotspot = 0,
        .hbmMask = mask,
        .hbmColor = dib,
    };
    return w32.CreateIconIndirect(&ii);
}

test "taskbar: countLabel saturates at 9+" {
    const testing = std.testing;
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("", countLabel(&buf, 0));
    try testing.expectEqualStrings("1", countLabel(&buf, 1));
    try testing.expectEqualStrings("9", countLabel(&buf, 9));
    try testing.expectEqualStrings("9+", countLabel(&buf, 10));
    try testing.expectEqualStrings("9+", countLabel(&buf, 999));
}
