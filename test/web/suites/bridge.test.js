// src/web/_shared/wmux-bridge.js against the mock host in a real browser:
// call/reply, error objects, timeouts, events, ready handshake, theme sync.
// Every test imports the bridge into a fresh frame, so each gets its own
// singleton (the bridge keeps one instance per page).
import { createMockHost, reply, DEFAULT_THEME } from "../mock-host.js";
import {
  test, run, assertEqual, assertDeepEqual, assertMatch, assertTrue, assertThrows, assertRejects, waitFor, sleep,
} from "../lib/assert.js";
import { loadFrame } from "../lib/harness.js";

const BRIDGE = new URL("../../../src/web/_shared/wmux-bridge.js", import.meta.url).href;
const THEME = new URL("../../../src/web/_shared/theme.js", import.meta.url).href;

/** Fresh frame + bridge. `hostOptions === null` loads the frame without a WebView2 host. */
async function fresh(hostOptions) {
  const host = hostOptions === null ? null : createMockHost(hostOptions || {});
  const page = await loadFrame(host);
  const mod = await page.import(BRIDGE);
  return { host, page, mod, wmux: mod.wmux };
}

test("bridge: call posts a v1 envelope and resolves with the result", async () => {
  const { host, page, wmux } = await fresh({ responses: { "workspace.list": { workspaces: [{ id: "w1" }] } } });
  const result = await wmux.call("workspace.list", { all: true });
  assertDeepEqual(result, { workspaces: [{ id: "w1" }] });
  const call = host.lastCall("workspace.list");
  assertDeepEqual(call.message, { v: 1, id: call.id, method: "workspace.list", params: { all: true } });
  assertMatch(call.id, /^c[0-9]+$/);
  assertEqual(wmux.pendingCount, 0, "nothing pending");
  assertTrue(Array.isArray(result.workspaces) && result.workspaces instanceof page.window.Array, "result parsed in the page realm");
  page.remove();
});

test("bridge: omitted or null params become {} and ids are unique", async () => {
  const { host, page, wmux } = await fresh({ responses: { "a.b": 1 } });
  await Promise.all([wmux.call("a.b"), wmux.call("a.b", null), wmux.call(" a.b ")]);
  const calls = host.callsTo("a.b");
  assertEqual(calls.length, 3, "method names are trimmed");
  for (const c of calls) assertDeepEqual(c.params, {});
  assertEqual(new Set(calls.map((c) => c.id)).size, 3, "unique ids");
  page.remove();
});

test("bridge: a reply without result resolves with null", async () => {
  const { page, wmux } = await fresh({
    unhandled: (params, call) => reply.raw({ v: 1, id: call.id, ok: true }),
  });
  assertEqual(await wmux.call("x.y"), null);
  page.remove();
});

test("bridge: invalid calls reject without posting", async () => {
  const { host, page, wmux, mod } = await fresh({});
  const missing = await assertRejects(wmux.call(""), { code: "invalid_request", message: "Missing method" });
  assertTrue(missing instanceof mod.WmuxError, "WmuxError instance");
  await assertRejects(wmux.call("   "), { code: "invalid_request" });
  await assertRejects(wmux.call("a.b", [1, 2]), { code: "invalid_params", method: "a.b" });
  await assertRejects(wmux.call("a.b", "text"), { code: "invalid_params" });
  const cyclic = {};
  cyclic.self = cyclic;
  await assertRejects(wmux.call("a.b", { cyclic }), { code: "encode_error", message: "Failed to encode JSON" });
  await assertRejects(wmux.call("a.b", { big: 10n }), { code: "encode_error" });
  assertEqual(host.calls.length, 0, "nothing was posted");
  page.remove();
});

