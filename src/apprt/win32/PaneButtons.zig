//! Per-pane top-right corner action buttons for the Win32 apprt: a small
//! cluster of clickable icons shown in the top-right corner of EVERY pane,
//! always visible (the hovered button is highlighted; hovering is not
//! required to reveal the cluster). The set mirrors cmux's per-pane
//! (Bonsplit) action buttons exactly: New Terminal, New Browser, Split
//! Right, Split Down — drawn to resemble cmux's SF Symbols `terminal`,
//! `globe`, `square.split.2x1`, `square.split.1x2`.
//!
//! Like AttentionRing/Scrollbar, panes are GL/WebView2 child HWNDs that
//! fully cover their rect, so GDI painted on the parent window would be
//! occluded. We use the same layered-popup technique: a WS_EX_LAYERED |
//! WS_EX_NOACTIVATE owned popup positioned over the pane's top-right
//! corner, painted via UpdateLayeredWindow with per-pixel premultiplied
//! alpha. Unlike the ring, this overlay must receive clicks, so it OMITS
//! WS_EX_TRANSPARENT (the Scrollbar model) and carries a real WndProc
//! handling WM_MOUSEMOVE/WM_MOUSELEAVE/WM_LBUTTONDOWN plus
//! WM_MOUSEACTIVATE -> MA_NOACTIVATE so a click never steals focus.
//!
//! One overlay is created per qualifying pane on demand; Window keeps a
//! pool (pane_buttons) and repositions/hides them as the layout changes
//! (updatePaneButtons, mirroring updateAttentionRings). The overlay
//! carries only its HWND, geometry, target Pane pointer, owning Window
//! pointer, and hover index — the "which pane gets a cluster" decision
//! lives in Window.updatePaneButtons. The pure geometry/hit-test helpers
//! (clusterWidth/clusterHeight/buttonRectAt/hitTest) are unit-tested
//! independent of GDI.

const std = @import("std");
const w32 = @import("win32.zig");
const Pane = @import("Pane.zig");
const testing = std.testing;

const log = std.log.scoped(.win32_pane_buttons);

/// Number of icon buttons in the cluster, left -> right:
/// 0 New Terminal, 1 New Browser, 2 Split Right, 3 Split Down.
pub const BUTTON_COUNT: usize = 4;

/// Per-button square size in unscaled pixels (DPI-scaled at use time).
const BTN_BASE: i32 = 20;
/// Gap between buttons in unscaled pixels.
const GAP_BASE: i32 = 4;
/// Inset of the cluster from the pane's top/right edge in unscaled pixels.
const PAD_BASE: i32 = 4;

/// Cluster background (a translucent dark rounded plate behind the icons
/// so they read over any terminal content). Premultiplied at paint time.
const PLATE_R: u8 = 0x20;
const PLATE_G: u8 = 0x20;
const PLATE_B: u8 = 0x20;
const PLATE_ALPHA: u8 = 210;

/// Hovered-button highlight (lighter plate behind the single hot icon).
const HOVER_R: u8 = 0x3D;
const HOVER_G: u8 = 0x8E;
const HOVER_B: u8 = 0xF8;
const HOVER_ALPHA: u8 = 235;

/// Icon stroke color (the glyph lines), fully opaque.
const ICON_R: u8 = 0xE6;
const ICON_G: u8 = 0xE6;
const ICON_B: u8 = 0xE6;

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyPaneButtons");

/// The action a clicked button maps to. Pure enum so the hit-test result
/// is testable; Window routes each to the corresponding pane operation.
/// Order + meaning mirror cmux's per-pane Bonsplit action buttons.
pub const Action = enum(usize) {
    new_terminal = 0,
    new_browser = 1,
    split_right = 2,
    split_down = 3,
};

/// DPI-scaled value of an unscaled base constant.
fn scaled(base: i32, scale: f32) i32 {
    const v: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(base)) * scale));
    return @max(v, 1);
}

/// Total cluster width in DPI-scaled pixels: N buttons + (N-1) gaps.
pub fn clusterWidth(scale: f32) i32 {
    const btn = scaled(BTN_BASE, scale);
    const gap = scaled(GAP_BASE, scale);
    return @as(i32, @intCast(BUTTON_COUNT)) * btn + (@as(i32, @intCast(BUTTON_COUNT)) - 1) * gap;
}

