//! The two-binary relay (ADR-4.3 step 2, ADR-4.10, ADR-4.11, AF-11). Owner: W1-2b.
//!
//! This file is imported by both executables, so it depends on std only:
//!
//! - `wmux.exe` (src/main_ghostty.zig) calls `gui.relayIfCliArgv` before
//!   anything else. `routeGui` keeps Ghostty-native `+actions` in-process,
//!   relays a cmux command, a global CLI option or a legacy wmux `+verb` to
//!   `<exe dir>\cli\cmux.exe` (inherited handles, the parent console attached
//!   when the std handles are missing, exit code propagated) and leaves every
//!   other argv to the app.
//! - `cmux.exe` (main.zig) relays Ghostty-native `+actions` back to
//!   `..\wmux.exe` and serves the legacy `+verbs` through `runLegacy`: the
//!   argv is parsed exactly as the old `src/cli` verbs parsed it, the legacy
//!   JSON command goes over the legacy pipe `\\.\pipe\wmux-ipc-<pid>` and the
//!   reply is printed byte for byte as before (AF-11). Without any legacy
//!   pipe (no wmux instance, or after M3 removes the pipe) the caller falls
//!   back to the cmux mapping of ADR-4.11 (commands/legacy_plus.zig).
//!
//! `+verb --help` (FOLLOWUPS 2026-10-17, decided here): the legacy text is
//! kept. The removed verbs print `error: ActionHelpRequested` and exit 1,
//! exactly as the old wmux.exe did (pinned by the plus-verbs goldens),
//! whether or not an instance runs; Ghostty-native `+actions` (`+ssh`,
//! `+list-themes`, ...) keep their in-process help. The cmux help of the new
//! commands is `cmux <command> --help`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// The `+actions` wmux.exe still runs in-process: Ghostty's CLI actions plus
/// `+hooks` (until W3-3a) and `+ssh` (until W6-1a). Must equal the fields of
/// `cli.ghostty.Action` (checked by a test in src/cli/ghostty.zig).
pub const ghostty_actions = [_][]const u8{
    "version",         "help",        "list-fonts",   "list-keybinds",
    "list-themes",     "list-colors", "list-actions", "ssh",
    "ssh-cache",       "edit-config", "show-config",  "explain-config",
    "validate-config", "show-face",   "crash-report", "boo",
    "hooks",
};

/// The legacy wmux `+verbs` whose `src/cli` clients W1-2b removed; both
/// binaries serve them through `runLegacy` in cmux.exe.
pub const legacy_verbs = [_][]const u8{
    "workspace", "tab",     "send",       "notify",                "surface",
    "split",     "status",  "log",        "read-screen",           "capture-pane",
    "session",   "browser", "new-window", "toggle-quick-terminal",
};

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

pub fn isGhosttyAction(name: []const u8) bool {
    return inList(&ghostty_actions, name);
}

pub fn isLegacyVerb(name: []const u8) bool {
    return inList(&legacy_verbs, name);
}

// ===========================================================================
// wmux.exe argv routing (ADR-4.10)
// ===========================================================================

/// What Ghostty's action detection (`cli/action.zig` `detectIter`) finds in
/// an argv, with the legacy verbs counted as actions.
pub const Detected = union(enum) {
    /// No action: the app starts (`-e` before any action included).
    none,
    /// `--help`/`-h` without an action (Ghostty's `+help` fallback).
    help,
    /// `--version` anywhere (it wins over every action).
    version,
    /// A second `+action` (Ghostty prints its MultipleActions error).
    multiple,
    /// An unknown `+action` (Ghostty prints its InvalidAction error).
    invalid,
    /// The name of the `+action`, without the `+`.
    action: []const u8,
};

/// Mirrors `detectIter` over `args` (argv without argv[0]).
pub fn detectAction(args: []const []const u8) Detected {
    var pending: ?[]const u8 = null;
    var fallback = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "-e")) {
            if (pending == null) return .none;
        }
        if (std.mem.eql(u8, a, "--version")) return .version;
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) fallback = true;
        if (a.len == 0 or a[0] != '+') continue;
        if (pending != null) return .multiple;
        const name = a[1..];
        if (!isGhosttyAction(name) and !isLegacyVerb(name)) return .invalid;
        pending = name;
    }
    if (pending) |p| return .{ .action = p };
    if (fallback) return .help;
    return .none;
}

/// A cmux command word: lowercase ASCII letters, digits and `-`, starting
/// with a letter (`list-workspaces`, `wmux`, `help`). The app itself takes
/// no positional first argument, so such a word is always CLI-shaped; paths
/// (`C:\x`, `.\x`, `x.txt`) never match.
pub fn isCliWord(a: []const u8) bool {
    if (a.len == 0 or !std.ascii.isLower(a[0])) return false;
    for (a) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    }
    return true;
}

/// The cmux global options (ADR-4.4); none of them is a Ghostty option.
const global_options = [_][]const u8{ "--socket", "--password", "--window", "--json", "--id-format" };

pub fn isGlobalCliOption(a: []const u8) bool {
    for (global_options) |o| {
        if (std.mem.eql(u8, a, o)) return true;
        if (a.len > o.len and std.mem.startsWith(u8, a, o) and a[o.len] == '=') return true;
    }
    return false;
}

pub const GuiRoute = enum {
    /// Start (or forward to) the app.
    app,
    /// A Ghostty CLI action (or its error) runs inside wmux.exe.
    in_process,
    /// Run `<exe dir>\cli\cmux.exe` with the same arguments.
    relay,
};

/// ADR-4.10 for `args` (argv without argv[0]).
pub fn routeGui(args: []const []const u8) GuiRoute {
    if (args.len > 0 and (isCliWord(args[0]) or isGlobalCliOption(args[0]))) return .relay;
    return switch (detectAction(args)) {
        .none => .app,
        .help, .version, .multiple, .invalid => .in_process,
        .action => |name| if (isLegacyVerb(name)) .relay else .in_process,
    };
}

