//! Unit tests of the pure browser planner: every verb's method and params,
//! and the usage errors cmux reports before contacting the app.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const g = @import("grammar.zig");
const plan_mod = @import("plan.zig");

const T = struct {
    arena_state: std.heap.ArenaAllocator,
    base: plan_mod.Inputs = .{ .verb = "" },

    fn init() T {
        return .{ .arena_state = std.heap.ArenaAllocator.init(testing.allocator), .base = .{
            .verb = "",
            .cwd = "/work",
            .home = "/home/u",
            .style = .posix,
            .caller_workspace = "WS-CALLER",
        } };
    }

    fn deinit(self: *T) void {
        self.arena_state.deinit();
    }

    /// Plans `browser <args>`.
    fn plan(self: *T, args: []const []const u8, diag: *g.Diag) g.Error!plan_mod.Plan {
        const a = self.arena_state.allocator();
        const t = try g.splitTarget(a, args, diag);
        var in = self.base;
        in.verb = t.verb orelse return error.Usage;
        in.rest = t.rest;
        in.surface = t.surface;
        in.surface_positional = t.surface_positional;
        in.workspace = t.workspace;
        in.window = t.window;
        return plan_mod.plan(a, in, diag);
    }

    /// Expects a call of `method` whose minified params equal `params`.
    fn expectCall(self: *T, args: []const []const u8, method: []const u8, params: []const u8) !void {
        var d: g.Diag = .{};
        const p = self.plan(args, &d) catch |err| {
            std.debug.print("unexpected {s}: {s}\n", .{ @errorName(err), d.message });
            return err;
        };
        const c = p.call;
        try testing.expectEqualStrings(method, c.method);
        const json = try std.json.Stringify.valueAlloc(self.arena_state.allocator(), std.json.Value{ .object = c.params }, .{});
        try testing.expectEqualStrings(params, json);
    }

    fn expectUsage(self: *T, args: []const []const u8, message: []const u8) !void {
        var d: g.Diag = .{};
        try testing.expectError(error.Usage, self.plan(args, &d));
        try testing.expectEqualStrings(message, d.message);
    }

    fn call(self: *T, args: []const []const u8) !plan_mod.Call {
        var d: g.Diag = .{};
        return (try self.plan(args, &d)).call;
    }
};

test "unit: browser-cli: open uses the caller workspace and never focuses by default" {
    var t = T.init();
    defer t.deinit();
    try t.expectCall(&.{ "open", "https://example.com" }, "browser.open_split", "{\"url\":\"https://example.com\",\"workspace_id\":\"WS-CALLER\",\"focus\":false}");
    try t.expectCall(&.{"new"}, "browser.open_split", "{\"workspace_id\":\"WS-CALLER\",\"focus\":false}");
    try t.expectCall(&.{ "open-split", "rust", "docs", "--window", "window:2", "--focus", "true", "--profile", "work" }, "browser.open_split", "{\"url\":\"rust docs\",\"window_id\":\"window:2\",\"profile\":\"work\",\"focus\":true}");
    try t.expectCall(&.{ "--surface", "surface:4", "open", "x.dev" }, "browser.open_split", "{\"url\":\"x.dev\",\"surface_id\":\"surface:4\",\"workspace_id\":\"WS-CALLER\",\"focus\":false}");
    // A positional surface turns open into navigate.
    try t.expectCall(&.{ "surface:2", "open", "https://a.b" }, "browser.navigate", "{\"surface_id\":\"surface:2\",\"url\":\"https://a.b\"}");
    try t.expectUsage(&.{ "open", "--x" }, "browser open does not support --x");
    try t.expectUsage(&.{ "open", "--focus", "yes" }, "--focus must be true or false");
}

test "unit: browser-cli: surface verbs require a surface and never retarget" {
    var t = T.init();
    defer t.deinit();
    try t.expectUsage(&.{ "click", "#x" }, "browser click requires a surface handle (use: browser <surface> click ... or --surface)");
    try t.expectUsage(&.{"url"}, "browser url requires a surface handle (use: browser <surface> url ... or --surface)");
    try t.expectUsage(&.{"download"}, "browser download requires a surface handle");
    try t.expectCall(&.{ "surface:2", "url" }, "browser.url.get", "{\"surface_id\":\"surface:2\"}");
    try t.expectCall(&.{ "url", "--surface", "surface:2" }, "browser.url.get", "{\"surface_id\":\"surface:2\"}");
    try t.expectCall(&.{ "get-url", "--panel", "3" }, "browser.url.get", "{\"surface_id\":\"3\"}");
    try t.expectUsage(&.{ "surface:2", "url", "--surface", "surface:3" }, "browser url: --surface surface:3 conflicts with surface surface:2 given before the subcommand");
    try t.expectUsage(&.{ "surface:2", "url", "extra" }, "browser url: unexpected argument 'extra'");
    try t.expectUsage(&.{ "surface:2", "drag", "a", "b" }, "browser drag is not supported by the cmux CLI");
}

