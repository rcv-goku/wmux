//! Unit tests for the browser snapshot / ref / locator logic (W2-8 pre-build).
//! Run: zig test --dep wmux_proto -Mroot=src/apprt/win32/web/cdp/logic/tests.zig
//!      -Mwmux_proto=src/wmux_proto/proto.zig

const std = @import("std");
const testing = std.testing;
const ax = @import("ax_tree.zig");
const css = @import("css.zig");
const refs = @import("refs.zig");
const snapshot = @import("snapshot.zig");
const locators = @import("locators.zig");

test {
    _ = ax;
    _ = css;
    _ = refs;
    _ = snapshot;
    _ = locators;
}

const gpa = testing.allocator;

// ---------------------------------------------------------------------------
// Fixtures (authored for these tests; shapes follow the CDP protocol).

/// Accessibility.getFullAXTree for a login form, as a full CDP response.
const ax_login =
    \\{"id":7,"result":{"nodes":[
    \\ {"nodeId":"1","ignored":false,"role":{"type":"internalRole","value":"RootWebArea"},
    \\  "name":{"type":"computedString","value":"Sign in"},"childIds":["2"],"backendDOMNodeId":1},
    \\ {"nodeId":"2","ignored":true,"role":{"type":"role","value":"generic"},"childIds":["3","4","5","6"],
    \\  "parentId":"1","backendDOMNodeId":2},
    \\ {"nodeId":"3","ignored":false,"role":{"type":"role","value":"heading"},
    \\  "name":{"type":"computedString","value":"Welcome back"},
    \\  "properties":[{"name":"level","value":{"type":"integer","value":1}}],
    \\  "childIds":["7"],"parentId":"2","backendDOMNodeId":3},
    \\ {"nodeId":"7","ignored":false,"role":{"type":"internalRole","value":"StaticText"},
    \\  "name":{"type":"computedString","value":"Welcome back"},"childIds":["8"],"parentId":"3","backendDOMNodeId":30},
    \\ {"nodeId":"8","ignored":false,"role":{"type":"internalRole","value":"InlineTextBox"},
    \\  "name":{"type":"computedString","value":"Welcome back"},"childIds":[],"parentId":"7"},
    \\ {"nodeId":"4","ignored":false,"role":{"type":"role","value":"textbox"},
    \\  "name":{"type":"computedString","value":"Email"},"value":{"type":"string","value":""},
    \\  "properties":[{"name":"focusable","value":{"type":"booleanOrUndefined","value":true}},
    \\                {"name":"required","value":{"type":"boolean","value":true}}],
    \\  "childIds":[],"parentId":"2","backendDOMNodeId":21},
    \\ {"nodeId":"5","ignored":false,"role":{"type":"role","value":"textbox"},
    \\  "name":{"type":"computedString","value":"Password"},
    \\  "properties":[{"name":"focusable","value":{"type":"booleanOrUndefined","value":true}}],
    \\  "childIds":[],"parentId":"2","backendDOMNodeId":22},
    \\ {"nodeId":"6","ignored":false,"role":{"type":"role","value":"button"},
    \\  "name":{"type":"computedString","value":"Sign in"},
    \\  "properties":[{"name":"focusable","value":{"type":"booleanOrUndefined","value":true}}],
    \\  "childIds":[],"parentId":"2","backendDOMNodeId":23}
    \\]}}
;

/// DOM.getDocument({depth:-1, pierce:true}) for a login form with hidden
/// content, a wrapping label, a script and an iframe.
const dom_login =
    \\{"root":{"nodeId":1,"backendNodeId":1,"nodeType":9,"nodeName":"#document","localName":"",
    \\ "documentURL":"https://example.test/login","children":[
    \\ {"nodeId":2,"backendNodeId":2,"nodeType":10,"nodeName":"html","localName":""},
    \\ {"nodeId":3,"backendNodeId":3,"nodeType":1,"nodeName":"HTML","localName":"html","attributes":[],"children":[
    \\  {"nodeId":4,"backendNodeId":4,"nodeType":1,"nodeName":"HEAD","localName":"head","attributes":[],"children":[
    \\   {"nodeId":5,"backendNodeId":5,"nodeType":1,"nodeName":"TITLE","localName":"title","attributes":[],"children":[
    \\    {"nodeId":6,"backendNodeId":6,"nodeType":3,"nodeName":"#text","nodeValue":"Login \"Portal\""}]}]},
    \\  {"nodeId":7,"backendNodeId":7,"nodeType":1,"nodeName":"BODY","localName":"body","attributes":[],"children":[
    \\   {"nodeId":8,"backendNodeId":8,"nodeType":1,"nodeName":"MAIN","localName":"main","attributes":["class","page"],"children":[
    \\    {"nodeId":9,"backendNodeId":9,"nodeType":1,"nodeName":"FORM","localName":"form","attributes":["id","login"],"children":[
    \\     {"nodeId":10,"backendNodeId":10,"nodeType":1,"nodeName":"LABEL","localName":"label","attributes":["for","email"],"children":[
    \\      {"nodeId":11,"backendNodeId":11,"nodeType":3,"nodeName":"#text","nodeValue":"Email"}]},
    \\     {"nodeId":12,"backendNodeId":12,"nodeType":1,"nodeName":"INPUT","localName":"input",
    \\      "attributes":["id","email","type","email","placeholder","you@example.com","data-testid","email-input"]},
    \\     {"nodeId":13,"backendNodeId":13,"nodeType":1,"nodeName":"LABEL","localName":"label","attributes":[],"children":[
    \\      {"nodeId":14,"backendNodeId":14,"nodeType":3,"nodeName":"#text","nodeValue":"  Password\n "},
    \\      {"nodeId":15,"backendNodeId":15,"nodeType":1,"nodeName":"INPUT","localName":"input","attributes":["type","password","name","pw"]}]},
    \\     {"nodeId":16,"backendNodeId":16,"nodeType":1,"nodeName":"BUTTON","localName":"button","attributes":["type","submit","class","btn primary"],"children":[
    \\      {"nodeId":17,"backendNodeId":17,"nodeType":3,"nodeName":"#text","nodeValue":"Sign in"}]},
    \\     {"nodeId":18,"backendNodeId":18,"nodeType":1,"nodeName":"DIV","localName":"div","attributes":["style","display: none"],"children":[
    \\      {"nodeId":19,"backendNodeId":19,"nodeType":1,"nodeName":"BUTTON","localName":"button","attributes":[],"children":[
    \\       {"nodeId":20,"backendNodeId":20,"nodeType":3,"nodeName":"#text","nodeValue":"Hidden"}]}]},
    \\     {"nodeId":21,"backendNodeId":21,"nodeType":1,"nodeName":"SCRIPT","localName":"script","attributes":[],"children":[
    \\      {"nodeId":22,"backendNodeId":22,"nodeType":3,"nodeName":"#text","nodeValue":"var x = '<button>';"}]}
    \\    ]}]}]}]}]}}
;

fn renderText(tree: *const ax.Tree, table: *refs.RefTable, opts: snapshot.Options) ![]u8 {
    var snap = try snapshot.render(gpa, tree, table, opts);
    defer snap.deinit();
    return gpa.dupe(u8, snap.text);
}

// ---------------------------------------------------------------------------
// ax_tree

test "unit: browser: ax tree parses CDP response envelope" {
    var tree = try ax.parseAxTree(gpa, ax_login, .{ .url = "https://example.test/login" });
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 8), tree.nodes.len);
    try testing.expectEqualStrings("Sign in", tree.title);
    try testing.expectEqualStrings("document", tree.get(tree.root).role);
    try testing.expectEqual(ax.Kind.document, tree.get(tree.root).kind);
    const h = tree.findByBackendId(3, null).?;
    try testing.expectEqualStrings("heading", tree.get(h).role);
    try testing.expectEqual(@as(?u8, 1), tree.get(h).states.level);
    const email = tree.findByBackendId(21, null).?;
    try testing.expect(tree.get(email).states.required);
    try testing.expectEqualStrings("Email", tree.get(email).label);
}

