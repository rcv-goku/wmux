//! cmux.json `actions` / `commands` model (persistence-actions-registry,
//! persistence-commands-shell, persistence-workspace-layout-definitions,
//! persistence-ui-surface-tab-bar-buttons, persistence-ui-new-workspace-button):
//! parse and validate one config file into actions, commands and the `ui`
//! placement keys; merge layers (packs < global < project) into a registry;
//! resolve placements (Command Palette rows, surface tab bar buttons, the
//! new-workspace plus button and its context menu); plan a run (text to
//! type, builtin to invoke, workspace to build, setting to change) with
//! `${name}` variable substitution.
//!
//! Workspace definitions are kept as raw JSON nodes here; the layouts
//! feature parses them (`FileContext.validate_workspace` lets the app wire
//! its validator in without a cross-feature import). Pure: std + wmux_proto.
//! Every result lives in a caller-provided arena. `parseConfig` also borrows
//! the root node's source text (jsonc keeps unescaped strings as slices of
//! its input); `parseConfigText` copies its input into the arena first.

const std = @import("std");
const proto = @import("wmux_proto");
const jsonc = proto.jsonc;
const strokes = proto.strokes;
const shell_quote = proto.shell_quote;

const Allocator = std.mem.Allocator;

/// Where an action or command was declared.
pub const Source = enum {
    builtin,
    /// The global cmux.json/wmux.json or one of its packs.
    global,
    /// A project file (.wmux/wmux.json, .cmux/cmux.json, ...). Needs trust.
    project,
};

pub const Kind = enum { builtin, command, agent, workspaceCommand, workspace, setting, settingPreset };

pub const Target = enum {
    currentTerminal,
    newTabInCurrentPane,

    pub const default: Target = .newTabInCurrentPane;
};

pub const Restart = enum {
    ignore,
    recreate,
    confirm,
    new,

    pub const default: Restart = .new;
};

/// Image icon file extensions (lowercase, without the dot). jpg and tif are
/// accepted as spellings of jpeg and tiff.
pub const image_extensions = [_][]const u8{
    "svg", "pdf", "png", "jpeg", "jpg", "gif", "tiff", "tif", "bmp", "heic", "heif", "webp", "avif", "ico", "icns",
};

pub const emoji_scale_max: f64 = 10;

pub const Icon = union(enum) {
    /// A named symbol (SF Symbol names on macOS; mapped to Segoe glyphs).
    symbol: []const u8,
    emoji: struct { value: []const u8, scale: f64 = 1 },
    /// Path as written, relative to the config file's directory.
    image: []const u8,
};

pub const SettingOp = union(enum) {
    set: jsonc.Node,
    toggle,
    cycle: []const jsonc.Node,
    unset,
};

pub const Body = union(Kind) {
    /// Built-in action id (normalized to `cmux.*` for known built-ins).
    builtin: []const u8,
    command: struct { command: []const u8, target: Target = Target.default },
    agent: struct { agent: []const u8, args: []const []const u8 = &.{}, target: Target = Target.default },
    /// Name of a `commands` entry.
    workspaceCommand: []const u8,
    workspace: jsonc.Node,
    setting: struct { path: []const u8, op: SettingOp },
    settingPreset: []const u8,
};

pub const Action = struct {
    id: []const u8,
    source: Source,
    config_path: ?[]const u8 = null,
    project_root: ?[]const u8 = null,
    title: ?[]const u8 = null,
    subtitle: ?[]const u8 = null,
    keywords: []const []const u8 = &.{},
    palette: bool = true,
    shortcut: ?strokes.Trigger = null,
    icon: ?Icon = null,
    tooltip: ?[]const u8 = null,
    confirm: bool = false,
    /// Null = default (workspace actions shown, others hidden).
    new_workspace_menu: ?bool = null,
    restart: Restart = Restart.default,
    body: Body,

    pub fn kind(self: *const Action) Kind {
        return std.meta.activeTag(self.body);
    }

    /// Whether the action is offered in the plus-button menu.
    pub fn inNewWorkspaceMenu(self: *const Action) bool {
        return self.new_workspace_menu orelse (self.kind() == .workspace);
    }
};

pub const Command = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    keywords: []const []const u8 = &.{},
    confirm: bool = false,
    restart: Restart = Restart.default,
    source: Source,
    config_path: ?[]const u8 = null,
    project_root: ?[]const u8 = null,
    body: union(enum) {
        /// Shell text typed into the focused terminal.
        shell: []const u8,
        /// Workspace definition (its `name` falls back to the command name).
        workspace: jsonc.Node,
    },
};

// ---------------------------------------------------------------------------
// Built-ins

pub const Builtin = struct {
    id: []const u8,
    title: []const u8,
    /// Shown only when Cloud Machines is enabled.
    cloud: bool = false,
};

pub const builtins = [_]Builtin{
    .{ .id = "cmux.newTerminal", .title = "New Terminal" },
    .{ .id = "cmux.newBrowser", .title = "New Browser" },
    .{ .id = "cmux.splitRight", .title = "Split Right" },
    .{ .id = "cmux.splitDown", .title = "Split Down" },
    .{ .id = "cmux.newWorkspace", .title = "New Workspace" },
    .{ .id = "cmux.newCloudWorkspace", .title = "New Cloud Workspace", .cloud = true },
    .{ .id = "cmux.newCloudMachine", .title = "New Cloud Machine", .cloud = true },
    .{ .id = "cmux.copyWorkingDirectory", .title = "Copy Working Directory" },
    .{ .id = "cmux.copyProjectRoot", .title = "Copy Project Root" },
    .{ .id = "cmux.copyScreen", .title = "Copy Screen" },
    .{ .id = "cmux.newAgentChat", .title = "New Agent Chat" },
    .{ .id = "cmux.configEditor", .title = "Open Config Editor" },
};

pub const default_tab_bar_buttons = [_][]const u8{ "cmux.newTerminal", "cmux.newBrowser", "cmux.splitRight", "cmux.splitDown" };
pub const default_context_menu = [_][]const u8{ "cmux.newWorkspace", "cmux.newCloudWorkspace", "cmux.newCloudMachine", "cmux.newTerminal", "cmux.newBrowser" };

pub fn findBuiltin(id: []const u8) ?*const Builtin {
    for (&builtins) |*b| {
        if (std.mem.eql(u8, b.id, id)) return b;
    }
    return null;
}

/// `wmux.newTerminal` and `cmux.newTerminal` name the same built-in; other
/// ids are returned unchanged.
pub fn normalizeId(id: []const u8) []const u8 {
    if (std.mem.startsWith(u8, id, "wmux.")) {
        for (&builtins) |*b| {
            if (std.mem.eql(u8, b.id["cmux.".len..], id["wmux.".len..])) return b.id;
        }
    }
    return id;
}

/// Id under which a legacy `commands` entry appears in the palette and can
/// be referenced from placements. An action with this id shadows the row.
pub fn commandActionIdAlloc(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, command_id_prefix ++ "{s}", .{name});
}

pub const command_id_prefix = "command:";

// ---------------------------------------------------------------------------
// Diagnostics

pub const Severity = enum { err, warning };

pub const Issue = struct {
    severity: Severity,
    /// JSON path ("actions.my-codex.icon.path").
    path: []const u8,
    message: []const u8,
};

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
};

/// Palette row title shown when a config has a schema error.
pub const schema_error_title = "cmux.json Schema Error";

fn childPath(arena: Allocator, base: []const u8, key: []const u8) Allocator.Error![]const u8 {
    if (base.len == 0) return arena.dupe(u8, key);
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ base, key });
}

fn indexPath(arena: Allocator, base: []const u8, i: usize) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}[{d}]", .{ base, i });
}

fn isBlank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t\r\n").len == 0;
}

// ---------------------------------------------------------------------------
// Parsing one config file

pub const WorkspaceValidator = *const fn (arena: Allocator, node: *const jsonc.Node) Allocator.Error!?[]const u8;

pub const FileContext = struct {
    source: Source,
    config_path: ?[]const u8 = null,
    project_root: ?[]const u8 = null,
    /// cmux.json uses macOS strokes; wmux.json literal Windows strokes.
    dialect: strokes.Dialect = .mac,
    /// Returns an error message when a workspace definition is invalid.
    validate_workspace: ?WorkspaceValidator = null,
};

/// A tab bar button or context-menu entry that references an action.
pub const ButtonEntry = struct {
    action: []const u8,
    title: ?[]const u8 = null,
    icon: ?Icon = null,
    tooltip: ?[]const u8 = null,
};

pub const MenuEntry = union(enum) {
    separator,
    ref: ButtonEntry,
    /// An action object written inline in the menu.
    inline_action: Action,
};

pub const Ui = struct {
    /// ui.surfaceTabBar.buttons (or legacy root surfaceTabBarButtons).
    tab_bar_buttons: ?[]const ButtonEntry = null,
    /// ui.newWorkspace.action.
    new_workspace_action: ?[]const u8 = null,
    /// Legacy root newWorkspaceCommand (a `commands` entry name).
    new_workspace_command: ?[]const u8 = null,
    /// ui.newWorkspace.contextMenu (alias rightClick).
    context_menu: ?[]const MenuEntry = null,
};

pub const Config = struct {
    source: Source,
    config_path: ?[]const u8 = null,
    actions: []const Action = &.{},
    commands: []const Command = &.{},
    ui: Ui = .{},
};

/// Parses one config file's root object. Invalid entries are skipped and
/// reported in `diags` (errors) so the rest of the file still applies; the
/// caller decides whether a file with errors falls back (schema error row).
/// Ids, titles and command strings may be slices of `root`'s source text,
/// so that text must outlive the result.
pub fn parseConfig(arena: Allocator, root: *const jsonc.Node, ctx: FileContext, diags: *Diagnostics) Allocator.Error!Config {
    var cfg: Config = .{ .source = ctx.source, .config_path = ctx.config_path };
    if (root.data != .object) {
        try diags.add(.err, "", "config root must be an object, not {s}", .{root.kindName()});
        return cfg;
    }
    if (root.get("actions")) |an| cfg.actions = try parseActions(arena, an, ctx, diags);
    if (root.get("commands")) |cn| cfg.commands = try parseCommands(arena, cn, ctx, diags);
    cfg.ui = try parseUi(arena, root, ctx, diags);
    return cfg;
}

/// Parses JSONC text; a syntax error is reported as one error issue. The
/// result lives entirely in `arena`, so the caller may free `src`.
pub fn parseConfigText(arena: Allocator, src: []const u8, ctx: FileContext, diags: *Diagnostics) Allocator.Error!Config {
    // jsonc keeps unescaped strings as slices of its input: parse a copy so
    // nothing in the result points into the caller's buffer.
    const text = try arena.dupe(u8, src);
    var jd: jsonc.Diagnostic = .{};
    const root = jsonc.parseInto(arena, text, .{}, &jd) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => {
            try diags.add(.err, "", "{d}:{d}: {s}", .{ jd.pos.line, jd.pos.col, jd.message });
            return .{ .source = ctx.source, .config_path = ctx.config_path };
        },
    };
    return parseConfig(arena, &root, ctx, diags);
}

