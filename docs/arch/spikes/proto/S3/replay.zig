//! S3 spike reference prototype (not shipped): the pure part of
//! terminal-side scrollback replay (ARCHITECTURE ADR-9.5).
//!
//! `buildReplay` turns a saved scrollback file into the exact byte stream
//! that W1-7 feeds through the termio stream handler in Termio.threadEnter,
//! BEFORE the backend starts the subprocess and the PTY read thread:
//!
//!   sanitize(saved) ++ ESC[0m ++ "\r\n" x rows ++ ESC[H
//!
//! * sanitize: the file is untrusted at replay time (another process may
//!   have written it). Only printable text, TAB, line breaks and SGR
//!   (CSI ... m) survive. Everything else is dropped, so a replay can never
//!   make the stream handler answer a query (DSR/DA/XTVERSION responses
//!   would be queued as PTY writes and typed into the new shell), set the
//!   clipboard (OSC 52), change the title/pwd/colors, or switch screens.
//!   Lone LF becomes CRLF, lone CR is dropped, trailing line breaks are
//!   trimmed (so the new prompt follows the last saved line directly).
//! * ESC[0m BEFORE the line feeds: Ghostty fills rows that scroll in with
//!   the current background (BCE), so an unterminated SGR background in the
//!   file would otherwise paint the whole blank screen.
//! * "\r\n" x rows: scrolls every replayed line into scrollback and leaves
//!   a blank active area. ConPTY's first frame is
//!   ESC[?25l ESC[2J ESC[m ESC[H (measured, in-box conhost 10.0.26100),
//!   and Ghostty's ED2 clears only the active area.
//! * ESC[H: parks the cursor at the top-left (where ConPTY assumes it is).
//!   With the cursor on the bottom row, a row-growing resize before the
//!   shell's first frame makes Ghostty "pull down" scrollback into the
//!   active area (PageList.resizeWithoutReflow), where ConPTY's ED2 then
//!   erases it. With the cursor at the top, Ghostty adds blank rows instead.
//!
//! Test: zig test replay.zig

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Terminal rows at replay time (Termio.terminal.rows).
    rows: u16,
    /// Emit ESC[H after the line feeds (recommended; see file comment).
    home: bool = true,
    /// Byte cap applied to the sanitized text (tail kept, cut on a line
    /// boundary). ADR-9.2 caps the saved file at 400,000 characters.
    max_bytes: usize = 1_600_000,
};

/// Build the replay byte stream. Caller owns the result.
pub fn buildReplay(gpa: Allocator, saved: []const u8, opts: Options) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const clean = try sanitize(gpa, saved);
    defer gpa.free(clean);

    // Keep the tail if over the cap, starting at a line boundary.
    var text: []const u8 = clean;
    if (text.len > opts.max_bytes) {
        text = text[text.len - opts.max_bytes ..];
        if (std.mem.indexOf(u8, text, "\r\n")) |nl| text = text[nl + 2 ..];
    }

    try out.ensureTotalCapacity(gpa, text.len + 8 + 2 * @as(usize, opts.rows));
    out.appendSliceAssumeCapacity(text);
    out.appendSliceAssumeCapacity("\x1b[0m");
    for (0..opts.rows) |_| out.appendSliceAssumeCapacity("\r\n");
    if (opts.home) out.appendSliceAssumeCapacity("\x1b[H");
    return out.toOwnedSlice(gpa);
}

/// SGR-only filter (see file comment). Caller owns the result.
pub fn sanitize(gpa: Allocator, in: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, in.len + in.len / 16);

    var i: usize = 0;
    while (i < in.len) {
        const c = in[i];
        switch (c) {
            0x1b => i = try escape(gpa, &out, in, i),
            '\n' => {
                try out.appendSlice(gpa, "\r\n");
                i += 1;
            },
            '\r' => {
                if (i + 1 < in.len and in[i + 1] == '\n') {
                    try out.appendSlice(gpa, "\r\n");
                    i += 2;
                } else i += 1; // lone CR: dropped
            },
            '\t' => {
                try out.append(gpa, c);
                i += 1;
            },
            0x00...0x08, 0x0b...0x0c, 0x0e...0x1a, 0x1c...0x1f, 0x7f => i += 1,
            0xc2 => {
                // UTF-8 encoded C1 controls (U+0080..U+009F): dropped.
                if (i + 1 < in.len and in[i + 1] >= 0x80 and in[i + 1] <= 0x9f) {
                    i += 2;
                } else {
                    try out.append(gpa, c);
                    i += 1;
                }
            },
            else => {
                try out.append(gpa, c);
                i += 1;
            },
        }
    }

    // Trim trailing line breaks and whitespace-only tail so the new prompt
    // directly follows the last saved line.
    var end = out.items.len;
    while (end > 0) : (end -= 1) {
        const b = out.items[end - 1];
        if (b != '\r' and b != '\n' and b != ' ') break;
    }
    out.shrinkRetainingCapacity(end);
    return out.toOwnedSlice(gpa);
}