/// The process side of the wmux.exe relay (Windows only).
pub const gui = struct {
    const w = std.os.windows;

    extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?w.HWND;
    extern "kernel32" fn AttachConsole(dwProcessId: w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn SetStdHandle(nStdHandle: w.DWORD, hHandle: w.HANDLE) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetFileType(hFile: w.HANDLE) callconv(.winapi) w.DWORD;

    const ATTACH_PARENT_PROCESS: w.DWORD = 0xFFFFFFFF;
    const FILE_TYPE_CHAR: w.DWORD = 0x0002;

    /// Relays a CLI-shaped argv to `cli\cmux.exe` and returns its exit code;
    /// null when the argv belongs to the app or to an in-process action.
    pub fn relayIfCliArgv() ?u8 {
        if (builtin.os.tag != .windows) return null;
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const argv_z = std.process.argsAlloc(arena) catch return null;
        if (argv_z.len < 2) return null;
        const args = arena.alloc([]const u8, argv_z.len - 1) catch return null;
        for (argv_z[1..], 0..) |a, i| args[i] = a;
        if (routeGui(args) != .relay) return null;
        return run(arena, args);
    }

    fn stdHandle(which: w.DWORD) ?w.HANDLE {
        const h = w.kernel32.GetStdHandle(which) orelse return null;
        if (h == w.INVALID_HANDLE_VALUE) return null;
        return h;
    }

    /// True when the relayed CLI can share a console: wmux.exe has one (a
    /// console-subsystem debug build), or a std handle is missing or a
    /// console and the parent's console could be attached (a GUI-subsystem
    /// wmux.exe started from cmd or pwsh). Fully redirected handles (pipes,
    /// files) never attach. Missing std handles are pointed at the attached
    /// console so the child inherits them.
    fn prepareConsole() bool {
        if (GetConsoleWindow() != null) return true;
        const ids = [_]w.DWORD{ w.STD_INPUT_HANDLE, w.STD_OUTPUT_HANDLE, w.STD_ERROR_HANDLE };
        var need = false;
        for (ids) |id| {
            const h = stdHandle(id) orelse {
                need = true;
                continue;
            };
            if (GetFileType(h) == FILE_TYPE_CHAR) need = true;
        }
        if (!need) return false;
        if (AttachConsole(ATTACH_PARENT_PROCESS) == 0) return false;
        for (ids) |id| {
            if (stdHandle(id) != null) continue;
            const input = id == w.STD_INPUT_HANDLE;
            const name = if (input) std.unicode.utf8ToUtf16LeStringLiteral("CONIN$") else std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$");
            var sa: w.SECURITY_ATTRIBUTES = .{
                .nLength = @sizeOf(w.SECURITY_ATTRIBUTES),
                .lpSecurityDescriptor = null,
                .bInheritHandle = w.TRUE,
            };
            const h = w.kernel32.CreateFileW(
                name,
                w.GENERIC_READ | w.GENERIC_WRITE,
                w.FILE_SHARE_READ | w.FILE_SHARE_WRITE,
                &sa,
                w.OPEN_EXISTING,
                0,
                null,
            );
            if (h != w.INVALID_HANDLE_VALUE) _ = SetStdHandle(id, h);
        }
        return true;
    }

    fn fail(comptime fmt: []const u8, a: anytype) u8 {
        var buf: [512]u8 = undefined;
        var fw = std.fs.File.stderr().writer(&buf);
        fw.interface.print("wmux: " ++ fmt ++ "\n", a) catch {};
        fw.interface.flush() catch {};
        return 1;
    }

    fn run(arena: Allocator, args: []const []const u8) u8 {
        const has_console = prepareConsole();
        const dir = std.fs.selfExeDirPathAlloc(arena) catch return fail("cannot relay '{s}': the path of wmux.exe is unknown", .{args[0]});
        const cli = std.fs.path.join(arena, &.{ dir, "cli", "cmux.exe" }) catch return 1;
        std.fs.accessAbsolute(cli, .{}) catch return fail("cannot relay '{s}': {s} not found", .{ args[0], cli });
        var env = std.process.getEnvMap(arena) catch return fail("cannot relay '{s}': cannot read the environment", .{args[0]});
        // The CLI brands its messages after the invoked name (ADR-4.1).
        env.put("WMUX_ARGV0", "wmux") catch return 1;
        const argv = std.mem.concat(arena, []const u8, &.{ &.{cli}, args }) catch return 1;
        var child = std.process.Child.init(argv, arena);
        child.env_map = &env;
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        // Without a console the CLI must not open one (G4: no window, no focus).
        child.create_no_window = !has_console;
        const term = child.spawnAndWait() catch |err| return fail("cannot run {s}: {s}", .{ cli, @errorName(err) });
        return switch (term) {
            .Exited => |code| code,
            else => 1,
        };
    }
};

// ===========================================================================
// cmux.exe: legacy +verbs over the legacy pipe (AF-11)
// ===========================================================================

/// The server's line limit (rpc/compat/legacy_json.zig `max_line_bytes`).
pub const max_line_bytes: usize = 1024 * 1024;

/// What the old verb did with its argv before any I/O.
pub const Parsed = union(enum) {
    /// `--help`/`-h`: the old CLI printed `error: ActionHelpRequested`.
    help,
    /// A usage error line (stderr, exit 1).
    usage: []const u8,
    /// One request line (newline included) for the legacy pipe.
    request: []const u8,
    /// `+browser list`: print the resolved pipe path.
    browser_list,
    /// `+new-window`: not supported by the Win32 runtime.
    new_window,
    /// `+toggle-quick-terminal`: not supported, and its message was never
    /// flushed, so it exits 1 silently.
    toggle_quick_terminal,
};

const Args = struct {
    items: []const []const u8,
    i: usize = 0,

    fn next(self: *Args) ?[]const u8 {
        if (self.i >= self.items.len) return null;
        defer self.i += 1;
        return self.items[self.i];
    }
};

fn isHelp(a: []const u8) bool {
    return std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h");
}

fn usageMsg(arena: Allocator, comptime fmt: []const u8, a: anytype) Allocator.Error!Parsed {
    return .{ .usage = try std.fmt.allocPrint(arena, fmt, a) };
}

const Flag = union(enum) { no, ok, fail: []const u8 };

/// `--name=V` or `--name V` as an integer (`base` as in std.fmt.parseInt).
fn intFlag(comptime T: type, arena: Allocator, it: *Args, arg: []const u8, comptime name: []const u8, base: u8, out: *?T) Allocator.Error!Flag {
    const raw = if (std.mem.startsWith(u8, arg, name ++ "="))
        arg[(name ++ "=").len..]
    else if (std.mem.eql(u8, arg, name))
        it.next() orelse return .{ .fail = try std.fmt.allocPrint(arena, "{s} requires a value", .{name}) }
    else
        return .no;
    out.* = std.fmt.parseInt(T, raw, base) catch return .{ .fail = try std.fmt.allocPrint(arena, "invalid {s} value", .{name}) };
    return .ok;
}

fn u32Flag(arena: Allocator, it: *Args, arg: []const u8, comptime name: []const u8, out: *?u32) Allocator.Error!Flag {
    return intFlag(u32, arena, it, arg, name, 10, out);
}

/// `--name=V` or `--name V` as a string; `missing` is the error when the
/// value is absent.
fn strFlag(it: *Args, arg: []const u8, comptime name: []const u8, missing: []const u8, out: *?[]const u8) Flag {
    if (std.mem.startsWith(u8, arg, name ++ "=")) {
        out.* = arg[(name ++ "=").len..];
        return .ok;
    }
    if (std.mem.eql(u8, arg, name)) {
        out.* = it.next() orelse return .{ .fail = missing };
        return .ok;
    }
    return .no;
}

/// Comma-joined JSON members of a request's `args` object.
const Members = struct {
    buf: std.ArrayList(u8) = .empty,
    arena: Allocator,

    fn add(self: *Members, comptime fmt: []const u8, a: anytype) Allocator.Error!void {
        if (self.buf.items.len > 0) try self.buf.append(self.arena, ',');
        try self.buf.print(self.arena, fmt, a);
    }

    fn object(self: *Members) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.arena, "{{{s}}}", .{self.buf.items});
    }
};

fn request(arena: Allocator, cmd: []const u8, args_json: ?[]const u8) Allocator.Error!Parsed {
    if (args_json) |a| return .{ .request = try std.fmt.allocPrint(arena, "{{\"id\":1,\"cmd\":\"{s}\",\"args\":{s}}}\n", .{ cmd, a }) };
    return .{ .request = try std.fmt.allocPrint(arena, "{{\"id\":1,\"cmd\":\"{s}\"}}\n", .{cmd}) };
}

fn parseIndex(arena: Allocator, positional: ?[]const u8) Allocator.Error!union(enum) { ok: u32, fail: Parsed } {
    const s = positional orelse return .{ .fail = try usageMsg(arena, "this subcommand requires an <index>", .{}) };
    const v = std.fmt.parseInt(u32, s, 10) catch return .{ .fail = try usageMsg(arena, "invalid <index> (must be a non-negative integer)", .{}) };
    return .{ .ok = v };
}

/// Parses `args` (the arguments after the `+verb`, `+`-prefixed tokens
/// already removed, as Ghostty's ArgsIterator did) the way the old verb did.
/// `cwd` is the client's working directory (`+workspace new --worktree`).
pub fn parseLegacy(arena: Allocator, verb: []const u8, args: []const []const u8, cwd: ?[]const u8) Allocator.Error!Parsed {
    var it: Args = .{ .items = args };
    const V = enum { workspace, tab, send, notify, surface, split, status, log, @"read-screen", @"capture-pane", session, browser, @"new-window", @"toggle-quick-terminal" };
    const v = std.meta.stringToEnum(V, verb) orelse return usageMsg(arena, "unknown legacy action '+{s}'", .{verb});
    return switch (v) {
        .workspace => parseWorkspace(arena, &it, cwd),
        .tab => parseTab(arena, &it),
        .send => parseSend(arena, &it),
        .notify => parseNotify(arena, &it),
        .surface => parseSurface(arena, &it),
        .split => parseSplit(arena, &it),
        .status => parseStatus(arena, &it),
        .log => parseLog(arena, &it),
        .@"read-screen" => parseReadScreen(arena, &it),
        .@"capture-pane" => parseCapturePane(arena, &it),
        .session => parseSession(arena, &it),
        .browser => parseBrowser(arena, &it),
        .@"new-window" => .new_window,
        .@"toggle-quick-terminal" => .toggle_quick_terminal,
    };
}

