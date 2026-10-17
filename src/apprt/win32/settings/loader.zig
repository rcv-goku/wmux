//! Reads and resolves the settings files into a `Snapshot` (ARCHITECTURE.md
//! ADR-5.1, 5.3): cmux.json, wmux.json, the packs each lists, the project
//! file found upward from a directory, the legacy Ghostty layer and the
//! policy values. Blocking file I/O: called by the watcher thread, and
//! once on the UI thread at startup (like Ghostty's own config load).
//! No App access, so tests drive it with temporary directories.
//!
//! A JSONC syntax error in any file fails the whole load (the caller keeps
//! the last good snapshot and shows the first three errors); type and range
//! errors only make the key fall back to the next lower layer
//! (`resolve.Resolved.rejected`).

const std = @import("std");
const proto = @import("wmux_proto");

const layers = @import("logic/layers.zig");
const debounce = @import("logic/debounce.zig");
const snapshot = @import("snapshot.zig");

const Allocator = std.mem.Allocator;
const jsonc = proto.jsonc;
const resolve = proto.settings.resolve;
const validate = proto.settings.validate;
const Node = jsonc.Node;
const Snapshot = snapshot.Snapshot;
const FileRecord = snapshot.FileRecord;
const FileError = layers.FileError;

/// Largest settings file read (larger files are an error).
pub const max_file_bytes = 8 * 1024 * 1024;

pub const Inputs = struct {
    /// `%XDG_CONFIG_HOME%\cmux\cmux.json` or `~\.config\cmux\cmux.json`.
    cmux_path: ?[]const u8 = null,
    /// `CONFIG\wmux.json`.
    wmux_path: ?[]const u8 = null,
    /// Where the project file search starts (null: no project layer).
    project_cwd: ?[]const u8 = null,
    /// The search stops below this directory (the user's home).
    home: ?[]const u8 = null,
    /// Explicitly set Ghostty keys (legacy layer).
    ghostty_pairs: []const layers.GhosttyPair = &.{},
    /// Managed policy values (registry, or the test policy file).
    policy: []const layers.PolicyValue = &.{},
    /// The test policy file, recorded so the watcher watches it.
    policy_file: ?[]const u8 = null,
    /// The spec list (tests pass fixtures).
    specs: []const proto.settings.spec.Spec = layers.effective_specs,
};

pub const Failure = struct {
    arena: std.heap.ArenaAllocator,
    errors: []const FileError,
    /// Every file looked at, with its hash, so the watcher keeps watching
    /// and does not reload until one of them changes again.
    files: []const FileRecord,

    pub fn deinit(self: *Failure) void {
        self.arena.deinit();
    }
};

pub const Outcome = union(enum) {
    ok: *Snapshot,
    failed: Failure,
};

/// One read and parsed file.
const Parsed = struct {
    path: []const u8,
    src: []const u8,
    root: Node,
};

