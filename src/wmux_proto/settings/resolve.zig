//! Layered settings resolution: defaults, legacy Ghostty keys, cmux.json,
//! wmux.json, project files, policy (ADR-5.1). Pure: callers read the files,
//! the explicitly set Ghostty keys and the registry policy values, then hand
//! them in as data. Also holds the pure parts of the offline `config` CLI
//! (ADR-5.6): config file locations, project/pack discovery candidates,
//! value parsing for `set`, `toggle`/`cycle` helpers and legacy shorthands.

const std = @import("std");
const jsonc = @import("../jsonc.zig");
const spec_mod = @import("spec.zig");
const validate = @import("validate.zig");
const manifest = @import("specs_manifest.zig");

const Spec = spec_mod.Spec;
const Node = jsonc.Node;
const Allocator = std.mem.Allocator;

/// Where an effective value came from (`config get --json` `source`).
/// Declared in precedence order, lowest first.
pub const Source = enum {
    default,
    ghostty,
    cmux_json,
    wmux_json,
    project,
    policy,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .default => "default",
            .ghostty => "ghostty",
            .cmux_json => "cmux.json",
            .wmux_json => "wmux.json",
            .project => "project",
            .policy => "policy",
        };
    }
};

/// One parsed input. Packs listed by a file are passed as extra layers with
/// the listing file's source, placed before it (ADR-5.1 row 5). Layers are
/// only read during `resolve`; the result keeps no reference to them.
pub const Layer = struct {
    source: Source,
    root: *const Node,
    /// Text `root` was parsed from (positions); may be empty.
    src: []const u8 = "",
};

// ---------------------------------------------------------------------------
// Policy (ADR-5.7): values read by settings/policy.zig from
// HKLM/HKCU\Software\Policies\wmux, named by setting path.

pub const PolicyHive = enum { hkcu, hklm };

pub const PolicyValue = struct {
    path: []const u8,
    hive: PolicyHive,
    data: union(enum) {
        /// REG_SZ holding a JSON literal.
        json: []const u8,
        /// REG_DWORD for booleans and integers.
        dword: u32,
    },
};

/// A layer value that did not take effect, and why.
pub const Rejected = struct {
    path: []const u8,
    source: Source,
    message: []const u8,
    pos: ?jsonc.Pos = null,
};

pub const Entry = struct {
    /// Points into the `specs` passed to `resolve` (the static registry).
    spec: *const Spec,
    /// Effective value, deep-copied into the `Resolved` arena.
    value: Node,
    /// Minified JSON of `value`.
    json: []const u8,
    source: Source,
    /// A policy value exists for this path: Settings shows it locked and the
    /// CLI refuses writes, even when the forced value itself is invalid.
    locked: bool,

    pub fn configured(self: *const Entry) bool {
        return self.source != .default;
    }
};

pub const Resolved = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,
    rejected: []const Rejected,

    pub fn deinit(self: *Resolved) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn get(self: *const Resolved, path: []const u8) ?*const Entry {
        for (self.entries) |*e| if (std.mem.eql(u8, e.spec.path, path)) return e;
        return null;
    }

    pub fn getBool(self: *const Resolved, path: []const u8) ?bool {
        return (self.get(path) orelse return null).value.asBool();
    }

    pub fn getInt(self: *const Resolved, path: []const u8) ?i64 {
        return (self.get(path) orelse return null).value.asInt();
    }

    pub fn getFloat(self: *const Resolved, path: []const u8) ?f64 {
        return (self.get(path) orelse return null).value.asFloat();
    }

    pub fn getString(self: *const Resolved, path: []const u8) ?[]const u8 {
        return (self.get(path) orelse return null).value.asString();
    }

    pub fn isLocked(self: *const Resolved, path: []const u8) bool {
        return if (self.get(path)) |e| e.locked else false;
    }
};

fn rank(s: Source) u8 {
    return @intFromEnum(s);
}

/// Resolves every spec in `specs`. `layers` may come in any order; equal
/// sources keep their relative order (later wins). Per ADR-5.3 a value with
/// a type/range error falls back to the next lower layer and is listed in
/// `rejected`; so are project values for global-only keys. The result owns
/// its values: callers may free the layers (and the policy strings) as soon
/// as this returns, which a reload snapshot needs. `specs` must outlive it.
pub fn resolve(
    gpa: Allocator,
    specs: []const Spec,
    layers: []const Layer,
    policy: []const PolicyValue,
) Allocator.Error!Resolved {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const ordered = try arena.dupe(Layer, layers);
    std.sort.insertion(Layer, ordered, {}, struct {
        fn lt(_: void, a: Layer, b: Layer) bool {
            return rank(a.source) < rank(b.source);
        }
    }.lt);

    var rejected: std.ArrayList(Rejected) = .empty;
    const entries = try arena.alloc(Entry, specs.len);
    for (specs, entries) |*s, *e| {
        e.* = try resolveOne(arena, s, ordered, policy, &rejected);
    }
    return .{ .arena = arena_state, .entries = entries, .rejected = try rejected.toOwnedSlice(arena) };
}

fn scopeAllows(s: *const Spec, source: Source) bool {
    return switch (source) {
        .project => s.scope.allowsProject(),
        .cmux_json, .wmux_json => s.scope.allowsGlobal(),
        .default, .ghostty, .policy => true,
    };
}

