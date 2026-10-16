/**
 * Task Manager model (pure): normalizes `system.top` / `system.memory`
 * replies into one tree (windows > workspaces > tags / panes > surfaces >
 * processes and browser webviews), derives the Coding Agents, Program Totals
 * and Child Process RSS sections, sorts siblings, flattens the tree for
 * rendering and formats CPU / memory / time. No DOM, no bridge.
 *
 * Field names follow the `cmux top` TSV columns (`cpu_percent`,
 * `memory_bytes`, `process_count`) and its tree node kinds; unknown fields
 * are ignored and missing numbers read as 0.
 */

/** Child arrays and the node kind each holds, in display order. */
const CHILD_KEYS = Object.freeze([
  ["workspaces", "workspace"],
  ["tags", "tag"],
  ["panes", "pane"],
  ["surfaces", "surface"],
  ["webviews", "webview"],
  ["processes", "process"],
  ["children", null],
]);

export const KINDS = Object.freeze(["window", "workspace", "tag", "pane", "surface", "webview", "process"]);
const KIND_SET = new Set(KINDS);
/** Kinds whose id (UUID) or ref is unique across the whole reply. */
const GLOBAL_ID_KINDS = new Set(["window", "workspace", "pane", "surface"]);

/** Known coding agents by executable base name (lowercase, no `.exe`). */
export const KNOWN_AGENTS = Object.freeze({
  claude: "Claude Code",
  "claude-code": "Claude Code",
  codex: "Codex",
  opencode: "OpenCode",
  gemini: "Gemini CLI",
});

/** Sort keys accepted by `sortTree` (the `cmux top --sort` set). */
export const SORT_KEYS = Object.freeze(["name", "cpu", "mem", "proc"]);

function num(v) {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" ? Number(v) : NaN;
  return Number.isFinite(n) && n >= 0 ? n : 0;
}

function str(v) {
  return typeof v === "string" ? v : typeof v === "number" && Number.isFinite(v) ? String(v) : "";
}

function pidOf(raw) {
  const n = typeof raw.pid === "number" ? raw.pid : typeof raw.pid === "string" ? Number(raw.pid) : NaN;
  return Number.isInteger(n) && n > 0 ? n : null;
}

/** `C:\x\Claude.EXE` -> `claude`. */
export function exeKey(name) {
  const base = str(name).split(/[\\/]/).pop() || "";
  return base.replace(/\.exe$/i, "").toLowerCase();
}

/**
 * Display name of a known agent id or executable key, or "". Own keys only:
 * process names are arbitrary, and `constructor` or `__proto__` would
 * otherwise read inherited Object members.
 */
function knownAgent(key) {
  return Object.prototype.hasOwnProperty.call(KNOWN_AGENTS, key) ? KNOWN_AGENTS[key] : "";
}

/**
 * Display name of the coding agent a process is, or "": an explicit `agent`
 * field from native (id or display name) wins over the executable name.
 */
export function agentName(raw) {
  if (!raw || typeof raw !== "object") return "";
  const agent = str(raw.agent);
  if (agent) return knownAgent(agent.toLowerCase()) || agent;
  return knownAgent(exeKey(raw.name));
}

function idFor(kind, raw) {
  return str(raw[`${kind}_id`]) || str(raw.id);
}

/** `C:\x\pwsh.exe` -> `pwsh.exe`. */
function baseName(name) {
  return str(name).split(/[\\/]/).pop() || "";
}

/**
 * Normalize one raw node. `kind` comes from the array holding it; `owner`
 * carries the ids of the enclosing window / workspace / pane / surface and
 * `parentKey` the key of the enclosing node.
 */
