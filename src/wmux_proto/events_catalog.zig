//! COMPLETE event catalog: cmux events plus `wmux.*` (ADR-3.10).
//! [shared-appendable, merge=union: one sorted line per event]
//!
//! Every event name the cmux events stream documents, with its subscription
//! category, payload keys and types, privacy classification (what the stream
//! and `events.jsonl` redact or omit), and whether it is a model lifecycle
//! event or a socket-sourced command effect. `model/events.zig` builds its
//! `Kind` from this table; `rpc/stream.zig` uses it for name/category filters.
//!
//! Names ending in `.*` are families: the producer supplies the suffix
//! (`agent.hook.<HookEventName>`). Payloads are open: unknown keys are allowed;
//! listed keys are type-checked and listed required keys must be present.
//!
//! To add an event: append ONE line to `entries`, keeping byte order by name.

const std = @import("std");

/// Coarse subscription group (`events.stream {categories}`, `cmux events --category`).
pub const Category = enum {
    agent,
    app,
    browser,
    config,
    feed,
    notification,
    pane,
    sidebar,
    surface,
    terminal,
    window,
    workspace,
    /// wmux-only events; kept out of cmux categories so cmux-filtered streams match cmux.
    wmux,

    pub fn parse(s: []const u8) ?Category {
        return std.meta.stringToEnum(Category, s);
    }

    pub fn name(self: Category) []const u8 {
        return @tagName(self);
    }
};

/// Who emits the event.
pub const Origin = enum {
    /// Emitted only by `model/ops/*` mutators, so UI, shortcut, CLI, startup and
    /// restore paths each emit exactly once (source `window.lifecycle` / `workspace.lifecycle`).
    lifecycle,
    /// Emitted by `rpc/dispatch.zig` after a successful reply, for command effects
    /// with no authoritative model event (source `socket.v2` / `socket.v1`).
    socket,
    /// Emitted by a feature store for its own domain (notifications, sidebar, feed, agents).
    store,
    /// Emitted for an external agent; `source` is the agent name (`claude`, `codex`, ...).
    agent,
};

/// Where the name comes from.
pub const Provenance = enum {
    /// cmux `docs/events.md`.
    docs,
    /// Named by the cmux inventory as present in cmux sources; payload undocumented.
    cmux_source,
    /// wmux-only (`wmux.*`, G2).
    wmux,
};

pub const ValueType = enum { any, string, uuid, integer, number, boolean, object, array, string_array, uuid_array };

/// Per-key privacy (cli-events-privacy).
pub const Privacy = enum {
    /// Operational data (ids, counts, names of hooks/tools, decisions).
    plain,
    /// Local text carried as-is but local-sensitive (forward only with explicit opt-in).
    sensitive,
    /// Text replaced by `null`; the payload carries `<key>_length` and lists the key in `redacted_fields`.
    redacted,
    /// Never present in the stream or the log.
    omitted,
};

/// Event-level privacy classification (the strongest key classification).
pub const EventPrivacy = enum { none, sensitive, redacted };

pub const Key = struct {
    name: []const u8,
    value_type: ValueType,
    required: bool = true,
    nullable: bool = false,
    privacy: Privacy = .plain,
    min: ?i64 = null,
    max: ?i64 = null,
    one_of: []const []const u8 = &.{},
};

pub const Entry = struct {
    name: []const u8,
    category: Category,
    origin: Origin,
    /// Default envelope `source`; null when the producer supplies it (agent name).
    source: ?[]const u8,
    provenance: Provenance = .docs,
    payload: []const Key = &.{},

    pub fn isFamily(self: *const Entry) bool {
        return std.mem.endsWith(u8, self.name, ".*");
    }

    /// `agent.hook.` for `agent.hook.*`; the full name otherwise.
    pub fn familyPrefix(self: *const Entry) []const u8 {
        return if (self.isFamily()) self.name[0 .. self.name.len - 1] else self.name;
    }

    pub fn isLifecycle(self: *const Entry) bool {
        return self.origin == .lifecycle;
    }

    pub fn isSocketSourced(self: *const Entry) bool {
        return self.origin == .socket;
    }

    pub fn privacy(self: *const Entry) EventPrivacy {
        var p: EventPrivacy = .none;
        for (self.payload) |k| switch (k.privacy) {
            .plain => {},
            .sensitive => if (p == .none) {
                p = .sensitive;
            },
            .redacted, .omitted => p = .redacted,
        };
        return p;
    }

    pub fn findKey(self: *const Entry, key: []const u8) ?*const Key {
        for (self.payload) |*k| if (std.mem.eql(u8, k.name, key)) return k;
        return null;
    }
};

// Key constructors (keep catalog lines short).
fn req(n: []const u8, t: ValueType) Key {
    return .{ .name = n, .value_type = t };
}
fn reqN(n: []const u8, t: ValueType) Key {
    return .{ .name = n, .value_type = t, .nullable = true };
}
fn opt(n: []const u8, t: ValueType) Key {
    return .{ .name = n, .value_type = t, .required = false, .nullable = true };
}
fn count(n: []const u8) Key {
    return .{ .name = n, .value_type = .integer, .min = 0 };
}
fn optCount(n: []const u8) Key {
    return .{ .name = n, .value_type = .integer, .required = false, .min = 0 };
}
fn sensitive(n: []const u8) Key {
    return .{ .name = n, .value_type = .string, .nullable = true, .privacy = .sensitive };
}
fn redacted(n: []const u8) Key {
    return .{ .name = n, .value_type = .string, .required = false, .nullable = true, .privacy = .redacted };
}
fn omitted(n: []const u8) Key {
    return .{ .name = n, .value_type = .any, .required = false, .privacy = .omitted };
}

/// Largest accepted `prompt_length` (the hook CLI's 1 MiB input ceiling).
pub const max_prompt_length: i64 = 1_048_576;

