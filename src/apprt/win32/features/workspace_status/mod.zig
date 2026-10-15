//! Feature `workspace_status` (ADR-1.3); owning wave W5 (ADR-1.5).
//! The feature manifest imports only this file. Besides `id`, declare the
//! optional registry tables and lifecycle hooks of ADR-1.3 here when needed.
pub const id = "workspace_status";

test {
    _ = @import("logic/tests.zig");
}
