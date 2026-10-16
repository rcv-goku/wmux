/**
 * Diff DOM rendering: file sections (header, notes, collapsible body) and the
 * unified / split line tables with syntax and word highlights. Every piece of
 * patch text is inserted with textContent or as DOMPurify-sanitized
 * highlight.js spans (highlight.js).
 *
 *   const r = createRenderer({ document, hljs, purify });
 *   const section = r.fileShell(file, info);
 *   const body = r.body(file, hunks, opts);   // {el, rowFor, gapFor, expandGap}
 */
import { segmentContext, STATUS_LETTERS } from "./files.js";
import { highlightLines, languageFor, wrapRanges } from "./highlight.js";
import { t } from "./strings.js";
import { hunkWordRanges } from "./words.js";

export const SIDE_ADD = "additions";
export const SIDE_DEL = "deletions";

function el(doc, tag, className, text) {
  const node = doc.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = text;
  return node;
}

/** Display path of a file header: "old → new" for renames and copies. */
export function displayPath(file) {
  if ((file.status === "renamed" || file.status === "copied") && file.oldPath !== file.newPath) {
    return file.oldPath + " → " + file.newPath;
  }
  return file.path;
}

/** Per-hunk syntax fragments: {old: Map(lineIndex -> frag), new: Map}. */
function hunkSyntax(env, language, lines) {
  const out = { old: new Map(), new: new Map() };
  if (!language) return out;
  const oldIdx = [];
  const newIdx = [];
  lines.forEach((l, i) => {
    if (l.type !== "add") oldIdx.push(i);
    if (l.type !== "del") newIdx.push(i);
  });
  const oldFrags = highlightLines(env, language, oldIdx.map((i) => lines[i].text));
  const newFrags = highlightLines(env, language, newIdx.map((i) => lines[i].text));
  if (oldFrags) oldIdx.forEach((i, k) => out.old.set(i, oldFrags[k]));
  if (newFrags) newIdx.forEach((i, k) => out.new.set(i, newFrags[k]));
  return out;
}

/**
 * @param {{document: Document, hljs?: object|null, purify?: object|null}} env
 */
