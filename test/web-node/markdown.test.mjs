// Markdown panel tests: node:test + jsdom, driving the real panel modules
// (src/web/markdown/*) and the vendored libraries against a mock WebView2 host
// (window.chrome.webview) that speaks the bridge envelope.
//
// jsdom is not vendored: install it outside the repo and point
// WMUX_WEB_TEST_DEPS at that directory (the one containing node_modules/):
//
//   npm install --prefix /tmp/wmux-web-test-deps --ignore-scripts jsdom@26
//   WMUX_WEB_TEST_DEPS=/tmp/wmux-web-test-deps node --test test/web-node/
//
import { test, describe, beforeEach, afterEach, after } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "../..");
const web = path.join(repo, "src/web");
const depsDir = process.env.WMUX_WEB_TEST_DEPS;
const requireDeps = createRequire(
  depsDir ? path.join(path.resolve(depsDir), "package.json") : import.meta.url,
);
const { JSDOM } = requireDeps("jsdom");

/* ------------------------------------------------------------------------ */
/* page + mock host                                                          */
/* ------------------------------------------------------------------------ */

const indexHtml = readFileSync(path.join(web, "markdown/index.html"), "utf8");
const dom = new JSDOM(indexHtml, {
  url: "https://markdown.wmux.example/markdown/index.html",
  pretendToBeVisual: true,
});
const { window } = dom;
const pristineBody = window.document.body.innerHTML;

/** Mock of window.chrome.webview: records posts, answers calls from `handlers`. */
const host = {
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

function hostError(code, message) {
  const err = new Error(message || code);
  err.code = code;
  return err;
}

// Globals the page modules expect (bridge reads chrome.webview at import time).
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

const { default: markdownit } = await importWeb("_vendor/markdown-it@15.0.2/markdown-it.js");
const { default: footnote } = await importWeb("_vendor/markdown-it-footnote@4.0.0/markdown-it-footnote.js");
const { default: hljs } = await importWeb("_vendor/highlightjs-cdn-assets@11.12.0/highlight.min.js");
const { default: createDOMPurify } = await importWeb("_vendor/dompurify@3.4.17/purify.es.js");
const purify = createDOMPurify(window);
const { wmux } = await importWeb("_shared/wmux-bridge.js");
await importWeb("_shared/theme.js");
const { createApp } = await importWeb("markdown/app.js");
const { createRenderer, slugify, createSlugger, extractFrontmatter } = await importWeb("markdown/render.js");
const { classifyLink, classifyImage, looksLikeMarkdownPath, basename } = await importWeb("markdown/links.js");
const { createFind, MAX_MATCHES } = await importWeb("markdown/find.js");
const { createDiagrams } = await importWeb("markdown/diagrams.js");
const typo = await importWeb("markdown/typography.js");
const { scrollTarget, DEFAULT_KEYMAP } = await importWeb("markdown/keymap.js");

const libs = { markdownit, footnote, hljs, purify };
const doc = window.document;

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
async function settle(n = 6) {
  for (let i = 0; i < n; i += 1) await tick();
}

function newRenderer() {
  return createRenderer({ ...libs, document: doc });
}

function renderToDiv(source, options) {
  const out = newRenderer().render(source, options);
  const div = doc.createElement("div");
  div.append(out.fragment);
  return { div, out };
}

/* ------------------------------------------------------------------------ */
/* app harness                                                               */
/* ------------------------------------------------------------------------ */

let app = null;
let fakeMermaid = null;

const README = [
  "# Project",
  "",
  "Install it with `npm install`. Then install again.",
  "",
  "| Name | Value |",
  "| ---- | ----- |",
  "| a    | 1     |",
  "",
  "- [x] done",
  "- [ ] todo",
  "",
  "```swift",
  'let greeting = "install"',
  "```",
  "",
  "## Install",
  "",
  "See [design](./design.md), [site](https://example.com/), [mail](mailto:a@b.c),",
  "[notes](notes.txt), [top](#project) and [bad](javascript:alert(1)).",
  "",
  "Also read `docs/guide.md` and `missing.md`.",
  "",
].join("\n");

/**
 * Start a fresh app on a fresh body.
 * @param {{text?: string, init?: object, handlers?: Record<string, Function>}} [opts]
 */
async function startApp(opts = {}) {
  if (app) app.destroy();
  doc.body.innerHTML = pristineBody;
  doc.documentElement.removeAttribute("data-mode");
  host.reset();
  let fileText = opts.text === undefined ? README : opts.text;
  const handlers = {
    "panel.ready": () => ({}),
    "panel.set_title": () => ({}),
    "panel.set_dirty": () => ({}),
    "panel.state_changed": () => ({}),
    "panel.watch_file": () => ({}),
    "panel.clipboard_write": () => ({}),
    "panel.open_in_browser": () => ({}),
    "panel.open_external": () => ({}),
    "panel.open_file": () => ({}),
    "panel.markdown.open": () => ({}),
    "panel.markdown.resolve_links": ({ paths }) => ({
      exists: Object.fromEntries(paths.map((p) => [p, p === "docs/guide.md"])),
    }),
    "panel.read_file": () => {
      if (fileText === null) throw hostError("file_not_found", "File not found");
      return { text: fileText, encoding: "utf-8", base_url: "https://f-0123456789abcdef.wmux.example/" };
    },
    "panel.write_file": ({ text }) => {
      fileText = text;
      return {};
    },
    ...(opts.handlers || {}),
  };
  for (const [method, fn] of Object.entries(handlers)) host.handlers.set(method, fn);
  host.emit("panel.init", {
    kind: "markdown",
    surface_id: "5B1D2C9E-0000-4000-8000-000000000001",
    params: { path: "C:\\work\\proj\\README.md", display_path: "C:\\work\\proj\\README.md" },
    state: null,
    theme: { background: "#1e1e1e", foreground: "#d4d4d4" },
    settings: {},
    ...(opts.init || {}),
  });
  app = createApp({
    document: doc,
    libs,
    loadMermaid: () => Promise.resolve(fakeMermaid),
  });
  await app.start();
  await settle();
  return {
    app,
    setFile(text) {
      fileText = text;
    },
  };
}

function key(target, init) {
  const event = new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init });
  target.dispatchEvent(event);
  return event;
}

function click(el, init) {
  el.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0, ...init }));
}

function fakeScroller(el, { height = 500, scrollHeight = 5000 } = {}) {
  let top = 0;
  Object.defineProperty(el, "clientHeight", { configurable: true, get: () => height });
  Object.defineProperty(el, "scrollHeight", { configurable: true, get: () => scrollHeight });
  Object.defineProperty(el, "scrollTop", {
    configurable: true,
    get: () => top,
    set: (v) => {
      top = Math.max(0, Math.min(Number(v), scrollHeight - height));
    },
  });
}

after(() => window.close());

afterEach(() => {
  if (app) {
    app.destroy();
    app = null;
  }
});

