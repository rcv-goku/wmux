//! The sidebar facade (ARCHITECTURE.md §14.3 pre-wiring; filled by W1-8):
//! ui/Window.zig calls `attach` once its top-level HWND exists and
//! `detach` before the window is freed, so the D2D sidebar child HWND,
//! its row pipeline and its contributors plug in without editing
//! Window.zig. Until then the sidebar is the legacy GDI strip painted by
//! the window itself (legacy_gdi.zig, input in legacy_input.zig), which
//! needs no per-window setup.

const Window = @import("../Window.zig");

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
