//! Windows command-line quoting (CommandLineToArgvW rules, BatBadBut-safe
//! `cmd /d /s /c`) (ADR-10.6).
//!
//! All functions work on UTF-8: every byte the rules care about is ASCII, so
//! multi-byte sequences pass through untouched. Convert to UTF-16 with
//! `utf8.zig` right before `CreateProcessW`.

const std = @import("std");
const Allocator = std.mem.Allocator;

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Splits a full command line exactly like `CommandLineToArgvW`:
/// - argv[0] (the program) ends at the first space/tab, or, when it starts
///   with `"`, at the next `"` (no backslash processing). A leading space
///   yields an empty argv[0].
/// - other arguments: 2n backslashes + `"` → n backslashes and a quote
///   toggle; 2n+1 backslashes + `"` → n backslashes and a literal `"`;
///   backslashes elsewhere are literal; runs of quotes follow the legacy
///   rule (every third consecutive quote is literal, `""` inside quotes
///   yields `"` and ends the quoted run).
/// An empty command line yields an empty list (the Win32 API would return
/// the current executable path instead).
pub fn split(gpa: Allocator, cmdline: []const u8) Allocator.Error![][]u8 {
    var args: std.ArrayList([]u8) = .empty;
    errdefer freeArgs(gpa, args.items);
    defer args.deinit(gpa);
    if (cmdline.len == 0) return args.toOwnedSlice(gpa);

    var i: usize = 0;
    var cur: std.ArrayList(u8) = .empty;
    defer cur.deinit(gpa);
    if (cmdline[0] == '"') {
        i = 1;
        while (i < cmdline.len and cmdline[i] != '"') : (i += 1) try cur.append(gpa, cmdline[i]);
        if (i < cmdline.len) i += 1; // closing quote
    } else {
        while (i < cmdline.len and !isWs(cmdline[i])) : (i += 1) try cur.append(gpa, cmdline[i]);
    }
    try args.append(gpa, try cur.toOwnedSlice(gpa));
    try splitRest(gpa, cmdline[i..], &args);
    return args.toOwnedSlice(gpa);
}

/// Splits an argument string that has no program name (every token uses the
/// argument rules of `split`).
pub fn splitArgs(gpa: Allocator, s: []const u8) Allocator.Error![][]u8 {
    var args: std.ArrayList([]u8) = .empty;
    errdefer freeArgs(gpa, args.items);
    defer args.deinit(gpa);
    try splitRest(gpa, s, &args);
    return args.toOwnedSlice(gpa);
}

fn splitRest(gpa: Allocator, s: []const u8, args: *std.ArrayList([]u8)) Allocator.Error!void {
    var cur: std.ArrayList(u8) = .empty;
    defer cur.deinit(gpa);
    var i: usize = 0;
    while (true) {
        while (i < s.len and isWs(s[i])) i += 1;
        if (i >= s.len) return;
        // One argument.
        var in_quotes = false;
        var backslashes: usize = 0;
        while (i < s.len) {
            const c = s[i];
            if (isWs(c) and !in_quotes) break;
            if (c == '\\') {
                backslashes += 1;
                try cur.append(gpa, c);
                i += 1;
                continue;
            }
            if (c == '"') {
                // Undo the backslashes we optimistically kept.
                cur.items.len -= backslashes;
                try cur.appendNTimes(gpa, '\\', backslashes / 2);
                var quotes: u8 = undefined;
                if (backslashes % 2 == 1) {
                    try cur.append(gpa, '"');
                    quotes = @intFromBool(in_quotes);
                } else {
                    quotes = @as(u8, @intFromBool(in_quotes)) + 1;
                }
                backslashes = 0;
                i += 1;
                while (i < s.len and s[i] == '"') : (i += 1) {
                    quotes += 1;
                    if (quotes == 3) {
                        try cur.append(gpa, '"');
                        quotes = 0;
                    }
                }
                if (quotes == 2) quotes = 0;
                in_quotes = quotes == 1;
                continue;
            }
            backslashes = 0;
            try cur.append(gpa, c);
            i += 1;
        }
        try args.append(gpa, try cur.toOwnedSlice(gpa));
    }
}

