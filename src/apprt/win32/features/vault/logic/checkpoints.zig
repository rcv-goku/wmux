//! Vault checkpoints and fork-from-checkpoint (agents-vault-checkpoints-fork,
//! agents-vault-cli, hosted-vault-cli). Pure: the caller reads transcripts,
//! loads/saves the store file and writes the forked transcript.
//!
//! A session's timeline is its derived turn checkpoints ("Turn N", one at the
//! end of every user-prompt turn) plus manual named checkpoints captured at
//! the transcript end together with the workspace git HEAD. A checkpoint pins
//! a byte offset (always a line boundary) and the SHA-256 of the transcript
//! prefix, so a fork can detect a transcript that no longer matches. Forking
//! writes a truncated copy with a new session id; the original is never
//! modified.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");
const index = @import("index.zig");
const Format = index.Format;

/// Transcripts larger than this are refused for checkpoints and forks.
pub const default_max_transcript_bytes: u64 = 256 << 20;
/// Prefix of derived turn checkpoint ids (`turn-3`); reserved for turns.
pub const turn_id_prefix = "turn-";
/// Store file schema version.
pub const store_version = 1;

pub const Kind = enum { turn, manual };

/// SHA-256 hex (lowercase) of a transcript prefix.
pub const Digest = [64]u8;

pub fn digestOf(bytes: []const u8) Digest {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return std.fmt.bytesToHex(out, .lower);
}

/// One timeline entry. Slices are owned by the checkpoint.
pub const Checkpoint = struct {
    id: []u8,
    kind: Kind,
    /// User-given name (manual; may be empty) or "Turn N" (derived).
    name: []u8,
    /// Number of user-prompt turns contained in the prefix.
    turn: u32,
    /// Prefix length in bytes; always ends at a line boundary.
    byte_offset: u64,
    sha256: Digest,
    /// Workspace git HEAD at capture (manual only; empty when unavailable).
    git_head: []u8,
    created_ms: i64 = 0,

    pub fn deinit(self: *Checkpoint, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
        gpa.free(self.git_head);
        self.* = undefined;
    }

    pub fn clone(self: *const Checkpoint, gpa: Allocator) Allocator.Error!Checkpoint {
        const id = try gpa.dupe(u8, self.id);
        errdefer gpa.free(id);
        const name = try gpa.dupe(u8, self.name);
        errdefer gpa.free(name);
        const head = try gpa.dupe(u8, self.git_head);
        var c = self.*;
        c.id = id;
        c.name = name;
        c.git_head = head;
        return c;
    }

    /// Label for the timeline: the name, or "Checkpoint (Turn N)" for an
    /// unnamed manual checkpoint.
    pub fn writeLabel(self: *const Checkpoint, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.name.len > 0) return w.writeAll(self.name);
        try w.print("Checkpoint (Turn {d})", .{self.turn});
    }
};

// ---------------------------------------------------------------------------
// Turn derivation

/// One user-prompt turn: bytes `[start, end)` of the transcript, where `end`
/// is the start of the next turn or the end of the last complete line.
pub const TurnMark = struct {
    turn: u32,
    start: u64,
    end: u64,
};

pub const Turns = struct {
    marks: []TurnMark,
    /// Length of the transcript made of complete lines (an unterminated tail
    /// counts only when it is a complete JSON object).
    complete_len: u64,

    pub fn deinit(self: *Turns, gpa: Allocator) void {
        gpa.free(self.marks);
        self.* = undefined;
    }
};