fn parseActions(arena: Allocator, node: *const jsonc.Node, ctx: FileContext, diags: *Diagnostics) Allocator.Error![]const Action {
    const members = switch (node.data) {
        .object => |m| m,
        .null => return &.{},
        else => {
            try diags.add(.err, "actions", "'actions' must be an object mapping ids to actions, not {s}", .{node.kindName()});
            return &.{};
        },
    };
    var out: std.ArrayList(Action) = .empty;
    for (members) |*m| {
        const path = try childPath(arena, "actions", m.key);
        if (isBlank(m.key)) {
            try diags.add(.err, path, "action id must not be blank", .{});
            continue;
        }
        const id = normalizeId(m.key);
        const action = (try parseAction(arena, id, &m.value, ctx, path, diags)) orelse continue;
        // A repeated id (also wmux./cmux. spellings of one built-in): last wins.
        var replaced = false;
        for (out.items) |*o| {
            if (std.mem.eql(u8, o.id, id)) {
                try diags.add(.warning, path, "action '{s}' is defined more than once; the last definition wins", .{id});
                o.* = action;
                replaced = true;
            }
        }
        if (!replaced) try out.append(arena, action);
    }
    return out.toOwnedSlice(arena);
}

const common_action_keys = [_][]const u8{
    "type",             "title",  "subtitle", "description", "keywords", "palette", "shortcut", "icon", "tooltip", "confirm",
    "newWorkspaceMenu", "target", "restart",  "id",
};
const body_keys = [_][]const u8{
    "builtin", "command", "agent", "args", "commandName", "name", "workspace", "path", "set", "toggle", "cycle", "unset", "preset",
};

fn isKnownKey(key: []const u8) bool {
    for (common_action_keys) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    for (body_keys) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return std.mem.startsWith(u8, key, "$");
}

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

