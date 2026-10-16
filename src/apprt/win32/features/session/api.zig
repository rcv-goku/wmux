//! Public API of the `session` feature (ARCHITECTURE.md ADR-9). Other
//! features and the layers reach the session only through this file
//! (ADR-1.2).
//!
//! Stubs written by W0-A3 (pre-wiring); W1-7 implements them (session v3,
//! autosave, restore, scrollback replay).

const Surface = @import("../../Surface.zig");

/// The saved scrollback (VT text) to replay into `surface`'s terminal
/// before its shell starts (ADR-9.5), borrowed until the core surface's
/// Termio.init returns, or null. Nothing to replay yet.
pub fn restoreHistory(surface: *Surface) ?[]const u8 {
    _ = surface;
    return null;
}
