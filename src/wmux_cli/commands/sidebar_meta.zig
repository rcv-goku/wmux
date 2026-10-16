//! CLI command family `sidebar_meta` (Appendix C).
//! set-status, clear-status, list-status, set-progress, clear-progress, log,
//! clear-log, list-log, sidebar-state, pr; internal report_pwd,
//! report_git_branch, report_pr_action. Owner: W2-6.
//!
//! cmux serves these verbs over its v1 text protocol only; wmux maps them to
//! the v2 twins `wmux.sidebar.*` and `wmux.workspace.pr.*` (Appendix B.3).
//! Arguments are validated client-side with cmux's v1 reply strings
//! (`ERROR: ...`, printed verbatim, exit 1 as a server reply would be), the
//! workspace defaults to `CMUX_WORKSPACE_ID` (ADR-4.6), and the text output
//! follows the v1 replies (`OK`, `key=value ...`, `[level] message`,
//! `sidebar-state` key=value lines). `--json` prints the v2 result.
//! The internal report_* verbs are sent by shell integration over the
//! socket (`surface.report_*`) and have no CLI form.

const std = @import("std");
const command = @import("../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../output.zig");
const common = @import("notify/common.zig");
const pr = @import("notify/pr.zig");
const Params = common.Params;
const Opt = common.Opt;

/// `CommandSpec` entries (ADR-4.9).
pub const commands = [_]CommandSpec{
    .{ .name = "set-status", .group = .customize, .usage = common.usageOf(@embedFile("../help/set-status.txt")), .help = @embedFile("../help/set-status.txt"), .run = runSetStatus },
    .{ .name = "clear-status", .group = .customize, .usage = common.usageOf(@embedFile("../help/clear-status.txt")), .help = @embedFile("../help/clear-status.txt"), .run = runClearStatus },
    .{ .name = "list-status", .group = .customize, .usage = common.usageOf(@embedFile("../help/list-status.txt")), .help = @embedFile("../help/list-status.txt"), .run = runListStatus },
    .{ .name = "set-progress", .group = .customize, .usage = common.usageOf(@embedFile("../help/set-progress.txt")), .help = @embedFile("../help/set-progress.txt"), .run = runSetProgress },
    .{ .name = "clear-progress", .group = .customize, .usage = common.usageOf(@embedFile("../help/clear-progress.txt")), .help = @embedFile("../help/clear-progress.txt"), .run = runClearProgress },
    .{ .name = "log", .group = .customize, .usage = common.usageOf(@embedFile("../help/log.txt")), .help = @embedFile("../help/log.txt"), .run = runLog },
    .{ .name = "clear-log", .group = .customize, .usage = common.usageOf(@embedFile("../help/clear-log.txt")), .help = @embedFile("../help/clear-log.txt"), .run = runClearLog },
    .{ .name = "list-log", .group = .customize, .usage = common.usageOf(@embedFile("../help/list-log.txt")), .help = @embedFile("../help/list-log.txt"), .run = runListLog },
    .{ .name = "sidebar-state", .group = .customize, .usage = common.usageOf(@embedFile("../help/sidebar-state.txt")), .help = @embedFile("../help/sidebar-state.txt"), .run = runSidebarState },
    .{ .name = "pr", .group = .customize, .usage = common.usageOf(@embedFile("../help/pr.txt")), .help = @embedFile("../help/pr.txt"), .run = pr.run },
};

/// `--workspace`/`--window` (plus `--tab`, the v1 spelling).
const target_opts = [_]Opt{
    .{ .name = "--workspace" },
    .{ .name = "--window" },
    .{ .name = "--tab", .canonical = "--workspace" },
};

/// Allowed values (cmux).
pub const formats = [_][]const u8{ "plain", "markdown" };
pub const work_states = [_][]const u8{ "running", "subagents", "waiting" };
pub const log_levels = [_][]const u8{ "info", "progress", "success", "warning", "error" };

/// Default and bounds of `sidebarMaxLogEntries` (cmux).
pub const default_max_log_entries = 50;

fn oneOf(list: []const []const u8, v: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, v)) return true;
    return false;
}

/// Prints a v1-style `ERROR: ...` line (rebranded) and returns exit 1.
fn v1Error(ctx: *Ctx, comptime fmt: []const u8, a: anytype) u8 {
    const text = std.fmt.allocPrint(ctx.arena, fmt, a) catch return output.exit.runtime;
    return common.runtimeText(ctx, text);
}

