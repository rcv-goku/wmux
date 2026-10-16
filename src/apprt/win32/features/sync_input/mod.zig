//! Feature `sync_input` (ADR-1.3); owning wave W0 (ADR-1.5).
//! The feature manifest imports only this file. Besides `id`, declare the
//! optional registry tables and lifecycle hooks of ADR-1.3 here when needed.
pub const id = "sync_input";
pub const legacy_commands = @import("legacy.zig").commands;

test {
    _ = @import("logic/tests.zig");
}
