//! Unit-test index of feature `vault` (ADR-12.1): import every logic/*.zig file
//! here and name tests "unit: vault: <behavior>". Logic files use only std,
//! wmux_proto and sibling logic files; they run in `zig build test-fast`.

const std = @import("std");
const testing = std.testing;
const index = @import("index.zig");
const query = @import("query.zig");
const checkpoints = @import("checkpoints.zig");

test {
    _ = index;
    _ = query;
    _ = checkpoints;
}

// ---------------------------------------------------------------------------
// Fixtures (authored for these tests; shapes follow the documented formats)

const claude_id = "7f1c2a3b-4d5e-4f60-8a71-92b3c4d5e6f7";

const claude_fixture =
    \\{"type":"summary","summary":"Fix socket","leafUuid":"u9"}
    \\{"type":"user","sessionId":"7f1c2a3b-4d5e-4f60-8a71-92b3c4d5e6f7","cwd":"C:\\src\\wmux","gitBranch":"main","timestamp":"2026-10-14T09:00:00.000Z","uuid":"u1","message":{"role":"user","content":"Fix the socket error in ipc.zig\nplease"}}
    \\{"type":"assistant","sessionId":"7f1c2a3b-4d5e-4f60-8a71-92b3c4d5e6f7","timestamp":"2026-10-14T09:00:05.000Z","uuid":"u2","message":{"role":"assistant","content":[{"type":"text","text":"Looking at the pipe server."},{"type":"tool_use","id":"t1","name":"Read","input":{"path":"ipc.zig"}}]}}
    \\{"type":"user","sessionId":"7f1c2a3b-4d5e-4f60-8a71-92b3c4d5e6f7","timestamp":"2026-10-14T09:00:06.000Z","uuid":"u3","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"error: broken pipe 0xE8"}]}}
    \\{"type":"user","sessionId":"7f1c2a3b-4d5e-4f60-8a71-92b3c4d5e6f7","isMeta":true,"timestamp":"2026-10-14T09:00:07.000Z","message":{"role":"user","content":"Caveat: meta"}}
    \\{"type":"user","sessionId":"7f1c2a3b-4d5e-4f60-8a71-92b3c4d5e6f7","timestamp":"2026-10-14T09:01:00.000Z","uuid":"u4","message":{"role":"user","content":[{"type":"text","text":"Now add a test"}]}}
    \\{"type":"assistant","sessionId":"7f1c2a3b-4d5e-4f60-8a71-92b3c4d5e6f7","timestamp":"2026-10-14T09:01:10.000Z","uuid":"u5","message":{"role":"assistant","content":[{"type":"text","text":"Added unit: ipc test."}]}}
    \\{"type":"user","sessionId":"7f1c2a3b-4d5e-4f60-8a71-92b3c4d5e6f7","timestamp":"2026-10-14T09:02:00.000Z","uuid":"u6","message":{"role":"user","content":"<local-command-stdout>ok</local-command-stdout>"}}
    \\{"type":"user","sessionId":"7f1c2a3b-4d5e-4f60-8a71-92b3c4d5e6f7","timestamp":"2026-10-14T09:03:00.000Z","uuid":"u7","message":{"role":"user","content":"Third: commit it, cost 1.50"}}
    \\{"type":"assistant","sessionId":"7f1c2a3b-4d5e-4f60-8a71-92b3c4d5e6f7","timestamp":"2026-10-14T09:03:30.000Z","uuid":"u8","costUSD":1.50,"message":{"role":"assistant","content":[{"type":"text","text":"Committed."}]}}
    \\
;

const codex_id = "0199a1b2-c3d4-4e5f-8a6b-7c8d9e0f1a2b";

const codex_fixture =
    \\{"timestamp":"2026-10-02T10:00:00.000Z","type":"session_meta","payload":{"id":"0199a1b2-c3d4-4e5f-8a6b-7c8d9e0f1a2b","timestamp":"2026-10-02T10:00:00.000Z","cwd":"/home/dev/wmux","originator":"codex_cli_rs","git":{"commit_hash":"abc123","branch":"feat/socket"}}}
    \\{"timestamp":"2026-10-02T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/home/dev/wmux</cwd>\n</environment_context>"}]}}
    \\{"timestamp":"2026-10-02T10:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Why do I get a socket error on reconnect?"}]}}
    \\{"timestamp":"2026-10-02T10:00:03.000Z","type":"event_msg","payload":{"type":"user_message","message":"Why do I get a socket error on reconnect?"}}
    \\{"timestamp":"2026-10-02T10:00:09.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"The handle is closed twice."}]}}
    \\{"timestamp":"2026-10-02T10:05:00.000Z","type":"turn_context","payload":{"cwd":"/home/dev/wmux","model":"x"}}
    \\{"timestamp":"2026-10-02T10:05:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix it"}]}}
    \\
;

const pi_fixture =
    \\{"type":"session","id":"5a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d","timestamp":"2026-09-20T08:00:00.000Z","cwd":"/home/dev/notes app"}
    \\{"type":"message","timestamp":"2026-09-20T08:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"Summarize TODO.md"}]}}
    \\{"type":"message","timestamp":"2026-09-20T08:00:04.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Three items remain."}]}}
    \\{"type":"message","timestamp":"2026-09-20T08:00:05.000Z","message":{"role":"toolResult","content":[{"type":"text","text":"file contents"}]}}
    \\
;

fn ms(iso: []const u8) i64 {
    return index.parseIso8601Ms(iso).?;
}

fn ingestAll(idx: *index.Index, path: []const u8, agent: []const u8, bytes: []const u8, mtime: []const u8) !*index.Entry {
    return idx.ingest(path, agent, .{ .size = bytes.len, .mtime_ms = ms(mtime) }, 0, bytes, true);
}

// ---------------------------------------------------------------------------
// index.zig

test "unit: vault: claude transcript yields id, cwd, branch, title and turns" {
    var idx = index.Index.init(testing.allocator);
    defer idx.deinit();
    const e = try ingestAll(&idx, "C:\\Users\\me\\.claude\\projects\\C--src-wmux\\" ++ claude_id ++ ".jsonl", "claude", claude_fixture, "2026-10-14T09:03:31Z");
    const s = &e.session;
    try testing.expectEqualStrings(claude_id, s.id);
    try testing.expectEqualStrings("C:\\src\\wmux", s.cwd);
    try testing.expectEqualStrings("main", s.branch);
    try testing.expectEqualStrings("Fix the socket error in ipc.zig", s.title);
    try testing.expectEqual(@as(u32, 3), s.turns);
    try testing.expectEqual(@as(u32, 0), s.malformed_lines);
    try testing.expectEqual(ms("2026-10-14T09:00:00Z"), s.created_ms);
    try testing.expectEqual(ms("2026-10-14T09:03:30Z"), s.last_record_ms);
    try testing.expectEqual(ms("2026-10-14T09:03:31Z"), s.modifiedMs());
    try testing.expectEqualStrings("Claude Code", s.agentName());
    // Tool results are searchable; tool_use input is not indexed.
    try testing.expect(std.mem.indexOf(u8, s.text.items, "broken pipe") != null);
    try testing.expect(std.mem.indexOf(u8, s.text.items, "Committed.") != null);
    try testing.expect(std.mem.indexOf(u8, s.text.items, "\"path\"") == null);
    try testing.expectEqual(@as(u64, claude_fixture.len), e.consumed);
}

