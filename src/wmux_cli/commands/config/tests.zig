//! Tests of the `config` family: config, reload-config, themes, settings,
//! shortcuts. Settings resolve against the validate.zig fixture specs.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const proto = @import("wmux_proto");
const harness = @import("../cli_misc/harness.zig");
const fake = @import("../../fake.zig");
const files = @import("files.zig");
const themes = @import("themes.zig");
const settings_cmd = @import("settings_cmd.zig");

fn server(_: *fake.Server, req: fake.Request) fake.Action {
    if (std.mem.eql(u8, req.method, "wmux.config.reload")) return .{ .ok = "{\"reloaded\":true}" };
    if (std.mem.eql(u8, req.method, "settings.open")) return .{ .ok = "{\"window_id\":\"W\"}" };
    return .{ .err = "{\"code\":\"method_not_found\",\"message\":\"Unknown method\"}" };
}

const Fixture = struct {
    h: harness.Harness,
    wmux_json: []const u8,
    cmux_json: []const u8,
    overlay: []const u8,

    fn init(self: *Fixture) void {
        self.h.init();
        const a = self.h.alloc();
        files.specs = &proto.settings.validate.test_fixture_specs;
        self.h.setEnv("WMUX_CONFIG_DIR", harness.p(a, &.{ harness.root, "cfg" }));
        self.h.setEnv("XDG_CONFIG_HOME", harness.p(a, &.{ harness.root, "xdg" }));
        self.h.setEnv("HOME", harness.p(a, &.{ harness.root, "home" }));
        self.h.setEnv("USERPROFILE", harness.p(a, &.{ harness.root, "home" }));
        self.wmux_json = harness.p(a, &.{ harness.root, "cfg", "wmux.json" });
        self.cmux_json = harness.p(a, &.{ harness.root, "xdg", "cmux", "cmux.json" });
        self.overlay = harness.p(a, &.{ harness.root, "cfg", "config.ghostty" });
    }

    fn deinit(self: *Fixture) void {
        files.specs = proto.settings.specs_manifest.all;
        self.h.deinit();
    }
};

const sample =
    \\{
    \\  // keep me
    \\  "app": {
    \\    "minimalMode": true
    \\  },
    \\  "terminal": { "scrollSpeed": 1.2 }
    \\}
    \\
;

test "unit: cli-config: doctor reports syntax and schema errors with paths" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    h.addFile(f.wmux_json, sample);
    const ok = h.run(&.{ "cmux", "config", "doctor" });
    try harness.expectOk(ok);
    try harness.expectGolden(h.alloc(), "config-doctor-ok.txt", ok.out);

    h.addFile(f.cmux_json, "{\"app\": {\"appearance\": \"neon\"}, \"nope\": 1}");
    const bad = h.run(&.{ "cmux", "config", "check" });
    try testing.expectEqual(@as(u8, 1), bad.code);
    try harness.expectGolden(h.alloc(), "config-doctor-error.txt", bad.out);
    const js = h.run(&.{ "cmux", "config", "validate", "--json" });
    try testing.expectEqual(@as(u8, 1), js.code);
    try harness.expectGolden(h.alloc(), "config-doctor-json.txt", js.out);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, h.alloc(), js.out, .{});
    try testing.expectEqual(@as(i64, 1), parsed.object.get("error_count").?.integer);

    // A malformed file: exit 1 with the issue path.
    const broken = harness.p(h.alloc(), &.{ harness.root, "broken.json" });
    h.addFile(broken, "{\"app\": {,}");
    const syn = h.run(&.{ "cmux", "config", "doctor", "--path", broken });
    try testing.expectEqual(@as(u8, 1), syn.code);
    try harness.expectContains(syn.out, "error: $:");
    const missing = h.run(&.{ "cmux", "config", "doctor", "--path", "nope.json" });
    try testing.expectEqual(@as(u8, 1), missing.code);
    try harness.expectContains(missing.out, "not found");
    try harness.expectFail(h.run(&.{ "cmux", "config", "doctor", "--scope", "team" }), 2, "--scope must be global or project");
    try harness.expectFail(h.run(&.{ "cmux", "config", "doctor", "x" }), 2, "unexpected argument 'x'");
}

