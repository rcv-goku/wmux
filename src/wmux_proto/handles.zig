//! Object handles: `Kind`, `Ref` (`<kind>:<N>`, `tab:N` == surface), `HandleText`,
//! `Handle` and `parseHandle` (ADR-2.1, ADR-2.2).

const std = @import("std");
const Uuid = @import("uuid.zig").Uuid;

pub const Kind = enum {
    window,
    workspace,
    workspace_group,
    pane,
    surface,

    /// Ref prefix and display kind name (`"workspace_group"`).
    pub fn name(k: Kind) []const u8 {
        return @tagName(k);
    }

    /// Parses a ref prefix. `tab` is an alias of `surface`. Case-sensitive,
    /// like cmux's ref grammar.
    pub fn fromName(s: []const u8) ?Kind {
        if (std.mem.eql(u8, s, "tab")) return .surface;
        return std.meta.stringToEnum(Kind, s);
    }

    /// Canonical selector/result key for the UUID (`workspace_id`). Groups
    /// use cmux's selector key `group_id`.
    pub fn idKey(k: Kind) []const u8 {
        return switch (k) {
            .window => "window_id",
            .workspace => "workspace_id",
            .workspace_group => "group_id",
            .pane => "pane_id",
            .surface => "surface_id",
        };
    }

    /// Result key for the ref (`workspace_ref`).
    pub fn refKey(k: Kind) []const u8 {
        return switch (k) {
            .window => "window_ref",
            .workspace => "workspace_ref",
            .workspace_group => "group_ref",
            .pane => "pane_ref",
            .surface => "surface_ref",
        };
    }

    /// Lowercase noun for messages (`"workspace group"`).
    pub fn noun(k: Kind) []const u8 {
        return switch (k) {
            .workspace_group => "workspace group",
            else => @tagName(k),
        };
    }

    /// Capitalized noun for messages (`"Workspace group"`).
    pub fn nounCapitalized(k: Kind) []const u8 {
        return switch (k) {
            .window => "Window",
            .workspace => "Workspace",
            .workspace_group => "Workspace group",
            .pane => "Pane",
            .surface => "Surface",
        };
    }
};

pub const Ref = struct {
    kind: Kind,
    n: u32,

    pub const ParseError = error{Invalid};

    /// Parses `<kind>:<N>` with N ≥ 1 in plain decimal (no sign, no leading
    /// zeros, fits u32). `tab:N` yields `.surface`.
    pub fn parse(s: []const u8) ParseError!Ref {
        const colon = std.mem.indexOfScalar(u8, s, ':') orelse return error.Invalid;
        const kind = Kind.fromName(s[0..colon]) orelse return error.Invalid;
        const n = parseOrdinal(s[colon + 1 ..]) orelse return error.Invalid;
        return .{ .kind = kind, .n = n };
    }

    /// Writes `<kind>:<N>`; invoked with `{f}`.
    pub fn format(self: Ref, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}:{d}", .{ self.kind.name(), self.n });
    }

    /// Writes the tab-context form: `tab:N` for surfaces, else `<kind>:<N>`.
    pub fn formatTab(self: Ref, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.kind == .surface) return w.print("tab:{d}", .{self.n});
        return self.format(w);
    }

    /// Heap text `<kind>:<N>`.
    pub fn toTextAlloc(self: Ref, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fmt.allocPrint(gpa, "{s}:{d}", .{ self.kind.name(), self.n });
    }

    pub fn eql(a: Ref, b: Ref) bool {
        return a.kind == b.kind and a.n == b.n;
    }

    pub fn jsonStringify(self: Ref, jws: anytype) !void {
        var buf: [max_text_len]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{s}:{d}", .{ self.kind.name(), self.n }) catch unreachable;
        try jws.write(s);
    }

    /// Longest ref text: `workspace_group:4294967295`.
    pub const max_text_len = "workspace_group:".len + 10;
};

/// The persisted identity of one object: UUID plus its per-kind ordinal.
pub const Handle = struct {
    uuid: Uuid,
    ref: u32,

    pub fn refOf(self: Handle, kind: Kind) Ref {
        return .{ .kind = kind, .n = self.ref };
    }
};

/// One selector value in any of the accepted forms.
pub const HandleText = union(enum) {
    uuid: Uuid,
    ref: Ref,
    /// 0-based position, resolved in context (ADR-2.4).
    index: u32,
    /// Ghostty core surface id (`GHOSTTY_SURFACE_ID`), surfaces only.
    legacy_core_id: u64,
};

pub const ParseHandleError = error{ Blank, Invalid, WrongKind };