test("bridge: error replies become WmuxError objects", async () => {
  const { page, wmux, mod } = await fresh({
    responses: {
      "workspace.close": reply.error("forbidden", "Method not allowed for this panel", {
        data: { method: "workspace.close" },
        reason: "allowlist",
        action: "none",
        details: { kind: "about" },
      }),
    },
  });
  const err = await assertRejects(wmux.call("workspace.close"));
  assertTrue(err instanceof mod.WmuxError, "instanceof WmuxError");
  assertTrue(err instanceof page.window.Error, "an Error of the page realm");
  assertEqual(err.name, "WmuxError");
  assertEqual(err.code, mod.ErrorCode.FORBIDDEN);
  assertEqual(err.message, "Method not allowed for this panel");
  assertDeepEqual(err.data, { method: "workspace.close" });
  assertEqual(err.reason, "allowlist");
  assertEqual(err.action, "none");
  assertDeepEqual(err.details, { kind: "about" });
  assertEqual(err.method, "workspace.close");
  assertDeepEqual(JSON.parse(JSON.stringify(err)), {
    code: "forbidden",
    message: "Method not allowed for this panel",
    data: { method: "workspace.close" },
    reason: "allowlist",
    action: "none",
    details: { kind: "about" },
    method: "workspace.close",
  });
  page.remove();
});

test("bridge: malformed error replies map to internal_error", async () => {
  const { page, wmux } = await fresh({
    responses: {
      "bad.one": (p, call) => reply.raw({ v: 1, id: call.id, ok: false, error: "nope" }),
      "bad.two": (p, call) => reply.raw({ v: 1, id: call.id, ok: false, error: { message: "" } }),
    },
  });
  await assertRejects(wmux.call("bad.one"), { code: "internal_error", message: "Malformed error reply from the wmux host" });
  await assertRejects(wmux.call("bad.two"), { code: "internal_error", message: "internal_error" });
  page.remove();
});

test("bridge: a call times out with bridge-stage data and late replies are dropped", async () => {
  const { host, page, wmux } = await fresh({ responses: { "slow.never": reply.never(), "slow.late": reply.delay(400, { late: true }) } });
  const err = await assertRejects(wmux.call("slow.never", {}, { timeoutMs: 200 }), { code: "timeout" });
  assertDeepEqual(err.data, { stage: "bridge", deadline_ms: 200, retryable: false });
  assertEqual(err.message, "Timed out waiting for a reply to slow.never");
  await assertRejects(wmux.call("slow.late", {}, { timeoutMs: 100 }), { code: "timeout" });
  assertEqual(wmux.pendingCount, 0, "timed-out calls are not pending");
  await host.waitForCall("slow.late");
  await waitFor(() => host.lastCall("slow.late").reply !== null, { message: "late reply sent" });
  await sleep(20); // the dropped reply must not throw or settle anything
  page.remove();
});

test("bridge: native timeout errors pass through", async () => {
  const { page, wmux } = await fresh({
    responses: { "ui.lane": reply.error("timeout", "main actor timeout", { data: { stage: "main_actor", deadline_ms: 10000 } }) },
  });
  const err = await assertRejects(wmux.call("ui.lane"), { code: "timeout" });
  assertEqual(err.data.stage, "main_actor");
  page.remove();
});

test("bridge: an AbortSignal cancels a call", async () => {
  const { page, wmux } = await fresh({ responses: { "slow.never": reply.never() } });
  const ctrl = new page.window.AbortController();
  const pending = wmux.call("slow.never", {}, { signal: ctrl.signal });
  assertEqual(wmux.pendingCount, 1);
  ctrl.abort();
  await assertRejects(pending, { code: "cancelled", message: "Request cancelled" });
  assertEqual(wmux.pendingCount, 0);
  const pre = new page.window.AbortController();
  pre.abort();
  await assertRejects(wmux.call("slow.never", {}, { signal: pre.signal }), { code: "cancelled" });
  page.remove();
});

test("bridge: send is fire-and-forget", async () => {
  const { host, page, wmux } = await fresh({});
  assertEqual(wmux.send("panel.state_changed", { state: { a: 1 } }), true);
  const call = await host.waitForCall("panel.state_changed");
  assertTrue(call.fireAndForget, "no id");
  assertDeepEqual(call.message, { v: 1, method: "panel.state_changed", params: { state: { a: 1 } } });
  assertEqual(wmux.send(""), false, "invalid send returns false");
  assertEqual(wmux.send("a.b", [1]), false);
  await sleep(20);
  assertEqual(call.reply, null, "native sends no reply");
  page.remove();
});