test "unit: cli-config: set then get, with comments preserved and sources" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    h.addFile(f.wmux_json, sample);
    const set = h.run(&.{ "cmux", "config", "set", "app.appearance", "dark" });
    try harness.expectOk(set);
    try harness.expectGolden(h.alloc(), "config-set.txt", set.out);
    try harness.expectGolden(h.alloc(), "config-set-file.txt", h.file(f.wmux_json).?);
    const get = h.run(&.{ "cmux", "config", "get", "app.appearance" });
    try testing.expectEqualStrings("\"dark\"\n", get.out);
    const js = h.run(&.{ "cmux", "config", "get", "app.appearance", "--json" });
    try harness.expectGolden(h.alloc(), "config-get-json.txt", js.out);
    const def = h.run(&.{ "cmux", "config", "get", "sidebar.showPorts" });
    try testing.expectEqualStrings("true  (default)\n", def.out);
    h.addFile(f.cmux_json, "{\"sidebar\": {\"showPorts\": false}}");
    const shared = h.run(&.{ "cmux", "config", "get", "sidebar.showPorts" });
    try testing.expectEqualStrings("false  (from cmux.json)\n", shared.out);
    // Unchanged writes print OK unchanged and do not touch the file.
    const writes = h.writes;
    const same = h.run(&.{ "cmux", "config", "set", "app.appearance", "\"dark\"" });
    try testing.expect(std.mem.startsWith(u8, same.out, "OK unchanged\npath: "));
    try testing.expectEqual(writes, h.writes);
    try harness.expectOk(h.run(&.{ "cmux", "config", "set", "terminal.scrollSpeed", "1.4" }));
    try testing.expectEqualStrings("1.4\n", h.run(&.{ "cmux", "config", "get", "terminal.scrollSpeed" }).out);
    // --file cmux writes the shared file.
    try harness.expectOk(h.run(&.{ "cmux", "config", "set", "app.minimalMode", "false", "--file", "cmux" }));
    try harness.expectContains(h.file(f.cmux_json).?, "\"minimalMode\": false");
}

test "unit: cli-config: invalid values are refused and leave the file byte-identical" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    h.addFile(f.wmux_json, sample);
    try harness.expectFail(h.run(&.{ "cmux", "config", "set", "terminal.scrollSpeed", "9" }), 1, "refusing to write");
    try testing.expectEqualStrings(sample, h.file(f.wmux_json).?);
    try testing.expectEqual(@as(usize, 0), h.writes);
    try harness.expectFail(h.run(&.{ "cmux", "config", "set", "nosuch.key", "1" }), 2, "unknown setting 'nosuch.key'");
    try harness.expectFail(h.run(&.{ "cmux", "config", "set", "workspaceGroups.byCwd.~/src/app.web", "x" }), 2, "keys that contain '.' cannot be addressed");
    try harness.expectFail(h.run(&.{ "cmux", "config", "get", "actions.build" }), 2, "not a setting");
    try harness.expectFail(h.run(&.{ "cmux", "config", "get", "app" }), 2, "is a section, not a single setting");
    try harness.expectFail(h.run(&.{ "cmux", "config", "get", "a..b" }), 2, "not a valid setting path");
    try harness.expectFail(h.run(&.{ "cmux", "config", "set", "app.appearance" }), 2, "config set requires a setting path and a value");
    try harness.expectFail(h.run(&.{ "cmux", "config", "set", "app.appearance", "dark", "--file", "ghostty" }), 2, "--file must be wmux or cmux");
    try harness.expectFail(h.run(&.{ "cmux", "config", "set", "app.appearance", "\xff" }), 2, "not valid UTF-8");
    try harness.expectFail(h.run(&.{ "cmux", "config", "frob" }), 2, "unknown config subcommand 'frob'");
    try harness.expectFail(h.run(&.{ "cmux", "config" }), 2, "config requires a subcommand");
    try harness.expectFail(h.run(&.{ "cmux", "config", "sidebar-font-size" }), 2, "unknown setting 'sidebar.fontSize'");
    h.fail_writes = true;
    try harness.expectFail(h.run(&.{ "cmux", "config", "set", "app.appearance", "light" }), 1, "cannot write");
    h.fail_writes = false;
    // A file that does not parse is reported, not overwritten.
    h.addFile(f.cmux_json, "{oops");
    try harness.expectFail(h.run(&.{ "cmux", "config", "get", "app.appearance" }), 1, "does not parse");
    try testing.expectEqualStrings(sample, h.file(f.wmux_json).?);
}

