//! Per-object state of feature `settings_ui` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.settings_ui`).
pub const App = struct {};

/// Per-window state (`Window.ext.settings_ui`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.settings_ui`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.settings_ui`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.settings_ui`).
pub const Tab = struct {};
