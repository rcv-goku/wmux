//! CLI command family `workspace` (Appendix C).
//! list-workspaces, new-workspace, select-workspace, rename-workspace
//! (rename-window), close-workspace, current-workspace, workspace
//! list|create|env|close|rename|select, workspace-action, reorder-workspace,
//! reorder-workspaces, next-window, previous-window, last-window (W2-1);
//! workspace status (W5a); workspace reconnect|disconnect (W6-1).
//!
//! The `workspace` namespace is one command that dispatches its verbs;
//! `workspace group <sub>` is the `workspace-group` namespace. Legacy verbs
//! print cmux's alias notice. Implementation pieces live in `ws/`.

const std = @import("std");
const proto = @import("wmux_proto");
const command = @import("../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../output.zig");
const common = @import("ws/common.zig");
const create = @import("ws/create.zig");
const reorder = @import("ws/reorder.zig");
const status = @import("ws/status.zig");
const workspace_group = @import("workspace_group.zig");
const Def = common.opts.Def;
const Params = common.Params;

const u_list = "Usage: cmux list-workspaces [--window <id|ref|index>]";
const u_current = "Usage: cmux current-workspace [--window <id|ref|index>]";
const u_new = "Usage: cmux new-workspace [--name <title>] [--description <text>] [--cwd <path>] [--command <text>] [--env KEY=VALUE]... [--env-file <path>]... [--layout <json>] [--window <id|ref|index>] [--focus <true|false>] [--group <id|ref>] [--group-placement afterCurrent|top|end] [--group-reference <workspace>]";
const u_select = "Usage: cmux select-workspace --workspace <id|ref|index> [--window <id|ref|index>]";
const u_rename = "Usage: cmux rename-workspace [--workspace <id|ref|index>] [--] <title>";
const u_close = "Usage: cmux close-workspace --workspace <id|ref|index> [--window <id|ref|index>] [--force]";
const u_next = "Usage: cmux next-window [--window <id|ref|index>]";
const u_previous = "Usage: cmux previous-window [--window <id|ref|index>]";
const u_last = "Usage: cmux last-window [--window <id|ref|index>]";
const u_ns = "Usage: cmux workspace <list|create|env|close|rename|select|status|reconnect|disconnect|group> [args]";

const u_ns_list = "Usage: cmux workspace list [--window <id|ref|index>]";
const u_ns_create = "Usage: cmux workspace create [new-workspace flags]";
const u_ns_env = "Usage: cmux workspace env [<id|ref|index> | --workspace <id|ref|index>] [--mask]";
const u_ns_close = "Usage: cmux workspace close <id|ref|index> [--window <id|ref|index>] [--force]";
const u_ns_rename = "Usage: cmux workspace rename [<id|ref|index>] --title <title>";
const u_ns_select = "Usage: cmux workspace select <id|ref|index> [--window <id|ref|index>]";
const u_ns_status = "Usage: cmux workspace status [set <todo|working|needs-attention|review|done|auto|none> | cycle] [--workspace <id|ref|index>] [--window <id|ref|index>]";
const u_ns_reconnect = "Usage: cmux workspace reconnect [<id|ref|index>] [--workspace <id|ref|index>]";
const u_ns_disconnect = "Usage: cmux workspace disconnect [<id|ref|index>] [--workspace <id|ref|index>]";

/// `CommandSpec` entries (ADR-4.9).
pub const commands = [_]CommandSpec{
    .{ .name = "list-workspaces", .group = .start, .usage = u_list, .help = @embedFile("../help/list-workspaces.txt"), .legacy_notice = true, .legacy_alias_of = "workspace list", .run = runListLegacy },
    .{ .name = "current-workspace", .group = .start, .usage = u_current, .help = @embedFile("../help/current-workspace.txt"), .run = runCurrent },
    .{ .name = "new-workspace", .group = .start, .usage = u_new, .help = @embedFile("../help/new-workspace.txt"), .legacy_notice = true, .legacy_alias_of = "workspace create", .run = runNewLegacy },
    .{ .name = "select-workspace", .group = .start, .usage = u_select, .help = @embedFile("../help/select-workspace.txt"), .legacy_notice = true, .legacy_alias_of = "workspace select", .run = runSelectLegacy },
    .{ .name = "rename-workspace", .aliases = &.{"rename-window"}, .group = .start, .usage = u_rename, .help = @embedFile("../help/rename-workspace.txt"), .legacy_notice = true, .legacy_alias_of = "workspace rename", .run = runRenameLegacy },
    .{ .name = "close-workspace", .group = .start, .usage = u_close, .help = @embedFile("../help/close-workspace.txt"), .legacy_notice = true, .legacy_alias_of = "workspace close", .run = runCloseLegacy },
    .{ .name = "workspace", .group = .start, .usage = u_ns, .help = @embedFile("../help/workspace.txt"), .run = runNamespace },
    .{ .name = "workspace-action", .group = .start, .usage = reorder.u_action, .help = @embedFile("../help/workspace-action.txt"), .run = reorder.runAction },
    .{ .name = "reorder-workspace", .group = .start, .usage = reorder.u_reorder, .help = @embedFile("../help/reorder-workspace.txt"), .run = reorder.runReorder },
    .{ .name = "reorder-workspaces", .group = .start, .usage = reorder.u_reorder_many, .help = @embedFile("../help/reorder-workspaces.txt"), .run = reorder.runReorderMany },
    .{ .name = "next-window", .group = .start, .usage = u_next, .help = @embedFile("../help/next-window.txt"), .run = runNext },
    .{ .name = "previous-window", .group = .start, .usage = u_previous, .help = @embedFile("../help/previous-window.txt"), .run = runPrevious },
    .{ .name = "last-window", .group = .start, .usage = u_last, .help = @embedFile("../help/last-window.txt"), .run = runLast },
};

const window_defs = [_]Def{.{ .name = "--window" }};

// ----- namespace -----

pub const verbs = [_][]const u8{ "list", "create", "env", "close", "rename", "select", "status", "reconnect", "disconnect", "group" };

fn runNamespace(ctx: *Ctx) !u8 {
    const a = ctx.args();
    if (a.len == 0) return common.usage(ctx, u_ns, "workspace requires a subcommand: {s}", .{try std.mem.join(ctx.arena, ", ", &verbs)});
    const sub = a[0];
    const rest = a[1..];
    const eql = std.mem.eql;
    if (eql(u8, sub, "list")) return runList(ctx, rest, u_ns_list);
    if (eql(u8, sub, "create")) return create.run(ctx, rest, u_ns_create);
    if (eql(u8, sub, "env")) return create.runEnv(ctx, rest, u_ns_env);
    if (eql(u8, sub, "close")) return runClose(ctx, rest, u_ns_close, "workspace close");
    if (eql(u8, sub, "rename")) return runRenameNs(ctx, rest);
    if (eql(u8, sub, "select")) return runSelect(ctx, rest, u_ns_select, "workspace select");
    if (eql(u8, sub, "status")) return status.runStatus(ctx, rest, u_ns_status);
    if (eql(u8, sub, "reconnect")) return status.runRemote(ctx, rest, u_ns_reconnect, "workspace.remote.reconnect");
    if (eql(u8, sub, "disconnect")) return status.runRemote(ctx, rest, u_ns_disconnect, "workspace.remote.disconnect");
    if (eql(u8, sub, "group")) return workspace_group.runNamespaceArgs(ctx, rest, "workspace group");
    return common.usage(ctx, u_ns, "unknown workspace subcommand '{s}'; expected one of: {s}", .{ sub, try std.mem.join(ctx.arena, ", ", &verbs) });
}

fn runListLegacy(ctx: *Ctx) !u8 {
    return runList(ctx, ctx.args(), u_list);
}

fn runNewLegacy(ctx: *Ctx) !u8 {
    return create.run(ctx, ctx.args(), u_new);
}

fn runSelectLegacy(ctx: *Ctx) !u8 {
    return runSelect(ctx, ctx.args(), u_select, "select-workspace");
}

