/**
 * Intra-line word highlights (pure). A change block (deleted lines followed by
 * added lines) pairs its lines in order; each pair is diffed on word tokens
 * and the changed character ranges are returned per side.
 */

/** Lines longer than this are not word-diffed. */
export const MAX_WORD_DIFF_CHARS = 2000;
/** Upper bound for the token LCS table (rows x columns). */
export const MAX_WORD_DIFF_CELLS = 250000;

const TOKEN_RE = /[\p{L}\p{N}_]+|\s+|[\uD800-\uDBFF][\uDC00-\uDFFF]|[^]/gu;

/** Split a line into word, whitespace and single-symbol tokens. */
export function tokenize(text) {
  return String(text).match(TOKEN_RE) || [];
}

function mergeRanges(ranges) {
  const out = [];
  for (const r of ranges) {
    const last = out[out.length - 1];
    if (last && r[0] <= last[1]) last[1] = Math.max(last[1], r[1]);
    else out.push([r[0], r[1]]);
  }
  return out;
}

/**
 * Changed ranges between two lines: {del: [[start, end]], add: [[start, end]]}
 * as UTF-16 offsets, or null when the lines are too long or share too little
 * to make word highlights useful (the whole line is already marked).
 */
export function wordDiff(oldText, newText) {
  const a = String(oldText);
  const b = String(newText);
  if (a === b) return { del: [], add: [] };
  if (a.length > MAX_WORD_DIFF_CHARS || b.length > MAX_WORD_DIFF_CHARS) return null;
  let ta = tokenize(a);
  let tb = tokenize(b);
  // Trim the common prefix and suffix first: keeps the table small.
  let pre = 0;
  while (pre < ta.length && pre < tb.length && ta[pre] === tb[pre]) pre += 1;
  let suf = 0;
  while (suf < ta.length - pre && suf < tb.length - pre && ta[ta.length - 1 - suf] === tb[tb.length - 1 - suf]) {
    suf += 1;
  }
  const offA = ta.slice(0, pre).join("").length;
  const offB = tb.slice(0, pre).join("").length;
  ta = ta.slice(pre, ta.length - suf);
  tb = tb.slice(pre, tb.length - suf);
  const n = ta.length;
  const m = tb.length;
  if ((n + 1) * (m + 1) > MAX_WORD_DIFF_CELLS) return null;

  // LCS lengths, suffix form: L[i][j] = LCS of ta[i..] and tb[j..].
  const w = m + 1;
  const L = new Uint32Array((n + 1) * w);
  for (let i = n - 1; i >= 0; i -= 1) {
    for (let j = m - 1; j >= 0; j -= 1) {
      L[i * w + j] = ta[i] === tb[j] ? L[(i + 1) * w + j + 1] + 1 : Math.max(L[(i + 1) * w + j], L[i * w + j + 1]);
    }
  }
  const del = [];
  const add = [];
  let i = 0;
  let j = 0;
  let pa = offA;
  let pb = offB;
  let common = 0;
  while (i < n || j < m) {
    if (i < n && j < m && ta[i] === tb[j]) {
      common += ta[i].trim() ? ta[i].length : 0;
      pa += ta[i++].length;
      pb += tb[j++].length;
    } else if (j < m && (i >= n || L[i * w + j + 1] >= L[(i + 1) * w + j])) {
      add.push([pb, pb + tb[j].length]);
      pb += tb[j++].length;
    } else {
      del.push([pa, pa + ta[i].length]);
      pa += ta[i++].length;
    }
  }
  common += (a.slice(0, offA) + a.slice(pa)).replace(/\s+/g, "").length;
  const longest = Math.max(a.replace(/\s+/g, "").length, b.replace(/\s+/g, "").length);
  if (longest > 0 && common / longest < 0.25) return null;
  return { del: mergeRanges(del), add: mergeRanges(add) };
}

/**
 * Word ranges for every line of a hunk: Map(lineIndex -> [[start, end]]).
 * Only del/add lines that pair up inside one change block get ranges.
 * @param {{type: string, text: string}[]} lines
 */
export function hunkWordRanges(lines) {
  const out = new Map();
  let i = 0;
  while (i < lines.length) {
    if (lines[i].type !== "del") {
      i += 1;
      continue;
    }
    const dels = [];
    while (i < lines.length && lines[i].type === "del") dels.push(i++);
    const adds = [];
    while (i < lines.length && lines[i].type === "add") adds.push(i++);
    const pairs = Math.min(dels.length, adds.length);
    for (let k = 0; k < pairs; k += 1) {
      const r = wordDiff(lines[dels[k]].text, lines[adds[k]].text);
      if (!r) continue;
      if (r.del.length) out.set(dels[k], r.del);
      if (r.add.length) out.set(adds[k], r.add);
    }
  }
  return out;
}
