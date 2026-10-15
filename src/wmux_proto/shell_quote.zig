//! Command quoting for pwsh, cmd and POSIX shells, e.g. agent resume commands
//! (ADR-10.7): the result is typed into an interactive shell, so it must
//! reproduce argv exactly and never let a metacharacter run.
//!
//! - POSIX (bash, zsh, sh, WSL): bare when safe, else single quotes with `'`
//!   written as `'\''`.
//! - pwsh / Windows PowerShell: `& 'prog' 'arg' …`; every token single-quoted,
//!   with `'` and the typographic single quotes U+2018–U+201B doubled.
//! - cmd.exe: CommandLineToArgvW quoting (`win_argv.zig`), then every cmd
//!   metacharacter (including `"`) caret-escaped so cmd never enters a quoted
//!   state, and `%` neutralized; the program token keeps real quotes so paths
//!   with spaces resolve.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const win_argv = @import("win_argv.zig");

pub const Shell = enum {
    posix,
    pwsh,
    cmd,

    /// Maps a shell executable or kind name (`pwsh.exe`, `C:\…\powershell.exe`,
    /// `bash`, `wsl`, `cmd`) to its quoting family, ignoring case, directory and
    /// a `.exe` suffix.
    pub fn fromName(name: []const u8) ?Shell {
        var base = name;
        if (std.mem.lastIndexOfAny(u8, base, "\\/")) |i| base = base[i + 1 ..];
        if (base.len > 4 and std.ascii.eqlIgnoreCase(base[base.len - 4 ..], ".exe")) base = base[0 .. base.len - 4];
        const table = [_]struct { []const u8, Shell }{
            .{ "pwsh", .pwsh },   .{ "powershell", .pwsh }, .{ "cmd", .cmd },
            .{ "bash", .posix },  .{ "sh", .posix },        .{ "zsh", .posix },
            .{ "dash", .posix },  .{ "ksh", .posix },       .{ "wsl", .posix },
            .{ "posix", .posix },
        };
        for (table) |e| if (std.ascii.eqlIgnoreCase(base, e[0])) return e[1];
        return null;
    }
};

pub const Error = error{Unrepresentable} || Writer.Error;

fn posixSafe(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '@', '%', '+', '=', ':', ',', '.', '/', '-' => true,
        else => false,
    };
}

/// POSIX sh word: bare when non-empty and made of `[A-Za-z0-9_@%+=:,./-]`,
/// else single-quoted. NUL cannot be carried.
pub fn writePosix(w: *Writer, arg: []const u8) Error!void {
    if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.Unrepresentable;
    var bare = arg.len > 0;
    for (arg) |c| if (!posixSafe(c)) {
        bare = false;
        break;
    };
    if (bare) return w.writeAll(arg);
    try w.writeByte('\'');
    for (arg) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeByte('\'');
}

/// PowerShell single-quoted string. PowerShell also treats U+2018–U+201B as
/// single quotes, so those are doubled too. NUL cannot be carried.
pub fn writePwsh(w: *Writer, arg: []const u8) Error!void {
    if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.Unrepresentable;
    try w.writeByte('\'');
    var i: usize = 0;
    while (i < arg.len) {
        if (arg[i] == '\'') {
            try w.writeAll("''");
            i += 1;
            continue;
        }
        // U+2018..U+201B = E2 80 98..9B
        if (i + 2 < arg.len and arg[i] == 0xE2 and arg[i + 1] == 0x80 and arg[i + 2] >= 0x98 and arg[i + 2] <= 0x9B) {
            try w.writeAll(arg[i .. i + 3]);
            try w.writeAll(arg[i .. i + 3]);
            i += 3;
            continue;
        }
        try w.writeByte(arg[i]);
        i += 1;
    }
    try w.writeByte('\'');
}

const cmd_meta = "^&|<>()\"!";

/// `%` in a cmd command line: a literal `%` followed by `%cd:~,%` (expands
/// to nothing), so `%name%` can never form.
const cmd_percent = "%%cd:~,%";

fn writeCmdEscaped(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| {
        if (c == '%') {
            try w.writeAll(cmd_percent);
        } else if (std.mem.indexOfScalar(u8, cmd_meta, c) != null) {
            try w.writeByte('^');
            try w.writeByte(c);
        } else try w.writeByte(c);
    }
}