fn parseWorkspace(arena: Allocator, it: *Args, cwd: ?[]const u8) Allocator.Error!Parsed {
    const sub_str = it.next() orelse return usageMsg(arena, "usage: ghostty +workspace <list|new|select|close> [args]", .{});
    if (isHelp(sub_str)) return .help;
    const Sub = enum { list, new, select, close };
    const sub = std.meta.stringToEnum(Sub, sub_str) orelse return usageMsg(arena, "unknown subcommand '{s}'", .{sub_str});

    var positional: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var worktree: ?[]const u8 = null;
    var repo: ?[]const u8 = null;
    var command: ?[]const u8 = null;
    var focus = false;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--focus")) {
            focus = true;
            continue;
        }
        const flags = .{
            .{ "--name", "--name requires a value", &name },
            .{ "--worktree", "--worktree requires a <branch>", &worktree },
            .{ "--repo", "--repo requires a <path>", &repo },
            .{ "--command", "--command requires a value", &command },
        };
        var matched = false;
        inline for (flags) |f| {
            if (!matched) switch (strFlag(it, arg, f[0], f[1], f[2])) {
                .no => {},
                .ok => matched = true,
                .fail => |m| return .{ .usage = m },
            };
        }
        if (matched) continue;
        if (isHelp(arg)) return .help;
        if (std.mem.startsWith(u8, arg, "--")) return usageMsg(arena, "unknown flag '{s}'", .{arg});
        if (positional == null) {
            positional = arg;
        } else return usageMsg(arena, "unexpected argument '{s}'", .{arg});
    }

    if (sub != .new and (worktree != null or repo != null or focus or command != null)) {
        return usageMsg(arena, "--worktree/--repo/--focus/--command are only valid for 'new'", .{});
    }

    switch (sub) {
        .list => return request(arena, "workspace-list", null),
        .new => {
            var m: Members = .{ .arena = arena };
            if (name) |n| try m.add("\"name\":{f}", .{std.json.fmt(n, .{})});
            if (worktree) |branch| {
                try m.add("\"worktree\":{f}", .{std.json.fmt(branch, .{})});
                const dir = cwd orelse return usageMsg(arena, "could not read current directory: {s}", .{"Unexpected"});
                try m.add("\"cwd\":{f}", .{std.json.fmt(dir, .{})});
                if (repo) |r| try m.add("\"repo\":{f}", .{std.json.fmt(r, .{})});
            }
            if (command) |c| try m.add("\"command\":{f}", .{std.json.fmt(c, .{})});
            if (focus) try m.add("\"focus\":true", .{});
            if (m.buf.items.len == 0) return request(arena, "workspace-new", null);
            return request(arena, "workspace-new", try m.object());
        },
        .select, .close => {
            const idx = switch (try parseIndex(arena, positional)) {
                .ok => |x| x,
                .fail => |p| return p,
            };
            return request(arena, if (sub == .select) "workspace-select" else "workspace-close", try std.fmt.allocPrint(arena, "{{\"index\":{d}}}", .{idx}));
        },
    }
}

fn parseTab(arena: Allocator, it: *Args) Allocator.Error!Parsed {
    const sub_str = it.next() orelse return usageMsg(arena, "usage: wmux +tab <list|new|select|close> [args]", .{});
    if (isHelp(sub_str)) return .help;
    const Sub = enum { list, new, select, close };
    const sub = std.meta.stringToEnum(Sub, sub_str) orelse return usageMsg(arena, "unknown subcommand '{s}'", .{sub_str});

    var positional: ?[]const u8 = null;
    var workspace: ?u32 = null;
    var pane: ?u32 = null;
    var command: ?[]const u8 = null;
    var focus = false;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--focus")) {
            focus = true;
            continue;
        }
        switch (try u32Flag(arena, it, arg, "--pane", &pane)) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        switch (try u32Flag(arena, it, arg, "--workspace", &workspace)) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        switch (strFlag(it, arg, "--command", "--command requires a value", &command)) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        if (isHelp(arg)) return .help;
        if (std.mem.startsWith(u8, arg, "--")) return usageMsg(arena, "unknown flag '{s}'", .{arg});
        if (positional == null) {
            positional = arg;
        } else return usageMsg(arena, "unexpected argument '{s}'", .{arg});
    }

    var m: Members = .{ .arena = arena };
    if (sub == .select or sub == .close) {
        const idx = switch (try parseIndex(arena, positional)) {
            .ok => |x| x,
            .fail => |p| return p,
        };
        try m.add("\"index\":{d}", .{idx});
    }
    if (workspace) |n| try m.add("\"workspace\":{d}", .{n});
    if (pane) |n| try m.add("\"pane\":{d}", .{n});
    if (sub == .new) {
        if (command) |c| try m.add("\"command\":{f}", .{std.json.fmt(c, .{})});
        if (focus) try m.add("\"focus\":true", .{});
    } else if (focus) {
        return usageMsg(arena, "--focus is only valid for 'new'", .{});
    }
    const cmd = switch (sub) {
        .list => "tab-list",
        .new => "tab-new",
        .select => "tab-select",
        .close => "tab-close",
    };
    return request(arena, cmd, try m.object());
}

/// `--workspace`, `--tab` and `--pane` (u32), shared by several verbs.
const Target = struct {
    workspace: ?u32 = null,
    tab: ?u32 = null,
    pane: ?u32 = null,

    fn parse(self: *Target, arena: Allocator, it: *Args, arg: []const u8, comptime order: []const []const u8) Allocator.Error!Flag {
        inline for (order) |name| {
            const field = if (comptime std.mem.eql(u8, name, "--workspace")) &self.workspace else if (comptime std.mem.eql(u8, name, "--tab")) &self.tab else &self.pane;
            switch (try u32Flag(arena, it, arg, name, field)) {
                .no => {},
                else => |r| return r,
            }
        }
        return .no;
    }

    fn members(self: Target, m: *Members) Allocator.Error!void {
        if (self.workspace) |n| try m.add("\"workspace\":{d}", .{n});
        if (self.tab) |n| try m.add("\"tab\":{d}", .{n});
        if (self.pane) |n| try m.add("\"pane\":{d}", .{n});
    }
};

const pane_ws_tab = &[_][]const u8{ "--pane", "--workspace", "--tab" };

fn parseSend(arena: Allocator, it: *Args) Allocator.Error!Parsed {
    var text: ?[]const u8 = null;
    var t: Target = .{};
    var enter = false;
    while (it.next()) |arg| {
        switch (try t.parse(arena, it, arg, pane_ws_tab)) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        if (std.mem.eql(u8, arg, "--enter")) {
            enter = true;
            continue;
        }
        if (isHelp(arg)) return .help;
        if (std.mem.startsWith(u8, arg, "--")) return usageMsg(arena, "unknown flag '{s}'", .{arg});
        if (text == null) {
            text = arg;
        } else return usageMsg(arena, "unexpected argument '{s}'", .{arg});
    }
    const send_text = text orelse return usageMsg(arena, "send requires a <text> argument", .{});
    var m: Members = .{ .arena = arena };
    try m.add("\"text\":{f}", .{std.json.fmt(send_text, .{})});
    try t.members(&m);
    if (enter) try m.add("\"enter\":true", .{});
    return request(arena, "send", try m.object());
}

fn parseNotify(arena: Allocator, it: *Args) Allocator.Error!Parsed {
    // The first token is a subcommand or (ignored) text, which means `ring`.
    const first = it.next() orelse return usageMsg(arena, "usage: ghostty +notify [ring|clear|next|toggle-read|mark-oldest-next] [<text>] [--workspace I] [--tab J] [--pane P]", .{});
    if (isHelp(first)) return .help;
    const Sub = enum { ring, clear, next, @"toggle-read", @"mark-oldest-next" };
    const sub = std.meta.stringToEnum(Sub, first) orelse .ring;
    var t: Target = .{};
    while (it.next()) |arg| {
        switch (try t.parse(arena, it, arg, pane_ws_tab)) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        if (isHelp(arg)) return .help;
        if (std.mem.startsWith(u8, arg, "--")) return usageMsg(arena, "unknown flag '{s}'", .{arg});
        // Positional text is accepted and ignored.
    }
    var m: Members = .{ .arena = arena };
    try m.add("\"action\":\"{s}\"", .{@tagName(sub)});
    try t.members(&m);
    return request(arena, "notify", try m.object());
}

