//! End-to-end tests of the CLI front end over the in-memory platform
//! (ADR-12.1): dispatch, offline help probes from the cmux CLI contract,
//! round trips of ping/capabilities/rpc/identify through a fake pipe server,
//! error mapping (connection refused, busy, timeout, bad JSON, error
//! envelope), legacy `+verbs`, and golden files under test/cli/golden/.
//!
//! Goldens are read at run time from `test/cli/golden/` relative to the
//! working directory (the repository root), or from `WMUX_CLI_GOLDEN_DIR`.
//! Set `WMUX_UPDATE_GOLDEN=1` to rewrite them.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");
const Env = proto.env_names.Env;
const main = @import("main.zig");
const fake = @import("fake.zig");
const platform_mod = @import("platform.zig");
const help = @import("help.zig");
const guide = @import("guide.zig");

const Result = struct { code: u8, out: []const u8, err: []const u8 };

const test_sid = "S-1-5-21-1000-1000-1000-1001";

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    fp: fake.Platform,
    pairs: std.ArrayList(Env.Pair),
    pairs_slice: []const Env.Pair,
    env_map: std.process.EnvMap,

    fn init(self: *Harness) void {
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        const a = self.arena_state.allocator();
        self.fp = fake.Platform.init(a);
        self.fp.sid = test_sid;
        self.fp.session = 1;
        self.pairs = .empty;
        self.pairs_slice = &.{};
        self.env_map = std.process.EnvMap.init(a);
        // Pin the channel so goldens do not depend on build options.
        self.setEnv("WMUX_CHANNEL", "stable");
    }

    fn deinit(self: *Harness) void {
        self.arena_state.deinit();
    }

    fn alloc(self: *Harness) Allocator {
        return self.arena_state.allocator();
    }

    fn setEnv(self: *Harness, name: []const u8, value: []const u8) void {
        self.pairs.append(self.alloc(), .{ name, value }) catch unreachable;
        self.env_map.put(name, value) catch unreachable;
    }

    fn control(self: *Harness) []const u8 {
        const h = proto.pipe_name.sidHash8(test_sid);
        return proto.pipe_name.controlName(self.alloc(), "stable", &h, 1) catch unreachable;
    }

    fn run(self: *Harness, argv: []const []const u8) Result {
        const al = self.alloc();
        var out: std.Io.Writer.Allocating = .init(al);
        var err: std.Io.Writer.Allocating = .init(al);
        self.pairs_slice = self.pairs.items;
        var names: std.ArrayList([]const u8) = .empty;
        for (self.pairs.items) |p| names.append(al, p[0]) catch unreachable;
        const code = main.run(.{
            .arena = al,
            .platform = self.fp.platform(),
            .env = Env.fromPairs(&self.pairs_slice),
            .env_names = names.items,
            .env_map = &self.env_map,
            .out = &out.writer,
            .err = &err.writer,
            .version_info = .{ .version = "1.2.3", .build = "456", .commit = "abcdef0123" },
        }, argv);
        return .{ .code = code, .out = out.written(), .err = err.written() };
    }
};

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn expectContains(hay: []const u8, needle: []const u8) !void {
    if (!contains(hay, needle)) {
        std.debug.print("\n--- expected to find ---\n{s}\n--- in ---\n{s}\n", .{ needle, hay });
        return error.TestExpectedContains;
    }
}

// ----- goldens -----

fn goldenDir(al: Allocator) []const u8 {
    return std.process.getEnvVarOwned(al, "WMUX_CLI_GOLDEN_DIR") catch "test/cli/golden";
}

fn expectGolden(al: Allocator, name: []const u8, actual: []const u8) !void {
    const path = try std.fs.path.join(al, &.{ goldenDir(al), name });
    const update = std.process.hasEnvVarConstant("WMUX_UPDATE_GOLDEN");
    if (update) {
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = actual });
        return;
    }
    const raw = std.fs.cwd().readFileAlloc(al, path, 1 << 20) catch |err| {
        std.debug.print("cannot read golden {s}: {s} (run from the repository root or set WMUX_CLI_GOLDEN_DIR)\n", .{ path, @errorName(err) });
        return err;
    };
    // Tolerate CRLF checkouts.
    const expected = try std.mem.replaceOwned(u8, al, raw, "\r\n", "\n");
    try testing.expectEqualStrings(expected, actual);
}

test "unit: cli-golden: help, version and socket-status text" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const al = h.alloc();
    const cases = [_]struct { []const u8, []const []const u8 }{
        .{ "help.txt", &.{ "cmux", "help" } },
        .{ "help-diagnostics.txt", &.{ "cmux", "help", "diagnostics" } },
        .{ "help-help.txt", &.{ "cmux", "help", "--help" } },
        .{ "version.txt", &.{ "cmux", "version" } },
        .{ "ping-help.txt", &.{ "cmux", "ping", "--help" } },
        .{ "capabilities-help.txt", &.{ "cmux", "capabilities", "--help" } },
        .{ "rpc-help.txt", &.{ "cmux", "rpc", "--help" } },
        .{ "identify-help.txt", &.{ "cmux", "identify", "--help" } },
        .{ "socket-status-help.txt", &.{ "cmux", "socket-status", "--help" } },
        .{ "socket-status.txt", &.{ "cmux", "socket-status" } },
        .{ "socket-status-json.txt", &.{ "cmux", "socket-status", "--json" } },
        .{ "docs.txt", &.{ "cmux", "docs" } },
        .{ "welcome.txt", &.{ "cmux", "welcome" } },
        .{ "wmux-version.txt", &.{ "wmux", "--version" } },
        .{ "wmux-ping-help.txt", &.{ "wmux", "ping", "--help" } },
    };
    for (cases) |c| {
        const r = h.run(c[1]);
        try testing.expectEqual(@as(u8, 0), r.code);
        try testing.expectEqualStrings("", r.err);
        try expectGolden(al, c[0], r.out);
    }
}

test "unit: cli-golden: socket-status under a forced policy" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fp.hklm = .{ .string = "off" };
    h.setEnv("CMUX_SOCKET_MODE", "allowAll");
    const r = h.run(&.{ "cmux", "socket-status" });
    try expectGolden(h.alloc(), "socket-status-policy.txt", r.out);
    const j = h.run(&.{ "cmux", "socket-status", "--json" });
    try expectGolden(h.alloc(), "socket-status-policy-json.txt", j.out);
}

// ----- offline help probes (cmux CLI contract, wmux subset) -----

const Probe = struct { argv: []const []const u8, want: []const u8 };