/// Scans, resolves the workspace target and starts the params.
fn begin(ctx: *Ctx, cmd: []const u8, extra: []const Opt, code: *u8) !?struct { s: common.Scanned, p: Params } {
    const opts = try std.mem.concat(ctx.arena, Opt, &.{ &target_opts, extra });
    const s = (try common.scanOrReport(ctx, cmd, opts, .{}, code)) orelse return null;
    const t = common.resolveTarget(ctx, s, .{ .env_workspace = true }, code) orelse return null;
    var p = Params.init(ctx.arena);
    try t.put(&p);
    return .{ .s = s, .p = p };
}

fn noPositionals(ctx: *Ctx, cmd: []const u8, s: common.Scanned) ?u8 {
    if (s.positionals.len == 0) return null;
    return common.reportProblem(ctx, cmd, .{ .unexpected = s.positionals });
}

/// Commands without arguments of their own: one request, `OK`.
fn simple(ctx: *Ctx, cmd: []const u8, method: []const u8) !u8 {
    var code: u8 = 0;
    var b = (try begin(ctx, cmd, &.{}, &code)) orelse return code;
    if (noPositionals(ctx, cmd, b.s)) |c| return c;
    return common.callOk(ctx, method, &b.p);
}

// ----- status entries -----

const status_opts = [_]Opt{
    .{ .name = "--icon" },
    .{ .name = "--color" },
    .{ .name = "--priority" },
    .{ .name = "--url" },
    .{ .name = "--link", .canonical = "--url" },
    .{ .name = "--format" },
    .{ .name = "--work" },
};

const set_status_v1_usage = "set-status <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--work=running|subagents|waiting] [--workspace=X]";

/// `http://` or `https://` followed by a host.
pub fn isHttpUrl(u: []const u8) bool {
    for ([_][]const u8{ "http://", "https://" }) |scheme| {
        if (u.len > scheme.len and std.ascii.startsWithIgnoreCase(u, scheme)) {
            const host = u[scheme.len..];
            return host[0] != '/' and std.mem.indexOfAny(u8, u, " \t\r\n") == null;
        }
    }
    return false;
}

fn runSetStatus(ctx: *Ctx) !u8 {
    var code: u8 = 0;
    var b = (try begin(ctx, "set-status", &status_opts, &code)) orelse return code;
    const s = b.s;
    if (s.positionals.len < 2 or s.positionals[0].len == 0)
        return v1Error(ctx, "ERROR: Missing status key or value \u{2014} usage: {s}", .{set_status_v1_usage});
    const value = try std.mem.join(ctx.arena, " ", s.positionals[1..]);
    var priority: ?i64 = null;
    if (s.get("--priority")) |x| priority = std.fmt.parseInt(i64, std.mem.trim(u8, x, " \t"), 10) catch
        return v1Error(ctx, "ERROR: Invalid metadata priority '{s}' \u{2014} must be an integer", .{x});
    if (s.get("--url")) |u| if (!isHttpUrl(u))
        return v1Error(ctx, "ERROR: Invalid metadata URL '{s}' \u{2014} expected http(s) URL", .{u});
    if (s.get("--format")) |f| if (!oneOf(&formats, f))
        return v1Error(ctx, "ERROR: Invalid metadata format '{s}' \u{2014} use: plain, markdown", .{f});
    if (s.get("--work")) |w| if (!oneOf(&work_states, w))
        return v1Error(ctx, "ERROR: Invalid work state '{s}' \u{2014} use: running, subagents, waiting", .{w});
    try b.p.str("key", s.positionals[0]);
    try b.p.str("value", value);
    if (s.get("--icon")) |x| try b.p.str("icon", x);
    if (s.get("--color")) |x| try b.p.str("color", x);
    if (priority) |n| try b.p.int("priority", n);
    if (s.get("--url")) |x| try b.p.str("url", x);
    if (s.get("--format")) |x| try b.p.str("format", x);
    if (s.get("--work")) |x| try b.p.str("work", x);
    return common.callOk(ctx, "wmux.sidebar.status.set", &b.p);
}

