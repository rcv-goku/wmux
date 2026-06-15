//! WSL (Windows Subsystem for Linux) distribution enumeration.
//!
//! WSL stores per-distribution metadata in the registry under
//! `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss`. Each subkey is
//! a GUID containing (among others) the values `DistributionName`
//! (REG_SZ), `Version` (REG_DWORD, 1 for WSL1 / 2 for WSL2), and `State`
//! (REG_DWORD, 1 when fully installed). The `Lxss` key itself has a
//! `DefaultDistribution` REG_SZ value naming the GUID subkey of the
//! default distribution.
//!
//! This module is self-contained (std-only) so it can be tested
//! standalone: `zig test src/os/wsl.zig -target x86_64-windows-gnu`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;

/// Registry path (relative to HKEY_CURRENT_USER) where WSL stores its
/// per-distribution metadata.
const lxss_path = "Software\\Microsoft\\Windows\\CurrentVersion\\Lxss";

/// The `State` DWORD value of a fully installed distribution. Other
/// values indicate an install/uninstall/import in progress.
const state_installed: u32 = 1;

/// A single installed WSL distribution.
pub const Distro = struct {
    /// The distribution name, e.g. "Ubuntu". UTF-8, allocated.
    name: []const u8,

    /// The registry subkey name for this distribution. This is a GUID
    /// string including braces, e.g. "{12345678-...}". UTF-8, allocated.
    guid: []const u8,

    /// True if this is the default distribution (the one `wsl.exe`
    /// launches when no `-d` flag is given).
    is_default: bool,

    /// The WSL version of this distribution: 1 (WSL1) or 2 (WSL2).
    version: u32,

    pub fn deinit(self: Distro, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.guid);
    }
};

/// List the fully installed WSL distributions for the current user.
///
/// If WSL is not installed (the Lxss registry key is absent) this
/// returns an empty slice. Malformed registry subkeys (missing or
/// wrongly-typed values, invalid UTF-16) are skipped. The result must
/// be freed with `free`.
pub fn list(alloc: Allocator) ![]Distro {
    return switch (builtin.os.tag) {
        .windows => try listWindows(alloc),

        // WSL is a Windows-only concept. Returning an empty slice (rather
        // than a compile error) lets callers compile cross-platform.
        else => try alloc.alloc(Distro, 0),
    };
}

/// Free a slice of distros returned by `list`.
pub fn free(alloc: Allocator, distros: []const Distro) void {
    for (distros) |d| d.deinit(alloc);
    alloc.free(distros);
}

/// Build the command to launch a shell in the given WSL distribution,
/// e.g. `wsl.exe --cd ~ -d Ubuntu`. The distro name is quoted according
/// to Windows command line rules if necessary. The result is allocated
/// and owned by the caller.
pub fn commandForDistro(alloc: Allocator, distro_name: []const u8) ![]const u8 {
    var cmd: std.ArrayList(u8) = .empty;
    errdefer cmd.deinit(alloc);
    try cmd.appendSlice(alloc, "wsl.exe --cd ~ -d ");
    try appendArg(&cmd, alloc, distro_name);
    return try cmd.toOwnedSlice(alloc);
}

//-------------------------------------------------------------------
// Pure helpers (no registry I/O, unit-testable on any platform)

/// Convert a UTF-16 registry string to allocated UTF-8. Registry string
/// data usually includes the NUL terminator in its reported length, so
/// the input is trimmed at the first NUL before conversion.
fn utf16ToUtf8Alloc(alloc: Allocator, utf16: []const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(alloc, trimNul(utf16));
}

/// Slice the input up to (not including) the first NUL code unit. The
/// registry does not guarantee string data is NUL-terminated, so data
/// without any NUL is returned unchanged.
fn trimNul(data: []const u16) []const u16 {
    const len = std.mem.indexOfScalar(u16, data, 0) orelse data.len;
    return data[0..len];
}

/// ASCII case-insensitive equality for UTF-16 strings. Sufficient for
/// comparing GUID strings, which are pure ASCII but appear in the
/// registry with inconsistent casing.
fn utf16EqlIgnoreCase(a: []const u16, b: []const u16) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| if (asciiLower16(ca) != asciiLower16(cb)) return false;
    return true;
}

