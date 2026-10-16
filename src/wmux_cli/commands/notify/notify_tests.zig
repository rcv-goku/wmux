//! Tests of the `notify` family against the fake control pipe: argument
//! validation (cmux messages and exit codes), request params, text output
//! and goldens.

const std = @import("std");
const testing = std.testing;
const kit = @import("testkit.zig");
const fake = kit.fake;
const Harness = kit.Harness;
const notify = @import("../notify.zig");
const common = @import("common.zig");

const ws_uuid = "11111111-1111-4111-8111-111111111111";
const sf_uuid = "22222222-2222-4222-8222-222222222222";
const nid = "33333333-3333-4333-8333-333333333333";

fn notifyHandler(server: *fake.Server, req: fake.Request) fake.Action {
    const m = req.method;
    if (std.mem.startsWith(u8, m, "notification.create")) return .{ .ok = "{\"id\":\"" ++ nid ++ "\",\"workspace_id\":\"" ++ ws_uuid ++ "\",\"workspace_ref\":\"workspace:1\",\"surface_id\":\"" ++ sf_uuid ++ "\",\"surface_ref\":\"surface:2\"}" };
    if (std.mem.eql(u8, m, "notification.open") or std.mem.eql(u8, m, "notification.jump_to_unread") or std.mem.eql(u8, m, "surface.jump_to_last_prompt")) {
        if (server.user != null) return .{ .ok = "{\"opened\":false}" };
        return .{ .ok = "{\"opened\":true,\"is_read\":true,\"id\":\"" ++ nid ++ "\",\"workspace_id\":\"" ++ ws_uuid ++ "\",\"workspace_ref\":\"workspace:1\",\"surface_id\":\"" ++ sf_uuid ++ "\",\"surface_ref\":\"surface:2\"}" };
    }
    if (std.mem.eql(u8, m, "notification.list")) {
        if (server.user != null) return .{ .ok = "{\"notifications\":[]}" };
        return .{ .ok = list_result };
    }
    if (std.mem.eql(u8, m, "notification.dismiss")) {
        if (req.params.object.get("id")) |id| if (std.mem.eql(u8, id.string, "44444444-4444-4444-8444-444444444444"))
            return .{ .err = "{\"code\":\"not_found\",\"message\":\"Notification not found\"}" };
        return .{ .ok = "{\"dismissed\":1}" };
    }
    return .{ .ok = "{}" };
}

const list_result = "{\"notifications\":[{\"id\":\"33333333-3333-4333-8333-333333333333\",\"workspace_id\":\"11111111-1111-4111-8111-111111111111\",\"workspace_ref\":\"workspace:1\",\"surface_id\":\"22222222-2222-4222-8222-222222222222\",\"surface_ref\":\"surface:2\",\"title\":\"Done\",\"subtitle\":\"\",\"body\":\"All tests passed | 42\",\"created_at\":\"2026-10-16T08:00:00Z\",\"tab_title\":\"api\",\"is_read\":false},{\"id\":\"55555555-5555-4555-8555-555555555555\",\"workspace_id\":\"11111111-1111-4111-8111-111111111111\",\"surface_id\":null,\"title\":\"H\\u00e9llo \\ud83d\\ude00\",\"subtitle\":\"sub\",\"body\":\"line1\\nline2\",\"created_at\":1760601600,\"tab_title\":null,\"is_read\":true}]}";

fn params(h: *Harness) []const u8 {
    return h.last().params_json;
}

test "unit: cli-notify: notify defaults to the caller and prints the notification handle" {
    var h: Harness = undefined;
    try h.init(notifyHandler);
    defer h.deinit();
    h.setEnv("CMUX_WORKSPACE_ID", ws_uuid);
    h.setEnv("CMUX_SURFACE_ID", sf_uuid);
    const r = h.run(&.{ "cmux", "notify", "--title", "Done", "--body", "All tests passed" });
    try kit.expectResult(r, 0, "OK notification:" ++ nid ++ "\n", "");
    try testing.expectEqualStrings("notification.create_for_caller", h.last().method);
    try testing.expectEqualStrings("{\"caller\":{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"surface_id\":\"" ++ sf_uuid ++ "\"},\"preferred_workspace_id\":\"" ++ ws_uuid ++ "\",\"preferred_surface_id\":\"" ++ sf_uuid ++ "\",\"title\":\"Done\",\"subtitle\":\"\",\"body\":\"All tests passed\"}", params(&h));
    // --id-format variants.
    try kit.expectResult(h.run(&.{ "cmux", "notify", "--id-format", "uuids" }), 0, "OK " ++ nid ++ "\n", "");
    try kit.expectResult(h.run(&.{ "cmux", "notify", "--id-format=both" }), 0, "OK notification:" ++ nid ++ " (" ++ nid ++ ")\n", "");
    try testing.expectEqualStrings("Notification", h.last().params.object.get("title").?.string);
}

