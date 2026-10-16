//! Keymap preset diffs: windows-terminal, tmux, linux-ghostty, wmux-classic
//! (ADR-8.9), plus the pure keymap checker shared with the catalog's keymap
//! conflict test: effective bindings, context overlap and collisions.
//!
//! Context overlap is decided over a fixed set of representative context
//! snapshots (one focused element × find bar × alternate screen × canvas
//! layout); each clause becomes a bitmask of the snapshots where it holds.

const std = @import("std");
const strokes = @import("strokes.zig");
const when = @import("when.zig");
const catalog = @import("actions_catalog.zig");

// ------------------------------------------------------------ snapshots

/// Mutually exclusive focus targets (ADR-8.5 focus keys).
pub const Focus = enum {
    terminal,
    browser,
    web_panel,
    markdown,
    markdown_edit,
    diff_viewer,
    file_preview_editor,
    file_explorer,
    text_box,
    todo,
    sidebar,
    right_sidebar,
    command_palette,
    find_field,
};

const focus_count = std.enums.values(Focus).len;
pub const snapshot_count = focus_count * 8;
pub const Mask = u128;
comptime {
    std.debug.assert(snapshot_count <= @bitSizeOf(Mask));
}

pub const Snapshot = struct {
    focus: Focus,
    find_visible: bool,
    alt_screen: bool,
    canvas: bool,

    pub fn fromIndex(i: usize) Snapshot {
        return .{
            .focus = @enumFromInt(i / 8),
            .find_visible = (i / 4) % 2 == 1 or i / 8 == @intFromEnum(Focus.find_field),
            .alt_screen = (i / 2) % 2 == 1 and i / 8 == @intFromEnum(Focus.terminal),
            .canvas = i % 2 == 1,
        };
    }

    fn lookup(ptr: *const anyopaque, key: []const u8) ?when.Value {
        const s: *const Snapshot = @ptrCast(@alignCast(ptr));
        const f = s.focus;
        const eq = std.mem.eql;
        const b: bool = if (eq(u8, key, "terminalFocus")) f == .terminal //
        else if (eq(u8, key, "browserFocus")) f == .browser //
        else if (eq(u8, key, "webPanelFocus")) f == .web_panel //
        else if (eq(u8, key, "markdownFocus")) f == .markdown or f == .markdown_edit //
        else if (eq(u8, key, "markdownEditFocus")) f == .markdown_edit //
        else if (eq(u8, key, "diffViewerFocus")) f == .diff_viewer //
        else if (eq(u8, key, "filePreviewTextEditorFocus")) f == .file_preview_editor //
        else if (eq(u8, key, "fileExplorerFocus")) f == .file_explorer //
        else if (eq(u8, key, "textBoxFocus")) f == .text_box //
        else if (eq(u8, key, "todoFocus")) f == .todo //
        else if (eq(u8, key, "sidebarFocus")) f == .sidebar //
        else if (eq(u8, key, "rightSidebarFocus")) f == .right_sidebar //
        else if (eq(u8, key, "commandPaletteVisible")) f == .command_palette //
        else if (eq(u8, key, "findFieldFocus")) f == .find_field //
        else if (eq(u8, key, "findVisible")) s.find_visible //
        else if (eq(u8, key, "terminalFindVisible")) s.find_visible and f == .terminal //
        else if (eq(u8, key, "terminalAlternateScreen")) s.alt_screen //
        else if (eq(u8, key, "workspaceCanvasLayout")) s.canvas //
        else return null;
        return .{ .boolean = b };
    }

    pub fn context(s: *const Snapshot) when.Context {
        return .{ .ptr = s, .getFn = lookup };
    }
};

/// Snapshots where the terminal has focus.
pub const terminal_mask: Mask = blk: {
    var m: Mask = 0;
    for (0..snapshot_count) |i| {
        if (Snapshot.fromIndex(i).focus == .terminal) m |= @as(Mask, 1) << @intCast(i);
    }
    break :blk m;
};

pub const all_mask: Mask = if (snapshot_count == @bitSizeOf(Mask)) ~@as(Mask, 0) else (@as(Mask, 1) << snapshot_count) - 1;

