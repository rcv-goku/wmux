//! Per-workspace checklist model (feature `todo`): items with a stable UUID,
//! trimmed and capped text, a three-way state and an origin. Storage order is
//! creation/`set` order; display order (unchecked first) is derived and never
//! written back. Every mutation goes through `Checklist` so the CLI, socket,
//! popover and pane share one entry point. Pure: std + wmux_proto only.

const std = @import("std");
const proto = @import("wmux_proto");
const Allocator = std.mem.Allocator;
const Uuid = proto.uuid.Uuid;

/// At most this many items per workspace.
pub const max_items = 50;
/// Text cap in Unicode code points (after trimming).
pub const max_text_chars = 500;

/// Item lifecycle. Wire names: `pending`, `in-progress`, `completed`.
pub const State = enum {
    pending,
    in_progress,
    completed,

    pub fn wireName(self: State) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in-progress",
            .completed => "completed",
        };
    }

    pub fn parse(s: []const u8) ?State {
        const map = std.StaticStringMap(State).initComptime(.{
            .{ "pending", .pending },
            .{ "in-progress", .in_progress },
            .{ "completed", .completed },
        });
        return map.get(s);
    }

    /// The `todo list` checkbox: `[ ]`, `[>]` or `[x]`.
    pub fn box(self: State) []const u8 {
        return switch (self) {
            .pending => "[ ]",
            .in_progress => "[>]",
            .completed => "[x]",
        };
    }

    pub fn jsonStringify(self: State, jws: anytype) !void {
        try jws.write(self.wireName());
    }

    /// Inverse of `jsonStringify`: std.json would otherwise match tag names
    /// and reject `"in-progress"`. Only wire-name strings are accepted.
    pub fn jsonParse(gpa: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!State {
        const token = try source.nextAllocMax(gpa, .alloc_if_needed, options.max_value_len.?);
        defer switch (token) {
            .allocated_number, .allocated_string => |s| gpa.free(s),
            else => {},
        };
        return switch (token) {
            inline .string, .allocated_string => |s| parse(s) orelse error.InvalidEnumTag,
            else => error.UnexpectedToken,
        };
    }

    pub fn jsonParseFromValue(gpa: Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!State {
        _ = gpa;
        _ = options;
        return switch (source) {
            .string => |s| parse(s) orelse error.InvalidEnumTag,
            else => error.UnexpectedToken,
        };
    }
};

/// Who created the item. Wire names: `user`, `agent`.
pub const Origin = enum {
    user,
    agent,

    pub fn wireName(self: Origin) []const u8 {
        return @tagName(self);
    }

    pub fn parse(s: []const u8) ?Origin {
        return std.meta.stringToEnum(Origin, s);
    }

    pub fn jsonStringify(self: Origin, jws: anytype) !void {
        try jws.write(self.wireName());
    }
};

/// Wire and `todo list --json` item shape: `{id, text, state, origin}`.
pub const Item = struct {
    id: Uuid,
    /// Heap-owned by the checklist; normalized by `normalizeText`.
    text: []u8,
    state: State = .pending,
    origin: Origin = .user,

    pub fn isCompleted(self: Item) bool {
        return self.state == .completed;
    }
};

/// `{completed, total}`.
pub const Progress = struct {
    completed: usize = 0,
    total: usize = 0,

    /// True when the list is non-empty and every item is completed.
    pub fn isComplete(self: Progress) bool {
        return self.total > 0 and self.completed == self.total;
    }
};

pub const TextError = error{ EmptyText, InvalidUtf8, OutOfMemory };
pub const TargetError = error{InvalidTarget};
pub const AddError = TextError || error{TooManyItems};

/// Trims leading and trailing whitespace (ASCII and the Unicode space
/// separators), rejects empty or invalid UTF-8 text, and truncates to
/// `max_text_chars` code points. Returns a heap copy.
pub fn normalizeText(gpa: Allocator, raw: []const u8) TextError![]u8 {
    if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;
    const t = trimSpace(raw);
    if (t.len == 0) return error.EmptyText;
    var it: std.unicode.Utf8Iterator = .{ .bytes = t, .i = 0 };
    var n: usize = 0;
    while (it.nextCodepointSlice()) |_| {
        n += 1;
        if (n == max_text_chars) break;
    }
    // Truncation may expose trailing whitespace; trim again (never empty,
    // because the first code point is not whitespace).
    const capped = trimSpace(t[0..it.i]);
    return gpa.dupe(u8, capped);
}

fn isSpace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        else => false,
    };
}