fn parseSurface(arena: Allocator, it: *Args) Allocator.Error!Parsed {
    const sub_str = it.next() orelse return usageMsg(arena, "usage: wmux +surface <list|focus> [...]", .{});
    if (isHelp(sub_str)) return .help;
    const Sub = enum { list, focus };
    const sub = std.meta.stringToEnum(Sub, sub_str) orelse return usageMsg(arena, "unknown subcommand '{s}'", .{sub_str});
    var t: Target = .{};
    var surface: ?u64 = null;
    while (it.next()) |arg| {
        switch (try t.parse(arena, it, arg, &.{ "--workspace", "--tab", "--pane" })) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        if (isHelp(arg)) return .help;
        if (std.mem.startsWith(u8, arg, "--")) return usageMsg(arena, "unknown flag '{s}'", .{arg});
        if (sub == .focus and surface == null) {
            // Base 0: the hex GHOSTTY_SURFACE_ID and the decimal list ids.
            surface = std.fmt.parseInt(u64, arg, 0) catch return usageMsg(arena, "invalid surface id '{s}'", .{arg});
        } else return usageMsg(arena, "unexpected argument '{s}'", .{arg});
    }
    var m: Members = .{ .arena = arena };
    switch (sub) {
        .list => {
            if (t.workspace) |n| try m.add("\"workspace\":{d}", .{n});
            if (t.tab) |n| try m.add("\"tab\":{d}", .{n});
            return request(arena, "surface-list", try m.object());
        },
        .focus => {
            if (surface) |sid| {
                try m.add("\"surface\":{d}", .{sid});
            } else {
                const p = t.pane orelse return usageMsg(arena, "focus needs a surface <id>, or --workspace/--tab/--pane", .{});
                if (t.workspace) |n| try m.add("\"workspace\":{d}", .{n});
                if (t.tab) |n| try m.add("\"tab\":{d}", .{n});
                try m.add("\"pane\":{d}", .{p});
            }
            return request(arena, "surface-focus", try m.object());
        },
    }
}

fn parseSplit(arena: Allocator, it: *Args) Allocator.Error!Parsed {
    const dir = it.next() orelse return usageMsg(arena, "usage: wmux +split <right|down|left|up> [--workspace I] [--pane P] [--command \"...\"]", .{});
    if (isHelp(dir)) return .help;
    const dirs = [_][]const u8{ "right", "down", "left", "up" };
    if (!inList(&dirs, dir)) return usageMsg(arena, "direction must be 'right', 'down', 'left', or 'up', got '{s}'", .{dir});
    var workspace: ?u32 = null;
    var pane: ?u32 = null;
    var command: ?[]const u8 = null;
    var focus = false;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--focus")) {
            focus = true;
            continue;
        }
        switch (try u32Flag(arena, it, arg, "--workspace", &workspace)) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        switch (try u32Flag(arena, it, arg, "--pane", &pane)) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        switch (strFlag(it, arg, "--command", "--command requires a value", &command)) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        if (isHelp(arg)) return .help;
        return usageMsg(arena, "unexpected argument '{s}'", .{arg});
    }
    var m: Members = .{ .arena = arena };
    try m.add("\"dir\":\"{s}\"", .{dir});
    if (workspace) |n| try m.add("\"workspace\":{d}", .{n});
    if (pane) |n| try m.add("\"pane\":{d}", .{n});
    if (command) |c| try m.add("\"command\":{f}", .{std.json.fmt(c, .{})});
    if (focus) try m.add("\"focus\":true", .{});
    return request(arena, "new-split", try m.object());
}

fn parseStatus(arena: Allocator, it: *Args) Allocator.Error!Parsed {
    const sub_str = it.next() orelse return usageMsg(arena, "usage: ghostty +status <set <text>|progress <0-100|clear>> [--workspace I] [--tab J] [--pane P]", .{});
    if (isHelp(sub_str)) return .help;
    const Sub = enum { set, progress };
    const sub = std.meta.stringToEnum(Sub, sub_str) orelse return usageMsg(arena, "unknown subcommand '{s}'", .{sub_str});
    var value: ?[]const u8 = null;
    var t: Target = .{};
    while (it.next()) |arg| {
        switch (try t.parse(arena, it, arg, pane_ws_tab)) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        if (isHelp(arg)) return .help;
        if (std.mem.startsWith(u8, arg, "--")) return usageMsg(arena, "unknown flag '{s}'", .{arg});
        if (value == null) {
            value = arg;
        } else return usageMsg(arena, "unexpected argument '{s}'", .{arg});
    }
    var m: Members = .{ .arena = arena };
    switch (sub) {
        .set => {
            try m.add("\"text\":{f}", .{std.json.fmt(value orelse "", .{})});
            try t.members(&m);
            return request(arena, "set-status", try m.object());
        },
        .progress => {
            const v = value orelse return usageMsg(arena, "progress requires a value (0-100 or 'clear')", .{});
            const num: i64 = if (std.mem.eql(u8, v, "clear"))
                -1
            else
                std.fmt.parseInt(i64, v, 10) catch return usageMsg(arena, "invalid progress value '{s}' (use 0-100 or 'clear')", .{v});
            if (num > 100) return usageMsg(arena, "progress must be 0-100 or 'clear'", .{});
            try m.add("\"value\":{d}", .{num});
            try t.members(&m);
            return request(arena, "set-progress", try m.object());
        },
    }
}

fn parseLog(arena: Allocator, it: *Args) Allocator.Error!Parsed {
    var text: ?[]const u8 = null;
    var t: Target = .{};
    while (it.next()) |arg| {
        switch (try t.parse(arena, it, arg, pane_ws_tab)) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        if (isHelp(arg)) return .help;
        if (std.mem.startsWith(u8, arg, "--")) return usageMsg(arena, "unknown flag '{s}'", .{arg});
        if (text == null) {
            text = arg;
        } else return usageMsg(arena, "unexpected argument '{s}'", .{arg});
    }
    const line = text orelse return usageMsg(arena, "usage: ghostty +log <text> [--workspace I] [--tab J] [--pane P]", .{});
    var m: Members = .{ .arena = arena };
    try m.add("\"text\":{f}", .{std.json.fmt(line, .{})});
    try t.members(&m);
    return request(arena, "log", try m.object());
}

fn parseReadScreen(arena: Allocator, it: *Args) Allocator.Error!Parsed {
    var t: Target = .{};
    var lines: ?u32 = null;
    var scrollback = false;
    while (it.next()) |arg| {
        switch (try t.parse(arena, it, arg, pane_ws_tab)) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        switch (try u32Flag(arena, it, arg, "--lines", &lines)) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        if (std.mem.eql(u8, arg, "--scrollback")) {
            scrollback = true;
            continue;
        }
        if (isHelp(arg)) return .help;
        return usageMsg(arena, "unexpected argument '{s}'", .{arg});
    }
    var m: Members = .{ .arena = arena };
    try t.members(&m);
    if (lines) |n| try m.add("\"lines\":{d}", .{n});
    if (scrollback) try m.add("\"scrollback\":true", .{});
    return request(arena, "read-screen", try m.object());
}

fn parseCapturePane(arena: Allocator, it: *Args) Allocator.Error!Parsed {
    var t: Target = .{};
    var scrollback = false;
    var file: ?[]const u8 = null;
    while (it.next()) |arg| {
        switch (try t.parse(arena, it, arg, pane_ws_tab)) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        if (std.mem.eql(u8, arg, "--scrollback")) {
            scrollback = true;
            continue;
        }
        switch (strFlag(it, arg, "--file", "--file requires a value", &file)) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        if (isHelp(arg)) return .help;
        return usageMsg(arena, "unexpected argument '{s}'", .{arg});
    }
    var m: Members = .{ .arena = arena };
    try t.members(&m);
    if (scrollback) try m.add("\"scrollback\":true", .{});
    if (file) |f| try m.add("\"file\":{f}", .{std.json.fmt(f, .{})});
    return request(arena, "capture-pane", try m.object());
}

