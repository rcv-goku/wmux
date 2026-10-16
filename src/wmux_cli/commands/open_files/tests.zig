//! Tests of the `open_files` family: open, cmux <path>, markdown, diff,
//! comments.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const proto = @import("wmux_proto");
const harness = @import("../cli_misc/harness.zig");
const fake = @import("../../fake.zig");
const open = @import("open.zig");
const markdown = @import("markdown.zig");
const diff = @import("diff.zig");

fn server(_: *fake.Server, req: fake.Request) fake.Action {
    const m = req.method;
    if (std.mem.eql(u8, m, "file.open")) return .{ .ok = "{\"surface_id\":\"6ba7b810-9dad-11d1-80b4-00c04fd430c8\",\"surface_ref\":\"surface:7\",\"pane_ref\":\"pane:3\",\"pane_id\":\"P3\"}" };
    if (std.mem.eql(u8, m, "workspace.create")) return .{ .ok = "{\"workspace_ref\":\"workspace:4\"}" };
    if (std.mem.eql(u8, m, "browser.open_split")) return .{ .ok = "{\"surface_ref\":\"surface:8\",\"pane_ref\":\"pane:5\"}" };
    if (std.mem.eql(u8, m, "markdown.open")) return .{ .ok = "{\"surface_ref\":\"surface:9\",\"pane_ref\":\"pane:6\"}" };
    if (std.mem.eql(u8, m, "wmux.diff.open")) return .{ .ok = "{\"surface_ref\":\"surface:10\",\"pane_ref\":\"pane:7\",\"source\":\"stdin\"}" };
    if (std.mem.eql(u8, m, "comments.list")) return .{ .ok = "{\"comments\":[{\"file\":\"src/a.zig\",\"start_line\":3,\"end_line\":5,\"message\":\"rename\\nthis\"},{\"path\":\"C:\\\\r\\\\b.md\",\"line\":1,\"message\":\"typo \u{e9}\"}]}" };
    if (std.mem.eql(u8, m, "app.launch")) return .{ .ok = "{\"accepted\":true}" };
    return .{ .err = "{\"code\":\"method_not_found\",\"message\":\"Unknown method\"}" };
}

const Fixture = struct {
    h: harness.Harness,

    fn init(self: *Fixture) void {
        self.h.init();
        self.h.serve(server);
        const a = self.h.alloc();
        self.h.addFile(harness.p(a, &.{ harness.root, "work", "a.md" }), "# a");
        self.h.addFile(harness.p(a, &.{ harness.root, "work", "b.png" }), "png");
        self.h.addFile(harness.p(a, &.{ harness.root, "work", "page.HTML" }), "<p>");
        self.h.addFile(harness.p(a, &.{ harness.root, "work", "my file.txt" }), "x");
        self.h.addDir(harness.p(a, &.{ harness.root, "work", "dir" }));
    }

    fn deinit(self: *Fixture) void {
        self.h.deinit();
    }

    fn path(self: *Fixture, name: []const u8) []const u8 {
        return harness.p(self.h.alloc(), &.{ harness.root, "work", name });
    }
};

test "unit: cli-open: helpers for URLs, positions and file URLs" {
    try testing.expect(open.isWebUrl("HTTPS://x.example"));
    try testing.expect(!open.isWebUrl("ftp://x"));
    try testing.expect(open.isHtml("a.HtM"));
    const p1 = open.splitPosition("src/a.zig:12:4").?;
    try testing.expectEqualStrings("src/a.zig", p1.path);
    try testing.expectEqual(@as(u32, 12), p1.line);
    try testing.expectEqual(@as(?u32, 4), p1.column);
    const p2 = open.splitPosition("C:\\a.zig:7").?;
    try testing.expectEqualStrings("C:\\a.zig", p2.path);
    try testing.expectEqual(@as(?u32, null), p2.column);
    try testing.expect(open.splitPosition("C:\\a.zig") == null);
    try testing.expect(open.splitPosition(":3") == null);
    try testing.expect(open.splitPosition("a:") == null);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("file:///C:/My%20Docs/a%23b.html", try open.fileUrl(a, "C:\\My Docs\\a#b.html"));
    try testing.expectEqualStrings("file:///home/u/\u{e9}.html", try open.fileUrl(a, "/home/u/\u{e9}.html"));
}

