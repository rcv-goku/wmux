//! Shortcut stroke grammar, parsing and matching (ADR-8.3).
//!
//! A stroke is a modifier set plus one key ("ctrl+shift+]"); a trigger is one
//! stroke or a two-stroke chord ("ctrl+b c"). Letters match by virtual key
//! (layout-aware mnemonics); digits and punctuation match by US scan-code
//! position so AZERTY digits and ISO brackets behave deterministically.
//! Also hosts the pure terminal-safety tier classifier (ADR-8.4) and the
//! macOS stroke translation rules used for `cmux.json` (ADR-8.6).

const std = @import("std");

pub const Dialect = enum {
    /// `wmux.json`: literal Windows strokes; `cmd` is rejected.
    windows,
    /// `cmux.json`: macOS strokes; `cmd`/`opt` and the ⌘⇧⌥⌃ glyphs accepted.
    mac,
    /// Human-readable hint text ("Ctrl+Shift+PgUp"); output only.
    display,
};

pub const Mods = packed struct(u8) {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    win: bool = false,
    cmd: bool = false,
    _pad: u3 = 0,

    pub fn eql(a: Mods, b: Mods) bool {
        return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
    }

    pub fn isEmpty(m: Mods) bool {
        return @as(u8, @bitCast(m)) == 0;
    }

    pub fn only(m: Mods, want: Mods) bool {
        return m.eql(want);
    }
};

/// Every bindable key. Field names are the canonical spelling.
pub const Key = enum(u8) {
    // zig fmt: off
    a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z,
    @"0", @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9",
    @",", @".", @"/", @";", @"'", @"[", @"]", @"\\", @"-", @"=", @"`",
    enter, tab, space, escape, backspace, delete, insert, home, end, pgup, pgdn,
    up, down, left, right,
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24,
    mouse4, mouse5,
    // zig fmt: on

    pub const Kind = enum { letter, digit, punct, named };

    pub fn kind(k: Key) Kind {
        const v = @intFromEnum(k);
        if (v <= @intFromEnum(Key.z)) return .letter;
        if (v <= @intFromEnum(Key.@"9")) return .digit;
        if (v <= @intFromEnum(Key.@"`")) return .punct;
        return .named;
    }

    pub fn name(k: Key) []const u8 {
        return @tagName(k);
    }

    /// Digit value for digit keys.
    pub fn digit(k: Key) ?u8 {
        if (k.kind() != .digit) return null;
        return @intCast(@intFromEnum(k) - @intFromEnum(Key.@"0"));
    }

    pub fn fromDigit(dg: u8) Key {
        std.debug.assert(dg <= 9);
        return @enumFromInt(@intFromEnum(Key.@"0") + dg);
    }

    pub fn isFunction(k: Key) bool {
        const v = @intFromEnum(k);
        return v >= @intFromEnum(Key.f1) and v <= @intFromEnum(Key.f24);
    }

    pub fn isArrow(k: Key) bool {
        return k == .up or k == .down or k == .left or k == .right;
    }

    pub fn isMouse(k: Key) bool {
        return k == .mouse4 or k == .mouse5;
    }

    /// True when the key (unmodified or with Shift) produces text.
    pub fn isPrintable(k: Key) bool {
        return switch (k.kind()) {
            .letter, .digit, .punct => true,
            .named => k == .space,
        };
    }
};

/// How a key is matched against a keyboard event (ADR-8.3).
pub const MatchBy = enum { virtual_key, scan_code };

pub fn matchBy(k: Key) MatchBy {
    return switch (k.kind()) {
        .digit, .punct => .scan_code,
        .letter, .named => .virtual_key,
    };
}

/// Windows virtual-key code (US layout for digits and punctuation; used for
/// hints and reverse lookup only).
pub fn virtualKey(k: Key) u16 {
    const v = @intFromEnum(k);
    return switch (k.kind()) {
        .letter => 0x41 + @as(u16, v),
        .digit => 0x30 + @as(u16, k.digit().?),
        .punct => switch (k) {
            .@";" => 0xBA,
            .@"=" => 0xBB,
            .@"," => 0xBC,
            .@"-" => 0xBD,
            .@"." => 0xBE,
            .@"/" => 0xBF,
            .@"`" => 0xC0,
            .@"[" => 0xDB,
            .@"\\" => 0xDC,
            .@"]" => 0xDD,
            .@"'" => 0xDE,
            else => unreachable,
        },
        .named => if (k.isFunction())
            0x70 + @as(u16, v - @intFromEnum(Key.f1))
        else switch (k) {
            .enter => 0x0D,
            .tab => 0x09,
            .space => 0x20,
            .escape => 0x1B,
            .backspace => 0x08,
            .delete => 0x2E,
            .insert => 0x2D,
            .home => 0x24,
            .end => 0x23,
            .pgup => 0x21,
            .pgdn => 0x22,
            .left => 0x25,
            .up => 0x26,
            .right => 0x27,
            .down => 0x28,
            .mouse4 => 0x05, // VK_XBUTTON1
            .mouse5 => 0x06, // VK_XBUTTON2
            else => unreachable,
        },
    };
}

