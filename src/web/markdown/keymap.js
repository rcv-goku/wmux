/**
 * Keyboard actions of the markdown panel and their default bindings.
 *
 * Native sends the effective bindings in panel.init.keymap (user rebinding and
 * `when` clauses already applied) and that keymap replaces these defaults.
 * The defaults only apply when the host sends no keymap. Ids are the cmux
 * action ids from wmux_proto/actions_catalog.zig; Windows keys follow the
 * catalog (find also takes the scoped Ctrl+F binding).
 */

export const DEFAULT_KEYMAP = Object.freeze({
  markdownZoomIn: ["ctrl+="],
  markdownZoomOut: ["ctrl+-"],
  markdownZoomReset: ["ctrl+0"],
  find: ["ctrl+f", "ctrl+shift+f"],
  findNext: ["f3"],
  findPrevious: ["shift+f3"],
  hideFind: ["escape"],
  saveFilePreview: ["ctrl+s"],
  diffViewerScrollDown: ["j"],
  diffViewerScrollUp: ["k"],
  diffViewerScrollHalfPageDown: ["ctrl+d"],
  diffViewerScrollHalfPageUp: ["ctrl+u"],
  diffViewerScrollDownEmacs: ["ctrl+n"],
  diffViewerScrollUpEmacs: ["ctrl+p"],
  diffViewerScrollToBottom: ["shift+g"],
  diffViewerScrollToTop: ["g g"],
});

/** One "line" of j/k scrolling, in CSS px. */
export const LINE_SCROLL_PX = 40;

/**
 * Scroll target for a navigation action, or null for other actions.
 * @param {string} action
 * @param {{top: number, height: number, max: number}} view current scrollTop,
 *   viewport height and the largest scrollTop
 */
export function scrollTarget(action, view) {
  const half = Math.max(LINE_SCROLL_PX, Math.floor(view.height / 2));
  let top;
  switch (action) {
    case "diffViewerScrollDown":
    case "diffViewerScrollDownEmacs":
      top = view.top + LINE_SCROLL_PX;
      break;
    case "diffViewerScrollUp":
    case "diffViewerScrollUpEmacs":
      top = view.top - LINE_SCROLL_PX;
      break;
    case "diffViewerScrollHalfPageDown":
      top = view.top + half;
      break;
    case "diffViewerScrollHalfPageUp":
      top = view.top - half;
      break;
    case "diffViewerScrollToBottom":
      top = view.max;
      break;
    case "diffViewerScrollToTop":
      top = 0;
      break;
    default:
      return null;
  }
  return Math.min(Math.max(0, top), Math.max(0, view.max));
}

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
