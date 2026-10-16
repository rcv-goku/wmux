/**
 * Task Manager strings. Keys are stable ids for translators (W7); values are
 * the English defaults handed to tr(). index.html carries the same keys in
 * data-i18n / data-i18n-attr attributes for its static text.
 */
import { tr } from "../_shared/strings.js";

export const STRINGS = Object.freeze({
  "tm.title": "Task Manager",
  "tm.refreshing": "Refreshing…",
  "tm.processes": "Processes",
  "tm.refresh": "Refresh",

  "tm.cards": "Summary",
  "tm.card.cpu": "CPU",
  "tm.card.memory": "Memory",
  "tm.card.app": "App Footprint",
  "tm.card.child": "Child RSS",
  "tm.card.processes": "Processes",
  "tm.card.updated": "Updated",
  "tm.card.none": "—",

  "tm.section.agents": "Coding Agents",
  "tm.section.programs": "Program Totals",
  "tm.section.child": "Child Process RSS",
  "tm.section.hierarchy": "Hierarchy",
  "tm.section.noAgents": "No coding agents running.",
  "tm.section.noPrograms": "No processes.",
  "tm.section.noChild": "No child processes.",

  "tm.col.name": "Name",
  "tm.col.cpu": "CPU",
  "tm.col.memory": "Memory",
  "tm.col.proc": "Proc",
  "tm.sort": "Sort by {column}",

  "tm.kind.window": "Window",
  "tm.kind.pane": "Pane",
  "tm.kind.terminal": "terminal",
  "tm.kind.browser": "browser",
  "tm.kind.webview": "Browser webview",
  "tm.flag.hidden": "hidden",
  "tm.flag.key": "key",
  "tm.flag.selected": "selected",
  "tm.flag.pinned": "pinned",
  "tm.flag.focused": "focused",
  "tm.flag.pidOnly": "pid-only",
  "tm.pid": "PID {pid}",
  "tm.expand": "Expand",
  "tm.collapse": "Collapse",

  "tm.state.loading": "Loading resource usage",
  "tm.state.empty": "No resource usage",
  "tm.state.emptyBody": "Open a workspace, terminal, or browser surface to see it here.",
  "tm.state.loadFailed": "Unable to load resource usage",
  "tm.state.refreshFailed": "Unable to refresh Task Manager data.",
  "tm.state.unsupported": "This wmux build does not support process diagnostics.",
  "tm.state.malformed": "malformed system.top reply",
  "tm.state.offline": "Not running inside wmux.",

  "tm.menu.label": "Row actions",
  "tm.menu.workspace": "View Workspace",
  "tm.menu.terminal": "View Terminal",
  "tm.menu.kill": "Kill Process...",

  "tm.kill.title": "Kill process?",
  "tm.kill.one":
    "Ask {name} (PID {pid}) to terminate gracefully. wmux will force-kill it if it is still running after a short grace period.",
  "tm.kill.many":
    "Ask {count} processes (PIDs {pids}) to terminate gracefully. wmux will force-kill them if they are still running after a short grace period.",
  "tm.kill.ok": "Kill",
  "tm.kill.cancel": "Cancel",
  "tm.kill.failed": "Unable to kill process: {message}",
  "tm.jump.failed": "Unable to show it: {message}",
});

/**
 * Translate a Task Manager string.
 * @param {keyof typeof STRINGS | string} key
 * @param {Record<string, unknown>} [params]
 */
export function t(key, params) {
  const fallback = Object.prototype.hasOwnProperty.call(STRINGS, key) ? STRINGS[key] : key;
  return tr(key, fallback, params);
}
