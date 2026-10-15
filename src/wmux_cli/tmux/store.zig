//! tmux-compat store model (`STATE\agents\tmux-compat-store.json`, ADR-10.8):
//! paste buffers, hooks, the main-vertical agent-column placement state and
//! the tmux pane id (`%N`) <-> wmux surface UUID map.
//!
//! JSON keys follow cmux's store (`buffers`, `hooks`, `mainVerticalLayouts`
//! with `mainSurfaceId`/`lastColumnSurfaceId`, `lastSplitSurface`); the pane
//! map is the wmux key `paneSurfaces` (`{"%N": "<surface uuid>"}`). Older or
//! partial files decode gracefully: missing keys are empty, entries of the
//! wrong type are skipped, unknown keys are ignored.
//!
//! This file is pure: the CLI reads the bytes and writes them back under
//! `LockFileEx` on `<file>.lock` with an atomic replace (see `lock_suffix`).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const file_name = "tmux-compat-store.json";
/// The lock file is `<store path>` + this suffix.
pub const lock_suffix = ".lock";
/// Per-buffer byte cap (G6); longer text is truncated on a code point boundary.
pub const max_buffer_bytes: usize = 16 * 1024 * 1024;
/// Default buffer name when none is given (cmux `set-buffer` semantics).
pub const default_buffer = "default";

/// `<state_dir>/agents/tmux-compat-store.json` (caller frees).
pub fn pathIn(gpa: Allocator, state_dir: []const u8) Allocator.Error![]u8 {
    return std.fs.path.join(gpa, &.{ state_dir, "agents", file_name });
}

pub const Layout = struct {
    main: []u8,
    column: ?[]u8 = null,
};

const StrMap = std.StringArrayHashMapUnmanaged([]u8);

