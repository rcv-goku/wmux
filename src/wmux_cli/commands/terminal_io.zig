//! CLI command family `terminal_io` (Appendix C).
//! send, send-key, send-panel, send-key-panel, paste, read-screen,
//! read-selection, capture-pane, clear-history, respawn-pane, pipe-pane,
//! debug-terminals, surface-health, refresh-surfaces. Owner: W2-3.
//! wait-for (file-based, offline; Appendix C lists it under `teams`, WP
//! CLI-fam-ps ships it here).
//!
//! - `send` interprets `\n`, `\r`, `\t` and `\\` and types the text
//!   (`surface.send_text`); `--paste` before the text routes it unchanged
//!   through `terminal.paste`. Large or multi-line text without `--paste`
//!   prints cmux's stderr hint.
//! - `send`, `send-panel`, `paste` and `send --paste` ask
//!   `surface.input_state` first and refuse over an agent draft or dialog;
//!   `send-key`, `send-key-panel` and Enter-only `send` refuse only for a
//!   dialog. `--force` skips the check; an app that cannot answer lets the
//!   command proceed (cmux "Draft Guard").
//! - `read-screen`/`capture-pane` print `surface.read_text` text;
//!   `read-selection` prints the selection with its context lines.

const std = @import("std");
const builtin = @import("builtin");
const command = @import("../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../output.zig");
const brand_mod = @import("../brand.zig");
const ps = @import("ps_common.zig");
const pane_surface = @import("pane_surface.zig");
const usageOf = pane_surface.usageOf;
const Opts = ps.Opts;
const Params = ps.Params;
const Allocator = std.mem.Allocator;

fn spec(comptime name: []const u8, comptime run: command.RunFn) CommandSpec {
    return .{ .name = name, .group = .agents, .usage = usageOf(name), .help = @embedFile("../help/" ++ name ++ ".txt"), .run = run };
}

/// `CommandSpec` entries (ADR-4.9).
pub const commands = [_]CommandSpec{
    spec("send", runSend),
    spec("send-key", runSendKey),
    spec("send-panel", runSendPanel),
    spec("send-key-panel", runSendKeyPanel),
    spec("paste", runPaste),
    spec("read-screen", runReadScreen),
    spec("read-selection", runReadSelection),
    spec("capture-pane", runCapturePane),
    blk: {
        var s = spec("wait-for", runWaitFor);
        s.socket = .none;
        break :blk s;
    },
};

fn unexpected(ctx: *Ctx, usage: []const u8, arg: []const u8) u8 {
    return ps.usageWithLine(ctx, usage, "unexpected argument '{s}'", .{arg});
}

// ----- escapes -----

/// cmux `send` escapes: `\n` and `\r` (Enter), `\t` (Tab) and `\\`; any
/// other backslash is kept literally.
pub fn unescape(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\\') == null) return text;
    var out: std.ArrayList(u8) = try .initCapacity(arena, text.len);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\\' and i + 1 < text.len) {
            const r: ?u8 = switch (text[i + 1]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                else => null,
            };
            if (r) |b| {
                try out.append(arena, b);
                i += 1;
                continue;
            }
        }
        try out.append(arena, c);
    }
    return out.items;
}

/// Text that only presses Enter (`\n`/`\r` only, at least one).
pub fn isEnterOnly(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (c != '\n' and c != '\r') return false;
    return true;
}

/// Over about 4 KB, or several lines: cmux prints the paste hint.
pub fn wantsPasteHint(text: []const u8) bool {
    if (text.len > 4096) return true;
    var lines: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') i += 1;
        if (text[i] == '\n' or text[i] == '\r') lines += 1;
    }
    return lines >= 2;
}

pub const paste_hint = "hint: each newline was typed as Enter; for large multi-line text use cmux send --paste or cmux paste to deliver it as one paste\n";

// ----- key names (cmux send-key table) -----

const named_keys = [_][]const u8{
    "enter",          "return",     "tab",       "escape",    "esc",         "backspace",  "delete",     "del",
    "forward_delete", "space",      "up",        "arrow_up",  "arrowup",     "down",       "arrow_down", "arrowdown",
    "left",           "arrow_left", "arrowleft", "right",     "arrow_right", "arrowright", "home",       "end",
    "pageup",         "page_up",    "pagedown",  "page_down",
};

const alias_keys = [_][]const u8{
    "shift+tab", "shift-tab", "backtab", "ctrl-c",  "ctrl+c",  "sigint", "ctrl-d", "eof", "ctrl-f",
    "ctrl-z",    "sigtstp",   "ctrl-\\", "ctrl+\\", "sigquit",
};

const modifiers = [_][]const u8{ "ctrl", "control", "shift", "alt", "opt", "option", "cmd", "command", "super" };

fn inList(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.ascii.eqlIgnoreCase(x, s)) return true;
    return false;
}

/// Whether `key` is a cmux key name: a named key, an alias, or a chord
/// `<mod>[+-]<mod>...<key>` whose key is a letter a-z or a named key.
/// Case-insensitive.
pub fn isValidKey(key: []const u8) bool {
    const k = std.mem.trim(u8, key, " \t");
    if (k.len == 0 or k.len > 64) return false;
    if (inList(&named_keys, k) or inList(&alias_keys, k)) return true;
    // Chord: split on '+'/'-' but keep the last token as the key, so
    // `ctrl+arrow_up` and `alt-page_down` work.
    var mods: usize = 0;
    var rest = k;
    while (true) {
        const sep = std.mem.indexOfAny(u8, rest, "+-") orelse break;
        const word = rest[0..sep];
        if (!inList(&modifiers, word)) break;
        mods += 1;
        rest = rest[sep + 1 ..];
    }
    if (mods == 0 or rest.len == 0) return false;
    if (rest.len == 1 and std.ascii.isAlphabetic(rest[0])) return true;
    return inList(&named_keys, rest);
}

// ----- draft guard -----

pub const GuardMode = enum {
    /// Text: refuse over a draft or a dialog.
    text,
    /// Keys and Enter-only text: refuse only for a dialog.
    key,
};

/// Selector keys copied from a write request into `surface.input_state`.
const guard_keys = [_][]const u8{ "window_id", "workspace_id", "pane_id", "surface_id" };