const Loader = struct {
    gpa: Allocator,
    arena: Allocator,
    errors: std.ArrayList(FileError) = .empty,
    warnings: std.ArrayList(FileError) = .empty,
    files: std.ArrayList(FileRecord) = .empty,

    /// Reads `path`; null when it does not exist. Read failures become
    /// errors (the load fails, as for a syntax error).
    fn read(self: *Loader, kind: FileRecord.Kind, path: []const u8) Allocator.Error!?[]const u8 {
        const bytes = std.fs.cwd().readFileAlloc(self.arena, path, max_file_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound, error.NotDir => {
                try self.files.append(self.arena, .{ .kind = kind, .path = path, .hash = null });
                return null;
            },
            else => {
                try self.files.append(self.arena, .{ .kind = kind, .path = path, .hash = null });
                try self.errors.append(self.arena, .{ .path = path, .message = try std.fmt.allocPrint(self.arena, "cannot read the file ({s})", .{@errorName(err)}) });
                return null;
            },
        };
        try self.files.append(self.arena, .{ .kind = kind, .path = path, .hash = debounce.contentHash(bytes) });
        return bytes;
    }

    /// Reads and parses `path`; null when missing or broken (recorded).
    fn parse(self: *Loader, kind: FileRecord.Kind, path: []const u8) Allocator.Error!?Parsed {
        const src = try self.read(kind, path) orelse return null;
        var diag: jsonc.Diagnostic = .{};
        const root = jsonc.parseInto(self.arena, src, .{}, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SyntaxError => {
                try self.errors.append(self.arena, .{ .path = path, .pos = diag.pos, .message = diag.message });
                return null;
            },
        };
        if (root.data != .object) {
            try self.errors.append(self.arena, .{ .path = path, .pos = jsonc.position(src, root.start), .message = "the settings file must be a JSON object" });
            return null;
        }
        if (root.get("schemaVersion")) |v| {
            if (v.asInt()) |n| if (n > validate.current_schema_version) {
                try self.warnings.append(self.arena, .{
                    .path = path,
                    .pos = jsonc.position(src, v.start),
                    .message = try std.fmt.allocPrint(self.arena, "schemaVersion {d} is newer than {d}; parsed best effort", .{ n, validate.current_schema_version }),
                });
            };
        }
        return .{ .path = path, .src = src, .root = root };
    }

    /// The packs `file` lists, parsed, in listed order. A missing pack or
    /// a bad entry is a warning; a broken pack fails the load.
    fn packs(self: *Loader, file: *const Parsed) Allocator.Error![]layers.InputFile.Pack {
        const entries = try layers.packEntries(self.arena, &file.root);
        var out: std.ArrayList(layers.InputFile.Pack) = .empty;
        const dir = std.fs.path.dirname(file.path) orelse ".";
        for (entries) |e| switch (e) {
            .bad => |b| try self.warnings.append(self.arena, .{ .path = file.path, .pos = jsonc.position(file.src, b.offset), .message = b.message }),
            .path => |p| {
                const pp = resolve.packPaths(self.arena, dir, p) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.RemotePack, error.EmptyPack => continue, // filtered by packEntries
                };
                const target = pick: {
                    if (isFile(pp.file)) break :pick pp.file;
                    for (pp.dir_candidates) |c| if (isFile(c)) break :pick c;
                    try self.files.append(self.arena, .{ .kind = .pack, .path = pp.file, .hash = null });
                    try self.warnings.append(self.arena, .{
                        .path = file.path,
                        .message = try std.fmt.allocPrint(self.arena, "pack not found: {s}", .{p}),
                    });
                    continue;
                };
                const parsed = try self.parse(.pack, target) orelse continue;
                const root = try self.arena.create(Node);
                root.* = parsed.root;
                try out.append(self.arena, .{ .root = root, .src = parsed.src });
            },
        };
        return out.toOwnedSlice(self.arena);
    }
};

fn isFile(path: []const u8) bool {
    const st = std.fs.cwd().statFile(path) catch return false;
    return st.kind == .file;
}

/// The first existing project file for `cwd` (see layers.projectCandidates).
pub fn findProjectFile(gpa: Allocator, cwd: []const u8, home: ?[]const u8) Allocator.Error!?[]u8 {
    const candidates = try layers.projectCandidates(gpa, cwd, home);
    defer resolve.freePaths(gpa, candidates);
    for (candidates) |c| {
        if (isFile(c)) return try gpa.dupe(u8, c);
    }
    return null;
}

