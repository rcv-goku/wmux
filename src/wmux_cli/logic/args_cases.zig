//! Table of cmux grammar cases (ADR-4.4, cli-global-options,
//! cli-id-format-output, cli-no-socket-help-probes): global options only
//! before the command, presentation options anywhere before `--`, the `--`
//! terminator, `+` values and `--version`/`--help` as payload, command
//! position flags and the usage errors with cmux's wording. Wired from the
//! test block of args.zig.

const std = @import("std");
const proto = @import("wmux_proto");
const idformat = proto.idformat;
const args = @import("../args.zig");
const CommandFlag = args.CommandFlag;

pub const Case = struct {
    argv: []const []const u8,
    command: ?[]const u8 = null,
    flag: ?CommandFlag = null,
    args: []const []const u8 = &.{},
    payload: []const []const u8 = &.{},
    help: bool = false,
    json: bool = false,
    id_format: idformat.Mode = .refs,
    id_explicit: bool = false,
    socket: ?[]const u8 = null,
    password: ?[]const u8 = null,
    window: ?[]const u8 = null,
    /// Expected usage error text; the other fields are ignored.
    usage: ?[]const u8 = null,
};

const id_msg = "--id-format must be one of: refs, uuids, both";

// zig fmt: off
pub const cases = [_]Case{
    // Presentation options before or after the command (acceptance a).
    .{ .argv = &.{ "--json", "list-workspaces" }, .command = "list-workspaces", .json = true },
    .{ .argv = &.{ "list-workspaces", "--json" }, .command = "list-workspaces", .json = true },
    .{ .argv = &.{ "list-workspaces", "--id-format", "both" }, .command = "list-workspaces", .id_format = .both, .id_explicit = true },
    .{ .argv = &.{ "--id-format", "uuids", "list-workspaces" }, .command = "list-workspaces", .id_format = .uuids, .id_explicit = true },
    .{ .argv = &.{ "list-workspaces", "--id-format=refs" }, .command = "list-workspaces", .id_format = .refs, .id_explicit = true },
    .{ .argv = &.{ "--id-format=both", "--json", "tree", "--all" }, .command = "tree", .args = &.{"--all"}, .json = true, .id_format = .both, .id_explicit = true },
    .{ .argv = &.{ "tree", "--id-format", "uuids", "--id-format", "both" }, .command = "tree", .id_format = .both, .id_explicit = true },
    .{ .argv = &.{ "--json", "--json", "ping", "--json" }, .command = "ping", .json = true },
    .{ .argv = &.{ "rpc", "system.ping" }, .command = "rpc", .args = &.{"system.ping"} },
    // Global options only before the command (acceptance b).
    .{ .argv = &.{ "--socket", "\\\\.\\pipe\\wmux-x", "ping" }, .command = "ping", .socket = "\\\\.\\pipe\\wmux-x" },
    .{ .argv = &.{ "--socket=wmux-x", "ping" }, .command = "ping", .socket = "wmux-x" },
    .{ .argv = &.{ "--password", "pw", "--window", "window:2", "list-workspaces" }, .command = "list-workspaces", .password = "pw", .window = "window:2" },
    .{ .argv = &.{ "--window=0", "--json", "current-workspace" }, .command = "current-workspace", .window = "0", .json = true },
    .{ .argv = &.{ "--window", "9B69E0A4-0000-4000-8000-000000000001", "tree" }, .command = "tree", .window = "9B69E0A4-0000-4000-8000-000000000001" },
    .{ .argv = &.{ "list-workspaces", "--socket", "/x" }, .command = "list-workspaces", .args = &.{ "--socket", "/x" } },
    .{ .argv = &.{ "list-workspaces", "--window", "1" }, .command = "list-workspaces", .args = &.{ "--window", "1" } },
    .{ .argv = &.{ "send", "--password", "p", "hi" }, .command = "send", .args = &.{ "--password", "p", "hi" } },
    .{ .argv = &.{ "--password", "--json", "ping" }, .command = "ping", .password = "--json" },
    .{ .argv = &.{ "--socket", "a", "--socket", "b", "ping" }, .command = "ping", .socket = "b" },
    .{ .argv = &.{ "--password=", "ping" }, .command = "ping", .password = "" },
    // `--` terminator: payload is untouched (negative help probes).
    .{ .argv = &.{ "send", "--", "--version" }, .command = "send", .args = &.{ "--", "--version" }, .payload = &.{"--version"} },
    .{ .argv = &.{ "send", "--", "--help" }, .command = "send", .args = &.{ "--", "--help" }, .payload = &.{"--help"} },
    .{ .argv = &.{ "send", "--surface", "surface:1", "--", "-h", "--json" }, .command = "send", .args = &.{ "--surface", "surface:1", "--", "-h", "--json" }, .payload = &.{ "-h", "--json" } },
    .{ .argv = &.{ "rpc", "x", "--", "--id-format", "bogus" }, .command = "rpc", .args = &.{ "x", "--", "--id-format", "bogus" }, .payload = &.{ "--id-format", "bogus" } },
    .{ .argv = &.{ "surface-resume", "set", "--", "claude", "--", "--resume" }, .command = "surface-resume", .args = &.{ "set", "--", "claude", "--", "--resume" }, .payload = &.{ "claude", "--", "--resume" } },
    .{ .argv = &.{ "send", "--" }, .command = "send", .args = &.{"--"} },
    .{ .argv = &.{ "--", "send", "x" }, .command = "send", .args = &.{"x"} },
    .{ .argv = &.{ "--", "--help" }, .command = "--help" },
    // `+` values and version text after the command are ordinary.
    .{ .argv = &.{ "send", "+workspace" }, .command = "send", .args = &.{"+workspace"} },
    .{ .argv = &.{ "send", "--version" }, .command = "send", .args = &.{"--version"} },
    .{ .argv = &.{ "send", "-v", "+" }, .command = "send", .args = &.{ "-v", "+" } },
    .{ .argv = &.{ "--password", "+secret", "ping" }, .command = "ping", .password = "+secret" },
    .{ .argv = &.{ "send", "--skill" }, .command = "send", .args = &.{"--skill"} },
    .{ .argv = &.{ "set-status", "k", "\u{1F600} h\u{e9}llo" }, .command = "set-status", .args = &.{ "k", "\u{1F600} h\u{e9}llo" } },
    // Help requests.
    .{ .argv = &.{ "ping", "--help" }, .command = "ping", .args = &.{"--help"}, .help = true },
    .{ .argv = &.{ "ping", "-h" }, .command = "ping", .args = &.{"-h"}, .help = true },
    .{ .argv = &.{ "browser", "open", "--help" }, .command = "browser", .args = &.{ "open", "--help" }, .help = true },
    .{ .argv = &.{ "help", "agents" }, .command = "help", .args = &.{"agents"} },
    .{ .argv = &.{ "rpc", "--helpful" }, .command = "rpc", .args = &.{"--helpful"} },
    .{ .argv = &.{ "version", "--help" }, .command = "version", .args = &.{"--help"}, .help = true },
    // Command-position flags.
    .{ .argv = &.{"--help"}, .command = "--help", .flag = .help },
    .{ .argv = &.{"-h"}, .command = "-h", .flag = .help },
    .{ .argv = &.{"--version"}, .command = "--version", .flag = .version },
    .{ .argv = &.{ "--json", "-v" }, .command = "-v", .flag = .version, .json = true },
    .{ .argv = &.{"--skill"}, .command = "--skill", .flag = .skill },
    .{ .argv = &.{ "--skill", "-h" }, .command = "--skill", .flag = .skill, .args = &.{"-h"}, .help = true },
    .{ .argv = &.{ "--skill", "extra" }, .command = "--skill", .flag = .skill, .args = &.{"extra"} },
    .{ .argv = &.{ "--socket", "x", "--version" }, .command = "--version", .flag = .version, .socket = "x" },
    .{ .argv = &.{} },
    .{ .argv = &.{"--json"}, .json = true },
    // Usage errors (exit 2) with cmux's wording.
    .{ .argv = &.{ "--id-format", "ids", "ping" }, .usage = id_msg },
    .{ .argv = &.{ "ping", "--id-format", "REFS" }, .usage = id_msg },
    .{ .argv = &.{ "ping", "--id-format" }, .usage = id_msg },
    .{ .argv = &.{ "--id-format=", "ping" }, .usage = id_msg },
    .{ .argv = &.{"--socket"}, .usage = "--socket requires a value" },
    .{ .argv = &.{ "--json", "--password" }, .usage = "--password requires a value" },
    .{ .argv = &.{"--window"}, .usage = "--window requires a value" },
    .{ .argv = &.{ "--frobnicate", "ping" }, .usage = "unknown global option '--frobnicate'" },
    .{ .argv = &.{ "-x", "ping" }, .usage = "unknown global option '-x'" },
    .{ .argv = &.{ "--json=true", "ping" }, .usage = "unknown global option '--json=true'" },
};
// zig fmt: on

