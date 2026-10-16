//! Workspace environment input (cli-workspace-env-vars): `--env KEY=VALUE`
//! assignments and `--env-file` contents (`KEY=VALUE` lines; blank lines and
//! `#` comments ignored; a leading `export ` stripped; one pair of matching
//! surrounding quotes removed from the value). Later assignments override
//! earlier ones, comparing names case-insensitively (the app hands the set
//! to Windows processes, whose environment block ignores case), so
//! `--env` given after the files wins. Values are never logged.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Pair = struct { key: []const u8, value: []const u8 };

/// Splits `KEY=VALUE`; null when there is no `=`, the key is empty or the
/// key holds whitespace or NUL.
pub fn parseAssignment(text: []const u8) ?Pair {
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return null;
    const key = text[0..eq];
    if (!validKey(key)) return null;
    return .{ .key = key, .value = text[eq + 1 ..] };
}

pub fn validKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| if (c == 0 or c == '=' or std.ascii.isWhitespace(c)) return false;
    return true;
}

fn unquote(v: []const u8) []const u8 {
    if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) return v[1 .. v.len - 1];
    return v;
}

/// Parses an env file. On a malformed line returns `error.Malformed` with
/// its 1-based number in `line.*`.
pub fn parseFile(arena: Allocator, bytes: []const u8, line: *usize) (Allocator.Error || error{Malformed})![]const Pair {
    var out: std.ArrayList(Pair) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    var n: usize = 0;
    while (it.next()) |raw| {
        n += 1;
        var t = std.mem.trim(u8, raw, " \t\r");
        // A UTF-8 byte order mark on the first line.
        if (n == 1 and std.mem.startsWith(u8, t, "\xEF\xBB\xBF")) t = t[3..];
        if (t.len == 0 or t[0] == '#') continue;
        if (std.mem.startsWith(u8, t, "export ") or std.mem.startsWith(u8, t, "export\t")) {
            t = std.mem.trimLeft(u8, t["export".len..], " \t");
        }
        // Spaces around `=` are tolerated in files.
        const eq = std.mem.indexOfScalar(u8, t, '=');
        const key = if (eq) |e| std.mem.trimRight(u8, t[0..e], " \t") else t;
        if (eq == null or !validKey(key)) {
            line.* = n;
            return error.Malformed;
        }
        try out.append(arena, .{ .key = key, .value = unquote(std.mem.trim(u8, t[eq.? + 1 ..], " \t")) });
    }
    return out.items;
}

/// Ordered name → value set with case-insensitive override.
pub const EnvSet = struct {
    pairs: std.ArrayList(Pair) = .empty,

    pub fn put(self: *EnvSet, arena: Allocator, p: Pair) Allocator.Error!void {
        for (self.pairs.items) |*e| {
            if (std.ascii.eqlIgnoreCase(e.key, p.key)) {
                e.* = p;
                return;
            }
        }
        try self.pairs.append(arena, p);
    }

    /// `{"KEY":"VALUE",...}`
    pub fn toJson(self: *const EnvSet, arena: Allocator) Allocator.Error!std.json.Value {
        var m = std.json.ObjectMap.init(arena);
        for (self.pairs.items) |p| try m.put(p.key, .{ .string = p.value });
        return .{ .object = m };
    }
};

/// Shown instead of a value by `workspace env --mask`.
pub const mask = "***";

const testing = std.testing;

test "unit: cli-workspace-env: assignments" {
    try testing.expectEqualStrings("FOO", parseAssignment("FOO=1").?.key);
    try testing.expectEqualStrings("a=b", parseAssignment("X=a=b").?.value);
    try testing.expectEqualStrings("", parseAssignment("EMPTY=").?.value);
    try testing.expectEqualStrings("\u{65e5}\u{672c}", parseAssignment("U=\u{65e5}\u{672c}").?.value);
    try testing.expect(parseAssignment("NOEQ") == null);
    try testing.expect(parseAssignment("=1") == null);
    try testing.expect(parseAssignment("A B=1") == null);
    try testing.expect(parseAssignment("") == null);
}

test "unit: cli-workspace-env: env file comments, export, quotes and errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var line: usize = 0;
    const text = "\xEF\xBB\xBF# comment\r\n\r\nexport AWS_PROFILE=prod\r\n  FOO = \"a b\" \nQ='x'\nURL=http://h/?a=b#frag\nexport\tT=1\n   # indented comment\n";
    const pairs = try parseFile(a, text, &line);
    try testing.expectEqual(@as(usize, 5), pairs.len);
    try testing.expectEqualStrings("AWS_PROFILE", pairs[0].key);
    try testing.expectEqualStrings("prod", pairs[0].value);
    try testing.expectEqualStrings("FOO", pairs[1].key);
    try testing.expectEqualStrings("a b", pairs[1].value);
    try testing.expectEqualStrings("x", pairs[2].value);
    try testing.expectEqualStrings("http://h/?a=b#frag", pairs[3].value);
    try testing.expectEqualStrings("T", pairs[4].key);
    // A key may not contain whitespace.
    try testing.expectError(error.Malformed, parseFile(a, "OK=1\nMY KEY=1\n", &line));
    try testing.expectEqual(@as(usize, 2), line);
    try testing.expectError(error.Malformed, parseFile(a, "just words\n", &line));
    try testing.expectEqual(@as(usize, 1), line);
    try testing.expectEqual(@as(usize, 0), (try parseFile(a, "", &line)).len);
}

test "unit: cli-workspace-env: later values override case-insensitively" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var set: EnvSet = .{};
    try set.put(a, .{ .key = "Path2", .value = "a" });
    try set.put(a, .{ .key = "FOO", .value = "1" });
    try set.put(a, .{ .key = "PATH2", .value = "b" });
    const js = try std.json.Stringify.valueAlloc(a, try set.toJson(a), .{});
    try testing.expectEqualStrings("{\"PATH2\":\"b\",\"FOO\":\"1\"}", js);
    var big: EnvSet = .{};
    for (0..2000) |i| try big.put(a, .{ .key = try std.fmt.allocPrint(a, "K{d}", .{i % 1000}), .value = "v" });
    try testing.expectEqual(@as(usize, 1000), big.pairs.items.len);
}
