const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");

/// Options exists so the shared CLI machinery (completions, docs,
/// `Action.options()`) has a type to reflect over. `+workspace` parses its
/// own positional subcommand and arguments in `run`, so the only flag
/// handled here is `--help`.
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

/// The `+workspace` command drives the sidebar workspaces of a running
/// Ghostty instance over its per-process agent IPC pipe, enabling
/// scripted/agentic control alongside `+tab`, `+send`, and `+browser`.
///
/// Subcommands:
///
///   * `list`: Print a JSON array of the target window's workspaces, one
///     object per workspace: `{index, name, active, tab_count}`.
///
///   * `new [--name X] [--worktree <branch>] [--repo <path>] [--command "..."] [--focus]`:
///     Create a new workspace (a sidebar row with one tab) and print its
///     index as `{index: N}`. By DEFAULT the workspace is created in the
///     BACKGROUND: the active workspace does not change and the window is
///     not raised, so an agent orchestrator spawning workspaces never
///     yanks you out of your current app (matching cmux's "workspace
///     creation is not a focus-intent operation"). Pass `--focus` to
///     switch the active workspace to the new one. With `--command "..."`,
///     the workspace's first tab runs that command (split on whitespace
///     into an argv) instead of the default shell; used by `+ssh
///     --workspace` to open a workspace whose initial tab runs `ssh
///     user@host`. Subsequent tabs opened in the workspace inherit the
///     command from the active tab (the standard tab-inherit behavior).
///     With `--worktree <branch>` the workspace is bound to
///     a git worktree at `<repo>/.worktrees/<branch>`: Ghostty runs `git
///     worktree add` (creating the branch, or attaching it if it already
///     exists), the workspace is named after the branch (unless `--name`
///     overrides), and every tab it opens spawns inside that worktree.
///     `--repo` defaults to the current working directory of THIS client
///     (sent over IPC, since the running Ghostty's cwd is its own, not
///     the agent's). A git failure is reported and no workspace is
///     created.
///
///   * `select <index>`: Switch the target window to workspace `<index>`.
///
///   * `close <index>`: Close workspace `<index>`. Closing the last
///     remaining workspace closes the window.
///
/// The target instance's IPC pipe is `ghostty-ipc-<pid>`. The pid is taken
/// from the `GHOSTTY_PID` environment variable (exported into every shell
/// Ghostty spawns); if it is unset, `+workspace` connects to the sole
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
        try stderr.print("+workspace is only supported on Windows.\n", .{});
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

        // argsIterator skips argv0 AND the "+workspace" action selector,
        // so the first value here is the subcommand.
        const sub_str = iter.next() orelse {
            try stderr.print("usage: ghostty +workspace <list|new|select|close> [args]\n", .{});
            return 1;
        };
        if (std.mem.eql(u8, sub_str, "--help") or std.mem.eql(u8, sub_str, "-h")) {
            return Action.help_error;
        }
        const sub = std.meta.stringToEnum(Command, sub_str) orelse {
            try stderr.print("unknown subcommand '{s}'\n", .{sub_str});
            return 1;
        };

        // Collect positional and flag args after the subcommand.
        var positional: ?[]const u8 = null;
        var name: ?[]const u8 = null;
        var worktree: ?[]const u8 = null;
        var repo: ?[]const u8 = null;
        var command: ?[]const u8 = null;
        var focus = false;
        while (iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--focus")) {
                focus = true;
            } else if (std.mem.startsWith(u8, arg, "--name=")) {
                name = try alloc.dupe(u8, arg["--name=".len..]);
            } else if (std.mem.eql(u8, arg, "--name")) {
                const v = iter.next() orelse {
                    try stderr.print("--name requires a value\n", .{});
                    return 1;
                };
                name = try alloc.dupe(u8, v);
            } else if (std.mem.startsWith(u8, arg, "--worktree=")) {
                worktree = try alloc.dupe(u8, arg["--worktree=".len..]);
            } else if (std.mem.eql(u8, arg, "--worktree")) {
                const v = iter.next() orelse {
                    try stderr.print("--worktree requires a <branch>\n", .{});
                    return 1;
                };
                worktree = try alloc.dupe(u8, v);
            } else if (std.mem.startsWith(u8, arg, "--repo=")) {
                repo = try alloc.dupe(u8, arg["--repo=".len..]);
            } else if (std.mem.eql(u8, arg, "--repo")) {
                const v = iter.next() orelse {
                    try stderr.print("--repo requires a <path>\n", .{});
                    return 1;
                };
                repo = try alloc.dupe(u8, v);
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

        // --repo/--worktree/--focus/--command are only meaningful to `new`.
        if (sub != .new and (worktree != null or repo != null or focus or command != null)) {
            try stderr.print("--worktree/--repo/--focus/--command are only valid for 'new'\n", .{});
            return 1;
        }

        const request = switch (sub) {
            .list => try alloc.dupe(u8, "{\"id\":1,\"cmd\":\"workspace-list\"}\n"),
            .new => try buildNewRequest(alloc, name, worktree, repo, command, focus, stderr) orelse return 1,
            .select => req: {
                const idx = try parseIndex(positional, stderr) orelse return 1;
                break :req try std.fmt.allocPrint(
                    alloc,
                    "{{\"id\":1,\"cmd\":\"workspace-select\",\"args\":{{\"index\":{d}}}}}\n",
                    .{idx},
                );
            },
            .close => req: {
                const idx = try parseIndex(positional, stderr) orelse return 1;
                break :req try std.fmt.allocPrint(
                    alloc,
                    "{{\"id\":1,\"cmd\":\"workspace-close\",\"args\":{{\"index\":{d}}}}}\n",
                    .{idx},
                );
            },
        };
        defer alloc.free(request);

        return agent_ipc.sendRequest(alloc, request, stdout, stderr);
    }

    /// Build the `workspace-new` request line, JSON-escaping every
    /// value. When a worktree branch is given, the request also carries
    /// the repo to resolve against: the explicit `--repo`, or — so the
    /// agent's working directory (NOT the running Ghostty's) is used — the
    /// client's own cwd, sent as a "cwd" arg. Returns null (after printing
    /// an error) only on a recoverable failure the caller maps to exit 1.
    fn buildNewRequest(
        alloc: Allocator,
        name: ?[]const u8,
        worktree: ?[]const u8,
        repo: ?[]const u8,
        command: ?[]const u8,
        focus: bool,
        stderr: *std.Io.Writer,
    ) !?[]u8 {
        var args_buf: std.ArrayList(u8) = .empty;
        defer args_buf.deinit(alloc);
        const w = args_buf.writer(alloc);

        var first = true;
        const sep = struct {
            fn f(wr: anytype, is_first: *bool) !void {
                if (!is_first.*) try wr.writeByte(',');
                is_first.* = false;
            }
        }.f;

        if (name) |n| {
            try sep(w, &first);
            try w.print("\"name\":{f}", .{std.json.fmt(n, .{})});
        }
        if (worktree) |branch| {
            try sep(w, &first);
            try w.print("\"worktree\":{f}", .{std.json.fmt(branch, .{})});

            // Resolve the repo for the server: --repo wins, else this
            // client's cwd. We always send "cwd" so the server can fall
            // back to it; --repo, when present, takes precedence there.
            const cwd = std.process.getCwdAlloc(alloc) catch |err| {
                try stderr.print("could not read current directory: {s}\n", .{@errorName(err)});
                return null;
            };
            defer alloc.free(cwd);
            try sep(w, &first);
            try w.print("\"cwd\":{f}", .{std.json.fmt(cwd, .{})});

            if (repo) |r| {
                try sep(w, &first);
                try w.print("\"repo\":{f}", .{std.json.fmt(r, .{})});
            }
        }

        if (command) |c| {
            try sep(w, &first);
            try w.print("\"command\":{f}", .{std.json.fmt(c, .{})});
        }

        // Non-focus is the default; only emit focus when opted in so a
        // plain `workspace new` stays a background create.
        if (focus) {
            try sep(w, &first);
            try w.print("\"focus\":true", .{});
        }

        if (first) {
            // No args at all.
            return try alloc.dupe(u8, "{\"id\":1,\"cmd\":\"workspace-new\"}\n");
        }
        return try std.fmt.allocPrint(
            alloc,
            "{{\"id\":1,\"cmd\":\"workspace-new\",\"args\":{{{s}}}}}\n",
            .{args_buf.items},
        );
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
