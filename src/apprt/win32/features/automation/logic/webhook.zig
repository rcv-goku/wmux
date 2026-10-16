//! Webhook URL and redirect policy (cli-automation-actions `webhook`).
//!
//! - The URL must be absolute `http://` or `https://` with a host. Spaces,
//!   control characters and backslashes are refused, so no HTTP client can
//!   read a different host than the origin checks here (a WHATWG-style
//!   parser treats `\` as `/`: `https://a.example\@b.example/` is host
//!   `a.example` there but `b.example` to an RFC 3986 parser).
//! - Credential-bearing requests (credential-like header names, URL userinfo
//!   or credential-like query parameters) must use HTTPS.
//! - Header names must be HTTP tokens and values must not contain CR, LF or
//!   NUL (no header injection).
//! - Redirects are followed by hand: a `Location` that leads to plain
//!   `http://` is refused, and credential headers are not sent on to a
//!   target whose scheme, host or port differs from the current one.

const std = @import("std");
const redact = @import("redact.zig");

pub const Scheme = enum {
    http,
    https,

    pub fn defaultPort(self: Scheme) u16 {
        return switch (self) {
            .http => 80,
            .https => 443,
        };
    }
};

pub const Url = struct {
    scheme: Scheme,
    userinfo: ?[]const u8 = null,
    /// Host as written (brackets kept for IPv6 literals).
    host: []const u8,
    port: ?u16 = null,
    /// Path, query and fragment (may be empty).
    rest: []const u8 = "",

    pub fn effectivePort(self: Url) u16 {
        return self.port orelse self.scheme.defaultPort();
    }

    /// Same scheme, host (ignoring ASCII case) and effective port.
    pub fn sameOrigin(a: Url, b: Url) bool {
        return a.scheme == b.scheme and std.ascii.eqlIgnoreCase(a.host, b.host) and a.effectivePort() == b.effectivePort();
    }

    /// Parses an absolute http(s) URL. Returns null for anything else,
    /// including URLs with spaces, control characters or backslashes.
    pub fn parse(text: []const u8) ?Url {
        for (text) |c| {
            if (c <= 0x20 or c == 0x7F or c == '\\') return null;
        }
        const sep = std.mem.indexOf(u8, text, "://") orelse return null;
        const scheme_text = text[0..sep];
        const scheme: Scheme = if (std.ascii.eqlIgnoreCase(scheme_text, "https"))
            .https
        else if (std.ascii.eqlIgnoreCase(scheme_text, "http"))
            .http
        else
            return null;
        const after = text[sep + 3 ..];
        const auth_end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
        var authority = after[0..auth_end];
        var userinfo: ?[]const u8 = null;
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
            userinfo = authority[0..at];
            authority = authority[at + 1 ..];
        }
        var host = authority;
        var port: ?u16 = null;
        if (std.mem.startsWith(u8, authority, "[")) {
            const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
            host = authority[0 .. close + 1];
            const tail = authority[close + 1 ..];
            if (tail.len > 0) {
                if (tail[0] != ':') return null;
                port = parsePort(tail[1..]) orelse return null;
            }
        } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
            host = authority[0..colon];
            port = parsePort(authority[colon + 1 ..]) orelse return null;
        }
        if (host.len == 0 or host.len > 253 + 2) return null;
        return .{ .scheme = scheme, .userinfo = userinfo, .host = host, .port = port, .rest = after[auth_end..] };
    }
};

fn parsePort(s: []const u8) ?u16 {
    if (s.len == 0 or s.len > 5) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseInt(u16, s, 10) catch return null;
    return if (n == 0) null else n;
}

pub const Header = struct { name: []const u8, value: []const u8 };

/// Credential-bearing header names (`Authorization`, `Cookie`, token,
/// secret and API-key styles).
pub fn isCredentialHeader(name: []const u8) bool {
    return redact.isCredentialName(name);
}

fn isTokenChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

pub fn isValidHeaderName(name: []const u8) bool {
    if (name.len == 0 or name.len > 256) return false;
    for (name) |c| if (!isTokenChar(c)) return false;
    return true;
}

pub fn isValidHeaderValue(value: []const u8) bool {
    for (value) |c| if (c == '\r' or c == '\n' or c == 0) return false;
    return true;
}

pub const messages = struct {
    pub const bad_url = "webhook url must be an absolute http:// or https:// URL";
    pub const needs_https = "webhook url must use https when credentials are sent (credential headers, userinfo or query credentials)";
    pub const bad_header_name = "webhook header name is not a valid HTTP token";
    pub const bad_header_value = "webhook header value must not contain CR, LF or NUL";
};

