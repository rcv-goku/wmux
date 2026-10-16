//! CLI command family `legacy_plus` (Appendix C).
//! Legacy wmux `+verb` mapping table of ADR-4.11. Owner: W1-2.
//!
//! A `+verb` at argv[1] is rewritten to its cmux command and dispatched
//! through the normal grammar, after a one-line stderr notice (suppressed by
//! `WMUX_QUIET`/`CMUX_QUIET`). Ghostty-native actions, `+ssh` (until W6) and
//! `+hooks` other than `setup` (until W3) are relayed to `..\wmux.exe` with
//! inherited handles and their exit code is propagated. No new `+verbs` are
//! ever added (G8). Old flag spellings (`--workspace I`, `--pane P`,
//! `--tab T`) pass through to the new commands unchanged.

const std = @import("std");
const Allocator = std.mem.Allocator;
const CommandSpec = @import("../command.zig").CommandSpec;

/// No top-level commands; dispatch calls `map` for `+verb` argv.
pub const commands = [_]CommandSpec{};

pub const Sub = struct { name: []const u8, to: []const []const u8 };

pub const Rule = struct {
    verb: []const u8,
    /// Replacement argv prefix when the verb takes no subcommand.
    to: ?[]const []const u8 = null,
    /// Subcommand table (the sub is consumed).
    subs: []const Sub = &.{},
    /// Relay subcommands not in `subs` to `wmux.exe` instead of failing.
    relay_other_subs: bool = false,
    /// Relay the whole verb to `wmux.exe`.
    relay: bool = false,
    /// `+send --enter`: append a carriage return to the text.
    enter_flag: bool = false,
};

pub const rules = [_]Rule{
    .{ .verb = "workspace", .subs = &.{
        .{ .name = "list", .to = &.{"list-workspaces"} },
        .{ .name = "new", .to = &.{"new-workspace"} },
        .{ .name = "select", .to = &.{"select-workspace"} },
        .{ .name = "close", .to = &.{"close-workspace"} },
    } },
    .{ .verb = "tab", .subs = &.{
        .{ .name = "list", .to = &.{"list-pane-surfaces"} },
        .{ .name = "new", .to = &.{"new-surface"} },
        .{ .name = "select", .to = &.{"focus-panel"} },
        .{ .name = "close", .to = &.{"close-surface"} },
    } },
    .{ .verb = "surface", .subs = &.{
        .{ .name = "list", .to = &.{"list-panels"} },
        .{ .name = "focus", .to = &.{"focus-panel"} },
    } },
    .{ .verb = "split", .to = &.{"new-split"} },
    .{ .verb = "send", .to = &.{"send"}, .enter_flag = true },
    .{ .verb = "notify", .subs = &.{
        .{ .name = "ring", .to = &.{ "wmux", "attention", "ring" } },
        .{ .name = "clear", .to = &.{ "wmux", "attention", "clear" } },
        .{ .name = "next", .to = &.{"jump-to-unread"} },
        .{ .name = "toggle-read", .to = &.{ "wmux", "notification", "toggle-unread" } },
        .{ .name = "mark-oldest-next", .to = &.{ "wmux", "notification", "mark-oldest-jump" } },
    } },
    .{ .verb = "status", .subs = &.{
        .{ .name = "set", .to = &.{"set-status"} },
        .{ .name = "progress", .to = &.{"set-progress"} },
    } },
    .{ .verb = "log", .to = &.{"log"} },
    .{ .verb = "read-screen", .to = &.{"read-screen"} },
    .{ .verb = "capture-pane", .to = &.{"capture-pane"} },
    .{ .verb = "browser", .to = &.{"browser"} },
    .{ .verb = "session", .subs = &.{
        .{ .name = "capture", .to = &.{ "surface-resume", "set" } },
        .{ .name = "resume", .to = &.{ "wmux", "session", "resume" } },
        .{ .name = "show", .to = &.{"sessions"} },
        .{ .name = "save", .to = &.{ "wmux", "session", "save" } },
        .{ .name = "restore", .to = &.{"restore-session"} },
    } },
    .{ .verb = "hooks", .subs = &.{.{ .name = "setup", .to = &.{ "hooks", "setup" } }}, .relay_other_subs = true },
    .{ .verb = "ssh", .relay = true },
    .{ .verb = "new-window", .to = &.{"new-window"} },
    .{ .verb = "toggle-quick-terminal", .to = &.{ "wmux", "quick-terminal", "toggle" } },
};