/// Legacy `+send`, `+read-screen` and `+capture-pane` spellings (ADR-4.11):
/// `--tab T` names the surface, `--pane P` the pane.
const legacy_targets: ps.TargetSpec = .{ .surface_flags = &.{ "--surface", "--tab" }, .pane = true };

/// Asks `surface.input_state` for the request's target. Returns an exit code
/// when the write must not happen (refusal or no connection), null to go
/// ahead. An app that cannot answer lets the write proceed.
pub fn draftGuard(ctx: *Ctx, verb: []const u8, target: *const Params, mode: GuardMode) !?u8 {
    var p = Params.init(ctx.arena);
    for (guard_keys) |k| if (target.map.get(k)) |v| try p.value(k, v);
    const out = (try ctx.call("surface.input_state", try p.json(ctx.arena))) orelse return output.exit.runtime;
    const r = switch (out) {
        .ok => |ok| ok.result,
        else => return null,
    };
    if (!ps.getBool(r, "agent")) return null;
    const state = ps.getStr(r, "state") orelse return null;
    if (std.mem.eql(u8, state, "dialog")) {
        return ctx.runtimeError("{s} refused: an agent question or permission dialog is open in the target surface; nothing was sent (use --force to send anyway)", .{verb});
    }
    if (mode == .text and std.mem.eql(u8, state, "draft")) {
        if (ps.getNum(r, "draft_length")) |n| {
            return ctx.runtimeError("{s} refused: the agent prompt holds an unsent draft ({d} characters); nothing was sent (use --force to send anyway)", .{ verb, @max(ps.toInt(n), 0) });
        }
        return ctx.runtimeError("{s} refused: the agent prompt holds an unsent draft; nothing was sent (use --force to send anyway)", .{verb});
    }
    return null;
}

// ----- send, send-panel -----

const send_usage = usageOf("send");
const send_panel_usage = usageOf("send-panel");

fn runSend(ctx: *Ctx) !u8 {
    return sendText(ctx, "send", send_usage, false);
}

fn runSendPanel(ctx: *Ctx) !u8 {
    return sendText(ctx, "send-panel", send_panel_usage, true);
}

fn sendText(ctx: *Ctx, verb: []const u8, usage: []const u8, panel: bool) !u8 {
    const values: []const []const u8 = if (panel) &.{ "--panel", "--workspace", "--window" } else &.{ "--workspace", "--surface", "--window", "--tab", "--pane" };
    const o = (try ps.parseArgs(ctx, usage, .{
        .values = values,
        .bools = if (panel) &.{"--force"} else &.{ "--paste", "--force" },
        .stop_at_positional = true,
    })) orelse return output.exit.usage;
    if (panel and o.get(&.{"--panel"}) == null) return ps.usageWithLine(ctx, usage, "{s} requires --panel <id|ref|index>", .{verb});
    if (o.positionals.len == 0) return ps.usageWithLine(ctx, usage, "{s} requires text", .{verb});
    const raw = try std.mem.join(ctx.arena, " ", o.positionals);
    const paste = o.has("--paste");
    var target = Params.init(ctx.arena);
    const tspec: ps.TargetSpec = if (panel) .{ .surface_flags = &.{"--panel"}, .env_surface = false } else legacy_targets;
    if (!try ps.addTargets(ctx, &target, o, tspec)) return output.exit.usage;
    const text = if (paste) raw else try unescape(ctx.arena, raw);
    if (!o.has("--force")) {
        const mode: GuardMode = if (!paste and isEnterOnly(text)) .key else .text;
        if (try draftGuard(ctx, verb, &target, mode)) |code| return code;
    }
    var p = Params.init(ctx.arena);
    try p.str("text", text);
    if (paste) try p.str("submit_key", "none");
    var it = target.map.iterator();
    while (it.next()) |e| try p.value(e.key_ptr.*, e.value_ptr.*);
    const method = if (paste) "terminal.paste" else "surface.send_text";
    const code = try ps.callRender(ctx, method, &p, ps.renderOk);
    if (code == output.exit.ok and !paste and wantsPasteHint(text)) try brand_mod.write(ctx.err, ctx.brand, paste_hint);
    return code;
}

// ----- send-key, send-key-panel -----

fn runSendKey(ctx: *Ctx) !u8 {
    return sendKey(ctx, "send-key", usageOf("send-key"), false);
}

fn runSendKeyPanel(ctx: *Ctx) !u8 {
    return sendKey(ctx, "send-key-panel", usageOf("send-key-panel"), true);
}

fn sendKey(ctx: *Ctx, verb: []const u8, usage: []const u8, panel: bool) !u8 {
    const values: []const []const u8 = if (panel) &.{ "--panel", "--workspace", "--window" } else &.{ "--workspace", "--surface", "--window" };
    const o = (try ps.parseArgs(ctx, usage, .{ .values = values, .bools = &.{"--force"}, .stop_at_positional = true })) orelse return output.exit.usage;
    if (panel and o.get(&.{"--panel"}) == null) return ps.usageWithLine(ctx, usage, "{s} requires --panel <id|ref|index>", .{verb});
    if (o.positionals.len == 0) return ps.usageWithLine(ctx, usage, "{s} requires a key", .{verb});
    if (o.positionals.len > 1) return unexpected(ctx, usage, o.positionals[1]);
    const key = std.mem.trim(u8, o.positionals[0], " \t");
    if (!isValidKey(key)) return ps.usageWithLine(ctx, usage, "unknown key '{s}' (examples: enter, tab, escape, up, ctrl+c, shift+tab)", .{key});
    var target = Params.init(ctx.arena);
    const tspec: ps.TargetSpec = if (panel) .{ .surface_flags = &.{"--panel"}, .env_surface = false } else .{};
    if (!try ps.addTargets(ctx, &target, o, tspec)) return output.exit.usage;
    if (!o.has("--force")) {
        if (try draftGuard(ctx, verb, &target, .key)) |code| return code;
    }
    var p = Params.init(ctx.arena);
    try p.str("key", key);
    var it = target.map.iterator();
    while (it.next()) |e| try p.value(e.key_ptr.*, e.value_ptr.*);
    return ps.callRender(ctx, "surface.send_key", &p, ps.renderOk);
}

// ----- paste -----

/// Text cap after JSON escaping (cmux: 15 MiB; the server line cap is 16).
pub const max_paste_json_bytes = 15 * 1024 * 1024;