test "unit: cli-config: toggle, cycle, unset and preset share the mutation path" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    h.addFile(f.wmux_json, sample);
    const t1 = h.run(&.{ "cmux", "config", "toggle", "fileEditor.wordWrap" });
    try harness.expectOk(t1);
    try harness.expectContains(t1.out, "OK fileEditor.wordWrap = false\n");
    try harness.expectOk(h.run(&.{ "cmux", "config", "toggle", "fileEditor.wordWrap" }));
    try testing.expectEqualStrings("true\n", h.run(&.{ "cmux", "config", "get", "fileEditor.wordWrap" }).out);
    try harness.expectFail(h.run(&.{ "cmux", "config", "toggle", "app.appearance" }), 2, "is not a boolean setting");

    try harness.expectOk(h.run(&.{ "cmux", "config", "cycle", "app.appearance", "light", "dark" }));
    try testing.expectEqualStrings("\"light\"\n", h.run(&.{ "cmux", "config", "get", "app.appearance" }).out);
    try harness.expectOk(h.run(&.{ "cmux", "config", "cycle", "app.appearance", "light", "dark" }));
    try testing.expectEqualStrings("\"dark\"\n", h.run(&.{ "cmux", "config", "get", "app.appearance" }).out);
    try harness.expectOk(h.run(&.{ "cmux", "config", "cycle", "app.appearance", "light", "dark" }));
    try testing.expectEqualStrings("\"light\"\n", h.run(&.{ "cmux", "config", "get", "app.appearance" }).out);
    try harness.expectFail(h.run(&.{ "cmux", "config", "cycle", "app.appearance" }), 2, "at least one value");

    const un = h.run(&.{ "cmux", "config", "unset", "app.appearance" });
    try harness.expectOk(un);
    try harness.expectContains(un.out, "OK app.appearance unset\n");
    try testing.expectEqualStrings("\"system\"  (default)\n", h.run(&.{ "cmux", "config", "get", "app.appearance" }).out);
    const again = h.run(&.{ "cmux", "config", "unset", "app.appearance", "--json" });
    try harness.expectOk(again);
    try harness.expectContains(again.out, "\"changed\": false");

    h.addFile(f.cmux_json, "{\"settingPresets\": {\"focus\": {\"app\": {\"minimalMode\": false, \"appearance\": \"dark\"}, \"sidebar\": {\"showPorts\": false}}, \"bad\": {\"app\": {\"nope\": 1}}}}");
    const pre = h.run(&.{ "cmux", "config", "preset", "focus" });
    try harness.expectOk(pre);
    try harness.expectGolden(h.alloc(), "config-preset.txt", pre.out);
    try harness.expectContains(h.file(f.wmux_json).?, "// keep me");
    try harness.expectFail(h.run(&.{ "cmux", "config", "preset", "nope" }), 2, "unknown preset 'nope'");
    try harness.expectFail(h.run(&.{ "cmux", "config", "preset", "bad" }), 2, "names 'app.nope', which is not a setting");
}

test "unit: cli-config: a missing wmux.json is created; policy-managed settings are refused" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    const js = h.run(&.{ "cmux", "config", "set", "sidebar.showPorts", "false", "--json" });
    try harness.expectOk(js);
    try harness.expectGolden(h.alloc(), "config-set-json.txt", js.out);
    try testing.expectEqualStrings("{\n  \"sidebar\": {\n    \"showPorts\": false\n  }\n}\n", h.file(f.wmux_json).?);
    h.fp.hklm = .{ .string = "allowAll" };
    try harness.expectFail(h.run(&.{ "cmux", "config", "set", "automation.socketControlMode", "off" }), 1, "is managed by policy");
    const get = h.run(&.{ "cmux", "config", "get", "automation.socketControlMode" });
    try testing.expectEqualStrings("\"allowAll\"  (managed by policy)\n", get.out);
}

