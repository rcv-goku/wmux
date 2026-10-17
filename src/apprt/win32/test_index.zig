//! Unit-test index of the win32 apprt [frozen] (ARCHITECTURE.md ADR-1.1,
//! ADR-12.1; pulled from App.zig's test block in W0-A3). App.zig's test
//! block imports only this file; the full suite (`zig build test`)
//! reaches it through src/apprt.zig.
//!
//! A file's `test` blocks are collected only when the file is referenced
//! for testing, so every file with tests is listed here (one sorted line
//! each), or reached from a listed file's own test block (ui/Window.zig
//! lists the model and ui files; each feature's mod.zig lists its
//! logic/tests.zig). The std-only logic indexes also run in
//! `zig build test-fast` through fast_tests.zig.
//!
//! Never reference the aggregated registries' handler tables from a test
//! (`rpc/registry.app`, `input/actions.zig`'s app table, `ui/contrib.zig`'s
//! lists): the feature handlers reach the terminal teardown graph, which
//! pulls the GTK apprt into the test binary.

const manifest = @import("features/manifest.zig");

test {
    // Every feature module: its mod.zig test block imports logic/tests.zig.
    inline for (manifest.modules) |module| _ = module;

    _ = @import("app/clipboard.zig");
    _ = @import("app/dialogs.zig");
    _ = @import("app/foreground.zig");
    _ = @import("app/hooks.zig");
    _ = @import("app/logger.zig");
    _ = @import("app/modal.zig");
    _ = @import("app/paths.zig");
    _ = @import("app/runtime_env.zig");
    _ = @import("app/tasks.zig");
    _ = @import("app/timers.zig");
    _ = @import("features/agents/legacy_store.zig");
    _ = @import("features/env_identity/api.zig");
    _ = @import("features/ext.zig");
    _ = @import("features/lifecycle.zig");
    _ = @import("features/manifest.zig");
    _ = @import("features/meta/probes.zig");
    _ = @import("features/notifications/legacy_ring.zig");
    _ = @import("features/session/api.zig");
    // Unreferenced until W1-7 replaces it; imported so the file at least
    // keeps compiling (an unimported file is never compiled).
    _ = @import("features/session/legacy_scrollback.zig");
    _ = @import("features/session/legacy_v2.zig");
    _ = @import("features/status/log_ring.zig");
    _ = @import("features/status/state.zig");
    _ = @import("features/workspaces/worktree.zig");
    _ = @import("input/actions.zig");
    _ = @import("input/router.zig");
    _ = @import("platform/taskbar.zig");
    _ = @import("rpc/compat/legacy_json.zig");
    _ = @import("rpc/registry.zig");
    _ = @import("rpc/server/legacy_pipe.zig");
    _ = @import("rpc/server/mod.zig");
    _ = @import("rpc/types.zig");
    _ = @import("settings/api.zig");
    _ = @import("settings/legacy_config_files.zig");
    _ = @import("ui/Window.zig");
    _ = @import("ui/notice.zig");
    _ = @import("ui/right_sidebar/api.zig");
    _ = @import("ui/sidebar/api.zig");
    _ = @import("ui/strings.zig");
    _ = @import("ui/tabbar/hints.zig");
    _ = @import("web/PanelKind.zig");
    _ = @import("web/WebPanel.zig");
    _ = @import("web/env.zig");
}
