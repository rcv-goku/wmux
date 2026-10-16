//! The model event bus [frozen] (ARCHITECTURE.md ADR-3.10; written in
//! W0-A3). UI thread only.
//!
//! Lifecycle events (`window.*`, `workspace.*`, `pane.*`, `surface.*`)
//! come only from model/ops/* (and the window's create/free paths there),
//! so UI, shortcut, CLI, restore and startup paths each emit exactly once.
//! Feature stores emit the events of their own domain (notifications,
//! sidebar metadata, agents, feed); rpc/dispatch.zig emits the
//! socket-sourced ones (W1-1/W2-4). Every name and its payload keys are in
//! wmux_proto/events_catalog.zig.
//!
//! `emit` runs synchronously after the mutation: every feature's
//! `onEvent` in manifest order (features/lifecycle.zig). The session's
//! autosave dirty mark (W1-7) and the events stream and durable log
//! (W2-4) are such consumers; JSON is written only by consumers that need
//! it, through the lazy `Payload`.

const std = @import("std");
const builtin = @import("builtin");
const proto = @import("wmux_proto");

const App = @import("../App.zig");
const ids = @import("ids.zig");
const lifecycle = @import("../features/lifecycle.zig");

pub const catalog = proto.events_catalog;
pub const Kind = catalog.Kind;
pub const Uuid = ids.Uuid;

/// The `automation_origin` of an event an automation action caused
/// (cli-automation-origin-loop-guard): `{rule_id, chain, depth}`. The pure
/// type lives with the automation feature's loop guard; the bus only
/// carries the pointer.
pub const AutomationOrigin = @import("../features/automation/logic/loop_guard.zig").AutomationOrigin;

/// A lazily written JSON payload object. `ctx` must stay valid for the
/// duration of `emit` (consumers that keep the event copy what they need).
pub const Payload = struct {
    ctx: *const anyopaque,
    write: *const fn (ctx: *const anyopaque, w: *std.json.Stringify) anyerror!void,

    /// The payload that writes `value.*` (a struct) as a JSON object.
    pub fn of(comptime T: type, value: *const T) Payload {
        const Writer = struct {
            fn write(ctx: *const anyopaque, w: *std.json.Stringify) anyerror!void {
                const v: *const T = @ptrCast(@alignCast(ctx));
                try w.write(v.*);
            }
        };
        return .{ .ctx = value, .write = Writer.write };
    }
};

pub const Event = struct {
    kind: Kind,
    /// For family entries (`agent.hook.*`): the part after the family
    /// prefix (`Stop` in `agent.hook.Stop`). Null for exact names.
    name_suffix: ?[]const u8 = null,
    /// Envelope `source` (`workspace.lifecycle`, `window.lifecycle`,
    /// `notification.store`, an agent name, ...).
    source: []const u8,
    window_id: ?Uuid = null,
    workspace_id: ?Uuid = null,
    pane_id: ?Uuid = null,
    surface_id: ?Uuid = null,
    payload: ?Payload = null,
    automation_origin: ?*const AutomationOrigin = null,

    /// An event named `event_name` (a catalog name, checked at compile
    /// time) with the catalog's default source.
    pub fn of(comptime event_name: []const u8) Event {
        const kind = comptime catalog.kindComptime(event_name);
        const source = comptime catalog.entry(kind).source orelse
            @compileError("model/events.zig: " ++ event_name ++ " has no default source; set it");
        return .{ .kind = kind, .source = source };
    }

    /// A family event (`agent.hook.*`) named by its suffix (`Stop`).
    pub fn ofFamily(comptime family: []const u8, suffix: []const u8, source: []const u8) Event {
        const kind = comptime std.meta.stringToEnum(Kind, family) orelse
            @compileError("model/events.zig: unknown event family: " ++ family);
        comptime if (!catalog.entry(kind).isFamily()) @compileError("model/events.zig: not a family: " ++ family);
        return .{ .kind = kind, .name_suffix = suffix, .source = source };
    }

    pub fn entry(self: *const Event) *const catalog.Entry {
        return catalog.entry(self.kind);
    }

    /// The concrete event name (`window.created`, `agent.hook.Stop`).
    /// `buf` must hold the family prefix plus the suffix; a family event
    /// whose name does not fit yields the prefix alone.
    pub fn name(self: *const Event, buf: []u8) []const u8 {
        const e = self.entry();
        if (!e.isFamily()) return e.name;
        const prefix = e.familyPrefix();
        const suffix = self.name_suffix orelse return prefix;
        return std.fmt.bufPrint(buf, "{s}{s}", .{ prefix, suffix }) catch prefix;
    }

    /// Whether the event is well formed: a family event carries a valid
    /// suffix, an exact one none.
    pub fn isValid(self: *const Event) bool {
        if (!self.entry().isFamily()) return self.name_suffix == null;
        const suffix = self.name_suffix orelse return false;
        var buf: [256]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}{s}", .{ self.entry().familyPrefix(), suffix }) catch return false;
        return catalog.kindOf(full) == self.kind;
    }
};

