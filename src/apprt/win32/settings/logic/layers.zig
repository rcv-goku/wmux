//! Pure parts of the settings layer stack (ARCHITECTURE.md ADR-5.1-5.5,
//! 5.7) on top of `wmux_proto/settings/resolve.zig` (W0-P2): the spec list
//! the app resolves, the layer order of files and their packs, legacy
//! Ghostty key extraction from replay arguments, id-keyed merges of the
//! project-overridable sections, snapshot diffs, the generated Ghostty
//! overrides file, the policy test file and the notice text. std and
//! wmux_proto only (`zig build test-fast`).

const std = @import("std");
const proto = @import("wmux_proto");

const jsonc = proto.jsonc;
const resolve = proto.settings.resolve;
const spec_mod = proto.settings.spec;
const manifest = proto.settings.specs_manifest;

const Allocator = std.mem.Allocator;
const Node = jsonc.Node;
const Spec = spec_mod.Spec;

pub const Source = resolve.Source;
pub const Layer = resolve.Layer;
pub const Resolved = resolve.Resolved;
pub const PolicyValue = resolve.PolicyValue;
pub const GhosttyPair = resolve.GhosttyPair;

// ---------------------------------------------------------------------------
// The spec list

/// Interim specs for the keys the settings layer itself needs before their
/// owners declare them (terminal_io in W2, automation in W5; ADR-5.5 and
/// ADR-3.8 name them). Each one drops out of `effective_specs`
/// automatically as soon as `specs_manifest.all` declares the same path
/// (or a section/setting clash with it), so the owner's spec always wins.
/// They are resolved, logged, policy-lockable and generate the Ghostty
/// overrides, but `settings.get` (comptime-checked against the manifest)
/// cannot read them.
pub const interim_specs = [_]Spec{
    .{
        .path = "automation.socketControlMode",
        .ty = .{ .enumeration = &.{ "off", "cmuxOnly", "automation", "password", "allowAll", "readOnly" } },
        .default = "\"cmuxOnly\"",
        .section = "automation",
        .label = "Socket control mode",
        .doc = "Who may connect to the control socket.",
        .apply = .restart,
    },
    .{
        .path = "terminal.copyOnSelect",
        .ty = .boolean,
        .default = "false",
        .section = "terminal",
        .label = "Copy on select",
        .doc = "Copy selected terminal text to the clipboard.",
        .ghostty_override = "copy-on-select",
    },
    .{
        .path = "terminal.confirmUnsafePaste",
        .ty = .boolean,
        .default = "true",
        .section = "terminal",
        .label = "Confirm unsafe paste",
        .doc = "Ask before pasting text that could run commands.",
        .ghostty_override = "clipboard-paste-protection",
    },
};

/// Every spec the app resolves: the registry plus the interim specs it
/// does not declare yet.
pub const effective_specs: []const Spec = withInterim(manifest.all, &interim_specs);

fn clashes(comptime registered: []const Spec, comptime path: []const u8) bool {
    for (registered) |r| {
        if (std.mem.eql(u8, r.path, path)) return true;
        if (isStrictPrefix(r.path, path) or isStrictPrefix(path, r.path)) return true;
    }
    return false;
}

fn isStrictPrefix(section: []const u8, path: []const u8) bool {
    return path.len > section.len and path[section.len] == '.' and std.mem.startsWith(u8, path, section);
}

/// `registered` followed by the `interim` specs that do not clash with it.
pub fn withInterim(comptime registered: []const Spec, comptime interim: []const Spec) []const Spec {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var n: usize = registered.len;
        for (interim) |s| {
            if (!clashes(registered, s.path)) n += 1;
        }
        var list: [n]Spec = undefined;
        for (registered, 0..) |s, i| list[i] = s;
        var i: usize = registered.len;
        for (interim) |s| {
            if (clashes(registered, s.path)) continue;
            list[i] = s;
            i += 1;
        }
        const final = list;
        const Mod = struct {
            pub const specs = final;
        };
        // Same comptime checks as the registry (duplicates, sections).
        _ = manifest.aggregate(.{Mod});
        return &final;
    }
}

// ---------------------------------------------------------------------------
// Legacy Ghostty keys (ADR-5.1 row 2)

