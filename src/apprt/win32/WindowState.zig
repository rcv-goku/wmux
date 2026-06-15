//! Persisted top-level window geometry for the Win32 runtime.
//!
//! Stores the last window size, position, and maximized state so the
//! main window restores to where the user left it — like Windows
//! Terminal and most native Windows apps.
//!
//! ## Storage
//!
//! The state lives in a small human-readable `key=value` text file at
//! `%LOCALAPPDATA%\ghostty\window-state` (see `Window.savePlacement` /
//! `Window.restorePlacement` for the path resolution, which mirrors the
//! existing `update_check_at` convention). Example contents:
//!
//! ```
//! width=1024
//! height=768
//! x=100
//! y=80
//! maximized=false
//! ```
//!
//! Unknown keys are ignored and missing keys keep their defaults, so the
//! format can grow without breaking older/newer builds.
//!
//! ## Coordinate space / DPI
//!
//! The persisted rect is captured from `GetWindowPlacement`'s
//! `rcNormalPosition`, which is the window's *restored* (non-maximized)
//! rectangle. We store and restore raw physical pixels in **workarea
//! coordinates** (the space `GetWindowPlacement`/`SetWindowPlacement`
//! use). Under per-monitor-v2 DPI awareness these are physical pixels on
//! the monitor the window currently occupies.
//!
//! This is intentionally simple: we do NOT normalize to a DPI-independent
//! unit. The trade-off is that if the saved monitor's DPI differs from the
//! restore monitor's DPI, the restored window is sized in the old
//! monitor's pixels. In practice this is the same behavior Windows
//! Terminal had for a long time and is acceptable for a "remember my
//! window" feature; the clamp below still guarantees visibility.

const std = @import("std");

/// Persisted geometry. Plain data, no allocations — safe to copy.
pub const State = struct {
    width: i32,
    height: i32,
    x: i32,
    y: i32,
    maximized: bool,

    /// Minimum sensible window dimensions. A saved width/height below
    /// this (e.g. from a corrupt file or a degenerate minimized capture)
    /// is rejected by `validate`.
    pub const min_dim: i32 = 100;

    /// Serialize to the `key=value` text format. Writes into `buf` and
    /// returns the populated slice. The buffer must be large enough; 160
    /// bytes is always sufficient for five i32/bool lines.
    pub fn serialize(self: State, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf,
            \\width={d}
            \\height={d}
            \\x={d}
            \\y={d}
            \\maximized={s}
            \\
        , .{
            self.width,
            self.height,
            self.x,
            self.y,
            if (self.maximized) "true" else "false",
        });
    }

    /// Parse the `key=value` text format. Tolerant of a missing/corrupt
    /// file: a leading UTF-8 BOM is stripped (Notepad's "UTF-8 with BOM"
    /// would otherwise glue onto the first key and silently lose ALL
    /// state), unknown keys are skipped, malformed lines are skipped,
    /// and a partial parse returns null unless every required geometry
    /// field (width/height/x/y) was present. A malformed value for a
    /// known key never clobbers an earlier valid duplicate (the last
    /// VALID occurrence wins). `maximized` defaults to false when absent
    /// or unparseable.
    ///
    /// Returns null when the input cannot produce a usable, on-its-face
    /// valid State (see `validate`), so callers fall back to defaults.
    pub fn parse(text: []const u8) ?State {
        var width: ?i32 = null;
        var height: ?i32 = null;
        var x: ?i32 = null;
        var y: ?i32 = null;
        var maximized: bool = false;

        const bom = "\xEF\xBB\xBF";
        const body = if (std.mem.startsWith(u8, text, bom)) text[bom.len..] else text;
        var lines = std.mem.tokenizeAny(u8, body, "\r\n");
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (line.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");

            // `catch <field>` keeps the previous value (null or an
            // earlier valid duplicate) when this value is malformed:
            // garbage never poisons a field a valid line already set.
            if (std.mem.eql(u8, key, "width")) {
                width = std.fmt.parseInt(i32, val, 10) catch width;
            } else if (std.mem.eql(u8, key, "height")) {
                height = std.fmt.parseInt(i32, val, 10) catch height;
            } else if (std.mem.eql(u8, key, "x")) {
                x = std.fmt.parseInt(i32, val, 10) catch x;
            } else if (std.mem.eql(u8, key, "y")) {
                y = std.fmt.parseInt(i32, val, 10) catch y;
            } else if (std.mem.eql(u8, key, "maximized")) {
                if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1")) {
                    maximized = true;
                } else {
                    maximized = false;
                }
            }
            // Unknown keys: ignored for forward compatibility.
        }

        const s = State{
            .width = width orelse return null,
            .height = height orelse return null,
            .x = x orelse return null,
            .y = y orelse return null,
            .maximized = maximized,
        };
        if (!s.validate()) return null;
        return s;
    }

    /// Sanity-check the geometry independent of any monitor layout.
    /// Rejects non-positive or absurdly small/large dimensions that
    /// would produce an unusable window.
    pub fn validate(self: State) bool {
        if (self.width < min_dim or self.height < min_dim) return false;
        // Guard against a corrupt file claiming a multi-million-pixel
        // window; 32767 comfortably exceeds any real multi-monitor span.
        if (self.width > 32767 or self.height > 32767) return false;
        return true;
    }
};

