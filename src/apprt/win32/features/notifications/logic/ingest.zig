//! Notification ingestion (ADR-7.3): OSC 9 / OSC 99 (kitty) / OSC 777 field
//! mapping, kitty `i=` chunk reassembly, per-surface coalescing, the bounded
//! drop-oldest ingress FIFO and routing of an ingress entry to a store
//! record. Pure: inputs are OSC payload bytes (after `<number>;`) and UUIDs.

const std = @import("std");
const store_mod = @import("store.zig");
const text = @import("text.zig");

const Uuid = store_mod.Uuid;
const Record = store_mod.Record;
const uuidEql = store_mod.uuidEql;

/// Heap payload caps (bytes, cut on code points).
pub const title_cap: usize = 1024;
pub const subtitle_cap: usize = 1024;
pub const body_cap: usize = 8 * 1024;
pub const fifo_capacity: usize = 256;
pub const coalesce_window_ms: i64 = 1000;
/// Bound on concurrently reassembled kitty notifications (all surfaces).
pub const max_pending_kitty: usize = 64;
/// Longest kept kitty `i=` identifier.
pub const kitty_id_cap: usize = 64;
pub const default_title = "Terminal";

/// Borrowed notification text from one OSC sequence.
pub const Fields = struct {
    title: []const u8 = "",
    subtitle: []const u8 = "",
    body: []const u8 = "",
};

// --------------------------------------------------------------- OSC 777

/// `777;notify;<title>;<body>`: `payload` is everything after `777;`. As in
/// the core parser (`src/terminal/osc/parsers/rxvt_extension.zig`) both
/// separators are required; the body may be empty and keeps any further
/// `;`. Other 777 extensions return null.
pub fn parseOsc777(payload: []const u8) ?Fields {
    const prefix = "notify;";
    if (!std.mem.startsWith(u8, payload, prefix)) return null;
    const rest = payload[prefix.len..];
    const semi = std.mem.indexOfScalar(u8, rest, ';') orelse return null;
    return .{ .title = rest[0..semi], .body = rest[semi + 1 ..] };
}

// ----------------------------------------------------------------- OSC 9

/// `9;<text>`: the text is the body with an empty title (the fallback title
/// applies at delivery); empty text is no notification. ConEmu extensions
/// are not notifications: `isConEmuOsc9` mirrors the core parser's routing.
pub fn parseOsc9(payload: []const u8) ?Fields {
    if (payload.len == 0 or isConEmuOsc9(payload)) return null;
    return .{ .body = payload };
}

/// The ConEmu forms that the core parser (`src/terminal/osc/parsers/osc9.zig`)
/// routes away from notifications, so both paths agree: `1;` sleep, `10` and
/// `10;0`..`10;3` emulation, `11;` comment, `12` prompt, `2;` message box,
/// `3;` tab title, `4;0`..`4;4` progress, `5` wait, `6;` GUI macro, `7;` run,
/// `8;` environment, `9;` cwd. Everything else (`1`, `4`, `4;9`, `13;x`) is
/// notification text.
fn isConEmuOsc9(p: []const u8) bool {
    const semi = p.len >= 2 and p[1] == ';';
    return switch (p[0]) {
        '1' => p.len >= 2 and switch (p[1]) {
            ';', '2' => true,
            '0' => p.len == 2 or (p.len >= 4 and p[2] == ';' and p[3] >= '0' and p[3] <= '3'),
            '1' => p.len >= 3 and p[2] == ';',
            else => false,
        },
        '2', '3', '6', '7', '8', '9' => semi,
        '4' => semi and p.len >= 3 and p[2] >= '0' and p[2] <= '4',
        '5' => true,
        else => false,
    };
}

// ---------------------------------------------------------------- OSC 99

pub const KittyPayload = enum { title, body, subtitle, query, control };

pub const KittyChunk = struct {
    /// `i=` value; empty when absent.
    id: []const u8 = "",
    /// `d=`; defaults to done.
    done: bool = true,
    base64: bool = false,
    payload_type: KittyPayload = .title,
    /// Raw payload (still base64 when `base64`).
    payload: []const u8 = "",
};

/// Parses `99;<metadata>;<payload>`; `payload` is everything after `99;`.
/// Metadata `k=v` pairs may be separated by `:` (kitty) or `;` (cmux docs),
/// and the payload may follow either separator. Never fails: unknown keys are
/// ignored and text that is not a `k=v` pair starts the payload.
pub fn parseOsc99(payload: []const u8) KittyChunk {
    var chunk: KittyChunk = .{};
    var pos: usize = 0;
    while (pos < payload.len) {
        const sep = std.mem.indexOfAnyPos(u8, payload, pos, ":;") orelse break;
        const token = payload[pos..sep];
        if (token.len != 0 and !isMetadataPair(token)) break;
        if (token.len != 0) applyMetadata(&chunk, token[0], token[2..]);
        pos = sep + 1;
    }
    chunk.payload = payload[pos..];
    return chunk;
}

