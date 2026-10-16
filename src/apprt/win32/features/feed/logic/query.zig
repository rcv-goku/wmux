//! `feed.list` filtering, paging and result encoding, plus the panel's
//! Actionable/Resolved partition and per-agent workstream summaries. Inputs
//! are item slices ordered oldest first (as held by `store.Store`); results
//! are latest first.

const std = @import("std");
const proto = @import("wmux_proto");
const model = @import("model.zig");
const Uuid = proto.uuid.Uuid;
const Item = model.Item;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const default_limit: usize = 200;
pub const max_limit: usize = 2000;

pub const Filter = struct {
    /// cmux `pending_only`.
    pending_only: bool = false,
    /// wmux extensions (absent in cmux; ignored by cmux clients).
    kinds: []const model.Kind = &.{},
    source: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    workspace_id: ?Uuid = null,
    surface_id: ?Uuid = null,
    /// Paging cursor: only items older than the item with this id.
    before: ?Uuid = null,
    limit: usize = default_limit,

    pub fn matches(f: *const Filter, it: *const Item) bool {
        if (f.pending_only and it.status != .pending) return false;
        if (f.kinds.len > 0 and std.mem.indexOfScalar(model.Kind, f.kinds, it.kind) == null) return false;
        if (f.source) |s| if (!std.ascii.eqlIgnoreCase(s, it.source)) return false;
        if (f.session_id) |s| if (it.session_id == null or !std.mem.eql(u8, s, it.session_id.?)) return false;
        if (f.workspace_id) |u| if (it.workspace_id == null or !u.eql(it.workspace_id.?)) return false;
        if (f.surface_id) |u| if (it.surface_id == null or !u.eql(it.surface_id.?)) return false;
        return true;
    }
};

pub const ParamError = error{ InvalidParams, OutOfMemory };

/// Message for the last `parseListParams` failure.
pub const ParamDiag = struct { message: []const u8 = "" };

/// Parses `feed.list` params. `kinds` storage is allocated in `a`; strings
/// borrow from `params`.
pub fn parseListParams(a: Allocator, params: ?Value, diag: *ParamDiag) ParamError!Filter {
    var f: Filter = .{};
    const p = params orelse return f;
    const obj = switch (p) {
        .null => return f,
        .object => |o| o,
        else => return fail(diag, "params must be an object"),
    };
    if (obj.get("pending_only")) |v| switch (v) {
        .bool => |b| f.pending_only = b,
        .null => {},
        else => return fail(diag, "pending_only must be a boolean"),
    };
    if (obj.get("kind")) |v| switch (v) {
        .null => {},
        .string => |s| {
            const k = model.Kind.parse(s) orelse return fail(diag, "unknown feed item kind");
            const one = try a.alloc(model.Kind, 1);
            one[0] = k;
            f.kinds = one;
        },
        .array => |arr| {
            const ks = try a.alloc(model.Kind, arr.items.len);
            for (arr.items, ks) |e, *k| k.* = switch (e) {
                .string => |s| model.Kind.parse(s) orelse return fail(diag, "unknown feed item kind"),
                else => return fail(diag, "kind must be a string or an array of strings"),
            };
            f.kinds = ks;
        },
        else => return fail(diag, "kind must be a string or an array of strings"),
    };
    inline for (.{ "source", "session_id" }) |key| {
        if (obj.get(key)) |v| switch (v) {
            .null => {},
            .string => |s| @field(f, key) = s,
            else => return fail(diag, key ++ " must be a string"),
        };
    }
    inline for (.{ "workspace_id", "surface_id", "before" }) |key| {
        if (obj.get(key)) |v| switch (v) {
            .null => {},
            .string => |s| @field(f, key) = Uuid.parse(s) catch return fail(diag, key ++ " must be a UUID"),
            else => return fail(diag, key ++ " must be a UUID"),
        };
    }
    if (obj.get("limit")) |v| switch (v) {
        .null => {},
        .integer => |n| {
            if (n < 1 or n > max_limit) return fail(diag, "limit must be between 1 and 2000");
            f.limit = @intCast(n);
        },
        else => return fail(diag, "limit must be between 1 and 2000"),
    };
    return f;
}

