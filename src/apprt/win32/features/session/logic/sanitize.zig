//! Untrusted-import sanitizer for `session.import` from a file path
//! (`restore-session --from <path>`, ADR-9.8). Layout, cwds, titles,
//! stripped text scrollback and http(s) browser tabs survive; workspace env
//! vars, remote connections (at any level), spawn command lines, browser
//! profiles, non-http(s) pages, unknown panel kinds and automatic agent
//! resume data do not. Channel imports are trusted and skip this pass.

const std = @import("std");
const schema = @import("schema_v3.zig");
const integrity = @import("integrity.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Tab `ext` keys whose resume data is held back (manual restore only).
pub const resume_ext_keys = [_][]const u8{ "agents", "resume" };
/// `ext` keys that carry remote connections, removed from windows,
/// workspaces, panes and tabs: the `remote` (SSH workspaces) and
/// `remote_tmux` (ssh-tmux mirror: tmux windows and panes map to workspaces
/// and panes) features of ADR-13, plus `ssh` and `cloud`.
pub const remote_ext_keys = [_][]const u8{ "remote", "remote_tmux", "ssh", "cloud" };
/// Fields of `ext.agents` kept for a manual resume rebuilt from kind + id.
pub const agent_identity_keys = [_][]const u8{ "kind", "session_id" };

pub const Report = struct {
    /// Terminals whose automatic resume was held back
    /// (cmux `held_back_resume_count`).
    held_back_resume_count: usize = 0,
    /// Workspaces opened without the file's remote connection and env vars
    /// (cmux `dropped_remote_workspace_count`).
    dropped_remote_workspace_count: usize = 0,
    /// Browser tabs removed because their page was not http(s).
    dropped_browser_tab_count: usize = 0,
    /// Tabs of a panel kind this build does not know.
    dropped_unknown_panel_count: usize = 0,
};

/// True for `http://` and `https://` URLs (scheme case-insensitive).
pub fn isHttpUrl(url: []const u8) bool {
    return hasSchemePrefix(url, "http://") or hasSchemePrefix(url, "https://");
}

fn hasSchemePrefix(url: []const u8, prefix: []const u8) bool {
    return url.len > prefix.len and std.ascii.eqlIgnoreCase(url[0..prefix.len], prefix);
}

/// Applies the untrusted rules in place and repairs the result with
/// `schema.normalize` (removed tabs can empty panes).
pub fn sanitizeUntrusted(arena: Allocator, s: *schema.Session) !Report {
    var r: Report = .{};
    for (s.windows) |*w| {
        _ = stripKeys(&w.ext, &remote_ext_keys);
        for (w.workspaces) |*ws| {
            var remote = ws.env.len > 0 or stripKeys(&ws.ext, &remote_ext_keys);
            ws.env = &.{};
            for (ws.panes) |*p| {
                if (stripKeys(&p.ext, &remote_ext_keys)) remote = true;
                var kept: usize = 0;
                for (p.tabs) |tab_in| {
                    var t = tab_in;
                    if (stripKeys(&t.ext, &remote_ext_keys)) remote = true;
                    if (!try sanitizeTab(arena, &t, &r)) continue;
                    p.tabs[kept] = t;
                    kept += 1;
                }
                p.tabs = p.tabs[0..kept];
            }
            if (remote) r.dropped_remote_workspace_count += 1;
        }
    }
    try schema.normalize(arena, s);
    return r;
}

/// Returns false when the tab must be removed.
fn sanitizeTab(arena: Allocator, t: *schema.Tab, r: *Report) !bool {
    switch (t.panel) {
        .terminal => |*term| {
            // A command line from a file is arbitrary code; keep only the
            // shell kind so restore launches that shell with defaults.
            if (term.spawn) |*sp| sp.argv = &.{};
            if (term.scrollback) |ref| {
                if (!integrity.isSafeScrollbackRef(ref)) term.scrollback = null;
            }
        },
        .browser => |*b| {
            if (!isHttpUrl(b.url)) {
                r.dropped_browser_tab_count += 1;
                return false;
            }
            b.back = try filterHttp(arena, b.back);
            b.forward = try filterHttp(arena, b.forward);
            b.profile = null;
        },
        .web, .placeholder => {},
        .unknown => {
            r.dropped_unknown_panel_count += 1;
            return false;
        },
    }
    if (try holdBackResume(arena, &t.ext)) r.held_back_resume_count += 1;
    return true;
}

fn filterHttp(arena: Allocator, urls: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (urls) |u| if (isHttpUrl(u)) try out.append(arena, u);
    return out.items;
}

/// Reduces `ext.agents` to its identity fields and removes `ext.resume`.
/// Returns true when anything resumable was held back.
fn holdBackResume(arena: Allocator, ext: *schema.Ext) !bool {
    const m = if (ext.*) |*m| m else return false;
    var held = false;
    if (m.fetchOrderedRemove("resume") != null) held = true;
    if (m.getPtr("agents")) |agents| {
        held = true;
        var identity: std.json.ObjectMap = .init(arena);
        if (agents.* == .object) {
            for (agent_identity_keys) |k| {
                if (agents.object.get(k)) |v| if (v == .string) try identity.put(k, v);
            }
        }
        agents.* = .{ .object = identity };
    }
    return held;
}

/// Removes `keys` from `ext`; true when any was present.
fn stripKeys(ext: *schema.Ext, keys: []const []const u8) bool {
    const m = if (ext.*) |*m| m else return false;
    var any = false;
    for (keys) |k| {
        if (m.fetchOrderedRemove(k) != null) any = true;
    }
    return any;
}

/// Plain text of a scrollback file from an untrusted source: every escape
/// sequence (CSI, OSC, DCS/SOS/PM/APC strings, two-byte ESC sequences), the
/// C1 controls and the C0 controls other than TAB, LF and CR are removed.
/// UTF-8 text passes through unchanged.
pub fn stripControlSequences(gpa: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, text.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == 0x1b) {
            i = skipEscape(text, i + 1);
            continue;
        }
        // C1 controls encoded in UTF-8 (U+0080..U+009F = C2 80..C2 9F).
        if (c == 0xc2 and i + 1 < text.len and text[i + 1] >= 0x80 and text[i + 1] <= 0x9f) {
            const c1 = text[i + 1];
            i += 2;
            switch (c1) {
                0x9b => i = skipCsi(text, i),
                0x9d, 0x90, 0x98, 0x9e, 0x9f => i = skipString(text, i),
                else => {},
            }
            continue;
        }
        if (c < 0x20 and c != '\t' and c != '\n' and c != '\r') {
            i += 1;
            continue;
        }
        if (c == 0x7f) {
            i += 1;
            continue;
        }
        out.appendAssumeCapacity(c);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// `i` is just past ESC; returns the index after the sequence.
fn skipEscape(text: []const u8, i: usize) usize {
    if (i >= text.len) return i;
    return switch (text[i]) {
        '[' => skipCsi(text, i + 1),
        ']', 'P', 'X', '^', '_' => skipString(text, i + 1),
        else => blk: {
            // Intermediates 0x20-0x2F, then a final byte 0x30-0x7E. Any
            // other byte (a control, ESC, DEL, a UTF-8 lead byte) cannot end
            // the sequence: drop ESC and the intermediates and resume at it,
            // so line breaks and multi-byte characters survive.
            var j = i;
            while (j < text.len and text[j] >= 0x20 and text[j] <= 0x2f) j += 1;
            if (j < text.len and text[j] >= 0x30 and text[j] <= 0x7e) j += 1;
            break :blk j;
        },
    };
}

/// Parameters and intermediates up to a final byte 0x40-0x7E.
fn skipCsi(text: []const u8, i: usize) usize {
    var j = i;
    while (j < text.len) : (j += 1) {
        if (text[j] >= 0x40 and text[j] <= 0x7e) return j + 1;
        if (text[j] < 0x20) return j; // malformed; resume at the control
    }
    return j;
}

/// Up to and including BEL, ST (ESC \) or C1 ST (C2 9C).
fn skipString(text: []const u8, i: usize) usize {
    var j = i;
    while (j < text.len) : (j += 1) {
        if (text[j] == 0x07) return j + 1;
        if (text[j] == 0x1b and j + 1 < text.len and text[j + 1] == '\\') return j + 2;
        if (text[j] == 0xc2 and j + 1 < text.len and text[j + 1] == 0x9c) return j + 2;
    }
    return j;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "unit: session: untrusted import drops env, remote, commands and resume" {
    var p = try schema.parse(testing.allocator, @embedFile("testdata/v3_full.json"), .{}, null);
    defer p.deinit();
    const arena = p.arena.allocator();
    const r = try sanitizeUntrusted(arena, &p.session);
    try testing.expectEqual(@as(usize, 1), r.held_back_resume_count);
    try testing.expectEqual(@as(usize, 1), r.dropped_remote_workspace_count);
    try testing.expectEqual(@as(usize, 0), r.dropped_browser_tab_count);
    try testing.expectEqual(@as(usize, 1), r.dropped_unknown_panel_count);
    const ws = p.session.windows[0].workspaces[0];
    try testing.expectEqual(@as(usize, 0), ws.env.len);
    // Layout, cwd and titles survive.
    try testing.expectEqualStrings("C:\\src\\api", ws.cwd.?);
    try testing.expectEqualStrings("api ✓", ws.title.custom.?);
    try testing.expect(ws.layout.? == .split);
    const term = ws.panes[0].tabs[0];
    try testing.expectEqual(@as(usize, 0), term.panel.terminal.spawn.?.argv.len);
    try testing.expectEqualStrings("pwsh", term.panel.terminal.spawn.?.shell_kind.?);
    try testing.expect(term.panel.terminal.scrollback != null);
    const agents = schema.extGet(term.ext, "agents").?.object;
    try testing.expectEqualStrings("claude", agents.get("kind").?.string);
    try testing.expectEqualStrings("abc", agents.get("session_id").?.string);
    try testing.expect(agents.get("launch") == null);
    const browser = ws.panes[0].tabs[1].panel.browser;
    try testing.expect(browser.profile == null);
    try testing.expectEqualStrings("https://example.com/b", browser.url);
    try testing.expectEqual(@as(usize, 2), ws.panes[1].tabs.len); // unknown panel removed
    // Other ext keys untouched.
    try testing.expectEqualStrings("#3B82F6", schema.extGet(ws.ext, "workspace_style").?.object.get("color").?.string);
}

test "unit: session: untrusted import filters browser schemes and scrollback refs" {
    var p = try schema.parse(testing.allocator,
        \\{"schema":"wmux-session","version":3,"windows":[{"workspaces":[{"ext":{"ssh":{"host":"h"}},"panes":[
        \\ {"id":"44444444-4444-4444-8444-444444444441","tabs":[
        \\  {"panel":{"kind":"browser","url":"file:///C:/secret.txt"}},
        \\  {"panel":{"kind":"browser","url":"javascript:alert(1)"}}]},
        \\ {"id":"44444444-4444-4444-8444-444444444442","tabs":[
        \\  {"panel":{"kind":"browser","url":"HTTPS://ok.example/","back":["http://a.example/","wmux://settings","ftp://x"],"forward":["about:blank","https://c.example/"]}},
        \\  {"panel":{"kind":"terminal","scrollback":"..\\..\\Windows\\win.ini"},"ext":{"resume":{"cmd":"rm -rf"}}},
        \\  {"panel":{"kind":"browser","url":"http://"}}]}]}]}]}
    , .{}, null);
    defer p.deinit();
    const r = try sanitizeUntrusted(p.arena.allocator(), &p.session);
    try testing.expectEqual(@as(usize, 3), r.dropped_browser_tab_count);
    try testing.expectEqual(@as(usize, 1), r.held_back_resume_count);
    try testing.expectEqual(@as(usize, 1), r.dropped_remote_workspace_count);
    const ws = p.session.windows[0].workspaces[0];
    try testing.expect(schema.extGet(ws.ext, "ssh") == null);
    // The pane that lost all its tabs is gone, and so is its layout leaf.
    try testing.expectEqual(@as(usize, 1), ws.panes.len);
    try testing.expectEqualStrings("44444444-4444-4444-8444-444444444442", ws.layout.?.pane);
    const b = ws.panes[0].tabs[0].panel.browser;
    try testing.expectEqual(@as(usize, 1), b.back.len);
    try testing.expectEqualStrings("http://a.example/", b.back[0]);
    try testing.expectEqual(@as(usize, 1), b.forward.len);
    const t = ws.panes[0].tabs[1];
    try testing.expect(t.panel.terminal.scrollback == null);
    try testing.expect(schema.extGet(t.ext, "resume") == null);
}

test "unit: session: untrusted import strips remote state at every level" {
    var p = try schema.parse(testing.allocator,
        \\{"schema":"wmux-session","version":3,"windows":[{"ext":{"remote":{"route":"r"},"keep":1},"workspaces":[
        \\ {"panes":[{"id":"44444444-4444-4444-8444-444444444441","ext":{"remote_tmux":{"pane":"%3"},"keep":2},"tabs":[{}]}]},
        \\ {"panes":[{"id":"44444444-4444-4444-8444-444444444442","tabs":[{"ext":{"remote_tmux":{},"keep":3}}]}]},
        \\ {"ext":{"remote_tmux":{"session":"s"}},"panes":[]},
        \\ {"panes":[{"id":"44444444-4444-4444-8444-444444444443","tabs":[{}]}]}]}]}
    , .{}, null);
    defer p.deinit();
    const r = try sanitizeUntrusted(p.arena.allocator(), &p.session);
    try testing.expectEqual(@as(usize, 3), r.dropped_remote_workspace_count);
    const w = p.session.windows[0];
    try testing.expect(schema.extGet(w.ext, "remote") == null);
    try testing.expect(schema.extGet(w.ext, "keep") != null);
    const pane_ext = w.workspaces[0].panes[0].ext;
    try testing.expect(schema.extGet(pane_ext, "remote_tmux") == null);
    try testing.expect(schema.extGet(pane_ext, "keep") != null);
    const tab_ext = w.workspaces[1].panes[0].tabs[0].ext;
    try testing.expect(schema.extGet(tab_ext, "remote_tmux") == null);
    try testing.expect(schema.extGet(tab_ext, "keep") != null);
    try testing.expect(schema.extGet(w.workspaces[2].ext, "remote_tmux") == null);
}

test "unit: session: http url check" {
    try testing.expect(isHttpUrl("http://a"));
    try testing.expect(isHttpUrl("HtTpS://a"));
    try testing.expect(!isHttpUrl("https://"));
    try testing.expect(!isHttpUrl(""));
    try testing.expect(!isHttpUrl("httpx://a"));
    try testing.expect(!isHttpUrl(" https://a"));
    try testing.expect(!isHttpUrl("file://c/"));
}

test "unit: session: scrollback control sequences are stripped" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "", "" },
        .{ "plain\r\n\ttext", "plain\r\n\ttext" },
        .{ "\x1b[1;31mred\x1b[0m", "red" },
        .{ "a\x1b]0;title\x07b", "ab" },
        .{ "a\x1b]52;c;ZXZpbA==\x1b\\b", "ab" },
        .{ "a\x1bPq#0;2;0;0;0\x1b\\b", "ab" },
        .{ "a\x1b(Bb\x1b=c\x1b7d", "abcd" },
        .{ "bell\x07 bs\x08 nul\x00 del\x7f", "bell bs nul del" },
        .{ "c1 \xc2\x9b31m csi \xc2\x9d0;t\xc2\x9c osc", "c1  csi  osc" },
        .{ "日本語 ✓ 😀", "日本語 ✓ 😀" },
        .{ "trailing\x1b", "trailing" },
        .{ "unterminated \x1b]0;never ends", "unterminated " },
        .{ "csi broken \x1b[12\nnext", "csi broken \nnext" },
        // A stray ESC goes alone: what follows is not swallowed.
        .{ "a\x1b日b", "a日b" },
        .{ "line1\x1b\nline2", "line1\nline2" },
        .{ "x\x1b(\r\nz", "x\r\nz" },
        .{ "\x1b\x1b[31mred", "red" },
    };
    for (cases) |c| {
        const out = try stripControlSequences(testing.allocator, c[0]);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c[1], out);
        try testing.expect(std.unicode.utf8ValidateSlice(out));
    }
}
