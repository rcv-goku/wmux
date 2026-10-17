//! Offline help (ADR-4.4, ADR-4.8, cli-help-command-topics,
//! cli-no-socket-help-probes). `cmux help`, `--help` and `-h` print the
//! top-level usage: every command once under the cmux task groups.
//! `cmux help <topic>` prints one group; an unknown topic or more than one
//! argument prints the top-level usage (exit 0). Per-command `--help` comes
//! from the command's `CommandSpec`, else from the catalog of known cmux
//! commands. Text is authored with the `cmux` spelling and rebranded at
//! output (brand.zig).

const std = @import("std");
const Writer = std.Io.Writer;
const command = @import("command.zig");
const Group = command.Group;
const brand_mod = @import("brand.zig");
const Brand = brand_mod.Brand;
pub const catalog = @import("help/catalog.zig");

pub const topics = [_]struct { name: []const u8, group: Group, text: []const u8 }{
    .{ .name = "start", .group = .start, .text = @embedFile("help/start.txt") },
    .{ .name = "agents", .group = .agents, .text = @embedFile("help/agents.txt") },
    .{ .name = "navigate", .group = .navigate, .text = @embedFile("help/navigate.txt") },
    .{ .name = "inspect", .group = .inspect, .text = @embedFile("help/inspect.txt") },
    .{ .name = "customize", .group = .customize, .text = @embedFile("help/customize.txt") },
    .{ .name = "automation", .group = .automation, .text = @embedFile("help/automation.txt") },
    .{ .name = "browser", .group = .browser, .text = @embedFile("help/browser.txt") },
    .{ .name = "remote", .group = .remote, .text = @embedFile("help/remote.txt") },
    .{ .name = "diagnostics", .group = .diagnostics, .text = @embedFile("help/diagnostics.txt") },
};

const head =
    \\cmux - control cmux via named pipe
    \\
    \\Usage: cmux [--socket <pipe>] [--password <pw>] [--window <id|ref|index>] <command> [options] [--json] [--id-format refs|uuids|both] [--] [args]
    \\       cmux <path>
    \\
    \\
;

const tail =
    \\
    \\Global options (before the command):
    \\  --socket <pipe>                             Control pipe for this invocation (\\.\pipe\<name> or <name>)
    \\  --password <value>                          Socket password (takes precedence over CMUX_SOCKET_PASSWORD)
    \\  --window <id|ref|index>                     Route the command through one window
    \\
    \\Presentation options (before or after the command):
    \\  --json                                      Machine-readable output where supported
    \\  --id-format <refs|uuids|both>               Handle format in JSON and text output (default: refs)
    \\  --                                          Pass everything after it through untouched
    \\
    \\Environment:
    \\  CMUX_SOCKET_PATH, WMUX_SOCKET_PATH          Control pipe override (CMUX_SOCKET is a deprecated alias)
    \\  CMUX_SOCKET_PASSWORD, WMUX_SOCKET_PASSWORD  Password fallback when --password is absent
    \\  CMUX_WORKSPACE_ID, CMUX_SURFACE_ID          Default targets inside wmux terminals
    \\  CMUX_QUIET=1, WMUX_QUIET=1                  Silence legacy-alias notices
    \\
    \\More help:
    \\  cmux help <start|agents|navigate|inspect|customize|automation|browser|remote|diagnostics>
    \\  cmux <command> --help
    \\  cmux guide | cmux --skill
    \\
;

/// The full top-level usage.
pub fn writeTopLevel(w: *Writer, brand: Brand) Writer.Error!void {
    try brand_mod.write(w, brand, head);
    for (topics, 0..) |t, i| {
        if (i > 0) try w.writeByte('\n');
        try brand_mod.write(w, brand, t.text);
    }
    try brand_mod.write(w, brand, tail);
}

pub fn topicByName(name: []const u8) ?usize {
    for (topics, 0..) |t, i| if (std.mem.eql(u8, t.name, name)) return i;
    return null;
}

/// `help [topic]`: exactly one known topic prints that group; anything else
/// prints the top-level usage.
pub fn writeHelpCommand(w: *Writer, brand: Brand, args: []const []const u8) Writer.Error!void {
    if (args.len == 1) {
        if (topicByName(args[0])) |i| return brand_mod.write(w, brand, topics[i].text);
    }
    return writeTopLevel(w, brand);
}

/// Alternate spellings resolved before catalog lookup.
pub const aliases = [_]struct { []const u8, []const u8 }{
    .{ "rename-window", "rename-workspace" },
    .{ "detach-tab", "move-tab-to-new-workspace" },
    .{ "screenshot", "shot" },
    .{ "surface resume", "surface-resume" },
    .{ "surface", "surface-resume" },
};

pub fn canonical(name: []const u8) []const u8 {
    for (aliases) |a| if (std.mem.eql(u8, a[0], name)) return a[1];
    return name;
}

/// Catalog entry for `name`, trying `name sub` first (two-word commands
/// such as `agent message`, `session restore`, `tmux attach`).
pub fn findCatalog(name: []const u8, sub: ?[]const u8) ?*const catalog.Entry {
    if (sub) |s| {
        var buf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s} {s}", .{ name, s })) |two| {
            const c = canonical(two);
            for (&catalog.entries) |*e| if (std.mem.eql(u8, e.name, c)) return e;
        } else |_| {}
    }
    const c = canonical(name);
    for (&catalog.entries) |*e| if (std.mem.eql(u8, e.name, c)) return e;
    return null;
}

/// `--help` text for a catalog entry: usage, blank line, summary.
pub fn writeCatalogHelp(w: *Writer, brand: Brand, e: *const catalog.Entry) Writer.Error!void {
    try brand_mod.write(w, brand, e.usage);
    try w.writeAll("\n\n");
    try brand_mod.write(w, brand, e.summary);
    try w.writeAll(".\n");
}

