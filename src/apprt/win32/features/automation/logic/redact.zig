//! Credential redaction for `automation show` and `automation test`
//! (cli-automation-cli): values under credential-like keys in predicates,
//! actions and events are replaced by `marker`, webhook URLs lose their
//! userinfo and credential-like query values, and webhook header values
//! under credential-like names are replaced.

const std = @import("std");
const wmux_proto = @import("wmux_proto");

const jsonc = wmux_proto.jsonc;
const Allocator = std.mem.Allocator;

pub const marker = "[REDACTED]";

/// Longest key considered; longer names are compared on their first bytes.
const max_name = 128;

/// Fragments that make a normalized key (lowercase, without `-`, `_`, `.`
/// and spaces) credential-like.
const fragments = [_][]const u8{
    "authorization", "password",  "passwd",     "passphrase", "secret",     "token",
    "apikey",        "accesskey", "privatekey", "signingkey", "sessionkey", "cookie",
    "credential",    "bearer",    "sessionid",
};
/// Normalized keys that are credential-like only as a whole word.
const exact = [_][]const u8{ "auth", "pwd", "sig", "signature", "key", "jwt", "session" };

/// True for key, header or query-parameter names that carry credentials
/// (`Authorization`, `X-Api-Key`, `access_token`, `Cookie`, `client-secret`, …).
pub fn isCredentialName(name: []const u8) bool {
    var buf: [max_name]u8 = undefined;
    var n: usize = 0;
    for (name) |c| {
        if (n == buf.len) break;
        switch (c) {
            '-', '_', '.', ' ' => {},
            else => {
                buf[n] = std.ascii.toLower(c);
                n += 1;
            },
        }
    }
    const norm = buf[0..n];
    for (exact) |e| {
        if (std.mem.eql(u8, norm, e)) return true;
    }
    for (fragments) |f| {
        if (std.mem.indexOf(u8, norm, f) != null) return true;
    }
    return false;
}

const UrlParts = struct {
    /// `scheme://`
    head: []const u8,
    userinfo: ?[]const u8,
    /// host[:port] and path, up to `?` or `#`.
    middle: []const u8,
    query: ?[]const u8,
    fragment: ?[]const u8,
};

fn splitUrl(url: []const u8) UrlParts {
    var head: []const u8 = "";
    var rest = url;
    if (std.mem.indexOf(u8, url, "://")) |i| {
        head = url[0 .. i + 3];
        rest = url[i + 3 ..];
    }
    var fragment: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '#')) |i| {
        fragment = rest[i + 1 ..];
        rest = rest[0..i];
    }
    var query: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '?')) |i| {
        query = rest[i + 1 ..];
        rest = rest[0..i];
    }
    var userinfo: ?[]const u8 = null;
    if (head.len > 0) {
        const auth_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        if (std.mem.lastIndexOfScalar(u8, rest[0..auth_end], '@')) |at| {
            userinfo = rest[0..at];
            rest = rest[at + 1 ..];
        }
    }
    return .{ .head = head, .userinfo = userinfo, .middle = rest, .query = query, .fragment = fragment };
}

/// `url` without credentials: userinfo becomes `marker@` and credential-like
/// query values become `marker`. Owned by `gpa`.
pub fn redactUrlAlloc(gpa: Allocator, url: []const u8) Allocator.Error![]u8 {
    const p = splitUrl(url);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, p.head);
    if (p.userinfo != null) {
        try out.appendSlice(gpa, marker);
        try out.append(gpa, '@');
    }
    try out.appendSlice(gpa, p.middle);
    if (p.query) |q| {
        try out.append(gpa, '?');
        var it = std.mem.splitScalar(u8, q, '&');
        var first = true;
        while (it.next()) |pair| {
            if (!first) try out.append(gpa, '&');
            first = false;
            const eq = std.mem.indexOfScalar(u8, pair, '=');
            const name = if (eq) |e| pair[0..e] else pair;
            if (eq != null and isCredentialName(name)) {
                try out.appendSlice(gpa, name);
                try out.append(gpa, '=');
                try out.appendSlice(gpa, marker);
            } else {
                try out.appendSlice(gpa, pair);
            }
        }
    }
    if (p.fragment) |f| {
        try out.append(gpa, '#');
        try out.appendSlice(gpa, f);
    }
    return out.toOwnedSlice(gpa);
}

/// True when `url` carries credentials in its userinfo or query.
pub fn urlHasCredentials(url: []const u8) bool {
    const p = splitUrl(url);
    if (p.userinfo != null) return true;
    const q = p.query orelse return false;
    var it = std.mem.splitScalar(u8, q, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (isCredentialName(pair[0..eq])) return true;
    }
    return false;
}

fn isUrlKey(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "url");
}

/// Streams a JSONC node (a rule as written) with credentials redacted.
/// `gpa` holds temporary URL copies.
pub fn writeNode(gpa: Allocator, node: *const jsonc.Node, jw: *std.json.Stringify) (Allocator.Error || std.Io.Writer.Error)!void {
    switch (node.data) {
        .array => |items| {
            try jw.beginArray();
            for (items) |*item| try writeNode(gpa, item, jw);
            try jw.endArray();
        },
        .object => |members| {
            try jw.beginObject();
            for (members) |*m| {
                try jw.objectField(m.key);
                if (m.value.data != .null and isCredentialName(m.key)) {
                    try jw.write(marker);
                } else if (isUrlKey(m.key) and m.value.data == .string) {
                    const red = try redactUrlAlloc(gpa, m.value.data.string);
                    defer gpa.free(red);
                    try jw.write(red);
                } else {
                    try writeNode(gpa, &m.value, jw);
                }
            }
            try jw.endObject();
        },
        else => try node.write(jw),
    }
}