/// Parses a handle for an `expect`ed kind. Surrounding whitespace is ignored.
/// - UUID (any case, optional braces) → `.uuid`
/// - `<kind>:<N>` → `.ref`; another valid kind → `WrongKind` (`tab:N` is a
///   surface ref)
/// - decimal digits fitting u32 → `.index`
/// - for surfaces only: `0x`/`0X` + 1..16 hex digits, or a decimal above
///   u32 range that fits u64 → `.legacy_core_id`
pub fn parseHandle(expect: Kind, s: []const u8) ParseHandleError!HandleText {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return error.Blank;
    if (Uuid.parse(t)) |u| return .{ .uuid = u } else |_| {}
    if (std.mem.indexOfScalar(u8, t, ':')) |colon| {
        const kind = Kind.fromName(t[0..colon]) orelse return error.Invalid;
        const n = parseOrdinal(t[colon + 1 ..]) orelse return error.Invalid;
        if (kind != expect) return error.WrongKind;
        return .{ .ref = .{ .kind = kind, .n = n } };
    }
    if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) {
        if (expect != .surface) return error.Invalid;
        const hex = t[2..];
        if (hex.len > 16) return error.Invalid;
        for (hex) |c| if (!std.ascii.isHex(c)) return error.Invalid;
        return .{ .legacy_core_id = std.fmt.parseInt(u64, hex, 16) catch return error.Invalid };
    }
    for (t) |c| if (!std.ascii.isDigit(c)) return error.Invalid;
    if (std.fmt.parseInt(u32, t, 10)) |i| return .{ .index = i } else |_| {}
    if (expect == .surface) {
        if (std.fmt.parseInt(u64, t, 10)) |id| return .{ .legacy_core_id = id } else |_| {}
    }
    return error.Invalid;
}

