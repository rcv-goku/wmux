//! Validation of settings values against their specs, as reported by
//! `config doctor` (ADR-5.3). Every issue carries the cmux-style JSON path
//! (`$.app.appearance`), a message and the `line:col` of the offending key
//! or value. Severity follows ADR-5.3: type/range/scope problems are errors,
//! unknown keys are warnings, known-but-unimplemented cmux keys are info.

const std = @import("std");
const jsonc = @import("../jsonc.zig");
const spec_mod = @import("spec.zig");
const known_mod = @import("cmux_known_keys.zig");
const manifest = @import("specs_manifest.zig");

const Spec = spec_mod.Spec;
const Type = spec_mod.Type;
const Node = jsonc.Node;
const Allocator = std.mem.Allocator;

/// The newest `schemaVersion` this build understands.
pub const current_schema_version: i64 = 1;

pub const Severity = enum {
    err,
    warning,
    info,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .info => "info",
        };
    }
};

pub const Code = enum {
    syntax,
    type_mismatch,
    out_of_range,
    not_in_enum,
    pattern_mismatch,
    invalid_value,
    scope,
    unknown_key,
    not_yet_supported,
    ignored_on_windows,
    newer_schema_version,
};

pub const Issue = struct {
    severity: Severity,
    code: Code,
    /// JSON path such as `$.app.appearance`.
    path: []const u8,
    message: []const u8,
    offset: usize = 0,
    pos: jsonc.Pos = .{ .line = 1, .col = 1 },

    pub fn format(self: Issue, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}: {s}: {s}: {s}", .{ self.pos.line, self.pos.col, self.severity.label(), self.path, self.message });
    }
};

pub const FileScope = enum { global, project };

pub const Options = struct {
    scope: FileScope = .global,
    specs: []const Spec = manifest.all,
    known: []const known_mod.KnownKey = &known_mod.all,
};

/// Issues of one file. Strings live in `arena`.
pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    issues: []const Issue,

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn errorCount(self: *const Report) usize {
        return countErrors(self.issues);
    }

    pub fn ok(self: *const Report) bool {
        return self.errorCount() == 0;
    }
};

pub fn countErrors(issues: []const Issue) usize {
    var n: usize = 0;
    for (issues) |i| {
        if (i.severity == .err) n += 1;
    }
    return n;
}

/// A value problem: what `checkValue` found wrong.
pub const Problem = struct {
    code: Code,
    message: []const u8,
};

/// Parses `src` as JSONC and validates it. A syntax error yields a single
/// `syntax` issue at the error position.
pub fn validateText(gpa: Allocator, src: []const u8, opts: Options) Allocator.Error!Report {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: jsonc.Diagnostic = .{};
    const root = jsonc.parseInto(arena, src, .{}, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => {
            const issues = try arena.alloc(Issue, 1);
            issues[0] = .{ .severity = .err, .code = .syntax, .path = "$", .message = diag.message, .offset = diag.offset, .pos = diag.pos };
            return .{ .arena = arena_state, .issues = issues };
        },
    };
    var w: Walker = .{ .arena = arena, .src = src, .opts = opts };
    try w.root(&root);
    return .{ .arena = arena_state, .issues = try w.issues.toOwnedSlice(arena) };
}

/// Validates an already parsed root. `src` is the text `root` was parsed
/// from (for positions).
pub fn validateDocument(gpa: Allocator, root: *const Node, src: []const u8, opts: Options) Allocator.Error!Report {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    var w: Walker = .{ .arena = arena_state.allocator(), .src = src, .opts = opts };
    try w.root(root);
    return .{ .arena = arena_state, .issues = try w.issues.toOwnedSlice(w.arena) };
}

