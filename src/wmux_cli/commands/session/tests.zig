//! Tests of the `session` family: restore-session and surface resume.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("../cli_misc/harness.zig");
const fake = @import("../../fake.zig");
const session = @import("../session.zig");
const surface_resume = @import("surface_resume.zig");

fn echo(server: *fake.Server, req: fake.Request) fake.Action {
    if (std.mem.eql(u8, req.method, "session.import")) return .{ .ok = "{\"path\":\"/t/s.json\",\"held_back_resume_count\":1,\"dropped_remote_workspace_count\":2}" };
    if (std.mem.eql(u8, req.method, "surface.resume.get")) {
        if (req.params.object.get("surface_id")) |s| {
            if (std.mem.eql(u8, s.string, "surface:9")) return .{ .ok = "{\"surface_id\":\"S9\",\"resume_binding\":null}" };
            if (std.mem.eql(u8, s.string, "surface:8")) return .{ .ok = "{\"surface_id\":\"S8\",\"resume_binding\":{\"kind\":\"x\",\"command\":null}}" };
        }
        return .{ .ok = "{\"surface_id\":\"S1\",\"surface_ref\":\"surface:1\",\"resume_binding\":{\"kind\":\"tmux\",\"command\":\"tmux attach -t work\",\"checkpointId\":\"work\"}}" };
    }
    if (std.mem.eql(u8, req.method, "surface.resume.clear")) return .{ .ok = "{\"cleared\":true,\"resume_binding\":null}" };
    if (std.mem.eql(u8, req.method, "surface.resume.set")) return .{ .ok = "{\"approval_required\":true}" };
    return .{ .ok = std.fmt.allocPrint(server.a, "{{\"echo\":{s}}}", .{req.params_json}) catch unreachable };
}

test "unit: cli-restore-session: --from classification follows the cmux rule" {
    try testing.expectEqual(session.FromKind.source, session.classifyFrom("nightly", true));
    try testing.expectEqual(session.FromKind.source, session.classifyFrom("debug:feature", false));
    try testing.expectEqual(session.FromKind.source, session.classifyFrom("dev:abc", false));
    try testing.expectEqual(session.FromKind.source, session.classifyFrom("com.cmuxterm.app.nightly", true));
    try testing.expectEqual(session.FromKind.path, session.classifyFrom("./nightly", false));
    try testing.expectEqual(session.FromKind.path, session.classifyFrom("~/s.json", false));
    try testing.expectEqual(session.FromKind.path, session.classifyFrom("dir/x", false));
    try testing.expectEqual(session.FromKind.path, session.classifyFrom("dir\\x", false));
    try testing.expectEqual(session.FromKind.path, session.classifyFrom("SESSION.JSON", false));
    try testing.expectEqual(session.FromKind.path, session.classifyFrom("backup", true));
    try testing.expectEqual(session.FromKind.source, session.classifyFrom("backup", false));
    try testing.expectEqual(session.FromKind.source, session.classifyFrom("debug:", false));
    try testing.expect(!session.isSourceName("debug:"));
    try testing.expect(!session.isSourceName(""));
}

test "unit: cli-restore-session: bare restore, import and export params" {
    var h: harness.Harness = undefined;
    h.init();
    defer h.deinit();
    h.serve(echo);
    const a = h.alloc();
    const bare = h.run(&.{ "cmux", "restore-session" });
    try harness.expectOk(bare);
    try testing.expectEqualStrings("OK\n", bare.out);
    try testing.expectEqualStrings("session.restore_previous", h.last().method);
    try testing.expectEqualStrings("{}", h.last().params_json);

    const src = h.run(&.{ "cmux", "restore-session", "--from", "nightly" });
    try harness.expectOk(src);
    try testing.expectEqualStrings("session.import", h.last().method);
    try testing.expectEqualStrings("{\"source\":\"nightly\"}", h.last().params_json);
    try harness.expectGolden(a, "restore-session-from.txt", src.out);

    _ = h.run(&.{ "cmux", "restore-session", "--from", "saved.json" });
    try testing.expectEqualStrings(harness.p(a, &.{ harness.root, "work", "saved.json" }), h.last().params.object.get("path").?.string);

    const ex = h.run(&.{ "cmux", "restore-session", "--export", "out.json", "--force" });
    try harness.expectOk(ex);
    try testing.expectEqualStrings("session.export", h.last().method);
    try testing.expectEqualStrings(harness.p(a, &.{ harness.root, "work", "out.json" }), h.last().params.object.get("path").?.string);
    try testing.expectEqual(true, h.last().params.object.get("force").?.bool);
    try harness.expectGolden(a, "restore-session-export.txt", ex.out);
    _ = h.run(&.{ "cmux", "restore-session", "--export=o.json" });
    try testing.expectEqual(false, h.last().params.object.get("force").?.bool);
}