/// US-layout set-1 scan code of digit and punctuation positions.
pub fn scanCode(k: Key) ?u16 {
    return switch (k.kind()) {
        .digit => if (k == .@"0") 0x0B else 0x01 + @as(u16, k.digit().?),
        .punct => switch (k) {
            .@"-" => 0x0C,
            .@"=" => 0x0D,
            .@"[" => 0x1A,
            .@"]" => 0x1B,
            .@";" => 0x27,
            .@"'" => 0x28,
            .@"`" => 0x29,
            .@"\\" => 0x2B,
            .@"," => 0x33,
            .@"." => 0x34,
            .@"/" => 0x35,
            else => unreachable,
        },
        else => null,
    };
}

/// A key press as seen by the router: modifier state, virtual key and the
/// set-1 scan code (without the E0 prefix).
pub const KeyEvent = struct {
    mods: Mods,
    vk: u16,
    scan: u16,
};

/// Resolves the bindable key of an event, or null when nothing matches.
/// Letters (by virtual key) are tried first, so on layouts that put a letter
/// at a US punctuation position (AZERTY M at `;`, Dvorak S at `;`) the event
/// is the letter and the positional punctuation default is shadowed.
pub fn keyFromEvent(ev: KeyEvent) ?Key {
    inline for (comptime std.enums.values(Key)) |k| {
        switch (comptime matchBy(k)) {
            .scan_code => if (ev.scan == comptime scanCode(k).?) return k,
            .virtual_key => if (ev.vk == comptime virtualKey(k)) return k,
        }
    }
    return null;
}

/// True when the event is this key: by scan code for digits and
/// punctuation, by virtual key for letters and named keys. An event is at
/// most one key (`keyFromEvent`), so two bindings never both match it.
pub fn keyMatches(k: Key, ev: KeyEvent) bool {
    return keyFromEvent(ev) == k;
}

const Mod = enum { ctrl, shift, alt, win, cmd };

const mod_names = std.StaticStringMap(Mod).initComptime(.{
    .{ "ctrl", .ctrl },     .{ "control", .ctrl }, .{ "ctl", .ctrl },
    .{ "\u{2303}", .ctrl }, .{ "shift", .shift },  .{ "\u{21E7}", .shift },
    .{ "alt", .alt },       .{ "opt", .alt },      .{ "option", .alt },
    .{ "\u{2325}", .alt },  .{ "win", .win },      .{ "super", .win },
    .{ "cmd", .cmd },       .{ "command", .cmd },  .{ "\u{2318}", .cmd },
});

/// Glyph modifiers that may prefix a key without '+' ("⌘⇧]").
const mod_glyphs = [_]struct { []const u8, Mod }{
    .{ "\u{2303}", .ctrl }, .{ "\u{21E7}", .shift }, .{ "\u{2325}", .alt }, .{ "\u{2318}", .cmd },
};

const key_aliases = std.StaticStringMap(Key).initComptime(.{
    .{ "return", .enter },      .{ "\u{21A9}", .enter },    .{ "\u{23CE}", .enter },
    .{ "esc", .escape },        .{ "\u{238B}", .escape },   .{ "\u{21E5}", .tab },
    .{ "<space>", .space },     .{ "spacebar", .space },    .{ "\u{232B}", .backspace },
    .{ "del", .delete },        .{ "\u{2326}", .delete },   .{ "ins", .insert },
    .{ "pageup", .pgup },       .{ "page_up", .pgup },      .{ "prior", .pgup },
    .{ "pagedown", .pgdn },     .{ "page_down", .pgdn },    .{ "next", .pgdn },
    .{ "\u{2190}", .left },     .{ "\u{2192}", .right },    .{ "\u{2191}", .up },
    .{ "\u{2193}", .down },     .{ "arrowleft", .left },    .{ "arrowright", .right },
    .{ "arrowup", .up },        .{ "arrowdown", .down },    .{ "comma", .@"," },
    .{ "period", .@"." },       .{ "dot", .@"." },          .{ "slash", .@"/" },
    .{ "backslash", .@"\\" },   .{ "semicolon", .@";" },    .{ "quote", .@"'" },
    .{ "apostrophe", .@"'" },   .{ "backtick", .@"`" },     .{ "backquote", .@"`" },
    .{ "grave", .@"`" },        .{ "minus", .@"-" },        .{ "dash", .@"-" },
    .{ "hyphen", .@"-" },       .{ "equal", .@"=" },        .{ "equals", .@"=" },
    .{ "bracketleft", .@"[" },  .{ "leftbracket", .@"[" },  .{ "lbracket", .@"[" },
    .{ "bracketright", .@"]" }, .{ "rightbracket", .@"]" }, .{ "rbracket", .@"]" },
    .{ "xbutton1", .mouse4 },   .{ "xbutton2", .mouse5 },
});

const max_token = 32;

fn lowerInto(buf: *[max_token]u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, idx| buf[idx] = std.ascii.toLower(c);
    return buf[0..s.len];
}

fn lookupMod(s: []const u8) ?Mod {
    var buf: [max_token]u8 = undefined;
    const lower = lowerInto(&buf, s) orelse return null;
    return mod_names.get(lower);
}

/// Parses a key name ("a", "A", "]", "bracketright", "pgup", "F5", "↩").
pub fn parseKey(s: []const u8) ?Key {
    var buf: [max_token]u8 = undefined;
    const lower = lowerInto(&buf, s) orelse return null;
    if (lower.len == 0) return null;
    if (std.meta.stringToEnum(Key, lower)) |k| return k;
    return key_aliases.get(lower);
}

