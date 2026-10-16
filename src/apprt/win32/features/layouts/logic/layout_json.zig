//! cmux workspace layout JSON (core-workspace-layout-json,
//! persistence-workspace-layout-definitions): parse, validate and serialize
//! the workspace definition {name, cwd, color, env, setup, layout} and its
//! layout tree of split nodes {direction, split, children[2]} and pane nodes
//! {surfaces[...]} (also accepted as {pane: {surfaces[...]}}). Also converts
//! between that schema and `Tree`, a neutral workspace-tree description with
//! resolved cwds and merged env that the app-side builder and the session
//! serializer speak (ADR-9.2 shape: split dir/ratio/a/b, panes with tabs).
//!
//! Pure: std + wmux_proto only. Every result lives in a caller-provided
//! arena; nothing here frees individual allocations. The node-based parsers
//! (`parseWorkspace`, `parseLayout`) also borrow the node's source text,
//! because jsonc keeps unescaped strings as slices of its input; the `*Text`
//! parsers copy their input into the arena first.

const std = @import("std");
const proto = @import("wmux_proto");
const jsonc = proto.jsonc;
const paths = proto.paths;

const Allocator = std.mem.Allocator;

pub const split_min: f64 = 0.1;
pub const split_max: f64 = 0.9;
pub const split_default: f64 = 0.5;

/// Nesting cap for layout nodes (recursion guard). Each node level costs
/// two JSON levels, so this stays below jsonc's default depth of 128.
pub const max_node_depth: u32 = 32;

pub const Direction = enum { horizontal, vertical };
pub const SurfaceType = enum { terminal, browser };

/// What happens when a workspace with the same name is already open.
pub const Restart = enum {
    /// Switch to the existing workspace.
    ignore,
    /// Replace it right away.
    recreate,
    /// Prompt, then replace.
    confirm,
    /// Create another one (default).
    new,

    pub fn parse(s: []const u8) ?Restart {
        return std.meta.stringToEnum(Restart, s);
    }
};

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

pub const Surface = struct {
    type: SurfaceType = .terminal,
    /// Tab title.
    name: ?[]const u8 = null,
    /// Terminal only: shell text run when the terminal opens.
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    env: []const EnvVar = &.{},
    /// Browser only.
    url: ?[]const u8 = null,
    focus: bool = false,
};

pub const Pane = struct {
    /// At least one entry.
    surfaces: []const Surface,
};

pub const Split = struct {
    direction: Direction,
    /// Divider position, already clamped to [split_min, split_max].
    split: f64 = split_default,
    children: *const [2]Node,
};

pub const Node = union(enum) {
    split: Split,
    pane: Pane,
};

pub const Workspace = struct {
    name: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    /// "#RRGGBB" or a workspace color name.
    color: ?[]const u8 = null,
    env: []const EnvVar = &.{},
    /// Bootstrap command sent to the first terminal before its own command.
    setup: ?[]const u8 = null,
    /// Null = one pane with one terminal.
    layout: ?Node = null,
};

// ---------------------------------------------------------------------------
// Diagnostics

pub const Severity = enum { err, warning };

pub const Issue = struct {
    severity: Severity,
    /// JSON path of the offending value ("layout.children[1].surfaces[0].type").
    path: []const u8,
    message: []const u8,
};

/// Collects every issue of a parse (it does not stop at the first one).
/// Paths and messages live in `arena`.
pub const Diagnostics = struct {
    arena: Allocator,
    items: std.ArrayList(Issue) = .empty,

    pub fn init(arena: Allocator) Diagnostics {
        return .{ .arena = arena };
    }

    pub fn add(self: *Diagnostics, severity: Severity, path: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const msg = try std.fmt.allocPrint(self.arena, fmt, args);
        try self.items.append(self.arena, .{ .severity = severity, .path = path, .message = msg });
    }

    pub fn errorCount(self: *const Diagnostics) usize {
        var n: usize = 0;
        for (self.items.items) |it| {
            if (it.severity == .err) n += 1;
        }
        return n;
    }

    pub fn hasErrors(self: *const Diagnostics) bool {
        return self.errorCount() > 0;
    }

    /// First error as "path: message" (for one-line CLI errors), or null.
    pub fn firstError(self: *const Diagnostics) ?Issue {
        for (self.items.items) |it| {
            if (it.severity == .err) return it;
        }
        return null;
    }
};

pub const ParseError = error{ OutOfMemory, InvalidLayout };

fn childPath(arena: Allocator, base: []const u8, key: []const u8) Allocator.Error![]const u8 {
    if (base.len == 0) return arena.dupe(u8, key);
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ base, key });
}

fn indexPath(arena: Allocator, base: []const u8, i: usize) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}[{d}]", .{ base, i });
}

// ---------------------------------------------------------------------------
// Parsing

/// Parses a workspace definition object. Returns error.InvalidLayout when
/// `diags` holds at least one error; warnings alone do not fail. Strings of
/// the result may be slices of `node`'s source text (see the file comment);
/// `cloneWorkspace` detaches it.
pub fn parseWorkspace(arena: Allocator, node: *const jsonc.Node, base_path: []const u8, diags: *Diagnostics) ParseError!Workspace {
    const ws = try parseWorkspaceInner(arena, node, base_path, diags);
    if (diags.hasErrors()) return error.InvalidLayout;
    return ws;
}

/// Parses a single layout node (the value of `layout`, or the `--layout`
/// argument of `new-workspace`). Borrows like `parseWorkspace`.
pub fn parseLayout(arena: Allocator, node: *const jsonc.Node, base_path: []const u8, diags: *Diagnostics) ParseError!Node {
    const n = try parseNode(arena, node, base_path, 0, diags);
    if (diags.hasErrors()) return error.InvalidLayout;
    return n orelse error.InvalidLayout;
}

/// Parses JSONC text holding a workspace definition. The result lives
/// entirely in `arena`, so the caller may free `src` afterwards.
pub fn parseWorkspaceText(arena: Allocator, src: []const u8, diags: *Diagnostics) ParseError!Workspace {
    const root = try parseRoot(arena, src, diags);
    return parseWorkspace(arena, &root, "", diags);
}

/// Parses JSONC text holding a layout node. The result lives entirely in
/// `arena`.
pub fn parseLayoutText(arena: Allocator, src: []const u8, diags: *Diagnostics) ParseError!Node {
    const root = try parseRoot(arena, src, diags);
    return parseLayout(arena, &root, "", diags);
}

fn parseRoot(arena: Allocator, src: []const u8, diags: *Diagnostics) ParseError!jsonc.Node {
    // jsonc keeps unescaped strings as slices of its input: parse a copy so
    // nothing in the result points into the caller's buffer.
    const text = try arena.dupe(u8, src);
    var jd: jsonc.Diagnostic = .{};
    return jsonc.parseInto(arena, text, .{}, &jd) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => {
            try diags.add(.err, "", "{d}:{d}: {s}", .{ jd.pos.line, jd.pos.col, jd.message });
            return error.InvalidLayout;
        },
    };
}

const workspace_keys = [_][]const u8{ "name", "cwd", "color", "env", "setup", "layout" };
const surface_keys = [_][]const u8{ "type", "name", "command", "cwd", "env", "url", "focus" };
const split_keys = [_][]const u8{ "direction", "split", "children" };

fn isKnown(keys: []const []const u8, key: []const u8) bool {
    for (keys) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

fn warnUnknownKeys(arena: Allocator, members: []const jsonc.Member, keys: []const []const u8, base: []const u8, diags: *Diagnostics) Allocator.Error!void {
    for (members) |m| {
        if (isKnown(keys, m.key) or std.mem.startsWith(u8, m.key, "$")) continue;
        try diags.add(.warning, try childPath(arena, base, m.key), "unknown key '{s}' is ignored", .{m.key});
    }
}

/// Optional string field: absent and null give null; other kinds are errors.
fn optString(arena: Allocator, obj: *const jsonc.Node, key: []const u8, base: []const u8, diags: *Diagnostics) Allocator.Error!?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v.data) {
        .null => null,
        .string => |s| s,
        else => blk: {
            try diags.add(.err, try childPath(arena, base, key), "'{s}' must be a string, not {s}", .{ key, v.kindName() });
            break :blk null;
        },
    };
}

