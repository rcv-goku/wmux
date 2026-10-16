//! `cmux docs [topic]` (cli-docs-command): documentation pointers, config
//! file locations and useful commands per topic, offline. `docs` alone lists
//! the topics under `Topics:`; an unknown topic prints the usage as an error.
//! wmux documentation lives in the repository under `docs/wmux/`; paths are
//! the Windows equivalents of cmux's (Appendix G). `--json` returns the same
//! data as an object.

const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");
const paths = proto.paths;
const brand_mod = @import("brand.zig");
const Brand = brand_mod.Brand;

pub const usage = "Usage: cmux docs [settings|shortcuts|api|browser|capture|agents|workflows|dock|managed-policies]";

/// Where wmux's documentation lives (repository-relative).
pub const docs_root = "docs/wmux";

pub const Example = struct {
    id: []const u8,
    title: []const u8,
    summary: []const u8,
    fit: []const u8,
    creates: []const []const u8,
    config_files: []const []const u8,
    primitives: []const []const u8,
    requires: []const []const u8,
    instantiate: []const u8,
    adapt: []const u8,
    source: []const u8,
};

pub const Topic = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    /// Shown as `<name>: <summary>`.
    summary: []const u8,
    docs: []const []const u8,
    commands: []const []const u8,
    examples: []const Example = &.{},
};

pub const topics = [_]Topic{
    .{
        .name = "settings",
        .aliases = &.{ "config", "configuration" },
        .summary = "Settings in wmux.json, its schema and the config files",
        .docs = &.{ docs_root ++ "/features/settings.md", docs_root ++ "/cli/config.md" },
        .commands = &.{ "cmux config path", "cmux config doctor", "cmux config get <key>", "cmux config set <key> <value>", "cmux reload-config" },
    },
    .{
        .name = "shortcuts",
        .aliases = &.{ "keys", "keybindings" },
        .summary = "Keyboard shortcuts, presets and rebinding",
        .docs = &.{docs_root ++ "/features/shortcuts.md"},
        .commands = &.{ "cmux shortcuts", "cmux welcome", "cmux config get shortcuts" },
    },
    .{
        .name = "api",
        .aliases = &.{ "socket", "rpc" },
        .summary = "The v2 control-pipe protocol and the CLI contract",
        .docs = &.{ docs_root ++ "/cli/system.md", docs_root ++ "/api.md" },
        .commands = &.{ "cmux capabilities --json", "cmux rpc system.ping", "cmux identify --json", "cmux socket-status --json" },
    },
    .{
        .name = "browser",
        .summary = "Built-in browser panes and browser automation",
        .docs = &.{ docs_root ++ "/features/browser.md", docs_root ++ "/cli/browser.md" },
        .commands = &.{ "cmux browser --help", "cmux browser open <url>", "cmux browser-status", "cmux disable-browser", "cmux enable-browser" },
    },
    .{
        .name = "capture",
        .aliases = &.{ "screenshot", "shot", "record", "gif" },
        .summary = "Screenshot or record a cmux window",
        .docs = &.{docs_root ++ "/features/capture.md"},
        .commands = &.{ "cmux shot --help", "cmux record start", "cmux record stop" },
    },
    .{
        .name = "agents",
        .aliases = &.{ "hooks", "agent" },
        .summary = "Agent hooks, sessions, resume and team launchers",
        .docs = &.{ docs_root ++ "/features/agents.md", docs_root ++ "/cli/hooks_agents.md" },
        .commands = &.{ "cmux hooks setup", "cmux sessions", "cmux guide", "cmux claude-teams" },
    },
    .{
        .name = "workflows",
        .aliases = &.{ "templates", "presets", "examples", "layouts" },
        .summary = "Saved layouts and workflow examples",
        .docs = &.{docs_root ++ "/features/layouts.md"},
        .commands = &.{ "cmux layout list", "cmux layout save <name>", "cmux layout open <name>", "cmux docs workflows --json" },
        .examples = &.{
            .{
                .id = "agent-and-server",
                .title = "Agent beside a dev server",
                .summary = "One workspace with an agent on the left and a dev server plus logs on the right.",
                .fit = "Web projects where the agent edits code while a server reloads.",
                .creates = &.{ "workspace", "split", "terminal surfaces" },
                .config_files = &.{"%USERPROFILE%\\.config\\wmux\\layouts\\agent-and-server.json"},
                .primitives = &.{ "new-workspace", "new-split", "send" },
                .requires = &.{"an agent CLI on PATH"},
                .instantiate = "cmux layout open agent-and-server --cwd <dir>",
                .adapt = "Change the server command in the layout file, then save it again with cmux layout save.",
                .source = docs_root ++ "/features/layouts.md",
            },
            .{
                .id = "review-loop",
                .title = "Review loop",
                .summary = "An agent workspace plus a diff viewer and a test runner surface.",
                .fit = "Iterating on a change with frequent test runs and diff review.",
                .creates = &.{ "workspace", "diff panel", "terminal surface" },
                .config_files = &.{"%USERPROFILE%\\.config\\wmux\\layouts\\review-loop.json"},
                .primitives = &.{ "new-workspace", "diff", "new-surface" },
                .requires = &.{"a git repository"},
                .instantiate = "cmux layout open review-loop --cwd <repo>",
                .adapt = "Point the test surface at your test command.",
                .source = docs_root ++ "/features/layouts.md",
            },
        },
    },
    .{
        .name = "dock",
        .summary = "Custom right-sidebar terminal controls",
        .docs = &.{docs_root ++ "/features/dock.md"},
        .commands = &.{ "cmux right-sidebar --help", "cmux config get rightSidebar" },
    },
    .{
        .name = "managed-policies",
        .aliases = &.{ "policies", "policy" },
        .summary = "Group Policy settings under HKLM/HKCU\\Software\\Policies\\wmux",
        .docs = &.{docs_root ++ "/features/policy.md"},
        .commands = &.{ "cmux socket-status --json", "cmux config doctor" },
    },
};