const probes = [_]Probe{
    .{ .argv = &.{"--help"}, .want = "cmux - control cmux via named pipe" },
    .{ .argv = &.{"-h"}, .want = "open <path-or-url>..." },
    .{ .argv = &.{"--help"}, .want = "sessions [list] [options]" },
    .{ .argv = &.{"--help"}, .want = "session restore [--list] [--session <id>]..." },
    .{ .argv = &.{"help"}, .want = "cmux - control cmux via named pipe" },
    .{ .argv = &.{"--help"}, .want = "Start & Resume:" },
    .{ .argv = &.{"--help"}, .want = "Diagnostics / Advanced:" },
    .{ .argv = &.{ "help", "start" }, .want = "Start & Resume:" },
    .{ .argv = &.{ "help", "agents" }, .want = "Agents:" },
    .{ .argv = &.{ "help", "navigate" }, .want = "Navigate & Arrange:" },
    .{ .argv = &.{ "help", "inspect" }, .want = "Inspect:" },
    .{ .argv = &.{ "help", "inspect" }, .want = "review list [--repo <path>] [--json]" },
    .{ .argv = &.{ "help", "customize" }, .want = "Customize:" },
    .{ .argv = &.{ "help", "automation" }, .want = "Automation:" },
    .{ .argv = &.{ "help", "browser" }, .want = "Browser:" },
    .{ .argv = &.{ "help", "remote" }, .want = "Remote:" },
    .{ .argv = &.{ "help", "diagnostics" }, .want = "Diagnostics / Advanced:" },
    .{ .argv = &.{ "help", "diagnostics" }, .want = "socket-status [--json]" },
    .{ .argv = &.{"--help"}, .want = "socket-status [--json]" },
    .{ .argv = &.{"--help"}, .want = "cmux help <start|agents|navigate|inspect|customize|automation|browser|remote|diagnostics>" },
    .{ .argv = &.{ "help", "--help" }, .want = "Usage: cmux help [topic]" },
    .{ .argv = &.{ "help", "unknown-task-topic" }, .want = "cmux - control cmux via named pipe" },
    .{ .argv = &.{"--help"}, .want = "cmux guide | cmux --skill" },
    .{ .argv = &.{"guide"}, .want = "# cmux guide" },
    .{ .argv = &.{"--skill"}, .want = "# cmux guide" },
    .{ .argv = &.{ "guide", "--help" }, .want = "Usage: cmux guide | cmux --skill [--json]" },
    .{ .argv = &.{ "--skill", "-h" }, .want = "Usage: cmux guide | cmux --skill [--json]" },
    .{ .argv = &.{ "sessions", "--help" }, .want = "Usage: cmux sessions list [options]" },
    .{ .argv = &.{ "ping", "--help" }, .want = "Usage: cmux ping" },
    .{ .argv = &.{ "ping", "--help" }, .want = "Check connectivity to the cmux socket server." },
    .{ .argv = &.{ "capabilities", "--help" }, .want = "Usage: cmux capabilities" },
    .{ .argv = &.{ "events", "--help" }, .want = "Usage: cmux events [options]" },
    .{ .argv = &.{ "surface", "--help" }, .want = "cmux surface resume set [flags] -- <argv...>" },
    .{ .argv = &.{ "surface-resume", "--help" }, .want = "cmux surface resume show [--json] [flags]" },
    .{ .argv = &.{ "rpc", "--help" }, .want = "Usage: cmux rpc <method> [json-params]" },
    .{ .argv = &.{ "comments", "--help" }, .want = "Usage: cmux comments <subcommand> [options]" },
    .{ .argv = &.{ "review", "--help" }, .want = "Usage: cmux review <subcommand> [options]" },
    .{ .argv = &.{ "vault", "--help" }, .want = "Usage: cmux vault <subcommand> [options]" },
    .{ .argv = &.{ "help", "--help" }, .want = "Usage: cmux help" },
    .{ .argv = &.{ "docs", "--help" }, .want = "Usage: cmux docs [settings|shortcuts|api|browser|capture|agents|workflows|dock|managed-policies]" },
    .{ .argv = &.{"docs"}, .want = "Topics:" },
    .{ .argv = &.{ "docs", "settings" }, .want = "Config files:" },
    .{ .argv = &.{ "docs", "capture" }, .want = "capture: Screenshot or record a cmux window" },
    .{ .argv = &.{ "docs", "dock" }, .want = "dock: Custom right-sidebar terminal controls" },
    .{ .argv = &.{ "settings", "--help" }, .want = "Usage: cmux settings [open [target]|path|docs|<target>]" },
    .{ .argv = &.{ "config", "--help" }, .want = "Usage: cmux config <doctor|check|validate|path|paths|docs|documentation|reload|get|set|unset|toggle|cycle|preset|sidebar-font-size|surface-tab-bar-font-size>" },
    .{ .argv = &.{ "welcome", "--help" }, .want = "Usage: cmux welcome" },
    .{ .argv = &.{ "welcome", "--help" }, .want = "the default shortcuts" },
    .{ .argv = &.{"welcome"}, .want = "Shortcuts" },
    .{ .argv = &.{"welcome"}, .want = "cmux shortcuts" },
    .{ .argv = &.{ "shortcuts", "--help" }, .want = "Usage: cmux shortcuts" },
    .{ .argv = &.{ "disable-browser", "--help" }, .want = "Usage: cmux disable-browser [--json]" },
    .{ .argv = &.{ "enable-browser", "--help" }, .want = "Usage: cmux enable-browser [--json]" },
    .{ .argv = &.{ "browser-status", "--help" }, .want = "Usage: cmux browser-status [--json]" },
    .{ .argv = &.{ "agent-hibernation", "--help" }, .want = "Usage: cmux agent-hibernation <on|off> [--json]" },
    .{ .argv = &.{ "agent-hibernation", "--help" }, .want = "cmux agent-hibernation <hibernate|wake> <surface> [--workspace <id|ref|index>] [--json]" },
    .{ .argv = &.{ "restore", "--help" }, .want = "Usage: cmux restore [--surface <id|ref>] <kind> <checkpoint-id>" },
    .{ .argv = &.{ "fork", "--help" }, .want = "Usage: cmux fork [--surface <id|ref>] <kind> <checkpoint-id>" },
    .{ .argv = &.{ "restore-session", "--help" }, .want = "Usage: cmux restore-session" },
    .{ .argv = &.{ "session", "restore", "--help" }, .want = "Usage: cmux session restore [--list] [--session <id>]..." },
    .{ .argv = &.{ "open", "--help" }, .want = "Usage: cmux open <path-or-url>..." },
    .{ .argv = &.{ "feed", "--help" }, .want = "Usage: cmux feed tui [--opentui|--legacy]" },
    .{ .argv = &.{ "hooks", "--help" }, .want = "Usage: cmux hooks setup [agent] [--agent <name>] [--yes|-y]" },
    .{ .argv = &.{ "codex", "--help" }, .want = "Usage: cmux codex <install-hooks|uninstall-hooks>" },
    .{ .argv = &.{ "themes", "--help" }, .want = "Usage: cmux themes" },
    .{ .argv = &.{ "import", "--help" }, .want = "Usage: cmux import" },
    .{ .argv = &.{ "omo", "--help" }, .want = "Usage: cmux omo [opencode-args...]" },
    .{ .argv = &.{ "omx", "--help" }, .want = "Usage: cmux omx [omx-args...]" },
    .{ .argv = &.{ "omc", "--help" }, .want = "Usage: cmux omc [omc-args...]" },
    .{ .argv = &.{ "identify", "--help" }, .want = "Usage: cmux identify" },
    .{ .argv = &.{ "list-windows", "--help" }, .want = "Usage: cmux list-windows" },
    .{ .argv = &.{ "current-window", "--help" }, .want = "Usage: cmux current-window" },
    .{ .argv = &.{ "new-window", "--help" }, .want = "Usage: cmux new-window" },
    .{ .argv = &.{ "focus-window", "--help" }, .want = "Usage: cmux focus-window --window <id|ref|index>" },
    .{ .argv = &.{ "close-window", "--help" }, .want = "Usage: cmux close-window --window <id|ref|index> [--force]" },
    .{ .argv = &.{ "resize-window", "--help" }, .want = "Usage: cmux resize-window --window <id|ref|index> [--width <points>] [--height <points>]" },
    .{ .argv = &.{ "move-workspace-to-window", "--help" }, .want = "Usage: cmux move-workspace-to-window" },
    .{ .argv = &.{ "move-surface", "--help" }, .want = "Usage: cmux move-surface" },
    .{ .argv = &.{ "split-off", "--help" }, .want = "Usage: cmux split-off" },
    .{ .argv = &.{ "reorder-surface", "--help" }, .want = "Usage: cmux reorder-surface" },
    .{ .argv = &.{ "reorder-workspace", "--help" }, .want = "Usage: cmux reorder-workspace" },
    .{ .argv = &.{ "reorder-workspaces", "--help" }, .want = "Usage: cmux reorder-workspaces" },
    .{ .argv = &.{ "workspace-action", "--help" }, .want = "Usage: cmux workspace-action --action <name>" },
    .{ .argv = &.{ "move-tab-to-new-workspace", "--help" }, .want = "Usage: cmux move-tab-to-new-workspace" },
    .{ .argv = &.{ "tab-action", "--help" }, .want = "Usage: cmux tab-action --action <name>" },
    .{ .argv = &.{ "rename-tab", "--help" }, .want = "Usage: cmux rename-tab" },
    .{ .argv = &.{ "new-workspace", "--help" }, .want = "Usage: cmux new-workspace" },
    .{ .argv = &.{ "new-workspace", "--help" }, .want = "--command <text>" },
    .{ .argv = &.{ "list-workspaces", "--help" }, .want = "Usage: cmux list-workspaces" },
    .{ .argv = &.{ "ssh", "--help" }, .want = "Usage: cmux ssh <destination>" },
    .{ .argv = &.{ "ssh", "--help" }, .want = "--forward-agent" },
    .{ .argv = &.{ "ssh", "--help" }, .want = "--transport <ssh|mosh>" },
    .{ .argv = &.{ "mosh", "--help" }, .want = "Usage: cmux mosh <destination>" },
    .{ .argv = &.{ "mosh-tmux", "--help" }, .want = "Usage: cmux mosh-tmux <destination>" },
    .{ .argv = &.{ "mosh-tmux", "--help" }, .want = "--session <name>" },
    .{ .argv = &.{ "ssh", "--help" }, .want = "--command <text>" },
    .{ .argv = &.{ "ssh", "--help" }, .want = "--no-focus              Open it in the background" },
    .{ .argv = &.{ "ssh-session-list", "--help" }, .want = "Usage: cmux ssh-session-list" },
    .{ .argv = &.{ "ssh-session-attach", "--help" }, .want = "Usage: cmux ssh-session-attach --session-id <id>" },
    .{ .argv = &.{ "ssh-session-cleanup", "--help" }, .want = "Usage: cmux ssh-session-cleanup" },
    .{ .argv = &.{ "new-split", "--help" }, .want = "Usage: cmux new-split" },
    .{ .argv = &.{ "new-split", "--help" }, .want = "--command <text>" },
    .{ .argv = &.{ "list-panes", "--help" }, .want = "Usage: cmux list-panes" },
    .{ .argv = &.{ "list-pane-surfaces", "--help" }, .want = "Usage: cmux list-pane-surfaces" },
    .{ .argv = &.{ "tree", "--help" }, .want = "Usage: cmux tree" },
    .{ .argv = &.{ "top", "--help" }, .want = "Usage: cmux top" },
    .{ .argv = &.{ "focus-pane", "--help" }, .want = "Usage: cmux focus-pane" },
    .{ .argv = &.{ "new-pane", "--help" }, .want = "Usage: cmux new-pane" },
    .{ .argv = &.{ "new-pane", "--help" }, .want = "--command <text>" },
    .{ .argv = &.{ "new-surface", "--help" }, .want = "Usage: cmux new-surface" },
    .{ .argv = &.{ "new-surface", "--help" }, .want = "--command <text>" },
    .{ .argv = &.{ "close-surface", "--help" }, .want = "Usage: cmux close-surface" },
    .{ .argv = &.{ "drag-surface-to-split", "--help" }, .want = "Usage: cmux drag-surface-to-split" },
    .{ .argv = &.{ "refresh-surfaces", "--help" }, .want = "Usage: cmux refresh-surfaces" },
    .{ .argv = &.{ "reload-config", "--help" }, .want = "Usage: cmux reload-config" },
    .{ .argv = &.{ "surface-health", "--help" }, .want = "Usage: cmux surface-health" },
    .{ .argv = &.{ "debug-terminals", "--help" }, .want = "Usage: cmux debug-terminals" },
    .{ .argv = &.{ "trigger-flash", "--help" }, .want = "Usage: cmux trigger-flash" },
    .{ .argv = &.{ "list-panels", "--help" }, .want = "Usage: cmux list-panels" },
    .{ .argv = &.{ "focus-panel", "--help" }, .want = "Usage: cmux focus-panel" },
    .{ .argv = &.{ "close-workspace", "--help" }, .want = "Usage: cmux close-workspace" },
    .{ .argv = &.{ "select-workspace", "--help" }, .want = "Usage: cmux select-workspace" },
    .{ .argv = &.{ "rename-workspace", "--help" }, .want = "Usage: cmux rename-workspace" },
    .{ .argv = &.{ "rename-window", "--help" }, .want = "Usage: cmux rename-workspace" },
    .{ .argv = &.{ "current-workspace", "--help" }, .want = "Usage: cmux current-workspace" },
    .{ .argv = &.{ "capture-pane", "--help" }, .want = "Usage: cmux capture-pane [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--scrollback] [--lines <n>]" },
    .{ .argv = &.{ "resize-pane", "--help" }, .want = "Usage: cmux resize-pane [--pane <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [-L|-R|-U|-D] [--amount <n>]" },
    .{ .argv = &.{ "pipe-pane", "--help" }, .want = "Usage: cmux pipe-pane [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--command <shell-command> | <shell-command>]" },
    .{ .argv = &.{ "wait-for", "--help" }, .want = "Usage: cmux wait-for [-S|--signal] <name> [--timeout <seconds>]" },
    .{ .argv = &.{ "swap-pane", "--help" }, .want = "Usage: cmux swap-pane --pane <id|ref|index> --target-pane <id|ref|index> [--workspace <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>]" },
    .{ .argv = &.{ "break-pane", "--help" }, .want = "Usage: cmux break-pane [--workspace <id|ref|index>] [--pane <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>] [--no-focus]" },
    .{ .argv = &.{ "join-pane", "--help" }, .want = "Usage: cmux join-pane --target-pane <id|ref|index> [--workspace <id|ref|index>] [--pane <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>] [--no-focus]" },
    .{ .argv = &.{ "next-window", "--help" }, .want = "Usage: cmux next-window" },
    .{ .argv = &.{ "previous-window", "--help" }, .want = "Usage: cmux previous-window" },
    .{ .argv = &.{ "last-window", "--help" }, .want = "Usage: cmux last-window" },
    .{ .argv = &.{ "last-pane", "--help" }, .want = "Usage: cmux last-pane" },
    .{ .argv = &.{ "find-window", "--help" }, .want = "Usage: cmux find-window" },
    .{ .argv = &.{ "clear-history", "--help" }, .want = "Usage: cmux clear-history" },
    .{ .argv = &.{ "set-hook", "--help" }, .want = "Usage: cmux set-hook" },
    .{ .argv = &.{ "popup", "--help" }, .want = "Usage: cmux popup" },
    .{ .argv = &.{ "bind-key", "--help" }, .want = "Usage: cmux bind-key" },
    .{ .argv = &.{ "unbind-key", "--help" }, .want = "Usage: cmux unbind-key" },
    .{ .argv = &.{ "copy-mode", "--help" }, .want = "Usage: cmux copy-mode" },
    .{ .argv = &.{ "set-buffer", "--help" }, .want = "Usage: cmux set-buffer" },
    .{ .argv = &.{ "paste-buffer", "--help" }, .want = "Usage: cmux paste-buffer" },
    .{ .argv = &.{ "list-buffers", "--help" }, .want = "Usage: cmux list-buffers" },
    .{ .argv = &.{ "respawn-pane", "--help" }, .want = "Usage: cmux respawn-pane" },
    .{ .argv = &.{ "display-message", "--help" }, .want = "Usage: cmux display-message" },
    .{ .argv = &.{ "read-screen", "--help" }, .want = "Usage: cmux read-screen" },
    .{ .argv = &.{ "record", "--help" }, .want = "Usage: cmux record [start] [flags]" },
    .{ .argv = &.{ "shot", "--help" }, .want = "Usage: cmux shot [flags]" },
    .{ .argv = &.{ "send", "--help" }, .want = "Usage: cmux send" },
    .{ .argv = &.{ "send-key", "--help" }, .want = "Usage: cmux send-key" },
    .{ .argv = &.{ "agent", "message", "--help" }, .want = "Usage: cmux agent message" },
    .{ .argv = &.{ "agent", "inbox", "--help" }, .want = "Usage: cmux agent inbox" },
    .{ .argv = &.{ "agent", "messages", "--help" }, .want = "Usage: cmux agent messages" },
    .{ .argv = &.{ "paste", "--help" }, .want = "Usage: cmux paste" },
    .{ .argv = &.{ "send-panel", "--help" }, .want = "Usage: cmux send-panel" },
    .{ .argv = &.{ "send-key-panel", "--help" }, .want = "Usage: cmux send-key-panel" },
    .{ .argv = &.{ "notify", "--help" }, .want = "Usage: cmux notify" },
    .{ .argv = &.{ "list-notifications", "--help" }, .want = "Usage: cmux list-notifications" },
    .{ .argv = &.{ "dismiss-notification", "--help" }, .want = "Usage: cmux dismiss-notification" },
    .{ .argv = &.{ "mark-notification-read", "--help" }, .want = "Usage: cmux mark-notification-read" },
    .{ .argv = &.{ "open-notification", "--help" }, .want = "Usage: cmux open-notification" },
    .{ .argv = &.{ "jump-to-unread", "--help" }, .want = "Usage: cmux jump-to-unread" },
    .{ .argv = &.{ "jump-to-last-prompt", "--help" }, .want = "Usage: cmux jump-to-last-prompt" },
    .{ .argv = &.{ "clear-notifications", "--help" }, .want = "Usage: cmux clear-notifications" },
    .{ .argv = &.{ "right-sidebar", "--help" }, .want = "Usage: cmux right-sidebar <command> [flags]" },
    .{ .argv = &.{ "set-status", "--help" }, .want = "Usage: cmux set-status" },
    .{ .argv = &.{ "clear-status", "--help" }, .want = "Usage: cmux clear-status" },
    .{ .argv = &.{ "list-status", "--help" }, .want = "Usage: cmux list-status" },
    .{ .argv = &.{ "set-progress", "--help" }, .want = "Usage: cmux set-progress" },
    .{ .argv = &.{ "clear-progress", "--help" }, .want = "Usage: cmux clear-progress" },
    .{ .argv = &.{ "log", "--help" }, .want = "Usage: cmux log" },
    .{ .argv = &.{ "clear-log", "--help" }, .want = "Usage: cmux clear-log" },
    .{ .argv = &.{ "list-log", "--help" }, .want = "Usage: cmux list-log" },
    .{ .argv = &.{ "sidebar-state", "--help" }, .want = "Usage: cmux sidebar-state" },
    .{ .argv = &.{ "set-app-focus", "--help" }, .want = "Usage: cmux set-app-focus" },
    .{ .argv = &.{ "simulate-app-active", "--help" }, .want = "Usage: cmux simulate-app-active" },
    .{ .argv = &.{ "claude-hook", "--help" }, .want = "Usage: cmux claude-hook" },
    .{ .argv = &.{ "browser", "--help" }, .want = "Usage: cmux browser" },
    .{ .argv = &.{ "help", "browser" }, .want = "browser react-grab toggle [--surface <id>] [--return-to <terminal-surface>]" },
    .{ .argv = &.{ "help", "browser" }, .want = "browser devtools toggle|console [--surface <id>]" },
    .{ .argv = &.{ "help", "browser" }, .want = "browser focus-mode enter|exit|toggle [--surface <id>]" },
    .{ .argv = &.{ "help", "browser" }, .want = "browser design-mode enable|disable|toggle|status [--surface <id>]" },
    .{ .argv = &.{ "help", "browser" }, .want = "browser zoom in|out|reset|<factor> [--surface <id>]" },
    .{ .argv = &.{ "help", "browser" }, .want = "browser history clear --force" },
    .{ .argv = &.{ "help", "browser" }, .want = "browser console <list|clear>" },
    .{ .argv = &.{ "help", "browser" }, .want = "browser errors <list|clear>" },
    .{ .argv = &.{ "browser", "--help" }, .want = "screenshot [--out <path>] [--json]" },
    .{ .argv = &.{ "browser", "--help" }, .want = "download list [--limit <1...25>] [--json]" },
    .{ .argv = &.{ "open-browser", "--help" }, .want = "Legacy alias for 'cmux browser open'" },
    .{ .argv = &.{ "navigate", "--help" }, .want = "Legacy alias for 'cmux browser navigate'" },
    .{ .argv = &.{ "browser-back", "--help" }, .want = "Legacy alias for 'cmux browser back'" },
    .{ .argv = &.{ "browser-forward", "--help" }, .want = "Legacy alias for 'cmux browser forward'" },
    .{ .argv = &.{ "browser-reload", "--help" }, .want = "Legacy alias for 'cmux browser reload'" },
    .{ .argv = &.{ "get-url", "--help" }, .want = "Legacy alias for 'cmux browser get-url'" },
    .{ .argv = &.{ "focus-webview", "--help" }, .want = "Legacy alias for 'cmux browser focus-webview'" },
    .{ .argv = &.{ "is-webview-focused", "--help" }, .want = "Legacy alias for 'cmux browser is-webview-focused'" },
    .{ .argv = &.{ "markdown", "--help" }, .want = "Usage: cmux markdown open <path>" },
    .{ .argv = &.{ "version", "--help" }, .want = "cmux 1.2.3 (456) [abcdef0]" },
    .{ .argv = &.{"--version"}, .want = "cmux 1.2.3 (456) [abcdef0]" },
    .{ .argv = &.{"-v"}, .want = "cmux 1.2.3 (456) [abcdef0]" },
    .{ .argv = &.{"version"}, .want = "cmux 1.2.3 (456) [abcdef0]" },
    .{ .argv = &.{ "socket-status", "--help" }, .want = "Usage: cmux socket-status [--json]" },
    .{ .argv = &.{"socket-status"}, .want = "Socket control mode: cmuxOnly. Live enforcement: not observed." },
};

