//! Event matching for automation rules (cli-automations-config `when` /
//! `where`, cli-automation-cli `test`).
//!
//! An `Event` is a view over a catalog event: its name, category (from the
//! event itself or from wmux_proto's events catalog), source, JSON payload,
//! optional top-level event object (ids such as `workspace_id`), context the
//! engine resolves from the model (workspace tags and title, surface kind,
//! ...) and its `automation_origin`.
//!
//! `where` keys resolve in this order: engine context for the common aliases,
//! then the payload (literal key, then dotted path, also without a leading
//! `payload.`), then the top-level event object. The aliases also look at
//! their conventional payload keys (`workspace_tags`, `tags`, `kind` on
//! surface events, `_source` on agent events, ...), so an offline
//! `automation test` sees workspace tags supplied in the event payload.
//!
//! Comparisons ignore case (fold.zig). A predicate on an array value holds
//! when any element satisfies it (`not` negates the whole predicate, so
//! `{"not": "x"}` on tags means "no tag is x"). Missing values only equal
//! `null`.

const std = @import("std");
const wmux_proto = @import("wmux_proto");
const rules = @import("rules.zig");
const fold = @import("fold.zig");
const loop_guard = @import("loop_guard.zig");
const template = @import("template.zig");
const ratelimit = @import("ratelimit.zig");
const redact = @import("redact.zig");

const catalog = wmux_proto.events_catalog;
const jsonc = wmux_proto.jsonc;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// Values the engine resolves from the model for the common aliases. Null
/// fields fall back to the payload.
pub const Context = struct {
    workspace_tags: ?[]const []const u8 = null,
    workspace_title: ?[]const u8 = null,
    title: ?[]const u8 = null,
    agent: ?[]const u8 = null,
    surface_kind: ?[]const u8 = null,
};

pub const Event = struct {
    name: []const u8,
    /// Explicit category; null derives it from the catalog.
    category: ?[]const u8 = null,
    source: ?[]const u8 = null,
    payload: ?*const ObjectMap = null,
    /// The whole event object (top-level ids), when available.
    top: ?*const ObjectMap = null,
    context: Context = .{},
    origin: ?loop_guard.AutomationOrigin = null,

    pub fn entry(self: *const Event) ?*const catalog.Entry {
        return catalog.lookup(self.name);
    }

    pub fn categoryName(self: *const Event) ?[]const u8 {
        if (self.category) |c| return c;
        const e = self.entry() orelse return null;
        return e.category.name();
    }

    pub fn originPtr(self: *const Event) ?*const loop_guard.AutomationOrigin {
        return if (self.origin) |*o| o else null;
    }

    /// Variables for notify templates.
    pub fn templateVars(self: *const Event) template.Vars {
        return .{ .name = self.name, .category = self.categoryName(), .source = self.source, .payload = self.payload };
    }
};

/// A resolved `where` value.
pub const Found = union(enum) {
    missing,
    json: Value,
    text: []const u8,
    texts: []const []const u8,
};

fn payloadGet(ev: *const Event, key: []const u8) ?Value {
    if (ev.payload) |p| {
        if (template.lookupPath(p, key)) |v| return v;
    }
    return null;
}

fn firstPayload(ev: *const Event, keys: []const []const u8) ?Value {
    for (keys) |k| {
        if (payloadGet(ev, k)) |v| if (v != .null) return v;
    }
    return null;
}

fn categoryIs(ev: *const Event, c: catalog.Category) bool {
    const name = ev.categoryName() orelse return false;
    return fold.eql(name, c.name());
}

fn resolveAlias(ev: *const Event, alias: rules.Alias) Found {
    const ctx = ev.context;
    switch (alias) {
        .workspace_tag => {
            if (ctx.workspace_tags) |t| return .{ .texts = t };
            if (firstPayload(ev, &.{ "workspace.tag", "workspace.tags", "workspace_tags", "workspace_tag", "tags", "tag" })) |v| return .{ .json = v };
        },
        .workspace_title => {
            if (ctx.workspace_title) |t| return .{ .text = t };
            if (firstPayload(ev, &.{ "workspace.title", "workspace_title" })) |v| return .{ .json = v };
            if (categoryIs(ev, .workspace)) if (firstPayload(ev, &.{"title"})) |v| return .{ .json = v };
        },
        .title => {
            if (ctx.title) |t| return .{ .text = t };
            if (firstPayload(ev, &.{"title"})) |v| return .{ .json = v };
        },
        .agent => {
            if (ctx.agent) |t| return .{ .text = t };
            if (firstPayload(ev, &.{ "agent", "agent_name", "_source" })) |v| return .{ .json = v };
            if (ev.entry()) |e| if (e.origin == .agent) if (ev.source) |s| return .{ .text = s };
        },
        .surface_kind => {
            if (ctx.surface_kind) |t| return .{ .text = t };
            if (firstPayload(ev, &.{ "surface.kind", "surface_kind" })) |v| return .{ .json = v };
            if (categoryIs(ev, .surface)) if (firstPayload(ev, &.{"kind"})) |v| return .{ .json = v };
        },
    }
    return .missing;
}