fn stringList(arena: Allocator, obj: *const jsonc.Node, key: []const u8, base: []const u8, diags: *Diagnostics) Allocator.Error![]const []const u8 {
    const v = obj.get(key) orelse return &.{};
    const path = try childPath(arena, base, key);
    const items = switch (v.data) {
        .null => return &.{},
        .array => |a| a,
        else => {
            try diags.add(.err, path, "'{s}' must be an array of strings", .{key});
            return &.{};
        },
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (items, 0..) |*it, i| {
        const s = it.asString() orelse {
            try diags.add(.err, try indexPath(arena, path, i), "'{s}' entries must be strings, not {s}", .{ key, it.kindName() });
            continue;
        };
        try out.append(arena, s);
    }
    return out.toOwnedSlice(arena);
}

fn parseEnumField(comptime E: type, arena: Allocator, obj: *const jsonc.Node, key: []const u8, base: []const u8, diags: *Diagnostics) Allocator.Error!?E {
    const s = (try optString(arena, obj, key, base, diags)) orelse return null;
    if (std.meta.stringToEnum(E, s)) |e| return e;
    var names: std.ArrayList(u8) = .empty;
    inline for (@typeInfo(E).@"enum".fields, 0..) |f, i| {
        if (i > 0) try names.appendSlice(arena, ", ");
        try names.appendSlice(arena, f.name);
    }
    try diags.add(.err, try childPath(arena, base, key), "unknown {s} '{s}' (expected one of {s})", .{ key, s, names.items });
    return null;
}

fn shortcutErrorText(e: strokes.ParseError) []const u8 {
    return switch (e) {
        error.Empty => "empty shortcut or empty stroke segment",
        error.UnknownModifier => "unknown modifier",
        error.UnknownKey => "unknown key",
        error.DuplicateModifier => "duplicate modifier",
        error.MissingKey => "shortcut has modifiers but no key",
        error.CmdNotAllowed => strokes.cmd_hint,
        error.TooManyStrokes => "a chord has at most two strokes",
    };
}

/// "cmd+shift+t", "cmd+k cmd+c" or ["cmd+k", "cmd+c"].
pub fn parseShortcut(v: *const jsonc.Node, dialect: strokes.Dialect, path: []const u8, diags: *Diagnostics) Allocator.Error!?strokes.Trigger {
    switch (v.data) {
        .null => return null,
        .string => |s| return strokes.Trigger.parse(s, dialect) catch |e| {
            try diags.add(.err, path, "invalid shortcut '{s}': {s}", .{ s, shortcutErrorText(e) });
            return null;
        },
        .array => |items| {
            if (items.len == 0 or items.len > 2) {
                try diags.add(.err, path, "a shortcut array holds one stroke or a two-stroke chord", .{});
                return null;
            }
            var parts: [2][]const u8 = undefined;
            for (items, 0..) |*it, i| {
                parts[i] = it.asString() orelse {
                    try diags.add(.err, path, "shortcut strokes must be strings", .{});
                    return null;
                };
            }
            const t = if (items.len == 1)
                strokes.Trigger{ .first = strokes.Stroke.parse(parts[0], dialect) catch |e| {
                    try diags.add(.err, path, "invalid shortcut '{s}': {s}", .{ parts[0], shortcutErrorText(e) });
                    return null;
                } }
            else
                strokes.Trigger.parseChord(parts[0], parts[1], dialect) catch |e| {
                    try diags.add(.err, path, "invalid shortcut chord: {s}", .{shortcutErrorText(e)});
                    return null;
                };
            return t;
        },
        else => {
            try diags.add(.err, path, "shortcut must be a string or an array of strokes", .{});
            return null;
        },
    }
}

/// Lowercase extension of an image icon path, or null without one.
pub fn imageExtension(path: []const u8) ?[]const u8 {
    const base_start = if (std.mem.lastIndexOfAny(u8, path, "/\\")) |i| i + 1 else 0;
    const base = path[base_start..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    if (dot == 0 or dot + 1 == base.len) return null;
    return base[dot + 1 ..];
}

pub fn isSupportedImage(path: []const u8) bool {
    const ext = imageExtension(path) orelse return false;
    for (image_extensions) |e| {
        if (std.ascii.eqlIgnoreCase(e, ext)) return true;
    }
    return false;
}

pub fn parseIcon(arena: Allocator, v: *const jsonc.Node, path: []const u8, diags: *Diagnostics) Allocator.Error!?Icon {
    if (v.data == .null) return null;
    if (v.data != .object) {
        try diags.add(.err, path, "icon must be an object {{type: symbol|emoji|image, ...}}", .{});
        return null;
    }
    const ty = (try optString(arena, v, "type", path, diags)) orelse {
        try diags.add(.err, path, "icon is missing 'type' (symbol, emoji or image)", .{});
        return null;
    };
    if (std.mem.eql(u8, ty, "symbol")) {
        const name = (try optString(arena, v, "name", path, diags)) orelse "";
        if (isBlank(name)) {
            try diags.add(.err, path, "symbol icon needs a non-blank 'name'", .{});
            return null;
        }
        return .{ .symbol = name };
    }
    if (std.mem.eql(u8, ty, "emoji")) {
        const value = (try optString(arena, v, "value", path, diags)) orelse "";
        if (isBlank(value)) {
            try diags.add(.err, path, "emoji icon needs a non-blank 'value'", .{});
            return null;
        }
        var scale: f64 = 1;
        if (v.get("scale")) |s| switch (s.data) {
            .null => {},
            .number => {
                const f = s.asFloat() orelse 1;
                if (!(f > 0 and f <= emoji_scale_max)) {
                    try diags.add(.err, try childPath(arena, path, "scale"), "emoji scale must be greater than 0 and at most {d}", .{emoji_scale_max});
                    return null;
                }
                scale = f;
            },
            else => {
                try diags.add(.err, try childPath(arena, path, "scale"), "emoji scale must be a number", .{});
                return null;
            },
        };
        return .{ .emoji = .{ .value = value, .scale = scale } };
    }
    if (std.mem.eql(u8, ty, "image")) {
        const p = (try optString(arena, v, "path", path, diags)) orelse "";
        if (isBlank(p)) {
            try diags.add(.err, path, "image icon needs a non-blank 'path'", .{});
            return null;
        }
        if (!isSupportedImage(p)) {
            try diags.add(.err, try childPath(arena, path, "path"), "unsupported image type '{s}' (svg, pdf, png, jpeg, gif, tiff, bmp, heic, heif, webp, avif, ico, icns)", .{p});
            return null;
        }
        return .{ .image = p };
    }
    try diags.add(.err, try childPath(arena, path, "type"), "unknown icon type '{s}' (expected symbol, emoji or image)", .{ty});
    return null;
}

/// Infers the kind from the body fields when `type` is absent.
fn inferKind(obj: *const jsonc.Node) union(enum) { none, ambiguous, kind: Kind } {
    const probes = [_]struct { []const u8, Kind }{
        .{ "builtin", .builtin },              .{ "workspace", .workspace },  .{ "agent", .agent },
        .{ "commandName", .workspaceCommand }, .{ "preset", .settingPreset }, .{ "path", .setting },
        .{ "command", .command },
    };
    var found: ?Kind = null;
    for (probes) |p| {
        if (obj.get(p[0]) == null) continue;
        // Two runnable fields (e.g. builtin and command) need an explicit type.
        if (found != null) return .ambiguous;
        found = p[1];
    }
    return if (found) |k| .{ .kind = k } else .none;
}

/// Parses one action object; null (with errors in `diags`) when invalid.
pub fn parseAction(arena: Allocator, id: []const u8, v: *const jsonc.Node, ctx: FileContext, path: []const u8, diags: *Diagnostics) Allocator.Error!?Action {
    if (v.data != .object) {
        try diags.add(.err, path, "action must be an object, not {s}", .{v.kindName()});
        return null;
    }
    const before = diags.errorCount();
    for (v.data.object) |m| {
        if (!isKnownKey(m.key)) try diags.add(.warning, try childPath(arena, path, m.key), "unknown key '{s}' is ignored", .{m.key});
    }
    const kind: Kind = blk: {
        if (try optString(arena, v, "type", path, diags)) |t| {
            if (std.meta.stringToEnum(Kind, t)) |k| break :blk k;
            try diags.add(.err, try childPath(arena, path, "type"), "unknown action type '{s}' (expected builtin, command, agent, workspaceCommand, workspace, setting or settingPreset)", .{t});
            return null;
        }
        switch (inferKind(v)) {
            .kind => |k| break :blk k,
            .ambiguous => {
                try diags.add(.err, path, "cannot infer the action type from its fields; set 'type'", .{});
                return null;
            },
            .none => {
                try diags.add(.err, path, "action has no runnable field (builtin, command, agent, commandName, workspace, path or preset)", .{});
                return null;
            },
        }
    };

    var a: Action = .{
        .id = id,
        .source = ctx.source,
        .config_path = ctx.config_path,
        .project_root = ctx.project_root,
        .body = undefined,
    };
    a.title = try optString(arena, v, "title", path, diags);
    a.subtitle = (try optString(arena, v, "subtitle", path, diags)) orelse (try optString(arena, v, "description", path, diags));
    a.keywords = try stringList(arena, v, "keywords", path, diags);
    a.palette = (try optBool(arena, v, "palette", path, diags)) orelse true;
    a.tooltip = try optString(arena, v, "tooltip", path, diags);
    a.confirm = (try optBool(arena, v, "confirm", path, diags)) orelse false;
    a.new_workspace_menu = try optBool(arena, v, "newWorkspaceMenu", path, diags);
    if (v.get("shortcut")) |s| a.shortcut = try parseShortcut(s, ctx.dialect, try childPath(arena, path, "shortcut"), diags);
    if (v.get("icon")) |ic| a.icon = try parseIcon(arena, ic, try childPath(arena, path, "icon"), diags);
    const target = (try parseEnumField(Target, arena, v, "target", path, diags)) orelse Target.default;
    if (v.get("target") != null and kind != .command and kind != .agent)
        try diags.add(.warning, try childPath(arena, path, "target"), "'target' applies only to command and agent actions", .{});
    a.restart = (try parseEnumField(Restart, arena, v, "restart", path, diags)) orelse Restart.default;

    switch (kind) {
        .builtin => {
            const b = (try optString(arena, v, "builtin", path, diags)) orelse "";
            if (isBlank(b)) {
                try diags.add(.err, path, "builtin action needs a 'builtin' id", .{});
                return null;
            }
            const nb = normalizeId(b);
            if (findBuiltin(nb) == null and !proto.actions_catalog.isKnownId(nb))
                try diags.add(.warning, try childPath(arena, path, "builtin"), "unknown built-in action '{s}'", .{b});
            a.body = .{ .builtin = nb };
        },
        .command => {
            const c = (try optString(arena, v, "command", path, diags)) orelse "";
            if (isBlank(c)) {
                try diags.add(.err, path, "command action needs a non-blank 'command'", .{});
                return null;
            }
            a.body = .{ .command = .{ .command = c, .target = target } };
        },
        .agent => {
            const ag = (try optString(arena, v, "agent", path, diags)) orelse "";
            if (isBlank(ag)) {
                try diags.add(.err, path, "agent action needs a non-blank 'agent'", .{});
                return null;
            }
            a.body = .{ .agent = .{ .agent = ag, .args = try stringList(arena, v, "args", path, diags), .target = target } };
        },
        .workspaceCommand => {
            const name = (try optString(arena, v, "commandName", path, diags)) orelse
                (try optString(arena, v, "name", path, diags)) orelse
                (try optString(arena, v, "command", path, diags)) orelse "";
            if (isBlank(name)) {
                try diags.add(.err, path, "workspaceCommand action needs 'commandName' naming a commands entry", .{});
                return null;
            }
            a.body = .{ .workspaceCommand = name };
        },
        .workspace => {
            const w = v.get("workspace") orelse {
                try diags.add(.err, path, "workspace action needs a 'workspace' definition", .{});
                return null;
            };
            if (w.data != .object) {
                try diags.add(.err, try childPath(arena, path, "workspace"), "'workspace' must be an object", .{});
                return null;
            }
            if (ctx.validate_workspace) |validate| {
                if (try validate(arena, w)) |msg| {
                    try diags.add(.err, try childPath(arena, path, "workspace"), "{s}", .{msg});
                    return null;
                }
            }
            a.body = .{ .workspace = try w.clone(arena) };
        },
        .setting => {
            const p = (try optString(arena, v, "path", path, diags)) orelse "";
            if (isBlank(p)) {
                try diags.add(.err, path, "setting action needs a non-blank 'path'", .{});
                return null;
            }
            var ops: usize = 0;
            var op: SettingOp = .unset;
            if (v.get("set")) |s| {
                ops += 1;
                op = .{ .set = try s.clone(arena) };
            }
            if (v.get("toggle")) |t| {
                ops += 1;
                if (t.asBool() != true) try diags.add(.err, try childPath(arena, path, "toggle"), "'toggle' must be true", .{});
                op = .toggle;
            }
            if (v.get("cycle")) |c| {
                ops += 1;
                switch (c.data) {
                    .array => |items| if (items.len == 0) {
                        try diags.add(.err, try childPath(arena, path, "cycle"), "'cycle' needs at least one value", .{});
                    } else {
                        const cl = try c.clone(arena);
                        op = .{ .cycle = cl.data.array };
                    },
                    else => try diags.add(.err, try childPath(arena, path, "cycle"), "'cycle' must be an array of values", .{}),
                }
            }
            if (v.get("unset")) |u| {
                ops += 1;
                if (u.asBool() != true) try diags.add(.err, try childPath(arena, path, "unset"), "'unset' must be true", .{});
                op = .unset;
            }
            if (ops != 1) {
                try diags.add(.err, path, "setting action needs exactly one of set, toggle, cycle or unset", .{});
                return null;
            }
            a.body = .{ .setting = .{ .path = p, .op = op } };
        },
        .settingPreset => {
            const p = (try optString(arena, v, "preset", path, diags)) orelse "";
            if (isBlank(p)) {
                try diags.add(.err, path, "settingPreset action needs a non-blank 'preset'", .{});
                return null;
            }
            a.body = .{ .settingPreset = p };
        },
    }
    if ((kind == .setting or kind == .settingPreset) and ctx.source == .project) {
        try diags.add(.err, path, "setting and settingPreset actions run only from the global config and its packs", .{});
        return null;
    }
    if (diags.errorCount() != before) return null;
    return a;
}

fn parseCommands(arena: Allocator, node: *const jsonc.Node, ctx: FileContext, diags: *Diagnostics) Allocator.Error![]const Command {
    const items = switch (node.data) {
        .array => |a| a,
        .null => return &.{},
        else => {
            try diags.add(.err, "commands", "'commands' must be an array, not {s}", .{node.kindName()});
            return &.{};
        },
    };
    var out: std.ArrayList(Command) = .empty;
    for (items, 0..) |*it, i| {
        const path = try indexPath(arena, "commands", i);
        const cmd = (try parseCommand(arena, it, ctx, path, diags)) orelse continue;
        var replaced = false;
        for (out.items) |*o| {
            if (std.mem.eql(u8, o.name, cmd.name)) {
                try diags.add(.warning, path, "command '{s}' is defined more than once; the last definition wins", .{cmd.name});
                o.* = cmd;
                replaced = true;
            }
        }
        if (!replaced) try out.append(arena, cmd);
    }
    return out.toOwnedSlice(arena);
}

const command_keys = [_][]const u8{ "name", "description", "keywords", "command", "workspace", "confirm", "restart" };

fn parseCommand(arena: Allocator, v: *const jsonc.Node, ctx: FileContext, path: []const u8, diags: *Diagnostics) Allocator.Error!?Command {
    if (v.data != .object) {
        try diags.add(.err, path, "command entry must be an object, not {s}", .{v.kindName()});
        return null;
    }
    const before = diags.errorCount();
    for (v.data.object) |m| {
        var known = std.mem.startsWith(u8, m.key, "$");
        for (command_keys) |k| known = known or std.mem.eql(u8, k, m.key);
        if (!known) try diags.add(.warning, try childPath(arena, path, m.key), "unknown key '{s}' is ignored", .{m.key});
    }
    const name = (try optString(arena, v, "name", path, diags)) orelse "";
    if (isBlank(name)) {
        try diags.add(.err, try childPath(arena, path, "name"), "command name must not be blank", .{});
        return null;
    }
    var c: Command = .{
        .name = name,
        .source = ctx.source,
        .config_path = ctx.config_path,
        .project_root = ctx.project_root,
        .body = undefined,
    };
    c.description = try optString(arena, v, "description", path, diags);
    c.keywords = try stringList(arena, v, "keywords", path, diags);
    c.confirm = (try optBool(arena, v, "confirm", path, diags)) orelse false;
    c.restart = (try parseEnumField(Restart, arena, v, "restart", path, diags)) orelse Restart.default;
    const shell = try optString(arena, v, "command", path, diags);
    const ws = v.get("workspace");
    if ((shell != null) == (ws != null and ws.?.data != .null)) {
        try diags.add(.err, path, "a command entry needs exactly one of 'command' or 'workspace'", .{});
        return null;
    }
    if (shell) |s| {
        if (isBlank(s)) {
            try diags.add(.err, try childPath(arena, path, "command"), "'command' must not be blank", .{});
            return null;
        }
        c.body = .{ .shell = s };
    } else {
        const w = ws.?;
        if (w.data != .object) {
            try diags.add(.err, try childPath(arena, path, "workspace"), "'workspace' must be an object", .{});
            return null;
        }
        if (ctx.validate_workspace) |validate| {
            if (try validate(arena, w)) |msg| {
                try diags.add(.err, try childPath(arena, path, "workspace"), "{s}", .{msg});
                return null;
            }
        }
        c.body = .{ .workspace = try w.clone(arena) };
    }
    if (diags.errorCount() != before) return null;
    return c;
}

fn parseButtonEntry(arena: Allocator, v: *const jsonc.Node, path: []const u8, diags: *Diagnostics) Allocator.Error!?ButtonEntry {
    switch (v.data) {
        .string => |s| {
            if (isBlank(s)) {
                try diags.add(.err, path, "action id must not be blank", .{});
                return null;
            }
            return .{ .action = normalizeId(s) };
        },
        .object => {
            const id = (try optString(arena, v, "action", path, diags)) orelse "";
            if (isBlank(id)) {
                try diags.add(.err, path, "button object needs an 'action' id", .{});
                return null;
            }
            var b: ButtonEntry = .{ .action = normalizeId(id) };
            b.title = try optString(arena, v, "title", path, diags);
            b.tooltip = try optString(arena, v, "tooltip", path, diags);
            if (v.get("icon")) |ic| b.icon = try parseIcon(arena, ic, try childPath(arena, path, "icon"), diags);
            return b;
        },
        else => {
            try diags.add(.err, path, "entry must be an action id or an object, not {s}", .{v.kindName()});
            return null;
        },
    }
}

fn parseUi(arena: Allocator, root: *const jsonc.Node, ctx: FileContext, diags: *Diagnostics) Allocator.Error!Ui {
    var ui: Ui = .{};
    // Buttons: ui.surfaceTabBar.buttons, else legacy root surfaceTabBarButtons.
    var buttons_path: []const u8 = "ui.surfaceTabBar.buttons";
    var buttons = root.getPath(&.{ "ui", "surfaceTabBar", "buttons" });
    if (buttons == null) {
        buttons = root.get("surfaceTabBarButtons");
        buttons_path = "surfaceTabBarButtons";
    }
    if (buttons) |b| switch (b.data) {
        .null => {},
        .array => |items| {
            var out: std.ArrayList(ButtonEntry) = .empty;
            for (items, 0..) |*it, i| {
                if (try parseButtonEntry(arena, it, try indexPath(arena, buttons_path, i), diags)) |e| try out.append(arena, e);
            }
            ui.tab_bar_buttons = try out.toOwnedSlice(arena);
        },
        else => try diags.add(.err, buttons_path, "buttons must be an array", .{}),
    };

    if (root.getPath(&.{ "ui", "newWorkspace" })) |nw| {
        if (nw.data == .object) {
            if (try optString(arena, nw, "action", "ui.newWorkspace", diags)) |a| {
                if (!isBlank(a)) ui.new_workspace_action = normalizeId(a);
            }
            var menu_path: []const u8 = "ui.newWorkspace.contextMenu";
            var menu = nw.get("contextMenu");
            if (menu == null) {
                menu = nw.get("rightClick");
                menu_path = "ui.newWorkspace.rightClick";
            }
            if (menu) |m| switch (m.data) {
                .null => {},
                .array => |items| {
                    var out: std.ArrayList(MenuEntry) = .empty;
                    for (items, 0..) |*it, i| {
                        const p = try indexPath(arena, menu_path, i);
                        if (try parseMenuEntry(arena, it, ctx, p, diags)) |e| try out.append(arena, e);
                    }
                    ui.context_menu = try out.toOwnedSlice(arena);
                },
                else => try diags.add(.err, menu_path, "contextMenu must be an array", .{}),
            };
        } else if (nw.data != .null) {
            try diags.add(.err, "ui.newWorkspace", "'ui.newWorkspace' must be an object", .{});
        }
    }
    if (try optString(arena, root, "newWorkspaceCommand", "", diags)) |c| {
        if (!isBlank(c)) ui.new_workspace_command = c;
    }
    return ui;
}

fn parseMenuEntry(arena: Allocator, v: *const jsonc.Node, ctx: FileContext, path: []const u8, diags: *Diagnostics) Allocator.Error!?MenuEntry {
    if (v.data == .object) {
        if (v.get("type")) |t| {
            if (t.asString()) |ts| {
                if (std.mem.eql(u8, ts, "separator")) return .separator;
            }
        }
        if (v.get("action") == null) {
            // Inline action object; its id is `id` or the menu position.
            const id = (try optString(arena, v, "id", path, diags)) orelse path;
            const a = (try parseAction(arena, normalizeId(id), v, ctx, path, diags)) orelse return null;
            return .{ .inline_action = a };
        }
    }
    const b = (try parseButtonEntry(arena, v, path, diags)) orelse return null;
    return .{ .ref = b };
}

// ---------------------------------------------------------------------------
// Registry

pub const Registry = struct {
    /// Merged actions; a higher layer replaces a lower one with the same id
    /// in place, new ids are appended in declaration order.
    actions: []const Action,
    /// Merged commands; replaced by name the same way.
    commands: []const Command,
    /// Each ui key comes from the highest layer that sets it.
    ui: Ui,

    pub fn findAction(self: *const Registry, id: []const u8) ?*const Action {
        const nid = normalizeId(id);
        for (self.actions) |*a| {
            if (std.mem.eql(u8, a.id, nid)) return a;
        }
        return null;
    }

    pub fn findCommand(self: *const Registry, name: []const u8) ?*const Command {
        for (self.commands) |*c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }

    /// The command behind a generated `command:<name>` id.
    pub fn findCommandById(self: *const Registry, id: []const u8) ?*const Command {
        if (!std.mem.startsWith(u8, id, command_id_prefix)) return null;
        return self.findCommand(id[command_id_prefix.len..]);
    }

    /// Display title: the action's title, else the built-in label (an
    /// override keeps it), else the command name, else the id.
    pub fn titleOf(self: *const Registry, id: []const u8) []const u8 {
        const nid = normalizeId(id);
        if (self.findAction(nid)) |a| {
            if (a.title) |t| return t;
        }
        if (findBuiltin(nid)) |b| return b.title;
        if (self.findAction(nid) == null) {
            if (self.findCommandById(nid)) |c| return c.name;
        }
        return nid;
    }

    /// What an id runs, or null when nothing has that id.
    pub fn resolve(self: *const Registry, id: []const u8) ?Runnable {
        const nid = normalizeId(id);
        if (self.findAction(nid)) |a| return .{ .action = a };
        if (findBuiltin(nid)) |b| return .{ .builtin = b.id };
        if (self.findCommandById(nid)) |c| return .{ .command = c };
        if (proto.actions_catalog.isKnownId(nid)) return .{ .builtin = nid };
        return null;
    }
};

pub const Runnable = union(enum) {
    /// A built-in that no config overrides.
    builtin: []const u8,
    action: *const Action,
    command: *const Command,
};

/// Merges config layers given lowest precedence first (packs, global,
/// project).
pub fn buildRegistry(arena: Allocator, layers: []const *const Config) Allocator.Error!Registry {
    var actions: std.ArrayList(Action) = .empty;
    var commands: std.ArrayList(Command) = .empty;
    var ui: Ui = .{};
    for (layers) |cfg| {
        outer: for (cfg.actions) |a| {
            for (actions.items) |*o| {
                if (std.mem.eql(u8, o.id, a.id)) {
                    o.* = a;
                    continue :outer;
                }
            }
            try actions.append(arena, a);
        }
        outer: for (cfg.commands) |c| {
            for (commands.items) |*o| {
                if (std.mem.eql(u8, o.name, c.name)) {
                    o.* = c;
                    continue :outer;
                }
            }
            try commands.append(arena, c);
        }
        if (cfg.ui.tab_bar_buttons) |b| ui.tab_bar_buttons = b;
        if (cfg.ui.context_menu) |m| ui.context_menu = m;
        // ui.newWorkspace.action and the legacy key are one setting: the
        // higher layer's value (in either spelling) wins.
        if (cfg.ui.new_workspace_action != null or cfg.ui.new_workspace_command != null) {
            ui.new_workspace_action = cfg.ui.new_workspace_action;
            ui.new_workspace_command = cfg.ui.new_workspace_command;
        }
    }
    return .{
        .actions = try actions.toOwnedSlice(arena),
        .commands = try commands.toOwnedSlice(arena),
        .ui = ui,
    };
}

// ---------------------------------------------------------------------------
// Placements

pub const PaletteRow = struct {
    id: []const u8,
    title: []const u8,
    subtitle: ?[]const u8 = null,
    keywords: []const []const u8 = &.{},
    shortcut: ?strokes.Trigger = null,
    source: Source,
    origin: union(enum) { action: *const Action, command: *const Command },
};

/// Custom palette rows: actions with palette != false whose id is not a
/// built-in (built-ins keep their normal rows; an override only changes
/// what they run), then legacy commands not shadowed by an action with the
/// generated id.
pub fn paletteRows(arena: Allocator, reg: *const Registry) Allocator.Error![]const PaletteRow {
    var out: std.ArrayList(PaletteRow) = .empty;
    for (reg.actions) |*a| {
        if (!a.palette or findBuiltin(a.id) != null) continue;
        try out.append(arena, .{
            .id = a.id,
            .title = a.title orelse a.id,
            .subtitle = a.subtitle,
            .keywords = a.keywords,
            .shortcut = a.shortcut,
            .source = a.source,
            .origin = .{ .action = a },
        });
    }
    for (reg.commands) |*c| {
        const id = try commandActionIdAlloc(arena, c.name);
        if (reg.findAction(id) != null) continue;
        try out.append(arena, .{
            .id = id,
            .title = c.name,
            .subtitle = c.description,
            .keywords = c.keywords,
            .source = c.source,
            .origin = .{ .command = c },
        });
    }
    return out.toOwnedSlice(arena);
}

pub const Button = struct {
    id: []const u8,
    /// Resolved title; also the trust prompt title.
    title: []const u8,
    icon: ?Icon = null,
    tooltip: ?[]const u8 = null,
    /// Null for a built-in nobody overrides.
    action: ?*const Action = null,
};

/// The surface tab bar buttons: the configured list (exact order; a missing
/// built-in is hidden) or the default four. Entries naming nothing are
/// dropped with a warning in `diags`.
pub fn tabBarButtons(arena: Allocator, reg: *const Registry, diags: ?*Diagnostics) Allocator.Error![]const Button {
    var entries: []const ButtonEntry = undefined;
    if (reg.ui.tab_bar_buttons) |b| {
        entries = b;
    } else {
        const d = try arena.alloc(ButtonEntry, default_tab_bar_buttons.len);
        for (default_tab_bar_buttons, d) |id, *e| e.* = .{ .action = id };
        entries = d;
    }
    var out: std.ArrayList(Button) = .empty;
    for (entries) |e| {
        const run = reg.resolve(e.action) orelse {
            if (diags) |dg| try dg.add(.warning, "ui.surfaceTabBar.buttons", "unknown action '{s}'", .{e.action});
            continue;
        };
        const action: ?*const Action = switch (run) {
            .action => |a| a,
            else => null,
        };
        try out.append(arena, .{
            .id = normalizeId(e.action),
            .title = e.title orelse reg.titleOf(e.action),
            .icon = e.icon orelse if (action) |a| a.icon else null,
            .tooltip = e.tooltip orelse if (action) |a| a.tooltip else null,
            .action = action,
        });
    }
    return out.toOwnedSlice(arena);
}

pub const MenuItem = union(enum) {
    separator,
    item: struct {
        id: []const u8,
        title: []const u8,
        icon: ?Icon = null,
        tooltip: ?[]const u8 = null,
        /// The action's own shortcut; for built-ins the app shows the live
        /// keymap shortcut of `id`.
        shortcut: ?strokes.Trigger = null,
        action: ?*const Action = null,
    },
};

pub const MenuOptions = struct {
    /// Cloud rows appear only when Cloud Machines is enabled.
    cloud_enabled: bool = false,
};

fn isCloudId(id: []const u8) bool {
    const b = findBuiltin(id) orelse return false;
    return b.cloud;
}

fn menuHas(items: []const MenuItem, id: []const u8) bool {
    for (items) |it| switch (it) {
        .item => |i| if (std.mem.eql(u8, i.id, id)) return true,
        .separator => {},
    };
    return false;
}

/// The plus button's right-click menu: ui.newWorkspace.contextMenu in order
/// (or the default rows), then every action offered in the menu
/// (newWorkspaceMenu:true, or inline workspace actions unless false) that
/// is not already listed.
pub fn newWorkspaceMenu(arena: Allocator, reg: *const Registry, opts: MenuOptions) Allocator.Error![]const MenuItem {
    var out: std.ArrayList(MenuItem) = .empty;
    if (reg.ui.context_menu) |entries| {
        for (entries) |*e| switch (e.*) {
            .separator => try out.append(arena, .separator),
            .ref => |r| {
                const nid = normalizeId(r.action);
                if (!opts.cloud_enabled and isCloudId(nid)) continue;
                const run = reg.resolve(nid) orelse continue;
                const action: ?*const Action = switch (run) {
                    .action => |a| a,
                    else => null,
                };
                try out.append(arena, .{ .item = .{
                    .id = nid,
                    .title = r.title orelse reg.titleOf(nid),
                    .icon = r.icon orelse if (action) |a| a.icon else null,
                    .tooltip = r.tooltip orelse if (action) |a| a.tooltip else null,
                    .shortcut = if (action) |a| a.shortcut else null,
                    .action = action,
                } });
            },
            .inline_action => |*a| try out.append(arena, .{ .item = .{
                .id = a.id,
                .title = a.title orelse a.id,
                .icon = a.icon,
                .tooltip = a.tooltip,
                .shortcut = a.shortcut,
                .action = a,
            } }),
        };
    } else {
        for (default_context_menu) |id| {
            if (!opts.cloud_enabled and isCloudId(id)) continue;
            const action = reg.findAction(id);
            try out.append(arena, .{ .item = .{
                .id = id,
                .title = reg.titleOf(id),
                .icon = if (action) |a| a.icon else null,
                .tooltip = if (action) |a| a.tooltip else null,
                .shortcut = if (action) |a| a.shortcut else null,
                .action = action,
            } });
        }
    }
    for (reg.actions) |*a| {
        if (!a.inNewWorkspaceMenu() or menuHas(out.items, a.id)) continue;
        if (!opts.cloud_enabled and isCloudId(a.id)) continue;
        try out.append(arena, .{ .item = .{
            .id = a.id,
            .title = reg.titleOf(a.id),
            .icon = a.icon,
            .tooltip = a.tooltip,
            .shortcut = a.shortcut,
            .action = a,
        } });
    }
    // Trim leading, trailing and doubled separators left by filtering.
    var trimmed: std.ArrayList(MenuItem) = .empty;
    for (out.items) |it| {
        if (it == .separator and (trimmed.items.len == 0 or trimmed.items[trimmed.items.len - 1] == .separator)) continue;
        try trimmed.append(arena, it);
    }
    if (trimmed.items.len > 0 and trimmed.items[trimmed.items.len - 1] == .separator) trimmed.items.len -= 1;
    return trimmed.toOwnedSlice(arena);
}

/// The id a plain New Workspace runs: ui.newWorkspace.action, else the
/// legacy newWorkspaceCommand mapped to its generated id, else null (a
/// blank terminal workspace).
pub fn newWorkspaceActionId(arena: Allocator, reg: *const Registry) Allocator.Error!?[]const u8 {
    if (reg.ui.new_workspace_action) |a| return a;
    if (reg.ui.new_workspace_command) |c| return try commandActionIdAlloc(arena, c);
    return null;
}

pub const DefaultChoice = struct {
    /// Null = None (blank terminal; choosing it removes the key).
    id: ?[]const u8,
    title: []const u8,
    selected: bool,
};

/// Rows of the "Default for New Workspace" submenu: None, then workspace
/// actions, then workspace commands not shadowed by an action.
pub fn defaultWorkspaceChoices(arena: Allocator, reg: *const Registry) Allocator.Error![]const DefaultChoice {
    const current = try newWorkspaceActionId(arena, reg);
    var out: std.ArrayList(DefaultChoice) = .empty;
    try out.append(arena, .{ .id = null, .title = "None", .selected = current == null });
    for (reg.actions) |*a| {
        const is_layout = switch (a.body) {
            .workspace => true,
            .workspaceCommand => |name| if (reg.findCommand(name)) |c| c.body == .workspace else false,
            else => false,
        };
        if (!is_layout) continue;
        try out.append(arena, .{
            .id = a.id,
            .title = a.title orelse a.id,
            .selected = current != null and std.mem.eql(u8, current.?, a.id),
        });
    }
    for (reg.commands) |*c| {
        if (c.body != .workspace) continue;
        const id = try commandActionIdAlloc(arena, c.name);
        if (reg.findAction(id) != null) continue;
        try out.append(arena, .{
            .id = id,
            .title = c.name,
            .selected = current != null and std.mem.eql(u8, current.?, id),
        });
    }
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Variable substitution

pub const Var = struct {
    name: []const u8,
    value: []const u8,
};

/// Variables for `substitute`. Names the caller does not supply are left
/// untouched, so shell syntax such as `${HOME}` keeps working.
pub const Vars = struct {
    /// e.g. cwd, projectRoot, workspaceName, workspaceId, surfaceId, configDir.
    vars: []const Var = &.{},
    /// Values for `${env:NAME}`.
    env: []const Var = &.{},
    /// Windows env names are case-insensitive.
    env_ignore_case: bool = false,

    fn lookup(self: Vars, name: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, name, "env:")) {
            const n = name["env:".len..];
            for (self.env) |e| {
                const eq = if (self.env_ignore_case) std.ascii.eqlIgnoreCase(e.name, n) else std.mem.eql(u8, e.name, n);
                if (eq) return e.value;
            }
            return null;
        }
        for (self.vars) |v| {
            if (std.mem.eql(u8, v.name, name)) return v.value;
        }
        return null;
    }
};

/// Replaces `${name}` and `${env:NAME}` with known values; `$${` yields a
/// literal `${`. Unknown names and an unterminated `${` stay verbatim.
pub fn substitute(gpa: Allocator, text: []const u8, vars: Vars) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '$' and i + 2 < text.len and text[i + 1] == '$' and text[i + 2] == '{') {
            try out.appendSlice(gpa, "${");
            i += 3;
            continue;
        }
        if (text[i] == '$' and i + 1 < text.len and text[i + 1] == '{') {
            if (std.mem.indexOfScalarPos(u8, text, i + 2, '}')) |close| {
                const name = text[i + 2 .. close];
                if (vars.lookup(name)) |val| {
                    try out.appendSlice(gpa, val);
                    i = close + 1;
                    continue;
                }
            }
        }
        try out.append(gpa, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Run plans

pub const RunPlan = union(enum) {
    /// Invoke a built-in by id.
    builtin: []const u8,
    /// Type `text` plus Enter, in the focused terminal or a new tab.
    send_text: struct { text: []const u8, target: Target },
    /// Build a workspace from this definition (layouts feature).
    workspace: struct { definition: jsonc.Node, restart: Restart, fallback_name: []const u8 },
    setting: struct { path: []const u8, op: SettingOp },
    preset: []const u8,
};

pub const Plan = struct {
    id: []const u8,
    title: []const u8,
    /// Ask before running.
    confirm: bool,
    source: Source,
    run: RunPlan,
};

pub const PlanError = error{ OutOfMemory, UnknownAction, UnknownCommand, Unrepresentable };

pub const PlanOptions = struct {
    vars: Vars = .{},
    /// Quoting family for agent command lines.
    shell: shell_quote.Shell = .posix,
};

/// What running `id` does. Command text, agent args and the agent name go
/// through `substitute`.
pub fn plan(arena: Allocator, reg: *const Registry, id: []const u8, opts: PlanOptions) PlanError!Plan {
    const run = reg.resolve(id) orelse return error.UnknownAction;
    return switch (run) {
        .builtin => |b| .{ .id = b, .title = reg.titleOf(b), .confirm = false, .source = .builtin, .run = .{ .builtin = b } },
        .action => |a| planAction(arena, reg, a, opts),
        .command => |c| planCommand(arena, c, opts),
    };
}

pub fn planAction(arena: Allocator, reg: *const Registry, a: *const Action, opts: PlanOptions) PlanError!Plan {
    const run: RunPlan = switch (a.body) {
        .builtin => |b| .{ .builtin = b },
        .command => |c| .{ .send_text = .{ .text = try substitute(arena, c.command, opts.vars), .target = c.target } },
        .agent => |ag| blk: {
            const argv = try arena.alloc([]const u8, ag.args.len + 1);
            argv[0] = try substitute(arena, ag.agent, opts.vars);
            for (ag.args, argv[1..]) |s, *o| o.* = try substitute(arena, s, opts.vars);
            const text = shell_quote.commandAlloc(arena, opts.shell, argv) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Unrepresentable => return error.Unrepresentable,
            };
            break :blk .{ .send_text = .{ .text = text, .target = ag.target } };
        },
        .workspaceCommand => |name| blk: {
            const c = reg.findCommand(name) orelse return error.UnknownCommand;
            break :blk switch (c.body) {
                .workspace => |w| .{ .workspace = .{ .definition = w, .restart = if (a.restart != .new) a.restart else c.restart, .fallback_name = c.name } },
                .shell => |s| .{ .send_text = .{ .text = try substitute(arena, s, opts.vars), .target = .currentTerminal } },
            };
        },
        .workspace => |w| .{ .workspace = .{ .definition = w, .restart = a.restart, .fallback_name = a.title orelse a.id } },
        .setting => |s| .{ .setting = .{ .path = s.path, .op = s.op } },
        .settingPreset => |p| .{ .preset = p },
    };
    return .{ .id = a.id, .title = reg.titleOf(a.id), .confirm = a.confirm, .source = a.source, .run = run };
}