test("bridge: host events reach on, once, wildcard and stop after unsubscribe", async () => {
  const { host, page, wmux } = await fresh({});
  const seen = [];
  const off = wmux.on("cmux.event", (payload, name) => seen.push(["on", name, payload]));
  wmux.once("cmux.event", (payload) => seen.push(["once", payload.n]));
  const offAll = wmux.on("*", (payload, name) => seen.push(["*", name]));
  host.emit("cmux.event", { n: 1, text: "héllo 👋 مرحبا" });
  await waitFor(() => seen.length >= 3, { message: "first event" });
  off();
  host.emit("cmux.event", { n: 2 });
  host.emit("wmux.custom", null);
  await waitFor(() => seen.filter((s) => s[0] === "*").length === 3, { message: "wildcard events" });
  offAll();
  host.emit("cmux.event", { n: 3 });
  await sleep(20);
  assertDeepEqual(seen, [
    ["on", "cmux.event", { n: 1, text: "héllo 👋 مرحبا" }],
    ["once", 1],
    ["*", "cmux.event"],
    ["*", "cmux.event"],
    ["*", "wmux.custom"],
  ]);
  assertThrows(() => wmux.on("", () => {}), TypeError);
  assertThrows(() => wmux.on("x", null), TypeError);
  page.remove();
});

test("bridge: ignores foreign versions, garbage and unknown reply ids", async () => {
  const { host, page, wmux } = await fresh({ responses: { "a.b": { ok: 1 } } });
  const seen = [];
  wmux.on("cmux.event", (payload) => seen.push(payload));
  host.post({ v: 2, event: "cmux.event", payload: "v2" });
  host.post("not json {");
  host.post("[1,2]");
  host.post({ v: 1, id: "c999", ok: true, result: 1 });
  host.post({ v: 1, something: "else" });
  host.post({ event: "cmux.event", payload: "no-v" });
  host.post(JSON.stringify({ v: 1, event: "cmux.event", payload: "string-json" }));
  assertDeepEqual(await wmux.call("a.b"), { ok: 1 }, "still works after junk");
  await waitFor(() => seen.length === 2, { message: "accepted events" });
  assertDeepEqual(seen, ["no-v", "string-json"]);
  page.remove();
});

test("bridge: ready handshake resolves with panel.init (event mode)", async () => {
  const init = { kind: "about", params: { a: 1 }, state: { s: 2 }, keymap: { closeTab: ["ctrl+w"] }, settings: { x: true } };
  const { host, page, wmux } = await fresh({ init });
  assertEqual(wmux.context, null, "no context before ready");
  const first = wmux.ready();
  assertTrue(wmux.ready() === first, "ready() is idempotent while pending");
  const ctx = await first;
  assertEqual(ctx.kind, "about");
  assertDeepEqual(ctx.params, { a: 1 });
  assertDeepEqual(ctx.state, { s: 2 });
  assertDeepEqual(ctx.keymap, { closeTab: ["ctrl+w"] });
  assertDeepEqual(ctx.settings, { x: true });
  assertEqual(ctx.surface_id, host.init.surface_id);
  assertTrue(wmux.context === ctx, "context exposes the payload");
  assertEqual(host.callsTo("panel.ready").length, 1, "panel.ready sent once");
  assertTrue((await wmux.ready()) === ctx, "later ready() resolves with the same context");
  assertEqual(host.callsTo("panel.ready").length, 1, "no second panel.ready");
  page.remove();
});

test("bridge: ready handshake accepts the init payload as the panel.ready result", async () => {
  const { host, page, wmux } = await fresh({ readyMode: "result", init: { kind: "markdown" } });
  const ctx = await wmux.ready();
  assertEqual(ctx.kind, "markdown");
  assertEqual(wmux.context.kind, "markdown");
  assertEqual(host.callsTo("panel.ready").length, 1);
  page.remove();
});

test("bridge: ready times out without panel.init and can be retried", async () => {
  const { host, page, wmux } = await fresh({ readyMode: "none" });
  const err = await assertRejects(wmux.ready({ timeoutMs: 200 }), { code: "timeout", method: "panel.ready" });
  assertEqual(err.data.retryable, true);
  host.setReadyMode("event");
  const ctx = await wmux.ready({ timeoutMs: 2000 });
  assertEqual(ctx.kind, "test");
  assertEqual(host.callsTo("panel.ready").length, 2, "the retry sent panel.ready again");
  page.remove();
});