/// Bitmask of the snapshots where `clause` holds (null clause = global).
pub fn clauseMask(gpa: std.mem.Allocator, clause: ?[]const u8) when.ParseError!Mask {
    const src = clause orelse return all_mask;
    var c = try when.parse(gpa, src);
    defer c.deinit();
    var m: Mask = 0;
    for (0..snapshot_count) |i| {
        const s = Snapshot.fromIndex(i);
        if (c.eval(s.context())) m |= @as(Mask, 1) << @intCast(i);
    }
    return m;
}

// ------------------------------------------------------------- bindings

/// One effective default (or preset) binding.
pub const Binding = struct {
    id: []const u8,
    trigger: strokes.Trigger,
    when: ?[]const u8,
    mask: Mask,
    performable: bool,
};

pub const BuildError = when.ParseError || strokes.ParseError || error{UnknownAction};

fn appendKey(gpa: std.mem.Allocator, out: *std.ArrayList(Binding), e: *const catalog.Entry, key: []const u8, clause: ?[]const u8) BuildError!void {
    const t = try strokes.Trigger.parse(key, .windows);
    const mask = try clauseMask(gpa, clause);
    // A numbered key stands for its whole 1–9 family; the digit is the last
    // stroke ("ctrl+shift+1", or "ctrl+b 1" after a chord prefix).
    const last = t.second orelse t.first;
    if (!e.numbered or last.key.kind() != .digit) {
        try out.append(gpa, .{ .id = e.id, .trigger = t, .when = clause, .mask = mask, .performable = e.performable });
        return;
    }
    for (1..10) |dg| {
        const k = strokes.Key.fromDigit(@intCast(dg));
        var ft = t;
        if (t.second) |s| ft.second = s.withKey(k) else ft.first = t.first.withKey(k);
        try out.append(gpa, .{ .id = e.id, .trigger = ft, .when = clause, .mask = mask, .performable = e.performable });
    }
}

fn appendEntryKeys(gpa: std.mem.Allocator, out: *std.ArrayList(Binding), e: *const catalog.Entry, keys: []const []const u8) BuildError!void {
    if (e.availability == .not_applicable) return;
    for (keys) |k| try appendKey(gpa, out, e, k, e.when);
}

/// Effective bindings of the built-in defaults, or of the defaults with a
/// preset's overrides applied (an override replaces every default key of
/// its action, scoped ones included). Numbered keys are expanded to the nine
/// strokes or chords the router matches. Caller frees with `gpa.free`.
pub fn effectiveBindings(gpa: std.mem.Allocator, preset: ?*const Preset) BuildError![]Binding {
    var out: std.ArrayList(Binding) = .empty;
    errdefer out.deinit(gpa);
    for (&catalog.entries) |*e| {
        if (preset) |p| if (p.override(e.id)) |o| {
            try appendEntryKeys(gpa, &out, e, o.keys);
            continue;
        };
        try appendEntryKeys(gpa, &out, e, e.keys);
        if (e.availability == .supported) {
            for (e.scoped) |sc| try appendKey(gpa, &out, e, sc.key, sc.when);
        }
    }
    if (preset) |p| for (p.overrides) |o| {
        if (catalog.find(o.id) == null) return error.UnknownAction;
    };
    return out.toOwnedSlice(gpa);
}

pub const Conflict = struct { a: Binding, b: Binding };

pub const ConflictOptions = struct {
    /// Unordered id pairs that intentionally share a stroke.
    allow: []const [2][]const u8 = &.{},
    /// Router semantics (ADR-8.2 step 4): a binding with a `when` clause
    /// shadows a global one, so only same-specificity pairs collide. The
    /// default-keymap test runs strict (false); presets run with true.
    specific_beats_global: bool = false,
};