/// Bytes `text` takes as a JSON string (quotes included).
pub fn jsonStringLen(text: []const u8) usize {
    var n: usize = 2;
    for (text) |c| n += switch (c) {
        '"', '\\', '\n', '\r', '\t', 0x08, 0x0c => 2,
        0...0x07, 0x0b, 0x0e...0x1f => 6,
        else => 1,
    };
    return n;
}

const paste_usage = usageOf("paste");

fn runPaste(ctx: *Ctx) !u8 {
    const o = (try ps.parseArgs(ctx, paste_usage, .{
        .values = &.{ "--workspace", "--surface", "--window" },
        .bools = &.{ "--submit", "--force" },
    })) orelse return output.exit.usage;
    const from_stdin = o.positionals.len == 0 or
        (o.positionals.len == 1 and o.before_dashdash == 1 and std.mem.eql(u8, o.positionals[0], "-"));
    var target = Params.init(ctx.arena);
    if (!try ps.addTargets(ctx, &target, o, .{})) return output.exit.usage;
    // stdin is read once, before connecting.
    const text = if (from_stdin) blk: {
        if (ctx.platform.isInteractive()) return ps.usageWithLine(ctx, paste_usage, "paste needs text: pass it as an argument or pipe it on stdin", .{});
        break :blk ctx.platform.readStdin(ctx.arena, max_paste_json_bytes) catch |err| switch (err) {
            error.TooLarge => return ctx.usageError("paste text exceeds 15 MiB", .{}),
            error.ReadFailed => return ctx.runtimeError("cannot read paste text from stdin", .{}),
            error.OutOfMemory => return error.OutOfMemory,
        };
    } else try std.mem.join(ctx.arena, " ", o.positionals);
    if (text.len == 0) return ps.usageWithLine(ctx, paste_usage, "paste needs text: the text is empty", .{});
    if (jsonStringLen(text) > max_paste_json_bytes) return ctx.usageError("paste text exceeds 15 MiB", .{});
    if (!o.has("--force")) {
        if (try draftGuard(ctx, "paste", &target, .text)) |code| return code;
    }
    var p = Params.init(ctx.arena);
    try p.str("text", text);
    try p.str("submit_key", if (o.has("--submit")) "enter" else "none");
    var it = target.map.iterator();
    while (it.next()) |e| try p.value(e.key_ptr.*, e.value_ptr.*);
    return ps.callRender(ctx, "terminal.paste", &p, ps.renderOk);
}

// ----- read-screen, capture-pane, read-selection -----

/// `--lines <n>` (n > 0); prints the usage error and returns error.Usage.
fn linesFlag(ctx: *Ctx, usage: []const u8, o: Opts) !?i64 {
    const t = o.get(&.{"--lines"}) orelse return null;
    const n = std.fmt.parseInt(i64, std.mem.trim(u8, t, " \t"), 10) catch {
        _ = ps.usageWithLine(ctx, usage, "--lines must be an integer", .{});
        return error.Usage;
    };
    if (n <= 0) {
        _ = ps.usageWithLine(ctx, usage, "--lines must be greater than 0", .{});
        return error.Usage;
    }
    return n;
}

/// read-screen and capture-pane: `surface.read_text`.
fn readText(ctx: *Ctx, usage: []const u8, allow_selection: bool) !u8 {
    const o = (try ps.parseArgs(ctx, usage, .{
        .values = &.{ "--workspace", "--surface", "--window", "--lines", "--tab", "--pane" },
        .bools = if (allow_selection) &.{ "--scrollback", "--selection" } else &.{"--scrollback"},
    })) orelse return output.exit.usage;
    if (o.positionals.len > 0) return unexpected(ctx, usage, o.positionals[0]);
    const lines = linesFlag(ctx, usage, o) catch return output.exit.usage;
    var p = Params.init(ctx.arena);
    if (!try ps.addTargets(ctx, &p, o, legacy_targets)) return output.exit.usage;
    if (o.has("--selection")) {
        if (o.has("--scrollback") or lines != null) return ps.usageWithLine(ctx, usage, "--selection cannot be combined with --scrollback or --lines", .{});
        return ps.callRender(ctx, "surface.read_selection", &p, renderText);
    }
    if (o.has("--scrollback") or lines != null) try p.boolean("scrollback", true);
    if (lines) |n| try p.int("lines", n);
    return ps.callRender(ctx, "surface.read_text", &p, renderText);
}

fn runReadScreen(ctx: *Ctx) !u8 {
    return readText(ctx, usageOf("read-screen"), true);
}

fn runCapturePane(ctx: *Ctx) !u8 {
    return readText(ctx, usageOf("capture-pane"), false);
}

/// Writes `text` with exactly one trailing newline added when missing.
fn writeLine(ctx: *Ctx, text: []const u8) !void {
    try ctx.out.writeAll(text);
    if (text.len == 0 or text[text.len - 1] != '\n') try ctx.out.writeByte('\n');
}

/// The `text` field as plain text.
pub fn renderText(ctx: *Ctx, result: std.json.Value) anyerror!void {
    try writeLine(ctx, ps.getStr(result, "text") orelse "");
}

/// Context lines (`Kind:`, `File:`, `Lines:`, `URL:`) then the selected
/// text; `Has selection: false` when nothing is selected.
pub fn renderSelection(ctx: *Ctx, result: std.json.Value) anyerror!void {
    const w = ctx.out;
    if (!ps.getBool(result, "has_selection")) return w.writeAll("Has selection: false\n");
    if (ps.getStr(result, "kind")) |k| {
        try w.writeAll("Kind: ");
        try ps.writeClean(w, k);
        try w.writeByte('\n');
    }
    if (ps.getStr(result, "file_path")) |f| {
        try w.writeAll("File: ");
        try ps.writeClean(w, f);
        try w.writeByte('\n');
    }
    if (ps.get(result, "line_range")) |lr| {
        if (ps.getNum(lr, "start")) |s| if (ps.getNum(lr, "end")) |e| {
            try w.print("Lines: {d}-{d}\n", .{ ps.toInt(s), ps.toInt(e) });
        };
    }
    if (ps.getStr(result, "url")) |u| {
        try w.writeAll("URL: ");
        try ps.writeClean(w, u);
        try w.writeByte('\n');
    }
    try writeLine(ctx, ps.getStr(result, "text") orelse "");
}

