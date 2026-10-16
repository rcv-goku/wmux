//! CLI-side checklist rules for `cmux todo`, mirroring the merged model in
//! src/apprt/win32/features/todo/logic (checklist.zig, json_set.zig): state
//! and origin wire names, text trimming, the 50-item cap, `<index|id>`
//! target syntax, `todo set` payload validation with the same messages, and
//! the `todo list` / `OK (<c>/<t> completed)` text rendered from the wire
//! payload. The CLI module cannot import files outside src/wmux_cli (Zig
//! module boundary), so the rules are restated here and pinned by tests
//! until the todo logic is exposed as a shared build module (requested).

const std = @import("std");
const proto = @import("wmux_proto");
const Uuid = proto.uuid.Uuid;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const max_items = 50;
pub const max_text_chars = 500;
pub const max_input_bytes = 1 << 20;

pub const states = [_][]const u8{ "pending", "in-progress", "completed" };
pub const origins = [_][]const u8{ "user", "agent" };

pub fn isState(s: []const u8) bool {
    for (states) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

pub fn isOrigin(s: []const u8) bool {
    for (origins) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// `todo list` checkbox for a wire state.
pub fn box(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "completed")) return "[x]";
    if (std.mem.eql(u8, state, "in-progress")) return "[>]";
    return "[ ]";
}

fn isSpace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        else => false,
    };
}