fn resolveOne(
    arena: Allocator,
    s: *const Spec,
    layers: []const Layer,
    policy: []const PolicyValue,
    rejected: *std.ArrayList(Rejected),
) Allocator.Error!Entry {
    const default_node = jsonc.parseInto(arena, s.default, .{}, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // Defaults are checked at comptime and by unit tests.
        error.SyntaxError => unreachable,
    };

    var winner: Node = default_node;
    var source: Source = .default;
    // Objects merge key by key upward; other types take the highest valid layer.
    var merged: std.ArrayList(jsonc.Member) = .empty;
    if (s.ty == .object) try mergeInto(arena, &merged, &default_node);

    for (layers) |layer| {
        const node = layer.root.getDotted(s.path) orelse continue;
        if (node.data == .null) continue;
        if (!scopeAllows(s, layer.source)) {
            try rejected.append(arena, .{
                .path = s.path,
                .source = layer.source,
                .message = if (layer.source == .project) "only allowed in the global config" else "only allowed in a project config",
                .pos = if (layer.src.len > 0) jsonc.position(layer.src, node.start) else null,
            });
            continue;
        }
        if (try validate.checkValue(arena, s.ty, node)) |p| {
            try rejected.append(arena, .{
                .path = s.path,
                .source = layer.source,
                .message = p.message,
                .pos = if (layer.src.len > 0) jsonc.position(layer.src, node.start) else null,
            });
            continue;
        }
        source = layer.source;
        if (s.ty == .object) try mergeInto(arena, &merged, node) else winner = node.*;
    }

    var locked = false;
    if (policyValueFor(policy, s.path)) |pv| {
        if (!s.policy_lockable) {
            try rejected.append(arena, .{ .path = s.path, .source = .policy, .message = "this setting cannot be managed by policy" });
        } else {
            locked = true;
            switch (try policyNode(arena, s, pv)) {
                .ok => |node| {
                    source = .policy;
                    if (s.ty == .object) {
                        merged.clearRetainingCapacity();
                        try mergeInto(arena, &merged, &node);
                    } else winner = node;
                },
                .bad => |msg| try rejected.append(arena, .{ .path = s.path, .source = .policy, .message = msg }),
            }
        }
    }

    if (s.ty == .object) winner = .{ .start = 0, .end = 0, .data = .{ .object = try merged.toOwnedSlice(arena) } };
    // Layer and policy nodes borrow their source text and parse arenas.
    winner = try winner.clone(arena);
    return .{
        .spec = s,
        .value = winner,
        .json = try winner.toJsonAlloc(arena),
        .source = source,
        .locked = locked,
    };
}

fn mergeInto(arena: Allocator, members: *std.ArrayList(jsonc.Member), obj: *const Node) Allocator.Error!void {
    const src = switch (obj.data) {
        .object => |m| m,
        else => return,
    };
    outer: for (src) |m| {
        for (members.items) |*existing| {
            if (std.mem.eql(u8, existing.key, m.key)) {
                existing.* = m;
                continue :outer;
            }
        }
        try members.append(arena, m);
    }
}

/// The policy value for `path`: HKLM beats HKCU.
pub fn policyValueFor(policy: []const PolicyValue, path: []const u8) ?*const PolicyValue {
    var best: ?*const PolicyValue = null;
    for (policy) |*p| {
        if (!std.mem.eql(u8, p.path, path)) continue;
        if (best == null or (p.hive == .hklm and best.?.hive == .hkcu)) best = p;
    }
    return best;
}

const PolicyOutcome = union(enum) { ok: Node, bad: []const u8 };

fn policyNode(arena: Allocator, s: *const Spec, pv: *const PolicyValue) Allocator.Error!PolicyOutcome {
    const node: Node = switch (pv.data) {
        .json => |text| jsonc.parseInto(arena, text, .{}, null) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SyntaxError => return .{ .bad = "policy value is not a JSON literal" },
        },
        .dword => |d| switch (s.ty) {
            .boolean => switch (d) {
                0 => .{ .start = 0, .end = 0, .data = .{ .boolean = false } },
                1 => .{ .start = 0, .end = 0, .data = .{ .boolean = true } },
                // cmux: a non-Boolean forced value locks writes but does not enforce.
                else => return .{ .bad = "policy DWORD for a boolean must be 0 or 1" },
            },
            .integer, .number => .{ .start = 0, .end = 0, .data = .{ .number = try std.fmt.allocPrint(arena, "{d}", .{d}) } },
            else => return .{ .bad = "policy DWORD is only valid for booleans and numbers" },
        },
    };
    if (node.data == .null) return .{ .bad = "policy value is null" };
    if (try validate.checkValue(arena, s.ty, &node)) |p| return .{ .bad = p.message };
    return .{ .ok = node };
}

// ---------------------------------------------------------------------------
// Legacy Ghostty keys (ADR-5.1 row 2). Only keys explicitly set in the
// user's Ghostty config count (the app reads them from Config._replay_steps).

pub const LegacyGhosttyKey = struct {
    ghostty: []const u8,
    path: []const u8,
    /// Boolean meaning is inverted (`sidebar-metadata` vs `hideAllDetails`).
    invert: bool = false,
    /// Ghostty value -> JSON string value; unmapped values pass through.
    values: []const [2][]const u8 = &.{},
};