fn runReadSelection(ctx: *Ctx) !u8 {
    const usage = usageOf("read-selection");
    const o = (try ps.parseArgs(ctx, usage, .{ .values = &.{ "--workspace", "--surface", "--window" } })) orelse return output.exit.usage;
    if (o.positionals.len > 0) return unexpected(ctx, usage, o.positionals[0]);
    var p = Params.init(ctx.arena);
    if (!try ps.addTargets(ctx, &p, o, .{})) return output.exit.usage;
    return ps.callRender(ctx, "surface.read_selection", &p, renderSelection);
}

// ----- wait-for (file-based, offline) -----

/// Longest accepted name (its base64 file name stays under 255 bytes).
pub const max_wait_name_bytes = 180;
pub const default_wait_timeout_s = 30;
/// Poll interval while waiting (deviation: cmux watches the directory).
pub const wait_poll_ms = 50;

/// Marker file of `name`: URL-safe base64 (no padding) of the UTF-8 name
/// plus `.sig`; the empty name is `empty.sig`.
pub fn markerName(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    if (name.len == 0) return "empty.sig";
    const enc = std.base64.url_safe_no_pad.Encoder;
    const buf = try arena.alloc(u8, enc.calcSize(name.len) + ".sig".len);
    _ = enc.encode(buf, name);
    @memcpy(buf[buf.len - 4 ..], ".sig");
    return buf;
}

/// The private per-user marker directory: `WMUX_WAIT_FOR_DIR` when set,
/// else `%TEMP%\wmux-wait-for` (Windows) or `$TMPDIR/wmux-wait-for-<uid>`.
pub fn waitDir(ctx: *Ctx) !?[]const u8 {
    if (ctx.env.getNonEmpty("WMUX_WAIT_FOR_DIR")) |d| return d;
    if (builtin.os.tag == .windows) {
        const tmp = ctx.env.first(&.{ "TEMP", "TMP" }) orelse return null;
        return try std.fs.path.join(ctx.arena, &.{ tmp, "wmux-wait-for" });
    }
    const tmp = ctx.env.getNonEmpty("TMPDIR") orelse "/tmp";
    const leaf = try std.fmt.allocPrint(ctx.arena, "wmux-wait-for-{d}", .{std.posix.getuid()});
    return try std.fs.path.join(ctx.arena, &.{ tmp, leaf });
}

pub const WaitStore = struct {
    dir: std.fs.Dir,

    pub const Error = error{ NotPrivate, Unavailable };

    /// Creates (if needed) and opens the marker directory; on POSIX it must
    /// be owned by the user and not accessible to others.
    pub fn open(path: []const u8) Error!WaitStore {
        // `iterate` gives a real descriptor (not O_PATH) that fchmod accepts.
        var dir = std.fs.cwd().makeOpenPath(path, .{ .iterate = true }) catch return error.Unavailable;
        if (builtin.os.tag != .windows) {
            const st = std.posix.fstat(dir.fd) catch {
                dir.close();
                return error.Unavailable;
            };
            if (st.uid != std.posix.getuid()) {
                dir.close();
                return error.NotPrivate;
            }
            if (st.mode & 0o077 != 0) std.posix.fchmod(dir.fd, 0o700) catch {
                dir.close();
                return error.NotPrivate;
            };
        }
        return .{ .dir = dir };
    }

    pub fn close(self: *WaitStore) void {
        self.dir.close();
    }

    /// Latches the signal (an existing marker stays).
    pub fn signal(self: *WaitStore, file: []const u8) Error!void {
        const f = self.dir.createFile(file, .{ .truncate = false }) catch return error.Unavailable;
        f.close();
    }

    /// Consumes the marker when it exists and is a regular file of the
    /// user; true when this caller took it.
    pub fn consume(self: *WaitStore, file: []const u8) bool {
        if (builtin.os.tag == .windows) {
            const st = self.dir.statFile(file) catch return false;
            if (st.kind != .file) return false;
        } else {
            const st = std.posix.fstatat(self.dir.fd, file, std.posix.AT.SYMLINK_NOFOLLOW) catch return false;
            if (!std.posix.S.ISREG(st.mode) or st.uid != std.posix.getuid()) return false;
        }
        self.dir.deleteFile(file) catch return false;
        return true;
    }
};

const wait_usage = usageOf("wait-for");

fn runWaitFor(ctx: *Ctx) !u8 {
    const o = (try ps.parseArgs(ctx, wait_usage, .{ .values = &.{"--timeout"}, .bools = &.{ "-S", "--signal" } })) orelse return output.exit.usage;
    if (o.positionals.len == 0) return ps.usageWithLine(ctx, wait_usage, "wait-for requires a name", .{});
    if (o.positionals.len > 1) return unexpected(ctx, wait_usage, o.positionals[1]);
    const name = o.positionals[0];
    if (name.len > max_wait_name_bytes) return ps.usageWithLine(ctx, wait_usage, "wait-for name is longer than {d} bytes", .{max_wait_name_bytes});
    var timeout_ms: i64 = default_wait_timeout_s * 1000;
    if (o.get(&.{"--timeout"})) |t| {
        const s = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " \t")) catch
            return ps.usageWithLine(ctx, wait_usage, "--timeout must be a number of seconds", .{});
        if (!(s >= 0) or s > 86_400 * 365) return ps.usageWithLine(ctx, wait_usage, "--timeout must be a number of seconds", .{});
        timeout_ms = @intFromFloat(s * 1000);
    }
    const path = (try waitDir(ctx)) orelse return ctx.runtimeError("wait-for: no temporary directory (TEMP is unset)", .{});
    var store = WaitStore.open(path) catch |err| return switch (err) {
        error.NotPrivate => ctx.runtimeError("wait-for: {s} is not a private directory of this user", .{path}),
        error.Unavailable => ctx.runtimeError("wait-for: cannot use {s}", .{path}),
    };
    defer store.close();
    const file = try markerName(ctx.arena, name);
    if (o.has("-S") or o.has("--signal")) {
        store.signal(file) catch return ctx.runtimeError("wait-for: cannot signal '{s}' in {s}", .{ name, path });
        return output.exit.ok;
    }
    const deadline = ctx.platform.nowMs() + timeout_ms;
    while (true) {
        if (store.consume(file)) return output.exit.ok;
        const now = ctx.platform.nowMs();
        if (now >= deadline) break;
        ctx.platform.sleepMs(@intCast(@min(wait_poll_ms, deadline - now)));
    }
    return ctx.runtimeError("wait-for: timed out waiting for '{s}'", .{name});
}