/// A legacy command: shell text is typed into the focused terminal; a
/// workspace entry builds a workspace named after the command by default.
pub fn planCommand(arena: Allocator, c: *const Command, opts: PlanOptions) PlanError!Plan {
    return .{
        .id = try commandActionIdAlloc(arena, c.name),
        .title = c.name,
        .confirm = c.confirm,
        .source = c.source,
        .run = switch (c.body) {
            .shell => |s| .{ .send_text = .{ .text = try substitute(arena, s, opts.vars), .target = .currentTerminal } },
            .workspace => |w| .{ .workspace = .{ .definition = w, .restart = c.restart, .fallback_name = c.name } },
        },
    };
}

const ConfigCommandError = error{ OutOfMemory, Unrepresentable, WriteFailed };

fn writeConfigValue(gpa: Allocator, w: *std.Io.Writer, v: *const jsonc.Node) ConfigCommandError!void {
    switch (v.data) {
        .string => |s| try shell_quote.writePosix(w, s),
        else => {
            const json = try v.toJsonAlloc(gpa);
            defer gpa.free(json);
            try shell_quote.writePosix(w, json);
        },
    }
}

fn writeConfigCommand(gpa: Allocator, w: *std.Io.Writer, run: RunPlan) ConfigCommandError!bool {
    switch (run) {
        .setting => |s| switch (s.op) {
            .set => |*v| {
                try w.print("cmux config set {s} ", .{s.path});
                try writeConfigValue(gpa, w, v);
            },
            .toggle => try w.print("cmux config toggle {s}", .{s.path}),
            .cycle => |items| {
                try w.print("cmux config cycle {s}", .{s.path});
                for (items) |*it| {
                    try w.writeByte(' ');
                    try writeConfigValue(gpa, w, it);
                }
            },
            .unset => try w.print("cmux config unset {s}", .{s.path}),
        },
        .preset => |p| {
            try w.writeAll("cmux config preset ");
            try shell_quote.writePosix(w, p);
        },
        else => return false,
    }
    return true;
}