fn runCloseLegacy(ctx: *Ctx) !u8 {
    return runClose(ctx, ctx.args(), u_close, "close-workspace");
}

// ----- list and current -----

fn runList(ctx: *Ctx, args: []const []const u8, u: []const u8) !u8 {
    var code: u8 = 0;
    const o = (try common.parseOpts(ctx, u, args, &window_defs, &code)) orelse return code;
    if (o.positionals.len > 0) return common.usage(ctx, u, "unexpected argument '{s}'", .{o.positionals[0]});
    var p = Params.init(ctx.arena);
    if (try common.putWindow(ctx, &p, u, o)) |c| return c;
    const v = switch (try common.request(ctx, "workspace.list", &p)) {
        .code => |c| return c,
        .ok => |v| v,
    };
    if (ctx.json()) {
        try common.writeJsonResult(ctx, v);
        return output.exit.ok;
    }
    const items = common.list(v, "workspaces") orelse &.{};
    if (items.len == 0) {
        try ctx.out.writeAll("No workspaces\n");
        return output.exit.ok;
    }
    for (items) |w| try writeListLine(ctx, w);
    return output.exit.ok;
}

/// `* workspace:2  <title>  [ssh:connected]  [selected]`: the remote tag
/// only for remote workspaces, `*` and `[selected]` for the selected one.
fn writeListLine(ctx: *Ctx, w: std.json.Value) !void {
    const selected = common.boolean(w, "selected");
    const handle = (try common.handleText(ctx, w, "workspace")) orelse "?";
    try ctx.out.print("{s}{s}  {s}", .{ if (selected) "* " else "  ", handle, common.str(w, "title") orelse "" });
    const remote = common.field(w, "remote");
    if (common.str(remote, "state")) |state| {
        try ctx.out.print("  [{s}:{s}]", .{ common.str(remote, "transport") orelse "ssh", state });
    }
    if (selected) try ctx.out.writeAll("  [selected]");
    try ctx.out.writeByte('\n');
}

fn runCurrent(ctx: *Ctx) !u8 {
    const u = u_current;
    var code: u8 = 0;
    const o = (try common.parseOpts(ctx, u, ctx.args(), &window_defs, &code)) orelse return code;
    if (o.positionals.len > 0) return common.usage(ctx, u, "unexpected argument '{s}'", .{o.positionals[0]});
    var p = Params.init(ctx.arena);
    if (try common.putWindow(ctx, &p, u, o)) |c| return c;
    const v = switch (try common.request(ctx, "workspace.current", &p)) {
        .code => |c| return c,
        .ok => |v| v,
    };
    if (ctx.json()) {
        try common.writeJsonResult(ctx, v);
        return output.exit.ok;
    }
    const handle = (try common.handleText(ctx, v, "workspace")) orelse return ctx.runtimeError("No workspace selected", .{});
    try ctx.out.print("{s}\n", .{handle});
    return output.exit.ok;
}

// ----- select, close, rename -----

const target_defs = [_]Def{ .{ .name = "--workspace" }, .{ .name = "--window" } };
const close_defs = [_]Def{ .{ .name = "--workspace" }, .{ .name = "--window" }, .{ .name = "--force", .takes_value = false } };

/// The workspace named by one positional or `--workspace` (not both).
fn explicitWorkspace(ctx: *Ctx, u: []const u8, o: common.opts.Opts, code: *u8) ?[]const u8 {
    if (o.positionals.len > 1) {
        code.* = common.usage(ctx, u, "unexpected argument '{s}'", .{o.positionals[1]});
        return null;
    }
    if (o.positionals.len == 1 and o.get("--workspace") != null) {
        code.* = common.usage(ctx, u, "give the workspace as an argument or --workspace, not both", .{});
        return null;
    }
    code.* = 0;
    return if (o.positionals.len == 1) o.positionals[0] else o.get("--workspace");
}

fn runSelect(ctx: *Ctx, args: []const []const u8, u: []const u8, name: []const u8) !u8 {
    var code: u8 = 0;
    const o = (try common.parseOpts(ctx, u, args, &target_defs, &code)) orelse return code;
    const ws = explicitWorkspace(ctx, u, o, &code) orelse {
        if (code != 0) return code;
        return common.usage(ctx, u, "{s} requires a workspace (<id|ref|index> or --workspace)", .{name});
    };
    var p = Params.init(ctx.arena);
    if (try common.putExplicitWorkspace(ctx, &p, u, "workspace_id", ws, common.windowText(ctx, o) != null)) |c| return c;
    if (try common.putWindow(ctx, &p, u, o)) |c| return c;
    return common.simple(ctx, "workspace.select", &p);
}

fn runClose(ctx: *Ctx, args: []const []const u8, u: []const u8, name: []const u8) !u8 {
    var code: u8 = 0;
    const o = (try common.parseOpts(ctx, u, args, &close_defs, &code)) orelse return code;
    const explicit = explicitWorkspace(ctx, u, o, &code);
    if (code != 0) return code;
    var p = Params.init(ctx.arena);
    if (try common.putWorkspaceTarget(ctx, &p, u, explicit, common.windowText(ctx, o) != null)) |c| return c;
    if (p.map.get("workspace_id") == null) return common.usage(ctx, u, "{s} requires a workspace (<id|ref|index> or --workspace)", .{name});
    if (try common.putWindow(ctx, &p, u, o)) |c| return c;
    if (o.has("--force")) try p.boolean("force", true);
    return common.simple(ctx, "workspace.close", &p);
}

/// `rename-workspace [--workspace <h>] [--] <title>` (tmux-style
/// `rename-window`): the remaining words are the title.
fn runRenameLegacy(ctx: *Ctx) !u8 {
    const u = u_rename;
    var code: u8 = 0;
    const o = (try common.parseOpts(ctx, u, ctx.args(), &target_defs, &code)) orelse return code;
    const title = try std.mem.join(ctx.arena, " ", o.positionals);
    if (std.mem.trim(u8, title, " \t\r\n").len == 0) return common.usage(ctx, u, "rename-workspace requires a title", .{});
    var p = Params.init(ctx.arena);
    if (try common.putWorkspaceTarget(ctx, &p, u, o.get("--workspace"), common.windowText(ctx, o) != null)) |c| return c;
    if (try common.putWindow(ctx, &p, u, o)) |c| return c;
    try p.str("title", title);
    return common.simple(ctx, "workspace.rename", &p);
}

fn runRenameNs(ctx: *Ctx, args: []const []const u8) !u8 {
    const u = u_ns_rename;
    var code: u8 = 0;
    const defs = [_]Def{ .{ .name = "--workspace" }, .{ .name = "--window" }, .{ .name = "--title" } };
    const o = (try common.parseOpts(ctx, u, args, &defs, &code)) orelse return code;
    const explicit = explicitWorkspace(ctx, u, o, &code);
    if (code != 0) return code;
    const title = o.get("--title") orelse "";
    if (std.mem.trim(u8, title, " \t\r\n").len == 0) return common.usage(ctx, u, "workspace rename requires --title <title>", .{});
    var p = Params.init(ctx.arena);
    if (try common.putWorkspaceTarget(ctx, &p, u, explicit, common.windowText(ctx, o) != null)) |c| return c;
    if (try common.putWindow(ctx, &p, u, o)) |c| return c;
    try p.str("title", title);
    return common.simple(ctx, "workspace.rename", &p);
}

// ----- next, previous, last -----

fn runCycle(ctx: *Ctx, u: []const u8, method: []const u8) !u8 {
    var code: u8 = 0;
    const o = (try common.parseOpts(ctx, u, ctx.args(), &window_defs, &code)) orelse return code;
    if (o.positionals.len > 0) return common.usage(ctx, u, "unexpected argument '{s}'", .{o.positionals[0]});
    var p = Params.init(ctx.arena);
    if (try common.putWindow(ctx, &p, u, o)) |c| return c;
    return common.simple(ctx, method, &p);
}

