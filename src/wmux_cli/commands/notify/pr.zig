//! `cmux pr <url|number|clear>`: attach, replace or clear a workspace's
//! pull-request link. The selector is validated, the repository and the
//! pull request are looked up with the GitHub CLI (`gh repo view`, `gh pr
//! view`), and the link is sent as `wmux.workspace.pr.set` (or
//! `wmux.workspace.pr.clear`). Target: `--workspace`/`--window`, then
//! `CMUX_WORKSPACE_ID`, then the unique workspace whose directory lies in
//! the current git worktree. Never changes focus.
//!
//! `gh`/`git` run through `runner` (std.process.Child), which tests replace;
//! the `Platform` vtable has no capture-output spawn yet.

const std = @import("std");
const Allocator = std.mem.Allocator;
const command = @import("../../command.zig");
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const brand_mod = @import("../../brand.zig");
const common = @import("common.zig");
const Params = common.Params;

pub const RunResult = struct { code: u8, stdout: []const u8, stderr: []const u8 };
pub const Runner = *const fn (arena: Allocator, argv: []const []const u8) anyerror!RunResult;

fn nativeRun(arena: Allocator, argv: []const []const u8) anyerror!RunResult {
    const r = try std.process.Child.run(.{ .allocator = arena, .argv = argv, .max_output_bytes = 1 << 20 });
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
}

pub var runner: Runner = nativeRun;

pub const expects_message = "cmux pr expects a pull-request URL or a positive pull-request number";
pub const foreign_message = "cmux pr: the pull request does not belong to the detected repository";

pub const PrUrl = struct { host: []const u8, owner: []const u8, repo: []const u8, number: u64 };

pub const Selector = union(enum) {
    clear,
    number: u64,
    url: PrUrl,
};

fn positiveNumber(s: []const u8) ?u64 {
    if (s.len == 0 or s.len > 18) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseInt(u64, s, 10) catch return null;
    return if (n == 0) null else n;
}

/// `clear`, `123`, `#123`, or `http(s)://<host>/<owner>/<repo>/pull/<n>[/...][?...][#...]`.
pub fn parseSelector(text: []const u8) ?Selector {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.eql(u8, t, "clear")) return .clear;
    if (positiveNumber(if (t.len > 0 and t[0] == '#') t[1..] else t)) |n| return .{ .number = n };
    var rest: []const u8 = undefined;
    if (std.ascii.startsWithIgnoreCase(t, "https://")) {
        rest = t["https://".len..];
    } else if (std.ascii.startsWithIgnoreCase(t, "http://")) {
        rest = t["http://".len..];
    } else return null;
    if (std.mem.indexOfAny(u8, rest, "?#")) |cut| rest = rest[0..cut];
    var it = std.mem.splitScalar(u8, rest, '/');
    const host = it.next() orelse return null;
    const owner = it.next() orelse return null;
    const repo = it.next() orelse return null;
    const pull = it.next() orelse return null;
    const num = it.next() orelse return null;
    if (host.len == 0 or owner.len == 0 or repo.len == 0) return null;
    if (!std.mem.eql(u8, pull, "pull")) return null;
    const n = positiveNumber(num) orelse return null;
    return .{ .url = .{ .host = host, .owner = owner, .repo = repo, .number = n } };
}

fn isGithubHost(h: []const u8) bool {
    return std.ascii.eqlIgnoreCase(h, "github.com") or std.ascii.eqlIgnoreCase(h, "www.github.com");
}

/// `owner/repo` of the detected repository and its parent that `u` names,
/// or null when it names neither.
pub fn matchRepo(u: PrUrl, candidates: []const []const u8) ?[]const u8 {
    if (!isGithubHost(u.host)) return null;
    for (candidates) |c| {
        const slash = std.mem.indexOfScalar(u8, c, '/') orelse continue;
        if (std.ascii.eqlIgnoreCase(c[0..slash], u.owner) and std.ascii.eqlIgnoreCase(c[slash + 1 ..], u.repo)) return c;
    }
    return null;
}

fn fail(ctx: *Ctx, comptime fmt: []const u8, a: anytype) u8 {
    const text = std.fmt.allocPrint(ctx.arena, fmt, a) catch return output.exit.runtime;
    return common.runtimeText(ctx, text);
}

fn firstLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    return t[0 .. std.mem.indexOfAny(u8, t, "\r\n") orelse t.len];
}

/// Runs `argv`; prints why it failed and returns null on failure.
fn exec(ctx: *Ctx, argv: []const []const u8, code: *u8) ?RunResult {
    const r = runner(ctx.arena, argv) catch |err| {
        code.* = if (err == error.FileNotFound)
            (if (std.mem.eql(u8, argv[0], "gh"))
                fail(ctx, "cmux pr: requires the GitHub CLI (gh) on PATH", .{})
            else
                fail(ctx, "cmux pr: requires {s} on PATH", .{argv[0]}))
        else
            fail(ctx, "cmux pr: cannot run {s}: {s}", .{ argv[0], @errorName(err) });
        return null;
    };
    if (r.code != 0) {
        const why = firstLine(r.stderr);
        code.* = fail(ctx, "cmux pr: {s} {s} failed: {s}", .{ argv[0], argv[1], if (why.len > 0) why else "no output" });
        return null;
    }
    return r;
}