test "unit: cli-config: a config file that exists but cannot be read is reported and never replaced" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    const a = h.alloc();
    // Larger than max_file_bytes: Platform.readFile refuses it like a file it
    // cannot open, yet the file is there.
    const big = try a.alloc(u8, files.max_file_bytes + 1);
    @memset(big, ' ');
    h.addFile(f.wmux_json, big);
    try harness.expectFail(h.run(&.{ "cmux", "config", "set", "app.appearance", "dark" }), 1, try std.fmt.allocPrint(a, "config set: cannot read {s}", .{f.wmux_json}));
    try harness.expectFail(h.run(&.{ "cmux", "config", "unset", "app.appearance" }), 1, "it was not changed");
    try harness.expectFail(h.run(&.{ "cmux", "config", "toggle", "sidebar.showPorts" }), 1, "cannot read");
    try testing.expectEqual(@as(usize, 0), h.writes);
    try testing.expectEqual(big.len, h.file(f.wmux_json).?.len);
    const doc = h.run(&.{ "cmux", "config", "doctor" });
    try testing.expectEqual(@as(u8, 1), doc.code);
    try harness.expectContains(doc.out, try std.fmt.allocPrint(a, "wmux.json: {s}: cannot read (unreadable or larger than 4 MiB)\n", .{f.wmux_json}));
    const js = try std.json.parseFromSliceLeaky(std.json.Value, a, h.run(&.{ "cmux", "config", "doctor", "--json" }).out, .{});
    const finding = js.object.get("findings").?.array.items[0].object;
    try testing.expectEqualStrings("error", finding.get("status").?.string);
    try testing.expectEqual(false, finding.get("ok").?.bool);

    // The theme overlay gets the same protection.
    addThemes(&f);
    h.addFile(f.overlay, big);
    try harness.expectFail(h.run(&.{ "cmux", "themes", "set", "Dracula" }), 1, "themes set: cannot read");
    try harness.expectFail(h.run(&.{ "cmux", "themes", "clear" }), 1, "themes clear: cannot read");
    try testing.expectEqual(@as(usize, 0), h.writes);
    try testing.expectEqual(big.len, h.file(f.overlay).?.len);
}

test "unit: cli-config: the global files are not project files and explicit files get an inferred scope" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    const a = h.alloc();
    // app.minimalMode is global-only: in project scope it is an error.
    const global_only = "{\"app\": {\"minimalMode\": true}}\n";
    h.addFile(f.wmux_json, global_only);
    // From inside the config directory, wmux.json is only the global file.
    h.fp.cwd_path = harness.p(a, &.{ harness.root, "cfg" });
    const inside = h.run(&.{ "cmux", "config", "doctor" });
    try harness.expectOk(inside);
    try testing.expect(!harness.contains(inside.out, "project:"));
    try testing.expectEqualStrings("true\n", h.run(&.{ "cmux", "config", "get", "app.minimalMode" }).out);
    // A project file next to the cwd still counts, in project scope.
    const repo = harness.p(a, &.{ harness.root, "repo" });
    const project = harness.p(a, &.{ repo, ".wmux", "wmux.json" });
    h.addFile(project, global_only);
    h.fp.cwd_path = repo;
    const in_repo = h.run(&.{ "cmux", "config", "doctor" });
    try testing.expectEqual(@as(u8, 1), in_repo.code);
    try harness.expectContains(in_repo.out, try std.fmt.allocPrint(a, "project: {s}: 1 error", .{project}));
    try harness.expectContains(in_repo.out, "$.app.minimalMode: only allowed in the global config");

    // --path: a wmux.json/cmux.json outside the config directory is a
    // project file unless --scope says otherwise; the global file (however
    // it is spelled) and other names are global.
    const explicit = h.run(&.{ "cmux", "config", "doctor", "--path", project });
    try testing.expectEqual(@as(u8, 1), explicit.code);
    try harness.expectContains(explicit.out, "only allowed in the global config");
    try harness.expectOk(h.run(&.{ "cmux", "config", "doctor", "--path", project, "--scope", "global" }));
    try harness.expectOk(h.run(&.{ "cmux", "config", "doctor", "--path", harness.p(a, &.{ harness.root, "cfg", ".", "wmux.json" }) }));
    const other = harness.p(a, &.{ repo, "team-settings.json" });
    h.addFile(other, global_only);
    try harness.expectOk(h.run(&.{ "cmux", "config", "doctor", "--path", other }));
}

test "unit: cli-config: samePath compares normalized spellings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const w = harness.p(a, &.{ harness.root, "cfg", "wmux.json" });
    try testing.expect(try files.samePath(a, w, harness.p(a, &.{ harness.root, "x", "..", "cfg", ".", "wmux.json" })));
    try testing.expect(!try files.samePath(a, w, harness.p(a, &.{ harness.root, "cfg", "cmux.json" })));
    if (builtin.os.tag == .windows) {
        try testing.expect(try files.samePath(a, "C:\\T\\Cfg\\WMUX.json", "c:/t/cfg/wmux.json"));
    } else {
        try testing.expect(!try files.samePath(a, "/T/cfg/wmux.json", "/t/cfg/wmux.json"));
    }
}