/// The equivalent `cmux config` command shown by confirm:true setting
/// actions ("cmux config set terminal.scrollSpeed 1.4"); null for other
/// plans.
pub fn configCommandAlloc(gpa: Allocator, run: RunPlan) error{ OutOfMemory, Unrepresentable }!?[]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const wrote = writeConfigCommand(gpa, &aw.writer, run) catch |e| switch (e) {
        error.Unrepresentable => return error.Unrepresentable,
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    if (!wrote) return null;
    return try aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const T = struct {
    ar: std.heap.ArenaAllocator,

    fn init() T {
        return .{ .ar = .init(testing.allocator) };
    }

    fn deinit(self: *T) void {
        self.ar.deinit();
    }

    fn a(self: *T) Allocator {
        return self.ar.allocator();
    }

    fn config(self: *T, src: []const u8, source: Source) !Config {
        var d: Diagnostics = .init(self.a());
        const cfg = try parseConfigText(self.a(), src, .{ .source = source, .config_path = "/p/.cmux/cmux.json", .project_root = "/p" }, &d);
        for (d.items.items) |it| {
            if (it.severity == .err) {
                std.log.err("{s}: {s}", .{ it.path, it.message });
                return error.TestUnexpectedDiagnostic;
            }
        }
        return cfg;
    }

    fn registry(self: *T, global: []const u8, project: ?[]const u8) !Registry {
        const g = try self.a().create(Config);
        g.* = try self.config(global, .global);
        if (project) |p| {
            const pc = try self.a().create(Config);
            pc.* = try self.config(p, .project);
            return buildRegistry(self.a(), &.{ g, pc });
        }
        return buildRegistry(self.a(), &.{g});
    }

    /// Parses and returns the error messages.
    fn errors(self: *T, src: []const u8, source: Source) ![]const Issue {
        var d: Diagnostics = .init(self.a());
        _ = try parseConfigText(self.a(), src, .{ .source = source }, &d);
        var out: std.ArrayList(Issue) = .empty;
        for (d.items.items) |it| {
            if (it.severity == .err) try out.append(self.a(), it);
        }
        return out.items;
    }

    fn expectError(self: *T, src: []const u8, source: Source, needle: []const u8) !void {
        const errs = try self.errors(src, source);
        for (errs) |e| {
            if (std.mem.indexOf(u8, e.message, needle) != null) return;
        }
        std.log.err("expected an error containing '{s}' for {s}", .{ needle, src });
        return error.TestExpectedError;
    }
};

test "unit: custom_actions: a command action with a shortcut is a palette row that runs in a new tab" {
    var t = T.init();
    defer t.deinit();
    const reg = try t.registry(
        \\{ // JSONC
        \\  "actions": { "npm-test": { "type": "command", "command": "npm test", "shortcut": "cmd+shift+t", "title": "Run Tests", "keywords": ["jest"], }, },
        \\}
    , null);
    const rows = try paletteRows(t.a(), &reg);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("Run Tests", rows[0].title);
    try testing.expectEqualStrings("jest", rows[0].keywords[0]);
    const sc = rows[0].shortcut.?;
    try testing.expect(sc.first.mods.cmd and sc.first.mods.shift and sc.second == null);
    const p = try plan(t.a(), &reg, "npm-test", .{});
    try testing.expectEqualStrings("npm test", p.run.send_text.text);
    try testing.expectEqual(Target.newTabInCurrentPane, p.run.send_text.target);
    try testing.expect(!p.confirm);
}

test "unit: custom_actions: palette false hides the row but the tab bar button still resolves" {
    var t = T.init();
    defer t.deinit();
    const reg = try t.registry(
        \\{"actions": {"my-codex": {"agent": "codex", "palette": false, "title": "Codex",
        \\   "icon": {"type": "emoji", "value": "🧪"}}},
        \\ "ui": {"surfaceTabBar": {"buttons": ["cmux.newTerminal", "my-codex"]}}}
    , null);
    try testing.expectEqual(@as(usize, 0), (try paletteRows(t.a(), &reg)).len);
    const buttons = try tabBarButtons(t.a(), &reg, null);
    try testing.expectEqual(@as(usize, 2), buttons.len);
    try testing.expectEqualStrings("cmux.newTerminal", buttons[0].id);
    try testing.expectEqualStrings("New Terminal", buttons[0].title);
    try testing.expect(buttons[0].action == null);
    try testing.expectEqualStrings("my-codex", buttons[1].id);
    try testing.expectEqualStrings("Codex", buttons[1].title);
    try testing.expectEqual(@as(f64, 1), buttons[1].icon.?.emoji.scale);
    const p = try plan(t.a(), &reg, buttons[1].id, .{});
    try testing.expectEqualStrings("codex", p.run.send_text.text);
}

test "unit: custom_actions: overriding cmux.newTerminal with an agent keeps its label and changes what runs" {
    var t = T.init();
    defer t.deinit();
    const reg = try t.registry(
        \\{"actions": {"wmux.newTerminal": {"type": "agent", "agent": "claude", "args": ["--model", "opus 5"], "target": "currentTerminal"}}}
    , null);
    try testing.expectEqualStrings("cmux.newTerminal", reg.actions[0].id);
    try testing.expectEqual(@as(usize, 0), (try paletteRows(t.a(), &reg)).len);
    try testing.expectEqualStrings("New Terminal", reg.titleOf("cmux.newTerminal"));
    try testing.expectEqualStrings("New Terminal", reg.titleOf("wmux.newTerminal"));
    const p = try plan(t.a(), &reg, "cmux.newTerminal", .{});
    try testing.expectEqualStrings("claude --model 'opus 5'", p.run.send_text.text);
    try testing.expectEqual(Target.currentTerminal, p.run.send_text.target);
    const pw = try plan(t.a(), &reg, "wmux.newTerminal", .{ .shell = .pwsh });
    try testing.expectEqualStrings("& 'claude' '--model' 'opus 5'", pw.run.send_text.text);
    const buttons = try tabBarButtons(t.a(), &reg, null);
    try testing.expectEqual(@as(usize, 4), buttons.len);
    try testing.expect(buttons[0].action != null);
    try testing.expectEqualStrings("New Terminal", buttons[0].title);
}

test "unit: custom_actions: setting actions are rejected in project files" {
    var t = T.init();
    defer t.deinit();
    const src =
        \\{"actions": {"wrap": {"type": "setting", "path": "fileEditor.wordWrap", "toggle": true},
        \\             "quiet": {"preset": "sidebar.quiet"}}}
    ;
    const errs = try t.errors(src, .project);
    try testing.expectEqual(@as(usize, 2), errs.len);
    try testing.expect(std.mem.indexOf(u8, errs[0].message, "only from the global config") != null);
    const g = try t.config(src, .global);
    try testing.expectEqual(@as(usize, 2), g.actions.len);
    try testing.expect(g.actions[0].body.setting.op == .toggle);
    try testing.expectEqualStrings("sidebar.quiet", g.actions[1].body.settingPreset);
}

test "unit: custom_actions: setting actions need exactly one operation" {
    var t = T.init();
    defer t.deinit();
    try t.expectError("{\"actions\":{\"s\":{\"path\":\"a.b\"}}}", .global, "exactly one of");
    try t.expectError("{\"actions\":{\"s\":{\"path\":\"a.b\",\"set\":1,\"unset\":true}}}", .global, "exactly one of");
    try t.expectError("{\"actions\":{\"s\":{\"path\":\"a.b\",\"toggle\":false}}}", .global, "'toggle' must be true");
    try t.expectError("{\"actions\":{\"s\":{\"path\":\"a.b\",\"cycle\":[]}}}", .global, "at least one value");
    try t.expectError("{\"actions\":{\"s\":{\"type\":\"setting\",\"set\":1}}}", .global, "non-blank 'path'");
    const g = try t.config("{\"actions\":{\"s\":{\"path\":\"terminal.scrollSpeed\",\"set\":1.4},\"c\":{\"path\":\"ui.theme\",\"cycle\":[\"light\",\"dark mode\"]},\"u\":{\"path\":\"x.y\",\"unset\":true}}}", .global);
    const reg = try buildRegistry(t.a(), &.{&g});
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "s", "cmux config set terminal.scrollSpeed 1.4" },
        .{ "c", "cmux config cycle ui.theme light 'dark mode'" },
        .{ "u", "cmux config unset x.y" },
    };
    for (cases) |c| {
        const p = try plan(t.a(), &reg, c[0], .{});
        const text = (try configCommandAlloc(testing.allocator, p.run)).?;
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(c[1], text);
    }
    try testing.expect((try configCommandAlloc(testing.allocator, .{ .builtin = "cmux.newTerminal" })) == null);
    const pre = (try configCommandAlloc(testing.allocator, .{ .preset = "sidebar.quiet" })).?;
    defer testing.allocator.free(pre);
    try testing.expectEqualStrings("cmux config preset sidebar.quiet", pre);
}