/// Ref ordinal: decimal, ≥ 1, no leading zeros or sign, fits u32.
fn parseOrdinal(s: []const u8) ?u32 {
    if (s.len == 0 or s.len > 10) return null;
    if (s[0] == '0') return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// Prefix of notification handles (`notification:<uuid>`).
pub const notification_prefix = "notification:";

/// Accepts a bare notification UUID or `notification:<uuid>`.
pub fn parseNotificationHandle(s: []const u8) error{ Blank, Invalid }!Uuid {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return error.Blank;
    const body = if (std.mem.startsWith(u8, t, notification_prefix)) t[notification_prefix.len..] else t;
    return Uuid.parse(body) catch error.Invalid;
}

/// Writes `notification:<UUID>`.
pub fn formatNotificationHandle(w: *std.Io.Writer, id: Uuid) std.Io.Writer.Error!void {
    try w.writeAll(notification_prefix);
    try id.format(w);
}

const testing = std.testing;

test "unit: proto: handles ref parse and format round trip" {
    const kinds = [_]Kind{ .window, .workspace, .workspace_group, .pane, .surface };
    for (kinds) |k| {
        for ([_]u32{ 1, 7, 4294967295 }) |n| {
            const r: Ref = .{ .kind = k, .n = n };
            var buf: [Ref.max_text_len]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{f}", .{r});
            try testing.expect((try Ref.parse(s)).eql(r));
        }
    }
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("workspace_group:3", try std.fmt.bufPrint(&buf, "{f}", .{Ref{ .kind = .workspace_group, .n = 3 }}));
}

test "unit: proto: handles tab ref aliases surface" {
    const r = try Ref.parse("tab:7");
    try testing.expectEqual(Kind.surface, r.kind);
    try testing.expectEqual(@as(u32, 7), r.n);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try r.formatTab(&aw.writer);
    try aw.writer.writeByte(' ');
    try (Ref{ .kind = .pane, .n = 2 }).formatTab(&aw.writer);
    try testing.expectEqualStrings("tab:7 pane:2", aw.written());
}

test "unit: proto: handles ref rejects malformed" {
    const bad = [_][]const u8{
        "",               "pane",         "pane:",             "pane:0",   "pane:01",
        "pane:-1",        "pane:+1",      "pane:1.0",          "pane: 1",  "Pane:1",
        "panel:1",        ":1",           "pane:4294967296",   "pane:1:2", "pane:99999999999",
        "notification:1", "pane:\u{661}", "workspace-group:1",
    };
    for (bad) |s| try testing.expectError(error.Invalid, Ref.parse(s));
}

test "unit: proto: handles parseHandle forms" {
    const u = Uuid.v4();
    const text = u.toText();
    try testing.expect((try parseHandle(.pane, &text)).uuid.eql(u));
    try testing.expectEqual(HandleText{ .ref = .{ .kind = .pane, .n = 3 } }, try parseHandle(.pane, "pane:3"));
    try testing.expectEqual(HandleText{ .index = 0 }, try parseHandle(.pane, "0"));
    try testing.expectEqual(HandleText{ .index = 4294967295 }, try parseHandle(.workspace, "4294967295"));
    try testing.expectEqual(HandleText{ .ref = .{ .kind = .surface, .n = 2 } }, try parseHandle(.surface, "tab:2"));
    try testing.expectEqual(HandleText{ .ref = .{ .kind = .workspace, .n = 9 } }, try parseHandle(.workspace, "  workspace:9\n"));
}

test "unit: proto: handles parseHandle errors" {
    try testing.expectError(error.Blank, parseHandle(.surface, ""));
    try testing.expectError(error.Blank, parseHandle(.surface, " \t "));
    try testing.expectError(error.WrongKind, parseHandle(.pane, "surface:1"));
    try testing.expectError(error.WrongKind, parseHandle(.pane, "tab:1"));
    try testing.expectError(error.WrongKind, parseHandle(.workspace, "workspace_group:1"));
    try testing.expectError(error.Invalid, parseHandle(.pane, "pane:0"));
    try testing.expectError(error.Invalid, parseHandle(.pane, "bogus:1"));
    try testing.expectError(error.Invalid, parseHandle(.pane, "-1"));
    try testing.expectError(error.Invalid, parseHandle(.pane, "1.5"));
    try testing.expectError(error.Invalid, parseHandle(.pane, "abc"));
    try testing.expectError(error.Invalid, parseHandle(.pane, "\u{1F600}"));
    try testing.expectError(error.Invalid, parseHandle(.pane, "0x1f"));
    try testing.expectError(error.Invalid, parseHandle(.pane, "4294967296"));
    try testing.expectError(error.Invalid, parseHandle(.surface, "0x"));
    try testing.expectError(error.Invalid, parseHandle(.surface, "0x12345678901234567"));
    try testing.expectError(error.Invalid, parseHandle(.surface, "0xzz"));
    try testing.expectError(error.Invalid, parseHandle(.surface, "99999999999999999999999"));
}

test "unit: proto: handles legacy core id for surfaces" {
    try testing.expectEqual(HandleText{ .legacy_core_id = 0xdeadbeefcafef00d }, try parseHandle(.surface, "0xDEADBEEFCAFEF00D"));
    try testing.expectEqual(HandleText{ .legacy_core_id = 0x1f }, try parseHandle(.surface, "0X1f"));
    try testing.expectEqual(HandleText{ .legacy_core_id = 4294967296 }, try parseHandle(.surface, "4294967296"));
    try testing.expectEqual(HandleText{ .legacy_core_id = std.math.maxInt(u64) }, try parseHandle(.surface, "18446744073709551615"));
}

test "unit: proto: handles kind keys and nouns" {
    try testing.expectEqualStrings("group_id", Kind.workspace_group.idKey());
    try testing.expectEqualStrings("surface_ref", Kind.surface.refKey());
    try testing.expectEqualStrings("Workspace group", Kind.workspace_group.nounCapitalized());
    try testing.expectEqual(@as(?Kind, null), Kind.fromName("Surface"));
    try testing.expectEqual(@as(?Kind, .surface), Kind.fromName("tab"));
}

test "unit: proto: handles handle refOf and json" {
    const h: Handle = .{ .uuid = Uuid.nil, .ref = 5 };
    try testing.expect(h.refOf(.pane).eql(.{ .kind = .pane, .n = 5 }));
    const s = try std.json.Stringify.valueAlloc(testing.allocator, .{ .r = h.refOf(.workspace_group) }, .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("{\"r\":\"workspace_group:5\"}", s);
    const t = try h.refOf(.surface).toTextAlloc(testing.allocator);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("surface:5", t);
}

test "unit: proto: handles notification handles" {
    const u = Uuid.v4();
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try formatNotificationHandle(&aw.writer, u);
    try testing.expect(std.mem.startsWith(u8, aw.written(), "notification:"));
    try testing.expect((try parseNotificationHandle(aw.written())).eql(u));
    try testing.expect((try parseNotificationHandle(&u.toText())).eql(u));
    try testing.expectError(error.Blank, parseNotificationHandle(""));
    try testing.expectError(error.Invalid, parseNotificationHandle("notification:"));
    try testing.expectError(error.Invalid, parseNotificationHandle("notification:1"));
}