test "unit: cli-restore-session: argument errors and the not-running message" {
    var h: harness.Harness = undefined;
    h.init();
    defer h.deinit();
    try harness.expectFail(h.run(&.{ "cmux", "restore-session", "--from", "a", "--export", "b" }), 2, "--from and --export cannot be combined");
    try harness.expectFail(h.run(&.{ "cmux", "restore-session", "--force" }), 2, "--force requires --export");
    try harness.expectFail(h.run(&.{ "cmux", "restore-session", "--from" }), 2, "--from requires a value");
    try harness.expectFail(h.run(&.{ "cmux", "restore-session", "--from", " " }), 2, "--from requires a value");
    try harness.expectFail(h.run(&.{ "cmux", "restore-session", "--export", "" }), 2, "--export requires a value");
    try harness.expectFail(h.run(&.{ "cmux", "restore-session", "stray" }), 2, "unexpected argument 'stray'");
    try harness.expectFail(h.run(&.{ "cmux", "restore-session", "--merge" }), 2, "restore-session: unknown flag '--merge'");
    // No app: import/export refuse and never spawn wmux.exe.
    const r = h.run(&.{ "cmux", "restore-session", "--from", "nightly" });
    try harness.expectFail(r, 1, "restore-session: cmux is not running. Open cmux, then run this command again.");
    const w = h.run(&.{ "wmux", "restore-session", "--export", "x.json" });
    try harness.expectFail(w, 1, "restore-session: wmux is not running. Open wmux, then run this command again.");
    try testing.expectEqual(@as(usize, 0), h.fp.spawned.items.len);
    const help = h.run(&.{ "cmux", "restore-session", "--help" });
    try harness.expectOk(help);
    try harness.expectGolden(h.alloc(), "restore-session-help.txt", help.out);
}

test "unit: cli-surface-resume: show defaults to the caller and renders the three cases" {
    var h: harness.Harness = undefined;
    h.init();
    defer h.deinit();
    h.serve(echo);
    h.setEnv("CMUX_WORKSPACE_ID", "WS-1");
    h.setEnv("CMUX_SURFACE_ID", "SF-1");
    const r = h.run(&.{ "cmux", "surface", "resume" });
    try harness.expectOk(r);
    try testing.expectEqualStrings("surface.resume.get", h.last().method);
    try testing.expectEqualStrings("{\"workspace_id\":\"WS-1\",\"surface_id\":\"SF-1\"}", h.last().params_json);
    try harness.expectGolden(h.alloc(), "surface-resume-show.txt", r.out);
    const none = h.run(&.{ "cmux", "surface-resume", "get", "--surface", "surface:9" });
    try testing.expectEqualStrings("No resume binding\n", none.out);
    // --surface given: the workspace still defaults, the surface does not.
    try testing.expectEqualStrings("{\"workspace_id\":\"WS-1\",\"surface_id\":\"surface:9\"}", h.last().params_json);
    const private = h.run(&.{ "cmux", "surface-resume", "show", "--surface", "surface:8" });
    try testing.expectEqualStrings("null\n", private.out);
    // --window drops both defaults.
    _ = h.run(&.{ "cmux", "surface-resume", "--window", "window:1" });
    try testing.expectEqualStrings("{\"window_id\":\"window:1\"}", h.last().params_json);
    const js = h.run(&.{ "cmux", "surface-resume", "show", "--json" });
    try harness.expectOk(js);
    try harness.expectGolden(h.alloc(), "surface-resume-show-json.txt", js.out);
}

test "unit: cli-surface-resume: set with --shell and with -- argv" {
    var h: harness.Harness = undefined;
    h.init();
    defer h.deinit();
    h.serve(echo);
    h.setEnv("CMUX_SURFACE_ID", "SF-1");
    const r = h.run(&.{ "cmux", "surface", "resume", "set", "--kind", "tmux", "--checkpoint", "work", "--shell", "tmux attach -t work" });
    try harness.expectOk(r);
    try harness.expectGolden(h.alloc(), "surface-resume-set.txt", r.out);
    const req = h.last();
    try testing.expectEqualStrings("surface.resume.set", req.method);
    try testing.expectEqualStrings("SF-1", req.params.object.get("surface_id").?.string);
    try testing.expectEqualStrings("tmux", req.params.object.get("kind").?.string);
    try testing.expectEqualStrings("work", req.params.object.get("checkpoint_id").?.string);
    try testing.expectEqualStrings("cli", req.params.object.get("source").?.string);
    try testing.expectEqualStrings("tmux attach -t work", req.params.object.get("command").?.string);
    try testing.expectEqualStrings(harness.p(h.alloc(), &.{ harness.root, "work" }), req.params.object.get("cwd").?.string);
    try testing.expect(req.params.object.get("launch_command") == null);

    _ = h.run(&.{ "cmux", "surface-resume", "set", "--checkpoint", "a", "--checkpoint-id", "b", "--source", "agent", "--cwd", "proj", "--", "claude", "--resume", "it's \u{e9}" });
    const r2 = h.last();
    try testing.expectEqualStrings("b", r2.params.object.get("checkpoint_id").?.string);
    try testing.expectEqualStrings("agent", r2.params.object.get("source").?.string);
    try testing.expectEqualStrings(harness.p(h.alloc(), &.{ harness.root, "work", "proj" }), r2.params.object.get("cwd").?.string);
    try testing.expectEqualStrings("claude --resume 'it'\\''s \u{e9}'", r2.params.object.get("command").?.string);
    try testing.expectEqualStrings("{\"argv\":[\"claude\",\"--resume\",\"it's \u{e9}\"]}", try std.json.Stringify.valueAlloc(h.alloc(), r2.params.object.get("launch_command").?, .{}));
}