/// A Ghostty replay argument (`--key=value`, `key = value` or a bare
/// `--flag`) as a pair, or null for anything else (`-e`, empty). Only
/// arguments that were explicitly given (files, includes, CLI) are replay
/// steps, so defaults never become a layer.
pub fn parseGhosttyArg(arg: []const u8) ?GhosttyPair {
    var s = std.mem.trim(u8, arg, " \t\r\n");
    if (std.mem.startsWith(u8, s, "--")) s = s[2..];
    if (s.len == 0 or s[0] == '-' or s[0] == '#') return null;
    if (std.mem.indexOfScalar(u8, s, '=')) |eq| {
        const key = std.mem.trim(u8, s[0..eq], " \t");
        if (key.len == 0) return null;
        return .{ .key = key, .value = std.mem.trim(u8, s[eq + 1 ..], " \t") };
    }
    // A bare boolean flag means true (resolve.ghosttyLayer).
    return .{ .key = s, .value = "true" };
}

// ---------------------------------------------------------------------------
// Files, packs and layer order (ADR-5.1 rows 3-6)

pub const PackEntryError = error{ RemotePack, EmptyPack, BadPackEntry };

/// One `packs` entry: a path string or `{"path": ...}`.
pub const PackEntry = union(enum) {
    path: []const u8,
    bad: struct { message: []const u8, offset: usize },
};

/// The `packs` entries of a config root, in listed order. http(s) URLs,
/// empty paths and other shapes are returned as `.bad` (validation errors
/// that skip the entry, never fatal).
pub fn packEntries(arena: Allocator, root: *const Node) Allocator.Error![]PackEntry {
    const packs = root.get("packs") orelse return &.{};
    const items = switch (packs.data) {
        .array => |a| a,
        else => {
            const out = try arena.alloc(PackEntry, 1);
            out[0] = .{ .bad = .{ .message = "packs must be an array", .offset = packs.start } };
            return out;
        },
    };
    const out = try arena.alloc(PackEntry, items.len);
    for (items, out) |*item, *o| {
        const path_node: *const Node = switch (item.data) {
            .string => item,
            .object => item.get("path") orelse {
                o.* = .{ .bad = .{ .message = "a pack object needs a \"path\"", .offset = item.start } };
                continue;
            },
            else => {
                o.* = .{ .bad = .{ .message = "a pack is a path string or {\"path\": ...}", .offset = item.start } };
                continue;
            },
        };
        const p = path_node.asString() orelse {
            o.* = .{ .bad = .{ .message = "a pack path must be a string", .offset = path_node.start } };
            continue;
        };
        const trimmed = std.mem.trim(u8, p, " \t");
        if (trimmed.len == 0) {
            o.* = .{ .bad = .{ .message = "a pack path must not be empty", .offset = path_node.start } };
        } else if (std.ascii.startsWithIgnoreCase(trimmed, "http://") or std.ascii.startsWithIgnoreCase(trimmed, "https://")) {
            o.* = .{ .bad = .{ .message = "remote packs (http/https) are not supported", .offset = path_node.start } };
        } else {
            o.* = .{ .path = trimmed };
        }
    }
    return out;
}

/// A parsed config file with the packs it lists (already parsed).
pub const InputFile = struct {
    source: Source,
    root: *const Node,
    src: []const u8 = "",
    packs: []const Pack = &.{},

    pub const Pack = struct { root: *const Node, src: []const u8 = "" };
};

/// The resolve layers of `files`: each file's packs, in listed order, then
/// the file, all with the file's source. `resolve.resolve` orders layers
/// by source with a stable sort, so a pack is overridden by the file that
/// lists it and by every later pack, and a wmux.json pack still beats
/// cmux.json (ADR-5.1 row 5).
pub fn planLayers(arena: Allocator, files: []const InputFile) Allocator.Error![]Layer {
    var out: std.ArrayList(Layer) = .empty;
    for (files) |f| {
        for (f.packs) |p| try out.append(arena, .{ .source = f.source, .root = p.root, .src = p.src });
        try out.append(arena, .{ .source = f.source, .root = f.root, .src = f.src });
    }
    return out.toOwnedSlice(arena);
}

/// Project file candidates from `cwd` upward (`resolve.projectCandidates`
/// order), leaving out `home` and its ancestors: `~/.cmux/cmux.json` or
/// `C:\cmux.json` are not project files of every directory under them.
/// Caller frees with `resolve.freePaths`.
pub fn projectCandidates(gpa: Allocator, cwd: []const u8, home: ?[]const u8) Allocator.Error![][]u8 {
    const all = try resolve.projectCandidates(gpa, cwd);
    const h = home orelse return all;
    var keep: usize = 0;
    for (all) |p| {
        var dir = std.fs.path.dirname(p) orelse "";
        // `.wmux\wmux.json` and `.cmux\cmux.json` belong to the parent.
        const base = std.fs.path.basename(dir);
        if (std.ascii.eqlIgnoreCase(base, ".wmux") or std.ascii.eqlIgnoreCase(base, ".cmux"))
            dir = std.fs.path.dirname(dir) orelse "";
        if (isSameOrAncestor(dir, h)) {
            gpa.free(p);
        } else {
            all[keep] = p;
            keep += 1;
        }
    }
    if (keep == all.len) return all;
    const out = try gpa.alloc([]u8, keep);
    @memcpy(out, all[0..keep]);
    gpa.free(all);
    return out;
}