// Shared payload key sets.
const window_lifecycle = [_]Key{ req("window_id", .uuid), reqN("workspace_id", .uuid), count("workspace_count"), reqN("selected_workspace_index", .integer), req("is_key_window", .boolean), req("is_main_window", .boolean), req("origin", .string) };
const workspace_selected = [_]Key{ reqN("previous_workspace_id", .uuid), count("index"), count("tab_count") };
const workspace_reordered = [_]Key{ req("workspace_ids", .uuid_array), req("moved_workspace_ids", .uuid_array), req("pinned_workspace_ids", .uuid_array), count("count") };
const workspace_prompt = [_]Key{ req("workspace_id", .uuid), redacted("message"), sensitive("message_preview"), count("message_length"), req("redacted_fields", .string_array) };
const surface_selected = [_]Key{ reqN("previous_surface_id", .uuid), reqN("pane_id", .uuid), req("kind", .string), req("focused", .boolean) };
const surface_input = [_]Key{ redacted("text"), count("text_length"), req("redacted_fields", .string_array) };
const pane_focused = [_]Key{reqN("selected_surface_id", .uuid)};
const program_status_events = [_][]const u8{ "report", "clear", "prompt_start", "transient_drop", "dismissed", "removed", "adopted" };
const program_status = [_]Key{ .{ .name = "event", .value_type = .string, .one_of = &program_status_events }, reqN("id", .string), reqN("record", .object), req("records", .array), count("records_total"), req("snapshot_id", .string), count("snapshot_index"), .{ .name = "snapshot_count", .value_type = .integer, .min = 1 }, omitted("text"), omitted("provider") };
const notification_text = [_]Key{ redacted("title"), redacted("subtitle"), redacted("body"), optCount("title_length"), optCount("subtitle_length"), optCount("body_length"), opt("redacted_fields", .string_array) };
const notification_created = [_]Key{ req("notification_id", .uuid), redacted("title"), redacted("subtitle"), redacted("body"), count("title_length"), count("subtitle_length"), count("body_length"), req("redacted_fields", .string_array), req("delivery", .string) };
const notification_ref = [_]Key{opt("notification_id", .uuid)};
const agent_hook = [_]Key{ opt("session_id", .string), req("hook_event_name", .string), req("_source", .string), opt("surface_id", .uuid), opt("tool_name", .string), opt("_opencode_request_id", .string), req("phase", .string), .{ .name = "prompt_length", .value_type = .integer, .required = false, .min = 0, .max = max_prompt_length }, optCount("tool_input_length"), omitted("prompt"), omitted("tool_input"), omitted("context"), omitted("extra_fields") };
const feed_completed = agent_hook ++ [_]Key{req("result", .object)};
const feed_resolved = [_]Key{ omitted("prompt"), omitted("tool_input"), omitted("context"), omitted("extra_fields") };
const agent_message_queued = [_]Key{ req("id", .string), reqN("thread_id", .string), reqN("sender_name", .string), reqN("sender_surface_id", .uuid), count("body_length"), omitted("body") };
const browser_input = [_]Key{ redacted("value"), count("value_length"), req("redacted_fields", .string_array) };

