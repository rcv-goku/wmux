// Diff panel application tests: the real src/web/diff modules in jsdom,
// driven through the mock bridge host (see harness.mjs).
import { test, describe, afterEach, after } from "node:test";
import assert from "node:assert/strict";
import { click, doc, host, hostError, importWeb, key, libs, patch, pristineBody, settle, typeInto, window } from "./harness.mjs";

await importWeb("_shared/theme.js");
const { createApp, gitApplyCommand } = await importWeb("diff/app.js");

const NOW = new Date("2026-10-16T12:00:00.000Z");

const PATCH = patch(
  "diff --git a/src/app.js b/src/app.js",
  "index 1111111..2222222 100644",
  "--- a/src/app.js",
  "+++ b/src/app.js",
  "@@ -1,5 +1,5 @@ function main() {",
  " import { render } from './render.js';",
  "-const answer = 41;",
  "+const answer = 42;",
  " render(answer);",
  " // render twice",
  " done();",
  "@@ -20,3 +20,4 @@",
  " a();",
  "+b();",
  " c();",
  " d();",
  "diff --git a/docs/old.md b/docs/new.md",
  "similarity index 90%",
  "rename from docs/old.md",
  "rename to docs/new.md",
  "--- a/docs/old.md",
  "+++ b/docs/new.md",
  "@@ -1,2 +1,2 @@",
  "-# Title",
  "+# New title render",
  " body",
  "diff --git a/img.png b/img.png",
  "index 1..2 100644",
  "Binary files a/img.png and b/img.png differ",
  "diff --git a/run.sh b/run.sh",
  "old mode 100644",
  "new mode 100755",
  "diff --git a/package-lock.json b/package-lock.json",
  "--- a/package-lock.json",
  "+++ b/package-lock.json",
  "@@ -1 +1 @@",
  '-  "version": "1.0.0"',
  '+  "version": "1.0.1"',
);

let app = null;

function freshDom() {
  doc.body.innerHTML = pristineBody;
  const root = doc.documentElement;
  root.className = "";
  root.removeAttribute("style");
}

/**
 * Start a fresh app.
 * @param {{patch?: string|null, init?: object, params?: object, handlers?: object,
 *   comments?: object[], viewed?: object[], fetch?: Function}} [opts]
 */
async function startApp(opts = {}) {
  if (app) app.destroy();
  freshDom();
  host.reset();
  const store = {
    patch: opts.patch === undefined ? PATCH : opts.patch,
    comments: (opts.comments || []).map((c) => ({ ...c })),
    viewed: new Map((opts.viewed || []).map((v) => [v.path, v.fingerprint])),
    prefs: null,
    clipboard: null,
  };
  const handlers = {
    "panel.ready": () => ({}),
    "panel.set_title": () => ({}),
    "panel.state_changed": () => ({}),
    "panel.clipboard_write": ({ text }) => {
      store.clipboard = text;
      return {};
    },
    "viewerPrefs.set": ({ prefs }) => {
      store.prefs = prefs;
      return {};
    },
    "viewedFiles.list": () => ({ files: Array.from(store.viewed, ([path, fingerprint]) => ({ path, fingerprint })) }),
    "viewedFiles.set": ({ path, fingerprint, viewed }) => {
      if (viewed) store.viewed.set(path, fingerprint);
      else store.viewed.delete(path);
      return {};
    },
    "viewedFiles.clear": () => {
      store.viewed.clear();
      return {};
    },
    "comments.list": () => ({ comments: store.comments }),
    "comments.save": ({ comment }) => {
      store.comments = store.comments.filter((c) => c.id !== comment.id).concat([comment]);
      return { comment };
    },
    "comments.delete": ({ id }) => {
      store.comments = store.comments.filter((c) => c.id !== id);
      return {};
    },
    "panel.diff.load": () => ({ patch: store.patch, title: "Unstaged changes" }),
    "panel.diff.send_comments": ({ ids }) => ({ consumed: ids.map((id) => ({ id, consumedAt: NOW.toISOString() })) }),
    ...(opts.handlers || {}),
  };
  for (const [method, fn] of Object.entries(handlers)) host.handlers.set(method, fn);
  host.emit("panel.init", {
    kind: "diff",
    surface_id: "5B1D2C9E-0000-4000-8000-000000000002",
    params: { title: "Working tree", ...(opts.params || {}) },
    state: null,
    theme: { background: "#1e1e1e", foreground: "#d4d4d4" },
    settings: {},
    ...(opts.init || {}),
  });
  app = createApp({ document: doc, libs, now: () => NOW, fetch: opts.fetch });
  await app.start();
  await settle();
  return { app, store };
}

const $ = (sel, root = doc) => root.querySelector(sel);
const $$ = (sel, root = doc) => Array.from(root.querySelectorAll(sel));
const section = (path) => $$(".dv-file").find((s) => s.querySelector(".dv-path").title === path);
const lastCall = (method) => host.calls(method).at(-1);