test("bridge: a late panel.init updates the context and reaches listeners", async () => {
  const { host, page, wmux } = await fresh({ init: { kind: "todo" } });
  await wmux.ready();
  const seen = [];
  wmux.on("panel.init", (ctx) => seen.push(ctx.params.workspace_id));
  host.sendInit({ params: { workspace_id: "w2" } });
  await waitFor(() => seen.length === 1, { message: "panel.init listener" });
  assertEqual(seen[0], "w2");
  assertEqual(wmux.context.params.workspace_id, "w2");
  host.post({ v: 1, event: "panel.init", payload: [1] });
  await sleep(20);
  assertEqual(wmux.context.params.workspace_id, "w2", "malformed panel.init ignored");
  page.remove();
});

test("bridge: theme sync updates wmux.theme and theme.js CSS variables", async () => {
  const { host, page, wmux } = await fresh({ init: { theme: Object.assign({}, DEFAULT_THEME, { background: "#202124" }) } });
  const theme = await page.import(THEME);
  const root = page.document.documentElement;
  await wmux.ready();
  assertEqual(wmux.theme.background, "#202124", "theme from panel.init");
  await waitFor(() => root.getAttribute("data-wmux-theme") === "host", { message: "theme applied from panel.init" });
  assertEqual(root.style.getPropertyValue("--wmux-bg").trim().toLowerCase(), "#202124");
  assertEqual(root.getAttribute("data-wmux-scheme"), "dark");
  const events = [];
  wmux.on("theme", (payload) => events.push(payload.background));
  host.setTheme({ background: "#fafafa", foreground: "#202020", font_size_px: 15, scheme: "light", high_contrast: true });
  await waitFor(() => root.getAttribute("data-wmux-scheme") === "light", { message: "light theme applied" });
  assertEqual(root.style.getPropertyValue("--wmux-bg").trim().toLowerCase(), "#fafafa");
  assertEqual(root.getAttribute("data-wmux-high-contrast"), "true");
  assertDeepEqual(events, ["#fafafa"]);
  assertEqual(wmux.theme.background, "#fafafa", "wmux.theme follows the event");
  assertEqual(wmux.context.theme.background, "#fafafa", "context.theme follows the event");
  assertEqual(theme.currentTheme().scheme, "light");
  assertEqual(host.init.theme.background, "#fafafa", "a later panel.init would carry the new theme");
  page.remove();
});

test("bridge: outside a WebView2 host calls reject with unavailable", async () => {
  const { page, wmux } = await fresh(null);
  assertEqual(wmux.available, false);
  await assertRejects(wmux.call("workspace.list"), { code: "unavailable", method: "workspace.list" });
  await assertRejects(wmux.ready({ timeoutMs: 100 }), { code: "unavailable", method: "panel.ready" });
  assertEqual(wmux.send("a.b"), false);
  page.remove();
});

test("bridge: posting to a torn-down host rejects with unavailable", async () => {
  const { host, page, wmux } = await fresh({});
  host.close();
  const err = await assertRejects(wmux.call("a.b"), { code: "unavailable", message: "Failed to post a message to the wmux host" });
  assertMatch(err.data.reason, "closed");
  assertEqual(wmux.pendingCount, 0);
  page.remove();
});

