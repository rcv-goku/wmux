// Shared jsdom harness for the todo and task-manager panel tests: a page
// loaded from src/web/<app>/index.html and a mock WebView2 host
// (window.chrome.webview) that speaks the bridge envelope. Same mock as
// test/web-node/markdown.test.mjs, factored out for reuse.
//
// jsdom is not vendored: install it outside the repo and point
// WMUX_WEB_TEST_DEPS at that directory (the one containing node_modules/):
//
//   npm install --prefix /tmp/wmux-web-test-deps --ignore-scripts jsdom@26
//   WMUX_WEB_TEST_DEPS=/tmp/wmux-web-test-deps node --test 'test/web-node/**/*.test.mjs'
//
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
export const repo = path.resolve(here, "../../..");
export const web = path.join(repo, "src/web");
const depsDir = process.env.WMUX_WEB_TEST_DEPS;
const requireDeps = createRequire(
  depsDir ? path.join(path.resolve(depsDir), "package.json") : import.meta.url,
);
const { JSDOM } = requireDeps("jsdom");

/** Mock of window.chrome.webview: records posts, answers calls from `handlers`. */
export function createHost() {
  return {
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
          reply = {
            v: 1,
            id: msg.id,
            ok: false,
            error: { code: "method_not_found", message: "Unknown method" },
          };
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
}

export function hostError(code, message) {
  const err = new Error(message || code);
  err.code = code;
  return err;
}

/**
 * Load src/web/<app>/index.html into jsdom, install the mock host and the
 * globals the page modules expect, and import the shared bridge (it reads
 * chrome.webview at import time, so this must run before any panel module).
 */
export async function setupPage(app) {
  const html = readFileSync(path.join(web, app, "index.html"), "utf8");
  const dom = new JSDOM(html, {
    url: `https://${app}.wmux.example/${app}/index.html`,
    pretendToBeVisual: true,
  });
  const { window } = dom;
  const host = createHost();
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
  const importWeb = (rel) => import(pathToFileURL(path.join(web, rel)).href);
  const { wmux } = await importWeb("_shared/wmux-bridge.js");
  await importWeb("_shared/theme.js");
  return {
    dom,
    window,
    doc: window.document,
    host,
    wmux,
    importWeb,
    pristineBody: window.document.body.innerHTML,
    html,
  };
}

export const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

export async function settle(n = 6) {
  for (let i = 0; i < n; i += 1) await tick();
}

export function key(window, target, init) {
  const event = new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init });
  target.dispatchEvent(event);
  return event;
}

export function click(window, el, init) {
  el.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0, ...init }));
}

export function mouse(window, el, type, init) {
  const event = new window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0, ...init });
  el.dispatchEvent(event);
  return event;
}

/** CSP of a page: the content of its first http-equiv meta. */
export function cspOf(html) {
  const m = /<meta http-equiv="Content-Security-Policy" content="([^"]*)">/.exec(html);
  return m ? m[1] : "";
}