/// Ghostty-native actions relayed to `wmux.exe` (ADR-4.3 step 2).
pub const ghostty_actions = [_][]const u8{
    "version",      "help",            "list-fonts",     "list-themes",
    "list-colors",  "list-actions",    "list-keybinds",  "show-config",
    "show-face",    "validate-config", "explain-config", "edit-config",
    "crash-report", "boo",
};

pub const Mapped = union(enum) {
    /// Dispatch `argv` (without argv[0]) through the grammar after the
    /// notice `'<legacy>' is now an alias for '<new>'`.
    rewrite: struct { argv: []const []const u8, legacy: []const u8, new: []const u8 },
    /// Run `wmux.exe` with the original arguments.
    relay,
    /// Usage error (message).
    usage: []const u8,
};

/// Flags whose next token is a value (so it is not the `+send` text).
const value_flags = [_][]const u8{ "--workspace", "--surface", "--pane", "--tab", "--window", "--panel" };

fn isValueFlag(a: []const u8) bool {
    for (value_flags) |f| if (std.mem.eql(u8, a, f)) return true;
    return false;
}

/// `+send ... --enter`: drop `--enter` and append `\r` to the text (the last
/// positional argument), or add `\r` as the text when there is none.
fn applyEnter(arena: Allocator, rest: []const []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var enter = false;
    var text_index: ?usize = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--")) {
            // Everything after `--` is text.
            for (rest[i..]) |x| try out.append(arena, x);
            if (rest.len > i + 1) text_index = out.items.len - 1;
            break;
        }
        if (std.mem.eql(u8, a, "--enter")) {
            enter = true;
            continue;
        }
        try out.append(arena, a);
        if (isValueFlag(a) and i + 1 < rest.len) {
            i += 1;
            try out.append(arena, rest[i]);
        } else if (!std.mem.startsWith(u8, a, "--")) text_index = out.items.len - 1;
    }
    if (enter) {
        if (text_index) |t| {
            out.items[t] = try std.mem.concat(arena, u8, &.{ out.items[t], "\r" });
        } else try out.append(arena, "\r");
    }
    return out.items;
}

fn joinWords(arena: Allocator, words: []const []const u8) Allocator.Error![]const u8 {
    return std.mem.join(arena, " ", words);
}

/// Maps `argv` (starting with the `+verb`, without argv[0]).
pub fn map(arena: Allocator, argv: []const []const u8) Allocator.Error!Mapped {
    std.debug.assert(argv.len > 0 and argv[0].len > 0 and argv[0][0] == '+');
    const verb = argv[0][1..];
    for (ghostty_actions) |g| if (std.mem.eql(u8, g, verb)) return .relay;
    const rule = for (&rules) |*r| {
        if (std.mem.eql(u8, r.verb, verb)) break r;
    } else return .{ .usage = try std.fmt.allocPrint(arena, "unknown legacy action '{s}'; run 'cmux help' for the cmux commands", .{argv[0]}) };
    if (rule.relay) return .relay;

    var prefix: []const []const u8 = undefined;
    var consumed: usize = 1;
    var legacy_words: []const []const u8 = argv[0..1];
    if (rule.to) |t| {
        prefix = t;
    } else {
        const sub = if (argv.len > 1) argv[1] else {
            return .{ .usage = try std.fmt.allocPrint(arena, "{s} needs a subcommand: {s}", .{ argv[0], try subList(arena, rule) }) };
        };
        const found = for (rule.subs) |s| {
            if (std.mem.eql(u8, s.name, sub)) break s;
        } else {
            if (rule.relay_other_subs) return .relay;
            return .{ .usage = try std.fmt.allocPrint(arena, "unknown subcommand '{s} {s}'; expected one of: {s}", .{ argv[0], sub, try subList(arena, rule) }) };
        };
        prefix = found.to;
        consumed = 2;
        legacy_words = argv[0..2];
    }
    const rest = if (rule.enter_flag) try applyEnter(arena, argv[consumed..]) else argv[consumed..];
    const out = try std.mem.concat(arena, []const u8, &.{ prefix, rest });
    return .{ .rewrite = .{ .argv = out, .legacy = try joinWords(arena, legacy_words), .new = try joinWords(arena, prefix) } };
}