pub fn hasCredentials(url: []const u8, headers: []const Header) bool {
    for (headers) |h| if (isCredentialHeader(h.name)) return true;
    return redact.urlHasCredentials(url);
}

/// Load-time check of a webhook action; returns the problem message or null.
pub fn validate(url: []const u8, headers: []const Header) ?[]const u8 {
    const u = Url.parse(url) orelse return messages.bad_url;
    for (headers) |h| {
        if (!isValidHeaderName(h.name)) return messages.bad_header_name;
        if (!isValidHeaderValue(h.value)) return messages.bad_header_value;
    }
    if (u.scheme != .https and hasCredentials(url, headers)) return messages.needs_https;
    return null;
}

pub const RedirectDecision = enum {
    /// Follow with all headers (same origin, https).
    follow,
    /// Follow, but drop credential headers first (cross-origin).
    follow_without_credentials,
    /// The target is cleartext http.
    reject_cleartext,
    /// The Location is not a usable http(s) URL.
    reject_invalid,
};

pub const Redirect = struct {
    decision: RedirectDecision,
    /// The absolute target when it is followed (borrowed from `location` or `buf`).
    target: ?Url = null,
};

/// Decides how to follow a redirect from `from` to `location` (absolute,
/// scheme-relative `//host/…` or path-absolute `/…`). `buf` receives the
/// resolved absolute URL text when `location` is relative.
pub fn redirect(from: Url, location: []const u8, buf: []u8) Redirect {
    const text: []const u8 = blk: {
        if (std.mem.startsWith(u8, location, "//")) {
            break :blk std.fmt.bufPrint(buf, "{s}:{s}", .{ @tagName(from.scheme), location }) catch return .{ .decision = .reject_invalid };
        }
        if (std.mem.startsWith(u8, location, "/")) {
            const port_buf_len = 8;
            var pb: [port_buf_len]u8 = undefined;
            const port_text = if (from.port) |p| std.fmt.bufPrint(&pb, ":{d}", .{p}) catch unreachable else "";
            break :blk std.fmt.bufPrint(buf, "{s}://{s}{s}{s}", .{ @tagName(from.scheme), from.host, port_text, location }) catch return .{ .decision = .reject_invalid };
        }
        break :blk location;
    };
    const to = Url.parse(text) orelse return .{ .decision = .reject_invalid };
    if (to.scheme != .https) return .{ .decision = .reject_cleartext };
    if (!Url.sameOrigin(from, to)) return .{ .decision = .follow_without_credentials, .target = to };
    return .{ .decision = .follow, .target = to };
}

/// Headers to send after a redirect with `decision`, written into `out`
/// (which must hold `headers.len` entries). Returns the kept slice.
pub fn headersAfterRedirect(decision: RedirectDecision, headers: []const Header, out: []Header) []Header {
    var n: usize = 0;
    switch (decision) {
        .follow => for (headers) |h| {
            out[n] = h;
            n += 1;
        },
        .follow_without_credentials => for (headers) |h| {
            if (isCredentialHeader(h.name)) continue;
            out[n] = h;
            n += 1;
        },
        .reject_cleartext, .reject_invalid => {},
    }
    return out[0..n];
}

const testing = std.testing;

test "unit: automation: webhook URL parsing and origins" {
    const u = Url.parse("HTTPS://user:pw@Hooks.Example:8443/path?q=1#f").?;
    try testing.expectEqual(Scheme.https, u.scheme);
    try testing.expectEqualStrings("user:pw", u.userinfo.?);
    try testing.expectEqualStrings("Hooks.Example", u.host);
    try testing.expectEqual(@as(u16, 8443), u.effectivePort());
    try testing.expectEqualStrings("/path?q=1#f", u.rest);
    const v6 = Url.parse("http://[::1]:9000").?;
    try testing.expectEqualStrings("[::1]", v6.host);
    try testing.expectEqual(@as(u16, 9000), v6.port.?);
    try testing.expect(Url.sameOrigin(Url.parse("https://a.example/x").?, Url.parse("https://A.EXAMPLE:443/y").?));
    try testing.expect(!Url.sameOrigin(Url.parse("https://a.example").?, Url.parse("https://a.example:444").?));
    try testing.expect(!Url.sameOrigin(Url.parse("https://a.example").?, Url.parse("http://a.example").?));
    const bad = [_][]const u8{ "", "hooks.example/x", "ftp://h/", "https://", "https:///x", "https://h:0/", "https://h:99999/", "https://h:x/", "https://h /", "https://[::1/", "https://[::1]x/", "file:///etc/passwd", "https://h/\r\nX: y", "https://evil.example\\@hooks.example/x", "https:\\\\h.example/", "https://h.example/a\\b" };
    for (bad) |b| try testing.expect(Url.parse(b) == null);
}