/// Errors in `candidate` that `baseline` does not have (same path and
/// message). Warnings and info never block. The returned slice is owned by
/// `gpa`; its strings point into `candidate`.
pub fn introducedIssues(gpa: Allocator, baseline: []const Issue, candidate: []const Issue) Allocator.Error![]Issue {
    var out: std.ArrayList(Issue) = .empty;
    errdefer out.deinit(gpa);
    outer: for (candidate) |c| {
        if (c.severity != .err) continue;
        for (baseline) |b| {
            if (b.severity == .err and std.mem.eql(u8, b.path, c.path) and std.mem.eql(u8, b.message, c.message))
                continue :outer;
        }
        try out.append(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

/// Result of `checkEdit`: the full report of the edited text and the errors
/// the edit introduced (`introduced` borrows from `after`).
pub const EditCheck = struct {
    after: Report,
    introduced: []Issue,
    gpa: Allocator,

    pub fn deinit(self: *EditCheck) void {
        self.gpa.free(self.introduced);
        self.after.deinit();
    }

    /// True when the write may proceed.
    pub fn accepted(self: *const EditCheck) bool {
        return self.introduced.len == 0;
    }
};

/// Validates `before` and `after` and keeps only the errors the edit
/// introduced, so pre-existing problems elsewhere never block an unrelated
/// write (cmux config-transactions rule). The baseline is validated only
/// when the candidate has errors.
pub fn checkEdit(gpa: Allocator, before: []const u8, after: []const u8, opts: Options) Allocator.Error!EditCheck {
    var after_report = try validateText(gpa, after, opts);
    errdefer after_report.deinit();
    if (after_report.errorCount() == 0)
        return .{ .after = after_report, .introduced = &.{}, .gpa = gpa };
    var base = try validateText(gpa, before, opts);
    defer base.deinit();
    const introduced = try introducedIssues(gpa, base.issues, after_report.issues);
    return .{ .after = after_report, .introduced = introduced, .gpa = gpa };
}

const Walker = struct {
    arena: Allocator,
    src: []const u8,
    opts: Options,
    issues: std.ArrayList(Issue) = .empty,

    fn add(self: *Walker, severity: Severity, code: Code, path: []const u8, offset: usize, message: []const u8) Allocator.Error!void {
        try self.issues.append(self.arena, .{
            .severity = severity,
            .code = code,
            .path = path,
            .message = message,
            .offset = offset,
            .pos = jsonc.position(self.src, offset),
        });
    }

    fn root(self: *Walker, node: *const Node) Allocator.Error!void {
        if (node.data != .object) {
            return self.add(.err, .type_mismatch, "$", node.start, try std.fmt.allocPrint(self.arena, "the root must be an object, got {s}", .{node.kindName()}));
        }
        for (node.data.object) |*m| {
            if (std.mem.eql(u8, m.key, "$schema")) {
                if (m.value.data != .string) try self.add(.err, .type_mismatch, "$.$schema", m.value.start, "expected a string");
            } else if (std.mem.eql(u8, m.key, "schemaVersion")) {
                try self.schemaVersion(&m.value);
            } else if (std.mem.eql(u8, m.key, "packs")) {
                try self.packs(&m.value);
            } else if (std.mem.eql(u8, m.key, "settingPresets") and spec_mod.find(self.opts.specs, "settingPresets") == null) {
                try self.presets(m);
            } else {
                try self.member(m, "", "$", true);
            }
        }
    }

    fn schemaVersion(self: *Walker, v: *const Node) Allocator.Error!void {
        const n = v.asInt() orelse
            return self.add(.err, .type_mismatch, "$.schemaVersion", v.start, "expected an integer >= 1");
        if (n < 1) return self.add(.err, .out_of_range, "$.schemaVersion", v.start, "expected an integer >= 1");
        if (n > current_schema_version) try self.add(.warning, .newer_schema_version, "$.schemaVersion", v.start, try std.fmt.allocPrint(
            self.arena,
            "schemaVersion {d} is newer than this build understands ({d}); parsed best effort",
            .{ n, current_schema_version },
        ));
    }

    fn packs(self: *Walker, v: *const Node) Allocator.Error!void {
        const items = switch (v.data) {
            .array => |a| a,
            .null => return,
            else => return self.add(.err, .type_mismatch, "$.packs", v.start, "expected an array of pack paths"),
        };
        for (items, 0..) |*item, i| {
            const path = try std.fmt.allocPrint(self.arena, "$.packs[{d}]", .{i});
            const p: ?[]const u8 = switch (item.data) {
                .string => |s| s,
                .object => if (item.get("path")) |pn| pn.asString() else null,
                else => null,
            };
            const s = p orelse {
                try self.add(.err, .type_mismatch, path, item.start, "expected a path string or an object with a string `path`");
                continue;
            };
            if (s.len == 0) {
                try self.add(.err, .invalid_value, path, item.start, "pack path is empty");
            } else if (isRemoteUrl(s)) {
                try self.add(.err, .invalid_value, path, item.start, "packs must be local paths; http(s) URLs are not supported");
            }
        }
    }

    fn presets(self: *Walker, m: *const jsonc.Member) Allocator.Error!void {
        if (self.opts.scope == .project)
            try self.add(.err, .scope, "$.settingPresets", m.key_start, "only allowed in the global config");
        const members = switch (m.value.data) {
            .object => |o| o,
            .null => return,
            else => return self.add(.err, .type_mismatch, "$.settingPresets", m.value.start, "expected an object of named presets"),
        };
        for (members) |*p| {
            const display = try std.fmt.allocPrint(self.arena, "$.settingPresets.{s}", .{p.key});
            const body = switch (p.value.data) {
                .object => |o| o,
                else => {
                    try self.add(.err, .type_mismatch, display, p.value.start, "a preset must be an object of settings");
                    continue;
                },
            };
            if (body.len == 0) {
                try self.add(.err, .invalid_value, display, p.value.start, "a preset must set at least one setting");
                continue;
            }
            // Presets hold settings only and are checked like a global file.
            const saved = self.opts.scope;
            self.opts.scope = .global;
            defer self.opts.scope = saved;
            for (body) |*inner| try self.member(inner, "", display, true);
        }
    }

    /// Validates one member whose parent is at spec path `prefix` and JSON
    /// path `display_prefix`.
    fn member(self: *Walker, m: *const jsonc.Member, prefix: []const u8, display_prefix: []const u8, check_scope: bool) Allocator.Error!void {
        const path = if (prefix.len == 0) m.key else try std.mem.concat(self.arena, u8, &.{ prefix, ".", m.key });
        const display = try std.mem.concat(self.arena, u8, &.{ display_prefix, ".", m.key });

        if (spec_mod.find(self.opts.specs, path)) |s| {
            if (check_scope and self.opts.scope == .project and !s.scope.allowsProject()) {
                return self.add(.err, .scope, display, m.key_start, "only allowed in the global config");
            }
            if (check_scope and self.opts.scope == .global and !s.scope.allowsGlobal()) {
                return self.add(.err, .scope, display, m.key_start, "only allowed in a project config");
            }
            if (m.value.data == .null) return; // null = unset
            if (try checkValue(self.arena, s.ty, &m.value)) |p| try self.add(.err, p.code, display, m.value.start, p.message);
            return;
        }
        if (spec_mod.isSection(self.opts.specs, path)) {
            switch (m.value.data) {
                .object => |members| for (members) |*child| try self.member(child, path, display, check_scope),
                .null => {},
                else => try self.add(.err, .type_mismatch, display, m.value.start, try std.fmt.allocPrint(self.arena, "expected an object, got {s}", .{m.value.kindName()})),
            }
            return;
        }
        if (known_mod.lookupIn(self.opts.known, path)) |k| {
            if (check_scope and self.opts.scope == .project and !k.project) {
                return self.add(.err, .scope, display, m.key_start, "only allowed in the global config");
            }
            const code: Code = if (k.support == .supported) .not_yet_supported else .ignored_on_windows;
            return self.add(.info, code, display, m.key_start, k.support.note());
        }
        if (known_mod.isSectionIn(self.opts.known, path)) {
            switch (m.value.data) {
                .object => |members| for (members) |*child| try self.member(child, path, display, check_scope),
                .null => {},
                else => try self.add(.err, .type_mismatch, display, m.value.start, try std.fmt.allocPrint(self.arena, "expected an object, got {s}", .{m.value.kindName()})),
            }
            return;
        }
        try self.add(.warning, .unknown_key, display, m.key_start, "unknown key");
    }
};

fn isRemoteUrl(s: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(s, "http://") or std.ascii.startsWithIgnoreCase(s, "https://");
}

/// Checks `node` (not null) against `ty`. Messages are allocated in `arena`.
pub fn checkValue(arena: Allocator, ty: Type, node: *const Node) Allocator.Error!?Problem {
    switch (ty) {
        .boolean => if (node.data != .boolean) return try mismatch(arena, "a boolean", node),
        .integer => |r| {
            if (node.data != .number) return try mismatch(arena, "an integer", node);
            const raw = node.data.number;
            const v = node.asInt() orelse {
                // Integer syntax that does not fit an i64 is a range problem.
                if (std.mem.indexOfAny(u8, raw, ".eE") == null)
                    return .{ .code = .out_of_range, .message = try std.fmt.allocPrint(arena, "{s} is outside the range {d}..{d}", .{ raw, r.min, r.max }) };
                return .{ .code = .type_mismatch, .message = try std.fmt.allocPrint(arena, "expected an integer, got {s}", .{raw}) };
            };
            if (v < r.min or v > r.max) return .{ .code = .out_of_range, .message = try std.fmt.allocPrint(arena, "{d} is outside the range {d}..{d}", .{ v, r.min, r.max }) };
        },
        .number => |r| {
            const v = node.asFloat() orelse return try mismatch(arena, "a number", node);
            if (v < r.min or v > r.max) return .{ .code = .out_of_range, .message = try std.fmt.allocPrint(arena, "{s} is outside the range {d}..{d}", .{ node.data.number, r.min, r.max }) };
        },
        .string => |rule| {
            const s = node.asString() orelse return try mismatch(arena, "a string", node);
            if (rule.pattern) |p| {
                const matched = patternMatches(arena, p, s) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidPattern => return .{ .code = .invalid_value, .message = "the setting's pattern is invalid" },
                };
                if (!matched) return .{ .code = .pattern_mismatch, .message = try std.fmt.allocPrint(arena, "does not match the pattern {s}", .{p}) };
            }
        },
        .enumeration => |values| {
            const s = node.asString() orelse return try mismatch(arena, "a string", node);
            for (values) |v| if (std.mem.eql(u8, v, s)) return null;
            const list = try std.mem.join(arena, ", ", values);
            return .{ .code = .not_in_enum, .message = try std.fmt.allocPrint(arena, "\"{s}\" is not one of: {s}", .{ s, list }) };
        },
        .color => {
            const s = node.asString() orelse return try mismatch(arena, "a color string", node);
            if (!spec_mod.isColor(s)) return .{ .code = .invalid_value, .message = "expected a color like #RRGGBB or #RRGGBBAA" };
        },
        .path => {
            const s = node.asString() orelse return try mismatch(arena, "a path string", node);
            if (std.mem.indexOfScalar(u8, s, 0) != null) return .{ .code = .invalid_value, .message = "path contains a NUL character" };
        },
        .string_list => {
            const items = switch (node.data) {
                .array => |a| a,
                else => return try mismatch(arena, "an array of strings", node),
            };
            for (items, 0..) |*it, i| {
                if (it.data != .string) return .{ .code = .type_mismatch, .message = try std.fmt.allocPrint(arena, "item {d} is {s}, expected a string", .{ i, it.kindName() }) };
            }
        },
        .object => if (node.data != .object) return try mismatch(arena, "an object", node),
        .strokes => switch (node.data) {
            .string => {},
            .array => |items| {
                if (items.len == 0 or items.len > 2) return .{ .code = .invalid_value, .message = "a chord has one or two strokes" };
                for (items) |*it| {
                    const s = it.asString() orelse return .{ .code = .type_mismatch, .message = "chord strokes must be strings" };
                    if (s.len == 0) return .{ .code = .invalid_value, .message = "chord strokes must not be empty" };
                }
            },
            else => return try mismatch(arena, "a shortcut string or a chord array", node),
        },
    }
    return null;
}

fn mismatch(arena: Allocator, expected: []const u8, node: *const Node) Allocator.Error!Problem {
    return .{ .code = .type_mismatch, .message = try std.fmt.allocPrint(arena, "expected {s}, got {s}", .{ expected, node.kindName() }) };
}

// ---------------------------------------------------------------------------
// Patterns: a linear-time (Pike VM) matcher for the JSON Schema `pattern`
// subset settings use: literals, `.`, classes `[a-z_]`/`[^...]`, escapes
// `\d \w \s \D \W \S` and escaped punctuation, groups `( )`/`(?: )`,
// alternation `|`, quantifiers `* + ? {n} {n,} {n,m}` and anchors `^ $`.
// Like JSON Schema, an unanchored pattern matches anywhere in the string.
// Matching is byte-oriented (`.` consumes one byte).

pub const PatternError = error{ OutOfMemory, InvalidPattern };

const max_repeat = 100;

const Class = struct {
    ranges: []const [2]u8,
    negated: bool,

    fn matches(self: Class, c: u8) bool {
        var hit = false;
        for (self.ranges) |r| {
            if (c >= r[0] and c <= r[1]) {
                hit = true;
                break;
            }
        }
        return hit != self.negated;
    }
};

const Inst = union(enum) {
    char: u8,
    any,
    class: Class,
    split: [2]usize,
    jmp: usize,
    bol,
    eol,
    match,
};

const Re = union(enum) {
    empty,
    char: u8,
    any,
    class: Class,
    bol,
    eol,
    concat: []const Re,
    alt: []const Re,
    repeat: struct { sub: *const Re, min: u32, max: ?u32 },
};

const digit_ranges = [_][2]u8{.{ '0', '9' }};
const word_ranges = [_][2]u8{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ 'a', 'z' }, .{ '_', '_' } };
const space_ranges = [_][2]u8{ .{ ' ', ' ' }, .{ '\t', '\r' } };

const ReParser = struct {
    arena: Allocator,
    p: []const u8,
    i: usize = 0,

    fn peek(self: *ReParser) ?u8 {
        return if (self.i < self.p.len) self.p[self.i] else null;
    }

    fn parseAlt(self: *ReParser) PatternError!Re {
        var alts: std.ArrayList(Re) = .empty;
        try alts.append(self.arena, try self.parseConcat());
        while (self.peek() == '|') {
            self.i += 1;
            try alts.append(self.arena, try self.parseConcat());
        }
        if (alts.items.len == 1) return alts.items[0];
        return .{ .alt = try alts.toOwnedSlice(self.arena) };
    }

    fn parseConcat(self: *ReParser) PatternError!Re {
        var items: std.ArrayList(Re) = .empty;
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            var atom = try self.parseAtom();
            atom = try self.parseQuantifiers(atom);
            try items.append(self.arena, atom);
        }
        if (items.items.len == 0) return .empty;
        if (items.items.len == 1) return items.items[0];
        return .{ .concat = try items.toOwnedSlice(self.arena) };
    }

    fn parseQuantifiers(self: *ReParser, atom: Re) PatternError!Re {
        var cur = atom;
        while (self.peek()) |c| {
            var min: u32 = 0;
            var max: ?u32 = null;
            switch (c) {
                '*' => self.i += 1,
                '+' => {
                    min = 1;
                    self.i += 1;
                },
                '?' => {
                    max = 1;
                    self.i += 1;
                },
                '{' => {
                    const close = std.mem.indexOfScalarPos(u8, self.p, self.i, '}') orelse return error.InvalidPattern;
                    const body = self.p[self.i + 1 .. close];
                    if (std.mem.indexOfScalar(u8, body, ',')) |comma| {
                        min = std.fmt.parseInt(u32, body[0..comma], 10) catch return error.InvalidPattern;
                        const rest = body[comma + 1 ..];
                        max = if (rest.len == 0) null else std.fmt.parseInt(u32, rest, 10) catch return error.InvalidPattern;
                    } else {
                        min = std.fmt.parseInt(u32, body, 10) catch return error.InvalidPattern;
                        max = min;
                    }
                    if (min > max_repeat or (max != null and (max.? > max_repeat or max.? < min))) return error.InvalidPattern;
                    self.i = close + 1;
                },
                else => break,
            }
            if (self.peek() == '?') self.i += 1; // lazy: same boolean result
            switch (cur) {
                .bol, .eol, .empty => return error.InvalidPattern,
                else => {},
            }
            const sub = try self.arena.create(Re);
            sub.* = cur;
            cur = .{ .repeat = .{ .sub = sub, .min = min, .max = max } };
        }
        return cur;
    }

    fn parseAtom(self: *ReParser) PatternError!Re {
        const c = self.p[self.i];
        self.i += 1;
        switch (c) {
            '.' => return .any,
            '^' => return .bol,
            '$' => return .eol,
            '(' => {
                if (self.peek() == '?') {
                    if (self.i + 1 < self.p.len and self.p[self.i + 1] == ':') {
                        self.i += 2;
                    } else return error.InvalidPattern;
                }
                const inner = try self.parseAlt();
                if (self.peek() != ')') return error.InvalidPattern;
                self.i += 1;
                return inner;
            },
            '[' => return .{ .class = try self.parseClass() },
            '\\' => return self.parseEscape(false),
            '*', '+', '?', '{', ')' => return error.InvalidPattern,
            else => return .{ .char = c },
        }
    }

    fn parseEscape(self: *ReParser, in_class: bool) PatternError!Re {
        const e = self.peek() orelse return error.InvalidPattern;
        self.i += 1;
        return switch (e) {
            'd' => .{ .class = .{ .ranges = &digit_ranges, .negated = false } },
            'w' => .{ .class = .{ .ranges = &word_ranges, .negated = false } },
            's' => .{ .class = .{ .ranges = &space_ranges, .negated = false } },
            'D' => if (in_class) error.InvalidPattern else .{ .class = .{ .ranges = &digit_ranges, .negated = true } },
            'W' => if (in_class) error.InvalidPattern else .{ .class = .{ .ranges = &word_ranges, .negated = true } },
            'S' => if (in_class) error.InvalidPattern else .{ .class = .{ .ranges = &space_ranges, .negated = true } },
            'n' => .{ .char = '\n' },
            't' => .{ .char = '\t' },
            'r' => .{ .char = '\r' },
            else => if (std.ascii.isAlphanumeric(e)) error.InvalidPattern else .{ .char = e },
        };
    }

    fn parseClass(self: *ReParser) PatternError!Class {
        var negated = false;
        if (self.peek() == '^') {
            negated = true;
            self.i += 1;
        }
        var ranges: std.ArrayList([2]u8) = .empty;
        var first = true;
        while (true) {
            const c = self.peek() orelse return error.InvalidPattern;
            if (c == ']' and !first) {
                self.i += 1;
                break;
            }
            first = false;
            var lo: u8 = c;
            self.i += 1;
            if (c == '\\') {
                switch (try self.parseEscape(true)) {
                    .char => |ch| lo = ch,
                    .class => |cls| {
                        try ranges.appendSlice(self.arena, cls.ranges);
                        continue;
                    },
                    else => unreachable,
                }
            }
            if (self.peek() == '-' and self.i + 1 < self.p.len and self.p[self.i + 1] != ']') {
                self.i += 1;
                var hi = self.p[self.i];
                self.i += 1;
                if (hi == '\\') {
                    switch (try self.parseEscape(true)) {
                        .char => |ch| hi = ch,
                        else => return error.InvalidPattern,
                    }
                }
                if (hi < lo) return error.InvalidPattern;
                try ranges.append(self.arena, .{ lo, hi });
            } else {
                try ranges.append(self.arena, .{ lo, lo });
            }
        }
        return .{ .ranges = try ranges.toOwnedSlice(self.arena), .negated = negated };
    }
};

