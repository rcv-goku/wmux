const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");

/// The hook shim scripts, embedded at build time so the installer can write
/// them at any cwd without the source tree. The .ps1 variants run on native
/// Windows; the .sh variants under WSL/Git-Bash.
const claude_ps1 = @embedFile("../shell-integration/agent-hooks/claude-code/ghostty-capture.ps1");
const claude_sh = @embedFile("../shell-integration/agent-hooks/claude-code/ghostty-capture.sh");
const codex_ps1 = @embedFile("../shell-integration/agent-hooks/codex/ghostty-capture.ps1");
const codex_sh = @embedFile("../shell-integration/agent-hooks/codex/ghostty-capture.sh");

/// Options exists so the shared CLI machinery (completions, docs,
/// `Action.options()`) has a type to reflect over. `+hooks` parses its own
/// positional subcommand and flags in `run`, so the only flag handled here
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

/// The `+hooks` command installs the per-agent `SessionStart` hooks that
/// drive `ghostty +session capture`, so a workspace can later be relaunched
/// with the agent's own resume command. This is pure local file IO — NOT an
/// IPC verb — so it works whether or not Ghostty is running.
///
/// Usage: `ghostty +hooks setup [--agent claude|codex|all] [--print] [--uninstall]`
///
///   * `setup --agent claude`: Merge a `hooks.SessionStart` block into
///     `~/.claude/settings.json` (created if absent; existing keys/hooks are
///     preserved, never clobbered), and copy the capture shim to
///     `~/.claude/ghostty-hooks/`.
///   * `setup --agent codex`: Merge a `[[hooks.SessionStart]]` block into
///     `$CODEX_HOME/config.toml` (default `~/.codex/config.toml`) and copy
///     the shim to `~/.codex/ghostty-hooks/`.
///   * `--agent all` (default): both of the above.
///   * `--print`: print the fragment(s) to stdout instead of writing, so a
///     user can merge by hand.
///   * `--uninstall`: remove the Ghostty SessionStart hook and shims.
///
/// The hook reads the agent's `SessionStart` stdin JSON (which carries
/// `session_id`) and forwards it via `ghostty +session capture`. It is
/// strictly non-fatal: any failure exits 0 so it can never block a session.
///
/// Only supported on Windows.
///
/// Available since: 1.2.0
pub fn run(alloc: Allocator) !u8 {
    if (comptime builtin.os.tag != .windows) {
        var buf: [256]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&buf);
        const stderr = &stderr_writer.interface;
        try stderr.print("+hooks is only supported on Windows.\n", .{});
        stderr.flush() catch {};
        return 1;
    }

    return windows_impl.run(alloc);
}

const Agent = enum { claude, codex, all };