/// Pairs of actions sharing a trigger (or a chord prefix) in an overlapping
/// context. Caller frees.
pub fn findConflicts(gpa: std.mem.Allocator, bindings: []const Binding, opts: ConflictOptions) error{OutOfMemory}![]Conflict {
    var out: std.ArrayList(Conflict) = .empty;
    errdefer out.deinit(gpa);
    for (bindings, 0..) |a, i| for (bindings[i + 1 ..]) |b| {
        if (std.mem.eql(u8, a.id, b.id)) continue;
        if (a.mask & b.mask == 0) continue;
        if (!a.trigger.eql(b.trigger) and !strokes.Trigger.prefixCollides(a.trigger, b.trigger)) continue;
        if (opts.specific_beats_global and ((a.when == null) != (b.when == null))) continue;
        if (isAllowed(opts.allow, a.id, b.id)) continue;
        try out.append(gpa, .{ .a = a, .b = b });
    };
    return out.toOwnedSlice(gpa);
}

fn isAllowed(allow: []const [2][]const u8, x: []const u8, y: []const u8) bool {
    for (allow) |p| {
        if (std.mem.eql(u8, p[0], x) and std.mem.eql(u8, p[1], y)) return true;
        if (std.mem.eql(u8, p[0], y) and std.mem.eql(u8, p[1], x)) return true;
    }
    return false;
}

/// True when the binding can fire while a terminal has focus.
pub fn terminalCapable(b: Binding) bool {
    return b.mask & terminal_mask != 0;
}

/// ADR-8.4 check of one binding: terminal-capable bindings must use a safe
/// tier on their first stroke.
pub fn violatesTerminalSafety(b: Binding) bool {
    return terminalCapable(b) and !strokes.tier(b.trigger.first).terminalSafe();
}

// -------------------------------------------------------------- presets

/// Replaces every default key of `id`; empty `keys` unbinds it.
pub const Override = struct {
    id: []const u8,
    keys: []const []const u8,
};

pub const Preset = struct {
    name: []const u8,
    title: []const u8,
    description: []const u8,
    overrides: []const Override,
    /// Shown before applying (behavior that changes muscle memory).
    warning: ?[]const u8 = null,

    pub fn override(p: *const Preset, id: []const u8) ?*const Override {
        for (p.overrides) |*o| if (std.mem.eql(u8, o.id, id)) return o;
        return null;
    }
};

/// Choosing the default keymap removes preset-written entries (cmux "cmux (Default)").
pub const default_name = "cmux";