/// A rectangle in physical pixels, expressed as origin + size (matching
/// how we store window geometry). Pure value type for the clamp logic.
pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn right(self: Rect) i32 {
        return self.x + self.width;
    }
    pub fn bottom(self: Rect) i32 {
        return self.y + self.height;
    }
};

/// Clamp a saved window rect so it is visible on the current virtual
/// screen (the bounding box of all monitors), given as `screen`.
///
/// Behavior:
///   * If the saved rect overlaps the virtual screen at all, it is
///     nudged so its top-left is on-screen and the title bar is
///     reachable, shrinking only if it is larger than the screen.
///   * If the saved rect is *fully* off-screen (e.g. the monitor it
///     lived on was unplugged), it falls back to centered on the
///     virtual screen at its saved size (clamped to fit).
///
/// Pure function: takes the saved rect and the virtual-screen rect,
/// returns the adjusted rect. No Win32 calls, fully unit-testable.
pub fn clampToVirtualScreen(saved: Rect, screen: Rect) Rect {
    // Never let a window be larger than the whole virtual screen.
    var w = @min(saved.width, screen.width);
    var h = @min(saved.height, screen.height);
    if (w < State.min_dim) w = @min(State.min_dim, screen.width);
    if (h < State.min_dim) h = @min(State.min_dim, screen.height);

    // Does the saved rect intersect the virtual screen at all?
    const intersects = saved.x < screen.right() and
        saved.right() > screen.x and
        saved.y < screen.bottom() and
        saved.bottom() > screen.y;

    if (!intersects) {
        // Fully off-screen → center on the virtual screen.
        return .{
            .x = screen.x + @divTrunc(screen.width - w, 2),
            .y = screen.y + @divTrunc(screen.height - h, 2),
            .width = w,
            .height = h,
        };
    }

    // Partially visible: clamp the top-left so the whole rect (now no
    // larger than the screen) sits inside the virtual screen. This keeps
    // the title bar reachable even if the saved position hung off an
    // edge.
    var nx = saved.x;
    var ny = saved.y;
    if (nx + w > screen.right()) nx = screen.right() - w;
    if (ny + h > screen.bottom()) ny = screen.bottom() - h;
    if (nx < screen.x) nx = screen.x;
    if (ny < screen.y) ny = screen.y;

    return .{ .x = nx, .y = ny, .width = w, .height = h };
}

test "winsize: serialize/parse round-trip" {
    const testing = std.testing;
    const in = State{ .width = 1024, .height = 768, .x = 100, .y = 80, .maximized = false };
    var buf: [256]u8 = undefined;
    const text = try in.serialize(&buf);
    const out = State.parse(text) orelse return error.ParseFailed;
    try testing.expectEqual(in.width, out.width);
    try testing.expectEqual(in.height, out.height);
    try testing.expectEqual(in.x, out.x);
    try testing.expectEqual(in.y, out.y);
    try testing.expectEqual(in.maximized, out.maximized);
}

test "winsize: serialize/parse round-trip maximized + negative coords" {
    const testing = std.testing;
    // Negative coords occur on secondary monitors left/above the primary.
    const in = State{ .width = 1920, .height = 1080, .x = -1920, .y = -200, .maximized = true };
    var buf: [256]u8 = undefined;
    const text = try in.serialize(&buf);
    const out = State.parse(text) orelse return error.ParseFailed;
    try testing.expectEqual(in.x, out.x);
    try testing.expectEqual(in.y, out.y);
    try testing.expect(out.maximized);
}