pub fn find(name: []const u8) ?*const Topic {
    for (&topics) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
        for (t.aliases) |a| if (std.mem.eql(u8, a, name)) return t;
    }
    return null;
}

/// Locations printed by `docs settings` (and `settings path` later).
/// Null entries print a placeholder naming the variable to set.
pub const Locations = struct {
    config_dir: ?[]const u8 = null,
    cmux_config_dir: ?[]const u8 = null,
    ghostty_dir: ?[]const u8 = null,
    install_dir: ?[]const u8 = null,

    pub fn resolve(arena: Allocator, env: proto.env_names.Env, self_exe: ?[]const u8) Allocator.Error!Locations {
        const style = paths.Style.native;
        return .{
            .config_dir = try paths.configDir(arena, env, style),
            .cmux_config_dir = try paths.cmuxConfigDir(arena, env, style),
            .ghostty_dir = try paths.legacyGhosttyDir(arena, env, style),
            .install_dir = if (self_exe) |e| paths.installFromCliExe(style, e) else null,
        };
    }
};

fn joinOr(arena: Allocator, dir: ?[]const u8, file: []const u8, fallback: []const u8) Allocator.Error![]const u8 {
    const d = dir orelse return fallback;
    return paths.join(arena, paths.Style.native, &.{ d, file });
}

fn writeConfigFiles(arena: Allocator, w: *Writer, loc: Locations) !void {
    try w.writeAll("Config files:\n");
    try w.print("  {s}  (primary)\n", .{try joinOr(arena, loc.config_dir, proto.paths.files.wmux_json, "%USERPROFILE%\\.config\\wmux\\wmux.json")});
    try w.print("  {s}  (cmux compatibility, read-only)\n", .{try joinOr(arena, loc.cmux_config_dir, proto.paths.files.cmux_json, "%USERPROFILE%\\.config\\cmux\\cmux.json")});
    try w.print("  {s}  (wmux overlay for terminal settings)\n", .{try joinOr(arena, loc.config_dir, proto.paths.files.ghostty_overlay, "%USERPROFILE%\\.config\\wmux\\config.ghostty")});
    try w.print("  {s}  (related Ghostty config)\n", .{try joinOr(arena, loc.ghostty_dir, "config.ghostty", "%LOCALAPPDATA%\\ghostty\\config.ghostty")});
    if (loc.install_dir) |i| {
        try w.print("Schema: {s}\n", .{try proto.paths.schemaFile(arena, paths.Style.native, i)});
    } else try w.writeAll("Schema: share\\wmux\\schema\\wmux.schema.json next to wmux.exe\n");
    try w.writeAll("Before editing by hand, copy wmux.json to a timestamped .bak file.\n");
    try w.writeAll("After editing: cmux reload-config\n");
}