/// Reads every settings file of `in` and resolves them.
pub fn load(gpa: Allocator, in: Inputs) Allocator.Error!Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    var arena_owned = true;
    defer if (arena_owned) arena_state.deinit();
    var l: Loader = .{ .gpa = gpa, .arena = arena_state.allocator() };
    const a = l.arena;

    var inputs: std.ArrayList(layers.InputFile) = .empty;
    var roots: std.ArrayList(*const Node) = .empty;

    const Global = struct { kind: FileRecord.Kind, source: layers.Source, path: ?[]const u8 };
    var project_path: ?[]const u8 = null;
    if (in.project_cwd) |cwd| {
        if (try findProjectFile(a, cwd, in.home)) |p| {
            // A global file found upward (e.g. CONFIG lives under the cwd)
            // is not also a project file.
            const same_cmux = if (in.cmux_path) |c| std.ascii.eqlIgnoreCase(c, p) else false;
            const same_wmux = if (in.wmux_path) |w| std.ascii.eqlIgnoreCase(w, p) else false;
            if (!same_cmux and !same_wmux) project_path = p;
        }
    }
    const files = [_]Global{
        .{ .kind = .cmux_json, .source = .cmux_json, .path = in.cmux_path },
        .{ .kind = .wmux_json, .source = .wmux_json, .path = in.wmux_path },
        .{ .kind = .project, .source = .project, .path = project_path },
    };
    for (files) |f| {
        const path = f.path orelse continue;
        const parsed = try l.parse(f.kind, path) orelse continue;
        const root = try a.create(Node);
        root.* = parsed.root;
        const pk = try l.packs(&parsed);
        try inputs.append(a, .{ .source = f.source, .root = root, .src = parsed.src, .packs = pk });
        for (pk) |p| try roots.append(a, p.root);
        try roots.append(a, root);
    }
    if (in.policy_file) |p| try l.files.append(a, .{ .kind = .policy_file, .path = p, .hash = null });

    if (l.errors.items.len > 0) {
        arena_owned = false;
        return .{ .failed = .{
            .arena = arena_state,
            .errors = l.errors.items,
            .files = l.files.items,
        } };
    }

    var plan = try layers.planLayers(a, inputs.items);
    if (in.ghostty_pairs.len > 0) {
        const groot = try a.create(Node);
        groot.* = try resolve.ghosttyLayer(a, in.ghostty_pairs);
        plan = try std.mem.concat(a, layers.Layer, &.{ &.{.{ .source = .ghostty, .root = groot }}, plan });
    }
    var resolved = try resolve.resolve(gpa, in.specs, plan, in.policy);
    const snap = Snapshot.create(gpa, resolved) catch |err| {
        resolved.deinit();
        return err;
    };
    errdefer snap.release();
    const sa = snap.allocator();

    // Copy what outlives the parse arena into the snapshot.
    const recs = try sa.alloc(FileRecord, l.files.items.len);
    for (l.files.items, recs) |f, *r| r.* = .{ .kind = f.kind, .path = try sa.dupe(u8, f.path), .hash = f.hash };
    snap.files = recs;
    const warns = try sa.alloc(FileError, l.warnings.items.len);
    for (l.warnings.items, warns) |w, *o| o.* = .{ .path = try sa.dupe(u8, w.path), .pos = w.pos, .message = try sa.dupe(u8, w.message) };
    snap.warnings = warns;
    if (try layers.mergeActions(a, roots.items)) |n| snap.actions_json = try n.toJsonAlloc(sa);
    if (try layers.mergeCommands(a, roots.items)) |n| snap.commands_json = try n.toJsonAlloc(sa);
    snap.ghostty_overrides = try layers.overridesText(sa, &snap.resolved);
    return .{ .ok = snap };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const fixtures: []const proto.settings.spec.Spec = &validate.test_fixture_specs;

fn writeFile(dir: std.fs.Dir, sub: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub)) |d| try dir.makePath(d);
    try dir.writeFile(.{ .sub_path = sub, .data = data });
}