test "unit: browser: ax tree accepts bare nodes array and nodes object" {
    const bare =
        \\[{"nodeId":"a","role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"Go"},"backendDOMNodeId":5}]
    ;
    var t1 = try ax.parseAxTree(gpa, bare, .{});
    defer t1.deinit();
    try testing.expectEqualStrings("button", t1.get(0).role);
    const obj =
        \\{"nodes":[{"nodeId":"a","role":{"type":"role","value":"link"},"name":{"type":"computedString","value":"Home"}}]}
    ;
    var t2 = try ax.parseAxTree(gpa, obj, .{});
    defer t2.deinit();
    try testing.expectEqualStrings("Home", t2.get(0).name);
}

test "unit: browser: ax tree rejects malformed and empty input" {
    try testing.expectError(error.InvalidCdpJson, ax.parseAxTree(gpa, "", .{}));
    try testing.expectError(error.InvalidCdpJson, ax.parseAxTree(gpa, "{\"nodes\":[", .{}));
    try testing.expectError(error.MissingNodes, ax.parseAxTree(gpa, "{\"nodes\":[]}", .{}));
    try testing.expectError(error.MissingNodes, ax.parseAxTree(gpa, "{\"result\":{}}", .{}));
    try testing.expectError(error.MissingNodes, ax.parseAxTree(gpa, "42", .{}));
    try testing.expectError(error.InvalidCdpJson, ax.parseAxTree(gpa, "[1,2]", .{}));
}

test "unit: browser: ax tree survives cycles, duplicates and dangling child ids" {
    const cyc =
        \\{"nodes":[
        \\ {"nodeId":"1","role":{"type":"internalRole","value":"RootWebArea"},"childIds":["2"]},
        \\ {"nodeId":"2","role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"A"},"childIds":["3","3","1","2","zz"]},
        \\ {"nodeId":"3","role":{"type":"role","value":"link"},"name":{"type":"computedString","value":"B"},"childIds":["2","1"]},
        \\ {"nodeId":"3","role":{"type":"role","value":"link"},"name":{"type":"computedString","value":"dup"}}
        \\]}
    ;
    var tree = try ax.parseAxTree(gpa, cyc, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    const text = try renderText(&tree, &table, .{ .max_depth = 50 });
    defer gpa.free(text);
    // Every node is emitted at most once; the walk terminates.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\"A\""));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\"B\""));
}

test "unit: browser: ax tree breaks parent cycles the root cannot reach" {
    // 2 -> 3 -> 4 -> 2 and nobody else lists them. Only cycles through the
    // root used to be cut, so isHidden/contains and a --selector walk
    // starting inside the loop never ended.
    const j =
        \\{"nodes":[
        \\ {"nodeId":"1","role":{"type":"internalRole","value":"RootWebArea"},"childIds":[]},
        \\ {"nodeId":"2","role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"A"},"childIds":["3"],"backendDOMNodeId":7},
        \\ {"nodeId":"3","role":{"type":"role","value":"generic"},"childIds":["4"],"backendDOMNodeId":8},
        \\ {"nodeId":"4","role":{"type":"role","value":"link"},"name":{"type":"computedString","value":"B"},"childIds":["2"],"backendDOMNodeId":9}
        \\]}
    ;
    var tree = try ax.parseAxTree(gpa, j, .{});
    defer tree.deinit();
    for (0..tree.nodes.len) |i| {
        var cur: ?ax.NodeIndex = @intCast(i);
        var steps: usize = 0;
        while (cur) |c| : (cur = tree.get(c).parent) {
            steps += 1;
            try testing.expect(steps <= tree.nodes.len);
        }
    }
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    _ = try table.add(.{ .backend_node_id = 7 });
    var snap = try snapshot.render(gpa, &tree, &table, .{ .selector = "@e1", .max_depth = 50 });
    defer snap.deinit();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, snap.text, "\"A\""));
}

test "unit: browser: lone surrogate escapes read as U+FFFD instead of failing the parse" {
    // Chrome writes each UTF-16 code unit as \uXXXX; text cut inside an
    // emoji by page script leaves a lone surrogate, which std.json rejects,
    // so one such string used to fail the whole snapshot.
    const j =
        \\{"root":{"nodeType":9,"children":[{"nodeType":1,"localName":"body","children":[
        \\ {"nodeType":1,"localName":"button","attributes":["aria-label","Like \ud83d"]},
        \\ {"nodeType":1,"localName":"button","attributes":["aria-label","\udc00x\ud800\ud800\udc00"]},
        \\ {"nodeType":1,"localName":"button","children":[{"nodeType":3,"nodeValue":"ok \ud83d\ude00 \\ud800"}]}]}]}}
    ;
    var tree = try ax.parseDomDocument(gpa, j, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    const text = try renderText(&tree, &table, .{});
    defer gpa.free(text);
    try testing.expectEqualStrings("- document \"\"\n" ++
        "- button \"Like \u{FFFD}\" [ref=e1]\n" ++
        "- button \"\u{FFFD}x\u{FFFD}\u{10000}\" [ref=e2]\n" ++
        "- button \"ok \u{1F600} \\ud800\" [ref=e3]", text);
    var a = try ax.parseAxTree(gpa, axDoc(
        \\{"nodeId":"2","role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"Go \udfff"},"parentId":"1"}
    ), .{});
    defer a.deinit();
    try testing.expectEqualStrings("Go \u{FFFD}", a.get(1).name);
    // A truncated escape is still malformed.
    try testing.expectError(error.InvalidCdpJson, ax.parseDomDocument(gpa, "{\"root\":{\"nodeType\":9,\"nodeName\":\"\\ud83\"}}", .{}));
}

test "unit: browser: ax tree scalar values and tri-state properties" {
    const j =
        \\{"nodes":[
        \\ {"nodeId":"1","role":{"type":"internalRole","value":"RootWebArea"},"name":{"type":"computedString","value":""},"childIds":["2","3","4"]},
        \\ {"nodeId":"2","role":{"type":"role","value":"slider"},"name":{"type":"computedString","value":"Vol"},
        \\  "value":{"type":"number","value":42},"childIds":[]},
        \\ {"nodeId":"3","role":{"type":"role","value":"checkbox"},"name":{"type":"computedString","value":"All"},
        \\  "properties":[{"name":"checked","value":{"type":"tristate","value":"mixed"}}]},
        \\ {"nodeId":"4","role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"Bold"},
        \\  "properties":[{"name":"pressed","value":{"type":"tristate","value":"true"}},
        \\                {"name":"disabled","value":{"type":"boolean","value":true}},
        \\                {"name":"expanded","value":{"type":"booleanOrUndefined","value":false}}]}
        \\]}
    ;
    var tree = try ax.parseAxTree(gpa, j, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    const text = try renderText(&tree, &table, .{});
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\- document ""
        \\- slider "Vol" [ref=e1]: 42
        \\- checkbox "All" [ref=e2] [checked=mixed]
        \\- button "Bold" [ref=e3] [disabled] [expanded=false] [pressed]
    , text);
}

test "unit: browser: dom document parses tags, attrs, title and url" {
    var tree = try ax.parseDomDocument(gpa, dom_login, .{});
    defer tree.deinit();
    try testing.expectEqualStrings("Login \"Portal\"", tree.title);
    try testing.expectEqualStrings("https://example.test/login", tree.url);
    const email = tree.findByBackendId(12, null).?;
    const n = tree.get(email);
    try testing.expectEqualStrings("input", n.tag);
    try testing.expectEqualStrings("textbox", n.role);
    try testing.expectEqualStrings("Email", n.name);
    try testing.expectEqualStrings("Email", n.label);
    try testing.expectEqualStrings("email-input", n.attr("DATA-TESTID").?);
    const pw = tree.get(tree.findByBackendId(15, null).?);
    try testing.expectEqualStrings("Password", pw.name);
    // Hidden by inline style / non-rendered tag.
    try testing.expect(tree.isHidden(tree.findByBackendId(19, null).?));
    try testing.expect(tree.isHidden(tree.findByBackendId(22, null).?));
    try testing.expectEqualStrings("body", tree.get(tree.bodyIndex()).tag);
}

test "unit: browser: page url survives later allocations in the tree arena" {
    // The url used to be copied into an arena the tree no longer tracked, so
    // finishDom / annotateFromDom overwrote it.
    const url = "https://example.test/a/fairly/long/path?with=query&and=\u{00e9}";
    var dom = try ax.parseDomDocument(gpa, dom_login, .{ .url = url });
    defer dom.deinit();
    try testing.expectEqualStrings(url, dom.url);
    var tree = try ax.parseAxTree(gpa, ax_login, .{ .url = url });
    defer tree.deinit();
    try tree.annotateFromDom(&dom);
    try testing.expectEqualStrings(url, tree.url);
    try testing.expectEqualStrings("Sign in", tree.title);
}

test "unit: browser: dom implicit roles" {
    const Case = struct { tag: []const u8, attrs: []const ax.Attr = &.{}, role: []const u8 };
    const cases = [_]Case{
        .{ .tag = "button", .role = "button" },
        .{ .tag = "a", .role = "" },
        .{ .tag = "a", .attrs = &.{.{ .name = "href", .value = "/x" }}, .role = "link" },
        .{ .tag = "input", .role = "textbox" },
        .{ .tag = "input", .attrs = &.{.{ .name = "type", .value = "CHECKBOX" }}, .role = "checkbox" },
        .{ .tag = "input", .attrs = &.{.{ .name = "type", .value = "radio" }}, .role = "radio" },
        .{ .tag = "input", .attrs = &.{.{ .name = "type", .value = "submit" }}, .role = "button" },
        .{ .tag = "input", .attrs = &.{.{ .name = "type", .value = "search" }}, .role = "searchbox" },
        .{ .tag = "input", .attrs = &.{.{ .name = "type", .value = "range" }}, .role = "slider" },
        .{ .tag = "input", .attrs = &.{.{ .name = "type", .value = "number" }}, .role = "spinbutton" },
        .{ .tag = "input", .attrs = &.{.{ .name = "type", .value = "made-up" }}, .role = "textbox" },
        .{ .tag = "textarea", .role = "textbox" },
        .{ .tag = "select", .role = "combobox" },
        .{ .tag = "summary", .role = "button" },
        .{ .tag = "h3", .role = "heading" },
        .{ .tag = "h7", .role = "" },
        .{ .tag = "li", .role = "listitem" },
        .{ .tag = "nav", .role = "navigation" },
        .{ .tag = "section", .role = "" },
        .{ .tag = "section", .attrs = &.{.{ .name = "aria-label", .value = "News" }}, .role = "region" },
        .{ .tag = "th", .attrs = &.{.{ .name = "scope", .value = "row" }}, .role = "rowheader" },
        .{ .tag = "div", .attrs = &.{.{ .name = "role", .value = " Tab  extra" }}, .role = "tab" },
        .{ .tag = "button", .attrs = &.{.{ .name = "role", .value = "presentation" }}, .role = "" },
        .{ .tag = "div", .attrs = &.{.{ .name = "role", .value = "x-custom" }}, .role = "x-custom" },
    };
    for (cases) |c| {
        const n: ax.Node = .{ .tag = c.tag, .attrs = c.attrs };
        try testing.expectEqualStrings(c.role, ax.domRole(&n));
    }
}

test "unit: browser: dom heading level comes only from h1-h6 or aria-level" {
    // Page markup decides tag names: `<h- role=heading>` must not underflow
    // and `<hr role=heading>` must not invent a level from its tag.
    const j =
        \\{"root":{"nodeType":9,"children":[{"nodeType":1,"localName":"body","children":[
        \\ {"nodeType":1,"localName":"h-","backendNodeId":2,"attributes":["role","heading"],"children":[{"nodeType":3,"nodeValue":"dash"}]},
        \\ {"nodeType":1,"localName":"hr","backendNodeId":3,"attributes":["role","heading"]},
        \\ {"nodeType":1,"localName":"h4","backendNodeId":4,"children":[{"nodeType":3,"nodeValue":"four"}]},
        \\ {"nodeType":1,"localName":"h-","backendNodeId":5,"attributes":["role","heading","aria-level","3"]},
        \\ {"nodeType":1,"localName":"h2","backendNodeId":6,"attributes":["aria-level","0"]},
        \\ {"nodeType":1,"localName":"h3","backendNodeId":7,"attributes":["aria-level"," x "]},
        \\ {"nodeType":1,"localName":"div","backendNodeId":8,"attributes":["role","heading","aria-level","0"]},
        \\ {"nodeType":1,"localName":"h1","backendNodeId":9,"attributes":["aria-level","\t5\n"]}]}]}}
    ;
    var tree = try ax.parseDomDocument(gpa, j, .{});
    defer tree.deinit();
    const Case = struct { i64, ?u8 };
    // Invalid aria-level values (not a positive integer) fall back to h1-h6.
    for ([_]Case{ .{ 2, null }, .{ 3, null }, .{ 4, 4 }, .{ 5, 3 }, .{ 6, 2 }, .{ 7, 3 }, .{ 8, null }, .{ 9, 5 } }) |c| {
        const n = tree.get(tree.findByBackendId(c[0], null).?);
        try testing.expectEqualStrings("heading", n.role);
        try testing.expectEqual(c[1], n.states.level);
    }
}

test "unit: browser: hidden wrapping labels do not crash dom parsing" {
    // A wrapping <label> that is itself hidden used to slice an empty
    // preorder (`order[1..]`) and panic. The closed <details> case is
    // ordinary settings-page markup.
    const j =
        \\{"root":{"nodeType":9,"children":[{"nodeType":1,"localName":"body","children":[
        \\ {"nodeType":1,"localName":"details","children":[
        \\  {"nodeType":1,"localName":"summary","children":[{"nodeType":3,"nodeValue":"Options"}]},
        \\  {"nodeType":1,"localName":"label","children":[
        \\   {"nodeType":1,"localName":"input","backendNodeId":2,"attributes":["type","checkbox"]},
        \\   {"nodeType":3,"nodeValue":"Enable"}]}]},
        \\ {"nodeType":1,"localName":"label","attributes":["hidden",""],"children":[
        \\  {"nodeType":1,"localName":"input","backendNodeId":3}]},
        \\ {"nodeType":1,"localName":"label","attributes":["style","display:none"],"children":[
        \\  {"nodeType":1,"localName":"input","backendNodeId":4}]},
        \\ {"nodeType":1,"localName":"label","attributes":["aria-hidden","true"]},
        \\ {"nodeType":1,"localName":"details","attributes":["open",""],"children":[
        \\  {"nodeType":1,"localName":"summary","children":[{"nodeType":3,"nodeValue":"More"}]},
        \\  {"nodeType":1,"localName":"label","children":[
        \\   {"nodeType":3,"nodeValue":"Notify me"},
        \\   {"nodeType":1,"localName":"span","children":[{"nodeType":1,"localName":"input","backendNodeId":5,"attributes":["type","hidden"]}]},
        \\   {"nodeType":1,"localName":"input","backendNodeId":6,"attributes":["type","checkbox"]}]}]}]}]}}
    ;
    var tree = try ax.parseDomDocument(gpa, j, .{});
    defer tree.deinit();
    for ([_]i64{ 2, 3, 4 }) |b| try testing.expect(tree.isHidden(tree.findByBackendId(b, null).?));
    // The first labelable descendant skips hidden ones (input[type=hidden]).
    try testing.expectEqualStrings("Notify me", tree.get(tree.findByBackendId(6, null).?).name);
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    const text = try renderText(&tree, &table, .{ .interactive = true });
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\- document ""
        \\- button "Options" [ref=e1] [expanded=false]
        \\- button "More" [ref=e2] [expanded]
        \\- checkbox "Notify me" [ref=e3]
    , text);
}

test "unit: browser: inline style visibility and cursor heuristics" {
    try testing.expect(ax.parseStyle("display:none").hidden);
    try testing.expect(ax.parseStyle("color: red; DISPLAY : None !important").hidden);
    try testing.expect(ax.parseStyle("visibility:hidden").hidden);
    try testing.expect(ax.parseStyle("opacity: 0.01").hidden);
    try testing.expect(ax.parseStyle("opacity: 0%").hidden);
    try testing.expect(!ax.parseStyle("opacity: 0.5").hidden);
    try testing.expect(!ax.parseStyle("opacity: bogus").hidden);
    try testing.expect(!ax.parseStyle("display:block;;;:").hidden);
    try testing.expect(ax.parseStyle("cursor: pointer").pointer);
    try testing.expect(!ax.parseStyle("").pointer);
}

test "unit: browser: annotateFromDom copies attributes and hidden state onto ax nodes" {
    var a = try ax.parseAxTree(gpa, ax_login, .{});
    defer a.deinit();
    var d = try ax.parseDomDocument(gpa, dom_login, .{});
    // Free the DOM tree first: the AX tree must own its copies.
    {
        defer d.deinit();
        try a.annotateFromDom(&d);
    }
    const email = a.get(a.findByBackendId(21, null).?);
    // backend 21 is the <script> in the DOM fixture: the copy marks it hidden.
    try testing.expectEqualStrings("script", email.tag);
    try testing.expect(email.hidden);
    const heading = a.get(a.findByBackendId(3, null).?);
    try testing.expectEqualStrings("html", heading.tag);
}

// ---------------------------------------------------------------------------
// snapshot

test "unit: browser: snapshot interactive login form yields e1 e2 e3 (acceptance)" {
    var tree = try ax.parseAxTree(gpa, ax_login, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    const text = try renderText(&tree, &table, .{ .interactive = true, .states = false });
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\- document "Sign in"
        \\- textbox "Email" [ref=e1]
        \\- textbox "Password" [ref=e2]
        \\- button "Sign in" [ref=e3]
    , text);
    try testing.expectEqual(@as(usize, 3), table.count());
    try testing.expectEqual(@as(?i64, 23), (try table.lookup("@e3")).backend_node_id);
}

test "unit: browser: snapshot full mode includes content roles and states" {
    var tree = try ax.parseAxTree(gpa, ax_login, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    const text = try renderText(&tree, &table, .{});
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\- document "Sign in"
        \\- heading "Welcome back" [ref=e1] [level=1]
        \\- textbox "Email" [ref=e2] [required]
        \\- textbox "Password" [ref=e3]
        \\- button "Sign in" [ref=e4]
    , text);
}

test "unit: browser: snapshot of dom login form skips hidden and script content" {
    var tree = try ax.parseDomDocument(gpa, dom_login, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    const text = try renderText(&tree, &table, .{});
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\- document "Login 'Portal'"
        \\- main "" [ref=e1]
        \\  - textbox "Email" [ref=e2]
        \\  - textbox "Password" [ref=e3]
        \\  - button "Sign in" [ref=e4]
    , text);
    // Refs carry CSS paths usable with querySelector.
    try testing.expectEqualStrings("#email", (try table.lookup("e2")).css_path.?);
    try testing.expectEqualStrings("#login > label:nth-of-type(2) > input", (try table.lookup("e3")).css_path.?);
    try testing.expectEqualStrings("html > body > main", (try table.lookup("e1")).css_path.?);
}

test "unit: browser: snapshot with a request arena keeps refs in the table allocator" {
    // W2-8 renders with a per-request arena into a long-lived per-surface
    // table. css paths used to be stored straight from the arena: they
    // dangled after the request and table.deinit freed them with the wrong
    // allocator ("Invalid free").
    var tree = try ax.parseDomDocument(gpa, dom_login, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const snap = try snapshot.render(arena.allocator(), &tree, &table, .{});
        try testing.expectEqual(@as(usize, 4), snap.element_count);
        // find + register through the same arena (the form is not in the snapshot).
        const form = (try locators.findOne(arena.allocator(), &tree, .{ .kind = .first, .value = "form" }, null)).?;
        try testing.expectEqual(@as(u32, 5), try locators.register(arena.allocator(), &tree, &table, form));
    }
    try testing.expectEqualStrings("#email", (try table.lookup("e2")).css_path.?);
    try testing.expectEqualStrings("#login > button", (try table.lookup("e4")).css_path.?);
    try testing.expectEqualStrings("#login", (try table.lookup("e5")).css_path.?);
}

test "unit: browser: snapshot compact drops unnamed structural roles" {
    var tree = try ax.parseDomDocument(gpa, dom_login, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    const text = try renderText(&tree, &table, .{ .compact = true });
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\- document "Login 'Portal'"
        \\- textbox "Email" [ref=e1]
        \\- textbox "Password" [ref=e2]
        \\- button "Sign in" [ref=e3]
    , text);
}

const dom_nested =
    \\{"root":{"nodeType":9,"nodeName":"#document","backendNodeId":1,"children":[
    \\ {"nodeType":1,"localName":"html","backendNodeId":2,"children":[
    \\  {"nodeType":1,"localName":"body","backendNodeId":3,"children":[
    \\   {"nodeType":1,"localName":"nav","backendNodeId":4,"attributes":["aria-label","Primary"],"children":[
    \\    {"nodeType":1,"localName":"ul","backendNodeId":5,"children":[
    \\     {"nodeType":1,"localName":"li","backendNodeId":6,"children":[
    \\      {"nodeType":1,"localName":"a","backendNodeId":7,"attributes":["href","/","title","Go home"],"children":[
    \\       {"nodeType":3,"nodeValue":"Home","backendNodeId":8}]}]},
    \\     {"nodeType":1,"localName":"li","backendNodeId":9,"children":[
    \\      {"nodeType":1,"localName":"a","backendNodeId":10,"attributes":["href","/docs"],"children":[
    \\       {"nodeType":3,"nodeValue":"Docs","backendNodeId":11}]}]}]}]},
    \\   {"nodeType":1,"localName":"div","backendNodeId":12,"attributes":["onclick","go()","class","card"],"children":[
    \\    {"nodeType":3,"nodeValue":"Clickable card","backendNodeId":13}]},
    \\   {"nodeType":1,"localName":"span","backendNodeId":14,"attributes":["style","cursor:pointer"],"children":[
    \\    {"nodeType":3,"nodeValue":"Pointer","backendNodeId":15}]},
    \\   {"nodeType":1,"localName":"details","backendNodeId":16,"children":[
    \\    {"nodeType":1,"localName":"summary","backendNodeId":17,"children":[{"nodeType":3,"nodeValue":"More","backendNodeId":18}]},
    \\    {"nodeType":1,"localName":"button","backendNodeId":19,"children":[{"nodeType":3,"nodeValue":"Inside","backendNodeId":20}]}]}
    \\]}]}]}}
;

test "unit: browser: snapshot indents two spaces per emitted ancestor" {
    var tree = try ax.parseDomDocument(gpa, dom_nested, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    const text = try renderText(&tree, &table, .{});
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\- document ""
        \\- navigation "Primary" [ref=e1]
        \\  - listitem "" [ref=e2]
        \\    - link "Go home" [ref=e3]
        \\  - listitem "" [ref=e4]
        \\    - link "Docs" [ref=e5]
        \\- button "More" [ref=e6] [expanded=false]
    , text);
}

test "unit: browser: snapshot max depth limits emitted nesting" {
    var tree = try ax.parseDomDocument(gpa, dom_nested, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    const one = try renderText(&tree, &table, .{ .max_depth = 1 });
    defer gpa.free(one);
    try testing.expectEqualStrings(
        \\- document ""
        \\- navigation "Primary" [ref=e1]
        \\- button "More" [ref=e2] [expanded=false]
    , one);
    const zero = try renderText(&tree, &table, .{ .max_depth = 0 });
    defer gpa.free(zero);
    try testing.expectEqualStrings(
        \\- document ""
        \\- text "Home Docs Clickable card Pointer More"
    , zero);
    try testing.expectEqual(@as(usize, 0), table.count());
}

test "unit: browser: snapshot cursor adds clickable generics" {
    var tree = try ax.parseDomDocument(gpa, dom_nested, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    const text = try renderText(&tree, &table, .{ .interactive = true, .cursor = true });
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\- document ""
        \\- link "Go home" [ref=e1]
        \\- link "Docs" [ref=e2]
        \\- generic "Clickable card" [ref=e3]
        \\- generic "Pointer" [ref=e4]
        \\- button "More" [ref=e5] [expanded=false]
    , text);
}

test "unit: browser: snapshot cursor generics are capped at 256" {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, "{\"root\":{\"nodeType\":9,\"children\":[{\"nodeType\":1,\"localName\":\"body\",\"children\":[");
    for (0..300) |i| {
        if (i > 0) try json.append(gpa, ',');
        try json.print(gpa, "{{\"nodeType\":1,\"localName\":\"div\",\"backendNodeId\":{d},\"attributes\":[\"tabindex\",\"0\"]}}", .{i + 10});
    }
    try json.appendSlice(gpa, "]}]}}");
    var tree = try ax.parseDomDocument(gpa, json.items, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    var snap = try snapshot.render(gpa, &tree, &table, .{ .cursor = true });
    defer snap.deinit();
    try testing.expectEqual(snapshot.cursor_limit, snap.element_count);
    try testing.expectEqual(snapshot.cursor_limit, table.count());
}

test "unit: browser: snapshot cursor cap counts only printed generics" {
    // 300 clickable divs sit below max_depth (not printed); they used to use
    // up the 256 cap so the top-level clickable "Last" was dropped.
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, "{\"root\":{\"nodeType\":9,\"children\":[{\"nodeType\":1,\"localName\":\"body\",\"children\":[");
    for (0..300) |i| {
        try json.print(gpa, "{{\"nodeType\":1,\"localName\":\"nav\",\"backendNodeId\":{d},\"children\":[{{\"nodeType\":1,\"localName\":\"div\",\"attributes\":[\"tabindex\",\"0\"]}}]}},", .{i + 10});
    }
    try json.appendSlice(gpa, "{\"nodeType\":1,\"localName\":\"div\",\"backendNodeId\":5,\"attributes\":[\"onclick\",\"f()\"],\"children\":[{\"nodeType\":3,\"nodeValue\":\"Last\"}]}]}]}}");
    var tree = try ax.parseDomDocument(gpa, json.items, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    var snap = try snapshot.render(gpa, &tree, &table, .{ .cursor = true, .max_depth = 1 });
    defer snap.deinit();
    try testing.expectEqual(@as(usize, 301), snap.element_count);
    try testing.expect(std.mem.endsWith(u8, snap.text, "\n- generic \"Last\" [ref=e301]"));
}

test "unit: browser: blank aria-label does not hide the label element" {
    const j =
        \\{"root":{"nodeType":9,"children":[{"nodeType":1,"localName":"body","children":[
        \\ {"nodeType":1,"localName":"label","attributes":["for","e"],"children":[{"nodeType":3,"nodeValue":"Email"}]},
        \\ {"nodeType":1,"localName":"input","backendNodeId":3,"attributes":["id","e","aria-label"," "]}]}]}}
    ;
    var tree = try ax.parseDomDocument(gpa, j, .{});
    defer tree.deinit();
    const n = tree.get(tree.findByBackendId(3, null).?);
    try testing.expectEqualStrings("Email", n.name);
    try testing.expectEqualStrings("Email", n.label);
    try testing.expectEqual(@as(?i64, 3), try findBackend(&tree, .{ .kind = .label, .value = "email" }));
}

test "unit: browser: snapshot selector scoping by css and by ref" {
    var tree = try ax.parseDomDocument(gpa, dom_nested, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    const scoped = try renderText(&tree, &table, .{ .selector = "nav > ul li" });
    defer gpa.free(scoped);
    try testing.expectEqualStrings(
        \\- document ""
        \\- listitem "" [ref=e1]
        \\  - link "Go home" [ref=e2]
    , scoped);
    // Scope by a ref from the previous snapshot: e2 is the Home link.
    const by_ref = try renderText(&tree, &table, .{ .selector = "@e2" });
    defer gpa.free(by_ref);
    try testing.expectEqualStrings(
        \\- document ""
        \\- link "Go home" [ref=e1]
    , by_ref);
    try testing.expectError(error.ElementNotFound, snapshot.render(gpa, &tree, &table, .{ .selector = "#nope" }));
    try testing.expectError(error.UnsupportedSelector, snapshot.render(gpa, &tree, &table, .{ .selector = "li:first-child" }));
    try testing.expectError(error.InvalidSelector, snapshot.render(gpa, &tree, &table, .{ .selector = "li[" }));
    try testing.expectError(error.RefNotFound, snapshot.render(gpa, &tree, &table, .{ .selector = "e99" }));
    // A failed scope does not clobber the current ref set.
    try testing.expectEqual(@as(usize, 1), table.count());
}

fn axDoc(comptime body: []const u8) []const u8 {
    return "{\"nodes\":[{\"nodeId\":\"1\",\"role\":{\"type\":\"internalRole\",\"value\":\"RootWebArea\"},\"name\":{\"type\":\"computedString\",\"value\":\"T\"},\"childIds\":[\"2\"]}," ++ body ++ "]}";
}

test "unit: browser: snapshot empty page falls back to text excerpt or (empty)" {
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    {
        var tree = try ax.parseAxTree(gpa, axDoc(
            \\{"nodeId":"2","role":{"type":"role","value":"paragraph"},"childIds":["3"],"parentId":"1"},
            \\{"nodeId":"3","role":{"type":"internalRole","value":"StaticText"},"name":{"type":"computedString","value":"  Just \"some\"\n text  "},"parentId":"2"}
        ), .{});
        defer tree.deinit();
        const text = try renderText(&tree, &table, .{});
        defer gpa.free(text);
        try testing.expectEqualStrings("- document \"T\"\n- text \"Just 'some' text\"", text);
    }
    {
        var tree = try ax.parseAxTree(gpa, axDoc(
            \\{"nodeId":"2","role":{"type":"role","value":"generic"},"parentId":"1"}
        ), .{});
        defer tree.deinit();
        const text = try renderText(&tree, &table, .{});
        defer gpa.free(text);
        try testing.expectEqualStrings("- document \"T\"\n- (empty)", text);
    }
    {
        // A bare document node (no body) renders as empty.
        var tree = try ax.parseDomDocument(gpa, "{\"root\":{\"nodeType\":9}}", .{});
        defer tree.deinit();
        const text = try renderText(&tree, &table, .{});
        defer gpa.free(text);
        try testing.expectEqualStrings("- document \"\"\n- (empty)", text);
    }
}

test "unit: browser: snapshot text excerpt is capped at 240 code points" {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, "{\"root\":{\"nodeType\":9,\"children\":[{\"nodeType\":1,\"localName\":\"body\",\"children\":[{\"nodeType\":3,\"nodeValue\":\"");
    for (0..500) |_| try json.appendSlice(gpa, "\u{00e9}");
    try json.appendSlice(gpa, "\"}]}]}}");
    var tree = try ax.parseDomDocument(gpa, json.items, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    const text = try renderText(&tree, &table, .{});
    defer gpa.free(text);
    const prefix = "- document \"\"\n- text \"";
    try testing.expect(std.mem.startsWith(u8, text, prefix));
    const inner = text[prefix.len .. text.len - 1];
    try testing.expectEqual(@as(usize, 240), try std.unicode.utf8CountCodepoints(inner));
}

test "unit: browser: snapshot prints only known roles" {
    // Explicit roles come from page markup and are printed verbatim. A
    // "menuitem" prefix used to be enough to pass, so a role carrying an
    // escape sequence reached the terminal that prints the snapshot.
    const j =
        \\{"root":{"nodeType":9,"children":[{"nodeType":1,"localName":"body","children":[
        \\ {"nodeType":1,"localName":"div","attributes":["role","menuitem\u001b]0;pwned\u0007\u001b[31m"],"children":[{"nodeType":3,"nodeValue":"x"}]},
        \\ {"nodeType":1,"localName":"div","attributes":["role","menuitemfoo"],"children":[{"nodeType":3,"nodeValue":"y"}]},
        \\ {"nodeType":1,"localName":"div","attributes":["role","MenuItemCheckbox","aria-checked","true"],"children":[{"nodeType":3,"nodeValue":"Wrap"}]},
        \\ {"nodeType":1,"localName":"div","attributes":["role","menuitemradio"],"children":[{"nodeType":3,"nodeValue":"Left"}]}]}]}}
    ;
    var tree = try ax.parseDomDocument(gpa, j, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    const text = try renderText(&tree, &table, .{ .cursor = true });
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\- document ""
        \\- menuitemcheckbox "Wrap" [ref=e1] [checked]
        \\- menuitemradio "Left" [ref=e2]
    , text);
    for (text) |c| try testing.expect(c >= 0x20 or c == '\n');
    try testing.expect(!ax.isInteractiveRole("menuitemfoo"));
}

test "unit: browser: snapshot names are sanitized, unicode-safe and capped at 120" {
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(gpa);
    for (0..200) |_| try long.appendSlice(gpa, "\u{1F600}");
    const s1 = try snapshot.sanitize(gpa, long.items, snapshot.name_max_chars);
    defer gpa.free(s1);
    try testing.expectEqual(@as(usize, 120), try std.unicode.utf8CountCodepoints(s1));
    const s2 = try snapshot.sanitize(gpa, "\t a \"b\"\r\n\x00c  ", 120);
    defer gpa.free(s2);
    try testing.expectEqualStrings("a 'b' c", s2);
    // Malformed UTF-8 is replaced, never passed through.
    const s3 = try snapshot.sanitize(gpa, "ok\xff\xc3", 120);
    defer gpa.free(s3);
    try testing.expect(std.unicode.utf8ValidateSlice(s3));
    try testing.expectEqualStrings("ok\u{FFFD}\u{FFFD}", s3);
    const s4 = try snapshot.sanitize(gpa, "", 120);
    defer gpa.free(s4);
    try testing.expectEqualStrings("", s4);
    const s5 = try snapshot.sanitize(gpa, "abc", 0);
    defer gpa.free(s5);
    try testing.expectEqualStrings("", s5);
}

test "unit: browser: snapshot shows values for textboxes and hides them when disabled" {
    const j =
        \\{"root":{"nodeType":9,"children":[{"nodeType":1,"localName":"body","children":[
        \\ {"nodeType":1,"localName":"input","backendNodeId":5,"attributes":["aria-label","Q","value","zig \"0.15\""]},
        \\ {"nodeType":1,"localName":"select","backendNodeId":6,"attributes":["aria-label","Size"],"children":[
        \\  {"nodeType":1,"localName":"option","children":[{"nodeType":3,"nodeValue":"S"}]},
        \\  {"nodeType":1,"localName":"option","attributes":["selected",""],"children":[{"nodeType":3,"nodeValue":"M"}]}]},
        \\ {"nodeType":1,"localName":"textarea","backendNodeId":7,"attributes":["placeholder","Notes","readonly",""],"children":[{"nodeType":3,"nodeValue":"line1\nline2"}]},
        \\ {"nodeType":1,"localName":"input","backendNodeId":8,"attributes":["type","checkbox","checked","","disabled",""]}
        \\]}]}}
    ;
    var tree = try ax.parseDomDocument(gpa, j, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    const text = try renderText(&tree, &table, .{ .interactive = true });
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\- document ""
        \\- textbox "Q" [ref=e1]: zig '0.15'
        \\- combobox "Size" [ref=e2]: M
        \\  - option "S" [ref=e3]
        \\  - option "M" [ref=e4] [selected]
        \\- textbox "Notes" [ref=e5] [readonly]: line1 line2
        \\- checkbox "" [ref=e6] [checked] [disabled]
    , text);
    const bare = try renderText(&tree, &table, .{ .interactive = true, .states = false, .values = false });
    defer gpa.free(bare);
    try testing.expect(std.mem.indexOf(u8, bare, "[checked]") == null);
    try testing.expect(std.mem.indexOf(u8, bare, ": M") == null);
}

test "unit: browser: snapshot of huge flat page" {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, "{\"root\":{\"nodeType\":9,\"children\":[{\"nodeType\":1,\"localName\":\"body\",\"children\":[");
    const count = 5000;
    for (0..count) |i| {
        if (i > 0) try json.append(gpa, ',');
        try json.print(gpa, "{{\"nodeType\":1,\"localName\":\"button\",\"backendNodeId\":{d},\"children\":[{{\"nodeType\":3,\"nodeValue\":\"b{d}\"}}]}}", .{ i + 100, i });
    }
    try json.appendSlice(gpa, "]}]}}");
    var tree = try ax.parseDomDocument(gpa, json.items, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    var snap = try snapshot.render(gpa, &tree, &table, .{});
    defer snap.deinit();
    try testing.expectEqual(@as(usize, count), snap.element_count);
    try testing.expect(std.mem.endsWith(u8, snap.text, "- button \"b4999\" [ref=e5000]"));
    try testing.expectEqualStrings("body > button:nth-of-type(5000)", (try table.lookup("e5000")).css_path.?);
}

test "unit: browser: deeply nested page does not overflow the stack" {
    // Every walk is iterative; 10k levels would overflow a recursive walker
    // in Debug on a default 1 MiB Windows thread stack.
    const depth = 10000;
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, "{\"root\":{\"nodeType\":9,\"children\":[{\"nodeType\":1,\"localName\":\"body\",\"children\":[");
    for (0..depth) |_| try json.appendSlice(gpa, "{\"nodeType\":1,\"localName\":\"li\",\"children\":[");
    try json.appendSlice(gpa, "{\"nodeType\":3,\"nodeValue\":\"deep\"}");
    for (0..depth) |_| try json.appendSlice(gpa, "]}");
    try json.appendSlice(gpa, "]}]}}");
    var tree = try ax.parseDomDocument(gpa, json.items, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    var snap = try snapshot.render(gpa, &tree, &table, .{});
    defer snap.deinit();
    try testing.expectEqual(@as(usize, snapshot.default_max_depth), snap.element_count);
    // 1000 levels are all emitted; refs deeper than the CSS path cap carry no
    // css_path (the integrator resolves those by backend id).
    var snap2 = try snapshot.render(gpa, &tree, &table, .{ .max_depth = 1000 });
    defer snap2.deinit();
    try testing.expectEqual(@as(usize, 1000), snap2.element_count);
    try testing.expect((try table.lookup("e1")).css_path != null);
    try testing.expect((try table.lookup("e1000")).css_path == null);
    const text = try tree.innerText(gpa, tree.root, 0, false);
    defer gpa.free(text);
    try testing.expectEqualStrings("deep", text);
    const found = try locators.findOne(gpa, &tree, .{ .kind = .role, .value = "listitem" }, null);
    try testing.expect(found != null);
}

test "unit: browser: snapshot options from socket params" {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"interactive":true,"cursor":false,"compact":true,"max_depth":3,"selector":"#main"}
    , .{});
    defer parsed.deinit();
    const o = try snapshot.Options.fromParams(parsed.value.object);
    try testing.expect(o.interactive and o.compact and !o.cursor);
    try testing.expectEqual(@as(u32, 3), o.max_depth);
    try testing.expectEqualStrings("#main", o.selector.?);

    var empty = try std.json.parseFromSlice(std.json.Value, gpa, "{\"selector\":\"  \",\"max_depth\":null}", .{});
    defer empty.deinit();
    const d = try snapshot.Options.fromParams(empty.value.object);
    try testing.expectEqual(snapshot.default_max_depth, d.max_depth);
    try testing.expect(d.selector == null and !d.interactive);

    const bad = [_][]const u8{ "{\"interactive\":\"yes\"}", "{\"max_depth\":-1}", "{\"max_depth\":1.5}", "{\"selector\":5}" };
    for (bad) |b| {
        var p = try std.json.parseFromSlice(std.json.Value, gpa, b, .{});
        defer p.deinit();
        try testing.expectError(error.InvalidParams, snapshot.Options.fromParams(p.value.object));
    }
}

test "unit: browser: snapshot-after options use post-action defaults" {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"snapshot_after\":true}", .{});
    defer parsed.deinit();
    const o = try snapshot.Options.fromPostActionParams(parsed.value.object);
    try testing.expect(o.interactive and o.compact and !o.cursor);
    try testing.expectEqual(@as(u32, 10), o.max_depth);
    try testing.expect(o.selector == null);
    var p2 = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"snapshot_interactive":false,"snapshot_compact":false,"snapshot_cursor":true,"snapshot_max_depth":4,"snapshot_selector":"form"}
    , .{});
    defer p2.deinit();
    const o2 = try snapshot.Options.fromPostActionParams(p2.value.object);
    try testing.expect(!o2.interactive and !o2.compact and o2.cursor);
    try testing.expectEqual(@as(u32, 4), o2.max_depth);
    try testing.expectEqualStrings("form", o2.selector.?);
}

test "unit: browser: snapshot options from cli args" {
    const o = try snapshot.Options.fromArgs(&.{ "-i", "--cursor", "--compact", "--max-depth", "5", "--selector", "#app" });
    try testing.expect(o.interactive and o.cursor and o.compact);
    try testing.expectEqual(@as(u32, 5), o.max_depth);
    try testing.expectEqualStrings("#app", o.selector.?);
    const o2 = try snapshot.Options.fromArgs(&.{ "--interactive", "--max-depth=0", "--selector=div > p" });
    try testing.expectEqual(@as(u32, 0), o2.max_depth);
    try testing.expectEqualStrings("div > p", o2.selector.?);
    const o3 = try snapshot.Options.fromArgs(&.{});
    try testing.expectEqual(snapshot.default_max_depth, o3.max_depth);
    try testing.expectError(error.UnknownFlag, snapshot.Options.fromArgs(&.{"--bogus"}));
    try testing.expectError(error.MissingValue, snapshot.Options.fromArgs(&.{"--max-depth"}));
    try testing.expectError(error.InvalidNumber, snapshot.Options.fromArgs(&.{ "--max-depth", "-3" }));
    try testing.expectError(error.InvalidNumber, snapshot.Options.fromArgs(&.{ "--max-depth", "99999999999" }));
    try testing.expectError(error.MissingValue, snapshot.Options.fromArgs(&.{"--selector="}));
    try testing.expectError(error.UnexpectedArgument, snapshot.Options.fromArgs(&.{"extra"}));
}

test "unit: browser: snapshot json payload shape" {
    var tree = try ax.parseAxTree(gpa, ax_login, .{ .url = "https://example.test/login" });
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    var snap = try snapshot.render(gpa, &tree, &table, .{ .interactive = true });
    defer snap.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try snapshot.writeJson(gpa, &s, &snap, &tree, &table, .{ .ready_state = "complete" });
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, aw.written(), .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqualStrings(snap.text, o.get("snapshot").?.string);
    try testing.expectEqualStrings("Sign in", o.get("title").?.string);
    try testing.expectEqualStrings("https://example.test/login", o.get("url").?.string);
    try testing.expectEqualStrings("complete", o.get("ready_state").?.string);
    const r = o.get("refs").?.object;
    try testing.expectEqual(@as(usize, 3), r.count());
    try testing.expectEqualStrings("textbox", r.get("e1").?.object.get("role").?.string);
    try testing.expectEqualStrings("Sign in", r.get("e3").?.object.get("name").?.string);
    const page = o.get("page").?.object;
    try testing.expectEqualStrings("Welcome back", page.get("text").?.string);
    try testing.expectEqualStrings("", page.get("html").?.string);
}

test "unit: browser: empty snapshot hints for blank urls" {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try snapshot.writeEmptyHints(&aw.writer, "surface:2", "about:blank", "complete");
    try testing.expectEqualStrings(
        "url: about:blank\nready_state: complete\nhint: run 'cmux browser surface:2 get url' to verify navigation\n",
        aw.written(),
    );
    aw.clearRetainingCapacity();
    try snapshot.writeEmptyHints(&aw.writer, "surface:2", "https://x.test/", "loading");
    try testing.expectEqualStrings("url: https://x.test/\nready_state: loading\n", aw.written());
    aw.clearRetainingCapacity();
    try snapshot.writeEmptyHints(&aw.writer, "s", "", "");
    try testing.expect(std.mem.indexOf(u8, aw.written(), "hint: ") != null);
}

test "unit: browser: snapshot excerpt keeps the first lines" {
    try testing.expectEqualStrings("a\nb", snapshot.excerpt("a\nb\nc", 2));
    try testing.expectEqualStrings("a\nb\nc", snapshot.excerpt("a\nb\nc", 9));
    try testing.expectEqualStrings("", snapshot.excerpt("", 3));
    try testing.expectEqualStrings("a", snapshot.excerpt("a\nb", 1));
    try testing.expectEqualStrings("", snapshot.excerpt("a\nb", 0));
    try testing.expectEqualStrings("", snapshot.excerpt("abc", 0));
}

// ---------------------------------------------------------------------------
// refs

test "unit: browser: ref token parsing" {
    try testing.expectEqual(@as(?u32, 3), refs.parseRefToken("e3"));
    try testing.expectEqual(@as(?u32, 3), refs.parseRefToken("@e3"));
    try testing.expectEqual(@as(?u32, 12), refs.parseRefToken(" ref=e12 "));
    try testing.expectEqual(@as(?u32, 4294967295), refs.parseRefToken("e4294967295"));
    const bad = [_][]const u8{ "", "e", "@", "@e", "e0", "e01", "E3", "e-1", "e+1", "e3x", "#e3", "e4294967296", "@@e1", "ref=", "ee1", "e 1", "e\u{0663}" };
    for (bad) |b| try testing.expectEqual(@as(?u32, null), refs.parseRefToken(b));
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("e4294967295", refs.formatRef(&buf, std.math.maxInt(u32)));
}

test "unit: browser: ref table lifecycle and invalidation on navigation" {
    var t = refs.RefTable.init(gpa);
    defer t.deinit();
    t.beginSnapshot();
    const e1 = try t.add(.{ .backend_node_id = 10, .role = "button", .name = "Go", .css_path = "#go" });
    const e2 = try t.add(.{ .backend_node_id = 11, .frame_id = "F2", .role = "link", .name = "In frame" });
    try testing.expectEqual(@as(u32, 1), e1);
    try testing.expectEqual(@as(u32, 2), e2);
    // Same element -> same ref (find after snapshot).
    try testing.expectEqual(e1, try t.add(.{ .backend_node_id = 10, .role = "button", .name = "Go" }));
    // Same backend id in another frame is a different element.
    try testing.expectEqual(@as(u32, 3), try t.add(.{ .backend_node_id = 10, .frame_id = "F2" }));
    try testing.expectEqualStrings("#go", (try t.lookup("e1")).css_path.?);
    try testing.expectError(error.RefNotFound, t.lookup("e9"));
    try testing.expectError(error.InvalidRef, t.lookup("button"));

    // Subframe navigation drops only that frame's refs.
    try t.setSelectedFrame("F2");
    const g = t.generation;
    t.onNavigation("F2", false);
    try testing.expect(t.generation != g);
    try testing.expect(t.selected_frame == null);
    _ = try t.lookup("e1");
    try testing.expectError(error.RefNotFound, t.lookup("e2"));
    // Unrelated subframe: nothing changes.
    const g2 = t.generation;
    t.onNavigation("F9", false);
    try testing.expectEqual(g2, t.generation);

    // Main-frame navigation drops everything (acceptance: click e3 -> not_found).
    try t.setSelectedFrame("F3");
    t.onNavigation(null, true);
    try testing.expectError(error.RefNotFound, t.lookup("@e1"));
    try testing.expectEqual(@as(usize, 0), t.count());
    try testing.expect(t.selected_frame == null);

    // A new snapshot restarts numbering.
    t.beginSnapshot();
    try testing.expectEqual(@as(u32, 1), try t.add(.{ .backend_node_id = 99 }));
}

test "unit: browser: ref table node removal and document updates" {
    var t = refs.RefTable.init(gpa);
    defer t.deinit();
    _ = try t.add(.{ .backend_node_id = 1, .role = "a" });
    _ = try t.add(.{ .backend_node_id = 2, .role = "b" });
    _ = try t.add(.{ .role = "no backend id" });
    t.onNodeRemoved(1);
    try testing.expectError(error.RefNotFound, t.lookup("e1"));
    try testing.expectEqualStrings("b", (try t.lookup("e2")).role);
    // Refs are never renumbered by removals.
    try testing.expectEqual(@as(u32, 4), try t.add(.{ .backend_node_id = 7 }));
    // A replaced document drops the refs and the selected frame.
    try t.setSelectedFrame("F1");
    const g = t.generation;
    t.onDocumentUpdated();
    try testing.expectEqual(@as(usize, 0), t.count());
    try testing.expect(t.selected_frame == null);
    try testing.expect(t.generation != g);
    try testing.expectError(error.RefNotFound, t.lookup("e4"));
}

test "unit: browser: ref table json and unicode names" {
    var t = refs.RefTable.init(gpa);
    defer t.deinit();
    _ = try t.add(.{ .backend_node_id = 1, .role = "button", .name = "Envoyer \u{2709}" });
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try t.writeJson(&s);
    try testing.expectEqualStrings("{\"e1\":{\"role\":\"button\",\"name\":\"Envoyer \u{2709}\"}}", aw.written());
}

test "unit: browser: ref table add leaves no leaks on allocation failure" {
    // Exercise every allocation point in `add`.
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = i });
        var t = refs.RefTable.init(failing.allocator());
        defer t.deinit();
        _ = t.add(.{ .backend_node_id = 1, .frame_id = "F", .role = "r", .name = "n", .css_path = "#x" }) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), t.count());
            continue;
        };
        try testing.expectEqual(@as(usize, 1), t.count());
    }
}

