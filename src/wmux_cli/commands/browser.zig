//! CLI command family `browser` (Appendix C).
//! browser <sub>, open-browser, navigate, browser-back, browser-forward,
//! browser-reload, get-url, focus-webview, is-webview-focused, disable-browser,
//! enable-browser, browser-status. Owner: W2-8 (browser II subcommands: W5a).
//!
//! `browser [--surface <h> | <h>] <sub> [args]` maps each verb onto cmux v2
//! `browser.*` methods (browser/plan*.zig, pure), prints cmux's text or the
//! JSON result (browser/render.zig), and reports cmux's usage errors before
//! contacting the app (browser/grammar.zig). The legacy top-level verbs are
//! `browser <verb>` with `--panel` as the old `--surface` spelling. The
//! availability commands work offline through `wmux.json`
//! (browser/availability.zig).

const std = @import("std");
const command = @import("../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../output.zig");
const run = @import("browser/run.zig");

/// `CommandSpec` entries (ADR-4.9).
pub const commands = [_]CommandSpec{
    .{ .name = "browser", .group = .browser, .usage = run.usage_line, .help = run.help_text, .run = run.runBrowser },
    alias("open-browser", "open", "[url] [--workspace <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>] [--profile <name|uuid>]", runOpen),
    alias("navigate", "navigate", "<url> --surface <id|ref|index> [--snapshot-after]", runNavigate),
    alias("browser-back", "back", "--surface <id|ref|index> [--snapshot-after]", runBack),
    alias("browser-forward", "forward", "--surface <id|ref|index> [--snapshot-after]", runForward),
    alias("browser-reload", "reload", "--surface <id|ref|index> [--snapshot-after]", runReload),
    alias("get-url", "get-url", "--surface <id|ref|index>", runGetUrl),
    alias("focus-webview", "focus-webview", "--surface <id|ref|index>", runFocusWebview),
    alias("is-webview-focused", "is-webview-focused", "--surface <id|ref|index>", runIsWebviewFocused),
    availabilitySpec("disable-browser", runDisable),
    availabilitySpec("enable-browser", runEnable),
    availabilitySpec("browser-status", runStatus),
};

fn alias(comptime name: []const u8, comptime verb: []const u8, comptime args: []const u8, comptime f: command.RunFn) CommandSpec {
    const usage = "Usage: cmux " ++ name ++ " " ++ args;
    return .{
        .name = name,
        .group = .browser,
        .usage = usage,
        .help = usage ++ "\n\nLegacy alias for 'cmux browser " ++ verb ++ "'. Run 'cmux browser --help' for details.\n" ++
            "--panel <id|ref|index> is accepted as the legacy spelling of --surface.\n",
        .run = f,
    };
}

fn availabilitySpec(comptime name: []const u8, comptime f: command.RunFn) CommandSpec {
    return .{
        .name = name,
        .group = .browser,
        .usage = "Usage: cmux " ++ name ++ " [--json]",
        .help = @embedFile("../help/" ++ name ++ ".txt"),
        .socket = .none,
        .run = f,
    };
}

fn runOpen(ctx: *Ctx) !u8 {
    return run.runAlias(ctx, "open");
}
fn runNavigate(ctx: *Ctx) !u8 {
    return run.runAlias(ctx, "navigate");
}
fn runBack(ctx: *Ctx) !u8 {
    return run.runAlias(ctx, "back");
}
fn runForward(ctx: *Ctx) !u8 {
    return run.runAlias(ctx, "forward");
}
fn runReload(ctx: *Ctx) !u8 {
    return run.runAlias(ctx, "reload");
}
fn runGetUrl(ctx: *Ctx) !u8 {
    return run.runAlias(ctx, "get-url");
}
fn runFocusWebview(ctx: *Ctx) !u8 {
    return run.runAlias(ctx, "focus-webview");
}
fn runIsWebviewFocused(ctx: *Ctx) !u8 {
    return run.runAlias(ctx, "is-webview-focused");
}

fn availability(ctx: *Ctx, which: @import("browser/plan.zig").Local) !u8 {
    if (ctx.args().len > 0) return ctx.usageError("Unexpected argument: {s}", .{ctx.args()[0]});
    return run.runAvailability(ctx, which);
}
fn runDisable(ctx: *Ctx) !u8 {
    return availability(ctx, .disable);
}
fn runEnable(ctx: *Ctx) !u8 {
    return availability(ctx, .enable);
}
fn runStatus(ctx: *Ctx) !u8 {
    return availability(ctx, .status);
}

test {
    _ = @import("browser/grammar.zig");
    _ = @import("browser/plan_tests.zig");
    _ = @import("browser/render.zig");
    _ = @import("browser/availability.zig");
    _ = @import("browser/files.zig");
    _ = @import("browser/screenshot.zig");
    _ = @import("browser/tests.zig");
}