test "unit: cli-notify: notify equals forms, reply, desktop effect and legacy aliases" {
    var h: Harness = undefined;
    try h.init(notifyHandler);
    defer h.deinit();
    const r = h.run(&.{ "cmux", "notify", "--title=X", "--subtitle=s", "--reply", "--desktop", "no", "--" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("{\"caller\":{},\"title\":\"X\",\"subtitle\":\"s\",\"body\":\"\",\"reply_shape\":\"text\",\"effects\":{\"desktop\":false}}", params(&h));
    _ = h.run(&.{ "cmux", "notify", "--desktop=TRUE" });
    try testing.expectEqual(true, h.last().params.object.get("effects").?.object.get("desktop").?.bool);
    // --tab/--panel are --workspace/--surface; a ref/index resolves inside the workspace.
    _ = h.run(&.{ "cmux", "notify", "--tab", "workspace:2", "--panel", "1" });
    try testing.expectEqualStrings("notification.create_for_target", h.last().method);
    try testing.expectEqualStrings("{\"workspace_id\":\"workspace:2\",\"surface_id\":\"1\",\"title\":\"Notification\",\"subtitle\":\"\",\"body\":\"\"}", params(&h));
}

test "unit: cli-notify: notify target resolution" {
    var h: Harness = undefined;
    try h.init(notifyHandler);
    defer h.deinit();
    // An explicit surface UUID resolves globally.
    _ = h.run(&.{ "cmux", "notify", "--surface", sf_uuid, "--workspace", "workspace:9" });
    try testing.expectEqualStrings("notification.create", h.last().method);
    try testing.expectEqualStrings(sf_uuid, h.last().params.object.get("surface_id").?.string);
    try testing.expect(h.last().params.object.get("workspace_id") == null);
    // A surface ref without context is global too.
    _ = h.run(&.{ "cmux", "notify", "--surface", "surface:4" });
    try testing.expectEqualStrings("notification.create", h.last().method);
    // An index needs context.
    const no_ctx = h.run(&.{ "cmux", "notify", "--surface", "3" });
    try kit.expectResult(no_ctx, 2, "", "cmux: notify --surface requires workspace or window context; specify --workspace or --window\n");
    // --window without --surface: that window's workspace.
    _ = h.run(&.{ "cmux", "notify", "--window", "window:1" });
    try testing.expectEqualStrings("notification.create_for_target", h.last().method);
    try testing.expectEqualStrings("{\"window_id\":\"window:1\",\"title\":\"Notification\",\"subtitle\":\"\",\"body\":\"\"}", params(&h));
    // The global --window counts as window context.
    _ = h.run(&.{ "cmux", "--window", "2", "notify", "--surface", "0" });
    try testing.expectEqualStrings("{\"window_id\":\"2\",\"surface_id\":\"0\",\"title\":\"Notification\",\"subtitle\":\"\",\"body\":\"\"}", params(&h));
    // The env workspace is context for an index.
    h.setEnv("CMUX_WORKSPACE_ID", ws_uuid);
    _ = h.run(&.{ "cmux", "notify", "--surface", "3" });
    try testing.expectEqualStrings("{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"surface_id\":\"3\",\"title\":\"Notification\",\"subtitle\":\"\",\"body\":\"\"}", params(&h));
    // An explicit other workspace drops the env surface preference.
    h.setEnv("CMUX_SURFACE_ID", sf_uuid);
    _ = h.run(&.{ "cmux", "notify", "--workspace", "workspace:3" });
    try testing.expectEqualStrings("notification.create_for_caller", h.last().method);
    try testing.expectEqualStrings("workspace:3", h.last().params.object.get("preferred_workspace_id").?.string);
    try testing.expect(h.last().params.object.get("preferred_surface_id") == null);
    // Inside tmux the caller's TTY is preferred.
    h.setEnv("TMUX", "/tmp/tmux-1000/default,1,0");
    _ = h.run(&.{ "cmux", "notify" });
    try testing.expectEqual(true, h.last().params.object.get("prefer_tty").?.bool);
}

test "unit: cli-notify: notify strict argument validation" {
    var h: Harness = undefined;
    try h.init(notifyHandler);
    defer h.deinit();
    const cases = [_]struct { []const []const u8, []const u8 }{
        .{ &.{ "notify", "--bogus" }, "cmux: notify: unexpected arguments: --bogus\n" },
        .{ &.{ "notify", "hello", "world" }, "cmux: notify: unexpected arguments: hello world\n" },
        .{ &.{ "notify", "--reply=yes" }, "cmux: notify: unexpected arguments: --reply=yes\n" },
        .{ &.{ "notify", "--clear=1" }, "cmux: notify: unexpected arguments: --clear=1\n" },
        .{ &.{ "notify", "--", "--title", "x" }, "cmux: notify: unexpected arguments: --\n" },
        .{ &.{ "notify", "--title=" }, "cmux: notify: --title requires a value\n" },
        .{ &.{ "notify", "--title", "--body", "x" }, "cmux: notify: --title requires a value\n" },
        .{ &.{ "notify", "--body" }, "cmux: notify: --body requires a value\n" },
        .{ &.{ "notify", "--desktop", "maybe" }, "cmux: --desktop must be true|false\n" },
        .{ &.{ "notify", "--surface", "pane:1" }, "cmux: Invalid surface handle: pane:1 (expected UUID, ref like surface:1, or index)\n" },
        .{ &.{ "notify", "--workspace", "nope" }, "cmux: Invalid workspace handle: nope (expected UUID, ref like workspace:1, or index)\n" },
        .{ &.{ "notify", "--surface", " " }, "cmux: Surface handle is blank\n" },
        .{ &.{ "notify", "--workspace", "" }, "cmux: No workspace selected: --workspace was blank and CMUX_WORKSPACE_ID is unset\n" },
        .{ &.{ "notify", "--clear", "--surface", "surface:1" }, "cmux: " ++ notify.clear_surface_context_message ++ "\n" },
    };
    for (cases) |c| {
        const argv = try std.mem.concat(h.alloc(), []const u8, &.{ &.{"cmux"}, c[0] });
        try kit.expectResult(h.run(argv), 2, "", c[1]);
    }
    try testing.expectEqual(@as(usize, 0), h.requestCount());
}

test "unit: cli-notify: notify --clear scopes and ignores --desktop" {
    var h: Harness = undefined;
    try h.init(notifyHandler);
    defer h.deinit();
    h.setEnv("CMUX_WORKSPACE_ID", ws_uuid);
    try kit.expectResult(h.run(&.{ "cmux", "notify", "--clear", "--desktop", "maybe" }), 0, "OK\n", "");
    try testing.expectEqualStrings("notification.clear", h.last().method);
    try testing.expectEqualStrings("{\"caller\":{\"workspace_id\":\"" ++ ws_uuid ++ "\"}}", params(&h));
    _ = h.run(&.{ "cmux", "notify", "--clear", "--workspace", "workspace:2" });
    try testing.expectEqualStrings("{\"workspace_id\":\"workspace:2\"}", params(&h));
    _ = h.run(&.{ "cmux", "notify", "--clear", "--window", "window:1", "--surface", "surface:3" });
    try testing.expectEqualStrings("{\"window_id\":\"window:1\",\"surface_id\":\"surface:3\"}", params(&h));
    // Same resolution as create: the caller's workspace is context for a
    // surface (without it the strict-validation test expects the error).
    try kit.expectResult(h.run(&.{ "cmux", "notify", "--clear", "--surface", "surface:3" }), 0, "OK\n", "");
    try testing.expectEqualStrings("{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"surface_id\":\"surface:3\"}", params(&h));
    const j = h.run(&.{ "cmux", "notify", "--clear", "--json" });
    try testing.expectEqualStrings("{}\n", j.out);
}

test "unit: cli-notify: notify prints plain OK without an id and the result with --json" {
    var h: Harness = undefined;
    try h.init(kit.okHandler);
    defer h.deinit();
    try kit.expectResult(h.run(&.{ "cmux", "notify", "--title", "muted" }), 0, "OK\n", "");
    var h2: Harness = undefined;
    try h2.init(notifyHandler);
    defer h2.deinit();
    const j = h2.run(&.{ "cmux", "notify", "--json" });
    try kit.expectResult(j, 0, "{\n  \"id\": \"" ++ nid ++ "\",\n  \"workspace_ref\": \"workspace:1\",\n  \"surface_ref\": \"surface:2\"\n}\n", "");
}

test "unit: cli-notify: list-notifications text, empty and json" {
    var h: Harness = undefined;
    try h.init(notifyHandler);
    defer h.deinit();
    const r = h.run(&.{ "cmux", "list-notifications" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("notification.list", h.last().method);
    try kit.expectGolden(h.alloc(), "list-notifications.txt", r.out);
    const j = h.run(&.{ "cmux", "list-notifications", "--json" });
    try testing.expectEqual(@as(u8, 0), j.code);
    try kit.expectGolden(h.alloc(), "list-notifications-json.txt", j.out);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, h.alloc(), j.out, .{});
    try testing.expectEqual(@as(usize, 2), v.array.items.len);
    try testing.expect(v.array.items[1].object.get("surface_id").? == .null);
    try kit.expectResult(h.run(&.{ "cmux", "list-notifications", "--all" }), 2, "", "cmux: list-notifications: unexpected arguments: --all\n");
    h.server.user = &h;
    try kit.expectResult(h.run(&.{ "cmux", "list-notifications" }), 0, "No notifications\n", "");
    try kit.expectResult(h.run(&.{ "cmux", "list-notifications", "--json" }), 0, "[]\n", "");
}

test "unit: cli-notify: created_at formats" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try notify.writeCreatedAt(&aw.writer, .{ .integer = 0 });
    try notify.writeCreatedAt(&aw.writer, .{ .integer = 1_760_601_600_123 });
    try notify.writeCreatedAt(&aw.writer, .{ .float = 951_782_400.5 });
    try notify.writeCreatedAt(&aw.writer, .{ .integer = -5 });
    try notify.writeCreatedAt(&aw.writer, .{ .float = std.math.nan(f64) });
    try notify.writeCreatedAt(&aw.writer, .null);
    try notify.writeCreatedAt(&aw.writer, null);
    try testing.expectEqualStrings("1970-01-01T00:00:00Z2025-10-16T08:00:00Z2000-02-29T00:00:00Z1970-01-01T00:00:00Z", aw.written());
}

test "unit: cli-notify: notification ids accept the handle prefix in any case" {
    try testing.expect(notify.parseNotificationId(nid) != null);
    try testing.expect(notify.parseNotificationId("notification:" ++ nid) != null);
    try testing.expect(notify.parseNotificationId("NOTIFICATION:" ++ nid) != null);
    try testing.expect(notify.parseNotificationId(" Notification:{" ++ nid ++ "} ") != null);
    try testing.expect(notify.parseNotificationId("") == null);
    try testing.expect(notify.parseNotificationId("notification:") == null);
    try testing.expect(notify.parseNotificationId("workspace:1") == null);
    try testing.expect(notify.parseNotificationId("\u{1F600}") == null);
}

test "unit: cli-notify: dismiss-notification selectors" {
    var h: Harness = undefined;
    try h.init(notifyHandler);
    defer h.deinit();
    try kit.expectResult(h.run(&.{ "cmux", "dismiss-notification", "--id", "notification:" ++ nid }), 0, "OK\n", "");
    try testing.expectEqualStrings("notification.dismiss", h.last().method);
    try testing.expectEqualStrings("{\"id\":\"" ++ nid ++ "\"}", params(&h));
    _ = h.run(&.{ "cmux", "dismiss-notification", "--all-read" });
    try testing.expectEqualStrings("{\"all_read\":true}", params(&h));
    _ = h.run(&.{ "cmux", "dismiss-notification", "notification:" ++ nid });
    try testing.expectEqualStrings("{\"id\":\"" ++ nid ++ "\"}", params(&h));
    const n = h.requestCount();
    const req = "cmux: dismiss-notification requires exactly one of --id or --all-read\n";
    try kit.expectResult(h.run(&.{ "cmux", "dismiss-notification" }), 2, "", req);
    try kit.expectResult(h.run(&.{ "cmux", "dismiss-notification", "--id", nid, "--all-read" }), 2, "", req);
    try kit.expectResult(h.run(&.{ "cmux", "dismiss-notification", "--id", "bogus" }), 2, "", "cmux: dismiss-notification: invalid notification id 'bogus' (expected <uuid> or notification:<uuid>)\n");
    try kit.expectResult(h.run(&.{ "cmux", "dismiss-notification", "a", "b" }), 2, "", "cmux: dismiss-notification: unexpected arguments: b\n");
    try testing.expectEqual(n, h.requestCount());
    const missing = h.run(&.{ "cmux", "dismiss-notification", "--id", "44444444-4444-4444-8444-444444444444" });
    try kit.expectResult(missing, 1, "", "not_found: Notification not found\n");
}

test "unit: cli-notify: mark-notification-read selectors" {
    var h: Harness = undefined;
    try h.init(notifyHandler);
    defer h.deinit();
    h.setEnv("CMUX_WORKSPACE_ID", ws_uuid);
    try kit.expectResult(h.run(&.{ "cmux", "mark-notification-read", "--all" }), 0, "OK\n", "");
    try testing.expectEqualStrings("notification.mark_read", h.last().method);
    try testing.expectEqualStrings("{\"all\":true}", params(&h));
    _ = h.run(&.{ "cmux", "mark-notification-read", "--id", nid });
    try testing.expectEqualStrings("{\"id\":\"" ++ nid ++ "\"}", params(&h));
    _ = h.run(&.{ "cmux", "mark-notification-read", "--workspace", "workspace:2", "--surface", "surface:5", "--window", "window:1" });
    try testing.expectEqualStrings("{\"window_id\":\"window:1\",\"workspace_id\":\"workspace:2\",\"surface_id\":\"surface:5\"}", params(&h));
    const sel = "cmux: mark-notification-read requires exactly one selector: --id, --workspace, or --all\n";
    try kit.expectResult(h.run(&.{ "cmux", "mark-notification-read" }), 2, "", sel);
    try kit.expectResult(h.run(&.{ "cmux", "mark-notification-read", "--all", "--id", nid }), 2, "", sel);
    try kit.expectResult(h.run(&.{ "cmux", "mark-notification-read", "--surface", "surface:1" }), 2, "", "cmux: --surface requires --workspace\n");
    try kit.expectResult(h.run(&.{ "cmux", "mark-notification-read", "--all", "--surface", "surface:1" }), 2, "", "cmux: --surface requires --workspace\n");
    try kit.expectResult(h.run(&.{ "cmux", "mark-notification-read", "--all", "x" }), 2, "", "cmux: mark-notification-read: unexpected arguments: x\n");
}

test "unit: cli-notify: open-notification and jump-to-unread print the opened handles" {
    var h: Harness = undefined;
    try h.init(notifyHandler);
    defer h.deinit();
    try kit.expectResult(h.run(&.{ "cmux", "open-notification", "--id", nid }), 0, "OK workspace:1 surface:2\n", "");
    try testing.expectEqualStrings("notification.open", h.last().method);
    try testing.expectEqualStrings("{\"id\":\"" ++ nid ++ "\"}", params(&h));
    try kit.expectResult(h.run(&.{ "cmux", "open-notification" }), 2, "", "cmux: open-notification requires --id\n");
    try kit.expectResult(h.run(&.{ "cmux", "jump-to-unread", "--id-format", "both" }), 0, "OK workspace:1 (" ++ ws_uuid ++ ") surface:2 (" ++ sf_uuid ++ ")\n", "");
    try testing.expectEqualStrings("notification.jump_to_unread", h.last().method);
    try kit.expectResult(h.run(&.{ "cmux", "jump-to-last-prompt" }), 0, "OK workspace:1 surface:2\n", "");
    try testing.expectEqualStrings("surface.jump_to_last_prompt", h.last().method);
    try testing.expectEqualStrings("{\"focus\":true}", params(&h));
    h.server.user = &h;
    try kit.expectResult(h.run(&.{ "cmux", "jump-to-unread" }), 0, "No unread notifications\n", "");
    try kit.expectResult(h.run(&.{ "cmux", "jump-to-unread", "--json" }), 0, "{\n  \"opened\": false\n}\n", "");
    try kit.expectResult(h.run(&.{ "cmux", "jump-to-last-prompt" }), 0, "No agent prompt to jump to\n", "");
    try kit.expectResult(h.run(&.{ "cmux", "jump-to-unread", "x" }), 2, "", "cmux: jump-to-unread: unexpected arguments: x\n");
}

test "unit: cli-notify: focus-intent commands grant the foreground only to interactive humans" {
    var h: Harness = undefined;
    try h.init(notifyHandler);
    defer h.deinit();
    h.fp.interactive = true;
    _ = h.run(&.{ "cmux", "jump-to-unread" });
    try testing.expectEqualStrings("{\"foreground_grant\":true}", params(&h));
    try testing.expectEqual(@as(usize, 1), h.fp.foreground_grants.items.len);
    try testing.expectEqual(@as(u32, 4242), h.fp.foreground_grants.items[0]);
    h.setEnv("CLAUDECODE", "1");
    _ = h.run(&.{ "cmux", "jump-to-unread" });
    try testing.expectEqualStrings("{}", params(&h));
    try testing.expectEqual(@as(usize, 1), h.fp.foreground_grants.items.len);
}

test "unit: cli-notify: an interactive focus command reports a missing app once" {
    var h: Harness = undefined;
    try h.init(notifyHandler);
    defer h.deinit();
    h.fp.interactive = true;
    h.fp.servers.clearRetainingCapacity();
    for ([_][]const []const u8{
        &.{ "cmux", "jump-to-unread" },
        &.{ "cmux", "jump-to-last-prompt" },
        &.{ "cmux", "open-notification", "--id", nid },
    }) |argv| {
        const r = h.run(argv);
        try testing.expectEqual(@as(u8, 1), r.code);
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.err, "No live wmux socket found"));
    }
}