fn isMetadataPair(token: []const u8) bool {
    if (token.len < 2 or token[1] != '=' or !std.ascii.isAlphabetic(token[0])) return false;
    for (token[2..]) |c| {
        const ok = std.ascii.isAlphanumeric(c) or switch (c) {
            '-', '_', ',', '?', '.', '+', '/', '=' => true,
            else => false,
        };
        if (!ok) return false;
    }
    return true;
}

fn applyMetadata(chunk: *KittyChunk, key: u8, value: []const u8) void {
    switch (key) {
        'i' => chunk.id = value,
        'd' => chunk.done = !std.mem.eql(u8, value, "0"),
        'e' => chunk.base64 = std.mem.eql(u8, value, "1"),
        'p' => chunk.payload_type = if (std.mem.eql(u8, value, "title"))
            .title
        else if (std.mem.eql(u8, value, "body"))
            .body
        else if (std.mem.eql(u8, value, "subtitle"))
            .subtitle
        else if (std.mem.eql(u8, value, "?"))
            .query
        else
            .control,
        else => {},
    }
}

/// Decodes a base64 payload; when decoding fails or does not yield valid
/// UTF-8, returns a copy of the raw text (cmux docs send `e=1` with plain
/// text, and a plain word like "Done" is also valid base64).
pub fn decodePayloadAlloc(gpa: std.mem.Allocator, chunk: KittyChunk) ![]u8 {
    if (!chunk.base64) return gpa.dupe(u8, chunk.payload);
    const trimmed = std.mem.trim(u8, chunk.payload, " \t\r\n");
    inline for (.{ std.base64.standard.Decoder, std.base64.standard_no_pad.Decoder }) |dec| {
        if (dec.calcSizeForSlice(trimmed)) |n| {
            const buf = try gpa.alloc(u8, n);
            if (dec.decode(buf, trimmed)) |_| {
                if (std.unicode.utf8ValidateSlice(buf)) return buf;
                gpa.free(buf);
            } else |_| gpa.free(buf);
        } else |_| {}
    }
    return gpa.dupe(u8, chunk.payload);
}

/// Owned, sanitized and capped notification text.
pub const OwnedFields = struct {
    title: []u8,
    subtitle: []u8,
    body: []u8,

    pub fn init(gpa: std.mem.Allocator, f: Fields) !OwnedFields {
        const title = try text.sanitizeAlloc(gpa, f.title, title_cap);
        errdefer gpa.free(title);
        const subtitle = try text.sanitizeAlloc(gpa, f.subtitle, subtitle_cap);
        errdefer gpa.free(subtitle);
        const body = try text.sanitizeAlloc(gpa, f.body, body_cap);
        return .{ .title = title, .subtitle = subtitle, .body = body };
    }

    pub fn deinit(self: *OwnedFields, gpa: std.mem.Allocator) void {
        gpa.free(self.title);
        gpa.free(self.subtitle);
        gpa.free(self.body);
        self.* = undefined;
    }

    pub fn fields(self: OwnedFields) Fields {
        return .{ .title = self.title, .subtitle = self.subtitle, .body = self.body };
    }
};

pub const KittyComplete = struct {
    /// Owned copy of the `i=` id (empty when absent).
    id: []u8,
    fields: OwnedFields,

    pub fn deinit(self: *KittyComplete, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        self.fields.deinit(gpa);
        self.* = undefined;
    }
};

