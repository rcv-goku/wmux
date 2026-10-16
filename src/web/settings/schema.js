/**
 * Settings schema -> form fields (pure). The schema is the generated JSON
 * Schema of the spec registry (ADR-5.2, `docs/wmux/schema/wmux.schema.json`)
 * with the UI hints `title`, `description`, `default`, `x-wmux-section`,
 * `x-wmux-keywords`, `x-wmux-kind` (path | strokes), `x-wmux-apply`,
 * `x-cmux-scopes`, `x-wmux-policy-lockable` and `x-wmux-ghostty-override`.
 * Leaves are the nodes that carry a section or a default; plain `object`
 * nodes with `properties` and neither are containers of dotted paths.
 */
import { parseBinding } from "../_shared/keys.js";
import { SECTION_IDS } from "./sections.js";
import { t } from "./strings.js";

/** Matches `spec.isColor` / `schema_dump.color_pattern`. */
export const COLOR_PATTERN = "^#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$";
const COLOR_RE = /^#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$/;

/** File-level root keys that are not settings rows. */
export const META_KEYS = Object.freeze(["$schema", "schemaVersion", "packs"]);

/** Section for schemas without `x-wmux-section` (by first path segment). */
const FALLBACK_SECTIONS = Object.freeze({
  app: "app",
  appearance: "themes",
  terminal: "terminal",
  surfaceTabBar: "terminal",
  textBox: "textBox",
  sidebar: "sidebarAppearance",
  automation: "automation",
  notifications: "automation",
  browser: "browser",
  shortcuts: "keyboardShortcuts",
  workspaceColors: "workspaceColors",
  wmux: "windows",
});

/** Unbind spellings (ADR-8.3). */
const UNBIND_VALUES = new Set(["", "none", "clear", "unbound", "disabled"]);

const hasOwn = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key);
const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

/** Structural equality for JSON values (key order ignored). */
export function deepEqual(a, b) {
  if (a === b) return true;
  if (typeof a !== typeof b || a === null || b === null || typeof a !== "object") return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a)) {
    if (a.length !== b.length) return false;
    return a.every((x, i) => deepEqual(x, b[i]));
  }
  const ka = Object.keys(a);
  const kb = Object.keys(b);
  if (ka.length !== kb.length) return false;
  return ka.every((k) => hasOwn(b, k) && deepEqual(a[k], b[k]));
}

/** "showPortsInSidebar" -> "Show ports in sidebar" (title fallback). */
export function humanize(segment) {
  const text = String(segment || "")
    .replace(/[-_]+/g, " ")
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2")
    .trim()
    .toLowerCase();
  return text ? text[0].toUpperCase() + text.slice(1) : "";
}

function typesOf(node) {
  if (Array.isArray(node.type)) return node.type.filter((x) => typeof x === "string");
  if (typeof node.type === "string") return [node.type];
  return [];
}

function isLeaf(node) {
  if (hasOwn(node, "x-wmux-section") || hasOwn(node, "default")) return true;
  if (isObject(node.properties)) return false;
  return typesOf(node).length > 0 || Array.isArray(node.enum) || Array.isArray(node.oneOf);
}

/** Control kind of a leaf schema node. */
export function kindOf(node) {
  const hint = node["x-wmux-kind"];
  if (hint === "strokes" || hint === "path" || hint === "color") return hint;
  if (Array.isArray(node.enum) && node.enum.length > 0) return "enum";
  const types = typesOf(node).filter((x) => x !== "null");
  const type = types.length === 1 ? types[0] : null;
  switch (type) {
    case "boolean":
      return "bool";
    case "integer":
      return "integer";
    case "number":
      return "number";
    case "string":
      if (node.pattern === COLOR_PATTERN || node.format === "color") return "color";
      return "string";
    case "array":
      if (isObject(node.items) && typesOf(node.items).join() === "string" && !node.items.enum) return "list";
      return "json";
    case "object":
      return "object";
    default:
      return "json";
  }
}

function nullableOf(node) {
  if (typesOf(node).includes("null")) return true;
  if (Array.isArray(node.enum) && node.enum.includes(null)) return true;
  if (Array.isArray(node.oneOf) && node.oneOf.some((s) => isObject(s) && s.type === "null")) return true;
  return hasOwn(node, "default") && node.default === null;
}

