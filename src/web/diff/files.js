/**
 * File-level diff logic (pure): deferral of generated and large files, totals,
 * the changed-files tree, the file filter, content fingerprints for "Viewed",
 * and the display transforms for context lines and whitespace.
 */

/** Well-known lockfiles, deferred as "Generated file" (basename match). */
export const LOCKFILES = Object.freeze([
  "bun.lock",
  "bun.lockb",
  "package-lock.json",
  "yarn.lock",
  "pnpm-lock.yaml",
  "Cargo.lock",
  "Package.resolved",
  "go.sum",
  "Gemfile.lock",
  "poetry.lock",
  "uv.lock",
]);

/** A file with at least this many changed lines is deferred as "Large diff". */
export const LARGE_CHANGED_LINES = 2000;
/** A file with at least this much patch text (bytes, UTF-8) is deferred as "Large diff". */
export const LARGE_PATCH_BYTES = 400 * 1024;

export function basename(p) {
  const s = String(p || "");
  const i = Math.max(s.lastIndexOf("/"), s.lastIndexOf("\\"));
  return i >= 0 ? s.slice(i + 1) : s;
}

export function utf8Length(text) {
  let n = 0;
  for (let i = 0; i < text.length; i += 1) {
    const c = text.charCodeAt(i);
    if (c < 0x80) n += 1;
    else if (c < 0x800) n += 2;
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length) {
      n += 4;
      i += 1;
    } else n += 3;
  }
  return n;
}

/**
 * Why a file renders collapsed until "Load diff": "generated", "large" or null.
 * @param {object} file parsed file
 * @param {Set<string>|string[]} [generated] paths native marked as
 *   linguist-generated or -diff (from .gitattributes)
 */
export function deferReason(file, generated) {
  const set = generated instanceof Set ? generated : new Set(Array.isArray(generated) ? generated : []);
  if (set.has(file.path) || set.has(file.oldPath) || LOCKFILES.includes(basename(file.path))) return "generated";
  if (file.additions + file.deletions >= LARGE_CHANGED_LINES) return "large";
  if (utf8Length(file.raw || "") >= LARGE_PATCH_BYTES) return "large";
  return null;
}

/** Sum of additions and deletions. */
export function totals(files) {
  let additions = 0;
  let deletions = 0;
  for (const f of files) {
    additions += f.additions;
    deletions += f.deletions;
  }
  return { additions, deletions, files: files.length };
}

/** Filter status bucket: "added" | "modified" | "deleted" | "renamed". */
export function statusBucket(status) {
  if (status === "copied") return "added";
  if (status === "added" || status === "deleted" || status === "renamed") return status;
  return "modified";
}

export const STATUS_LETTERS = Object.freeze({ added: "A", modified: "M", deleted: "D", renamed: "R", copied: "C" });

/**
 * Changed-files tree. Directories with a single child directory are merged
 * ("src/web"). Children: directories first, then files, by name.
 * @returns {{name: string, path: string, dirs: object[], files: object[]}}
 */