/// Reassembles kitty chunks per (surface, i=) until `d=1`. Chunks of the
/// same payload type append. Bounded: the oldest pending entry is dropped.
pub const KittyAssembler = struct {
    const Pending = struct {
        surface: Uuid,
        id: []u8,
        title: std.ArrayList(u8) = .empty,
        subtitle: std.ArrayList(u8) = .empty,
        body: std.ArrayList(u8) = .empty,

        fn deinit(self: *Pending, gpa: std.mem.Allocator) void {
            gpa.free(self.id);
            self.title.deinit(gpa);
            self.subtitle.deinit(gpa);
            self.body.deinit(gpa);
        }
    };

    gpa: std.mem.Allocator,
    /// Oldest first.
    pending: std.ArrayList(Pending) = .empty,
    dropped: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) KittyAssembler {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *KittyAssembler) void {
        for (self.pending.items) |*p| p.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.* = undefined;
    }

    /// Feeds one chunk. Returns a complete notification on `d=1` when it
    /// carries any title/subtitle/body text; queries and control payloads
    /// produce nothing (a control chunk with `d=1` still ends the entry).
    pub fn feed(self: *KittyAssembler, surface: Uuid, chunk: KittyChunk) !?KittyComplete {
        const id = text.truncateUtf8(chunk.id, kitty_id_cap);
        if (chunk.payload_type == .query) return null;
        const idx = self.find(surface, id) orelse blk: {
            if (chunk.done and chunk.payload_type == .control) return null;
            if (self.pending.items.len >= max_pending_kitty) {
                var old = self.pending.orderedRemove(0);
                old.deinit(self.gpa);
                self.dropped += 1;
            }
            const owned_id = try self.gpa.dupe(u8, id);
            errdefer self.gpa.free(owned_id);
            try self.pending.append(self.gpa, .{ .surface = surface, .id = owned_id });
            break :blk self.pending.items.len - 1;
        };
        const p = &self.pending.items[idx];
        if (chunk.payload_type != .control) {
            const decoded = try decodePayloadAlloc(self.gpa, chunk);
            defer self.gpa.free(decoded);
            const target, const cap = switch (chunk.payload_type) {
                .title => .{ &p.title, title_cap },
                .subtitle => .{ &p.subtitle, subtitle_cap },
                else => .{ &p.body, body_cap },
            };
            // Keep up to cap + 3 raw bytes so the final cut lands on a code point.
            const room = (cap + 3) -| target.items.len;
            try target.appendSlice(self.gpa, decoded[0..@min(room, decoded.len)]);
        }
        if (!chunk.done) return null;

        var done = self.pending.orderedRemove(idx);
        defer done.deinit(self.gpa);
        if (done.title.items.len == 0 and done.subtitle.items.len == 0 and done.body.items.len == 0) return null;
        var f = try OwnedFields.init(self.gpa, .{
            .title = done.title.items,
            .subtitle = done.subtitle.items,
            .body = done.body.items,
        });
        errdefer f.deinit(self.gpa);
        const out_id = try self.gpa.dupe(u8, done.id);
        return .{ .id = out_id, .fields = f };
    }

    fn find(self: *const KittyAssembler, surface: Uuid, id: []const u8) ?usize {
        for (self.pending.items, 0..) |p, i| {
            if (uuidEql(p.surface, surface) and std.mem.eql(u8, p.id, id)) return i;
        }
        return null;
    }

    /// Drops partial notifications of a closed surface.
    pub fn forgetSurface(self: *KittyAssembler, surface: Uuid) void {
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (uuidEql(self.pending.items[i].surface, surface)) {
                var p = self.pending.orderedRemove(i);
                p.deinit(self.gpa);
            } else i += 1;
        }
    }
};

// ------------------------------------------------------------ coalescing

/// Per-surface coalescing: an identical title+body from the same surface
/// within `coalesce_window_ms` of the last delivered one collapses.
pub const Coalescer = struct {
    const Last = struct { hash: u64, at_ms: i64 };

    gpa: std.mem.Allocator,
    last: std.AutoHashMapUnmanaged(Uuid, Last) = .empty,

    pub fn init(gpa: std.mem.Allocator) Coalescer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Coalescer) void {
        self.last.deinit(self.gpa);
        self.* = undefined;
    }

    fn hashText(title: []const u8, body: []const u8) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&title.len));
        h.update(title);
        h.update(body);
        return h.final();
    }

    /// True when the notification should be delivered (and records it). A
    /// clock that jumps backwards never suppresses.
    pub fn admit(self: *Coalescer, surface: Uuid, title: []const u8, body: []const u8, now_ms: i64) !bool {
        const hash = hashText(title, body);
        if (self.last.get(surface)) |l| {
            const dt = now_ms -| l.at_ms;
            if (l.hash == hash and dt >= 0 and dt < coalesce_window_ms) return false;
        }
        if (self.last.count() >= 1024) self.prune(now_ms);
        try self.last.put(self.gpa, surface, .{ .hash = hash, .at_ms = now_ms });
        return true;
    }

    fn prune(self: *Coalescer, now_ms: i64) void {
        var it = self.last.iterator();
        var stale: [64]Uuid = undefined;
        var n: usize = 0;
        while (it.next()) |e| {
            if (n == stale.len) break;
            if (now_ms -| e.value_ptr.at_ms >= coalesce_window_ms) {
                stale[n] = e.key_ptr.*;
                n += 1;
            }
        }
        for (stale[0..n]) |k| _ = self.last.remove(k);
    }

    pub fn forgetSurface(self: *Coalescer, surface: Uuid) void {
        _ = self.last.remove(surface);
    }
};

// ------------------------------------------------------------ ingress FIFO

pub const IngressOrigin = store_mod.Origin;

pub const Kitty = struct {
    id: []u8,
    done: bool,
};

/// One pending notification: owned, sanitized, capped. The workspace is
/// resolved at delivery time from `surface`.
pub const Entry = struct {
    surface: Uuid,
    fields: OwnedFields,
    kitty: ?Kitty = null,
    origin: IngressOrigin = .local,

    pub fn create(gpa: std.mem.Allocator, surface: Uuid, f: Fields, kitty_id: ?[]const u8, origin: IngressOrigin) !Entry {
        var owned = try OwnedFields.init(gpa, f);
        errdefer owned.deinit(gpa);
        const k: ?Kitty = if (kitty_id) |id| .{
            .id = try gpa.dupe(u8, text.truncateUtf8(id, kitty_id_cap)),
            .done = true,
        } else null;
        return .{ .surface = surface, .fields = owned, .kitty = k, .origin = origin };
    }

    /// Takes ownership of an assembled kitty notification.
    pub fn fromKitty(surface: Uuid, k: KittyComplete, origin: IngressOrigin) Entry {
        return .{ .surface = surface, .fields = k.fields, .kitty = .{ .id = k.id, .done = true }, .origin = origin };
    }

    pub fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
        self.fields.deinit(gpa);
        if (self.kitty) |k| gpa.free(k.id);
        self.* = undefined;
    }
};

