//! `todo set` / `workspace.todo.set`: atomic replace of a checklist from a JSON
//! array of `{text, state?, id?, origin?}` objects (or `{"items": [...]}`).
//! Items whose `id` names an existing item keep that identity and origin and
//! update text (and state when given); other items are created (`origin`
//! defaults to `user`, `state` to `pending`); unnamed items are removed.
//! Any validation failure rejects the whole replace with nothing mutated.

const std = @import("std");
const proto = @import("wmux_proto");
const checklist = @import("checklist.zig");
const Allocator = std.mem.Allocator;
const Uuid = proto.uuid.Uuid;
const Checklist = checklist.Checklist;
const Item = checklist.Item;

/// Inline argument or stdin payloads above this size are rejected.
pub const max_input_bytes = 1 << 20;

pub const Error = error{
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

/// Where a per-item error happened (0-based element index), when known.
pub const Diagnostic = struct {
    index: ?usize = null,
};

/// Validates the `json` text (inline argument or stdin) and atomically
/// replaces `list`'s items. On error `list` is unchanged and `diag.index`
/// names the offending element if any.
pub fn replace(gpa: Allocator, list: *Checklist, json: []const u8, diag: ?*Diagnostic) Error!void {
    if (diag) |d| d.* = .{};
    if (json.len > max_input_bytes) return error.InputTooLarge;

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
    return replaceValue(gpa, list, parsed.value, diag);
}

/// `replace` for an already-parsed payload: an array, or an object whose
/// `items` member is one (other members are ignored). RPC params arrive
/// parsed (`wmux_proto.envelope` hands handlers an ObjectMap), so a
/// `workspace.todo.set` handler passes `.{ .object = params }` here rather
/// than re-encoding them and parsing again on the UI thread. Session
/// restore can rebuild a checklist the same way. Nothing in `payload` is
/// retained: every string is copied.
pub fn replaceValue(gpa: Allocator, list: *Checklist, payload: std.json.Value, diag: ?*Diagnostic) Error!void {
    var scratch: Diagnostic = .{};
    const d = diag orelse &scratch;
    d.* = .{};

    const elems: []const std.json.Value = switch (payload) {
        .array => |a| a.items,
        .object => |o| blk: {
            const v = o.get("items") orelse return error.ExpectedArray;
            if (v != .array) return error.ExpectedArray;
            break :blk v.array.items;
        },
        else => return error.ExpectedArray,
    };
    if (elems.len > checklist.max_items) return error.TooManyItems;

    var next: std.ArrayList(Item) = try .initCapacity(gpa, elems.len);
    defer {
        for (next.items) |it| gpa.free(it.text);
        next.deinit(gpa);
    }

    for (elems, 0..) |elem, i| {
        d.index = i;
        const item = try buildItem(gpa, list, elem);
        for (next.items) |prev| {
            if (prev.id.eql(item.id)) {
                gpa.free(item.text);
                return error.DuplicateId;
            }
        }
        next.appendAssumeCapacity(item);
    }
    d.index = null;

    // Commit: swap storage; the old items are freed by the deferred cleanup.
    std.mem.swap(std.ArrayList(Item), &list.items, &next);
}

fn buildItem(gpa: Allocator, list: *const Checklist, elem: std.json.Value) Error!Item {
    if (elem != .object) return error.ItemNotObject;
    const obj = elem.object;

    const text_v = field(obj, "text") orelse return error.MissingText;
    if (text_v != .string) return error.InvalidText;

    var state: ?checklist.State = null;
    if (field(obj, "state")) |v| {
        if (v != .string) return error.InvalidState;
        state = checklist.State.parse(v.string) orelse return error.InvalidState;
    }
    var origin: ?checklist.Origin = null;
    if (field(obj, "origin")) |v| {
        if (v != .string) return error.InvalidOrigin;
        origin = checklist.Origin.parse(v.string) orelse return error.InvalidOrigin;
    }
    var id: ?Uuid = null;
    if (field(obj, "id")) |v| {
        if (v != .string) return error.InvalidId;
        id = Uuid.parse(v.string) catch return error.InvalidId;
    }

    const text = checklist.normalizeText(gpa, text_v.string) catch |err| switch (err) {
        error.EmptyText => return error.EmptyText,
        error.InvalidUtf8 => return error.InvalidText,
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (id) |want| {
        if (list.indexOfId(want)) |at| {
            const existing = list.items.items[at];
            return .{
                .id = existing.id,
                .text = text,
                .state = state orelse existing.state,
                .origin = existing.origin,
            };
        }
    }
    return .{
        .id = id orelse Uuid.v4(),
        .text = text,
        .state = state orelse .pending,
        .origin = origin orelse .user,
    };
}

/// A present, non-null member.
fn field(obj: std.json.ObjectMap, name: []const u8) ?std.json.Value {
    const v = obj.get(name) orelse return null;
    return if (v == .null) null else v;
}

/// Human-readable message for a `replace` error (CLI stderr / RPC message).
pub fn writeError(w: *std.Io.Writer, err: Error, diag: Diagnostic) std.Io.Writer.Error!void {
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
    if (diag.index) |i| try w.print("item {d}: ", .{i + 1});
    try w.writeAll(msg);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testId(n: u8) Uuid {
    return Uuid.fromRandomBytes(@splat(n));
}

test "unit: todo: set replaces the list from a bare array with defaults" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    _ = try c.add(gpa, "old", .{});
    try replace(gpa, &c, "[{\"text\":\"lint\",\"state\":\"completed\"},{\"text\":\" test \"}]", null);
    try testing.expectEqual(@as(usize, 2), c.len());
    try testing.expectEqualStrings("lint", c.items.items[0].text);
    try testing.expectEqual(checklist.State.completed, c.items.items[0].state);
    try testing.expectEqualStrings("test", c.items.items[1].text);
    try testing.expectEqual(checklist.State.pending, c.items.items[1].state);
    try testing.expectEqual(checklist.Origin.user, c.items.items[1].origin);
}

test "unit: todo: set accepts the items wrapper and an empty array clears" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    try replace(gpa, &c, "{\"items\":[{\"text\":\"a\",\"origin\":\"agent\"}]}", null);
    try testing.expectEqual(@as(usize, 1), c.len());
    try testing.expectEqual(checklist.Origin.agent, c.items.items[0].origin);
    try replace(gpa, &c, " [ ] ", null);
    try testing.expectEqual(@as(usize, 0), c.len());
    try replace(gpa, &c, "{\"items\":[]}", null);
    try testing.expectEqual(@as(usize, 0), c.len());
}

test "unit: todo: set with matching ids keeps identity and origin" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    _ = try c.add(gpa, "a", .{ .id = testId(1), .origin = .agent, .state = .in_progress });
    _ = try c.add(gpa, "b", .{ .id = testId(2) });
    _ = try c.add(gpa, "gone", .{ .id = testId(3) });
    const id1 = testId(1).toText();
    const id2 = testId(2).toText();
    const json = try std.fmt.allocPrint(gpa,
        \\[{{"id":"{s}","text":"b2","state":"completed"}},
        \\ {{"id":"{s}","text":"a2","origin":"user"}},
        \\ {{"text":"new"}}]
    , .{ &id2, &id1 });
    defer gpa.free(json);
    try replace(gpa, &c, json, null);
    try testing.expectEqual(@as(usize, 3), c.len());
    const items = c.items.items;
    try testing.expect(items[0].id.eql(testId(2)));
    try testing.expectEqualStrings("b2", items[0].text);
    try testing.expectEqual(checklist.State.completed, items[0].state);
    // Origin of an existing item is preserved even when the payload names one;
    // state stays when not given.
    try testing.expect(items[1].id.eql(testId(1)));
    try testing.expectEqual(checklist.Origin.agent, items[1].origin);
    try testing.expectEqual(checklist.State.in_progress, items[1].state);
    try testing.expect(c.indexOfId(testId(3)) == null);

    // Re-running the same payload is stable.
    try replace(gpa, &c, json, null);
    try testing.expect(c.items.items[0].id.eql(testId(2)));
    try testing.expect(c.items.items[1].id.eql(testId(1)));
}