pub fn freeArgs(gpa: Allocator, args: []const []u8) void {
    for (args) |a| gpa.free(a);
}

/// Frees the result of `split`/`splitArgs`.
pub fn free(gpa: Allocator, args: [][]u8) void {
    freeArgs(gpa, args);
    gpa.free(args);
}

/// True when `arg` must be quoted to survive `split`.
pub fn needsQuotes(arg: []const u8) bool {
    if (arg.len == 0) return true;
    for (arg) |c| switch (c) {
        ' ', '\t', '\n', '\x0b', '"' => return true,
        else => {},
    };
    return false;
}

/// Writes `arg` so that `split` reproduces it exactly (the inverse of the
/// argument rules): bare when safe, else wrapped in quotes with backslashes
/// doubled before quotes and at the end, and `"` written as `\"`.
pub fn writeArg(w: *std.Io.Writer, arg: []const u8) std.Io.Writer.Error!void {
    if (!needsQuotes(arg)) return w.writeAll(arg);
    try w.writeByte('"');
    var backslashes: usize = 0;
    for (arg) |c| {
        if (c == '\\') {
            backslashes += 1;
            continue;
        }
        if (c == '"') {
            try w.splatByteAll('\\', backslashes * 2 + 1);
            try w.writeByte('"');
        } else {
            try w.splatByteAll('\\', backslashes);
            try w.writeByte(c);
        }
        backslashes = 0;
    }
    try w.splatByteAll('\\', backslashes * 2);
    try w.writeByte('"');
}

pub const ProgramError = error{Unrepresentable};

/// Writes argv[0]. Program names cannot contain `"` (argv[0] has no escape)
/// or NUL; they are quoted when empty or containing a space/tab.
pub fn writeProgram(w: *std.Io.Writer, program: []const u8) (ProgramError || std.Io.Writer.Error)!void {
    if (std.mem.indexOfAny(u8, program, "\"\x00") != null) return error.Unrepresentable;
    const quote = program.len == 0 or std.mem.indexOfAny(u8, program, " \t") != null;
    if (quote) try w.writeByte('"');
    try w.writeAll(program);
    if (quote) try w.writeByte('"');
}

pub const JoinError = error{ Unrepresentable, OutOfMemory };

/// Inverse of `split`: `split(join(argv)) == argv` for any argv whose
/// program has no `"` and no argument contains NUL.
pub fn join(gpa: Allocator, argv: []const []const u8) JoinError![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    if (argv.len == 0) return aw.toOwnedSlice();
    writeProgram(&aw.writer, argv[0]) catch |err| return mapWriteErr(err);
    for (argv[1..]) |a| {
        if (std.mem.indexOfScalar(u8, a, 0) != null) return error.Unrepresentable;
        aw.writer.writeByte(' ') catch return error.OutOfMemory;
        writeArg(&aw.writer, a) catch return error.OutOfMemory;
    }
    return aw.toOwnedSlice();
}

/// Joins arguments only (no program-name rules).
pub fn joinArgs(gpa: Allocator, args: []const []const u8) JoinError![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    for (args, 0..) |a, i| {
        if (std.mem.indexOfScalar(u8, a, 0) != null) return error.Unrepresentable;
        if (i > 0) aw.writer.writeByte(' ') catch return error.OutOfMemory;
        writeArg(&aw.writer, a) catch return error.OutOfMemory;
    }
    return aw.toOwnedSlice();
}

fn mapWriteErr(err: (ProgramError || std.Io.Writer.Error)) JoinError {
    return switch (err) {
        error.Unrepresentable => error.Unrepresentable,
        error.WriteFailed => error.OutOfMemory,
    };
}

// ----- batch files through cmd.exe -----

