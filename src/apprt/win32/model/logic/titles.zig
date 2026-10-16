//! Pure title helpers of the window model (ARCHITECTURE.md ADR-1.2: std
//! only): the initial tab title derived from a backend argv, the UTF-8
//! title cap, and the UTF-16 transcoding the GDI chrome draws titles
//! with. Moved out of Window.zig in W0-A2.

const std = @import("std");

/// Initial tab title for an inherited backend argv, mirroring the
/// titles the backend picker passes to addTabWithCommand: pwsh /
/// powershell → "PowerShell", cmd → "cmd", wsl with an explicit
/// -d/--distribution → the distro name. Anything else (including a
/// bare wsl.exe) returns null, leaving the default title until the
/// shell's OSC title arrives. The distro case returns a slice into
/// `argv`; addTabWithCommand copies the title before returning.
pub fn titleForCommand(argv: []const []const u8) ?[]const u8 {
    if (argv.len == 0) return null;
    var exe = std.fs.path.basename(argv[0]);
    if (std.ascii.endsWithIgnoreCase(exe, ".exe")) exe = exe[0 .. exe.len - 4];
    if (std.ascii.eqlIgnoreCase(exe, "pwsh") or
        std.ascii.eqlIgnoreCase(exe, "powershell")) return "PowerShell";
    if (std.ascii.eqlIgnoreCase(exe, "cmd")) return "cmd";
    if (std.ascii.eqlIgnoreCase(exe, "wsl")) {
        var i: usize = 1;
        while (i + 1 < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "-d") or
                std.mem.eql(u8, argv[i], "--distribution")) return argv[i + 1];
        }
    }
    return null;
}

/// Cap a UTF-8 string at `max_bytes`, backing up to a sequence
/// boundary so the cut doesn't strand a partial multi-byte sequence
/// (which would invalidate the whole string and drop the title).
pub fn capUtf8(title: []const u8, max_bytes: usize) []const u8 {
    if (title.len <= max_bytes) return title;
    var len = max_bytes;
    while (len > 0 and (title[len] & 0xC0) == 0x80) len -= 1;
    return title[0..len];
}

/// Transcode `text` (UTF-8, or WTF-8 holding unpaired surrogates from a
/// rename) into `out` as UTF-16 for GDI, stopping before the first code
/// point that does not fit; returns the number of units written. Text
/// that is not valid WTF-8 transcodes to nothing (the chrome showed an
/// empty title for undecodable input before W0-A2 too).
pub fn toUtf16(out: []u16, text: []const u8) usize {
    const view = std.unicode.Wtf8View.init(text) catch return 0;
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x10000) {
            if (n + 1 > out.len) break;
            out[n] = @intCast(cp);
            n += 1;
        } else {
            if (n + 2 > out.len) break;
            const v = cp - 0x10000;
            out[n] = @intCast(0xD800 + (v >> 10));
            out[n + 1] = @intCast(0xDC00 + (v & 0x3FF));
            n += 2;
        }
    }
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: model: title cap ascii passes through" {
    try testing.expectEqualStrings("hello", capUtf8("hello", 255));
}

test "unit: model: title cap exact boundary is unchanged" {
    try testing.expectEqualStrings("abcd", capUtf8("abcd", 4));
}

test "unit: model: title cap truncates past the boundary" {
    try testing.expectEqualStrings("abc", capUtf8("abcdef", 3));
}

test "unit: model: title cap backs up over a split multi-byte sequence" {
    // "aé" = 61 C3 A9; a cap of 2 lands inside é.
    try testing.expectEqualStrings("a", capUtf8("a\xC3\xA9", 2));
    // 4-byte emoji (U+1F600 = F0 9F 98 80) split at every interior byte.
    const emoji = "ab\xF0\x9F\x98\x80";
    try testing.expectEqualStrings("ab", capUtf8(emoji, 3));
    try testing.expectEqualStrings("ab", capUtf8(emoji, 4));
    try testing.expectEqualStrings("ab", capUtf8(emoji, 5));
}

test "unit: model: title cap at a sequence boundary keeps the sequence" {
    try testing.expectEqualStrings("a\xC3\xA9", capUtf8("a\xC3\xA9b", 3));
}

test "unit: model: title cap empty and degenerate inputs" {
    try testing.expectEqualStrings("", capUtf8("", 255));
    try testing.expectEqualStrings("", capUtf8("abc", 0));
    // All continuation bytes (malformed input): backs up to empty
    // rather than returning a partial sequence.
    try testing.expectEqualStrings("", capUtf8("\x80\x80\x80", 2));
}

test "unit: model: title cap=1 boundary" {
    // cap=1 ASCII keeps a single byte (the fast path's smallest cut).
    try testing.expectEqualStrings("a", capUtf8("abc", 1));
    // cap=1 inside a 2-byte sequence backs up to empty.
    try testing.expectEqualStrings("", capUtf8("\xC3\xA9x", 1));
    // cap=1 after the lead byte of a 4-byte emoji backs up to empty.
    try testing.expectEqualStrings("", capUtf8("\xF0\x9F\x98\x80", 1));
}

test "unit: model: inherit title maps the picker backends" {
    try testing.expectEqualStrings("PowerShell", titleForCommand(&.{"pwsh.exe"}).?);
    try testing.expectEqualStrings("PowerShell", titleForCommand(&.{"powershell.exe"}).?);
    try testing.expectEqualStrings("cmd", titleForCommand(&.{"cmd.exe"}).?);
    // The exact argv the backend picker stores for a distro tab.
    try testing.expectEqualStrings(
        "Ubuntu-24.04",
        titleForCommand(&.{ "wsl.exe", "--cd", "~", "-d", "Ubuntu-24.04" }).?,
    );
}