test "unit: browser-cli: navigation verbs and snapshot-after" {
    var t = T.init();
    defer t.deinit();
    try t.expectCall(&.{ "surface:1", "goto", "https://x.y" }, "browser.navigate", "{\"surface_id\":\"surface:1\",\"url\":\"https://x.y\"}");
    try t.expectCall(&.{ "surface:1", "navigate", "x.y", "--snapshot-after" }, "browser.navigate", "{\"surface_id\":\"surface:1\",\"snapshot_after\":true,\"url\":\"x.y\"}");
    try testing.expectEqual(@as(?u32, 35_000), (try t.call(&.{ "surface:1", "back", "--snapshot-after" })).timeout_ms);
    try t.expectCall(&.{ "surface:1", "forward" }, "browser.forward", "{\"surface_id\":\"surface:1\"}");
    try t.expectCall(&.{ "surface:1", "reload" }, "browser.reload", "{\"surface_id\":\"surface:1\"}");
    try t.expectUsage(&.{ "surface:1", "goto" }, "browser goto requires a URL");
    try t.expectUsage(&.{ "surface:1", "navigate", "  " }, "browser navigate requires a URL");
    try t.expectUsage(&.{ "surface:1", "goto", "--new-tab", "x" }, "browser goto does not support --new-tab");
    try t.expectUsage(&.{ "surface:1", "url", "--snapshot-after" }, "browser url does not support --snapshot-after");
    try t.expectCall(&.{ "surface:1", "focus-webview" }, "browser.focus_webview", "{\"surface_id\":\"surface:1\"}");
    try t.expectCall(&.{ "surface:1", "is_webview_focused" }, "browser.is_webview_focused", "{\"surface_id\":\"surface:1\"}");
}

test "unit: browser-cli: snapshot options" {
    var t = T.init();
    defer t.deinit();
    try t.expectCall(&.{ "surface:1", "snapshot" }, "browser.snapshot", "{\"surface_id\":\"surface:1\",\"interactive\":false,\"cursor\":false,\"compact\":false}");
    try t.expectCall(&.{ "surface:1", "snapshot", "-i", "--compact", "--cursor", "--max-depth", "3", "-s", "#main" }, "browser.snapshot", "{\"surface_id\":\"surface:1\",\"interactive\":true,\"cursor\":true,\"compact\":true,\"max_depth\":3,\"selector\":\"#main\"}");
    try t.expectUsage(&.{ "surface:1", "snapshot", "--max-depth", "-1" }, "browser snapshot --max-depth must be a non-negative integer");
    try t.expectUsage(&.{ "surface:1", "snapshot", "--max-depth", "deep" }, "browser snapshot --max-depth must be a non-negative integer");
}

test "unit: browser-cli: eval joins words and requires a script" {
    var t = T.init();
    defer t.deinit();
    try t.expectCall(&.{ "surface:1", "eval", "1", "+", "1" }, "browser.eval", "{\"surface_id\":\"surface:1\",\"script\":\"1 + 1\"}");
    try t.expectCall(&.{ "surface:1", "eval", "--script", "document.title" }, "browser.eval", "{\"surface_id\":\"surface:1\",\"script\":\"document.title\"}");
    try t.expectCall(&.{ "surface:1", "eval", "--", "--x", "\u{1F600}" }, "browser.eval", "{\"surface_id\":\"surface:1\",\"script\":\"--x \u{1F600}\"}");
    try t.expectUsage(&.{ "surface:1", "eval" }, "browser eval requires a script");
    try t.expectUsage(&.{ "surface:1", "eval", " " }, "browser eval requires a script");
    try t.expectUsage(&.{ "surface:1", "addstyle" }, "browser addstyle requires content");
    try t.expectCall(&.{ "surface:1", "addstyle", "--css", "a{}" }, "browser.addstyle", "{\"surface_id\":\"surface:1\",\"css\":\"a{}\"}");
    try t.expectCall(&.{ "surface:1", "addinitscript", "window.x=1" }, "browser.addinitscript", "{\"surface_id\":\"surface:1\",\"script\":\"window.x=1\"}");
}