fn isSameOrAncestor(dir: []const u8, of: []const u8) bool {
    const d = std.mem.trimRight(u8, dir, "\\/");
    const o = std.mem.trimRight(u8, of, "\\/");
    if (d.len > o.len) return false;
    if (!std.ascii.eqlIgnoreCase(d, o[0..d.len])) return false;
    return d.len == o.len or o[d.len] == '\\' or o[d.len] == '/';
}

// ---------------------------------------------------------------------------
// Id-keyed sections (project actions and commands override global ones)

/// Merges the `actions` objects of `roots` (lowest layer first): an entry
/// of a higher layer replaces the entry with the same id whole; ids keep
/// their first position. Returns null when no root has `actions`.
pub fn mergeActions(arena: Allocator, roots: []const *const Node) Allocator.Error!?Node {
    var members: std.ArrayList(jsonc.Member) = .empty;
    var any = false;
    for (roots) |r| {
        const obj = r.get("actions") orelse continue;
        const src = switch (obj.data) {
            .object => |m| m,
            else => continue,
        };
        any = true;
        outer: for (src) |m| {
            for (members.items) |*e| {
                if (std.mem.eql(u8, e.key, m.key)) {
                    e.* = m;
                    continue :outer;
                }
            }
            try members.append(arena, m);
        }
    }
    if (!any) return null;
    return .{ .start = 0, .end = 0, .data = .{ .object = try members.toOwnedSlice(arena) } };
}

/// The identity of a `commands` entry: its "id", else its "name".
fn entryKey(n: *const Node) ?[]const u8 {
    if (n.get("id")) |v| if (v.asString()) |s| return s;
    if (n.get("name")) |v| if (v.asString()) |s| return s;
    return null;
}

/// Merges the `commands` arrays of `roots` (lowest first): an entry whose
/// id/name matches an earlier one replaces it in place; others append.
pub fn mergeCommands(arena: Allocator, roots: []const *const Node) Allocator.Error!?Node {
    var items: std.ArrayList(Node) = .empty;
    var any = false;
    for (roots) |r| {
        const arr = r.get("commands") orelse continue;
        const src = switch (arr.data) {
            .array => |a| a,
            else => continue,
        };
        any = true;
        outer: for (src) |*n| {
            if (entryKey(n)) |k| {
                for (items.items) |*e| {
                    const ek = entryKey(e) orelse continue;
                    if (std.mem.eql(u8, ek, k)) {
                        e.* = n.*;
                        continue :outer;
                    }
                }
            }
            try items.append(arena, n.*);
        }
    }
    if (!any) return null;
    return .{ .start = 0, .end = 0, .data = .{ .array = try items.toOwnedSlice(arena) } };
}

// ---------------------------------------------------------------------------
// Diffs between snapshots

pub const Change = struct {
    path: []const u8,
    /// Minified JSON of the new effective value.
    json: []const u8,
    /// The previous value's JSON (null for the first snapshot).
    old_json: ?[]const u8,
    source: Source,
    locked: bool,
};

