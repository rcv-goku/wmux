/**
 * Todos pane model (pure). Mirrors the native checklist model in
 * src/apprt/win32/features/todo/logic/checklist.zig: wire states
 * `pending` / `in-progress` / `completed`, origins `user` / `agent`, at most
 * 50 items, text trimmed and capped at 500 code points, storage order as
 * native sends it and a derived display order (not completed first). A move
 * stays inside the item's completion group, as `Checklist.move` clamps it.
 * No DOM, no bridge: unit-tested directly.
 */

export const MAX_ITEMS = 50;
export const MAX_TEXT_CHARS = 500;
export const STATES = Object.freeze(["pending", "in-progress", "completed"]);
export const ORIGINS = Object.freeze(["user", "agent"]);

const STATE_SET = new Set(STATES);
const ORIGIN_SET = new Set(ORIGINS);

/** Code points `checklist.zig: isSpace` trims (ASCII and Unicode spaces). */
function isSpace(cp) {
  return (
    cp === 0x20 ||
    (cp >= 0x09 && cp <= 0x0d) ||
    cp === 0x85 ||
    cp === 0xa0 ||
    cp === 0x1680 ||
    (cp >= 0x2000 && cp <= 0x200a) ||
    cp === 0x2028 ||
    cp === 0x2029 ||
    cp === 0x202f ||
    cp === 0x205f ||
    cp === 0x3000 ||
    cp === 0xfeff
  );
}

function trimSpace(chars) {
  let start = 0;
  let end = chars.length;
  while (start < end && isSpace(chars[start].codePointAt(0))) start += 1;
  while (end > start && isSpace(chars[end - 1].codePointAt(0))) end -= 1;
  return chars.slice(start, end);
}

