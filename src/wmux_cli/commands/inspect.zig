//! `system` family extras (WP CLI-fam-ps): `tree` (`system.tree`), `top`
//! (`system.top`), `memory` (`system.memory`), `shot`/`screenshot`
//! (`window.screenshot`) and the `identify` flags. system.zig registers the
//! commands; the parsing, requests and text renderers live here.

const std = @import("std");
const command = @import("../command.zig");
const Ctx = command.Ctx;
const output = @import("../output.zig");
const brand_mod = @import("../brand.zig");
const ps = @import("ps_common.zig");
const usageOf = @import("pane_surface.zig").usageOf;
const Opts = ps.Opts;
const Params = ps.Params;
const Value = std.json.Value;
const Writer = std.Io.Writer;

fn unexpected(ctx: *Ctx, usage: []const u8, arg: []const u8) u8 {
    return ps.usageWithLine(ctx, usage, "unexpected argument '{s}'", .{arg});
}

/// `--window` with `--all` is an error for tree and top.
fn checkAllWindow(ctx: *Ctx, usage: []const u8, o: Opts) bool {
    if (o.has("--all") and ps.windowText(ctx, o) != null) {
        _ = ps.usageWithLine(ctx, usage, "--window cannot be combined with --all", .{});
        return false;
    }
    return true;
}

/// all_windows, window_id, workspace_id (no caller defaults: the scope is
/// the current window) and the caller.
fn scopeParams(ctx: *Ctx, p: *Params, o: Opts) !bool {
    if (o.has("--all")) try p.boolean("all_windows", true);
    if (ps.windowText(ctx, o)) |w| if (!try ps.putHandle(ctx, p, "window_id", .window, w)) return false;
    if (o.get(&.{"--workspace"})) |w| if (!try ps.putHandle(ctx, p, "workspace_id", .workspace, w)) return false;
    return true;
}

// ----- identify -----

pub const identify_usage = "Usage: cmux identify";

/// `identify [--workspace <h>] [--surface <h>] [--window <h>] [--no-caller]`.
/// Without flags the params are `{"caller":{...}}` from the environment.
pub fn identifyParams(ctx: *Ctx) !?Params {
    const o = (try ps.parseArgs(ctx, identify_usage, .{
        .values = &.{ "--workspace", "--surface", "--window" },
        .bools = &.{"--no-caller"},
    })) orelse return null;
    if (o.positionals.len > 0) {
        _ = unexpected(ctx, identify_usage, o.positionals[0]);
        return null;
    }
    var p = Params.init(ctx.arena);
    if (ps.windowText(ctx, o)) |w| if (!try ps.putHandle(ctx, &p, "window_id", .window, w)) return null;
    if (o.has("--no-caller")) return p;
    const ws_flag = o.get(&.{"--workspace"});
    const sf_flag = o.get(&.{"--surface"});
    var caller = Params.init(ctx.arena);
    if (ws_flag) |w| {
        if (!try ps.putHandle(ctx, &caller, "workspace_id", .workspace, w)) return null;
    } else if (ps.envWorkspace(ctx)) |w| try caller.str("workspace_id", w);
    if (sf_flag) |s| {
        if (!try ps.putHandle(ctx, &caller, "surface_id", .surface, s)) return null;
    } else if (ws_flag == null) if (ps.envSurface(ctx)) |s| try caller.str("surface_id", s);
    if (caller.map.count() > 0) try p.value("caller", .{ .object = caller.map });
    return p;
}

// ----- tree -----

pub const tree_usage = usageOf("tree");

pub fn runTree(ctx: *Ctx) !u8 {
    const o = (try ps.parseArgs(ctx, tree_usage, .{ .values = &.{ "--workspace", "--window" }, .bools = &.{"--all"} })) orelse return output.exit.usage;
    if (o.positionals.len > 0) return unexpected(ctx, tree_usage, o.positionals[0]);
    if (!checkAllWindow(ctx, tree_usage, o)) return output.exit.usage;
    var p = Params.init(ctx.arena);
    if (!try scopeParams(ctx, &p, o)) return output.exit.usage;
    try ps.addCaller(ctx, &p);
    return ps.callRender(ctx, "system.tree", &p, renderTree);
}

/// Same object: equal ids (case-insensitive) or, without ids, equal refs.
fn sameObject(node: Value, ctx_obj: ?Value, kind: []const u8) bool {
    const c = ctx_obj orelse return false;
    var kb: [32]u8 = undefined;
    var rb: [32]u8 = undefined;
    const id_key = std.fmt.bufPrint(&kb, "{s}_id", .{kind}) catch return false;
    const ref_key = std.fmt.bufPrint(&rb, "{s}_ref", .{kind}) catch return false;
    if (ps.getStr(node, "id")) |id| if (ps.getStr(c, id_key)) |cid| return std.ascii.eqlIgnoreCase(id, cid);
    if (ps.getStr(node, "ref")) |r| if (ps.getStr(c, ref_key)) |cr| return std.mem.eql(u8, r, cr);
    return false;
}

const TreeState = struct {
    ctx: *Ctx,
    active: ?Value,
    caller: ?Value,
    /// Box-drawing prefix of the current depth.
    prefix: std.ArrayList(u8) = .empty,
};

fn nonNull(v: ?Value) ?Value {
    const x = v orelse return null;
    return if (x == .null) null else x;
}