// ----- tests -----

const testing = std.testing;
const pt = @import("ps_testing.zig");
const Harness = pt.Harness;

const sf_uuid = "9B69C1E2-3D4F-4A5B-8C6D-7E8F9A0B1C2D";

test "unit: cli-ps: terminal_io --help works offline and matches goldens" {
    var names: [commands.len][]const u8 = undefined;
    for (commands, 0..) |c, i| names[i] = c.name;
    try pt.expectHelpGoldens(&names);
}

test "unit: cli-ps: send escapes, enter-only detection and paste hint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("echo hi\n", try unescape(a, "echo hi\\n"));
    try testing.expectEqualStrings("a\tb\rc\\d\\x\\", try unescape(a, "a\\tb\\rc\\\\d\\x\\"));
    try testing.expectEqualStrings("", try unescape(a, ""));
    try testing.expectEqualStrings("h\u{e9}llo \u{1F600}\n", try unescape(a, "h\u{e9}llo \u{1F600}\\n"));
    try testing.expect(isEnterOnly("\n"));
    try testing.expect(isEnterOnly("\r\n\r"));
    try testing.expect(!isEnterOnly(""));
    try testing.expect(!isEnterOnly("ls\n"));
    try testing.expect(!wantsPasteHint("echo hi\n"));
    try testing.expect(!wantsPasteHint("a\r\n"));
    try testing.expect(wantsPasteHint("a\nb\n"));
    const big = try a.alloc(u8, 4097);
    @memset(big, 'x');
    try testing.expect(wantsPasteHint(big));
    try testing.expect(!wantsPasteHint(big[0..4096]));
}

test "unit: cli-ps: send-key name table" {
    for ([_][]const u8{ "enter", "Return", "TAB", "esc", "escape", "backspace", "delete", "del", "forward_delete", "space", "up", "arrow_up", "ArrowUp", "down", "left", "right", "home", "end", "pageup", "page_up", "pagedown", "page_down", "shift+tab", "shift-tab", "backtab", "ctrl-c", "ctrl+c", "sigint", "ctrl-d", "eof", "ctrl-f", "ctrl-z", "sigtstp", "ctrl-\\", "sigquit", "ctrl+r", "Ctrl+Shift+T", "alt-left", "opt+b", "cmd+k", "super-a", "control+page_down", " enter " }) |k| {
        if (!isValidKey(k)) {
            std.debug.print("rejected valid key '{s}'\n", .{k});
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ "", "bogus", "ctrl+", "ctrl", "+c", "ctrl+cc", "ctrl+1", "hyper+a", "shift+\u{e9}", "f13x", "ctrl-+" }) |k| {
        if (isValidKey(k)) {
            std.debug.print("accepted invalid key '{s}'\n", .{k});
            return error.TestUnexpectedResult;
        }
    }
    var long: [100]u8 = undefined;
    @memset(&long, 'a');
    try testing.expect(!isValidKey(&long));
}

test "unit: cli-ps: send params, double dash, caller default and hint on stderr" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.setEnv("CMUX_SURFACE_ID", sf_uuid);
    const r = h.run(&.{ "cmux", "send", "echo hi\\n" });
    try pt.expectOk(r);
    try testing.expectEqualStrings("OK\n", r.out);
    try testing.expectEqual(@as(usize, 2), h.requests().len);
    try testing.expectEqualStrings("surface.input_state", h.requests()[0].method);
    try testing.expectEqualStrings("{\"surface_id\":\"" ++ sf_uuid ++ "\"}", h.requests()[0].params_json);
    try h.expectLast("surface.send_text", "{\"text\":\"echo hi\\n\",\"surface_id\":\"" ++ sf_uuid ++ "\"}");
    // Words after the first are text, flags included; `--` protects a dash.
    _ = h.run(&.{ "cmux", "send", "--surface", "surface:2", "ls", "--force", "-la" });
    try h.expectLast("surface.send_text", "{\"text\":\"ls --force -la\",\"surface_id\":\"surface:2\"}");
    _ = h.run(&.{ "cmux", "send", "--force", "--", "--help" });
    try h.expectLast("surface.send_text", "{\"text\":\"--help\",\"surface_id\":\"" ++ sf_uuid ++ "\"}");
    const multi = h.run(&.{ "cmux", "send", "--force", "a\\nb\\n" });
    try testing.expectEqual(@as(u8, 0), multi.code);
    try testing.expectEqualStrings("OK\n", multi.out);
    try testing.expectEqualStrings(paste_hint, multi.err);
    const wm = h.run(&.{ "wmux", "send", "--force", "a\\nb\\n" });
    try pt.expectContains(wm.err, "use wmux send --paste or wmux paste");
    // --paste: unchanged text through terminal.paste, no hint.
    const pr = h.run(&.{ "cmux", "send", "--paste", "--force", "a\\nb\\n" });
    try pt.expectOk(pr);
    try h.expectLast("terminal.paste", "{\"text\":\"a\\\\nb\\\\n\",\"submit_key\":\"none\",\"surface_id\":\"" ++ sf_uuid ++ "\"}");
    // send-panel requires --panel and ignores the caller surface.
    _ = h.run(&.{ "cmux", "send-panel", "--panel", "surface:2", "--force", "echo hello\\n" });
    try h.expectLast("surface.send_text", "{\"text\":\"echo hello\\n\",\"surface_id\":\"surface:2\"}");

    h.clearRequests();
    try pt.expectUsage(h.run(&.{ "cmux", "send" }), "send requires text");
    try pt.expectUsage(h.run(&.{ "cmux", "send-panel", "hi" }), "send-panel requires --panel <id|ref|index>");
    try pt.expectUsage(h.run(&.{ "cmux", "send-panel", "--panel", "nope", "hi" }), "Invalid surface handle: nope");
    try testing.expectEqual(@as(usize, 0), h.requests().len);
    // An unknown dash word starts the text.
    _ = h.run(&.{ "cmux", "send", "--force", "--version", "-la" });
    try h.expectLast("surface.send_text", "{\"text\":\"--version -la\",\"surface_id\":\"" ++ sf_uuid ++ "\"}");
    try pt.expectUsage(h.run(&.{ "cmux", "send-key", "--bogus" }), "unknown key '--bogus'");
}