pub const legacy_ghostty_keys = [_]LegacyGhosttyKey{
    .{ .ghostty = "window-show-sidebar", .path = "wmux.sidebar.visible" },
    .{ .ghostty = "window-sidebar-width", .path = "wmux.sidebar.width" },
    .{ .ghostty = "sidebar-metadata", .path = "sidebar.hideAllDetails", .invert = true },
    .{ .ghostty = "window-show-right-sidebar", .path = "wmux.rightSidebar.visible" },
    .{ .ghostty = "window-right-sidebar-width", .path = "wmux.rightSidebar.width" },
    .{ .ghostty = "socket-control", .path = "automation.socketControlMode", .values = &.{.{ "off", "off" }} },
    .{ .ghostty = "desktop-notifications", .path = "wmux.notifications.desktop" },
};

pub fn legacyGhosttyKey(ghostty_key: []const u8) ?*const LegacyGhosttyKey {
    for (&legacy_ghostty_keys) |*k| if (std.mem.eql(u8, k.ghostty, ghostty_key)) return k;
    return null;
}

/// One explicitly set Ghostty `key = value` line.
pub const GhosttyPair = struct { key: []const u8, value: []const u8 };

/// Builds the Ghostty layer root object (allocated in `arena`) from the
/// explicitly set pairs, in file order (later wins). Keys outside
/// `legacy_ghostty_keys` and empty values (Ghostty's "reset") are skipped.
/// Values convert by the target spec's type when `specs` has one.
pub fn ghosttyLayer(arena: Allocator, specs: []const Spec, pairs: []const GhosttyPair) Allocator.Error!Node {
    var tree: Tree = .{};
    for (pairs) |pair| {
        const k = legacyGhosttyKey(pair.key) orelse continue;
        const raw = std.mem.trim(u8, pair.value, " \t\"");
        if (raw.len == 0) continue;
        const node = try ghosttyValue(arena, spec_mod.find(specs, k.path), k, raw);
        try tree.put(arena, k.path, node);
    }
    return tree.toNode(arena);
}

fn ghosttyValue(arena: Allocator, s: ?*const Spec, k: *const LegacyGhosttyKey, raw: []const u8) Allocator.Error!Node {
    const as_bool: ?bool = if (std.mem.eql(u8, raw, "true")) true else if (std.mem.eql(u8, raw, "false")) false else null;
    const numeric = std.fmt.parseFloat(f64, raw) catch null;
    const want: enum { boolean, number, string } = if (s) |sp| switch (sp.ty) {
        .boolean => .boolean,
        .integer, .number => .number,
        else => .string,
    } else if (as_bool != null) .boolean else if (numeric != null) .number else .string;

    switch (want) {
        .boolean => if (as_bool) |b| return .{ .start = 0, .end = 0, .data = .{ .boolean = b != k.invert } },
        .number => if (numeric != null and jsonc.isValidLiteral(raw)) return .{ .start = 0, .end = 0, .data = .{ .number = try arena.dupe(u8, raw) } },
        .string => {},
    }
    var mapped: []const u8 = raw;
    for (k.values) |v| if (std.mem.eql(u8, v[0], raw)) {
        mapped = v[1];
    };
    // A value that does not fit the type is kept as a string so validation
    // rejects it and resolution falls back to the default.
    return .{ .start = 0, .end = 0, .data = .{ .string = try arena.dupe(u8, mapped) } };
}

/// Small mutable object tree used to build layers from dotted paths.
const Tree = struct {
    members: std.ArrayList(Item) = .empty,

    const Item = struct { key: []const u8, leaf: ?Node, child: ?*Tree };

    fn put(self: *Tree, arena: Allocator, path: []const u8, value: Node) Allocator.Error!void {
        const dot = std.mem.indexOfScalar(u8, path, '.');
        const key = if (dot) |d| path[0..d] else path;
        const item = for (self.members.items) |*it| {
            if (std.mem.eql(u8, it.key, key)) break it;
        } else blk: {
            try self.members.append(arena, .{ .key = key, .leaf = null, .child = null });
            break :blk &self.members.items[self.members.items.len - 1];
        };
        if (dot) |d| {
            if (item.child == null) {
                item.child = try arena.create(Tree);
                item.child.?.* = .{};
            }
            item.leaf = null;
            try item.child.?.put(arena, path[d + 1 ..], value);
        } else {
            item.leaf = value;
            item.child = null;
        }
    }

    fn toNode(self: *const Tree, arena: Allocator) Allocator.Error!Node {
        const out = try arena.alloc(jsonc.Member, self.members.items.len);
        for (self.members.items, out) |it, *m| {
            m.* = .{
                .key = it.key,
                .key_start = 0,
                .key_end = 0,
                .value = if (it.leaf) |l| l else try it.child.?.toNode(arena),
            };
        }
        return .{ .start = 0, .end = 0, .data = .{ .object = out } };
    }
};

// ---------------------------------------------------------------------------
// File locations (ADR-5.1 rows 3-6), pure: the caller supplies the
// environment and checks which candidates exist.

pub const Env = struct {
    /// %WMUX_CONFIG_DIR%
    wmux_config_dir: ?[]const u8 = null,
    /// %XDG_CONFIG_HOME%
    xdg_config_home: ?[]const u8 = null,
    /// %USERPROFILE% (Windows) or $HOME.
    home: ?[]const u8 = null,

    fn nonEmpty(v: ?[]const u8) ?[]const u8 {
        const s = v orelse return null;
        return if (s.len == 0) null else s;
    }
};

