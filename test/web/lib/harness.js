/**
 * Page helpers for test/web suites: load a web app (or a blank page) in a
 * same-origin iframe with the mock host installed before any of its scripts
 * run, and the shared smoke checks every merged app gets.
 *
 * How the mock gets in without touching the page or its CSP: an inserted
 * iframe starts on an initial about:blank document whose Window Chromium
 * reuses for the first same-origin navigation (HTML "window reuse"). The
 * harness installs window.chrome.webview and the error/CSP listeners on that
 * Window synchronously after insertion, so the app's own module scripts, under
 * the app's own meta CSP and Trusted Types policy, find them exactly where
 * WebView2 puts them. loadPage() verifies the Window was reused and fails loudly
 * otherwise.
 */
import { createMockHost } from "../mock-host.js";
import { watchWindow, waitFor, assertTrue, assertEqual, assertMatch, captureErrors, test } from "./assert.js";

/** Repo-root-relative URL of a web app's entry page. */
export function appUrl(app) {
  return new URL("../../../src/web/" + app + "/index.html", import.meta.url).href;
}

/** URL of the blank frame page used for fresh bridge instances. */
export const FRAME_URL = new URL("./frame.html", import.meta.url).href;

/**
 * Load `url` in a new iframe with `host` installed as its chrome.webview.
 * @param {string} url same-origin URL
 * @param {ReturnType<typeof createMockHost> | null} host null = no WebView2 host
 * @param {{label?: string, width?: number, height?: number, timeoutMs?: number}} [options]
 */
