//! Persistence limits of the session snapshot (ADR-9.2, cmux
//! SessionPersistencePolicy): object caps per snapshot, the scrollback tail
//! cap per terminal, and the browser history and text caps wmux adds so a
//! hostile or runaway file stays bounded (G6, G7: only persistence is
//! capped, never the live model).

const std = @import("std");
const schema = @import("schema_v3.zig");

const Allocator = std.mem.Allocator;

/// cmux: windows per snapshot.
pub const max_windows: usize = 12;
/// cmux: workspaces per window.
pub const max_workspaces_per_window: usize = 128;
/// cmux: panels (surfaces, i.e. tabs) per workspace.
pub const max_surfaces_per_workspace: usize = 512;
/// cmux: scrollback lines kept per terminal (tail).
pub const max_scrollback_lines: usize = 4000;
/// cmux: scrollback characters kept per terminal (tail). Counted in
/// Unicode code points.
pub const max_scrollback_chars: usize = 400_000;

/// wmux: entries kept on each side of a browser tab's back/forward list
/// (the entries nearest the current page are kept).
pub const max_browser_history: usize = 100;
/// wmux: byte cap of any single text field read from a session file.
pub const max_text_bytes: usize = 64 * 1024;
/// wmux: session files larger than this are treated as corrupt.
pub const max_file_bytes: usize = 32 * 1024 * 1024;
/// wmux: split levels kept in a layout; deeper subtrees are dropped so
/// recursion and the JSON writer's nesting limit stay bounded.
pub const max_layout_depth: usize = 64;
/// wmux: `[`/`{` nesting levels accepted in a session file; deeper files
/// are corrupt. A written file stays well below it (a layout of
/// `max_layout_depth` splits reaches about 135 levels). The bound keeps the
/// parse stack small and every value the writer passes through untouched
/// (`ext`, web panel state, unknown panels) under `std.json.Stringify`'s
/// 256-level nesting check.
pub const max_json_depth: usize = 200;

pub const min_split_ratio: f64 = 0.01;
pub const max_split_ratio: f64 = 0.99;
pub const min_font_size: f64 = 1.0;
pub const max_font_size: f64 = 512.0;
/// WebView2 `ZoomFactor` range.
pub const min_browser_zoom: f64 = 0.25;
pub const max_browser_zoom: f64 = 5.0;

/// Longest prefix of `s` that is at most `max` bytes and does not split a
/// UTF-8 sequence. Invalid bytes are treated as single-byte units.
pub fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    // Back up over continuation bytes to the lead byte, then keep that
    // sequence only if it fits entirely.
    while (end > 0 and isContinuation(s[end])) end -= 1;
    return s[0..end];
}

fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// True when the JSON text nests `[`/`{` deeper than `max` (brackets inside
/// strings do not count). One linear pass without allocation, so a hostile
/// file is refused before `std.json` builds its parse stack. Malformed text
/// is left for the parser to reject.
pub fn exceedsJsonDepth(bytes: []const u8, max: usize) bool {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (bytes) |c| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '[', '{' => {
                depth += 1;
                if (depth > max) return true;
            },
            ']', '}' => depth -|= 1,
            else => {},
        }
    }
    return false;
}

/// The tail of a terminal history that fits the cmux caps: at most
/// `max_scrollback_lines` lines and `max_scrollback_chars` code points.
/// When the char cap cuts into a line, the partial line is dropped too
/// (so the tail never begins mid-line or mid escape sequence) unless the
/// whole tail is that one line. A trailing newline does not open a line.
pub fn tailScrollback(text: []const u8) []const u8 {
    return tailScrollbackCaps(text, max_scrollback_lines, max_scrollback_chars);
}

