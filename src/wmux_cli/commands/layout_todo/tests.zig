//! Tests of the `layout_todo` family: todo and layout.

const std = @import("std");
const testing = std.testing;
const harness = @import("../cli_misc/harness.zig");
const fake = @import("../../fake.zig");
const layout = @import("layout.zig");

const id1 = "6ba7b810-9dad-11d1-80b4-00c04fd430c8";
const id2 = "6ba7b811-9dad-11d1-80b4-00c04fd430c8";
const list_payload = "{\"items\":[{\"id\":\"" ++ id1 ++ "\",\"text\":\"write test\",\"state\":\"pending\",\"origin\":\"user\"}," ++
    "{\"id\":\"" ++ id2 ++ "\",\"text\":\"lint \u{1F600}\",\"state\":\"completed\",\"origin\":\"agent\"}," ++
    "{\"id\":\"6ba7b812-9dad-11d1-80b4-00c04fd430c8\",\"text\":\"ship\",\"state\":\"in-progress\",\"origin\":\"user\"}],\"completed\":1,\"total\":3}";

fn todoServer(_: *fake.Server, req: fake.Request) fake.Action {
    if (std.mem.eql(u8, req.method, "workspace.todo.open")) return .{ .ok = "{\"surface_id\":\"S\"}" };
    if (std.mem.startsWith(u8, req.method, "workspace.todo.")) {
        if (req.params.object.get("workspace_id")) |w| if (std.mem.eql(u8, w.string, "workspace:9")) return .{ .ok = "{\"items\":[],\"completed\":0,\"total\":0}" };
        return .{ .ok = list_payload };
    }
    if (std.mem.eql(u8, req.method, "layout.save")) return .{ .ok = "{\"name\":\"dev\",\"unsupported\":1}" };
    if (std.mem.eql(u8, req.method, "layout.list")) {
        if (req.params.object.get("window_id") != null) return .{ .ok = "{\"layouts\":[]}" };
        return .{ .ok = "{\"layouts\":[{\"name\":\"dev\",\"panes\":3,\"surfaces\":4,\"description\":\"agent +\\tserver\"},{\"name\":\"\u{e9}t\u{e9}\",\"panes\":1,\"surfaces\":1}]}" };
    }
    if (std.mem.eql(u8, req.method, "layout.get")) return .{ .ok = "{\"layout\":{\"name\":\"dev\",\"workspace\":{\"layout\":{\"pane\":{\"surfaces\":[{\"type\":\"terminal\"}]}}}}}" };
    if (std.mem.eql(u8, req.method, "layout.open")) return .{ .ok = "{\"workspace_id\":\"" ++ id1 ++ "\",\"workspace_ref\":\"workspace:5\"}" };
    if (std.mem.eql(u8, req.method, "layout.delete")) {
        if (std.mem.eql(u8, req.params.object.get("name").?.string, "gone")) return .{ .err = "{\"code\":\"notFound\",\"message\":\"No saved layout named gone\"}" };
        return .{ .ok = "{\"deleted\":true}" };
    }
    return .{ .err = "{\"code\":\"method_not_found\",\"message\":\"Unknown method\"}" };
}

test "unit: cli-todo: list text, empty list and json" {
    var h: harness.Harness = undefined;
    h.init();
    defer h.deinit();
    h.serve(todoServer);
    h.setEnv("CMUX_WORKSPACE_ID", "WS-1");
    const r = h.run(&.{ "cmux", "todo", "list" });
    try harness.expectOk(r);
    try testing.expectEqualStrings("workspace.todo.list", h.last().method);
    try testing.expectEqualStrings("{\"workspace_id\":\"WS-1\"}", h.last().params_json);
    try harness.expectGolden(h.alloc(), "todo-list.txt", r.out);
    const empty = h.run(&.{ "cmux", "todo", "ls", "--workspace", "workspace:9" });
    try testing.expectEqualStrings("No todo items.\n", empty.out);
    const js = h.run(&.{ "cmux", "todo", "list", "--json" });
    try harness.expectOk(js);
    try harness.expectContains(js.out, "\"total\": 3");
}