const Compiler = struct {
    arena: Allocator,
    prog: std.ArrayList(Inst) = .empty,

    fn emit(self: *Compiler, inst: Inst) PatternError!usize {
        try self.prog.append(self.arena, inst);
        return self.prog.items.len - 1;
    }

    fn compile(self: *Compiler, re: *const Re) PatternError!void {
        if (self.prog.items.len > 10_000) return error.InvalidPattern;
        switch (re.*) {
            .empty => {},
            .char => |c| _ = try self.emit(.{ .char = c }),
            .any => _ = try self.emit(.any),
            .class => |c| _ = try self.emit(.{ .class = c }),
            .bol => _ = try self.emit(.bol),
            .eol => _ = try self.emit(.eol),
            .concat => |items| for (items) |*it| try self.compile(it),
            .alt => |alts| {
                var jumps: std.ArrayList(usize) = .empty;
                for (alts, 0..) |*a, i| {
                    if (i + 1 < alts.len) {
                        const split = try self.emit(.{ .split = .{ 0, 0 } });
                        try self.compile(a);
                        try jumps.append(self.arena, try self.emit(.{ .jmp = 0 }));
                        self.prog.items[split].split = .{ split + 1, self.prog.items.len };
                    } else try self.compile(a);
                }
                for (jumps.items) |j| self.prog.items[j].jmp = self.prog.items.len;
            },
            .repeat => |r| {
                for (0..r.min) |_| try self.compile(r.sub);
                if (r.max) |max| {
                    var splits: std.ArrayList(usize) = .empty;
                    for (r.min..max) |_| {
                        try splits.append(self.arena, try self.emit(.{ .split = .{ 0, 0 } }));
                        try self.compile(r.sub);
                    }
                    for (splits.items) |s| self.prog.items[s].split = .{ s + 1, self.prog.items.len };
                } else {
                    const split = try self.emit(.{ .split = .{ 0, 0 } });
                    try self.compile(r.sub);
                    _ = try self.emit(.{ .jmp = split });
                    self.prog.items[split].split = .{ split + 1, self.prog.items.len };
                }
            },
        }
    }
};

