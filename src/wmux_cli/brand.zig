//! Program branding (ADR-4.1, ADR-4.3 step 1): the CLI answers to the name it
//! was invoked as. `WMUX_ARGV0` (set by the sh launchers) wins over argv[0];
//! argv[0] may be a bare name (cmd) or a full path with an extension (pwsh,
//! bash; spike S6 §5.3). Help and messages are authored with the `cmux`
//! spelling and rewritten word-wise for `wmux`.

const std = @import("std");

pub const Brand = enum {
    cmux,
    wmux,

    pub fn name(b: Brand) []const u8 {
        return @tagName(b);
    }
};

/// What argv[0] asks for.
pub const Invoked = union(enum) {
    /// `cmux`/`wmux` (or an unrecognized name, which gets the cmux grammar).
    cli: Brand,
    /// `tmux` compat shim (ADR-10.8, owned by W3-6).
    tmux,
    /// Agent wrapper such as `claude` or `codex` (ADR-10.6, owned by W3-2).
    agent_wrapper: []const u8,
};

/// Agent wrapper names known to the dispatcher. W3-2 extends dispatch through
/// the agent catalog; until then these names report "not available".
pub const wrapper_names = [_][]const u8{ "claude", "codex" };

/// Basename of `path` without a trailing `.exe`/`.com` (case-insensitive);
/// either slash direction separates.
pub fn programStem(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') start = i + 1;
    }
    const base = path[start..];
    for ([_][]const u8{ ".exe", ".com" }) |ext| {
        if (base.len > ext.len and std.ascii.endsWithIgnoreCase(base, ext))
            return base[0 .. base.len - ext.len];
    }
    return base;
}

pub fn classify(argv0: []const u8, wmux_argv0: ?[]const u8) Invoked {
    const source = if (wmux_argv0) |v| (if (v.len > 0) v else argv0) else argv0;
    const stem = programStem(source);
    if (std.ascii.eqlIgnoreCase(stem, "wmux")) return .{ .cli = .wmux };
    if (std.ascii.eqlIgnoreCase(stem, "cmux")) return .{ .cli = .cmux };
    if (std.ascii.eqlIgnoreCase(stem, "tmux")) return .tmux;
    for (wrapper_names) |w| {
        if (std.ascii.eqlIgnoreCase(stem, w)) return .{ .agent_wrapper = w };
    }
    return .{ .cli = .cmux };
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '/' or c == '\\';
}

/// Writes `text` with every standalone word `cmux` replaced by the brand
/// name. A word is standalone when neither neighbor is alphanumeric, `_`,
/// `-`, `.`, `/` or `\`, so `cmux.json`, `~/.config/cmux/`, `CMUX_QUIET` and
/// `cmux-cli` stay as they are while `cmux ping`, `# cmux guide` and
/// `cmux:` are rebranded. A trailing `.` ends a sentence, not a file name,
/// when it is followed by whitespace or the end of the text.
pub fn write(w: *std.Io.Writer, brand: Brand, text: []const u8) std.Io.Writer.Error!void {
    if (brand == .cmux) return w.writeAll(text);
    const word = "cmux";
    var i: usize = 0;
    var flushed: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, word)) |pos| {
        const end = pos + word.len;
        const before_ok = pos == 0 or !isWordByte(text[pos - 1]);
        var after_ok = end == text.len or !isWordByte(text[end]);
        if (!after_ok and text[end] == '.') {
            after_ok = end + 1 == text.len or std.ascii.isWhitespace(text[end + 1]);
        }
        if (before_ok and after_ok) {
            try w.writeAll(text[flushed..pos]);
            try w.writeAll(brand.name());
            flushed = end;
        }
        i = end;
    }
    try w.writeAll(text[flushed..]);
}

/// Heap copy of `write`.
pub fn alloc(gpa: std.mem.Allocator, brand: Brand, text: []const u8) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    write(&aw.writer, brand, text) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

const testing = std.testing;

test "unit: cli: brand program stem strips directories and extensions" {
    try testing.expectEqualStrings("wmux", programStem("wmux"));
    try testing.expectEqualStrings("wmux", programStem("C:\\Users\\x\\AppData\\Local\\Microsoft\\WindowsApps\\wmux.exe"));
    try testing.expectEqualStrings("cmux", programStem("/c/Program Files/wmux/cli/cmux.EXE"));
    try testing.expectEqualStrings("wmux", programStem("..\\cli\\wmux.com"));
    try testing.expectEqualStrings("", programStem(""));
    try testing.expectEqualStrings("", programStem("dir\\"));
    try testing.expectEqualStrings(".exe", programStem(".exe"));
    try testing.expectEqualStrings("caf\u{e9}", programStem("x/caf\u{e9}.exe"));
}

test "unit: cli: brand classify honors WMUX_ARGV0 first" {
    try testing.expectEqual(Invoked{ .cli = .wmux }, classify("C:\\i\\cli\\cmux.exe", "wmux"));
    try testing.expectEqual(Invoked{ .cli = .cmux }, classify("C:\\i\\cli\\wmux.exe", "cmux"));
    try testing.expectEqual(Invoked{ .cli = .wmux }, classify("WMUX", ""));
    try testing.expectEqual(Invoked{ .cli = .cmux }, classify("cmux", null));
    try testing.expectEqual(Invoked.tmux, classify("D:\\shims\\teams\\tmux.exe", null));
    try testing.expectEqualStrings("claude", classify("claude.exe", null).agent_wrapper);
    try testing.expectEqualStrings("codex", classify("x/Codex", null).agent_wrapper);
    // Renamed or unknown binaries get the cmux grammar.
    try testing.expectEqual(Invoked{ .cli = .cmux }, classify("wmux-cli.exe", null));
    try testing.expectEqual(Invoked{ .cli = .cmux }, classify("", null));
}

test "unit: cli: brand rewrites standalone cmux words only" {
    const gpa = testing.allocator;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "Usage: cmux ping", "Usage: wmux ping" },
        .{ "# cmux guide", "# wmux guide" },
        .{ "cmux guide | cmux --skill", "wmux guide | wmux --skill" },
        .{ "cmux: 'x' is now", "wmux: 'x' is now" },
        .{ "~/.config/cmux/cmux.json", "~/.config/cmux/cmux.json" },
        .{ "set CMUX_QUIET=1", "set CMUX_QUIET=1" },
        .{ "cmux-cli and cmuxterm", "cmux-cli and cmuxterm" },
        .{ "run cmux.", "run wmux." },
        .{ "cmux.exe", "cmux.exe" },
        .{ "(cmux)", "(wmux)" },
        .{ "cmux", "wmux" },
        .{ "", "" },
        .{ "\u{e9}cmux\u{e9}", "\u{e9}wmux\u{e9}" },
    };
    for (cases) |c| {
        const got = try alloc(gpa, .wmux, c[0]);
        defer gpa.free(got);
        try testing.expectEqualStrings(c[1], got);
        const same = try alloc(gpa, .cmux, c[0]);
        defer gpa.free(same);
        try testing.expectEqualStrings(c[0], same);
    }
}