/** True when `s` has no lone UTF-16 surrogate (native rejects WTF-8). */
export function isWellFormedText(s) {
  if (typeof s !== "string") return false;
  if (typeof s.isWellFormed === "function") return s.isWellFormed();
  return !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:^|[^\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(s);
}

/**
 * Same rules as `checklist.zig: normalizeText`: trim, reject empty or
 * malformed text, cap at 500 code points and re-trim after the cut.
 * @param {unknown} raw
 * @returns {{ok: true, text: string} | {ok: false, error: "empty" | "invalid"}}
 */
export function normalizeText(raw) {
  if (typeof raw !== "string" || !isWellFormedText(raw)) return { ok: false, error: "invalid" };
  const trimmed = trimSpace(Array.from(raw));
  if (trimmed.length === 0) return { ok: false, error: "empty" };
  const capped = trimSpace(trimmed.slice(0, MAX_TEXT_CHARS));
  return { ok: true, text: capped.join("") };
}

/**
 * One attachment as native reports it: `{id, name}` (a string is taken as
 * both). Pages never get filesystem paths, only ids and display names.
 */
export function normalizeAttachment(raw, index) {
  if (typeof raw === "string") return raw ? { id: raw, name: raw } : null;
  if (!raw || typeof raw !== "object") return null;
  const id = typeof raw.id === "string" && raw.id ? raw.id : null;
  const name = typeof raw.name === "string" && raw.name ? raw.name : null;
  if (!id && !name) return null;
  return { id: id || name, name: name || `image ${index + 1}` };
}

/**
 * Wire item `{id, text, state, origin, attachments?}`; unknown states fall
 * back to `pending` and unknown origins to `user`. Null when unusable.
 */
export function normalizeItem(raw) {
  if (!raw || typeof raw !== "object") return null;
  if (typeof raw.id !== "string" || raw.id === "") return null;
  if (typeof raw.text !== "string") return null;
  const state = STATE_SET.has(raw.state) ? raw.state : "pending";
  const origin = ORIGIN_SET.has(raw.origin) ? raw.origin : "user";
  const list = Array.isArray(raw.attachments) ? raw.attachments : [];
  const attachments = [];
  list.forEach((a, i) => {
    const att = normalizeAttachment(a, i);
    if (att) attachments.push(att);
  });
  return { id: raw.id, text: raw.text, state, origin, attachments };
}

/**
 * `workspace.todo.list` result (`{items, completed, total}`), a bare item
 * array, or `{checklist: {...}}`. Items with a repeated id keep the first.
 * @returns {{items: object[], completed: number, total: number} | null}
 */
export function normalizeList(payload) {
  let raw = payload;
  if (raw && typeof raw === "object" && !Array.isArray(raw) && raw.checklist) raw = raw.checklist;
  const array = Array.isArray(raw) ? raw : raw && Array.isArray(raw.items) ? raw.items : null;
  if (!array) return null;
  const seen = new Set();
  const items = [];
  for (const entry of array) {
    const item = normalizeItem(entry);
    if (!item || seen.has(item.id)) continue;
    seen.add(item.id);
    items.push(item);
  }
  return { items, ...progress(items) };
}

/** `{completed, total}`. */
export function progress(items) {
  let completed = 0;
  for (const it of items) if (it.state === "completed") completed += 1;
  return { completed, total: items.length };
}

/** "2/5". */
export function progressText(p) {
  return `${p.completed}/${p.total}`;
}

/** Storage indexes in display order: not completed first, then completed. */
export function displayOrder(items) {
  const open = [];
  const done = [];
  items.forEach((it, i) => (it.state === "completed" ? done : open).push(i));
  return open.concat(done);
}

/** Return / Ctrl+Enter toggle: completed -> pending, anything else -> completed. */
export function toggledState(state) {
  return state === "completed" ? "pending" : "completed";
}

/** True when both items sit in the same completion group. */
export function sameGroup(a, b) {
  return (a.state === "completed") === (b.state === "completed");
}

/**
 * `Checklist.move`: the storage index the item at `index` ends up at when
 * moved toward `newIndex`, clamped between the first and last storage
 * positions of its completion group.
 */
export function clampMove(items, index, newIndex) {
  const done = items[index].state === "completed";
  let lo = index;
  let hi = index;
  items.forEach((it, i) => {
    if ((it.state === "completed") !== done) return;
    lo = Math.min(lo, i);
    hi = Math.max(hi, i);
  });
  return Math.min(Math.max(newIndex, lo), hi);
}

/** A copy of `items` with the item at `from` moved to storage index `to`. */
export function applyMove(items, from, to) {
  const out = items.slice();
  const [moving] = out.splice(from, 1);
  out.splice(to, 0, moving);
  return out;
}

/**
 * Storage index for dropping the item `fromId` before (`after = false`) or
 * after the item `targetId`; null when the drop is not allowed (other
 * completion group, unknown ids) or changes nothing the pane shows.
 */
export function dropTarget(items, fromId, targetId, after) {
  const from = items.findIndex((it) => it.id === fromId);
  const target = items.findIndex((it) => it.id === targetId);
  if (from < 0 || target < 0 || from === target) return null;
  if (!sameGroup(items[from], items[target])) return null;
  let dest = after ? target + 1 : target;
  if (dest > from) dest -= 1;
  dest = clampMove(items, from, dest);
  if (dest === from) return null;
  // Completed items stay where they are in storage, so they can sit between
  // two open ones. Dropping an item right next to its neighbour then picks a
  // new storage index without changing the order the pane shows; skip it, as
  // it would only renumber the items in `todo list`.
  const shown = (list) => displayOrder(list).map((i) => list[i].id);
  const before = shown(items);
  const moved = shown(applyMove(items, from, dest));
  return moved.every((id, i) => id === before[i]) ? null : dest;
}

/**
 * Storage index for Alt+Up / Alt+Down on `id` (`delta` -1 / +1): the
 * neighbour in display order within the same group; null at the group edge.
 */
export function stepTarget(items, id, delta) {
  const order = displayOrder(items);
  const pos = order.findIndex((i) => items[i].id === id);
  if (pos < 0) return null;
  const next = order[pos + delta];
  if (next === undefined || !sameGroup(items[order[pos]], items[next])) return null;
  return next;
}

/**
 * The lane name is hidden when the workspace is in the default `todo` lane
 * and not pinned. `status` is the `workspace.status.get` result.
 */
export function laneLabel(status) {
  if (!status || typeof status !== "object") return "";
  const lane =
    typeof status.lane === "string" ? status.lane : typeof status.status === "string" ? status.status : "";
  const name = typeof status.lane_name === "string" && status.lane_name ? status.lane_name : lane;
  if (!lane) return "";
  if (lane === "todo" && !status.pinned) return "";
  return name;
}

/** The item highlighted after the list changed: same id, else the same row, else none. */
export function keepHighlight(items, prevId, prevPos) {
  if (!items.length) return null;
  if (prevId && items.some((it) => it.id === prevId)) return prevId;
  if (prevPos === null || prevPos === undefined || prevPos < 0) return null;
  const order = displayOrder(items);
  return items[order[Math.min(prevPos, order.length - 1)]].id;
}
