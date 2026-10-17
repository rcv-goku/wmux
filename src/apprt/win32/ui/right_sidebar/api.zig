//! Public API of the right sidebar (ARCHITECTURE.md ADR-11.6, AF-13): what
//! the rest of the app calls. ui/Window.zig reaches `attach`/`detach`
//! through ui/right_sidebar/mod.zig; the chrome action handlers (W1-5a:
//! `toggleRightSidebar`, `focusRightSidebar`) call `toggle`, `focus`,
//! `isVisible` and `setWidth`.
//!
//! Written by the W1 kickoff interface commit (W1-IF) with the final
//! signatures so W1-5a can call them before the mode host lands. Until
//! W1-8d replaces the bodies (host frame, modes, per-window width,
//! visibility and mode, persisted), they keep today's behavior: the
//! legacy strip painted by the window (legacy_strip.zig).

const Window = @import("../Window.zig");

/// Set up the right sidebar of `window` (its HWND exists). No-op for the
/// legacy strip. Called for quick terminals too, which show no sidebar.
pub fn attach(window: *Window) void {
    _ = window;
}

/// Tear down what `attach` set up: the window is about to be freed, and
/// its HWND (with any child windows) may already be destroyed.
pub fn detach(window: *Window) void {
    _ = window;
}

/// Show or hide the right sidebar of `window`. Today: the legacy
/// session-only hide (`Window.toggleRightSidebar`).
pub fn toggle(window: *Window) void {
    window.toggleRightSidebar();
}

/// Move keyboard focus to the right sidebar (`rightSidebarFocus`).
/// Today: the legacy focus toggle (`Window.focusRightSidebar`), a no-op
/// while the strip is hidden.
pub fn focus(window: *Window) void {
    window.focusRightSidebar();
}

/// Whether the right sidebar of `window` takes space right now.
pub fn isVisible(window: *const Window) bool {
    return window.rightSidebarWidth() > 0;
}

/// Set the right sidebar width of `window` in unscaled pixels (DIPs).
/// No-op until W1-8d: the legacy strip width comes from the Ghostty
/// configuration only.
pub fn setWidth(window: *Window, width: u32) void {
    _ = window;
    _ = width;
}

test {
    _ = &attach;
    _ = &detach;
    _ = &toggle;
    _ = &focus;
    _ = &isVisible;
    _ = &setWidth;
}