fn subList(arena: Allocator, rule: *const Rule) Allocator.Error![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (rule.subs) |s| try names.append(arena, s.name);
    return std.mem.join(arena, ", ", names.items);
}

const testing = std.testing;

fn expectRewrite(argv: []const []const u8, want: []const []const u8, legacy: []const u8, new: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const m = try map(arena_state.allocator(), argv);
    try testing.expectEqualStrings(legacy, m.rewrite.legacy);
    try testing.expectEqualStrings(new, m.rewrite.new);
    try testing.expectEqual(want.len, m.rewrite.argv.len);
    for (want, m.rewrite.argv) |w, g| try testing.expectEqualStrings(w, g);
}

test "unit: cli-legacy-plus: every ADR-4.11 row maps to its cmux command" {
    try expectRewrite(&.{ "+workspace", "list" }, &.{"list-workspaces"}, "+workspace list", "list-workspaces");
    try expectRewrite(&.{ "+workspace", "new", "--worktree", "x" }, &.{ "new-workspace", "--worktree", "x" }, "+workspace new", "new-workspace");
    try expectRewrite(&.{ "+workspace", "select", "--workspace", "2" }, &.{ "select-workspace", "--workspace", "2" }, "+workspace select", "select-workspace");
    try expectRewrite(&.{ "+workspace", "close" }, &.{"close-workspace"}, "+workspace close", "close-workspace");
    try expectRewrite(&.{ "+tab", "list" }, &.{"list-pane-surfaces"}, "+tab list", "list-pane-surfaces");
    try expectRewrite(&.{ "+tab", "new" }, &.{"new-surface"}, "+tab new", "new-surface");
    try expectRewrite(&.{ "+tab", "select", "--tab", "3" }, &.{ "focus-panel", "--tab", "3" }, "+tab select", "focus-panel");
    try expectRewrite(&.{ "+tab", "close" }, &.{"close-surface"}, "+tab close", "close-surface");
    try expectRewrite(&.{ "+surface", "list" }, &.{"list-panels"}, "+surface list", "list-panels");
    try expectRewrite(&.{ "+surface", "focus" }, &.{"focus-panel"}, "+surface focus", "focus-panel");
    try expectRewrite(&.{ "+split", "right" }, &.{ "new-split", "right" }, "+split", "new-split");
    try expectRewrite(&.{ "+notify", "ring" }, &.{ "wmux", "attention", "ring" }, "+notify ring", "wmux attention ring");
    try expectRewrite(&.{ "+notify", "clear" }, &.{ "wmux", "attention", "clear" }, "+notify clear", "wmux attention clear");
    try expectRewrite(&.{ "+notify", "next" }, &.{"jump-to-unread"}, "+notify next", "jump-to-unread");
    try expectRewrite(&.{ "+notify", "toggle-read" }, &.{ "wmux", "notification", "toggle-unread" }, "+notify toggle-read", "wmux notification toggle-unread");
    try expectRewrite(&.{ "+notify", "mark-oldest-next" }, &.{ "wmux", "notification", "mark-oldest-jump" }, "+notify mark-oldest-next", "wmux notification mark-oldest-jump");
    try expectRewrite(&.{ "+status", "set", "build", "ok" }, &.{ "set-status", "build", "ok" }, "+status set", "set-status");
    try expectRewrite(&.{ "+status", "progress", "0.5" }, &.{ "set-progress", "0.5" }, "+status progress", "set-progress");
    try expectRewrite(&.{ "+log", "hello" }, &.{ "log", "hello" }, "+log", "log");
    try expectRewrite(&.{"+read-screen"}, &.{"read-screen"}, "+read-screen", "read-screen");
    try expectRewrite(&.{ "+capture-pane", "--lines", "5" }, &.{ "capture-pane", "--lines", "5" }, "+capture-pane", "capture-pane");
    try expectRewrite(&.{ "+browser", "open", "https://x.example" }, &.{ "browser", "open", "https://x.example" }, "+browser", "browser");
    try expectRewrite(&.{ "+session", "capture" }, &.{ "surface-resume", "set" }, "+session capture", "surface-resume set");
    try expectRewrite(&.{ "+session", "resume" }, &.{ "wmux", "session", "resume" }, "+session resume", "wmux session resume");
    try expectRewrite(&.{ "+session", "show" }, &.{"sessions"}, "+session show", "sessions");
    try expectRewrite(&.{ "+session", "save" }, &.{ "wmux", "session", "save" }, "+session save", "wmux session save");
    try expectRewrite(&.{ "+session", "restore" }, &.{"restore-session"}, "+session restore", "restore-session");
    try expectRewrite(&.{ "+hooks", "setup" }, &.{ "hooks", "setup" }, "+hooks setup", "hooks setup");
    try expectRewrite(&.{"+new-window"}, &.{"new-window"}, "+new-window", "new-window");
    try expectRewrite(&.{"+toggle-quick-terminal"}, &.{ "wmux", "quick-terminal", "toggle" }, "+toggle-quick-terminal", "wmux quick-terminal toggle");
}