/// Resolves a `where` key for `ev`.
pub fn resolve(ev: *const Event, pred_key: []const u8, alias: ?rules.Alias) Found {
    if (alias) |a| {
        const f = resolveAlias(ev, a);
        if (f != .missing) return f;
    }
    if (payloadGet(ev, pred_key)) |v| return .{ .json = v };
    if (std.mem.startsWith(u8, pred_key, "payload.")) {
        if (payloadGet(ev, pred_key["payload.".len..])) |v| return .{ .json = v };
    }
    if (ev.top) |t| {
        if (template.lookupPath(t, pred_key)) |v| return .{ .json = v };
    }
    return .missing;
}

// ---------------------------------------------------------------------------
// Predicates

/// One comparable element of a resolved value.
const Elem = union(enum) {
    null,
    boolean: bool,
    number: f64,
    /// JSON number text (integers and number_string).
    number_text: []const u8,
    string: []const u8,
    /// Objects never match a scalar.
    other,
};

fn elemOf(v: Value) Elem {
    return switch (v) {
        .null => .null,
        .bool => |b| .{ .boolean = b },
        .integer => |n| .{ .number = @floatFromInt(n) },
        .float => |f| .{ .number = f },
        .number_string => |s| .{ .number_text = s },
        .string => |s| .{ .string = s },
        .array, .object => .other,
    };
}

fn elemNumber(e: Elem) ?f64 {
    return switch (e) {
        .number => |f| f,
        .number_text => |s| std.fmt.parseFloat(f64, s) catch null,
        .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch null,
        else => null,
    };
}

/// Text form of an element for string comparisons (`buf` holds numbers).
fn elemText(e: Elem, buf: []u8) ?[]const u8 {
    return switch (e) {
        .string => |s| s,
        .number_text => |s| s,
        .number => |f| blk: {
            if (@floor(f) == f and @abs(f) < 1e15) break :blk std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(f))}) catch null;
            break :blk std.fmt.bufPrint(buf, "{d}", .{f}) catch null;
        },
        .boolean => |b| if (b) "true" else "false",
        .null, .other => null,
    };
}

fn scalarEquals(s: rules.Scalar, e: Elem) bool {
    var buf: [64]u8 = undefined;
    return switch (s) {
        .null => e == .null,
        .boolean => |b| e == .boolean and e.boolean == b,
        .number => |n| if (elemNumber(e)) |x| x == n.value else false,
        .string => |str| switch (e) {
            .null, .other => false,
            .number, .number_text => if (elemNumber(e)) |x| (if (std.fmt.parseFloat(f64, str) catch null) |y| x == y else false) else false,
            else => if (elemText(e, &buf)) |t| fold.eql(t, str) else false,
        },
    };
}

const TextOp = enum { contains, prefix, suffix };

fn textOp(op: TextOp, needle: []const u8, e: Elem) bool {
    var buf: [64]u8 = undefined;
    const t = elemText(e, &buf) orelse return false;
    return switch (op) {
        .contains => fold.contains(t, needle),
        .prefix => fold.startsWith(t, needle),
        .suffix => fold.endsWith(t, needle),
    };
}

fn opOnElem(op: rules.Op, e: Elem) bool {
    return switch (op) {
        .equals => |s| scalarEquals(s, e),
        .contains => |n| textOp(.contains, n, e),
        .prefix => |n| textOp(.prefix, n, e),
        .suffix => |n| textOp(.suffix, n, e),
        .in => |list| for (list) |s| {
            if (scalarEquals(s, e)) break true;
        } else false,
        .not => unreachable,
    };
}

/// True when any element of `f` satisfies `op` (missing behaves as null).
fn opHolds(op: rules.Op, f: Found) bool {
    if (op == .not) return !condHolds(op.not.*, f);
    switch (f) {
        .missing => return opOnElem(op, .null),
        .text => |t| return opOnElem(op, .{ .string = t }),
        .texts => |list| {
            for (list) |t| if (opOnElem(op, .{ .string = t })) return true;
            return false;
        },
        .json => |v| switch (v) {
            .array => |arr| {
                for (arr.items) |item| if (opOnElem(op, elemOf(item))) return true;
                return false;
            },
            else => return opOnElem(op, elemOf(v)),
        },
    }
}

