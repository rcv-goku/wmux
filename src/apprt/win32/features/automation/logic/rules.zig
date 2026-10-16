//! Automation rules file (cli-automations-config, cli-automation-actions).
//!
//! `STATE\automations.json` (ARCHITECTURE Appendix G) holds
//! `{"version": 1, "rules": [...]}`. Each rule has `id`, `enabled`
//! (default true), `when` (`event` and/or `category`, exact or with one `*`
//! prefix/suffix wildcard), `where` (payload predicates), `rate_limit`
//! (`interval_seconds`, `maximum`; default one firing per second) and `then`
//! (ordered `notify` / `rpc` / `run` / `webhook` actions).
//!
//! `parse` never fails on user input: it returns the valid rules plus every
//! issue with its JSON path and `line:col`. A file-level error (syntax, size,
//! nesting, root shape, version) loads no rules; an error inside a rule
//! drops only that rule. Warnings (unknown keys, events missing from the
//! catalog, placeholders a notify template would leave literal) never drop
//! anything. The source is copied into the config's arena, so the config
//! outlives the caller's buffer.

const std = @import("std");
const wmux_proto = @import("wmux_proto");
const ratelimit = @import("ratelimit.zig");
const template = @import("template.zig");
const webhook = @import("webhook.zig");
const loop_guard = @import("loop_guard.zig");
const fold = @import("fold.zig");

const jsonc = wmux_proto.jsonc;
const catalog = wmux_proto.events_catalog;
const json_edit = wmux_proto.json_edit;
const Node = jsonc.Node;
const Allocator = std.mem.Allocator;

/// File name under STATE.
pub const file_name = "automations.json";
pub const current_version: i64 = 1;
/// Largest rules file and test event (`@file`) accepted: 4 MiB.
pub const max_bytes: usize = 4 * 1024 * 1024;
/// Nesting guard shared by the rules loader and test events.
pub const max_depth: u32 = 64;
pub const max_id_len: usize = loop_guard.max_rule_id_len;
/// `run` timeout: default 60 s, at most 300 s.
pub const default_run_timeout_ms: u64 = 60_000;
pub const max_run_timeout_ms: u64 = 300_000;

/// CLI strings (cli-automation-cli).
pub const msg = struct {
    pub const usage_first_line = "Usage: cmux automation <list|show|test|enable|disable|logs|reload> [args]";
    /// cmux names `~/.cmuxterm/automations.json`; wmux keeps the file under STATE.
    pub const usage_rules_note = "Rules live in %LOCALAPPDATA%\\wmux\\<channel>\\automations.json.";
    pub const test_requires_event = "automation test requires --event <json>";
    pub const test_event_not_object = "automation test event must be a JSON object";
    pub const no_rules = "No automation rules";
    pub const rule_not_found_prefix = "Automation rule not found: ";
    pub const enabled_prefix = "Enabled ";
    pub const disabled_prefix = "Disabled ";
};

/// `Automation rule not found: <id>`. Owned by `gpa`.
pub fn ruleNotFoundMessage(gpa: Allocator, id: []const u8) Allocator.Error![]u8 {
    return std.mem.concat(gpa, u8, &.{ msg.rule_not_found_prefix, id });
}

pub const Severity = enum {
    err,
    warning,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
        };
    }
};

pub const Issue = struct {
    severity: Severity,
    /// JSON path such as `$.rules[0].when.event`.
    path: []const u8,
    message: []const u8,
    offset: usize = 0,
    pos: jsonc.Pos = .{ .line = 1, .col = 1 },

    pub fn format(self: Issue, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}: {s}: {s}: {s}", .{ self.pos.line, self.pos.col, self.severity.label(), self.path, self.message });
    }
};

/// An event or category selector: exact, `prefix*`, `*suffix` or `*`.
/// Comparison ignores case (fold.zig).
pub const Pattern = struct {
    text: []const u8,
    kind: Kind,
    /// `text` without the `*`.
    stem: []const u8,

    pub const Kind = enum { exact, prefix, suffix, any };

    /// Null for an empty text, a `*` in the middle or `*` at both ends.
    pub fn parse(text: []const u8) ?Pattern {
        if (text.len == 0) return null;
        if (std.mem.eql(u8, text, "*")) return .{ .text = text, .kind = .any, .stem = "" };
        const stars = std.mem.count(u8, text, "*");
        if (stars == 0) return .{ .text = text, .kind = .exact, .stem = text };
        if (stars > 1) return null;
        if (text[text.len - 1] == '*') return .{ .text = text, .kind = .prefix, .stem = text[0 .. text.len - 1] };
        if (text[0] == '*') return .{ .text = text, .kind = .suffix, .stem = text[1..] };
        return null;
    }

    pub fn matches(self: Pattern, value: []const u8) bool {
        return switch (self.kind) {
            .any => true,
            .exact => fold.eql(value, self.stem),
            .prefix => fold.startsWith(value, self.stem),
            .suffix => fold.endsWith(value, self.stem),
        };
    }
};

pub const When = struct {
    event: ?Pattern = null,
    category: ?Pattern = null,
};

pub const Scalar = union(enum) {
    null,
    boolean: bool,
    /// Raw JSON number text and its value.
    number: struct { raw: []const u8, value: f64 },
    string: []const u8,
};

/// A predicate: every op must hold (a scalar is a single `equals`).
pub const Cond = struct {
    ops: []const Op,
};

pub const Op = union(enum) {
    equals: Scalar,
    contains: []const u8,
    prefix: []const u8,
    suffix: []const u8,
    in: []const Scalar,
    not: *const Cond,
};

/// The common `where` aliases (resolved by match.zig).
pub const Alias = enum {
    workspace_tag,
    workspace_title,
    title,
    agent,
    surface_kind,

    pub fn parse(key: []const u8) ?Alias {
        const map = std.StaticStringMap(Alias).initComptime(.{
            .{ "workspace.tag", .workspace_tag },
            .{ "workspace.title", .workspace_title },
            .{ "title", .title },
            .{ "agent", .agent },
            .{ "surface.kind", .surface_kind },
        });
        return map.get(key);
    }
};

pub const Predicate = struct {
    key: []const u8,
    alias: ?Alias,
    cond: Cond,
};

pub const Notify = struct {
    title: ?[]const u8 = null,
    subtitle: ?[]const u8 = null,
    body: ?[]const u8 = null,
    message: ?[]const u8 = null,
    /// Null targets the event's own workspace / surface.
    workspace_id: ?[]const u8 = null,
    surface_id: ?[]const u8 = null,
};

pub const Rpc = struct {
    method: []const u8,
    /// `params` as written (an object), or null.
    params: ?*const Node = null,
    /// `allow_focus: true` or `focus: true`; focus is suppressed otherwise (G4).
    allow_focus: bool = false,
};

pub const Run = struct {
    /// `command`, or `cmd` when `command` is absent.
    command: []const u8,
    timeout_ms: u64 = default_run_timeout_ms,
};

pub const Webhook = struct {
    url: []const u8,
    headers: []const webhook.Header = &.{},
};

pub const Action = union(enum) {
    notify: Notify,
    rpc: Rpc,
    run: Run,
    webhook: Webhook,

    pub fn typeName(self: Action) []const u8 {
        return @tagName(self);
    }
};

pub const Rule = struct {
    id: []const u8,
    enabled: bool = true,
    when: When,
    where: []const Predicate = &.{},
    rate_limit: ratelimit.Limit = ratelimit.default,
    then: []const Action = &.{},
    /// Index in the file's `rules` array.
    index: usize,
    /// The rule as written (for `show`, redacted through redact.zig).
    node: *const Node,
    pos: jsonc.Pos,
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    /// Copy of the source text.
    src: []const u8,
    version: i64 = current_version,
    /// Valid rules in file order.
    rules: []const Rule = &.{},
    /// Every issue in document order.
    issues: []const Issue = &.{},
    /// Ids of rules dropped for errors (when they had a usable id).
    invalid_ids: []const []const u8 = &.{},

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn find(self: *const Config, id: []const u8) ?*const Rule {
        for (self.rules) |*r| {
            if (std.mem.eql(u8, r.id, id)) return r;
        }
        return null;
    }

    pub fn errorCount(self: *const Config) usize {
        var n: usize = 0;
        for (self.issues) |i| {
            if (i.severity == .err) n += 1;
        }
        return n;
    }

    /// Rule ids and limits for `ratelimit.Table.sync`. Owned by `gpa`.
    pub fn limits(self: *const Config, gpa: Allocator) Allocator.Error![]ratelimit.Table.RuleLimit {
        const out = try gpa.alloc(ratelimit.Table.RuleLimit, self.rules.len);
        for (self.rules, out) |r, *o| o.* = .{ .id = r.id, .limit = r.rate_limit };
        return out;
    }
};

