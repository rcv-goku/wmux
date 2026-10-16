// Diff panel: page shell rules (CSP, no inline code, strings) and the entry module.
import { test, describe, after } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { doc, host, importWeb, indexHtml, settle, web, window } from "./harness.mjs";

const { STRINGS } = await importWeb("diff/strings.js");

after(() => window.close());

describe("unit: diff page", () => {
  test("unit: diff: CSP meta comes first and denies by default", () => {
    const head = doc.head;
    const metas = Array.from(head.querySelectorAll('meta[http-equiv="Content-Security-Policy"]'));
    assert.equal(metas.length, 1);
    assert.equal(head.firstElementChild.getAttribute("charset"), "utf-8");
    assert.equal(head.children[1], metas[0]);
    const csp = metas[0].getAttribute("content");
    for (const part of ["default-src 'self'", "script-src 'self'", "style-src 'self'", "object-src 'none'", "base-uri 'none'", "form-action 'none'", "connect-src 'self' https://*.wmux.example"]) {
      assert.ok(csp.includes(part), part);
    }
    assert.ok(!csp.includes("unsafe"));
  });

  test("unit: diff: no inline scripts, styles or handlers in the shell", () => {
    assert.equal(doc.querySelectorAll("script:not([src]), style, [style]").length, 0);
    for (const el of doc.querySelectorAll("*")) {
      for (const attr of el.attributes) assert.ok(!/^on/i.test(attr.name), `${el.tagName} ${attr.name}`);
    }
    assert.ok(!/<script>/.test(indexHtml));
  });

  test("unit: diff: every data-i18n key has an English default", () => {
    const keys = new Set();
    for (const el of doc.querySelectorAll("[data-i18n]")) keys.add(el.getAttribute("data-i18n"));
    for (const el of doc.querySelectorAll("[data-i18n-attr]")) {
      for (const pair of el.getAttribute("data-i18n-attr").split(";")) keys.add(pair.split(":")[1].trim());
    }
    for (const k of keys) assert.ok(Object.prototype.hasOwnProperty.call(STRINGS, k), k);
  });

  test("unit: diff: sources never assign innerHTML or use eval", () => {
    const dir = path.join(web, "diff");
    for (const name of readdirSync(dir).filter((n) => n.endsWith(".js"))) {
      const src = readFileSync(path.join(dir, name), "utf8");
      assert.ok(!/\.innerHTML\s*=|outerHTML\s*=|insertAdjacentHTML|document\.write|\beval\(|new Function/.test(src), name);
    }
  });

  test("unit: diff: entry module boots the app against the bridge", async () => {
    host.reset();
    host.handlers.set("panel.ready", () => ({}));
    host.handlers.set("panel.diff.load", () => ({ patch: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n" }));
    await importWeb("diff/diff.js");
    await settle(4);
    host.emit("panel.init", { kind: "diff", surface_id: "s", params: {}, state: null, theme: null, keymap: {}, settings: {} });
    await settle(20);
    assert.equal(host.calls("panel.ready").length, 1);
    assert.equal(doc.querySelectorAll(".dv-file").length, 1);
  });
});
