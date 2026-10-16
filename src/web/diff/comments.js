/**
 * Review comments (pure): the record schema, the text delivered to an agent
 * (`submissionText`) and re-anchoring of saved comments on a regenerated diff.
 *
 * Record (cmux schema): {id, filePath, side: "additions" | "deletions",
 *   startLine, endLine, endSide?, lineText, message, submissionText,
 *   consumedAt?, createdAt, updatedAt}. Lines are 1-based numbers on the
 * side's version (additions = new version, deletions = old version);
 * timestamps are ISO 8601 strings.
 */

export const SIDES = Object.freeze(["additions", "deletions"]);
/** Longest accepted message (characters). */
export const MAX_MESSAGE_CHARS = 65536;

/** Line number of a parsed line on a side, or null when absent there. */
export function lineNoOn(line, side) {
  return side === "deletions" ? line.oldNo : line.newNo;
}

/** Map line number -> parsed line for one side of a file. */
export function sideLines(file, side) {
  const map = new Map();
  if (!file) return map;
  for (const h of file.hunks) {
    for (const l of h.lines) {
      if (side === "deletions" ? l.type === "add" : l.type === "del") continue;
      const no = lineNoOn(l, side);
      if (no !== null && no !== undefined) map.set(no, l);
    }
  }
  return map;
}

/** Text of lines start..end on a side, joined with "\n" (missing lines are ""). */
export function rangeText(file, side, start, end) {
  const map = sideLines(file, side);
  const out = [];
  for (let n = start; n <= end; n += 1) out.push(map.has(n) ? map.get(n).text : "");
  return out.join("\n");
}

/** Diff-style excerpt ("+x", "-y", " z") of a range, or null when not in the diff. */
export function diffExcerpt(file, side, start, end) {
  const map = sideLines(file, side);
  const out = [];
  for (let n = start; n <= end; n += 1) {
    const l = map.get(n);
    if (!l) return null;
    out.push((l.type === "add" ? "+" : l.type === "del" ? "-" : " ") + l.text);
  }
  return out.length ? out.join("\n") : null;
}

