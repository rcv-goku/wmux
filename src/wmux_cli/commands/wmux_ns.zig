//! CLI command family `wmux_ns` (Appendix C).
//! The `wmux <sub>` namespace for wmux-only commands (ADR-4.11, Appendix B.3).
//! Framework: W1-2; subcommands: their Appendix B.3 owners; install-cli: W7.
//! Entries here are subcommands of `cmux wmux` (and top-level words when the
//! binary runs as `wmux` and the word is not a cmux command); main.zig skips
//! families that declare `namespace` when it builds the top-level table.
//!
//! Since the W1 kickoff interface commit (W1-IF) this file only dispatches:
//! each subcommand group lives in its own sub-file under `wmux/` (one owner
//! per file, AF-1), and `commands` concatenates them.

const CommandSpec = @import("../command.zig").CommandSpec;

const action = @import("wmux/action.zig");
const attention = @import("wmux/attention.zig");
const install_cli = @import("wmux/install_cli.zig");
const layout = @import("wmux/layout.zig");
const notification = @import("wmux/notification.zig");
const quick_terminal = @import("wmux/quick_terminal.zig");
const session = @import("wmux/session.zig");
const sync_input = @import("wmux/sync_input.zig");

/// The namespace word.
pub const namespace = "wmux";

/// The sub-files, in help order (Appendix C row order).
pub const subfiles = .{ attention, notification, quick_terminal, layout, sync_input, session, action, install_cli };

/// `CommandSpec` entries (ADR-4.9) of every sub-file, in `subfiles` order.
pub const commands = attention.commands ++ notification.commands ++ quick_terminal.commands ++
    layout.commands ++ sync_input.commands ++ session.commands ++ action.commands ++ install_cli.commands;

test {
    inline for (subfiles) |f| _ = f;
}

test "unit: cli: wmux namespace concatenates its sub-files" {
    const std = @import("std");
    var n: usize = 0;
    inline for (subfiles) |f| n += f.commands.len;
    try std.testing.expectEqual(n, commands.len);
}
