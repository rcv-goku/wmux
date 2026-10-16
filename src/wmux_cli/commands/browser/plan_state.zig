//! Planning of the browser state and emulation verbs: download, cookies,
//! storage, state, tab, console, errors, viewport, geolocation, offline and
//! the families cmux reports as `not_supported` (trace, network,
//! screencast, input). SPEC.json `browser-cli-*`.

const std = @import("std");
const plan_mod = @import("plan.zig");
const plan_page = @import("plan_page.zig");
const g = @import("grammar.zig");
const C = plan_mod.C;
const P = plan_mod.P;
const Plan = plan_mod.Plan;
const Opts = g.Opts;
const Error = g.Error;
const eql = plan_mod.eql;
const oneOf = plan_mod.oneOf;

pub fn planStateVerb(c: *C) Error!Plan {
    const v = c.in.verb;
    if (eql(v, "download")) return download(c);
    if (eql(v, "cookies")) return cookies(c);
    if (eql(v, "storage")) return storage(c);
    if (eql(v, "state")) return state(c);
    if (oneOf(v, &.{ "tab", "tabs" })) return tab(c);
    if (oneOf(v, &.{ "console", "errors" })) return logs(c);
    if (eql(v, "viewport")) return viewport(c);
    if (oneOf(v, &.{ "geolocation", "geo" })) return geolocation(c);
    if (eql(v, "offline")) return offline(c);
    return unsupportedFamily(c);
}

fn parseInt(comptime T: type, s: []const u8) ?T {
    return std.fmt.parseInt(T, std.mem.trim(u8, s, " \t"), 10) catch null;
}

/// `download [wait] [--path|<path>] [--timeout-ms|--timeout]` and
/// `download list|ls [--limit <1...25>]`.
fn download(c: *C) Error!Plan {
    const o = try c.scan(&.{ .{ .name = "--path" }, .{ .name = "--timeout-ms" }, .{ .name = "--timeout" }, .{ .name = "--limit" } });
    var pos = o.positionals;
    if (pos.len > 0 and oneOf(pos[0], &.{ "list", "ls" })) {
        var b = try c.base(o, "browser.download.list", .downloads);
        if (pos.len > 1) return c.usage("browser download list: unexpected argument '{s}'", .{pos[1]});
        if (o.has("--path") or o.has("--timeout-ms") or o.has("--timeout")) return c.usage("browser download list only supports --limit", .{});
        if (o.has("--snapshot-after")) return c.usage("browser download list does not support --snapshot-after", .{});
        if (o.count("--limit") > 1) return c.usage("--limit may only be given once", .{});
        if (o.get("--limit")) |l| {
            const n = parseInt(i64, l) orelse 0;
            if (n < 1 or n > plan_mod.download_list_max) return c.usage("--limit must be an integer from 1 to 25", .{});
            try b.p.int("limit", n);
        }
        return b.plan();
    }
    var b = try c.base(o, "browser.download.wait", .ok);
    if (o.has("--limit")) return c.usage("browser download wait does not support --limit", .{});
    if (pos.len > 0 and eql(pos[0], "wait")) pos = pos[1..];
    const path = o.get("--path") orelse if (pos.len > 0) pos[0] else null;
    const extra: usize = if (o.get("--path") != null) 0 else 1;
    if (pos.len > extra) return c.usage("browser download: unexpected argument '{s}'", .{pos[extra]});
    if (path) |p| {
        if (std.mem.trim(u8, p, " \t").len == 0) return c.usage("browser download --path requires a path", .{});
        try b.p.str("path", try c.absPath(p));
    }
    var wait_ms: u32 = 0;
    if (try plan_page.timeoutMs(c, o, "browser download")) |ms| {
        wait_ms = ms;
        try b.p.int("timeout_ms", ms);
    }
    b.call.timeout_ms = @max(b.call.timeout_ms orelse 0, @max(15_000, wait_ms +| 8_000));
    return b.plan();
}

const cookie_filters = [_][]const u8{ "--name", "--url", "--domain", "--path" };