export function createRenderer(env) {
  const doc = env.document;
  const hl = { hljs: env.hljs || null, purify: env.purify || null, document: doc };

  /* ---------------------------------------------------------------------- */
  /* file shell                                                             */
  /* ---------------------------------------------------------------------- */

  /**
   * @param {object} file
   * @param {{deferred: string|null, collapsed: boolean, viewed: boolean,
   *   changedSinceViewed: boolean}} info
   */
  function fileShell(file, info) {
    const section = el(doc, "section", "dv-file");
    section.id = "dv-file-" + file.index;
    section.dataset.file = String(file.index);
    section.dataset.status = file.status;

    const header = el(doc, "header", "dv-file-header");
    const toggle = el(doc, "button", "dv-collapse dv-icon-button");
    toggle.type = "button";
    toggle.dataset.action = "toggle-file";
    const badge = el(doc, "span", "dv-badge dv-badge-" + file.status, STATUS_LETTERS[file.status] || "M");
    badge.title = t("diff.status." + file.status);
    const pathEl = el(doc, "span", "dv-path", displayPath(file));
    pathEl.title = file.path;
    const stats = el(doc, "span", "dv-file-stats");
    if (file.additions) stats.append(el(doc, "span", "dv-plus", t("diff.additionsCount", { count: file.additions })));
    if (file.deletions) stats.append(el(doc, "span", "dv-minus", t("diff.deletionsCount", { count: file.deletions })));
    const changed = el(doc, "span", "dv-changed-since", t("diff.changedSinceViewed"));
    const viewed = el(doc, "label", "dv-viewed");
    const box = el(doc, "input", "dv-viewed-box");
    box.type = "checkbox";
    box.dataset.action = "toggle-viewed";
    viewed.append(box, el(doc, "span", "", t("diff.viewed")));
    header.append(toggle, badge, pathEl, stats, changed, viewed);

    const notes = el(doc, "div", "dv-file-notes");
    if (file.combined) notes.append(el(doc, "span", "dv-note", t("diff.combined", { parents: file.parents })));
    if (file.status === "renamed" && file.similarity !== null && file.similarity !== undefined) {
      notes.append(el(doc, "span", "dv-note", t("diff.similarity", { percent: file.similarity })));
    }
    if (file.oldMode && file.newMode && file.oldMode !== file.newMode) {
      notes.append(el(doc, "span", "dv-note dv-note-mode", t("diff.mode", { old: file.oldMode, new: file.newMode })));
    }
    if (file.binary) notes.append(el(doc, "span", "dv-note dv-note-binary", t("diff.binary")));
    else if (file.hunks.length === 0 && !(file.oldMode && file.newMode && file.oldMode !== file.newMode)) {
      if (file.status === "modified" || file.status === "renamed" || file.status === "copied") {
        notes.append(el(doc, "span", "dv-note", t("diff.noChanges")));
      }
    }
    const deferred = el(doc, "div", "dv-deferred");
    const deferLabel = el(doc, "span", "dv-deferred-label");
    const load = el(doc, "button", "dv-load", t("diff.loadDiff"));
    load.type = "button";
    load.dataset.action = "load-diff";
    deferred.append(deferLabel, load);

    const body = el(doc, "div", "dv-file-body");
    section.append(header, notes, deferred, body);
    updateShell(section, info);
    return section;
  }

  /** Reflect collapsed / viewed / deferred state in a file section. */
  function updateShell(section, info) {
    const toggle = section.querySelector(".dv-collapse");
    const expanded = !info.collapsed && !info.deferred;
    section.classList.toggle("dv-collapsed", !expanded);
    section.classList.toggle("dv-is-viewed", !!info.viewed);
    section.classList.toggle("dv-is-changed", !!info.changedSinceViewed);
    toggle.setAttribute("aria-expanded", String(expanded));
    const label = expanded ? t("diff.collapseFile") : t("diff.expandFile");
    toggle.setAttribute("aria-label", label);
    toggle.title = label;
    toggle.textContent = expanded ? "▾" : "▸";
    const box = section.querySelector(".dv-viewed-box");
    box.checked = !!info.viewed;
    box.title = info.viewed ? t("diff.markNotViewed") : t("diff.markViewed");
    box.setAttribute("aria-label", box.title);
    section.querySelector(".dv-changed-since").hidden = !info.changedSinceViewed;
    const deferred = section.querySelector(".dv-deferred");
    deferred.hidden = !info.deferred;
    deferred.querySelector(".dv-deferred-label").textContent = info.deferred === "large" ? t("diff.large") : t("diff.generated");
    section.querySelector(".dv-file-body").hidden = !expanded;
  }

  /* ---------------------------------------------------------------------- */
  /* body                                                                   */
  /* ---------------------------------------------------------------------- */

  function numCell(no, which) {
    const td = el(doc, "td", "dv-num dv-num-" + which);
    if (no !== null && no !== undefined) {
      td.dataset.line = String(no);
      td.textContent = String(no);
    }
    return td;
  }

  function codeCell(line, h, i, side, frag, ranges) {
    const td = el(doc, "td", "dv-code dv-" + line.type);
    td.dataset.h = String(h);
    td.dataset.l = String(i);
    td.dataset.side = side;
    const no = side === SIDE_DEL ? line.oldNo : line.newNo;
    if (no !== null && no !== undefined) td.dataset.line = String(no);
    const add = el(doc, "button", "dv-add-comment", "+");
    add.type = "button";
    add.dataset.action = "add-comment";
    add.tabIndex = -1;
    add.setAttribute("aria-label", t("diff.addComment"));
    add.title = t("diff.addComment");
    const sign = el(doc, "span", "dv-sign", line.type === "add" ? "+" : line.type === "del" ? "-" : " ");
    sign.setAttribute("aria-hidden", "true");
    const text = el(doc, "span", "dv-text");
    if (frag && frag.textContent === line.text) text.append(frag.cloneNode(true));
    else text.textContent = line.text;
    if (ranges && ranges.length) wrapRanges(text, ranges, "dv-word");
    td.append(add, sign);
    // The sign is decoration (not rendered in the bars and none styles), so
    // without this label the change type reaches assistive technology only
    // as a color.
    if (line.type === "add" || line.type === "del") {
      const label = t(line.type === "add" ? "diff.lineAdded" : "diff.lineDeleted") + " ";
      td.append(el(doc, "span", "wmux-visually-hidden dv-change-label", label));
    }
    td.append(text);
    if (line.noNewline) {
      const mark = el(doc, "span", "dv-nonl", "⊘");
      mark.title = t("diff.noNewline");
      td.append(mark);
    }
    return td;
  }

  function emptyCells() {
    return [el(doc, "td", "dv-num dv-empty"), el(doc, "td", "dv-code dv-empty")];
  }

  /**
   * @param {object} file
   * @param {object[][]} hunks display lines per hunk (after whitespace folding)
   * @param {{layout: "unified"|"split", wordDiffs: boolean, context: number,
   *   pinned?: (hunkIndex: number) => Set<number>|null}} opts
   */
  function body(file, hunks, opts) {
    const layout = file.combined ? "unified" : opts.layout;
    const cols = layout === "split" ? 4 : 3;
    const language = languageFor(file.path, hl.hljs);
    const table = el(doc, "table", "dv-table dv-" + layout);
    const tbody = el(doc, "tbody");
    table.append(tbody);
    const rows = new Map();
    const gapOf = new Map();
    const gaps = new Map();
    const perHunk = [];

    const register = (tr, line) => {
      if (line.type !== "add" && line.oldNo !== null) rows.set(SIDE_DEL + ":" + line.oldNo, tr);
      if (line.type !== "del" && line.newNo !== null) rows.set(SIDE_ADD + ":" + line.newNo, tr);
    };

    function lineRows(h, items) {
      const { lines, syntax, words, index } = perHunk[h];
      const out = [];
      if (layout === "unified") {
        for (const line of items) {
          const i = index.get(line);
          const tr = el(doc, "tr", "dv-line dv-" + line.type);
          const side = line.type === "del" ? SIDE_DEL : SIDE_ADD;
          const frag = line.type === "del" ? syntax.old.get(i) : syntax.new.get(i);
          tr.append(numCell(line.oldNo, "old"), numCell(line.newNo, "new"), codeCell(line, h, i, side, frag, words.get(i)));
          register(tr, line);
          out.push(tr);
        }
        return out;
      }
      let k = 0;
      while (k < items.length) {
        if (items[k].type === "context") {
          const line = items[k++];
          const i = index.get(line);
          const tr = el(doc, "tr", "dv-line dv-context");
          tr.append(
            numCell(line.oldNo, "old"),
            codeCell(line, h, i, SIDE_DEL, syntax.old.get(i), null),
            numCell(line.newNo, "new"),
            codeCell(line, h, i, SIDE_ADD, syntax.new.get(i), null),
          );
          register(tr, line);
          out.push(tr);
          continue;
        }
        const dels = [];
        const adds = [];
        while (k < items.length && items[k].type === "del") dels.push(items[k++]);
        while (k < items.length && items[k].type === "add") adds.push(items[k++]);
        for (let r = 0; r < Math.max(dels.length, adds.length); r += 1) {
          const tr = el(doc, "tr", "dv-line dv-change");
          const d = dels[r];
          const a = adds[r];
          if (d) {
            const i = index.get(d);
            tr.append(numCell(d.oldNo, "old"), codeCell(d, h, i, SIDE_DEL, syntax.old.get(i), words.get(i)));
            register(tr, d);
          } else tr.append(...emptyCells());
          if (a) {
            const i = index.get(a);
            tr.append(numCell(a.newNo, "new"), codeCell(a, h, i, SIDE_ADD, syntax.new.get(i), words.get(i)));
            register(tr, a);
          } else tr.append(...emptyCells());
          out.push(tr);
        }
      }
      return out;
    }

    function gapRow(h, items) {
      const tr = el(doc, "tr", "dv-gap");
      const td = el(doc, "td", "dv-gap-cell");
      td.colSpan = cols;
      const button = el(doc, "button", "dv-gap-button");
      button.type = "button";
      button.dataset.action = "expand-gap";
      button.textContent = items.length === 1 ? t("diff.hiddenLine") : t("diff.hiddenLines", { count: items.length });
      td.append(button);
      tr.append(td);
      gaps.set(tr, { h, items });
      for (const line of items) gapOf.set(h + ":" + perHunk[h].index.get(line), tr);
      return tr;
    }

    function expandGap(tr) {
      const gap = gaps.get(tr);
      if (!gap || !tr.parentNode) return false;
      gaps.delete(tr);
      for (const line of gap.items) gapOf.delete(gap.h + ":" + perHunk[gap.h].index.get(line));
      tr.replaceWith(...lineRows(gap.h, gap.items));
      return true;
    }

    hunks.forEach((lines, h) => {
      const index = new Map(lines.map((l, i) => [l, i]));
      perHunk.push({
        lines,
        index,
        syntax: hunkSyntax(hl, language, lines),
        words: opts.wordDiffs ? hunkWordRanges(lines) : new Map(),
      });
      const head = el(doc, "tr", "dv-hunk");
      head.dataset.h = String(h);
      const td = el(doc, "td", "dv-hunk-cell", file.hunks[h] ? file.hunks[h].header : "");
      td.colSpan = cols;
      head.append(td);
      tbody.append(head);
      const pinned = opts.pinned ? opts.pinned(h) : null;
      for (const seg of segmentContext(lines, opts.context, pinned)) {
        if (seg.kind === "gap") tbody.append(gapRow(h, seg.lines));
        else tbody.append(...lineRows(h, seg.lines));
      }
    });

    return {
      el: table,
      layout,
      cols,
      rowFor: (side, line) => rows.get(side + ":" + line) || null,
      gapFor: (h, i) => gapOf.get(h + ":" + i) || null,
      expandGap,
      expandAllGaps() {
        for (const tr of Array.from(gaps.keys())) expandGap(tr);
      },
    };
  }

  /** Table row that holds comment UI under a line (whole width, or one split side). */
  function commentRow(bodyInfo, side, content) {
    const tr = el(doc, "tr", "dv-comment-row");
    tr.dataset.side = side;
    if (bodyInfo.layout === "split") {
      const filled = el(doc, "td", "dv-comment-cell");
      filled.colSpan = 2;
      filled.append(content);
      const blank = el(doc, "td", "dv-comment-cell dv-empty");
      blank.colSpan = 2;
      if (side === SIDE_DEL) tr.append(filled, blank);
      else tr.append(blank, filled);
    } else {
      const td = el(doc, "td", "dv-comment-cell");
      td.colSpan = bodyInfo.cols;
      td.append(content);
      tr.append(td);
    }
    return tr;
  }

  return { fileShell, updateShell, body, commentRow };
}
