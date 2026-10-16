/**
 * Keyboard actions of the diff panel and their default bindings
 * (ARCHITECTURE Appendix A.5; cmux action ids).
 *
 * Native sends the effective bindings in panel.init.keymap (user rebinding,
 * e.g. diffViewerNextHunk -> "m", already applied) and that keymap replaces
 * these defaults. The defaults only apply when the host sends no keymap.
 * keys.js ignores bare keys while a text field (comment composer, filters,
 * find) has focus.
 */

export const DEFAULT_KEYMAP = Object.freeze({
  diffViewerScrollDown: ["j"],
  diffViewerScrollUp: ["k"],
  diffViewerScrollHalfPageDown: ["ctrl+d"],
  diffViewerScrollHalfPageUp: ["ctrl+u"],
  diffViewerScrollDownEmacs: ["ctrl+n"],
  diffViewerScrollUpEmacs: ["ctrl+p"],
  diffViewerScrollToBottom: ["shift+g"],
  diffViewerScrollToTop: ["g g"],
  diffViewerOpenFileSearch: ["/"],
  diffViewerNextFile: ["] f"],
  diffViewerPreviousFile: ["[ f"],
  diffViewerNextHunk: ["n"],
  diffViewerPreviousHunk: ["p"],
  diffViewerToggleViewed: ["v"],
  find: ["ctrl+f", "ctrl+shift+f"],
  findNext: ["f3"],
  findPrevious: ["shift+f3"],
  hideFind: ["escape"],
});

/** One "line" of j/k scrolling, in CSS px. */
export const LINE_SCROLL_PX = 40;

export const SCROLL_ACTIONS = Object.freeze([
  "diffViewerScrollDown",
  "diffViewerScrollUp",
  "diffViewerScrollHalfPageDown",
  "diffViewerScrollHalfPageUp",
  "diffViewerScrollDownEmacs",
  "diffViewerScrollUpEmacs",
  "diffViewerScrollToBottom",
  "diffViewerScrollToTop",
]);

/**
 * Scroll target for a scroll action, or null for other actions.
 * @param {string} action
 * @param {{top: number, height: number, max: number}} view
 */
export function scrollTarget(action, view) {
  const half = Math.max(LINE_SCROLL_PX, Math.floor(view.height / 2));
  const deltas = {
    diffViewerScrollDown: LINE_SCROLL_PX,
    diffViewerScrollDownEmacs: LINE_SCROLL_PX,
    diffViewerScrollUp: -LINE_SCROLL_PX,
    diffViewerScrollUpEmacs: -LINE_SCROLL_PX,
    diffViewerScrollHalfPageDown: half,
    diffViewerScrollHalfPageUp: -half,
  };
  let top;
  if (action === "diffViewerScrollToBottom") top = view.max;
  else if (action === "diffViewerScrollToTop") top = 0;
  else if (deltas[action] !== undefined) top = view.top + deltas[action];
  else return null;
  return Math.min(Math.max(0, top), Math.max(0, view.max));
}

/**
 * Index of the next/previous target given sorted offsets (document positions
 * of file headers or hunks) and the current scroll position. A target within
 * `slack` px below the top counts as the current one.
 * @returns {number} index, or -1 when there is none in that direction
 */
export function stepTarget(offsets, top, dir, slack = 4) {
  if (dir > 0) {
    for (let i = 0; i < offsets.length; i += 1) if (offsets[i] > top + slack) return i;
    return -1;
  }
  for (let i = offsets.length - 1; i >= 0; i -= 1) if (offsets[i] < top - slack) return i;
  return -1;
}