/// Publish `ev` after the mutation it describes (UI thread): every
/// feature's `onEvent`, in manifest order. Nothing is delivered while the
/// features are not initialized (`App.features_initialized`: a failed
/// feature init, or after their deinit in App.terminate).
pub fn emit(app: *App, ev: Event) void {
    if (builtin.mode == .Debug) std.debug.assert(ev.isValid());
    if (!app.features_initialized) return;
    lifecycle.onEvent(app, &ev);
}

// ---------------------------------------------------------------------------
// Payloads of the lifecycle events (cmux key names; W2-4 audits them)
// ---------------------------------------------------------------------------

/// `window.created`, `window.closed`.
pub const WindowPayload = struct {
    window_id: Uuid,
    workspace_id: ?Uuid,
    workspace_count: usize,
    selected_workspace_index: ?usize,
    is_key_window: bool,
    is_main_window: bool,
    origin: []const u8,
};

/// `workspace.created`, `workspace.closed`, `workspace.renamed`.
pub const WorkspacePayload = struct {
    workspace_id: Uuid,
    title: []const u8,
    custom_title: ?[]const u8,
    cwd: ?[]const u8,
    selected: bool,
};

/// `workspace.selected`.
pub const WorkspaceSelectedPayload = struct {
    workspace_id: Uuid,
    previous_workspace_id: ?Uuid,
    index: usize,
    tab_count: usize,
};

/// `workspace.reordered`.
pub const WorkspaceReorderedPayload = struct {
    workspace_ids: []const Uuid,
    moved_workspace_ids: []const Uuid,
    pinned_workspace_ids: []const Uuid,
    count: usize,
};

/// `pane.created`, `pane.broken`.
pub const PaneCreatedPayload = struct {
    pane_id: Uuid,
    source_pane_id: ?Uuid,
    orientation: ?[]const u8,
    surface_id: ?Uuid,
    origin: []const u8,
};

/// `pane.closed`.
pub const PaneClosedPayload = struct {
    pane_id: Uuid,
    closed_surface_ids: []const Uuid,
    origin: []const u8,
};

/// `pane.focused`.
pub const PaneFocusedPayload = struct {
    pane_id: Uuid,
    selected_surface_id: ?Uuid,
    origin: []const u8,
};

/// `pane.swapped`, `pane.resized`.
pub const PaneChangedPayload = struct {
    pane_id: Uuid,
    other_pane_id: ?Uuid = null,
    origin: []const u8,
};

/// `surface.created`.
pub const SurfaceCreatedPayload = struct {
    surface_id: Uuid,
    pane_id: ?Uuid,
    kind: []const u8,
    origin: []const u8,
    focused: bool,
};

/// `surface.selected`.
pub const SurfaceSelectedPayload = struct {
    surface_id: Uuid,
    pane_id: ?Uuid,
    kind: []const u8,
    previous_surface_id: ?Uuid,
    focused: bool,
    origin: []const u8,
};