fn runNext(ctx: *Ctx) !u8 {
    return runCycle(ctx, u_next, "workspace.next");
}

fn runPrevious(ctx: *Ctx) !u8 {
    return runCycle(ctx, u_previous, "workspace.previous");
}

fn runLast(ctx: *Ctx) !u8 {
    return runCycle(ctx, u_last, "workspace.last");
}

// ----- tests -----

const testing = std.testing;
const testkit = @import("ws/testkit.zig");

test "unit: cli-workspace: offline help for every workspace command" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    const cases = [_]struct { []const []const u8, []const u8 }{
        .{ &.{"list-workspaces"}, "list-workspaces-help.txt" },
        .{ &.{"current-workspace"}, "current-workspace-help.txt" },
        .{ &.{"new-workspace"}, "new-workspace-help.txt" },
        .{ &.{"select-workspace"}, "select-workspace-help.txt" },
        .{ &.{"rename-workspace"}, "rename-workspace-help.txt" },
        .{ &.{"close-workspace"}, "close-workspace-help.txt" },
        .{ &.{"workspace"}, "workspace-help.txt" },
        .{ &.{"workspace-action"}, "workspace-action-help.txt" },
        .{ &.{"reorder-workspace"}, "reorder-workspace-help.txt" },
        .{ &.{"reorder-workspaces"}, "reorder-workspaces-help.txt" },
        .{ &.{"next-window"}, "next-window-help.txt" },
        .{ &.{"previous-window"}, "previous-window-help.txt" },
        .{ &.{"last-window"}, "last-window-help.txt" },
    };
    for (cases) |c| try testkit.expectHelpGolden(&h, c[0], c[1]);
    // Aliases and namespace verbs share the help.
    try testkit.expectHelpGolden(&h, &.{"rename-window"}, "rename-workspace-help.txt");
    try testkit.expectHelpGolden(&h, &.{ "workspace", "create" }, "workspace-help.txt");
    try testkit.expectHelpGolden(&h, &.{ "workspace", "status", "set" }, "workspace-help.txt");
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
}

const workspaces_json =
    \\{"window_id":"6F1D2C3B-0000-4000-8000-000000000001","window_ref":"window:1","workspaces":[
    \\{"id":"9B690000-0000-4000-8000-000000000001","ref":"workspace:1","index":0,"title":"api","custom_title":null,"pinned":true,"selected":false},
    \\{"id":"9B690000-0000-4000-8000-000000000002","ref":"workspace:2","index":1,"title":"build été 🚀","custom_title":"build","selected":true,"remote":{"transport":"ssh","state":"connected"}},
    \\{"id":"9B690000-0000-4000-8000-000000000005","ref":"workspace:5","index":2,"title":"","selected":false,"remote":{"transport":"mosh","state":"reconnecting"}}]}
;

test "unit: cli-workspace: list-workspaces and workspace list text, json and empty" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.list", workspaces_json);
    const out = try testkit.expectOk(&h, &.{"list-workspaces"});
    try testkit.expectGolden(h.alloc(), "list-workspaces.txt", out);
    try h.expectLast("workspace.list", "{}");
    try testing.expectEqualStrings(out, try testkit.expectOk(&h, &.{ "workspace", "list" }));
    const both = try testkit.expectOk(&h, &.{ "workspace", "list", "--id-format", "both" });
    try testkit.expectGolden(h.alloc(), "workspace-list-both.txt", both);
    _ = try testkit.expectOk(&h, &.{ "workspace", "list", "--window", "window:2" });
    try h.expectLast("workspace.list", "{\"window_id\":\"window:2\"}");
    _ = try testkit.expectOk(&h, &.{ "--window", "0", "list-workspaces" });
    try h.expectLast("workspace.list", "{\"window_id\":0}");
    const js = try testkit.expectOk(&h, &.{ "workspace", "list", "--json" });
    try testkit.expectGolden(h.alloc(), "workspace-list-json.txt", js);
    h.ok("workspace.list", "{\"workspaces\":[]}");
    try testing.expectEqualStrings("No workspaces\n", try testkit.expectOk(&h, &.{ "workspace", "list" }));
    try testkit.expectUsage(&h, &.{ "workspace", "list", "x" }, "unexpected argument 'x'");
    try testkit.expectUsage(&h, &.{ "list-workspaces", "--window", "pane:1" }, "Invalid window handle: pane:1 (expected UUID, ref like window:1, or index)");
}

test "unit: cli-workspace: legacy verbs print the alias notice unless quiet" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.list", "{\"workspaces\":[]}");
    h.ok("workspace.create", "{\"workspace_ref\":\"workspace:3\"}");
    h.noisy();
    const r = h.run(&.{"list-workspaces"});
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("cmux: 'list-workspaces' is now an alias for 'workspace list'. The legacy form keeps working indefinitely; set CMUX_QUIET=1 to silence this notice.\n", r.err);
    const n = h.run(&.{"new-workspace"});
    try testing.expectEqualStrings("cmux: 'new-workspace' is now an alias for 'workspace create'. The legacy form keeps working indefinitely; set CMUX_QUIET=1 to silence this notice.\n", n.err);
    try testing.expectEqualStrings("OK workspace:3\n", n.out);
    const ns = h.run(&.{ "workspace", "list" });
    try testing.expectEqualStrings("", ns.err);
    h.setEnv("CMUX_QUIET", "1");
    try testing.expectEqualStrings("", h.run(&.{"list-workspaces"}).err);
}

test "unit: cli-workspace: current-workspace prints the selected handle" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.current", "{\"workspace_id\":\"9B690000-0000-4000-8000-000000000002\",\"workspace_ref\":\"workspace:2\",\"window_ref\":\"window:1\"}");
    const out = try testkit.expectOk(&h, &.{"current-workspace"});
    try testkit.expectGolden(h.alloc(), "current-workspace.txt", out);
    try h.expectLast("workspace.current", "{}");
    try testing.expectEqualStrings("9B690000-0000-4000-8000-000000000002\n", try testkit.expectOk(&h, &.{ "current-workspace", "--id-format", "uuids", "--window", "window:1" }));
    try h.expectLast("workspace.current", "{\"window_id\":\"window:1\"}");
    h.ok("workspace.current", "{\"workspace_id\":null}");
    const r = h.run(&.{"current-workspace"});
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings("cmux: No workspace selected\n", r.err);
}