test "winsize: parse tolerates whitespace, unknown keys, and key reorder" {
    const testing = std.testing;
    const text =
        \\# a comment-ish line with no equals is skipped
        \\  maximized = true
        \\unknown_future_key=42
        \\height=600
        \\  width =  800
        \\x=10
        \\y=20
        \\
    ;
    const out = State.parse(text) orelse return error.ParseFailed;
    try testing.expectEqual(@as(i32, 800), out.width);
    try testing.expectEqual(@as(i32, 600), out.height);
    try testing.expectEqual(@as(i32, 10), out.x);
    try testing.expectEqual(@as(i32, 20), out.y);
    try testing.expect(out.maximized);
}

test "winsize: parse rejects corrupt / incomplete input → null" {
    const testing = std.testing;
    // Empty file.
    try testing.expect(State.parse("") == null);
    // Garbage bytes.
    try testing.expect(State.parse("\x00\xff not a config at all") == null);
    // Missing required field (no width).
    try testing.expect(State.parse("height=600\nx=1\ny=2\n") == null);
    // Non-numeric value for a required field.
    try testing.expect(State.parse("width=abc\nheight=600\nx=1\ny=2\n") == null);
    // Degenerate (too small) dimensions are rejected by validate.
    try testing.expect(State.parse("width=1\nheight=1\nx=0\ny=0\n") == null);
    // Absurdly large dimensions rejected.
    try testing.expect(State.parse("width=999999\nheight=999999\nx=0\ny=0\n") == null);
}

test "winsize: clamp leaves a fully-visible rect unchanged" {
    const testing = std.testing;
    const screen = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const saved = Rect{ .x = 100, .y = 80, .width = 1024, .height = 768 };
    const out = clampToVirtualScreen(saved, screen);
    try testing.expectEqual(saved.x, out.x);
    try testing.expectEqual(saved.y, out.y);
    try testing.expectEqual(saved.width, out.width);
    try testing.expectEqual(saved.height, out.height);
}

test "winsize: clamp nudges a partially off-screen rect back inside" {
    const testing = std.testing;
    const screen = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    // Hangs off the right and bottom edges.
    const saved = Rect{ .x = 1800, .y = 1000, .width = 800, .height = 600 };
    const out = clampToVirtualScreen(saved, screen);
    try testing.expect(out.x >= screen.x);
    try testing.expect(out.y >= screen.y);
    try testing.expect(out.right() <= screen.right());
    try testing.expect(out.bottom() <= screen.bottom());
    // Size preserved (it fits after the move).
    try testing.expectEqual(@as(i32, 800), out.width);
    try testing.expectEqual(@as(i32, 600), out.height);
    try testing.expectEqual(@as(i32, 1120), out.x); // 1920 - 800
    try testing.expectEqual(@as(i32, 480), out.y); // 1080 - 600
}

test "winsize: clamp centers a fully off-screen rect (monitor removed)" {
    const testing = std.testing;
    // Single monitor remains at origin; saved rect was on a now-removed
    // monitor far to the right.
    const screen = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const saved = Rect{ .x = 5000, .y = 200, .width = 800, .height = 600 };
    const out = clampToVirtualScreen(saved, screen);
    // Centered.
    try testing.expectEqual(@as(i32, (1920 - 800) / 2), out.x);
    try testing.expectEqual(@as(i32, (1080 - 600) / 2), out.y);
    try testing.expectEqual(@as(i32, 800), out.width);
    try testing.expectEqual(@as(i32, 600), out.height);
    // And it's on-screen.
    try testing.expect(out.x >= screen.x and out.right() <= screen.right());
}

test "winsize: clamp shrinks a rect larger than the virtual screen" {
    const testing = std.testing;
    const screen = Rect{ .x = 0, .y = 0, .width = 1280, .height = 720 };
    const saved = Rect{ .x = -200, .y = -100, .width = 4000, .height = 3000 };
    const out = clampToVirtualScreen(saved, screen);
    try testing.expectEqual(@as(i32, 1280), out.width);
    try testing.expectEqual(@as(i32, 720), out.height);
    try testing.expect(out.x >= screen.x);
    try testing.expect(out.y >= screen.y);
    try testing.expect(out.right() <= screen.right());
    try testing.expect(out.bottom() <= screen.bottom());
}