test "unit: browser: selector param keys in priority order" {
    var p = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"ref":"e2","element_ref":"@e5","sel":"  ","selector":7}
    , .{});
    defer p.deinit();
    try testing.expectEqualStrings("@e5", refs.selectorFromParams(p.value.object).?);
    var p2 = try std.json.parseFromSlice(std.json.Value, gpa, "{\"selector\":\"#a\",\"ref\":\"e1\"}", .{});
    defer p2.deinit();
    try testing.expectEqualStrings("#a", refs.selectorFromParams(p2.value.object).?);
    var p3 = try std.json.parseFromSlice(std.json.Value, gpa, "{}", .{});
    defer p3.deinit();
    try testing.expect(refs.selectorFromParams(p3.value.object) == null);
}

test "unit: browser: error mapping uses cmux strings" {
    const r = refs.errorInfo(error.RefNotFound);
    try testing.expectEqualStrings("not_found", r.code);
    try testing.expectEqualStrings("Element reference not found", r.message);
    const e = refs.errorInfo(error.ElementNotFound);
    try testing.expectEqualStrings("not_found", e.code);
    try testing.expectEqualStrings("Element not found", e.message);
    try testing.expectEqualStrings("invalid_params", refs.errorInfo(error.InvalidSelector).code);
    try testing.expectEqualStrings("not_supported", refs.errorInfo(error.UnsupportedSelector).code);
    try testing.expectEqualStrings("internal_error", refs.errorInfo(error.Whatever).code);
}

