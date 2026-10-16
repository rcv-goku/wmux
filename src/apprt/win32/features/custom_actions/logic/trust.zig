//! Project action trust (persistence-project-action-trust): fingerprints of
//! project-local actions and commands, the trusted-actions.json store, the
//! projects.json store of path + content-hash approvals (ADR-6.7), the
//! run-or-prompt decision and the "Trust and Run" prompt model.
//!
//! A fingerprint is the SHA-256 (lowercase hex) of the sorted-keys JSON
//! descriptor {schemaVersion, actionID, kind, command, target,
//! workspaceCommand, configPath, projectRoot, iconFingerprint}; every key is
//! always present (null when it does not apply). Any edit to what runs, a
//! move to another project root or config file, or an icon change gives a
//! new fingerprint and re-prompts. Global and built-in actions are trusted.
//!
//! Pure: file I/O and atomic replace stay on the app side.

const std = @import("std");
const proto = @import("wmux_proto");
const actions = @import("actions.zig");

const jsonc = proto.jsonc;
const paths = proto.paths;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const schema_version: u32 = 1;

pub const trust_button = "Trust and Run";
pub const cancel_button = "Cancel";

pub const Fingerprint = [Sha256.digest_length * 2]u8;

pub fn sha256Hex(data: []const u8) Fingerprint {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn isFingerprint(s: []const u8) bool {
    if (s.len != @sizeOf(Fingerprint)) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

pub const Descriptor = struct {
    actionID: []const u8,
    kind: []const u8,
    command: ?[]const u8 = null,
    target: ?[]const u8 = null,
    workspaceCommand: ?[]const u8 = null,
    configPath: ?[]const u8 = null,
    projectRoot: ?[]const u8 = null,
    iconFingerprint: ?[]const u8 = null,
};

/// The canonical descriptor text: minified, keys in byte order.
pub fn canonicalJsonAlloc(gpa: Allocator, d: Descriptor) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    writeDescriptor(&jw, d) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeDescriptor(jw: *std.json.Stringify, d: Descriptor) std.Io.Writer.Error!void {
    // Byte order: actionID < command < configPath < iconFingerprint < kind
    // < projectRoot < schemaVersion < target < workspaceCommand.
    try jw.beginObject();
    try jw.objectField("actionID");
    try jw.write(d.actionID);
    try jw.objectField("command");
    try jw.write(d.command);
    try jw.objectField("configPath");
    try jw.write(d.configPath);
    try jw.objectField("iconFingerprint");
    try jw.write(d.iconFingerprint);
    try jw.objectField("kind");
    try jw.write(d.kind);
    try jw.objectField("projectRoot");
    try jw.write(d.projectRoot);
    try jw.objectField("schemaVersion");
    try jw.write(schema_version);
    try jw.objectField("target");
    try jw.write(d.target);
    try jw.objectField("workspaceCommand");
    try jw.write(d.workspaceCommand);
    try jw.endObject();
}

pub fn fingerprint(gpa: Allocator, d: Descriptor) Allocator.Error!Fingerprint {
    const text = try canonicalJsonAlloc(gpa, d);
    defer gpa.free(text);
    return sha256Hex(text);
}

/// JSON of a node with object keys sorted (recursively) and comments and
/// whitespace dropped, so reformatting a definition keeps its fingerprint.
pub fn canonicalNodeAlloc(gpa: Allocator, node: *const jsonc.Node) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    writeSorted(gpa, &jw, node) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.OutOfMemory,
    };
    return aw.toOwnedSlice();
}

fn memberLess(_: void, a: jsonc.Member, b: jsonc.Member) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

