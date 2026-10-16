/**
 * Unified diff parser (pure). Understands `git diff` / `git format-patch`
 * output (extended headers: renames, copies, mode changes, similarity, index
 * lines, binary markers, quoted paths), plain `diff -u` output, `\ No newline
 * at end of file` markers and combined diffs (`diff --cc` / `diff --combined`,
 * `@@@` hunks). Text before the first file (commit messages) and after a
 * hunk's line counts are used up (format-patch signatures) is ignored.
 *
 *   const { files, errors } = parsePatch(text);
 *
 * File: {index, oldPath, newPath, path, status, oldMode, newMode, similarity,
 *   binary, combined, parents, hunks, additions, deletions, headers, raw}
 *   status: "added" | "deleted" | "renamed" | "copied" | "modified"
 * Hunk: {header, oldStart, oldLines, newStart, newLines, section, lines}
 * Line: {type: "context" | "add" | "del", text, oldNo, newNo, noNewline,
 *   marks?} (marks = combined-diff column prefix, e.g. "+-")
 */

const DEV_NULL = "/dev/null";
const UTF8 = new TextEncoder();

/**
 * Decode a git C-quoted path ("a/\303\244.txt") into a JS string. Escapes are
 * bytes; other characters (raw UTF-8 with core.quotePath=false) are kept
 * whole, including those outside the BMP.
 */
export function unquotePath(text) {
  if (text.length < 2 || text[0] !== '"' || text[text.length - 1] !== '"') return text;
  const bytes = [];
  const body = text.slice(1, -1);
  const simple = { n: 10, t: 9, r: 13, a: 7, b: 8, f: 12, v: 11, '"': 34, "\\": 92 };
  for (let i = 0; i < body.length; i += 1) {
    const c = String.fromCodePoint(body.codePointAt(i));
    if (c.length === 2) i += 1;
    if (c === "\\" && i + 1 < body.length) {
      const n = body[i + 1];
      if (/[0-7]/.test(n)) {
        const oct = body.slice(i + 1, i + 4).match(/^[0-7]{1,3}/)[0];
        bytes.push(parseInt(oct, 8) & 0xff);
        i += oct.length;
        continue;
      }
      if (simple[n] !== undefined) {
        bytes.push(simple[n]);
        i += 1;
        continue;
      }
    }
    for (const b of UTF8.encode(c)) bytes.push(b);
  }
  return new TextDecoder("utf-8", { fatal: false }).decode(new Uint8Array(bytes));
}

/** Read one (possibly quoted) path token from `s` at `pos`: [path, nextPos]. */
function readPathToken(s, pos) {
  if (s[pos] === '"') {
    let i = pos + 1;
    while (i < s.length) {
      if (s[i] === "\\") i += 2;
      else if (s[i] === '"') break;
      else i += 1;
    }
    return [unquotePath(s.slice(pos, i + 1)), i + 1];
  }
  return [s.slice(pos), s.length];
}

function stripPrefix(p) {
  if (p === DEV_NULL) return p;
  return /^[abciow12]\//.test(p) ? p.slice(2) : p;
}

/** Path from a `--- ` / `+++ ` line (tab-separated timestamps dropped). */
export function headerPath(rest) {
  let p;
  if (rest.startsWith('"')) p = readPathToken(rest, 0)[0];
  else {
    const tab = rest.indexOf("\t");
    p = tab >= 0 ? rest.slice(0, tab) : rest.replace(/\s+$/, "");
  }
  return stripPrefix(p);
}

/**
 * Paths of a `diff --git` line. Unquoted paths with spaces are ambiguous; when
 * both sides are equal (the common case) the split in the middle is used.
 */
export function gitHeaderPaths(rest) {
  if (rest.startsWith('"')) {
    const [a, next] = readPathToken(rest, 0);
    const tail = rest.slice(next).replace(/^ /, "");
    const b = tail.startsWith('"') ? readPathToken(tail, 0)[0] : tail;
    return [stripPrefix(a), stripPrefix(b)];
  }
  const qb = rest.indexOf(' "');
  if (qb >= 0) return [stripPrefix(rest.slice(0, qb)), stripPrefix(readPathToken(rest, qb + 1)[0])];
  const half = (rest.length - 1) / 2;
  if (Number.isInteger(half) && rest[half] === " ") {
    const a = rest.slice(0, half);
    const b = rest.slice(half + 1);
    if (stripPrefix(a) === stripPrefix(b)) return [stripPrefix(a), stripPrefix(b)];
  }
  const m = rest.match(/^(\S+) (\S+)$/) || rest.match(/^(a\/.*) (b\/.*)$/);
  if (m) return [stripPrefix(m[1]), stripPrefix(m[2])];
  return [stripPrefix(rest), stripPrefix(rest)];
}

const HUNK_RE = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)$/;
const COMBINED_HUNK_RE = /^(@{3,}) (.*?) \1 ?(.*)$/;

