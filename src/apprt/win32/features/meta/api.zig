//! Public API of the `meta` feature (workspace git branch / ports / PR
//! metadata). Other features and the app/ui layers reach it only through
//! this file (ARCHITECTURE.md ADR-1.2). In W0-A1 it re-exports the legacy
//! refresh (`legacy_refresh.zig`); W1-7a adds `onPwd` (ADR-9.6) and W2-6
//! replaces the probes (ADR-14.4/14.5).

const std = @import("std");

const App = @import("../../App.zig");
const apprt = @import("../../../../apprt.zig");
const refresh = @import("legacy_refresh.zig");
const session = @import("../session/api.zig");

/// Start the periodic refresh timer (App.init).
pub const startRefreshTimer = refresh.startRefreshTimer;

/// Refresh one workspace now (focus / worktree bind; Window.zig).
pub const refreshWorkspaceMetadataNow = refresh.refreshWorkspaceMetadataNow;

/// The `.pwd` apprt action (OSC 7 and OSC 9;9; ADR-9.6): the terminal's
/// shell reported its working directory. It becomes the tab's `cwd`; when
/// the tab is the one the user works in (the selected tab of its
/// workspace's focused pane) it also becomes the workspace's directory,
/// which new tabs inherit; the session saves it with the next autosave.
/// app/perform_action.zig calls this once CCR W1-7a-1 lands; until then
/// the session reads the live terminal pwd when it serializes.
pub fn onPwd(app: *App, target: apprt.Target, value: apprt.Action.Value(.pwd)) void {
    const core_surface = switch (target) {
        .app => return,
        .surface => |s| s,
    };
    const tab = core_surface.rt_surface.tab orelse return;
    const gpa = app.core_app.alloc;
    const pwd = value.pwd;
    if (pwd.len == 0) return;
    if (tab.cwd) |old| if (std.mem.eql(u8, old, pwd)) return;
    const copy = gpa.dupe(u8, pwd) catch return;
    if (tab.cwd) |old| gpa.free(old);
    tab.cwd = copy;
    if (tab.pane) |pane| if (pane.workspace) |ws| {
        const focused = ws.focusedPaneOrFirst();
        if (focused == pane and pane.selectedTab() == tab) ws.setCwd(gpa, pwd) catch {};
    };
    session.markDirty(app);
}

test {
    _ = &onPwd;
}
