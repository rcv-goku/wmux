# `test/web`: real-browser harness for web panels

Runs every web panel (ARCHITECTURE ADR-6) in a headless Chromium-family browser
under its **real** Content Security Policy and Trusted Types policy, with a mock
of the WebView2 host side. It catches what the jsdom tests in `test/web-node/`
cannot see: jsdom enforces neither CSP nor Trusted Types, loads no real CSS
cascade and does no layout.

```
pwsh test/web/run.ps1                          # every suite
pwsh test/web/run.ps1 -Suite bridge,about      # some suites
pwsh test/web/run.ps1 -Browser "C:\path\msedge.exe" -TimeoutSec 60
```

Needs PowerShell 7 and a Chromium-family browser; no Node, no npm. On Windows
it uses Microsoft Edge (`Program Files (x86)`, then `Program Files`); on Linux
the first of `microsoft-edge`, `chromium`, `google-chrome` and
`chrome-headless-shell` on `PATH`. `-Browser` or `WMUX_WEB_BROWSER` overrides
the search. `WMUX_WEB_BROWSER_ARGS` adds browser flags (split on whitespace),
for example `--no-sandbox` in a Linux container without user namespaces.

## Files

| File | Purpose |
|---|---|
| `run.ps1` | runner: loopback static server, browser per suite, summary, `test-results/web.json` |
| `mock-host.js` | mock WebView2 host: `window.chrome.webview` plus scripted native replies |
| `lib/assert.js` | tiny test framework; writes `<pre id="wmux-test-results">` |
| `lib/harness.js` | `loadApp()` / `loadFrame()` / `defineSmokeSuite()` and DOM helpers |
| `lib/frame.html`, `lib/frame.js` | blank page for a fresh bridge instance per test |
| `suites/<name>.test.html` + `.js` | one suite per page; `<name>` is what `-Suite` takes |

Suites: `bridge` (wmux-bridge.js protocol), `about`, one smoke suite per merged
app (`markdown`, `diff`, `notifications`, `feed`, `settings`, `task-manager`,
`todo`) and `harness` (self-tests of the framework and the mock).

## What `run.ps1` does

1. Finds the browser and the suites (`suites/*.test.html`, or `-Suite` names;
   unknown names are an error).
2. Serves the repository root over `System.Net.HttpListener` on
   `http://127.0.0.1:<free port>/` (module scripts do not load from `file://`).
   If Windows HTTP.sys refuses that prefix to a non-elevated user, it uses
   `http://localhost:<port>/`, which HTTP.sys also binds to loopback only. The
   server answers only loopback clients with our own `Host`, serves `GET`/`HEAD`
   of files under the repo (no directory listings, no dot files such as `.git`,
   no `..`), sends correct MIME types (`text/javascript` for modules), and
   `Cache-Control: no-store` plus `X-Content-Type-Options: nosniff`.
3. Runs each suite page in a new temporary profile:
   `--headless=new --disable-gpu --no-first-run --no-default-browser-check
   --user-data-dir=<temp> --virtual-time-budget=<ms> --dump-dom <url>` (plus a
   few quieting flags and `--disable-features=msImplicitSignin`, see the
   Windows notes). With a virtual time budget the browser fast-forwards timers
   while the page is idle, so a suite's page work, delays and timeouts
   included, takes about a second of real time. Browser start and exit add a
   few seconds: with Edge on Windows a suite takes about 3-6 s and a full run
   about a minute.
4. Reads the results block from the dumped DOM and prints one line per suite
   and every failure.
5. Writes `test-results/web.json` (`-OutFile` overrides), then always stops the
   server and deletes the temporary profiles.

A suite fails when a test fails, when it records an uncaught error, unhandled
rejection or CSP/Trusted Types violation, when the browser runs longer than
`-TimeoutSec` (its process tree is killed), or when the dumped DOM has no
complete results block (crash, load failure, or the suite needed more than
`-VirtualTimeBudgetMs`, default 60000). Exit codes: 0 all passed, 1 failures,
2 setup errors (no browser, unknown suite, server failure).

## Writing a suite

Add `suites/<app>.test.html` (copy an existing one; keep its strict CSP) and
`suites/<app>.test.js`:

```js
import { createMockHost, reply } from "../mock-host.js";
import { test, run, assertEqual, waitFor } from "../lib/assert.js";
import { loadApp, defineSmokeSuite } from "../lib/harness.js";

test("myapp: renders the list", async () => {
  const host = createMockHost({ init: { kind: "myapp", params: { id: "x" } } });
  host.respond("myapp.list", { items: [{ id: 1, title: "One" }] });
  host.respond("panel.set_title", null);
  const page = await loadApp("myapp", host);       // src/web/myapp/index.html
  await waitFor(() => page.$("#list .item"), { message: "first item" });
  assertEqual(page.$("#list .item").textContent, "One");
  page.host.emit("cmux.event", { category: "myapp", name: "changed" });
  page.remove();
});

defineSmokeSuite({                                 // the standard smoke checks
  app: "myapp",
  responses: { "myapp.list": { items: [] }, "panel.set_title": null },
  mainSelector: "#list",
  errorSelectors: ["#error"],
});

run({ suite: "myapp" });
```

Test names follow `"<feature-or-layer>: <behavior>"`. `defineSmokeSuite`
registers: the app initializes with a visible, non-empty main view; no error
element is shown; it calls only scripted methods (list optional ones in
`optionalMethods`) with well-formed envelopes; the page's CSP blocks an
injected inline script (and `innerHTML` under Trusted Types) and the harness
sees the violation; a `theme` event reaches the CSS variables and the computed
`color-scheme`.