test "unit: cli-notify: clear-notifications scopes" {
    var h: Harness = undefined;
    try h.init(notifyHandler);
    defer h.deinit();
    try kit.expectResult(h.run(&.{ "cmux", "clear-notifications" }), 0, "OK\n", "");
    try testing.expectEqualStrings("notification.clear", h.last().method);
    try testing.expectEqualStrings("{}", params(&h));
    try kit.expectResult(h.run(&.{ "cmux", "clear-notifications", "--surface", "surface:1" }), 2, "", "cmux: clear-notifications --surface requires a workspace or window context\n");
    _ = h.run(&.{ "cmux", "clear-notifications", "--window", "window:1", "--workspace", "workspace:1", "--panel", "surface:1" });
    try testing.expectEqualStrings("{\"window_id\":\"window:1\",\"workspace_id\":\"workspace:1\",\"surface_id\":\"surface:1\"}", params(&h));
    h.setEnv("CMUX_WORKSPACE_ID", ws_uuid);
    _ = h.run(&.{ "cmux", "clear-notifications" });
    try testing.expectEqualStrings("{\"workspace_id\":\"" ++ ws_uuid ++ "\"}", params(&h));
    _ = h.run(&.{ "cmux", "clear-notifications", "--window", "window:2" });
    try testing.expectEqualStrings("{\"window_id\":\"window:2\"}", params(&h));
    try kit.expectResult(h.run(&.{ "cmux", "clear-notifications", "--all" }), 2, "", "cmux: clear-notifications: unexpected arguments: --all\n");
}