const windows_impl = if (builtin.os.tag == .windows) struct {
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

    const Command = enum { setup };

    fn runImpl(
        alloc: Allocator,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !u8 {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();

        const sub_str = iter.next() orelse {
            try stderr.print("usage: ghostty +hooks setup [--agent claude|codex|all] [--print] [--uninstall]\n", .{});
            return 1;
        };
        if (std.mem.eql(u8, sub_str, "--help") or std.mem.eql(u8, sub_str, "-h")) {
            return Action.help_error;
        }
        _ = std.meta.stringToEnum(Command, sub_str) orelse {
            try stderr.print("unknown subcommand '{s}' (only 'setup')\n", .{sub_str});
            return 1;
        };

        var agent: Agent = .all;
        var print_only = false;
        var uninstall = false;
        while (iter.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--agent=")) {
                agent = parseAgent(arg["--agent=".len..]) orelse {
                    try stderr.print("invalid --agent (use claude|codex|all)\n", .{});
                    return 1;
                };
            } else if (std.mem.eql(u8, arg, "--agent")) {
                const v = iter.next() orelse {
                    try stderr.print("--agent requires a value\n", .{});
                    return 1;
                };
                agent = parseAgent(v) orelse {
                    try stderr.print("invalid --agent (use claude|codex|all)\n", .{});
                    return 1;
                };
            } else if (std.mem.eql(u8, arg, "--print")) {
                print_only = true;
            } else if (std.mem.eql(u8, arg, "--uninstall")) {
                uninstall = true;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return Action.help_error;
            } else {
                try stderr.print("unexpected argument '{s}'\n", .{arg});
                return 1;
            }
        }

        const home = std.process.getEnvVarOwned(alloc, "USERPROFILE") catch {
            try stderr.print("USERPROFILE not set; cannot locate agent dotfiles\n", .{});
            return 1;
        };
        defer alloc.free(home);

        if (agent == .claude or agent == .all)
            try setupClaude(alloc, home, print_only, uninstall, stdout, stderr);
        if (agent == .codex or agent == .all)
            try setupCodex(alloc, home, print_only, uninstall, stdout, stderr);
        return 0;
    }

    fn parseAgent(s: []const u8) ?Agent {
        if (std.mem.eql(u8, s, "claude") or std.mem.eql(u8, s, "claude_code")) return .claude;
        if (std.mem.eql(u8, s, "codex")) return .codex;
        if (std.mem.eql(u8, s, "all")) return .all;
        return null;
    }

    // -- Claude Code: ~/.claude/settings.json --------------------------------

    /// The marker string that identifies a Ghostty-installed SessionStart
    /// hook entry (its command points at our shim), used to avoid duplicate
    /// installs and to find the entry to remove on --uninstall.
    const claude_marker = "ghostty-hooks\\\\ghostty-capture.ps1";

    fn setupClaude(
        alloc: Allocator,
        home: []const u8,
        print_only: bool,
        uninstall: bool,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !void {
        const hooks_dir = try std.fmt.allocPrint(alloc, "{s}\\.claude\\ghostty-hooks", .{home});
        defer alloc.free(hooks_dir);
        const ps1_path = try std.fmt.allocPrint(alloc, "{s}\\ghostty-capture.ps1", .{hooks_dir});
        defer alloc.free(ps1_path);
        const sh_path = try std.fmt.allocPrint(alloc, "{s}\\ghostty-capture.sh", .{hooks_dir});
        defer alloc.free(sh_path);
        const settings_path = try std.fmt.allocPrint(alloc, "{s}\\.claude\\settings.json", .{home});
        defer alloc.free(settings_path);

        // The SessionStart command we install: pwsh runs our shim.
        const command = try std.fmt.allocPrint(
            alloc,
            "pwsh -NoProfile -File \"{s}\"",
            .{ps1_path},
        );
        defer alloc.free(command);

        if (print_only) {
            try stdout.print(
                \\# Merge into {s} (hooks.SessionStart):
                \\{{
                \\  "hooks": {{
                \\    "SessionStart": [
                \\      {{ "matcher": "startup|resume|compact",
                \\        "hooks": [ {{ "type": "command", "command": {f}, "timeout": 10 }} ] }}
                \\    ]
                \\  }}
                \\}}
                \\
            , .{ settings_path, std.json.fmt(command, .{}) });
            return;
        }

        // Read-modify-write the JSON, preserving every other key.
        const new_json = try mergeClaudeJson(alloc, settings_path, command, uninstall);
        defer alloc.free(new_json);

        if (uninstall) {
            try writeFileAtomic(alloc, settings_path, new_json);
            // Best-effort remove the shims.
            std.fs.deleteFileAbsolute(ps1_path) catch {};
            std.fs.deleteFileAbsolute(sh_path) catch {};
            try stdout.print("Removed Ghostty SessionStart hook from {s}\n", .{settings_path});
            return;
        }

        try ensureDir(hooks_dir);
        try writeFileAbsolute(ps1_path, claude_ps1);
        try writeFileAbsolute(sh_path, claude_sh);
        try writeFileAtomic(alloc, settings_path, new_json);
        try stdout.print("Installed Claude Code SessionStart hook:\n  {s}\n  shim: {s}\n", .{ settings_path, ps1_path });
        _ = stderr;
    }

    /// Read `settings.json` (treating a missing/empty file as `{}`), ensure
    /// `hooks.SessionStart` is an array, and append our hook entry (unless
    /// already present, matched by `command`). On `uninstall`, remove every
    /// SessionStart entry whose command equals `command`. Returns the
    /// re-serialized JSON (caller frees). Never drops unrelated keys.
    fn mergeClaudeJson(
        alloc: Allocator,
        path: []const u8,
        command: []const u8,
        uninstall: bool,
    ) ![]u8 {
        const existing = readFileAlloc(alloc, path) catch null;
        defer if (existing) |e| alloc.free(e);

        var parsed: std.json.Parsed(std.json.Value) = undefined;
        var have_parsed = false;
        defer if (have_parsed) parsed.deinit();

        var root: std.json.Value = blk: {
            const src = if (existing) |e| std.mem.trim(u8, e, &std.ascii.whitespace) else "";
            if (src.len == 0) break :blk std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
            parsed = std.json.parseFromSlice(std.json.Value, alloc, src, .{}) catch
                return error.SettingsNotJson;
            have_parsed = true;
            if (parsed.value != .object) return error.SettingsNotObject;
            break :blk parsed.value;
        };

        // We need an arena to build new Value nodes that outlive `parsed`
        // only until we serialize; build into a fresh arena and stringify.
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const aa = arena.allocator();

        // Ensure root.object.hooks is an object.
        var hooks_obj: std.json.ObjectMap = if (root.object.get("hooks")) |h|
            (if (h == .object) h.object else std.json.ObjectMap.init(aa))
        else
            std.json.ObjectMap.init(aa);

        // Ensure hooks.SessionStart is an array.
        const ss_arr: std.json.Array = if (hooks_obj.get("SessionStart")) |s|
            (if (s == .array) s.array else std.json.Array.init(aa))
        else
            std.json.Array.init(aa);

        // Build a fresh array, dropping any prior Ghostty entry (so a
        // re-install updates rather than duplicates, and uninstall removes).
        var out_arr = std.json.Array.init(aa);
        for (ss_arr.items) |item| {
            if (entryHasCommand(item, command)) continue; // drop ours
            try out_arr.append(item);
        }
        if (!uninstall) {
            try out_arr.append(try buildClaudeEntry(aa, command));
        }

        try hooks_obj.put("SessionStart", .{ .array = out_arr });
        try root.object.put("hooks", .{ .object = hooks_obj });

        // Serialize pretty so the file stays human-editable.
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        try std.json.Stringify.value(root, .{ .whitespace = .indent_2 }, &aw.writer);
        return alloc.dupe(u8, aw.written());
    }

    /// Build `{matcher, hooks:[{type:"command", command, timeout:10}]}`.
    fn buildClaudeEntry(aa: Allocator, command: []const u8) !std.json.Value {
        var inner = std.json.ObjectMap.init(aa);
        try inner.put("type", .{ .string = "command" });
        try inner.put("command", .{ .string = command });
        try inner.put("timeout", .{ .integer = 10 });
        var inner_arr = std.json.Array.init(aa);
        try inner_arr.append(.{ .object = inner });
        var entry = std.json.ObjectMap.init(aa);
        try entry.put("matcher", .{ .string = "startup|resume|compact" });
        try entry.put("hooks", .{ .array = inner_arr });
        return .{ .object = entry };
    }

    /// True when `item` is a SessionStart entry whose nested hooks contain a
    /// command equal to `command` (our marker).
    fn entryHasCommand(item: std.json.Value, command: []const u8) bool {
        const obj = switch (item) {
            .object => |o| o,
            else => return false,
        };
        const hooks = obj.get("hooks") orelse return false;
        const arr = switch (hooks) {
            .array => |a| a,
            else => return false,
        };
        for (arr.items) |h| {
            const ho = switch (h) {
                .object => |o| o,
                else => continue,
            };
            const cmd = ho.get("command") orelse continue;
            if (cmd == .string and std.mem.eql(u8, cmd.string, command)) return true;
        }
        return false;
    }

    // -- Codex: $CODEX_HOME/config.toml --------------------------------------

    fn setupCodex(
        alloc: Allocator,
        home: []const u8,
        print_only: bool,
        uninstall: bool,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !void {
        _ = stderr;
        const codex_home = std.process.getEnvVarOwned(alloc, "CODEX_HOME") catch
            try std.fmt.allocPrint(alloc, "{s}\\.codex", .{home});
        defer alloc.free(codex_home);

        const hooks_dir = try std.fmt.allocPrint(alloc, "{s}\\ghostty-hooks", .{codex_home});
        defer alloc.free(hooks_dir);
        const ps1_path = try std.fmt.allocPrint(alloc, "{s}\\ghostty-capture.ps1", .{hooks_dir});
        defer alloc.free(ps1_path);
        const sh_path = try std.fmt.allocPrint(alloc, "{s}\\ghostty-capture.sh", .{hooks_dir});
        defer alloc.free(sh_path);
        const config_path = try std.fmt.allocPrint(alloc, "{s}\\config.toml", .{codex_home});
        defer alloc.free(config_path);

        // The block we append. The command uses a TOML literal (single-quoted)
        // string so the embedded Windows backslashes need no escaping. A
        // sentinel comment pair lets uninstall find and remove it.
        const block = try std.fmt.allocPrint(
            alloc,
            "\n# >>> ghostty session-capture hook >>>\n" ++
                "[[hooks.SessionStart]]\nmatcher = \"\"\n\n" ++
                "[[hooks.SessionStart.hooks]]\ntype = \"command\"\n" ++
                "command = 'pwsh -NoProfile -File \"{s}\"'\ntimeout = 10\n" ++
                "# <<< ghostty session-capture hook <<<\n",
            .{ps1_path},
        );
        defer alloc.free(block);

        if (print_only) {
            try stdout.print("# Append to {s}:\n{s}\n", .{ config_path, block });
            return;
        }

        const existing = readFileAlloc(alloc, config_path) catch null;
        defer if (existing) |e| alloc.free(e);

        const new_toml = try mergeCodexToml(alloc, existing, block, uninstall);
        defer alloc.free(new_toml);

        if (uninstall) {
            if (existing != null) try writeFileAtomic(alloc, config_path, new_toml);
            std.fs.deleteFileAbsolute(ps1_path) catch {};
            std.fs.deleteFileAbsolute(sh_path) catch {};
            try stdout.print("Removed Ghostty SessionStart hook from {s}\n", .{config_path});
            return;
        }

        try ensureDir(codex_home);
        try ensureDir(hooks_dir);
        try writeFileAbsolute(ps1_path, codex_ps1);
        try writeFileAbsolute(sh_path, codex_sh);
        try writeFileAtomic(alloc, config_path, new_toml);
        try stdout.print("Installed Codex SessionStart hook:\n  {s}\n  shim: {s}\n", .{ config_path, ps1_path });
    }

    const codex_begin = "# >>> ghostty session-capture hook >>>";
    const codex_end = "# <<< ghostty session-capture hook <<<";

    /// Append/replace our sentinel-delimited TOML block in `existing`. The
    /// block is line-delimited by `codex_begin`/`codex_end`, so we strip any
    /// prior copy verbatim (idempotent install + clean uninstall) and append
    /// the new one. Unrelated config is preserved byte-for-byte. We do NOT
    /// parse TOML (no std TOML writer); the sentinel-block approach is the
    /// robust read-modify-write here. Caller frees.
    fn mergeCodexToml(
        alloc: Allocator,
        existing: ?[]const u8,
        block: []const u8,
        uninstall: bool,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);

        if (existing) |src| {
            // Copy everything outside a prior sentinel block.
            const begin = std.mem.indexOf(u8, src, codex_begin);
            if (begin) |b| {
                // Trim a trailing newline before the block for tidiness.
                var head_end = b;
                if (head_end > 0 and src[head_end - 1] == '\n') head_end -= 1;
                try out.appendSlice(alloc, src[0..head_end]);
                // Find the end sentinel and skip to the line after it.
                if (std.mem.indexOfPos(u8, src, b, codex_end)) |e| {
                    var rest = e + codex_end.len;
                    if (rest < src.len and src[rest] == '\r') rest += 1;
                    if (rest < src.len and src[rest] == '\n') rest += 1;
                    try out.appendSlice(alloc, src[rest..]);
                }
            } else {
                try out.appendSlice(alloc, src);
            }
        }

        if (!uninstall) {
            try out.appendSlice(alloc, block);
        }
        return out.toOwnedSlice(alloc);
    }

    // -- file helpers --------------------------------------------------------

    fn ensureDir(path: []const u8) !void {
        std.fs.makeDirAbsolute(path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            error.FileNotFound => {
                // Parent missing: create it then retry (one level is enough
                // for ~/.claude or ~/.codex whose parent — the home dir —
                // always exists).
                if (std.fs.path.dirname(path)) |parent| {
                    std.fs.makeDirAbsolute(parent) catch {};
                    try std.fs.makeDirAbsolute(path);
                } else return err;
            },
            else => return err,
        };
    }

    fn readFileAlloc(alloc: Allocator, path: []const u8) ![]u8 {
        const f = try std.fs.openFileAbsolute(path, .{});
        defer f.close();
        return f.readToEndAlloc(alloc, 4 * 1024 * 1024);
    }

    fn writeFileAbsolute(path: []const u8, bytes: []const u8) !void {
        const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(bytes);
    }

    /// Write `bytes` to `path` via a sibling temp file + rename, so a crash
    /// mid-write can't leave a half-written settings file.
    fn writeFileAtomic(alloc: Allocator, path: []const u8, bytes: []const u8) !void {
        const tmp = try std.fmt.allocPrint(alloc, "{s}.ghostty-tmp", .{path});
        defer alloc.free(tmp);
        try writeFileAbsolute(tmp, bytes);
        std.fs.renameAbsolute(tmp, path) catch |err| {
            // Some filesystems refuse rename-over; fall back to direct write.
            std.fs.deleteFileAbsolute(tmp) catch {};
            if (err == error.PathAlreadyExists or err == error.AccessDenied) {
                try writeFileAbsolute(path, bytes);
                return;
            }
            return err;
        };
    }
} else struct {};