test "unit: model: inherit title handles paths, case, and missing extension" {
    try testing.expectEqualStrings(
        "PowerShell",
        titleForCommand(&.{"C:\\Program Files\\PowerShell\\7\\pwsh.exe"}).?,
    );
    try testing.expectEqualStrings("cmd", titleForCommand(&.{"CMD.EXE"}).?);
    try testing.expectEqualStrings("Debian", titleForCommand(&.{ "wsl", "-d", "Debian" }).?);
    try testing.expectEqualStrings(
        "Debian",
        titleForCommand(&.{ "wsl.exe", "--distribution", "Debian" }).?,
    );
}

test "unit: model: inherit title unknown or degenerate argv keeps the default" {
    try testing.expectEqual(@as(?[]const u8, null), titleForCommand(&.{}));
    try testing.expectEqual(@as(?[]const u8, null), titleForCommand(&.{"nu.exe"}));
    // wsl without an explicit distro: nothing to derive a name from.
    try testing.expectEqual(@as(?[]const u8, null), titleForCommand(&.{"wsl.exe"}));
    // Trailing -d with no value must not read past the argv.
    try testing.expectEqual(@as(?[]const u8, null), titleForCommand(&.{ "wsl.exe", "-d" }));
}

test "unit: model: inherit title resolves full paths and mixed-case exe names" {
    // basename strips the directory; the exe name and the .exe
    // extension both match case-insensitively.
    try testing.expectEqualStrings(
        "Ubuntu",
        titleForCommand(&.{ "C:\\Windows\\System32\\wsl.exe", "-d", "Ubuntu" }).?,
    );
    try testing.expectEqualStrings(
        "Ubuntu",
        titleForCommand(&.{ "WsL.ExE", "-d", "Ubuntu" }).?,
    );
    try testing.expectEqualStrings("PowerShell", titleForCommand(&.{"PoWeRsHeLl.ExE"}).?);
    try testing.expectEqualStrings("PowerShell", titleForCommand(&.{"Pwsh.EXE"}).?);
    // Single-element argv without an extension still resolves.
    try testing.expectEqualStrings("PowerShell", titleForCommand(&.{"powershell"}).?);
}

test "unit: model: inherit title keeps a distro name containing spaces" {
    // The name is a single argv element; spaces inside it belong to
    // the distro name, not to argument splitting.
    try testing.expectEqualStrings(
        "openSUSE Leap 15.6",
        titleForCommand(&.{ "wsl.exe", "--cd", "~", "-d", "openSUSE Leap 15.6" }).?,
    );
    try testing.expectEqualStrings(
        "Ubuntu 24.04 LTS",
        titleForCommand(&.{ "wsl.exe", "--distribution", "Ubuntu 24.04 LTS" }).?,
    );
}

test "unit: model: inherit title only recognizes the exact two-token distro flag" {
    // Only the exact "-d <name>" / "--distribution <name>" forms the
    // picker writes are recognized; near misses fall back to the
    // default title (a harmless fallback, never a wrong distro name).
    try testing.expectEqual(
        @as(?[]const u8, null),
        titleForCommand(&.{ "wsl.exe", "-D", "Ubuntu" }),
    );
    try testing.expectEqual(
        @as(?[]const u8, null),
        titleForCommand(&.{ "wsl.exe", "-d=Ubuntu" }),
    );
    // --distribution as the LAST token has no value to take.
    try testing.expectEqual(
        @as(?[]const u8, null),
        titleForCommand(&.{ "wsl.exe", "--distribution" }),
    );
}

test "unit: model: title toUtf16 transcodes and stops at the unit cap" {
    var buf: [8]u16 = undefined;
    // ASCII and BMP.
    const n = toUtf16(&buf, "a\xC3\xA9b");
    try testing.expectEqualSlices(u16, &.{ 'a', 0xE9, 'b' }, buf[0..n]);
    // An astral code point is a surrogate pair; one that does not fit
    // is dropped whole.
    var two: [2]u16 = undefined;
    try testing.expectEqual(@as(usize, 2), toUtf16(&two, "\xF0\x9F\x98\x80"));
    try testing.expectEqualSlices(u16, &.{ 0xD83D, 0xDE00 }, &two);
    var three: [3]u16 = undefined;
    // "x" plus one pair fill 3 units; the second pair would need 2 more.
    try testing.expectEqual(@as(usize, 3), toUtf16(&three, "x\xF0\x9F\x98\x80\xF0\x9F\x98\x80"));
    // Exactly at the cap.
    var cap: [3]u16 = undefined;
    try testing.expectEqual(@as(usize, 3), toUtf16(&cap, "abcdef"));
}

test "unit: model: title toUtf16 round-trips WTF-8 surrogate halves" {
    // A rename holding a lone high surrogate survives WTF-16 -> WTF-8 ->
    // UTF-16 unchanged.
    const units = [_]u16{ 'a', 0xD800, 'b' };
    const wtf8 = try std.unicode.wtf16LeToWtf8Alloc(testing.allocator, &units);
    defer testing.allocator.free(wtf8);
    var buf: [8]u16 = undefined;
    const n = toUtf16(&buf, wtf8);
    try testing.expectEqualSlices(u16, &units, buf[0..n]);
}

test "unit: model: title toUtf16 of invalid text is empty" {
    var buf: [8]u16 = undefined;
    try testing.expectEqual(@as(usize, 0), toUtf16(&buf, "ab\xFFcd"));
    try testing.expectEqual(@as(usize, 0), toUtf16(&buf, ""));
}
