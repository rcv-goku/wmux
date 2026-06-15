const std = @import("std");

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

const log = std.log.scoped(.osc_kitty_notification);

/// Parse OSC 99, the Kitty desktop-notification protocol.
/// https://sw.kovidgoyal.net/kitty/desktop-notifications/
///
/// Wire format: `OSC 99 ; <metadata> ; <payload> ST` where `<metadata>` is
/// a (possibly empty) list of colon-separated `key=value` pairs and
/// `<payload>` is the notification text. Both semicolons are mandatory, so
/// the trailing data captured after `99;` always begins at the metadata.
///
/// Relevant metadata keys (others are accepted and ignored):
///   p  payload type: `title` (default), `body`, or one of the control
///      types (`close`, `icon`, `alive`, `buttons`, `?`) which carry no
///      user-visible text and are dropped here.
///   e  encoding: `0` plain UTF-8 (default) or `1` Base64.
///   i  notification id (parsed for completeness; not used by the apprt
///      mapping, which keys notifications by the emitting surface).
///   d  done flag (0=more chunks coming, 1=complete). We map each OSC 99
///      sequence to one `show_desktop_notification`; cross-sequence chunk
///      reassembly (a title in one OSC and a body in another sharing an
///      `i=`) is intentionally NOT performed here — it would require
///      stateful accumulation across OSCs, which belongs in the apprt, not
///      this pure parser. A title-only or body-only sequence still shows.
///
/// The payload maps into the shared `show_desktop_notification {title, body}`
/// command (the same channel OSC 9 / OSC 777 use), so it flows through the
/// existing desktop-notification + attention pipeline with no apprt change.
/// A `p=title` payload becomes the `title`; a `p=body` payload becomes the
/// `body`. Control payload types produce no command (the OSC is consumed
/// silently) so that, e.g., a `p=?` capability query does not pop a balloon.
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };
    // Sentinel-terminate so the slices below are NUL-terminated for the
    // [:0] command fields (mirrors the rxvt/osc9 parsers).
    cap.writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();
    // data is `<metadata>;<payload>\0`. Strip the trailing sentinel for the
    // logical content; keep the buffer for in-place NUL insertion.
    if (data.len == 0) {
        parser.state = .invalid;
        return null;
    }
    const content = data[0 .. data.len - 1];

    // Split metadata from payload at the first unescaped ';'. The metadata
    // alphabet excludes ';', so the first ';' is always the separator.
    const sep = std.mem.indexOfScalar(u8, content, ';') orelse {
        // No second ';': malformed per spec (both semicolons mandatory).
        log.warn("OSC 99 missing payload separator", .{});
        parser.state = .invalid;
        return null;
    };
    const metadata = content[0..sep];
    // Payload spans [sep+1 .. end); it already ends right before the
    // sentinel NUL at data[data.len-1].
    const payload_start = sep + 1;

    const meta = parseMetadata(metadata);

    // Control payload types carry no user-visible notification text. Drop
    // them silently (a capability query, close, icon update, etc.) instead
    // of surfacing an empty balloon.
    switch (meta.payload_type) {
        .title, .body => {},
        .other => {
            parser.state = .invalid;
            return null;
        },
    }

    // Decode the payload. For plain UTF-8 we can point into the captured
    // buffer; for Base64 we must decode in place. Either way the result is
    // NUL-terminated using the buffer's trailing sentinel slot.
    const text: [:0]const u8 = text: {
        if (meta.base64) {
            // Decode in place into the same buffer region (decoded length
            // is always <= encoded length). Then write a NUL after it.
            const dec = std.base64.standard.Decoder;
            const enc = data[payload_start .. data.len - 1];
            const out_len = dec.calcSizeForSlice(enc) catch {
                log.warn("OSC 99 invalid base64 payload", .{});
                parser.state = .invalid;
                return null;
            };
            dec.decode(data[payload_start .. payload_start + out_len], enc) catch {
                log.warn("OSC 99 invalid base64 payload", .{});
                parser.state = .invalid;
                return null;
            };
            data[payload_start + out_len] = 0;
            break :text data[payload_start .. payload_start + out_len :0];
        }
        break :text data[payload_start .. data.len - 1 :0];
    };

    parser.command = switch (meta.payload_type) {
        .body => .{ .show_desktop_notification = .{ .title = "", .body = text } },
        // Default/title: surface as the title with no body.
        else => .{ .show_desktop_notification = .{ .title = text, .body = "" } },
    };
    return &parser.command;
}

const PayloadType = enum { title, body, other };

const Metadata = struct {
    payload_type: PayloadType = .title,
    base64: bool = false,
    /// Done flag. Defaults true (a single-shot notification is complete).
    done: bool = true,
};

/// Parse the colon-separated `key=value` metadata. Unknown keys are
/// ignored. Pure so the mapping is unit-testable independent of the parser
/// state machine.
pub fn parseMetadata(metadata: []const u8) Metadata {
    var meta: Metadata = .{};
    var it = std.mem.splitScalar(u8, metadata, ':');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const value = pair[eq + 1 ..];
        if (key.len != 1) continue;
        switch (key[0]) {
            'p' => {
                if (std.mem.eql(u8, value, "title")) {
                    meta.payload_type = .title;
                } else if (std.mem.eql(u8, value, "body")) {
                    meta.payload_type = .body;
                } else {
                    meta.payload_type = .other;
                }
            },
            'e' => meta.base64 = std.mem.eql(u8, value, "1"),
            'd' => meta.done = !std.mem.eql(u8, value, "0"),
            else => {},
        }
    }
    return meta;
}

test "OSC 99: title-only notification (empty metadata)" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "99;;Hello world";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("Hello world", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("", cmd.show_desktop_notification.body);
}

test "OSC 99: explicit p=title" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "99;p=title;Build done";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("Build done", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("", cmd.show_desktop_notification.body);
}

test "OSC 99: p=body maps to the body field" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "99;i=1:d=1:p=body;Tests passed";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("Tests passed", cmd.show_desktop_notification.body);
}

test "OSC 99: base64-encoded payload (e=1) is decoded" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // base64("Hi there") = "SGkgdGhlcmU="
    const input = "99;e=1;SGkgdGhlcmU=";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("Hi there", cmd.show_desktop_notification.title);
}

test "OSC 99: base64 body" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // base64("done") = "ZG9uZQ=="
    const input = "99;p=body:e=1;ZG9uZQ==";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("done", cmd.show_desktop_notification.body);
}

test "OSC 99: control payload type (p=?) produces no command" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "99;p=?;";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC 99: missing second semicolon is invalid" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "99;p=title";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC 99: empty body payload still parses" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "99;;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("", cmd.show_desktop_notification.body);
}

test "OSC 99: parseMetadata defaults and overrides" {
    const testing = std.testing;
    const d = parseMetadata("");
    try testing.expectEqual(PayloadType.title, d.payload_type);
    try testing.expectEqual(false, d.base64);
    try testing.expectEqual(true, d.done);

    const m = parseMetadata("i=abc:p=body:e=1:d=0:x=ignored");
    try testing.expectEqual(PayloadType.body, m.payload_type);
    try testing.expectEqual(true, m.base64);
    try testing.expectEqual(false, m.done);
}
