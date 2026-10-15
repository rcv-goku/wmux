//! UUIDv4 `Uuid`: generation, case-insensitive parsing (braces tolerated) and
//! uppercase 8-4-4-4-12 formatting (ADR-2.1, ADR-2.2).

const std = @import("std");

pub const Uuid = extern struct {
    b: [16]u8,

    /// Length of the canonical text form (`8-4-4-4-12`).
    pub const text_len = 36;

    pub const nil: Uuid = .{ .b = @splat(0) };

    pub const ParseError = error{InvalidUuid};

    /// A random RFC 4122 version 4 UUID from `std.crypto.random`.
    pub fn v4() Uuid {
        var bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&bytes);
        return fromRandomBytes(bytes);
    }

    /// Stamps the version (4) and variant (RFC 4122) bits onto random bytes.
    /// Deterministic; used by `v4` and by tests.
    pub fn fromRandomBytes(bytes: [16]u8) Uuid {
        var u: Uuid = .{ .b = bytes };
        u.b[6] = (u.b[6] & 0x0f) | 0x40;
        u.b[8] = (u.b[8] & 0x3f) | 0x80;
        return u;
    }

    /// Parses `8-4-4-4-12` hex in any case, optionally wrapped in `{}`.
    /// Any version is accepted (identity is compared by bytes).
    pub fn parse(s: []const u8) ParseError!Uuid {
        var t = s;
        if (t.len == text_len + 2 and t[0] == '{' and t[t.len - 1] == '}') t = t[1 .. t.len - 1];
        if (t.len != text_len) return error.InvalidUuid;
        var out: Uuid = undefined;
        var bi: usize = 0;
        var i: usize = 0;
        while (i < text_len) {
            if (i == 8 or i == 13 or i == 18 or i == 23) {
                if (t[i] != '-') return error.InvalidUuid;
                i += 1;
                continue;
            }
            const hi = hexVal(t[i]) orelse return error.InvalidUuid;
            const lo = hexVal(t[i + 1]) orelse return error.InvalidUuid;
            out.b[bi] = (hi << 4) | lo;
            bi += 1;
            i += 2;
        }
        return out;
    }

    /// True when `s` parses as a UUID.
    pub fn isUuidText(s: []const u8) bool {
        _ = parse(s) catch return false;
        return true;
    }

    /// Uppercase canonical text (Swift `uuidString`).
    pub fn toText(self: Uuid) [text_len]u8 {
        const hex = "0123456789ABCDEF";
        var out: [text_len]u8 = undefined;
        var o: usize = 0;
        for (self.b, 0..) |byte, i| {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                out[o] = '-';
                o += 1;
            }
            out[o] = hex[byte >> 4];
            out[o + 1] = hex[byte & 0x0f];
            o += 2;
        }
        return out;
    }

    /// Invoked with `{f}`; writes the uppercase canonical form.
    pub fn format(self: Uuid, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const text = self.toText();
        try w.writeAll(&text);
    }

    /// Serializes as a JSON string (uppercase canonical form).
    pub fn jsonStringify(self: Uuid, jws: anytype) !void {
        const text = self.toText();
        try jws.write(@as([]const u8, &text));
    }

    pub fn eql(a: Uuid, b: Uuid) bool {
        return std.mem.eql(u8, &a.b, &b.b);
    }

    pub fn isNil(self: Uuid) bool {
        return self.eql(nil);
    }

    /// The version nibble (4 for `v4`).
    pub fn version(self: Uuid) u4 {
        return @intCast(self.b[6] >> 4);
    }

    fn hexVal(c: u8) ?u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
    }
};

const testing = std.testing;

test "unit: proto: uuid v4 sets version and variant bits" {
    for (0..64) |_| {
        const u = Uuid.v4();
        try testing.expectEqual(@as(u4, 4), u.version());
        try testing.expectEqual(@as(u8, 0x80), u.b[8] & 0xc0);
    }
}