fn optBool(arena: Allocator, obj: *const jsonc.Node, key: []const u8, base: []const u8, diags: *Diagnostics) Allocator.Error!?bool {
    const v = obj.get(key) orelse return null;
    return switch (v.data) {
        .null => null,
        .boolean => |b| b,
        else => blk: {
            try diags.add(.err, try childPath(arena, base, key), "'{s}' must be true or false, not {s}", .{ key, v.kindName() });
            break :blk null;
        },
    };
}

/// True when the name can be put in a process environment block.
pub fn isValidEnvName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (c == '=' or c == 0) return false;
    }
    return true;
}

fn parseEnv(arena: Allocator, obj: *const jsonc.Node, base: []const u8, diags: *Diagnostics) Allocator.Error![]const EnvVar {
    const v = obj.get("env") orelse return &.{};
    const path = try childPath(arena, base, "env");
    const members = switch (v.data) {
        .null => return &.{},
        .object => |m| m,
        else => {
            try diags.add(.err, path, "'env' must be an object of strings, not {s}", .{v.kindName()});
            return &.{};
        },
    };
    var out: std.ArrayList(EnvVar) = .empty;
    for (members) |m| {
        const vp = try childPath(arena, path, m.key);
        if (!isValidEnvName(m.key)) {
            try diags.add(.err, vp, "invalid environment variable name '{s}'", .{m.key});
            continue;
        }
        const val = switch (m.value.data) {
            .string => |s| s,
            else => {
                try diags.add(.err, vp, "environment value must be a string, not {s}", .{m.value.kindName()});
                continue;
            },
        };
        if (std.mem.indexOfScalar(u8, val, 0) != null) {
            try diags.add(.err, vp, "environment value contains a NUL character", .{});
            continue;
        }
        // Last duplicate wins, as in jsonc's getMember.
        var replaced = false;
        for (out.items) |*e| {
            if (std.mem.eql(u8, e.name, m.key)) {
                e.value = val;
                replaced = true;
            }
        }
        if (!replaced) try out.append(arena, .{ .name = m.key, .value = val });
    }
    return out.toOwnedSlice(arena);
}

/// "#RRGGBB" (hex digits, any case) or a non-blank color name.
pub fn isValidColor(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '#') {
        if (s.len != 7) return false;
        for (s[1..]) |c| {
            if (!std.ascii.isHex(c)) return false;
        }
        return true;
    }
    return std.mem.trim(u8, s, " \t\r\n").len > 0;
}

fn parseWorkspaceInner(arena: Allocator, node: *const jsonc.Node, base: []const u8, diags: *Diagnostics) Allocator.Error!Workspace {
    const members = switch (node.data) {
        .object => |m| m,
        else => {
            try diags.add(.err, base, "workspace definition must be an object, not {s}", .{node.kindName()});
            return .{};
        },
    };
    try warnUnknownKeys(arena, members, &workspace_keys, base, diags);
    var ws: Workspace = .{};
    ws.name = try optString(arena, node, "name", base, diags);
    ws.cwd = try optString(arena, node, "cwd", base, diags);
    ws.setup = try optString(arena, node, "setup", base, diags);
    if (try optString(arena, node, "color", base, diags)) |c| {
        if (isValidColor(c)) {
            ws.color = c;
        } else {
            try diags.add(.err, try childPath(arena, base, "color"), "color must be #RRGGBB or a workspace color name, got '{s}'", .{c});
        }
    }
    ws.env = try parseEnv(arena, node, base, diags);
    if (node.get("layout")) |l| {
        if (l.data != .null) ws.layout = try parseNode(arena, l, try childPath(arena, base, "layout"), 0, diags);
    }
    return ws;
}

fn parseNode(arena: Allocator, node: *const jsonc.Node, path: []const u8, depth: u32, diags: *Diagnostics) Allocator.Error!?Node {
    if (depth >= max_node_depth) {
        try diags.add(.err, path, "layout is nested more than {d} levels deep", .{max_node_depth});
        return null;
    }
    const members = switch (node.data) {
        .object => |m| m,
        else => {
            try diags.add(.err, path, "layout node must be an object, not {s}", .{node.kindName()});
            return null;
        },
    };
    const is_split = node.get("direction") != null or node.get("children") != null or node.get("split") != null;
    const pane_obj = node.get("pane");
    const bare_surfaces = node.get("surfaces");
    if (is_split and (pane_obj != null or bare_surfaces != null)) {
        try diags.add(.err, path, "a layout node is either a split (direction, split, children) or a pane (surfaces), not both", .{});
        return null;
    }
    if (is_split) return try parseSplit(arena, node, members, path, depth, diags);
    if (pane_obj) |p| {
        if (bare_surfaces != null) {
            try diags.add(.err, path, "use either 'pane' or 'surfaces', not both", .{});
            return null;
        }
        for (members) |m| {
            if (!std.mem.eql(u8, m.key, "pane") and !std.mem.startsWith(u8, m.key, "$"))
                try diags.add(.warning, try childPath(arena, path, m.key), "unknown key '{s}' is ignored", .{m.key});
        }
        const pp = try childPath(arena, path, "pane");
        const pm = switch (p.data) {
            .object => |m| m,
            else => {
                try diags.add(.err, pp, "'pane' must be an object with 'surfaces', not {s}", .{p.kindName()});
                return null;
            },
        };
        for (pm) |m| {
            if (!std.mem.eql(u8, m.key, "surfaces") and !std.mem.startsWith(u8, m.key, "$"))
                try diags.add(.warning, try childPath(arena, pp, m.key), "unknown key '{s}' is ignored", .{m.key});
        }
        return try parsePane(arena, p.get("surfaces"), pp, diags);
    }
    if (bare_surfaces != null) {
        for (members) |m| {
            if (!std.mem.eql(u8, m.key, "surfaces") and !std.mem.startsWith(u8, m.key, "$"))
                try diags.add(.warning, try childPath(arena, path, m.key), "unknown key '{s}' is ignored", .{m.key});
        }
        return try parsePane(arena, bare_surfaces, path, diags);
    }
    try diags.add(.err, path, "layout node must be a split (direction, children) or a pane (surfaces)", .{});
    return null;
}

fn parseSplit(arena: Allocator, node: *const jsonc.Node, members: []const jsonc.Member, path: []const u8, depth: u32, diags: *Diagnostics) Allocator.Error!?Node {
    try warnUnknownKeys(arena, members, &split_keys, path, diags);
    var ok = true;
    var direction: Direction = .horizontal;
    if (node.get("direction")) |d| {
        const s = d.asString();
        if (s != null and std.meta.stringToEnum(Direction, s.?) != null) {
            direction = std.meta.stringToEnum(Direction, s.?).?;
        } else {
            try diags.add(.err, try childPath(arena, path, "direction"), "direction must be 'horizontal' or 'vertical'", .{});
            ok = false;
        }
    } else {
        try diags.add(.err, path, "split node is missing 'direction'", .{});
        ok = false;
    }
    var ratio = split_default;
    if (node.get("split")) |s| {
        switch (s.data) {
            .null => {},
            .number => ratio = clampSplit(s.asFloat() orelse split_default),
            else => {
                try diags.add(.err, try childPath(arena, path, "split"), "split must be a number between 0.1 and 0.9", .{});
                ok = false;
            },
        }
    }
    const cp = try childPath(arena, path, "children");
    const children = node.get("children") orelse {
        try diags.add(.err, path, "split node is missing 'children'", .{});
        return null;
    };
    const items = switch (children.data) {
        .array => |a| a,
        else => {
            try diags.add(.err, cp, "children must be an array of exactly two nodes", .{});
            return null;
        },
    };
    if (items.len != 2) {
        try diags.add(.err, cp, "children must contain exactly two nodes, found {d}", .{items.len});
        return null;
    }
    const kids = try arena.create([2]Node);
    const a = try parseNode(arena, &items[0], try indexPath(arena, cp, 0), depth + 1, diags);
    const b = try parseNode(arena, &items[1], try indexPath(arena, cp, 1), depth + 1, diags);
    if (!ok or a == null or b == null) return null;
    kids.* = .{ a.?, b.? };
    return .{ .split = .{ .direction = direction, .split = ratio, .children = kids } };
}

