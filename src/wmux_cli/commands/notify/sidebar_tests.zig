//! Tests of the `sidebar_meta` family: v1 error strings, request params,
//! list/state text output and goldens, and `pr` with a scripted gh/git.

const std = @import("std");
const testing = std.testing;
const kit = @import("testkit.zig");
const fake = kit.fake;
const Harness = kit.Harness;
const sidebar = @import("../sidebar_meta.zig");
const pr = @import("pr.zig");

const ws_uuid = "11111111-1111-4111-8111-111111111111";

const status_list = "{\"entries\":[{\"key\":\"build\",\"value\":\"compiling\",\"icon\":\"hammer\",\"color\":\"#ff9500\",\"priority\":80},{\"key\":\"docs\",\"value\":\"see [PR](https://x.example)\",\"url\":\"https://x.example\",\"priority\":0,\"format\":\"markdown\",\"work\":\"waiting\"},{\"key\":\"\u{65e5}\u{672c}\",\"value\":\"multi\\nline\",\"format\":\"plain\"}]}";
const log_list = "{\"entries\":[{\"level\":\"info\",\"message\":\"one\"},{\"level\":\"warning\",\"message\":\"two\",\"source\":\"ci\"},{\"level\":\"error\",\"message\":\"Compilation failed\",\"source\":\"build\"}]}";
const state_full = "{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"workspace_ref\":\"workspace:1\",\"color\":\"blue\",\"cwd\":\"C:\\\\src\\\\api\",\"focused_cwd\":\"C:\\\\src\\\\api\\\\web\",\"focused_surface_id\":\"22222222-2222-4222-8222-222222222222\",\"git_branch\":{\"name\":\"main\",\"dirty\":false},\"pr\":{\"number\":123,\"state\":\"open\",\"url\":\"https://github.com/o/r/pull/123\"},\"pr_label\":\"Review\",\"ports\":[3000,5173],\"progress\":{\"value\":0.5,\"label\":\"Building...\"},\"status\":[{\"key\":\"build\",\"value\":\"ok\",\"priority\":1}],\"meta_blocks\":[\"## Notes\",{\"text\":\"block two\"}],\"log\":[{\"level\":\"info\",\"message\":\"1\"},{\"level\":\"info\",\"message\":\"2\"},{\"level\":\"info\",\"message\":\"3\"},{\"level\":\"info\",\"message\":\"4\"},{\"level\":\"success\",\"message\":\"5\"},{\"level\":\"error\",\"message\":\"6\"}]}";

fn sidebarHandler(server: *fake.Server, req: fake.Request) fake.Action {
    const m = req.method;
    const empty = server.user != null;
    if (std.mem.eql(u8, m, "wmux.sidebar.status.list")) return .{ .ok = if (empty) "{\"entries\":[]}" else status_list };
    if (std.mem.eql(u8, m, "wmux.sidebar.log.list")) return .{ .ok = if (empty) "{\"entries\":[]}" else log_list };
    if (std.mem.eql(u8, m, "wmux.sidebar.state")) return .{ .ok = if (empty) "{}" else state_full };
    if (std.mem.eql(u8, m, "workspace.list")) return .{ .ok = "{\"workspaces\":[{\"id\":\"W1\",\"cwd\":\"C:\\\\src\\\\api\\\\sub\"},{\"id\":\"W2\",\"cwd\":\"C:\\\\src\\\\other\"},{\"id\":\"W3\"}]}" };
    if (std.mem.eql(u8, m, "wmux.workspace.pr.set")) return .{ .ok = "{\"workspace_id\":\"W1\",\"cleared\":false,\"number\":123,\"url\":\"https://github.com/o/r/pull/123\",\"state\":\"open\"}" };
    return .{ .ok = "{}" };
}

fn params(h: *Harness) []const u8 {
    return h.last().params_json;
}