test("bridge: panel.setState enforces the 64 KiB cap in UTF-8 bytes", async () => {
  const { host, page, wmux, mod } = await fresh({ responses: { "panel.state_changed": null } });
  await wmux.ready();
  // JSON of a string of n ASCII chars is n + 2 bytes.
  await wmux.panel.setState("a".repeat(mod.MAX_STATE_BYTES - 2));
  assertEqual(host.lastCall("panel.state_changed").params.state.length, mod.MAX_STATE_BYTES - 2, "exactly 64 KiB passes");
  const over = await assertRejects(wmux.panel.setState("a".repeat(mod.MAX_STATE_BYTES - 1)), { code: "invalid_params" });
  assertDeepEqual(over.data, { bytes: mod.MAX_STATE_BYTES + 1, limit: mod.MAX_STATE_BYTES });
  // "€" is 3 bytes in UTF-8 but one UTF-16 unit.
  const euros = "€".repeat(Math.floor(mod.MAX_STATE_BYTES / 3));
  await assertRejects(wmux.panel.setState({ euros }), { code: "invalid_params" });
  await wmux.panel.setState({ small: "€" });
  assertDeepEqual(wmux.context.state, { small: "€" }, "context.state follows");
  await wmux.panel.setState(undefined);
  assertEqual(host.lastCall("panel.state_changed").params.state, null, "undefined state is sent as null");
  page.remove();
});

test("bridge: panel helpers post their documented params", async () => {
  const methods = ["panel.set_title", "panel.set_dirty", "panel.open_external", "panel.open_in_browser", "panel.open_file",
    "panel.clipboard_write", "panel.request_focus", "panel.key_capture", "panel.subscribe", "panel.notify"];
  const responses = {};
  for (const m of methods) responses[m] = null;
  const { host, page, wmux } = await fresh({ responses });
  await wmux.panel.setTitle(42);
  await wmux.panel.setDirty("yes");
  await wmux.panel.openExternal("https://example.org/");
  await wmux.panel.openInBrowser("https://example.org/b");
  await wmux.panel.openFile("C:\\tmp\\a.md");
  await wmux.panel.clipboardWrite("t");
  await wmux.panel.clipboardWrite("t", "<b>t</b>");
  await wmux.panel.requestFocus();
  await wmux.panel.keyCapture(1);
  await wmux.panel.subscribe("feed");
  await wmux.panel.notify("Title");
  await wmux.panel.notify("Title", "Body");
  assertDeepEqual(host.calls.map((c) => [c.method, c.params]), [
    ["panel.set_title", { title: "42" }],
    ["panel.set_dirty", { dirty: true }],
    ["panel.open_external", { url: "https://example.org/" }],
    ["panel.open_in_browser", { url: "https://example.org/b" }],
    ["panel.open_file", { path: "C:\\tmp\\a.md" }],
    ["panel.clipboard_write", { text: "t" }],
    ["panel.clipboard_write", { text: "t", html: "<b>t</b>" }],
    ["panel.request_focus", {}],
    ["panel.key_capture", { on: true }],
    ["panel.subscribe", { categories: ["feed"] }],
    ["panel.notify", { title: "Title" }],
    ["panel.notify", { title: "Title", body: "Body" }],
  ]);
  page.remove();
});

test("bridge: huge and unicode payloads round-trip intact", async () => {
  const { host, page, wmux } = await fresh({ responses: { "echo": (params) => params } });
  const big = "x".repeat(2 * 1024 * 1024);
  const text = "naïve café 日本語 👩‍💻 \u202Eمرحبا\u202C \u0000 \"quoted\" </script>";
  const result = await wmux.call("echo", { big, text, nested: { list: [1, 2.5, -0, null, true] } });
  assertEqual(result.big.length, big.length, "2 MiB string");
  assertEqual(result.text, text, "unicode text");
  assertDeepEqual(result.nested, { list: [1, 2.5, 0, null, true] });
  assertEqual(host.lastCall("echo").params.text, text, "recorded params");
  page.remove();
});

test("bridge: one shared instance, page globals and the cmux alias", async () => {
  const { host, page, wmux, mod } = await fresh({ responses: { "system.ping": { pong: true } } });
  const again = await page.import(BRIDGE + "?second-url");
  assertTrue(again.wmux === wmux, "a second module instance reuses the singleton");
  assertTrue(page.window.wmux === wmux, "window.wmux");
  assertTrue(page.window.cmux === mod.cmux, "window.cmux");
  assertDeepEqual(await mod.cmux("system.ping"), { pong: true });
  assertEqual(host.callsTo("system.ping").length, 1);
  assertEqual(mod.PROTOCOL_VERSION, 1);
  assertTrue(Object.isFrozen(wmux), "bridge object is frozen");
  page.remove();
});

run({ suite: "bridge" });
