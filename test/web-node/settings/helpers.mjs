// Shared setup for the settings panel tests: a jsdom page loaded from
// src/web/settings/index.html and a mock WebView2 host (window.chrome.webview)
// that speaks the bridge envelope, the same pattern as markdown.test.mjs.
//
// jsdom is not vendored: install it outside the repo and point
// WMUX_WEB_TEST_DEPS at that directory (the one containing node_modules/):
//
//   npm install --prefix ../.webtest --ignore-scripts jsdom@26
//   WMUX_WEB_TEST_DEPS=../.webtest node --test 'test/web-node/settings/*.test.mjs'
//
// Node runs each test file in its own process, so every file gets a fresh page.
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
export const repo = path.resolve(here, "../../..");
export const web = path.join(repo, "src/web");
const depsDir = process.env.WMUX_WEB_TEST_DEPS;
const requireDeps = createRequire(depsDir ? path.join(path.resolve(depsDir), "package.json") : import.meta.url);
const { JSDOM } = requireDeps("jsdom");

const indexHtml = readFileSync(path.join(web, "settings/index.html"), "utf8");
export const dom = new JSDOM(indexHtml, {
  url: "https://settings.wmux.example/settings/index.html",
  pretendToBeVisual: true,
});
export const { window } = dom;
export const pristineBody = window.document.body.innerHTML;

/** Mock of window.chrome.webview: records posts, answers calls from `handlers`. */
export const host = {
  sent: [],
  listeners: [],
  handlers: new Map(),
  postMessage(message) {
    const msg = JSON.parse(JSON.stringify(message));
    this.sent.push(msg);
    if (msg.id === undefined) return;
    Promise.resolve().then(async () => {
      const handler = this.handlers.get(msg.method);
      let reply;
      if (!handler) {
        reply = { v: 1, id: msg.id, ok: false, error: { code: "method_not_found", message: "Unknown method" } };
      } else {
        try {
          const result = await handler(msg.params || {}, msg);
          reply = { v: 1, id: msg.id, ok: true, result: result === undefined ? {} : result };
        } catch (err) {
          reply = {
            v: 1,
            id: msg.id,
            ok: false,
            error: { code: err.code || "internal_error", message: err.message || String(err) },
          };
        }
      }
      this.deliver(reply);
    });
  },
  addEventListener(type, fn) {
    if (type === "message") this.listeners.push(fn);
  },
  removeEventListener(type, fn) {
    this.listeners = this.listeners.filter((l) => l !== fn);
  },
  deliver(data) {
    for (const fn of this.listeners) fn({ data });
  },
  emit(event, payload) {
    this.deliver({ v: 1, event, payload });
  },
  calls(method) {
    return this.sent.filter((m) => m.method === method);
  },
  reset() {
    this.sent = [];
    this.handlers = new Map();
  },
};

export function hostError(code, message) {
  const err = new Error(message || code);
  err.code = code;
  return err;
}

// Globals the page modules expect (the bridge reads chrome.webview at import time).
window.chrome = { webview: host };
for (const name of [
  "window",
  "document",
  "Node",
  "NodeFilter",
  "Element",
  "HTMLElement",
  "Event",
  "CustomEvent",
  "KeyboardEvent",
  "MouseEvent",
  "FocusEvent",
  "InputEvent",
  "DocumentFragment",
  "getComputedStyle",
]) {
  const value = name === "window" ? window : window[name];
  Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });
}
globalThis.chrome = window.chrome;

export const importWeb = (rel) => import(pathToFileURL(path.join(web, rel)).href);

/** The committed generated schema (the fixture the task names). */
export function committedSchema() {
  return JSON.parse(readFileSync(path.join(repo, "docs/wmux/schema/wmux.schema.json"), "utf8"));
}

/** The schema golden file of schema_dump.zig: every control kind and hint. */
export function goldenSchema() {
  return JSON.parse(readFileSync(path.join(repo, "src/wmux_proto/settings/testdata/schema_golden.json"), "utf8"));
}

/** Let pending promise callbacks and bridge replies run. */
export async function flush(rounds = 6) {
  for (let i = 0; i < rounds; i += 1) await new Promise((resolve) => setTimeout(resolve, 0));
}

export function $(selector, root) {
  return (root || window.document).querySelector(selector);
}

export function $$(selector, root) {
  return Array.from((root || window.document).querySelectorAll(selector));
}

/** Dispatch a keydown on `target` (default: the focused element or document). */
export function keydown(init, target) {
  const el = target || window.document.activeElement || window.document;
  const ev = new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init });
  el.dispatchEvent(ev);
  return ev;
}

/** Set an input's value and fire input + change like a user edit. */
export function edit(el, value) {
  el.value = value;
  el.dispatchEvent(new window.Event("input", { bubbles: true }));
  el.dispatchEvent(new window.Event("change", { bubbles: true }));
}

/* ------------------------------------------------------------------------ */
/* fixtures: schema + a fake native settings store                           */
/* ------------------------------------------------------------------------ */