/// `s` must be valid UTF-8.
fn trimSpace(s: []const u8) []const u8 {
    var start: usize = 0;
    var it: std.unicode.Utf8Iterator = .{ .bytes = s, .i = 0 };
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch break;
        if (!isSpace(cp)) break;
        start = it.i;
    }
    var end: usize = s.len;
    while (end > start) {
        var lead = end - 1;
        while (lead > start and s[lead] & 0xC0 == 0x80) lead -= 1;
        const cp = std.unicode.utf8Decode(s[lead..end]) catch break;
        if (!isSpace(cp)) break;
        end = lead;
    }
    return s[start..end];
}

/// A non-empty run of ASCII digits. `std.fmt.parseUnsigned` alone is not
/// enough: it skips `_` separators, so "0_1" would resolve to item 1.
fn isAsciiDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

/// Writes `Invalid todo item: <x> (expected an item UUID or a 1-based index from `cmux todo list`)`.
pub fn writeInvalidTarget(w: *std.Io.Writer, target: []const u8) std.Io.Writer.Error!void {
    try w.print("Invalid todo item: {s} (expected an item UUID or a 1-based index from `cmux todo list`)", .{target});
}

pub const Checklist = struct {
    items: std.ArrayList(Item) = .empty,

    pub fn deinit(self: *Checklist, gpa: Allocator) void {
        for (self.items.items) |it| gpa.free(it.text);
        self.items.deinit(gpa);
        self.* = undefined;
    }

    pub fn len(self: *const Checklist) usize {
        return self.items.items.len;
    }

    pub fn progress(self: *const Checklist) Progress {
        var p: Progress = .{ .total = self.items.items.len };
        for (self.items.items) |it| {
            if (it.isCompleted()) p.completed += 1;
        }
        return p;
    }

    pub fn indexOfId(self: *const Checklist, id: Uuid) ?usize {
        for (self.items.items, 0..) |it, i| {
            if (it.id.eql(id)) return i;
        }
        return null;
    }

    /// Resolves `<index|id>` to a 0-based storage index: all digits means a
    /// 1-based `todo list` index, otherwise an item UUID (any case, braces ok).
    pub fn resolve(self: *const Checklist, target: []const u8) TargetError!usize {
        const t = std.mem.trim(u8, target, " \t\r\n");
        if (t.len == 0) return error.InvalidTarget;
        if (isAsciiDigits(t)) {
            const n = std.fmt.parseUnsigned(usize, t, 10) catch return error.InvalidTarget;
            if (n == 0 or n > self.items.items.len) return error.InvalidTarget;
            return n - 1;
        }
        const id = Uuid.parse(t) catch return error.InvalidTarget;
        return self.indexOfId(id) orelse error.InvalidTarget;
    }

    pub const AddOptions = struct {
        state: State = .pending,
        origin: Origin = .user,
        /// Identity to adopt (session restore); a fresh v4 otherwise. An id
        /// that another item already has is replaced by a fresh v4, as
        /// ADR-2.7 does for colliding handles: duplicate ids would make the
        /// list's own JSON fail `todo set` with DuplicateId.
        id: ?Uuid = null,
    };

    /// Appends an item and returns its storage index. Fails without mutating
    /// when the list is full or the text is empty after trimming.
    pub fn add(self: *Checklist, gpa: Allocator, raw_text: []const u8, opts: AddOptions) AddError!usize {
        if (self.items.items.len >= max_items) return error.TooManyItems;
        const text = try normalizeText(gpa, raw_text);
        errdefer gpa.free(text);
        try self.items.append(gpa, .{
            .id = self.unusedId(opts.id),
            .text = text,
            .state = opts.state,
            .origin = opts.origin,
        });
        return self.items.items.len - 1;
    }

    /// `want` when no item has it yet, otherwise (or when null) a fresh v4.
    fn unusedId(self: *const Checklist, want: ?Uuid) Uuid {
        if (want) |id| {
            if (self.indexOfId(id) == null) return id;
        }
        return Uuid.v4();
    }

    /// check / uncheck / start.
    pub fn setState(self: *Checklist, index: usize, state: State) void {
        self.items.items[index].state = state;
    }

    /// Replaces the text, keeping id, state and origin.
    pub fn edit(self: *Checklist, gpa: Allocator, index: usize, raw_text: []const u8) TextError!void {
        const text = try normalizeText(gpa, raw_text);
        const item = &self.items.items[index];
        gpa.free(item.text);
        item.text = text;
    }

    pub fn remove(self: *Checklist, gpa: Allocator, index: usize) void {
        const it = self.items.orderedRemove(index);
        gpa.free(it.text);
    }

    pub fn clear(self: *Checklist, gpa: Allocator) void {
        for (self.items.items) |it| gpa.free(it.text);
        self.items.clearRetainingCapacity();
    }

    /// Moves the item at `index` toward the 0-based storage position
    /// `new_index`, clamped so it stays between the first and last storage
    /// positions of its completion group (completed vs. not completed).
    /// Returns the final storage index.
    pub fn move(self: *Checklist, index: usize, new_index: usize) usize {
        const items = self.items.items;
        const done = items[index].isCompleted();
        var lo: usize = index;
        var hi: usize = index;
        for (items, 0..) |it, i| {
            if (it.isCompleted() != done) continue;
            lo = @min(lo, i);
            hi = @max(hi, i);
        }
        const dest = std.math.clamp(new_index, lo, hi);
        if (dest == index) return index;
        const moving = items[index];
        if (dest < index) {
            std.mem.copyBackwards(Item, items[dest + 1 .. index + 1], items[dest..index]);
        } else {
            std.mem.copyForwards(Item, items[index..dest], items[index + 1 .. dest + 1]);
        }
        items[dest] = moving;
        return dest;
    }

    /// Display order (storage indexes): items not completed first, then
    /// completed, each group in storage order. Caller frees.
    pub fn displayOrder(self: *const Checklist, gpa: Allocator) Allocator.Error![]usize {
        const out = try gpa.alloc(usize, self.items.items.len);
        var o: usize = 0;
        for (self.items.items, 0..) |it, i| {
            if (!it.isCompleted()) {
                out[o] = i;
                o += 1;
            }
        }
        for (self.items.items, 0..) |it, i| {
            if (it.isCompleted()) {
                out[o] = i;
                o += 1;
            }
        }
        return out;
    }

    /// `todo list` text: `<n>. [ ] text` lines (`[x]` completed, `[>]`
    /// in-progress, `  (agent)` suffix for agent items), then
    /// `<c>/<t> completed`; or `No todo items.` when empty.
    pub fn writeListText(self: *const Checklist, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.items.items.len == 0) return w.writeAll("No todo items.\n");
        for (self.items.items, 1..) |it, n| {
            try w.print("{d}. {s} {s}", .{ n, it.state.box(), it.text });
            if (it.origin == .agent) try w.writeAll("  (agent)");
            try w.writeByte('\n');
        }
        const p = self.progress();
        try w.print("{d}/{d} completed\n", .{ p.completed, p.total });
    }

    /// Mutation acknowledgement: `OK (<c>/<t> completed)`.
    pub fn writeOk(self: *const Checklist, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const p = self.progress();
        try w.print("OK ({d}/{d} completed)\n", .{ p.completed, p.total });
    }

    /// List payload: `{"items":[{id,text,state,origin}...],"completed":c,"total":t}`.
    pub fn jsonStringify(self: *const Checklist, jws: anytype) !void {
        const p = self.progress();
        try jws.beginObject();
        try jws.objectField("items");
        try jws.write(self.items.items);
        try jws.objectField("completed");
        try jws.write(p.completed);
        try jws.objectField("total");
        try jws.write(p.total);
        try jws.endObject();
    }
};

