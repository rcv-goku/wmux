const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");

/// Options exists so the shared CLI machinery (completions, docs,
/// `Action.options()`) has a type to reflect over. `+split` parses its own
/// positional direction and flags in `run`, so the only flag handled here
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

/// The `+split` command splits a terminal pane of a running Ghostty
/// instance over its per-process agent IPC pipe and prints the new pane's
/// surface id — the primitive an orchestrator uses to spawn a teammate pane
/// next to an existing one, alongside `+surface`, `+send`, and `+tab`.
///
/// Usage: `ghostty +split <right|down> [--workspace I] [--tab J] [--command "..."] [--focus]`
///
///   * `<right|down>`: split the addressed (or active) pane horizontally
///     (right) or vertically (down).
///   * `--workspace I` / `--tab J`: address a tab other than the active one;
///     its active pane is the one that gets split.
///   * `--command "prog arg ..."`: run this command in the new pane (split
///     on whitespace). Without it, the new pane inherits the source pane's
///     backend (the same shell), matching the UI split behavior.
///   * `--focus`: by DEFAULT the split is created in the background — the
///     active workspace/tab/pane and the OS foreground are NOT changed (an
///     agent spawning a teammate pane never yanks you out of your current
///     app or pane). Pass `--focus` to switch to the target workspace/tab
///     and focus the new pane (the interactive split behavior).
///
/// On success, prints `{"id":<surface-id>}` — the new pane's stable surface
/// id (the same value the pane's shell sees as `GHOSTTY_SURFACE_ID`), or 0
/// if its core has not finished starting up.
///
/// The target instance's IPC pipe is `ghostty-ipc-<pid>`. The pid is taken
/// from the `GHOSTTY_PID` environment variable (exported into every shell
/// Ghostty spawns); if it is unset, `+split` connects to the sole
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
        try stderr.print("+split is only supported on Windows.\n", .{});
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

        const dir_str = iter.next() orelse {
            try stderr.print("usage: ghostty +split <right|down> [--workspace I] [--tab J] [--command \"...\"]\n", .{});
            return 1;
        };
        if (std.mem.eql(u8, dir_str, "--help") or std.mem.eql(u8, dir_str, "-h")) {
            return Action.help_error;
        }
        if (!std.mem.eql(u8, dir_str, "right") and !std.mem.eql(u8, dir_str, "down")) {
            try stderr.print("direction must be 'right' or 'down', got '{s}'\n", .{dir_str});
            return 1;
        }

        var workspace: ?u32 = null;
        var tab: ?u32 = null;
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
            } else if (std.mem.startsWith(u8, arg, "--command=")) {
                command = arg["--command=".len..];
            } else if (std.mem.eql(u8, arg, "--command")) {
                command = iter.next() orelse {
                    try stderr.print("--command requires a value\n", .{});
                    return 1;
                };
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return Action.help_error;
            } else {
                try stderr.print("unexpected argument '{s}'\n", .{arg});
                return 1;
            }
        }

        // Build the args object. dir is required; the rest are optional.
        var argbuf: std.ArrayList(u8) = .empty;
        defer argbuf.deinit(alloc);
        try argbuf.writer(alloc).print("{{\"dir\":\"{s}\"", .{dir_str});
        if (workspace) |n| try argbuf.writer(alloc).print(",\"workspace\":{d}", .{n});
        if (tab) |n| try argbuf.writer(alloc).print(",\"tab\":{d}", .{n});
        if (command) |c| {
            try argbuf.writer(alloc).print(",\"command\":{f}", .{std.json.fmt(c, .{})});
        }
        // Non-focus is the default; only emit focus when opted in so a
        // plain `split` stays a background create.
        if (focus) try argbuf.writer(alloc).print(",\"focus\":true", .{});
        try argbuf.append(alloc, '}');

        const request = try std.fmt.allocPrint(
            alloc,
            "{{\"id\":1,\"cmd\":\"new-split\",\"args\":{s}}}\n",
            .{argbuf.items},
        );
        defer alloc.free(request);

        return agent_ipc.sendRequest(alloc, request, stdout, stderr);
    }
} else struct {};
