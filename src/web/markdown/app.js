/**
 * Markdown panel application: PanelKind "markdown" (ARCHITECTURE ADR-6.11),
 * entry https://markdown.wmux.example/markdown/index.html. The native contract
 * (params, settings, methods, events) is documented in README.md.
 *
 *   const app = createApp({ document, libs: { markdownit, footnote, hljs, purify } });
 *   await app.start();
 *
 * Everything is injectable (document, bridge, libraries, mermaid loader) so the
 * jsdom tests in test/web-node/ drive the real code.
 */
import { wmux as defaultBridge } from "../_shared/wmux-bridge.js";
import { installKeys } from "../_shared/keys.js";
import { applyStrings } from "../_shared/strings.js";
import { currentTheme, onThemeChange } from "../_shared/theme.js";
import { createDiagrams } from "./diagrams.js";
import { createFind } from "./find.js";
import { DEFAULT_KEYMAP, SCROLL_ACTIONS, scrollTarget } from "./keymap.js";
import { basename, classifyLink, isServableImageUrl } from "./links.js";
import { createRenderer } from "./render.js";
import { t } from "./strings.js";
import {
  BUILTIN_DEFAULTS,
  LIMITS,
  adoptDefaults,
  fontFamilyCss,
  normalizeTypography,
  readDefaults,
  sameTypography,
  zoomFactor,
  zoomStep,
} from "./typography.js";

/** Error codes that mean "the file is gone" for panel.read_file. */
const MISSING_CODES = new Set(["file_not_found", "not_found"]);
/** Error codes that mean "native does not implement this method". */
const UNSUPPORTED_CODES = new Set(["method_not_found", "not_supported", "forbidden"]);
/** read_file errors that are not retried. */
const FINAL_READ_CODES = new Set([
  "file_not_found",
  "not_found",
  "forbidden",
  "method_not_found",
  "not_supported",
  "invalid_params",
]);
const READ_RETRIES = 3;
const READ_RETRY_DELAY_MS = 150;
const XLINK_NS = "http://www.w3.org/1999/xlink";
const STATUS_MS = 2500;
const COPIED_MS = 1200;
const STATE_DEBOUNCE_MS = 400;
const MAX_APPROVED_IMAGES = 200;
const MAX_APPROVED_CHARS = 32768;
const MAX_RESOLVE_BATCH = 200;
const FALLBACK_FONTS = [
  "Segoe UI",
  "Calibri",
  "Cambria",
  "Candara",
  "Georgia",
  "Verdana",
  "Arial",
  "Times New Roman",
  "Consolas",
  "Cascadia Code",
];

function errorMessage(err) {
  return err && typeof err.message === "string" ? err.message : String(err);
}

function errorCode(err) {
  return err && typeof err.code === "string" ? err.code : "";
}

/** Text as a <textarea> reports it: CRLF and lone CR line breaks become LF. */
function editorText(text) {
  return text.includes("\r") ? text.replace(/\r\n?/g, "\n") : text;
}

/** The line break a file uses: CRLF when its first line break is CRLF, else LF. */
function lineBreakOf(text) {
  const lf = text.indexOf("\n");
  return lf > 0 && text[lf - 1] === "\r" ? "\r\n" : "\n";
}

/**
 * @param {{
 *   document?: Document,
 *   bridge?: object,
 *   libs: {markdownit: Function, footnote?: Function, hljs?: object, purify: object},
 *   loadMermaid?: () => Promise<object>,
 *   installKeys?: Function,
 *   readyTimeoutMs?: number,
 * }} options
 */
