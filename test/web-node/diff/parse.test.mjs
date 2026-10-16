// Diff panel: unified diff parser and word diff (pure modules).
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { importWeb, patch } from "./harness.mjs";

const { parsePatch, unquotePath, gitHeaderPaths, parseHunkHeader, headerPath } = await importWeb("diff/parse.js");
const { wordDiff, hunkWordRanges, tokenize } = await importWeb("diff/words.js");

describe("unit: diff parse", () => {
  test("unit: diff: parses a modified file with line numbers and section", () => {
    const { files, errors } = parsePatch(
      patch(
        "diff --git a/src/a.js b/src/a.js",
        "index 1111111..2222222 100644",
        "--- a/src/a.js",
        "+++ b/src/a.js",
        "@@ -10,4 +10,5 @@ function main() {",
        " keep",
        "-old",
        "+new",
        "+added",
        " tail",
        " end",
      ),
    );
    assert.deepEqual(errors, []);
    assert.equal(files.length, 1);
    const f = files[0];
    assert.equal(f.path, "src/a.js");
    assert.equal(f.status, "modified");
    assert.equal(f.additions, 2);
    assert.equal(f.deletions, 1);
    const h = f.hunks[0];
    assert.equal(h.section, "function main() {");
    assert.deepEqual(
      h.lines.map((l) => [l.type, l.oldNo, l.newNo, l.text]),
      [
        ["context", 10, 10, "keep"],
        ["del", 11, null, "old"],
        ["add", null, 11, "new"],
        ["add", null, 12, "added"],
        ["context", 12, 13, "tail"],
        ["context", 13, 14, "end"],
      ],
    );
  });

  test("unit: diff: renames, copies, similarity and paths with spaces", () => {
    const { files } = parsePatch(
      patch(
        "diff --git a/old name.txt b/new name.txt",
        "similarity index 87%",
        "rename from old name.txt",
        "rename to new name.txt",
        "index 1..2 100644",
        "--- a/old name.txt",
        "+++ b/new name.txt",
        "@@ -1 +1 @@",
        "-a",
        "+b",
        "diff --git a/x.c b/y.c",
        "similarity index 100%",
        "copy from x.c",
        "copy to y.c",
      ),
    );
    assert.equal(files[0].status, "renamed");
    assert.equal(files[0].oldPath, "old name.txt");
    assert.equal(files[0].newPath, "new name.txt");
    assert.equal(files[0].similarity, 87);
    assert.equal(files[1].status, "copied");
    assert.equal(files[1].oldPath, "x.c");
    assert.equal(files[1].path, "y.c");
    assert.equal(files[1].hunks.length, 0);
  });

  test("unit: diff: added, deleted, binary and mode changes", () => {
    const { files } = parsePatch(
      patch(
        "diff --git a/new.txt b/new.txt",
        "new file mode 100644",
        "index 0000000..1234567",
        "--- /dev/null",
        "+++ b/new.txt",
        "@@ -0,0 +1,2 @@",
        "+one",
        "+two",
        "diff --git a/gone.txt b/gone.txt",
        "deleted file mode 100755",
        "--- a/gone.txt",
        "+++ /dev/null",
        "@@ -1 +0,0 @@",
        "-bye",
        "diff --git a/img.png b/img.png",
        "index 1..2 100644",
        "Binary files a/img.png and b/img.png differ",
        "diff --git a/run.sh b/run.sh",
        "old mode 100644",
        "new mode 100755",
        "diff --git a/lit.bin b/lit.bin",
        "new file mode 100644",
        "index 0000000..3",
        "GIT binary patch",
        "literal 5",
        "McmZQzWMXCj0000Q01Dg-",
        "",
        "literal 0",
        "HcmV?d00001",
        "",
      ),
    );
    assert.deepEqual(files.map((f) => f.status), ["added", "deleted", "modified", "modified", "added"]);
    assert.equal(files[0].newMode, "100644");
    assert.deepEqual(files[0].hunks[0].lines.map((l) => l.newNo), [1, 2]);
    assert.equal(files[1].path, "gone.txt");
    assert.equal(files[1].oldMode, "100755");
    assert.equal(files[2].binary, true);
    assert.equal(files[3].oldMode, "100644");
    assert.equal(files[3].newMode, "100755");
    assert.equal(files[4].binary, true);
    assert.equal(files[4].hunks.length, 0);
  });

  test("unit: diff: no-newline markers attach to the previous line", () => {
    const { files, errors } = parsePatch(
      patch("--- a/f", "+++ b/f", "@@ -1 +1 @@", "-a", "\\ No newline at end of file", "+a", "\\ No newline at end of file"),
    );
    assert.deepEqual(errors, []);
    const lines = files[0].hunks[0].lines;
    assert.deepEqual(lines.map((l) => [l.type, l.noNewline]), [["del", true], ["add", true]]);
  });

  test("unit: diff: combined diffs (diff --cc, @@@ hunks)", () => {
    const { files, errors } = parsePatch(
      patch("diff --cc merged.c", "index a,b..c", "--- a/merged.c", "+++ b/merged.c", "@@@ -1,3 -1,3 +1,3 @@@", "  same", "- ours", " -theirs", "++both", "  tail"),
    );
    assert.deepEqual(errors, []);
    const f = files[0];
    assert.equal(f.combined, true);
    assert.equal(f.parents, 2);
    assert.equal(f.path, "merged.c");
    assert.deepEqual(
      f.hunks[0].lines.map((l) => [l.type, l.marks, l.oldNo, l.newNo]),
      [
        ["context", "  ", 1, 1],
        ["del", "- ", 2, null],
        ["del", " -", null, null],
        ["add", "++", null, 2],
        ["context", "  ", 3, 3],
      ],
    );
    assert.equal(f.additions, 1);
    assert.equal(f.deletions, 2);
  });

  test("unit: diff: format-patch preamble and signature are ignored", () => {
    const text = patch(
      "From 0123 Mon Sep 17 00:00:00 2001",
      "Subject: [PATCH] change",
      "---",
      " a | 2 +-",
      "",
      "diff --git a/a b/a",
      "--- a/a",
      "+++ b/a",
      "@@ -1,2 +1,2 @@",
      "-x",
      "+y",
      " z",
      "-- ",
      "2.43.0",
    );
    const { files, errors } = parsePatch(text);
    assert.deepEqual(errors, []);
    assert.equal(files.length, 1);
    assert.equal(files[0].hunks[0].lines.length, 3);
    assert.ok(!files[0].raw.includes("2.43.0"));
  });

  test("unit: diff: plain diff -u files, CRLF and timestamps", () => {
    const text = "--- old/a.txt\t2024-01-01 10:00:00\r\n+++ new/a.txt\t2024-01-02 10:00:00\r\n@@ -1 +1 @@\r\n-é\r\n+ü\r\n";
    const { files } = parsePatch(text);
    assert.equal(files.length, 1);
    assert.equal(files[0].oldPath, "old/a.txt");
    assert.equal(files[0].newPath, "new/a.txt");
    assert.deepEqual(files[0].hunks[0].lines.map((l) => l.text), ["é", "ü"]);
  });

  test("unit: diff: quoted unicode paths and header helpers", () => {
    assert.equal(unquotePath('"a/\\303\\244 \\"q\\".txt"'), 'a/ä "q".txt');
    assert.equal(unquotePath("plain"), "plain");
    // core.quotePath=false: raw characters (also outside the BMP) next to escapes.
    assert.equal(unquotePath('"a/tab\\there \u{1F600} é.txt"'), "a/tab\there \u{1F600} é.txt");
    assert.deepEqual(gitHeaderPaths('"a/\u{1F4C1}\\t.md" "b/\u{1F4C1}\\t.md"'), ["\u{1F4C1}\t.md", "\u{1F4C1}\t.md"]);
    assert.deepEqual(gitHeaderPaths('"a/\\303\\244.txt" "b/\\303\\244.txt"'), ["ä.txt", "ä.txt"]);
    assert.deepEqual(gitHeaderPaths("a/x y.txt b/x y.txt"), ["x y.txt", "x y.txt"]);
    assert.equal(headerPath("/dev/null"), "/dev/null");
    assert.equal(parseHunkHeader("@@ -3 +4,0 @@").oldLines, 1);
    assert.equal(parseHunkHeader("@@ -3 +4,0 @@").newLines, 0);
    assert.equal(parseHunkHeader("@@ bogus @@"), null);
    assert.equal(parseHunkHeader("@@@ -1 +1 @@@"), null);
  });

  test("unit: diff: empty, malformed and huge input", () => {
    assert.deepEqual(parsePatch("").files, []);
    assert.deepEqual(parsePatch(null).files, []);
    assert.deepEqual(parsePatch("hello\nworld\n").files, []);
    const bad = parsePatch(patch("--- a/f", "+++ b/f", "@@ -1,3 +1,3 @@", " a", "garbage"));
    assert.equal(bad.files.length, 1);
    assert.ok(bad.errors.length >= 1);
    const trunc = parsePatch(patch("--- a/f", "+++ b/f", "@@ -1,5 +1,5 @@", " a"));
    assert.match(trunc.errors[0].message, /ended inside a hunk/);
    const mal = parsePatch(patch("diff --git a/f b/f", "@@ nope @@", "+x"));
    assert.match(mal.errors[0].message, /Malformed hunk header/);
    const big = ["diff --git a/big b/big", "--- a/big", "+++ b/big", "@@ -0,0 +1,20000 @@"];
    for (let i = 0; i < 20000; i += 1) big.push("+line " + i);
    const { files } = parsePatch(patch(big));
    assert.equal(files[0].additions, 20000);
    assert.equal(files[0].hunks[0].lines[19999].newNo, 20000);
  });

  test("unit: diff: empty context lines (stripped trailing space) count as context", () => {
    const { files, errors } = parsePatch(patch("--- a/f", "+++ b/f", "@@ -1,3 +1,3 @@", " a", "", "-b", "+c"));
    assert.deepEqual(errors, []);
    assert.deepEqual(files[0].hunks[0].lines.map((l) => l.type), ["context", "context", "del", "add"]);
  });
});

