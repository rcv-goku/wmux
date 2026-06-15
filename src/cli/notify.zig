const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");

/// Options exists so the shared CLI machinery (completions, docs,
/// `Action.options()`) has a type to reflect over. `+notify` parses its
/// own positional subcommand and flags in `run`, so the only flag handled
/// here is `--help`.
pub const Options = struct {
    pub fn deinit(self: *Options) void {
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `+notify` command sets or clears the per-pane notification ring (a
/// "needs attention / waiting for input" indicator) of a running Ghostty
/// instance over its per-process agent IPC pipe — the explicit,
/// shell-agnostic counterpart to the attention OSC, alongside
/// `+workspace`, `+tab`, `+send`, and `+browser`.
///
/// Subcommands (both accept `--workspace I` and `--tab J` to target a
/// pane other than the active one):
///
///   * `ring [--workspace I] [--tab J]`: Flag the target tab's active
///     pane for attention. Its sidebar workspace row and top tab show a
///     blue dot, and — when the pane is in a visible split but not the
///     focused pane — a blue ring is drawn around it. The flag clears
///     automatically when the pane gains focus or its tab+workspace
///     become active.
///
///   * `clear [--workspace I] [--tab J]`: Clear the attention flag on the
///     target tab's active pane.
///
///   * `next`: Jump to the most-recent UNREAD entry in the notifications
///     panel — raise its window, select its workspace+tab, and focus its
///     pane (a cross-workspace jump), then mark that entry Read. Replies
///     `{jumped:true,surface:<id>}` on success or `{jumped:false}` when
///     there are no unread notifications. Ignores `--workspace`/`--tab`
///     (the destination is wherever the notifying pane lives).
///
///   * `toggle-read`: Toggle the read/unread state of the most recent
///     notification entry. Replies `{toggled:true,read:<bool>}` on
///     success or `{toggled:false}` when there are no notifications.
///     Ignores `--workspace`/`--tab`.
///
///   * `mark-oldest-next`: Find the oldest unread notification, mark it
///     as read, and jump to the next unread notification's source pane.
///     Replies `{jumped:true,surface:<id>}` or `{jumped:false}` when
///     there are no unread notifications. Ignores `--workspace`/`--tab`.
///
/// The target pane must be a terminal — a browser pane has no terminal
/// surface and is rejected.
///
/// The target instance's IPC pipe is `ghostty-ipc-<pid>`. The pid is taken
/// from the `GHOSTTY_PID` environment variable (exported into every shell
/// Ghostty spawns); if it is unset, `+notify` connects to the sole
/// `ghostty-ipc-*` pipe present and errors if there are zero or more than
/// one.
///
/// Only supported on Windows.
///
/// Available since: 1.2.0
pub fn run(alloc: Allocator) !u8 {
    if (comptime builtin.os.tag != .windows) {
        var buf: [256]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&buf);
        const stderr = &stderr_writer.interface;
        try stderr.print("+notify is only supported on Windows.\n", .{});
        stderr.flush() catch {};
        return 1;
    }

    return windows_impl.run(alloc);
}

/// All Windows-specific machinery, kept in a struct so the whole thing is
/// only semantically analyzed on Windows.
const windows_impl = if (builtin.os.tag == .windows) struct {
    const agent_ipc = @import("agent_ipc.zig").impl;

    fn run(alloc: Allocator) !u8 {
        var out_buf: [4096]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&out_buf);
        const stdout = &stdout_writer.interface;
        var err_buf: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&err_buf);
        const stderr = &stderr_writer.interface;

        const code = runImpl(alloc, stdout, stderr) catch |err| blk: {
            stderr.print("error: {s}\n", .{@errorName(err)}) catch {};
            break :blk @as(u8, 1);
        };
        stdout.flush() catch {};
        stderr.flush() catch {};
        return code;
    }

    const Command = enum { ring, clear, next, @"toggle-read", @"mark-oldest-next" };

    fn runImpl(
        alloc: Allocator,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !u8 {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();

        const sub_str = iter.next() orelse {
            try stderr.print("usage: ghostty +notify <ring|clear|next|toggle-read|mark-oldest-next> [--workspace I] [--tab J]\n", .{});
            return 1;
        };
        if (std.mem.eql(u8, sub_str, "--help") or std.mem.eql(u8, sub_str, "-h")) {
            return Action.help_error;
        }
        const sub = std.meta.stringToEnum(Command, sub_str) orelse {
            try stderr.print("unknown subcommand '{s}'\n", .{sub_str});
            return 1;
        };

        var workspace: ?u32 = null;
        var tab: ?u32 = null;
        while (iter.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--workspace=")) {
                workspace = std.fmt.parseInt(u32, arg["--workspace=".len..], 10) catch {
                    try stderr.print("invalid --workspace value\n", .{});
                    return 1;
                };
            } else if (std.mem.eql(u8, arg, "--workspace")) {
                const v = iter.next() orelse {
                    try stderr.print("--workspace requires a value\n", .{});
                    return 1;
                };
                workspace = std.fmt.parseInt(u32, v, 10) catch {
                    try stderr.print("invalid --workspace value\n", .{});
                    return 1;
                };
            } else if (std.mem.startsWith(u8, arg, "--tab=")) {
                tab = std.fmt.parseInt(u32, arg["--tab=".len..], 10) catch {
                    try stderr.print("invalid --tab value\n", .{});
                    return 1;
                };
            } else if (std.mem.eql(u8, arg, "--tab")) {
                const v = iter.next() orelse {
                    try stderr.print("--tab requires a value\n", .{});
                    return 1;
                };
                tab = std.fmt.parseInt(u32, v, 10) catch {
                    try stderr.print("invalid --tab value\n", .{});
                    return 1;
                };
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return Action.help_error;
            } else if (std.mem.startsWith(u8, arg, "--")) {
                try stderr.print("unknown flag '{s}'\n", .{arg});
                return 1;
            } else {
                try stderr.print("unexpected argument '{s}'\n", .{arg});
                return 1;
            }
        }

        // Build the args object: action is required; workspace/tab are
        // optional and only emitted when present.
        var argbuf: std.ArrayList(u8) = .empty;
        defer argbuf.deinit(alloc);
        try argbuf.writer(alloc).print("{{\"action\":\"{s}\"", .{@tagName(sub)});
        if (workspace) |n| try argbuf.writer(alloc).print(",\"workspace\":{d}", .{n});
        if (tab) |n| try argbuf.writer(alloc).print(",\"tab\":{d}", .{n});
        try argbuf.append(alloc, '}');

        const request = try std.fmt.allocPrint(
            alloc,
            "{{\"id\":1,\"cmd\":\"notify\",\"args\":{s}}}\n",
            .{argbuf.items},
        );
        defer alloc.free(request);

        return agent_ipc.sendRequest(alloc, request, stdout, stderr);
    }
} else struct {};
