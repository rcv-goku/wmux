//! Public API of the settings layer (ARCHITECTURE.md ADR-5): the
//! `cmux.json`/`wmux.json` layering, the typed snapshot, the watcher and
//! the Ghostty overlay. App.init calls `init` once the app struct exists
//! and before any window is created; App.terminate calls `deinit`.
//!
//! Stubs written by W0-A3 (pre-wiring); W1-4 implements the layer (it
//! owns settings/**). Until then the Ghostty configuration (`App.config`)
//! is the only configuration.

const App = @import("../App.zig");

/// Load the settings layers and start the watcher. Nothing yet.
pub fn init(app: *App) !void {
    _ = app;
}

/// Stop the watcher and free the settings. Nothing yet.
pub fn deinit(app: *App) void {
    _ = app;
}
