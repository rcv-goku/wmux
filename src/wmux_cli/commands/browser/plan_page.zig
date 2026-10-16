//! Planning of the `cmux browser <surface> <verb>` page verbs: navigation,
//! snapshot, eval, wait, element actions, input, getters, locators, frames,
//! dialogs, downloads and the P2 families (SPEC.json `browser-cli-*`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const plan_mod = @import("plan.zig");
const g = @import("grammar.zig");
const C = plan_mod.C;
const P = plan_mod.P;
const Plan = plan_mod.Plan;
const Render = plan_mod.Render;
const Flag = g.Flag;
const Opts = g.Opts;
const Error = g.Error;
const eql = plan_mod.eql;
const oneOf = plan_mod.oneOf;

const selector_flag: Flag = .{ .name = "--selector", .aliases = &.{"-s"} };

pub fn planSurfaceVerb(c: *C) Error!Plan {
    const v = c.in.verb;
    if (oneOf(v, &.{ "goto", "navigate" })) return plan_mod.navigate(c);
    if (oneOf(v, &.{ "back", "forward", "reload" })) return simple(c, switch (v[0]) {
        'b' => "browser.back",
        'f' => "browser.forward",
        else => "browser.reload",
    }, .ok);
    if (oneOf(v, &.{ "url", "get-url" })) return simple(c, "browser.url.get", .url);
    if (oneOf(v, &.{ "focus-webview", "focus_webview" })) return simple(c, "browser.focus_webview", .ok);
    if (oneOf(v, &.{ "is-webview-focused", "is_webview_focused" })) return simple(c, "browser.is_webview_focused", .focused);
    if (eql(v, "snapshot")) return snapshot(c);
    if (eql(v, "eval")) return script(c, "browser.eval", "--script", .eval, "browser eval requires a script");
    if (eql(v, "addscript")) return script(c, "browser.addscript", "--script", .eval, "browser addscript requires content");
    if (eql(v, "addinitscript")) return script(c, "browser.addinitscript", "--script", .ok, "browser addinitscript requires content");
    if (eql(v, "addstyle")) return script(c, "browser.addstyle", "--css", .ok, "browser addstyle requires content");
    if (eql(v, "wait")) return wait(c);
    if (oneOf(v, &.{ "click", "dblclick", "hover", "focus", "check", "uncheck", "highlight" })) {
        const m = try std.fmt.allocPrint(c.arena, "browser.{s}", .{v});
        return element(c, m);
    }
    if (oneOf(v, &.{ "scroll-into-view", "scrollintoview", "scrollinto" })) return element(c, "browser.scroll_into_view");
    if (eql(v, "type")) return typeText(c, false);
    if (eql(v, "fill")) return typeText(c, true);
    if (oneOf(v, &.{ "press", "key", "keydown", "keyup" })) return key(c);
    if (eql(v, "select")) return selectOption(c);
    if (eql(v, "scroll")) return scroll(c);
    if (eql(v, "set-input-files")) return setInputFiles(c);
    if (eql(v, "get")) return get(c);
    if (eql(v, "is")) return isState(c);
    if (eql(v, "find")) return find(c);
    if (eql(v, "frame")) return frame(c);
    if (eql(v, "dialog")) return dialog(c);
    if (eql(v, "screenshot")) return screenshot(c);
    return @import("plan_state.zig").planStateVerb(c);
}

/// A verb without arguments beyond the target.
fn simple(c: *C, method: []const u8, render: Render) Error!Plan {
    const o = try c.scan(&.{});
    const b = try c.base(o, method, render);
    try c.noPositionals(o, 0);
    return b.plan();
}

fn parseInt(comptime T: type, s: []const u8) ?T {
    return std.fmt.parseInt(T, std.mem.trim(u8, s, " \t"), 10) catch null;
}

/// `snapshot [--interactive|-i] [--cursor] [--compact|-c] [--max-depth|-d
/// <n>] [--selector|-s <css>]` -> `browser.snapshot`.
fn snapshot(c: *C) Error!Plan {
    const o = try c.scan(&.{
        .{ .name = "--interactive", .kind = .boolean, .aliases = &.{"-i"} },
        .{ .name = "--cursor", .kind = .boolean },
        .{ .name = "--compact", .kind = .boolean, .aliases = &.{"-c"} },
        .{ .name = "--max-depth", .aliases = &.{ "-d", "--depth" } },
        selector_flag,
    });
    var b = try c.base(o, "browser.snapshot", .snapshot);
    try c.noPositionals(o, 0);
    try b.p.boolean("interactive", o.has("--interactive"));
    try b.p.boolean("cursor", o.has("--cursor"));
    try b.p.boolean("compact", o.has("--compact"));
    if (o.get("--max-depth")) |d| {
        const n = parseInt(u32, d) orelse return c.usage("browser snapshot --max-depth must be a non-negative integer", .{});
        try b.p.int("max_depth", n);
    }
    try b.p.optStr("selector", o.get("--selector"));
    return b.plan();
}

