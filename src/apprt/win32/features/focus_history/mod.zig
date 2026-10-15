//! Feature `focus_history` (ADR-1.3); owning wave W2 (ADR-1.5).
//! The feature manifest imports only this file. Besides `id`, declare the
//! optional registry tables and lifecycle hooks of ADR-1.3 here when needed.
pub const id = "focus_history";

test {
    _ = @import("logic/tests.zig");
}