/// One cmd.exe argument (not the program token): argv-quoted, then
/// caret-escaped. CR, LF and NUL cannot be carried.
pub fn writeCmdArg(w: *Writer, arg: []const u8) Error!void {
    if (std.mem.indexOfAny(u8, arg, "\r\n\x00") != null) return error.Unrepresentable;
    var esc: CmdEscapeWriter = .{ .out = w, .interface = .{ .vtable = &.{ .drain = CmdEscapeWriter.drain }, .buffer = &.{} } };
    try win_argv.writeArg(&esc.interface, arg);
}

/// Unbuffered adapter that caret-escapes everything written through it.
const CmdEscapeWriter = struct {
    out: *Writer,
    interface: Writer,

    fn drain(io_w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *CmdEscapeWriter = @alignCast(@fieldParentPtr("interface", io_w));
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try writeCmdEscaped(self.out, d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try writeCmdEscaped(self.out, last);
            n += last.len;
        }
        return n;
    }
};

/// The program token for cmd.exe: wrapped in real quotes when it contains a
/// space, tab or metacharacter (inside quotes cmd treats them literally), `%`
/// neutralized. `"`, CR, LF and NUL cannot be carried.
pub fn writeCmdProgram(w: *Writer, program: []const u8) Error!void {
    if (program.len == 0 or std.mem.indexOfAny(u8, program, "\"\r\n\x00") != null) return error.Unrepresentable;
    const quote = std.mem.indexOfAny(u8, program, " \t^&|<>()!,;=") != null;
    if (quote) try w.writeByte('"');
    for (program) |c| {
        if (c == '%') try w.writeAll(cmd_percent) else try w.writeByte(c);
    }
    if (quote) try w.writeByte('"');
}

/// One argument (not the program) for `shell`.
pub fn writeArg(w: *Writer, shell: Shell, arg: []const u8) Error!void {
    return switch (shell) {
        .posix => writePosix(w, arg),
        .pwsh => writePwsh(w, arg),
        .cmd => writeCmdArg(w, arg),
    };
}

/// A full command line for `shell` from `argv` (argv[0] = program):
/// posix `prog 'a b'`, pwsh `& 'prog' 'a b'`, cmd `prog "a b"` (escaped).
/// An empty argv writes nothing.
pub fn writeCommand(w: *Writer, shell: Shell, argv: []const []const u8) Error!void {
    if (argv.len == 0) return;
    switch (shell) {
        .posix => try writePosix(w, argv[0]),
        .pwsh => {
            try w.writeAll("& ");
            try writePwsh(w, argv[0]);
        },
        .cmd => try writeCmdProgram(w, argv[0]),
    }
    for (argv[1..]) |a| {
        try w.writeByte(' ');
        try writeArg(w, shell, a);
    }
}

/// Heap copy of `writeCommand`.
pub fn commandAlloc(gpa: Allocator, shell: Shell, argv: []const []const u8) error{ Unrepresentable, OutOfMemory }![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    writeCommand(&aw.writer, shell, argv) catch |err| return switch (err) {
        error.Unrepresentable => error.Unrepresentable,
        error.WriteFailed => error.OutOfMemory,
    };
    return aw.toOwnedSlice();
}

const testing = std.testing;

fn expectCommand(shell: Shell, argv: []const []const u8, want: []const u8) !void {
    const got = try commandAlloc(testing.allocator, shell, argv);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

/// Minimal POSIX sh word splitter for the subset `writePosix` emits.
fn posixUnquote(gpa: Allocator, line: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |a| gpa.free(a);
        out.deinit(gpa);
    }
    var cur: std.ArrayList(u8) = .empty;
    defer cur.deinit(gpa);
    var in_word = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == ' ') {
            if (in_word) try out.append(gpa, try cur.toOwnedSlice(gpa));
            in_word = false;
        } else if (c == '\'') {
            in_word = true;
            i += 1;
            while (line[i] != '\'') : (i += 1) try cur.append(gpa, line[i]);
        } else if (c == '\\') {
            in_word = true;
            i += 1;
            try cur.append(gpa, line[i]);
        } else {
            in_word = true;
            try cur.append(gpa, c);
        }
    }
    if (in_word) try out.append(gpa, try cur.toOwnedSlice(gpa));
    return out.toOwnedSlice(gpa);
}