test "winsize: clamp respects a virtual screen with a negative origin" {
    const testing = std.testing;
    // Primary at origin, secondary monitor to the left (negative x).
    const screen = Rect{ .x = -1920, .y = 0, .width = 3840, .height = 1080 };
    const saved = Rect{ .x = -1800, .y = 100, .width = 1000, .height = 700 };
    const out = clampToVirtualScreen(saved, screen);
    // Already visible → unchanged.
    try testing.expectEqual(saved.x, out.x);
    try testing.expectEqual(saved.y, out.y);
}

test "winsize: parse duplicate keys last occurrence wins" {
    const testing = std.testing;
    const text =
        \\width=640
        \\height=480
        \\x=1
        \\y=2
        \\width=800
        \\maximized=true
        \\maximized=false
        \\
    ;
    const out = State.parse(text) orelse return error.ParseFailed;
    try testing.expectEqual(@as(i32, 800), out.width);
    try testing.expectEqual(@as(i32, 480), out.height);
    try testing.expect(!out.maximized);
}

test "winsize: parse duplicate key with malformed last value keeps the valid value" {
    const testing = std.testing;
    // A later malformed duplicate is IGNORED: it neither overwrites nor
    // poisons the earlier valid value, so the parse succeeds. (This used
    // to pin the opposite — the garbage duplicate nulled the field and
    // failed the whole parse.)
    const text =
        \\width=800
        \\height=600
        \\x=1
        \\y=2
        \\width=corrupt
        \\
    ;
    const out = State.parse(text) orelse return error.ParseFailed;
    try testing.expectEqual(@as(i32, 800), out.width);
    try testing.expectEqual(@as(i32, 600), out.height);
}

test "winsize: parse duplicate key garbage-then-valid takes the valid value" {
    const testing = std.testing;
    // The mirror case: garbage first is ignored, a later valid duplicate
    // sets the field normally (last VALID occurrence wins).
    const text =
        \\height=junk
        \\width=800
        \\height=600
        \\x=1
        \\y=2
        \\
    ;
    const out = State.parse(text) orelse return error.ParseFailed;
    try testing.expectEqual(@as(i32, 600), out.height);
    // Garbage-only (no valid duplicate anywhere) still fails the parse.
    try testing.expect(State.parse("width=junk\nheight=600\nx=1\ny=2\n") == null);
}

test "winsize: parse extreme numeric values" {
    const testing = std.testing;
    // i32 max parses fine but is rejected by validate (> 32767).
    try testing.expect(State.parse("width=2147483647\nheight=600\nx=0\ny=0\n") == null);
    // Overflowing i32 fails parseInt → field stays null → parse fails.
    try testing.expect(State.parse("width=99999999999999999999\nheight=600\nx=0\ny=0\n") == null);
    // x/y are NOT bounded by validate: extreme positions are accepted
    // as-is (clampToVirtualScreen handles them at restore time).
    const out = State.parse("width=800\nheight=600\nx=2147483647\ny=-2147483648\n") orelse
        return error.ParseFailed;
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), out.x);
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), out.y);
}

test "winsize: parse dimension boundaries at min_dim and 32767" {
    const testing = std.testing;
    // Exactly min_dim is accepted.
    const at_min = State.parse("width=100\nheight=100\nx=0\ny=0\n") orelse
        return error.ParseFailed;
    try testing.expectEqual(@as(i32, 100), at_min.width);
    // One below min_dim is rejected.
    try testing.expect(State.parse("width=99\nheight=100\nx=0\ny=0\n") == null);
    try testing.expect(State.parse("width=100\nheight=99\nx=0\ny=0\n") == null);
    // Negative dimensions are rejected.
    try testing.expect(State.parse("width=-500\nheight=600\nx=0\ny=0\n") == null);
    try testing.expect(State.parse("width=800\nheight=-1\nx=0\ny=0\n") == null);
    // Exactly 32767 is accepted; one above is rejected.
    const at_max = State.parse("width=32767\nheight=32767\nx=0\ny=0\n") orelse
        return error.ParseFailed;
    try testing.expectEqual(@as(i32, 32767), at_max.height);
    try testing.expect(State.parse("width=32768\nheight=600\nx=0\ny=0\n") == null);
    try testing.expect(State.parse("width=800\nheight=32768\nx=0\ny=0\n") == null);
}

