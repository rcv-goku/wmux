//! CLI command family `window` (Appendix C).
//! list-windows, current-window, new-window, focus-window, close-window,
//! resize-window, window displays|display|default-display,
//! move-workspace-to-window (W2-1); shot (screenshot), record (W5b).
//!
//! Methods: `window.list`, `window.current`, `window.create`,
//! `window.focus`, `window.close`, `wmux.window.resize`, `window.displays`,
//! `window.display`, `workspace.move_to_window`. Text output follows cmux;
//! handles print per `--id-format` (default refs). `--json` prints the
//! id-formatted result.

const std = @import("std");
const selectors = @import("wmux_proto").selectors;
const command = @import("../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../output.zig");
const common = @import("ws/common.zig");
const Def = common.opts.Def;
const Params = common.Params;

const u_list = "Usage: cmux list-windows";
const u_current = "Usage: cmux current-window";
const u_new = "Usage: cmux new-window [--name <title>]";
const u_focus = "Usage: cmux focus-window --window <id|ref|index>";
const u_close = "Usage: cmux close-window --window <id|ref|index> [--force]";
const u_resize = "Usage: cmux resize-window --window <id|ref|index> [--width <points>] [--height <points>]";
const u_window = "Usage: cmux window <displays|display <name|index>|default-display [<name>|--clear]>";
const u_move = "Usage: cmux move-workspace-to-window --workspace <id|ref|index> --window <id|ref|index>";

/// `CommandSpec` entries (ADR-4.9).
pub const commands = [_]CommandSpec{
    .{ .name = "list-windows", .group = .navigate, .usage = u_list, .help = @embedFile("../help/list-windows.txt"), .run = runList },
    .{ .name = "current-window", .group = .navigate, .usage = u_current, .help = @embedFile("../help/current-window.txt"), .run = runCurrent },
    .{ .name = "new-window", .group = .navigate, .usage = u_new, .help = @embedFile("../help/new-window.txt"), .socket = .launch_if_needed, .run = runNew },
    .{ .name = "focus-window", .group = .navigate, .usage = u_focus, .help = @embedFile("../help/focus-window.txt"), .run = runFocus },
    .{ .name = "close-window", .group = .navigate, .usage = u_close, .help = @embedFile("../help/close-window.txt"), .run = runClose },
    .{ .name = "resize-window", .group = .navigate, .usage = u_resize, .help = @embedFile("../help/resize-window.txt"), .run = runResize },
    .{ .name = "window", .group = .navigate, .usage = u_window, .help = @embedFile("../help/window.txt"), .run = runWindow },
    .{ .name = "move-workspace-to-window", .group = .navigate, .usage = u_move, .help = @embedFile("../help/move-workspace-to-window.txt"), .run = runMove },
};

/// Largest accepted `--width`/`--height` (points).
pub const max_dimension: f64 = 100_000;

fn noPositionals(ctx: *Ctx, usage_line: []const u8, o: common.opts.Opts) ?u8 {
    if (o.positionals.len == 0) return null;
    return common.usage(ctx, usage_line, "unexpected argument '{s}'", .{o.positionals[0]});
}

fn runList(ctx: *Ctx) !u8 {
    var code: u8 = 0;
    const o = (try common.parseOpts(ctx, u_list, ctx.args(), &.{}, &code)) orelse return code;
    if (noPositionals(ctx, u_list, o)) |c| return c;
    var p = Params.init(ctx.arena);
    const v = switch (try common.request(ctx, "window.list", &p)) {
        .code => |c| return c,
        .ok => |v| v,
    };
    if (ctx.json()) {
        try common.writeJsonResult(ctx, v);
        return output.exit.ok;
    }
    const items = common.list(v, "windows") orelse &.{};
    if (items.len == 0) {
        try ctx.out.writeAll("No windows\n");
        return output.exit.ok;
    }
    for (items, 0..) |w, i| {
        const key = common.boolean(w, "key");
        const index = common.int(w, "index") orelse @as(i64, @intCast(i));
        const handle = (try common.handleText(ctx, w, "window")) orelse "?";
        const sel = (try selectedWorkspaceText(ctx, w)) orelse "none";
        const count = common.int(w, "workspace_count") orelse 0;
        try ctx.out.print("{s}{d}: {s} selected_workspace={s} workspaces={d}\n", .{ if (key) "* " else "  ", index, handle, sel, count });
    }
    return output.exit.ok;
}

fn selectedWorkspaceText(ctx: *Ctx, w: std.json.Value) !?[]const u8 {
    const ref = common.str(w, "selected_workspace_ref");
    const id = common.str(w, "selected_workspace_id");
    if (ref == null and id == null) return null;
    return try @import("wmux_proto").idformat.handleTextAlloc(ctx.arena, ctx.parsed.globals.id_format, ref, id, .{});
}