pub fn tailScrollbackCaps(text: []const u8, max_lines: usize, max_chars: usize) []const u8 {
    if (max_lines == 0 or max_chars == 0) return text[text.len..];
    // Ignore one trailing newline when counting lines.
    const body_end = if (text.len > 0 and text[text.len - 1] == '\n') text.len - 1 else text.len;
    var start: usize = 0;
    var newlines: usize = 0;
    var chars: usize = 0;
    // Start of the most recently counted code point.
    var last_lead: usize = text.len;
    var i: usize = text.len;
    var cut_by_chars = false;
    while (i > 0) : (i -= 1) {
        const c = text[i - 1];
        if (i - 1 < body_end and c == '\n') {
            newlines += 1;
            if (newlines == max_lines) {
                start = i;
                break;
            }
        }
        if (isContinuation(c)) continue;
        if (chars == max_chars) {
            start = last_lead;
            cut_by_chars = true;
            break;
        }
        chars += 1;
        last_lead = i - 1;
    }
    if (cut_by_chars and text[start - 1] != '\n') {
        // Skip to after the next newline when one exists in the tail.
        if (std.mem.indexOfScalarPos(u8, text[0..body_end], start, '\n')) |nl| start = nl + 1;
    }
    return text[start..];
}

/// Caps a back/forward pair to `max_browser_history` entries per side,
/// keeping the entries nearest the current page. Returns the capped slices.
pub fn capHistory(back: []const []const u8, forward: []const []const u8) struct { back: []const []const u8, forward: []const []const u8 } {
    const b = if (back.len > max_browser_history) back[back.len - max_browser_history ..] else back;
    const f = if (forward.len > max_browser_history) forward[0..max_browser_history] else forward;
    return .{ .back = b, .forward = f };
}

pub const Report = struct {
    dropped_windows: usize = 0,
    dropped_workspaces: usize = 0,
    dropped_surfaces: usize = 0,
    trimmed_history_entries: usize = 0,

    pub fn any(self: Report) bool {
        return self.dropped_windows + self.dropped_workspaces + self.dropped_surfaces + self.trimmed_history_entries > 0;
    }
};