test "unit: cli-probes: no-socket help probes exit 0 without connecting" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    for (probes) |p| {
        const argv = try std.mem.concat(h.alloc(), []const u8, &.{ &.{"cmux"}, p.argv });
        const r = h.run(argv);
        if (r.code != 0 or !contains(r.out, p.want)) {
            std.debug.print("\nprobe failed: cmux {s} (exit {d})\nwant: {s}\nout:\n{s}\nerr:\n{s}\n", .{ try std.mem.join(h.alloc(), " ", p.argv), r.code, p.want, r.out, r.err });
            return error.TestProbeFailed;
        }
    }
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
}

test "unit: cli-probes: help after double dash is forwarded, not intercepted" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const r = h.run(&.{ "cmux", "send", "--", "--help" });
    try testing.expect(!contains(r.out, "Usage:"));
    try testing.expectEqual(@as(u8, 1), r.code);
    try expectContains(r.err, "'send' is not available in this build of wmux yet");
    // rpc treats a forwarded --help as its params.
    const rpc = h.run(&.{ "cmux", "rpc", "system.ping", "--", "--help" });
    try testing.expect(!contains(rpc.out, "Usage:"));
}

test "unit: cli-probes: wmux branding rewrites help and usage" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const top = h.run(&.{ "C:\\Programs\\wmux\\cli\\wmux.exe", "--help" });
    try testing.expect(std.mem.startsWith(u8, top.out, "wmux - control wmux via named pipe\n"));
    try expectContains(top.out, "wmux guide | wmux --skill");
    try expectContains(top.out, "CMUX_QUIET=1, WMUX_QUIET=1");
    h.setEnv("WMUX_ARGV0", "wmux");
    const g = h.run(&.{ "cmux.exe", "guide" });
    try testing.expect(std.mem.startsWith(u8, g.out, "# wmux guide\n"));
    const cat = h.run(&.{ "cmux.exe", "list-windows", "--help" });
    try testing.expectEqualStrings("Usage: wmux list-windows\n\nList windows.\n", cat.out);
}