/// `cookies [get|set|clear] [--name] [--value] [--url] [--domain] [--path]
/// [--expires <unix>] [--secure] [--http-only] [--all]`.
fn cookies(c: *C) Error!Plan {
    const o = try c.scan(&.{
        .{ .name = "--name" },                     .{ .name = "--value" },
        .{ .name = "--url" },                      .{ .name = "--domain" },
        .{ .name = "--path" },                     .{ .name = "--expires" },
        .{ .name = "--secure", .kind = .boolean }, .{ .name = "--http-only", .kind = .boolean, .aliases = &.{"--httponly"} },
        .{ .name = "--all", .kind = .boolean },
    });
    var pos = o.positionals;
    var op: []const u8 = "get";
    if (pos.len > 0 and oneOf(pos[0], &.{ "get", "set", "clear" })) {
        op = pos[0];
        pos = pos[1..];
    }
    var b = try c.base(o, try std.fmt.allocPrint(c.arena, "browser.cookies.{s}", .{op}), if (eql(op, "get")) .json else .ok);
    var expires: ?i64 = null;
    if (o.get("--expires")) |e| expires = parseInt(i64, e) orelse return c.usage("browser cookies --expires must be an integer", .{});
    if (eql(op, "set")) {
        const name = o.get("--name") orelse if (pos.len > 0) pos[0] else null;
        const used: usize = if (o.get("--name") != null) 0 else 1;
        const value = o.get("--value") orelse if (pos.len > used) pos[used] else null;
        const used2 = used + @as(usize, if (o.get("--value") != null) 0 else 1);
        if (name == null or value == null or name.?.len == 0) return c.usage("browser cookies set requires <name> <value> (or --name/--value)", .{});
        if (pos.len > used2) return c.usage("browser cookies set: unexpected argument '{s}'", .{pos[used2]});
        if (o.has("--all")) return c.usage("browser cookies set does not support --all", .{});
        try b.p.str("name", name.?);
        try b.p.str("value", value.?);
        try b.p.optStr("url", o.get("--url"));
        try b.p.optStr("domain", o.get("--domain"));
        try b.p.optStr("path", o.get("--path"));
        if (o.has("--secure")) try b.p.boolean("secure", true);
        if (o.has("--http-only")) try b.p.boolean("http_only", true);
        if (expires) |e| try b.p.int("expires", e);
        return b.plan();
    }
    if (pos.len > 0) return c.usage("browser cookies {s}: unexpected argument '{s}'", .{ op, pos[0] });
    if (o.has("--value")) return c.usage("browser cookies {s} does not support --value", .{op});
    for (cookie_filters) |f| try b.p.optStr(f[2..], o.get(f));
    if (o.has("--secure")) try b.p.boolean("secure", true);
    if (o.has("--http-only")) try b.p.boolean("http_only", true);
    if (expires) |e| try b.p.int("expires", e);
    if (eql(op, "clear")) {
        if (o.has("--all")) try b.p.boolean("all", true);
        if (b.p.map.count() == 1) return c.usage("browser cookies clear requires a scope: --url, --domain, --name, --path, or --all", .{});
    } else if (o.has("--all")) return c.usage("browser cookies get does not support --all", .{});
    return b.plan();
}

/// `storage <local|session> <get [key]|set <key> <value>|clear>` (defaults:
/// local, get).
fn storage(c: *C) Error!Plan {
    const o = try c.scan(&.{});
    var pos = o.positionals;
    var kind: []const u8 = "local";
    if (pos.len > 0 and oneOf(pos[0], &.{ "local", "session" })) {
        kind = pos[0];
        pos = pos[1..];
    } else if (pos.len > 0 and !oneOf(pos[0], &.{ "get", "set", "clear" })) {
        return c.usage("browser storage requires type: local|session", .{});
    }
    var op: []const u8 = "get";
    if (pos.len > 0) {
        if (!oneOf(pos[0], &.{ "get", "set", "clear" })) return c.usage("browser storage requires an operation: get, set, clear", .{});
        op = pos[0];
        pos = pos[1..];
    }
    var b = try c.base(o, try std.fmt.allocPrint(c.arena, "browser.storage.{s}", .{op}), if (eql(op, "get")) .value else .ok);
    try b.p.str("type", kind);
    if (eql(op, "get")) {
        if (pos.len > 1) return c.usage("browser storage get: unexpected argument '{s}'", .{pos[1]});
        if (pos.len == 1) try b.p.str("key", pos[0]);
    } else if (eql(op, "set")) {
        if (pos.len < 2) return c.usage("browser storage set requires <key> <value>", .{});
        if (pos.len > 2) return c.usage("browser storage set: unexpected argument '{s}'", .{pos[2]});
        try b.p.str("key", pos[0]);
        try b.p.str("value", pos[1]);
    } else if (pos.len > 0) return c.usage("browser storage clear: unexpected argument '{s}'", .{pos[0]});
    return b.plan();
}

/// `state save|load <path>`.
fn state(c: *C) Error!Plan {
    const o = try c.scan(&.{});
    const pos = o.positionals;
    if (pos.len == 0 or !oneOf(pos[0], &.{ "save", "load" })) return c.usage("browser state requires save|load <path>", .{});
    var b = try c.base(o, if (eql(pos[0], "save")) "browser.state.save" else "browser.state.load", .ok);
    if (pos.len < 2 or std.mem.trim(u8, pos[1], " \t").len == 0) return c.usage("browser state {s} requires a file path", .{pos[0]});
    if (pos.len > 2) return c.usage("browser state {s}: unexpected argument '{s}'", .{ pos[0], pos[2] });
    try b.p.str("path", try c.absPath(pos[1]));
    return b.plan();
}