test "unit: cli-todo: add, state changes, edit, rm, move, clear, open" {
    var h: harness.Harness = undefined;
    h.init();
    defer h.deinit();
    h.serve(todoServer);
    h.setEnv("CMUX_WORKSPACE_ID", "WS-1");
    const add = h.run(&.{ "cmux", "todo", "add", "  write test ", "--state", "in-progress", "--origin", "agent" });
    try harness.expectOk(add);
    try harness.expectGolden(h.alloc(), "todo-add.txt", add.out);
    try testing.expectEqualStrings("workspace.todo.add", h.last().method);
    try testing.expectEqualStrings("{\"workspace_id\":\"WS-1\",\"text\":\"write test\",\"state\":\"in-progress\",\"origin\":\"agent\"}", h.last().params_json);

    // An index is resolved through todo.list, then sent as item_id.
    const before = h.requestCount();
    try harness.expectOk(h.run(&.{ "cmux", "todo", "check", "2" }));
    try testing.expectEqual(before + 2, h.requestCount());
    try testing.expectEqualStrings("workspace.todo.list", h.server.requests.items[before].method);
    try testing.expectEqualStrings("workspace.todo.set_state", h.last().method);
    try testing.expectEqualStrings("{\"workspace_id\":\"WS-1\",\"item_id\":\"" ++ id2 ++ "\",\"state\":\"completed\"}", h.last().params_json);
    // A UUID goes straight to the mutation.
    const n = h.requestCount();
    try harness.expectOk(h.run(&.{ "cmux", "todo", "uncheck", id1 }));
    try testing.expectEqual(n + 1, h.requestCount());
    try testing.expectEqualStrings("{\"workspace_id\":\"WS-1\",\"item_id\":\"" ++ id1 ++ "\",\"state\":\"pending\"}", h.last().params_json);
    try harness.expectOk(h.run(&.{ "cmux", "todo", "start", "1" }));
    try testing.expectEqualStrings("in-progress", h.last().params.object.get("state").?.string);
    try harness.expectOk(h.run(&.{ "cmux", "todo", "edit", "1", "new text" }));
    try testing.expectEqualStrings("workspace.todo.edit", h.last().method);
    try testing.expectEqualStrings("new text", h.last().params.object.get("text").?.string);
    try harness.expectOk(h.run(&.{ "cmux", "todo", "remove", "3" }));
    try testing.expectEqualStrings("workspace.todo.remove", h.last().method);
    try harness.expectOk(h.run(&.{ "cmux", "todo", "mv", "3", "1" }));
    try testing.expectEqualStrings("workspace.todo.move", h.last().method);
    try testing.expectEqual(@as(i64, 0), h.last().params.object.get("index").?.integer);
    try harness.expectOk(h.run(&.{ "cmux", "todo", "clear", "--workspace", "workspace:2" }));
    try testing.expectEqualStrings("{\"workspace_id\":\"workspace:2\"}", h.last().params_json);
    const open = h.run(&.{ "cmux", "todo", "open" });
    try testing.expectEqualStrings("OK\n", open.out);
    try testing.expectEqualStrings("workspace.todo.open", h.last().method);
    // Text that starts with a dash after --.
    try harness.expectOk(h.run(&.{ "cmux", "todo", "add", "--", "-v flag" }));
    try testing.expectEqualStrings("-v flag", h.last().params.object.get("text").?.string);
}