/// eval/addscript/addinitscript/addstyle: `--<flag> <text>` or the
/// positional words joined by spaces.
fn script(c: *C, method: []const u8, flag: []const u8, render: Render, empty_message: []const u8) Error!Plan {
    const o = try c.scan(&.{.{ .name = flag }});
    var b = try c.base(o, method, render);
    const text = o.get(flag) orelse try c.joined(o.positionals);
    if (o.get(flag) != null) try c.noPositionals(o, 0);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return c.usage("{s}", .{empty_message});
    try b.p.str(if (eql(flag, "--css")) "css" else "script", text);
    return b.plan();
}

/// `wait [--selector|<css>] [--text] [--url-contains|--url]
/// [--load-state] [--function] [--timeout-ms|--timeout]` -> `browser.wait`.
fn wait(c: *C) Error!Plan {
    const o = try c.scan(&.{
        selector_flag,
        .{ .name = "--text" },
        .{ .name = "--url-contains", .aliases = &.{"--url"} },
        .{ .name = "--load-state" },
        .{ .name = "--function" },
        .{ .name = "--timeout-ms" },
        .{ .name = "--timeout" },
    });
    var b = try c.base(o, "browser.wait", .ok);
    try c.noPositionals(o, 1);
    const sel = o.get("--selector") orelse if (o.positionals.len == 1) o.positionals[0] else null;
    if (o.get("--selector") != null) try c.noPositionals(o, 0);
    try b.p.optStr("selector", sel);
    try b.p.optStr("text_contains", o.get("--text"));
    try b.p.optStr("url_contains", o.get("--url-contains"));
    if (o.get("--load-state")) |ls| {
        if (!oneOf(ls, &.{ "interactive", "complete" })) return c.usage("browser wait --load-state must be interactive or complete", .{});
        try b.p.str("load_state", ls);
    }
    try b.p.optStr("function", o.get("--function"));
    var wait_ms: u32 = plan_mod.wait_default_ms;
    if (try timeoutMs(c, o, "browser wait")) |ms| {
        wait_ms = ms;
        try b.p.int("timeout_ms", ms);
    }
    b.call.timeout_ms = @max(b.call.timeout_ms orelse 0, @max(15_000, wait_ms +| 8_000));
    return b.plan();
}

/// `--timeout-ms <ms>` or `--timeout <seconds>`.
pub fn timeoutMs(c: *C, o: Opts, label: []const u8) Error!?u32 {
    if (o.get("--timeout-ms")) |t| {
        return parseInt(u32, t) orelse c.usage("{s} --timeout-ms must be a non-negative integer", .{label});
    }
    if (o.get("--timeout")) |t| {
        const s = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " \t")) catch return c.usage("{s} --timeout must be a number of seconds", .{label});
        if (!std.math.isFinite(s) or s < 0 or s > 86_400) return c.usage("{s} --timeout must be a number of seconds", .{label});
        return @intFromFloat(@round(s * 1000));
    }
    return null;
}

/// The selector from `--selector` or the first positional; returns the
/// remaining positionals.
fn selectorArg(c: *C, o: Opts, required: bool) Error!struct { sel: ?[]const u8, rest: []const []const u8 } {
    if (o.get("--selector")) |s| return .{ .sel = s, .rest = o.positionals };
    if (o.positionals.len > 0) return .{ .sel = o.positionals[0], .rest = o.positionals[1..] };
    if (required) return c.usage("{s} requires a selector", .{c.label});
    return .{ .sel = null, .rest = o.positionals };
}

/// click/dblclick/hover/focus/check/uncheck/highlight/scroll-into-view
/// `[--selector <css> | <css|ref>]`.
fn element(c: *C, method: []const u8) Error!Plan {
    const o = try c.scan(&.{selector_flag});
    var b = try c.base(o, method, .ok);
    const s = try selectorArg(c, o, true);
    if (s.rest.len > 0) return c.usage("{s}: unexpected argument '{s}'", .{ c.label, s.rest[0] });
    try b.p.str("selector", s.sel.?);
    return b.plan();
}