/// Bounded FIFO between the terminal threads (push) and the UI thread (pop).
/// When full, the OLDEST entry is dropped so a flood keeps the newest.
pub const Fifo = struct {
    gpa: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    buf: []?Entry,
    head: usize = 0,
    len: usize = 0,
    /// Entries dropped because the FIFO was full; read it with
    /// `droppedCount` while producers may run.
    dropped: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, capacity: usize) !Fifo {
        const buf = try gpa.alloc(?Entry, @max(capacity, 1));
        @memset(buf, null);
        return .{ .gpa = gpa, .buf = buf };
    }

    pub fn deinit(self: *Fifo) void {
        for (self.buf) |*slot| {
            if (slot.*) |*e| e.deinit(self.gpa);
        }
        self.gpa.free(self.buf);
        self.* = undefined;
    }

    /// Takes ownership of `entry`. Returns true when an older entry was dropped.
    pub fn push(self: *Fifo, entry: Entry) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var dropped_one = false;
        if (self.len == self.buf.len) {
            if (self.buf[self.head]) |*old| old.deinit(self.gpa);
            self.buf[self.head] = null;
            self.head = (self.head + 1) % self.buf.len;
            self.len -= 1;
            self.dropped += 1;
            dropped_one = true;
        }
        self.buf[(self.head + self.len) % self.buf.len] = entry;
        self.len += 1;
        return dropped_one;
    }

    /// Oldest entry; the caller owns it.
    pub fn pop(self: *Fifo) ?Entry {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == 0) return null;
        const e = self.buf[self.head].?;
        self.buf[self.head] = null;
        self.head = (self.head + 1) % self.buf.len;
        self.len -= 1;
        return e;
    }

    pub fn count(self: *Fifo) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.len;
    }

    pub fn droppedCount(self: *Fifo) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.dropped;
    }

    /// Discards everything pending (Clear All drops queued notifications).
    pub fn clear(self: *Fifo) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.len > 0) {
            if (self.buf[self.head]) |*e| e.deinit(self.gpa);
            self.buf[self.head] = null;
            self.head = (self.head + 1) % self.buf.len;
            self.len -= 1;
        }
    }
};

// --------------------------------------------------------------- routing

/// Empty title -> workspace title -> "Terminal".
pub fn resolveTitle(title: []const u8, workspace_title: []const u8) []const u8 {
    if (std.mem.trim(u8, title, " \t\n").len != 0) return title;
    if (std.mem.trim(u8, workspace_title, " \t\n").len != 0) return workspace_title;
    return default_title;
}

pub const Attention = enum { ring, clear };

/// wmux extension: an OSC whose title or body is exactly
/// `@ghostty-attention:ring` / `@ghostty-attention:clear` (maps to manual
/// unread on the surface instead of a record).
pub fn attentionSentinel(f: Fields) ?Attention {
    for ([_][]const u8{ f.body, f.title }) |s| {
        const t = std.mem.trim(u8, s, " \t\r\n");
        if (std.mem.eql(u8, t, "@ghostty-attention:ring")) return .ring;
        if (std.mem.eql(u8, t, "@ghostty-attention:clear")) return .clear;
    }
    return null;
}

/// What the UI thread learned when it resolved the entry's surface.
pub const Route = struct {
    /// The surface's CURRENT workspace (a moved pane notifies its new one).
    workspace: Uuid,
    workspace_title: []const u8 = "",
    /// Fresh record id and timestamp.
    id: Uuid,
    now_ms: i64,
    /// The surface has a live hook-integrated agent session: raw OSC
    /// notifications are suppressed (the hook bridge covers them).
    agent_hooked: bool = false,
};

pub const Delivery = union(enum) {
    /// Borrowed from the entry: add it to the store before freeing the entry.
    record: Record,
    attention: struct { workspace: Uuid, surface: Uuid, on: bool },
    suppressed,
};