describe("unit: diff words", () => {
  test("unit: diff: word diff marks only changed tokens", () => {
    const r = wordDiff("const foo = bar(1);", "const fooBar = bar(2);");
    assert.deepEqual(r.del, [[6, 9], [16, 17]]);
    assert.deepEqual(r.add, [[6, 12], [19, 20]]);
  });

  test("unit: diff: word diff handles unicode, identical, unrelated and long lines", () => {
    const r = wordDiff("héllo wörld 😀", "héllo welt 😀");
    assert.deepEqual(r, { del: [[6, 11]], add: [[6, 10]] });
    assert.deepEqual(wordDiff("same", "same"), { del: [], add: [] });
    assert.equal(wordDiff("abc def", "xyz uvw"), null);
    assert.equal(wordDiff("a".repeat(3000), "b"), null);
    assert.deepEqual(tokenize("a1_b+😀 c"), ["a1_b", "+", "😀", " ", "c"]);
    assert.deepEqual(tokenize(""), []);
  });

  test("unit: diff: hunk word ranges pair deletions with additions in order", () => {
    const lines = [
      { type: "context", text: "x" },
      { type: "del", text: "let a = 1;" },
      { type: "del", text: "let b = 2;" },
      { type: "add", text: "let a = 10;" },
      { type: "context", text: "y" },
    ];
    const ranges = hunkWordRanges(lines);
    assert.deepEqual(ranges.get(1), [[8, 9]]);
    assert.deepEqual(ranges.get(3), [[8, 10]]);
    assert.equal(ranges.has(2), false);
  });
});
