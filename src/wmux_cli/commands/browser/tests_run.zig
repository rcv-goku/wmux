//! `browser` family round trips: targeting, params on the wire, output.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const fake = @import("../../fake.zig");
const t = @import("tests.zig");
const Harness = t.Harness;
const expectContains = t.expectContains;
const expectGolden = t.expectGolden;
const contains = t.contains;

const snapshot_text = "- document \\\"Sign in\\\"\\n  - textbox \\\"Email\\\" [ref=e1]\\n  - textbox \\\"Password\\\" [ref=e2]\\n  - button \\\"Sign in\\\" [ref=e3]";

fn ok(server: *fake.Server, json: []const u8) fake.Action {
    _ = server;
    return .{ .ok = json };
}

fn param(req: fake.Request, key: []const u8) ?[]const u8 {
    const v = req.params.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// A scripted app: fixed results per method; `browser.*` methods it does
/// not know answer `{"surface_ref":"surface:2"}`.
pub fn appHandler(server: *fake.Server, req: fake.Request) fake.Action {
    const m = req.method;
    const eq = std.mem.eql;
    if (eq(u8, m, "system.ping")) return ok(server, "{\"pong\":true}");
    if (eq(u8, m, "system.identify")) return ok(server, "{\"focused\":{\"window_id\":\"W-UUID\",\"window_ref\":\"window:1\",\"workspace_id\":\"WS-UUID\",\"workspace_ref\":\"workspace:1\",\"pane_id\":\"P-UUID\",\"pane_ref\":\"pane:1\",\"surface_id\":\"S2-UUID\",\"surface_ref\":\"surface:2\",\"surface_type\":\"browser\"}}");
    if (eq(u8, m, "browser.open_split")) return ok(server, "{\"window_id\":\"W-UUID\",\"window_ref\":\"window:1\",\"workspace_id\":\"WS-UUID\",\"workspace_ref\":\"workspace:1\",\"pane_id\":\"P3-UUID\",\"pane_ref\":\"pane:3\",\"surface_id\":\"S5-UUID\",\"surface_ref\":\"surface:5\",\"created_split\":true,\"placement_strategy\":\"split_right\",\"url\":\"https://example.com/\"}");
    if (eq(u8, m, "browser.url.get")) return ok(server, "{\"surface_id\":\"S2-UUID\",\"surface_ref\":\"surface:2\",\"url\":\"https://example.com/\"}");
    if (eq(u8, m, "browser.get.title")) return ok(server, "{\"title\":\"Example Domain\"}");
    if (eq(u8, m, "browser.get.count")) return ok(server, "{\"count\":3}");
    if (eq(u8, m, "browser.get.box")) return ok(server, "{\"value\":{\"x\":8,\"y\":16,\"width\":120.5,\"height\":40}}");
    if (eq(u8, m, "browser.is.enabled")) return ok(server, "{\"value\":false}");
    if (eq(u8, m, "browser.is_webview_focused")) return ok(server, "{\"focused\":true}");
    if (eq(u8, m, "browser.snapshot")) return ok(server, "{\"snapshot\":\"" ++ snapshot_text ++ "\",\"title\":\"Sign in\",\"url\":\"https://example.com/login\",\"ready_state\":\"complete\",\"refs\":{\"e1\":{\"role\":\"textbox\",\"name\":\"Email\"}},\"surface_id\":\"S2-UUID\",\"surface_ref\":\"surface:2\"}");
    if (eq(u8, m, "browser.eval")) {
        const script = param(req, "script") orelse "";
        if (std.mem.startsWith(u8, script, "throw")) return .{ .err = "{\"code\":\"js_error\",\"message\":\"Error: x\"}" };
        if (eq(u8, script, "document.title")) return ok(server, "{\"value\":\"Example Domain\"}");
        if (eq(u8, script, "void 0")) return ok(server, "{}");
        return ok(server, "{\"value\":2}");
    }
    if (eq(u8, m, "browser.click")) {
        if (req.params.object.get("snapshot_after") != null) return ok(server, "{\"surface_ref\":\"surface:2\",\"post_action_snapshot\":\"- document \\\"Welcome\\\"\\n  - heading \\\"Welcome back\\\" [ref=e1]\",\"post_action_url\":\"https://example.com/home\"}");
        return ok(server, "{\"surface_ref\":\"surface:2\"}");
    }
    if (eq(u8, m, "browser.wait")) {
        if (param(req, "text_contains") != null) return .{ .err = "{\"code\":\"timeout\",\"message\":\"Condition not met before timeout\",\"data\":{\"timeout_ms\":2000}}" };
        return ok(server, "{\"waited\":true}");
    }
    if (eq(u8, m, "browser.download.list")) return ok(server, "{\"downloads\":[{\"download_id\":\"D-2\",\"filename\":\"report.csv\",\"path\":\"/dl/report.csv\",\"status\":\"saved\",\"bytes\":2048,\"path_exists\":true},{\"download_id\":\"D-1\",\"filename\":\"big.zip\",\"path\":null,\"status\":\"downloading\"}]}");
    if (eq(u8, m, "browser.console.list")) return ok(server, "{\"entries\":[{\"level\":\"warn\",\"text\":\"x\",\"timestamp_ms\":1},{\"level\":\"log\",\"text\":\"{\\\"a\\\":1} done\",\"timestamp_ms\":2}],\"count\":2}");
    if (eq(u8, m, "browser.errors.list")) return ok(server, "{\"errors\":[{\"message\":\"Uncaught TypeError: x is undefined\",\"source\":\"app.js\",\"line\":3,\"column\":7}],\"count\":1}");
    if (eq(u8, m, "browser.profiles.list")) return ok(server, "{\"profiles\":[{\"id\":\"PR-1\",\"name\":\"Default\",\"slug\":\"default\",\"is_default\":true},{\"id\":\"PR-2\",\"name\":\"Work\",\"slug\":\"work\",\"last_used\":true}]}");
    if (eq(u8, m, "browser.profiles.create")) return ok(server, "{\"profile\":{\"id\":\"PR-3\",\"name\":\"job\",\"slug\":\"job\"}}");
    if (eq(u8, m, "browser.profiles.clear")) {
        if (req.params.object.get("force").?.bool == false) return .{ .err = "{\"code\":\"invalid_state\",\"message\":\"Profile 'work' is in use by 1 open browser surface\",\"action\":\"pass --force to clear it anyway\"}" };
        return ok(server, "{\"cleared\":[{\"id\":\"PR-2\"}],\"cleared_history\":true}");
    }
    if (eq(u8, m, "browser.tab.list")) return ok(server, "{\"workspace_id\":\"WS-UUID\",\"workspace_ref\":\"workspace:1\",\"surface_id\":\"S2-UUID\",\"surface_ref\":\"surface:2\",\"tabs\":[{\"id\":\"S2-UUID\",\"ref\":\"surface:2\",\"index\":0,\"title\":\"Example Domain\",\"url\":\"https://example.com/\",\"focused\":true,\"pane_id\":\"P-UUID\",\"pane_ref\":\"pane:1\"},{\"id\":\"S7-UUID\",\"ref\":\"surface:7\",\"index\":1,\"title\":\"\",\"url\":\"https://x.dev/\",\"focused\":false}]}");
    if (eq(u8, m, "browser.design_mode.set") or eq(u8, m, "browser.design_mode.status")) return ok(server, "{\"enabled\":true,\"surface_ref\":\"surface:2\"}");
    if (eq(u8, m, "browser.import.cookies")) return ok(server, "{\"imported\":12,\"skipped\":2,\"browser\":\"chrome\",\"warnings\":[\"Chrome profile 'Work' is locked\"]}");
    if (eq(u8, m, "browser.screenshot")) return ok(server, "{\"png_base64\":\"iVBORw==\",\"path\":\"/tmp/wmux-browser-screenshots/surface-s2uuid-1.png\",\"url\":\"file:///tmp/wmux-browser-screenshots/surface-s2uuid-1.png\",\"surface_ref\":\"surface:2\"}");
    if (eq(u8, m, "browser.network.requests")) return .{ .err = "{\"code\":\"not_supported\",\"message\":\"browser.network.requests is not supported on WebView2 yet\",\"data\":{\"details\":\"request interception is not implemented\",\"recorded_requests\":[]}}" };
    if (std.mem.startsWith(u8, m, "browser.")) return ok(server, "{\"surface_ref\":\"surface:2\"}");
    return .{ .err = "{\"code\":\"method_not_found\",\"message\":\"Unknown method\"}" };
}

fn live(h: *Harness) !void {
    try h.init(appHandler);
}

test "unit: browser-cli: positional surface equals --surface (acceptance)" {
    var h: Harness = undefined;
    try live(&h);
    defer h.deinit();
    const a = h.run(&.{ "cmux", "browser", "surface:2", "url" });
    try testing.expectEqual(@as(u8, 0), a.code);
    try testing.expectEqualStrings("https://example.com/\n", a.out);
    try h.expectRequest("browser.url.get", "{\"surface_id\":\"surface:2\"}");
    const b = h.run(&.{ "cmux", "browser", "--surface", "surface:2", "url" });
    try testing.expectEqualStrings(a.out, b.out);
    try h.expectRequest("browser.url.get", "{\"surface_id\":\"surface:2\"}");
    const j = h.run(&.{ "cmux", "browser", "surface:2", "url", "--json" });
    try testing.expectEqualStrings("{\n  \"surface_ref\": \"surface:2\",\n  \"url\": \"https://example.com/\"\n}\n", j.out);
    const both = h.run(&.{ "cmux", "--json", "browser", "surface:2", "url", "--id-format", "both" });
    try expectContains(both.out, "\"surface_id\": \"S2-UUID\"");
}

test "unit: browser-cli: page verbs without a surface fail before connecting" {
    var h: Harness = undefined;
    try live(&h);
    defer h.deinit();
    h.setEnv("CMUX_SURFACE_ID", "S9-UUID");
    h.setEnv("CMUX_WORKSPACE_ID", "WS-UUID");
    const r = h.run(&.{ "cmux", "browser", "click", "#x" });
    try testing.expectEqual(@as(u8, 2), r.code);
    try testing.expectEqualStrings("cmux: browser click requires a surface handle (use: browser <surface> click ... or --surface)\n", r.err);
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
    const bad = h.run(&.{ "cmux", "browser", "nope!", "url" });
    try testing.expectEqual(@as(u8, 2), bad.code);
    try testing.expectEqualStrings("cmux: Invalid surface handle: nope! (expected UUID, ref like surface:1, or index)\n", bad.err);
    const flag = h.run(&.{ "cmux", "browser", "surface:2", "goto", "--bogus", "x" });
    try testing.expectEqual(@as(u8, 2), flag.code);
    try testing.expectEqualStrings("cmux: browser goto does not support --bogus\n", flag.err);
    const none = h.run(&.{ "cmux", "browser" });
    try testing.expectEqual(@as(u8, 2), none.code);
    try expectContains(none.err, "browser requires a subcommand\nUsage: cmux browser [--surface");
    const w = h.run(&.{ "wmux", "browser", "surface:1", "frob" });
    try testing.expectEqualStrings("wmux: browser: unknown subcommand 'frob'. Run 'wmux browser --help' for the list.\n", w.err);
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
}

test "unit: browser-cli: open text, params and golden (acceptance)" {
    var h: Harness = undefined;
    try live(&h);
    defer h.deinit();
    h.setEnv("CMUX_WORKSPACE_ID", "WS-UUID");
    const r = h.run(&.{ "cmux", "browser", "open", "https://example.com" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try h.expectRequest("browser.open_split", "{\"url\":\"https://example.com\",\"workspace_id\":\"WS-UUID\",\"focus\":false}");
    try expectGolden(h.alloc(), "browser-open.txt", r.out);
    const legacy = h.run(&.{ "cmux", "open-browser", "https://example.com" });
    try testing.expectEqualStrings(r.out, legacy.out);
    try testing.expectEqualStrings("", legacy.err);
    const json = h.run(&.{ "cmux", "browser", "open", "--json" });
    try expectGolden(h.alloc(), "browser-open-json.txt", json.out);
    try h.expectRequest("browser.open_split", "{\"workspace_id\":\"WS-UUID\",\"focus\":false}");
    const bad = h.run(&.{ "cmux", "browser", "open", "--new-tab" });
    try testing.expectEqualStrings("cmux: browser open does not support --new-tab\n", bad.err);
}

test "unit: browser-cli: snapshot, snapshot-after and eval output" {
    var h: Harness = undefined;
    try live(&h);
    defer h.deinit();
    const s = h.run(&.{ "cmux", "browser", "surface:2", "snapshot", "-i" });
    try testing.expectEqual(@as(u8, 0), s.code);
    try h.expectRequest("browser.snapshot", "{\"surface_id\":\"surface:2\",\"interactive\":true,\"cursor\":false,\"compact\":false}");
    try expectGolden(h.alloc(), "browser-snapshot.txt", s.out);
    const c = h.run(&.{ "cmux", "browser", "surface:2", "click", "@e3", "--snapshot-after" });
    try h.expectRequest("browser.click", "{\"surface_id\":\"surface:2\",\"snapshot_after\":true,\"selector\":\"@e3\"}");
    try expectGolden(h.alloc(), "browser-click-snapshot-after.txt", c.out);
    try testing.expectEqualStrings("OK\n", h.run(&.{ "cmux", "browser", "surface:2", "click", "@e3" }).out);
    try testing.expectEqualStrings("Example Domain\n", h.run(&.{ "cmux", "browser", "surface:2", "eval", "document.title" }).out);
    try testing.expectEqualStrings("2\n", h.run(&.{ "cmux", "browser", "surface:2", "eval", "1+1" }).out);
    try testing.expectEqualStrings("OK\n", h.run(&.{ "cmux", "browser", "surface:2", "eval", "void 0" }).out);
    const e = h.run(&.{ "cmux", "browser", "surface:2", "eval", "throw new Error(\"x\")" });
    try testing.expectEqual(@as(u8, 1), e.code);
    try testing.expectEqualStrings("js_error: Error: x\n", e.err);
    const empty = h.run(&.{ "cmux", "browser", "surface:2", "eval" });
    try testing.expectEqual(@as(u8, 2), empty.code);
    try testing.expectEqualStrings("cmux: browser eval requires a script\n", empty.err);
}

test "unit: browser-cli: wait timeout, getters, is and focus queries" {
    var h: Harness = undefined;
    try live(&h);
    defer h.deinit();
    const w = h.run(&.{ "cmux", "browser", "surface:2", "wait", "--text", "Welcome", "--timeout-ms", "2000" });
    try testing.expectEqual(@as(u8, 1), w.code);
    try testing.expectEqualStrings("timeout: Condition not met before timeout\n", w.err);
    try testing.expectEqualStrings("OK\n", h.run(&.{ "cmux", "browser", "surface:2", "wait", "#ready" }).out);
    try testing.expectEqualStrings("3\n", h.run(&.{ "cmux", "browser", "surface:2", "get", "count", ".row" }).out);
    try testing.expectEqualStrings("{\"x\":8,\"y\":16,\"width\":120.5,\"height\":40}\n", h.run(&.{ "cmux", "browser", "surface:2", "get", "box", "#x" }).out);
    try testing.expectEqualStrings("Example Domain\n", h.run(&.{ "cmux", "browser", "surface:2", "get", "title" }).out);
    try testing.expectEqualStrings("false\n", h.run(&.{ "cmux", "browser", "surface:2", "is", "enabled", "button[disabled]" }).out);
    try testing.expectEqualStrings("true\n", h.run(&.{ "cmux", "browser", "surface:2", "is-webview-focused" }).out);
    try testing.expectEqualStrings("true\n", h.run(&.{ "cmux", "is-webview-focused", "--panel", "surface:2" }).out);
    const legacy = h.run(&.{ "cmux", "get-url", "--panel", "surface:2" });
    try testing.expectEqualStrings("https://example.com/\n", legacy.out);
    try h.expectRequest("browser.url.get", "{\"surface_id\":\"surface:2\"}");
    try testing.expectEqualStrings("OK\n", h.run(&.{ "cmux", "navigate", "https://x.y", "--panel", "surface:2" }).out);
    try h.expectRequest("browser.navigate", "{\"surface_id\":\"surface:2\",\"url\":\"https://x.y\"}");
    try testing.expectEqualStrings("OK\n", h.run(&.{ "cmux", "browser-back", "--surface", "surface:2" }).out);
    try h.expectRequest("browser.back", "{\"surface_id\":\"surface:2\"}");
}

test "unit: browser-cli: list renderers through the app (goldens)" {
    var h: Harness = undefined;
    try live(&h);
    defer h.deinit();
    const cases = [_]struct { []const u8, []const []const u8 }{
        .{ "browser-download-list.txt", &.{ "cmux", "browser", "surface:2", "download", "list", "--limit", "5" } },
        .{ "browser-console-list.txt", &.{ "cmux", "browser", "surface:2", "console", "list" } },
        .{ "browser-errors-list.txt", &.{ "cmux", "browser", "surface:2", "errors" } },
        .{ "browser-profiles-list.txt", &.{ "cmux", "browser", "profiles" } },
        .{ "browser-tab-list.txt", &.{ "cmux", "browser", "surface:2", "tab", "list" } },
    };
    for (cases) |c| {
        const r = h.run(c[1]);
        try testing.expectEqual(@as(u8, 0), r.code);
        try expectGolden(h.alloc(), c[0], r.out);
    }
    try h.expectRequest("browser.tab.list", "{\"surface_id\":\"surface:2\"}");
    try testing.expectEqualStrings("Created browser profile job\tjob\tPR-3\n", h.run(&.{ "cmux", "browser", "profiles", "create", "job" }).out);
    const busy = h.run(&.{ "cmux", "browser", "profiles", "clear", "work" });
    try testing.expectEqual(@as(u8, 1), busy.code);
    try expectContains(busy.err, "invalid_state: Profile 'work' is in use by 1 open browser surface\nWhat to do: pass --force to clear it anyway\n");
    try testing.expectEqualStrings("Cleared 1 browser profile(s).\n", h.run(&.{ "cmux", "browser", "profiles", "clear", "work", "--force" }).out);
    try testing.expectEqualStrings("enabled\n", h.run(&.{ "cmux", "browser", "design-mode" }).out);
    try testing.expectEqualStrings("enabled\n", h.run(&.{ "cmux", "browser", "--surface", "surface:2", "design-mode", "enable" }).out);
    try h.expectRequest("browser.design_mode.set", "{\"surface_id\":\"surface:2\",\"mode\":\"enable\"}");
}

test "unit: browser-cli: import defaults to cookies in agent environments" {
    var h: Harness = undefined;
    try live(&h);
    defer h.deinit();
    const wizard = h.run(&.{ "cmux", "browser", "import" });
    try testing.expectEqualStrings("OK\n", wizard.out);
    try h.expectRequest("browser.import.dialog", "{}");
    h.setEnv("CLAUDECODE", "1");
    const r = h.run(&.{ "cmux", "browser", "import", "--from", "chrome", "--domain", "github.com" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try h.expectRequest("browser.import.cookies", "{\"scope\":\"cookiesOnly\",\"browser\":\"chrome\",\"source_profiles\":[],\"domain_filters\":[\"github.com\"],\"all_profiles\":false,\"create_destination_profile\":false}");
    try expectGolden(h.alloc(), "browser-import.txt", r.out);
}

test "unit: browser-cli: unsupported families surface not_supported" {
    var h: Harness = undefined;
    try live(&h);
    defer h.deinit();
    const r = h.run(&.{ "cmux", "browser", "surface:2", "network", "requests", "--json" });
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings("", r.out);
    try expectContains(r.err, "not_supported: browser.network.requests is not supported on WebView2 yet\n");
    const drag = h.run(&.{ "cmux", "browser", "surface:2", "drag", "#a", "#b" });
    try testing.expectEqual(@as(u8, 2), drag.code);
    try testing.expectEqualStrings("cmux: browser drag is not supported by the cmux CLI\n", drag.err);
}

test "unit: browser-cli: identify adds the browser url and title" {
    var h: Harness = undefined;
    try live(&h);
    defer h.deinit();
    h.setEnv("CMUX_WORKSPACE_ID", "WS-UUID");
    h.setEnv("CMUX_SURFACE_ID", "S1-UUID");
    const r = h.run(&.{ "cmux", "browser", "identify", "--surface", "surface:2", "--json" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try h.expectRequest("system.identify", "{\"caller\":{\"workspace_id\":\"WS-UUID\",\"surface_id\":\"S1-UUID\"}}");
    try h.expectRequest("browser.get.title", "{\"surface_id\":\"surface:2\"}");
    try expectGolden(h.alloc(), "browser-identify-json.txt", r.out);
    try testing.expectEqualStrings("OK\n", h.run(&.{ "cmux", "browser", "identify" }).out);
    try h.expectRequest("browser.url.get", "{\"surface_id\":\"S2-UUID\"}");
}

test "unit: browser-cli: set-input-files checks files on the client" {
    var h: Harness = undefined;
    try live(&h);
    defer h.deinit();
    const root = if (builtin.os.tag == .windows) "C:\\work\\" else "/work/";
    const a_path = try std.mem.concat(h.alloc(), u8, &.{ root, "a.txt" });
    try h.fp.addFile(a_path, "hello");
    const r = h.run(&.{ "cmux", "browser", "surface:2", "set-input-files", "--selector", "#f", "--file", "a.txt" });
    try testing.expectEqual(@as(u8, 0), r.code);
    const sent = h.request("browser.set_input_files").?;
    try testing.expectEqualStrings(a_path, sent.params.object.get("files").?.array.items[0].string);
    const missing = h.run(&.{ "cmux", "browser", "surface:2", "set-input-files", "--selector", "#f", "--file", "nope.txt" });
    try testing.expectEqual(@as(u8, 2), missing.code);
    try testing.expectEqualStrings("cmux: Every upload path must be a readable regular file\n", missing.err);
    try testing.expectEqual(@as(?fake.Request, null), h.request("browser.set_input_files"));
    const big = try h.alloc().alloc(u8, 20 * 1024 * 1024);
    @memset(big, 'x');
    const b_path = try std.mem.concat(h.alloc(), u8, &.{ root, "b.bin" });
    try h.fp.addFile(b_path, big);
    const over = h.run(&.{ "cmux", "browser", "surface:2", "set-input-files", "--selector", "#f", "--file", b_path, "--file", b_path });
    try testing.expectEqualStrings("cmux: The combined upload must be no larger than 32 MiB\n", over.err);
    const clear = h.run(&.{ "cmux", "browser", "surface:2", "set-input-files", "--selector", "#f", "--clear" });
    try testing.expectEqual(@as(u8, 0), clear.code);
}

test "unit: browser-cli: screenshot writes --out or prints the app's file URL" {
    var h: Harness = undefined;
    try live(&h);
    defer h.deinit();
    const out = if (builtin.os.tag == .windows) "C:\\work\\shots\\p.png" else "/work/shots/p.png";
    const r = h.run(&.{ "cmux", "browser", "surface:2", "screenshot", "--out", "shots/p.png" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings(try std.fmt.allocPrint(h.alloc(), "OK {s}\n", .{out}), r.out);
    try testing.expectEqualStrings("\x89PNG", h.mem.get(out).?);
    const plain = h.run(&.{ "cmux", "browser", "surface:2", "screenshot" });
    try testing.expectEqualStrings("OK file:///tmp/wmux-browser-screenshots/surface-s2uuid-1.png\n", plain.out);
    const j = h.run(&.{ "cmux", "browser", "surface:2", "screenshot", "--json" });
    try testing.expect(!contains(j.out, "png_base64"));
    try expectContains(j.out, "\"url\": \"file:///tmp/");
    h.mem.fail = true;
    const fail = h.run(&.{ "cmux", "browser", "surface:2", "screenshot", "--out", "x.png" });
    try testing.expectEqual(@as(u8, 1), fail.code);
    try expectContains(fail.err, "browser screenshot: cannot write ");
}

fn cfgDir() []const u8 {
    return if (builtin.os.tag == .windows) "C:\\cfg" else "/cfg";
}

fn wmuxJson() []const u8 {
    return if (builtin.os.tag == .windows) "C:\\cfg\\wmux.json" else "/cfg/wmux.json";
}

test "unit: browser-cli: availability works offline through wmux.json" {
    var h: Harness = undefined;
    try h.init(fake.pingHandler);
    defer h.deinit();
    h.setEnv("WMUX_CONFIG_DIR", cfgDir());
    const s = h.run(&.{ "cmux", "browser-status" });
    try testing.expectEqual(@as(u8, 0), s.code);
    try testing.expectEqualStrings("enabled\n", s.out);
    const d = h.run(&.{ "cmux", "disable-browser" });
    try testing.expectEqualStrings("cmux browser disabled\n", d.out);
    const written = h.mem.get(wmuxJson()).?;
    try expectContains(written, "\"enabled\": false");
    try h.fp.addFile(wmuxJson(), written);
    try testing.expectEqualStrings("disabled\n", h.run(&.{ "cmux", "browser", "status" }).out);
    const j = h.run(&.{ "cmux", "browser-status", "--json" });
    // The settings path is OS-specific; the golden names it <wmux.json>.
    const escaped = try std.json.Stringify.valueAlloc(h.alloc(), wmuxJson(), .{});
    try expectGolden(h.alloc(), "browser-status-json.txt", try std.mem.replaceOwned(u8, h.alloc(), j.out, escaped, "\"<wmux.json>\""));
    try testing.expectEqualStrings("wmux browser enabled\n", h.run(&.{ "wmux", "enable-browser" }).out);
    try testing.expectEqualStrings("cmux browser enabled\n", h.run(&.{ "cmux", "browser", "enable" }).out);
    const extra = h.run(&.{ "cmux", "disable-browser", "now" });
    try testing.expectEqual(@as(u8, 2), extra.code);
    try testing.expectEqualStrings("cmux: Unexpected argument: now\n", extra.err);
    const extra2 = h.run(&.{ "cmux", "browser", "status", "x" });
    try testing.expectEqualStrings("cmux: Unexpected argument: x\n", extra2.err);
    // Nothing here talks to the app.
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
}

test "unit: browser-cli: availability refuses to clobber a broken wmux.json" {
    var h: Harness = undefined;
    try h.init(fake.pingHandler);
    defer h.deinit();
    h.setEnv("WMUX_CONFIG_DIR", cfgDir());
    try h.fp.addFile(wmuxJson(), "{ \"font\": ");
    const r = h.run(&.{ "cmux", "disable-browser" });
    try testing.expectEqual(@as(u8, 1), r.code);
    try expectContains(r.err, "it is not valid JSON (fix or remove it first)");
    try testing.expectEqual(@as(?[]const u8, null), h.mem.get(wmuxJson()));
    try testing.expectEqualStrings("enabled\n", h.run(&.{ "cmux", "browser-status" }).out);
    // A write failure is reported, not ignored.
    var h2: Harness = undefined;
    try h2.init(fake.pingHandler);
    defer h2.deinit();
    h2.setEnv("WMUX_CONFIG_DIR", cfgDir());
    h2.mem.fail = true;
    const f = h2.run(&.{ "cmux", "enable-browser" });
    try testing.expectEqual(@as(u8, 1), f.code);
    try expectContains(f.err, "cannot write ");
}

test "unit: browser-cli: offline help, docs and skill (goldens)" {
    var h: Harness = undefined;
    try h.init(fake.pingHandler);
    defer h.deinit();
    const cases = [_]struct { []const u8, []const []const u8 }{
        .{ "browser-help.txt", &.{ "cmux", "browser", "--help" } },
        .{ "browser-skill.txt", &.{ "cmux", "browser", "--skill" } },
        .{ "browser-repl-guide.txt", &.{ "cmux", "browser", "repl", "guide" } },
        .{ "get-url-help.txt", &.{ "cmux", "get-url", "--help" } },
        .{ "open-browser-help.txt", &.{ "cmux", "open-browser", "--help" } },
        .{ "disable-browser-help.txt", &.{ "cmux", "disable-browser", "--help" } },
        .{ "browser-status-help.txt", &.{ "cmux", "browser-status", "--help" } },
    };
    for (cases) |c| {
        const r = h.run(c[1]);
        try testing.expectEqual(@as(u8, 0), r.code);
        try expectGolden(h.alloc(), c[0], r.out);
    }
    try testing.expectEqualStrings(h.run(&.{ "cmux", "browser", "--help" }).out, h.run(&.{ "cmux", "browser", "help" }).out);
    try testing.expectEqualStrings(h.run(&.{ "cmux", "browser", "--skill" }).out, h.run(&.{ "cmux", "browser", "skill" }).out);
    // Help after a surface or verb is still offline.
    try testing.expectEqual(@as(u8, 0), h.run(&.{ "cmux", "browser", "surface:2", "click", "--help" }).code);
    const w = h.run(&.{ "wmux", "browser", "--help" });
    try testing.expect(std.mem.startsWith(u8, w.out, "Usage: wmux browser [--surface"));
    const docs = h.run(&.{ "cmux", "browser", "docs" });
    try testing.expectEqual(@as(u8, 0), docs.code);
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
}