test "unit: cli-open: files batch, directories and URLs map to their methods" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    const r = h.run(&.{ "cmux", "open", "a.md", "b.png", "dir", "https://x.example" });
    try harness.expectOk(r);
    try harness.expectGolden(h.alloc(), "open-mixed.txt", r.out);
    const reqs = h.server.requests.items;
    try testing.expectEqual(@as(usize, 3), reqs.len);
    try testing.expectEqualStrings("file.open", reqs[0].method);
    try testing.expectEqualStrings(try std.fmt.allocPrint(h.alloc(), "{{\"paths\":[{f},{f}],\"focus\":false}}", .{ std.json.fmt(f.path("a.md"), .{}), std.json.fmt(f.path("b.png"), .{}) }), reqs[0].params_json);
    try testing.expectEqualStrings("workspace.create", reqs[1].method);
    try testing.expectEqualStrings(try std.fmt.allocPrint(h.alloc(), "{{\"cwd\":{f},\"focus\":false}}", .{std.json.fmt(f.path("dir"), .{})}), reqs[1].params_json);
    try testing.expectEqualStrings("browser.open_split", reqs[2].method);
    try testing.expectEqualStrings("{\"url\":\"https://x.example\",\"focus\":false}", reqs[2].params_json);
    const js = h.run(&.{ "cmux", "open", "a.md", "https://x.example", "--json" });
    try harness.expectOk(js);
    try harness.expectGolden(h.alloc(), "open-json.txt", js.out);
}

test "unit: cli-open: HTML, positions, separate batches and missing paths" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    h.fp.interactive = true;
    try harness.expectOk(h.run(&.{ "cmux", "open", "page.HTML" }));
    try testing.expectEqualStrings("browser.open_split", h.last().method);
    try testing.expectEqual(false, harness.param(h.last(), "focus").?.bool);
    try testing.expect(std.mem.startsWith(u8, harness.param(h.last(), "url").?.string, "file:///"));
    try harness.expectOk(h.run(&.{ "cmux", "open", "page.HTML", "--focus", "true" }));
    try testing.expectEqual(true, harness.param(h.last(), "focus").?.bool);

    const pos = h.run(&.{ "cmux", "open", "a.md:12:3" });
    try harness.expectOk(pos);
    try testing.expectEqualStrings(f.path("a.md"), harness.param(h.last(), "paths").?.array.items[0].string);
    try testing.expectEqual(@as(i64, 12), harness.param(h.last(), "positions").?.array.items[0].object.get("line").?.integer);

    const n = h.requestCount();
    try harness.expectOk(h.run(&.{ "cmux", "open", "a.md", "dir", "my file.txt" }));
    try testing.expectEqual(n + 3, h.requestCount());

    const before = h.requestCount();
    const missing = h.run(&.{ "cmux", "open", "a.md", "nope.txt" });
    try harness.expectFail(missing, 1, try std.fmt.allocPrint(h.alloc(), "Path does not exist: {s}", .{f.path("nope.txt")}));
    try harness.expectFail(h.run(&.{ "cmux", "open", "nope.txt:3" }), 1, "Path does not exist:");
    try testing.expectEqual(before, h.requestCount());
}

test "unit: cli-open: paths are normalized before they are checked and sent" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    const a = h.alloc();
    try harness.expectOk(h.run(&.{ "cmux", "open", "./a.md", "../work/b.png", "dir/." }));
    const reqs = h.server.requests.items;
    const paths = harness.param(reqs[0], "paths").?.array.items;
    try testing.expectEqualStrings(f.path("a.md"), paths[0].string);
    try testing.expectEqualStrings(f.path("b.png"), paths[1].string);
    try testing.expectEqualStrings(f.path("dir"), harness.param(reqs[1], "cwd").?.string);
    try harness.expectFail(h.run(&.{ "cmux", "open", "dir/../nope.md" }), 1, try std.fmt.allocPrint(a, "Path does not exist: {s}\n", .{f.path("nope.md")}));
    _ = h.run(&.{ "cmux", "markdown", "open", "./notes/../plan.md" });
    try testing.expectEqualStrings(f.path("plan.md"), harness.param(h.last(), "path").?.string);
    if (builtin.os.tag == .windows) {
        // Root-relative and drive-relative spellings resolve like Windows does.
        _ = h.run(&.{ "cmux", "markdown", "open", "\\plan.md" });
        try testing.expectEqualStrings("C:\\plan.md", harness.param(h.last(), "path").?.string);
        _ = h.run(&.{ "cmux", "markdown", "open", "C:plan.md" });
        try testing.expectEqualStrings(f.path("plan.md"), harness.param(h.last(), "path").?.string);
        _ = h.run(&.{ "cmux", "markdown", "open", "c:/t/work/plan.md" });
        try testing.expectEqualStrings(f.path("plan.md"), harness.param(h.last(), "path").?.string);
    }
}