/** Fake scroll metrics and positions: sections at 1000 px steps, hunks 100 px apart. */
function fakeLayout() {
  const vp = $("#dv-viewport");
  let top = 0;
  Object.defineProperty(vp, "clientHeight", { configurable: true, get: () => 500 });
  Object.defineProperty(vp, "scrollHeight", { configurable: true, get: () => 100000 });
  Object.defineProperty(vp, "scrollTop", { configurable: true, get: () => top, set: (v) => (top = Math.max(0, Number(v))) });
  const pos = (node) => {
    if (node === vp) return 0;
    const sec = node.closest && node.closest(".dv-file");
    if (!sec) return 0;
    const order = $$(".dv-file").indexOf(sec);
    let y = order * 1000;
    if (node.matches("tr.dv-hunk")) y += 100 * (Number(node.dataset.h) + 1);
    if (node.closest("tr.dv-line")) y += 50;
    return y - top;
  };
  window.Element.prototype.getBoundingClientRect = function () {
    return { top: pos(this), left: 0, right: 0, bottom: 0, width: 0, height: 0 };
  };
  return vp;
}

const KEYCODES = { "]": 221, "[": 219, "/": 191 };
/** Press a printable key on the viewport (keys.js matches by virtual key). */
function press(k, extra = {}, target) {
  const upper = k.toUpperCase();
  const keyCode = KEYCODES[k] || upper.charCodeAt(0);
  const code = KEYCODES[k] ? { "]": "BracketRight", "[": "BracketLeft", "/": "Slash" }[k] : "Key" + upper;
  return key(target || $("#dv-viewport"), { key: k, code, keyCode, ...extra });
}

const originalRect = window.Element.prototype.getBoundingClientRect;

after(() => window.close());
afterEach(() => {
  window.Element.prototype.getBoundingClientRect = originalRect;
  if (app) {
    app.destroy();
    app = null;
  }
});

