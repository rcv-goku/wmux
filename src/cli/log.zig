const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");

/// Options exists so the shared CLI machinery (completions, docs,
/// `Action.options()`) has a type to reflect over. `+log` parses its own
/// positional text and flags in `run`, so the only flag handled here is
/// `--help`.
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

/// The `+log` command appends a line to a tab's ring log buffer of a
/// running Ghostty instance over its per-process agent IPC pipe. The latest
/// line is surfaced as the workspace row's "latest" text in the session
/// sidebar and pushed into the notification panel, alongside `+status` and
/// `+notify`.
///
/// Usage: `ghostty +log <text> [--workspace I] [--tab J]`
///
///   * `<text>`: the line to append (truncated to a small per-line cap).
///   * `--workspace I` / `--tab J`: target a tab other than the active one.
///
/// The target instance's IPC pipe is `ghostty-ipc-<pid>`. The pid is taken
/// from the `GHOSTTY_PID` environment variable (exported into every shell
/// Ghostty spawns); if it is unset, `+log` connects to the sole
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
        try stderr.print("+log is only supported on Windows.\n", .{});
        stderr.flush() catch {};
        return 1;
    }

    return windows_impl.run(alloc);
}

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

        var text: ?[]const u8 = null;
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
            } else if (text == null) {
                text = arg;
            } else {
                try stderr.print("unexpected argument '{s}'\n", .{arg});
                return 1;
            }
        }

        const line = text orelse {
            try stderr.print("usage: ghostty +log <text> [--workspace I] [--tab J]\n", .{});
            return 1;
        };

        var argbuf: std.ArrayList(u8) = .empty;
        defer argbuf.deinit(alloc);
        try argbuf.writer(alloc).print("{{\"text\":{f}", .{std.json.fmt(line, .{})});
        if (workspace) |n| try argbuf.writer(alloc).print(",\"workspace\":{d}", .{n});
        if (tab) |n| try argbuf.writer(alloc).print(",\"tab\":{d}", .{n});
        try argbuf.append(alloc, '}');

        const request = try std.fmt.allocPrint(
            alloc,
            "{{\"id\":1,\"cmd\":\"log\",\"args\":{s}}}\n",
            .{argbuf.items},
        );
        defer alloc.free(request);

        return agent_ipc.sendRequest(alloc, request, stdout, stderr);
    }
} else struct {};