test "unit: cli-notify: app focus overrides" {
    var h: Harness = undefined;
    try h.init(notifyHandler);
    defer h.deinit();
    try kit.expectResult(h.run(&.{ "cmux", "set-app-focus", "Inactive" }), 0, "OK\n", "");
    try testing.expectEqualStrings("app.focus_override.set", h.last().method);
    try testing.expectEqualStrings("{\"state\":\"inactive\"}", params(&h));
    try kit.expectResult(h.run(&.{ "cmux", "set-app-focus" }), 2, "", "cmux: set-app-focus requires a value\n");
    try kit.expectResult(h.run(&.{ "cmux", "set-app-focus", "sideways" }), 2, "", "cmux: set-app-focus: invalid value 'sideways' (expected active, inactive or clear)\n");
    try kit.expectResult(h.run(&.{ "cmux", "set-app-focus", "clear", "x" }), 2, "", "cmux: set-app-focus: unexpected arguments: x\n");
    try kit.expectResult(h.run(&.{ "cmux", "simulate-app-active" }), 0, "OK\n", "");
    try testing.expectEqualStrings("app.simulate_active", h.last().method);
    try kit.expectResult(h.run(&.{ "cmux", "simulate-app-active", "now" }), 2, "", "cmux: simulate-app-active: unexpected arguments: now\n");
}

