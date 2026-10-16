// Notifications panel tests: node:test + jsdom, driving the real panel modules
// (src/web/notifications/*) against the mock WebView2 host of harness.mjs.
//
//   WMUX_WEB_TEST_DEPS=/tmp/wmux-web-test-deps node --test 'test/web-node/**/*.test.mjs'
//
import { test, describe, afterEach, after } from "node:test";
import assert from "node:assert/strict";
import { loadPage, importWeb, settle, sleep, key, click, contextmenu, texts, hostError } from "./harness.mjs";

const { window, doc, host, pristineBody } = loadPage("notifications");
await importWeb("_shared/wmux-bridge.js");
await importWeb("_shared/theme.js");
const { createApp } = await importWeb("notifications/app.js");
const model = await importWeb("notifications/model.js");

const WS1 = "11111111-1111-4111-8111-111111111111";
const WS2 = "22222222-2222-4222-8222-222222222222";
const SF1 = "AAAAAAAA-0000-4000-8000-000000000001";
const SF2 = "AAAAAAAA-0000-4000-8000-000000000002";
const NOW = Date.UTC(2026, 9, 16, 15, 30);
const uuid = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

function rec(n, extra = {}) {
  return {
    id: uuid(n),
    workspace: WS1,
    surface: SF1,
    title: `Title ${n}`,
    subtitle: "",
    body: `Body ${n}`,
    created_at_ms: NOW - n * 60000,
    read: false,
    ...extra,
  };
}

const WORKSPACES = { workspaces: [{ id: WS1, title: "api" }, { id: WS2, title: "web" }] };

let app = null;

/**
 * Start a fresh app on a fresh body.
 * @param {{records?: object[], markers?: number, params?: object, state?: object, handlers?: object, keymap?: object}} [opts]
 */
async function startApp(opts = {}) {
  if (app) app.destroy();
  doc.body.innerHTML = pristineBody;
  host.reset();
  let records = (opts.records || [rec(1), rec(2, { read: true }), rec(3, { workspace: WS2, surface: SF2 })]).map((r) => ({ ...r }));
  const handlers = {
    "panel.ready": () => ({}),
    "panel.set_title": () => ({}),
    "panel.state_changed": () => ({}),
    "panel.subscribe": () => ({}),
    "panel.clipboard_write": () => ({}),
    "notification.list": () => ({ notifications: records.map((r) => ({ ...r })), marker_count: opts.markers || 0 }),
    "workspace.list": () => WORKSPACES,
    "notification.open": () => ({}),
    "notification.mark_read": ({ notification_id }) => {
      records = records.map((r) => (r.id === notification_id ? { ...r, read: true } : r));
      return {};
    },
    "panel.notifications.mark_unread": ({ notification_id }) => {
      records = records.map((r) => (r.id === notification_id ? { ...r, read: false } : r));
      return {};
    },
    "notification.dismiss": ({ notification_id }) => {
      records = records.filter((r) => r.id !== notification_id);
      return {};
    },
    "notification.clear": () => {
      records = [];
      return {};
    },
    "notification.jump_to_unread": () => ({}),
    "panel.notifications.close_popover": () => ({}),
    ...(opts.handlers || {}),
  };
  for (const [method, fn] of Object.entries(handlers)) host.handlers.set(method, fn);
  host.emit("panel.init", {
    kind: "notifications",
    surface_id: "5B1D2C9E-0000-4000-8000-000000000001",
    params: opts.params || {},
    state: opts.state || null,
    theme: { background: "#1e1e1e", foreground: "#d4d4d4" },
    keymap: opts.keymap || { jumpToUnread: ["ctrl+shift+u"] },
    settings: {},
  });
  app = createApp({ document: doc, now: () => NOW, locale: "en-US" });
  await app.start();
  await settle();
  return {
    app,
    setRecords(list) {
      records = list;
    },
    get records() {
      return records;
    },
  };
}

const $ = (id) => doc.getElementById(id);
const rows = () => Array.from(doc.querySelectorAll(".ntf-row"));
const rowById = (id) => rows().find((r) => r.dataset.id === id);

after(() => window.close());

afterEach(() => {
  if (app) {
    app.destroy();
    app = null;
  }
});

/* ------------------------------------------------------------------------ */
/* model                                                                     */
/* ------------------------------------------------------------------------ */

