//! Browser availability (SPEC.json `browser-availability-toggle`):
//! `disable-browser`, `enable-browser`, `browser-status` and `browser
//! disable|enable|status`. They work without the app: the switch is the
//! setting `wmux.browser.enabled` in `wmux.json` (ADR-3.6, F.1 #19), edited
//! losslessly; the running app picks the change up through live reload.
//! The URL allowlist is `browser.urlAllowlist` (wmux.json over cmux.json).

const std = @import("std");
const proto = @import("wmux_proto");
const jsonc = proto.jsonc;
const json_edit = proto.json_edit;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const key = "wmux.browser.enabled";
pub const allowlist_key = "browser.urlAllowlist";

pub const Status = struct {
    enabled: bool = true,
    /// Forced by a managed policy (enable/disable then fail).
    managed: bool = false,
    /// The settings file that holds the switch.
    domain: []const u8 = "",
    url_allowlist: []const []const u8 = &.{},
    url_allowlist_managed: bool = false,

    pub fn allowlistActive(s: Status) bool {
        return s.url_allowlist.len > 0;
    }

    /// Loopback hosts pass an active allowlist only when listed.
    pub fn allowsLocalhost(s: Status) bool {
        if (!s.allowlistActive()) return true;
        for (s.url_allowlist) |e| if (isLoopbackPattern(e)) return true;
        return false;
    }

    pub fn allowsLocalFiles(s: Status) bool {
        if (!s.allowlistActive()) return true;
        for (s.url_allowlist) |e| if (std.mem.startsWith(u8, e, "file:")) return true;
        return false;
    }
};

fn isLoopbackPattern(e: []const u8) bool {
    var host = e;
    if (std.mem.indexOf(u8, host, "://")) |i| host = host[i + 3 ..];
    if (std.mem.indexOfAny(u8, host, "/")) |i| host = host[0..i];
    // Drop a `:port`: after the `]` of a bracketed IPv6 literal, or after a
    // host with a single colon. Several colons without brackets are a bare
    // IPv6 address (`::1`), which has no port to drop.
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |i| {
        if (std.mem.indexOfScalar(u8, host, ']')) |close| {
            if (i > close) host = host[0..i];
        } else if (std.mem.indexOfScalar(u8, host, ':') == i) host = host[0..i];
    }
    for ([_][]const u8{ "localhost", "127.0.0.1", "[::1]", "::1", "*.localhost" }) |l| {
        if (std.ascii.eqlIgnoreCase(host, l)) return true;
    }
    return false;
}

fn parse(arena: Allocator, bytes: ?[]const u8) ?jsonc.Node {
    const b = bytes orelse return null;
    const n = jsonc.parseInto(arena, b, .{}, null) catch return null;
    return if (n.data == .object) n else null;
}

fn allowlistFrom(arena: Allocator, root: ?jsonc.Node) Allocator.Error!?[]const []const u8 {
    const r = root orelse return null;
    const n = r.getDotted(allowlist_key) orelse return null;
    var list: std.ArrayList([]const u8) = .empty;
    switch (n.data) {
        .array => |items| for (items) |*it| {
            if (it.asString()) |s| if (std.mem.trim(u8, s, " \t\r\n").len > 0) try list.append(arena, std.mem.trim(u8, s, " \t\r\n"));
        },
        .string => |s| {
            var it = std.mem.tokenizeAny(u8, s, ",\r\n");
            while (it.next()) |e| if (std.mem.trim(u8, e, " \t").len > 0) try list.append(arena, std.mem.trim(u8, e, " \t"));
        },
        else => return null,
    }
    return list.items;
}

/// The effective status from the two settings files (either may be
/// missing or malformed: defaults apply).
pub fn status(arena: Allocator, wmux_json: ?[]const u8, cmux_json: ?[]const u8, domain: []const u8, managed: ?bool) Allocator.Error!Status {
    const w = parse(arena, wmux_json);
    const c = parse(arena, cmux_json);
    var s: Status = .{ .domain = domain };
    if (w) |root| if (root.getDotted(key)) |n| if (n.asBool()) |b| {
        s.enabled = b;
    };
    if (managed) |forced_disabled| {
        s.managed = true;
        s.enabled = !forced_disabled;
    }
    s.url_allowlist = (try allowlistFrom(arena, w)) orelse (try allowlistFrom(arena, c)) orelse &.{};
    return s;
}

pub const EditError = json_edit.Error;

/// `wmux.json` with the switch set (a missing or empty file starts as `{}`).
pub fn edit(gpa: Allocator, wmux_json: ?[]const u8, enabled: bool) EditError!json_edit.Result {
    const src = wmux_json orelse "";
    const base = if (std.mem.trim(u8, src, " \t\r\n\xEF\xBB\xBF").len == 0) "{}\n" else src;
    return json_edit.set(gpa, base, key, if (enabled) "true" else "false", null);
}

/// The managed-policy refusal (cmux wording).
pub fn managedMessage(arena: Allocator, domain: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "Browser availability is managed by your organization (MDM policy for domain {s}); it cannot be changed from the CLI.", .{domain});
}

