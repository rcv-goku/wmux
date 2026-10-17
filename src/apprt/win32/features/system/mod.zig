//! Feature `system` (ADR-1.3); owning waves W1, W2 (ADR-1.5).
//! The feature manifest imports only this file.
//!
//! W1-1a: `rpc_methods` (`system.ping`, `system.capabilities`, rpc.zig) and
//! the WM_ACTIVATE window hook that tracks the active window for the
//! router (ADR-2.6: the most recently activated wmux window, never
//! `GetForegroundWindow()`).
const hooks = @import("../../app/hooks.zig");
const router = @import("../../rpc/router.zig");
const w32 = @import("../../platform/win32.zig");
const Window = @import("../../ui/Window.zig");

pub const id = "system";

pub const rpc_methods = @import("rpc.zig").methods;

pub const window_hooks = [_]hooks.WindowHook{
    .{ .msg = w32.WM_ACTIVATE, .handler = onActivate },
};

/// Records the window as the active one when it is activated; never
/// consumes the message.
fn onActivate(window: *Window, wparam: usize, lparam: isize) ?isize {
    _ = lparam;
    if (@as(u16, @truncate(wparam)) != w32.WA_INACTIVE) router.noteActivated(window);
    return null;
}

test {
    _ = @import("logic/tests.zig");
}