test "unit: settings: loader layers cmux.json, wmux.json, packs and the project file" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);

    try writeFile(tmp.dir, "xdg/cmux/cmux.json", "{\"app\": {\"appearance\": \"light\"}, \"terminal\": {\"scrollSpeed\": 1.5}}");
    try writeFile(tmp.dir, "cfg/wmux.json",
        \\// wmux
        \\{"packs": ["packs/team", "missing"], "app": {"appearance": "dark"},
        \\ "actions": {"a": {"type": "command", "command": "x"}}, "schemaVersion": 9,}
    );
    try writeFile(tmp.dir, "cfg/packs/team/wmux.pack.json", "{\"terminal\": {\"scrollSpeed\": 2}, \"app\": {\"appearance\": \"system\"}, \"actions\": {\"p\": {\"type\": \"command\", \"command\": \"p\"}}}");
    try writeFile(tmp.dir, "home/proj/.wmux/wmux.json", "{\"notifications\": {\"hooks\": {\"k\": 1}}, \"app\": {\"minimalMode\": true}, \"actions\": {\"a\": {\"type\": \"command\", \"command\": \"y\"}}}");
    try tmp.dir.makePath("home/proj/sub");

    const cmux_path = try std.fs.path.join(gpa, &.{ root, "xdg", "cmux", "cmux.json" });
    defer gpa.free(cmux_path);
    const wmux_path = try std.fs.path.join(gpa, &.{ root, "cfg", "wmux.json" });
    defer gpa.free(wmux_path);
    const cwd = try std.fs.path.join(gpa, &.{ root, "home", "proj", "sub" });
    defer gpa.free(cwd);
    const home = try std.fs.path.join(gpa, &.{ root, "home" });
    defer gpa.free(home);

    const out = try load(gpa, .{
        .cmux_path = cmux_path,
        .wmux_path = wmux_path,
        .project_cwd = cwd,
        .home = home,
        .ghostty_pairs = &.{.{ .key = "window-sidebar-width", .value = "300" }},
        .policy = &.{.{ .path = "terminal.copyOnSelect", .hive = .hklm, .data = .{ .dword = 1 } }},
        .specs = fixtures,
    });
    const snap = out.ok;
    defer snap.release();
    try testing.expectEqualStrings("\"dark\"", snap.get("app.appearance").?.json);
    try testing.expectEqual(layers.Source.wmux_json, snap.get("app.appearance").?.source);
    // The wmux.json pack beats cmux.json.
    try testing.expectEqualStrings("2", snap.get("terminal.scrollSpeed").?.json);
    try testing.expectEqualStrings("300", snap.get("wmux.sidebar.width").?.json);
    try testing.expectEqual(layers.Source.ghostty, snap.get("wmux.sidebar.width").?.source);
    try testing.expectEqualStrings("{\"k\":1}", snap.get("notifications.hooks").?.json);
    try testing.expectEqual(layers.Source.project, snap.get("notifications.hooks").?.source);
    try testing.expectEqualStrings("false", snap.get("app.minimalMode").?.json); // global-only
    try testing.expectEqual(layers.Source.policy, snap.get("terminal.copyOnSelect").?.source);
    try testing.expectEqualStrings(layers.overrides_header ++ "copy-on-select = true\n", snap.ghostty_overrides);
    // Pack entries come first (packs load before their file); the file wins per id.
    try testing.expectEqualStrings("{\"p\":{\"type\":\"command\",\"command\":\"p\"},\"a\":{\"type\":\"command\",\"command\":\"y\"}}", snap.actions_json.?);
    // Warnings: missing pack and newer schemaVersion.
    try testing.expectEqual(@as(usize, 2), snap.warnings.len);
    // Every file the watcher must watch is recorded.
    var kinds: [5]usize = @splat(0);
    for (snap.files) |f| kinds[@intFromEnum(f.kind)] += 1;
    try testing.expectEqual(@as(usize, 1), kinds[@intFromEnum(FileRecord.Kind.cmux_json)]);
    try testing.expectEqual(@as(usize, 1), kinds[@intFromEnum(FileRecord.Kind.wmux_json)]);
    try testing.expectEqual(@as(usize, 2), kinds[@intFromEnum(FileRecord.Kind.pack)]);
    try testing.expectEqual(@as(usize, 1), kinds[@intFromEnum(FileRecord.Kind.project)]);
}

test "unit: settings: loader reports JSONC syntax errors with line and column" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);
    try writeFile(tmp.dir, "wmux.json", "{\n  \"app\": {\"appearance\": \"dark\"\n  \"x\": 1\n}\n");
    const wmux_path = try std.fs.path.join(gpa, &.{ root, "wmux.json" });
    defer gpa.free(wmux_path);
    const missing = try std.fs.path.join(gpa, &.{ root, "nope", "cmux.json" });
    defer gpa.free(missing);

    var out = try load(gpa, .{ .cmux_path = missing, .wmux_path = wmux_path, .specs = fixtures });
    defer out.failed.deinit();
    try testing.expectEqual(@as(usize, 1), out.failed.errors.len);
    try testing.expectEqual(jsonc.Pos{ .line = 3, .col = 3 }, out.failed.errors[0].pos.?);
    try testing.expectEqual(@as(usize, 2), out.failed.files.len);

    // Missing files are simply absent layers.
    var ok = try load(gpa, .{ .cmux_path = missing, .specs = fixtures });
    defer ok.ok.release();
    try testing.expectEqual(layers.Source.default, ok.ok.get("app.appearance").?.source);
}
