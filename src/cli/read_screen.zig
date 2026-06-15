const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");

/// Options exists so the shared CLI machinery (completions, docs,
/// `Action.options()`) has a type to reflect over. `+read-screen` parses
/// its own flags in `run`, so the only flag handled here is `--help`.
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

/// The `+read-screen` command returns the terminal screen text of a pane in
/// a running Ghostty instance over its per-process agent IPC pipe. This is
/// the agent-reads-agent primitive: one agent can read what another agent's
/// pane is showing (echo a sentinel in one pane, read it back from
/// another), the foundation of supervised multi-agent flows.
///
/// Usage: `ghostty +read-screen [--workspace I] [--tab J] [--lines N] [--scrollback]`
///
///   * `--workspace I` / `--tab J`: read the active pane of a tab other
///     than the active one.
///   * `--lines N`: return only the last N physical lines of the dump.
///   * `--scrollback`: include the full scrollback history (default: only
///     the visible active screen).
///
/// The text is returned as a JSON string (escaped). v1 limitation: the
/// dump is the terminal's logical screen/scrollback text, not a
/// pixel-accurate render, and very long scrollback is truncated to fit the
/// IPC message size (~768 KiB).
///
/// The target instance's IPC pipe is `ghostty-ipc-<pid>`. The pid is taken
/// from the `GHOSTTY_PID` environment variable (exported into every shell
/// Ghostty spawns); if it is unset, `+read-screen` connects to the sole
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
        try stderr.print("+read-screen is only supported on Windows.\n", .{});
        stderr.flush() catch {};
        return 1;
    }

    return windows_impl.run(alloc);
}

const windows_impl = if (builtin.os.tag == .windows) struct {
    const agent_ipc = @import("agent_ipc.zig").impl;

    fn run(alloc: Allocator) !u8 {
        // Screen dumps can be large; give stdout a generous buffer.
        var out_buf: [64 * 1024]u8 = undefined;
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

    fn runImpl(
        alloc: Allocator,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !u8 {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();

        var workspace: ?u32 = null;
        var tab: ?u32 = null;
        var lines: ?u32 = null;
        var scrollback = false;
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
            } else if (std.mem.startsWith(u8, arg, "--lines=")) {
                lines = std.fmt.parseInt(u32, arg["--lines=".len..], 10) catch {
                    try stderr.print("invalid --lines value\n", .{});
                    return 1;
                };
            } else if (std.mem.eql(u8, arg, "--lines")) {
                const v = iter.next() orelse {
                    try stderr.print("--lines requires a value\n", .{});
                    return 1;
                };
                lines = std.fmt.parseInt(u32, v, 10) catch {
                    try stderr.print("invalid --lines value\n", .{});
                    return 1;
                };
            } else if (std.mem.eql(u8, arg, "--scrollback")) {
                scrollback = true;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return Action.help_error;
            } else {
                try stderr.print("unexpected argument '{s}'\n", .{arg});
                return 1;
            }
        }

        var argbuf: std.ArrayList(u8) = .empty;
        defer argbuf.deinit(alloc);
        try argbuf.append(alloc, '{');
        var first = true;
        if (workspace) |n| {
            try argbuf.writer(alloc).print("\"workspace\":{d}", .{n});
            first = false;
        }
        if (tab) |n| {
            if (!first) try argbuf.append(alloc, ',');
            try argbuf.writer(alloc).print("\"tab\":{d}", .{n});
            first = false;
        }
        if (lines) |n| {
            if (!first) try argbuf.append(alloc, ',');
            try argbuf.writer(alloc).print("\"lines\":{d}", .{n});
            first = false;
        }
        if (scrollback) {
            if (!first) try argbuf.append(alloc, ',');
            try argbuf.appendSlice(alloc, "\"scrollback\":true");
        }
        try argbuf.append(alloc, '}');

        const request = try std.fmt.allocPrint(
            alloc,
            "{{\"id\":1,\"cmd\":\"read-screen\",\"args\":{s}}}\n",
            .{argbuf.items},
        );
        defer alloc.free(request);

        return agent_ipc.sendRequest(alloc, request, stdout, stderr);
    }
} else struct {};