/// Edge detector for "checklist first becomes fully complete": `observe`
/// returns true once per transition into the complete state.
pub const CompletionEdge = struct {
    complete: bool = false,

    pub fn observe(self: *CompletionEdge, p: Progress) bool {
        const now = p.isComplete();
        defer self.complete = now;
        return now and !self.complete;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testId(n: u8) Uuid {
    var b: [16]u8 = @splat(n);
    b[0] = n;
    return Uuid.fromRandomBytes(b);
}

fn listText(c: *const Checklist) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try c.writeListText(&aw.writer);
    return aw.toOwnedSlice();
}

test "unit: todo: state and origin wire names round-trip" {
    inline for (.{ State.pending, State.in_progress, State.completed }) |s| {
        try testing.expectEqual(s, State.parse(s.wireName()).?);
    }
    try testing.expectEqualStrings("in-progress", State.in_progress.wireName());
    try testing.expect(State.parse("in_progress") == null);
    try testing.expect(State.parse("Completed") == null);
    try testing.expect(State.parse("") == null);
    try testing.expectEqual(Origin.agent, Origin.parse("agent").?);
    try testing.expect(Origin.parse("bot") == null);
}

test "unit: todo: state parses back from its wire name through std.json" {
    const gpa = testing.allocator;
    inline for (.{ State.pending, State.in_progress, State.completed }) |s| {
        const json = try std.json.Stringify.valueAlloc(gpa, s, .{});
        defer gpa.free(json);
        const parsed = try std.json.parseFromSlice(State, gpa, json, .{});
        defer parsed.deinit();
        try testing.expectEqual(s, parsed.value);
        const tree = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
        defer tree.deinit();
        const from_value = try std.json.parseFromValue(State, gpa, tree.value, .{});
        defer from_value.deinit();
        try testing.expectEqual(s, from_value.value);
    }
    // Optional fields of a typed params struct take the same path.
    const P = struct { state: ?State = null };
    const p = try std.json.parseFromSlice(P, gpa, "{\"state\":\"in-progress\"}", .{});
    defer p.deinit();
    try testing.expectEqual(@as(?State, .in_progress), p.value.state);
    // Tag spellings and enum numbers are not wire names.
    try testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(State, gpa, "\"in_progress\"", .{}));
    try testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(State, gpa, "1", .{}));
    try testing.expectError(error.InvalidEnumTag, std.json.parseFromValue(State, gpa, .{ .string = "done" }, .{}));
    try testing.expectError(error.UnexpectedToken, std.json.parseFromValue(State, gpa, .{ .integer = 1 }, .{}));
}