/// An empty config (no file yet).
pub fn empty(gpa: Allocator) Config {
    return .{ .arena = .init(gpa), .src = "" };
}

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    /// Positions of rule starts (visited in document order, so it never rewinds).
    cursor: jsonc.PosCursor = .{},
    issues: std.ArrayList(Issue) = .empty,
    /// Errors recorded for the current rule.
    rule_errors: usize = 0,

    /// Objects with more members than this use a hash map for duplicate checks.
    const small_object = 16;

    fn pos(self: *Parser, offset: usize) jsonc.Pos {
        return self.cursor.advance(self.src, offset);
    }

    /// Records an issue; `finishIssues` fills in its position. Issues are
    /// not produced in document order (a rule's keys are checked in a fixed
    /// order), so computing positions here would rewind the cursor to the
    /// top of the file for each out-of-order issue: quadratic on big files.
    fn add(self: *Parser, sev: Severity, path: []const u8, offset: usize, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const message = try std.fmt.allocPrint(self.arena, fmt, args);
        if (sev == .err) self.rule_errors += 1;
        try self.issues.append(self.arena, .{ .severity = sev, .path = path, .message = message, .offset = offset });
    }

    /// Sorts the issues into document order (stable, O(n log n)) and computes
    /// every position in one forward pass over the source.
    fn finishIssues(self: *Parser) Allocator.Error![]const Issue {
        const items = self.issues.items;
        std.sort.block(Issue, items, {}, struct {
            fn lt(_: void, a: Issue, b: Issue) bool {
                return a.offset < b.offset;
            }
        }.lt);
        var cursor: jsonc.PosCursor = .{};
        for (items) |*i| i.pos = cursor.advance(self.src, i.offset);
        return self.issues.toOwnedSlice(self.arena);
    }

    fn err(self: *Parser, path: []const u8, offset: usize, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        return self.add(.err, path, offset, fmt, args);
    }

    fn warn(self: *Parser, path: []const u8, offset: usize, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        return self.add(.warning, path, offset, fmt, args);
    }

    fn sub(self: *Parser, base: []const u8, key: []const u8) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ base, key });
    }

    fn idx(self: *Parser, base: []const u8, i: usize) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ base, i });
    }

    fn expectObject(self: *Parser, node: *const Node, path: []const u8) Allocator.Error!?[]const jsonc.Member {
        return switch (node.data) {
            .object => |m| m,
            else => {
                try self.err(path, node.start, "expected an object, found {s}", .{node.kindName()});
                return null;
            },
        };
    }

    fn expectString(self: *Parser, node: *const Node, path: []const u8) Allocator.Error!?[]const u8 {
        return switch (node.data) {
            .string => |s| s,
            else => {
                try self.err(path, node.start, "expected a string, found {s}", .{node.kindName()});
                return null;
            },
        };
    }

    fn expectBool(self: *Parser, node: *const Node, path: []const u8) Allocator.Error!?bool {
        return switch (node.data) {
            .boolean => |b| b,
            else => {
                try self.err(path, node.start, "expected true or false, found {s}", .{node.kindName()});
                return null;
            },
        };
    }

    /// Warns at each member whose key repeats an earlier member's key (the
    /// last value wins, as with `jsonc.Node.get`). When `shadowed` is given,
    /// `shadowed[i]` is set for every member that a later one overrides.
    /// Linear in the member count (a 4 MiB object can hold ~800k members).
    fn checkDuplicates(self: *Parser, members: []const jsonc.Member, path: []const u8, shadowed: ?[]bool) Allocator.Error!void {
        if (members.len <= small_object) {
            for (members, 0..) |*m, i| {
                var j = i;
                while (j > 0) {
                    j -= 1;
                    if (!std.mem.eql(u8, members[j].key, m.key)) continue;
                    if (shadowed) |s| s[j] = true;
                    try self.warn(try self.sub(path, m.key), m.key_start, "duplicate key \"{s}\"; the last value wins", .{m.key});
                    break;
                }
            }
            return;
        }
        var last: std.StringHashMapUnmanaged(usize) = .empty;
        defer last.deinit(self.arena);
        try last.ensureTotalCapacity(self.arena, @intCast(members.len));
        for (members, 0..) |*m, i| {
            const gop = last.getOrPutAssumeCapacity(m.key);
            if (gop.found_existing) {
                if (shadowed) |s| s[gop.value_ptr.*] = true;
                try self.warn(try self.sub(path, m.key), m.key_start, "duplicate key \"{s}\"; the last value wins", .{m.key});
            }
            gop.value_ptr.* = i;
        }
    }

    /// Warns about members not in `known`, and about repeated keys (last wins).
    fn checkKeys(self: *Parser, members: []const jsonc.Member, path: []const u8, known: []const []const u8) Allocator.Error!void {
        try self.checkDuplicates(members, path, null);
        for (members) |*m| {
            const is_known = for (known) |k| {
                if (std.mem.eql(u8, k, m.key)) break true;
            } else false;
            if (!is_known) try self.warn(try self.sub(path, m.key), m.key_start, "unknown key \"{s}\" (ignored)", .{m.key});
        }
    }

    fn root(self: *Parser, node: *const Node) Allocator.Error!?struct { version: i64, rules: []const Node } {
        const members = (try self.expectObject(node, "$")) orelse return null;
        try self.checkKeys(members, "$", &.{ "version", "rules" });
        var version: i64 = current_version;
        if (node.get("version")) |v| {
            const n = v.asInt();
            if (n == null) {
                try self.err("$.version", v.start, "version must be the integer {d}", .{current_version});
                return null;
            }
            version = n.?;
            if (version != current_version) {
                try self.err("$.version", v.start, "unsupported version {d}; this build reads version {d}", .{ version, current_version });
                return null;
            }
        } else {
            try self.err("$", node.start, "missing \"version\": {d}", .{current_version});
            return null;
        }
        const rules_node = node.get("rules") orelse return .{ .version = version, .rules = &.{} };
        return switch (rules_node.data) {
            .array => |items| .{ .version = version, .rules = items },
            .null => .{ .version = version, .rules = &.{} },
            else => {
                try self.err("$.rules", rules_node.start, "rules must be an array, found {s}", .{rules_node.kindName()});
                return null;
            },
        };
    }

    fn checkEventPattern(self: *Parser, p: Pattern, path: []const u8, offset: usize) Allocator.Error!void {
        switch (p.kind) {
            .any => {},
            .exact => {
                if (catalog.kindOf(p.stem) != null) return;
                for (catalog.entries) |e| {
                    if (!e.isFamily() and fold.eql(e.name, p.stem)) return;
                    if (e.isFamily() and fold.startsWith(p.stem, e.familyPrefix()) and p.stem.len > e.familyPrefix().len) return;
                }
                try self.warn(path, offset, "unknown event \"{s}\"; the rule fires only if such an event is emitted", .{p.text});
            },
            .prefix => {
                for (catalog.entries) |e| {
                    if (fold.startsWith(e.name, p.stem)) return;
                    if (e.isFamily() and fold.startsWith(p.stem, e.familyPrefix())) return;
                }
                try self.warn(path, offset, "no catalog event matches \"{s}\"", .{p.text});
            },
            .suffix => {
                for (catalog.entries) |e| {
                    if (e.isFamily() or fold.endsWith(e.name, p.stem)) return;
                }
                try self.warn(path, offset, "no catalog event matches \"{s}\"", .{p.text});
            },
        }
    }

    fn checkCategoryPattern(self: *Parser, p: Pattern, path: []const u8, offset: usize) Allocator.Error!void {
        inline for (std.meta.fields(catalog.Category)) |f| {
            if (p.matches(f.name)) return;
        }
        try self.warn(path, offset, "unknown category \"{s}\"", .{p.text});
    }

    fn pattern(self: *Parser, node: *const Node, path: []const u8) Allocator.Error!?Pattern {
        const s = (try self.expectString(node, path)) orelse return null;
        return Pattern.parse(s) orelse {
            try self.err(path, node.start, "invalid pattern \"{s}\": use an exact name or one * at the start or end", .{s});
            return null;
        };
    }

    fn when(self: *Parser, node: *const Node, path: []const u8) Allocator.Error!?When {
        const members = (try self.expectObject(node, path)) orelse return null;
        try self.checkKeys(members, path, &.{ "event", "category" });
        var w: When = .{};
        var ok = true;
        if (node.get("event")) |e| {
            const p = try self.sub(path, "event");
            if (try self.pattern(e, p)) |pat| {
                w.event = pat;
                try self.checkEventPattern(pat, p, e.start);
            } else ok = false;
        }
        if (node.get("category")) |c| {
            const p = try self.sub(path, "category");
            if (try self.pattern(c, p)) |pat| {
                w.category = pat;
                try self.checkCategoryPattern(pat, p, c.start);
            } else ok = false;
        }
        if (!ok) return null;
        if (w.event == null and w.category == null) {
            try self.err(path, node.start, "when needs \"event\" or \"category\"", .{});
            return null;
        }
        // An exact catalog event whose category the category pattern excludes never fires.
        if (w.event) |e| if (w.category) |c| if (e.kind == .exact) {
            if (catalog.lookup(e.stem)) |entry| {
                if (!c.matches(entry.category.name()))
                    try self.warn(path, node.start, "event \"{s}\" is in category \"{s}\", which \"{s}\" does not match; the rule never fires", .{ e.text, entry.category.name(), c.text });
            }
        };
        return w;
    }

    fn scalar(self: *Parser, node: *const Node, path: []const u8) Allocator.Error!?Scalar {
        _ = self;
        _ = path;
        return switch (node.data) {
            .null => .null,
            .boolean => |b| .{ .boolean = b },
            .number => |raw| .{ .number = .{ .raw = raw, .value = std.fmt.parseFloat(f64, raw) catch return null } },
            .string => |s| .{ .string = s },
            .array, .object => null,
        };
    }

    fn cond(self: *Parser, node: *const Node, path: []const u8, depth: u32) Allocator.Error!?Cond {
        if (try self.scalar(node, path)) |s| {
            const ops = try self.arena.alloc(Op, 1);
            ops[0] = .{ .equals = s };
            return .{ .ops = ops };
        }
        const members = switch (node.data) {
            .object => |m| m,
            else => {
                try self.err(path, node.start, "expected a string, number, boolean, null or predicate object, found {s}", .{node.kindName()});
                return null;
            },
        };
        if (members.len == 0) {
            try self.err(path, node.start, "empty predicate; use equals, contains, prefix, suffix, in or not", .{});
            return null;
        }
        if (depth >= 8) {
            try self.err(path, node.start, "predicate nested too deeply", .{});
            return null;
        }
        // A repeated operator keeps its last value, as keys do everywhere else.
        const shadowed = try self.arena.alloc(bool, members.len);
        @memset(shadowed, false);
        try self.checkDuplicates(members, path, shadowed);
        var ops: std.ArrayList(Op) = .empty;
        var ok = true;
        for (members, shadowed) |*m, skip| {
            if (skip) continue;
            const p = try self.sub(path, m.key);
            const v = &m.value;
            if (std.mem.eql(u8, m.key, "equals")) {
                if (try self.scalar(v, p)) |s| try ops.append(self.arena, .{ .equals = s }) else {
                    try self.err(p, v.start, "equals needs a string, number, boolean or null", .{});
                    ok = false;
                }
            } else if (std.mem.eql(u8, m.key, "contains") or std.mem.eql(u8, m.key, "prefix") or std.mem.eql(u8, m.key, "suffix")) {
                const s = (try self.expectString(v, p)) orelse {
                    ok = false;
                    continue;
                };
                const op: Op = if (m.key[0] == 'c') .{ .contains = s } else if (m.key[0] == 'p') .{ .prefix = s } else .{ .suffix = s };
                try ops.append(self.arena, op);
            } else if (std.mem.eql(u8, m.key, "in")) {
                const items = switch (v.data) {
                    .array => |a| a,
                    else => {
                        try self.err(p, v.start, "in needs an array of strings, numbers, booleans or null", .{});
                        ok = false;
                        continue;
                    },
                };
                if (items.len == 0) try self.warn(p, v.start, "empty in list never matches", .{});
                const list = try self.arena.alloc(Scalar, items.len);
                for (items, 0..) |*item, i| {
                    if (try self.scalar(item, p)) |s| list[i] = s else {
                        try self.err(try self.idx(p, i), item.start, "in needs an array of strings, numbers, booleans or null", .{});
                        ok = false;
                    }
                }
                try ops.append(self.arena, .{ .in = list });
            } else if (std.mem.eql(u8, m.key, "not")) {
                if (try self.cond(v, p, depth + 1)) |inner| {
                    const ptr = try self.arena.create(Cond);
                    ptr.* = inner;
                    try ops.append(self.arena, .{ .not = ptr });
                } else ok = false;
            } else {
                try self.err(p, m.key_start, "unknown predicate operator \"{s}\"; use equals, contains, prefix, suffix, in or not", .{m.key});
                ok = false;
            }
        }
        if (!ok) return null;
        return .{ .ops = try ops.toOwnedSlice(self.arena) };
    }

    fn where(self: *Parser, node: *const Node, path: []const u8) Allocator.Error!?[]const Predicate {
        const members = switch (node.data) {
            .null => return &.{},
            .object => |m| m,
            else => {
                try self.err(path, node.start, "expected an object, found {s}", .{node.kindName()});
                return null;
            },
        };
        // A repeated key keeps its last value, as everywhere else in the file
        // (and as a JSON object decoder would), instead of adding a second
        // predicate that must also hold.
        const shadowed = try self.arena.alloc(bool, members.len);
        @memset(shadowed, false);
        try self.checkDuplicates(members, path, shadowed);
        var preds: std.ArrayList(Predicate) = .empty;
        var ok = true;
        for (members, shadowed) |*m, skip| {
            if (skip) continue;
            const p = try self.sub(path, m.key);
            if (std.mem.trim(u8, m.key, " \t").len == 0) {
                try self.err(p, m.key_start, "empty where key", .{});
                ok = false;
                continue;
            }
            const c = (try self.cond(&m.value, p, 0)) orelse {
                ok = false;
                continue;
            };
            try preds.append(self.arena, .{ .key = m.key, .alias = Alias.parse(m.key), .cond = c });
        }
        if (!ok) return null;
        return try preds.toOwnedSlice(self.arena);
    }

    fn rateLimit(self: *Parser, node: *const Node, path: []const u8) Allocator.Error!?ratelimit.Limit {
        if (node.data == .null) return ratelimit.default;
        const members = (try self.expectObject(node, path)) orelse return null;
        try self.checkKeys(members, path, &.{ "interval_seconds", "maximum" });
        var limit: ratelimit.Limit = ratelimit.default;
        var ok = true;
        if (node.get("interval_seconds")) |v| {
            const p = try self.sub(path, "interval_seconds");
            const max_s = ratelimit.max_interval_ms / 1000;
            const f = v.asFloat();
            if (f == null or !std.math.isFinite(f.?) or f.? <= 0 or f.? > @as(f64, @floatFromInt(max_s))) {
                try self.err(p, v.start, "interval_seconds must be a number above 0 and at most {d}", .{max_s});
                ok = false;
            } else {
                limit.interval_ms = @max(ratelimit.min_interval_ms, @as(u64, @intFromFloat(@round(f.? * 1000))));
            }
        }
        if (node.get("maximum")) |v| {
            const p = try self.sub(path, "maximum");
            const n = v.asInt();
            if (n == null or n.? < 1 or n.? > ratelimit.max_maximum) {
                try self.err(p, v.start, "maximum must be an integer from 1 to {d}", .{ratelimit.max_maximum});
                ok = false;
            } else {
                limit.maximum = @intCast(n.?);
            }
        }
        return if (ok) limit else null;
    }

    fn optString(self: *Parser, obj: *const Node, key: []const u8, path: []const u8, ok: *bool) Allocator.Error!?[]const u8 {
        const v = obj.get(key) orelse return null;
        if (v.data == .null) return null;
        return (try self.expectString(v, try self.sub(path, key))) orelse {
            ok.* = false;
            return null;
        };
    }

    fn checkTemplate(self: *Parser, obj: *const Node, key: []const u8, path: []const u8) Allocator.Error!void {
        const v = obj.get(key) orelse return;
        const s = v.asString() orelse return;
        if (template.check(s)) |problem| try self.warn(try self.sub(path, key), v.start, "{s}", .{problem.message});
    }

    fn action(self: *Parser, node: *const Node, path: []const u8) Allocator.Error!?Action {
        _ = (try self.expectObject(node, path)) orelse return null;
        const members = node.data.object;
        const type_node = node.get("action") orelse {
            try self.err(path, node.start, "missing \"action\" (notify, rpc, run or webhook)", .{});
            return null;
        };
        const type_name = (try self.expectString(type_node, try self.sub(path, "action"))) orelse return null;
        var ok = true;
        if (std.mem.eql(u8, type_name, "notify")) {
            try self.checkKeys(members, path, &.{ "action", "title", "subtitle", "body", "message", "workspace_id", "surface_id" });
            const n: Notify = .{
                .title = try self.optString(node, "title", path, &ok),
                .subtitle = try self.optString(node, "subtitle", path, &ok),
                .body = try self.optString(node, "body", path, &ok),
                .message = try self.optString(node, "message", path, &ok),
                .workspace_id = try self.optString(node, "workspace_id", path, &ok),
                .surface_id = try self.optString(node, "surface_id", path, &ok),
            };
            if (!ok) return null;
            for ([_][]const u8{ "title", "subtitle", "body", "message" }) |k| try self.checkTemplate(node, k, path);
            if (n.title == null and n.body == null and n.message == null and n.subtitle == null)
                try self.warn(path, node.start, "notify has no title, subtitle, body or message", .{});
            return .{ .notify = n };
        }
        if (std.mem.eql(u8, type_name, "rpc")) {
            try self.checkKeys(members, path, &.{ "action", "method", "params", "allow_focus", "focus" });
            const m = node.get("method") orelse {
                try self.err(path, node.start, "rpc needs \"method\"", .{});
                return null;
            };
            const method = (try self.expectString(m, try self.sub(path, "method"))) orelse return null;
            if (std.mem.trim(u8, method, " \t").len == 0) {
                try self.err(try self.sub(path, "method"), m.start, "rpc method must not be empty", .{});
                return null;
            }
            var r: Rpc = .{ .method = method };
            if (node.get("params")) |pn| switch (pn.data) {
                .object => r.params = pn,
                .null => {},
                else => {
                    try self.err(try self.sub(path, "params"), pn.start, "params must be an object, found {s}", .{pn.kindName()});
                    ok = false;
                },
            };
            for ([_][]const u8{ "allow_focus", "focus" }) |k| {
                if (node.get(k)) |b| {
                    if (try self.expectBool(b, try self.sub(path, k))) |v| {
                        r.allow_focus = r.allow_focus or v;
                    } else ok = false;
                }
            }
            return if (ok) .{ .rpc = r } else null;
        }
        if (std.mem.eql(u8, type_name, "run")) {
            try self.checkKeys(members, path, &.{ "action", "command", "cmd", "timeout_seconds" });
            const cmd_key: []const u8 = if (node.get("command") != null) "command" else "cmd";
            const cn = node.get(cmd_key) orelse {
                try self.err(path, node.start, "run needs \"command\" (or \"cmd\")", .{});
                return null;
            };
            const command = (try self.expectString(cn, try self.sub(path, cmd_key))) orelse return null;
            if (std.mem.trim(u8, command, " \t\r\n").len == 0) {
                try self.err(try self.sub(path, cmd_key), cn.start, "run command must not be empty", .{});
                return null;
            }
            if (node.get("command") != null and node.get("cmd") != null)
                try self.warn(try self.sub(path, "cmd"), node.get("cmd").?.start, "both command and cmd are set; cmd is ignored", .{});
            var r: Run = .{ .command = command };
            if (node.get("timeout_seconds")) |t| if (t.data != .null) {
                const max_s = max_run_timeout_ms / 1000;
                const f = t.asFloat();
                if (f == null or !std.math.isFinite(f.?) or f.? <= 0 or f.? > @as(f64, @floatFromInt(max_s))) {
                    try self.err(try self.sub(path, "timeout_seconds"), t.start, "timeout_seconds must be a number above 0 and at most {d}", .{max_s});
                    return null;
                }
                r.timeout_ms = @max(1, @as(u64, @intFromFloat(@round(f.? * 1000))));
            };
            return .{ .run = r };
        }
        if (std.mem.eql(u8, type_name, "webhook")) {
            try self.checkKeys(members, path, &.{ "action", "url", "headers" });
            const un = node.get("url") orelse {
                try self.err(path, node.start, "webhook needs \"url\"", .{});
                return null;
            };
            const url = (try self.expectString(un, try self.sub(path, "url"))) orelse return null;
            var headers: std.ArrayList(webhook.Header) = .empty;
            if (node.get("headers")) |hn| switch (hn.data) {
                .null => {},
                .object => |hm| {
                    // A repeated header key keeps its last value (sent once).
                    const shadowed = try self.arena.alloc(bool, hm.len);
                    @memset(shadowed, false);
                    try self.checkDuplicates(hm, try self.sub(path, "headers"), shadowed);
                    for (hm, shadowed) |*h, skip| {
                        if (skip) continue;
                        const hp = try self.sub(try self.sub(path, "headers"), h.key);
                        const value = (try self.expectString(&h.value, hp)) orelse {
                            ok = false;
                            continue;
                        };
                        try headers.append(self.arena, .{ .name = h.key, .value = value });
                    }
                },
                else => {
                    try self.err(try self.sub(path, "headers"), hn.start, "headers must be an object of strings, found {s}", .{hn.kindName()});
                    ok = false;
                },
            };
            if (!ok) return null;
            if (webhook.validate(url, headers.items)) |problem| {
                try self.err(try self.sub(path, "url"), un.start, "{s}", .{problem});
                return null;
            }
            return .{ .webhook = .{ .url = url, .headers = try headers.toOwnedSlice(self.arena) } };
        }
        try self.err(try self.sub(path, "action"), type_node.start, "unknown action \"{s}\"; use notify, rpc, run or webhook", .{type_name});
        return null;
    }

    fn then(self: *Parser, node: *const Node, path: []const u8) Allocator.Error!?[]const Action {
        const items = switch (node.data) {
            .array => |a| a,
            else => {
                try self.err(path, node.start, "then must be an array of actions, found {s}", .{node.kindName()});
                return null;
            },
        };
        if (items.len == 0) try self.warn(path, node.start, "then is empty; the rule does nothing", .{});
        var out: std.ArrayList(Action) = .empty;
        var ok = true;
        for (items, 0..) |*item, i| {
            if (try self.action(item, try self.idx(path, i))) |a| try out.append(self.arena, a) else ok = false;
        }
        if (!ok) return null;
        return try out.toOwnedSlice(self.arena);
    }

    fn validId(id: []const u8) bool {
        if (id.len == 0 or id.len > max_id_len) return false;
        if (std.mem.trim(u8, id, " \t").len != id.len) return false;
        for (id) |c| if (c < 0x20 or c == 0x7F) return false;
        return std.unicode.utf8ValidateSlice(id);
    }

    /// Parses one rule; null when it has errors. `id_out` receives a usable id even then.
    fn rule(self: *Parser, node: *const Node, path: []const u8, index: usize, id_out: *?[]const u8) Allocator.Error!?Rule {
        self.rule_errors = 0;
        const members = (try self.expectObject(node, path)) orelse return null;
        try self.checkKeys(members, path, &.{ "id", "enabled", "when", "where", "rate_limit", "then" });

        var id: []const u8 = "";
        if (node.get("id")) |n| {
            const p = try self.sub(path, "id");
            if (try self.expectString(n, p)) |s| {
                if (validId(s)) {
                    id = s;
                    id_out.* = s;
                } else try self.err(p, n.start, "id must be 1 to {d} bytes of UTF-8 without control characters or surrounding spaces", .{max_id_len});
            }
        } else try self.err(path, node.start, "rule needs an \"id\"", .{});

        var enabled = true;
        if (node.get("enabled")) |n| {
            if (n.data != .null) enabled = (try self.expectBool(n, try self.sub(path, "enabled"))) orelse true;
        }

        var w: ?When = null;
        if (node.get("when")) |n| {
            w = try self.when(n, try self.sub(path, "when"));
        } else try self.err(path, node.start, "rule needs \"when\"", .{});

        var preds: []const Predicate = &.{};
        if (node.get("where")) |n| preds = (try self.where(n, try self.sub(path, "where"))) orelse &.{};

        var limit = ratelimit.default;
        if (node.get("rate_limit")) |n| limit = (try self.rateLimit(n, try self.sub(path, "rate_limit"))) orelse ratelimit.default;

        var actions: []const Action = &.{};
        if (node.get("then")) |n| {
            actions = (try self.then(n, try self.sub(path, "then"))) orelse &.{};
        } else try self.err(path, node.start, "rule needs \"then\"", .{});

        if (self.rule_errors > 0) return null;
        return .{
            .id = id,
            .enabled = enabled,
            .when = w.?,
            .where = preds,
            .rate_limit = limit,
            .then = actions,
            .index = index,
            .node = node,
            .pos = self.pos(node.start),
        };
    }
};