pub const presets = [_]Preset{
    .{
        .name = "windows-terminal",
        .title = "Windows Terminal",
        .description = "Windows Terminal pane and tab keys: Alt+Shift+= / Alt+Shift+- split, Alt+arrows move focus, Ctrl+Alt+1…9 select workspaces.",
        .warning = "Alt+arrows will move pane focus instead of reaching the shell (readline and PSReadLine word motion).",
        .overrides = &.{
            .{ .id = "equalizeSplits", .keys = &.{} },
            .{ .id = "focusDown", .keys = &.{"alt+down"} },
            .{ .id = "focusLeft", .keys = &.{"alt+left"} },
            .{ .id = "focusRight", .keys = &.{"alt+right"} },
            .{ .id = "focusUp", .keys = &.{"alt+up"} },
            .{ .id = "selectWorkspaceByNumber", .keys = &.{"ctrl+alt+1"} },
            .{ .id = "splitDown", .keys = &.{"alt+shift+-"} },
            .{ .id = "splitRight", .keys = &.{"alt+shift+="} },
        },
    },
    .{
        .name = "linux-ghostty",
        .title = "Ghostty (Linux)",
        .description = "Ghostty's Linux defaults: Alt+1…9 select surfaces, Ctrl+Shift+O / Ctrl+Shift+E split right / down.",
        .warning = "Alt+1…9 will select surfaces instead of sending Meta-digit (readline and PSReadLine digit-argument).",
        .overrides = &.{
            .{ .id = "focusSidebar", .keys = &.{} },
            .{ .id = "openFolder", .keys = &.{} },
            .{ .id = "selectSurfaceByNumber", .keys = &.{"alt+1"} },
            .{ .id = "splitDown", .keys = &.{"ctrl+shift+e"} },
            .{ .id = "splitRight", .keys = &.{"ctrl+shift+o"} },
        },
    },
    .{
        .name = "tmux",
        .title = "tmux-style (Ctrl-B prefix)",
        .description = "Ctrl+B prefix chords for workspaces, splits, pane focus, zoom and copy mode.",
        .warning = "Ctrl+B will no longer reach the shell (readline backward-char, tmux inside wmux).",
        .overrides = &.{
            .{ .id = "closeTab", .keys = &.{"ctrl+b x"} },
            .{ .id = "closeWorkspace", .keys = &.{"ctrl+b shift+7"} },
            .{ .id = "focusDown", .keys = &.{"ctrl+b down"} },
            .{ .id = "focusLeft", .keys = &.{"ctrl+b left"} },
            .{ .id = "focusNextPane", .keys = &.{"ctrl+b o"} },
            .{ .id = "focusRight", .keys = &.{"ctrl+b right"} },
            .{ .id = "focusUp", .keys = &.{"ctrl+b up"} },
            .{ .id = "goToWorkspace", .keys = &.{"ctrl+b w"} },
            .{ .id = "newTab", .keys = &.{"ctrl+b c"} },
            .{ .id = "nextSidebarTab", .keys = &.{"ctrl+b n"} },
            .{ .id = "prevSidebarTab", .keys = &.{"ctrl+b p"} },
            .{ .id = "renameWorkspace", .keys = &.{"ctrl+b ,"} },
            .{ .id = "selectWorkspaceByNumber", .keys = &.{"ctrl+b 1"} },
            .{ .id = "splitDown", .keys = &.{"ctrl+b shift+'"} },
            .{ .id = "splitRight", .keys = &.{"ctrl+b shift+5"} },
            .{ .id = "toggleSplitZoom", .keys = &.{"ctrl+b z"} },
            .{ .id = "toggleTerminalCopyMode", .keys = &.{"ctrl+b ["} },
        },
    },
    .{
        .name = "wmux-classic",
        .title = "wmux classic",
        .description = "Pre-parity wmux defaults: Ctrl+T, Ctrl+W, Ctrl+B, Alt+1…9, Ctrl+Enter.",
        .warning = "Ctrl+T, Ctrl+W, Ctrl+B and Alt+1…9 will no longer reach the shell.",
        .overrides = &.{
            .{ .id = "closeTab", .keys = &.{ "ctrl+w", "ctrl+shift+w" } },
            .{ .id = "newSurface", .keys = &.{ "ctrl+t", "ctrl+shift+t" } },
            .{ .id = "nextSurface", .keys = &.{ "ctrl+tab", "ctrl+pgdn" } },
            .{ .id = "openFolder", .keys = &.{} },
            .{ .id = "prevSurface", .keys = &.{ "ctrl+shift+tab", "ctrl+pgup" } },
            .{ .id = "selectSurfaceByNumber", .keys = &.{"alt+1"} },
            .{ .id = "splitRight", .keys = &.{"ctrl+shift+o"} },
            .{ .id = "toggleFileExplorer", .keys = &.{"ctrl+alt+b"} },
            .{ .id = "toggleFullScreen", .keys = &.{"ctrl+enter"} },
            .{ .id = "toggleSidebar", .keys = &.{"ctrl+b"} },
        },
    },
};