test "unit: cli-todo: set from an inline argument and from stdin" {
    var h: harness.Harness = undefined;
    h.init();
    defer h.deinit();
    h.serve(todoServer);
    const r = h.run(&.{ "cmux", "todo", "set", "[{\"text\":\"lint\",\"state\":\"completed\"}]" });
    try harness.expectOk(r);
    try testing.expectEqualStrings("OK (1/3 completed)\n", r.out);
    try testing.expectEqualStrings("workspace.todo.set", h.last().method);
    try testing.expectEqualStrings("{\"items\":[{\"text\":\"lint\",\"state\":\"completed\"}]}", h.last().params_json);
    h.fp.stdin = "{\"items\":[{\"text\":\"a\",\"id\":\"" ++ id1 ++ "\"}]}";
    try harness.expectOk(h.run(&.{ "cmux", "todo", "set" }));
    try testing.expectEqualStrings("{\"items\":[{\"text\":\"a\",\"id\":\"" ++ id1 ++ "\"}]}", h.last().params_json);
    const n = h.requestCount();
    h.fp.stdin = "[{\"text\":\" \"}]";
    try harness.expectFail(h.run(&.{ "cmux", "todo", "set" }), 2, "item 1: item text is empty");
    try harness.expectFail(h.run(&.{ "cmux", "todo", "set", "nope" }), 2, "todo set input is not valid JSON");
    try testing.expectEqual(n, h.requestCount());
}

test "unit: cli-todo: argument errors" {
    var h: harness.Harness = undefined;
    h.init();
    defer h.deinit();
    h.serve(todoServer);
    try harness.expectFail(h.run(&.{ "cmux", "todo" }), 2, "todo requires a subcommand");
    try harness.expectFail(h.run(&.{ "cmux", "todo", "frob" }), 2, "unknown todo subcommand 'frob'");
    try harness.expectFail(h.run(&.{ "cmux", "todo", "add" }), 2, "todo add: missing text");
    try harness.expectFail(h.run(&.{ "cmux", "todo", "add", " \t" }), 2, "todo add requires non-empty text");
    try harness.expectFail(h.run(&.{ "cmux", "todo", "add", "x", "y" }), 2, "unexpected argument 'y'");
    try harness.expectFail(h.run(&.{ "cmux", "todo", "add", "x", "--state", "done" }), 2, "--state must be pending, in-progress or completed");
    try harness.expectFail(h.run(&.{ "cmux", "todo", "add", "x", "--origin", "bot" }), 2, "--origin must be user or agent");
    try harness.expectFail(h.run(&.{ "cmux", "todo", "check", "1", "--state", "pending" }), 2, "--state is only valid with todo add");
    try harness.expectFail(h.run(&.{ "cmux", "todo", "check", "zero" }), 2, "Invalid todo item: zero (expected an item UUID or a 1-based index from `cmux todo list`)");
    try harness.expectFail(h.run(&.{ "cmux", "todo", "check", "0" }), 2, "Invalid todo item: 0");
    try harness.expectFail(h.run(&.{ "cmux", "todo", "move", "1", "x" }), 2, "invalid position 'x'");
    try harness.expectFail(h.run(&.{ "cmux", "todo", "edit", "1", "" }), 2, "todo edit requires non-empty text");
    try harness.expectFail(h.run(&.{ "cmux", "todo", "list", "--bogus" }), 2, "todo: unknown flag '--bogus'");
    try testing.expectEqual(@as(usize, 0), h.requestCount());
    // Out-of-range index: needs the list, then fails with exit 1.
    try harness.expectFail(h.run(&.{ "cmux", "todo", "rm", "7" }), 1, "Invalid todo item: 7");
    try testing.expectEqual(@as(usize, 1), h.requestCount());
    const help = h.run(&.{ "cmux", "todo", "--help" });
    try harness.expectOk(help);
    try harness.expectGolden(h.alloc(), "todo-help.txt", help.out);
}

