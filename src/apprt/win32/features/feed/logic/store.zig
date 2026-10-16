//! Bounded feed history and its JSONL audit format (`workstream.jsonl`).
//! Memory keeps the newest `capacity` items (2000, cmux's ring size), oldest
//! first. Every new item and every later mutation (resolution, timeout,
//! expiry) is appended to the file as one full-state line; loading collapses
//! lines by item id to the latest state. Compaction rewrites the file with
//! one line per item, keeping the newest `file_items`. File I/O itself is the
//! caller's (worker thread); this module only encodes, decodes and plans.

const std = @import("std");
const proto = @import("wmux_proto");
const model = @import("model.zig");
const Uuid = proto.uuid.Uuid;
const Item = model.Item;
const Allocator = std.mem.Allocator;

/// File name under the feed state directory.
pub const file_name = "workstream.jsonl";
/// Line format version written as `"v"`.
pub const format_version: u32 = 1;

pub const Retention = struct {
    /// Items held in memory (cmux: the most recent 2000).
    memory: usize = 2000,
    /// Items kept by compaction; older ones are dropped from the file.
    file_items: usize = 20_000,
    /// Compact when the file holds this many more lines than items kept...
    slack_lines: usize = 20_000,
    /// ...or grows past this many bytes.
    max_file_bytes: u64 = 64 * 1024 * 1024,

    /// Output budget for `compactJsonl`: half of `max_file_bytes`, so a
    /// compacted file never re-triggers `needsCompaction` on size.
    pub fn compactBytes(r: Retention) u64 {
        return r.max_file_bytes / 2;
    }
};

/// True when the appended file should be rewritten by
/// `compactJsonl(gpa, bytes, r.file_items, r.compactBytes())`.
pub fn needsCompaction(line_count: usize, file_bytes: u64, r: Retention) bool {
    return line_count > r.file_items + r.slack_lines or file_bytes > r.max_file_bytes;
}