fn parseJson(ctx: *Ctx, r: RunResult, what: []const u8, code: *u8) ?std.json.Value {
    const v = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, r.stdout, .{}) catch {
        code.* = fail(ctx, "cmux pr: unexpected output from {s}", .{what});
        return null;
    };
    if (v != .object) {
        code.* = fail(ctx, "cmux pr: unexpected output from {s}", .{what});
        return null;
    }
    return v;
}

/// `/`-separated, without a trailing separator.
fn normalizeDir(arena: Allocator, p: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, std.mem.trim(u8, p, " \t\r\n"));
    for (out) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    return std.mem.trimRight(u8, out, "/");
}

/// True when `dir` is `top` or below it (ASCII case-insensitive, either
/// separator).
pub fn dirWithin(arena: Allocator, dir: []const u8, top: []const u8) !bool {
    const d = try normalizeDir(arena, dir);
    const t = try normalizeDir(arena, top);
    if (t.len == 0 or d.len < t.len) return false;
    if (!std.ascii.eqlIgnoreCase(d[0..t.len], t)) return false;
    return d.len == t.len or d[t.len] == '/';
}

/// The unique workspace whose directory lies in the current git worktree.
fn worktreeWorkspace(ctx: *Ctx, code: *u8) !?[]const u8 {
    const git = exec(ctx, &.{ "git", "rev-parse", "--show-toplevel" }, code) orelse return null;
    const top = firstLine(git.stdout);
    const r = (try common.request(ctx, "workspace.list", null)) orelse {
        code.* = output.exit.runtime;
        return null;
    };
    var found: ?[]const u8 = null;
    var count: usize = 0;
    for (common.firstArray(r, &.{"workspaces"})) |w| {
        const dir = common.strField(w, "cwd") orelse common.strField(w, "directory") orelse common.strField(w, "current_directory") orelse continue;
        if (!try dirWithin(ctx.arena, dir, top)) continue;
        count += 1;
        found = common.strField(w, "id") orelse common.strField(w, "ref");
    }
    if (count == 1 and found != null) return found;
    code.* = if (count == 0)
        fail(ctx, "cmux pr: no workspace is open in this repository; pass --workspace", .{})
    else
        fail(ctx, "cmux pr: several workspaces are open in this repository; pass --workspace", .{});
    return null;
}

const pr_opts = [_]common.Opt{
    .{ .name = "--workspace" },
    .{ .name = "--window" },
};

pub fn run(ctx: *Ctx) !u8 {
    var code: u8 = 0;
    const s = (try common.scanOrReport(ctx, "pr", &pr_opts, .{}, &code)) orelse return code;
    if (s.positionals.len > 1) return common.reportProblem(ctx, "pr", .{ .unexpected = s.positionals[1..] });
    const sel = (if (s.positionals.len == 1) parseSelector(s.positionals[0]) else null) orelse {
        brand_mod.write(ctx.err, ctx.brand, expects_message) catch {};
        ctx.err.writeByte('\n') catch {};
        return output.exit.usage;
    };
    var t = common.resolveTarget(ctx, s, .{ .env_workspace = true }, &code) orelse return code;
    if (t.workspace == null and t.window == null) t.workspace = (try worktreeWorkspace(ctx, &code)) orelse return code;
    var p = Params.init(ctx.arena);
    try t.put(&p);
    if (sel == .clear) return common.callOk(ctx, "wmux.workspace.pr.clear", &p);

    const repo_out = exec(ctx, &.{ "gh", "repo", "view", "--json", "nameWithOwner,url,parent" }, &code) orelse return code;
    const repo = parseJson(ctx, repo_out, "gh repo view", &code) orelse return code;
    const repo_url = common.strField(repo, "url") orelse "";
    if (!std.ascii.startsWithIgnoreCase(repo_url, "https://github.com/"))
        return fail(ctx, "cmux pr: only github.com repositories are supported", .{});
    var candidates: [2][]const u8 = undefined;
    var n: usize = 0;
    if (common.strField(repo, "nameWithOwner")) |x| {
        candidates[n] = x;
        n += 1;
    }
    if (common.field(repo, "parent")) |parent| if (common.strField(parent, "nameWithOwner")) |x| {
        candidates[n] = x;
        n += 1;
    };
    if (n == 0) return fail(ctx, "cmux pr: unexpected output from gh repo view", .{});
    const number, const repo_name = switch (sel) {
        .number => |x| .{ x, candidates[0] },
        .url => |u| .{ u.number, matchRepo(u, candidates[0..n]) orelse return fail(ctx, "{s}", .{foreign_message}) },
        .clear => unreachable,
    };
    const num_text = try std.fmt.allocPrint(ctx.arena, "{d}", .{number});
    const view = exec(ctx, &.{ "gh", "pr", "view", num_text, "--repo", repo_name, "--json", "number,url,state,headRefName" }, &code) orelse return code;
    const info = parseJson(ctx, view, "gh pr view", &code) orelse return code;
    const state = try std.ascii.allocLowerString(ctx.arena, common.strField(info, "state") orelse "open");
    try p.int("number", @intCast(number));
    try p.str("url", common.strField(info, "url") orelse "");
    try p.str("state", state);
    if (common.strField(info, "headRefName")) |b| try p.str("branch", b);
    return common.callOk(ctx, "wmux.workspace.pr.set", &p);
}