test "unit: cli-probes: guide and --skill print identical text; extra args are usage errors" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const g = h.run(&.{ "cmux", "guide" });
    const s = h.run(&.{ "cmux", "--skill" });
    try testing.expectEqualStrings(g.out, s.out);
    try testing.expectEqualStrings(guide.text, g.out);
    const extra = h.run(&.{ "cmux", "guide", "more" });
    try testing.expectEqual(@as(u8, 2), extra.code);
    try expectContains(extra.err, "Usage: cmux guide | cmux --skill [--json]");
    const js = h.run(&.{ "cmux", "--json", "guide" });
    try expectContains(js.out, "\"format\": \"markdown\"");
}

test "unit: cli-probes: no arguments print the top-level usage" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const r = h.run(&.{"cmux"});
    try testing.expectEqual(@as(u8, 0), r.code);
    var aw: std.Io.Writer.Allocating = .init(h.alloc());
    try help.writeTopLevel(&aw.writer, .cmux);
    try testing.expectEqualStrings(aw.written(), r.out);
}

test "unit: cli-probes: docs errors and json" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const bad = h.run(&.{ "cmux", "docs", "bogus" });
    try testing.expectEqual(@as(u8, 2), bad.code);
    try expectContains(bad.err, "Usage: cmux docs [settings|");
    try testing.expectEqual(@as(u8, 2), h.run(&.{ "cmux", "docs", "a", "b" }).code);
    h.setEnv("WMUX_CONFIG_DIR", "C:\\cfg");
    const s = h.run(&.{ "cmux", "docs", "settings", "--json" });
    try testing.expectEqual(@as(u8, 0), s.code);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, h.alloc(), s.out, .{});
    try testing.expect(std.mem.startsWith(u8, v.object.get("config_files").?.object.get("primary").?.string, "C:\\cfg"));
    const list = h.run(&.{ "cmux", "docs", "--json" });
    _ = try std.json.parseFromSliceLeaky(std.json.Value, h.alloc(), list.out, .{});
}

