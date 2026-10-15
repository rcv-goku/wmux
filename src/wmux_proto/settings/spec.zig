//! The `Spec` type describing one setting (ADR-5.2). Feature files
//! `specs/<id>.zig` declare `pub const specs = [_]Spec{ ... };` and
//! `specs_manifest.zig` aggregates them. `checkComptime` rejects malformed
//! specs (bad path, default literal that does not fit the type) at compile time.

const std = @import("std");
const jsonc = @import("../jsonc.zig");

pub const IntRange = struct { min: i64, max: i64 };
pub const NumberRange = struct { min: f64, max: f64 };
pub const StringRule = struct { pattern: ?[]const u8 = null };

pub const Type = union(enum) {
    boolean,
    integer: IntRange,
    number: NumberRange,
    string: StringRule,
    /// Allowed string values.
    enumeration: []const []const u8,
    /// `#RRGGBB` or `#RRGGBBAA`.
    color,
    path,
    string_list,
    object,
    /// One stroke string, or a chord as an array of one or two strokes.
    strokes,
};

pub const Scope = enum {
    global,
    project,
    both,

    pub fn allowsProject(self: Scope) bool {
        return self != .global;
    }

    pub fn allowsGlobal(self: Scope) bool {
        return self != .project;
    }
};

pub const Apply = enum { live, restart };

pub const Spec = struct {
    /// Dotted cmux key path, e.g. "sidebar.showPorts".
    path: [:0]const u8,
    ty: Type,
    /// JSON literal, validated at comptime.
    default: []const u8,
    scope: Scope = .global,
    /// Settings UI section id (cmux raw ids + "windows").
    section: []const u8,
    label: []const u8,
    doc: []const u8,
    keywords: []const []const u8 = &.{},
    apply: Apply = .live,
    /// false for keys under "wmux.".
    cmux_compat: bool = true,
    /// e.g. "copy-on-select" for terminal.copyOnSelect.
    ghostty_override: ?[]const u8 = null,
    policy_lockable: bool = true,
    /// Generates "Enable/Disable <label>" palette entries.
    palette_toggle: bool = false,
};

/// Settings UI section ids (cmux raw ids + the Windows-only `windows`).
pub const sections = [_][]const u8{
    "app",               "themes",            "terminal",        "textBox",
    "sidebarAppearance", "automation",        "browser",         "browserImport",
    "globalHotkey",      "keyboardShortcuts", "workspaceColors", "settingsJSON",
    "reset",             "windows",
};

pub fn isWmuxPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "wmux.");
}

/// The spec with exactly `path`, or null.
pub fn find(specs: []const Spec, path: []const u8) ?*const Spec {
    for (specs) |*s| if (std.mem.eql(u8, s.path, path)) return s;
    return null;
}

/// True when some spec lives strictly below `path` (so `path` is a section).
pub fn isSection(specs: []const Spec, path: []const u8) bool {
    for (specs) |*s| {
        if (s.path.len > path.len and s.path[path.len] == '.' and std.mem.startsWith(u8, s.path, path))
            return true;
    }
    return false;
}

/// Returns an error message when `path` is not a well-formed dotted path.
pub fn pathProblem(path: []const u8) ?[]const u8 {
    if (path.len == 0) return "empty path";
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| {
        if (seg.len == 0) return "empty path segment";
        for (seg) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '$'))
                return "path segments use letters, digits, '_', '-' or '$'";
        }
    }
    return null;
}