/// The catalog: one line per event, sorted by name (byte order). merge=union.
pub const entries = [_]Entry{
    .{ .name = "agent.auto_resume.scheduled", .category = .agent, .origin = .store, .source = "agents.store", .provenance = .cmux_source },
    .{ .name = "agent.auto_resume.sent", .category = .agent, .origin = .store, .source = "agents.store", .provenance = .cmux_source },
    .{ .name = "agent.hook.*", .category = .agent, .origin = .agent, .source = null, .payload = &agent_hook },
    .{ .name = "agent.journal.*", .category = .agent, .origin = .store, .source = "agents.store", .provenance = .cmux_source },
    .{ .name = "agent.message.delivered", .category = .agent, .origin = .store, .source = "agent_messages.store", .payload = &.{req("delivered_via", .string)} },
    .{ .name = "agent.message.failed", .category = .agent, .origin = .store, .source = "agent_messages.store", .provenance = .cmux_source },
    .{ .name = "agent.message.queued", .category = .agent, .origin = .store, .source = "agent_messages.store", .payload = &agent_message_queued },
    .{ .name = "agent.message.read", .category = .agent, .origin = .store, .source = "agent_messages.store" },
    .{ .name = "agent.needs_input", .category = .agent, .origin = .store, .source = "agents.store", .provenance = .cmux_source },
    .{ .name = "agent.notification.decision", .category = .agent, .origin = .store, .source = "agents.store", .provenance = .cmux_source },
    .{ .name = "app.focus_override.changed", .category = .app, .origin = .socket, .source = "socket.v2" },
    .{ .name = "app.simulated_active", .category = .app, .origin = .socket, .source = "socket.v2" },
    .{ .name = "browser.input", .category = .browser, .origin = .socket, .source = "socket.v2", .payload = &browser_input },
    .{ .name = "browser.interaction", .category = .browser, .origin = .socket, .source = "socket.v2" },
    .{ .name = "browser.navigation", .category = .browser, .origin = .socket, .source = "socket.v2" },
    .{ .name = "config.reloaded", .category = .config, .origin = .socket, .source = "socket.v1" },
    .{ .name = "feed.item.completed", .category = .feed, .origin = .store, .source = "feed.store", .payload = &feed_completed },
    .{ .name = "feed.item.received", .category = .feed, .origin = .store, .source = "feed.store", .payload = &agent_hook },
    .{ .name = "feed.item.resolved", .category = .feed, .origin = .store, .source = "feed.store", .payload = &feed_resolved },
    .{ .name = "notification.clear_requested", .category = .notification, .origin = .socket, .source = "socket.v2" },
    .{ .name = "notification.cleared", .category = .notification, .origin = .store, .source = "notification.store" },
    .{ .name = "notification.created", .category = .notification, .origin = .store, .source = "notification.store", .payload = &notification_created },
    .{ .name = "notification.dismiss_requested", .category = .notification, .origin = .socket, .source = "socket.v2", .payload = &notification_ref },
    .{ .name = "notification.jump_to_unread_requested", .category = .notification, .origin = .socket, .source = "socket.v2" },
    .{ .name = "notification.mark_read_requested", .category = .notification, .origin = .socket, .source = "socket.v2", .payload = &notification_ref },
    .{ .name = "notification.open_requested", .category = .notification, .origin = .socket, .source = "socket.v2", .payload = &notification_ref },
    .{ .name = "notification.read", .category = .notification, .origin = .store, .source = "notification.store", .payload = &notification_ref },
    .{ .name = "notification.removed", .category = .notification, .origin = .store, .source = "notification.store", .payload = &notification_ref },
    .{ .name = "notification.requested", .category = .notification, .origin = .socket, .source = "socket.v2", .payload = &notification_text },
    .{ .name = "pane.broken", .category = .pane, .origin = .lifecycle, .source = "workspace.lifecycle" },
    .{ .name = "pane.closed", .category = .pane, .origin = .lifecycle, .source = "workspace.lifecycle" },
    .{ .name = "pane.created", .category = .pane, .origin = .lifecycle, .source = "workspace.lifecycle" },
    .{ .name = "pane.focused", .category = .pane, .origin = .lifecycle, .source = "workspace.lifecycle", .payload = &pane_focused },
    .{ .name = "pane.joined", .category = .pane, .origin = .lifecycle, .source = "workspace.lifecycle" },
    .{ .name = "pane.resize_requested", .category = .pane, .origin = .socket, .source = "socket.v2" },
    .{ .name = "pane.resized", .category = .pane, .origin = .lifecycle, .source = "workspace.lifecycle" },
    .{ .name = "pane.swapped", .category = .pane, .origin = .lifecycle, .source = "workspace.lifecycle" },
    .{ .name = "program_status.changed", .category = .terminal, .origin = .store, .source = "program_status.store", .payload = &program_status },
    .{ .name = "sidebar.log.appended", .category = .sidebar, .origin = .store, .source = "sidebar.store" },
    .{ .name = "sidebar.log.cleared", .category = .sidebar, .origin = .store, .source = "sidebar.store" },
    .{ .name = "sidebar.metadata.cleared", .category = .sidebar, .origin = .store, .source = "sidebar.store" },
    .{ .name = "sidebar.metadata.updated", .category = .sidebar, .origin = .store, .source = "sidebar.store" },
    .{ .name = "sidebar.progress.cleared", .category = .sidebar, .origin = .store, .source = "sidebar.store" },
    .{ .name = "sidebar.progress.updated", .category = .sidebar, .origin = .store, .source = "sidebar.store" },
    .{ .name = "sidebar.reset", .category = .sidebar, .origin = .store, .source = "sidebar.store" },
    .{ .name = "surface.action", .category = .surface, .origin = .socket, .source = "socket.v2" },
    .{ .name = "surface.closed", .category = .surface, .origin = .lifecycle, .source = "workspace.lifecycle" },
    .{ .name = "surface.created", .category = .surface, .origin = .lifecycle, .source = "workspace.lifecycle" },
    .{ .name = "surface.focused", .category = .surface, .origin = .lifecycle, .source = "workspace.lifecycle" },
    .{ .name = "surface.input_sent", .category = .surface, .origin = .socket, .source = "socket.v2", .payload = &surface_input },
    .{ .name = "surface.jump_to_last_prompt_requested", .category = .surface, .origin = .socket, .source = "socket.v2" },
    .{ .name = "surface.key_sent", .category = .surface, .origin = .socket, .source = "socket.v2", .payload = &.{opt("key", .string)} },
    .{ .name = "surface.moved", .category = .surface, .origin = .lifecycle, .source = "workspace.lifecycle" },
    .{ .name = "surface.reordered", .category = .surface, .origin = .lifecycle, .source = "workspace.lifecycle" },
    .{ .name = "surface.selected", .category = .surface, .origin = .lifecycle, .source = "workspace.lifecycle", .payload = &surface_selected },
    .{ .name = "window.closed", .category = .window, .origin = .lifecycle, .source = "window.lifecycle", .payload = &window_lifecycle },
    .{ .name = "window.created", .category = .window, .origin = .lifecycle, .source = "window.lifecycle", .payload = &window_lifecycle },
    .{ .name = "window.focused", .category = .window, .origin = .lifecycle, .source = "window.lifecycle", .payload = &window_lifecycle },
    .{ .name = "window.keyed", .category = .window, .origin = .lifecycle, .source = "window.lifecycle", .payload = &window_lifecycle },
    .{ .name = "window.unkeyed", .category = .window, .origin = .lifecycle, .source = "window.lifecycle", .payload = &window_lifecycle },
    .{ .name = "wmux.agent.session.changed", .category = .wmux, .origin = .store, .source = "agents.store", .provenance = .wmux, .payload = &.{ req("state", .string), count("version"), opt("session_id", .string), opt("agent", .string) } },
    .{ .name = "wmux.attention.changed", .category = .wmux, .origin = .store, .source = "notification.store", .provenance = .wmux, .payload = &.{req("on", .boolean)} },
    .{ .name = "wmux.notification.unread_count.changed", .category = .wmux, .origin = .store, .source = "notification.store", .provenance = .wmux, .payload = &.{ count("unread_count"), optCount("previous_unread_count") } },
    .{ .name = "wmux.right_sidebar.changed", .category = .wmux, .origin = .store, .source = "right_sidebar.host", .provenance = .wmux, .payload = &.{ req("visible", .boolean), opt("mode", .string) } },
    .{ .name = "wmux.session.saved", .category = .wmux, .origin = .store, .source = "session.store", .provenance = .wmux, .payload = &.{opt("reason", .string)} },
    .{ .name = "wmux.settings.changed", .category = .wmux, .origin = .store, .source = "settings.watcher", .provenance = .wmux, .payload = &.{opt("changed_keys", .string_array)} },
    .{ .name = "wmux.sync_input.changed", .category = .wmux, .origin = .store, .source = "sync_input.store", .provenance = .wmux, .payload = &.{req("on", .boolean)} },
    .{ .name = "wmux.workspace_group.closed", .category = .wmux, .origin = .lifecycle, .source = "workspace.lifecycle", .provenance = .wmux, .payload = &.{req("group_id", .uuid)} },
    .{ .name = "wmux.workspace_group.created", .category = .wmux, .origin = .lifecycle, .source = "workspace.lifecycle", .provenance = .wmux, .payload = &.{req("group_id", .uuid)} },
    .{ .name = "wmux.workspace_group.renamed", .category = .wmux, .origin = .lifecycle, .source = "workspace.lifecycle", .provenance = .wmux, .payload = &.{req("group_id", .uuid)} },
    .{ .name = "workspace.action", .category = .workspace, .origin = .socket, .source = "socket.v2" },
    .{ .name = "workspace.closed", .category = .workspace, .origin = .lifecycle, .source = "workspace.lifecycle" },
    .{ .name = "workspace.created", .category = .workspace, .origin = .lifecycle, .source = "workspace.lifecycle" },
    .{ .name = "workspace.moved", .category = .workspace, .origin = .lifecycle, .source = "workspace.lifecycle" },
    .{ .name = "workspace.prompt.submitted", .category = .workspace, .origin = .store, .source = "agents.store", .payload = &workspace_prompt },
    .{ .name = "workspace.renamed", .category = .workspace, .origin = .lifecycle, .source = "workspace.lifecycle" },
    .{ .name = "workspace.reordered", .category = .workspace, .origin = .lifecycle, .source = "workspace.lifecycle", .payload = &workspace_reordered },
    .{ .name = "workspace.selected", .category = .workspace, .origin = .lifecycle, .source = "workspace.lifecycle", .payload = &workspace_selected },
};

