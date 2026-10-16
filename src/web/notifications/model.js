/**
 * Notifications panel model (pure, no DOM): record normalization mirroring the
 * native store (features/notifications/logic/store.zig: id, workspace,
 * surface, title, subtitle, body, created_at_ms, read, agent), workspace
 * grouping, unread counts, the copy text and time formatting.
 */

/** Records kept by the page at most (native history cap is 500). */
export const MAX_RECORDS = 1000;
/** Characters of a body kept for display (native keeps it uncapped). */
export const MAX_TEXT = 8192;

function str(v) {
  if (typeof v === "string") return v;
  if (typeof v === "number" && Number.isFinite(v)) return String(v);
  return "";
}

function clip(s, max) {
  if (s.length <= max) return s;
  // Do not split a surrogate pair.
  let end = max;
  const code = s.charCodeAt(end - 1);
  if (code >= 0xd800 && code <= 0xdbff) end -= 1;
  return s.slice(0, end);
}

function firstString(obj, keys) {
  for (const k of keys) {
    const v = obj[k];
    if (typeof v === "string" && v !== "") return v;
  }
  return "";
}

/**
 * Milliseconds since the epoch from `created_at_ms` (ms), `created_at` or
 * `timestamp` (seconds when below 1e11, else ms; ISO strings parsed).
 */
export function timeOf(raw) {
  if (Number.isFinite(raw.created_at_ms)) return Math.trunc(raw.created_at_ms);
  for (const key of ["created_at", "timestamp", "time"]) {
    const v = raw[key];
    if (typeof v === "number" && Number.isFinite(v)) return Math.trunc(v < 1e11 ? v * 1000 : v);
    if (typeof v === "string" && v !== "") {
      const n = Number(v);
      if (Number.isFinite(n)) return Math.trunc(n < 1e11 ? n * 1000 : n);
      const parsed = Date.parse(v);
      if (Number.isFinite(parsed)) return parsed;
    }
  }
  return 0;
}

/**
 * One record in the page's shape, or null when it has no id. Accepts the
 * native field names and the cmux-style `*_id` / `is_read` spellings.
 */
export function normalizeRecord(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const id = firstString(raw, ["id", "notification_id"]);
  if (!id) return null;
  const read = typeof raw.read === "boolean" ? raw.read : typeof raw.is_read === "boolean" ? raw.is_read : false;
  const agent = raw.agent && typeof raw.agent === "object" ? raw.agent : null;
  return {
    id,
    workspace: firstString(raw, ["workspace", "workspace_id"]),
    surface: firstString(raw, ["surface", "surface_id"]) || null,
    title: clip(str(raw.title), MAX_TEXT),
    subtitle: clip(str(raw.subtitle), MAX_TEXT),
    body: clip(str(raw.body), MAX_TEXT),
    created_at_ms: timeOf(raw),
    read,
    agent: agent ? { kind: str(agent.kind), category: str(agent.category) } : null,
    workspace_title: str(raw.workspace_title || raw.workspace_name),
    surface_title: str(raw.surface_title || raw.surface_name || raw.tab_title),
  };
}

/** Records array from a `notification.list` result or snapshot payload. */
export function recordsFrom(result) {
  let list = [];
  if (Array.isArray(result)) list = result;
  else if (result && typeof result === "object") {
    list = Array.isArray(result.notifications) ? result.notifications : Array.isArray(result.records) ? result.records : [];
  }
  const seen = new Set();
  const out = [];
  for (const raw of list) {
    const r = normalizeRecord(raw);
    if (!r || seen.has(r.id)) continue;
    seen.add(r.id);
    out.push(r);
    if (out.length >= MAX_RECORDS) break;
  }
  return sortRecords(out);
}

/** Newest first; ties keep their input order (the store's order). */
export function sortRecords(records) {
  return records
    .map((r, i) => [r, i])
    .sort((a, b) => b[0].created_at_ms - a[0].created_at_ms || a[1] - b[1])
    .map((pair) => pair[0]);
}

/** Workspace-marker count (manual/restored marks without records). */
export function markerCountFrom(result) {
  if (!result || typeof result !== "object" || Array.isArray(result)) return 0;
  for (const key of ["marker_count", "markers"]) {
    const v = result[key];
    if (Number.isInteger(v) && v > 0) return v;
    if (Array.isArray(v)) return v.length;
  }
  return 0;
}

/** Map workspace id -> {title, index} from a `workspace.list` result. */
export function workspaceTitlesFrom(result) {
  const map = new Map();
  const list = Array.isArray(result) ? result : result && Array.isArray(result.workspaces) ? result.workspaces : [];
  list.forEach((w, index) => {
    if (!w || typeof w !== "object") return;
    const id = firstString(w, ["id", "workspace_id"]);
    if (!id) return;
    map.set(id.toUpperCase(), { title: firstString(w, ["title", "name"]), index });
  });
  return map;
}

/** Live workspace title for a record ("" when unknown). */
export function workspaceTitle(record, titles) {
  const live = titles && record.workspace ? titles.get(record.workspace.toUpperCase()) : null;
  if (live && live.title) return live.title;
  return record.workspace_title || "";
}

export function unreadCount(records) {
  let n = 0;
  for (const r of records) if (!r.read) n += 1;
  return n;
}

