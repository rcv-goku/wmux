//! CLI command family `right_sidebar` (Appendix C).
//! right-sidebar <sub>. Owner: W1-8 (CLI: cf-cli-misc).
//!
//! `right-sidebar toggle|show|hide|focus` change visibility or focus and
//! print nothing on success; `set <mode>` (and the mode words as short
//! aliases) shows the sidebar in that mode and focuses it unless
//! `--no-focus`; `mode` prints `{visible, mode}` JSON. `--window` targets a
//! window, `--workspace` the window holding that workspace; without either
//! the caller's workspace (`CMUX_WORKSPACE_ID`) picks the window. Methods:
//! `wmux.right_sidebar.{toggle,show,hide,focus,set,get}` (Appendix B.3).
//! cmux's Cloud modes (`cloud`, `devices` and their aliases) are refused.

const std = @import("std");
const command = @import("../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../output.zig");
const util = @import("cli_misc/util.zig");

pub const usage = "Usage: cmux right-sidebar <command> [flags]";

/// `CommandSpec` entries (ADR-4.9).
pub const commands = [_]CommandSpec{
    .{ .name = "right-sidebar", .group = .customize, .usage = usage, .help = @embedFile("../help/right-sidebar.txt"), .run = run },
};

/// wmux right-sidebar modes (ADR-11.6); `vault` and `sessions` share a host.
pub const modes = [_][]const u8{ "files", "find", "vault", "sessions", "feed", "dock" };

/// cmux Cloud panel modes and their aliases (not available on Windows).
pub const cloud_modes = [_][]const u8{ "cloud", "machines", "vms", "devices", "device", "macs" };

const flag_specs = [_]util.FlagSpec{
    .{ .name = "--window", .value = true },
    .{ .name = "--workspace", .value = true },
    .{ .name = "--no-focus" },
};