test "unit: browser-cli: wait conditions and deadline" {
    var t = T.init();
    defer t.deinit();
    try t.expectCall(&.{ "surface:1", "wait", "#ready" }, "browser.wait", "{\"surface_id\":\"surface:1\",\"selector\":\"#ready\"}");
    try t.expectCall(&.{ "surface:1", "wait", "--text", "Welcome", "--timeout-ms", "2000" }, "browser.wait", "{\"surface_id\":\"surface:1\",\"text_contains\":\"Welcome\",\"timeout_ms\":2000}");
    try t.expectCall(&.{ "surface:1", "wait", "--url", "/done", "--load-state", "complete", "--timeout", "1.5" }, "browser.wait", "{\"surface_id\":\"surface:1\",\"url_contains\":\"/done\",\"load_state\":\"complete\",\"timeout_ms\":1500}");
    try testing.expectEqual(@as(?u32, 15_000), (try t.call(&.{ "surface:1", "wait", "--function", "ok()" })).timeout_ms);
    try testing.expectEqual(@as(?u32, 68_000), (try t.call(&.{ "surface:1", "wait", "--timeout", "60" })).timeout_ms);
    try t.expectUsage(&.{ "surface:1", "wait", "--load-state", "idle" }, "browser wait --load-state must be interactive or complete");
    try t.expectUsage(&.{ "surface:1", "wait", "--timeout-ms", "soon" }, "browser wait --timeout-ms must be a non-negative integer");
    try t.expectUsage(&.{ "surface:1", "wait", "--timeout", "nan" }, "browser wait --timeout must be a number of seconds");
    try t.expectUsage(&.{ "surface:1", "wait", "a", "b" }, "browser wait: unexpected argument 'b'");
}

test "unit: browser-cli: element actions, typing, keys, select and scroll" {
    var t = T.init();
    defer t.deinit();
    try t.expectCall(&.{ "surface:1", "click", "@e3", "--snapshot-after" }, "browser.click", "{\"surface_id\":\"surface:1\",\"snapshot_after\":true,\"selector\":\"@e3\"}");
    try t.expectCall(&.{ "surface:1", "dblclick", "--selector", "#a" }, "browser.dblclick", "{\"surface_id\":\"surface:1\",\"selector\":\"#a\"}");
    try t.expectCall(&.{ "surface:1", "scrollinto", "#a" }, "browser.scroll_into_view", "{\"surface_id\":\"surface:1\",\"selector\":\"#a\"}");
    try t.expectCall(&.{ "surface:1", "highlight", "#a" }, "browser.highlight", "{\"surface_id\":\"surface:1\",\"selector\":\"#a\"}");
    try t.expectUsage(&.{ "surface:1", "check" }, "browser check requires a selector");
    try t.expectUsage(&.{ "surface:1", "hover", "#a", "#b" }, "browser hover: unexpected argument '#b'");
    try t.expectCall(&.{ "surface:1", "type", "#q", "hello", "world" }, "browser.type", "{\"surface_id\":\"surface:1\",\"selector\":\"#q\",\"text\":\"hello world\"}");
    try t.expectUsage(&.{ "surface:1", "type", "#q" }, "browser type requires text");
    try t.expectCall(&.{ "surface:1", "fill", "#email", "--text", "a@b.c" }, "browser.fill", "{\"surface_id\":\"surface:1\",\"selector\":\"#email\",\"text\":\"a@b.c\"}");
    try t.expectCall(&.{ "surface:1", "fill", "#email", "" }, "browser.fill", "{\"surface_id\":\"surface:1\",\"selector\":\"#email\",\"text\":\"\"}");
    try t.expectCall(&.{ "surface:1", "fill", "#email" }, "browser.fill", "{\"surface_id\":\"surface:1\",\"selector\":\"#email\",\"text\":\"\"}");
    try t.expectCall(&.{ "surface:1", "key", "Enter" }, "browser.press", "{\"surface_id\":\"surface:1\",\"key\":\"Enter\"}");
    try t.expectCall(&.{ "surface:1", "keydown", "--key", " " }, "browser.keydown", "{\"surface_id\":\"surface:1\",\"key\":\" \"}");
    try t.expectCall(&.{ "surface:1", "keyup", "Shift" }, "browser.keyup", "{\"surface_id\":\"surface:1\",\"key\":\"Shift\"}");
    try t.expectUsage(&.{ "surface:1", "press" }, "browser press requires a key");
    try t.expectCall(&.{ "surface:1", "select", "#region", "us-east" }, "browser.select", "{\"surface_id\":\"surface:1\",\"selector\":\"#region\",\"value\":\"us-east\"}");
    try t.expectCall(&.{ "surface:1", "select", "#region", "--value", "" }, "browser.select", "{\"surface_id\":\"surface:1\",\"selector\":\"#region\",\"value\":\"\"}");
    try t.expectUsage(&.{ "surface:1", "select", "#region" }, "browser select requires a value");
    try t.expectCall(&.{ "surface:1", "scroll", "--dy", "800" }, "browser.scroll", "{\"surface_id\":\"surface:1\",\"dy\":800}");
    try t.expectCall(&.{ "surface:1", "scroll", "-200", "--dx", "5", "--selector", ".list" }, "browser.scroll", "{\"surface_id\":\"surface:1\",\"selector\":\".list\",\"dx\":5,\"dy\":-200}");
    try t.expectUsage(&.{ "surface:1", "scroll", "--dx", "1.5" }, "--dx must be an integer");
    try t.expectUsage(&.{ "surface:1", "scroll", "down" }, "--dy must be an integer");
}