test "unit: vault: codex rollout yields meta, skips injected context as turns" {
    var idx = index.Index.init(testing.allocator);
    defer idx.deinit();
    const e = try ingestAll(&idx, "/home/dev/.codex/sessions/2026/10/02/rollout-2026-10-02T10-00-00-" ++ codex_id ++ ".jsonl", "codex", codex_fixture, "2026-10-02T10:05:01Z");
    const s = &e.session;
    try testing.expectEqualStrings(codex_id, s.id);
    try testing.expectEqualStrings("/home/dev/wmux", s.cwd);
    try testing.expectEqualStrings("feat/socket", s.branch);
    try testing.expectEqualStrings("Why do I get a socket error on reconnect?", s.title);
    try testing.expectEqual(@as(u32, 2), s.turns);
}

test "unit: vault: codex legacy un-wrapped layout is understood" {
    const legacy =
        \\{"id":"11111111-2222-4333-8444-555555555555","timestamp":"2025-05-01T12:00:00Z","instructions":"","git":{"branch":"dev"}}
        \\{"type":"message","role":"user","content":[{"type":"input_text","text":"hello legacy"}]}
        \\{"record_type":"state"}
        \\
    ;
    var idx = index.Index.init(testing.allocator);
    defer idx.deinit();
    const e = try ingestAll(&idx, "rollout-x.jsonl", "codex", legacy, "2025-05-01T12:00:00Z");
    try testing.expectEqualStrings("11111111-2222-4333-8444-555555555555", e.session.id);
    try testing.expectEqualStrings("dev", e.session.branch);
    try testing.expectEqualStrings("hello legacy", e.session.title);
    try testing.expectEqual(@as(u32, 1), e.session.turns);
}

test "unit: vault: pi-style session header and messages" {
    var idx = index.Index.init(testing.allocator);
    defer idx.deinit();
    const e = try ingestAll(&idx, "/home/dev/.pi/agent/sessions/--home-dev-notes--/x.jsonl", "pi", pi_fixture, "2026-09-20T08:00:05Z");
    try testing.expectEqualStrings("5a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d", e.session.id);
    try testing.expectEqualStrings("/home/dev/notes app", e.session.cwd);
    try testing.expectEqualStrings("Summarize TODO.md", e.session.title);
    try testing.expectEqual(@as(u32, 1), e.session.turns);
    try testing.expect(std.mem.indexOf(u8, e.session.text.items, "file contents") != null);
    try testing.expectEqualStrings("Pi", e.session.agentName());
}

test "unit: vault: empty transcript falls back to file stem and Untitled chat" {
    var idx = index.Index.init(testing.allocator);
    defer idx.deinit();
    const e = try ingestAll(&idx, "/p/abc-123.jsonl", "claude", "", "2026-01-01T00:00:00Z");
    try testing.expectEqualStrings("abc-123", e.session.id);
    try testing.expectEqual(@as(u32, 0), e.session.turns);
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try e.session.writeTitle(&w);
    try testing.expectEqualStrings("Untitled chat", w.buffered());
    e.session.forked = true;
    w = std.Io.Writer.fixed(&buf);
    try e.session.writeTitle(&w);
    try testing.expectEqualStrings("Untitled chat (fork)", w.buffered());
}