test "unit: browser: not-found diagnostics payload" {
    const d: refs.Diagnostics = .{
        .selector = "#missing",
        .match_count = 2,
        .visible_match_count = 0,
        .sample = &.{"<button id=\"missing\">"},
        .snapshot_excerpt = "- document \"x\"",
        .title = "x",
        .url = "https://x.test/",
        .action = "click",
        .retry_attempts = 3,
    };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try d.write(&s);
    var p = try std.json.parseFromSlice(std.json.Value, gpa, aw.written(), .{});
    defer p.deinit();
    const o = p.value.object;
    const keys = [_][]const u8{ "selector", "match_count", "visible_match_count", "sample", "snapshot_excerpt", "body_excerpt", "title", "url", "action", "retry_attempts", "hint" };
    for (keys) |k| try testing.expect(o.get(k) != null);
    try testing.expectEqual(@as(i64, 2), o.get("match_count").?.integer);
    try testing.expectEqualStrings(refs.not_found_hint, o.get("hint").?.string);
    try testing.expectEqualStrings("Run 'browser snapshot' to refresh refs, then retry with a more specific selector.", refs.not_found_hint);
}

// ---------------------------------------------------------------------------
// css

fn queryCount(tree: *const ax.Tree, sel: []const u8) !usize {
    var s = try css.parse(gpa, sel);
    defer s.deinit();
    const m = try s.queryAll(gpa, tree, tree.root);
    defer gpa.free(m);
    return m.len;
}