test "unit: todo: set takes already-parsed rpc params and copies their strings" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    _ = try c.add(gpa, "old", .{ .id = testId(1), .origin = .agent });
    _ = try c.add(gpa, "gone", .{ .id = testId(2) });
    const id1 = testId(1).toText();
    const params_json = try std.fmt.allocPrint(gpa,
        \\{{"workspace_id":"workspace:2","items":[{{"id":"{s}","text":" kept ","state":"completed"}},{{"text":"new","origin":"agent"}}]}}
    , .{&id1});
    defer gpa.free(params_json);
    {
        const params = try std.json.parseFromSlice(std.json.Value, gpa, params_json, .{});
        defer params.deinit();
        try replaceValue(gpa, &c, .{ .object = params.value.object }, null);
    }
    // The parsed tree is gone; the checklist owns copies.
    try testing.expectEqual(@as(usize, 2), c.len());
    const items = c.items.items;
    try testing.expect(items[0].id.eql(testId(1)));
    try testing.expectEqualStrings("kept", items[0].text);
    try testing.expectEqual(checklist.State.completed, items[0].state);
    try testing.expectEqual(checklist.Origin.agent, items[0].origin);
    try testing.expectEqualStrings("new", items[1].text);
    try testing.expectEqual(checklist.Origin.agent, items[1].origin);
    try testing.expect(c.indexOfId(testId(2)) == null);

    // Same validation as the text form, and nothing mutated on failure.
    var d: Diagnostic = .{ .index = 7 };
    try testing.expectError(error.ExpectedArray, replaceValue(gpa, &c, .null, &d));
    try testing.expectEqual(@as(?usize, null), d.index);
    try testing.expectError(error.ExpectedArray, replaceValue(gpa, &c, .{ .string = "[]" }, &d));
    const bad = try std.json.parseFromSlice(std.json.Value, gpa, "[{\"text\":\"ok\"},{\"text\":\" \"}]", .{});
    defer bad.deinit();
    try testing.expectError(error.EmptyText, replaceValue(gpa, &c, bad.value, &d));
    try testing.expectEqual(@as(?usize, 1), d.index);
    try testing.expectEqual(@as(usize, 2), c.len());
    try testing.expectEqualStrings("kept", c.items.items[0].text);
}