/* ------------------------------------------------------------------------ */
/* rendering                                                                 */
/* ------------------------------------------------------------------------ */

describe("unit: markdown render", () => {
  test("unit: markdown: renders GFM tables, strikethrough, autolinks and nested lists", () => {
    const { div } = renderToDiv(
      "| A | B |\n|:--|--:|\n| 1 | 2 |\n\n~~gone~~ https://example.com/x and a@b.example\n\n- one\n  - two\n\n> quote",
    );
    const table = div.querySelector("table");
    assert.ok(table, "table rendered");
    assert.equal(table.querySelectorAll("thead th").length, 2);
    assert.equal(table.querySelector("tbody td").textContent, "1");
    assert.deepEqual(
      Array.from(table.querySelectorAll("th")).map((th) => th.getAttribute("align")),
      ["left", "right"],
    );
    assert.equal(table.querySelector("[style]"), null);
    assert.equal(div.querySelector("s, del").textContent, "gone");
    assert.equal(div.querySelector("a").getAttribute("href"), "https://example.com/x");
    assert.equal(div.querySelectorAll("a")[1].getAttribute("href"), "mailto:a@b.example");
    assert.equal(div.querySelector("a").getAttribute("rel"), "noreferrer noopener");
    assert.ok(div.querySelector("ul ul li"));
    assert.ok(div.querySelector("blockquote"));
  });

  test("unit: markdown: renders GFM task lists as disabled checkboxes", () => {
    const { div } = renderToDiv("- [x] done\n- [ ] todo\n- [X] Done too\n- not a task\n\n1. [ ] numbered");
    const boxes = div.querySelectorAll("input.task-list-item-checkbox");
    assert.equal(boxes.length, 4);
    assert.deepEqual(
      Array.from(boxes).map((b) => b.checked),
      [true, false, true, false],
    );
    for (const box of boxes) assert.ok(box.disabled, "checkbox disabled");
    assert.equal(div.querySelectorAll("li.task-list-item").length, 4);
    assert.ok(div.querySelector("ul.contains-task-list"));
    assert.ok(div.querySelector("ol.contains-task-list"));
    assert.equal(div.querySelectorAll("li")[0].textContent.trim(), "done");
    assert.equal(div.querySelectorAll("li")[3].querySelector("input"), null);
  });

  test("unit: markdown: highlights fenced code and adds a copy button", () => {
    const { div } = renderToDiv(
      '```swift\nlet x = "a"\n```\n\n```js\nconst y = 1 < 2;\n```\n\n```nosuchlang\n<b>raw</b>\n```\n\n    indented',
    );
    const blocks = div.querySelectorAll(".mdv-code-block");
    assert.equal(blocks.length, 4);
    for (const block of blocks) {
      assert.equal(block.querySelector("button.mdv-copy-code").textContent, "Copy code");
    }
    const swift = blocks[0].querySelector("code");
    assert.ok(swift.classList.contains("language-swift"));
    assert.ok(swift.querySelector(".hljs-keyword"), "swift keyword highlighted");
    assert.equal(swift.textContent, 'let x = "a"\n');
    assert.ok(blocks[1].querySelector(".hljs-keyword"));
    assert.equal(blocks[1].querySelector("code").textContent, "const y = 1 < 2;\n");
    // Unknown languages stay escaped text.
    assert.equal(blocks[2].querySelector("b"), null);
    assert.equal(blocks[2].querySelector("code").textContent, "<b>raw</b>\n");
  });

  test("unit: markdown: GitHub heading slugs are unique and unicode aware", () => {
    assert.equal(slugify("Hello, World!"), "hello-world");
    assert.equal(slugify("  API_v2 (beta) "), "api_v2-beta");
    assert.equal(slugify("Ünïcödé Straße 日本語"), "ünïcödé-straße-日本語");
    assert.equal(slugify("emoji 🚀 here"), "emoji--here");
    assert.equal(slugify("!!!"), "");
    const slug = createSlugger();
    assert.deepEqual(
      ["Intro", "Intro", "Intro", "Intro-1", ""].map(slug),
      ["intro", "intro-1", "intro-2", "intro-1-1", ""],
    );
    const { div } = renderToDiv("# Setup\n## Setup\n### `code` *Setup*\n#### !!!");
    assert.deepEqual(
      Array.from(div.querySelectorAll("h1,h2,h3,h4")).map((h) => h.id),
      ["setup", "setup-1", "code-setup", ""],
    );
  });

  test("unit: markdown: frontmatter is a collapsed disclosure, not a rule", () => {
    assert.deepEqual(extractFrontmatter("---\ntitle: x\n---\nbody"), { frontmatter: "title: x", body: "body" });
    assert.deepEqual(extractFrontmatter("\ufeff---\r\na: 1\r\n...\r\n# H"), { frontmatter: "a: 1", body: "# H" });
    assert.deepEqual(extractFrontmatter("---\n---\ntext"), { frontmatter: "", body: "text" });
    assert.equal(extractFrontmatter("---\nno closing").frontmatter, null);
    assert.equal(extractFrontmatter("text\n---\na: b\n---").frontmatter, null);
    assert.equal(extractFrontmatter("").body, "");

    const { div, out } = renderToDiv("---\ntitle: x\ntags: [a, b]\n---\n# Body");
    assert.equal(out.frontmatter, "title: x\ntags: [a, b]");
    const details = div.querySelector("details.wmux-frontmatter");
    assert.ok(details);
    assert.equal(details.hasAttribute("open"), false);
    assert.equal(details.querySelector("summary").textContent, "Show frontmatter");
    assert.ok(details.querySelector("code.language-yaml .hljs-attr"), "yaml highlighted");
    assert.equal(div.querySelector("hr"), null);
    assert.equal(div.querySelector("h1").textContent, "Body");
  });

  test("unit: markdown: sanitizes scripts, handlers, forms, frames, styles and script URLs", () => {
    const { div } = renderToDiv(
      [
        "<script>alert(1)</script>",
        '<img src="x.png" onerror="alert(1)">',
        '<a href="javascript:alert(1)">js</a> <a href="JaVaScRiPt&#58;alert(1)">js2</a>',
        '<form action="/x"><input name="q"><button>go</button></form>',
        '<iframe src="https://example.com"></iframe><object data="x"></object><embed src="x">',
        '<meta http-equiv="refresh" content="0;url=https://evil.example">',
        '<p style="color:red" onclick="x()">styled</p><style>body{display:none}</style>',
        "<kbd>Ctrl</kbd> <details><summary>more</summary>hidden</details>",
        "[md js](javascript:alert(1)) [data](data:text/html;base64,PHNjcmlwdD4=)",
        '<img src="x.png" srcset="https://evil.example/a.png 2x">',
        '<span data-mdv-path="evil.md" data-mdv-file-exists="true">forged</span>',
      ].join("\n\n"),
    );
    assert.equal(div.querySelector("[data-mdv-path], [data-mdv-file-exists]"), null, "app markers cannot be forged");
    const html = div.innerHTML;
    assert.doesNotMatch(html, /<script|onerror|onclick|<form|<iframe|<object|<embed|<meta|<style|style=/i);
    assert.equal(div.querySelector('[href^="javascript" i], [src^="javascript" i]'), null);
    assert.match(html, /\[md js\]\(javascript:alert\(1\)\)/, "script links stay plain text");
    assert.doesNotMatch(html, /srcset/i);
    assert.equal(div.querySelector("input"), null, "form inputs removed");
    assert.equal(div.querySelector("button:not(.mdv-copy-code)"), null);
    assert.ok(div.querySelector("kbd"));
    assert.ok(div.querySelector("details summary"));
    assert.equal(div.querySelector('[href^="data:"]'), null);
  });

  test("unit: markdown: renders footnotes and keeps file: links", () => {
    const { div } = renderToDiv("Text[^1].\n\n[^1]: The note.\n\n[f](file:///C:/docs/a.md)");
    assert.ok(div.querySelector("section.footnotes"));
    const ref = div.querySelector("sup a");
    assert.ok(ref.getAttribute("href").startsWith("#fn"));
    assert.ok(div.querySelector('a[href="file:///C:/docs/a.md"]'));
  });

  test("unit: markdown: images use the file host, block remote URLs and keep approved ones", () => {
    const base = "https://f-0123456789abcdef.wmux.example/";
    const { div, out } = renderToDiv(
      [
        "![a](img/a.png)",
        "![up](../up.png)",
        "![badge](https://img.shields.io/badge/x-y-green)",
        "[![linked](https://example.com/b.png)](https://example.com)",
        "![ok](https://example.com/ok.png)",
        "![abs](C:\\pics\\c.png)",
        "![data](data:image/png;base64,iVBORw0KGgo=)",
      ].join("\n\n"),
      { baseUrl: base, approvedImages: new Set(["https://example.com/ok.png"]) },
    );
    const imgs = Array.from(div.querySelectorAll("img"));
    const byAlt = (alt) => imgs.find((i) => i.getAttribute("alt") === alt);
    assert.equal(byAlt("a").getAttribute("src"), base + "img/a.png");
    assert.equal(byAlt("up").getAttribute("src"), base + "up.png", "cannot climb above the host root");
    assert.equal(byAlt("ok").getAttribute("src"), "https://example.com/ok.png");
    assert.equal(byAlt("abs").hasAttribute("src"), false);
    assert.equal(byAlt("abs").getAttribute("data-mdv-local-src"), "C:\\pics\\c.png");
    assert.equal(out.imageRequests.length, 1);
    assert.ok(byAlt("data").getAttribute("src").startsWith("data:image/png"));

    const placeholders = div.querySelectorAll(".wmux-remote-image");
    assert.equal(placeholders.length, 2);
    assert.equal(placeholders[0].getAttribute("data-url"), "https://img.shields.io/badge/x-y-green");
    assert.match(placeholders[0].textContent, /Remote image blocked/);
    assert.match(placeholders[0].textContent, /will not contact this image URL until you load this image/);
    assert.deepEqual(
      Array.from(placeholders[0].querySelectorAll("button")).map((b) => b.getAttribute("data-image-action")),
      ["load", "open", "copy"],
    );
    // Linked image: the placeholder follows the anchor instead of sitting inside it.
    const link = div.querySelector('a[href="https://example.com"]');
    assert.equal(link.querySelector(".wmux-remote-image"), null);
    assert.equal(link.nextElementSibling, placeholders[1]);
    assert.equal(link.textContent, "linked");
  });

  test("unit: markdown: mermaid fences become placeholders with the source hidden", () => {
    const { div, out } = renderToDiv("```mermaid\ngraph TD; A-->B\n```\n\n```Mermaid\nx\n```");
    assert.equal(out.diagrams, 2);
    const blocks = div.querySelectorAll(".wmux-diagram.wmux-mermaid");
    assert.equal(blocks.length, 2);
    const source = blocks[0].querySelector("pre.wmux-source");
    assert.ok(source.hidden);
    assert.equal(source.textContent, "graph TD; A-->B\n");
    assert.equal(blocks[0].querySelector(".mdv-copy-code"), null);
  });

  test("unit: markdown: handles empty, huge and malformed input", () => {
    assert.equal(renderToDiv("").div.innerHTML, "");
    assert.equal(renderToDiv(null).div.innerHTML, "");
    const lines = [];
    for (let i = 0; i < 4000; i += 1) lines.push(`## Heading ${i % 50}\n\nParagraph ${i} with *emphasis* and \`code\`.`);
    const started = Date.now();
    const { div } = renderToDiv(lines.join("\n\n"));
    assert.equal(div.querySelectorAll("h2").length, 4000);
    assert.equal(new Set(Array.from(div.querySelectorAll("h2")).map((h) => h.id)).size, 4000);
    assert.ok(Date.now() - started < 20000);
    const weird = renderToDiv("<div><span>unclosed\n\n[link](<bad\n\n```\nunterminated fence\n\u0000\ud800");
    assert.ok(weird.div.textContent.includes("unterminated fence"));
  });
});