describe("unit: notifications model", () => {
  test("unit: notifications: copy text joins workspace, title and detail", () => {
    const titles = model.workspaceTitlesFrom(WORKSPACES);
    const r = model.normalizeRecord({ id: "x", workspace: WS1, title: "Claude Code", body: "Done" });
    assert.equal(model.copyText(r, titles), "api\nClaude Code\nDone");
  });

  test("unit: notifications: copy text trims, omits empty lines and a detail equal to the title", () => {
    const n = (o) => model.normalizeRecord({ id: "x", ...o });
    assert.equal(model.copyText(n({ title: "  Same ", body: " Same " }), new Map()), "Same");
    assert.equal(model.copyText(n({ title: "T", body: "   ", subtitle: " sub " }), new Map()), "T\nsub");
    assert.equal(model.copyText(n({ title: "", body: "" }), new Map()), "");
    assert.equal(model.copyText(n({ workspace_title: " w ", title: "", body: "b" }), new Map()), "w\nb");
  });

  test("unit: notifications: normalizes native and cmux field spellings", () => {
    const a = model.normalizeRecord({ notification_id: "n1", workspace_id: WS1, surface_id: SF1, is_read: true, created_at: 1700000000.5 });
    assert.equal(a.id, "n1");
    assert.equal(a.workspace, WS1);
    assert.equal(a.surface, SF1);
    assert.equal(a.read, true);
    assert.equal(a.created_at_ms, 1700000000500);
    assert.equal(model.normalizeRecord({ id: "n", created_at: "2026-01-02T03:04:05Z" }).created_at_ms, Date.UTC(2026, 0, 2, 3, 4, 5));
    assert.equal(model.normalizeRecord({ id: "n", title: 42, body: null }).title, "42");
    for (const bad of [null, 5, "x", [], {}, { id: "" }, { id: 7 }]) assert.equal(model.normalizeRecord(bad), null);
  });

  test("unit: notifications: records are deduplicated, sorted newest first and capped", () => {
    const list = model.recordsFrom({ notifications: [rec(3), rec(1), rec(2), rec(1), null, "junk"] });
    assert.deepEqual(list.map((r) => r.id), [uuid(1), uuid(2), uuid(3)]);
    const huge = Array.from({ length: model.MAX_RECORDS + 50 }, (_, i) => rec(i + 1));
    assert.equal(model.recordsFrom(huge).length, model.MAX_RECORDS);
    assert.deepEqual(model.recordsFrom(null), []);
    assert.deepEqual(model.recordsFrom({ notifications: "nope" }), []);
  });

  test("unit: notifications: long bodies are clipped without splitting a surrogate pair", () => {
    const body = "a".repeat(model.MAX_TEXT - 1) + "😀" + "tail";
    const r = model.normalizeRecord({ id: "x", body });
    assert.equal(r.body.length, model.MAX_TEXT - 1);
    assert.ok(!/[\ud800-\udbff]$/.test(r.body));
  });

  test("unit: notifications: groups by workspace in newest-record order with unread counts", () => {
    const titles = model.workspaceTitlesFrom(WORKSPACES);
    const records = model.recordsFrom([rec(1, { workspace: WS2 }), rec(2), rec(3, { workspace: WS2, read: true }), rec(4, { workspace: "" })]);
    const groups = model.groupRecords(records, titles);
    assert.deepEqual(groups.map((g) => g.title), ["web", "api", ""]);
    assert.deepEqual(groups.map((g) => g.unread), [1, 1, 1]);
    assert.deepEqual(groups[0].records.map((r) => r.id), [uuid(1), uuid(3)]);
  });

  test("unit: notifications: workspace ids match case-insensitively and live titles win", () => {
    const titles = model.workspaceTitlesFrom({ workspaces: [{ id: WS1.toLowerCase(), title: "renamed" }] });
    const r = model.normalizeRecord({ id: "x", workspace: WS1, workspace_title: "old" });
    assert.equal(model.workspaceTitle(r, titles), "renamed");
    assert.equal(model.workspaceTitle(r, new Map()), "old");
  });

  test("unit: notifications: body state and marker counts", () => {
    assert.equal(model.bodyState([], 0), "empty");
    assert.equal(model.bodyState([], 2), "markers");
    assert.equal(model.bodyState([rec(1)], 2), "list");
    assert.equal(model.markerCountFrom({ marker_count: 3 }), 3);
    assert.equal(model.markerCountFrom({ markers: [WS1, WS2] }), 2);
    assert.equal(model.markerCountFrom({ marker_count: -1 }), 0);
    assert.equal(model.markerCountFrom([]), 0);
  });

  test("unit: notifications: short time shows the time today and a date otherwise", () => {
    const today = model.formatShortTime(NOW - 60000, NOW, "en-US");
    assert.match(today, /\d{1,2}:\d{2}/);
    const older = model.formatShortTime(Date.UTC(2026, 0, 3, 12), NOW, "en-US");
    assert.match(older, /Jan/);
    assert.equal(model.formatShortTime(0, NOW, "en-US"), "");
    assert.equal(model.formatShortTime(NaN, NOW, "en-US"), "");
  });

  test("unit: notifications: shortcut labels and event classification", () => {
    assert.equal(model.shortcutLabel("ctrl+shift+u"), "Ctrl+Shift+U");
    assert.equal(model.shortcutLabel("g g"), "G G");
    assert.equal(model.shortcutLabel("ctrl++"), "Ctrl++");
    assert.equal(model.shortcutLabel(undefined), "");
    assert.ok(model.isRecordEvent("notification.created"));
    assert.ok(model.isRecordEvent("wmux.notification.unread_count.changed"));
    assert.ok(!model.isRecordEvent("workspace.renamed"));
    assert.ok(model.isWorkspaceEvent("workspace.renamed"));
    assert.equal(model.frameName({ type: "event", name: "notification.read" }), "notification.read");
    assert.equal(model.frameName({ event: "notification.read" }), "notification.read");
    assert.equal(model.frameName(null), "");
  });
});

