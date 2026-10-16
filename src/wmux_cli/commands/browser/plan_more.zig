//! Planning of the surface-less browser verbs: profiles, import, and the
//! view verbs with an optional surface (react-grab, devtools, focus-mode,
//! design-mode, zoom, history, repl). SPEC.json `browser-profiles-cli`,
//! `browser-import-cli`, `browser-design-mode-cli`, cli contract rows.

const std = @import("std");
const plan_mod = @import("plan.zig");
const g = @import("grammar.zig");
const C = plan_mod.C;
const P = plan_mod.P;
const Plan = plan_mod.Plan;
const Render = plan_mod.Render;
const Error = g.Error;
const eql = plan_mod.eql;
const oneOf = plan_mod.oneOf;
const done = plan_mod.done;

fn call(method: []const u8, render: Render) plan_mod.Call {
    return .{ .method = method, .params = undefined, .render = render };
}

/// `profiles [list|ls|add|new|create|rename|clear|delete|remove|rm] ...`.
pub fn planProfiles(c: *C) Error!Plan {
    const o = try c.scan(&.{
        .{ .name = "--name" },
        .{ .name = "--profile" },
        .{ .name = "--all", .kind = .boolean },
        .{ .name = "--force", .kind = .boolean },
    });
    if (o.has("--surface") or o.has("--workspace") or o.has("--window")) return c.usage("browser profiles does not take a surface, workspace or window", .{});
    var pos = o.positionals;
    const op = if (pos.len > 0) pos[0] else "list";
    if (pos.len > 0) pos = pos[1..];
    var p = P.init(c.arena);
    if (oneOf(op, &.{ "list", "ls" })) {
        if (pos.len > 0) return c.usage("browser profiles list: unexpected argument '{s}'", .{pos[0]});
        if (o.entries.len > 0) return c.usage("browser profiles list does not support {s}", .{o.entries[0].name});
        return done(p, call("browser.profiles.list", .profiles_list));
    }
    if (oneOf(op, &.{ "add", "new", "create" })) {
        const name = o.get("--name") orelse if (pos.len > 0) try c.joined(pos) else null;
        if (o.get("--name") != null and pos.len > 0) return c.usage("browser profiles {s}: unexpected argument '{s}'", .{ op, pos[0] });
        if (name == null or std.mem.trim(u8, name.?, " \t").len == 0) return c.usage("browser profiles {s} requires a name", .{op});
        if (o.has("--profile") or o.has("--all") or o.has("--force")) return c.usage("browser profiles {s} only supports --name", .{op});
        try p.str("name", name.?);
        return done(p, call("browser.profiles.create", .profile_created));
    }
    if (eql(op, "rename")) {
        var rest = pos;
        const profile = o.get("--profile") orelse blk: {
            if (rest.len == 0) break :blk null;
            const x = rest[0];
            rest = rest[1..];
            break :blk x;
        };
        const new_name = o.get("--name") orelse if (rest.len > 0) try c.joined(rest) else null;
        if (o.get("--name") != null and rest.len > 0) return c.usage("browser profiles rename: unexpected argument '{s}'", .{rest[0]});
        if (profile == null or new_name == null or std.mem.trim(u8, new_name.?, " \t").len == 0) return c.usage("browser profiles rename requires <profile> <new name>", .{});
        if (o.has("--all") or o.has("--force")) return c.usage("browser profiles rename does not support {s}", .{if (o.has("--all")) "--all" else "--force"});
        try p.str("profile", profile.?);
        try p.str("new_name", new_name.?);
        return done(p, call("browser.profiles.rename", .profile_renamed));
    }
    if (eql(op, "clear")) {
        const profile = o.get("--profile") orelse if (pos.len > 0) pos[0] else null;
        const extra: usize = if (o.get("--profile") != null) 0 else 1;
        if (pos.len > extra) return c.usage("browser profiles clear: unexpected argument '{s}'", .{pos[extra]});
        if (o.has("--name")) return c.usage("browser profiles clear does not support --name", .{});
        if ((profile == null) == !o.has("--all")) return c.usage("browser profiles clear requires <profile> or --all", .{});
        if (profile) |x| try p.str("profile", x) else try p.boolean("all", true);
        try p.boolean("force", o.has("--force"));
        return done(p, call("browser.profiles.clear", .profiles_cleared));
    }
    if (oneOf(op, &.{ "delete", "remove", "rm" })) {
        const profile = o.get("--profile") orelse if (pos.len > 0) pos[0] else null;
        const extra: usize = if (o.get("--profile") != null) 0 else 1;
        if (pos.len > extra) return c.usage("browser profiles {s}: unexpected argument '{s}'", .{ op, pos[extra] });
        if (profile == null) return c.usage("browser profiles {s} requires <profile>", .{op});
        if (o.has("--name") or o.has("--all") or o.has("--force")) return c.usage("browser profiles {s} only supports --profile", .{op});
        try p.str("profile", profile.?);
        return done(p, call("browser.profiles.delete", .profile_deleted));
    }
    return c.usage("browser profiles requires one of: list, add, rename, clear, delete", .{});
}

