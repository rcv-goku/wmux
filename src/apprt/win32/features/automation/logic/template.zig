//! `{{…}}` substitution for notify actions (cli-automation-actions):
//! `{{event.name}}`, `{{event.category}}`, `{{event.source}}` and
//! `{{payload.<key>}}`. Whitespace inside the braces is ignored. A payload
//! key is looked up literally first (`payload.a.b` → key `a.b`), then as a
//! nested path. Missing values and JSON null render as the empty string,
//! strings as-is, numbers and booleans as JSON, objects and arrays as minified
//! JSON. Unknown placeholders and unterminated `{{` stay literal. Output is
//! capped at `max_output_bytes` on a code-point boundary (G6).

const std = @import("std");
const wmux_proto = @import("wmux_proto");

const Allocator = std.mem.Allocator;

pub const max_output_bytes: usize = 64 * 1024;

pub const Vars = struct {
    name: []const u8 = "",
    category: ?[]const u8 = null,
    source: ?[]const u8 = null,
    payload: ?*const std.json.ObjectMap = null,
};

const Placeholder = union(enum) {
    event_name,
    event_category,
    event_source,
    payload: []const u8,
};

fn classify(inner_raw: []const u8) ?Placeholder {
    const inner = std.mem.trim(u8, inner_raw, " \t");
    if (std.mem.eql(u8, inner, "event.name")) return .event_name;
    if (std.mem.eql(u8, inner, "event.category")) return .event_category;
    if (std.mem.eql(u8, inner, "event.source")) return .event_source;
    if (std.mem.startsWith(u8, inner, "payload.") and inner.len > "payload.".len) return .{ .payload = inner["payload.".len..] };
    return null;
}

/// Looks up `key` in `obj`: the literal key first, then a dotted path.
pub fn lookupPath(obj: *const std.json.ObjectMap, key: []const u8) ?std.json.Value {
    if (obj.get(key)) |v| return v;
    var cur: std.json.Value = .{ .object = obj.* };
    var it = std.mem.splitScalar(u8, key, '.');
    while (it.next()) |seg| {
        switch (cur) {
            .object => |o| cur = o.get(seg) orelse return null,
            else => return null,
        }
    }
    return cur;
}

fn writeValue(out: *std.Io.Writer, v: std.json.Value) std.Io.Writer.Error!void {
    switch (v) {
        .null => {},
        .string => |s| try out.writeAll(s),
        .number_string => |s| try out.writeAll(s),
        else => try std.json.Stringify.value(v, .{}, out),
    }
}

/// Renders `tmpl`. The result is owned by `gpa`.
pub fn render(gpa: Allocator, tmpl: []const u8, vars: Vars) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    var i: usize = 0;
    while (i < tmpl.len) {
        if (aw.written().len > max_output_bytes) break;
        const open = std.mem.indexOfPos(u8, tmpl, i, "{{") orelse {
            w.writeAll(tmpl[i..]) catch return error.OutOfMemory;
            break;
        };
        w.writeAll(tmpl[i..open]) catch return error.OutOfMemory;
        const close = std.mem.indexOfPos(u8, tmpl, open + 2, "}}") orelse {
            w.writeAll(tmpl[open..]) catch return error.OutOfMemory;
            break;
        };
        const ph = classify(tmpl[open + 2 .. close]) orelse {
            // Unknown: keep one brace literal and rescan, so `{{{x}}}` still finds `{{x}}`.
            w.writeAll("{") catch return error.OutOfMemory;
            i = open + 1;
            continue;
        };
        switch (ph) {
            .event_name => w.writeAll(vars.name) catch return error.OutOfMemory,
            .event_category => w.writeAll(vars.category orelse "") catch return error.OutOfMemory,
            .event_source => w.writeAll(vars.source orelse "") catch return error.OutOfMemory,
            .payload => |key| if (vars.payload) |p| {
                if (lookupPath(p, key)) |v| writeValue(w, v) catch return error.OutOfMemory;
            },
        }
        i = close + 2;
    }
    const all = aw.written();
    const kept = wmux_proto.utf8.truncateUtf8(all, max_output_bytes);
    aw.shrinkRetainingCapacity(kept.len);
    return aw.toOwnedSlice();
}

pub const Problem = struct {
    offset: usize,
    message: []const u8,
};

/// The first placeholder `render` would leave literal, for a load-time warning.
pub fn check(tmpl: []const u8) ?Problem {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, tmpl, i, "{{")) |open| {
        const close = std.mem.indexOfPos(u8, tmpl, open + 2, "}}") orelse
            return .{ .offset = open, .message = "unterminated {{ placeholder" };
        if (classify(tmpl[open + 2 .. close]) == null) {
            if (open + 2 < tmpl.len and tmpl[open + 2] == '{') {
                i = open + 1;
                continue;
            }
            return .{ .offset = open, .message = "unknown placeholder; use {{event.name}}, {{event.category}}, {{event.source}} or {{payload.<key>}}" };
        }
        i = close + 2;
    }
    return null;
}

const testing = std.testing;

test "unit: automation: template substitutes event and payload values" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"session_id":"s-1","n":42,"ok":true,"none":null,"obj":{"a":[1,"x"]},"a.b":"lit","u":"✓ ünï"}
    , .{});
    const vars: Vars = .{ .name = "agent.needs_input", .category = "agent", .source = "agents.store", .payload = &v.object };
    const cases = [_][2][]const u8{
        .{ "Session {{payload.session_id}} paused", "Session s-1 paused" },
        .{ "{{event.name}}/{{ event.category }}/{{event.source}}", "agent.needs_input/agent/agents.store" },
        .{ "{{payload.n}} {{payload.ok}} [{{payload.none}}] [{{payload.missing}}]", "42 true [] []" },
        .{ "{{payload.obj}}", "{\"a\":[1,\"x\"]}" },
        .{ "{{payload.obj.a}}", "[1,\"x\"]" },
        .{ "{{payload.a.b}}", "lit" },
        .{ "{{payload.u}}", "✓ ünï" },
        .{ "", "" },
        .{ "no placeholders", "no placeholders" },
        .{ "{{unknown}} {{event.name}}", "{{unknown}} agent.needs_input" },
        .{ "{{{event.name}}}", "{agent.needs_input}" },
        .{ "tail {{event.name", "tail {{event.name" },
        .{ "{{payload.}}", "{{payload.}}" },
    };
    for (cases) |c| {
        const out = try render(testing.allocator, c[0], vars);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c[1], out);
    }
    // Without a payload, payload placeholders are empty; missing category too.
    const out = try render(testing.allocator, "[{{payload.x}}][{{event.category}}]", .{ .name = "x" });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[][]", out);
}

test "unit: automation: template output is capped on a code point boundary" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const big = try arena.alloc(u8, max_output_bytes * 2);
    for (0..big.len / 2) |k| @memcpy(big[k * 2 ..][0..2], "é");
    var obj: std.json.ObjectMap = .init(arena);
    try obj.put("big", .{ .string = big });
    const out = try render(testing.allocator, "x{{payload.big}}{{payload.big}}", .{ .payload = &obj });
    defer testing.allocator.free(out);
    try testing.expect(out.len <= max_output_bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "unit: automation: template check reports placeholders render keeps literal" {
    try testing.expect(check("") == null);
    try testing.expect(check("Session {{payload.session_id}} {{ event.name }}") == null);
    try testing.expectEqual(@as(usize, 2), check("a {{payload}}").?.offset);
    try testing.expect(check("{{event.name") != null);
    try testing.expect(check("{{workspace.title}}") != null);
    try testing.expect(check("{{{event.name}}}") == null);
}