test "unit: cli-ps: draft guard refuses over drafts and dialogs, --force and old apps proceed" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.ok("surface.input_state", "{\"state\":\"draft\",\"draft_length\":12,\"agent\":true,\"lifecycle\":\"idle\",\"blocks_typing\":true,\"terminal\":true}");
    const r = h.run(&.{ "cmux", "send", "--surface", "surface:2", "hi" });
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings("cmux: send refused: the agent prompt holds an unsent draft (12 characters); nothing was sent (use --force to send anyway)\n", r.err);
    try testing.expectEqual(@as(usize, 1), h.server.countMethod("surface.input_state"));
    try testing.expectEqual(@as(usize, 0), h.server.countMethod("surface.send_text"));
    // Enter-only text and keys pass a draft.
    try pt.expectOk(h.run(&.{ "cmux", "send", "--surface", "surface:2", "\\n" }));
    try pt.expectOk(h.run(&.{ "cmux", "send-key", "--surface", "surface:2", "enter" }));
    try testing.expectEqual(@as(usize, 1), h.server.countMethod("surface.send_key"));
    // paste refuses over a draft; --force skips the check entirely.
    try testing.expectEqual(@as(u8, 1), h.run(&.{ "cmux", "paste", "--surface", "surface:2", "x" }).code);
    h.clearRequests();
    try pt.expectOk(h.run(&.{ "cmux", "send", "--force", "--surface", "surface:2", "hi" }));
    try testing.expectEqual(@as(usize, 0), h.server.countMethod("surface.input_state"));
    // A dialog blocks keys too.
    h.ok("surface.input_state", "{\"state\":\"dialog\",\"agent\":true}");
    const k = h.run(&.{ "cmux", "send-key-panel", "--panel", "surface:2", "enter" });
    try testing.expectEqual(@as(u8, 1), k.code);
    try pt.expectContains(k.err, "send-key-panel refused: an agent question or permission dialog is open");
    try pt.expectOk(h.run(&.{ "cmux", "send-key-panel", "--panel", "surface:2", "--force", "enter" }));
    // No agent: never blocked. Old app: method_not_found lets it through.
    h.ok("surface.input_state", "{\"state\":\"draft\",\"agent\":false}");
    try pt.expectOk(h.run(&.{ "cmux", "send", "hi" }));
    h.reply("surface.input_state", .{ .err = "{\"code\":\"method_not_found\",\"message\":\"Unknown method\"}" });
    try pt.expectOk(h.run(&.{ "cmux", "send", "hi" }));
    try pt.expectOk(h.run(&.{ "cmux", "paste", "hi" }));
}

test "unit: cli-ps: send-key params and validation" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.setEnv("CMUX_WORKSPACE_ID", "W-UUID");
    h.setEnv("CMUX_SURFACE_ID", sf_uuid);
    _ = h.run(&.{ "cmux", "send-key", "ctrl+c" });
    try h.expectLast("surface.send_key", "{\"key\":\"ctrl+c\",\"workspace_id\":\"W-UUID\",\"surface_id\":\"" ++ sf_uuid ++ "\"}");
    _ = h.run(&.{ "cmux", "send-key", "--workspace", "workspace:2", "--force", "--", "up" });
    try h.expectLast("surface.send_key", "{\"key\":\"up\",\"workspace_id\":\"workspace:2\"}");
    h.clearRequests();
    try pt.expectUsage(h.run(&.{ "cmux", "send-key" }), "send-key requires a key");
    try pt.expectUsage(h.run(&.{ "cmux", "send-key", "bogus" }), "unknown key 'bogus'");
    try pt.expectUsage(h.run(&.{ "cmux", "send-key", "enter", "tab" }), "unexpected argument 'tab'");
    try pt.expectUsage(h.run(&.{ "cmux", "send-key-panel", "enter" }), "send-key-panel requires --panel <id|ref|index>");
    try testing.expectEqual(@as(usize, 0), h.requests().len);
    // A server-side rejection still maps to exit 1.
    h.reply("surface.send_key", .{ .err = "{\"code\":\"invalid_params\",\"message\":\"Unknown key\",\"data\":{\"key\":\"ctrl+q\"}}" });
    const r = h.run(&.{ "cmux", "send-key", "--force", "ctrl+q" });
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings("invalid_params: Unknown key\n", r.err);
}

test "unit: cli-ps: paste reads argument or stdin and maps submit" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = h.run(&.{ "cmux", "paste", "--force", "--submit", "Review this" });
    try h.expectLast("terminal.paste", "{\"text\":\"Review this\",\"submit_key\":\"enter\"}");
    h.fp.stdin = "diff --git a/x b/x\n+\u{1F600}\x1b[31m\n";
    _ = h.run(&.{ "cmux", "paste", "--force", "--surface", "surface:2" });
    try h.expectLast("terminal.paste", "{\"text\":\"diff --git a/x b/x\\n+\u{1F600}\\u001b[31m\\n\",\"submit_key\":\"none\",\"surface_id\":\"surface:2\"}");
    _ = h.run(&.{ "cmux", "paste", "--force", "-" });
    try testing.expectEqualStrings("diff --git a/x b/x\n+\u{1F600}\x1b[31m\n", (try h.last()).params.object.get("text").?.string);
    // `-- -` pastes a literal dash; `\n` is not interpreted.
    _ = h.run(&.{ "cmux", "paste", "--force", "--", "-" });
    try h.expectLast("terminal.paste", "{\"text\":\"-\",\"submit_key\":\"none\"}");
    _ = h.run(&.{ "cmux", "paste", "--force", "a\\n" });
    try h.expectLast("terminal.paste", "{\"text\":\"a\\\\n\",\"submit_key\":\"none\"}");
    h.clearRequests();
    h.fp.stdin = "";
    try pt.expectUsage(h.run(&.{ "cmux", "paste" }), "paste needs text: the text is empty");
    h.fp.interactive = true;
    try pt.expectUsage(h.run(&.{ "cmux", "paste" }), "paste needs text: pass it as an argument or pipe it on stdin");
    h.fp.interactive = false;
    // Over 15 MiB after JSON escaping (quotes become two bytes each).
    const big = try h.alloc().alloc(u8, max_paste_json_bytes / 2 + 1);
    @memset(big, '"');
    h.fp.stdin = big;
    try pt.expectUsage(h.run(&.{ "cmux", "paste" }), "paste text exceeds 15 MiB");
    const huge = try h.alloc().alloc(u8, max_paste_json_bytes + 1);
    @memset(huge, 'x');
    h.fp.stdin = huge;
    try pt.expectUsage(h.run(&.{ "cmux", "paste" }), "paste text exceeds 15 MiB");
    try testing.expectEqual(@as(usize, 0), h.requests().len);
    try testing.expectEqual(@as(usize, 2 + 2 + 6 + 1), jsonStringLen("\"\x01a"));
}