// ---------------------------------------------------------------------------
// Comptime checks and derived tables.

/// Longest accepted family suffix (`agent.hook.<HookEventName>`).
pub const max_family_suffix_len = 128;

fn checkCatalog() void {
    @setEvalBranchQuota(1_000_000);
    for (entries, 0..) |e, i| {
        if (!isValidName(e.name, e.isFamily())) @compileError("events_catalog: malformed event name: " ++ e.name);
        if (std.mem.startsWith(u8, e.name, "wmux.") != (e.provenance == .wmux))
            @compileError("events_catalog: wmux.* names and provenance .wmux must match: " ++ e.name);
        if ((e.category == .wmux) != (e.provenance == .wmux))
            @compileError("events_catalog: category .wmux is reserved for wmux.* events: " ++ e.name);
        if (i > 0) switch (std.mem.order(u8, entries[i - 1].name, e.name)) {
            .lt => {},
            .eq => @compileError("events_catalog: duplicate event name: " ++ e.name),
            .gt => @compileError("events_catalog: entries not sorted at: " ++ e.name),
        };
        for (e.payload, 0..) |k, j| {
            for (e.payload[0..j]) |prev| {
                if (std.mem.eql(u8, prev.name, k.name)) @compileError("events_catalog: duplicate payload key " ++ k.name ++ " in " ++ e.name);
            }
            if (k.privacy == .redacted) {
                if (!k.nullable or k.required) @compileError("events_catalog: redacted key must be optional and nullable: " ++ k.name);
                var has_len = false;
                for (e.payload) |other| {
                    if (std.mem.eql(u8, other.name, k.name ++ "_length")) has_len = true;
                }
                if (!has_len) @compileError("events_catalog: redacted key needs a _length companion: " ++ k.name ++ " in " ++ e.name);
            }
            if (k.privacy == .omitted and k.required) @compileError("events_catalog: omitted key cannot be required: " ++ k.name);
        }
    }
}

comptime {
    checkCatalog();
}

/// One tag per catalog entry, in catalog order; tag names are event names
/// (`.@"window.created"`, `.@"agent.hook.*"`). `@intFromEnum(k)` indexes `entries`.
pub const Kind = blk: {
    @setEvalBranchQuota(1_000_000);
    var fields: [entries.len]std.builtin.Type.EnumField = undefined;
    for (entries, 0..) |e, i| fields[i] = .{ .name = e.name ++ "", .value = i };
    break :blk @Type(.{ .@"enum" = .{ .tag_type = u16, .fields = &fields, .decls = &.{}, .is_exhaustive = true } });
};

pub fn entry(kind: Kind) *const Entry {
    return &entries[@intFromEnum(kind)];
}

const exact_map = blk: {
    @setEvalBranchQuota(1_000_000);
    var n: usize = 0;
    for (entries) |e| {
        if (!e.isFamily()) n += 1;
    }
    var kvs: [n]struct { []const u8, Kind } = undefined;
    var i: usize = 0;
    for (entries, 0..) |e, idx| {
        if (e.isFamily()) continue;
        kvs[i] = .{ e.name, @enumFromInt(idx) };
        i += 1;
    }
    break :blk std.StaticStringMap(Kind).initComptime(kvs);
};

const family_kinds = blk: {
    @setEvalBranchQuota(1_000_000);
    var n: usize = 0;
    for (entries) |e| {
        if (e.isFamily()) n += 1;
    }
    var out: [n]Kind = undefined;
    var i: usize = 0;
    for (entries, 0..) |e, idx| {
        if (!e.isFamily()) continue;
        out[i] = @enumFromInt(idx);
        i += 1;
    }
    break :blk out;
};

/// Kinds of every family entry (`agent.hook.*`, ...).
pub const families: []const Kind = &family_kinds;

const category_tables = blk: {
    @setEvalBranchQuota(1_000_000);
    const cats = std.meta.fields(Category);
    var tables: [cats.len][]const Kind = undefined;
    for (cats, 0..) |c, ci| {
        var n: usize = 0;
        for (entries) |e| {
            if (@intFromEnum(e.category) == c.value) n += 1;
        }
        var list: [n]Kind = undefined;
        var i: usize = 0;
        for (entries, 0..) |e, idx| {
            if (@intFromEnum(e.category) != c.value) continue;
            list[i] = @enumFromInt(idx);
            i += 1;
        }
        const final = list;
        tables[ci] = &final;
    }
    break :blk tables;
};

/// All kinds in a category, sorted by name. Usable at comptime and runtime.
pub fn byCategory(category: Category) []const Kind {
    return category_tables[@intFromEnum(category)];
}

/// Resolves a concrete event name: exact names first, then families
/// (`agent.hook.Stop` → `.@"agent.hook.*"`). Returns null for unknown or malformed names.
pub fn kindOf(name: []const u8) ?Kind {
    if (exact_map.get(name)) |k| return k;
    for (families) |k| {
        const prefix = entry(k).familyPrefix();
        if (name.len > prefix.len and std.mem.startsWith(u8, name, prefix)) {
            const suffix = name[prefix.len..];
            if (suffix.len <= max_family_suffix_len and isValidSegments(suffix)) return k;
        }
    }
    return null;
}

/// Catalog entry for a concrete event name, or null.
pub fn lookup(name: []const u8) ?*const Entry {
    return if (kindOf(name)) |k| entry(k) else null;
}

/// Comptime lookup: compile error when the name is not in the catalog.
pub fn kindComptime(comptime name: []const u8) Kind {
    return comptime kindOf(name) orelse @compileError("events_catalog: unknown event name: " ++ name);
}

/// Keys of `kind` whose text is redacted to null (the `redacted_fields` value), in catalog order.
pub fn redactedFields(comptime kind: Kind) []const []const u8 {
    return comptime blk: {
        const e = entry(kind);
        var n: usize = 0;
        for (e.payload) |k| {
            if (k.privacy == .redacted) n += 1;
        }
        var out: [n][]const u8 = undefined;
        var i: usize = 0;
        for (e.payload) |k| {
            if (k.privacy != .redacted) continue;
            out[i] = k.name;
            i += 1;
        }
        const final = out;
        break :blk &final;
    };
}

fn isSegmentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Dot-separated, non-empty segments of [A-Za-z0-9_].
fn isValidSegments(s: []const u8) bool {
    if (s.len == 0) return false;
    var seg_len: usize = 0;
    for (s) |c| {
        if (c == '.') {
            if (seg_len == 0) return false;
            seg_len = 0;
        } else if (isSegmentChar(c)) {
            seg_len += 1;
        } else return false;
    }
    return seg_len > 0;
}

