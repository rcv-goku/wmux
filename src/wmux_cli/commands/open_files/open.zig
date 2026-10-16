//! `cmux open <path-or-url>...` (cli-open-command, panels-open-cli): http(s)
//! URLs open browser splits (`browser.open_split`); directories open new
//! workspaces (`workspace.create {cwd}`); `.html`/`.htm` files open as
//! file:// URLs in browser splits without focus by default; other files are
//! batched, consecutive files in one `file.open {paths}` so they open as tabs
//! in the same pane. Paths resolve from the cwd, then from the enclosing git
//! root (`locate`). Every target is checked before the first request, so a
//! missing path changes nothing. Focus: `--no-focus` wins over `--focus
//! <true|false>`; otherwise only interactive runs take focus
//! (focus_default.zig). Starts wmux when needed. (`cmux <path>` without a
//! command goes through `app.launch` in main.zig/launch.zig.)

const std = @import("std");
const proto = @import("wmux_proto");
const command = @import("../../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const focus_default = @import("../../focus_default.zig");
const util = @import("../cli_misc/util.zig");

pub const usage = "Usage: cmux open <path-or-url>...";

pub const spec: CommandSpec = .{ .name = "open", .group = .start, .usage = usage, .help = @embedFile("../../help/open.txt"), .socket = .launch_if_needed, .run = run };

const flag_specs = [_]util.FlagSpec{
    .{ .name = "--workspace", .value = true },
    .{ .name = "--surface", .value = true },
    .{ .name = "--pane", .value = true },
    .{ .name = "--window", .value = true },
    .{ .name = "--focus", .value = true },
    .{ .name = "--no-focus" },
};

pub const Kind = enum { file, html, workspace, url };

pub const Item = struct {
    kind: Kind,
    /// The argument as typed.
    raw: []const u8,
    /// Absolute path (files, directories) or the URL.
    value: []const u8,
    line: ?u32 = null,
    column: ?u32 = null,
};

pub fn isWebUrl(s: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(s, "http://") or std.ascii.startsWithIgnoreCase(s, "https://");
}

pub fn isHtml(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".html") or std.ascii.endsWithIgnoreCase(path, ".htm");
}

pub const Position = struct { path: []const u8, line: u32, column: ?u32 = null };

/// Splits a trailing `:line` or `:line:col` (parsed from the right, so a
/// drive letter's colon is never taken). Null when there is no suffix.
pub fn splitPosition(s: []const u8) ?Position {
    const last = std.mem.lastIndexOfScalar(u8, s, ':') orelse return null;
    const n1 = parseNum(s[last + 1 ..]) orelse return null;
    const head = s[0..last];
    if (std.mem.lastIndexOfScalar(u8, head, ':')) |prev| {
        if (parseNum(head[prev + 1 ..])) |n0| {
            if (prev > 0) return .{ .path = head[0..prev], .line = n0, .column = n1 };
        }
    }
    if (head.len == 0) return null;
    return .{ .path = head, .line = n1 };
}