test "unit: cli-open: a relative path missing from the cwd resolves from the git root" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    const a = h.alloc();
    // The repository root is the test root; the cwd is root/work.
    h.addDir(harness.p(a, &.{ harness.root, ".git" }));
    const in_root = harness.p(a, &.{ harness.root, "src", "main.zig" });
    h.addFile(in_root, "x");
    h.addDir(harness.p(a, &.{ harness.root, "docs" }));
    const rel = harness.p(a, &.{ "src", "main.zig" });
    try harness.expectOk(h.run(&.{ "cmux", "open", rel }));
    try testing.expectEqualStrings(in_root, harness.param(h.last(), "paths").?.array.items[0].string);
    // With a :line:col suffix, and for a directory (a new workspace).
    try harness.expectOk(h.run(&.{ "cmux", "open", try std.fmt.allocPrint(a, "{s}:4:2", .{rel}) }));
    try testing.expectEqualStrings(in_root, harness.param(h.last(), "paths").?.array.items[0].string);
    try testing.expectEqual(@as(i64, 4), harness.param(h.last(), "positions").?.array.items[0].object.get("line").?.integer);
    try harness.expectOk(h.run(&.{ "cmux", "open", "docs" }));
    try testing.expectEqualStrings("workspace.create", h.last().method);
    try testing.expectEqualStrings(harness.p(a, &.{ harness.root, "docs" }), harness.param(h.last(), "cwd").?.string);
    // Missing in both places: the error names the cwd spelling, nothing opens.
    const n = h.requestCount();
    const missing = harness.p(a, &.{ "src", "nope.zig" });
    try harness.expectFail(h.run(&.{ "cmux", "open", "a.md", missing }), 1, try std.fmt.allocPrint(a, "Path does not exist: {s}\n", .{f.path(missing)}));
    try testing.expectEqual(n, h.requestCount());
    // The cwd wins over the repository root.
    const local = f.path(rel);
    h.addFile(local, "y");
    try harness.expectOk(h.run(&.{ "cmux", "open", rel }));
    try testing.expectEqualStrings(local, harness.param(h.last(), "paths").?.array.items[0].string);
}

test "unit: cli-open: without a repository a missing relative path fails" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    const a = h.alloc();
    // A file at the root, but no .git above the cwd: no fallback.
    h.addFile(harness.p(a, &.{ harness.root, "top.md" }), "x");
    try harness.expectFail(h.run(&.{ "cmux", "open", "top.md" }), 1, try std.fmt.allocPrint(a, "Path does not exist: {s}", .{f.path("top.md")}));
    try testing.expectEqual(@as(usize, 0), h.requestCount());
}

test "unit: cli-comments: a '..' in --repo resolves before the repository walk" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    const a = h.alloc();
    // The outer repository at the root and a nested one at work/dir.
    h.addDir(harness.p(a, &.{ harness.root, ".git" }));
    h.addDir(harness.p(a, &.{ harness.root, "work", "dir", ".git" }));
    try harness.expectOk(h.run(&.{ "cmux", "comments", "list", "--repo", "dir/.." }));
    try testing.expectEqualStrings(harness.root, harness.param(h.last(), "repo").?.string);
    try harness.expectOk(h.run(&.{ "cmux", "comments", "list", "--repo", "./dir" }));
    try testing.expectEqualStrings(f.path("dir"), harness.param(h.last(), "repo").?.string);
    try harness.expectOk(h.run(&.{ "cmux", "diff", "--staged", "--repo", "dir/.." }));
    try testing.expectEqualStrings(harness.root, harness.param(h.last(), "repo").?.string);
}

