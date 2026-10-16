//! The right sidebar facade (ARCHITECTURE.md §14.3 pre-wiring; filled by
//! W1-8 with the right-sidebar host frame): ui/Window.zig calls `attach`
//! once its top-level HWND exists and `detach` before the window is
//! freed. Until then the right sidebar is the legacy strip painted by the
//! window itself (legacy_strip.zig), which needs no per-window setup.

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