pub const Store = struct {
    buffers: StrMap = .empty,
    hooks: StrMap = .empty,
    main_vertical: std.StringArrayHashMapUnmanaged(Layout) = .empty,
    last_split: StrMap = .empty,
    pane_surfaces: std.AutoArrayHashMapUnmanaged(u32, []u8) = .empty,

    pub const ParseError = Allocator.Error || error{InvalidStore};

    pub fn deinit(self: *Store, gpa: Allocator) void {
        freeStrMap(gpa, &self.buffers);
        freeStrMap(gpa, &self.hooks);
        freeStrMap(gpa, &self.last_split);
        var it = self.main_vertical.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            freeLayout(gpa, e.value_ptr.*);
        }
        self.main_vertical.deinit(gpa);
        for (self.pane_surfaces.values()) |v| gpa.free(v);
        self.pane_surfaces.deinit(gpa);
        self.* = .{};
    }

    /// Decodes a store file. Empty or whitespace-only input is an empty
    /// store; malformed JSON or a non-object root is `error.InvalidStore`
    /// (the caller may back the file up and start fresh).
    pub fn parse(gpa: Allocator, bytes: []const u8) ParseError!Store {
        var self: Store = .{};
        errdefer self.deinit(gpa);
        if (std.mem.trim(u8, bytes, " \t\r\n").len == 0) return self;

        var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidStore,
        };
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidStore,
        };
        if (root.get("buffers")) |v| try loadStrMap(gpa, &self.buffers, v);
        if (root.get("hooks")) |v| try loadStrMap(gpa, &self.hooks, v);
        if (root.get("lastSplitSurface")) |v| try loadStrMap(gpa, &self.last_split, v);
        if (root.get("mainVerticalLayouts")) |v| switch (v) {
            .object => |o| {
                var it = o.iterator();
                while (it.next()) |e| {
                    const lo = switch (e.value_ptr.*) {
                        .object => |x| x,
                        else => continue,
                    };
                    const main = switch (lo.get("mainSurfaceId") orelse continue) {
                        .string => |s| s,
                        else => continue,
                    };
                    const column: ?[]const u8 = if (lo.get("lastColumnSurfaceId")) |c| switch (c) {
                        .string => |s| s,
                        else => null,
                    } else null;
                    try self.setLayout(gpa, e.key_ptr.*, main, column);
                }
            },
            else => {},
        };
        if (root.get("paneSurfaces")) |v| switch (v) {
            .object => |o| {
                var it = o.iterator();
                while (it.next()) |e| {
                    const n = parsePaneKey(e.key_ptr.*) orelse continue;
                    switch (e.value_ptr.*) {
                        .string => |s| try self.setPaneSurface(gpa, n, s),
                        else => {},
                    }
                }
            },
            else => {},
        };
        return self;
    }

    /// Encodes the store as pretty JSON with a trailing newline.
    pub fn write(self: *const Store, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
        try s.beginObject();
        try writeStrMap(&s, "buffers", &self.buffers);
        try writeStrMap(&s, "hooks", &self.hooks);
        try s.objectField("mainVerticalLayouts");
        try s.beginObject();
        var it = self.main_vertical.iterator();
        while (it.next()) |e| {
            try objectFieldSafe(&s, e.key_ptr.*);
            try s.beginObject();
            try s.objectField("mainSurfaceId");
            try writeStringSafe(&s, e.value_ptr.main);
            if (e.value_ptr.column) |c| {
                try s.objectField("lastColumnSurfaceId");
                try writeStringSafe(&s, c);
            }
            try s.endObject();
        }
        try s.endObject();
        try writeStrMap(&s, "lastSplitSurface", &self.last_split);
        try s.objectField("paneSurfaces");
        try s.beginObject();
        var pit = self.pane_surfaces.iterator();
        while (pit.next()) |e| {
            var key_buf: [16]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "%{d}", .{e.key_ptr.*}) catch unreachable;
            try s.objectField(key);
            try writeStringSafe(&s, e.value_ptr.*);
        }
        try s.endObject();
        try s.endObject();
        try w.writeByte('\n');
    }

    pub fn toJson(self: *const Store, gpa: Allocator) Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        self.write(&aw.writer) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    // -- buffers -----------------------------------------------------------

    pub fn getBuffer(self: *const Store, name: []const u8) ?[]const u8 {
        return self.buffers.get(name);
    }

    /// Stores text exactly (up to `max_buffer_bytes`); `append` adds to an
    /// existing buffer.
    pub fn setBuffer(self: *Store, gpa: Allocator, name: []const u8, text: []const u8, append: bool) Allocator.Error!void {
        if (append) {
            if (self.buffers.getPtr(name)) |old| {
                const joined = try std.mem.concat(gpa, u8, &.{ old.*, text });
                defer gpa.free(joined);
                const capped = try gpa.dupe(u8, truncateUtf8(joined, max_buffer_bytes));
                gpa.free(old.*);
                old.* = capped;
                return;
            }
        }
        try putStr(gpa, &self.buffers, name, truncateUtf8(text, max_buffer_bytes));
    }

    pub fn deleteBuffer(self: *Store, gpa: Allocator, name: []const u8) bool {
        return removeStr(gpa, &self.buffers, name);
    }

    /// Renames a buffer, replacing any buffer already called `new_name`.
    pub fn renameBuffer(self: *Store, gpa: Allocator, old_name: []const u8, new_name: []const u8) Allocator.Error!bool {
        const text = self.buffers.get(old_name) orelse return false;
        if (std.mem.eql(u8, old_name, new_name)) return true;
        try putStr(gpa, &self.buffers, new_name, text);
        _ = removeStr(gpa, &self.buffers, old_name);
        return true;
    }

    // -- hooks -------------------------------------------------------------

    pub fn getHook(self: *const Store, event: []const u8) ?[]const u8 {
        return self.hooks.get(event);
    }

    pub fn setHook(self: *Store, gpa: Allocator, event: []const u8, command: []const u8) Allocator.Error!void {
        try putStr(gpa, &self.hooks, event, command);
    }

    pub fn removeHook(self: *Store, gpa: Allocator, event: []const u8) bool {
        return removeStr(gpa, &self.hooks, event);
    }

    // -- main-vertical placement -------------------------------------------

    pub fn getLayout(self: *const Store, workspace: []const u8) ?Layout {
        return self.main_vertical.get(workspace);
    }

    pub fn setLayout(self: *Store, gpa: Allocator, workspace: []const u8, main: []const u8, column: ?[]const u8) Allocator.Error!void {
        const new_main = try gpa.dupe(u8, main);
        errdefer gpa.free(new_main);
        const new_col: ?[]u8 = if (column) |c| try gpa.dupe(u8, c) else null;
        errdefer if (new_col) |c| gpa.free(c);
        const gop = try self.main_vertical.getOrPut(gpa, workspace);
        if (gop.found_existing) {
            freeLayout(gpa, gop.value_ptr.*);
        } else {
            gop.key_ptr.* = gpa.dupe(u8, workspace) catch |err| {
                self.main_vertical.swapRemoveAt(gop.index);
                return err;
            };
        }
        gop.value_ptr.* = .{ .main = new_main, .column = new_col };
    }

    pub fn setLayoutColumn(self: *Store, gpa: Allocator, workspace: []const u8, column: ?[]const u8) Allocator.Error!void {
        const lo = self.main_vertical.getPtr(workspace) orelse return;
        const new_col: ?[]u8 = if (column) |c| try gpa.dupe(u8, c) else null;
        if (lo.column) |old| gpa.free(old);
        lo.column = new_col;
    }

    pub fn removeLayout(self: *Store, gpa: Allocator, workspace: []const u8) bool {
        const kv = self.main_vertical.fetchOrderedRemove(workspace) orelse return false;
        gpa.free(kv.key);
        freeLayout(gpa, kv.value);
        return true;
    }

    pub fn getLastSplit(self: *const Store, workspace: []const u8) ?[]const u8 {
        return self.last_split.get(workspace);
    }

    pub fn setLastSplit(self: *Store, gpa: Allocator, workspace: []const u8, surface: []const u8) Allocator.Error!void {
        try putStr(gpa, &self.last_split, workspace, surface);
    }

    // -- pane ids ----------------------------------------------------------

    pub fn paneSurface(self: *const Store, pane: u32) ?[]const u8 {
        return self.pane_surfaces.get(pane);
    }

    /// The `%N` recorded for a surface UUID (case-insensitive compare).
    pub fn paneForSurface(self: *const Store, surface: []const u8) ?u32 {
        var it = self.pane_surfaces.iterator();
        while (it.next()) |e| {
            if (std.ascii.eqlIgnoreCase(e.value_ptr.*, surface)) return e.key_ptr.*;
        }
        return null;
    }

    pub fn setPaneSurface(self: *Store, gpa: Allocator, pane: u32, surface: []const u8) Allocator.Error!void {
        const val = try gpa.dupe(u8, surface);
        errdefer gpa.free(val);
        const gop = try self.pane_surfaces.getOrPut(gpa, pane);
        if (gop.found_existing) gpa.free(gop.value_ptr.*);
        gop.value_ptr.* = val;
    }

    /// Forgets every reference to a closed surface: its pane id, `lastSplit`
    /// entries naming it, agent columns ending at it and layouts whose main
    /// surface it was. Returns true when anything changed.
    pub fn forgetSurface(self: *Store, gpa: Allocator, surface: []const u8) bool {
        var changed = false;
        var i: usize = 0;
        while (i < self.pane_surfaces.count()) {
            const v = self.pane_surfaces.values()[i];
            if (std.ascii.eqlIgnoreCase(v, surface)) {
                gpa.free(v);
                self.pane_surfaces.orderedRemoveAt(i);
                changed = true;
            } else i += 1;
        }
        i = 0;
        while (i < self.last_split.count()) {
            const v = self.last_split.values()[i];
            if (std.ascii.eqlIgnoreCase(v, surface)) {
                gpa.free(self.last_split.keys()[i]);
                gpa.free(v);
                self.last_split.orderedRemoveAt(i);
                changed = true;
            } else i += 1;
        }
        i = 0;
        while (i < self.main_vertical.count()) {
            const lo = &self.main_vertical.values()[i];
            if (std.ascii.eqlIgnoreCase(lo.main, surface)) {
                gpa.free(self.main_vertical.keys()[i]);
                freeLayout(gpa, lo.*);
                self.main_vertical.orderedRemoveAt(i);
                changed = true;
                continue;
            }
            if (lo.column) |c| {
                if (std.ascii.eqlIgnoreCase(c, surface)) {
                    gpa.free(c);
                    lo.column = null;
                    changed = true;
                }
            }
            i += 1;
        }
        return changed;
    }
};