/// A tab index (digits) or a surface handle (`target_surface_id`).
fn tabTarget(c: *C, p: *P, text: []const u8) Error!void {
    if (parseInt(u32, text)) |i| {
        try p.int("index", i);
        return;
    }
    try p.str("target_surface_id", try g.checkSurface(c.arena, text, c.diag));
}

/// `tab [list|new [url]|switch <index|surface>|close [index|surface]|<n>]`.
fn tab(c: *C) Error!Plan {
    const o = try c.scan(&.{});
    var pos = o.positionals;
    var op: []const u8 = "list";
    if (pos.len > 0 and oneOf(pos[0], &.{ "list", "ls", "new", "switch", "select", "close" })) {
        op = pos[0];
        pos = pos[1..];
    } else if (pos.len > 0 and parseInt(u32, pos[0]) != null) {
        op = "switch";
    } else if (pos.len > 0) {
        return c.usage("browser tab requires one of: list, new, switch, close, <index>", .{});
    }
    if (oneOf(op, &.{ "list", "ls" })) {
        const b = try c.base(o, "browser.tab.list", .tabs);
        if (pos.len > 0) return c.usage("browser tab list: unexpected argument '{s}'", .{pos[0]});
        return b.plan();
    }
    if (eql(op, "new")) {
        var b = try c.base(o, "browser.tab.new", .ok);
        if (pos.len > 1) return c.usage("browser tab new: unexpected argument '{s}'", .{pos[1]});
        if (pos.len == 1) try b.p.str("url", pos[0]);
        return b.plan();
    }
    if (oneOf(op, &.{ "switch", "select" })) {
        var b = try c.base(o, "browser.tab.switch", .ok);
        if (pos.len == 0) return c.usage("browser tab switch requires <index|surface>", .{});
        if (pos.len > 1) return c.usage("browser tab switch: unexpected argument '{s}'", .{pos[1]});
        try tabTarget(c, &b.p, pos[0]);
        return b.plan();
    }
    var b = try c.base(o, "browser.tab.close", .ok);
    if (pos.len > 1) return c.usage("browser tab close: unexpected argument '{s}'", .{pos[1]});
    if (pos.len == 1) try tabTarget(c, &b.p, pos[0]);
    return b.plan();
}

/// `console list|clear` and `errors list|clear` (default list).
fn logs(c: *C) Error!Plan {
    const o = try c.scan(&.{});
    const is_console = eql(c.in.verb, "console");
    const op = if (o.positionals.len > 0) o.positionals[0] else "list";
    if (!oneOf(op, &.{ "list", "clear" })) return c.usage("browser {s} requires list|clear", .{c.in.verb});
    try c.noPositionals(o, 1);
    if (is_console) {
        return (try c.base(o, if (eql(op, "list")) "browser.console.list" else "browser.console.clear", if (eql(op, "list")) .console else .ok)).plan();
    }
    var b = try c.base(o, "browser.errors.list", if (eql(op, "list")) .errors else .ok);
    if (eql(op, "clear")) try b.p.boolean("clear", true);
    return b.plan();
}

const viewport_usage = "browser viewport requires: <width> <height> | reset";

/// `viewport <width> <height>` (1...4096) or `viewport reset`.
fn viewport(c: *C) Error!Plan {
    const o = try c.scan(&.{});
    var b = try c.base(o, "browser.viewport.set", .ok);
    const pos = o.positionals;
    if (pos.len == 1 and eql(pos[0], "reset")) {
        try b.p.boolean("reset", true);
        return b.plan();
    }
    if (pos.len != 2) return c.usage(viewport_usage, .{});
    const w = parseInt(i64, pos[0]) orelse return c.usage(viewport_usage, .{});
    const h = parseInt(i64, pos[1]) orelse return c.usage(viewport_usage, .{});
    if (w < 1 or w > 4096 or h < 1 or h > 4096) return c.usage("browser viewport width and height must be integers from 1 to 4096", .{});
    try b.p.int("width", w);
    try b.p.int("height", h);
    return b.plan();
}

fn parseCoord(s: []const u8, limit: f64) ?f64 {
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t")) catch return null;
    if (!std.math.isFinite(v) or v < -limit or v > limit) return null;
    return v;
}