fn writeSorted(gpa: Allocator, jw: *std.json.Stringify, node: *const jsonc.Node) (Allocator.Error || std.Io.Writer.Error)!void {
    switch (node.data) {
        .null => try jw.write(null),
        .boolean => |b| try jw.write(b),
        .number => |n| {
            // Normalize spelling (1.0 vs 1) when the value is an exact integer.
            const f = node.asFloat();
            if (f != null and @floor(f.?) == f.? and @abs(f.?) < 1e15) {
                try jw.print("{d}", .{@as(i64, @intFromFloat(f.?))});
            } else try jw.print("{s}", .{n});
        },
        .string => |s| try jw.write(s),
        .array => |items| {
            try jw.beginArray();
            for (items) |*it| try writeSorted(gpa, jw, it);
            try jw.endArray();
        },
        .object => |members| {
            // Last duplicate wins, as in getMember; then sort.
            var list: std.ArrayList(jsonc.Member) = .empty;
            defer list.deinit(gpa);
            outer: for (members, 0..) |m, i| {
                for (members[i + 1 ..]) |later| {
                    if (std.mem.eql(u8, later.key, m.key)) continue :outer;
                }
                try list.append(gpa, m);
            }
            std.mem.sort(jsonc.Member, list.items, {}, memberLess);
            try jw.beginObject();
            for (list.items) |*m| {
                try jw.objectField(m.key);
                try writeSorted(gpa, jw, &m.value);
            }
            try jw.endObject();
        },
    }
}

