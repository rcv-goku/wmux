// Smoke: diff viewer (src/web/diff) under its real CSP. Reply shapes follow
// src/web/diff/README.md (panel.diff.load -> {patch, title?}).
import { run, assertTrue } from "../lib/assert.js";
import { defineSmokeSuite } from "../lib/harness.js";

const PATCH = [
  "diff --git a/src/app.js b/src/app.js",
  "index 1111111..2222222 100644",
  "--- a/src/app.js",
  "+++ b/src/app.js",
  "@@ -1,3 +1,3 @@",
  " import x from './x.js';",
  "-const answer = 41;",
  "+const answer = 42;",
  " x(answer);",
  "",
].join("\n");

defineSmokeSuite({
  app: "diff",
  init: { params: { title: "Working tree" } },
  responses: {
    "viewedFiles.list": { files: [] },
    "comments.list": { comments: [] },
    "panel.diff.load": { patch: PATCH, title: "Unstaged changes" },
    "panel.set_title": null,
    "panel.state_changed": null,
    "viewerPrefs.set": null,
  },
  mainSelector: "#dv-files",
  contentSelector: "#dv-files .dv-file",
  contentText: "const answer = 42;",
  errorSelectors: ['#dv-message[data-kind="error"]', '#dv-status[data-kind="error"]'],
  extra(page) {
    assertTrue(page.$$("#dv-files .dv-file").length === 1, "one file section");
    assertTrue(page.$("#dv-tree .dv-tree-file") !== null, "file tree entry");
  },
});

run({ suite: "diff" });