/// True when `pattern` matches somewhere in `text`.
pub fn patternMatches(gpa: Allocator, pattern: []const u8, text: []const u8) PatternError!bool {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parser: ReParser = .{ .arena = arena, .p = pattern };
    const re = try parser.parseAlt();
    if (parser.i != pattern.len) return error.InvalidPattern;
    var comp: Compiler = .{ .arena = arena };
    try comp.compile(&re);
    _ = try comp.emit(.match);
    const prog = comp.prog.items;

    const seen = try arena.alloc(usize, prog.len);
    @memset(seen, std.math.maxInt(usize));
    var clist: std.ArrayList(usize) = .empty;
    var nlist: std.ArrayList(usize) = .empty;
    try clist.ensureTotalCapacity(arena, prog.len);
    try nlist.ensureTotalCapacity(arena, prog.len);

    var gen: usize = 0;
    var sp: usize = 0;
    while (true) : (sp += 1) {
        // Unanchored search: a new thread starts at every position.
        if (addThread(prog, seen, gen, &clist, 0, sp, text.len)) return true;
        if (sp >= text.len) break;
        gen += 1;
        nlist.clearRetainingCapacity();
        const c = text[sp];
        for (clist.items) |pc| {
            const ok = switch (prog[pc]) {
                .char => |want| c == want,
                .any => c != '\n',
                .class => |cls| cls.matches(c),
                else => false,
            };
            if (ok and addThread(prog, seen, gen, &nlist, pc + 1, sp + 1, text.len)) return true;
        }
        std.mem.swap(std.ArrayList(usize), &clist, &nlist);
    }
    return false;
}