test "winsize: parse missing any single required key returns null" {
    const testing = std.testing;
    try testing.expect(State.parse("width=800\nheight=600\nx=1\n") == null); // no y
    try testing.expect(State.parse("width=800\nheight=600\ny=2\n") == null); // no x
    try testing.expect(State.parse("width=800\nx=1\ny=2\n") == null); // no height
    try testing.expect(State.parse("height=600\nx=1\ny=2\n") == null); // no width
}

test "winsize: parse CRLF and lone-CR line endings" {
    const testing = std.testing;
    // CRLF (a user editing the file in Notepad).
    const crlf = State.parse("width=800\r\nheight=600\r\nx=10\r\ny=20\r\nmaximized=1\r\n") orelse
        return error.ParseFailed;
    try testing.expectEqual(@as(i32, 800), crlf.width);
    try testing.expectEqual(@as(i32, 20), crlf.y);
    try testing.expect(crlf.maximized);
    // Lone CR separators also tokenize (tokenizeAny on "\r\n").
    const cr = State.parse("width=800\rheight=600\rx=10\ry=20\r") orelse
        return error.ParseFailed;
    try testing.expectEqual(@as(i32, 600), cr.height);
    // Mixed endings with blank lines.
    const mixed = State.parse("width=800\n\r\nheight=600\rx=10\r\n\ny=20") orelse
        return error.ParseFailed;
    try testing.expectEqual(@as(i32, 10), mixed.x);
}

test "winsize: parse trailing garbage and same-line junk" {
    const testing = std.testing;
    // Garbage lines after valid content are ignored (no '=' → skipped;
    // unknown key with '=' → ignored), including a value containing '='.
    const out = State.parse("width=800\nheight=600\nx=1\ny=2\n\xff\xfe binary junk\ntrailing=garbage=here\n") orelse
        return error.ParseFailed;
    try testing.expectEqual(@as(i32, 800), out.width);
    // Junk after the value on the SAME line poisons that field.
    try testing.expect(State.parse("width=800 junk\nheight=600\nx=1\ny=2\n") == null);
    // A second '=' inside a required value poisons it too.
    try testing.expect(State.parse("width=800=600\nheight=600\nx=1\ny=2\n") == null);
}

test "winsize: parse unicode junk" {
    const testing = std.testing;
    // Unicode lookalike key ('í') is an unknown key → required width missing.
    try testing.expect(State.parse("w\xc3\xaddth=800\nheight=600\nx=1\ny=2\n") == null);
    // Fullwidth digits are not ASCII digits → parseInt fails.
    try testing.expect(State.parse("width=\xef\xbc\x98\xef\xbc\x90\xef\xbc\x90\nheight=600\nx=1\ny=2\n") == null);
    // A leading UTF-8 BOM is stripped before parsing, so the first key
    // is recognized. (This used to pin the opposite — the BOM glued onto
    // the first key and the whole parse failed.)
    try testing.expect(State.parse("\xef\xbb\xbfwidth=800\nheight=600\nx=1\ny=2\n") != null);
    // A BOM anywhere else is still junk: it glues onto that line's key.
    try testing.expect(State.parse("\xef\xbb\xbf\xef\xbb\xbfwidth=800\nheight=600\nx=1\ny=2\n") == null);
    // Emoji garbage on separate lines does not disturb valid keys.
    const out = State.parse("\xf0\x9f\xa6\x80\xf0\x9f\xa6\x80\nwidth=800\nheight=600\nx=1\ny=2\n\xf0\x9f\x92\xa5=42\n") orelse
        return error.ParseFailed;
    try testing.expectEqual(@as(i32, 800), out.width);
}