fn asciiLower16(c: u16) u16 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

/// Append a single command line argument to `cmd`, quoting it according
/// to Windows (CommandLineToArgvW/MSVCRT) rules if it contains
/// whitespace or quotes.
fn appendArg(
    cmd: *std.ArrayList(u8),
    alloc: Allocator,
    arg: []const u8,
) Allocator.Error!void {
    if (!argNeedsQuoting(arg)) {
        try cmd.appendSlice(alloc, arg);
        return;
    }

    try cmd.append(alloc, '"');
    var i: usize = 0;
    while (i < arg.len) {
        // Count a run of backslashes. Backslashes are only special when
        // they precede a double quote (or our closing quote).
        var backslashes: usize = 0;
        while (i < arg.len and arg[i] == '\\') : (i += 1) backslashes += 1;

        if (i == arg.len) {
            // Trailing backslashes are doubled so they don't escape the
            // closing quote.
            try cmd.appendNTimes(alloc, '\\', backslashes * 2);
        } else if (arg[i] == '"') {
            // Double the backslashes, then escape the quote itself.
            try cmd.appendNTimes(alloc, '\\', backslashes * 2 + 1);
            try cmd.append(alloc, '"');
            i += 1;
        } else {
            try cmd.appendNTimes(alloc, '\\', backslashes);
            try cmd.append(alloc, arg[i]);
            i += 1;
        }
    }
    try cmd.append(alloc, '"');
}

fn argNeedsQuoting(arg: []const u8) bool {
    if (arg.len == 0) return true;
    for (arg) |c| switch (c) {
        ' ', '\t', '"' => return true,
        else => {},
    };
    return false;
}

//-------------------------------------------------------------------
// Registry I/O (Windows only)

const advapi32 = windows.advapi32;

// Win32 error codes (winerror.h) returned as LSTATUS by registry APIs.
const reg_success: windows.LSTATUS = 0; // ERROR_SUCCESS
const reg_file_not_found: windows.LSTATUS = 2; // ERROR_FILE_NOT_FOUND
const reg_no_more_items: windows.LSTATUS = 259; // ERROR_NO_MORE_ITEMS

// Not exposed by std.os.windows.advapi32 so we declare it ourselves.
// https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regenumkeyexw
extern "advapi32" fn RegEnumKeyExW(
    hKey: windows.HKEY,
    dwIndex: windows.DWORD,
    lpName: [*]u16,
    lpcchName: *windows.DWORD,
    lpReserved: ?*windows.DWORD,
    lpClass: ?windows.LPWSTR,
    lpcchClass: ?*windows.DWORD,
    lpftLastWriteTime: ?*windows.FILETIME,
) callconv(.winapi) windows.LSTATUS;

fn listWindows(alloc: Allocator) ![]Distro {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;

    var lxss: windows.HKEY = undefined;
    switch (advapi32.RegOpenKeyExW(
        windows.HKEY_CURRENT_USER,
        L(lxss_path),
        0,
        windows.KEY_READ,
        &lxss,
    )) {
        reg_success => {},

        // No Lxss key means WSL was never installed: no distros.
        reg_file_not_found => return try alloc.alloc(Distro, 0),

        else => return error.Unexpected,
    }
    defer _ = advapi32.RegCloseKey(lxss);

    // The default distribution is recorded as a GUID string value on
    // the Lxss key itself. GUID strings are 38 characters.
    var default_buf: [64]u16 = undefined;
    const default_guid: ?[]const u16 = queryString(
        lxss,
        L("DefaultDistribution"),
        &default_buf,
    );

    var distros: std.ArrayList(Distro) = .empty;
    errdefer {
        for (distros.items) |d| d.deinit(alloc);
        distros.deinit(alloc);
    }

    // Registry key names are limited to 255 characters.
    var subkey_buf: [256]u16 = undefined;
    var index: windows.DWORD = 0;
    while (true) : (index += 1) {
        var subkey_len: windows.DWORD = subkey_buf.len;
        switch (RegEnumKeyExW(
            lxss,
            index,
            &subkey_buf,
            &subkey_len,
            null,
            null,
            null,
            null,
        )) {
            reg_success => {},
            reg_no_more_items => break,

            // Skip subkeys we fail to enumerate; don't fail the whole
            // listing for one bad entry.
            else => continue,
        }
        if (subkey_len >= subkey_buf.len) continue;
        subkey_buf[subkey_len] = 0;
        const subkey = subkey_buf[0..subkey_len :0];

        const maybe_distro = try readDistro(alloc, lxss, subkey, default_guid);
        const distro = maybe_distro orelse continue;
        errdefer distro.deinit(alloc);
        try distros.append(alloc, distro);
    }

    return try distros.toOwnedSlice(alloc);
}

