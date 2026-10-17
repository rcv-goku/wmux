//! CLI command family `pane_surface` (Appendix C).
//! new-split, new-pane, new-surface, close-surface, list-panes, list-pane-surfaces,
//! list-panels, focus-pane, focus-panel, move-surface, reorder-surface, split-off,
//! drag-surface-to-split, tab-action, rename-tab, move-tab-to-new-workspace
//! (detach-tab), resize-pane, swap-pane, break-pane, join-pane, last-pane (W2-2).
//! trigger-flash (Appendix C: here, W2-7) ships in notify.zig with WP
//! CLI-fam-notify, which owns it in this program.
//!
//! Every command maps its flags onto one v2 method (`surface.*`, `pane.*`,
//! `tab.action`), defaults its targets to the caller (ADR-4.6, ps_common.zig)
//! and prints cmux's text (`OK surface:3 pane:2 workspace:1`, list rows) or
//! the id-formatted result with `--json`. Creation and move commands never
//! take focus unless `--focus true` is given (cmux default for new-split and
//! split-off; G4).

const std = @import("std");
const command = @import("../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../output.zig");
const catalog = @import("../help/catalog.zig");
const ps = @import("ps_common.zig");
const Opts = ps.Opts;
const Params = ps.Params;

/// The catalog usage line of `name` (help and usage errors share it).
pub fn usageOf(comptime name: []const u8) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        for (catalog.entries) |e| if (std.mem.eql(u8, e.name, name)) break :blk e.usage;
        @compileError("no catalog entry for " ++ name);
    };
}

fn spec(comptime name: []const u8, comptime group: command.Group, comptime run: command.RunFn) CommandSpec {
    return .{ .name = name, .group = group, .usage = usageOf(name), .help = @embedFile("../help/" ++ name ++ ".txt"), .run = run };
}

/// `CommandSpec` entries (ADR-4.9).
pub const commands = [_]CommandSpec{
    spec("new-split", .navigate, runNewSplit),
    spec("new-pane", .navigate, runNewPane),
    spec("new-surface", .navigate, runNewSurface),
    spec("close-surface", .navigate, runCloseSurface),
    spec("list-panes", .navigate, runListPanes),
    spec("list-pane-surfaces", .navigate, runListPaneSurfaces),
    spec("list-panels", .navigate, runListPanels),
    spec("focus-pane", .navigate, runFocusPane),
    spec("focus-panel", .navigate, runFocusPanel),
    spec("move-surface", .navigate, runMoveSurface),
    spec("reorder-surface", .navigate, runReorderSurface),
    spec("split-off", .navigate, runSplitOff),
    spec("drag-surface-to-split", .navigate, runDragToSplit),
    spec("tab-action", .navigate, runTabAction),
    spec("rename-tab", .navigate, runRenameTab),
    blk: {
        var s = spec("move-tab-to-new-workspace", .navigate, runMoveTabToNewWorkspace);
        s.aliases = &.{"detach-tab"};
        break :blk s;
    },
    spec("resize-pane", .navigate, runResizePane),
    spec("swap-pane", .navigate, runSwapPane),
    spec("break-pane", .navigate, runBreakPane),
    spec("join-pane", .navigate, runJoinPane),
    spec("last-pane", .navigate, runLastPane),
};

pub const directions = [_][]const u8{ "left", "right", "up", "down" };

fn isDirection(s: []const u8) bool {
    for (directions) |d| if (std.mem.eql(u8, d, s)) return true;
    return false;
}

fn unexpected(ctx: *Ctx, usage: []const u8, arg: []const u8) u8 {
    return ps.usageWithLine(ctx, usage, "unexpected argument '{s}'", .{arg});
}

/// The required direction positional (`new-split right`).
fn direction(ctx: *Ctx, usage: []const u8, o: Opts, verb: []const u8) ?[]const u8 {
    if (o.positionals.len == 0) {
        _ = ps.usageWithLine(ctx, usage, "{s} requires a direction: left, right, up or down", .{verb});
        return null;
    }
    if (o.positionals.len > 1) {
        _ = unexpected(ctx, usage, o.positionals[1]);
        return null;
    }
    const d = o.positionals[0];
    if (!isDirection(d)) {
        _ = ps.usageWithLine(ctx, usage, "invalid direction '{s}' (expected left, right, up or down)", .{d});
        return null;
    }
    return d;
}

/// `--command <text>`: `initial_input` with one trailing Enter; blank text
/// sends nothing (cmux "Initial terminal command").
fn addInitialInput(ctx: *Ctx, p: *Params, o: Opts) !void {
    const text = o.get(&.{"--command"}) orelse return;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
    try p.str("initial_input", try std.mem.concat(ctx.arena, u8, &.{ text, "\r" }));
}

/// A non-negative integer flag value; prints the usage error and returns
/// error.Usage on a bad value.
fn intFlag(ctx: *Ctx, usage: []const u8, o: Opts, name: []const u8, min: i64) !?i64 {
    const text = o.get(&.{name}) orelse return null;
    const n = std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t"), 10) catch {
        _ = ps.usageWithLine(ctx, usage, "{s} must be an integer", .{name});
        return error.Usage;
    };
    if (n < min) {
        _ = ps.usageWithLine(ctx, usage, "{s} must be at least {d}", .{ name, min });
        return error.Usage;
    }
    return n;
}

/// The required surface flag (`--surface`, `--panel` or `--tab`).
fn requiredSurface(ctx: *Ctx, usage: []const u8, o: Opts, flags: []const []const u8, verb: []const u8, flag_hint: []const u8) ?[]const u8 {
    if (o.get(flags)) |s| return s;
    _ = ps.usageWithLine(ctx, usage, "{s} requires {s} <id|ref|index>", .{ verb, flag_hint });
    return null;
}

// ----- creation -----

const split_usage = usageOf("new-split");

fn runNewSplit(ctx: *Ctx) !u8 {
    // `--pane` is the legacy `+split <dir> --pane P` spelling (ADR-4.11).
    const o = (try ps.parseArgs(ctx, split_usage, .{
        .values = &.{ "--workspace", "--surface", "--panel", "--window", "--command", "--pane" },
        .focus = true,
    })) orelse return output.exit.usage;
    const dir = direction(ctx, split_usage, o, "new-split") orelse return output.exit.usage;
    var p = Params.init(ctx.arena);
    try p.str("direction", dir);
    if (!try ps.addTargets(ctx, &p, o, .{ .surface_flags = &.{ "--surface", "--panel" }, .pane = true })) return output.exit.usage;
    try addInitialInput(ctx, &p, o);
    try p.boolean("focus", o.focus orelse false);
    return ps.callRender(ctx, "surface.split", &p, ps.renderOk);
}

const pane_usage = usageOf("new-pane");

fn checkType(ctx: *Ctx, usage: []const u8, o: Opts) ?[]const u8 {
    const t = o.get(&.{"--type"}) orelse return "terminal";
    if (std.mem.eql(u8, t, "terminal") or std.mem.eql(u8, t, "browser")) {
        if (std.mem.eql(u8, t, "browser") and o.get(&.{"--command"}) != null) {
            _ = ps.usageWithLine(ctx, usage, "--command is only supported for terminal surfaces", .{});
            return null;
        }
        return t;
    }
    _ = ps.usageWithLine(ctx, usage, "--type must be terminal or browser", .{});
    return null;
}