export async function loadPage(url, host, options) {
  const o = options || {};
  const label = o.label || url.replace(/^.*\/src\/web\//, "");
  const frame = document.createElement("iframe");
  frame.width = String(o.width || 1024);
  frame.height = String(o.height || 768);
  frame.title = label;
  const loaded = new Promise((resolve, reject) => {
    frame.addEventListener("load", resolve, { once: true });
    frame.addEventListener("error", () => reject(new Error("frame failed to load: " + url)), { once: true });
  });
  frame.src = url;
  document.body.appendChild(frame);
  const initial = frame.contentWindow;
  if (host) host.install(initial);
  const unwatch = watchWindow(initial, label);
  const timeoutMs = o.timeoutMs || 10000;
  let timer = 0;
  try {
    await Promise.race([
      loaded,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error("frame did not load within " + timeoutMs + " ms: " + url)), timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
  const win = frame.contentWindow;
  if (win !== initial) {
    throw new Error("the browser did not reuse the iframe's initial Window, so the mock host was not installed in " + url);
  }
  if (win.location.href !== new URL(url, location.href).href) {
    throw new Error("frame ended at " + win.location.href + " instead of " + url);
  }
  return {
    frame,
    host,
    window: win,
    document: win.document,
    $: (selector) => win.document.querySelector(selector),
    $$: (selector) => Array.from(win.document.querySelectorAll(selector)),
    remove() {
      unwatch();
      if (host) host.close();
      frame.remove();
    },
  };
}

/** Load a web app's index.html (see loadPage). */
export function loadApp(app, host, options) {
  return loadPage(appUrl(app), host, Object.assign({ label: app }, options));
}

/**
 * Load the blank frame page; `page.import(url)` imports a module in the frame's
 * realm (a fresh wmux-bridge.js singleton per frame).
 */
export async function loadFrame(host, options) {
  const page = await loadPage(FRAME_URL, host, Object.assign({ label: "frame" }, options));
  page.import = (url) => page.window.__wmuxFrameImport(new URL(url, location.href).href);
  return page;
}

/** Element is rendered with a non-zero box (real layout, which jsdom lacks). */
export function isVisible(el) {
  if (!el || !el.isConnected) return false;
  if (el.closest("[hidden]")) return false;
  const style = el.ownerDocument.defaultView.getComputedStyle(el);
  if (style.display === "none" || style.visibility === "hidden") return false;
  const box = el.getBoundingClientRect();
  return box.width > 0 && box.height > 0;
}

/** The Content-Security-Policy meta content of a document ("" when absent). */
export function metaCsp(doc) {
  const meta = doc.querySelector('meta[http-equiv="Content-Security-Policy" i]');
  return meta ? meta.getAttribute("content") || "" : "";
}

/**
 * Register the standard smoke tests for a merged web app.
 *
 * @param {object} config
 * @param {string} config.app directory under src/web/
 * @param {object} [config.init] panel.init fields (kind defaults to config.kind || config.app)
 * @param {string} [config.kind]
 * @param {Record<string, any>} [config.responses] mock replies (see mock-host.js respond())
 * @param {string} config.mainSelector element that must render visible, non-empty content
 * @param {string} [config.contentSelector] element proving the scripted data rendered (default mainSelector)
 * @param {string} [config.contentText] text that contentSelector must contain
 * @param {string[]} [config.errorSelectors] elements that must not be visible with text
 * @param {string[]} [config.optionalMethods] methods the app may call without a script
 *   (they get method_not_found, which the app treats as "feature off")
 * @param {(page: object) => any} [config.extra] more checks after the content rendered
 */
export function defineSmokeSuite(config) {
  const app = config.app;
  const name = (behavior) => "smoke: " + app + ": " + behavior;
  let page = null;
  const loadedPage = () => {
    if (!page) throw new Error(app + " did not load (see the first test)");
    return page;
  };

  test(name("initializes under its real CSP with the mock host"), async () => {
    const host = createMockHost({
      init: Object.assign({ kind: config.kind || app }, config.init || {}),
      responses: config.responses || {},
    });
    page = await loadApp(app, host);
    await host.waitForCall("panel.ready", { timeoutMs: 5000 });
    const main = await waitFor(
      () => {
        const el = page.$(config.mainSelector);
        return el && isVisible(el) && el.textContent.trim() !== "" ? el : null;
      },
      { timeoutMs: 8000, message: config.mainSelector + " visible and non-empty" },
    );
    assertTrue(main.getBoundingClientRect().height > 0, "main view has layout height");
    const content = await waitFor(() => page.$(config.contentSelector || config.mainSelector), {
      timeoutMs: 5000,
      message: (config.contentSelector || config.mainSelector) + " rendered",
    });
    if (config.contentText) assertMatch(content.textContent, config.contentText, "rendered content");
  });

  test(name("shows no error state"), async () => {
    const p = loadedPage();
    for (const selector of config.errorSelectors || []) {
      for (const el of p.$$(selector)) {
        const shown = isVisible(el) && el.textContent.trim() !== "";
        assertTrue(!shown, selector + " is shown: " + JSON.stringify(el.textContent.trim().slice(0, 200)));
      }
    }
  });

  test(name("calls only scripted bridge methods with well-formed envelopes"), async () => {
    const p = loadedPage();
    const scripted = new Set(Object.keys(config.responses || {}).concat(["panel.ready"], config.optionalMethods || []));
    const ids = new Set();
    for (const call of p.host.calls) {
      assertEqual(call.message.v, 1, "envelope v of " + call.method);
      assertEqual(typeof call.method, "string", "method name");
      if (!call.fireAndForget) {
        assertMatch(String(call.id), /^c[0-9]+$/, "request id");
        assertTrue(!ids.has(call.id), "request id " + call.id + " is unique");
        ids.add(call.id);
      }
      assertTrue(scripted.has(call.method), "unscripted bridge method " + call.method + " (script it or list it in optionalMethods)");
    }
  });

  test(name("enforces the page's CSP and the harness sees violations"), async () => {
    const p = loadedPage();
    const csp = metaCsp(p.document);
    assertMatch(csp, "script-src 'self'", "meta CSP");
    assertTrue(!/unsafe-(inline|eval)/.test(csp.match(/script-src[^;]*/)[0]), "script-src has no unsafe-* source");
    const trusted = /require-trusted-types-for\s+'script'/.test(csp);
    const errors = await captureErrors(() => {
      const s = p.document.createElement("script");
      try {
        s.textContent = "window.__wmuxInlineRan = true;";
        p.document.head.appendChild(s);
      } catch (err) {
        if (!trusted) throw err;
      }
    });
    assertTrue(p.window.__wmuxInlineRan !== true, "an inline script ran despite the CSP");
    const directive = trusted ? "require-trusted-types-for" : "script-src-elem";
    assertTrue(
      errors.some((e) => e.kind === "securitypolicyviolation" && e.effectiveDirective === directive),
      "expected a " + directive + " violation, got " + JSON.stringify(errors.map((e) => e.effectiveDirective || e.kind)),
    );
    if (trusted) {
      const ttErrors = await captureErrors(() => {
        let threw = false;
        try {
          p.document.createElement("div").innerHTML = "<b>x</b>";
        } catch (err) {
          threw = err instanceof p.window.TypeError || err.name === "TypeError";
        }
        assertTrue(threw, "innerHTML assignment must throw under Trusted Types");
      });
      assertTrue(ttErrors.some((e) => e.effectiveDirective === "require-trusted-types-for"), "Trusted Types violation reported");
    }
  });

  test(name("applies theme sync from the host"), async () => {
    const p = loadedPage();
    const root = p.document.documentElement;
    p.host.setTheme(Object.assign({}, p.host.init.theme, { background: "#102030", foreground: "#e0e0e0", scheme: "dark" }));
    await waitFor(() => root.style.getPropertyValue("--wmux-bg").trim().toLowerCase() === "#102030", {
      timeoutMs: 3000,
      message: "--wmux-bg follows the theme event",
    });
    assertEqual(root.getAttribute("data-wmux-theme"), "host", "data-wmux-theme");
    assertEqual(root.getAttribute("data-wmux-scheme"), "dark", "data-wmux-scheme");
    assertEqual(p.window.getComputedStyle(root).colorScheme, "dark", "computed color-scheme from base.css");
  });

  if (typeof config.extra === "function") {
    test(name("app-specific checks"), async () => {
      await config.extra(loadedPage());
    });
  }
}
