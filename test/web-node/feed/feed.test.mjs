// Feed panel tests: node:test + jsdom, driving the real panel modules
// (src/web/feed/*), the vendored markdown-it and DOMPurify against the mock
// WebView2 host of ../notifications/harness.mjs.
//
//   WMUX_WEB_TEST_DEPS=/tmp/wmux-web-test-deps node --test 'test/web-node/**/*.test.mjs'
//
import { test, describe, afterEach, after } from "node:test";
import assert from "node:assert/strict";
import { loadPage, importWeb, settle, sleep, key, click, dblclick, texts, hostError } from "../notifications/harness.mjs";

const { window, doc, host, pristineBody } = loadPage("feed");
const { default: markdownit } = await importWeb("_vendor/markdown-it@15.0.2/markdown-it.js");
const { default: createDOMPurify } = await importWeb("_vendor/dompurify@3.4.17/purify.es.js");
const purify = createDOMPurify(window);
await importWeb("_shared/wmux-bridge.js");
await importWeb("_shared/theme.js");
const { createApp } = await importWeb("feed/app.js");
const { createMarkdownRenderer } = await importWeb("feed/render.js");
const model = await importWeb("feed/model.js");

const WS = "11111111-1111-4111-8111-111111111111";
const SF = "AAAAAAAA-0000-4000-8000-000000000001";
const NOW = Date.UTC(2026, 9, 16, 15, 30);
const uuid = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const secs = (minutesAgo) => (NOW - minutesAgo * 60000) / 1000;

/** An item as feed.list encodes it (query.zig writeListItem). */
function item(n, kind, extra = {}) {
  const decision = model.DECISION_KINDS.includes(kind);
  return {
    id: uuid(n),
    kind,
    status: decision ? "pending" : "info",
    source: "claude",
    hook_event_name: "PermissionRequest",
    title: `Item ${n}`,
    detail: "",
    created_at: secs(n),
    session_id: "sess-1",
    workspace_id: WS,
    surface_id: SF,
    ...(decision ? { request_id: `req-${n}` } : {}),
    ...extra,
  };
}

const permission = (n, extra) => item(n, "permissionRequest", { tool_name: "Bash", detail: "rm -rf build", options: ["once", "always", "all", "bypass", "deny"], ...extra });
const plan = (n, extra) =>
  item(n, "exitPlan", {
    tool_name: "ExitPlanMode",
    plan: { text: "# Plan\n\n1. Do **this**\n2. [docs](https://example.com/x) <script>bad()</script>", file_path: "C:\\p\\plan.md", allowed_prompts: ["run tests"] },
    options: ["ultraplan", "bypassPermissions", "autoAccept", "manual", "deny"],
    ...extra,
  });
const question = (n, questions, extra) => item(n, "question", { tool_name: "AskUserQuestion", questions, options: questions.flatMap((q) => q.options.map((o) => o.label)), ...extra });

let app = null;

/**
 * @param {{items?: object[], hasMore?: boolean, params?: object, state?: object, handlers?: object}} [opts]
 */
async function startApp(opts = {}) {
  if (app) app.destroy();
  doc.body.innerHTML = pristineBody;
  host.reset();
  let items = opts.items || [permission(1), item(2, "message", { title: "Hello" }), item(3, "todos", { todos: [{ content: "a", status: "completed", active_form: "" }, { content: "b", status: "pending", active_form: "" }, { content: "c", status: "in_progress", active_form: "Doing c" }] })];
  const handlers = {
    "panel.ready": () => ({}),
    "panel.set_title": () => ({}),
    "panel.state_changed": () => ({}),
    "panel.subscribe": () => ({}),
    "panel.open_in_browser": () => ({}),
    "panel.open_external": () => ({}),
    "feed.list": (p) => {
      if (p.before) return opts.older ? opts.older(p) : { items: [], has_more: false };
      return { items, has_more: opts.hasMore === true };
    },
    "feed.permission.reply": () => ({ delivered: true }),
    "feed.exit_plan.reply": () => ({ delivered: true }),
    "feed.question.reply": () => ({ delivered: true }),
    "panel.feed.stop_reply": () => ({ delivered: true }),
    "feed.jump": () => ({}),
    ...(opts.handlers || {}),
  };
  for (const [method, fn] of Object.entries(handlers)) host.handlers.set(method, fn);
  host.emit("panel.init", {
    kind: "feed",
    surface_id: "5B1D2C9E-0000-4000-8000-000000000002",
    params: opts.params || {},
    state: opts.state || null,
    theme: { background: "#1e1e1e", foreground: "#d4d4d4" },
    keymap: {},
    settings: {},
  });
  const renderMarkdown = createMarkdownRenderer({ markdownit, purify, document: doc });
  app = createApp({ document: doc, now: () => NOW, renderMarkdown });
  await app.start();
  await settle();
  return {
    setItems(list) {
      items = list;
    },
    get items() {
      return items;
    },
  };
}