fn runNewPane(ctx: *Ctx) !u8 {
    const o = (try ps.parseArgs(ctx, pane_usage, .{
        .values = &.{ "--type", "--direction", "--placement", "--workspace", "--window", "--url", "--profile", "--command" },
        .focus = true,
    })) orelse return output.exit.usage;
    if (o.positionals.len > 0) return unexpected(ctx, pane_usage, o.positionals[0]);
    const t = checkType(ctx, pane_usage, o) orelse return output.exit.usage;
    const dir = o.get(&.{"--direction"}) orelse "right";
    if (!isDirection(dir)) return ps.usageWithLine(ctx, pane_usage, "invalid direction '{s}' (expected left, right, up or down)", .{dir});
    var p = Params.init(ctx.arena);
    try p.str("type", t);
    try p.str("direction", dir);
    if (o.get(&.{"--placement"})) |pl| {
        if (!(std.mem.eql(u8, pl, "workspace") or std.mem.eql(u8, pl, "dock")))
            return ps.usageWithLine(ctx, pane_usage, "--placement must be workspace or dock", .{});
        try p.str("placement", pl);
    }
    if (!try ps.addTargets(ctx, &p, o, .{ .surface_flags = &.{} })) return output.exit.usage;
    if (o.get(&.{"--url"})) |u| try p.str("url", u);
    if (o.get(&.{"--profile"})) |pr| try p.str("profile", pr);
    try addInitialInput(ctx, &p, o);
    try p.boolean("focus", o.focus orelse false);
    return ps.callRender(ctx, "pane.create", &p, ps.renderOk);
}

const surface_usage = usageOf("new-surface");

fn runNewSurface(ctx: *Ctx) !u8 {
    const o = (try ps.parseArgs(ctx, surface_usage, .{
        .values = &.{ "--pane", "--type", "--workspace", "--window", "--url", "--command" },
        .focus = true,
    })) orelse return output.exit.usage;
    if (o.positionals.len > 0) return unexpected(ctx, surface_usage, o.positionals[0]);
    const t = checkType(ctx, surface_usage, o) orelse return output.exit.usage;
    var p = Params.init(ctx.arena);
    try p.str("type", t);
    if (!try ps.addTargets(ctx, &p, o, .{ .surface_flags = &.{}, .pane = true })) return output.exit.usage;
    if (o.get(&.{"--url"})) |u| try p.str("url", u);
    try addInitialInput(ctx, &p, o);
    try p.boolean("focus", o.focus orelse false);
    return ps.callRender(ctx, "surface.create", &p, ps.renderOk);
}

/// split-off and drag-surface-to-split: `--surface <h> <direction>`.
fn surfaceToSplit(ctx: *Ctx, comptime name: []const u8, method: []const u8) !u8 {
    const usage = usageOf(name);
    const o = (try ps.parseArgs(ctx, usage, .{
        .values = &.{ "--surface", "--panel", "--workspace", "--window" },
        .focus = true,
    })) orelse return output.exit.usage;
    if (requiredSurface(ctx, usage, o, &.{ "--surface", "--panel" }, name, "--surface") == null) return output.exit.usage;
    const dir = direction(ctx, usage, o, name) orelse return output.exit.usage;
    var p = Params.init(ctx.arena);
    if (!try ps.addTargets(ctx, &p, o, .{ .surface_flags = &.{ "--surface", "--panel" } })) return output.exit.usage;
    try p.str("direction", dir);
    try p.boolean("focus", o.focus orelse false);
    return ps.callRender(ctx, method, &p, ps.renderOk);
}

fn runSplitOff(ctx: *Ctx) !u8 {
    return surfaceToSplit(ctx, "split-off", "surface.split_off");
}

fn runDragToSplit(ctx: *Ctx) !u8 {
    return surfaceToSplit(ctx, "drag-surface-to-split", "surface.drag_to_split");
}

// ----- close, lists, focus -----

fn runCloseSurface(ctx: *Ctx) !u8 {
    const usage = usageOf("close-surface");
    // `--tab`, `--pane` and a positional handle are the legacy
    // `+tab close <index> [--pane P]` spellings (ADR-4.11).
    const flags: []const []const u8 = &.{ "--surface", "--panel", "--tab" };
    const o = (try ps.parseArgs(ctx, usage, .{ .values = &.{ "--surface", "--panel", "--tab", "--pane", "--workspace", "--window" } })) orelse return output.exit.usage;
    var opts = o;
    if (o.get(flags) == null and o.positionals.len == 1) {
        opts.values = try std.mem.concat(ctx.arena, ps.Opt, &.{ o.values, &.{.{ .name = "--surface", .value = o.positionals[0] }} });
        opts.positionals = &.{};
    }
    if (opts.positionals.len > 0) return unexpected(ctx, usage, opts.positionals[0]);
    var p = Params.init(ctx.arena);
    if (!try ps.addTargets(ctx, &p, opts, .{ .surface_flags = flags, .pane = true })) return output.exit.usage;
    return ps.callRender(ctx, "surface.close", &p, ps.renderOk);
}

/// list-panes, list-pane-surfaces, list-panels: selectors only.
fn listCommand(ctx: *Ctx, comptime name: []const u8, method: []const u8, pane: bool, render: ps.RenderFn) !u8 {
    const usage = usageOf(name);
    const values: []const []const u8 = if (pane) &.{ "--workspace", "--pane", "--window" } else &.{ "--workspace", "--window" };
    const o = (try ps.parseArgs(ctx, usage, .{ .values = values })) orelse return output.exit.usage;
    if (o.positionals.len > 0) return unexpected(ctx, usage, o.positionals[0]);
    var p = Params.init(ctx.arena);
    if (!try ps.addTargets(ctx, &p, o, .{ .surface_flags = &.{}, .pane = pane })) return output.exit.usage;
    return ps.callRender(ctx, method, &p, render);
}

fn runListPanes(ctx: *Ctx) !u8 {
    return listCommand(ctx, "list-panes", "pane.list", false, renderPanes);
}

fn runListPaneSurfaces(ctx: *Ctx) !u8 {
    return listCommand(ctx, "list-pane-surfaces", "pane.surfaces", true, renderPaneSurfaces);
}

fn runListPanels(ctx: *Ctx) !u8 {
    return listCommand(ctx, "list-panels", "surface.list", false, renderPanels);
}

/// `* pane:2  [3 surfaces]  [dock:<scope>]  [focused]`; the marker column
/// is `*` for the focused pane.
pub fn renderPanes(ctx: *Ctx, result: std.json.Value) anyerror!void {
    const w = ctx.out;
    const panes = ps.getArr(result, "panes");
    if (panes.len == 0) return w.writeAll("No panes\n");
    for (panes) |pane| {
        const focused = ps.getBool(pane, "focused");
        try w.writeAll(if (focused) "* " else "  ");
        _ = try ps.writeHandle(ctx, w, pane, null, false);
        const n: u64 = if (ps.getNum(pane, "surface_count")) |c| @intCast(@max(ps.toInt(c), 0)) else ps.getArr(pane, "surface_ids").len;
        try w.print("  [{d} {s}]", .{ n, if (n == 1) "surface" else "surfaces" });
        if (ps.getStr(pane, "dock")) |d| {
            try w.writeAll("  [dock:");
            try ps.writeClean(w, d);
            try w.writeByte(']');
        }
        if (focused) try w.writeAll("  [focused]");
        try w.writeByte('\n');
    }
}