fn fileError(arena_state: *std.heap.ArenaAllocator, src: []const u8, offset: usize, message: []const u8) Allocator.Error!Config {
    const arena = arena_state.allocator();
    const issues = try arena.alloc(Issue, 1);
    issues[0] = .{ .severity = .err, .path = "$", .message = message, .offset = offset, .pos = jsonc.position(src, offset) };
    return .{ .arena = arena_state.*, .src = src, .issues = issues };
}

/// Parses and validates a rules file. Only allocation failures are errors;
/// everything else is reported in `Config.issues`.
pub fn parse(gpa: Allocator, src_in: []const u8) Allocator.Error!Config {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    if (src_in.len > max_bytes) return fileError(&arena_state, "", 0, "automations file exceeds 4 MiB");
    const src = try arena.dupe(u8, src_in);
    if (std.mem.trim(u8, src, " \t\r\n").len == 0 or std.mem.eql(u8, std.mem.trim(u8, src, " \t\r\n"), jsonc.utf8_bom)) {
        // An empty file is an empty rule set.
        return .{ .arena = arena_state, .src = src };
    }
    if (!std.unicode.utf8ValidateSlice(src)) return fileError(&arena_state, src, 0, "automations file is not valid UTF-8");

    var diag: jsonc.Diagnostic = .{};
    const root_node = try arena.create(Node);
    root_node.* = jsonc.parseInto(arena, src, .{ .max_depth = max_depth }, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return fileError(&arena_state, src, diag.offset, diag.message),
    };

    var p: Parser = .{ .arena = arena, .src = src };
    const top = (try p.root(root_node)) orelse {
        const issues = try p.finishIssues();
        return .{ .arena = arena_state, .src = src, .issues = issues };
    };

    var rules: std.ArrayList(Rule) = .empty;
    var invalid: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (top.rules, 0..) |*rn, i| {
        const path = try p.idx("$.rules", i);
        var id: ?[]const u8 = null;
        const r = try p.rule(rn, path, i, &id);
        if (id) |s| {
            const gop = try seen.getOrPut(arena, s);
            if (gop.found_existing) {
                const id_node = rn.get("id").?;
                try p.err(try p.sub(path, "id"), id_node.start, "duplicate rule id \"{s}\"", .{s});
                try invalid.append(arena, s);
                continue;
            }
        }
        if (r) |ok_rule| try rules.append(arena, ok_rule) else if (id) |s| try invalid.append(arena, s);
    }
    const rules_out = try rules.toOwnedSlice(arena);
    const invalid_out = try invalid.toOwnedSlice(arena);
    const issues = try p.finishIssues();
    // Copy the arena state into the result only after its last allocation:
    // a copy taken earlier would miss buffers the arena adds afterwards.
    return .{
        .arena = arena_state,
        .src = src,
        .version = top.version,
        .rules = rules_out,
        .issues = issues,
        .invalid_ids = invalid_out,
    };
}