test "unit: automation: webhook refuses backslash URLs and redirects" {
    // Hosts must not depend on how a client treats `\` (WHATWG reads it as `/`).
    try testing.expectEqualStrings(messages.bad_url, validate("https://evil.example\\@hooks.example/x", &.{.{ .name = "Authorization", .value = "x" }}).?);
    var buf: [256]u8 = undefined;
    const from = Url.parse("https://hooks.example/a").?;
    try testing.expectEqual(RedirectDecision.reject_invalid, redirect(from, "https://evil.example\\@hooks.example/b", &buf).decision);
    try testing.expectEqual(RedirectDecision.reject_invalid, redirect(from, "/\\evil.example/b", &buf).decision);
    try testing.expectEqual(RedirectDecision.follow, redirect(from, "/b?x=%5C", &buf).decision);
}

test "unit: automation: webhook with credential headers must use https" {
    const auth = [_]Header{.{ .name = "Authorization", .value = "Bearer x" }};
    const plain = [_]Header{.{ .name = "X-Trace", .value = "1" }};
    try testing.expectEqualStrings(messages.needs_https, validate("http://hooks.example/x", &auth).?);
    try testing.expect(validate("https://hooks.example/x", &auth) == null);
    try testing.expect(validate("http://hooks.example/x", &plain) == null);
    try testing.expect(validate("http://hooks.example/x", &.{}) == null);
    try testing.expectEqualStrings(messages.needs_https, validate("http://u:p@hooks.example/", &.{}).?);
    try testing.expectEqualStrings(messages.needs_https, validate("http://hooks.example/?token=1", &.{}).?);
    try testing.expectEqualStrings(messages.needs_https, validate("http://h.example/", &.{.{ .name = "Cookie", .value = "a=b" }}).?);
    try testing.expectEqualStrings(messages.bad_url, validate("ftp://h/", &.{}).?);
    try testing.expectEqualStrings(messages.bad_header_name, validate("https://h/", &.{.{ .name = "Bad Name", .value = "" }}).?);
    try testing.expectEqualStrings(messages.bad_header_name, validate("https://h/", &.{.{ .name = "", .value = "" }}).?);
    try testing.expectEqualStrings(messages.bad_header_value, validate("https://h/", &.{.{ .name = "X", .value = "a\r\nInjected: 1" }}).?);
}

test "unit: automation: webhook redirects reject cleartext and strip credentials across origins" {
    var buf: [2048]u8 = undefined;
    const from = Url.parse("https://hooks.example:8443/a").?;
    try testing.expectEqual(RedirectDecision.follow, redirect(from, "/b", &buf).decision);
    try testing.expectEqual(@as(u16, 8443), redirect(from, "/b", &buf).target.?.effectivePort());
    try testing.expectEqual(RedirectDecision.follow, redirect(from, "https://HOOKS.example:8443/c", &buf).decision);
    try testing.expectEqual(RedirectDecision.follow_without_credentials, redirect(from, "https://other.example/c", &buf).decision);
    try testing.expectEqual(RedirectDecision.follow_without_credentials, redirect(from, "//other.example/c", &buf).decision);
    try testing.expectEqual(RedirectDecision.reject_cleartext, redirect(from, "http://hooks.example:8443/a", &buf).decision);
    try testing.expectEqual(RedirectDecision.reject_cleartext, redirect(Url.parse("http://h.example/").?, "/x", &buf).decision);
    try testing.expectEqual(RedirectDecision.reject_invalid, redirect(from, "", &buf).decision);
    try testing.expectEqual(RedirectDecision.reject_invalid, redirect(from, "javascript:alert(1)", &buf).decision);
    var tiny: [4]u8 = undefined;
    try testing.expectEqual(RedirectDecision.reject_invalid, redirect(from, "/long/path", &tiny).decision);

    const headers = [_]Header{ .{ .name = "Authorization", .value = "x" }, .{ .name = "X-Api-Key", .value = "k" }, .{ .name = "Content-Type", .value = "application/json" } };
    var out: [headers.len]Header = undefined;
    try testing.expectEqual(@as(usize, 3), headersAfterRedirect(.follow, &headers, &out).len);
    const kept = headersAfterRedirect(.follow_without_credentials, &headers, &out);
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings("Content-Type", kept[0].name);
    try testing.expectEqual(@as(usize, 0), headersAfterRedirect(.reject_cleartext, &headers, &out).len);
}