function fieldFor(path, node) {
  const segments = path.split(".");
  const kind = kindOf(node);
  let section = typeof node["x-wmux-section"] === "string" ? node["x-wmux-section"] : "";
  if (!section) section = hasOwn(FALLBACK_SECTIONS, segments[0]) ? FALLBACK_SECTIONS[segments[0]] : "app";
  const field = {
    path,
    section,
    title: typeof node.title === "string" && node.title ? node.title : humanize(segments[segments.length - 1]),
    description: typeof node.description === "string" ? node.description : "",
    kind,
    hasDefault: hasOwn(node, "default"),
    default: hasOwn(node, "default") ? node.default : null,
    nullable: nullableOf(node),
    keywords: Array.isArray(node["x-wmux-keywords"]) ? node["x-wmux-keywords"].map(String) : [],
    apply: node["x-wmux-apply"] === "restart" ? "restart" : "live",
    scopes: Array.isArray(node["x-cmux-scopes"]) ? node["x-cmux-scopes"].map(String) : ["global"],
    policyLockable: node["x-wmux-policy-lockable"] !== false,
    ghosttyOverride: typeof node["x-wmux-ghostty-override"] === "string" ? node["x-wmux-ghostty-override"] : null,
    enumValues: Array.isArray(node.enum) ? node.enum.slice() : null,
    min: typeof node.minimum === "number" ? node.minimum : null,
    max: typeof node.maximum === "number" ? node.maximum : null,
    step: typeof node.multipleOf === "number" && node.multipleOf > 0 ? node.multipleOf : null,
    pattern: kind === "string" || kind === "path" ? (typeof node.pattern === "string" ? node.pattern : null) : null,
    minLength: typeof node.minLength === "number" ? node.minLength : null,
  };
  if (field.kind === "integer" && field.step === null) field.step = 1;
  return field;
}

/**
 * Flatten a schema into fields ordered by section (SECTIONS order, unknown
 * sections last) and then by schema order. Malformed input yields [].
 */
export function flattenSchema(schema) {
  const out = [];
  if (!isObject(schema) || !isObject(schema.properties)) return out;
  const walk = (props, prefix, depth) => {
    if (depth > 32) return;
    for (const key of Object.keys(props)) {
      const node = props[key];
      if (!isObject(node) || key === "") continue;
      if (!prefix && META_KEYS.includes(key)) continue;
      const path = prefix ? `${prefix}.${key}` : key;
      if (isLeaf(node)) out.push(fieldFor(path, node));
      else if (isObject(node.properties)) walk(node.properties, path, depth + 1);
    }
  };
  walk(schema.properties, "", 0);
  const rank = (s) => {
    const i = SECTION_IDS.indexOf(s);
    return i < 0 ? SECTION_IDS.length : i;
  };
  return out
    .map((f, i) => ({ f, i }))
    .sort((a, b) => rank(a.f.section) - rank(b.f.section) || a.i - b.i)
    .map((x) => x.f);
}

function formatNumber(n) {
  return Number.isInteger(n) ? String(n) : String(Number(n.toPrecision(12)));
}

function rangeMessage(field) {
  const { min, max } = field;
  if (min !== null && max !== null)
    return t("settings.validate.range", { min: formatNumber(min), max: formatNumber(max) });
  if (min !== null) return t("settings.validate.min", { min: formatNumber(min) });
  return t("settings.validate.max", { max: formatNumber(max) });
}

function patternMatches(pattern, text) {
  try {
    return new RegExp(pattern, "u").test(text);
  } catch {
    return true; // an unsupported pattern is checked natively
  }
}

/**
 * Validate a value against a field. Returns null when valid, else a
 * user-visible message. Native validates again (`wmux.settings.set`).
 */
export function validateValue(field, value) {
  if (value === null || value === undefined) {
    return field.nullable || field.kind === "json" ? null : t("settings.validate.required");
  }
  switch (field.kind) {
    case "bool":
      return typeof value === "boolean" ? null : t("settings.validate.bool");
    case "integer":
    case "number": {
      if (typeof value !== "number" || !Number.isFinite(value)) return t("settings.validate.number");
      if (field.kind === "integer" && !Number.isInteger(value)) return t("settings.validate.integer");
      if ((field.min !== null && value < field.min) || (field.max !== null && value > field.max))
        return rangeMessage(field);
      if (field.step !== null && field.kind === "number") {
        const q = value / field.step;
        if (Math.abs(q - Math.round(q)) > 1e-9) return t("settings.validate.step", { step: formatNumber(field.step) });
      }
      return null;
    }
    case "enum":
      return field.enumValues.some((v) => deepEqual(v, value))
        ? null
        : t("settings.validate.enum", { values: field.enumValues.map((v) => String(v)).join(", ") });
    case "color":
      return typeof value === "string" && COLOR_RE.test(value) ? null : t("settings.validate.color");
    case "string":
    case "path":
      if (typeof value !== "string") return t("settings.validate.string");
      if (field.minLength !== null && [...value].length < field.minLength) return t("settings.validate.required");
      if (field.pattern && !patternMatches(field.pattern, value))
        return t("settings.validate.pattern", { pattern: field.pattern });
      return null;
    case "list":
      return Array.isArray(value) && value.every((x) => typeof x === "string") ? null : t("settings.validate.list");
    case "object":
      return isObject(value) ? null : t("settings.validate.object");
    case "strokes": {
      if (typeof value === "string" && UNBIND_VALUES.has(value.trim().toLowerCase())) return null;
      const ok = (typeof value === "string" || Array.isArray(value)) && parseBinding(value) !== null;
      return ok ? null : t("settings.validate.strokes");
    }
    default:
      return null;
  }
}