fn surfaceSelected(s: std.json.Value) bool {
    return ps.getBool(s, "selected_in_pane") or ps.getBool(s, "selected");
}

/// `* surface:4  <title>  [selected]` for the pane's surfaces.
pub fn renderPaneSurfaces(ctx: *Ctx, result: std.json.Value) anyerror!void {
    const w = ctx.out;
    const surfaces = ps.getArr(result, "surfaces");
    if (surfaces.len == 0) return w.writeAll("No surfaces\n");
    for (surfaces) |s| {
        const selected = surfaceSelected(s);
        try w.writeAll(if (selected) "* " else "  ");
        _ = try ps.writeHandle(ctx, w, s, null, false);
        try w.writeAll("  ");
        try ps.writeClean(w, ps.getStr(s, "title") orelse "");
        if (selected) try w.writeAll("  [selected]");
        try w.writeByte('\n');
    }
}

/// `* surface:4  pane:2  <type>  <title>  [focused]` for every surface of
/// the workspace (compatibility listing).
pub fn renderPanels(ctx: *Ctx, result: std.json.Value) anyerror!void {
    const w = ctx.out;
    const surfaces = ps.getArr(result, "surfaces");
    if (surfaces.len == 0) return w.writeAll("No surfaces\n");
    for (surfaces) |s| {
        const focused = ps.getBool(s, "focused");
        try w.writeAll(if (focused) "* " else "  ");
        _ = try ps.writeHandle(ctx, w, s, null, false);
        var aw: std.Io.Writer.Allocating = .init(ctx.arena);
        if (try ps.writeHandle(ctx, &aw.writer, s, "pane", false)) try w.print("  {s}", .{aw.written()});
        try w.print("  {s}  ", .{ps.getStr(s, "type") orelse "terminal"});
        try ps.writeClean(w, ps.getStr(s, "title") orelse "");
        if (focused) try w.writeAll("  [focused]");
        try w.writeByte('\n');
    }
}

fn runFocusPane(ctx: *Ctx) !u8 {
    const usage = usageOf("focus-pane");
    const o = (try ps.parseArgs(ctx, usage, .{ .values = &.{ "--pane", "--workspace", "--window" } })) orelse return output.exit.usage;
    // `focus-pane pane:2` is accepted like `--pane pane:2`.
    var opts = o;
    if (o.get(&.{"--pane"}) == null and o.positionals.len == 1) {
        opts.values = try std.mem.concat(ctx.arena, ps.Opt, &.{ o.values, &.{.{ .name = "--pane", .value = o.positionals[0] }} });
        opts.positionals = &.{};
    }
    if (opts.positionals.len > 0) return unexpected(ctx, usage, opts.positionals[0]);
    if (opts.get(&.{"--pane"}) == null) return ps.usageWithLine(ctx, usage, "focus-pane requires --pane <id|ref|index>", .{});
    var p = Params.init(ctx.arena);
    if (!try ps.addTargets(ctx, &p, opts, .{ .surface_flags = &.{}, .pane = true })) return output.exit.usage;
    return ps.callRender(ctx, "pane.focus", &p, ps.renderOk);
}

fn runFocusPanel(ctx: *Ctx) !u8 {
    const usage = usageOf("focus-panel");
    // `--pane` is the legacy `+tab select <index> --pane P` / `+surface focus
    // --pane P [--tab T]` spelling (ADR-4.11); alone it names the pane's
    // selected surface.
    const o = (try ps.parseArgs(ctx, usage, .{ .values = &.{ "--panel", "--surface", "--tab", "--pane", "--workspace", "--window" } })) orelse return output.exit.usage;
    var opts = o;
    if (o.get(&.{ "--panel", "--surface", "--tab" }) == null and o.positionals.len == 1) {
        opts.values = try std.mem.concat(ctx.arena, ps.Opt, &.{ o.values, &.{.{ .name = "--panel", .value = o.positionals[0] }} });
        opts.positionals = &.{};
    }
    if (opts.positionals.len > 0) return unexpected(ctx, usage, opts.positionals[0]);
    const flags: []const []const u8 = &.{ "--panel", "--surface", "--tab" };
    if (opts.get(&.{"--pane"}) == null and requiredSurface(ctx, usage, opts, flags, "focus-panel", "--panel") == null) return output.exit.usage;
    var p = Params.init(ctx.arena);
    if (!try ps.addTargets(ctx, &p, opts, .{ .surface_flags = flags, .pane = true })) return output.exit.usage;
    return ps.callRender(ctx, "surface.focus", &p, ps.renderOk);
}

// ----- move and reorder -----

fn runMoveSurface(ctx: *Ctx) !u8 {
    const usage = usageOf("move-surface");
    const o = (try ps.parseArgs(ctx, usage, .{
        .values = &.{ "--surface", "--panel", "--pane", "--workspace", "--window", "--index" },
        .focus = true,
    })) orelse return output.exit.usage;
    if (o.positionals.len > 0) return unexpected(ctx, usage, o.positionals[0]);
    const sf = requiredSurface(ctx, usage, o, &.{ "--surface", "--panel" }, "move-surface", "--surface") orelse return output.exit.usage;
    const index = intFlag(ctx, usage, o, "--index", 0) catch return output.exit.usage;
    const pane = o.get(&.{"--pane"});
    const ws = o.get(&.{"--workspace"});
    const win = ps.windowText(ctx, o);
    if (pane == null and ws == null and win == null and index == null)
        return ps.usageWithLine(ctx, usage, "move-surface requires --pane, --workspace, --window or --index", .{});
    // The surface is explicit; the other selectors name the destination.
    var p = Params.init(ctx.arena);
    if (!try ps.putHandle(ctx, &p, "surface_id", .surface, sf)) return output.exit.usage;
    if (pane) |x| if (!try ps.putHandle(ctx, &p, "pane_id", .pane, x)) return output.exit.usage;
    if (ws) |x| if (!try ps.putHandle(ctx, &p, "workspace_id", .workspace, x)) return output.exit.usage;
    if (win) |x| if (!try ps.putHandle(ctx, &p, "window_id", .window, x)) return output.exit.usage;
    if (index) |n| try p.int("index", n);
    try p.boolean("focus", o.focus orelse false);
    return ps.callRender(ctx, "surface.move", &p, ps.renderOk);
}

fn runReorderSurface(ctx: *Ctx) !u8 {
    const usage = usageOf("reorder-surface");
    const o = (try ps.parseArgs(ctx, usage, .{ .values = &.{ "--surface", "--panel", "--index", "--workspace", "--window" } })) orelse return output.exit.usage;
    if (o.positionals.len > 0) return unexpected(ctx, usage, o.positionals[0]);
    if (requiredSurface(ctx, usage, o, &.{ "--surface", "--panel" }, "reorder-surface", "--surface") == null) return output.exit.usage;
    const index = (intFlag(ctx, usage, o, "--index", 0) catch return output.exit.usage) orelse
        return ps.usageWithLine(ctx, usage, "reorder-surface requires --index <n>", .{});
    var p = Params.init(ctx.arena);
    if (!try ps.addTargets(ctx, &p, o, .{ .surface_flags = &.{ "--surface", "--panel" } })) return output.exit.usage;
    try p.int("index", index);
    return ps.callRender(ctx, "surface.reorder", &p, ps.renderOk);
}