test "unit: cli-notify: trigger-flash defaults to the calling pane" {
    var h: Harness = undefined;
    try h.init(notifyHandler);
    defer h.deinit();
    try kit.expectResult(h.run(&.{ "cmux", "trigger-flash" }), 0, "OK\n", "");
    try testing.expectEqualStrings("surface.trigger_flash", h.last().method);
    try testing.expectEqualStrings("{}", params(&h));
    h.setEnv("CMUX_WORKSPACE_ID", ws_uuid);
    h.setEnv("CMUX_SURFACE_ID", sf_uuid);
    _ = h.run(&.{ "cmux", "trigger-flash" });
    try testing.expectEqualStrings("{\"workspace_id\":\"" ++ ws_uuid ++ "\",\"surface_id\":\"" ++ sf_uuid ++ "\"}", params(&h));
    _ = h.run(&.{ "cmux", "trigger-flash", "--workspace", "workspace:2", "--panel", "surface:3" });
    try testing.expectEqualStrings("{\"workspace_id\":\"workspace:2\",\"surface_id\":\"surface:3\"}", params(&h));
    _ = h.run(&.{ "cmux", "trigger-flash", "--window", "window:1" });
    try testing.expectEqualStrings("{\"window_id\":\"window:1\"}", params(&h));
    h.setEnv("TMUX", "x");
    _ = h.run(&.{ "cmux", "trigger-flash" });
    try testing.expectEqualStrings("{\"workspace_id\":\"" ++ ws_uuid ++ "\"}", params(&h));
    try kit.expectResult(h.run(&.{ "cmux", "trigger-flash", "--surface" }), 2, "", "cmux: trigger-flash: --surface requires a value\n");
}