pub fn deriveTurns(gpa: Allocator, format: Format, transcript: []const u8) Allocator.Error!Turns {
    var marks: std.ArrayList(TurnMark) = .empty;
    errdefer marks.deinit(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var it: index.LineIterator = .{ .bytes = transcript, .at_eof = true };
    var complete: u64 = 0;
    while (it.next()) |ln| {
        const line = transcript[ln.start..ln.end];
        if (ln.next == ln.end and !index.tailIsComplete(gpa, line)) break;
        _ = arena_state.reset(.retain_capacity);
        const info = try index.classifyLine(arena_state.allocator(), format, line);
        if (info.kind == .user_prompt) {
            if (marks.items.len > 0) marks.items[marks.items.len - 1].end = ln.start;
            try marks.append(gpa, .{ .turn = @intCast(marks.items.len + 1), .start = ln.start, .end = ln.next });
        }
        complete = ln.next;
    }
    if (marks.items.len > 0) marks.items[marks.items.len - 1].end = complete;
    return .{ .marks = try marks.toOwnedSlice(gpa), .complete_len = complete };
}

/// Number of turns that start before `offset`.
pub fn turnsBefore(turns: *const Turns, offset: u64) u32 {
    var n: u32 = 0;
    for (turns.marks) |m| {
        if (m.start < offset) n = m.turn else break;
    }
    return n;
}

fn turnCheckpoint(gpa: Allocator, m: TurnMark, digest: Digest) Allocator.Error!Checkpoint {
    const id = try std.fmt.allocPrint(gpa, turn_id_prefix ++ "{d}", .{m.turn});
    errdefer gpa.free(id);
    const name = try std.fmt.allocPrint(gpa, "Turn {d}", .{m.turn});
    errdefer gpa.free(name);
    const head = try gpa.alloc(u8, 0);
    return .{
        .id = id,
        .kind = .turn,
        .name = name,
        .turn = m.turn,
        .byte_offset = m.end,
        .sha256 = digest,
        .git_head = head,
    };
}

// ---------------------------------------------------------------------------
// Manual checkpoints

pub const CaptureError = Allocator.Error || error{
    /// The full transcript has not been read yet ("unavailable until the full
    /// transcript is read").
    TranscriptIncomplete,
    TranscriptTooLarge,
    /// Id empty, reserved (`turn-…`) or not printable ASCII.
    InvalidCheckpointId,
};

pub const CaptureOptions = struct {
    /// Caller-generated unique id (e.g. a lowercase UUID).
    id: []const u8,
    name: []const u8 = "",
    /// Workspace git HEAD (`git rev-parse HEAD`), empty when unavailable.
    git_head: []const u8 = "",
    now_ms: i64,
    /// False while the transcript is still being read.
    complete: bool = true,
    max_bytes: u64 = default_max_transcript_bytes,
};

/// "Checkpoint Now": a manual checkpoint at the current transcript end.
pub fn captureManual(gpa: Allocator, format: Format, transcript: []const u8, opts: CaptureOptions) CaptureError!Checkpoint {
    if (!opts.complete) return error.TranscriptIncomplete;
    if (transcript.len > opts.max_bytes) return error.TranscriptTooLarge;
    if (!validCheckpointId(opts.id)) return error.InvalidCheckpointId;
    var turns = try deriveTurns(gpa, format, transcript);
    defer turns.deinit(gpa);
    const end = turns.complete_len;
    const id = try gpa.dupe(u8, opts.id);
    errdefer gpa.free(id);
    const name = try sanitizedName(gpa, opts.name);
    errdefer gpa.free(name);
    const head = try proto.utf8.dupeTruncated(gpa, std.mem.trim(u8, opts.git_head, " \t\r\n"), 128);
    return .{
        .id = id,
        .kind = .manual,
        .name = name,
        .turn = turnsBefore(&turns, end),
        .byte_offset = end,
        .sha256 = digestOf(transcript[0..@intCast(end)]),
        .git_head = head,
        .created_ms = opts.now_ms,
    };
}

pub fn validCheckpointId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    if (std.mem.startsWith(u8, id, turn_id_prefix)) return false;
    for (id) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

/// Trimmed, single-line, capped (256 bytes) copy of a checkpoint name.
fn sanitizedName(gpa: Allocator, name: []const u8) Allocator.Error![]u8 {
    const t = proto.utf8.truncateUtf8(std.mem.trim(u8, name, " \t\r\n"), 256);
    const out = try gpa.dupe(u8, t);
    for (out) |*c| if (c.* == '\n' or c.* == '\r' or c.* == '\t') {
        c.* = ' ';
    };
    return out;
}

// ---------------------------------------------------------------------------
// Store (`%LOCALAPPDATA%\wmux\vault-checkpoints.json`)

/// A fork created by Vault: marks `session_id` with "(fork)".
pub const ForkRecord = struct {
    agent: []u8,
    session_id: []u8,
    parent_session_id: []u8,
    checkpoint_id: []u8,
    created_ms: i64,

    fn deinit(self: *ForkRecord, gpa: Allocator) void {
        gpa.free(self.agent);
        gpa.free(self.session_id);
        gpa.free(self.parent_session_id);
        gpa.free(self.checkpoint_id);
        self.* = undefined;
    }
};

const Record = struct {
    agent: []u8,
    session_id: []u8,
    cp: Checkpoint,

    fn deinit(self: *Record, gpa: Allocator) void {
        gpa.free(self.agent);
        gpa.free(self.session_id);
        self.cp.deinit(gpa);
        self.* = undefined;
    }
};

/// Manual checkpoints and fork records of all sessions.
pub const Store = struct {
    gpa: Allocator,
    records: std.ArrayList(Record) = .empty,
    forks: std.ArrayList(ForkRecord) = .empty,

    pub fn init(gpa: Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Store) void {
        for (self.records.items) |*r| r.deinit(self.gpa);
        self.records.deinit(self.gpa);
        for (self.forks.items) |*f| f.deinit(self.gpa);
        self.forks.deinit(self.gpa);
        self.* = undefined;
    }

    fn find(self: *const Store, agent: []const u8, session_id: []const u8, id: []const u8) ?usize {
        for (self.records.items, 0..) |r, i| {
            if (std.mem.eql(u8, r.agent, agent) and std.mem.eql(u8, r.session_id, session_id) and
                std.mem.eql(u8, r.cp.id, id)) return i;
        }
        return null;
    }

    /// Adds a manual checkpoint (the store takes a copy).
    pub fn add(self: *Store, agent: []const u8, session_id: []const u8, cp: *const Checkpoint) (Allocator.Error || error{DuplicateCheckpoint})!void {
        if (self.find(agent, session_id, cp.id) != null) return error.DuplicateCheckpoint;
        const a = try self.gpa.dupe(u8, agent);
        errdefer self.gpa.free(a);
        const s = try self.gpa.dupe(u8, session_id);
        errdefer self.gpa.free(s);
        var c = try cp.clone(self.gpa);
        errdefer c.deinit(self.gpa);
        try self.records.append(self.gpa, .{ .agent = a, .session_id = s, .cp = c });
    }

    /// Removes a manual checkpoint; false when absent.
    pub fn remove(self: *Store, agent: []const u8, session_id: []const u8, id: []const u8) bool {
        const i = self.find(agent, session_id, id) orelse return false;
        var r = self.records.orderedRemove(i);
        r.deinit(self.gpa);
        return true;
    }

    /// Manual checkpoints of one session, in insertion order (borrowed).
    pub fn manualFor(self: *const Store, gpa: Allocator, agent: []const u8, session_id: []const u8) Allocator.Error![]*const Checkpoint {
        var out: std.ArrayList(*const Checkpoint) = .empty;
        errdefer out.deinit(gpa);
        for (self.records.items) |*r| {
            if (std.mem.eql(u8, r.agent, agent) and std.mem.eql(u8, r.session_id, session_id))
                try out.append(gpa, &r.cp);
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn recordFork(self: *Store, agent: []const u8, session_id: []const u8, parent: []const u8, checkpoint_id: []const u8, now_ms: i64) Allocator.Error!void {
        const a = try self.gpa.dupe(u8, agent);
        errdefer self.gpa.free(a);
        const s = try self.gpa.dupe(u8, session_id);
        errdefer self.gpa.free(s);
        const p = try self.gpa.dupe(u8, parent);
        errdefer self.gpa.free(p);
        const c = try self.gpa.dupe(u8, checkpoint_id);
        errdefer self.gpa.free(c);
        try self.forks.append(self.gpa, .{ .agent = a, .session_id = s, .parent_session_id = p, .checkpoint_id = c, .created_ms = now_ms });
    }

    /// True when Vault created this session by forking (title gets "(fork)").
    pub fn isFork(self: *const Store, agent: []const u8, session_id: []const u8) bool {
        for (self.forks.items) |f| {
            if (std.mem.eql(u8, f.agent, agent) and std.mem.eql(u8, f.session_id, session_id)) return true;
        }
        return false;
    }

    const JsonCheckpoint = struct {
        agent: []const u8,
        session_id: []const u8,
        id: []const u8,
        name: []const u8 = "",
        turn: u32 = 0,
        byte_offset: u64,
        sha256: []const u8,
        git_head: []const u8 = "",
        created_ms: i64 = 0,
    };
    const JsonFork = struct {
        agent: []const u8,
        session_id: []const u8,
        parent_session_id: []const u8,
        checkpoint_id: []const u8 = "",
        created_ms: i64 = 0,
    };
    const JsonFile = struct {
        version: u32,
        checkpoints: []const JsonCheckpoint = &.{},
        forks: []const JsonFork = &.{},
    };

    /// Serializes the store as JSON (stable order: insertion order).
    pub fn write(self: *const Store, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
        try s.beginObject();
        try s.objectField("version");
        try s.write(store_version);
        try s.objectField("checkpoints");
        try s.beginArray();
        for (self.records.items) |r| {
            try s.write(JsonCheckpoint{
                .agent = r.agent,
                .session_id = r.session_id,
                .id = r.cp.id,
                .name = r.cp.name,
                .turn = r.cp.turn,
                .byte_offset = r.cp.byte_offset,
                .sha256 = &r.cp.sha256,
                .git_head = r.cp.git_head,
                .created_ms = r.cp.created_ms,
            });
        }
        try s.endArray();
        try s.objectField("forks");
        try s.beginArray();
        for (self.forks.items) |f| {
            try s.write(JsonFork{
                .agent = f.agent,
                .session_id = f.session_id,
                .parent_session_id = f.parent_session_id,
                .checkpoint_id = f.checkpoint_id,
                .created_ms = f.created_ms,
            });
        }
        try s.endArray();
        try s.endObject();
        try w.writeByte('\n');
    }

    pub const LoadError = Allocator.Error || error{ InvalidStore, UnsupportedVersion };

    /// Parses a store file. Unknown fields are ignored; individual records
    /// with an invalid id or digest are dropped; a file that is not a store
    /// object fails with `error.InvalidStore` (callers start empty and keep
    /// the bad file aside).
    pub fn load(gpa: Allocator, bytes: []const u8) LoadError!Store {
        const parsed = std.json.parseFromSlice(JsonFile, gpa, bytes, .{
            .ignore_unknown_fields = true,
            .duplicate_field_behavior = .use_last,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidStore,
        };
        defer parsed.deinit();
        if (parsed.value.version != store_version) return error.UnsupportedVersion;
        var store = Store.init(gpa);
        errdefer store.deinit();
        for (parsed.value.checkpoints) |jc| {
            if (!validCheckpointId(jc.id) or jc.sha256.len != 64 or jc.agent.len == 0 or jc.session_id.len == 0) continue;
            var digest: Digest = undefined;
            for (jc.sha256, &digest) |c, *d| d.* = std.ascii.toLower(c);
            if (!isHex(&digest)) continue;
            const cp: Checkpoint = .{
                .id = @constCast(jc.id),
                .kind = .manual,
                .name = @constCast(jc.name),
                .turn = jc.turn,
                .byte_offset = jc.byte_offset,
                .sha256 = digest,
                .git_head = @constCast(jc.git_head),
                .created_ms = jc.created_ms,
            };
            store.add(jc.agent, jc.session_id, &cp) catch |err| switch (err) {
                error.DuplicateCheckpoint => continue,
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        for (parsed.value.forks) |jf| {
            if (jf.agent.len == 0 or jf.session_id.len == 0) continue;
            try store.recordFork(jf.agent, jf.session_id, jf.parent_session_id, jf.checkpoint_id, jf.created_ms);
        }
        return store;
    }
};

fn isHex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Timeline

/// A session's checkpoints ordered by offset (turn before manual at the same
/// offset, then manual by creation time). Owns its checkpoints.
pub const Timeline = struct {
    items: []Checkpoint,
    /// Turns derived from the current transcript.
    turn_count: u32,

    pub fn deinit(self: *Timeline, gpa: Allocator) void {
        for (self.items) |*c| c.deinit(gpa);
        gpa.free(self.items);
        self.* = undefined;
    }

    pub fn find(self: *const Timeline, id: []const u8) ?*const Checkpoint {
        for (self.items) |*c| if (std.mem.eql(u8, c.id, id)) return c;
        return null;
    }

    pub fn findTurn(self: *const Timeline, n: u32) ?*const Checkpoint {
        for (self.items) |*c| if (c.kind == .turn and c.turn == n) return c;
        return null;
    }
};

pub fn timeline(
    gpa: Allocator,
    format: Format,
    transcript: []const u8,
    manual: []const *const Checkpoint,
) Allocator.Error!Timeline {
    var turns = try deriveTurns(gpa, format, transcript);
    defer turns.deinit(gpa);
    var items: std.ArrayList(Checkpoint) = .empty;
    errdefer {
        for (items.items) |*c| c.deinit(gpa);
        items.deinit(gpa);
    }
    try items.ensureTotalCapacity(gpa, turns.marks.len + manual.len);
    // One running hash over the transcript; each turn end snapshots it.
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var hashed: usize = 0;
    for (turns.marks) |m| {
        const end: usize = @intCast(m.end);
        hasher.update(transcript[hashed..end]);
        hashed = end;
        var snap = hasher;
        var raw: [32]u8 = undefined;
        snap.final(&raw);
        items.appendAssumeCapacity(try turnCheckpoint(gpa, m, std.fmt.bytesToHex(raw, .lower)));
    }
    for (manual) |m| items.appendAssumeCapacity(try m.clone(gpa));
    std.mem.sort(Checkpoint, items.items, {}, struct {
        fn lt(_: void, a: Checkpoint, b: Checkpoint) bool {
            if (a.byte_offset != b.byte_offset) return a.byte_offset < b.byte_offset;
            if (a.kind != b.kind) return a.kind == .turn;
            if (a.created_ms != b.created_ms) return a.created_ms < b.created_ms;
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lt);
    return .{ .items = try items.toOwnedSlice(gpa), .turn_count = @intCast(turns.marks.len) };
}

// ---------------------------------------------------------------------------
// Fork

/// Agents whose transcripts Vault can fork; others get a view-only timeline.
pub fn forkSupported(agent: []const u8) bool {
    const ids = [_][]const u8{ "claude", "codex", "pi", "grok" };
    for (ids) |id| if (std.mem.eql(u8, id, agent)) return true;
    return false;
}

pub const ForkError = Allocator.Error || error{
    ForkUnsupported,
    TranscriptTooLarge,
    CheckpointMismatch,
    NothingBeforeCheckpoint,
    InvalidSessionId,
};

/// User-facing message for a fork/checkpoint error.
pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ForkUnsupported => "Fork from checkpoint isn't available for this agent yet",
        error.TranscriptTooLarge => "Transcript is too large to fork",
        error.CheckpointMismatch => "Transcript no longer matches this checkpoint",
        error.NothingBeforeCheckpoint => "Nothing to fork before this checkpoint",
        error.InvalidSessionId => "Invalid new session id",
        error.TranscriptIncomplete => "Checkpoints are unavailable until the full transcript is read",
        error.InvalidCheckpointId => "Invalid checkpoint id",
        error.DuplicateCheckpoint => "Checkpoint already exists",
        error.FileNotFound => "Transcript is missing",
        else => "Fork failed",
    };
}

pub const ForkOptions = struct {
    /// New native session id (a UUID; Claude/Codex/Pi/Grok all use UUIDs).
    new_session_id: []const u8,
    max_bytes: u64 = default_max_transcript_bytes,
};

/// Writes the forked transcript: the checkpoint's prefix with every session
/// id field rewritten to `new_session_id`. Lines without a session id are
/// copied byte for byte. The result always ends with a newline.
pub fn fork(gpa: Allocator, agent: []const u8, transcript: []const u8, cp: *const Checkpoint, opts: ForkOptions) ForkError![]u8 {
    if (!forkSupported(agent)) return error.ForkUnsupported;
    if (transcript.len > opts.max_bytes) return error.TranscriptTooLarge;
    if (!proto.uuid.Uuid.isUuidText(opts.new_session_id)) return error.InvalidSessionId;
    if (cp.byte_offset > transcript.len) return error.CheckpointMismatch;
    const end: usize = @intCast(cp.byte_offset);
    const prefix = transcript[0..end];
    if (end > 0 and prefix[end - 1] != '\n' and end != transcript.len) return error.CheckpointMismatch;
    if (!std.mem.eql(u8, &digestOf(prefix), &cp.sha256)) return error.CheckpointMismatch;

    const format = Format.forAgent(agent);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, prefix.len + 1);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var it: index.LineIterator = .{ .bytes = prefix, .at_eof = true };
    var prompts: usize = 0;
    while (it.next()) |ln| {
        const line = prefix[ln.start..ln.end];
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        const info = try index.classifyLine(arena, format, line);
        if (info.kind == .user_prompt) prompts += 1;
        const rewritten = if (info.kind == .meta or info.session_id != null)
            try rewriteIds(arena, format, line, opts.new_session_id)
        else
            null;
        try out.appendSlice(gpa, rewritten orelse line);
        try out.append(gpa, '\n');
    }
    if (prompts == 0) return error.NothingBeforeCheckpoint;
    return out.toOwnedSlice(gpa);
}

/// Re-serializes one record with its session id fields replaced, or null
/// when the line has none. Numbers keep their original spelling.
fn rewriteIds(arena: Allocator, format: Format, line: []const u8, new_id: []const u8) Allocator.Error!?[]const u8 {
    var root = std.json.parseFromSliceLeaky(std.json.Value, arena, std.mem.trim(u8, line, " \t\r"), .{
        .parse_numbers = false,
        .duplicate_field_behavior = .use_last,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (root != .object) return null;
    const new_val: std.json.Value = .{ .string = new_id };
    var changed = false;
    switch (format) {
        .claude_code => changed = replaceStr(&root.object, "sessionId", new_val),
        .codex => {
            const t = if (root.object.get("type")) |v| (if (v == .string) v.string else "") else "";
            if (std.mem.eql(u8, t, "session_meta")) {
                if (root.object.getPtr("payload")) |p| if (p.* == .object) {
                    changed = replaceStr(&p.object, "id", new_val);
                };
            } else if (root.object.get("payload") == null and t.len == 0) {
                changed = replaceStr(&root.object, "id", new_val);
            }
        },
        .pi => {
            const t = if (root.object.get("type")) |v| (if (v == .string) v.string else "") else "";
            if (std.mem.eql(u8, t, "session") or std.mem.eql(u8, t, "session_meta"))
                changed = replaceStr(&root.object, "id", new_val);
            if (replaceStr(&root.object, "sessionId", new_val)) changed = true;
            if (replaceStr(&root.object, "session_id", new_val)) changed = true;
        },
    }
    if (!changed) return null;
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(root, .{}, &aw.writer) catch return error.OutOfMemory;
    return aw.written();
}

fn replaceStr(obj: *std.json.ObjectMap, key: []const u8, v: std.json.Value) bool {
    const p = obj.getPtr(key) orelse return false;
    if (p.* != .string) return false;
    p.* = v;
    return true;
}

/// Base name of the forked transcript. Claude Code: `<id>.jsonl` (same
/// project directory). Codex: `rollout-YYYY-MM-DDThh-mm-ss-<id>.jsonl` (under
/// `sessions/YYYY/MM/DD/`, see `codexDayDir`). Others: `<id>.jsonl` beside
/// the original.
pub fn forkFileName(gpa: Allocator, format: Format, new_id: []const u8, now_ms: i64) Allocator.Error![]u8 {
    if (format != .codex) return std.fmt.allocPrint(gpa, "{s}.jsonl", .{new_id});
    const t = splitTime(now_ms);
    return std.fmt.allocPrint(gpa, "rollout-{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}-{d:0>2}-{d:0>2}-{s}.jsonl", .{
        t.year, t.month, t.day, t.hour, t.minute, t.second, new_id,
    });
}

/// Codex day directory relative to `$CODEX_HOME/sessions` (`YYYY/MM/DD`).
pub fn codexDayDir(gpa: Allocator, now_ms: i64) Allocator.Error![]u8 {
    const t = splitTime(now_ms);
    return std.fmt.allocPrint(gpa, "{d:0>4}/{d:0>2}/{d:0>2}", .{ t.year, t.month, t.day });
}

const SplitTime = struct { year: u64, month: u8, day: u8, hour: u64, minute: u64, second: u64 };

fn splitTime(ms: i64) SplitTime {
    const secs = @divFloor(ms, 1000);
    const days = @divFloor(secs, 86400);
    const rem: u64 = @intCast(secs - days * 86400);
    const c = index.civilFromDays(days);
    return .{
        .year = @intCast(@max(c.year, 0)),
        .month = c.month,
        .day = c.day,
        .hour = rem / 3600,
        .minute = rem / 60 % 60,
        .second = rem % 60,
    };
}
