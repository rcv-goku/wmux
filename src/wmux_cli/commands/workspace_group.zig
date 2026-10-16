//! CLI command family `workspace_group` (Appendix C).
//! workspace-group <sub>, workspace group <sub>. Owner: W4-5.
//!
//! Every verb maps to `workspace.group.<verb>` (`set-anchor` →
//! `set_anchor`, `new-workspace` → `new_workspace`) with the group in
//! `group_id` (UUID, `workspace_group:N` or index), workspaces in
//! `workspace_id`, and flags as snake_case params (`--idempotency-key` →
//! `idempotency_key`, `--close-workspaces` → `close_workspaces`, …).
//! Mutations print `OK` (creations `OK <handle>`); `--json` prints the
//! result.

const std = @import("std");
const command = @import("../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../output.zig");
const common = @import("ws/common.zig");
const create = @import("ws/create.zig");
const Def = common.opts.Def;
const Params = common.Params;

const u_ns = "Usage: cmux workspace-group <list|create|rename|ungroup|delete|collapse|expand|pin|unpin|add|remove|set-anchor|set-color|set-icon|move|focus|new-workspace> [args]";

/// `CommandSpec` entries (ADR-4.9).
pub const commands = [_]CommandSpec{
    .{ .name = "workspace-group", .group = .navigate, .usage = u_ns, .help = @embedFile("../help/workspace-group.txt"), .run = runNamespace },
};

pub const Verb = struct {
    name: []const u8,
    method: []const u8,
    usage: []const u8,
    run: *const fn (ctx: *Ctx, args: []const []const u8, v: *const Verb, prefix: []const u8) anyerror!u8,
};

pub const verbs = [_]Verb{
    .{ .name = "list", .method = "workspace.group.list", .usage = "Usage: cmux workspace-group list [--window <id|ref|index>]", .run = runList },
    .{ .name = "create", .method = "workspace.group.create", .usage = "Usage: cmux workspace-group create [--name <name>] [--cwd <path>] [--from <id>,<id>...] [--idempotency-key <key> | --external-id <id>]", .run = runCreate },
    .{ .name = "rename", .method = "workspace.group.rename", .usage = "Usage: cmux workspace-group rename <group> --name <new>", .run = runRename },
    .{ .name = "ungroup", .method = "workspace.group.ungroup", .usage = "Usage: cmux workspace-group ungroup <group> [--remove-generated-anchor]", .run = runUngroup },
    .{ .name = "delete", .method = "workspace.group.delete", .usage = "Usage: cmux workspace-group delete <group> [--close-workspaces] [--remove-generated-anchor]", .run = runDelete },
    .{ .name = "collapse", .method = "workspace.group.collapse", .usage = "Usage: cmux workspace-group collapse <group>", .run = runGroupOnly },
    .{ .name = "expand", .method = "workspace.group.expand", .usage = "Usage: cmux workspace-group expand <group>", .run = runGroupOnly },
    .{ .name = "pin", .method = "workspace.group.pin", .usage = "Usage: cmux workspace-group pin <group>", .run = runGroupOnly },
    .{ .name = "unpin", .method = "workspace.group.unpin", .usage = "Usage: cmux workspace-group unpin <group>", .run = runGroupOnly },
    .{ .name = "add", .method = "workspace.group.add", .usage = "Usage: cmux workspace-group add --group <group> --workspace <id|ref|index>", .run = runGroupWorkspace },
    .{ .name = "remove", .method = "workspace.group.remove", .usage = "Usage: cmux workspace-group remove --workspace <id|ref|index>", .run = runRemove },
    .{ .name = "set-anchor", .method = "workspace.group.set_anchor", .usage = "Usage: cmux workspace-group set-anchor --group <group> --workspace <id|ref|index>", .run = runGroupWorkspace },
    .{ .name = "set-color", .method = "workspace.group.set_color", .usage = "Usage: cmux workspace-group set-color <group> [--hex #RRGGBB]", .run = runSetColor },
    .{ .name = "set-icon", .method = "workspace.group.set_icon", .usage = "Usage: cmux workspace-group set-icon <group> [--symbol <name>]", .run = runSetIcon },
    .{ .name = "move", .method = "workspace.group.move", .usage = "Usage: cmux workspace-group move <group> (--to-index <n> | --before <group> | --after <group>)", .run = runMove },
    .{ .name = "focus", .method = "workspace.group.focus", .usage = "Usage: cmux workspace-group focus <group>", .run = runGroupOnly },
    .{ .name = "new-workspace", .method = "workspace.group.new_workspace", .usage = "Usage: cmux workspace-group new-workspace <group> [--placement afterCurrent|top|end]", .run = runNewWorkspace },
};