/* ------------------------------------------------------------------------ */
/* link classification                                                       */
/* ------------------------------------------------------------------------ */

describe("unit: markdown links", () => {
  test("unit: markdown: classifies link targets for routing", () => {
    assert.deepEqual(classifyLink("#install"), { action: "anchor", id: "install" });
    assert.deepEqual(classifyLink("#caf%C3%A9"), { action: "anchor", id: "café" });
    assert.deepEqual(classifyLink("https://example.com/a?b=1"), { action: "browser", url: "https://example.com/a?b=1" });
    assert.deepEqual(classifyLink("HTTP://Example.com"), { action: "browser", url: "http://example.com/" });
    assert.deepEqual(classifyLink("//cdn.example.com/x"), { action: "browser", url: "https://cdn.example.com/x" });
    assert.deepEqual(classifyLink("mailto:a@b.c"), { action: "external", url: "mailto:a@b.c" });
    assert.deepEqual(classifyLink("vscode://file/c:/x"), { action: "external", url: "vscode://file/c:/x" });
    assert.deepEqual(classifyLink("tel:+123"), { action: "external", url: "tel:+123" });
    assert.deepEqual(classifyLink("./design.md"), { action: "markdown", path: "./design.md", fragment: "" });
    assert.deepEqual(classifyLink("../docs/My%20Guide.markdown?x=1#part-2"), {
      action: "markdown",
      path: "../docs/My Guide.markdown",
      fragment: "part-2",
    });
    assert.deepEqual(classifyLink("notes.MDX"), { action: "markdown", path: "notes.MDX", fragment: "" });
    assert.deepEqual(classifyLink("C:\\docs\\a.mkd"), { action: "markdown", path: "C:\\docs\\a.mkd", fragment: "" });
    assert.deepEqual(classifyLink("file:///C:/docs/a%20b.md#top"), {
      action: "markdown",
      path: "C:/docs/a b.md",
      fragment: "top",
    });
    assert.deepEqual(classifyLink("file://server/share/x.txt"), { action: "file", path: "//server/share/x.txt" });
    assert.deepEqual(classifyLink("src/main.zig"), { action: "file", path: "src/main.zig" });
    assert.deepEqual(classifyLink("日本/読む.md"), { action: "markdown", path: "日本/読む.md", fragment: "" });
    assert.deepEqual(classifyLink("?q=1#frag"), { action: "anchor", id: "frag" });
    for (const bad of ["", "   ", "#", "javascript:alert(1)", " JavaScript:x", "data:text/html,x", "vbscript:x", "blob:x", "a\u0000b", "x".repeat(5000), null, 42, ".md"]) {
      const action = classifyLink(bad).action;
      assert.ok(action === "none" || (bad === ".md" && action === "file"), `none for ${String(bad).slice(0, 20)}`);
    }
    assert.ok(looksLikeMarkdownPath("docs/foo.md"));
    assert.ok(looksLikeMarkdownPath("../x.md#a"));
    assert.ok(!looksLikeMarkdownPath("https://x.example/a.md"));
    assert.ok(!looksLikeMarkdownPath("two words.md"));
    assert.ok(!looksLikeMarkdownPath("file.txt"));
    assert.equal(basename("C:\\work\\proj\\README.md"), "README.md");
    assert.equal(basename("/a/b/"), "b");
    assert.equal(basename(""), "");
  });

  test("unit: markdown: classifies image sources", () => {
    const base = "https://f-00ff.wmux.example/";
    assert.deepEqual(classifyImage("a.png", base), { kind: "local", url: base + "a.png" });
    assert.deepEqual(classifyImage("a b.png", base), { kind: "local", url: base + "a%20b.png" });
    assert.deepEqual(classifyImage("a.png", null), { kind: "none" });
    assert.deepEqual(classifyImage("a.png", "https://evil.example/"), { kind: "none" });
    assert.deepEqual(classifyImage(base + "x.png", base), { kind: "host", url: base + "x.png" });
    assert.deepEqual(classifyImage("https://f-other.wmux.example/x.png", base), {
      kind: "remote",
      url: "https://f-other.wmux.example/x.png",
    });
    assert.deepEqual(classifyImage("/abs/p.png", base), { kind: "absolute", path: "/abs/p.png" });
    assert.deepEqual(classifyImage("file:///C:/p.png", base), { kind: "absolute", path: "C:/p.png" });
    assert.deepEqual(classifyImage("\\\\srv\\share\\p.png", base), { kind: "absolute", path: "\\\\srv\\share\\p.png" });
    assert.deepEqual(classifyImage("ftp://x/p.png", base), { kind: "none" });
    assert.deepEqual(classifyImage("", base), { kind: "none" });
  });
});