/// Writes one node line at the current depth: `<prefix><connector><text>`.
fn treeLine(st: *TreeState, is_last: bool, root: bool, text: []const u8) !void {
    const w = st.ctx.out;
    try w.writeAll(st.prefix.items);
    if (!root) try w.writeAll(if (is_last) "\u{2514}\u{2500}\u{2500} " else "\u{251c}\u{2500}\u{2500} ");
    try w.writeAll(text);
    try w.writeByte('\n');
}

/// Runs `children` one level deeper (`│   ` or four spaces).
fn push(st: *TreeState, is_last: bool, root: bool) !usize {
    const len = st.prefix.items.len;
    if (!root) try st.prefix.appendSlice(st.ctx.arena, if (is_last) "    " else "\u{2502}   ");
    return len;
}

fn handleText(ctx: *Ctx, v: Value, tab: bool) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(ctx.arena);
    if (!try ps.writeHandle(ctx, &aw.writer, v, null, tab)) try aw.writer.writeAll("?");
    return aw.written();
}

fn dockTag(w: *Writer, v: Value) !void {
    if (ps.getStr(v, "dock")) |d| {
        try w.writeAll(" [dock:");
        try ps.writeClean(w, d);
        try w.writeByte(']');
    }
}

const health_tags = [_][]const u8{ "awaiting_frame", "not_rendering", "shell_exited" };

fn surfaceText(st: *TreeState, s: Value) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(st.ctx.arena);
    const w = &aw.writer;
    try w.print("surface {s}", .{try handleText(st.ctx, s, false)});
    if (ps.getStr(s, "type")) |t| {
        try w.writeAll(" [");
        try ps.writeClean(w, t);
        try w.writeByte(']');
    }
    try dockTag(w, s);
    try w.writeByte(' ');
    try ps.writeQuoted(w, ps.getStr(s, "title") orelse "");
    if (ps.getBool(s, "selected_in_pane") or ps.getBool(s, "selected")) try w.writeAll(" [selected]");
    if (sameObject(s, st.active, "surface")) try w.writeAll(" \u{25c0} active");
    if (sameObject(s, st.caller, "surface")) try w.writeAll(" \u{25c0} here");
    if (ps.getStr(s, "tty")) |t| {
        try w.writeAll(" tty=");
        try ps.writeClean(w, t);
    }
    if (ps.getStr(s, "render_health")) |hl| for (health_tags) |tag| {
        if (std.mem.eql(u8, hl, tag)) try w.print(" [{s}]", .{tag});
    };
    if (ps.getStr(s, "url")) |u| {
        try w.writeByte(' ');
        try ps.writeClean(w, u);
    }
    return aw.written();
}

/// Box-drawing tree of window > workspace > pane > surface with the
/// `◀ active` (focus path) and `◀ here` (caller surface) markers.
pub fn renderTree(ctx: *Ctx, result: Value) anyerror!void {
    const windows = ps.getArr(result, "windows");
    if (windows.len == 0) return ctx.out.writeAll("No windows\n");
    var st: TreeState = .{ .ctx = ctx, .active = nonNull(ps.get(result, "active")), .caller = nonNull(ps.get(result, "caller")) };
    for (windows) |win| {
        var aw: std.Io.Writer.Allocating = .init(ctx.arena);
        try aw.writer.print("window {s}", .{try handleText(ctx, win, false)});
        const active_win = sameObject(win, st.active, "window");
        const current = if (ps.get(win, "current")) |c| (c == .bool and c.bool) else active_win;
        if (current) try aw.writer.writeAll(" [current]");
        if (active_win) try aw.writer.writeAll(" \u{25c0} active");
        try treeLine(&st, true, true, aw.written());
        const workspaces = ps.getArr(win, "workspaces");
        for (workspaces, 0..) |ws, wi| {
            const ws_last = wi + 1 == workspaces.len;
            var wa: std.Io.Writer.Allocating = .init(ctx.arena);
            try wa.writer.print("workspace {s} ", .{try handleText(ctx, ws, false)});
            try ps.writeQuoted(&wa.writer, ps.getStr(ws, "title") orelse "");
            if (ps.getBool(ws, "selected")) try wa.writer.writeAll(" [selected]");
            if (sameObject(ws, st.active, "workspace")) try wa.writer.writeAll(" \u{25c0} active");
            try treeLine(&st, ws_last, false, wa.written());
            const ws_mark = try push(&st, ws_last, false);
            const panes = ps.getArr(ws, "panes");
            for (panes, 0..) |pane, pi| {
                const pane_last = pi + 1 == panes.len;
                var pa: std.Io.Writer.Allocating = .init(ctx.arena);
                try pa.writer.print("pane {s}", .{try handleText(ctx, pane, false)});
                try dockTag(&pa.writer, pane);
                if (ps.getBool(pane, "focused")) try pa.writer.writeAll(" [focused]");
                if (sameObject(pane, st.active, "pane")) try pa.writer.writeAll(" \u{25c0} active");
                try treeLine(&st, pane_last, false, pa.written());
                const pane_mark = try push(&st, pane_last, false);
                const surfaces = ps.getArr(pane, "surfaces");
                for (surfaces, 0..) |s, si| try treeLine(&st, si + 1 == surfaces.len, false, try surfaceText(&st, s));
                st.prefix.shrinkRetainingCapacity(pane_mark);
            }
            st.prefix.shrinkRetainingCapacity(ws_mark);
        }
    }
}

// ----- top -----

pub const top_usage = usageOf("top");
pub const top_unsupported = "cmux top requires a running cmux build that supports process diagnostics";

