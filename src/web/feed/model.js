/**
 * Feed panel model (pure, no DOM): item normalization mirroring the native
 * `feed.list` encoding (features/feed/logic/query.zig writeListItem), the
 * Actionable/Resolved partition, workstreams, decision-mode labels and
 * badges, todo summaries, banner text and relative time.
 */

/** Items kept by the page at most (one feed.list page is <= 2000). */
export const MAX_ITEMS = 2000;
/** Page size of feed.list calls. */
export const PAGE_LIMIT = 200;

export const DECISION_KINDS = Object.freeze(["permissionRequest", "exitPlan", "question"]);
export const KINDS = Object.freeze([
  "permissionRequest",
  "exitPlan",
  "question",
  "stop",
  "todos",
  "notification",
  "message",
  "prompt",
  "toolUse",
  "toolResult",
  "sessionStart",
  "sessionEnd",
]);

/** Upper-case card labels (model.zig Kind.label). */
export const KIND_LABELS = Object.freeze({
  permissionRequest: "PERMISSION",
  exitPlan: "PLAN",
  question: "QUESTION",
  stop: "STOP",
  todos: "TODOS",
  notification: "NOTIFICATION",
  message: "MESSAGE",
  prompt: "PROMPT",
  toolUse: "TOOL USE",
  toolResult: "TOOL RESULT",
  sessionStart: "SESSION START",
  sessionEnd: "SESSION END",
});

/** feed.permission.reply modes in button order. */
export const PERMISSION_MODES = Object.freeze(["once", "always", "all", "bypass", "deny"]);
/** feed.exit_plan.reply modes in button order. */
export const EXIT_PLAN_MODES = Object.freeze(["ultraplan", "manual", "autoAccept", "bypassPermissions", "deny"]);

const PERMISSION_BADGES = { once: "once", always: "always", all: "all tools", bypass: "bypass", deny: "denied" };
const EXIT_PLAN_BADGES = { ultraplan: "ultraplan", bypassPermissions: "bypass", autoAccept: "auto", manual: "manual", deny: "denied" };

const SOURCE_NAMES = {
  claude: "Claude",
  codex: "Codex",
  grok: "Grok",
  hermes: "Hermes",
  opencode: "OpenCode",
  cursor: "Cursor",
  gemini: "Gemini",
  kiro: "Kiro",
  copilot: "Copilot",
  codebuddy: "CodeBuddy",
  factory: "Factory",
  qoder: "Qoder",
  kimi: "Kimi",
  pi: "Pi",
  omp: "OMP",
  campfire: "Campfire",
  rovodev: "Rovo Dev",
  rovo: "Rovo Dev",
};

/** Display name of an agent source (model.zig sourceDisplayName). */
export function sourceDisplayName(source) {
  if (typeof source !== "string" || source === "") return "Agent";
  return Object.prototype.hasOwnProperty.call(SOURCE_NAMES, source) ? SOURCE_NAMES[source] : source;
}

function str(v) {
  return typeof v === "string" ? v : typeof v === "number" && Number.isFinite(v) ? String(v) : "";
}

function optStr(v) {
  return typeof v === "string" && v !== "" ? v : null;
}

function strList(v) {
  return Array.isArray(v) ? v.filter((x) => typeof x === "string") : [];
}

/** Seconds (float, as feed.list encodes) or milliseconds -> milliseconds. */
export function toMs(v) {
  if (typeof v === "number" && Number.isFinite(v)) return Math.round(v < 1e11 ? v * 1000 : v);
  if (typeof v === "string" && v !== "") {
    const n = Number(v);
    if (Number.isFinite(n)) return Math.round(n < 1e11 ? n * 1000 : n);
    const parsed = Date.parse(v);
    if (Number.isFinite(parsed)) return parsed;
  }
  return 0;
}