// ---------------------------------------------------------------------------
// enable / disable (lossless edit of the file)

pub const EditError = error{ OutOfMemory, SyntaxError, RuleNotFound, NotARulesFile };

/// Sets `enabled` of rule `id` in `src`, splicing only that value (comments
/// and formatting survive). Enabling a rule without `enabled` changes
/// nothing (the default is true). Works on rules that have other errors.
/// The returned text is owned by `gpa`.
pub fn setEnabled(gpa: Allocator, src: []const u8, id: []const u8, enabled: bool) EditError!json_edit.Result {
    var doc = try jsonc.parse(gpa, src, .{ .max_depth = max_depth }, null);
    defer doc.deinit();
    const rules_node = doc.root.get("rules") orelse return error.RuleNotFound;
    const items = switch (rules_node.data) {
        .array => |a| a,
        else => return error.NotARulesFile,
    };
    // The last rule with this id, matching the duplicate rule (which loads the first).
    const target: *const Node = for (items) |*rn| {
        const s = (rn.get("id") orelse continue).asString() orelse continue;
        if (std.mem.eql(u8, s, id)) break rn;
    } else return error.RuleNotFound;

    if (target.get("enabled")) |cur| {
        if (cur.asBool()) |b| if (b == enabled) return .{ .text = try gpa.dupe(u8, src), .changed = false };
    } else if (enabled) return .{ .text = try gpa.dupe(u8, src), .changed = false };

    const sub_src = src[target.start..target.end];
    const edited = json_edit.setPath(gpa, sub_src, &.{"enabled"}, if (enabled) "true" else "false", null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SyntaxError,
    };
    defer gpa.free(edited.text);
    const out = try std.mem.concat(gpa, u8, &.{ src[0..target.start], edited.text, src[target.end..] });
    return .{ .text = out, .changed = true };
}

