const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");

/// Options exists so the shared CLI machinery (completions, docs,
/// `Action.options()`) has a type to reflect over. `+send` parses its own
/// positional argument and flags in `run`, so the only flag handled here
/// is `--help`.
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

/// The `+send` command writes text to a terminal pane of a running Ghostty
/// instance over its per-process agent IPC pipe, as if the text had been
/// typed — the "send keystrokes" primitive for scripting/agentic control
/// alongside `+workspace`, `+tab`, and `+browser`.
///
///   `+send <text> [--workspace I] [--tab J] [--enter]`
///
/// The text is written to the child PTY of the active pane of the target
/// tab. Without `--workspace`/`--tab` the active workspace's active tab is
/// used. `--enter` appends a carriage return so the line is submitted (the
/// Enter key's PTY encoding). The target pane must be a terminal — a
/// browser pane has no PTY and is rejected.
///
/// The target instance's IPC pipe is `ghostty-ipc-<pid>`. The pid is taken
/// from the `GHOSTTY_PID` environment variable (exported into every shell
/// Ghostty spawns); if it is unset, `+send` connects to the sole
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
        try stderr.print("+send is only supported on Windows.\n", .{});
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

    fn runImpl(
        alloc: Allocator,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !u8 {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();

        // argsIterator skips argv0 AND the "+send" action selector, so the
        // first value here is the <text> positional (or a flag).
        var text: ?[]const u8 = null;
        var workspace: ?u32 = null;
        var tab: ?u32 = null;
        var enter = false;
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
            } else if (std.mem.eql(u8, arg, "--enter")) {
                enter = true;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return Action.help_error;
            } else if (std.mem.startsWith(u8, arg, "--")) {
                try stderr.print("unknown flag '{s}'\n", .{arg});
                return 1;
            } else if (text == null) {
                text = try alloc.dupe(u8, arg);
            } else {
                try stderr.print("unexpected argument '{s}'\n", .{arg});
                return 1;
            }
        }

        const send_text = text orelse {
            try stderr.print("send requires a <text> argument\n", .{});
            return 1;
        };

        // Build the args object: text is required; workspace/tab/enter are
        // optional and only emitted when set.
        var argbuf: std.ArrayList(u8) = .empty;
        defer argbuf.deinit(alloc);
        try argbuf.writer(alloc).print("{{\"text\":{f}", .{std.json.fmt(send_text, .{})});
        if (workspace) |n| try argbuf.writer(alloc).print(",\"workspace\":{d}", .{n});
        if (tab) |n| try argbuf.writer(alloc).print(",\"tab\":{d}", .{n});
        if (enter) try argbuf.appendSlice(alloc, ",\"enter\":true");
        try argbuf.append(alloc, '}');

        const request = try std.fmt.allocPrint(
            alloc,
            "{{\"id\":1,\"cmd\":\"send\",\"args\":{s}}}\n",
            .{argbuf.items},
        );
        defer alloc.free(request);

        return agent_ipc.sendRequest(alloc, request, stdout, stderr);
    }
} else struct {};
