const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");

/// Options exists so the shared CLI machinery (completions, docs,
/// `Action.options()`) has a type to reflect over. `+capture-pane` parses
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

/// The `+capture-pane` command captures the terminal screen text of a pane
/// in a running Ghostty instance — the tmux `capture-pane` equivalent for
/// session restore. It communicates over the per-process agent IPC pipe.
///
/// Usage: `ghostty +capture-pane [--workspace I] [--tab J] [--scrollback] [--file path]`
///
///   * `--workspace I` / `--tab J`: capture the active pane of a tab other
///     than the active one.
///   * `--scrollback`: include the full scrollback history (default: only
///     the visible active screen).
///   * `--file path`: write the dump to the given file instead of returning
///     it over IPC stdout.
///
/// The text is returned as a JSON string (escaped). With `--file`, the
/// file path is returned instead. The dump is plain UTF-8 text.
///
/// The target instance's IPC pipe is `ghostty-ipc-<pid>`. The pid is taken
/// from the `GHOSTTY_PID` environment variable (exported into every shell
/// Ghostty spawns); if it is unset, `+capture-pane` connects to the sole
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
        try stderr.print("+capture-pane is only supported on Windows.\n", .{});
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
        var scrollback = false;
        var file_path: ?[]const u8 = null;
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
            } else if (std.mem.eql(u8, arg, "--scrollback")) {
                scrollback = true;
            } else if (std.mem.startsWith(u8, arg, "--file=")) {
                file_path = arg["--file=".len..];
            } else if (std.mem.eql(u8, arg, "--file")) {
                const v = iter.next() orelse {
                    try stderr.print("--file requires a value\n", .{});
                    return 1;
                };
                file_path = v;
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
        if (scrollback) {
            if (!first) try argbuf.append(alloc, ',');
            try argbuf.appendSlice(alloc, "\"scrollback\":true");
            first = false;
        }
        if (file_path) |fp| {
            if (!first) try argbuf.append(alloc, ',');
            // JSON-escape the file path.
            try argbuf.writer(alloc).print("\"file\":{f}", .{std.json.fmt(fp, .{})});
        }
        try argbuf.append(alloc, '}');

        const request = try std.fmt.allocPrint(
            alloc,
            "{{\"id\":1,\"cmd\":\"capture-pane\",\"args\":{s}}}\n",
            .{argbuf.items},
        );
        defer alloc.free(request);

        return agent_ipc.sendRequest(alloc, request, stdout, stderr);
    }
} else struct {};