fn verbList(ctx: *Ctx) ![]const u8 {
    var names: [verbs.len][]const u8 = undefined;
    for (verbs, 0..) |v, i| names[i] = v.name;
    return std.mem.join(ctx.arena, ", ", &names);
}

fn runNamespace(ctx: *Ctx) !u8 {
    return runNamespaceArgs(ctx, ctx.args(), "workspace-group");
}

/// `workspace-group <sub> ...` and `workspace group <sub> ...`; `prefix`
/// names the spelling in messages.
pub fn runNamespaceArgs(ctx: *Ctx, args: []const []const u8, prefix: []const u8) !u8 {
    if (args.len == 0) return common.usage(ctx, u_ns, "{s} requires a subcommand: {s}", .{ prefix, try verbList(ctx) });
    for (&verbs) |*v| {
        if (std.mem.eql(u8, v.name, args[0])) return v.run(ctx, args[1..], v, prefix);
    }
    return common.usage(ctx, u_ns, "unknown {s} subcommand '{s}'; expected one of: {s}", .{ prefix, args[0], try verbList(ctx) });
}

/// The group named by one positional or `--group`; prints the usage error
/// and returns null when it is missing or ambiguous (exit code in `code.*`).
fn groupArg(ctx: *Ctx, o: common.opts.Opts, v: *const Verb, prefix: []const u8, code: *u8) ?[]const u8 {
    if (o.positionals.len > 1) {
        code.* = common.usage(ctx, v.usage, "unexpected argument '{s}'", .{o.positionals[1]});
        return null;
    }
    if (o.positionals.len == 1 and o.get("--group") != null) {
        code.* = common.usage(ctx, v.usage, "give the group as an argument or --group, not both", .{});
        return null;
    }
    const g: ?[]const u8 = if (o.positionals.len == 1) o.positionals[0] else o.get("--group");
    if (g == null) code.* = common.usage(ctx, v.usage, "{s} {s} requires a group (<id|ref>)", .{ prefix, v.name });
    return g;
}

/// Parses `args` with `--group` plus `extra`, validates the group and
/// stores it as `group_id`.
fn groupParams(ctx: *Ctx, args: []const []const u8, v: *const Verb, prefix: []const u8, extra: []const Def, p: *Params, code: *u8) !?common.opts.Opts {
    var defs: std.ArrayList(Def) = .empty;
    try defs.append(ctx.arena, .{ .name = "--group" });
    try defs.appendSlice(ctx.arena, extra);
    const o = (try common.parseOpts(ctx, v.usage, args, defs.items, code)) orelse return null;
    const g = groupArg(ctx, o, v, prefix, code) orelse return null;
    if (try common.putHandle(ctx, p, v.usage, "group_id", .workspace_group, g)) |c| {
        code.* = c;
        return null;
    }
    return o;
}

fn runGroupOnly(ctx: *Ctx, args: []const []const u8, v: *const Verb, prefix: []const u8) !u8 {
    var code: u8 = 0;
    var p = Params.init(ctx.arena);
    _ = (try groupParams(ctx, args, v, prefix, &.{}, &p, &code)) orelse return code;
    return common.simple(ctx, v.method, &p);
}

fn runList(ctx: *Ctx, args: []const []const u8, v: *const Verb, _: []const u8) !u8 {
    var code: u8 = 0;
    const o = (try common.parseOpts(ctx, v.usage, args, &.{.{ .name = "--window" }}, &code)) orelse return code;
    if (o.positionals.len > 0) return common.usage(ctx, v.usage, "unexpected argument '{s}'", .{o.positionals[0]});
    var p = Params.init(ctx.arena);
    if (try common.putWindow(ctx, &p, v.usage, o)) |c| return c;
    const r = switch (try common.request(ctx, v.method, &p)) {
        .code => |c| return c,
        .ok => |r| r,
    };
    if (ctx.json()) {
        try common.writeJsonResult(ctx, r);
        return output.exit.ok;
    }
    const items = common.list(r, "groups") orelse &.{};
    if (items.len == 0) {
        try ctx.out.writeAll("No workspace groups\n");
        return output.exit.ok;
    }
    for (items) |g| {
        const handle = (try common.handleText(ctx, g, "group")) orelse "?";
        const members = common.list(g, "workspace_ids") orelse common.list(g, "child_workspace_ids");
        const count = common.int(g, "workspace_count") orelse if (members) |l| @as(i64, @intCast(l.len)) else 0;
        try ctx.out.print("{s}  {s}  workspaces={d}", .{ handle, common.str(g, "name") orelse "", count });
        if (common.boolean(g, "collapsed")) try ctx.out.writeAll("  [collapsed]");
        if (common.boolean(g, "pinned")) try ctx.out.writeAll("  [pinned]");
        try ctx.out.writeByte('\n');
    }
    return output.exit.ok;
}