pub const SortKey = enum { none, cpu, mem, proc };

/// One `top` row: an object of the result with its kind and depth.
const Row = struct { kind: []const u8, depth: usize, node: Value };

/// Child arrays per kind, in walk order (assumed `system.top` shape:
/// windows > workspaces > panes > surfaces > processes > children, every
/// node with `cpu_percent`, `rss_bytes` and `process_count`).
const child_keys = [_]struct { key: []const u8, kind: []const u8 }{
    .{ .key = "windows", .kind = "window" },
    .{ .key = "workspaces", .kind = "workspace" },
    .{ .key = "panes", .kind = "pane" },
    .{ .key = "surfaces", .kind = "surface" },
    .{ .key = "webviews", .kind = "webview" },
    .{ .key = "processes", .kind = "process" },
    .{ .key = "children", .kind = "process" },
};

fn sortValue(v: Value, key: SortKey) f64 {
    return switch (key) {
        .none => 0,
        .cpu => ps.getNum(v, "cpu_percent") orelse 0,
        .mem => ps.getNum(v, "rss_bytes") orelse 0,
        .proc => ps.getNum(v, "process_count") orelse 0,
    };
}

fn sortedChildren(ctx: *Ctx, items: []const Value, key: SortKey) ![]const Value {
    if (key == .none) return items;
    const copy = try ctx.arena.dupe(Value, items);
    std.mem.sort(Value, copy, key, struct {
        fn lt(k: SortKey, a: Value, b: Value) bool {
            return sortValue(a, k) > sortValue(b, k);
        }
    }.lt);
    return copy;
}

fn collectRows(ctx: *Ctx, rows: *std.ArrayList(Row), node: Value, depth: usize, key: SortKey, processes: bool) !void {
    for (child_keys) |ck| {
        if (!processes and std.mem.eql(u8, ck.kind, "process")) continue;
        for (try sortedChildren(ctx, ps.getArr(node, ck.key), key)) |child| {
            try rows.append(ctx.arena, .{ .kind = ck.kind, .depth = depth, .node = child });
            try collectRows(ctx, rows, child, depth + 1, key, processes);
        }
    }
}

/// `<kind> <handle-or-pid> ["title"|name]` for a row.
fn rowName(ctx: *Ctx, w: *Writer, row: Row) !void {
    try w.print("{s} ", .{row.kind});
    if (std.mem.eql(u8, row.kind, "process")) {
        if (ps.getNum(row.node, "pid")) |pid| try w.print("{d}", .{ps.toInt(pid)});
        if (ps.getStr(row.node, "name")) |n| {
            try w.writeByte(' ');
            try ps.writeClean(w, n);
        }
        return;
    }
    if (!try ps.writeHandle(ctx, w, row.node, null, false)) try ps.writeClean(w, ps.getStr(row.node, "name") orelse "?");
    if (ps.getStr(row.node, "title")) |t| {
        try w.writeByte(' ');
        try ps.writeQuoted(w, t);
    }
}

pub fn runTop(ctx: *Ctx) !u8 {
    const o = (try ps.parseArgs(ctx, top_usage, .{
        .values = &.{ "--workspace", "--window", "--sort", "--format" },
        .bools = &.{ "--all", "--processes", "--flat" },
    })) orelse return output.exit.usage;
    if (o.positionals.len > 0) return unexpected(ctx, top_usage, o.positionals[0]);
    if (!checkAllWindow(ctx, top_usage, o)) return output.exit.usage;
    const sort: SortKey = if (o.get(&.{"--sort"})) |s|
        std.meta.stringToEnum(SortKey, s) orelse return ps.usageWithLine(ctx, top_usage, "--sort must be cpu, mem or proc", .{})
    else
        .none;
    if (sort == .none and o.get(&.{"--sort"}) != null) return ps.usageWithLine(ctx, top_usage, "--sort must be cpu, mem or proc", .{});
    const format = o.get(&.{"--format"}) orelse "tree";
    const tsv = std.mem.eql(u8, format, "tsv");
    if (!tsv and !std.mem.eql(u8, format, "tree")) return ps.usageWithLine(ctx, top_usage, "--format must be tree or tsv", .{});
    var p = Params.init(ctx.arena);
    if (!try scopeParams(ctx, &p, o)) return output.exit.usage;
    if (o.has("--processes")) try p.boolean("include_processes", true);
    try ps.addCaller(ctx, &p);
    const out = (try ctx.call("system.top", try p.json(ctx.arena))) orelse return output.exit.runtime;
    switch (out) {
        .ok => |ok| {
            if (ctx.json()) {
                try output.writeResult(ctx.arena, ctx.out, ok.result, ctx.parsed.globals.id_format);
                return output.exit.ok;
            }
            try writeTop(ctx, ok.result, .{ .sort = sort, .flat = tsv or o.has("--flat"), .tsv = tsv, .processes = o.has("--processes") });
            return output.exit.ok;
        },
        .rpc_error => |e| if (e.err.known == .method_not_found) {
            try brand_mod.write(ctx.err, ctx.brand, top_unsupported ++ "\n");
            return output.exit.runtime;
        },
        .failure => {},
    }
    return ctx.reportError("system.top", out);
}

pub const TopOptions = struct { sort: SortKey = .none, flat: bool = false, tsv: bool = false, processes: bool = false };

const name_width = 48;

/// TSV field text: tabs and control characters become spaces.
fn writeField(w: *Writer, s: []const u8) !void {
    for (s) |c| try w.writeByte(if (c < 0x20 or c == 0x7f) ' ' else c);
}