/// True for `.bat`/`.cmd` paths, ignoring case and the trailing dots and
/// spaces Windows strips from file names (`x.bat.`, `x.cmd  `).
pub fn isBatchFile(path: []const u8) bool {
    var p = path;
    while (p.len > 0 and (p[p.len - 1] == '.' or p[p.len - 1] == ' ')) p = p[0 .. p.len - 1];
    if (p.len < 4) return false;
    const ext = p[p.len - 4 ..];
    return std.ascii.eqlIgnoreCase(ext, ".bat") or std.ascii.eqlIgnoreCase(ext, ".cmd");
}

/// Characters that are safe unquoted in a batch argument. Everything else
/// (spaces, `&|<>^()%!"`, the batch delimiters `,;=`, …) forces quoting.
fn batchSafe(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-', '+', '.', '/', ':', '@', '\\', '#', '$', '~', '[', ']', '{', '}', '\'', '`', '*', '?' => true,
        0x80...0xFF => true,
        else => false,
    };
}

/// `%` inside a cmd.exe command line: a literal `%` followed by `%cd:~,%`,
/// which expands to nothing, so no `%name%` can ever form.
const percent_escape = "%%cd:~,%";

fn writeBatchText(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| {
        if (c == '%') try w.writeAll(percent_escape) else try w.writeByte(c);
    }
}

pub const BatchError = error{ Unrepresentable, OutOfMemory };

/// Writes one argument for a batch file run through `cmd.exe`, safe against
/// BatBadBut-style injection: the batch re-parses its arguments with cmd's
/// quote-toggle rules (no backslash escapes), so an embedded `"` is written
/// as `""` (two toggles; every metacharacter stays inside quotes), `%` is
/// neutralized, and CR, LF and NUL (which cmd cannot carry) are rejected.
/// Programs that parse their command line with the UCRT rules (node.exe
/// behind npm `.cmd` shims) read `""` inside quotes as one `"`.
pub fn writeBatchArg(w: *std.Io.Writer, arg: []const u8) (error{Unrepresentable} || std.Io.Writer.Error)!void {
    if (std.mem.indexOfAny(u8, arg, "\r\n\x00") != null) return error.Unrepresentable;
    var quote = arg.len == 0;
    for (arg) |c| if (!batchSafe(c)) {
        quote = true;
        break;
    };
    if (!quote) return w.writeAll(arg);
    try w.writeByte('"');
    var backslashes: usize = 0;
    for (arg) |c| {
        if (c == '\\') {
            backslashes += 1;
            continue;
        }
        if (c == '"') {
            try w.splatByteAll('\\', backslashes * 2);
            try w.writeAll("\"\"");
        } else {
            try w.splatByteAll('\\', backslashes);
            if (c == '%') try w.writeAll(percent_escape) else try w.writeByte(c);
        }
        backslashes = 0;
    }
    try w.splatByteAll('\\', backslashes * 2);
    try w.writeByte('"');
}