test "unit: todo: text is trimmed, capped at 500 code points, empty rejected" {
    const gpa = testing.allocator;
    const a = try normalizeText(gpa, "  \t write test \r\n");
    defer gpa.free(a);
    try testing.expectEqualStrings("write test", a);

    try testing.expectError(error.EmptyText, normalizeText(gpa, ""));
    try testing.expectError(error.EmptyText, normalizeText(gpa, " \n\t "));
    try testing.expectError(error.EmptyText, normalizeText(gpa, "\u{3000}\u{a0}"));
    try testing.expectError(error.InvalidUtf8, normalizeText(gpa, "ab\xffcd"));

    const long = "x" ** 600;
    const b = try normalizeText(gpa, long);
    defer gpa.free(b);
    try testing.expectEqual(@as(usize, 500), b.len);

    // Multi-byte: 600 × "é" (2 bytes) → 500 code points, never split.
    const accents = "\u{e9}" ** 600;
    const c = try normalizeText(gpa, accents);
    defer gpa.free(c);
    try testing.expectEqual(@as(usize, 500), try std.unicode.utf8CountCodepoints(c));
    try testing.expect(std.unicode.utf8ValidateSlice(c));

    // Exactly 500 is kept whole; unicode space trimming on both ends.
    const d = try normalizeText(gpa, "\u{2003}" ++ ("y" ** 500) ++ "\u{3000}");
    defer gpa.free(d);
    try testing.expectEqual(@as(usize, 500), d.len);

    // Truncation that leaves trailing whitespace is re-trimmed.
    const e = try normalizeText(gpa, ("z" ** 499) ++ "   tail");
    defer gpa.free(e);
    try testing.expectEqual(@as(usize, 499), e.len);

    // Emoji and CJK survive.
    const f = try normalizeText(gpa, " 🚀 デプロイ ");
    defer gpa.free(f);
    try testing.expectEqualStrings("🚀 デプロイ", f);
}

