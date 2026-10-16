// Diff panel test harness: a jsdom page loaded from src/web/diff/index.html,
// the mock WebView2 host (window.chrome.webview) speaking the bridge envelope
// (same shape as the one in ../markdown.test.mjs), and the vendored
// highlight.js and DOMPurify.
//
// jsdom is not vendored: install it outside the repo and point
// WMUX_WEB_TEST_DEPS at that directory (the one containing node_modules/):
//
//   npm install --prefix ../.webtest --ignore-scripts jsdom@26
//   WMUX_WEB_TEST_DEPS=../.webtest node --test 'test/web-node/diff/*.test.mjs'
//
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

export const indexHtml = readFileSync(path.join(web, "diff/index.html"), "utf8");
const dom = new JSDOM(indexHtml, {
  url: "https://diff.wmux.example/diff/index.html",
  pretendToBeVisual: true,
});
export const { window } = dom;
export const doc = window.document;
export const pristineBody = doc.body.innerHTML;

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
          reply = { v: 1, id: msg.id, ok: false, error: { code: err.code || "internal_error", message: err.message || String(err) } };
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
  "DOMParser",
  "DocumentFragment",
  "getComputedStyle",
]) {
  const value = name === "window" ? window : window[name];
  Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });
}
globalThis.chrome = window.chrome;

export const importWeb = (rel) => import(pathToFileURL(path.join(web, rel)).href);

const { default: hljs } = await importWeb("_vendor/highlightjs-cdn-assets@11.12.0/highlight.min.js");
const { default: createDOMPurify } = await importWeb("_vendor/dompurify@3.4.17/purify.es.js");
export { hljs };
export const purify = createDOMPurify(window);
export const libs = { hljs, purify };

export const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
export async function settle(n = 8) {
  for (let i = 0; i < n; i += 1) await tick();
}

export function key(target, init) {
  const event = new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init });
  target.dispatchEvent(event);
  return event;
}

export function click(el, init) {
  el.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0, ...init }));
}

export function typeInto(el, value) {
  el.focus();
  el.value = value;
  el.dispatchEvent(new window.Event("input", { bubbles: true }));
}

/** Join lines into patch text with a trailing newline. */
export function patch(...lines) {
  return lines.flat().join("\n") + "\n";
}