test "unit: custom_actions: action types are inferred from fields" {
    var t = T.init();
    defer t.deinit();
    const cfg = try t.config(
        \\{"actions": {
        \\  "b": {"builtin": "wmux.splitRight"}, "c": {"command": "ls"}, "a": {"agent": "opencode"},
        \\  "wc": {"commandName": "Dev"}, "w": {"workspace": {"name": "x"}}, "s": {"path": "a.b", "unset": true},
        \\  "p": {"preset": "q"}, "named": {"type": "workspaceCommand", "name": "Dev"}
        \\}}
    , .global);
    const want = [_]Kind{ .builtin, .command, .agent, .workspaceCommand, .workspace, .setting, .settingPreset, .workspaceCommand };
    for (cfg.actions, want) |act, k| try testing.expectEqual(k, act.kind());
    try testing.expectEqualStrings("cmux.splitRight", cfg.actions[0].body.builtin);
    try testing.expectEqualStrings("Dev", cfg.actions[7].body.workspaceCommand);
}

test "unit: custom_actions: malformed actions are reported and skipped" {
    var t = T.init();
    defer t.deinit();
    try t.expectError("{\"actions\":{\"x\":{\"builtin\":\"cmux.newTerminal\",\"command\":\"ls\"}}}", .global, "set 'type'");
    try t.expectError("{\"actions\":{\"x\":{\"title\":\"nothing\"}}}", .global, "no runnable field");
    try t.expectError("{\"actions\":{\"x\":{\"type\":\"macro\"}}}", .global, "unknown action type");
    try t.expectError("{\"actions\":{\"x\":{\"type\":\"command\",\"command\":\"  \"}}}", .global, "non-blank 'command'");
    try t.expectError("{\"actions\":{\"x\":{\"command\":\"ls\",\"target\":\"newWindow\"}}}", .global, "unknown target");
    try t.expectError("{\"actions\":{\"x\":{\"command\":\"ls\",\"palette\":\"no\"}}}", .global, "true or false");
    try t.expectError("{\"actions\":{\"x\":{\"agent\":\"c\",\"args\":[1]}}}", .global, "must be strings");
    try t.expectError("{\"actions\":{\"x\":{\"workspace\":[]}}}", .global, "must be an object");
    try t.expectError("{\"actions\":{\"x\":3}}", .global, "must be an object");
    try t.expectError("{\"actions\":{\"  \":{\"command\":\"ls\"}}}", .global, "must not be blank");
    try t.expectError("{\"actions\":[]}", .global, "mapping ids");
    try t.expectError("[]", .global, "root must be an object");
    try t.expectError("{\"actions\":", .global, "1:");
    // Valid siblings survive.
    var d: Diagnostics = .init(t.a());
    const cfg = try parseConfigText(t.a(), "{\"actions\":{\"bad\":{},\"good\":{\"command\":\"ls\"}}}", .{ .source = .global }, &d);
    try testing.expectEqual(@as(usize, 1), cfg.actions.len);
    try testing.expectEqualStrings("good", cfg.actions[0].id);
    try testing.expect(d.hasErrors());
}