/// Read a single distribution from its Lxss GUID subkey. Returns null
/// if the subkey is malformed (missing/wrongly-typed values, invalid
/// UTF-16) or the distribution is not fully installed.
fn readDistro(
    alloc: Allocator,
    lxss: windows.HKEY,
    subkey: [:0]const u16,
    default_guid: ?[]const u16,
) Allocator.Error!?Distro {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;

    var key: windows.HKEY = undefined;
    if (advapi32.RegOpenKeyExW(
        lxss,
        subkey,
        0,
        windows.KEY_READ,
        &key,
    ) != reg_success) return null;
    defer _ = advapi32.RegCloseKey(key);

    // Only include fully installed distributions. Anything else is mid
    // install/uninstall/import and can't be launched.
    const state = queryDword(key, L("State")) orelse return null;
    if (state != state_installed) return null;

    const version = queryDword(key, L("Version")) orelse return null;

    var name_buf: [512]u16 = undefined;
    const name_utf16 = queryString(
        key,
        L("DistributionName"),
        &name_buf,
    ) orelse return null;
    if (name_utf16.len == 0) return null;

    const name = utf16ToUtf8Alloc(alloc, name_utf16) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Invalid UTF-16 means a malformed subkey: skip it.
        else => return null,
    };
    errdefer alloc.free(name);

    const guid = utf16ToUtf8Alloc(alloc, subkey) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    errdefer alloc.free(guid);

    return .{
        .name = name,
        .guid = guid,
        .is_default = if (default_guid) |d| utf16EqlIgnoreCase(subkey, d) else false,
        .version = version,
    };
}

/// Query a REG_SZ value into the provided buffer, returning the string
/// trimmed of any NUL terminator. Returns null if the value is missing,
/// not a string, or too large for the buffer.
fn queryString(
    key: windows.HKEY,
    value_name: [*:0]const u16,
    buf: []u16,
) ?[]const u16 {
    var vtype: windows.DWORD = 0;
    var byte_len: windows.DWORD = @intCast(buf.len * @sizeOf(u16));
    const rc = advapi32.RegQueryValueExW(
        key,
        value_name,
        null,
        &vtype,
        @ptrCast(buf.ptr),
        &byte_len,
    );
    if (rc != reg_success) return null;
    if (vtype != windows.REG.SZ) return null;
    return trimNul(buf[0 .. byte_len / @sizeOf(u16)]);
}

/// Query a REG_DWORD value. Returns null if the value is missing or not
/// a DWORD.
fn queryDword(key: windows.HKEY, value_name: [*:0]const u16) ?u32 {
    var vtype: windows.DWORD = 0;
    var value: u32 = 0;
    var byte_len: windows.DWORD = @sizeOf(u32);
    const rc = advapi32.RegQueryValueExW(
        key,
        value_name,
        null,
        &vtype,
        @ptrCast(&value),
        &byte_len,
    );
    if (rc != reg_success) return null;
    if (vtype != windows.REG.DWORD or byte_len != @sizeOf(u32)) return null;
    return value;
}

//-------------------------------------------------------------------
// Tests