pub fn route(entry: *const Entry, r: Route) Delivery {
    const f = entry.fields.fields();
    if (attentionSentinel(f)) |a| return .{ .attention = .{
        .workspace = r.workspace,
        .surface = entry.surface,
        .on = a == .ring,
    } };
    if (r.agent_hooked) return .suppressed;
    return .{ .record = .{
        .id = r.id,
        .workspace = r.workspace,
        .surface = entry.surface,
        .title = resolveTitle(f.title, r.workspace_title),
        .subtitle = f.subtitle,
        .body = f.body,
        .created_at_ms = r.now_ms,
        .origin = entry.origin,
    } };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const testUuid = store_mod.testUuid;
const sf = testUuid(0x51);
const sf2 = testUuid(0x52);

test "unit: notifications: osc 777 maps title and body" {
    const f = parseOsc777("notify;My Title;Message body here").?;
    try testing.expectEqualStrings("My Title", f.title);
    try testing.expectEqualStrings("Message body here", f.body);
    const g = parseOsc777("notify;T;a;b;c").?;
    try testing.expectEqualStrings("a;b;c", g.body);
    const t = parseOsc777("notify;T;").?;
    try testing.expectEqualStrings("T", t.title);
    try testing.expectEqualStrings("", t.body);
    const e = parseOsc777("notify;;").?;
    try testing.expectEqualStrings("", e.title);
    try testing.expectEqualStrings("", e.body);
    // Like the core parser: both separators are required.
    try testing.expect(parseOsc777("notify;OnlyTitle") == null);
    try testing.expect(parseOsc777("notify") == null);
    try testing.expect(parseOsc777("notify;") == null);
    try testing.expect(parseOsc777("Notify;T;B") == null);
    try testing.expect(parseOsc777("precmd") == null);
    try testing.expect(parseOsc777("") == null);
    try testing.expectEqualStrings("\u{1F680} \u{00E9}t\u{00E9}", parseOsc777("notify;\u{1F680} \u{00E9}t\u{00E9};x").?.title);
}

test "unit: notifications: osc 9 text is a body, conemu subcommands are not notifications" {
    const f = parseOsc9("Build finished").?;
    try testing.expectEqualStrings("", f.title);
    try testing.expectEqualStrings("Build finished", f.body);
    try testing.expect(parseOsc9("") == null);
    // Routed away by the core parser (src/terminal/osc/parsers/osc9.zig).
    const conemu = [_][]const u8{
        "1;",  "1;420",   "10",    "10;0",      "10;3",   "11;note", "12", "12x",
        "2;m", "3;",      "3;tab", "4;0",       "4;1;50", "4;4",     "5",  "5 tests",
        "6;m", "7;a.exe", "8;VAR", "9;C:\\src",
    };
    for (conemu) |p| try testing.expectEqual(@as(?Fields, null), parseOsc9(p));
    // Text the core parser delivers as a notification body.
    const bodies = [_][]const u8{
        "1", "1 test failed", "10;", "10;4", "100", "11", "13;x", "2",
        "3", "4",             "4;",  "4;5",  "6",   "9",  "0",    "\u{1F680} done",
    };
    for (bodies) |p| {
        const got = parseOsc9(p) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(p, got.body);
    }
}

test "unit: notifications: osc 99 accepts kitty and cmux-docs separators" {
    const a = parseOsc99("i=1:d=0;Hello");
    try testing.expectEqualStrings("1", a.id);
    try testing.expect(!a.done);
    try testing.expectEqualStrings("Hello", a.payload);
    try testing.expectEqual(KittyPayload.title, a.payload_type);
    const b = parseOsc99("i=1;e=1;d=0:Hello World");
    try testing.expectEqualStrings("1", b.id);
    try testing.expect(b.base64);
    try testing.expectEqualStrings("Hello World", b.payload);
    const c = parseOsc99("i=1;e=1;d=0;p=subtitle:Project X");
    try testing.expectEqual(KittyPayload.subtitle, c.payload_type);
    try testing.expectEqualStrings("Project X", c.payload);
    const d = parseOsc99(";hello: world");
    try testing.expectEqualStrings("hello: world", d.payload);
    try testing.expect(d.done);
    const e = parseOsc99("p=?;");
    try testing.expectEqual(KittyPayload.query, e.payload_type);
    try testing.expectEqual(KittyPayload.control, parseOsc99("p=close;").payload_type);
    try testing.expectEqualStrings("", parseOsc99("").payload);
    try testing.expectEqualStrings("just text", parseOsc99("just text").payload);
    // A trailing k=v without separator is payload, not metadata.
    try testing.expectEqualStrings("a=b", parseOsc99("i=2;a=b").payload);
    try testing.expectEqualStrings("x=1 y", parseOsc99("x=1 y").payload);
}

test "unit: notifications: kitty base64 decodes and falls back to raw text" {
    const gpa = testing.allocator;
    const ok = try decodePayloadAlloc(gpa, .{ .base64 = true, .payload = "SGVsbG8=" });
    defer gpa.free(ok);
    try testing.expectEqualStrings("Hello", ok);
    const nopad = try decodePayloadAlloc(gpa, .{ .base64 = true, .payload = "SGVsbG8" });
    defer gpa.free(nopad);
    try testing.expectEqualStrings("Hello", nopad);
    const raw = try decodePayloadAlloc(gpa, .{ .base64 = true, .payload = "Hello World" });
    defer gpa.free(raw);
    try testing.expectEqualStrings("Hello World", raw);
    const plain = try decodePayloadAlloc(gpa, .{ .payload = "SGVsbG8=" });
    defer gpa.free(plain);
    try testing.expectEqualStrings("SGVsbG8=", plain);
    const word = try decodePayloadAlloc(gpa, .{ .base64 = true, .payload = "Done" });
    defer gpa.free(word);
    try testing.expectEqualStrings("Done", word);
    const uni = try decodePayloadAlloc(gpa, .{ .base64 = true, .payload = "4pyTIGRvbmU=" });
    defer gpa.free(uni);
    try testing.expectEqualStrings("\u{2713} done", uni);
}

test "unit: notifications: kitty title chunk plus body chunk make one notification" {
    const gpa = testing.allocator;
    var asm_ = KittyAssembler.init(gpa);
    defer asm_.deinit();
    try testing.expect(try asm_.feed(sf, parseOsc99("i=1;e=1;d=0;p=title:Build Complete")) == null);
    try testing.expect(try asm_.feed(sf, parseOsc99("i=1;e=1;d=0;p=subtitle:Project X")) == null);
    var done = (try asm_.feed(sf, parseOsc99("i=1;e=1;d=1;p=body:All tests passed"))).?;
    defer done.deinit(gpa);
    try testing.expectEqualStrings("1", done.id);
    try testing.expectEqualStrings("Build Complete", done.fields.title);
    try testing.expectEqualStrings("Project X", done.fields.subtitle);
    try testing.expectEqualStrings("All tests passed", done.fields.body);
    try testing.expectEqual(@as(usize, 0), asm_.pending.items.len);
}

test "unit: notifications: kitty chunks are separated per surface and id" {
    const gpa = testing.allocator;
    var asm_ = KittyAssembler.init(gpa);
    defer asm_.deinit();
    _ = try asm_.feed(sf, parseOsc99("i=1:d=0;A"));
    _ = try asm_.feed(sf2, parseOsc99("i=1:d=0;B"));
    _ = try asm_.feed(sf, parseOsc99("i=2:d=0;C"));
    _ = try asm_.feed(sf, parseOsc99("i=1:d=0;A2")); // same type appends
    var x = (try asm_.feed(sf, parseOsc99("i=1:d=1;"))).?;
    defer x.deinit(gpa);
    try testing.expectEqualStrings("AA2", x.fields.title);
    var y = (try asm_.feed(sf2, parseOsc99("i=1;"))).?;
    defer y.deinit(gpa);
    try testing.expectEqualStrings("B", y.fields.title);
    asm_.forgetSurface(sf);
    try testing.expectEqual(@as(usize, 0), asm_.pending.items.len);
}

test "unit: notifications: kitty queries and controls never notify" {
    const gpa = testing.allocator;
    var asm_ = KittyAssembler.init(gpa);
    defer asm_.deinit();
    try testing.expect(try asm_.feed(sf, parseOsc99("i=1:p=?;")) == null);
    try testing.expect(try asm_.feed(sf, parseOsc99("i=1:p=close;")) == null);
    try testing.expect(try asm_.feed(sf, parseOsc99("i=1:d=1;")) == null); // empty
    try testing.expectEqual(@as(usize, 0), asm_.pending.items.len);
    // A control chunk with d=1 ends a pending notification.
    _ = try asm_.feed(sf, parseOsc99("i=5:d=0;Title"));
    var t = (try asm_.feed(sf, parseOsc99("i=5:d=1:p=alive;"))).?;
    defer t.deinit(gpa);
    try testing.expectEqualStrings("Title", t.fields.title);
}

test "unit: notifications: kitty pending entries are bounded and capped" {
    const gpa = testing.allocator;
    var asm_ = KittyAssembler.init(gpa);
    defer asm_.deinit();
    var buf: [32]u8 = undefined;
    for (0..max_pending_kitty + 5) |i| {
        const p = try std.fmt.bufPrint(&buf, "i={d}:d=0;t", .{i});
        _ = try asm_.feed(sf, parseOsc99(p));
    }
    try testing.expectEqual(max_pending_kitty, asm_.pending.items.len);
    try testing.expectEqual(@as(u64, 5), asm_.dropped);
    // Huge unicode body chunks stay within the cap on a code point.
    const big = "\u{4E2D}" ** 5000; // 15000 bytes
    _ = try asm_.feed(sf, .{ .id = "big", .done = false, .payload_type = .body, .payload = big });
    _ = try asm_.feed(sf, .{ .id = "big", .done = false, .payload_type = .body, .payload = big });
    var done = (try asm_.feed(sf, .{ .id = "big", .done = true, .payload_type = .title, .payload = "x" })).?;
    defer done.deinit(gpa);
    try testing.expect(done.fields.body.len <= body_cap);
    try testing.expect(done.fields.body.len > body_cap - 3);
    try testing.expect(std.unicode.utf8ValidateSlice(done.fields.body));
}

test "unit: notifications: kitty parsing and reassembly survive random input" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(99);
    const r = prng.random();
    var asm_ = KittyAssembler.init(gpa);
    defer asm_.deinit();
    const alphabet = "ipde=:;?01tlbosA-_+/x ";
    var buf: [40]u8 = undefined;
    for (0..3000) |_| {
        const p = buf[0..r.uintAtMost(usize, buf.len)];
        for (p) |*c| c.* = if (r.boolean()) alphabet[r.uintLessThan(usize, alphabet.len)] else r.int(u8);
        const chunk = parseOsc99(p);
        try testing.expect(chunk.payload.len <= p.len);
        const decoded = try decodePayloadAlloc(gpa, chunk);
        gpa.free(decoded);
        if (try asm_.feed(testUuid(r.uintLessThan(u32, 3)), chunk)) |done| {
            var x = done;
            defer x.deinit(gpa);
            for ([_][]const u8{ x.fields.title, x.fields.subtitle, x.fields.body }) |f| {
                try testing.expect(std.unicode.utf8ValidateSlice(f));
            }
            try testing.expect(x.fields.title.len <= title_cap and x.id.len <= kitty_id_cap);
        }
        try testing.expect(asm_.pending.items.len <= max_pending_kitty);
    }
}