// ----- socket round trips -----

fn controlHandler(server: *fake.Server, req: fake.Request) fake.Action {
    const m = req.method;
    if (std.mem.eql(u8, m, "system.ping")) return .{ .ok = "{\"pong\":true}" };
    if (std.mem.eql(u8, m, "system.capabilities")) return .{ .ok = "{\"protocol\":\"cmux-socket\",\"version\":2,\"access_mode\":\"cmuxOnly\",\"methods\":[\"system.capabilities\",\"system.identify\",\"system.ping\"]}" };
    if (std.mem.eql(u8, m, "system.identify")) {
        return .{ .ok = std.fmt.allocPrint(server.a, "{{\"app\":\"wmux\",\"version\":\"1.0.0\",\"build\":\"7\",\"focused\":{{\"workspace_id\":\"AAAA\",\"workspace_ref\":\"workspace:1\"}},\"caller\":{s}}}", .{
            if (req.params.object.get("caller")) |_| std.json.Stringify.valueAlloc(server.a, req.params.object.get("caller").?, .{}) catch unreachable else "null",
        }) catch unreachable };
    }
    if (std.mem.eql(u8, m, "surface.list")) return .{ .ok = std.fmt.allocPrint(server.a, "{{\"surfaces\":[{{\"id\":\"S1\",\"ref\":\"surface:1\"}}],\"echo\":{s}}}", .{req.params_json}) catch unreachable };
    if (std.mem.eql(u8, m, "surface.read_selection")) return .{ .ok = std.fmt.allocPrint(server.a, "{{\"echo\":{s}}}", .{req.params_json}) catch unreachable };
    if (std.mem.eql(u8, m, "workspace.select")) return .{ .err = "{\"code\":\"not_found\",\"message\":\"Workspace not found\",\"data\":{\"selector\":\"workspace_id\"},\"reason\":\"no workspace has that ref\",\"action\":\"run cmux list-workspaces\"}" };
    return .{ .err = "{\"code\":\"method_not_found\",\"message\":\"Unknown method\"}" };
}