/// `type [--selector|<sel>] [--text|<text...>]` (text required) and
/// `fill <sel> [--text|<text...>]` (empty clears).
fn typeText(c: *C, fill: bool) Error!Plan {
    const o = try c.scan(&.{ selector_flag, .{ .name = "--text" } });
    var b = try c.base(o, if (fill) "browser.fill" else "browser.type", .ok);
    const s = try selectorArg(c, o, true);
    const text = o.get("--text") orelse try c.joined(s.rest);
    if (o.get("--text") != null and s.rest.len > 0) return c.usage("{s}: unexpected argument '{s}'", .{ c.label, s.rest[0] });
    if (!fill and text.len == 0) return c.usage("browser type requires text", .{});
    try b.p.str("selector", s.sel.?);
    try b.p.str("text", text);
    return b.plan();
}

/// `press|key|keydown|keyup [--key <key> | <key>]`. The key is sent as
/// typed (`' '` stays a space).
fn key(c: *C) Error!Plan {
    const v = c.in.verb;
    const method = if (eql(v, "keydown")) "browser.keydown" else if (eql(v, "keyup")) "browser.keyup" else "browser.press";
    const o = try c.scan(&.{.{ .name = "--key" }});
    var b = try c.base(o, method, .ok);
    const k = o.get("--key") orelse if (o.positionals.len > 0) o.positionals[0] else "";
    try c.noPositionals(o, if (o.get("--key") != null) 0 else 1);
    if (k.len == 0) return c.usage("{s} requires a key", .{c.label});
    try b.p.str("key", k);
    return b.plan();
}

/// `select [--selector|<sel>] [--value|<value>]` (empty value allowed).
fn selectOption(c: *C) Error!Plan {
    const o = try c.scan(&.{ selector_flag, .{ .name = "--value" } });
    var b = try c.base(o, "browser.select", .ok);
    const s = try selectorArg(c, o, true);
    const value = o.get("--value") orelse if (s.rest.len > 0) s.rest[0] else return c.usage("browser select requires a value", .{});
    const extra: usize = if (o.get("--value") != null) 0 else 1;
    if (s.rest.len > extra) return c.usage("{s}: unexpected argument '{s}'", .{ c.label, s.rest[extra] });
    try b.p.str("selector", s.sel.?);
    try b.p.str("value", value);
    return b.plan();
}

/// `scroll [--selector <css>] [--dx <n>] [--dy <n>] [<dy>]`.
fn scroll(c: *C) Error!Plan {
    const o = try c.scan(&.{ selector_flag, .{ .name = "--dx" }, .{ .name = "--dy" } });
    var b = try c.base(o, "browser.scroll", .ok);
    try c.noPositionals(o, 1);
    try b.p.optStr("selector", o.get("--selector"));
    if (o.get("--dx")) |t| try b.p.int("dx", parseInt(i64, t) orelse return c.usage("--dx must be an integer", .{}));
    const dy = o.get("--dy") orelse if (o.positionals.len == 1) o.positionals[0] else null;
    if (o.get("--dy") != null) try c.noPositionals(o, 0);
    if (dy) |t| try b.p.int("dy", parseInt(i64, t) orelse return c.usage("--dy must be an integer", .{}));
    return b.plan();
}

const upload_usage = "set-input-files requires --selector <css> and either --file <path> (repeatable) or --clear";

/// `set-input-files --selector <css|ref> (--file <path> ...|--clear)`.
/// Paths are expanded and made absolute here; the run step checks them.
fn setInputFiles(c: *C) Error!Plan {
    const o = try c.scan(&.{ selector_flag, .{ .name = "--file" }, .{ .name = "--clear", .kind = .boolean } });
    var b = try c.base(o, "browser.set_input_files", .ok);
    try c.noPositionals(o, 0);
    const sel = o.get("--selector") orelse return c.usage(upload_usage, .{});
    const files = try o.all(c.arena, "--file");
    if ((files.len == 0) == !o.has("--clear")) return c.usage(upload_usage, .{});
    if (files.len > plan_mod.max_upload_files) return c.usage("Select at most 128 files using absolute paths", .{});
    var abs: std.ArrayList([]const u8) = .empty;
    for (files) |f| {
        if (std.mem.trim(u8, f, " \t").len == 0) return c.usage("Every upload path must be a readable regular file", .{});
        try abs.append(c.arena, try c.absPath(f));
    }
    try b.p.str("selector", sel);
    try b.p.strings(c.arena, "files", abs.items);
    b.call.check_uploads = abs.items.len > 0;
    b.call.timeout_ms = (b.call.timeout_ms orelse 15_000) +| plan_mod.upload_extra_ms;
    return b.plan();
}

