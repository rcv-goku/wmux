//! Feature `updater` (ADR-1.3); owning wave W5 (ADR-1.5).
//! The feature manifest imports only this file. Besides `id`, declare the
//! optional registry tables and lifecycle hooks of ADR-1.3 here when needed.
pub const id = "updater";

/// A click on the update balloon opens the releases page.
pub const app_hooks = [_]hooks.AppHook{
    .{ .msg = hooks.WM_APP_TRAY, .handler = &legacy_check.onTrayCallback },
};

const hooks = @import("../../app/hooks.zig");
const legacy_check = @import("legacy_check.zig");

test {
    _ = @import("logic/tests.zig");
}
