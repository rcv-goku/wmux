//! Brief flash overlay for the Win32 apprt: a semi-transparent colored
//! border drawn over the currently focused pane so the user can quickly
//! see which pane has focus. The flash is a one-shot effect that auto-
//! dismisses after ~200ms via a WM_TIMER on the popup's own HWND.
//!
//! Uses the same layered-popup technique as AttentionRing.zig:
//! WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE owned popup
//! sized to the pane's screen rect, painted via UpdateLayeredWindow with
//! per-pixel premultiplied alpha. Clicks pass through, and the popup
//! rides the owner's z-order.

const std = @import("std");
const w32 = @import("win32.zig");
const testing = std.testing;

/// Flash border thickness in unscaled pixels (DPI-scaled at use time).
/// Thicker than the attention ring so the flash is unmistakable.
const BORDER_BASE: i32 = 5;

/// Flash color: warm amber/yellow for visibility on any background.
const FLASH_R: u8 = 0xFF;
const FLASH_G: u8 = 0xD7;
const FLASH_B: u8 = 0x00;

/// Flash opacity (per-pixel alpha). Semi-transparent so the pane edge
/// is still partially visible.
const FLASH_ALPHA: u8 = 180;

/// Auto-dismiss delay in milliseconds.
const FLASH_DURATION_MS: u32 = 200;

/// Timer ID used on the popup's own HWND (only one timer per popup).
const FLASH_TIMER_ID: usize = 1;

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyFlashOverlay");

/// Compute the DPI-scaled border thickness, clamped to at least 3px.
pub fn borderThickness(scale: f32) i32 {
    const t: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(BORDER_BASE)) * scale));
    return @max(t, 3);
}

/// Whether pixel (x, y) in a w x h bitmap lies within the `border`-thick
/// frame band.
pub fn isBorderPixel(x: i32, y: i32, w: i32, h: i32, border: i32) bool {
    if (x < 0 or y < 0 or x >= w or y >= h) return false;
    return x < border or y < border or x >= w - border or y >= h - border;
}

pub const FlashOverlay = struct {
    alloc: std.mem.Allocator,
    owner: w32.HWND,
    hwnd: w32.HWND,
    scale: f32 = 1.0,
    visible: bool = false,

    pub fn create(
        alloc: std.mem.Allocator,
        hinstance: w32.HINSTANCE,
        owner: w32.HWND,
    ) !*FlashOverlay {
        try registerClassOnce(hinstance);

        const self = try alloc.create(FlashOverlay);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .owner = owner, .hwnd = undefined };

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
            1,
            owner,
            null,
            hinstance,
            null,
        ) orelse return error.Win32Error;
        errdefer _ = w32.DestroyWindow(hwnd);

        // Store self pointer for the WndProc timer callback.
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

        self.hwnd = hwnd;
        return self;
    }

    pub fn destroy(self: *FlashOverlay) void {
        _ = w32.KillTimer(self.hwnd, FLASH_TIMER_ID);
        _ = w32.DestroyWindow(self.hwnd);
        self.alloc.destroy(self);
    }

    pub fn setScale(self: *FlashOverlay, scale: f32) void {
        self.scale = scale;
    }

    pub fn hide(self: *FlashOverlay) void {
        if (!self.visible) return;
        _ = w32.KillTimer(self.hwnd, FLASH_TIMER_ID);
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        self.visible = false;
    }

    /// Show the flash overlay around the given screen rect, then start
    /// the auto-dismiss timer. If already visible (rapid re-trigger),
    /// the timer is reset.
    pub fn flash(self: *FlashOverlay, pane_screen: w32.RECT) void {
        const fw = pane_screen.right - pane_screen.left;
        const fh = pane_screen.bottom - pane_screen.top;
        if (fw <= 0 or fh <= 0) return;

        _ = w32.SetWindowPos(
            self.hwnd,
            null,
            pane_screen.left,
            pane_screen.top,
            fw,
            fh,
            w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_SHOWWINDOW,
        );
        self.visible = true;
        self.repaint(fw, fh);

        // (Re-)arm the auto-dismiss timer on the popup's own HWND.
        _ = w32.SetTimer(self.hwnd, FLASH_TIMER_ID, FLASH_DURATION_MS, null);
    }

    fn repaint(self: *FlashOverlay, w: i32, h: i32) void {
        if (w <= 0 or h <= 0) return;

        const screen_dc = w32.GetDC(null) orelse return;
        defer _ = w32.ReleaseDC(null, screen_dc);

        const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return;
        defer _ = w32.DeleteDC(mem_dc);

        var bits: ?*anyopaque = null;
        const bmi = w32.BITMAPINFO{
            .bmiHeader = .{
                .biWidth = w,
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
        const blend = w32.BLENDFUNCTION{ .SourceConstantAlpha = 255 };

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

    fn drawBitmap(self: *FlashOverlay, pixels: [*]u32, w: i32, h: i32) void {
        const border = borderThickness(self.scale);
        const color = packBGRA(FLASH_R, FLASH_G, FLASH_B, FLASH_ALPHA);
        const total = w * h;
        var i: i32 = 0;
        while (i < total) : (i += 1) {
            const x = @mod(i, w);
            const y = @divFloor(i, w);
            pixels[@intCast(i)] = if (isBorderPixel(x, y, w, h, border)) color else 0;
        }
    }
};

/// Pack RGB + alpha into premultiplied BGRA.
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
        .lpfnWndProc = flashWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn flashWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,
        w32.WM_TIMER => {
            if (wparam == FLASH_TIMER_ID) {
                _ = w32.KillTimer(hwnd, FLASH_TIMER_ID);
                _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
                // Mark as not visible on the struct.
                const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
                if (userdata != 0) {
                    const self: *FlashOverlay = @ptrFromInt(@as(usize, @bitCast(userdata)));
                    self.visible = false;
                }
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "unit: borderThickness scales and floors at 3" {
    try testing.expectEqual(@as(i32, 5), borderThickness(1.0));
    try testing.expectEqual(@as(i32, 6), borderThickness(1.25));
    try testing.expectEqual(@as(i32, 10), borderThickness(2.0));
    try testing.expectEqual(@as(i32, 3), borderThickness(0.5));
    try testing.expectEqual(@as(i32, 3), borderThickness(0.1));
}

test "unit: isBorderPixel marks the frame band only" {
    const w = 10;
    const h = 8;
    const b = 3;
    try testing.expect(isBorderPixel(0, 0, w, h, b));
    try testing.expect(isBorderPixel(9, 7, w, h, b));
    try testing.expect(isBorderPixel(2, 5, w, h, b));
    try testing.expect(!isBorderPixel(3, 3, w, h, b));
    try testing.expect(!isBorderPixel(6, 4, w, h, b));
    try testing.expect(!isBorderPixel(-1, 0, w, h, b));
}

test "unit: packBGRA premultiplies correctly" {
    const opaque_color = packBGRA(0xFF, 0xD7, 0x00, 0xFF);
    try testing.expectEqual(@as(u32, 0xFFFFD700), opaque_color);
    try testing.expectEqual(@as(u32, 0), packBGRA(0xFF, 0xD7, 0x00, 0));
}