function fence(body) {
  const runs = body.match(/`{3,}/g) || [];
  const longest = runs.reduce((n, r) => Math.max(n, r.length), 2);
  return "`".repeat(longest + 1);
}

/**
 * Text appended to an agent prompt for a comment:
 *   Review comment on <filePath> line N|lines A-B (new|old version):
 *   <blank>
 *   ```diff excerpt (or a plain ``` excerpt of lineText)
 *   <blank>
 *   message
 */
export function submissionText(c, excerpt) {
  const lines = c.startLine === c.endLine ? `line ${c.startLine}` : `lines ${c.startLine}-${c.endLine}`;
  const version = c.side === "deletions" ? "old" : "new";
  let block;
  if (typeof excerpt === "string" && excerpt !== "") {
    const f = fence(excerpt);
    block = f + "diff\n" + excerpt + "\n" + f;
  } else {
    const body = String(c.lineText || "");
    const f = fence(body);
    block = f + "\n" + body + "\n" + f;
  }
  const message = String(c.message || "").replace(/\s+$/, "");
  return `Review comment on ${c.filePath} ${lines} (${version} version):\n\n${block}\n\n${message}\n`;
}

/** A random comment id (UUID v4 when crypto is available). */
export function newCommentId(cryptoImpl) {
  const c = cryptoImpl || globalThis.crypto;
  if (c && typeof c.randomUUID === "function") return c.randomUUID();
  const hex = () => Math.floor(Math.random() * 0x10000).toString(16).padStart(4, "0");
  return `${hex()}${hex()}-${hex()}-4${hex().slice(1)}-a${hex().slice(1)}-${hex()}${hex()}${hex()}`;
}

/**
 * Build a new or edited record.
 * @param {{file: object, side: string, startLine: number, endLine: number,
 *   message: string, existing?: object, now?: Date, id?: string}} o
 */
export function buildComment(o) {
  const side = SIDES.includes(o.side) ? o.side : "additions";
  const start = Math.min(o.startLine, o.endLine);
  const end = Math.max(o.startLine, o.endLine);
  const now = (o.now || new Date()).toISOString();
  const prev = o.existing || null;
  const rec = {
    id: prev ? prev.id : o.id || newCommentId(),
    filePath: o.file.path,
    side,
    startLine: start,
    endLine: end,
    lineText: rangeText(o.file, side, start, end),
    message: String(o.message || "").slice(0, MAX_MESSAGE_CHARS),
    submissionText: "",
    createdAt: prev && prev.createdAt ? prev.createdAt : now,
    updatedAt: now,
  };
  if (prev && prev.endSide) rec.endSide = prev.endSide;
  if (prev && prev.consumedAt) rec.consumedAt = prev.consumedAt;
  rec.submissionText = submissionText(rec, diffExcerpt(o.file, side, start, end));
  return rec;
}

/** Validate a record from native; null when unusable. */
export function normalizeComment(raw) {
  if (!raw || typeof raw !== "object") return null;
  const id = typeof raw.id === "string" && raw.id ? raw.id : null;
  const start = Number(raw.startLine);
  const end = raw.endLine === undefined ? start : Number(raw.endLine);
  if (!id || typeof raw.filePath !== "string" || !raw.filePath) return null;
  if (!Number.isInteger(start) || !Number.isInteger(end) || start < 1 || end < start) return null;
  return {
    ...raw,
    id,
    side: SIDES.includes(raw.side) ? raw.side : "additions",
    startLine: start,
    endLine: end,
    lineText: typeof raw.lineText === "string" ? raw.lineText : "",
    message: typeof raw.message === "string" ? raw.message : "",
  };
}

/** Parsed file a comment belongs to (deletions also match a renamed file's old path). */
export function fileForComment(files, c) {
  return (
    files.find((f) => f.path === c.filePath) ||
    (c.side === "deletions" ? files.find((f) => f.oldPath === c.filePath) : undefined) ||
    null
  );
}

function matchesAt(map, start, expected) {
  for (let k = 0; k < expected.length; k += 1) {
    const l = map.get(start + k);
    if (!l || l.text !== expected[k]) return false;
  }
  return true;
}

/**
 * Re-anchor a saved comment on the current diff.
 * status: "anchored" (same lines, same text), "moved" (same text found at
 * another position; `delta` = new - old start), "outdated" (text no longer
 * found) or "absent" (the file is not part of this diff).
 * @returns {{status: string, file: object|null, startLine: number, endLine: number, delta: number}}
 */
export function anchorComment(files, c) {
  const file = fileForComment(files, c);
  const base = { file, startLine: c.startLine, endLine: c.endLine, delta: 0 };
  if (!file) return { ...base, status: "absent" };
  const map = sideLines(file, c.side);
  const len = c.endLine - c.startLine + 1;
  // Records without lineText cannot be verified: they stay where they are.
  if (!c.lineText) return { ...base, status: map.has(c.startLine) ? "anchored" : "outdated" };
  const expected = String(c.lineText).split("\n");
  if (expected.length !== len) {
    return { ...base, status: map.has(c.startLine) && map.has(c.endLine) ? "anchored" : "outdated" };
  }
  if (matchesAt(map, c.startLine, expected)) return { ...base, status: "anchored" };
  let best = null;
  for (const n of map.keys()) {
    if (!matchesAt(map, n, expected)) continue;
    if (best === null || Math.abs(n - c.startLine) < Math.abs(best - c.startLine)) best = n;
  }
  if (best === null) return { ...base, status: "outdated" };
  return { file, startLine: best, endLine: best + len - 1, delta: best - c.startLine, status: "moved" };
}

/** Sort for the Comments section: file path, then side line, then creation. */
export function compareComments(a, b) {
  if (a.filePath !== b.filePath) return a.filePath < b.filePath ? -1 : 1;
  if (a.startLine !== b.startLine) return a.startLine - b.startLine;
  return String(a.createdAt || "").localeCompare(String(b.createdAt || ""));
}

/** Comments not yet delivered to an agent. */
export function pendingComments(list) {
  return list.filter((c) => !c.consumedAt);
}