const get_verbs = [_][]const u8{ "url", "title", "text", "html", "value", "attr", "count", "box", "styles" };

/// `get url|title|text|html|value|attr|count|box|styles ...`.
fn get(c: *C) Error!Plan {
    const o = try c.scan(&.{ selector_flag, .{ .name = "--attr" }, .{ .name = "--property" } });
    if (o.positionals.len == 0) return c.usage("browser get requires a subcommand: url, title, text, html, value, attr, count, box, styles", .{});
    const sub = o.positionals[0];
    if (!oneOf(sub, &get_verbs)) return c.usage("Unsupported browser get subcommand: {s}", .{sub});
    if (eql(sub, "url") or eql(sub, "title")) {
        var b = try c.base(o, if (eql(sub, "url")) "browser.url.get" else "browser.get.title", .value);
        if (o.positionals.len > 1) return c.usage("browser get {s}: unexpected argument '{s}'", .{ sub, o.positionals[1] });
        return b.plan();
    }
    var b = try c.base(o, try std.fmt.allocPrint(c.arena, "browser.get.{s}", .{sub}), .value);
    const rest = o.positionals[1..];
    const sel = o.get("--selector") orelse if (rest.len > 0) rest[0] else return c.usage("browser get {s} requires a selector", .{sub});
    const after = if (o.get("--selector") != null) rest else rest[1..];
    try b.p.str("selector", sel);
    var max_after: usize = 0;
    if (eql(sub, "attr")) {
        const name = o.get("--attr") orelse if (after.len > 0) after[0] else return c.usage("browser get attr requires --attr <name>", .{});
        if (o.get("--attr") == null) max_after = 1;
        try b.p.str("attr", name);
    } else if (eql(sub, "styles")) {
        try b.p.optStr("property", o.get("--property"));
    }
    if (after.len > max_after) return c.usage("browser get {s}: unexpected argument '{s}'", .{ sub, after[max_after] });
    return b.plan();
}

/// `is visible|enabled|checked [--selector|<css>]` -> true/false.
fn isState(c: *C) Error!Plan {
    const o = try c.scan(&.{selector_flag});
    if (o.positionals.len == 0 or !oneOf(o.positionals[0], &.{ "visible", "enabled", "checked" })) {
        return c.usage("browser is requires one of: visible, enabled, checked", .{});
    }
    const sub = o.positionals[0];
    var b = try c.base(o, try std.fmt.allocPrint(c.arena, "browser.is.{s}", .{sub}), .bool_value);
    const rest = o.positionals[1..];
    const sel = o.get("--selector") orelse if (rest.len > 0) rest[0] else return c.usage("browser is {s} requires a selector", .{sub});
    const extra: usize = if (o.get("--selector") != null) 0 else 1;
    if (rest.len > extra) return c.usage("browser is {s}: unexpected argument '{s}'", .{ sub, rest[extra] });
    try b.p.str("selector", sel);
    return b.plan();
}

const find_text_locators = [_][]const u8{ "text", "label", "placeholder", "alt", "title", "testid" };