/// Command line for running a batch file:
/// `"<cmd_exe>" /d /s /c ""<script>" <args…>"`. Pass the same `cmd_exe` as
/// `lpApplicationName` to `CreateProcessW`. `/s` makes cmd strip exactly the
/// outer quote pair; `/d` skips AutoRun. The script path must not contain
/// `"`, CR, LF or NUL.
pub fn cmdBatchCommandLine(gpa: Allocator, cmd_exe: []const u8, script: []const u8, args: []const []const u8) BatchError![]u8 {
    if (std.mem.indexOfAny(u8, script, "\"\r\n\x00") != null or script.len == 0) return error.Unrepresentable;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    writeProgram(w, cmd_exe) catch |err| return mapWriteErr(err);
    w.writeAll(" /d /s /c \"\"") catch return error.OutOfMemory;
    writeBatchText(w, script) catch return error.OutOfMemory;
    w.writeByte('"') catch return error.OutOfMemory;
    for (args) |a| {
        w.writeByte(' ') catch return error.OutOfMemory;
        writeBatchArg(w, a) catch |err| return switch (err) {
            error.Unrepresentable => error.Unrepresentable,
            error.WriteFailed => error.OutOfMemory,
        };
    }
    w.writeByte('"') catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

const testing = std.testing;

fn expectSplit(cmdline: []const u8, want: []const []const u8) !void {
    const got = try split(testing.allocator, cmdline);
    defer free(testing.allocator, got);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

fn expectSplitArgs(s: []const u8, want: []const []const u8) !void {
    const got = try splitArgs(testing.allocator, s);
    defer free(testing.allocator, got);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "unit: proto: win_argv split documented examples" {
    // The Microsoft "Parsing C command-line arguments" table.
    try expectSplit("p \"a b c\" d e", &.{ "p", "a b c", "d", "e" });
    try expectSplit("p \"ab\\\"c\" \"\\\\\" d", &.{ "p", "ab\"c", "\\", "d" });
    try expectSplit("p a\\\\\\b d\"e f\"g h", &.{ "p", "a\\\\\\b", "de fg", "h" });
    try expectSplit("p a\\\\\\\"b c d", &.{ "p", "a\\\"b", "c", "d" });
    try expectSplit("p a\\\\\\\\\"b c\" d e", &.{ "p", "a\\\\b c", "d", "e" });
}

test "unit: proto: win_argv split quote runs" {
    try expectSplitArgs("\"\"", &.{""});
    try expectSplitArgs("\"\"\"\"", &.{"\""});
    try expectSplitArgs("a\"\"\"b", &.{"a\"b"});
    // `""` inside quotes yields `"` and ends the quoted run.
    try expectSplitArgs("\"a\"\"b c\"", &.{ "a\"b", "c" });
    try expectSplitArgs("\"a\"\"\"b c\"", &.{"a\"b c"});
    try expectSplitArgs("\"\"\"\"\"\"", &.{"\"\""});
    try expectSplitArgs("a \"\" b", &.{ "a", "", "b" });
}

test "unit: proto: win_argv split program name rules" {
    try expectSplit("\"C:\\Program Files\\x.exe\" -a", &.{ "C:\\Program Files\\x.exe", "-a" });
    try expectSplit("\"C:\\a\\\"b c", &.{ "C:\\a\\", "b", "c" });
    try expectSplit("\"a\"b c", &.{ "a", "b", "c" });
    try expectSplit("C:\\x\\\"y\" z", &.{ "C:\\x\\\"y\"", "z" });
    try expectSplit(" a b", &.{ "", "a", "b" });
    try expectSplit("\"unterminated", &.{"unterminated"});
    try expectSplit("prog", &.{"prog"});
    try expectSplit("prog   \t ", &.{"prog"});
    try expectSplit("", &.{});
}

test "unit: proto: win_argv split whitespace and unicode" {
    try expectSplit("p a\tb\t\t\"c\td\"", &.{ "p", "a", "b", "c\td" });
    try expectSplit("p a\nb", &.{ "p", "a\nb" });
    try expectSplit("p J\u{f6}rg \"\u{1F600} \u{4e2d}\"", &.{ "p", "J\u{f6}rg", "\u{1F600} \u{4e2d}" });
    try expectSplit("p trailing\\", &.{ "p", "trailing\\" });
    try expectSplit("p \"unterminated arg", &.{ "p", "unterminated arg" });
}

test "unit: proto: win_argv quote examples" {
    const gpa = testing.allocator;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "simple", "simple" },
        .{ "", "\"\"" },
        .{ "a b", "\"a b\"" },
        .{ "a\"b", "\"a\\\"b\"" },
        .{ "C:\\dir\\", "C:\\dir\\" },
        .{ "C:\\my dir\\", "\"C:\\my dir\\\\\"" },
        .{ "a\\\"b", "\"a\\\\\\\"b\"" },
        .{ "tab\there", "\"tab\there\"" },
        .{ "\u{1F600}", "\u{1F600}" },
    };
    for (cases) |c| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try writeArg(&aw.writer, c[0]);
        try testing.expectEqualStrings(c[1], aw.written());
    }
}

