//! Modifier-hold hint chips in tab bars (ARCHITECTURE.md ADR-8.6/8.9,
//! `shortcuts.showModifierHoldHints`): while the user holds the binding
//! modifiers, each tab shows the stroke that selects it.
//!
//! Empty hook written by the W1 kickoff interface commit (W1-IF):
//! tabbar/paint.zig calls `paintPane` into the double buffer of every bar
//! it draws, so W1-5b (shortcut customization) draws the chips here
//! without editing paint.zig, which W1-8c (hover tooltips and DPI, same
//! plan sub-wave) owns. Draws nothing until then.

const Pane = @import("../../model/Pane.zig");
const geometry = @import("logic/geometry.zig");
const w32 = @import("../../platform/win32.zig");

/// Draw the hint chips of `pane`'s tab bar into `hdc`, the bar's
/// off-screen bitmap (local coordinates: the bar's left/top edge is 0,0;
/// tab spans from `geo.tabLocalLeft`/`geo.tabWidth`). Called after the
/// tabs and before the bitmap is copied to the window. No-op (W1-5b).
pub fn paintPane(pane: *const Pane, hdc: w32.HDC, geo: geometry.Geometry, scale: f32, is_focused: bool) void {
    _ = pane;
    _ = hdc;
    _ = geo;
    _ = scale;
    _ = is_focused;
}

test {
    _ = &paintPane;
}