function normalizeQuestions(v) {
  if (!Array.isArray(v)) return [];
  const out = [];
  for (const q of v) {
    if (!q || typeof q !== "object") continue;
    const options = Array.isArray(q.options)
      ? q.options
          .map((o) => (typeof o === "string" ? { label: o, description: "" } : o && typeof o === "object" ? { label: str(o.label), description: str(o.description) } : null))
          .filter((o) => o && o.label !== "")
      : [];
    out.push({
      question: str(q.question),
      header: str(q.header),
      multi_select: q.multi_select === true || q.multiSelect === true,
      options,
    });
  }
  return out;
}

function normalizeTodos(v) {
  if (!Array.isArray(v)) return [];
  return v
    .filter((t) => t && typeof t === "object")
    .map((t) => ({
      content: str(t.content),
      status: t.status === "in_progress" || t.status === "completed" ? t.status : "pending",
      active_form: str(t.active_form || t.activeForm),
    }));
}

function normalizeResolution(v) {
  if (!v || typeof v !== "object" || Array.isArray(v)) return null;
  const r = { badge: str(v.badge) };
  if (typeof v.mode === "string") r.mode = v.mode;
  if (typeof v.feedback === "string") r.feedback = v.feedback;
  if (Array.isArray(v.selections)) r.selections = strList(v.selections);
  if (typeof v.text === "string") r.text = v.text;
  return r;
}

/** One item in the page's shape, or null without an id or a known kind. */
export function normalizeItem(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const id = optStr(raw.id);
  if (!id || !KINDS.includes(raw.kind)) return null;
  const status = ["pending", "resolved", "timedOut", "expired", "info"].includes(raw.status)
    ? raw.status
    : DECISION_KINDS.includes(raw.kind)
      ? "pending"
      : "info";
  const plan = raw.plan && typeof raw.plan === "object" ? raw.plan : null;
  return {
    id,
    kind: raw.kind,
    status,
    source: str(raw.source),
    hook_event_name: str(raw.hook_event_name),
    title: str(raw.title),
    detail: str(raw.detail),
    created_at_ms: toMs(raw.created_at),
    request_id: optStr(raw.request_id),
    session_id: optStr(raw.session_id),
    workspace_id: optStr(raw.workspace_id),
    surface_id: optStr(raw.surface_id),
    tool_name: optStr(raw.tool_name),
    text: typeof raw.text === "string" ? raw.text : null,
    questions: normalizeQuestions(raw.questions),
    plan: plan ? { text: str(plan.text), file_path: optStr(plan.file_path), allowed_prompts: strList(plan.allowed_prompts) } : null,
    todos: normalizeTodos(raw.todos),
    todo_summary: optStr(raw.todo_summary),
    is_error: typeof raw.is_error === "boolean" ? raw.is_error : null,
    options: strList(raw.options),
    resolution: normalizeResolution(raw.resolution),
    resolved_at_ms: raw.resolved_at === undefined ? null : toMs(raw.resolved_at),
  };
}

/** Items (latest first, deduplicated) from a feed.list result or snapshot. */
export function itemsFrom(result) {
  const list = Array.isArray(result) ? result : result && Array.isArray(result.items) ? result.items : [];
  const seen = new Set();
  const out = [];
  for (const raw of list) {
    const it = normalizeItem(raw);
    if (!it || seen.has(it.id)) continue;
    seen.add(it.id);
    out.push(it);
  }
  return sortItems(out).slice(0, MAX_ITEMS);
}

/** Latest first; ties keep input order. */
export function sortItems(items) {
  return items
    .map((it, i) => [it, i])
    .sort((a, b) => b[0].created_at_ms - a[0].created_at_ms || a[1] - b[1])
    .map((p) => p[0]);
}

/**
 * Merges `incoming` (newer data) into `current`: same ids are replaced,
 * new ids added, the result sorted and capped.
 */
export function mergeItems(current, incoming) {
  const byId = new Map(current.map((it) => [it.id, it]));
  for (const it of incoming) byId.set(it.id, it);
  return sortItems(Array.from(byId.values())).slice(0, MAX_ITEMS);
}