fn runCreate(ctx: *Ctx, args: []const []const u8, v: *const Verb, _: []const u8) !u8 {
    const u = v.usage;
    var code: u8 = 0;
    const defs = [_]Def{ .{ .name = "--name" }, .{ .name = "--cwd" }, .{ .name = "--from" }, .{ .name = "--idempotency-key" }, .{ .name = "--external-id" }, .{ .name = "--window" } };
    const o = (try common.parseOpts(ctx, u, args, &defs, &code)) orelse return code;
    if (o.positionals.len > 0) return common.usage(ctx, u, "unexpected argument '{s}'", .{o.positionals[0]});
    if (o.has("--idempotency-key") and o.has("--external-id")) return common.usage(ctx, u, "--idempotency-key and --external-id cannot be combined", .{});
    var p = Params.init(ctx.arena);
    if (o.get("--name")) |n| try p.str("name", n);
    if (o.get("--cwd")) |c| {
        if (c.len == 0) return common.usage(ctx, u, "--cwd requires a non-empty value", .{});
        try p.str("cwd", try create.resolvePath(ctx, c));
    }
    if (o.get("--from")) |from| {
        // Explicit members only; omitting --from creates an anchor-only group.
        var ids = std.json.Array.init(ctx.arena);
        var it = std.mem.splitScalar(u8, from, ',');
        while (it.next()) |item| {
            if (std.mem.trim(u8, item, " \t").len == 0) return common.usage(ctx, u, "--from has an empty entry", .{});
            var msg: []const u8 = "";
            const hv = (try common.handleValue(ctx.arena, .workspace, item, &msg)) orelse return common.usage(ctx, u, "{s}", .{msg});
            try ids.append(hv);
        }
        // cmux's member key on workspace.group.create.
        try p.value("child_workspace_ids", .{ .array = ids });
    }
    for ([_][2][]const u8{ .{ "--idempotency-key", "idempotency_key" }, .{ "--external-id", "external_id" } }) |f| {
        if (o.get(f[0])) |k| {
            if (std.mem.trim(u8, k, " \t").len == 0) return common.usage(ctx, u, "{s} requires a non-empty value", .{f[0]});
            try p.str(f[1], k);
        }
    }
    if (try common.putWindow(ctx, &p, u, o)) |c| return c;
    return common.created(ctx, v.method, &p, "group");
}

fn runRename(ctx: *Ctx, args: []const []const u8, v: *const Verb, prefix: []const u8) !u8 {
    var code: u8 = 0;
    var p = Params.init(ctx.arena);
    const o = (try groupParams(ctx, args, v, prefix, &.{.{ .name = "--name" }}, &p, &code)) orelse return code;
    const name = o.get("--name") orelse "";
    if (std.mem.trim(u8, name, " \t\r\n").len == 0) return common.usage(ctx, v.usage, "{s} rename requires --name <new>", .{prefix});
    try p.str("name", name);
    return common.simple(ctx, v.method, &p);
}

fn runUngroup(ctx: *Ctx, args: []const []const u8, v: *const Verb, prefix: []const u8) !u8 {
    var code: u8 = 0;
    var p = Params.init(ctx.arena);
    const o = (try groupParams(ctx, args, v, prefix, &.{.{ .name = "--remove-generated-anchor", .takes_value = false }}, &p, &code)) orelse return code;
    if (o.has("--remove-generated-anchor")) try p.boolean("remove_generated_anchor", true);
    return common.simple(ctx, v.method, &p);
}

fn runDelete(ctx: *Ctx, args: []const []const u8, v: *const Verb, prefix: []const u8) !u8 {
    var code: u8 = 0;
    var p = Params.init(ctx.arena);
    const extra = [_]Def{ .{ .name = "--close-workspaces", .takes_value = false }, .{ .name = "--remove-generated-anchor", .takes_value = false } };
    const o = (try groupParams(ctx, args, v, prefix, &extra, &p, &code)) orelse return code;
    if (o.has("--close-workspaces")) try p.boolean("close_workspaces", true);
    if (o.has("--remove-generated-anchor")) try p.boolean("remove_generated_anchor", true);
    const r = switch (try common.request(ctx, v.method, &p)) {
        .code => |c| return c,
        .ok => |r| r,
    };
    if (ctx.json()) {
        try common.writeJsonResult(ctx, r);
        return output.exit.ok;
    }
    try ctx.out.writeAll("OK");
    if (common.str(r, "operation")) |op| try ctx.out.print(" operation={s}", .{op});
    if (common.int(r, "affected")) |n| try ctx.out.print(" affected={d}", .{n});
    try ctx.out.writeByte('\n');
    return output.exit.ok;
}

