//! `reorder-workspace`, `reorder-workspaces` (core-workspace-reorder) and
//! `workspace-action` (core-cli-workspace-action).
//!
//! - `workspace.reorder {workspace_id, index | before_workspace_id |
//!   after_workspace_id, window_id?, dry_run?}`; `--dry-run` prints the
//!   resolved final index.
//! - `workspace.reorder_many {workspace_ids, window_id?, dry_run?}`;
//!   `--dry-run` prints the resulting order, one handle per line, or, for
//!   cmux's `plan[]` result, one `<handle> from=<i> to=<j>` line per step.
//! - `workspace.action {action, workspace_id?, window_id?, title?,
//!   description?, color?, force?}`.

const std = @import("std");
const command = @import("../../command.zig");
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const common = @import("common.zig");
const Def = common.opts.Def;
const Params = common.Params;

pub const u_reorder = "Usage: cmux reorder-workspace [--workspace <id|ref|index> | <id|ref|index>] (--index <n> | --before <id|ref|index> | --after <id|ref|index>) [--window <id|ref|index>] [--dry-run]";
pub const u_reorder_many = "Usage: cmux reorder-workspaces --order <id|ref|index>,<id|ref|index>,... [--window <id|ref|index>] [--dry-run]";
pub const u_action = "Usage: cmux workspace-action --action <name> [--workspace <id|ref|index>] [--window <id|ref|index>] [--title <text>] [--description <text>] [--color <name|#RRGGBB>] [--force]";

/// A non-negative decimal index.
pub fn parseIndex(s: []const u8) ?u32 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 0) return null;
    for (t) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, t, 10) catch null;
}

pub fn runReorder(ctx: *Ctx) !u8 {
    const u = u_reorder;
    var code: u8 = 0;
    const defs = [_]Def{
        .{ .name = "--workspace" },
        .{ .name = "--index" },
        .{ .name = "--before", .aliases = &.{"--before-workspace"} },
        .{ .name = "--after", .aliases = &.{"--after-workspace"} },
        .{ .name = "--window" },
        .{ .name = "--dry-run", .takes_value = false },
    };
    const o = (try common.parseOpts(ctx, u, ctx.args(), &defs, &code)) orelse return code;
    if (o.positionals.len > 1) return common.usage(ctx, u, "unexpected argument '{s}'", .{o.positionals[1]});
    if (o.positionals.len == 1 and o.get("--workspace") != null) return common.usage(ctx, u, "give the workspace as an argument or --workspace, not both", .{});
    var n_targets: usize = 0;
    for ([_][]const u8{ "--index", "--before", "--after" }) |f| {
        if (o.has(f)) n_targets += 1;
    }
    if (n_targets != 1) return common.usage(ctx, u, "reorder-workspace requires exactly one of --index, --before or --after", .{});
    var p = Params.init(ctx.arena);
    const explicit: ?[]const u8 = if (o.positionals.len == 1) o.positionals[0] else o.get("--workspace");
    if (try common.putWorkspaceTarget(ctx, &p, u, explicit, common.windowText(ctx, o) != null)) |c| return c;
    if (o.get("--index")) |s| {
        const i = parseIndex(s) orelse return common.usage(ctx, u, "--index must be a non-negative integer (got '{s}')", .{s});
        try p.int("index", i);
    }
    if (o.get("--before")) |s| if (try common.putHandle(ctx, &p, u, "before_workspace_id", .workspace, s)) |c| return c;
    if (o.get("--after")) |s| if (try common.putHandle(ctx, &p, u, "after_workspace_id", .workspace, s)) |c| return c;
    if (try common.putWindow(ctx, &p, u, o)) |c| return c;
    const dry = o.has("--dry-run");
    if (dry) try p.boolean("dry_run", true);
    const v = switch (try common.request(ctx, "workspace.reorder", &p)) {
        .code => |c| return c,
        .ok => |v| v,
    };
    if (ctx.json()) {
        try common.writeJsonResult(ctx, v);
    } else if (dry and common.field(v, "index") != null) {
        try common.writeNumber(ctx.out, common.field(v, "index").?);
        try ctx.out.writeByte('\n');
    } else try ctx.out.writeAll("OK\n");
    return output.exit.ok;
}

pub fn runReorderMany(ctx: *Ctx) !u8 {
    const u = u_reorder_many;
    var code: u8 = 0;
    const defs = [_]Def{ .{ .name = "--order" }, .{ .name = "--window" }, .{ .name = "--dry-run", .takes_value = false } };
    const o = (try common.parseOpts(ctx, u, ctx.args(), &defs, &code)) orelse return code;
    if (o.positionals.len > 0) return common.usage(ctx, u, "unexpected argument '{s}'", .{o.positionals[0]});
    const order = o.get("--order") orelse return common.usage(ctx, u, "reorder-workspaces requires --order", .{});
    var ids = std.json.Array.init(ctx.arena);
    var it = std.mem.splitScalar(u8, order, ',');
    while (it.next()) |item| {
        if (std.mem.trim(u8, item, " \t").len == 0) return common.usage(ctx, u, "--order has an empty entry", .{});
        var msg: []const u8 = "";
        const hv = (try common.handleValue(ctx.arena, .workspace, item, &msg)) orelse return common.usage(ctx, u, "{s}", .{msg});
        try ids.append(hv);
    }
    var p = Params.init(ctx.arena);
    try p.value("workspace_ids", .{ .array = ids });
    if (try common.putWindow(ctx, &p, u, o)) |c| return c;
    const dry = o.has("--dry-run");
    if (dry) try p.boolean("dry_run", true);
    const v = switch (try common.request(ctx, "workspace.reorder_many", &p)) {
        .code => |c| return c,
        .ok => |v| v,
    };
    if (ctx.json()) {
        try common.writeJsonResult(ctx, v);
        return output.exit.ok;
    }
    if (dry) {
        // The resulting order when the result lists it, else cmux's plan
        // (`plan[]` entries with refs and `from_index`/`to_index`).
        if (common.list(v, "workspaces")) |list| {
            for (list) |w| try ctx.out.print("{s}\n", .{(try common.handleText(ctx, w, "workspace")) orelse "?"});
            return output.exit.ok;
        }
        if (common.list(v, "plan")) |plan| {
            for (plan) |step| try writePlanStep(ctx, step);
            return output.exit.ok;
        }
    }
    try ctx.out.writeAll("OK\n");
    return output.exit.ok;
}