var deleted: [4][]const u8 = undefined;
var deleted_n: usize = 0;
var delete_fails = false;

fn recordDelete(path: []const u8) anyerror!void {
    if (delete_fails) return error.AccessDenied;
    deleted[deleted_n] = path;
    deleted_n += 1;
}

fn noWrite(_: []const u8, _: []const u8) anyerror!void {}

test "unit: cli-notify: feed clear confirms, deletes and works offline" {
    var h: Harness = undefined;
    try h.init(notifyHandler);
    defer h.deinit();
    const saved = common.files;
    defer common.files = saved;
    common.files = .{ .delete = recordDelete, .write = noWrite };
    deleted_n = 0;
    delete_fails = false;
    const proto = @import("wmux_proto");
    const home = if (proto.paths.Style.native == .windows) "C:\\Users\\u" else "/home/u";
    h.setEnv(if (proto.paths.Style.native == .windows) "USERPROFILE" else "HOME", home);
    const path = try proto.paths.join(h.alloc(), proto.paths.Style.native, &.{ home, ".cmuxterm", "workstream.jsonl" });

    const none = h.run(&.{ "cmux", "feed", "clear", "--yes" });
    try kit.expectResult(none, 0, try std.fmt.allocPrint(h.alloc(), "No Feed history to clear ({s} does not exist).\n", .{path}), "");
    try h.fp.addFile(path, "{}\n");
    h.fp.stdin = "n\n";
    const prompt = try std.fmt.allocPrint(h.alloc(), "This will permanently delete {s}. Proceed? [y/N] ", .{path});
    try kit.expectResult(h.run(&.{ "cmux", "feed", "clear" }), 0, try std.mem.concat(h.alloc(), u8, &.{ prompt, "Aborted.\n" }), "");
    h.fp.stdin = "";
    try kit.expectResult(h.run(&.{ "cmux", "feed", "clear" }), 0, try std.mem.concat(h.alloc(), u8, &.{ prompt, "Aborted.\n" }), "");
    try testing.expectEqual(@as(usize, 0), deleted_n);
    h.fp.stdin = "Yes please\n";
    const cleared = try std.fmt.allocPrint(h.alloc(), "Cleared {s}\n", .{path});
    try kit.expectResult(h.run(&.{ "cmux", "feed", "clear" }), 0, try std.mem.concat(h.alloc(), u8, &.{ prompt, cleared }), "");
    try kit.expectResult(h.run(&.{ "cmux", "feed", "clear", "-y" }), 0, cleared, "");
    try testing.expectEqual(@as(usize, 2), deleted_n);
    try testing.expectEqualStrings(path, deleted[0]);
    delete_fails = true;
    const failed = h.run(&.{ "cmux", "feed", "clear", "--yes" });
    try testing.expectEqual(@as(u8, 1), failed.code);
    try kit.expectContains(failed.err, "cannot delete ");
    // Never connects.
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
    try kit.expectResult(h.run(&.{ "cmux", "feed", "clear", "--force" }), 2, "", "cmux: feed clear: unexpected arguments: --force\n");
    try kit.expectResult(h.run(&.{ "cmux", "feed", "tui" }), 1, "", "cmux: 'feed tui' is not available in this build of wmux yet\n");
    try kit.expectResult(h.run(&.{ "cmux", "feed", "bogus" }), 2, "", "cmux: unknown feed subcommand 'bogus'; expected tui or clear\n");
    const bare = h.run(&.{ "cmux", "feed" });
    try testing.expectEqual(@as(u8, 2), bare.code);
    try kit.expectContains(bare.err, "cmux feed clear [--yes|-y]");
}

