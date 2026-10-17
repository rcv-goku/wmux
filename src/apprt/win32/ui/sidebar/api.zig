//! Public API of the left sidebar (ARCHITECTURE.md ADR-11, AF-13): what
//! the rest of the app calls. ui/Window.zig reaches `attach`/`detach`
//! through ui/sidebar/mod.zig; the chrome action handlers (W1-5a:
//! `toggleSidebar`, `focusSidebar`, the width actions) call `toggle`,
//! `focus`, `isVisible` and `setWidth`.
//!
//! Written by the W1 kickoff interface commit (W1-IF) with the final
//! signatures so W1-5a (same plan sub-wave as W1-8b) can call them before
//! the D2D sidebar lands. Until W1-8b replaces the bodies (the WmuxSidebar
//! child HWND, per-window width and visibility) and W1-8c adds the
//! keyboard focus mode, they keep today's behavior: the legacy GDI strip
//! painted by the window (legacy_gdi.zig, legacy_input.zig).

const std = @import("std");

const Sidebar = @import("legacy_gdi.zig");
const Window = @import("../Window.zig");
const w32 = @import("../../platform/win32.zig");

/// Set up the sidebar of `window` (its HWND exists). No-op for the
/// legacy strip. Called for quick terminals too, which show no sidebar.
pub fn attach(window: *Window) void {
    _ = window;
}

/// Tear down what `attach` set up: the window is about to be freed, and
/// its HWND (with any child windows) may already be destroyed.
pub fn detach(window: *Window) void {
    _ = window;
}

/// Show or hide the sidebar of `window` (the runtime toggle). Today: the
/// legacy session-only hide (`Window.toggleSidebar`).
pub fn toggle(window: *Window) void {
    window.toggleSidebar();
}

/// Move keyboard focus into the sidebar (keyboard focus mode, ADR-11.4).
/// No-op until W1-8c: the legacy strip has no keyboard focus.
pub fn focus(window: *Window) void {
    _ = window;
}

/// Whether the sidebar of `window` takes space right now.
pub fn isVisible(window: *const Window) bool {
    return window.sidebarWidth() > 0;
}

/// Set the sidebar width of `window` in unscaled pixels (DIPs), clamped
/// to the legacy limits; relays out the panes. Today: the same per-window
/// override the edge drag sets (lost on a config reload).
pub fn setWidth(window: *Window, width: u32) void {
    if (window.closing) return;
    const clamped = std.math.clamp(width, Sidebar.MIN_WIDTH, Sidebar.MAX_WIDTH);
    if (window.sidebar_width_override) |cur| if (cur == clamped) return;
    window.sidebar_width_override = clamped;
    window.handleResize();
    if (window.hwnd) |h| _ = w32.InvalidateRect(h, null, 0);
}

test {
    _ = &attach;
    _ = &detach;
    _ = &toggle;
    _ = &focus;
    _ = &isVisible;
    _ = &setWidth;
}