test "unit: todo: text rejects surrogates and overlong forms, keeps inner bytes" {
    const gpa = testing.allocator;
    // Windows argv with a lone UTF-16 surrogate arrives as WTF-8.
    try testing.expectError(error.InvalidUtf8, normalizeText(gpa, "a\xED\xA0\x80b"));
    try testing.expectError(error.InvalidUtf8, normalizeText(gpa, "\xC0\xAF"));
    try testing.expectError(error.InvalidUtf8, normalizeText(gpa, "ok\xE2\x82"));
    // Only the ends are trimmed; inner whitespace, tabs and NUL stay.
    const a = try normalizeText(gpa, "\u{2028} a\t\x00 b \u{85}");
    defer gpa.free(a);
    try testing.expectEqualStrings("a\t\x00 b", a);
    // Zero-width space is not whitespace (Swift does not trim it either).
    const z = try normalizeText(gpa, "\u{200B}");
    defer gpa.free(z);
    try testing.expectEqualStrings("\u{200B}", z);
}

test "unit: todo: add assigns ids, defaults, and fails on the 51st item" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    var i: usize = 0;
    while (i < max_items) : (i += 1) {
        _ = try c.add(gpa, "item", .{});
    }
    try testing.expectEqual(@as(usize, 50), c.len());
    try testing.expectError(error.TooManyItems, c.add(gpa, "one more", .{}));
    try testing.expectEqual(@as(usize, 50), c.len());
    const first = c.items.items[0];
    try testing.expectEqual(State.pending, first.state);
    try testing.expectEqual(Origin.user, first.origin);
    try testing.expectEqual(@as(u4, 4), first.id.version());
    try testing.expect(!first.id.eql(c.items.items[1].id));
}

test "unit: todo: add rejects empty text without mutating" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    try testing.expectError(error.EmptyText, c.add(gpa, "   ", .{}));
    try testing.expectEqual(@as(usize, 0), c.len());
    const idx = try c.add(gpa, "x", .{ .state = .in_progress, .origin = .agent, .id = testId(1) });
    try testing.expectEqual(@as(usize, 0), idx);
    try testing.expect(c.items.items[0].id.eql(testId(1)));
}

test "unit: todo: add never adopts an id another item already has" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    _ = try c.add(gpa, "a", .{ .id = testId(1) });
    // A corrupted or hand-edited session snapshot can repeat an id.
    _ = try c.add(gpa, "b", .{ .id = testId(1), .origin = .agent });
    try testing.expect(c.items.items[0].id.eql(testId(1)));
    const second = c.items.items[1];
    try testing.expect(!second.id.eql(testId(1)));
    try testing.expectEqual(@as(u4, 4), second.id.version());
    try testing.expectEqualStrings("b", second.text);
    try testing.expectEqual(Origin.agent, second.origin);
    // Both stay addressable by their own id.
    const second_text = second.id.toText();
    try testing.expectEqual(@as(usize, 1), try c.resolve(&second_text));
    // An unused id is still adopted as given.
    _ = try c.add(gpa, "c", .{ .id = testId(2) });
    try testing.expect(c.items.items[2].id.eql(testId(2)));
}

test "unit: todo: list text formats boxes, agent suffix, progress and empty" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    {
        const t = try listText(&c);
        defer gpa.free(t);
        try testing.expectEqualStrings("No todo items.\n", t);
    }
    _ = try c.add(gpa, "write test", .{});
    {
        const t = try listText(&c);
        defer gpa.free(t);
        try testing.expectEqualStrings("1. [ ] write test\n0/1 completed\n", t);
    }
    _ = try c.add(gpa, "lint", .{ .state = .completed });
    _ = try c.add(gpa, "build", .{ .state = .in_progress, .origin = .agent });
    const t = try listText(&c);
    defer gpa.free(t);
    try testing.expectEqualStrings(
        "1. [ ] write test\n2. [x] lint\n3. [>] build  (agent)\n1/3 completed\n",
        t,
    );
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try c.writeOk(&aw.writer);
    try testing.expectEqualStrings("OK (1/3 completed)\n", aw.written());
}