test "unit: cli-workspace: new-workspace maps every flag onto workspace.create" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.create", "{\"workspace_id\":\"9B690000-0000-4000-8000-000000000007\",\"workspace_ref\":\"workspace:7\",\"window_ref\":\"window:1\"}");
    const out = try testkit.expectOk(&h, &.{ "new-workspace", "--name", "Build", "--cwd", "/tmp", "--command", "echo \"a b\" && ls $HOME | wc -l" });
    try testkit.expectGolden(h.alloc(), "new-workspace.txt", out);
    try h.expectLast("workspace.create", "{\"title\":\"Build\",\"cwd\":\"/tmp\",\"initial_input\":\"echo \\\"a b\\\" && ls $HOME | wc -l\\r\",\"focus\":false}");
    _ = try testkit.expectOk(&h, &.{ "workspace", "create", "--description", "line1\nline2", "--window", "window:2", "--focus", "true", "--group", "workspace_group:3", "--group-placement", "afterCurrent", "--group-reference", "workspace:1" });
    try h.expectLast("workspace.create", "{\"description\":\"line1\\nline2\",\"window_id\":\"window:2\",\"focus\":true,\"group_id\":\"workspace_group:3\",\"group_placement\":\"afterCurrent\",\"group_reference_workspace_id\":\"workspace:1\"}");
    // Defaults: background creation, nothing else.
    _ = try testkit.expectOk(&h, &.{"new-workspace"});
    try h.expectLast("workspace.create", "{\"focus\":false}");
    // Focus spellings; the last one wins.
    _ = try testkit.expectOk(&h, &.{ "new-workspace", "--focus=true", "--no-focus" });
    try h.expectLast("workspace.create", "{\"focus\":false}");
    _ = try testkit.expectOk(&h, &.{ "new-workspace", "--no-focus", "--focus", "1" });
    try h.expectLast("workspace.create", "{\"focus\":true}");
    // A bare --focus (the `+workspace new --focus` spelling) means true.
    _ = try testkit.expectOk(&h, &.{ "new-workspace", "--focus" });
    try h.expectLast("workspace.create", "{\"focus\":true}");
    _ = try testkit.expectOk(&h, &.{ "new-workspace", "--name", "N", "--focus", "--json" });
    try h.expectLast("workspace.create", "{\"title\":\"N\",\"focus\":true}");
    _ = try testkit.expectOk(&h, &.{ "+workspace", "new", "--focus", "--name", "N" });
    try h.expectLast("workspace.create", "{\"title\":\"N\",\"focus\":true}");
    // Blank commands are dropped; --command=<text> works.
    _ = try testkit.expectOk(&h, &.{ "new-workspace", "--command", "   " });
    try h.expectLast("workspace.create", "{\"focus\":false}");
    _ = try testkit.expectOk(&h, &.{ "new-workspace", "--command=--version" });
    try h.expectLast("workspace.create", "{\"initial_input\":\"--version\\r\",\"focus\":false}");
    // --layout wins over --command; JSON layouts go through as objects.
    _ = try testkit.expectOk(&h, &.{ "new-workspace", "--command", "ls", "--layout", "{\"split\":\"right\",\"children\":[{},{}]}" });
    try h.expectLast("workspace.create", "{\"layout\":{\"split\":\"right\",\"children\":[{},{}]},\"focus\":false}");
    _ = try testkit.expectOk(&h, &.{ "new-workspace", "--layout", "dev" });
    try h.expectLast("workspace.create", "{\"layout\":\"dev\",\"focus\":false}");
    // The global --window routes the creation too.
    _ = try testkit.expectOk(&h, &.{ "--window", "window:4", "new-workspace", "--name", "\u{65e5}\u{672c}" });
    try h.expectLast("workspace.create", "{\"title\":\"\u{65e5}\u{672c}\",\"window_id\":\"window:4\",\"focus\":false}");
    const js = try testkit.expectOk(&h, &.{ "workspace", "create", "--json" });
    try testing.expectEqualStrings("{\n  \"workspace_ref\": \"workspace:7\",\n  \"window_ref\": \"window:1\"\n}\n", js);
}

test "unit: cli-workspace: new-workspace usage errors" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    try testkit.expectUsage(&h, &.{ "new-workspace", "--command" }, "--command requires a value");
    try testkit.expectUsage(&h, &.{ "new-workspace", "--name", "" }, "--name requires a non-empty value");
    try testkit.expectUsage(&h, &.{ "new-workspace", "--cwd=" }, "--cwd requires a non-empty value");
    try testkit.expectUsage(&h, &.{ "new-workspace", "--focus", "maybe" }, "--focus must be true or false");
    try testkit.expectUsage(&h, &.{ "new-workspace", "--focus=" }, "--focus must be true or false");
    try testkit.expectUsage(&h, &.{ "new-workspace", "--layout", "{bad" }, "--layout is not valid JSON");
    try testkit.expectUsage(&h, &.{ "new-workspace", "--layout", " " }, "--layout requires a non-empty value");
    try testkit.expectUsage(&h, &.{ "new-workspace", "--group-placement", "top" }, "--group-placement requires --group");
    try testkit.expectUsage(&h, &.{ "new-workspace", "--group-reference", "workspace:1" }, "--group-reference requires --group");
    try testkit.expectUsage(&h, &.{ "new-workspace", "--group", "workspace_group:1", "--group-placement", "middle" }, "--group-placement must be one of: afterCurrent, top, end");
    try testkit.expectUsage(&h, &.{ "new-workspace", "--group", "workspace:1" }, "Invalid workspace group handle: workspace:1 (expected UUID, ref like workspace_group:1, or index)");
    try testkit.expectUsage(&h, &.{ "new-workspace", "--env", "NOEQUALS" }, "--env expects KEY=VALUE");
    try testkit.expectUsage(&h, &.{ "new-workspace", "--env", "=secret" }, "--env expects KEY=VALUE");
    try testkit.expectUsage(&h, &.{ "new-workspace", "extra" }, "unexpected argument 'extra'");
    try testkit.expectUsage(&h, &.{ "workspace", "create", "--bogus" }, "unknown option '--bogus'");
}

test "unit: cli-workspace: --worktree and --repo kept from +workspace new" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.create", "{\"workspace_ref\":\"workspace:2\"}");
    // Without a working directory there is no repository to default to.
    const no_cwd = h.run(&.{ "new-workspace", "--worktree", "feat/x" });
    try testing.expectEqual(@as(u8, 1), no_cwd.code);
    try testing.expectEqualStrings("cmux: cannot determine the current directory for --worktree; pass --repo <path>\n", no_cwd.err);
    try testing.expectEqual(@as(usize, 0), h.requestCount());
    // The repository defaults to the CLI's directory, never the app's.
    h.fp.cwd_path = "C:\\src\\repo";
    _ = try testkit.expectOk(&h, &.{ "new-workspace", "--worktree", "feat/x" });
    try h.expectLast("workspace.create", "{\"worktree\":\"feat/x\",\"repo\":\"C:\\\\src\\\\repo\",\"focus\":false}");
    _ = try testkit.expectOk(&h, &.{ "workspace", "create", "--name", "Fix", "--worktree=fix-\u{65e5}", "--repo", "D:\\app" });
    try h.expectLast("workspace.create", "{\"title\":\"Fix\",\"worktree\":\"fix-\u{65e5}\",\"repo\":\"D:\\\\app\",\"focus\":false}");
    _ = try testkit.expectOk(&h, &.{ "new-workspace", "--worktree", "b", "--repo", "." });
    try h.expectLast("workspace.create", "{\"worktree\":\"b\",\"repo\":\"C:\\\\src\\\\repo\",\"focus\":false}");
    // The legacy form reaches new-workspace with its flags intact.
    _ = try testkit.expectOk(&h, &.{ "+workspace", "new", "--worktree", "b", "--repo", "D:\\app" });
    try h.expectLast("workspace.create", "{\"worktree\":\"b\",\"repo\":\"D:\\\\app\",\"focus\":false}");
    try testkit.expectUsage(&h, &.{ "new-workspace", "--repo", "D:\\app" }, "--repo requires --worktree");
    try testkit.expectUsage(&h, &.{ "new-workspace", "--worktree", " " }, "--worktree requires a non-empty branch");
    try testkit.expectUsage(&h, &.{ "new-workspace", "--worktree" }, "--worktree requires a value");
    try testkit.expectUsage(&h, &.{ "new-workspace", "--worktree", "b", "--repo=" }, "--repo requires a non-empty value");
}

test "unit: cli-workspace: relative --cwd resolves against the CLI's directory" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.create", "{\"workspace_ref\":\"workspace:2\"}");
    h.fp.cwd_path = "C:\\work";
    _ = try testkit.expectOk(&h, &.{ "new-workspace", "--cwd", "D:\\abs" });
    try h.expectLast("workspace.create", "{\"cwd\":\"D:\\\\abs\",\"focus\":false}");
    _ = try testkit.expectOk(&h, &.{ "new-workspace", "--cwd", "." });
    try h.expectLast("workspace.create", "{\"cwd\":\"C:\\\\work\",\"focus\":false}");
    _ = try testkit.expectOk(&h, &.{ "new-workspace", "--cwd", "sub" });
    const want = try proto.paths.join(h.alloc(), proto.paths.Style.native, &.{ "C:\\work", "sub" });
    try testing.expectEqualStrings(want, h.requests()[h.requestCount() - 1].params.object.get("cwd").?.string);
    try testing.expect(create.isAbsolute("\\\\server\\share"));
    try testing.expect(create.isAbsolute("c:/x"));
    try testing.expect(!create.isAbsolute("c:x"));
    try testing.expect(!create.isAbsolute(""));
}

