//! Feature `panes_surfaces` (ADR-1.3); owning wave W2 (ADR-1.5).
//! The feature manifest imports only this file. Besides `id`, declare the
//! optional registry tables and lifecycle hooks of ADR-1.3 here when needed.
pub const id = "panes_surfaces";
pub const action_handlers = @import("actions.zig").handlers;
pub const legacy_commands = @import("legacy.zig").commands;

test {
    _ = @import("logic/tests.zig");
}