fn runCurrent(ctx: *Ctx) !u8 {
    var code: u8 = 0;
    const o = (try common.parseOpts(ctx, u_current, ctx.args(), &.{}, &code)) orelse return code;
    if (noPositionals(ctx, u_current, o)) |c| return c;
    var p = Params.init(ctx.arena);
    const v = switch (try common.request(ctx, "window.current", &p)) {
        .code => |c| return c,
        .ok => |v| v,
    };
    if (ctx.json()) {
        try common.writeJsonResult(ctx, v);
        return output.exit.ok;
    }
    const handle = (try common.handleText(ctx, v, "window")) orelse return ctx.runtimeError("No active window", .{});
    try ctx.out.print("{s}\n", .{handle});
    return output.exit.ok;
}

fn runNew(ctx: *Ctx) !u8 {
    var code: u8 = 0;
    const o = (try common.parseOpts(ctx, u_new, ctx.args(), &.{.{ .name = "--name" }}, &code)) orelse return code;
    if (noPositionals(ctx, u_new, o)) |c| return c;
    var p = Params.init(ctx.arena);
    if (o.get("--name")) |name| {
        if (std.mem.trim(u8, name, " \t\r\n").len == 0) return common.usage(ctx, u_new, "--name requires a non-empty value", .{});
        try p.str("title", name);
    }
    return common.created(ctx, "window.create", &p, "window");
}

/// Commands whose only target is a required window (`--window` after the
/// command, or the global one before it).
fn requiredWindow(ctx: *Ctx, usage_line: []const u8, o: common.opts.Opts, p: *Params) !?u8 {
    const w = common.windowText(ctx, o) orelse return common.usage(ctx, usage_line, "{s} requires --window", .{ctx.command});
    return common.putHandle(ctx, p, usage_line, "window_id", .window, w);
}

fn runFocus(ctx: *Ctx) !u8 {
    var code: u8 = 0;
    const o = (try common.parseOpts(ctx, u_focus, ctx.args(), &.{.{ .name = "--window" }}, &code)) orelse return code;
    if (noPositionals(ctx, u_focus, o)) |c| return c;
    var p = Params.init(ctx.arena);
    if (try requiredWindow(ctx, u_focus, o, &p)) |c| return c;
    // Bringing the window to front needs the foreground grant (ADR-3.11),
    // which only an interactive, non-agent caller hands over.
    if (!try common.grantForeground(ctx, &p)) return output.exit.runtime;
    return common.simple(ctx, "window.focus", &p, &.{});
}

fn runClose(ctx: *Ctx) !u8 {
    var code: u8 = 0;
    const defs = [_]Def{ .{ .name = "--window" }, .{ .name = "--force", .takes_value = false } };
    const o = (try common.parseOpts(ctx, u_close, ctx.args(), &defs, &code)) orelse return code;
    if (noPositionals(ctx, u_close, o)) |c| return c;
    var p = Params.init(ctx.arena);
    if (try requiredWindow(ctx, u_close, o, &p)) |c| return c;
    if (o.has("--force")) try p.boolean("force", true);
    return common.simple(ctx, "window.close", &p, &.{});
}

/// A `--width`/`--height` value: finite, > 0 and <= 100000.
pub fn parseDimension(s: []const u8) ?f64 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 0) return null;
    for (t) |c| if (!(std.ascii.isDigit(c) or c == '.')) return null;
    const v = std.fmt.parseFloat(f64, t) catch return null;
    if (!std.math.isFinite(v) or v <= 0 or v > max_dimension) return null;
    return v;
}

fn putDimension(p: *Params, key: []const u8, v: f64) !void {
    if (@floor(v) == v) try p.int(key, @intFromFloat(v)) else try p.value(key, .{ .float = v });
}

fn runResize(ctx: *Ctx) !u8 {
    var code: u8 = 0;
    const defs = [_]Def{ .{ .name = "--window" }, .{ .name = "--width" }, .{ .name = "--height" } };
    const o = (try common.parseOpts(ctx, u_resize, ctx.args(), &defs, &code)) orelse return code;
    if (noPositionals(ctx, u_resize, o)) |c| return c;
    var p = Params.init(ctx.arena);
    if (try requiredWindow(ctx, u_resize, o, &p)) |c| return c;
    for ([_][]const u8{ "--width", "--height" }) |flag| {
        if (o.get(flag)) |s| {
            const v = parseDimension(s) orelse return common.usage(ctx, u_resize, "{s} must be a finite number greater than 0 and at most 100000 (got '{s}')", .{ flag, s });
            try putDimension(&p, flag[2..], v);
        }
    }
    const v = switch (try common.request(ctx, "wmux.window.resize", &p)) {
        .code => |c| return c,
        .ok => |v| v,
    };
    if (ctx.json()) {
        try common.writeJsonResult(ctx, v);
        return output.exit.ok;
    }
    try ctx.out.writeAll("OK");
    const frame = common.field(v, "frame") orelse v;
    if (common.field(frame, "width")) |w| if (common.field(frame, "height")) |h| {
        try ctx.out.writeByte(' ');
        try common.writeNumber(ctx.out, w);
        try ctx.out.writeByte(' ');
        try common.writeNumber(ctx.out, h);
    };
    try ctx.out.writeByte('\n');
    return output.exit.ok;
}