test "unit: custom_actions: parseConfigText does not borrow the caller's buffer" {
    var t = T.init();
    defer t.deinit();
    const buf = try testing.allocator.dupe(u8,
        \\{"actions": {"t": {"command": "npm test", "title": "Test", "keywords": ["jest"]}},
        \\ "commands": [{"name": "Lint", "command": "npm run lint"}],
        \\ "ui": {"surfaceTabBar": {"buttons": ["t"]}, "newWorkspace": {"action": "t"}}}
    );
    defer testing.allocator.free(buf);
    var d: Diagnostics = .init(t.a());
    const cfg = try parseConfigText(t.a(), buf, .{ .source = .global }, &d);
    // The settings loader frees (or reuses) its file buffer after parsing.
    @memset(buf, 'X');
    try testing.expectEqualStrings("t", cfg.actions[0].id);
    try testing.expectEqualStrings("Test", cfg.actions[0].title.?);
    try testing.expectEqualStrings("jest", cfg.actions[0].keywords[0]);
    try testing.expectEqualStrings("npm test", cfg.actions[0].body.command.command);
    try testing.expectEqualStrings("Lint", cfg.commands[0].name);
    try testing.expectEqualStrings("npm run lint", cfg.commands[0].body.shell);
    try testing.expectEqualStrings("t", cfg.ui.tab_bar_buttons.?[0].action);
    try testing.expectEqualStrings("t", cfg.ui.new_workspace_action.?);
}

test "unit: custom_actions: unknown keys and unknown builtins only warn" {
    var t = T.init();
    defer t.deinit();
    var d: Diagnostics = .init(t.a());
    const cfg = try parseConfigText(t.a(), "{\"actions\":{\"x\":{\"builtin\":\"cmux.teleport\",\"colour\":1,\"target\":\"currentTerminal\"}}}", .{ .source = .global }, &d);
    try testing.expectEqual(@as(usize, 1), cfg.actions.len);
    try testing.expectEqual(@as(usize, 0), d.errorCount());
    try testing.expectEqual(@as(usize, 3), d.items.items.len);
}

test "unit: custom_actions: shortcuts accept single strokes and chords" {
    var t = T.init();
    defer t.deinit();
    const cfg = try t.config(
        \\{"actions": {"a": {"command": "x", "shortcut": ["cmd+k", "cmd+c"]},
        \\             "b": {"command": "x", "shortcut": "cmd+k c"},
        \\             "c": {"command": "x", "shortcut": ["⌘⇧T"]}}}
    , .global);
    try testing.expect(cfg.actions[0].shortcut.?.isChord());
    try testing.expect(cfg.actions[1].shortcut.?.isChord());
    try testing.expect(!cfg.actions[2].shortcut.?.isChord());
    try t.expectError("{\"actions\":{\"a\":{\"command\":\"x\",\"shortcut\":\"cmd+\"}}}", .global, "invalid shortcut");
    try t.expectError("{\"actions\":{\"a\":{\"command\":\"x\",\"shortcut\":[\"a\",\"b\",\"c\"]}}}", .global, "two-stroke chord");
    try t.expectError("{\"actions\":{\"a\":{\"command\":\"x\",\"shortcut\":5}}}", .global, "string or an array");
    var d: Diagnostics = .init(t.a());
    _ = try parseConfigText(t.a(), "{\"actions\":{\"a\":{\"command\":\"x\",\"shortcut\":\"cmd+t\"}}}", .{ .source = .global, .dialect = .windows }, &d);
    try testing.expect(std.mem.indexOf(u8, d.items.items[0].message, "macOS modifier") != null);
}

test "unit: custom_actions: icons validate type, emoji scale and image extensions" {
    var t = T.init();
    defer t.deinit();
    const cfg = try t.config(
        \\{"actions": {"a": {"command": "x", "icon": {"type": "symbol", "name": "play.circle"}},
        \\             "b": {"command": "x", "icon": {"type": "emoji", "value": "🧪", "scale": 0.9}},
        \\             "c": {"command": "x", "icon": {"type": "image", "path": "./icons/Codex.SVG"}}}}
    , .global);
    try testing.expectEqualStrings("play.circle", cfg.actions[0].icon.?.symbol);
    try testing.expectEqual(@as(f64, 0.9), cfg.actions[1].icon.?.emoji.scale);
    try testing.expectEqualStrings("./icons/Codex.SVG", cfg.actions[2].icon.?.image);
    try t.expectError("{\"actions\":{\"a\":{\"command\":\"x\",\"icon\":\"play\"}}}", .global, "icon must be an object");
    try t.expectError("{\"actions\":{\"a\":{\"command\":\"x\",\"icon\":{\"type\":\"gif\"}}}}", .global, "unknown icon type");
    try t.expectError("{\"actions\":{\"a\":{\"command\":\"x\",\"icon\":{\"type\":\"emoji\",\"value\":\"x\",\"scale\":0}}}}", .global, "emoji scale");
    try t.expectError("{\"actions\":{\"a\":{\"command\":\"x\",\"icon\":{\"type\":\"image\",\"path\":\"i.exe\"}}}}", .global, "unsupported image type");
    try t.expectError("{\"actions\":{\"a\":{\"command\":\"x\",\"icon\":{\"type\":\"symbol\"}}}}", .global, "non-blank 'name'");
    for ([_][]const u8{ "a.png", "b.jpeg", "c.jpg", "d.ico", "e.icns", "dir.v2/f.webp", "C:\\x\\g.AVIF" }) |p| try testing.expect(isSupportedImage(p));
    for ([_][]const u8{ "png", ".png", "a.", "a.exe", "dir.png/file" }) |p| try testing.expect(!isSupportedImage(p));
}

test "unit: custom_actions: commands need a non-blank name and exactly one of command or workspace" {
    var t = T.init();
    defer t.deinit();
    try t.expectError("{\"commands\":[{\"name\":\"  \",\"command\":\"ls\"}]}", .global, "must not be blank");
    try t.expectError("{\"commands\":[{\"command\":\"ls\"}]}", .global, "must not be blank");
    try t.expectError("{\"commands\":[{\"name\":\"x\"}]}", .global, "exactly one of");
    try t.expectError("{\"commands\":[{\"name\":\"x\",\"command\":\"ls\",\"workspace\":{}}]}", .global, "exactly one of");
    try t.expectError("{\"commands\":[{\"name\":\"x\",\"workspace\":\"dev\"}]}", .global, "must be an object");
    try t.expectError("{\"commands\":[{\"name\":\"x\",\"command\":\"ls\",\"restart\":\"maybe\"}]}", .global, "unknown restart");
    try t.expectError("{\"commands\":{}}", .global, "must be an array");
    try t.expectError("{\"commands\":[1]}", .global, "must be an object");
}

test "unit: custom_actions: legacy commands become palette rows; local overrides global; actions shadow them" {
    var t = T.init();
    defer t.deinit();
    const reg = try t.registry(
        \\{"commands": [{"name": "Test", "command": "npm test", "description": "global"},
        \\              {"name": "Lint", "command": "npm run lint", "keywords": ["eslint"]}]}
    ,
        \\{"commands": [{"name": "Test", "command": "pnpm test", "confirm": true}],
        \\ "actions": {"command:Lint": {"command": "eslint .", "title": "Lint (action)"}}}
    );
    const rows = try paletteRows(t.a(), &reg);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("Lint (action)", rows[0].title);
    try testing.expectEqualStrings("command:Test", rows[1].id);
    try testing.expectEqual(Source.project, rows[1].source);
    const p = try plan(t.a(), &reg, "command:Test", .{});
    try testing.expectEqualStrings("pnpm test", p.run.send_text.text);
    try testing.expectEqual(Target.currentTerminal, p.run.send_text.target);
    try testing.expect(p.confirm);
    try testing.expectEqualStrings("Test", p.title);
}

test "unit: custom_actions: workspace commands and workspace actions plan a workspace build" {
    var t = T.init();
    defer t.deinit();
    const reg = try t.registry(
        \\{"commands": [{"name": "Dev", "restart": "ignore", "workspace": {"layout": {"surfaces": [{"command": "npm run dev"}]}}},
        \\              {"name": "Shell", "command": "echo ${cwd}"}],
        \\ "actions": {"dev": {"commandName": "Dev"}, "dev2": {"commandName": "Dev", "restart": "recreate"},
        \\             "sh": {"commandName": "Shell"}, "missing": {"commandName": "Nope"},
        \\             "inline": {"title": "API", "workspace": {"name": "api"}, "restart": "confirm"}}}
    , null);
    const p = try plan(t.a(), &reg, "dev", .{});
    try testing.expectEqualStrings("Dev", p.run.workspace.fallback_name);
    try testing.expectEqual(Restart.ignore, p.run.workspace.restart);
    try testing.expect(p.run.workspace.definition.get("layout") != null);
    try testing.expectEqual(Restart.recreate, (try plan(t.a(), &reg, "dev2", .{})).run.workspace.restart);
    const sh = try plan(t.a(), &reg, "sh", .{ .vars = .{ .vars = &.{.{ .name = "cwd", .value = "/w" }} } });
    try testing.expectEqualStrings("echo /w", sh.run.send_text.text);
    try testing.expectError(error.UnknownCommand, plan(t.a(), &reg, "missing", .{}));
    try testing.expectError(error.UnknownAction, plan(t.a(), &reg, "nope", .{}));
    const inl = try plan(t.a(), &reg, "inline", .{});
    try testing.expectEqual(Restart.confirm, inl.run.workspace.restart);
    try testing.expectEqualStrings("API", inl.run.workspace.fallback_name);
    const b = try plan(t.a(), &reg, "cmux.splitDown", .{});
    try testing.expectEqualStrings("cmux.splitDown", b.run.builtin);
    try testing.expectEqualStrings("Split Down", b.title);
}

