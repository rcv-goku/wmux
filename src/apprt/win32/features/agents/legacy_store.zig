//! Pure-logic store mapping a surface to the agent running in it and that
//! agent's *native* session id, so a workspace can be relaunched with the
//! agent's own resume command (`claude --resume <id>`, `codex resume
//! <id>`, `opencode -s <id>`, `gemini --resume <id>`, ...). This module
//! is deliberately free of any HWND / IPC / Win32 dependency: it is the
//! data model + (de)serialization only, so it compiles and unit-tests on
//! any target with a plain `zig test`. The orchestration layer (App /
//! ipc.zig) owns the wiring that feeds it; see
//! `agent-orchestration-design.md`.
//!
//! Capture path (design, not wired here): `ghostty +hooks setup` installs
//! a per-agent hook that, when the agent starts/resumes, calls back into
//! the running Ghostty over the existing `ghostty-ipc-<pid>` pipe with the
//! agent kind + the session id the hook reads from its own stdin payload
//! (Claude Code/Codex `SessionStart` JSON `session_id`; Gemini/OpenCode
//! from their resume metadata). The IPC handler calls `Store.put` keyed by
//! the calling surface. Relaunch reads `Store.get` and replays
//! `AgentKind.resumeArgv`.
//!
//! Identity & lifetime: a "surface id" here is an opaque stable u64 the
//! caller assigns to a terminal surface (e.g. a monotonically increasing
//! counter, mirroring BrowserPane.ipc_id). The store never dereferences
//! it; it only compares for equality, so the pure tests need no live
//! surface. Session-id strings are owned heap copies (dupe on put, free on
//! overwrite / remove / deinit).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Hard cap on a stored session-id string. Every agent's id is a UUID or a
/// short token well under this; the cap bounds memory and rejects a
/// hostile hook payload before it is duped.
pub const max_session_id_len: usize = 256;

/// Agents whose native session-resume we know how to drive. The tag names
/// are the stable wire identifiers the hook callback sends over IPC
/// (`{"agent":"claude_code",...}`), so renaming a tag is a protocol
/// change. Ordered roughly by integration confidence (see the design
/// doc's feasibility table). `unknown` is the fallback for an agent we can
/// store an id for but have no resume recipe — the sidebar can still show
/// "session captured" without offering one-click resume.
pub const AgentKind = enum {
    claude_code,
    codex,
    opencode,
    gemini,
    aider,
    unknown,

    /// Parse the wire identifier (the IPC `agent` field / the
    /// `+hooks setup <agent>` positional). Unrecognized names map to
    /// `.unknown` rather than erroring so a newer hook script naming an
    /// agent this build predates still stores its id.
    pub fn parse(name: []const u8) AgentKind {
        return std.meta.stringToEnum(AgentKind, name) orelse .unknown;
    }

    /// The executable name to relaunch this agent with. Caller resolves it
    /// on PATH. Null for `.unknown` (no known resume recipe).
    pub fn exe(self: AgentKind) ?[]const u8 {
        return switch (self) {
            .claude_code => "claude",
            .codex => "codex",
            .opencode => "opencode",
            .gemini => "gemini",
            .aider => "aider",
            .unknown => null,
        };
    }

    /// Write the full relaunch argv (including the exe at argv[0]) for
    /// resuming `session_id` into `out`, returning the number of slots
    /// used. The slices borrow `self.exe()` (static) and `session_id`
    /// (caller-owned), so they are valid only as long as `session_id` is.
    /// `out` must have room for `max_resume_argv` entries. Returns
    /// `error.NoResumeRecipe` for `.unknown`.
    ///
    /// The recipes encode each vendor's documented resume syntax:
    ///   claude  --resume <id>      (id scoped to the original cwd)
    ///   codex   resume <id>        (id is a UUID)
    ///   opencode -s <id>
    ///   gemini  --resume <id>
    ///   aider   --restore-chat-history   (no per-id selector; cwd-scoped)
    pub fn resumeArgv(
        self: AgentKind,
        session_id: []const u8,
        out: *[max_resume_argv][]const u8,
    ) error{NoResumeRecipe}!usize {
        const e = self.exe() orelse return error.NoResumeRecipe;
        switch (self) {
            .claude_code, .gemini => {
                out[0] = e;
                out[1] = "--resume";
                out[2] = session_id;
                return 3;
            },
            .codex => {
                out[0] = e;
                out[1] = "resume";
                out[2] = session_id;
                return 3;
            },
            .opencode => {
                out[0] = e;
                out[1] = "-s";
                out[2] = session_id;
                return 3;
            },
            .aider => {
                // Aider has no resume-by-id selector; it restores the most
                // recent chat history for the cwd. session_id is retained
                // for display/bookkeeping but not passed.
                out[0] = e;
                out[1] = "--restore-chat-history";
                return 2;
            },
            .unknown => unreachable, // exe() already returned null above
        }
    }
};

