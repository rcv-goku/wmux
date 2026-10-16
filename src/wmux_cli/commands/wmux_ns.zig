//! CLI command family `wmux_ns` (Appendix C).
//! The `wmux <sub>` namespace for wmux-only commands (ADR-4.11, Appendix B.3).
//! Framework: W1-2; subcommands: their Appendix B.3 owners; install-cli: W7.
//! Entries here are subcommands of `cmux wmux` (and top-level words when the
//! binary runs as `wmux` and the word is not a cmux command); main.zig skips
//! families that declare `namespace` when it builds the top-level table.

const CommandSpec = @import("../command.zig").CommandSpec;

/// The namespace word.
pub const namespace = "wmux";

/// `CommandSpec` entries (ADR-4.9); empty until the owning WPs fill them.
pub const commands = [_]CommandSpec{};