fn runWindow(ctx: *Ctx) !u8 {
    const a = ctx.args();
    if (a.len == 0) return common.usage(ctx, u_window, "window requires a subcommand: displays, display, default-display", .{});
    const sub = a[0];
    const rest = a[1..];
    if (std.mem.eql(u8, sub, "displays") or std.mem.eql(u8, sub, "--list") or std.mem.eql(u8, sub, "-l")) return runDisplays(ctx, rest);
    if (std.mem.eql(u8, sub, "display")) return runDisplay(ctx, rest);
    if (std.mem.eql(u8, sub, "default-display")) return runDefaultDisplay(ctx, rest);
    return common.usage(ctx, u_window, "unknown window subcommand '{s}'; expected one of: displays, display, default-display", .{sub});
}

fn runDisplays(ctx: *Ctx, args: []const []const u8) !u8 {
    var code: u8 = 0;
    const o = (try common.parseOpts(ctx, u_window, args, &.{}, &code)) orelse return code;
    if (noPositionals(ctx, u_window, o)) |c| return c;
    var p = Params.init(ctx.arena);
    const v = switch (try common.request(ctx, "window.displays", &p)) {
        .code => |c| return c,
        .ok => |v| v,
    };
    if (ctx.json()) {
        try common.writeJsonResult(ctx, v);
        return output.exit.ok;
    }
    const items = common.list(v, "displays") orelse &.{};
    if (items.len == 0) {
        try ctx.out.writeAll("No displays found.\n");
        return output.exit.ok;
    }
    for (items, 0..) |d, i| {
        const index = common.int(d, "index") orelse @as(i64, @intCast(i));
        try ctx.out.print("{d}: {s}{s}\n", .{ index, common.str(d, "name") orelse "", if (common.boolean(d, "main")) "  (main)" else "" });
    }
    return output.exit.ok;
}

fn runDisplay(ctx: *Ctx, args: []const []const u8) !u8 {
    // `window display --list` aliases `window displays`.
    if (args.len > 0 and (std.mem.eql(u8, args[0], "--list") or std.mem.eql(u8, args[0], "-l"))) return runDisplays(ctx, args[1..]);
    var code: u8 = 0;
    const defs = [_]Def{ .{ .name = "--list", .takes_value = false }, .{ .name = "--window" } };
    const o = (try common.parseOpts(ctx, u_window, args, &defs, &code)) orelse return code;
    if (o.has("--list")) return runDisplays(ctx, o.positionals);
    if (o.positionals.len == 0 or std.mem.trim(u8, o.positionals[0], " \t").len == 0) return common.usage(ctx, u_window, "window display requires a display name or index", .{});
    if (o.positionals.len > 1) return common.usage(ctx, u_window, "unexpected argument '{s}'", .{o.positionals[1]});
    var p = Params.init(ctx.arena);
    try p.str("display", o.positionals[0]);
    if (try common.putWindow(ctx, &p, u_window, o)) |c| return c;
    const v = switch (try common.request(ctx, "window.display", &p)) {
        .code => |c| return c,
        .ok => |v| v,
    };
    if (ctx.json()) {
        try common.writeJsonResult(ctx, v);
        return output.exit.ok;
    }
    // cmux's result lists the moved window ids (`moved: [...]`); a count
    // is accepted too.
    const moved: usize = if (common.field(v, "moved")) |m| switch (m) {
        .array => |arr| arr.items.len,
        else => if (common.int(v, "moved")) |n| (if (n > 0) @intCast(n) else 0) else 0,
    } else 0;
    const display = common.str(v, "display") orelse common.str(common.field(v, "display"), "name") orelse o.positionals[0];
    try ctx.out.print("Moved {d} window{s} to {s}.\n", .{ moved, if (moved == 1) "" else "s", display });
    return output.exit.ok;
}

/// `window default-display` configures where cmux DEBUG dev builds open new
/// windows (`app.devWindowDisplay`); wmux has no such placement, so every
/// valid form reports that it is not supported (exit 2).
fn runDefaultDisplay(ctx: *Ctx, args: []const []const u8) !u8 {
    var code: u8 = 0;
    const o = (try common.parseOpts(ctx, u_window, args, &.{.{ .name = "--clear", .takes_value = false }}, &code)) orelse return code;
    if (o.positionals.len > 1) return common.usage(ctx, u_window, "unexpected argument '{s}'", .{o.positionals[1]});
    if (o.has("--clear") and o.positionals.len > 0) return common.usage(ctx, u_window, "window default-display takes a name or --clear, not both", .{});
    try ctx.err.print("{s} window default-display: not supported on wmux (dev-build window placement is macOS-only)\n", .{ctx.brand.name()});
    return output.exit.usage;
}