/// `--workspace`, else the caller's workspace; usage error when neither.
fn putMember(ctx: *Ctx, o: common.opts.Opts, v: *const Verb, prefix: []const u8, p: *Params) !?u8 {
    const window_given = ctx.parsed.globals.window != null;
    if (o.get("--workspace")) |ws| return common.putExplicitWorkspace(ctx, p, v.usage, "workspace_id", ws, window_given);
    const caller = (if (window_given) null else common.callerWorkspace(ctx)) orelse
        return common.usage(ctx, v.usage, "{s} {s} requires --workspace <id|ref|index>", .{ prefix, v.name });
    try p.str("workspace_id", caller);
    return null;
}

fn runGroupWorkspace(ctx: *Ctx, args: []const []const u8, v: *const Verb, prefix: []const u8) !u8 {
    var code: u8 = 0;
    var p = Params.init(ctx.arena);
    const o = (try groupParams(ctx, args, v, prefix, &.{.{ .name = "--workspace" }}, &p, &code)) orelse return code;
    if (try putMember(ctx, o, v, prefix, &p)) |c| return c;
    return common.simple(ctx, v.method, &p);
}

fn runRemove(ctx: *Ctx, args: []const []const u8, v: *const Verb, prefix: []const u8) !u8 {
    var code: u8 = 0;
    const o = (try common.parseOpts(ctx, v.usage, args, &.{.{ .name = "--workspace" }}, &code)) orelse return code;
    if (o.positionals.len > 0) return common.usage(ctx, v.usage, "unexpected argument '{s}'", .{o.positionals[0]});
    var p = Params.init(ctx.arena);
    if (try putMember(ctx, o, v, prefix, &p)) |c| return c;
    return common.simple(ctx, v.method, &p);
}