test "unit: notifications: identical text from one surface within 1 s coalesces" {
    var c = Coalescer.init(testing.allocator);
    defer c.deinit();
    try testing.expect(try c.admit(sf, "T", "B", 1000));
    try testing.expect(!try c.admit(sf, "T", "B", 1500));
    try testing.expect(!try c.admit(sf, "T", "B", 1999));
    try testing.expect(try c.admit(sf, "T", "B", 2000));
    // Different text, other surface, or title/body boundary shift: delivered.
    try testing.expect(try c.admit(sf, "T", "B2", 2001));
    try testing.expect(try c.admit(sf2, "T", "B2", 2001));
    try testing.expect(try c.admit(sf, "TB", "2", 2002));
    // Clock going backwards never suppresses.
    try testing.expect(try c.admit(sf, "TB", "2", 1));
    c.forgetSurface(sf);
    try testing.expect(try c.admit(sf, "TB", "2", 2));
    // Extreme clock values neither overflow nor suppress.
    try testing.expect(try c.admit(sf, "x", "y", std.math.minInt(i64)));
    try testing.expect(try c.admit(sf, "x", "y", std.math.maxInt(i64)));
    try testing.expect(try c.admit(sf, "x", "y", std.math.minInt(i64)));
}

test "unit: notifications: coalescer prune tolerates extreme clock values" {
    var c = Coalescer.init(testing.allocator);
    defer c.deinit();
    for (0..1030) |i| _ = try c.admit(testUuid(@intCast(i)), "t", "b", std.math.minInt(i64));
    try testing.expect(try c.admit(testUuid(0x7777), "t", "b", std.math.maxInt(i64)));
    try testing.expect(c.last.count() < 1031);
}