fn runClearStatus(ctx: *Ctx) !u8 {
    var code: u8 = 0;
    var b = (try begin(ctx, "clear-status", &.{}, &code)) orelse return code;
    if (b.s.positionals.len == 0 or b.s.positionals[0].len == 0)
        return v1Error(ctx, "ERROR: Missing status key \u{2014} usage: clear-status <key> [--workspace=X]", .{});
    if (b.s.positionals.len > 1) return common.reportProblem(ctx, "clear-status", .{ .unexpected = b.s.positionals[1..] });
    try b.p.str("key", b.s.positionals[0]);
    return common.callOk(ctx, "wmux.sidebar.status.clear", &b.p);
}

/// One `list_status` line:
/// `key=value[ icon=..][ color=..][ url=..][ priority=N][ format=markdown][ work=..]`.
pub fn writeStatusLine(w: *std.Io.Writer, e: std.json.Value) std.Io.Writer.Error!void {
    try writeSafe(w, common.strField(e, "key") orelse "");
    try w.writeByte('=');
    try writeSafe(w, common.strField(e, "value") orelse "");
    for ([_][]const u8{ "icon", "color", "url" }) |k| if (common.strField(e, k)) |v| {
        try w.print(" {s}=", .{k});
        try writeSafe(w, v);
    };
    if (common.field(e, "priority")) |v| switch (v) {
        .integer => |n| if (n != 0) try w.print(" priority={d}", .{n}),
        .float => |f| if (f != 0 and std.math.isFinite(f)) try w.print(" priority={d}", .{@as(i64, @intFromFloat(@max(@min(f, 9e18), -9e18)))}),
        else => {},
    };
    if (common.strField(e, "format")) |f| if (std.mem.eql(u8, f, "markdown")) try w.writeAll(" format=markdown");
    if (common.strField(e, "work")) |v| {
        try w.writeAll(" work=");
        try writeSafe(w, v);
    }
    try w.writeByte('\n');
}

fn writeSafe(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| try w.writeByte(if (c == '\n' or c == '\r') ' ' else c);
}

fn statusEntries(r: std.json.Value) []const std.json.Value {
    return common.firstArray(r, &.{ "entries", "statuses", "status" });
}

fn runListStatus(ctx: *Ctx) !u8 {
    var code: u8 = 0;
    var b = (try begin(ctx, "list-status", &.{}, &code)) orelse return code;
    if (noPositionals(ctx, "list-status", b.s)) |c| return c;
    const r = (try common.request(ctx, "wmux.sidebar.status.list", &b.p)) orelse return output.exit.runtime;
    if (ctx.json()) return common.printOk(ctx, r);
    const entries = statusEntries(r);
    if (entries.len == 0) try ctx.out.writeAll("No status entries\n");
    for (entries) |e| try writeStatusLine(ctx.out, e);
    return output.exit.ok;
}

// ----- progress -----

/// The progress value: a finite number clamped to 0...1; null when invalid.
pub fn parseProgress(text: []const u8) ?f64 {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return null;
    const v = std.fmt.parseFloat(f64, t) catch return null;
    if (!std.math.isFinite(v)) return null;
    return std.math.clamp(v, 0.0, 1.0);
}

fn runSetProgress(ctx: *Ctx) !u8 {
    var code: u8 = 0;
    var b = (try begin(ctx, "set-progress", &.{.{ .name = "--label" }}, &code)) orelse return code;
    const pos = b.s.positionals;
    if (pos.len == 0) return v1Error(ctx, "ERROR: Missing progress value \u{2014} usage: set-progress <0.0-1.0> [--label=X] [--workspace=X]", .{});
    if (pos.len > 1) return common.reportProblem(ctx, "set-progress", .{ .unexpected = pos[1..] });
    const v = parseProgress(pos[0]) orelse
        return v1Error(ctx, "ERROR: Invalid progress value '{s}' \u{2014} must be 0.0 to 1.0", .{pos[0]});
    try b.p.float("value", v);
    if (b.s.get("--label")) |l| try b.p.str("label", l);
    return common.callOk(ctx, "wmux.sidebar.progress.set", &b.p);
}

fn runClearProgress(ctx: *Ctx) !u8 {
    return simple(ctx, "clear-progress", "wmux.sidebar.progress.clear");
}

// ----- log -----

