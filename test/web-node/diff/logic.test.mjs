// Diff panel: file logic, preferences, comments, find, keymap and highlight helpers.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { doc, hljs, importWeb, libs, patch } from "./harness.mjs";

const { parsePatch } = await importWeb("diff/parse.js");
const files = await importWeb("diff/files.js");
const prefs = await importWeb("diff/prefs.js");
const comments = await importWeb("diff/comments.js");
const { searchFiles, cycle, MAX_FIND_MATCHES } = await importWeb("diff/find.js");
const { scrollTarget, stepTarget, DEFAULT_KEYMAP } = await importWeb("diff/keymap.js");
const { languageFor, highlightLines, wrapRanges, unwrapRanges } = await importWeb("diff/highlight.js");

function fileOf(path, _unused, extra = {}) {
  return { index: 0, path, oldPath: path, newPath: path, status: "modified", additions: 0, deletions: 0, raw: "", hunks: [], ...extra };
}

const SAMPLE = parsePatch(
  patch(
    "diff --git a/src/app.js b/src/app.js",
    "--- a/src/app.js",
    "+++ b/src/app.js",
    "@@ -1,4 +1,4 @@",
    " import x;",
    "-const a = 1;",
    "+const a = 2;",
    " call(a);",
    " end();",
  ),
).files[0];

describe("unit: diff files", () => {
  test("unit: diff: lockfiles and attributes defer as generated, size as large", () => {
    for (const name of files.LOCKFILES) {
      assert.equal(files.deferReason(fileOf("sub/" + name), []), "generated", name);
    }
    assert.equal(files.deferReason(fileOf("dist/out.js"), ["dist/out.js"]), "generated");
    assert.equal(files.deferReason(fileOf("a.js", null, { additions: 1999 }), []), null);
    assert.equal(files.deferReason(fileOf("a.js", null, { additions: 1500, deletions: 500 }), []), "large");
    assert.equal(files.deferReason(fileOf("a.js", null, { raw: "x".repeat(400 * 1024) }), []), "large");
    assert.equal(files.deferReason(fileOf("a.js", null, { raw: "é".repeat(200 * 1024) }), []), "large");
    assert.equal(files.deferReason(fileOf("a.js", null, { raw: "x".repeat(400 * 1024 - 1) }), []), null);
    assert.equal(files.deferReason(fileOf("package-lock.json.bak"), []), null);
  });

  test("unit: diff: tree merges single-child directories and sorts dirs first", () => {
    const list = ["src/web/diff/app.js", "src/web/diff/a.css", "README.md", "src/main.zig"].map((p, i) => fileOf(p, null, { index: i }));
    const tree = files.buildTree(list);
    assert.deepEqual(tree.dirs.map((d) => d.name), ["src"]);
    assert.deepEqual(tree.files.map((f) => f.path), ["README.md"]);
    const src = tree.dirs[0];
    assert.deepEqual(src.dirs.map((d) => d.name), ["web/diff"]);
    assert.deepEqual(files.treeOrder(tree).map((f) => f.path), ["src/web/diff/a.css", "src/web/diff/app.js", "src/main.zig", "README.md"]);
    assert.deepEqual(files.buildTree([]).files, []);
  });

  test("unit: diff: filter by path terms, status subset and viewed", () => {
    const f = fileOf("src/Web/App.js", null, { status: "renamed", oldPath: "src/old.js" });
    assert.equal(files.matchesFilter(f, { query: "web app" }), true);
    assert.equal(files.matchesFilter(f, { query: "old.js" }), true);
    assert.equal(files.matchesFilter(f, { query: "nope" }), false);
    assert.equal(files.matchesFilter(f, { statuses: ["added", "modified"] }), false);
    assert.equal(files.matchesFilter(f, { statuses: ["renamed"] }), true);
    assert.equal(files.matchesFilter(f, { hideViewed: true }, () => true), false);
    assert.equal(files.statusBucket("copied"), "added");
    assert.equal(files.filterActive({}), false);
    assert.equal(files.filterActive({ statuses: ["added"] }), true);
    assert.equal(files.filterActive({ query: "  " }), false);
  });

  test("unit: diff: fingerprints change with content only", () => {
    const a = files.fingerprint({ raw: "x", status: "modified", path: "a" });
    assert.match(a, /^fp1:[0-9a-f]{16}$/);
    assert.equal(a, files.fingerprint({ raw: "x", status: "modified", path: "a" }));
    assert.notEqual(a, files.fingerprint({ raw: "y", status: "modified", path: "a" }));
    assert.notEqual(a, files.fingerprint({ raw: "x", status: "modified", path: "b" }));
  });

  test("unit: diff: fuzzy score prefers basename and contiguous matches", () => {
    assert.equal(files.fuzzyScore("zzz", "src/app.js"), -1);
    assert.ok(files.fuzzyScore("app", "src/app.js") > files.fuzzyScore("app", "a/p/p/x.js"));
    assert.ok(files.fuzzyScore("app", "src/app.js") > files.fuzzyScore("app", "app/src/main.js"));
    assert.equal(files.fuzzyScore("", "x"), 0);
  });

  test("unit: diff: whitespace folding turns whitespace-only pairs into context", () => {
    const lines = [
      { type: "del", text: "a  b", oldNo: 1, newNo: null },
      { type: "del", text: "c", oldNo: 2, newNo: null },
      { type: "add", text: "a b", oldNo: null, newNo: 1 },
      { type: "add", text: "d", oldNo: null, newNo: 2 },
    ];
    const out = files.foldWhitespace(lines);
    assert.deepEqual(out.map((l) => [l.type, l.text, l.oldNo, l.newNo]), [
      ["context", "a b", 1, 1],
      ["del", "c", 2, null],
      ["add", "d", null, 2],
    ]);
    assert.equal(out[0].ws, true);
    assert.deepEqual(files.foldWhitespace([]), []);
  });

  test("unit: diff: context segmentation keeps N lines around changes and pinned lines", () => {
    const ctx = (n) => ({ type: "context", text: "c" + n });
    const lines = [ctx(0), ctx(1), ctx(2), ctx(3), { type: "add", text: "x" }, ctx(5), ctx(6), ctx(7), ctx(8), ctx(9)];
    const seg = files.segmentContext(lines, 1);
    assert.deepEqual(seg.map((s) => [s.kind, s.lines.length]), [["gap", 3], ["lines", 3], ["gap", 4]]);
    assert.deepEqual(files.segmentContext(lines, Infinity).map((s) => s.kind), ["lines"]);
    const pinned = files.segmentContext(lines, 0, new Set([8]));
    assert.deepEqual(pinned.map((s) => [s.kind, s.lines.length]), [["gap", 4], ["lines", 1], ["gap", 3], ["lines", 1], ["gap", 1]]);
    assert.deepEqual(files.segmentContext([], 3), []);
  });
});