/// Adds `pc` (following jumps and zero-width assertions) to `list`. Returns
/// true when a thread reaches `match`.
fn addThread(prog: []const Inst, seen: []usize, gen: usize, list: *std.ArrayList(usize), pc: usize, sp: usize, len: usize) bool {
    if (seen[pc] == gen) return false;
    seen[pc] = gen;
    switch (prog[pc]) {
        .match => return true,
        .jmp => |t| return addThread(prog, seen, gen, list, t, sp, len),
        .split => |s| return addThread(prog, seen, gen, list, s[0], sp, len) or
            addThread(prog, seen, gen, list, s[1], sp, len),
        .bol => return sp == 0 and addThread(prog, seen, gen, list, pc + 1, sp, len),
        .eol => return sp == len and addThread(prog, seen, gen, list, pc + 1, sp, len),
        else => {
            list.appendAssumeCapacity(pc);
            return false;
        },
    }
}

// ---------------------------------------------------------------------------
// Test fixtures (used by the unit tests of resolve.zig and schema_dump.zig
// too): a handful of realistic cmux and wmux settings.

pub const test_fixture_specs = [_]Spec{
    .{ .path = "app.appearance", .ty = .{ .enumeration = &.{ "system", "light", "dark" } }, .default = "\"system\"", .section = "app", .label = "Theme", .doc = "Light, dark or follow the system." },
    .{ .path = "app.minimalMode", .ty = .boolean, .default = "false", .section = "app", .label = "Minimal mode", .doc = "Hide chrome." },
    .{ .path = "app.paneResizeStepPixels", .ty = .{ .integer = .{ .min = 1, .max = 200 } }, .default = "20", .section = "app", .label = "Pane resize step", .doc = "Pixels per keypress." },
    .{ .path = "terminal.scrollSpeed", .ty = .{ .number = .{ .min = 0.1, .max = 3 } }, .default = "1", .section = "terminal", .label = "Scroll speed", .doc = "Scroll multiplier." },
    .{ .path = "terminal.copyOnSelect", .ty = .boolean, .default = "false", .section = "terminal", .label = "Copy on select", .doc = "Copy selected text.", .ghostty_override = "copy-on-select" },
    .{ .path = "fileEditor.wordWrap", .ty = .boolean, .default = "true", .section = "app", .label = "Word wrap", .doc = "Soft-wrap long lines.", .palette_toggle = true },
    .{ .path = "sidebar.showPorts", .ty = .boolean, .default = "true", .section = "sidebarAppearance", .label = "Show ports", .doc = "Listening ports per workspace.", .keywords = &.{"ports"} },
    .{ .path = "activePaneBorderColor", .ty = .color, .default = "\"#3B82F6\"", .section = "app", .label = "Active pane border", .doc = "Focused pane border." },
    .{ .path = "browser.urlAllowlist", .ty = .string_list, .default = "[]", .section = "browser", .label = "URL allowlist", .doc = "Allowed hosts." },
    .{ .path = "notifications.hooks", .ty = .object, .default = "{}", .scope = .both, .section = "automation", .label = "Notification hooks", .doc = "Hooks." },
    .{ .path = "automation.socketControlMode", .ty = .{ .enumeration = &.{ "off", "cmuxOnly", "automation", "password", "allowAll", "readOnly" } }, .default = "\"cmuxOnly\"", .section = "automation", .label = "Socket control", .doc = "Who may connect.", .apply = .restart },
    .{ .path = "automation.autoNamingAgent", .ty = .{ .string = .{ .pattern = "^[a-z0-9-]+$" } }, .default = "\"auto\"", .section = "automation", .label = "Auto-naming agent", .doc = "Agent slug." },
    .{ .path = "automation.claudeBinaryPath", .ty = .path, .default = "\"\"", .section = "automation", .label = "Claude binary", .doc = "Path override.", .policy_lockable = false },
    .{ .path = "wmux.sidebar.visible", .ty = .boolean, .default = "true", .section = "windows", .label = "Show sidebar", .doc = "Left sidebar.", .cmux_compat = false },
    .{ .path = "wmux.sidebar.width", .ty = .{ .integer = .{ .min = 120, .max = 600 } }, .default = "220", .section = "windows", .label = "Sidebar width", .doc = "Pixels.", .cmux_compat = false },
    .{ .path = "wmux.quickTerminal.hotkey", .ty = .strokes, .default = "\"ctrl+`\"", .section = "globalHotkey", .label = "Quick terminal hotkey", .doc = "Global hotkey.", .cmux_compat = false },
};