/// Total cluster height in DPI-scaled pixels (one button tall).
pub fn clusterHeight(scale: f32) i32 {
    return scaled(BTN_BASE, scale);
}

/// Rect of button `index` within the cluster's own client area (origin
/// 0,0 = cluster top-left). Pure for unit testing.
pub fn buttonRectAt(index: usize, scale: f32) w32.RECT {
    const btn = scaled(BTN_BASE, scale);
    const gap = scaled(GAP_BASE, scale);
    const left = @as(i32, @intCast(index)) * (btn + gap);
    return .{ .left = left, .top = 0, .right = left + btn, .bottom = btn };
}

/// Map a point in the cluster's client area to the button index it hits,
/// or null if it lands in a gap / outside. Pure for unit testing.
pub fn hitTest(x: i32, y: i32, scale: f32) ?usize {
    const btn = scaled(BTN_BASE, scale);
    if (y < 0 or y >= btn) return null;
    var i: usize = 0;
    while (i < BUTTON_COUNT) : (i += 1) {
        const r = buttonRectAt(i, scale);
        if (x >= r.left and x < r.right) return i;
    }
    return null;
}

pub const PaneButtons = struct {
    alloc: std.mem.Allocator,
    /// The owning top-level window (popups are owned, not parented).
    owner: w32.HWND,
    hwnd: w32.HWND,
    /// DPI scale of the owner (1.0 at 96 DPI).
    scale: f32 = 1.0,
    /// Whether the popup is currently shown.
    visible: bool = false,
    /// The pane this cluster acts on. Validated by address (Window.findLoc)
    /// before any action runs, so a stale pointer is a safe no-op.
    pane: ?*Pane = null,
    /// Back-pointer to the owning Window, set by Window so the WndProc can
    /// route clicks. Opaque to avoid an import cycle (Window imports us).
    window: ?*anyopaque = null,
    /// Index of the currently hovered button, or null. Drives the
    /// per-button highlight.
    hover: ?usize = null,
    /// Whether WM_MOUSELEAVE tracking is active.
    tracking: bool = false,

    pub fn create(
        alloc: std.mem.Allocator,
        hinstance: w32.HINSTANCE,
        owner: w32.HWND,
    ) !*PaneButtons {
        try registerClassOnce(hinstance);

        const self = try alloc.create(PaneButtons);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .owner = owner, .hwnd = undefined };

        // WS_EX_LAYERED — DWM-composited above the OpenGL/WebView2 pane.
        // (No WS_EX_TRANSPARENT: we need clicks.)
        // WS_EX_NOACTIVATE — clicking us never steals focus.
        // WS_EX_TOOLWINDOW — out of the taskbar / Alt-Tab list.
        const ex_style: u32 = w32.WS_EX_LAYERED | w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW;
        const style: u32 = w32.WS_POPUP;

        const hwnd = w32.CreateWindowExW(
            ex_style,
            WINDOW_CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            style,
            0,
            0,
            1,
            1, // placeholder; positionAt sets the real rect
            owner,
            null,
            hinstance,
            null,
        ) orelse return error.Win32Error;
        errdefer _ = w32.DestroyWindow(hwnd);

        // Stash self pointer so the WndProc can find us.
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

        self.hwnd = hwnd;
        return self;
    }

    pub fn destroy(self: *PaneButtons) void {
        _ = w32.DestroyWindow(self.hwnd);
        self.alloc.destroy(self);
    }

    pub fn setScale(self: *PaneButtons, scale: f32) void {
        self.scale = scale;
    }

    /// Hide the overlay (no pane needs it right now).
    pub fn hide(self: *PaneButtons) void {
        if (!self.visible) return;
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        self.visible = false;
        self.hover = null;
    }

    /// Position the cluster at the top-right of the pane whose client rect
    /// is `pane_screen` (already in screen coordinates), bind it to `pane`
    /// + `window`, then paint and show it. The cluster is inset from the
    /// pane's top/right edges by a DPI-scaled pad.
    pub fn positionAt(
        self: *PaneButtons,
        pane_screen: w32.RECT,
        pane: *Pane,
        window: *anyopaque,
    ) void {
        const w = clusterWidth(self.scale);
        const h = clusterHeight(self.scale);
        const pad = scaled(PAD_BASE, self.scale);

        const pane_w = pane_screen.right - pane_screen.left;
        const pane_h = pane_screen.bottom - pane_screen.top;
        // Don't show on a pane too small to fit the cluster + pad.
        if (pane_w <= w + 2 * pad or pane_h <= h + 2 * pad) {
            self.hide();
            return;
        }

        self.pane = pane;
        self.window = window;

        const left = pane_screen.right - pad - w;
        const top = pane_screen.top + pad;

        // hWndInsertAfter = null (HWND_TOP) and NO SWP_NOZORDER: bring the
        // clickable cluster to the TOP of the owner's z-order each pass so
        // it is never occluded by the GL/WebView2 child or a ring popup at
        // the shared top-right corner. NOACTIVATE keeps focus on the
        // terminal.
        _ = w32.SetWindowPos(
            self.hwnd,
            null,
            left,
            top,
            w,
            h,
            w32.SWP_NOACTIVATE | w32.SWP_SHOWWINDOW,
        );
        self.visible = true;
        self.repaint(w, h);
    }

    fn ensureLeaveTracking(self: *PaneButtons) void {
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.hwnd,
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
        self.tracking = true;
    }

    fn onMouseMove(self: *PaneButtons, x: i32, y: i32) void {
        self.ensureLeaveTracking();
        const new_hover = hitTest(x, y, self.scale);
        if (new_hover != self.hover) {
            self.hover = new_hover;
            if (self.visible) {
                var client: w32.RECT = undefined;
                if (w32.GetClientRect(self.hwnd, &client) != 0) {
                    self.repaint(client.right - client.left, client.bottom - client.top);
                }
            }
        }
    }

    fn onMouseLeave(self: *PaneButtons) void {
        self.tracking = false;
        if (self.hover != null) {
            self.hover = null;
            if (self.visible) {
                var client: w32.RECT = undefined;
                if (w32.GetClientRect(self.hwnd, &client) != 0) {
                    self.repaint(client.right - client.left, client.bottom - client.top);
                }
            }
        }
    }

    fn repaint(self: *PaneButtons, w: i32, h: i32) void {
        if (w <= 0 or h <= 0) return;

        const screen_dc = w32.GetDC(null) orelse return;
        defer _ = w32.ReleaseDC(null, screen_dc);

        const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return;
        defer _ = w32.DeleteDC(mem_dc);

        var bits: ?*anyopaque = null;
        const bmi = w32.BITMAPINFO{
            .bmiHeader = .{
                .biWidth = w,
                // Negative height -> top-down DIB so row 0 is the top.
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

    fn drawBitmap(self: *PaneButtons, pixels: [*]u32, w: i32, h: i32) void {
        // Start fully transparent.
        const total = w * h;
        var i: i32 = 0;
        while (i < total) : (i += 1) pixels[@intCast(i)] = 0;

        var b: usize = 0;
        while (b < BUTTON_COUNT) : (b += 1) {
            const r = buttonRectAt(b, self.scale);
            const hot = (self.hover == b);
            const plate = if (hot)
                packBGRA(HOVER_R, HOVER_G, HOVER_B, HOVER_ALPHA)
            else
                packBGRA(PLATE_R, PLATE_G, PLATE_B, PLATE_ALPHA);
            fillRect(pixels, w, h, r, plate);
            const stroke = packBGRA(ICON_R, ICON_G, ICON_B, 255);
            self.drawGlyph(pixels, w, h, r, @enumFromInt(b), stroke);
        }
    }

    /// Draw the glyph for `action` inside button rect `r` using simple
    /// pixel shapes (no GDI text), so every icon is crisp at any DPI and
    /// carries zero tofu risk. Each shape mirrors the corresponding cmux
    /// SF Symbol: `terminal`, `globe`, `square.split.2x1`, `square.split.1x2`.
    fn drawGlyph(self: *PaneButtons, pixels: [*]u32, w: i32, h: i32, r: w32.RECT, action: Action, color: u32) void {
        const t = @max(scaled(2, self.scale), 1); // stroke thickness (bold)
        const thin = @max(@divFloor(t, 2), 1); // outline/divider thickness
        const inset = scaled(4, self.scale); // glyph inset from button edge
        const gx0 = r.left + inset;
        const gy0 = r.top + inset;
        const gx1 = r.right - inset;
        const gy1 = r.bottom - inset;
        if (gx1 <= gx0 or gy1 <= gy0) return;
        const cx = @divFloor(gx0 + gx1, 2);
        const cy = @divFloor(gy0 + gy1, 2);

        switch (action) {
            .new_terminal => {
                // cmux `terminal`: a ">" command prompt and an "_" cursor.
                // Drawn without the enclosing rounded square (it reads as a
                // terminal from the chevron alone and stays legible at small
                // sizes; the square would crowd the glyph).
                const pad = scaled(2, self.scale);
                // ">" chevron: top-left -> center, then center -> bottom-left.
                diag(pixels, w, h, gx0 + pad, gy0 + pad, cx, cy, t, color);
                diag(pixels, w, h, cx, cy, gx0 + pad, gy1 - pad, t, color);
                // "_" underscore (cursor) along the bottom, right of center.
                hLine(pixels, w, h, cx, gx1 - pad, gy1 - pad, t, color);
            },
            .new_browser => {
                // cmux `globe`: a round circle crossed by a vertical meridian
                // and a horizontal equator. Drawn as an actual circle (not a
                // square) so it is unmistakably a globe and distinct from the
                // square split glyphs.
                const radius = @divFloor(@min(gx1 - gx0, gy1 - gy0), 2);
                strokeCircle(pixels, w, h, cx, cy, radius, thin, color);
                vLine(pixels, w, h, cx, cy - radius, cy + radius, thin, color);
                hLine(pixels, w, h, cx - radius, cx + radius, cy, thin, color);
            },
            .split_right => {
                // cmux `square.split.2x1`: a square split into two COLUMNS
                // (a vertical divider down the middle).
                drawBox(pixels, w, h, gx0, gy0, gx1, gy1, thin, color);
                vLine(pixels, w, h, cx, gy0, gy1, thin, color);
            },
            .split_down => {
                // cmux `square.split.1x2`: a square split into two ROWS
                // (a horizontal divider across the middle).
                drawBox(pixels, w, h, gx0, gy0, gx1, gy1, thin, color);
                hLine(pixels, w, h, gx0, gx1, cy, thin, color);
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Pixel drawing helpers (pure, operate on the premultiplied BGRA buffer)
// ---------------------------------------------------------------------------

fn putPixel(pixels: [*]u32, w: i32, h: i32, x: i32, y: i32, color: u32) void {
    if (x < 0 or y < 0 or x >= w or y >= h) return;
    pixels[@intCast(y * w + x)] = color;
}

fn fillRect(pixels: [*]u32, w: i32, h: i32, r: w32.RECT, color: u32) void {
    var y = @max(r.top, 0);
    const y_end = @min(r.bottom, h);
    while (y < y_end) : (y += 1) {
        var x = @max(r.left, 0);
        const x_end = @min(r.right, w);
        while (x < x_end) : (x += 1) {
            pixels[@intCast(y * w + x)] = color;
        }
    }
}

/// Horizontal bar of thickness `t` centered on row `y`, spanning [x0, x1).
fn hLine(pixels: [*]u32, w: i32, h: i32, x0: i32, x1: i32, y: i32, t: i32, color: u32) void {
    var dy: i32 = 0;
    while (dy < t) : (dy += 1) {
        var x = x0;
        while (x < x1) : (x += 1) putPixel(pixels, w, h, x, y + dy, color);
    }
}

/// Vertical bar of thickness `t` starting at column `x`, spanning [y0, y1).
fn vLine(pixels: [*]u32, w: i32, h: i32, x: i32, y0: i32, y1: i32, t: i32, color: u32) void {
    var dx: i32 = 0;
    while (dx < t) : (dx += 1) {
        var y = y0;
        while (y < y1) : (y += 1) putPixel(pixels, w, h, x + dx, y, color);
    }
}

/// Outline a rectangle [x0,x1) x [y0,y1) with a border of thickness `t`.
/// Used for the two split-square glyphs.
fn drawBox(pixels: [*]u32, w: i32, h: i32, x0: i32, y0: i32, x1: i32, y1: i32, t: i32, color: u32) void {
    hLine(pixels, w, h, x0, x1, y0, t, color); // top
    hLine(pixels, w, h, x0, x1, y1 - t, t, color); // bottom
    vLine(pixels, w, h, x0, y0, y1, t, color); // left
    vLine(pixels, w, h, x1 - t, y0, y1, t, color); // right
}

/// One-pixel midpoint circle centered at (cx,cy). Plots the 8 octant
/// symmetric points each step.
fn midpointCircle(pixels: [*]u32, w: i32, h: i32, cx: i32, cy: i32, radius: i32, color: u32) void {
    if (radius <= 0) return;
    var x: i32 = radius;
    var y: i32 = 0;
    var err: i32 = 1 - radius;
    while (x >= y) {
        putPixel(pixels, w, h, cx + x, cy + y, color);
        putPixel(pixels, w, h, cx - x, cy + y, color);
        putPixel(pixels, w, h, cx + x, cy - y, color);
        putPixel(pixels, w, h, cx - x, cy - y, color);
        putPixel(pixels, w, h, cx + y, cy + x, color);
        putPixel(pixels, w, h, cx - y, cy + x, color);
        putPixel(pixels, w, h, cx + y, cy - x, color);
        putPixel(pixels, w, h, cx - y, cy - x, color);
        y += 1;
        if (err < 0) {
            err += 2 * y + 1;
        } else {
            x -= 1;
            err += 2 * (y - x) + 1;
        }
    }
}

/// Stroke a circle of thickness `t` (t concentric midpoint circles) — the
/// globe outline for the New Browser glyph.
fn strokeCircle(pixels: [*]u32, w: i32, h: i32, cx: i32, cy: i32, radius: i32, t: i32, color: u32) void {
    var k: i32 = 0;
    while (k < t) : (k += 1) midpointCircle(pixels, w, h, cx, cy, radius - k, color);
}

/// Anti-alias-free diagonal line from (x0,y0) to (x1,y1) with a square
/// brush of size `t` (Bresenham-ish). Used for the terminal ">" chevron.
fn diag(pixels: [*]u32, w: i32, h: i32, x0: i32, y0: i32, x1: i32, y1: i32, t: i32, color: u32) void {
    const steps = @max(@abs(x1 - x0), @abs(y1 - y0));
    if (steps == 0) return;
    var s: i32 = 0;
    while (s <= steps) : (s += 1) {
        const fx = @as(f32, @floatFromInt(x0)) + @as(f32, @floatFromInt(x1 - x0)) * @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
        const fy = @as(f32, @floatFromInt(y0)) + @as(f32, @floatFromInt(y1 - y0)) * @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
        const px: i32 = @intFromFloat(@round(fx));
        const py: i32 = @intFromFloat(@round(fy));
        var dy: i32 = 0;
        while (dy < t) : (dy += 1) {
            var dx: i32 = 0;
            while (dx < t) : (dx += 1) putPixel(pixels, w, h, px + dx, py + dy, color);
        }
    }
}

/// Pack RGB + alpha into premultiplied BGRA. Layout per pixel: 0xAARRGGBB.
fn packBGRA(r: u8, g: u8, b: u8, a: u8) u32 {
    const af: f32 = @as(f32, @floatFromInt(a)) / 255.0;
    const pr: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(r)) * af));
    const pg: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(g)) * af));
    const pb: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(b)) * af));
    return (@as(u32, a) << 24) | (pr << 16) | (pg << 8) | pb;
}

