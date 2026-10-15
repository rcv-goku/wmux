//! Session file schema v3 (ADR-9.2): Zig types, a tolerant reader and a
//! deterministic writer. One document holds every window, nested
//! window → groups/workspaces → panes → tabs, and every object carries an
//! `ext` object (one key per feature) that round-trips untouched, so data
//! written by newer builds survives older ones.
//!
//! Reader rules: unknown fields are ignored, wrongly typed fields fall back
//! to their defaults, malformed UUIDs become `null` (the restorer mints a new
//! handle), refs that are not positive u32 become 0 (mint). Only a document
//! whose header is not a v3 `wmux-session` is refused (see `ParseError`).
//! `normalize` then repairs cross references so restore never sees a
//! dangling id.
//!
//! Memory: everything a `Session` points at lives in one arena. `parse`
//! returns a `Parsed` that owns it; builders use their own arena.

const std = @import("std");
const limits = @import("limits.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub const schema_name = "wmux-session";
pub const current_version: u32 = 3;

// ── Types ───────────────────────────────────────────────────────────

pub const Kind = enum { window, workspace, workspace_group, pane, surface };

/// `handles.next`: per-kind ref high-water marks (ADR-2.2). A ref `n` is
/// never re-issued once `next > n`.
pub const HandleNext = struct {
    window: u32 = 1,
    workspace: u32 = 1,
    workspace_group: u32 = 1,
    pane: u32 = 1,
    surface: u32 = 1,

    pub fn get(self: HandleNext, kind: Kind) u32 {
        return switch (kind) {
            inline else => |k| @field(self, @tagName(k)),
        };
    }

    pub fn set(self: *HandleNext, kind: Kind, n: u32) void {
        switch (kind) {
            inline else => |k| @field(self, @tagName(k)) = n,
        }
    }
};

pub const Handles = struct {
    next: HandleNext = .{},
};

/// Per-feature extension data: one key per feature id. `null` writes `{}`.
pub const Ext = ?ObjectMap;

pub const TitleSource = enum { auto, user, process, agent };

pub const Title = struct {
    custom: ?[]const u8 = null,
    auto: ?[]const u8 = null,
    source: TitleSource = .auto,
};

pub const Placement = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    maximized: bool = false,
    fullscreen: bool = false,
    monitor: ?[]const u8 = null,
    dpi: u32 = 96,
};

pub const Sidebar = struct {
    visible: bool = true,
    width: u32 = 240,
    scroll: u32 = 0,
};

pub const RightSidebar = struct {
    visible: bool = false,
    width: u32 = 300,
    mode: ?[]const u8 = null,
};

pub const Group = struct {
    id: ?[]const u8 = null,
    ref: u32 = 0,
    name: []const u8 = "",
    collapsed: bool = false,
    pinned: bool = false,
    anchor: ?[]const u8 = null,
};

pub const SplitDir = enum { horizontal, vertical };

/// Split tree of a workspace. Leaves name a pane by UUID.
pub const Layout = union(enum) {
    pane: []const u8,
    split: *Split,

    /// Number of split levels on the deepest path (a leaf is 0).
    pub fn depth(self: Layout) usize {
        return switch (self) {
            .pane => 0,
            .split => |s| 1 + @max(s.a.depth(), s.b.depth()),
        };
    }
};

pub const Split = struct {
    dir: SplitDir = .horizontal,
    ratio: f32 = 0.5,
    a: Layout,
    b: Layout,
};

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

pub const Spawn = struct {
    argv: []const []const u8 = &.{},
    shell_kind: ?[]const u8 = null,
};

pub const Terminal = struct {
    cwd: ?[]const u8 = null,
    remote_cwd: ?[]const u8 = null,
    wsl_distro: ?[]const u8 = null,
    spawn: ?Spawn = null,
    font_size: ?f32 = null,
    /// Relative path of the scrollback file (`scrollback/<surface-uuid>.vt`).
    scrollback: ?[]const u8 = null,
};

pub const Browser = struct {
    url: []const u8 = "about:blank",
    back: []const []const u8 = &.{},
    forward: []const []const u8 = &.{},
    zoom: f32 = 1.0,
    profile: ?[]const u8 = null,
    devtools: bool = false,
    muted: bool = false,
};

pub const Web = struct {
    app: []const u8 = "",
    params: Value = .null,
    state: Value = .null,
};

pub const Placeholder = struct {
    reason: []const u8 = "",
};

pub const Panel = union(enum) {
    terminal: Terminal,
    browser: Browser,
    web: Web,
    placeholder: Placeholder,
    /// A panel kind this build does not know; the raw object round-trips.
    unknown: ObjectMap,
};

pub const Tab = struct {
    id: ?[]const u8 = null,
    ref: u32 = 0,
    title: Title = .{},
    pinned: bool = false,
    panel: Panel = .{ .terminal = .{} },
    ext: Ext = null,
};

pub const Pane = struct {
    id: ?[]const u8 = null,
    ref: u32 = 0,
    selected_tab: ?[]const u8 = null,
    tabs: []Tab = &.{},
    ext: Ext = null,
};

pub const Workspace = struct {
    id: ?[]const u8 = null,
    ref: u32 = 0,
    title: Title = .{},
    description: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    env: []const EnvVar = &.{},
    group: ?[]const u8 = null,
    pinned: bool = false,
    focused_pane: ?[]const u8 = null,
    zoomed_pane: ?[]const u8 = null,
    layout: ?Layout = null,
    panes: []Pane = &.{},
    ext: Ext = null,
};

pub const Window = struct {
    id: ?[]const u8 = null,
    ref: u32 = 0,
    placement: ?Placement = null,
    sidebar: Sidebar = .{},
    right_sidebar: RightSidebar = .{},
    selected_workspace: ?[]const u8 = null,
    groups: []Group = &.{},
    workspaces: []Workspace = &.{},
    ext: Ext = null,
};

pub const Session = struct {
    app_version: []const u8 = "",
    channel: []const u8 = "",
    /// ISO 8601 UTC with milliseconds (`formatTimestamp`).
    created_at: ?[]const u8 = null,
    clean_exit: bool = false,
    scrollback_captured_at: ?[]const u8 = null,
    handles: Handles = .{},
    windows: []Window = &.{},
};

// ── Ext helpers ─────────────────────────────────────────────────────

/// Returns the value a feature stored under `key`, if any.
pub fn extGet(ext: Ext, key: []const u8) ?Value {
    const m = ext orelse return null;
    return m.get(key);
}

/// Stores `value` under `key`, creating the map in `arena` when needed.
/// `key` and `value` must outlive the session (arena-owned).
pub fn extPut(arena: Allocator, ext: *Ext, key: []const u8, value: Value) !void {
    if (ext.* == null) ext.* = ObjectMap.init(arena);
    try ext.*.?.put(key, value);
}

// ── UUID text ───────────────────────────────────────────────────────

/// Validates a UUID in 8-4-4-4-12 hex form (case-insensitive, `{}` braces
/// tolerated) and writes the canonical uppercase form into `out`.
pub fn canonicalUuid(s: []const u8, out: *[36]u8) bool {
    var t = s;
    if (t.len == 38 and t[0] == '{' and t[37] == '}') t = t[1..37];
    if (t.len != 36) return false;
    for (t, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
            out[i] = '-';
        } else {
            if (!std.ascii.isHex(c)) return false;
            out[i] = std.ascii.toUpper(c);
        }
    }
    return true;
}

/// Renders 16 random bytes as an uppercase UUIDv4 (RFC 4122 variant).
pub fn mintUuid(random: std.Random, out: *[36]u8) void {
    var b: [16]u8 = undefined;
    random.bytes(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const hex = "0123456789ABCDEF";
    var o: usize = 0;
    for (b, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[o] = '-';
            o += 1;
        }
        out[o] = hex[byte >> 4];
        out[o + 1] = hex[byte & 0x0f];
        o += 2;
    }
}