test "unit: cli-config: path and docs work offline; reload needs the app" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    for ([_][]const []const u8{
        &.{ "cmux", "config", "path" },   &.{ "cmux", "config", "paths" },
        &.{ "cmux", "config", "docs" },   &.{ "cmux", "config", "documentation" },
        &.{ "cmux", "settings", "path" }, &.{ "cmux", "settings", "docs" },
    }) |argv| {
        const r = h.run(argv);
        try harness.expectOk(r);
        try harness.expectContains(r.out, "Config files:");
    }
    const path = h.run(&.{ "cmux", "config", "path" });
    try harness.expectGolden(h.alloc(), "config-path.txt", path.out);
    const js = h.run(&.{ "cmux", "settings", "path", "--json" });
    try harness.expectContains(js.out, "\"config_files\"");
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
    try harness.expectFail(h.run(&.{ "cmux", "config", "reload" }), 1, "No live wmux socket found");
    h.serve(server);
    const r = h.run(&.{ "cmux", "config", "reload" });
    try testing.expectEqualStrings("OK\n", r.out);
    try testing.expectEqualStrings("wmux.config.reload", h.last().method);
    const rc = h.run(&.{ "cmux", "reload-config" });
    try testing.expectEqualStrings("OK\n", rc.out);
    try harness.expectFail(h.run(&.{ "cmux", "reload-config", "x" }), 2, "unexpected argument 'x'");
    const help = h.run(&.{ "cmux", "config", "--help" });
    try harness.expectOk(help);
    try harness.expectGolden(h.alloc(), "config-help.txt", help.out);
}

test "unit: cli-themes: parse, rewrite and the theme line forms" {
    const c = themes.parseChoice("light:Rose Pine Dawn, dark:Dracula");
    try testing.expectEqualStrings("Rose Pine Dawn", c.light.?);
    try testing.expectEqualStrings("Dracula", c.dark.?);
    const one = themes.parseChoice("\"Catppuccin Mocha\"");
    try testing.expectEqualStrings("Catppuccin Mocha", one.light.?);
    try testing.expectEqualStrings("Catppuccin Mocha", one.dark.?);
    const half = themes.parseChoice("dark:Nord");
    try testing.expect(half.light == null);
    try testing.expectEqualStrings("Nord", themes.themeOf("# theme = x\nfont-size = 12\ntheme = a\ntheme = dark:Nord\n").?.dark.?);
    try testing.expect(themes.themeOf("font-size = 3\n") == null);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("font-size = 12\r\ntheme = X\r\nx = 1\r\n", try themes.rewriteTheme(a, "font-size = 12\r\ntheme = a\r\nx = 1\r\ntheme=b\r\n", "theme = X"));
    try testing.expectEqualStrings("a = 1\ntheme = X\n", try themes.rewriteTheme(a, "a = 1", "theme = X"));
    try testing.expectEqualStrings("theme = X\n", try themes.rewriteTheme(a, "", "theme = X"));
    try testing.expectEqualStrings("a = 1\n", try themes.rewriteTheme(a, "a = 1\ntheme = b\n", null));
    try testing.expectEqualStrings("", try themes.rewriteTheme(a, "", null));
}

fn addThemes(f: *Fixture) void {
    const h = &f.h;
    const a = h.alloc();
    h.fp.self_exe = harness.p(a, &.{ harness.root, "wmux", "cli", "cmux.exe" });
    const bundled = harness.p(a, &.{ harness.root, "wmux", "share", "ghostty", "themes" });
    for ([_][]const u8{ "Dracula", "Catppuccin Mocha", "nord", ".hidden" }) |n| h.addFile(harness.p(a, &.{ bundled, n }), "background = 000000\n");
    const user = harness.p(a, &.{ harness.root, "xdg", "ghostty", "themes" });
    h.addFile(harness.p(a, &.{ user, "Mine \u{e9}" }), "x");
    h.addFile(harness.p(a, &.{ user, "dracula" }), "user copy wins");
}

