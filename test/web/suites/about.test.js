// About panel (src/web/about) under its real CSP and Trusted Types policy,
// with the mock host answering panel.about.info (contract: about.js header).
import { createMockHost, reply } from "../mock-host.js";
import { test, run, assertEqual, assertMatch, assertTrue, assertDeepEqual, waitFor } from "../lib/assert.js";
import { loadApp, isVisible, defineSmokeSuite } from "../lib/harness.js";

const INFO = {
  product: "wmux",
  version: "1.2.3",
  channel: "beta",
  commit: "aa1f532c0ffee",
  build: { build_mode: "ReleaseFast", zig_version: "0.15.2", os: "Windows 11 26100", arch: "x86_64", webview2_runtime: "141.0.3537.71" },
  license: { spdx: "MIT", name: "MIT License", text: "Permission is hereby granted, free of charge…" },
  copyright: "Copyright (c) 2026 wmux contributors",
  homepage: "https://wmux.example.org/",
};
const NOTICES = { text: "zlib\nCopyright (C) Jean-loup Gailly and Mark Adler\n", format: "text" };

function aboutHost(responses) {
  return createMockHost({
    init: { kind: "about" },
    responses: Object.assign(
      {
        "panel.about.info": INFO,
        "panel.about.notices": NOTICES,
        "panel.set_title": null,
        "panel.clipboard_write": null,
        "panel.open_external": null,
      },
      responses || {},
    ),
  });
}

function buildRows(page) {
  const out = [];
  const items = page.$$("#about-build > *");
  for (let i = 0; i + 1 < items.length; i += 2) out.push([items[i].textContent, items[i + 1].textContent]);
  return out;
}

let page = null;

test("about: renders the app info from panel.about.info", async () => {
  page = await loadApp("about", aboutHost());
  await waitFor(() => page.$("#about-version").textContent === "Version 1.2.3", { message: "version line" });
  assertEqual(page.$("#about-product").textContent, "wmux", "product");
  const channel = page.$("#about-channel");
  assertTrue(isVisible(channel), "channel badge visible");
  assertEqual(channel.textContent, "beta", "channel");
  const rows = buildRows(page);
  assertDeepEqual(rows.slice(0, 5), [
    ["Version", "1.2.3"],
    ["Channel", "beta"],
    ["Commit", "aa1f532c0ffee"],
    ["Build mode", "ReleaseFast"],
    ["Zig", "0.15.2"],
  ]);
  assertTrue(rows.some((r) => r[0] === "WebView2 runtime" && r[1] === "141.0.3537.71"), "webview2 row from native wins over the UA");
  assertEqual(page.$("#about-license-summary").textContent, "wmux is free software, released under the MIT License.");
  assertEqual(page.$("#about-copyright").textContent, INFO.copyright);
  assertTrue(isVisible(page.$("#about-homepage")), "homepage link visible");
  assertEqual(page.$("#about-status").getAttribute("data-kind"), "info", "status kind");
  assertEqual(page.$("#about-status").textContent, "", "no status text");
  assertTrue(isVisible(page.$("main.about")), "main view has layout");
});

test("about: ready handshake and title", async () => {
  const host = page.host;
  const ready = host.callsTo("panel.ready");
  assertEqual(ready.length, 1, "panel.ready sent once");
  assertDeepEqual(ready[0].params, {});
  const title = await host.waitForCall("panel.set_title");
  assertDeepEqual(title.params, { title: "About wmux" });
  assertEqual(page.document.title, "About wmux");
  assertTrue(host.lastCall("panel.about.info").seq > ready[0].seq, "info requested after panel.ready");
});

test("about: copy version info posts panel.clipboard_write", async () => {
  page.$("#about-copy").click();
  const call = await page.host.waitForCall("panel.clipboard_write");
  assertMatch(call.params.text, /^wmux 1\.2\.3\n/);
  assertMatch(call.params.text, "Channel: beta");
  await waitFor(() => page.$("#about-status").textContent !== "", { message: "copied status" });
  assertEqual(page.$("#about-status").getAttribute("data-kind"), "info");
});

test("about: third-party notices load on demand", async () => {
  assertEqual(page.host.callsTo("panel.about.notices").length, 0, "not loaded before the click");
  page.$("#about-notices-toggle").click();
  await waitFor(() => page.$("#about-notices-text").textContent === NOTICES.text, { message: "notices text" });
  assertTrue(isVisible(page.$("#about-notices-text")), "notices region visible");
  assertEqual(page.$("#about-notices-toggle").getAttribute("aria-expanded"), "true");
});

test("about: homepage opens through panel.open_external", async () => {
  page.$("#about-homepage").click();
  const call = await page.host.waitForCall("panel.open_external");
  assertDeepEqual(call.params, { url: INFO.homepage });
  assertEqual(page.window.location.pathname, "/src/web/about/index.html", "the page did not navigate");
  page.remove();
});

test("about: falls back to system.capabilities when panel.about.info is missing", async () => {
  const host = aboutHost({
    "panel.about.info": reply.error("method_not_found", "Unknown method"),
    "system.capabilities": { capabilities: { wmux: { version: "0.9.0", channel: "nightly", platform: "windows" } } },
  });
  const p = await loadApp("about", host, { label: "about-fallback" });
  await waitFor(() => p.$("#about-version").textContent === "Version 0.9.0", { message: "fallback version" });
  assertEqual(p.$("#about-channel").textContent, "nightly");
  assertTrue(buildRows(p).some((r) => r[0] === "Platform" && r[1] === "windows"), "platform row");
  assertEqual(host.callsTo("system.capabilities").length, 1);
  p.remove();
});

test("about: a failed info call shows an error status and placeholders", async () => {
  const host = aboutHost({ "panel.about.info": reply.error("internal_error", "boom") });
  const p = await loadApp("about", host, { label: "about-error" });
  await waitFor(() => p.$("#about-status").getAttribute("data-kind") === "error", { message: "error status" });
  assertMatch(p.$("#about-status").textContent, "boom");
  assertEqual(p.$("#about-version").textContent, "Version unknown");
  p.remove();
});

test("about: slow host replies still render", async () => {
  const host = aboutHost({ "panel.about.info": reply.delay(1500, INFO) });
  host.setLatency(50);
  const p = await loadApp("about", host, { label: "about-slow" });
  await waitFor(() => p.$("#about-version").textContent === "Version 1.2.3", { timeoutMs: 6000, message: "delayed version" });
  p.remove();
});

defineSmokeSuite({
  app: "about",
  responses: { "panel.about.info": INFO, "panel.set_title": null },
  mainSelector: "#about-build",
  contentText: "ReleaseFast",
  errorSelectors: ['#about-status[data-kind="error"]'],
});

run({ suite: "about" });