test "unit: cli-legacy-plus: send --enter appends a carriage return to the text" {
    try expectRewrite(&.{ "+send", "ls", "--enter" }, &.{ "send", "ls\r" }, "+send", "send");
    try expectRewrite(&.{ "+send", "--enter", "--surface", "surface:2", "echo hi" }, &.{ "send", "--surface", "surface:2", "echo hi\r" }, "+send", "send");
    try expectRewrite(&.{ "+send", "--enter" }, &.{ "send", "\r" }, "+send", "send");
    try expectRewrite(&.{ "+send", "--enter", "--", "--help" }, &.{ "send", "--", "--help\r" }, "+send", "send");
    try expectRewrite(&.{ "+send", "+workspace", "--version" }, &.{ "send", "+workspace", "--version" }, "+send", "send");
    try expectRewrite(&.{ "+send", "h\u{e9}llo \u{1F600}", "--enter" }, &.{ "send", "h\u{e9}llo \u{1F600}\r" }, "+send", "send");
}

test "unit: cli-legacy-plus: relays and usage errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (ghostty_actions) |g| {
        const v = try std.fmt.allocPrint(a, "+{s}", .{g});
        try testing.expect((try map(a, &.{ v, "--x" })) == .relay);
    }
    try testing.expect((try map(a, &.{"+ssh"})) == .relay);
    try testing.expect((try map(a, &.{ "+hooks", "claude" })) == .relay);
    try testing.expectEqualStrings("+workspace needs a subcommand: list, new, select, close", (try map(a, &.{"+workspace"})).usage);
    try testing.expectEqualStrings("unknown subcommand '+tab rename'; expected one of: list, new, select, close", (try map(a, &.{ "+tab", "rename" })).usage);
    try testing.expectEqualStrings("unknown legacy action '+frobnicate'; run 'cmux help' for the cmux commands", (try map(a, &.{"+frobnicate"})).usage);
    try testing.expect((try map(a, &.{"+"})) == .usage);
}
