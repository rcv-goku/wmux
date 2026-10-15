//! Public API of the `meta` feature (workspace git branch / ports / PR
//! metadata). Other features and the app/ui layers reach it only through
//! this file (ARCHITECTURE.md ADR-1.2). In W0-A1 it re-exports the legacy
//! refresh (`legacy_refresh.zig`); W1-7 adds `onPwd` and W2-6 replaces the
//! probes (ADR-14.4/14.5).

const refresh = @import("legacy_refresh.zig");

/// Start the periodic refresh timer (App.init).
pub const startRefreshTimer = refresh.startRefreshTimer;

/// Refresh one workspace now (focus / worktree bind; Window.zig).
pub const refreshWorkspaceMetadataNow = refresh.refreshWorkspaceMetadataNow;