pub const Store = struct {
    gpa: Allocator,
    capacity: usize,
    /// Oldest first.
    list: std.ArrayList(*Item) = .empty,
    by_id: std.AutoHashMapUnmanaged([16]u8, *Item) = .empty,

    pub fn init(gpa: Allocator, capacity: usize) Store {
        return .{ .gpa = gpa, .capacity = @max(capacity, 1) };
    }

    pub fn deinit(self: *Store) void {
        for (self.list.items) |it| it.destroy();
        self.list.deinit(self.gpa);
        self.by_id.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn len(self: *const Store) usize {
        return self.list.items.len;
    }

    /// Oldest first; invalidated by `add`/`clear`.
    pub fn items(self: *const Store) []const *Item {
        return self.list.items;
    }

    pub fn get(self: *const Store, id: Uuid) ?*Item {
        return self.by_id.get(id.b);
    }

    /// Newest item carrying `request_id`.
    pub fn findByRequestId(self: *const Store, request_id: []const u8) ?*Item {
        var i = self.list.items.len;
        while (i > 0) {
            i -= 1;
            const it = self.list.items[i];
            if (it.request_id) |r| if (std.mem.eql(u8, r, request_id)) return it;
        }
        return null;
    }

    /// Takes ownership of `item` (also on error). An item with the same id
    /// replaces the old one in place (keeps its position); otherwise it is
    /// appended and the oldest items beyond `capacity` are destroyed.
    /// Re-adding the stored item itself (after updating it in place) is a
    /// no-op. Returns the number of evicted items.
    pub fn add(self: *Store, item: *Item) Allocator.Error!usize {
        errdefer item.destroy();
        if (self.by_id.getPtr(item.id.b)) |slot| {
            const old = slot.*;
            if (old == item) return 0;
            for (self.list.items) |*p| if (p.* == old) {
                p.* = item;
                break;
            };
            slot.* = item;
            old.destroy();
            return 0;
        }
        try self.list.ensureUnusedCapacity(self.gpa, 1);
        try self.by_id.put(self.gpa, item.id.b, item);
        self.list.appendAssumeCapacity(item);
        return self.evict();
    }

    fn evict(self: *Store) usize {
        const over = self.list.items.len -| self.capacity;
        if (over == 0) return 0;
        for (self.list.items[0..over]) |it| {
            _ = self.by_id.remove(it.id.b);
            it.destroy();
        }
        const rest = self.list.items.len - over;
        std.mem.copyForwards(*Item, self.list.items[0..rest], self.list.items[over..]);
        self.list.shrinkRetainingCapacity(rest);
        return over;
    }

    /// `feed clear`.
    pub fn clear(self: *Store) void {
        for (self.list.items) |it| it.destroy();
        self.list.clearRetainingCapacity();
        self.by_id.clearRetainingCapacity();
    }

    /// Loads JSONL history (collapsed by id, newest `capacity` kept). Items
    /// still `pending` belong to hooks of an earlier run that can no longer
    /// be answered: the caller should `close(.expired, now)` them and append
    /// their rows.
    pub fn load(self: *Store, bytes: []const u8) Allocator.Error!LoadStats {
        var c = try collapse(self.gpa, bytes);
        var stats = c.stats;
        const owned = c.items.toOwnedSlice(self.gpa) catch |e| {
            c.deinit(self.gpa);
            return e;
        };
        defer self.gpa.free(owned);
        const keep = owned.len -| self.capacity;
        for (owned[0..keep]) |it| it.destroy();
        stats.evicted += keep;
        var i: usize = keep;
        while (i < owned.len) : (i += 1) {
            stats.evicted += self.add(owned[i]) catch |e| {
                for (owned[i + 1 ..]) |it| it.destroy();
                return e;
            };
        }
        return stats;
    }
};

// ---------------------------------------------------------------------------
// JSONL line format

const StoredResolution = struct {
    kind: []const u8,
    mode: ?[]const u8 = null,
    feedback: ?[]const u8 = null,
    selections: ?[]const []const u8 = null,
    text: ?[]const u8 = null,
};

const Stored = struct {
    v: u32 = format_version,
    id: []const u8,
    kind: []const u8,
    status: []const u8,
    source: []const u8 = "",
    hook_event_name: []const u8 = "",
    request_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    workspace_id: ?[]const u8 = null,
    surface_id: ?[]const u8 = null,
    pid: ?u32 = null,
    tool_name: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    title: []const u8 = "",
    detail: []const u8 = "",
    text: ?[]const u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64 = 0,
    resolved_at_ms: ?i64 = null,
    questions: []const model.Question = &.{},
    plan: ?model.Plan = null,
    todos: []const model.Todo = &.{},
    permission_modes: []const []const u8 = &.{},
    exit_plan_modes: []const []const u8 = &.{},
    tool_error: ?bool = null,
    tool_input_json: ?[]const u8 = null,
    resolution: ?StoredResolution = null,
};

/// Wire names of the enabled modes of a packed mode set.
fn modeNames(comptime Mode: type, set: anytype, buf: *[5][]const u8) []const []const u8 {
    var n: usize = 0;
    inline for (std.meta.fields(Mode)) |f| {
        const m: Mode = @enumFromInt(f.value);
        if (set.has(m)) {
            buf[n] = m.wire();
            n += 1;
        }
    }
    return buf[0..n];
}

/// Writes `item` as one JSON object without a trailing newline.
pub fn writeItemJson(w: *std.Io.Writer, item: *const Item) std.Io.Writer.Error!void {
    const id_text = item.id.toText();
    var ws_buf: [36]u8 = undefined;
    var sf_buf: [36]u8 = undefined;
    var pm: [5][]const u8 = undefined;
    var em: [5][]const u8 = undefined;
    const res: ?StoredResolution = if (item.resolution) |r| switch (r) {
        .permission => |m| .{ .kind = "permission", .mode = m.wire() },
        .exit_plan => |p| .{ .kind = "exitPlan", .mode = p.mode.wire(), .feedback = p.feedback },
        .question => |q| .{ .kind = "question", .selections = q.selections },
        .reply => |t| .{ .kind = "reply", .text = t },
    } else null;
    const s: Stored = .{
        .id = &id_text,
        .kind = item.kind.wire(),
        .status = item.status.wire(),
        .source = item.source,
        .hook_event_name = item.hook_event_name,
        .request_id = item.request_id,
        .session_id = item.session_id,
        .workspace_id = if (item.workspace_id) |u| blk: {
            ws_buf = u.toText();
            break :blk &ws_buf;
        } else null,
        .surface_id = if (item.surface_id) |u| blk: {
            sf_buf = u.toText();
            break :blk &sf_buf;
        } else null,
        .pid = item.pid,
        .tool_name = item.tool_name,
        .cwd = item.cwd,
        .title = item.title,
        .detail = item.detail,
        .text = item.text,
        .created_at_ms = item.created_at_ms,
        .updated_at_ms = item.updated_at_ms,
        .resolved_at_ms = item.resolved_at_ms,
        .questions = item.questions,
        .plan = item.plan,
        .todos = item.todos,
        .permission_modes = if (item.kind == .permission_request) modeNames(model.PermissionMode, item.permission_modes, &pm) else &.{},
        .exit_plan_modes = if (item.kind == .exit_plan) modeNames(model.ExitPlanMode, item.exit_plan_modes, &em) else &.{},
        .tool_error = item.tool_error,
        .tool_input_json = item.tool_input_json,
        .resolution = res,
    };
    try std.json.Stringify.value(s, .{ .emit_null_optional_fields = false }, w);
}

/// One JSONL line (with `\n`), heap-owned.
pub fn encodeLine(gpa: Allocator, item: *const Item) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    writeItemJson(&aw.writer, item) catch return error.OutOfMemory;
    aw.writer.writeByte('\n') catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

pub const DecodeError = error{ OutOfMemory, InvalidRecord };

/// Parses one JSONL line (surrounding whitespace ignored).
pub fn decodeLine(gpa: Allocator, line: []const u8) DecodeError!*Item {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidRecord;
    const parsed = std.json.parseFromSlice(Stored, gpa, trimmed, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRecord,
    };
    defer parsed.deinit();
    const s = parsed.value;
    if (s.v > format_version) return error.InvalidRecord;
    const id = Uuid.parse(s.id) catch return error.InvalidRecord;
    const kind = model.Kind.parse(s.kind) orelse return error.InvalidRecord;
    const status = model.Status.parse(s.status) orelse return error.InvalidRecord;

    var sel_buf: std.ArrayList([]const u8) = .empty;
    defer sel_buf.deinit(gpa);
    const resolution: ?model.Resolution = if (s.resolution) |r| blk: {
        if (std.mem.eql(u8, r.kind, "permission")) {
            break :blk .{ .permission = model.PermissionMode.parse(r.mode orelse "") orelse return error.InvalidRecord };
        } else if (std.mem.eql(u8, r.kind, "exitPlan")) {
            break :blk .{ .exit_plan = .{ .mode = model.ExitPlanMode.parse(r.mode orelse "") orelse return error.InvalidRecord, .feedback = r.feedback } };
        } else if (std.mem.eql(u8, r.kind, "question")) {
            break :blk .{ .question = .{ .selections = r.selections orelse &.{} } };
        } else if (std.mem.eql(u8, r.kind, "reply")) {
            break :blk .{ .reply = r.text orelse "" };
        } else return error.InvalidRecord;
    } else null;
    if (resolution) |r| if (r.answers() != kind) return error.InvalidRecord;

    var pmodes: model.PermissionModes = .{ .once = false, .deny = false };
    for (s.permission_modes) |n| switch (model.PermissionMode.parse(n) orelse continue) {
        inline else => |m| @field(pmodes, @tagName(m)) = true,
    };
    if (s.permission_modes.len == 0) pmodes = .{};
    var emodes: model.ExitPlanModes = .{ .manual = false, .deny = false };
    for (s.exit_plan_modes) |n| switch (model.ExitPlanMode.parse(n) orelse continue) {
        inline else => |m| @field(emodes, @tagName(m)) = true,
    };
    if (s.exit_plan_modes.len == 0) emodes = .{};

    // Borrowing view over the parsed tree; `clone` deep-copies it.
    var view: Item = .{
        .arena = undefined,
        .id = id,
        .kind = kind,
        .status = status,
        .source = s.source,
        .hook_event_name = s.hook_event_name,
        .request_id = s.request_id,
        .session_id = s.session_id,
        .workspace_id = if (s.workspace_id) |t| Uuid.parse(t) catch null else null,
        .surface_id = if (s.surface_id) |t| Uuid.parse(t) catch null else null,
        .pid = s.pid,
        .tool_name = s.tool_name,
        .cwd = s.cwd,
        .title = s.title,
        .detail = s.detail,
        .text = s.text,
        .created_at_ms = s.created_at_ms,
        .updated_at_ms = if (s.updated_at_ms == 0) s.created_at_ms else s.updated_at_ms,
        .resolved_at_ms = s.resolved_at_ms,
        .questions = s.questions,
        .plan = s.plan,
        .todos = s.todos,
        .permission_modes = pmodes,
        .exit_plan_modes = emodes,
        .tool_error = s.tool_error,
        .tool_input_json = s.tool_input_json,
        .resolution = resolution,
    };
    return view.clone(gpa);
}

pub const LoadStats = struct {
    /// Well-formed lines read.
    lines: usize = 0,
    /// Malformed lines skipped (torn tail write, garbage, future version).
    skipped: usize = 0,
    /// Distinct items after collapsing by id.
    distinct: usize = 0,
    /// Items dropped by the retention bound.
    evicted: usize = 0,
};

pub const Collapsed = struct {
    /// Latest state per id, ordered by (created_at_ms, first appearance).
    items: std.ArrayList(*Item) = .empty,
    stats: LoadStats = .{},

    pub fn deinit(self: *Collapsed, gpa: Allocator) void {
        for (self.items.items) |it| it.destroy();
        self.items.deinit(gpa);
    }
};

/// Parses JSONL and keeps the latest line per id. Malformed lines are
/// counted and skipped; a later line for an id replaces the earlier state
/// but keeps the first appearance as its position.
pub fn collapse(gpa: Allocator, bytes: []const u8) Allocator.Error!Collapsed {
    var out: Collapsed = .{};
    errdefer out.deinit(gpa);
    var index: std.AutoHashMapUnmanaged([16]u8, usize) = .empty;
    defer index.deinit(gpa);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        const item = decodeLine(gpa, line) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidRecord => {
                out.stats.skipped += 1;
                continue;
            },
        };
        out.stats.lines += 1;
        const gop = index.getOrPut(gpa, item.id.b) catch |e| {
            item.destroy();
            return e;
        };
        if (gop.found_existing) {
            const slot = &out.items.items[gop.value_ptr.*];
            slot.*.destroy();
            slot.* = item;
        } else {
            out.items.append(gpa, item) catch |e| {
                _ = index.remove(item.id.b);
                item.destroy();
                return e;
            };
            gop.value_ptr.* = out.items.items.len - 1;
        }
    }
    std.mem.sort(*Item, out.items.items, {}, struct {
        fn lt(_: void, a: *Item, b: *Item) bool {
            return a.created_at_ms < b.created_at_ms;
        }
    }.lt);
    out.stats.distinct = out.items.items.len;
    return out;
}