test "unit: proto: win_argv join split round trip" {
    const gpa = testing.allocator;
    const argvs = [_][]const []const u8{
        &.{"prog"},
        &.{ "C:\\Program Files\\Claude\\claude.exe", "--resume", "abc" },
        &.{ "p", "", "", "x" },
        &.{ "p", "\"", "\"\"", "\"\"\"", "\\", "\\\\", "\\\"", "a\\\\\"b\\" },
        &.{ "p", "say \"hi\" & exit", "100%", "^caret", "tab\tand\nnewline" },
        &.{ "", "a" },
        &.{ "p", "J\u{f6}rg \u{1F600}", "\u{4e2d}\u{6587}" },
        &.{ "p", " leading", "trailing ", "trailing\\\\" },
    };
    for (argvs) |argv| {
        const line = try join(gpa, argv);
        defer gpa.free(line);
        const back = try split(gpa, line);
        defer free(gpa, back);
        try testing.expectEqual(argv.len, back.len);
        for (argv, back) |a, b| try testing.expectEqualStrings(a, b);
    }
}

test "unit: proto: win_argv round trip exhaustive small alphabet" {
    // Every argument of length ≤ 5 over { a, space, ", \ }.
    const gpa = testing.allocator;
    const alphabet = "a \"\\";
    var buf: [5]u8 = undefined;
    for (0..6) |len| {
        var total: usize = 1;
        for (0..len) |_| total *= alphabet.len;
        for (0..total) |n| {
            var x = n;
            for (0..len) |k| {
                buf[k] = alphabet[x % alphabet.len];
                x /= alphabet.len;
            }
            const argv = [_][]const u8{ "p", buf[0..len], "z" };
            const line = try join(gpa, &argv);
            defer gpa.free(line);
            const back = try split(gpa, line);
            defer free(gpa, back);
            try testing.expectEqual(@as(usize, 3), back.len);
            try testing.expectEqualStrings(buf[0..len], back[1]);
        }
    }
}

test "unit: proto: win_argv join errors" {
    const gpa = testing.allocator;
    try testing.expectError(error.Unrepresentable, join(gpa, &.{"a\"b"}));
    try testing.expectError(error.Unrepresentable, join(gpa, &.{ "p", "a\x00b" }));
    const empty = try join(gpa, &.{});
    defer gpa.free(empty);
    try testing.expectEqualStrings("", empty);
    const args = try joinArgs(gpa, &.{ "a b", "c" });
    defer gpa.free(args);
    try testing.expectEqualStrings("\"a b\" c", args);
    const back = try splitArgs(gpa, args);
    defer free(gpa, back);
    try testing.expectEqualStrings("a b", back[0]);
}

test "unit: proto: win_argv huge command line" {
    const gpa = testing.allocator;
    const big = try gpa.alloc(u8, 32 * 1024);
    defer gpa.free(big);
    for (big, 0..) |*c, i| c.* = "ab \\\""[i % 5];
    const line = try join(gpa, &.{ "p", big });
    defer gpa.free(line);
    const back = try split(gpa, line);
    defer free(gpa, back);
    try testing.expectEqualStrings(big, back[1]);
}

test "unit: proto: win_argv batch file detection" {
    try testing.expect(isBatchFile("C:\\npm\\claude.cmd"));
    try testing.expect(isBatchFile("x.BAT"));
    try testing.expect(isBatchFile("x.bat."));
    try testing.expect(isBatchFile("x.cmd . "));
    try testing.expect(!isBatchFile("x.exe"));
    try testing.expect(!isBatchFile("cmd"));
    try testing.expect(!isBatchFile(".bat"[1..]));
    try testing.expect(!isBatchFile("x.batch"));
}