test "wsl trimNul" {
    const testing = std.testing;

    // Trailing NUL terminator (the usual registry case)
    try testing.expectEqualSlices(
        u16,
        &[_]u16{ 'a', 'b' },
        trimNul(&[_]u16{ 'a', 'b', 0 }),
    );

    // No NUL at all
    try testing.expectEqualSlices(
        u16,
        &[_]u16{ 'a', 'b' },
        trimNul(&[_]u16{ 'a', 'b' }),
    );

    // Embedded NUL cuts the string short
    try testing.expectEqualSlices(
        u16,
        &[_]u16{'a'},
        trimNul(&[_]u16{ 'a', 0, 'b', 0 }),
    );

    // Empty and NUL-only inputs
    try testing.expectEqualSlices(u16, &[_]u16{}, trimNul(&[_]u16{}));
    try testing.expectEqualSlices(u16, &[_]u16{}, trimNul(&[_]u16{ 0, 0 }));
}

test "wsl utf16ToUtf8Alloc" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Plain ASCII with trailing NUL
    {
        const result = try utf16ToUtf8Alloc(alloc, &[_]u16{ 'U', 'b', 'u', 'n', 't', 'u', 0 });
        defer alloc.free(result);
        try testing.expectEqualStrings("Ubuntu", result);
    }

    // No NUL terminator
    {
        const result = try utf16ToUtf8Alloc(alloc, &[_]u16{ 'a', 'b' });
        defer alloc.free(result);
        try testing.expectEqualStrings("ab", result);
    }

    // Non-ASCII BMP characters (é = U+00E9, 日 = U+65E5)
    {
        const result = try utf16ToUtf8Alloc(alloc, &[_]u16{ 0x00E9, 0x65E5, 0 });
        defer alloc.free(result);
        try testing.expectEqualStrings("é日", result);
    }

    // Surrogate pair (U+1F600 = 😀)
    {
        const result = try utf16ToUtf8Alloc(alloc, &[_]u16{ 0xD83D, 0xDE00, 0 });
        defer alloc.free(result);
        try testing.expectEqualStrings("😀", result);
    }

    // Unpaired high surrogate is invalid UTF-16
    try testing.expectError(
        error.DanglingSurrogateHalf,
        utf16ToUtf8Alloc(alloc, &[_]u16{ 'a', 0xD83D, 0 }),
    );

    // Empty input
    {
        const result = try utf16ToUtf8Alloc(alloc, &[_]u16{0});
        defer alloc.free(result);
        try testing.expectEqualStrings("", result);
    }
}

test "wsl utf16EqlIgnoreCase" {
    const testing = std.testing;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;

    try testing.expect(utf16EqlIgnoreCase(
        L("{ABCDEF01-2345-6789-ABCD-EF0123456789}"),
        L("{abcdef01-2345-6789-abcd-ef0123456789}"),
    ));
    try testing.expect(utf16EqlIgnoreCase(L(""), L("")));
    try testing.expect(!utf16EqlIgnoreCase(L("{abc}"), L("{abd}")));
    try testing.expect(!utf16EqlIgnoreCase(L("{abc}"), L("{abc")));

    // Case-insensitivity must only apply to ASCII letters: 'Z'+32 is
    // '{' but they are not the same character.
    try testing.expect(!utf16EqlIgnoreCase(L("{"), L("Z")));
}

test "wsl commandForDistro" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Simple name: no quoting
    {
        const cmd = try commandForDistro(alloc, "Ubuntu");
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d Ubuntu", cmd);
    }

    // Name containing spaces must be quoted
    {
        const cmd = try commandForDistro(alloc, "Ubuntu 22.04 LTS");
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d \"Ubuntu 22.04 LTS\"", cmd);
    }

    // Empty name still produces an (empty) quoted argument
    {
        const cmd = try commandForDistro(alloc, "");
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d \"\"", cmd);
    }
}

test "wsl commandForDistro quoting edge cases" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Embedded quote is escaped
    {
        const cmd = try commandForDistro(alloc, "my\"distro");
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d \"my\\\"distro\"", cmd);
    }

    // Backslashes before a quote are doubled; lone backslashes are not
    {
        const cmd = try commandForDistro(alloc, "a\\b \\\"c");
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d \"a\\b \\\\\\\"c\"", cmd);
    }

    // Trailing backslashes are doubled so they don't escape the
    // closing quote
    {
        const cmd = try commandForDistro(alloc, "dist ro\\");
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d \"dist ro\\\\\"", cmd);
    }

    // Backslashes without whitespace/quotes need no quoting at all
    {
        const cmd = try commandForDistro(alloc, "a\\b");
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d a\\b", cmd);
    }
}