/// Enforces the snapshot caps in place: the first `max_windows` windows,
/// the first `max_workspaces_per_window` workspaces of each, and the first
/// `max_surfaces_per_workspace` tabs of each workspace in pane order (panes
/// left empty disappear and the layout is repaired by `schema.normalize`).
/// Browser history is capped per tab.
pub fn apply(arena: Allocator, s: *schema.Session) !Report {
    var r: Report = .{};
    if (s.windows.len > max_windows) {
        r.dropped_windows = s.windows.len - max_windows;
        s.windows = s.windows[0..max_windows];
    }
    var touched = false;
    for (s.windows) |*w| {
        if (w.workspaces.len > max_workspaces_per_window) {
            r.dropped_workspaces += w.workspaces.len - max_workspaces_per_window;
            w.workspaces = w.workspaces[0..max_workspaces_per_window];
            touched = true;
        }
        for (w.workspaces) |*ws| {
            var budget: usize = max_surfaces_per_workspace;
            for (ws.panes) |*p| {
                if (p.tabs.len > budget) {
                    r.dropped_surfaces += p.tabs.len - budget;
                    p.tabs = p.tabs[0..budget];
                    touched = true;
                }
                budget -= p.tabs.len;
                for (p.tabs) |*t| switch (t.panel) {
                    .browser => |*b| {
                        const capped = capHistory(b.back, b.forward);
                        r.trimmed_history_entries += (b.back.len - capped.back.len) + (b.forward.len - capped.forward.len);
                        b.back = capped.back;
                        b.forward = capped.forward;
                    },
                    else => {},
                };
            }
        }
    }
    if (touched) try schema.normalize(arena, s);
    return r;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "unit: session: limits match cmux SessionPersistencePolicy" {
    try testing.expectEqual(@as(usize, 12), max_windows);
    try testing.expectEqual(@as(usize, 128), max_workspaces_per_window);
    try testing.expectEqual(@as(usize, 512), max_surfaces_per_workspace);
    try testing.expectEqual(@as(usize, 4000), max_scrollback_lines);
    try testing.expectEqual(@as(usize, 400_000), max_scrollback_chars);
}

test "unit: session: truncateUtf8 never splits a code point" {
    try testing.expectEqualStrings("", truncateUtf8("", 0));
    try testing.expectEqualStrings("abc", truncateUtf8("abc", 10));
    try testing.expectEqualStrings("ab", truncateUtf8("abc", 2));
    try testing.expectEqualStrings("a", truncateUtf8("aé", 2)); // é = 2 bytes
    try testing.expectEqualStrings("aé", truncateUtf8("aé", 3));
    try testing.expectEqualStrings("", truncateUtf8("😀", 3)); // 4 bytes
    try testing.expectEqualStrings("😀", truncateUtf8("😀x", 4));
    try testing.expectEqualStrings("", truncateUtf8("abc", 0));
}

test "unit: session: JSON nesting depth check ignores brackets in strings" {
    try testing.expect(!exceedsJsonDepth("", 0));
    try testing.expect(!exceedsJsonDepth("3", 0));
    try testing.expect(exceedsJsonDepth("[]", 0));
    try testing.expect(!exceedsJsonDepth("[]", 1));
    try testing.expect(!exceedsJsonDepth("{\"a\":[1,{}],\"b\":{}}", 3));
    try testing.expect(exceedsJsonDepth("{\"a\":[1,{}],\"b\":{}}", 2));
    // Brackets in strings, escaped quotes and escaped backslashes.
    try testing.expect(!exceedsJsonDepth("[\"[[[{{{\"]", 1));
    try testing.expect(!exceedsJsonDepth("[\"\\\"[[[\"]", 1));
    try testing.expect(exceedsJsonDepth("[\"\\\\\",[[]]]", 2));
    // Unbalanced or truncated text never underflows.
    try testing.expect(!exceedsJsonDepth("]]]}}}[", 1));
    try testing.expect(exceedsJsonDepth("[[[", 2));

    // A huge flat document is fine; one nesting level too many is not.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    for (0..max_json_depth) |_| try aw.writer.writeAll("[");
    for (0..max_json_depth) |_| try aw.writer.writeAll("]");
    try testing.expect(!exceedsJsonDepth(aw.written(), max_json_depth));
    try testing.expect(exceedsJsonDepth(aw.written(), max_json_depth - 1));
}

test "unit: session: scrollback tail keeps the newest lines" {
    try testing.expectEqualStrings("", tailScrollback(""));
    try testing.expectEqualStrings("b\nc", tailScrollbackCaps("a\nb\nc", 2, 100));
    try testing.expectEqualStrings("b\nc\n", tailScrollbackCaps("a\nb\nc\n", 2, 100));
    try testing.expectEqualStrings("a\nb\nc\n", tailScrollbackCaps("a\nb\nc\n", 3, 100));
    try testing.expectEqualStrings("c", tailScrollbackCaps("a\nb\nc", 1, 100));
    try testing.expectEqualStrings("\n", tailScrollbackCaps("a\n\n", 1, 100));
    try testing.expectEqualStrings("", tailScrollbackCaps("abc", 0, 100));

    // 5000 numbered lines → the last 4000.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    for (1..5001) |i| try aw.writer.print("{d}\r\n", .{i});
    const tail = tailScrollback(aw.written());
    try testing.expect(std.mem.startsWith(u8, tail, "1001\r\n"));
    try testing.expect(std.mem.endsWith(u8, tail, "5000\r\n"));
    try testing.expectEqual(@as(usize, 4000), std.mem.count(u8, tail, "\n"));
}

test "unit: session: scrollback tail honours the character cap" {
    // Char cap cuts mid-line: the partial line is dropped.
    try testing.expectEqualStrings("ccc\nddd", tailScrollbackCaps("aaa\nbbb\nccc\nddd", 100, 9));
    // Cut exactly at a line start keeps that line.
    try testing.expectEqualStrings("ccc\nddd", tailScrollbackCaps("aaa\nbbb\nccc\nddd", 100, 7));
    // One huge line: keep the code-point tail.
    try testing.expectEqualStrings("éèà", tailScrollbackCaps("abcéèà", 100, 3));
    try testing.expectEqualStrings("😀😀", tailScrollbackCaps("😀😀😀", 100, 2));
    try testing.expect(std.unicode.utf8ValidateSlice(tailScrollbackCaps("ü😀ü😀", 100, 3)));

    // 2 MB of one-line text → exactly 400k code points of UTF-8.
    const big = try testing.allocator.alloc(u8, 2 * 500_000);
    defer testing.allocator.free(big);
    var i: usize = 0;
    while (i < big.len) : (i += 2) {
        big[i] = 0xC3;
        big[i + 1] = 0xA9; // é
    }
    const t = tailScrollback(big);
    try testing.expectEqual(max_scrollback_chars, std.unicode.utf8CountCodepoints(t) catch unreachable);
}

test "unit: session: browser history keeps entries nearest the page" {
    var back: [150][]const u8 = undefined;
    var fwd: [150][]const u8 = undefined;
    for (&back, 0..) |*b, i| b.* = if (i == 149) "newest-back" else if (i == 50) "first-kept-back" else "b";
    for (&fwd, 0..) |*f, i| f.* = if (i == 0) "nearest-forward" else if (i == 99) "last-kept-forward" else "f";
    const c = capHistory(&back, &fwd);
    try testing.expectEqual(max_browser_history, c.back.len);
    try testing.expectEqual(max_browser_history, c.forward.len);
    try testing.expectEqualStrings("first-kept-back", c.back[0]);
    try testing.expectEqualStrings("newest-back", c.back[99]);
    try testing.expectEqualStrings("nearest-forward", c.forward[0]);
    try testing.expectEqualStrings("last-kept-forward", c.forward[99]);
    const small = capHistory(back[0..3], fwd[0..0]);
    try testing.expectEqual(@as(usize, 3), small.back.len);
}

test "unit: session: apply enforces window, workspace and surface caps" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(7);
    const mint = struct {
        fn f(a: Allocator, r: std.Random) ![]const u8 {
            var buf: [36]u8 = undefined;
            schema.mintUuid(r, &buf);
            return a.dupe(u8, &buf);
        }
    }.f;

    const windows = try arena.alloc(schema.Window, max_windows + 3);
    for (windows) |*w| w.* = .{ .id = try mint(arena, prng.random()) };
    const wss = try arena.alloc(schema.Workspace, max_workspaces_per_window + 2);
    for (wss) |*ws| ws.* = .{ .id = try mint(arena, prng.random()) };
    // Workspace 0: two panes of 300 tabs each → 88 tabs and nothing of
    // pane 2 beyond the cap... pane 3 vanishes entirely.
    const panes = try arena.alloc(schema.Pane, 3);
    for (panes) |*p| {
        const tabs = try arena.alloc(schema.Tab, 300);
        for (tabs) |*t| t.* = .{ .id = try mint(arena, prng.random()) };
        p.* = .{ .id = try mint(arena, prng.random()), .tabs = tabs };
    }
    const back = try arena.alloc([]const u8, 120);
    for (back) |*b| b.* = "https://x.example/";
    panes[0].tabs[0].panel = .{ .browser = .{ .url = "https://x.example/", .back = back } };
    wss[0].panes = panes;
    wss[0].focused_pane = panes[2].id;
    windows[0].workspaces = wss;
    windows[0].selected_workspace = wss[wss.len - 1].id;
    var s: schema.Session = .{ .windows = windows };
    try schema.normalize(arena, &s);

    const r = try apply(arena, &s);
    try testing.expect(r.any());
    try testing.expectEqual(@as(usize, 3), r.dropped_windows);
    try testing.expectEqual(@as(usize, 2), r.dropped_workspaces);
    try testing.expectEqual(@as(usize, 900 - 512), r.dropped_surfaces);
    try testing.expectEqual(@as(usize, 20), r.trimmed_history_entries);
    try testing.expectEqual(max_windows, s.windows.len);
    const w = s.windows[0];
    try testing.expectEqual(max_workspaces_per_window, w.workspaces.len);
    try testing.expect(w.selected_workspace == null);
    const ws = w.workspaces[0];
    try testing.expectEqual(@as(usize, 2), ws.panes.len);
    try testing.expectEqual(@as(usize, 212), ws.panes[1].tabs.len);
    try testing.expect(ws.focused_pane == null);
    try testing.expect(!schema.layoutContains(ws.layout.?, panes[2].id.?));
    try testing.expect(schema.layoutContains(ws.layout.?, panes[1].id.?));
    // Within limits: nothing changes.
    const again = try apply(arena, &s);
    try testing.expect(!again.any());
}