test "winsize: parse BOM-prefixed valid file (Notepad UTF-8 with BOM)" {
    const testing = std.testing;
    // Notepad's "UTF-8 with BOM" encoding prepends EF BB BF; the state
    // file must survive a user editing it there. CRLF endings included,
    // since that is what Notepad writes.
    const out = State.parse("\xef\xbb\xbfwidth=1024\r\nheight=768\r\nx=100\r\ny=80\r\nmaximized=true\r\n") orelse
        return error.ParseFailed;
    try testing.expectEqual(@as(i32, 1024), out.width);
    try testing.expectEqual(@as(i32, 768), out.height);
    try testing.expectEqual(@as(i32, 100), out.x);
    try testing.expectEqual(@as(i32, 80), out.y);
    try testing.expect(out.maximized);
    // A BOM alone is still an empty file.
    try testing.expect(State.parse("\xef\xbb\xbf") == null);
}

test "winsize: parse maximized value variants" {
    const testing = std.testing;
    const base = "width=800\nheight=600\nx=1\ny=2\n";
    const cases = [_]struct { line: []const u8, want: bool }{
        .{ .line = "maximized=true", .want = true },
        .{ .line = "maximized=1", .want = true },
        .{ .line = "maximized=TRUE", .want = false }, // case-sensitive
        .{ .line = "maximized=yes", .want = false },
        .{ .line = "maximized=0", .want = false },
        .{ .line = "maximized=", .want = false },
        .{ .line = "maximized = true ", .want = true }, // whitespace trimmed
    };
    inline for (cases) |case| {
        const out = State.parse(base ++ case.line ++ "\n") orelse return error.ParseFailed;
        try testing.expectEqual(case.want, out.maximized);
    }
}

test "winsize: parse numeric quirks (digit separator, leading plus)" {
    const testing = std.testing;
    // Pins std.fmt.parseInt tolerance inherited by the format: Zig-style
    // '_' digit separators and an explicit '+' sign are accepted.
    const out = State.parse("width=1_024\nheight=+768\nx=+0\ny=-0\n") orelse
        return error.ParseFailed;
    try testing.expectEqual(@as(i32, 1024), out.width);
    try testing.expectEqual(@as(i32, 768), out.height);
    try testing.expectEqual(@as(i32, 0), out.x);
    try testing.expectEqual(@as(i32, 0), out.y);
}

test "winsize: clamp keeps rects flush at each screen edge unchanged" {
    const testing = std.testing;
    const screen = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const cases = [_]Rect{
        .{ .x = 0, .y = 100, .width = 800, .height = 600 }, // left flush
        .{ .x = 100, .y = 0, .width = 800, .height = 600 }, // top flush
        .{ .x = 1120, .y = 100, .width = 800, .height = 600 }, // right flush
        .{ .x = 100, .y = 480, .width = 800, .height = 600 }, // bottom flush
        .{ .x = 1120, .y = 480, .width = 800, .height = 600 }, // corner flush
        .{ .x = 0, .y = 0, .width = 1920, .height = 1080 }, // fills screen
    };
    for (cases) |saved| {
        const out = clampToVirtualScreen(saved, screen);
        try testing.expectEqual(saved.x, out.x);
        try testing.expectEqual(saved.y, out.y);
        try testing.expectEqual(saved.width, out.width);
        try testing.expectEqual(saved.height, out.height);
    }
}

test "winsize: clamp nudges a 1px overhang in each direction" {
    const testing = std.testing;
    const screen = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const cases = [_]struct { saved: Rect, want_x: i32, want_y: i32 }{
        // 1px off the left → snapped to x=0.
        .{ .saved = .{ .x = -1, .y = 100, .width = 800, .height = 600 }, .want_x = 0, .want_y = 100 },
        // 1px off the top → snapped to y=0.
        .{ .saved = .{ .x = 100, .y = -1, .width = 800, .height = 600 }, .want_x = 100, .want_y = 0 },
        // 1px off the right → snapped to right-flush.
        .{ .saved = .{ .x = 1121, .y = 100, .width = 800, .height = 600 }, .want_x = 1120, .want_y = 100 },
        // 1px off the bottom → snapped to bottom-flush.
        .{ .saved = .{ .x = 100, .y = 481, .width = 800, .height = 600 }, .want_x = 100, .want_y = 480 },
    };
    for (cases) |case| {
        const out = clampToVirtualScreen(case.saved, screen);
        try testing.expectEqual(case.want_x, out.x);
        try testing.expectEqual(case.want_y, out.y);
        // Size always preserved here (rect fits the screen).
        try testing.expectEqual(@as(i32, 800), out.width);
        try testing.expectEqual(@as(i32, 600), out.height);
    }
}