test "unit: vault: malformed lines are counted and skipped, never fatal" {
    const bad =
        \\not json at all
        \\[1,2,3]
        \\{"type":"user","sessionId":"s1","message":{"role":"user","content":"ok prompt"}}
        \\{"type":"user", "message": {"content": "unterminated
        \\
        \\{"type":"assistant","message":{"role":"assistant","content":42}}
        \\
    ;
    var idx = index.Index.init(testing.allocator);
    defer idx.deinit();
    const e = try ingestAll(&idx, "/p/s1.jsonl", "claude", bad, "2026-01-01T00:00:00Z");
    try testing.expectEqual(@as(u32, 3), e.session.malformed_lines);
    try testing.expectEqual(@as(u32, 1), e.session.turns);
    try testing.expectEqualStrings("ok prompt", e.session.title);
    try testing.expect(e.session.partiallySearchable());
}

test "unit: vault: unicode content, paths and titles survive" {
    const uni =
        \\{"type":"user","sessionId":"u-1","cwd":"C:\\Users\\Zoë\\プロジェクト","timestamp":"2026-10-16T01:00:00+09:00","message":{"role":"user","content":"Résumé \u00e9t\u00e9 — 日本語のテスト 🚀"}}
        \\
    ;
    var idx = index.Index.init(testing.allocator);
    defer idx.deinit();
    const e = try ingestAll(&idx, "/p/u-1.jsonl", "claude", uni, "2026-10-15T16:00:00Z");
    try testing.expectEqualStrings("C:\\Users\\Zoë\\プロジェクト", e.session.cwd);
    try testing.expectEqualStrings("Résumé été — 日本語のテスト 🚀", e.session.title);
    try testing.expectEqualStrings("プロジェクト", index.basename(e.session.cwd));
    try testing.expectEqual(ms("2026-10-15T16:00:00Z"), e.session.created_ms);
}

test "unit: vault: incremental ingest appends only complete lines" {
    var idx = index.Index.init(testing.allocator);
    defer idx.deinit();
    const path = "/p/" ++ claude_id ++ ".jsonl";
    // Cut mid-line: the partial tail is not consumed.
    const cut = std.mem.indexOf(u8, claude_fixture, "\"Now add a test\"").?;
    var e = try idx.ingest(path, "claude", .{ .size = cut, .mtime_ms = 1 }, 0, claude_fixture[0..cut], true);
    try testing.expectEqual(@as(u32, 1), e.session.turns);
    const consumed = e.consumed;
    try testing.expect(consumed < cut and claude_fixture[consumed - 1] == '\n');

    // Unchanged stat: nothing to read.
    try testing.expectEqual(index.Plan.unchanged, idx.plan(path, .{ .size = cut, .mtime_ms = 1 }));
    // Grown file: resume at the consumed offset.
    const p = idx.plan(path, .{ .size = claude_fixture.len, .mtime_ms = 2 });
    try testing.expectEqual(index.Plan{ .read_from = consumed }, p);
    e = try idx.ingest(path, "claude", .{ .size = claude_fixture.len, .mtime_ms = 2 }, consumed, claude_fixture[consumed..], true);
    try testing.expectEqual(@as(u32, 3), e.session.turns);
    try testing.expectEqual(@as(u64, claude_fixture.len), e.consumed);
    try testing.expectEqualStrings("Fix the socket error in ipc.zig", e.session.title);

    // Offsets that do not line up are rejected.
    try testing.expectError(error.OffsetMismatch, idx.ingest(path, "claude", .{ .size = 9, .mtime_ms = 3 }, 5, "x", true));
    try testing.expectError(error.OffsetMismatch, idx.ingest("/p/new.jsonl", "claude", .{ .size = 9, .mtime_ms = 3 }, 5, "x", true));
    try testing.expectEqual(@as(usize, 1), idx.count());

    // Shrunk (rewritten) file: full reparse from 0 resets the session.
    try testing.expectEqual(index.Plan{ .read_from = 0 }, idx.plan(path, .{ .size = 10, .mtime_ms = 4 }));
    const short =
        \\{"type":"user","sessionId":"other","message":{"role":"user","content":"rewritten"}}
        \\
    ;
    e = try idx.ingest(path, "claude", .{ .size = short.len, .mtime_ms = 4 }, 0, short, true);
    try testing.expectEqual(@as(u32, 1), e.session.turns);
    try testing.expectEqualStrings("rewritten", e.session.title);
    try testing.expectEqualStrings("other", e.session.id);
}

test "unit: vault: a failed ingest forces a full reparse" {
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var idx = index.Index.init(fa.allocator());
    defer idx.deinit();
    const path = "/p/" ++ claude_id ++ ".jsonl";
    const half = std.mem.indexOf(u8, claude_fixture, "{\"type\":\"user\",\"sessionId\":\"7f1c2a3b-4d5e-4f60-8a71-92b3c4d5e6f7\",\"timestamp\":\"2026-10-14T09:01").?;
    _ = try idx.ingest(path, "claude", .{ .size = half, .mtime_ms = 1 }, 0, claude_fixture[0..half], true);
    // Fail somewhere inside the next feed.
    fa.fail_index = fa.alloc_index + 3;
    const consumed = idx.get(path).?.consumed;
    try testing.expectError(error.OutOfMemory, idx.ingest(path, "claude", .{ .size = claude_fixture.len, .mtime_ms = 2 }, consumed, claude_fixture[consumed..], true));
    fa.fail_index = std.math.maxInt(usize);
    try testing.expectEqual(index.Plan{ .read_from = 0 }, idx.plan(path, .{ .size = claude_fixture.len, .mtime_ms = 2 }));
    try testing.expectError(error.OffsetMismatch, idx.ingest(path, "claude", .{ .size = claude_fixture.len, .mtime_ms = 2 }, consumed, claude_fixture[consumed..], true));
    const e = try idx.ingest(path, "claude", .{ .size = claude_fixture.len, .mtime_ms = 2 }, 0, claude_fixture, true);
    try testing.expectEqual(@as(u32, 3), e.session.turns);
    try testing.expect(!e.dirty);
}

test "unit: vault: unterminated tail is consumed at eof only when complete JSON" {
    var idx = index.Index.init(testing.allocator);
    defer idx.deinit();
    const whole = "{\"type\":\"user\",\"sessionId\":\"t\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}";
    var e = try idx.ingest("/p/t.jsonl", "claude", .{ .size = whole.len, .mtime_ms = 1 }, 0, whole, true);
    try testing.expectEqual(@as(u64, whole.len), e.consumed);
    try testing.expectEqual(@as(u32, 1), e.session.turns);
    // Not at eof: the same bytes are left for later.
    e = try idx.ingest("/p/t2.jsonl", "claude", .{ .size = whole.len, .mtime_ms = 1 }, 0, whole, false);
    try testing.expectEqual(@as(u64, 0), e.consumed);
    // Half-written record at eof.
    e = try idx.ingest("/p/t3.jsonl", "claude", .{ .size = 10, .mtime_ms = 1 }, 0, whole[0..10], true);
    try testing.expectEqual(@as(u64, 0), e.consumed);
    try testing.expectEqual(@as(u32, 0), e.session.malformed_lines);
}

test "unit: vault: scan sweep removes vanished transcripts" {
    var idx = index.Index.init(testing.allocator);
    defer idx.deinit();
    _ = try ingestAll(&idx, "/a.jsonl", "claude", "", "2026-01-01T00:00:00Z");
    _ = try ingestAll(&idx, "/b.jsonl", "claude", "", "2026-01-01T00:00:00Z");
    _ = try ingestAll(&idx, "/c.jsonl", "codex", "", "2026-01-01T00:00:00Z");
    idx.beginScan();
    idx.markSeen("/a.jsonl");
    _ = try ingestAll(&idx, "/c.jsonl", "codex", "", "2026-01-02T00:00:00Z");
    try testing.expectEqual(@as(usize, 1), idx.endScan());
    try testing.expect(idx.get("/b.jsonl") == null);
    try testing.expect(idx.get("/a.jsonl") != null and idx.get("/c.jsonl") != null);
}

test "unit: vault: searchable text is capped on a code point boundary" {
    const gpa = testing.allocator;
    // One huge prompt made of 3-byte code points.
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    try line.appendSlice(gpa, "{\"type\":\"user\",\"sessionId\":\"big\",\"message\":{\"role\":\"user\",\"content\":\"");
    for (0..(index.max_text_bytes / 3 + 10)) |_| try line.appendSlice(gpa, "語");
    try line.appendSlice(gpa, "\"}}\n");
    var idx = index.Index.init(gpa);
    defer idx.deinit();
    const e = try idx.ingest("/p/big.jsonl", "claude", .{ .size = line.items.len, .mtime_ms = 1 }, 0, line.items, true);
    try testing.expect(e.session.text_truncated);
    try testing.expect(e.session.text.items.len <= index.max_text_bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(e.session.text.items));
    try testing.expect(e.session.title.len <= 200);
    try testing.expect(std.unicode.utf8ValidateSlice(e.session.title));
}

test "unit: vault: ISO 8601 and date parsing" {
    try testing.expectEqual(@as(i64, 0), index.parseIso8601Ms("1970-01-01T00:00:00Z").?);
    try testing.expectEqual(@as(i64, 1_789_000_000_123), index.parseIso8601Ms("2026-09-10T00:26:40.123Z").?);
    try testing.expectEqual(ms("2026-10-16T10:00:00Z"), index.parseIso8601Ms("2026-10-16T12:00:00+02:00").?);
    try testing.expectEqual(ms("2026-10-16T10:00:00Z"), index.parseIso8601Ms("2026-10-16T10:00:00.000000Z").?);
    try testing.expectEqual(ms("2026-10-16T10:00:00Z"), index.parseIso8601Ms("2026-10-16T10:00:00").?);
    for ([_][]const u8{ "", "2026-10-16", "2026-13-01T00:00:00Z", "2026-02-30T00:00:00Z", "2026-10-16T25:00:00Z", "2026-10-16T10:00:00.Z", "2026-10-16T10:00:00+0200", "2026-10-16T10:00:00Zjunk" }) |bad| {
        try testing.expect(index.parseIso8601Ms(bad) == null);
    }
    try testing.expectEqual(index.daysFromCivil(2024, 2, 29), index.parseDate("2024-02-29").?);
    try testing.expect(index.parseDate("2025-02-29") == null);
    try testing.expect(index.parseDate("2026-1-01") == null);
    for ([_]i64{ -800_000, -1, 0, 59, 20_000, 2_932_896 }) |d| {
        const c = index.civilFromDays(d);
        try testing.expectEqual(d, index.daysFromCivil(c.year, c.month, c.day));
    }
}

test "unit: vault: recency sections honor the local day" {
    const now = ms("2026-10-16T12:00:00Z");
    try testing.expectEqual(index.Section.today, index.sectionFor(ms("2026-10-16T00:00:00Z"), now, 0));
    try testing.expectEqual(index.Section.yesterday, index.sectionFor(ms("2026-10-15T23:59:59Z"), now, 0));
    // At UTC+2 that instant is already Oct 16 local.
    try testing.expectEqual(index.Section.today, index.sectionFor(ms("2026-10-15T23:00:00Z"), now, 120));
    try testing.expectEqual(index.Section.last_7_days, index.sectionFor(ms("2026-10-10T12:00:00Z"), now, 0));
    try testing.expectEqual(index.Section.last_30_days, index.sectionFor(ms("2026-10-09T12:00:00Z"), now, 0));
    try testing.expectEqual(index.Section.older, index.sectionFor(ms("2026-09-16T12:00:00Z"), now, 0));
    try testing.expectEqual(index.Section.today, index.sectionFor(ms("2027-01-01T00:00:00Z"), now, 0));
    try testing.expectEqualStrings("Last 7 days", index.Section.last_7_days.label());
}

test "unit: vault: out-of-range record timestamps are ignored, never overflow" {
    const bad =
        \\{"type":"user","sessionId":"t","timestamp":-9223372036854775807,"message":{"role":"user","content":"a"}}
        \\{"type":"user","sessionId":"t","timestamp":9223372036854775807,"message":{"role":"user","content":"b"}}
        \\{"type":"user","sessionId":"t","timestamp":253402300800000,"message":{"role":"user","content":"c"}}
        \\
    ;
    var idx = index.Index.init(testing.allocator);
    defer idx.deinit();
    const e = try idx.ingest("/p/t.jsonl", "claude", .{ .size = bad.len, .mtime_ms = 7 }, 0, bad, true);
    try testing.expectEqual(@as(u32, 3), e.session.turns);
    try testing.expectEqual(@as(i64, 0), e.session.created_ms);
    try testing.expectEqual(@as(i64, 0), e.session.last_record_ms);
    try testing.expectEqual(index.Section.older, index.sectionFor(e.session.modifiedMs(), ms("2026-10-16T12:00:00Z"), 840));
    // Epoch seconds and milliseconds inside the range are still accepted.
    const good =
        \\{"type":"user","sessionId":"u","timestamp":1789000000,"message":{"role":"user","content":"secs"}}
        \\{"type":"user","sessionId":"u","timestamp":1789000000123,"message":{"role":"user","content":"millis"}}
        \\
    ;
    const f = try idx.ingest("/p/u.jsonl", "claude", .{ .size = good.len, .mtime_ms = 7 }, 0, good, true);
    try testing.expectEqual(@as(i64, 1_789_000_000_000), f.session.created_ms);
    try testing.expectEqual(@as(i64, 1_789_000_000_123), f.session.last_record_ms);
    try testing.expectEqual(index.min_timestamp_ms, index.parseIso8601Ms("0000-01-01T00:00:00Z").?);
    try testing.expectEqual(index.max_timestamp_ms, index.parseIso8601Ms("9999-12-31T23:59:59.999Z").?);
}

test "unit: vault: path helpers handle both separators" {
    try testing.expectEqualStrings("wmux", index.basename("C:\\src\\wmux\\"));
    try testing.expectEqualStrings("wmux", index.basename("/home/dev/wmux"));
    try testing.expectEqualStrings("", index.basename(""));
    try testing.expectEqualStrings("abc", index.fileStem("/x/abc.jsonl"));
    try testing.expectEqualStrings(".hidden", index.fileStem(".hidden"));
    const slug = try index.claudeProjectSlug(testing.allocator, "C:\\src\\my repo.v2");
    defer testing.allocator.free(slug);
    try testing.expectEqualStrings("C--src-my-repo-v2", slug);
}

test "unit: vault: CLI text row format" {
    var idx = index.Index.init(testing.allocator);
    defer idx.deinit();
    const e = try ingestAll(&idx, "/p/" ++ claude_id ++ ".jsonl", "claude", claude_fixture, "2026-10-14T09:03:31Z");
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try index.writeTextRow(&w, &e.session);
    try testing.expectEqualStrings("claude\t" ++ claude_id ++ "\tinactive\t2026-10-14T09:03:31Z\tFix the socket error in ipc.zig\tC:\\src\\wmux\n", w.buffered());
}

test "unit: vault: format and agent name tables" {
    try testing.expectEqual(index.Format.claude_code, index.Format.forAgent("claude"));
    try testing.expectEqual(index.Format.codex, index.Format.forAgent("codex"));
    try testing.expectEqual(index.Format.pi, index.Format.forAgent("my-agent"));
    try testing.expectEqualStrings("Hermes Agent", index.builtinAgentName("hermes-agent").?);
    try testing.expect(index.builtinAgentName("my-agent") == null);
}

// ---------------------------------------------------------------------------
// query.zig

fn parseQ(src: []const u8) !query.Query {
    return query.parse(testing.allocator, src, .{});
}

test "unit: vault: query parser splits operators, phrases and terms" {
    var q = try parseQ("  agent:codex repo:wmux after:2026-10-01 \"socket error\" reconnect ws:\"/home/dev\" Agent:Claude");
    defer q.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), q.agents.items.len);
    try testing.expectEqualStrings("codex", q.agents.items[0]);
    try testing.expectEqualStrings("Claude", q.agents.items[1]);
    try testing.expectEqualStrings("wmux", q.repos.items[0]);
    try testing.expectEqualStrings("/home/dev", q.wss.items[0]);
    try testing.expectEqual(@as(usize, 2), q.terms.items.len);
    try testing.expectEqualStrings("socket error", q.terms.items[0]);
    try testing.expectEqualStrings("reconnect", q.terms.items[1]);
    try testing.expectEqual(ms("2026-10-01T00:00:00Z"), q.after_ms.?);
    try testing.expect(q.before_ms == null);
}