/// Streams a `std.json.Value` (an event) with credentials redacted.
pub fn writeValue(gpa: Allocator, v: std.json.Value, jw: *std.json.Stringify) (Allocator.Error || std.Io.Writer.Error)!void {
    switch (v) {
        .array => |arr| {
            try jw.beginArray();
            for (arr.items) |item| try writeValue(gpa, item, jw);
            try jw.endArray();
        },
        .object => |obj| {
            try jw.beginObject();
            var it = obj.iterator();
            while (it.next()) |e| {
                try jw.objectField(e.key_ptr.*);
                const val = e.value_ptr.*;
                if (val != .null and isCredentialName(e.key_ptr.*)) {
                    try jw.write(marker);
                } else if (isUrlKey(e.key_ptr.*) and val == .string) {
                    const red = try redactUrlAlloc(gpa, val.string);
                    defer gpa.free(red);
                    try jw.write(red);
                } else {
                    try writeValue(gpa, val, jw);
                }
            }
            try jw.endObject();
        },
        else => try jw.write(v),
    }
}

/// Minified redacted JSON of a JSONC node. Owned by `gpa`.
pub fn nodeToJsonAlloc(gpa: Allocator, node: *const jsonc.Node) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    writeNode(gpa, node, &jw) catch |e| switch (e) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    return aw.toOwnedSlice();
}

/// Minified redacted JSON of a value. Owned by `gpa`.
pub fn valueToJsonAlloc(gpa: Allocator, v: std.json.Value) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    writeValue(gpa, v, &jw) catch |e| switch (e) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    return aw.toOwnedSlice();
}

const testing = std.testing;

test "unit: automation: redaction recognizes credential-like names" {
    const yes = [_][]const u8{ "Authorization", "proxy-authorization", "X-Api-Key", "api_key", "apiKey", "access_token", "Cookie", "Set-Cookie", "client-secret", "password", "PASSWD", "auth", "X-Auth-Token", "session_token", "sessionId", "sig", "jwt", "private_key" };
    const no = [_][]const u8{ "", "author", "title", "body", "url", "method", "hotkey", "Content-Type", "keyboard", "workspace.tag", "monkey_business", "signal" };
    for (yes) |n| try testing.expect(isCredentialName(n));
    for (no) |n| try testing.expect(!isCredentialName(n));
    // Huge names are bounded and do not crash.
    var big: [4096]u8 = undefined;
    @memset(&big, 'a');
    try testing.expect(!isCredentialName(&big));
}

test "unit: automation: redaction strips URL userinfo and query credentials" {
    const cases = [_][2][]const u8{
        .{ "https://hooks.example/x?token=abc&channel=ops", "https://hooks.example/x?token=[REDACTED]&channel=ops" },
        .{ "https://user:pw@hooks.example/x", "https://[REDACTED]@hooks.example/x" },
        .{ "https://hooks.example/a@b?Api-Key=1#frag", "https://hooks.example/a@b?Api-Key=[REDACTED]#frag" },
        .{ "https://hooks.example/", "https://hooks.example/" },
        .{ "", "" },
        .{ "not a url?secret=1&x", "not a url?secret=[REDACTED]&x" },
        .{ "https://h.example/?token&x=", "https://h.example/?token&x=" },
        .{ "https://ü.example/✓?sig=✓", "https://ü.example/✓?sig=[REDACTED]" },
    };
    for (cases) |c| {
        const out = try redactUrlAlloc(testing.allocator, c[0]);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c[1], out);
    }
    try testing.expect(urlHasCredentials("http://u@h/"));
    try testing.expect(urlHasCredentials("http://h/?access_token=1"));
    try testing.expect(!urlHasCredentials("http://h/?a=1"));
    try testing.expect(!urlHasCredentials("http://h/p@x"));
}

test "unit: automation: redaction of rules and events keeps structure" {
    const gpa = testing.allocator;
    var doc = try jsonc.parse(gpa,
        \\{"id":"r","where":{"token":{"equals":"abc"},"title":"x"},
        \\ "then":[{"action":"webhook","url":"https://u:p@h.example/?key=1",
        \\          "headers":{"Authorization":"Bearer abc","X-Trace":"t"}},
        \\         {"action":"run","command":"echo","password":null}]}
    , .{}, null);
    defer doc.deinit();
    const out = try nodeToJsonAlloc(gpa, &doc.root);
    defer gpa.free(out);
    try testing.expectEqualStrings(
        \\{"id":"r","where":{"token":"[REDACTED]","title":"x"},"then":[{"action":"webhook","url":"https://[REDACTED]@h.example/?key=[REDACTED]","headers":{"Authorization":"[REDACTED]","X-Trace":"t"}},{"action":"run","command":"echo","password":null}]}
    , out);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(),
        \\{"name":"x","payload":{"session_id":"s","api_key":"k","n":[1,{"cookie":"c"}]}}
    , .{});
    const ev = try valueToJsonAlloc(gpa, v);
    defer gpa.free(ev);
    try testing.expectEqualStrings(
        \\{"name":"x","payload":{"session_id":"[REDACTED]","api_key":"[REDACTED]","n":[1,{"cookie":"[REDACTED]"}]}}
    , ev);
}
