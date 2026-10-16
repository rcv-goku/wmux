//! CLI command family `notify` (Appendix C).
//! notify, list-notifications, dismiss-notification, mark-notification-read,
//! open-notification, jump-to-unread, clear-notifications, set-app-focus,
//! simulate-app-active (W2-5); jump-to-last-prompt (W3-4); trigger-flash and
//! `feed clear` (assigned to this WP; Appendix C lists them under
//! pane_surface and layout_todo).
//!
//! Each command validates its arguments strictly with cmux's messages, maps
//! them onto the `notification.*`, `surface.*` and `app.*` v2 methods with
//! explicit selectors (caller environment defaults per ADR-4.6), and prints
//! cmux's text (`OK`, `OK notification:<uuid>`, the v1 list format) or the
//! id-formatted result with `--json`.

const std = @import("std");
const proto = @import("wmux_proto");
const Uuid = proto.uuid.Uuid;
const command = @import("../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../output.zig");
const common = @import("notify/common.zig");
const Params = common.Params;
const Opt = common.Opt;

/// `CommandSpec` entries (ADR-4.9).
pub const commands = [_]CommandSpec{
    .{ .name = "notify", .group = .agents, .usage = common.usageOf(@embedFile("../help/notify.txt")), .help = @embedFile("../help/notify.txt"), .run = runNotify },
    .{ .name = "list-notifications", .group = .agents, .usage = common.usageOf(@embedFile("../help/list-notifications.txt")), .help = @embedFile("../help/list-notifications.txt"), .run = runList },
    .{ .name = "dismiss-notification", .group = .agents, .usage = common.usageOf(@embedFile("../help/dismiss-notification.txt")), .help = @embedFile("../help/dismiss-notification.txt"), .run = runDismiss },
    .{ .name = "mark-notification-read", .group = .agents, .usage = common.usageOf(@embedFile("../help/mark-notification-read.txt")), .help = @embedFile("../help/mark-notification-read.txt"), .run = runMarkRead },
    .{ .name = "open-notification", .group = .agents, .usage = common.usageOf(@embedFile("../help/open-notification.txt")), .help = @embedFile("../help/open-notification.txt"), .run = runOpen },
    .{ .name = "jump-to-unread", .group = .agents, .usage = common.usageOf(@embedFile("../help/jump-to-unread.txt")), .help = @embedFile("../help/jump-to-unread.txt"), .run = runJumpToUnread },
    .{ .name = "jump-to-last-prompt", .group = .agents, .usage = common.usageOf(@embedFile("../help/jump-to-last-prompt.txt")), .help = @embedFile("../help/jump-to-last-prompt.txt"), .run = runJumpToLastPrompt },
    .{ .name = "clear-notifications", .group = .agents, .usage = common.usageOf(@embedFile("../help/clear-notifications.txt")), .help = @embedFile("../help/clear-notifications.txt"), .run = runClear },
    .{ .name = "set-app-focus", .group = .agents, .usage = common.usageOf(@embedFile("../help/set-app-focus.txt")), .help = @embedFile("../help/set-app-focus.txt"), .run = runSetAppFocus },
    .{ .name = "simulate-app-active", .group = .agents, .usage = common.usageOf(@embedFile("../help/simulate-app-active.txt")), .help = @embedFile("../help/simulate-app-active.txt"), .run = runSimulateAppActive },
    .{ .name = "trigger-flash", .group = .navigate, .usage = common.usageOf(@embedFile("../help/trigger-flash.txt")), .help = @embedFile("../help/trigger-flash.txt"), .run = runTriggerFlash },
    .{ .name = "feed", .group = .automation, .usage = common.usageOf(@embedFile("../help/feed.txt")), .help = @embedFile("../help/feed.txt"), .socket = .none, .run = runFeed },
};

/// Defaults of a created notification (cmux).
pub const default_title = "Notification";

const target_opts = [_]Opt{
    .{ .name = "--workspace" },
    .{ .name = "--surface" },
    .{ .name = "--window" },
};