test "unit: vault: query parser edge cases" {
    {
        var q = try parseQ("");
        defer q.deinit(testing.allocator);
        try testing.expect(q.isEmpty());
    }
    {
        // Quoted operator value with spaces; unterminated phrase runs to end.
        var q = try parseQ("repo:\"my project\" \"half open");
        defer q.deinit(testing.allocator);
        try testing.expectEqualStrings("my project", q.repos.items[0]);
        try testing.expectEqualStrings("half open", q.terms.items[0]);
    }
    {
        // Unknown keys, empty values, URLs and empty phrases.
        var q = try parseQ("foo:bar agent: http://x.y \"\" :lead");
        defer q.deinit(testing.allocator);
        try testing.expect(q.agents.items.len == 0);
        try testing.expectEqual(@as(usize, 4), q.terms.items.len);
        try testing.expectEqualStrings("foo:bar", q.terms.items[0]);
        try testing.expectEqualStrings("agent:", q.terms.items[1]);
        try testing.expectEqualStrings("http://x.y", q.terms.items[2]);
        try testing.expectEqualStrings(":lead", q.terms.items[3]);
    }
    {
        // Bad dates are ignored; repeated bounds keep the tightest.
        var q = try parseQ("after:2026-1-1 before:yesterday after:2026-01-01 after:2026-03-01 before:2026-12-01 before:2026-06-01");
        defer q.deinit(testing.allocator);
        try testing.expectEqual(@as(u32, 2), q.invalid_dates);
        try testing.expectEqual(ms("2026-03-01T00:00:00Z"), q.after_ms.?);
        try testing.expectEqual(ms("2026-06-01T00:00:00Z"), q.before_ms.?);
        try testing.expect(q.terms.items.len == 0);
    }
    {
        // Local start of day at UTC+2 is 22:00 UTC the day before.
        var q = try query.parse(testing.allocator, "before:2026-10-16", .{ .tz_offset_min = 120 });
        defer q.deinit(testing.allocator);
        try testing.expectEqual(ms("2026-10-15T22:00:00Z"), q.before_ms.?);
    }
    {
        // Unicode phrase and a huge token.
        const gpa = testing.allocator;
        const long = try gpa.alloc(u8, 100_000);
        defer gpa.free(long);
        @memset(long, 'a');
        const src = try std.mem.concat(gpa, u8, &.{ "\"日本語 テスト\" ", long });
        defer gpa.free(src);
        var q = try query.parse(gpa, src, .{});
        defer q.deinit(gpa);
        try testing.expectEqualStrings("日本語 テスト", q.terms.items[0]);
        try testing.expectEqual(@as(usize, 100_000), q.terms.items[1].len);
    }
}