fn consoleYes(_: *@import("../../command.zig").Ctx, _: usize) []const u8 {
    return "y\r";
}

test "unit: cli-notify: feed clear takes one answer line, not stdin up to EOF" {
    var h: Harness = undefined;
    try h.init(notifyHandler);
    defer h.deinit();
    const saved = common.files;
    defer common.files = saved;
    common.files = .{ .delete = recordDelete, .write = noWrite };
    deleted_n = 0;
    delete_fails = false;
    const proto = @import("wmux_proto");
    const home = if (proto.paths.Style.native == .windows) "C:\\Users\\u" else "/home/u";
    h.setEnv(if (proto.paths.Style.native == .windows) "USERPROFILE" else "HOME", home);
    const path = try proto.paths.join(h.alloc(), proto.paths.Style.native, &.{ home, ".cmuxterm", "workstream.jsonl" });
    try h.fp.addFile(path, "{}\n");
    // A console answers with one CRLF line and never sends EOF, so the
    // answer comes from the line hook (h.deinit restores it), not from the
    // platform's read-to-EOF stdin.
    h.fp.stdin = "n\n";
    common.read_answer = consoleYes;
    const r = h.run(&.{ "cmux", "feed", "clear" });
    try kit.expectResult(r, 0, try std.fmt.allocPrint(h.alloc(), "This will permanently delete {s}. Proceed? [y/N] Cleared {s}\n", .{ path, path }), "");
    try testing.expectEqual(@as(usize, 1), deleted_n);
}