fn writeNum(w: *Writer, v: ?f64, comptime frac: bool) !void {
    const x = v orelse return;
    if (frac) try w.print("{d:.1}", .{x}) else try w.print("{d}", .{@max(ps.toInt(x), 0)});
}

/// Text (`--format tree`, indented unless `--flat`) or TSV rows of CPU%,
/// RSS and process count per window, workspace, pane, surface (and
/// processes with `--processes`), headed by the app itself.
pub fn writeTop(ctx: *Ctx, result: Value, opts: TopOptions) !void {
    const w = ctx.out;
    var rows: std.ArrayList(Row) = .empty;
    if (ps.get(result, "app")) |app| if (app == .object) try rows.append(ctx.arena, .{ .kind = "app", .depth = 0, .node = app });
    try collectRows(ctx, &rows, result, 0, opts.sort, opts.processes);
    if (opts.flat and opts.sort != .none) {
        std.mem.sort(Row, rows.items, opts.sort, struct {
            fn lt(k: SortKey, a: Row, b: Row) bool {
                return sortValue(a.node, k) > sortValue(b.node, k);
            }
        }.lt);
    }
    if (opts.tsv) {
        try w.writeAll("kind\thandle\tname\tcpu_percent\trss_bytes\tprocess_count\n");
        for (rows.items) |row| {
            try w.print("{s}\t", .{row.kind});
            if (std.mem.eql(u8, row.kind, "process")) {
                try writeNum(w, ps.getNum(row.node, "pid"), false);
            } else _ = try ps.writeHandle(ctx, w, row.node, null, false);
            try w.writeByte('\t');
            try writeField(w, ps.getStr(row.node, "title") orelse ps.getStr(row.node, "name") orelse "");
            try w.writeByte('\t');
            try writeNum(w, ps.getNum(row.node, "cpu_percent"), true);
            try w.writeByte('\t');
            try writeNum(w, ps.getNum(row.node, "rss_bytes"), false);
            try w.writeByte('\t');
            try writeNum(w, ps.getNum(row.node, "process_count"), false);
            try w.writeByte('\n');
        }
        return;
    }
    if (rows.items.len == 0) return w.writeAll("No windows\n");
    try w.print("{s: <48}  {s: >6}  {s: >10}  {s: >5}\n", .{ "NAME", "CPU%", "RSS", "PROCS" });
    for (rows.items) |row| {
        var aw: std.Io.Writer.Allocating = .init(ctx.arena);
        if (!opts.flat) try aw.writer.splatByteAll(' ', 2 * row.depth);
        if (std.mem.eql(u8, row.kind, "app")) {
            try aw.writer.writeAll("app ");
            try ps.writeClean(&aw.writer, ps.getStr(row.node, "name") orelse "wmux");
        } else try rowName(ctx, &aw.writer, row);
        const name = aw.written();
        const cols = std.unicode.utf8CountCodepoints(name) catch name.len;
        try w.writeAll(name);
        try w.splatByteAll(' ', if (cols < name_width) name_width - cols else 0);
        if (ps.getNum(row.node, "cpu_percent")) |c| try w.print("  {d: >6.1}", .{c}) else try w.print("  {s: >6}", .{"-"});
        var rb: std.Io.Writer.Allocating = .init(ctx.arena);
        if (ps.getNum(row.node, "rss_bytes")) |r| try ps.writeBytes(&rb.writer, r) else try rb.writer.writeAll("-");
        try w.print("  {s: >10}", .{rb.written()});
        if (ps.getNum(row.node, "process_count")) |n| try w.print("  {d: >5}", .{@max(ps.toInt(n), 0)}) else try w.print("  {s: >5}", .{"-"});
        try w.writeByte('\n');
    }
}

// ----- memory -----

pub const memory_usage = usageOf("memory");
pub const memory_unsupported = "cmux memory requires a running cmux build that supports process diagnostics";

pub fn runMemory(ctx: *Ctx) !u8 {
    const o = (try ps.parseArgs(ctx, memory_usage, .{ .values = &.{ "--workspace", "--limit" }, .bools = &.{"--all"} })) orelse return output.exit.usage;
    if (o.positionals.len > 0) return unexpected(ctx, memory_usage, o.positionals[0]);
    var p = Params.init(ctx.arena);
    if (o.has("--all")) try p.boolean("all_windows", true);
    if (o.get(&.{"--workspace"})) |w| if (!try ps.putHandle(ctx, &p, "workspace_id", .workspace, w)) return output.exit.usage;
    if (o.get(&.{"--limit"})) |l| {
        const n = std.fmt.parseInt(i64, l, 10) catch -1;
        if (n < 1) return ps.usageWithLine(ctx, memory_usage, "--limit must be a positive integer", .{});
        try p.int("top_group_limit", n);
    }
    try ps.addCaller(ctx, &p);
    const out = (try ctx.call("system.memory", try p.json(ctx.arena))) orelse return output.exit.runtime;
    switch (out) {
        .ok => |ok| {
            if (ctx.json()) {
                try output.writeResult(ctx.arena, ctx.out, ok.result, ctx.parsed.globals.id_format);
            } else try renderMemory(ctx, ok.result);
            return output.exit.ok;
        },
        .rpc_error => |e| if (e.err.known == .method_not_found) {
            try brand_mod.write(ctx.err, ctx.brand, memory_unsupported ++ "\n");
            return output.exit.runtime;
        },
        .failure => {},
    }
    return ctx.reportError("system.memory", out);
}