/// Clamps a divider fraction to [0.1, 0.9]; non-finite values give 0.5.
pub fn clampSplit(v: f64) f64 {
    if (!std.math.isFinite(v)) return split_default;
    return std.math.clamp(v, split_min, split_max);
}

fn parsePane(arena: Allocator, surfaces: ?*const jsonc.Node, path: []const u8, diags: *Diagnostics) Allocator.Error!?Node {
    const sp = try childPath(arena, path, "surfaces");
    const s = surfaces orelse {
        try diags.add(.err, path, "pane is missing 'surfaces'", .{});
        return null;
    };
    const items = switch (s.data) {
        .array => |a| a,
        else => {
            try diags.add(.err, sp, "surfaces must be an array, not {s}", .{s.kindName()});
            return null;
        },
    };
    if (items.len == 0) {
        try diags.add(.err, sp, "a pane needs at least one surface", .{});
        return null;
    }
    const out = try arena.alloc(Surface, items.len);
    var ok = true;
    for (items, out, 0..) |*item, *o, i| {
        if (try parseSurface(arena, item, try indexPath(arena, sp, i), diags)) |surf| {
            o.* = surf;
        } else ok = false;
    }
    if (!ok) return null;
    return .{ .pane = .{ .surfaces = out } };
}

fn parseSurface(arena: Allocator, node: *const jsonc.Node, path: []const u8, diags: *Diagnostics) Allocator.Error!?Surface {
    const members = switch (node.data) {
        .object => |m| m,
        else => {
            try diags.add(.err, path, "surface must be an object, not {s}", .{node.kindName()});
            return null;
        },
    };
    try warnUnknownKeys(arena, members, &surface_keys, path, diags);
    const before = diags.errorCount();
    var s: Surface = .{};
    s.name = try optString(arena, node, "name", path, diags);
    s.command = try optString(arena, node, "command", path, diags);
    s.cwd = try optString(arena, node, "cwd", path, diags);
    s.url = try optString(arena, node, "url", path, diags);
    s.focus = (try optBool(arena, node, "focus", path, diags)) orelse false;
    s.env = try parseEnv(arena, node, path, diags);
    if (try optString(arena, node, "type", path, diags)) |t| {
        if (std.meta.stringToEnum(SurfaceType, t)) |ty| {
            s.type = ty;
        } else {
            try diags.add(.err, try childPath(arena, path, "type"), "unknown surface type '{s}' (expected 'terminal' or 'browser')", .{t});
        }
    } else if (s.url != null and s.command == null) {
        // Type omitted: a url makes it a browser.
        s.type = .browser;
    }
    switch (s.type) {
        .terminal => if (s.url != null) {
            try diags.add(.warning, try childPath(arena, path, "url"), "'url' is ignored for terminal surfaces", .{});
            s.url = null;
        },
        .browser => if (s.command != null) {
            try diags.add(.warning, try childPath(arena, path, "command"), "'command' is ignored for browser surfaces", .{});
            s.command = null;
        },
    }
    if (diags.errorCount() != before) return null;
    return s;
}

// ---------------------------------------------------------------------------
// Serialization

/// Writes the workspace definition in canonical form: absent fields are
/// omitted, panes are written as {"pane": {"surfaces": [...]}} and `split`
/// is always written.
pub fn writeWorkspace(jw: *std.json.Stringify, ws: Workspace) std.Io.Writer.Error!void {
    try jw.beginObject();
    try writeOpt(jw, "name", ws.name);
    try writeOpt(jw, "cwd", ws.cwd);
    try writeOpt(jw, "color", ws.color);
    try writeEnv(jw, ws.env);
    try writeOpt(jw, "setup", ws.setup);
    if (ws.layout) |l| {
        try jw.objectField("layout");
        try writeNode(jw, l);
    }
    try jw.endObject();
}

pub fn writeNode(jw: *std.json.Stringify, node: Node) std.Io.Writer.Error!void {
    switch (node) {
        .split => |s| {
            try jw.beginObject();
            try jw.objectField("direction");
            try jw.write(@tagName(s.direction));
            try jw.objectField("split");
            try writeRatio(jw, s.split);
            try jw.objectField("children");
            try jw.beginArray();
            try writeNode(jw, s.children[0]);
            try writeNode(jw, s.children[1]);
            try jw.endArray();
            try jw.endObject();
        },
        .pane => |p| {
            try jw.beginObject();
            try jw.objectField("pane");
            try jw.beginObject();
            try jw.objectField("surfaces");
            try jw.beginArray();
            for (p.surfaces) |s| try writeSurface(jw, s);
            try jw.endArray();
            try jw.endObject();
            try jw.endObject();
        },
    }
}

pub fn writeSurface(jw: *std.json.Stringify, s: Surface) std.Io.Writer.Error!void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write(@tagName(s.type));
    try writeOpt(jw, "name", s.name);
    if (s.type == .terminal) try writeOpt(jw, "command", s.command);
    try writeOpt(jw, "cwd", s.cwd);
    try writeEnv(jw, s.env);
    if (s.type == .browser) try writeOpt(jw, "url", s.url);
    if (s.focus) {
        try jw.objectField("focus");
        try jw.write(true);
    }
    try jw.endObject();
}

fn writeOpt(jw: *std.json.Stringify, key: []const u8, v: ?[]const u8) std.Io.Writer.Error!void {
    const s = v orelse return;
    try jw.objectField(key);
    try jw.write(s);
}

fn writeEnv(jw: *std.json.Stringify, env: []const EnvVar) std.Io.Writer.Error!void {
    if (env.len == 0) return;
    try jw.objectField("env");
    try jw.beginObject();
    for (env) |e| {
        try jw.objectField(e.name);
        try jw.write(e.value);
    }
    try jw.endObject();
}

/// Ratios are written with at most 4 decimals ("0.5", "0.3333").
fn writeRatio(jw: *std.json.Stringify, v: f64) std.Io.Writer.Error!void {
    const rounded = @round(clampSplit(v) * 10_000.0) / 10_000.0;
    try jw.print("{d}", .{rounded});
}

pub const StringifyOptions = struct {
    pretty: bool = false,
};

pub fn workspaceToJsonAlloc(gpa: Allocator, ws: Workspace, opts: StringifyOptions) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = if (opts.pretty) .indent_2 else .minified } };
    writeWorkspace(&jw, ws) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

pub fn layoutToJsonAlloc(gpa: Allocator, node: Node, opts: StringifyOptions) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = if (opts.pretty) .indent_2 else .minified } };
    writeNode(&jw, node) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Deep copy

pub fn cloneWorkspace(arena: Allocator, ws: Workspace) Allocator.Error!Workspace {
    return .{
        .name = try dupeOpt(arena, ws.name),
        .cwd = try dupeOpt(arena, ws.cwd),
        .color = try dupeOpt(arena, ws.color),
        .env = try cloneEnv(arena, ws.env),
        .setup = try dupeOpt(arena, ws.setup),
        .layout = if (ws.layout) |l| try cloneNode(arena, l) else null,
    };
}