test "unit: browser: css subset matching" {
    var tree = try ax.parseDomDocument(gpa, dom_login, .{});
    defer tree.deinit();
    const cases = [_]struct { []const u8, usize }{
        .{ "input", 2 },
        .{ "INPUT", 2 },
        .{ "*", 13 - 4 }, // visible elements: html body main form label input label input button (hidden ones excluded)
        .{ "#email", 1 },
        .{ "input#email", 1 },
        .{ "button#email", 0 },
        .{ ".btn", 1 },
        .{ ".btn.primary", 1 },
        .{ ".btn.secondary", 0 },
        .{ "[type]", 3 },
        .{ "[type=submit]", 1 },
        .{ "[type=\"password\"]", 1 },
        .{ "[type='PASSWORD' i]", 1 },
        .{ "[type='PASSWORD']", 0 },
        .{ "[placeholder^=you]", 1 },
        .{ "[placeholder$='.com']", 1 },
        .{ "[placeholder*=example]", 1 },
        .{ "[class~=primary]", 1 },
        .{ "[data-testid|=email]", 1 },
        .{ "form input", 2 },
        .{ "form > input", 1 },
        .{ "main > input", 0 },
        .{ "main  label > input", 1 },
        .{ "body main form button", 1 },
        .{ "#login button, #email", 2 },
        .{ "div button", 0 }, // hidden subtree
        .{ "html > body", 1 },
    };
    for (cases) |c| {
        const got = try queryCount(&tree, c[0]);
        if (got != c[1]) {
            std.log.err("selector {s}: expected {d}, got {d}", .{ c[0], c[1], got });
            return error.TestExpectedEqual;
        }
    }
}