fn parseNum(s: []const u8) ?u32 {
    if (s.len == 0 or s.len > 9) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// `file:///C:/a%20b.html` / `file:///home/a.html`.
pub fn fileUrl(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("file://");
    if (path.len == 0 or (path[0] != '/' and path[0] != '\\')) try aw.writer.writeByte('/');
    for (path) |c| switch (c) {
        '\\' => try aw.writer.writeByte('/'),
        ' ', '#', '%', '?', '"', '<', '>', '`', '{', '}', '|', '^', '[', ']' => try aw.writer.print("%{X:0>2}", .{c}),
        else => if (c < 0x20 or c == 0x7f) try aw.writer.print("%{X:0>2}", .{c}) else try aw.writer.writeByte(c),
    };
    return aw.written();
}

pub const Located = struct { path: []const u8, line: ?u32 = null, column: ?u32 = null };

/// The git root of the cwd, looked up once: null until then, then the root
/// or null when the cwd is not inside a repository.
const RepoRoot = ??[]const u8;

/// A path that names neither a root nor a drive: `src\a.zig`, `../x`, not
/// `C:\x`, `\x`, `C:x`, `\\srv\x`, `/x` or `~/x`.
fn isPlainRelative(p: []const u8) bool {
    if (p.len == 0 or p[0] == '~' or p[0] == '/' or p[0] == '\\') return false;
    if (p.len >= 2 and std.ascii.isAlphabetic(p[0]) and p[1] == ':') return false;
    return !util.isAbsolute(p);
}

fn repoRootOf(ctx: *Ctx, cache: *RepoRoot) !?[]const u8 {
    if (cache.*) |known| return known;
    const cwd = ctx.platform.cwd(ctx.arena);
    const root: ?[]const u8 = if (cwd) |c| try util.gitRoot(ctx, try std.fs.path.resolve(ctx.arena, &.{c})) else null;
    cache.* = root;
    return root;
}

/// The file or directory `raw` names (panels-open-cli): relative to the cwd
/// (`~` expanded), then without a `:line[:col]` suffix; a plain relative
/// path that exists in neither form is tried the same two ways from the
/// root of the git repository that contains the cwd. Null when none exists.
pub fn locate(ctx: *Ctx, raw: []const u8, repo_root: *RepoRoot) !?Located {
    const abs = try util.resolvePath(ctx, raw);
    if (ctx.platform.pathExists(abs)) return .{ .path = abs };
    const pos = splitPosition(raw);
    if (pos) |p| {
        const stripped = try util.resolvePath(ctx, p.path);
        if (ctx.platform.pathExists(stripped)) return .{ .path = stripped, .line = p.line, .column = p.column };
    }
    if (!isPlainRelative(raw)) return null;
    const root = (try repoRootOf(ctx, repo_root)) orelse return null;
    const in_root = try std.fs.path.resolve(ctx.arena, &.{ root, raw });
    if (ctx.platform.pathExists(in_root)) return .{ .path = in_root };
    if (pos) |p| {
        const stripped = try std.fs.path.resolve(ctx.arena, &.{ root, p.path });
        if (ctx.platform.pathExists(stripped)) return .{ .path = stripped, .line = p.line, .column = p.column };
    }
    return null;
}

fn run(ctx: *Ctx) !u8 {
    const flags = (try util.flagsOrFail(ctx, "open", usage, ctx.args(), &flag_specs)) orelse return output.exit.usage;
    var raw: std.ArrayList([]const u8) = .empty;
    try raw.appendSlice(ctx.arena, flags.positionals);
    if (flags.payload) |p| try raw.appendSlice(ctx.arena, p);
    if (raw.items.len == 0) return ctx.usageError("open requires at least one path or URL. {s}", .{try util.branded(ctx, usage)});
    const explicit = util.explicitFocus(flags) catch return ctx.usageError("{s}", .{util.focus_value_message});
    const target = util.resolveTarget(ctx, flags, .{ .surface_default = true, .pane_blocks_surface_default = true }) orelse return output.exit.usage;

    // Resolve and check every target first.
    var items: std.ArrayList(Item) = .empty;
    var repo_root: RepoRoot = null;
    for (raw.items) |r| {
        if (isWebUrl(r)) {
            try items.append(ctx.arena, .{ .kind = .url, .raw = r, .value = r });
            continue;
        }
        const found = (try locate(ctx, r, &repo_root)) orelse
            return ctx.runtimeError("Path does not exist: {s}", .{try util.resolvePath(ctx, r)});
        const kind: Kind = if (util.fs.isDir(found.path)) .workspace else if (isHtml(found.path)) .html else .file;
        try items.append(ctx.arena, .{ .kind = kind, .raw = r, .value = found.path, .line = found.line, .column = found.column });
    }

    const default_focus = focus_default.defaultFocus(ctx.platform.isInteractive(), ctx.env, ctx.env_names);
    const focus = explicit orelse default_focus;
    var opened = std.json.Array.init(ctx.arena);
    var counts: struct { files: usize = 0, urls: usize = 0, workspaces: usize = 0 } = .{};
    var last_file: ?std.json.Value = null;
    var i: usize = 0;
    while (i < items.items.len) {
        const it = items.items[i];
        switch (it.kind) {
            .file => {
                // Consecutive files become one batch (tabs in one pane).
                var end = i;
                while (end < items.items.len and items.items[end].kind == .file) end += 1;
                const batch = items.items[i..end];
                var params = util.Params.init(ctx.arena);
                var paths: std.ArrayList([]const u8) = .empty;
                for (batch) |b| try paths.append(ctx.arena, b.value);
                try params.strings("paths", paths.items);
                try params.boolean("focus", focus);
                try params.target(target);
                try addPositions(ctx, &params, batch);
                const r = (try util.call(ctx, "file.open", &params)) orelse return output.exit.runtime;
                for (batch) |b| try opened.append(try entry(ctx, "file", r, "path", b.value));
                counts.files += batch.len;
                last_file = r;
                i = end;
                continue;
            },
            .workspace => {
                var params = util.Params.init(ctx.arena);
                try params.str("cwd", it.value);
                try params.optStr("window_id", target.window);
                try params.boolean("focus", focus);
                const r = (try util.call(ctx, "workspace.create", &params)) orelse return output.exit.runtime;
                try opened.append(try entry(ctx, "workspace", r, "path", it.value));
                counts.workspaces += 1;
            },
            .url, .html => {
                const url = if (it.kind == .html) try fileUrl(ctx.arena, it.value) else it.value;
                var params = util.Params.init(ctx.arena);
                try params.str("url", url);
                // HTML files never take focus unless asked (cmux).
                try params.boolean("focus", if (it.kind == .html) explicit orelse false else focus);
                try params.optStr("window_id", target.window);
                try params.optStr("workspace_id", target.workspace);
                try params.optStr("surface_id", target.surface);
                const r = (try util.call(ctx, "browser.open_split", &params)) orelse return output.exit.runtime;
                if (it.kind == .html) {
                    try opened.append(try entry(ctx, "file", r, "path", it.value));
                    counts.files += 1;
                } else {
                    try opened.append(try entry(ctx, "url", r, "url", url));
                    counts.urls += 1;
                }
            },
        }
        i += 1;
    }

    if (ctx.json()) {
        var o = std.json.ObjectMap.init(ctx.arena);
        try o.put("opened", .{ .array = opened });
        try util.writeJsonResult(ctx, .{ .object = o });
        return output.exit.ok;
    }
    var aw: std.Io.Writer.Allocating = .init(ctx.arena);
    const w = &aw.writer;
    try w.writeAll("OK");
    if (counts.files > 0) {
        try w.print(" files={d}", .{counts.files});
        if (last_file) |r| {
            if (try util.handleText(ctx, r, "surface")) |s| try w.print(" surface={s}", .{s});
            if (try util.handleText(ctx, r, "pane")) |p| try w.print(" pane={s}", .{p});
        }
    }
    if (counts.urls > 0) try w.print(" urls={d}", .{counts.urls});
    if (counts.workspaces > 0) try w.print(" workspaces={d}", .{counts.workspaces});
    try ctx.out.print("{s}\n", .{aw.written()});
    return output.exit.ok;
}

fn entry(ctx: *Ctx, kind: []const u8, payload: std.json.Value, key: []const u8, value: []const u8) !std.json.Value {
    var o = std.json.ObjectMap.init(ctx.arena);
    try o.put("kind", .{ .string = kind });
    try o.put("payload", payload);
    try o.put(key, .{ .string = value });
    return .{ .object = o };
}

/// `positions: [{path, line, column?}]` for `file:line[:col]` arguments.
fn addPositions(ctx: *Ctx, params: *util.Params, batch: []const Item) !void {
    var arr = std.json.Array.init(ctx.arena);
    for (batch) |b| {
        const line = b.line orelse continue;
        var o = util.Params.init(ctx.arena);
        try o.str("path", b.value);
        try o.int("line", line);
        if (b.column) |c| try o.int("column", c);
        try arr.append(.{ .object = o.obj });
    }
    if (arr.items.len > 0) try params.put("positions", .{ .array = arr });
}