fn fail(diag: *ParamDiag, msg: []const u8) ParamError {
    diag.message = msg;
    return error.InvalidParams;
}

pub const Page = struct {
    /// Latest first; owned slice of borrowed item pointers.
    items: []*Item,
    /// More matching items exist past the last one ("Load older activity").
    has_more: bool,

    pub fn deinit(self: Page, a: Allocator) void {
        a.free(self.items);
    }
};

/// Applies `f` to `oldest_first`. An unknown `before` cursor yields an empty
/// page (the item fell out of the window).
pub fn select(a: Allocator, oldest_first: []const *Item, f: Filter) Allocator.Error!Page {
    var end = oldest_first.len;
    if (f.before) |cur| {
        end = 0;
        for (oldest_first, 0..) |it, i| if (it.id.eql(cur)) {
            end = i;
            break;
        };
    }
    var out: std.ArrayList(*Item) = .empty;
    errdefer out.deinit(a);
    var has_more = false;
    var i = end;
    while (i > 0) {
        i -= 1;
        const it = oldest_first[i];
        if (!f.matches(it)) continue;
        if (out.items.len == f.limit) {
            has_more = true;
            break;
        }
        try out.append(a, it);
    }
    return .{ .items = try out.toOwnedSlice(a), .has_more = has_more };
}

/// Panel tabs: Actionable = pending decisions (latest first) with resolved
/// and closed decisions under the "Resolved" divider; All Activity = all.
pub const Actionable = struct {
    pending: []*Item,
    resolved: []*Item,

    pub fn deinit(self: Actionable, a: Allocator) void {
        a.free(self.pending);
        a.free(self.resolved);
    }
};

pub fn actionable(a: Allocator, oldest_first: []const *Item) Allocator.Error!Actionable {
    var pending: std.ArrayList(*Item) = .empty;
    errdefer pending.deinit(a);
    var resolved: std.ArrayList(*Item) = .empty;
    errdefer resolved.deinit(a);
    var i = oldest_first.len;
    while (i > 0) {
        i -= 1;
        const it = oldest_first[i];
        if (!it.kind.isDecision()) continue;
        if (it.status == .pending) try pending.append(a, it) else try resolved.append(a, it);
    }
    const p = try pending.toOwnedSlice(a);
    errdefer a.free(p);
    return .{ .pending = p, .resolved = try resolved.toOwnedSlice(a) };
}

/// Empty-state copy of the panel tabs (title, body).
pub const EmptyState = struct { title: []const u8, body: []const u8 };
pub const empty_actionable: EmptyState = .{ .title = "No pending decisions", .body = "Permission, plan, and question requests from AI agents will appear here." };
pub const empty_activity: EmptyState = .{ .title = "No activity yet", .body = "Agent decisions and todo-list updates will appear here." };

/// One agent context (source + session) of the timeline.
pub const Workstream = struct {
    source: []const u8,
    session_id: ?[]const u8,
    workspace_id: ?Uuid,
    surface_id: ?Uuid,
    item_count: usize,
    pending_count: usize,
    last_activity_ms: i64,
    /// Newest item of the stream.
    latest: *Item,
};

/// Groups items by (source, session_id), most recently active first.
/// Strings borrow from the items.
pub fn workstreams(a: Allocator, oldest_first: []const *Item) Allocator.Error![]Workstream {
    var list: std.ArrayList(Workstream) = .empty;
    errdefer list.deinit(a);
    for (oldest_first) |it| {
        const ws = for (list.items) |*w| {
            if (std.mem.eql(u8, w.source, it.source) and optEql(w.session_id, it.session_id)) break w;
        } else blk: {
            try list.append(a, .{ .source = it.source, .session_id = it.session_id, .workspace_id = null, .surface_id = null, .item_count = 0, .pending_count = 0, .last_activity_ms = it.updated_at_ms, .latest = it });
            break :blk &list.items[list.items.len - 1];
        };
        ws.item_count += 1;
        if (it.status == .pending) ws.pending_count += 1;
        ws.last_activity_ms = @max(ws.last_activity_ms, it.updated_at_ms);
        ws.latest = it;
        if (it.workspace_id) |u| ws.workspace_id = u;
        if (it.surface_id) |u| ws.surface_id = u;
    }
    std.mem.sort(Workstream, list.items, {}, struct {
        fn lt(_: void, x: Workstream, y: Workstream) bool {
            return x.last_activity_ms > y.last_activity_ms;
        }
    }.lt);
    return list.toOwnedSlice(a);
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

// ---------------------------------------------------------------------------
// Result encoding

/// Writes `{"items":[...],"has_more":bool}`. `created_at` is Unix seconds
/// with millisecond precision; `options` lists the decision modes still
/// selectable (empty once the item is no longer pending).
pub fn writeListJson(w: *std.Io.Writer, page: Page) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{} };
    try s.beginObject();
    try s.objectField("items");
    try s.beginArray();
    for (page.items) |it| try writeListItem(&s, it);
    try s.endArray();
    try s.objectField("has_more");
    try s.write(page.has_more);
    try s.endObject();
}