describe("unit: diff prefs", () => {
  test("unit: diff: sanitize drops unknown keys and invalid values", () => {
    assert.deepEqual(
      prefs.sanitizePrefs({ layout: "split", diffIndicators: "classic", wordWrap: true, lineNumbers: "no", evil: 1, contextLines: 5 }),
      { layout: "split", diffIndicators: "classic", wordWrap: true, contextLines: 5 },
    );
    assert.deepEqual(prefs.sanitizePrefs({ layout: "SPLIT", contextLines: 1.5 }), {});
    assert.deepEqual(prefs.sanitizePrefs({ contextLines: 101 }), {});
    assert.deepEqual(prefs.sanitizePrefs(null), {});
    assert.deepEqual(prefs.sanitizePrefs([1]), {});
  });

  test("unit: diff: layout precedence: --layout > persisted > defaultLayout > unified", () => {
    assert.equal(prefs.resolvePrefs({}).layout, "unified");
    assert.equal(prefs.resolvePrefs({ settings: { "diffViewer.defaultLayout": "split" } }).layout, "split");
    assert.equal(prefs.resolvePrefs({ settings: { diffViewer: { defaultLayout: "split" } } }).layout, "split");
    assert.equal(prefs.resolvePrefs({ prefs: { layout: "unified" }, settings: { "diffViewer.defaultLayout": "split" } }).layout, "unified");
    assert.equal(prefs.resolvePrefs({ params: { layout: "split" }, prefs: { layout: "unified" } }).layout, "split");
    assert.equal(prefs.resolvePrefs({ params: { layout: "split" }, state: { prefs: { layout: "unified" } } }).layout, "unified");
    assert.equal(prefs.resolvePrefs({ prefs: { lineNumbers: false } }).lineNumbers, false);
  });

  test("unit: diff: font size defaults to 10 pt", () => {
    assert.equal(prefs.resolveFontSize({}), 10);
    assert.equal(prefs.resolveFontSize({ font_size: 14 }), 14);
    assert.equal(prefs.resolveFontSize({ font_size: 1000 }), 10);
    assert.equal(prefs.resolveFontSize(null), 10);
    assert.equal(prefs.ptToPx(12), 16);
  });
});

