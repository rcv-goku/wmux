//! Right sidebar for the Win32 apprt. A vertical strip on the right
//! edge of the window that displays per-tab contextual information:
//! - Tab title header
//! - Status text (set via `set-status` IPC command)
//! - Progress bar (set via `set-progress` IPC command)
//! - Log entries (set via `log` IPC command, from LogRing)
//!
//! Enabled via the `window-show-right-sidebar` config option. The right
//! sidebar coexists with the left sidebar and tab bar.

const std = @import("std");
const w32 = @import("win32.zig");
const Window = @import("Window.zig");
const ipc = @import("ipc.zig");

/// Unscaled layout constants.
const HEADER_H_BASE: i32 = 32;
const PAD_BASE: i32 = 8;
const LINE_H_BASE: i32 = 20;
const PROGRESS_H_BASE: i32 = 4;
const LOG_ENTRY_H_BASE: i32 = 18;
const SECTION_GAP_BASE: i32 = 8;

/// Right sidebar width clamp bounds in unscaled pixels.
pub const MIN_WIDTH: u32 = 120;
pub const MAX_WIDTH: u32 = 500;

/// Pixel value of an unscaled base constant at the given DPI scale.
fn scaled(base: i32, scale: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(base)) * scale));
}

/// Header height at the given DPI scale.
pub fn headerHeight(scale: f32) i32 {
    return scaled(HEADER_H_BASE, scale);
}

/// Single log entry height at the given DPI scale.
pub fn logEntryHeight(scale: f32) i32 {
    return scaled(LOG_ENTRY_H_BASE, scale);
}