pub fn cloneNode(arena: Allocator, node: Node) Allocator.Error!Node {
    switch (node) {
        .split => |s| {
            const kids = try arena.create([2]Node);
            kids.* = .{ try cloneNode(arena, s.children[0]), try cloneNode(arena, s.children[1]) };
            return .{ .split = .{ .direction = s.direction, .split = s.split, .children = kids } };
        },
        .pane => |p| {
            const out = try arena.alloc(Surface, p.surfaces.len);
            for (p.surfaces, out) |s, *o| o.* = .{
                .type = s.type,
                .name = try dupeOpt(arena, s.name),
                .command = try dupeOpt(arena, s.command),
                .cwd = try dupeOpt(arena, s.cwd),
                .env = try cloneEnv(arena, s.env),
                .url = try dupeOpt(arena, s.url),
                .focus = s.focus,
            };
            return .{ .pane = .{ .surfaces = out } };
        },
    }
}

fn dupeOpt(arena: Allocator, s: ?[]const u8) Allocator.Error!?[]const u8 {
    return if (s) |v| try arena.dupe(u8, v) else null;
}

fn cloneEnv(arena: Allocator, env: []const EnvVar) Allocator.Error![]const EnvVar {
    const out = try arena.alloc(EnvVar, env.len);
    for (env, out) |e, *o| o.* = .{ .name = try arena.dupe(u8, e.name), .value = try arena.dupe(u8, e.value) };
    return out;
}

// ---------------------------------------------------------------------------
// Statistics (`layout list`: PANES and SURFACES columns)

pub fn countPanes(node: ?Node) usize {
    const n = node orelse return 1;
    return switch (n) {
        .split => |s| countPanes(s.children[0]) + countPanes(s.children[1]),
        .pane => 1,
    };
}

pub fn countSurfaces(node: ?Node) usize {
    const n = node orelse return 1;
    return switch (n) {
        .split => |s| countSurfaces(s.children[0]) + countSurfaces(s.children[1]),
        .pane => |p| p.surfaces.len,
    };
}

// ---------------------------------------------------------------------------
// cwd resolution

/// True for "/x" on both styles and, on Windows, "C:\x", "C:/x", "C:" and
/// "\x"/"\\server\share".
pub fn isAbsolute(style: paths.Style, p: []const u8) bool {
    if (p.len == 0) return false;
    if (p[0] == '/') return true;
    if (style == .windows) {
        if (p[0] == '\\') return true;
        if (p.len >= 2 and std.ascii.isAlphabetic(p[0]) and p[1] == ':') return true;
    }
    return false;
}

fn isSep(style: paths.Style, c: u8) bool {
    return c == '/' or (style == .windows and c == '\\');
}

/// Resolves a cmux cwd value: unset/empty inherits `base`; "~" and "~/x"
/// go under `home`; absolute paths are literal; anything else is appended
/// to `base` (a leading "./" is dropped; "." is `base`). Without a base (or
/// home) the value is returned as written. Result is null only when both
/// the value and `base` are null.
pub fn resolveCwd(arena: Allocator, style: paths.Style, base: ?[]const u8, home: ?[]const u8, value: ?[]const u8) Allocator.Error!?[]const u8 {
    const v = value orelse return base;
    if (v.len == 0) return base;
    if (v[0] == '~' and (v.len == 1 or isSep(style, v[1]))) {
        const h = home orelse return v;
        if (v.len == 1) return h;
        return try paths.join(arena, style, &.{ h, v[2..] });
    }
    if (isAbsolute(style, v)) return v;
    var rel = v;
    while (rel.len >= 2 and rel[0] == '.' and isSep(style, rel[1])) {
        rel = rel[2..];
        while (rel.len > 0 and isSep(style, rel[0])) rel = rel[1..];
    }
    const b = base orelse return v;
    if (rel.len == 0 or std.mem.eql(u8, rel, ".")) return b;
    return try paths.join(arena, style, &.{ b, rel });
}

// ---------------------------------------------------------------------------
// Neutral workspace tree

pub const TabKind = enum {
    terminal,
    browser,
    /// A panel the layout schema cannot describe (web panels, placeholders).
    other,
};

pub const TreeTab = struct {
    kind: TabKind,
    title: ?[]const u8 = null,
    /// Absolute (resolved) directory, or null to use the app default.
    cwd: ?[]const u8 = null,
    command: ?[]const u8 = null,
    /// Effective env for this tab: workspace env overlaid by surface env.
    env: []const EnvVar = &.{},
    url: ?[]const u8 = null,
    focused: bool = false,
    /// Set only on the first terminal of the tree (depth-first): the
    /// workspace `setup` to send before `command`.
    setup: ?[]const u8 = null,
};

pub const TreePane = struct {
    tabs: []const TreeTab,
    /// Index of the selected tab.
    selected: usize = 0,
};

pub const TreeSplit = struct {
    direction: Direction,
    ratio: f64,
    a: *const TreeNode,
    b: *const TreeNode,
};

pub const TreeNode = union(enum) {
    split: TreeSplit,
    pane: TreePane,
};

pub const Tree = struct {
    name: ?[]const u8 = null,
    /// Resolved workspace base directory.
    cwd: ?[]const u8 = null,
    color: ?[]const u8 = null,
    env: []const EnvVar = &.{},
    setup: ?[]const u8 = null,
    root: TreeNode,
};

pub const BuildOptions = struct {
    style: paths.Style = .native,
    home: ?[]const u8 = null,
    /// `layout open --cwd`: replaces the workspace's own base directory.
    cwd_override: ?[]const u8 = null,
    /// Directory relative workspace cwds resolve against (the caller's cwd);
    /// also the base when the definition has no cwd.
    inherited_cwd: ?[]const u8 = null,
    /// Name used when the definition has none (the command name).
    fallback_name: ?[]const u8 = null,
};

fn mergeEnv(arena: Allocator, style: paths.Style, base: []const EnvVar, over: []const EnvVar) Allocator.Error![]const EnvVar {
    if (over.len == 0) return base;
    var out: std.ArrayList(EnvVar) = .empty;
    for (base) |e| {
        if (findEnv(style, over, e.name) == null) try out.append(arena, e);
    }
    try out.appendSlice(arena, over);
    return out.toOwnedSlice(arena);
}