/// `--json` payload (cmux keys).
pub fn writeJson(w: *Writer, s: Status) Writer.Error!void {
    var js: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try js.write(.{
        .enabled = s.enabled,
        .disabled = !s.enabled,
        .managed = s.managed,
        .domain = s.domain,
        .key = key,
        .url_allowlist = s.url_allowlist,
        .url_allowlist_active = s.allowlistActive(),
        .url_allowlist_managed = s.url_allowlist_managed,
        .url_allowlist_allows_localhost = s.allowsLocalhost(),
        .url_allowlist_localhost_implicit = false,
        .url_allowlist_allows_local_files = s.allowsLocalFiles(),
    });
    try w.writeByte('\n');
}

const testing = std.testing;

test "unit: browser-cli: availability status from settings files" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d = try status(a, null, null, "C:\\cfg\\wmux.json", null);
    try testing.expect(d.enabled and !d.managed and !d.allowlistActive() and d.allowsLocalhost() and d.allowsLocalFiles());
    const off = try status(a, "// comment\n{\"wmux\":{\"browser\":{\"enabled\":false}}}", null, "x", null);
    try testing.expect(!off.enabled);
    const bad = try status(a, "{not json", "[]", "x", null);
    try testing.expect(bad.enabled);
    const al = try status(a, null, "{\"browser\":{\"urlAllowlist\":[\"example.com\",\" \",\"http://localhost:3000\"]}}", "x", null);
    try testing.expectEqual(@as(usize, 2), al.url_allowlist.len);
    try testing.expect(al.allowlistActive() and al.allowsLocalhost() and !al.allowsLocalFiles());
    const wins = try status(a, "{\"browser\":{\"urlAllowlist\":\"a.com, file:///c\"}}", "{\"browser\":{\"urlAllowlist\":[\"b.com\"]}}", "x", null);
    try testing.expectEqualStrings("a.com", wins.url_allowlist[0]);
    try testing.expect(wins.allowsLocalFiles() and !wins.allowsLocalhost());
    const m = try status(a, "{\"wmux\":{\"browser\":{\"enabled\":true}}}", null, "x", true);
    try testing.expect(m.managed and !m.enabled);
    try testing.expect(isLoopbackPattern("[::1]:8080") and isLoopbackPattern("LOCALHOST") and !isLoopbackPattern("localhost.evil.com"));
}

test "unit: browser-cli: availability recognizes bare and bracketed IPv6 loopback" {
    // A bare IPv6 literal has no port; its colons are part of the address.
    try testing.expect(isLoopbackPattern("::1"));
    try testing.expect(isLoopbackPattern("http://[::1]:3000/app"));
    try testing.expect(isLoopbackPattern("[::1]"));
    try testing.expect(isLoopbackPattern("localhost:3000"));
    try testing.expect(isLoopbackPattern("https://127.0.0.1:8443/x"));
    try testing.expect(!isLoopbackPattern("::2"));
    try testing.expect(!isLoopbackPattern("[::2]:80"));
    try testing.expect(!isLoopbackPattern(""));
    try testing.expect(!isLoopbackPattern(":"));
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try status(arena_state.allocator(), "{\"browser\":{\"urlAllowlist\":[\"example.com\",\"::1\"]}}", null, "x", null);
    try testing.expect(s.allowlistActive() and s.allowsLocalhost());
}

test "unit: browser-cli: availability edits are lossless and idempotent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fresh = try edit(a, null, false);
    try testing.expect(fresh.changed);
    const s1 = try status(a, fresh.text, null, "x", null);
    try testing.expect(!s1.enabled);
    const src = "{\n  // keep me\n  \"font\": 12,\n  \"wmux\": { \"browser\": { \"enabled\": false } }\n}\n";
    const on = try edit(a, src, true);
    try testing.expect(std.mem.indexOf(u8, on.text, "// keep me") != null);
    try testing.expect((try status(a, on.text, null, "x", null)).enabled);
    const again = try edit(a, on.text, true);
    try testing.expect(!again.changed);
    try testing.expectError(error.SyntaxError, edit(a, "{oops", true));
    try testing.expectError(error.RootNotObject, edit(a, "[1]", true));
    try testing.expectError(error.PathConflict, edit(a, "{\"wmux\":{\"browser\":true}}", false));
    try testing.expectError(error.PathConflict, edit(a, "{\"wmux\":5}", false));
    // A null parent is replaced (json_edit), not a conflict.
    try testing.expect(!(try status(a, (try edit(a, "{\"wmux\":null}", false)).text, null, "x", null)).enabled);
    try testing.expect((try edit(a, "\xEF\xBB\xBF  \n", true)).changed);
    try testing.expectEqualStrings("Browser availability is managed by your organization (MDM policy for domain HKLM\\Software\\Policies\\wmux); it cannot be changed from the CLI.", try managedMessage(a, "HKLM\\Software\\Policies\\wmux"));
}