test "unit: custom_actions: workspace validator hook rejects bad definitions" {
    var t = T.init();
    defer t.deinit();
    const V = struct {
        fn validate(_: Allocator, node: *const jsonc.Node) Allocator.Error!?[]const u8 {
            return if (node.get("layout") == null) "layout is required" else null;
        }
    };
    var d: Diagnostics = .init(t.a());
    const cfg = try parseConfigText(t.a(),
        \\{"actions": {"w": {"workspace": {"name": "x"}}}, "commands": [{"name": "c", "workspace": {"layout": {}}}]}
    , .{ .source = .global, .validate_workspace = &V.validate }, &d);
    try testing.expectEqual(@as(usize, 0), cfg.actions.len);
    try testing.expectEqual(@as(usize, 1), cfg.commands.len);
    try testing.expectEqualStrings("actions.w.workspace", d.items.items[0].path);
    try testing.expectEqualStrings("layout is required", d.items.items[0].message);
}

test "unit: custom_actions: tab bar buttons accept objects, the legacy key, and drop unknown ids" {
    var t = T.init();
    defer t.deinit();
    const reg = try t.registry(
        \\{"actions": {"t": {"command": "npm test", "title": "Test", "tooltip": "Run tests"}},
        \\ "surfaceTabBarButtons": [{"action": "t", "title": "🧪", "icon": {"type": "symbol", "name": "flask"}}, "nope", "wmux.splitDown"]}
    , null);
    var d: Diagnostics = .init(t.a());
    const b = try tabBarButtons(t.a(), &reg, &d);
    try testing.expectEqual(@as(usize, 2), b.len);
    try testing.expectEqualStrings("🧪", b[0].title);
    try testing.expectEqualStrings("flask", b[0].icon.?.symbol);
    try testing.expectEqualStrings("Run tests", b[0].tooltip.?);
    try testing.expectEqualStrings("cmux.splitDown", b[1].id);
    try testing.expectEqual(@as(usize, 1), d.items.items.len);
    // An empty list hides every button.
    const none = try t.registry("{\"ui\":{\"surfaceTabBar\":{\"buttons\":[]}}}", null);
    try testing.expectEqual(@as(usize, 0), (try tabBarButtons(t.a(), &none, null)).len);
    // The project list replaces the global one.
    const both = try t.registry("{\"ui\":{\"surfaceTabBar\":{\"buttons\":[\"cmux.newBrowser\"]}}}", "{\"ui\":{\"surfaceTabBar\":{\"buttons\":[\"cmux.splitRight\",\"cmux.splitDown\"]}}}");
    const bb = try tabBarButtons(t.a(), &both, null);
    try testing.expectEqual(@as(usize, 2), bb.len);
    try testing.expectEqualStrings("Split Right", bb[0].title);
}

test "unit: custom_actions: default plus-button menu hides cloud rows unless enabled and appends layouts" {
    var t = T.init();
    defer t.deinit();
    const reg = try t.registry(
        \\{"actions": {"layout": {"title": "Fullstack", "workspace": {"name": "fs"}},
        \\             "hidden": {"workspace": {}, "newWorkspaceMenu": false},
        \\             "agent": {"agent": "claude", "newWorkspaceMenu": true, "shortcut": "cmd+opt+c"},
        \\             "plain": {"command": "ls"}}}
    , null);
    const m = try newWorkspaceMenu(t.a(), &reg, .{});
    const want = [_][]const u8{ "cmux.newWorkspace", "cmux.newTerminal", "cmux.newBrowser", "layout", "agent" };
    try testing.expectEqual(want.len, m.len);
    for (m, want) |it, id| try testing.expectEqualStrings(id, it.item.id);
    try testing.expectEqualStrings("New Workspace", m[0].item.title);
    try testing.expectEqualStrings("Fullstack", m[3].item.title);
    try testing.expect(m[4].item.shortcut != null);
    const mc = try newWorkspaceMenu(t.a(), &reg, .{ .cloud_enabled = true });
    try testing.expectEqualStrings("cmux.newCloudWorkspace", mc[1].item.id);
    try testing.expectEqualStrings("cmux.newCloudMachine", mc[2].item.id);
}

test "unit: custom_actions: a configured context menu keeps its order, separators and inline actions" {
    var t = T.init();
    defer t.deinit();
    const reg = try t.registry(
        \\{"actions": {"wt": {"title": "Codex Worktree", "workspace": {"name": "wt"}}},
        \\ "ui": {"newWorkspace": {"rightClick": [
        \\   {"type": "separator"}, "wt", {"type": "separator"}, {"type": "separator"},
        \\   "cmux.newCloudMachine", {"action": "cmux.newBrowser", "title": "Web"},
        \\   {"id": "inline-ls", "command": "ls", "title": "List"}, "missing", {"type": "separator"}]}}}
    , null);
    const m = try newWorkspaceMenu(t.a(), &reg, .{});
    // Leading/doubled/trailing separators trimmed, cloud row and unknown id
    // dropped, "wt" not appended twice.
    try testing.expectEqual(@as(usize, 4), m.len);
    try testing.expectEqualStrings("wt", m[0].item.id);
    try testing.expect(m[1] == .separator);
    try testing.expectEqualStrings("Web", m[2].item.title);
    try testing.expectEqualStrings("inline-ls", m[3].item.id);
    try testing.expectEqualStrings("List", m[3].item.title);
    try testing.expect(m[3].item.action != null);
}

test "unit: custom_actions: ui.newWorkspace.action prefers the project and honors the legacy key" {
    var t = T.init();
    defer t.deinit();
    const g = "{\"actions\":{\"a\":{\"workspace\":{}},\"b\":{\"workspace\":{}}},\"ui\":{\"newWorkspace\":{\"action\":\"a\"}},\"commands\":[{\"name\":\"Dev\",\"workspace\":{}},{\"name\":\"sh\",\"command\":\"ls\"}]}";
    const r1 = try t.registry(g, null);
    try testing.expectEqualStrings("a", (try newWorkspaceActionId(t.a(), &r1)).?);
    const r2 = try t.registry(g, "{\"ui\":{\"newWorkspace\":{\"action\":\"b\"}}}");
    try testing.expectEqualStrings("b", (try newWorkspaceActionId(t.a(), &r2)).?);
    const r3 = try t.registry(g, "{\"newWorkspaceCommand\":\"Dev\"}");
    try testing.expectEqualStrings("command:Dev", (try newWorkspaceActionId(t.a(), &r3)).?);
    const r4 = try t.registry("{\"actions\":{\"a\":{\"workspace\":{}}}}", null);
    try testing.expect((try newWorkspaceActionId(t.a(), &r4)) == null);

    const choices = try defaultWorkspaceChoices(t.a(), &r3);
    try testing.expectEqual(@as(usize, 4), choices.len);
    try testing.expect(choices[0].id == null and !choices[0].selected);
    try testing.expectEqualStrings("command:Dev", choices[3].id.?);
    try testing.expect(choices[3].selected);
    const c4 = try defaultWorkspaceChoices(t.a(), &r4);
    try testing.expect(c4[0].selected);
}

test "unit: custom_actions: substitution replaces known names and leaves the rest verbatim" {
    const vars: Vars = .{
        .vars = &.{ .{ .name = "cwd", .value = "C:\\src\\äpp" }, .{ .name = "workspaceName", .value = "dev 🚀" } },
        .env = &.{.{ .name = "Path", .value = "C:\\bin" }},
        .env_ignore_case = true,
    };
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "cd ${cwd} && echo ${workspaceName}", "cd C:\\src\\äpp && echo dev 🚀" },
        .{ "${env:PATH};x", "C:\\bin;x" },
        .{ "echo ${HOME} $USER ${env:NOPE}", "echo ${HOME} $USER ${env:NOPE}" },
        .{ "literal $${cwd}", "literal ${cwd}" },
        .{ "open ${cwd", "open ${cwd" },
        .{ "", "" },
        .{ "$", "$" },
        .{ "${}", "${}" },
        .{ "${cwd}${cwd}", "C:\\src\\äppC:\\src\\äpp" },
    };
    for (cases) |c| {
        const out = try substitute(testing.allocator, c[0], vars);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c[1], out);
    }
    const strict = try substitute(testing.allocator, "${env:path}", .{ .env = vars.env });
    defer testing.allocator.free(strict);
    try testing.expectEqualStrings("${env:path}", strict);
}

test "unit: custom_actions: higher layers replace actions by id in place" {
    var t = T.init();
    defer t.deinit();
    const pack = try t.config("{\"actions\":{\"x\":{\"command\":\"pack\"},\"y\":{\"command\":\"y\"}}}", .global);
    const global = try t.config("{\"actions\":{\"x\":{\"command\":\"global\"}}}", .global);
    const project = try t.config("{\"actions\":{\"z\":{\"command\":\"z\"},\"x\":{\"command\":\"project\"}}}", .project);
    const reg = try buildRegistry(t.a(), &.{ &pack, &global, &project });
    try testing.expectEqual(@as(usize, 3), reg.actions.len);
    try testing.expectEqualStrings("x", reg.actions[0].id);
    try testing.expectEqualStrings("project", reg.actions[0].body.command.command);
    try testing.expectEqual(Source.project, reg.actions[0].source);
    try testing.expectEqualStrings("z", reg.actions[2].id);
}

test "unit: custom_actions: many actions parse and resolve" {
    var t = T.init();
    defer t.deinit();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(t.a(), "{\"actions\":{");
    for (0..2000) |i| {
        if (i > 0) try src.append(t.a(), ',');
        try src.print(t.a(), "\"a{d}\":{{\"command\":\"echo {d}\"}}", .{ i, i });
    }
    try src.appendSlice(t.a(), "}}");
    const reg = try t.registry(src.items, null);
    try testing.expectEqual(@as(usize, 2000), (try paletteRows(t.a(), &reg)).len);
    try testing.expectEqualStrings("echo 1999", reg.findAction("a1999").?.body.command.command);
}