const Corpus = struct {
    idx: index.Index,
    list: []*const index.Session,

    fn init() !Corpus {
        var idx = index.Index.init(testing.allocator);
        errdefer idx.deinit();
        _ = try ingestAll(&idx, "/c/" ++ claude_id ++ ".jsonl", "claude", claude_fixture, "2026-10-14T09:03:31Z");
        _ = try ingestAll(&idx, "/x/" ++ codex_id ++ ".jsonl", "codex", codex_fixture, "2026-10-02T10:05:01Z");
        _ = try ingestAll(&idx, "/pi/a.jsonl", "pi", pi_fixture, "2026-09-20T08:00:05Z");
        // An older Codex session in another repo that also mentions the phrase.
        const other =
            \\{"timestamp":"2026-09-01T10:00:00Z","type":"session_meta","payload":{"id":"22222222-2222-4222-8222-222222222222","cwd":"/home/dev/other"}}
            \\{"timestamp":"2026-09-01T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"socket error again"}]}}
            \\
        ;
        _ = try ingestAll(&idx, "/x/old.jsonl", "codex", other, "2026-09-01T10:00:01Z");
        // A Codex session in wmux after Oct 1 without the phrase.
        const nophrase =
            \\{"timestamp":"2026-10-05T10:00:00Z","type":"session_meta","payload":{"id":"33333333-3333-4333-8333-333333333333","cwd":"/home/dev/wmux-two"}}
            \\{"timestamp":"2026-10-05T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"update docs"}]}}
            \\
        ;
        _ = try ingestAll(&idx, "/x/nophrase.jsonl", "codex", nophrase, "2026-10-05T10:00:01Z");
        return .{ .idx = idx, .list = try idx.sessions(testing.allocator) };
    }

    fn deinit(self: *Corpus) void {
        testing.allocator.free(self.list);
        self.idx.deinit();
    }

    fn ids(self: *Corpus, src: []const u8, limit: usize) ![]const u8 {
        var q = try parseQ(src);
        defer q.deinit(testing.allocator);
        var r = try query.search(testing.allocator, self.list, &q, limit);
        defer r.deinit(testing.allocator);
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        for (r.hits) |s| try out.writer.print("{s} ", .{s.id[0..8]});
        @memcpy(scratch[0..out.written().len], out.written());
        return scratch[0..out.written().len];
    }
    var scratch: [256]u8 = undefined;
};

test "unit: vault: acceptance query returns only the matching codex session" {
    var c = try Corpus.init();
    defer c.deinit();
    try testing.expectEqualStrings("0199a1b2 ", try c.ids("agent:codex repo:wmux after:2026-10-01 \"socket error\"", 0));
}

test "unit: vault: free text ANDs across fields and ranks by recency" {
    var c = try Corpus.init();
    defer c.deinit();
    // Phrase in transcripts of three sessions, newest first.
    try testing.expectEqualStrings("7f1c2a3b 0199a1b2 22222222 ", try c.ids("\"SOCKET ERROR\"", 0));
    // AND: both terms required.
    try testing.expectEqualStrings("0199a1b2 ", try c.ids("socket reconnect", 0));
    // Branch, agent name and cwd are searchable metadata.
    try testing.expectEqualStrings("0199a1b2 ", try c.ids("feat/socket", 0));
    try testing.expectEqualStrings("5a6b7c8d ", try c.ids("pi notes", 0));
    try testing.expectEqualStrings("7f1c2a3b ", try c.ids("\"claude code\" ipc", 0));
    // Multiple agent: operators OR together.
    try testing.expectEqualStrings("7f1c2a3b 5a6b7c8d ", try c.ids("agent:claude agent:pi", 0));
    // Empty query lists everything newest first; limit trims.
    try testing.expectEqualStrings("7f1c2a3b 33333333 0199a1b2 ", try c.ids("", 3));
    try testing.expectEqualStrings("", try c.ids("nothing-matches-this", 0));
}

test "unit: vault: repo, ws and date operators" {
    var c = try Corpus.init();
    defer c.deinit();
    // repo: is a substring of the cwd basename (case-insensitive), not the path.
    try testing.expectEqualStrings("33333333 0199a1b2 ", try c.ids("repo:WMUX agent:codex", 0));
    try testing.expectEqualStrings("", try c.ids("repo:dev", 0));
    try testing.expectEqualStrings("5a6b7c8d ", try c.ids("repo:\"notes app\"", 0));
    // ws: is a substring of the full cwd, backslashes included.
    try testing.expectEqualStrings("7f1c2a3b ", try c.ids("ws:\"src\\wmux\"", 0));
    // before: is exclusive at the start of the day, after: inclusive.
    try testing.expectEqualStrings("5a6b7c8d 22222222 ", try c.ids("before:2026-10-02", 0));
    try testing.expectEqualStrings("0199a1b2 ", try c.ids("after:2026-10-02 before:2026-10-03", 0));
    try testing.expectEqualStrings("", try c.ids("after:2026-10-03 before:2026-10-03", 0));
}

test "unit: vault: partial flag when unsearchable sessions could have matched" {
    var idx = index.Index.init(testing.allocator);
    defer idx.deinit();
    const e = try ingestAll(&idx, "/p/a.jsonl", "claude", "garbage\n", "2026-01-01T00:00:00Z");
    try testing.expect(e.session.partiallySearchable());
    const list = try idx.sessions(testing.allocator);
    defer testing.allocator.free(list);
    {
        var q = try parseQ("needle");
        defer q.deinit(testing.allocator);
        var r = try query.search(testing.allocator, list, &q, 0);
        defer r.deinit(testing.allocator);
        try testing.expect(r.partial);
        try testing.expectEqual(@as(usize, 0), r.total);
    }
    {
        // Excluded by metadata: not counted as unsearched.
        var q = try parseQ("agent:codex needle");
        defer q.deinit(testing.allocator);
        var r = try query.search(testing.allocator, list, &q, 0);
        defer r.deinit(testing.allocator);
        try testing.expect(!r.partial);
    }
}

test "unit: vault: sessions listing filters by agent and folder" {
    var c = try Corpus.init();
    defer c.deinit();
    const by_agent = try query.listSessions(testing.allocator, c.list, .{ .agent = "codex", .limit = 2 });
    defer testing.allocator.free(by_agent);
    try testing.expectEqual(@as(usize, 2), by_agent.len);
    try testing.expectEqualStrings("33333333-3333-4333-8333-333333333333", by_agent[0].id);
    const by_folder = try query.listSessions(testing.allocator, c.list, .{ .folder = "/home/dev/wmux/" });
    defer testing.allocator.free(by_folder);
    try testing.expectEqual(@as(usize, 1), by_folder.len);
    try testing.expectEqualStrings(codex_id, by_folder[0].id);
    const win = try query.listSessions(testing.allocator, c.list, .{ .folder = "c:/SRC" });
    defer testing.allocator.free(win);
    try testing.expectEqual(@as(usize, 1), win.len);
    try testing.expect(query.inFolder("/home/dev/wmux/sub", "/home/dev/wmux"));
    try testing.expect(!query.inFolder("/home/dev/wmux-two", "/home/dev/wmux"));
    try testing.expect(query.inFolder("C:\\anything", "C:\\"));
    try testing.expect(query.inFolder("/x", "/"));
    try testing.expect(query.inFolder("/x", ""));
}

// ---------------------------------------------------------------------------
// checkpoints.zig

test "unit: vault: turns are derived from user prompts only" {
    var t = try checkpoints.deriveTurns(testing.allocator, .claude_code, claude_fixture);
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), t.marks.len);
    try testing.expectEqual(@as(u64, claude_fixture.len), t.complete_len);
    for (t.marks, 0..) |m, i| {
        try testing.expectEqual(@as(u32, @intCast(i + 1)), m.turn);
        try testing.expect(m.start < m.end);
        try testing.expect(m.end == claude_fixture.len or claude_fixture[m.end - 1] == '\n');
    }
    try testing.expectEqual(t.marks[1].start, t.marks[0].end);
    try testing.expectEqual(@as(u32, 0), checkpoints.turnsBefore(&t, t.marks[0].start));
    try testing.expectEqual(@as(u32, 2), checkpoints.turnsBefore(&t, t.marks[1].end));

    var empty = try checkpoints.deriveTurns(testing.allocator, .codex, "");
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), empty.marks.len);
}