fn parsePaneKey(key: []const u8) ?u32 {
    const digits = if (key.len > 0 and key[0] == '%') key[1..] else key;
    if (digits.len == 0) return null;
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

fn freeLayout(gpa: Allocator, lo: Layout) void {
    gpa.free(lo.main);
    if (lo.column) |c| gpa.free(c);
}

fn freeStrMap(gpa: Allocator, m: *StrMap) void {
    var it = m.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        gpa.free(e.value_ptr.*);
    }
    m.deinit(gpa);
}

fn putStr(gpa: Allocator, m: *StrMap, key: []const u8, value: []const u8) Allocator.Error!void {
    const val = try gpa.dupe(u8, value);
    errdefer gpa.free(val);
    const gop = try m.getOrPut(gpa, key);
    if (gop.found_existing) {
        gpa.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = gpa.dupe(u8, key) catch |err| {
            m.swapRemoveAt(gop.index);
            return err;
        };
    }
    gop.value_ptr.* = val;
}

fn removeStr(gpa: Allocator, m: *StrMap, key: []const u8) bool {
    const kv = m.fetchOrderedRemove(key) orelse return false;
    gpa.free(kv.key);
    gpa.free(kv.value);
    return true;
}

fn loadStrMap(gpa: Allocator, m: *StrMap, v: std.json.Value) Allocator.Error!void {
    const o = switch (v) {
        .object => |o| o,
        else => return,
    };
    var it = o.iterator();
    while (it.next()) |e| switch (e.value_ptr.*) {
        .string => |s| try putStr(gpa, m, e.key_ptr.*, s),
        else => {},
    };
}