/// `%XDG_CONFIG_HOME%\cmux\cmux.json`, else `%USERPROFILE%\.config\cmux\cmux.json`.
pub fn cmuxGlobalPath(gpa: Allocator, env: Env) Allocator.Error!?[]u8 {
    if (Env.nonEmpty(env.xdg_config_home)) |x| return try std.fs.path.join(gpa, &.{ x, "cmux", "cmux.json" });
    if (Env.nonEmpty(env.home)) |h| return try std.fs.path.join(gpa, &.{ h, ".config", "cmux", "cmux.json" });
    return null;
}

/// `%WMUX_CONFIG_DIR%\wmux.json`, else `%XDG_CONFIG_HOME%\wmux\wmux.json`,
/// else `%USERPROFILE%\.config\wmux\wmux.json`. All writers target this file.
pub fn wmuxGlobalPath(gpa: Allocator, env: Env) Allocator.Error!?[]u8 {
    if (Env.nonEmpty(env.wmux_config_dir)) |d| return try std.fs.path.join(gpa, &.{ d, "wmux.json" });
    if (Env.nonEmpty(env.xdg_config_home)) |x| return try std.fs.path.join(gpa, &.{ x, "wmux", "wmux.json" });
    if (Env.nonEmpty(env.home)) |h| return try std.fs.path.join(gpa, &.{ h, ".config", "wmux", "wmux.json" });
    return null;
}

/// Project file names tried in each directory, in order.
pub const project_files = [_][]const []const u8{
    &.{ ".wmux", "wmux.json" },
    &.{"wmux.json"},
    &.{ ".cmux", "cmux.json" },
    &.{"cmux.json"},
};

/// Candidate project files from `cwd` upward (nearest directory first, then
/// `project_files` order). The first existing one is the project file.
/// Caller frees each path and the slice (see `freePaths`).
pub fn projectCandidates(gpa: Allocator, cwd: []const u8) Allocator.Error![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    if (cwd.len == 0) return out.toOwnedSlice(gpa);
    var dir: ?[]const u8 = cwd;
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        for (project_files) |parts| {
            var segs: [3][]const u8 = undefined;
            segs[0] = d;
            for (parts, 1..) |p, i| segs[i] = p;
            try out.append(gpa, try std.fs.path.join(gpa, segs[0 .. parts.len + 1]));
        }
    }
    return out.toOwnedSlice(gpa);
}

pub fn freePaths(gpa: Allocator, paths: [][]u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

/// Where a `packs` entry may live: the path itself (a file), or the two
/// pack files inside it when it is a directory.
pub const PackPaths = struct {
    file: []u8,
    dir_candidates: [2][]u8,

    pub fn deinit(self: *PackPaths, gpa: Allocator) void {
        gpa.free(self.file);
        for (self.dir_candidates) |p| gpa.free(p);
    }
};

pub const pack_dir_files = [_][]const u8{ "wmux.pack.json", "cmux.pack.json" };

/// Resolves a `packs` entry relative to the directory of the config file
/// that lists it (absolute entries stay). http(s) URLs are refused.
pub fn packPaths(gpa: Allocator, config_dir: []const u8, entry: []const u8) (Allocator.Error || error{ RemotePack, EmptyPack })!PackPaths {
    if (entry.len == 0) return error.EmptyPack;
    if (std.ascii.startsWithIgnoreCase(entry, "http://") or std.ascii.startsWithIgnoreCase(entry, "https://"))
        return error.RemotePack;
    const file = try std.fs.path.resolve(gpa, &.{ config_dir, entry });
    errdefer gpa.free(file);
    const a = try std.fs.path.join(gpa, &.{ file, pack_dir_files[0] });
    errdefer gpa.free(a);
    const b = try std.fs.path.join(gpa, &.{ file, pack_dir_files[1] });
    return .{ .file = file, .dir_candidates = .{ a, b } };
}

// ---------------------------------------------------------------------------
// `config get|set|toggle|cycle` helpers (ADR-5.6, cmux semantics).

/// Top-level sections that are not settings: `config get/set` refuse them.
pub const non_setting_sections = [_][]const u8{ "$schema", "schemaVersion", "packs", "actions", "commands", "ui", "settingPresets" };

/// Legacy CLI shorthands mapped to JSON paths.
pub const legacy_shorthands = [_][2][]const u8{
    .{ "sidebar-font-size", "sidebar.fontSize" },
    .{ "surface-tab-bar-font-size", "wmux.tabBar.fontSize" },
};

pub fn expandShorthand(path: []const u8) []const u8 {
    for (legacy_shorthands) |s| if (std.mem.eql(u8, s[0], path)) return s[1];
    return path;
}

/// Why `path` cannot be read or written with `config get/set`, or null when
/// it names a declared setting.
pub fn settingPathProblem(specs: []const Spec, path: []const u8) ?[]const u8 {
    if (spec_mod.pathProblem(path)) |_| return "not a valid setting path (segments are separated by '.')";
    const top = if (std.mem.indexOfScalar(u8, path, '.')) |d| path[0..d] else path;
    for (non_setting_sections) |s| {
        if (std.mem.eql(u8, s, top)) return "not a setting; edit this section in the config file";
    }
    if (spec_mod.find(specs, path) == null) {
        if (spec_mod.isSection(specs, path)) return "is a section, not a single setting";
        return "unknown setting";
    }
    return null;
}

/// `config set` value: JSON when it parses as one JSON value, otherwise the
/// text as a JSON string. Caller owns the result.
pub fn cliValueJson(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    if (jsonc.parseInto(arena_state.allocator(), text, .{ .allow_comments = false, .allow_trailing_commas = false }, null)) |node| {
        return node.toJsonAlloc(gpa);
    } else |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => {},
    }
    const node: Node = .{ .start = 0, .end = 0, .data = .{ .string = text } };
    return node.toJsonAlloc(gpa);
}