pub const ParseError = error{
    /// Empty text, or an empty segment ("ctrl+", "ctrl++b").
    Empty,
    UnknownModifier,
    UnknownKey,
    DuplicateModifier,
    /// Only modifiers ("ctrl+shift").
    MissingKey,
    /// `cmd` in a Windows-dialect (wmux.json) stroke; see `cmd_hint`.
    CmdNotAllowed,
    /// More than two strokes in a chord.
    TooManyStrokes,
};

/// Hint shown when `cmd` appears in wmux.json (ADR-8.3).
pub const cmd_hint = "'cmd' is a macOS modifier; use ctrl+shift (or put the macOS stroke in cmux.json, which is translated)";

pub const Stroke = struct {
    mods: Mods = .{},
    key: Key,

    pub fn eql(a: Stroke, b: Stroke) bool {
        return a.key == b.key and a.mods.eql(b.mods);
    }

    /// Parses one stroke ("ctrl+shift+]", "cmd+opt+b", "⌘⇧]", "shift+'").
    pub fn parse(text: []const u8, dialect: Dialect) ParseError!Stroke {
        const t = std.mem.trim(u8, text, " \t");
        if (t.len == 0) return error.Empty;
        var mods: Mods = .{};
        var it = std.mem.splitScalar(u8, t, '+');
        var key: ?Key = null;
        while (it.next()) |seg_raw| {
            if (seg_raw.len == 0) return error.Empty;
            const seg = try peelGlyphs(seg_raw, &mods, dialect);
            const last = it.peek() == null;
            if (seg.len == 0) {
                if (last) return error.MissingKey;
                continue;
            }
            if (lookupMod(seg)) |m| {
                try addMod(&mods, m, dialect);
                if (last) return error.MissingKey;
                continue;
            }
            if (!last) return error.UnknownModifier;
            key = parseKey(seg) orelse return error.UnknownKey;
        }
        return .{ .mods = mods, .key = key orelse return error.MissingKey };
    }

    fn peelGlyphs(seg: []const u8, mods: *Mods, dialect: Dialect) ParseError![]const u8 {
        var rest = seg;
        outer: while (rest.len > 0) {
            for (mod_glyphs) |g| {
                if (std.mem.startsWith(u8, rest, g[0])) {
                    try addMod(mods, g[1], dialect);
                    rest = rest[g[0].len..];
                    continue :outer;
                }
            }
            break;
        }
        return rest;
    }

    fn addMod(mods: *Mods, m: Mod, dialect: Dialect) ParseError!void {
        if (m == .cmd and dialect == .windows) return error.CmdNotAllowed;
        const bit: u8 = @as(u8, 1) << @intFromEnum(m);
        const cur: u8 = @bitCast(mods.*);
        if (cur & bit != 0) return error.DuplicateModifier;
        mods.* = @bitCast(cur | bit);
    }

    /// Writes the canonical text. Windows order: ctrl+shift+alt+win;
    /// mac order: cmd+ctrl+opt+shift; display: "Ctrl+Shift+Alt+PgUp".
    pub fn write(s: Stroke, w: *std.Io.Writer, dialect: Dialect) std.Io.Writer.Error!void {
        const m = s.mods;
        switch (dialect) {
            .windows => {
                if (m.cmd) try w.writeAll("cmd+");
                if (m.ctrl) try w.writeAll("ctrl+");
                if (m.shift) try w.writeAll("shift+");
                if (m.alt) try w.writeAll("alt+");
                if (m.win) try w.writeAll("win+");
                try w.writeAll(s.key.name());
            },
            .mac => {
                if (m.cmd) try w.writeAll("cmd+");
                if (m.ctrl) try w.writeAll("ctrl+");
                if (m.alt) try w.writeAll("opt+");
                if (m.shift) try w.writeAll("shift+");
                if (m.win) try w.writeAll("win+");
                try w.writeAll(s.key.name());
            },
            .display => {
                if (m.cmd) try w.writeAll("Cmd+");
                if (m.ctrl) try w.writeAll("Ctrl+");
                if (m.shift) try w.writeAll("Shift+");
                if (m.alt) try w.writeAll("Alt+");
                if (m.win) try w.writeAll("Win+");
                try w.writeAll(displayName(s.key));
            },
        }
    }

    /// `{f}` formats in the Windows dialect.
    pub fn format(s: Stroke, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return s.write(w, .windows);
    }

    /// Exact match of a key event (modifiers must be identical).
    pub fn matches(s: Stroke, ev: KeyEvent) bool {
        return s.mods.eql(ev.mods) and keyMatches(s.key, ev);
    }

    /// Numbered families (ADR-8.3): a digit stroke stands for its 1–9
    /// family. Returns the pressed digit (1–9) or null.
    pub fn matchNumbered(s: Stroke, ev: KeyEvent) ?u8 {
        if (s.key.kind() != .digit or !s.mods.eql(ev.mods)) return null;
        const dg = (keyFromEvent(ev) orelse return null).digit() orelse return null;
        return if (dg == 0) null else dg;
    }

    /// No modifiers at all (bare key).
    pub fn isBare(s: Stroke) bool {
        return s.mods.isEmpty();
    }

    pub fn withKey(s: Stroke, k: Key) Stroke {
        return .{ .mods = s.mods, .key = k };
    }
};