test "unit: cli-open: focus defaults, overrides and caller targets" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    h.fp.interactive = true;
    _ = h.run(&.{ "cmux", "open", "a.md" });
    try testing.expectEqual(true, harness.param(h.last(), "focus").?.bool);
    _ = h.run(&.{ "cmux", "open", "a.md", "--focus", "true", "--no-focus" });
    try testing.expectEqual(false, harness.param(h.last(), "focus").?.bool);
    h.setEnv("CMUX_WORKSPACE_ID", "WS-1");
    h.setEnv("CMUX_SURFACE_ID", "SF-1");
    _ = h.run(&.{ "cmux", "open", "a.md" });
    try testing.expectEqualStrings("WS-1", harness.param(h.last(), "workspace_id").?.string);
    try testing.expectEqualStrings("SF-1", harness.param(h.last(), "surface_id").?.string);
    _ = h.run(&.{ "cmux", "open", "a.md", "--pane", "pane:2" });
    try testing.expectEqualStrings("WS-1", harness.param(h.last(), "workspace_id").?.string);
    try testing.expect(harness.param(h.last(), "surface_id") == null);
    _ = h.run(&.{ "cmux", "open", "a.md", "--window", "window:1" });
    try testing.expect(harness.param(h.last(), "workspace_id") == null);
    try testing.expect(harness.param(h.last(), "surface_id") == null);
    h.setEnv("CLAUDECODE", "1");
    _ = h.run(&.{ "cmux", "open", "a.md" });
    try testing.expectEqual(false, harness.param(h.last(), "focus").?.bool);
    h.setEnv("CMUX_FOCUS_NEW", "1");
    _ = h.run(&.{ "cmux", "open", "a.md" });
    try testing.expectEqual(true, harness.param(h.last(), "focus").?.bool);
}

test "unit: cli-open: usage errors" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    try harness.expectFail(h.run(&.{ "cmux", "open" }), 2, "open requires at least one path or URL. Usage: cmux open <path-or-url>...");
    try harness.expectFail(h.run(&.{ "wmux", "open" }), 2, "open requires at least one path or URL. Usage: wmux open <path-or-url>...");
    try harness.expectFail(h.run(&.{ "cmux", "open", "a.md", "--bogus" }), 2, "open: unknown flag '--bogus'. Usage: cmux open <path-or-url>...");
    try harness.expectFail(h.run(&.{ "cmux", "open", "a.md", "--focus", "yes" }), 2, "--focus must be true|false");
    try harness.expectFail(h.run(&.{ "cmux", "open", "a.md", "--surface", "" }), 2, "Surface handle is blank");
    try testing.expectEqual(@as(usize, 0), h.requestCount());
    const help = h.run(&.{ "cmux", "open", "--help" });
    try harness.expectOk(help);
    try harness.expectGolden(h.alloc(), "open-help.txt", help.out);
}

test "unit: cli-open: cmux <path> goes through app.launch on the launch pipe" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    const a = h.alloc();
    var launch_server = fake.Server.init(a);
    launch_server.handler = server;
    const hash = proto.pipe_name.sidHash8(harness.test_sid);
    const control = try proto.pipe_name.controlName(a, "stable", &hash, 1);
    try h.fp.addServer(try proto.pipe_name.launchName(a, control), &launch_server);
    const dir = f.path("dir");
    const r = h.run(&.{ "cmux", dir });
    try harness.expectOk(r);
    try testing.expectEqual(@as(usize, 1), launch_server.requests.items.len);
    const req = launch_server.requests.items[0];
    try testing.expectEqualStrings("app.launch", req.method);
    try testing.expectEqualStrings("open", harness.param(req, "intent").?.string);
    try testing.expectEqualStrings(dir, harness.param(req, "paths").?.array.items[0].string);
    // Command names win over paths.
    h.addFile("open", "");
    try harness.expectFail(h.run(&.{ "cmux", "open" }), 2, "open requires at least one path or URL");
}

test "unit: cli-markdown: open params, shorthand, defaults and output" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    h.setEnv("CMUX_WORKSPACE_ID", "WS-1");
    h.setEnv("CMUX_SURFACE_ID", "SF-1");
    const r = h.run(&.{ "cmux", "markdown", "open", "plan.md", "--direction", "down", "--font-size", "12.345" });
    try harness.expectOk(r);
    try harness.expectGolden(h.alloc(), "markdown-open.txt", r.out);
    try testing.expectEqualStrings("markdown.open", h.last().method);
    try testing.expectEqualStrings(try std.fmt.allocPrint(h.alloc(), "{{\"path\":{f},\"direction\":\"down\",\"font_size\":12.35,\"workspace_id\":\"WS-1\",\"focus\":false}}", .{std.json.fmt(f.path("plan.md"), .{})}), h.last().params_json);
    _ = h.run(&.{ "cmux", "markdown", "plan.md", "--focus", "true", "--surface", "surface:2" });
    try testing.expectEqualStrings("right", harness.param(h.last(), "direction").?.string);
    try testing.expectEqual(true, harness.param(h.last(), "focus").?.bool);
    try testing.expectEqualStrings("surface:2", harness.param(h.last(), "surface_id").?.string);
    _ = h.run(&.{ "cmux", "markdown", "--direction", "left", "open", "x.md", "--window", "window:1" });
    try testing.expect(harness.param(h.last(), "workspace_id") == null);
    try testing.expectEqualStrings("window:1", harness.param(h.last(), "window_id").?.string);
    try testing.expectEqual(@as(?f64, 8), markdown.parseFontSize("8"));
    try testing.expectEqual(@as(?f64, 96), markdown.parseFontSize("96"));
    try testing.expect(markdown.parseFontSize("7.99") == null);
    try testing.expect(markdown.parseFontSize("nan") == null);
    try testing.expect(markdown.parseFontSize("inf") == null);
}