test "unit: cli-surface-resume: set takes $PWD only when it is a native absolute path" {
    // A native absolute PWD (the shell's logical spelling) wins over the
    // process cwd on every host.
    {
        var h: harness.Harness = undefined;
        h.init();
        defer h.deinit();
        h.serve(echo);
        const logical = harness.p(h.alloc(), &.{ harness.root, "logical" });
        h.setEnv("PWD", logical);
        try harness.expectOk(h.run(&.{ "cmux", "surface-resume", "set", "--surface", "surface:1", "--shell", "make" }));
        try testing.expectEqualStrings(logical, h.last().params.object.get("cwd").?.string);
    }
    // Git Bash exports PWD in MSYS form, which is not a Windows path: there
    // the process cwd is sent instead.
    {
        var h: harness.Harness = undefined;
        h.init();
        defer h.deinit();
        h.serve(echo);
        h.setEnv("PWD", "/c/Users/me/proj");
        try harness.expectOk(h.run(&.{ "cmux", "surface-resume", "set", "--surface", "surface:1", "--shell", "make" }));
        const want = if (builtin.os.tag == .windows) harness.p(h.alloc(), &.{ harness.root, "work" }) else "/c/Users/me/proj";
        try testing.expectEqualStrings(want, h.last().params.object.get("cwd").?.string);
    }
}

test "unit: cli-surface-resume: set and clear validation, clear guards" {
    var h: harness.Harness = undefined;
    h.init();
    defer h.deinit();
    h.serve(echo);
    try harness.expectFail(h.run(&.{ "cmux", "surface-resume", "set" }), 2, "requires --shell <command> or -- <argv...>");
    try harness.expectFail(h.run(&.{ "cmux", "surface-resume", "set", "--shell", "tmux", "attach" }), 2, "unexpected argument 'attach' after the --shell value");
    try harness.expectFail(h.run(&.{ "cmux", "surface-resume", "set", "--shell", "a", "--", "b" }), 2, "not both");
    try harness.expectFail(h.run(&.{ "cmux", "surface-resume", "set", "--shell", "  " }), 2, "--shell requires a non-empty command");
    try harness.expectFail(h.run(&.{ "cmux", "surface-resume", "set", "--shell" }), 2, "--shell requires a value");
    try harness.expectFail(h.run(&.{ "cmux", "surface-resume", "set", "--surface", "", "--shell", "x" }), 2, "Surface handle is blank");
    try harness.expectFail(h.run(&.{ "cmux", "surface-resume", "set", "--surface", "nope", "--shell", "x" }), 2, "Invalid surface handle: nope (expected UUID, ref like surface:1, or index)");
    try harness.expectFail(h.run(&.{ "cmux", "surface-resume", "frob" }), 2, "unknown surface resume subcommand 'frob'");
    try harness.expectFail(h.run(&.{ "cmux", "surface", "ls" }), 2, "not supported on wmux");
    try harness.expectFail(h.run(&.{ "cmux", "surface", "pick" }), 2, "unknown surface subcommand 'pick'");
    try harness.expectFail(h.run(&.{ "cmux", "surface" }), 2, "surface requires a subcommand");
    try harness.expectFail(h.run(&.{ "cmux", "surface-resume", "show", "extra" }), 2, "unexpected argument 'extra'");
    try testing.expectEqual(@as(usize, 0), h.requestCount());

    const c = h.run(&.{ "cmux", "surface", "resume", "clear", "--surface", "surface:2", "--checkpoint", "work", "--source", "cli" });
    try harness.expectOk(c);
    try testing.expectEqualStrings("OK cleared=true\n", c.out);
    try testing.expectEqualStrings("surface.resume.clear", h.last().method);
    try testing.expectEqualStrings("{\"surface_id\":\"surface:2\",\"checkpoint_id\":\"work\",\"source\":\"cli\"}", h.last().params_json);
    try testing.expectEqualStrings("No resume binding", surface_resume.bindingText(.null));
}

test "unit: cli-surface-resume: help is offline and shared by both spellings" {
    var h: harness.Harness = undefined;
    h.init();
    defer h.deinit();
    const a = h.run(&.{ "cmux", "surface", "--help" });
    const b = h.run(&.{ "cmux", "surface-resume", "--help" });
    try harness.expectOk(a);
    try testing.expectEqualStrings(a.out, b.out);
    try harness.expectContains(a.out, "cmux surface resume set [flags] -- <argv...>");
    try harness.expectContains(a.out, "cmux surface resume show [--json] [flags]");
    try harness.expectGolden(h.alloc(), "surface-resume-help.txt", a.out);
}
