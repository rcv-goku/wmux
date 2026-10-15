//! Selector parsing shared by the RPC router and the CLI: canonical `*_id` keys,
//! UUID/ref/index forms and cmux's exact selector errors (ADR-2.6, ADR-4.6).
//!
//! Server side: `parse` reads the routing selectors out of a request's
//! `params` and fails closed with a `Failure` (code, message, offending key).
//! Client side: `cliMessage` renders cmux's CLI handle errors.

const std = @import("std");
const Allocator = std.mem.Allocator;
const handles = @import("handles.zig");
const errors = @import("errors.zig");
const Kind = handles.Kind;
const HandleText = handles.HandleText;

/// Canonical routing selector keys.
pub const Key = enum {
    window_id,
    group_id,
    workspace_id,
    surface_id,
    terminal_id,
    tab_id,
    pane_id,

    pub fn text(k: Key) []const u8 {
        return @tagName(k);
    }

    /// Object kind the key selects (`terminal_id`/`tab_id` select surfaces).
    pub fn kind(k: Key) Kind {
        return switch (k) {
            .window_id => .window,
            .group_id => .workspace_group,
            .workspace_id => .workspace,
            .surface_id, .terminal_id, .tab_id => .surface,
            .pane_id => .pane,
        };
    }
};

/// Server precedence (ADR-2.6): window → group → workspace → surface
/// (aliases terminal, tab) → pane.
pub const precedence = [_]Key{ .window_id, .group_id, .workspace_id, .surface_id, .terminal_id, .tab_id, .pane_id };

/// The canonical key `key` spells, ignoring ASCII case and underscores
/// (`surfaceID`, `Surface_Id`, `surface__id` → `surface_id`); null when `key`
/// is not a routing selector spelling at all.
pub fn canonicalize(key: []const u8) ?Key {
    var buf: [16]u8 = undefined;
    var n: usize = 0;
    for (key) |c| {
        if (c == '_') continue;
        if (n == buf.len) return null;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    const folded = buf[0..n];
    inline for (@typeInfo(Key).@"enum".fields) |f| {
        const want = comptime blk: {
            var out: []const u8 = "";
            for (f.name) |c| {
                if (c != '_') out = out ++ &[_]u8{c};
            }
            break :blk out;
        };
        if (std.mem.eql(u8, folded, want)) return @enumFromInt(f.value);
    }
    return null;
}

/// Canonical key for a non-canonical spelling; null for exact canonical keys
/// and for unrelated keys.
pub fn nonCanonical(key: []const u8) ?Key {
    const k = canonicalize(key) orelse return null;
    if (std.mem.eql(u8, key, k.text())) return null;
    return k;
}

pub const Unsupported = struct {
    given: []const u8,
    canonical: Key,
};

/// First non-canonical routing key in `obj` (insertion order).
pub fn findNonCanonical(obj: *const std.json.ObjectMap) ?Unsupported {
    var it = obj.iterator();
    while (it.next()) |e| {
        if (nonCanonical(e.key_ptr.*)) |k| return .{ .given = e.key_ptr.*, .canonical = k };
    }
    return null;
}

/// `Unsupported parameter '<x>'; use '<canonical>'` (cmux string).
pub fn unsupportedMessage(gpa: Allocator, u: Unsupported) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "Unsupported parameter '{s}'; use '{s}'", .{ u.given, u.canonical.text() });
}

/// Selectors present in a request, aliases folded into `surface`.
pub const Selectors = struct {
    window: ?HandleText = null,
    group: ?HandleText = null,
    workspace: ?HandleText = null,
    surface: ?HandleText = null,
    pane: ?HandleText = null,

    pub fn isEmpty(self: Selectors) bool {
        return self.window == null and self.group == null and self.workspace == null and
            self.surface == null and self.pane == null;
    }

    pub fn get(self: Selectors, kind: Kind) ?HandleText {
        return switch (kind) {
            .window => self.window,
            .workspace_group => self.group,
            .workspace => self.workspace,
            .surface => self.surface,
            .pane => self.pane,
        };
    }
};

/// Why `parse` rejected a request. `message` is static or allocated in the
/// arena passed to `parse`.
pub const Failure = struct {
    code: errors.Code,
    message: []const u8,
    /// The offending key as sent (for `data.selector`).
    key: []const u8,
};

pub const ValueError = error{ Blank, Invalid, WrongKind };

