//! Notification-ring overlay for the Win32 apprt: a thin blue border
//! drawn around a terminal pane that is flagged for attention (an agent
//! is waiting) but is NOT the currently focused/visible-active pane.
//!
//! Panes are GL/child HWNDs that fully cover their rect, so a GDI border
//! painted on the parent window would be occluded. We use the same
//! layered-popup technique as Scrollbar.zig: a WS_EX_LAYERED |
//! WS_EX_TRANSPARENT | WS_EX_NOACTIVATE owned popup sized to the pane's
//! screen rect, painted via UpdateLayeredWindow with per-pixel
//! premultiplied alpha. Only the border band is opaque; the interior is
//! fully transparent so the terminal shows through and clicks pass to it
//! (WS_EX_TRANSPARENT). The popup is owned by the window so it follows in
//! z-order and never appears in the taskbar / Alt-Tab.
//!
//! One ring is created per (workspace, tab, pane) that needs one, on
//! demand; Window keeps a small pool keyed by the target Surface and
//! repositions/hides them as the layout changes. The ring carries no
//! state of its own beyond its HWND and last geometry — the "should this
//! pane be ringed" decision lives in Window.updateAttentionRings.

const std = @import("std");
const w32 = @import("win32.zig");
const Surface = @import("Surface.zig");
const testing = std.testing;

/// Ring border thickness in unscaled pixels (DPI-scaled at use time).
/// 3 reads clearly without crowding the cell grid.
const BORDER_BASE: i32 = 3;

/// Accent blue, matching the tab-bar/sidebar accent (RGB 0x3D8EF8).
const RING_R: u8 = 0x3D;
const RING_G: u8 = 0x8E;
const RING_B: u8 = 0xF8;

/// Ring opacity (per-pixel alpha). High enough to read over any
/// background without fully hiding the pane edge underneath.
const RING_ALPHA: u8 = 235;

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyAttentionRing");

/// Compute the DPI-scaled border thickness, clamped to at least 2px so
/// the ring is always visible even at 1.0 scale rounding.
pub fn borderThickness(scale: f32) i32 {
    const t: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(BORDER_BASE)) * scale));
    return @max(t, 2);
}

/// Whether pixel (x, y) in a w×h bitmap lies within the `border`-thick
/// frame band (the part the ring paints). Pure so the frame geometry is
/// unit-testable independent of GDI.
pub fn isBorderPixel(x: i32, y: i32, w: i32, h: i32, border: i32) bool {
    if (x < 0 or y < 0 or x >= w or y >= h) return false;
    return x < border or y < border or x >= w - border or y >= h - border;
}

pub const AttentionRing = struct {
    alloc: std.mem.Allocator,
    /// The owning top-level window (popups are owned, not parented, so
    /// they ride the owner's z-order without clipping to it).
    owner: w32.HWND,
    hwnd: w32.HWND,
    /// DPI scale of the owner (1.0 at 96 DPI).
    scale: f32 = 1.0,
    /// Whether the popup is currently shown.
    visible: bool = false,

    pub fn create(
        alloc: std.mem.Allocator,
        hinstance: w32.HINSTANCE,
        owner: w32.HWND,
    ) !*AttentionRing {
        try registerClassOnce(hinstance);

        const self = try alloc.create(AttentionRing);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .owner = owner, .hwnd = undefined };

        // WS_EX_LAYERED — DWM-composited above the OpenGL pane.
        // WS_EX_TRANSPARENT — clicks fall through to the terminal under it.
        // WS_EX_NOACTIVATE — never steals focus.
        // WS_EX_TOOLWINDOW — out of the taskbar / Alt-Tab list.
        const ex_style: u32 = w32.WS_EX_LAYERED | w32.WS_EX_TRANSPARENT |
            w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW;
        const style: u32 = w32.WS_POPUP;

        const hwnd = w32.CreateWindowExW(
            ex_style,
            WINDOW_CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            style,
            0,
            0,
            1,
            1, // placeholder; positionAround sets the real rect
            owner,
            null,
            hinstance,
            null,
        ) orelse return error.Win32Error;
        errdefer _ = w32.DestroyWindow(hwnd);

        self.hwnd = hwnd;
        return self;
    }

    pub fn destroy(self: *AttentionRing) void {
        _ = w32.DestroyWindow(self.hwnd);
        self.alloc.destroy(self);
    }

    pub fn setScale(self: *AttentionRing, scale: f32) void {
        self.scale = scale;
    }

    /// Hide the ring (no pane needs it right now).
    pub fn hide(self: *AttentionRing) void {
        if (!self.visible) return;
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        self.visible = false;
    }

    /// Position the ring so its border frames the pane whose client rect
    /// is `pane_screen` (already in screen coordinates), then paint and
    /// show it. The popup exactly overlaps the pane; the border band is
    /// drawn just inside the pane edges.
    pub fn positionAround(self: *AttentionRing, pane_screen: w32.RECT) void {
        const w = pane_screen.right - pane_screen.left;
        const h = pane_screen.bottom - pane_screen.top;
        if (w <= 0 or h <= 0) {
            self.hide();
            return;
        }

        _ = w32.SetWindowPos(
            self.hwnd,
            null,
            pane_screen.left,
            pane_screen.top,
            w,
            h,
            w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_SHOWWINDOW,
        );
        self.visible = true;
        self.repaint(w, h);
    }

    fn repaint(self: *AttentionRing, w: i32, h: i32) void {
        if (w <= 0 or h <= 0) return;

        const screen_dc = w32.GetDC(null) orelse return;
        defer _ = w32.ReleaseDC(null, screen_dc);

        const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return;
        defer _ = w32.DeleteDC(mem_dc);

        var bits: ?*anyopaque = null;
        const bmi = w32.BITMAPINFO{
            .bmiHeader = .{
                .biWidth = w,
                // Negative height → top-down DIB so row 0 is the top.
                .biHeight = -h,
            },
        };
        const bitmap = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return;
        defer _ = w32.DeleteObject(bitmap);

        const old = w32.SelectObject(mem_dc, bitmap);
        defer _ = w32.SelectObject(mem_dc, old.?);

        self.drawBitmap(@ptrCast(@alignCast(bits.?)), w, h);

        var window_rect: w32.RECT = undefined;
        _ = w32.GetWindowRect(self.hwnd, &window_rect);
        const dst_pt = w32.POINT{ .x = window_rect.left, .y = window_rect.top };
        const dst_size = w32.SIZE{ .cx = w, .cy = h };
        const src_pt = w32.POINT{ .x = 0, .y = 0 };
        const blend = w32.BLENDFUNCTION{ .SourceConstantAlpha = 255 }; // per-pixel alpha only

        _ = w32.UpdateLayeredWindow(
            self.hwnd,
            screen_dc,
            &dst_pt,
            &dst_size,
            mem_dc,
            &src_pt,
            0,
            &blend,
            w32.ULW_ALPHA,
        );
    }

    fn drawBitmap(self: *AttentionRing, pixels: [*]u32, w: i32, h: i32) void {
        const border = borderThickness(self.scale);
        const ring = packBGRA(RING_R, RING_G, RING_B, RING_ALPHA);
        const total = w * h;
        var i: i32 = 0;
        while (i < total) : (i += 1) {
            const x = @mod(i, w);
            const y = @divFloor(i, w);
            pixels[@intCast(i)] = if (isBorderPixel(x, y, w, h, border)) ring else 0;
        }
    }
};