test "winsize: clamp boundary between partially visible and fully off-screen" {
    const testing = std.testing;
    const screen = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };

    // Left edge exactly at screen.right() → zero overlap → centered.
    {
        const out = clampToVirtualScreen(
            .{ .x = 1920, .y = 100, .width = 800, .height = 600 },
            screen,
        );
        try testing.expectEqual(@as(i32, 560), out.x); // (1920-800)/2
        try testing.expectEqual(@as(i32, 240), out.y); // (1080-600)/2
    }
    // One pixel of overlap on the right → nudged, not centered.
    {
        const out = clampToVirtualScreen(
            .{ .x = 1919, .y = 100, .width = 800, .height = 600 },
            screen,
        );
        try testing.expectEqual(@as(i32, 1120), out.x);
        try testing.expectEqual(@as(i32, 100), out.y);
    }
    // Right edge exactly at screen.x → zero overlap → centered.
    {
        const out = clampToVirtualScreen(
            .{ .x = -800, .y = 100, .width = 800, .height = 600 },
            screen,
        );
        try testing.expectEqual(@as(i32, 560), out.x);
        try testing.expectEqual(@as(i32, 240), out.y);
    }
    // One pixel of overlap on the left → snapped to x=0.
    {
        const out = clampToVirtualScreen(
            .{ .x = -799, .y = 100, .width = 800, .height = 600 },
            screen,
        );
        try testing.expectEqual(@as(i32, 0), out.x);
        try testing.expectEqual(@as(i32, 100), out.y);
    }
    // Top edge exactly at screen.bottom() → zero overlap → centered.
    {
        const out = clampToVirtualScreen(
            .{ .x = 100, .y = 1080, .width = 800, .height = 600 },
            screen,
        );
        try testing.expectEqual(@as(i32, 560), out.x);
        try testing.expectEqual(@as(i32, 240), out.y);
    }
}

test "winsize: clamp degenerate zero- and negative-size rects grow to min_dim" {
    const testing = std.testing;
    const screen = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };

    // Zero-size rect with an on-screen origin: still "intersects" by the
    // point-overlap rule? No — a zero-size rect at (500,500) has
    // right()==x, but x < screen.right() and right() > screen.x both
    // hold, so it intersects and keeps its origin, growing to min_dim.
    {
        const out = clampToVirtualScreen(
            .{ .x = 500, .y = 500, .width = 0, .height = 0 },
            screen,
        );
        try testing.expectEqual(@as(i32, 500), out.x);
        try testing.expectEqual(@as(i32, 500), out.y);
        try testing.expectEqual(State.min_dim, out.width);
        try testing.expectEqual(State.min_dim, out.height);
    }
    // Zero-size rect exactly at the screen origin: right()==screen.x so
    // the overlap test fails → treated as fully off-screen → centered.
    {
        const out = clampToVirtualScreen(
            .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            screen,
        );
        try testing.expectEqual(@as(i32, 910), out.x); // (1920-100)/2
        try testing.expectEqual(@as(i32, 490), out.y); // (1080-100)/2
        try testing.expectEqual(State.min_dim, out.width);
        try testing.expectEqual(State.min_dim, out.height);
    }
    // Negative size is normalized up to min_dim as well.
    {
        const out = clampToVirtualScreen(
            .{ .x = 500, .y = 500, .width = -50, .height = -50 },
            screen,
        );
        try testing.expectEqual(@as(i32, 500), out.x);
        try testing.expectEqual(@as(i32, 500), out.y);
        try testing.expectEqual(State.min_dim, out.width);
        try testing.expectEqual(State.min_dim, out.height);
    }
}

