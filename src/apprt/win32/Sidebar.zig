//! Workspace sidebar for the Win32 apprt. A vertical strip on the left
//! edge of the window that lists each workspace as a row plus a
//! "+ New workspace" row. Enabled via the `window-show-sidebar` config
//! option. The top tab bar (showing the active workspace's tabs)
//! coexists with the sidebar, offset to its right.

const std = @import("std");
const w32 = @import("win32.zig");
const Window = @import("Window.zig");
const testing = std.testing;

const ITEM_HEIGHT_BASE: i32 = 36;
/// Extra unscaled height added to a row when the metadata second line is
/// shown (Stage 2). The taller row fits the dim branch/ports/status line
/// below the name. Applied uniformly to every row when metadata rendering
/// is active so the index-based row geometry (hitTest/itemRect/drag) stays
/// a single fixed stride.
const META_EXTRA_BASE: i32 = 16;
const PAD_BASE: i32 = 8;
const ACCENT_W_BASE: i32 = 3;
const EDGE_BAND_BASE: i32 = 5;
const FOOTER_H_BASE: i32 = 32;
const FOOTER_ICON_BASE: i32 = 24;
const NOTIF_HEADER_BASE: i32 = 24;
const NOTIF_ENTRY_BASE: i32 = 40;
const NOTIF_CLEAR_W_BASE: i32 = 48;
const BADGE_BASE: i32 = 14;
const DROPDOWN_BASE: i32 = 24;
const CLOSE_BASE: i32 = 20;
const DRAG_THRESHOLD_BASE: i32 = 5;

/// Sidebar width clamp bounds in unscaled pixels, applied to both the
/// `window-sidebar-width` config value and the drag-resize override.
pub const MIN_WIDTH: u32 = 120;
pub const MAX_WIDTH: u32 = 400;

/// Result of hit-testing a point against the sidebar.
pub const HitTarget = union(enum) {
    none,
    /// A workspace row body. The sidebar lists workspaces (one row each);
    /// clicking switches to that workspace.
    workspace: usize,
    /// The close 'x' glyph at the right edge of workspace row `index`.
    /// Hit-tested ahead of `.workspace` within the row; revealed on hover.
    row_close: usize,
    new_session,
    /// The dropdown chevron zone at the right edge of the
    /// "+ New session" row (opens the backend picker targeting a new
    /// workspace whose first tab runs the chosen backend).
    new_session_dropdown,
    bell_icon,
    gear_icon,
    browser_icon,
    /// The collapse chevron in the footer (fourth slot): runtime-hides
    /// the sidebar (toggle_sidebar). Distinct from the config option.
    collapse_toggle,
    /// Display index into the notification log, 0 = newest.
    notif_entry: usize,
    notif_clear,
};

/// Pixel value of an unscaled base constant at the given DPI scale.
fn scaled(base: i32, scale: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(base)) * scale));
}

/// Base (single-line) row height in pixels at the given DPI scale.
pub fn itemHeight(scale: f32) i32 {
    return scaled(ITEM_HEIGHT_BASE, scale);
}

/// Row height in pixels at the given DPI scale when the metadata second
/// line is shown (Stage 2). Taller than itemHeight by the metadata band.
/// Callers pick between the two via Window.sidebarItemHeight and pass the
/// chosen value into the pure geometry helpers (hitTest/itemRect/...), so
/// those stay metadata-agnostic and their tests unchanged.
pub fn itemHeightMeta(scale: f32) i32 {
    return scaled(ITEM_HEIGHT_BASE + META_EXTRA_BASE, scale);
}

/// Width of the drag-resize grab band along the sidebar's right edge,
/// in pixels at the given DPI scale.
pub fn edgeBandWidth(scale: f32) i32 {
    return scaled(EDGE_BAND_BASE, scale);
}

/// Height of the footer strip (bell/gear icons) at the given DPI scale.
pub fn footerHeight(scale: f32) i32 {
    return scaled(FOOTER_H_BASE, scale);
}

/// Pixel distance the cursor must move from the press point before a
/// row press becomes a drag-reorder (vs. a click-to-select), at the
/// given DPI scale. Matches the tab bar's 5px threshold at 1.0.
pub fn dragThreshold(scale: f32) i32 {
    return scaled(DRAG_THRESHOLD_BASE, scale);
}

/// Height of the notifications panel: ~40% of the client height.
pub fn panelHeight(client_h: i32) i32 {
    return @divTrunc(client_h * 2, 5);
}

/// Height of one notification entry row at the given DPI scale.
pub fn notifEntryHeight(scale: f32) i32 {
    return scaled(NOTIF_ENTRY_BASE, scale);
}

/// Icon slot rect for the bell, vertically centered in the footer.
pub fn bellSlotRect(footer_top: i32, scale: f32) w32.RECT {
    const pad = scaled(PAD_BASE, scale);
    const icon = scaled(FOOTER_ICON_BASE, scale);
    const top = footer_top + @divTrunc(footerHeight(scale) - icon, 2);
    return .{ .left = pad, .top = top, .right = pad + icon, .bottom = top + icon };
}

/// Icon slot rect for the gear, vertically centered in the footer.
pub fn gearSlotRect(footer_top: i32, scale: f32) w32.RECT {
    const pad = scaled(PAD_BASE, scale);
    const icon = scaled(FOOTER_ICON_BASE, scale);
    const top = footer_top + @divTrunc(footerHeight(scale) - icon, 2);
    return .{ .left = pad + icon + pad, .top = top, .right = pad + icon + pad + icon, .bottom = top + icon };
}

/// Icon slot rect for the browser globe (third slot), vertically
/// centered in the footer.
pub fn globeSlotRect(footer_top: i32, scale: f32) w32.RECT {
    const pad = scaled(PAD_BASE, scale);
    const icon = scaled(FOOTER_ICON_BASE, scale);
    const top = footer_top + @divTrunc(footerHeight(scale) - icon, 2);
    const left = (pad + icon) * 2 + pad;
    return .{ .left = left, .top = top, .right = left + icon, .bottom = top + icon };
}

/// Icon slot rect for the collapse chevron, RIGHT-aligned in the footer
/// (set apart from the left-clustered bell/gear/globe so it reads as a
/// distinct "hide" affordance). Ending at width-pad keeps it left of the
/// drag-resize edge band, which is hit-tested first.
pub fn collapseSlotRect(footer_top: i32, width: i32, scale: f32) w32.RECT {
    const pad = scaled(PAD_BASE, scale);
    const icon = scaled(FOOTER_ICON_BASE, scale);
    const top = footer_top + @divTrunc(footerHeight(scale) - icon, 2);
    return .{ .left = width - pad - icon, .top = top, .right = width - pad, .bottom = top + icon };
}

/// Hit-test an x coordinate against the drag-resize grab band, which
/// spans [edge - band_w, edge) where `edge` is the sidebar's right
/// edge. A hidden sidebar (edge <= 0) has no band.
pub fn hitTestEdge(x: i32, edge: i32, band_w: i32) bool {
    if (edge <= 0) return false;
    return x >= edge - band_w and x < edge;
}

/// Window-side state hitTest needs beyond the point itself. All
/// fields are plain values so the function stays pure and testable.
pub const HitCtx = struct {
    item_h: i32,
    /// Number of workspace rows (one per workspace in the window).
    workspace_count: usize,
    /// Full client height (the footer is anchored to the bottom).
    client_h: i32,
    /// Sidebar width (the "Clear" button is right-aligned).
    width: i32,
    scale: f32,
    panel_open: bool,
    /// Number of entries currently in the notification log.
    notif_count: usize,
};

/// Hit-test a point against the sidebar. Top-to-bottom: workspace rows
/// (0..workspace_count-1), the "+ New workspace" row, then — when open —
/// the notifications panel (header with the Clear button, entry rows
/// newest-first), and finally the footer strip (bell/gear icons). The
/// row area ends at the panel top (footer top when closed); rows under
/// the panel/footer are not hit.
///
/// Points outside the strip are .none on both axes: x outside
/// [0, width) never resolves a target, mirroring the y bounds. Callers
/// gate on `x < sidebarWidth()` today, but capture-driven mouse
/// messages can deliver NEGATIVE client x, which used to fall through
/// to a row body; the guard makes the function safe stand-alone.
pub fn hitTest(x: i32, y: i32, ctx: HitCtx) HitTarget {
    if (x < 0 or x >= ctx.width) return .none;
    if (y < 0 or ctx.item_h <= 0) return .none;
    if (y >= ctx.client_h) return .none;

    const footer_top = ctx.client_h - footerHeight(ctx.scale);
    if (y >= footer_top) {
        // Footer icon slots span the full strip height for a more
        // forgiving click zone; only x decides the slot. The collapse
        // chevron is right-aligned and checked first (it can't overlap
        // the left cluster at any usable width).
        const pad = scaled(PAD_BASE, ctx.scale);
        const icon = scaled(FOOTER_ICON_BASE, ctx.scale);
        if (x >= ctx.width - pad - icon and x < ctx.width - pad) return .collapse_toggle;
        if (x >= pad and x < pad + icon) return .bell_icon;
        const gear_left = pad + icon + pad;
        if (x >= gear_left and x < gear_left + icon) return .gear_icon;
        const globe_left = gear_left + icon + pad;
        if (x >= globe_left and x < globe_left + icon) return .browser_icon;
        return .none;
    }

    if (ctx.panel_open) {
        const panel_top = footer_top - panelHeight(ctx.client_h);
        if (y >= panel_top) {
            const rel = y - panel_top;
            const header_h = scaled(NOTIF_HEADER_BASE, ctx.scale);
            if (rel < header_h) {
                const clear_w = scaled(NOTIF_CLEAR_W_BASE, ctx.scale);
                if (x >= ctx.width - clear_w) return .notif_clear;
                return .none;
            }
            const entry_h = notifEntryHeight(ctx.scale);
            if (entry_h <= 0) return .none;
            const idx: usize = @intCast(@divTrunc(rel - header_h, entry_h));
            if (idx < ctx.notif_count) return .{ .notif_entry = idx };
            return .none;
        }
    }

    const row: usize = @intCast(@divTrunc(y, ctx.item_h));
    if (row < ctx.workspace_count) {
        // Close 'x' band: like the dropdown chevron, the zone spans the
        // full row height for a forgiving click; only x decides. It
        // takes priority over the row body. The band matches
        // rowCloseRect's x-range so paint and hit-test agree.
        const pad = scaled(PAD_BASE, ctx.scale);
        const cw = scaled(CLOSE_BASE, ctx.scale);
        if (x >= ctx.width - pad - cw and x < ctx.width - pad) return .{ .row_close = row };
        return .{ .workspace = row };
    }
    if (row == ctx.workspace_count) {
        // Dropdown chevron: like the footer slots, the zone spans the
        // full row height for a forgiving click; only x decides.
        const pad = scaled(PAD_BASE, ctx.scale);
        const dd = scaled(DROPDOWN_BASE, ctx.scale);
        if (x >= ctx.width - pad - dd and x < ctx.width - pad) return .new_session_dropdown;
        return .new_session;
    }
    return .none;
}

/// The rectangle of row `index` in a sidebar of the given width.
pub fn itemRect(index: usize, width: i32, item_h: i32) w32.RECT {
    const top = @as(i32, @intCast(index)) * item_h;
    return .{ .left = 0, .top = top, .right = width, .bottom = top + item_h };
}