test "unit: cli-ps: read-screen, capture-pane and read-selection" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.setEnv("CMUX_WORKSPACE_ID", "W-UUID");
    h.setEnv("CMUX_SURFACE_ID", sf_uuid);
    h.ok("surface.read_text", "{\"text\":\"$ echo marker\\nmarker\\n$ \",\"base64\":\"\",\"surface_ref\":\"surface:1\"}");
    const r = h.run(&.{ "cmux", "read-screen" });
    try pt.expectOk(r);
    try h.expectLast("surface.read_text", "{\"workspace_id\":\"W-UUID\",\"surface_id\":\"" ++ sf_uuid ++ "\"}");
    try pt.expectGolden(h.alloc(), "read-screen.txt", r.out);
    _ = h.run(&.{ "cmux", "read-screen", "--lines", "5" });
    try h.expectLast("surface.read_text", "{\"workspace_id\":\"W-UUID\",\"surface_id\":\"" ++ sf_uuid ++ "\",\"scrollback\":true,\"lines\":5}");
    const c = h.run(&.{ "cmux", "capture-pane", "--surface", "surface:1", "--scrollback", "--lines", "200" });
    try h.expectLast("surface.read_text", "{\"workspace_id\":\"W-UUID\",\"surface_id\":\"surface:1\",\"scrollback\":true,\"lines\":200}");
    try testing.expectEqualStrings(r.out, c.out);
    _ = h.run(&.{ "cmux", "capture-pane", "--window", "window:1" });
    try h.expectLast("surface.read_text", "{\"window_id\":\"window:1\"}");
    const j = h.run(&.{ "cmux", "read-screen", "--json" });
    try pt.expectContains(j.out, "\"surface_ref\": \"surface:1\"");
    h.ok("surface.read_text", "{\"text\":\"\"}");
    try testing.expectEqualStrings("\n", h.run(&.{ "cmux", "read-screen" }).out);

    h.ok("surface.read_selection", "{\"has_selection\":true,\"kind\":\"filepreview\",\"text\":\"let answer = 42\",\"base64\":\"x\",\"file_path\":\"C:\\\\src\\\\Answer.swift\",\"line_range\":{\"start\":7,\"end\":7}}");
    const sel = h.run(&.{ "cmux", "read-selection", "--surface", "surface:2" });
    try pt.expectOk(sel);
    try h.expectLast("surface.read_selection", "{\"workspace_id\":\"W-UUID\",\"surface_id\":\"surface:2\"}");
    try pt.expectGolden(h.alloc(), "read-selection.txt", sel.out);
    try testing.expectEqualStrings("let answer = 42\n", h.run(&.{ "cmux", "read-screen", "--selection" }).out);
    h.ok("surface.read_selection", "{\"has_selection\":true,\"kind\":\"browser\",\"text\":\"Hello\",\"url\":\"https://example.com/\"}");
    try testing.expectEqualStrings("Kind: browser\nURL: https://example.com/\nHello\n", h.run(&.{ "cmux", "read-selection" }).out);
    h.ok("surface.read_selection", "{\"has_selection\":false,\"kind\":\"terminal\",\"text\":\"\",\"base64\":\"\"}");
    const none = h.run(&.{ "cmux", "read-selection" });
    try pt.expectOk(none);
    try testing.expectEqualStrings("Has selection: false\n", none.out);

    h.clearRequests();
    try pt.expectUsage(h.run(&.{ "cmux", "read-screen", "--lines", "0" }), "--lines must be greater than 0");
    try pt.expectUsage(h.run(&.{ "cmux", "read-screen", "--lines", "x" }), "--lines must be an integer");
    try pt.expectUsage(h.run(&.{ "cmux", "read-screen", "--selection", "--scrollback" }), "--selection cannot be combined with --scrollback or --lines");
    try pt.expectUsage(h.run(&.{ "cmux", "capture-pane", "--selection" }), "unknown flag '--selection'");
    try pt.expectUsage(h.run(&.{ "cmux", "read-selection", "x" }), "unexpected argument 'x'");
    try testing.expectEqual(@as(usize, 0), h.requests().len);
}

test "unit: cli-ps: legacy +send, +read-screen and +capture-pane spellings" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.setEnv("CMUX_QUIET", "1");
    h.setEnv("CMUX_WORKSPACE_ID", "W-UUID");
    h.setEnv("CMUX_SURFACE_ID", sf_uuid);
    // ADR-4.11: --tab T names the surface and --pane P the pane. An explicit
    // pane drops the caller's surface, and the draft guard asks about the
    // same target the write goes to.
    const r = h.run(&.{ "wmux", "+send", "--pane", "1", "--tab", "2", "ls", "--enter" });
    try pt.expectOk(r);
    try testing.expectEqualStrings("surface.input_state", h.requests()[0].method);
    try testing.expectEqualStrings("{\"workspace_id\":\"W-UUID\",\"pane_id\":1,\"surface_id\":2}", h.requests()[0].params_json);
    try h.expectLast("surface.send_text", "{\"text\":\"ls\\r\",\"workspace_id\":\"W-UUID\",\"pane_id\":1,\"surface_id\":2}");
    _ = h.run(&.{ "wmux", "+send", "--pane", "0", "pwd" });
    try h.expectLast("surface.send_text", "{\"text\":\"pwd\",\"workspace_id\":\"W-UUID\",\"pane_id\":0}");
    // The old text-first order: the flags still target, they are not typed.
    _ = h.run(&.{ "wmux", "+send", "echo hi", "--workspace", "1", "--tab", "0", "--enter" });
    try h.expectLast("surface.send_text", "{\"text\":\"echo hi\\r\",\"workspace_id\":1,\"surface_id\":0}");
    _ = h.run(&.{ "wmux", "+read-screen", "--workspace", "0", "--tab", "1", "--lines", "5" });
    try h.expectLast("surface.read_text", "{\"workspace_id\":0,\"surface_id\":1,\"scrollback\":true,\"lines\":5}");
    _ = h.run(&.{ "wmux", "+capture-pane", "--pane", "2", "--scrollback" });
    try h.expectLast("surface.read_text", "{\"workspace_id\":\"W-UUID\",\"pane_id\":2,\"scrollback\":true}");
    h.clearRequests();
    try pt.expectUsage(h.run(&.{ "wmux", "+capture-pane", "--tab", "x" }), "Invalid surface handle: x");
    try pt.expectUsage(h.run(&.{ "wmux", "+send", "--pane", "", "hi" }), "Pane handle is blank");
    try testing.expectEqual(@as(usize, 0), h.requests().len);
}