fn parseSession(arena: Allocator, it: *Args) Allocator.Error!Parsed {
    const sub_str = it.next() orelse return usageMsg(arena, "usage: ghostty +session <capture|resume|show|save|restore> [...]", .{});
    if (isHelp(sub_str)) return .help;
    const Sub = enum { capture, @"resume", show, save, restore };
    const sub = std.meta.stringToEnum(Sub, sub_str) orelse return usageMsg(arena, "unknown subcommand '{s}'", .{sub_str});
    var kind: ?[]const u8 = null;
    var id: ?[]const u8 = null;
    var surface: ?u64 = null;
    var workspace: ?u32 = null;
    var tab: ?u32 = null;
    while (it.next()) |arg| {
        const strs = .{
            .{ "--kind", "--kind requires a value", &kind },
            .{ "--agent", "--agent requires a value", &kind },
            .{ "--id", "--id requires a value", &id },
            .{ "--session", "--session requires a value", &id },
        };
        var matched = false;
        inline for (strs) |f| {
            if (!matched) switch (strFlag(it, arg, f[0], f[1], f[2])) {
                .no => {},
                .ok => matched = true,
                .fail => |m| return .{ .usage = m },
            };
        }
        if (matched) continue;
        switch (try intFlag(u64, arena, it, arg, "--surface", 0, &surface)) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        switch (try u32Flag(arena, it, arg, "--workspace", &workspace)) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        switch (try u32Flag(arena, it, arg, "--tab", &tab)) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        if (std.mem.eql(u8, arg, "--json")) continue;
        if (isHelp(arg)) return .help;
        if (std.mem.startsWith(u8, arg, "--")) return usageMsg(arena, "unknown flag '{s}'", .{arg});
        return usageMsg(arena, "unexpected argument '{s}'", .{arg});
    }
    var m: Members = .{ .arena = arena };
    switch (sub) {
        .capture => {
            const k = kind orelse return usageMsg(arena, "capture requires --kind <agent>", .{});
            const i = id orelse return usageMsg(arena, "capture requires --id <session-id>", .{});
            try m.add("\"agent\":{f}", .{std.json.fmt(k, .{})});
            try m.add("\"session\":{f}", .{std.json.fmt(i, .{})});
            if (surface) |s| try m.add("\"surface\":{d}", .{s});
            return request(arena, "session-capture", try m.object());
        },
        .@"resume" => {
            if (surface) |s| try m.add("\"surface\":{d}", .{s});
            if (workspace) |n| try m.add("\"workspace\":{d}", .{n});
            if (tab) |n| try m.add("\"tab\":{d}", .{n});
            return request(arena, "session-resume", try m.object());
        },
        .show => return request(arena, "session-list", null),
        .save => return request(arena, "session-save", null),
        .restore => return request(arena, "session-restore", null),
    }
}

fn parseBrowser(arena: Allocator, it: *Args) Allocator.Error!Parsed {
    const sub_str = it.next() orelse return usageMsg(arena, "usage: ghostty +browser <open|navigate|eval|list|snapshot|click|fill> [args]", .{});
    if (isHelp(sub_str)) return .help;
    const Sub = enum { open, navigate, eval, list, snapshot, click, fill };
    const sub = std.meta.stringToEnum(Sub, sub_str) orelse return usageMsg(arena, "unknown subcommand '{s}'", .{sub_str});
    var positional: ?[]const u8 = null;
    var positional2: ?[]const u8 = null;
    var id: ?u32 = null;
    var as_tab = false;
    while (it.next()) |arg| {
        // The legacy meanings: --tab and --split are booleans (open's target).
        if (std.mem.eql(u8, arg, "--tab")) {
            as_tab = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--split")) continue;
        switch (try u32Flag(arena, it, arg, "--id", &id)) {
            .no => {},
            .ok => continue,
            .fail => |m| return .{ .usage = m },
        }
        if (isHelp(arg)) return .help;
        if (std.mem.startsWith(u8, arg, "--")) return usageMsg(arena, "unknown flag '{s}'", .{arg});
        if (positional == null) {
            positional = arg;
        } else if (positional2 == null and sub == .fill) {
            positional2 = arg;
        } else return usageMsg(arena, "unexpected argument '{s}'", .{arg});
    }
    var m: Members = .{ .arena = arena };
    switch (sub) {
        .open => {
            const url = positional orelse return usageMsg(arena, "open requires a <url>", .{});
            try m.add("\"url\":{f}", .{std.json.fmt(url, .{})});
            try m.add("\"target\":\"{s}\"", .{if (as_tab) "tab" else "split"});
            return request(arena, "open", try m.object());
        },
        .navigate, .eval => {
            const val = positional orelse return usageMsg(arena, "{s}", .{if (sub == .navigate) "navigate requires a <url>" else "eval requires a <js> expression"});
            try m.add("\"{s}\":{f}", .{ if (sub == .navigate) "url" else "js", std.json.fmt(val, .{}) });
            if (id) |n| try m.add("\"id\":{d}", .{n});
            return request(arena, @tagName(sub), try m.object());
        },
        .snapshot => {
            const n = id orelse return request(arena, "snapshot", null);
            try m.add("\"id\":{d}", .{n});
            return request(arena, "snapshot", try m.object());
        },
        .click, .fill => {
            const missing = if (sub == .click) "click requires a <ref>" else "fill requires a <ref> and <text>";
            const ref_str = positional orelse return usageMsg(arena, "{s}", .{missing});
            const text: ?[]const u8 = if (sub == .fill) (positional2 orelse return usageMsg(arena, "{s}", .{missing})) else null;
            const ref = std.fmt.parseInt(i64, ref_str, 10) catch return usageMsg(arena, "invalid <ref> (must be an integer backendNodeId)", .{});
            try m.add("\"ref\":{d}", .{ref});
            if (text) |x| try m.add("\"text\":{f}", .{std.json.fmt(x, .{})});
            if (id) |n| try m.add("\"id\":{d}", .{n});
            return request(arena, @tagName(sub), try m.object());
        },
        .list => return .browser_list,
    }
}

// ----- execution -----

pub const Outcome = union(enum) {
    /// Served; the exit code.
    done: u8,
    /// Ghostty's own detection decides (another `+action` or `--version`
    /// in the argv): run `..\wmux.exe` with the original arguments.
    relay_gui,
    /// No legacy pipe exists: use the cmux mapping (ADR-4.11).
    fallback,
};

pub const LegacyIo = struct {
    arena: Allocator,
    out: *Writer,
    err: *Writer,
    /// `GHOSTTY_PID` from the environment, if set.
    ghostty_pid: ?[]const u8,
};

const legacy_prefix = "wmux-ipc-";

fn bareName(name: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, name, '\\') orelse return name;
    return name[i + 1 ..];
}

fn isLegacyPipe(name: []const u8) bool {
    const b = bareName(name);
    return b.len >= legacy_prefix.len and std.ascii.eqlIgnoreCase(b[0..legacy_prefix.len], legacy_prefix);
}

fn trimmedPid(io: LegacyIo) ?[]const u8 {
    const raw = io.ghostty_pid orelse return null;
    const t = std.mem.trim(u8, raw, &std.ascii.whitespace);
    return if (t.len > 0) t else null;
}

/// True when the legacy client has somewhere to go: `GHOSTTY_PID` is set or
/// a `wmux-ipc-*` pipe exists.
fn hasLegacyPipe(io: LegacyIo, platform: anytype) Allocator.Error!bool {
    if (trimmedPid(io) != null) return true;
    for (try platform.enumeratePipes(io.arena)) |n| if (isLegacyPipe(n)) return true;
    return false;
}

/// The old resolution: `GHOSTTY_PID`, else the only `wmux-ipc-*` pipe.
/// Null after printing the old message.
fn resolvePipePath(io: LegacyIo, platform: anytype) !?[]const u8 {
    if (trimmedPid(io)) |pid| return try std.fmt.allocPrint(io.arena, "\\\\.\\pipe\\wmux-ipc-{s}", .{pid});
    var first: ?[]const u8 = null;
    for (try platform.enumeratePipes(io.arena)) |n| {
        if (!isLegacyPipe(n)) continue;
        if (first != null) {
            try io.err.writeAll("multiple Ghostty instances found; set GHOSTTY_PID to choose one\n");
            return null;
        }
        first = bareName(n);
    }
    const name = first orelse {
        try io.err.writeAll("no running Ghostty instance found (set GHOSTTY_PID or start Ghostty)\n");
        return null;
    };
    return try std.fmt.allocPrint(io.arena, "\\\\.\\pipe\\{s}", .{name});
}

const connect_timeout_ms: u32 = 2000;
/// The old client blocked without a timeout (a browser eval can be slow).
const io_timeout_ms: u32 = std.math.maxInt(u32);

fn sendRequest(io: LegacyIo, platform: anytype, line: []const u8) !u8 {
    const path = (try resolvePipePath(io, platform)) orelse return 1;
    const t = platform.connect(io.arena, path, connect_timeout_ms) catch {
        try io.err.print("could not connect to Ghostty IPC pipe ({s})\n", .{path});
        return 1;
    };
    defer t.close();
    t.write(line, io_timeout_ms) catch {
        try io.err.writeAll("failed to write IPC request\n");
        return 1;
    };
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    const reply = while (true) {
        if (std.mem.indexOfScalar(u8, buf.items, '\n')) |nl| {
            var l = buf.items[0..nl];
            if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
            break l;
        }
        const n = t.read(&chunk, io_timeout_ms) catch 0;
        if (n == 0) {
            try io.err.writeAll("no response from Ghostty\n");
            return 1;
        }
        if (buf.items.len + n > max_line_bytes) return error.MessageTooLong;
        try buf.appendSlice(io.arena, chunk[0..n]);
    };
    return printResponse(io, reply);
}

