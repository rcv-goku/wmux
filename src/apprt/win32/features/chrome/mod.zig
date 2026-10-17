//! Feature `chrome` (ADR-1.3); owning wave W1 (ADR-1.5).
//! The feature manifest imports only this file. Besides `id`, declare the
//! optional registry tables and lifecycle hooks of ADR-1.3 here when needed.
//! `window_hooks` (W1-8c, dpi_hooks.zig) and `rpc_methods` (W1-8d, rpc.zig)
//! are declared by the W1 kickoff interface commit (W1-IF) so the two WPs
//! of one plan sub-wave never edit this file together.
pub const id = "chrome";
pub const action_handlers = @import("actions.zig").handlers;
pub const legacy_commands = @import("legacy.zig").commands;
pub const rpc_methods = @import("rpc.zig").methods;
pub const window_hooks = @import("dpi_hooks.zig").hooks;

test {
    _ = @import("logic/tests.zig");
}