/// The entries of `new` whose value, source or lock differ from `old`
/// (every configured entry when `old` is null). Both must resolve the
/// same spec list. Strings borrow from the snapshots.
pub fn diff(arena: Allocator, old: ?*const Resolved, new: *const Resolved) Allocator.Error![]Change {
    var out: std.ArrayList(Change) = .empty;
    for (new.entries, 0..) |*e, i| {
        if (old) |o| {
            const prev: ?*const resolve.Entry = if (i < o.entries.len and o.entries[i].spec == e.spec) &o.entries[i] else o.get(e.spec.path);
            if (prev) |p| {
                if (std.mem.eql(u8, p.json, e.json) and p.source == e.source and p.locked == e.locked) continue;
                try out.append(arena, .{ .path = e.spec.path, .json = e.json, .old_json = p.json, .source = e.source, .locked = e.locked });
                continue;
            }
        } else if (!e.configured() and !e.locked) continue;
        try out.append(arena, .{ .path = e.spec.path, .json = e.json, .old_json = null, .source = e.source, .locked = e.locked });
    }
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// The generated Ghostty overrides file (ADR-5.5)

pub const overrides_header = "# Generated by wmux from cmux.json/wmux.json settings (ADR-5.5). Do not edit:\n" ++
    "# it is rewritten on every settings reload. Unset JSON keys defer to the Ghostty config.\n";

/// `STATE\run\settings-overrides.ghostty`: one `ghostty-key = value` line
/// per explicitly set JSON setting (cmux.json, wmux.json, packs, project
/// or policy) whose spec has a `ghostty_override`, in spec order. Values
/// a Ghostty line cannot carry (newlines, objects) are skipped.
pub fn overridesText(gpa: Allocator, r: *const Resolved) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, overrides_header);
    for (r.entries) |*e| {
        const key = e.spec.ghostty_override orelse continue;
        switch (e.source) {
            .default, .ghostty => continue,
            .cmux_json, .wmux_json, .project, .policy => {},
        }
        const value: []const u8 = switch (e.value.data) {
            .boolean => |b| if (b) "true" else "false",
            .number => |n| n,
            .string => |s| s,
            else => continue,
        };
        if (std.mem.indexOfAny(u8, value, "\r\n") != null) continue;
        try out.print(gpa, "{s} = {s}\n", .{ key, value });
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Policy test file (WMUX_TEST_POLICY_FILE, test mode only)

/// Parses the JSON policy file that replaces the registry in test mode:
/// either `{"HKLM": {"<path>": <value>}, "HKCU": {...}}` or a flat
/// `{"<path>": <value>}` (= HKLM). Values are JSON literals; booleans and
/// integers may also be written as `{"dword": n}`. Strings live in `arena`.
pub fn parsePolicyFile(arena: Allocator, src: []const u8, diag: ?*jsonc.Diagnostic) (jsonc.ParseError || error{NotAnObject})![]PolicyValue {
    const root = try jsonc.parseInto(arena, src, .{}, diag);
    const top = switch (root.data) {
        .object => |m| m,
        else => return error.NotAnObject,
    };
    var out: std.ArrayList(PolicyValue) = .empty;
    var hive_form = false;
    for (top) |m| {
        if (std.ascii.eqlIgnoreCase(m.key, "HKLM") or std.ascii.eqlIgnoreCase(m.key, "HKCU")) hive_form = true;
    }
    if (hive_form) {
        for (top) |m| {
            const hive: resolve.PolicyHive = if (std.ascii.eqlIgnoreCase(m.key, "HKLM")) .hklm else if (std.ascii.eqlIgnoreCase(m.key, "HKCU")) .hkcu else continue;
            const vals = switch (m.value.data) {
                .object => |v| v,
                else => continue,
            };
            for (vals) |v| try out.append(arena, try policyValue(arena, hive, v.key, &v.value));
        }
    } else {
        for (top) |v| try out.append(arena, try policyValue(arena, .hklm, v.key, &v.value));
    }
    return out.toOwnedSlice(arena);
}

fn policyValue(arena: Allocator, hive: resolve.PolicyHive, path: []const u8, v: *const Node) Allocator.Error!PolicyValue {
    if (v.get("dword")) |d| {
        if (d.asInt()) |n| if (n >= 0 and n <= std.math.maxInt(u32))
            return .{ .path = path, .hive = hive, .data = .{ .dword = @intCast(n) } };
    }
    return .{ .path = path, .hive = hive, .data = .{ .json = try v.toJsonAlloc(arena) } };
}

/// Order-independent fingerprint of a policy value set (the watcher
/// reloads only when it changes).
pub fn policyFingerprint(values: []const PolicyValue) u64 {
    var acc: u64 = 0;
    for (values) |v| {
        var h = std.hash.Wyhash.init(0x706f6c);
        h.update(v.path);
        h.update(&.{@intFromEnum(v.hive)});
        switch (v.data) {
            .json => |j| h.update(j),
            .dword => |d| h.update(std.mem.asBytes(&d)),
        }
        acc +%= h.final();
    }
    return acc +% values.len;
}

// ---------------------------------------------------------------------------
// Notice text (ADR-5.3: the first three errors)

pub const FileError = struct {
    /// The file the error is in (full path).
    path: []const u8,
    pos: ?jsonc.Pos = null,
    message: []const u8,
};

pub const max_notice_errors = 3;

/// "wmux.json:3:5: expected ':'" lines for the first three errors, plus
/// "(and N more)" when there are more. Caller owns the result.
pub fn noticeBody(gpa: Allocator, errors: []const FileError) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (errors[0..@min(errors.len, max_notice_errors)], 0..) |e, i| {
        if (i > 0) try out.append(gpa, '\n');
        try out.appendSlice(gpa, std.fs.path.basename(e.path));
        if (e.pos) |p| try out.print(gpa, ":{d}:{d}", .{ p.line, p.col });
        try out.print(gpa, ": {s}", .{e.message});
    }
    if (errors.len > max_notice_errors) try out.print(gpa, "\n(and {d} more)", .{errors.len - max_notice_errors});
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const fixtures: []const Spec = &proto.settings.validate.test_fixture_specs;

fn parseTest(arena: Allocator, src: []const u8) !Node {
    return jsonc.parseInto(arena, src, .{}, null);
}

test "unit: settings: layer precedence table incl. explicit-vs-default legacy Ghostty keys" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Replay arguments only exist for keys the user wrote: the Ghostty
    // layer of a config that leaves window-sidebar-width at its default
    // has no such key, so the spec default (not Ghostty's) applies.
    const explicit_args = [_][]const u8{ "--window-show-sidebar=false", "--font-size=13", "--config-file=C:\\x.conf" };
    var pairs: std.ArrayList(GhosttyPair) = .empty;
    for (explicit_args) |arg| if (parseGhosttyArg(arg)) |p| try pairs.append(a, p);
    const ghostty = try resolve.ghosttyLayer(a, pairs.items);
    try testing.expect(ghostty.getDotted("wmux.sidebar.width") == null);

    const cmux = try parseTest(a, "{\"terminal\": {\"scrollSpeed\": 1.5, \"copyOnSelect\": true}, \"app\": {\"appearance\": \"light\"}, \"wmux\": {\"sidebar\": {\"visible\": true}}}");
    const wmux = try parseTest(a, "{\"terminal\": {\"copyOnSelect\": false}, \"automation\": {\"socketControlMode\": \"automation\"}}");
    const layers = try planLayers(a, &.{
        .{ .source = .cmux_json, .root = &cmux },
        .{ .source = .wmux_json, .root = &wmux },
    });
    const all_layers = try std.mem.concat(a, Layer, &.{ layers, &.{.{ .source = .ghostty, .root = &ghostty }} });
    var r = try resolve.resolve(testing.allocator, fixtures, all_layers, &.{
        .{ .path = "automation.socketControlMode", .hive = .hklm, .data = .{ .json = "\"allowAll\"" } },
    });
    defer r.deinit();

    const Row = struct { path: []const u8, json: []const u8, source: Source };
    const table = [_]Row{
        // default: nobody set it (and Ghostty's own default never counts)
        .{ .path = "wmux.sidebar.width", .json = "220", .source = .default },
        .{ .path = "app.minimalMode", .json = "false", .source = .default },
        // cmux.json beats an explicit legacy Ghostty key
        .{ .path = "wmux.sidebar.visible", .json = "true", .source = .cmux_json },
        .{ .path = "terminal.scrollSpeed", .json = "1.5", .source = .cmux_json },
        .{ .path = "app.appearance", .json = "\"light\"", .source = .cmux_json },
        // wmux.json beats cmux.json
        .{ .path = "terminal.copyOnSelect", .json = "false", .source = .wmux_json },
        // policy beats both
        .{ .path = "automation.socketControlMode", .json = "\"allowAll\"", .source = .policy },
    };
    for (table) |row| {
        const e = r.get(row.path).?;
        try testing.expectEqualStrings(row.json, e.json);
        try testing.expectEqual(row.source, e.source);
    }
    try testing.expect(r.isLocked("automation.socketControlMode"));

    // Without cmux.json the explicit Ghostty key is the source.
    var g = try resolve.resolve(testing.allocator, fixtures, &.{.{ .source = .ghostty, .root = &ghostty }}, &.{});
    defer g.deinit();
    try testing.expectEqualStrings("false", g.get("wmux.sidebar.visible").?.json);
    try testing.expectEqual(Source.ghostty, g.get("wmux.sidebar.visible").?.source);
}