fn displayName(k: Key) []const u8 {
    return switch (k) {
        // zig fmt: off
        .a => "A", .b => "B", .c => "C", .d => "D", .e => "E", .f => "F", .g => "G",
        .h => "H", .i => "I", .j => "J", .k => "K", .l => "L", .m => "M", .n => "N",
        .o => "O", .p => "P", .q => "Q", .r => "R", .s => "S", .t => "T", .u => "U",
        .v => "V", .w => "W", .x => "X", .y => "Y", .z => "Z",
        .f1 => "F1", .f2 => "F2", .f3 => "F3", .f4 => "F4", .f5 => "F5", .f6 => "F6",
        .f7 => "F7", .f8 => "F8", .f9 => "F9", .f10 => "F10", .f11 => "F11", .f12 => "F12",
        .f13 => "F13", .f14 => "F14", .f15 => "F15", .f16 => "F16", .f17 => "F17",
        .f18 => "F18", .f19 => "F19", .f20 => "F20", .f21 => "F21", .f22 => "F22",
        .f23 => "F23", .f24 => "F24",
        .enter => "Enter", .tab => "Tab", .space => "Space", .escape => "Esc",
        .backspace => "Backspace", .delete => "Delete", .insert => "Insert",
        .home => "Home", .end => "End", .pgup => "PgUp", .pgdn => "PgDn",
        .up => "Up", .down => "Down", .left => "Left", .right => "Right",
        .mouse4 => "Mouse4", .mouse5 => "Mouse5",
        // zig fmt: on
        else => k.name(),
    };
}

/// One stroke or a two-stroke chord ("ctrl+b c", JSON `["ctrl+b","c"]`).
pub const Trigger = struct {
    first: Stroke,
    second: ?Stroke = null,

    pub fn eql(a: Trigger, b: Trigger) bool {
        if (!a.first.eql(b.first)) return false;
        if (a.second == null or b.second == null) return a.second == null and b.second == null;
        return a.second.?.eql(b.second.?);
    }

    pub fn isChord(t: Trigger) bool {
        return t.second != null;
    }

    /// Parses "stroke" or "stroke stroke" (strokes separated by whitespace).
    pub fn parse(text: []const u8, dialect: Dialect) ParseError!Trigger {
        var it = std.mem.tokenizeAny(u8, text, " \t");
        const a = it.next() orelse return error.Empty;
        const first = try Stroke.parse(a, dialect);
        const b = it.next() orelse return .{ .first = first };
        if (it.next() != null) return error.TooManyStrokes;
        return .{ .first = first, .second = try Stroke.parse(b, dialect) };
    }

    /// Parses the two-element JSON array form.
    pub fn parseChord(prefix: []const u8, key: []const u8, dialect: Dialect) ParseError!Trigger {
        return .{ .first = try Stroke.parse(prefix, dialect), .second = try Stroke.parse(key, dialect) };
    }

    pub fn write(t: Trigger, w: *std.Io.Writer, dialect: Dialect) std.Io.Writer.Error!void {
        try t.first.write(w, dialect);
        if (t.second) |s| {
            try w.writeByte(' ');
            try s.write(w, dialect);
        }
    }

    pub fn format(t: Trigger, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return t.write(w, .windows);
    }

    /// True when one trigger is a strict chord extension of the other's
    /// single stroke (a prefix collision: "ctrl+b" vs "ctrl+b c").
    pub fn prefixCollides(a: Trigger, b: Trigger) bool {
        if (!a.first.eql(b.first)) return false;
        return (a.second == null) != (b.second == null);
    }
};

/// Unbind spellings (ADR-8.3); JSON `null` is handled by the caller.
pub fn isUnbindValue(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t");
    const words = [_][]const u8{ "", "none", "clear", "unbound", "disabled" };
    for (words) |wd| if (std.ascii.eqlIgnoreCase(t, wd)) return true;
    return false;
}

/// Writes a trigger into a caller buffer; returns the slice.
pub fn bufPrint(buf: []u8, t: Trigger, dialect: Dialect) error{NoSpaceLeft}![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    t.write(&w, dialect) catch return error.NoSpaceLeft;
    return w.buffered();
}

/// Terminal-safety classification of a stroke (ADR-8.4).
pub const Tier = enum {
    /// Ctrl+Shift+<key> (cmux ⌘<key>).
    a,
    /// Ctrl+Shift+Alt+<key> (cmux ⌘⇧<key>, ⌃⌘, ⌥⌘ variants); AltGr rule applies.
    b,
    /// Alt+Shift+<key> (cmux ⌥⌘<key>; Windows Terminal pane tier).
    c,
    /// Navigation: Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+Alt+<arrows|PgUp|PgDn>,
    /// F11, Alt+F4, and the mouse X buttons.
    n,
    /// Documented Windows Terminal / Ghostty exceptions: Ctrl+C, Ctrl+V,
    /// Ctrl+, and the font-size keys Ctrl+= / Ctrl+- / Ctrl+0.
    exception,
    /// Must not fire while a terminal has focus.
    reserved,

    pub fn terminalSafe(t: Tier) bool {
        return t != .reserved;
    }
};