/// `#RRGGBB`.
pub fn validHex(s: []const u8) bool {
    if (s.len != 7 or s[0] != '#') return false;
    for (s[1..]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn runSetColor(ctx: *Ctx, args: []const []const u8, v: *const Verb, prefix: []const u8) !u8 {
    var code: u8 = 0;
    var p = Params.init(ctx.arena);
    const o = (try groupParams(ctx, args, v, prefix, &.{.{ .name = "--hex" }}, &p, &code)) orelse return code;
    const hex = std.mem.trim(u8, o.get("--hex") orelse "", " \t");
    if (hex.len == 0) {
        // Empty or missing clears the color.
        try p.value("hex", .null);
    } else {
        if (!validHex(hex)) return common.usage(ctx, v.usage, "--hex must be #RRGGBB (got '{s}')", .{hex});
        try p.str("hex", hex);
    }
    return common.simple(ctx, v.method, &p);
}

fn runSetIcon(ctx: *Ctx, args: []const []const u8, v: *const Verb, prefix: []const u8) !u8 {
    var code: u8 = 0;
    var p = Params.init(ctx.arena);
    const o = (try groupParams(ctx, args, v, prefix, &.{.{ .name = "--symbol" }}, &p, &code)) orelse return code;
    const sym = std.mem.trim(u8, o.get("--symbol") orelse "", " \t");
    if (sym.len == 0) try p.value("symbol", .null) else try p.str("symbol", sym);
    return common.simple(ctx, v.method, &p);
}

fn runMove(ctx: *Ctx, args: []const []const u8, v: *const Verb, prefix: []const u8) !u8 {
    var code: u8 = 0;
    var p = Params.init(ctx.arena);
    const extra = [_]Def{ .{ .name = "--to-index" }, .{ .name = "--before" }, .{ .name = "--after" } };
    const o = (try groupParams(ctx, args, v, prefix, &extra, &p, &code)) orelse return code;
    var n: usize = 0;
    for (extra) |d| {
        if (o.has(d.name)) n += 1;
    }
    if (n != 1) return common.usage(ctx, v.usage, "{s} move requires exactly one of --to-index, --before or --after", .{prefix});
    if (o.get("--to-index")) |s| {
        const i = @import("ws/reorder.zig").parseIndex(s) orelse return common.usage(ctx, v.usage, "--to-index must be a non-negative integer (got '{s}')", .{s});
        try p.int("to_index", i);
    }
    if (o.get("--before")) |g| if (try common.putHandle(ctx, &p, v.usage, "before_group_id", .workspace_group, g)) |c| return c;
    if (o.get("--after")) |g| if (try common.putHandle(ctx, &p, v.usage, "after_group_id", .workspace_group, g)) |c| return c;
    return common.simple(ctx, v.method, &p);
}

fn runNewWorkspace(ctx: *Ctx, args: []const []const u8, v: *const Verb, prefix: []const u8) !u8 {
    var code: u8 = 0;
    var p = Params.init(ctx.arena);
    const o = (try groupParams(ctx, args, v, prefix, &.{.{ .name = "--placement" }}, &p, &code)) orelse return code;
    if (o.get("--placement")) |pl| {
        if (!create.validPlacement(pl)) return common.usage(ctx, v.usage, "--placement must be one of: afterCurrent, top, end", .{});
        try p.str("placement", pl);
    }
    return common.created(ctx, v.method, &p, "workspace");
}

// ----- tests -----

const testing = std.testing;
const testkit = @import("ws/testkit.zig");

test "unit: cli-workspace-group: offline help in both spellings" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    try testkit.expectHelpGolden(&h, &.{"workspace-group"}, "workspace-group-help.txt");
    try testkit.expectHelpGolden(&h, &.{ "workspace-group", "create" }, "workspace-group-help.txt");
    const ns = try testkit.expectOk(&h, &.{ "workspace", "group", "list", "--help" });
    try testing.expect(std.mem.startsWith(u8, ns, "Usage: cmux workspace <list|create|env|close|rename|select|status|reconnect|disconnect|group> [args]\n"));
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
}

const groups_json =
    \\{"window_ref":"window:1","groups":[
    \\{"group_id":"0A000000-0000-4000-8000-000000000001","group_ref":"workspace_group:1","name":"Backend","workspace_count":3,"collapsed":true,"pinned":false},
    \\{"group_id":"0A000000-0000-4000-8000-000000000002","group_ref":"workspace_group:2","name":"Fronts été","workspace_ids":["A","B"],"collapsed":false,"pinned":true}]}
;

test "unit: cli-workspace-group: list text, json, empty and both spellings" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.group.list", groups_json);
    const out = try testkit.expectOk(&h, &.{ "workspace-group", "list" });
    try testkit.expectGolden(h.alloc(), "workspace-group-list.txt", out);
    try h.expectLast("workspace.group.list", "{}");
    try testing.expectEqualStrings(out, try testkit.expectOk(&h, &.{ "workspace", "group", "list" }));
    _ = try testkit.expectOk(&h, &.{ "workspace-group", "list", "--window", "window:2" });
    try h.expectLast("workspace.group.list", "{\"window_id\":\"window:2\"}");
    const js = try testkit.expectOk(&h, &.{ "workspace-group", "list", "--json" });
    try testkit.expectGolden(h.alloc(), "workspace-group-list-json.txt", js);
    h.ok("workspace.group.list", "{\"groups\":[]}");
    try testing.expectEqualStrings("No workspace groups\n", try testkit.expectOk(&h, &.{ "workspace-group", "list" }));
}

test "unit: cli-workspace-group: create params and validation" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.group.create", "{\"group_id\":\"0A000000-0000-4000-8000-000000000003\",\"group_ref\":\"workspace_group:3\"}");
    const out = try testkit.expectOk(&h, &.{ "workspace-group", "create", "--name", "m", "--from", "workspace:1,workspace:2", "--idempotency-key", "k" });
    try testkit.expectGolden(h.alloc(), "workspace-group-create.txt", out);
    try h.expectLast("workspace.group.create", "{\"name\":\"m\",\"child_workspace_ids\":[\"workspace:1\",\"workspace:2\"],\"idempotency_key\":\"k\"}");
    // Anchor-only: no --from means no members are inferred.
    _ = try testkit.expectOk(&h, &.{ "workspace", "group", "create", "--cwd", "/srv", "--external-id", "jira-7" });
    try h.expectLast("workspace.group.create", "{\"cwd\":\"/srv\",\"external_id\":\"jira-7\"}");
    _ = try testkit.expectOk(&h, &.{ "workspace-group", "create", "--from", "3", "--window", "window:1" });
    try h.expectLast("workspace.group.create", "{\"child_workspace_ids\":[3],\"window_id\":\"window:1\"}");
    try testkit.expectUsage(&h, &.{ "workspace-group", "create", "--idempotency-key", "k", "--external-id", "e" }, "--idempotency-key and --external-id cannot be combined");
    try testkit.expectUsage(&h, &.{ "workspace-group", "create", "--from", "workspace:1," }, "--from has an empty entry");
    try testkit.expectUsage(&h, &.{ "workspace-group", "create", "--from", "pane:1" }, "Invalid workspace handle: pane:1 (expected UUID, ref like workspace:1, or index)");
    try testkit.expectUsage(&h, &.{ "workspace-group", "create", "--idempotency-key", " " }, "--idempotency-key requires a non-empty value");
    try testkit.expectUsage(&h, &.{ "workspace-group", "create", "name" }, "unexpected argument 'name'");
}