/// `config toggle`: the flipped value of a boolean entry, or null when the
/// setting is not a boolean (cmux refuses non-booleans).
pub fn toggled(entry: *const Entry) ?[]const u8 {
    if (entry.spec.ty != .boolean) return null;
    const b = entry.value.asBool() orelse return null;
    return if (b) "false" else "true";
}

/// `config cycle <path> <v1> [v2...]`: index into `values` (CLI texts) of
/// the value after `current`, wrapping; an unlisted current value moves to
/// the first. Returns null when `values` is empty.
pub fn cycleIndex(gpa: Allocator, current: *const Node, values: []const []const u8) Allocator.Error!?usize {
    if (values.len == 0) return null;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (values, 0..) |v, i| {
        const json = try cliValueJson(arena, v);
        const node = jsonc.parseInto(arena, json, .{}, null) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SyntaxError => unreachable,
        };
        if (node.eql(current)) return (i + 1) % values.len;
    }
    return 0;
}

const testing = std.testing;
const fixtures = &validate.test_fixture_specs;

const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    node: Node,
    src: []const u8,

    fn init(src: []const u8) !Parsed {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        errdefer arena.deinit();
        const node = try jsonc.parseInto(arena.allocator(), src, .{}, null);
        return .{ .arena = arena, .node = node, .src = src };
    }

    fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }

    fn layer(self: *const Parsed, source: Source) Layer {
        return .{ .source = source, .root = &self.node, .src = self.src };
    }
};

test "unit: settings: defaults apply without layers" {
    var r = try resolve(testing.allocator, fixtures, &.{}, &.{});
    defer r.deinit();
    try testing.expectEqual(fixtures.len, r.entries.len);
    try testing.expectEqualStrings("system", r.getString("app.appearance").?);
    try testing.expectEqual(@as(i64, 20), r.getInt("app.paneResizeStepPixels").?);
    try testing.expectEqual(@as(f64, 1), r.getFloat("terminal.scrollSpeed").?);
    try testing.expectEqual(true, r.getBool("sidebar.showPorts").?);
    try testing.expectEqual(Source.default, r.get("sidebar.showPorts").?.source);
    try testing.expect(!r.get("sidebar.showPorts").?.configured());
    try testing.expect(r.get("nope") == null);
    try testing.expect(r.getBool("app.appearance") == null);
    try testing.expectEqual(@as(usize, 0), r.rejected.len);
}

test "unit: settings: precedence defaults < ghostty < cmux.json < wmux.json < project < policy" {
    var g_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer g_arena.deinit();
    const groot = try ghosttyLayer(g_arena.allocator(), fixtures, &.{
        .{ .key = "window-sidebar-width", .value = "250" },
        .{ .key = "window-show-sidebar", .value = "false" },
    });
    var cmux = try Parsed.init("{\"wmux\": {\"sidebar\": {\"width\": 260}}, \"app\": {\"appearance\": \"light\"}, \"notifications\": {\"hooks\": {\"a\": 1}}}");
    defer cmux.deinit();
    var wmux = try Parsed.init("// mine\n{\"app\": {\"appearance\": \"dark\"}, \"notifications\": {\"hooks\": {\"a\": 2}}}");
    defer wmux.deinit();
    var project = try Parsed.init("{\"notifications\": {\"hooks\": {\"a\": 3}}}");
    defer project.deinit();

    const layers = [_]Layer{
        project.layer(.project), // order of the slice does not matter
        wmux.layer(.wmux_json),
        .{ .source = .ghostty, .root = &groot },
        cmux.layer(.cmux_json),
    };
    var r = try resolve(testing.allocator, fixtures, &layers, &.{
        .{ .path = "app.minimalMode", .hive = .hkcu, .data = .{ .dword = 1 } },
    });
    defer r.deinit();
    try testing.expectEqual(@as(i64, 260), r.getInt("wmux.sidebar.width").?);
    try testing.expectEqual(Source.cmux_json, r.get("wmux.sidebar.width").?.source);
    try testing.expectEqual(false, r.getBool("wmux.sidebar.visible").?);
    try testing.expectEqual(Source.ghostty, r.get("wmux.sidebar.visible").?.source);
    try testing.expectEqualStrings("dark", r.getString("app.appearance").?);
    try testing.expectEqual(Source.wmux_json, r.get("app.appearance").?.source);
    try testing.expectEqualStrings("{\"a\":3}", r.get("notifications.hooks").?.json);
    try testing.expectEqual(Source.project, r.get("notifications.hooks").?.source);
    try testing.expectEqual(true, r.getBool("app.minimalMode").?);
    try testing.expectEqual(Source.policy, r.get("app.minimalMode").?.source);
    try testing.expect(r.isLocked("app.minimalMode"));
    try testing.expect(!r.isLocked("app.appearance"));
    try testing.expectEqualStrings("policy", Source.policy.label());
    try testing.expectEqualStrings("cmux.json", Source.cmux_json.label());
}