/// Rewrites JSONL as one line per item (latest state), keeping the newest
/// items: at most `keep` of them in at most `max_bytes` of output (a
/// contiguous newest run; an item whose line does not fit ends it). Pass
/// `Retention.compactBytes()` so the result cannot re-trigger compaction on
/// size. Malformed lines are dropped. Returns heap-owned bytes.
pub fn compactJsonl(gpa: Allocator, bytes: []const u8, keep: usize, max_bytes: u64) Allocator.Error![]u8 {
    var c = try collapse(gpa, bytes);
    defer c.deinit(gpa);
    const all = c.items.items;
    var start = all.len;
    var total: u64 = 0;
    var scratch: [256]u8 = undefined;
    while (start > 0 and all.len - start < keep) {
        var counter: std.Io.Writer.Discarding = .init(&scratch);
        // A discarding writer never fails.
        writeItemJson(&counter.writer, all[start - 1]) catch unreachable;
        const line_bytes = counter.fullCount() + 1;
        if (line_bytes > max_bytes - total) break;
        total += line_bytes;
        start -= 1;
    }
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    for (all[start..]) |it| {
        writeItemJson(&aw.writer, it) catch return error.OutOfMemory;
        aw.writer.writeByte('\n') catch return error.OutOfMemory;
    }
    return aw.toOwnedSlice();
}