fn runLog(ctx: *Ctx) !u8 {
    var code: u8 = 0;
    var b = (try begin(ctx, "log", &.{ .{ .name = "--level" }, .{ .name = "--source" } }, &code)) orelse return code;
    const level = b.s.get("--level") orelse "info";
    if (!oneOf(&log_levels, level))
        return v1Error(ctx, "ERROR: Unknown log level '{s}' \u{2014} use: info, progress, success, warning, error", .{level});
    const message = try std.mem.join(ctx.arena, " ", b.s.positionals);
    if (message.len == 0) return v1Error(ctx, "ERROR: Missing message \u{2014} usage: log [--level=X] [--source=X] [--workspace=X] -- <message>", .{});
    try b.p.str("message", message);
    try b.p.str("level", level);
    if (b.s.get("--source")) |x| try b.p.str("source", x);
    return common.callOk(ctx, "wmux.sidebar.log.append", &b.p);
}

fn runClearLog(ctx: *Ctx) !u8 {
    return simple(ctx, "clear-log", "wmux.sidebar.log.clear");
}

/// One `list_log` line: `[source] [level] message` (source only when set).
pub fn writeLogLine(w: *std.Io.Writer, e: std.json.Value) std.Io.Writer.Error!void {
    if (common.strField(e, "source")) |src| {
        try w.writeByte('[');
        try writeSafe(w, src);
        try w.writeAll("] ");
    }
    try w.writeByte('[');
    try writeSafe(w, common.strField(e, "level") orelse "info");
    try w.writeAll("] ");
    try writeSafe(w, common.strField(e, "message") orelse "");
    try w.writeByte('\n');
}

fn logEntries(r: std.json.Value) []const std.json.Value {
    return common.firstArray(r, &.{ "entries", "logs", "log" });
}

fn runListLog(ctx: *Ctx) !u8 {
    var code: u8 = 0;
    var b = (try begin(ctx, "list-log", &.{.{ .name = "--limit" }}, &code)) orelse return code;
    if (noPositionals(ctx, "list-log", b.s)) |c| return c;
    var limit: usize = 0;
    if (b.s.get("--limit")) |x| {
        const n = std.fmt.parseInt(i64, std.mem.trim(u8, x, " \t"), 10) catch -1;
        if (n < 0) return v1Error(ctx, "ERROR: Invalid limit '{s}' \u{2014} must be >= 0", .{x});
        limit = @intCast(@min(n, std.math.maxInt(u32)));
        if (limit > 0) try b.p.int("limit", @intCast(limit));
    }
    const r = (try common.request(ctx, "wmux.sidebar.log.list", &b.p)) orelse return output.exit.runtime;
    if (ctx.json()) return common.printOk(ctx, r);
    var entries = logEntries(r);
    if (entries.len == 0) try ctx.out.writeAll("No log entries\n");
    // The last N entries, oldest first (0 = all).
    if (limit > 0 and entries.len > limit) entries = entries[entries.len - limit ..];
    for (entries) |e| try writeLogLine(ctx.out, e);
    return output.exit.ok;
}

// ----- sidebar-state -----

/// Max log lines `sidebar-state` prints (cmux).
pub const state_log_lines = 5;

fn writeKey(w: *std.Io.Writer, key: []const u8, v: ?[]const u8, fallback: []const u8) std.Io.Writer.Error!void {
    try w.print("{s}=", .{key});
    try writeSafe(w, v orelse fallback);
    try w.writeByte('\n');
}

fn writeNumber(w: *std.Io.Writer, v: std.json.Value) std.Io.Writer.Error!bool {
    switch (v) {
        .integer => |n| try w.print("{d}", .{n}),
        .float => |f| if (std.math.isFinite(f)) try w.print("{d}", .{@as(i64, @intFromFloat(@max(@min(f, 9e18), -9e18)))}) else return false,
        .string, .number_string => |x| try writeSafe(w, x),
        else => return false,
    }
    return true;
}

