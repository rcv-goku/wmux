//! The right sidebar facade (ARCHITECTURE.md §14.3 pre-wiring; filled by
//! W1-8 with the right-sidebar host frame): ui/Window.zig calls `attach`
//! once its top-level HWND exists and `detach` before the window is
//! freed. Until then the right sidebar is the legacy strip painted by the
//! window itself (legacy_strip.zig), which needs no per-window setup.
//!
//! Since the W1 kickoff interface commit (W1-IF) both calls delegate to
//! api.zig, the right sidebar's public API, so W1-8d edits only api.zig.

const Window = @import("../Window.zig");
pub const api = @import("api.zig");

/// Set up the right sidebar of `window` (its HWND exists). See `api.attach`.
pub fn attach(window: *Window) void {
    api.attach(window);
}

/// Tear down what `attach` set up. See `api.detach`.
pub fn detach(window: *Window) void {
    api.detach(window);
}
