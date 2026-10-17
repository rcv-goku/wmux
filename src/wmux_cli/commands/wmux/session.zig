//! `wmux session save|resume` (Appendix C, family `wmux_ns`; methods `wmux.session.save` (W1-7b), `wmux.surface.resume_run` (W3-5a), Appendix B.3).
//! Sub-file of the `wmux` namespace dispatcher (commands/wmux_ns.zig),
//! written empty by the W1 kickoff interface commit (W1-IF) so each owner
//! edits only its own sub-file. Owner: W1-7b (save), W3-5a (resume).

const CommandSpec = @import("../../command.zig").CommandSpec;

/// `CommandSpec` entries (ADR-4.9); empty until the owner fills them.
pub const commands = [_]CommandSpec{};