const $ = (id) => doc.getElementById(id);
const cards = () => Array.from(doc.querySelectorAll("#feed-list .feed-card"));
const cardById = (id) => cards().find((c) => c.dataset.id === id);
const btn = (card, action, extra = "") => card.querySelector(`[data-action="${action}"]${extra}`);

function type(el, value) {
  el.value = value;
  el.dispatchEvent(new window.Event("input", { bubbles: true }));
}

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

describe("unit: feed model", () => {
  test("unit: feed: normalizes feed.list items and drops malformed ones", () => {
    const list = model.itemsFrom({
      items: [permission(2), item(1, "message"), { id: "x", kind: "bogus" }, { kind: "stop" }, null, 7, permission(2)],
      has_more: false,
    });
    assert.deepEqual(list.map((it) => it.id), [uuid(1), uuid(2)]);
    const p = list[1];
    assert.equal(p.kind, "permissionRequest");
    assert.equal(p.status, "pending");
    assert.equal(p.request_id, "req-2");
    assert.equal(p.created_at_ms, NOW - 120000);
    assert.equal(model.normalizeItem({ id: "a", kind: "question" }).status, "pending");
    assert.equal(model.normalizeItem({ id: "a", kind: "message", status: "weird" }).status, "info");
    assert.deepEqual(model.itemsFrom("nope"), []);
  });

  test("unit: feed: questions, plans and todos accept both spellings", () => {
    const q = model.normalizeItem({ id: "q", kind: "question", questions: [{ question: "Pick", multiSelect: true, options: ["A", { label: "B", description: "bee" }, { label: "" }, 5] }, "junk"] });
    assert.equal(q.questions.length, 1);
    assert.equal(q.questions[0].multi_select, true);
    assert.deepEqual(q.questions[0].options, [{ label: "A", description: "" }, { label: "B", description: "bee" }]);
    const todo = model.normalizeItem({ id: "t", kind: "todos", todos: [{ content: "x", status: "weird", activeForm: "Xing" }, null] });
    assert.deepEqual(todo.todos, [{ content: "x", status: "pending", active_form: "Xing" }]);
    const p = model.normalizeItem({ id: "p", kind: "exitPlan", plan: { text: "t", allowed_prompts: ["a", 3] } });
    assert.deepEqual(p.plan, { text: "t", file_path: null, allowed_prompts: ["a"] });
  });

  test("unit: feed: actionable partition keeps pending decisions and puts closed ones under Resolved", () => {
    const items = model.itemsFrom([permission(1), permission(2, { status: "resolved", resolution: { mode: "once", badge: "once" } }), item(3, "message"), plan(4, { status: "expired" })]);
    const p = model.partition(items);
    assert.deepEqual(p.pending.map((it) => it.id), [uuid(1)]);
    assert.deepEqual(p.resolved.map((it) => it.id), [uuid(2), uuid(4)]);
  });

  test("unit: feed: badges follow the native resolution badges", () => {
    const n = (o) => model.normalizeItem({ id: "i", ...o });
    assert.equal(model.badgeFor(n({ kind: "permissionRequest", status: "resolved", resolution: { mode: "all" } })), "all tools");
    assert.equal(model.badgeFor(n({ kind: "permissionRequest", status: "resolved", resolution: { mode: "deny" } })), "denied");
    assert.equal(model.badgeFor(n({ kind: "exitPlan", status: "resolved", resolution: { mode: "autoAccept" } })), "auto");
    assert.equal(model.badgeFor(n({ kind: "exitPlan", status: "resolved", resolution: { mode: "deny", feedback: "x" } })), "refined");
    assert.equal(model.badgeFor(n({ kind: "question", status: "resolved", resolution: { selections: ["a"] } })), "Submitted");
    assert.equal(model.badgeFor(n({ kind: "question", status: "resolved", resolution: { badge: "custom" } })), "custom");
    assert.equal(model.badgeFor(n({ kind: "permissionRequest", status: "timedOut" })), "timed out");
    assert.equal(model.badgeFor(n({ kind: "permissionRequest", status: "expired" })), "expired");
    assert.equal(model.localResolution("exitPlan", { mode: "bypassPermissions" }).badge, "bypass");
    assert.equal(model.localResolution("stop", { text: "go" }).badge, "Sent");
  });

  test("unit: feed: buttons only for modes the item offers, in cmux order", () => {
    const n = (o) => model.normalizeItem({ id: "i", request_id: "r", ...o });
    assert.deepEqual(model.availableModes(n({ kind: "permissionRequest", options: ["deny", "once", "bogus"] })), ["once", "deny"]);
    assert.deepEqual(model.availableModes(n({ kind: "permissionRequest" })), ["once", "deny"]);
    assert.deepEqual(model.availableModes(n({ kind: "exitPlan", options: ["deny", "manual", "ultraplan", "autoAccept"] })), ["ultraplan", "manual", "autoAccept", "deny"]);
    assert.deepEqual(model.availableModes(n({ kind: "permissionRequest", status: "resolved", options: ["once"] })), []);
    assert.deepEqual(model.availableModes(model.normalizeItem({ id: "i", kind: "permissionRequest", options: ["once"] })), [], "no request_id: telemetry only");
  });

  test("unit: feed: todo summary matches the native format", () => {
    const todos = [{ status: "completed" }, { status: "pending" }, { status: "pending" }];
    assert.equal(model.todoSummary(todos), "2 open, 1 done");
    assert.equal(model.todoSummary([{ status: "in_progress" }]), "1 in progress");
    assert.equal(model.todoSummary([]), "0 open");
    assert.deepEqual(model.todoCounts(todos), { open: 2, in_progress: 0, done: 1 });
  });

  test("unit: feed: banner text per decision kind", () => {
    const n = (o) => model.normalizeItem({ id: "i", source: "claude", ...o });
    assert.deepEqual(model.bannerText(n({ kind: "permissionRequest", tool_name: "Bash" })), {
      title: ["feed.banner.permission", { source: "Claude" }],
      body: ["feed.banner.permissionBody", { tool: "Bash" }],
    });
    assert.equal(model.bannerText(n({ kind: "permissionRequest" })).body[0], "feed.banner.decisionNeeded");
    assert.equal(model.bannerText(n({ kind: "exitPlan" })).title[0], "feed.banner.plan");
    assert.equal(model.bannerText(n({ kind: "question", source: "mystery" })).title[1].source, "mystery");
    assert.equal(model.bannerText(n({ kind: "message" })), null);
    assert.equal(model.bannerText(n({ kind: "question", status: "resolved" })), null);
    assert.equal(model.sourceDisplayName(""), "Agent");
    assert.equal(model.sourceDisplayName("rovodev"), "Rovo Dev");
  });

  test("unit: feed: relative time", () => {
    assert.equal(model.relativeTime(NOW - 10000, NOW), "now");
    assert.equal(model.relativeTime(NOW + 60000, NOW), "now");
    assert.equal(model.relativeTime(NOW - 5 * 60000, NOW), "5m");
    assert.equal(model.relativeTime(NOW - 3 * 3600000, NOW), "3h");
    assert.equal(model.relativeTime(NOW - 2 * 86400000, NOW), "2d");
    assert.equal(model.relativeTime(NOW - 15 * 86400000, NOW), "2w");
    assert.equal(model.relativeTime(0, NOW), "");
  });

  test("unit: feed: relative times and the unknown agent name go through tr()", async () => {
    const strings = await importWeb("_shared/strings.js");
    const prev = strings.getLocale();
    strings.addStrings("qps-ploc", { "feed.time.now": "[now]", "feed.time.minutes": "[{count} min]", "feed.source.unknown": "[agent]" });
    strings.setLocale("qps-ploc");
    try {
      assert.equal(model.relativeTime(NOW - 10000, NOW), "[now]");
      assert.equal(model.relativeTime(NOW - 5 * 60000, NOW), "[5 min]");
      assert.equal(model.relativeTime(NOW - 3 * 3600000, NOW), "3h", "keys without a translation keep the English default");
      assert.equal(model.sourceDisplayName(""), "[agent]");
      assert.equal(model.sourceDisplayName("claude"), "Claude");
    } finally {
      strings.setLocale(prev);
    }
  });

  test("unit: feed: selections flatten answers in question order with free text", () => {
    const qs = [
      { question: "A?", multi_select: false, options: [{ label: "x" }, { label: "y" }] },
      { question: "B?", multi_select: true, options: [{ label: "p" }, { label: "q" }, { label: "r" }] },
      { question: "C?", multi_select: false, options: [] },
    ];
    const built = model.buildSelections(qs, [
      { selected: new Set(["y"]), other: "" },
      { selected: new Set(["r", "p"]), other: " also s " },
      { selected: new Set(), other: "free" },
    ]);
    assert.deepEqual(built.selections, ["y", "p", "r", "also s", "free"]);
    assert.deepEqual(built.answers, [["y"], ["p", "r", "also s"], ["free"]]);
    const single = model.buildSelections([qs[0]], [{ selected: new Set(["x"]), other: "typed" }]);
    assert.deepEqual(single.selections, ["typed"], "typed text replaces a single choice");
    assert.deepEqual(model.buildSelections(qs, []).selections, []);
  });

  test("unit: feed: workstreams group by source and session, most recent first", () => {
    const items = model.itemsFrom([permission(5, { session_id: "a" }), item(1, "message", { session_id: "b", source: "codex" }), item(3, "stop", { session_id: "a" })]);
    const ws = model.workstreams(items);
    assert.deepEqual(ws.map((w) => w.session_id), ["b", "a"]);
    assert.equal(ws[1].item_count, 2);
    assert.equal(ws[1].pending_count, 2);
    assert.equal(ws[1].latest.id, uuid(3));
  });

  test("unit: feed: plan markdown is sanitized and links are kept safe", () => {
    const render = createMarkdownRenderer({ markdownit, purify, document: doc });
    const div = doc.createElement("div");
    div.append(render("# T\n\n<script>x()</script><img src=x onerror=y()>\n\n[a](javascript:alert(1)) [b](https://ok.example/) ![i](https://evil.example/i.png)"));
    assert.equal(div.querySelector("script, img, style"), null);
    assert.ok(div.querySelector("h1"));
    const links = Array.from(div.querySelectorAll("a"));
    assert.ok(links.every((a) => !/javascript:/i.test(a.getAttribute("href") || "")));
    assert.ok(links.some((a) => a.getAttribute("href") === "https://ok.example/"));
    assert.equal(render(""), null);
    assert.equal(render("x".repeat(300000)), null);
    assert.equal(createMarkdownRenderer(null)("x"), null);
  });
});