test "unit: cli-workspace-group: group verbs map onto workspace.group methods" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    const Case = struct { argv: []const []const u8, method: []const u8, params: []const u8 };
    const cases = [_]Case{
        .{ .argv = &.{ "rename", "workspace_group:1", "--name", "New \u{1F680}" }, .method = "workspace.group.rename", .params = "{\"group_id\":\"workspace_group:1\",\"name\":\"New \u{1F680}\"}" },
        .{ .argv = &.{ "ungroup", "workspace_group:1", "--remove-generated-anchor" }, .method = "workspace.group.ungroup", .params = "{\"group_id\":\"workspace_group:1\",\"remove_generated_anchor\":true}" },
        .{ .argv = &.{ "ungroup", "workspace_group:1" }, .method = "workspace.group.ungroup", .params = "{\"group_id\":\"workspace_group:1\"}" },
        .{ .argv = &.{ "collapse", "0A000000-0000-4000-8000-000000000001" }, .method = "workspace.group.collapse", .params = "{\"group_id\":\"0A000000-0000-4000-8000-000000000001\"}" },
        .{ .argv = &.{ "expand", "workspace_group:2" }, .method = "workspace.group.expand", .params = "{\"group_id\":\"workspace_group:2\"}" },
        .{ .argv = &.{ "pin", "--group", "workspace_group:2" }, .method = "workspace.group.pin", .params = "{\"group_id\":\"workspace_group:2\"}" },
        .{ .argv = &.{ "unpin", "1" }, .method = "workspace.group.unpin", .params = "{\"group_id\":1}" },
        .{ .argv = &.{ "focus", "workspace_group:2" }, .method = "workspace.group.focus", .params = "{\"group_id\":\"workspace_group:2\"}" },
        .{ .argv = &.{ "add", "--group", "workspace_group:2", "--workspace", "workspace:5" }, .method = "workspace.group.add", .params = "{\"group_id\":\"workspace_group:2\",\"workspace_id\":\"workspace:5\"}" },
        .{ .argv = &.{ "remove", "--workspace", "workspace:5" }, .method = "workspace.group.remove", .params = "{\"workspace_id\":\"workspace:5\"}" },
        .{ .argv = &.{ "set-anchor", "--group", "workspace_group:2", "--workspace", "workspace:6" }, .method = "workspace.group.set_anchor", .params = "{\"group_id\":\"workspace_group:2\",\"workspace_id\":\"workspace:6\"}" },
        .{ .argv = &.{ "set-color", "workspace_group:2", "--hex", "#FF8800" }, .method = "workspace.group.set_color", .params = "{\"group_id\":\"workspace_group:2\",\"hex\":\"#FF8800\"}" },
        .{ .argv = &.{ "set-color", "workspace_group:2", "--hex", "" }, .method = "workspace.group.set_color", .params = "{\"group_id\":\"workspace_group:2\",\"hex\":null}" },
        .{ .argv = &.{ "set-color", "workspace_group:2" }, .method = "workspace.group.set_color", .params = "{\"group_id\":\"workspace_group:2\",\"hex\":null}" },
        .{ .argv = &.{ "set-icon", "workspace_group:2", "--symbol", "hammer" }, .method = "workspace.group.set_icon", .params = "{\"group_id\":\"workspace_group:2\",\"symbol\":\"hammer\"}" },
        .{ .argv = &.{ "set-icon", "workspace_group:2", "--symbol=" }, .method = "workspace.group.set_icon", .params = "{\"group_id\":\"workspace_group:2\",\"symbol\":null}" },
        .{ .argv = &.{ "move", "workspace_group:2", "--to-index", "0" }, .method = "workspace.group.move", .params = "{\"group_id\":\"workspace_group:2\",\"to_index\":0}" },
        .{ .argv = &.{ "move", "workspace_group:2", "--before", "workspace_group:1" }, .method = "workspace.group.move", .params = "{\"group_id\":\"workspace_group:2\",\"before_group_id\":\"workspace_group:1\"}" },
        .{ .argv = &.{ "move", "workspace_group:2", "--after", "workspace_group:1" }, .method = "workspace.group.move", .params = "{\"group_id\":\"workspace_group:2\",\"after_group_id\":\"workspace_group:1\"}" },
    };
    for (cases) |c| {
        h.ok(c.method, "{}");
        for ([_][]const u8{ "workspace-group", "workspace group" }) |spelling| {
            var argv: std.ArrayList([]const u8) = .empty;
            var words = std.mem.splitScalar(u8, spelling, ' ');
            while (words.next()) |w| try argv.append(h.alloc(), w);
            try argv.appendSlice(h.alloc(), c.argv);
            try testing.expectEqualStrings("OK\n", try testkit.expectOk(&h, argv.items));
            try h.expectLast(c.method, c.params);
        }
    }
}