/** Parse a hunk header; null when malformed. */
export function parseHunkHeader(line) {
  const m = line.match(HUNK_RE);
  if (m) {
    return {
      header: line,
      oldStart: Number(m[1]),
      oldLines: m[2] === undefined ? 1 : Number(m[2]),
      newStart: Number(m[3]),
      newLines: m[4] === undefined ? 1 : Number(m[4]),
      section: m[5] || "",
      parents: 1,
      parentRanges: null,
      lines: [],
    };
  }
  const c = line.match(COMBINED_HUNK_RE);
  if (!c) return null;
  const ranges = c[2].split(" ");
  const parents = c[1].length - 1;
  if (ranges.length !== parents + 1) return null;
  const parsed = [];
  for (let i = 0; i < ranges.length; i += 1) {
    const r = ranges[i].match(/^([-+])(\d+)(?:,(\d+))?$/);
    if (!r || (i < parents) !== (r[1] === "-")) return null;
    parsed.push({ start: Number(r[2]), lines: r[3] === undefined ? 1 : Number(r[3]) });
  }
  const last = parsed[parents];
  return {
    header: line,
    oldStart: parsed[0].start,
    oldLines: parsed[0].lines,
    newStart: last.start,
    newLines: last.lines,
    section: c[3] || "",
    parents,
    parentRanges: parsed.slice(0, parents),
    lines: [],
  };
}

function newFile(index, oldPath, newPath, startLine, git) {
  return {
    index,
    oldPath,
    newPath,
    path: newPath,
    status: "modified",
    oldMode: null,
    newMode: null,
    similarity: null,
    binary: false,
    combined: false,
    parents: 1,
    hunks: [],
    additions: 0,
    deletions: 0,
    headers: [],
    raw: "",
    git,
    _flags: { added: false, deleted: false, renamed: false, copied: false },
    _start: startLine,
    _end: startLine + 1,
  };
}

function finishFile(file, lines) {
  const f = file._flags;
  if (f.deleted || file.newPath === DEV_NULL) file.status = "deleted";
  else if (f.added || file.oldPath === DEV_NULL) file.status = "added";
  else if (f.renamed) file.status = "renamed";
  else if (f.copied) file.status = "copied";
  else file.status = "modified";
  if (file.status === "deleted") {
    file.path = file.oldPath;
    if (file.newPath === DEV_NULL) file.newPath = file.oldPath;
  } else {
    file.path = file.newPath;
    if (file.oldPath === DEV_NULL) file.oldPath = file.newPath;
  }
  file.raw = lines.slice(file._start, file._end).join("\n");
  delete file._flags;
  delete file._start;
  delete file._end;
  delete file.git;
  return file;
}

/** Apply one extended git header line; false when the line is not one. */
function applyExtendedHeader(file, line) {
  let m;
  if ((m = line.match(/^old mode (\d+)/))) file.oldMode = m[1];
  else if ((m = line.match(/^new mode (\d+)/))) file.newMode = m[1];
  else if ((m = line.match(/^deleted file mode (\d+)/))) {
    file.oldMode = m[1];
    file._flags.deleted = true;
  } else if ((m = line.match(/^new file mode (\d+)/))) {
    file.newMode = m[1];
    file._flags.added = true;
  } else if (line.startsWith("rename from ")) {
    file.oldPath = readPathToken(line.slice(12), 0)[0];
    file._flags.renamed = true;
  } else if (line.startsWith("rename to ")) {
    file.newPath = readPathToken(line.slice(10), 0)[0];
    file._flags.renamed = true;
  } else if (line.startsWith("copy from ")) {
    file.oldPath = readPathToken(line.slice(10), 0)[0];
    file._flags.copied = true;
  } else if (line.startsWith("copy to ")) {
    file.newPath = readPathToken(line.slice(8), 0)[0];
    file._flags.copied = true;
  } else if ((m = line.match(/^similarity index (\d+)%/))) file.similarity = Number(m[1]);
  else if (/^dissimilarity index \d+%/.test(line)) {
    // informational
  } else if ((m = line.match(/^index [0-9a-fA-F.,]+(?: (\d+))?\s*$/))) {
    if (m[1] && !file.oldMode && !file.newMode) {
      file.oldMode = m[1];
      file.newMode = m[1];
    }
  } else if (/^Binary files .* differ$/.test(line) || line === "GIT binary patch") {
    file.binary = true;
  } else return false;
  file.headers.push(line);
  return true;
}