/// Fingerprint of an icon: symbol name, emoji value and scale, or image
/// path plus the image bytes (`image_bytes` null = file unreadable).
pub fn iconFingerprint(gpa: Allocator, icon: actions.Icon, image_bytes: ?[]const u8) Allocator.Error!Fingerprint {
    var h = Sha256.init(.{});
    switch (icon) {
        .symbol => |n| {
            h.update("symbol\x00");
            h.update(n);
        },
        .emoji => |e| {
            const text = try std.fmt.allocPrint(gpa, "emoji\x00{s}\x00{d}", .{ e.value, e.scale });
            defer gpa.free(text);
            h.update(text);
        },
        .image => |p| {
            h.update("image\x00");
            h.update(p);
            if (image_bytes) |b| {
                h.update("\x00");
                h.update(b);
            } else h.update("\x01missing");
        },
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub const DescriptorOptions = struct {
    /// Bytes of the action's image icon file, when it has one.
    icon_bytes: ?[]const u8 = null,
};

/// Builds the descriptor of an action. For workspaceCommand actions the
/// referenced command's definition is part of `command`, so editing that
/// entry re-prompts too.
pub fn descriptorForAction(arena: Allocator, reg: *const actions.Registry, a: *const actions.Action, opts: DescriptorOptions) Allocator.Error!Descriptor {
    var d: Descriptor = .{
        .actionID = a.id,
        .kind = @tagName(a.kind()),
        .configPath = a.config_path,
        .projectRoot = a.project_root,
    };
    if (a.icon) |ic| d.iconFingerprint = try arena.dupe(u8, &(try iconFingerprint(arena, ic, opts.icon_bytes)));
    switch (a.body) {
        .builtin => |b| d.command = b,
        .command => |c| {
            d.command = c.command;
            d.target = @tagName(c.target);
        },
        .agent => |ag| {
            var aw: std.Io.Writer.Allocating = .init(arena);
            var jw: std.json.Stringify = .{ .writer = &aw.writer };
            jw.beginArray() catch return error.OutOfMemory;
            jw.write(ag.agent) catch return error.OutOfMemory;
            for (ag.args) |s| jw.write(s) catch return error.OutOfMemory;
            jw.endArray() catch return error.OutOfMemory;
            d.command = try aw.toOwnedSlice();
            d.target = @tagName(ag.target);
        },
        .workspaceCommand => |name| {
            d.workspaceCommand = name;
            if (reg.findCommand(name)) |c| d.command = try commandBodyText(arena, c);
            d.target = @tagName(a.restart);
        },
        .workspace => |*w| {
            d.command = try canonicalNodeAlloc(arena, w);
            d.target = @tagName(a.restart);
        },
        .setting => |s| d.command = s.path,
        .settingPreset => |p| d.command = p,
    }
    return d;
}

fn commandBodyText(arena: Allocator, c: *const actions.Command) Allocator.Error![]const u8 {
    return switch (c.body) {
        .shell => |s| s,
        .workspace => |*w| try canonicalNodeAlloc(arena, w),
    };
}

/// Descriptor of a legacy `commands` entry (project commands need trust too).
pub fn descriptorForCommand(arena: Allocator, c: *const actions.Command) Allocator.Error!Descriptor {
    return .{
        .actionID = try actions.commandActionIdAlloc(arena, c.name),
        .kind = switch (c.body) {
            .shell => "command",
            .workspace => "workspace",
        },
        .command = try commandBodyText(arena, c),
        .target = switch (c.body) {
            .shell => @tagName(actions.Target.currentTerminal),
            .workspace => @tagName(c.restart),
        },
        .configPath = c.config_path,
        .projectRoot = c.project_root,
    };
}

pub fn needsTrust(source: actions.Source) bool {
    return source == .project;
}

pub const Decision = enum { run, prompt };

pub fn decide(store: *const ActionTrustStore, source: actions.Source, fp: Fingerprint) Decision {
    if (!needsTrust(source)) return .run;
    return if (store.isTrusted(fp)) .run else .prompt;
}

/// Project image icons stay locked (not loaded) until the action is trusted.
pub fn iconLocked(source: actions.Source, icon: ?actions.Icon, trusted: bool) bool {
    const ic = icon orelse return false;
    return ic == .image and needsTrust(source) and !trusted;
}

pub const Prompt = struct {
    /// Resolved title (button title override, else action title).
    title: []const u8,
    /// What will run (command text, agent line, workspace summary).
    detail: []const u8,
    project_root: ?[]const u8,
    config_path: ?[]const u8,
    trust: []const u8 = trust_button,
    cancel: []const u8 = cancel_button,
};

/// Builds the prompt contents for a plan from `actions.plan`.
pub fn promptFor(arena: Allocator, title: []const u8, p: actions.Plan, project_root: ?[]const u8, config_path: ?[]const u8) Allocator.Error!Prompt {
    const detail: []const u8 = switch (p.run) {
        .builtin => |b| b,
        .send_text => |s| s.text,
        .workspace => |w| try std.fmt.allocPrint(arena, "Open workspace \"{s}\"", .{
            if (w.definition.get("name")) |n| n.asString() orelse w.fallback_name else w.fallback_name,
        }),
        .setting => |s| s.path,
        .preset => |pr| pr,
    };
    return .{ .title = title, .detail = detail, .project_root = project_root, .config_path = config_path };
}

// ---------------------------------------------------------------------------
// trusted-actions.json

pub const TrustedAction = struct {
    fingerprint: Fingerprint,
    action_id: []const u8,
    project_root: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    /// Unix milliseconds.
    trusted_at: i64 = 0,
};

pub const LoadError = error{ OutOfMemory, CorruptFile };

/// The trusted fingerprints. Strings live in the store arena; removals keep
/// their bytes until deinit (the file is small).
pub const ActionTrustStore = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(TrustedAction) = .empty,

    pub fn init(gpa: Allocator) ActionTrustStore {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *ActionTrustStore) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Empty text is an empty store. Entries with a malformed fingerprint
    /// are dropped; a wrong document shape is error.CorruptFile (the caller
    /// starts empty and keeps the bad file aside).
    pub fn parse(gpa: Allocator, src: []const u8) LoadError!ActionTrustStore {
        var self: ActionTrustStore = .init(gpa);
        errdefer self.deinit();
        if (std.mem.trim(u8, src, " \t\r\n").len == 0) return self;
        const a = self.arena.allocator();
        const root = jsonc.parseInto(a, src, .{}, null) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SyntaxError => return error.CorruptFile,
        };
        const list = root.get("trusted") orelse return error.CorruptFile;
        const items = switch (list.data) {
            .array => |x| x,
            else => return error.CorruptFile,
        };
        for (items) |*it| {
            const fp = (it.get("fingerprint") orelse continue).asString() orelse continue;
            if (!isFingerprint(fp)) continue;
            const id = (it.get("actionID") orelse continue).asString() orelse continue;
            var e: TrustedAction = .{ .fingerprint = fp[0..@sizeOf(Fingerprint)].*, .action_id = id };
            if (it.get("projectRoot")) |v| e.project_root = v.asString();
            if (it.get("configPath")) |v| e.config_path = v.asString();
            if (it.get("trustedAt")) |v| e.trusted_at = v.asInt() orelse 0;
            if (self.isTrusted(e.fingerprint)) continue;
            try self.entries.append(a, e);
        }
        return self;
    }

    pub fn isTrusted(self: *const ActionTrustStore, fp: Fingerprint) bool {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, &e.fingerprint, &fp)) return true;
        }
        return false;
    }

    /// Records a trust decision ("Trust and Run"); idempotent.
    pub fn trust(self: *ActionTrustStore, fp: Fingerprint, d: Descriptor, now_ms: i64) Allocator.Error!void {
        if (self.isTrusted(fp)) return;
        const a = self.arena.allocator();
        try self.entries.append(a, .{
            .fingerprint = fp,
            .action_id = try a.dupe(u8, d.actionID),
            .project_root = if (d.projectRoot) |p| try a.dupe(u8, p) else null,
            .config_path = if (d.configPath) |p| try a.dupe(u8, p) else null,
            .trusted_at = now_ms,
        });
    }

    pub fn revoke(self: *ActionTrustStore, fp: Fingerprint) bool {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, &e.fingerprint, &fp)) {
                _ = self.entries.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Forgets every action trusted under `root`; returns how many.
    pub fn revokeProject(self: *ActionTrustStore, style: paths.Style, root: []const u8) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const r = self.entries.items[i].project_root;
            if (r != null and samePath(style, r.?, root)) {
                _ = self.entries.orderedRemove(i);
                removed += 1;
            } else i += 1;
        }
        return removed;
    }

    pub fn serializeAlloc(self: *const ActionTrustStore, gpa: Allocator) Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
        self.write(&jw) catch return error.OutOfMemory;
        aw.writer.writeByte('\n') catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    fn write(self: *const ActionTrustStore, jw: *std.json.Stringify) std.Io.Writer.Error!void {
        try jw.beginObject();
        try jw.objectField("schemaVersion");
        try jw.write(schema_version);
        try jw.objectField("trusted");
        try jw.beginArray();
        for (self.entries.items) |e| {
            try jw.beginObject();
            try jw.objectField("fingerprint");
            try jw.write(@as([]const u8, &e.fingerprint));
            try jw.objectField("actionID");
            try jw.write(e.action_id);
            try jw.objectField("projectRoot");
            try jw.write(e.project_root);
            try jw.objectField("configPath");
            try jw.write(e.config_path);
            try jw.objectField("trustedAt");
            try jw.write(e.trusted_at);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
    }
};