// ---------------------------------------------------------------------------
// Window class + WndProc
// ---------------------------------------------------------------------------

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = paneButtonsWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_HAND),
        .hbrBackground = null, // painted via UpdateLayeredWindow
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

/// Window.onPaneButtonClick has this signature; declared here as a fn
/// pointer type so the WndProc can call back into Window without an
/// import cycle. Window casts its *anyopaque self back to *Window.
pub const ClickFn = *const fn (window: *anyopaque, pane: *Pane, action: Action) void;

/// Set by Window at startup so the overlay WndProc can route clicks.
pub var on_click: ?ClickFn = null;

fn loword(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) & 0xFFFF))));
}

fn hiword(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate((@as(usize, @bitCast(lparam)) >> 16) & 0xFFFF))));
}

fn paneButtonsWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*PaneButtons = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    const self = self_opt orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        // Never activate: clicking the cluster keeps the terminal focused.
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,

        w32.WM_MOUSEMOVE => {
            self.onMouseMove(loword(lparam), hiword(lparam));
            return 0;
        },

        w32.WM_MOUSELEAVE => {
            self.onMouseLeave();
            return 0;
        },

        w32.WM_LBUTTONDOWN => {
            const x = loword(lparam);
            const y = hiword(lparam);
            if (hitTest(x, y, self.scale)) |idx| {
                if (self.pane) |pane| {
                    if (self.window) |window| {
                        if (on_click) |cb| cb(window, pane, @enumFromInt(idx));
                    }
                }
            }
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "unit: clusterWidth = N buttons + (N-1) gaps" {
    // At scale 1.0: btn=20, gap=4 -> 4*20 + 3*4 = 92.
    try testing.expectEqual(@as(i32, 92), clusterWidth(1.0));
    try testing.expectEqual(@as(i32, 20), clusterHeight(1.0));
}

test "unit: buttonRectAt strides by btn+gap" {
    const r0 = buttonRectAt(0, 1.0);
    try testing.expectEqual(@as(i32, 0), r0.left);
    try testing.expectEqual(@as(i32, 20), r0.right);
    const r1 = buttonRectAt(1, 1.0);
    try testing.expectEqual(@as(i32, 24), r1.left); // 20 + 4
    try testing.expectEqual(@as(i32, 44), r1.right);
    const r3 = buttonRectAt(3, 1.0);
    try testing.expectEqual(@as(i32, 72), r3.left); // 3*(20+4)
    try testing.expectEqual(@as(i32, 92), r3.right);
}

test "unit: hitTest maps x into the right button, gaps are misses" {
    // Inside button 0.
    try testing.expectEqual(@as(?usize, 0), hitTest(0, 0, 1.0));
    try testing.expectEqual(@as(?usize, 0), hitTest(19, 19, 1.0));
    // The gap between 0 and 1 (x in [20,24)) is a miss.
    try testing.expectEqual(@as(?usize, null), hitTest(20, 5, 1.0));
    try testing.expectEqual(@as(?usize, null), hitTest(23, 5, 1.0));
    // Inside button 1.
    try testing.expectEqual(@as(?usize, 1), hitTest(24, 5, 1.0));
    try testing.expectEqual(@as(?usize, 1), hitTest(43, 5, 1.0));
    // Inside button 3 (close).
    try testing.expectEqual(@as(?usize, 3), hitTest(72, 5, 1.0));
    try testing.expectEqual(@as(?usize, 3), hitTest(91, 5, 1.0));
    // Past the cluster, and above/below it, are misses.
    try testing.expectEqual(@as(?usize, null), hitTest(92, 5, 1.0));
    try testing.expectEqual(@as(?usize, null), hitTest(5, -1, 1.0));
    try testing.expectEqual(@as(?usize, null), hitTest(5, 20, 1.0));
}

test "unit: hitTest scales with DPI" {
    // At 2.0: btn=40, gap=8. Button 0 spans [0,40); gap [40,48); button 1 [48,88).
    try testing.expectEqual(@as(?usize, 0), hitTest(39, 10, 2.0));
    try testing.expectEqual(@as(?usize, null), hitTest(44, 10, 2.0));
    try testing.expectEqual(@as(?usize, 1), hitTest(48, 10, 2.0));
    // Height doubles too: y=39 is in, y=40 is out.
    try testing.expectEqual(@as(?usize, 0), hitTest(10, 39, 2.0));
    try testing.expectEqual(@as(?usize, null), hitTest(10, 40, 2.0));
}

test "unit: Action enum matches cmux button order" {
    try testing.expectEqual(@as(usize, 0), @intFromEnum(Action.new_terminal));
    try testing.expectEqual(@as(usize, 1), @intFromEnum(Action.new_browser));
    try testing.expectEqual(@as(usize, 2), @intFromEnum(Action.split_right));
    try testing.expectEqual(@as(usize, 3), @intFromEnum(Action.split_down));
    try testing.expectEqual(BUTTON_COUNT, @typeInfo(Action).@"enum".fields.len);
}

test "unit: packBGRA premultiplies" {
    try testing.expectEqual(@as(u32, 0xFFE6E6E6), packBGRA(0xE6, 0xE6, 0xE6, 0xFF));
    try testing.expectEqual(@as(u32, 0), packBGRA(0x20, 0x20, 0x20, 0));
}