// ----- tab actions -----

/// cmux tab context-menu action names (`tab.action`).
pub const tab_actions = [_][]const u8{
    "rename",             "clear-name",        "close-left",            "close-right",           "close-others",
    "new-terminal-right", "new-browser-right", "reload",                "duplicate",             "pin",
    "unpin",              "mark-unread",       "move-to-new-workspace", "toggle-full-width-tab",
};

fn isTabAction(s: []const u8) bool {
    for (tab_actions) |a| if (std.mem.eql(u8, a, s)) return true;
    return false;
}

const tab_flags: []const []const u8 = &.{ "--tab", "--surface", "--panel" };

/// Shared tail of tab-action, rename-tab and move-tab-to-new-workspace.
fn tabActionCall(ctx: *Ctx, o: Opts, action: []const u8, title: ?[]const u8, render: ps.RenderFn) !u8 {
    var p = Params.init(ctx.arena);
    try p.str("action", action);
    if (!try ps.addTargets(ctx, &p, o, .{ .surface_flags = tab_flags })) return output.exit.usage;
    if (title) |t| try p.str("title", t);
    if (o.get(&.{"--url"})) |u| try p.str("url", u);
    if (o.focus) |f| {
        try p.boolean("focus", f);
    } else if (std.mem.eql(u8, action, "move-to-new-workspace")) try p.boolean("focus", false);
    if (o.has("--force")) try p.boolean("force", true);
    return ps.callRender(ctx, "tab.action", &p, render);
}

const tab_action_usage = usageOf("tab-action");

fn runTabAction(ctx: *Ctx) !u8 {
    const o = (try ps.parseArgs(ctx, tab_action_usage, .{
        .values = &.{ "--action", "--tab", "--surface", "--panel", "--workspace", "--window", "--title", "--url" },
        .bools = &.{"--force"},
        .focus = true,
    })) orelse return output.exit.usage;
    var rest = o.positionals;
    const action = o.get(&.{"--action"}) orelse blk: {
        if (rest.len == 0) return ps.usageWithLine(ctx, tab_action_usage, "tab-action requires --action <name>", .{});
        const a = rest[0];
        rest = rest[1..];
        break :blk a;
    };
    if (!isTabAction(action)) {
        const list = try std.mem.join(ctx.arena, ", ", &tab_actions);
        return ps.usageWithLine(ctx, tab_action_usage, "unknown tab action '{s}'; expected one of: {s}", .{ action, list });
    }
    var title: ?[]const u8 = null;
    if (std.mem.eql(u8, action, "rename")) {
        title = o.get(&.{"--title"}) orelse if (rest.len > 0) try std.mem.join(ctx.arena, " ", rest) else return ps.usageWithLine(ctx, tab_action_usage, "tab-action rename requires --title <text> or trailing text", .{});
        rest = &.{};
    }
    if (rest.len > 0) return unexpected(ctx, tab_action_usage, rest[0]);
    return tabActionCall(ctx, o, action, title, renderTabAction);
}

/// `OK surface:3 ...`; toggle-full-width-tab adds the resulting mode.
fn renderTabAction(ctx: *Ctx, result: std.json.Value) anyerror!void {
    if (ps.get(result, "full_width")) |v| if (v == .bool) {
        var aw: std.Io.Writer.Allocating = .init(ctx.arena);
        const saved = ctx.out;
        ctx.out = &aw.writer;
        defer ctx.out = saved;
        try ps.writeOk(ctx, result);
        const line = std.mem.trimRight(u8, aw.written(), "\n");
        try saved.print("{s} full_width={s}\n", .{ line, if (v.bool) "true" else "false" });
        return;
    };
    try ps.writeOk(ctx, result);
}

fn runRenameTab(ctx: *Ctx) !u8 {
    const usage = usageOf("rename-tab");
    const o = (try ps.parseArgs(ctx, usage, .{ .values = &.{ "--tab", "--surface", "--panel", "--workspace", "--window", "--title" } })) orelse return output.exit.usage;
    const title = o.get(&.{"--title"}) orelse if (o.positionals.len > 0) try std.mem.join(ctx.arena, " ", o.positionals) else return ps.usageWithLine(ctx, usage, "rename-tab requires a title", .{});
    if (o.get(&.{"--title"}) != null and o.positionals.len > 0) return unexpected(ctx, usage, o.positionals[0]);
    return tabActionCall(ctx, o, "rename", title, ps.renderOk);
}

fn runMoveTabToNewWorkspace(ctx: *Ctx) !u8 {
    const usage = usageOf("move-tab-to-new-workspace");
    const o = (try ps.parseArgs(ctx, usage, .{ .values = &.{ "--tab", "--surface", "--panel", "--workspace", "--window" }, .focus = true })) orelse return output.exit.usage;
    if (o.positionals.len > 0) return unexpected(ctx, usage, o.positionals[0]);
    return tabActionCall(ctx, o, "move-to-new-workspace", null, ps.renderOk);
}

// ----- pane layout -----

const resize_usage = usageOf("resize-pane");

fn runResizePane(ctx: *Ctx) !u8 {
    const o = (try ps.parseArgs(ctx, resize_usage, .{
        .values = &.{ "--pane", "--workspace", "--window", "--amount" },
        .bools = &.{ "-L", "-R", "-U", "-D" },
    })) orelse return output.exit.usage;
    if (o.positionals.len > 0) return unexpected(ctx, resize_usage, o.positionals[0]);
    const flag = o.lastOf(&.{ "-L", "-R", "-U", "-D" }) orelse "-R";
    const dir: []const u8 = switch (flag[1]) {
        'L' => "left",
        'U' => "up",
        'D' => "down",
        else => "right",
    };
    const amount = (intFlag(ctx, resize_usage, o, "--amount", 1) catch return output.exit.usage) orelse 1;
    var p = Params.init(ctx.arena);
    if (!try ps.addTargets(ctx, &p, o, .{ .surface_flags = &.{}, .pane = true })) return output.exit.usage;
    try p.str("direction", dir);
    try p.int("amount", amount);
    return ps.callRender(ctx, "pane.resize", &p, ps.renderOk);
}

fn runSwapPane(ctx: *Ctx) !u8 {
    const usage = usageOf("swap-pane");
    const o = (try ps.parseArgs(ctx, usage, .{ .values = &.{ "--pane", "--target-pane", "--workspace", "--window" }, .focus = true })) orelse return output.exit.usage;
    if (o.positionals.len > 0) return unexpected(ctx, usage, o.positionals[0]);
    if (o.get(&.{"--pane"}) == null) return ps.usageWithLine(ctx, usage, "swap-pane requires --pane <id|ref|index>", .{});
    const target = o.get(&.{"--target-pane"}) orelse return ps.usageWithLine(ctx, usage, "swap-pane requires --target-pane <id|ref|index>", .{});
    var p = Params.init(ctx.arena);
    if (!try ps.addTargets(ctx, &p, o, .{ .surface_flags = &.{}, .pane = true })) return output.exit.usage;
    if (!try ps.putHandle(ctx, &p, "target_pane_id", .pane, target)) return output.exit.usage;
    try p.boolean("focus", o.focus orelse false);
    return ps.callRender(ctx, "pane.swap", &p, ps.renderOk);
}

