//! Per-object state of feature `i18n` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.i18n`).
pub const App = struct {};

/// Per-window state (`Window.ext.i18n`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.i18n`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.i18n`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.i18n`).
pub const Tab = struct {};