export function buildTree(files) {
  const root = { name: "", path: "", dirs: [], files: [], _dirs: new Map() };
  for (const f of files) {
    const parts = String(f.path).split("/").filter((p) => p !== "");
    let node = root;
    for (let i = 0; i < parts.length - 1; i += 1) {
      let next = node._dirs.get(parts[i]);
      if (!next) {
        next = { name: parts[i], path: node.path ? node.path + "/" + parts[i] : parts[i], dirs: [], files: [], _dirs: new Map() };
        node._dirs.set(parts[i], next);
        node.dirs.push(next);
      }
      node = next;
    }
    node.files.push(f);
  }
  const byName = (a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
  const finish = (node) => {
    delete node._dirs;
    node.dirs.sort(byName);
    node.files.sort((a, b) => byName({ name: basename(a.path) }, { name: basename(b.path) }));
    node.dirs = node.dirs.map((d) => {
      finish(d);
      let cur = d;
      while (cur.files.length === 0 && cur.dirs.length === 1) {
        const only = cur.dirs[0];
        cur = { ...only, name: cur.name + "/" + only.name };
      }
      return cur;
    });
  };
  finish(root);
  return root;
}

/** Files in tree order (what the file list shows top to bottom). */
export function treeOrder(tree) {
  const out = [];
  const walk = (n) => {
    for (const d of n.dirs) walk(d);
    for (const f of n.files) out.push(f);
  };
  walk(tree);
  return out;
}

export const ALL_STATUSES = Object.freeze(["added", "modified", "deleted", "renamed"]);

/** Normalized filter: {query, statuses: Set, hideViewed}. */
export function normalizeFilter(raw) {
  const r = raw && typeof raw === "object" ? raw : {};
  const list = Array.isArray(r.statuses) || r.statuses instanceof Set ? Array.from(r.statuses) : ALL_STATUSES;
  return {
    query: typeof r.query === "string" ? r.query.trim() : "",
    statuses: new Set(list.filter((s) => ALL_STATUSES.includes(s))),
    hideViewed: r.hideViewed === true,
  };
}

/** Whether the filter differs from "show everything". */
export function filterActive(filter) {
  const f = normalizeFilter(filter);
  return f.query !== "" || f.hideViewed || f.statuses.size !== ALL_STATUSES.length;
}

/**
 * Whether a file passes the filter. The query is a case-insensitive substring
 * of the path (or old path); several space-separated terms must all match.
 * @param {(file: object) => boolean} isViewed
 */
export function matchesFilter(file, filter, isViewed) {
  const f = normalizeFilter(filter);
  if (!f.statuses.has(statusBucket(file.status))) return false;
  if (f.hideViewed && isViewed && isViewed(file)) return false;
  if (!f.query) return true;
  const hay = (file.path + "\n" + (file.oldPath || "")).toLowerCase();
  return f.query
    .toLowerCase()
    .split(/\s+/)
    .every((term) => hay.includes(term));
}

/** Content fingerprint of a file's patch text ("fp1:" + 16 hex digits). */
export function fingerprint(file) {
  const s = String(file.raw || "") + "\n" + file.status + "\n" + file.path;
  let h1 = 0x811c9dc5;
  let h2 = 0x9747b28c;
  for (let i = 0; i < s.length; i += 1) {
    const c = s.charCodeAt(i);
    h1 = Math.imul(h1 ^ c, 0x01000193);
    h2 = Math.imul(h2 ^ c, 0x5bd1e995);
    h2 ^= h2 >>> 15;
  }
  h1 ^= s.length;
  const hex = (n) => (n >>> 0).toString(16).padStart(8, "0");
  return "fp1:" + hex(h1) + hex(h2);
}

/**
 * Fuzzy score of `query` against a path for the file search ("Jump to file"):
 * higher is better, -1 = no match. Characters must appear in order; matches in
 * the basename, at word starts and in runs score higher.
 */
export function fuzzyScore(query, path) {
  const q = String(query).toLowerCase().replace(/\s+/g, "");
  const p = String(path);
  const lower = p.toLowerCase();
  if (!q) return 0;
  const baseStart = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\")) + 1;
  let score = 0;
  let pos = 0;
  let prev = -2;
  for (const ch of q) {
    const at = lower.indexOf(ch, pos);
    if (at < 0) return -1;
    score += 1;
    if (at === prev + 1) score += 3;
    if (at === 0 || "/\\._- ".includes(p[at - 1]) || (p[at] !== lower[at] && p[at - 1] === lower[at - 1])) score += 2;
    if (at >= baseStart) score += 2;
    prev = at;
    pos = at + 1;
  }
  if (lower.slice(baseStart).includes(q)) score += 10;
  return score - p.length / 1000;
}

function normalizeSpace(text) {
  return text.replace(/\s+/g, " ").trim();
}

/**
 * "Ignore whitespace": inside each change block, a deleted line and its paired
 * added line that differ only in whitespace become one context line (the new
 * text, flagged `ws: true`). Returns a new line array.
 */
export function foldWhitespace(lines) {
  const out = [];
  let i = 0;
  while (i < lines.length) {
    if (lines[i].type === "context") {
      out.push(lines[i++]);
      continue;
    }
    const dels = [];
    const adds = [];
    while (i < lines.length && lines[i].type === "del") dels.push(lines[i++]);
    while (i < lines.length && lines[i].type === "add") adds.push(lines[i++]);
    const pendingDel = [];
    const pendingAdd = [];
    const flush = () => {
      out.push(...pendingDel.splice(0), ...pendingAdd.splice(0));
    };
    const pairs = Math.min(dels.length, adds.length);
    for (let k = 0; k < pairs; k += 1) {
      if (normalizeSpace(dels[k].text) === normalizeSpace(adds[k].text)) {
        flush();
        out.push({ ...adds[k], type: "context", oldNo: dels[k].oldNo, ws: true });
      } else {
        pendingDel.push(dels[k]);
        pendingAdd.push(adds[k]);
      }
    }
    pendingDel.push(...dels.slice(pairs));
    pendingAdd.push(...adds.slice(pairs));
    flush();
  }
  return out;
}

/**
 * Split hunk lines into visible runs and collapsible gaps of unchanged lines,
 * keeping `context` lines around every change and every pinned line index
 * (lines that carry comments or the current find match).
 * @returns {({kind: "lines", lines: object[]} | {kind: "gap", lines: object[]})[]}
 */
export function segmentContext(lines, context, pinned) {
  const n = Number.isFinite(context) ? Math.max(0, Math.floor(context)) : Infinity;
  if (n === Infinity) return lines.length ? [{ kind: "lines", lines: lines.slice() }] : [];
  const keep = new Array(lines.length).fill(false);
  lines.forEach((l, i) => {
    if (l.type === "context" && !(pinned && pinned.has(i))) return;
    for (let k = Math.max(0, i - n); k <= Math.min(lines.length - 1, i + n); k += 1) keep[k] = true;
  });
  const out = [];
  for (let i = 0; i < lines.length; i += 1) {
    const kind = keep[i] ? "lines" : "gap";
    const last = out[out.length - 1];
    if (last && last.kind === kind) last.lines.push(lines[i]);
    else out.push({ kind, lines: [lines[i]] });
  }
  return out;
}