// ── Timestamps ──────────────────────────────────────────────────────

/// Formats Unix milliseconds as `YYYY-MM-DDTHH:MM:SS.mmmZ`. Negative input
/// clamps to the epoch.
pub fn formatTimestamp(ms: i64, out: *[24]u8) []const u8 {
    const clamped: u64 = @intCast(@max(ms, 0));
    const secs = std.time.epoch.EpochSeconds{ .secs = clamped / 1000 };
    const yd = secs.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = secs.getDaySeconds();
    return std.fmt.bufPrint(out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        yd.year % 10000,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
        clamped % 1000,
    }) catch unreachable;
}

/// Parses `YYYY-MM-DDTHH:MM:SS[.fff]Z` (the `formatTimestamp` shape;
/// 1 to 9 fraction digits) into Unix milliseconds. Years before 1970 and
/// out-of-range fields are rejected.
pub fn parseTimestamp(s: []const u8) ?i64 {
    if (s.len < 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;
    if (s[s.len - 1] != 'Z') return null;
    const year = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, s[17..19], 10) catch return null;
    var ms: i64 = 0;
    const rest = s[19 .. s.len - 1];
    if (rest.len > 0) {
        if (rest[0] != '.' or rest.len < 2 or rest.len > 10) return null;
        for (rest[1..], 0..) |c, i| {
            if (!std.ascii.isDigit(c)) return null;
            if (i < 3) ms = ms * 10 + (c - '0');
        }
        var digits = rest.len - 1;
        while (digits < 3) : (digits += 1) ms *= 10;
    }
    if (year < 1970 or month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59) return null;
    const month_enum: std.time.epoch.Month = @enumFromInt(month);
    if (day < 1 or day > std.time.epoch.getDaysInMonth(year, month_enum)) return null;
    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) days += std.time.epoch.getDaysInYear(y);
    var m: u8 = 1;
    while (m < month) : (m += 1) days += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
    days += day - 1;
    const secs = days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
    return secs * 1000 + ms;
}

// ── Reader ──────────────────────────────────────────────────────────

pub const ParseError = error{
    OutOfMemory,
    /// Not JSON, not an object, or a `wmux-session` header that is invalid.
    Corrupt,
    /// Valid JSON object with a `schema` that is not `wmux-session`.
    NotSession,
    /// A pre-v3 wmux file (no `schema`, top-level `workspaces`): migrate it.
    LegacyVersion,
    /// A `wmux-session` with a version newer than this build: refuse it.
    FutureVersion,
};

pub const Diagnostics = struct {
    /// The document's version number when one was found (legacy files
    /// without a version report 1).
    version: ?i64 = null,
};

pub const Parsed = struct {
    arena: *std.heap.ArenaAllocator,
    session: Session,

    pub fn deinit(self: Parsed) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }
};

pub const ParseOptions = struct {
    /// Run `normalize` after reading (repairs dangling references).
    normalize: bool = true,
    /// Run `limits.apply` after reading (cmux snapshot caps).
    apply_limits: bool = true,
};

/// Parses a v3 document into an owned `Parsed`.
pub fn parse(gpa: Allocator, bytes: []const u8, opts: ParseOptions, diag: ?*Diagnostics) ParseError!Parsed {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    const session = try parseLeaky(arena.allocator(), bytes, opts, diag);
    return .{ .arena = arena, .session = session };
}