/**
 * Parse the text of a text-based control into a value:
 * {ok: true, value} or {ok: false, error}.
 */
export function parseInput(field, text) {
  const raw = typeof text === "string" ? text : "";
  switch (field.kind) {
    case "integer":
    case "number": {
      const trimmed = raw.trim();
      if (trimmed === "") {
        return field.nullable ? { ok: true, value: null } : { ok: false, error: t("settings.validate.number") };
      }
      const n = Number(trimmed);
      if (!Number.isFinite(n)) return { ok: false, error: t("settings.validate.number") };
      return { ok: true, value: n };
    }
    case "color": {
      const trimmed = raw.trim();
      if (trimmed === "" && field.nullable) return { ok: true, value: null };
      return { ok: true, value: trimmed };
    }
    case "list":
      return {
        ok: true,
        value: raw
          .split(/\r\n|\r|\n/)
          .map((x) => x.trim())
          .filter((x) => x !== ""),
      };
    case "json":
    case "object": {
      if (raw.trim() === "") return { ok: true, value: field.kind === "object" ? {} : null };
      try {
        return { ok: true, value: JSON.parse(raw) };
      } catch (err) {
        return { ok: false, error: t("settings.validate.json", { message: err.message }) };
      }
    }
    case "strokes": {
      const trimmed = raw.trim();
      const parts = trimmed.split(/\s+/);
      return { ok: true, value: parts.length === 2 ? parts : trimmed };
    }
    default:
      return { ok: true, value: raw };
  }
}

/** Display text of a value for list/strokes/json controls. */
export function formatInput(field, value) {
  if (value === null || value === undefined) return "";
  switch (field.kind) {
    case "list":
      return Array.isArray(value) ? value.join("\n") : "";
    case "strokes":
      return Array.isArray(value) ? value.join(" ") : String(value);
    case "json":
    case "object":
      return JSON.stringify(value, null, 2);
    default:
      return typeof value === "string" ? value : String(value);
  }
}

/* ------------------------------------------------------------------ search */

/** Case- and width-insensitive form used for matching. */
export function foldText(text) {
  return String(text ?? "")
    .normalize("NFKC")
    .toLocaleLowerCase();
}

/** Whitespace-separated query tokens (folded); [] for an empty query. */
export function queryTokens(query) {
  return foldText(query)
    .split(/\s+/)
    .filter((x) => x !== "")
    .slice(0, 16);
}

/** Every searchable string of a field. */
export function fieldHaystack(field, sectionTitle, sectionKeywords) {
  const parts = [
    field.title,
    field.description,
    field.path,
    ...field.keywords,
    sectionTitle || "",
    ...(sectionKeywords || []),
  ];
  if (field.enumValues) for (const v of field.enumValues) parts.push(String(v));
  return foldText(parts.join("\n"));
}

/** True when every token occurs in the haystack (an empty query matches). */
export function matchesTokens(haystack, tokens) {
  return tokens.every((tok) => haystack.includes(tok));
}

/**
 * Ranges [start, end) in `text` where any token occurs, merged and sorted,
 * for <mark> highlights. Folding may change lengths for some characters, so
 * matching runs per code unit on the lower-cased text only when it has the
 * same length; otherwise nothing is highlighted.
 */
export function highlightRanges(text, tokens) {
  const source = String(text ?? "");
  const lower = source.toLocaleLowerCase();
  if (lower.length !== source.length || tokens.length === 0) return [];
  const ranges = [];
  for (const tok of tokens) {
    const needle = tok.toLocaleLowerCase();
    if (!needle) continue;
    let from = 0;
    while (ranges.length < 1000) {
      const at = lower.indexOf(needle, from);
      if (at < 0) break;
      ranges.push([at, at + needle.length]);
      from = at + needle.length;
    }
  }
  ranges.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  const merged = [];
  for (const r of ranges) {
    const last = merged[merged.length - 1];
    if (last && r[0] <= last[1]) last[1] = Math.max(last[1], r[1]);
    else merged.push([r[0], r[1]]);
  }
  return merged;
}