/// Painted rect of the close 'x' glyph for session row `index`: a
/// square, vertically centered in the row and right-aligned to the
/// text pad. Mirrors the tab bar's close button placement. Ending at
/// width-pad keeps it left of the drag-resize edge band (pad >= band
/// width at any scale), which is hit-tested first.
pub fn rowCloseRect(index: usize, width: i32, item_h: i32, scale: f32) w32.RECT {
    const pad = scaled(PAD_BASE, scale);
    const cw = scaled(CLOSE_BASE, scale);
    const row = itemRect(index, width, item_h);
    const top = row.top + @divTrunc(item_h - cw, 2);
    return .{ .left = width - pad - cw, .top = top, .right = width - pad, .bottom = top + cw };
}

/// Painted rect of the "+ New session" dropdown chevron: a square,
/// vertically centered in the row and right-aligned to the text pad.
/// Ending at width-pad keeps it left of the drag-resize edge band
/// (pad >= band width at any scale), which is hit-tested first.
pub fn newSessionDropdownRect(tab_count: usize, width: i32, item_h: i32, scale: f32) w32.RECT {
    const pad = scaled(PAD_BASE, scale);
    const dd = scaled(DROPDOWN_BASE, scale);
    const row = itemRect(tab_count, width, item_h);
    const top = row.top + @divTrunc(item_h - dd, 2);
    return .{ .left = width - pad - dd, .top = top, .right = width - pad, .bottom = top + dd };
}

/// Compose the workspace metadata second line into UTF-8 in `out` and
/// return its byte length. Pure (reads only the workspace's cached
/// fields), so the composition rule — segment order, the "·" separators,
/// the "⎇"/":" sigils, and the PR marker — is unit tested without GDI.
/// Segments are emitted in priority order and dropped once the buffer is
/// nearly full so the most useful info (branch, then ports, then status)
/// survives truncation.
pub fn formatMetaLineUtf8(wsp: *const Window.Workspace, out: []u8) usize {
    var len: usize = 0;
    const sep = " \u{00B7} "; // " · "

    const append = struct {
        fn f(buf: []u8, n: *usize, s: []const u8) void {
            if (n.* + s.len > buf.len) return;
            @memcpy(buf[n.*..][0..s.len], s);
            n.* += s.len;
        }
    }.f;

    // Branch: "⎇ <branch>".
    const branch = wsp.gitBranch();
    if (branch.len > 0) {
        append(out, &len, "\u{2387} "); // ⎇
        append(out, &len, branch);
    }

    // PR marker: "PR #NN" with a state sigil.
    if (wsp.pr_state != .none) {
        if (len > 0) append(out, &len, sep);
        const sigil: []const u8 = switch (wsp.pr_state) {
            .open => "PR #",
            .draft => "draft #",
            .merged => "merged #",
            .closed => "closed #",
            .none => unreachable,
        };
        append(out, &len, sigil);
        var num_buf: [10]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{wsp.pr_number}) catch num_buf[0..0];
        append(out, &len, num);
    }

    // Ports: ":3000, 8080".
    const ports = wsp.portsSlice();
    if (ports.len > 0) {
        if (len > 0) append(out, &len, sep);
        append(out, &len, ":");
        for (ports, 0..) |p, i| {
            if (i > 0) append(out, &len, ", ");
            var pb: [6]u8 = undefined;
            const ps = std.fmt.bufPrint(&pb, "{d}", .{p}) catch pb[0..0];
            append(out, &len, ps);
        }
    }

    // Latest agent status text: the first non-empty per-tab status.
    var status: []const u8 = "";
    for (0..wsp.tab_count) |t| {
        const s = wsp.tabStatusText(t);
        if (s.len > 0) {
            status = s;
            break;
        }
    }
    if (status.len > 0) {
        if (len > 0) append(out, &len, sep);
        append(out, &len, status);
    }

    return len;
}

/// Build the metadata line as UTF-16 in `out16`, returning the code-unit
/// length. Routes through formatMetaLineUtf8 then transcodes; on a
/// transcode error returns 0 (no line drawn).
fn buildMetaLine(wsp: *const Window.Workspace, out16: []u16) usize {
    var utf8_buf: [512]u8 = undefined;
    var n = formatMetaLineUtf8(wsp, &utf8_buf);
    if (n == 0) return 0;
    // utf8ToUtf16Le does NOT bounds-check its output: it would write past
    // out16 if the source transcoded to more units than out16 holds. Since
    // UTF-16 units <= UTF-8 bytes always, capping the source byte length to
    // out16.len guarantees the write fits. Truncate on a codepoint boundary
    // so the transcode never fails on a split multi-byte sequence.
    if (n > out16.len) {
        n = out16.len;
        while (n > 0 and (utf8_buf[n] & 0xC0) == 0x80) n -= 1; // back off into a lead byte
    }
    const w = std.unicode.utf8ToUtf16Le(out16, utf8_buf[0..n]) catch return 0;
    return w;
}