/// Minimal PowerShell model: `& ` then single-quoted tokens.
fn pwshUnquote(gpa: Allocator, line: []const u8) ![][]u8 {
    try testing.expect(std.mem.startsWith(u8, line, "& "));
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |a| gpa.free(a);
        out.deinit(gpa);
    }
    var i: usize = 2;
    while (i < line.len) {
        try testing.expectEqual(@as(u8, '\''), line[i]);
        i += 1;
        var cur: std.ArrayList(u8) = .empty;
        errdefer cur.deinit(gpa);
        while (true) {
            if (line[i] == '\'') {
                if (i + 1 < line.len and line[i + 1] == '\'') {
                    try cur.append(gpa, '\'');
                    i += 2;
                    continue;
                }
                i += 1;
                break;
            }
            if (i + 5 < line.len and line[i] == 0xE2 and line[i + 1] == 0x80 and line[i + 2] >= 0x98 and line[i + 2] <= 0x9B) {
                try testing.expectEqualSlices(u8, line[i .. i + 3], line[i + 3 .. i + 6]);
                try cur.appendSlice(gpa, line[i .. i + 3]);
                i += 6;
                continue;
            }
            try cur.append(gpa, line[i]);
            i += 1;
        }
        try out.append(gpa, try cur.toOwnedSlice(gpa));
        if (i < line.len) {
            try testing.expectEqual(@as(u8, ' '), line[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Models cmd.exe: drops `%cd:~,%` expansions, checks no metacharacter is
/// live (outside real quotes and not caret-escaped), removes carets, then
/// splits with CommandLineToArgvW rules.
fn cmdUnquote(gpa: Allocator, line: []const u8) ![][]u8 {
    const expanded = try std.mem.replaceOwned(u8, gpa, line, "%cd:~,%", "");
    defer gpa.free(expanded);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var in_quotes = false;
    var i: usize = 0;
    while (i < expanded.len) : (i += 1) {
        const c = expanded[i];
        if (c == '^' and !in_quotes) {
            i += 1;
            try out.append(gpa, expanded[i]);
            continue;
        }
        if (c == '"') in_quotes = !in_quotes;
        if (!in_quotes and std.mem.indexOfScalar(u8, "&|<>()!", c) != null) return error.LiveMetacharacter;
        try out.append(gpa, c);
    }
    try testing.expect(!in_quotes);
    return win_argv.split(gpa, out.items);
}

fn expectRoundTrip(shell: Shell, argv: []const []const u8) !void {
    const gpa = testing.allocator;
    const line = try commandAlloc(gpa, shell, argv);
    defer gpa.free(line);
    const back = switch (shell) {
        .posix => try posixUnquote(gpa, line),
        .pwsh => try pwshUnquote(gpa, line),
        .cmd => try cmdUnquote(gpa, line),
    };
    defer {
        for (back) |a| gpa.free(a);
        gpa.free(back);
    }
    try testing.expectEqual(argv.len, back.len);
    for (argv, back) |a, b| try testing.expectEqualStrings(a, b);
}

test "unit: proto: shell_quote resume command per shell" {
    const id = "6f1c0a4e-2b7d-4c1e-9a55-0d3b2f1e8c77";
    try expectCommand(.pwsh, &.{ "claude", "--resume", id }, "& 'claude' '--resume' '" ++ id ++ "'");
    try expectCommand(.posix, &.{ "claude", "--resume", id }, "claude --resume " ++ id);
    try expectCommand(.cmd, &.{ "claude", "--resume", id }, "claude --resume " ++ id);
}

test "unit: proto: shell_quote posix quoting" {
    try expectCommand(.posix, &.{ "echo", "", "a b", "it's", "$HOME", "*", "x;y", "\u{1F600}" }, "echo '' 'a b' 'it'\\''s' '$HOME' '*' 'x;y' '\u{1F600}'");
    try expectCommand(.posix, &.{ "/usr/bin/env", "A=1", "a,b:c@d%e+f.g/h-i_j" }, "/usr/bin/env A=1 a,b:c@d%e+f.g/h-i_j");
    try expectCommand(.posix, &.{ "printf", "line1\nline2" }, "printf 'line1\nline2'");
}

test "unit: proto: shell_quote pwsh quoting" {
    try expectCommand(.pwsh, &.{ "C:\\Program Files\\x.exe", "it's", "", "$env:X", "`n", "\"q\"" }, "& 'C:\\Program Files\\x.exe' 'it''s' '' '$env:X' '`n' '\"q\"'");
    try expectCommand(.pwsh, &.{ "p", "a\u{2019}b\u{2018}" }, "& 'p' 'a\u{2019}\u{2019}b\u{2018}\u{2018}'");
    try expectCommand(.pwsh, &.{ "p", "\u{201C}dq\u{201D}" }, "& 'p' '\u{201C}dq\u{201D}'");
}

test "unit: proto: shell_quote cmd quoting" {
    try expectCommand(.cmd, &.{ "claude", "a b" }, "claude ^\"a b^\"");
    try expectCommand(.cmd, &.{ "claude", "a&b" }, "claude a^&b");
    try expectCommand(.cmd, &.{ "claude", "say \"hi\"" }, "claude ^\"say \\^\"hi\\^\"^\"");
    try expectCommand(.cmd, &.{ "claude", "100%" }, "claude 100%%cd:~,%");
    try expectCommand(.cmd, &.{ "C:\\Program Files\\Claude\\claude.exe", "-p", "x" }, "\"C:\\Program Files\\Claude\\claude.exe\" -p x");
    try expectCommand(.cmd, &.{ "C:\\a&b\\x.exe", "" }, "\"C:\\a&b\\x.exe\" ^\"^\"");
}

test "unit: proto: shell_quote round trips through shell models" {
    const argvs = [_][]const []const u8{
        &.{ "claude", "--resume", "abc" },
        &.{ "C:\\Program Files\\tool.exe", "", "a b", "\"", "\\", "\\\"", "trailing\\" },
        &.{ "tool", "a&b|c<d>e^f(g)h!i", "%PATH%", "100%", "%", "%%" },
        &.{ "tool", "' \" ` $ ; *", "it's", "\u{2018}x\u{2019}", "J\u{f6}rg \u{1F600} \u{4e2d}" },
        &.{ "tool", "\" & calc & \"", "^\"^&", "a\\\\\"b" },
    };
    for (argvs) |argv| {
        try expectRoundTrip(.posix, argv);
        try expectRoundTrip(.pwsh, argv);
        try expectRoundTrip(.cmd, argv);
    }
}

test "unit: proto: shell_quote long cmd argument" {
    const gpa = testing.allocator;
    const big = try gpa.alloc(u8, 4096);
    defer gpa.free(big);
    for (big, 0..) |*c, i| c.* = "a &\"\\%^"[i % 7];
    try expectRoundTrip(.cmd, &.{ "tool", big });
    try expectRoundTrip(.posix, &.{ "tool", big });
    try expectRoundTrip(.pwsh, &.{ "tool", big });
}

test "unit: proto: shell_quote unrepresentable input" {
    const gpa = testing.allocator;
    try testing.expectError(error.Unrepresentable, commandAlloc(gpa, .posix, &.{ "p", "a\x00b" }));
    try testing.expectError(error.Unrepresentable, commandAlloc(gpa, .pwsh, &.{ "p", "a\x00b" }));
    try testing.expectError(error.Unrepresentable, commandAlloc(gpa, .cmd, &.{ "p", "a\nb" }));
    try testing.expectError(error.Unrepresentable, commandAlloc(gpa, .cmd, &.{ "p", "a\rb" }));
    try testing.expectError(error.Unrepresentable, commandAlloc(gpa, .cmd, &.{"a\"b"}));
    try testing.expectError(error.Unrepresentable, commandAlloc(gpa, .cmd, &.{""}));
    const empty = try commandAlloc(gpa, .pwsh, &.{});
    defer gpa.free(empty);
    try testing.expectEqualStrings("", empty);
}

test "unit: proto: shell_quote shell names" {
    try testing.expectEqual(@as(?Shell, .pwsh), Shell.fromName("pwsh"));
    try testing.expectEqual(@as(?Shell, .pwsh), Shell.fromName("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\PowerShell.EXE"));
    try testing.expectEqual(@as(?Shell, .cmd), Shell.fromName("cmd.exe"));
    try testing.expectEqual(@as(?Shell, .posix), Shell.fromName("/usr/bin/zsh"));
    try testing.expectEqual(@as(?Shell, .posix), Shell.fromName("wsl.exe"));
    try testing.expectEqual(@as(?Shell, .posix), Shell.fromName("C:\\Program Files\\Git\\bin\\bash.exe"));
    try testing.expectEqual(@as(?Shell, null), Shell.fromName("fish"));
    try testing.expectEqual(@as(?Shell, null), Shell.fromName(""));
    try testing.expectEqual(@as(?Shell, null), Shell.fromName(".exe"));
}
