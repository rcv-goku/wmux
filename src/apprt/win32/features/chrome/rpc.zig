//! v2 methods of the `chrome` feature (ARCHITECTURE.md ADR-11.6, Appendix
//! B.3): `wmux.right_sidebar.{get,set,toggle,show,hide,focus}`.
//!
//! Written empty by the W1 kickoff interface commit (W1-IF) and declared
//! in chrome/mod.zig as `rpc_methods`, so W1-8d (right sidebar host) fills
//! this file without editing mod.zig, which W1-8c (same plan sub-wave)
//! needs for `window_hooks`. No method yet.

const Method = @import("../../rpc/types.zig").Method;

/// The chrome feature's v2 methods (W1-8d).
pub const methods = [_]Method{};