describe("unit: diff comments", () => {
  const NOW = new Date("2026-10-16T12:00:00.000Z");

  test("unit: diff: builds a record with submission text for one line", () => {
    const rec = comments.buildComment({ file: SAMPLE, side: "additions", startLine: 2, endLine: 2, message: "why 2?\n", now: NOW, id: "c1" });
    assert.equal(rec.id, "c1");
    assert.equal(rec.filePath, "src/app.js");
    assert.equal(rec.lineText, "const a = 2;");
    assert.equal(rec.createdAt, "2026-10-16T12:00:00.000Z");
    assert.equal(
      rec.submissionText,
      "Review comment on src/app.js line 2 (new version):\n\n```diff\n+const a = 2;\n```\n\nwhy 2?\n",
    );
  });

  test("unit: diff: range on the old side and plain excerpt fallback", () => {
    const rec = comments.buildComment({ file: SAMPLE, side: "deletions", startLine: 3, endLine: 1, message: "m", now: NOW });
    assert.equal(rec.startLine, 1);
    assert.equal(rec.endLine, 3);
    assert.match(rec.submissionText, /^Review comment on src\/app\.js lines 1-3 \(old version\):\n\n```diff\n import x;\n-const a = 1;\n call\(a\);\n```\n\nm\n$/);
    const plain = comments.submissionText({ filePath: "f", side: "additions", startLine: 4, endLine: 4, lineText: "has ``` fence", message: "x" }, null);
    assert.equal(plain, "Review comment on f line 4 (new version):\n\n````\nhas ``` fence\n````\n\nx\n");
  });

  test("unit: diff: edit keeps id, createdAt and consumedAt", () => {
    const first = comments.buildComment({ file: SAMPLE, side: "additions", startLine: 2, endLine: 2, message: "a", now: NOW, id: "c9" });
    first.consumedAt = "2026-10-16T13:00:00.000Z";
    const later = new Date("2026-10-17T00:00:00.000Z");
    const edited = comments.buildComment({ file: SAMPLE, side: "additions", startLine: 2, endLine: 2, message: "b", existing: first, now: later });
    assert.equal(edited.id, "c9");
    assert.equal(edited.createdAt, first.createdAt);
    assert.equal(edited.updatedAt, later.toISOString());
    assert.equal(edited.consumedAt, first.consumedAt);
  });

  test("unit: diff: re-anchoring: anchored, moved, outdated, absent", () => {
    const base = { id: "x", filePath: "src/app.js", side: "additions", startLine: 3, endLine: 3, lineText: "call(a);" };
    assert.equal(comments.anchorComment([SAMPLE], base).status, "anchored");
    const moved = comments.anchorComment([SAMPLE], { ...base, startLine: 1, endLine: 1 });
    assert.equal(moved.status, "moved");
    assert.equal(moved.startLine, 3);
    assert.equal(moved.delta, 2);
    assert.equal(comments.anchorComment([SAMPLE], { ...base, lineText: "gone" }).status, "outdated");
    assert.equal(comments.anchorComment([SAMPLE], { ...base, filePath: "other.js" }).status, "absent");
    assert.equal(comments.anchorComment([SAMPLE], { ...base, lineText: "" }).status, "anchored");
    const range = comments.anchorComment([SAMPLE], { ...base, startLine: 2, endLine: 3, lineText: "const a = 2;\ncall(a);" });
    assert.equal(range.status, "anchored");
  });

  test("unit: diff: normalize rejects unusable records", () => {
    assert.equal(comments.normalizeComment(null), null);
    assert.equal(comments.normalizeComment({ id: "a", filePath: "f", startLine: 0 }), null);
    assert.equal(comments.normalizeComment({ id: "a", filePath: "f", startLine: 3, endLine: 2 }), null);
    assert.equal(comments.normalizeComment({ filePath: "f", startLine: 1 }), null);
    const ok = comments.normalizeComment({ id: "a", filePath: "f", startLine: "2", side: "weird", extra: 1 });
    assert.equal(ok.side, "additions");
    assert.equal(ok.endLine, 2);
    assert.equal(ok.extra, 1);
    assert.match(comments.newCommentId(), /^[0-9a-f-]{36}$/);
    assert.match(comments.newCommentId({}), /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-a[0-9a-f]{3}-[0-9a-f]{12}$/);
  });
});