fn envNameEql(style: paths.Style, a: []const u8, b: []const u8) bool {
    return if (style == .windows) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

fn findEnv(style: paths.Style, env: []const EnvVar, name: []const u8) ?EnvVar {
    for (env) |e| {
        if (envNameEql(style, e.name, name)) return e;
    }
    return null;
}

const BuildState = struct {
    arena: Allocator,
    opts: BuildOptions,
    ws: Workspace,
    base: ?[]const u8,
    setup_pending: bool,
    focus_taken: bool = false,
};

/// Converts a definition into a buildable tree: cwds resolved, env merged,
/// `setup` attached to the first terminal, `focus` resolved (the first
/// surface with focus:true in the tree gets keyboard focus; every pane
/// selects its own first focus:true tab, else tab 0).
pub fn toTree(arena: Allocator, ws: Workspace, opts: BuildOptions) Allocator.Error!Tree {
    const own = opts.cwd_override orelse ws.cwd;
    const base = try resolveCwd(arena, opts.style, opts.inherited_cwd, opts.home, own);
    var st: BuildState = .{ .arena = arena, .opts = opts, .ws = ws, .base = base, .setup_pending = ws.setup != null };
    const default_layout: Node = .{ .pane = .{ .surfaces = &.{.{}} } };
    const root = try buildNode(&st, ws.layout orelse default_layout);
    return .{
        .name = ws.name orelse opts.fallback_name,
        .cwd = base,
        .color = ws.color,
        .env = ws.env,
        .setup = ws.setup,
        .root = root,
    };
}

fn buildNode(st: *BuildState, node: Node) Allocator.Error!TreeNode {
    switch (node) {
        .split => |s| {
            const a = try st.arena.create(TreeNode);
            a.* = try buildNode(st, s.children[0]);
            const b = try st.arena.create(TreeNode);
            b.* = try buildNode(st, s.children[1]);
            return .{ .split = .{ .direction = s.direction, .ratio = clampSplit(s.split), .a = a, .b = b } };
        },
        .pane => |p| {
            const tabs = try st.arena.alloc(TreeTab, p.surfaces.len);
            var selected: ?usize = null;
            for (p.surfaces, tabs, 0..) |s, *t, i| {
                t.* = .{
                    .kind = switch (s.type) {
                        .terminal => .terminal,
                        .browser => .browser,
                    },
                    .title = s.name,
                    .cwd = try resolveCwd(st.arena, st.opts.style, st.base, st.opts.home, s.cwd),
                    .command = if (s.type == .terminal) s.command else null,
                    .env = try mergeEnv(st.arena, st.opts.style, st.ws.env, s.env),
                    .url = if (s.type == .browser) s.url else null,
                };
                if (s.type == .terminal and st.setup_pending) {
                    t.setup = st.ws.setup;
                    st.setup_pending = false;
                }
                if (s.focus) {
                    if (selected == null) selected = i;
                    if (!st.focus_taken) {
                        t.focused = true;
                        st.focus_taken = true;
                    }
                }
            }
            return .{ .pane = .{ .tabs = tabs, .selected = selected orelse 0 } };
        },
    }
}

pub const CaptureOptions = struct {
    style: paths.Style = .native,
    /// Cwds under this directory are stored relative to it; also stored as
    /// the definition's `cwd` when the tree has none.
    base_cwd: ?[]const u8 = null,
};

pub const Capture = struct {
    workspace: Workspace,
    /// Tabs that could not be captured (kind `other`).
    unsupported: usize,
};

/// Converts a live workspace tree into a definition (Save Layout / Save
/// Workspace as Layout). Unsupported tabs are dropped and counted; panes
/// left empty are removed and their split collapses into the sibling; an
/// entirely unsupported tree becomes one terminal pane.
pub fn fromTree(arena: Allocator, tree: Tree, opts: CaptureOptions) Allocator.Error!Capture {
    const base = opts.base_cwd orelse tree.cwd;
    var unsupported: usize = 0;
    const root = try captureNode(arena, tree, opts.style, base, tree.root, &unsupported);
    return .{
        .workspace = .{
            .name = tree.name,
            .cwd = base,
            .color = tree.color,
            .env = tree.env,
            .setup = tree.setup,
            .layout = root orelse Node{ .pane = .{ .surfaces = try arena.dupe(Surface, &.{.{}}) } },
        },
        .unsupported = unsupported,
    };
}

fn captureNode(arena: Allocator, tree: Tree, style: paths.Style, base: ?[]const u8, node: TreeNode, unsupported: *usize) Allocator.Error!?Node {
    switch (node) {
        .split => |s| {
            const a = try captureNode(arena, tree, style, base, s.a.*, unsupported);
            const b = try captureNode(arena, tree, style, base, s.b.*, unsupported);
            if (a == null) return b;
            if (b == null) return a;
            const kids = try arena.create([2]Node);
            kids.* = .{ a.?, b.? };
            return .{ .split = .{ .direction = s.direction, .split = clampSplit(s.ratio), .children = kids } };
        },
        .pane => |p| {
            var out: std.ArrayList(Surface) = .empty;
            for (p.tabs) |t| {
                const ty: SurfaceType = switch (t.kind) {
                    .terminal => .terminal,
                    .browser => .browser,
                    .other => {
                        unsupported.* += 1;
                        continue;
                    },
                };
                try out.append(arena, .{
                    .type = ty,
                    .name = t.title,
                    .command = if (ty == .terminal) t.command else null,
                    .cwd = try relativeCwd(arena, style, base, t.cwd),
                    .env = try envDelta(arena, style, tree.env, t.env),
                    .url = if (ty == .browser) t.url else null,
                    .focus = t.focused,
                });
            }
            if (out.items.len == 0) return null;
            return .{ .pane = .{ .surfaces = try out.toOwnedSlice(arena) } };
        },
    }
}

fn pathEql(style: paths.Style, a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (isSep(style, x) and isSep(style, y)) continue;
        if (style == .windows) {
            if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
        } else if (x != y) return false;
    }
    return true;
}

fn trimTrailingSeps(style: paths.Style, p: []const u8) []const u8 {
    var end = p.len;
    while (end > 1 and isSep(style, p[end - 1])) end -= 1;
    return p[0..end];
}

/// `cwd` relative to `base` when inside it (null when equal), else as is.
/// The result always resolves back to `cwd` through `resolveCwd`: doubled
/// separators after the base are dropped (a leading one would read as an
/// absolute path), and a first component named "~" gets a "./" prefix (it
/// would read as the home directory).
pub fn relativeCwd(arena: Allocator, style: paths.Style, base: ?[]const u8, cwd: ?[]const u8) Allocator.Error!?[]const u8 {
    const c = cwd orelse return null;
    const b_raw = base orelse return c;
    const b = trimTrailingSeps(style, b_raw);
    const ct = trimTrailingSeps(style, c);
    if (pathEql(style, b, ct)) return null;
    if (ct.len <= b.len or !pathEql(style, ct[0..b.len], b)) return c;
    // The prefix must end on a path boundary: a separator follows it, or
    // the base is a root such as "/" or "C:\".
    if (!isSep(style, ct[b.len]) and !(b.len > 0 and isSep(style, b[b.len - 1]))) return c;
    var rest = ct[b.len..];
    while (rest.len > 0 and isSep(style, rest[0])) rest = rest[1..];
    if (rest.len == 0) return null;
    if (rest[0] == '~' and (rest.len == 1 or isSep(style, rest[1])))
        return try std.fmt.allocPrint(arena, ".{c}{s}", .{ style.sep(), rest });
    return try arena.dupe(u8, rest);
}

fn envDelta(arena: Allocator, style: paths.Style, base: []const EnvVar, tab: []const EnvVar) Allocator.Error![]const EnvVar {
    var out: std.ArrayList(EnvVar) = .empty;
    for (tab) |e| {
        if (findEnv(style, base, e.name)) |b| {
            if (std.mem.eql(u8, b.value, e.value)) continue;
        }
        try out.append(arena, e);
    }
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return .init(testing.allocator);
}

const readme_example =
    \\{
    \\  "name": "dev",
    \\  "cwd": "~/src/app",
    \\  "layout": {
    \\    "direction": "horizontal",
    \\    "split": 0.5,
    \\    "children": [
    \\      { "pane": { "surfaces": [ { "type": "terminal", "command": "vim" } ] } },
    \\      { "pane": { "surfaces": [ { "type": "terminal", "command": "npm run start" } ] } }
    \\    ]
    \\  }
    \\}
;

test "unit: layouts: README example parses into two side-by-side terminals" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    var d: Diagnostics = .init(a);
    const ws = try parseWorkspaceText(a, readme_example, &d);
    try testing.expectEqual(@as(usize, 0), d.items.items.len);
    try testing.expectEqualStrings("dev", ws.name.?);
    const s = ws.layout.?.split;
    try testing.expectEqual(Direction.horizontal, s.direction);
    try testing.expectEqual(@as(f64, 0.5), s.split);
    try testing.expectEqualStrings("vim", s.children[0].pane.surfaces[0].command.?);
    try testing.expectEqualStrings("npm run start", s.children[1].pane.surfaces[0].command.?);
    try testing.expectEqual(@as(usize, 2), countPanes(ws.layout));
    try testing.expectEqual(@as(usize, 2), countSurfaces(ws.layout));
}