test "unit: notifications: coalescer prunes stale surfaces" {
    var c = Coalescer.init(testing.allocator);
    defer c.deinit();
    for (0..1100) |i| _ = try c.admit(testUuid(@intCast(i)), "t", "b", @intCast(i * 10));
    try testing.expect(c.last.count() < 1100);
}

fn mkEntry(gpa: std.mem.Allocator, n: usize) !Entry {
    var buf: [32]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "n{d}", .{n});
    return Entry.create(gpa, sf, .{ .title = "t", .body = body }, null, .local);
}

test "unit: notifications: ingress fifo is ordered and drops the oldest when full" {
    const gpa = testing.allocator;
    var q = try Fifo.init(gpa, 4);
    defer q.deinit();
    try testing.expect(q.pop() == null);
    for (0..6) |i| _ = q.push(try mkEntry(gpa, i));
    try testing.expectEqual(@as(usize, 4), q.count());
    try testing.expectEqual(@as(u64, 2), q.dropped);
    for (2..6) |i| {
        var e = q.pop().?;
        defer e.deinit(gpa);
        var buf: [32]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "n{d}", .{i}), e.fields.body);
    }
    try testing.expect(q.pop() == null);
}

test "unit: notifications: ingress fifo stays at 256 under a 10000 entry flood" {
    const gpa = testing.allocator;
    var q = try Fifo.init(gpa, fifo_capacity);
    defer q.deinit();
    for (0..10_000) |i| _ = q.push(try mkEntry(gpa, i));
    try testing.expectEqual(fifo_capacity, q.count());
    try testing.expectEqual(@as(u64, 10_000 - fifo_capacity), q.dropped);
    var first = q.pop().?;
    defer first.deinit(gpa);
    try testing.expectEqualStrings("n9744", first.fields.body);
    q.clear();
    try testing.expectEqual(@as(usize, 0), q.count());
    _ = q.push(try mkEntry(gpa, 1)); // freed by deinit
}

