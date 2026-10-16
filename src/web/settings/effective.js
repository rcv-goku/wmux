/**
 * Effective settings (pure): normalizes `wmux.settings.get_effective` replies
 * and decides what each row may do. Sources follow `config get --json`
 * (ADR-5.6): default | ghostty | cmux.json | wmux.json | project | policy.
 */

export const SOURCES = Object.freeze(["default", "ghostty", "cmux.json", "wmux.json", "project", "policy"]);

const SOURCE_ALIASES = Object.freeze({
  default: "default",
  builtin: "default",
  "built-in": "default",
  ghostty: "ghostty",
  cmux: "cmux.json",
  "cmux.json": "cmux.json",
  wmux: "wmux.json",
  "wmux.json": "wmux.json",
  pack: "wmux.json",
  project: "project",
  policy: "policy",
  managed: "policy",
  mdm: "policy",
});

/** Canonical source name; unknown or missing -> "default". */
export function normalizeSource(source) {
  if (typeof source !== "string") return "default";
  const key = source.trim().toLowerCase();
  return Object.prototype.hasOwnProperty.call(SOURCE_ALIASES, key) ? SOURCE_ALIASES[key] : "default";
}

function entryOf(raw) {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
  const source = normalizeSource(raw.source);
  return {
    value: Object.prototype.hasOwnProperty.call(raw, "value") ? raw.value : undefined,
    source,
    locked: raw.locked === true || source === "policy",
    error: typeof raw.error === "string" && raw.error ? raw.error : null,
  };
}

/**
 * Accepted reply shapes:
 *   {values: {"<path>": {value, source, locked?, error?}}}
 *   {values: [{path, value, source, locked?, error?}]}
 *   {"<path>": {value, source, ...}} (the map itself)
 * Returns a Map path -> {value, source, locked, error}. Bad entries are dropped.
 */
export function normalizeEffective(result) {
  const out = new Map();
  if (result === null || typeof result !== "object") return out;
  const values = Object.prototype.hasOwnProperty.call(result, "values") ? result.values : result;
  if (Array.isArray(values)) {
    for (const raw of values) {
      if (!raw || typeof raw.path !== "string" || raw.path === "") continue;
      const entry = entryOf(raw);
      if (entry) out.set(raw.path, entry);
    }
  } else if (values && typeof values === "object") {
    for (const path of Object.keys(values)) {
      if (path === "") continue;
      const entry = entryOf(values[path]);
      if (entry) out.set(path, entry);
    }
  }
  return out;
}

/**
 * Row state for a field given its effective entry (may be undefined) and
 * whether the user chose "Override in wmux.json" for a cmux.json value.
 *   value     effective value (the default when native sent nothing)
 *   source    canonical source
 *   readOnly  policy locks always; project-only keys; cmux.json values until overridden
 *   managed   "policy" | "project" | "cmux.json" | null (why the row is read-only)
 *   canReset  the value lives in wmux.json, so `wmux.settings.unset` restores the lower layer
 *   modified  the value differs from the default
 */
export function rowState(field, entry, options) {
  const opts = options || {};
  const deepEqual = opts.deepEqual || ((a, b) => JSON.stringify(a) === JSON.stringify(b));
  const source = entry ? entry.source : "default";
  const value = entry && entry.value !== undefined ? entry.value : field.default;
  const locked = Boolean(entry && entry.locked);
  let managed = null;
  if (locked) managed = "policy";
  else if (Array.isArray(field.scopes) && field.scopes.length > 0 && !field.scopes.includes("global"))
    managed = "project";
  else if (source === "cmux.json" && !opts.overridden) managed = "cmux.json";
  return {
    value,
    source,
    readOnly: managed !== null,
    managed,
    canReset: source === "wmux.json" && !locked && managed !== "project",
    modified: field.hasDefault ? !deepEqual(value, field.default) : source !== "default",
    error: entry ? entry.error : null,
  };
}