fn writeStrMap(s: *std.json.Stringify, field: []const u8, m: *const StrMap) std.Io.Writer.Error!void {
    try s.objectField(field);
    try s.beginObject();
    var it = m.iterator();
    while (it.next()) |e| {
        try objectFieldSafe(s, e.key_ptr.*);
        try writeStringSafe(s, e.value_ptr.*);
    }
    try s.endObject();
}

/// JSON must be valid UTF-8: invalid bytes are written as U+FFFD.
fn writeStringSafe(s: *std.json.Stringify, v: []const u8) std.Io.Writer.Error!void {
    if (std.unicode.utf8ValidateSlice(v)) return s.write(v);
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const fixed = sanitizeUtf8(fba.allocator(), v) catch {
        // Very long invalid text: degrade to replacing every non-ASCII byte.
        try s.beginWriteRaw();
        try s.writer.writeByte('"');
        for (v) |c| {
            if (c < 0x80) {
                try std.json.Stringify.encodeJsonStringChars(&.{c}, .{}, s.writer);
            } else try s.writer.writeAll("\\ufffd");
        }
        try s.writer.writeByte('"');
        s.endWriteRaw();
        return;
    };
    try s.write(fixed);
}

fn objectFieldSafe(s: *std.json.Stringify, key: []const u8) std.Io.Writer.Error!void {
    if (std.unicode.utf8ValidateSlice(key)) return s.objectField(key);
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const fixed = sanitizeUtf8(fba.allocator(), key) catch "\u{FFFD}";
    try s.objectField(fixed);
}

fn sanitizeUtf8(a: Allocator, v: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < v.len) {
        const n = std.unicode.utf8ByteSequenceLength(v[i]) catch {
            try out.appendSlice(a, "\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + n <= v.len and std.unicode.utf8ValidateSlice(v[i .. i + n])) {
            try out.appendSlice(a, v[i .. i + n]);
            i += n;
        } else {
            try out.appendSlice(a, "\u{FFFD}");
            i += 1;
        }
    }
    return out.items;
}

