const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");

/// Options exists so the shared CLI machinery (completions, docs,
/// `Action.options()`) has a type to reflect over. `+session` parses its
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

/// The `+session` command captures and replays an agent's native session id
/// for a pane of a running Ghostty instance, so a pane can be relaunched
/// with the agent's own resume command (`claude --resume <id>`,
/// `codex resume <id>`, ...). The capture half is normally driven by the
/// per-agent `SessionStart` hook installed by `ghostty +hooks setup`.
///
/// Subcommands:
///
///   * `capture --kind <agent> --id <session-id> [--surface SID]`: Record
///     that `<agent>` (claude_code, codex, opencode, gemini, aider, ...) is
///     running in the calling pane with native session id `<session-id>`.
///     `--surface SID` names the pane explicitly by its `GHOSTTY_SURFACE_ID`
///     (what a hook should pass, since it runs in its own pane); without it
///     the active pane is used. (`--agent`/`--session` are accepted as
///     aliases for `--kind`/`--id`.)
///
///   * `resume [--surface SID] [--workspace I --tab J]`: Look up the
///     captured agent + id for the addressed pane and replay the agent's
///     resume command into it (typed as a line + Enter).
///
///   * `show [--json]`: Print the whole session store. `--json` is the
///     default and only format today: `[{surface, agent, session}]`.
///
/// The target instance's IPC pipe is `ghostty-ipc-<pid>`. The pid is taken
/// from the `GHOSTTY_PID` environment variable (exported into every shell
/// Ghostty spawns); if it is unset, `+session` connects to the sole
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
        try stderr.print("+session is only supported on Windows.\n", .{});
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

    const Command = enum { capture, @"resume", show };

    fn runImpl(
        alloc: Allocator,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !u8 {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();

        const sub_str = iter.next() orelse {
            try stderr.print("usage: ghostty +session <capture|resume|show> [...]\n", .{});
            return 1;
        };
        if (std.mem.eql(u8, sub_str, "--help") or std.mem.eql(u8, sub_str, "-h")) {
            return Action.help_error;
        }
        const sub = std.meta.stringToEnum(Command, sub_str) orelse {
            try stderr.print("unknown subcommand '{s}'\n", .{sub_str});
            return 1;
        };

        var kind: ?[]const u8 = null;
        var id: ?[]const u8 = null;
        var surface: ?u64 = null;
        var workspace: ?u32 = null;
        var tab: ?u32 = null;
        while (iter.next()) |arg| {
            if (try strFlag(arg, &iter, "--kind", &kind, stderr)) |c| {
                if (c == 1) return 1 else continue;
            } else if (try strFlag(arg, &iter, "--agent", &kind, stderr)) |c| {
                if (c == 1) return 1 else continue;
            } else if (try strFlag(arg, &iter, "--id", &id, stderr)) |c| {
                if (c == 1) return 1 else continue;
            } else if (try strFlag(arg, &iter, "--session", &id, stderr)) |c| {
                if (c == 1) return 1 else continue;
            } else if (try u64Flag(arg, &iter, "--surface", &surface, stderr)) |c| {
                if (c == 1) return 1 else continue;
            } else if (try u32Flag(arg, &iter, "--workspace", &workspace, stderr)) |c| {
                if (c == 1) return 1 else continue;
            } else if (try u32Flag(arg, &iter, "--tab", &tab, stderr)) |c| {
                if (c == 1) return 1 else continue;
            } else if (std.mem.eql(u8, arg, "--json")) {
                // show's only/default format; accept and ignore.
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

        switch (sub) {
            .capture => {
                const k = kind orelse {
                    try stderr.print("capture requires --kind <agent>\n", .{});
                    return 1;
                };
                const i = id orelse {
                    try stderr.print("capture requires --id <session-id>\n", .{});
                    return 1;
                };
                var argbuf: std.ArrayList(u8) = .empty;
                defer argbuf.deinit(alloc);
                try argbuf.writer(alloc).print("{{\"agent\":{f}", .{std.json.fmt(k, .{})});
                try argbuf.writer(alloc).print(",\"session\":{f}", .{std.json.fmt(i, .{})});
                if (surface) |s| try argbuf.writer(alloc).print(",\"surface\":{d}", .{s});
                try argbuf.append(alloc, '}');
                const request = try std.fmt.allocPrint(
                    alloc,
                    "{{\"id\":1,\"cmd\":\"session-capture\",\"args\":{s}}}\n",
                    .{argbuf.items},
                );
                defer alloc.free(request);
                return agent_ipc.sendRequest(alloc, request, stdout, stderr);
            },
            .@"resume" => {
                var argbuf: std.ArrayList(u8) = .empty;
                defer argbuf.deinit(alloc);
                try argbuf.append(alloc, '{');
                var first = true;
                if (surface) |s| {
                    try argbuf.writer(alloc).print("\"surface\":{d}", .{s});
                    first = false;
                }
                if (workspace) |n| {
                    if (!first) try argbuf.append(alloc, ',');
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
                    "{{\"id\":1,\"cmd\":\"session-resume\",\"args\":{s}}}\n",
                    .{argbuf.items},
                );
                defer alloc.free(request);
                return agent_ipc.sendRequest(alloc, request, stdout, stderr);
            },
            .show => {
                const request = "{\"id\":1,\"cmd\":\"session-list\"}\n";
                return agent_ipc.sendRequest(alloc, request, stdout, stderr);
            },
        }
    }

    fn strFlag(
        arg: []const u8,
        iter: anytype,
        comptime name: []const u8,
        out: *?[]const u8,
        stderr: *std.Io.Writer,
    ) !?u8 {
        if (std.mem.startsWith(u8, arg, name ++ "=")) {
            out.* = arg[(name ++ "=").len..];
            return 0;
        } else if (std.mem.eql(u8, arg, name)) {
            out.* = iter.next() orelse {
                try stderr.print("{s} requires a value\n", .{name});
                return 1;
            };
            return 0;
        }
        return null;
    }

    fn u32Flag(
        arg: []const u8,
        iter: anytype,
        comptime name: []const u8,
        out: *?u32,
        stderr: *std.Io.Writer,
    ) !?u8 {
        var raw: ?[]const u8 = null;
        const matched = try strFlag(arg, iter, name, &raw, stderr);
        if (matched == null) return null;
        if (matched.? == 1) return 1;
        out.* = std.fmt.parseInt(u32, raw.?, 10) catch {
            try stderr.print("invalid {s} value\n", .{name});
            return 1;
        };
        return 0;
    }

    fn u64Flag(
        arg: []const u8,
        iter: anytype,
        comptime name: []const u8,
        out: *?u64,
        stderr: *std.Io.Writer,
    ) !?u8 {
        var raw: ?[]const u8 = null;
        const matched = try strFlag(arg, iter, name, &raw, stderr);
        if (matched == null) return null;
        if (matched.? == 1) return 1;
        // base 0 auto-detects radix: GHOSTTY_SURFACE_ID is exported to the
        // shell as a hex string ("0x...") while +surface list prints ids in
        // decimal, so both forms must parse.
        out.* = std.fmt.parseInt(u64, raw.?, 0) catch {
            try stderr.print("invalid {s} value\n", .{name});
            return 1;
        };
        return 0;
    }
} else struct {};