/* ------------------------------------------------------------------------ */
/* app                                                                       */
/* ------------------------------------------------------------------------ */

describe("unit: feed app", () => {
  test("unit: feed: Actionable shows the pending permission with all scope buttons", async () => {
    await startApp();
    assert.ok(host.calls("panel.set_title").some((m) => m.params.title === "Feed"));
    assert.deepEqual(host.calls("panel.subscribe")[0].params.categories, ["feed"]);
    assert.deepEqual(host.calls("feed.list")[0].params, { limit: 200 });
    assert.equal($("feed-tab-actionable").getAttribute("aria-selected"), "true");
    assert.equal($("feed-pending-count").textContent, "1");
    assert.equal(cards().length, 1);
    const card = cards()[0];
    assert.equal(card.querySelector(".feed-kind").textContent, "PERMISSION");
    assert.equal(card.querySelector(".feed-source").textContent, "Claude");
    assert.equal(card.querySelector(".feed-tool").textContent, "Bash");
    assert.equal(card.querySelector(".feed-time").textContent, "1m");
    assert.deepEqual(texts(card, '[data-action="permission"]'), ["Allow Once", "Always Allow", "All tools", "Bypass", "Deny"]);
  });

  test("unit: feed: a permission decision is sent and the card moves under Resolved", async () => {
    const h = await startApp();
    click(window, btn(cards()[0], "permission", '[data-mode="always"]'));
    await settle();
    assert.deepEqual(host.calls("feed.permission.reply").map((m) => m.params), [{ request_id: "req-1", mode: "always" }]);
    assert.ok(doc.querySelector(".feed-divider"));
    const card = cardById(uuid(1));
    assert.equal(card.dataset.status, "resolved");
    assert.equal(card.querySelector(".feed-badge").textContent, "always");
    assert.equal(btn(card, "permission"), null);
    assert.equal($("feed-pending-count").hidden, true);

    // Native's resolution event: the reload carries the resolved item.
    h.setItems([permission(1, { status: "resolved", options: [], resolution: { mode: "always", badge: "always" } })]);
    host.emit("cmux.event", { type: "event", name: "feed.item.resolved" });
    await sleep(60);
    await settle();
    assert.equal(cardById(uuid(1)).querySelector(".feed-badge").textContent, "always");
    assert.equal(app.state.localResolved.size, 0);
  });

  test("unit: feed: a failed decision shows an inline error and keeps the buttons", async () => {
    await startApp({ handlers: { "feed.permission.reply": () => { throw hostError("internal_error", "pipe closed"); } } });
    await app.replyPermission(uuid(1), "once");
    const card = cardById(uuid(1));
    assert.match(card.querySelector(".feed-card-error").textContent, /pipe closed/);
    assert.equal(card.dataset.status, "pending");
    assert.equal(btn(card, "permission").disabled, false);
  });

  test("unit: feed: answering a request resolved elsewhere says so", async () => {
    await startApp({ handlers: { "feed.permission.reply": () => { throw hostError("not_found", "unknown request"); } } });
    await app.replyPermission(uuid(1), "deny");
    assert.equal(cardById(uuid(1)).querySelector(".feed-card-error").textContent, "This request was already resolved.");
  });

  test("unit: feed: All Activity lists every kind with labels, todos and tool results", async () => {
    await startApp({
      items: [
        permission(1),
        item(2, "prompt", { text: "fix the tests\nplease" }),
        item(3, "toolUse", { tool_name: "Edit", detail: "src/a.zig" }),
        item(4, "toolResult", { tool_name: "Bash", is_error: true }),
        item(5, "toolResult", { tool_name: "Read", is_error: false }),
        item(6, "sessionStart"),
        item(7, "sessionEnd"),
        item(8, "notification", { title: "Needs input" }),
        item(9, "todos", { todos: [{ content: "a", status: "completed" }, { content: "b", status: "pending" }, { content: "c", status: "pending" }] }),
      ],
    });
    click(window, $("feed-tab-activity"));
    await settle();
    assert.equal($("feed-tab-activity").getAttribute("aria-selected"), "true");
    assert.deepEqual(texts(doc, "#feed-list .feed-kind"), ["PERMISSION", "PROMPT", "TOOL USE", "TOOL RESULT", "TOOL RESULT", "SESSION START", "SESSION END", "NOTIFICATION", "TODOS"]);
    assert.equal(cardById(uuid(2)).querySelector(".feed-card-title").textContent, "You: fix the tests");
    assert.equal(cardById(uuid(4)).querySelector(".feed-result").textContent, "error");
    assert.equal(cardById(uuid(5)).querySelector(".feed-result").textContent, "ok");
    const todos = cardById(uuid(9));
    assert.equal(todos.querySelector(".feed-card-title").textContent, "Tasks");
    assert.equal(todos.querySelector(".feed-todo-summary span").textContent, "2 open, 1 done");
    assert.equal(todos.querySelector(".feed-todos"), null);
    click(window, btn(todos, "toggle-todos"));
    const open = cardById(uuid(9));
    assert.equal(open.querySelectorAll(".feed-todo").length, 3);
    assert.equal(btn(open, "toggle-todos").textContent, "Collapse");
    assert.equal(btn(open, "toggle-todos").getAttribute("aria-expanded"), "true");
    await sleep(450);
    assert.deepEqual(host.calls("panel.state_changed").at(-1).params.state, { v: 1, filter: "activity" });
  });

  test("unit: feed: plan card renders sanitized markdown and sends modes and feedback", async () => {
    await startApp({ items: [plan(1)] });
    const card = cards()[0];
    assert.equal(card.querySelector(".feed-kind").textContent, "PLAN");
    const box = card.querySelector(".feed-plan");
    assert.ok(box.querySelector("h1"));
    assert.equal(box.querySelector("strong").textContent, "this");
    assert.equal(box.querySelector("script"), null);
    assert.match(card.textContent, /Plan file: C:\\p\\plan\.md/);
    assert.deepEqual(texts(card, ".feed-allowed-list li"), ["run tests"]);
    assert.deepEqual(texts(card, '[data-action="plan"]'), ["Ultraplan", "Manual", "Auto", "Bypass", "Deny"]);

    click(window, box.querySelector("a"));
    await settle();
    assert.deepEqual(host.calls("panel.open_in_browser").map((m) => m.params.url), ["https://example.com/x"]);

    click(window, btn(card, "revise"));
    const area = cardById(uuid(1)).querySelector('[data-field="feedback"]');
    assert.equal(doc.activeElement, area);
    const send = btn(cardById(uuid(1)), "plan-feedback");
    assert.equal(send.disabled, true);
    type(area, "  use a smaller diff  ");
    assert.equal(send.disabled, false);
    click(window, send);
    await settle();
    assert.deepEqual(host.calls("feed.exit_plan.reply").map((m) => m.params), [{ request_id: "req-1", mode: "deny", feedback: "use a smaller diff" }]);
    const done = cardById(uuid(1));
    assert.equal(done.querySelector(".feed-badge").textContent, "refined");
    assert.equal(done.querySelector(".feed-sent").textContent, "use a smaller diff");
    assert.equal(done.querySelector(".feed-card-detail").textContent, "Plan: # Plan");
  });

  test("unit: feed: plan Manual sends the mode without feedback", async () => {
    await startApp({ items: [plan(1, { options: ["manual", "deny"] })] });
    assert.deepEqual(texts(cards()[0], '[data-action="plan"]'), ["Manual", "Deny"]);
    click(window, btn(cards()[0], "plan", '[data-mode="manual"]'));
    await settle();
    assert.deepEqual(host.calls("feed.exit_plan.reply")[0].params, { request_id: "req-1", mode: "manual" });
    assert.equal(cardById(uuid(1)).querySelector(".feed-badge").textContent, "manual");
  });

  test("unit: feed: plan links never navigate: http(s) opens a browser tab, mailto the OS handler", async () => {
    await startApp({ items: [plan(1, { plan: { text: "[mail](mailto:dev@example.com) and [web](https://example.com/y)", allowed_prompts: [] } })] });
    const links = Array.from(cards()[0].querySelectorAll(".feed-plan a"));
    const mail = links.find((a) => a.textContent === "mail");
    const web = links.find((a) => a.textContent === "web");
    assert.ok(mail && web);
    const ev = new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 });
    mail.dispatchEvent(ev);
    assert.equal(ev.defaultPrevented, true);
    click(window, web);
    await settle();
    assert.deepEqual(host.calls("panel.open_external").map((m) => m.params.url), ["mailto:dev@example.com"]);
    assert.deepEqual(host.calls("panel.open_in_browser").map((m) => m.params.url), ["https://example.com/y"]);
  });

  test("unit: feed: single single-choice question answers on click", async () => {
    await startApp({ items: [question(1, [{ question: "Which DB?", header: "Storage", multi_select: false, options: [{ label: "Postgres", description: "" }, { label: "SQLite", description: "small" }] }])] });
    const card = cards()[0];
    assert.equal(card.querySelector(".feed-question-header").textContent, "Storage");
    assert.equal(btn(card, "submit-question").textContent, "Submit");
    click(window, btn(card, "option", '[data-label="SQLite"]'));
    await settle();
    assert.deepEqual(host.calls("feed.question.reply").map((m) => m.params), [{ request_id: "req-1", selections: ["SQLite"] }]);
    const done = cardById(uuid(1));
    assert.equal(done.querySelector(".feed-badge").textContent, "Submitted");
    assert.deepEqual(texts(done, ".feed-answers li"), ["SQLite"]);
  });

  test("unit: feed: multiple questions with multi-select and Other are submitted together", async () => {
    await startApp({
      items: [
        question(1, [
          { question: "Targets?", header: "", multi_select: true, options: [{ label: "win", description: "" }, { label: "linux", description: "" }] },
          { question: "Name?", header: "", multi_select: false, options: [] },
        ]),
      ],
    });
    let card = cards()[0];
    assert.match(card.textContent, /Multi-select/);
    assert.match(card.textContent, /Agent provided no options\./);
    assert.equal(btn(card, "submit-question").textContent, "Submit All Answers");
    assert.equal(btn(card, "submit-question").disabled, true);
    click(window, btn(card, "option", '[data-label="win"]'));
    click(window, btn(cardById(uuid(1)), "option", '[data-label="linux"]'));
    card = cardById(uuid(1));
    assert.equal(btn(card, "option", '[data-label="win"]').getAttribute("aria-pressed"), "true");
    const others = card.querySelectorAll('[data-field="other"]');
    assert.equal(others[1].placeholder, "Type something...");
    others[1].focus();
    type(others[1], "wmux");
    assert.equal(btn(card, "submit-question").disabled, false);
    key(window, others[1], { key: "Enter", ctrlKey: true });
    await settle();
    assert.deepEqual(host.calls("feed.question.reply").map((m) => m.params), [
      { request_id: "req-1", selections: ["win", "linux", "wmux"], answers: [["win", "linux"], ["wmux"]] },
    ]);
  });

  test("unit: feed: typed answers survive live re-renders", async () => {
    const h = await startApp({ items: [question(1, [{ question: "Q", header: "", multi_select: true, options: [{ label: "a", description: "" }] }])] });
    const input = cards()[0].querySelector('[data-field="other"]');
    input.focus();
    type(input, "half typed");
    input.setSelectionRange(4, 4);
    h.setItems([...h.items, item(2, "message")]);
    host.emit("cmux.event", { name: "feed.item.received" });
    await sleep(60);
    await settle();
    const again = cardById(uuid(1)).querySelector('[data-field="other"]');
    assert.notEqual(again, input, "the card was rebuilt");
    assert.equal(again.value, "half typed");
    assert.equal(doc.activeElement, again);
    assert.equal(again.selectionStart, 4);
  });

  test("unit: feed: stop card sends the reply to the agent", async () => {
    await startApp({ items: [item(1, "stop", { hook_event_name: "Stop" })] });
    click(window, $("feed-tab-activity"));
    const card = cards()[0];
    assert.equal(card.querySelector(".feed-card-title").textContent, "Claude finished — reply to continue");
    const area = card.querySelector('[data-field="reply"]');
    assert.equal(area.placeholder, "Reply to Claude…");
    assert.equal(btn(card, "stop-reply").textContent, "Send to Claude");
    assert.equal(btn(card, "stop-reply").disabled, true);
    type(area, "continue with tests");
    click(window, btn(card, "stop-reply"));
    await settle();
    assert.deepEqual(host.calls("panel.feed.stop_reply").map((m) => m.params), [
      { id: uuid(1), text: "continue with tests", session_id: "sess-1", workspace_id: WS, surface_id: SF, source: "claude" },
    ]);
    const done = cardById(uuid(1));
    assert.equal(done.querySelector(".feed-badge").textContent, "Sent");
    assert.equal(done.querySelector(".feed-sent").textContent, "continue with tests");
    assert.equal(done.querySelector('[data-field="reply"]'), null);
  });

  test("unit: feed: double click, the jump button and Enter jump to the agent", async () => {
    await startApp();
    dblclick(window, cards()[0].querySelector(".feed-card-title"));
    await settle();
    click(window, btn(cards()[0], "jump"));
    await settle();
    app.focusCard(uuid(1));
    key(window, cards()[0], { key: "Enter" });
    await settle();
    const calls = host.calls("feed.jump").map((m) => m.params);
    assert.equal(calls.length, 3);
    assert.deepEqual(calls[0], { id: uuid(1), workspace_id: WS, surface_id: SF, session_id: "sess-1", source: "claude" });
    dblclick(window, btn(cards()[0], "permission"));
    await settle();
    assert.equal(host.calls("feed.jump").length, 3, "double click on a button does not jump");
  });

  test("unit: feed: jump outside wmux reports a no-op", async () => {
    await startApp({ handlers: { "feed.jump": () => { throw hostError("not_found", "no surface"); } } });
    await app.jump(uuid(1));
    assert.equal($("feed-status").textContent, "This agent is not running in a wmux terminal.");
  });

  test("unit: feed: new pending decisions raise banners that review and withdraw", async () => {
    const h = await startApp();
    assert.equal($("feed-banners").hidden, true, "no banners for items present at start");
    click(window, $("feed-tab-activity"));
    h.setItems([plan(0.5), ...h.items]);
    host.emit("cmux.event", { name: "feed.item.received" });
    await sleep(60);
    await settle();
    const banner = doc.querySelector(".feed-banner");
    assert.ok(banner);
    assert.equal(banner.querySelector(".feed-banner-title").textContent, "Claude plan ready");
    assert.equal(banner.querySelector(".feed-banner-body").textContent, "Review and approve the plan");
    click(window, btn(banner, "banner-review"));
    await settle();
    assert.equal(app.state.filter, "actionable");
    assert.equal(doc.activeElement, cardById(uuid(0.5)));
    assert.equal($("feed-banners").hidden, true);

    host.emit("panel.feed.item", { item: permission(0.2, { tool_name: "Write" }) });
    await settle();
    assert.equal(doc.querySelector(".feed-banner-body").textContent, "Write needs approval");
    host.emit("panel.feed.item", { item: permission(0.2, { status: "resolved", resolution: { mode: "once", badge: "once" } }) });
    await settle();
    assert.equal($("feed-banners").hidden, true, "banner withdrawn when resolved elsewhere");

    host.emit("panel.feed.item", { item: question(0.1, []) });
    await settle();
    click(window, btn(doc.querySelector(".feed-banner"), "banner-dismiss"));
    assert.equal($("feed-banners").hidden, true);
  });

  test("unit: feed: empty states per tab", async () => {
    await startApp({ items: [] });
    assert.equal($("feed-empty").hidden, false);
    assert.equal($("feed-empty-title").textContent, "No pending decisions");
    assert.equal($("feed-empty-body").textContent, "Permission, plan, and question requests from AI agents will appear here.");
    app.setFilter("activity");
    assert.equal($("feed-empty-title").textContent, "No activity yet");
    assert.equal($("feed-empty-body").textContent, "Agent decisions and todo-list updates will appear here.");
  });

  test("unit: feed: Load older activity pages history with the before cursor", async () => {
    const older = [item(300, "message", { title: "old" })];
    await startApp({ hasMore: true, params: { filter: "activity" }, older: () => ({ items: older, has_more: false }) });
    const more = $("feed-load-older");
    assert.equal(more.hidden, false);
    assert.equal(more.textContent, "Load older activity");
    const pending = app.loadOlder();
    assert.equal(more.textContent, "Loading older activity...");
    assert.equal(more.disabled, true);
    await pending;
    assert.deepEqual(host.calls("feed.list").at(-1).params, { before: uuid(3), limit: 200 });
    assert.equal(cards().at(-1).dataset.id, uuid(300));
    assert.equal(more.hidden, true);

    host.emit("cmux.event", { name: "feed.item.completed" });
    await sleep(60);
    await settle();
    assert.ok(cardById(uuid(300)), "paged-in history survives a reload");
  });

  test("unit: feed: keyboard moves between cards and tabs", async () => {
    await startApp({ params: { filter: "activity" } });
    app.focusCard(uuid(1));
    key(window, doc.activeElement, { key: "ArrowDown" });
    assert.equal(doc.activeElement, cardById(uuid(2)));
    key(window, doc.activeElement, { key: "j" });
    assert.equal(doc.activeElement, cardById(uuid(3)));
    key(window, doc.activeElement, { key: "ArrowDown" });
    assert.equal(doc.activeElement, cardById(uuid(3)));
    key(window, doc.activeElement, { key: "Home" });
    assert.equal(doc.activeElement, cardById(uuid(1)));
    key(window, doc.activeElement, { key: "End" });
    key(window, doc.activeElement, { key: "k" });
    assert.equal(doc.activeElement, cardById(uuid(2)));
    assert.equal(cardById(uuid(2)).tabIndex, 0);
    assert.equal(cardById(uuid(1)).tabIndex, -1);

    $("feed-tab-activity").focus();
    key(window, $("feed-tab-activity"), { key: "ArrowRight" });
    assert.equal(app.state.filter, "actionable");
    assert.equal(doc.activeElement, $("feed-tab-actionable"));
    key(window, $("feed-tab-actionable"), { key: "ArrowLeft" });
    assert.equal(app.state.filter, "activity");
  });

  test("unit: feed: untrusted item text never becomes markup", async () => {
    await startApp({
      params: { filter: "activity" },
      items: [item(1, "message", { title: "<img src=x onerror=alert(1)>", detail: "<b>bold</b>" }), permission(2, { tool_name: "<script>x</script>" })],
    });
    assert.equal(doc.querySelector("#feed-list img, #feed-list script, #feed-list b"), null);
    assert.equal(cardById(uuid(1)).querySelector(".feed-card-title").textContent, "<img src=x onerror=alert(1)>");
    assert.equal(cardById(uuid(2)).querySelector(".feed-tool").textContent, "<script>x</script>");
  });

  test("unit: feed: decisions without a request id are shown without buttons", async () => {
    await startApp({ items: [permission(1, { request_id: undefined }), question(2, [{ question: "Q?", header: "", multi_select: false, options: [{ label: "a", description: "" }] }], { request_id: undefined })] });
    assert.equal(cards().length, 2);
    assert.equal(doc.querySelector('#feed-list [data-action="permission"], #feed-list [data-action="option"]'), null);
    assert.equal(await app.replyPermission(uuid(1), "once"), false);
    assert.equal(host.calls("feed.permission.reply").length, 0);
  });

  test("unit: feed: restored state and params pick the tab", async () => {
    await startApp({ state: { v: 1, filter: "activity" } });
    assert.equal(app.state.filter, "activity");
    assert.equal(cards().length, 3);
    await startApp({ state: { v: 1, filter: "activity" }, params: { filter: "actionable" } });
    assert.equal(app.state.filter, "actionable");
    await startApp({ state: { v: 1, filter: "bogus" } });
    assert.equal(app.state.filter, "actionable");
  });

  test("unit: feed: commands, snapshots and load failures", async () => {
    await startApp();
    host.emit("panel.feed.command", { action: "showActivity" });
    assert.equal(app.state.filter, "activity");
    host.emit("panel.feed.command", { action: "showActionable" });
    assert.equal(app.state.filter, "actionable");
    host.emit("panel.feed.command", { action: "focus" });
    assert.equal(doc.activeElement, cardById(uuid(1)));
    host.emit("panel.feed.snapshot", { items: [item(7, "message")], has_more: false });
    app.setFilter("activity");
    assert.deepEqual(cards().map((c) => c.dataset.id), [uuid(7)]);
    host.emit("panel.feed.command", { action: "nope" });

    await startApp({ handlers: { "feed.list": () => { throw hostError("internal_error", "store busy"); } } });
    assert.match($("feed-status").textContent, /Could not load the feed: store busy/);
    assert.equal($("feed-empty").hidden, false);
  });

  test("unit: feed: workstream chips jump to each agent", async () => {
    await startApp({ items: [permission(1, { session_id: "aaaaaaaa-1111" }), item(2, "message", { source: "codex", session_id: "bbbbbbbb-2222", surface_id: "AAAAAAAA-0000-4000-8000-000000000009" })] });
    const chips = Array.from(doc.querySelectorAll("#feed-workstreams .feed-stream"));
    assert.equal($("feed-workstreams").hidden, false);
    assert.deepEqual(chips.map((c) => c.firstChild.textContent), ["Claude · aaaaaaaa", "Codex · bbbbbbbb"]);
    assert.equal(chips[0].querySelector(".feed-count").textContent, "1");
    click(window, chips[1]);
    await settle();
    assert.equal(host.calls("feed.jump")[0].params.id, uuid(2));
  });

  test("unit: feed: huge feeds and unicode render", async () => {
    const many = Array.from({ length: 2500 }, (_, i) => item(i + 1, "message", { title: `メッセージ ${i} 🚀` }));
    await startApp({ items: many, params: { filter: "activity" } });
    assert.equal(cards().length, model.MAX_ITEMS);
    assert.equal(cards()[0].querySelector(".feed-card-title").textContent, "メッセージ 0 🚀");
  });
});