function normalizeNode(raw, kind, owner, path, parentKey) {
  if (!raw || typeof raw !== "object") return null;
  const k = KIND_SET.has(raw.kind) ? raw.kind : kind || "process";
  const node = {
    kind: k,
    id: k === "process" ? "" : idFor(k, raw),
    ref: str(raw.ref),
    title: str(raw.title) || (k === "process" ? "" : str(raw.name)),
    name: k === "process" ? str(raw.name) || str(raw.command) : "",
    pid: k === "process" || k === "tag" || k === "webview" ? pidOf(raw) : null,
    type: str(raw.type) || str(raw.surface_type),
    attribution: str(raw.attribution),
    agent: k === "process" ? agentName(raw) : "",
    tagKey: str(raw.key),
    tagValue: str(raw.value),
    tty: str(raw.tty),
    flags: {
      // The key (active) window; on tags `key` is the tag name instead.
      key: k === "window" && raw.key === true,
      hidden: raw.hidden === true,
      selected: raw.selected === true,
      pinned: raw.pinned === true,
      focused: raw.focused === true,
      pidOnly: raw.pid_only === true,
    },
    cpu: num(raw.cpu_percent),
    mem: num(raw.memory_bytes),
    proc: num(raw.process_count),
    owner: { ...owner },
    key: "",
    children: [],
  };
  if (k !== "process" && k !== "webview" && k !== "tag" && node.id) node.owner[`${k}_id`] = node.id;
  // Windows, workspaces, panes and surfaces are keyed by their id or ref.
  // Processes, tags and webviews are known by PID, and one PID can show up in
  // several places (a status tag and the terminal running it, webviews sharing
  // the WebView2 browser process), so their keys are scoped to the parent.
  const ident = node.id || node.pid || node.ref || path;
  node.key =
    GLOBAL_ID_KINDS.has(k) && (node.id || node.ref)
      ? `${k}:${ident}`
      : `${parentKey ? `${parentKey}/` : ""}${k}:${ident}`;
  for (const [field, childKind] of CHILD_KEYS) {
    const list = raw[field];
    if (!Array.isArray(list)) continue;
    const ck = childKind || (k === "process" ? "process" : null);
    list.forEach((child, i) => {
      const n = normalizeNode(child, ck, node.owner, `${path}/${field}.${i}`, node.key);
      if (n) node.children.push(n);
    });
  }
  if (k === "process" && node.proc === 0) node.proc = 1 + countDescendants(node);
  return node;
}

function countDescendants(node) {
  let n = 0;
  for (const c of node.children) if (c.kind === "process") n += 1 + countDescendants(c);
  return n;
}

/**
 * `system.top` result -> `{windows, totals}`; null when it is not one.
 * `totals` falls back to the sum over windows when native omits it.
 */
export function normalizeTop(result) {
  if (!result || typeof result !== "object" || !Array.isArray(result.windows)) return null;
  const windows = [];
  result.windows.forEach((w, i) => {
    const n = normalizeNode(w, "window", {}, `w${i}`, "");
    if (n) windows.push(n);
  });
  // Rows, selection, focus and collapsed state are looked up by key: make
  // every key unique (a repeated PID under one parent, a repeated id).
  const used = new Set();
  walk(windows, (n) => {
    let key = n.key;
    for (let i = 2; used.has(key); i += 1) key = `${n.key}#${i}`;
    used.add(key);
    n.key = key;
  });
  const t = result.totals && typeof result.totals === "object" ? result.totals : null;
  const totals = t
    ? { cpu: num(t.cpu_percent), mem: num(t.memory_bytes), proc: num(t.process_count) }
    : windows.reduce((acc, w) => ({ cpu: acc.cpu + w.cpu, mem: acc.mem + w.mem, proc: acc.proc + w.proc }), {
        cpu: 0,
        mem: 0,
        proc: 0,
      });
  return { windows, totals };
}

/** Depth-first visit of every node; `fn(node, parents)`. */
export function walk(nodes, fn, parents = []) {
  for (const n of nodes) {
    fn(n, parents);
    walk(n.children, fn, parents.concat(n));
  }
}

/** True when the tree has at least one workspace (else "No resource usage"). */
export function hasUsage(top) {
  let found = false;
  if (top) walk(top.windows, (n) => (found = found || n.kind === "workspace"));
  return found;
}

/** The workspace node enclosing a node (from the parents chain). */
function workspaceTitle(parents) {
  const ws = parents.filter((p) => p.kind === "workspace").pop();
  return ws ? ws.title || ws.ref : "";
}

/** Every process once (first occurrence per PID) with its owner and parents. */
export function uniqueProcesses(top) {
  const seen = new Map();
  if (!top) return [];
  walk(top.windows, (n, parents) => {
    if (n.kind !== "process" || n.pid === null || seen.has(n.pid)) return;
    seen.set(n.pid, { node: n, workspace: workspaceTitle(parents) });
  });
  return Array.from(seen.values());
}

/** Unique PIDs of a process node and its process descendants. */
export function subtreePids(node) {
  const out = [];
  const visit = (n) => {
    if (n.kind === "process" && n.pid !== null && !out.includes(n.pid)) out.push(n.pid);
    for (const c of n.children) visit(c);
  };
  visit(node);
  return out;
}