fn liveHarness(h: *Harness, server: *fake.Server) !void {
    h.init();
    server.* = fake.Server.init(h.alloc());
    server.handler = controlHandler;
    try h.fp.addServer(h.control(), server);
}

test "unit: cli-roundtrip: ping prints PONG and --json the result" {
    var h: Harness = undefined;
    var server: fake.Server = undefined;
    try liveHarness(&h, &server);
    defer h.deinit();
    const r = h.run(&.{ "cmux", "ping" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("PONG\n", r.out);
    try testing.expectEqualStrings("", r.err);
    const j1 = h.run(&.{ "cmux", "--json", "ping" });
    const j2 = h.run(&.{ "cmux", "ping", "--json" });
    try testing.expectEqualStrings("{\n  \"pong\": true\n}\n", j1.out);
    try testing.expectEqualStrings(j1.out, j2.out);
}

test "unit: cli-roundtrip: capability prefix comes from the environment" {
    var h: Harness = undefined;
    var server: fake.Server = undefined;
    try liveHarness(&h, &server);
    defer h.deinit();
    h.setEnv("CMUX_SOCKET_CAPABILITY", "cap-token");
    _ = h.run(&.{ "cmux", "ping" });
    try testing.expectEqualStrings("cap-token", server.requests.items[0].capability.?);
}

test "unit: cli-roundtrip: capabilities prints JSON" {
    var h: Harness = undefined;
    var server: fake.Server = undefined;
    try liveHarness(&h, &server);
    defer h.deinit();
    const r = h.run(&.{ "cmux", "capabilities" });
    try testing.expectEqual(@as(u8, 0), r.code);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, h.alloc(), r.out, .{});
    try testing.expectEqual(@as(i64, 2), v.object.get("version").?.integer);
    try testing.expectEqualStrings("system.capabilities", server.requests.items[0].method);
}

test "unit: cli-roundtrip: identify sends the caller and applies --id-format" {
    var h: Harness = undefined;
    var server: fake.Server = undefined;
    try liveHarness(&h, &server);
    defer h.deinit();
    h.setEnv("CMUX_WORKSPACE_ID", "WS-UUID");
    h.setEnv("CMUX_SURFACE_ID", "SF-UUID");
    const r = h.run(&.{ "cmux", "identify" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("{\"caller\":{\"workspace_id\":\"WS-UUID\",\"surface_id\":\"SF-UUID\"}}", server.requests.items[0].params_json);
    try expectContains(r.out, "\"workspace_ref\": \"workspace:1\"");
    try testing.expect(!contains(r.out, "\"workspace_id\": \"AAAA\""));
    const both = h.run(&.{ "cmux", "identify", "--id-format", "both" });
    try expectContains(both.out, "\"workspace_id\": \"AAAA\"");
}

test "unit: cli-roundtrip: rpc prints the raw result, reads stdin and validates params" {
    var h: Harness = undefined;
    var server: fake.Server = undefined;
    try liveHarness(&h, &server);
    defer h.deinit();
    const ping = h.run(&.{ "cmux", "rpc", "system.ping" });
    try testing.expectEqual(@as(u8, 0), ping.code);
    try testing.expectEqualStrings("{\n  \"pong\": true\n}\n", ping.out);

    h.fp.stdin = "{\"workspace_id\":\"workspace:1\"}\n";
    const listed = h.run(&.{ "cmux", "rpc", "surface.list", "-" });
    try testing.expectEqual(@as(u8, 0), listed.code);
    try expectContains(listed.out, "\"id\": \"S1\"");
    try expectContains(listed.out, "\"workspace_id\": \"workspace:1\"");
    // --id-format given: ids are formatted.
    const refs = h.run(&.{ "cmux", "rpc", "surface.list", "{}", "--id-format", "refs" });
    try testing.expect(!contains(refs.out, "\"id\": \"S1\""));

    for ([_][]const u8{ "[1,2]", "\"str\"", "42", "null" }) |bad| {
        const r = h.run(&.{ "cmux", "rpc", "surface.list", bad });
        try testing.expectEqual(@as(u8, 2), r.code);
        try expectContains(r.err, "rpc params must be a JSON object");
    }
    const invalid = h.run(&.{ "cmux", "rpc", "surface.list", "{oops" });
    try testing.expectEqual(@as(u8, 2), invalid.code);
    try expectContains(invalid.err, "rpc params are not valid JSON");
    const missing = h.run(&.{ "cmux", "rpc" });
    try testing.expectEqual(@as(u8, 2), missing.code);
    try expectContains(missing.err, "Usage: cmux rpc <method> [json-params]");
    try testing.expectEqual(@as(u8, 2), h.run(&.{ "cmux", "rpc", "a", "{}", "c" }).code);
    h.fp.stdin = "";
    const empty_stdin = h.run(&.{ "cmux", "rpc", "system.ping", "-" });
    try testing.expectEqual(@as(u8, 0), empty_stdin.code);
}

test "unit: cli-roundtrip: rpc injects --window for surface.read_selection only" {
    var h: Harness = undefined;
    var server: fake.Server = undefined;
    try liveHarness(&h, &server);
    defer h.deinit();
    const r = h.run(&.{ "cmux", "--window", "window:2", "rpc", "surface.read_selection", "{\"surface_id\":\"S\"}" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("{\"surface_id\":\"S\",\"window_id\":\"window:2\"}", server.requests.items[0].params_json);
    _ = h.run(&.{ "cmux", "--window", "window:2", "rpc", "surface.read_selection", "{\"window_id\":\"keep\"}" });
    try testing.expectEqualStrings("{\"window_id\":\"keep\"}", server.requests.items[1].params_json);
    _ = h.run(&.{ "cmux", "--window", "window:2", "rpc", "surface.list" });
    try testing.expectEqualStrings("{}", server.requests.items[2].params_json);
}

test "unit: cli-roundtrip: error envelope prints code, message, reason and action" {
    var h: Harness = undefined;
    var server: fake.Server = undefined;
    try liveHarness(&h, &server);
    defer h.deinit();
    const r = h.run(&.{ "cmux", "rpc", "workspace.select", "{\"workspace_id\":\"workspace:9\"}" });
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings("", r.out);
    try testing.expectEqualStrings("not_found: Workspace not found\nReason: no workspace has that ref\nWhat to do: run cmux list-workspaces\n", r.err);
}

test "unit: cli-roundtrip: method_not_found adds the version-skew diagnosis" {
    var h: Harness = undefined;
    var server: fake.Server = undefined;
    try liveHarness(&h, &server);
    defer h.deinit();
    const r = h.run(&.{ "cmux", "rpc", "wmux.future.method" });
    try testing.expectEqual(@as(u8, 1), r.code);
    try expectContains(r.err, "method_not_found: Unknown method\nThis CLI: cmux 1.2.3 (456) [abcdef0]\nConnected app: wmux 1.0.0 (7)\nFix: the app does not know 'wmux.future.method'.");
}

test "unit: cli-roundtrip: no live app prints the Tried list and exits 1" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const r = h.run(&.{ "cmux", "ping" });
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings("", r.out);
    try testing.expect(std.mem.startsWith(u8, r.err, "No live wmux socket found. Tried:\n  \\\\.\\pipe\\wmux-stable-"));
    try testing.expectEqual(@as(usize, 0), h.fp.spawned.items.len);
}

fn handlerFor(comptime action: fake.Action) fake.Handler {
    return struct {
        fn f(_: *fake.Server, _: fake.Request) fake.Action {
            return action;
        }
    }.f;
}

test "unit: cli-roundtrip: error mapping for refused, busy, timeout, bad JSON and close" {
    const cases = [_]struct { ?platform_mod.ConnectError, ?fake.Handler, []const u8 }{
        .{ error.NotFound, null, "cmux: " },
        .{ null, null, "cannot connect to \\\\.\\pipe\\explicit: no such pipe (is wmux running?)\n" },
        .{ error.Busy, null, "cannot connect to \\\\.\\pipe\\explicit: busy (all pipe instances in use)\n" },
        .{ error.ForeignOwner, null, "refusing \\\\.\\pipe\\explicit: the pipe server is not owned by the current user\n" },
        .{ error.AccessDenied, null, "cannot connect to \\\\.\\pipe\\explicit: access denied\n" },
        .{ null, handlerFor(.stall), "timed out after 0.25s waiting for a response to system.ping from \\\\.\\pipe\\explicit (set WMUX_CLI_RESPONSE_TIMEOUT_SEC to wait longer)\n" },
        .{ null, handlerFor(.{ .raw = "not json" }), "invalid response from \\\\.\\pipe\\explicit: not a v2 JSON reply\n" },
        .{ null, handlerFor(.close), "connection to \\\\.\\pipe\\explicit closed before a response to system.ping arrived\n" },
        .{ null, handlerFor(.{ .raw = "ERROR: Access denied (cmuxOnly)" }), "ERROR: Access denied (cmuxOnly)\n" },
        .{ null, handlerFor(.{ .ok_wrong_id = "{}" }), "Mismatched v2 response id\n" },
    };
    for (cases, 0..) |c, i| {
        if (i == 0) continue;
        var h: Harness = undefined;
        h.init();
        defer h.deinit();
        h.setEnv("WMUX_CLI_RESPONSE_TIMEOUT_SEC", "0.25");
        var server = fake.Server.init(h.alloc());
        if (c[0]) |e| try h.fp.addFailure("\\\\.\\pipe\\explicit", e);
        if (c[1]) |hd| {
            server.handler = hd;
            try h.fp.addServer("\\\\.\\pipe\\explicit", &server);
        }
        const r = h.run(&.{ "cmux", "--socket", "explicit", "ping" });
        try testing.expectEqual(@as(u8, 1), r.code);
        try testing.expectEqualStrings(c[2], r.err);
    }
}

test "unit: cli-roundtrip: CMUX_SOCKET mismatch fails before connecting; env path is verbatim" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.setEnv("CMUX_SOCKET", "\\\\.\\pipe\\a");
    h.setEnv("CMUX_SOCKET_PATH", "\\\\.\\pipe\\b");
    const r = h.run(&.{ "cmux", "ping" });
    try testing.expectEqual(@as(u8, 1), r.code);
    try expectContains(r.err, "CMUX_SOCKET (\\\\.\\pipe\\a) and CMUX_SOCKET_PATH (\\\\.\\pipe\\b) are both set and differ");
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
    // --socket overrides both.
    var server = fake.Server.init(h.alloc());
    try h.fp.addServer("\\\\.\\pipe\\y", &server);
    try testing.expectEqual(@as(u8, 0), h.run(&.{ "cmux", "--socket", "y", "ping" }).code);
    try testing.expectEqualStrings("\\\\.\\pipe\\y", h.fp.connect_log.items[0]);
}

test "unit: cli-roundtrip: --socket after the command is not global" {
    var h: Harness = undefined;
    var server: fake.Server = undefined;
    try liveHarness(&h, &server);
    defer h.deinit();
    const r = h.run(&.{ "cmux", "ping", "--socket", "/x" });
    try testing.expectEqual(@as(u8, 2), r.code);
    try expectContains(r.err, "unexpected argument '--socket'");
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
}

test "unit: cli-roundtrip: password mode logs in with --password" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    var server = fake.Server.init(h.alloc());
    server.handler = struct {
        fn f(s: *fake.Server, req: fake.Request) fake.Action {
            if (std.mem.eql(u8, req.method, "auth.login")) {
                s.user = @ptrFromInt(1);
                return .{ .ok = "{}" };
            }
            if (s.user == null) return .{ .err = "{\"code\":\"auth_required\",\"message\":\"Authentication required\"}" };
            return .{ .ok = "{\"pong\":true}" };
        }
    }.f;
    try h.fp.addServer(h.control(), &server);
    const r = h.run(&.{ "cmux", "--password", "+s3cret", "ping" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("{\"password\":\"+s3cret\"}", server.requests.items[1].params_json);
}

// ----- legacy verbs, unsupported and unknown commands -----

test "unit: cli-dispatch: legacy +verb prints one notice unless quiet" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const r = h.run(&.{ "wmux", "+workspace", "list" });
    try testing.expect(std.mem.startsWith(u8, r.err, "wmux: '+workspace list' is now an alias for 'list-workspaces'. The legacy form keeps working indefinitely; set CMUX_QUIET=1 to silence this notice.\n"));
    try expectContains(r.err, "'list-workspaces' is not available in this build of wmux yet");
    h.setEnv("WMUX_QUIET", "1");
    const q = h.run(&.{ "wmux", "+workspace", "list" });
    try testing.expect(!contains(q.err, "is now an alias"));
}

test "unit: cli-dispatch: legacy +send reaches send with its text intact" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.setEnv("CMUX_QUIET", "1");
    const r = h.run(&.{ "cmux", "+send", "--version", "--enter" });
    // `send` is not implemented yet; the text was not taken as a version flag.
    try testing.expect(!contains(r.out, "cmux 1.2.3"));
    try expectContains(r.err, "'send' is not available");
}

test "unit: cli-dispatch: Ghostty-native actions relay to wmux.exe without WMUX_ARGV0" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fp.self_exe = try proto.paths.join(h.alloc(), proto.paths.Style.native, &.{ "C:", "wmux", "cli", "cmux.exe" });
    h.fp.run_exit = 3;
    h.setEnv("WMUX_ARGV0", "wmux");
    h.setEnv("WSLENV", "WMUX_ARGV0:X/u");
    const r = h.run(&.{ "cmux", "+list-fonts", "--family", "x" });
    try testing.expectEqual(@as(u8, 3), r.code);
    const ran = h.fp.ran.items[0];
    try testing.expectEqualStrings(try proto.paths.join(h.alloc(), proto.paths.Style.native, &.{ "C:", "wmux", "wmux.exe" }), ran.argv[0]);
    try testing.expectEqualStrings("+list-fonts", ran.argv[1]);
    try testing.expectEqualStrings("x", ran.argv[3]);
    try testing.expect(!ran.had_argv0);
    try testing.expectEqualStrings("X/u", ran.wslenv.?);
    h.fp.self_exe = null;
    try testing.expectEqual(@as(u8, 1), h.run(&.{ "cmux", "+ssh", "host" }).code);
}

test "unit: cli-dispatch: unknown legacy verbs and subcommands are usage errors" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const r = h.run(&.{ "cmux", "+frobnicate" });
    try testing.expectEqual(@as(u8, 2), r.code);
    try expectContains(r.err, "unknown legacy action '+frobnicate'");
    try testing.expectEqual(@as(u8, 2), h.run(&.{ "cmux", "+tab" }).code);
}

