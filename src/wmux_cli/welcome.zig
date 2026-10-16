//! `cmux welcome` (cli-welcome-command): the logo in a truecolor gradient
//! (palette per light/dark appearance), a tagline, the fixed default
//! shortcut list and a pointer to `cmux shortcuts`. The list comes from the
//! Windows defaults in `wmux_proto.actions_catalog`, never from the user's
//! bindings. Offline. Colors are emitted only when stdout is a terminal.

const std = @import("std");
const proto = @import("wmux_proto");
const catalog = proto.actions_catalog;
const Writer = std.Io.Writer;
const brand_mod = @import("brand.zig");
const Brand = brand_mod.Brand;

pub const help_text =
    \\Usage: cmux welcome
    \\
    \\Print the welcome screen: the wmux logo, a tagline and the default shortcuts
    \\(the built-in Windows keymap, not your own bindings). Works without a
    \\running app.
    \\
;

const logo = [_][]const u8{
    "__        __ __  __  _   _ __  __",
    "\\ \\      / /|  \\/  || | | |\\ \\/ /",
    " \\ \\ /\\ / / | |\\/| || | | | \\  / ",
    "  \\ V  V /  | |  | || |_| | /  \\ ",
    "   \\_/\\_/   |_|  |_| \\___/ /_/\\_\\",
};

const tagline = "A Windows terminal for AI coding agents.";

/// The actions shown, in order (cmux action ids).
pub const shortcut_ids = [_][]const u8{
    "commandPalette",
    "newTab",
    "newWindow",
    "splitRight",
    "splitDown",
    "focusLeft",
    "focusRight",
    "closeTab",
    "renameWorkspace",
    "selectWorkspaceByNumber",
    "toggleSidebar",
    "toggleFileExplorer",
    "find",
    "showNotifications",
    "jumpToUnread",
};

const Shortcut = struct { title: []const u8, key: []const u8 };

/// Resolved at compile time; a missing id or an unbound action fails the build.
pub const shortcuts = blk: {
    @setEvalBranchQuota(1_000_000);
    var out: [shortcut_ids.len]Shortcut = undefined;
    for (shortcut_ids, 0..) |id, i| {
        var found: ?Shortcut = null;
        for (catalog.entries) |e| {
            if (std.mem.eql(u8, e.id, id)) {
                if (e.keys.len == 0) @compileError("welcome shortcut has no default key: " ++ id);
                found = .{ .title = e.title, .key = e.keys[0] };
            }
        }
        out[i] = found orelse @compileError("welcome shortcut id not in the actions catalog: " ++ id);
    }
    break :blk out;
};

/// `ctrl+shift+n` → `Ctrl+Shift+N`; chords keep their space.
pub fn writeKey(w: *Writer, key: []const u8) Writer.Error!void {
    var i: usize = 0;
    var start: usize = 0;
    while (i <= key.len) : (i += 1) {
        if (i == key.len or key[i] == '+' or key[i] == ' ') {
            const part = key[start..i];
            if (part.len == 1) {
                try w.writeByte(std.ascii.toUpper(part[0]));
            } else if (part.len > 1) {
                try w.writeByte(std.ascii.toUpper(part[0]));
                try w.writeAll(part[1..]);
            } else if (i < key.len and key[i] == '+') {
                // `ctrl++`: the empty part before this `+` is the plus key.
                try w.writeByte('+');
                start = i + 1;
                continue;
            }
            if (i < key.len) try w.writeByte(key[i]);
            start = i + 1;
        }
    }
}

const Rgb = struct { r: u8, g: u8, b: u8 };

fn lerp(a: u8, b: u8, t_num: usize, t_den: usize) u8 {
    const af: i32 = a;
    const bf: i32 = b;
    return @intCast(af + @divTrunc((bf - af) * @as(i32, @intCast(t_num)), @as(i32, @intCast(t_den))));
}