/// Strips `notification:` (any case) and parses the UUID.
pub fn parseNotificationId(text: []const u8) ?Uuid {
    const t = std.mem.trim(u8, text, " \t\r\n");
    const prefix = proto.handles.notification_prefix;
    const body = if (t.len >= prefix.len and std.ascii.eqlIgnoreCase(t[0..prefix.len], prefix)) t[prefix.len..] else t;
    return Uuid.parse(body) catch null;
}

fn idParam(ctx: *Ctx, cmd: []const u8, text: []const u8, p: *Params, code: *u8) !bool {
    const id = parseNotificationId(text) orelse {
        code.* = ctx.usageError("{s}: invalid notification id '{s}' (expected <uuid> or notification:<uuid>)", .{ cmd, text });
        return false;
    };
    const t = id.toText();
    try p.str("id", try ctx.arena.dupe(u8, &t));
    return true;
}

fn noArgs(ctx: *Ctx, cmd: []const u8) ?u8 {
    if (ctx.args().len == 0) return null;
    const joined = std.mem.join(ctx.arena, " ", ctx.args()) catch "";
    return ctx.usageError("{s}: unexpected arguments: {s}", .{ cmd, joined });
}

// ----- notify -----

const notify_opts = [_]Opt{
    .{ .name = "--title" },
    .{ .name = "--subtitle" },
    .{ .name = "--body" },
    .{ .name = "--desktop" },
    .{ .name = "--reply", .kind = .flag },
    .{ .name = "--clear", .kind = .flag },
    .{ .name = "--workspace" },
    .{ .name = "--surface" },
    .{ .name = "--window" },
    // Legacy compatibility spellings (cmux docs).
    .{ .name = "--tab", .canonical = "--workspace" },
    .{ .name = "--panel", .canonical = "--surface" },
};

pub const clear_surface_context_message = "notify --clear --surface requires workspace or window context; specify --workspace or --window";
const surface_context_message = "notify --surface requires workspace or window context; specify --workspace or --window";

fn runNotify(ctx: *Ctx) !u8 {
    var code: u8 = 0;
    const s = (try common.scanOrReport(ctx, "notify", &notify_opts, .{ .positionals = false, .dashdash_last_only = true }, &code)) orelse return code;
    const clear = s.has("--clear");
    var desktop: ?bool = null;
    if (!clear) if (s.get("--desktop")) |d| {
        desktop = common.parseBool(d) orelse return ctx.usageError("--desktop must be true|false", .{});
    };
    const t = common.resolveTarget(ctx, s, .{ .env_workspace = false }, &code) orelse return code;
    if (clear) return notifyClear(ctx, t);

    var p = Params.init(ctx.arena);
    var method: []const u8 = "notification.create_for_caller";
    if (t.surface) |sf| {
        const h = proto.handles.parseHandle(.surface, sf) catch unreachable;
        const global = h == .uuid or h == .legacy_core_id;
        const env_ws = common.envWorkspace(ctx);
        if (global) {
            method = "notification.create";
            try p.str("surface_id", sf);
        } else if (t.workspace != null or t.window != null or env_ws != null) {
            // A ref or index resolves inside the workspace context.
            method = "notification.create_for_target";
            if (t.window) |w| try p.str("window_id", w);
            if (t.workspace orelse (if (t.window == null) env_ws else null)) |w| try p.str("workspace_id", w);
            try p.str("surface_id", sf);
        } else if (h == .ref) {
            // Refs are global and never reused.
            method = "notification.create";
            try p.str("surface_id", sf);
        } else return ctx.usageError("{s}", .{surface_context_message});
    } else if (t.window != null) {
        // The window's current (or the given) workspace, workspace-level.
        method = "notification.create_for_target";
        try t.put(&p);
    } else {
        try p.object("caller", common.callerObject(ctx));
        const env_ws = common.envWorkspace(ctx);
        const ws = t.workspace orelse env_ws;
        if (ws) |w| try p.str("preferred_workspace_id", w);
        const same_ws = t.workspace == null or (env_ws != null and std.mem.eql(u8, env_ws.?, t.workspace.?));
        if (same_ws) if (common.envSurface(ctx)) |sf| try p.str("preferred_surface_id", sf);
        if (common.insideTmux(ctx) and t.window == null) try p.boolean("prefer_tty", true);
    }
    try p.str("title", s.get("--title") orelse default_title);
    try p.str("subtitle", s.get("--subtitle") orelse "");
    try p.str("body", s.get("--body") orelse "");
    if (s.has("--reply")) try p.str("reply_shape", "text");
    if (desktop) |d| {
        var e = Params.init(ctx.arena);
        try e.boolean("desktop", d);
        try p.object("effects", e);
    }
    const r = (try common.request(ctx, method, &p)) orelse return output.exit.runtime;
    if (ctx.json()) return common.printOk(ctx, r);
    try ctx.out.writeAll("OK");
    if (common.strField(r, "id")) |id| {
        const ref = try std.mem.concat(ctx.arena, u8, &.{ proto.handles.notification_prefix, id });
        try ctx.out.writeByte(' ');
        try proto.idformat.writeHandle(ctx.out, ctx.parsed.globals.id_format, ref, id, .{});
    }
    try ctx.out.writeByte('\n');
    return output.exit.ok;
}

