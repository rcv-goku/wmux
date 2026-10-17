// Smoke: markdown viewer (src/web/markdown) under its real CSP. Reply shapes
// follow src/web/markdown/README.md (panel.read_file -> {text, encoding, base_url}).
import { run, assertTrue } from "../lib/assert.js";
import { defineSmokeSuite } from "../lib/harness.js";

const TEXT = [
  "# Project",
  "",
  "Hello **world**, with `code` and a [link](https://example.org/).",
  "",
  "- [x] done",
  "- [ ] todo",
  "",
  "| a | b |",
  "|---|---|",
  "| 1 | 2 |",
  "",
  "```js",
  "const answer = 42;",
  "```",
  "",
].join("\n");

defineSmokeSuite({
  app: "markdown",
  init: { params: { path: "C:\\work\\proj\\README.md", display_path: "C:\\work\\proj\\README.md" } },
  responses: {
    "panel.read_file": { text: TEXT, encoding: "utf-8", base_url: "https://f-0123456789abcdef.wmux.example/" },
    "panel.watch_file": {},
    "panel.set_title": null,
    "panel.state_changed": null,
  },
  mainSelector: "#mdv-content",
  contentSelector: "#mdv-content h1",
  contentText: "Project",
  errorSelectors: ["#mdv-unavailable", '#mdv-status[data-kind="error"]'],
  extra(page) {
    assertTrue(page.$("#mdv-content table td") !== null, "GFM table rendered");
    assertTrue(page.$("#mdv-content pre code") !== null, "code block rendered");
    assertTrue(page.$("#mdv-content script") === null, "no script element in the rendered markdown");
  },
});

run({ suite: "markdown" });
