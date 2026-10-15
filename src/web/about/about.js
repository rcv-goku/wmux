/**
 * About panel: PanelKind "about" (ARCHITECTURE ADR-6.11), entry
 * https://about.wmux.example/about/index.html.
 *
 * Native contract: kind-local methods handled by the about kind's on_message
 * (they fall under the implicit "panel.*" allowlist):
 *
 *   panel.about.info {} -> {
 *     product: "wmux",
 *     version: "1.2.0",            // the same string `wmux --version` prints and
 *                                  // system.capabilities -> capabilities.wmux.version
 *                                  // reports (the W1-6 e2e compares them)
 *     channel: "stable",           // optional
 *     commit: "aa1f532...",        // optional
 *     build: {                     // optional; string/number/boolean values. Known keys are
 *       build_mode, zig_version,   // shown first in this order, other keys after them
 *       app_runtime, renderer,     // with the key as label.
 *       font_engine, webview2_runtime, os, arch
 *     },
 *     license: {spdx: "MIT", name: "MIT License", text: "..."} | "MIT",   // optional
 *     copyright: "Copyright (c) ...",                                     // optional
 *     homepage: "https://..."                                             // optional, https only
 *   }
 *   panel.about.notices {} -> {text: "...", format: "text"} | "..."
 *     the bundled third-party notices (Ghostty dependencies, WebView2 loader,
 *     every src/web/_vendor/<lib>@<ver>/LICENSE), shown as plain text.
 *
 * When panel.about.info is missing (method_not_found, forbidden, not_supported)
 * the page falls back to system.capabilities -> capabilities.wmux
 * {version, build, channel, platform}, if the kind allowlists it.
 *
 * The UI starts only when a document exists; the helpers are exported for tests.
 */
import { wmux } from "../_shared/wmux-bridge.js";
import "../_shared/theme.js";
import { installKeys } from "../_shared/keys.js";
import { applyStrings } from "../_shared/strings.js";
import { t } from "./strings.js";

const KNOWN_BUILD_KEYS = [
  "build_mode",
  "zig_version",
  "app_runtime",
  "renderer",
  "font_engine",
  "webview2_runtime",
  "os",
  "arch",
];
const FALLBACK_CODES = new Set(["method_not_found", "forbidden", "not_supported"]);
const MAX_VALUE_LENGTH = 300;
const MAX_TEXT_LENGTH = 4 * 1024 * 1024;

function displayValue(value) {
  if (typeof value === "string") {
    const text = value.trim();
    return text === "" ? null : text.slice(0, MAX_VALUE_LENGTH);
  }
  if (typeof value === "number" && isFinite(value)) return String(value);
  if (typeof value === "boolean") return String(value);
  return null;
}

function longText(value) {
  if (typeof value !== "string" || value.trim() === "") return null;
  return value.length > MAX_TEXT_LENGTH ? value.slice(0, MAX_TEXT_LENGTH) : value;
}

function licenseName(spdx) {
  if (!spdx || spdx.toUpperCase() === "MIT") return t("about.license.defaultName");
  return spdx;
}

function normalizeLicense(raw) {
  if (typeof raw === "string") {
    const spdx = displayValue(raw);
    return { spdx, name: licenseName(spdx), text: null };
  }
  const src = raw && typeof raw === "object" ? raw : {};
  const spdx = displayValue(src.spdx);
  return {
    spdx,
    name: displayValue(src.name) || licenseName(spdx),
    text: longText(src.text),
  };
}

/** An https URL without credentials, or null. */
export function safeHttpsUrl(value) {
  if (typeof value !== "string" || value.length > 2048) return null;
  try {
    const url = new URL(value.trim());
    if (url.protocol !== "https:" || url.username !== "" || url.password !== "") return null;
    return url.href;
  } catch {
    return null;
  }
}

/** Normalize a panel.about.info result (anything else yields placeholders). */
export function normalizeInfo(raw) {
  const src = raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
  const buildSrc =
    src.build && typeof src.build === "object" && !Array.isArray(src.build) ? src.build : {};
  const build = [];
  for (const key of KNOWN_BUILD_KEYS) {
    const value = displayValue(buildSrc[key]);
    if (value !== null) build.push([key, value]);
  }
  for (const key of Object.keys(buildSrc)) {
    if (KNOWN_BUILD_KEYS.indexOf(key) >= 0) continue;
    const value = displayValue(buildSrc[key]);
    if (value !== null) build.push([key.slice(0, 64), value]);
  }
  return {
    product: displayValue(src.product) || t("about.product"),
    version: displayValue(src.version),
    channel: displayValue(src.channel),
    commit: displayValue(src.commit),
    build,
    license: normalizeLicense(src.license),
    copyright: displayValue(src.copyright),
    homepage: safeHttpsUrl(src.homepage),
  };
}