/// Renders the `wmux.sidebar.state` result as cmux's `sidebar_state`
/// key=value dump (see the module notes in REPORT for the result keys).
pub fn writeSidebarState(w: *std.Io.Writer, r: std.json.Value) std.Io.Writer.Error!void {
    try writeKey(w, "tab", common.strField(r, "workspace_id") orelse common.strField(r, "workspace_ref"), "unknown");
    try writeKey(w, "color", common.strField(r, "color"), "none");
    try writeKey(w, "cwd", common.strField(r, "cwd"), "");
    try writeKey(w, "focused_cwd", common.strField(r, "focused_cwd"), "unknown");
    try writeKey(w, "focused_panel", common.strField(r, "focused_surface_id") orelse common.strField(r, "focused_panel"), "unknown");

    try w.writeAll("git_branch=");
    const gb = common.field(r, "git_branch");
    const branch: ?[]const u8 = if (gb) |g| switch (g) {
        .string => |x| if (x.len > 0) x else null,
        .object => common.strField(g, "name") orelse common.strField(g, "branch"),
        else => null,
    } else null;
    if (branch) |name| {
        const dirty = (if (gb.? == .object) common.boolField(gb.?, "dirty") else null) orelse common.boolField(r, "git_dirty") orelse false;
        try writeSafe(w, name);
        try w.writeAll(if (dirty) " dirty\n" else " clean\n");
    } else try w.writeAll("none\n");

    try w.writeAll("pr=");
    const prv = common.field(r, "pr");
    if (prv != null and prv.? == .object and common.field(prv.?, "number") != null) {
        try w.writeByte('#');
        if (!try writeNumber(w, common.field(prv.?, "number").?)) try w.writeByte('?');
        try w.writeByte(' ');
        try writeSafe(w, common.strField(prv.?, "state") orelse "open");
        try w.writeByte(' ');
        try writeSafe(w, common.strField(prv.?, "url") orelse "");
        try w.writeByte('\n');
    } else try w.writeAll("none\n");
    try writeKey(w, "pr_label", common.strField(r, "pr_label") orelse (if (prv != null) common.strField(prv.?, "label") else null), "none");

    try w.writeAll("ports=");
    const ports = common.arrayField(r, "ports") orelse &.{};
    var n_ports: usize = 0;
    for (ports) |port| {
        if (n_ports > 0) try w.writeByte(',');
        if (try writeNumber(w, port)) n_ports += 1;
    }
    try w.writeAll(if (n_ports == 0) "none\n" else "\n");

    try w.writeAll("progress=");
    const prog = common.field(r, "progress");
    const pval: ?f64 = if (prog) |pg| switch (pg) {
        .object => if (common.field(pg, "value")) |x| switch (x) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        } else null,
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    } else null;
    if (pval) |v| {
        try w.print("{d:.2}", .{if (std.math.isFinite(v)) std.math.clamp(v, 0.0, 1.0) else 0.0});
        if (common.strField(prog.?, "label") orelse common.strField(r, "progress_label")) |l| {
            try w.writeByte(' ');
            try writeSafe(w, l);
        }
        try w.writeByte('\n');
    } else try w.writeAll("none\n");

    const statuses = common.firstArray(r, &.{ "status", "statuses", "status_entries" });
    try w.print("status_count={d}\n", .{statuses.len});
    for (statuses) |e| {
        try w.writeAll("  ");
        try writeStatusLine(w, e);
    }
    const blocks = common.firstArray(r, &.{"meta_blocks"});
    try w.print("meta_block_count={d}\n", .{blocks.len});
    for (blocks) |blk| {
        try w.writeAll("  ");
        switch (blk) {
            .string => |x| try writeSafe(w, x),
            else => try writeSafe(w, common.strField(blk, "text") orelse common.strField(blk, "markdown") orelse common.strField(blk, "key") orelse ""),
        }
        try w.writeByte('\n');
    }
    const logs = common.firstArray(r, &.{ "log", "logs", "log_entries" });
    try w.print("log_count={d}\n", .{logs.len});
    const tail = if (logs.len > state_log_lines) logs[logs.len - state_log_lines ..] else logs;
    for (tail) |e| {
        try w.writeAll("  [");
        try writeSafe(w, common.strField(e, "level") orelse "info");
        try w.writeAll("] ");
        try writeSafe(w, common.strField(e, "message") orelse "");
        try w.writeByte('\n');
    }
}

fn runSidebarState(ctx: *Ctx) !u8 {
    var code: u8 = 0;
    var b = (try begin(ctx, "sidebar-state", &.{}, &code)) orelse return code;
    if (noPositionals(ctx, "sidebar-state", b.s)) |c| return c;
    const r = (try common.request(ctx, "wmux.sidebar.state", &b.p)) orelse return output.exit.runtime;
    if (ctx.json()) return common.printOk(ctx, r);
    try writeSidebarState(ctx.out, r);
    return output.exit.ok;
}

test {
    _ = @import("notify/sidebar_tests.zig");
}