test "wsl commandForDistro trailing backslash torture" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Backslash directly before an embedded quote at the end of the
    // name: the run is doubled AND the quote escaped → \\\" inside.
    {
        const cmd = try commandForDistro(alloc, "dist\\\"");
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d \"dist\\\\\\\"\"", cmd);
    }

    // Two trailing backslashes in a quoted name double to four so the
    // closing quote survives.
    {
        const cmd = try commandForDistro(alloc, "a b\\\\");
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d \"a b\\\\\\\\\"", cmd);
    }

    // Space followed by a single trailing backslash.
    {
        const cmd = try commandForDistro(alloc, " \\");
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d \" \\\\\"", cmd);
    }

    // A lone backslash with no whitespace/quote needs no quoting at all
    // and is passed through verbatim.
    {
        const cmd = try commandForDistro(alloc, "\\");
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d \\", cmd);
    }
}

test "wsl commandForDistro quote-heavy names" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A name that is just one double quote.
    {
        const cmd = try commandForDistro(alloc, "\"");
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d \"\\\"\"", cmd);
    }

    // Two consecutive quotes, each escaped independently.
    {
        const cmd = try commandForDistro(alloc, "\"\"");
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d \"\\\"\\\"\"", cmd);
    }

    // Quote mid-name plus trailing backslash: both rules at once.
    {
        const cmd = try commandForDistro(alloc, "a\"b\\");
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d \"a\\\"b\\\\\"", cmd);
    }

    // Two backslashes before a mid-name quote: 2*2+1 = 5 backslashes.
    {
        const cmd = try commandForDistro(alloc, "a\\\\\"b");
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d \"a\\\\\\\\\\\"b\"", cmd);
    }
}

test "wsl commandForDistro tab handling" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A tab triggers quoting just like a space.
    {
        const cmd = try commandForDistro(alloc, "a\tb");
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d \"a\tb\"", cmd);
    }

    // A name that is only a tab.
    {
        const cmd = try commandForDistro(alloc, "\t");
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d \"\t\"", cmd);
    }

    // Tab followed by a quote: tab is not a backslash, so only the
    // quote is escaped.
    {
        const cmd = try commandForDistro(alloc, "\t\"");
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d \"\t\\\"\"", cmd);
    }
}

test "wsl commandForDistro max-length names" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Registry key names (and thus practical distro names) are capped at
    // 255 characters. A plain max-length name is passed unquoted.
    {
        const long = "a" ** 255;
        const cmd = try commandForDistro(alloc, long);
        defer alloc.free(cmd);
        try testing.expectEqualStrings("wsl.exe --cd ~ -d " ++ long, cmd);
        try testing.expectEqual(@as(usize, 18 + 255), cmd.len);
    }

    // Max-length name with a space and a trailing backslash exercises
    // quoting + trailing-run doubling at the length limit.
    {
        const long = ("a" ** 253) ++ " \\";
        const cmd = try commandForDistro(alloc, long);
        defer alloc.free(cmd);
        try testing.expectEqualStrings(
            "wsl.exe --cd ~ -d \"" ++ ("a" ** 253) ++ " \\\\\"",
            cmd,
        );
    }
}