test "unit: vault: timeline merges turns and manual checkpoints in order" {
    const gpa = testing.allocator;
    var store = checkpoints.Store.init(gpa);
    defer store.deinit();
    var mid = try checkpoints.captureManual(gpa, .claude_code, claude_fixture[0..std.mem.indexOf(u8, claude_fixture, "{\"type\":\"user\",\"sessionId\":\"7f1c2a3b-4d5e-4f60-8a71-92b3c4d5e6f7\",\"timestamp\":\"2026-10-14T09:03").?], .{
        .id = "cp-a",
        .name = "  before commit\n",
        .git_head = "0123456789abcdef0123456789abcdef01234567\n",
        .now_ms = 5,
    });
    defer mid.deinit(gpa);
    try testing.expectEqualStrings("before commit", mid.name);
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", mid.git_head);
    try testing.expectEqual(@as(u32, 2), mid.turn);
    try store.add("claude", claude_id, &mid);
    try testing.expectError(error.DuplicateCheckpoint, store.add("claude", claude_id, &mid));

    var tip = try checkpoints.captureManual(gpa, .claude_code, claude_fixture, .{ .id = "cp-b", .now_ms = 6 });
    defer tip.deinit(gpa);
    try store.add("claude", claude_id, &tip);
    // Another session's checkpoint stays out of this timeline.
    try store.add("claude", "someone-else", &tip);

    const manual = try store.manualFor(gpa, "claude", claude_id);
    defer gpa.free(manual);
    try testing.expectEqual(@as(usize, 2), manual.len);
    var tl = try checkpoints.timeline(gpa, .claude_code, claude_fixture, manual);
    defer tl.deinit(gpa);
    try testing.expectEqual(@as(u32, 3), tl.turn_count);
    const order = [_][]const u8{ "turn-1", "turn-2", "cp-a", "turn-3", "cp-b" };
    try testing.expectEqual(order.len, tl.items.len);
    for (order, tl.items) |id, cp| try testing.expectEqualStrings(id, cp.id);
    try testing.expectEqualStrings("Turn 2", tl.findTurn(2).?.name);
    try testing.expect(tl.find("cp-b") != null and tl.find("nope") == null);

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tl.find("cp-b").?.writeLabel(&w);
    try testing.expectEqualStrings("Checkpoint (Turn 3)", w.buffered());

    try testing.expect(store.remove("claude", claude_id, "cp-a"));
    try testing.expect(!store.remove("claude", claude_id, "cp-a"));
}

test "unit: vault: manual checkpoint preconditions" {
    const gpa = testing.allocator;
    try testing.expectError(error.TranscriptIncomplete, checkpoints.captureManual(gpa, .claude_code, claude_fixture, .{ .id = "x", .now_ms = 0, .complete = false }));
    try testing.expectError(error.TranscriptTooLarge, checkpoints.captureManual(gpa, .claude_code, claude_fixture, .{ .id = "x", .now_ms = 0, .max_bytes = 10 }));
    for ([_][]const u8{ "", "turn-1", "has space", "tab\t", "é" }) |bad| {
        try testing.expectError(error.InvalidCheckpointId, checkpoints.captureManual(gpa, .claude_code, claude_fixture, .{ .id = bad, .now_ms = 0 }));
    }
    // A half-written last line is not part of the checkpoint.
    const partial = claude_fixture ++ "{\"type\":\"user\",\"mess";
    var cp = try checkpoints.captureManual(gpa, .claude_code, partial, .{ .id = "x", .now_ms = 0 });
    defer cp.deinit(gpa);
    try testing.expectEqual(@as(u64, claude_fixture.len), cp.byte_offset);
    try testing.expectEqual(checkpoints.digestOf(claude_fixture), cp.sha256);
}

