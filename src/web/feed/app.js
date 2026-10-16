/**
 * Feed panel application: PanelKind "feed" (ARCHITECTURE ADR-6.11, ADR-11
 * right-sidebar mode), entry https://feed.wmux.example/feed/index.html.
 * Agent decision requests and activity, latest first, with the Actionable
 * and All Activity tabs, decision cards, todo snapshots, jump to the agent's
 * surface and in-panel banners for new pending decisions. The native contract
 * is documented in README.md.
 *
 *   const app = createApp({ document, renderMarkdown });
 *   await app.start();
 *
 * Everything is injectable (document, bridge, clock, keys, markdown renderer)
 * so the jsdom tests in test/web-node/feed/ drive the real code.
 */
import { wmux as defaultBridge } from "../_shared/wmux-bridge.js";
import { installKeys } from "../_shared/keys.js";
import { applyStrings } from "../_shared/strings.js";
import { createCards, newUiState } from "./cards.js";
import {
  PAGE_LIMIT,
  bannerText,
  buildSelections,
  canReply,
  frameName,
  isDecision,
  isFeedEvent,
  isPending,
  itemsFrom,
  localResolution,
  mergeItems,
  normalizeItem,
  partition,
  sourceDisplayName,
  supersededStops,
  workstreams,
} from "./model.js";
import { t } from "./strings.js";

/** Keymap defaults; panel.init.keymap replaces them. */
export const DEFAULT_KEYMAP = Object.freeze({});

const RELOAD_DEBOUNCE_MS = 40;
const STATE_DEBOUNCE_MS = 400;
const STATUS_MS = 3000;
const TIME_REFRESH_MS = 30000;
const MAX_BANNERS = 3;
/** Longest a pointer press holds back renders (a release the page never sees). */
const PRESS_MAX_MS = 2000;
/**
 * v2 error codes (ADR-3.5, wmux_proto/errors.zig) that mean the request is
 * gone: unknown request id, or no longer pending (answered elsewhere, timed
 * out, expired).
 */
const GONE_CODES = new Set(["not_found", "invalid_state", "stale_state"]);

/**
 * @param {{
 *   document: Document,
 *   bridge?: object,
 *   now?: () => number,
 *   installKeys?: Function,
 *   renderMarkdown?: (text: string) => Node|null,
 * }} options
 */