fn isValidName(name: []const u8, family: bool) bool {
    if (family) {
        if (name.len < 3 or !std.mem.endsWith(u8, name, ".*")) return false;
        return isValidSegments(name[0 .. name.len - 2]);
    }
    return std.mem.indexOfScalar(u8, name, '.') != null and isValidSegments(name);
}

// ---------------------------------------------------------------------------
// Payload validation.

pub const Reason = enum {
    not_an_object,
    missing_required_key,
    wrong_type,
    null_not_allowed,
    out_of_range,
    value_not_allowed,
    redacted_value_present,
    omitted_key_present,
};

pub const Violation = struct {
    reason: Reason,
    /// Offending key; empty for `not_an_object`.
    key: []const u8,
};

/// First violation of `e`'s payload contract, or null when the payload is valid.
/// A payload with `payload_truncated: true` (frame cap replacement) skips the
/// required/type checks but still must not carry redacted or omitted text.
pub fn checkPayload(e: *const Entry, payload: std.json.Value) ?Violation {
    const obj = switch (payload) {
        .object => |o| o,
        else => return .{ .reason = .not_an_object, .key = "" },
    };
    const truncated = if (obj.get("payload_truncated")) |v| v == .bool and v.bool else false;
    for (e.payload) |*k| {
        const v = obj.get(k.name) orelse {
            if (k.required and !truncated) return .{ .reason = .missing_required_key, .key = k.name };
            continue;
        };
        switch (k.privacy) {
            .omitted => return .{ .reason = .omitted_key_present, .key = k.name },
            .redacted => {
                if (v != .null) return .{ .reason = .redacted_value_present, .key = k.name };
                continue;
            },
            .plain, .sensitive => {},
        }
        if (truncated) continue;
        if (checkValue(k, v)) |reason| return .{ .reason = reason, .key = k.name };
    }
    return null;
}

pub fn validatePayload(e: *const Entry, payload: std.json.Value) error{InvalidPayload}!void {
    if (checkPayload(e, payload) != null) return error.InvalidPayload;
}

/// True when every required key of `e` is present in `obj` (types not checked).
pub fn hasRequiredKeys(e: *const Entry, obj: std.json.ObjectMap) bool {
    for (e.payload) |k| {
        if (k.required and !obj.contains(k.name)) return false;
    }
    return true;
}

pub const ValidateJsonError = error{ UnknownEvent, InvalidPayload } || std.json.ParseError(std.json.Scanner);

/// Parses `payload_json` and validates it against the catalog entry for `name`.
pub fn validatePayloadJson(gpa: std.mem.Allocator, name: []const u8, payload_json: []const u8) ValidateJsonError!void {
    const e = lookup(name) orelse return error.UnknownEvent;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, payload_json, .{});
    defer parsed.deinit();
    try validatePayload(e, parsed.value);
}

fn checkValue(k: *const Key, v: std.json.Value) ?Reason {
    if (v == .null) return if (k.nullable) null else .null_not_allowed;
    switch (k.value_type) {
        .any => {},
        .string => if (v != .string) return .wrong_type,
        .uuid => {
            if (v != .string) return .wrong_type;
            if (!isUuidText(v.string)) return .value_not_allowed;
        },
        .integer => {
            const n = integerValue(v) orelse return .wrong_type;
            const lo = k.min orelse std.math.minInt(i64);
            const hi = k.max orelse std.math.maxInt(i64);
            switch (n) {
                .int => |i| if (i < lo or i > hi) return .out_of_range,
                .huge => return .out_of_range,
            }
        },
        .number => switch (v) {
            .integer, .float, .number_string => {},
            else => return .wrong_type,
        },
        .boolean => if (v != .bool) return .wrong_type,
        .object => if (v != .object) return .wrong_type,
        .array => if (v != .array) return .wrong_type,
        .string_array, .uuid_array => {
            if (v != .array) return .wrong_type;
            for (v.array.items) |item| {
                if (item != .string) return .wrong_type;
                if (k.value_type == .uuid_array and !isUuidText(item.string)) return .value_not_allowed;
            }
        },
    }
    if (k.one_of.len > 0) {
        for (k.one_of) |allowed| {
            if (std.mem.eql(u8, allowed, v.string)) break;
        } else return .value_not_allowed;
    }
    return null;
}

const IntegerValue = union(enum) { int: i64, huge };

/// Integral JSON numbers only: integers, floats with no fractional part, and
/// digit strings too large for i64 (reported as `huge`).
fn integerValue(v: std.json.Value) ?IntegerValue {
    switch (v) {
        .integer => |i| return .{ .int = i },
        .float => |f| {
            if (!std.math.isFinite(f) or @floor(f) != f) return null;
            if (f < -9.2e18 or f > 9.2e18) return .huge;
            return .{ .int = @intFromFloat(f) };
        },
        .number_string => |s| {
            const digits = if (s.len > 0 and s[0] == '-') s[1..] else s;
            if (digits.len == 0) return null;
            for (digits) |c| if (!std.ascii.isDigit(c)) return null;
            return .huge;
        },
        else => return null,
    }
}

/// 8-4-4-4-12 hex, either case.
fn isUuidText(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| switch (i) {
        8, 13, 18, 23 => if (c != '-') return false,
        else => if (!std.ascii.isHex(c)) return false,
    };
    return true;
}

// ---------------------------------------------------------------------------
// Tests.

const testing = std.testing;

test "unit: events: names unique and sorted" {
    for (entries[1..], 1..) |e, i| {
        try testing.expect(std.mem.order(u8, entries[i - 1].name, e.name) == .lt);
    }
}

test "unit: events: names well formed and categories valid" {
    for (entries) |e| {
        try testing.expect(isValidName(e.name, e.isFamily()));
        try testing.expectEqual(e.category, Category.parse(e.category.name()).?);
        // A cmux event's first segment names its category, except program_status (terminal).
        const first = e.name[0..std.mem.indexOfScalar(u8, e.name, '.').?];
        if (std.mem.eql(u8, first, "program_status")) {
            try testing.expectEqual(Category.terminal, e.category);
        } else {
            try testing.expectEqual(e.category, Category.parse(first).?);
        }
    }
}