/// Parses into `arena`; every returned slice is owned by `arena`.
pub fn parseLeaky(arena: Allocator, bytes: []const u8, opts: ParseOptions, diag: ?*Diagnostics) ParseError!Session {
    if (bytes.len > limits.max_file_bytes) return error.Corrupt;
    const root = std.json.parseFromSliceLeaky(Value, arena, bytes, .{
        .duplicate_field_behavior = .use_last,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    const obj = switch (root) {
        .object => |o| o,
        else => return error.Corrupt,
    };
    try checkHeader(obj, diag);
    var session = try readSession(arena, obj);
    if (opts.normalize or opts.apply_limits) try normalize(arena, &session);
    if (opts.apply_limits) _ = try limits.apply(arena, &session);
    return session;
}

/// Classifies a parsed root object without reading the body.
pub fn checkHeader(obj: ObjectMap, diag: ?*Diagnostics) ParseError!void {
    const schema_v = obj.get("schema") orelse {
        if (obj.get("workspaces")) |w| if (w == .array) {
            if (diag) |d| d.version = getInt(obj, "version") orelse 1;
            return error.LegacyVersion;
        };
        return error.Corrupt;
    };
    const schema = switch (schema_v) {
        .string => |s| s,
        else => return error.Corrupt,
    };
    if (!std.mem.eql(u8, schema, schema_name)) return error.NotSession;
    const version = getInt(obj, "version") orelse return error.Corrupt;
    if (diag) |d| d.version = version;
    if (version > current_version) return error.FutureVersion;
    if (version != current_version) return error.Corrupt;
}

fn readSession(arena: Allocator, o: ObjectMap) !Session {
    var s: Session = .{
        .app_version = getText(o, "app_version") orelse "",
        .channel = getText(o, "channel") orelse "",
        .created_at = getText(o, "created_at"),
        .clean_exit = getBool(o, "clean_exit", false),
        .scrollback_captured_at = getText(o, "scrollback_captured_at"),
    };
    if (getObject(o, "handles")) |h| if (getObject(h, "next")) |n| {
        inline for (std.meta.fields(HandleNext)) |f| {
            if (getU32(n, f.name)) |v| @field(s.handles.next, f.name) = @max(v, 1);
        }
    };
    const wins = getArray(o, "windows");
    var list: std.ArrayList(Window) = .empty;
    for (wins) |wv| {
        const wo = asObject(wv) orelse continue;
        try list.append(arena, try readWindow(arena, wo));
    }
    s.windows = list.items;
    return s;
}

fn readWindow(arena: Allocator, o: ObjectMap) !Window {
    var w: Window = .{
        .id = try getUuid(arena, o, "id"),
        .ref = getRef(o),
        .selected_workspace = try getUuid(arena, o, "selected_workspace"),
        .ext = getExt(o),
    };
    if (getObject(o, "placement")) |p| {
        w.placement = .{
            .x = getI32(p, "x") orelse 0,
            .y = getI32(p, "y") orelse 0,
            .w = getI32(p, "w") orelse 0,
            .h = getI32(p, "h") orelse 0,
            .maximized = getBool(p, "maximized", false),
            .fullscreen = getBool(p, "fullscreen", false),
            .monitor = getText(p, "monitor"),
            .dpi = getU32(p, "dpi") orelse 96,
        };
    }
    if (getObject(o, "sidebar")) |sb| {
        w.sidebar = .{
            .visible = getBool(sb, "visible", true),
            .width = getU32(sb, "width") orelse 240,
            .scroll = getU32(sb, "scroll") orelse 0,
        };
    }
    if (getObject(o, "right_sidebar")) |rs| {
        w.right_sidebar = .{
            .visible = getBool(rs, "visible", false),
            .width = getU32(rs, "width") orelse 300,
            .mode = getText(rs, "mode"),
        };
    }
    var groups: std.ArrayList(Group) = .empty;
    for (getArray(o, "groups")) |gv| {
        const go = asObject(gv) orelse continue;
        try groups.append(arena, .{
            .id = try getUuid(arena, go, "id"),
            .ref = getRef(go),
            .name = getText(go, "name") orelse "",
            .collapsed = getBool(go, "collapsed", false),
            .pinned = getBool(go, "pinned", false),
            .anchor = try getUuid(arena, go, "anchor"),
        });
    }
    w.groups = groups.items;
    var wss: std.ArrayList(Workspace) = .empty;
    for (getArray(o, "workspaces")) |wv| {
        const wo = asObject(wv) orelse continue;
        try wss.append(arena, try readWorkspace(arena, wo));
    }
    w.workspaces = wss.items;
    return w;
}

fn readWorkspace(arena: Allocator, o: ObjectMap) !Workspace {
    var ws: Workspace = .{
        .id = try getUuid(arena, o, "id"),
        .ref = getRef(o),
        .title = readTitle(o),
        .description = getText(o, "description"),
        .cwd = getText(o, "cwd"),
        .group = try getUuid(arena, o, "group"),
        .pinned = getBool(o, "pinned", false),
        .focused_pane = try getUuid(arena, o, "focused_pane"),
        .zoomed_pane = try getUuid(arena, o, "zoomed_pane"),
        .ext = getExt(o),
    };
    if (getObject(o, "env")) |env| {
        var vars: std.ArrayList(EnvVar) = .empty;
        var it = env.iterator();
        while (it.next()) |e| {
            const v = switch (e.value_ptr.*) {
                .string => |s| s,
                else => continue,
            };
            if (e.key_ptr.len == 0) continue;
            try vars.append(arena, .{ .name = e.key_ptr.*, .value = capText(v) });
        }
        ws.env = vars.items;
    }
    if (o.get("layout")) |lv| ws.layout = try readLayout(arena, lv, 0);
    var panes: std.ArrayList(Pane) = .empty;
    for (getArray(o, "panes")) |pv| {
        const po = asObject(pv) orelse continue;
        var pane: Pane = .{
            .id = try getUuid(arena, po, "id"),
            .ref = getRef(po),
            .selected_tab = try getUuid(arena, po, "selected_tab"),
            .ext = getExt(po),
        };
        var tabs: std.ArrayList(Tab) = .empty;
        for (getArray(po, "tabs")) |tv| {
            const to = asObject(tv) orelse continue;
            try tabs.append(arena, try readTab(arena, to));
        }
        pane.tabs = tabs.items;
        try panes.append(arena, pane);
    }
    ws.panes = panes.items;
    return ws;
}

/// Reads a layout node; malformed or too deep subtrees yield `null`.
fn readLayout(arena: Allocator, v: Value, depth: usize) !?Layout {
    if (depth > limits.max_layout_depth) return null;
    const o = asObject(v) orelse return null;
    if (try getUuid(arena, o, "pane")) |id| return .{ .pane = id };
    const so = getObject(o, "split") orelse return null;
    const a = try readLayout(arena, so.get("a") orelse return null, depth + 1);
    const b = try readLayout(arena, so.get("b") orelse return null, depth + 1);
    // A split with one broken side collapses to the other side.
    if (a == null) return b;
    if (b == null) return a;
    const split = try arena.create(Split);
    split.* = .{
        .dir = getEnum(SplitDir, so, "dir") orelse .horizontal,
        .ratio = sanitizeRatio(getFloat(so, "ratio") orelse 0.5),
        .a = a.?,
        .b = b.?,
    };
    return .{ .split = split };
}

fn readTitle(o: ObjectMap) Title {
    const t = getObject(o, "title") orelse {
        // Tolerate a bare string title.
        return .{ .auto = getText(o, "title") };
    };
    return .{
        .custom = getText(t, "custom"),
        .auto = getText(t, "auto"),
        .source = getEnum(TitleSource, t, "source") orelse .auto,
    };
}

fn readTab(arena: Allocator, o: ObjectMap) !Tab {
    return .{
        .id = try getUuid(arena, o, "id"),
        .ref = getRef(o),
        .title = readTitle(o),
        .pinned = getBool(o, "pinned", false),
        .panel = try readPanel(arena, getObject(o, "panel")),
        .ext = getExt(o),
    };
}

fn readPanel(arena: Allocator, maybe: ?ObjectMap) !Panel {
    const o = maybe orelse return .{ .terminal = .{} };
    const kind = getString(o, "kind") orelse "terminal";
    if (std.mem.eql(u8, kind, "terminal")) {
        var t: Terminal = .{
            .cwd = getText(o, "cwd"),
            .remote_cwd = getText(o, "remote_cwd"),
            .wsl_distro = getText(o, "wsl_distro"),
            .scrollback = getText(o, "scrollback"),
        };
        if (getFloat(o, "font_size")) |f| {
            if (std.math.isFinite(f) and f >= limits.min_font_size and f <= limits.max_font_size)
                t.font_size = @floatCast(f);
        }
        if (getObject(o, "spawn")) |sp| {
            t.spawn = .{
                .argv = try getStringList(arena, sp, "argv", std.math.maxInt(usize)),
                .shell_kind = getText(sp, "shell_kind"),
            };
        }
        return .{ .terminal = t };
    }
    if (std.mem.eql(u8, kind, "browser")) {
        var zoom: f32 = 1.0;
        if (getFloat(o, "zoom")) |z| {
            if (std.math.isFinite(z)) zoom = @floatCast(std.math.clamp(z, limits.min_browser_zoom, limits.max_browser_zoom));
        }
        return .{ .browser = .{
            .url = getText(o, "url") orelse "about:blank",
            .back = try getStringList(arena, o, "back", std.math.maxInt(usize)),
            .forward = try getStringList(arena, o, "forward", std.math.maxInt(usize)),
            .zoom = zoom,
            .profile = getText(o, "profile"),
            .devtools = getBool(o, "devtools", false),
            .muted = getBool(o, "muted", false),
        } };
    }
    if (std.mem.eql(u8, kind, "web")) {
        return .{ .web = .{
            .app = getText(o, "app") orelse "",
            .params = o.get("params") orelse .null,
            .state = o.get("state") orelse .null,
        } };
    }
    if (std.mem.eql(u8, kind, "placeholder")) {
        return .{ .placeholder = .{ .reason = getText(o, "reason") orelse "" } };
    }
    return .{ .unknown = o };
}

// JSON accessors. All tolerate missing keys and wrong types.

fn asObject(v: Value) ?ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn getObject(o: ObjectMap, k: []const u8) ?ObjectMap {
    return asObject(o.get(k) orelse return null);
}

fn getArray(o: ObjectMap, k: []const u8) []const Value {
    const v = o.get(k) orelse return &.{};
    return switch (v) {
        .array => |a| a.items,
        else => &.{},
    };
}

fn getString(o: ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// A string field capped to `limits.max_text_bytes` on a code-point
/// boundary (G6). The returned slice is arena-owned already.
fn getText(o: ObjectMap, k: []const u8) ?[]const u8 {
    const s = getString(o, k) orelse return null;
    return capText(s);
}

fn capText(s: []const u8) []const u8 {
    return limits.truncateUtf8(s, limits.max_text_bytes);
}

fn getStringList(arena: Allocator, o: ObjectMap, k: []const u8, max: usize) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (getArray(o, k)) |v| {
        if (list.items.len >= max) break;
        switch (v) {
            .string => |s| try list.append(arena, capText(s)),
            else => {},
        }
    }
    return list.items;
}

fn getUuid(arena: Allocator, o: ObjectMap, k: []const u8) !?[]const u8 {
    const s = getString(o, k) orelse return null;
    var buf: [36]u8 = undefined;
    if (!canonicalUuid(s, &buf)) return null;
    return try arena.dupe(u8, &buf);
}

fn getBool(o: ObjectMap, k: []const u8, default: bool) bool {
    const v = o.get(k) orelse return default;
    return switch (v) {
        .bool => |b| b,
        else => default,
    };
}

fn getInt(o: ObjectMap, k: []const u8) ?i64 {
    const v = o.get(k) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f) and @floor(f) == f and @abs(f) < 9.0e15) @intFromFloat(f) else null,
        else => null,
    };
}

fn getU32(o: ObjectMap, k: []const u8) ?u32 {
    const i = getInt(o, k) orelse return null;
    return std.math.cast(u32, i);
}