/// `data` re-serialized on success, `error` on failure (the old format).
pub fn printResponse(io: LegacyIo, line: []const u8) !u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, io.arena, line, .{}) catch {
        try io.err.print("malformed response: {s}\n", .{line});
        return 1;
    };
    const obj = switch (parsed) {
        .object => |o| o,
        else => {
            try io.err.print("malformed response: {s}\n", .{line});
            return 1;
        },
    };
    const ok = if (obj.get("ok")) |v| (v == .bool and v.bool) else false;
    if (!ok) {
        const msg = if (obj.get("error")) |v| (if (v == .string) v.string else "unknown error") else "unknown error";
        try io.err.print("{s}\n", .{msg});
        return 1;
    }
    if (obj.get("data")) |data| {
        try std.json.Stringify.value(data, .{}, io.out);
        try io.out.writeAll("\n");
    }
    return 0;
}

fn execute(io: LegacyIo, platform: anytype, parsed: Parsed) !u8 {
    switch (parsed) {
        .help => return error.ActionHelpRequested,
        .usage => |msg| {
            try io.err.print("{s}\n", .{msg});
            return 1;
        },
        .new_window => {
            try io.err.writeAll("+new-window is not supported on this platform.\n");
            return 1;
        },
        .toggle_quick_terminal => return 1,
        .browser_list => {
            const path = (try resolvePipePath(io, platform)) orelse return 1;
            try io.out.print("connected instance pipe: {s}\n", .{path});
            return 0;
        },
        .request => |line| return sendRequest(io, platform, line),
    }
}

/// Serves a legacy `+verb` (`rest[0]`, one of `legacy_verbs`) with the old
/// output. `platform` is a `platform.Platform` (connect, enumeratePipes,
/// cwd).
pub fn runLegacy(io: LegacyIo, platform: anytype, rest: []const []const u8) Outcome {
    return runLegacyInner(io, platform, rest) catch |err| {
        // The old verbs printed every escaping error by name.
        io.err.print("error: {s}\n", .{@errorName(err)}) catch {};
        return .{ .done = 1 };
    };
}

fn runLegacyInner(io: LegacyIo, platform: anytype, rest: []const []const u8) !Outcome {
    std.debug.assert(rest.len > 0 and rest[0].len > 1 and rest[0][0] == '+');
    const verb = rest[0][1..];
    var overridden = false;
    var filtered: std.ArrayList([]const u8) = .empty;
    for (rest[1..]) |a| {
        if (std.mem.eql(u8, a, "--version")) overridden = true;
        if (a.len > 0 and a[0] == '+') {
            overridden = true;
            continue;
        }
        try filtered.append(io.arena, a);
    }
    const cwd: ?[]const u8 = platform.cwd(io.arena);
    const parsed = try parseLegacy(io.arena, verb, filtered.items, cwd);
    // Help and the two unsupported verbs never needed a pipe.
    const offline = switch (parsed) {
        .help, .new_window, .toggle_quick_terminal => true,
        else => false,
    };
    if ((overridden or !offline) and !try hasLegacyPipe(io, platform)) return .fallback;
    if (overridden) return .relay_gui;
    return .{ .done = try execute(io, platform, parsed) };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "unit: cli-relay: wmux.exe routes argv per ADR-4.10" {
    const R = GuiRoute;
    const cases = [_]struct { argv: []const []const u8, want: R }{
        .{ .argv = &.{}, .want = .app },
        .{ .argv = &.{"--new-window"}, .want = .app },
        .{ .argv = &.{ "--config-file=x", "-e", "+workspace" }, .want = .app },
        .{ .argv = &.{ "-e", "cmd.exe" }, .want = .app },
        .{ .argv = &.{"C:\\work"}, .want = .app },
        .{ .argv = &.{"+list-themes"}, .want = .in_process },
        .{ .argv = &.{ "+ssh", "--help" }, .want = .in_process },
        .{ .argv = &.{"+hooks"}, .want = .in_process },
        .{ .argv = &.{"--version"}, .want = .in_process },
        .{ .argv = &.{"--help"}, .want = .in_process },
        .{ .argv = &.{"+frobnicate"}, .want = .in_process },
        .{ .argv = &.{ "+workspace", "+tab" }, .want = .in_process },
        .{ .argv = &.{ "+workspace", "list", "--version" }, .want = .in_process },
        .{ .argv = &.{ "+workspace", "list" }, .want = .relay },
        .{ .argv = &.{ "+send", "hi", "--enter" }, .want = .relay },
        .{ .argv = &.{ "+workspace", "--help" }, .want = .relay },
        .{ .argv = &.{"+toggle-quick-terminal"}, .want = .relay },
        .{ .argv = &.{ "list-workspaces", "--json" }, .want = .relay },
        .{ .argv = &.{ "wmux", "attention", "ring" }, .want = .relay },
        .{ .argv = &.{"help"}, .want = .relay },
        .{ .argv = &.{ "send", "--", "--version" }, .want = .relay },
        .{ .argv = &.{ "--json", "list-workspaces" }, .want = .relay },
        .{ .argv = &.{ "--socket", "\\\\.\\pipe\\x", "ping" }, .want = .relay },
        .{ .argv = &.{ "--id-format=uuids", "tree" }, .want = .relay },
        .{ .argv = &.{"--window-width=80"}, .want = .app },
    };
    for (cases) |c| {
        testing.expectEqual(c.want, routeGui(c.argv)) catch |e| {
            std.debug.print("argv: {any}\n", .{c.argv});
            return e;
        };
    }
}

test "unit: cli-relay: the action tables are disjoint" {
    for (legacy_verbs) |v| try testing.expect(!isGhosttyAction(v));
    try testing.expect(isCliWord("list-workspaces"));
    try testing.expect(!isCliWord("List"));
    try testing.expect(!isCliWord("x.txt"));
    try testing.expect(!isCliWord("-e"));
    try testing.expect(isGlobalCliOption("--socket=x"));
    try testing.expect(!isGlobalCliOption("--socketx"));
}

fn expectParsed(verb: []const u8, args: []const []const u8, want: Parsed) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try parseLegacy(arena_state.allocator(), verb, args, "C:\\work");
    errdefer std.debug.print("+{s} {any}: got {any}\n", .{ verb, args, got });
    try testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(got));
    switch (want) {
        .usage => |m| try testing.expectEqualStrings(m, got.usage),
        .request => |r| try testing.expectEqualStrings(r, got.request),
        else => {},
    }
}

fn req(comptime s: []const u8) Parsed {
    return .{ .request = s ++ "\n" };
}

fn usg(s: []const u8) Parsed {
    return .{ .usage = s };
}