/// Classifies the stroke against the ADR-8.4 rules.
pub fn tier(s: Stroke) Tier {
    const m = s.mods;
    const k = s.key;
    if (k.isMouse()) return .n;
    if (m.win or m.cmd) return .reserved;
    const ctrl_shift: Mods = .{ .ctrl = true, .shift = true };
    const ctrl_alt: Mods = .{ .ctrl = true, .alt = true };
    if (m.eql(.{ .ctrl = true }) and k == .tab) return .n;
    if (m.eql(ctrl_shift) and k == .tab) return .n;
    if (m.eql(ctrl_alt) and (k.isArrow() or k == .pgup or k == .pgdn)) return .n;
    if (m.isEmpty() and k == .f11) return .n;
    if (m.eql(.{ .alt = true }) and k == .f4) return .n;
    if (m.eql(.{ .ctrl = true })) return switch (k) {
        .c, .v, .@",", .@"=", .@"-", .@"0" => .exception,
        else => .reserved,
    };
    if (m.eql(ctrl_shift)) {
        // PSReadLine word selection.
        if (k == .left or k == .right) return .reserved;
        return .a;
    }
    if (m.eql(.{ .ctrl = true, .shift = true, .alt = true })) return .b;
    if (m.eql(.{ .alt = true, .shift = true })) return .c;
    // Bare, Shift-only, Alt-only, Ctrl+Alt (AltGr) on anything else.
    return .reserved;
}

/// Translates a macOS (`cmux.json`) stroke to its Windows stroke (ADR-8.6):
/// `cmd`→`ctrl+shift`; `cmd+opt+<letter>` (with or without shift)→
/// `alt+shift+<letter>`; any other `cmd` combination (`cmd+shift`,
/// `cmd+ctrl`, `cmd+opt+<non-letter>`)→`ctrl+shift+alt`; without `cmd`,
/// `opt`→`alt` and `ctrl`/`shift` are kept.
pub fn translateMac(s: Stroke) Stroke {
    const m = s.mods;
    if (!m.cmd) return s;
    const others = m.shift or m.ctrl or m.alt;
    const out: Mods = if (!others)
        .{ .ctrl = true, .shift = true }
    else if (m.alt and !m.ctrl and s.key.kind() == .letter)
        .{ .alt = true, .shift = true }
    else
        .{ .ctrl = true, .shift = true, .alt = true };
    var r = out;
    r.win = m.win;
    return .{ .mods = r, .key = s.key };
}