test "unit: proto: win_argv batch args" {
    const gpa = testing.allocator;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "--resume", "--resume" },
        .{ "", "\"\"" },
        .{ "a b", "\"a b\"" },
        .{ "a&b", "\"a&b\"" },
        .{ "a,b", "\"a,b\"" },
        .{ "say \"hi\"", "\"say \"\"hi\"\"\"" },
        .{ "\" & calc & \"", "\"\"\" & calc & \"\"\"" },
        .{ "100%", "\"100%%cd:~,%\"" },
        .{ "%PATH%", "\"%%cd:~,%PATH%%cd:~,%\"" },
        .{ "C:\\dir\\", "C:\\dir\\" },
        .{ "C:\\my dir\\", "\"C:\\my dir\\\\\"" },
        .{ "a\\\"b", "\"a\\\\\"\"b\"" },
        .{ "J\u{f6}rg", "J\u{f6}rg" },
    };
    for (cases) |c| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try writeBatchArg(&aw.writer, c[0]);
        try testing.expectEqualStrings(c[1], aw.written());
    }
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try testing.expectError(error.Unrepresentable, writeBatchArg(&aw.writer, "a\nb"));
    try testing.expectError(error.Unrepresentable, writeBatchArg(&aw.writer, "a\rb"));
    try testing.expectError(error.Unrepresentable, writeBatchArg(&aw.writer, "a\x00b"));
}

/// cmd.exe's view of a line: true when every metacharacter is inside a
/// quoted run (quotes toggle, no escapes) and no `%` can start a variable.
fn cmdSafe(line: []const u8) bool {
    var in_quotes = false;
    for (line) |c| {
        if (c == '"') {
            in_quotes = !in_quotes;
            continue;
        }
        if (!in_quotes and std.mem.indexOfScalar(u8, "&|<>^()", c) != null) return false;
    }
    return !in_quotes;
}

test "unit: proto: win_argv batch args keep metacharacters quoted" {
    const gpa = testing.allocator;
    const nasty = [_][]const u8{
        "\" & calc.exe & \"", "a\"&b",       "\\\"&calc",             "^&|<>()",
        "\"\"\"&\"",          "x\" | y \"z", "trailing\\\"&w",        "\"",
        "a\\\\\"b & c",       "(echo)",      "J\u{f6}rg & \u{1F600}",
    };
    for (nasty) |arg| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try writeBatchArg(&aw.writer, arg);
        try testing.expect(cmdSafe(aw.written()));
    }
}

test "unit: proto: win_argv cmd batch command line" {
    const gpa = testing.allocator;
    const line = try cmdBatchCommandLine(gpa, "C:\\Windows\\System32\\cmd.exe", "C:\\Users\\u\\AppData\\Roaming\\npm\\claude.cmd", &.{ "--resume", "id 1", "a&b" });
    defer gpa.free(line);
    try testing.expectEqualStrings("C:\\Windows\\System32\\cmd.exe /d /s /c \"\"C:\\Users\\u\\AppData\\Roaming\\npm\\claude.cmd\" --resume \"id 1\" \"a&b\"\"", line);

    const spaced = try cmdBatchCommandLine(gpa, "C:\\Program Files\\cmd.exe", "C:\\My Tools\\100%.bat", &.{});
    defer gpa.free(spaced);
    try testing.expectEqualStrings("\"C:\\Program Files\\cmd.exe\" /d /s /c \"\"C:\\My Tools\\100%%cd:~,%.bat\"\"", spaced);

    try testing.expectError(error.Unrepresentable, cmdBatchCommandLine(gpa, "cmd.exe", "a\"b.cmd", &.{}));
    try testing.expectError(error.Unrepresentable, cmdBatchCommandLine(gpa, "cmd.exe", "", &.{}));
    try testing.expectError(error.Unrepresentable, cmdBatchCommandLine(gpa, "cmd.exe", "x.cmd", &.{"a\nb"}));
    try testing.expectError(error.Unrepresentable, cmdBatchCommandLine(gpa, "c\"md.exe", "x.cmd", &.{}));
}