test "wsl utf16 lone surrogate halves" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Lone high surrogate at end of input.
    try testing.expectError(
        error.DanglingSurrogateHalf,
        utf16ToUtf8Alloc(alloc, &[_]u16{0xD800}),
    );

    // High surrogate followed by a non-surrogate.
    try testing.expectError(
        error.ExpectedSecondSurrogateHalf,
        utf16ToUtf8Alloc(alloc, &[_]u16{ 0xD83D, 'a' }),
    );

    // Lone low surrogate.
    try testing.expectError(
        error.UnexpectedSecondSurrogateHalf,
        utf16ToUtf8Alloc(alloc, &[_]u16{0xDE00}),
    );

    // Low-then-high (reversed pair).
    try testing.expectError(
        error.UnexpectedSecondSurrogateHalf,
        utf16ToUtf8Alloc(alloc, &[_]u16{ 0xDE00, 0xD83D }),
    );

    // A surrogate pair split by an embedded NUL: trimNul cuts after the
    // high half, leaving it dangling.
    try testing.expectError(
        error.DanglingSurrogateHalf,
        utf16ToUtf8Alloc(alloc, &[_]u16{ 0xD83D, 0, 0xDE00 }),
    );
}

test "wsl utf16 BMP boundary and astral chars" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // U+D7FF: last code point before the surrogate range.
    {
        const result = try utf16ToUtf8Alloc(alloc, &[_]u16{ 0xD7FF, 0 });
        defer alloc.free(result);
        try testing.expectEqualStrings("\u{D7FF}", result);
    }

    // U+E000: first code point after the surrogate range.
    {
        const result = try utf16ToUtf8Alloc(alloc, &[_]u16{ 0xE000, 0 });
        defer alloc.free(result);
        try testing.expectEqualStrings("\u{E000}", result);
    }

    // U+FFFD (replacement char) and U+FFFF (last BMP code unit) both
    // round-trip; the converter does not reject noncharacters.
    {
        const result = try utf16ToUtf8Alloc(alloc, &[_]u16{ 0xFFFD, 0xFFFF, 0 });
        defer alloc.free(result);
        try testing.expectEqualStrings("\u{FFFD}\u{FFFF}", result);
    }

    // U+10000: the first astral code point (lowest surrogate pair).
    {
        const result = try utf16ToUtf8Alloc(alloc, &[_]u16{ 0xD800, 0xDC00, 0 });
        defer alloc.free(result);
        try testing.expectEqualStrings("\u{10000}", result);
    }
}

test "wsl utf16EqlIgnoreCase non-ASCII stays case-sensitive" {
    const testing = std.testing;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;

    // ASCII letters fold.
    try testing.expect(utf16EqlIgnoreCase(L("A"), L("a")));
    try testing.expect(utf16EqlIgnoreCase(L("Z"), L("z")));
    try testing.expect(utf16EqlIgnoreCase(L("Ubuntu-22.04"), L("UBUNTU-22.04")));

    // Latin-1 É (U+00C9) vs é (U+00E9): differ by 0x20 like ASCII case
    // pairs, but they are non-ASCII so they must NOT fold.
    try testing.expect(!utf16EqlIgnoreCase(L("É"), L("é")));

    // Cyrillic А (U+0410) vs а (U+0430): also a 0x20 pair, also no fold.
    try testing.expect(!utf16EqlIgnoreCase(L("А"), L("а")));

    // Fullwidth Ａ (U+FF21) vs ａ (U+FF41): no fold.
    try testing.expect(!utf16EqlIgnoreCase(L("Ａ"), L("ａ")));

    // Characters just outside A-Z: '@' (0x40) vs '`' (0x60) and
    // '[' (0x5B) vs '{' (0x7B) differ by 0x20 but must not fold.
    try testing.expect(!utf16EqlIgnoreCase(&[_]u16{'@'}, &[_]u16{'`'}));
    try testing.expect(!utf16EqlIgnoreCase(&[_]u16{'['}, &[_]u16{'{'}));

    // Raw surrogate code units compare bitwise (no decoding involved).
    try testing.expect(utf16EqlIgnoreCase(&[_]u16{0xD800}, &[_]u16{0xD800}));
    try testing.expect(!utf16EqlIgnoreCase(&[_]u16{0xD800}, &[_]u16{0xD801}));
}

test "wsl list" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const distros = try list(testing.allocator);
    defer free(testing.allocator, distros);

    // Any count is valid (including zero on machines without WSL), but
    // every returned entry must be well-formed.
    for (distros) |d| {
        try testing.expect(d.name.len > 0);
        try testing.expect(d.guid.len > 0);
    }
}