test "unit: settings: ghostty replay arguments become pairs" {
    const p = parseGhosttyArg("--window-sidebar-width=300").?;
    try testing.expectEqualStrings("window-sidebar-width", p.key);
    try testing.expectEqualStrings("300", p.value);
    const q = parseGhosttyArg("socket-control = read-only").?;
    try testing.expectEqualStrings("socket-control", q.key);
    try testing.expectEqualStrings("read-only", q.value);
    try testing.expectEqualStrings("true", parseGhosttyArg("--window-show-sidebar").?.value);
    try testing.expectEqualStrings("", parseGhosttyArg("--window-show-sidebar=").?.value);
    try testing.expect(parseGhosttyArg("-e") == null);
    try testing.expect(parseGhosttyArg("") == null);
    try testing.expect(parseGhosttyArg("--=x") == null);
}

test "unit: settings: pack resolution order" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cmux_pack = try parseTest(a, "{\"app\": {\"appearance\": \"dark\", \"paneResizeStepPixels\": 5}}");
    const cmux = try parseTest(a, "{\"app\": {\"appearance\": \"light\"}}");
    const wmux_pack_a = try parseTest(a, "{\"terminal\": {\"scrollSpeed\": 2}, \"app\": {\"paneResizeStepPixels\": 7}}");
    const wmux_pack_b = try parseTest(a, "{\"terminal\": {\"scrollSpeed\": 2.5}}");
    const wmux = try parseTest(a, "{\"packs\": [\"a\", {\"path\": \"b\"}]}");

    const layers = try planLayers(a, &.{
        .{ .source = .wmux_json, .root = &wmux, .packs = &.{ .{ .root = &wmux_pack_a }, .{ .root = &wmux_pack_b } } },
        .{ .source = .cmux_json, .root = &cmux, .packs = &.{.{ .root = &cmux_pack }} },
    });
    try testing.expectEqual(@as(usize, 5), layers.len);
    // Packs come before the file that lists them.
    try testing.expectEqual(&wmux_pack_a, layers[0].root);
    try testing.expectEqual(&wmux_pack_b, layers[1].root);
    try testing.expectEqual(&wmux, layers[2].root);
    try testing.expectEqual(&cmux_pack, layers[3].root);

    var r = try resolve.resolve(testing.allocator, fixtures, layers, &.{});
    defer r.deinit();
    // The listing file beats its pack.
    try testing.expectEqualStrings("\"light\"", r.get("app.appearance").?.json);
    // A later pack beats an earlier one.
    try testing.expectEqualStrings("2.5", r.get("terminal.scrollSpeed").?.json);
    // A wmux.json pack beats cmux.json and its packs.
    try testing.expectEqualStrings("7", r.get("app.paneResizeStepPixels").?.json);
    try testing.expectEqual(Source.wmux_json, r.get("app.paneResizeStepPixels").?.source);

    const entries = try packEntries(a, &wmux);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("a", entries[0].path);
    try testing.expectEqualStrings("b", entries[1].path);
    const bad_root = try parseTest(a, "{\"packs\": [\"https://example.invalid/p\", \"\", 3, {\"x\": 1}, \" ./ok \"]}");
    const bad = try packEntries(a, &bad_root);
    try testing.expect(bad[0] == .bad);
    try testing.expect(bad[1] == .bad);
    try testing.expect(bad[2] == .bad);
    try testing.expect(bad[3] == .bad);
    try testing.expectEqualStrings("./ok", bad[4].path);
    const not_array = try parseTest(a, "{\"packs\": \"x\"}");
    try testing.expect((try packEntries(a, &not_array))[0] == .bad);
    const none = try parseTest(a, "{}");
    try testing.expectEqual(@as(usize, 0), (try packEntries(a, &none)).len);
}

