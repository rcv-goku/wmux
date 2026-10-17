//! `wmux sync-input on|off|toggle` (Appendix C, family `wmux_ns`; methods `wmux.sync_input.set`, Appendix B.3).
//! Sub-file of the `wmux` namespace dispatcher (commands/wmux_ns.zig),
//! written empty by the W1 kickoff interface commit (W1-IF) so each owner
//! edits only its own sub-file. Owner: W2-2b.

const CommandSpec = @import("../../command.zig").CommandSpec;

/// `CommandSpec` entries (ADR-4.9); empty until the owner fills them.
pub const commands = [_]CommandSpec{};
