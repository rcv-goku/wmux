const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");

/// Options exists so the shared CLI machinery (completions, docs,
/// `Action.options()`) has a type to reflect over. `+tab` parses its own
/// positional subcommand and arguments in `run`, so the only flag handled
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

/// The `+tab` command drives the per-workspace tabs of a running Ghostty
/// instance over its per-process agent IPC pipe, enabling scripted/agentic
/// control alongside `+workspace`, `+send`, and `+browser`.
///
/// Subcommands (all accept `--workspace I` to target a workspace other than
/// the active one):
///
///   * `list [--workspace I]`: Print a JSON array of the target
///     workspace's tabs, one object per tab: `{index, title, active}`.
///
///   * `new [--workspace I] [--command "..."] [--focus]`: Add a tab and
///     print its index as `{index: N}`. With `--command` the tab runs that
///     command (split on whitespace into an argv); without it the tab
///     inherits the active pane's backend (the same behavior as the tab
///     bar "+"). By DEFAULT the tab is created in the background: the
///     active workspace/tab does not change and the window is not raised
///     (so an agent spawning tabs never yanks you out of your current
///     app). Pass `--focus` to switch to the tab's workspace and select
///     the new tab. The printed index is relative to the target workspace
///     — the same index `list`/`close` use for that workspace.
///
///   * `select <index> [--workspace I]`: Make tab `<index>` active.
///
///   * `close <index> [--workspace I]`: Close tab `<index>`. Closing the
///     last tab collapses its workspace (or closes the window if it was
///     the only workspace).
///
/// The target instance's IPC pipe is `ghostty-ipc-<pid>`. The pid is taken
/// from the `GHOSTTY_PID` environment variable (exported into every shell
/// Ghostty spawns); if it is unset, `+tab` connects to the sole
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
        try stderr.print("+tab is only supported on Windows.\n", .{});
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

    const Command = enum { list, new, select, close };

    fn runImpl(
        alloc: Allocator,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !u8 {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();

        const sub_str = iter.next() orelse {
            try stderr.print("usage: ghostty +tab <list|new|select|close> [args]\n", .{});
            return 1;
        };
        if (std.mem.eql(u8, sub_str, "--help") or std.mem.eql(u8, sub_str, "-h")) {
            return Action.help_error;
        }
        const sub = std.meta.stringToEnum(Command, sub_str) orelse {
            try stderr.print("unknown subcommand '{s}'\n", .{sub_str});
            return 1;
        };

        var positional: ?[]const u8 = null;
        var workspace: ?u32 = null;
        var command: ?[]const u8 = null;
        var focus = false;
        while (iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--focus")) {
                focus = true;
            } else if (std.mem.startsWith(u8, arg, "--workspace=")) {
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
            } else if (std.mem.startsWith(u8, arg, "--command=")) {
                command = try alloc.dupe(u8, arg["--command=".len..]);
            } else if (std.mem.eql(u8, arg, "--command")) {
                const v = iter.next() orelse {
                    try stderr.print("--command requires a value\n", .{});
                    return 1;
                };
                command = try alloc.dupe(u8, v);
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return Action.help_error;
            } else if (std.mem.startsWith(u8, arg, "--")) {
                try stderr.print("unknown flag '{s}'\n", .{arg});
                return 1;
            } else if (positional == null) {
                positional = try alloc.dupe(u8, arg);
            } else {
                try stderr.print("unexpected argument '{s}'\n", .{arg});
                return 1;
            }
        }

        // Build the args object incrementally so optional fields
        // (workspace/command/index) only appear when present and commas
        // stay correct. The args object is shared by all subcommands.
        var argbuf: std.ArrayList(u8) = .empty;
        defer argbuf.deinit(alloc);
        try argbuf.append(alloc, '{');
        var have_field = false;

        if (sub == .select or sub == .close) {
            const idx = try parseIndex(positional, stderr) orelse return 1;
            try argbuf.writer(alloc).print("\"index\":{d}", .{idx});
            have_field = true;
        }
        if (workspace) |n| {
            if (have_field) try argbuf.append(alloc, ',');
            try argbuf.writer(alloc).print("\"workspace\":{d}", .{n});
            have_field = true;
        }
        if (sub == .new) {
            if (command) |c| {
                if (have_field) try argbuf.append(alloc, ',');
                try argbuf.writer(alloc).print("\"command\":{f}", .{std.json.fmt(c, .{})});
                have_field = true;
            }
            // Non-focus is the default; only emit focus when opted in so a
            // plain `tab new` stays a background create.
            if (focus) {
                if (have_field) try argbuf.append(alloc, ',');
                try argbuf.writer(alloc).print("\"focus\":true", .{});
                have_field = true;
            }
        } else if (focus) {
            try stderr.print("--focus is only valid for 'new'\n", .{});
            return 1;
        }
        try argbuf.append(alloc, '}');

        const cmd_name = switch (sub) {
            .list => "tab-list",
            .new => "tab-new",
            .select => "tab-select",
            .close => "tab-close",
        };
        const request = try std.fmt.allocPrint(
            alloc,
            "{{\"id\":1,\"cmd\":\"{s}\",\"args\":{s}}}\n",
            .{ cmd_name, argbuf.items },
        );
        defer alloc.free(request);

        return agent_ipc.sendRequest(alloc, request, stdout, stderr);
    }

    /// Parse the required <index> positional. Returns null (after
    /// printing an error) when missing or non-numeric.
    fn parseIndex(positional: ?[]const u8, stderr: *std.Io.Writer) !?u32 {
        const s = positional orelse {
            try stderr.print("this subcommand requires an <index>\n", .{});
            return null;
        };
        return std.fmt.parseInt(u32, s, 10) catch {
            try stderr.print("invalid <index> (must be a non-negative integer)\n", .{});
            return null;
        };
    }
} else struct {};