fn memLine(w: *Writer, label: []const u8, bytes: ?f64, procs: ?f64) !void {
    try w.print("{s: <22}", .{label});
    if (bytes) |b| try ps.writeBytes(w, b) else try w.writeAll("-");
    if (procs) |n| {
        const c = @max(ps.toInt(n), 0);
        try w.print(" in {d} {s}", .{ c, if (c == 1) "process" else "processes" });
    }
    try w.writeByte('\n');
}

/// The app's own footprint and its WebView2 processes, apart from the
/// recursive RSS of terminal child processes, then the heaviest groups
/// (assumed `system.memory` shape: `app {footprint_bytes, webview_bytes,
/// webview_process_count}`, `children {rss_bytes, process_count}`,
/// `groups [{kind, id, ref, title, rss_bytes, process_count}]`).
pub fn renderMemory(ctx: *Ctx, result: Value) !void {
    const w = ctx.out;
    const app = ps.get(result, "app") orelse .null;
    const children = ps.get(result, "children") orelse .null;
    try memLine(w, "App footprint:", ps.getNum(app, "footprint_bytes"), null);
    if (ps.getNum(app, "webview_bytes")) |b| try memLine(w, "WebView2 processes:", b, ps.getNum(app, "webview_process_count"));
    try memLine(w, "Terminal children:", ps.getNum(children, "rss_bytes"), ps.getNum(children, "process_count"));
    const groups = ps.getArr(result, "groups");
    if (groups.len == 0) return;
    try w.writeAll("Top groups:\n");
    for (groups) |g| {
        var aw: std.Io.Writer.Allocating = .init(ctx.arena);
        try aw.writer.writeAll("  ");
        if (ps.getStr(g, "kind")) |k| {
            try ps.writeClean(&aw.writer, k);
            try aw.writer.writeByte(' ');
        }
        if (!try ps.writeHandle(ctx, &aw.writer, g, null, false)) try aw.writer.writeAll("?");
        if (ps.getStr(g, "title")) |t| {
            try aw.writer.writeByte(' ');
            try ps.writeQuoted(&aw.writer, t);
        }
        try w.writeAll(aw.written());
        try w.writeAll("  ");
        if (ps.getNum(g, "rss_bytes")) |b| try ps.writeBytes(w, b) else try w.writeAll("-");
        if (ps.getNum(g, "process_count")) |n| {
            const c = @max(ps.toInt(n), 0);
            try w.print(" in {d} {s}", .{ c, if (c == 1) "process" else "processes" });
        }
        try w.writeByte('\n');
    }
}

// ----- shot / screenshot -----

pub const shot_usage = usageOf("shot");
/// cmux's client timeout for `window.screenshot`.
pub const shot_timeout_ms = 45_000;

fn floatFlag(ctx: *Ctx, o: Opts, name: []const u8) !?f64 {
    const t = o.get(&.{name}) orelse return null;
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " \t")) catch {
        _ = ps.usageWithLine(ctx, shot_usage, "{s} must be a number", .{name});
        return error.Usage;
    };
    if (!std.math.isFinite(v)) {
        _ = ps.usageWithLine(ctx, shot_usage, "{s} must be a number", .{name});
        return error.Usage;
    }
    return v;
}

/// `--region x,y,w,h` in window points (width and height > 0).
pub fn parseRegion(s: []const u8) ?[4]f64 {
    var out: [4]f64 = undefined;
    var it = std.mem.splitScalar(u8, s, ',');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n == 4) return null;
        out[n] = std.fmt.parseFloat(f64, std.mem.trim(u8, part, " \t")) catch return null;
        if (!std.math.isFinite(out[n])) return null;
    }
    if (n != 4 or out[2] <= 0 or out[3] <= 0) return null;
    return out;
}

pub fn runShot(ctx: *Ctx) !u8 {
    const o = (try ps.parseArgs(ctx, shot_usage, .{
        .values = &.{ "--format", "--scale", "--max-width", "--quality", "--region", "--out", "--label", "--caption", "--window" },
        .bools = &.{"--jpg"},
    })) orelse return output.exit.usage;
    if (o.positionals.len > 0) {
        const rest = try std.mem.join(ctx.arena, " ", o.positionals);
        return ps.usageWithLine(ctx, shot_usage, "shot: unexpected arguments: {s}", .{rest});
    }
    var format: ?[]const u8 = o.get(&.{"--format"});
    if (format) |f| if (!(std.mem.eql(u8, f, "png") or std.mem.eql(u8, f, "jpg")))
        return ps.usageWithLine(ctx, shot_usage, "--format must be png or jpg", .{});
    if (o.has("--jpg")) {
        if (format) |f| if (!std.mem.eql(u8, f, "jpg")) return ps.usageWithLine(ctx, shot_usage, "--jpg conflicts with --format {s}", .{f});
        format = "jpg";
    }
    const scale = floatFlag(ctx, o, "--scale") catch return output.exit.usage;
    const quality = floatFlag(ctx, o, "--quality") catch return output.exit.usage;
    var p = Params.init(ctx.arena);
    if (format) |f| try p.str("format", f);
    if (scale) |v| try p.float("scale", v);
    if (o.get(&.{"--max-width"})) |t| {
        const n = std.fmt.parseInt(i64, std.mem.trim(u8, t, " \t"), 10) catch
            return ps.usageWithLine(ctx, shot_usage, "--max-width must be an integer", .{});
        try p.int("max_width", n);
    }
    if (quality) |v| try p.float("quality", v);
    if (o.get(&.{"--region"})) |r| {
        const reg = parseRegion(r) orelse return ps.usageWithLine(ctx, shot_usage, "--region must be x,y,w,h with a positive width and height", .{});
        var m = std.json.ObjectMap.init(ctx.arena);
        for ([_][]const u8{ "x", "y", "width", "height" }, reg) |k, v| try m.put(k, .{ .float = v });
        try p.value("region", .{ .object = m });
    }
    if (o.get(&.{"--label"})) |l| try p.str("label", l);
    if (o.get(&.{"--caption"})) |c| try p.str("caption", c);
    if (o.get(&.{"--out"})) |path| {
        if (path.len == 0) return ps.usageWithLine(ctx, shot_usage, "--out requires a path", .{});
        // The app writes the file: send an absolute path.
        const abs = if (std.fs.path.isAbsolute(path)) path else if (ctx.platform.cwd(ctx.arena)) |cwd|
            try std.fs.path.join(ctx.arena, &.{ cwd, path })
        else
            path;
        try p.str("out", abs);
    }
    if (ps.windowText(ctx, o)) |w| if (!try ps.putHandle(ctx, &p, "window", .window, w)) return output.exit.usage;
    const client = (try ctx.connect()) orelse return output.exit.runtime;
    client.opts.response_timeout_ms = @max(client.opts.response_timeout_ms, shot_timeout_ms);
    return ps.callRender(ctx, "window.screenshot", &p, renderShot);
}