test "unit: cli-workspace: --env and --env-file build workspace_env" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.create", "{\"workspace_ref\":\"workspace:2\"}");
    try h.fp.addFile("/env/a.env", "# shared\nexport AWS_PROFILE=dev\nFOO=from-file\nQUOTED=\"x y\"\n");
    try h.fp.addFile("/env/b.env", "AWS_PROFILE=prod\n");
    _ = try testkit.expectOk(&h, &.{ "new-workspace", "--env", "FOO=1", "--env-file", "/env/a.env", "--env-file=/env/b.env", "--env", "EMPTY=" });
    try h.expectLast("workspace.create", "{\"workspace_env\":{\"AWS_PROFILE\":\"prod\",\"FOO\":\"1\",\"QUOTED\":\"x y\",\"EMPTY\":\"\"},\"focus\":false}");
    const missing = h.run(&.{ "new-workspace", "--env-file", "/env/none.env" });
    try testing.expectEqual(@as(u8, 1), missing.code);
    try testing.expectEqualStrings("cmux: cannot read --env-file '/env/none.env'\n", missing.err);
    try h.fp.addFile("/env/bad.env", "OK=1\nnot an assignment\n");
    const bad = h.run(&.{ "new-workspace", "--env-file", "/env/bad.env" });
    try testing.expectEqual(@as(u8, 1), bad.code);
    try testing.expectEqualStrings("cmux: invalid line 2 in --env-file '/env/bad.env': expected KEY=VALUE\n", bad.err);
    try testkit.expectUsage(&h, &.{ "new-workspace", "--env-file=" }, "--env-file requires a non-empty value");
}

test "unit: cli-workspace: workspace env lists, masks and targets" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.env", "{\"workspace_id\":\"W\",\"workspace_ref\":\"workspace:2\",\"env\":{\"AWS_PROFILE\":\"prod\",\"TOKEN\":\"s3cr\u{e9}t\",\"EMPTY\":\"\"}}");
    const out = try testkit.expectOk(&h, &.{ "workspace", "env" });
    try testkit.expectGolden(h.alloc(), "workspace-env.txt", out);
    try h.expectLast("workspace.env", "{}");
    const masked = try testkit.expectOk(&h, &.{ "workspace", "env", "--mask" });
    try testkit.expectGolden(h.alloc(), "workspace-env-mask.txt", masked);
    const mj = try testkit.expectOk(&h, &.{ "workspace", "env", "--mask", "--json" });
    try testing.expect(std.mem.indexOf(u8, mj, "s3cr") == null);
    try testing.expect(std.mem.indexOf(u8, mj, "\"TOKEN\": \"***\"") != null);
    _ = try testkit.expectOk(&h, &.{ "workspace", "env", "workspace:3" });
    try h.expectLast("workspace.env", "{\"workspace_id\":\"workspace:3\"}");
    _ = try testkit.expectOk(&h, &.{ "workspace", "env", "--workspace", "2" });
    try h.expectLast("workspace.env", "{\"workspace_id\":2}");
    h.setEnv("CMUX_WORKSPACE_ID", "CALLER-UUID");
    _ = try testkit.expectOk(&h, &.{ "workspace", "env" });
    try h.expectLast("workspace.env", "{\"workspace_id\":\"CALLER-UUID\"}");
    _ = try testkit.expectOk(&h, &.{ "workspace", "env", "--window", "window:1" });
    try h.expectLast("workspace.env", "{\"window_id\":\"window:1\"}");
    h.ok("workspace.env", "{\"env\":{}}");
    try testing.expectEqualStrings("No environment variables set.\n", try testkit.expectOk(&h, &.{ "workspace", "env" }));
    try testkit.expectUsage(&h, &.{ "workspace", "env", "a", "b" }, "unexpected argument 'b'");
    try testkit.expectUsage(&h, &.{ "workspace", "env", "workspace:1", "--workspace", "workspace:2" }, "give the workspace as an argument or --workspace, not both");
    try testkit.expectUsage(&h, &.{ "workspace", "env", "surface:1" }, "Invalid workspace handle: surface:1 (expected UUID, ref like workspace:1, or index)");
}

test "unit: cli-workspace: select, close and rename in legacy and namespace forms" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    for ([_][]const u8{ "workspace.select", "workspace.close", "workspace.rename" }) |m| h.ok(m, "{\"workspace_ref\":\"workspace:3\"}");
    try testing.expectEqualStrings("OK\n", try testkit.expectOk(&h, &.{ "select-workspace", "--workspace", "workspace:3" }));
    try h.expectLast("workspace.select", "{\"workspace_id\":\"workspace:3\"}");
    _ = try testkit.expectOk(&h, &.{ "workspace", "select", "2", "--window", "window:1" });
    try h.expectLast("workspace.select", "{\"workspace_id\":2,\"window_id\":\"window:1\"}");
    try testkit.expectUsage(&h, &.{"select-workspace"}, "select-workspace requires a workspace (<id|ref|index> or --workspace)");
    try testkit.expectUsage(&h, &.{ "workspace", "select" }, "workspace select requires a workspace (<id|ref|index> or --workspace)");
    try testkit.expectUsage(&h, &.{ "workspace", "select", "workspace:0" }, "Invalid workspace handle: workspace:0 (expected UUID, ref like workspace:1, or index)");

    _ = try testkit.expectOk(&h, &.{ "close-workspace", "--workspace", "workspace:3", "--force" });
    try h.expectLast("workspace.close", "{\"workspace_id\":\"workspace:3\",\"force\":true}");
    _ = try testkit.expectOk(&h, &.{ "workspace", "close", "9b690000-0000-4000-8000-000000000003" });
    try h.expectLast("workspace.close", "{\"workspace_id\":\"9b690000-0000-4000-8000-000000000003\"}");
    try testkit.expectUsage(&h, &.{"close-workspace"}, "close-workspace requires a workspace (<id|ref|index> or --workspace)");
    try testkit.expectUsage(&h, &.{ "workspace", "close", "a", "b" }, "unexpected argument 'b'");

    try testkit.expectUsage(&h, &.{"rename-workspace"}, "rename-workspace requires a title");
    try testkit.expectUsage(&h, &.{ "workspace", "rename", "workspace:1" }, "workspace rename requires --title <title>");
    _ = try testkit.expectOk(&h, &.{ "workspace", "rename", "workspace:1", "--title", "API \u{1F680}" });
    try h.expectLast("workspace.rename", "{\"workspace_id\":\"workspace:1\",\"title\":\"API \u{1F680}\"}");

    // Inside a terminal the caller's workspace is the default target.
    h.setEnv("CMUX_WORKSPACE_ID", "CALLER-UUID");
    _ = try testkit.expectOk(&h, &.{"close-workspace"});
    try h.expectLast("workspace.close", "{\"workspace_id\":\"CALLER-UUID\"}");
    _ = try testkit.expectOk(&h, &.{ "rename-window", "agent", "run" });
    try h.expectLast("workspace.rename", "{\"workspace_id\":\"CALLER-UUID\",\"title\":\"agent run\"}");
    _ = try testkit.expectOk(&h, &.{ "rename-workspace", "--workspace", "workspace:2", "--", "--odd title" });
    try h.expectLast("workspace.rename", "{\"workspace_id\":\"workspace:2\",\"title\":\"--odd title\"}");
    _ = try testkit.expectOk(&h, &.{ "workspace", "rename", "--title", "x" });
    try h.expectLast("workspace.rename", "{\"workspace_id\":\"CALLER-UUID\",\"title\":\"x\"}");
    // Naming a window drops the caller default; the server picks the
    // window's selected workspace.
    _ = try testkit.expectOk(&h, &.{ "rename-workspace", "--window", "window:2", "new" });
    try h.expectLast("workspace.rename", "{\"window_id\":\"window:2\",\"title\":\"new\"}");
    try testkit.expectUsage(&h, &.{ "close-workspace", "--window", "window:2" }, "close-workspace requires a workspace (<id|ref|index> or --workspace)");
}

