/**
 * Diff viewer application: PanelKind "diff" (ARCHITECTURE ADR-6.11), entry
 * https://diff.wmux.example/diff/index.html. The native contract (params,
 * methods, events) is documented in README.md.
 *
 *   const app = createApp({ document, libs: { hljs, purify } });
 *   await app.start();
 *
 * Everything is injectable (document, bridge, libraries, fetch, keys) so the
 * jsdom tests in test/web-node/diff/ drive the real code.
 */
import { wmux as defaultBridge } from "../_shared/wmux-bridge.js";
import { installKeys } from "../_shared/keys.js";
import { applyStrings } from "../_shared/strings.js";
import { currentTheme, onThemeChange } from "../_shared/theme.js";
import {
  anchorComment,
  buildComment,
  compareComments,
  normalizeComment,
  pendingComments,
} from "./comments.js";
import {
  basename,
  buildTree,
  deferReason,
  filterActive,
  fingerprint,
  foldWhitespace,
  fuzzyScore,
  matchesFilter,
  normalizeFilter,
  totals,
  treeOrder,
  STATUS_LETTERS,
} from "./files.js";
import { cycle, searchFiles } from "./find.js";
import { unwrapRanges, wrapRanges } from "./highlight.js";
import { DEFAULT_KEYMAP, SCROLL_ACTIONS, scrollTarget, stepTarget } from "./keymap.js";
import { parsePatch } from "./parse.js";
import { BUILTIN_PREFS, CONTEXT_LINES, ptToPx, resolveFontSize, resolvePrefs, sanitizePrefs } from "./prefs.js";
import { SIDE_ADD, SIDE_DEL, createRenderer, displayPath } from "./render.js";
import { t } from "./strings.js";

/** Error codes that mean "native does not implement this method". */
const UNSUPPORTED_CODES = new Set(["method_not_found", "not_supported", "forbidden", "not_allowed"]);
const STATUS_MS = 2500;
const STATE_DEBOUNCE_MS = 400;
const MAX_STATE_COLLAPSED = 200;
const MAX_FILE_SEARCH_RESULTS = 50;
/** Only per-panel data hosts may be fetched (ADR-6.4). */
const PATCH_URL_RE = /^https:\/\/[a-z0-9-]+\.wmux\.example\//i;

function errorMessage(err) {
  return err && typeof err.message === "string" ? err.message : String(err);
}

function errorCode(err) {
  return err && typeof err.code === "string" ? err.code : "";
}

/**
 * Shell command that applies the patch from stdin (POSIX here-document: Git
 * Bash, WSL, macOS/Linux shells). The delimiter never occurs as a patch line.
 */
export function gitApplyCommand(patch) {
  const text = String(patch || "").replace(/\r\n/g, "\n").replace(/\n$/, "");
  const lines = new Set(text.split("\n"));
  let delim = "WMUX_PATCH";
  for (let n = 1; lines.has(delim); n += 1) delim = "WMUX_PATCH_" + n;
  return `git apply <<'${delim}'\n${text}\n${delim}\n`;
}

/**
 * @param {{
 *   document?: Document,
 *   bridge?: object,
 *   libs?: {hljs?: object, purify?: object},
 *   fetch?: Function,
 *   installKeys?: Function,
 *   readyTimeoutMs?: number,
 *   now?: () => Date,
 * }} options
 */
