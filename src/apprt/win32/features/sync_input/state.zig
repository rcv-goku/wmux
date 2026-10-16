//! Per-object state of feature `sync_input` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.sync_input`).
pub const App = struct {};

/// Per-window state (`Window.ext.sync_input`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.sync_input`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.sync_input`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.sync_input`), moved out of model/Tab.zig
/// in W0-A3.
pub const Tab = struct {
    /// Synchronized input: keys typed into this tab, while it is its
    /// pane's selected tab, are replayed into the pane's other tabs.
    synchronized: bool = false,
};