test "unit: todo: set accepts the list's own json payload unchanged" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    _ = try c.add(gpa, "a", .{ .id = testId(1), .origin = .agent, .state = .in_progress });
    // A restored snapshot that repeats an id must not break the round trip.
    _ = try c.add(gpa, "b", .{ .id = testId(1) });
    _ = try c.add(gpa, "c", .{ .state = .completed });
    // `cmux todo list --json | cmux todo set`
    const before = try std.json.Stringify.valueAlloc(gpa, &c, .{});
    defer gpa.free(before);
    try replace(gpa, &c, before, null);
    const after = try std.json.Stringify.valueAlloc(gpa, &c, .{});
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);
}

test "unit: todo: set adopts an unknown valid id and accepts lowercase ids" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    const id = testId(7).toText();
    const lower = try std.ascii.allocLowerString(gpa, &id);
    defer gpa.free(lower);
    const json = try std.fmt.allocPrint(gpa, "[{{\"id\":\"{s}\",\"text\":\"x\"}}]", .{lower});
    defer gpa.free(json);
    try replace(gpa, &c, json, null);
    try testing.expect(c.items.items[0].id.eql(testId(7)));
}

test "unit: todo: set rejects the whole replace and mutates nothing" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    _ = try c.add(gpa, "keep", .{ .id = testId(1) });
    const id = testId(5).toText();
    const dup = try std.fmt.allocPrint(gpa, "[{{\"id\":\"{s}\",\"text\":\"a\"}},{{\"id\":\"{s}\",\"text\":\"b\"}}]", .{ &id, &id });
    defer gpa.free(dup);

    const Case = struct { json: []const u8, err: Error, index: ?usize };
    const cases = [_]Case{
        .{ .json = "", .err = error.InvalidJson, .index = null },
        .{ .json = "[{\"text\":\"a\"}", .err = error.InvalidJson, .index = null },
        .{ .json = "\"text\"", .err = error.ExpectedArray, .index = null },
        .{ .json = "{\"list\":[]}", .err = error.ExpectedArray, .index = null },
        .{ .json = "{\"items\":{}}", .err = error.ExpectedArray, .index = null },
        .{ .json = "[{\"text\":\"ok\"},{\"text\":\"  \"}]", .err = error.EmptyText, .index = 1 },
        .{ .json = "[{\"text\":\"ok\"},3]", .err = error.ItemNotObject, .index = 1 },
        .{ .json = "[{\"state\":\"pending\"}]", .err = error.MissingText, .index = 0 },
        .{ .json = "[{\"text\":null}]", .err = error.MissingText, .index = 0 },
        .{ .json = "[{\"text\":5}]", .err = error.InvalidText, .index = 0 },
        .{ .json = "[{\"text\":\"a\",\"state\":\"done\"}]", .err = error.InvalidState, .index = 0 },
        .{ .json = "[{\"text\":\"a\",\"state\":1}]", .err = error.InvalidState, .index = 0 },
        .{ .json = "[{\"text\":\"a\",\"origin\":\"bot\"}]", .err = error.InvalidOrigin, .index = 0 },
        .{ .json = "[{\"text\":\"a\",\"id\":\"lint\"}]", .err = error.InvalidId, .index = 0 },
        .{ .json = dup, .err = error.DuplicateId, .index = 1 },
    };
    for (cases) |case| {
        var d: Diagnostic = .{};
        try testing.expectError(case.err, replace(gpa, &c, case.json, &d));
        try testing.expectEqual(case.index, d.index);
        try testing.expectEqual(@as(usize, 1), c.len());
        try testing.expectEqualStrings("keep", c.items.items[0].text);
    }
}