// ---------------------------------------------------------------------------
// projects.json: path + content-hash approvals

/// Compares paths ignoring separator spelling and trailing separators
/// (and ASCII case on Windows).
pub fn samePath(style: paths.Style, a: []const u8, b: []const u8) bool {
    const x = trimSeps(style, a);
    const y = trimSeps(style, b);
    if (x.len != y.len) return false;
    for (x, y) |p, q| {
        if (isSep(style, p) and isSep(style, q)) continue;
        if (style == .windows) {
            if (std.ascii.toLower(p) != std.ascii.toLower(q)) return false;
        } else if (p != q) return false;
    }
    return true;
}

fn isSep(style: paths.Style, c: u8) bool {
    return c == '/' or (style == .windows and c == '\\');
}

fn trimSeps(style: paths.Style, p: []const u8) []const u8 {
    var end = p.len;
    while (end > 1 and isSep(style, p[end - 1])) end -= 1;
    return p[0..end];
}

/// Canonical spelling for storage: native separators, no trailing
/// separator, lowercase ASCII on Windows.
pub fn normalizePathAlloc(gpa: Allocator, style: paths.Style, p: []const u8) Allocator.Error![]u8 {
    const t = trimSeps(style, p);
    const out = try gpa.alloc(u8, t.len);
    for (t, out) |c, *o| {
        o.* = if (isSep(style, c)) style.sep() else if (style == .windows) std.ascii.toLower(c) else c;
    }
    return out;
}

pub const ProjectApproval = struct {
    /// Normalized project root.
    path: []const u8,
    /// SHA-256 hex of the project config file bytes when approved.
    content_hash: Fingerprint,
    approved_at: i64 = 0,
};

pub const ProjectStatus = enum {
    /// Approved and the config is unchanged.
    approved,
    /// Approved once, but the config changed since: ask again.
    changed,
    unknown,
};