test "unit: browser-cli: set-input-files paths and limits" {
    var t = T.init();
    defer t.deinit();
    try t.expectCall(&.{ "surface:1", "set-input-files", "--selector", "#f", "--file", "a.txt", "--file", "~/b.png", "--file", "/abs/c" }, "browser.set_input_files", "{\"surface_id\":\"surface:1\",\"selector\":\"#f\",\"files\":[\"/work/a.txt\",\"/home/u/b.png\",\"/abs/c\"]}");
    const c = try t.call(&.{ "surface:1", "set-input-files", "--selector", "#f", "--file", "a" });
    try testing.expect(c.check_uploads);
    try testing.expectEqual(@as(?u32, 25_000), c.timeout_ms);
    try t.expectCall(&.{ "surface:1", "set-input-files", "--selector", "#f", "--clear" }, "browser.set_input_files", "{\"surface_id\":\"surface:1\",\"selector\":\"#f\",\"files\":[]}");
    const usage = "set-input-files requires --selector <css> and either --file <path> (repeatable) or --clear";
    try t.expectUsage(&.{ "surface:1", "set-input-files", "--file", "a" }, usage);
    try t.expectUsage(&.{ "surface:1", "set-input-files", "--selector", "#f" }, usage);
    try t.expectUsage(&.{ "surface:1", "set-input-files", "--selector", "#f", "--clear", "--file", "a" }, usage);
    var many: std.ArrayList([]const u8) = .empty;
    const a = t.arena_state.allocator();
    try many.appendSlice(a, &.{ "surface:1", "set-input-files", "--selector", "#f" });
    for (0..129) |_| try many.appendSlice(a, &.{ "--file", "x" });
    try t.expectUsage(many.items, "Select at most 128 files using absolute paths");
    try t.expectUsage(&.{ "surface:1", "set-input-files", "--selector", "#f", "--file", "" }, "Every upload path must be a readable regular file");
}

test "unit: browser-cli: windows paths are absolutized with the windows style" {
    var t = T.init();
    defer t.deinit();
    t.base.style = .windows;
    t.base.cwd = "C:\\work";
    t.base.home = "C:\\Users\\u";
    try t.expectCall(&.{ "surface:1", "state", "save", "s.json" }, "browser.state.save", "{\"surface_id\":\"surface:1\",\"path\":\"C:\\\\work\\\\s.json\"}");
    try t.expectCall(&.{ "surface:1", "state", "load", "~\\s.json" }, "browser.state.load", "{\"surface_id\":\"surface:1\",\"path\":\"C:\\\\Users\\\\u\\\\s.json\"}");
    try t.expectCall(&.{ "surface:1", "state", "load", "D:/x.json" }, "browser.state.load", "{\"surface_id\":\"surface:1\",\"path\":\"D:/x.json\"}");
    try testing.expect(plan_mod.isAbsolute(.windows, "\\\\server\\share"));
    try testing.expect(!plan_mod.isAbsolute(.windows, "C:rel"));
    try testing.expect(!plan_mod.isAbsolute(.posix, "C:\\x"));
}

test "unit: browser-cli: get, is and find" {
    var t = T.init();
    defer t.deinit();
    try t.expectCall(&.{ "surface:1", "get", "url" }, "browser.url.get", "{\"surface_id\":\"surface:1\"}");
    try t.expectCall(&.{ "surface:1", "get", "title" }, "browser.get.title", "{\"surface_id\":\"surface:1\"}");
    try t.expectCall(&.{ "surface:1", "get", "count", ".row" }, "browser.get.count", "{\"surface_id\":\"surface:1\",\"selector\":\".row\"}");
    try t.expectCall(&.{ "surface:1", "get", "attr", "#a", "href" }, "browser.get.attr", "{\"surface_id\":\"surface:1\",\"selector\":\"#a\",\"attr\":\"href\"}");
    try t.expectCall(&.{ "surface:1", "get", "attr", "--selector", "#a", "--attr", "href" }, "browser.get.attr", "{\"surface_id\":\"surface:1\",\"selector\":\"#a\",\"attr\":\"href\"}");
    try t.expectCall(&.{ "surface:1", "get", "styles", "#a", "--property", "color" }, "browser.get.styles", "{\"surface_id\":\"surface:1\",\"selector\":\"#a\",\"property\":\"color\"}");
    try t.expectUsage(&.{ "surface:1", "get", "attr", "#a" }, "browser get attr requires --attr <name>");
    try t.expectUsage(&.{ "surface:1", "get", "text" }, "browser get text requires a selector");
    try t.expectUsage(&.{ "surface:1", "get", "pixels", "#a" }, "Unsupported browser get subcommand: pixels");
    try t.expectUsage(&.{ "surface:1", "get" }, "browser get requires a subcommand: url, title, text, html, value, attr, count, box, styles");
    try t.expectUsage(&.{ "surface:1", "get", "box", "#a", "#b" }, "browser get box: unexpected argument '#b'");
    try t.expectCall(&.{ "surface:1", "is", "enabled", "button[disabled]" }, "browser.is.enabled", "{\"surface_id\":\"surface:1\",\"selector\":\"button[disabled]\"}");
    try t.expectUsage(&.{ "surface:1", "is", "hidden", "#a" }, "browser is requires one of: visible, enabled, checked");
    try t.expectCall(&.{ "surface:1", "find", "role", "button", "--name", "Continue" }, "browser.find.role", "{\"surface_id\":\"surface:1\",\"role\":\"button\",\"name\":\"Continue\",\"exact\":false}");
    try t.expectCall(&.{ "surface:1", "find", "testid", "--exact", "save-btn" }, "browser.find.testid", "{\"surface_id\":\"surface:1\",\"testid\":\"save-btn\",\"exact\":true}");
    try t.expectCall(&.{ "surface:1", "find", "text", "Sign", "in" }, "browser.find.text", "{\"surface_id\":\"surface:1\",\"text\":\"Sign in\",\"exact\":false}");
    try t.expectCall(&.{ "surface:1", "find", "nth", "2", ".row" }, "browser.find.nth", "{\"surface_id\":\"surface:1\",\"index\":2,\"selector\":\".row\"}");
    try t.expectCall(&.{ "surface:1", "find", "last", "--selector", "li" }, "browser.find.last", "{\"surface_id\":\"surface:1\",\"selector\":\"li\"}");
    try t.expectUsage(&.{ "surface:1", "find", "nth", "x", ".row" }, "browser find nth requires an integer index");
    try t.expectUsage(&.{ "surface:1", "find", "css", "a" }, "browser find requires a locator: role, text, label, placeholder, alt, title, testid, first, last, nth");
}