test "unit: cli-themes: list, set halves, unknown names and clear" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    addThemes(&f);
    h.addFile(f.overlay, "font-size = 13\ntheme = light:nord,dark:dracula\n");
    const list = h.run(&.{ "cmux", "themes", "list" });
    try harness.expectOk(list);
    try harness.expectGolden(h.alloc(), "themes-list.txt", list.out);
    const js = h.run(&.{ "cmux", "themes", "--json" });
    try harness.expectOk(js);
    try harness.expectGolden(h.alloc(), "themes-list-json.txt", js.out);

    const set = h.run(&.{ "cmux", "themes", "set", "catppuccin mocha" });
    try harness.expectOk(set);
    try harness.expectGolden(h.alloc(), "themes-set.txt", set.out);
    try testing.expectEqualStrings("font-size = 13\ntheme = light:Catppuccin Mocha,dark:Catppuccin Mocha\n", h.file(f.overlay).?);
    try harness.expectOk(h.run(&.{ "cmux", "themes", "set", "--dark", "Dracula" }));
    try testing.expectEqualStrings("font-size = 13\ntheme = light:Catppuccin Mocha,dark:dracula\n", h.file(f.overlay).?);

    const writes = h.writes;
    try harness.expectFail(h.run(&.{ "cmux", "themes", "set", "Solarized" }), 1, "unknown theme 'Solarized'");
    try harness.expectFail(h.run(&.{ "cmux", "themes", "set", "--both", "x" }), 2, "themes set: unknown flag '--both'. Known flags: --light <theme>, --dark <theme>");
    try harness.expectFail(h.run(&.{ "cmux", "themes", "set" }), 2, "themes set requires a theme name");
    try harness.expectFail(h.run(&.{ "cmux", "themes", "paint" }), 2, "unknown themes subcommand 'paint'");
    try testing.expectEqual(writes, h.writes);

    // With the app running the reload is requested.
    h.serve(server);
    const clear = h.run(&.{ "cmux", "themes", "clear" });
    try harness.expectOk(clear);
    try harness.expectGolden(h.alloc(), "themes-clear.txt", clear.out);
    try testing.expectEqualStrings("font-size = 13\n", h.file(f.overlay).?);
    try testing.expectEqualStrings("wmux.config.reload", h.last().method);
    const after = h.run(&.{ "cmux", "themes" });
    try harness.expectContains(after.out, "Current light: inherit\n");
}

test "unit: cli-settings: open targets, shortcuts and argument errors" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    h.serve(server);
    const r = h.run(&.{ "cmux", "settings" });
    try testing.expectEqualStrings("OK\n", r.out);
    try testing.expectEqualStrings("settings.open", h.last().method);
    try testing.expectEqualStrings("{\"activate\":true}", h.last().params_json);
    _ = h.run(&.{ "cmux", "settings", "shortcuts" });
    try testing.expectEqualStrings("{\"target\":\"keyboard-shortcuts\",\"activate\":true}", h.last().params_json);
    _ = h.run(&.{ "cmux", "settings", "open", "json" });
    try testing.expectEqualStrings("{\"target\":\"cmux-json\",\"activate\":true}", h.last().params_json);
    _ = h.run(&.{ "cmux", "settings", "open", "browser-import" });
    try testing.expectEqualStrings("browser-import", harness.param(h.last(), "target").?.string);
    const sc = h.run(&.{ "cmux", "shortcuts" });
    try testing.expectEqualStrings("OK\n", sc.out);
    try testing.expectEqualStrings("{\"target\":\"keyboard-shortcuts\",\"activate\":true}", h.last().params_json);
    const n = h.requestCount();
    try harness.expectFail(h.run(&.{ "cmux", "settings", "colors" }), 2, "unknown settings target 'colors'");
    try harness.expectFail(h.run(&.{ "cmux", "settings", "open", "app", "x" }), 2, "unexpected argument 'x'");
    try harness.expectFail(h.run(&.{ "cmux", "shortcuts", "x" }), 2, "unexpected argument 'x'");
    try harness.expectFail(h.run(&.{ "cmux", "settings", "path", "x" }), 2, "unexpected argument 'x'");
    try testing.expectEqual(n, h.requestCount());
    try testing.expectEqualStrings("keyboard-shortcuts", settings_cmd.canonicalTarget("shortcuts").?);
    try testing.expect(settings_cmd.canonicalTarget("nope") == null);
    const help = h.run(&.{ "cmux", "shortcuts", "--help" });
    try harness.expectContains(help.out, "Usage: cmux shortcuts\n\nOpen the Settings window to Keyboard Shortcuts.");
    try harness.expectGolden(h.alloc(), "settings-help.txt", h.run(&.{ "cmux", "settings", "--help" }).out);
    try harness.expectGolden(h.alloc(), "themes-help.txt", h.run(&.{ "cmux", "themes", "--help" }).out);
}