test "unit: notifications: ingress fifo is safe across threads" {
    const gpa = testing.allocator;
    var q = try Fifo.init(gpa, 32);
    defer q.deinit();
    const Producer = struct {
        fn run(fifo: *Fifo, alloc: std.mem.Allocator) void {
            for (0..500) |i| {
                const e = mkEntry(alloc, i) catch return;
                _ = fifo.push(e);
            }
        }
    };
    const t = try std.Thread.spawn(.{}, Producer.run, .{ &q, gpa });
    var popped: usize = 0;
    var spins: usize = 0;
    while (spins < 1_000_000) : (spins += 1) {
        if (q.pop()) |e| {
            var x = e;
            x.deinit(gpa);
            popped += 1;
        }
        if (popped + q.droppedCount() >= 500 and q.count() == 0) break;
    }
    t.join();
    while (q.pop()) |e| {
        var x = e;
        x.deinit(gpa);
        popped += 1;
    }
    try testing.expectEqual(@as(u64, 500), popped + q.droppedCount());
}

test "unit: notifications: entries are sanitized and capped on code points" {
    const gpa = testing.allocator;
    const huge_title = "\u{00E9}" ** 2000; // 4000 bytes
    const huge_body = "\u{1F600}" ** 5000; // 20000 bytes
    var e = try Entry.create(gpa, sf, .{ .title = huge_title, .subtitle = "s\x07", .body = huge_body }, "kid", .{ .ssh_relay = sf2 });
    defer e.deinit(gpa);
    try testing.expectEqual(@as(usize, 1024), e.fields.title.len);
    try testing.expectEqual(@as(usize, 8192), e.fields.body.len);
    try testing.expectEqualStrings("s", e.fields.subtitle);
    try testing.expectEqualStrings("kid", e.kitty.?.id);
    try testing.expect(std.unicode.utf8ValidateSlice(e.fields.body));
}

test "unit: notifications: title falls back to workspace title then Terminal" {
    try testing.expectEqualStrings("T", resolveTitle("T", "ws"));
    try testing.expectEqualStrings("ws", resolveTitle("", "ws"));
    try testing.expectEqualStrings("ws", resolveTitle("  ", "ws"));
    try testing.expectEqualStrings("Terminal", resolveTitle("", ""));
    try testing.expectEqualStrings("Terminal", resolveTitle("", " \t"));
}

test "unit: notifications: routing resolves the current workspace and suppressions" {
    const gpa = testing.allocator;
    var e = try Entry.create(gpa, sf, .{ .body = "Build finished" }, null, .local);
    defer e.deinit(gpa);
    const ws_now = testUuid(0xEE);
    const d = route(&e, .{ .workspace = ws_now, .workspace_title = "api", .id = testUuid(7), .now_ms = 42 });
    const r = d.record;
    try testing.expectEqualStrings(&ws_now, &r.workspace);
    try testing.expectEqualStrings(&sf, &r.surface.?);
    try testing.expectEqualStrings("api", r.title);
    try testing.expectEqualStrings("Build finished", r.body);
    try testing.expectEqual(@as(i64, 42), r.created_at_ms);
    try testing.expect(route(&e, .{ .workspace = ws_now, .id = testUuid(8), .now_ms = 1, .agent_hooked = true }) == .suppressed);

    var ring = try Entry.create(gpa, sf, .{ .body = "@ghostty-attention:ring" }, null, .local);
    defer ring.deinit(gpa);
    const a = route(&ring, .{ .workspace = ws_now, .id = testUuid(9), .now_ms = 1, .agent_hooked = true });
    try testing.expect(a.attention.on);
    try testing.expectEqual(Attention.clear, attentionSentinel(.{ .title = "@ghostty-attention:clear\n" }).?);
    try testing.expect(attentionSentinel(.{ .body = "@ghostty-attention:ringx" }) == null);
}

test "unit: notifications: osc to store end to end" {
    const gpa = testing.allocator;
    const unread = @import("unread.zig");
    var m = unread.Model.init(gpa);
    defer m.deinit();
    var c = Coalescer.init(gpa);
    defer c.deinit();
    var q = try Fifo.init(gpa, fifo_capacity);
    defer q.deinit();
    const payloads = [_][]const u8{ "notify;A;one", "notify;A;one", "notify;B;two" };
    for (payloads, 0..) |p, i| {
        const f = parseOsc777(p).?;
        if (!try c.admit(sf, f.title, f.body, @intCast(i * 100))) continue;
        _ = q.push(try Entry.create(gpa, sf, f, null, .local));
    }
    try testing.expectEqual(@as(usize, 2), q.count());
    var n: u32 = 0;
    while (q.pop()) |entry| {
        var e = entry;
        defer e.deinit(gpa);
        n += 1;
        switch (route(&e, .{ .workspace = testUuid(0xAA), .id = testUuid(n), .now_ms = n })) {
            .record => |r| {
                var res = try m.add(r, .{});
                res.deinit(gpa);
            },
            else => unreachable,
        }
    }
    // Same pane twice: one row, the latest.
    try testing.expectEqual(@as(usize, 1), m.store.records.items.len);
    try testing.expectEqualStrings("B", m.store.records.items[0].title);
    try testing.expectEqual(@as(usize, 1), m.globalUnreadCount());
}