/// Paint the full sidebar strip using double-buffered GDI painting.
/// Draws workspace rows (status dot, number, name) and the
/// "+ New workspace" row. The caller owns BeginPaint/EndPaint.
pub fn paint(win: *Window, hdc_screen: w32.HDC) void {
    const hwnd = win.hwnd orelse return;
    const sidebar_w = win.sidebarWidth();
    if (sidebar_w <= 0) return;

    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client_rect) == 0) return;
    const client_h = client_rect.bottom - client_rect.top;
    if (client_h <= 0) return;

    // Double-buffer: create offscreen DC and bitmap.
    const mem_dc = w32.CreateCompatibleDC(hdc_screen) orelse return;
    defer _ = w32.DeleteDC(mem_dc);

    const mem_bmp = w32.CreateCompatibleBitmap(hdc_screen, sidebar_w, client_h) orelse return;
    const old_bmp = w32.SelectObject(mem_dc, mem_bmp);
    defer {
        _ = w32.SelectObject(mem_dc, old_bmp);
        _ = w32.DeleteObject(mem_bmp);
    }

    // --- Colors ---
    const bg = win.app.config.background;
    // Sidebar background: terminal bg + 12 per channel. Slightly darker
    // than the tab bar's +20 so the two chrome strips read as distinct.
    const bar_r: u8 = @min(@as(u16, bg.r) + 12, 255);
    const bar_g: u8 = @min(@as(u16, bg.g) + 12, 255);
    const bar_b: u8 = @min(@as(u16, bg.b) + 12, 255);
    const bar_color = w32.RGB(bar_r, bar_g, bar_b);

    // Hover row: terminal bg + 35 per channel (same as tab bar hover).
    const hover_r: u8 = @min(@as(u16, bg.r) + 35, 255);
    const hover_g: u8 = @min(@as(u16, bg.g) + 35, 255);
    const hover_b: u8 = @min(@as(u16, bg.b) + 35, 255);
    const hover_color = w32.RGB(hover_r, hover_g, hover_b);

    // Active row background: terminal bg (darker than the sidebar).
    const active_bg_color = w32.RGB(bg.r, bg.g, bg.b);

    // Accent bar color (blue).
    const accent_color = w32.RGB(0x3D, 0x8E, 0xF8);

    // Text colors.
    const active_text_color = w32.RGB(230, 230, 230);
    const inactive_text_color = w32.RGB(150, 150, 150);
    // Metadata second-line text: dimmer than the inactive name color so the
    // branch/ports/status read as secondary.
    const meta_text_color = w32.RGB(120, 120, 120);

    // Status dot colors.
    const bell_color = w32.RGB(255, 185, 0);
    const exited_color = w32.RGB(232, 65, 65);

    // --- Fill sidebar background ---
    var bar_rect = w32.RECT{ .left = 0, .top = 0, .right = sidebar_w, .bottom = client_h };
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

    // --- Row geometry ---
    // The sidebar lists WORKSPACES, one row each. The "+ New workspace"
    // row sits directly below the last workspace row.
    const ws_count = win.workspace_count;
    // Single source of truth for the row stride (matches hitTest); taller
    // when the metadata second line is active.
    const show_meta = win.sidebarShowMetadata();
    const item_h = win.sidebarItemHeight();
    const pad = scaled(PAD_BASE, win.scale);
    const accent_w = scaled(ACCENT_W_BASE, win.scale);
    // Fixed-width status dot column so numbers/titles align across rows.
    const dot_w = pad * 2;

    // Footer/panel geometry. Session rows are painted full-length and
    // the panel/footer fills below overdraw them, which clips rows to
    // the visible area without GDI clip regions.
    const footer_top = client_h - footerHeight(win.scale);
    const panel_top = if (win.notif_panel_open)
        footer_top - panelHeight(client_h)
    else
        footer_top;

    // Height of the first (name) line within a row. When the metadata
    // second line is shown the row is taller; the name/dot/close glyph all
    // center in this top band and the metadata line fills the band below.
    const line1_h = if (show_meta) itemHeight(win.scale) else item_h;

    // --- Draw each workspace row ---
    for (0..ws_count) |i| {
        const wsp = &win.workspaces[i];
        var row = itemRect(i, sidebar_w, item_h);
        // The top band the name/dot/close occupy (== the whole row when
        // metadata is off).
        const line1_bottom = row.top + line1_h;
        const is_active = (i == win.active_workspace);
        // The row reads as hovered when the cursor is over its body or
        // its close 'x'; the close glyph itself only appears in either
        // case (mirrors the tab bar revealing 'x' on hover).
        const close_hovered = switch (win.sidebar_hover) {
            .row_close => |h| h == i,
            else => false,
        };
        const is_hovered = close_hovered or switch (win.sidebar_hover) {
            .workspace => |h| h == i,
            else => false,
        };

        // A workspace with an attention pane (the notification ring)
        // lights up its row with the same blue accent bar the active row
        // uses, so a background workspace where an agent is waiting reads
        // at a glance. Orthogonal to the bell/exited status dot.
        const has_attention = wsp.hasAttention();

        if (is_active) {
            if (w32.CreateSolidBrush(active_bg_color)) |brush| {
                _ = w32.FillRect(mem_dc, &row, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }

            // Draw accent bar on the left edge.
            var accent_rect = w32.RECT{
                .left = 0,
                .top = row.top,
                .right = accent_w,
                .bottom = row.bottom,
            };
            if (w32.CreateSolidBrush(accent_color)) |brush| {
                _ = w32.FillRect(mem_dc, &accent_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        } else if (is_hovered) {
            if (w32.CreateSolidBrush(hover_color)) |brush| {
                _ = w32.FillRect(mem_dc, &row, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        // Attention left accent bar on a non-active row (the active row
        // already shows the accent). Drawn after the hover fill so it sits
        // on top.
        if (has_attention and !is_active) {
            var attn_rect = w32.RECT{
                .left = 0,
                .top = row.top,
                .right = accent_w,
                .bottom = row.bottom,
            };
            if (w32.CreateSolidBrush(accent_color)) |brush| {
                _ = w32.FillRect(mem_dc, &attn_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        // Draw the dot column: the worst bell/exited status takes it;
        // otherwise an attention-only workspace shows a blue dot there.
        // (When a workspace is both exited/bell AND waiting, the left
        // accent bar above carries the attention signal.)
        const status = wsp.aggregateStatus();
        const dot_color: ?u32 = if (status != .normal)
            switch (status) {
                .bell => bell_color,
                .exited => exited_color,
                .normal => unreachable,
            }
        else if (has_attention)
            accent_color
        else
            null;
        if (dot_color) |dc| {
            _ = w32.SetTextColor(mem_dc, dc);
            const dot_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{25CF}");
            var dot_rect = w32.RECT{
                .left = accent_w + pad,
                .top = row.top,
                .right = accent_w + pad + dot_w,
                .bottom = line1_bottom,
            };
            _ = w32.DrawTextW(
                mem_dc,
                dot_char,
                1,
                &dot_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
        }

        // Draw "N  name" where N is index+1 for the first nine rows
        // (matches the default alt+1..8 goto keybinds). The label is the
        // workspace name, falling back to "Workspace N" when unnamed.
        var text_buf: [260]u16 = undefined;
        var text_len: usize = 0;
        if (i < 9) {
            text_buf[0] = '1' + @as(u16, @intCast(i));
            text_buf[1] = ' ';
            text_buf[2] = ' ';
            text_len = 3;
        }
        if (wsp.name_len > 0) {
            const name_len: usize = wsp.name_len;
            @memcpy(text_buf[text_len .. text_len + name_len], wsp.name[0..name_len]);
            text_len += name_len;
        } else {
            // Fallback label: "Workspace <n>" (1-based).
            const fallback = std.unicode.utf8ToUtf16LeStringLiteral("Workspace ");
            @memcpy(text_buf[text_len .. text_len + fallback.len], fallback);
            text_len += fallback.len;
            // Append the 1-based index. Workspaces cap at 16, so at most
            // two digits.
            var num_buf: [2]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i + 1}) catch num_buf[0..0];
            for (num_str) |c| {
                text_buf[text_len] = c;
                text_len += 1;
            }
        }

        if (text_len > 0) {
            _ = w32.SetTextColor(mem_dc, if (is_active) active_text_color else inactive_text_color);
            // Reserve room for the close 'x' when it is shown so the
            // title ellipsizes instead of running under the glyph
            // (the tab bar reserves close_btn_w the same way).
            const cw = scaled(CLOSE_BASE, win.scale);
            const text_right = if (is_hovered) sidebar_w - pad - cw else sidebar_w - pad;
            var text_rect = w32.RECT{
                .left = accent_w + pad + dot_w,
                .top = row.top,
                .right = text_right,
                .bottom = line1_bottom,
            };
            _ = w32.DrawTextW(
                mem_dc,
                @ptrCast(&text_buf),
                @intCast(text_len),
                &text_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
            );
        }

        // Close 'x' — revealed on row hover, like the tab bar. Red when
        // the cursor is specifically over the glyph. Centered in the top
        // (name) band so it stays beside the name on a two-line row; the
        // hit band (in hitTest) still spans the whole row by x.
        if (is_hovered) {
            _ = w32.SetTextColor(mem_dc, if (close_hovered) exited_color else inactive_text_color);
            const x_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{00D7}");
            var close_rect = rowCloseRect(i, sidebar_w, line1_h, win.scale);
            // rowCloseRect lays the glyph out relative to row index*line1_h;
            // shift it down to this row's actual top (rows stride item_h).
            const dy = row.top - @as(i32, @intCast(i)) * line1_h;
            close_rect.top += dy;
            close_rect.bottom += dy;
            _ = w32.DrawTextW(
                mem_dc,
                x_char,
                1,
                &close_rect,
                w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
        }

        // --- Second line: description or metadata (Stage 2) ---
        // When a user-set description exists, show it (dimmer than the
        // name) in the metadata band below the workspace name; otherwise
        // fall back to the auto-populated metadata line (git branch,
        // ports, status).
        if (show_meta) {
            const desc = wsp.descriptionSlice();
            if (desc.len > 0) {
                _ = w32.SetTextColor(mem_dc, meta_text_color);
                var desc_rect = w32.RECT{
                    .left = accent_w + pad + dot_w,
                    .top = line1_bottom,
                    .right = sidebar_w - pad,
                    .bottom = row.bottom,
                };
                _ = w32.DrawTextW(
                    mem_dc,
                    @ptrCast(desc.ptr),
                    @intCast(desc.len),
                    &desc_rect,
                    w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
                );
            } else {
                var meta_buf: [256]u16 = undefined;
                const meta_len = buildMetaLine(wsp, &meta_buf);
                if (meta_len > 0) {
                    _ = w32.SetTextColor(mem_dc, meta_text_color);
                    var meta_rect = w32.RECT{
                        .left = accent_w + pad + dot_w,
                        .top = line1_bottom,
                        .right = sidebar_w - pad,
                        .bottom = row.bottom,
                    };
                    _ = w32.DrawTextW(
                        mem_dc,
                        @ptrCast(&meta_buf),
                        @intCast(meta_len),
                        &meta_rect,
                        w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
                    );
                }
            }
        }
    }

    // --- Draw "+ New workspace" row ---
    {
        var row = itemRect(ws_count, sidebar_w, item_h);
        if (win.sidebar_hover == .new_session) {
            if (w32.CreateSolidBrush(hover_color)) |brush| {
                _ = w32.FillRect(mem_dc, &row, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        const dd_rect = newSessionDropdownRect(ws_count, sidebar_w, item_h, win.scale);

        _ = w32.SetTextColor(mem_dc, inactive_text_color);
        const label = std.unicode.utf8ToUtf16LeStringLiteral("+ New workspace");
        var text_rect = w32.RECT{
            .left = accent_w + pad,
            .top = row.top,
            .right = dd_rect.left,
            .bottom = row.bottom,
        };
        _ = w32.DrawTextW(
            mem_dc,
            label,
            label.len,
            &text_rect,
            w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
        );

        // Dropdown chevron: hover-highlighted square, independent of
        // the row-body hover above.
        const dd_hot = win.sidebar_hover == .new_session_dropdown;
        if (dd_hot) {
            var dd_fill = dd_rect;
            if (w32.CreateSolidBrush(hover_color)) |brush| {
                _ = w32.FillRect(mem_dc, &dd_fill, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }
        _ = w32.SetTextColor(mem_dc, if (dd_hot) active_text_color else inactive_text_color);
        const chevron = std.unicode.utf8ToUtf16LeStringLiteral("\u{25BE}");
        var chevron_rect = dd_rect;
        _ = w32.DrawTextW(
            mem_dc,
            chevron,
            chevron.len,
            &chevron_rect,
            w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );
    }

    // --- Notifications panel ---
    if (win.notif_panel_open and panel_top < footer_top) {
        // Panel background: terminal bg + 6, slightly darker than the
        // sidebar's +12 so the panel reads as a separate layer.
        const panel_r: u8 = @min(@as(u16, bg.r) + 6, 255);
        const panel_g: u8 = @min(@as(u16, bg.g) + 6, 255);
        const panel_b: u8 = @min(@as(u16, bg.b) + 6, 255);
        var panel_rect = w32.RECT{ .left = 0, .top = panel_top, .right = sidebar_w, .bottom = footer_top };
        if (w32.CreateSolidBrush(w32.RGB(panel_r, panel_g, panel_b))) |brush| {
            _ = w32.FillRect(mem_dc, &panel_rect, brush);
            _ = w32.DeleteObject(@ptrCast(brush));
        }

        // Header row: "Clear" text button, right-aligned.
        const header_h = scaled(NOTIF_HEADER_BASE, win.scale);
        const clear_w = scaled(NOTIF_CLEAR_W_BASE, win.scale);
        _ = w32.SetTextColor(mem_dc, if (win.sidebar_hover == .notif_clear)
            active_text_color
        else
            inactive_text_color);
        const clear_label = std.unicode.utf8ToUtf16LeStringLiteral("Clear");
        var clear_rect = w32.RECT{
            .left = sidebar_w - clear_w,
            .top = panel_top,
            .right = sidebar_w - pad,
            .bottom = panel_top + header_h,
        };
        _ = w32.DrawTextW(
            mem_dc,
            clear_label,
            clear_label.len,
            &clear_rect,
            w32.DT_RIGHT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );

        // Entries, newest first. Entries that cross the footer are
        // drawn truncated (the footer fill below overdraws the rest).
        const entry_h = notifEntryHeight(win.scale);
        var entry_top = panel_top + header_h;
        var i: usize = 0;
        while (entry_top < footer_top) : ({
            i += 1;
            entry_top += entry_h;
        }) {
            const entry = win.app.notifAt(i) orelse break;
            const entry_bottom = @min(entry_top + entry_h, footer_top);

            const entry_hovered = switch (win.sidebar_hover) {
                .notif_entry => |h| h == i,
                else => false,
            };
            if (entry_hovered) {
                var hover_rect = w32.RECT{ .left = 0, .top = entry_top, .right = sidebar_w, .bottom = entry_bottom };
                if (w32.CreateSolidBrush(hover_color)) |brush| {
                    _ = w32.FillRect(mem_dc, &hover_rect, brush);
                    _ = w32.DeleteObject(@ptrCast(brush));
                }
            }

            // Kind dot, colored like the session status dots.
            _ = w32.SetTextColor(mem_dc, switch (entry.kind) {
                .bell => bell_color,
                .exited => exited_color,
                .osc => accent_color,
            });
            const dot_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{25CF}");
            var entry_dot_rect = w32.RECT{
                .left = accent_w + pad,
                .top = entry_top,
                .right = accent_w + pad + dot_w,
                .bottom = entry_bottom,
            };
            _ = w32.DrawTextW(
                mem_dc,
                dot_char,
                1,
                &entry_dot_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );

            // Two lines: title (bright) over body (dim).
            const text_left = accent_w + pad + dot_w;
            const half_h = @divTrunc(entry_h, 2);
            if (entry.title_len > 0) {
                _ = w32.SetTextColor(mem_dc, active_text_color);
                var title_rect = w32.RECT{
                    .left = text_left,
                    .top = entry_top,
                    .right = sidebar_w - pad,
                    .bottom = @min(entry_top + half_h, entry_bottom),
                };
                _ = w32.DrawTextW(
                    mem_dc,
                    @ptrCast(&entry.title),
                    @intCast(entry.title_len),
                    &title_rect,
                    w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
                );
            }
            if (entry.body_len > 0 and entry_top + half_h < entry_bottom) {
                _ = w32.SetTextColor(mem_dc, inactive_text_color);
                var body_rect = w32.RECT{
                    .left = text_left,
                    .top = entry_top + half_h,
                    .right = sidebar_w - pad,
                    .bottom = entry_bottom,
                };
                _ = w32.DrawTextW(
                    mem_dc,
                    @ptrCast(&entry.body),
                    @intCast(entry.body_len),
                    &body_rect,
                    w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
                );
            }
        }
    }

    // --- Footer strip ---
    {
        // Re-fill with the sidebar bg to overdraw any rows that ran
        // under the footer.
        var footer_rect = w32.RECT{ .left = 0, .top = footer_top, .right = sidebar_w, .bottom = client_h };
        if (w32.CreateSolidBrush(bar_color)) |brush| {
            _ = w32.FillRect(mem_dc, &footer_rect, brush);
            _ = w32.DeleteObject(@ptrCast(brush));
        }

        // Bell icon. U+1F514 falls back through GDI font linking; on
        // systems without an emoji/symbol font it may render as tofu.
        var bell_rect = bellSlotRect(footer_top, win.scale);
        const bell_hot = win.notif_panel_open or win.sidebar_hover == .bell_icon;
        _ = w32.SetTextColor(mem_dc, if (bell_hot) active_text_color else inactive_text_color);
        const bell_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{1F514}");
        _ = w32.DrawTextW(
            mem_dc,
            bell_char,
            bell_char.len,
            &bell_rect,
            w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );

        // Gear icon: U+2699 without U+FE0F so GDI keeps the text-style
        // glyph instead of the color emoji presentation.
        var gear_rect = gearSlotRect(footer_top, win.scale);
        _ = w32.SetTextColor(mem_dc, if (win.sidebar_hover == .gear_icon)
            active_text_color
        else
            inactive_text_color);
        const gear_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{2699}");
        _ = w32.DrawTextW(
            mem_dc,
            gear_char,
            gear_char.len,
            &gear_rect,
            w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );

        // Browser globe icon. Like the bell, U+1F310 relies on GDI
        // font linking for the glyph.
        var globe_rect = globeSlotRect(footer_top, win.scale);
        _ = w32.SetTextColor(mem_dc, if (win.sidebar_hover == .browser_icon)
            active_text_color
        else
            inactive_text_color);
        const globe_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{1F310}");
        _ = w32.DrawTextW(
            mem_dc,
            globe_char,
            globe_char.len,
            &globe_rect,
            w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );

        // Collapse chevron (right-aligned): runtime-hides the sidebar.
        // "‹" (U+2039) reads as "tuck the panel away to the left". A
        // text-style chevron, no tofu risk (BMP punctuation).
        var collapse_rect = collapseSlotRect(footer_top, sidebar_w, win.scale);
        _ = w32.SetTextColor(mem_dc, if (win.sidebar_hover == .collapse_toggle)
            active_text_color
        else
            inactive_text_color);
        const collapse_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{2039}");
        _ = w32.DrawTextW(
            mem_dc,
            collapse_char,
            collapse_char.len,
            &collapse_rect,
            w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );

        // Unread badge: amber square at the bell's top-right corner.
        const unread = win.app.notif_log.unread;
        if (unread > 0) {
            const badge = scaled(BADGE_BASE, win.scale);
            var badge_rect = w32.RECT{
                .left = bell_rect.right - badge + scaled(5, win.scale),
                .top = bell_rect.top - scaled(3, win.scale),
                .right = bell_rect.right + scaled(5, win.scale),
                .bottom = bell_rect.top - scaled(3, win.scale) + badge,
            };
            if (w32.CreateSolidBrush(bell_color)) |brush| {
                _ = w32.FillRect(mem_dc, &badge_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }

            var count_buf: [2]u16 = undefined;
            const count_len: u32 = if (unread > 9) blk: {
                count_buf[0] = '9';
                count_buf[1] = '+';
                break :blk 2;
            } else blk: {
                count_buf[0] = '0' + @as(u16, @intCast(unread));
                break :blk 1;
            };
            // The tab font is too tall for the badge; use a temporary
            // smaller one.
            if (w32.CreateFontW(
                -scaled(10, win.scale),
                0,
                0,
                0,
                w32.FW_NORMAL,
                0,
                0,
                0,
                w32.DEFAULT_CHARSET,
                0,
                0,
                0,
                0,
                std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
            )) |badge_font| {
                const prev_font = w32.SelectObject(mem_dc, badge_font);
                _ = w32.SetTextColor(mem_dc, w32.RGB(32, 32, 32));
                _ = w32.DrawTextW(
                    mem_dc,
                    @ptrCast(&count_buf),
                    @intCast(count_len),
                    &badge_rect,
                    w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
                );
                _ = w32.SelectObject(mem_dc, prev_font);
                _ = w32.DeleteObject(badge_font);
            }
        }
    }

    // --- BitBlt to screen ---
    _ = w32.BitBlt(hdc_screen, 0, 0, sidebar_w, client_h, mem_dc, 0, 0, w32.SRCCOPY);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// hitTest context used by the tests: scale 1.0, 400px tall, 220px
/// wide. Derived geometry: footer_top=368, panel_h=160, panel_top=208
/// (open), bell x in [8,32), gear x in [40,64), globe x in [72,96),
/// panel header y in [208,232) with Clear at x>=172, entry rows 40px
/// from y=232.
fn testCtx(ws_count: usize, panel_open: bool, notif_count: usize) HitCtx {
    return .{
        .item_h = 36,
        .workspace_count = ws_count,
        .client_h = 400,
        .width = 220,
        .scale = 1.0,
        .panel_open = panel_open,
        .notif_count = notif_count,
    };
}

test "sidebar hitTest: rows map to workspaces" {
    const ctx = testCtx(3, false, 0);
    try testing.expectEqual(HitTarget{ .workspace = 0 }, hitTest(10, 0, ctx));
    try testing.expectEqual(HitTarget{ .workspace = 0 }, hitTest(10, 35, ctx));
    try testing.expectEqual(HitTarget{ .workspace = 2 }, hitTest(10, 2 * 36, ctx));
}

test "sidebar hitTest: row boundary belongs to the lower row" {
    // y == item_h is the first pixel of row 1, not part of row 0.
    try testing.expectEqual(HitTarget{ .workspace = 1 }, hitTest(10, 36, testCtx(3, false, 0)));
}

test "sidebar hitTest: row close band takes priority over the row body" {
    // Close 'x' band: x in [width-pad-cw, width-pad) = [192, 212) at
    // the test geometry (pad=8, cw=20). The rest of the row is body,
    // including the strip right of the band (x>=212) and left of it.
    const ctx = testCtx(3, false, 0);
    try testing.expectEqual(HitTarget{ .workspace = 0 }, hitTest(191, 0, ctx));
    try testing.expectEqual(HitTarget{ .row_close = 0 }, hitTest(192, 0, ctx));
    try testing.expectEqual(HitTarget{ .row_close = 0 }, hitTest(211, 35, ctx));
    try testing.expectEqual(HitTarget{ .workspace = 0 }, hitTest(212, 0, ctx));
    try testing.expectEqual(HitTarget{ .workspace = 0 }, hitTest(219, 0, ctx));
}

test "sidebar hitTest: close band is per-row" {
    const ctx = testCtx(3, false, 0);
    try testing.expectEqual(HitTarget{ .row_close = 1 }, hitTest(200, 36, ctx));
    try testing.expectEqual(HitTarget{ .row_close = 2 }, hitTest(200, 2 * 36, ctx));
    // No close band on the "+ New session" row — that x is the chevron.
    try testing.expectEqual(@as(HitTarget, .new_session_dropdown), hitTest(200, 3 * 36, ctx));
}

test "sidebar rowCloseRect: square right-aligned and centered in the row" {
    // Row 1 spans y [36,72); a 20px square centered there is y [44,64),
    // right-aligned to the text pad at x [192,212) (pad=8, cw=20).
    const r = rowCloseRect(1, 220, 36, 1.0);
    try testing.expectEqual(@as(i32, 192), r.left);
    try testing.expectEqual(@as(i32, 212), r.right);
    try testing.expectEqual(@as(i32, 44), r.top);
    try testing.expectEqual(@as(i32, 64), r.bottom);
}

test "sidebar rowCloseRect: scales with DPI and agrees with hitTest" {
    // At 2.0 scale, width 440: pad=16, cw=40 — close x in [384, 424).
    const ctx: HitCtx = .{
        .item_h = 72,
        .workspace_count = 2,
        .client_h = 800,
        .width = 440,
        .scale = 2.0,
        .panel_open = false,
        .notif_count = 0,
    };
    const r = rowCloseRect(0, 440, 72, 2.0);
    try testing.expectEqual(@as(i32, 384), r.left);
    try testing.expectEqual(@as(i32, 424), r.right);
    try testing.expectEqual(HitTarget{ .workspace = 0 }, hitTest(383, 0, ctx));
    try testing.expectEqual(HitTarget{ .row_close = 0 }, hitTest(384, 0, ctx));
    try testing.expectEqual(HitTarget{ .row_close = 0 }, hitTest(423, 71, ctx));
    try testing.expectEqual(HitTarget{ .workspace = 0 }, hitTest(424, 0, ctx));
}

test "sidebar rowCloseRect clears the resize edge band" {
    // WM_LBUTTONDOWN tests the edge band before the sidebar, so the
    // close 'x' must end at or left of the band at any scale.
    const scales = [_]f32{ 1.0, 1.25, 1.5, 1.75, 2.0 };
    for (scales) |s| {
        const r = rowCloseRect(0, 300, itemHeight(s), s);
        try testing.expect(r.right <= 300 - edgeBandWidth(s));
    }
}

test "sidebar hitTest: new session row directly below sessions" {
    const ctx = testCtx(3, false, 0);
    try testing.expectEqual(@as(HitTarget, .new_session), hitTest(10, 3 * 36, ctx));
    try testing.expectEqual(@as(HitTarget, .new_session), hitTest(10, 4 * 36 - 1, ctx));
}

test "sidebar hitTest: new session dropdown chevron band" {
    // Chevron: x in [width-pad-dd, width-pad) = [188, 212) at the test
    // geometry; the rest of the row is the body, including the strip
    // right of the chevron.
    const ctx = testCtx(3, false, 0);
    try testing.expectEqual(@as(HitTarget, .new_session), hitTest(187, 3 * 36, ctx));
    try testing.expectEqual(@as(HitTarget, .new_session_dropdown), hitTest(188, 3 * 36, ctx));
    try testing.expectEqual(@as(HitTarget, .new_session_dropdown), hitTest(211, 4 * 36 - 1, ctx));
    try testing.expectEqual(@as(HitTarget, .new_session), hitTest(212, 3 * 36, ctx));
    try testing.expectEqual(@as(HitTarget, .new_session), hitTest(219, 3 * 36, ctx));
}

test "sidebar hitTest: dropdown band only exists on the new session row" {
    const ctx = testCtx(3, false, 0);
    // An x in the chevron band on a session row is not the dropdown:
    // it is either the row body or (in the close band) the close 'x',
    // never .new_session_dropdown.
    const body = hitTest(160, 0, ctx);
    try testing.expectEqual(HitTarget{ .workspace = 0 }, body);
    const close = hitTest(200, 0, ctx);
    try testing.expectEqual(HitTarget{ .row_close = 0 }, close);
    // And below the new-session row it stays none.
    try testing.expectEqual(@as(HitTarget, .none), hitTest(200, 4 * 36, ctx));
}

test "sidebar hitTest: zero tabs dropdown on row 0" {
    const ctx = testCtx(0, false, 0);
    try testing.expectEqual(@as(HitTarget, .new_session_dropdown), hitTest(200, 0, ctx));
    try testing.expectEqual(@as(HitTarget, .new_session), hitTest(100, 0, ctx));
}

test "sidebar newSessionDropdownRect: square right-aligned and centered in the row" {
    // Row 3 spans y [108,144); a 24px square centered there is
    // y [114,138), right-aligned to the text pad at x [188,212).
    const r = newSessionDropdownRect(3, 220, 36, 1.0);
    try testing.expectEqual(@as(i32, 188), r.left);
    try testing.expectEqual(@as(i32, 212), r.right);
    try testing.expectEqual(@as(i32, 114), r.top);
    try testing.expectEqual(@as(i32, 138), r.bottom);
}

test "sidebar newSessionDropdownRect: scales with DPI and agrees with hitTest" {
    // At 2.0 scale, width 440: pad=16, dd=48 — chevron x in [376, 424).
    const ctx: HitCtx = .{
        .item_h = 72,
        .workspace_count = 2,
        .client_h = 800,
        .width = 440,
        .scale = 2.0,
        .panel_open = false,
        .notif_count = 0,
    };
    const r = newSessionDropdownRect(2, 440, 72, 2.0);
    try testing.expectEqual(@as(i32, 376), r.left);
    try testing.expectEqual(@as(i32, 424), r.right);
    try testing.expectEqual(@as(HitTarget, .new_session), hitTest(375, 2 * 72, ctx));
    try testing.expectEqual(@as(HitTarget, .new_session_dropdown), hitTest(376, 2 * 72, ctx));
    try testing.expectEqual(@as(HitTarget, .new_session_dropdown), hitTest(423, 3 * 72 - 1, ctx));
    try testing.expectEqual(@as(HitTarget, .new_session), hitTest(424, 2 * 72, ctx));
}

test "sidebar dropdown chevron clears the resize edge band" {
    // WM_LBUTTONDOWN tests the edge band before the sidebar, so the
    // chevron must end at or left of the band at any scale.
    const scales = [_]f32{ 1.0, 1.25, 1.5, 1.75, 2.0 };
    for (scales) |s| {
        const r = newSessionDropdownRect(0, 300, itemHeight(s), s);
        try testing.expect(r.right <= 300 - edgeBandWidth(s));
    }
}

test "sidebar hitTest: below the new session row is none" {
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 4 * 36, testCtx(3, false, 0)));
}

test "sidebar hitTest: zero tabs" {
    // With no sessions, row 0 is the "+ New session" row.
    const ctx = testCtx(0, false, 0);
    try testing.expectEqual(@as(HitTarget, .new_session), hitTest(10, 0, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 36, ctx));
}

test "sidebar hitTest: negative y is none" {
    const ctx = testCtx(3, false, 0);
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, -1, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, -100, ctx));
}

test "sidebar hitTest: y at or below the client bottom is none" {
    const ctx = testCtx(3, false, 0);
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 400, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 500, ctx));
}

test "sidebar hitTest: negative x is none" {
    // Capture-driven mouse messages can deliver negative client x; a
    // row/footer/panel y must not resolve a target there.
    const ctx = testCtx(3, true, 2);
    try testing.expectEqual(@as(HitTarget, .none), hitTest(-1, 0, ctx)); // row 0 body
    try testing.expectEqual(@as(HitTarget, .none), hitTest(-100, 35, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(-1, 3 * 36, ctx)); // new session row
    try testing.expectEqual(@as(HitTarget, .none), hitTest(-1, 232, ctx)); // panel entry 0
    try testing.expectEqual(@as(HitTarget, .none), hitTest(-1, 368, ctx)); // footer strip
}

test "sidebar hitTest: x at or beyond the width is none" {
    // x == width is the first out-of-strip pixel (the strip spans
    // [0, width), like the rows span [top, bottom)); the row body used
    // to extend to any x >= width.
    const ctx = testCtx(3, true, 2);
    try testing.expectEqual(@as(HitTarget, .none), hitTest(220, 0, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(500, 35, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(220, 3 * 36, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(220, 208, ctx)); // panel header / Clear y
    try testing.expectEqual(@as(HitTarget, .none), hitTest(220, 368, ctx));
    // The last in-strip x still resolves (boundary partner).
    try testing.expectEqual(HitTarget{ .workspace = 0 }, hitTest(219, 0, ctx));
}

test "sidebar hitTest: zero width (hidden sidebar) is none everywhere" {
    var ctx = testCtx(3, false, 0);
    ctx.width = 0;
    try testing.expectEqual(@as(HitTarget, .none), hitTest(0, 0, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 100, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(8, 368, ctx));
}

test "sidebar hitTest: footer bell and gear slots" {
    const ctx = testCtx(3, false, 0);
    // Bell: x in [8, 32).
    try testing.expectEqual(@as(HitTarget, .none), hitTest(7, 368, ctx));
    try testing.expectEqual(@as(HitTarget, .bell_icon), hitTest(8, 368, ctx));
    try testing.expectEqual(@as(HitTarget, .bell_icon), hitTest(31, 399, ctx));
    // Gap between the slots.
    try testing.expectEqual(@as(HitTarget, .none), hitTest(32, 368, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(39, 368, ctx));
    // Gear: x in [40, 64).
    try testing.expectEqual(@as(HitTarget, .gear_icon), hitTest(40, 368, ctx));
    try testing.expectEqual(@as(HitTarget, .gear_icon), hitTest(63, 368, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(64, 368, ctx));
    // Gap, then globe: x in [72, 96).
    try testing.expectEqual(@as(HitTarget, .none), hitTest(71, 368, ctx));
    try testing.expectEqual(@as(HitTarget, .browser_icon), hitTest(72, 368, ctx));
    try testing.expectEqual(@as(HitTarget, .browser_icon), hitTest(95, 399, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(96, 368, ctx));
}

test "sidebar hitTest: footer collapse chevron (right-aligned slot)" {
    const ctx = testCtx(3, false, 0);
    // width=220, pad=8, icon=24 -> collapse slot x in [188, 212).
    // Just left of the slot is a miss (no left-cluster icon reaches here).
    try testing.expectEqual(@as(HitTarget, .none), hitTest(187, 368, ctx));
    try testing.expectEqual(@as(HitTarget, .collapse_toggle), hitTest(188, 368, ctx));
    try testing.expectEqual(@as(HitTarget, .collapse_toggle), hitTest(211, 399, ctx));
    // The pad gap right of the slot, before the strip edge, is a miss.
    try testing.expectEqual(@as(HitTarget, .none), hitTest(212, 368, ctx));
    // The collapse slot never collides with the left cluster (globe ends
    // at x=96), so the globe still resolves.
    try testing.expectEqual(@as(HitTarget, .browser_icon), hitTest(72, 368, ctx));
}

test "collapseSlotRect: right-aligned square in the footer" {
    // footer_top=368 at client_h=400 (footerHeight 32); pad=8, icon=24.
    const r = collapseSlotRect(368, 220, 1.0);
    try testing.expectEqual(@as(i32, 188), r.left); // 220 - 8 - 24
    try testing.expectEqual(@as(i32, 212), r.right); // 220 - 8
    try testing.expectEqual(@as(i32, 24), r.right - r.left);
    try testing.expectEqual(@as(i32, 24), r.bottom - r.top);
}

test "sidebar hitTest: footer boundary clips the row area" {
    // y=368 is the first footer pixel; y=367 is still row territory
    // (row 10 with 36px rows — past the tab rows, so .none).
    const ctx = testCtx(3, false, 0);
    try testing.expectEqual(@as(HitTarget, .bell_icon), hitTest(10, 368, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 367, ctx));
}

test "sidebar hitTest: closed panel area behaves as row space" {
    // With the panel closed, y in [208, 368) is plain row space.
    const ctx = testCtx(10, false, 5);
    try testing.expectEqual(HitTarget{ .workspace = 6 }, hitTest(10, 220, ctx));
}

test "sidebar hitTest: open panel covers the row area beneath it" {
    // Rows end at panel_top=208: y=207 is row 5, y=208 is the panel
    // header (not Clear at x=10).
    const ctx = testCtx(10, true, 5);
    try testing.expectEqual(HitTarget{ .workspace = 5 }, hitTest(10, 207, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 208, ctx));
}

test "sidebar hitTest: panel header Clear button is right-aligned" {
    // Clear zone: x >= width-48 = 172, header y in [208, 232).
    const ctx = testCtx(3, true, 5);
    try testing.expectEqual(@as(HitTarget, .none), hitTest(171, 208, ctx));
    try testing.expectEqual(@as(HitTarget, .notif_clear), hitTest(172, 208, ctx));
    try testing.expectEqual(@as(HitTarget, .notif_clear), hitTest(219, 231, ctx));
    // First entry pixel is no longer the header.
    try testing.expectEqual(HitTarget{ .notif_entry = 0 }, hitTest(219, 232, ctx));
}

test "sidebar hitTest: panel entries stack newest-first below the header" {
    // Entries are 40px: entry 0 in [232, 272), entry 1 in [272, 312).
    const ctx = testCtx(3, true, 2);
    try testing.expectEqual(HitTarget{ .notif_entry = 0 }, hitTest(10, 232, ctx));
    try testing.expectEqual(HitTarget{ .notif_entry = 0 }, hitTest(10, 271, ctx));
    try testing.expectEqual(HitTarget{ .notif_entry = 1 }, hitTest(10, 272, ctx));
    // Beyond the log: empty panel space.
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 312, ctx));
}

test "sidebar hitTest: partially clipped entry is hittable above the footer" {
    // Entry 3 spans [352, 392) but the footer starts at 368; only the
    // visible band hits.
    const ctx = testCtx(3, true, 8);
    try testing.expectEqual(HitTarget{ .notif_entry = 3 }, hitTest(100, 360, ctx));
    try testing.expectEqual(HitTarget{ .notif_entry = 3 }, hitTest(100, 367, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(100, 368, ctx));
}

test "sidebar footerHeight and panelHeight scale" {
    try testing.expectEqual(@as(i32, 32), footerHeight(1.0));
    try testing.expectEqual(@as(i32, 48), footerHeight(1.5));
    try testing.expectEqual(@as(i32, 64), footerHeight(2.0));
    try testing.expectEqual(@as(i32, 160), panelHeight(400));
    try testing.expectEqual(@as(i32, 0), panelHeight(0));
}

test "sidebar footer slots: hitTest x range matches the painted rects" {
    const bell = bellSlotRect(368, 1.0);
    const gear = gearSlotRect(368, 1.0);
    const globe = globeSlotRect(368, 1.0);
    try testing.expectEqual(@as(i32, 8), bell.left);
    try testing.expectEqual(@as(i32, 32), bell.right);
    try testing.expectEqual(@as(i32, 40), gear.left);
    try testing.expectEqual(@as(i32, 64), gear.right);
    try testing.expectEqual(@as(i32, 72), globe.left);
    try testing.expectEqual(@as(i32, 96), globe.right);
    // Icons are vertically centered in the 32px footer.
    try testing.expectEqual(@as(i32, 372), bell.top);
    try testing.expectEqual(@as(i32, 396), bell.bottom);
    try testing.expectEqual(@as(i32, 372), globe.top);
    try testing.expectEqual(@as(i32, 396), globe.bottom);
}

test "sidebar hitTest: globe slot scales with DPI" {
    // At 2.0 scale: pad=16, icon=48 — globe x in [144, 192),
    // footer_top = 800 - 64 = 736.
    const ctx: HitCtx = .{
        .item_h = 72,
        .workspace_count = 2,
        .client_h = 800,
        .width = 440,
        .scale = 2.0,
        .panel_open = false,
        .notif_count = 0,
    };
    try testing.expectEqual(@as(HitTarget, .none), hitTest(143, 736, ctx));
    try testing.expectEqual(@as(HitTarget, .browser_icon), hitTest(144, 736, ctx));
    try testing.expectEqual(@as(HitTarget, .browser_icon), hitTest(191, 799, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(192, 736, ctx));
    const globe = globeSlotRect(736, 2.0);
    try testing.expectEqual(@as(i32, 144), globe.left);
    try testing.expectEqual(@as(i32, 192), globe.right);
}

test "sidebar itemRect: first row spans the full width" {
    const r = itemRect(0, 220, 36);
    try testing.expectEqual(@as(i32, 0), r.left);
    try testing.expectEqual(@as(i32, 0), r.top);
    try testing.expectEqual(@as(i32, 220), r.right);
    try testing.expectEqual(@as(i32, 36), r.bottom);
}

test "sidebar itemRect: rows stack by item height" {
    const r = itemRect(2, 220, 36);
    try testing.expectEqual(@as(i32, 72), r.top);
    try testing.expectEqual(@as(i32, 108), r.bottom);
}

test "sidebar hitTest and itemRect agree on row bounds" {
    const ctx = testCtx(5, false, 0);
    for (0..4) |i| {
        const r = itemRect(i, 220, ctx.item_h);
        try testing.expectEqual(HitTarget{ .workspace = i }, hitTest(10, r.top, ctx));
        try testing.expectEqual(HitTarget{ .workspace = i }, hitTest(10, r.bottom - 1, ctx));
    }
}

test "sidebar hitTestEdge: band ends at the edge" {
    try testing.expect(hitTestEdge(215, 220, 5));
    try testing.expect(hitTestEdge(219, 220, 5));
    try testing.expect(!hitTestEdge(220, 220, 5));
    try testing.expect(!hitTestEdge(214, 220, 5));
}

test "sidebar hitTestEdge: hidden sidebar has no band" {
    try testing.expect(!hitTestEdge(0, 0, 5));
    try testing.expect(!hitTestEdge(-3, 0, 5));
    try testing.expect(!hitTestEdge(-1, -10, 5));
}

test "sidebar edgeBandWidth: scales with DPI" {
    try testing.expectEqual(@as(i32, 5), edgeBandWidth(1.0));
    try testing.expectEqual(@as(i32, 8), edgeBandWidth(1.5));
    try testing.expectEqual(@as(i32, 10), edgeBandWidth(2.0));
}

// ---------------------------------------------------------------------------
// Scale-matrix tests: the same boundary assertions at 1.0/1.25/1.5/2.0.
// ---------------------------------------------------------------------------

/// Expected pixel value of each scaled metric at the matrix scales,
/// hard-coded independently of `scaled()` so a rounding regression
/// there (e.g. trunc instead of round) fails these tests.
const ScaleGeom = struct {
    scale: f32,
    pad: i32,
    icon: i32,
    close: i32,
    dd: i32,
    header: i32,
    entry: i32,
    clear_w: i32,
    band: i32,
    item_h: i32,
    footer_h: i32,
    drag: i32,
};

const scale_matrix = [_]ScaleGeom{
    .{ .scale = 1.0, .pad = 8, .icon = 24, .close = 20, .dd = 24, .header = 24, .entry = 40, .clear_w = 48, .band = 5, .item_h = 36, .footer_h = 32, .drag = 5 },
    .{ .scale = 1.25, .pad = 10, .icon = 30, .close = 25, .dd = 30, .header = 30, .entry = 50, .clear_w = 60, .band = 6, .item_h = 45, .footer_h = 40, .drag = 6 },
    .{ .scale = 1.5, .pad = 12, .icon = 36, .close = 30, .dd = 36, .header = 36, .entry = 60, .clear_w = 72, .band = 8, .item_h = 54, .footer_h = 48, .drag = 8 },
    .{ .scale = 2.0, .pad = 16, .icon = 48, .close = 40, .dd = 48, .header = 48, .entry = 80, .clear_w = 96, .band = 10, .item_h = 72, .footer_h = 64, .drag = 10 },
};

/// hitTest context at a matrix scale: `rows_h` rows worth of client
/// height above the footer plus the footer strip itself, so
/// footer_top == rows_h * item_h exactly.
fn matrixCtx(g: ScaleGeom, ws_count: usize, rows_h: i32, width: i32, panel_open: bool, notif_count: usize) HitCtx {
    return .{
        .item_h = g.item_h,
        .workspace_count = ws_count,
        .client_h = rows_h * g.item_h + g.footer_h,
        .width = width,
        .scale = g.scale,
        .panel_open = panel_open,
        .notif_count = notif_count,
    };
}

test "sidebar scale matrix: table matches the scaled helpers" {
    for (scale_matrix) |g| {
        try testing.expectEqual(g.item_h, itemHeight(g.scale));
        try testing.expectEqual(g.footer_h, footerHeight(g.scale));
        try testing.expectEqual(g.band, edgeBandWidth(g.scale));
        try testing.expectEqual(g.entry, notifEntryHeight(g.scale));
        try testing.expectEqual(g.pad, scaled(PAD_BASE, g.scale));
        try testing.expectEqual(g.icon, scaled(FOOTER_ICON_BASE, g.scale));
        try testing.expectEqual(g.close, scaled(CLOSE_BASE, g.scale));
        try testing.expectEqual(g.dd, scaled(DROPDOWN_BASE, g.scale));
        try testing.expectEqual(g.header, scaled(NOTIF_HEADER_BASE, g.scale));
        try testing.expectEqual(g.clear_w, scaled(NOTIF_CLEAR_W_BASE, g.scale));
    }
}

test "sidebar dragThreshold: scales with DPI across the matrix" {
    for (scale_matrix) |g| {
        try testing.expectEqual(g.drag, dragThreshold(g.scale));
    }
    // 5px at 1.0 to match the tab bar's threshold; 7.5 at 1.5 rounds
    // half away from zero to 8, never truncating below the 1.0 value.
    try testing.expectEqual(@as(i32, 5), dragThreshold(1.0));
    try testing.expectEqual(@as(i32, 8), dragThreshold(1.5));
}

test "sidebar hitTest matrix: row body vs close band at every scale" {
    for (scale_matrix) |g| {
        const width: i32 = 300;
        const ctx = matrixCtx(g, 3, 6, width, false, 0);
        const cl = width - g.pad - g.close;
        const cr = width - g.pad;
        for (0..3) |row| {
            const top = @as(i32, @intCast(row)) * g.item_h;
            const ys = [_]i32{ top, top + g.item_h - 1 };
            for (ys) |y| {
                try testing.expectEqual(HitTarget{ .workspace = row }, hitTest(0, y, ctx));
                try testing.expectEqual(HitTarget{ .workspace = row }, hitTest(cl - 1, y, ctx));
                try testing.expectEqual(HitTarget{ .row_close = row }, hitTest(cl, y, ctx));
                try testing.expectEqual(HitTarget{ .row_close = row }, hitTest(cr - 1, y, ctx));
                try testing.expectEqual(HitTarget{ .workspace = row }, hitTest(cr, y, ctx));
                try testing.expectEqual(HitTarget{ .workspace = row }, hitTest(width - 1, y, ctx));
            }
        }
        // Last row's close band vs the new-session dropdown right below:
        // one pixel down at the same x flips row_close -> dropdown.
        const last_y = 3 * g.item_h - 1;
        try testing.expectEqual(HitTarget{ .row_close = 2 }, hitTest(cr - 1, last_y, ctx));
        try testing.expectEqual(@as(HitTarget, .new_session_dropdown), hitTest(cr - 1, last_y + 1, ctx));
    }
}

test "sidebar rowCloseRect: paint rect equals the hit band at every scale" {
    for (scale_matrix) |g| {
        const width: i32 = 300;
        const ctx = matrixCtx(g, 4, 8, width, false, 0);
        for (0..4) |row| {
            const r = rowCloseRect(row, width, g.item_h, g.scale);
            // x extents match hitTest's close band exactly.
            try testing.expectEqual(width - g.pad - g.close, r.left);
            try testing.expectEqual(width - g.pad, r.right);
            // Square, vertically centered in the row.
            const row_rect = itemRect(row, width, g.item_h);
            try testing.expectEqual(g.close, r.right - r.left);
            try testing.expectEqual(g.close, r.bottom - r.top);
            try testing.expectEqual(row_rect.top + @divTrunc(g.item_h - g.close, 2), r.top);
            // Every painted x hits the close target; both neighbors miss.
            const mid_y = row_rect.top + @divTrunc(g.item_h, 2);
            var x = r.left;
            while (x < r.right) : (x += 1) {
                try testing.expectEqual(HitTarget{ .row_close = row }, hitTest(x, mid_y, ctx));
            }
            try testing.expectEqual(HitTarget{ .workspace = row }, hitTest(r.left - 1, mid_y, ctx));
            try testing.expectEqual(HitTarget{ .workspace = row }, hitTest(r.right, mid_y, ctx));
        }
    }
}

test "sidebar hitTest matrix: new session vs dropdown at every scale" {
    for (scale_matrix) |g| {
        const width: i32 = 300;
        const ctx = matrixCtx(g, 2, 6, width, false, 0);
        const dl = width - g.pad - g.dd;
        const dr = width - g.pad;
        const top = 2 * g.item_h;
        const ys = [_]i32{ top, top + g.item_h - 1 };
        for (ys) |y| {
            try testing.expectEqual(@as(HitTarget, .new_session), hitTest(0, y, ctx));
            try testing.expectEqual(@as(HitTarget, .new_session), hitTest(dl - 1, y, ctx));
            try testing.expectEqual(@as(HitTarget, .new_session_dropdown), hitTest(dl, y, ctx));
            try testing.expectEqual(@as(HitTarget, .new_session_dropdown), hitTest(dr - 1, y, ctx));
            try testing.expectEqual(@as(HitTarget, .new_session), hitTest(dr, y, ctx));
            try testing.expectEqual(@as(HitTarget, .new_session), hitTest(width - 1, y, ctx));
        }
        // One pixel above the row at the dropdown's right edge is the
        // last row's close band (the close band nests inside the wider
        // dropdown band's x-range).
        try testing.expectEqual(HitTarget{ .row_close = 1 }, hitTest(dr - 1, top - 1, ctx));
        // The dropdown's LEFT edge x on the row above is row BODY:
        // dd > close at every scale, so that x is left of the close band.
        try testing.expect(g.dd > g.close);
        try testing.expectEqual(HitTarget{ .workspace = 1 }, hitTest(dl, top - 1, ctx));
        // One pixel below the row is dead space.
        try testing.expectEqual(@as(HitTarget, .none), hitTest(dr - 1, top + g.item_h, ctx));
    }
}

test "sidebar newSessionDropdownRect: paint rect equals the hit band at every scale" {
    for (scale_matrix) |g| {
        const width: i32 = 300;
        for ([_]usize{ 0, 1, 5, 16 }) |ws_count| {
            const rows_h: i32 = @intCast(ws_count + 3);
            const ctx = matrixCtx(g, ws_count, rows_h, width, false, 0);
            const r = newSessionDropdownRect(ws_count, width, g.item_h, g.scale);
            try testing.expectEqual(width - g.pad - g.dd, r.left);
            try testing.expectEqual(width - g.pad, r.right);
            try testing.expectEqual(g.dd, r.right - r.left);
            try testing.expectEqual(g.dd, r.bottom - r.top);
            const row_rect = itemRect(ws_count, width, g.item_h);
            try testing.expectEqual(row_rect.top + @divTrunc(g.item_h - g.dd, 2), r.top);
            // Every painted x hits the dropdown; both neighbors are body.
            const mid_y = row_rect.top + @divTrunc(g.item_h, 2);
            var x = r.left;
            while (x < r.right) : (x += 1) {
                try testing.expectEqual(@as(HitTarget, .new_session_dropdown), hitTest(x, mid_y, ctx));
            }
            try testing.expectEqual(@as(HitTarget, .new_session), hitTest(r.left - 1, mid_y, ctx));
            try testing.expectEqual(@as(HitTarget, .new_session), hitTest(r.right, mid_y, ctx));
        }
    }
}

test "sidebar hitTest matrix: footer slot boundaries at every scale" {
    for (scale_matrix) |g| {
        const ctx = matrixCtx(g, 2, 6, 300, false, 0);
        const footer_top = ctx.client_h - g.footer_h;
        const bell_l = g.pad;
        const gear_l = g.pad + g.icon + g.pad;
        const globe_l = (g.pad + g.icon) * 2 + g.pad;
        // The slots span the full strip height: same answers at the
        // first and last footer pixel rows.
        const ys = [_]i32{ footer_top, ctx.client_h - 1 };
        for (ys) |y| {
            try testing.expectEqual(@as(HitTarget, .none), hitTest(bell_l - 1, y, ctx));
            try testing.expectEqual(@as(HitTarget, .bell_icon), hitTest(bell_l, y, ctx));
            try testing.expectEqual(@as(HitTarget, .bell_icon), hitTest(bell_l + g.icon - 1, y, ctx));
            try testing.expectEqual(@as(HitTarget, .none), hitTest(bell_l + g.icon, y, ctx));
            try testing.expectEqual(@as(HitTarget, .none), hitTest(gear_l - 1, y, ctx));
            try testing.expectEqual(@as(HitTarget, .gear_icon), hitTest(gear_l, y, ctx));
            try testing.expectEqual(@as(HitTarget, .gear_icon), hitTest(gear_l + g.icon - 1, y, ctx));
            try testing.expectEqual(@as(HitTarget, .none), hitTest(gear_l + g.icon, y, ctx));
            try testing.expectEqual(@as(HitTarget, .none), hitTest(globe_l - 1, y, ctx));
            try testing.expectEqual(@as(HitTarget, .browser_icon), hitTest(globe_l, y, ctx));
            try testing.expectEqual(@as(HitTarget, .browser_icon), hitTest(globe_l + g.icon - 1, y, ctx));
            try testing.expectEqual(@as(HitTarget, .none), hitTest(globe_l + g.icon, y, ctx));
        }
        // One pixel above the footer is row space (past the rows here),
        // and the first y past the client is dead.
        try testing.expectEqual(@as(HitTarget, .none), hitTest(bell_l, footer_top - 1, ctx));
        try testing.expectEqual(@as(HitTarget, .none), hitTest(bell_l, ctx.client_h, ctx));
    }
}

test "sidebar footer slot rects: paint geometry equals the hit bands at every scale" {
    for (scale_matrix) |g| {
        const ctx = matrixCtx(g, 2, 6, 300, false, 0);
        const footer_top = ctx.client_h - g.footer_h;
        const bell = bellSlotRect(footer_top, g.scale);
        const gear = gearSlotRect(footer_top, g.scale);
        const globe = globeSlotRect(footer_top, g.scale);
        const slots = [_]struct { r: w32.RECT, hit: HitTarget }{
            .{ .r = bell, .hit = .bell_icon },
            .{ .r = gear, .hit = .gear_icon },
            .{ .r = globe, .hit = .browser_icon },
        };
        for (slots) |slot| {
            // Square icon, vertically centered in the footer strip.
            try testing.expectEqual(g.icon, slot.r.right - slot.r.left);
            try testing.expectEqual(g.icon, slot.r.bottom - slot.r.top);
            try testing.expectEqual(footer_top + @divTrunc(g.footer_h - g.icon, 2), slot.r.top);
            // Every painted x hits the slot; both x neighbors miss.
            var x = slot.r.left;
            while (x < slot.r.right) : (x += 1) {
                try testing.expectEqual(slot.hit, hitTest(x, footer_top, ctx));
            }
            try testing.expectEqual(@as(HitTarget, .none), hitTest(slot.r.left - 1, footer_top, ctx));
            try testing.expectEqual(@as(HitTarget, .none), hitTest(slot.r.right, footer_top, ctx));
        }
        // Slots are disjoint left-to-right with a pad-wide gap.
        try testing.expectEqual(bell.right + g.pad, gear.left);
        try testing.expectEqual(gear.right + g.pad, globe.left);
    }
}

test "sidebar hitTest matrix: rows, panel, footer vertical precedence at every scale" {
    for (scale_matrix) |g| {
        const width: i32 = 300;
        const ctx = matrixCtx(g, 16, 10, width, true, 4);
        const footer_top = ctx.client_h - g.footer_h;
        const panel_top = footer_top - panelHeight(ctx.client_h);

        // Just above the panel is still a workspace row.
        const row_above: usize = @intCast(@divTrunc(panel_top - 1, g.item_h));
        try testing.expect(row_above < 16);
        try testing.expectEqual(HitTarget{ .workspace = row_above }, hitTest(10, panel_top - 1, ctx));

        // First panel pixel is the header (x=10 is left of Clear).
        try testing.expectEqual(@as(HitTarget, .none), hitTest(10, panel_top, ctx));

        // Last pixel above the footer is the last visible (clipped)
        // entry; the footer takes over exactly at footer_top.
        const e0 = panel_top + g.header;
        const last_idx: usize = @intCast(@divTrunc(footer_top - 1 - e0, g.entry));
        try testing.expect(last_idx < 4);
        try testing.expectEqual(HitTarget{ .notif_entry = last_idx }, hitTest(10, footer_top - 1, ctx));
        try testing.expectEqual(@as(HitTarget, .bell_icon), hitTest(g.pad, footer_top, ctx));

        // A row whose rect starts inside the open panel is not hittable
        // as a workspace even though its itemRect is inside the client...
        const covered = row_above + 1;
        const covered_rect = itemRect(covered, width, g.item_h);
        try testing.expect(covered_rect.top >= panel_top);
        try testing.expect(std.meta.activeTag(hitTest(10, covered_rect.top, ctx)) != .workspace);

        // ...but with the panel closed the same pixel is that row again.
        const ctx_closed = matrixCtx(g, 16, 10, width, false, 0);
        try testing.expectEqual(HitTarget{ .workspace = covered }, hitTest(10, covered_rect.top, ctx_closed));
    }
}

test "sidebar hitTest matrix: footer clips overflowing rows at every scale" {
    for (scale_matrix) |g| {
        // 16 rows would need 16*item_h of height; only 10 fit above the
        // footer at this client height.
        const ctx = matrixCtx(g, 16, 10, 300, false, 0);
        const footer_top = ctx.client_h - g.footer_h;
        try testing.expectEqual(HitTarget{ .workspace = 9 }, hitTest(g.pad, footer_top - 1, ctx));
        try testing.expectEqual(@as(HitTarget, .bell_icon), hitTest(g.pad, footer_top, ctx));
        // Row 10's rect starts exactly at footer_top: fully clipped.
        const r10 = itemRect(10, 300, g.item_h);
        try testing.expectEqual(footer_top, r10.top);
        try testing.expect(std.meta.activeTag(hitTest(g.pad, r10.top, ctx)) != .workspace);
    }
}

test "sidebar hitTest matrix: panel header and Clear boundaries at every scale" {
    for (scale_matrix) |g| {
        const width: i32 = 300;
        const ctx = matrixCtx(g, 3, 10, width, true, 2);
        const footer_top = ctx.client_h - g.footer_h;
        const panel_top = footer_top - panelHeight(ctx.client_h);
        const clear_l = width - g.clear_w;
        const header_ys = [_]i32{ panel_top, panel_top + g.header - 1 };
        for (header_ys) |y| {
            try testing.expectEqual(@as(HitTarget, .none), hitTest(0, y, ctx));
            try testing.expectEqual(@as(HitTarget, .none), hitTest(clear_l - 1, y, ctx));
            try testing.expectEqual(@as(HitTarget, .notif_clear), hitTest(clear_l, y, ctx));
            try testing.expectEqual(@as(HitTarget, .notif_clear), hitTest(width - 1, y, ctx));
        }
        // First entry pixel below the header: the Clear x hits entry 0.
        try testing.expectEqual(HitTarget{ .notif_entry = 0 }, hitTest(clear_l, panel_top + g.header, ctx));
        // Zero notifications: entry space is inert, Clear still hittable.
        const ctx0 = matrixCtx(g, 3, 10, width, true, 0);
        try testing.expectEqual(@as(HitTarget, .none), hitTest(10, panel_top + g.header, ctx0));
        try testing.expectEqual(@as(HitTarget, .notif_clear), hitTest(width - 1, panel_top, ctx0));
    }
}

test "sidebar hitTest matrix: notif entry boundaries and count clamp at every scale" {
    for (scale_matrix) |g| {
        const ctx = matrixCtx(g, 3, 10, 300, true, 3);
        const footer_top = ctx.client_h - g.footer_h;
        const panel_top = footer_top - panelHeight(ctx.client_h);
        const e0 = panel_top + g.header;
        // Entries stack newest-first, entry_h tall, below the header.
        try testing.expectEqual(HitTarget{ .notif_entry = 0 }, hitTest(10, e0, ctx));
        try testing.expectEqual(HitTarget{ .notif_entry = 0 }, hitTest(10, e0 + g.entry - 1, ctx));
        try testing.expectEqual(HitTarget{ .notif_entry = 1 }, hitTest(10, e0 + g.entry, ctx));
        try testing.expectEqual(HitTarget{ .notif_entry = 2 }, hitTest(10, e0 + 2 * g.entry, ctx));
        // idx == notif_count is dead panel space. The slot must still be
        // above the footer here so the clamp (not the footer) decides.
        const e3 = e0 + 3 * g.entry;
        try testing.expect(e3 < footer_top);
        try testing.expectEqual(@as(HitTarget, .none), hitTest(10, e3, ctx));
        // With a deep log, the partially clipped entry is hittable up to
        // the last pixel above the footer.
        const ctx_full = matrixCtx(g, 3, 10, 300, true, 99);
        const last_idx: usize = @intCast(@divTrunc(footer_top - 1 - e0, g.entry));
        try testing.expectEqual(HitTarget{ .notif_entry = last_idx }, hitTest(10, footer_top - 1, ctx_full));
        try testing.expectEqual(@as(HitTarget, .bell_icon), hitTest(g.pad, footer_top, ctx_full));
    }
}

test "sidebar hitTest matrix: edge band boundaries and overlap at every scale" {
    for (scale_matrix) |g| {
        const widths = [_]i32{ 300, scaled(@intCast(MIN_WIDTH), g.scale), scaled(@intCast(MAX_WIDTH), g.scale) };
        for (widths) |w| {
            // The resize band spans [width-band, width).
            try testing.expect(!hitTestEdge(w - g.band - 1, w, g.band));
            try testing.expect(hitTestEdge(w - g.band, w, g.band));
            try testing.expect(hitTestEdge(w - 1, w, g.band));
            try testing.expect(!hitTestEdge(w, w, g.band));
            // The close and dropdown bands end at w-pad and pad >= band
            // at every scale, so the Window-level edge-first precedence
            // can never shadow a close/dropdown click.
            try testing.expect(g.pad >= g.band);
            try testing.expect(rowCloseRect(0, w, g.item_h, g.scale).right <= w - g.band);
            try testing.expect(newSessionDropdownRect(1, w, g.item_h, g.scale).right <= w - g.band);
            // Inside the band, hitTest itself still reports the row body
            // (running hitTestEdge first is the caller's responsibility).
            const ctx = matrixCtx(g, 2, 6, w, false, 0);
            try testing.expectEqual(HitTarget{ .workspace = 0 }, hitTest(w - g.band, 0, ctx));
        }
    }
}

test "sidebar hitTest matrix: zero workspaces at every scale" {
    for (scale_matrix) |g| {
        const width: i32 = 300;
        const ctx = matrixCtx(g, 0, 6, width, false, 0);
        // Row 0 is the "+ New workspace" row, with its dropdown band.
        try testing.expectEqual(@as(HitTarget, .new_session), hitTest(10, 0, ctx));
        try testing.expectEqual(@as(HitTarget, .new_session), hitTest(10, g.item_h - 1, ctx));
        try testing.expectEqual(@as(HitTarget, .new_session_dropdown), hitTest(width - g.pad - 1, 0, ctx));
        // No workspace rows or close bands anywhere below it.
        try testing.expectEqual(@as(HitTarget, .none), hitTest(10, g.item_h, ctx));
        try testing.expectEqual(@as(HitTarget, .none), hitTest(width - g.pad - 1, g.item_h, ctx));
        // The footer is still live.
        try testing.expectEqual(@as(HitTarget, .bell_icon), hitTest(g.pad, ctx.client_h - 1, ctx));
    }
}

test "sidebar hitTest matrix: sixteen workspaces row math at every scale" {
    for (scale_matrix) |g| {
        const width: i32 = 300;
        const ctx = matrixCtx(g, 16, 20, width, false, 0);
        // All 16 rows (the MAX_WORKSPACES cap) hit at their rect bounds.
        for (0..16) |i| {
            const r = itemRect(i, width, g.item_h);
            try testing.expectEqual(HitTarget{ .workspace = i }, hitTest(10, r.top, ctx));
            try testing.expectEqual(HitTarget{ .workspace = i }, hitTest(10, r.bottom - 1, ctx));
            try testing.expectEqual(HitTarget{ .row_close = i }, hitTest(width - g.pad - 1, r.top, ctx));
        }
        // Row 16 is the "+ New workspace" row; row 17 is dead space.
        try testing.expectEqual(@as(HitTarget, .new_session), hitTest(10, 16 * g.item_h, ctx));
        try testing.expectEqual(@as(HitTarget, .new_session_dropdown), hitTest(width - g.pad - 1, 16 * g.item_h, ctx));
        try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 17 * g.item_h, ctx));
        // Rows stack exactly: row 16 starts where row 15 ends.
        try testing.expectEqual(itemRect(15, width, g.item_h).bottom, itemRect(16, width, g.item_h).top);
    }
}

test "sidebar hitTest matrix: bands respond at MIN and MAX widths at every scale" {
    for (scale_matrix) |g| {
        // Window.sidebarWidth clamps the unscaled width then scales it
        // with the same rounding, so these are the physical extremes.
        const widths = [_]i32{ scaled(@intCast(MIN_WIDTH), g.scale), scaled(@intCast(MAX_WIDTH), g.scale) };
        for (widths) |w| {
            const ctx = matrixCtx(g, 2, 10, w, true, 1);
            const footer_top = ctx.client_h - g.footer_h;
            const panel_top = footer_top - panelHeight(ctx.client_h);
            // Close band on row 0.
            try testing.expectEqual(HitTarget{ .workspace = 0 }, hitTest(w - g.pad - g.close - 1, 0, ctx));
            try testing.expectEqual(HitTarget{ .row_close = 0 }, hitTest(w - g.pad - g.close, 0, ctx));
            try testing.expectEqual(HitTarget{ .workspace = 0 }, hitTest(w - g.pad, 0, ctx));
            // Dropdown band on the new-workspace row (row 2).
            try testing.expectEqual(@as(HitTarget, .new_session_dropdown), hitTest(w - g.pad - 1, 2 * g.item_h, ctx));
            // Clear button right-aligned to this width.
            try testing.expectEqual(@as(HitTarget, .notif_clear), hitTest(w - 1, panel_top, ctx));
            try testing.expectEqual(@as(HitTarget, .none), hitTest(w - g.clear_w - 1, panel_top, ctx));
            // Controls stay strictly inside the strip even at MIN width.
            try testing.expect(rowCloseRect(0, w, g.item_h, g.scale).left > 0);
            try testing.expect(newSessionDropdownRect(2, w, g.item_h, g.scale).left > 0);
            try testing.expect(w - g.clear_w > 0);
            try testing.expect(globeSlotRect(footer_top, g.scale).right <= w);
        }
    }
}

test "sidebar hitTest: non-positive item height is none everywhere" {
    var ctx = testCtx(3, false, 0);
    ctx.item_h = 0;
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 0, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 100, ctx));
    // Even the footer is dead when the row math is degenerate.
    try testing.expectEqual(@as(HitTarget, .none), hitTest(8, 380, ctx));
    ctx.item_h = -36;
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 0, ctx));
}

test "sidebar hitTest: tiny client heights collapse to the footer" {
    // client_h smaller than the footer: footer_top < 0, every in-client
    // y is footer space and only x picks a slot.
    var ctx = testCtx(3, false, 0);
    ctx.client_h = 10;
    try testing.expectEqual(@as(HitTarget, .bell_icon), hitTest(8, 0, ctx));
    try testing.expectEqual(@as(HitTarget, .bell_icon), hitTest(31, 9, ctx));
    try testing.expectEqual(@as(HitTarget, .gear_icon), hitTest(40, 5, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(100, 5, ctx));
    // No workspace row is reachable: y past the client is dead too.
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 10, ctx));
    // client_h == footer height exactly: same collapse.
    ctx.client_h = 32;
    try testing.expectEqual(@as(HitTarget, .bell_icon), hitTest(8, 0, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 32, ctx));
    // An open panel cannot resurface rows: the footer test runs first.
    ctx.panel_open = true;
    ctx.notif_count = 5;
    ctx.client_h = 10;
    try testing.expectEqual(@as(HitTarget, .bell_icon), hitTest(8, 0, ctx));
}

test "sidebar hitTest: zero scale degenerates to none without crashing" {
    // scale 0 zeroes every scaled metric: no footer strip, a zero-height
    // header, and zero-height entries. The entry_h guard returns none
    // instead of dividing by zero.
    const ctx: HitCtx = .{
        .item_h = 36, // rows still laid out; only the scaled chrome is zero
        .workspace_count = 2,
        .client_h = 400,
        .width = 220,
        .scale = 0.0,
        .panel_open = true,
        .notif_count = 3,
    };
    const panel_top = 400 - panelHeight(400);
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, panel_top, ctx));
    try testing.expectEqual(@as(HitTarget, .none), hitTest(10, 399, ctx));
    // Rows above the panel still resolve.
    try testing.expectEqual(HitTarget{ .workspace = 0 }, hitTest(10, 0, ctx));
}

// ---------------------------------------------------------------------------
// Stage 2: metadata row height + second-line composition.
// ---------------------------------------------------------------------------

test "sidebar itemHeightMeta is taller than itemHeight and scales" {
    // Base 36 + meta 16 = 52 at 1.0; scales together.
    try testing.expectEqual(@as(i32, 52), itemHeightMeta(1.0));
    try testing.expect(itemHeightMeta(1.0) > itemHeight(1.0));
    try testing.expectEqual(@as(i32, 104), itemHeightMeta(2.0));
    try testing.expectEqual(@as(i32, 65), itemHeightMeta(1.25));
}

test "sidebar hitTest agrees with the taller metadata row stride" {
    // The pure geometry helpers take item_h, so a metadata-tall row just
    // means callers pass itemHeightMeta. Row math must stay consistent at
    // that stride: rows, the close band, and the new-session row.
    const item_h = itemHeightMeta(1.0); // 52
    const ctx: HitCtx = .{
        .item_h = item_h,
        .workspace_count = 3,
        .client_h = item_h * 6 + footerHeight(1.0),
        .width = 220,
        .scale = 1.0,
        .panel_open = false,
        .notif_count = 0,
    };
    // Row boundaries at the taller stride.
    try testing.expectEqual(HitTarget{ .workspace = 0 }, hitTest(10, 0, ctx));
    try testing.expectEqual(HitTarget{ .workspace = 0 }, hitTest(10, item_h - 1, ctx));
    try testing.expectEqual(HitTarget{ .workspace = 1 }, hitTest(10, item_h, ctx));
    try testing.expectEqual(HitTarget{ .workspace = 2 }, hitTest(10, 2 * item_h, ctx));
    // Close band on each tall row (x in [192,212)).
    try testing.expectEqual(HitTarget{ .row_close = 1 }, hitTest(200, item_h + 5, ctx));
    // The new-session row sits right below the 3 tall rows.
    try testing.expectEqual(@as(HitTarget, .new_session), hitTest(10, 3 * item_h, ctx));
    // itemRect and hitTest agree at the taller stride.
    for (0..3) |i| {
        const r = itemRect(i, 220, item_h);
        try testing.expectEqual(HitTarget{ .workspace = i }, hitTest(10, r.top, ctx));
        try testing.expectEqual(HitTarget{ .workspace = i }, hitTest(10, r.bottom - 1, ctx));
    }
}

/// A bare workspace for metadata-line composition tests: only the fields
/// formatMetaLineUtf8 reads are set; tab_count stays 0 unless a test wants
/// a status (the status scan walks tab_status_text[0..tab_count]).
fn metaTestWorkspace() Window.Workspace {
    return .{};
}

test "sidebar formatMetaLineUtf8: empty workspace yields nothing" {
    var ws = metaTestWorkspace();
    var buf: [256]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), formatMetaLineUtf8(&ws, &buf));
}

test "sidebar formatMetaLineUtf8: branch only" {
    var ws = metaTestWorkspace();
    ws.setGitBranch("feat/agent");
    var buf: [256]u8 = undefined;
    const n = formatMetaLineUtf8(&ws, &buf);
    // "⎇ feat/agent" — the branch text must appear verbatim after the sigil.
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "feat/agent") != null);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "\u{2387}") != null);
}

test "sidebar formatMetaLineUtf8: branch, ports, and status joined with separators" {
    var ws = metaTestWorkspace();
    ws.setGitBranch("main");
    ws.setPorts(&.{ 3000, 8080 });
    ws.tab_count = 1;
    ws.setTabStatusText(0, "running tests");
    var buf: [256]u8 = undefined;
    const n = formatMetaLineUtf8(&ws, &buf);
    const s = buf[0..n];
    try testing.expect(std.mem.indexOf(u8, s, "main") != null);
    try testing.expect(std.mem.indexOf(u8, s, ":3000, 8080") != null);
    try testing.expect(std.mem.indexOf(u8, s, "running tests") != null);
    // Three segments → two " · " separators.
    var seps: usize = 0;
    var it = std.mem.window(u8, s, 3, 1);
    while (it.next()) |w| {
        if (std.mem.eql(u8, w, " \u{00B7} ")) seps += 1;
    }
    // "·" is 2 bytes so the 3-byte window above can't match it; count via
    // indexOf occurrences instead.
    seps = std.mem.count(u8, s, "\u{00B7}");
    try testing.expectEqual(@as(usize, 2), seps);
}

test "sidebar formatMetaLineUtf8: PR marker reflects state" {
    var ws = metaTestWorkspace();
    ws.setGitBranch("x");
    ws.setPrStatus(.draft, 42);
    var buf: [256]u8 = undefined;
    const n = formatMetaLineUtf8(&ws, &buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "draft #42") != null);

    ws.setPrStatus(.open, 7);
    const n2 = formatMetaLineUtf8(&ws, &buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n2], "PR #7") != null);
}

test "sidebar formatMetaLineUtf8: truncates without overflowing the buffer" {
    var ws = metaTestWorkspace();
    ws.setGitBranch("a-very-long-branch-name-that-keeps-going");
    ws.setPorts(&.{ 3000, 3001, 3002, 3003 });
    ws.tab_count = 1;
    ws.setTabStatusText(0, "a long status message that should be dropped");
    // Tiny buffer: composition must stop at the boundary, never overflow.
    var small: [12]u8 = undefined;
    const n = formatMetaLineUtf8(&ws, &small);
    try testing.expect(n <= small.len);
}