/// break-pane and join-pane share their selectors.
fn paneMove(ctx: *Ctx, comptime name: []const u8, method: []const u8, needs_target: bool) !u8 {
    const usage = usageOf(name);
    const values: []const []const u8 = if (needs_target)
        &.{ "--target-pane", "--workspace", "--pane", "--surface", "--window" }
    else
        &.{ "--workspace", "--pane", "--surface", "--window" };
    const o = (try ps.parseArgs(ctx, usage, .{ .values = values, .focus = true })) orelse return output.exit.usage;
    if (o.positionals.len > 0) return unexpected(ctx, usage, o.positionals[0]);
    const target = o.get(&.{"--target-pane"});
    if (needs_target and target == null) return ps.usageWithLine(ctx, usage, "{s} requires --target-pane <id|ref|index>", .{name});
    var p = Params.init(ctx.arena);
    if (!try ps.addTargets(ctx, &p, o, .{ .pane = true })) return output.exit.usage;
    if (target) |t| if (!try ps.putHandle(ctx, &p, "target_pane_id", .pane, t)) return output.exit.usage;
    try p.boolean("focus", o.focus orelse false);
    return ps.callRender(ctx, method, &p, ps.renderOk);
}

fn runBreakPane(ctx: *Ctx) !u8 {
    return paneMove(ctx, "break-pane", "pane.break", false);
}

fn runJoinPane(ctx: *Ctx) !u8 {
    return paneMove(ctx, "join-pane", "pane.join", true);
}

fn runLastPane(ctx: *Ctx) !u8 {
    const usage = usageOf("last-pane");
    const o = (try ps.parseArgs(ctx, usage, .{ .values = &.{ "--workspace", "--window" } })) orelse return output.exit.usage;
    if (o.positionals.len > 0) return unexpected(ctx, usage, o.positionals[0]);
    var p = Params.init(ctx.arena);
    if (!try ps.addTargets(ctx, &p, o, .{ .surface_flags = &.{} })) return output.exit.usage;
    return ps.callRender(ctx, "pane.last", &p, ps.renderOk);
}

// ----- tests -----

const testing = std.testing;
const pt = @import("ps_testing.zig");
const Harness = pt.Harness;

const ws_uuid = "0F4A3C2B-1D2E-4F5A-8B9C-0D1E2F3A4B5C";
const sf_uuid = "9B69C1E2-3D4F-4A5B-8C6D-7E8F9A0B1C2D";

test "unit: cli-ps: pane_surface --help works offline and matches goldens" {
    var names: [commands.len][]const u8 = undefined;
    for (commands, 0..) |c, i| names[i] = c.name;
    try pt.expectHelpGoldens(&names);
}

test "unit: cli-ps: new-split sends direction, caller targets, initial input and focus false" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.setEnv("CMUX_WORKSPACE_ID", ws_uuid);
    h.setEnv("CMUX_SURFACE_ID", sf_uuid);
    h.ok("surface.split", "{\"surface_id\":\"S3\",\"surface_ref\":\"surface:3\",\"pane_id\":\"P2\",\"pane_ref\":\"pane:2\",\"workspace_id\":\"W1\",\"workspace_ref\":\"workspace:1\"}");
    const r = h.run(&.{ "cmux", "new-split", "down", "--command", "htop" });
    try pt.expectOk(r);
    try h.expectLast("surface.split", "{\"direction\":\"down\",\"workspace_id\":\"" ++ ws_uuid ++ "\",\"surface_id\":\"" ++ sf_uuid ++ "\",\"initial_input\":\"htop\\r\",\"focus\":false}");
    try pt.expectGolden(h.alloc(), "new-split.txt", r.out);
    const both = h.run(&.{ "cmux", "new-split", "right", "--id-format", "both" });
    try testing.expectEqualStrings("OK surface:3 (S3) pane:2 (P2) workspace:1 (W1)\n", both.out);
    // Results also carry the window (ADR-2.5); the OK line keeps cmux's
    // documented `OK surface:<n> pane:<n> workspace:<n>` shape and --json
    // still shows everything.
    h.ok("surface.split", "{\"window_id\":\"WIN1\",\"window_ref\":\"window:1\",\"surface_id\":\"S3\",\"surface_ref\":\"surface:3\",\"pane_id\":\"P2\",\"pane_ref\":\"pane:2\",\"workspace_id\":\"W1\",\"workspace_ref\":\"workspace:1\"}");
    try testing.expectEqualStrings("OK surface:3 pane:2 workspace:1\n", h.run(&.{ "cmux", "new-split", "right" }).out);
    try pt.expectContains(h.run(&.{ "cmux", "new-split", "right", "--json" }).out, "\"window_ref\": \"window:1\"");
    // Explicit handles beat the caller; --window drops the caller defaults.
    _ = h.run(&.{ "cmux", "--window", "window:2", "new-split", "left", "--panel", "3", "--focus", "--command", "  " });
    try h.expectLast("surface.split", "{\"direction\":\"left\",\"window_id\":\"window:2\",\"surface_id\":3,\"focus\":true}");
    _ = h.run(&.{ "cmux", "new-split", "up", "--workspace", "workspace:4", "--focus=false" });
    try h.expectLast("surface.split", "{\"direction\":\"up\",\"workspace_id\":\"workspace:4\",\"focus\":false}");
}

test "unit: cli-ps: new-split argument validation" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try pt.expectUsage(h.run(&.{ "cmux", "new-split" }), "cmux: new-split requires a direction: left, right, up or down\nUsage: cmux new-split");
    try pt.expectUsage(h.run(&.{ "cmux", "new-split", "sideways" }), "invalid direction 'sideways'");
    try pt.expectUsage(h.run(&.{ "cmux", "new-split", "right", "extra" }), "unexpected argument 'extra'");
    try pt.expectUsage(h.run(&.{ "cmux", "new-split", "right", "--bogus" }), "unknown flag '--bogus'");
    try pt.expectUsage(h.run(&.{ "cmux", "new-split", "right", "--command" }), "--command requires a value");
    try pt.expectUsage(h.run(&.{ "cmux", "new-split", "right", "--surface", "" }), "cmux: Surface handle is blank\n");
    try pt.expectUsage(h.run(&.{ "cmux", "new-split", "right", "--surface", "pane:1" }), "Invalid surface handle: pane:1 (expected UUID, ref like surface:1, or index)");
    try pt.expectUsage(h.run(&.{ "cmux", "new-split", "right", "--workspace", " " }), "No workspace selected: --workspace was blank and CMUX_WORKSPACE_ID is unset");
    try pt.expectUsage(h.run(&.{ "cmux", "new-split", "right", "--focus=maybe" }), "--focus must be true|false");
    try testing.expectEqual(@as(usize, 0), h.requests().len);
}