test "unit: todo: resolve accepts 1-based index or uuid and rejects the rest" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    _ = try c.add(gpa, "a", .{ .id = testId(1) });
    _ = try c.add(gpa, "b", .{ .id = testId(2) });
    try testing.expectEqual(@as(usize, 0), try c.resolve("1"));
    try testing.expectEqual(@as(usize, 1), try c.resolve(" 2 "));
    const id_text = testId(2).toText();
    try testing.expectEqual(@as(usize, 1), try c.resolve(&id_text));
    const lower = try std.ascii.allocLowerString(gpa, &id_text);
    defer gpa.free(lower);
    try testing.expectEqual(@as(usize, 1), try c.resolve(lower));
    for ([_][]const u8{ "0", "3", "", "-1", "1.5", "abc", "99999999999999999999999", "{}", "ä" }) |bad| {
        try testing.expectError(error.InvalidTarget, c.resolve(bad));
    }
    // Digit separators are not indexes ("0_1" is not item 1).
    for ([_][]const u8{ "0_1", "0_2", "1_", "_1" }) |bad| {
        try testing.expectError(error.InvalidTarget, c.resolve(bad));
    }
    try testing.expectEqual(@as(usize, 1), try c.resolve("02"));
    const missing = testId(9).toText();
    try testing.expectError(error.InvalidTarget, c.resolve(&missing));
    // Braced UUIDs resolve; half-braced and signed or non-ASCII digits do not.
    var braced_buf: [Uuid.text_len + 2]u8 = undefined;
    const braced = try std.fmt.bufPrint(&braced_buf, "{{{s}}}", .{&id_text});
    try testing.expectEqual(@as(usize, 1), try c.resolve(braced));
    for ([_][]const u8{ braced[0 .. braced.len - 1], "+1", "\u{FF11}", "1\x00" }) |bad| {
        try testing.expectError(error.InvalidTarget, c.resolve(bad));
    }

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeInvalidTarget(&aw.writer, "7");
    try testing.expectEqualStrings(
        "Invalid todo item: 7 (expected an item UUID or a 1-based index from `cmux todo list`)",
        aw.written(),
    );
}

test "unit: todo: check, start, uncheck, edit keep identity; remove and clear" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    _ = try c.add(gpa, "a", .{ .id = testId(1), .origin = .agent });
    _ = try c.add(gpa, "b", .{ .id = testId(2) });
    c.setState(0, .completed);
    try testing.expectEqual(Progress{ .completed = 1, .total = 2 }, c.progress());
    c.setState(0, .in_progress);
    try testing.expectEqual(@as(usize, 0), c.progress().completed);
    c.setState(0, .pending);
    try c.edit(gpa, 0, "  renamed  ");
    try testing.expectEqualStrings("renamed", c.items.items[0].text);
    try testing.expect(c.items.items[0].id.eql(testId(1)));
    try testing.expectEqual(Origin.agent, c.items.items[0].origin);
    try testing.expectError(error.EmptyText, c.edit(gpa, 0, ""));
    try testing.expectEqualStrings("renamed", c.items.items[0].text);
    c.remove(gpa, 0);
    try testing.expectEqual(@as(usize, 1), c.len());
    try testing.expect(c.items.items[0].id.eql(testId(2)));
    c.clear(gpa);
    try testing.expectEqual(@as(usize, 0), c.len());
    try testing.expectEqual(Progress{}, c.progress());
}

test "unit: todo: display floats unchecked first but storage order is kept" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    _ = try c.add(gpa, "one", .{});
    _ = try c.add(gpa, "two", .{ .state = .in_progress });
    _ = try c.add(gpa, "three", .{});
    c.setState(0, .completed);
    const order = try c.displayOrder(gpa);
    defer gpa.free(order);
    try testing.expectEqualSlices(usize, &.{ 1, 2, 0 }, order);
    // `todo list` still prints the checked item as 1.
    const t = try listText(&c);
    defer gpa.free(t);
    try testing.expect(std.mem.startsWith(u8, t, "1. [x] one\n"));

    var empty: Checklist = .{};
    const none = try empty.displayOrder(gpa);
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "unit: todo: move reorders and clamps within the completion group" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    // storage: a(p) b(p) X(c) d(p) Y(c)
    _ = try c.add(gpa, "a", .{});
    _ = try c.add(gpa, "b", .{});
    _ = try c.add(gpa, "X", .{ .state = .completed });
    _ = try c.add(gpa, "d", .{});
    _ = try c.add(gpa, "Y", .{ .state = .completed });

    // d to the top.
    try testing.expectEqual(@as(usize, 0), c.move(3, 0));
    try expectOrder(&c, "dabXY");
    // a far past the end clamps to the last pending position (index 2,
    // the slot after b, before X... pending group spans 0..2).
    try testing.expectEqual(@as(usize, 2), c.move(1, 100));
    try expectOrder(&c, "dbaXY");
    // Y to the top clamps to the first completed position (3).
    try testing.expectEqual(@as(usize, 3), c.move(4, 0));
    try expectOrder(&c, "dbaYX");
    // No-op move.
    try testing.expectEqual(@as(usize, 1), c.move(1, 1));
    try expectOrder(&c, "dbaYX");
    // Single item.
    var one: Checklist = .{};
    defer one.deinit(gpa);
    _ = try one.add(gpa, "solo", .{});
    try testing.expectEqual(@as(usize, 0), one.move(0, 5));
}