describe("unit: diff app rendering", () => {
  test("unit: diff: renders title, stats, tree and per-file headers", async () => {
    await startApp();
    assert.equal($("#dv-title").textContent, "Working tree");
    assert.equal(lastCall("panel.set_title").params.title, "Working tree");
    assert.equal($("#dv-stats-add").textContent, "+4");
    assert.equal($("#dv-stats-del").textContent, "−3");
    assert.equal($("#dv-progress").textContent, "0 of 5 files viewed");
    assert.equal($$(".dv-file").length, 5);
    assert.deepEqual($$(".dv-tree-name").map((n) => n.textContent), ["new.md", "app.js", "img.png", "package-lock.json", "run.sh"]);
    assert.equal($(".dv-path", section("docs/new.md")).textContent, "docs/old.md → docs/new.md");
    assert.match($(".dv-file-notes", section("docs/new.md")).textContent, /90% similar/);
    assert.equal($(".dv-note-binary", section("img.png")).textContent, "Binary file");
    assert.equal($(".dv-note-mode", section("run.sh")).textContent, "Mode 100644 → 100755");
    assert.equal($("#dv-message").hidden, true);
  });

  test("unit: diff: title falls back to the load result, then Untitled", async () => {
    await startApp({ params: { title: "" } });
    assert.equal($("#dv-title").textContent, "Unstaged changes");
    await startApp({ params: { title: "  ", patch: PATCH } });
    assert.equal($("#dv-title").textContent, "Untitled");
  });

  test("unit: diff: unified rows carry numbers, syntax spans and word highlights", async () => {
    await startApp();
    const sec = section("src/app.js");
    assert.ok($("table.dv-unified", sec));
    const del = $('td.dv-code.dv-del[data-side="deletions"]', sec);
    assert.equal($(".dv-text", del).textContent, "const answer = 41;");
    assert.equal($(".dv-word", del).textContent, "41");
    const add = $('td.dv-code.dv-add[data-line="2"]', sec);
    assert.equal($(".dv-word", add).textContent, "42");
    assert.ok($(".dv-text span[class^='hljs-']", add), "syntax highlighted");
    assert.equal($$("tr.dv-hunk", sec).length, 2);
    assert.match($("tr.dv-hunk td", sec).textContent, /^@@ -1,5 \+1,5 @@ function main\(\) \{$/);
  });

  test("unit: diff: no-newline marker and status filter labels go through tr()", async () => {
    const { addStrings, setLocale } = await importWeb("_shared/strings.js");
    addStrings("x-test", { "diff.noNewline": "[no newline]", "diff.filter.status": "[status]" });
    setLocale("x-test");
    try {
      await startApp({ params: { patch: patch("--- a/f.txt", "+++ b/f.txt", "@@ -1 +1 @@", "-a", "+b", "\\ No newline at end of file") } });
      assert.equal($(".dv-nonl").title, "[no newline]");
      assert.equal($(".dv-filter-statuses").getAttribute("aria-label"), "[status]");
    } finally {
      setLocale("en");
    }
  });

  test("unit: diff: split toggle re-renders side by side and persists", async () => {
    const { store } = await startApp();
    assert.equal($("#dv-layout").textContent, "Switch to split diff");
    click($("#dv-layout"));
    await settle();
    const sec = section("src/app.js");
    assert.ok($("table.dv-split", sec));
    const row = $("tr.dv-change", sec);
    assert.equal($('td.dv-code[data-side="deletions"] .dv-text', row).textContent, "const answer = 41;");
    assert.equal($('td.dv-code[data-side="additions"] .dv-text', row).textContent, "const answer = 42;");
    assert.equal($("#dv-layout").textContent, "Switch to unified diff");
    assert.equal(store.prefs.layout, "split");
    assert.equal(doc.documentElement.dataset.dvLayout, "split");
    await startApp({ params: { prefs: store.prefs } });
    assert.ok($("table.dv-split", section("src/app.js")), "next viewer opens split");
  });

  test("unit: diff: options menu toggles line numbers, wrap, indicators and persists", async () => {
    const { store } = await startApp();
    click($("#dv-options"));
    assert.equal($("#dv-options-menu").hidden, false);
    const item = $('[data-menu="lineNumbers"]');
    assert.equal(item.textContent, "Hide line numbers");
    click(item);
    await settle();
    assert.ok(doc.documentElement.classList.contains("dv-no-line-numbers"));
    assert.equal(store.prefs.lineNumbers, false);
    assert.equal($("#dv-options-menu").hidden, true);
    click($("#dv-options"));
    assert.equal($('[data-menu="lineNumbers"]').textContent, "Show line numbers");
    click($('[data-indicator="classic"]'));
    assert.equal(doc.documentElement.dataset.dvIndicators, "classic");
    assert.equal($('[data-indicator="classic"]').getAttribute("aria-checked"), "true");
    click($('[data-menu="wordWrap"]'));
    assert.ok(doc.documentElement.classList.contains("dv-wrap"));
    await startApp({ params: { prefs: store.prefs } });
    assert.ok(doc.documentElement.classList.contains("dv-no-line-numbers"), "hidden line numbers persist");
  });

  test("unit: diff: word diffs, ignore whitespace and context lines re-render", async () => {
    const ws = patch("--- a/w.txt", "+++ b/w.txt", "@@ -1,9 +1,9 @@", " 1", " 2", " 3", " 4", "-a  b", "+a b", " 6", " 7", " 8", " 9");
    await startApp({ params: { patch: ws } });
    app.setPrefs({ wordDiffs: false });
    assert.equal($$(".dv-word").length, 0);
    app.setPrefs({ contextLines: 1 });
    const gaps = $$(".dv-gap-button");
    assert.deepEqual(gaps.map((g) => g.textContent), ["Show 3 unchanged lines", "Show 3 unchanged lines"]);
    click(gaps[0]);
    assert.equal($$(".dv-gap-button").length, 1);
    app.setPrefs({ ignoreWhitespace: true });
    assert.equal($$("td.dv-code.dv-del").length, 0);
    app.setPrefs({ expandUnchanged: true });
    assert.equal($$(".dv-gap-button").length, 0);
    assert.equal($$("tr.dv-line").length, 9);
  });

  test("unit: diff: generated and large files are deferred until Load diff", async () => {
    await startApp({ params: { generated: ["src/app.js"] } });
    const lock = section("package-lock.json");
    assert.equal($(".dv-deferred", lock).hidden, false);
    assert.equal($(".dv-deferred-label", lock).textContent, "Generated file");
    assert.equal($(".dv-load", lock).textContent, "Load diff");
    assert.equal($("table", lock), null);
    assert.equal($("table", section("src/app.js")), null, "attribute-marked file deferred");
    click($(".dv-load", lock));
    assert.ok($("table", lock));
    assert.equal($(".dv-deferred", lock).hidden, true);
    const big = ["--- a/big.txt", "+++ b/big.txt", "@@ -0,0 +1,2000 @@"];
    for (let i = 0; i < 2000; i += 1) big.push("+" + i);
    await startApp({ params: { patch: patch(big) } });
    assert.equal($(".dv-deferred-label").textContent, "Large diff");
  });

  test("unit: diff: patch text is never interpreted as markup", async () => {
    const evil = patch(
      'diff --git a/"><img src=x onerror=alert(1)>.js b/"><img src=x onerror=alert(1)>.js',
      '--- a/"><img src=x onerror=alert(1)>.js',
      '+++ b/"><img src=x onerror=alert(1)>.js',
      "@@ -1 +1 @@",
      "-<script>alert(1)</script>",
      '+<img src=x onerror="alert(2)"><b>bold</b>',
    );
    await startApp({ params: { patch: evil } });
    assert.equal($$("#dv-files script, #dv-files img, #dv-files b, #dv-tree img").length, 0);
    assert.equal($('td.dv-code.dv-add .dv-text').textContent, '<img src=x onerror="alert(2)"><b>bold</b>');
    assert.match($(".dv-path").textContent, /<img src=x/);
  });

  test("unit: diff: empty, failing and unparsable input show cmux messages", async () => {
    await startApp({ params: { patch: "" } });
    assert.equal($("#dv-message").textContent, "No file diffs found in patch input.");
    assert.equal($("#dv-progress").textContent, "");
    await startApp({ handlers: { "panel.diff.load": () => { throw hostError("internal_error", "boom"); } } });
    assert.equal($("#dv-message").textContent, "Could not render this diff. Check the patch input and try again.");
  });

  test("unit: diff: patch_url is fetched from data hosts only", async () => {
    const urls = [];
    const fetch = async (url) => {
      urls.push(url);
      return { ok: true, status: 200, text: async () => PATCH };
    };
    await startApp({ params: { patch_url: "https://d-0123456789abcdef.wmux.example/p.diff" }, fetch });
    assert.deepEqual(urls, ["https://d-0123456789abcdef.wmux.example/p.diff"]);
    assert.equal($$(".dv-file").length, 5);
    await startApp({ params: { patch_url: "https://evil.example.com/p.diff" }, fetch });
    assert.equal(urls.length, 1);
    assert.equal($("#dv-message").textContent, "Could not render this diff. Check the patch input and try again.");
  });

  test("unit: diff: refresh reloads through panel.diff.load and keeps choices", async () => {
    const { store } = await startApp({ params: { patch: PATCH, title: "" } });
    app.toggleFile(app.state.files.find((f) => f.path === "src/app.js"));
    store.patch = PATCH.replace("42", "43");
    click($("#dv-refresh"));
    await settle();
    assert.equal(lastCall("panel.diff.load").params.refresh, true);
    assert.ok(section("src/app.js").classList.contains("dv-collapsed"));
    app.toggleFile(app.state.files.find((f) => f.path === "src/app.js"));
    assert.equal($('td.dv-code.dv-add[data-line="2"] .dv-text', section("src/app.js")).textContent, "const answer = 43;");
    host.emit("panel.diff.patch", { patch: patch("--- a/z", "+++ b/z", "@@ -1 +1 @@", "-a", "+b"), title: "Pushed" });
    await settle();
    assert.equal($$(".dv-file").length, 1);
    assert.equal($("#dv-title").textContent, "Pushed");
  });

  test("unit: diff: copy git apply command", async () => {
    const { store } = await startApp();
    click($("#dv-copy-apply"));
    await settle();
    assert.equal(store.clipboard, gitApplyCommand(PATCH));
    assert.equal($("#dv-status").textContent, "Copied git apply command");
    await startApp({ handlers: { "panel.clipboard_write": () => { throw hostError("forbidden", "no gesture"); } } });
    click($("#dv-copy-apply"));
    await settle();
    assert.equal($("#dv-status").textContent, "Could not copy git apply command.");
    const cmd = gitApplyCommand("a\nWMUX_PATCH\n");
    assert.equal(cmd, "git apply <<'WMUX_PATCH_1'\na\nWMUX_PATCH\nWMUX_PATCH_1\n");
  });
});

describe("unit: diff app viewed and filter", () => {
  test("unit: diff: viewed progress survives refresh and flips on content change", async () => {
    const { store } = await startApp({ params: { title: "" } });
    for (const p of ["src/app.js", "docs/new.md"]) {
      const box = $(".dv-viewed-box", section(p));
      box.checked = true;
      box.dispatchEvent(new window.Event("change", { bubbles: true }));
    }
    await settle();
    assert.equal($("#dv-progress").textContent, "2 of 5 files viewed");
    assert.equal(host.calls("viewedFiles.set").length, 2);
    assert.match(lastCall("viewedFiles.set").params.fingerprint, /^fp1:/);
    assert.ok(section("src/app.js").classList.contains("dv-collapsed"), "viewed files collapse");
    const appIndex = app.state.files.find((f) => f.path === "src/app.js").index;
    assert.equal($(`.dv-tree-item[data-file="${appIndex}"] .dv-tree-viewed`).textContent, "✓");
    click($("#dv-refresh"));
    await settle();
    assert.equal($("#dv-progress").textContent, "2 of 5 files viewed");
    store.patch = PATCH.replace("42", "43");
    click($("#dv-refresh"));
    await settle();
    assert.equal($("#dv-progress").textContent, "1 of 5 files viewed");
    const changed = section("src/app.js");
    assert.equal($(".dv-changed-since", changed).hidden, false);
    assert.equal($(".dv-changed-since", changed).textContent, "Changed since viewed");
    assert.equal($(".dv-viewed-box", changed).checked, false);
    assert.equal($(".dv-viewed-box", section("docs/new.md")).title, "Mark as not viewed");
    await app.clearViewed();
    assert.equal(host.calls("viewedFiles.clear").length, 1);
    assert.equal($("#dv-progress").textContent, "0 of 5 files viewed");
  });

  test("unit: diff: filter by path, status and hide viewed with an empty state", async () => {
    await startApp();
    typeInto($("#dv-filter-input"), "src");
    assert.deepEqual($$(".dv-file").filter((s) => !s.hidden).map((s) => s.dataset.file), [String(app.state.files.find((f) => f.path === "src/app.js").index)]);
    assert.equal($$(".dv-tree-item").filter((i) => !i.hidden).length, 1);
    assert.equal($("#dv-sidebar-title").textContent, "Files");
    typeInto($("#dv-filter-input"), "");
    const renamed = $('input[data-status="renamed"]');
    renamed.checked = false;
    renamed.dispatchEvent(new window.Event("change", { bubbles: true }));
    assert.equal(section("docs/new.md").hidden, true);
    app.setViewed(app.state.files.find((f) => f.path === "src/app.js"), true);
    click($("#dv-hide-viewed"));
    assert.equal($("#dv-hide-viewed").textContent, "Show viewed files");
    assert.equal(section("src/app.js").hidden, true);
    typeInto($("#dv-filter-input"), "nothing-matches");
    assert.equal($("#dv-filter-empty").hidden, false);
    assert.equal($("#dv-filter-empty p").textContent, "No files match the filter.");
    click($("#dv-filter-clear"));
    assert.equal($("#dv-filter-empty").hidden, true);
    assert.equal($$(".dv-file").filter((s) => s.hidden).length, 0);
    assert.equal($("#dv-filter-input").value, "");
    assert.equal($("#dv-sidebar-title").textContent, "Changed files");
  });

  test("unit: diff: files panel toggle, tree jump and expand/collapse all", async () => {
    await startApp();
    click($("#dv-files-toggle"));
    assert.equal($("#dv-sidebar").hidden, true);
    assert.equal($("#dv-files-toggle").textContent, "Show files");
    click($("#dv-files-toggle"));
    assert.equal($("#dv-sidebar").hidden, false);
    assert.equal($("#dv-expand-all").textContent, "Expand all diffs");
    click($("#dv-expand-all"));
    assert.ok($("table", section("package-lock.json")));
    assert.equal($("#dv-expand-all").textContent, "Collapse all diffs");
    click($("#dv-expand-all"));
    assert.equal($$(".dv-file table").length, 0);
    const vp = fakeLayout();
    click($(`.dv-tree-item[data-file="${app.state.files.find((f) => f.path === "run.sh").index}"] button`));
    assert.equal(vp.scrollTop, $$(".dv-file").indexOf(section("run.sh")) * 1000);
  });
});

describe("unit: diff app keyboard", () => {
  test("unit: diff: ] f and [ f move between file headers", async () => {
    await startApp();
    const vp = fakeLayout();
    press("]");
    press("f");
    assert.equal(vp.scrollTop, 1000);
    press("]");
    press("f");
    assert.equal(vp.scrollTop, 2000);
    press("[");
    press("f");
    assert.equal(vp.scrollTop, 1000);
  });

  test("unit: diff: n / p move between hunks, j / k / G / g g scroll", async () => {
    await startApp();
    const vp = fakeLayout();
    const order = $$(".dv-file").indexOf(section("src/app.js")) * 1000;
    vp.scrollTop = order;
    press("n");
    assert.equal(vp.scrollTop, order + 100);
    press("n");
    assert.equal(vp.scrollTop, order + 200);
    press("p");
    assert.equal(vp.scrollTop, order + 100);
    press("j");
    assert.equal(vp.scrollTop, order + 140);
    press("k");
    assert.equal(vp.scrollTop, order + 100);
    press("G", { shiftKey: true });
    assert.equal(vp.scrollTop, 100000 - 500);
    press("g");
    press("g");
    assert.equal(vp.scrollTop, 0);
  });

  test("unit: diff: v toggles viewed on the current file; keys ignored while typing", async () => {
    await startApp();
    fakeLayout();
    press("v");
    const first = app.state.order[0];
    assert.equal(lastCall("viewedFiles.set").params.path, first.path);
    assert.equal(lastCall("viewedFiles.set").params.viewed, true);
    const before = host.calls("viewedFiles.set").length;
    const input = $("#dv-filter-input");
    input.focus();
    const e = press("v", {}, input);
    assert.equal(e.defaultPrevented, false);
    assert.equal(host.calls("viewedFiles.set").length, before);
  });

  test("unit: diff: rebinding from panel.init.keymap applies in the page", async () => {
    await startApp({ init: { keymap: { diffViewerNextHunk: ["m"], diffViewerPreviousHunk: ["p"] } } });
    const vp = fakeLayout();
    const base = $$(".dv-file").indexOf(section("src/app.js")) * 1000;
    vp.scrollTop = base;
    press("n");
    assert.equal(vp.scrollTop, base);
    press("m");
    assert.equal(vp.scrollTop, base + 100);
  });

  test("unit: diff: native commands run page actions", async () => {
    await startApp();
    host.emit("panel.diff.command", { action: "diffViewerOpenFileSearch" });
    assert.equal($("#dv-filesearch").hidden, false);
    host.emit("panel.diff.command", { action: "hideFind" });
    assert.equal($("#dv-filesearch").hidden, true);
    host.emit("panel.diff.command", { action: "nonsense" });
  });
});

describe("unit: diff app find and file search", () => {
  test("unit: diff: find cycles through matches across files with a counter", async () => {
    await startApp();
    fakeLayout();
    app.openFind("render");
    assert.equal($("#dv-find").hidden, false);
    // "render" appears in app.js (4 lines, one line twice) and new.md (1).
    const total = app.state.find.matches.length;
    assert.equal(total, 5);
    assert.equal($("#dv-find-count").textContent, "1/5");
    assert.equal($$(".dv-find-current").length, 1);
    const seen = new Set();
    for (let i = 0; i < total; i += 1) {
      const m = app.state.find.matches[app.state.find.index];
      seen.add(m.fileIndex + ":" + m.lineIndex + ":" + m.start);
      key($("#dv-find-input"), { key: "Enter", code: "Enter", keyCode: 13 });
    }
    assert.equal(seen.size, 5);
    assert.equal($("#dv-find-count").textContent, "1/5", "wraps around");
    key($("#dv-find-input"), { key: "Enter", code: "Enter", keyCode: 13, shiftKey: true });
    assert.equal($("#dv-find-count").textContent, "5/5");
    typeInto($("#dv-find-input"), "zzzz");
    assert.equal($("#dv-find-count").textContent, "No results");
  });

  test("unit: diff: find expands collapsed files, deferred files and gaps", async () => {
    await startApp();
    const lock = app.state.files.find((f) => f.path === "package-lock.json");
    app.toggleFile(app.state.files.find((f) => f.path === "src/app.js"));
    app.setPrefs({ contextLines: 0 });
    app.openFind("done();");
    assert.equal(app.state.find.matches.length, 1);
    assert.ok($("table", section("src/app.js")), "collapsed file expanded");
    assert.equal($$(".dv-find-current").map((x) => x.textContent).join(""), "done();");
    app.openFind("1.0.1");
    assert.ok($("table", section(lock.path)), "deferred file loaded");
    assert.equal($$(".dv-find-current").map((x) => x.textContent).join(""), "1.0.1");
  });

  test("unit: diff: Escape closes overlays innermost first", async () => {
    await startApp();
    app.openFind("render");
    press("/", {}, $("#dv-find-input"));
    assert.equal($("#dv-filesearch").hidden, true, "/ is typing inside the find field");
    app.openFileSearch();
    assert.equal($("#dv-filesearch").hidden, false);
    key($("#dv-filesearch-input"), { key: "Escape", code: "Escape", keyCode: 27 });
    assert.equal($("#dv-filesearch").hidden, true);
    assert.equal($("#dv-find").hidden, false, "find stays while another overlay owns Escape");
    click($("#dv-options"));
    key($("#dv-viewport"), { key: "Escape", code: "Escape", keyCode: 27 });
    assert.equal($("#dv-options-menu").hidden, true);
    assert.equal($("#dv-find").hidden, false);
    key($("#dv-find-input"), { key: "Escape", code: "Escape", keyCode: 27 });
    assert.equal($("#dv-find").hidden, true);
    assert.equal($$(".dv-find-hit").length, 0);
  });

  test("unit: diff: Escape closes overlays when the host keymap has no hideFind", async () => {
    await startApp({ init: { keymap: { diffViewerOpenFileSearch: ["/"] } } });
    click($("#dv-options"));
    assert.equal($("#dv-options-menu").hidden, false);
    const e = key($('#dv-options-menu [data-menu="wordWrap"]'), { key: "Escape", code: "Escape", keyCode: 27 });
    assert.equal($("#dv-options-menu").hidden, true);
    assert.equal(e.defaultPrevented, true);
    assert.equal(doc.activeElement, $("#dv-options"));
    app.openFind("render");
    key($("#dv-viewport"), { key: "Escape", code: "Escape", keyCode: 27 });
    assert.equal($("#dv-find").hidden, true);
    click($('td.dv-num-new[data-line="2"]', section("src/app.js")));
    assert.equal($$("td.dv-code.dv-selected").length, 1);
    key($("#dv-viewport"), { key: "Escape", code: "Escape", keyCode: 27 });
    assert.equal($$("td.dv-code.dv-selected").length, 0);
    const idle = key($("#dv-viewport"), { key: "Escape", code: "Escape", keyCode: 27 });
    assert.equal(idle.defaultPrevented, false, "nothing left to close");
  });

  test("unit: diff: native find events and Ctrl+F open the find bar", async () => {
    await startApp();
    host.emit("panel.diff.find", { query: "answer" });
    assert.equal($("#dv-find-input").value, "answer");
    assert.equal(app.state.find.matches.length, 3);
    app.closeFind();
    key($("#dv-viewport"), { key: "f", code: "KeyF", keyCode: 70, ctrlKey: true });
    assert.equal($("#dv-find").hidden, false);
    key($("#dv-viewport"), { key: "F3", code: "F3", keyCode: 114 });
  });

  test("unit: diff: / opens file search; typing ranks files; Enter jumps", async () => {
    await startApp();
    const vp = fakeLayout();
    press("/");
    assert.equal($("#dv-filesearch").hidden, false);
    assert.equal($("#dv-search-toggle").textContent, "Hide file search");
    typeInto($("#dv-filesearch-input"), "runsh");
    assert.equal($(".dv-filesearch-item").textContent, "run.sh");
    typeInto($("#dv-filesearch-input"), "a");
    key($("#dv-filesearch-input"), { key: "ArrowDown", code: "ArrowDown", keyCode: 40 });
    assert.equal($('.dv-filesearch-item[aria-selected="true"]'), $$(".dv-filesearch-item")[1]);
    typeInto($("#dv-filesearch-input"), "lock");
    key($("#dv-filesearch-input"), { key: "Enter", code: "Enter", keyCode: 13 });
    assert.equal($("#dv-filesearch").hidden, true);
    assert.equal(vp.scrollTop, $$(".dv-file").indexOf(section("package-lock.json")) * 1000);
    assert.ok($("table", section("package-lock.json")), "jump loads the deferred diff");
    typeInto(($("#dv-search-toggle").click(), $("#dv-filesearch-input")), "qqqq");
    assert.equal($("#dv-filesearch-list").textContent, "No matching files");
  });
});

describe("unit: diff app comments", () => {
  const SAVED = {
    id: "c-1",
    filePath: "src/app.js",
    side: "additions",
    startLine: 3,
    endLine: 3,
    lineText: "render(answer);",
    message: "Is <b>this</b> right?",
    submissionText: "x",
    createdAt: "2026-10-01T00:00:00.000Z",
    updatedAt: "2026-10-01T00:00:00.000Z",
  };

  test("unit: diff: existing comments render inline and in the Comments section", async () => {
    await startApp({
      comments: [
        SAVED,
        { ...SAVED, id: "c-2", startLine: 1, endLine: 1, lineText: "gone line" },
        { ...SAVED, id: "c-3", filePath: "elsewhere.c" },
        { ...SAVED, id: "c-4", startLine: 1, endLine: 1, lineText: "c();", side: "deletions" },
      ],
    });
    const sec = section("src/app.js");
    const inline = $$(".dv-comment-row .dv-comment", sec).map((c) => c.dataset.comment);
    assert.deepEqual(inline.sort(), ["c-1", "c-4"]);
    const card = $('.dv-comment-row [data-comment="c-1"]', sec);
    assert.equal($(".dv-comment-body", card).textContent, "Is <b>this</b> right?");
    assert.equal($("b", card), null);
    assert.equal(card.closest("tr").previousElementSibling.querySelector('td.dv-code[data-side="additions"]').dataset.line, "3");
    const moved = $('.dv-comment-row [data-comment="c-4"]', sec);
    assert.match(moved.textContent, /line 21 \(old version\)/);
    assert.match(moved.textContent, /Moved/);
    assert.equal($("#dv-comments-toggle").textContent, "Comments (4)");
    click($("#dv-comments-toggle"));
    assert.equal($("#dv-comments").hidden, false);
    assert.equal($("#dv-comments-empty").hidden, true);
    const items = $$("#dv-comments-list .dv-comments-item");
    assert.equal(items.length, 4);
    assert.match($('#dv-comments-list [data-comment="c-2"]').textContent, /Outdated/);
    assert.match($('#dv-comments-list [data-comment="c-3"]').textContent, /Not in this diff/);
  });

  test("unit: diff: add a comment through the composer", async () => {
    const { store } = await startApp();
    assert.equal($("#dv-comments-empty").textContent, "No comments yet");
    const sec = section("src/app.js");
    click($('td.dv-code.dv-add[data-line="2"] .dv-add-comment', sec));
    const composer = $(".dv-composer", sec);
    assert.ok(composer);
    const area = $("textarea", composer);
    assert.equal(area.placeholder, "Leave a comment");
    assert.equal(doc.activeElement, area);
    const submit = $('[data-action="submit-comment"]', composer);
    assert.equal(submit.textContent, "Comment");
    assert.equal($('[data-action="cancel-comment"]', composer).textContent, "Cancel");
    assert.equal(submit.disabled, true);
    press("v", {}, area);
    typeInto(area, "Use 43");
    assert.equal(submit.disabled, false);
    key(area, { key: "Enter", code: "Enter", keyCode: 13, ctrlKey: true });
    await settle();
    const saved = lastCall("comments.save").params.comment;
    assert.equal(saved.filePath, "src/app.js");
    assert.equal(saved.side, "additions");
    assert.equal(saved.startLine, 2);
    assert.equal(saved.lineText, "const answer = 42;");
    assert.equal(saved.message, "Use 43");
    assert.equal(saved.createdAt, NOW.toISOString());
    assert.equal(
      saved.submissionText,
      "Review comment on src/app.js line 2 (new version):\n\n```diff\n+const answer = 42;\n```\n\nUse 43\n",
    );
    assert.equal(store.comments.length, 1);
    assert.equal($(".dv-composer"), null);
    assert.equal($(".dv-comment-row .dv-comment-body", section("src/app.js")).textContent, "Use 43");
    assert.equal(host.calls("viewedFiles.set").length, 0, "v typed into the composer");
  });

  test("unit: diff: shift-click selects a range on one side (split view)", async () => {
    await startApp();
    app.setPrefs({ layout: "split" });
    const sec = section("src/app.js");
    const nums = $$('td.dv-num-new[data-line]', sec);
    click(nums.find((n) => n.dataset.line === "1"));
    click(nums.find((n) => n.dataset.line === "3"), { shiftKey: true });
    assert.deepEqual($$('td.dv-code.dv-selected', sec).map((c) => c.dataset.line), ["1", "2", "3"]);
    assert.ok($$('td.dv-code.dv-selected', sec).every((c) => c.dataset.side === "additions"));
    click($('td.dv-code[data-side="additions"][data-line="2"] .dv-add-comment', sec));
    const composer = $(".dv-composer", sec);
    assert.match($(".dv-composer-label", composer).textContent, /lines 1-3 \(new version\)/);
    assert.equal(composer.closest("td").colSpan, 2);
    typeInto($("textarea", composer), "range");
    click($('[data-action="submit-comment"]', composer));
    await settle();
    const saved = lastCall("comments.save").params.comment;
    assert.deepEqual([saved.startLine, saved.endLine], [1, 3]);
    assert.match(saved.submissionText, /^Review comment on src\/app\.js lines 1-3 \(new version\):/);
  });

  test("unit: diff: Escape and Cancel close the composer; save errors keep it", async () => {
    await startApp({ handlers: { "comments.save": () => { throw hostError("not_allowed", "nope"); } } });
    const sec = section("src/app.js");
    click($('td.dv-code.dv-add[data-line="2"] .dv-add-comment', sec));
    key($(".dv-composer textarea"), { key: "Escape", code: "Escape", keyCode: 27 });
    assert.equal($(".dv-composer"), null);
    click($('td.dv-code.dv-add[data-line="2"] .dv-add-comment', sec));
    typeInto($(".dv-composer textarea"), "x");
    click($('[data-action="submit-comment"]'));
    await settle();
    assert.ok($(".dv-composer"));
    assert.equal($("#dv-status").textContent, "Could not save comment: nope");
    click($('[data-action="cancel-comment"]'));
    assert.equal($(".dv-composer"), null);
  });

  test("unit: diff: edit and delete a comment", async () => {
    const { store } = await startApp({ comments: [SAVED] });
    const sec = section("src/app.js");
    click($('.dv-comment-row [data-action="edit-comment"]', sec));
    const area = $(".dv-composer textarea", sec);
    assert.equal(area.value, SAVED.message);
    assert.equal($('.dv-composer [data-action="submit-comment"]').textContent, "Save");
    typeInto(area, "Edited");
    click($('.dv-composer [data-action="submit-comment"]'));
    await settle();
    const saved = lastCall("comments.save").params.comment;
    assert.equal(saved.id, "c-1");
    assert.equal(saved.createdAt, SAVED.createdAt);
    assert.equal(saved.message, "Edited");
    click($('.dv-comment-row [data-action="delete-comment"]', section("src/app.js")));
    await settle();
    assert.equal(lastCall("comments.delete").params.id, "c-1");
    assert.equal(store.comments.length, 0);
    assert.equal($$(".dv-comment").length, 0);
    assert.equal($("#dv-comments-empty").hidden, false);
  });

  test("unit: diff: send to agent delivers pending comments and marks them sent", async () => {
    await startApp({ comments: [SAVED, { ...SAVED, id: "c-old", consumedAt: "2026-10-02T00:00:00.000Z" }] });
    assert.equal($("#dv-send").disabled, false);
    click($("#dv-send"));
    await settle();
    assert.deepEqual(lastCall("panel.diff.send_comments").params.ids, ["c-1"]);
    assert.equal($("#dv-status").textContent, "Sent 1 comment to the agent");
    assert.equal($("#dv-send").disabled, true);
    assert.match($('#dv-comments-list [data-comment="c-1"]').textContent, /Sent to agent/);
    host.emit("panel.diff.comments_changed", { comments: [] });
    await settle();
    assert.equal($$(".dv-comment").length, 0);
  });

  test("unit: diff: comments survive a missing store and re-anchor on refresh", async () => {
    await startApp({ handlers: { "comments.list": () => { throw hostError("method_not_found", "x"); } } });
    assert.equal(app.state.commentsSupported, false);
    const { store } = await startApp({ comments: [SAVED], params: { title: "" } });
    store.patch = PATCH.replace("@@ -1,5 +1,5 @@ function main() {\n import", "@@ -1,5 +1,6 @@ function main() {\n+// new first line\n import").replace(
      "@@ -20,3 +20,4 @@",
      "@@ -20,3 +21,4 @@",
    );
    click($("#dv-refresh"));
    await settle();
    const a = app.state.anchors.get("c-1");
    assert.equal(a.status, "moved");
    assert.equal(a.startLine, 4);
  });

  test("unit: diff: the composer keeps focus and caret when native re-renders", async () => {
    const { store } = await startApp();
    click($('td.dv-code.dv-add[data-line="2"] .dv-add-comment', section("src/app.js")));
    const area = $(".dv-composer textarea");
    typeInto(area, "half a thought");
    area.setSelectionRange(4, 4);
    host.emit("panel.diff.comments_changed", { comments: [] });
    await settle();
    let now = $(".dv-composer textarea");
    assert.notEqual(now, area, "the composer was rebuilt");
    assert.equal(doc.activeElement, now);
    assert.equal(now.value, "half a thought");
    assert.deepEqual([now.selectionStart, now.selectionEnd], [4, 4]);
    host.emit("panel.diff.patch", { patch: store.patch });
    await settle();
    now = $(".dv-composer textarea");
    assert.equal(doc.activeElement, now);
    assert.equal(now.value, "half a thought");
    const e = press("v", {}, now);
    assert.equal(e.defaultPrevented, false, "v keeps typing instead of toggling Viewed");
    assert.equal(host.calls("viewedFiles.set").length, 0);
  });
});

describe("unit: diff app session", () => {
  test("unit: diff: state snapshot and restore", async () => {
    await startApp();
    app.toggleFile(app.state.files.find((f) => f.path === "docs/new.md"));
    app.setPrefs({ layout: "split" });
    const snap = app.stateSnapshot();
    assert.equal(snap.v, 1);
    assert.equal(snap.prefs.layout, "split");
    assert.deepEqual(snap.collapsed, ["docs/new.md"]);
    assert.ok(JSON.stringify(snap).length < 65536);
    await startApp({ init: { state: { ...snap, find: "answer", files_visible: false } } });
    assert.ok(section("docs/new.md").classList.contains("dv-collapsed"));
    assert.ok($("table.dv-split"));
    assert.equal($("#dv-sidebar").hidden, true);
    assert.equal($("#dv-find-input").value, "answer");
  });

  test("unit: diff: outside wmux the page says so", async () => {
    freshDom();
    const offline = createApp({ document: doc, libs, bridge: { available: false, on: () => () => {}, context: null, panel: {} } });
    await offline.start();
    assert.equal($("#dv-message").textContent, "Not running inside wmux.");
    assert.equal($("#dv-title").textContent, "Untitled");
    offline.destroy();
  });
});