test "unit: vault: store JSON round trip and tolerant load" {
    const gpa = testing.allocator;
    var store = checkpoints.Store.init(gpa);
    defer store.deinit();
    var cp = try checkpoints.captureManual(gpa, .codex, codex_fixture, .{ .id = "cp-1", .name = "naïve \"quote\"", .git_head = "abc", .now_ms = 42 });
    defer cp.deinit(gpa);
    try store.add("codex", codex_id, &cp);
    try store.recordFork("codex", "99999999-9999-4999-8999-999999999999", codex_id, "cp-1", 43);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try store.write(&aw.writer);

    var back = try checkpoints.Store.load(gpa, aw.written());
    defer back.deinit();
    const m = try back.manualFor(gpa, "codex", codex_id);
    defer gpa.free(m);
    try testing.expectEqual(@as(usize, 1), m.len);
    try testing.expectEqualStrings("naïve \"quote\"", m[0].name);
    try testing.expectEqualStrings("abc", m[0].git_head);
    try testing.expectEqual(cp.sha256, m[0].sha256);
    try testing.expectEqual(cp.byte_offset, m[0].byte_offset);
    try testing.expectEqual(@as(i64, 42), m[0].created_ms);
    try testing.expect(back.isFork("codex", "99999999-9999-4999-8999-999999999999"));
    try testing.expect(!back.isFork("codex", codex_id));

    // Bad records are dropped, unknown fields ignored.
    const messy =
        \\{"version":1,"extra":true,"checkpoints":[
        \\ {"agent":"claude","session_id":"s","id":"ok","byte_offset":3,"sha256":"ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789","future":1},
        \\ {"agent":"claude","session_id":"s","id":"turn-9","byte_offset":3,"sha256":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"},
        \\ {"agent":"claude","session_id":"s","id":"short","byte_offset":3,"sha256":"abc"},
        \\ {"agent":"claude","session_id":"s","id":"nothex","byte_offset":3,"sha256":"zzcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"},
        \\ {"agent":"claude","session_id":"s","id":"ok","byte_offset":4,"sha256":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"}
        \\]}
    ;
    var s2 = try checkpoints.Store.load(gpa, messy);
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 1), s2.records.items.len);
    try testing.expectEqual(@as(u8, 'a'), s2.records.items[0].cp.sha256[0]);

    try testing.expectError(error.InvalidStore, checkpoints.Store.load(gpa, ""));
    try testing.expectError(error.InvalidStore, checkpoints.Store.load(gpa, "[]"));
    try testing.expectError(error.InvalidStore, checkpoints.Store.load(gpa, "{\"checkpoints\":[]}"));
    try testing.expectError(error.UnsupportedVersion, checkpoints.Store.load(gpa, "{\"version\":2}"));
    var empty = try checkpoints.Store.load(gpa, "{\"version\":1}");
    empty.deinit();
}

test "unit: vault: fork a claude session at turn 2 keeps only turns 1-2 with a new id" {
    const gpa = testing.allocator;
    var tl = try checkpoints.timeline(gpa, .claude_code, claude_fixture, &.{});
    defer tl.deinit(gpa);
    const new_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    const out = try checkpoints.fork(gpa, "claude", claude_fixture, tl.findTurn(2).?, .{ .new_session_id = new_id });
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, claude_id) == null);
    try testing.expect(std.mem.indexOf(u8, out, "Now add a test") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Third: commit") == null);
    // Lines without a session id (the summary) are byte-identical.
    try testing.expect(std.mem.startsWith(u8, out, "{\"type\":\"summary\",\"summary\":\"Fix socket\",\"leafUuid\":\"u9\"}\n"));
    try testing.expect(out[out.len - 1] == '\n');

    // The fork re-indexes as a 2-turn session under the new id.
    var idx = index.Index.init(gpa);
    defer idx.deinit();
    const e = try idx.ingest("/p/" ++ new_id ++ ".jsonl", "claude", .{ .size = out.len, .mtime_ms = 1 }, 0, out, true);
    try testing.expectEqualStrings(new_id, e.session.id);
    try testing.expectEqual(@as(u32, 2), e.session.turns);
    try testing.expectEqualStrings("Fix the socket error in ipc.zig", e.session.title);
    try testing.expectEqualStrings("C:\\src\\wmux", e.session.cwd);

    // Fork at the last turn: numbers keep their spelling (1.50 stays 1.50).
    const full = try checkpoints.fork(gpa, "claude", claude_fixture, tl.findTurn(3).?, .{ .new_session_id = new_id });
    defer gpa.free(full);
    try testing.expect(std.mem.indexOf(u8, full, "\"costUSD\":1.50") != null);
    try testing.expectEqual(claude_fixture.len, full.len);
}

test "unit: vault: fork codex and pi rewrites their header ids" {
    const gpa = testing.allocator;
    const new_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    {
        var tl = try checkpoints.timeline(gpa, .codex, codex_fixture, &.{});
        defer tl.deinit(gpa);
        const out = try checkpoints.fork(gpa, "codex", codex_fixture, tl.findTurn(1).?, .{ .new_session_id = new_id });
        defer gpa.free(out);
        try testing.expect(std.mem.indexOf(u8, out, codex_id) == null);
        try testing.expect(std.mem.indexOf(u8, out, "\"id\":\"" ++ new_id ++ "\"") != null);
        try testing.expect(std.mem.indexOf(u8, out, "Fix it") == null);
        var idx = index.Index.init(gpa);
        defer idx.deinit();
        const e = try idx.ingest("/f.jsonl", "codex", .{ .size = out.len, .mtime_ms = 1 }, 0, out, true);
        try testing.expectEqualStrings(new_id, e.session.id);
        try testing.expectEqualStrings("feat/socket", e.session.branch);
    }
    {
        var tl = try checkpoints.timeline(gpa, .pi, pi_fixture, &.{});
        defer tl.deinit(gpa);
        const out = try checkpoints.fork(gpa, "pi", pi_fixture, tl.findTurn(1).?, .{ .new_session_id = new_id });
        defer gpa.free(out);
        try testing.expect(std.mem.startsWith(u8, out, "{\"type\":\"session\",\"id\":\"" ++ new_id ++ "\""));
    }
}