/* ------------------------------------------------------------------------ */
/* find, typography, keymap helpers                                          */
/* ------------------------------------------------------------------------ */

describe("unit: markdown helpers", () => {
  test("unit: markdown: find highlights matches, wraps and counts", () => {
    const root = doc.createElement("div");
    root.innerHTML =
      "<p>Install the app. INSTALL now.</p><p>re<b>install</b>ed</p><pre class='wmux-source' hidden>install</pre><button>install</button>";
    doc.body.append(root);
    const states = [];
    const find = createFind(root, { onChange: (s) => states.push(s), scroll: () => {} });
    assert.deepEqual(find.search("install"), { needle: "install", current: 1, total: 3 });
    const marks = root.querySelectorAll("mark.mdv-find-match");
    assert.equal(marks.length, 3);
    assert.ok(marks[0].classList.contains("mdv-find-current"));
    assert.equal(marks[1].textContent, "INSTALL");
    assert.equal(find.next().current, 2);
    assert.equal(find.next().current, 3);
    assert.equal(find.next().current, 1, "wraps forward");
    assert.equal(find.previous().current, 3, "wraps backward");
    assert.equal(root.querySelectorAll(".mdv-find-current").length, 1);
    assert.equal(find.search("").total, 0);
    assert.equal(root.querySelectorAll("mark").length, 0);
    assert.equal(root.querySelector("p").textContent, "Install the app. INSTALL now.");
    assert.equal(root.querySelector("p").childNodes.length, 1, "text nodes normalized after clear");
    assert.equal(find.search("ünï").total, 0);
    root.innerHTML = "<p>ÜNÏCODE ünïcode Straße</p>";
    assert.equal(find.search("ünïcode").total, 2);
    assert.equal(find.search("a.p").total, 0, "needle is literal");
    assert.ok(states.length > 0);
    root.remove();
  });

  test("unit: markdown: find caps the number of highlights", () => {
    const root = doc.createElement("div");
    // jsdom is slow with tens of thousands of nodes; the cap is injectable (<= MAX_MATCHES).
    root.textContent = "ab".repeat(600);
    const find = createFind(root, { scroll: () => {}, maxMatches: 500 });
    assert.equal(find.search("a").total, 500);
    assert.equal(find.search("B").total, 500);
    find.clear();
    assert.equal(root.textContent, "ab".repeat(600));
    assert.equal(root.childNodes.length, 1);
    assert.equal(createFind(root, { maxMatches: 1e9 }).search("a").total, 600);
    assert.ok(MAX_MATCHES >= 1000);
  });

  test("unit: markdown: typography clamps, steps and adopts defaults", () => {
    assert.equal(typo.clampFontSize(7), 8);
    assert.equal(typo.clampFontSize(200), 96);
    assert.equal(typo.clampFontSize("16.4"), 16);
    assert.equal(typo.clampFontSize("abc"), 15);
    assert.equal(typo.clampMaxWidth(611), 620);
    assert.equal(typo.clampMaxWidth(10), 320);
    assert.equal(typo.clampMaxWidth(1e9), 2400);
    assert.equal(typo.zoomFactor(15), 1);
    assert.equal(typo.zoomFactor(30), 2);
    assert.equal(typo.zoomStep(96, 1), 96);
    assert.equal(typo.zoomStep(8, -1), 8);
    assert.equal(typo.normalizeFontFamily(' "Fira";}\u0000 '), "Fira");
    assert.equal(typo.normalizeFontFamily("System"), "");
    assert.deepEqual(typo.readDefaults({ "markdown.fontSize": 18, "markdown.maxWidth": 600 }), {
      fontSize: 18,
      fontFamily: "",
      maxWidth: 600,
    });
    assert.deepEqual(typo.readDefaults({ markdown: { font_family: "Georgia" } }), {
      fontSize: 15,
      fontFamily: "Georgia",
      maxWidth: 980,
    });
    assert.deepEqual(typo.readDefaults(null), typo.BUILTIN_DEFAULTS);
    const prev = { fontSize: 15, fontFamily: "", maxWidth: 980 };
    const next = { fontSize: 15, fontFamily: "", maxWidth: 600 };
    assert.deepEqual(typo.adoptDefaults({ fontSize: 15, fontFamily: "", maxWidth: 980 }, prev, next).maxWidth, 600);
    assert.deepEqual(typo.adoptDefaults({ fontSize: 20, fontFamily: "", maxWidth: 1200 }, prev, next), {
      fontSize: 20,
      fontFamily: "",
      maxWidth: 1200,
    });
  });

  test("unit: markdown: scroll targets for viewer navigation keys", () => {
    const v = { top: 100, height: 600, max: 2000 };
    assert.equal(scrollTarget("diffViewerScrollDown", v), 140);
    assert.equal(scrollTarget("diffViewerScrollUpEmacs", v), 60);
    assert.equal(scrollTarget("diffViewerScrollHalfPageDown", v), 400);
    assert.equal(scrollTarget("diffViewerScrollHalfPageUp", v), 0);
    assert.equal(scrollTarget("diffViewerScrollToBottom", v), 2000);
    assert.equal(scrollTarget("diffViewerScrollToTop", v), 0);
    assert.equal(scrollTarget("nope", v), null);
    assert.equal(scrollTarget("diffViewerScrollDown", { top: 0, height: 0, max: -5 }), 0);
    assert.deepEqual(DEFAULT_KEYMAP.diffViewerScrollToTop, ["g g"]);
  });
});