/// Looks up a preset by name; null for unknown names and for `default_name`.
pub fn find(name: []const u8) ?*const Preset {
    for (&presets) |*p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

/// True for every name `cmux config preset <name>` accepts.
pub fn isKnownName(name: []const u8) bool {
    return std.mem.eql(u8, name, default_name) or find(name) != null;
}

// ------------------------------------------------------------ apply plan

/// A user's current `shortcuts.bindings.<id>` value (empty = unbound).
pub const UserBinding = struct {
    id: []const u8,
    keys: []const []const u8,
};

/// What `cmux config preset <name>` / Settings "Apply Keymap" writes.
/// Slices borrow from the preset tables and the caller's input.
pub const Plan = struct {
    /// Entries to write into `shortcuts.bindings`.
    set: []const Override,
    /// Ids whose entries are removed (preset-written values not in the new preset).
    remove: []const []const u8,
    /// Ids the user customized; left untouched ("Kept your own shortcut for X").
    kept: []const []const u8,

    pub fn deinit(p: *Plan, gpa: std.mem.Allocator) void {
        gpa.free(p.set);
        gpa.free(p.remove);
        gpa.free(p.kept);
        p.* = undefined;
    }

    pub fn isEmpty(p: Plan) bool {
        return p.set.len == 0 and p.remove.len == 0;
    }
};

/// Order-sensitive equality of two key lists after parsing (so
/// "Ctrl+Shift+D" equals "ctrl+shift+d"). Unparsable keys compare as text.
pub fn keysEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const tx = strokes.Trigger.parse(x, .windows) catch {
            if (!std.mem.eql(u8, x, y)) return false;
            continue;
        };
        const ty = strokes.Trigger.parse(y, .windows) catch return false;
        if (!tx.eql(ty)) return false;
    }
    return true;
}

/// True when the override changes the catalog default of its action.
pub fn differsFromDefault(o: Override) bool {
    const e = catalog.find(o.id) orelse return true;
    return e.scoped.len != 0 or !keysEqual(o.keys, e.keys);
}

/// True when `u` holds exactly the value some preset writes for its id.
fn presetOwned(u: UserBinding) bool {
    for (&presets) |*p| if (p.override(u.id)) |o| {
        if (keysEqual(o.keys, u.keys)) return true;
    };
    return false;
}

fn findUser(current: []const UserBinding, id: []const u8) ?UserBinding {
    for (current) |u| if (std.mem.eql(u8, u.id, id)) return u;
    return null;
}

pub const PlanError = error{ OutOfMemory, UnknownPreset };