test "unit: cli-layout: save, list, get, open and delete" {
    var h: harness.Harness = undefined;
    h.init();
    defer h.deinit();
    h.serve(todoServer);
    h.setEnv("CMUX_WORKSPACE_ID", "WS-1");
    const a = h.alloc();
    const save = h.run(&.{ "cmux", "layout", "save", "dev", "--overwrite", "--description", "agent + server" });
    try harness.expectOk(save);
    try testing.expectEqualStrings("OK layout=dev unsupported=1\n", save.out);
    try testing.expectEqualStrings("layout.save", h.last().method);
    try testing.expectEqualStrings("{\"name\":\"dev\",\"workspace_id\":\"WS-1\",\"overwrite\":true,\"description\":\"agent + server\"}", h.last().params_json);
    _ = h.run(&.{ "cmux", "layout", "save", "x", "--workspace", "workspace:3" });
    try testing.expectEqualStrings("{\"name\":\"x\",\"workspace_id\":\"workspace:3\",\"overwrite\":false}", h.last().params_json);

    const list = h.run(&.{ "cmux", "layout", "list" });
    try harness.expectOk(list);
    try testing.expectEqualStrings("{}", h.last().params_json);
    try harness.expectGolden(a, "layout-list.txt", list.out);
    const empty = h.run(&.{ "cmux", "layout", "list", "--window", "window:1" });
    try testing.expectEqualStrings("No saved layouts\n", empty.out);

    const get = h.run(&.{ "cmux", "layout", "get", "dev" });
    try harness.expectOk(get);
    try harness.expectGolden(a, "layout-get.txt", get.out);

    const open = h.run(&.{ "cmux", "layout", "open", "dev", "--cwd", "~/x", "--focus", "true" });
    try harness.expectOk(open);
    try testing.expectEqualStrings("OK workspace=workspace:5\n", open.out);
    try testing.expectEqualStrings("layout.open", h.last().method);
    h.setEnv("HOME", "/home/u");
    h.setEnv("USERPROFILE", "C:\\Users\\u");
    _ = h.run(&.{ "cmux", "layout", "open", "dev" });
    try testing.expectEqualStrings("{\"name\":\"dev\",\"focus\":false}", h.last().params_json);
    _ = h.run(&.{ "cmux", "layout", "open", "dev", "--cwd", "sub" });
    try testing.expectEqualStrings(harness.p(a, &.{ harness.root, "work", "sub" }), h.last().params.object.get("cwd").?.string);
    const uuids = h.run(&.{ "cmux", "layout", "open", "dev", "--id-format", "uuids" });
    try testing.expectEqualStrings("OK workspace=" ++ id1 ++ "\n", uuids.out);

    const del = h.run(&.{ "cmux", "layout", "delete", "dev" });
    try testing.expectEqualStrings("OK deleted=true\n", del.out);
    try harness.expectFail(h.run(&.{ "cmux", "layout", "delete", "gone" }), 1, "notFound: No saved layout named gone");
}

test "unit: cli-layout: argument errors" {
    var h: harness.Harness = undefined;
    h.init();
    defer h.deinit();
    h.serve(todoServer);
    try harness.expectFail(h.run(&.{ "cmux", "layout" }), 2, "layout requires a subcommand");
    try harness.expectFail(h.run(&.{ "cmux", "layout", "rename" }), 2, "unknown layout subcommand 'rename'");
    try harness.expectFail(h.run(&.{ "cmux", "layout", "save" }), 2, "layout save requires a name");
    try harness.expectFail(h.run(&.{ "cmux", "layout", "save", "  " }), 2, "layout save requires a name");
    try harness.expectFail(h.run(&.{ "cmux", "layout", "open", "a", "b" }), 2, "unexpected argument 'b'");
    try harness.expectFail(h.run(&.{ "cmux", "layout", "list", "x" }), 2, "unexpected argument 'x'");
    try harness.expectFail(h.run(&.{ "cmux", "layout", "open", "a", "--focus", "maybe" }), 2, "--focus must be true|false");
    try harness.expectFail(h.run(&.{ "cmux", "layout", "delete", "a", "--overwrite" }), 2, "layout delete: --overwrite is not valid here");
    try harness.expectFail(h.run(&.{ "cmux", "layout", "save", "a", "--cwd", "x" }), 2, "layout save: --cwd is not valid here");
    const long = [_]u8{'n'} ** (layout.max_name_bytes + 1);
    try harness.expectFail(h.run(&.{ "cmux", "layout", "save", &long }), 2, "layout name is longer than 256 bytes");
    try harness.expectFail(h.run(&.{ "cmux", "layout", "save", "a\xff" }), 2, "layout name must be UTF-8");
    try testing.expectEqual(@as(usize, 0), h.requestCount());
    const help = h.run(&.{ "cmux", "layout", "--help" });
    try harness.expectOk(help);
    try harness.expectGolden(h.alloc(), "layout-help.txt", help.out);
}