/** Sum of own CPU / memory over a process node and its descendants (unique PIDs). */
function subtreeUsage(node) {
  const seen = new Set();
  const acc = { cpu: 0, mem: 0, proc: 0 };
  const visit = (n) => {
    if (n.kind === "process" && n.pid !== null && !seen.has(n.pid)) {
      seen.add(n.pid);
      acc.cpu += n.cpu;
      acc.mem += n.mem;
      acc.proc += 1;
    }
    for (const c of n.children) visit(c);
  };
  visit(node);
  return acc;
}

/**
 * Coding Agents rows: the outermost process of each agent (an agent's own
 * helper children are counted in its row), with usage over its subtree.
 */
export function codingAgents(top) {
  if (!top) return [];
  const byPid = new Map();
  walk(top.windows, (n, parents) => {
    if (n.kind !== "process" || !n.agent || n.pid === null) return;
    if (parents.some((p) => p.kind === "process" && p.agent)) return;
    // One agent can be listed under its status tag (walked first) and under
    // the terminal running it; keep the copy that knows its surface, so the
    // row can jump to that terminal.
    const prev = byPid.get(n.pid);
    if (prev && (prev.node.owner.surface_id || !n.owner.surface_id)) return;
    byPid.set(n.pid, { node: n, parents });
  });
  return Array.from(byPid.values(), ({ node: n, parents }) => ({
    kind: "agent",
    key: `agent:${n.pid}`,
    title: n.agent,
    detail: workspaceTitle(parents),
    pid: n.pid,
    pids: subtreePids(n),
    owner: { ...n.owner },
    ...subtreeUsage(n),
  }));
}

/** Program Totals rows: unique processes grouped by executable name. */
export function programTotals(top) {
  const groups = new Map();
  for (const { node } of uniqueProcesses(top)) {
    const k = exeKey(node.name) || `pid ${node.pid}`;
    let g = groups.get(k);
    if (!g) {
      g = {
        kind: "program",
        key: `program:${k}`,
        title: node.name.split(/[\\/]/).pop() || k,
        cpu: 0,
        mem: 0,
        proc: 0,
        pids: [],
        owner: {},
      };
      groups.set(k, g);
    }
    g.cpu += node.cpu;
    g.mem += node.mem;
    g.proc += 1;
    g.pids.push(node.pid);
  }
  return Array.from(groups.values());
}

/**
 * `system.memory` result -> `{app, child, groups}`; tolerant of the field
 * spellings below, null when it is not an object.
 *   app:   app.memory_bytes | app_memory_bytes | app_footprint_bytes
 *   child: child.memory_bytes | child_rss_bytes | children.memory_bytes (else the group sum)
 *   groups[]: {command|name, memory_bytes|rss_bytes, process_count|count, workspaces|labels}
 */
export function normalizeMemory(result) {
  if (!result || typeof result !== "object") return null;
  const pick = (...vals) => {
    for (const v of vals)
      if (typeof v === "number" || (typeof v === "string" && v.trim() !== "")) return num(v);
    return null;
  };
  const sub = (o) => (o && typeof o === "object" ? o : {});
  const groups = [];
  const rawGroups = Array.isArray(result.groups) ? result.groups : [];
  rawGroups.forEach((g, i) => {
    if (!g || typeof g !== "object") return;
    const title = str(g.command) || str(g.name);
    if (!title) return;
    const labels = Array.isArray(g.workspaces) ? g.workspaces : Array.isArray(g.labels) ? g.labels : [];
    groups.push({
      kind: "group",
      key: `group:${i}:${title}`,
      title,
      detail: labels
        .map((l) => (l && typeof l === "object" ? str(l.title) || str(l.label) || str(l.ref) : str(l)))
        .filter(Boolean)
        .join(", "),
      cpu: null,
      mem: pick(g.memory_bytes, g.rss_bytes) || 0,
      proc: pick(g.process_count, g.count) || 0,
      owner: {},
    });
  });
  const app = pick(sub(result.app).memory_bytes, result.app_memory_bytes, result.app_footprint_bytes);
  let child = pick(sub(result.child).memory_bytes, result.child_rss_bytes, sub(result.children).memory_bytes);
  if (child === null && groups.length) child = groups.reduce((s, g) => s + g.mem, 0);
  return { app, child, groups };
}

/** Name used for sorting by name: what the row shows. */
export function sortName(node) {
  if (node.kind === "tag") return `${node.tagKey} ${node.tagValue}`;
  if (node.kind === "process") return baseName(node.name);
  return node.title || node.name || node.ref || "";
}