test "unit: cli-sidebar: set-status params, defaults and v1 errors" {
    var h: Harness = undefined;
    try h.init(sidebarHandler);
    defer h.deinit();
    h.setEnv("CMUX_WORKSPACE_ID", ws_uuid);
    const r = h.run(&.{ "cmux", "set-status", "build", "compiling", "--icon", "hammer", "--color", "#ff9500", "--priority", "80" });
    try kit.expectResult(r, 0, "OK\n", "");
    try testing.expectEqualStrings("wmux.sidebar.status.set", h.last().method);
    try testing.expectEqualStrings("{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"key\":\"build\",\"value\":\"compiling\",\"icon\":\"hammer\",\"color\":\"#ff9500\",\"priority\":80}", params(&h));
    _ = h.run(&.{ "cmux", "set-status", "k", "two", "words", "--link=https://x.example/a", "--format", "markdown", "--work", "subagents", "--workspace", "workspace:2", "--priority=-3" });
    try testing.expectEqualStrings("{\"workspace_id\":\"workspace:2\",\"key\":\"k\",\"value\":\"two words\",\"priority\":-3,\"url\":\"https://x.example/a\",\"format\":\"markdown\",\"work\":\"subagents\"}", params(&h));
    _ = h.run(&.{ "cmux", "set-status", "--window", "window:1", "k", "--", "--v" });
    try testing.expectEqualStrings("{\"window_id\":\"window:1\",\"key\":\"k\",\"value\":\"--v\"}", params(&h));
    const n = h.requestCount();
    const cases = [_]struct { []const []const u8, []const u8 }{
        .{ &.{"set-status"}, "ERROR: Missing status key or value \u{2014} usage: set-status <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--work=running|subagents|waiting] [--workspace=X]\n" },
        .{ &.{ "set-status", "only" }, "ERROR: Missing status key or value \u{2014} usage: set-status <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--work=running|subagents|waiting] [--workspace=X]\n" },
        .{ &.{ "set-status", "k", "v", "--format", "html" }, "ERROR: Invalid metadata format 'html' \u{2014} use: plain, markdown\n" },
        .{ &.{ "set-status", "k", "v", "--work", "idle" }, "ERROR: Invalid work state 'idle' \u{2014} use: running, subagents, waiting\n" },
        .{ &.{ "set-status", "k", "v", "--priority", "high" }, "ERROR: Invalid metadata priority 'high' \u{2014} must be an integer\n" },
        .{ &.{ "set-status", "k", "v", "--priority", "1.5" }, "ERROR: Invalid metadata priority '1.5' \u{2014} must be an integer\n" },
        .{ &.{ "set-status", "k", "v", "--url", "ftp://x" }, "ERROR: Invalid metadata URL 'ftp://x' \u{2014} expected http(s) URL\n" },
        .{ &.{ "set-status", "k", "v", "--url", "https://" }, "ERROR: Invalid metadata URL 'https://' \u{2014} expected http(s) URL\n" },
        .{ &.{ "clear-status", "" }, "ERROR: Missing status key \u{2014} usage: clear-status <key> [--workspace=X]\n" },
    };
    for (cases) |c| {
        const argv = try std.mem.concat(h.alloc(), []const u8, &.{ &.{"cmux"}, c[0] });
        try kit.expectResult(h.run(argv), 1, "", c[1]);
    }
    try kit.expectResult(h.run(&.{ "cmux", "set-status", "k", "v", "--bogus" }), 2, "", "cmux: set-status: unexpected arguments: --bogus\n");
    try kit.expectResult(h.run(&.{ "cmux", "set-status", "k", "v", "--icon" }), 2, "", "cmux: set-status: --icon requires a value\n");
    try kit.expectResult(h.run(&.{ "cmux", "set-status", "k", "v", "--workspace", "pane:1" }), 2, "", "cmux: Invalid workspace handle: pane:1 (expected UUID, ref like workspace:1, or index)\n");
    try testing.expectEqual(n, h.requestCount());
}