export function createApp(options) {
  const opts = options || {};
  const doc = opts.document || globalThis.document;
  const view = doc.defaultView || globalThis;
  const bridge = opts.bridge || defaultBridge;
  const libs = opts.libs || {};
  const renderer = createRenderer({ document: doc, hljs: libs.hljs || null, purify: libs.purify || null });
  const fetchImpl = opts.fetch || (typeof view.fetch === "function" ? view.fetch.bind(view) : null);
  const now = opts.now || (() => new Date());
  const cleanups = [];
  const timers = new Set();
  const ui = findElements(doc);

  const state = {
    started: false,
    destroyed: false,
    params: {},
    title: "",
    patch: "",
    applyCommand: null,
    files: [],
    order: [], // files in tree order
    generated: new Set(),
    loadedDeferred: new Set(), // paths whose deferred diff was loaded
    collapsed: new Set(), // paths collapsed by the user
    expanded: new Set(), // viewed paths expanded by the user
    viewed: new Map(), // path -> fingerprint (native store)
    prefs: { ...BUILTIN_PREFS },
    fontSizePt: 10,
    filter: normalizeFilter(null),
    filesVisible: true,
    views: new Map(), // file index -> {section, body}
    hunkCache: new Map(),
    comments: new Map(), // id -> record
    anchors: new Map(), // id -> anchor
    composer: null, // {fileIndex, side, start, end, editingId, draft}
    selection: null, // {fileIndex, side, start, end}
    find: { open: false, query: "", matches: [], index: -1, capped: false },
    fileSearch: { open: false, results: [], active: 0 },
    loadSeq: 0,
    status: "idle", // idle | loading | ready | empty | error
    commentsSupported: true,
    viewedSupported: true,
  };

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

  function listen(target, type, fn, o) {
    target.addEventListener(type, fn, o);
    cleanups.push(() => target.removeEventListener(type, fn, o));
  }

  function reducedMotion() {
    const root = doc.documentElement;
    if (root.getAttribute("data-wmux-reduced-motion") === "true") return true;
    try {
      return !!(view.matchMedia && view.matchMedia("(prefers-reduced-motion: reduce)").matches);
    } catch {
      return false;
    }
  }

  function currentScheme() {
    const theme = currentTheme();
    if (theme && theme.scheme) return theme.scheme;
    return doc.documentElement.getAttribute("data-wmux-scheme") || "dark";
  }

  let statusTimer = 0;
  function setStatus(text, kind, sticky) {
    cancel(statusTimer);
    ui.status.textContent = text || "";
    ui.status.dataset.kind = kind || "info";
    if (text && !sticky) statusTimer = later(() => setStatus(""), STATUS_MS);
  }

  function call(method, params) {
    return bridge.call(method, params || {});
  }

  function unsupported(err) {
    return UNSUPPORTED_CODES.has(errorCode(err));
  }

  function fileByIndex(i) {
    return state.files[i] || null;
  }

  function fileByPath(p) {
    return state.files.find((f) => f.path === p) || null;
  }

  /* ---------------------------------------------------------------------- */
  /* file state                                                             */
  /* ---------------------------------------------------------------------- */

  function isViewed(file) {
    return state.viewed.get(file.path) === file.fingerprint;
  }

  function changedSinceViewed(file) {
    return state.viewed.has(file.path) && state.viewed.get(file.path) !== file.fingerprint;
  }

  function deferredNow(file) {
    return file.deferred && !state.loadedDeferred.has(file.path) ? file.deferred : null;
  }

  function isCollapsed(file) {
    if (state.collapsed.has(file.path)) return true;
    return isViewed(file) && !state.expanded.has(file.path);
  }

  function isExpanded(file) {
    return !deferredNow(file) && !isCollapsed(file) && !file.binary && file.hunks.length > 0;
  }

  function shellInfo(file) {
    return {
      deferred: deferredNow(file),
      collapsed: isCollapsed(file),
      viewed: isViewed(file),
      changedSinceViewed: changedSinceViewed(file),
    };
  }

  function displayHunks(file) {
    const key = file.index;
    let hunks = state.hunkCache.get(key);
    if (!hunks) {
      hunks = file.hunks.map((h) => (state.prefs.ignoreWhitespace ? foldWhitespace(h.lines) : h.lines));
      state.hunkCache.set(key, hunks);
    }
    return hunks;
  }

  /* ---------------------------------------------------------------------- */
  /* rendering                                                              */
  /* ---------------------------------------------------------------------- */

  function contextSetting() {
    return state.prefs.expandUnchanged ? Infinity : state.prefs.contextLines;
  }

  /** Line indices per hunk that must stay visible (comments, current match). */
  function pinnedFor(file) {
    const pins = new Map();
    const add = (h, i) => {
      if (!pins.has(h)) pins.set(h, new Set());
      pins.get(h).add(i);
    };
    const hunks = displayHunks(file);
    const want = new Set();
    for (const c of state.comments.values()) {
      const a = state.anchors.get(c.id);
      if (!a || !a.file || a.file.index !== file.index) continue;
      if (a.status !== "anchored" && a.status !== "moved") continue;
      for (let n = a.startLine; n <= a.endLine; n += 1) want.add(c.side + ":" + n);
    }
    if (state.composer && state.composer.fileIndex === file.index) {
      for (let n = state.composer.start; n <= state.composer.end; n += 1) want.add(state.composer.side + ":" + n);
    }
    if (want.size) {
      hunks.forEach((lines, h) =>
        lines.forEach((l, i) => {
          if (l.type !== "add" && want.has(SIDE_DEL + ":" + l.oldNo)) add(h, i);
          if (l.type !== "del" && want.has(SIDE_ADD + ":" + l.newNo)) add(h, i);
        }),
      );
    }
    return (h) => pins.get(h) || null;
  }

  function renderBody(file) {
    const v = state.views.get(file.index);
    if (!v) return;
    const holder = v.section.querySelector(".dv-file-body");
    holder.textContent = "";
    v.body = null;
    if (!isExpanded(file)) return;
    v.body = renderer.body(file, displayHunks(file), {
      layout: state.prefs.layout,
      wordDiffs: state.prefs.wordDiffs,
      context: contextSetting(),
      pinned: pinnedFor(file),
    });
    holder.append(v.body.el);
    placeComments(file);
    applySelection();
    if (state.find.open) highlightFindIn(file.index);
  }

  function refreshShell(file) {
    const v = state.views.get(file.index);
    if (!v) return;
    const wasExpanded = !!v.body;
    renderer.updateShell(v.section, shellInfo(file));
    if (isExpanded(file) !== wasExpanded) renderBody(file);
  }

  function renderFiles() {
    ui.files.textContent = "";
    state.views.clear();
    state.hunkCache.clear();
    for (const file of state.order) {
      const section = renderer.fileShell(file, shellInfo(file));
      state.views.set(file.index, { section, body: null });
      ui.files.append(section);
    }
    for (const file of state.order) renderBody(file);
    applyFilter();
  }

  function rerenderBodies() {
    state.hunkCache.clear();
    for (const file of state.order) renderBody(file);
    if (state.find.open) runFind(false);
  }

  /* ---------------------------------------------------------------------- */
  /* toolbar, options, preferences                                          */
  /* ---------------------------------------------------------------------- */

  const PREF_LABELS = {
    wordWrap: ["diff.disableWrap", "diff.enableWrap"],
    wordDiffs: ["diff.disableWordDiffs", "diff.enableWordDiffs"],
    lineNumbers: ["diff.hideLineNumbers", "diff.showLineNumbers"],
    showBackgrounds: ["diff.hideBackgrounds", "diff.showBackgrounds"],
    expandUnchanged: ["diff.collapseUnchanged", "diff.expandUnchanged"],
    ignoreWhitespace: ["diff.showWhitespace", "diff.ignoreWhitespace"],
  };

  function allExpanded() {
    const candidates = state.files.filter((f) => !f.binary && f.hunks.length > 0);
    return candidates.length > 0 && candidates.every((f) => isExpanded(f));
  }

  function updateToolbar() {
    const p = state.prefs;
    const layoutLabel = p.layout === "split" ? t("diff.switchUnified") : t("diff.switchSplit");
    const filesLabel = state.filesVisible ? t("diff.hideFiles") : t("diff.showFiles");
    const searchLabel = state.fileSearch.open ? t("diff.hideFileSearch") : t("diff.showFileSearch");
    const expandLabel = allExpanded() ? t("diff.collapseAll") : t("diff.expandAll");
    ui.layout.textContent = layoutLabel;
    ui.filesToggle.textContent = filesLabel;
    ui.filesToggle.setAttribute("aria-pressed", String(state.filesVisible));
    ui.searchToggle.textContent = searchLabel;
    ui.searchToggle.setAttribute("aria-pressed", String(state.fileSearch.open));
    ui.expandAll.textContent = expandLabel;
    const labels = { layout: layoutLabel, files: filesLabel, search: searchLabel, "expand-all": expandLabel };
    for (const item of ui.menu.querySelectorAll("[data-menu]")) {
      const id = item.dataset.menu;
      if (labels[id]) item.textContent = labels[id];
      if (PREF_LABELS[id]) {
        item.textContent = t(PREF_LABELS[id][p[id] ? 0 : 1]);
        item.setAttribute("aria-checked", String(!!p[id]));
      }
    }
    for (const item of ui.menu.querySelectorAll("[data-indicator]")) {
      item.setAttribute("aria-checked", String(item.dataset.indicator === p.diffIndicators));
    }
    if (doc.activeElement !== ui.contextLines) ui.contextLines.value = String(p.contextLines);
    ui.contextLines.disabled = !!p.expandUnchanged;
    const pending = pendingComments(Array.from(state.comments.values())).length;
    ui.commentsToggle.textContent = state.comments.size ? t("diff.commentsCount", { count: state.comments.size }) : t("diff.comments");
    ui.send.disabled = pending === 0;
  }

  function applyPrefClasses() {
    const root = doc.documentElement;
    const p = state.prefs;
    root.dataset.dvLayout = p.layout;
    root.dataset.dvIndicators = p.diffIndicators;
    root.classList.toggle("dv-wrap", !!p.wordWrap);
    root.classList.toggle("dv-no-line-numbers", !p.lineNumbers);
    root.classList.toggle("dv-no-backgrounds", !p.showBackgrounds);
    root.style.setProperty("--dv-font-size", ptToPx(state.fontSizePt) + "px");
    ui.body.classList.toggle("dv-files-hidden", !state.filesVisible);
    ui.sidebar.hidden = !state.filesVisible;
  }

  /** Change preferences; re-render when the change affects the tables. */
  function setPrefs(patch, persist = true) {
    const next = { ...state.prefs, ...sanitizePrefs(patch) };
    const rerender = ["layout", "wordDiffs", "expandUnchanged", "ignoreWhitespace", "contextLines"].some(
      (k) => next[k] !== state.prefs[k],
    );
    state.prefs = next;
    applyPrefClasses();
    if (rerender) rerenderBodies();
    updateToolbar();
    saveState();
    if (persist) {
      call("viewerPrefs.set", { prefs: { ...state.prefs } }).catch((err) => {
        if (!unsupported(err)) console.warn("[diff] viewerPrefs.set failed:", errorMessage(err));
      });
    }
  }

  /* ---------------------------------------------------------------------- */
  /* loading                                                                */
  /* ---------------------------------------------------------------------- */

  function showMessage(text, kind) {
    ui.message.textContent = text || "";
    ui.message.dataset.kind = kind || "info";
    ui.message.hidden = !text;
  }

  function topFilePath() {
    const top = ui.viewport.scrollTop;
    let best = null;
    for (const file of state.order) {
      const v = state.views.get(file.index);
      if (!v || v.section.hidden) continue;
      if (docTop(v.section) <= top + 4) best = file.path;
      else break;
    }
    return best;
  }

  /** Accept a load result: {patch, title?, generated?, apply_command?}. */
  function acceptMeta(meta) {
    if (!meta || typeof meta !== "object") return;
    const explicit = typeof state.params.title === "string" && state.params.title.trim() !== "";
    if (typeof meta.title === "string" && meta.title.trim() && !explicit) setTitle(meta.title);
    if (Array.isArray(meta.generated)) state.generated = new Set(meta.generated.filter((p) => typeof p === "string"));
    if (typeof meta.apply_command === "string" && meta.apply_command) state.applyCommand = meta.apply_command;
  }

  /**
   * Parse and render patch text. Collapsed / viewed / expanded choices, the
   * scroll position (by file) and the find query survive a reload.
   */
  function loadPatch(text, meta) {
    acceptMeta(meta);
    const keepTop = state.files.length ? topFilePath() : null;
    state.patch = typeof text === "string" ? text : "";
    state.status = "loading";
    showMessage(t("diff.parsing"));
    let parsed;
    try {
      parsed = parsePatch(state.patch);
    } catch (err) {
      console.error("[diff] parse failed", err);
      return fail();
    }
    for (const e of parsed.errors) console.warn("[diff] patch line " + e.line + ": " + e.message);
    for (const f of parsed.files) {
      f.fingerprint = fingerprint(f);
      f.deferred = deferReason(f, state.generated);
    }
    state.files = parsed.files;
    state.order = treeOrder(buildTree(parsed.files));
    state.selection = null;
    if (state.composer && !state.composer.draft) state.composer = null;
    if (state.composer) {
      const f = fileByPath(state.composer.filePath);
      if (f) state.composer.fileIndex = f.index;
      else state.composer = null;
    }
    reanchorComments();
    if (parsed.files.length === 0) {
      state.status = "empty";
      ui.files.textContent = "";
      state.views.clear();
      renderTree();
      updateStats();
      updateToolbar();
      showMessage(t("diff.noFiles"), "empty");
      renderCommentList();
      return;
    }
    showMessage(t("diff.rendering"));
    try {
      renderFiles();
    } catch (err) {
      console.error("[diff] render failed", err);
      return fail();
    }
    state.status = "ready";
    showMessage("");
    renderTree();
    updateStats();
    updateToolbar();
    renderCommentList();
    if (state.find.open && state.find.query) runFind(false);
    if (keepTop) {
      const f = fileByPath(keepTop);
      if (f) scrollToFile(f, false);
    }
  }

  function fail() {
    state.status = "error";
    ui.files.textContent = "";
    state.views.clear();
    showMessage(t("diff.renderError"), "error");
  }

  async function fetchPatchUrl(url) {
    if (!PATCH_URL_RE.test(url) || !fetchImpl) throw new Error("patch_url not allowed: " + url);
    const res = await fetchImpl(url, { credentials: "omit", cache: "no-store" });
    if (!res.ok) throw new Error("HTTP " + res.status);
    return res.text();
  }

  /** Load the patch: params.patch, then params.patch_url, then panel.diff.load. */
  async function load(refresh) {
    const seq = ++state.loadSeq;
    state.status = "loading";
    if (!state.files.length) showMessage(t("diff.loading"));
    else setStatus(t("diff.loading"), "info", true);
    let text = null;
    let meta = null;
    try {
      if (!refresh && typeof state.params.patch === "string") {
        text = state.params.patch;
      } else if (!refresh && typeof state.params.patch_url === "string") {
        text = await fetchPatchUrl(state.params.patch_url);
      } else {
        try {
          meta = await call("panel.diff.load", {
            refresh: !!refresh,
            context_lines: state.prefs.contextLines,
            ignore_whitespace: !!state.prefs.ignoreWhitespace,
          });
          text = meta && typeof meta.patch === "string" ? meta.patch : "";
          if (meta && typeof meta.patch_url === "string" && typeof meta.patch !== "string") {
            text = await fetchPatchUrl(meta.patch_url);
          }
        } catch (err) {
          if (refresh && unsupported(err) && typeof state.params.patch_url === "string") {
            text = await fetchPatchUrl(state.params.patch_url);
          } else if (refresh && unsupported(err) && typeof state.params.patch === "string") {
            text = state.params.patch;
          } else throw err;
        }
      }
    } catch (err) {
      if (seq !== state.loadSeq || state.destroyed) return;
      console.warn("[diff] load failed:", errorMessage(err));
      setStatus("");
      if (!state.files.length) fail();
      else setStatus(t("diff.renderError"), "error");
      return;
    }
    if (seq !== state.loadSeq || state.destroyed) return;
    setStatus("");
    if (refresh) await loadViewed();
    loadPatch(text, meta);
  }

  /* ---------------------------------------------------------------------- */
  /* viewed files                                                           */
  /* ---------------------------------------------------------------------- */

  function acceptViewedList(result) {
    const map = new Map();
    const list = result && Array.isArray(result.files) ? result.files : Array.isArray(result) ? result : [];
    for (const item of list) {
      if (item && typeof item.path === "string" && typeof item.fingerprint === "string") map.set(item.path, item.fingerprint);
    }
    if (result && result.viewed && typeof result.viewed === "object" && !Array.isArray(result.viewed)) {
      for (const [p, fp] of Object.entries(result.viewed)) if (typeof fp === "string") map.set(p, fp);
    }
    state.viewed = map;
  }

  async function loadViewed() {
    if (!state.viewedSupported) return;
    try {
      acceptViewedList(await call("viewedFiles.list", {}));
    } catch (err) {
      if (unsupported(err)) state.viewedSupported = false;
      else console.warn("[diff] viewedFiles.list failed:", errorMessage(err));
    }
  }

  function setViewed(file, viewed) {
    if (viewed) state.viewed.set(file.path, file.fingerprint);
    else state.viewed.delete(file.path);
    state.expanded.delete(file.path);
    refreshShell(file);
    renderTree();
    updateStats();
    updateToolbar();
    saveState();
    if (!state.viewedSupported) return;
    call("viewedFiles.set", { path: file.path, fingerprint: file.fingerprint, viewed: !!viewed }).catch((err) => {
      if (unsupported(err)) state.viewedSupported = false;
      else console.warn("[diff] viewedFiles.set failed:", errorMessage(err));
    });
  }

  async function clearViewed() {
    state.viewed.clear();
    state.expanded.clear();
    for (const f of state.files) refreshShell(f);
    renderTree();
    updateStats();
    if (state.viewedSupported) await call("viewedFiles.clear", {}).catch(() => {});
  }

  /* ---------------------------------------------------------------------- */
  /* stats, title, tree, filter                                             */
  /* ---------------------------------------------------------------------- */

  function updateStats() {
    const sum = totals(state.files);
    ui.statsAdd.textContent = t("diff.additionsCount", { count: sum.additions });
    ui.statsDel.textContent = t("diff.deletionsCount", { count: sum.deletions });
    const viewedCount = state.files.filter((f) => isViewed(f)).length;
    ui.progress.textContent = state.files.length ? t("diff.progress", { viewed: viewedCount, total: state.files.length }) : "";
  }

  function setTitle(title) {
    state.title = String(title || "").trim() || t("diff.title");
    ui.title.textContent = state.title;
    doc.title = state.title;
    if (bridge.available) bridge.panel.setTitle(state.title).catch(() => {});
  }

  function treeFileItem(file) {
    const li = doc.createElement("li");
    li.setAttribute("role", "treeitem");
    li.className = "dv-tree-item";
    li.dataset.file = String(file.index);
    const button = doc.createElement("button");
    button.type = "button";
    button.className = "dv-tree-file";
    button.dataset.action = "jump";
    button.title = t("diff.jumpToFile") + ": " + displayPath(file);
    const badge = doc.createElement("span");
    badge.className = "dv-badge dv-badge-" + file.status;
    badge.textContent = STATUS_LETTERS[file.status] || "M";
    const name = doc.createElement("span");
    name.className = "dv-tree-name";
    name.textContent = basename(file.path);
    const stats = doc.createElement("span");
    stats.className = "dv-tree-stats";
    if (file.additions) stats.append(Object.assign(doc.createElement("span"), { className: "dv-plus", textContent: "+" + file.additions }));
    if (file.deletions) stats.append(Object.assign(doc.createElement("span"), { className: "dv-minus", textContent: "−" + file.deletions }));
    const mark = doc.createElement("span");
    mark.className = "dv-tree-viewed";
    mark.textContent = isViewed(file) ? "✓" : changedSinceViewed(file) ? "•" : "";
    mark.title = isViewed(file) ? t("diff.viewed") : changedSinceViewed(file) ? t("diff.changedSinceViewed") : "";
    button.append(badge, name, stats, mark);
    li.append(button);
    return li;
  }

  function treeNode(node) {
    const items = [];
    for (const dir of node.dirs) {
      const li = doc.createElement("li");
      li.setAttribute("role", "treeitem");
      li.setAttribute("aria-expanded", "true");
      li.className = "dv-tree-dir";
      const label = doc.createElement("span");
      label.className = "dv-tree-dirname";
      label.textContent = dir.name;
      const group = doc.createElement("ul");
      group.setAttribute("role", "group");
      group.append(...treeNode(dir));
      li.append(label, group);
      items.push(li);
    }
    for (const f of node.files) items.push(treeFileItem(f));
    return items;
  }

  function renderTree() {
    ui.tree.textContent = "";
    ui.tree.append(...treeNode(buildTree(state.files)));
    applyFilter();
  }

  function passes(file) {
    return matchesFilter(file, state.filter, isViewed);
  }

  function applyFilter() {
    let shown = 0;
    for (const file of state.files) {
      const ok = passes(file);
      if (ok) shown += 1;
      const v = state.views.get(file.index);
      if (v) v.section.hidden = !ok;
      const item = ui.tree.querySelector(`.dv-tree-item[data-file="${file.index}"]`);
      if (item) item.hidden = !ok;
    }
    for (const dir of Array.from(ui.tree.querySelectorAll(".dv-tree-dir")).reverse()) {
      dir.hidden = !dir.querySelector(".dv-tree-item:not([hidden])");
    }
    const empty = state.files.length > 0 && shown === 0;
    ui.filterEmpty.hidden = !empty;
    ui.filesEmpty.hidden = !empty;
    ui.hideViewed.textContent = state.filter.hideViewed ? t("diff.filter.showViewed") : t("diff.filter.hideViewed");
    ui.hideViewed.setAttribute("aria-pressed", String(state.filter.hideViewed));
    ui.sidebarTitle.textContent = filterActive(state.filter) ? t("diff.files") : t("diff.changedFiles");
  }

  function setFilter(patch) {
    const cur = state.filter;
    state.filter = normalizeFilter({
      query: patch.query !== undefined ? patch.query : cur.query,
      statuses: patch.statuses !== undefined ? patch.statuses : cur.statuses,
      hideViewed: patch.hideViewed !== undefined ? patch.hideViewed : cur.hideViewed,
    });
    applyFilter();
  }

  function clearFilter() {
    state.filter = normalizeFilter(null);
    ui.filterInput.value = "";
    for (const box of ui.statusBoxes) box.checked = true;
    applyFilter();
  }

  /* ---------------------------------------------------------------------- */
  /* scrolling and navigation                                               */
  /* ---------------------------------------------------------------------- */

  /** Position of an element in the viewport's scroll coordinates. */
  function docTop(node) {
    return node.getBoundingClientRect().top - ui.viewport.getBoundingClientRect().top + ui.viewport.scrollTop;
  }

  function scrollViewportTo(top, smooth) {
    const vp = ui.viewport;
    const max = Math.max(0, vp.scrollHeight - vp.clientHeight);
    const target = Math.max(0, Math.min(top, max || top));
    if (smooth && !reducedMotion() && typeof vp.scrollTo === "function") vp.scrollTo({ top: target, behavior: "smooth" });
    else vp.scrollTop = target;
  }

  function scrollToFile(file, smooth = true) {
    const v = state.views.get(file.index);
    if (v) scrollViewportTo(docTop(v.section), smooth);
  }

  function visibleSections() {
    return state.order.map((f) => state.views.get(f.index)).filter((v) => v && !v.section.hidden);
  }

  function stepFile(dir) {
    const sections = visibleSections();
    const i = stepTarget(sections.map((v) => docTop(v.section)), ui.viewport.scrollTop, dir);
    if (i >= 0) scrollViewportTo(docTop(sections[i].section), true);
  }

  function stepHunk(dir) {
    const rows = [];
    for (const v of visibleSections()) if (v.body) rows.push(...v.section.querySelectorAll("tr.dv-hunk"));
    const i = stepTarget(rows.map((r) => docTop(r)), ui.viewport.scrollTop, dir);
    if (i >= 0) scrollViewportTo(docTop(rows[i]), true);
  }

  /** The file whose section is at the top of the viewport. */
  function currentFile() {
    const top = ui.viewport.scrollTop;
    let current = null;
    for (const v of visibleSections()) {
      if (current === null || docTop(v.section) <= top + 4) current = v;
      else break;
    }
    if (!current) return null;
    return fileByIndex(Number(current.section.dataset.file));
  }

  function scrollBy(action) {
    const vp = ui.viewport;
    const top = scrollTarget(action, {
      top: vp.scrollTop,
      height: vp.clientHeight,
      max: Math.max(0, vp.scrollHeight - vp.clientHeight),
    });
    if (top !== null) scrollViewportTo(top, action !== "diffViewerScrollDown" && action !== "diffViewerScrollUp");
  }

  /* ---------------------------------------------------------------------- */
  /* file actions                                                           */
  /* ---------------------------------------------------------------------- */

  function toggleFile(file) {
    if (deferredNow(file)) return loadDeferred(file);
    if (isCollapsed(file)) {
      state.collapsed.delete(file.path);
      if (isViewed(file)) state.expanded.add(file.path);
    } else {
      state.collapsed.add(file.path);
      state.expanded.delete(file.path);
    }
    refreshShell(file);
    updateToolbar();
    saveState();
  }

  function loadDeferred(file) {
    state.loadedDeferred.add(file.path);
    state.collapsed.delete(file.path);
    if (isViewed(file)) state.expanded.add(file.path);
    refreshShell(file);
    updateToolbar();
  }

  function expandFile(file) {
    if (isExpanded(file)) return;
    if (deferredNow(file)) state.loadedDeferred.add(file.path);
    state.collapsed.delete(file.path);
    if (isViewed(file)) state.expanded.add(file.path);
    refreshShell(file);
  }

  function setAllExpanded(expand) {
    for (const file of state.files) {
      if (expand) {
        if (deferredNow(file)) state.loadedDeferred.add(file.path);
        state.collapsed.delete(file.path);
        if (isViewed(file)) state.expanded.add(file.path);
      } else {
        state.collapsed.add(file.path);
        state.expanded.delete(file.path);
      }
      refreshShell(file);
    }
    updateToolbar();
    saveState();
  }

  async function copyApply() {
    const text = state.applyCommand || gitApplyCommand(state.patch);
    try {
      if (bridge.available) await bridge.panel.clipboardWrite(text);
      else if (view.navigator && view.navigator.clipboard) await view.navigator.clipboard.writeText(text);
      else throw new Error("no clipboard");
      setStatus(t("diff.copiedApply"), "info");
    } catch (err) {
      console.warn("[diff] copy failed:", errorMessage(err));
      setStatus(t("diff.copyApplyFailed"), "error");
    }
  }

  /* ---------------------------------------------------------------------- */
  /* file search ("Jump to file")                                           */
  /* ---------------------------------------------------------------------- */

  function openFileSearch() {
    closeMenu();
    state.fileSearch.open = true;
    ui.fileSearch.hidden = false;
    ui.fileSearchInput.value = "";
    updateFileSearch();
    updateToolbar();
    ui.fileSearchInput.focus();
  }

  function closeFileSearch() {
    if (!state.fileSearch.open) return;
    state.fileSearch.open = false;
    ui.fileSearch.hidden = true;
    updateToolbar();
    ui.viewport.focus();
  }

  function updateFileSearch() {
    const q = ui.fileSearchInput.value;
    const scored = state.order
      .map((f) => ({ f, s: fuzzyScore(q, f.path) }))
      .filter((x) => x.s >= 0)
      .sort((a, b) => b.s - a.s);
    state.fileSearch.results = scored.slice(0, MAX_FILE_SEARCH_RESULTS).map((x) => x.f);
    state.fileSearch.active = 0;
    renderFileSearch();
  }

  function renderFileSearch() {
    ui.fileSearchList.textContent = "";
    const { results, active } = state.fileSearch;
    if (results.length === 0) {
      const li = doc.createElement("li");
      li.className = "dv-muted";
      li.textContent = t("diff.fileSearch.none");
      ui.fileSearchList.append(li);
      ui.fileSearchInput.removeAttribute("aria-activedescendant");
      return;
    }
    results.forEach((f, i) => {
      const li = doc.createElement("li");
      li.id = "dv-filesearch-" + i;
      li.setAttribute("role", "option");
      li.setAttribute("aria-selected", String(i === active));
      li.dataset.file = String(f.index);
      li.className = "dv-filesearch-item";
      li.textContent = displayPath(f);
      ui.fileSearchList.append(li);
    });
    ui.fileSearchInput.setAttribute("aria-activedescendant", "dv-filesearch-" + active);
  }

  function jumpTo(file) {
    if (!passes(file)) clearFilter();
    expandFile(file);
    scrollToFile(file, true);
    updateToolbar();
  }

  function chooseFileSearch(index) {
    const f = state.fileSearch.results[index];
    if (!f) return;
    closeFileSearch();
    jumpTo(f);
  }

  /* ---------------------------------------------------------------------- */
  /* find in diff                                                           */
  /* ---------------------------------------------------------------------- */

  const findSpans = new Map(); // match index -> spans

  function updateFindCount() {
    const f = state.find;
    if (!f.query) ui.findCount.textContent = "";
    else if (f.matches.length === 0) ui.findCount.textContent = t("diff.find.none");
    else {
      const key = f.capped ? "diff.find.capped" : "diff.find.count";
      ui.findCount.textContent = t(key, { current: f.index + 1, total: f.matches.length });
    }
  }

  function codeCellFor(section, m) {
    return section.querySelector(`td.dv-code[data-h="${m.hunkIndex}"][data-l="${m.lineIndex}"][data-side="${m.side}"]`);
  }

  function highlightFindIn(fileIndex) {
    const v = state.views.get(fileIndex);
    if (!v) return;
    unwrapRanges(v.section, "dv-find-hit");
    for (const [i] of findSpans) if (state.find.matches[i] && state.find.matches[i].fileIndex === fileIndex) findSpans.delete(i);
    if (!v.body || !state.find.query) return;
    const byCell = new Map();
    state.find.matches.forEach((m, i) => {
      if (m.fileIndex !== fileIndex) return;
      const cell = codeCellFor(v.section, m);
      if (!cell) return;
      if (!byCell.has(cell)) byCell.set(cell, []);
      byCell.get(cell).push(i);
    });
    for (const [cell, idx] of byCell) {
      const text = cell.querySelector(".dv-text");
      for (const i of idx.slice().reverse()) {
        const m = state.find.matches[i];
        findSpans.set(i, wrapRanges(text, [[m.start, m.end]], "dv-find-hit"));
      }
    }
    markCurrentMatch();
  }

  function markCurrentMatch() {
    for (const s of doc.querySelectorAll(".dv-find-current")) s.classList.remove("dv-find-current");
    const spans = findSpans.get(state.find.index) || [];
    for (const s of spans) s.classList.add("dv-find-current");
    return spans;
  }

  function clearFindHighlights() {
    unwrapRanges(ui.files, "dv-find-hit");
    findSpans.clear();
  }

  function runFind(scroll) {
    const f = state.find;
    clearFindHighlights();
    const res = searchFiles(state.files, f.query, (file) => displayHunks(file));
    const prev = f.matches[f.index];
    f.matches = res.matches;
    f.capped = res.capped;
    f.index = -1;
    if (prev && !scroll) {
      const same = f.matches.findIndex((m) => m.fileIndex === prev.fileIndex && m.hunkIndex === prev.hunkIndex && m.lineIndex >= prev.lineIndex);
      f.index = same;
    }
    if (f.index < 0 && f.matches.length) f.index = 0;
    for (const file of state.files) if (f.matches.some((m) => m.fileIndex === file.index)) highlightFindIn(file.index);
    updateFindCount();
    if (scroll && f.index >= 0) goToMatch(f.index);
  }

  function goToMatch(index) {
    const f = state.find;
    const m = f.matches[index];
    if (!m) return;
    f.index = index;
    const file = fileByIndex(m.fileIndex);
    if (!passes(file)) clearFilter();
    expandFile(file);
    const v = state.views.get(file.index);
    if (v && v.body) {
      const gap = v.body.gapFor(m.hunkIndex, m.lineIndex);
      if (gap) v.body.expandGap(gap);
      highlightFindIn(file.index);
    }
    const spans = markCurrentMatch();
    updateFindCount();
    updateToolbar();
    if (spans[0]) scrollViewportTo(docTop(spans[0]) - ui.viewport.clientHeight / 2, false);
    saveState();
  }

  function openFind(query) {
    closeMenu();
    state.find.open = true;
    ui.find.hidden = false;
    if (typeof query === "string") ui.findInput.value = query;
    state.find.query = ui.findInput.value;
    ui.findInput.focus();
    if (typeof ui.findInput.select === "function") ui.findInput.select();
    runFind(true);
  }

  function closeFind() {
    if (!state.find.open) return;
    state.find = { open: false, query: "", matches: [], index: -1, capped: false };
    ui.find.hidden = true;
    clearFindHighlights();
    updateFindCount();
    ui.viewport.focus();
    saveState();
  }

  function findStep(dir) {
    if (!state.find.open) return openFind();
    const f = state.find;
    if (!f.matches.length) return;
    goToMatch(cycle(f.index, f.matches.length, dir));
  }

  /* ---------------------------------------------------------------------- */
  /* review comments                                                        */
  /* ---------------------------------------------------------------------- */

  function reanchorComments() {
    state.anchors.clear();
    for (const c of state.comments.values()) state.anchors.set(c.id, anchorComment(state.files, c));
  }

  function acceptComments(result) {
    const list = Array.isArray(result) ? result : result && Array.isArray(result.comments) ? result.comments : [];
    state.comments.clear();
    for (const raw of list) {
      const c = normalizeComment(raw);
      if (c) state.comments.set(c.id, c);
    }
    reanchorComments();
  }

  async function loadComments() {
    if (!state.commentsSupported) return;
    try {
      acceptComments(await call("comments.list", {}));
    } catch (err) {
      if (unsupported(err)) state.commentsSupported = false;
      else console.warn("[diff] comments.list failed:", errorMessage(err));
    }
  }

  function commentsChanged() {
    reanchorComments();
    for (const file of state.files) renderBody(file);
    renderCommentList();
    updateToolbar();
  }

  function linesLabel(start, end) {
    return start === end ? t("diff.lineLabel", { line: start }) : t("diff.linesLabel", { start, end });
  }

  function badge(text, kind) {
    const span = doc.createElement("span");
    span.className = "dv-tag dv-tag-" + kind;
    span.textContent = text;
    return span;
  }

  function button(text, action, extra) {
    const b = doc.createElement("button");
    b.type = "button";
    b.textContent = text;
    b.dataset.action = action;
    if (extra) Object.assign(b.dataset, extra);
    return b;
  }

  function commentCard(c) {
    const a = state.anchors.get(c.id);
    const card = doc.createElement("div");
    card.className = "dv-comment";
    card.dataset.comment = c.id;
    const head = doc.createElement("div");
    head.className = "dv-comment-head";
    const where = doc.createElement("span");
    where.className = "dv-comment-where";
    const start = a ? a.startLine : c.startLine;
    const end = a ? a.endLine : c.endLine;
    where.textContent = linesLabel(start, end) + " (" + t(c.side === SIDE_DEL ? "diff.oldVersion" : "diff.newVersion") + ")";
    head.append(where);
    if (a && a.status === "moved") head.append(badge(t("diff.moved"), "moved"));
    if (a && a.status === "outdated") head.append(badge(t("diff.outdated"), "outdated"));
    if (a && a.status === "absent") head.append(badge(t("diff.absent"), "absent"));
    if (c.consumedAt) head.append(badge(t("diff.delivered"), "delivered"));
    const actions = doc.createElement("span");
    actions.className = "dv-comment-actions";
    actions.append(button(t("diff.edit"), "edit-comment", { id: c.id }), button(t("diff.delete"), "delete-comment", { id: c.id }));
    head.append(actions);
    const body = doc.createElement("div");
    body.className = "dv-comment-body";
    body.textContent = c.message;
    card.append(head, body);
    return card;
  }

  function composerEl() {
    const c = state.composer;
    const box = doc.createElement("div");
    box.className = "dv-composer";
    const label = doc.createElement("div");
    label.className = "dv-composer-label";
    label.textContent = linesLabel(c.start, c.end) + " (" + t(c.side === SIDE_DEL ? "diff.oldVersion" : "diff.newVersion") + ")";
    const area = doc.createElement("textarea");
    area.className = "dv-composer-input";
    area.placeholder = t("diff.composer.placeholder");
    area.setAttribute("aria-label", t("diff.composer.placeholder"));
    area.value = c.draft || "";
    const actions = doc.createElement("div");
    actions.className = "dv-composer-actions";
    const submit = button(c.editingId ? t("diff.save") : t("diff.comment"), "submit-comment");
    submit.classList.add("wmux-primary");
    submit.disabled = !area.value.trim();
    actions.append(button(t("diff.cancel"), "cancel-comment"), submit);
    box.append(label, area, actions);
    return box;
  }

  /** Insert comment threads and the composer under their lines. */
  function placeComments(file) {
    const v = state.views.get(file.index);
    if (!v || !v.body) return;
    const groups = new Map(); // "side:line" -> {side, line, cards: []}
    const group = (side, line) => {
      const key = side + ":" + line;
      if (!groups.has(key)) groups.set(key, { side, line, items: [] });
      return groups.get(key);
    };
    const list = Array.from(state.comments.values()).sort(compareComments);
    for (const c of list) {
      const a = state.anchors.get(c.id);
      if (!a || !a.file || a.file.index !== file.index) continue;
      if (a.status !== "anchored" && a.status !== "moved") continue;
      if (state.composer && state.composer.editingId === c.id) continue;
      group(c.side, a.endLine).items.push(commentCard(c));
    }
    const cmp = state.composer;
    if (cmp && cmp.fileIndex === file.index) group(cmp.side, cmp.end).items.push(composerEl());
    for (const g of groups.values()) {
      const row = v.body.rowFor(g.side, g.line);
      if (!row) continue;
      const thread = doc.createElement("div");
      thread.className = "dv-thread";
      thread.append(...g.items);
      let after = row;
      while (after.nextElementSibling && after.nextElementSibling.classList.contains("dv-comment-row")) after = after.nextElementSibling;
      after.after(renderer.commentRow(v.body, g.side, thread));
    }
    const area = v.section.querySelector(".dv-composer-input");
    if (area && cmp && cmp.focus) {
      cmp.focus = false;
      area.focus();
    }
  }

  function openComposer(fileIndex, side, start, end, editing) {
    const file = fileByIndex(fileIndex);
    if (!file) return;
    const prev = state.composer ? fileByIndex(state.composer.fileIndex) : null;
    state.composer = {
      fileIndex,
      filePath: file.path,
      side,
      start: Math.min(start, end),
      end: Math.max(start, end),
      editingId: editing ? editing.id : null,
      draft: editing ? editing.message : "",
      focus: true,
    };
    state.selection = null;
    if (prev && prev !== file) renderBody(prev);
    renderBody(file);
  }

  function closeComposer() {
    const cmp = state.composer;
    if (!cmp) return false;
    state.composer = null;
    const file = fileByIndex(cmp.fileIndex);
    if (file) renderBody(file);
    return true;
  }

  async function submitComment() {
    const cmp = state.composer;
    if (!cmp) return;
    const area = ui.files.querySelector(".dv-composer-input");
    const message = (area ? area.value : cmp.draft || "").trim();
    if (!message) return;
    const file = fileByIndex(cmp.fileIndex);
    const existing = cmp.editingId ? state.comments.get(cmp.editingId) : null;
    const rec = buildComment({ file, side: cmp.side, startLine: cmp.start, endLine: cmp.end, message, existing, now: now() });
    cmp.draft = message;
    try {
      const result = await call("comments.save", { comment: rec });
      const saved = normalizeComment(result && result.comment ? result.comment : rec) || rec;
      state.comments.set(saved.id, saved);
    } catch (err) {
      setStatus(t("diff.saveFailed", { message: errorMessage(err) }), "error", true);
      return;
    }
    setStatus("");
    state.composer = null;
    commentsChanged();
  }

  async function deleteComment(id) {
    if (!state.comments.has(id)) return;
    try {
      await call("comments.delete", { id });
    } catch (err) {
      setStatus(t("diff.deleteFailed", { message: errorMessage(err) }), "error", true);
      return;
    }
    state.comments.delete(id);
    if (state.composer && state.composer.editingId === id) state.composer = null;
    commentsChanged();
  }

  function editComment(id) {
    const c = state.comments.get(id);
    const a = state.anchors.get(id);
    if (!c || !a || !a.file || (a.status !== "anchored" && a.status !== "moved")) return;
    expandFile(a.file);
    openComposer(a.file.index, c.side, a.startLine, a.endLine, c);
  }

  async function sendToAgent() {
    const pending = pendingComments(Array.from(state.comments.values())).sort(compareComments);
    if (!pending.length) return;
    let result;
    try {
      result = await call("panel.diff.send_comments", { ids: pending.map((c) => c.id) });
    } catch (err) {
      setStatus(t("diff.sendFailed", { message: errorMessage(err) }), "error", true);
      return;
    }
    const consumed = result && Array.isArray(result.consumed) ? result.consumed : null;
    const stamp = now().toISOString();
    if (consumed) {
      for (const item of consumed) {
        const id = typeof item === "string" ? item : item && item.id;
        const c = state.comments.get(id);
        if (c) c.consumedAt = (item && item.consumedAt) || stamp;
      }
    } else {
      for (const c of pending) c.consumedAt = stamp;
    }
    const count = consumed ? consumed.length : pending.length;
    setStatus(count === 1 ? t("diff.sentOneToAgent") : t("diff.sentToAgent", { count }), "info");
    commentsChanged();
  }

  function renderCommentList() {
    const list = Array.from(state.comments.values()).sort(compareComments);
    ui.commentsList.textContent = "";
    ui.commentsEmpty.hidden = list.length > 0;
    for (const c of list) {
      const a = state.anchors.get(c.id);
      const li = doc.createElement("li");
      li.className = "dv-comments-item";
      const jump = button(c.filePath + ":" + (a ? a.startLine : c.startLine), "jump-comment", { id: c.id });
      jump.className = "dv-comment-jump";
      jump.title = t("diff.commentOn", {
        path: c.filePath,
        lines: linesLabel(c.startLine, c.endLine),
        version: t(c.side === SIDE_DEL ? "diff.oldVersion" : "diff.newVersion"),
      });
      li.append(jump, commentCard(c));
      ui.commentsList.append(li);
    }
    updateToolbar();
  }

  function jumpToComment(id) {
    const a = state.anchors.get(id);
    if (!a || !a.file) return;
    jumpTo(a.file);
    const v = state.views.get(a.file.index);
    const row = v && v.body ? v.body.rowFor(state.comments.get(id).side, a.endLine) : null;
    if (row) scrollViewportTo(docTop(row) - ui.viewport.clientHeight / 3, true);
  }

  function toggleComments(show) {
    const open = show === undefined ? ui.comments.hidden : show;
    ui.comments.hidden = !open;
    ui.commentsToggle.setAttribute("aria-pressed", String(open));
  }

  /* ---------------------------------------------------------------------- */
  /* line selection                                                         */
  /* ---------------------------------------------------------------------- */

  /** {fileIndex, side, line} of a code cell, or null. */
  function cellInfo(cell) {
    if (!cell || !cell.dataset || cell.dataset.line === undefined) return null;
    const section = cell.closest(".dv-file");
    if (!section) return null;
    return { fileIndex: Number(section.dataset.file), side: cell.dataset.side, line: Number(cell.dataset.line) };
  }

  /** Code cell for a clicked line-number cell (split: its side; unified: the row). */
  function codeCellOfNum(num) {
    const next = num.nextElementSibling;
    if (next && next.classList.contains("dv-code")) return next;
    return num.parentNode.querySelector("td.dv-code");
  }

  function applySelection() {
    for (const c of ui.files.querySelectorAll(".dv-selected")) c.classList.remove("dv-selected");
    const s = state.selection;
    if (!s) return;
    const v = state.views.get(s.fileIndex);
    if (!v) return;
    for (const cell of v.section.querySelectorAll(`td.dv-code[data-side="${s.side}"]`)) {
      const n = Number(cell.dataset.line);
      if (cell.dataset.line !== undefined && n >= s.start && n <= s.end) cell.classList.add("dv-selected");
    }
  }

  function selectLine(info, extend) {
    const s = state.selection;
    if (extend && s && s.fileIndex === info.fileIndex && s.side === info.side) {
      state.selection = { ...s, start: Math.min(s.anchor, info.line), end: Math.max(s.anchor, info.line) };
    } else {
      state.selection = { fileIndex: info.fileIndex, side: info.side, start: info.line, end: info.line, anchor: info.line };
    }
    applySelection();
  }

  function addCommentAt(info) {
    const s = state.selection;
    if (s && s.fileIndex === info.fileIndex && s.side === info.side && info.line >= s.start && info.line <= s.end) {
      openComposer(info.fileIndex, info.side, s.start, s.end, null);
    } else {
      openComposer(info.fileIndex, info.side, info.line, info.line, null);
    }
  }

  /* ---------------------------------------------------------------------- */
  /* menu, escape, actions                                                  */
  /* ---------------------------------------------------------------------- */

  function openMenu() {
    ui.menu.hidden = false;
    ui.options.setAttribute("aria-expanded", "true");
    updateToolbar();
    const first = ui.menu.querySelector("[role^=menuitem]:not([hidden])");
    if (first) first.focus();
  }

  function closeMenu() {
    if (ui.menu.hidden) return false;
    ui.menu.hidden = true;
    ui.options.setAttribute("aria-expanded", "false");
    return true;
  }

  /**
   * Escape closes the innermost overlay: comment composer, options menu, file
   * search, then the find bar (find only closes when nothing else owns Escape).
   */
  function handleEscape() {
    const active = doc.activeElement;
    if (state.composer && active && active.classList && active.classList.contains("dv-composer-input")) {
      closeComposer();
      return true;
    }
    if (closeMenu()) {
      ui.options.focus();
      return true;
    }
    if (state.fileSearch.open) {
      closeFileSearch();
      return true;
    }
    if (state.find.open) {
      closeFind();
      return true;
    }
    if (state.selection) {
      state.selection = null;
      applySelection();
      return true;
    }
    return false;
  }

  const actions = {
    diffViewerOpenFileSearch: () => openFileSearch(),
    diffViewerNextFile: () => stepFile(1),
    diffViewerPreviousFile: () => stepFile(-1),
    diffViewerNextHunk: () => stepHunk(1),
    diffViewerPreviousHunk: () => stepHunk(-1),
    diffViewerToggleViewed: () => {
      const f = currentFile();
      if (f) setViewed(f, !isViewed(f));
    },
    find: () => openFind(),
    findNext: () => findStep(1),
    findPrevious: () => findStep(-1),
    hideFind: () => handleEscape(),
    "wmux.diffRefresh": () => load(true),
  };
  for (const id of SCROLL_ACTIONS) actions[id] = () => scrollBy(id);

  function runAction(id) {
    const fn = actions[id];
    if (!fn) return false;
    fn();
    return true;
  }

  function menuCommand(id) {
    switch (id) {
      case "layout":
        setPrefs({ layout: state.prefs.layout === "split" ? "unified" : "split" });
        break;
      case "files":
        state.filesVisible = !state.filesVisible;
        applyPrefClasses();
        updateToolbar();
        saveState();
        break;
      case "search":
        if (state.fileSearch.open) closeFileSearch();
        else openFileSearch();
        return;
      case "expand-all":
        setAllExpanded(!allExpanded());
        break;
      case "refresh":
        load(true);
        break;
      case "copy-apply":
        copyApply();
        break;
      default:
        if (Object.prototype.hasOwnProperty.call(PREF_LABELS, id)) setPrefs({ [id]: !state.prefs[id] });
    }
  }

  /* ---------------------------------------------------------------------- */
  /* session state                                                          */
  /* ---------------------------------------------------------------------- */

  let stateTimer = 0;
  function stateSnapshot() {
    return {
      v: 1,
      prefs: { ...state.prefs },
      files_visible: state.filesVisible,
      top_file: topFilePath(),
      collapsed: Array.from(state.collapsed).slice(0, MAX_STATE_COLLAPSED),
      find: state.find.open ? state.find.query : "",
    };
  }

  function flushState() {
    cancel(stateTimer);
    stateTimer = 0;
    if (!bridge.available || state.destroyed) return;
    bridge.panel.setState(stateSnapshot()).catch(() => {});
  }

  function saveState() {
    cancel(stateTimer);
    stateTimer = later(flushState, STATE_DEBOUNCE_MS);
  }

  function restoreState(saved) {
    if (!saved || typeof saved !== "object") return;
    if (typeof saved.files_visible === "boolean") state.filesVisible = saved.files_visible;
    if (Array.isArray(saved.collapsed)) {
      for (const p of saved.collapsed.slice(0, MAX_STATE_COLLAPSED)) if (typeof p === "string") state.collapsed.add(p);
    }
  }

  /* ---------------------------------------------------------------------- */
  /* DOM wiring                                                             */
  /* ---------------------------------------------------------------------- */

  function sectionFile(node) {
    const section = node && node.closest ? node.closest(".dv-file") : null;
    return section ? fileByIndex(Number(section.dataset.file)) : null;
  }

  function onFilesClick(e) {
    const target = e.target;
    if (!target || !target.closest) return;
    const actionEl = target.closest("[data-action]");
    const action = actionEl ? actionEl.dataset.action : "";
    const file = sectionFile(target);
    switch (action) {
      case "toggle-file":
        if (file) toggleFile(file);
        return;
      case "load-diff":
        if (file) loadDeferred(file);
        return;
      case "expand-gap": {
        const v = file && state.views.get(file.index);
        if (v && v.body && v.body.expandGap(actionEl.closest("tr"))) {
          applySelection();
          if (state.find.open) highlightFindIn(file.index);
        }
        return;
      }
      case "add-comment": {
        const info = cellInfo(actionEl.closest("td.dv-code"));
        if (info) addCommentAt(info);
        return;
      }
      case "submit-comment":
        submitComment();
        return;
      case "cancel-comment":
        closeComposer();
        return;
      case "edit-comment":
        editComment(actionEl.dataset.id);
        return;
      case "delete-comment":
        deleteComment(actionEl.dataset.id);
        return;
      default:
        break;
    }
    const num = target.closest("td.dv-num");
    if (num && num.dataset.line !== undefined) {
      const info = cellInfo(codeCellOfNum(num));
      if (info) selectLine(info, e.shiftKey);
    }
  }

  function onComposerInput(e) {
    if (!e.target.classList.contains("dv-composer-input") || !state.composer) return;
    state.composer.draft = e.target.value;
    const submit = e.target.parentNode.querySelector('[data-action="submit-comment"]');
    if (submit) submit.disabled = !e.target.value.trim();
  }

  function onComposerKey(e) {
    if (!e.target.classList || !e.target.classList.contains("dv-composer-input")) return;
    if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      submitComment();
    } else if (e.key === "Escape") {
      e.preventDefault();
      closeComposer();
    }
  }

  function wireDom() {
    listen(ui.files, "click", onFilesClick);
    listen(ui.files, "input", onComposerInput);
    listen(ui.files, "keydown", onComposerKey);
    listen(ui.files, "change", (e) => {
      if (e.target.dataset && e.target.dataset.action === "toggle-viewed") {
        const file = sectionFile(e.target);
        if (file) setViewed(file, e.target.checked);
      }
    });
    listen(ui.commentsList, "click", (e) => {
      const el = e.target.closest ? e.target.closest("[data-action]") : null;
      if (!el) return;
      if (el.dataset.action === "jump-comment") jumpToComment(el.dataset.id);
      else if (el.dataset.action === "edit-comment") editComment(el.dataset.id);
      else if (el.dataset.action === "delete-comment") deleteComment(el.dataset.id);
    });
    listen(ui.layout, "click", () => menuCommand("layout"));
    listen(ui.filesToggle, "click", () => menuCommand("files"));
    listen(ui.searchToggle, "click", () => menuCommand("search"));
    listen(ui.expandAll, "click", () => menuCommand("expand-all"));
    listen(ui.refresh, "click", () => menuCommand("refresh"));
    listen(ui.copyApply, "click", () => menuCommand("copy-apply"));
    listen(ui.commentsToggle, "click", () => toggleComments());
    listen(ui.send, "click", () => sendToAgent());
    listen(ui.options, "click", (e) => {
      e.stopPropagation();
      if (ui.menu.hidden) openMenu();
      else closeMenu();
    });
    listen(ui.menu, "click", (e) => {
      e.stopPropagation();
      const item = e.target.closest ? e.target.closest("[data-menu], [data-indicator]") : null;
      if (!item) return;
      if (item.dataset.indicator) setPrefs({ diffIndicators: item.dataset.indicator });
      else {
        closeMenu();
        menuCommand(item.dataset.menu);
      }
    });
    listen(ui.contextLines, "change", () => {
      const n = Math.round(Number(ui.contextLines.value));
      if (Number.isFinite(n)) setPrefs({ contextLines: Math.min(CONTEXT_LINES.max, Math.max(CONTEXT_LINES.min, n)) });
      ui.contextLines.value = String(state.prefs.contextLines);
    });
    listen(doc, "click", (e) => {
      if (!ui.menu.hidden && !ui.menu.contains(e.target)) closeMenu();
    });
    // Escape normally reaches handleEscape through keys.js (hideFind), which
    // consumes it. The host keymap replaces the defaults and may lack that
    // binding (its when-clause is findVisible, which native cannot see for
    // the page's own find bar), so the page's overlays still close here.
    // Fields with their own Escape handling mark the event handled first.
    listen(doc, "keydown", (e) => {
      if (e.key !== "Escape" || e.defaultPrevented || e.isComposing) return;
      if (handleEscape()) e.preventDefault();
    });
    listen(ui.filterInput, "input", () => setFilter({ query: ui.filterInput.value }));
    for (const box of ui.statusBoxes) {
      listen(box, "change", () => setFilter({ statuses: ui.statusBoxes.filter((b) => b.checked).map((b) => b.dataset.status) }));
    }
    listen(ui.hideViewed, "click", () => setFilter({ hideViewed: !state.filter.hideViewed }));
    listen(ui.filterClear, "click", () => clearFilter());
    listen(ui.filesClear, "click", () => clearFilter());
    listen(ui.tree, "click", (e) => {
      const item = e.target.closest ? e.target.closest(".dv-tree-item") : null;
      const file = item ? fileByIndex(Number(item.dataset.file)) : null;
      if (file) jumpTo(file);
    });
    listen(ui.fileSearchInput, "input", () => updateFileSearch());
    listen(ui.fileSearchInput, "keydown", (e) => {
      const fs = state.fileSearch;
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        if (fs.results.length) fs.active = cycle(fs.active, fs.results.length, e.key === "ArrowDown" ? 1 : -1);
        renderFileSearch();
      } else if (e.key === "Enter") {
        e.preventDefault();
        chooseFileSearch(fs.active);
      } else if (e.key === "Escape") {
        e.preventDefault();
        closeFileSearch();
      }
    });
    listen(ui.fileSearchList, "click", (e) => {
      const li = e.target.closest ? e.target.closest(".dv-filesearch-item") : null;
      if (li) chooseFileSearch(state.fileSearch.results.findIndex((f) => String(f.index) === li.dataset.file));
    });
    listen(ui.findInput, "input", () => {
      state.find.query = ui.findInput.value;
      runFind(true);
    });
    listen(ui.findInput, "keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        findStep(e.shiftKey ? -1 : 1);
      } else if (e.key === "Escape") {
        e.preventDefault();
        handleEscape();
      }
    });
    listen(ui.findPrev, "click", () => findStep(-1));
    listen(ui.findNext, "click", () => findStep(1));
    listen(ui.findClose, "click", () => closeFind());
    listen(ui.viewport, "scroll", () => saveState(), { passive: true });
    listen(view, "pagehide", () => flushState());
  }

  /* ---------------------------------------------------------------------- */
  /* bridge, keys, start                                                    */
  /* ---------------------------------------------------------------------- */

  function wireBridge() {
    cleanups.push(
      bridge.on("panel.diff.patch", (payload) => {
        if (payload && typeof payload.patch === "string") loadPatch(payload.patch, payload);
      }),
      bridge.on("panel.diff.comments_changed", (payload) => {
        if (payload && Array.isArray(payload.comments)) {
          acceptComments(payload.comments);
          commentsChanged();
        } else loadComments().then(() => commentsChanged());
      }),
      bridge.on("panel.diff.viewed_changed", async (payload) => {
        if (payload && (Array.isArray(payload.files) || payload.viewed)) acceptViewedList(payload);
        else await loadViewed();
        for (const f of state.files) refreshShell(f);
        renderTree();
        updateStats();
        updateToolbar();
      }),
      bridge.on("panel.diff.command", (payload) => {
        if (payload && typeof payload.action === "string") runAction(payload.action);
      }),
      bridge.on("panel.diff.find", (payload) => {
        openFind(payload && typeof payload.query === "string" ? payload.query : "");
      }),
    );
    cleanups.push(onThemeChange((theme) => applyHighlightTheme(theme.scheme)));
  }

  function applyHighlightTheme(scheme) {
    const light = scheme === "light";
    if (ui.hljsLight) ui.hljsLight.media = light ? "all" : "not all";
    if (ui.hljsDark) ui.hljsDark.media = light ? "not all" : "all";
  }

  function installKeyboard() {
    const keys = (opts.installKeys || installKeys)();
    keys.setKeymap(DEFAULT_KEYMAP);
    if (bridge.context && bridge.context.keymap !== undefined) keys.setKeymap(bridge.context.keymap);
    for (const id of Object.keys(actions)) cleanups.push(keys.handle(id, () => runAction(id)));
    return keys;
  }

  function applyInit(ctx) {
    const params = ctx && ctx.params && typeof ctx.params === "object" ? ctx.params : {};
    const saved = ctx && ctx.state && typeof ctx.state === "object" ? ctx.state : null;
    state.params = params;
    state.prefs = resolvePrefs({ params, prefs: params.prefs, settings: ctx && ctx.settings, state: saved });
    state.fontSizePt = resolveFontSize(params);
    acceptMeta({ generated: params.generated, apply_command: params.apply_command });
    restoreState(saved);
    setTitle(typeof params.title === "string" ? params.title : "");
    applyPrefClasses();
  }

  async function start() {
    if (state.started) return api;
    state.started = true;
    applyStrings(doc);
    applyHighlightTheme(currentScheme());
    showMessage(t("diff.loadingRenderer"));
    wireDom();
    wireBridge();
    const keys = installKeyboard();
    applyPrefClasses();
    updateToolbar();
    renderCommentList();

    if (!bridge.available) {
      setTitle("");
      showMessage(t("diff.offline"), "info");
      return api;
    }
    let ctx = null;
    try {
      ctx = await bridge.ready(opts.readyTimeoutMs !== undefined ? { timeoutMs: opts.readyTimeoutMs } : undefined);
    } catch (err) {
      console.warn("[diff] panel.ready failed:", errorMessage(err));
    }
    if (state.destroyed) return api;
    if (bridge.context) ctx = bridge.context;
    if (ctx && ctx.keymap !== undefined) keys.setKeymap(ctx.keymap);
    applyInit(ctx);
    await Promise.all([loadViewed(), loadComments()]);
    if (state.destroyed) return api;
    await load(false);
    if (state.destroyed) return api;
    const saved = ctx && ctx.state && typeof ctx.state === "object" ? ctx.state : null;
    if (saved && typeof saved.top_file === "string") {
      const f = fileByPath(saved.top_file);
      if (f) scrollToFile(f, false);
    }
    const initialFind = typeof state.params.find === "string" ? state.params.find : saved && typeof saved.find === "string" ? saved.find : "";
    if (initialFind) openFind(initialFind);
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
  }

  const api = {
    start,
    destroy,
    load,
    loadPatch,
    runAction,
    setPrefs,
    setFilter,
    clearFilter,
    setViewed,
    clearViewed,
    toggleFile,
    setAllExpanded,
    openFind,
    closeFind,
    openFileSearch,
    closeFileSearch,
    openComposer,
    submitComment,
    deleteComment,
    sendToAgent,
    handleEscape,
    copyApply,
    stateSnapshot,
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
    if (!node) throw new Error("diff: missing #" + id);
    return node;
  };
  const sidebar = el("dv-sidebar");
  return {
    root: doc.documentElement,
    body: doc.querySelector(".dv-body"),
    title: el("dv-title"),
    statsAdd: el("dv-stats-add"),
    statsDel: el("dv-stats-del"),
    progress: el("dv-progress"),
    status: el("dv-status"),
    filesToggle: el("dv-files-toggle"),
    layout: el("dv-layout"),
    searchToggle: el("dv-search-toggle"),
    expandAll: el("dv-expand-all"),
    refresh: el("dv-refresh"),
    copyApply: el("dv-copy-apply"),
    commentsToggle: el("dv-comments-toggle"),
    options: el("dv-options"),
    menu: el("dv-options-menu"),
    contextLines: el("dv-context-lines"),
    fileSearch: el("dv-filesearch"),
    fileSearchInput: el("dv-filesearch-input"),
    fileSearchList: el("dv-filesearch-list"),
    find: el("dv-find"),
    findInput: el("dv-find-input"),
    findCount: el("dv-find-count"),
    findPrev: el("dv-find-prev"),
    findNext: el("dv-find-next"),
    findClose: el("dv-find-close"),
    sidebar,
    sidebarTitle: el("dv-sidebar-title"),
    filterInput: el("dv-filter-input"),
    statusBoxes: Array.from(sidebar.querySelectorAll("input[data-status]")),
    hideViewed: el("dv-hide-viewed"),
    tree: el("dv-tree"),
    filterEmpty: el("dv-filter-empty"),
    filterClear: el("dv-filter-clear"),
    viewport: el("dv-viewport"),
    message: el("dv-message"),
    files: el("dv-files"),
    filesEmpty: el("dv-files-empty"),
    filesClear: el("dv-files-clear"),
    comments: el("dv-comments"),
    commentsEmpty: el("dv-comments-empty"),
    commentsList: el("dv-comments-list"),
    send: el("dv-send"),
    hljsLight: doc.getElementById("dv-hljs-light"),
    hljsDark: doc.getElementById("dv-hljs-dark"),
  };
}