pub const Options = struct {
    color: bool = false,
    light: bool = false,
};

pub fn write(w: *Writer, brand: Brand, opts: Options) Writer.Error!void {
    const from: Rgb = if (opts.light) .{ .r = 0x00, .g = 0x6e, .b = 0xc7 } else .{ .r = 0x5e, .g = 0xd4, .b = 0xff };
    const to: Rgb = if (opts.light) .{ .r = 0x6a, .g = 0x3d, .b = 0xc9 } else .{ .r = 0xc3, .g = 0x8c, .b = 0xff };
    try w.writeByte('\n');
    for (logo, 0..) |line, i| {
        try w.writeAll("  ");
        if (opts.color) {
            // Horizontal gradient per character, shifted per row.
            for (line, 0..) |c, x| {
                const t = x + i * 2;
                const den = line.len + logo.len * 2;
                try w.print("\x1b[38;2;{d};{d};{d}m{c}", .{ lerp(from.r, to.r, t, den), lerp(from.g, to.g, t, den), lerp(from.b, to.b, t, den), c });
            }
            try w.writeAll("\x1b[0m");
        } else try w.writeAll(line);
        try w.writeByte('\n');
    }
    try w.writeByte('\n');
    try w.print("  {s}\n\n", .{tagline});
    if (opts.color) try w.writeAll("  \x1b[1mShortcuts\x1b[0m\n") else try w.writeAll("  Shortcuts\n");
    for (shortcuts) |s| {
        var buf: [64]u8 = undefined;
        var kw: Writer = .fixed(&buf);
        writeKey(&kw, s.key) catch {};
        const key = kw.buffered();
        try w.print("    {s}", .{key});
        try w.splatByteAll(' ', 22 -| key.len);
        try w.print("{s}\n", .{s.title});
    }
    try w.writeByte('\n');
    try brand_mod.write(w, brand, "  Edit shortcuts: cmux shortcuts\n  Learn the CLI: cmux help, cmux guide\n\n");
}

const testing = std.testing;

test "unit: cli-welcome: key labels" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "ctrl+shift+n", "Ctrl+Shift+N" },
        .{ "alt+shift+b", "Alt+Shift+B" },
        .{ "ctrl+alt+left", "Ctrl+Alt+Left" },
        .{ "ctrl+b c", "Ctrl+B C" },
        .{ "ctrl+shift+[", "Ctrl+Shift+[" },
        .{ "ctrl++", "Ctrl++" },
        .{ "", "" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        var w: Writer = .fixed(&buf);
        try writeKey(&w, c[0]);
        try testing.expectEqualStrings(c[1], w.buffered());
    }
}

test "unit: cli-welcome: plain output has the shortcut list and pointer" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try write(&aw.writer, .cmux, .{});
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "Shortcuts") != null);
    try testing.expect(std.mem.indexOf(u8, out, "cmux shortcuts") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Ctrl+Shift+P") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[") == null);
}

test "unit: cli-welcome: color output uses truecolor and differs by appearance" {
    var dark: std.Io.Writer.Allocating = .init(testing.allocator);
    defer dark.deinit();
    try write(&dark.writer, .wmux, .{ .color = true });
    var light: std.Io.Writer.Allocating = .init(testing.allocator);
    defer light.deinit();
    try write(&light.writer, .wmux, .{ .color = true, .light = true });
    try testing.expect(std.mem.indexOf(u8, dark.written(), "\x1b[38;2;94;212;255m") != null);
    try testing.expect(!std.mem.eql(u8, dark.written(), light.written()));
    try testing.expect(std.mem.indexOf(u8, dark.written(), "wmux shortcuts") != null);
}

test "unit: cli-welcome: help mentions the default shortcuts" {
    try testing.expect(std.mem.startsWith(u8, help_text, "Usage: cmux welcome\n"));
    try testing.expect(std.mem.indexOf(u8, help_text, "the default shortcuts") != null);
}