/** Feed one line to the current hunk. Returns "consumed" | "done" | "reject". */
function feedHunkLine(file, hunk, line, counts) {
  const last = hunk.lines[hunk.lines.length - 1];
  if (line.startsWith("\\")) {
    if (last) last.noNewline = true;
    return "consumed";
  }
  if (counts.done()) return "done";
  const p = hunk.parents;
  let prefix = line.slice(0, p);
  let text = line.slice(p);
  if (line === "") {
    prefix = " ".repeat(p);
    text = "";
  }
  if (prefix.length < p || /[^ +-]/.test(prefix)) return "reject";
  const removed = prefix.includes("-");
  const inResult = !removed;
  const inParent = [];
  for (let i = 0; i < p; i += 1) inParent.push(removed ? prefix[i] === "-" : prefix[i] === " ");
  if (!counts.fits(inParent, inResult)) return "reject";
  counts.take(inParent, inResult);
  const type = removed ? "del" : prefix.includes("+") ? "add" : "context";
  const entry = {
    type,
    text,
    oldNo: inParent[0] ? counts.old++ : null,
    newNo: inResult ? counts.new++ : null,
    noNewline: false,
  };
  if (p > 1) entry.marks = prefix;
  hunk.lines.push(entry);
  if (type === "add") file.additions += 1;
  else if (type === "del") file.deletions += 1;
  return "consumed";
}

function hunkCounter(hunk) {
  const parentLeft = hunk.parentRanges ? hunk.parentRanges.map((r) => r.lines) : [hunk.oldLines];
  let newLeft = hunk.newLines;
  return {
    old: hunk.oldStart,
    new: hunk.newStart,
    done: () => newLeft <= 0 && parentLeft.every((n) => n <= 0),
    fits(inParent, inResult) {
      if (inResult && newLeft <= 0) return false;
      return inParent.every((x, i) => !x || parentLeft[i] > 0);
    },
    take(inParent, inResult) {
      if (inResult) newLeft -= 1;
      inParent.forEach((x, i) => {
        if (x) parentLeft[i] -= 1;
      });
    },
  };
}

/**
 * Parse patch text.
 * @param {string} text
 * @returns {{files: object[], errors: {line: number, message: string}[]}}
 */
export function parsePatch(text) {
  const src = typeof text === "string" ? text : "";
  const lines = src.split(/\r?\n/);
  if (lines.length && lines[lines.length - 1] === "") lines.pop();
  const files = [];
  const errors = [];
  let file = null;
  let hunk = null;
  let counts = null;
  let skippingBinary = false;

  const close = () => {
    if (file) {
      file.index = files.length;
      files.push(finishFile(file, lines));
    }
    file = null;
    hunk = null;
    counts = null;
    skippingBinary = false;
  };
  const start = (f) => {
    close();
    file = f;
  };

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (hunk) {
      const r = feedHunkLine(file, hunk, line, counts);
      if (r === "consumed") {
        file._end = i + 1;
        continue;
      }
      if (r === "reject") {
        errors.push({ line: i + 1, message: "Hunk ended before its line counts were reached" });
      }
      hunk = null;
      counts = null;
    }
    if (line.startsWith("diff --git ")) {
      const [a, b] = gitHeaderPaths(line.slice(11));
      start(newFile(files.length, a, b, i, true));
      continue;
    }
    const cc = line.match(/^diff --(?:cc|combined) (.*)$/);
    if (cc) {
      const p = readPathToken(cc[1], 0)[0];
      start(newFile(files.length, p, p, i, true));
      file.combined = true;
      continue;
    }
    const plainStart =
      line.startsWith("--- ") &&
      i + 1 < lines.length &&
      lines[i + 1].startsWith("+++ ") &&
      (!file || file.hunks.length > 0 || file.binary);
    if (plainStart) {
      start(newFile(files.length, headerPath(line.slice(4)), headerPath(lines[i + 1].slice(4)), i, false));
    }
    if (!file) continue;
    if (skippingBinary) {
      file._end = i + 1;
      continue;
    }
    if (line.startsWith("--- ") && i + 1 < lines.length && lines[i + 1].startsWith("+++ ")) {
      const a = headerPath(line.slice(4));
      const b = headerPath(lines[i + 1].slice(4));
      if (a === DEV_NULL) file._flags.added = true;
      if (b === DEV_NULL) file._flags.deleted = true;
      if (!file.combined) {
        if (a !== DEV_NULL || !file._flags.renamed) file.oldPath = a === DEV_NULL ? file.oldPath : a;
        if (b !== DEV_NULL) file.newPath = b;
      }
      i += 1;
      file._end = i + 1;
      continue;
    }
    if (line.startsWith("@@")) {
      const h = parseHunkHeader(line);
      if (!h) {
        errors.push({ line: i + 1, message: "Malformed hunk header" });
        continue;
      }
      if (h.parents > 1) {
        file.combined = true;
        file.parents = h.parents;
      }
      file.hunks.push(h);
      hunk = h;
      counts = hunkCounter(h);
      file._end = i + 1;
      continue;
    }
    if (file.hunks.length === 0 && applyExtendedHeader(file, line)) {
      if (line === "GIT binary patch") skippingBinary = true;
      file._end = i + 1;
    }
  }
  if (hunk && counts && !counts.done()) {
    errors.push({ line: lines.length, message: "Patch ended inside a hunk" });
  }
  close();
  for (const f of files) {
    for (const h of f.hunks) {
      delete h.parentRanges;
    }
  }
  return { files, errors };
}