export function isDecision(item) {
  return DECISION_KINDS.includes(item.kind);
}

export function isPending(item) {
  return item.status === "pending";
}

/** A card the user can act on: a pending decision, or a stop card without a reply. */
export function isActionable(item) {
  if (isDecision(item)) return isPending(item);
  return item.kind === "stop" && !item.resolution && item.status !== "expired" && item.status !== "timedOut";
}

/**
 * Actionable tab: pending decisions (latest first) and, under "Resolved",
 * the decisions that are no longer pending (query.zig actionable()).
 */
export function partition(items) {
  const pending = [];
  const resolved = [];
  for (const it of items) {
    if (!isDecision(it)) continue;
    (isPending(it) ? pending : resolved).push(it);
  }
  return { pending, resolved };
}

/** Badge of a closed item: the resolution badge, else derived from status/mode. */
export function badgeFor(item) {
  const r = item.resolution;
  if (r) {
    if (r.badge) return r.badge;
    if (item.kind === "permissionRequest" && r.mode) return PERMISSION_BADGES[r.mode] || r.mode;
    if (item.kind === "exitPlan" && r.mode) return r.mode === "deny" && r.feedback ? "refined" : EXIT_PLAN_BADGES[r.mode] || r.mode;
    if (item.kind === "question") return "Submitted";
    if (item.kind === "stop") return "Sent";
  }
  if (item.status === "timedOut") return "timed out";
  if (item.status === "expired") return "expired";
  return "";
}

/** Local resolution for an answered card (before native confirms it). */
export function localResolution(kind, reply) {
  switch (kind) {
    case "permissionRequest":
      return { mode: reply.mode, badge: PERMISSION_BADGES[reply.mode] || reply.mode };
    case "exitPlan":
      return {
        mode: reply.mode,
        feedback: reply.feedback,
        badge: reply.mode === "deny" && reply.feedback ? "refined" : EXIT_PLAN_BADGES[reply.mode] || reply.mode,
      };
    case "question":
      return { selections: reply.selections.slice(), badge: "Submitted" };
    case "stop":
      return { text: reply.text, badge: "Sent" };
    default:
      return { badge: "" };
  }
}

/** A pending decision native can still route a reply for. */
export function canReply(item) {
  return isDecision(item) && isPending(item) && typeof item.request_id === "string" && item.request_id !== "";
}

/** Modes still selectable on a pending decision, in button order. */
export function availableModes(item) {
  if (!canReply(item)) return [];
  const order = item.kind === "permissionRequest" ? PERMISSION_MODES : item.kind === "exitPlan" ? EXIT_PLAN_MODES : null;
  if (!order) return [];
  // Older hosts may omit `options`: fall back to the native defaults.
  const offered = item.options.length > 0 ? item.options : item.kind === "permissionRequest" ? ["once", "deny"] : ["manual", "deny"];
  return order.filter((m) => offered.includes(m));
}

/** "2 open, 1 in progress, 3 done"; zero parts omitted; empty -> "0 open". */
export function todoSummary(todos) {
  let open = 0;
  let progress = 0;
  let done = 0;
  for (const t of todos) {
    if (t.status === "completed") done += 1;
    else if (t.status === "in_progress") progress += 1;
    else open += 1;
  }
  const parts = [];
  if (open) parts.push(`${open} open`);
  if (progress) parts.push(`${progress} in progress`);
  if (done) parts.push(`${done} done`);
  return parts.length ? parts.join(", ") : "0 open";
}

/** {open, in_progress, done} counts of a todo list. */
export function todoCounts(todos) {
  const c = { open: 0, in_progress: 0, done: 0 };
  for (const t of todos) {
    if (t.status === "completed") c.done += 1;
    else if (t.status === "in_progress") c.in_progress += 1;
    else c.open += 1;
  }
  return c;
}