test "unit: proto: uuid v4 values differ" {
    const a = Uuid.v4();
    const b = Uuid.v4();
    try testing.expect(!a.eql(b));
}

test "unit: proto: uuid formats uppercase 8-4-4-4-12" {
    const u: Uuid = .{ .b = .{ 0x9b, 0x69, 0x0a, 0xbc, 0xde, 0xf0, 0x41, 0x23, 0x84, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12 } };
    try testing.expectEqualStrings("9B690ABC-DEF0-4123-8456-789ABCDEF012", &u.toText());
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "<{f}>", .{u});
    try testing.expectEqualStrings("<9B690ABC-DEF0-4123-8456-789ABCDEF012>", s);
}

test "unit: proto: uuid parse round trip and case insensitivity" {
    for (0..32) |_| {
        const u = Uuid.v4();
        const text = u.toText();
        try testing.expect((try Uuid.parse(&text)).eql(u));
        var buf: [Uuid.text_len]u8 = undefined;
        const lower = std.ascii.lowerString(&buf, &text);
        try testing.expect((try Uuid.parse(lower)).eql(u));
    }
    const mixed = try Uuid.parse("9b690AbC-dEf0-4123-8456-789abcdef012");
    try testing.expectEqualStrings("9B690ABC-DEF0-4123-8456-789ABCDEF012", &mixed.toText());
}

test "unit: proto: uuid parse tolerates braces" {
    const a = try Uuid.parse("{9B690ABC-DEF0-4123-8456-789ABCDEF012}");
    const b = try Uuid.parse("9B690ABC-DEF0-4123-8456-789ABCDEF012");
    try testing.expect(a.eql(b));
}

test "unit: proto: uuid parse rejects malformed input" {
    const bad = [_][]const u8{
        "",
        "{}",
        "9B690ABC-DEF0-4123-8456-789ABCDEF01",
        "9B690ABC-DEF0-4123-8456-789ABCDEF0123",
        "9B690ABCDEF0-4123-8456-789ABCDEF012-",
        "9B690ABC-DEF0-4123-8456_789ABCDEF012",
        "9B690ABC-DEF0-4123-8456-789ABCDEF01G",
        "{9B690ABC-DEF0-4123-8456-789ABCDEF012",
        "9B690ABC-DEF0-4123-8456-789ABCDEF012}",
        "(9B690ABC-DEF0-4123-8456-789ABCDEF012)",
        " 9B690ABC-DEF0-4123-8456-789ABCDEF012",
        "9B690ABCDEF041238456789ABCDEF012",
        "9B690ABC-DEF0-4123-8456-789ABCDEF0é",
        "workspace:1",
    };
    for (bad) |s| try testing.expectError(error.InvalidUuid, Uuid.parse(s));
    try testing.expect(!Uuid.isUuidText("pane:1"));
}

test "unit: proto: uuid nil and non-v4 parse" {
    const n = try Uuid.parse("00000000-0000-0000-0000-000000000000");
    try testing.expect(n.isNil());
    const v1 = try Uuid.parse("6ba7b810-9dad-11d1-80b4-00c04fd430c8");
    try testing.expectEqual(@as(u4, 1), v1.version());
}

test "unit: proto: uuid json stringify" {
    const u = try Uuid.parse("9b690abc-def0-4123-8456-789abcdef012");
    const s = try std.json.Stringify.valueAlloc(testing.allocator, .{ .id = u }, .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("{\"id\":\"9B690ABC-DEF0-4123-8456-789ABCDEF012\"}", s);
}

test "unit: proto: uuid usable as hash map key" {
    var map: std.AutoHashMapUnmanaged(Uuid, u32) = .empty;
    defer map.deinit(testing.allocator);
    const a = Uuid.v4();
    try map.put(testing.allocator, a, 7);
    try testing.expectEqual(@as(?u32, 7), map.get(try Uuid.parse(&a.toText())));
}
