//! Feature `session` (ADR-1.3); owning wave W1 (ADR-1.5).
//! The feature manifest imports only this file. Besides `id`, declare the
//! optional registry tables and lifecycle hooks of ADR-1.3 here when needed.
//!
//! W1-7a (session v3, ADR-9.1-9.4, 9.6, 9.8): `init` loads (or migrates)
//! the saved session and schedules the launch restore, seeds the handle
//! registry and starts the 8 s autosave; `onEvent` marks the session
//! dirty on model lifecycle events; the broadcast-window `app_hooks` do
//! the logoff/shutdown full save; `deinit` flushes the writer.
const std = @import("std");

const App = @import("../../App.zig");
const autosave = @import("autosave.zig");
const events = @import("../../model/events.zig");
const restore = @import("restore.zig");

pub const id = "session";
pub const action_handlers = @import("actions.zig").handlers;
pub const legacy_commands = @import("legacy.zig").commands;
pub const app_hooks = autosave.app_hooks;

pub fn init(app: *App) !void {
    restore.launchInit(app);
}

pub fn deinit(app: *App) void {
    autosave.destroy(app);
}

pub fn onEvent(app: *App, ev: *const events.Event) void {
    // Every window/workspace/pane/surface lifecycle event changes what
    // the snapshot holds; feature-domain events (notifications, agents,
    // status) do not, unless their owners snapshot ext state (they call
    // api.markDirty).
    if (isStructural(ev)) autosave.markDirty(app);
    // A window opened after the final save (the app kept running without
    // windows): automatic saves resume.
    if (ev.kind == .@"window.created") autosave.resumeAfterFinalSave(app);
}

fn isStructural(ev: *const events.Event) bool {
    var buf: [128]u8 = undefined;
    const name = ev.name(&buf);
    inline for (.{ "window.", "workspace.", "pane.", "surface." }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

test {
    _ = @import("logic/tests.zig");
    _ = @import("state.zig");
    _ = @import("writer.zig");
    _ = @import("markers.zig");
    _ = @import("autosave.zig");
    _ = @import("restore.zig");
}