/// One selector value: JSON null → absent, string → `handles.parseHandle`,
/// non-negative integer within u32 → index (wmux leniency, Appendix E D15).
pub fn parseValue(kind: Kind, v: std.json.Value) ValueError!?HandleText {
    return switch (v) {
        .null => null,
        .string => |s| try handles.parseHandle(kind, s),
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32))
            HandleText{ .index = @intCast(i) }
        else
            error.Invalid,
        else => error.Invalid,
    };
}

pub const ParseError = error{ Rejected, OutOfMemory };

/// Reads the routing selectors of `params`. Rejections (fail closed, never
/// "absent"):
/// - a non-canonical spelling → `invalid_params` "Unsupported parameter …"
/// - a blank or malformed value → `invalid_params`
/// - a ref of another kind (`workspace_id: "pane:1"`) → `not_found` with the
///   routing message for the expected kind
pub fn parse(arena: Allocator, params: *const std.json.ObjectMap, failure: *Failure) ParseError!Selectors {
    if (findNonCanonical(params)) |u| {
        failure.* = .{ .code = .invalid_params, .message = try unsupportedMessage(arena, u), .key = u.given };
        return error.Rejected;
    }
    var out: Selectors = .{};
    for (precedence) |key| {
        const v = params.get(key.text()) orelse continue;
        const kind = key.kind();
        const h = parseValue(kind, v) catch |err| {
            failure.* = try valueFailure(arena, key.text(), kind, err);
            return error.Rejected;
        } orelse continue;
        const slot: *?HandleText = switch (kind) {
            .window => &out.window,
            .workspace_group => &out.group,
            .workspace => &out.workspace,
            .surface => &out.surface,
            .pane => &out.pane,
        };
        // surface_id beats terminal_id beats tab_id.
        if (slot.* == null) slot.* = h;
    }
    return out;
}

/// The cmux `caller` object inside `params` (ADR-3.9).
pub const Caller = struct {
    workspace: ?HandleText = null,
    surface: ?HandleText = null,
};

/// Parses `params.caller {workspace_id, surface_id|tab_id}`. Absent or null
/// → null. A non-object caller or a bad value is rejected like a selector.
pub fn parseCaller(arena: Allocator, params: *const std.json.ObjectMap, failure: *Failure) ParseError!?Caller {
    const v = params.get("caller") orelse return null;
    const obj = switch (v) {
        .null => return null,
        .object => |*o| o,
        else => {
            failure.* = .{ .code = .invalid_params, .message = "Invalid caller: expected an object", .key = "caller" };
            return error.Rejected;
        },
    };
    if (findNonCanonical(obj)) |u| {
        failure.* = .{ .code = .invalid_params, .message = try unsupportedMessage(arena, u), .key = u.given };
        return error.Rejected;
    }
    var out: Caller = .{};
    const keys = [_]Key{ .workspace_id, .surface_id, .tab_id };
    for (keys) |key| {
        const field = obj.get(key.text()) orelse continue;
        const h = parseValue(key.kind(), field) catch |err| {
            failure.* = try valueFailure(arena, key.text(), key.kind(), err);
            return error.Rejected;
        } orelse continue;
        if (key == .workspace_id) {
            out.workspace = h;
        } else if (out.surface == null) {
            out.surface = h;
        }
    }
    return out;
}

fn valueFailure(arena: Allocator, key: []const u8, kind: Kind, err: ValueError) Allocator.Error!Failure {
    return switch (err) {
        error.WrongKind => .{ .code = .not_found, .message = errors.notFoundMessage(kind), .key = key },
        error.Blank, error.Invalid => .{
            .code = .invalid_params,
            .message = try std.fmt.allocPrint(arena, "Invalid {s}: expected UUID, ref like {s}:1, or index", .{ key, kind.name() }),
            .key = key,
        },
    };
}

/// CLI-side handle problems with cmux's exact messages (ADR-4.6).
pub const CliProblem = enum {
    /// `Surface handle is blank`
    blank,
    /// `Invalid surface handle: X (expected UUID, ref like surface:1, or index)`
    invalid,
    /// `Surface ref not found: X`
    ref_not_found,
    /// `Surface index not found`
    index_not_found,
};