pub const ProjectTrustStore = struct {
    arena: std.heap.ArenaAllocator,
    style: paths.Style,
    entries: std.ArrayList(ProjectApproval) = .empty,

    pub fn init(gpa: Allocator, style: paths.Style) ProjectTrustStore {
        return .{ .arena = .init(gpa), .style = style };
    }

    pub fn deinit(self: *ProjectTrustStore) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn parse(gpa: Allocator, style: paths.Style, src: []const u8) LoadError!ProjectTrustStore {
        var self: ProjectTrustStore = .init(gpa, style);
        errdefer self.deinit();
        if (std.mem.trim(u8, src, " \t\r\n").len == 0) return self;
        const a = self.arena.allocator();
        const root = jsonc.parseInto(a, src, .{}, null) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SyntaxError => return error.CorruptFile,
        };
        const list = root.get("projects") orelse return error.CorruptFile;
        const items = switch (list.data) {
            .array => |x| x,
            else => return error.CorruptFile,
        };
        for (items) |*it| {
            const p = (it.get("path") orelse continue).asString() orelse continue;
            if (p.len == 0) continue;
            const h = (it.get("contentHash") orelse continue).asString() orelse continue;
            if (!isFingerprint(h)) continue;
            const approved_at = if (it.get("approvedAt")) |v| v.asInt() orelse 0 else 0;
            try self.put(p, h[0..@sizeOf(Fingerprint)].*, approved_at);
        }
        return self;
    }

    fn indexOf(self: *const ProjectTrustStore, path: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (samePath(self.style, e.path, path)) return i;
        }
        return null;
    }

    fn put(self: *ProjectTrustStore, path: []const u8, hash: Fingerprint, now_ms: i64) Allocator.Error!void {
        if (self.indexOf(path)) |i| {
            self.entries.items[i].content_hash = hash;
            self.entries.items[i].approved_at = now_ms;
            return;
        }
        const a = self.arena.allocator();
        try self.entries.append(a, .{ .path = try normalizePathAlloc(a, self.style, path), .content_hash = hash, .approved_at = now_ms });
    }

    pub fn status(self: *const ProjectTrustStore, path: []const u8, config_bytes: []const u8) ProjectStatus {
        const i = self.indexOf(path) orelse return .unknown;
        const h = sha256Hex(config_bytes);
        return if (std.mem.eql(u8, &self.entries.items[i].content_hash, &h)) .approved else .changed;
    }

    /// Approves `path` for the current config contents.
    pub fn approve(self: *ProjectTrustStore, path: []const u8, config_bytes: []const u8, now_ms: i64) Allocator.Error!void {
        try self.put(path, sha256Hex(config_bytes), now_ms);
    }

    pub fn revoke(self: *ProjectTrustStore, path: []const u8) bool {
        const i = self.indexOf(path) orelse return false;
        _ = self.entries.orderedRemove(i);
        return true;
    }

    pub fn serializeAlloc(self: *const ProjectTrustStore, gpa: Allocator) Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
        self.write(&jw) catch return error.OutOfMemory;
        aw.writer.writeByte('\n') catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    fn write(self: *const ProjectTrustStore, jw: *std.json.Stringify) std.Io.Writer.Error!void {
        try jw.beginObject();
        try jw.objectField("schemaVersion");
        try jw.write(schema_version);
        try jw.objectField("projects");
        try jw.beginArray();
        for (self.entries.items) |e| {
            try jw.beginObject();
            try jw.objectField("path");
            try jw.write(e.path);
            try jw.objectField("contentHash");
            try jw.write(@as([]const u8, &e.content_hash));
            try jw.objectField("approvedAt");
            try jw.write(e.approved_at);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn projectRegistry(arena: Allocator, src: []const u8, root: []const u8) !actions.Registry {
    var d: actions.Diagnostics = .init(arena);
    const cfg = try arena.create(actions.Config);
    cfg.* = try actions.parseConfigText(arena, src, .{
        .source = .project,
        .config_path = try std.fmt.allocPrint(arena, "{s}/.cmux/cmux.json", .{root}),
        .project_root = root,
    }, &d);
    try testing.expect(!d.hasErrors());
    return actions.buildRegistry(arena, &.{cfg});
}

fn actionFingerprint(arena: Allocator, reg: *const actions.Registry, id: []const u8) !Fingerprint {
    const d = try descriptorForAction(arena, reg, reg.findAction(id).?, .{});
    return fingerprint(arena, d);
}

test "unit: custom_actions: descriptor JSON has sorted keys and explicit nulls" {
    const text = try canonicalJsonAlloc(testing.allocator, .{ .actionID = "t", .kind = "command", .command = "npm test", .target = "newTabInCurrentPane", .projectRoot = "/p" });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\{"actionID":"t","command":"npm test","configPath":null,"iconFingerprint":null,"kind":"command","projectRoot":"/p","schemaVersion":1,"target":"newTabInCurrentPane","workspaceCommand":null}
    , text);
    const fp = try fingerprint(testing.allocator, .{ .actionID = "t", .kind = "command", .command = "npm test", .target = "newTabInCurrentPane", .projectRoot = "/p" });
    try testing.expectEqualStrings(&sha256Hex(text), &fp);
    try testing.expect(isFingerprint(&fp));
    try testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &sha256Hex(""));
}