fn notifyClear(ctx: *Ctx, t: common.Target) !u8 {
    var p = Params.init(ctx.arena);
    if (t.surface != null) {
        if (t.workspace == null and t.window == null) return ctx.usageError("{s}", .{clear_surface_context_message});
        try t.put(&p);
    } else if (t.workspace != null or t.window != null) {
        try t.put(&p);
    } else {
        // The caller's own scope; never "everything".
        try p.object("caller", common.callerObject(ctx));
    }
    return common.callOk(ctx, "notification.clear", &p);
}

// ----- list-notifications -----

/// `YYYY-MM-DDTHH:MM:SSZ` for epoch seconds (negative clamps to 1970).
pub fn writeIso8601(w: *std.Io.Writer, epoch_s: i64) std.Io.Writer.Error!void {
    const secs: u64 = @intCast(@max(epoch_s, 0));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year, md.month.numeric(), @as(u32, md.day_index) + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

/// `created_at` as ISO 8601: strings pass through; numbers are epoch
/// seconds, or milliseconds when larger than 1e11.
pub fn writeCreatedAt(w: *std.Io.Writer, v: ?std.json.Value) std.Io.Writer.Error!void {
    const x = v orelse return;
    switch (x) {
        .string => |s| try writeLineSafe(w, s),
        .integer => |i| try writeIso8601(w, if (i > 100_000_000_000) @divFloor(i, 1000) else i),
        .float => |f| {
            if (!std.math.isFinite(f) or @abs(f) > 1e15) return;
            const secs: i64 = @intFromFloat(if (f > 1e11) f / 1000.0 else f);
            try writeIso8601(w, secs);
        },
        else => {},
    }
}

/// Writes `s` with line breaks turned into spaces so one record stays on
/// one line.
pub fn writeLineSafe(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| try w.writeByte(if (c == '\n' or c == '\r') ' ' else c);
}

/// One v1 `list_notifications` line:
/// `<index>:<uuid>|<workspace>|<surface|none>|<read|unread>|<title>|<subtitle>|<body>|<created_at>|<tab_title>`.
pub fn writeNotificationLine(w: *std.Io.Writer, index: usize, n: std.json.Value) std.Io.Writer.Error!void {
    try w.print("{d}:", .{index});
    try writeLineSafe(w, common.strField(n, "id") orelse "");
    try w.writeByte('|');
    try writeLineSafe(w, common.strField(n, "workspace_id") orelse common.strField(n, "workspace_ref") orelse "");
    try w.writeByte('|');
    try writeLineSafe(w, common.strField(n, "surface_id") orelse common.strField(n, "surface_ref") orelse "none");
    try w.writeAll(if (common.boolField(n, "is_read") orelse false) "|read|" else "|unread|");
    for ([_][]const u8{ "title", "subtitle", "body" }) |k| {
        try writeLineSafe(w, common.strField(n, k) orelse "");
        try w.writeByte('|');
    }
    try writeCreatedAt(w, common.field(n, "created_at"));
    try w.writeByte('|');
    try writeLineSafe(w, common.strField(n, "tab_title") orelse "");
    try w.writeByte('\n');
}

/// The cmux `--json` array: `{id, workspace_id, surface_id|null, is_read,
/// title, subtitle, body, created_at|null, tab_title|null}` per record.
pub fn listJson(arena: std.mem.Allocator, items: []const std.json.Value) !std.json.Value {
    var arr = std.json.Array.init(arena);
    for (items) |n| {
        var o = std.json.ObjectMap.init(arena);
        const keys = [_][]const u8{ "id", "workspace_id", "surface_id", "is_read", "title", "subtitle", "body", "created_at", "tab_title" };
        for (keys) |k| {
            const v = common.field(n, k) orelse if (std.mem.eql(u8, k, "is_read"))
                std.json.Value{ .bool = false }
            else if (std.mem.eql(u8, k, "title") or std.mem.eql(u8, k, "subtitle") or std.mem.eql(u8, k, "body"))
                std.json.Value{ .string = "" }
            else
                std.json.Value.null;
            try o.put(k, v);
        }
        try arr.append(.{ .object = o });
    }
    return .{ .array = arr };
}

fn runList(ctx: *Ctx) !u8 {
    if (noArgs(ctx, "list-notifications")) |c| return c;
    const r = (try common.request(ctx, "notification.list", null)) orelse return output.exit.runtime;
    const items = common.firstArray(r, &.{"notifications"});
    if (ctx.json()) {
        try output.writeJson(ctx.out, try listJson(ctx.arena, items));
        return output.exit.ok;
    }
    if (items.len == 0) {
        try ctx.out.writeAll("No notifications\n");
        return output.exit.ok;
    }
    for (items, 0..) |n, i| try writeNotificationLine(ctx.out, i, n);
    return output.exit.ok;
}

// ----- dismiss / mark read / open -----

const dismiss_opts = [_]Opt{ .{ .name = "--id" }, .{ .name = "--all-read", .kind = .flag } };

fn runDismiss(ctx: *Ctx) !u8 {
    const cmd = "dismiss-notification";
    var code: u8 = 0;
    const s = (try common.scanOrReport(ctx, cmd, &dismiss_opts, .{}, &code)) orelse return code;
    if (s.positionals.len > 1) return common.reportProblem(ctx, cmd, .{ .unexpected = s.positionals[1..] });
    // A lone positional id is accepted like `--id` (older usage line).
    const id = s.get("--id") orelse (if (s.positionals.len == 1) s.positionals[0] else null);
    const all_read = s.has("--all-read");
    if ((id != null) == all_read) return ctx.usageError("dismiss-notification requires exactly one of --id or --all-read", .{});
    var p = Params.init(ctx.arena);
    if (id) |text| {
        if (!try idParam(ctx, cmd, text, &p, &code)) return code;
    } else try p.boolean("all_read", true);
    return common.callOk(ctx, "notification.dismiss", &p);
}

const mark_read_opts = [_]Opt{
    .{ .name = "--id" },
    .{ .name = "--all", .kind = .flag },
    .{ .name = "--workspace" },
    .{ .name = "--surface" },
    .{ .name = "--window" },
};

fn runMarkRead(ctx: *Ctx) !u8 {
    const cmd = "mark-notification-read";
    var code: u8 = 0;
    const s = (try common.scanOrReport(ctx, cmd, &mark_read_opts, .{ .positionals = false }, &code)) orelse return code;
    const n = @as(u8, @intFromBool(s.has("--id"))) + @intFromBool(s.has("--workspace")) + @intFromBool(s.has("--all"));
    if (n != 1) {
        if (n == 0 and s.has("--surface")) return ctx.usageError("--surface requires --workspace", .{});
        return ctx.usageError("mark-notification-read requires exactly one selector: --id, --workspace, or --all", .{});
    }
    if (s.has("--surface") and !s.has("--workspace")) return ctx.usageError("--surface requires --workspace", .{});
    var p = Params.init(ctx.arena);
    if (s.get("--id")) |text| {
        if (!try idParam(ctx, cmd, text, &p, &code)) return code;
    } else if (s.has("--all")) {
        try p.boolean("all", true);
    } else {
        const t = common.resolveTarget(ctx, s, .{ .env_workspace = false }, &code) orelse return code;
        try t.put(&p);
    }
    return common.callOk(ctx, "notification.mark_read", &p);
}

fn runOpen(ctx: *Ctx) !u8 {
    const cmd = "open-notification";
    var code: u8 = 0;
    const s = (try common.scanOrReport(ctx, cmd, &.{.{ .name = "--id" }}, .{ .positionals = false }, &code)) orelse return code;
    const text = s.get("--id") orelse return ctx.usageError("open-notification requires --id", .{});
    var p = Params.init(ctx.arena);
    if (!try idParam(ctx, cmd, text, &p, &code)) return code;
    try common.grantForeground(ctx, &p);
    const r = (try common.request(ctx, "notification.open", &p)) orelse return output.exit.runtime;
    if (ctx.json()) return common.printOk(ctx, r);
    try common.printOpened(ctx, r);
    return output.exit.ok;
}

// ----- jumps -----

/// `OK <workspace> <surface>` when something opened, else `none_text`
/// (exit 0 either way; `--json` shows `opened`).
fn printJump(ctx: *Ctx, r: std.json.Value, none_text: []const u8) !u8 {
    if (ctx.json()) return common.printOk(ctx, r);
    if (common.boolField(r, "opened") orelse true) {
        try common.printOpened(ctx, r);
    } else {
        try ctx.out.writeAll(none_text);
        try ctx.out.writeByte('\n');
    }
    return output.exit.ok;
}

fn runJumpToUnread(ctx: *Ctx) !u8 {
    if (noArgs(ctx, "jump-to-unread")) |c| return c;
    var p = Params.init(ctx.arena);
    try common.grantForeground(ctx, &p);
    const r = (try common.request(ctx, "notification.jump_to_unread", &p)) orelse return output.exit.runtime;
    return printJump(ctx, r, "No unread notifications");
}

fn runJumpToLastPrompt(ctx: *Ctx) !u8 {
    if (noArgs(ctx, "jump-to-last-prompt")) |c| return c;
    var p = Params.init(ctx.arena);
    // A focus intent through `focus:true` (Appendix B).
    try p.boolean("focus", true);
    try common.grantForeground(ctx, &p);
    const r = (try common.request(ctx, "surface.jump_to_last_prompt", &p)) orelse return output.exit.runtime;
    return printJump(ctx, r, "No agent prompt to jump to");
}

// ----- clear-notifications -----

const clear_opts = target_opts ++ [_]Opt{.{ .name = "--panel", .canonical = "--surface" }};

fn runClear(ctx: *Ctx) !u8 {
    const cmd = "clear-notifications";
    var code: u8 = 0;
    const s = (try common.scanOrReport(ctx, cmd, &clear_opts, .{ .positionals = false }, &code)) orelse return code;
    // No flags: everything, or the caller's workspace inside a terminal.
    const t = common.resolveTarget(ctx, s, .{ .env_workspace = true }, &code) orelse return code;
    if (t.surface != null and t.workspace == null and t.window == null)
        return ctx.usageError("clear-notifications --surface requires a workspace or window context", .{});
    var p = Params.init(ctx.arena);
    try t.put(&p);
    return common.callOk(ctx, "notification.clear", &p);
}

// ----- app focus test overrides -----

pub const app_focus_values = [_][]const u8{ "active", "inactive", "clear" };

fn runSetAppFocus(ctx: *Ctx) !u8 {
    const a = ctx.args();
    if (a.len == 0) return ctx.usageError("set-app-focus requires a value", .{});
    if (a.len > 1) {
        const joined = try std.mem.join(ctx.arena, " ", a[1..]);
        return ctx.usageError("set-app-focus: unexpected arguments: {s}", .{joined});
    }
    const v = std.mem.trim(u8, a[0], " \t");
    const value = for (app_focus_values) |x| {
        if (std.ascii.eqlIgnoreCase(x, v)) break x;
    } else return ctx.usageError("set-app-focus: invalid value '{s}' (expected active, inactive or clear)", .{a[0]});
    var p = Params.init(ctx.arena);
    try p.str("state", value);
    return common.callOk(ctx, "app.focus_override.set", &p);
}

fn runSimulateAppActive(ctx: *Ctx) !u8 {
    if (noArgs(ctx, "simulate-app-active")) |c| return c;
    return common.callOk(ctx, "app.simulate_active", null);
}

// ----- trigger-flash -----

const flash_opts = clear_opts;

fn runTriggerFlash(ctx: *Ctx) !u8 {
    var code: u8 = 0;
    const s = (try common.scanOrReport(ctx, "trigger-flash", &flash_opts, .{ .positionals = false }, &code)) orelse return code;
    const t = common.resolveTarget(ctx, s, .{ .env_workspace = true, .env_surface = true }, &code) orelse return code;
    var p = Params.init(ctx.arena);
    try t.put(&p);
    return common.callOk(ctx, "surface.trigger_flash", &p);
}

// ----- feed -----

/// cmux keeps Feed history in `~/.cmuxterm/workstream.jsonl`; wmux uses the
/// same file under the user profile.
pub fn feedHistoryPath(ctx: *Ctx) !?[]const u8 {
    const style = proto.paths.Style.native;
    const order: []const []const u8 = if (style == .windows) &.{ "USERPROFILE", "HOME" } else &.{ "HOME", "USERPROFILE" };
    for (order) |n| if (ctx.env.getNonEmpty(n)) |home| {
        return try proto.paths.join(ctx.arena, style, &.{ home, ".cmuxterm", "workstream.jsonl" });
    };
    return null;
}

const feed_usage = "Usage: cmux feed tui [--opentui|--legacy]\n       cmux feed clear [--yes|-y]";

fn runFeed(ctx: *Ctx) !u8 {
    const a = ctx.args();
    if (a.len == 0) {
        const code = ctx.usageError("feed requires a subcommand: tui or clear", .{});
        _ = common.runtimeText(ctx, feed_usage);
        return code;
    }
    if (std.mem.eql(u8, a[0], "clear")) return feedClear(ctx, a[1..]);
    if (std.mem.eql(u8, a[0], "tui")) return common.runtimeText(ctx, "cmux: 'feed tui' is not available in this build of wmux yet");
    return ctx.usageError("unknown feed subcommand '{s}'; expected tui or clear", .{a[0]});
}

fn feedClear(ctx: *Ctx, rest: []const []const u8) !u8 {
    var yes = false;
    var bad: std.ArrayList([]const u8) = .empty;
    for (rest) |x| {
        if (std.mem.eql(u8, x, "--yes") or std.mem.eql(u8, x, "-y")) yes = true else try bad.append(ctx.arena, x);
    }
    if (bad.items.len > 0) return common.reportProblem(ctx, "feed clear", .{ .unexpected = bad.items });
    const path = (try feedHistoryPath(ctx)) orelse return ctx.runtimeError("cannot locate the home directory (USERPROFILE and HOME are unset)", .{});
    if (!ctx.platform.pathExists(path)) {
        try ctx.out.print("No Feed history to clear ({s} does not exist).\n", .{path});
        return output.exit.ok;
    }
    if (!yes) {
        try ctx.out.print("This will permanently delete {s}. Proceed? [y/N] ", .{path});
        try ctx.out.flush();
        const answer = ctx.platform.readStdin(ctx.arena, 64 * 1024) catch "";
        const line = std.mem.trimLeft(u8, answer, " \t");
        if (line.len == 0 or (line[0] != 'y' and line[0] != 'Y')) {
            try ctx.out.writeAll("Aborted.\n");
            return output.exit.ok;
        }
    }
    common.files.delete(path) catch |err| return ctx.runtimeError("cannot delete {s}: {s}", .{ path, @errorName(err) });
    try ctx.out.print("Cleared {s}\n", .{path});
    return output.exit.ok;
}

test {
    _ = common;
    _ = @import("notify/notify_tests.zig");
}