/// Pack RGB + alpha into premultiplied BGRA (UpdateLayeredWindow expects
/// premultiplied per-pixel alpha). Layout per pixel: 0xAARRGGBB.
fn packBGRA(r: u8, g: u8, b: u8, a: u8) u32 {
    const af: f32 = @as(f32, @floatFromInt(a)) / 255.0;
    const pr: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(r)) * af));
    const pg: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(g)) * af));
    const pb: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(b)) * af));
    return (@as(u32, a) << 24) | (pr << 16) | (pg << 8) | pb;
}

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = ringWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null, // painted via UpdateLayeredWindow
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn ringWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    switch (msg) {
        // Belt-and-suspenders with WS_EX_TRANSPARENT: never activate.
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "unit: borderThickness scales and floors at 2" {
    try testing.expectEqual(@as(i32, 3), borderThickness(1.0));
    try testing.expectEqual(@as(i32, 4), borderThickness(1.25)); // round(3.75)
    try testing.expectEqual(@as(i32, 6), borderThickness(2.0));
    // Never below 2 even at sub-1.0 rounding.
    try testing.expectEqual(@as(i32, 2), borderThickness(0.5)); // round(1.5)=2
    try testing.expectEqual(@as(i32, 2), borderThickness(0.1)); // floor would be 0 → clamp 2
}

test "unit: isBorderPixel marks the frame band only" {
    const w = 10;
    const h = 8;
    const b = 2;
    // Corners are border.
    try testing.expect(isBorderPixel(0, 0, w, h, b));
    try testing.expect(isBorderPixel(9, 7, w, h, b));
    // First two rows/cols are border.
    try testing.expect(isBorderPixel(1, 5, w, h, b)); // left band
    try testing.expect(isBorderPixel(5, 1, w, h, b)); // top band
    try testing.expect(isBorderPixel(8, 4, w, h, b)); // right band (>= w-b=8)
    try testing.expect(isBorderPixel(4, 6, w, h, b)); // bottom band (>= h-b=6)
    // Interior is NOT border.
    try testing.expect(!isBorderPixel(2, 2, w, h, b));
    try testing.expect(!isBorderPixel(7, 5, w, h, b));
    try testing.expect(!isBorderPixel(5, 4, w, h, b));
    // Out of bounds is never border.
    try testing.expect(!isBorderPixel(-1, 0, w, h, b));
    try testing.expect(!isBorderPixel(0, h, w, h, b));
}

test "unit: packBGRA premultiplies and is opaque at full alpha" {
    // Full alpha → channels unchanged, top byte 0xFF.
    const opaque_blue = packBGRA(0x3D, 0x8E, 0xF8, 0xFF);
    try testing.expectEqual(@as(u32, 0xFF3D8EF8), opaque_blue);
    // Zero alpha → fully transparent black.
    try testing.expectEqual(@as(u32, 0), packBGRA(0x3D, 0x8E, 0xF8, 0));
}