fn runMove(ctx: *Ctx) !u8 {
    var code: u8 = 0;
    const defs = [_]Def{ .{ .name = "--workspace" }, .{ .name = "--window" } };
    const o = (try common.parseOpts(ctx, u_move, ctx.args(), &defs, &code)) orelse return code;
    if (noPositionals(ctx, u_move, o)) |c| return c;
    var p = Params.init(ctx.arena);
    if (try common.putWorkspaceTarget(ctx, &p, u_move, o.get("--workspace"), false)) |c| return c;
    const ws = p.map.get("workspace_id") orelse return common.usage(ctx, u_move, "move-workspace-to-window requires --workspace", .{});
    if (try requiredWindow(ctx, u_move, o, &p)) |c| return c;
    // `window_id` is the destination here, and the server reads a workspace
    // index in the `window_id` window (ADR-2.4). Like cmux, resolve an index
    // first, in the caller's (or the active) window.
    if (ws == .integer) switch (try resolveWorkspaceIndex(ctx, ws.integer)) {
        .code => |c| return c,
        .handle => |h| try p.str("workspace_id", h),
    };
    return common.simple(ctx, "workspace.move_to_window", &p, &.{ "workspace", "window" });
}

const Resolved = union(enum) { handle: []const u8, code: u8 };

/// The workspace at `index` of the caller's (or the active) window, from
/// `workspace.list` without a window: its UUID, else its ref. Failures are
/// reported (exit code in `.code`).
fn resolveWorkspaceIndex(ctx: *Ctx, index: i64) !Resolved {
    var lp = Params.init(ctx.arena);
    const v = switch (try common.request(ctx, "workspace.list", &lp)) {
        .code => |c| return .{ .code = c },
        .ok => |v| v,
    };
    for (common.list(v, "workspaces") orelse &.{}) |w| {
        const i = common.int(w, "index") orelse continue;
        if (i != index) continue;
        if (common.str(w, "id") orelse common.str(w, "ref")) |h| return .{ .handle = h };
    }
    const msg = try selectors.cliMessage(ctx.arena, .index_not_found, .workspace, "");
    return .{ .code = ctx.runtimeError("{s}", .{msg}) };
}

// ----- tests -----

const testing = std.testing;
const testkit = @import("ws/testkit.zig");

test {
    _ = common;
    _ = common.opts;
}

test "unit: cli-window: offline help for every window command" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    const cases = [_]struct { []const []const u8, []const u8 }{
        .{ &.{"list-windows"}, "list-windows-help.txt" },
        .{ &.{"current-window"}, "current-window-help.txt" },
        .{ &.{"new-window"}, "new-window-help.txt" },
        .{ &.{"focus-window"}, "focus-window-help.txt" },
        .{ &.{"close-window"}, "close-window-help.txt" },
        .{ &.{"resize-window"}, "resize-window-help.txt" },
        .{ &.{ "window", "displays" }, "window-help.txt" },
        .{ &.{"move-workspace-to-window"}, "move-workspace-to-window-help.txt" },
    };
    for (cases) |c| try testkit.expectHelpGolden(&h, c[0], c[1]);
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
}

const windows_json =
    \\{"windows":[{"id":"6F1D2C3B-0000-4000-8000-000000000001","ref":"window:1","index":0,"key":true,"workspace_count":3,"selected_workspace_id":"9B690000-0000-4000-8000-000000000002","selected_workspace_ref":"workspace:2"},{"id":"6F1D2C3B-0000-4000-8000-000000000003","ref":"window:3","index":1,"key":false,"workspace_count":1,"selected_workspace_id":null,"selected_workspace_ref":null}]}
;

test "unit: cli-window: list-windows text, id formats, json and empty" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("window.list", windows_json);
    const out = try testkit.expectOk(&h, &.{"list-windows"});
    try testkit.expectGolden(h.alloc(), "list-windows.txt", out);
    try h.expectLast("window.list", "{}");
    const both = try testkit.expectOk(&h, &.{ "list-windows", "--id-format", "both" });
    try testkit.expectGolden(h.alloc(), "list-windows-both.txt", both);
    const uuids = try testkit.expectOk(&h, &.{ "--id-format", "uuids", "list-windows" });
    try testing.expect(std.mem.startsWith(u8, uuids, "* 0: 6F1D2C3B-0000-4000-8000-000000000001 selected_workspace=9B690000-0000-4000-8000-000000000002 workspaces=3\n"));
    const js = try testkit.expectOk(&h, &.{ "list-windows", "--json" });
    try testkit.expectGolden(h.alloc(), "list-windows-json.txt", js);
    h.ok("window.list", "{\"windows\":[]}");
    try testing.expectEqualStrings("No windows\n", try testkit.expectOk(&h, &.{"list-windows"}));
    try testkit.expectUsage(&h, &.{ "list-windows", "extra" }, "unexpected argument 'extra'");
    try testkit.expectUsage(&h, &.{ "list-windows", "--all" }, "unknown option '--all'");
}