const testing = std.testing;

test {
    _ = @import("help/conformance_tests.zig");
}

fn topLevelAlloc(brand: Brand) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try writeTopLevel(&aw.writer, brand);
    return aw.toOwnedSlice();
}

test "unit: cli-help: top-level usage carries the contract probe strings" {
    const text = try topLevelAlloc(.cmux);
    defer testing.allocator.free(text);
    const probes = [_][]const u8{
        "cmux - control cmux via named pipe",
        "open <path-or-url>...",
        "sessions [list] [options]",
        "session restore [--list] [--session <id>]...",
        "Start & Resume:",
        "Diagnostics / Advanced:",
        "socket-status [--json]",
        "cmux help <start|agents|navigate|inspect|customize|automation|browser|remote|diagnostics>",
        "cmux guide | cmux --skill",
    };
    for (probes) |p| {
        if (std.mem.indexOf(u8, text, p) == null) {
            std.debug.print("missing probe: {s}\n", .{p});
            return error.TestUnexpectedResult;
        }
    }
    const wtext = try topLevelAlloc(.wmux);
    defer testing.allocator.free(wtext);
    try testing.expect(std.mem.startsWith(u8, wtext, "wmux - control wmux via named pipe\n"));
    try testing.expect(std.mem.indexOf(u8, wtext, "wmux guide | wmux --skill") != null);
}

test "unit: cli-help: topics carry their titles and probe lines" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "start", "Start & Resume:" },
        .{ "agents", "Agents:" },
        .{ "navigate", "Navigate & Arrange:" },
        .{ "inspect", "Inspect:" },
        .{ "inspect", "review list [--repo <path>] [--json]" },
        .{ "customize", "Customize:" },
        .{ "automation", "Automation:" },
        .{ "browser", "Browser:" },
        .{ "remote", "Remote:" },
        .{ "diagnostics", "Diagnostics / Advanced:" },
        .{ "diagnostics", "socket-status [--json]" },
        .{ "browser", "browser react-grab toggle [--surface <id>] [--return-to <terminal-surface>]" },
        .{ "browser", "browser devtools toggle|console [--surface <id>]" },
        .{ "browser", "browser focus-mode enter|exit|toggle [--surface <id>]" },
        .{ "browser", "browser design-mode enable|disable|toggle|status [--surface <id>]" },
        .{ "browser", "browser zoom in|out|reset|<factor> [--surface <id>]" },
        .{ "browser", "browser history clear --force" },
        .{ "browser", "browser console <list|clear>" },
        .{ "browser", "browser errors <list|clear>" },
    };
    for (cases) |c| {
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try writeHelpCommand(&aw.writer, .cmux, &.{c[0]});
        try testing.expect(std.mem.indexOf(u8, aw.written(), c[1]) != null);
        // A topic is one group only.
        try testing.expect(std.mem.indexOf(u8, aw.written(), "Global options") == null);
    }
}

test "unit: cli-help: unknown topic or extra arguments print the top level" {
    const full = try topLevelAlloc(.cmux);
    defer testing.allocator.free(full);
    for ([_][]const []const u8{ &.{"bogus"}, &.{"unknown-task-topic"}, &.{ "start", "agents" }, &.{}, &.{""}, &.{"START"} }) |a| {
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try writeHelpCommand(&aw.writer, .cmux, a);
        try testing.expectEqualStrings(full, aw.written());
    }
}

fn listedIn(text: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "  ") or line.len < 3 or line[2] == ' ') continue;
        const rest = line[2..];
        if (!std.mem.startsWith(u8, rest, name)) continue;
        if (rest.len == name.len or rest[name.len] == ' ') return true;
    }
    return false;
}

test "unit: cli-help: every visible catalog command is listed in exactly one topic" {
    for (catalog.entries) |e| {
        var count: usize = 0;
        var where: Group = undefined;
        for (topics) |t| if (listedIn(t.text, e.name)) {
            count += 1;
            where = t.group;
        };
        if (e.hidden) {
            try testing.expectEqual(@as(usize, 0), count);
            continue;
        }
        if (count != 1 or where != e.group) {
            std.debug.print("catalog entry '{s}' listed {d} times\n", .{ e.name, count });
            return error.TestUnexpectedResult;
        }
    }
}

test "unit: cli-help: catalog names are unique and usages start with Usage: cmux" {
    for (catalog.entries, 0..) |e, i| {
        try testing.expect(std.mem.startsWith(u8, e.usage, "Usage: cmux "));
        try testing.expect(e.summary.len > 0);
        for (catalog.entries[0..i]) |prev| try testing.expect(!std.mem.eql(u8, prev.name, e.name));
    }
}

test "unit: cli-help: catalog lookup handles two-word commands and aliases" {
    try testing.expectEqualStrings("agent message", findCatalog("agent", "message").?.name);
    try testing.expectEqualStrings("session restore", findCatalog("session", "restore").?.name);
    try testing.expectEqualStrings("rename-workspace", findCatalog("rename-window", null).?.name);
    try testing.expectEqualStrings("surface-resume", findCatalog("surface", "resume").?.name);
    try testing.expectEqualStrings("shot", findCatalog("screenshot", "--help").?.name);
    try testing.expectEqual(@as(?*const catalog.Entry, null), findCatalog("frobnicate", null));
    try testing.expectEqual(@as(?*const catalog.Entry, null), findCatalog("", null));
    const long = "x" ** 200;
    try testing.expectEqual(@as(?*const catalog.Entry, null), findCatalog(long, long));
}