test "unit: browser-cli: frame, dialog and screenshot" {
    var t = T.init();
    defer t.deinit();
    try t.expectCall(&.{ "surface:1", "frame", "main" }, "browser.frame.main", "{\"surface_id\":\"surface:1\"}");
    try t.expectCall(&.{ "surface:1", "frame", "iframe[name='checkout']" }, "browser.frame.select", "{\"surface_id\":\"surface:1\",\"selector\":\"iframe[name='checkout']\"}");
    try t.expectUsage(&.{ "surface:1", "frame" }, "browser frame requires <selector|main>");
    try t.expectCall(&.{ "surface:1", "dialog", "accept", "Bob", "Smith" }, "browser.dialog.accept", "{\"surface_id\":\"surface:1\",\"text\":\"Bob Smith\"}");
    try t.expectCall(&.{ "surface:1", "dialog", "accept", "" }, "browser.dialog.accept", "{\"surface_id\":\"surface:1\",\"text\":\"\"}");
    try t.expectCall(&.{ "surface:1", "dialog", "accept" }, "browser.dialog.accept", "{\"surface_id\":\"surface:1\"}");
    try t.expectCall(&.{ "surface:1", "dialog", "dismiss" }, "browser.dialog.dismiss", "{\"surface_id\":\"surface:1\"}");
    try t.expectUsage(&.{ "surface:1", "dialog" }, "browser dialog requires accept|dismiss");
    const s = try t.call(&.{ "surface:1", "screenshot", "--out", "shots/p.png" });
    try testing.expectEqualStrings("/work/shots/p.png", s.out_path.?);
    try t.expectCall(&.{ "surface:1", "screenshot" }, "browser.screenshot", "{\"surface_id\":\"surface:1\"}");
}