// ---------------------------------------------------------------------------
// list output

/// Writes the `automation list` entry of a rule:
/// `{"id","enabled","when":{"event","category"},"where_count","rate_limit":{"interval_seconds","maximum"},"actions":[types]}`.
pub fn writeSummary(r: *const Rule, jw: *std.json.Stringify) std.Io.Writer.Error!void {
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(r.id);
    try jw.objectField("enabled");
    try jw.write(r.enabled);
    try jw.objectField("when");
    try jw.beginObject();
    if (r.when.event) |e| {
        try jw.objectField("event");
        try jw.write(e.text);
    }
    if (r.when.category) |c| {
        try jw.objectField("category");
        try jw.write(c.text);
    }
    try jw.endObject();
    try jw.objectField("where_count");
    try jw.write(r.where.len);
    try jw.objectField("rate_limit");
    try jw.beginObject();
    try jw.objectField("interval_seconds");
    if (r.rate_limit.interval_ms % 1000 == 0) {
        try jw.write(r.rate_limit.interval_ms / 1000);
    } else {
        try jw.write(@as(f64, @floatFromInt(r.rate_limit.interval_ms)) / 1000.0);
    }
    try jw.objectField("maximum");
    try jw.write(r.rate_limit.maximum);
    try jw.endObject();
    try jw.objectField("actions");
    try jw.beginArray();
    for (r.then) |a| try jw.write(a.typeName());
    try jw.endArray();
    try jw.endObject();
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// A rule that uses every field (an original fixture; clean room G1).
const example =
    \\{
    \\  "version": 1,
    \\  "rules": [
    \\    {
    \\      "id": "triage-waiting",
    \\      "enabled": true,
    \\      "when": { "event": "agent.needs_input", "category": "agent" },
    \\      "where": {
    \\        "workspace.tag": "triage",
    \\        "surface.kind": { "in": ["terminal", "browser"] }
    \\      },
    \\      "rate_limit": { "interval_seconds": 45, "maximum": 2 },
    \\      "then": [
    \\        { "action": "notify", "title": "Waiting on you", "body": "Session {{payload.session_id}} paused" },
    \\        { "action": "rpc", "method": "workspace.rename", "params": { "title": "needs you" } },
    \\        { "action": "run", "command": "echo %CMUX_AUTOMATION_RULE_ID%", "timeout_seconds": 10 },
    \\        { "action": "webhook", "url": "https://hooks.example/triage", "headers": { "X-Source": "wmux" } }
    \\      ]
    \\    }
    \\  ]
    \\}
;

fn expectIssue(cfg: *const Config, sev: Severity, path: []const u8, needle: []const u8) !void {
    for (cfg.issues) |i| {
        if (i.severity == sev and std.mem.eql(u8, i.path, path) and std.mem.indexOf(u8, i.message, needle) != null) return;
    }
    std.log.err("missing {s} at {s} containing \"{s}\"; issues:", .{ sev.label(), path, needle });
    for (cfg.issues) |i| std.log.err("  {f}", .{i});
    return error.TestExpectedIssue;
}

test "unit: automation: rules parse a rule that uses every field" {
    var cfg = try parse(testing.allocator, example);
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 0), cfg.issues.len);
    try testing.expectEqual(@as(usize, 1), cfg.rules.len);
    const r = cfg.find("triage-waiting").?;
    try testing.expect(r.enabled);
    try testing.expectEqual(Pattern.Kind.exact, r.when.event.?.kind);
    try testing.expectEqualStrings("agent", r.when.category.?.stem);
    try testing.expectEqual(@as(usize, 2), r.where.len);
    try testing.expectEqual(Alias.workspace_tag, r.where[0].alias.?);
    try testing.expectEqual(Alias.surface_kind, r.where[1].alias.?);
    try testing.expectEqualStrings("triage", r.where[0].cond.ops[0].equals.string);
    try testing.expectEqualStrings("browser", r.where[1].cond.ops[0].in[1].string);
    try testing.expectEqual(@as(u64, 45_000), r.rate_limit.interval_ms);
    try testing.expectEqual(@as(u32, 2), r.rate_limit.maximum);
    try testing.expectEqual(@as(usize, 4), r.then.len);
    try testing.expectEqualStrings("Session {{payload.session_id}} paused", r.then[0].notify.body.?);
    try testing.expectEqualStrings("workspace.rename", r.then[1].rpc.method);
    try testing.expect(!r.then[1].rpc.allow_focus);
    try testing.expectEqualStrings("needs you", r.then[1].rpc.params.?.get("title").?.data.string);
    try testing.expectEqualStrings("echo %CMUX_AUTOMATION_RULE_ID%", r.then[2].run.command);
    try testing.expectEqual(@as(u64, 10_000), r.then[2].run.timeout_ms);
    try testing.expectEqualStrings("https://hooks.example/triage", r.then[3].webhook.url);
    try testing.expectEqualStrings("X-Source", r.then[3].webhook.headers[0].name);
    try testing.expectEqual(@as(u32, 4), r.pos.line);
    try testing.expect(cfg.find("other") == null);
}

test "unit: automation: rules apply defaults for enabled, rate limit and run timeout" {
    var cfg = try parse(testing.allocator,
        \\{"version":1,"rules":[
        \\ {"id":"a","when":{"category":"workspace"},"then":[{"action":"run","cmd":"echo hi"}]},
        \\ {"id":"b","enabled":false,"when":{"event":"workspace.*"},"rate_limit":{"maximum":5},
        \\  "then":[{"action":"run","command":"x","timeout_seconds":300}]},
        \\ {"id":"c","when":{"event":"*"},"rate_limit":{"interval_seconds":0.25},"then":[{"action":"rpc","method":"workspace.select","focus":true}]}
        \\]}
    );
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 0), cfg.errorCount());
    const a = cfg.find("a").?;
    try testing.expect(a.enabled);
    try testing.expect(a.rate_limit.eql(ratelimit.default));
    try testing.expectEqualStrings("echo hi", a.then[0].run.command);
    try testing.expectEqual(default_run_timeout_ms, a.then[0].run.timeout_ms);
    const b = cfg.find("b").?;
    try testing.expect(!b.enabled);
    try testing.expectEqual(Pattern.Kind.prefix, b.when.event.?.kind);
    try testing.expectEqual(@as(u32, 5), b.rate_limit.maximum);
    try testing.expectEqual(@as(u64, 1000), b.rate_limit.interval_ms);
    try testing.expectEqual(@as(u64, 300_000), b.then[0].run.timeout_ms);
    const c = cfg.find("c").?;
    try testing.expectEqual(Pattern.Kind.any, c.when.event.?.kind);
    try testing.expectEqual(@as(u64, 250), c.rate_limit.interval_ms);
    try testing.expect(c.then[0].rpc.allow_focus);
}