/// Paint the full right sidebar strip using double-buffered GDI painting.
/// Shows the active tab's title, status text, progress bar, and log entries.
/// The caller owns BeginPaint/EndPaint.
pub fn paint(win: *Window, hdc_screen: w32.HDC) void {
    const hwnd = win.hwnd orelse return;
    const rs_w = win.rightSidebarWidth();
    if (rs_w <= 0) return;

    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client_rect) == 0) return;
    const client_w = client_rect.right - client_rect.left;
    const client_h = client_rect.bottom - client_rect.top;
    if (client_h <= 0) return;

    // The right sidebar occupies [client_w - rs_w, client_w).
    const rs_left = client_w - rs_w;

    // Double-buffer: create offscreen DC and bitmap.
    const mem_dc = w32.CreateCompatibleDC(hdc_screen) orelse return;
    defer _ = w32.DeleteDC(mem_dc);

    const mem_bmp = w32.CreateCompatibleBitmap(hdc_screen, rs_w, client_h) orelse return;
    const old_bmp = w32.SelectObject(mem_dc, mem_bmp);
    defer {
        _ = w32.SelectObject(mem_dc, old_bmp);
        _ = w32.DeleteObject(mem_bmp);
    }

    // --- Colors ---
    const bg = win.app.config.background;
    // Right sidebar background: terminal bg + 12 per channel (matches left sidebar).
    const bar_r: u8 = @min(@as(u16, bg.r) + 12, 255);
    const bar_g: u8 = @min(@as(u16, bg.g) + 12, 255);
    const bar_b: u8 = @min(@as(u16, bg.b) + 12, 255);
    const bar_color = w32.RGB(bar_r, bar_g, bar_b);

    // Header background: terminal bg + 20 (matches tab bar).
    const hdr_r: u8 = @min(@as(u16, bg.r) + 20, 255);
    const hdr_g: u8 = @min(@as(u16, bg.g) + 20, 255);
    const hdr_b: u8 = @min(@as(u16, bg.b) + 20, 255);
    const hdr_color = w32.RGB(hdr_r, hdr_g, hdr_b);

    // Text colors.
    const title_text_color = w32.RGB(230, 230, 230);
    const status_text_color = w32.RGB(180, 180, 180);
    const log_text_color = w32.RGB(150, 150, 150);
    const dim_text_color = w32.RGB(120, 120, 120);

    // Progress bar colors.
    const progress_bg_color = w32.RGB(
        @min(@as(u16, bg.r) + 25, 255),
        @min(@as(u16, bg.g) + 25, 255),
        @min(@as(u16, bg.b) + 25, 255),
    );
    const progress_fg_color = w32.RGB(0x3D, 0x8E, 0xF8); // blue accent

    // Accent line color (blue).
    const accent_color = w32.RGB(0x3D, 0x8E, 0xF8);

    // --- Fill sidebar background ---
    var bar_rect = w32.RECT{ .left = 0, .top = 0, .right = rs_w, .bottom = client_h };
    const bar_brush = w32.CreateSolidBrush(bar_color) orelse return;
    _ = w32.FillRect(mem_dc, &bar_rect, bar_brush);
    _ = w32.DeleteObject(@ptrCast(bar_brush));

    // --- Select font and set text mode ---
    var old_font: ?*anyopaque = null;
    if (win.tab_font) |font| {
        old_font = w32.SelectObject(mem_dc, font);
    }
    defer {
        if (old_font) |f| _ = w32.SelectObject(mem_dc, f);
    }
    _ = w32.SetBkMode(mem_dc, w32.TRANSPARENT);

    const pad = scaled(PAD_BASE, win.scale);
    const header_h = headerHeight(win.scale);
    const line_h = scaled(LINE_H_BASE, win.scale);
    const progress_h = scaled(PROGRESS_H_BASE, win.scale);
    const section_gap = scaled(SECTION_GAP_BASE, win.scale);
    var y: i32 = 0;

    // Get the active workspace and tab data.
    const wsp = &win.workspaces[win.active_workspace];
    const active_tab = wsp.active_tab;

    // --- Header: tab title ---
    {
        var hdr_rect = w32.RECT{ .left = 0, .top = y, .right = rs_w, .bottom = y + header_h };
        if (w32.CreateSolidBrush(hdr_color)) |brush| {
            _ = w32.FillRect(mem_dc, &hdr_rect, brush);
            _ = w32.DeleteObject(@ptrCast(brush));
        }

        // Accent line at the left edge of the header.
        const accent_w = scaled(3, win.scale);
        var accent_rect = w32.RECT{ .left = 0, .top = y, .right = accent_w, .bottom = y + header_h };
        if (w32.CreateSolidBrush(accent_color)) |brush| {
            _ = w32.FillRect(mem_dc, &accent_rect, brush);
            _ = w32.DeleteObject(@ptrCast(brush));
        }

        // Tab title text.
        if (wsp.tab_count > 0 and active_tab < wsp.tab_count) {
            const title_len: usize = wsp.tab_title_lens[active_tab];
            if (title_len > 0) {
                _ = w32.SetTextColor(mem_dc, title_text_color);
                var text_rect = w32.RECT{
                    .left = pad + accent_w,
                    .top = y,
                    .right = rs_w - pad,
                    .bottom = y + header_h,
                };
                _ = w32.DrawTextW(
                    mem_dc,
                    @ptrCast(&wsp.tab_titles[active_tab]),
                    @intCast(title_len),
                    &text_rect,
                    w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
                );
            }
        }
        y += header_h;
    }

    // --- Status text ---
    if (wsp.tab_count > 0 and active_tab < wsp.tab_count) {
        const status = wsp.tabStatusText(active_tab);
        if (status.len > 0) {
            y += section_gap;

            // Label.
            _ = w32.SetTextColor(mem_dc, dim_text_color);
            const label = std.unicode.utf8ToUtf16LeStringLiteral("STATUS");
            var label_rect = w32.RECT{
                .left = pad,
                .top = y,
                .right = rs_w - pad,
                .bottom = y + line_h,
            };
            _ = w32.DrawTextW(
                mem_dc,
                label,
                label.len,
                &label_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
            y += line_h;

            // Status text value (convert UTF-8 to UTF-16).
            var status_buf: [128]u16 = undefined;
            const status_w = std.unicode.utf8ToUtf16Le(&status_buf, status) catch 0;
            if (status_w > 0) {
                _ = w32.SetTextColor(mem_dc, status_text_color);
                var status_rect = w32.RECT{
                    .left = pad,
                    .top = y,
                    .right = rs_w - pad,
                    .bottom = y + line_h,
                };
                _ = w32.DrawTextW(
                    mem_dc,
                    @ptrCast(&status_buf),
                    @intCast(status_w),
                    &status_rect,
                    w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
                );
                y += line_h;
            }
        }
    }

    // --- Progress bar ---
    if (wsp.tab_count > 0 and active_tab < wsp.tab_count) {
        if (wsp.tab_progress[active_tab]) |progress| {
            y += section_gap;

            // Label.
            _ = w32.SetTextColor(mem_dc, dim_text_color);
            const plabel = std.unicode.utf8ToUtf16LeStringLiteral("PROGRESS");
            var plabel_rect = w32.RECT{
                .left = pad,
                .top = y,
                .right = rs_w - pad,
                .bottom = y + line_h,
            };
            _ = w32.DrawTextW(
                mem_dc,
                plabel,
                plabel.len,
                &plabel_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );

            // Percent text right-aligned.
            var pct_buf: [8]u16 = undefined;
            var pct_utf8: [4]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_utf8, "{d}%", .{progress}) catch pct_utf8[0..0];
            const pct_w = std.unicode.utf8ToUtf16Le(&pct_buf, pct_str) catch 0;
            if (pct_w > 0) {
                _ = w32.SetTextColor(mem_dc, status_text_color);
                var pct_rect = w32.RECT{
                    .left = pad,
                    .top = y,
                    .right = rs_w - pad,
                    .bottom = y + line_h,
                };
                _ = w32.DrawTextW(
                    mem_dc,
                    @ptrCast(&pct_buf),
                    @intCast(pct_w),
                    &pct_rect,
                    w32.DT_RIGHT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
                );
            }
            y += line_h;

            // Progress bar track.
            const bar_width = rs_w - 2 * pad;
            var track_rect = w32.RECT{
                .left = pad,
                .top = y,
                .right = pad + bar_width,
                .bottom = y + progress_h,
            };
            if (w32.CreateSolidBrush(progress_bg_color)) |brush| {
                _ = w32.FillRect(mem_dc, &track_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }

            // Progress bar fill.
            const fill_width = @divTrunc(bar_width * @as(i32, progress), 100);
            if (fill_width > 0) {
                var fill_rect = w32.RECT{
                    .left = pad,
                    .top = y,
                    .right = pad + fill_width,
                    .bottom = y + progress_h,
                };
                if (w32.CreateSolidBrush(progress_fg_color)) |brush| {
                    _ = w32.FillRect(mem_dc, &fill_rect, brush);
                    _ = w32.DeleteObject(@ptrCast(brush));
                }
            }
            y += progress_h;
        }
    }

    // --- Log entries ---
    if (wsp.tab_count > 0 and active_tab < wsp.tab_count) {
        const ring = &wsp.tab_log[active_tab];
        if (ring.len > 0) {
            y += section_gap;

            // Label.
            _ = w32.SetTextColor(mem_dc, dim_text_color);
            const llabel = std.unicode.utf8ToUtf16LeStringLiteral("LOG");
            var llabel_rect = w32.RECT{
                .left = pad,
                .top = y,
                .right = rs_w - pad,
                .bottom = y + line_h,
            };
            _ = w32.DrawTextW(
                mem_dc,
                llabel,
                llabel.len,
                &llabel_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
            y += line_h;

            // Separator line.
            var sep_rect = w32.RECT{
                .left = pad,
                .top = y,
                .right = rs_w - pad,
                .bottom = y + 1,
            };
            if (w32.CreateSolidBrush(dim_text_color)) |brush| {
                _ = w32.FillRect(mem_dc, &sep_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
            y += scaled(2, win.scale);

            // Log entries, newest first.
            const entry_h = logEntryHeight(win.scale);
            var i: usize = 0;
            while (i < ring.len and y + entry_h <= client_h) : (i += 1) {
                const line = ring.at(i) orelse break;
                var line_buf: [ipc.max_log_line_bytes]u16 = undefined;
                const line_w = std.unicode.utf8ToUtf16Le(&line_buf, line) catch 0;
                if (line_w > 0) {
                    _ = w32.SetTextColor(mem_dc, log_text_color);
                    var entry_rect = w32.RECT{
                        .left = pad,
                        .top = y,
                        .right = rs_w - pad,
                        .bottom = y + entry_h,
                    };
                    _ = w32.DrawTextW(
                        mem_dc,
                        @ptrCast(&line_buf),
                        @intCast(line_w),
                        &entry_rect,
                        w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
                    );
                }
                y += entry_h;
            }
        }
    }

    // --- BitBlt to screen ---
    _ = w32.BitBlt(hdc_screen, rs_left, 0, rs_w, client_h, mem_dc, 0, 0, w32.SRCCOPY);
}