fn isIn(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn run(ctx: *Ctx) !u8 {
    const flags = (try util.flagsOrFail(ctx, "right-sidebar", usage, ctx.args(), &flag_specs)) orelse return output.exit.usage;
    const pos = flags.positionals;
    if (pos.len == 0) return util.usageFail(ctx, usage, "right-sidebar requires a command (toggle, show, hide, focus, set <mode>, mode)", .{});
    const sub = pos[0];

    var mode: ?[]const u8 = null;
    var method: []const u8 = undefined;
    var extra: usize = 1;
    if (std.mem.eql(u8, sub, "toggle") or std.mem.eql(u8, sub, "show") or std.mem.eql(u8, sub, "hide") or std.mem.eql(u8, sub, "focus")) {
        method = try std.fmt.allocPrint(ctx.arena, "wmux.right_sidebar.{s}", .{sub});
    } else if (std.mem.eql(u8, sub, "mode")) {
        method = "wmux.right_sidebar.get";
    } else if (std.mem.eql(u8, sub, "set")) {
        if (pos.len < 2) return util.usageFail(ctx, usage, "right-sidebar set requires a mode ({s})", .{try std.mem.join(ctx.arena, ", ", &modes)});
        mode = pos[1];
        extra = 2;
        method = "wmux.right_sidebar.set";
    } else if (isIn(&modes, sub) or isIn(&cloud_modes, sub)) {
        mode = sub;
        method = "wmux.right_sidebar.set";
    } else {
        return util.usageFail(ctx, usage, "unknown right-sidebar command '{s}'", .{sub});
    }
    if (pos.len > extra) return util.usageFail(ctx, usage, "right-sidebar {s}: unexpected argument '{s}'", .{ sub, pos[extra] });
    if (mode) |m| {
        if (isIn(&cloud_modes, m)) {
            try ctx.err.print("{s} right-sidebar {s}: not supported on wmux (requires cmux cloud/macOS)\n", .{ ctx.brand.name(), m });
            return output.exit.usage;
        }
        if (!isIn(&modes, m)) return util.usageFail(ctx, usage, "unknown right-sidebar mode '{s}' (expected one of: {s})", .{ m, try std.mem.join(ctx.arena, ", ", &modes) });
    } else if (flags.has("--no-focus")) {
        return util.usageFail(ctx, usage, "--no-focus is only valid with right-sidebar set", .{});
    }

    const target = util.resolveTarget(ctx, flags, .{}) orelse return output.exit.usage;
    var params = util.Params.init(ctx.arena);
    try params.optStr("window_id", target.window);
    try params.optStr("workspace_id", target.workspace);
    if (mode) |m| {
        try params.str("mode", m);
        try params.boolean("focus", !flags.has("--no-focus"));
    }
    const r = (try util.call(ctx, method, &params)) orelse return output.exit.runtime;
    // `mode` always prints JSON; the mutations print only with --json.
    if (mode == null and std.mem.eql(u8, sub, "mode")) {
        try util.writeJsonResult(ctx, .{ .object = try modeView(ctx, r) });
    } else if (ctx.json()) try util.writeJsonResult(ctx, r);
    return output.exit.ok;
}

/// `{visible, mode}` from the `wmux.right_sidebar.get` result.
fn modeView(ctx: *Ctx, r: std.json.Value) !std.json.ObjectMap {
    var o = std.json.ObjectMap.init(ctx.arena);
    try o.put("visible", util.field(r, "visible") orelse .{ .bool = false });
    try o.put("mode", util.field(r, "mode") orelse .null);
    return o;
}

// ----- tests -----

const testing = std.testing;
const harness = @import("cli_misc/harness.zig");
const fake = @import("../fake.zig");

fn echoHandler(server: *fake.Server, req: fake.Request) fake.Action {
    if (std.mem.eql(u8, req.method, "wmux.right_sidebar.get")) return .{ .ok = "{\"visible\":true,\"mode\":\"files\",\"window_id\":\"W\",\"width\":300}" };
    return .{ .ok = std.fmt.allocPrint(server.a, "{{\"ok\":true,\"echo\":{s}}}", .{req.params_json}) catch unreachable };
}

test "unit: cli-right-sidebar: visibility verbs map to methods and print nothing" {
    var h: harness.Harness = undefined;
    h.init();
    defer h.deinit();
    h.serve(echoHandler);
    h.setEnv("CMUX_WORKSPACE_ID", "WS-1");
    for ([_][]const u8{ "toggle", "show", "hide", "focus" }) |verb| {
        const r = h.run(&.{ "cmux", "right-sidebar", verb });
        try harness.expectOk(r);
        try testing.expectEqualStrings("", r.out);
        const m = try std.fmt.allocPrint(h.alloc(), "wmux.right_sidebar.{s}", .{verb});
        try testing.expectEqualStrings(m, h.last().method);
        try testing.expectEqualStrings("{\"workspace_id\":\"WS-1\"}", h.last().params_json);
    }
    // --window wins over the caller's workspace.
    _ = h.run(&.{ "cmux", "right-sidebar", "show", "--window", "window:2" });
    try testing.expectEqualStrings("{\"window_id\":\"window:2\"}", h.last().params_json);
    _ = h.run(&.{ "cmux", "--window", "window:3", "right-sidebar", "hide" });
    try testing.expectEqualStrings("{\"window_id\":\"window:3\"}", h.last().params_json);
    _ = h.run(&.{ "cmux", "right-sidebar", "toggle", "--workspace", "workspace:4" });
    try testing.expectEqualStrings("{\"workspace_id\":\"workspace:4\"}", h.last().params_json);
}

test "unit: cli-right-sidebar: set, mode aliases and --no-focus" {
    var h: harness.Harness = undefined;
    h.init();
    defer h.deinit();
    h.serve(echoHandler);
    try harness.expectOk(h.run(&.{ "cmux", "right-sidebar", "set", "feed" }));
    try testing.expectEqualStrings("wmux.right_sidebar.set", h.last().method);
    try testing.expectEqualStrings("{\"mode\":\"feed\",\"focus\":true}", h.last().params_json);
    try harness.expectOk(h.run(&.{ "cmux", "right-sidebar", "set", "dock", "--no-focus" }));
    try testing.expectEqualStrings("{\"mode\":\"dock\",\"focus\":false}", h.last().params_json);
    try harness.expectOk(h.run(&.{ "cmux", "right-sidebar", "files" }));
    try testing.expectEqualStrings("{\"mode\":\"files\",\"focus\":true}", h.last().params_json);
    const js = h.run(&.{ "cmux", "right-sidebar", "vault", "--json" });
    try harness.expectOk(js);
    try harness.expectContains(js.out, "\"echo\"");
}

test "unit: cli-right-sidebar: mode prints visible and mode JSON" {
    var h: harness.Harness = undefined;
    h.init();
    defer h.deinit();
    h.serve(echoHandler);
    const r = h.run(&.{ "cmux", "right-sidebar", "mode" });
    try harness.expectOk(r);
    try testing.expectEqualStrings("wmux.right_sidebar.get", h.last().method);
    try harness.expectGolden(h.alloc(), "right-sidebar-mode.txt", r.out);
}

test "unit: cli-right-sidebar: argument errors exit 2 without contacting the app" {
    var h: harness.Harness = undefined;
    h.init();
    defer h.deinit();
    h.serve(echoHandler);
    try harness.expectFail(h.run(&.{ "cmux", "right-sidebar" }), 2, "right-sidebar requires a command");
    try harness.expectFail(h.run(&.{ "cmux", "right-sidebar", "explode" }), 2, "unknown right-sidebar command 'explode'");
    try harness.expectFail(h.run(&.{ "cmux", "right-sidebar", "set" }), 2, "right-sidebar set requires a mode");
    try harness.expectFail(h.run(&.{ "cmux", "right-sidebar", "set", "nope" }), 2, "unknown right-sidebar mode 'nope'");
    try harness.expectFail(h.run(&.{ "cmux", "right-sidebar", "show", "--no-focus" }), 2, "--no-focus is only valid with right-sidebar set");
    try harness.expectFail(h.run(&.{ "cmux", "right-sidebar", "show", "extra" }), 2, "unexpected argument 'extra'");
    try harness.expectFail(h.run(&.{ "cmux", "right-sidebar", "show", "--bogus" }), 2, "right-sidebar: unknown flag '--bogus'. Usage: cmux right-sidebar <command> [flags]");
    try harness.expectFail(h.run(&.{ "cmux", "right-sidebar", "show", "--window" }), 2, "--window requires a value");
    try harness.expectFail(h.run(&.{ "cmux", "right-sidebar", "show", "--window", "" }), 2, "Window handle is blank");
    try harness.expectFail(h.run(&.{ "cmux", "right-sidebar", "show", "--workspace", "pane:1" }), 2, "Invalid workspace handle: pane:1 (expected UUID, ref like workspace:1, or index)");
    try harness.expectFail(h.run(&.{ "cmux", "right-sidebar", "cloud" }), 2, "not supported on wmux");
    try harness.expectFail(h.run(&.{ "cmux", "right-sidebar", "set", "macs" }), 2, "not supported on wmux");
    try testing.expectEqual(@as(usize, 0), h.requestCount());
}

test "unit: cli-right-sidebar: help works offline and server errors exit 1" {
    var h: harness.Harness = undefined;
    h.init();
    defer h.deinit();
    const help = h.run(&.{ "cmux", "right-sidebar", "--help" });
    try harness.expectOk(help);
    try harness.expectGolden(h.alloc(), "right-sidebar-help.txt", help.out);
    // No app running: discovery failure, exit 1.
    try harness.expectFail(h.run(&.{ "cmux", "right-sidebar", "show" }), 1, "No live wmux socket found");
}