test "unit: automation: rules report file-level errors with positions" {
    const gpa = testing.allocator;
    {
        var cfg = try parse(gpa, "{\"version\":1,\n  \"rules\": [ }");
        defer cfg.deinit();
        try testing.expectEqual(@as(usize, 1), cfg.issues.len);
        try testing.expectEqual(@as(u32, 2), cfg.issues[0].pos.line);
        try testing.expectEqual(@as(usize, 0), cfg.rules.len);
    }
    {
        var cfg = try parse(gpa, "[1,2]");
        defer cfg.deinit();
        try expectIssue(&cfg, .err, "$", "expected an object");
    }
    {
        var cfg = try parse(gpa, "{\"rules\":[]}");
        defer cfg.deinit();
        try expectIssue(&cfg, .err, "$", "missing \"version\"");
    }
    {
        var cfg = try parse(gpa, "{\"version\":2,\"rules\":[]}");
        defer cfg.deinit();
        try expectIssue(&cfg, .err, "$.version", "unsupported version 2");
    }
    {
        var cfg = try parse(gpa, "{\"version\":\"1\"}");
        defer cfg.deinit();
        try expectIssue(&cfg, .err, "$.version", "integer");
    }
    {
        var cfg = try parse(gpa, "{\"version\":1,\"rules\":{}}");
        defer cfg.deinit();
        try expectIssue(&cfg, .err, "$.rules", "must be an array");
    }
    {
        var cfg = try parse(gpa, "{\"version\":1,\"rules\":[\"\xff\"]}");
        defer cfg.deinit();
        try expectIssue(&cfg, .err, "$", "UTF-8");
    }
    // Empty, whitespace-only and BOM-only files are an empty rule set.
    for ([_][]const u8{ "", "  \n", jsonc.utf8_bom }) |text| {
        var cfg = try parse(gpa, text);
        defer cfg.deinit();
        try testing.expectEqual(@as(usize, 0), cfg.issues.len);
        try testing.expectEqual(@as(usize, 0), cfg.rules.len);
    }
    // No rules key / null rules: fine.
    {
        var cfg = try parse(gpa, "// rules\n{\"version\":1,\"rules\":null,}");
        defer cfg.deinit();
        try testing.expectEqual(@as(usize, 0), cfg.errorCount());
    }
}

test "unit: automation: rules enforce size and nesting guards" {
    const gpa = testing.allocator;
    const huge = try gpa.alloc(u8, max_bytes + 1);
    defer gpa.free(huge);
    @memset(huge, ' ');
    var cfg = try parse(gpa, huge);
    defer cfg.deinit();
    try expectIssue(&cfg, .err, "$", "4 MiB");

    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(gpa);
    try deep.appendSlice(gpa, "{\"version\":1,\"rules\":[{\"id\":\"x\",\"when\":{\"event\":\"*\"},\"then\":[{\"action\":\"rpc\",\"method\":\"m\",\"params\":{\"a\":");
    for (0..max_depth) |_| try deep.append(gpa, '[');
    for (0..max_depth) |_| try deep.append(gpa, ']');
    try deep.appendSlice(gpa, "}}]}]}");
    var cfg2 = try parse(gpa, deep.items);
    defer cfg2.deinit();
    try testing.expectEqual(@as(usize, 1), cfg2.issues.len);
    try testing.expectEqual(@as(usize, 0), cfg2.rules.len);
}

test "unit: automation: rules parse huge files in linear time" {
    const gpa = testing.allocator;
    // One rule object with 50k unknown keys and a repeated one: duplicate
    // detection used to compare every key with every earlier key.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try buf.appendSlice(gpa, "{\"version\":1,\"rules\":[{\"id\":\"x\",\"when\":{\"event\":\"*\"},\"then\":[]");
        const n = 50_000;
        for (0..n) |i| try buf.print(gpa, ",\"k{d}\":0", .{i});
        try buf.appendSlice(gpa, ",\"k7\":1}]}");
        var cfg = try parse(gpa, buf.items);
        defer cfg.deinit();
        try testing.expectEqual(@as(usize, 1), cfg.rules.len);
        // n + 1 unknown keys, one duplicate key, one empty `then`.
        try testing.expectEqual(@as(usize, n + 3), cfg.issues.len);
        try expectIssue(&cfg, .warning, "$.rules[0].k7", "duplicate key");
    }
    // 5k rules whose warnings are produced out of document order (`then`
    // before `when`): each one used to rescan the file from the top for its
    // line:col.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try buf.appendSlice(gpa, "{\"version\":1,\"rules\":[\n");
        const n = 5_000;
        for (0..n) |i| {
            if (i > 0) try buf.appendSlice(gpa, ",\n");
            try buf.print(gpa, "{{\"then\":[{{\"action\":\"notify\"}}],\"id\":\"r{d}\",\"when\":{{\"event\":\"no.such{d}\"}}}}", .{ i, i });
        }
        try buf.appendSlice(gpa, "\n]}");
        var cfg = try parse(gpa, buf.items);
        defer cfg.deinit();
        try testing.expectEqual(@as(usize, n), cfg.rules.len);
        try testing.expectEqual(@as(usize, 2 * n), cfg.issues.len);
        // Document order, and positions agree with jsonc.position (sampled).
        var i: usize = 0;
        while (i < cfg.issues.len) : (i += 997) {
            const issue = cfg.issues[i];
            try testing.expectEqual(jsonc.position(cfg.src, issue.offset), issue.pos);
            if (i > 0) try testing.expect(cfg.issues[i - 1].offset <= issue.offset);
        }
        try testing.expectEqual(@as(u32, n + 1), cfg.issues[cfg.issues.len - 1].pos.line);
        try testing.expectEqual(@as(u32, n + 1), cfg.rules[n - 1].pos.line);
    }
}

test "unit: automation: rules drop only the rule with errors" {
    var cfg = try parse(testing.allocator,
        \\{"version":1,"rules":[
        \\ {"id":"good","when":{"event":"workspace.created"},"then":[{"action":"notify","title":"new"}]},
        \\ {"id":"bad","when":{"event":"workspace.created"},"rate_limit":{"interval_seconds":-1,"maximum":0},"then":[]},
        \\ {"id":"good","when":{"event":"workspace.created"},"then":[]},
        \\ {"when":{"event":"workspace.created"},"then":[]},
        \\ 7
        \\]}
    );
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 1), cfg.rules.len);
    try testing.expectEqualStrings("good", cfg.rules[0].id);
    try expectIssue(&cfg, .err, "$.rules[1].rate_limit.interval_seconds", "above 0");
    try expectIssue(&cfg, .err, "$.rules[1].rate_limit.maximum", "from 1 to");
    try expectIssue(&cfg, .err, "$.rules[2].id", "duplicate rule id \"good\"");
    try expectIssue(&cfg, .err, "$.rules[3]", "needs an \"id\"");
    try expectIssue(&cfg, .err, "$.rules[4]", "expected an object");
    try expectIssue(&cfg, .warning, "$.rules[1].then", "empty");
    try testing.expectEqual(@as(usize, 2), cfg.invalid_ids.len);
    // Issues are in document order and carry line numbers.
    var last: usize = 0;
    for (cfg.issues) |i| {
        try testing.expect(i.offset >= last);
        last = i.offset;
    }
    try testing.expectEqual(@as(u32, 3), cfg.issues[0].pos.line);
}