/* ------------------------------------------------------------------------ */
/* app                                                                       */
/* ------------------------------------------------------------------------ */

describe("unit: notifications app", () => {
  test("unit: notifications: pane tab lists records grouped by workspace with unread state", async () => {
    await startApp();
    assert.equal(doc.documentElement.dataset.placement, "tab");
    assert.deepEqual(texts(doc, ".ntf-group-name"), ["api", "web"]);
    assert.equal(rows().length, 3);
    assert.deepEqual(rows().map((r) => r.classList.contains("ntf-unread")), [true, false, true]);
    assert.equal($("ntf-count").textContent, "2");
    assert.equal($("ntf-count").hidden, false);
    assert.equal($("ntf-jump-label").textContent, "Jump to Latest Unread");
    assert.equal($("ntf-jump-chip").textContent, "Ctrl+Shift+U");
    assert.equal($("ntf-jump").disabled, false);
    assert.equal($("ntf-clear").disabled, false);
    assert.equal(rows()[0].querySelector(".ntf-row-primary").textContent, "Title 1");
    assert.equal(rows()[0].querySelector(".ntf-row-body").textContent, "Body 1");
    assert.ok(host.calls("panel.set_title").some((m) => m.params.title === "Notifications"));
    const sub = host.calls("panel.subscribe")[0];
    assert.ok(sub.params.categories.includes("notification"));
  });

  test("unit: notifications: popover uses the flat cmux row layout when grouping is off", async () => {
    await startApp({ params: { placement: "popover", group_by: "none" } });
    assert.equal(doc.documentElement.dataset.placement, "popover");
    assert.equal(doc.querySelectorAll(".ntf-group").length, 0);
    assert.equal($("ntf-jump-label").textContent, "Jump to Latest");
    const first = rows()[0];
    assert.equal(first.querySelector(".ntf-row-primary").textContent, "api");
    assert.equal(first.querySelector(".ntf-row-secondary").textContent, "Title 1");
    assert.equal(first.querySelector(".ntf-row-body").textContent, "Body 1");
    assert.match(first.querySelector(".ntf-row-time").textContent, /\d:\d\d/);
  });

  test("unit: notifications: untrusted text is rendered as text, never markup", async () => {
    await startApp({ records: [rec(1, { title: "<img src=x onerror=alert(1)>", body: "<script>bad()</script>" })] });
    assert.equal(doc.querySelector(".ntf-list img"), null);
    assert.equal(doc.querySelector(".ntf-list script"), null);
    assert.equal(rows()[0].querySelector(".ntf-row-primary").textContent, "<img src=x onerror=alert(1)>");
  });

  test("unit: notifications: empty and markers-only states", async () => {
    await startApp({ records: [] });
    assert.equal($("ntf-list").hidden, true);
    assert.equal($("ntf-empty").hidden, false);
    assert.equal($("ntf-empty-title").textContent, "No notifications yet");
    assert.equal($("ntf-empty-body").textContent, "Desktop notifications will appear here for quick review.");
    assert.equal($("ntf-jump").disabled, true);
    assert.equal($("ntf-clear").disabled, true);
    assert.equal($("ntf-count").hidden, true);

    await startApp({ records: [], params: { placement: "popover" } });
    assert.equal($("ntf-empty-body").textContent, "Desktop notifications will appear here.");

    await startApp({ records: [], markers: 3 });
    assert.equal($("ntf-empty").dataset.state, "markers");
    assert.equal($("ntf-empty-title").textContent, "3 unread notifications");
    assert.equal($("ntf-jump").disabled, false);
    await startApp({ records: [], markers: 1 });
    assert.equal($("ntf-empty-title").textContent, "1 unread notification");
  });

  test("unit: notifications: click opens the record, marks it read and closes the popover", async () => {
    await startApp({ params: { placement: "popover" } });
    click(window, rows()[0].querySelector(".ntf-row-primary"));
    await settle();
    assert.deepEqual(host.calls("notification.open").map((m) => m.params), [{ notification_id: uuid(1) }]);
    assert.equal(host.calls("panel.notifications.close_popover").length, 1);
    assert.equal(rowById(uuid(1)).classList.contains("ntf-unread"), false);
  });

  test("unit: notifications: open in a pane tab does not close anything", async () => {
    await startApp();
    await app.open(uuid(3));
    await settle();
    assert.equal(host.calls("notification.open").length, 1);
    assert.equal(host.calls("panel.notifications.close_popover").length, 0);
  });

  test("unit: notifications: hover X dismisses the row and moves focus to the next one", async () => {
    await startApp();
    app.focusRow(uuid(1));
    click(window, rowById(uuid(1)).querySelector(".ntf-row-clear"));
    await settle();
    assert.deepEqual(host.calls("notification.dismiss").map((m) => m.params), [{ notification_id: uuid(1) }]);
    assert.equal(host.calls("notification.open").length, 0);
    assert.equal(rows().length, 2);
    assert.equal(app.state.focusedId, uuid(2));
    assert.equal(doc.activeElement, rowById(uuid(2)));
  });

  test("unit: notifications: Mark as Unread re-adds the unread state and increments the count", async () => {
    await startApp();
    assert.equal($("ntf-count").textContent, "2");
    contextmenu(window, rowById(uuid(2)), { clientX: 30, clientY: 40 });
    const menu = $("ntf-menu");
    assert.equal(menu.hidden, false);
    const toggle = menu.querySelector('[data-action="toggleRead"]');
    assert.equal(toggle.textContent, "Mark as Unread");
    assert.deepEqual(texts(menu, "[role=menuitem]"), ["Open", "Copy", "Mark as Unread", "Dismiss"]);
    assert.equal(menu.style.getPropertyValue("left"), "30px");
    click(window, toggle);
    await settle();
    assert.equal(menu.hidden, true);
    assert.deepEqual(host.calls("panel.notifications.mark_unread").map((m) => m.params), [{ notification_id: uuid(2) }]);
    assert.equal(rowById(uuid(2)).classList.contains("ntf-unread"), true);
    assert.equal($("ntf-count").textContent, "3");

    contextmenu(window, rowById(uuid(2)));
    assert.equal(menu.querySelector('[data-action="toggleRead"]').textContent, "Mark as Read");
    click(window, menu.querySelector('[data-action="toggleRead"]'));
    await settle();
    assert.deepEqual(host.calls("notification.mark_read").map((m) => m.params), [{ notification_id: uuid(2) }]);
    assert.equal($("ntf-count").textContent, "2");
  });

  test("unit: notifications: context menu Copy writes the cmux copy text", async () => {
    await startApp({ records: [rec(1, { title: "Claude Code", body: "Done" })] });
    contextmenu(window, rows()[0]);
    click(window, $("ntf-menu").querySelector('[data-action="copy"]'));
    await settle();
    assert.deepEqual(host.calls("panel.clipboard_write").map((m) => m.params), [{ text: "api\nClaude Code\nDone" }]);
    assert.equal($("ntf-status").textContent, "Copied");
  });

  test("unit: notifications: context menu Dismiss and Open", async () => {
    await startApp();
    contextmenu(window, rowById(uuid(3)));
    click(window, $("ntf-menu").querySelector('[data-action="dismiss"]'));
    await settle();
    assert.deepEqual(host.calls("notification.dismiss").map((m) => m.params.notification_id), [uuid(3)]);
    contextmenu(window, rowById(uuid(2)));
    click(window, $("ntf-menu").querySelector('[data-action="open"]'));
    await settle();
    assert.deepEqual(host.calls("notification.open").map((m) => m.params.notification_id), [uuid(2)]);
  });

  test("unit: notifications: context menu keyboard navigation and Escape", async () => {
    await startApp();
    app.focusRow(uuid(1));
    key(window, rowById(uuid(1)), { key: "F10", shiftKey: true });
    const items = Array.from($("ntf-menu").querySelectorAll("[role=menuitem]"));
    assert.equal($("ntf-menu").hidden, false);
    assert.equal(doc.activeElement, items[0]);
    key(window, items[0], { key: "ArrowDown" });
    assert.equal(doc.activeElement, items[1]);
    key(window, items[1], { key: "ArrowUp" });
    key(window, items[0], { key: "ArrowUp" });
    assert.equal(doc.activeElement, items[3]);
    key(window, items[3], { key: "Escape" });
    assert.equal($("ntf-menu").hidden, true);
    assert.equal(doc.activeElement, rowById(uuid(1)));
    assert.equal(host.calls("panel.notifications.close_popover").length, 0);
  });

  test("unit: notifications: list keyboard navigation, Enter opens, Space toggles, Delete dismisses", async () => {
    await startApp();
    app.focusList();
    // Visual order follows the groups: api (1, 2), web (3).
    assert.equal(doc.activeElement, rowById(uuid(1)));
    assert.equal(rowById(uuid(1)).tabIndex, 0);
    assert.equal(rowById(uuid(2)).tabIndex, -1);
    key(window, doc.activeElement, { key: "ArrowDown" });
    assert.equal(doc.activeElement, rowById(uuid(2)));
    key(window, doc.activeElement, { key: "j" });
    assert.equal(doc.activeElement, rowById(uuid(3)));
    key(window, doc.activeElement, { key: "ArrowDown" });
    assert.equal(doc.activeElement, rowById(uuid(3)), "stays at the end");
    key(window, doc.activeElement, { key: "Home" });
    assert.equal(doc.activeElement, rowById(uuid(1)));
    key(window, doc.activeElement, { key: "End" });
    assert.equal(doc.activeElement, rowById(uuid(3)));
    key(window, doc.activeElement, { key: "k" });
    assert.equal(rowById(uuid(2)).getAttribute("aria-selected"), "true");

    key(window, doc.activeElement, { key: " " });
    await settle();
    assert.deepEqual(host.calls("panel.notifications.mark_unread").map((m) => m.params.notification_id), [uuid(2)]);
    key(window, doc.activeElement, { key: "Enter" });
    await settle();
    assert.deepEqual(host.calls("notification.open").map((m) => m.params.notification_id), [uuid(2)]);
    key(window, doc.activeElement, { key: "Delete" });
    await settle();
    assert.deepEqual(host.calls("notification.dismiss").map((m) => m.params.notification_id), [uuid(2)]);
    assert.equal(doc.activeElement, rowById(uuid(3)));
    key(window, doc.activeElement, { key: "c", ctrlKey: true });
    await settle();
    assert.equal(host.calls("panel.clipboard_write").length, 1);
  });

  test("unit: notifications: pane focus puts the first row in focus and Return opens the newest", async () => {
    await startApp({ params: { group_by: "none" } });
    window.dispatchEvent(new window.Event("focus"));
    assert.equal(doc.activeElement, rows()[0]);
    key(window, doc.activeElement, { key: "Enter" });
    await settle();
    assert.deepEqual(host.calls("notification.open").map((m) => m.params.notification_id), [uuid(1)]);
  });

  test("unit: notifications: Escape in the popover asks native to close it", async () => {
    await startApp({ params: { placement: "popover" } });
    key(window, doc.body, { key: "Escape" });
    await settle();
    assert.equal(host.calls("panel.notifications.close_popover").length, 1);
  });

  test("unit: notifications: Clear All and Jump to Latest", async () => {
    await startApp({ params: { placement: "popover" } });
    click(window, $("ntf-jump"));
    await settle();
    assert.equal(host.calls("notification.jump_to_unread").length, 1);
    assert.equal(host.calls("panel.notifications.close_popover").length, 1);
    click(window, $("ntf-clear"));
    await settle();
    assert.equal(host.calls("notification.clear").length, 1);
    assert.equal(rows().length, 0);
    assert.equal($("ntf-empty").hidden, false);
    assert.equal($("ntf-clear").disabled, true);
  });

  test("unit: notifications: jump with nothing unread does not call native", async () => {
    await startApp({ records: [rec(1, { read: true })] });
    assert.equal($("ntf-jump").disabled, true);
    assert.equal(await app.jumpToUnread(), false);
    assert.equal(host.calls("notification.jump_to_unread").length, 0);
  });

  test("unit: notifications: live updates reload on notification events and workspace renames", async () => {
    const h = await startApp();
    h.setRecords([rec(9, { title: "Fresh" }), ...h.records]);
    host.emit("cmux.event", { type: "event", name: "notification.created", seq: 7 });
    await sleep(60);
    await settle();
    assert.equal(rows().length, 4);
    assert.equal($("ntf-count").textContent, "3");

    host.handlers.set("workspace.list", () => ({ workspaces: [{ id: WS1, title: "api-renamed" }, { id: WS2, title: "web" }] }));
    host.emit("cmux.event", { type: "event", name: "workspace.renamed" });
    await sleep(60);
    await settle();
    assert.ok(texts(doc, ".ntf-group-name").includes("api-renamed"));

    const before = host.calls("notification.list").length;
    host.emit("cmux.event", { type: "event", name: "surface.focused" });
    await sleep(60);
    assert.equal(host.calls("notification.list").length, before, "unrelated events are ignored");
  });

  test("unit: notifications: snapshot events replace the list without a round trip", async () => {
    await startApp();
    host.emit("panel.notifications.snapshot", { notifications: [rec(5, { workspace: WS2 })], workspaces: WORKSPACES.workspaces });
    await settle();
    assert.equal(rows().length, 1);
    assert.deepEqual(texts(doc, ".ntf-group-name"), ["web"]);
  });

  test("unit: notifications: a burst of events coalesces into one reload", async () => {
    await startApp();
    const before = host.calls("notification.list").length;
    for (let i = 0; i < 20; i += 1) host.emit("cmux.event", { name: "notification.read" });
    await sleep(80);
    assert.equal(host.calls("notification.list").length, before + 1);
  });

  test("unit: notifications: failed actions report and reload the authoritative list", async () => {
    await startApp({ handlers: { "notification.dismiss": () => { throw hostError("not_found", "No such notification"); } } });
    const before = host.calls("notification.list").length;
    await app.dismiss(uuid(1));
    assert.match($("ntf-status").textContent, /No such notification/);
    await sleep(60);
    await settle();
    assert.equal(host.calls("notification.list").length, before + 1);
    assert.equal(rows().length, 3, "the row comes back from the reload");
  });

  test("unit: notifications: load failure shows a status and the empty state", async () => {
    await startApp({ handlers: { "notification.list": () => { throw hostError("internal_error", "boom"); } } });
    assert.match($("ntf-status").textContent, /Could not load notifications: boom/);
    assert.equal($("ntf-empty").hidden, false);
  });

  test("unit: notifications: commands from native run panel actions", async () => {
    await startApp();
    host.emit("panel.notifications.command", { action: "jumpToUnread" });
    await settle();
    assert.equal(host.calls("notification.jump_to_unread").length, 1);
    host.emit("panel.notifications.command", { action: "clearAllNotifications" });
    await settle();
    assert.equal(host.calls("notification.clear").length, 1);
    host.emit("panel.notifications.command", { action: "bogus" });
    await settle();
  });

  test("unit: notifications: restored state refocuses the last row and focus changes are saved", async () => {
    await startApp({ state: { v: 1, focused_id: uuid(3) } });
    assert.equal(app.state.focusedId, uuid(3));
    app.focusRow(uuid(2));
    await sleep(450);
    const saved = host.calls("panel.state_changed").at(-1);
    assert.deepEqual(saved.params.state, { v: 1, focused_id: uuid(2) });
  });

  test("unit: notifications: huge lists and unicode render", async () => {
    const many = Array.from({ length: 600 }, (_, i) => rec(i + 1, { title: `通知 ${i} 😀`, workspace: i % 2 ? WS1 : WS2 }));
    await startApp({ records: many });
    assert.equal(rows().length, 600);
    assert.equal($("ntf-count").textContent, "99+");
    assert.ok(texts(doc, ".ntf-row-primary").includes("通知 0 😀"));
  });
});