test "unit: cli-workspace: a blank workspace handle means the caller's workspace or fails closed" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    for ([_][]const u8{ "workspace.close", "workspace.select", "workspace.rename", "workspace.move_to_window" }) |m| h.ok(m, "{}");
    const msg = "No workspace selected: --workspace was blank and CMUX_WORKSPACE_ID is unset";
    // Without a caller workspace a blank handle never reaches the server
    // (cmux: `--workspace "${CMUX_WORKSPACE_ID:-}"` outside a terminal).
    try testkit.expectUsage(&h, &.{ "close-workspace", "--workspace", "" }, msg);
    try testkit.expectUsage(&h, &.{ "select-workspace", "--workspace", " " }, msg);
    try testkit.expectUsage(&h, &.{ "workspace", "close", "" }, msg);
    try testkit.expectUsage(&h, &.{ "workspace", "env", "--workspace=" }, msg);
    try testkit.expectUsage(&h, &.{ "workspace", "status", "--workspace", "" }, msg);
    try testkit.expectUsage(&h, &.{ "workspace", "reconnect", "" }, msg);
    try testkit.expectUsage(&h, &.{ "workspace-action", "pin", "--workspace", "" }, msg);
    try testkit.expectUsage(&h, &.{ "reorder-workspace", "--workspace", "", "--index", "0" }, msg);
    try testkit.expectUsage(&h, &.{ "move-workspace-to-window", "--workspace", "", "--window", "1" }, msg);
    // Inside a terminal it is the caller's workspace...
    h.setEnv("CMUX_WORKSPACE_ID", "CALLER-UUID");
    _ = try testkit.expectOk(&h, &.{ "close-workspace", "--workspace", "" });
    try h.expectLast("workspace.close", "{\"workspace_id\":\"CALLER-UUID\"}");
    _ = try testkit.expectOk(&h, &.{ "workspace", "select", "\t" });
    try h.expectLast("workspace.select", "{\"workspace_id\":\"CALLER-UUID\"}");
    _ = try testkit.expectOk(&h, &.{ "rename-workspace", "--workspace=", "T" });
    try h.expectLast("workspace.rename", "{\"workspace_id\":\"CALLER-UUID\",\"title\":\"T\"}");
    // (move-workspace-to-window's --window is the destination, not a scope.)
    _ = try testkit.expectOk(&h, &.{ "move-workspace-to-window", "--workspace", "", "--window", "1" });
    try h.expectLast("workspace.move_to_window", "{\"workspace_id\":\"CALLER-UUID\",\"window_id\":1}");
    // ...unless a window was named: CMUX_WORKSPACE_ID applies only without one.
    try testkit.expectUsage(&h, &.{ "close-workspace", "--workspace", "", "--window", "window:1" }, msg);
    try testkit.expectUsage(&h, &.{ "--window", "window:1", "select-workspace", "--workspace", "" }, msg);
    try testkit.expectUsage(&h, &.{ "--window", "window:1", "workspace", "env", "" }, msg);
    // Other blank handles keep cmux's per-kind message.
    try testkit.expectUsage(&h, &.{ "close-workspace", "--workspace", "workspace:1", "--window", "" }, "Window handle is blank");
    try testkit.expectUsage(&h, &.{ "reorder-workspace", "--before", " " }, "Workspace handle is blank");
}

fn expectNoLeak(out: []const u8, secrets: []const []const u8) !void {
    for (secrets) |secret| {
        if (std.mem.indexOf(u8, out, secret) != null) {
            std.debug.print("\nleaked {s} in:\n{s}\n", .{ secret, out });
            return error.TestUnexpectedResult;
        }
    }
}

test "unit: cli-workspace: workspace env --mask hides values whatever the result shape" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.env", "{\"workspace_ref\":\"workspace:2\",\"env\":[{\"name\":\"TOKEN\",\"value\":\"s3cret\"},\"RAW=x9\"],\"workspace_env\":{\"K\":\"v1\",\"N\":7,\"Z\":null}}");
    const js = try testkit.expectOk(&h, &.{ "workspace", "env", "--mask", "--json" });
    try expectNoLeak(js, &.{ "s3cret", "TOKEN", "x9", "v1", "7" });
    try testing.expect(std.mem.indexOf(u8, js, "\"K\": \"***\"") != null);
    try testing.expect(std.mem.indexOf(u8, js, "\"Z\": null") != null);
    try testing.expect(std.mem.indexOf(u8, js, "\"workspace_ref\": \"workspace:2\"") != null);
    // Without --mask nothing is rewritten.
    const plain = try testkit.expectOk(&h, &.{ "workspace", "env", "--json" });
    try testing.expect(std.mem.indexOf(u8, plain, "s3cret") != null);

    // A set under any other key is masked as well; only the target handles
    // keep their values.
    h.ok("workspace.env", "{\"workspace_id\":\"W-UUID\",\"workspace_ref\":\"workspace:2\",\"window_ref\":\"window:1\",\"variables\":{\"API_KEY\":\"k3y\"},\"count\":1}");
    const other = try testkit.expectOk(&h, &.{ "workspace", "env", "--mask", "--json", "--id-format", "both" });
    try expectNoLeak(other, &.{"k3y"});
    try testing.expect(std.mem.indexOf(u8, other, "\"API_KEY\": \"***\"") != null);
    try testing.expect(std.mem.indexOf(u8, other, "\"count\": \"***\"") != null);
    try testing.expect(std.mem.indexOf(u8, other, "\"workspace_id\": \"W-UUID\"") != null);
    try testing.expect(std.mem.indexOf(u8, other, "\"workspace_ref\": \"workspace:2\"") != null);
    try testing.expect(std.mem.indexOf(u8, other, "\"window_ref\": \"window:1\"") != null);
    // So is a result that is not an object, in JSON and in text.
    h.ok("workspace.env", "[\"TOKEN=s3cret\",{\"name\":\"PW\",\"value\":\"hunter2\"}]");
    try expectNoLeak(try testkit.expectOk(&h, &.{ "workspace", "env", "--mask", "--json" }), &.{ "s3cret", "hunter2" });
    try testing.expectEqualStrings("No environment variables set.\n", try testkit.expectOk(&h, &.{ "workspace", "env", "--mask" }));
    h.ok("workspace.env", "\"TOKEN=s3cret\"");
    try testing.expectEqualStrings("\"***\"\n", try testkit.expectOk(&h, &.{ "workspace", "env", "--mask", "--json" }));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"A\":\"1\",\"B\":{\"c\":[true,2.5,\"d\"]},\"E\":null}", .{});
    const masked = try std.json.Stringify.valueAlloc(a, try create.maskValues(a, v), .{});
    try testing.expectEqualStrings("{\"A\":\"***\",\"B\":{\"c\":[\"***\",\"***\",\"***\"]},\"E\":null}", masked);
    try testing.expectEqualStrings("\"***\"", try std.json.Stringify.valueAlloc(a, try create.maskValues(a, .{ .string = "" }), .{}));
    const r = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"workspace_id\":\"W\",\"window_id\":null,\"env\":{\"A\":\"1\"},\"workspace\":\"x\"}", .{});
    try testing.expectEqualStrings("{\"workspace_id\":\"W\",\"window_id\":null,\"env\":{\"A\":\"***\"},\"workspace\":\"***\"}", try std.json.Stringify.valueAlloc(a, try create.maskEnvResult(a, r), .{}));
    try testing.expectEqualStrings("\"***\"", try std.json.Stringify.valueAlloc(a, try create.maskEnvResult(a, .{ .integer = 42 }), .{}));
    try testing.expectEqualStrings("{}", try std.json.Stringify.valueAlloc(a, try create.maskEnvResult(a, .{ .object = std.json.ObjectMap.init(a) }), .{}));
}