test "unit: cli-ps: a blank --workspace is the caller's only when no window is named" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.setEnv("CMUX_WORKSPACE_ID", ws_uuid);
    h.setEnv("CMUX_SURFACE_ID", sf_uuid);
    // `--workspace "${CMUX_WORKSPACE_ID:-}"` inside a terminal names the
    // caller's workspace (ADR-4.6).
    _ = h.run(&.{ "cmux", "list-panes", "--workspace", "" });
    try h.expectLast("pane.list", "{\"workspace_id\":\"" ++ ws_uuid ++ "\"}");
    _ = h.run(&.{ "cmux", "tree", "--workspace", " " });
    try h.expectLast("system.tree", "{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"caller\":{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"surface_id\":\"" ++ sf_uuid ++ "\"}}");
    _ = h.run(&.{ "cmux", "identify", "--workspace", "" });
    try h.expectLast("system.identify", "{\"caller\":{\"workspace_id\":\"" ++ ws_uuid ++ "\"}}");
    // A named window (its own flag or the global one) never pairs with the
    // caller's workspace: the selection fails closed, before any request.
    h.clearRequests();
    const msg = "cmux: No workspace selected: --workspace was blank and CMUX_WORKSPACE_ID is unset\n";
    try pt.expectUsage(h.run(&.{ "cmux", "list-panes", "--window", "window:2", "--workspace", "" }), msg);
    try pt.expectUsage(h.run(&.{ "cmux", "--window", "window:2", "send", "--workspace", "", "hi" }), msg);
    try pt.expectUsage(h.run(&.{ "cmux", "--window", "1", "new-split", "down", "--workspace=" }), msg);
    try pt.expectUsage(h.run(&.{ "cmux", "tree", "--window", "1", "--workspace", "" }), msg);
    try pt.expectUsage(h.run(&.{ "cmux", "--window", "1", "top", "--workspace", "" }), msg);
    try pt.expectUsage(h.run(&.{ "cmux", "identify", "--window", "1", "--workspace", "" }), msg);
    try testing.expectEqual(@as(usize, 0), h.requests().len);
}

test "unit: cli-ps: new-split remote tmux mirror acceptance note" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("surface.split", "{\"accepted\":true,\"workspace_ref\":\"workspace:2\"}");
    const r = h.run(&.{ "cmux", "new-split", "right" });
    try testing.expectEqualStrings("OK accepted workspace:2 (routed to remote tmux; the new pane arrives asynchronously)\n", r.out);
}

test "unit: cli-ps: new-pane and new-surface params" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = h.run(&.{ "cmux", "new-pane" });
    try h.expectLast("pane.create", "{\"type\":\"terminal\",\"direction\":\"right\",\"focus\":false}");
    _ = h.run(&.{ "cmux", "new-pane", "--type", "browser", "--direction", "down", "--placement", "dock", "--url", "https://example.com", "--profile", "work", "--focus", "true" });
    try h.expectLast("pane.create", "{\"type\":\"browser\",\"direction\":\"down\",\"placement\":\"dock\",\"url\":\"https://example.com\",\"profile\":\"work\",\"focus\":true}");
    _ = h.run(&.{ "cmux", "new-surface", "--pane", "pane:2", "--command", "npm test" });
    try h.expectLast("surface.create", "{\"type\":\"terminal\",\"pane_id\":\"pane:2\",\"initial_input\":\"npm test\\r\",\"focus\":false}");
    try pt.expectUsage(h.run(&.{ "cmux", "new-pane", "--type", "browser", "--command", "ls" }), "--command is only supported for terminal surfaces");
    try pt.expectUsage(h.run(&.{ "cmux", "new-pane", "--type", "simulator" }), "--type must be terminal or browser");
    try pt.expectUsage(h.run(&.{ "cmux", "new-pane", "--direction", "north" }), "invalid direction 'north'");
    try pt.expectUsage(h.run(&.{ "cmux", "new-pane", "--placement", "sky" }), "--placement must be workspace or dock");
    try pt.expectUsage(h.run(&.{ "cmux", "new-surface", "--pane", "surface:1" }), "Invalid pane handle: surface:1");
    try pt.expectUsage(h.run(&.{ "cmux", "new-surface", "stray" }), "unexpected argument 'stray'");
}

test "unit: cli-ps: list commands render cmux rows and goldens" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.setEnv("CMUX_WORKSPACE_ID", ws_uuid);
    h.ok("pane.list", "{\"workspace_ref\":\"workspace:1\",\"panes\":[" ++
        "{\"id\":\"P1\",\"ref\":\"pane:1\",\"focused\":false,\"surface_ids\":[\"S1\"],\"surface_count\":1}," ++
        "{\"id\":\"P2\",\"ref\":\"pane:2\",\"focused\":true,\"surface_ids\":[\"S2\",\"S3\",\"S4\"]}," ++
        "{\"id\":\"P5\",\"ref\":\"pane:5\",\"focused\":false,\"surface_count\":0,\"dock\":\"workspace\"}]}");
    const panes = h.run(&.{ "cmux", "list-panes" });
    try pt.expectOk(panes);
    try h.expectLast("pane.list", "{\"workspace_id\":\"" ++ ws_uuid ++ "\"}");
    try pt.expectGolden(h.alloc(), "list-panes.txt", panes.out);

    h.ok("pane.surfaces", "{\"surfaces\":[{\"id\":\"S2\",\"ref\":\"surface:2\",\"title\":\"zsh\",\"selected\":false}," ++
        "{\"id\":\"S4\",\"ref\":\"surface:4\",\"title\":\"vim \\u001b[31mREADME\",\"selected_in_pane\":true}," ++
        "{\"id\":\"S9\",\"ref\":\"surface:9\",\"title\":\"\\u65e5\\u672c \\ud83d\\ude00\"}]}");
    const ps_out = h.run(&.{ "cmux", "list-pane-surfaces", "--pane", "pane:2" });
    try pt.expectOk(ps_out);
    try h.expectLast("pane.surfaces", "{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"pane_id\":\"pane:2\"}");
    try pt.expectGolden(h.alloc(), "list-pane-surfaces.txt", ps_out.out);

    h.ok("surface.list", "{\"surfaces\":[{\"id\":\"S1\",\"ref\":\"surface:1\",\"pane_ref\":\"pane:1\",\"type\":\"terminal\",\"title\":\"build\",\"focused\":true}," ++
        "{\"id\":\"S7\",\"ref\":\"surface:7\",\"pane_ref\":\"pane:2\",\"type\":\"browser\",\"title\":\"Docs\"}]}");
    const panels = h.run(&.{ "cmux", "list-panels", "--window", "1" });
    try pt.expectOk(panels);
    try h.expectLast("surface.list", "{\"window_id\":1}");
    try pt.expectGolden(h.alloc(), "list-panels.txt", panels.out);

    h.ok("pane.list", "{\"panes\":[]}");
    try testing.expectEqualStrings("No panes\n", h.run(&.{ "cmux", "list-panes" }).out);
    h.ok("surface.list", "{}");
    try testing.expectEqualStrings("No surfaces\n", h.run(&.{ "cmux", "list-panels" }).out);
    const j = h.run(&.{ "cmux", "list-panels", "--json" });
    try testing.expectEqualStrings("{}\n", j.out);
}