pub fn condHolds(c: rules.Cond, f: Found) bool {
    for (c.ops) |op| if (!opHolds(op, f)) return false;
    return true;
}

pub fn predicateHolds(p: *const rules.Predicate, ev: *const Event) bool {
    return condHolds(p.cond, resolve(ev, p.key, p.alias));
}

// ---------------------------------------------------------------------------
// Rules

pub fn whenMatches(w: rules.When, ev: *const Event) bool {
    if (w.event) |p| if (!p.matches(ev.name)) return false;
    if (w.category) |p| {
        const c = ev.categoryName() orelse return false;
        if (!p.matches(c)) return false;
    }
    return true;
}

pub const Outcome = enum {
    matched,
    disabled,
    event_mismatch,
    category_mismatch,
    where_mismatch,
    /// Matched, but the rule is in the event's automation chain or the chain is full.
    loop_skipped,

    pub fn text(self: Outcome) []const u8 {
        return @tagName(self);
    }
};

pub const Evaluation = struct {
    outcome: Outcome,
    /// Index into `rule.where` of the first predicate that failed.
    failed_predicate: ?usize = null,
    loop: ?loop_guard.SkipReason = null,

    pub fn fires(self: Evaluation) bool {
        return self.outcome == .matched;
    }
};

/// Evaluates `rule` against `ev`, without side effects. Order: enabled,
/// event, category, where, loop guard (rate limits are the caller's).
pub fn evaluate(rule: *const rules.Rule, ev: *const Event) Evaluation {
    if (!rule.enabled) return .{ .outcome = .disabled };
    if (rule.when.event) |p| if (!p.matches(ev.name)) return .{ .outcome = .event_mismatch };
    if (rule.when.category) |p| {
        const c = ev.categoryName() orelse return .{ .outcome = .category_mismatch };
        if (!p.matches(c)) return .{ .outcome = .category_mismatch };
    }
    for (rule.where, 0..) |*p, i| {
        if (!predicateHolds(p, ev)) return .{ .outcome = .where_mismatch, .failed_predicate = i };
    }
    if (loop_guard.skipReason(ev.originPtr(), rule.id)) |r| return .{ .outcome = .loop_skipped, .loop = r };
    return .{ .outcome = .matched };
}