/// Upper bound on slots `resumeArgv` writes (exe + subcommand/flag + id).
pub const max_resume_argv: usize = 4;

/// One captured association: which agent runs in a surface and its native
/// session id. `session_id` is an owned heap slice.
pub const Entry = struct {
    surface_id: u64,
    agent: AgentKind,
    session_id: []const u8,
};

/// The store: a flat list of entries keyed by surface_id. A surface holds
/// at most one live agent association at a time (a re-`put` for the same
/// surface replaces it — e.g. the agent resumed and reported a new id, or
/// a different agent took over the pane). Flat-array lookup is fine: the
/// table is bounded by the number of open terminal surfaces (tens at
/// most), and every access is O(n) over a handful of entries.
pub const Store = struct {
    alloc: Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(alloc: Allocator) Store {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |e| self.alloc.free(e.session_id);
        self.entries.deinit(self.alloc);
        self.* = undefined;
    }

    /// Record (or replace) the agent + session id for `surface_id`. Dupes
    /// `session_id`. Rejects an oversized id (a hostile/garbled hook
    /// payload) with `error.SessionIdTooLong` before allocating. Replacing
    /// an existing entry frees the old id first.
    pub fn put(
        self: *Store,
        surface_id: u64,
        agent: AgentKind,
        session_id: []const u8,
    ) error{ OutOfMemory, SessionIdTooLong }!void {
        if (session_id.len > max_session_id_len) return error.SessionIdTooLong;
        const owned = try self.alloc.dupe(u8, session_id);
        errdefer self.alloc.free(owned);

        if (self.find(surface_id)) |e| {
            self.alloc.free(e.session_id);
            e.agent = agent;
            e.session_id = owned;
            return;
        }
        try self.entries.append(self.alloc, .{
            .surface_id = surface_id,
            .agent = agent,
            .session_id = owned,
        });
    }

    /// The live entry for `surface_id`, or null. The returned pointer is
    /// invalidated by any subsequent put/remove (the backing array may
    /// move); read it before mutating.
    pub fn find(self: *Store, surface_id: u64) ?*Entry {
        for (self.entries.items) |*e| {
            if (e.surface_id == surface_id) return e;
        }
        return null;
    }

    /// Read-only view of the entry for `surface_id`, or null.
    pub fn get(self: *const Store, surface_id: u64) ?Entry {
        for (self.entries.items) |e| {
            if (e.surface_id == surface_id) return e;
        }
        return null;
    }

    /// Drop the association for `surface_id` (the surface closed, or the
    /// agent exited without a resumable session). Idempotent; returns true
    /// if an entry was removed. Uses swapRemove because order is
    /// irrelevant — entries are addressed by surface_id, never by index.
    pub fn remove(self: *Store, surface_id: u64) bool {
        for (self.entries.items, 0..) |e, i| {
            if (e.surface_id == surface_id) {
                self.alloc.free(e.session_id);
                _ = self.entries.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn count(self: *const Store) usize {
        return self.entries.items.len;
    }

    /// Serialize the whole store to a JSON array
    /// `[{"surface":N,"agent":"...","session":"..."}]`, suitable for
    /// persisting across a Ghostty restart (session-resume survives the
    /// terminal closing) and for the `read`-back path. Caller owns the
    /// returned slice. Stable field order so the output is diffable.
    pub fn serialize(self: *const Store, alloc: Allocator) Allocator.Error![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try w.writeByte('[');
        for (self.entries.items, 0..) |e, i| {
            if (i > 0) try w.writeByte(',');
            try w.print(
                "{{\"surface\":{d},\"agent\":\"{s}\",\"session\":{f}}}",
                .{ e.surface_id, @tagName(e.agent), std.json.fmt(e.session_id, .{}) },
            );
        }
        try w.writeByte(']');
        return buf.toOwnedSlice(alloc);
    }

    /// Parse a previously-serialized array back into a fresh store. Skips
    /// malformed entries (missing/wrong-typed fields, oversized ids)
    /// rather than failing the whole load, so one corrupt record can't
    /// wipe a restored session map; a count mismatch vs the input is the
    /// caller's signal that something was dropped. An unrecognized agent
    /// name loads as `.unknown` (id still retained). Returns a store the
    /// caller must `deinit`.
    pub fn parse(alloc: Allocator, json: []const u8) error{ OutOfMemory, InvalidJson }!Store {
        var store = Store.init(alloc);
        errdefer store.deinit();

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJson,
        };
        defer parsed.deinit();

        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return error.InvalidJson,
        };

        for (arr.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const surface: u64 = switch (obj.get("surface") orelse continue) {
                .integer => |n| if (n >= 0) @intCast(n) else continue,
                else => continue,
            };
            const agent_name = switch (obj.get("agent") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const session = switch (obj.get("session") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            store.put(surface, AgentKind.parse(agent_name), session) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Oversized id: drop this record, keep the rest.
                error.SessionIdTooLong => continue,
            };
        }
        return store;
    }
};

// ---------------------------------------------------------------------------
// Tests (pure; run with: zig test src/apprt/win32/agent_session.zig)
// ---------------------------------------------------------------------------

test "agent_session: AgentKind.parse maps known and unknown names" {
    try testing.expectEqual(AgentKind.claude_code, AgentKind.parse("claude_code"));
    try testing.expectEqual(AgentKind.codex, AgentKind.parse("codex"));
    try testing.expectEqual(AgentKind.gemini, AgentKind.parse("gemini"));
    try testing.expectEqual(AgentKind.unknown, AgentKind.parse("rovodev"));
    try testing.expectEqual(AgentKind.unknown, AgentKind.parse(""));
}

test "agent_session: resumeArgv encodes each vendor's resume syntax" {
    var out: [max_resume_argv][]const u8 = undefined;

    var n = try AgentKind.claude_code.resumeArgv("abc123", &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("claude", out[0]);
    try testing.expectEqualStrings("--resume", out[1]);
    try testing.expectEqualStrings("abc123", out[2]);

    n = try AgentKind.codex.resumeArgv("550e8400-e29b-41d4-a716-446655440000", &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("codex", out[0]);
    try testing.expectEqualStrings("resume", out[1]);

    n = try AgentKind.opencode.resumeArgv("sess_xyz", &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("opencode", out[0]);
    try testing.expectEqualStrings("-s", out[1]);

    n = try AgentKind.gemini.resumeArgv("uuid", &out);
    try testing.expectEqualStrings("gemini", out[0]);
    try testing.expectEqualStrings("--resume", out[1]);

    // Aider resumes by cwd, not id: 2 slots, no id passed.
    n = try AgentKind.aider.resumeArgv("ignored", &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("aider", out[0]);
    try testing.expectEqualStrings("--restore-chat-history", out[1]);

    try testing.expectError(error.NoResumeRecipe, AgentKind.unknown.resumeArgv("x", &out));
}

test "agent_session: put / get round-trips and owns the id" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // Pass a buffer that we then mutate to prove the store duped the id.
    var idbuf = [_]u8{ 'a', 'b', 'c' };
    try store.put(7, .claude_code, &idbuf);
    idbuf[0] = 'Z';

    const e = store.get(7).?;
    try testing.expectEqual(AgentKind.claude_code, e.agent);
    try testing.expectEqualStrings("abc", e.session_id);
    try testing.expectEqual(@as(usize, 1), store.count());
    try testing.expect(store.get(8) == null);
}

test "agent_session: re-put replaces agent + id without leaking" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.put(1, .claude_code, "first");
    try store.put(1, .codex, "second"); // overwrite same surface
    try testing.expectEqual(@as(usize, 1), store.count());

    const e = store.get(1).?;
    try testing.expectEqual(AgentKind.codex, e.agent);
    try testing.expectEqualStrings("second", e.session_id);
    // (testing.allocator fails the test on any leak from the freed "first".)
}

test "agent_session: remove is idempotent and frees" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.put(1, .gemini, "g1");
    try store.put(2, .aider, "a1");
    try testing.expect(store.remove(1));
    try testing.expect(!store.remove(1)); // already gone
    try testing.expectEqual(@as(usize, 1), store.count());
    try testing.expect(store.get(2) != null);
}

test "agent_session: put rejects an oversized session id" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const big = [_]u8{'x'} ** (max_session_id_len + 1);
    try testing.expectError(error.SessionIdTooLong, store.put(1, .codex, &big));
    try testing.expectEqual(@as(usize, 0), store.count());

    // Exactly at the cap is accepted.
    const at_cap = [_]u8{'y'} ** max_session_id_len;
    try store.put(1, .codex, &at_cap);
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "agent_session: serialize escapes and round-trips through parse" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.put(3, .claude_code, "id-with-\"quote\"");
    try store.put(10, .unknown, "kept-even-though-unknown");

    const json = try store.serialize(testing.allocator);
    defer testing.allocator.free(json);

    var restored = try Store.parse(testing.allocator, json);
    defer restored.deinit();

    try testing.expectEqual(store.count(), restored.count());
    try testing.expectEqualStrings(
        "id-with-\"quote\"",
        restored.get(3).?.session_id,
    );
    try testing.expectEqual(AgentKind.claude_code, restored.get(3).?.agent);
    try testing.expectEqual(AgentKind.unknown, restored.get(10).?.agent);
}

test "agent_session: parse skips malformed records but keeps valid ones" {
    const json =
        \\[
        \\  {"surface":1,"agent":"codex","session":"good"},
        \\  {"surface":-2,"agent":"codex","session":"neg-surface"},
        \\  {"surface":3,"session":"missing-agent"},
        \\  {"agent":"codex","session":"missing-surface"},
        \\  {"surface":4,"agent":42,"session":"bad-agent-type"},
        \\  {"surface":5,"agent":"gemini","session":"also-good"}
        \\]
    ;
    var store = try Store.parse(testing.allocator, json);
    defer store.deinit();

    try testing.expectEqual(@as(usize, 2), store.count());
    try testing.expectEqualStrings("good", store.get(1).?.session_id);
    try testing.expectEqualStrings("also-good", store.get(5).?.session_id);
}

test "agent_session: parse rejects non-array top level" {
    try testing.expectError(error.InvalidJson, Store.parse(testing.allocator, "{}"));
    try testing.expectError(error.InvalidJson, Store.parse(testing.allocator, "not json"));
}

test "agent_session: empty store serializes to []" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    const json = try store.serialize(testing.allocator);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("[]", json);
}