fn isHexColor(s: []const u8) bool {
    if (s.len != 7 and s.len != 9) return false;
    if (s[0] != '#') return false;
    for (s[1..]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

pub fn isColor(s: []const u8) bool {
    return isHexColor(s);
}

/// Inner bytes of a JSON string literal without escapes, or null.
fn plainStringBody(lit: []const u8) ?[]const u8 {
    if (lit.len < 2 or lit[0] != '"' or lit[lit.len - 1] != '"') return null;
    const body = lit[1 .. lit.len - 1];
    for (body) |c| if (c == '"' or c == '\\' or c < 0x20) return null;
    return body;
}

/// Shape check of a default literal against its type that needs no
/// allocator, so it runs at comptime. Returns a message or null. The full
/// check (patterns, escapes) is `validate.checkValue`, run by unit tests
/// over every registered spec.
pub fn defaultProblem(ty: Type, lit: []const u8) ?[]const u8 {
    if (!jsonc.isValidLiteral(lit)) return "default is not a JSON literal";
    var t = jsonc.Tokenizer.init(lit, false);
    const first = (t.next() orelse return "default is not a JSON literal").tag;
    switch (ty) {
        .boolean => if (first != .true and first != .false) return "default must be true or false",
        .integer => |r| {
            if (first != .number) return "default must be an integer";
            const v = std.fmt.parseInt(i64, std.mem.trim(u8, lit, " "), 10) catch return "default must be an integer";
            if (v < r.min or v > r.max) return "default is out of range";
        },
        .number => |r| {
            if (first != .number) return "default must be a number";
            const v = std.fmt.parseFloat(f64, std.mem.trim(u8, lit, " ")) catch return "default must be a number";
            if (v < r.min or v > r.max) return "default is out of range";
        },
        .string, .path => if (first != .string) return "default must be a string",
        .enumeration => |values| {
            const body = plainStringBody(lit) orelse return "default must be a plain string";
            for (values) |v| if (std.mem.eql(u8, v, body)) return null;
            return "default is not one of the enumeration values";
        },
        .color => {
            const body = plainStringBody(lit) orelse return "default must be a color string";
            if (!isHexColor(body)) return "default must be #RRGGBB or #RRGGBBAA";
        },
        .string_list => {
            if (first != .lbracket) return "default must be an array of strings";
            while (t.next()) |tok| switch (tok.tag) {
                .string, .comma, .rbracket => {},
                .eof => break,
                else => return "default must be an array of strings",
            } else return "default is not a JSON literal";
        },
        .object => if (first != .lbrace) return "default must be an object",
        .strokes => {
            if (first == .string) return null;
            if (first != .lbracket) return "default must be a stroke string or chord array";
            var n: usize = 0;
            while (t.next()) |tok| switch (tok.tag) {
                .string => n += 1,
                .comma, .rbracket => {},
                .eof => break,
                else => return "default must be a stroke string or chord array",
            } else return "default is not a JSON literal";
            if (n == 0 or n > 2) return "a chord has one or two strokes";
        },
    }
    return null;
}

/// Compile-time checks for one spec (called by `specs_manifest.zig`).
pub fn checkComptime(comptime s: Spec) void {
    if (pathProblem(s.path)) |msg| @compileError("settings spec '" ++ s.path ++ "': " ++ msg);
    if (isWmuxPath(s.path) == s.cmux_compat)
        @compileError("settings spec '" ++ s.path ++ "': cmux_compat must be false exactly for keys under \"wmux.\"");
    if (defaultProblem(s.ty, s.default)) |msg| @compileError("settings spec '" ++ s.path ++ "': " ++ msg);
    switch (s.ty) {
        .integer => |r| if (r.min > r.max) @compileError("settings spec '" ++ s.path ++ "': min > max"),
        .number => |r| if (r.min > r.max) @compileError("settings spec '" ++ s.path ++ "': min > max"),
        .enumeration => |v| if (v.len == 0) @compileError("settings spec '" ++ s.path ++ "': empty enumeration"),
        else => {},
    }
    for (sections) |sec| {
        if (std.mem.eql(u8, sec, s.section)) break;
    } else @compileError("settings spec '" ++ s.path ++ "': unknown section '" ++ s.section ++ "'");
}

const testing = std.testing;

test "unit: settings: spec default literals are shape-checked" {
    try testing.expect(defaultProblem(.boolean, "true") == null);
    try testing.expect(defaultProblem(.boolean, "1") != null);
    try testing.expect(defaultProblem(.{ .integer = .{ .min = 1, .max = 200 } }, "20") == null);
    try testing.expect(defaultProblem(.{ .integer = .{ .min = 1, .max = 200 } }, "0") != null);
    try testing.expect(defaultProblem(.{ .integer = .{ .min = 1, .max = 200 } }, "1.5") != null);
    try testing.expect(defaultProblem(.{ .number = .{ .min = 0.1, .max = 3 } }, "1.4") == null);
    try testing.expect(defaultProblem(.{ .number = .{ .min = 0.1, .max = 3 } }, "9") != null);
    try testing.expect(defaultProblem(.{ .string = .{} }, "\"\"") == null);
    try testing.expect(defaultProblem(.{ .string = .{} }, "null") != null);
    const modes: []const []const u8 = &.{ "system", "light", "dark" };
    try testing.expect(defaultProblem(.{ .enumeration = modes }, "\"dark\"") == null);
    try testing.expect(defaultProblem(.{ .enumeration = modes }, "\"blue\"") != null);
    try testing.expect(defaultProblem(.color, "\"#3B82F6\"") == null);
    try testing.expect(defaultProblem(.color, "\"#3B82F6CC\"") == null);
    try testing.expect(defaultProblem(.color, "\"blue\"") != null);
    try testing.expect(defaultProblem(.string_list, "[\"localhost\", \"::1\"]") == null);
    try testing.expect(defaultProblem(.string_list, "[1]") != null);
    try testing.expect(defaultProblem(.object, "{}") == null);
    try testing.expect(defaultProblem(.strokes, "\"ctrl+b\"") == null);
    try testing.expect(defaultProblem(.strokes, "[\"ctrl+b\", \"c\"]") == null);
    try testing.expect(defaultProblem(.strokes, "[\"a\", \"b\", \"c\"]") != null);
    try testing.expect(defaultProblem(.strokes, "[]") != null);
    try testing.expect(defaultProblem(.boolean, "tru") != null);
    comptime std.debug.assert(defaultProblem(.boolean, "false") == null);
}

test "unit: settings: spec paths and sections" {
    try testing.expect(pathProblem("sidebar.showPorts") == null);
    try testing.expect(pathProblem("$schema") == null);
    try testing.expect(pathProblem("") != null);
    try testing.expect(pathProblem("a..b") != null);
    try testing.expect(pathProblem("a b") != null);
    const specs = [_]Spec{
        .{ .path = "sidebar.showPorts", .ty = .boolean, .default = "true", .section = "sidebarAppearance", .label = "Show ports", .doc = "" },
    };
    try testing.expect(find(&specs, "sidebar.showPorts") != null);
    try testing.expect(find(&specs, "sidebar") == null);
    try testing.expect(isSection(&specs, "sidebar"));
    try testing.expect(!isSection(&specs, "side"));
    try testing.expect(!isSection(&specs, "sidebar.showPorts"));
    try testing.expect(isWmuxPath("wmux.sidebar.width"));
    comptime checkComptime(specs[0]);
}