test "unit: todo: set caps at 50 items and rejects oversized input" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.writeByte('[');
    var i: usize = 0;
    while (i < 51) : (i += 1) {
        if (i > 0) try aw.writer.writeByte(',');
        try aw.writer.print("{{\"text\":\"t{d}\"}}", .{i});
    }
    try aw.writer.writeByte(']');
    try testing.expectError(error.TooManyItems, replace(gpa, &c, aw.written(), null));
    try testing.expectEqual(@as(usize, 0), c.len());

    // Exactly 50 is accepted.
    const fifty = aw.written()[0..std.mem.lastIndexOfScalar(u8, aw.written(), ',').?];
    const json50 = try std.mem.concat(gpa, u8, &.{ fifty, "]" });
    defer gpa.free(json50);
    try replace(gpa, &c, json50, null);
    try testing.expectEqual(@as(usize, 50), c.len());

    const huge = try gpa.alloc(u8, max_input_bytes + 1);
    defer gpa.free(huge);
    @memset(huge, ' ');
    try testing.expectError(error.InputTooLarge, replace(gpa, &c, huge, null));
    try testing.expectEqual(@as(usize, 50), c.len());
}

test "unit: todo: set truncates long unicode text and ignores unknown keys" {
    const gpa = testing.allocator;
    var c: Checklist = .{};
    defer c.deinit(gpa);
    const long = "\u{1F680}" ** 600;
    const json = try std.fmt.allocPrint(gpa, "[{{\"text\":\"{s}\",\"images\":[],\"state\":null}}]", .{long});
    defer gpa.free(json);
    try replace(gpa, &c, json, null);
    try testing.expectEqual(@as(usize, 500), try std.unicode.utf8CountCodepoints(c.items.items[0].text));
    try testing.expectEqual(checklist.State.pending, c.items.items[0].state);
    // JSON escapes decode before trimming.
    try replace(gpa, &c, "[{\"text\":\"\\u00e9t\\u00e9\\n\"}]", null);
    try testing.expectEqualStrings("\u{e9}t\u{e9}", c.items.items[0].text);
}

test "unit: todo: set leaves the list untouched when an allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, replaceUnderAllocationFailure, .{});
}

fn replaceUnderAllocationFailure(gpa: Allocator) !void {
    var c: Checklist = .{};
    defer c.deinit(gpa);
    _ = try c.add(gpa, "keep", .{ .id = testId(1), .origin = .agent });
    _ = try c.add(gpa, "drop", .{ .id = testId(2) });
    var buf: [192]u8 = undefined;
    const id1 = testId(1).toText();
    const json = try std.fmt.bufPrint(&buf,
        \\{{"items":[{{"id":"{s}","text":" kept ","state":"completed"}},{{"text":"new"}}]}}
    , .{&id1});
    replace(gpa, &c, json, null) catch |err| {
        try testing.expectEqual(@as(usize, 2), c.len());
        try testing.expectEqualStrings("keep", c.items.items[0].text);
        try testing.expectEqualStrings("drop", c.items.items[1].text);
        return err;
    };
    try testing.expectEqual(@as(usize, 2), c.len());
    try testing.expect(c.items.items[0].id.eql(testId(1)));
    try testing.expectEqualStrings("kept", c.items.items[0].text);
    try testing.expectEqual(checklist.Origin.agent, c.items.items[0].origin);
    try testing.expectEqualStrings("new", c.items.items[1].text);
}

test "unit: todo: set error messages name the element" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeError(&w, error.EmptyText, .{ .index = 1 });
    try testing.expectEqualStrings("item 2: item text is empty", w.buffered());
    w = .fixed(&buf);
    try writeError(&w, error.TooManyItems, .{});
    try testing.expectEqualStrings("todo set accepts at most 50 items", w.buffered());
}