/* ------------------------------------------------------------------------ */
/* diagrams                                                                  */
/* ------------------------------------------------------------------------ */

describe("unit: markdown diagrams", () => {
  test("unit: markdown: mermaid loads lazily once, renders SVG and shows inline errors", async () => {
    let loads = 0;
    const renders = [];
    const mermaid = {
      initialized: null,
      initialize(cfg) {
        this.initialized = cfg;
      },
      async render(id, text) {
        renders.push(id);
        if (!text.includes("-->")) throw new Error("Parse error on line 1:\nExpecting arrow");
        return {
          svg: `<svg id="${id}" xmlns="http://www.w3.org/2000/svg"><style>#${id} .node{fill:red}</style><g class="node" style="opacity: 0.5"><text>A</text></g><script>alert(1)</script></svg>`,
        };
      },
    };
    const diagrams = createDiagrams({
      document: doc,
      purify,
      loadMermaid: async () => {
        loads += 1;
        return mermaid;
      },
      scheme: () => "light",
    });
    const root = doc.createElement("div");
    assert.equal(await diagrams.render(root), 0);
    assert.equal(loads, 0, "no diagram, no load");

    root.append(renderToDiv("```mermaid\ngraph TD; A-->B\n```\n\n```mermaid\nnot a diagram\n```").div);
    doc.body.append(root);
    assert.equal(await diagrams.render(root), 2);
    assert.equal(loads, 1);
    assert.equal(mermaid.initialized.securityLevel, "strict");
    assert.equal(mermaid.initialized.theme, "default");
    const [ok, bad] = root.querySelectorAll(".wmux-mermaid");
    assert.equal(ok.getAttribute("data-state"), "rendered");
    const svg = ok.querySelector(".wmux-diagram-output svg");
    assert.ok(svg);
    assert.equal(svg.querySelector("script"), null);
    assert.equal(svg.querySelector("style"), null, "style moved out of the markup");
    assert.equal(svg.querySelector("g").getAttribute("style"), "opacity: 0.5;", "inline style re-applied via CSSOM");
    assert.equal(bad.getAttribute("data-state"), "error");
    assert.equal(bad.querySelector(".wmux-diagram-error").textContent, "Mermaid error: Parse error on line 1:");
    assert.ok(ok.querySelector(".wmux-source").hidden, "source kept hidden");
    assert.equal(await diagrams.render(root), 0, "rendered blocks are not rendered again");
    assert.equal(loads, 1);
    root.remove();
  });

  test("unit: markdown: a failing mermaid load shows the error box", async () => {
    const diagrams = createDiagrams({
      document: doc,
      purify,
      loadMermaid: () => Promise.reject(new Error("Failed to load mermaid")),
    });
    const root = renderToDiv("```mermaid\ngraph TD; A-->B\n```").div;
    await diagrams.render(root);
    assert.equal(root.querySelector(".wmux-diagram-error").textContent, "Mermaid error: Failed to load mermaid");
  });

  test("unit: markdown: vendored mermaid parses valid and rejects malformed diagrams", async () => {
    const mdom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
      url: "https://markdown.wmux.example/markdown/index.html",
      runScripts: "outside-only",
      pretendToBeVisual: true,
    });
    // A classic script (top-level var declarations become globals), as in the page.
    new vm.Script(readFileSync(path.join(web, "_vendor/mermaid@11.17.2/mermaid.min.js"), "utf8")).runInContext(
      mdom.getInternalVMContext(),
    );
    const mermaid = mdom.window.mermaid;
    assert.equal(typeof mermaid.render, "function");
    mermaid.initialize({ startOnLoad: false, securityLevel: "strict" });
    assert.ok(await mermaid.parse("graph TD; A-->B"));
    await assert.rejects(() => mermaid.parse("graph TD; A-->"));
    mdom.window.close();
  });
});

/* ------------------------------------------------------------------------ */
/* app                                                                       */
/* ------------------------------------------------------------------------ */

