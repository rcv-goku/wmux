//! Feature `notifications` (ADR-1.3); owning waves W2, W3 (ADR-1.5).
//! The feature manifest imports only this file. Besides `id`, declare the
//! optional registry tables and lifecycle hooks of ADR-1.3 here when needed.
pub const id = "notifications";
pub const action_handlers = @import("actions.zig").handlers;
pub const legacy_commands = @import("legacy.zig").commands;

/// A click on a desktop-notification balloon jumps to its surface.
pub const app_hooks = [_]hooks.AppHook{
    .{ .msg = hooks.WM_APP_TRAY, .handler = &api.onTrayCallback },
};

const api = @import("api.zig");
const hooks = @import("../../app/hooks.zig");

test {
    _ = @import("logic/tests.zig");
}