/**
 * Records grouped by workspace. Groups are ordered by their newest record
 * (newest first, so the group order follows the flat list); records stay
 * newest first inside a group.
 * @returns {{workspace: string, title: string, unread: number, records: object[]}[]}
 */
export function groupRecords(records, titles) {
  const groups = new Map();
  for (const r of records) {
    const key = r.workspace ? r.workspace.toUpperCase() : "";
    let g = groups.get(key);
    if (!g) {
      g = { workspace: r.workspace, title: workspaceTitle(r, titles), unread: 0, records: [] };
      groups.set(key, g);
    }
    if (!g.title) g.title = workspaceTitle(r, titles);
    g.records.push(r);
    if (!r.read) g.unread += 1;
  }
  return Array.from(groups.values());
}

/**
 * Row lines per the popover: line 1 = workspace title (or the record title
 * when no workspace title), line 2 = the record title when line 1 is the
 * workspace, then the detail (body, or subtitle when the body is empty).
 */
export function rowLines(record, titles) {
  const ws = workspaceTitle(record, titles).trim();
  const title = record.title.trim();
  const detail = (record.body.trim() || record.subtitle.trim());
  if (ws) return { primary: ws, secondary: title, detail };
  return { primary: title, secondary: "", detail };
}

/**
 * Clipboard text (notifications-copy): workspace title line (if known), title
 * line, detail line (body, or subtitle when the body is empty); each trimmed,
 * empty lines omitted, the detail omitted when equal to the title; joined
 * with "\n".
 */
export function copyText(record, titles) {
  const ws = workspaceTitle(record, titles).trim();
  const title = record.title.trim();
  const body = record.body.trim();
  const detail = body !== "" ? body : record.subtitle.trim();
  const lines = [];
  if (ws) lines.push(ws);
  if (title) lines.push(title);
  if (detail && detail !== title) lines.push(detail);
  return lines.join("\n");
}

/**
 * Body state: "list" when there are records, "markers" when only workspace
 * markers exist, else "empty".
 */
export function bodyState(records, markerCount) {
  if (records.length > 0) return "list";
  return markerCount > 0 ? "markers" : "empty";
}

function sameDay(a, b) {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

/**
 * Short time: the time of day for today, else a short date. `locale`
 * undefined uses the user's locale.
 */
export function formatShortTime(ms, nowMs, locale) {
  if (!Number.isFinite(ms) || ms <= 0) return "";
  const d = new Date(ms);
  const now = new Date(Number.isFinite(nowMs) ? nowMs : Date.now());
  try {
    if (sameDay(d, now)) {
      return new Intl.DateTimeFormat(locale, { hour: "numeric", minute: "2-digit" }).format(d);
    }
    const opts = d.getFullYear() === now.getFullYear() ? { month: "short", day: "numeric" } : { dateStyle: "short" };
    return new Intl.DateTimeFormat(locale, opts).format(d);
  } catch {
    return d.toISOString().slice(0, 16).replace("T", " ");
  }
}

/** Full timestamp for tooltips. */
export function formatFullTime(ms, locale) {
  if (!Number.isFinite(ms) || ms <= 0) return "";
  try {
    return new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" }).format(new Date(ms));
  } catch {
    return new Date(ms).toISOString();
  }
}

/** Event names (cmux.event frames) that change the record list. */
export function isRecordEvent(name) {
  return typeof name === "string" && (name.startsWith("notification.") || name === "wmux.notification.unread_count.changed" || name === "wmux.attention.changed");
}

/**
 * Workspace events that change titles or order. Frequent ones that do not
 * (`workspace.selected`, `workspace.prompt.submitted` on every agent prompt,
 * `workspace.action`) would only cost a `workspace.list` and a re-render.
 */
const WORKSPACE_TITLE_EVENTS = new Set(["workspace.created", "workspace.closed", "workspace.moved", "workspace.renamed", "workspace.reordered"]);

/** Event names that change workspace titles or order. */
export function isWorkspaceEvent(name) {
  return WORKSPACE_TITLE_EVENTS.has(name);
}

/** Event name of a `cmux.event` frame (`name`, or `event` when it is a string). */
export function frameName(frame) {
  if (!frame || typeof frame !== "object") return "";
  if (typeof frame.name === "string") return frame.name;
  if (typeof frame.event === "string") return frame.event;
  if (frame.event && typeof frame.event === "object" && typeof frame.event.name === "string") return frame.event.name;
  return "";
}

const KEY_NAMES = {
  ctrl: "Ctrl",
  shift: "Shift",
  alt: "Alt",
  win: "Win",
  enter: "Enter",
  escape: "Esc",
  space: "Space",
  tab: "Tab",
  backspace: "Backspace",
  delete: "Del",
};

/** Display text of a canonical binding ("ctrl+shift+u" -> "Ctrl+Shift+U"). */
export function shortcutLabel(binding) {
  if (typeof binding !== "string" || binding.trim() === "") return "";
  return binding
    .trim()
    .split(/\s+/)
    .map((stroke) =>
      stroke
        .split(/\+(?!$)/)
        .map((part) => KEY_NAMES[part] || (part.length === 1 ? part.toUpperCase() : part.charAt(0).toUpperCase() + part.slice(1)))
        .join("+"),
    )
    .join(" ");
}
