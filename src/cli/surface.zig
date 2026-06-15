const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");

/// Options exists so the shared CLI machinery (completions, docs,
/// `Action.options()`) has a type to reflect over. `+surface` parses its
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

/// The `+surface` command lists and focuses the terminal/browser panes of a
/// running Ghostty instance over its per-process agent IPC pipe — the
/// addressing primitive an orchestrator uses to see and switch between the
/// panes running agents, alongside `+workspace`, `+tab`, `+split`, and
/// `+read-screen`.
///
/// Subcommands:
///
///   * `list [--workspace I] [--tab J]`: Print a JSON array of the panes in
///     the addressed (or active) tab: `[{id, kind, focused, title}]`. `id`
///     is the stable surface id (the same value exported to shells as
///     `GHOSTTY_SURFACE_ID`) for terminal panes, or the browser pane id for
///     browser panes; `kind` is "terminal" or "browser" and disambiguates
///     the id space. A terminal whose core has not finished starting up
///     reports id 0.
///
///   * `focus <id>`: Focus the pane with stable surface `id`, selecting its
///     window, workspace, and tab. Alternatively address a pane by position
///     with `--workspace I --tab J --pane K` (K is the pane's index within
///     the tab in split-tree iteration order).
///
/// The target instance's IPC pipe is `ghostty-ipc-<pid>`. The pid is taken
/// from the `GHOSTTY_PID` environment variable (exported into every shell
/// Ghostty spawns); if it is unset, `+surface` connects to the sole
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
        try stderr.print("+surface is only supported on Windows.\n", .{});
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

    const Command = enum { list, focus };

    fn runImpl(
        alloc: Allocator,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !u8 {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();

        const sub_str = iter.next() orelse {
            try stderr.print("usage: ghostty +surface <list|focus> [...]\n", .{});
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
        var pane: ?u32 = null;
        var surface: ?u64 = null;
        while (iter.next()) |arg| {
            if (try parseU32Flag(arg, &iter, "--workspace", &workspace, stderr)) |c| {
                if (c == 1) return 1 else continue;
            } else if (try parseU32Flag(arg, &iter, "--tab", &tab, stderr)) |c| {
                if (c == 1) return 1 else continue;
            } else if (try parseU32Flag(arg, &iter, "--pane", &pane, stderr)) |c| {
                if (c == 1) return 1 else continue;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return Action.help_error;
            } else if (std.mem.startsWith(u8, arg, "--")) {
                try stderr.print("unknown flag '{s}'\n", .{arg});
                return 1;
            } else if (sub == .focus and surface == null) {
                // The positional <id> for `focus`. base 0 auto-detects radix
                // so the hex GHOSTTY_SURFACE_ID ("0x...") and the decimal id
                // printed by +surface list both parse.
                surface = std.fmt.parseInt(u64, arg, 0) catch {
                    try stderr.print("invalid surface id '{s}'\n", .{arg});
                    return 1;
                };
            } else {
                try stderr.print("unexpected argument '{s}'\n", .{arg});
                return 1;
            }
        }

        switch (sub) {
            .list => {
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
                }
                try argbuf.append(alloc, '}');
                const request = try std.fmt.allocPrint(
                    alloc,
                    "{{\"id\":1,\"cmd\":\"surface-list\",\"args\":{s}}}\n",
                    .{argbuf.items},
                );
                defer alloc.free(request);
                return agent_ipc.sendRequest(alloc, request, stdout, stderr);
            },
            .focus => {
                var argbuf: std.ArrayList(u8) = .empty;
                defer argbuf.deinit(alloc);
                try argbuf.append(alloc, '{');
                if (surface) |sid| {
                    try argbuf.writer(alloc).print("\"surface\":{d}", .{sid});
                } else {
                    // Address by position: pane is required in this mode.
                    const p = pane orelse {
                        try stderr.print("focus needs a surface <id>, or --workspace/--tab/--pane\n", .{});
                        return 1;
                    };
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
                    if (!first) try argbuf.append(alloc, ',');
                    try argbuf.writer(alloc).print("\"pane\":{d}", .{p});
                }
                try argbuf.append(alloc, '}');
                const request = try std.fmt.allocPrint(
                    alloc,
                    "{{\"id\":1,\"cmd\":\"surface-focus\",\"args\":{s}}}\n",
                    .{argbuf.items},
                );
                defer alloc.free(request);
                return agent_ipc.sendRequest(alloc, request, stdout, stderr);
            },
        }
    }

    /// Parse a `--flag value` / `--flag=value` u32 option. Returns null when
    /// `arg` is not this flag; 0 on success (value stored); 1 on a parse
    /// error (already reported to stderr).
    fn parseU32Flag(
        arg: []const u8,
        iter: anytype,
        comptime name: []const u8,
        out: *?u32,
        stderr: *std.Io.Writer,
    ) !?u8 {
        if (std.mem.startsWith(u8, arg, name ++ "=")) {
            out.* = std.fmt.parseInt(u32, arg[(name ++ "=").len..], 10) catch {
                try stderr.print("invalid {s} value\n", .{name});
                return 1;
            };
            return 0;
        } else if (std.mem.eql(u8, arg, name)) {
            const v = iter.next() orelse {
                try stderr.print("{s} requires a value\n", .{name});
                return 1;
            };
            out.* = std.fmt.parseInt(u32, v, 10) catch {
                try stderr.print("invalid {s} value\n", .{name});
                return 1;
            };
            return 0;
        }
        return null;
    }
} else struct {};