test "unit: custom_actions: first run of a project action prompts and trusting it lets it run" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const reg = try projectRegistry(a, "{\"actions\":{\"t\":{\"command\":\"npm test\",\"title\":\"Test\"}}}", "/p");
    const act = reg.findAction("t").?;
    const d = try descriptorForAction(a, &reg, act, .{});
    const fp = try fingerprint(a, d);
    var store: ActionTrustStore = .init(testing.allocator);
    defer store.deinit();
    try testing.expectEqual(Decision.prompt, decide(&store, act.source, fp));
    try store.trust(fp, d, 1_700_000_000_000);
    try store.trust(fp, d, 1_700_000_000_001);
    try testing.expectEqual(@as(usize, 1), store.entries.items.len);
    try testing.expectEqual(Decision.run, decide(&store, act.source, fp));
    // Global and built-in actions never prompt.
    try testing.expectEqual(Decision.run, decide(&store, .global, try actionFingerprint(a, &reg, "t")));
    try testing.expectEqual(Decision.run, decide(&store, .builtin, fp));
}

test "unit: custom_actions: editing the command or moving the project changes the fingerprint" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const base = try projectRegistry(a, "{\"actions\":{\"t\":{\"command\":\"npm test\"}}}", "/p");
    const edited = try projectRegistry(a, "{\"actions\":{\"t\":{\"command\":\"npm test -- --watch\"}}}", "/p");
    const moved = try projectRegistry(a, "{\"actions\":{\"t\":{\"command\":\"npm test\"}}}", "/q");
    const retarget = try projectRegistry(a, "{\"actions\":{\"t\":{\"command\":\"npm test\",\"target\":\"currentTerminal\"}}}", "/p");
    const retitled = try projectRegistry(a, "{\"actions\":{\"t\":{\"command\":\"npm test\",\"title\":\"x\",\"palette\":false}}}", "/p");
    const fp = try actionFingerprint(a, &base, "t");
    try testing.expect(!std.mem.eql(u8, &fp, &(try actionFingerprint(a, &edited, "t"))));
    try testing.expect(!std.mem.eql(u8, &fp, &(try actionFingerprint(a, &moved, "t"))));
    try testing.expect(!std.mem.eql(u8, &fp, &(try actionFingerprint(a, &retarget, "t"))));
    // Labels are not part of what runs.
    try testing.expectEqualStrings(&fp, &(try actionFingerprint(a, &retitled, "t")));
}

test "unit: custom_actions: workspace fingerprints ignore formatting but not content" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r1 = try projectRegistry(a, "{\"actions\":{\"w\":{\"workspace\":{\"name\":\"x\",\"layout\":{\"surfaces\":[{\"command\":\"a\"}]}}}}}", "/p");
    const r2 = try projectRegistry(a,
        \\{"actions": {"w": {"workspace": {
        \\   // reordered and commented
        \\   "layout": {"surfaces": [{"command": "a"}]}, "name": "x",
        \\}}}}
    , "/p");
    const r3 = try projectRegistry(a, "{\"actions\":{\"w\":{\"workspace\":{\"name\":\"x\",\"layout\":{\"surfaces\":[{\"command\":\"b\"}]}}}}}", "/p");
    try testing.expectEqualStrings(&(try actionFingerprint(a, &r1, "w")), &(try actionFingerprint(a, &r2, "w")));
    try testing.expect(!std.mem.eql(u8, &(try actionFingerprint(a, &r1, "w")), &(try actionFingerprint(a, &r3, "w"))));
}