test "unit: automation: rules validate when patterns against the event catalog" {
    var cfg = try parse(testing.allocator,
        \\{"version":1,"rules":[
        \\ {"id":"a","when":{"event":"agent.hook.Stop"},"then":[]},
        \\ {"id":"b","when":{"event":"no.such.event"},"then":[]},
        \\ {"id":"c","when":{"event":"*.created","category":"work*"},"then":[]},
        \\ {"id":"d","when":{"event":"a*b"},"then":[]},
        \\ {"id":"e","when":{"event":"*x*"},"then":[]},
        \\ {"id":"f","when":{},"then":[]},
        \\ {"id":"g","when":{"category":"nope"},"then":[]},
        \\ {"id":"h","when":{"event":"workspace.created","category":"agent"},"then":[]},
        \\ {"id":"i","when":{"event":""},"then":[]},
        \\ {"id":"j","when":{"event":"zzz*"},"then":[]},
        \\ {"id":"k","when":{"event":"WORKSPACE.CREATED"},"then":[]},
        \\ {"id":"l","when":{"event":"agent.hook.*"},"then":[]},
        \\ {"id":"m","when":{"event":7},"then":[]},
        \\ {"id":"n","when":"workspace.created","then":[]}
        \\]}
    );
    defer cfg.deinit();
    for ([_][]const u8{ "a", "b", "c", "g", "h", "j", "k", "l" }) |id| try testing.expect(cfg.find(id) != null);
    for ([_][]const u8{ "d", "e", "f", "i", "m", "n" }) |id| try testing.expect(cfg.find(id) == null);
    try expectIssue(&cfg, .warning, "$.rules[1].when.event", "unknown event");
    try expectIssue(&cfg, .err, "$.rules[3].when.event", "invalid pattern");
    try expectIssue(&cfg, .err, "$.rules[4].when.event", "invalid pattern");
    try expectIssue(&cfg, .err, "$.rules[5].when", "needs \"event\" or \"category\"");
    try expectIssue(&cfg, .warning, "$.rules[6].when.category", "unknown category");
    try expectIssue(&cfg, .warning, "$.rules[7].when", "never fires");
    try expectIssue(&cfg, .err, "$.rules[8].when.event", "invalid pattern");
    try expectIssue(&cfg, .warning, "$.rules[9].when.event", "no catalog event");
    try expectIssue(&cfg, .err, "$.rules[12].when.event", "expected a string");
    try expectIssue(&cfg, .err, "$.rules[13].when", "expected an object");
    for (cfg.issues) |i| {
        // Known names (any case, families) do not warn.
        try testing.expect(!std.mem.startsWith(u8, i.path, "$.rules[0].when"));
        try testing.expect(!std.mem.startsWith(u8, i.path, "$.rules[2].when"));
        try testing.expect(!std.mem.startsWith(u8, i.path, "$.rules[10].when"));
        try testing.expect(!std.mem.startsWith(u8, i.path, "$.rules[11].when"));
    }
}

test "unit: automation: rules parse where predicates" {
    var cfg = try parse(testing.allocator,
        \\{"version":1,"rules":[
        \\ {"id":"a","when":{"event":"*"},"then":[],"where":{
        \\   "workspace.title":{"contains":"API","not":{"suffix":"old"}},
        \\   "agent":{"in":["claude","codex",null,3,true]},
        \\   "payload.count":42,
        \\   "flag":false,
        \\   "x":null,
        \\   "title":{"prefix":"Ünï"}
        \\ }},
        \\ {"id":"b","when":{"event":"*"},"then":[],"where":{"k":{"bogus":1}}},
        \\ {"id":"c","when":{"event":"*"},"then":[],"where":{"k":{}}},
        \\ {"id":"d","when":{"event":"*"},"then":[],"where":{"k":[1]}},
        \\ {"id":"e","when":{"event":"*"},"then":[],"where":{"k":{"contains":1}}},
        \\ {"id":"f","when":{"event":"*"},"then":[],"where":{"k":{"in":[[1]]}}},
        \\ {"id":"g","when":{"event":"*"},"then":[],"where":{"":"x"}},
        \\ {"id":"h","when":{"event":"*"},"then":[],"where":{"k":{"in":[]}}},
        \\ {"id":"i","when":{"event":"*"},"then":[],"where":{"k":{"not":{"not":{"not":{"not":{"not":{"not":{"not":{"not":{"not":"x"}}}}}}}}}}},
        \\ {"id":"j","when":{"event":"*"},"then":[],"where":null}
        \\]}
    );
    defer cfg.deinit();
    const a = cfg.find("a").?;
    try testing.expectEqual(@as(usize, 6), a.where.len);
    try testing.expectEqual(Alias.workspace_title, a.where[0].alias.?);
    try testing.expectEqual(@as(usize, 2), a.where[0].cond.ops.len);
    try testing.expectEqualStrings("API", a.where[0].cond.ops[0].contains);
    try testing.expectEqualStrings("old", a.where[0].cond.ops[1].not.ops[0].suffix);
    try testing.expectEqual(@as(usize, 5), a.where[1].cond.ops[0].in.len);
    try testing.expectEqual(@as(f64, 42), a.where[2].cond.ops[0].equals.number.value);
    try testing.expect(a.where[2].alias == null);
    try testing.expect(!a.where[3].cond.ops[0].equals.boolean);
    try testing.expect(a.where[4].cond.ops[0].equals == .null);
    try testing.expect(cfg.find("h") != null);
    try testing.expect(cfg.find("j") != null);
    for ([_][]const u8{ "b", "c", "d", "e", "f", "g", "i" }) |id| try testing.expect(cfg.find(id) == null);
    try expectIssue(&cfg, .err, "$.rules[1].where.k.bogus", "unknown predicate operator");
    try expectIssue(&cfg, .err, "$.rules[2].where.k", "empty predicate");
    try expectIssue(&cfg, .err, "$.rules[4].where.k.contains", "expected a string");
    try expectIssue(&cfg, .err, "$.rules[5].where.k.in[0]", "in needs");
    try expectIssue(&cfg, .err, "$.rules[6].where.", "empty where key");
    try expectIssue(&cfg, .warning, "$.rules[7].where.k.in", "never matches");
}

test "unit: automation: rules keep the last of repeated where keys and operators" {
    var cfg = try parse(testing.allocator,
        \\{"version":1,"rules":[
        \\ {"id":"r","when":{"event":"*"},"then":[],
        \\  "where":{"title":"a","agent":"claude","title":{"prefix":"x","prefix":"b"}}},
        \\ {"id":"s","when":{"event":"*"},"then":[],"where":{"k":{"bogus":1},"k":"ok"}}
        \\]}
    );
    defer cfg.deinit();
    const r = cfg.find("r").?;
    try testing.expectEqual(@as(usize, 2), r.where.len);
    try testing.expectEqualStrings("agent", r.where[0].key);
    try testing.expectEqualStrings("title", r.where[1].key);
    try testing.expectEqual(@as(usize, 1), r.where[1].cond.ops.len);
    try testing.expectEqualStrings("b", r.where[1].cond.ops[0].prefix);
    try expectIssue(&cfg, .warning, "$.rules[0].where.title", "duplicate key");
    try expectIssue(&cfg, .warning, "$.rules[0].where.title.prefix", "duplicate key");
    // An overridden value is ignored, errors and all.
    const s = cfg.find("s").?;
    try testing.expectEqual(@as(usize, 1), s.where.len);
    try testing.expectEqualStrings("ok", s.where[0].cond.ops[0].equals.string);
    try testing.expectEqual(@as(usize, 0), cfg.errorCount());

    // Webhook headers too: one header, the last value.
    var hc = try parse(testing.allocator,
        \\{"version":1,"rules":[{"id":"w","when":{"event":"*"},
        \\ "then":[{"action":"webhook","url":"https://h.example/","headers":{"X-Tag":7,"X-Tag":"b"}}]}]}
    );
    defer hc.deinit();
    const wh = hc.find("w").?.then[0].webhook;
    try testing.expectEqual(@as(usize, 1), wh.headers.len);
    try testing.expectEqualStrings("b", wh.headers[0].value);
    try expectIssue(&hc, .warning, "$.rules[0].then[0].headers.X-Tag", "duplicate key");
}

