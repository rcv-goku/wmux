//! Feature `notifications` (ADR-1.3); owning waves W2, W3 (ADR-1.5).
//! The feature manifest imports only this file. Besides `id`, declare the
//! optional registry tables and lifecycle hooks of ADR-1.3 here when needed.
pub const id = "notifications";
pub const action_handlers = @import("actions.zig").handlers;
pub const legacy_commands = @import("legacy.zig").commands;

test {
    _ = @import("logic/tests.zig");
}