/// Computes the minimal edit that switches `current` to preset `name`
/// (`default_name` removes every preset-written entry).
pub fn plan(gpa: std.mem.Allocator, name: []const u8, current: []const UserBinding) PlanError!Plan {
    const target: ?*const Preset = if (std.mem.eql(u8, name, default_name)) null else find(name) orelse return error.UnknownPreset;
    var set: std.ArrayList(Override) = .empty;
    errdefer set.deinit(gpa);
    var remove: std.ArrayList([]const u8) = .empty;
    errdefer remove.deinit(gpa);
    var kept: std.ArrayList([]const u8) = .empty;
    errdefer kept.deinit(gpa);

    for (current) |u| {
        if (!presetOwned(u)) continue;
        const o = if (target) |t| t.override(u.id) else null;
        if (o == null or !differsFromDefault(o.?.*)) try remove.append(gpa, u.id);
    }
    if (target) |t| for (t.overrides) |o| {
        if (!differsFromDefault(o)) continue;
        if (findUser(current, o.id)) |u| {
            if (keysEqual(u.keys, o.keys)) continue; // already applied
            if (!presetOwned(u)) {
                try kept.append(gpa, o.id);
                continue;
            }
        }
        try set.append(gpa, o);
    };
    const s = try set.toOwnedSlice(gpa);
    errdefer gpa.free(s);
    const r = try remove.toOwnedSlice(gpa);
    errdefer gpa.free(r);
    return .{ .set = s, .remove = r, .kept = try kept.toOwnedSlice(gpa) };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "unit: keys: context snapshot masks" {
    const gpa = testing.allocator;
    try testing.expectEqual(all_mask, try clauseMask(gpa, null));
    try testing.expectEqual(all_mask, try clauseMask(gpa, "true"));
    try testing.expectEqual(@as(Mask, 0), try clauseMask(gpa, "false"));
    try testing.expectEqual(terminal_mask, try clauseMask(gpa, "terminalFocus"));
    try testing.expectEqual(all_mask & ~terminal_mask, try clauseMask(gpa, "!terminalFocus"));
    try testing.expectEqual(@as(Mask, 0), try clauseMask(gpa, "browserFocus && terminalFocus"));
    try testing.expectEqual(@as(Mask, 0), try clauseMask(gpa, "terminalAlternateScreen && !terminalFocus"));
    try testing.expect(try clauseMask(gpa, "findVisible && findFieldFocus") & terminal_mask == 0);
    try testing.expect(try clauseMask(gpa, "findVisible") & terminal_mask != 0);
    try testing.expect(try clauseMask(gpa, "markdownFocus") & try clauseMask(gpa, "markdownEditFocus") != 0);
    try testing.expectEqual(@as(Mask, 0), try clauseMask(gpa, "unknownKey"));
    try testing.expectError(error.UnexpectedEnd, clauseMask(gpa, "terminalFocus &&"));
    try testing.expectEqual(@as(u32, @popCount(all_mask)), snapshot_count);
}

test "unit: keys: presets are well-formed" {
    for (presets, 0..) |p, i| {
        errdefer std.log.err("bad preset '{s}'", .{p.name});
        try testing.expect(find(p.name) == &presets[i]);
        try testing.expect(!std.mem.eql(u8, p.name, default_name));
        try testing.expect(p.overrides.len > 0);
        for (p.overrides, 0..) |o, j| {
            const e = catalog.find(o.id) orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings(e.id, o.id); // canonical id, not an alias
            try testing.expect(e.availability == .supported);
            for (o.keys) |k| {
                const t = try strokes.Trigger.parse(k, .windows);
                // Numbered families are written with their first member.
                if (e.numbered) try testing.expectEqual(strokes.Key.@"1", (t.second orelse t.first).key);
            }
            // Sorted, one entry per id; and every override changes a default.
            if (j > 0) try testing.expect(std.mem.lessThan(u8, p.overrides[j - 1].id, o.id));
            try testing.expect(differsFromDefault(o));
        }
    }
    for ([_][]const u8{ "windows-terminal", "tmux", "linux-ghostty", "wmux-classic", "cmux" }) |n|
        try testing.expect(isKnownName(n));
    try testing.expect(find("cmux") == null);
    try testing.expect(!isKnownName("iterm2"));
    try testing.expect(!isKnownName(""));
}

const shared = [_][2][]const u8{.{ "groupSelectedWorkspaces", "toggleReactGrab" }};

test "unit: keys: every preset keymap is conflict-free under router precedence" {
    const gpa = testing.allocator;
    for (&presets) |*p| {
        const bindings = try effectiveBindings(gpa, p);
        defer gpa.free(bindings);
        const conflicts = try findConflicts(gpa, bindings, .{ .allow = &shared, .specific_beats_global = true });
        defer gpa.free(conflicts);
        for (conflicts) |c| std.log.err("preset {s}: {s} vs {s}", .{ p.name, c.a.id, c.b.id });
        try testing.expectEqual(@as(usize, 0), conflicts.len);
    }
}

test "unit: keys: conflicts with a numbered chord family are found" {
    const gpa = testing.allocator;
    // "ctrl+b 2" is a member of selectWorkspaceByNumber's ctrl+b 1…9 family.
    const clash: Preset = .{ .name = "t", .title = "t", .description = "t", .overrides = &.{
        .{ .id = "newTab", .keys = &.{"ctrl+b 2"} },
        .{ .id = "selectWorkspaceByNumber", .keys = &.{"ctrl+b 1"} },
    } };
    const b = try effectiveBindings(gpa, &clash);
    defer gpa.free(b);
    const conflicts = try findConflicts(gpa, b, .{ .specific_beats_global = true });
    defer gpa.free(conflicts);
    try testing.expectEqual(@as(usize, 1), conflicts.len);
    try testing.expect(conflicts[0].a.trigger.eql(try strokes.Trigger.parse("ctrl+b 2", .windows)));
    // A plain "ctrl+b" binding is a prefix of every member.
    const prefix: Preset = .{ .name = "t", .title = "t", .description = "t", .overrides = &.{
        .{ .id = "selectWorkspaceByNumber", .keys = &.{"ctrl+b 1"} },
        .{ .id = "toggleSidebar", .keys = &.{"ctrl+b"} },
    } };
    const b2 = try effectiveBindings(gpa, &prefix);
    defer gpa.free(b2);
    const c2 = try findConflicts(gpa, b2, .{ .specific_beats_global = true });
    defer gpa.free(c2);
    try testing.expectEqual(@as(usize, 9), c2.len);
    // An unknown override id is an error, and nothing leaks.
    const unknown: Preset = .{ .name = "t", .title = "t", .description = "t", .overrides = &.{
        .{ .id = "noSuchAction", .keys = &.{"ctrl+shift+f12"} },
    } };
    try testing.expectError(error.UnknownAction, effectiveBindings(gpa, &unknown));
    const bad_key: Preset = .{ .name = "t", .title = "t", .description = "t", .overrides = &.{
        .{ .id = "splitRight", .keys = &.{"ctrl+shift+nokey"} },
    } };
    try testing.expectError(error.UnknownKey, effectiveBindings(gpa, &bad_key));
}

fn bindingFor(bindings: []const Binding, id: []const u8) ?Binding {
    for (bindings) |b| if (std.mem.eql(u8, b.id, id)) return b;
    return null;
}

test "unit: keys: preset contents" {
    const gpa = testing.allocator;
    const tmux = find("tmux").?;
    const b = try effectiveBindings(gpa, tmux);
    defer gpa.free(b);
    const new_tab = bindingFor(b, "newTab").?;
    try testing.expect(new_tab.trigger.eql(try strokes.Trigger.parse("ctrl+b c", .windows)));
    // Overridden actions lose their defaults; others keep them.
    for (b) |x| if (std.mem.eql(u8, x.id, "newTab")) try testing.expect(x.trigger.isChord());
    try testing.expect(bindingFor(b, "newSurface").?.trigger.eql(try strokes.Trigger.parse("ctrl+shift+t", .windows)));
    // A numbered chord ("ctrl+b 1") stands for ctrl+b 1 … ctrl+b 9.
    var fam: usize = 0;
    for (b) |x| if (std.mem.eql(u8, x.id, "selectWorkspaceByNumber")) {
        fam += 1;
        try testing.expect(x.trigger.first.eql(try strokes.Stroke.parse("ctrl+b", .windows)));
        try testing.expectEqual(@as(?u8, @as(u8, @intCast(fam))), x.trigger.second.?.key.digit());
    };
    try testing.expectEqual(@as(usize, 9), fam);

    const wt = try effectiveBindings(gpa, find("windows-terminal").?);
    defer gpa.free(wt);
    var n: usize = 0;
    for (wt) |x| if (std.mem.eql(u8, x.id, "selectWorkspaceByNumber")) {
        n += 1;
        try testing.expect(x.trigger.first.mods.eql(.{ .ctrl = true, .alt = true }));
    };
    try testing.expectEqual(@as(usize, 9), n);
    try testing.expect(bindingFor(wt, "equalizeSplits") == null);

    const classic = try effectiveBindings(gpa, find("wmux-classic").?);
    defer gpa.free(classic);
    var alt_digits: usize = 0;
    for (classic) |x| if (std.mem.eql(u8, x.id, "selectSurfaceByNumber")) {
        try testing.expect(x.trigger.first.mods.eql(.{ .alt = true }));
        alt_digits += 1;
    };
    try testing.expectEqual(@as(usize, 9), alt_digits);
    // Presets are opt-in and may claim terminal keys; defaults never do.
    var violations: usize = 0;
    for (classic) |x| if (violatesTerminalSafety(x)) {
        violations += 1;
    };
    try testing.expect(violations > 0);
}

/// Applies a plan to an in-memory bindings list (test model of cmux.json).
fn applyPlan(gpa: std.mem.Allocator, list: *std.ArrayList(UserBinding), p: Plan) !void {
    for (p.remove) |id| {
        for (list.items, 0..) |u, i| if (std.mem.eql(u8, u.id, id)) {
            _ = list.orderedRemove(i);
            break;
        };
    }
    for (p.set) |o| {
        const existing = for (list.items) |*u| {
            if (std.mem.eql(u8, u.id, o.id)) break u;
        } else null;
        if (existing) |u| u.keys = o.keys else try list.append(gpa, .{ .id = o.id, .keys = o.keys });
    }
}

test "unit: keys: preset plan writes only differences and cmux removes them" {
    const gpa = testing.allocator;
    var cfg: std.ArrayList(UserBinding) = .empty;
    defer cfg.deinit(gpa);
    // A user customization unrelated to presets survives everything.
    try cfg.append(gpa, .{ .id = "openBrowser", .keys = &.{"alt+shift+l"} });

    var p1 = try plan(gpa, "tmux", cfg.items);
    try testing.expectEqual(find("tmux").?.overrides.len, p1.set.len);
    try testing.expectEqual(@as(usize, 0), p1.remove.len);
    try applyPlan(gpa, &cfg, p1);
    p1.deinit(gpa);
    try testing.expectEqual(1 + find("tmux").?.overrides.len, cfg.items.len);

    // Re-applying is a no-op ("No shortcuts changed.").
    var again = try plan(gpa, "tmux", cfg.items);
    try testing.expect(again.isEmpty());
    again.deinit(gpa);

    // Switching presets removes tmux-only entries and writes the new ones.
    var p2 = try plan(gpa, "windows-terminal", cfg.items);
    try testing.expect(p2.remove.len > 0);
    try applyPlan(gpa, &cfg, p2);
    p2.deinit(gpa);
    for (cfg.items) |u| try testing.expect(!std.mem.eql(u8, u.id, "newTab"));

    // Back to the default keymap: no preset entries remain.
    var p3 = try plan(gpa, default_name, cfg.items);
    try testing.expectEqual(@as(usize, 0), p3.set.len);
    try applyPlan(gpa, &cfg, p3);
    p3.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), cfg.items.len);
    try testing.expectEqualStrings("openBrowser", cfg.items[0].id);
}

