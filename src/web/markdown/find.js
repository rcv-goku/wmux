/**
 * In-page find for the markdown preview: case-insensitive substring search
 * over the visible text nodes of a root element, <mark> highlights, the
 * current match marked separately, wrap-around at both ends, and a
 * current/total counter. A match never spans two text nodes (like the browser
 * find script it mirrors).
 *
 *   const find = createFind(contentElement, { onChange: ({current, total}) => {} });
 *   find.search("install");   // highlights, selects the first match
 *   find.next(); find.previous();
 *   find.refresh();           // re-apply the needle after the content was re-rendered
 *   find.clear();             // remove highlights, forget the needle
 */

/** Highlight at most this many matches. */
export const MAX_MATCHES = 10000;

/** Needles are cut to this many characters. */
export const MAX_NEEDLE_LENGTH = 1000;

const SKIP_TAGS = new Set([
  "SCRIPT",
  "STYLE",
  "NOSCRIPT",
  "TEXTAREA",
  "INPUT",
  "SELECT",
  "BUTTON",
  "TEMPLATE",
  "svg",
  "SVG",
]);
const SKIP_SELECTOR = "[hidden], .wmux-source, .mdv-find-skip, details:not([open]) > :not(summary)";

export const MATCH_CLASS = "mdv-find-match";
export const CURRENT_CLASS = "mdv-find-current";

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Text nodes under root that a reader can see. */
export function visibleTextNodes(root) {
  const doc = root.ownerDocument;
  const view = doc.defaultView;
  const filter = view && view.NodeFilter ? view.NodeFilter : globalThis.NodeFilter;
  const out = [];
  const walker = doc.createTreeWalker(root, filter.SHOW_TEXT, {
    acceptNode(node) {
      if (!node.nodeValue) return filter.FILTER_REJECT;
      const parent = node.parentElement;
      if (!parent) return filter.FILTER_REJECT;
      for (let el = parent; el && el !== root; el = el.parentElement) {
        if (SKIP_TAGS.has(el.tagName)) return filter.FILTER_REJECT;
      }
      const skip = parent.closest(SKIP_SELECTOR);
      if (skip && skip !== root && root.contains(skip)) return filter.FILTER_REJECT;
      return filter.FILTER_ACCEPT;
    },
  });
  for (let node = walker.nextNode(); node; node = walker.nextNode()) out.push(node);
  return out;
}

/**
 * @param {HTMLElement} root
 * @param {{onChange?: (state: {needle: string, current: number, total: number}) => void,
 *          scroll?: (el: HTMLElement) => void, maxMatches?: number}} [options]
 */
export function createFind(root, options) {
  const opts = options || {};
  const maxMatches = opts.maxMatches > 0 ? Math.min(opts.maxMatches, MAX_MATCHES) : MAX_MATCHES;
  let needle = "";
  let marks = [];
  let index = -1;

  function notify() {
    if (opts.onChange) opts.onChange(state());
  }

  function state() {
    return { needle, current: marks.length ? index + 1 : 0, total: marks.length };
  }

  function unhighlight() {
    const parents = new Set();
    for (const mark of root.querySelectorAll("mark." + MATCH_CLASS)) {
      const parent = mark.parentNode;
      if (!parent) continue;
      while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
      parent.removeChild(mark);
      parents.add(parent);
    }
    for (const parent of parents) parent.normalize();
    marks = [];
    index = -1;
  }

  function highlight() {
    if (needle === "") return;
    const doc = root.ownerDocument;
    const re = new RegExp(escapeRegExp(needle), "giu");
    for (const node of visibleTextNodes(root)) {
      if (marks.length >= maxMatches) break;
      const text = node.nodeValue;
      const ranges = [];
      re.lastIndex = 0;
      for (let m = re.exec(text); m; m = re.exec(text)) {
        if (m[0].length === 0) {
          re.lastIndex += 1;
          continue;
        }
        ranges.push([m.index, m.index + m[0].length]);
        if (marks.length + ranges.length >= maxMatches) break;
      }
      if (!ranges.length) continue;
      // Rebuild the node as one fragment (linear, unlike repeated splitText).
      const fragment = doc.createDocumentFragment();
      let offset = 0;
      for (const [start, end] of ranges) {
        if (start > offset) fragment.append(doc.createTextNode(text.slice(offset, start)));
        const mark = doc.createElement("mark");
        mark.className = MATCH_CLASS;
        mark.textContent = text.slice(start, end);
        fragment.append(mark);
        marks.push(mark);
        offset = end;
      }
      if (offset < text.length) fragment.append(doc.createTextNode(text.slice(offset)));
      node.replaceWith(fragment);
    }
  }

  function select(i, scroll) {
    if (index >= 0 && marks[index]) marks[index].classList.remove(CURRENT_CLASS);
    if (!marks.length) {
      index = -1;
      return;
    }
    index = ((i % marks.length) + marks.length) % marks.length;
    const mark = marks[index];
    mark.classList.add(CURRENT_CLASS);
    if (scroll !== false) {
      if (opts.scroll) opts.scroll(mark);
      else if (typeof mark.scrollIntoView === "function") {
        mark.scrollIntoView({ block: "center", inline: "nearest", behavior: "smooth" });
      }
    }
  }

  /** Search for `text` (replaces the previous needle). */
  function search(text) {
    unhighlight();
    needle = typeof text === "string" ? text.slice(0, MAX_NEEDLE_LENGTH) : "";
    highlight();
    select(0);
    notify();
    return state();
  }

  function next() {
    if (marks.length) select(index + 1);
    notify();
    return state();
  }

  function previous() {
    if (marks.length) select(index - 1);
    notify();
    return state();
  }

  /** Re-apply the needle (after a re-render), keeping the current index when possible. */
  function refresh() {
    const keep = index;
    unhighlight();
    highlight();
    if (marks.length) select(Math.min(Math.max(keep, 0), marks.length - 1), false);
    notify();
    return state();
  }

  function clear() {
    unhighlight();
    needle = "";
    notify();
    return state();
  }

  return {
    search,
    next,
    previous,
    refresh,
    clear,
    state,
    get needle() {
      return needle;
    },
  };
}