### `lib/assert.js`

`test(name, fn, {timeoutMs?})`, `test.skip`, `assertEqual` (`Object.is`),
`assertDeepEqual` (structural, works across realms), `assertMatch` (RegExp or
substring), `assertTrue`, `assertThrows(fn, expected?)` (sync, or async when
`fn` returns a promise; `expected` is an Error class, a RegExp, an object of
expected properties or a predicate), `assertRejects`, `waitFor(predicate,
{timeoutMs, intervalMs, message})`, `sleep`, `captureErrors(fn)` (returns the
error records instead of failing: use it for code that is meant to violate the
CSP) and `run({suite})`, which every suite calls once at the end. If `run()`
is not called within 20 s of `load` (a module failed to load), the page
publishes a failed result. Uncaught errors, unhandled rejections and
`securitypolicyviolation` events of the suite page and of every page loaded
through `lib/harness.js` fail the running test.

### `mock-host.js`

```js
const host = createMockHost({
  init: { kind, params, state, theme, keymap, settings },  // panel.init payload
  readyMode: "event",      // "event": reply to panel.ready, then push panel.init
                           // "result": init as the panel.ready result; "none": never answer
  responses: { "method": value },
  unhandled: "method_not_found",   // or "never", or a function
  latencyMs: 0,
});
host.respond("m", value);                       // ok reply with `value` as result
host.respond("m", (params, call) => value);     // computed (may return a promise or throw)
host.respond("m", reply.error("forbidden", "message", { data, reason, action, details }));
host.respond("m", reply.delay(500, value));     // answer later
host.respond("m", reply.never());               // never answer (bridge timeouts)
host.respond("m", reply.raw("garbage"));        // post any message instead
host.respondOnce("m", reply.error("busy", "x")); // one-shot, before the respond() script
host.emit("cmux.event", payload);               // inject a host event
host.setTheme({ background: "#202020" });       // theme sync ("theme" event + later panel.init)
host.sendInit({ params: { ... } });             // push panel.init again
host.calls / host.callsTo("m") / host.lastCall("m") / await host.waitForCall("m")
host.close();                                   // torn-down host: postMessage throws
```

Messages go both ways through JSON like `PostWebMessageAsJson` /
`get_WebMessageAsJson`, host messages are parsed in the page's realm and
delivered asynchronously as `MessageEvent`s, and every page message is recorded
with its reply.

## How the mock host gets into a page without weakening its CSP

WebView2 injects `window.chrome.webview` before any page script runs; the app
pages load only `'self'` scripts and some enforce Trusted Types, so nothing may
be added to them. The harness does not modify or proxy the page:

1. The suite page creates a same-origin `<iframe src=".../src/web/<app>/index.html">`.
2. An inserted iframe starts on an initial `about:blank` document. For the
   first navigation to a same-origin URL, browsers reuse that document's
   `Window` object (HTML "window reuse"; Chromium and therefore Edge do this).
3. Synchronously after inserting the frame, before the navigation commits, the
   harness defines `chrome.webview` on that `Window` and adds the `error`,
   `unhandledrejection` and `securitypolicyviolation` listeners.
4. The app's module scripts then run under the app's own meta CSP and Trusted
   Types policy and find the mock exactly where WebView2 puts it.

`loadPage()` checks that the loaded frame still has the same `Window` (and the
expected URL) and fails loudly otherwise, so a browser that stops reusing the
`Window` cannot produce false passes. The suite pages themselves use a strict
CSP with Trusted Types too.

## Relation to `test/web-node`

`test/web-node/**` (Node + jsdom, `node --test`) unit-tests the pure modules and
the DOM logic of each app quickly and in detail, with two near-identical
in-file mock bridges. `test/web` is the slower, coarser layer that runs the
same pages in a real engine: CSP and Trusted Types enforcement, module loading
over HTTP, real CSS and layout, `MessageEvent` delivery and the unmodified
`wmux-bridge.js`. Put logic tests in `test/web-node`. Put a suite here for
what only a browser can show: policy violations, visibility and layout,
vendored bundles that need a real engine, and the bridge contract end to end.
`mock-host.js` is plain ES and does not depend on the DOM, so the jsdom tests
could adopt it in place of their two in-file mocks. That is left as a
follow-up.

## Windows notes

Edge runs headless (`--headless=new`, started with `CreateNoWindow`). On
Windows 11 with Edge 155, a sampler that checked the foreground window and all
visible top-level windows every 100 ms during full runs found no window from
the browser's processes. On a work-joined host, Edge signs every new
profile in to the Windows account ("implicit sign-in"): each suite would then
get tokens through the account broker and call Microsoft Graph, Office and
Intune endpoints with the user's identity. `run.ps1` passes
`--disable-features=msImplicitSignin` to turn that off (other browsers ignore
the name). A `--disable-features=...` given in `WMUX_WEB_BROWSER_ARGS` is merged
with it rather than replacing it. The non-elevated `HttpListener` on
`http://127.0.0.1:<port>/` needed no URL ACL on Windows 11.

## Linux notes

`chrome-headless-shell` from Chrome for Testing works. It needs the usual
Chromium shared libraries and at least one font (without fonts, text lays out
with zero width and visibility checks fail). On hosts where unprivileged user
namespaces are disabled (Ubuntu 24.04 AppArmor), set
`WMUX_WEB_BROWSER_ARGS=--no-sandbox`.
