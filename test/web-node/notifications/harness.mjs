// Shared jsdom harness for the notifications and feed panel tests: loads a
// panel's index.html into jsdom, installs the mock WebView2 host
// (window.chrome.webview) that speaks the bridge envelope, and exposes the
// page globals the panel modules expect. Same mock as markdown.test.mjs.
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
}

export function hostError(code, message) {
  const err = new Error(message || code);
  err.code = code;
  return err;
}

/**
 * Loads `src/web/<app>/index.html` into jsdom with the mock host and defines
 * the globals. Call once per test file, before importing any panel module.
 */
export function loadPage(app) {
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
  return { dom, window, doc: window.document, host, pristineBody: window.document.body.innerHTML };
}

export const importWeb = (rel) => import(pathToFileURL(path.join(web, rel)).href);

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
export async function settle(n = 6) {
  for (let i = 0; i < n; i += 1) await tick();
}
export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function key(window, target, init) {
  const event = new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init });
  target.dispatchEvent(event);
  return event;
}

export function click(window, el, init) {
  el.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0, ...init }));
}

export function dblclick(window, el, init) {
  el.dispatchEvent(new window.MouseEvent("dblclick", { bubbles: true, cancelable: true, button: 0, detail: 2, ...init }));
}

export function contextmenu(window, el, init) {
  el.dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, button: 2, ...init }));
}

/** Text of every element matching `selector` under `root`. */
export function texts(root, selector) {
  return Array.from(root.querySelectorAll(selector), (n) => n.textContent);
}