test "unit: vault: fork error cases" {
    const gpa = testing.allocator;
    const new_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    var tl = try checkpoints.timeline(gpa, .claude_code, claude_fixture, &.{});
    defer tl.deinit(gpa);
    const t1 = tl.findTurn(1).?;
    try testing.expectError(error.ForkUnsupported, checkpoints.fork(gpa, "opencode", claude_fixture, t1, .{ .new_session_id = new_id }));
    try testing.expectError(error.InvalidSessionId, checkpoints.fork(gpa, "claude", claude_fixture, t1, .{ .new_session_id = "not-a-uuid" }));
    try testing.expectError(error.InvalidSessionId, checkpoints.fork(gpa, "claude", claude_fixture, t1, .{ .new_session_id = "" }));
    try testing.expectError(error.TranscriptTooLarge, checkpoints.fork(gpa, "claude", claude_fixture, t1, .{ .new_session_id = new_id, .max_bytes = 100 }));
    // Transcript edited before the checkpoint / truncated below it.
    var edited = claude_fixture.*;
    edited[70] ^= 1;
    try testing.expectError(error.CheckpointMismatch, checkpoints.fork(gpa, "claude", &edited, t1, .{ .new_session_id = new_id }));
    try testing.expectError(error.CheckpointMismatch, checkpoints.fork(gpa, "claude", claude_fixture[0..10], t1, .{ .new_session_id = new_id }));
    // Appending after the checkpoint is fine.
    const grown = try checkpoints.fork(gpa, "claude", claude_fixture ++ "{\"type\":\"user\"}\n", t1, .{ .new_session_id = new_id });
    gpa.free(grown);
    // A checkpoint whose prefix holds no prompt.
    const only_summary = "{\"type\":\"summary\",\"summary\":\"s\"}\n";
    var none = try checkpoints.captureManual(gpa, .claude_code, only_summary, .{ .id = "x", .now_ms = 0 });
    defer none.deinit(gpa);
    try testing.expectError(error.NothingBeforeCheckpoint, checkpoints.fork(gpa, "claude", only_summary, &none, .{ .new_session_id = new_id }));
    var zero = try checkpoints.captureManual(gpa, .claude_code, "", .{ .id = "x", .now_ms = 0 });
    defer zero.deinit(gpa);
    try testing.expectError(error.NothingBeforeCheckpoint, checkpoints.fork(gpa, "claude", "", &zero, .{ .new_session_id = new_id }));
    try testing.expectEqualStrings("Fork from checkpoint isn't available for this agent yet", checkpoints.errorMessage(error.ForkUnsupported));
    try testing.expect(checkpoints.forkSupported("grok") and !checkpoints.forkSupported("amp"));
}

/// A Claude assistant record (no newline) whose nesting depth, counting the
/// record object itself, is `depth`.
fn nestedRecord(gpa: std.mem.Allocator, depth: usize) ![]u8 {
    var t: std.ArrayList(u8) = .empty;
    errdefer t.deinit(gpa);
    try t.appendSlice(gpa, "{\"type\":\"assistant\",\"sessionId\":\"" ++ claude_id ++ "\",\"x\":");
    try t.appendNTimes(gpa, '[', depth - 1);
    try t.appendNTimes(gpa, ']', depth - 1);
    try t.append(gpa, '}');
    return t.toOwnedSlice(gpa);
}

test "unit: vault: records nested too deeply are malformed and fork copies them verbatim" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The limit itself is fine and one more level is malformed; brackets
    // inside strings (even after an escaped quote) do not count.
    const at_limit = try nestedRecord(arena, index.max_json_depth);
    try testing.expectEqual(index.LineKind.assistant, (try index.classifyLine(arena, .claude_code, at_limit)).kind);
    const past_limit = try nestedRecord(arena, index.max_json_depth + 1);
    try testing.expectEqual(index.LineKind.malformed, (try index.classifyLine(arena, .claude_code, past_limit)).kind);
    const in_string = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"\\\"" ++ ("[{" ** 200) ++ "\"}}";
    try testing.expectEqual(index.LineKind.user_prompt, (try index.classifyLine(arena, .claude_code, in_string)).kind);

    // A record deeper than std.json.Stringify's checked nesting (256 levels).
    const deep_line = try std.mem.concat(arena, u8, &.{ try nestedRecord(arena, 300), "\n" });
    const transcript = try std.mem.concat(arena, u8, &.{ claude_fixture, deep_line });
    var idx = index.Index.init(gpa);
    defer idx.deinit();
    const e = try idx.ingest("/p/" ++ claude_id ++ ".jsonl", "claude", .{ .size = transcript.len, .mtime_ms = 1 }, 0, transcript, true);
    try testing.expectEqual(@as(u32, 1), e.session.malformed_lines);
    try testing.expectEqual(@as(u32, 3), e.session.turns);
    var cp = try checkpoints.captureManual(gpa, .claude_code, transcript, .{ .id = "deep", .now_ms = 0 });
    defer cp.deinit(gpa);
    try testing.expectEqual(@as(u64, transcript.len), cp.byte_offset);
    const new_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    const out = try checkpoints.fork(gpa, "claude", transcript, &cp, .{ .new_session_id = new_id });
    defer gpa.free(out);
    try testing.expect(std.mem.endsWith(u8, out, deep_line));
    const f = try idx.ingest("/p/" ++ new_id ++ ".jsonl", "claude", .{ .size = out.len, .mtime_ms = 1 }, 0, out, true);
    try testing.expectEqualStrings(new_id, f.session.id);
    try testing.expectEqual(@as(u32, 3), f.session.turns);
}

test "unit: vault: fork file names follow each agent's layout" {
    const gpa = testing.allocator;
    const id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    const now = ms("2026-10-16T07:08:09Z");
    const c = try checkpoints.forkFileName(gpa, .claude_code, id, now);
    defer gpa.free(c);
    try testing.expectEqualStrings(id ++ ".jsonl", c);
    const x = try checkpoints.forkFileName(gpa, .codex, id, now);
    defer gpa.free(x);
    try testing.expectEqualStrings("rollout-2026-10-16T07-08-09-" ++ id ++ ".jsonl", x);
    const d = try checkpoints.codexDayDir(gpa, now);
    defer gpa.free(d);
    try testing.expectEqualStrings("2026/10/16", d);
}

test "unit: vault: allocation failures never leak" {
    const S = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var idx = index.Index.init(gpa);
            defer idx.deinit();
            _ = try idx.ingest("/p/" ++ claude_id ++ ".jsonl", "claude", .{ .size = claude_fixture.len, .mtime_ms = 1 }, 0, claude_fixture, true);
            const list = try idx.sessions(gpa);
            defer gpa.free(list);
            var q = try query.parse(gpa, "agent:claude repo:wmux \"socket error\" x:y", .{});
            defer q.deinit(gpa);
            var r = try query.search(gpa, list, &q, 0);
            defer r.deinit(gpa);
            var store = checkpoints.Store.init(gpa);
            defer store.deinit();
            var cp = try checkpoints.captureManual(gpa, .claude_code, claude_fixture, .{ .id = "cp", .name = "n", .now_ms = 1 });
            defer cp.deinit(gpa);
            try store.add("claude", claude_id, &cp);
            const manual = try store.manualFor(gpa, "claude", claude_id);
            defer gpa.free(manual);
            var tl = try checkpoints.timeline(gpa, .claude_code, claude_fixture, manual);
            defer tl.deinit(gpa);
            const out = try checkpoints.fork(gpa, "claude", claude_fixture, tl.findTurn(2).?, .{ .new_session_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" });
            gpa.free(out);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, S.run, .{});
}