test "unit: cli-window: current-window prints the handle and fails without one" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("window.current", "{\"window_id\":\"6F1D2C3B-0000-4000-8000-000000000001\",\"window_ref\":\"window:1\"}");
    const out = try testkit.expectOk(&h, &.{"current-window"});
    try testkit.expectGolden(h.alloc(), "current-window.txt", out);
    try h.expectLast("window.current", "{}");
    try testing.expectEqualStrings("6F1D2C3B-0000-4000-8000-000000000001\n", try testkit.expectOk(&h, &.{ "current-window", "--id-format", "uuids" }));
    try testing.expectEqualStrings("{\n  \"window_ref\": \"window:1\"\n}\n", try testkit.expectOk(&h, &.{ "current-window", "--json" }));
    h.ok("window.current", "{}");
    const r = h.run(&.{"current-window"});
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings("cmux: No active window\n", r.err);
    h.fail("window.current", "{\"code\":\"not_found\",\"message\":\"No active window\"}");
    const e = h.run(&.{"current-window"});
    try testing.expectEqual(@as(u8, 1), e.code);
    try testing.expectEqualStrings("not_found: No active window\n", e.err);
}

test "unit: cli-window: new-window sends the title and validates it" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("window.create", "{\"window_id\":\"6F1D2C3B-0000-4000-8000-000000000004\",\"window_ref\":\"window:4\",\"workspace_id\":\"W\",\"workspace_ref\":\"workspace:9\"}");
    const out = try testkit.expectOk(&h, &.{ "new-window", "--name", "Build \u{1F680}" });
    try testkit.expectGolden(h.alloc(), "new-window.txt", out);
    try h.expectLast("window.create", "{\"title\":\"Build \u{1F680}\"}");
    _ = try testkit.expectOk(&h, &.{"new-window"});
    try h.expectLast("window.create", "{}");
    _ = try testkit.expectOk(&h, &.{ "new-window", "--name=x" });
    try h.expectLast("window.create", "{\"title\":\"x\"}");
    try testkit.expectUsage(&h, &.{ "new-window", "--name" }, "--name requires a value");
    try testkit.expectUsage(&h, &.{ "new-window", "--name", "--json" }, "--name requires a value");
    try testkit.expectUsage(&h, &.{ "new-window", "--name", "  " }, "--name requires a non-empty value");
    try testkit.expectUsage(&h, &.{ "new-window", "--name=" }, "--name requires a non-empty value");
    try testkit.expectUsage(&h, &.{ "new-window", "title" }, "unexpected argument 'title'");
}

test "unit: cli-window: focus-window and close-window require a window" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("window.focus", "{\"window_id\":\"A\",\"window_ref\":\"window:2\"}");
    h.ok("window.close", "{}");
    try testing.expectEqualStrings("OK\n", try testkit.expectOk(&h, &.{ "focus-window", "--window", "window:2" }));
    try h.expectLast("window.focus", "{\"window_id\":\"window:2\"}");
    _ = try testkit.expectOk(&h, &.{ "--window", "1", "focus-window" });
    try h.expectLast("window.focus", "{\"window_id\":1}");
    _ = try testkit.expectOk(&h, &.{ "focus-window", "--window", "6f1d2c3b-0000-4000-8000-000000000001" });
    try h.expectLast("window.focus", "{\"window_id\":\"6f1d2c3b-0000-4000-8000-000000000001\"}");
    try testkit.expectUsage(&h, &.{"focus-window"}, "focus-window requires --window");
    try testkit.expectUsage(&h, &.{ "focus-window", "--window", "workspace:1" }, "Invalid window handle: workspace:1 (expected UUID, ref like window:1, or index)");
    try testkit.expectUsage(&h, &.{ "focus-window", "--window", " " }, "Window handle is blank");
    try testkit.expectUsage(&h, &.{ "focus-window", "--window", "window:0" }, "Invalid window handle: window:0 (expected UUID, ref like window:1, or index)");
    try testing.expectEqualStrings("OK\n", try testkit.expectOk(&h, &.{ "close-window", "--window", "window:2", "--force" }));
    try h.expectLast("window.close", "{\"window_id\":\"window:2\",\"force\":true}");
    _ = try testkit.expectOk(&h, &.{ "close-window", "--window=window:3" });
    try h.expectLast("window.close", "{\"window_id\":\"window:3\"}");
    try testkit.expectUsage(&h, &.{ "close-window", "--force" }, "close-window requires --window");
    try testkit.expectUsage(&h, &.{ "close-window", "--window", "window:2", "--force=1" }, "--force does not take a value");
    const j = try testkit.expectOk(&h, &.{ "focus-window", "--window", "window:2", "--json" });
    try testing.expectEqualStrings("{\n  \"window_ref\": \"window:2\"\n}\n", j);
}