/// `<width>x<height> <bytes> <path>`.
pub fn renderShot(ctx: *Ctx, result: Value) anyerror!void {
    const w = ctx.out;
    const width = ps.toInt(ps.getNum(result, "width") orelse 0);
    const height = ps.toInt(ps.getNum(result, "height") orelse 0);
    const bytes = ps.toInt(ps.getNum(result, "bytes") orelse 0);
    try w.print("{d}x{d} {d} ", .{ width, height, bytes });
    try ps.writeClean(w, ps.getStr(result, "path") orelse "");
    try w.writeByte('\n');
}

// ----- tests -----

const testing = std.testing;
const pt = @import("ps_testing.zig");
const Harness = pt.Harness;

test "unit: cli-ps: inspect --help works offline and matches goldens" {
    try pt.expectHelpGoldens(&.{ "identify", "tree", "top", "memory", "shot", "screenshot" });
}

test "unit: cli-ps: identify flags build window, caller and no-caller params" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.setEnv("CMUX_WORKSPACE_ID", "WS-UUID");
    h.setEnv("CMUX_SURFACE_ID", "SF-UUID");
    try pt.expectOk(h.run(&.{ "cmux", "identify" }));
    try h.expectLast("system.identify", "{\"caller\":{\"workspace_id\":\"WS-UUID\",\"surface_id\":\"SF-UUID\"}}");
    _ = h.run(&.{ "cmux", "identify", "--no-caller" });
    try h.expectLast("system.identify", "{}");
    _ = h.run(&.{ "cmux", "identify", "--window", "window:2", "--surface", "surface:3" });
    try h.expectLast("system.identify", "{\"window_id\":\"window:2\",\"caller\":{\"workspace_id\":\"WS-UUID\",\"surface_id\":\"surface:3\"}}");
    _ = h.run(&.{ "cmux", "identify", "--workspace", "1" });
    try h.expectLast("system.identify", "{\"caller\":{\"workspace_id\":1}}");
    _ = h.run(&.{ "cmux", "--window", "window:1", "identify" });
    try h.expectLast("system.identify", "{\"window_id\":\"window:1\",\"caller\":{\"workspace_id\":\"WS-UUID\",\"surface_id\":\"SF-UUID\"}}");
    try pt.expectUsage(h.run(&.{ "cmux", "identify", "extra" }), "unexpected argument 'extra'");
    try pt.expectUsage(h.run(&.{ "cmux", "identify", "--surface", "pane:1" }), "Invalid surface handle: pane:1");
    try pt.expectUsage(h.run(&.{ "cmux", "identify", "--bogus" }), "unknown flag '--bogus'");
}

const tree_result =
    \\{"active":{"window_id":"W1","workspace_id":"WS1","pane_id":"P1","surface_id":"S1"},
    \\ "caller":{"workspace_id":"WS1","surface_id":"s2"},
    \\ "windows":[
    \\  {"id":"W1","ref":"window:1","index":0,"workspaces":[
    \\   {"id":"WS1","ref":"workspace:1","title":"api","selected":true,"panes":[
    \\    {"id":"P1","ref":"pane:1","focused":true,"surfaces":[
    \\     {"id":"S1","ref":"surface:1","type":"terminal","title":"zsh","selected_in_pane":true,"tty":"pid:4242"},
    \\     {"id":"S2","ref":"surface:2","type":"browser","title":"Docs \u001b[2J","url":"https://example.com/docs"}]},
    \\    {"id":"P2","ref":"pane:2","dock":"workspace","surfaces":[
    \\     {"id":"S3","ref":"surface:3","type":"terminal","title":"日本","render_health":"shell_exited"}]}]},
    \\   {"id":"WS2","ref":"workspace:2","title":"web","panes":[]}]},
    \\  {"id":"W2","ref":"window:2","index":1,"workspaces":[
    \\   {"id":"WS3","ref":"workspace:3","title":"","panes":[{"id":"P3","ref":"pane:3","surfaces":[]}]}]}]}