test "unit: cli-ps: wait-for marker names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("empty.sig", try markerName(a, ""));
    try testing.expectEqualStrings("am9i.sig", try markerName(a, "job"));
    // URL-safe alphabet: no '/' or '+' in file names.
    const m = try markerName(a, "\xfb\xff/\u{1F600}");
    try testing.expect(std.mem.indexOfAny(u8, m, "/+=\\") == null);
    const long = try a.alloc(u8, max_wait_name_bytes);
    @memset(long, 0xff);
    try testing.expect((try markerName(a, long)).len < 255);
}

test "unit: cli-ps: wait-for signals are latched, consumed once, and time out" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const dir = try std.fs.path.join(h.alloc(), &.{ try tmp.dir.realpathAlloc(h.alloc(), "."), "w" });
    h.setEnv("WMUX_WAIT_FOR_DIR", dir);
    try pt.expectOk(h.run(&.{ "cmux", "wait-for", "-S", "job" }));
    try pt.expectOk(h.run(&.{ "cmux", "wait-for", "-S", "job" }));
    const start = h.fp.clock;
    try pt.expectOk(h.run(&.{ "cmux", "wait-for", "job" }));
    try testing.expectEqual(start, h.fp.clock);
    // The signal was consumed: the next wait times out after ~1 s.
    const t = h.run(&.{ "cmux", "wait-for", "job", "--timeout", "1" });
    try testing.expectEqual(@as(u8, 1), t.code);
    try testing.expectEqualStrings("cmux: wait-for: timed out waiting for 'job'\n", t.err);
    try testing.expectEqual(start + 1000, h.fp.clock);
    // Unicode and empty names; --signal spelling; zero timeout checks once.
    try pt.expectOk(h.run(&.{ "cmux", "wait-for", "--signal", "\u{65e5}\u{672c}" }));
    try pt.expectOk(h.run(&.{ "cmux", "wait-for", "\u{65e5}\u{672c}", "--timeout", "0" }));
    try pt.expectOk(h.run(&.{ "cmux", "wait-for", "-S", "" }));
    try pt.expectOk(h.run(&.{ "cmux", "wait-for", "", "--timeout=0.5" }));
    try testing.expectEqual(@as(u8, 1), h.run(&.{ "cmux", "wait-for", "other", "--timeout", "0" }).code);
    // A directory named like a marker is not a signal.
    var d = try std.fs.cwd().openDir(dir, .{});
    defer d.close();
    try d.makeDir("ZmFrZQ.sig");
    try testing.expectEqual(@as(u8, 1), h.run(&.{ "cmux", "wait-for", "fake", "--timeout", "0" }).code);
    // Offline: never connects.
    try testing.expectEqual(@as(usize, 0), h.fp.connects);

    try pt.expectUsage(h.run(&.{ "cmux", "wait-for" }), "wait-for requires a name");
    try pt.expectUsage(h.run(&.{ "cmux", "wait-for", "a", "b" }), "unexpected argument 'b'");
    try pt.expectUsage(h.run(&.{ "cmux", "wait-for", "a", "--timeout", "soon" }), "--timeout must be a number of seconds");
    try pt.expectUsage(h.run(&.{ "cmux", "wait-for", "a", "--timeout", "-1" }), "--timeout must be a number of seconds");
    try pt.expectUsage(h.run(&.{ "cmux", "wait-for", "a", "--timeout", "nan" }), "--timeout must be a number of seconds");
    const long = try h.alloc().alloc(u8, max_wait_name_bytes + 1);
    @memset(long, 'n');
    try pt.expectUsage(h.run(&.{ "cmux", "wait-for", long }), "wait-for name is longer than 180 bytes");
}

test "unit: cli-ps: terminal_io OK lines match goldens" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const reply = "{\"surface_id\":\"S2\",\"surface_ref\":\"surface:2\",\"workspace_id\":\"W1\",\"workspace_ref\":\"workspace:1\"}";
    const cases = [_]struct { []const u8, []const u8, []const []const u8 }{
        .{ "send", "surface.send_text", &.{ "cmux", "send", "--surface", "surface:2", "echo hi\\n" } },
        .{ "send-key", "surface.send_key", &.{ "cmux", "send-key", "--surface", "surface:2", "ctrl+c" } },
        .{ "send-panel", "surface.send_text", &.{ "cmux", "send-panel", "--panel", "surface:2", "ls\\n" } },
        .{ "send-key-panel", "surface.send_key", &.{ "cmux", "send-key-panel", "--panel", "surface:2", "enter" } },
        .{ "paste", "terminal.paste", &.{ "cmux", "paste", "--surface", "surface:2", "text" } },
    };
    for (cases) |c| {
        h.ok(c[1], reply);
        const r = h.run(c[2]);
        try pt.expectOk(r);
        try testing.expectEqualStrings(c[1], (try h.last()).method);
        try pt.expectGolden(h.alloc(), try std.fmt.allocPrint(h.alloc(), "{s}.txt", .{c[0]}), r.out);
    }
    h.ok("surface.read_text", "{\"text\":\"line 1\\nline 2\"}");
    try pt.expectGolden(h.alloc(), "capture-pane.txt", h.run(&.{ "cmux", "capture-pane", "--lines", "2" }).out);
}