test "unit: custom_actions: a workspaceCommand fingerprint follows the referenced command" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r1 = try projectRegistry(a, "{\"actions\":{\"d\":{\"commandName\":\"Dev\"}},\"commands\":[{\"name\":\"Dev\",\"workspace\":{\"setup\":\"a\"}}]}", "/p");
    const r2 = try projectRegistry(a, "{\"actions\":{\"d\":{\"commandName\":\"Dev\"}},\"commands\":[{\"name\":\"Dev\",\"workspace\":{\"setup\":\"rm -rf /\"}}]}", "/p");
    const d1 = try descriptorForAction(a, &r1, r1.findAction("d").?, .{});
    try testing.expectEqualStrings("Dev", d1.workspaceCommand.?);
    try testing.expectEqualStrings("{\"setup\":\"a\"}", d1.command.?);
    try testing.expect(!std.mem.eql(u8, &(try actionFingerprint(a, &r1, "d")), &(try actionFingerprint(a, &r2, "d"))));
    // Legacy commands get descriptors too.
    const cd = try descriptorForCommand(a, r2.findCommand("Dev").?);
    try testing.expectEqualStrings("command:Dev", cd.actionID);
    try testing.expectEqualStrings("workspace", cd.kind);
    try testing.expectEqualStrings("/p", cd.projectRoot.?);
}

test "unit: custom_actions: canonical nodes sort keys, drop duplicates and normalize integers" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const n = try jsonc.parseInto(a, "{\"b\":[1.0,2.5,{\"z\":null,\"y\":true}],\"a\":\"ü\",\"b\":[1.0,2.5,{\"z\":null,\"y\":true}],\"c\":-0.0}", .{}, null);
    try testing.expectEqualStrings("{\"a\":\"ü\",\"b\":[1,2.5,{\"y\":true,\"z\":null}],\"c\":0}", try canonicalNodeAlloc(a, &n));
}

test "unit: custom_actions: image icons stay locked until trusted and icon edits re-prompt" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const img: actions.Icon = .{ .image = "./icons/codex.svg" };
    try testing.expect(iconLocked(.project, img, false));
    try testing.expect(!iconLocked(.project, img, true));
    try testing.expect(!iconLocked(.global, img, false));
    try testing.expect(!iconLocked(.project, .{ .symbol = "play" }, false));
    try testing.expect(!iconLocked(.project, null, false));
    const f1 = try iconFingerprint(a, img, "<svg/>");
    const f2 = try iconFingerprint(a, img, "<svg>evil</svg>");
    const f3 = try iconFingerprint(a, img, null);
    try testing.expect(!std.mem.eql(u8, &f1, &f2));
    try testing.expect(!std.mem.eql(u8, &f1, &f3));
    const e1 = try iconFingerprint(a, .{ .emoji = .{ .value = "🧪" } }, null);
    const e2 = try iconFingerprint(a, .{ .emoji = .{ .value = "🧪", .scale = 0.9 } }, null);
    try testing.expect(!std.mem.eql(u8, &e1, &e2));

    const reg = try projectRegistry(a, "{\"actions\":{\"c\":{\"agent\":\"codex\",\"icon\":{\"type\":\"image\",\"path\":\"./icons/codex.svg\"}}}}", "/p");
    const act = reg.findAction("c").?;
    const d1 = try descriptorForAction(a, &reg, act, .{ .icon_bytes = "<svg/>" });
    const d2 = try descriptorForAction(a, &reg, act, .{ .icon_bytes = "<svg>v2</svg>" });
    try testing.expectEqualStrings("[\"codex\"]", d1.command.?);
    try testing.expect(!std.mem.eql(u8, &(try fingerprint(a, d1)), &(try fingerprint(a, d2))));
}

test "unit: custom_actions: trusted-actions.json round-trips and tolerates bad entries" {
    var store: ActionTrustStore = .init(testing.allocator);
    defer store.deinit();
    const fp1 = sha256Hex("one");
    const fp2 = sha256Hex("two");
    try store.trust(fp1, .{ .actionID = "a", .kind = "command", .projectRoot = "C:\\Src\\App", .configPath = "C:\\Src\\App\\.cmux\\cmux.json" }, 5);
    try store.trust(fp2, .{ .actionID = "ünï", .kind = "agent", .projectRoot = "/q" }, 6);
    const text = try store.serializeAlloc(testing.allocator);
    defer testing.allocator.free(text);
    var again = try ActionTrustStore.parse(testing.allocator, text);
    defer again.deinit();
    try testing.expectEqual(@as(usize, 2), again.entries.items.len);
    try testing.expect(again.isTrusted(fp1));
    try testing.expectEqualStrings("ünï", again.entries.items[1].action_id);
    try testing.expectEqual(@as(i64, 5), again.entries.items[0].trusted_at);
    const text2 = try again.serializeAlloc(testing.allocator);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);

    try testing.expectEqual(@as(usize, 1), again.revokeProject(.windows, "c:/src/app/"));
    try testing.expect(!again.isTrusted(fp1));
    try testing.expect(again.revoke(fp2));
    try testing.expect(!again.revoke(fp2));

    var empty = try ActionTrustStore.parse(testing.allocator, "");
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.entries.items.len);
    var partial = try ActionTrustStore.parse(testing.allocator,
        \\{"trusted": [{"fingerprint": "XYZ", "actionID": "a"}, {"fingerprint": 3}, 7,
        \\  {"fingerprint": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
        \\  {"fingerprint": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "actionID": "ok"}]}
    );
    defer partial.deinit();
    try testing.expectEqual(@as(usize, 1), partial.entries.items.len);
    for ([_][]const u8{ "{", "[]", "{\"trusted\":{}}", "{}" }) |bad| {
        try testing.expectError(error.CorruptFile, ActionTrustStore.parse(testing.allocator, bad));
    }
    try testing.expect(!isFingerprint("E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"));
}