export function createApp(options) {
  const doc = options.document || globalThis.document;
  const view = doc.defaultView || globalThis;
  const bridge = options.bridge || defaultBridge;
  const renderer = createRenderer({ ...options.libs, document: doc });
  const diagrams = createDiagrams({
    document: doc,
    purify: options.libs.purify,
    loadMermaid: options.loadMermaid,
    scheme: () => currentScheme(),
  });
  const cleanups = [];
  const timers = new Set();

  const ui = findElements(doc);

  const state = {
    started: false,
    destroyed: false,
    params: {},
    path: "",
    displayPath: "",
    baseUrl: null,
    encoding: null,
    diskText: "",
    available: null, // null = loading, true, false = "File unavailable"
    mode: "preview",
    dirty: false,
    saving: false,
    deletedOnDisk: false,
    loadSeq: 0,
    renderSeq: 0,
    defaults: { ...BUILTIN_DEFAULTS },
    typography: { ...BUILTIN_DEFAULTS },
    approvedImages: new Set(),
    resolvedPaths: new Map(), // path -> true/false (per page load)
    findOpen: false,
    fonts: null,
    lastScheme: null,
  };

  const find = createFind(ui.content, {
    onChange: (s) => updateFindCount(s),
    scroll: (el) => scrollIntoView(el, "center"),
  });

  /* ---------------------------------------------------------------------- */
  /* helpers                                                                */
  /* ---------------------------------------------------------------------- */

  function later(fn, ms) {
    const id = view.setTimeout(() => {
      timers.delete(id);
      fn();
    }, ms);
    timers.add(id);
    return id;
  }

  function cancel(id) {
    if (id) {
      view.clearTimeout(id);
      timers.delete(id);
    }
  }

  function listen(target, type, fn, opts) {
    target.addEventListener(type, fn, opts);
    cleanups.push(() => target.removeEventListener(type, fn, opts));
  }

  function reducedMotion() {
    const root = doc.documentElement;
    if (root.getAttribute("data-wmux-reduced-motion") === "true") return true;
    return (
      typeof view.matchMedia === "function" &&
      view.matchMedia("(prefers-reduced-motion: reduce)").matches
    );
  }

  function currentScheme() {
    const theme = currentTheme();
    if (theme && theme.scheme) return theme.scheme;
    return doc.documentElement.getAttribute("data-wmux-scheme") === "light" ? "light" : "dark";
  }

  function scrollIntoView(el, block) {
    if (typeof el.scrollIntoView === "function") {
      el.scrollIntoView({ block, inline: "nearest", behavior: reducedMotion() ? "auto" : "smooth" });
    }
  }

  let statusTimer = 0;
  function setStatus(text, kind, sticky) {
    cancel(statusTimer);
    ui.status.textContent = text || "";
    ui.status.setAttribute("data-kind", kind || "info");
    if (text && !sticky) statusTimer = later(() => setStatus("", "info", true), STATUS_MS);
  }

  async function clipboardWrite(text, html) {
    if (bridge.available) return bridge.panel.clipboardWrite(text, html);
    const nav = view.navigator;
    if (nav && nav.clipboard && typeof nav.clipboard.writeText === "function") {
      return nav.clipboard.writeText(text);
    }
    throw new Error(t("markdown.status.offline"));
  }

  function call(method, params) {
    return bridge.call(method, params);
  }

  /* ---------------------------------------------------------------------- */
  /* session state                                                          */
  /* ---------------------------------------------------------------------- */

  let stateTimer = 0;

  /** Newest approvals that fit the budget (panel.state_changed is capped at 64 KiB). */
  function approvedForState() {
    const all = Array.from(state.approvedImages);
    const out = [];
    let chars = 0;
    for (let i = all.length - 1; i >= 0 && out.length < MAX_APPROVED_IMAGES; i -= 1) {
      chars += all[i].length + 3;
      if (chars > MAX_APPROVED_CHARS) break;
      out.unshift(all[i]);
    }
    return out;
  }

  /** Send the session state now, replacing a pending debounced save. */
  function flushState() {
    cancel(stateTimer);
    stateTimer = 0;
    if (!bridge.available) return;
    const snapshot = {
      v: 1,
      display_mode: state.mode,
      typography: { ...state.typography },
      approved_images: approvedForState(),
      find: find.needle || "",
    };
    bridge.panel.setState(snapshot).catch((err) => {
      console.warn("[markdown] panel.state_changed failed:", errorMessage(err));
    });
  }

  function saveState() {
    if (!bridge.available) return;
    cancel(stateTimer);
    stateTimer = later(flushState, STATE_DEBOUNCE_MS);
  }

  function restoreState(saved) {
    if (!saved || typeof saved !== "object") return;
    if (saved.display_mode === "text" || saved.display_mode === "preview") {
      state.mode = saved.display_mode;
    }
    if (saved.typography && typeof saved.typography === "object") {
      state.typography = normalizeTypography(saved.typography, state.defaults);
    }
    if (Array.isArray(saved.approved_images)) {
      for (const url of saved.approved_images.slice(-MAX_APPROVED_IMAGES)) {
        if (typeof url === "string" && /^https?:\/\//i.test(url)) state.approvedImages.add(url);
      }
    }
  }

  /* ---------------------------------------------------------------------- */
  /* typography                                                             */
  /* ---------------------------------------------------------------------- */

  function applyTypography() {
    const style = ui.content.style;
    const typo = state.typography;
    style.setProperty("--mdv-zoom", String(zoomFactor(typo.fontSize)));
    style.setProperty("--mdv-max-width", typo.maxWidth + "px");
    const family = fontFamilyCss(typo.fontFamily);
    if (family) style.setProperty("--mdv-font-family", family);
    else style.removeProperty("--mdv-font-family");
    ui.content.setAttribute("data-font-size", String(typo.fontSize));
    syncTypographyForm();
  }

  function setTypography(next, persist) {
    const normalized = normalizeTypography(next, state.typography);
    if (sameTypography(normalized, state.typography)) {
      syncTypographyForm();
      return;
    }
    state.typography = normalized;
    applyTypography();
    if (persist !== false) saveState();
  }

  function applyDefaults(settings) {
    const next = readDefaults(settings);
    const previous = state.defaults;
    state.defaults = next;
    setTypography(adoptDefaults(state.typography, previous, next));
  }

  function zoom(delta) {
    if (delta === 0) setTypography({ ...state.typography, fontSize: state.defaults.fontSize });
    else setTypography({ ...state.typography, fontSize: zoomStep(state.typography.fontSize, delta) });
  }

  function syncTypographyForm() {
    ui.fontSize.value = String(state.typography.fontSize);
    ui.maxWidth.value = String(state.typography.maxWidth);
    ensureFontOption(state.typography.fontFamily);
    ui.fontFamily.value = state.typography.fontFamily;
  }

  function ensureFontOption(family) {
    const values = Array.from(ui.fontFamily.options).map((o) => o.value);
    if (!values.includes("")) {
      const system = doc.createElement("option");
      system.value = "";
      system.textContent = t("markdown.typo.system");
      ui.fontFamily.prepend(system);
    }
    if (family && !values.includes(family)) {
      const option = doc.createElement("option");
      option.value = family;
      option.textContent = family;
      ui.fontFamily.append(option);
    }
  }

  async function loadFonts() {
    if (state.fonts) return;
    let families = FALLBACK_FONTS;
    if (bridge.available) {
      try {
        const result = await call("panel.markdown.list_fonts", {});
        if (result && Array.isArray(result.families)) {
          families = result.families.filter((f) => typeof f === "string" && f.trim() !== "");
        }
      } catch {
        // Keep the fallback list.
      }
    }
    state.fonts = Array.from(new Set(families.map((f) => f.trim().slice(0, 128)))).sort((a, b) =>
      a.localeCompare(b),
    );
    const options = [];
    const system = doc.createElement("option");
    system.value = "";
    system.textContent = t("markdown.typo.system");
    options.push(system);
    for (const family of state.fonts) {
      const option = doc.createElement("option");
      option.value = family;
      option.textContent = family;
      options.push(option);
    }
    ui.fontFamily.replaceChildren(...options);
    syncTypographyForm();
  }

  function toggleTypography(open) {
    const show = open === undefined ? ui.typoPopover.hidden : open;
    ui.typoPopover.hidden = !show;
    ui.typoButton.setAttribute("aria-expanded", show ? "true" : "false");
    if (show) {
      syncTypographyForm();
      loadFonts();
      ui.fontFamily.focus();
    }
  }

  async function setAsDefault() {
    const values = { ...state.typography };
    try {
      await call("panel.markdown.set_defaults", values);
      state.defaults = values;
      setStatus(t("markdown.typo.savedDefault"), "info");
    } catch (err) {
      setStatus(t("markdown.typo.saveDefaultFailed", { message: errorMessage(err) }), "error");
    }
  }

  /* ---------------------------------------------------------------------- */
  /* loading and live reload                                                */
  /* ---------------------------------------------------------------------- */

  function sleep(ms) {
    return new Promise((resolve) => later(resolve, ms));
  }

  async function readFile() {
    let lastError = null;
    for (let attempt = 0; attempt <= READ_RETRIES; attempt += 1) {
      try {
        return await call("panel.read_file", {});
      } catch (err) {
        lastError = err;
        if (FINAL_READ_CODES.has(errorCode(err)) || attempt === READ_RETRIES) break;
        await sleep(READ_RETRY_DELAY_MS * (attempt + 1));
      }
    }
    throw lastError;
  }

  function acceptFileMeta(result) {
    if (!result || typeof result !== "object") return;
    if (typeof result.encoding === "string") state.encoding = result.encoding;
    if (typeof result.base_url === "string") state.baseUrl = result.base_url;
    if (typeof result.path === "string" && !state.path) state.path = result.path;
    if (typeof result.display_path === "string") state.displayPath = result.display_path;
  }

  /** Read the file from disk; only the newest request is applied. */
  async function reload(reason) {
    if (!bridge.available) return;
    const seq = ++state.loadSeq;
    try {
      const result = await readFile();
      if (seq !== state.loadSeq || state.destroyed) return;
      acceptFileMeta(result);
      const text = result && typeof result.text === "string" ? result.text : "";
      applyText(text, reason);
    } catch (err) {
      if (seq !== state.loadSeq || state.destroyed) return;
      markUnavailable();
      if (!MISSING_CODES.has(errorCode(err))) {
        setStatus(t("markdown.status.loadFailed", { message: errorMessage(err) }), "error");
      }
    }
  }

  /** New disk contents (initial load, live reload, revert). */
  function applyText(text, reason) {
    const wasUnavailable = state.available === false;
    state.diskText = text;
    state.available = true;
    state.deletedOnDisk = false;
    if (reason === "revert") {
      // Revert discards the unsaved buffer, whichever mode is showing now.
      ui.editor.value = text;
      setDirty(false);
      setStatus("");
    }
    showBody();
    if (state.dirty) {
      // Never replace unsaved edits: the editor and the preview keep the buffer.
      setStatus(t("markdown.status.changedOnDisk"), "warning", true);
      return;
    }
    if (state.mode === "text") {
      ui.editor.value = text;
      setDirty(false);
      if (ui.status.getAttribute("data-kind") === "warning") setStatus("");
      return;
    }
    renderPreview(reason !== "initial" && !wasUnavailable);
  }

  function markUnavailable() {
    if (state.dirty) {
      // Unsaved edits stay on screen in either mode (the preview renders the
      // buffer); Save writes the file again.
      state.deletedOnDisk = true;
      setStatus(t("markdown.status.deletedOnDisk"), "warning", true);
      return;
    }
    state.available = false;
    ui.unavailablePath.textContent = state.displayPath || state.path || "";
    showBody();
  }

  function onFileChanged(payload) {
    const p = payload && typeof payload === "object" ? payload : {};
    const status = typeof p.status === "string" ? p.status : "changed";
    if (status === "deleted" || status === "unavailable" || status === "missing") {
      state.loadSeq += 1; // drop reads in flight
      markUnavailable();
      return;
    }
    if (typeof p.text === "string") {
      state.loadSeq += 1;
      acceptFileMeta(p);
      applyText(p.text, "reload");
    } else {
      reload("reload");
    }
  }

  /* ---------------------------------------------------------------------- */
  /* preview                                                                */
  /* ---------------------------------------------------------------------- */

  function sourceText() {
    return state.dirty ? ui.editor.value : state.diskText;
  }

  /** First element with an id at or below the top of the viewport, for scroll anchoring. */
  function captureAnchor() {
    const top = ui.viewport.getBoundingClientRect().top;
    for (const el of ui.content.querySelectorAll("[id]")) {
      const rect = el.getBoundingClientRect();
      if (rect.bottom > top) return { id: el.id, offset: rect.top - top, scrollTop: ui.viewport.scrollTop };
    }
    return { id: null, offset: 0, scrollTop: ui.viewport.scrollTop };
  }

  function restoreAnchor(anchor) {
    if (!anchor) return;
    const el = anchor.id ? findById(anchor.id) : null;
    if (el) {
      const top = ui.viewport.getBoundingClientRect().top;
      ui.viewport.scrollTop += el.getBoundingClientRect().top - top - anchor.offset;
    } else {
      ui.viewport.scrollTop = anchor.scrollTop;
    }
  }

  function findById(id) {
    for (const el of ui.content.querySelectorAll("[id], a[name]")) {
      if (el.id === id || el.getAttribute("name") === id) return el;
    }
    return null;
  }

  /**
   * Render the current source into the preview.
   * @param {boolean} preserveScroll keep the reading position (live reload)
   */
  function renderPreview(preserveScroll) {
    const seq = ++state.renderSeq;
    const anchor = preserveScroll ? captureAnchor() : null;
    diagrams.reset();
    const out = renderer.render(sourceText(), {
      baseUrl: state.baseUrl,
      approvedImages: state.approvedImages,
    });
    ui.content.replaceChildren(out.fragment);
    state.lastScheme = currentScheme();
    if (find.needle) find.refresh();
    restoreAnchor(anchor);
    resolveImages(out.imageRequests, seq);
    resolveCodePaths(seq);
    diagrams
      .render(ui.content)
      .then(() => {
        if (seq === state.renderSeq && find.needle) find.refresh();
      })
      .catch((err) => console.warn("[markdown] diagram rendering failed:", errorMessage(err)));
    return out;
  }

  async function resolveImages(requests, seq) {
    if (!requests.length || !bridge.available) return;
    for (const { img, path } of requests) {
      try {
        const result = await call("panel.markdown.resolve_image", { path });
        if (seq !== state.renderSeq) return;
        const url = result && result.url;
        if (isServableImageUrl(url)) img.setAttribute("src", url);
      } catch (err) {
        if (UNSUPPORTED_CODES.has(errorCode(err))) return;
      }
    }
  }

  function markPath(code, exists) {
    if (exists) {
      code.setAttribute("data-mdv-file-exists", "true");
      code.setAttribute("role", "link");
      code.setAttribute("tabindex", "0");
      code.setAttribute("title", t("markdown.link.openFile", { path: code.getAttribute("data-mdv-path") }));
    } else {
      code.setAttribute("data-mdv-file-exists", "false");
    }
  }

  async function resolveCodePaths(seq) {
    const codes = Array.from(ui.content.querySelectorAll("code[data-mdv-path]"));
    if (!codes.length) return;
    const unknown = [];
    for (const code of codes) {
      const path = code.getAttribute("data-mdv-path");
      if (state.resolvedPaths.has(path)) markPath(code, state.resolvedPaths.get(path));
      else if (!unknown.includes(path)) unknown.push(path);
    }
    if (!unknown.length || !bridge.available) return;
    const batch = unknown.slice(0, MAX_RESOLVE_BATCH);
    let result;
    try {
      result = await call("panel.markdown.resolve_links", { paths: batch });
    } catch {
      return;
    }
    const exists = result && result.exists && typeof result.exists === "object" ? result.exists : {};
    for (const path of batch) state.resolvedPaths.set(path, exists[path] === true);
    if (seq !== state.renderSeq) return;
    for (const code of codes) {
      const path = code.getAttribute("data-mdv-path");
      if (state.resolvedPaths.has(path)) markPath(code, state.resolvedPaths.get(path));
    }
  }

  /* ---------------------------------------------------------------------- */
  /* modes                                                                  */
  /* ---------------------------------------------------------------------- */

  function showBody() {
    const unavailable = state.available === false;
    ui.unavailable.hidden = !unavailable;
    ui.content.hidden = unavailable || state.mode !== "preview";
    ui.editor.hidden = unavailable || state.mode !== "text";
    ui.root.setAttribute("data-mode", state.mode);
    ui.root.setAttribute("data-available", unavailable ? "false" : "true");
    ui.mode.textContent = t(state.mode === "text" ? "markdown.showPreview" : "markdown.showText");
    ui.mode.setAttribute("aria-pressed", state.mode === "text" ? "true" : "false");
    ui.revert.hidden = state.mode !== "text";
    ui.save.hidden = state.mode !== "text";
    ui.refresh.hidden = state.mode !== "preview";
    ui.findToggle.disabled = state.mode !== "preview" || unavailable;
    updateEditorButtons();
  }

  function updateEditorButtons() {
    ui.revert.disabled = !state.dirty || state.saving;
    ui.save.disabled = (!state.dirty && !state.deletedOnDisk) || state.saving;
  }

  function setDirty(dirty) {
    if (state.dirty === dirty) {
      updateEditorButtons();
      return;
    }
    state.dirty = dirty;
    updateEditorButtons();
    if (bridge.available) {
      bridge.panel.setDirty(dirty).catch(() => {});
    }
  }

  function setMode(mode) {
    if (mode !== "preview" && mode !== "text") return;
    if (mode === state.mode) return;
    state.mode = mode;
    if (mode === "text") {
      closeFind();
      toggleTypography(false);
      if (!state.dirty) ui.editor.value = state.diskText;
      showBody();
      ui.editor.focus();
    } else {
      showBody();
      if (state.available !== false) renderPreview(false);
      ui.viewport.focus();
    }
    saveState();
  }

  async function save() {
    if (state.mode !== "text" || state.saving) return;
    if (!state.dirty && !state.deletedOnDisk) return;
    const text = ui.editor.value;
    // The textarea reports LF line breaks. Write the file's own style back so
    // saving a CRLF file (usual on Windows) does not rewrite every line ending.
    const out = lineBreakOf(state.diskText) === "\r\n" ? editorText(text).replace(/\n/g, "\r\n") : text;
    state.saving = true;
    updateEditorButtons();
    try {
      const params = { text: out };
      if (state.encoding) params.encoding = state.encoding;
      const result = await call("panel.write_file", params);
      if (result && typeof result.encoding === "string") state.encoding = result.encoding;
      state.diskText = out;
      state.deletedOnDisk = false;
      state.available = true;
      setDirty(ui.editor.value !== text);
      setStatus(t("markdown.status.saved"), "info");
    } catch (err) {
      setStatus(t("markdown.status.saveFailed", { message: errorMessage(err) }), "error", true);
    } finally {
      state.saving = false;
      updateEditorButtons();
    }
  }

  async function revert() {
    if (state.mode !== "text") return;
    const seq = ++state.loadSeq;
    try {
      const result = await readFile();
      if (seq !== state.loadSeq || state.destroyed) return;
      acceptFileMeta(result);
      applyText(result && typeof result.text === "string" ? result.text : "", "revert");
    } catch (err) {
      setStatus(t("markdown.status.loadFailed", { message: errorMessage(err) }), "error");
    }
  }

  /* ---------------------------------------------------------------------- */
  /* find                                                                   */
  /* ---------------------------------------------------------------------- */

  function updateFindCount(s) {
    ui.findCount.textContent = s.needle
      ? t("markdown.find.count", { current: s.current, total: s.total })
      : "";
    ui.findCount.setAttribute("data-empty", s.needle && s.total === 0 ? "true" : "false");
  }

  function openFind(query) {
    if (state.mode !== "preview" || state.available === false) {
      setStatus(t("markdown.find.unavailable"), "info");
      return false;
    }
    state.findOpen = true;
    ui.find.hidden = false;
    if (typeof query === "string") {
      ui.findInput.value = query;
      find.search(query);
      saveState();
    } else if (!find.needle && ui.findInput.value) {
      // Reopened (Ctrl+F after Escape): the field still shows the last query,
      // so search for it again instead of showing it without highlights.
      find.search(ui.findInput.value);
    }
    ui.findInput.focus();
    if (typeof ui.findInput.select === "function") ui.findInput.select();
    return true;
  }

  function closeFind() {
    if (!state.findOpen && ui.find.hidden) return;
    state.findOpen = false;
    ui.find.hidden = true;
    find.clear();
    saveState();
    if (state.mode === "preview") ui.viewport.focus();
  }

  /* ---------------------------------------------------------------------- */
  /* links, code copy, remote images                                        */
  /* ---------------------------------------------------------------------- */

  function scrollToAnchor(id) {
    const el = findById(id);
    if (el) scrollIntoView(el, "start");
  }

  async function openMarkdown(path, fragment) {
    try {
      await call("panel.markdown.open", fragment ? { path, fragment } : { path });
    } catch (err) {
      const code = errorCode(err);
      if (UNSUPPORTED_CODES.has(code)) {
        await bridge.panel.openFile(path);
      } else if (MISSING_CODES.has(code)) {
        setStatus(t("markdown.link.notFound", { path }), "error");
      } else {
        throw err;
      }
    }
  }

  /** Route a link target (the href attribute) per README "Link routing". */
  async function routeLink(href) {
    const target = classifyLink(href);
    if (target.action === "none") return target;
    if (target.action === "anchor") {
      scrollToAnchor(target.id);
      return target;
    }
    if (!bridge.available) {
      setStatus(t("markdown.status.offline"), "info");
      return target;
    }
    try {
      if (target.action === "browser") await bridge.panel.openInBrowser(target.url);
      else if (target.action === "external") await bridge.panel.openExternal(target.url);
      else if (target.action === "markdown") await openMarkdown(target.path, target.fragment);
      else if (target.action === "file") await bridge.panel.openFile(target.path);
    } catch (err) {
      setStatus(t("markdown.link.failed", { message: errorMessage(err) }), "error");
    }
    return target;
  }

  function flashButton(button, text) {
    const original = button.getAttribute("data-label") || button.textContent;
    button.setAttribute("data-label", original);
    button.textContent = text;
    later(() => {
      button.textContent = original;
      button.removeAttribute("data-label");
    }, COPIED_MS);
  }

  async function copyCode(button) {
    const code = button.parentElement && button.parentElement.querySelector("pre > code");
    if (!code) return;
    try {
      await clipboardWrite(code.textContent);
      flashButton(button, t("markdown.copied"));
    } catch (err) {
      setStatus(t("markdown.copyFailed", { message: errorMessage(err) }), "error");
    }
  }

  async function imageAction(button) {
    const box = button.closest(".wmux-remote-image");
    if (!box) return;
    const url = box.getAttribute("data-url");
    const action = button.getAttribute("data-image-action");
    if (action === "copy") {
      try {
        await clipboardWrite(url);
        flashButton(button, t("markdown.copied"));
      } catch (err) {
        setStatus(t("markdown.copyFailed", { message: errorMessage(err) }), "error");
      }
    } else if (action === "open") {
      await routeLink(url);
    } else if (action === "load") {
      // A meta CSP cannot be relaxed in place: native allows the URL by
      // reloading the page with a rewritten CSP, so the approval must already
      // be in the panel state that the reloaded page gets in panel.init.
      const added = !state.approvedImages.has(url);
      state.approvedImages.add(url);
      flushState();
      try {
        await call("panel.markdown.approve_remote_image", { url });
      } catch (err) {
        if (added) {
          state.approvedImages.delete(url);
          flushState();
        }
        setStatus(t("markdown.image.loadFailed", { message: errorMessage(err) }), "error");
        return;
      }
      for (const other of Array.from(ui.content.querySelectorAll(".wmux-remote-image"))) {
        if (other.getAttribute("data-url") !== url) continue;
        const img = doc.createElement("img");
        img.setAttribute("src", url);
        img.setAttribute("alt", other.getAttribute("data-alt") || "");
        img.setAttribute("referrerpolicy", "no-referrer");
        other.replaceWith(img);
      }
    }
  }

  function exportHtml() {
    const clone = ui.content.cloneNode(true);
    for (const el of clone.querySelectorAll(".mdv-copy-code, .wmux-source, .wmux-remote-image-actions")) {
      el.remove();
    }
    for (const mark of clone.querySelectorAll("mark.mdv-find-match")) {
      mark.replaceWith(...mark.childNodes);
    }
    for (const block of clone.querySelectorAll(".mdv-code-block")) {
      block.replaceWith(...block.childNodes);
    }
    clone.normalize();
    return { html: clone.innerHTML, text: clone.textContent };
  }

  async function copyAsMarkdown() {
    try {
      await clipboardWrite(state.mode === "text" ? ui.editor.value : sourceText());
      setStatus(t("markdown.copiedMarkdown"), "info");
    } catch (err) {
      setStatus(t("markdown.copyFailed", { message: errorMessage(err) }), "error");
    }
  }

  async function copyAsHtml() {
    try {
      if (state.mode === "text") renderPreview(false);
      const out = exportHtml();
      await clipboardWrite(out.text, out.html);
      setStatus(t("markdown.copiedHtml"), "info");
    } catch (err) {
      setStatus(t("markdown.copyFailed", { message: errorMessage(err) }), "error");
    }
  }

  /* ---------------------------------------------------------------------- */
  /* keyboard                                                               */
  /* ---------------------------------------------------------------------- */

  function scrollBy(action) {
    if (state.mode !== "preview") return;
    const vp = ui.viewport;
    const top = scrollTarget(action, {
      top: vp.scrollTop,
      height: vp.clientHeight,
      max: vp.scrollHeight - vp.clientHeight,
    });
    if (top === null) return;
    if (typeof vp.scrollTo === "function" && !reducedMotion()) {
      vp.scrollTo({ top, behavior: "smooth" });
    } else {
      vp.scrollTop = top;
    }
  }

  const actions = {
    markdownZoomIn: () => zoom(1),
    markdownZoomOut: () => zoom(-1),
    markdownZoomReset: () => zoom(0),
    find: () => openFind(),
    findNext: () => {
      if (state.findOpen) find.next();
    },
    findPrevious: () => {
      if (state.findOpen) find.previous();
    },
    hideFind: () => {
      if (!ui.typoPopover.hidden) {
        toggleTypography(false);
        ui.typoButton.focus(); // the focused control was inside the popover
      } else {
        closeFind();
      }
    },
    saveFilePreview: () => save(),
    "wmux.markdownTogglePreview": () => setMode(state.mode === "text" ? "preview" : "text"),
    "wmux.markdownRefresh": () => reload("reload"),
  };
  for (const id of SCROLL_ACTIONS) actions[id] = () => scrollBy(id);

  /** Run a panel action by id (keyboard, panel.markdown.command). Returns whether it exists. */
  function runAction(id) {
    const fn = Object.prototype.hasOwnProperty.call(actions, id) ? actions[id] : null;
    if (!fn) return false;
    fn();
    return true;
  }

  /* ---------------------------------------------------------------------- */
  /* wiring                                                                 */
  /* ---------------------------------------------------------------------- */

  function wireDom() {
    listen(ui.refresh, "click", () => reload("reload"));
    listen(ui.mode, "click", () => setMode(state.mode === "text" ? "preview" : "text"));
    listen(ui.revert, "click", () => revert());
    listen(ui.save, "click", () => save());
    listen(ui.findToggle, "click", () => (state.findOpen ? closeFind() : openFind()));
    listen(ui.copyMarkdown, "click", () => copyAsMarkdown());
    listen(ui.copyHtml, "click", () => copyAsHtml());
    listen(ui.typoButton, "click", () => toggleTypography());

    listen(ui.editor, "input", () => {
      setDirty(ui.editor.value !== editorText(state.diskText) || state.deletedOnDisk);
    });

    listen(ui.findInput, "input", () => {
      find.search(ui.findInput.value);
      saveState();
    });
    listen(ui.findInput, "keydown", (e) => {
      if (e.key === "Enter" && !e.isComposing) {
        e.preventDefault();
        if (e.shiftKey) find.previous();
        else find.next();
      } else if (e.key === "Escape") {
        e.preventDefault();
        closeFind();
      }
    });
    listen(ui.findPrev, "click", () => find.previous());
    listen(ui.findNext, "click", () => find.next());
    listen(ui.findClose, "click", () => closeFind());

    const typoField = (input, key) =>
      listen(input, "change", () => setTypography({ ...state.typography, [key]: input.value }));
    typoField(ui.fontFamily, "fontFamily");
    typoField(ui.fontSize, "fontSize");
    typoField(ui.maxWidth, "maxWidth");
    listen(ui.resetDefault, "click", () => setTypography({ ...state.defaults }));
    listen(ui.resetBuiltin, "click", () => setTypography({ ...BUILTIN_DEFAULTS }));
    listen(ui.setDefault, "click", () => setAsDefault());
    listen(ui.typoPopover, "keydown", (e) => {
      if (e.key === "Escape") {
        e.preventDefault();
        toggleTypography(false);
        ui.typoButton.focus();
      }
    });
    listen(doc, "mousedown", (e) => {
      if (ui.typoPopover.hidden) return;
      if (ui.typoPopover.contains(e.target) || ui.typoButton.contains(e.target)) return;
      toggleTypography(false);
    });

    listen(ui.content, "click", (e) => onContentClick(e));
    listen(ui.content, "auxclick", (e) => {
      if (e.button === 1 && linkTarget(eventElement(e)) !== null) onContentClick(e);
    });
    listen(ui.content, "keydown", (e) => {
      if (e.key !== "Enter") return;
      const code = e.target.closest && e.target.closest('code[data-mdv-file-exists="true"]');
      if (code) {
        e.preventDefault();
        routeLink(code.getAttribute("data-mdv-path"));
      }
    });
  }

  function eventElement(e) {
    return e.target && e.target.nodeType === 1 ? e.target : e.target && e.target.parentElement;
  }

  /**
   * The target of the link a click landed in, or null: HTML and SVG <a href>,
   * SVG <a xlink:href> and image-map <area href>. Anything left to the browser
   * would navigate the panel itself (same-origin targets are not cancelled).
   */
  function linkTarget(start) {
    for (let el = start; el && el !== ui.content; el = el.parentElement) {
      if (el.localName !== "a" && el.localName !== "area") continue;
      const href = el.hasAttribute("href") ? el.getAttribute("href") : el.getAttributeNS(XLINK_NS, "href");
      if (href !== null) return href;
    }
    return null;
  }

  function onContentClick(e) {
    const target = eventElement(e);
    if (!target) return;
    const copy = target.closest("button.mdv-copy-code");
    if (copy) {
      e.preventDefault();
      copyCode(copy);
      return;
    }
    const imageButton = target.closest("button[data-image-action]");
    if (imageButton) {
      e.preventDefault();
      imageAction(imageButton);
      return;
    }
    const href = ui.content.contains(target) ? linkTarget(target) : null;
    if (href !== null) {
      e.preventDefault();
      routeLink(href);
      return;
    }
    const code = target.closest('code[data-mdv-file-exists="true"]');
    if (code) {
      e.preventDefault();
      routeLink(code.getAttribute("data-mdv-path"));
    }
  }

  function wireBridge() {
    cleanups.push(
      bridge.on("panel.markdown.file_changed", (payload) => onFileChanged(payload)),
      bridge.on("panel.markdown.settings", (payload) => applyDefaults(payload)),
      bridge.on("panel.markdown.command", (payload) => {
        if (payload && typeof payload.action === "string") runAction(payload.action);
      }),
      bridge.on("panel.markdown.find", (payload) => {
        const query = payload && typeof payload.query === "string" ? payload.query : "";
        if (state.mode === "text") setMode("preview");
        openFind(query);
      }),
    );
    cleanups.push(
      onThemeChange((theme) => {
        applyHighlightTheme(theme.scheme);
        if (state.lastScheme && theme.scheme !== state.lastScheme && state.mode === "preview") {
          if (ui.content.querySelector(".wmux-mermaid") && state.available) renderPreview(true);
          state.lastScheme = theme.scheme;
        }
      }),
    );
  }

  function applyHighlightTheme(scheme) {
    const light = scheme === "light";
    if (ui.hljsLight) ui.hljsLight.media = light ? "all" : "not all";
    if (ui.hljsDark) ui.hljsDark.media = light ? "not all" : "all";
  }

  function installKeyboard() {
    const keys = (options.installKeys || installKeys)();
    keys.setKeymap(DEFAULT_KEYMAP);
    if (bridge.context && bridge.context.keymap !== undefined) keys.setKeymap(bridge.context.keymap);
    for (const id of Object.keys(actions)) {
      cleanups.push(keys.handle(id, () => runAction(id)));
    }
    return keys;
  }

  /* ---------------------------------------------------------------------- */
  /* start                                                                  */
  /* ---------------------------------------------------------------------- */

  function applyInit(ctx) {
    const params = ctx && ctx.params && typeof ctx.params === "object" ? ctx.params : {};
    state.params = params;
    state.path = typeof params.path === "string" ? params.path : "";
    state.displayPath = typeof params.display_path === "string" ? params.display_path : state.path;
    if (typeof params.base_url === "string") state.baseUrl = params.base_url;
    if (typeof params.encoding === "string") state.encoding = params.encoding;

    state.defaults = readDefaults(ctx && ctx.settings);
    state.typography = { ...state.defaults };
    if (params.font_size !== undefined) {
      state.typography = normalizeTypography(
        { ...state.typography, fontSize: params.font_size },
        state.defaults,
      );
    }
    if (params.display_mode === "text" || params.display_mode === "preview") state.mode = params.display_mode;
    restoreState(ctx && ctx.state);

    const settings = ctx && ctx.settings && typeof ctx.settings === "object" ? ctx.settings : {};
    const wrap = settings["fileEditor.wordWrap"];
    ui.editor.setAttribute("wrap", wrap === false ? "off" : "soft");
  }

  async function start() {
    if (state.started) return api;
    state.started = true;
    applyStrings(doc);
    applyHighlightTheme(currentScheme());
    ui.fontSize.min = String(LIMITS.fontSize.min);
    ui.fontSize.max = String(LIMITS.fontSize.max);
    ui.maxWidth.min = String(LIMITS.maxWidth.min);
    ui.maxWidth.max = String(LIMITS.maxWidth.max);
    ui.maxWidth.step = String(LIMITS.maxWidth.step);
    wireDom();
    wireBridge();
    const keys = installKeyboard();
    applyTypography();
    showBody();

    if (!bridge.available) {
      setStatus(t("markdown.status.offline"), "info", true);
      state.available = true;
      renderPreview(false);
      return api;
    }

    let ctx = null;
    try {
      ctx = await bridge.ready(
        options.readyTimeoutMs !== undefined ? { timeoutMs: options.readyTimeoutMs } : undefined,
      );
    } catch (err) {
      console.warn("[markdown] panel.ready failed:", errorMessage(err));
    }
    if (state.destroyed) return api;
    // The newest panel.init wins (ready() resolves with the first one).
    if (bridge.context) ctx = bridge.context;
    if (ctx && ctx.keymap !== undefined) keys.setKeymap(ctx.keymap);
    applyInit(ctx);
    applyTypography();

    const title = basename(state.displayPath || state.path) || t("markdown.title");
    doc.title = title;
    bridge.panel.setTitle(title).catch(() => {});

    // Watch before the first read: a change made while that read is in flight
    // then triggers a fresh read (only the newest read is applied) instead of
    // being missed until the next change.
    call("panel.watch_file", { on: true }).catch((err) => {
      console.warn("[markdown] panel.watch_file failed:", errorMessage(err));
    });

    if (typeof state.params.text === "string") {
      state.diskText = state.params.text;
      state.available = true;
      if (state.mode === "text") ui.editor.value = state.diskText;
      showBody();
      if (state.mode === "preview") renderPreview(false);
    } else {
      showBody();
      await reload("initial");
    }

    const saved = ctx && ctx.state && typeof ctx.state === "object" ? ctx.state : null;
    let initialFind = "";
    if (typeof state.params.find === "string") initialFind = state.params.find;
    else if (saved && typeof saved.find === "string") initialFind = saved.find;
    if (initialFind && state.mode === "preview") openFind(initialFind);
    return api;
  }

  function destroy() {
    state.destroyed = true;
    for (const fn of cleanups.splice(0)) {
      try {
        fn();
      } catch {
        // ignore
      }
    }
    for (const id of Array.from(timers)) cancel(id);
    diagrams.dispose();
  }

  const api = {
    start,
    destroy,
    renderPreview,
    routeLink,
    runAction,
    setMode,
    save,
    revert,
    openFind,
    closeFind,
    exportHtml,
    get find() {
      return find;
    },
    get state() {
      return state;
    },
    get ui() {
      return ui;
    },
  };
  return api;
}

function findElements(doc) {
  const el = (id) => {
    const node = doc.getElementById(id);
    if (!node) throw new Error("markdown: missing #" + id);
    return node;
  };
  return {
    root: doc.documentElement,
    status: el("mdv-status"),
    refresh: el("mdv-refresh"),
    mode: el("mdv-mode"),
    revert: el("mdv-revert"),
    save: el("mdv-save"),
    findToggle: el("mdv-find-toggle"),
    copyMarkdown: el("mdv-copy-md"),
    copyHtml: el("mdv-copy-html"),
    typoButton: el("mdv-typography"),
    typoPopover: el("mdv-typography-popover"),
    fontFamily: el("mdv-font-family"),
    fontSize: el("mdv-font-size"),
    maxWidth: el("mdv-max-width"),
    resetDefault: el("mdv-reset-default"),
    resetBuiltin: el("mdv-reset-builtin"),
    setDefault: el("mdv-set-default"),
    find: el("mdv-find"),
    findInput: el("mdv-find-input"),
    findCount: el("mdv-find-count"),
    findPrev: el("mdv-find-prev"),
    findNext: el("mdv-find-next"),
    findClose: el("mdv-find-close"),
    viewport: el("mdv-viewport"),
    content: el("mdv-content"),
    unavailable: el("mdv-unavailable"),
    unavailablePath: el("mdv-unavailable-path"),
    editor: el("mdv-editor"),
    hljsLight: doc.getElementById("mdv-hljs-light"),
    hljsDark: doc.getElementById("mdv-hljs-dark"),
  };
}