test "unit: browser-cli: downloads, cookies, storage and state" {
    var t = T.init();
    defer t.deinit();
    try t.expectCall(&.{ "surface:1", "download", "--path", "r.csv", "--timeout-ms", "30000" }, "browser.download.wait", "{\"surface_id\":\"surface:1\",\"path\":\"/work/r.csv\",\"timeout_ms\":30000}");
    try testing.expectEqual(@as(?u32, 38_000), (try t.call(&.{ "surface:1", "download", "wait", "--timeout", "30" })).timeout_ms);
    try t.expectCall(&.{ "surface:1", "download", "wait", "/tmp/x" }, "browser.download.wait", "{\"surface_id\":\"surface:1\",\"path\":\"/tmp/x\"}");
    try t.expectCall(&.{ "surface:1", "download", "list", "--limit", "5" }, "browser.download.list", "{\"surface_id\":\"surface:1\",\"limit\":5}");
    try t.expectCall(&.{ "surface:1", "download", "ls" }, "browser.download.list", "{\"surface_id\":\"surface:1\"}");
    try t.expectUsage(&.{ "surface:1", "download", "list", "--limit", "26" }, "--limit must be an integer from 1 to 25");
    try t.expectUsage(&.{ "surface:1", "download", "list", "--limit", "0" }, "--limit must be an integer from 1 to 25");
    try t.expectUsage(&.{ "surface:1", "download", "list", "--limit", "2", "--limit", "3" }, "--limit may only be given once");
    try t.expectCall(&.{ "surface:1", "cookies" }, "browser.cookies.get", "{\"surface_id\":\"surface:1\"}");
    try t.expectCall(&.{ "surface:1", "cookies", "get", "--name", "sid", "--domain", "example" }, "browser.cookies.get", "{\"surface_id\":\"surface:1\",\"name\":\"sid\",\"domain\":\"example\"}");
    try t.expectCall(&.{ "surface:1", "cookies", "set", "session_id", "abc", "--domain", "example.com", "--path", "/", "--http-only", "--expires", "1700000000" }, "browser.cookies.set", "{\"surface_id\":\"surface:1\",\"name\":\"session_id\",\"value\":\"abc\",\"domain\":\"example.com\",\"path\":\"/\",\"http_only\":true,\"expires\":1700000000}");
    try t.expectCall(&.{ "surface:1", "cookies", "set", "--name", "a", "--value", "" }, "browser.cookies.set", "{\"surface_id\":\"surface:1\",\"name\":\"a\",\"value\":\"\"}");
    try t.expectUsage(&.{ "surface:1", "cookies", "set", "a" }, "browser cookies set requires <name> <value> (or --name/--value)");
    try t.expectUsage(&.{ "surface:1", "cookies", "set", "a", "b", "--expires", "soon" }, "browser cookies --expires must be an integer");
    try t.expectUsage(&.{ "surface:1", "cookies", "clear" }, "browser cookies clear requires a scope: --url, --domain, --name, --path, or --all");
    try t.expectCall(&.{ "surface:1", "cookies", "clear", "--all" }, "browser.cookies.clear", "{\"surface_id\":\"surface:1\",\"all\":true}");
    try t.expectCall(&.{ "surface:1", "cookies", "clear", "--url", "https://x.y/" }, "browser.cookies.clear", "{\"surface_id\":\"surface:1\",\"url\":\"https://x.y/\"}");
    try t.expectCall(&.{ "surface:1", "storage" }, "browser.storage.get", "{\"surface_id\":\"surface:1\",\"type\":\"local\"}");
    try t.expectCall(&.{ "surface:1", "storage", "local", "set", "theme", "dark" }, "browser.storage.set", "{\"surface_id\":\"surface:1\",\"type\":\"local\",\"key\":\"theme\",\"value\":\"dark\"}");
    try t.expectCall(&.{ "surface:1", "storage", "session", "get", "__proto__" }, "browser.storage.get", "{\"surface_id\":\"surface:1\",\"type\":\"session\",\"key\":\"__proto__\"}");
    try t.expectCall(&.{ "surface:1", "storage", "clear" }, "browser.storage.clear", "{\"surface_id\":\"surface:1\",\"type\":\"local\"}");
    try t.expectUsage(&.{ "surface:1", "storage", "cookie", "get" }, "browser storage requires type: local|session");
    try t.expectUsage(&.{ "surface:1", "storage", "local", "set", "k" }, "browser storage set requires <key> <value>");
    try t.expectUsage(&.{ "surface:1", "state", "save" }, "browser state save requires a file path");
    try t.expectUsage(&.{ "surface:1", "state" }, "browser state requires save|load <path>");
}