test "unit: cli-notify: feed clear without a home directory" {
    var h: Harness = undefined;
    try h.init(notifyHandler);
    defer h.deinit();
    try kit.expectResult(h.run(&.{ "cmux", "feed", "clear", "-y" }), 1, "", "cmux: cannot locate the home directory (USERPROFILE and HOME are unset)\n");
}

test "unit: cli-notify: server errors and connection failures exit 1" {
    var h: Harness = undefined;
    try h.init(struct {
        fn f(_: *fake.Server, req: fake.Request) fake.Action {
            if (std.mem.eql(u8, req.method, "system.identify")) return .{ .ok = "{\"app\":\"wmux\",\"version\":\"0.9\"}" };
            if (std.mem.eql(u8, req.method, "notification.open")) return .{ .err = "{\"code\":\"not_found\",\"message\":\"Notification not found\"}" };
            return .{ .err = "{\"code\":\"method_not_found\",\"message\":\"Unknown method\"}" };
        }
    }.f);
    defer h.deinit();
    try kit.expectResult(h.run(&.{ "cmux", "open-notification", "--id", nid }), 1, "", "not_found: Notification not found\n");
    const skew = h.run(&.{ "cmux", "simulate-app-active" });
    try testing.expectEqual(@as(u8, 1), skew.code);
    try kit.expectContains(skew.err, "method_not_found: Unknown method\nThis CLI: cmux 1.2.3");
    try kit.expectContains(skew.err, "Fix: the app does not know 'app.simulate_active'");
    // No app running.
    h.fp.servers.clearRetainingCapacity();
    const down = h.run(&.{ "cmux", "notify", "--title", "x" });
    try testing.expectEqual(@as(u8, 1), down.code);
    try kit.expectContains(down.err, "No live wmux socket found");
}

test "unit: cli-notify: goldens for help and text output" {
    var h: Harness = undefined;
    try h.init(notifyHandler);
    defer h.deinit();
    const cases = [_][]const u8{
        "notify",            "list-notifications",  "dismiss-notification", "mark-notification-read",
        "open-notification", "jump-to-unread",      "jump-to-last-prompt",  "clear-notifications",
        "set-app-focus",     "simulate-app-active", "trigger-flash",        "feed",
    };
    for (cases) |c| {
        const r = h.run(&.{ "cmux", c, "--help" });
        try testing.expectEqual(@as(u8, 0), r.code);
        try testing.expect(std.mem.startsWith(u8, r.out, "Usage: cmux "));
        try kit.expectGolden(h.alloc(), try std.fmt.allocPrint(h.alloc(), "{s}-help.txt", .{c}), r.out);
    }
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
    h.setEnv("CMUX_WORKSPACE_ID", ws_uuid);
    const n = h.run(&.{ "cmux", "notify", "--title", "Done" });
    const o = h.run(&.{ "cmux", "open-notification", "--id", nid });
    const t = h.run(&.{ "cmux", "trigger-flash" });
    try kit.expectGolden(h.alloc(), "notify.txt", try std.mem.concat(h.alloc(), u8, &.{ n.out, o.out, t.out }));
}
