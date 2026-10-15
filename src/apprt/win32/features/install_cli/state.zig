//! Per-object state of feature `install_cli` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.install_cli`).
pub const App = struct {};

/// Per-window state (`Window.ext.install_cli`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.install_cli`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.install_cli`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.install_cli`).
pub const Tab = struct {};