test "unit: cli-workspace-group: delete reports the operation; new-workspace prints the handle" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.group.delete", "{\"operation\":\"close_workspaces\",\"affected\":3}");
    const out = try testkit.expectOk(&h, &.{ "workspace-group", "delete", "workspace_group:1", "--close-workspaces", "--remove-generated-anchor" });
    try testkit.expectGolden(h.alloc(), "workspace-group-delete.txt", out);
    try h.expectLast("workspace.group.delete", "{\"group_id\":\"workspace_group:1\",\"close_workspaces\":true,\"remove_generated_anchor\":true}");
    h.ok("workspace.group.delete", "{}");
    try testing.expectEqualStrings("OK\n", try testkit.expectOk(&h, &.{ "workspace-group", "delete", "workspace_group:1" }));
    try h.expectLast("workspace.group.delete", "{\"group_id\":\"workspace_group:1\"}");

    h.ok("workspace.group.new_workspace", "{\"workspace_id\":\"W\",\"workspace_ref\":\"workspace:9\",\"group_ref\":\"workspace_group:1\"}");
    const nw = try testkit.expectOk(&h, &.{ "workspace-group", "new-workspace", "workspace_group:1", "--placement", "afterCurrent" });
    try testkit.expectGolden(h.alloc(), "workspace-group-new-workspace.txt", nw);
    try h.expectLast("workspace.group.new_workspace", "{\"group_id\":\"workspace_group:1\",\"placement\":\"afterCurrent\"}");
    _ = try testkit.expectOk(&h, &.{ "workspace", "group", "new-workspace", "workspace_group:1" });
    try h.expectLast("workspace.group.new_workspace", "{\"group_id\":\"workspace_group:1\"}");
    try testkit.expectUsage(&h, &.{ "workspace-group", "new-workspace", "workspace_group:1", "--placement", "bottom" }, "--placement must be one of: afterCurrent, top, end");
}

test "unit: cli-workspace-group: membership verbs default to the caller's workspace" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.group.add", "{}");
    h.ok("workspace.group.remove", "{}");
    h.ok("workspace.group.set_anchor", "{}");
    try testkit.expectUsage(&h, &.{ "workspace-group", "add", "--group", "workspace_group:1" }, "workspace-group add requires --workspace <id|ref|index>");
    try testkit.expectUsage(&h, &.{ "workspace", "group", "remove" }, "workspace group remove requires --workspace <id|ref|index>");
    h.setEnv("CMUX_WORKSPACE_ID", "CALLER-UUID");
    _ = try testkit.expectOk(&h, &.{ "workspace-group", "add", "--group", "workspace_group:1" });
    try h.expectLast("workspace.group.add", "{\"group_id\":\"workspace_group:1\",\"workspace_id\":\"CALLER-UUID\"}");
    _ = try testkit.expectOk(&h, &.{ "workspace-group", "remove" });
    try h.expectLast("workspace.group.remove", "{\"workspace_id\":\"CALLER-UUID\"}");
    // A blank --workspace is the caller's workspace too (ADR-4.6)...
    _ = try testkit.expectOk(&h, &.{ "workspace-group", "set-anchor", "--group", "workspace_group:1", "--workspace", "" });
    try h.expectLast("workspace.group.set_anchor", "{\"group_id\":\"workspace_group:1\",\"workspace_id\":\"CALLER-UUID\"}");
    // ...but naming a window drops the caller default.
    const msg = "No workspace selected: --workspace was blank and CMUX_WORKSPACE_ID is unset";
    try testkit.expectUsage(&h, &.{ "--window", "window:1", "workspace-group", "remove", "--workspace", " " }, msg);
    try testkit.expectUsage(&h, &.{ "--window", "window:1", "workspace", "group", "remove" }, "workspace group remove requires --workspace <id|ref|index>");
    h.unsetEnv("CMUX_WORKSPACE_ID");
    try testkit.expectUsage(&h, &.{ "workspace-group", "add", "--group", "workspace_group:1", "--workspace=" }, msg);
}

