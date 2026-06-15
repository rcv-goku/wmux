const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");

/// Options exists so the shared CLI machinery (completions, docs,
/// `Action.options()`) has a type to reflect over. `+status` parses its
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

/// The `+status` command sets the per-tab orchestration status string and
/// progress of a running Ghostty instance over its per-process agent IPC
/// pipe — the agent-pushed metadata the session sidebar renders, alongside
/// `+log` and `+notify`.
///
/// Subcommands (both accept `--workspace I` and `--tab J` to target a tab
/// other than the active one):
///
///   * `set <text>`: Set the addressed tab's status string ("running
///     tests", "waiting", "blocked", ...). An empty `""` clears it.
///
///   * `progress <0-100|clear>`: Set the addressed tab's progress percent
///     (rendered as a thin bar under the row), or `clear` to remove it.
///
/// The target instance's IPC pipe is `ghostty-ipc-<pid>`. The pid is taken
/// from the `GHOSTTY_PID` environment variable (exported into every shell
/// Ghostty spawns); if it is unset, `+status` connects to the sole
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
        try stderr.print("+status is only supported on Windows.\n", .{});
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

    const Command = enum { set, progress };

    fn runImpl(
        alloc: Allocator,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !u8 {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();

        const sub_str = iter.next() orelse {
            try stderr.print("usage: ghostty +status <set <text>|progress <0-100|clear>> [--workspace I] [--tab J]\n", .{});
            return 1;
        };
        if (std.mem.eql(u8, sub_str, "--help") or std.mem.eql(u8, sub_str, "-h")) {
            return Action.help_error;
        }
        const sub = std.meta.stringToEnum(Command, sub_str) orelse {
            try stderr.print("unknown subcommand '{s}'\n", .{sub_str});
            return 1;
        };

        // The first non-flag positional is the value (status text or
        // progress). Flags may appear before or after it.
        var value: ?[]const u8 = null;
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
            } else if (value == null) {
                value = arg;
            } else {
                try stderr.print("unexpected argument '{s}'\n", .{arg});
                return 1;
            }
        }

        switch (sub) {
            .set => {
                // Empty/absent text clears the status.
                const text = value orelse "";
                var argbuf: std.ArrayList(u8) = .empty;
                defer argbuf.deinit(alloc);
                try argbuf.writer(alloc).print("{{\"text\":{f}", .{std.json.fmt(text, .{})});
                if (workspace) |n| try argbuf.writer(alloc).print(",\"workspace\":{d}", .{n});
                if (tab) |n| try argbuf.writer(alloc).print(",\"tab\":{d}", .{n});
                try argbuf.append(alloc, '}');
                const request = try std.fmt.allocPrint(
                    alloc,
                    "{{\"id\":1,\"cmd\":\"set-status\",\"args\":{s}}}\n",
                    .{argbuf.items},
                );
                defer alloc.free(request);
                return agent_ipc.sendRequest(alloc, request, stdout, stderr);
            },
            .progress => {
                const v = value orelse {
                    try stderr.print("progress requires a value (0-100 or 'clear')\n", .{});
                    return 1;
                };
                const num: i64 = if (std.mem.eql(u8, v, "clear"))
                    -1
                else
                    std.fmt.parseInt(i64, v, 10) catch {
                        try stderr.print("invalid progress value '{s}' (use 0-100 or 'clear')\n", .{v});
                        return 1;
                    };
                if (num > 100) {
                    try stderr.print("progress must be 0-100 or 'clear'\n", .{});
                    return 1;
                }
                var argbuf: std.ArrayList(u8) = .empty;
                defer argbuf.deinit(alloc);
                try argbuf.writer(alloc).print("{{\"value\":{d}", .{num});
                if (workspace) |n| try argbuf.writer(alloc).print(",\"workspace\":{d}", .{n});
                if (tab) |n| try argbuf.writer(alloc).print(",\"tab\":{d}", .{n});
                try argbuf.append(alloc, '}');
                const request = try std.fmt.allocPrint(
                    alloc,
                    "{{\"id\":1,\"cmd\":\"set-progress\",\"args\":{s}}}\n",
                    .{argbuf.items},
                );
                defer alloc.free(request);
                return agent_ipc.sendRequest(alloc, request, stdout, stderr);
            },
        }
    }
} else struct {};
