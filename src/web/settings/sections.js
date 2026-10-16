/**
 * Settings sections (ARCHITECTURE ADR-5.8): the cmux raw section ids (persisted
 * and used for deep links, never renamed) plus the Windows-only `windows`
 * section, their labels, search keywords and the `settings open <target>`
 * aliases. Account, mobile, cloud, devices and networking are omitted on
 * Windows; their targets fall back to the first section.
 */
import { t } from "./strings.js";

/**
 * Section order in the left nav. `custom` marks sections with a hand-built
 * page in addition to (or instead of) schema rows.
 */
export const SECTIONS = Object.freeze([
  { id: "app", keywords: ["general", "language", "quit", "workspace", "tabs", "editor", "confirm", "warn"] },
  {
    id: "themes",
    custom: true,
    keywords: ["appearance", "theme", "dark", "light", "accent", "color", "colour", "palette"],
  },
  {
    id: "terminal",
    keywords: ["scrollback", "scroll", "copy", "paste", "selection", "cursor", "font", "password", "echo", "shell"],
  },
  { id: "textBox", keywords: ["composer", "input", "submit", "prompt"] },
  { id: "sidebarAppearance", keywords: ["sidebar", "branch", "ports", "pull request", "badge", "metadata"] },
  { id: "automation", keywords: ["socket", "agent", "claude", "hooks", "notifications", "cli", "api"] },
  { id: "browser", keywords: ["web", "search engine", "zoom", "url", "download", "allowlist"] },
  { id: "browserImport", keywords: ["import", "bookmarks", "cookies", "history"] },
  { id: "globalHotkey", keywords: ["hotkey", "quick terminal", "dropdown", "summon"] },
  {
    id: "keyboardShortcuts",
    custom: true,
    keywords: ["shortcuts", "keys", "keybindings", "keymap", "preset", "chord", "tmux", "resize"],
  },
  { id: "workspaceColors", keywords: ["colors", "colour", "workspace", "tint"] },
  { id: "settingsJSON", custom: true, keywords: ["json", "wmux.json", "cmux.json", "file", "config", "docs"] },
  { id: "reset", custom: true, keywords: ["reset", "defaults", "restore", "clear"] },
  { id: "windows", keywords: ["windows", "explorer", "shell", "toast", "cli tools", "taskbar", "tray"] },
]);

export const SECTION_IDS = Object.freeze(SECTIONS.map((s) => s.id));

const DEFAULT_TITLES = Object.freeze({
  app: "App",
  themes: "Themes",
  terminal: "Terminal",
  textBox: "TextBox",
  sidebarAppearance: "Sidebar",
  automation: "Automation",
  browser: "Browser",
  browserImport: "Import Browser Data",
  globalHotkey: "Global Hotkey",
  keyboardShortcuts: "Keyboard Shortcuts",
  workspaceColors: "Workspace Colors",
  settingsJSON: "wmux.json",
  reset: "Reset",
  windows: "Windows",
});

/** Localized section title; unknown ids show the raw id. */
export function sectionTitle(id) {
  if (Object.prototype.hasOwnProperty.call(DEFAULT_TITLES, id)) return t(`settings.section.${id}`);
  return String(id);
}

/** The section record for an id, or null. */
export function findSection(id) {
  return SECTIONS.find((s) => s.id === id) || null;
}

/**
 * `settings open <target>` aliases (cmux CLI targets; matched
 * case-insensitively). Raw section ids are accepted as well.
 */
export const TARGET_ALIASES = Object.freeze({
  app: "app",
  general: "app",
  themes: "themes",
  theme: "themes",
  appearance: "themes",
  terminal: "terminal",
  textbox: "textBox",
  "text-box": "textBox",
  sidebar: "sidebarAppearance",
  "sidebar-appearance": "sidebarAppearance",
  automation: "automation",
  browser: "browser",
  "browser-import": "browserImport",
  "import-browser-data": "browserImport",
  "global-hotkey": "globalHotkey",
  hotkey: "globalHotkey",
  "keyboard-shortcuts": "keyboardShortcuts",
  shortcuts: "keyboardShortcuts",
  keys: "keyboardShortcuts",
  keybindings: "keyboardShortcuts",
  "workspace-colors": "workspaceColors",
  colors: "workspaceColors",
  "cmux-json": "settingsJSON",
  "wmux-json": "settingsJSON",
  json: "settingsJSON",
  "settings-json": "settingsJSON",
  file: "settingsJSON",
  "settings-file": "settingsJSON",
  reset: "reset",
  windows: "windows",
});

/** Targets cmux has that wmux omits on Windows (cloud or account features). */
export const OMITTED_TARGETS = Object.freeze([
  "account",
  "mobile",
  "cloud",
  "cloudmachines",
  "networking",
  "network",
  "iroh",
  "computers",
  "devices",
  "custom-sidebars",
  "customsidebars",
]);

/**
 * Resolve a CLI target or raw section id to a section id. Returns null for
 * empty, unknown or omitted targets (the caller keeps the current section).
 */
export function resolveTarget(target) {
  if (typeof target !== "string") return null;
  const raw = target.trim();
  if (raw === "") return null;
  if (SECTION_IDS.includes(raw)) return raw;
  const key = raw.toLowerCase();
  if (Object.prototype.hasOwnProperty.call(TARGET_ALIASES, key)) return TARGET_ALIASES[key];
  const byId = SECTION_IDS.find((id) => id.toLowerCase() === key);
  return byId || null;
}