test "unit: browser: css combinators match without backtracking" {
    // body > section.a > div.b > div > div.b > span.c
    const j =
        \\{"root":{"nodeType":9,"children":[{"nodeType":1,"localName":"html","children":[{"nodeType":1,"localName":"body","children":[
        \\ {"nodeType":1,"localName":"section","attributes":["class","a"],"children":[
        \\  {"nodeType":1,"localName":"div","attributes":["class","b"],"children":[
        \\   {"nodeType":1,"localName":"div","children":[
        \\    {"nodeType":1,"localName":"div","attributes":["class","b"],"children":[
        \\     {"nodeType":1,"localName":"span","attributes":["class","c"]}]}]}]}]}]}]}]}}
    ;
    var tree = try ax.parseDomDocument(gpa, j, .{});
    defer tree.deinit();
    const cases = [_]struct { []const u8, usize }{
        .{ ".a > .b .c", 1 }, // the nearest .b has no .a parent; a farther one does
        .{ ".a .b > .c", 1 },
        .{ ".a > div > div > .b > .c", 1 },
        .{ ".a > .b > .c", 0 },
        .{ "section > div > div", 1 },
        .{ ".b .b .c", 1 },
        .{ ".b .b .b .c", 0 },
        .{ "body .a > .b > div > .b > .c", 1 },
        .{ "html > body > section div span", 1 },
        .{ "div div", 2 },
    };
    for (cases) |c| {
        const got = try queryCount(&tree, c[0]);
        if (got != c[1]) {
            std.log.err("selector {s}: expected {d}, got {d}", .{ c[0], c[1], got });
            return error.TestExpectedEqual;
        }
    }

    // A failing descendant chain over 40 nested divs: exponential before.
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, "{\"root\":{\"nodeType\":9,\"children\":[{\"nodeType\":1,\"localName\":\"body\",\"children\":[");
    for (0..40) |_| try json.appendSlice(gpa, "{\"nodeType\":1,\"localName\":\"div\",\"children\":[");
    try json.appendSlice(gpa, "{\"nodeType\":1,\"localName\":\"span\"}");
    for (0..40) |_| try json.appendSlice(gpa, "]}");
    try json.appendSlice(gpa, "]}]}}");
    var deep = try ax.parseDomDocument(gpa, json.items, .{});
    defer deep.deinit();
    try testing.expectEqual(@as(usize, 0), try queryCount(&deep, "p div div div div div div span"));
    try testing.expectEqual(@as(usize, 1), try queryCount(&deep, "body div div div div div div span"));
}

test "unit: browser: css parse errors" {
    const invalid = [_][]const u8{ "", "  ", "[", "[a", "[a=", "[a='x", "#", ".", "a,", ",a", "a >", "> a", "[a!=b]", "1abc", "a)", "[a=b c]" };
    for (invalid) |sel| {
        if (css.parse(gpa, sel)) |s| {
            var ss = s;
            ss.deinit();
            std.log.err("selector {s} parsed but should not", .{sel});
            return error.TestUnexpectedResult;
        } else |err| try testing.expectEqual(error.InvalidSelector, err);
    }
    const unsupported = [_][]const u8{ "a:hover", "li:nth-child(2)", "a + b", "a ~ b", "svg|rect", "::before", "#\\31 23" };
    for (unsupported) |sel| try testing.expectError(error.UnsupportedSelector, css.parse(gpa, sel));
}

test "unit: browser: css escapes and unicode identifiers" {
    const j =
        \\{"root":{"nodeType":9,"children":[{"nodeType":1,"localName":"body","children":[
        \\ {"nodeType":1,"localName":"div","attributes":["id","a.b","class","caf\u00e9 x"]},
        \\ {"nodeType":1,"localName":"div","attributes":["data-x","say \"hi\""]}]}]}}
    ;
    var tree = try ax.parseDomDocument(gpa, j, .{});
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 1), try queryCount(&tree, "#a\\.b"));
    try testing.expectEqual(@as(usize, 1), try queryCount(&tree, ".caf\u{00e9}"));
    try testing.expectEqual(@as(usize, 1), try queryCount(&tree, "[data-x='say \"hi\"']"));
    try testing.expectEqual(@as(usize, 1), try queryCount(&tree, "[data-x=\"say \\\"hi\\\"\"]"));
}

const dom_frames =
    \\{"root":{"nodeType":9,"backendNodeId":1,"documentURL":"https://top.test/","children":[
    \\ {"nodeType":1,"localName":"html","backendNodeId":2,"children":[
    \\  {"nodeType":1,"localName":"body","backendNodeId":3,"children":[
    \\   {"nodeType":1,"localName":"button","backendNodeId":4,"attributes":["id","dup"],"children":[{"nodeType":3,"nodeValue":"Top"}]},
    \\   {"nodeType":1,"localName":"iframe","backendNodeId":5,"frameId":"CHILD","attributes":["title","Payment"],
    \\    "contentDocument":{"nodeType":9,"backendNodeId":6,"children":[
    \\     {"nodeType":1,"localName":"html","backendNodeId":7,"children":[
    \\      {"nodeType":1,"localName":"body","backendNodeId":8,"children":[
    \\       {"nodeType":1,"localName":"button","backendNodeId":9,"attributes":["id","dup"],"children":[{"nodeType":3,"nodeValue":"Pay"}]}]}]}]}},
    \\   {"nodeType":1,"localName":"x-card","backendNodeId":10,"shadowRoots":[
    \\     {"nodeType":11,"backendNodeId":11,"children":[
    \\      {"nodeType":1,"localName":"button","backendNodeId":12,"children":[{"nodeType":3,"nodeValue":"Shadow"}]}]}],
    \\    "children":[{"nodeType":1,"localName":"span","backendNodeId":13}]}
    \\]}]}]}}
;

test "unit: browser: iframes and shadow roots carry frame ids and css scope" {
    var tree = try ax.parseDomDocument(gpa, dom_frames, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    const text = try renderText(&tree, &table, .{});
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\- document ""
        \\- button "Top" [ref=e1]
        \\- button "Pay" [ref=e2]
        \\- button "Shadow" [ref=e3]
    , text);
    const pay = try table.lookup("e2");
    try testing.expectEqualStrings("CHILD", pay.frame_id.?);
    try testing.expect((try table.lookup("e1")).frame_id == null);
    // #dup is unique within each document, so both paths use it.
    try testing.expectEqualStrings("#dup", pay.css_path.?);
    try testing.expectEqualStrings("#dup", (try table.lookup("e1")).css_path.?);
    // document.querySelector cannot reach shadow content: "button" would
    // resolve to the "Top" button, so the ref keeps only its backend id.
    try testing.expect((try table.lookup("e3")).css_path == null);
    // CSS queries stay in the queried document, like querySelectorAll: the
    // iframe document and the shadow root are separate scopes.
    try testing.expectEqual(@as(usize, 0), try queryCount(&tree, "iframe button"));
    try testing.expectEqual(@as(usize, 0), try queryCount(&tree, "x-card button"));
    try testing.expectEqual(@as(usize, 1), try queryCount(&tree, "button"));
    try testing.expectEqual(@as(usize, 1), try queryCount(&tree, "body > button"));
    var sel = try css.parse(gpa, "body > button#dup");
    defer sel.deinit();
    const in_frame = try sel.queryAll(gpa, &tree, tree.findByBackendId(6, null).?);
    defer gpa.free(in_frame);
    try testing.expectEqual(@as(usize, 1), in_frame.len);
    try testing.expectEqual(@as(?i64, 9), tree.get(in_frame[0]).backend_id);
    // Lookup by backend id honours the frame.
    try testing.expect(tree.findByBackendId(9, "CHILD") != null);
    try testing.expect(tree.findByBackendId(9, "OTHER") == null);
}

test "unit: browser: css paths only where querySelector finds the same element" {
    // AX-sourced tree annotated with DOM tags: the AX tree has no node for
    // the hidden first button, so an AX-derived "body > button" would make
    // document.querySelector return that hidden button instead.
    const axj =
        \\{"nodes":[
        \\ {"nodeId":"1","role":{"type":"internalRole","value":"RootWebArea"},"childIds":["2"],"backendDOMNodeId":1},
        \\ {"nodeId":"2","ignored":true,"role":{"type":"role","value":"generic"},"childIds":["3"],"backendDOMNodeId":3},
        \\ {"nodeId":"3","role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"Go"},"backendDOMNodeId":6}
        \\]}
    ;
    const domj =
        \\{"root":{"nodeType":9,"backendNodeId":1,"children":[{"nodeType":1,"localName":"html","backendNodeId":2,"children":[{"nodeType":1,"localName":"body","backendNodeId":3,"children":[
        \\ {"nodeType":1,"localName":"button","backendNodeId":5,"attributes":["hidden",""],"children":[{"nodeType":3,"nodeValue":"Old"}]},
        \\ {"nodeType":1,"localName":"button","backendNodeId":6,"children":[{"nodeType":3,"nodeValue":"Go"}]},
        \\ {"nodeType":1,"localName":"my.el-x","backendNodeId":7},
        \\ {"nodeType":1,"localName":"my.el-x","backendNodeId":8,"attributes":["id","card"]},
        \\ {"nodeType":1,"localName":"x-host","backendNodeId":9,"shadowRoots":[{"nodeType":11,"backendNodeId":10,"children":[
        \\  {"nodeType":1,"localName":"input","backendNodeId":11,"attributes":["id","only"]}]}]}]}]}]}}
    ;
    var dom = try ax.parseDomDocument(gpa, domj, .{});
    defer dom.deinit();
    var a = try ax.parseAxTree(gpa, axj, .{});
    defer a.deinit();
    try a.annotateFromDom(&dom);
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    var snap = try snapshot.render(gpa, &a, &table, .{});
    defer snap.deinit();
    try testing.expect((try table.lookup("e1")).css_path == null);
    try testing.expectEqual(@as(?i64, 6), (try table.lookup("e1")).backend_node_id);
    // The find result then names the ref instead of a CSS path.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try locators.writeFindResult(gpa, &s, &a, &table, a.findByBackendId(6, null).?, 1, "find");
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"selector\":\"@e1\"") != null);

    const Case = struct { i64, ?[]const u8 };
    for ([_]Case{
        .{ 6, "html > body > button:nth-of-type(2)" },
        .{ 7, null }, // tag needs escaping
        .{ 8, "#card" }, // the id makes the tag irrelevant
        .{ 9, "html > body > x-host" },
        .{ 11, null }, // shadow content, even with a unique id
    }) |c| {
        const p = try css.cssPath(gpa, &dom, dom.findByBackendId(c[0], null).?);
        defer if (p) |q| gpa.free(q);
        if (c[1]) |want| try testing.expectEqualStrings(want, p.?) else try testing.expect(p == null);
    }
}

test "unit: browser: label for and aria-labelledby resolve ids in their own document" {
    // A payment iframe reusing the page's "email" id: its <label for> must
    // name its own input, not the page's.
    const j =
        \\{"root":{"nodeType":9,"backendNodeId":1,"children":[{"nodeType":1,"localName":"html","backendNodeId":2,"children":[{"nodeType":1,"localName":"body","backendNodeId":3,"children":[
        \\ {"nodeType":1,"localName":"input","backendNodeId":4,"attributes":["id","email","placeholder","Your email"]},
        \\ {"nodeType":1,"localName":"span","backendNodeId":12,"attributes":["id","tip"],"children":[{"nodeType":3,"nodeValue":"Page tip"}]},
        \\ {"nodeType":1,"localName":"iframe","backendNodeId":5,"frameId":"F","contentDocument":{"nodeType":9,"backendNodeId":6,"children":[
        \\  {"nodeType":1,"localName":"html","backendNodeId":7,"children":[{"nodeType":1,"localName":"body","backendNodeId":8,"children":[
        \\   {"nodeType":1,"localName":"label","backendNodeId":9,"attributes":["for","email"],"children":[{"nodeType":3,"nodeValue":"Billing email"}]},
        \\   {"nodeType":1,"localName":"input","backendNodeId":10,"attributes":["id","email"]}]}]}]}},
        \\ {"nodeType":1,"localName":"x-host","backendNodeId":13,"shadowRoots":[{"nodeType":11,"backendNodeId":14,"children":[
        \\  {"nodeType":1,"localName":"button","backendNodeId":15,"attributes":["aria-labelledby","tip"],"children":[{"nodeType":3,"nodeValue":"Own text"}]}]}]}]}]}]}}
    ;
    var tree = try ax.parseDomDocument(gpa, j, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    const text = try renderText(&tree, &table, .{});
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\- document ""
        \\- textbox "Your email" [ref=e1]
        \\- textbox "Billing email" [ref=e2]
        \\- button "Own text" [ref=e3]
    , text);
    try testing.expectEqualStrings("F", (try table.lookup("e2")).frame_id.?);
}