/// Renders a CLI handle error for `kind`; `text` is the handle as typed.
pub fn cliMessage(gpa: Allocator, problem: CliProblem, kind: Kind, text: []const u8) Allocator.Error![]u8 {
    return switch (problem) {
        .blank => std.fmt.allocPrint(gpa, "{s} handle is blank", .{kind.nounCapitalized()}),
        .invalid => std.fmt.allocPrint(gpa, "Invalid {s} handle: {s} (expected UUID, ref like {s}:1, or index)", .{ kind.noun(), text, kind.name() }),
        .ref_not_found => std.fmt.allocPrint(gpa, "{s} ref not found: {s}", .{ kind.nounCapitalized(), text }),
        .index_not_found => std.fmt.allocPrint(gpa, "{s} index not found", .{kind.nounCapitalized()}),
    };
}

/// Maps a `parseHandle` error to the CLI problem (`WrongKind` is reported as
/// an invalid handle, since the CLI names the expected form).
pub fn cliProblemFor(err: handles.ParseHandleError) CliProblem {
    return switch (err) {
        error.Blank => .blank,
        error.Invalid, error.WrongKind => .invalid,
    };
}

const testing = std.testing;

fn parseParams(arena: Allocator, json: []const u8) !std.json.ObjectMap {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    return v.object;
}

test "unit: proto: selectors canonicalize spellings" {
    try testing.expectEqual(@as(?Key, .surface_id), canonicalize("surface_id"));
    try testing.expectEqual(@as(?Key, .surface_id), canonicalize("surfaceId"));
    try testing.expectEqual(@as(?Key, .surface_id), canonicalize("SURFACE_ID"));
    try testing.expectEqual(@as(?Key, .surface_id), canonicalize("surface__id"));
    try testing.expectEqual(@as(?Key, .workspace_id), canonicalize("workspaceID"));
    try testing.expectEqual(@as(?Key, .terminal_id), canonicalize("terminalId"));
    try testing.expectEqual(@as(?Key, .tab_id), canonicalize("tabId"));
    try testing.expectEqual(@as(?Key, .group_id), canonicalize("groupId"));
    try testing.expectEqual(@as(?Key, .window_id), canonicalize("_window_id_"));
    try testing.expectEqual(@as(?Key, null), canonicalize("surface"));
    try testing.expectEqual(@as(?Key, null), canonicalize("surface_ids"));
    try testing.expectEqual(@as(?Key, null), canonicalize(""));
    try testing.expectEqual(@as(?Key, null), canonicalize("a_very_long_key_name_beyond_buffer"));
    try testing.expectEqual(@as(?Key, null), canonicalize("surface-id"));
    try testing.expectEqual(@as(?Key, null), canonicalize("s\u{fc}rface_id"));
}

test "unit: proto: selectors nonCanonical ignores exact keys" {
    for (precedence) |k| try testing.expectEqual(@as(?Key, null), nonCanonical(k.text()));
    try testing.expectEqual(@as(?Key, .pane_id), nonCanonical("paneId"));
    try testing.expectEqual(@as(?Key, null), nonCanonical("text"));
}

test "unit: proto: selectors rejects non-canonical key with cmux message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const params = try parseParams(arena, "{\"text\":\"hi\",\"surfaceId\":\"x\"}");
    var f: Failure = undefined;
    try testing.expectError(error.Rejected, parse(arena, &params, &f));
    try testing.expectEqual(errors.Code.invalid_params, f.code);
    try testing.expectEqualStrings("Unsupported parameter 'surfaceId'; use 'surface_id'", f.message);
    try testing.expectEqualStrings("surfaceId", f.key);
}

test "unit: proto: selectors parses all forms" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const params = try parseParams(arena,
        \\{"window_id":0,"workspace_id":"workspace:2","pane_id":"9b690abc-def0-4123-8456-789abcdef012",
        \\ "tab_id":"tab:4","group_id":null,"focus":false}
    );
    var f: Failure = undefined;
    const s = try parse(arena, &params, &f);
    try testing.expectEqual(HandleText{ .index = 0 }, s.window.?);
    try testing.expectEqual(HandleText{ .ref = .{ .kind = .workspace, .n = 2 } }, s.workspace.?);
    try testing.expectEqual(HandleText{ .ref = .{ .kind = .surface, .n = 4 } }, s.surface.?);
    try testing.expectEqualStrings("9B690ABC-DEF0-4123-8456-789ABCDEF012", &s.pane.?.uuid.toText());
    try testing.expectEqual(@as(?HandleText, null), s.group);
    try testing.expect(!s.isEmpty());
    try testing.expectEqual(s.workspace, s.get(.workspace));
}