const testing = std.testing;

fn eqlOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn eqlList(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn check(c: Case) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: args.Diag = .{};
    const result = args.parse(arena_state.allocator(), c.argv, &diag);
    if (c.usage) |want| {
        try testing.expectError(error.Usage, result);
        try testing.expectEqualStrings(want, diag.message);
        return;
    }
    const p = try result;
    const g = p.globals;
    const ok = eqlOpt(c.command, p.command) and c.flag == p.command_flag and
        eqlList(c.args, p.args) and eqlList(c.payload, p.payload()) and
        c.help == p.help_requested and c.json == g.json and
        c.id_format == g.id_format and c.id_explicit == g.id_format_explicit and
        eqlOpt(c.socket, g.socket) and eqlOpt(c.password, g.password) and eqlOpt(c.window, g.window);
    if (!ok) {
        std.debug.print("\nargs case failed: {any}\n  got command={?s} flag={?} args={any} help={} json={} id={}/{}\n", .{
            c.argv, p.command, p.command_flag, p.args, p.help_requested, g.json, g.id_format, g.id_format_explicit,
        });
        return error.TestUnexpectedResult;
    }
}

test "unit: cli: args cases table" {
    try testing.expect(cases.len >= 40);
    for (cases) |c| try check(c);
}

test "unit: cli: args cases table covers the WP acceptance lines" {
    const required = [_][]const []const u8{
        &.{ "send", "--", "--version" },
        &.{ "--json", "list-workspaces" },
        &.{ "list-workspaces", "--id-format", "both" },
    };
    for (required) |r| {
        var found = false;
        for (cases) |c| found = found or eqlList(r, c.argv);
        try testing.expect(found);
    }
}

test "unit: cli: args json before and after the command parse identically" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: args.Diag = .{};
    const forms = [_][]const []const u8{
        &.{ "--json", "--id-format", "both", "list-workspaces", "--window", "1" },
        &.{ "list-workspaces", "--json", "--window", "1", "--id-format", "both" },
        &.{ "--id-format=both", "list-workspaces", "--window", "1", "--json" },
    };
    const first = try args.parse(a, forms[0], &d);
    for (forms[1..]) |f| {
        const p = try args.parse(a, f, &d);
        try testing.expectEqualStrings(first.command.?, p.command.?);
        try testing.expect(eqlList(first.args, p.args));
        try testing.expectEqual(first.globals.json, p.globals.json);
        try testing.expectEqual(first.globals.id_format, p.globals.id_format);
    }
}