/// Longest prefix of `s` that is at most `cap` bytes and does not split a
/// UTF-8 sequence.
pub fn truncateUtf8(s: []const u8, cap: usize) []const u8 {
    if (s.len <= cap) return s;
    var end = cap;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

const testing = std.testing;

test "unit: tmux: store: round trip with every key" {
    const gpa = testing.allocator;
    var st: Store = .{};
    defer st.deinit(gpa);
    try st.setBuffer(gpa, "default", "hello\nwörld", false);
    try st.setHook(gpa, "after-split-window", "select-layout main-vertical");
    try st.setLayout(gpa, "WS-1", "S-MAIN", "S-COL");
    try st.setLastSplit(gpa, "WS-1", "S-COL");
    try st.setPaneSurface(gpa, 3, "S-COL");
    const json = try st.toJson(gpa);
    defer gpa.free(json);
    try testing.expectEqualStrings(
        \\{
        \\  "buffers": {
        \\    "default": "hello\nwörld"
        \\  },
        \\  "hooks": {
        \\    "after-split-window": "select-layout main-vertical"
        \\  },
        \\  "mainVerticalLayouts": {
        \\    "WS-1": {
        \\      "mainSurfaceId": "S-MAIN",
        \\      "lastColumnSurfaceId": "S-COL"
        \\    }
        \\  },
        \\  "lastSplitSurface": {
        \\    "WS-1": "S-COL"
        \\  },
        \\  "paneSurfaces": {
        \\    "%3": "S-COL"
        \\  }
        \\}
        \\
    , json);
    var back = try Store.parse(gpa, json);
    defer back.deinit(gpa);
    try testing.expectEqualStrings("hello\nwörld", back.getBuffer("default").?);
    try testing.expectEqualStrings("S-COL", back.getLayout("WS-1").?.column.?);
    try testing.expectEqualStrings("S-COL", back.paneSurface(3).?);
    try testing.expectEqual(@as(?u32, 3), back.paneForSurface("s-col"));
}

test "unit: tmux: store: older and partial files decode gracefully" {
    const gpa = testing.allocator;
    var empty = try Store.parse(gpa, "  \n");
    defer empty.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), empty.buffers.count());

    var old = try Store.parse(gpa,
        \\{"buffers":{"a":"1","bad":7},"hooks":[],"mainVerticalLayouts":{"W":{"mainSurfaceId":"M"},"X":{"lastColumnSurfaceId":"C"},"Y":3},
        \\ "paneSurfaces":{"%2":"U2","7":"U7","%x":"bad","%9":null},"future":{"k":1}}
    );
    defer old.deinit(gpa);
    try testing.expectEqualStrings("1", old.getBuffer("a").?);
    try testing.expect(old.getBuffer("bad") == null);
    try testing.expectEqual(@as(usize, 0), old.hooks.count());
    try testing.expect(old.getLayout("W").?.column == null);
    try testing.expect(old.getLayout("X") == null);
    try testing.expectEqualStrings("U2", old.paneSurface(2).?);
    try testing.expectEqualStrings("U7", old.paneSurface(7).?);
    try testing.expectEqual(@as(usize, 2), old.pane_surfaces.count());

    try testing.expectError(error.InvalidStore, Store.parse(gpa, "{not json"));
    try testing.expectError(error.InvalidStore, Store.parse(gpa, "[1,2]"));
}

test "unit: tmux: store: forgetSurface prunes every reference" {
    const gpa = testing.allocator;
    var st: Store = .{};
    defer st.deinit(gpa);
    try st.setLayout(gpa, "W1", "M", "C");
    try st.setLayout(gpa, "W2", "C2", null);
    try st.setLastSplit(gpa, "W1", "C");
    try st.setPaneSurface(gpa, 4, "C");
    try testing.expect(st.forgetSurface(gpa, "c"));
    try testing.expect(st.getLayout("W1").?.column == null);
    try testing.expect(st.getLastSplit("W1") == null);
    try testing.expect(st.paneSurface(4) == null);
    try testing.expect(st.forgetSurface(gpa, "C2"));
    try testing.expect(st.getLayout("W2") == null);
    try testing.expect(!st.forgetSurface(gpa, "nothing"));
}

test "unit: tmux: store: buffers append, rename, delete, cap and invalid UTF-8" {
    const gpa = testing.allocator;
    var st: Store = .{};
    defer st.deinit(gpa);
    try st.setBuffer(gpa, "b", "ab", false);
    try st.setBuffer(gpa, "b", "cd", true);
    try testing.expectEqualStrings("abcd", st.getBuffer("b").?);
    try testing.expect(try st.renameBuffer(gpa, "b", "c"));
    try testing.expect(st.getBuffer("b") == null);
    try testing.expect(!(try st.renameBuffer(gpa, "missing", "x")));
    try testing.expect(st.deleteBuffer(gpa, "c"));
    try testing.expect(!st.deleteBuffer(gpa, "c"));

    try testing.expectEqualStrings("a", truncateUtf8("aé", 2));
    try testing.expectEqualStrings("aé", truncateUtf8("aé", 3));
    try testing.expectEqualStrings("", truncateUtf8("é", 1));

    try st.setBuffer(gpa, "raw", "x\xffy", false);
    const json = try st.toJson(gpa);
    defer gpa.free(json);
    var back = try Store.parse(gpa, json);
    defer back.deinit(gpa);
    try testing.expectEqualStrings("x\u{FFFD}y", back.getBuffer("raw").?);
}

test "unit: tmux: store: path" {
    const gpa = testing.allocator;
    const p = try pathIn(gpa, "state");
    defer gpa.free(p);
    const want = try std.fs.path.join(gpa, &.{ "state", "agents", "tmux-compat-store.json" });
    defer gpa.free(want);
    try testing.expectEqualStrings(want, p);
}