/// `surface.closed`.
pub const SurfaceClosedPayload = struct {
    surface_id: Uuid,
    pane_id: ?Uuid,
    kind: []const u8,
    origin: []const u8,
};

/// `surface.reordered`.
pub const SurfaceReorderedPayload = struct {
    pane_id: Uuid,
    surface_ids: []const Uuid,
    moved_surface_id: Uuid,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn payloadJson(p: Payload) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try p.write(p.ctx, &jw);
    return aw.toOwnedSlice();
}

test "unit: model: events of a catalog name carry its kind and default source" {
    const ev = Event.of("workspace.created");
    try testing.expectEqualStrings("workspace.created", catalog.entry(ev.kind).name);
    try testing.expectEqualStrings("workspace.lifecycle", ev.source);
    try testing.expect(ev.isValid());
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("workspace.created", ev.name(&buf));
    const w = Event.of("window.closed");
    try testing.expectEqualStrings("window.lifecycle", w.source);
}

test "unit: model: events of a family carry the suffix in their name" {
    // FOLLOWUPS (cf-p4): agent.hook.<HookEventName> needs a family suffix.
    const ev = Event.ofFamily("agent.hook.*", "Stop", "claude");
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("agent.hook.Stop", ev.name(&buf));
    try testing.expectEqualStrings("claude", ev.source);
    try testing.expect(ev.isValid());
    // A family event without a suffix, or an exact one with one, is malformed.
    var bad = ev;
    bad.name_suffix = null;
    try testing.expect(!bad.isValid());
    var exact = Event.of("pane.created");
    exact.name_suffix = "x";
    try testing.expect(!exact.isValid());
    // A suffix the catalog grammar rejects is malformed too.
    bad.name_suffix = "";
    try testing.expect(!bad.isValid());
}

test "unit: model: events payloads write their struct as JSON" {
    const u = try Uuid.parse("9b690abc-def0-4123-8456-789abcdef012");
    const value: SurfaceClosedPayload = .{ .surface_id = u, .pane_id = null, .kind = "terminal", .origin = "tab_close" };
    const json = try payloadJson(Payload.of(SurfaceClosedPayload, &value));
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"surface_id\":\"9B690ABC-DEF0-4123-8456-789ABCDEF012\",\"pane_id\":null,\"kind\":\"terminal\",\"origin\":\"tab_close\"}",
        json,
    );
    const ids_list = [_]Uuid{ u, u };
    const reordered: WorkspaceReorderedPayload = .{ .workspace_ids = &ids_list, .moved_workspace_ids = ids_list[0..1], .pinned_workspace_ids = &.{}, .count = 2 };
    const json2 = try payloadJson(Payload.of(WorkspaceReorderedPayload, &reordered));
    defer testing.allocator.free(json2);
    try testing.expect(std.mem.indexOf(u8, json2, "\"pinned_workspace_ids\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, json2, "\"count\":2") != null);
}

test "unit: model: events required catalog keys appear in the payload structs" {
    // Every required key of the lifecycle events the model emits is a field
    // of the payload struct it uses.
    const pairs = .{
        .{ "window.created", WindowPayload },
        .{ "window.closed", WindowPayload },
        .{ "workspace.selected", WorkspaceSelectedPayload },
        .{ "workspace.reordered", WorkspaceReorderedPayload },
        .{ "pane.focused", PaneFocusedPayload },
        .{ "surface.selected", SurfaceSelectedPayload },
    };
    inline for (pairs) |pair| {
        const e = catalog.entry(comptime catalog.kindComptime(pair[0]));
        for (e.payload) |k| {
            if (!k.required) continue;
            var found = false;
            inline for (@typeInfo(pair[1]).@"struct".fields) |f| {
                if (std.mem.eql(u8, f.name, k.name)) found = true;
            }
            try testing.expect(found);
        }
    }
}