test "unit: cli-ps: close, focus, move, reorder, split-off and drag params" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.setEnv("CMUX_SURFACE_ID", sf_uuid);
    _ = h.run(&.{ "cmux", "close-surface" });
    try h.expectLast("surface.close", "{\"surface_id\":\"" ++ sf_uuid ++ "\"}");
    _ = h.run(&.{ "cmux", "focus-pane", "pane:3" });
    try h.expectLast("pane.focus", "{\"pane_id\":\"pane:3\"}");
    _ = h.run(&.{ "cmux", "focus-panel", "--panel", "surface:2" });
    try h.expectLast("surface.focus", "{\"surface_id\":\"surface:2\"}");
    _ = h.run(&.{ "cmux", "focus-panel", "tab:5" });
    try h.expectLast("surface.focus", "{\"surface_id\":\"tab:5\"}");
    _ = h.run(&.{ "cmux", "move-surface", "--surface", "surface:2", "--pane", "pane:4", "--index", "0" });
    try h.expectLast("surface.move", "{\"surface_id\":\"surface:2\",\"pane_id\":\"pane:4\",\"index\":0,\"focus\":false}");
    _ = h.run(&.{ "cmux", "move-surface", "--surface", "surface:2", "--workspace", "workspace:3", "--focus", "true" });
    try h.expectLast("surface.move", "{\"surface_id\":\"surface:2\",\"workspace_id\":\"workspace:3\",\"focus\":true}");
    _ = h.run(&.{ "cmux", "reorder-surface", "--surface", "surface:2", "--index", "3" });
    try h.expectLast("surface.reorder", "{\"surface_id\":\"surface:2\",\"index\":3}");
    _ = h.run(&.{ "cmux", "split-off", "--surface", "surface:2", "right" });
    try h.expectLast("surface.split_off", "{\"surface_id\":\"surface:2\",\"direction\":\"right\",\"focus\":false}");
    _ = h.run(&.{ "cmux", "drag-surface-to-split", "--surface", "surface:2", "up", "--focus" });
    try h.expectLast("surface.drag_to_split", "{\"surface_id\":\"surface:2\",\"direction\":\"up\",\"focus\":true}");

    h.clearRequests();
    try pt.expectUsage(h.run(&.{ "cmux", "focus-pane" }), "focus-pane requires --pane <id|ref|index>");
    try pt.expectUsage(h.run(&.{ "cmux", "focus-panel" }), "focus-panel requires --panel <id|ref|index>");
    try pt.expectUsage(h.run(&.{ "cmux", "move-surface", "--surface", "surface:2" }), "move-surface requires --pane, --workspace, --window or --index");
    try pt.expectUsage(h.run(&.{ "cmux", "move-surface", "--pane", "pane:1" }), "move-surface requires --surface <id|ref|index>");
    try pt.expectUsage(h.run(&.{ "cmux", "move-surface", "--surface", "surface:2", "--index", "-1" }), "--index must be at least 0");
    try pt.expectUsage(h.run(&.{ "cmux", "reorder-surface", "--surface", "surface:2" }), "reorder-surface requires --index <n>");
    try pt.expectUsage(h.run(&.{ "cmux", "reorder-surface", "--surface", "surface:2", "--index", "two" }), "--index must be an integer");
    try pt.expectUsage(h.run(&.{ "cmux", "split-off", "right" }), "split-off requires --surface <id|ref|index>");
    try pt.expectUsage(h.run(&.{ "cmux", "drag-surface-to-split", "--surface", "surface:1" }), "drag-surface-to-split requires a direction");
    try pt.expectUsage(h.run(&.{ "cmux", "close-surface", "x", "y" }), "unexpected argument 'x'");
    try testing.expectEqual(@as(usize, 0), h.requests().len);
}

test "unit: cli-ps: legacy +split, +tab and +surface spellings reach the commands" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.setEnv("CMUX_QUIET", "1");
    h.setEnv("CMUX_WORKSPACE_ID", ws_uuid);
    h.setEnv("CMUX_SURFACE_ID", sf_uuid);
    // ADR-4.11: --pane P, --tab T and `+tab close <index>` stay accepted. An
    // explicit pane drops the caller's surface, which the server would prefer.
    _ = h.run(&.{ "wmux", "+split", "down", "--pane", "1", "--focus" });
    try h.expectLast("surface.split", "{\"direction\":\"down\",\"workspace_id\":\"" ++ ws_uuid ++ "\",\"pane_id\":1,\"focus\":true}");
    _ = h.run(&.{ "wmux", "+tab", "close", "2" });
    try h.expectLast("surface.close", "{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"surface_id\":2}");
    _ = h.run(&.{ "wmux", "+tab", "close", "0", "--workspace", "1", "--pane", "2" });
    try h.expectLast("surface.close", "{\"workspace_id\":1,\"pane_id\":2,\"surface_id\":0}");
    _ = h.run(&.{ "wmux", "+tab", "select", "1", "--pane", "0" });
    try h.expectLast("surface.focus", "{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"pane_id\":0,\"surface_id\":1}");
    _ = h.run(&.{ "wmux", "+surface", "focus", "--workspace", "0", "--pane", "1", "--tab", "2" });
    try h.expectLast("surface.focus", "{\"workspace_id\":0,\"pane_id\":1,\"surface_id\":2}");
    _ = h.run(&.{ "wmux", "+surface", "focus", "--pane", "1" });
    try h.expectLast("surface.focus", "{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"pane_id\":1}");
    // The pane movers follow the same rule.
    _ = h.run(&.{ "cmux", "break-pane", "--pane", "pane:3" });
    try h.expectLast("pane.break", "{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"pane_id\":\"pane:3\",\"focus\":false}");

    h.clearRequests();
    try pt.expectUsage(h.run(&.{ "cmux", "close-surface", "x" }), "Invalid surface handle: x");
    try pt.expectUsage(h.run(&.{ "cmux", "close-surface", "--surface", "surface:1", "2" }), "unexpected argument '2'");
    try pt.expectUsage(h.run(&.{ "wmux", "+split", "right", "--pane", "surface:1" }), "Invalid pane handle: surface:1");
    try testing.expectEqual(@as(usize, 0), h.requests().len);
}

test "unit: cli-ps: tab-action, rename-tab and detach-tab params" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.setEnv("CMUX_SURFACE_ID", sf_uuid);
    _ = h.run(&.{ "cmux", "tab-action", "--tab", "tab:2", "--action", "pin" });
    try h.expectLast("tab.action", "{\"action\":\"pin\",\"surface_id\":\"tab:2\"}");
    _ = h.run(&.{ "cmux", "tab-action", "close-right" });
    try h.expectLast("tab.action", "{\"action\":\"close-right\",\"surface_id\":\"" ++ sf_uuid ++ "\"}");
    _ = h.run(&.{ "cmux", "tab-action", "rename", "my", "t\u{e9}st" });
    try h.expectLast("tab.action", "{\"action\":\"rename\",\"surface_id\":\"" ++ sf_uuid ++ "\",\"title\":\"my t\u{e9}st\"}");
    _ = h.run(&.{ "cmux", "tab-action", "--action", "rename", "--title", "x", "--surface", "surface:1" });
    try h.expectLast("tab.action", "{\"action\":\"rename\",\"surface_id\":\"surface:1\",\"title\":\"x\"}");
    _ = h.run(&.{ "cmux", "tab-action", "close-others", "--force" });
    try h.expectLast("tab.action", "{\"action\":\"close-others\",\"surface_id\":\"" ++ sf_uuid ++ "\",\"force\":true}");
    _ = h.run(&.{ "cmux", "tab-action", "new-browser-right", "--url", "https://x.example" });
    try h.expectLast("tab.action", "{\"action\":\"new-browser-right\",\"surface_id\":\"" ++ sf_uuid ++ "\",\"url\":\"https://x.example\"}");
    _ = h.run(&.{ "cmux", "tab-action", "move-to-new-workspace" });
    try h.expectLast("tab.action", "{\"action\":\"move-to-new-workspace\",\"surface_id\":\"" ++ sf_uuid ++ "\",\"focus\":false}");
    _ = h.run(&.{ "cmux", "rename-tab", "--surface", "surface:3", "Build", "logs" });
    try h.expectLast("tab.action", "{\"action\":\"rename\",\"surface_id\":\"surface:3\",\"title\":\"Build logs\"}");
    _ = h.run(&.{ "cmux", "detach-tab", "--focus", "true" });
    try h.expectLast("tab.action", "{\"action\":\"move-to-new-workspace\",\"surface_id\":\"" ++ sf_uuid ++ "\",\"focus\":true}");

    h.ok("tab.action", "{\"surface_ref\":\"surface:2\",\"full_width\":true}");
    try testing.expectEqualStrings("OK surface:2 full_width=true\n", h.run(&.{ "cmux", "tab-action", "toggle-full-width-tab" }).out);

    h.clearRequests();
    try pt.expectUsage(h.run(&.{ "cmux", "tab-action" }), "tab-action requires --action <name>");
    try pt.expectUsage(h.run(&.{ "cmux", "tab-action", "explode" }), "unknown tab action 'explode'; expected one of: rename, clear-name");
    try pt.expectUsage(h.run(&.{ "cmux", "tab-action", "rename" }), "tab-action rename requires --title <text> or trailing text");
    try pt.expectUsage(h.run(&.{ "cmux", "tab-action", "pin", "extra" }), "unexpected argument 'extra'");
    try pt.expectUsage(h.run(&.{ "cmux", "rename-tab" }), "rename-tab requires a title");
    try testing.expectEqual(@as(usize, 0), h.requests().len);
}