comptime {
    _ = manifest.aggregate(.{struct {
        pub const specs = test_fixture_specs;
    }});
}

const testing = std.testing;

fn fixtureOpts(scope: FileScope) Options {
    return .{ .scope = scope, .specs = &test_fixture_specs };
}

fn expectIssue(report: *const Report, severity: Severity, code: Code, path: []const u8, line: u32, col: u32) !void {
    for (report.issues) |i| {
        if (i.code == code and std.mem.eql(u8, i.path, path)) {
            try testing.expectEqual(severity, i.severity);
            try testing.expectEqual(line, i.pos.line);
            try testing.expectEqual(col, i.pos.col);
            return;
        }
    }
    std.debug.print("missing issue {s} {s}; got:\n", .{ @tagName(code), path });
    for (report.issues) |i| std.debug.print("  {f}\n", .{i});
    return error.TestExpectedIssue;
}

test "unit: settings: a valid file has no issues" {
    var r = try validateText(testing.allocator,
        \\{
        \\  "$schema": "https://example.invalid/wmux.schema.json",
        \\  "schemaVersion": 1,
        \\  // comment
        \\  "app": {"appearance": "dark", "minimalMode": null},
        \\  "terminal": {"scrollSpeed": 1.4, "copyOnSelect": true,},
        \\  "activePaneBorderColor": "#112233aa",
        \\  "browser": {"urlAllowlist": ["localhost", "*.internal.example"]},
        \\  "automation": {"autoNamingAgent": "claude-2"},
        \\  "wmux": {"sidebar": {"width": 300}, "quickTerminal": {"hotkey": ["ctrl+b", "c"]}}
        \\}
    , fixtureOpts(.global));
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.issues.len);
    try testing.expect(r.ok());
}

test "unit: settings: type errors report positions" {
    var r = try validateText(testing.allocator,
        \\{
        \\  "app": {
        \\    "appearance": "blue",
        \\    "minimalMode": "yes",
        \\    "paneResizeStepPixels": 1.5
        \\  },
        \\  "terminal": {"scrollSpeed": 9},
        \\  "activePaneBorderColor": "blue",
        \\  "browser": {"urlAllowlist": ["a", 2]},
        \\  "automation": {"autoNamingAgent": "Bad Name"},
        \\  "wmux": {"sidebar": {"width": 50}, "quickTerminal": {"hotkey": ["a", "b", "c"]}},
        \\  "sidebar": true
        \\}
    , fixtureOpts(.global));
    defer r.deinit();
    try expectIssue(&r, .err, .not_in_enum, "$.app.appearance", 3, 19);
    try expectIssue(&r, .err, .type_mismatch, "$.app.minimalMode", 4, 20);
    try expectIssue(&r, .err, .type_mismatch, "$.app.paneResizeStepPixels", 5, 29);
    try expectIssue(&r, .err, .out_of_range, "$.terminal.scrollSpeed", 7, 31);
    try expectIssue(&r, .err, .invalid_value, "$.activePaneBorderColor", 8, 28);
    try expectIssue(&r, .err, .type_mismatch, "$.browser.urlAllowlist", 9, 31);
    try expectIssue(&r, .err, .pattern_mismatch, "$.automation.autoNamingAgent", 10, 37);
    try expectIssue(&r, .err, .out_of_range, "$.wmux.sidebar.width", 11, 33);
    try expectIssue(&r, .err, .invalid_value, "$.wmux.quickTerminal.hotkey", 11, 66);
    try expectIssue(&r, .err, .type_mismatch, "$.sidebar", 12, 14);
    try testing.expectEqual(@as(usize, 10), r.errorCount());
    for (r.issues) |i| if (i.code == .not_in_enum) try testing.expectEqualStrings("\"blue\" is not one of: system, light, dark", i.message);
}