test "unit: cli-window: focus-window hands the foreground grant only to interactive callers" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("window.focus", "{}");
    _ = try testkit.expectOk(&h, &.{ "focus-window", "--window", "window:2" });
    try h.expectLast("window.focus", "{\"window_id\":\"window:2\"}");
    try testing.expectEqual(@as(usize, 0), h.fp.foreground_grants.items.len);
    h.fp.interactive = true;
    _ = try testkit.expectOk(&h, &.{ "focus-window", "--window", "window:2" });
    try h.expectLast("window.focus", "{\"window_id\":\"window:2\",\"focus\":true,\"foreground_grant\":true}");
    try testing.expectEqualSlices(u32, &.{4242}, h.fp.foreground_grants.items);
    h.setEnv("CLAUDECODE", "1");
    _ = try testkit.expectOk(&h, &.{ "focus-window", "--window", "window:2" });
    try h.expectLast("window.focus", "{\"window_id\":\"window:2\"}");
    try testing.expectEqual(@as(usize, 1), h.fp.foreground_grants.items.len);
}

test "unit: cli-window: focus-window grants the foreground through an explicit pipe" {
    // Inside wmux terminals CMUX_SOCKET_PATH names the pipe, so discovery
    // does not open it; the grant must still reach the server.
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("window.focus", "{}");
    h.fp.interactive = true;
    h.setEnv("CMUX_SOCKET_PATH", h.control);
    _ = try testkit.expectOk(&h, &.{ "focus-window", "--window", "window:2" });
    try h.expectLast("window.focus", "{\"window_id\":\"window:2\",\"focus\":true,\"foreground_grant\":true}");
    try testing.expectEqualSlices(u32, &.{4242}, h.fp.foreground_grants.items);
    // One connection carries the request.
    try testing.expectEqual(@as(usize, 1), h.fp.connects);
    h.unsetEnv("CMUX_SOCKET_PATH");
    _ = try testkit.expectOk(&h, &.{ "--socket", h.control, "focus-window", "--window", "1" });
    try h.expectLast("window.focus", "{\"window_id\":1,\"focus\":true,\"foreground_grant\":true}");
    try testing.expectEqual(@as(usize, 2), h.fp.foreground_grants.items.len);
    // A pipe that cannot be opened is reported by the request, once.
    const r = h.run(&.{ "--socket", "wmux-missing", "focus-window", "--window", "1" });
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqual(@as(usize, 2), h.fp.foreground_grants.items.len);
    try testing.expectEqualStrings("cannot connect to \\\\.\\pipe\\wmux-missing: no such pipe (is wmux running?)\n", r.err);
    // Without any app the discovery failure prints once and exits 1.
    h.fp.servers.clearRetainingCapacity();
    for ([_]bool{ true, false }) |interactive| {
        h.fp.interactive = interactive;
        const none = h.run(&.{ "focus-window", "--window", "1" });
        try testing.expectEqual(@as(u8, 1), none.code);
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, none.err, "No live wmux socket found"));
    }
}

test "unit: cli-window: resize-window reads or sets the frame and validates dimensions" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("wmux.window.resize", "{\"window_id\":\"A\",\"window_ref\":\"window:1\",\"width\":1280,\"height\":400.0}");
    const out = try testkit.expectOk(&h, &.{ "resize-window", "--window", "0" });
    try testkit.expectGolden(h.alloc(), "resize-window.txt", out);
    try h.expectLast("wmux.window.resize", "{\"window_id\":0}");
    _ = try testkit.expectOk(&h, &.{ "resize-window", "--window", "window:1", "--height", "400" });
    try h.expectLast("wmux.window.resize", "{\"window_id\":\"window:1\",\"height\":400}");
    _ = try testkit.expectOk(&h, &.{ "resize-window", "--window", "window:1", "--width", "800.5", "--height=100000" });
    try h.expectLast("wmux.window.resize", "{\"window_id\":\"window:1\",\"width\":800.5,\"height\":100000}");
    h.ok("wmux.window.resize", "{\"frame\":{\"width\":640.25,\"height\":480}}");
    try testing.expectEqualStrings("OK 640.25 480\n", try testkit.expectOk(&h, &.{ "resize-window", "--window", "window:1" }));
    const bad = [_][]const u8{ "0", "-5", "100001", "nan", "inf", "1e3", "", "abc", "1.2.3" };
    for (bad) |b| {
        const msg = try std.fmt.allocPrint(h.alloc(), "--width must be a finite number greater than 0 and at most 100000 (got '{s}')", .{b});
        const arg = try std.fmt.allocPrint(h.alloc(), "--width={s}", .{b});
        try testkit.expectUsage(&h, &.{ "resize-window", "--window", "window:1", arg }, msg);
    }
    try testkit.expectUsage(&h, &.{ "resize-window", "--width", "10" }, "resize-window requires --window");
    try testing.expectEqual(@as(?f64, 0.5), parseDimension("0.5"));
    try testing.expectEqual(@as(?f64, 100000), parseDimension(" 100000 "));
}