test "unit: browser: css path id uniqueness is per document and precomputed" {
    // 5000 buttons with ids: uniqueness used to be rescanned over the whole
    // tree for every path (7 s in Debug, quadratic).
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, "{\"root\":{\"nodeType\":9,\"children\":[{\"nodeType\":1,\"localName\":\"html\",\"children\":[{\"nodeType\":1,\"localName\":\"body\",\"children\":[");
    try json.appendSlice(gpa, "{\"nodeType\":1,\"localName\":\"x-host\",\"backendNodeId\":1,\"shadowRoots\":[{\"nodeType\":11,\"children\":[{\"nodeType\":1,\"localName\":\"i\",\"attributes\":[\"id\",\"b7\"]}]}]}");
    const count = 5000;
    for (0..count) |i| {
        try json.print(gpa, ",{{\"nodeType\":1,\"localName\":\"button\",\"backendNodeId\":{d},\"attributes\":[\"id\",\"b{d}\"],\"children\":[{{\"nodeType\":3,\"nodeValue\":\"b{d}\"}}]}}", .{ i + 100, i, i });
    }
    try json.appendSlice(gpa, ",{\"nodeType\":1,\"localName\":\"p\",\"attributes\":[\"id\",\"b9\"]}]}]}]}}");
    var tree = try ax.parseDomDocument(gpa, json.items, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    var snap = try snapshot.render(gpa, &tree, &table, .{});
    defer snap.deinit();
    try testing.expectEqual(@as(usize, count), snap.element_count);
    try testing.expectEqualStrings("#b4999", (try table.lookup("e5000")).css_path.?);
    // A shadow tree's "b7" does not clash with the page's.
    try testing.expectEqualStrings("#b7", (try table.lookup("e8")).css_path.?);
    // "b9" appears twice in the page: positional path instead.
    try testing.expectEqualStrings("html > body > button:nth-of-type(10)", (try table.lookup("e10")).css_path.?);
}

test "unit: browser: css path falls back to nth-of-type for duplicate ids" {
    const j =
        \\{"root":{"nodeType":9,"children":[{"nodeType":1,"localName":"html","children":[{"nodeType":1,"localName":"body","children":[
        \\ {"nodeType":1,"localName":"p","attributes":["id","x"]},
        \\ {"nodeType":1,"localName":"div"},
        \\ {"nodeType":1,"localName":"p","attributes":["id","x"]},
        \\ {"nodeType":1,"localName":"p","attributes":["id","1bad"]}]}]}]}}
    ;
    var tree = try ax.parseDomDocument(gpa, j, .{});
    defer tree.deinit();
    var paths: [3]?[]u8 = .{ null, null, null };
    defer for (paths) |p| if (p) |q| gpa.free(q);
    var k: usize = 0;
    for (tree.nodes, 0..) |n, i| {
        if (!std.mem.eql(u8, n.tag, "p")) continue;
        paths[k] = try css.cssPath(gpa, &tree, @intCast(i));
        k += 1;
    }
    try testing.expectEqualStrings("html > body > p:nth-of-type(1)", paths[0].?);
    try testing.expectEqualStrings("html > body > p:nth-of-type(2)", paths[1].?);
    try testing.expectEqualStrings("html > body > p:nth-of-type(3)", paths[2].?);
    try testing.expect((try css.cssPath(gpa, &tree, tree.root)) == null);
}

// ---------------------------------------------------------------------------
// locators

const dom_app =
    \\{"root":{"nodeType":9,"backendNodeId":1,"children":[{"nodeType":1,"localName":"html","backendNodeId":2,"children":[
    \\ {"nodeType":1,"localName":"body","backendNodeId":3,"children":[
    \\  {"nodeType":1,"localName":"h1","backendNodeId":4,"children":[{"nodeType":3,"nodeValue":"Checkout"}]},
    \\  {"nodeType":1,"localName":"p","backendNodeId":5,"children":[
    \\   {"nodeType":3,"nodeValue":"Total: "},
    \\   {"nodeType":1,"localName":"strong","backendNodeId":6,"children":[{"nodeType":3,"nodeValue":"$42.00"}]}]},
    \\  {"nodeType":1,"localName":"input","backendNodeId":7,"attributes":["aria-label","Coupon code","placeholder","SAVE10","title","Enter a coupon"]},
    \\  {"nodeType":1,"localName":"img","backendNodeId":8,"attributes":["alt","Company logo","src","/l.png"]},
    \\  {"nodeType":1,"localName":"button","backendNodeId":9,"attributes":["data-testid","continue-btn"],"children":[{"nodeType":3,"nodeValue":"Continue"}]},
    \\  {"nodeType":1,"localName":"button","backendNodeId":10,"children":[{"nodeType":3,"nodeValue":"Continue  shopping"}]},
    \\  {"nodeType":1,"localName":"button","backendNodeId":11,"attributes":["hidden",""],"children":[{"nodeType":3,"nodeValue":"Continue hidden"}]},
    \\  {"nodeType":1,"localName":"div","backendNodeId":12,"attributes":["role","checkbox","aria-checked","true","aria-labelledby","lbl"]},
    \\  {"nodeType":1,"localName":"span","backendNodeId":13,"attributes":["id","lbl","hidden",""],"children":[{"nodeType":3,"nodeValue":"Gift wrap"}]},
    \\  {"nodeType":1,"localName":"ul","backendNodeId":14,"children":[
    \\   {"nodeType":1,"localName":"li","backendNodeId":15,"attributes":["class","row"],"children":[{"nodeType":3,"nodeValue":"one"}]},
    \\   {"nodeType":1,"localName":"li","backendNodeId":16,"attributes":["class","row"],"children":[{"nodeType":3,"nodeValue":"two"}]},
    \\   {"nodeType":1,"localName":"li","backendNodeId":17,"attributes":["class","row"],"children":[{"nodeType":3,"nodeValue":"three"}]}]}
    \\]}]}]}}
;

fn findBackend(tree: *const ax.Tree, loc: locators.Locator) !?i64 {
    const idx = try locators.findOne(gpa, tree, loc, null) orelse return null;
    return tree.get(idx).backend_id;
}

test "unit: browser: find locators by kind" {
    var tree = try ax.parseDomDocument(gpa, dom_app, .{});
    defer tree.deinit();
    const Case = struct { locators.Locator, ?i64 };
    const cases = [_]Case{
        .{ .{ .kind = .role, .value = "button", .name = "continue" }, 9 },
        .{ .{ .kind = .role, .value = "BUTTON", .name = "Continue", .exact = true }, 9 },
        .{ .{ .kind = .role, .value = "button", .name = "continue shopping", .exact = true }, null },
        .{ .{ .kind = .role, .value = "button", .name = "Continue shopping", .exact = true }, 10 },
        .{ .{ .kind = .role, .value = "button", .name = "hidden" }, null },
        .{ .{ .kind = .role, .value = "heading" }, 4 },
        .{ .{ .kind = .role, .value = "checkbox", .name = "gift" }, 12 },
        .{ .{ .kind = .text, .value = "42.00" }, 6 },
        .{ .{ .kind = .text, .value = "total: $42" }, 5 },
        .{ .{ .kind = .text, .value = "Total: $42.00", .exact = true }, 5 },
        .{ .{ .kind = .text, .value = "checkout", .exact = true }, null },
        .{ .{ .kind = .text, .value = "nowhere" }, null },
        .{ .{ .kind = .label, .value = "coupon" }, 7 },
        .{ .{ .kind = .label, .value = "Gift wrap", .exact = true }, 12 },
        .{ .{ .kind = .placeholder, .value = "save10" }, 7 },
        .{ .{ .kind = .placeholder, .value = "save10", .exact = true }, null },
        .{ .{ .kind = .alt, .value = "logo" }, 8 },
        .{ .{ .kind = .title, .value = "coupon" }, 7 },
        .{ .{ .kind = .testid, .value = "continue-btn", .exact = true }, 9 },
        .{ .{ .kind = .testid, .value = "CONTINUE" }, 9 },
        .{ .{ .kind = .first, .value = "li.row" }, 15 },
        .{ .{ .kind = .last, .value = "li.row" }, 17 },
        .{ .{ .kind = .nth, .value = "li.row", .index = 1 }, 16 },
        .{ .{ .kind = .nth, .value = "li.row", .index = -1 }, 17 },
        .{ .{ .kind = .nth, .value = "li.row", .index = -3 }, 15 },
        .{ .{ .kind = .nth, .value = "li.row", .index = 3 }, null },
        .{ .{ .kind = .nth, .value = "li.row", .index = -4 }, null },
        .{ .{ .kind = .first, .value = "table" }, null },
    };
    for (cases, 0..) |c, i| {
        const got = try findBackend(&tree, c[0]);
        if (got != c[1]) {
            std.log.err("case {d} ({s} {s}): expected {?d}, got {?d}", .{ i, @tagName(c[0].kind), c[0].value, c[1], got });
            return error.TestExpectedEqual;
        }
    }
    try testing.expectError(error.UnsupportedSelector, locators.findOne(gpa, &tree, .{ .kind = .first, .value = "li:first-child" }, null));
}

test "unit: browser: find with scope limits matches" {
    var tree = try ax.parseDomDocument(gpa, dom_app, .{});
    defer tree.deinit();
    const ul = tree.findByBackendId(14, null).?;
    const all = try locators.findAll(gpa, &tree, .{ .kind = .text, .value = "o" }, ul);
    defer gpa.free(all);
    // "one" and "two" (innermost li); "three" has no "o".
    try testing.expectEqual(@as(usize, 2), all.len);
}

test "unit: browser: match text semantics" {
    try testing.expect(locators.matchText("Sign In", "sign in", false));
    try testing.expect(locators.matchText("Sign\n   In now", "sign in", false));
    try testing.expect(!locators.matchText("Sign In", "sign in", true));
    try testing.expect(locators.matchText("  Sign \t In ", "Sign In", true));
    try testing.expect(locators.matchText("anything", "", false));
    try testing.expect(!locators.matchText("anything", "", true));
    try testing.expect(locators.matchText("", "", true));
    try testing.expect(!locators.matchText("", "x", false));
    try testing.expect(locators.matchText("Caf\u{00e9} cr\u{00e8}me", "\u{00e9} cr", false));
    try testing.expect(!locators.matchText("ab", "abc", false));
}

test "unit: browser: locator from socket params" {
    const Case = struct { locators.Kind, []const u8 };
    const ok = [_]Case{
        .{ .role, "{\"role\":\"button\",\"name\":\"Go\",\"exact\":true}" },
        .{ .text, "{\"text\":\"Hello\"}" },
        .{ .label, "{\"label\":\"Email\"}" },
        .{ .placeholder, "{\"placeholder\":\"Search\"}" },
        .{ .alt, "{\"alt\":\"logo\"}" },
        .{ .title, "{\"title\":\"tip\"}" },
        .{ .testid, "{\"testid\":\"x\"}" },
        .{ .first, "{\"selector\":\"li\"}" },
        .{ .last, "{\"sel\":\"li\"}" },
        .{ .nth, "{\"index\":2,\"selector\":\"li\"}" },
        .{ .nth, "{\"index\":\"-1\",\"selector\":\"li\"}" },
    };
    for (ok) |c| {
        var p = try std.json.parseFromSlice(std.json.Value, gpa, c[1], .{});
        defer p.deinit();
        const loc = try locators.fromParams(c[0], p.value.object);
        try testing.expectEqual(c[0], loc.kind);
        try testing.expect(loc.value.len > 0);
    }
    var p = try std.json.parseFromSlice(std.json.Value, gpa, "{\"role\":\"button\",\"name\":\"Go\",\"exact\":true}", .{});
    defer p.deinit();
    const r = try locators.fromParams(.role, p.value.object);
    try testing.expectEqualStrings("Go", r.name.?);
    try testing.expect(r.exact);

    const bad = [_]struct { locators.Kind, []const u8, anyerror }{
        .{ .role, "{}", error.MissingParam },
        .{ .role, "{\"role\":3}", error.InvalidParams },
        .{ .text, "{\"text\":\"  \"}", error.EmptyValue },
        .{ .role, "{\"role\":\"b\",\"exact\":\"yes\"}", error.InvalidParams },
        .{ .role, "{\"role\":\"b\",\"name\":1}", error.InvalidParams },
        .{ .nth, "{\"selector\":\"li\"}", error.MissingParam },
        .{ .nth, "{\"index\":true,\"selector\":\"li\"}", error.InvalidParams },
        .{ .nth, "{\"index\":\"x\",\"selector\":\"li\"}", error.InvalidParams },
        .{ .first, "{}", error.MissingParam },
    };
    for (bad) |c| {
        var q = try std.json.parseFromSlice(std.json.Value, gpa, c[1], .{});
        defer q.deinit();
        try testing.expectError(c[2], locators.fromParams(c[0], q.value.object));
    }
    try testing.expectEqual(locators.Kind.testid, locators.Kind.fromName("testid").?);
    try testing.expect(locators.Kind.fromName("css") == null);
}

