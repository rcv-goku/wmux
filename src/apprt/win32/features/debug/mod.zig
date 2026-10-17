//! Feature `debug` (ADR-1.3); owning wave W1 (ADR-1.5).
//! The feature manifest imports only this file.
//!
//! W1-1a: the `wmux.debug.*` test-hook framework (AF-14). The core hooks
//! are `debug_methods` (rpc.zig, handlers in hooks_core.zig); other
//! features declare their own `debug_methods` in `features/<id>/debug.zig`
//! and rpc/registry.zig aggregates them all. `hooks_core.setHotkeysProvider`
//! lets W1-5b fill `wmux.debug.focus_state.hotkeys`.
pub const id = "debug";

pub const debug_methods = @import("rpc.zig").debug_methods;

test {
    _ = @import("logic/tests.zig");
    _ = @import("hooks_core.zig");
}