test "unit: cli-window: window displays and display" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("window.displays", "{\"displays\":[{\"name\":\"\\\\\\\\.\\\\DISPLAY1 Dell U2720Q\",\"index\":0,\"main\":true},{\"name\":\"LG \\u00e9cran\",\"index\":1,\"main\":false}]}");
    const out = try testkit.expectOk(&h, &.{ "window", "displays" });
    try testkit.expectGolden(h.alloc(), "window-displays.txt", out);
    try h.expectLast("window.displays", "{}");
    try testing.expectEqualStrings(out, try testkit.expectOk(&h, &.{ "window", "--list" }));
    try testing.expectEqualStrings(out, try testkit.expectOk(&h, &.{ "window", "display", "-l" }));
    try testing.expectEqualStrings(out, try testkit.expectOk(&h, &.{ "window", "display", "--list" }));
    h.ok("window.displays", "{\"displays\":[]}");
    try testing.expectEqualStrings("No displays found.\n", try testkit.expectOk(&h, &.{ "window", "displays" }));

    // cmux's result: the resolved display name and the moved window ids.
    h.ok("window.display", "{\"display\":\"LG \\u00e9cran\",\"moved\":[\"6F1D2C3B-0000-4000-8000-000000000001\",\"6F1D2C3B-0000-4000-8000-000000000003\"]}");
    const moved = try testkit.expectOk(&h, &.{ "window", "display", "1" });
    try testkit.expectGolden(h.alloc(), "window-display.txt", moved);
    try h.expectLast("window.display", "{\"display\":\"1\"}");
    _ = try testkit.expectOk(&h, &.{ "--window", "window:2", "window", "display", "LG" });
    try h.expectLast("window.display", "{\"display\":\"LG\",\"window_id\":\"window:2\"}");
    _ = try testkit.expectOk(&h, &.{ "window", "display", "LG", "--window", "window:3" });
    try h.expectLast("window.display", "{\"display\":\"LG\",\"window_id\":\"window:3\"}");
    h.ok("window.display", "{\"display\":\"DELL\",\"moved\":[\"6F1D2C3B-0000-4000-8000-000000000001\"]}");
    try testing.expectEqualStrings("Moved 1 window to DELL.\n", try testkit.expectOk(&h, &.{ "window", "display", "DE" }));
    h.ok("window.display", "{\"display\":\"DELL\",\"moved\":[]}");
    try testing.expectEqualStrings("Moved 0 windows to DELL.\n", try testkit.expectOk(&h, &.{ "window", "display", "DE" }));
    // A count and a display object are accepted too; a missing name falls
    // back to the argument.
    h.ok("window.display", "{\"moved\":3,\"display\":{\"name\":\"LG\"}}");
    try testing.expectEqualStrings("Moved 3 windows to LG.\n", try testkit.expectOk(&h, &.{ "window", "display", "1" }));
    h.ok("window.display", "{\"moved\":-1}");
    try testing.expectEqualStrings("Moved 0 windows to 2.\n", try testkit.expectOk(&h, &.{ "window", "display", "2" }));

    try testkit.expectUsage(&h, &.{"window"}, "window requires a subcommand: displays, display, default-display");
    try testkit.expectUsage(&h, &.{ "window", "bogus" }, "unknown window subcommand 'bogus'; expected one of: displays, display, default-display");
    try testkit.expectUsage(&h, &.{ "window", "display" }, "window display requires a display name or index");
    try testkit.expectUsage(&h, &.{ "window", "display", "a", "b" }, "unexpected argument 'b'");
    try testkit.expectUsage(&h, &.{ "window", "displays", "x" }, "unexpected argument 'x'");
}

test "unit: cli-window: window default-display is not supported on wmux" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    for ([_][]const []const u8{ &.{ "window", "default-display" }, &.{ "window", "default-display", "DELL" }, &.{ "window", "default-display", "--clear" } }) |argv| {
        const r = h.run(argv);
        try testing.expectEqual(@as(u8, 2), r.code);
        try testing.expectEqualStrings("cmux window default-display: not supported on wmux (dev-build window placement is macOS-only)\n", r.err);
    }
    try testkit.expectUsage(&h, &.{ "window", "default-display", "a", "--clear" }, "window default-display takes a name or --clear, not both");
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
}

