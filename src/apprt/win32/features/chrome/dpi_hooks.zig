//! Window hooks of the `chrome` feature (ARCHITECTURE.md ADR-1.6, ADR-11.5):
//! `WM_DPICHANGED` / `WM_GETDPISCALEDSIZE` on the top-level window apply the
//! suggested rect, rebuild text formats, `SetDpi` on render targets,
//! rescale tab bars and overlays and forward to terminal surfaces and
//! WebView2 bounds.
//!
//! Written empty by the W1 kickoff interface commit (W1-IF) and declared
//! in chrome/mod.zig as `window_hooks`, so W1-8c (sidebar focus and DPI)
//! fills this file without editing mod.zig, which W1-8d (right sidebar
//! host, same plan sub-wave) needs for `rpc_methods`. No hook yet: the
//! window keeps its current DPI handling.

const WindowHook = @import("../../app/hooks.zig").WindowHook;

/// The chrome feature's top-level window hooks (W1-8c).
pub const hooks = [_]WindowHook{};