test "unit: cli-markdown: usage errors" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    try harness.expectFail(h.run(&.{ "cmux", "markdown" }), 2, "markdown open requires a file path. Usage: cmux markdown open <path>");
    try harness.expectFail(h.run(&.{ "cmux", "markdown", "open" }), 2, "markdown open requires a file path. Usage: cmux markdown open <path>");
    try harness.expectFail(h.run(&.{ "cmux", "markdown", "view", "x.md" }), 2, "Unknown markdown subcommand 'view'");
    try harness.expectFail(h.run(&.{ "cmux", "markdown", "open", "a.md", "b.md" }), 2, "markdown open: unexpected argument 'b.md'");
    try harness.expectFail(h.run(&.{ "cmux", "markdown", "open", "a.md", "--zoom", "2" }), 2, "markdown open: unknown flag '--zoom'. Usage: cmux markdown open <path> [--workspace");
    try harness.expectFail(h.run(&.{ "cmux", "markdown", "open", "a.md", "--font-size", "200" }), 2, "--font-size must be a number between 8 and 96");
    try harness.expectFail(h.run(&.{ "cmux", "markdown", "open", "a.md", "--direction", "north" }), 2, "--direction must be left, right, up or down");
    try harness.expectFail(h.run(&.{ "cmux", "markdown", "open", "a.md", "--focus", "1" }), 2, "--focus must be true|false");
    try testing.expectEqual(@as(usize, 0), h.requestCount());
    const help = h.run(&.{ "cmux", "markdown", "--help" });
    try harness.expectOk(help);
    try harness.expectGolden(h.alloc(), "markdown-help.txt", help.out);
}

test "unit: cli-diff: stdin, patch files, URLs and git sources" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    const a = h.alloc();
    h.addDir(harness.p(a, &.{ harness.root, ".git" }));
    h.fp.stdin = "diff --git a/x b/x\n";
    const r = h.run(&.{ "cmux", "diff" });
    try harness.expectOk(r);
    try harness.expectGolden(a, "diff-stdin.txt", r.out);
    try testing.expectEqualStrings("wmux.diff.open", h.last().method);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{{\"patch\":\"diff --git a/x b/x\\n\",\"repo\":{f},\"font_size\":10,\"focus\":false}}", .{std.json.fmt(harness.root, .{})}), h.last().params_json);

    h.addFile(f.path("x.patch"), "--- a\n+++ b\n");
    _ = h.run(&.{ "cmux", "diff", "x.patch", "--layout", "split", "--title", "T", "--font-size", "13", "--focus", "true" });
    try testing.expectEqualStrings("--- a\n+++ b\n", harness.param(h.last(), "patch").?.string);
    try testing.expectEqualStrings(f.path("x.patch"), harness.param(h.last(), "patch_path").?.string);
    try testing.expectEqualStrings("split", harness.param(h.last(), "layout").?.string);
    try testing.expectEqual(true, harness.param(h.last(), "focus").?.bool);

    _ = h.run(&.{ "cmux", "diff", "https://github.com/o/r/pull/1" });
    try testing.expectEqualStrings("https://github.com/o/r/pull/1", harness.param(h.last(), "url").?.string);

    h.setEnv("CMUX_SURFACE_ID", "SF-1");
    _ = h.run(&.{ "cmux", "diff", "--staged" });
    try testing.expectEqualStrings("staged", harness.param(h.last(), "source").?.string);
    try testing.expectEqualStrings(harness.root, harness.param(h.last(), "repo").?.string);
    try testing.expectEqualStrings("SF-1", harness.param(h.last(), "surface_id").?.string);
    _ = h.run(&.{ "cmux", "diff", "--branch-base", "main" });
    try testing.expectEqualStrings("branch", harness.param(h.last(), "source").?.string);
    try testing.expectEqualStrings("main", harness.param(h.last(), "base").?.string);
    _ = h.run(&.{ "cmux", "diff", "--agent-session", "abc" });
    try testing.expectEqualStrings("last-turn", harness.param(h.last(), "source").?.string);
    _ = h.run(&.{ "cmux", "diff", "--source", "unstaged", "--unstaged", "--repo", "dir" });
    try testing.expectEqualStrings("unstaged", harness.param(h.last(), "source").?.string);
}