test "unit: settings: project-scoped key filtering and id-keyed overrides" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const global = try parseTest(a,
        \\{"app": {"minimalMode": false}, "notifications": {"hooks": {"g": 1}},
        \\ "actions": {"build": {"type": "command", "command": "make"}, "test": {"type": "command", "command": "t"}},
        \\ "commands": [{"name": "dev", "command": "a"}, {"name": "lint", "command": "l"}]}
    );
    const project = try parseTest(a,
        \\{"app": {"minimalMode": true}, "notifications": {"hooks": {"p": 2}},
        \\ "actions": {"build": {"type": "command", "command": "zig build"}, "run": {"type": "command", "command": "r"}},
        \\ "commands": [{"name": "dev", "command": "b"}, {"id": "x", "command": "c"}]}
    );
    var r = try resolve.resolve(testing.allocator, fixtures, &.{
        .{ .source = .wmux_json, .root = &global },
        .{ .source = .project, .root = &project },
    }, &.{});
    defer r.deinit();
    // A global-only key in a project file is ignored (and reported).
    try testing.expectEqualStrings("false", r.get("app.minimalMode").?.json);
    try testing.expectEqual(Source.wmux_json, r.get("app.minimalMode").?.source);
    try testing.expectEqual(@as(usize, 1), r.rejected.len);
    try testing.expectEqualStrings("app.minimalMode", r.rejected[0].path);
    // A project-scoped key merges over the global one.
    try testing.expectEqualStrings("{\"g\":1,\"p\":2}", r.get("notifications.hooks").?.json);
    try testing.expectEqual(Source.project, r.get("notifications.hooks").?.source);

    const actions = (try mergeActions(a, &.{ &global, &project })).?;
    try testing.expectEqualStrings(
        "{\"build\":{\"type\":\"command\",\"command\":\"zig build\"},\"test\":{\"type\":\"command\",\"command\":\"t\"},\"run\":{\"type\":\"command\",\"command\":\"r\"}}",
        try actions.toJsonAlloc(a),
    );
    const commands = (try mergeCommands(a, &.{ &global, &project })).?;
    try testing.expectEqualStrings(
        "[{\"name\":\"dev\",\"command\":\"b\"},{\"name\":\"lint\",\"command\":\"l\"},{\"id\":\"x\",\"command\":\"c\"}]",
        try commands.toJsonAlloc(a),
    );
    const empty = try parseTest(a, "{}");
    try testing.expect((try mergeActions(a, &.{&empty})) == null);
    try testing.expect((try mergeCommands(a, &.{&empty})) == null);
}