/** Golden schema plus a few keys the tests need (terminal row, pane resize, nullable color). */
export function fixtureSchema() {
  const schema = goldenSchema();
  const p = schema.properties;
  p.terminal.properties.showScrollBar = {
    title: "Show scroll bar",
    description: "Overlay scroll bar for the scrollback.",
    type: "boolean",
    default: true,
    "x-cmux-scopes": ["global"],
    "x-wmux-section": "terminal",
  };
  p.app.properties.paneResizeStepPixels = {
    title: "Pane resize step",
    description: "Pixels per resize key press.",
    type: "integer",
    minimum: 1,
    maximum: 200,
    default: 20,
    "x-cmux-scopes": ["global"],
    "x-wmux-section": "app",
  };
  p.sidebar.properties.selectionColor = {
    title: "Selection color",
    description: "Selected workspace background.",
    type: ["string", "null"],
    pattern: "^#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$",
    default: null,
    "x-cmux-scopes": ["global"],
    "x-wmux-section": "sidebarAppearance",
  };
  p.shortcuts = {
    type: "object",
    properties: {
      bindings: {
        title: "Bindings",
        description: "Shortcut overrides.",
        type: "object",
        default: {},
        "x-wmux-section": "keyboardShortcuts",
      },
      showModifierHoldHints: {
        title: "Modifier hold hints",
        description: "Hint chips while holding Ctrl.",
        type: "boolean",
        default: true,
        "x-wmux-section": "keyboardShortcuts",
      },
    },
  };
  return schema;
}

function defaultsOf(schema) {
  const out = {};
  const walk = (props, prefix) => {
    for (const [k, node] of Object.entries(props)) {
      const path = prefix ? `${prefix}.${k}` : k;
      if (!prefix && ["$schema", "schemaVersion", "packs"].includes(k)) continue;
      if (Object.prototype.hasOwnProperty.call(node, "default") || node["x-wmux-section"])
        out[path] = node.default ?? null;
      else if (node.properties) walk(node.properties, path);
    }
  };
  walk(schema.properties, "");
  return out;
}

/**
 * Fake native settings store: layers default < cmux.json < wmux.json < policy.
 * Installs the wmux.settings.* handlers on the mock host.
 */
export function createStore({ schema = fixtureSchema(), cmux = {}, wmux = {}, policy = {} } = {}) {
  const store = { schema, defaults: defaultsOf(schema), cmux: { ...cmux }, wmux: { ...wmux }, policy: { ...policy } };
  store.effective = () => {
    const values = {};
    for (const path of Object.keys(store.defaults)) {
      let entry = { value: store.defaults[path], source: "default" };
      if (path in store.cmux) entry = { value: store.cmux[path], source: "cmux.json" };
      if (path in store.wmux) entry = { value: store.wmux[path], source: "wmux.json" };
      if (path in store.policy) entry = { value: store.policy[path], source: "policy", locked: true };
      values[path] = entry;
    }
    return values;
  };
  store.install = () => {
    host.handlers.set("wmux.settings.schema", () => ({ schema: store.schema }));
    host.handlers.set("wmux.settings.get_effective", () => ({
      values: store.effective(),
      files: { wmux: "C:\\Users\\me\\.config\\wmux\\wmux.json" },
    }));
    host.handlers.set("wmux.settings.set", ({ path: p, value }) => {
      if (p in store.policy) throw hostError("policy_locked", "Managed by your organization");
      if (!(p in store.defaults)) throw hostError("invalid_params", `Unknown setting ${p}`);
      store.wmux[p] = value;
      return { path: p, ...store.effective()[p] };
    });
    host.handlers.set("wmux.settings.unset", ({ path: p }) => {
      delete store.wmux[p];
      return { path: p, ...(store.effective()[p] || { value: null, source: "default" }) };
    });
    host.handlers.set("wmux.settings.reset_all", () => {
      store.wmux = {};
      return {};
    });
    host.handlers.set("wmux.settings.open_file", () => ({}));
    host.handlers.set("wmux.settings.open_docs", () => ({}));
  };
  return store;
}

export const BASE_HANDLERS = {
  "panel.ready": () => ({}),
  "panel.set_title": () => ({}),
  "panel.state_changed": () => ({}),
  "panel.key_capture": () => ({}),
  "panel.open_external": () => ({}),
};

let currentApp = null;

/**
 * Start a fresh settings app on a fresh body.
 * @param {{store?: object, init?: object, handlers?: Record<string, Function>}} [opts]
 */
export async function startSettings(opts = {}) {
  const { createApp } = await importWeb("settings/app.js");
  if (currentApp) currentApp.destroy();
  window.document.body.innerHTML = pristineBody;
  host.reset();
  for (const [m, fn] of Object.entries(BASE_HANDLERS)) host.handlers.set(m, fn);
  const store = opts.store || createStore();
  store.install();
  for (const [m, fn] of Object.entries(opts.handlers || {})) host.handlers.set(m, fn);
  host.emit("panel.init", {
    kind: "settings",
    surface_id: "5B1D2C9E-0000-4000-8000-000000000002",
    params: {},
    state: null,
    theme: { background: "#1e1e1e", foreground: "#d4d4d4" },
    keymap: {},
    settings: {},
    ...(opts.init || {}),
  });
  const app = createApp({ document: window.document });
  currentApp = app;
  const started = await app.start();
  await flush();
  return { app, store, started };
}

/** The row element for a settings path in the current view. */
export function rowEl(p) {
  return window.document.querySelector(`.set-row[data-path="${p}"]`);
}