pub fn translateMacTrigger(t: Trigger) Trigger {
    return .{
        .first = translateMac(t.first),
        .second = if (t.second) |s| translateMac(s) else null,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectRoundTrip(text: []const u8, dialect: Dialect, want: []const u8) !void {
    const t = try Trigger.parse(text, dialect);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(want, try bufPrint(&buf, t, dialect));
    // Canonical text parses back to the same trigger.
    try testing.expect((try Trigger.parse(want, dialect)).eql(t));
}

test "unit: keys: stroke parse/format round trips (windows)" {
    try expectRoundTrip("ctrl+shift+d", .windows, "ctrl+shift+d");
    try expectRoundTrip("Shift+Ctrl+D", .windows, "ctrl+shift+d");
    try expectRoundTrip("control+alt+shift+n", .windows, "ctrl+shift+alt+n");
    try expectRoundTrip("ctl+,", .windows, "ctrl+,");
    try expectRoundTrip("ctrl+shift+comma", .windows, "ctrl+shift+,");
    try expectRoundTrip("alt+shift+equal", .windows, "shift+alt+=");
    try expectRoundTrip("ctrl+shift+alt+pageup", .windows, "ctrl+shift+alt+pgup");
    try expectRoundTrip("ctrl+alt+Right", .windows, "ctrl+alt+right");
    try expectRoundTrip("F11", .windows, "f11");
    try expectRoundTrip("f24", .windows, "f24");
    try expectRoundTrip("esc", .windows, "escape");
    try expectRoundTrip("return", .windows, "enter");
    try expectRoundTrip("mouse4", .windows, "mouse4");
    try expectRoundTrip("ctrl+shift+bracketleft", .windows, "ctrl+shift+[");
    try expectRoundTrip("ctrl+shift+\\", .windows, "ctrl+shift+\\");
    try expectRoundTrip("shift+'", .windows, "shift+'");
    try expectRoundTrip("ctrl+shift+backtick", .windows, "ctrl+shift+`");
    try expectRoundTrip("win+e", .windows, "win+e");
    try expectRoundTrip("opt+z", .windows, "alt+z");
}

test "unit: keys: chord parse/format round trips" {
    try expectRoundTrip("ctrl+b c", .windows, "ctrl+b c");
    try expectRoundTrip("  ctrl+b   shift+5 ", .windows, "ctrl+b shift+5");
    try expectRoundTrip("g g", .windows, "g g");
    try expectRoundTrip("] f", .windows, "] f");
    try expectRoundTrip("ctrl+b space", .windows, "ctrl+b space");
    const c = try Trigger.parseChord("ctrl+b", ",", .windows);
    try testing.expect(c.eql(try Trigger.parse("ctrl+b ,", .windows)));
    try testing.expectError(error.TooManyStrokes, Trigger.parse("a b c", .windows));
    try testing.expect(Trigger.prefixCollides(try Trigger.parse("ctrl+b", .windows), c));
    try testing.expect(!Trigger.prefixCollides(c, c));
}

test "unit: keys: mac strokes parse and round trip" {
    try expectRoundTrip("cmd+shift+]", .mac, "cmd+shift+]");
    try expectRoundTrip("cmd+shift+[", .mac, "cmd+shift+[");
    try expectRoundTrip("shift+cmd+]", .mac, "cmd+shift+]");
    try expectRoundTrip("command+option+b", .mac, "cmd+opt+b");
    try expectRoundTrip("cmd+ctrl+opt+.", .mac, "cmd+ctrl+opt+.");
    try expectRoundTrip("cmd+opt+shift+left", .mac, "cmd+opt+shift+left");
    try expectRoundTrip("ctrl+shift+h", .mac, "ctrl+shift+h");
    try expectRoundTrip("cmd+enter", .mac, "cmd+enter");
    // Glyph forms.
    const g = try Stroke.parse("\u{2318}\u{21E7}]", .mac);
    try testing.expect(g.eql(try Stroke.parse("cmd+shift+]", .mac)));
    const g2 = try Stroke.parse("\u{2303}\u{2318}\u{2190}", .mac);
    try testing.expect(g2.eql(try Stroke.parse("cmd+ctrl+left", .mac)));
    const g3 = try Stroke.parse("\u{2318}+\u{21A9}", .mac);
    try testing.expect(g3.eql(try Stroke.parse("cmd+return", .mac)));
    // cmd is rejected in the Windows dialect.
    try testing.expectError(error.CmdNotAllowed, Stroke.parse("cmd+d", .windows));
    try testing.expectError(error.CmdNotAllowed, Stroke.parse("\u{2318}d", .windows));
}

test "unit: keys: malformed strokes are rejected" {
    try testing.expectError(error.Empty, Stroke.parse("", .windows));
    try testing.expectError(error.Empty, Stroke.parse("   ", .windows));
    try testing.expectError(error.Empty, Trigger.parse("", .windows));
    try testing.expectError(error.Empty, Stroke.parse("ctrl+", .windows));
    try testing.expectError(error.Empty, Stroke.parse("ctrl++", .windows));
    try testing.expectError(error.Empty, Stroke.parse("+a", .windows));
    try testing.expectError(error.MissingKey, Stroke.parse("ctrl+shift", .windows));
    try testing.expectError(error.MissingKey, Stroke.parse("\u{2318}\u{21E7}", .mac));
    try testing.expectError(error.UnknownModifier, Stroke.parse("hyper+a", .windows));
    try testing.expectError(error.UnknownModifier, Stroke.parse("a+ctrl", .windows));
    try testing.expectError(error.UnknownKey, Stroke.parse("ctrl+banana", .windows));
    try testing.expectError(error.UnknownKey, Stroke.parse("ctrl+f25", .windows));
    try testing.expectError(error.UnknownKey, Stroke.parse("ctrl+\u{00E9}", .windows));
    try testing.expectError(error.DuplicateModifier, Stroke.parse("ctrl+control+a", .windows));
    try testing.expectError(error.DuplicateModifier, Stroke.parse("alt+opt+a", .windows));
    const huge = "ctrl+" ** 200 ++ "a";
    try testing.expectError(error.DuplicateModifier, Stroke.parse(huge, .windows));
    const long_key = "ctrl+" ++ "x" ** 100;
    try testing.expectError(error.UnknownKey, Stroke.parse(long_key, .windows));
}

test "unit: keys: stroke parsing edge cases" {
    // Tabs and repeated blanks separate chord strokes; case is ignored.
    const t = try Trigger.parse("\tCTRL+B \t  PageDown\t", .windows);
    try testing.expect(t.eql(try Trigger.parse("ctrl+b pgdn", .windows)));
    try testing.expect((try Stroke.parse("Ctrl+Shift+ArrowLeft", .windows)).eql(try Stroke.parse("ctrl+shift+left", .windows)));
    // Glyph keys and glyph modifiers mix with words.
    try testing.expect((try Stroke.parse("\u{21E7}\u{21E5}", .mac)).eql(try Stroke.parse("shift+tab", .mac)));
    try testing.expect((try Stroke.parse("\u{2318}+\u{232B}", .mac)).eql(try Stroke.parse("cmd+backspace", .mac)));
    try testing.expect((try Stroke.parse("opt+\u{2318}\u{2193}", .mac)).eql(try Stroke.parse("cmd+opt+down", .mac)));
    try testing.expectError(error.DuplicateModifier, Stroke.parse("\u{2318}\u{2318}a", .mac));
    try testing.expectError(error.DuplicateModifier, Stroke.parse("cmd+\u{2318}a", .mac));
    // Every key name round-trips in every dialect that can express it.
    var buf: [32]u8 = undefined;
    for (std.enums.values(Key)) |k| {
        const s: Stroke = .{ .mods = .{ .ctrl = true }, .key = k };
        for ([_]Dialect{ .windows, .mac }) |d| {
            const text = try bufPrint(&buf, .{ .first = s }, d);
            try testing.expect((try Stroke.parse(text, d)).eql(s));
        }
        try testing.expectEqual(k, parseKey(@tagName(k)).?);
    }
    // Spaces around '+' are not part of the grammar ("ctrl" alone is the
    // first stroke of a chord here, and it has no key).
    try testing.expectError(error.MissingKey, Trigger.parse("ctrl + b", .windows));
    try testing.expectError(error.UnknownModifier, Stroke.parse("ctrl +b", .windows));
    // A chord whose parts fail reports the part's error.
    try testing.expectError(error.UnknownKey, Trigger.parseChord("ctrl+b", "nokey", .windows));
    try testing.expectError(error.CmdNotAllowed, Trigger.parseChord("cmd+b", "c", .windows));
}

test "unit: keys: unbind spellings" {
    for ([_][]const u8{ "", "none", "NONE", "clear", "unbound", "disabled", "  none " }) |s|
        try testing.expect(isUnbindValue(s));
    for ([_][]const u8{ "ctrl+a", "null", "nothing" }) |s|
        try testing.expect(!isUnbindValue(s));
}

test "unit: keys: display format" {
    var buf: [64]u8 = undefined;
    const t = try Trigger.parse("ctrl+shift+alt+pgup", .windows);
    try testing.expectEqualStrings("Ctrl+Shift+Alt+PgUp", try bufPrint(&buf, t, .display));
    const t2 = try Trigger.parse("ctrl+b shift+5", .windows);
    try testing.expectEqualStrings("Ctrl+B Shift+5", try bufPrint(&buf, t2, .display));
    try testing.expectError(error.NoSpaceLeft, bufPrint(buf[0..3], t, .display));
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try aw.writer.print("{f}", .{t});
    try testing.expectEqualStrings("ctrl+shift+alt+pgup", aw.written());
}

test "unit: keys: letters match by virtual key, digits and punctuation by scan code" {
    const ctrl_shift: Mods = .{ .ctrl = true, .shift = true };
    // Letter: vk 'D', any scan (layout-aware mnemonic).
    const d = try Stroke.parse("ctrl+shift+d", .windows);
    try testing.expect(d.matches(.{ .mods = ctrl_shift, .vk = 0x44, .scan = 0x99 }));
    try testing.expect(!d.matches(.{ .mods = ctrl_shift, .vk = 0x45, .scan = 0x20 }));
    try testing.expect(!d.matches(.{ .mods = .{ .ctrl = true }, .vk = 0x44, .scan = 0x20 }));
    // Digit by position: AZERTY "1" key has vk '&'-ish OEM but scan 0x02.
    const one = try Stroke.parse("ctrl+shift+1", .windows);
    try testing.expect(one.matches(.{ .mods = ctrl_shift, .vk = 0x00, .scan = 0x02 }));
    try testing.expect(!one.matches(.{ .mods = ctrl_shift, .vk = 0x31, .scan = 0x03 }));
    // ISO bracket position: "]" is scan 0x1B whatever the label.
    const br = try Stroke.parse("ctrl+shift+]", .windows);
    try testing.expect(br.matches(.{ .mods = ctrl_shift, .vk = 0xBB, .scan = 0x1B }));
    // Named keys by vk.
    const pg = try Stroke.parse("ctrl+alt+pgdn", .windows);
    try testing.expect(pg.matches(.{ .mods = .{ .ctrl = true, .alt = true }, .vk = 0x22, .scan = 0x51 }));
    try testing.expect((try Stroke.parse("f12", .windows)).matches(.{ .mods = .{}, .vk = 0x7B, .scan = 0x58 }));
    try testing.expect((try Stroke.parse("mouse5", .windows)).matches(.{ .mods = .{}, .vk = 0x06, .scan = 0 }));
    // Reverse lookup.
    try testing.expectEqual(Key.@"0", keyFromEvent(.{ .mods = .{}, .vk = 0, .scan = 0x0B }).?);
    try testing.expectEqual(Key.q, keyFromEvent(.{ .mods = .{}, .vk = 0x51, .scan = 0x1E }).?);
    try testing.expectEqual(@as(?Key, null), keyFromEvent(.{ .mods = .{}, .vk = 0xFF, .scan = 0x7F }));
    // Every key has a distinct vk, and scan-matched keys a distinct scan code.
    for (std.enums.values(Key)) |a| for (std.enums.values(Key)) |b| {
        if (a == b) continue;
        try testing.expect(virtualKey(a) != virtualKey(b));
        if (scanCode(a)) |sa| if (scanCode(b)) |sb| try testing.expect(sa != sb);
    };
}

test "unit: keys: numbered families match 1-9 only" {
    const fam = try Stroke.parse("ctrl+shift+alt+1", .windows);
    const m: Mods = .{ .ctrl = true, .shift = true, .alt = true };
    var dg: u8 = 1;
    while (dg <= 9) : (dg += 1) {
        const ev: KeyEvent = .{ .mods = m, .vk = 0, .scan = scanCode(Key.fromDigit(dg)).? };
        try testing.expectEqual(@as(?u8, dg), fam.matchNumbered(ev));
    }
    try testing.expectEqual(@as(?u8, null), fam.matchNumbered(.{ .mods = m, .vk = 0, .scan = 0x0B }));
    try testing.expectEqual(@as(?u8, null), fam.matchNumbered(.{ .mods = .{ .ctrl = true }, .vk = 0, .scan = 0x02 }));
    const letter = try Stroke.parse("ctrl+shift+a", .windows);
    try testing.expectEqual(@as(?u8, null), letter.matchNumbered(.{ .mods = .{ .ctrl = true, .shift = true }, .vk = 0x41, .scan = 0x1E }));
}

test "unit: keys: an event matches one key on non-US layouts" {
    const cs: Mods = .{ .ctrl = true, .shift = true };
    // A letter at a US punctuation position is the letter, never the
    // punctuation: AZERTY M at ';', Dvorak W at ',', S at ';', Z at '/'.
    const cases = [_]struct { u16, u16, Key, []const u8, []const u8 }{
        .{ 'M', 0x27, .m, "ctrl+shift+m", "ctrl+shift+;" },
        .{ 'W', 0x33, .w, "ctrl+shift+w", "ctrl+shift+," },
        .{ 'S', 0x27, .s, "ctrl+shift+s", "ctrl+shift+;" },
        .{ 'Z', 0x35, .z, "ctrl+shift+z", "ctrl+shift+/" },
    };
    for (cases) |c| {
        const ev: KeyEvent = .{ .mods = cs, .vk = c[0], .scan = c[1] };
        try testing.expectEqual(c[2], keyFromEvent(ev).?);
        try testing.expect((try Stroke.parse(c[3], .windows)).matches(ev));
        try testing.expect(!(try Stroke.parse(c[4], .windows)).matches(ev));
    }
    // AZERTY ',' sits at the US 'm' position: no positional key there.
    const comma: KeyEvent = .{ .mods = cs, .vk = 0xBC, .scan = 0x32 };
    try testing.expectEqual(@as(?Key, null), keyFromEvent(comma));
    try testing.expect(!(try Stroke.parse("ctrl+shift+,", .windows)).matches(comma));
    // The AZERTY digit row keeps the US positions for numbered families...
    const fam = try Stroke.parse("ctrl+shift+1", .windows);
    try testing.expectEqual(@as(?u8, 3), fam.matchNumbered(.{ .mods = cs, .vk = 0x33, .scan = 0x04 }));
    try testing.expectEqual(@as(?u8, 9), fam.matchNumbered(.{ .mods = cs, .vk = 0x00, .scan = 0x0A }));
    // ...but a letter on the digit row is a letter.
    try testing.expectEqual(@as(?u8, null), fam.matchNumbered(.{ .mods = cs, .vk = 'A', .scan = 0x02 }));
    // Every key matches its own US event and no other key does.
    for (std.enums.values(Key)) |k| {
        const ev: KeyEvent = .{ .mods = .{}, .vk = virtualKey(k), .scan = scanCode(k) orelse 0 };
        for (std.enums.values(Key)) |other| try testing.expectEqual(k == other, keyMatches(other, ev));
    }
}

fn tierOf(text: []const u8) !Tier {
    return tier(try Stroke.parse(text, .windows));
}

test "unit: keys: terminal-safety tiers" {
    try testing.expectEqual(Tier.a, try tierOf("ctrl+shift+d"));
    try testing.expectEqual(Tier.a, try tierOf("ctrl+shift+pgup"));
    try testing.expectEqual(Tier.b, try tierOf("ctrl+shift+alt+n"));
    try testing.expectEqual(Tier.c, try tierOf("alt+shift+="));
    try testing.expectEqual(Tier.n, try tierOf("ctrl+tab"));
    try testing.expectEqual(Tier.n, try tierOf("ctrl+shift+tab"));
    try testing.expectEqual(Tier.n, try tierOf("ctrl+alt+left"));
    try testing.expectEqual(Tier.n, try tierOf("ctrl+alt+pgdn"));
    try testing.expectEqual(Tier.n, try tierOf("f11"));
    try testing.expectEqual(Tier.n, try tierOf("alt+f4"));
    try testing.expectEqual(Tier.n, try tierOf("mouse4"));
    for ([_][]const u8{ "ctrl+c", "ctrl+v", "ctrl+,", "ctrl+=", "ctrl+-", "ctrl+0" }) |s|
        try testing.expectEqual(Tier.exception, try tierOf(s));
    const reserved = [_][]const u8{
        "ctrl+a",         "ctrl+b",        "ctrl+t",     "ctrl+w",          "ctrl+1",
        "ctrl+enter",     "ctrl+pgup",     "ctrl+pgdn",  "alt+1",           "alt+9",
        "alt+b",          "alt+left",      "ctrl+alt+b", "ctrl+alt+1",      "a",
        "shift+a",        "f1",            "f10",        "f3",              "enter",
        "escape",         "shift+tab",     "win+e",      "ctrl+shift+left", "ctrl+shift+right",
        "ctrl+alt+enter", "ctrl+win+left",
    };
    for (reserved) |s| {
        if (try tierOf(s) != .reserved) {
            std.log.err("expected reserved: {s}", .{s});
            return error.TestUnexpectedResult;
        }
    }
}

fn expectTranslate(mac: []const u8, win: []const u8) !void {
    const got = translateMacTrigger(try Trigger.parse(mac, .mac));
    try testing.expect(got.eql(try Trigger.parse(win, .windows)));
}

test "unit: keys: mac stroke translation" {
    try expectTranslate("cmd+d", "ctrl+shift+d");
    try expectTranslate("cmd+,", "ctrl+shift+,");
    try expectTranslate("cmd+shift+d", "ctrl+shift+alt+d");
    try expectTranslate("cmd+shift+]", "ctrl+shift+alt+]");
    try expectTranslate("cmd+ctrl+w", "ctrl+shift+alt+w");
    try expectTranslate("cmd+opt+b", "alt+shift+b");
    try expectTranslate("cmd+opt+shift+a", "alt+shift+a");
    try expectTranslate("cmd+opt+=", "ctrl+shift+alt+=");
    try expectTranslate("cmd+opt+left", "ctrl+shift+alt+left");
    try expectTranslate("cmd+ctrl+opt+n", "ctrl+shift+alt+n");
    try expectTranslate("opt+z", "alt+z");
    try expectTranslate("ctrl+shift+h", "ctrl+shift+h");
    try expectTranslate("ctrl+1", "ctrl+1");
    try expectTranslate("ctrl+b c", "ctrl+b c");
    try expectTranslate("cmd+b cmd+c", "ctrl+shift+b ctrl+shift+c");
}