function compare(a, b, key) {
  if (key === "name")
    return sortName(a).localeCompare(sortName(b), undefined, { numeric: true, sensitivity: "base" });
  const field = key === "mem" ? "mem" : key === "proc" ? "proc" : "cpu";
  return (a[field] || 0) - (b[field] || 0);
}

/** Default direction of a sort key: names ascend, numbers descend. */
export function defaultDirection(key) {
  return key === "name" ? "asc" : "desc";
}

/** A copy of flat `rows` sorted by `key` (`null` keeps the order); stable. */
export function sortRows(rows, key, dir) {
  if (!SORT_KEYS.includes(key)) return rows.slice();
  const sign = dir === "asc" ? 1 : -1;
  return rows.slice().sort((a, b) => sign * compare(a, b, key));
}

/** A copy of the tree with every sibling list sorted (cmux `--sort`). */
export function sortTree(nodes, key, dir) {
  return sortRows(nodes, key, dir).map((n) => ({ ...n, children: sortTree(n.children, key, dir) }));
}

/**
 * Visible rows of the tree: `{node, depth, expandable, expanded}`. Nodes whose
 * key is in `collapsed` hide their children; `showProcesses = false` drops
 * process rows (and their subtrees).
 */
export function flatten(nodes, collapsed, showProcesses, depth = 0, out = []) {
  for (const node of nodes) {
    if (!showProcesses && node.kind === "process") continue;
    const kids = showProcesses ? node.children : node.children.filter((c) => c.kind !== "process");
    const expandable = kids.length > 0;
    const expanded = expandable && !collapsed.has(node.key);
    out.push({ node, depth, expandable, expanded });
    if (expanded) flatten(kids, collapsed, showProcesses, depth + 1, out);
  }
  return out;
}

/**
 * PIDs "Kill Process…" targets for a row: a process (and its descendants are
 * left to native's tree kill) -> its PID; a tag -> its PID; a surface, pane or
 * workspace -> the top-level processes under it; agent / program rows -> their
 * PIDs. Webviews and windows are never killed from here.
 */
export function killPids(row) {
  if (!row) return [];
  if (row.kind === "agent") return [row.pid];
  if (row.kind === "program") return row.pids.slice();
  if (row.kind === "process" || row.kind === "tag") return row.pid === null ? [] : [row.pid];
  if (row.kind === "surface" || row.kind === "pane" || row.kind === "workspace") {
    const out = [];
    const visit = (n) => {
      for (const c of n.children) {
        if (c.kind === "process") {
          if (c.pid !== null && !out.includes(c.pid)) out.push(c.pid);
        } else if (c.kind !== "webview") visit(c);
      }
    };
    visit(row);
    return out;
  }
  return [];
}

/** `cmux top`: cpu as `%.1f%%`; null -> "". */
export function formatCpu(p) {
  if (p === null || p === undefined) return "";
  return `${num(p).toFixed(1)}%`;
}

const UNITS = ["B", "KB", "MB", "GB", "TB", "PB"];

/** `v` as shown in `unit`: whole bytes, one decimal below 100, whole numbers above. */
function roundForUnit(v, unit) {
  return unit === 0 || v >= 99.95 ? Math.round(v) : Math.round(v * 10) / 10;
}

/** Human-readable bytes, 1024-based: `512 B`, `12.5 MB`, `345 MB`, `1.2 GB`. */
export function formatBytes(n) {
  if (n === null || n === undefined) return "";
  let v = num(n);
  let u = 0;
  while (v >= 1024 && u < UNITS.length - 1) {
    v /= 1024;
    u += 1;
  }
  // Rounding can reach the next unit (1023.97 KB): show 1.0 MB, not 1024 KB.
  let shown = roundForUnit(v, u);
  if (shown >= 1024 && u < UNITS.length - 1) {
    v /= 1024;
    u += 1;
    shown = roundForUnit(v, u);
  }
  if (u === 0) return `${shown} B`;
  return `${shown >= 100 ? shown : shown.toFixed(1)} ${UNITS[u]}`;
}

/** `HH:MM:SS` (24 h, local time). */
export function formatTime(date) {
  if (!(date instanceof Date) || Number.isNaN(date.getTime())) return "";
  const p = (x) => String(x).padStart(2, "0");
  return `${p(date.getHours())}:${p(date.getMinutes())}:${p(date.getSeconds())}`;
}