test "unit: settings: project candidates stop below the home directory" {
    const gpa = testing.allocator;
    const c = try projectCandidates(gpa, "C:\\Users\\me\\src\\app", "C:\\Users\\me");
    defer resolve.freePaths(gpa, c);
    try testing.expectEqual(@as(usize, 8), c.len);
    try testing.expectEqualStrings("C:\\Users\\me\\src\\app\\.wmux\\wmux.json", c[0]);
    try testing.expectEqualStrings("C:\\Users\\me\\src\\cmux.json", c[7]);
    const outside = try projectCandidates(gpa, "D:\\work", "C:\\Users\\me");
    defer resolve.freePaths(gpa, outside);
    try testing.expectEqual(@as(usize, 8), outside.len);
    const at_home = try projectCandidates(gpa, "C:\\Users\\me", "C:\\Users\\me\\");
    defer resolve.freePaths(gpa, at_home);
    try testing.expectEqual(@as(usize, 0), at_home.len);
    try testing.expect(isSameOrAncestor("C:\\Users", "C:\\Users\\me"));
    try testing.expect(!isSameOrAncestor("C:\\Use", "C:\\Users\\me"));
}

test "unit: settings: policy lock wins" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const policy = try parsePolicyFile(a,
        \\// test policy
        \\{"HKLM": {"automation.socketControlMode": "allowAll", "app.paneResizeStepPixels": {"dword": 40}},
        \\ "HKCU": {"automation.socketControlMode": "off", "app.minimalMode": true}}
    , null);
    try testing.expectEqual(@as(usize, 4), policy.len);
    const flat = try parsePolicyFile(a, "{\"terminal.copyOnSelect\": true}", null);
    try testing.expectEqual(resolve.PolicyHive.hklm, flat[0].hive);
    try testing.expectError(error.NotAnObject, parsePolicyFile(a, "[1]", null));
    var d: jsonc.Diagnostic = .{};
    try testing.expectError(error.SyntaxError, parsePolicyFile(a, "{\"a\": }", &d));
    try testing.expectEqual(@as(u32, 1), d.pos.line);

    const cmux = try parseTest(a, "{\"automation\": {\"socketControlMode\": \"readOnly\"}, \"app\": {\"minimalMode\": false}}");
    const wmux = try parseTest(a, "{\"automation\": {\"socketControlMode\": \"automation\"}, \"app\": {\"paneResizeStepPixels\": 30}}");
    var r = try resolve.resolve(testing.allocator, fixtures, &.{
        .{ .source = .cmux_json, .root = &cmux },
        .{ .source = .wmux_json, .root = &wmux },
    }, policy);
    defer r.deinit();
    // HKLM beats HKCU, and policy beats every file.
    try testing.expectEqualStrings("\"allowAll\"", r.get("automation.socketControlMode").?.json);
    try testing.expectEqual(Source.policy, r.get("automation.socketControlMode").?.source);
    try testing.expectEqualStrings("40", r.get("app.paneResizeStepPixels").?.json);
    try testing.expectEqualStrings("true", r.get("app.minimalMode").?.json);
    try testing.expect(r.isLocked("app.minimalMode"));

    // Fingerprints ignore order and see value changes.
    const swapped = [_]PolicyValue{ policy[1], policy[0], policy[2], policy[3] };
    try testing.expectEqual(policyFingerprint(policy), policyFingerprint(&swapped));
    try testing.expect(policyFingerprint(policy) != policyFingerprint(policy[0..3]));
}