test "unit: cli-relay: legacy +verbs build the old request lines" {
    try expectParsed("workspace", &.{"list"}, req("{\"id\":1,\"cmd\":\"workspace-list\"}"));
    try expectParsed("workspace", &.{ "new", "--name", "pv-two" }, req("{\"id\":1,\"cmd\":\"workspace-new\",\"args\":{\"name\":\"pv-two\"}}"));
    try expectParsed("workspace", &.{"new"}, req("{\"id\":1,\"cmd\":\"workspace-new\"}"));
    try expectParsed("workspace", &.{ "new", "--worktree=feat", "--repo", "D:\\r", "--command", "ssh h", "--focus" }, req("{\"id\":1,\"cmd\":\"workspace-new\",\"args\":{\"worktree\":\"feat\",\"cwd\":\"C:\\\\work\",\"repo\":\"D:\\\\r\",\"command\":\"ssh h\",\"focus\":true}}"));
    try expectParsed("workspace", &.{ "select", "1" }, req("{\"id\":1,\"cmd\":\"workspace-select\",\"args\":{\"index\":1}}"));
    try expectParsed("workspace", &.{ "close", "1" }, req("{\"id\":1,\"cmd\":\"workspace-close\",\"args\":{\"index\":1}}"));
    try expectParsed("tab", &.{"list"}, req("{\"id\":1,\"cmd\":\"tab-list\",\"args\":{}}"));
    try expectParsed("tab", &.{ "close", "1", "--pane", "1" }, req("{\"id\":1,\"cmd\":\"tab-close\",\"args\":{\"index\":1,\"pane\":1}}"));
    try expectParsed("tab", &.{ "new", "--focus", "--command=pwsh", "--workspace=2" }, req("{\"id\":1,\"cmd\":\"tab-new\",\"args\":{\"workspace\":2,\"command\":\"pwsh\",\"focus\":true}}"));
    try expectParsed("send", &.{ "echo PV-MARK-1", "--enter" }, req("{\"id\":1,\"cmd\":\"send\",\"args\":{\"text\":\"echo PV-MARK-1\",\"enter\":true}}"));
    try expectParsed("send", &.{ "x", "--tab", "2", "--workspace", "1", "--pane=3" }, req("{\"id\":1,\"cmd\":\"send\",\"args\":{\"text\":\"x\",\"workspace\":1,\"tab\":2,\"pane\":3}}"));
    try expectParsed("read-screen", &.{ "--lines", "3" }, req("{\"id\":1,\"cmd\":\"read-screen\",\"args\":{\"lines\":3}}"));
    try expectParsed("capture-pane", &.{}, req("{\"id\":1,\"cmd\":\"capture-pane\",\"args\":{}}"));
    try expectParsed("capture-pane", &.{ "--file", "C:\\w\\c.txt", "--scrollback" }, req("{\"id\":1,\"cmd\":\"capture-pane\",\"args\":{\"scrollback\":true,\"file\":\"C:\\\\w\\\\c.txt\"}}"));
    try expectParsed("split", &.{"right"}, req("{\"id\":1,\"cmd\":\"new-split\",\"args\":{\"dir\":\"right\"}}"));
    try expectParsed("surface", &.{"list"}, req("{\"id\":1,\"cmd\":\"surface-list\",\"args\":{}}"));
    try expectParsed("surface", &.{ "focus", "--pane", "0", "--tab", "0" }, req("{\"id\":1,\"cmd\":\"surface-focus\",\"args\":{\"tab\":0,\"pane\":0}}"));
    try expectParsed("surface", &.{ "focus", "0x10" }, req("{\"id\":1,\"cmd\":\"surface-focus\",\"args\":{\"surface\":16}}"));
    try expectParsed("status", &.{ "set", "pv-busy" }, req("{\"id\":1,\"cmd\":\"set-status\",\"args\":{\"text\":\"pv-busy\"}}"));
    try expectParsed("status", &.{"set"}, req("{\"id\":1,\"cmd\":\"set-status\",\"args\":{\"text\":\"\"}}"));
    try expectParsed("status", &.{ "progress", "40" }, req("{\"id\":1,\"cmd\":\"set-progress\",\"args\":{\"value\":40}}"));
    try expectParsed("status", &.{ "progress", "clear" }, req("{\"id\":1,\"cmd\":\"set-progress\",\"args\":{\"value\":-1}}"));
    try expectParsed("log", &.{"hello from plus-verbs"}, req("{\"id\":1,\"cmd\":\"log\",\"args\":{\"text\":\"hello from plus-verbs\"}}"));
    try expectParsed("notify", &.{ "ring", "--workspace", "1" }, req("{\"id\":1,\"cmd\":\"notify\",\"args\":{\"action\":\"ring\",\"workspace\":1}}"));
    try expectParsed("notify", &.{"Hello world"}, req("{\"id\":1,\"cmd\":\"notify\",\"args\":{\"action\":\"ring\"}}"));
    try expectParsed("notify", &.{"mark-oldest-next"}, req("{\"id\":1,\"cmd\":\"notify\",\"args\":{\"action\":\"mark-oldest-next\"}}"));
    try expectParsed("session", &.{ "capture", "--kind", "pv-agent", "--id", "pv-session-1" }, req("{\"id\":1,\"cmd\":\"session-capture\",\"args\":{\"agent\":\"pv-agent\",\"session\":\"pv-session-1\"}}"));
    try expectParsed("session", &.{"resume"}, req("{\"id\":1,\"cmd\":\"session-resume\",\"args\":{}}"));
    try expectParsed("session", &.{ "show", "--json" }, req("{\"id\":1,\"cmd\":\"session-list\"}"));
    try expectParsed("session", &.{"save"}, req("{\"id\":1,\"cmd\":\"session-save\"}"));
    try expectParsed("session", &.{"restore"}, req("{\"id\":1,\"cmd\":\"session-restore\"}"));
    try expectParsed("browser", &.{ "open", "about:blank", "--tab" }, req("{\"id\":1,\"cmd\":\"open\",\"args\":{\"url\":\"about:blank\",\"target\":\"tab\"}}"));
    try expectParsed("browser", &.{ "open", "about:blank", "--split" }, req("{\"id\":1,\"cmd\":\"open\",\"args\":{\"url\":\"about:blank\",\"target\":\"split\"}}"));
    try expectParsed("browser", &.{ "eval", "document.title", "--id", "2" }, req("{\"id\":1,\"cmd\":\"eval\",\"args\":{\"js\":\"document.title\",\"id\":2}}"));
    try expectParsed("browser", &.{ "navigate", "data:x" }, req("{\"id\":1,\"cmd\":\"navigate\",\"args\":{\"url\":\"data:x\"}}"));
    try expectParsed("browser", &.{"snapshot"}, req("{\"id\":1,\"cmd\":\"snapshot\"}"));
    try expectParsed("browser", &.{ "click", "7" }, req("{\"id\":1,\"cmd\":\"click\",\"args\":{\"ref\":7}}"));
    try expectParsed("browser", &.{ "fill", "2", "pv-text" }, req("{\"id\":1,\"cmd\":\"fill\",\"args\":{\"ref\":2,\"text\":\"pv-text\"}}"));
    try expectParsed("browser", &.{"list"}, .browser_list);
    try expectParsed("new-window", &.{"--help"}, .new_window);
    try expectParsed("toggle-quick-terminal", &.{}, .toggle_quick_terminal);
}

test "unit: cli-relay: legacy +verbs keep the old help and usage errors" {
    // Every pipe-backed verb (all but new-window and toggle-quick-terminal).
    for (legacy_verbs[0..12]) |v| {
        try expectParsed(v, &.{"--help"}, .help);
        try expectParsed(v, &.{"-h"}, .help);
    }
    try expectParsed("workspace", &.{ "new", "--help" }, .help);
    try expectParsed("workspace", &.{}, usg("usage: ghostty +workspace <list|new|select|close> [args]"));
    try expectParsed("workspace", &.{ "select", "99x" }, usg("invalid <index> (must be a non-negative integer)"));
    try expectParsed("workspace", &.{"close"}, usg("this subcommand requires an <index>"));
    try expectParsed("workspace", &.{ "list", "--focus" }, usg("--worktree/--repo/--focus/--command are only valid for 'new'"));
    try expectParsed("workspace", &.{ "new", "--name" }, usg("--name requires a value"));
    try expectParsed("workspace", &.{ "new", "--worktree" }, usg("--worktree requires a <branch>"));
    try expectParsed("tab", &.{"frob"}, usg("unknown subcommand 'frob'"));
    try expectParsed("tab", &.{}, usg("usage: wmux +tab <list|new|select|close> [args]"));
    try expectParsed("tab", &.{ "list", "--focus" }, usg("--focus is only valid for 'new'"));
    try expectParsed("tab", &.{ "list", "--pane", "x" }, usg("invalid --pane value"));
    try expectParsed("send", &.{}, usg("send requires a <text> argument"));
    try expectParsed("send", &.{ "a", "b" }, usg("unexpected argument 'b'"));
    try expectParsed("send", &.{ "a", "--version" }, usg("unknown flag '--version'"));
    try expectParsed("send", &.{ "a", "--tab" }, usg("--tab requires a value"));
    try expectParsed("split", &.{}, usg("usage: wmux +split <right|down|left|up> [--workspace I] [--pane P] [--command \"...\"]"));
    try expectParsed("split", &.{"sideways"}, usg("direction must be 'right', 'down', 'left', or 'up', got 'sideways'"));
    try expectParsed("split", &.{ "up", "--bogus" }, usg("unexpected argument '--bogus'"));
    try expectParsed("status", &.{ "progress", "400" }, usg("progress must be 0-100 or 'clear'"));
    try expectParsed("status", &.{ "progress", "x" }, usg("invalid progress value 'x' (use 0-100 or 'clear')"));
    try expectParsed("status", &.{"progress"}, usg("progress requires a value (0-100 or 'clear')"));
    try expectParsed("log", &.{}, usg("usage: ghostty +log <text> [--workspace I] [--tab J] [--pane P]"));
    try expectParsed("notify", &.{}, usg("usage: ghostty +notify [ring|clear|next|toggle-read|mark-oldest-next] [<text>] [--workspace I] [--tab J] [--pane P]"));
    try expectParsed("surface", &.{"focus"}, usg("focus needs a surface <id>, or --workspace/--tab/--pane"));
    try expectParsed("surface", &.{ "focus", "zz" }, usg("invalid surface id 'zz'"));
    try expectParsed("session", &.{"capture"}, usg("capture requires --kind <agent>"));
    try expectParsed("session", &.{ "capture", "--agent", "claude" }, usg("capture requires --id <session-id>"));
    try expectParsed("session", &.{ "resume", "--surface", "nope" }, usg("invalid --surface value"));
    try expectParsed("browser", &.{"frob"}, usg("unknown subcommand 'frob'"));
    try expectParsed("browser", &.{"open"}, usg("open requires a <url>"));
    try expectParsed("browser", &.{ "click", "x" }, usg("invalid <ref> (must be an integer backendNodeId)"));
    try expectParsed("browser", &.{ "fill", "1" }, usg("fill requires a <ref> and <text>"));
    try expectParsed("read-screen", &.{"--bogus"}, usg("unexpected argument '--bogus'"));
}

