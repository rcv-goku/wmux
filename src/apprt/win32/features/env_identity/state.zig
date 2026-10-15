//! Per-object state of feature `env_identity` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.env_identity`).
pub const App = struct {};

/// Per-window state (`Window.ext.env_identity`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.env_identity`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.env_identity`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.env_identity`).
pub const Tab = struct {};