test "unit: automation: rules validate actions" {
    var cfg = try parse(testing.allocator,
        \\{"version":1,"rules":[
        \\ {"id":"a","when":{"event":"*"},"then":[{"title":"x"}]},
        \\ {"id":"b","when":{"event":"*"},"then":[{"action":"email"}]},
        \\ {"id":"c","when":{"event":"*"},"then":[{"action":"rpc"}]},
        \\ {"id":"d","when":{"event":"*"},"then":[{"action":"rpc","method":"m","params":[1]}]},
        \\ {"id":"e","when":{"event":"*"},"then":[{"action":"run"}]},
        \\ {"id":"f","when":{"event":"*"},"then":[{"action":"run","command":"x","timeout_seconds":301}]},
        \\ {"id":"g","when":{"event":"*"},"then":[{"action":"run","command":"x","timeout_seconds":0}]},
        \\ {"id":"h","when":{"event":"*"},"then":[{"action":"webhook","url":"http://h.example/","headers":{"Authorization":"Bearer x"}}]},
        \\ {"id":"i","when":{"event":"*"},"then":[{"action":"webhook","url":"https://h.example/","headers":{"Authorization":"Bearer x"}}]},
        \\ {"id":"j","when":{"event":"*"},"then":[{"action":"notify","body":"{{payload}}","extra":1}]},
        \\ {"id":"k","when":{"event":"*"},"then":[{"action":"notify"}]},
        \\ {"id":"l","when":{"event":"*"},"then":[{"action":"run","command":"  "}]},
        \\ {"id":"m","when":{"event":"*"},"then":[{"action":"rpc","method":"m","allow_focus":"yes"}]},
        \\ {"id":"n","when":{"event":"*"},"then":[{"action":"notify","title":5}]},
        \\ {"id":"o","when":{"event":"*"},"then":{"action":"notify"}},
        \\ {"id":"p","when":{"event":"*"},"then":[{"action":"webhook","url":"https://h.example/","headers":{"X":1}}]},
        \\ {"id":"q","when":{"event":"*"},"then":[{"action":"run","command":"a","cmd":"b"}]},
        \\ {"id":"r","when":{"event":"*"}}
        \\]}
    );
    defer cfg.deinit();
    for ([_][]const u8{ "i", "j", "k", "q" }) |id| try testing.expect(cfg.find(id) != null);
    for ([_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "l", "m", "n", "o", "p", "r" }) |id| try testing.expect(cfg.find(id) == null);
    try expectIssue(&cfg, .err, "$.rules[0].then[0]", "missing \"action\"");
    try expectIssue(&cfg, .err, "$.rules[1].then[0].action", "unknown action \"email\"");
    try expectIssue(&cfg, .err, "$.rules[2].then[0]", "needs \"method\"");
    try expectIssue(&cfg, .err, "$.rules[3].then[0].params", "must be an object");
    try expectIssue(&cfg, .err, "$.rules[4].then[0]", "needs \"command\"");
    try expectIssue(&cfg, .err, "$.rules[5].then[0].timeout_seconds", "at most 300");
    try expectIssue(&cfg, .err, "$.rules[6].then[0].timeout_seconds", "above 0");
    try expectIssue(&cfg, .err, "$.rules[7].then[0].url", "must use https");
    try expectIssue(&cfg, .warning, "$.rules[9].then[0].body", "unknown placeholder");
    try expectIssue(&cfg, .warning, "$.rules[9].then[0].extra", "unknown key");
    try expectIssue(&cfg, .warning, "$.rules[10].then[0]", "no title");
    try expectIssue(&cfg, .err, "$.rules[11].then[0].command", "must not be empty");
    try expectIssue(&cfg, .err, "$.rules[12].then[0].allow_focus", "true or false");
    try expectIssue(&cfg, .err, "$.rules[13].then[0].title", "expected a string");
    try expectIssue(&cfg, .err, "$.rules[14].then", "must be an array");
    try expectIssue(&cfg, .err, "$.rules[15].then[0].headers.X", "expected a string");
    try expectIssue(&cfg, .warning, "$.rules[16].then[0].cmd", "cmd is ignored");
    try expectIssue(&cfg, .err, "$.rules[17]", "needs \"then\"");
    try testing.expectEqualStrings("a", cfg.find("q").?.then[0].run.command);
    const wh = cfg.find("i").?.then[0].webhook;
    try testing.expectEqual(@as(usize, 1), wh.headers.len);
}

test "unit: automation: rules validate ids and unknown keys" {
    var cfg = try parse(testing.allocator,
        \\{"version":1,"extra":true,"rules":[
        \\ {"id":"","when":{"event":"*"},"then":[]},
        \\ {"id":" padded","when":{"event":"*"},"then":[]},
        \\ {"id":"tab\there","when":{"event":"*"},"then":[]},
        \\ {"id":5,"when":{"event":"*"},"then":[]},
        \\ {"id":"règle ✓","when":{"event":"*"},"then":[],"colour":"red","enabled":"no"},
        \\ {"id":"ok","id":"ok2","when":{"event":"*"},"then":[]}
        \\]}
    );
    defer cfg.deinit();
    try expectIssue(&cfg, .warning, "$.extra", "unknown key");
    try expectIssue(&cfg, .err, "$.rules[0].id", "id must be");
    try expectIssue(&cfg, .err, "$.rules[1].id", "id must be");
    try expectIssue(&cfg, .err, "$.rules[2].id", "id must be");
    try expectIssue(&cfg, .err, "$.rules[3].id", "expected a string");
    try expectIssue(&cfg, .warning, "$.rules[4].colour", "unknown key");
    try expectIssue(&cfg, .err, "$.rules[4].enabled", "true or false");
    try expectIssue(&cfg, .warning, "$.rules[5].id", "duplicate key");
    try testing.expect(cfg.find("ok2") != null);
    try testing.expectEqual(@as(usize, 1), cfg.rules.len);

    // A huge id is rejected; a maximal one is accepted.
    const gpa = testing.allocator;
    for ([_]usize{ max_id_len, max_id_len + 1 }) |n| {
        const id = try gpa.alloc(u8, n);
        defer gpa.free(id);
        @memset(id, 'x');
        const text = try std.fmt.allocPrint(gpa, "{{\"version\":1,\"rules\":[{{\"id\":\"{s}\",\"when\":{{\"event\":\"*\"}},\"then\":[]}}]}}", .{id});
        defer gpa.free(text);
        var c = try parse(gpa, text);
        defer c.deinit();
        try testing.expectEqual(@as(usize, if (n == max_id_len) 1 else 0), c.rules.len);
    }
}

test "unit: automation: rules config outlives the source buffer" {
    const gpa = testing.allocator;
    const buf = try gpa.dupe(u8, example);
    var cfg = try parse(gpa, buf);
    defer cfg.deinit();
    @memset(buf, 'x');
    gpa.free(buf);
    try testing.expectEqualStrings("triage-waiting", cfg.rules[0].id);
    try testing.expectEqualStrings("Waiting on you", cfg.rules[0].then[0].notify.title.?);
    try testing.expectEqualStrings("triage", cfg.rules[0].where[0].cond.ops[0].equals.string);
    const lims = try cfg.limits(gpa);
    defer gpa.free(lims);
    try testing.expectEqual(@as(u64, 45_000), lims[0].limit.interval_ms);
}

test "unit: automation: rules enable and disable edit the file losslessly" {
    const gpa = testing.allocator;
    const src =
        \\{
        \\  "version": 1,
        \\  // keep me
        \\  "rules": [
        \\    {
        \\      "id": "a",
        \\      "when": { "event": "workspace.created" },
        \\      "then": []
        \\    },
        \\    { "id": "b", "enabled": false, "when": { "event": "*" }, "then": [] }
        \\  ]
        \\}
    ;
    const dis = try setEnabled(gpa, src, "a", false);
    defer gpa.free(dis.text);
    try testing.expect(dis.changed);
    try testing.expect(std.mem.indexOf(u8, dis.text, "// keep me") != null);
    var cfg = try parse(gpa, dis.text);
    defer cfg.deinit();
    try testing.expect(!cfg.find("a").?.enabled);
    try testing.expectEqual(@as(usize, 0), cfg.errorCount());

    // Enabling a rule without "enabled" is a no-op; disabling a disabled one too.
    const noop = try setEnabled(gpa, src, "a", true);
    defer gpa.free(noop.text);
    try testing.expect(!noop.changed);
    try testing.expectEqualStrings(src, noop.text);
    const noop2 = try setEnabled(gpa, src, "b", false);
    defer gpa.free(noop2.text);
    try testing.expect(!noop2.changed);

    const en = try setEnabled(gpa, src, "b", true);
    defer gpa.free(en.text);
    try testing.expect(en.changed);
    try testing.expect(std.mem.indexOf(u8, en.text, "{ \"id\": \"b\", \"enabled\": true, \"when\"") != null);

    try testing.expectError(error.RuleNotFound, setEnabled(gpa, src, "zzz", true));
    try testing.expectError(error.RuleNotFound, setEnabled(gpa, "{\"version\":1}", "a", true));
    try testing.expectError(error.NotARulesFile, setEnabled(gpa, "{\"version\":1,\"rules\":3}", "a", true));
    try testing.expectError(error.SyntaxError, setEnabled(gpa, "{", "a", true));

    const m = try ruleNotFoundMessage(gpa, "zzz");
    defer gpa.free(m);
    try testing.expectEqualStrings("Automation rule not found: zzz", m);
}

test "unit: automation: rules list summary JSON" {
    const gpa = testing.allocator;
    var cfg = try parse(gpa,
        \\{"version":1,"rules":[{"id":"a","when":{"event":"workspace.*","category":"workspace"},
        \\ "where":{"title":"x"},"rate_limit":{"interval_seconds":1.5},
        \\ "then":[{"action":"notify","title":"t"},{"action":"run","command":"c"}]}]}
    );
    defer cfg.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try writeSummary(&cfg.rules[0], &jw);
    try testing.expectEqualStrings(
        \\{"id":"a","enabled":true,"when":{"event":"workspace.*","category":"workspace"},"where_count":1,"rate_limit":{"interval_seconds":1.5,"maximum":1},"actions":["notify","run"]}
    , aw.written());
}

test "unit: automation: rule patterns match case-insensitively" {
    const exact = Pattern.parse("agent.needs_input").?;
    try testing.expect(exact.matches("Agent.Needs_Input"));
    try testing.expect(!exact.matches("agent.needs_input2"));
    const pre = Pattern.parse("workspace.*").?;
    try testing.expect(pre.matches("workspace.created"));
    try testing.expect(pre.matches("WORKSPACE."));
    try testing.expect(!pre.matches("workspace"));
    const suf = Pattern.parse("*.created").?;
    try testing.expect(suf.matches("window.created"));
    try testing.expect(!suf.matches("window.created.x"));
    try testing.expect(Pattern.parse("*").?.matches(""));
    for ([_][]const u8{ "", "**", "a*b", "*a*", "a**" }) |bad| try testing.expect(Pattern.parse(bad) == null);
}