test "unit: settings: an invalid value falls back to the next lower layer" {
    var cmux = try Parsed.init("{\"terminal\": {\"scrollSpeed\": 1.4}}");
    defer cmux.deinit();
    var wmux = try Parsed.init("{\n  \"terminal\": {\"scrollSpeed\": 9},\n  \"app\": {\"appearance\": \"blue\", \"minimalMode\": null}\n}");
    defer wmux.deinit();
    var r = try resolve(testing.allocator, fixtures, &.{ cmux.layer(.cmux_json), wmux.layer(.wmux_json) }, &.{});
    defer r.deinit();
    try testing.expectEqual(@as(f64, 1.4), r.getFloat("terminal.scrollSpeed").?);
    try testing.expectEqual(Source.cmux_json, r.get("terminal.scrollSpeed").?.source);
    try testing.expectEqualStrings("system", r.getString("app.appearance").?);
    try testing.expectEqual(Source.default, r.get("app.appearance").?.source);
    // null means unset: no rejection.
    try testing.expectEqual(Source.default, r.get("app.minimalMode").?.source);
    try testing.expectEqual(@as(usize, 2), r.rejected.len);
    try testing.expectEqualStrings("app.appearance", r.rejected[0].path);
    try testing.expectEqual(jsonc.Pos{ .line = 3, .col = 25 }, r.rejected[0].pos.?);
    try testing.expectEqualStrings("terminal.scrollSpeed", r.rejected[1].path);
    try testing.expectEqual(Source.wmux_json, r.rejected[1].source);
    try testing.expectEqualStrings("9 is outside the range 0.1..3", r.rejected[1].message);
}

test "unit: settings: project files cannot set global-only keys" {
    var project = try Parsed.init("{\"app\": {\"minimalMode\": true}, \"notifications\": {\"hooks\": {\"x\": true}}}");
    defer project.deinit();
    var r = try resolve(testing.allocator, fixtures, &.{project.layer(.project)}, &.{});
    defer r.deinit();
    try testing.expectEqual(false, r.getBool("app.minimalMode").?);
    try testing.expectEqual(Source.project, r.get("notifications.hooks").?.source);
    try testing.expectEqual(@as(usize, 1), r.rejected.len);
    try testing.expectEqualStrings("only allowed in the global config", r.rejected[0].message);
}

test "unit: settings: object settings merge key by key across layers" {
    var global = try Parsed.init("{\"notifications\": {\"hooks\": {\"a\": 1, \"b\": 1}}}");
    defer global.deinit();
    var project = try Parsed.init("{\"notifications\": {\"hooks\": {\"b\": 2, \"c\": 2}}}");
    defer project.deinit();
    var r = try resolve(testing.allocator, fixtures, &.{ global.layer(.wmux_json), project.layer(.project) }, &.{});
    defer r.deinit();
    try testing.expectEqualStrings("{\"a\":1,\"b\":2,\"c\":2}", r.get("notifications.hooks").?.json);
}

test "unit: settings: policy values lock and enforce" {
    var wmux = try Parsed.init("{\"automation\": {\"socketControlMode\": \"allowAll\"}, \"app\": {\"paneResizeStepPixels\": 30}}");
    defer wmux.deinit();
    const policy = [_]PolicyValue{
        .{ .path = "automation.socketControlMode", .hive = .hkcu, .data = .{ .json = "\"password\"" } },
        .{ .path = "automation.socketControlMode", .hive = .hklm, .data = .{ .json = "\"off\"" } },
        .{ .path = "app.paneResizeStepPixels", .hive = .hklm, .data = .{ .dword = 50 } },
        .{ .path = "sidebar.showPorts", .hive = .hklm, .data = .{ .dword = 7 } },
        .{ .path = "app.appearance", .hive = .hklm, .data = .{ .json = "not json" } },
        .{ .path = "automation.claudeBinaryPath", .hive = .hklm, .data = .{ .json = "\"C:\\\\x\"" } },
    };
    var r = try resolve(testing.allocator, fixtures, &.{wmux.layer(.wmux_json)}, &policy);
    defer r.deinit();
    try testing.expectEqualStrings("off", r.getString("automation.socketControlMode").?);
    try testing.expectEqual(Source.policy, r.get("automation.socketControlMode").?.source);
    try testing.expectEqual(@as(i64, 50), r.getInt("app.paneResizeStepPixels").?);
    // Invalid forced values lock writes but do not enforce.
    try testing.expect(r.isLocked("sidebar.showPorts"));
    try testing.expectEqual(true, r.getBool("sidebar.showPorts").?);
    try testing.expectEqual(Source.default, r.get("sidebar.showPorts").?.source);
    try testing.expect(r.isLocked("app.appearance"));
    // Non-lockable settings ignore policy.
    try testing.expect(!r.isLocked("automation.claudeBinaryPath"));
    try testing.expectEqualStrings("", r.getString("automation.claudeBinaryPath").?);
    try testing.expectEqual(@as(usize, 3), r.rejected.len);
}