test "unit: browser: locator from cli args" {
    const r = try locators.fromArgs(&.{ "role", "button", "--name", "Continue", "--exact" });
    try testing.expectEqual(locators.Kind.role, r.kind);
    try testing.expectEqualStrings("button", r.value);
    try testing.expectEqualStrings("Continue", r.name.?);
    try testing.expect(r.exact);
    const t = try locators.fromArgs(&.{ "text", "--exact", "Hello world" });
    try testing.expectEqualStrings("Hello world", t.value);
    try testing.expect(t.exact);
    const f = try locators.fromArgs(&.{ "first", "--selector", "li" });
    try testing.expectEqualStrings("li", f.value);
    const l = try locators.fromArgs(&.{ "last", "li.row" });
    try testing.expectEqualStrings("li.row", l.value);
    const n1 = try locators.fromArgs(&.{ "nth", "2", "li" });
    try testing.expectEqual(@as(i64, 2), n1.index);
    try testing.expectEqualStrings("li", n1.value);
    const n2 = try locators.fromArgs(&.{ "nth", "--index", "-1", "--selector", "li" });
    try testing.expectEqual(@as(i64, -1), n2.index);
    const n3 = try locators.fromArgs(&.{ "nth", "-2", "li" });
    try testing.expectEqual(@as(i64, -2), n3.index);
    const n4 = try locators.fromArgs(&.{ "nth", "--index=0", "li" });
    try testing.expectEqual(@as(i64, 0), n4.index);

    try testing.expectError(error.MissingParam, locators.fromArgs(&.{}));
    try testing.expectError(error.InvalidParams, locators.fromArgs(&.{"xpath"}));
    try testing.expectError(error.MissingParam, locators.fromArgs(&.{"role"}));
    try testing.expectError(error.UnknownFlag, locators.fromArgs(&.{ "text", "--name", "x", "y" }));
    try testing.expectError(error.UnknownFlag, locators.fromArgs(&.{ "first", "--exact", "li" }));
    try testing.expectError(error.UnknownFlag, locators.fromArgs(&.{ "role", "button", "--bogus" }));
    try testing.expectError(error.MissingValue, locators.fromArgs(&.{ "role", "button", "--name" }));
    try testing.expectError(error.UnexpectedArgument, locators.fromArgs(&.{ "text", "a", "b" }));
    try testing.expectError(error.InvalidNumber, locators.fromArgs(&.{ "nth", "x", "li" }));
    try testing.expectError(error.MissingParam, locators.fromArgs(&.{ "nth", "1" }));
    try testing.expectError(error.EmptyValue, locators.fromArgs(&.{ "label", " " }));
}

test "unit: browser: resolve selector accepts refs and css" {
    var tree = try ax.parseDomDocument(gpa, dom_app, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    var snap = try snapshot.render(gpa, &tree, &table, .{ .interactive = true });
    defer snap.deinit();
    // e1 = coupon textbox (first interactive element).
    const by_ref = try locators.resolveSelector(gpa, &tree, &table, "e1");
    try testing.expectEqual(@as(?i64, 7), tree.get(by_ref).backend_id);
    try testing.expectEqual(by_ref, try locators.resolveSelector(gpa, &tree, &table, " @e1 "));
    const by_css = try locators.resolveSelector(gpa, &tree, &table, "button[data-testid=continue-btn]");
    try testing.expectEqual(@as(?i64, 9), tree.get(by_css).backend_id);
    try testing.expectError(error.RefNotFound, locators.resolveSelector(gpa, &tree, &table, "e99"));
    try testing.expectError(error.ElementNotFound, locators.resolveSelector(gpa, &tree, &table, "#none"));
    try testing.expectError(error.InvalidSelector, locators.resolveSelector(gpa, &tree, &table, ""));
    try testing.expectError(error.InvalidRef, locators.resolveSelector(gpa, &tree, &table, "@foo"));
    // After navigation the old ref is gone (acceptance).
    table.onNavigation(null, true);
    try testing.expectError(error.RefNotFound, locators.resolveSelector(gpa, &tree, &table, "e1"));
    // A ref whose node vanished from a fresh tree is stale too.
    _ = try table.add(.{ .backend_node_id = 123456 });
    try testing.expectError(error.RefNotFound, locators.resolveSelector(gpa, &tree, &table, "e1"));
}

test "unit: browser: find registers a ref usable by click (acceptance)" {
    var tree = try ax.parseDomDocument(gpa, dom_app, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    var snap = try snapshot.render(gpa, &tree, &table, .{ .interactive = true });
    defer snap.deinit();
    const before = table.count();
    const loc = try locators.fromArgs(&.{ "role", "button", "--name", "Continue" });
    const idx = (try locators.findOne(gpa, &tree, loc, null)).?;
    const id = try locators.register(gpa, &tree, &table, idx);
    // Already in the snapshot: same ref, no new entry.
    try testing.expectEqual(before, table.count());
    var buf: [16]u8 = undefined;
    const ref = refs.formatRef(&buf, id);
    try testing.expectEqual(idx, try locators.resolveSelector(gpa, &tree, &table, ref));

    // A non-snapshot element (the logo image) gets the next ref.
    const img = (try locators.findOne(gpa, &tree, .{ .kind = .alt, .value = "logo" }, null)).?;
    const img_id = try locators.register(gpa, &tree, &table, img);
    try testing.expectEqual(@as(u32, @intCast(before + 1)), img_id);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try locators.writeFindResult(gpa, &s, &tree, &table, idx, id, "find");
    var p = try std.json.parseFromSlice(std.json.Value, gpa, aw.written(), .{});
    defer p.deinit();
    const o = p.value.object;
    try testing.expectEqualStrings("find", o.get("action").?.string);
    try testing.expectEqualStrings("button", o.get("tag").?.string);
    try testing.expectEqualStrings("Continue", o.get("text").?.string);
    try testing.expectEqualStrings(ref, o.get("ref").?.string);
    try testing.expectEqualStrings(o.get("element_ref").?.string[1..], ref);
    try testing.expectEqualStrings("html > body > button:nth-of-type(1)", o.get("selector").?.string);
    try testing.expectEqual(@as(i64, 9), o.get("backend_node_id").?.integer);
}

test "unit: browser: css selectors resolve in the page document like querySelector" {
    // A header web component (shadow buttons) and an iframe come before the
    // page's own buttons in flattened order. `click button` must pick what
    // document.querySelector("button") picks, as the in-page fallback for
    // unsupported selectors would.
    const j =
        \\{"root":{"nodeType":9,"backendNodeId":1,"children":[{"nodeType":1,"localName":"html","backendNodeId":2,"children":[{"nodeType":1,"localName":"body","backendNodeId":3,"children":[
        \\ {"nodeType":1,"localName":"site-header","backendNodeId":4,"shadowRoots":[{"nodeType":11,"backendNodeId":5,"children":[
        \\  {"nodeType":1,"localName":"button","backendNodeId":6,"children":[{"nodeType":3,"nodeValue":"Menu"}]}]}]},
        \\ {"nodeType":1,"localName":"iframe","backendNodeId":7,"frameId":"AD","contentDocument":{"nodeType":9,"backendNodeId":8,"children":[
        \\  {"nodeType":1,"localName":"html","backendNodeId":9,"children":[{"nodeType":1,"localName":"body","backendNodeId":10,"children":[
        \\   {"nodeType":1,"localName":"button","backendNodeId":11,"children":[{"nodeType":3,"nodeValue":"Ad"}]}]}]}]}},
        \\ {"nodeType":1,"localName":"button","backendNodeId":12,"attributes":["hidden",""],"children":[{"nodeType":3,"nodeValue":"Old"}]},
        \\ {"nodeType":1,"localName":"button","backendNodeId":13,"children":[{"nodeType":3,"nodeValue":"Buy"}]}]}]}]}}
    ;
    var tree = try ax.parseDomDocument(gpa, j, .{});
    defer tree.deinit();
    var table = refs.RefTable.init(gpa);
    defer table.deinit();
    const idx = try locators.resolveSelector(gpa, &tree, &table, "button");
    try testing.expectEqual(@as(?i64, 13), tree.get(idx).backend_id);
    const c = try locators.countMatches(gpa, &tree, "button");
    try testing.expectEqual(@as(usize, 2), c.total);
    try testing.expectEqual(@as(usize, 1), c.visible);
    try testing.expectEqual(@as(?i64, 13), try findBackend(&tree, .{ .kind = .first, .value = "body > button" }));
    try testing.expectEqual(@as(?i64, null), try findBackend(&tree, .{ .kind = .nth, .value = "button", .index = 1 }));
    // Text/role locators still see every frame and shadow tree.
    try testing.expectEqual(@as(?i64, 11), try findBackend(&tree, .{ .kind = .role, .value = "button", .name = "ad" }));
    // The snapshot still lists shadow and iframe content.
    const text = try renderText(&tree, &table, .{});
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\- document ""
        \\- button "Menu" [ref=e1]
        \\- button "Ad" [ref=e2]
        \\- button "Buy" [ref=e3]
    , text);
}

test "unit: browser: count matches separates visible" {
    var tree = try ax.parseDomDocument(gpa, dom_app, .{});
    defer tree.deinit();
    const c = try locators.countMatches(gpa, &tree, "button");
    try testing.expectEqual(@as(usize, 3), c.total);
    try testing.expectEqual(@as(usize, 2), c.visible);
    const none = try locators.countMatches(gpa, &tree, "table");
    try testing.expectEqual(@as(usize, 0), none.total);
}

test "unit: browser: locators over an ax-only tree use names" {
    var tree = try ax.parseAxTree(gpa, ax_login, .{});
    defer tree.deinit();
    try testing.expectEqual(@as(?i64, 22), try findBackend(&tree, .{ .kind = .label, .value = "pass" }));
    try testing.expectEqual(@as(?i64, 23), try findBackend(&tree, .{ .kind = .role, .value = "button", .name = "sign in", .exact = false }));
    try testing.expectEqual(@as(?i64, 3), try findBackend(&tree, .{ .kind = .text, .value = "welcome" }));
    // No attributes without DOM annotation.
    try testing.expectEqual(@as(?i64, null), try findBackend(&tree, .{ .kind = .testid, .value = "x" }));
    try testing.expectEqual(@as(?i64, null), try findBackend(&tree, .{ .kind = .first, .value = "button" }));
}

// ---------------------------------------------------------------------------
// allocation failures

/// Every allocating entry point once, all on `a`: parse (both sources, with
/// a url, frames, shadow roots, labels and a lone surrogate), annotate,
/// render with refs and css paths, JSON, find/register, resolve, count.
fn pipeline(a: std.mem.Allocator) !void {
    var dom = try ax.parseDomDocument(a, dom_frames, .{ .url = "https://top.test/" });
    defer dom.deinit();
    var login = try ax.parseDomDocument(a, dom_login, .{});
    defer login.deinit();
    var tree = try ax.parseAxTree(a, ax_login, .{ .url = "https://example.test/login" });
    defer tree.deinit();
    try tree.annotateFromDom(&login);
    var odd = try ax.parseDomDocument(a, "{\"root\":{\"nodeType\":9,\"children\":[{\"nodeType\":1,\"localName\":\"button\",\"attributes\":[\"aria-label\",\"\\ud83d\"]}]}}", .{});
    defer odd.deinit();

    var table = refs.RefTable.init(a);
    defer table.deinit();
    try table.setSelectedFrame("CHILD");
    var snap = try snapshot.render(a, &dom, &table, .{ .cursor = true });
    defer snap.deinit();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    snapshot.writeJson(a, &s, &snap, &dom, &table, .{}) catch return error.OutOfMemory;
    var ax_snap = try snapshot.render(a, &tree, &table, .{ .compact = true });
    defer ax_snap.deinit();
    const idx = (try locators.findOne(a, &login, .{ .kind = .text, .value = "sign" }, null)).?;
    const id = try locators.register(a, &login, &table, idx);
    aw.clearRetainingCapacity();
    s = .{ .writer = &aw.writer };
    locators.writeFindResult(a, &s, &login, &table, idx, id, "find") catch return error.OutOfMemory;
    _ = try locators.resolveSelector(a, &login, &table, "form > button.btn");
    _ = try locators.countMatches(a, &dom, "button");
}

test "unit: browser: allocation failures anywhere in the pipeline leak nothing" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        if (pipeline(failing.allocator())) |_| {
            try testing.expect(fail_index > 0);
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
        try testing.expect(fail_index < 100_000);
    }
}