test "unit: layouts: split values are clamped to 0.1..0.9 and default to 0.5" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    const cases = [_]struct { []const u8, f64 }{
        .{ "0.95", 0.9 }, .{ "0.05", 0.1 }, .{ "-3", 0.1 }, .{ "1e9", 0.9 }, .{ "0.3", 0.3 }, .{ "null", 0.5 },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(a, "{{\"direction\":\"vertical\",\"split\":{s},\"children\":[{{\"surfaces\":[{{}}]}},{{\"surfaces\":[{{}}]}}]}}", .{c[0]});
        var d: Diagnostics = .init(a);
        const n = try parseLayoutText(a, src, &d);
        try testing.expectEqual(c[1], n.split.split);
    }
    var d: Diagnostics = .init(a);
    const n = try parseLayoutText(a, "{\"direction\":\"vertical\",\"children\":[{\"surfaces\":[{}]},{\"surfaces\":[{}]}]}", &d);
    try testing.expectEqual(split_default, n.split.split);
    try testing.expectEqual(@as(f64, 0.5), clampSplit(std.math.nan(f64)));
    try testing.expectEqual(@as(f64, 0.5), clampSplit(std.math.inf(f64)));
}

test "unit: layouts: both pane spellings are accepted" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    var d: Diagnostics = .init(a);
    const p1 = try parseLayoutText(a, "{\"pane\":{\"surfaces\":[{\"type\":\"browser\",\"url\":\"http://localhost:3000\"}]}}", &d);
    const p2 = try parseLayoutText(a, "{\"surfaces\":[{\"type\":\"browser\",\"url\":\"http://localhost:3000\"}]}", &d);
    try testing.expectEqualStrings(p1.pane.surfaces[0].url.?, p2.pane.surfaces[0].url.?);
    try testing.expectEqual(SurfaceType.browser, p2.pane.surfaces[0].type);
}

fn expectLayoutError(src: []const u8, needle: []const u8) !void {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    var d: Diagnostics = .init(a);
    try testing.expectError(error.InvalidLayout, parseLayoutText(a, src, &d));
    for (d.items.items) |it| {
        if (it.severity == .err and std.mem.indexOf(u8, it.message, needle) != null) return;
    }
    std.log.err("no error containing '{s}'", .{needle});
    return error.TestExpectedError;
}

test "unit: layouts: malformed trees are rejected with a message" {
    try expectLayoutError("{\"direction\":\"horizontal\",\"children\":[{\"surfaces\":[{}]}]}", "exactly two");
    try expectLayoutError("{\"direction\":\"horizontal\",\"children\":[{\"surfaces\":[{}]},{\"surfaces\":[{}]},{\"surfaces\":[{}]}]}", "exactly two");
    try expectLayoutError("{\"direction\":\"diagonal\",\"children\":[{\"surfaces\":[{}]},{\"surfaces\":[{}]}]}", "direction");
    try expectLayoutError("{\"children\":[{\"surfaces\":[{}]},{\"surfaces\":[{}]}]}", "missing 'direction'");
    try expectLayoutError("{\"direction\":\"horizontal\",\"split\":\"half\",\"children\":[{\"surfaces\":[{}]},{\"surfaces\":[{}]}]}", "split must be a number");
    try expectLayoutError("{\"surfaces\":[]}", "at least one surface");
    try expectLayoutError("{\"pane\":{}}", "missing 'surfaces'");
    try expectLayoutError("{\"surfaces\":[{\"type\":\"canvas\"}]}", "unknown surface type");
    try expectLayoutError("{\"surfaces\":[{\"env\":{\"A\":1}}]}", "must be a string");
    try expectLayoutError("{\"surfaces\":[{\"env\":{\"A=B\":\"x\"}}]}", "invalid environment variable name");
    try expectLayoutError("{\"surfaces\":[{\"focus\":\"yes\"}]}", "true or false");
    try expectLayoutError("{}", "must be a split");
    try expectLayoutError("[]", "must be an object");
    try expectLayoutError("{\"direction\":\"horizontal\",\"surfaces\":[{}]}", "not both");
    try expectLayoutError("{\"direction\":", "unexpected");
}

test "unit: layouts: errors carry JSON paths and all errors are collected" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    var d: Diagnostics = .init(a);
    const src =
        \\{"color": "#12345", "layout": {"direction": "vertical", "children": [
        \\  {"surfaces": [{"type": "terminal"}, {"type": "nope"}]},
        \\  {"surfaces": []}
        \\]}}
    ;
    try testing.expectError(error.InvalidLayout, parseWorkspaceText(a, src, &d));
    try testing.expectEqual(@as(usize, 3), d.errorCount());
    try testing.expectEqualStrings("color", d.items.items[0].path);
    try testing.expectEqualStrings("layout.children[0].surfaces[1].type", d.items.items[1].path);
    try testing.expectEqualStrings("layout.children[1].surfaces", d.items.items[2].path);
}

test "unit: layouts: unknown keys and mismatched surface fields only warn" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    var d: Diagnostics = .init(a);
    const ws = try parseWorkspaceText(a,
        \\{"bogus": 1, "$schema": "x", "layout": {"surfaces": [
        \\  {"type": "browser", "url": "https://example.com", "command": "ls"},
        \\  {"type": "terminal", "url": "https://example.com"}
        \\]}}
    , &d);
    try testing.expectEqual(@as(usize, 0), d.errorCount());
    try testing.expectEqual(@as(usize, 3), d.items.items.len);
    const ss = ws.layout.?.pane.surfaces;
    try testing.expect(ss[0].command == null);
    try testing.expect(ss[1].url == null);
}

test "unit: layouts: surface type is inferred from url when omitted" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    var d: Diagnostics = .init(a);
    const n = try parseLayoutText(a, "{\"surfaces\":[{\"url\":\"http://x\"},{\"command\":\"ls\"},{}]}", &d);
    try testing.expectEqual(SurfaceType.browser, n.pane.surfaces[0].type);
    try testing.expectEqual(SurfaceType.terminal, n.pane.surfaces[1].type);
    try testing.expectEqual(SurfaceType.terminal, n.pane.surfaces[2].type);
}

test "unit: layouts: colors accept #RRGGBB and names only" {
    try testing.expect(isValidColor("#3B82F6"));
    try testing.expect(isValidColor("#abcdef"));
    try testing.expect(isValidColor("blue"));
    try testing.expect(!isValidColor("#3B82F"));
    try testing.expect(!isValidColor("#GGGGGG"));
    try testing.expect(!isValidColor(""));
    try testing.expect(!isValidColor("   "));
}

test "unit: layouts: deep nesting is capped" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    var src: std.ArrayList(u8) = .empty;
    const depth = max_node_depth + 2;
    for (0..depth) |_| try src.appendSlice(a, "{\"direction\":\"horizontal\",\"children\":[{\"surfaces\":[{}]},");
    try src.appendSlice(a, "{\"surfaces\":[{}]}");
    for (0..depth) |_| try src.appendSlice(a, "]}");
    var d: Diagnostics = .init(a);
    try testing.expectError(error.InvalidLayout, parseLayoutText(a, src.items, &d));
    try testing.expect(std.mem.indexOf(u8, d.firstError().?.message, "nested") != null);
}