/// `find role|text|label|placeholder|alt|title|testid|first|last|nth ...`.
fn find(c: *C) Error!Plan {
    const o = try c.scan(&.{ selector_flag, .{ .name = "--name" }, .{ .name = "--exact", .kind = .boolean }, .{ .name = "--index" } });
    const usage = "browser find requires a locator: role, text, label, placeholder, alt, title, testid, first, last, nth";
    if (o.positionals.len == 0) return c.usage(usage, .{});
    const loc = o.positionals[0];
    const rest = o.positionals[1..];
    if (eql(loc, "role")) {
        var b = try c.base(o, "browser.find.role", .ok);
        if (rest.len == 0) return c.usage("browser find role requires a role", .{});
        if (rest.len > 1) return c.usage("browser find role: unexpected argument '{s}'", .{rest[1]});
        try b.p.str("role", rest[0]);
        try b.p.optStr("name", o.get("--name"));
        try b.p.boolean("exact", o.has("--exact"));
        return b.plan();
    }
    if (oneOf(loc, &find_text_locators)) {
        var b = try c.base(o, try std.fmt.allocPrint(c.arena, "browser.find.{s}", .{loc}), .ok);
        if (o.has("--name")) return c.usage("browser find {s} does not support --name", .{loc});
        const text = try c.joined(rest);
        if (text.len == 0) return c.usage("browser find {s} requires a value", .{loc});
        try b.p.str(loc, text);
        try b.p.boolean("exact", o.has("--exact"));
        return b.plan();
    }
    if (oneOf(loc, &.{ "first", "last" })) {
        var b = try c.base(o, if (eql(loc, "first")) "browser.find.first" else "browser.find.last", .ok);
        const sel = o.get("--selector") orelse if (rest.len > 0) rest[0] else return c.usage("browser find {s} requires a selector", .{loc});
        const extra: usize = if (o.get("--selector") != null) 0 else 1;
        if (rest.len > extra) return c.usage("browser find {s}: unexpected argument '{s}'", .{ loc, rest[extra] });
        try b.p.str("selector", sel);
        return b.plan();
    }
    if (eql(loc, "nth")) {
        var b = try c.base(o, "browser.find.nth", .ok);
        var r = rest;
        const idx_text = o.get("--index") orelse blk: {
            if (r.len == 0) return c.usage("browser find nth requires an index", .{});
            const t = r[0];
            r = r[1..];
            break :blk t;
        };
        const idx = parseInt(i64, idx_text) orelse return c.usage("browser find nth requires an integer index", .{});
        const sel = o.get("--selector") orelse if (r.len > 0) r[0] else return c.usage("browser find nth requires a selector", .{});
        const extra: usize = if (o.get("--selector") != null) 0 else 1;
        if (r.len > extra) return c.usage("browser find nth: unexpected argument '{s}'", .{r[extra]});
        try b.p.int("index", idx);
        try b.p.str("selector", sel);
        return b.plan();
    }
    return c.usage(usage, .{});
}

/// `frame <selector|main> [--selector <css>]`.
fn frame(c: *C) Error!Plan {
    const o = try c.scan(&.{selector_flag});
    const target = o.get("--selector") orelse if (o.positionals.len > 0) o.positionals[0] else return c.usage("browser frame requires <selector|main>", .{});
    try c.noPositionals(o, if (o.get("--selector") != null) 0 else 1);
    if (o.get("--selector") == null and eql(target, "main")) {
        return (try c.base(o, "browser.frame.main", .ok)).plan();
    }
    var b = try c.base(o, "browser.frame.select", .ok);
    try b.p.str("selector", target);
    return b.plan();
}

/// `dialog accept [text...]` / `dialog dismiss`.
fn dialog(c: *C) Error!Plan {
    const o = try c.scan(&.{.{ .name = "--text" }});
    if (o.positionals.len == 0 or !oneOf(o.positionals[0], &.{ "accept", "dismiss" })) return c.usage("browser dialog requires accept|dismiss", .{});
    if (eql(o.positionals[0], "dismiss")) {
        const b = try c.base(o, "browser.dialog.dismiss", .ok);
        if (o.positionals.len > 1) return c.usage("browser dialog dismiss: unexpected argument '{s}'", .{o.positionals[1]});
        if (o.has("--text")) return c.usage("browser dialog dismiss does not support --text", .{});
        return b.plan();
    }
    var b = try c.base(o, "browser.dialog.accept", .ok);
    if (o.get("--text")) |t| {
        if (o.positionals.len > 1) return c.usage("browser dialog accept: unexpected argument '{s}'", .{o.positionals[1]});
        try b.p.str("text", t);
    } else if (o.positionals.len > 1) try b.p.str("text", try c.joined(o.positionals[1..]));
    return b.plan();
}

/// `screenshot [--out <path>]`.
fn screenshot(c: *C) Error!Plan {
    const o = try c.scan(&.{.{ .name = "--out", .aliases = &.{"--path"} }});
    var b = try c.base(o, "browser.screenshot", .screenshot);
    try c.noPositionals(o, 0);
    if (o.get("--out")) |out| {
        if (std.mem.trim(u8, out, " \t").len == 0) return c.usage("browser screenshot --out requires a path", .{});
        b.call.out_path = try c.absPath(out);
    }
    return b.plan();
}