test "unit: cli-workspace: next, previous and last window" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    const cases = [_][2][]const u8{ .{ "next-window", "workspace.next" }, .{ "previous-window", "workspace.previous" }, .{ "last-window", "workspace.last" } };
    for (cases) |c| {
        h.ok(c[1], "{\"workspace_ref\":\"workspace:2\"}");
        try testing.expectEqualStrings("OK\n", try testkit.expectOk(&h, &.{c[0]}));
        try h.expectLast(c[1], "{}");
        _ = try testkit.expectOk(&h, &.{ c[0], "--window", "window:2" });
        try h.expectLast(c[1], "{\"window_id\":\"window:2\"}");
        try testkit.expectUsage(&h, &.{ c[0], "x" }, "unexpected argument 'x'");
    }
    const j = try testkit.expectOk(&h, &.{ "last-window", "--json" });
    try testing.expectEqualStrings("{\n  \"workspace_ref\": \"workspace:2\"\n}\n", j);
}

test "unit: cli-workspace: reorder-workspace targets, dry run and validation" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.reorder", "{\"workspace_ref\":\"workspace:3\",\"index\":0}");
    const dry = try testkit.expectOk(&h, &.{ "reorder-workspace", "workspace:3", "--index", "0", "--dry-run" });
    try testkit.expectGolden(h.alloc(), "reorder-workspace-dry-run.txt", dry);
    try h.expectLast("workspace.reorder", "{\"workspace_id\":\"workspace:3\",\"index\":0,\"dry_run\":true}");
    try testing.expectEqualStrings("OK\n", try testkit.expectOk(&h, &.{ "reorder-workspace", "--workspace", "workspace:3", "--index", "0" }));
    try h.expectLast("workspace.reorder", "{\"workspace_id\":\"workspace:3\",\"index\":0}");
    _ = try testkit.expectOk(&h, &.{ "reorder-workspace", "workspace:3", "--before-workspace", "workspace:1", "--window", "window:1" });
    try h.expectLast("workspace.reorder", "{\"workspace_id\":\"workspace:3\",\"before_workspace_id\":\"workspace:1\",\"window_id\":\"window:1\"}");
    _ = try testkit.expectOk(&h, &.{ "reorder-workspace", "workspace:3", "--after", "1" });
    try h.expectLast("workspace.reorder", "{\"workspace_id\":\"workspace:3\",\"after_workspace_id\":1}");
    h.setEnv("CMUX_WORKSPACE_ID", "CALLER-UUID");
    _ = try testkit.expectOk(&h, &.{ "reorder-workspace", "--index", "4294967295" });
    try h.expectLast("workspace.reorder", "{\"workspace_id\":\"CALLER-UUID\",\"index\":4294967295}");
    try testkit.expectUsage(&h, &.{ "reorder-workspace", "workspace:3" }, "reorder-workspace requires exactly one of --index, --before or --after");
    try testkit.expectUsage(&h, &.{ "reorder-workspace", "--index", "0", "--after", "workspace:1" }, "reorder-workspace requires exactly one of --index, --before or --after");
    try testkit.expectUsage(&h, &.{ "reorder-workspace", "--index", "-1" }, "--index must be a non-negative integer (got '-1')");
    try testkit.expectUsage(&h, &.{ "reorder-workspace", "--index", "4294967296" }, "--index must be a non-negative integer (got '4294967296')");
    try testkit.expectUsage(&h, &.{ "reorder-workspace", "a", "b", "--index", "1" }, "unexpected argument 'b'");
}

test "unit: cli-workspace: reorder-workspaces order list and dry run" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.reorder_many", "{\"workspaces\":[{\"id\":\"A\",\"ref\":\"workspace:3\"},{\"id\":\"B\",\"ref\":\"workspace:1\"},{\"id\":\"C\",\"ref\":\"workspace:2\"}]}");
    try testing.expectEqualStrings("OK\n", try testkit.expectOk(&h, &.{ "reorder-workspaces", "--order", "workspace:3, workspace:1" }));
    try h.expectLast("workspace.reorder_many", "{\"workspace_ids\":[\"workspace:3\",\"workspace:1\"]}");
    const dry = try testkit.expectOk(&h, &.{ "reorder-workspaces", "--order=workspace:3,0", "--window", "window:1", "--dry-run" });
    try testkit.expectGolden(h.alloc(), "reorder-workspaces-dry-run.txt", dry);
    try h.expectLast("workspace.reorder_many", "{\"workspace_ids\":[\"workspace:3\",0],\"window_id\":\"window:1\",\"dry_run\":true}");
    // cmux's result shape: plan[] and events[] with refs and from/to indexes.
    h.ok("workspace.reorder_many", "{\"dry_run\":true,\"plan\":[{\"workspace_id\":\"A\",\"workspace_ref\":\"workspace:3\",\"from_index\":2,\"to_index\":0},{\"workspace_id\":\"B\",\"workspace_ref\":\"workspace:1\",\"from_index\":0,\"to_index\":1},{\"ref\":\"workspace:9\"}],\"events\":[]}");
    const plan = try testkit.expectOk(&h, &.{ "reorder-workspaces", "--order", "workspace:3,workspace:1", "--dry-run" });
    try testkit.expectGolden(h.alloc(), "reorder-workspaces-dry-run-plan.txt", plan);
    const plan_both = try testkit.expectOk(&h, &.{ "reorder-workspaces", "--order", "workspace:3", "--dry-run", "--id-format", "both" });
    try testing.expect(std.mem.startsWith(u8, plan_both, "workspace:3 (A) from=2 to=0\n"));
    try testing.expectEqualStrings("OK\n", try testkit.expectOk(&h, &.{ "reorder-workspaces", "--order", "workspace:3" }));
    h.ok("workspace.reorder_many", "{\"ok\":true}");
    try testing.expectEqualStrings("OK\n", try testkit.expectOk(&h, &.{ "reorder-workspaces", "--order", "workspace:3", "--dry-run" }));
    try testkit.expectUsage(&h, &.{"reorder-workspaces"}, "reorder-workspaces requires --order");
    try testkit.expectUsage(&h, &.{ "reorder-workspaces", "--order", "workspace:1,,workspace:2" }, "--order has an empty entry");
    try testkit.expectUsage(&h, &.{ "reorder-workspaces", "--order=" }, "--order has an empty entry");
    try testkit.expectUsage(&h, &.{ "reorder-workspaces", "--order", "workspace:1,pane:2" }, "Invalid workspace handle: pane:2 (expected UUID, ref like workspace:1, or index)");
    try testkit.expectUsage(&h, &.{ "reorder-workspaces", "workspace:1" }, "unexpected argument 'workspace:1'");
}