test "unit: events: every cli-events-catalog inventory event present with its category" {
    const expected = [_]struct { []const u8, Category }{
        // cli-events-catalog-window-workspace
        .{ "window.created", .window },
        .{ "window.focused", .window },
        .{ "window.keyed", .window },
        .{ "window.unkeyed", .window },
        .{ "window.closed", .window },
        .{ "workspace.created", .workspace },
        .{ "workspace.selected", .workspace },
        .{ "workspace.closed", .workspace },
        .{ "workspace.renamed", .workspace },
        .{ "workspace.reordered", .workspace },
        .{ "workspace.moved", .workspace },
        .{ "workspace.action", .workspace },
        .{ "workspace.prompt.submitted", .workspace },
        // cli-events-catalog-surface-pane
        .{ "surface.created", .surface },
        .{ "surface.selected", .surface },
        .{ "surface.focused", .surface },
        .{ "surface.closed", .surface },
        .{ "surface.moved", .surface },
        .{ "surface.reordered", .surface },
        .{ "surface.action", .surface },
        .{ "surface.input_sent", .surface },
        .{ "surface.key_sent", .surface },
        .{ "surface.jump_to_last_prompt_requested", .surface },
        .{ "pane.created", .pane },
        .{ "pane.closed", .pane },
        .{ "pane.focused", .pane },
        .{ "pane.resized", .pane },
        .{ "pane.resize_requested", .pane },
        .{ "pane.swapped", .pane },
        .{ "pane.broken", .pane },
        .{ "pane.joined", .pane },
        // cli-events-catalog-sidebar-terminal
        .{ "sidebar.metadata.updated", .sidebar },
        .{ "sidebar.metadata.cleared", .sidebar },
        .{ "sidebar.progress.updated", .sidebar },
        .{ "sidebar.progress.cleared", .sidebar },
        .{ "sidebar.log.appended", .sidebar },
        .{ "sidebar.log.cleared", .sidebar },
        .{ "sidebar.reset", .sidebar },
        .{ "program_status.changed", .terminal },
        // cli-events-catalog-notification
        .{ "notification.requested", .notification },
        .{ "notification.clear_requested", .notification },
        .{ "notification.dismiss_requested", .notification },
        .{ "notification.mark_read_requested", .notification },
        .{ "notification.open_requested", .notification },
        .{ "notification.jump_to_unread_requested", .notification },
        .{ "notification.created", .notification },
        .{ "notification.read", .notification },
        .{ "notification.removed", .notification },
        .{ "notification.cleared", .notification },
        // cli-events-catalog-feed-agent
        .{ "feed.item.received", .feed },
        .{ "feed.item.completed", .feed },
        .{ "feed.item.resolved", .feed },
        .{ "agent.hook.Stop", .agent },
        .{ "agent.hook.UserPromptSubmit", .agent },
        .{ "agent.message.queued", .agent },
        .{ "agent.message.delivered", .agent },
        .{ "agent.message.read", .agent },
        .{ "agent.auto_resume.scheduled", .agent },
        .{ "agent.auto_resume.sent", .agent },
        .{ "agent.notification.decision", .agent },
        .{ "agent.journal.write_failed", .agent },
        .{ "agent.needs_input", .agent },
        // agents-agent-events-stream
        .{ "agent.message.failed", .agent },
        // cli-events-catalog-app-browser-config
        .{ "app.focus_override.changed", .app },
        .{ "app.simulated_active", .app },
        .{ "browser.navigation", .browser },
        .{ "browser.interaction", .browser },
        .{ "browser.input", .browser },
        .{ "config.reloaded", .config },
    };
    for (expected) |x| {
        const e = lookup(x[0]) orelse {
            std.log.err("missing event: {s}", .{x[0]});
            return error.MissingEvent;
        };
        try testing.expectEqual(x[1], e.category);
    }
}

test "unit: events: lifecycle versus socket-sourced classification" {
    try testing.expect(lookup("window.created").?.isLifecycle());
    try testing.expectEqualStrings("window.lifecycle", lookup("window.keyed").?.source.?);
    try testing.expectEqualStrings("workspace.lifecycle", lookup("workspace.selected").?.source.?);
    try testing.expect(lookup("surface.input_sent").?.isSocketSourced());
    try testing.expect(lookup("browser.input").?.isSocketSourced());
    try testing.expectEqualStrings("socket.v1", lookup("config.reloaded").?.source.?);
    try testing.expectEqualStrings("notification.store", lookup("notification.created").?.source.?);
    try testing.expect(!lookup("notification.created").?.isSocketSourced());
    // Agent hook source is the agent name, supplied by the producer.
    try testing.expect(lookup("agent.hook.Stop").?.source == null);
    for (entries) |e| {
        if (std.mem.endsWith(u8, e.name, "_requested")) try testing.expect(e.isSocketSourced());
        if (e.origin == .lifecycle) {
            const s = e.source.?;
            try testing.expect(std.mem.eql(u8, s, "window.lifecycle") or std.mem.eql(u8, s, "workspace.lifecycle"));
        }
        if (e.origin == .agent) try testing.expect(e.source == null) else try testing.expect(e.source != null);
    }
}

test "unit: events: privacy classification" {
    try testing.expectEqual(EventPrivacy.redacted, lookup("surface.input_sent").?.privacy());
    try testing.expectEqual(EventPrivacy.redacted, lookup("browser.input").?.privacy());
    try testing.expectEqual(EventPrivacy.redacted, lookup("notification.created").?.privacy());
    try testing.expectEqual(EventPrivacy.redacted, lookup("notification.requested").?.privacy());
    try testing.expectEqual(EventPrivacy.redacted, lookup("workspace.prompt.submitted").?.privacy());
    try testing.expectEqual(EventPrivacy.redacted, lookup("agent.hook.PreToolUse").?.privacy());
    try testing.expectEqual(EventPrivacy.redacted, lookup("program_status.changed").?.privacy());
    try testing.expectEqual(EventPrivacy.none, lookup("window.created").?.privacy());
    try testing.expectEqual(EventPrivacy.none, lookup("pane.swapped").?.privacy());

    const nf = redactedFields(.@"notification.created");
    try testing.expectEqual(@as(usize, 3), nf.len);
    try testing.expectEqualStrings("title", nf[0]);
    try testing.expectEqualStrings("subtitle", nf[1]);
    try testing.expectEqualStrings("body", nf[2]);
    try testing.expectEqualStrings("message", redactedFields(.@"workspace.prompt.submitted")[0]);
    try testing.expectEqualStrings("text", redactedFields(.@"surface.input_sent")[0]);
    try testing.expectEqual(@as(usize, 0), redactedFields(.@"window.created").len);
    for (lookup("agent.hook.Stop").?.payload) |k| {
        if (std.mem.eql(u8, k.name, "tool_input") or std.mem.eql(u8, k.name, "context") or std.mem.eql(u8, k.name, "extra_fields"))
            try testing.expectEqual(Privacy.omitted, k.privacy);
    }
}