test "unit: settings: diffs list changed values, sources and locks" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v1 = try parseTest(a, "{\"app\": {\"appearance\": \"dark\"}}");
    const v2 = try parseTest(a, "{\"app\": {\"appearance\": \"dark\", \"minimalMode\": true}}");
    var r1 = try resolve.resolve(testing.allocator, fixtures, &.{.{ .source = .wmux_json, .root = &v1 }}, &.{});
    defer r1.deinit();
    var r2 = try resolve.resolve(testing.allocator, fixtures, &.{.{ .source = .cmux_json, .root = &v2 }}, &.{});
    defer r2.deinit();

    const first = try diff(a, null, &r1);
    try testing.expectEqual(@as(usize, 1), first.len);
    try testing.expectEqualStrings("app.appearance", first[0].path);
    try testing.expect(first[0].old_json == null);

    const d = try diff(a, &r1, &r2);
    try testing.expectEqual(@as(usize, 2), d.len);
    try testing.expectEqualStrings("app.appearance", d[0].path); // same value, new source
    try testing.expectEqual(Source.cmux_json, d[0].source);
    try testing.expectEqualStrings("app.minimalMode", d[1].path);
    try testing.expectEqualStrings("false", d[1].old_json.?);
    try testing.expectEqualStrings("true", d[1].json);
    try testing.expectEqual(@as(usize, 0), (try diff(a, &r2, &r2)).len);
}

test "unit: settings: ghostty overrides file lists explicitly set keys" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const specs = comptime withInterim(&.{}, &interim_specs);
    try testing.expectEqual(interim_specs.len, specs.len);

    var none = try resolve.resolve(testing.allocator, specs, &.{}, &.{});
    defer none.deinit();
    const empty = try overridesText(testing.allocator, &none);
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings(overrides_header, empty);

    const wmux = try parseTest(a, "{\"terminal\": {\"copyOnSelect\": true}}");
    var r = try resolve.resolve(testing.allocator, specs, &.{.{ .source = .wmux_json, .root = &wmux }}, &.{
        .{ .path = "terminal.confirmUnsafePaste", .hive = .hklm, .data = .{ .dword = 0 } },
    });
    defer r.deinit();
    const text = try overridesText(testing.allocator, &r);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(overrides_header ++ "copy-on-select = true\nclipboard-paste-protection = false\n", text);
}

test "unit: settings: interim specs yield to registered ones" {
    const registered = [_]Spec{
        .{ .path = "terminal.copyOnSelect", .ty = .boolean, .default = "true", .section = "terminal", .label = "Copy", .doc = "" },
        .{ .path = "automation", .ty = .object, .default = "{}", .section = "automation", .label = "Automation", .doc = "" },
    };
    const specs = comptime withInterim(&registered, &interim_specs);
    // copyOnSelect is registered; automation is a setting, so its interim
    // child is dropped; confirmUnsafePaste stays.
    try testing.expectEqual(@as(usize, 3), specs.len);
    try testing.expectEqualStrings("true", specs[0].default);
    try testing.expectEqualStrings("terminal.confirmUnsafePaste", specs[2].path);
    try testing.expect(effective_specs.len >= manifest.all.len);
}

test "unit: settings: notice body shows the first three errors" {
    const gpa = testing.allocator;
    const errs = [_]FileError{
        .{ .path = "C:\\cfg\\wmux.json", .pos = .{ .line = 3, .col = 5 }, .message = "expected ':'" },
        .{ .path = "C:\\cfg\\cmux.json", .message = "unreadable" },
        .{ .path = "p.json", .pos = .{ .line = 1, .col = 1 }, .message = "a" },
        .{ .path = "q.json", .pos = .{ .line = 2, .col = 2 }, .message = "b" },
    };
    const body = try noticeBody(gpa, &errs);
    defer gpa.free(body);
    try testing.expectEqualStrings("wmux.json:3:5: expected ':'\ncmux.json: unreadable\np.json:1:1: a\n(and 1 more)", body);
}