fn writeSeconds(s: *std.json.Stringify, ms: i64) !void {
    const sign: []const u8 = if (ms < 0) "-" else "";
    const abs = @abs(ms);
    try s.print("{s}{d}.{d:0>3}", .{ sign, abs / 1000, abs % 1000 });
}

fn field(s: *std.json.Stringify, name: []const u8, v: anytype) !void {
    try s.objectField(name);
    try s.write(v);
}

fn optField(s: *std.json.Stringify, name: []const u8, v: anytype) !void {
    if (v) |x| try field(s, name, x);
}

pub fn writeListItem(s: *std.json.Stringify, it: *const Item) std.Io.Writer.Error!void {
    try s.beginObject();
    try field(s, "id", it.id);
    try field(s, "kind", it.kind.wire());
    try field(s, "status", it.status.wire());
    try field(s, "source", it.source);
    try field(s, "hook_event_name", it.hook_event_name);
    try field(s, "title", it.title);
    try field(s, "detail", it.detail);
    try s.objectField("created_at");
    try writeSeconds(s, it.created_at_ms);
    try optField(s, "request_id", it.request_id);
    try optField(s, "session_id", it.session_id);
    try optField(s, "workspace_id", it.workspace_id);
    try optField(s, "surface_id", it.surface_id);
    try optField(s, "tool_name", it.tool_name);
    try optField(s, "text", it.text);
    if (it.kind == .question) try field(s, "questions", it.questions);
    if (it.plan) |p| try field(s, "plan", p);
    if (it.kind == .todos) {
        try field(s, "todos", it.todos);
        var buf: [96]u8 = undefined;
        var bw: std.Io.Writer = .fixed(&buf);
        bw.print("{f}", .{model.TodoSummary.of(it.todos)}) catch {};
        try field(s, "todo_summary", bw.buffered());
    }
    if (it.tool_error) |e| try field(s, "is_error", e);
    if (it.kind.isDecision()) {
        try s.objectField("options");
        try s.beginArray();
        if (it.status == .pending) switch (it.kind) {
            .permission_request => inline for (std.meta.fields(model.PermissionMode)) |f| {
                const m: model.PermissionMode = @enumFromInt(f.value);
                if (it.permission_modes.has(m)) try s.write(m.wire());
            },
            .exit_plan => inline for (std.meta.fields(model.ExitPlanMode)) |f| {
                const m: model.ExitPlanMode = @enumFromInt(f.value);
                if (it.exit_plan_modes.has(m)) try s.write(m.wire());
            },
            .question => for (it.questions) |q| for (q.options) |o| try s.write(o.label),
            else => {},
        };
        try s.endArray();
    }
    if (it.resolution) |r| {
        try s.objectField("resolution");
        try s.beginObject();
        switch (r) {
            .permission => |m| try field(s, "mode", m.wire()),
            .exit_plan => |p| {
                try field(s, "mode", p.mode.wire());
                try optField(s, "feedback", p.feedback);
            },
            .question => |q| try field(s, "selections", q.selections),
            .reply => |t| try field(s, "text", t),
        }
        try field(s, "badge", r.badge());
        try s.endObject();
        if (it.resolved_at_ms) |ms| {
            try s.objectField("resolved_at");
            try writeSeconds(s, ms);
        }
    }
    try s.endObject();
}