test "unit: cli-dispatch: cloud and macOS commands are not supported" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    for ([_][]const []const u8{ &.{"vm"}, &.{ "cloud", "--help" }, &.{ "agent", "claude", "fix it" }, &.{ "session", "move", "x" }, &.{"auth"}, &.{"feedback"} }) |a| {
        const argv = try std.mem.concat(h.alloc(), []const u8, &.{ &.{"cmux"}, a });
        const r = h.run(argv);
        try testing.expectEqual(@as(u8, 2), r.code);
        try expectContains(r.err, "not supported on wmux (requires cmux cloud/macOS)");
    }
    // `agent message` is a real (not yet implemented) command.
    try expectContains(h.run(&.{ "cmux", "agent", "message", "--help" }).out, "Usage: cmux agent message");
}

test "unit: cli-dispatch: unknown commands and global option errors exit 2" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const r = h.run(&.{ "cmux", "frobnicate" });
    try testing.expectEqual(@as(u8, 2), r.code);
    try testing.expectEqualStrings("cmux: unknown command 'frobnicate'. Run 'cmux help' for usage.\n", r.err);
    const idf = h.run(&.{ "cmux", "ping", "--id-format", "ids" });
    try testing.expectEqual(@as(u8, 2), idf.code);
    try testing.expectEqualStrings("cmux: --id-format must be one of: refs, uuids, both\n", idf.err);
    try testing.expectEqual(@as(u8, 2), h.run(&.{ "cmux", "--bogus" }).code);
}