test "unit: settings: numeric boundaries" {
    const cases = [_]struct { []const u8, ?Code, []const u8 }{
        .{ "{\"app\": {\"paneResizeStepPixels\": 99999999999999999999}}", .out_of_range, "99999999999999999999 is outside the range 1..200" },
        .{ "{\"app\": {\"paneResizeStepPixels\": -9223372036854775809}}", .out_of_range, "-9223372036854775809 is outside the range 1..200" },
        .{ "{\"app\": {\"paneResizeStepPixels\": 1.0}}", .type_mismatch, "expected an integer, got 1.0" },
        .{ "{\"app\": {\"paneResizeStepPixels\": 2e1}}", .type_mismatch, "expected an integer, got 2e1" },
        .{ "{\"app\": {\"paneResizeStepPixels\": 1}}", null, "" },
        .{ "{\"app\": {\"paneResizeStepPixels\": 200}}", null, "" },
        .{ "{\"app\": {\"paneResizeStepPixels\": 201}}", .out_of_range, "201 is outside the range 1..200" },
        .{ "{\"terminal\": {\"scrollSpeed\": 0.1}}", null, "" },
        .{ "{\"terminal\": {\"scrollSpeed\": 3e0}}", null, "" },
        .{ "{\"terminal\": {\"scrollSpeed\": 1e400}}", .out_of_range, "1e400 is outside the range 0.1..3" },
        .{ "{\"terminal\": {\"scrollSpeed\": 0.09999}}", .out_of_range, "0.09999 is outside the range 0.1..3" },
    };
    for (cases) |c| {
        var r = try validateText(testing.allocator, c[0], fixtureOpts(.global));
        defer r.deinit();
        if (c[1]) |code| {
            try testing.expectEqual(@as(usize, 1), r.issues.len);
            try testing.expectEqual(code, r.issues[0].code);
            try testing.expectEqualStrings(c[2], r.issues[0].message);
        } else try testing.expectEqual(@as(usize, 0), r.issues.len);
    }
}

test "unit: settings: unknown keys warn and known cmux keys inform" {
    var r = try validateText(testing.allocator,
        \\{
        \\  "app": {"appearance": "dark", "bogus": 1, "confirmQuit": "never"},
        \\  "mobile": {"artifactFolderAccess": "subtree"},
        \\  "computerUse": {"enabled": true},
        \\  "notThere": {},
        \\  "sidebar": {"beta": {"workspaceTodos": {"checklistStyle": "inline"}}}
        \\}
    , fixtureOpts(.global));
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.errorCount());
    try expectIssue(&r, .warning, .unknown_key, "$.app.bogus", 2, 33);
    try expectIssue(&r, .info, .not_yet_supported, "$.app.confirmQuit", 2, 45);
    try expectIssue(&r, .info, .ignored_on_windows, "$.mobile", 3, 3);
    try expectIssue(&r, .info, .ignored_on_windows, "$.computerUse.enabled", 4, 19);
    try expectIssue(&r, .warning, .unknown_key, "$.notThere", 5, 3);
    try expectIssue(&r, .info, .not_yet_supported, "$.sidebar.beta.workspaceTodos.checklistStyle", 6, 43);

    var r2 = try validateText(testing.allocator, "{\"terminal\": 5, \"mobile\": 5}", fixtureOpts(.global));
    defer r2.deinit();
    try expectIssue(&r2, .err, .type_mismatch, "$.terminal", 1, 14);
    try expectIssue(&r2, .info, .ignored_on_windows, "$.mobile", 1, 17);
    var r3 = try validateText(testing.allocator, "{\"app\": []}", .{});
    defer r3.deinit();
    try expectIssue(&r3, .err, .type_mismatch, "$.app", 1, 9);
    for (r.issues) |i| if (i.code == .ignored_on_windows) try testing.expectEqualStrings("ignored on Windows", i.message);
}

test "unit: settings: project files reject global-only keys" {
    var r = try validateText(testing.allocator,
        \\{
        \\  "app": {"minimalMode": true},
        \\  "notifications": {"hooks": {"x": {}}},
        \\  "actions": {"a": {}},
        \\  "terminal": {"uploadCommands": []},
        \\  "settingPresets": {"p": {"app": {"minimalMode": true}}}
        \\}
    , fixtureOpts(.project));
    defer r.deinit();
    try expectIssue(&r, .err, .scope, "$.app.minimalMode", 2, 11);
    try expectIssue(&r, .info, .not_yet_supported, "$.actions", 4, 3);
    try expectIssue(&r, .err, .scope, "$.terminal.uploadCommands", 5, 16);
    try expectIssue(&r, .err, .scope, "$.settingPresets", 6, 3);
    try testing.expectEqual(@as(usize, 3), r.errorCount());

    const project_only = [_]Spec{.{ .path = "workspace.launch", .ty = .object, .default = "{}", .scope = .project, .section = "app", .label = "Launch", .doc = "" }};
    var g = try validateText(testing.allocator, "{\"workspace\": {\"launch\": {}}}", .{ .specs = &project_only });
    defer g.deinit();
    try expectIssue(&g, .err, .scope, "$.workspace.launch", 1, 16);
    var p = try validateText(testing.allocator, "{\"workspace\": {\"launch\": {}}}", .{ .scope = .project, .specs = &project_only });
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.issues.len);
}

test "unit: settings: root meta keys" {
    var r = try validateText(testing.allocator,
        \\{"schemaVersion": 7, "packs": ["./p", {"path": "dir"}, "https://x.example/p.json", 3, ""]}
    , fixtureOpts(.global));
    defer r.deinit();
    try expectIssue(&r, .warning, .newer_schema_version, "$.schemaVersion", 1, 19);
    try expectIssue(&r, .err, .invalid_value, "$.packs[2]", 1, 56);
    try expectIssue(&r, .err, .type_mismatch, "$.packs[3]", 1, 84);
    try expectIssue(&r, .err, .invalid_value, "$.packs[4]", 1, 87);
    try testing.expectEqual(@as(usize, 3), r.errorCount());

    var r2 = try validateText(testing.allocator, "{\"schemaVersion\": 0, \"$schema\": 1}", fixtureOpts(.global));
    defer r2.deinit();
    try expectIssue(&r2, .err, .out_of_range, "$.schemaVersion", 1, 19);
    try expectIssue(&r2, .err, .type_mismatch, "$.$schema", 1, 33);
}