test "unit: browser-cli: tabs, console, errors and emulation" {
    var t = T.init();
    defer t.deinit();
    try t.expectCall(&.{ "surface:1", "tab" }, "browser.tab.list", "{\"surface_id\":\"surface:1\"}");
    try t.expectCall(&.{ "surface:1", "tab", "new", "https://x" }, "browser.tab.new", "{\"surface_id\":\"surface:1\",\"url\":\"https://x\"}");
    try t.expectCall(&.{ "surface:1", "tab", "1" }, "browser.tab.switch", "{\"surface_id\":\"surface:1\",\"index\":1}");
    try t.expectCall(&.{ "surface:1", "tab", "switch", "surface:7" }, "browser.tab.switch", "{\"surface_id\":\"surface:1\",\"target_surface_id\":\"surface:7\"}");
    try t.expectCall(&.{ "surface:1", "tab", "close", "surface:7" }, "browser.tab.close", "{\"surface_id\":\"surface:1\",\"target_surface_id\":\"surface:7\"}");
    try t.expectCall(&.{ "surface:1", "tab", "close" }, "browser.tab.close", "{\"surface_id\":\"surface:1\"}");
    try t.expectUsage(&.{ "surface:1", "tab", "switch", "pane:2" }, "Invalid surface handle: pane:2 (expected UUID, ref like surface:1, or index)");
    try t.expectCall(&.{ "surface:1", "console" }, "browser.console.list", "{\"surface_id\":\"surface:1\"}");
    try t.expectCall(&.{ "surface:1", "console", "clear" }, "browser.console.clear", "{\"surface_id\":\"surface:1\"}");
    try t.expectCall(&.{ "surface:1", "errors", "clear" }, "browser.errors.list", "{\"surface_id\":\"surface:1\",\"clear\":true}");
    try t.expectUsage(&.{ "surface:1", "errors", "show" }, "browser errors requires list|clear");
    try t.expectCall(&.{ "surface:1", "viewport", "375", "812" }, "browser.viewport.set", "{\"surface_id\":\"surface:1\",\"width\":375,\"height\":812}");
    try t.expectCall(&.{ "surface:1", "viewport", "reset" }, "browser.viewport.set", "{\"surface_id\":\"surface:1\",\"reset\":true}");
    try t.expectUsage(&.{ "surface:1", "viewport", "reset", "1" }, "browser viewport requires: <width> <height> | reset");
    try t.expectUsage(&.{ "surface:1", "viewport", "4097", "10" }, "browser viewport width and height must be integers from 1 to 4096");
    try t.expectUsage(&.{ "surface:1", "viewport", "0", "10" }, "browser viewport width and height must be integers from 1 to 4096");
    try t.expectCall(&.{ "surface:1", "geo", "48.85", "2.35" }, "browser.geolocation.set", "{\"surface_id\":\"surface:1\",\"latitude\":48.85,\"longitude\":2.35}");
    try t.expectCall(&.{ "surface:1", "geolocation", "-33.9", "-151.2", "10" }, "browser.geolocation.set", "{\"surface_id\":\"surface:1\",\"latitude\":-33.9,\"longitude\":-151.2,\"accuracy\":10}");
    try t.expectCall(&.{ "surface:1", "geo", "clear" }, "browser.geolocation.set", "{\"surface_id\":\"surface:1\",\"clear\":true}");
    try t.expectUsage(&.{ "surface:1", "geo", "91", "0" }, "browser geolocation requires: <latitude> <longitude>");
    try t.expectUsage(&.{ "surface:1", "geo", "1" }, "browser geolocation requires: <latitude> <longitude>");
    try t.expectCall(&.{ "surface:1", "offline", "true" }, "browser.offline.set", "{\"surface_id\":\"surface:1\",\"enabled\":true}");
    try t.expectUsage(&.{ "surface:1", "offline", "on" }, "browser offline requires true|false");
}

test "unit: browser-cli: unsupported families keep cmux grammar" {
    var t = T.init();
    defer t.deinit();
    try t.expectCall(&.{ "surface:1", "trace", "start" }, "browser.trace.start", "{\"surface_id\":\"surface:1\"}");
    try t.expectCall(&.{ "surface:1", "trace", "stop", "/t/trace.zip" }, "browser.trace.stop", "{\"surface_id\":\"surface:1\",\"path\":\"/t/trace.zip\"}");
    try t.expectCall(&.{ "surface:1", "network", "route", "**/api", "--abort" }, "browser.network.route", "{\"surface_id\":\"surface:1\",\"pattern\":\"**/api\",\"abort\":true}");
    try t.expectCall(&.{ "surface:1", "network", "requests" }, "browser.network.requests", "{\"surface_id\":\"surface:1\"}");
    try t.expectCall(&.{ "surface:1", "screencast", "stop" }, "browser.screencast.stop", "{\"surface_id\":\"surface:1\"}");
    try t.expectCall(&.{ "surface:1", "input", "mouse", "move", "10", "20" }, "browser.input_mouse", "{\"surface_id\":\"surface:1\",\"args\":[\"move\",\"10\",\"20\"]}");
    try t.expectCall(&.{ "surface:1", "input_touch" }, "browser.input_touch", "{\"surface_id\":\"surface:1\",\"args\":[]}");
    try t.expectUsage(&.{ "surface:1", "network", "unroute" }, "browser network unroute requires <pattern>");
    try t.expectUsage(&.{ "surface:1", "trace", "--abort", "start" }, "browser trace does not support --abort");
    try t.expectUsage(&.{ "surface:1", "input", "pen" }, "browser input requires mouse|keyboard|touch");
}