test "unit: proto: selectors surface alias precedence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const params = try parseParams(arena, "{\"tab_id\":\"surface:3\",\"terminal_id\":\"surface:2\",\"surface_id\":\"surface:1\"}");
    var f: Failure = undefined;
    const s = try parse(arena, &params, &f);
    try testing.expectEqual(@as(u32, 1), s.surface.?.ref.n);
    const empty = try parseParams(arena, "{}");
    try testing.expect((try parse(arena, &empty, &f)).isEmpty());
}

test "unit: proto: selectors value failures" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var f: Failure = undefined;

    const wrong = try parseParams(arena, "{\"workspace_id\":\"pane:1\"}");
    try testing.expectError(error.Rejected, parse(arena, &wrong, &f));
    try testing.expectEqual(errors.Code.not_found, f.code);
    try testing.expectEqualStrings("Workspace not found", f.message);

    const cases = [_][]const u8{
        "{\"surface_id\":\"\"}",
        "{\"surface_id\":\"  \"}",
        "{\"surface_id\":\"bogus\"}",
        "{\"surface_id\":-1}",
        "{\"surface_id\":4294967296}",
        "{\"surface_id\":1.5}",
        "{\"surface_id\":true}",
        "{\"surface_id\":{}}",
        "{\"surface_id\":[]}",
    };
    for (cases) |c| {
        const p = try parseParams(arena, c);
        try testing.expectError(error.Rejected, parse(arena, &p, &f));
        try testing.expectEqual(errors.Code.invalid_params, f.code);
        try testing.expectEqualStrings("surface_id", f.key);
        try testing.expectEqualStrings("Invalid surface_id: expected UUID, ref like surface:1, or index", f.message);
    }
}

test "unit: proto: selectors caller object" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var f: Failure = undefined;
    const p = try parseParams(arena, "{\"caller\":{\"workspace_id\":\"workspace:1\",\"tab_id\":\"surface:5\"}}");
    const c = (try parseCaller(arena, &p, &f)).?;
    try testing.expectEqual(@as(u32, 1), c.workspace.?.ref.n);
    try testing.expectEqual(@as(u32, 5), c.surface.?.ref.n);

    const none = try parseParams(arena, "{\"caller\":null}");
    try testing.expectEqual(@as(?Caller, null), try parseCaller(arena, &none, &f));
    const absent = try parseParams(arena, "{}");
    try testing.expectEqual(@as(?Caller, null), try parseCaller(arena, &absent, &f));

    const bad = try parseParams(arena, "{\"caller\":\"x\"}");
    try testing.expectError(error.Rejected, parseCaller(arena, &bad, &f));
    const camel = try parseParams(arena, "{\"caller\":{\"surfaceId\":\"surface:1\"}}");
    try testing.expectError(error.Rejected, parseCaller(arena, &camel, &f));
    try testing.expectEqualStrings("Unsupported parameter 'surfaceId'; use 'surface_id'", f.message);
}

test "unit: proto: selectors cli messages are cmux strings" {
    const gpa = testing.allocator;
    const cases = [_]struct { CliProblem, Kind, []const u8, []const u8 }{
        .{ .blank, .surface, "", "Surface handle is blank" },
        .{ .invalid, .surface, "X", "Invalid surface handle: X (expected UUID, ref like surface:1, or index)" },
        .{ .ref_not_found, .surface, "surface:9", "Surface ref not found: surface:9" },
        .{ .index_not_found, .surface, "3", "Surface index not found" },
        .{ .ref_not_found, .workspace, "workspace:3", "Workspace ref not found: workspace:3" },
        .{ .index_not_found, .workspace, "7", "Workspace index not found" },
        .{ .invalid, .workspace_group, "\u{1F600}", "Invalid workspace group handle: \u{1F600} (expected UUID, ref like workspace_group:1, or index)" },
    };
    for (cases) |c| {
        const m = try cliMessage(gpa, c[0], c[1], c[2]);
        defer gpa.free(m);
        try testing.expectEqualStrings(c[3], m);
    }
    try testing.expectEqual(CliProblem.blank, cliProblemFor(error.Blank));
    try testing.expectEqual(CliProblem.invalid, cliProblemFor(error.WrongKind));
}