/// Text trimmed of ASCII and Unicode spaces; null when not UTF-8.
pub fn trimText(s: []const u8) ?[]const u8 {
    if (!std.unicode.utf8ValidateSlice(s)) return null;
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

pub const Target = union(enum) {
    /// 1-based `todo list` number.
    index: usize,
    id: []const u8,
};

/// `<index|id>`: all ASCII digits (≥ 1) is a list number, otherwise a UUID
/// (any case, braces allowed). Null when neither.
pub fn parseTarget(raw: []const u8) ?Target {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (t.len == 0) return null;
    var digits = true;
    for (t) |c| if (!std.ascii.isDigit(c)) {
        digits = false;
    };
    if (digits) {
        const n = std.fmt.parseUnsigned(usize, t, 10) catch return null;
        return if (n == 0) null else .{ .index = n };
    }
    _ = Uuid.parse(t) catch return null;
    return .{ .id = t };
}

pub fn writeInvalidTarget(w: *Writer, target: []const u8) Writer.Error!void {
    try w.print("Invalid todo item: {s} (expected an item UUID or a 1-based index from `cmux todo list`)", .{target});
}

pub const SetError = error{
    InputTooLarge,
    InvalidJson,
    ExpectedArray,
    ItemNotObject,
    MissingText,
    InvalidText,
    EmptyText,
    InvalidState,
    InvalidOrigin,
    InvalidId,
    DuplicateId,
    TooManyItems,
    OutOfMemory,
};

/// The `todo set` items (validated) or the first error; `index` names the
/// offending element (0-based) for per-item errors.
pub const SetCheck = struct {
    items: []const std.json.Value = &.{},
    index: ?usize = null,
};

fn member(obj: std.json.ObjectMap, name: []const u8) ?std.json.Value {
    const v = obj.get(name) orelse return null;
    return if (v == .null) null else v;
}

/// Validates a `todo set` payload (a JSON array, or `{"items": [...]}`) like
/// the app does, so a bad replace fails before anything is sent.
pub fn checkSet(arena: Allocator, text: []const u8, out: *SetCheck) SetError!void {
    out.* = .{};
    if (text.len > max_input_bytes) return error.InputTooLarge;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    const elems: []const std.json.Value = switch (v) {
        .array => |a| a.items,
        .object => |o| blk: {
            const items = o.get("items") orelse return error.ExpectedArray;
            if (items != .array) return error.ExpectedArray;
            break :blk items.array.items;
        },
        else => return error.ExpectedArray,
    };
    if (elems.len > max_items) return error.TooManyItems;
    var ids: std.ArrayList(Uuid) = .empty;
    for (elems, 0..) |e, i| {
        out.index = i;
        if (e != .object) return error.ItemNotObject;
        const text_v = member(e.object, "text") orelse return error.MissingText;
        if (text_v != .string) return error.InvalidText;
        if (member(e.object, "state")) |s| if (s != .string or !isState(s.string)) return error.InvalidState;
        if (member(e.object, "origin")) |o| if (o != .string or !isOrigin(o.string)) return error.InvalidOrigin;
        if (member(e.object, "id")) |idv| {
            if (idv != .string) return error.InvalidId;
            const id = Uuid.parse(idv.string) catch return error.InvalidId;
            for (ids.items) |prev| if (prev.eql(id)) return error.DuplicateId;
            try ids.append(arena, id);
        }
        const t = trimText(text_v.string) orelse return error.InvalidText;
        if (t.len == 0) return error.EmptyText;
    }
    out.index = null;
    out.items = elems;
}

pub fn writeSetError(w: *Writer, err: SetError, check: SetCheck) Writer.Error!void {
    const msg: []const u8 = switch (err) {
        error.InputTooLarge => "todo set input is too large",
        error.InvalidJson => "todo set input is not valid JSON",
        error.ExpectedArray => "todo set expects a JSON array of {text, state?, id?, origin?} objects or {\"items\": [...]}",
        error.ItemNotObject => "item must be an object",
        error.MissingText => "item is missing \"text\"",
        error.InvalidText => "item \"text\" must be a UTF-8 string",
        error.EmptyText => "item text is empty",
        error.InvalidState => "item \"state\" must be pending, in-progress or completed",
        error.InvalidOrigin => "item \"origin\" must be user or agent",
        error.InvalidId => "item \"id\" must be a UUID",
        error.DuplicateId => "item \"id\" appears more than once",
        error.TooManyItems => "todo set accepts at most 50 items",
        error.OutOfMemory => "out of memory",
    };
    if (check.index) |i| try w.print("item {d}: ", .{i + 1});
    try w.writeAll(msg);
}

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

/// The `items` array of a list payload (empty when absent).
pub fn itemsOf(payload: std.json.Value) ?[]const std.json.Value {
    if (payload != .object) return null;
    const items = payload.object.get("items") orelse return null;
    return if (items == .array) items.array.items else null;
}

pub const Progress = struct { completed: usize, total: usize };

pub fn progressOf(items: []const std.json.Value) Progress {
    var p: Progress = .{ .completed = 0, .total = items.len };
    for (items) |it| {
        if (str(it, "state")) |s| if (std.mem.eql(u8, s, "completed")) {
            p.completed += 1;
        };
    }
    return p;
}

/// `todo list` text from a list payload.
pub fn writeList(w: *Writer, items: []const std.json.Value) Writer.Error!void {
    if (items.len == 0) return w.writeAll("No todo items.\n");
    for (items, 1..) |it, n| {
        try w.print("{d}. {s} {s}", .{ n, box(str(it, "state") orelse "pending"), str(it, "text") orelse "" });
        if (str(it, "origin")) |o| if (std.mem.eql(u8, o, "agent")) try w.writeAll("  (agent)");
        try w.writeByte('\n');
    }
    const p = progressOf(items);
    try w.print("{d}/{d} completed\n", .{ p.completed, p.total });
}

/// Item id at a 1-based list number.
pub fn idAt(items: []const std.json.Value, n: usize) ?[]const u8 {
    if (n == 0 or n > items.len) return null;
    return str(items[n - 1], "id");
}

const testing = std.testing;

test "unit: cli-todo: target syntax mirrors the checklist model" {
    try testing.expectEqual(@as(usize, 3), parseTarget(" 3 ").?.index);
    try testing.expect(parseTarget("0") == null);
    try testing.expect(parseTarget("") == null);
    try testing.expect(parseTarget("-1") == null);
    try testing.expect(parseTarget("0_1") == null);
    try testing.expect(parseTarget("99999999999999999999999") == null);
    try testing.expectEqualStrings("{6BA7B810-9DAD-11D1-80B4-00C04FD430C8}", parseTarget("{6BA7B810-9DAD-11D1-80B4-00C04FD430C8}").?.id);
    try testing.expect(parseTarget("not-a-uuid") == null);
}

test "unit: cli-todo: text trimming handles unicode spaces and rejects bad UTF-8" {
    try testing.expectEqualStrings("write test", trimText("\u{3000} write test \u{a0}\n").?);
    try testing.expectEqualStrings("", trimText(" \t\u{2003}").?);
    try testing.expectEqualStrings("h\u{e9}llo \u{1F600}", trimText("h\u{e9}llo \u{1F600}").?);
    try testing.expect(trimText("\xff") == null);
}

fn expectSetError(text: []const u8, want: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var check: SetCheck = .{};
    const err = if (checkSet(arena_state.allocator(), text, &check)) |_| return error.TestExpectedError else |e| e;
    var aw: Writer.Allocating = .init(arena_state.allocator());
    try writeSetError(&aw.writer, err, check);
    try testing.expectEqualStrings(want, aw.written());
}

test "unit: cli-todo: set payload validation uses the model's messages" {
    try expectSetError("{oops", "todo set input is not valid JSON");
    try expectSetError("\"x\"", "todo set expects a JSON array of {text, state?, id?, origin?} objects or {\"items\": [...]}");
    try expectSetError("{\"items\":3}", "todo set expects a JSON array of {text, state?, id?, origin?} objects or {\"items\": [...]}");
    try expectSetError("[1]", "item 1: item must be an object");
    try expectSetError("[{\"text\":\"a\"},{}]", "item 2: item is missing \"text\"");
    try expectSetError("[{\"text\":5}]", "item 1: item \"text\" must be a UTF-8 string");
    try expectSetError("[{\"text\":\"  \"}]", "item 1: item text is empty");
    try expectSetError("[{\"text\":\"a\",\"state\":\"done\"}]", "item 1: item \"state\" must be pending, in-progress or completed");
    try expectSetError("[{\"text\":\"a\",\"origin\":\"bot\"}]", "item 1: item \"origin\" must be user or agent");
    try expectSetError("[{\"text\":\"a\",\"id\":\"x\"}]", "item 1: item \"id\" must be a UUID");
    const id = "6ba7b810-9dad-11d1-80b4-00c04fd430c8";
    try expectSetError("[{\"text\":\"a\",\"id\":\"" ++ id ++ "\"},{\"text\":\"b\",\"id\":\"" ++ id ++ "\"}]", "item 2: item \"id\" appears more than once");
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    try big.append(testing.allocator, '[');
    for (0..51) |i| {
        if (i > 0) try big.append(testing.allocator, ',');
        try big.appendSlice(testing.allocator, "{\"text\":\"t\"}");
    }
    try big.append(testing.allocator, ']');
    try expectSetError(big.items, "todo set accepts at most 50 items");
    const huge = try testing.allocator.alloc(u8, max_input_bytes + 1);
    defer testing.allocator.free(huge);
    @memset(huge, ' ');
    try expectSetError(huge, "todo set input is too large");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var check: SetCheck = .{};
    try checkSet(arena_state.allocator(), "{\"items\":[{\"text\":\"lint\",\"state\":\"completed\",\"id\":null}]}", &check);
    try testing.expectEqual(@as(usize, 1), check.items.len);
    try checkSet(arena_state.allocator(), "[]", &check);
    try testing.expectEqual(@as(usize, 0), check.items.len);
}