test "unit: browser-cli: surface-less verbs: profiles, import, view verbs, local verbs" {
    var t = T.init();
    defer t.deinit();
    try t.expectCall(&.{"profiles"}, "browser.profiles.list", "{}");
    try t.expectCall(&.{ "profile", "ls" }, "browser.profiles.list", "{}");
    try t.expectCall(&.{ "profiles", "create", "work" }, "browser.profiles.create", "{\"name\":\"work\"}");
    try t.expectCall(&.{ "profiles", "rename", "work", "job" }, "browser.profiles.rename", "{\"profile\":\"work\",\"new_name\":\"job\"}");
    try t.expectCall(&.{ "profiles", "rename", "--profile", "work", "--name", "My Job" }, "browser.profiles.rename", "{\"profile\":\"work\",\"new_name\":\"My Job\"}");
    try t.expectCall(&.{ "profiles", "clear", "--all", "--force" }, "browser.profiles.clear", "{\"all\":true,\"force\":true}");
    try t.expectCall(&.{ "profiles", "clear", "work" }, "browser.profiles.clear", "{\"profile\":\"work\",\"force\":false}");
    try t.expectCall(&.{ "profiles", "rm", "job" }, "browser.profiles.delete", "{\"profile\":\"job\"}");
    try t.expectUsage(&.{ "profiles", "clear" }, "browser profiles clear requires <profile> or --all");
    try t.expectUsage(&.{ "profiles", "add" }, "browser profiles add requires a name");
    try t.expectUsage(&.{ "profiles", "frob" }, "browser profiles requires one of: list, add, rename, clear, delete");
    try t.expectCall(&.{"import"}, "browser.import.dialog", "{}");
    try t.expectCall(&.{ "import", "-y", "--from", "chrome", "--domain", "github.com,gitlab.com", "--profile", "Default" }, "browser.import.cookies", "{\"scope\":\"cookiesOnly\",\"browser\":\"chrome\",\"source_profiles\":[\"Default\"],\"domain_filters\":[\"github.com\",\"gitlab.com\"],\"all_profiles\":false,\"create_destination_profile\":false}");
    t.base.agent = true;
    const imp = try t.call(&.{ "import", "--from", "edge", "--to", "work", "--create-profile" });
    try testing.expectEqualStrings("browser.import.cookies", imp.method);
    try testing.expectEqual(@as(?u32, 600_000), imp.timeout_ms);
    try t.expectCall(&.{ "import", "--interactive" }, "browser.import.dialog", "{}");
    try t.expectUsage(&.{ "import", "--interactive", "--yes" }, "browser import: --interactive and --non-interactive cannot be used together");
    try t.expectUsage(&.{ "import", "cookies" }, "browser import no longer takes a data type");
    t.base.agent = false;
    try t.expectUsage(&.{ "import", "--from", "chrome" }, "browser import: --from requires --non-interactive");
    try t.expectCall(&.{ "design-mode", "enable" }, "browser.design_mode.set", "{\"workspace_id\":\"WS-CALLER\",\"mode\":\"enable\"}");
    try t.expectCall(&.{"design-mode"}, "browser.design_mode.status", "{\"workspace_id\":\"WS-CALLER\"}");
    try t.expectCall(&.{ "--surface", "surface:3", "design-mode", "toggle" }, "browser.design_mode.set", "{\"surface_id\":\"surface:3\",\"workspace_id\":\"WS-CALLER\",\"mode\":\"toggle\"}");
    try t.expectUsage(&.{ "design-mode", "on" }, "browser design-mode requires one of: enable, disable, toggle, status");
    try t.expectCall(&.{ "zoom", "1.25", "--window", "window:1" }, "browser.zoom.set", "{\"window_id\":\"window:1\",\"factor\":1.25}");
    try t.expectCall(&.{ "zoom", "in", "--workspace", "workspace:2" }, "browser.zoom.set", "{\"workspace_id\":\"workspace:2\",\"action\":\"in\"}");
    try t.expectCall(&.{ "focus-mode", "on" }, "browser.focus_mode.set", "{\"workspace_id\":\"WS-CALLER\",\"mode\":\"enter\"}");
    try t.expectCall(&.{ "devtools", "console" }, "browser.console.show", "{\"workspace_id\":\"WS-CALLER\"}");
    try t.expectCall(&.{ "react-grab", "toggle", "--return-to", "surface:9" }, "browser.react_grab.toggle", "{\"workspace_id\":\"WS-CALLER\",\"return_to_surface_id\":\"surface:9\"}");
    try t.expectUsage(&.{ "history", "clear" }, "browser history clear permanently deletes history; pass --force (or --yes) to confirm");
    try t.expectCall(&.{ "history", "clear", "--yes" }, "browser.history.clear", "{\"workspace_id\":\"WS-CALLER\"}");
    try t.expectCall(&.{ "repl", "await", "page.title()" }, "browser.repl.eval", "{\"workspace_id\":\"WS-CALLER\",\"script\":\"await page.title()\"}");
    try t.expectCall(&.{ "repl", "reset" }, "browser.repl.reset", "{\"workspace_id\":\"WS-CALLER\"}");
    var d: g.Diag = .{};
    try testing.expectEqual(plan_mod.Local.repl_guide, (try t.plan(&.{ "repl", "guide" }, &d)).local);
    try testing.expectEqual(plan_mod.Local.disable, (try t.plan(&.{"disable"}, &d)).local);
    try testing.expectEqual(plan_mod.Local.help, (try t.plan(&.{"help"}, &d)).local);
    try t.expectUsage(&.{ "status", "x" }, "Unexpected argument: x");
    try testing.expectEqualStrings("surface:2", (try t.plan(&.{ "identify", "--surface", "surface:2" }, &d)).identify.?);
    try testing.expectEqual(@as(?[]const u8, null), (try t.plan(&.{"identify"}, &d)).identify);
}
