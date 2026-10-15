//! Public API of the `meta` feature (workspace git branch / ports / PR
//! metadata). Other features and the app/ui layers reach it only through
//! this file (ARCHITECTURE.md ADR-1.2). In W0-A1 it re-exports the legacy
//! refresh (`legacy_refresh.zig`); W1-7 adds `onPwd` and W2-6 replaces the
//! probes (ADR-14.4/14.5).

const refresh = @import("legacy_refresh.zig");

pub const Result = @import("probes.zig").Result;

pub const WM_APP_WS_META = refresh.WM_APP_WS_META;
pub const WS_META_TIMER_ID = refresh.WS_META_TIMER_ID;
pub const WS_META_INTERVAL_MS = refresh.WS_META_INTERVAL_MS;

pub const refreshWorkspaceMetadata = refresh.refreshWorkspaceMetadata;
pub const refreshWorkspaceMetadataNow = refresh.refreshWorkspaceMetadataNow;
pub const applyWorkspaceMetadata = refresh.applyWorkspaceMetadata;