test "unit: settings: setting presets are validated" {
    var r = try validateText(testing.allocator,
        \\{"settingPresets": {"quiet": {"sidebar": {"showPorts": false}}, "bad": {"app": {"appearance": 3}}, "empty": {}, "x": 1}}
    , fixtureOpts(.global));
    defer r.deinit();
    try expectIssue(&r, .err, .type_mismatch, "$.settingPresets.bad.app.appearance", 1, 95);
    try expectIssue(&r, .err, .invalid_value, "$.settingPresets.empty", 1, 109);
    try expectIssue(&r, .err, .type_mismatch, "$.settingPresets.x", 1, 118);
    try testing.expectEqual(@as(usize, 3), r.errorCount());
}

test "unit: settings: syntax errors become one issue" {
    var r = try validateText(testing.allocator, "{\n  \"app\": {\"appearance\": \"dark\",,}\n}", fixtureOpts(.global));
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.issues.len);
    try expectIssue(&r, .err, .syntax, "$", 2, 32);
    var r2 = try validateText(testing.allocator, "[1]", fixtureOpts(.global));
    defer r2.deinit();
    try expectIssue(&r2, .err, .type_mismatch, "$", 1, 1);
    var r3 = try validateText(testing.allocator, "{} // trailing comment\n", fixtureOpts(.global));
    defer r3.deinit();
    try testing.expectEqual(@as(usize, 0), r3.issues.len);
}

test "unit: settings: edits are refused only for issues they introduce" {
    const before = "{\n  \"app\": {\"appearance\": \"blue\"},\n  \"terminal\": {\"scrollSpeed\": 1}\n}";
    // Unrelated valid change: accepted despite the pre-existing error.
    var ok = try checkEdit(testing.allocator, before, "{\n  \"app\": {\"appearance\": \"blue\"},\n  \"terminal\": {\"scrollSpeed\": 2}\n}", fixtureOpts(.global));
    defer ok.deinit();
    try testing.expect(ok.accepted());
    try testing.expectEqual(@as(usize, 1), ok.after.errorCount());
    // A new range error: refused, and only that error is reported.
    var bad = try checkEdit(testing.allocator, before, "{\n  \"app\": {\"appearance\": \"blue\"},\n  \"terminal\": {\"scrollSpeed\": 9}\n}", fixtureOpts(.global));
    defer bad.deinit();
    try testing.expect(!bad.accepted());
    try testing.expectEqual(@as(usize, 1), bad.introduced.len);
    try testing.expectEqualStrings("$.terminal.scrollSpeed", bad.introduced[0].path);
    // Breaking the syntax is always introduced.
    var syn = try checkEdit(testing.allocator, before, "{", fixtureOpts(.global));
    defer syn.deinit();
    try testing.expect(!syn.accepted());
}

test "unit: settings: every fixture default passes validation" {
    for (test_fixture_specs) |s| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const node = try jsonc.parseInto(arena.allocator(), s.default, .{}, null);
        try testing.expect((try checkValue(arena.allocator(), s.ty, &node)) == null);
    }
}

test "unit: settings: every registered spec default passes validation" {
    for (manifest.all) |s| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const node = try jsonc.parseInto(arena.allocator(), s.default, .{}, null);
        if (try checkValue(arena.allocator(), s.ty, &node)) |p| {
            std.debug.print("spec {s}: default {s}: {s}\n", .{ s.path, s.default, p.message });
            return error.TestBadDefault;
        }
    }
}

test "unit: settings: pattern matcher subset" {
    const gpa = testing.allocator;
    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "^[A-Za-z0-9._-]+$", "team.claude_1-x", true },
        .{ "^[A-Za-z0-9._-]+$", "bad id", false },
        .{ "^[A-Za-z0-9._-]+$", "", false },
        .{ "abc", "xxabcxx", true },
        .{ "^abc", "xxabc", false },
        .{ "c$", "abc", true },
        .{ "^(foo|bar)+$", "foobarfoo", true },
        .{ "^(?:foo|bar)+$", "foobaz", false },
        .{ "^a{2,3}$", "aa", true },
        .{ "^a{2,3}$", "aaaa", false },
        .{ "^a{2}$", "aa", true },
        .{ "^a{2,}$", "aaaaa", true },
        .{ "^\\d+(\\.\\d+)?$", "1.25", true },
        .{ "^\\d+(\\.\\d+)?$", "1.", false },
        .{ "^\\w+\\s\\S$", "ab c", true },
        .{ "^[^/]+$", "a/b", false },
        .{ "^.?$", "", true },
        .{ "^#[0-9a-fA-F]{6}$", "#00ffAA", true },
        .{ "^[\\]x]+$", "]x]", true },
        .{ "^$", "", true },
        .{ "a*?b", "aaab", true },
        .{ "^(a|ab)(c|bcd)(d*)$", "abcd", true },
    };
    for (cases) |c| {
        const got = try patternMatches(gpa, c[0], c[1]);
        if (got != c[2]) {
            std.debug.print("pattern {s} on '{s}': got {}\n", .{ c[0], c[1], got });
            return error.TestPatternMismatch;
        }
    }
    for ([_][]const u8{ "(", "a)", "[a", "*a", "a{3,1}", "a{999}", "\\q", "(?=a)", "^*" }) |bad| {
        try testing.expectError(error.InvalidPattern, patternMatches(gpa, bad, "a"));
    }
    // Linear time: a classic catastrophic-backtracking case stays fast.
    const long = "a" ** 5000;
    try testing.expect(!try patternMatches(gpa, "^(a+)+b$", long));
}