fn getI32(o: ObjectMap, k: []const u8) ?i32 {
    const i = getInt(o, k) orelse return null;
    return std.math.cast(i32, i);
}

fn getRef(o: ObjectMap) u32 {
    return getU32(o, "ref") orelse 0;
}

fn getFloat(o: ObjectMap, k: []const u8) ?f64 {
    const v = o.get(k) orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn getEnum(comptime E: type, o: ObjectMap, k: []const u8) ?E {
    return std.meta.stringToEnum(E, getString(o, k) orelse return null);
}

fn getExt(o: ObjectMap) Ext {
    return getObject(o, "ext");
}

/// Ratios are kept strictly inside (0, 1); non-finite becomes 0.5.
pub fn sanitizeRatio(r: f64) f32 {
    if (!std.math.isFinite(r)) return 0.5;
    return @floatCast(std.math.clamp(r, limits.min_split_ratio, limits.max_split_ratio));
}

// ── Normalize ───────────────────────────────────────────────────────

const IdSet = std.StringHashMapUnmanaged(void);
const RefSet = std.AutoHashMapUnmanaged(u32, void);

const Seen = struct {
    arena: Allocator,
    ids: IdSet = .empty,
    refs: std.EnumArray(Kind, RefSet) = .initFill(.empty),
    max_ref: std.EnumArray(Kind, u32) = .initFill(0),

    /// Clears a duplicate id. Returns false when the id was a duplicate.
    fn id(self: *Seen, slot: *?[]const u8) !bool {
        const v = slot.* orelse return true;
        const gop = try self.ids.getOrPut(self.arena, v);
        if (gop.found_existing) {
            slot.* = null;
            return false;
        }
        return true;
    }

    fn ref(self: *Seen, kind: Kind, slot: *u32) !void {
        if (slot.* == 0) return;
        const gop = try self.refs.getPtr(kind).getOrPut(self.arena, slot.*);
        if (gop.found_existing) {
            slot.* = 0;
            return;
        }
        self.max_ref.set(kind, @max(self.max_ref.get(kind), slot.*));
    }
};

/// Repairs a session in place so every cross reference resolves:
/// duplicate ids become `null` and duplicate refs 0 (the restorer mints);
/// panes without an id or without tabs are dropped; the layout loses leaves
/// that name unknown or repeated panes, and panes missing from it are
/// attached at the root; selections naming missing objects become `null`;
/// `handles.next` is raised above every ref in the file.
pub fn normalize(arena: Allocator, s: *Session) !void {
    var seen: Seen = .{ .arena = arena };
    for (s.windows) |*w| {
        _ = try seen.id(&w.id);
        try seen.ref(.window, &w.ref);
        for (w.groups) |*g| {
            _ = try seen.id(&g.id);
            try seen.ref(.workspace_group, &g.ref);
        }
        for (w.workspaces) |*ws| {
            _ = try seen.id(&ws.id);
            try seen.ref(.workspace, &ws.ref);
            try normalizeWorkspace(arena, &seen, ws);
        }
        // Group and workspace cross references within the window.
        for (w.workspaces) |*ws| {
            if (ws.group) |gid| {
                if (findGroup(w.groups, gid) == null) ws.group = null;
            }
        }
        for (w.groups) |*g| {
            if (g.anchor) |a| {
                if (findWorkspace(w.workspaces, a) == null) g.anchor = null;
            }
        }
        if (w.selected_workspace) |sel| {
            if (findWorkspace(w.workspaces, sel) == null) w.selected_workspace = null;
        }
    }
    inline for (comptime std.enums.values(Kind)) |k| {
        const m = seen.max_ref.get(k);
        if (m != std.math.maxInt(u32) and s.handles.next.get(k) <= m) s.handles.next.set(k, m + 1);
    }
}

fn normalizeWorkspace(arena: Allocator, seen: *Seen, ws: *Workspace) !void {
    // Keep panes that have a unique id and at least one tab.
    var kept: usize = 0;
    for (ws.panes) |pane_in| {
        var pane = pane_in;
        if (pane.id == null or pane.tabs.len == 0) continue;
        if (!try seen.id(&pane.id)) continue;
        try seen.ref(.pane, &pane.ref);
        for (pane.tabs) |*t| {
            _ = try seen.id(&t.id);
            try seen.ref(.surface, &t.ref);
        }
        if (pane.selected_tab) |sel| {
            if (findTab(pane.tabs, sel) == null) pane.selected_tab = null;
        }
        ws.panes[kept] = pane;
        kept += 1;
    }
    ws.panes = ws.panes[0..kept];

    // Prune the layout to known panes, each at most once.
    var used: IdSet = .empty;
    if (ws.layout) |l| ws.layout = try pruneLayout(arena, l, ws.panes, &used);
    for (ws.panes) |pane| {
        const id = pane.id.?;
        if (used.contains(id)) continue;
        try used.put(arena, id, {});
        const leaf: Layout = .{ .pane = id };
        if (ws.layout) |root| {
            if (root.depth() >= limits.max_layout_depth) {
                // Too deep to attach; keep the pane out of the layout.
                continue;
            }
            const split = try arena.create(Split);
            split.* = .{ .dir = .horizontal, .ratio = 0.5, .a = root, .b = leaf };
            ws.layout = .{ .split = split };
        } else {
            ws.layout = leaf;
        }
    }
    // Panes the layout could not hold are dropped.
    kept = 0;
    for (ws.panes) |pane| {
        if (ws.layout != null and layoutContains(ws.layout.?, pane.id.?)) {
            ws.panes[kept] = pane;
            kept += 1;
        }
    }
    ws.panes = ws.panes[0..kept];
    if (ws.panes.len == 0) ws.layout = null;

    if (ws.focused_pane) |f| {
        if (findPane(ws.panes, f) == null) ws.focused_pane = null;
    }
    if (ws.zoomed_pane) |z| {
        if (findPane(ws.panes, z) == null) ws.zoomed_pane = null;
    }
}

fn pruneLayout(arena: Allocator, l: Layout, panes: []const Pane, used: *IdSet) !?Layout {
    switch (l) {
        .pane => |id| {
            if (findPane(panes, id) == null) return null;
            const gop = try used.getOrPut(arena, id);
            if (gop.found_existing) return null;
            return l;
        },
        .split => |s| {
            const a = try pruneLayout(arena, s.a, panes, used);
            const b = try pruneLayout(arena, s.b, panes, used);
            if (a == null) return b;
            if (b == null) return a;
            s.a = a.?;
            s.b = b.?;
            s.ratio = sanitizeRatio(s.ratio);
            return l;
        },
    }
}

pub fn layoutContains(l: Layout, id: []const u8) bool {
    return switch (l) {
        .pane => |p| std.mem.eql(u8, p, id),
        .split => |s| layoutContains(s.a, id) or layoutContains(s.b, id),
    };
}

pub fn findPane(panes: []const Pane, id: []const u8) ?*const Pane {
    for (panes) |*p| if (p.id) |pid| if (std.mem.eql(u8, pid, id)) return p;
    return null;
}

pub fn findTab(tabs: []const Tab, id: []const u8) ?*const Tab {
    for (tabs) |*t| if (t.id) |tid| if (std.mem.eql(u8, tid, id)) return t;
    return null;
}

pub fn findWorkspace(wss: []const Workspace, id: []const u8) ?*const Workspace {
    for (wss) |*w| if (w.id) |wid| if (std.mem.eql(u8, wid, id)) return w;
    return null;
}

pub fn findGroup(groups: []const Group, id: []const u8) ?*const Group {
    for (groups) |*g| if (g.id) |gid| if (std.mem.eql(u8, gid, id)) return g;
    return null;
}

// ── Writer ──────────────────────────────────────────────────────────

pub const WriteOptions = struct {
    pretty: bool = false,
    /// Leave out fields that change on every save (`created_at`,
    /// `clean_exit`, `scrollback_captured_at`, sidebar scroll) so the output
    /// can be fingerprinted (ADR-9.3).
    omit_volatile: bool = false,
};

pub const WriteError = std.Io.Writer.Error;

/// Writes `s` as a v3 document. Key order is fixed, so equal sessions
/// produce equal bytes.
pub fn write(s: *const Session, w: *std.Io.Writer, opts: WriteOptions) WriteError!void {
    var jw: std.json.Stringify = .{
        .writer = w,
        .options = .{ .whitespace = if (opts.pretty) .indent_2 else .minified },
    };
    try writeSession(&jw, s, opts);
}

pub fn writeAlloc(gpa: Allocator, s: *const Session, opts: WriteOptions) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    write(s, &aw.writer, opts) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Wyhash of the document without volatile fields: the autosave skips the
/// write when it equals the previous fingerprint.
pub fn fingerprint(s: *const Session) u64 {
    var buf: [512]u8 = undefined;
    var h: std.Io.Writer.Hashing(std.hash.Wyhash) = .initHasher(.init(0), &buf);
    write(s, &h.writer, .{ .omit_volatile = true }) catch unreachable;
    h.writer.flush() catch unreachable;
    return h.hasher.final();
}

fn writeSession(jw: *std.json.Stringify, s: *const Session, opts: WriteOptions) WriteError!void {
    try jw.beginObject();
    try field(jw, "schema", schema_name);
    try field(jw, "version", current_version);
    try field(jw, "app_version", s.app_version);
    try field(jw, "channel", s.channel);
    if (!opts.omit_volatile) {
        try field(jw, "created_at", s.created_at);
        try field(jw, "clean_exit", s.clean_exit);
        try field(jw, "scrollback_captured_at", s.scrollback_captured_at);
    }
    try jw.objectField("handles");
    try jw.beginObject();
    try jw.objectField("next");
    try jw.beginObject();
    inline for (std.meta.fields(HandleNext)) |f| try field(jw, f.name, @field(s.handles.next, f.name));
    try jw.endObject();
    try jw.endObject();
    try jw.objectField("windows");
    try jw.beginArray();
    for (s.windows) |*w| try writeWindow(jw, w, opts);
    try jw.endArray();
    try jw.endObject();
}

fn writeWindow(jw: *std.json.Stringify, w: *const Window, opts: WriteOptions) WriteError!void {
    try jw.beginObject();
    try field(jw, "id", w.id);
    try field(jw, "ref", w.ref);
    try jw.objectField("placement");
    if (w.placement) |p| {
        try jw.beginObject();
        try field(jw, "x", p.x);
        try field(jw, "y", p.y);
        try field(jw, "w", p.w);
        try field(jw, "h", p.h);
        try field(jw, "maximized", p.maximized);
        try field(jw, "fullscreen", p.fullscreen);
        try field(jw, "monitor", p.monitor);
        try field(jw, "dpi", p.dpi);
        try jw.endObject();
    } else try jw.write(null);
    try jw.objectField("sidebar");
    try jw.beginObject();
    try field(jw, "visible", w.sidebar.visible);
    try field(jw, "width", w.sidebar.width);
    if (!opts.omit_volatile) try field(jw, "scroll", w.sidebar.scroll);
    try jw.endObject();
    try jw.objectField("right_sidebar");
    try jw.beginObject();
    try field(jw, "visible", w.right_sidebar.visible);
    try field(jw, "width", w.right_sidebar.width);
    try field(jw, "mode", w.right_sidebar.mode);
    try jw.endObject();
    try field(jw, "selected_workspace", w.selected_workspace);
    try jw.objectField("groups");
    try jw.beginArray();
    for (w.groups) |g| {
        try jw.beginObject();
        try field(jw, "id", g.id);
        try field(jw, "ref", g.ref);
        try field(jw, "name", g.name);
        try field(jw, "collapsed", g.collapsed);
        try field(jw, "pinned", g.pinned);
        try field(jw, "anchor", g.anchor);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.objectField("workspaces");
    try jw.beginArray();
    for (w.workspaces) |*ws| try writeWorkspace(jw, ws);
    try jw.endArray();
    try writeExt(jw, w.ext);
    try jw.endObject();
}

fn writeWorkspace(jw: *std.json.Stringify, ws: *const Workspace) WriteError!void {
    try jw.beginObject();
    try field(jw, "id", ws.id);
    try field(jw, "ref", ws.ref);
    try writeTitle(jw, ws.title);
    try field(jw, "description", ws.description);
    try field(jw, "cwd", ws.cwd);
    try jw.objectField("env");
    try jw.beginObject();
    for (ws.env) |e| try field(jw, e.name, e.value);
    try jw.endObject();
    try field(jw, "group", ws.group);
    try field(jw, "pinned", ws.pinned);
    try field(jw, "focused_pane", ws.focused_pane);
    try field(jw, "zoomed_pane", ws.zoomed_pane);
    try jw.objectField("layout");
    if (ws.layout) |l| {
        if (l.depth() <= limits.max_layout_depth) try writeLayout(jw, l) else try jw.write(null);
    } else try jw.write(null);
    try jw.objectField("panes");
    try jw.beginArray();
    for (ws.panes) |*p| {
        try jw.beginObject();
        try field(jw, "id", p.id);
        try field(jw, "ref", p.ref);
        try field(jw, "selected_tab", p.selected_tab);
        try jw.objectField("tabs");
        try jw.beginArray();
        for (p.tabs) |*t| try writeTab(jw, t);
        try jw.endArray();
        try writeExt(jw, p.ext);
        try jw.endObject();
    }
    try jw.endArray();
    try writeExt(jw, ws.ext);
    try jw.endObject();
}

fn writeLayout(jw: *std.json.Stringify, l: Layout) WriteError!void {
    try jw.beginObject();
    switch (l) {
        .pane => |id| try field(jw, "pane", id),
        .split => |s| {
            try jw.objectField("split");
            try jw.beginObject();
            try field(jw, "dir", @tagName(s.dir));
            try jw.objectField("ratio");
            try writeF32(jw, s.ratio, 0.5);
            try jw.objectField("a");
            try writeLayout(jw, s.a);
            try jw.objectField("b");
            try writeLayout(jw, s.b);
            try jw.endObject();
        },
    }
    try jw.endObject();
}

fn writeTab(jw: *std.json.Stringify, t: *const Tab) WriteError!void {
    try jw.beginObject();
    try field(jw, "id", t.id);
    try field(jw, "ref", t.ref);
    try writeTitle(jw, t.title);
    try field(jw, "pinned", t.pinned);
    try jw.objectField("panel");
    switch (t.panel) {
        .terminal => |p| {
            try jw.beginObject();
            try field(jw, "kind", "terminal");
            try field(jw, "cwd", p.cwd);
            try field(jw, "remote_cwd", p.remote_cwd);
            try field(jw, "wsl_distro", p.wsl_distro);
            try jw.objectField("spawn");
            if (p.spawn) |sp| {
                try jw.beginObject();
                try field(jw, "argv", sp.argv);
                try field(jw, "shell_kind", sp.shell_kind);
                try jw.endObject();
            } else try jw.write(null);
            try jw.objectField("font_size");
            if (p.font_size) |f| try writeF32(jw, f, null) else try jw.write(null);
            try field(jw, "scrollback", p.scrollback);
            try jw.endObject();
        },
        .browser => |p| {
            try jw.beginObject();
            try field(jw, "kind", "browser");
            try field(jw, "url", p.url);
            try field(jw, "back", p.back);
            try field(jw, "forward", p.forward);
            try jw.objectField("zoom");
            try writeF32(jw, p.zoom, 1.0);
            try field(jw, "profile", p.profile);
            try field(jw, "devtools", p.devtools);
            try field(jw, "muted", p.muted);
            try jw.endObject();
        },
        .web => |p| {
            try jw.beginObject();
            try field(jw, "kind", "web");
            try field(jw, "app", p.app);
            try field(jw, "params", p.params);
            try field(jw, "state", p.state);
            try jw.endObject();
        },
        .placeholder => |p| {
            try jw.beginObject();
            try field(jw, "kind", "placeholder");
            try field(jw, "reason", p.reason);
            try jw.endObject();
        },
        .unknown => |o| try jw.write(Value{ .object = o }),
    }
    try writeExt(jw, t.ext);
    try jw.endObject();
}

fn writeTitle(jw: *std.json.Stringify, t: Title) WriteError!void {
    try jw.objectField("title");
    try jw.beginObject();
    try field(jw, "custom", t.custom);
    try field(jw, "auto", t.auto);
    try field(jw, "source", @tagName(t.source));
    try jw.endObject();
}

fn writeExt(jw: *std.json.Stringify, ext: Ext) WriteError!void {
    try jw.objectField("ext");
    if (ext) |m| try jw.write(Value{ .object = m }) else {
        try jw.beginObject();
        try jw.endObject();
    }
}

/// Shortest decimal that round-trips the f32 (`0.6`, not
/// `0.6000000238418579`). Non-finite values write `fallback`.
fn writeF32(jw: *std.json.Stringify, v: f32, fallback: ?f32) WriteError!void {
    if (std.math.isFinite(v)) return jw.print("{d}", .{v});
    if (fallback) |f| return jw.print("{d}", .{f});
    return jw.write(null);
}

fn field(jw: *std.json.Stringify, name: []const u8, v: anytype) WriteError!void {
    try jw.objectField(name);
    try jw.write(v);
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

const full_input = @embedFile("testdata/v3_full.json");
const full_golden = @embedFile("testdata/v3_full.golden.json");

fn expectWritten(s: *const Session, opts: WriteOptions, expected: []const u8) !void {
    const out = try writeAlloc(testing.allocator, s, opts);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "unit: session: golden v3 document reads and writes canonically" {
    var p = try parse(testing.allocator, full_input, .{}, null);
    defer p.deinit();
    try expectWritten(&p.session, .{ .pretty = true }, full_golden);

    // The canonical form is a fixed point.
    var p2 = try parse(testing.allocator, full_golden, .{}, null);
    defer p2.deinit();
    try expectWritten(&p2.session, .{ .pretty = true }, full_golden);
}

test "unit: session: golden v3 fields decode to the documented types" {
    var p = try parse(testing.allocator, full_input, .{}, null);
    defer p.deinit();
    const s = p.session;
    try testing.expectEqualStrings("stable", s.channel);
    try testing.expectEqual(@as(u32, 77), s.handles.next.surface);
    try testing.expectEqual(@as(usize, 1), s.windows.len);
    const w = s.windows[0];
    try testing.expectEqual(@as(i32, -8), w.placement.?.x);
    try testing.expectEqualStrings("\\\\.\\DISPLAY1", w.placement.?.monitor.?);
    // Braced UUID canonicalized.
    try testing.expectEqualStrings("33333333-3333-4333-8333-333333333333", w.groups[0].id.?);
    const ws = w.workspaces[0];
    try testing.expectEqualStrings("api ✓", ws.title.custom.?);
    try testing.expectEqual(TitleSource.user, ws.title.source);
    // Non-string env values are dropped.
    try testing.expectEqual(@as(usize, 1), ws.env.len);
    try testing.expectEqualStrings("AWS_PROFILE", ws.env[0].name);
    try testing.expectApproxEqAbs(@as(f32, 0.6), ws.layout.?.split.ratio, 1e-6);
    const t0 = ws.panes[0].tabs[0];
    try testing.expectEqualStrings("pwsh.exe", t0.panel.terminal.spawn.?.argv[0]);
    try testing.expectEqual(@as(f32, 13), t0.panel.terminal.font_size.?);
    try testing.expectEqualStrings("claude", extGet(t0.ext, "agents").?.object.get("kind").?.string);
    const b = ws.panes[0].tabs[1].panel.browser;
    try testing.expectEqual(@as(f32, 1.25), b.zoom);
    try testing.expect(b.devtools);
    try testing.expectEqualStrings("markdown", ws.panes[1].tabs[0].panel.web.app);
    try testing.expectEqualStrings("hibernated", ws.panes[1].tabs[1].panel.placeholder.reason);
    try testing.expect(ws.panes[1].tabs[2].panel == .unknown);
}

test "unit: session: minimal session writes the exact minified golden" {
    const golden =
        \\{"schema":"wmux-session","version":3,"app_version":"1.2.0","channel":"nightly","created_at":"2026-10-15T10:00:00.000Z","clean_exit":false,"scrollback_captured_at":null,"handles":{"next":{"window":2,"workspace":2,"workspace_group":1,"pane":2,"surface":2}},"windows":[{"id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","ref":1,"placement":null,"sidebar":{"visible":true,"width":240,"scroll":0},"right_sidebar":{"visible":false,"width":300,"mode":null},"selected_workspace":null,"groups":[],"workspaces":[{"id":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB","ref":1,"title":{"custom":null,"auto":"cmd","source":"process"},"description":null,"cwd":null,"env":{},"group":null,"pinned":false,"focused_pane":null,"zoomed_pane":null,"layout":{"pane":"CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"},"panes":[{"id":"CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC","ref":1,"selected_tab":null,"tabs":[{"id":"DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD","ref":1,"title":{"custom":null,"auto":null,"source":"auto"},"pinned":false,"panel":{"kind":"terminal","cwd":"C:\\Users\\me","remote_cwd":null,"wsl_distro":null,"spawn":null,"font_size":null,"scrollback":null},"ext":{}}],"ext":{}}],"ext":{}}],"ext":{}}]}
    ;
    var tabs = [_]Tab{.{ .id = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD", .ref = 1, .panel = .{ .terminal = .{ .cwd = "C:\\Users\\me" } } }};
    var panes = [_]Pane{.{ .id = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC", .ref = 1, .tabs = &tabs }};
    var wss = [_]Workspace{.{
        .id = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
        .ref = 1,
        .title = .{ .auto = "cmd", .source = .process },
        .layout = .{ .pane = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC" },
        .panes = &panes,
    }};
    var wins = [_]Window{.{ .id = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", .ref = 1, .workspaces = &wss }};
    var s: Session = .{
        .app_version = "1.2.0",
        .channel = "nightly",
        .created_at = "2026-10-15T10:00:00.000Z",
        .windows = &wins,
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try normalize(arena.allocator(), &s);
    try expectWritten(&s, .{}, golden);

    var p = try parse(testing.allocator, golden, .{}, null);
    defer p.deinit();
    try expectWritten(&p.session, .{}, golden);
}

test "unit: session: a version from the future is refused" {
    var diag: Diagnostics = .{};
    try testing.expectError(error.FutureVersion, parse(testing.allocator,
        \\{"schema":"wmux-session","version":4,"windows":"whatever"}
    , .{}, &diag));
    try testing.expectEqual(@as(?i64, 4), diag.version);
    diag = .{};
    try testing.expectError(error.FutureVersion, parse(testing.allocator,
        \\{"schema":"wmux-session","version":99999999999}
    , .{}, &diag));
    try testing.expectEqual(@as(?i64, 99999999999), diag.version);
}

test "unit: session: header classification" {
    const cases = [_]struct { []const u8, ParseError }{
        .{ "{\"schema\":\"wmux-session\",\"version\":2}", error.Corrupt },
        .{ "{\"schema\":\"wmux-session\",\"version\":\"3\"}", error.Corrupt },
        .{ "{\"schema\":\"wmux-session\"}", error.Corrupt },
        .{ "{\"schema\":\"wmux-session\",\"version\":3.5}", error.Corrupt },
        .{ "{\"schema\":7,\"version\":3}", error.Corrupt },
        .{ "{\"schema\":\"cmux-session\",\"version\":3}", error.NotSession },
        .{ "{\"version\":1,\"windows\":[]}", error.Corrupt },
        .{ "{\"version\":2,\"workspaces\":[]}", error.LegacyVersion },
        .{ "{\"workspaces\":[]}", error.LegacyVersion },
    };
    for (cases) |c| try testing.expectError(c[1], parse(testing.allocator, c[0], .{}, null));
    var diag: Diagnostics = .{};
    _ = parse(testing.allocator, "{\"workspaces\":[]}", .{}, &diag) catch {};
    try testing.expectEqual(@as(?i64, 1), diag.version);
    // Integral float version is accepted.
    var p = try parse(testing.allocator, "{\"schema\":\"wmux-session\",\"version\":3.0}", .{}, null);
    p.deinit();
}

test "unit: session: corrupt inputs are rejected without leaks" {
    const bad = [_][]const u8{ "", " ", "{", "}", "[]", "null", "\"x\"", "3", "{\"a\":}", "\xff\xfe{}", "{\"schema\":\"wmux-session\",\"version\":3,}" };
    for (bad) |b| try testing.expectError(error.Corrupt, parse(testing.allocator, b, .{}, null));
    // Every strict prefix of a valid document is corrupt.
    const doc = "{\"schema\":\"wmux-session\",\"version\":3,\"windows\":[{\"id\":\"11111111-1111-4111-8111-111111111111\",\"workspaces\":[{\"panes\":[]}]}]}";
    for (0..doc.len) |n| try testing.expectError(error.Corrupt, parse(testing.allocator, doc[0..n], .{}, null));
    var p = try parse(testing.allocator, doc, .{}, null);
    p.deinit();
}

test "unit: session: wrongly typed fields fall back to defaults" {
    var p = try parse(testing.allocator,
        \\{"schema":"wmux-session","version":3,"app_version":5,"clean_exit":"yes",
        \\ "handles":{"next":{"window":-3,"pane":"9","surface":0}},
        \\ "windows":[7,{"id":"not-a-uuid","ref":-1,"placement":[],"sidebar":{"width":-5,"visible":1},
        \\   "groups":"x","workspaces":[null,{"id":"22222222-2222-4222-8222-222222222222","ref":4294967296,
        \\   "title":"bare","env":[],"layout":{"split":{"dir":"diagonal","ratio":"0.5","a":{"pane":"44444444-4444-4444-8444-444444444441"},"b":{"pane":5}}},
        \\   "panes":[{"id":"44444444-4444-4444-8444-444444444441","tabs":[{"panel":{"kind":"browser","url":7,"zoom":1000,"back":["a",1,null]}},{"panel":"terminal"},{"panel":{"kind":"terminal","font_size":-4}}]}]}]}]}
    , .{}, null);
    defer p.deinit();
    const s = p.session;
    try testing.expectEqualStrings("", s.app_version);
    try testing.expect(!s.clean_exit);
    try testing.expectEqual(@as(u32, 1), s.handles.next.window);
    try testing.expectEqual(@as(usize, 1), s.windows.len);
    const w = s.windows[0];
    try testing.expect(w.id == null);
    try testing.expectEqual(@as(u32, 0), w.ref);
    try testing.expect(w.placement == null);
    try testing.expectEqual(@as(u32, 240), w.sidebar.width);
    try testing.expect(w.sidebar.visible);
    try testing.expectEqual(@as(usize, 1), w.workspaces.len);
    const ws = w.workspaces[0];
    try testing.expectEqual(@as(u32, 0), ws.ref);
    try testing.expectEqualStrings("bare", ws.title.auto.?);
    // Broken split side collapsed to the leaf.
    try testing.expectEqualStrings("44444444-4444-4444-8444-444444444441", ws.layout.?.pane);
    const tabs = ws.panes[0].tabs;
    try testing.expectEqual(@as(usize, 3), tabs.len);
    try testing.expectEqualStrings("about:blank", tabs[0].panel.browser.url);
    try testing.expectEqual(@as(f32, 5.0), tabs[0].panel.browser.zoom);
    try testing.expectEqual(@as(usize, 1), tabs[0].panel.browser.back.len);
    try testing.expect(tabs[1].panel == .terminal);
    try testing.expect(tabs[2].panel.terminal.font_size == null);
}

test "unit: session: ratios round-trip within 1%" {
    const ratios = [_]f32{ 0.5, 0.6, 1.0 / 3.0, 0.123456, 0.01, 0.99, 0.7071 };
    for (ratios) |r| {
        var split: Split = .{ .ratio = r, .a = .{ .pane = "44444444-4444-4444-8444-444444444441" }, .b = .{ .pane = "44444444-4444-4444-8444-444444444442" } };
        var tabs = [_]Tab{.{}};
        var tabs2 = [_]Tab{.{}};
        var panes = [_]Pane{ .{ .id = "44444444-4444-4444-8444-444444444441", .tabs = &tabs }, .{ .id = "44444444-4444-4444-8444-444444444442", .tabs = &tabs2 } };
        var wss = [_]Workspace{.{ .layout = .{ .split = &split }, .panes = &panes }};
        var wins = [_]Window{.{ .workspaces = &wss }};
        const s: Session = .{ .windows = &wins };
        const out = try writeAlloc(testing.allocator, &s, .{});
        defer testing.allocator.free(out);
        var p = try parse(testing.allocator, out, .{}, null);
        defer p.deinit();
        const got = p.session.windows[0].workspaces[0].layout.?.split.ratio;
        try testing.expect(@abs(got - r) <= 0.01 * r);
        try testing.expectEqual(r, got); // in fact exact
    }
}

test "unit: session: normalize repairs dangling and duplicate references" {
    var p = try parse(testing.allocator,
        \\{"schema":"wmux-session","version":3,"handles":{"next":{"pane":2}},"windows":[{"id":"11111111-1111-4111-8111-111111111111","ref":5,
        \\ "selected_workspace":"99999999-9999-4999-8999-999999999999",
        \\ "groups":[{"id":"33333333-3333-4333-8333-333333333333","anchor":"99999999-9999-4999-8999-999999999999"}],
        \\ "workspaces":[{"id":"22222222-2222-4222-8222-222222222222","ref":1,"group":"88888888-8888-4888-8888-888888888888",
        \\   "focused_pane":"44444444-4444-4444-8444-444444444449","zoomed_pane":"44444444-4444-4444-8444-444444444442",
        \\   "layout":{"split":{"ratio":0.3,"a":{"pane":"44444444-4444-4444-8444-444444444441"},
        \\     "b":{"split":{"a":{"pane":"44444444-4444-4444-8444-444444444441"},"b":{"pane":"44444444-4444-4444-8444-444444444449"}}}}},
        \\   "panes":[
        \\     {"id":"44444444-4444-4444-8444-444444444441","ref":30,"selected_tab":"55555555-5555-4555-8555-555555555559","tabs":[{"id":"55555555-5555-4555-8555-555555555551","ref":3},{"id":"55555555-5555-4555-8555-555555555551","ref":3}]},
        \\     {"id":"44444444-4444-4444-8444-444444444441","tabs":[{}]},
        \\     {"id":"44444444-4444-4444-8444-444444444442","ref":30,"tabs":[{}]},
        \\     {"id":"44444444-4444-4444-8444-444444444443","tabs":[]},
        \\     {"tabs":[{}]}
        \\   ]},
        \\  {"id":"22222222-2222-4222-8222-222222222222","ref":1}]}]}
    , .{}, null);
    defer p.deinit();
    const w = p.session.windows[0];
    try testing.expect(w.selected_workspace == null);
    try testing.expect(w.groups[0].anchor == null);
    const ws = w.workspaces[0];
    try testing.expect(ws.group == null);
    try testing.expect(ws.focused_pane == null);
    try testing.expectEqualStrings("44444444-4444-4444-8444-444444444442", ws.zoomed_pane.?);
    // Duplicate pane, empty pane and id-less pane dropped.
    try testing.expectEqual(@as(usize, 2), ws.panes.len);
    try testing.expect(ws.panes[0].selected_tab == null);
    try testing.expect(ws.panes[0].tabs[1].id == null);
    try testing.expectEqual(@as(u32, 0), ws.panes[0].tabs[1].ref);
    try testing.expectEqual(@as(u32, 0), ws.panes[1].ref);
    // Layout: duplicate and unknown leaves pruned, orphan pane attached.
    const root = ws.layout.?.split;
    try testing.expectEqualStrings("44444444-4444-4444-8444-444444444441", root.a.pane);
    try testing.expectEqualStrings("44444444-4444-4444-8444-444444444442", root.b.pane);
    try testing.expectApproxEqAbs(@as(f32, 0.5), root.ratio, 1e-6);
    // Second workspace had a duplicate id and ref.
    try testing.expect(w.workspaces[1].id == null);
    try testing.expectEqual(@as(u32, 0), w.workspaces[1].ref);
    // handles.next raised above the refs in the file.
    try testing.expectEqual(@as(u32, 31), p.session.handles.next.pane);
    try testing.expectEqual(@as(u32, 6), p.session.handles.next.window);
    try testing.expectEqual(@as(u32, 4), p.session.handles.next.surface);
}

test "unit: session: pathologically deep layouts are bounded" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const w = &aw.writer;
    const depth = 300;
    try w.writeAll("{\"schema\":\"wmux-session\",\"version\":3,\"windows\":[{\"workspaces\":[{\"layout\":");
    for (0..depth) |i| try w.print("{{\"split\":{{\"a\":{{\"pane\":\"44444444-4444-4444-8444-{d:0>12}\"}},\"b\":", .{i});
    try w.print("{{\"pane\":\"44444444-4444-4444-8444-{d:0>12}\"}}", .{depth});
    for (0..depth) |_| try w.writeAll("}}");
    try w.writeAll(",\"panes\":[");
    for (0..depth + 1) |i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"id\":\"44444444-4444-4444-8444-{d:0>12}\",\"tabs\":[{{}}]}}", .{i});
    }
    try w.writeAll("]}]}]}");
    var p = try parse(testing.allocator, aw.written(), .{}, null);
    defer p.deinit();
    const ws = p.session.windows[0].workspaces[0];
    try testing.expect(ws.layout.?.depth() <= limits.max_layout_depth);
    for (ws.panes) |pane| try testing.expect(layoutContains(ws.layout.?, pane.id.?));
    const out = try writeAlloc(testing.allocator, &p.session, .{ .pretty = true });
    defer testing.allocator.free(out);
    var p2 = try parse(testing.allocator, out, .{}, null);
    defer p2.deinit();
    try testing.expectEqual(ws.panes.len, p2.session.windows[0].workspaces[0].panes.len);
}

test "unit: session: huge text fields are capped on a code-point boundary" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"schema\":\"wmux-session\",\"version\":3,\"channel\":\"");
    for (0..limits.max_text_bytes) |_| try aw.writer.writeAll("é");
    try aw.writer.writeAll("\"}");
    var p = try parse(testing.allocator, aw.written(), .{}, null);
    defer p.deinit();
    try testing.expect(p.session.channel.len <= limits.max_text_bytes);
    try testing.expect(p.session.channel.len >= limits.max_text_bytes - 1);
    try testing.expect(std.unicode.utf8ValidateSlice(p.session.channel));
}

test "unit: session: fingerprint ignores volatile fields only" {
    var p = try parse(testing.allocator, full_input, .{}, null);
    defer p.deinit();
    const base = fingerprint(&p.session);
    try testing.expectEqual(base, fingerprint(&p.session));
    p.session.created_at = "2030-01-01T00:00:00.000Z";
    p.session.clean_exit = false;
    p.session.scrollback_captured_at = "2030-01-01T00:00:00.000Z";
    p.session.windows[0].sidebar.scroll = 999;
    try testing.expectEqual(base, fingerprint(&p.session));
    p.session.windows[0].workspaces[0].layout.?.split.ratio = 0.61;
    try testing.expect(base != fingerprint(&p.session));
}

test "unit: session: ext helpers add and read feature keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ext: Ext = null;
    try testing.expect(extGet(ext, "status") == null);
    try extPut(arena.allocator(), &ext, "status", .{ .integer = 3 });
    try testing.expectEqual(@as(i64, 3), extGet(ext, "status").?.integer);
    var tabs = [_]Tab{.{ .ext = ext }};
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try writeTab(&jw, &tabs[0]);
    try testing.expect(std.mem.endsWith(u8, aw.written(), "\"ext\":{\"status\":3}}"));
}

test "unit: session: uuid canonicalization and minting" {
    var buf: [36]u8 = undefined;
    try testing.expect(canonicalUuid("{abcdef01-2345-4678-9abc-def012345678}", &buf));
    try testing.expectEqualStrings("ABCDEF01-2345-4678-9ABC-DEF012345678", &buf);
    const bad = [_][]const u8{ "", "abcdef01-2345-4678-9abc-def01234567", "abcdef01x2345-4678-9abc-def012345678", "abcdef01-2345-4678-9abc-def01234567g", "{abcdef01-2345-4678-9abc-def012345678", "ééééééé-2345-4678-9abc-def012345678" };
    for (bad) |b| try testing.expect(!canonicalUuid(b, &buf));
    var prng = std.Random.DefaultPrng.init(42);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        seen.deinit(testing.allocator);
    }
    for (0..256) |_| {
        var id: [36]u8 = undefined;
        mintUuid(prng.random(), &id);
        var canon: [36]u8 = undefined;
        try testing.expect(canonicalUuid(&id, &canon));
        try testing.expectEqualStrings(&id, &canon);
        try testing.expectEqual(@as(u8, '4'), id[14]);
        try testing.expect(std.mem.indexOfScalar(u8, "89AB", id[19]) != null);
        const gop = try seen.getOrPut(testing.allocator, &id);
        try testing.expect(!gop.found_existing);
        gop.key_ptr.* = try testing.allocator.dupe(u8, &id);
    }
}

test "unit: session: timestamps format and parse" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", formatTimestamp(0, &buf));
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", formatTimestamp(-5, &buf));
    try testing.expectEqualStrings("2026-10-15T10:00:00.123Z", formatTimestamp(1_792_058_400_123, &buf));
    try testing.expectEqualStrings("2024-02-29T23:59:59.999Z", formatTimestamp(1_709_251_199_999, &buf));
    try testing.expectEqual(@as(?i64, 1_792_058_400_123), parseTimestamp("2026-10-15T10:00:00.123Z"));
    try testing.expectEqual(@as(?i64, 1_792_058_400_000), parseTimestamp("2026-10-15T10:00:00Z"));
    try testing.expectEqual(@as(?i64, 1_792_058_400_100), parseTimestamp("2026-10-15T10:00:00.1Z"));
    try testing.expectEqual(@as(?i64, 1_792_058_400_123), parseTimestamp("2026-10-15T10:00:00.123456789Z"));
    const bad = [_][]const u8{ "", "2026-10-15", "2026-13-15T10:00:00Z", "2025-02-29T10:00:00Z", "2026-10-15T24:00:00Z", "2026-10-15T10:00:00.Z", "2026-10-15T10:00:00+01:00", "1969-12-31T23:59:59Z", "2026-10-15T10:00:00.12aZ" };
    for (bad) |b| try testing.expect(parseTimestamp(b) == null);
    var ms: i64 = 0;
    while (ms < 4_000_000_000_000) : (ms += 97_654_321_987) {
        try testing.expectEqual(@as(?i64, ms), parseTimestamp(formatTimestamp(ms, &buf)));
    }
}