test "unit: cli-ps: resize, swap, break, join and last-pane params" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.setEnv("CMUX_WORKSPACE_ID", ws_uuid);
    _ = h.run(&.{ "cmux", "resize-pane" });
    try h.expectLast("pane.resize", "{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"direction\":\"right\",\"amount\":1}");
    _ = h.run(&.{ "cmux", "resize-pane", "-U", "-L", "--amount", "5", "--pane", "pane:2" });
    try h.expectLast("pane.resize", "{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"pane_id\":\"pane:2\",\"direction\":\"left\",\"amount\":5}");
    _ = h.run(&.{ "cmux", "resize-pane", "-D", "--window", "window:1" });
    try h.expectLast("pane.resize", "{\"window_id\":\"window:1\",\"direction\":\"down\",\"amount\":1}");
    _ = h.run(&.{ "cmux", "swap-pane", "--pane", "pane:1", "--target-pane", "pane:2" });
    try h.expectLast("pane.swap", "{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"pane_id\":\"pane:1\",\"target_pane_id\":\"pane:2\",\"focus\":false}");
    _ = h.run(&.{ "cmux", "break-pane", "--pane", "pane:3", "--no-focus" });
    try h.expectLast("pane.break", "{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"pane_id\":\"pane:3\",\"focus\":false}");
    _ = h.run(&.{ "cmux", "join-pane", "--target-pane", "pane:1", "--surface", "surface:4", "--focus", "true" });
    try h.expectLast("pane.join", "{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"surface_id\":\"surface:4\",\"target_pane_id\":\"pane:1\",\"focus\":true}");
    _ = h.run(&.{ "cmux", "last-pane" });
    try h.expectLast("pane.last", "{\"workspace_id\":\"" ++ ws_uuid ++ "\"}");

    h.clearRequests();
    try pt.expectUsage(h.run(&.{ "cmux", "resize-pane", "--amount", "0" }), "--amount must be at least 1");
    try pt.expectUsage(h.run(&.{ "cmux", "resize-pane", "-X" }), "unknown flag '-X'");
    try pt.expectUsage(h.run(&.{ "cmux", "swap-pane", "--pane", "pane:1" }), "swap-pane requires --target-pane <id|ref|index>");
    try pt.expectUsage(h.run(&.{ "cmux", "swap-pane", "--target-pane", "pane:1" }), "swap-pane requires --pane <id|ref|index>");
    try pt.expectUsage(h.run(&.{ "cmux", "join-pane" }), "join-pane requires --target-pane <id|ref|index>");
    try pt.expectUsage(h.run(&.{ "cmux", "last-pane", "now" }), "unexpected argument 'now'");
    try testing.expectEqual(@as(usize, 0), h.requests().len);
}

test "unit: cli-ps: server errors print code and message and exit 1" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.reply("surface.close", .{ .err = "{\"code\":\"not_found\",\"message\":\"Surface not found for the given surface_id\"}" });
    const r = h.run(&.{ "cmux", "close-surface", "--surface", "surface:99" });
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings("not_found: Surface not found for the given surface_id\n", r.err);
    try testing.expectEqualStrings("", r.out);
}

test "unit: cli-ps: pane_surface OK lines match goldens" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const reply = "{\"surface_id\":\"S3\",\"surface_ref\":\"surface:3\",\"pane_id\":\"P2\",\"pane_ref\":\"pane:2\",\"workspace_id\":\"W1\",\"workspace_ref\":\"workspace:1\"}";
    const cases = [_]struct { []const u8, []const u8, []const []const u8 }{
        .{ "new-pane", "pane.create", &.{ "cmux", "new-pane" } },
        .{ "new-surface", "surface.create", &.{ "cmux", "new-surface" } },
        .{ "close-surface", "surface.close", &.{ "cmux", "close-surface", "--surface", "surface:3" } },
        .{ "focus-pane", "pane.focus", &.{ "cmux", "focus-pane", "--pane", "pane:2" } },
        .{ "focus-panel", "surface.focus", &.{ "cmux", "focus-panel", "--panel", "surface:3" } },
        .{ "move-surface", "surface.move", &.{ "cmux", "move-surface", "--surface", "surface:3", "--pane", "pane:2" } },
        .{ "reorder-surface", "surface.reorder", &.{ "cmux", "reorder-surface", "--surface", "surface:3", "--index", "0" } },
        .{ "split-off", "surface.split_off", &.{ "cmux", "split-off", "--surface", "surface:3", "down" } },
        .{ "drag-surface-to-split", "surface.drag_to_split", &.{ "cmux", "drag-surface-to-split", "--surface", "surface:3", "left" } },
        .{ "tab-action", "tab.action", &.{ "cmux", "tab-action", "--tab", "tab:3", "--action", "pin" } },
        .{ "rename-tab", "tab.action", &.{ "cmux", "rename-tab", "--surface", "surface:3", "logs" } },
        .{ "move-tab-to-new-workspace", "tab.action", &.{ "cmux", "move-tab-to-new-workspace", "--surface", "surface:3" } },
        .{ "resize-pane", "pane.resize", &.{ "cmux", "resize-pane", "-L", "--amount", "5" } },
        .{ "swap-pane", "pane.swap", &.{ "cmux", "swap-pane", "--pane", "pane:1", "--target-pane", "pane:2" } },
        .{ "break-pane", "pane.break", &.{ "cmux", "break-pane" } },
        .{ "join-pane", "pane.join", &.{ "cmux", "join-pane", "--target-pane", "pane:2" } },
        .{ "last-pane", "pane.last", &.{ "cmux", "last-pane" } },
    };
    for (cases) |c| {
        h.ok(c[1], reply);
        const r = h.run(c[2]);
        try pt.expectOk(r);
        try testing.expectEqualStrings(c[1], (try h.last()).method);
        try pt.expectGolden(h.alloc(), try std.fmt.allocPrint(h.alloc(), "{s}.txt", .{c[0]}), r.out);
    }
}