/// `<handle> from=<from_index> to=<to_index>` (indexes when present).
fn writePlanStep(ctx: *Ctx, step: std.json.Value) !void {
    try ctx.out.writeAll((try common.handleText(ctx, step, "workspace")) orelse "?");
    if (common.field(step, "from_index")) |f| {
        try ctx.out.writeAll(" from=");
        try common.writeNumber(ctx.out, f);
    }
    if (common.field(step, "to_index")) |t| {
        try ctx.out.writeAll(" to=");
        try common.writeNumber(ctx.out, t);
    }
    try ctx.out.writeByte('\n');
}

pub const actions = [_][]const u8{
    "pin",             "unpin",             "rename",      "clear-name",
    "set-description", "clear-description", "move-up",     "move-down",
    "move-top",        "close-others",      "close-above", "close-below",
    "mark-read",       "mark-unread",       "set-color",   "clear-color",
};

/// cmux's named workspace colors.
pub const color_names = [_][]const u8{
    "Red",  "Crimson", "Orange", "Amber",  "Olive",   "Green", "Teal",  "Aqua",
    "Blue", "Navy",    "Indigo", "Purple", "Magenta", "Rose",  "Brown", "Charcoal",
};

pub fn isAction(s: []const u8) bool {
    for (actions) |a| if (std.mem.eql(u8, a, s)) return true;
    return false;
}

/// `#RRGGBB` as given, or the canonical spelling of a named color (any
/// case); null otherwise.
pub fn normalizeColor(s: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 7 and t[0] == '#') {
        for (t[1..]) |c| if (!std.ascii.isHex(c)) return null;
        return t;
    }
    for (color_names) |n| if (std.ascii.eqlIgnoreCase(n, t)) return n;
    return null;
}

pub fn runAction(ctx: *Ctx) !u8 {
    const u = u_action;
    var code: u8 = 0;
    const defs = [_]Def{
        .{ .name = "--action" },
        .{ .name = "--workspace" },
        .{ .name = "--window" },
        .{ .name = "--title" },
        .{ .name = "--description" },
        .{ .name = "--color" },
        .{ .name = "--force", .takes_value = false },
    };
    const o = (try common.parseOpts(ctx, u, ctx.args(), &defs, &code)) orelse return code;
    var rest = o.positionals;
    const action = o.get("--action") orelse blk: {
        if (rest.len == 0) return common.usage(ctx, u, "workspace-action requires --action <name>", .{});
        const a = rest[0];
        rest = rest[1..];
        break :blk a;
    };
    if (!isAction(action)) {
        const valid = try std.mem.join(ctx.arena, ", ", &actions);
        return common.usage(ctx, u, "Unknown workspace action: {s}. Valid actions: {s}", .{ action, valid });
    }
    const is_desc = std.mem.eql(u8, action, "set-description");
    if (rest.len > 0 and !is_desc) return common.usage(ctx, u, "unexpected argument '{s}'", .{rest[0]});
    var p = Params.init(ctx.arena);
    try p.str("action", action);
    if (try common.putWorkspaceTarget(ctx, &p, u, o.get("--workspace"), common.windowText(ctx, o) != null)) |c| return c;
    if (try common.putWindow(ctx, &p, u, o)) |c| return c;
    if (std.mem.eql(u8, action, "rename")) {
        const t = o.get("--title") orelse "";
        if (std.mem.trim(u8, t, " \t\r\n").len == 0) return common.usage(ctx, u, "workspace-action rename requires --title <text>", .{});
        try p.str("title", t);
    } else if (is_desc) {
        // Trailing text is the description; newlines are kept.
        const d = o.get("--description") orelse if (rest.len > 0) try std.mem.join(ctx.arena, " ", rest) else return common.usage(ctx, u, "workspace-action set-description requires --description <text> or trailing text", .{});
        if (o.get("--description") != null and rest.len > 0) return common.usage(ctx, u, "unexpected argument '{s}'", .{rest[0]});
        try p.str("description", d);
    } else if (std.mem.eql(u8, action, "set-color")) {
        const c = o.get("--color") orelse return common.usage(ctx, u, "workspace-action set-color requires --color <name|#RRGGBB>", .{});
        const norm = normalizeColor(c) orelse {
            const names = try std.mem.join(ctx.arena, ", ", &color_names);
            return common.usage(ctx, u, "invalid color '{s}': use #RRGGBB or one of {s}", .{ c, names });
        };
        try p.str("color", norm);
    }
    if (o.has("--force")) try p.boolean("force", true);
    return common.simple(ctx, "workspace.action", &p);
}