test "unit: layouts: serialization round-trips and is canonical" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    var d: Diagnostics = .init(a);
    const src =
        \\{"name":"wörk 🚀","cwd":"C:\\src","color":"#FF0000","env":{"A":"1"},"setup":"echo hi",
        \\ "layout":{"direction":"vertical","split":0.33333,"children":[
        \\  {"surfaces":[{"name":"ed","command":"vim","cwd":"sub","env":{"B":"2"},"focus":true}]},
        \\  {"pane":{"surfaces":[{"type":"browser","url":"http://localhost:3000"}]}}]}}
    ;
    const ws = try parseWorkspaceText(a, src, &d);
    const out = try workspaceToJsonAlloc(a, ws, .{});
    try testing.expectEqualStrings(
        \\{"name":"wörk 🚀","cwd":"C:\\src","color":"#FF0000","env":{"A":"1"},"setup":"echo hi","layout":{"direction":"vertical","split":0.3333,"children":[{"pane":{"surfaces":[{"type":"terminal","name":"ed","command":"vim","cwd":"sub","env":{"B":"2"},"focus":true}]}},{"pane":{"surfaces":[{"type":"browser","url":"http://localhost:3000"}]}}]}}
    , out);
    var d2: Diagnostics = .init(a);
    const again = try parseWorkspaceText(a, out, &d2);
    const out2 = try workspaceToJsonAlloc(a, again, .{ .pretty = true });
    var d3: Diagnostics = .init(a);
    const third = try parseWorkspaceText(a, out2, &d3);
    try testing.expectEqualStrings(out, try workspaceToJsonAlloc(a, third, .{}));
}

test "unit: layouts: empty workspace object serializes to {}" {
    const out = try workspaceToJsonAlloc(testing.allocator, .{}, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{}", out);
}

test "unit: layouts: clone is independent of the source arena" {
    var ar = testArena();
    var d: Diagnostics = .init(ar.allocator());
    const ws = try parseWorkspaceText(ar.allocator(), readme_example, &d);
    var ar2 = testArena();
    defer ar2.deinit();
    const copy = try cloneWorkspace(ar2.allocator(), ws);
    ar.deinit();
    const out = try workspaceToJsonAlloc(ar2.allocator(), copy, .{});
    try testing.expect(std.mem.indexOf(u8, out, "npm run start") != null);
}

test "unit: layouts: text parsers do not borrow the caller's buffer" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    const wbuf = try testing.allocator.dupe(u8, readme_example);
    defer testing.allocator.free(wbuf);
    const lbuf = try testing.allocator.dupe(u8, "{\"surfaces\":[{\"name\":\"ed\",\"command\":\"vim\",\"env\":{\"K\":\"v\"}}]}");
    defer testing.allocator.free(lbuf);
    var d: Diagnostics = .init(a);
    const ws = try parseWorkspaceText(a, wbuf, &d);
    const n = try parseLayoutText(a, lbuf, &d);
    // A caller that reuses or frees its file buffer must not change the result.
    @memset(wbuf, 'X');
    @memset(lbuf, 'X');
    try testing.expectEqualStrings("dev", ws.name.?);
    try testing.expectEqualStrings("~/src/app", ws.cwd.?);
    try testing.expectEqualStrings("npm run start", ws.layout.?.split.children[1].pane.surfaces[0].command.?);
    const s = n.pane.surfaces[0];
    try testing.expectEqualStrings("ed", s.name.?);
    try testing.expectEqualStrings("K", s.env[0].name);
    try testing.expectEqualStrings("v", s.env[0].value);
}

test "unit: layouts: cwd resolution follows unset, relative, home and absolute rules" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    const P = paths.Style.posix;
    try testing.expectEqualStrings("/w", (try resolveCwd(a, P, "/w", "/home/u", null)).?);
    try testing.expectEqualStrings("/w", (try resolveCwd(a, P, "/w", "/home/u", "")).?);
    try testing.expectEqualStrings("/w", (try resolveCwd(a, P, "/w", "/home/u", ".")).?);
    try testing.expectEqualStrings("/w/api", (try resolveCwd(a, P, "/w", "/home/u", "api")).?);
    try testing.expectEqualStrings("/w/api/x", (try resolveCwd(a, P, "/w/", "/home/u", "./api/x")).?);
    try testing.expectEqualStrings("/home/u", (try resolveCwd(a, P, "/w", "/home/u", "~")).?);
    try testing.expectEqualStrings("/home/u/src", (try resolveCwd(a, P, "/w", "/home/u", "~/src")).?);
    try testing.expectEqualStrings("~user/x", (try resolveCwd(a, P, null, "/home/u", "~user/x")).?);
    try testing.expectEqualStrings("/etc", (try resolveCwd(a, P, "/w", "/home/u", "/etc")).?);
    try testing.expectEqualStrings("api", (try resolveCwd(a, P, null, null, "api")).?);
    try testing.expectEqualStrings("~/x", (try resolveCwd(a, P, null, null, "~/x")).?);
    try testing.expect((try resolveCwd(a, P, null, null, null)) == null);
    const W = paths.Style.windows;
    try testing.expectEqualStrings("C:\\w\\api", (try resolveCwd(a, W, "C:\\w", "C:\\Users\\u", "api")).?);
    try testing.expectEqualStrings("C:\\Users\\u\\src", (try resolveCwd(a, W, "C:\\w", "C:\\Users\\u", "~\\src")).?);
    try testing.expectEqualStrings("D:/x", (try resolveCwd(a, W, "C:\\w", null, "D:/x")).?);
    try testing.expectEqualStrings("\\\\srv\\share", (try resolveCwd(a, W, "C:\\w", null, "\\\\srv\\share")).?);
    try testing.expectEqualStrings("C:\\w\\ünï", (try resolveCwd(a, W, "C:\\w", null, ".\\ünï")).?);
}

test "unit: layouts: toTree resolves cwds, merges env, attaches setup and focus" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    var d: Diagnostics = .init(a);
    const ws = try parseWorkspaceText(a,
        \\{"name":"dev","cwd":"proj","env":{"A":"1","B":"1"},"setup":"source .env",
        \\ "layout":{"direction":"horizontal","children":[
        \\   {"surfaces":[{"type":"browser","url":"http://x"},{"command":"npm run dev","env":{"B":"2"}}]},
        \\   {"surfaces":[{"cwd":"/abs","focus":true},{"focus":true}]}]}}
    , &d);
    const t = try toTree(a, ws, .{ .style = .posix, .home = "/home/u", .inherited_cwd = "/w" });
    try testing.expectEqualStrings("/w/proj", t.cwd.?);
    const left = t.root.split.a.pane;
    const right = t.root.split.b.pane;
    try testing.expectEqual(TabKind.browser, left.tabs[0].kind);
    try testing.expect(left.tabs[0].setup == null);
    try testing.expectEqualStrings("source .env", left.tabs[1].setup.?);
    try testing.expectEqualStrings("/w/proj", left.tabs[1].cwd.?);
    try testing.expectEqual(@as(usize, 2), left.tabs[1].env.len);
    try testing.expectEqualStrings("A", left.tabs[1].env[0].name);
    try testing.expectEqualStrings("2", left.tabs[1].env[1].value);
    try testing.expect(right.tabs[0].setup == null);
    try testing.expectEqualStrings("/abs", right.tabs[0].cwd.?);
    try testing.expect(right.tabs[0].focused);
    try testing.expect(!right.tabs[1].focused);
    try testing.expectEqual(@as(usize, 0), right.selected);
}

test "unit: layouts: every pane shows its own focus tab and keyboard focus goes to the first" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    var d: Diagnostics = .init(a);
    const ws = try parseWorkspaceText(a,
        \\{"layout":{"direction":"horizontal","children":[
        \\  {"surfaces":[{},{"focus":true}]},
        \\  {"direction":"vertical","children":[{"surfaces":[{},{},{"focus":true}]},{"surfaces":[{},{}]}]}]}}
    , &d);
    const t = try toTree(a, ws, .{ .style = .posix });
    const left = t.root.split.a.pane;
    const top_right = t.root.split.b.split.a.pane;
    const bottom_right = t.root.split.b.split.b.pane;
    try testing.expectEqual(@as(usize, 1), left.selected);
    try testing.expect(left.tabs[1].focused);
    try testing.expectEqual(@as(usize, 2), top_right.selected);
    try testing.expect(!top_right.tabs[2].focused);
    try testing.expectEqual(@as(usize, 0), bottom_right.selected);
}

