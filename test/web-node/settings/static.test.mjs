// Static checks over src/web/settings: CSP, no HTML sinks or remote URLs,
// string keys defined, bridge methods documented in README.md.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { importWeb, web } from "./helpers.mjs";

const dir = path.join(web, "settings");
const files = readdirSync(dir).sort();
const read = (f) => readFileSync(path.join(dir, f), "utf8");
const js = files.filter((f) => f.endsWith(".js"));
const html = read("index.html");
const readme = read("README.md");
const { STRINGS } = await importWeb("settings/strings.js");
const { SECTION_IDS } = await importWeb("settings/sections.js");
const { CATEGORIES } = await importWeb("settings/shortcuts.js");
const { SOURCES } = await importWeb("settings/effective.js");

describe("unit: settings-panel: static checks", () => {
  test("unit: settings-panel: the page has the strict CSP first and no inline code or styles", () => {
    const head = html.slice(html.indexOf("<head>"), html.indexOf("</head>"));
    const metas = head.match(/<meta[^>]*>/g);
    assert.match(metas[0], /charset="utf-8"/);
    assert.match(metas[1], /http-equiv="Content-Security-Policy"/);
    const csp = /content="([^"]+)"/.exec(metas[1])[1];
    for (const d of [
      "default-src 'self'",
      "script-src 'self'",
      "object-src 'none'",
      "base-uri 'none'",
      "form-action 'none'",
      "trusted-types 'none'",
    ]) {
      assert.ok(csp.includes(d), d);
    }
    assert.ok(!/unsafe-inline|unsafe-eval|https?:/.test(csp));
    assert.ok(!/<script(?![^>]*type="module" src=)/.test(html), "only module scripts with src");
    assert.ok(!/<style|\sstyle=|\son[a-z]+=/i.test(html), "no inline styles or handlers");
    assert.match(html, /<link rel="icon" href="data:,">/);
  });

  test("unit: settings-panel: sources use no HTML sinks, eval or remote URLs", () => {
    for (const f of js) {
      const src = read(f);
      assert.ok(!/\.innerHTML|\.outerHTML|insertAdjacentHTML|document\.write|\beval\(|new Function\(/.test(src), f);
      assert.ok(!/https?:\/\/(?!json-schema\.org|[a-z0-9-]+\.wmux\.example\/)/.test(src), `${f}: no remote URLs`);
      assert.ok(!/\bfetch\(|XMLHttpRequest|WebSocket/.test(src), `${f}: no network APIs`);
    }
  });

  test("unit: settings-panel: every string key used is defined", () => {
    const used = new Set();
    for (const f of [...js, "index.html"]) {
      for (const m of read(f).matchAll(/["'`](settings\.[A-Za-z0-9_.]+)["'`]/g)) used.add(m[1]);
      for (const m of read(f).matchAll(/data-i18n(?:-attr)?="([^"]+)"/g)) {
        for (const part of m[1].split(";")) used.add(part.includes(":") ? part.split(":")[1].trim() : part.trim());
      }
    }
    for (const id of SECTION_IDS) used.add(`settings.section.${id}`);
    for (const c of CATEGORIES) used.add(`settings.shortcuts.category.${c}`);
    for (const s of SOURCES) used.add(`settings.source.${s}`);
    const methodLike = /^settings\.(open|schema|get_effective|set|unset|js|css|md)$/;
    const missing = [...used].filter((k) => !methodLike.test(k) && !Object.prototype.hasOwnProperty.call(STRINGS, k));
    assert.deepEqual(missing, []);
  });

  test("unit: settings-panel: every bridge method and event used is documented in README.md", () => {
    const names = new Set();
    for (const f of js) {
      for (const m of read(f).matchAll(/["'`]((?:wmux\.(?:settings|shortcuts)|panel)\.[a-z_]+)["'`]/g)) names.add(m[1]);
    }
    assert.ok(names.size >= 15, `found ${names.size}`);
    const undocumented = [...names].filter((n) => !readme.includes(`\`${n}\``));
    assert.deepEqual(undocumented, []);
  });
});