test "unit: cli-workspace-group: group handles in the kind spelling print too" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.group.create", "{\"workspace_group_id\":\"0A000000-0000-4000-8000-000000000004\",\"workspace_group_ref\":\"workspace_group:4\"}");
    try testing.expectEqualStrings("OK workspace_group:4\n", try testkit.expectOk(&h, &.{ "workspace-group", "create", "--name", "x" }));
    try testing.expectEqualStrings("OK 0A000000-0000-4000-8000-000000000004\n", try testkit.expectOk(&h, &.{ "workspace-group", "create", "--id-format", "uuids" }));
    h.ok("workspace.group.list", "{\"groups\":[{\"workspace_group_ref\":\"workspace_group:4\",\"name\":\"N\",\"child_workspace_ids\":[\"A\",\"B\",\"C\"]},{\"ref\":\"workspace_group:5\",\"name\":\"M\"}]}");
    try testing.expectEqualStrings("workspace_group:4  N  workspaces=3\nworkspace_group:5  M  workspaces=0\n", try testkit.expectOk(&h, &.{ "workspace-group", "list" }));
}

test "unit: cli-workspace-group: usage errors" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    const all = "list, create, rename, ungroup, delete, collapse, expand, pin, unpin, add, remove, set-anchor, set-color, set-icon, move, focus, new-workspace";
    try testkit.expectUsage(&h, &.{"workspace-group"}, "workspace-group requires a subcommand: " ++ all);
    try testkit.expectUsage(&h, &.{ "workspace", "group" }, "workspace group requires a subcommand: " ++ all);
    try testkit.expectUsage(&h, &.{ "workspace-group", "explode" }, "unknown workspace-group subcommand 'explode'; expected one of: " ++ all);
    try testkit.expectUsage(&h, &.{ "workspace-group", "collapse" }, "workspace-group collapse requires a group (<id|ref>)");
    try testkit.expectUsage(&h, &.{ "workspace", "group", "focus" }, "workspace group focus requires a group (<id|ref>)");
    try testkit.expectUsage(&h, &.{ "workspace-group", "pin", "workspace_group:1", "workspace_group:2" }, "unexpected argument 'workspace_group:2'");
    try testkit.expectUsage(&h, &.{ "workspace-group", "pin", "workspace_group:1", "--group", "workspace_group:2" }, "give the group as an argument or --group, not both");
    try testkit.expectUsage(&h, &.{ "workspace-group", "pin", "workspace:1" }, "Invalid workspace group handle: workspace:1 (expected UUID, ref like workspace_group:1, or index)");
    try testkit.expectUsage(&h, &.{ "workspace-group", "pin", "" }, "Workspace group handle is blank");
    try testkit.expectUsage(&h, &.{ "workspace-group", "rename", "workspace_group:1" }, "workspace-group rename requires --name <new>");
    try testkit.expectUsage(&h, &.{ "workspace-group", "set-color", "workspace_group:1", "--hex", "orange" }, "--hex must be #RRGGBB (got 'orange')");
    try testkit.expectUsage(&h, &.{ "workspace-group", "move", "workspace_group:1" }, "workspace-group move requires exactly one of --to-index, --before or --after");
    try testkit.expectUsage(&h, &.{ "workspace-group", "move", "workspace_group:1", "--to-index", "1", "--after", "workspace_group:2" }, "workspace-group move requires exactly one of --to-index, --before or --after");
    try testkit.expectUsage(&h, &.{ "workspace-group", "move", "workspace_group:1", "--to-index", "x" }, "--to-index must be a non-negative integer (got 'x')");
    try testkit.expectUsage(&h, &.{ "workspace-group", "remove", "workspace:1" }, "unexpected argument 'workspace:1'");
    try testkit.expectUsage(&h, &.{ "workspace-group", "list", "--bogus" }, "unknown option '--bogus'");
    try testing.expect(validHex("#a1B2c3"));
    try testing.expect(!validHex("a1b2c3"));
    try testing.expect(!validHex("#a1b2c"));
}

test "unit: cli-workspace-group: server errors exit 1" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.fail("workspace.group.ungroup", "{\"code\":\"invalid_state\",\"message\":\"Group has children\"}");
    const r = h.run(&.{ "workspace-group", "ungroup", "workspace_group:1", "--remove-generated-anchor" });
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings("invalid_state: Group has children\n", r.err);
}