/// `geolocation|geo <latitude> <longitude> [accuracy]` or `geo clear`.
fn geolocation(c: *C) Error!Plan {
    const o = try c.scan(&.{.{ .name = "--accuracy" }});
    var b = try c.base(o, "browser.geolocation.set", .ok);
    const pos = o.positionals;
    const usage = "browser geolocation requires: <latitude> <longitude>";
    if (pos.len == 1 and eql(pos[0], "clear")) {
        try b.p.boolean("clear", true);
        return b.plan();
    }
    if (pos.len < 2 or pos.len > 3) return c.usage(usage, .{});
    try b.p.float("latitude", parseCoord(pos[0], 90) orelse return c.usage(usage, .{}));
    try b.p.float("longitude", parseCoord(pos[1], 180) orelse return c.usage(usage, .{}));
    const acc_text = o.get("--accuracy") orelse if (pos.len == 3) pos[2] else null;
    if (o.get("--accuracy") != null and pos.len == 3) return c.usage(usage, .{});
    if (acc_text) |t| {
        const acc = parseCoord(t, 1e9) orelse return c.usage("browser geolocation accuracy must be a non-negative number", .{});
        if (acc < 0) return c.usage("browser geolocation accuracy must be a non-negative number", .{});
        try b.p.float("accuracy", acc);
    }
    return b.plan();
}

/// `offline true|false`.
fn offline(c: *C) Error!Plan {
    const o = try c.scan(&.{});
    var b = try c.base(o, "browser.offline.set", .ok);
    if (o.positionals.len != 1) return c.usage("browser offline requires true|false", .{});
    const on = plan_mod.parseBool(o.positionals[0]) orelse return c.usage("browser offline requires true|false", .{});
    try b.p.boolean("enabled", on);
    return b.plan();
}

/// trace, network, screencast and input: cmux's grammar, forwarded to the
/// method (the app answers `not_supported` until it implements them).
fn unsupportedFamily(c: *C) Error!Plan {
    const v = c.in.verb;
    const o = try c.scan(&.{ .{ .name = "--abort", .kind = .boolean }, .{ .name = "--body" } });
    const pos = o.positionals;
    if (!eql(v, "network") and (o.has("--abort") or o.has("--body"))) {
        return c.usage("browser {s} does not support {s}", .{ v, if (o.has("--abort")) "--abort" else "--body" });
    }
    if (oneOf(v, &.{ "trace", "screencast" })) {
        if (pos.len == 0 or !oneOf(pos[0], &.{ "start", "stop" })) return c.usage("browser {s} requires start|stop", .{v});
        var b = try c.base(o, try std.fmt.allocPrint(c.arena, "browser.{s}.{s}", .{ v, pos[0] }), .ok);
        if (eql(v, "trace")) {
            if (pos.len > 2) return c.usage("browser trace: unexpected argument '{s}'", .{pos[2]});
            if (pos.len == 2) try b.p.str("path", try c.absPath(pos[1]));
        } else if (pos.len > 1) return c.usage("browser screencast: unexpected argument '{s}'", .{pos[1]});
        return b.plan();
    }
    if (eql(v, "network")) {
        if (pos.len == 0 or !oneOf(pos[0], &.{ "route", "unroute", "requests" })) return c.usage("browser network requires route|unroute|requests", .{});
        var b = try c.base(o, try std.fmt.allocPrint(c.arena, "browser.network.{s}", .{pos[0]}), .ok);
        if (eql(pos[0], "requests")) {
            if (pos.len > 1) return c.usage("browser network requests: unexpected argument '{s}'", .{pos[1]});
            if (o.has("--abort") or o.has("--body")) return c.usage("browser network requests does not support route options", .{});
            return b.plan();
        }
        if (pos.len < 2) return c.usage("browser network {s} requires <pattern>", .{pos[0]});
        if (pos.len > 2) return c.usage("browser network {s}: unexpected argument '{s}'", .{ pos[0], pos[2] });
        try b.p.str("pattern", pos[1]);
        if (eql(pos[0], "route")) {
            if (o.has("--abort")) try b.p.boolean("abort", true);
            try b.p.optStr("body", o.get("--body"));
        } else if (o.has("--abort") or o.has("--body")) return c.usage("browser network unroute does not support route options", .{});
        return b.plan();
    }
    // input mouse|keyboard|touch [args...] and input_mouse|input_keyboard|input_touch [args...]
    var kind: []const u8 = undefined;
    var args = pos;
    if (eql(v, "input")) {
        if (pos.len == 0 or !oneOf(pos[0], &.{ "mouse", "keyboard", "touch" })) return c.usage("browser input requires mouse|keyboard|touch", .{});
        kind = pos[0];
        args = pos[1..];
    } else kind = v["input_".len..];
    var b = try c.base(o, try std.fmt.allocPrint(c.arena, "browser.input_{s}", .{kind}), .ok);
    try b.p.strings(c.arena, "args", args);
    return b.plan();
}
