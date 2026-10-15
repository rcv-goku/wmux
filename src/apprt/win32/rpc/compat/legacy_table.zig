//! TEMPORARY aggregation of the legacy wmux-v1 JSON command tables
//! (W0-A1). Each owning feature exports `pub const commands` from its
//! `features/<id>/legacy.zig`; this file joins them into one table indexed
//! by `legacy_json.Command` and checks at comptime that every command has
//! exactly one handler (the guarantee the old exhaustive switch in
//! `App.handleIpcRequest` gave).
//!
//! W0-A3 replaces this file with the comptime registry (`rpc/registry.zig`
//! aggregating `legacy_commands` from every `features/<id>/mod.zig`) and
//! moves `LegacyCommand` to `rpc/types.zig` (ARCHITECTURE.md ADR-1.4,
//! ADR-3.6). Nothing else should import the feature tables directly.

const std = @import("std");

const App = @import("../../App.zig");
const ipc = @import("legacy_json.zig");

/// One legacy wmux-v1 JSON command. Shape per ARCHITECTURE.md ADR-3.6
/// (`cmd`, `handler`, `read_only`) plus the W0-A1-only `prepare` hook.
pub const LegacyCommand = struct {
    /// Wire name: a `legacy_json.Command` tag name.
    cmd: []const u8,

    /// Runs on the UI thread. Replies exactly once through
    /// `app.ipc_server` (synchronously, or later from an async completion)
    /// or returns an error, which the dispatcher names to the client via
    /// `@errorName`.
    handler: *const fn (*App, *ipc.Request) anyerror!void,

    /// Whether the command only reads state (never mutates the model,
    /// spawns a process, or sends input). Under `socket-control =
    /// read-only` only these are honored; everything else is refused
    /// before dispatch. The browser CDP verbs (snapshot/eval) read a page
    /// but eval can run arbitrary JS, so only snapshot is read-only;
    /// navigate/click/fill/open mutate.
    read_only: bool = false,

    /// Optional pipe-thread stage, run before the request is handed to
    /// the UI thread (only `workspace-new --worktree`, which shells out to
    /// git off the message loop). Returns false after it has answered the
    /// client itself; the request is then dropped.
    prepare: ?*const fn (*App, *ipc.Request) bool = null,
};

/// The per-feature tables (ARCHITECTURE.md Appendix B.4 owners).
const tables = .{
    @import("../../features/browser/legacy.zig").commands,
    @import("../../features/chrome/legacy.zig").commands,
    @import("../../features/layouts/legacy.zig").commands,
    @import("../../features/notifications/legacy.zig").commands,
    @import("../../features/panes_surfaces/legacy.zig").commands,
    @import("../../features/session/legacy.zig").commands,
    @import("../../features/status/legacy.zig").commands,
    @import("../../features/sync_input/legacy.zig").commands,
    @import("../../features/terminal_io/legacy.zig").commands,
    @import("../../features/workspaces/legacy.zig").commands,
};

const command_count = @typeInfo(ipc.Command).@"enum".fields.len;

/// Every command's entry, indexed by `@intFromEnum(legacy_json.Command)`.
const by_command: [command_count]LegacyCommand = blk: {
    @setEvalBranchQuota(100_000);
    var result: [command_count]LegacyCommand = undefined;
    var seen: [command_count]bool = @splat(false);
    for (tables) |table| {
        for (table) |entry| {
            const cmd = std.meta.stringToEnum(ipc.Command, entry.cmd) orelse
                @compileError("legacy command table names unknown command: " ++ entry.cmd);
            const idx = @intFromEnum(cmd);
            if (seen[idx]) @compileError("duplicate legacy command: " ++ entry.cmd);
            seen[idx] = true;
            result[idx] = entry;
        }
    }
    for (seen, 0..) |ok, idx| {
        if (!ok) @compileError("legacy command has no handler: " ++
            @tagName(@as(ipc.Command, @enumFromInt(idx))));
    }
    break :blk result;
};

/// The table entry for a parsed command. Total: `parseLine` only yields
/// known commands and the comptime check above guarantees an entry each.
pub fn lookup(cmd: ipc.Command) *const LegacyCommand {
    return &by_command[@intFromEnum(cmd)];
}