;

test "unit: cli-ps: tree params, markers and box drawing" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.setEnv("CMUX_WORKSPACE_ID", "WS1");
    h.setEnv("CMUX_SURFACE_ID", "s2");
    h.ok("system.tree", tree_result);
    const r = h.run(&.{ "cmux", "tree", "--all" });
    try pt.expectOk(r);
    try h.expectLast("system.tree", "{\"all_windows\":true,\"caller\":{\"workspace_id\":\"WS1\",\"surface_id\":\"s2\"}}");
    try pt.expectGolden(h.alloc(), "tree.txt", r.out);
    try pt.expectContains(r.out, "\"Docs  [2J\" \u{25c0} here https://example.com/docs");
    _ = h.run(&.{ "cmux", "tree", "--workspace", "workspace:2", "--window", "window:1" });
    try h.expectLast("system.tree", "{\"window_id\":\"window:1\",\"workspace_id\":\"workspace:2\",\"caller\":{\"workspace_id\":\"WS1\",\"surface_id\":\"s2\"}}");
    const j = h.run(&.{ "cmux", "--json", "tree", "--all" });
    try pt.expectContains(j.out, "\"ref\": \"window:2\"");
    h.ok("system.tree", "{\"active\":null,\"caller\":null,\"windows\":[]}");
    try testing.expectEqualStrings("No windows\n", h.run(&.{ "cmux", "tree" }).out);
    h.clearRequests();
    try pt.expectUsage(h.run(&.{ "cmux", "tree", "--all", "--window", "1" }), "--window cannot be combined with --all");
    try pt.expectUsage(h.run(&.{ "cmux", "--window", "1", "tree", "--all" }), "--window cannot be combined with --all");
    try pt.expectUsage(h.run(&.{ "cmux", "tree", "x" }), "unexpected argument 'x'");
    try testing.expectEqual(@as(usize, 0), h.requests().len);
}

const top_result =
    \\{"app":{"name":"wmux","cpu_percent":1.5,"rss_bytes":125829120,"process_count":3},
    \\ "windows":[{"id":"W1","ref":"window:1","cpu_percent":12.25,"rss_bytes":524288000,"process_count":9,"workspaces":[
    \\  {"id":"WS1","ref":"workspace:1","title":"api","cpu_percent":12.0,"rss_bytes":400000000,"process_count":7,"panes":[
    \\   {"id":"P1","ref":"pane:1","cpu_percent":2.0,"rss_bytes":1000,"process_count":2,"surfaces":[
    \\    {"id":"S1","ref":"surface:1","title":"zsh","cpu_percent":0.5,"rss_bytes":512,"process_count":1,
    \\     "processes":[{"pid":4242,"name":"zsh\tx","cpu_percent":0.5,"rss_bytes":512,"children":[{"pid":4243,"name":"sleep","cpu_percent":0,"rss_bytes":100}]}]},
    \\    {"id":"S2","ref":"surface:2","title":"cargo","cpu_percent":95.5,"rss_bytes":300000000,"process_count":5}]}]}]}]}
;

test "unit: cli-ps: top params, tree and tsv layouts, sorting and old apps" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.setEnv("CMUX_SURFACE_ID", "S1");
    h.ok("system.top", top_result);
    const r = h.run(&.{ "cmux", "top" });
    try pt.expectOk(r);
    try h.expectLast("system.top", "{\"caller\":{\"surface_id\":\"S1\"}}");
    try pt.expectGolden(h.alloc(), "top.txt", r.out);
    const tsv = h.run(&.{ "cmux", "top", "--format", "tsv", "--processes", "--all", "--sort", "cpu" });
    try pt.expectOk(tsv);
    try h.expectLast("system.top", "{\"all_windows\":true,\"include_processes\":true,\"caller\":{\"surface_id\":\"S1\"}}");
    try pt.expectGolden(h.alloc(), "top-tsv.txt", tsv.out);
    const flat = h.run(&.{ "cmux", "top", "--flat", "--sort", "mem", "--workspace", "workspace:1" });
    try h.expectLast("system.top", "{\"workspace_id\":\"workspace:1\",\"caller\":{\"surface_id\":\"S1\"}}");
    try pt.expectGolden(h.alloc(), "top-flat.txt", flat.out);
    // Unknown method: cmux's process-diagnostics message, exit 1.
    h.reply("system.top", .{ .err = "{\"code\":\"method_not_found\",\"message\":\"Unknown method\"}" });
    const old = h.run(&.{ "wmux", "top" });
    try testing.expectEqual(@as(u8, 1), old.code);
    try testing.expectEqualStrings("wmux top requires a running wmux build that supports process diagnostics\n", old.err);
    h.clearRequests();
    try pt.expectUsage(h.run(&.{ "cmux", "top", "--sort", "name" }), "--sort must be cpu, mem or proc");
    try pt.expectUsage(h.run(&.{ "cmux", "top", "--sort", "none" }), "--sort must be cpu, mem or proc");
    try pt.expectUsage(h.run(&.{ "cmux", "top", "--format", "json" }), "--format must be tree or tsv");
    try pt.expectUsage(h.run(&.{ "cmux", "top", "--all", "--window", "window:1" }), "--window cannot be combined with --all");
    try testing.expectEqual(@as(usize, 0), h.requests().len);
}