test "unit: custom_actions: project approvals are keyed by path and config content hash" {
    var store: ProjectTrustStore = .init(testing.allocator, .windows);
    defer store.deinit();
    const cfg = "{\"actions\":{}}";
    try testing.expectEqual(ProjectStatus.unknown, store.status("C:\\Src\\App", cfg));
    try store.approve("C:\\Src\\App\\", cfg, 10);
    try testing.expectEqual(ProjectStatus.approved, store.status("c:/src/app", cfg));
    try testing.expectEqual(ProjectStatus.changed, store.status("C:\\Src\\App", "{\"actions\":{\"x\":{}}}"));
    try testing.expectEqual(ProjectStatus.unknown, store.status("C:\\Src\\App2", cfg));
    try store.approve("c:\\src\\app", "{\"v\":2}", 11);
    try testing.expectEqual(@as(usize, 1), store.entries.items.len);
    try testing.expectEqualStrings("c:\\src\\app", store.entries.items[0].path);
    try testing.expectEqual(ProjectStatus.approved, store.status("C:\\SRC\\APP", "{\"v\":2}"));

    const text = try store.serializeAlloc(testing.allocator);
    defer testing.allocator.free(text);
    var again = try ProjectTrustStore.parse(testing.allocator, .windows, text);
    defer again.deinit();
    try testing.expectEqual(ProjectStatus.approved, again.status("C:/src/app", "{\"v\":2}"));
    try testing.expectEqual(@as(i64, 11), again.entries.items[0].approved_at);
    try testing.expect(again.revoke("C:\\src\\app"));
    try testing.expect(!again.revoke("C:\\src\\app"));

    var posix: ProjectTrustStore = .init(testing.allocator, .posix);
    defer posix.deinit();
    try posix.approve("/Src/App", cfg, 1);
    try testing.expectEqual(ProjectStatus.unknown, posix.status("/src/app", cfg));
    try testing.expectEqual(ProjectStatus.approved, posix.status("/Src/App/", cfg));
    try testing.expectError(error.CorruptFile, ProjectTrustStore.parse(testing.allocator, .posix, "{\"projects\":1}"));
}

test "unit: custom_actions: the trust prompt shows the resolved title and what will run" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const reg = try projectRegistry(a,
        \\{"actions": {"t": {"command": "npm test", "title": "Test"}, "w": {"title": "Fullstack", "workspace": {"name": "fs"}}},
        \\ "ui": {"surfaceTabBar": {"buttons": [{"action": "t", "title": "Run the tests"}]}}}
    , "/p");
    const buttons = try actions.tabBarButtons(a, &reg, null);
    const p = try actions.plan(a, &reg, "t", .{});
    const prompt = try promptFor(a, buttons[0].title, p, "/p", null);
    try testing.expectEqualStrings("Run the tests", prompt.title);
    try testing.expectEqualStrings("npm test", prompt.detail);
    try testing.expectEqualStrings("Trust and Run", prompt.trust);
    const pw = try actions.plan(a, &reg, "w", .{});
    const prompt_w = try promptFor(a, pw.title, pw, "/p", null);
    try testing.expectEqualStrings("Fullstack", prompt_w.title);
    try testing.expectEqualStrings("Open workspace \"fs\"", prompt_w.detail);
}