test "unit: layouts: cwd override re-roots the layout (layout open --cwd)" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    var d: Diagnostics = .init(a);
    const ws = try parseWorkspaceText(a, "{\"cwd\":\"/old\",\"layout\":{\"surfaces\":[{\"cwd\":\"api\"}]}}", &d);
    const t = try toTree(a, ws, .{ .style = .posix, .home = "/home/u", .cwd_override = "~/x" });
    try testing.expectEqualStrings("/home/u/x", t.cwd.?);
    try testing.expectEqualStrings("/home/u/x/api", t.root.pane.tabs[0].cwd.?);
}

test "unit: layouts: toTree without a layout gives one terminal and the fallback name" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    const t = try toTree(a, .{ .setup = "make" }, .{ .style = .posix, .fallback_name = "Build" });
    try testing.expectEqualStrings("Build", t.name.?);
    try testing.expectEqual(@as(usize, 1), t.root.pane.tabs.len);
    try testing.expectEqual(TabKind.terminal, t.root.pane.tabs[0].kind);
    try testing.expectEqualStrings("make", t.root.pane.tabs[0].setup.?);
    try testing.expect(t.cwd == null);
}

test "unit: layouts: fromTree captures relative cwds, env deltas and counts unsupported tabs" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    const web = TreeNode{ .pane = .{ .tabs = &.{.{ .kind = .other, .title = "Markdown" }} } };
    const right = TreeNode{ .pane = .{ .tabs = &.{
        .{ .kind = .browser, .url = "http://localhost:3000", .command = "ignored" },
        .{ .kind = .other },
    } } };
    const left = TreeNode{ .pane = .{ .tabs = &.{
        .{ .kind = .terminal, .cwd = "C:\\SRC\\App\\api", .command = "claude", .env = &.{ .{ .name = "A", .value = "1" }, .{ .name = "B", .value = "2" } }, .focused = true },
        .{ .kind = .terminal, .cwd = "c:/src/app" },
        .{ .kind = .terminal, .cwd = "D:\\other" },
    } } };
    const inner = TreeNode{ .split = .{ .direction = .vertical, .ratio = 0.95, .a = &right, .b = &web } };
    const tree: Tree = .{
        .name = "dev",
        .cwd = "C:\\src\\app\\",
        .env = &.{.{ .name = "a", .value = "1" }},
        .root = .{ .split = .{ .direction = .horizontal, .ratio = 0.25, .a = &left, .b = &inner } },
    };
    const cap = try fromTree(a, tree, .{ .style = .windows });
    try testing.expectEqual(@as(usize, 2), cap.unsupported);
    const s = cap.workspace.layout.?.split;
    try testing.expectEqual(@as(f64, 0.25), s.split);
    const l = s.children[0].pane.surfaces;
    try testing.expectEqualStrings("api", l[0].cwd.?);
    try testing.expect(l[0].focus);
    try testing.expectEqual(@as(usize, 1), l[0].env.len);
    try testing.expectEqualStrings("B", l[0].env[0].name);
    try testing.expect(l[1].cwd == null);
    try testing.expectEqualStrings("D:\\other", l[2].cwd.?);
    // The web-only pane vanished and its split collapsed into the browser pane.
    const r = s.children[1].pane.surfaces;
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqual(SurfaceType.browser, r[0].type);
    try testing.expect(r[0].command == null);
}

test "unit: layouts: fromTree of a fully unsupported tree yields one terminal" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    const tree: Tree = .{ .root = .{ .pane = .{ .tabs = &.{ .{ .kind = .other }, .{ .kind = .other } } } } };
    const cap = try fromTree(a, tree, .{ .style = .posix, .base_cwd = "/w" });
    try testing.expectEqual(@as(usize, 2), cap.unsupported);
    try testing.expectEqual(@as(usize, 1), countSurfaces(cap.workspace.layout));
    try testing.expectEqualStrings("/w", cap.workspace.cwd.?);
}

test "unit: layouts: save then open with another cwd recreates the same panes" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    const p1 = TreeNode{ .pane = .{ .tabs = &.{.{ .kind = .terminal, .cwd = "/w/app", .command = "vim" }} } };
    const p2 = TreeNode{ .pane = .{ .tabs = &.{.{ .kind = .terminal, .cwd = "/w/app/web", .command = "npm start" }} } };
    const live: Tree = .{ .cwd = "/w/app", .root = .{ .split = .{ .direction = .horizontal, .ratio = 0.5, .a = &p1, .b = &p2 } } };
    const cap = try fromTree(a, live, .{ .style = .posix });
    const json = try workspaceToJsonAlloc(a, cap.workspace, .{});
    var d: Diagnostics = .init(a);
    const ws = try parseWorkspaceText(a, json, &d);
    const t = try toTree(a, ws, .{ .style = .posix, .home = "/home/u", .cwd_override = "~/x" });
    try testing.expectEqualStrings("/home/u/x", t.root.split.a.pane.tabs[0].cwd.?);
    try testing.expectEqualStrings("/home/u/x/web", t.root.split.b.pane.tabs[0].cwd.?);
    try testing.expectEqualStrings("npm start", t.root.split.b.pane.tabs[0].command.?);
}

test "unit: layouts: relativeCwd handles roots and prefixes that are not path boundaries" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectEqualStrings("/w/appx", (try relativeCwd(a, .posix, "/w/app", "/w/appx")).?);
    try testing.expectEqualStrings("etc", (try relativeCwd(a, .posix, "/", "/etc")).?);
    try testing.expectEqualStrings("Users", (try relativeCwd(a, .windows, "C:\\", "C:\\Users")).?);
    try testing.expect((try relativeCwd(a, .posix, "/w/", "/w")) == null);
    try testing.expect((try relativeCwd(a, .posix, "/w", null)) == null);
    try testing.expectEqualStrings("/x", (try relativeCwd(a, .posix, null, "/x")).?);
}

test "unit: layouts: relativeCwd results resolve back to the captured directory" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    const cases = [_]struct { paths.Style, []const u8, []const u8, []const u8, []const u8 }{
        // style, base, captured cwd, relative value, where re-opening lands
        .{ .posix, "/w", "/w//x", "x", "/w/x" },
        .{ .posix, "/", "//etc", "etc", "/etc" },
        .{ .posix, "/w", "/w/~/x", "./~/x", "/w/~/x" },
        .{ .posix, "/w", "/w/~", "./~", "/w/~" },
        .{ .posix, "/w", "/w/~x", "~x", "/w/~x" },
        .{ .windows, "C:\\w", "C:\\w\\\\x", "x", "C:\\w\\x" },
        .{ .windows, "C:\\w", "c:/w/~", ".\\~", "C:\\w\\~" },
    };
    for (cases) |c| {
        const rel = (try relativeCwd(a, c[0], c[1], c[2])).?;
        try testing.expectEqualStrings(c[3], rel);
        // Not an absolute path and not the home directory.
        const back = (try resolveCwd(a, c[0], c[1], "/home/u", rel)).?;
        try testing.expectEqualStrings(c[4], back);
    }
}

test "unit: layouts: huge layouts parse and count" {
    var ar = testArena();
    defer ar.deinit();
    const a = ar.allocator();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "{\"surfaces\":[");
    for (0..5000) |i| {
        if (i > 0) try src.append(a, ',');
        try src.print(a, "{{\"name\":\"t{d}\",\"command\":\"echo {d}\"}}", .{ i, i });
    }
    try src.appendSlice(a, "]}");
    var d: Diagnostics = .init(a);
    const n = try parseLayoutText(a, src.items, &d);
    try testing.expectEqual(@as(usize, 5000), countSurfaces(n));
}