test "unit: events: lookup by name, kind and category" {
    const k = kindOf("notification.created").?;
    try testing.expectEqual(Kind.@"notification.created", k);
    try testing.expectEqualStrings("notification.created", @tagName(k));
    try testing.expectEqualStrings("notification.created", entry(k).name);
    try testing.expectEqual(kindComptime("pane.joined"), Kind.@"pane.joined");
    for (entries, 0..) |e, i| {
        try testing.expectEqualStrings(e.name, @tagName(@as(Kind, @enumFromInt(i))));
        if (!e.isFamily()) try testing.expectEqual(@as(Kind, @enumFromInt(i)), kindOf(e.name).?);
    }

    var total: usize = 0;
    inline for (std.meta.fields(Category)) |f| {
        const cat: Category = @enumFromInt(f.value);
        const kinds = byCategory(cat);
        try testing.expect(kinds.len > 0);
        for (kinds, 0..) |kk, i| {
            try testing.expectEqual(cat, entry(kk).category);
            if (i > 0) try testing.expect(@intFromEnum(kinds[i - 1]) < @intFromEnum(kk));
        }
        total += kinds.len;
    }
    try testing.expectEqual(entries.len, total);
    try testing.expectEqual(@as(usize, 5), byCategory(.window).len);
    try testing.expectEqual(@as(usize, 10), byCategory(.notification).len);
    comptime std.debug.assert(byCategory(.terminal).len == 1);

    try testing.expect(Category.parse("feed").? == .feed);
    try testing.expect(Category.parse("Feed") == null);
    try testing.expect(Category.parse("") == null);
}

test "unit: events: family names and malformed lookups" {
    try testing.expectEqual(Kind.@"agent.hook.*", kindOf("agent.hook.UserPromptSubmit").?);
    try testing.expectEqual(Kind.@"agent.journal.*", kindOf("agent.journal.append.failed").?);
    try testing.expectEqualStrings("agent.hook.", entry(.@"agent.hook.*").familyPrefix());
    try testing.expectEqual(@as(usize, 2), families.len);
    const bad = [_][]const u8{
        "",
        "agent.hook.",
        "agent.hook.*",
        "agent.hook",
        "agent.hook..x",
        "agent.hook.x.",
        "agent.hook.Stop Now",
        "agent.hook.Stöp",
        "agent.hook.\x00",
        "window.created ",
        "Window.created",
        "window.created\n",
        "window",
        ".",
        "nope.event",
        "agent.hook.👩‍💻",
        "notification.created.",
        "wmux.unknown.event",
    };
    for (bad) |name| try testing.expect(kindOf(name) == null);
    const at_limit = "agent.hook." ++ "A" ** max_family_suffix_len;
    try testing.expect(kindOf(at_limit) != null);
    const too_long = "agent.hook." ++ "A" ** (max_family_suffix_len + 1);
    try testing.expect(kindOf(too_long) == null);
    const huge = "x" ** 65536;
    try testing.expect(kindOf(huge) == null);
}

test "unit: events: wmux additions live under wmux.* in category wmux" {
    var n: usize = 0;
    for (entries) |e| {
        const is_wmux = std.mem.startsWith(u8, e.name, "wmux.");
        try testing.expectEqual(is_wmux, e.category == .wmux);
        try testing.expectEqual(is_wmux, e.provenance == .wmux);
        if (is_wmux) n += 1;
    }
    try testing.expect(n > 0);
    try testing.expectEqual(n, byCategory(.wmux).len);
}

test "unit: events: catalog invariants for redacted and omitted keys" {
    for (entries) |e| {
        for (e.payload, 0..) |k, j| {
            for (e.payload[0..j]) |prev| try testing.expect(!std.mem.eql(u8, prev.name, k.name));
            switch (k.privacy) {
                .redacted => {
                    try testing.expect(k.nullable and !k.required);
                    var buf: [64]u8 = undefined;
                    const len_key = try std.fmt.bufPrint(&buf, "{s}_length", .{k.name});
                    try testing.expect(e.findKey(len_key) != null);
                },
                .omitted => try testing.expect(!k.required),
                else => {},
            }
        }
    }
}

fn expectViolation(name: []const u8, json: []const u8, reason: Reason, key: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const v = checkPayload(lookup(name).?, parsed.value) orelse return error.ExpectedViolation;
    try testing.expectEqual(reason, v.reason);
    try testing.expectEqualStrings(key, v.key);
}

test "unit: events: payload validation accepts documented payloads" {
    const gpa = testing.allocator;
    try validatePayloadJson(gpa, "notification.created",
        \\{"notification_id":"7ED5F805-CC6F-4B06-9701-AC798F63E209","title":null,"subtitle":null,"body":null,
        \\ "title_length":14,"subtitle_length":0,"body_length":13,"redacted_fields":["title","subtitle","body"],"delivery":"store"}
    );
    try validatePayloadJson(gpa, "agent.hook.Stop",
        \\{"session_id":"session-123","hook_event_name":"Stop","_source":"codex",
        \\ "surface_id":"83F4E6A4-5246-4DB8-A412-9CE7B059FA6C","tool_name":null,"_opencode_request_id":"request-456","phase":"received"}
    );
    try validatePayloadJson(gpa, "window.created",
        \\{"window_id":"2fb4e6a4-5246-4db8-a412-9ce7b059fa6c","workspace_id":null,"workspace_count":1,
        \\ "selected_workspace_index":0,"is_key_window":true,"is_main_window":true,"origin":"startup","extra":"ok"}
    );
    try validatePayloadJson(gpa, "program_status.changed",
        \\{"event":"removed","id":null,"record":null,"records":[],"records_total":0,"snapshot_id":"s1","snapshot_index":0,"snapshot_count":1}
    );
    try validatePayloadJson(gpa, "workspace.prompt.submitted",
        \\{"workspace_id":"9B6920C1-6C29-4C27-A069-78CF285F932A","message":null,"message_preview":"héllo 中 👩‍💻",
        \\ "message_length":9,"redacted_fields":["message"]}
    );
    try validatePayloadJson(gpa, "feed.item.completed",
        \\{"hook_event_name":"PermissionRequest","_source":"claude","phase":"completed","result":{"decision":"allow"}}
    );
    // Events without documented keys accept any object, including an empty one.
    try validatePayloadJson(gpa, "config.reloaded", "{}");
    try validatePayloadJson(gpa, "sidebar.reset", "{\"anything\":[1,2,3]}");
    // A truncated payload replaces the original and skips required keys.
    try validatePayloadJson(gpa, "notification.created", "{\"payload_truncated\":true}");
}