/** Map a system.capabilities result to the panel.about.info shape. */
export function infoFromCapabilities(caps) {
  const inner = caps && caps.capabilities && caps.capabilities.wmux;
  const wm = inner && typeof inner === "object" ? inner : {};
  const build = {};
  if (wm.build !== undefined) build.build = wm.build;
  if (wm.platform !== undefined) build.platform = wm.platform;
  return { version: wm.version, channel: wm.channel, build };
}

/**
 * WebView2 runtime version from the user agent ("Edg/<version>"), or null.
 * Reduced user agents carry only the major version ("155.0.0.0" -> "155");
 * native supplies the exact version as build.webview2_runtime.
 */
export function webview2VersionFromUserAgent(userAgent) {
  const match = /\bEdg\/(\d+)((?:\.\d+)*)/.exec(typeof userAgent === "string" ? userAgent : "");
  if (!match) return null;
  return /^(\.0)*$/.test(match[2]) ? match[1] : match[1] + match[2];
}

/** Rows [key, value] shown under "Build information", in display order. */
export function buildRows(info, userAgent) {
  const rows = [];
  if (info.version) rows.push(["version", info.version]);
  if (info.channel) rows.push(["channel", info.channel]);
  if (info.commit) rows.push(["commit", info.commit]);
  for (const pair of info.build) rows.push(pair);
  if (!info.build.some((pair) => pair[0] === "webview2_runtime")) {
    const runtime = webview2VersionFromUserAgent(userAgent);
    if (runtime) rows.push(["webview2_runtime", runtime]);
  }
  return rows;
}

/** Localized label of a build row; unknown keys are shown as they are. */
export function rowLabel(key) {
  const id = "about.build." + key;
  const label = t(id);
  return label === id ? key : label;
}

/** Plain-text summary for "Copy version info" (bug reports). */
export function versionReport(info, rows) {
  const lines = [info.version ? info.product + " " + info.version : info.product];
  for (const pair of rows) {
    if (pair[0] !== "version") lines.push(rowLabel(pair[0]) + ": " + pair[1]);
  }
  return lines.join("\n");
}

/** Text of a panel.about.notices result, or "" when there is none. */
export function noticesText(result) {
  if (typeof result === "string") return longText(result) || "";
  if (result && typeof result === "object") return longText(result.text) || "";
  return "";
}

/**
 * Load the build information: panel.about.info, else system.capabilities.
 * @param {{call: Function}} [bridge] defaults to the page bridge
 */
export async function loadInfo(bridge) {
  const b = bridge || wmux;
  try {
    return normalizeInfo(await b.call("panel.about.info"));
  } catch (err) {
    if (!err || !FALLBACK_CODES.has(err.code)) throw err;
    let caps;
    try {
      caps = await b.call("system.capabilities");
    } catch {
      throw err;
    }
    return normalizeInfo(infoFromCapabilities(caps));
  }
}

function errorMessage(err) {
  return err && typeof err.message === "string" ? err.message : String(err);
}

/* ------------------------------------------------------------------------ */
/* UI                                                                         */
/* ------------------------------------------------------------------------ */

const current = { info: null, rows: [] };
let noticesLoaded = false;
let noticesLoading = false;

function element(id) {
  const el = document.getElementById(id);
  if (!el) throw new Error("about: missing #" + id);
  return el;
}

function findElements() {
  return {
    product: element("about-product"),
    version: element("about-version"),
    channel: element("about-channel"),
    build: element("about-build"),
    copy: element("about-copy"),
    licenseSummary: element("about-license-summary"),
    copyright: element("about-copyright"),
    licenseToggle: element("about-license-toggle"),
    licenseText: element("about-license-text"),
    noticesToggle: element("about-notices-toggle"),
    noticesText: element("about-notices-text"),
    homepage: element("about-homepage"),
    status: element("about-status"),
  };
}

function setStatus(ui, text, kind) {
  ui.status.textContent = text;
  ui.status.setAttribute("data-kind", kind);
}