/// `import [--interactive | --non-interactive|-y|--yes] [--from <browser>]
/// [--profile <name>]... [--all-profiles] [--to <name|uuid>]
/// [--create-profile] [--domain <domain>]...`.
pub fn planImport(c: *C) Error!Plan {
    const o = try c.scan(&.{
        .{ .name = "--interactive", .kind = .boolean },
        .{ .name = "--non-interactive", .kind = .boolean, .aliases = &.{ "--noninteractive", "-y", "--yes" } },
        .{ .name = "--from", .aliases = &.{ "--browser", "--source" } },
        .{ .name = "--profile", .aliases = &.{"--source-profile"} },
        .{ .name = "--all-profiles", .kind = .boolean },
        .{ .name = "--to", .aliases = &.{ "--to-profile", "--destination-profile" } },
        .{ .name = "--create-profile", .kind = .boolean, .aliases = &.{"--create-destination-profile"} },
        .{ .name = "--domain", .aliases = &.{"--domains"} },
    });
    if (o.positionals.len > 0) {
        if (eql(o.positionals[0], "cookies")) return c.usage("browser import no longer takes a data type", .{});
        return c.usage("browser import: unexpected argument '{s}'", .{o.positionals[0]});
    }
    if (o.has("--surface") or o.has("--workspace") or o.has("--window")) return c.usage("browser import does not take a surface, workspace or window", .{});
    if (o.has("--interactive") and o.has("--non-interactive")) return c.usage("browser import: --interactive and --non-interactive cannot be used together", .{});
    const non_interactive = o.has("--non-interactive") or (!o.has("--interactive") and c.in.agent);
    var p = P.init(c.arena);
    if (!non_interactive) {
        // The wizard collects everything itself.
        for ([_][]const u8{ "--from", "--profile", "--all-profiles", "--to", "--create-profile", "--domain" }) |f| {
            if (o.has(f)) return c.usage("browser import: {s} requires --non-interactive", .{f});
        }
        return done(p, call("browser.import.dialog", .ok));
    }
    try p.str("scope", "cookiesOnly");
    try p.optStr("browser", o.get("--from"));
    try p.strings(c.arena, "source_profiles", try o.all(c.arena, "--profile"));
    try p.optStr("destination_profile", o.get("--to"));
    var domains: std.ArrayList([]const u8) = .empty;
    for (try o.all(c.arena, "--domain")) |d| {
        var it = std.mem.tokenizeAny(u8, d, ", ");
        while (it.next()) |x| try domains.append(c.arena, x);
    }
    try p.strings(c.arena, "domain_filters", domains.items);
    try p.boolean("all_profiles", o.has("--all-profiles"));
    try p.boolean("create_destination_profile", o.has("--create-profile"));
    var cl = call("browser.import.cookies", .imported);
    cl.timeout_ms = plan_mod.import_timeout_ms;
    return done(p, cl);
}