/// A legacy pipe server for the client tests: answers every request line
/// with `reply` and records it.
const FakeLegacy = struct {
    reply: []const u8,
    got: std.ArrayList(u8) = .empty,
    a: Allocator,
    sent: bool = false,
    /// Keep returning `reply` (never a complete line).
    endless: bool = false,
    connects: usize = 0,
    pipes: []const []const u8 = &.{},
    connected_path: []const u8 = "",

    const T = struct {
        f: *FakeLegacy,
        pub fn write(t: T, bytes: []const u8, _: u32) error{Closed}!void {
            t.f.got.appendSlice(t.f.a, bytes) catch return error.Closed;
        }
        pub fn read(t: T, buf: []u8, _: u32) error{Timeout}!usize {
            if (t.f.sent and !t.f.endless) return 0;
            t.f.sent = true;
            const n = @min(buf.len, t.f.reply.len);
            @memcpy(buf[0..n], t.f.reply[0..n]);
            return n;
        }
        pub fn close(_: T) void {}
    };

    pub fn connect(f: *FakeLegacy, _: Allocator, path: []const u8, _: u32) error{NotFound}!T {
        f.connects += 1;
        f.connected_path = path;
        if (std.mem.indexOf(u8, path, "404") != null) return error.NotFound;
        return .{ .f = f };
    }
    pub fn enumeratePipes(f: *FakeLegacy, gpa: Allocator) Allocator.Error![][]u8 {
        const out = try gpa.alloc([]u8, f.pipes.len);
        for (f.pipes, 0..) |p, i| out[i] = try gpa.dupe(u8, p);
        return out;
    }
    pub fn cwd(_: *FakeLegacy, gpa: Allocator) ?[]u8 {
        return gpa.dupe(u8, "C:\\work") catch null;
    }
};

const LegacyRun = struct { outcome: Outcome, out: []const u8, err: []const u8 };

fn runFake(a: Allocator, f: *FakeLegacy, pid: ?[]const u8, rest: []const []const u8) LegacyRun {
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    const o = runLegacy(.{ .arena = a, .out = &out.writer, .err = &err.writer, .ghostty_pid = pid }, f, rest);
    return .{ .outcome = o, .out = out.written(), .err = err.written() };
}

test "unit: cli-relay: legacy client prints data and errors like the old verbs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var f: FakeLegacy = .{ .a = a, .reply = "{\"id\":1,\"ok\":true,\"data\":[{\"index\":0,\"name\":\"\",\"active\":true,\"tab_count\":1}]}\r\n" };
    var r = runFake(a, &f, " 4711 ", &.{ "+workspace", "list" });
    try testing.expectEqual(@as(u8, 0), r.outcome.done);
    try testing.expectEqualStrings("[{\"index\":0,\"name\":\"\",\"active\":true,\"tab_count\":1}]\n", r.out);
    try testing.expectEqualStrings("", r.err);
    try testing.expectEqualStrings("\\\\.\\pipe\\wmux-ipc-4711", f.connected_path);
    try testing.expectEqualStrings("{\"id\":1,\"cmd\":\"workspace-list\"}\n", f.got.items);

    f = .{ .a = a, .reply = "{\"id\":1,\"ok\":true,\"data\":null}\n" };
    r = runFake(a, &f, "1", &.{ "+workspace", "select", "0" });
    try testing.expectEqualStrings("null\n", r.out);

    f = .{ .a = a, .reply = "{\"id\":1,\"ok\":false,\"error\":\"UnknownWorkspace\"}\n" };
    r = runFake(a, &f, "1", &.{ "+workspace", "select", "99" });
    try testing.expectEqual(@as(u8, 1), r.outcome.done);
    try testing.expectEqualStrings("UnknownWorkspace\n", r.err);

    f = .{ .a = a, .reply = "{\"id\":1,\"ok\":true,\"data\":{\"id\":123456789012345678}}\n" };
    r = runFake(a, &f, "1", &.{ "+split", "right" });
    try testing.expectEqualStrings("{\"id\":123456789012345678}\n", r.out);

    f = .{ .a = a, .reply = "not json\n" };
    r = runFake(a, &f, "1", &.{"+capture-pane"});
    try testing.expectEqualStrings("malformed response: not json\n", r.err);

    f = .{ .a = a, .reply = "" };
    r = runFake(a, &f, "1", &.{"+capture-pane"});
    try testing.expectEqualStrings("no response from Ghostty\n", r.err);

    f = .{ .a = a, .reply = "" };
    r = runFake(a, &f, "404", &.{"+capture-pane"});
    try testing.expectEqualStrings("could not connect to Ghostty IPC pipe (\\\\.\\pipe\\wmux-ipc-404)\n", r.err);
}

test "unit: cli-relay: help, usage, browser list and the fallback" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f: FakeLegacy = .{ .a = a, .reply = "" };

    // --help keeps the old text with or without an instance.
    var r = runFake(a, &f, null, &.{ "+workspace", "--help" });
    try testing.expectEqual(@as(u8, 1), r.outcome.done);
    try testing.expectEqualStrings("error: ActionHelpRequested\n", r.err);
    r = runFake(a, &f, null, &.{ "+new-window", "--help" });
    try testing.expectEqualStrings("+new-window is not supported on this platform.\n", r.err);
    r = runFake(a, &f, null, &.{"+toggle-quick-terminal"});
    try testing.expectEqual(@as(u8, 1), r.outcome.done);
    try testing.expectEqualStrings("", r.err);

    // Without GHOSTTY_PID or a wmux-ipc pipe the cmux mapping takes over.
    f.pipes = &.{ "wmux-stable-abcdef01-s1", "wmux-stable-abcdef01-s1-launch" };
    try testing.expect(runFake(a, &f, null, &.{ "+workspace", "list" }).outcome == .fallback);
    try testing.expect(runFake(a, &f, "  ", &.{"+tab"}).outcome == .fallback);
    try testing.expectEqual(@as(usize, 0), f.connects);

    // With an enumerated legacy pipe the usage errors are the old ones.
    f.pipes = &.{ "wmux-stable-abcdef01-s1", "\\\\.\\pipe\\wmux-ipc-77" };
    r = runFake(a, &f, null, &.{"+tab"});
    try testing.expectEqual(@as(u8, 1), r.outcome.done);
    try testing.expectEqualStrings("usage: wmux +tab <list|new|select|close> [args]\n", r.err);
    r = runFake(a, &f, null, &.{ "+browser", "list" });
    try testing.expectEqualStrings("connected instance pipe: \\\\.\\pipe\\wmux-ipc-77\n", r.out);
    f.pipes = &.{ "wmux-ipc-77", "wmux-ipc-78" };
    r = runFake(a, &f, null, &.{ "+browser", "list" });
    try testing.expectEqualStrings("multiple Ghostty instances found; set GHOSTTY_PID to choose one\n", r.err);

    // Another +action or --version anywhere: Ghostty's detection decides.
    try testing.expect(runFake(a, &f, "1", &.{ "+send", "hi", "--version" }).outcome == .relay_gui);
    try testing.expect(runFake(a, &f, "1", &.{ "+send", "+list-fonts" }).outcome == .relay_gui);
    // `+`-prefixed tokens were dropped by Ghostty's ArgsIterator.
    try expectParsed("send", &.{"hi"}, req("{\"id\":1,\"cmd\":\"send\",\"args\":{\"text\":\"hi\"}}"));
}

test "unit: cli-relay: an oversized reply fails like the old line framer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f: FakeLegacy = .{ .a = a, .reply = "x" ** 4096, .endless = true };
    const r = runFake(a, &f, "1", &.{"+read-screen"});
    try testing.expectEqual(@as(u8, 1), r.outcome.done);
    try testing.expectEqualStrings("error: MessageTooLong\n", r.err);
}