function setExpanded(button, region, open, showKey, hideKey) {
  button.setAttribute("aria-expanded", open ? "true" : "false");
  button.textContent = t(open ? hideKey : showKey);
  region.hidden = !open;
}

function render(ui, info) {
  current.info = info;
  current.rows = buildRows(info, typeof navigator !== "undefined" ? navigator.userAgent : "");

  ui.product.textContent = info.product;
  ui.version.textContent = info.version
    ? t("about.version", { version: info.version })
    : t("about.versionUnknown");
  ui.channel.textContent = info.channel || "";
  ui.channel.hidden = !info.channel;

  const fragment = document.createDocumentFragment();
  for (const pair of current.rows) {
    const dt = document.createElement("dt");
    dt.textContent = rowLabel(pair[0]);
    const dd = document.createElement("dd");
    dd.textContent = pair[1];
    fragment.append(dt, dd);
  }
  ui.build.replaceChildren(fragment);

  ui.licenseSummary.textContent = t("about.license.summary", { license: info.license.name });
  ui.copyright.textContent = info.copyright || "";
  ui.copyright.hidden = !info.copyright;
  ui.licenseText.textContent = info.license.text || "";
  ui.licenseToggle.hidden = !info.license.text;
  setExpanded(ui.licenseToggle, ui.licenseText, false, "about.license.show", "about.license.hide");

  if (info.homepage) {
    ui.homepage.href = info.homepage;
    ui.homepage.hidden = false;
  } else {
    ui.homepage.hidden = true;
  }
}

async function copyVersion(ui) {
  const info = current.info || normalizeInfo(null);
  try {
    await wmux.panel.clipboardWrite(versionReport(info, current.rows));
    setStatus(ui, t("about.copied"), "info");
  } catch (err) {
    setStatus(ui, t("about.copyFailed", { message: errorMessage(err) }), "error");
  }
}

async function toggleNotices(ui) {
  const open = ui.noticesToggle.getAttribute("aria-expanded") !== "true";
  setExpanded(ui.noticesToggle, ui.noticesText, open, "about.notices.show", "about.notices.hide");
  if (!open || noticesLoaded || noticesLoading) return;

  noticesLoading = true;
  ui.noticesText.textContent = t("about.notices.loading");
  ui.noticesText.setAttribute("aria-busy", "true");
  try {
    const text = noticesText(await wmux.call("panel.about.notices"));
    ui.noticesText.textContent = text || t("about.notices.unavailable");
    noticesLoaded = text !== "";
  } catch (err) {
    ui.noticesText.textContent = t("about.notices.unavailable");
    if (wmux.available && !FALLBACK_CODES.has(err && err.code)) {
      setStatus(ui, errorMessage(err), "error");
    }
  } finally {
    noticesLoading = false;
    ui.noticesText.removeAttribute("aria-busy");
  }
}

async function openHomepage(ui) {
  const url = current.info && current.info.homepage;
  if (!url) return;
  try {
    await wmux.panel.openExternal(url);
  } catch (err) {
    setStatus(ui, t("about.openFailed", { message: errorMessage(err) }), "error");
  }
}

async function load(ui) {
  if (!wmux.available) {
    render(ui, normalizeInfo(null));
    setStatus(ui, t("about.status.offline"), "info");
    return;
  }
  try {
    await wmux.ready();
  } catch (err) {
    // Continue: kind-local calls can still succeed without panel.init.
    console.warn("[about] panel.ready failed:", errorMessage(err));
  }
  wmux.panel.setTitle(t("about.title")).catch(() => {});
  try {
    render(ui, await loadInfo());
    setStatus(ui, "", "info");
  } catch (err) {
    render(ui, normalizeInfo(null));
    setStatus(ui, t("about.status.error", { message: errorMessage(err) }), "error");
  }
}

function start() {
  const ui = findElements();
  applyStrings(document);
  document.title = t("about.title");
  installKeys();

  ui.copy.addEventListener("click", () => copyVersion(ui));
  ui.licenseToggle.addEventListener("click", () => {
    const open = ui.licenseToggle.getAttribute("aria-expanded") !== "true";
    setExpanded(ui.licenseToggle, ui.licenseText, open, "about.license.show", "about.license.hide");
  });
  ui.noticesToggle.addEventListener("click", () => toggleNotices(ui));
  ui.homepage.addEventListener("click", (event) => {
    event.preventDefault();
    openHomepage(ui);
  });

  load(ui);
}

if (typeof document !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
}