describe("unit: markdown app", () => {
  beforeEach(() => {
    fakeMermaid = {
      initialize() {},
      async render(id) {
        return { svg: `<svg id="${id}" xmlns="http://www.w3.org/2000/svg"><text>diagram</text></svg>` };
      },
    };
  });

  test("unit: markdown: loads the file through the bridge, sets the title and watches", async () => {
    await startApp();
    assert.equal(host.calls("panel.read_file").length, 1);
    assert.deepEqual(host.calls("panel.set_title")[0].params, { title: "README.md" });
    assert.deepEqual(host.calls("panel.watch_file")[0].params, { on: true });
    const content = doc.getElementById("mdv-content");
    assert.equal(content.querySelector("h1").id, "project");
    assert.ok(content.querySelector("table"));
    assert.equal(content.querySelectorAll("input.task-list-item-checkbox").length, 2);
    assert.ok(content.querySelector("code.language-swift"));
    assert.equal(doc.getElementById("mdv-unavailable").hidden, true);
    assert.equal(doc.title, "README.md");
  });

  test("unit: markdown: renders params.text without reading the file", async () => {
    await startApp({ init: { params: { display_path: "notes.md", text: "# Inline" } } });
    assert.equal(host.calls("panel.read_file").length, 0);
    assert.equal(doc.querySelector("#mdv-content h1").textContent, "Inline");
  });

  test("unit: markdown: routes link clicks through the bridge", async () => {
    await startApp();
    const content = doc.getElementById("mdv-content");
    const link = (text) => Array.from(content.querySelectorAll("a")).find((a) => a.textContent === text);

    click(link("site"));
    click(link("mail"));
    click(link("design"));
    click(link("notes"));
    click(link("top"));
    await settle();
    assert.deepEqual(host.calls("panel.open_in_browser").map((m) => m.params), [{ url: "https://example.com/" }]);
    assert.deepEqual(host.calls("panel.open_external").map((m) => m.params), [{ url: "mailto:a@b.c" }]);
    assert.deepEqual(host.calls("panel.markdown.open").map((m) => m.params), [{ path: "./design.md" }]);
    assert.deepEqual(host.calls("panel.open_file").map((m) => m.params), [{ path: "notes.txt" }]);
    // The javascript: link is not a link at all.
    assert.equal(link("bad"), undefined);

    // Middle click routes too; the default navigation is always prevented.
    const event = new window.MouseEvent("auxclick", { bubbles: true, cancelable: true, button: 1 });
    link("site").dispatchEvent(event);
    assert.ok(event.defaultPrevented);
    await settle();
    assert.equal(host.calls("panel.open_in_browser").length, 2);
  });

  test("unit: markdown: markdown links fall back to the open router", async () => {
    await startApp({
      handlers: {
        "panel.markdown.open": () => {
          throw hostError("method_not_found", "Unknown method");
        },
      },
    });
    await app.routeLink("guide/intro.md#start");
    assert.deepEqual(host.calls("panel.markdown.open")[0].params, { path: "guide/intro.md", fragment: "start" });
    assert.deepEqual(host.calls("panel.open_file")[0].params, { path: "guide/intro.md" });
  });

  test("unit: markdown: code spans that name existing markdown files become links", async () => {
    await startApp();
    assert.deepEqual(host.calls("panel.markdown.resolve_links")[0].params, { paths: ["docs/guide.md", "missing.md"] });
    const guide = doc.querySelector('code[data-mdv-path="docs/guide.md"]');
    const missing = doc.querySelector('code[data-mdv-path="missing.md"]');
    assert.equal(guide.getAttribute("data-mdv-file-exists"), "true");
    assert.equal(guide.getAttribute("role"), "link");
    assert.equal(missing.getAttribute("data-mdv-file-exists"), "false");
    click(guide);
    click(missing);
    await settle();
    assert.deepEqual(host.calls("panel.markdown.open").map((m) => m.params), [{ path: "docs/guide.md" }]);

    // Results are cached per page: a re-render asks nothing new.
    app.renderPreview(true);
    await settle();
    assert.equal(host.calls("panel.markdown.resolve_links").length, 1);
  });

  test("unit: markdown: live reload re-renders, keeps the scroll position and re-applies find", async () => {
    const page = await startApp();
    const viewport = doc.getElementById("mdv-viewport");
    fakeScroller(viewport);
    viewport.scrollTop = 700;

    app.openFind("install");
    await settle();
    assert.equal(doc.getElementById("mdv-find-count").textContent, "1/5");

    host.emit("panel.markdown.file_changed", { status: "changed", text: README + "\nOne more install.\n" });
    await settle();
    assert.match(doc.getElementById("mdv-content").textContent, /One more install\./);
    assert.equal(viewport.scrollTop, 700, "no jump to the top");
    assert.equal(doc.getElementById("mdv-find-count").textContent, "1/6");
    assert.equal(doc.querySelectorAll("#mdv-content mark.mdv-find-match").length, 6);

    // Without text in the event the page re-reads the file.
    page.setFile("# Changed on disk\n");
    host.emit("panel.markdown.file_changed", { status: "changed" });
    await settle();
    assert.equal(host.calls("panel.read_file").length, 2);
    assert.equal(doc.querySelector("#mdv-content h1").textContent, "Changed on disk");
  });

  test("unit: markdown: only the newest reload is applied", async () => {
    const page = await startApp();
    let release;
    const gate = new Promise((resolve) => {
      release = resolve;
    });
    let n = 0;
    host.handlers.set("panel.read_file", async () => {
      n += 1;
      if (n === 1) {
        await gate;
        return { text: "# Stale" };
      }
      return { text: "# Fresh" };
    });
    host.emit("panel.markdown.file_changed", {});
    host.emit("panel.markdown.file_changed", {});
    await settle();
    release();
    await settle();
    assert.equal(doc.querySelector("#mdv-content h1").textContent, "Fresh");
    void page;
  });

  test("unit: markdown: deleted files show File unavailable and recover", async () => {
    await startApp();
    host.emit("panel.markdown.file_changed", { status: "deleted" });
    await settle();
    const unavailable = doc.getElementById("mdv-unavailable");
    assert.equal(unavailable.hidden, false);
    assert.equal(doc.getElementById("mdv-content").hidden, true);
    assert.match(unavailable.textContent, /File unavailable/);
    assert.equal(doc.getElementById("mdv-unavailable-path").textContent, "C:\\work\\proj\\README.md");

    host.emit("panel.markdown.file_changed", { status: "changed", text: "# Back" });
    await settle();
    assert.equal(unavailable.hidden, true);
    assert.equal(doc.querySelector("#mdv-content h1").textContent, "Back");
  });

  test("unit: markdown: a missing file at startup shows File unavailable", async () => {
    await startApp({ text: null });
    assert.equal(doc.getElementById("mdv-unavailable").hidden, false);
    assert.equal(host.calls("panel.read_file").length, 1, "file_not_found is not retried");
  });

  test("unit: markdown: find bar via Ctrl+F, Enter/Shift+Enter, F3 and Escape", async () => {
    await startApp();
    const viewport = doc.getElementById("mdv-viewport");
    key(viewport, { key: "f", code: "KeyF", keyCode: 70, ctrlKey: true });
    const bar = doc.getElementById("mdv-find");
    const input = doc.getElementById("mdv-find-input");
    assert.equal(bar.hidden, false);
    input.value = "INSTALL";
    input.dispatchEvent(new window.Event("input", { bubbles: true }));
    const count = doc.getElementById("mdv-find-count");
    assert.equal(count.textContent, "1/5");
    key(input, { key: "Enter", code: "Enter", keyCode: 13 });
    assert.equal(count.textContent, "2/5");
    key(input, { key: "Enter", code: "Enter", keyCode: 13, shiftKey: true });
    key(input, { key: "Enter", code: "Enter", keyCode: 13, shiftKey: true });
    assert.equal(count.textContent, "5/5", "wraps to the end");
    key(viewport, { key: "F3", code: "F3", keyCode: 114 });
    assert.equal(count.textContent, "1/5");
    const current = doc.querySelector("mark.mdv-find-current");
    assert.ok(current);
    key(input, { key: "Escape", code: "Escape", keyCode: 27 });
    assert.equal(bar.hidden, true);
    assert.equal(doc.querySelectorAll("mark.mdv-find-match").length, 0);

    input.value = "zzz-no-match";
    app.openFind("zzz-no-match");
    assert.equal(count.textContent, "0/0");
    assert.equal(count.getAttribute("data-empty"), "true");
  });

  test("unit: markdown: global search pre-fills the find bar", async () => {
    await startApp();
    host.emit("panel.markdown.find", { query: "greeting" });
    await settle();
    assert.equal(doc.getElementById("mdv-find").hidden, false);
    assert.equal(doc.getElementById("mdv-find-input").value, "greeting");
    assert.equal(doc.getElementById("mdv-find-count").textContent, "1/1");
  });

  test("unit: markdown: zoom shortcuts and settings defaults", async () => {
    await startApp({ init: { settings: { "markdown.fontSize": 15, "markdown.maxWidth": 980 } } });
    const content = doc.getElementById("mdv-content");
    const viewport = doc.getElementById("mdv-viewport");
    const zoomIn = () => key(viewport, { key: "=", code: "Equal", keyCode: 187, ctrlKey: true });
    zoomIn();
    assert.equal(content.style.getPropertyValue("--mdv-zoom"), "1.0667");
    assert.equal(content.getAttribute("data-font-size"), "16");
    key(viewport, { key: "-", code: "Minus", keyCode: 189, ctrlKey: true });
    key(viewport, { key: "-", code: "Minus", keyCode: 189, ctrlKey: true });
    assert.equal(content.getAttribute("data-font-size"), "14");
    key(viewport, { key: "0", code: "Digit0", keyCode: 48, ctrlKey: true });
    assert.equal(content.getAttribute("data-font-size"), "15");
    assert.equal(content.style.getPropertyValue("--mdv-zoom"), "1");
    for (let i = 0; i < 100; i += 1) zoomIn();
    assert.equal(content.getAttribute("data-font-size"), "96", "clamped");

    // New defaults: the untouched max width follows, the zoomed size stays.
    host.emit("panel.markdown.settings", { "markdown.fontSize": 18, "markdown.maxWidth": 600 });
    assert.equal(content.style.getPropertyValue("--mdv-max-width"), "600px");
    assert.equal(content.getAttribute("data-font-size"), "96");
    key(viewport, { key: "0", code: "Digit0", keyCode: 48, ctrlKey: true });
    assert.equal(content.getAttribute("data-font-size"), "18", "Actual Size = the current default");

    // Palette commands arrive as panel.markdown.command.
    host.emit("panel.markdown.command", { action: "markdownZoomIn" });
    assert.equal(content.getAttribute("data-font-size"), "19");
    host.emit("panel.markdown.command", { action: "wmux.markdownTogglePreview" });
    assert.equal(doc.getElementById("mdv-editor").hidden, false);
    host.emit("panel.markdown.command", { action: "toString" });
    host.emit("panel.markdown.command", { action: "wmux.markdownTogglePreview" });
    assert.equal(doc.getElementById("mdv-content").hidden, false);
  });

  test("unit: markdown: typography popover applies, resets and saves defaults", async () => {
    await startApp({
      init: { params: { path: "a.md", font_size: 20 } },
      handlers: { "panel.markdown.list_fonts": () => ({ families: ["Georgia", "Fira Sans"] }) },
    });
    const content = doc.getElementById("mdv-content");
    assert.equal(content.getAttribute("data-font-size"), "20", "--font-size override");
    click(doc.getElementById("mdv-typography"));
    await settle();
    const popover = doc.getElementById("mdv-typography-popover");
    assert.equal(popover.hidden, false);
    const family = doc.getElementById("mdv-font-family");
    assert.deepEqual(Array.from(family.options).map((o) => o.textContent), ["System", "Fira Sans", "Georgia"]);
    family.value = "Georgia";
    family.dispatchEvent(new window.Event("change", { bubbles: true }));
    assert.match(content.style.getPropertyValue("--mdv-font-family"), /^"Georgia"/);
    const width = doc.getElementById("mdv-max-width");
    width.value = "613";
    width.dispatchEvent(new window.Event("change", { bubbles: true }));
    assert.equal(content.style.getPropertyValue("--mdv-max-width"), "620px");
    click(doc.getElementById("mdv-set-default"));
    await settle();
    assert.deepEqual(host.calls("panel.markdown.set_defaults")[0].params, {
      fontSize: 20,
      fontFamily: "Georgia",
      maxWidth: 620,
    });
    click(doc.getElementById("mdv-reset-builtin"));
    assert.equal(content.getAttribute("data-font-size"), "15");
    assert.equal(content.style.getPropertyValue("--mdv-font-family"), "");
    key(popover, { key: "Escape", code: "Escape", keyCode: 27 });
    assert.equal(popover.hidden, true);
  });

  test("unit: markdown: TextEdit mode edits, saves with Ctrl+S and refreshes the preview", async () => {
    const page = await startApp();
    click(doc.getElementById("mdv-mode"));
    const editor = doc.getElementById("mdv-editor");
    assert.equal(editor.hidden, false);
    assert.equal(doc.getElementById("mdv-content").hidden, true);
    assert.equal(doc.getElementById("mdv-mode").textContent, "Show Preview");
    assert.equal(editor.value, README);
    const save = doc.getElementById("mdv-save");
    assert.ok(save.disabled, "nothing to save yet");

    // Find is not available in TextEdit mode.
    assert.equal(app.openFind("x"), false);

    editor.value = "# Edited\n\njkl";
    editor.dispatchEvent(new window.Event("input", { bubbles: true }));
    await settle();
    assert.equal(save.disabled, false);
    assert.deepEqual(host.calls("panel.set_dirty").map((m) => m.params), [{ dirty: true }]);

    // An external change never overwrites the dirty buffer.
    host.emit("panel.markdown.file_changed", { status: "changed", text: "# Someone else" });
    await settle();
    assert.equal(editor.value, "# Edited\n\njkl");
    assert.match(doc.getElementById("mdv-status").textContent, /changed on disk/);

    // Typing j in the editor is text, not a scroll key.
    const ev = key(editor, { key: "j", code: "KeyJ", keyCode: 74 });
    assert.equal(ev.defaultPrevented, false);

    key(editor, { key: "s", code: "KeyS", keyCode: 83, ctrlKey: true });
    await settle();
    assert.deepEqual(host.calls("panel.write_file")[0].params, { text: "# Edited\n\njkl", encoding: "utf-8" });
    assert.deepEqual(host.calls("panel.set_dirty").map((m) => m.params), [{ dirty: true }, { dirty: false }]);
    assert.ok(save.disabled);

    click(doc.getElementById("mdv-mode"));
    assert.equal(doc.querySelector("#mdv-content h1").textContent, "Edited");
    void page;
  });

  test("unit: markdown: TextEdit keeps a CRLF file's line breaks and ignores them for dirty state", async () => {
    await startApp({ text: "# Title\r\n\r\nbody\r\n" });
    app.setMode("text");
    const editor = doc.getElementById("mdv-editor");

    // A browser textarea reports LF line breaks; only those differ from disk.
    editor.value = "# Title\n\nbody\n";
    editor.dispatchEvent(new window.Event("input", { bubbles: true }));
    await settle();
    assert.equal(app.state.dirty, false);

    editor.value = "# Title\n\nedited\n";
    editor.dispatchEvent(new window.Event("input", { bubbles: true }));
    await settle();
    assert.equal(app.state.dirty, true);
    await app.save();
    await settle();
    assert.deepEqual(host.calls("panel.write_file")[0].params, {
      text: "# Title\r\n\r\nedited\r\n",
      encoding: "utf-8",
    });
    assert.equal(app.state.dirty, false);
  });

  test("unit: markdown: Revert reloads the file into the editor", async () => {
    const page = await startApp();
    app.setMode("text");
    const editor = doc.getElementById("mdv-editor");
    editor.value = "scratch";
    editor.dispatchEvent(new window.Event("input", { bubbles: true }));
    page.setFile("# From disk");
    click(doc.getElementById("mdv-revert"));
    await settle();
    assert.equal(editor.value, "# From disk");
    assert.ok(doc.getElementById("mdv-save").disabled);
    assert.equal(app.state.dirty, false);
  });

  test("unit: markdown: copy toolbar and code copy buttons use panel.clipboard_write", async () => {
    await startApp();
    click(doc.getElementById("mdv-copy-md"));
    await settle();
    assert.deepEqual(host.calls("panel.clipboard_write")[0].params, { text: README });
    assert.equal(doc.getElementById("mdv-status").textContent, "Copied as Markdown");

    click(doc.getElementById("mdv-copy-html"));
    await settle();
    const htmlCall = host.calls("panel.clipboard_write")[1].params;
    assert.match(htmlCall.html, /<table>/);
    assert.match(htmlCall.html, /<h1 id="project">Project<\/h1>/);
    assert.doesNotMatch(htmlCall.html, /mdv-copy-code|Copy code/);
    assert.match(htmlCall.text, /Project/);
    assert.equal(doc.getElementById("mdv-status").textContent, "Copied as HTML");

    const button = doc.querySelector(".mdv-copy-code");
    click(button);
    await settle();
    assert.deepEqual(host.calls("panel.clipboard_write")[2].params, { text: 'let greeting = "install"\n' });
    assert.equal(button.textContent, "Copied");
  });

  test("unit: markdown: remote images load after approval and copy their URL", async () => {
    await startApp({
      text: "![badge](https://img.shields.io/b.svg)",
      handlers: { "panel.markdown.approve_remote_image": () => ({ approved: true }) },
    });
    const box = doc.querySelector(".wmux-remote-image");
    click(box.querySelector('[data-image-action="copy"]'));
    await settle();
    assert.deepEqual(host.calls("panel.clipboard_write")[0].params, { text: "https://img.shields.io/b.svg" });
    assert.equal(box.querySelector('[data-image-action="copy"]').textContent, "Copied");
    click(box.querySelector('[data-image-action="open"]'));
    await settle();
    assert.deepEqual(host.calls("panel.open_in_browser")[0].params, { url: "https://img.shields.io/b.svg" });
    click(box.querySelector('[data-image-action="load"]'));
    await settle();
    assert.deepEqual(host.calls("panel.markdown.approve_remote_image")[0].params, { url: "https://img.shields.io/b.svg" });
    const img = doc.querySelector("#mdv-content img");
    assert.equal(img.getAttribute("src"), "https://img.shields.io/b.svg");
    assert.equal(img.getAttribute("alt"), "badge");
    // A re-render keeps the approval.
    app.renderPreview(true);
    assert.equal(doc.querySelector("#mdv-content img").getAttribute("src"), "https://img.shields.io/b.svg");
  });

  test("unit: markdown: absolute local images are resolved by native", async () => {
    await startApp({
      text: "![p](C:\\pics\\p.png) ![q](/etc/q.png)",
      handlers: {
        "panel.markdown.resolve_image": ({ path }) =>
          path.startsWith("C:") ? { url: "https://d-0000000000000001.wmux.example/p.png" } : { url: "https://evil.example/q.png" },
      },
    });
    await settle();
    const [p, q] = doc.querySelectorAll("#mdv-content img");
    assert.equal(p.getAttribute("src"), "https://d-0000000000000001.wmux.example/p.png");
    assert.equal(q.hasAttribute("src"), false, "non-wmux URLs from native are ignored");
  });

  test("unit: markdown: mermaid blocks render after the page renders", async () => {
    await startApp({ text: "# D\n\n```mermaid\ngraph TD; A-->B\n```\n" });
    await settle();
    const block = doc.querySelector("#mdv-content .wmux-mermaid");
    assert.equal(block.getAttribute("data-state"), "rendered");
    assert.ok(block.querySelector(".wmux-diagram-output svg"));
  });

  test("unit: markdown: vim and emacs keys scroll the preview", async () => {
    await startApp();
    const viewport = doc.getElementById("mdv-viewport");
    fakeScroller(viewport, { height: 500, scrollHeight: 5000 });
    viewport.scrollTo = undefined; // jsdom: no smooth scrolling, assign scrollTop
    key(viewport, { key: "j", code: "KeyJ", keyCode: 74 });
    assert.equal(viewport.scrollTop, 40);
    key(viewport, { key: "d", code: "KeyD", keyCode: 68, ctrlKey: true });
    assert.equal(viewport.scrollTop, 290);
    key(viewport, { key: "k", code: "KeyK", keyCode: 75 });
    assert.equal(viewport.scrollTop, 250);
    key(viewport, { key: "p", code: "KeyP", keyCode: 80, ctrlKey: true });
    assert.equal(viewport.scrollTop, 210);
    key(viewport, { key: "G", code: "KeyG", keyCode: 71, shiftKey: true });
    assert.equal(viewport.scrollTop, 4500);
    key(viewport, { key: "g", code: "KeyG", keyCode: 71 });
    assert.equal(viewport.scrollTop, 4500, "first g of the chord waits");
    key(viewport, { key: "g", code: "KeyG", keyCode: 71 });
    assert.equal(viewport.scrollTop, 0, "g g jumps to the top");
  });

  test("unit: markdown: in-page anchors scroll without a bridge call", async () => {
    await startApp();
    const target = doc.getElementById("install");
    let scrolled = null;
    target.scrollIntoView = (opts) => {
      scrolled = opts;
    };
    const before = host.sent.length;
    await app.routeLink("#install");
    assert.equal(scrolled.block, "start");
    assert.equal(host.sent.length, before);
  });

  test("unit: markdown: restores display mode, typography and approvals from the session", async () => {
    await startApp({
      init: {
        params: { path: "a.md" },
        state: {
          v: 1,
          display_mode: "text",
          typography: { fontSize: 22, fontFamily: "Georgia", maxWidth: 700 },
          approved_images: ["https://example.com/x.png", "javascript:bad"],
        },
      },
    });
    assert.equal(doc.getElementById("mdv-editor").hidden, false);
    assert.equal(doc.getElementById("mdv-editor").value, README);
    assert.equal(doc.getElementById("mdv-content").getAttribute("data-font-size"), "22");
    assert.deepEqual(Array.from(app.state.approvedImages), ["https://example.com/x.png"]);
  });
});