test "unit: cli-window: move-workspace-to-window targets and defaults" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.move_to_window", "{\"workspace_ref\":\"workspace:3\",\"window_ref\":\"window:2\"}");
    try testing.expectEqualStrings("OK workspace:3 window:2\n", try testkit.expectOk(&h, &.{ "move-workspace-to-window", "--workspace", "workspace:3", "--window", "window:2" }));
    try h.expectLast("workspace.move_to_window", "{\"workspace_id\":\"workspace:3\",\"window_id\":\"window:2\"}");
    h.ok("workspace.move_to_window", "{}");
    try testkit.expectUsage(&h, &.{ "move-workspace-to-window", "--window", "window:2" }, "move-workspace-to-window requires --workspace");
    h.setEnv("CMUX_WORKSPACE_ID", "9B690000-0000-4000-8000-000000000002");
    _ = try testkit.expectOk(&h, &.{ "move-workspace-to-window", "--window", "2" });
    try h.expectLast("workspace.move_to_window", "{\"workspace_id\":\"9B690000-0000-4000-8000-000000000002\",\"window_id\":2}");
    try testkit.expectUsage(&h, &.{"move-workspace-to-window"}, "move-workspace-to-window requires --window");
    try testkit.expectUsage(&h, &.{ "move-workspace-to-window", "--workspace", "pane:1", "--window", "1" }, "Invalid workspace handle: pane:1 (expected UUID, ref like workspace:1, or index)");
}

test "unit: cli-window: move-workspace-to-window resolves an index before naming the destination" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("workspace.list", "{\"window_ref\":\"window:1\",\"workspaces\":[{\"id\":\"9B690000-0000-4000-8000-000000000001\",\"ref\":\"workspace:1\",\"index\":0},{\"id\":\"9B690000-0000-4000-8000-000000000004\",\"ref\":\"workspace:4\",\"index\":1}]}");
    h.ok("workspace.move_to_window", "{\"workspace_ref\":\"workspace:4\",\"window_ref\":\"window:2\"}");
    // The index counts in the caller's (or the active) window: the list is
    // asked without a window, and the move names the workspace's UUID.
    try testing.expectEqualStrings("OK workspace:4 window:2\n", try testkit.expectOk(&h, &.{ "move-workspace-to-window", "--workspace", "1", "--window", "window:2" }));
    const reqs = h.requests();
    try testing.expectEqual(@as(usize, 2), reqs.len);
    try testing.expectEqualStrings("workspace.list", reqs[0].method);
    try testing.expectEqualStrings("{}", reqs[0].params_json);
    try h.expectLast("workspace.move_to_window", "{\"workspace_id\":\"9B690000-0000-4000-8000-000000000004\",\"window_id\":\"window:2\"}");
    // Refs and UUIDs go out as typed, without a lookup.
    _ = try testkit.expectOk(&h, &.{ "move-workspace-to-window", "--workspace", "workspace:4", "--window", "window:2" });
    try testing.expectEqual(@as(usize, 3), h.requestCount());
    // A row without a UUID gives its ref.
    h.ok("workspace.list", "{\"workspaces\":[{\"title\":\"no index\"},{\"ref\":\"workspace:7\",\"index\":0}]}");
    _ = try testkit.expectOk(&h, &.{ "move-workspace-to-window", "--workspace", "0", "--window", "2" });
    try h.expectLast("workspace.move_to_window", "{\"workspace_id\":\"workspace:7\",\"window_id\":2}");
    // A missing index fails after the lookup and moves nothing.
    const before = h.requestCount();
    const r = h.run(&.{ "move-workspace-to-window", "--workspace", "5", "--window", "window:2" });
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings("cmux: Workspace index not found\n", r.err);
    try testing.expectEqual(before + 1, h.requestCount());
    // A failed lookup is reported as the server's error.
    h.fail("workspace.list", "{\"code\":\"unavailable\",\"message\":\"TabManager not available\"}");
    const f = h.run(&.{ "move-workspace-to-window", "--workspace", "0", "--window", "window:2" });
    try testing.expectEqual(@as(u8, 1), f.code);
    try testing.expectEqualStrings("unavailable: TabManager not available\n", f.err);
    try testing.expectEqualStrings("workspace.list", h.requests()[h.requestCount() - 1].method);
}

test "unit: cli-window: server errors and missing app exit 1" {
    var h: testkit.Harness = undefined;
    try h.init();
    defer h.deinit();
    h.fail("window.focus", "{\"code\":\"not_found\",\"message\":\"Window not found\"}");
    const r = h.run(&.{ "focus-window", "--window", "window:9" });
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings("not_found: Window not found\n", r.err);
    const skew = h.run(&.{ "window", "displays" });
    try testing.expectEqual(@as(u8, 1), skew.code);
    try testing.expect(std.mem.indexOf(u8, skew.err, "Fix: the app does not know 'window.displays'") != null);
}