test "unit: cli-diff: usage errors" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    try harness.expectFail(h.run(&.{ "cmux", "diff", "--staged", "--unstaged" }), 2, "diff accepts only one source, got staged and unstaged");
    try harness.expectFail(h.run(&.{ "cmux", "diff", "x.patch", "--staged" }), 2, "diff accepts either a patch file or a git source, not both");
    try harness.expectFail(h.run(&.{ "cmux", "diff", "a", "b" }), 2, "diff accepts at most one patch file");
    try harness.expectFail(h.run(&.{ "cmux", "diff", "--source", "worktree" }), 2, "--source must be unstaged, staged, branch or last-turn");
    try harness.expectFail(h.run(&.{ "cmux", "diff", "--staged", "--font-size", "0" }), 2, "--font-size must be a number greater than 0 and at most 96");
    try harness.expectFail(h.run(&.{ "cmux", "diff", "--staged", "--font-size", "97" }), 2, "--font-size");
    try harness.expectFail(h.run(&.{ "cmux", "diff", "--staged", "--layout", "side" }), 2, "--layout must be split or unified");
    try harness.expectFail(h.run(&.{ "cmux", "diff" }), 2, diff.no_input_message);
    // A terminal stdin refuses without reading, even with stdout redirected
    // (fp.interactive stays false). Typed text would otherwise be taken as
    // the patch.
    h.stdin_tty = true;
    h.fp.stdin = "diff --git a/x b/x\n";
    try harness.expectFail(h.run(&.{ "cmux", "diff" }), 2, diff.no_input_message);
    h.fp.interactive = true;
    try harness.expectFail(h.run(&.{ "cmux", "diff" }), 2, diff.no_input_message);
    try testing.expectEqual(@as(usize, 0), h.requestCount());
    h.stdin_tty = false;
    h.fp.interactive = false;
    h.fp.stdin = null;
    try harness.expectFail(h.run(&.{ "cmux", "diff", "missing.patch" }), 1, "diff: cannot read patch file");
    const help = h.run(&.{ "cmux", "diff", "--help" });
    try harness.expectOk(help);
    try harness.expectGolden(h.alloc(), "diff-help.txt", help.out);
}

test "unit: cli-comments: list resolves the repository and renders anchors" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.h;
    const a = h.alloc();
    h.addDir(harness.p(a, &.{ harness.root, ".git" }));
    const r = h.run(&.{ "cmux", "comments", "list" });
    try harness.expectOk(r);
    try harness.expectGolden(a, "comments-list.txt", r.out);
    try testing.expectEqualStrings("comments.list", h.last().method);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{{\"repo\":{f},\"all\":false}}", .{std.json.fmt(harness.root, .{})}), h.last().params_json);
    _ = h.run(&.{ "cmux", "comments", "ls", "--all", "--repo", "dir" });
    try testing.expectEqual(true, harness.param(h.last(), "all").?.bool);
    const n = h.requestCount();
    try harness.expectFail(h.run(&.{ "cmux", "comments", "add" }), 2, "unknown comments subcommand 'add'");
    try harness.expectFail(h.run(&.{ "cmux", "comments" }), 2, "comments requires a subcommand");
    try harness.expectFail(h.run(&.{ "cmux", "comments", "list", "--since", "x" }), 2, "comments list: unknown flag '--since'");
    try harness.expectFail(h.run(&.{ "cmux", "comments", "list", "--repo", harness.other_root }), 1, "not inside a git repository");
    try testing.expectEqual(n, h.requestCount());
    const help = h.run(&.{ "cmux", "comments", "--help" });
    try harness.expectOk(help);
    try harness.expectContains(help.out, "Usage: cmux comments <subcommand> [options]");
}