test "unit: cli-ps: memory separates the app from terminal children" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("system.memory",
        \\{"app":{"footprint_bytes":157286400,"webview_bytes":83886080,"webview_process_count":4},
        \\ "children":{"rss_bytes":1288490188,"process_count":14},
        \\ "groups":[{"kind":"surface","id":"S2","ref":"surface:2","title":"cargo","rss_bytes":966367641,"process_count":1},
        \\           {"kind":"workspace","id":"WS1","ref":"workspace:1","title":"api","rss_bytes":1073741824,"process_count":9}]}
    );
    const r = h.run(&.{ "cmux", "memory", "--all", "--limit", "2" });
    try pt.expectOk(r);
    try h.expectLast("system.memory", "{\"all_windows\":true,\"top_group_limit\":2}");
    try pt.expectGolden(h.alloc(), "memory.txt", r.out);
    h.ok("system.memory", "{}");
    try testing.expectEqualStrings("App footprint:        -\nTerminal children:    -\n", h.run(&.{ "cmux", "memory" }).out);
    h.reply("system.memory", .{ .err = "{\"code\":\"method_not_found\",\"message\":\"Unknown method\"}" });
    try testing.expectEqualStrings("cmux memory requires a running cmux build that supports process diagnostics\n", h.run(&.{ "cmux", "memory" }).err);
    try pt.expectUsage(h.run(&.{ "cmux", "memory", "--limit", "0" }), "--limit must be a positive integer");
    try pt.expectUsage(h.run(&.{ "cmux", "memory", "--workspace", "" }), "Workspace handle is blank");
}

test "unit: cli-ps: shot params, validation and text output" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // A relative --out is joined to the CLI's cwd with the native separator.
    const windows = @import("builtin").os.tag == .windows;
    h.fp.cwd_path = if (windows) "C:\\work" else "/work";
    const out_json = if (windows) "C:\\\\work\\\\shots/b.jpg" else "/work/shots/b.jpg";
    h.ok("window.screenshot", "{\"width\":1600,\"height\":1000,\"bytes\":48213,\"path\":\"/tmp/a.png\",\"format\":\"png\"}");
    const r = h.run(&.{ "cmux", "shot", "--out", "/tmp/a.png" });
    try pt.expectOk(r);
    try h.expectLast("window.screenshot", "{\"out\":\"/tmp/a.png\"}");
    try pt.expectGolden(h.alloc(), "shot.txt", r.out);
    _ = h.run(&.{ "cmux", "screenshot", "--jpg", "--scale", "0.5", "--max-width", "800", "--quality", "0.9", "--region", "0,0,100,100", "--label", "l", "--caption", "Build \u{2713}", "--out", "shots/b.jpg", "--window", "window:2" });
    try h.expectLast("window.screenshot", "{\"format\":\"jpg\",\"scale\":0.5,\"max_width\":800,\"quality\":0.9,\"region\":{\"x\":0,\"y\":0,\"width\":100,\"height\":100},\"label\":\"l\",\"caption\":\"Build \u{2713}\",\"out\":\"" ++ out_json ++ "\",\"window\":\"window:2\"}");
    _ = h.run(&.{ "cmux", "--window", "1", "shot", "--format", "jpg", "--jpg" });
    try h.expectLast("window.screenshot", "{\"format\":\"jpg\",\"window\":1}");
    h.clearRequests();
    try pt.expectUsage(h.run(&.{ "cmux", "shot", "now", "please" }), "cmux: shot: unexpected arguments: now please\n");
    try pt.expectUsage(h.run(&.{ "cmux", "shot", "--format", "png", "--jpg" }), "--jpg conflicts with --format png");
    try pt.expectUsage(h.run(&.{ "cmux", "shot", "--format", "gif" }), "--format must be png or jpg");
    try pt.expectUsage(h.run(&.{ "cmux", "shot", "--scale", "big" }), "--scale must be a number");
    try pt.expectUsage(h.run(&.{ "cmux", "shot", "--quality", "inf" }), "--quality must be a number");
    try pt.expectUsage(h.run(&.{ "cmux", "shot", "--max-width", "1.5" }), "--max-width must be an integer");
    for ([_][]const u8{ "0,0,100", "0,0,0,10", "a,b,c,d", "1,2,3,4,5", "" }) |bad| {
        try pt.expectUsage(h.run(&.{ "cmux", "shot", "--region", bad }), "--region must be x,y,w,h");
    }
    try testing.expectEqual(@as(usize, 0), h.requests().len);
    // Hostile numbers never trap the renderer.
    h.ok("window.screenshot", "{\"width\":1e300,\"height\":-1e300,\"bytes\":\"x\",\"path\":\"p\\u001b\"}");
    try testing.expectEqualStrings("9223372036854775807x-9223372036854775808 0 p \n", h.run(&.{ "cmux", "shot" }).out);
}

test "unit: cli-ps: identify output golden" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("system.identify", "{\"app\":\"wmux\",\"version\":\"1.0.0\",\"build\":\"7\",\"socket_path\":\"\\\\\\\\.\\\\pipe\\\\wmux-stable-1-s1\",\"focused\":{\"window_id\":\"W1\",\"window_ref\":\"window:1\",\"surface_id\":\"S1\",\"surface_ref\":\"surface:1\",\"surface_type\":\"terminal\",\"is_browser_surface\":false},\"caller\":null}");
    const r = h.run(&.{ "cmux", "identify", "--no-caller" });
    try pt.expectOk(r);
    try pt.expectGolden(h.alloc(), "identify.txt", r.out);
}