/// Handle an escape sequence starting at in[start] == ESC. Appends it to
/// `out` only if it is a well-formed SGR. Returns the index after it.
fn escape(gpa: Allocator, out: *std.ArrayList(u8), in: []const u8, start: usize) Allocator.Error!usize {
    var i = start + 1;
    if (i >= in.len) return i;
    switch (in[i]) {
        '[' => {
            // CSI: params 0x30-0x3F, intermediates 0x20-0x2F, final 0x40-0x7E.
            i += 1;
            var sgr_ok = true;
            while (i < in.len and in[i] >= 0x30 and in[i] <= 0x3f) : (i += 1) {
                const p = in[i];
                if (!((p >= '0' and p <= '9') or p == ';' or p == ':')) sgr_ok = false;
            }
            while (i < in.len and in[i] >= 0x20 and in[i] <= 0x2f) : (i += 1) sgr_ok = false;
            if (i >= in.len) return i; // truncated: drop
            const final = in[i];
            i += 1;
            if (final < 0x40 or final > 0x7e) return i; // malformed: drop
            if (sgr_ok and final == 'm') try out.appendSlice(gpa, in[start..i]);
            return i;
        },
        ']', 'P', 'X', '^', '_' => {
            // OSC / DCS / SOS / PM / APC: skip to BEL (OSC only) or ST.
            const is_osc = in[i] == ']';
            i += 1;
            while (i < in.len) : (i += 1) {
                if (is_osc and in[i] == 0x07) return i + 1;
                if (in[i] == 0x1b and i + 1 < in.len and in[i + 1] == '\\') return i + 2;
            }
            return i;
        },
        else => {
            // Two-byte escapes (ESC c, ESC 7, ESC =, ...) and nF sequences
            // (ESC SP F, ESC ( B, ...): drop.
            while (i < in.len and in[i] >= 0x20 and in[i] <= 0x2f) : (i += 1) {}
            return @min(i + 1, in.len);
        },
    }
}

const testing = std.testing;

test "sanitize keeps text, tabs and SGR" {
    const out = try sanitize(testing.allocator, "a\tb \x1b[1;38;2;1;2;3mred\x1b[0m\x1b[38:5:9mx\x1b[m");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a\tb \x1b[1;38;2;1;2;3mred\x1b[0m\x1b[38:5:9mx\x1b[m", out);
}

test "sanitize drops queries, OSC, DCS, mode changes and C0" {
    const in = "A\x1b[6n\x1b[c\x1b[>q\x1b]52;c;SGVsbG8=\x07\x1b]0;title\x1b\\" ++
        "\x1bP+q544e\x1b\\\x1b[?1049h\x1b[2J\x1b[3J\x1bc\x1b7\x1b(B\x07\x08B";
    const out = try sanitize(testing.allocator, in);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("AB", out);
}

test "sanitize normalizes line breaks and trims the tail" {
    const out = try sanitize(testing.allocator, "one\ntwo\r\nthree\rX\r\n\r\n  \n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("one\r\ntwo\r\nthreeX", out);
}

test "sanitize drops UTF-8 C1 controls but keeps other UTF-8" {
    const out = try sanitize(testing.allocator, "\xc2\x9b6n\xc3\xa9\xe2\x94\x80\xc2\xa0");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("6n\xc3\xa9\xe2\x94\x80\xc2\xa0", out);
}

test "sanitize drops truncated sequences" {
    const out = try sanitize(testing.allocator, "ok\x1b[38;5");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("ok", out);
}

test "buildReplay appends reset, rows x CRLF and home" {
    const out = try buildReplay(testing.allocator, "L1\nL2\n", .{ .rows = 3 });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("L1\r\nL2\x1b[0m\r\n\r\n\r\n\x1b[H", out);
}

test "buildReplay without home" {
    const out = try buildReplay(testing.allocator, "L1", .{ .rows = 2, .home = false });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("L1\x1b[0m\r\n\r\n", out);
}

test "buildReplay caps on a line boundary and keeps the tail" {
    const out = try buildReplay(testing.allocator, "aaaa\nbbbb\ncccc", .{ .rows = 1, .home = false, .max_bytes = 8 });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("cccc\x1b[0m\r\n", out);
}