test "unit: settings: resolved values outlive the layers and policy strings" {
    const gpa = testing.allocator;
    const src = try gpa.dupe(u8, "{\"app\": {\"appearance\": \"dark\"}, \"terminal\": {\"scrollSpeed\": 1.25}, \"notifications\": {\"hooks\": {\"k\": [\"v\"]}}}");
    var layer_arena: std.heap.ArenaAllocator = .init(gpa);
    const root = try jsonc.parseInto(layer_arena.allocator(), src, .{}, null);
    const forced = try gpa.dupe(u8, "\"cmuxOnly\"");
    var r = try resolve(gpa, fixtures, &.{.{ .source = .wmux_json, .root = &root, .src = src }}, &.{
        .{ .path = "automation.socketControlMode", .hive = .hklm, .data = .{ .json = forced } },
    });
    defer r.deinit();
    // A reload frees the parsed files right after resolving.
    @memset(src, 'X');
    @memset(forced, 'X');
    layer_arena.deinit();
    gpa.free(src);
    gpa.free(forced);
    try testing.expectEqualStrings("dark", r.getString("app.appearance").?);
    try testing.expectEqual(@as(f64, 1.25), r.getFloat("terminal.scrollSpeed").?);
    try testing.expectEqualStrings("cmuxOnly", r.getString("automation.socketControlMode").?);
    const hooks = r.get("notifications.hooks").?;
    try testing.expectEqualStrings("v", hooks.value.getPath(&.{"k"}).?.data.array[0].asString().?);
    try testing.expectEqualStrings("{\"k\":[\"v\"]}", hooks.json);
}

test "unit: settings: legacy ghostty keys convert by spec type" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try ghosttyLayer(a, fixtures, &.{
        .{ .key = "font-size", .value = "14" }, // not a legacy key
        .{ .key = "window-sidebar-width", .value = "180" },
        .{ .key = "window-sidebar-width", .value = "300" }, // later wins
        .{ .key = "sidebar-metadata", .value = "false" }, // inverted, no spec in fixtures
        .{ .key = "socket-control", .value = "off" },
        .{ .key = "window-show-sidebar", .value = "" }, // reset: skipped
        .{ .key = "desktop-notifications", .value = "true" },
        .{ .key = "window-right-sidebar-width", .value = "wide" },
    });
    try testing.expectEqual(@as(i64, 300), root.getDotted("wmux.sidebar.width").?.asInt().?);
    try testing.expectEqual(true, root.getDotted("sidebar.hideAllDetails").?.asBool().?);
    try testing.expectEqualStrings("off", root.getDotted("automation.socketControlMode").?.asString().?);
    try testing.expect(root.getDotted("wmux.sidebar.visible") == null);
    try testing.expect(root.getDotted("font-size") == null);
    try testing.expectEqual(true, root.getDotted("wmux.notifications.desktop").?.asBool().?);
    try testing.expectEqualStrings("wide", root.getDotted("wmux.rightSidebar.width").?.asString().?);
    const json = try root.toJsonAlloc(a);
    try testing.expectEqualStrings(
        "{\"wmux\":{\"sidebar\":{\"width\":300},\"notifications\":{\"desktop\":true},\"rightSidebar\":{\"width\":\"wide\"}},\"sidebar\":{\"hideAllDetails\":true},\"automation\":{\"socketControlMode\":\"off\"}}",
        json,
    );
    // An unconvertible value fails validation and the default applies.
    const bad = try ghosttyLayer(a, fixtures, &.{.{ .key = "window-sidebar-width", .value = "abc" }});
    var r = try resolve(testing.allocator, fixtures, &.{.{ .source = .ghostty, .root = &bad }}, &.{});
    defer r.deinit();
    try testing.expectEqual(@as(i64, 220), r.getInt("wmux.sidebar.width").?);
    try testing.expectEqual(@as(usize, 1), r.rejected.len);
}

test "unit: settings: real registry resolves" {
    var r = try resolve(testing.allocator, manifest.all, &.{}, &.{});
    defer r.deinit();
    try testing.expectEqual(manifest.all.len, r.entries.len);
}

test "unit: settings: config file locations" {
    const gpa = testing.allocator;
    const join = std.fs.path.join;
    {
        const got = (try wmuxGlobalPath(gpa, .{ .wmux_config_dir = "/c/wm", .xdg_config_home = "/x", .home = "/h" })).?;
        defer gpa.free(got);
        const want = try join(gpa, &.{ "/c/wm", "wmux.json" });
        defer gpa.free(want);
        try testing.expectEqualStrings(want, got);
    }
    {
        const got = (try wmuxGlobalPath(gpa, .{ .wmux_config_dir = "", .xdg_config_home = "/x", .home = "/h" })).?;
        defer gpa.free(got);
        const want = try join(gpa, &.{ "/x", "wmux", "wmux.json" });
        defer gpa.free(want);
        try testing.expectEqualStrings(want, got);
    }
    {
        const got = (try cmuxGlobalPath(gpa, .{ .home = "/home/ü" })).?;
        defer gpa.free(got);
        const want = try join(gpa, &.{ "/home/ü", ".config", "cmux", "cmux.json" });
        defer gpa.free(want);
        try testing.expectEqualStrings(want, got);
    }
    try testing.expect(try cmuxGlobalPath(gpa, .{}) == null);
    try testing.expect(try wmuxGlobalPath(gpa, .{ .home = "" }) == null);
}