/// Indices of the rules in `cfg` that fire for `ev` (before rate limits), in file order.
pub fn firingRules(gpa: Allocator, cfg: *const rules.Config, ev: *const Event) Allocator.Error![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    for (cfg.rules, 0..) |*r, i| {
        if (evaluate(r, ev).fires()) try out.append(gpa, i);
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Test events (`automation test <id> --event <json|@file>`)

pub const EventError = error{
    OutOfMemory,
    TooLarge,
    TooDeep,
    InvalidJson,
    NotObject,
    MissingName,
};

pub fn eventErrorMessage(e: EventError) []const u8 {
    return switch (e) {
        error.InvalidJson, error.NotObject => rules.msg.test_event_not_object,
        error.TooLarge => "automation test event exceeds 4 MiB",
        error.TooDeep => "automation test event is nested too deeply",
        error.MissingName => "automation test event needs a \"name\" string",
        error.OutOfMemory => "out of memory",
    };
}

/// Fails with `TooDeep` when arrays/objects nest past `max` (no allocation).
fn checkDepth(text: []const u8, max: u32) EventError!void {
    var tok: jsonc.Tokenizer = .init(text, false);
    var depth: u32 = 0;
    while (tok.next()) |t| switch (t.tag) {
        .lbrace, .lbracket => {
            depth += 1;
            if (depth > max) return error.TooDeep;
        },
        .rbrace, .rbracket => depth -|= 1,
        .eof => return,
        else => {},
    };
    return error.InvalidJson;
}

/// Parses a synthetic event: `{"name", "category"?, "source"?, "payload"?,
/// "automation_origin"?, ...ids}`. Bounded to `rules.max_bytes` and
/// `rules.max_depth`. A leading UTF-8 byte order mark is skipped, as the
/// rules loader does (Notepad and PowerShell 5.1 write one into `@file`
/// events). Everything lives in `arena`.
pub fn parseEventJson(arena: Allocator, text_in: []const u8) EventError!Event {
    if (text_in.len > rules.max_bytes) return error.TooLarge;
    const text = if (std.mem.startsWith(u8, text_in, jsonc.utf8_bom)) text_in[jsonc.utf8_bom.len..] else text_in;
    try checkDepth(text, rules.max_depth);
    const v = std.json.parseFromSliceLeaky(Value, arena, text, .{ .duplicate_field_behavior = .use_last }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    const top = try arena.create(ObjectMap);
    top.* = switch (v) {
        .object => |o| o,
        else => return error.NotObject,
    };
    return eventFromObject(arena, top);
}

/// Builds an event view over an already parsed event object.
pub fn eventFromObject(arena: Allocator, top: *const ObjectMap) EventError!Event {
    const name = switch (top.get("name") orelse return error.MissingName) {
        .string => |s| s,
        else => return error.MissingName,
    };
    var ev: Event = .{ .name = name, .top = top };
    if (top.get("category")) |c| if (c == .string) {
        ev.category = c.string;
    };
    if (top.get("source")) |s| if (s == .string) {
        ev.source = s.string;
    };
    if (ev.source == null) if (ev.entry()) |e| {
        ev.source = e.source;
    };
    if (top.getPtr("payload")) |p| if (p.* == .object) {
        ev.payload = &p.object;
    };
    if (top.get("automation_origin")) |o| ev.origin = try loop_guard.fromJson(arena, o);
    return ev;
}

/// Writes the `automation test` result: `{"id","matched","outcome",
/// "failed_predicate"?,"enabled","rate_limited","dispatched":false,
/// "actions":[types],"event":<redacted event>}`. `would_allow` is the
/// limiter's dry-run verdict (state is never touched).
pub fn writeTestResult(
    gpa: Allocator,
    rule: *const rules.Rule,
    ev: *const Event,
    eval: Evaluation,
    would_allow: bool,
    jw: *std.json.Stringify,
) (Allocator.Error || std.Io.Writer.Error)!void {
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(rule.id);
    try jw.objectField("matched");
    try jw.write(eval.fires());
    try jw.objectField("outcome");
    try jw.write(eval.outcome.text());
    if (eval.failed_predicate) |i| {
        try jw.objectField("failed_predicate");
        try jw.write(rule.where[i].key);
    }
    if (eval.loop) |l| {
        try jw.objectField("loop");
        try jw.write(@tagName(l));
    }
    try jw.objectField("enabled");
    try jw.write(rule.enabled);
    try jw.objectField("rate_limited");
    try jw.write(eval.fires() and !would_allow);
    try jw.objectField("dispatched");
    try jw.write(false);
    try jw.objectField("actions");
    try jw.beginArray();
    for (rule.then) |a| try jw.write(a.typeName());
    try jw.endArray();
    try jw.objectField("event");
    if (ev.top) |t| {
        try redact.writeValue(gpa, .{ .object = t.* }, jw);
    } else {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(ev.name);
        try jw.endObject();
    }
    try jw.endObject();
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    cfg: rules.Config,

    fn init(src: []const u8) !Fixture {
        var cfg = try rules.parse(testing.allocator, src);
        errdefer cfg.deinit();
        if (cfg.errorCount() != 0) {
            for (cfg.issues) |i| std.log.err("{f}", .{i});
            return error.TestUnexpectedResult;
        }
        return .{ .arena_state = .init(testing.allocator), .cfg = cfg };
    }

    fn deinit(self: *Fixture) void {
        self.cfg.deinit();
        self.arena_state.deinit();
    }

    fn event(self: *Fixture, text: []const u8) !Event {
        return parseEventJson(self.arena_state.allocator(), text);
    }

    fn outcome(self: *Fixture, id: []const u8, text: []const u8) !Outcome {
        const ev = try self.event(text);
        return evaluate(self.cfg.find(id).?, &ev).outcome;
    }
};

test "unit: automation: match a rule on workspace tag and surface kind" {
    var f = try Fixture.init(rules_example);
    defer f.deinit();
    const id = "triage-waiting";
    try testing.expectEqual(Outcome.matched, try f.outcome(id,
        \\{"name":"agent.needs_input","payload":{"workspace_tags":["triage","x"],"surface_kind":"terminal","session_id":"s1"}}
    ));
    // Tag matching ignores case; wrong tag, missing tags and wrong kind fail at their predicate.
    try testing.expectEqual(Outcome.matched, try f.outcome(id,
        \\{"name":"agent.needs_input","payload":{"workspace.tag":"TRIAGE","surface.kind":"Terminal"}}
    ));
    const ev = try f.event(
        \\{"name":"agent.needs_input","payload":{"workspace_tags":["other"],"surface_kind":"terminal"}}
    );
    const e = evaluate(f.cfg.find(id).?, &ev);
    try testing.expectEqual(Outcome.where_mismatch, e.outcome);
    try testing.expectEqual(@as(usize, 0), e.failed_predicate.?);
    try testing.expectEqual(Outcome.where_mismatch, try f.outcome(id,
        \\{"name":"agent.needs_input"}
    ));
    try testing.expectEqual(Outcome.event_mismatch, try f.outcome(id,
        \\{"name":"agent.message.read","payload":{"workspace_tags":["triage"],"surface_kind":"terminal"}}
    ));
}

/// An original fixture (clean room G1).
const rules_example =
    \\{"version":1,"rules":[{"id":"triage-waiting","when":{"event":"agent.needs_input"},
    \\ "where":{"workspace.tag":"triage","surface.kind":"terminal"},
    \\ "rate_limit":{"interval_seconds":45,"maximum":1},
    \\ "then":[{"action":"notify","title":"Waiting on you","body":"Session {{payload.session_id}} paused"}]}]}
;

test "unit: automation: match workspace.created rule fires per event and respects enabled" {
    var f = try Fixture.init(
        \\{"version":1,"rules":[
        \\ {"id":"on","when":{"event":"workspace.created"},"then":[{"action":"notify","title":"new"}]},
        \\ {"id":"off","enabled":false,"when":{"event":"workspace.created"},"then":[{"action":"notify","title":"new"}]}
        \\]}
    );
    defer f.deinit();
    const ev = try f.event("{\"name\":\"workspace.created\"}");
    const fired = try firingRules(testing.allocator, &f.cfg, &ev);
    defer testing.allocator.free(fired);
    try testing.expectEqualSlices(usize, &.{0}, fired);
    try testing.expectEqual(Outcome.disabled, evaluate(f.cfg.find("off").?, &ev).outcome);
}

test "unit: automation: match event and category wildcards against the catalog" {
    var f = try Fixture.init(
        \\{"version":1,"rules":[
        \\ {"id":"ws","when":{"event":"workspace.*"},"then":[]},
        \\ {"id":"created","when":{"event":"*.created"},"then":[]},
        \\ {"id":"cat","when":{"category":"agent"},"then":[]},
        \\ {"id":"catwild","when":{"category":"*ace"},"then":[]},
        \\ {"id":"both","when":{"event":"agent.hook.*","category":"agent"},"then":[]},
        \\ {"id":"all","when":{"event":"*"},"then":[]}
        \\]}
    );
    defer f.deinit();
    try testing.expectEqual(Outcome.matched, try f.outcome("ws", "{\"name\":\"workspace.created\"}"));
    try testing.expectEqual(Outcome.event_mismatch, try f.outcome("ws", "{\"name\":\"window.created\"}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("created", "{\"name\":\"window.created\"}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("cat", "{\"name\":\"agent.hook.Stop\"}"));
    try testing.expectEqual(Outcome.category_mismatch, try f.outcome("cat", "{\"name\":\"workspace.created\"}"));
    // Unknown events have no category unless the event names one.
    try testing.expectEqual(Outcome.category_mismatch, try f.outcome("cat", "{\"name\":\"made.up\"}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("cat", "{\"name\":\"made.up\",\"category\":\"AGENT\"}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("catwild", "{\"name\":\"workspace.created\"}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("both", "{\"name\":\"agent.hook.PreToolUse\"}"));
    try testing.expectEqual(Outcome.event_mismatch, try f.outcome("both", "{\"name\":\"agent.needs_input\"}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("all", "{\"name\":\"\"}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("all", "{\"name\":\"ünï.cødé\"}"));
}

test "unit: automation: match where operators" {
    var f = try Fixture.init(
        \\{"version":1,"rules":[
        \\ {"id":"contains","when":{"event":"*"},"then":[],"where":{"workspace.title":{"contains":"api"}}},
        \\ {"id":"prefix","when":{"event":"*"},"then":[],"where":{"title":{"prefix":"Build"}}},
        \\ {"id":"suffix","when":{"event":"*"},"then":[],"where":{"title":{"suffix":"FAILED"}}},
        \\ {"id":"in","when":{"event":"*"},"then":[],"where":{"agent":{"in":["claude","codex"]}}},
        \\ {"id":"not","when":{"event":"*"},"then":[],"where":{"workspace.tag":{"not":"muted"}}},
        \\ {"id":"combo","when":{"event":"*"},"then":[],"where":{"title":{"prefix":"a","suffix":"z","not":{"contains":"q"}}}},
        \\ {"id":"num","when":{"event":"*"},"then":[],"where":{"index":2,"count":{"in":[1,"3"]}}},
        \\ {"id":"bool","when":{"event":"*"},"then":[],"where":{"focused":true}},
        \\ {"id":"null","when":{"event":"*"},"then":[],"where":{"gone":null}},
        \\ {"id":"nested","when":{"event":"*"},"then":[],"where":{"payload.result.status":"ok","workspace_id":{"prefix":"0A"}}}
        \\]}
    );
    defer f.deinit();
    try testing.expectEqual(Outcome.matched, try f.outcome("contains", "{\"name\":\"x\",\"payload\":{\"workspace_title\":\"My API work\"}}"));
    try testing.expectEqual(Outcome.where_mismatch, try f.outcome("contains", "{\"name\":\"x\",\"payload\":{\"workspace_title\":\"docs\"}}"));
    // workspace.title falls back to `title` only on workspace events.
    try testing.expectEqual(Outcome.matched, try f.outcome("contains", "{\"name\":\"workspace.renamed\",\"payload\":{\"title\":\"API\"}}"));
    try testing.expectEqual(Outcome.where_mismatch, try f.outcome("contains", "{\"name\":\"surface.created\",\"payload\":{\"title\":\"API\"}}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("prefix", "{\"name\":\"x\",\"payload\":{\"title\":\"build ok\"}}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("suffix", "{\"name\":\"x\",\"payload\":{\"title\":\"build failed\"}}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("in", "{\"name\":\"x\",\"payload\":{\"agent\":\"Codex\"}}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("in", "{\"name\":\"agent.hook.Stop\",\"payload\":{\"_source\":\"claude\"}}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("in", "{\"name\":\"agent.hook.Stop\",\"source\":\"claude\"}"));
    try testing.expectEqual(Outcome.where_mismatch, try f.outcome("in", "{\"name\":\"x\",\"source\":\"claude\"}"));
    try testing.expectEqual(Outcome.where_mismatch, try f.outcome("in", "{\"name\":\"x\",\"payload\":{\"agent\":\"gemini\"}}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("not", "{\"name\":\"x\",\"payload\":{\"tags\":[\"a\",\"b\"]}}"));
    try testing.expectEqual(Outcome.where_mismatch, try f.outcome("not", "{\"name\":\"x\",\"payload\":{\"tags\":[\"a\",\"MUTED\"]}}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("not", "{\"name\":\"x\"}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("combo", "{\"name\":\"x\",\"payload\":{\"title\":\"abcz\"}}"));
    try testing.expectEqual(Outcome.where_mismatch, try f.outcome("combo", "{\"name\":\"x\",\"payload\":{\"title\":\"aqz\"}}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("num", "{\"name\":\"x\",\"payload\":{\"index\":2.0,\"count\":3}}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("num", "{\"name\":\"x\",\"payload\":{\"index\":\"2\",\"count\":1}}"));
    try testing.expectEqual(Outcome.where_mismatch, try f.outcome("num", "{\"name\":\"x\",\"payload\":{\"index\":3,\"count\":1}}"));
    try testing.expectEqual(Outcome.where_mismatch, try f.outcome("num", "{\"name\":\"x\",\"payload\":{\"index\":2,\"count\":{\"v\":1}}}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("bool", "{\"name\":\"x\",\"payload\":{\"focused\":true}}"));
    try testing.expectEqual(Outcome.where_mismatch, try f.outcome("bool", "{\"name\":\"x\",\"payload\":{\"focused\":\"true\"}}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("null", "{\"name\":\"x\"}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("null", "{\"name\":\"x\",\"payload\":{\"gone\":null}}"));
    try testing.expectEqual(Outcome.where_mismatch, try f.outcome("null", "{\"name\":\"x\",\"payload\":{\"gone\":0}}"));
    try testing.expectEqual(Outcome.matched, try f.outcome("nested", "{\"name\":\"x\",\"workspace_id\":\"0a1b\",\"payload\":{\"result\":{\"status\":\"OK\"}}}"));
    try testing.expectEqual(Outcome.where_mismatch, try f.outcome("nested", "{\"name\":\"x\",\"workspace_id\":\"ff\",\"payload\":{\"result\":{\"status\":\"ok\"}}}"));
}

test "unit: automation: match uses the last of repeated where keys" {
    var f = try Fixture.init(
        \\{"version":1,"rules":[{"id":"r","when":{"event":"*"},"then":[],
        \\ "where":{"title":"a","title":{"prefix":"x","prefix":"b"}}}]}
    );
    defer f.deinit();
    try testing.expectEqual(Outcome.matched, try f.outcome("r", "{\"name\":\"x\",\"payload\":{\"title\":\"Bee\"}}"));
    try testing.expectEqual(Outcome.where_mismatch, try f.outcome("r", "{\"name\":\"x\",\"payload\":{\"title\":\"a\"}}"));
    try testing.expectEqual(Outcome.where_mismatch, try f.outcome("r", "{\"name\":\"x\",\"payload\":{\"title\":\"xb\"}}"));
}

test "unit: automation: match engine context overrides payload aliases" {
    var f = try Fixture.init(
        \\{"version":1,"rules":[{"id":"r","when":{"event":"*"},"then":[],
        \\ "where":{"workspace.tag":"triage","surface.kind":"terminal","agent":"claude","title":"T","workspace.title":"W"}}]}
    );
    defer f.deinit();
    var ev = try f.event("{\"name\":\"agent.needs_input\",\"payload\":{\"tags\":[\"nope\"]}}");
    const r = f.cfg.find("r").?;
    try testing.expectEqual(Outcome.where_mismatch, evaluate(r, &ev).outcome);
    const tags = [_][]const u8{ "x", "Triage" };
    ev.context = .{ .workspace_tags = &tags, .surface_kind = "TERMINAL", .agent = "claude", .title = "t", .workspace_title = "w" };
    try testing.expectEqual(Outcome.matched, evaluate(r, &ev).outcome);
    ev.context.workspace_tags = &.{};
    try testing.expectEqual(Outcome.where_mismatch, evaluate(r, &ev).outcome);
}

test "unit: automation: match skips rules already in the automation chain" {
    var f = try Fixture.init(
        \\{"version":1,"rules":[
        \\ {"id":"A","when":{"event":"workspace.created"},"then":[{"action":"rpc","method":"workspace.create"}]},
        \\ {"id":"B","when":{"event":"workspace.created"},"then":[]}
        \\]}
    );
    defer f.deinit();
    const a = f.cfg.find("A").?;
    // External creation: A fires.
    const external = try f.event("{\"name\":\"workspace.created\"}");
    try testing.expectEqual(Outcome.matched, evaluate(a, &external).outcome);
    // The workspace A's action created carries A in its chain: A is skipped, B still fires.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var caused = external;
    caused.origin = try loop_guard.extend(arena_state.allocator(), null, "A");
    const e = evaluate(a, &caused);
    try testing.expectEqual(Outcome.loop_skipped, e.outcome);
    try testing.expectEqual(loop_guard.SkipReason.cycle, e.loop.?);
    try testing.expectEqual(Outcome.matched, evaluate(f.cfg.find("B").?, &caused).outcome);
    // The same through an event JSON carrying automation_origin (CLI round trip).
    try testing.expectEqual(Outcome.loop_skipped, try f.outcome("A",
        \\{"name":"workspace.created","automation_origin":{"rule_id":"B","chain":["A","B"],"depth":2}}
    ));
    try testing.expectEqual(Outcome.matched, try f.outcome("A",
        \\{"name":"workspace.created","automation_origin":"garbage"}
    ));
}

test "unit: automation: match parses test events and rejects malformed ones" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ev = try parseEventJson(arena, "{\"name\":\"agent.needs_input\"}");
    try testing.expectEqualStrings("agent", ev.categoryName().?);
    try testing.expectEqualStrings("agents.store", ev.source.?);
    try testing.expect(ev.payload == null);

    const bad = [_]struct { []const u8, EventError }{
        .{ "", error.InvalidJson },
        .{ "{", error.InvalidJson },
        .{ "[]", error.NotObject },
        .{ "\"x\"", error.NotObject },
        .{ "null", error.NotObject },
        .{ "{}", error.MissingName },
        .{ "{\"name\":5}", error.MissingName },
        .{ "{\"name\":\"x\"} trailing", error.InvalidJson },
        .{ "{\"name\":\"x\",/*c*/}", error.InvalidJson },
    };
    for (bad) |b| try testing.expectError(b[1], parseEventJson(arena, b[0]));
    try testing.expectEqualStrings("automation test event must be a JSON object", eventErrorMessage(error.NotObject));

    // Nesting guard and size bound.
    var deep: std.ArrayList(u8) = .empty;
    try deep.appendSlice(arena, "{\"name\":\"x\",\"payload\":");
    for (0..rules.max_depth) |_| try deep.append(arena, '[');
    for (0..rules.max_depth) |_| try deep.append(arena, ']');
    try deep.append(arena, '}');
    try testing.expectError(error.TooDeep, parseEventJson(arena, deep.items));
    const huge = try arena.alloc(u8, rules.max_bytes + 1);
    @memset(huge, ' ');
    try testing.expectError(error.TooLarge, parseEventJson(arena, huge));

    // Unicode names and payload strings survive; payload must be an object to be used.
    const u = try parseEventJson(arena, "{\"name\":\"wmux.ünï\",\"payload\":[1]}");
    try testing.expectEqualStrings("wmux.ünï", u.name);
    try testing.expect(u.payload == null);
    try testing.expect(u.categoryName() == null);

    // Windows files: a UTF-8 byte order mark and CRLF line breaks are fine; only one BOM is skipped.
    const bom = try parseEventJson(arena, "\xEF\xBB\xBF{\r\n  \"name\": \"workspace.created\"\r\n}\r\n");
    try testing.expectEqualStrings("workspace.created", bom.name);
    try testing.expectError(error.InvalidJson, parseEventJson(arena, "\xEF\xBB\xBF"));
    try testing.expectError(error.InvalidJson, parseEventJson(arena, "\xEF\xBB\xBF\xEF\xBB\xBF{\"name\":\"x\"}"));
}

test "unit: automation: match dry-run test result does not touch rate limits" {
    var f = try Fixture.init(rules_example);
    defer f.deinit();
    const gpa = testing.allocator;
    const r = f.cfg.find("triage-waiting").?;
    const ev = try f.event(
        \\{"name":"agent.needs_input","payload":{"workspace_tags":["triage"],"surface_kind":"terminal","api_key":"k"}}
    );
    var lim: ratelimit.Limiter = .init(r.rate_limit);
    defer lim.deinit(gpa);
    const e = evaluate(r, &ev);
    try testing.expect(e.fires());
    for (0..3) |_| try testing.expect(lim.wouldAllow(0));
    try testing.expectEqual(@as(usize, 0), lim.len);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try writeTestResult(gpa, r, &ev, e, lim.wouldAllow(0), &jw);
    try testing.expectEqualStrings(
        \\{"id":"triage-waiting","matched":true,"outcome":"matched","enabled":true,"rate_limited":false,"dispatched":false,"actions":["notify"],"event":{"name":"agent.needs_input","payload":{"workspace_tags":["triage"],"surface_kind":"terminal","api_key":"[REDACTED]"}}}
    , aw.written());

    // After a real firing the dry run reports rate_limited, still without changing state.
    try testing.expect(try lim.tryAcquire(gpa, 0));
    var aw2: std.Io.Writer.Allocating = .init(gpa);
    defer aw2.deinit();
    var jw2: std.json.Stringify = .{ .writer = &aw2.writer };
    const miss = try f.event("{\"name\":\"agent.needs_input\"}");
    try writeTestResult(gpa, r, &miss, evaluate(r, &miss), lim.wouldAllow(1), &jw2);
    try testing.expect(std.mem.indexOf(u8, aw2.written(), "\"matched\":false,\"outcome\":\"where_mismatch\",\"failed_predicate\":\"workspace.tag\"") != null);
    try testing.expectEqual(@as(usize, 1), lim.len);
}

test "unit: automation: match template vars come from the event" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const ev = try parseEventJson(arena_state.allocator(), "{\"name\":\"agent.needs_input\",\"payload\":{\"session_id\":\"s-9\"}}");
    const out = try template.render(testing.allocator, "{{event.category}}:{{event.source}}:{{payload.session_id}}", ev.templateVars());
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("agent:agents.store:s-9", out);
}

test "unit: automation: match handles huge arrays and unicode values" {
    var f = try Fixture.init(
        \\{"version":1,"rules":[{"id":"r","when":{"event":"*"},"then":[],"where":{"workspace.tag":{"contains":"ÉCOLE"}}}]}
    );
    defer f.deinit();
    const arena = f.arena_state.allocator();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, "{\"name\":\"x\",\"payload\":{\"tags\":[");
    for (0..10_000) |i| try text.print(arena, "\"t{d}\",", .{i});
    try text.appendSlice(arena, "\"la petite école\"]}}");
    try testing.expectEqual(Outcome.matched, try f.outcome("r", text.items));
}