test "winsize: clamp full matrix on a negative-origin virtual screen" {
    const testing = std.testing;
    // Secondary monitors left of and above the primary: the virtual
    // screen origin is (-1920,-1080), spanning to (1920,1080).
    const screen = Rect{ .x = -1920, .y = -1080, .width = 3840, .height = 2160 };

    // Fully visible at negative coordinates → unchanged.
    {
        const saved = Rect{ .x = -1800, .y = -1000, .width = 800, .height = 600 };
        const out = clampToVirtualScreen(saved, screen);
        try testing.expectEqual(saved.x, out.x);
        try testing.expectEqual(saved.y, out.y);
    }
    // 1px off the (negative) left edge → snapped to screen.x.
    {
        const out = clampToVirtualScreen(
            .{ .x = -1921, .y = 100, .width = 800, .height = 600 },
            screen,
        );
        try testing.expectEqual(@as(i32, -1920), out.x);
        try testing.expectEqual(@as(i32, 100), out.y);
    }
    // Fully off the left → centered on the (negative-origin) screen.
    {
        const out = clampToVirtualScreen(
            .{ .x = -2721, .y = 100, .width = 800, .height = 600 },
            screen,
        );
        try testing.expectEqual(@as(i32, -400), out.x); // -1920 + (3840-800)/2
        try testing.expectEqual(@as(i32, -300), out.y); // -1080 + (2160-600)/2
    }
}

test "winsize: clamp oversized rect fully off-screen centers at screen size" {
    const testing = std.testing;
    const screen = Rect{ .x = 0, .y = 0, .width = 1280, .height = 720 };
    const out = clampToVirtualScreen(
        .{ .x = 5000, .y = 5000, .width = 4000, .height = 3000 },
        screen,
    );
    // Shrunk to the screen and centered → exactly fills it.
    try testing.expectEqual(@as(i32, 0), out.x);
    try testing.expectEqual(@as(i32, 0), out.y);
    try testing.expectEqual(@as(i32, 1280), out.width);
    try testing.expectEqual(@as(i32, 720), out.height);
}

test "winsize: clamp rect larger than the screen on one axis only" {
    const testing = std.testing;
    const screen = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    // Too wide: width clamped to screen, x snapped to 0, y untouched.
    {
        const out = clampToVirtualScreen(
            .{ .x = 100, .y = 100, .width = 4000, .height = 500 },
            screen,
        );
        try testing.expectEqual(@as(i32, 0), out.x);
        try testing.expectEqual(@as(i32, 100), out.y);
        try testing.expectEqual(@as(i32, 1920), out.width);
        try testing.expectEqual(@as(i32, 500), out.height);
    }
    // Too tall: height clamped to screen, y snapped to 0, x untouched.
    {
        const out = clampToVirtualScreen(
            .{ .x = 100, .y = 100, .width = 500, .height = 4000 },
            screen,
        );
        try testing.expectEqual(@as(i32, 100), out.x);
        try testing.expectEqual(@as(i32, 0), out.y);
        try testing.expectEqual(@as(i32, 500), out.width);
        try testing.expectEqual(@as(i32, 1080), out.height);
    }
}

test "winsize: clamp virtual screen smaller than min_dim" {
    const testing = std.testing;
    // Pathological screen smaller than the minimum window size: the
    // result can never exceed the screen, so min_dim loses.
    const screen = Rect{ .x = 0, .y = 0, .width = 50, .height = 50 };
    // Fully off-screen → centered, sized to the whole tiny screen.
    {
        const out = clampToVirtualScreen(
            .{ .x = 200, .y = 200, .width = 800, .height = 600 },
            screen,
        );
        try testing.expectEqual(@as(i32, 0), out.x);
        try testing.expectEqual(@as(i32, 0), out.y);
        try testing.expectEqual(@as(i32, 50), out.width);
        try testing.expectEqual(@as(i32, 50), out.height);
    }
    // Overlapping → still clamped to fill the tiny screen.
    {
        const out = clampToVirtualScreen(
            .{ .x = 10, .y = 10, .width = 800, .height = 600 },
            screen,
        );
        try testing.expectEqual(@as(i32, 0), out.x);
        try testing.expectEqual(@as(i32, 0), out.y);
        try testing.expectEqual(@as(i32, 50), out.width);
        try testing.expectEqual(@as(i32, 50), out.height);
    }
    // A small visible rect is grown toward min_dim, capped at the
    // screen, and re-clamped into it.
    {
        const out = clampToVirtualScreen(
            .{ .x = 10, .y = 10, .width = 20, .height = 20 },
            screen,
        );
        try testing.expectEqual(@as(i32, 0), out.x);
        try testing.expectEqual(@as(i32, 0), out.y);
        try testing.expectEqual(@as(i32, 50), out.width);
        try testing.expectEqual(@as(i32, 50), out.height);
    }
}