/// Text for one topic (authored with `cmux`; the caller rebrands).
pub fn writeTopic(arena: Allocator, w: *Writer, t: *const Topic, loc: Locations) !void {
    try w.print("{s}: {s}\n", .{ t.name, t.summary });
    try w.writeAll("Docs:\n");
    for (t.docs) |d| try w.print("  {s}\n", .{d});
    if (std.mem.eql(u8, t.name, "settings")) try writeConfigFiles(arena, w, loc);
    try w.writeAll("Commands:\n");
    for (t.commands) |c| try w.print("  {s}\n", .{c});
    if (t.examples.len > 0) {
        try w.writeAll("Examples:\n");
        for (t.examples) |e| try w.print("  {s}  {s}\n", .{ e.id, e.title });
    }
}

pub fn writeTopicList(w: *Writer) Writer.Error!void {
    try w.writeAll(usage ++ "\n\nTopics:\n");
    for (topics) |t| {
        try w.print("  {s}", .{t.name});
        try w.splatByteAll(' ', 18 -| t.name.len);
        try w.print("{s}\n", .{t.summary});
    }
}

pub fn writeTopicJson(arena: Allocator, w: *Writer, t: *const Topic, loc: Locations) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("topic");
    try s.write(t.name);
    try s.objectField("aliases");
    try s.write(t.aliases);
    try s.objectField("summary");
    try s.write(t.summary);
    try s.objectField("docs");
    try s.write(t.docs);
    try s.objectField("commands");
    try s.write(t.commands);
    if (std.mem.eql(u8, t.name, "settings")) {
        try s.objectField("config_files");
        try s.write(.{
            .primary = try joinOr(arena, loc.config_dir, proto.paths.files.wmux_json, "%USERPROFILE%\\.config\\wmux\\wmux.json"),
            .cmux_compat = try joinOr(arena, loc.cmux_config_dir, proto.paths.files.cmux_json, "%USERPROFILE%\\.config\\cmux\\cmux.json"),
            .ghostty_overlay = try joinOr(arena, loc.config_dir, proto.paths.files.ghostty_overlay, "%USERPROFILE%\\.config\\wmux\\config.ghostty"),
            .ghostty = try joinOr(arena, loc.ghostty_dir, "config.ghostty", "%LOCALAPPDATA%\\ghostty\\config.ghostty"),
        });
    }
    if (t.examples.len > 0) {
        try s.objectField("examples");
        try s.write(t.examples);
    }
    try s.endObject();
    try w.writeByte('\n');
}

pub fn writeTopicListJson(w: *Writer) Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("topics");
    try s.beginArray();
    for (topics) |t| try s.write(.{ .name = t.name, .aliases = t.aliases, .summary = t.summary });
    try s.endArray();
    try s.endObject();
    try w.writeByte('\n');
}

const testing = std.testing;

test "unit: cli-docs: topics and aliases resolve" {
    try testing.expectEqualStrings("capture", find("gif").?.name);
    try testing.expectEqualStrings("capture", find("screenshot").?.name);
    try testing.expectEqualStrings("workflows", find("layouts").?.name);
    try testing.expectEqualStrings("managed-policies", find("managed-policies").?.name);
    try testing.expectEqual(@as(?*const Topic, null), find("bogus"));
    try testing.expectEqual(@as(?*const Topic, null), find(""));
}

test "unit: cli-docs: settings lists config files with the reload command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeTopic(a, &aw.writer, find("settings").?, .{});
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "Config files:\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "%USERPROFILE%\\.config\\wmux\\wmux.json  (primary)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "cmux reload-config") != null);
}

test "unit: cli-docs: probe summaries and json shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeTopic(a, &aw.writer, find("capture").?, .{});
    try testing.expect(std.mem.startsWith(u8, aw.written(), "capture: Screenshot or record a cmux window\n"));
    aw.clearRetainingCapacity();
    try writeTopic(a, &aw.writer, find("dock").?, .{});
    try testing.expect(std.mem.startsWith(u8, aw.written(), "dock: Custom right-sidebar terminal controls\n"));
    aw.clearRetainingCapacity();
    try writeTopicJson(a, &aw.writer, find("workflows").?, .{});
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, aw.written(), .{});
    const ex = v.object.get("examples").?.array.items[0].object;
    for ([_][]const u8{ "id", "title", "summary", "fit", "creates", "config_files", "primitives", "requires", "instantiate", "adapt", "source" }) |k| {
        try testing.expect(ex.get(k) != null);
    }
    aw.clearRetainingCapacity();
    try writeTopicList(&aw.writer);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\nTopics:\n") != null);
}