test "unit: events: payload validation rejects malformed payloads" {
    const gpa = testing.allocator;
    try testing.expectError(error.UnknownEvent, validatePayloadJson(gpa, "no.such.event", "{}"));
    try testing.expectError(error.InvalidPayload, validatePayloadJson(gpa, "config.reloaded", "[]"));
    try testing.expectError(error.InvalidPayload, validatePayloadJson(gpa, "config.reloaded", "null"));
    try testing.expectError(error.SyntaxError, validatePayloadJson(gpa, "config.reloaded", "{\"a\" 1}"));
    try testing.expectError(error.UnexpectedEndOfInput, validatePayloadJson(gpa, "config.reloaded", ""));

    try expectViolation("config.reloaded", "\"str\"", .not_an_object, "");
    try expectViolation("pane.focused", "{}", .missing_required_key, "selected_surface_id");
    try expectViolation("workspace.selected", "{\"previous_workspace_id\":null,\"index\":\"1\",\"tab_count\":2}", .wrong_type, "index");
    try expectViolation("workspace.selected", "{\"previous_workspace_id\":null,\"index\":-1,\"tab_count\":2}", .out_of_range, "index");
    try expectViolation("workspace.selected", "{\"previous_workspace_id\":\"not-a-uuid\",\"index\":1,\"tab_count\":2}", .value_not_allowed, "previous_workspace_id");
    try expectViolation("surface.selected", "{\"previous_surface_id\":null,\"pane_id\":null,\"kind\":null,\"focused\":true}", .null_not_allowed, "kind");
    try expectViolation("workspace.reordered", "{\"workspace_ids\":[\"x\"],\"moved_workspace_ids\":[],\"pinned_workspace_ids\":[],\"count\":1}", .value_not_allowed, "workspace_ids");
    try expectViolation("workspace.reordered", "{\"workspace_ids\":[1],\"moved_workspace_ids\":[],\"pinned_workspace_ids\":[],\"count\":1}", .wrong_type, "workspace_ids");
    try expectViolation("program_status.changed", "{\"event\":\"bogus\",\"id\":null,\"record\":null,\"records\":[],\"records_total\":0,\"snapshot_id\":\"s\",\"snapshot_index\":0,\"snapshot_count\":1}", .value_not_allowed, "event");
    try expectViolation("program_status.changed", "{\"event\":\"clear\",\"id\":null,\"record\":null,\"records\":[],\"records_total\":0,\"snapshot_id\":\"s\",\"snapshot_index\":0,\"snapshot_count\":0}", .out_of_range, "snapshot_count");
}

test "unit: events: privacy violations are detected" {
    // The acceptance line: typed text must never appear in surface.input_sent.
    try expectViolation("surface.input_sent", "{\"text\":\"secret123\",\"text_length\":9,\"redacted_fields\":[\"text\"]}", .redacted_value_present, "text");
    try expectViolation("browser.input", "{\"value\":\"hunter2\",\"value_length\":7,\"redacted_fields\":[\"value\"]}", .redacted_value_present, "value");
    try expectViolation("notification.created",
        \\{"notification_id":"7ED5F805-CC6F-4B06-9701-AC798F63E209","title":"T","subtitle":null,"body":null,
        \\ "title_length":1,"subtitle_length":0,"body_length":0,"redacted_fields":["title","subtitle","body"],"delivery":"store"}
    , .redacted_value_present, "title");
    try expectViolation("agent.hook.PreToolUse", "{\"hook_event_name\":\"PreToolUse\",\"_source\":\"claude\",\"phase\":\"received\",\"tool_input\":{\"cmd\":\"ls\"}}", .omitted_key_present, "tool_input");
    try expectViolation("agent.message.queued", "{\"id\":\"m1\",\"thread_id\":null,\"sender_name\":null,\"sender_surface_id\":null,\"body_length\":2,\"body\":\"hi\"}", .omitted_key_present, "body");
    // Truncation never licenses leaking redacted text.
    try expectViolation("surface.input_sent", "{\"payload_truncated\":true,\"text\":\"secret123\"}", .redacted_value_present, "text");
    try validatePayloadJson(testing.allocator, "surface.input_sent", "{\"text\":null,\"text_length\":0,\"redacted_fields\":[\"text\"]}");
}

test "unit: events: prompt_length accepts only integral 0..1048576" {
    const ok = [_][]const u8{ "0", "85", "18635", "1048576", "85.0" };
    const bad = [_]struct { []const u8, Reason }{
        .{ "-1", .out_of_range },    .{ "1048577", .out_of_range },
        .{ "1.5", .wrong_type },     .{ "true", .wrong_type },
        .{ "\"85\"", .wrong_type },  .{ "99999999999999999999999", .out_of_range },
        .{ "1e300", .out_of_range }, .{ "null", .null_not_allowed },
    };
    var buf: [256]u8 = undefined;
    for (ok) |n| {
        const json = try std.fmt.bufPrint(&buf, "{{\"hook_event_name\":\"UserPromptSubmit\",\"_source\":\"claude\",\"phase\":\"received\",\"prompt_length\":{s}}}", .{n});
        try validatePayloadJson(testing.allocator, "agent.hook.UserPromptSubmit", json);
    }
    for (bad) |b| {
        const json = try std.fmt.bufPrint(&buf, "{{\"hook_event_name\":\"UserPromptSubmit\",\"_source\":\"claude\",\"phase\":\"received\",\"prompt_length\":{s}}}", .{b[0]});
        try expectViolation("agent.hook.UserPromptSubmit", json, b[1], "prompt_length");
    }
    // Absent means unknown, not zero: still valid.
    try validatePayloadJson(testing.allocator, "agent.hook.UserPromptSubmit", "{\"hook_event_name\":\"UserPromptSubmit\",\"_source\":\"claude\",\"phase\":\"received\"}");
}

test "unit: events: hasRequiredKeys on huge and unicode payloads" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{");
    for (0..5000) |i| try w.print("\"k{d}\":\"ü{d}\",", .{ i, i });
    try w.writeAll("\"selected_surface_id\":null}");
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, aw.written(), .{});
    defer parsed.deinit();
    const e = lookup("pane.focused").?;
    try testing.expect(hasRequiredKeys(e, parsed.value.object));
    try testing.expect(checkPayload(e, parsed.value) == null);
    try testing.expect(!hasRequiredKeys(lookup("window.created").?, parsed.value.object));
    try testing.expect(hasRequiredKeys(lookup("config.reloaded").?, parsed.value.object));
}