test "unit: todo: move in interleaved storage keeps the other group's order" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    // storage: X(c) a(p) Y(c) b(>); in-progress counts as unchecked, so the
    // unchecked items span 1..3 and the completed ones 0..2.
    _ = try c.add(gpa, "X", .{ .state = .completed });
    _ = try c.add(gpa, "a", .{});
    _ = try c.add(gpa, "Y", .{ .state = .completed });
    _ = try c.add(gpa, "b", .{ .state = .in_progress });
    // b to the top stops at the first pending slot; X and Y keep their order.
    try testing.expectEqual(@as(usize, 1), c.move(3, 0));
    try expectOrder(&c, "XbaY");
    // X to the end: the completed group now spans 0..3.
    try testing.expectEqual(@as(usize, 3), c.move(0, 3));
    try expectOrder(&c, "baYX");
    // a cannot pass the completed run that now follows the pending one.
    try testing.expectEqual(@as(usize, 1), c.move(1, 3));
    try expectOrder(&c, "baYX");
    // Display order is unchecked first, each group in storage order.
    const order = try c.displayOrder(gpa);
    defer gpa.free(order);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, order);
}

test "unit: todo: add, edit and display order clean up when an allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, mutateUnderAllocationFailure, .{});
}

fn mutateUnderAllocationFailure(gpa: Allocator) !void {
    var c: Checklist = .{};
    defer c.deinit(gpa);
    _ = try c.add(gpa, "first", .{ .id = testId(1) });
    _ = try c.add(gpa, "second", .{ .state = .completed });
    c.edit(gpa, 0, " renamed ") catch |err| {
        try testing.expectEqualStrings("first", c.items.items[0].text);
        return err;
    };
    try testing.expectEqualStrings("renamed", c.items.items[0].text);
    const order = try c.displayOrder(gpa);
    defer gpa.free(order);
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, order);
}

fn expectOrder(c: *const Checklist, expected: []const u8) !void {
    try testing.expectEqual(expected.len, c.len());
    for (c.items.items, expected) |it, ch| {
        try testing.expectEqual(ch, it.text[0]);
    }
}

test "unit: todo: list payload json shape" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    _ = try c.add(gpa, "say \"hi\"", .{ .id = testId(1), .state = .in_progress, .origin = .agent });
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(&c, .{}, &aw.writer);
    const id = testId(1).toText();
    const expected = try std.fmt.allocPrint(gpa,
        \\{{"items":[{{"id":"{s}","text":"say \"hi\"","state":"in-progress","origin":"agent"}}],"completed":0,"total":1}}
    , .{&id});
    defer gpa.free(expected);
    try testing.expectEqualStrings(expected, aw.written());
}

test "unit: todo: completion edge fires once per transition" {
    var e: CompletionEdge = .{};
    try testing.expect(!e.observe(.{ .completed = 0, .total = 0 }));
    try testing.expect(!e.observe(.{ .completed = 0, .total = 2 }));
    try testing.expect(e.observe(.{ .completed = 2, .total = 2 }));
    try testing.expect(!e.observe(.{ .completed = 2, .total = 2 }));
    try testing.expect(!e.observe(.{ .completed = 1, .total = 2 }));
    try testing.expect(e.observe(.{ .completed = 2, .total = 2 }));
    // Clearing the list resets; an empty list is never "complete".
    try testing.expect(!e.observe(.{}));
    try testing.expect(e.observe(.{ .completed = 1, .total = 1 }));
}