/**
 * Banner text of a pending decision (model.zig bannerText), or null for
 * other items: permission -> "<Source> permission" / "<tool> needs approval"
 * (or "Decision needed"); plan -> "<Source> plan ready" / "Review and approve
 * the plan"; question -> "<Source> question" / "Agent is asking a question".
 * Returns string keys plus params so the page can translate them.
 */
export function bannerText(item) {
  if (!isDecision(item) || !isPending(item)) return null;
  const source = sourceDisplayName(item.source);
  switch (item.kind) {
    case "permissionRequest":
      return item.tool_name
        ? { title: ["feed.banner.permission", { source }], body: ["feed.banner.permissionBody", { tool: item.tool_name }] }
        : { title: ["feed.banner.permission", { source }], body: ["feed.banner.decisionNeeded", {}] };
    case "exitPlan":
      return { title: ["feed.banner.plan", { source }], body: ["feed.banner.planBody", {}] };
    default:
      return { title: ["feed.banner.question", { source }], body: ["feed.banner.questionBody", {}] };
  }
}

/** Relative age: "now", "5m", "2h", "3d", "4w" (future times read "now"). */
export function relativeTime(ms, nowMs) {
  if (!Number.isFinite(ms) || ms <= 0) return "";
  const s = Math.max(0, Math.floor((nowMs - ms) / 1000));
  if (s < 45) return "now";
  const m = Math.round(s / 60);
  if (m < 60) return `${Math.max(1, m)}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h`;
  const d = Math.floor(h / 24);
  if (d < 7) return `${d}d`;
  return `${Math.floor(d / 7)}w`;
}

/**
 * Agent contexts (source + session), most recently active first
 * (query.zig workstreams()). `items` may be in any order.
 */
export function workstreams(items) {
  const map = new Map();
  for (const it of items) {
    const key = it.source + "\u0000" + (it.session_id || "");
    let w = map.get(key);
    if (!w) {
      w = { key, source: it.source, session_id: it.session_id, workspace_id: null, surface_id: null, item_count: 0, pending_count: 0, last_activity_ms: 0, latest: it };
      map.set(key, w);
    }
    w.item_count += 1;
    if (isActionable(it)) w.pending_count += 1;
    if (it.created_at_ms >= w.last_activity_ms) {
      w.last_activity_ms = it.created_at_ms;
      w.latest = it;
    }
    if (it.workspace_id && !w.workspace_id) w.workspace_id = it.workspace_id;
    if (it.surface_id && !w.surface_id) w.surface_id = it.surface_id;
  }
  return Array.from(map.values()).sort((a, b) => b.last_activity_ms - a.last_activity_ms);
}

/** Event name of a `cmux.event` frame. */
export function frameName(frame) {
  if (!frame || typeof frame !== "object") return "";
  if (typeof frame.name === "string") return frame.name;
  if (typeof frame.event === "string") return frame.event;
  return "";
}

export function isFeedEvent(name) {
  return typeof name === "string" && name.startsWith("feed.");
}

/**
 * `feed.question.reply` selections: each question's chosen labels in order,
 * then its free text (trimmed, when not empty; for a single-choice question
 * the text replaces the option). Also returns the per-question
 * answers (wmux extension `answers`).
 * @param {{question: string, options: object[], multi_select: boolean}[]} questions
 * @param {{selected: Set<string>|string[], other: string}[]} answers
 */
export function buildSelections(questions, answers) {
  const flat = [];
  const perQuestion = [];
  questions.forEach((q, i) => {
    const a = answers[i] || { selected: [], other: "" };
    const chosen = q.options.map((o) => o.label).filter((label) => (a.selected instanceof Set ? a.selected.has(label) : a.selected.includes(label)));
    const other = typeof a.other === "string" ? a.other.trim() : "";
    // Single choice: typed text replaces the option; multi-select adds it.
    const one = q.multi_select ? chosen : other ? [] : chosen.slice(0, 1);
    if (other) one.push(other);
    perQuestion.push(one);
    flat.push(...one);
  });
  return { selections: flat, answers: perQuestion };
}