test "unit: keys: preset plan keeps the user's own shortcuts" {
    const gpa = testing.allocator;
    const current = [_]UserBinding{
        .{ .id = "splitRight", .keys = &.{"ctrl+shift+alt+\\"} }, // custom
        .{ .id = "newTab", .keys = &.{"Ctrl+B C"} }, // equals the tmux value (normalized)
    };
    var p = try plan(gpa, "tmux", &current);
    defer p.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), p.kept.len);
    try testing.expectEqualStrings("splitRight", p.kept[0]);
    for (p.set) |o| {
        try testing.expect(!std.mem.eql(u8, o.id, "splitRight"));
        try testing.expect(!std.mem.eql(u8, o.id, "newTab"));
    }
    try testing.expectEqual(find("tmux").?.overrides.len - 2, p.set.len);
    // An unbound user entry is a customization too.
    const unbound = [_]UserBinding{.{ .id = "focusLeft", .keys = &.{} }};
    var q = try plan(gpa, "windows-terminal", &unbound);
    defer q.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), q.kept.len);
    try testing.expectError(error.UnknownPreset, plan(gpa, "iterm2", &.{}));
    var empty = try plan(gpa, default_name, &.{});
    defer empty.deinit(gpa);
    try testing.expect(empty.isEmpty());
}

test "unit: keys: keysEqual normalizes strokes" {
    try testing.expect(keysEqual(&.{"Ctrl+Shift+D"}, &.{"shift+ctrl+d"}));
    try testing.expect(!keysEqual(&.{"ctrl+shift+d"}, &.{"ctrl+shift+e"}));
    try testing.expect(!keysEqual(&.{"ctrl+shift+d"}, &.{}));
    try testing.expect(keysEqual(&.{}, &.{}));
    try testing.expect(keysEqual(&.{"bogus+x"}, &.{"bogus+x"}));
    try testing.expect(!keysEqual(&.{"bogus+x"}, &.{"ctrl+x"}));
    try testing.expect(!differsFromDefault(.{ .id = "splitRight", .keys = &.{"ctrl+shift+d"} }));
    try testing.expect(differsFromDefault(.{ .id = "splitRight", .keys = &.{} }));
    try testing.expect(differsFromDefault(.{ .id = "nope", .keys = &.{} }));
}
