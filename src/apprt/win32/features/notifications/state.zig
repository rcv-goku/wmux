//! Per-object state of feature `notifications` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// The sidebar dot of a tab: bell or exited, cleared when the tab is seen.
pub const TabStatus = enum { normal, bell, exited };

/// App-wide state (`App.features.notifications`).
pub const App = struct {};

/// Per-window state (`Window.ext.notifications`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.notifications`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.notifications`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.notifications`): the legacy per-tab
/// attention state, moved out of model/Tab.zig in W0-A3.
pub const Tab = struct {
    /// Bell/exited dot, cleared when the tab is selected in the focused
    /// pane.
    status: TabStatus = .normal,
    /// "Needs attention": the aggregate of the content's
    /// `Surface.attention` (the attention ring).
    attention: bool = false,
};