export function createApp(options) {
  const doc = options.document;
  const win = doc.defaultView;
  const bridge = options.bridge || defaultBridge;
  const now = options.now || (() => Date.now());
  const $ = (id) => doc.getElementById(id);
  const els = {
    tabs: Array.from(doc.querySelectorAll(".feed-tabs [role=tab]")),
    pendingCount: $("feed-pending-count"),
    banners: $("feed-banners"),
    workstreams: $("feed-workstreams"),
    status: $("feed-status"),
    viewport: $("feed-viewport"),
    list: $("feed-list"),
    loadOlder: $("feed-load-older"),
    empty: $("feed-empty"),
    emptyTitle: $("feed-empty-title"),
    emptyBody: $("feed-empty-body"),
  };
  const state = {
    filter: "actionable",
    items: [],
    hasMore: false,
    olderLoaded: false,
    loadingOlder: false,
    loaded: false,
    ui: new Map(),
    /** id -> resolution answered here, until native reports the item closed. */
    localResolved: new Map(),
    /** Pending decisions that arrived after the first load and are not reviewed. */
    banners: [],
    knownIds: new Set(),
    focusedId: null,
    destroyed: false,
    loadSeq: 0,
    reloadTimer: null,
    stateTimer: null,
    statusTimer: null,
    timeTimer: null,
    /** A primary pointer button is down; renders wait for its release. */
    pressed: false,
    renderDeferred: false,
    pressTimer: null,
  };
  const cards = createCards({ document: doc, t, now, renderMarkdown: options.renderMarkdown });
  const cleanups = [];
  let keys = null;

  function listen(target, type, fn, opts) {
    target.addEventListener(type, fn, opts);
    cleanups.push(() => target.removeEventListener(type, fn, opts));
  }

  function el(tag, className, text) {
    const node = doc.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function setStatus(text) {
    els.status.textContent = text || "";
    if (state.statusTimer) win.clearTimeout(state.statusTimer);
    state.statusTimer = text ? win.setTimeout(() => (els.status.textContent = ""), STATUS_MS) : null;
  }

  function errorMessage(err) {
    return (err && err.message) || String(err);
  }

  function find(id) {
    return state.items.find((it) => it.id === id) || null;
  }

  function uiFor(id) {
    let ui = state.ui.get(id);
    if (!ui) {
      ui = newUiState();
      state.ui.set(id, ui);
    }
    return ui;
  }

  function cardFor(id) {
    for (const card of els.list.querySelectorAll(".feed-card")) if (card.dataset.id === id) return card;
    return null;
  }

  /* ------------------------------------------------------------- rendering */

  /**
   * Items with answers given here applied until native reports them closed,
   * and stop items whose agent went on marked `superseded` (no reply box).
   */
  function effectiveItems() {
    const stale = supersededStops(state.items);
    if (state.localResolved.size === 0 && stale.size === 0) return state.items;
    return state.items.map((it) => {
      let out = it;
      const r = state.localResolved.get(it.id);
      if (r && it.kind === "stop") out = it.resolution ? it : { ...it, resolution: r };
      else if (r && isPending(it)) out = { ...it, status: "resolved", resolution: r };
      return stale.has(it.id) ? { ...out, superseded: true } : out;
    });
  }

  function renderTabs(items) {
    for (const tab of els.tabs) {
      const on = tab.dataset.filter === state.filter;
      tab.setAttribute("aria-selected", on ? "true" : "false");
      tab.tabIndex = on ? 0 : -1;
      if (on) els.viewport.setAttribute("aria-labelledby", tab.id);
    }
    const pending = items.filter((it) => isDecision(it) && isPending(it)).length;
    els.pendingCount.hidden = pending === 0;
    els.pendingCount.textContent = pending > 99 ? "99+" : String(pending);
  }

  function renderBanners(items) {
    const byId = new Map(items.map((it) => [it.id, it]));
    state.banners = state.banners.filter((id) => {
      const it = byId.get(id);
      return it && isDecision(it) && isPending(it);
    });
    const nodes = [];
    for (const id of state.banners.slice(0, MAX_BANNERS)) {
      const it = byId.get(id);
      const text = bannerText(it);
      if (!text) continue;
      const banner = el("div", "feed-banner");
      banner.dataset.id = id;
      banner.setAttribute("role", "group");
      const body = el("div", "feed-banner-text");
      body.append(el("strong", "feed-banner-title", t(text.title[0], text.title[1])));
      body.append(el("span", "feed-banner-body", t(text.body[0], text.body[1])));
      banner.append(body);
      const review = el("button", "wmux-primary", t("feed.banner.review"));
      review.type = "button";
      review.dataset.action = "banner-review";
      banner.append(review);
      const close = el("button", "feed-icon-button", "✕");
      close.type = "button";
      close.dataset.action = "banner-dismiss";
      close.title = t("feed.banner.dismiss");
      close.setAttribute("aria-label", t("feed.banner.dismiss"));
      banner.append(close);
      banner.setAttribute("aria-label", body.textContent);
      nodes.push(banner);
    }
    els.banners.replaceChildren(...nodes);
    els.banners.hidden = nodes.length === 0;
  }

  function renderWorkstreams(items) {
    const streams = workstreams(items).filter((w) => w.surface_id || w.workspace_id);
    if (streams.length < 2) {
      els.workstreams.replaceChildren();
      els.workstreams.hidden = true;
      return;
    }
    const nodes = streams.slice(0, 12).map((w) => {
      const chip = el("button", "feed-stream");
      chip.type = "button";
      chip.dataset.action = "jump-stream";
      chip.dataset.id = w.latest.id;
      const name = sourceDisplayName(w.source) + (w.session_id ? " · " + w.session_id.slice(0, 8) : "");
      chip.append(el("span", "", name));
      if (w.pending_count > 0) {
        const badge = el("span", "feed-count", String(w.pending_count));
        badge.setAttribute("aria-label", t("feed.workstream.pending", { count: w.pending_count }));
        chip.append(badge);
      }
      chip.title = t("feed.jump");
      return chip;
    });
    els.workstreams.replaceChildren(...nodes);
    els.workstreams.hidden = false;
  }

  /** What has focus inside the list, so a re-render can put it back. */
  function captureFocus() {
    const active = doc.activeElement;
    if (!active || !els.list.contains(active)) return null;
    const card = active.closest(".feed-card");
    if (!card) return null;
    const snap = { id: card.dataset.id, self: active === card };
    if (active.dataset.field) {
      snap.field = active.dataset.field;
      snap.q = active.dataset.q;
      if (typeof active.selectionStart === "number") snap.sel = [active.selectionStart, active.selectionEnd];
    } else if (active.dataset.action) {
      snap.action = active.dataset.action;
      snap.mode = active.dataset.mode;
      snap.label = active.dataset.label;
      // Option buttons repeat labels across questions ("Yes"/"No" in each).
      snap.q = active.dataset.q;
    }
    return snap;
  }

  function restoreFocus(snap) {
    if (!snap) return;
    const card = cardFor(snap.id);
    if (!card) return;
    let target = card;
    if (snap.field) {
      target = Array.from(card.querySelectorAll("[data-field]")).find((n) => n.dataset.field === snap.field && n.dataset.q === snap.q) || card;
    } else if (snap.action) {
      target =
        Array.from(card.querySelectorAll("[data-action]")).find(
          (n) =>
            n.dataset.action === snap.action &&
            n.dataset.mode === snap.mode &&
            n.dataset.label === snap.label &&
            n.dataset.q === snap.q &&
            !n.disabled,
        ) || card;
    }
    target.focus({ preventScroll: true });
    if (snap.sel && target.dataset.field && typeof target.setSelectionRange === "function") {
      try {
        target.setSelectionRange(snap.sel[0], snap.sel[1]);
      } catch {
        // inputs without a selection API
      }
    }
  }

  /** Inner scroll boxes of a card: the plan (field "") and the text boxes. */
  const SCROLLERS = ".feed-plan, textarea[data-field]";

  /**
   * Scroll offsets of the inner scroll boxes. Every render rebuilds the cards,
   * so without this a long plan jumps back to its top on each live update.
   */
  function captureScroll() {
    const saved = [];
    for (const node of els.list.querySelectorAll(SCROLLERS)) {
      if (!node.scrollTop && !node.scrollLeft) continue;
      const card = node.closest(".feed-card");
      if (card) saved.push({ id: card.dataset.id, field: node.dataset.field || "", top: node.scrollTop, left: node.scrollLeft });
    }
    return saved;
  }

  function restoreScroll(saved) {
    for (const s of saved) {
      const card = cardFor(s.id);
      const node = card && Array.from(card.querySelectorAll(SCROLLERS)).find((n) => (n.dataset.field || "") === s.field);
      if (!node) continue;
      node.scrollTop = s.top;
      node.scrollLeft = s.left;
    }
  }

  function visibleItems(items) {
    if (state.filter === "activity") return { main: items, resolved: [] };
    const p = partition(items);
    return { main: p.pending, resolved: p.resolved };
  }

  function renderList(items) {
    const snap = captureFocus();
    const scrolls = captureScroll();
    const view = visibleItems(items);
    const nodes = view.main.map((it) => cards.buildCard(it, uiFor(it.id)));
    if (view.resolved.length) {
      const divider = el("div", "feed-divider", t("feed.resolved"));
      divider.setAttribute("role", "separator");
      nodes.push(divider);
      for (const it of view.resolved) nodes.push(cards.buildCard(it, uiFor(it.id)));
    }
    els.list.replaceChildren(...nodes);
    const ids = cardIds();
    if (!ids.includes(state.focusedId)) state.focusedId = ids[0] || null;
    for (const card of els.list.querySelectorAll(".feed-card")) card.tabIndex = card.dataset.id === state.focusedId ? 0 : -1;
    restoreFocus(snap);
    restoreScroll(scrolls);

    const empty = view.main.length === 0 && view.resolved.length === 0;
    els.empty.hidden = !empty || !state.loaded;
    if (empty) {
      const which = state.filter === "activity" ? "activity" : "actionable";
      els.emptyTitle.textContent = t(`feed.empty.${which}.title`);
      els.emptyBody.textContent = t(`feed.empty.${which}.body`);
    }
    els.loadOlder.hidden = !state.hasMore;
    els.loadOlder.disabled = state.loadingOlder;
    els.loadOlder.textContent = t(state.loadingOlder ? "feed.loadingOlder" : "feed.loadOlder");
  }

  function cardIds() {
    return Array.from(els.list.querySelectorAll(".feed-card"), (c) => c.dataset.id);
  }

  function render() {
    // A render rebuilds the cards, banners and chips. Between pointerdown and
    // pointerup it would replace the pressed button, and the browser drops a
    // click whose mousedown target left the document. Busy feeds update
    // several times a second, so renders wait for the release.
    if (state.pressed) {
      state.renderDeferred = true;
      return;
    }
    const items = effectiveItems();
    renderTabs(items);
    renderBanners(items);
    renderWorkstreams(items);
    renderList(items);
  }

  function onPointerDown(e) {
    if (typeof e.button === "number" && e.button !== 0) return;
    state.pressed = true;
    if (state.pressTimer) win.clearTimeout(state.pressTimer);
    state.pressTimer = win.setTimeout(releasePress, PRESS_MAX_MS);
  }

  function releasePress() {
    if (state.pressTimer) win.clearTimeout(state.pressTimer);
    state.pressTimer = null;
    if (!state.pressed) return;
    state.pressed = false;
    if (!state.renderDeferred) return;
    state.renderDeferred = false;
    // Runs after the click that this pointerup produces.
    win.setTimeout(() => {
      if (!state.destroyed) render();
    }, 0);
  }

  /* ----------------------------------------------------------------- data */

  /**
   * Records new ids; pending decisions that arrive after the first load get a
   * banner. Local answers are dropped once native reports the item closed.
   */
  function noteItems(items, live) {
    for (const it of items) {
      if (!state.knownIds.has(it.id)) {
        state.knownIds.add(it.id);
        if (live && isDecision(it) && isPending(it) && !state.banners.includes(it.id)) state.banners.unshift(it.id);
      }
      if (state.localResolved.has(it.id) && (it.kind === "stop" ? it.resolution : !isPending(it))) state.localResolved.delete(it.id);
    }
  }

  function applyPage(result) {
    const page = itemsFrom(result);
    noteItems(page, state.loaded);
    if (state.olderLoaded && page.length > 0) {
      // Keep the history paged in with "Load older activity".
      const oldest = page[page.length - 1].created_at_ms;
      state.items = mergeItems(state.items.filter((it) => it.created_at_ms < oldest), page);
    } else {
      state.items = page;
      state.hasMore = !!(result && result.has_more === true);
    }
    const ids = new Set(state.items.map((it) => it.id));
    for (const id of state.ui.keys()) if (!ids.has(id)) state.ui.delete(id);
    // Ids that left the window never return in a newer page (items keep their
    // place in the store), so the long-lived panel does not keep them.
    for (const id of state.knownIds) if (!ids.has(id)) state.knownIds.delete(id);
    for (const id of state.localResolved.keys()) if (!ids.has(id)) state.localResolved.delete(id);
    state.loaded = true;
    render();
  }

  /** Fetches the newest page (`feed.list`); only the newest load applies. */
  async function reload() {
    const seq = ++state.loadSeq;
    try {
      const result = await bridge.call("feed.list", { limit: PAGE_LIMIT });
      if (seq !== state.loadSeq || state.destroyed) return;
      applyPage(result);
    } catch (err) {
      if (seq !== state.loadSeq || state.destroyed) return;
      setStatus(t("feed.status.loadFailed", { message: errorMessage(err) }));
      if (!state.loaded) {
        state.loaded = true;
        render();
      }
    }
  }

  async function loadOlder() {
    if (state.loadingOlder || !state.hasMore || state.items.length === 0) return;
    state.loadingOlder = true;
    render();
    const before = state.items[state.items.length - 1].id;
    try {
      const result = await bridge.call("feed.list", { before, limit: PAGE_LIMIT });
      if (state.destroyed) return;
      const page = itemsFrom(result);
      noteItems(page, false);
      state.items = mergeItems(state.items, page);
      state.hasMore = !!(result && result.has_more === true);
      state.olderLoaded = true;
    } catch (err) {
      setStatus(t("feed.status.loadFailed", { message: errorMessage(err) }));
    } finally {
      state.loadingOlder = false;
      if (!state.destroyed) render();
    }
  }

  /** `panel.feed.item {item}`: insert or replace one item. */
  function upsert(payload) {
    const it = normalizeItem(payload && payload.item ? payload.item : payload);
    if (!it) return;
    noteItems([it], true);
    state.items = mergeItems(state.items, [it]);
    render();
  }

  function scheduleReload() {
    if (state.reloadTimer) win.clearTimeout(state.reloadTimer);
    state.reloadTimer = win.setTimeout(() => {
      state.reloadTimer = null;
      reload();
    }, RELOAD_DEBOUNCE_MS);
  }

  function onFrame(frame) {
    if (isFeedEvent(frameName(frame))) scheduleReload();
  }

  function saveState() {
    if (state.stateTimer) win.clearTimeout(state.stateTimer);
    state.stateTimer = win.setTimeout(() => {
      state.stateTimer = null;
      if (bridge.available) bridge.panel.setState({ v: 1, filter: state.filter }).catch(() => {});
    }, STATE_DEBOUNCE_MS);
  }

  /* ------------------------------------------------------------ decisions */

  /**
   * Sends one decision. The card shows "Sending…" and, on success, the
   * resolved badge right away; native's resolution event then reloads it.
   */
  async function decide(id, method, params, reply) {
    const item = find(id);
    if (!item) return false;
    const ui = uiFor(id);
    if (ui.sending) return false;
    ui.sending = true;
    ui.error = "";
    render();
    try {
      await bridge.call(method, params);
      if (state.destroyed) return true;
      ui.sending = false;
      state.localResolved.set(id, localResolution(item.kind, reply));
      state.banners = state.banners.filter((b) => b !== id);
      render();
      scheduleReload();
      return true;
    } catch (err) {
      if (state.destroyed) return false;
      ui.sending = false;
      ui.error = err && GONE_CODES.has(err.code) ? t("feed.status.alreadyResolved") : t("feed.status.replyFailed", { message: errorMessage(err) });
      render();
      scheduleReload();
      return false;
    }
  }

  function replyPermission(id, mode) {
    const item = find(id);
    if (!item || !canReply(item)) return Promise.resolve(false);
    return decide(id, "feed.permission.reply", { request_id: item.request_id, mode }, { mode });
  }

  function replyPlan(id, mode, feedback) {
    const item = find(id);
    if (!item || !canReply(item)) return Promise.resolve(false);
    const params = { request_id: item.request_id, mode };
    const text = typeof feedback === "string" ? feedback.trim() : "";
    if (text) params.feedback = text;
    return decide(id, "feed.exit_plan.reply", params, { mode, feedback: text || undefined });
  }

  function replyQuestion(id) {
    const item = find(id);
    if (!item || !canReply(item)) return Promise.resolve(false);
    const ui = uiFor(id);
    const questions = item.questions.length ? item.questions : [{ question: "", header: "", multi_select: false, options: [] }];
    questions.forEach((_, qi) => cards.answerOf(ui, qi));
    const built = buildSelections(questions, ui.answers);
    if (built.selections.length === 0) return Promise.resolve(false);
    const params = { request_id: item.request_id, selections: built.selections };
    if (questions.length > 1) params.answers = built.answers;
    return decide(id, "feed.question.reply", params, { selections: built.selections });
  }

  function replyStop(id, text) {
    const item = find(id);
    const body = typeof text === "string" ? text.trim() : "";
    if (!item || item.kind !== "stop" || !body) return Promise.resolve(false);
    // The agent went on since this stop: the text would be typed into its
    // terminal as it is now, not as a reply to this turn.
    if (supersededStops(state.items).has(id)) return Promise.resolve(false);
    const params = { id, text: body };
    for (const key of ["request_id", "session_id", "workspace_id", "surface_id"]) if (item[key]) params[key] = item[key];
    if (item.source) params.source = item.source;
    return decide(id, "panel.feed.stop_reply", params, { text: body });
  }

  async function jump(id) {
    const item = find(id);
    if (!item) return false;
    const params = { id };
    for (const key of ["workspace_id", "surface_id", "session_id"]) if (item[key]) params[key] = item[key];
    if (item.source) params.source = item.source;
    try {
      await bridge.call("feed.jump", params);
      return true;
    } catch (err) {
      setStatus(err && err.code === "not_found" ? t("feed.jump.unavailable") : t("feed.jump.failed", { message: errorMessage(err) }));
      return false;
    }
  }

  /* --------------------------------------------------------- interaction */

  function setFilter(filter, focusTab = false) {
    if (filter !== "actionable" && filter !== "activity") return;
    if (state.filter !== filter) {
      state.filter = filter;
      saveState();
      render();
    }
    if (focusTab) {
      const tab = els.tabs.find((x) => x.dataset.filter === filter);
      if (tab) tab.focus();
    }
  }

  function focusCard(id, scroll = true) {
    const card = cardFor(id);
    if (!card) return false;
    state.focusedId = id;
    for (const c of els.list.querySelectorAll(".feed-card")) c.tabIndex = c === card ? 0 : -1;
    card.focus({ preventScroll: true });
    if (scroll && typeof card.scrollIntoView === "function") card.scrollIntoView({ block: "nearest" });
    return true;
  }

  /** Banner Review: show the card (Actionable tab) and focus it. */
  function review(id) {
    state.banners = state.banners.filter((b) => b !== id);
    if (state.filter !== "actionable") state.filter = "actionable";
    saveState();
    render();
    focusCard(id);
  }

  function updateSubmitState(card, id) {
    const item = find(id);
    if (!item) return;
    const ui = uiFor(id);
    const send = (action, enabled) => {
      const b = card.querySelector(`[data-action="${action}"]`);
      if (b) b.disabled = ui.sending || !enabled;
    };
    send("plan-feedback", ui.feedback.trim() !== "");
    send("stop-reply", ui.reply.trim() !== "");
    send("submit-question", cards.questionsAnswered(item, ui));
  }

  function onInput(e) {
    const field = e.target.dataset && e.target.dataset.field;
    const card = e.target.closest && e.target.closest(".feed-card");
    if (!field || !card) return;
    const id = card.dataset.id;
    const ui = uiFor(id);
    if (field === "feedback") ui.feedback = e.target.value;
    else if (field === "reply") ui.reply = e.target.value;
    else if (field === "other") cards.answerOf(ui, Number(e.target.dataset.q) || 0).other = e.target.value;
    updateSubmitState(card, id);
  }

  function runAction(action, target, id) {
    const ui = id ? uiFor(id) : null;
    switch (action) {
      case "permission":
        return replyPermission(id, target.dataset.mode);
      case "plan":
        return replyPlan(id, target.dataset.mode);
      case "revise":
        ui.reviseOpen = !ui.reviseOpen;
        render();
        if (ui.reviseOpen) {
          const area = cardFor(id) && cardFor(id).querySelector('[data-field="feedback"]');
          if (area) area.focus();
        }
        return undefined;
      case "plan-feedback":
        return replyPlan(id, "deny", ui.feedback);
      case "option": {
        const item = find(id);
        const qi = Number(target.dataset.q) || 0;
        const q = item && item.questions[qi];
        if (!q) return undefined;
        const answer = cards.answerOf(ui, qi);
        const label = target.dataset.label;
        if (q.multi_select) {
          if (answer.selected.has(label)) answer.selected.delete(label);
          else answer.selected.add(label);
        } else {
          answer.selected = new Set([label]);
          answer.other = "";
          // One single-choice question: the option button answers it.
          if (item.questions.length === 1) return replyQuestion(id);
        }
        render();
        return undefined;
      }
      case "submit-question":
        return replyQuestion(id);
      case "stop-reply":
        return replyStop(id, ui.reply);
      case "toggle-todos":
        ui.expanded = !ui.expanded;
        render();
        return undefined;
      case "jump":
      case "jump-stream":
        return jump(id);
      case "banner-review":
        return review(id);
      case "banner-dismiss":
        state.banners = state.banners.filter((b) => b !== id);
        render();
        return undefined;
      default:
        return undefined;
    }
  }

  function onClick(e) {
    const target = e.target.closest && e.target.closest("[data-action]");
    if (!target || target.disabled) return;
    const holder = target.closest(".feed-card, .feed-banner") || target;
    const id = holder.dataset.id;
    e.preventDefault();
    runAction(target.dataset.action, target, id);
  }

  function onDblClick(e) {
    const card = e.target.closest && e.target.closest(".feed-card");
    if (!card || e.target.closest("button, input, textarea, a, .feed-plan")) return;
    e.preventDefault();
    jump(card.dataset.id);
  }

  function onListKeydown(e) {
    if (e.defaultPrevented || e.isComposing) return;
    const field = e.target.dataset && e.target.dataset.field;
    if (field) {
      // Ctrl+Enter sends from the text boxes.
      if (e.key === "Enter" && e.ctrlKey && !e.altKey) {
        const card = e.target.closest(".feed-card");
        const action = field === "feedback" ? "plan-feedback" : field === "reply" ? "stop-reply" : "submit-question";
        const b = card && card.querySelector(`[data-action="${action}"]`);
        if (b && !b.disabled) {
          e.preventDefault();
          runAction(action, b, card.dataset.id);
        }
      }
      return;
    }
    const card = e.target.classList && e.target.classList.contains("feed-card") ? e.target : null;
    if (!card || e.ctrlKey || e.altKey || e.metaKey) return;
    const ids = cardIds();
    const i = ids.indexOf(card.dataset.id);
    let next = null;
    if (e.key === "ArrowDown" || e.key === "j") next = ids[Math.min(ids.length - 1, i + 1)];
    else if (e.key === "ArrowUp" || e.key === "k") next = ids[Math.max(0, i - 1)];
    else if (e.key === "Home") next = ids[0];
    else if (e.key === "End") next = ids[ids.length - 1];
    else if (e.key === "Enter") {
      e.preventDefault();
      jump(card.dataset.id);
      return;
    } else return;
    e.preventDefault();
    if (next) focusCard(next);
  }

  function onTabKeydown(e) {
    const i = els.tabs.indexOf(e.target);
    if (i < 0) return;
    let j = -1;
    if (e.key === "ArrowRight") j = (i + 1) % els.tabs.length;
    else if (e.key === "ArrowLeft") j = (i - 1 + els.tabs.length) % els.tabs.length;
    else if (e.key === "Home") j = 0;
    else if (e.key === "End") j = els.tabs.length - 1;
    if (j < 0) return;
    e.preventDefault();
    setFilter(els.tabs[j].dataset.filter, true);
  }

  /**
   * Links in rendered plans never navigate the page: http(s) opens a wmux
   * browser tab, mailto: goes to the OS handler (render.js keeps only these).
   */
  function onLinkClick(e) {
    const a = e.target.closest && e.target.closest(".feed-plan a[href]");
    if (!a) return false;
    e.preventDefault();
    const href = a.getAttribute("href") || "";
    if (/^https?:\/\//i.test(href)) bridge.panel.openInBrowser(href).catch(() => {});
    else if (/^mailto:/i.test(href)) bridge.panel.openExternal(href).catch(() => {});
    return true;
  }

  /* ------------------------------------------------------------ lifecycle */

  function readContext(ctx) {
    const params = (ctx && ctx.params) || {};
    const saved = ctx && ctx.state;
    let filter = saved && typeof saved === "object" ? saved.filter : null;
    if (params.filter === "actionable" || params.filter === "activity") filter = params.filter;
    if (filter === "actionable" || filter === "activity") state.filter = filter;
    doc.documentElement.dataset.placement = params.placement === "tab" ? "tab" : "right_sidebar";
  }

  function runCommand(payload) {
    const action = payload && typeof payload.action === "string" ? payload.action : "";
    switch (action) {
      case "showActionable":
        return setFilter("actionable");
      case "showActivity":
        return setFilter("activity");
      case "refresh":
        return reload();
      case "focus": {
        const id = state.focusedId || cardIds()[0];
        return id ? focusCard(id) : undefined;
      }
      case "review":
        return payload.id && find(payload.id) ? review(payload.id) : undefined;
      default:
        return undefined;
    }
  }

  async function start() {
    applyStrings(doc);
    keys = (options.installKeys || installKeys)();
    keys.setKeymap(DEFAULT_KEYMAP);
    if (bridge.context && bridge.context.keymap !== undefined) keys.setKeymap(bridge.context.keymap);
    listen(doc.body, "click", (e) => {
      if (!onLinkClick(e)) onClick(e);
    });
    // A middle click on a link would otherwise ask the host for a new
    // window; route it like a click (as the markdown panel does).
    listen(doc.body, "auxclick", (e) => {
      if (e.button === 1) onLinkClick(e);
    });
    listen(els.list, "dblclick", onDblClick);
    listen(els.list, "input", onInput);
    listen(els.list, "keydown", onListKeydown);
    listen(els.list, "focusin", (e) => {
      const card = e.target.closest && e.target.closest(".feed-card");
      if (card) state.focusedId = card.dataset.id;
    });
    for (const tab of els.tabs) {
      listen(tab, "click", () => setFilter(tab.dataset.filter));
      listen(tab, "keydown", onTabKeydown);
    }
    listen(els.loadOlder, "click", () => loadOlder());
    listen(doc, "pointerdown", onPointerDown, true);
    listen(win, "pointerup", releasePress, true);
    listen(win, "pointercancel", releasePress, true);
    listen(win, "blur", releasePress);
    cleanups.push(bridge.on("cmux.event", onFrame));
    cleanups.push(bridge.on("panel.feed.item", upsert));
    cleanups.push(bridge.on("panel.feed.snapshot", (p) => applyPage(p)));
    cleanups.push(bridge.on("panel.feed.command", runCommand));
    cleanups.push(bridge.on("keymap", (km) => keys && keys.setKeymap(km)));
    state.timeTimer = win.setInterval(() => state.items.length && render(), TIME_REFRESH_MS);
    render();

    if (!bridge.available) {
      setStatus(t("feed.status.offline"));
      return api;
    }
    let ctx = null;
    try {
      ctx = await bridge.ready();
    } catch (err) {
      setStatus(t("feed.status.loadFailed", { message: errorMessage(err) }));
      return api;
    }
    if (state.destroyed) return api;
    // The latest panel.init wins (ready() keeps resolving with the first).
    ctx = bridge.context || ctx;
    readContext(ctx);
    if (ctx && ctx.keymap !== undefined) keys.setKeymap(ctx.keymap);
    cleanups.push(
      bridge.on("panel.init", (next) => {
        readContext(next);
        render();
      }),
    );
    bridge.panel.setTitle(t("feed.title")).catch(() => {});
    bridge.panel.subscribe(["feed"]).catch(() => {});
    if (ctx && ctx.params && ctx.params.payload) applyPage(ctx.params.payload);
    await reload();
    return api;
  }

  function destroy() {
    state.destroyed = true;
    for (const timer of [state.reloadTimer, state.stateTimer, state.statusTimer, state.pressTimer]) if (timer) win.clearTimeout(timer);
    if (state.timeTimer) win.clearInterval(state.timeTimer);
    while (cleanups.length) {
      try {
        cleanups.pop()();
      } catch {
        // keep tearing down
      }
    }
  }

  const api = {
    start,
    destroy,
    reload,
    render,
    loadOlder,
    setFilter,
    replyPermission,
    replyPlan,
    replyQuestion,
    replyStop,
    jump,
    review,
    focusCard,
    upsert,
    runCommand,
    get state() {
      return state;
    },
  };
  return api;
}