test "unit: cli-dispatch: wmux namespace lists its subcommands" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const r = h.run(&.{ "cmux", "wmux" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try expectContains(r.out, "Usage: cmux wmux <subcommand> [args]");
    const u = h.run(&.{ "cmux", "wmux", "attention", "ring" });
    try testing.expectEqual(@as(u8, 2), u.code);
    try expectContains(u.err, "unknown wmux subcommand 'attention'");
}

test "unit: cli-dispatch: cmux <path> opens an existing path over the launch pipe" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try h.fp.addFile("C:\\work\\README.md", "");
    h.fp.cwd_path = "C:\\work";
    var server = fake.Server.init(h.alloc());
    server.handler = struct {
        fn f(_: *fake.Server, _: fake.Request) fake.Action {
            return .{ .ok = "{}" };
        }
    }.f;
    try h.fp.addServer(try proto.pipe_name.launchName(h.alloc(), h.control()), &server);
    const r = h.run(&.{ "cmux", "C:\\work\\README.md" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("app.launch", server.requests.items[0].method);
    try testing.expectEqualStrings("C:\\work\\README.md", server.requests.items[0].params.object.get("paths").?.array.items[0].string);
}

test "unit: cli-dispatch: shims report that they are not available yet" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try testing.expectEqual(@as(u8, 1), h.run(&.{ "C:\\shims\\tmux.exe", "ls" }).code);
    try testing.expectEqual(@as(u8, 1), h.run(&.{"claude"}).code);
}

test "unit: cli-dispatch: every registered command has usage and help" {
    for (main.all_commands) |c| {
        try testing.expect(std.mem.startsWith(u8, c.usage, "Usage: cmux "));
        try testing.expect(std.mem.startsWith(u8, c.help, c.usage));
        // Registered commands are also catalogued so help lists them.
        if (!c.hidden) try testing.expect(help.findCatalog(c.name, null) != null);
    }
}