test "unit: cli-workspace: workspace-action actions, flags and errors" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.action", "{\"workspace_ref\":\"workspace:2\"}");
    for (reorder.actions) |a| {
        const argv: []const []const u8 = if (std.mem.eql(u8, a, "rename"))
            &.{ "workspace-action", a, "--title", "T" }
        else if (std.mem.eql(u8, a, "set-description"))
            &.{ "workspace-action", a, "--description", "D" }
        else if (std.mem.eql(u8, a, "set-color"))
            &.{ "workspace-action", a, "--color", "teal" }
        else
            &.{ "workspace-action", "--action", a };
        try testing.expectEqualStrings("OK\n", try testkit.expectOk(&h, argv));
        try testing.expectEqualStrings(a, h.requests()[h.requestCount() - 1].params.object.get("action").?.string);
    }
    try h.expectLast("workspace.action", "{\"action\":\"clear-color\"}");
    _ = try testkit.expectOk(&h, &.{ "workspace-action", "set-color", "--color", "teal" });
    try h.expectLast("workspace.action", "{\"action\":\"set-color\",\"color\":\"Teal\"}");
    _ = try testkit.expectOk(&h, &.{ "workspace-action", "set-color", "--color", "#1a2B3c", "--workspace", "workspace:4" });
    try h.expectLast("workspace.action", "{\"action\":\"set-color\",\"workspace_id\":\"workspace:4\",\"color\":\"#1a2B3c\"}");
    _ = try testkit.expectOk(&h, &.{ "workspace-action", "set-description", "two", "words\nkept" });
    try h.expectLast("workspace.action", "{\"action\":\"set-description\",\"description\":\"two words\\nkept\"}");
    _ = try testkit.expectOk(&h, &.{ "workspace-action", "close-others", "--force", "--window", "window:1" });
    try h.expectLast("workspace.action", "{\"action\":\"close-others\",\"window_id\":\"window:1\",\"force\":true}");
    h.setEnv("CMUX_WORKSPACE_ID", "CALLER-UUID");
    _ = try testkit.expectOk(&h, &.{ "workspace-action", "rename", "--title", "Agent \u{1F916}" });
    try h.expectLast("workspace.action", "{\"action\":\"rename\",\"workspace_id\":\"CALLER-UUID\",\"title\":\"Agent \u{1F916}\"}");

    try testkit.expectUsage(&h, &.{"workspace-action"}, "workspace-action requires --action <name>");
    try testkit.expectUsage(&h, &.{ "workspace-action", "explode" }, "Unknown workspace action: explode. Valid actions: pin, unpin, rename, clear-name, set-description, clear-description, move-up, move-down, move-top, close-others, close-above, close-below, mark-read, mark-unread, set-color, clear-color");
    try testkit.expectUsage(&h, &.{ "workspace-action", "rename" }, "workspace-action rename requires --title <text>");
    try testkit.expectUsage(&h, &.{ "workspace-action", "set-description" }, "workspace-action set-description requires --description <text> or trailing text");
    try testkit.expectUsage(&h, &.{ "workspace-action", "set-description", "--description", "a", "b" }, "unexpected argument 'b'");
    try testkit.expectUsage(&h, &.{ "workspace-action", "set-color" }, "workspace-action set-color requires --color <name|#RRGGBB>");
    try testkit.expectUsage(&h, &.{ "workspace-action", "set-color", "--color", "#12345" }, "invalid color '#12345': use #RRGGBB or one of Red, Crimson, Orange, Amber, Olive, Green, Teal, Aqua, Blue, Navy, Indigo, Purple, Magenta, Rose, Brown, Charcoal");
    try testkit.expectUsage(&h, &.{ "workspace-action", "pin", "extra" }, "unexpected argument 'extra'");
    try testing.expectEqualStrings("Charcoal", reorder.normalizeColor(" CHARCOAL ").?);
    try testing.expect(reorder.normalizeColor("#GG0000") == null);
}

test "unit: cli-workspace: workspace status get, set, cycle and errors" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    const pinned = "{\"effective\":\"done\",\"inferred\":\"working\",\"override\":{\"status\":\"done\",\"inferred_at_override\":\"working\"}}";
    h.ok("workspace.status.get", pinned);
    h.ok("workspace.status.set", pinned);
    h.ok("workspace.status.cycle", "{\"effective\":\"todo\",\"inferred\":\"working\",\"override\":null}");
    const out = try testkit.expectOk(&h, &.{ "workspace", "status" });
    try testkit.expectGolden(h.alloc(), "workspace-status.txt", out);
    try h.expectLast("workspace.status.get", "{}");
    try testing.expectEqualStrings(out, try testkit.expectOk(&h, &.{ "workspace", "status", "set", "done" }));
    try h.expectLast("workspace.status.set", "{\"status\":\"done\"}");
    const cyc = try testkit.expectOk(&h, &.{ "workspace", "status", "cycle", "--workspace", "workspace:3" });
    try testkit.expectGolden(h.alloc(), "workspace-status-auto.txt", cyc);
    try h.expectLast("workspace.status.cycle", "{\"workspace_id\":\"workspace:3\"}");
    for (status.lanes) |l| {
        _ = try testkit.expectOk(&h, &.{ "workspace", "status", "set", l });
        try testing.expectEqualStrings(l, h.requests()[h.requestCount() - 1].params.object.get("status").?.string);
    }
    h.setEnv("CMUX_WORKSPACE_ID", "CALLER-UUID");
    _ = try testkit.expectOk(&h, &.{ "workspace", "status", "--window", "window:2" });
    try h.expectLast("workspace.status.get", "{\"window_id\":\"window:2\"}");
    _ = try testkit.expectOk(&h, &.{ "workspace", "status" });
    try h.expectLast("workspace.status.get", "{\"workspace_id\":\"CALLER-UUID\"}");
    const js = try testkit.expectOk(&h, &.{ "workspace", "status", "--json" });
    try testing.expect(std.mem.indexOf(u8, js, "\"inferred_at_override\": \"working\"") != null);
    try testkit.expectUsage(&h, &.{ "workspace", "status", "bogus" }, "Unknown workspace status subcommand: bogus. Try: cmux workspace status [set <lane|auto> | cycle]");
    try testkit.expectUsage(&h, &.{ "workspace", "status", "set" }, "workspace status set requires a lane: todo, working, needs-attention, review, done, auto, none");
    try testkit.expectUsage(&h, &.{ "workspace", "status", "set", "Done" }, "Invalid workspace status 'Done'. Expected one of: todo, working, needs-attention, review, done, auto, none");
    try testkit.expectUsage(&h, &.{ "workspace", "status", "set", "done", "x" }, "unexpected argument 'x'");
    try testkit.expectUsage(&h, &.{ "workspace", "status", "cycle", "x" }, "unexpected argument 'x'");
}

test "unit: cli-workspace: workspace reconnect and disconnect" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.remote.reconnect", "{\"workspace_ref\":\"workspace:3\",\"remote\":{\"state\":\"connecting\"}}");
    h.ok("workspace.remote.disconnect", "{\"workspace_ref\":\"workspace:3\",\"remote\":{\"state\":\"disconnected\"}}");
    try testing.expectEqualStrings("OK\n", try testkit.expectOk(&h, &.{ "workspace", "reconnect", "workspace:3" }));
    try h.expectLast("workspace.remote.reconnect", "{\"workspace_id\":\"workspace:3\"}");
    _ = try testkit.expectOk(&h, &.{ "workspace", "disconnect", "--workspace", "workspace:3" });
    try h.expectLast("workspace.remote.disconnect", "{\"workspace_id\":\"workspace:3\"}");
    const js = try testkit.expectOk(&h, &.{ "workspace", "disconnect", "--json" });
    try testing.expect(std.mem.indexOf(u8, js, "\"state\": \"disconnected\"") != null);
    try h.expectLast("workspace.remote.disconnect", "{}");
    h.setEnv("WMUX_WORKSPACE_ID", "CALLER-UUID");
    _ = try testkit.expectOk(&h, &.{ "workspace", "reconnect" });
    try h.expectLast("workspace.remote.reconnect", "{\"workspace_id\":\"CALLER-UUID\"}");
    try testkit.expectUsage(&h, &.{ "workspace", "reconnect", "a", "b" }, "unexpected argument 'b'");
    h.fail("workspace.remote.reconnect", "{\"code\":\"invalid_state\",\"message\":\"Workspace is not remote\"}");
    const r = h.run(&.{ "workspace", "reconnect", "workspace:1" });
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings("invalid_state: Workspace is not remote\n", r.err);
}

test "unit: cli-workspace: namespace usage errors" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    try testkit.expectUsage(&h, &.{"workspace"}, "workspace requires a subcommand: list, create, env, close, rename, select, status, reconnect, disconnect, group");
    try testkit.expectUsage(&h, &.{ "workspace", "bogus" }, "unknown workspace subcommand 'bogus'; expected one of: list, create, env, close, rename, select, status, reconnect, disconnect, group");
    const r = h.run(&.{ "workspace", "bogus" });
    try testing.expect(std.mem.endsWith(u8, r.err, "\nUsage: cmux workspace <list|create|env|close|rename|select|status|reconnect|disconnect|group> [args]\n"));
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
}