describe("unit: diff find and keys", () => {
  test("unit: diff: find matches both sides, several per line, case-insensitively", () => {
    const res = searchFiles([SAMPLE], "A", (f) => f.hunks.map((h) => h.lines));
    const sides = res.matches.map((m) => [m.side, m.lineNo, m.start]);
    assert.deepEqual(sides, [
      ["deletions", 2, 6],
      ["additions", 2, 6],
      ["additions", 3, 1],
      ["additions", 3, 5],
    ]);
    assert.equal(searchFiles([SAMPLE], "", () => []).matches.length, 0);
  });

  test("unit: diff: find caps at 9999 matches", () => {
    const lines = [{ type: "add", text: "a".repeat(20000), newNo: 1, oldNo: null }];
    const res = searchFiles([{ index: 0 }], "a", () => [lines]);
    assert.equal(res.matches.length, MAX_FIND_MATCHES);
    assert.equal(res.capped, true);
    assert.equal(cycle(-1, 3, 1), 0);
    assert.equal(cycle(-1, 3, -1), 2);
    assert.equal(cycle(2, 3, 1), 0);
    assert.equal(cycle(0, 3, -1), 2);
    assert.equal(cycle(0, 0, 1), -1);
  });

  test("unit: diff: default keymap follows the action catalog", () => {
    assert.deepEqual(DEFAULT_KEYMAP.diffViewerNextFile, ["] f"]);
    assert.deepEqual(DEFAULT_KEYMAP.diffViewerNextHunk, ["n"]);
    assert.deepEqual(DEFAULT_KEYMAP.diffViewerScrollToTop, ["g g"]);
    assert.deepEqual(DEFAULT_KEYMAP.diffViewerToggleViewed, ["v"]);
    assert.deepEqual(DEFAULT_KEYMAP.diffViewerOpenFileSearch, ["/"]);
    const view = { top: 100, height: 400, max: 1000 };
    assert.equal(scrollTarget("diffViewerScrollDown", view), 140);
    assert.equal(scrollTarget("diffViewerScrollHalfPageUp", view), 0);
    assert.equal(scrollTarget("diffViewerScrollToBottom", view), 1000);
    assert.equal(scrollTarget("other", view), null);
    assert.equal(stepTarget([0, 100, 200], 100, 1), 2);
    assert.equal(stepTarget([0, 100, 200], 100, -1), 0);
    assert.equal(stepTarget([0, 100, 200], 200, 1), -1);
  });
});

describe("unit: diff highlight", () => {
  test("unit: diff: language detection by name and extension", () => {
    assert.equal(languageFor("src/a.js", hljs), "js");
    assert.equal(languageFor("Makefile", hljs), "makefile");
    assert.equal(languageFor("x.tsx", hljs), "typescript");
    assert.equal(languageFor("noext", hljs), null);
    assert.equal(languageFor("a.unknownlang", hljs), null);
    assert.equal(languageFor("a.js", null), null);
  });

  test("unit: diff: highlighted lines keep multi-line tokens and exact text", () => {
    const texts = ["/* start", "end */ let x = '<b>';", ""];
    const frags = highlightLines({ ...libs, document: doc }, "javascript", texts);
    assert.equal(frags.length, 3);
    frags.forEach((f, i) => assert.equal(f.textContent, texts[i]));
    const div = doc.createElement("div");
    div.append(frags[1]);
    assert.ok(div.querySelector("span.hljs-comment"));
    assert.equal(div.querySelector("b"), null);
    assert.equal(highlightLines({ ...libs, document: doc }, null, texts), null);
    assert.equal(highlightLines({ ...libs, document: doc }, "javascript", ["x".repeat(200000)]), null);
  });

  test("unit: diff: wrapRanges splits across nested text nodes and unwraps", () => {
    const div = doc.createElement("div");
    div.innerHTML = "ab<span>cd</span>ef";
    const spans = wrapRanges(div, [[1, 3], [4, 6]], "hit");
    assert.equal(div.textContent, "abcdef");
    assert.deepEqual(spans.map((s) => s.textContent), ["b", "c", "ef"]);
    unwrapRanges(div, "hit");
    assert.equal(div.querySelectorAll(".hit").length, 0);
    assert.equal(div.innerHTML, "ab<span>cd</span>ef");
    assert.deepEqual(wrapRanges(div, [], "hit"), []);
  });
});