/// react-grab, devtools, focus-mode, design-mode, zoom, history and repl:
/// an optional `--surface`, else the caller's workspace.
pub fn planView(c: *C) Error!Plan {
    const v = c.in.verb;
    const o = try c.scan(&.{
        .{ .name = "--return-to" },
        .{ .name = "--force", .kind = .boolean, .aliases = &.{"--yes"} },
        .{ .name = "--script" },
    });
    const pos = o.positionals;
    var p = P.init(c.arena);
    if (!oneOf(v, &.{ "react-grab", "reactgrab" }) and o.has("--return-to")) return c.usage("browser {s} does not support --return-to", .{v});
    if (!eql(v, "history") and o.has("--force")) return c.usage("browser {s} does not support --force", .{v});
    if (!eql(v, "repl") and o.has("--script")) return c.usage("browser {s} does not support --script", .{v});
    if (eql(v, "repl")) return repl(c, o);
    try c.viewTarget(o, &p);
    if (oneOf(v, &.{ "react-grab", "reactgrab" })) {
        if (pos.len != 1 or !eql(pos[0], "toggle")) return c.usage("browser react-grab requires toggle", .{});
        if (o.get("--return-to")) |r| try p.str("return_to_surface_id", try g.checkSurface(c.arena, r, c.diag));
        return done(p, call("browser.react_grab.toggle", .ok));
    }
    if (oneOf(v, &.{ "devtools", "dev-tools" })) {
        if (pos.len != 1 or !oneOf(pos[0], &.{ "toggle", "console" })) return c.usage("browser devtools requires toggle|console", .{});
        return done(p, call(if (eql(pos[0], "toggle")) "browser.devtools.toggle" else "browser.console.show", .ok));
    }
    if (eql(v, "focus-mode")) {
        const modes = [_][]const u8{ "enter", "exit", "toggle", "on", "off" };
        if (pos.len != 1 or !oneOf(pos[0], &modes)) return c.usage("browser focus-mode requires one of: enter, exit, toggle", .{});
        const mode = if (eql(pos[0], "on")) "enter" else if (eql(pos[0], "off")) "exit" else pos[0];
        try p.str("mode", mode);
        return done(p, call("browser.focus_mode.set", .ok));
    }
    if (eql(v, "design-mode")) {
        const mode = if (pos.len > 0) pos[0] else "status";
        if (pos.len > 1 or !oneOf(mode, &.{ "enable", "disable", "toggle", "status" })) return c.usage("browser design-mode requires one of: enable, disable, toggle, status", .{});
        if (eql(mode, "status")) return done(p, call("browser.design_mode.status", .design_mode));
        try p.str("mode", mode);
        return done(p, call("browser.design_mode.set", .design_mode));
    }
    if (eql(v, "zoom")) {
        if (pos.len != 1) return c.usage("browser zoom requires in|out|reset|<factor>", .{});
        if (oneOf(pos[0], &.{ "in", "out", "reset" })) {
            try p.str("action", pos[0]);
        } else {
            const f = std.fmt.parseFloat(f64, pos[0]) catch return c.usage("browser zoom requires in|out|reset|<factor>", .{});
            if (!std.math.isFinite(f) or f <= 0) return c.usage("browser zoom factor must be a positive number", .{});
            try p.float("factor", f);
        }
        return done(p, call("browser.zoom.set", .ok));
    }
    // history clear --force|--yes
    if (pos.len != 1 or !eql(pos[0], "clear")) return c.usage("browser history requires clear --force", .{});
    if (!o.has("--force")) return c.usage("browser history clear permanently deletes history; pass --force (or --yes) to confirm", .{});
    return done(p, call("browser.history.clear", .ok));
}

/// `repl guide`, `repl list`, `repl reset`, `repl [eval] <js...>` or
/// `repl --script <js>`: the workspace's persistent Playwright-style session.
fn repl(c: *C, o: g.Opts) Error!Plan {
    const pos = o.positionals;
    if (pos.len == 1 and eql(pos[0], "guide") and !o.has("--script")) return .{ .local = .repl_guide };
    var p = P.init(c.arena);
    try c.viewTarget(o, &p);
    if (pos.len == 1 and oneOf(pos[0], &.{ "list", "reset" }) and !o.has("--script")) {
        return done(p, call(if (eql(pos[0], "list")) "browser.repl.list" else "browser.repl.reset", if (eql(pos[0], "list")) .json else .ok));
    }
    const words = if (pos.len > 0 and eql(pos[0], "eval")) pos[1..] else pos;
    const script = o.get("--script") orelse try c.joined(words);
    if (o.get("--script") != null and words.len > 0) return c.usage("browser repl: unexpected argument '{s}'", .{words[0]});
    if (std.mem.trim(u8, script, " \t\r\n").len == 0) return c.usage("browser repl requires a script (or: repl guide|list|reset)", .{});
    try p.str("script", script);
    var cl = call("browser.repl.eval", .eval);
    cl.timeout_ms = 60_000;
    return done(p, cl);
}