test "unit: settings: project candidates walk upward" {
    const gpa = testing.allocator;
    const sep = std.fs.path.sep_str;
    const cwd = sep ++ "src" ++ sep ++ "app";
    const c = try projectCandidates(gpa, cwd);
    defer freePaths(gpa, c);
    try testing.expectEqual(@as(usize, 12), c.len);
    try testing.expectEqualStrings(cwd ++ sep ++ ".wmux" ++ sep ++ "wmux.json", c[0]);
    try testing.expectEqualStrings(cwd ++ sep ++ "wmux.json", c[1]);
    try testing.expectEqualStrings(cwd ++ sep ++ ".cmux" ++ sep ++ "cmux.json", c[2]);
    try testing.expectEqualStrings(cwd ++ sep ++ "cmux.json", c[3]);
    try testing.expectEqualStrings(sep ++ "src" ++ sep ++ ".wmux" ++ sep ++ "wmux.json", c[4]);
    const empty = try projectCandidates(gpa, "");
    defer freePaths(gpa, empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "unit: settings: pack paths" {
    const gpa = testing.allocator;
    const sep = std.fs.path.sep_str;
    var p = try packPaths(gpa, sep ++ "cfg", "packs" ++ sep ++ "team");
    defer p.deinit(gpa);
    try testing.expectEqualStrings(sep ++ "cfg" ++ sep ++ "packs" ++ sep ++ "team", p.file);
    try testing.expectEqualStrings(sep ++ "cfg" ++ sep ++ "packs" ++ sep ++ "team" ++ sep ++ "wmux.pack.json", p.dir_candidates[0]);
    try testing.expectEqualStrings(sep ++ "cfg" ++ sep ++ "packs" ++ sep ++ "team" ++ sep ++ "cmux.pack.json", p.dir_candidates[1]);
    var abs = try packPaths(gpa, sep ++ "cfg", sep ++ "abs" ++ sep ++ "p.json");
    defer abs.deinit(gpa);
    try testing.expectEqualStrings(sep ++ "abs" ++ sep ++ "p.json", abs.file);
    try testing.expectError(error.RemotePack, packPaths(gpa, sep ++ "cfg", "HTTPS://example.invalid/p.json"));
    try testing.expectError(error.RemotePack, packPaths(gpa, sep ++ "cfg", "http://x"));
    try testing.expectError(error.EmptyPack, packPaths(gpa, sep ++ "cfg", ""));
}

test "unit: settings: config set value parsing" {
    const gpa = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "1.4", "1.4" },
        .{ "true", "true" },
        .{ "\"dark\"", "\"dark\"" },
        .{ "dark", "\"dark\"" },
        .{ "[1, 2]", "[1,2]" },
        .{ "{\"a\": null}", "{\"a\":null}" },
        .{ "", "\"\"" },
        .{ "日本 \"q\"", "\"日本 \\\"q\\\"\"" },
        .{ "[1,]", "\"[1,]\"" },
        .{ "// c\n1", "\"// c\\n1\"" },
    };
    for (cases) |c| {
        const got = try cliValueJson(gpa, c[0]);
        defer gpa.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

test "unit: settings: config path checks and shorthands" {
    try testing.expect(settingPathProblem(fixtures, "terminal.scrollSpeed") == null);
    try testing.expectEqualStrings("unknown setting", settingPathProblem(fixtures, "terminal.nope").?);
    try testing.expectEqualStrings("is a section, not a single setting", settingPathProblem(fixtures, "terminal").?);
    try testing.expect(settingPathProblem(fixtures, "actions.foo") != null);
    try testing.expect(settingPathProblem(fixtures, "settingPresets") != null);
    try testing.expect(settingPathProblem(fixtures, "workspaceGroups.byCwd.~/src/app.web") != null);
    try testing.expect(settingPathProblem(fixtures, "") != null);
    try testing.expectEqualStrings("sidebar.fontSize", expandShorthand("sidebar-font-size"));
    try testing.expectEqualStrings("terminal.scrollSpeed", expandShorthand("terminal.scrollSpeed"));
}

test "unit: settings: toggle and cycle follow the effective value" {
    var r = try resolve(testing.allocator, fixtures, &.{}, &.{});
    defer r.deinit();
    try testing.expectEqualStrings("false", toggled(r.get("fileEditor.wordWrap").?).?);
    try testing.expectEqualStrings("true", toggled(r.get("app.minimalMode").?).?);
    try testing.expect(toggled(r.get("app.appearance").?) == null);

    const appearance = &r.get("app.appearance").?.value; // "system"
    try testing.expectEqual(@as(?usize, 2), try cycleIndex(testing.allocator, appearance, &.{ "light", "system", "dark" }));
    try testing.expectEqual(@as(?usize, 0), try cycleIndex(testing.allocator, appearance, &.{ "light", "dark", "system" }));
    try testing.expectEqual(@as(?usize, 0), try cycleIndex(testing.allocator, appearance, &.{ "light", "dark" }));
    try testing.expectEqual(@as(?usize, null), try cycleIndex(testing.allocator, appearance, &.{}));
    const speed = &r.get("terminal.scrollSpeed").?.value; // 1
    try testing.expectEqual(@as(?usize, 1), try cycleIndex(testing.allocator, speed, &.{ "1.0", "2" }));
}