test "unit: cli-sidebar: clear-status and list-status" {
    var h: Harness = undefined;
    try h.init(sidebarHandler);
    defer h.deinit();
    try kit.expectResult(h.run(&.{ "cmux", "clear-status", "build" }), 0, "OK\n", "");
    try testing.expectEqualStrings("wmux.sidebar.status.clear", h.last().method);
    try testing.expectEqualStrings("{\"key\":\"build\"}", params(&h));
    try kit.expectResult(h.run(&.{ "cmux", "clear-status", "a", "b" }), 2, "", "cmux: clear-status: unexpected arguments: b\n");
    const r = h.run(&.{ "cmux", "list-status", "--tab", "workspace:3" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("{\"workspace_id\":\"workspace:3\"}", params(&h));
    try kit.expectGolden(h.alloc(), "list-status.txt", r.out);
    try testing.expect(std.mem.startsWith(u8, r.out, "build=compiling icon=hammer color=#ff9500 priority=80\n"));
    const j = h.run(&.{ "cmux", "list-status", "--json" });
    _ = try std.json.parseFromSliceLeaky(std.json.Value, h.alloc(), j.out, .{});
    try kit.expectResult(h.run(&.{ "cmux", "list-status", "extra" }), 2, "", "cmux: list-status: unexpected arguments: extra\n");
    h.server.user = &h;
    try kit.expectResult(h.run(&.{ "cmux", "list-status" }), 0, "No status entries\n", "");
}

test "unit: cli-sidebar: set-progress clamps and validates" {
    var h: Harness = undefined;
    try h.init(sidebarHandler);
    defer h.deinit();
    try kit.expectResult(h.run(&.{ "cmux", "set-progress", "0.5", "--label", "Building..." }), 0, "OK\n", "");
    try testing.expectEqualStrings("wmux.sidebar.progress.set", h.last().method);
    try testing.expectEqualStrings("{\"value\":0.5,\"label\":\"Building...\"}", params(&h));
    _ = h.run(&.{ "cmux", "set-progress", "2" });
    try testing.expectEqualStrings("{\"value\":1}", params(&h));
    _ = h.run(&.{ "cmux", "set-progress", "-0.25" });
    try testing.expectEqualStrings("{\"value\":0}", params(&h));
    for ([_][]const u8{ "abc", "nan", "inf", "", "1e999" }) |bad| {
        const want = try std.fmt.allocPrint(h.alloc(), "ERROR: Invalid progress value '{s}' \u{2014} must be 0.0 to 1.0\n", .{bad});
        try kit.expectResult(h.run(&.{ "cmux", "set-progress", bad }), 1, "", want);
    }
    try kit.expectResult(h.run(&.{ "cmux", "set-progress" }), 1, "", "ERROR: Missing progress value \u{2014} usage: set-progress <0.0-1.0> [--label=X] [--workspace=X]\n");
    try kit.expectResult(h.run(&.{ "cmux", "set-progress", "0.1", "0.2" }), 2, "", "cmux: set-progress: unexpected arguments: 0.2\n");
    try kit.expectResult(h.run(&.{ "cmux", "clear-progress" }), 0, "OK\n", "");
    try testing.expectEqualStrings("wmux.sidebar.progress.clear", h.last().method);
    try kit.expectResult(h.run(&.{ "cmux", "clear-progress", "now" }), 2, "", "cmux: clear-progress: unexpected arguments: now\n");
    try testing.expectEqual(@as(?f64, 0.75), sidebar.parseProgress(" 0.75 "));
    try testing.expectEqual(@as(?f64, null), sidebar.parseProgress("0.5x"));
}

test "unit: cli-sidebar: log levels, sources and message terminator" {
    var h: Harness = undefined;
    try h.init(sidebarHandler);
    defer h.deinit();
    try kit.expectResult(h.run(&.{ "cmux", "log", "--level", "error", "--source", "build", "Compilation failed" }), 0, "OK\n", "");
    try testing.expectEqualStrings("wmux.sidebar.log.append", h.last().method);
    try testing.expectEqualStrings("{\"message\":\"Compilation failed\",\"level\":\"error\",\"source\":\"build\"}", params(&h));
    _ = h.run(&.{ "cmux", "log", "hello", "world" });
    try testing.expectEqualStrings("{\"message\":\"hello world\",\"level\":\"info\"}", params(&h));
    _ = h.run(&.{ "cmux", "log", "--", "--not-an-option", "-x" });
    try testing.expectEqualStrings("{\"message\":\"--not-an-option -x\",\"level\":\"info\"}", params(&h));
    _ = h.run(&.{ "cmux", "log", "h\u{e9}llo \u{1F600}" });
    try testing.expectEqualStrings("h\u{e9}llo \u{1F600}", h.last().params.object.get("message").?.string);
    try kit.expectResult(h.run(&.{ "cmux", "log", "--level", "debug", "x" }), 1, "", "ERROR: Unknown log level 'debug' \u{2014} use: info, progress, success, warning, error\n");
    try kit.expectResult(h.run(&.{ "cmux", "log" }), 1, "", "ERROR: Missing message \u{2014} usage: log [--level=X] [--source=X] [--workspace=X] -- <message>\n");
    try kit.expectResult(h.run(&.{ "cmux", "log", "--" }), 1, "", "ERROR: Missing message \u{2014} usage: log [--level=X] [--source=X] [--workspace=X] -- <message>\n");
    try kit.expectResult(h.run(&.{ "cmux", "clear-log" }), 0, "OK\n", "");
    try testing.expectEqualStrings("wmux.sidebar.log.clear", h.last().method);
    // A huge message is sent whole.
    const big = try h.alloc().alloc(u8, 200_000);
    @memset(big, 'a');
    try kit.expectResult(h.run(&.{ "cmux", "log", big }), 0, "OK\n", "");
    try testing.expectEqual(@as(usize, 200_000), h.last().params.object.get("message").?.string.len);
}

test "unit: cli-sidebar: list-log limit and lines" {
    var h: Harness = undefined;
    try h.init(sidebarHandler);
    defer h.deinit();
    const r = h.run(&.{ "cmux", "list-log" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try kit.expectGolden(h.alloc(), "list-log.txt", r.out);
    try kit.expectResult(h.run(&.{ "cmux", "list-log", "--limit", "1" }), 0, "[build] [error] Compilation failed\n", "");
    try testing.expectEqualStrings("{\"limit\":1}", params(&h));
    const all = h.run(&.{ "cmux", "list-log", "--limit=0" });
    try testing.expectEqualStrings(r.out, all.out);
    try testing.expectEqualStrings("{}", params(&h));
    try kit.expectResult(h.run(&.{ "cmux", "list-log", "--limit", "-1" }), 1, "", "ERROR: Invalid limit '-1' \u{2014} must be >= 0\n");
    try kit.expectResult(h.run(&.{ "cmux", "list-log", "--limit", "many" }), 1, "", "ERROR: Invalid limit 'many' \u{2014} must be >= 0\n");
    h.server.user = &h;
    try kit.expectResult(h.run(&.{ "cmux", "list-log" }), 0, "No log entries\n", "");
}

test "unit: cli-sidebar: sidebar-state dump" {
    var h: Harness = undefined;
    try h.init(sidebarHandler);
    defer h.deinit();
    h.setEnv("CMUX_WORKSPACE_ID", ws_uuid);
    const r = h.run(&.{ "cmux", "sidebar-state" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("wmux.sidebar.state", h.last().method);
    try testing.expectEqualStrings("{\"workspace_id\":\"" ++ ws_uuid ++ "\"}", params(&h));
    try kit.expectGolden(h.alloc(), "sidebar-state.txt", r.out);
    h.server.user = &h;
    const e = h.run(&.{ "cmux", "sidebar-state", "--window", "window:1" });
    try testing.expectEqualStrings("{\"window_id\":\"window:1\"}", params(&h));
    try kit.expectGolden(h.alloc(), "sidebar-state-empty.txt", e.out);
    const j = h.run(&.{ "cmux", "sidebar-state", "--json" });
    try testing.expectEqualStrings("{}\n", j.out);
}

test "unit: cli-sidebar: sidebar-state skips malformed ports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "[3000,{},null,5173,{\"x\":1}]", "ports=3000,5173\n" },
        .{ "[{},3000]", "ports=3000\n" },
        .{ "[3000,true]", "ports=3000\n" },
        .{ "[\"8080\",80.0,443]", "ports=8080,80,443\n" },
        .{ "[null,[]]", "ports=none\n" },
    };
    for (cases) |c| {
        const r = try std.json.parseFromSliceLeaky(std.json.Value, a, try std.fmt.allocPrint(a, "{{\"ports\":{s}}}", .{c[0]}), .{});
        var aw: std.Io.Writer.Allocating = .init(a);
        try sidebar.writeSidebarState(&aw.writer, r);
        try kit.expectContains(aw.written(), c[1]);
    }
}

const Script = struct {
    var calls: [8][]const u8 = undefined;
    var n: usize = 0;
    var repo_json: []const u8 = "{\"nameWithOwner\":\"me/fork\",\"url\":\"https://github.com/me/fork\",\"parent\":{\"nameWithOwner\":\"Owner/Repo\"}}";
    var gh_missing = false;
    var git_missing = false;
    var pr_fails = false;

    fn reset() void {
        n = 0;
        repo_json = "{\"nameWithOwner\":\"me/fork\",\"url\":\"https://github.com/me/fork\",\"parent\":{\"nameWithOwner\":\"Owner/Repo\"}}";
        gh_missing = false;
        git_missing = false;
        pr_fails = false;
    }

    fn run(arena: std.mem.Allocator, argv: []const []const u8) anyerror!pr.RunResult {
        calls[n] = try std.mem.join(arena, " ", argv);
        n += 1;
        if (std.mem.eql(u8, argv[0], "git")) {
            if (git_missing) return error.FileNotFound;
            return .{ .code = 0, .stdout = "C:/src/api\n", .stderr = "" };
        }
        if (gh_missing) return error.FileNotFound;
        if (std.mem.eql(u8, argv[1], "repo")) return .{ .code = 0, .stdout = repo_json, .stderr = "" };
        if (pr_fails) return .{ .code = 1, .stdout = "", .stderr = "GraphQL: Could not resolve to a PullRequest\nmore\n" };
        return .{ .code = 0, .stdout = "{\"number\":123,\"url\":\"https://github.com/Owner/Repo/pull/123\",\"state\":\"MERGED\",\"headRefName\":\"feat/x\"}", .stderr = "" };
    }
};

test "unit: cli-sidebar: pr selector parsing" {
    try testing.expect(pr.parseSelector("clear").? == .clear);
    try testing.expectEqual(@as(u64, 123), pr.parseSelector("123").?.number);
    try testing.expectEqual(@as(u64, 7), pr.parseSelector("#7").?.number);
    const u = pr.parseSelector("https://github.com/o/r/pull/45/files?x=1#y").?.url;
    try testing.expectEqualStrings("o", u.owner);
    try testing.expectEqualStrings("r", u.repo);
    try testing.expectEqual(@as(u64, 45), u.number);
    for ([_][]const u8{ "", "0", "#0", "-1", "abc", "#", "12a", "https://github.com/o/r/issues/4", "https://github.com/o/r/pull/", "https://github.com/o/pull/4", "ftp://github.com/o/r/pull/4", "9999999999999999999999", "\u{1F600}" }) |bad| {
        try testing.expect(pr.parseSelector(bad) == null);
    }
    const cands = [_][]const u8{ "me/fork", "Owner/Repo" };
    try testing.expectEqualStrings("Owner/Repo", pr.matchRepo(pr.parseSelector("https://github.com/owner/repo/pull/1").?.url, &cands).?);
    try testing.expect(pr.matchRepo(pr.parseSelector("https://gitlab.com/owner/repo/pull/1").?.url, &cands) == null);
    try testing.expect(pr.matchRepo(pr.parseSelector("https://github.com/other/repo/pull/1").?.url, &cands) == null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(try pr.dirWithin(arena.allocator(), "C:\\src\\API\\sub", "C:/src/api"));
    try testing.expect(try pr.dirWithin(arena.allocator(), "C:/src/api/", "C:/src/api"));
    try testing.expect(!try pr.dirWithin(arena.allocator(), "C:/src/apiary", "C:/src/api"));
    try testing.expect(!try pr.dirWithin(arena.allocator(), "C:/src", ""));
}

test "unit: cli-sidebar: pr attaches, clears and validates" {
    var h: Harness = undefined;
    try h.init(sidebarHandler);
    defer h.deinit();
    const saved = pr.runner;
    defer pr.runner = saved;
    pr.runner = Script.run;
    Script.reset();
    h.setEnv("CMUX_WORKSPACE_ID", ws_uuid);
    try kit.expectResult(h.run(&.{ "cmux", "pr", "https://github.com/owner/repo/pull/123" }), 0, "OK\n", "");
    try testing.expectEqualStrings("wmux.workspace.pr.set", h.last().method);
    try testing.expectEqualStrings("{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"number\":123,\"url\":\"https://github.com/Owner/Repo/pull/123\",\"state\":\"merged\",\"branch\":\"feat/x\"}", params(&h));
    try testing.expectEqual(@as(usize, 2), Script.n);
    try testing.expectEqualStrings("gh repo view --json nameWithOwner,url,parent", Script.calls[0]);
    try testing.expectEqualStrings("gh pr view 123 --repo Owner/Repo --json number,url,state,headRefName", Script.calls[1]);
    Script.reset();
    _ = h.run(&.{ "cmux", "pr", "#123", "--workspace", "workspace:2" });
    try testing.expectEqualStrings("gh pr view 123 --repo me/fork --json number,url,state,headRefName", Script.calls[1]);
    try testing.expectEqualStrings("workspace:2", h.last().params.object.get("workspace_id").?.string);
    const j = h.run(&.{ "cmux", "pr", "123", "--json" });
    try kit.expectContains(j.out, "\"cleared\": false");
    Script.reset();
    try kit.expectResult(h.run(&.{ "cmux", "pr", "clear" }), 0, "OK\n", "");
    try testing.expectEqualStrings("wmux.workspace.pr.clear", h.last().method);
    try testing.expectEqualStrings("{\"workspace_id\":\"" ++ ws_uuid ++ "\"}", params(&h));
    try testing.expectEqual(@as(usize, 0), Script.n);
    const n = h.requestCount();
    try kit.expectResult(h.run(&.{ "cmux", "pr", "https://github.com/other/repo/pull/1" }), 1, "", pr.foreign_message ++ "\n");
    try kit.expectResult(h.run(&.{ "cmux", "pr", "banana" }), 2, "", pr.expects_message ++ "\n");
    try kit.expectResult(h.run(&.{ "cmux", "pr" }), 2, "", pr.expects_message ++ "\n");
    try kit.expectResult(h.run(&.{ "cmux", "pr", "1", "2" }), 2, "", "cmux: pr: unexpected arguments: 2\n");
    Script.repo_json = "{\"nameWithOwner\":\"me/x\",\"url\":\"https://ghe.example.com/me/x\"}";
    try kit.expectResult(h.run(&.{ "cmux", "pr", "5" }), 1, "", "cmux pr: only github.com repositories are supported\n");
    Script.reset();
    Script.pr_fails = true;
    try kit.expectResult(h.run(&.{ "cmux", "pr", "5" }), 1, "", "cmux pr: gh pr failed: GraphQL: Could not resolve to a PullRequest\n");
    Script.reset();
    Script.gh_missing = true;
    try kit.expectResult(h.run(&.{ "cmux", "pr", "5" }), 1, "", "cmux pr: requires the GitHub CLI (gh) on PATH\n");
    Script.repo_json = "not json";
    Script.gh_missing = false;
    try kit.expectResult(h.run(&.{ "cmux", "pr", "5" }), 1, "", "cmux pr: unexpected output from gh repo view\n");
    try testing.expectEqual(n, h.requestCount());
    // wmux branding rewrites the messages.
    try kit.expectResult(h.run(&.{ "wmux", "pr", "banana" }), 2, "", "wmux pr expects a pull-request URL or a positive pull-request number\n");
}

test "unit: cli-sidebar: pr finds the workspace open in this worktree" {
    var h: Harness = undefined;
    try h.init(sidebarHandler);
    defer h.deinit();
    const saved = pr.runner;
    defer pr.runner = saved;
    pr.runner = Script.run;
    Script.reset();
    try kit.expectResult(h.run(&.{ "cmux", "pr", "clear" }), 0, "OK\n", "");
    try testing.expectEqualStrings("git rev-parse --show-toplevel", Script.calls[0]);
    try testing.expectEqualStrings("{\"workspace_id\":\"W1\"}", params(&h));
    // Without git the worktree lookup names git, not the GitHub CLI.
    Script.reset();
    Script.git_missing = true;
    try kit.expectResult(h.run(&.{ "cmux", "pr", "clear" }), 1, "", "cmux pr: requires git on PATH\n");
}

test "unit: cli-sidebar: goldens for help" {
    var h: Harness = undefined;
    try h.init(sidebarHandler);
    defer h.deinit();
    const cases = [_][]const u8{ "set-status", "clear-status", "list-status", "set-progress", "clear-progress", "log", "clear-log", "list-log", "sidebar-state", "pr" };
    for (cases) |c| {
        const r = h.run(&.{ "cmux", c, "--help" });
        try testing.expectEqual(@as(u8, 0), r.code);
        try testing.expect(std.mem.startsWith(u8, r.out, "Usage: cmux "));
        try kit.expectGolden(h.alloc(), try std.fmt.allocPrint(h.alloc(), "{s}-help.txt", .{c}), r.out);
    }
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
}
