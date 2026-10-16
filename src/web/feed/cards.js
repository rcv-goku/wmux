/**
 * Feed card DOM builders. Cards carry `data-action` buttons and `data-field`
 * inputs; app.js handles them by delegation and keeps per-card drafts in a
 * `ui` record so re-renders never lose typed text:
 *   {feedback, reviseOpen, reply, answers: [{selected: Set, other}], expanded, sending, error}
 * All item text is untrusted and set with textContent; only the plan text
 * goes through `renderMarkdown` (markdown-it + DOMPurify, see feed.js).
 */
import {
  availableModes,
  badgeFor,
  badgeLabel,
  canReply,
  isActionable,
  isDecision,
  isPending,
  relativeTime,
  sourceDisplayName,
  todoCounts,
} from "./model.js";

/** Fresh per-card UI state. */
export function newUiState() {
  return { feedback: "", reviseOpen: false, reply: "", answers: [], expanded: false, sending: false, error: "" };
}

/**
 * @param {{document: Document, t: Function, now: () => number, renderMarkdown?: (text: string) => Node|null}} deps
 */
export function createCards(deps) {
  const doc = deps.document;
  const t = deps.t;

  function el(tag, className, text) {
    const node = doc.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  }

  function button(label, action, extra = {}) {
    const b = el("button", extra.className || "", label);
    b.type = "button";
    b.dataset.action = action;
    for (const [k, v] of Object.entries(extra.data || {})) b.dataset[k] = v;
    if (extra.disabled) b.disabled = true;
    if (extra.title) b.title = extra.title;
    if (extra.ariaLabel) b.setAttribute("aria-label", extra.ariaLabel);
    if (extra.pressed !== undefined) b.setAttribute("aria-pressed", extra.pressed ? "true" : "false");
    return b;
  }

  function firstLine(text) {
    const line = (text || "").split(/\r?\n/).find((l) => l.trim() !== "");
    return line ? line.trim() : "";
  }

  function head(item) {
    const h = el("header", "feed-card-head");
    h.append(el("span", "feed-kind", t("feed.kind." + item.kind)));
    h.append(el("span", "feed-source", sourceDisplayName(item.source)));
    if (item.tool_name && item.kind !== "todos") h.append(el("code", "feed-tool", item.tool_name));
    if (item.kind === "toolResult" && item.is_error !== null) {
      const ok = !item.is_error;
      h.append(el("span", "feed-result " + (ok ? "feed-result-ok" : "feed-result-error"), t(ok ? "feed.toolResult.ok" : "feed.toolResult.error")));
    }
    const badge = badgeFor(item);
    if (badge && (!isDecision(item) || !isPending(item))) h.append(el("span", "feed-badge", badgeLabel(badge)));
    const time = el("time", "feed-time", relativeTime(item.created_at_ms, deps.now()));
    if (item.created_at_ms > 0) {
      time.dateTime = new Date(item.created_at_ms).toISOString();
      time.title = new Date(item.created_at_ms).toLocaleString();
    }
    h.append(time);
    if (item.surface_id || item.workspace_id) {
      h.append(button("↗", "jump", { className: "feed-icon-button", title: t("feed.jump"), ariaLabel: t("feed.jump") }));
    }
    return h;
  }

  /** Title and context lines shared by every kind. */
  function summary(item, card) {
    const source = sourceDisplayName(item.source);
    let title = item.title;
    let detail = item.detail;
    if (item.kind === "stop") title = t("feed.stop.title", { source });
    if (item.kind === "todos") title = t("feed.todos.title");
    if (item.kind === "prompt") {
      const text = item.text !== null ? item.text : item.detail || item.title;
      title = t("feed.context.you", { text: firstLine(text) || text });
      detail = "";
    }
    if (item.kind === "exitPlan" && !isPending(item)) {
      const planLine = firstLine(item.plan ? item.plan.text : "") || firstLine(item.detail);
      if (planLine) detail = t("feed.context.plan", { text: planLine });
    }
    if (title) card.append(el("div", "feed-card-title", title));
    if (detail && detail !== title) card.append(el("div", "feed-card-detail", detail));
  }

  function actions(children) {
    const row = el("div", "feed-actions");
    row.append(...children);
    return row;
  }

  function permissionBody(item, ui, card) {
    const modes = availableModes(item);
    if (modes.length === 0) return;
    card.append(
      actions(
        modes.map((m) =>
          button(t("feed.permission." + m), "permission", {
            className: m === "deny" ? "feed-deny" : m === "once" ? "wmux-primary" : "",
            data: { mode: m },
            disabled: ui.sending,
          }),
        ),
      ),
    );
  }

  function planBody(item, ui, card) {
    const plan = item.plan;
    const pending = isPending(item);
    if (plan && pending) {
      const box = el("div", "feed-plan");
      const rendered = plan.text && deps.renderMarkdown ? deps.renderMarkdown(plan.text) : null;
      if (rendered) {
        box.classList.add("feed-markdown");
        box.append(rendered);
      } else if (plan.text) {
        box.append(el("pre", "feed-plan-text", plan.text));
      }
      if (box.childNodes.length) card.append(box);
      if (plan.file_path) card.append(el("div", "feed-caption", t("feed.plan.file", { path: plan.file_path })));
      if (plan.allowed_prompts.length) {
        const wrap = el("div", "feed-allowed");
        wrap.append(el("div", "feed-caption", t("feed.plan.allowedPrompts")));
        const ul = el("ul", "feed-allowed-list");
        for (const p of plan.allowed_prompts) ul.append(el("li", "", p));
        wrap.append(ul);
        card.append(wrap);
      }
    }
    const modes = availableModes(item);
    if (modes.length === 0) {
      const r = item.resolution;
      if (r && r.feedback) card.append(el("blockquote", "feed-sent", r.feedback));
      return;
    }
    const buttons = modes.map((m) =>
      button(t("feed.plan." + m), "plan", {
        className: m === "deny" ? "feed-deny" : m === "manual" ? "wmux-primary" : "",
        data: { mode: m },
        disabled: ui.sending,
      }),
    );
    if (modes.includes("deny")) {
      buttons.push(button(t("feed.plan.revise"), "revise", { pressed: ui.reviseOpen, disabled: ui.sending }));
    }
    card.append(actions(buttons));
    if (ui.reviseOpen) {
      const box = el("div", "feed-compose");
      const area = el("textarea", "feed-input");
      area.dataset.field = "feedback";
      area.rows = 3;
      area.value = ui.feedback;
      area.placeholder = t("feed.plan.feedbackPlaceholder");
      area.setAttribute("aria-label", t("feed.plan.feedbackLabel"));
      box.append(area);
      box.append(button(t("feed.plan.sendFeedback"), "plan-feedback", { className: "wmux-primary", disabled: ui.sending || ui.feedback.trim() === "" }));
      card.append(box);
    }
  }

  function answerOf(ui, qi) {
    if (!ui.answers[qi]) ui.answers[qi] = { selected: new Set(), other: "" };
    return ui.answers[qi];
  }

  /** Every question has a chosen option or text. */
  function questionsAnswered(item, ui) {
    if (item.questions.length === 0) return (answerOf(ui, 0).other || "").trim() !== "";
    return item.questions.every((q, qi) => {
      const a = answerOf(ui, qi);
      return a.selected.size > 0 || a.other.trim() !== "";
    });
  }

  function questionBody(item, ui, card) {
    const pending = isPending(item);
    if (!pending) {
      const r = item.resolution;
      if (r && r.selections && r.selections.length) {
        const ul = el("ul", "feed-answers");
        for (const s of r.selections) ul.append(el("li", "", s));
        card.append(ul);
      }
      return;
    }
    const questions = item.questions.length ? item.questions : [{ question: "", header: "", multi_select: false, options: [] }];
    if (!canReply(item)) {
      for (const q of item.questions) if (q.question) card.append(el("div", "feed-question-text", q.question));
      return;
    }
    questions.forEach((q, qi) => {
      const a = answerOf(ui, qi);
      const set = el("fieldset", "feed-question");
      const legend = el("legend", "feed-question-text");
      if (q.header) legend.append(el("span", "feed-question-header", q.header));
      if (q.question) legend.append(el("span", "", q.question));
      if (legend.childNodes.length) set.append(legend);
      if (q.multi_select) set.append(el("div", "feed-caption", t("feed.question.multiSelect")));
      if (q.options.length === 0) set.append(el("div", "feed-caption", t("feed.question.noOptions")));
      const opts = el("div", "feed-options");
      for (const o of q.options) {
        const b = button(o.label, "option", {
          className: "feed-option",
          data: { q: String(qi), label: o.label },
          pressed: a.selected.has(o.label),
          disabled: ui.sending,
          title: o.description || undefined,
        });
        if (o.description) b.append(el("span", "feed-option-desc", o.description));
        opts.append(b);
      }
      if (q.options.length) set.append(opts);
      const other = el("input", "feed-input");
      other.type = "text";
      other.dataset.field = "other";
      other.dataset.q = String(qi);
      other.value = a.other;
      other.placeholder = t("feed.question.otherPlaceholder");
      other.setAttribute("aria-label", t("feed.question.other"));
      other.disabled = ui.sending;
      set.append(other);
      card.append(set);
    });
    const label = questions.length > 1 ? t("feed.question.submitAll") : t("feed.question.submit");
    card.append(actions([button(label, "submit-question", { className: "wmux-primary", disabled: ui.sending || !questionsAnswered(item, ui) })]));
  }

  function stopBody(item, ui, card) {
    const source = sourceDisplayName(item.source);
    if (item.resolution && item.resolution.text) {
      card.append(el("blockquote", "feed-sent", item.resolution.text));
      return;
    }
    if (!isActionable(item)) return;
    const box = el("div", "feed-compose");
    const area = el("textarea", "feed-input");
    area.dataset.field = "reply";
    area.rows = 2;
    area.value = ui.reply;
    area.placeholder = t("feed.stop.placeholder", { source });
    area.setAttribute("aria-label", t("feed.stop.placeholder", { source }));
    area.disabled = ui.sending;
    box.append(area);
    box.append(button(t("feed.stop.send", { source }), "stop-reply", { className: "wmux-primary", disabled: ui.sending || ui.reply.trim() === "" }));
    card.append(box);
  }

  function todoSummaryText(todos) {
    const c = todoCounts(todos);
    const parts = [];
    if (c.open) parts.push(t("feed.todos.open", { count: c.open }));
    if (c.in_progress) parts.push(t("feed.todos.inProgress", { count: c.in_progress }));
    if (c.done) parts.push(t("feed.todos.done", { count: c.done }));
    return parts.length ? parts.join(", ") : t("feed.todos.open", { count: 0 });
  }

  function todosBody(item, ui, card) {
    const line = el("div", "feed-todo-summary");
    line.append(el("span", "", todoSummaryText(item.todos)));
    if (item.todos.length) {
      const toggle = button(t(ui.expanded ? "feed.todos.collapse" : "feed.todos.show"), "toggle-todos", { className: "wmux-link" });
      toggle.setAttribute("aria-expanded", ui.expanded ? "true" : "false");
      line.append(toggle);
    }
    card.append(line);
    if (!ui.expanded) return;
    const ul = el("ul", "feed-todos");
    for (const todo of item.todos) {
      const li = el("li", "feed-todo feed-todo-" + todo.status);
      const mark = el("span", "feed-todo-mark", todo.status === "completed" ? "✓" : todo.status === "in_progress" ? "◐" : "○");
      mark.setAttribute("aria-hidden", "true");
      li.append(mark);
      const text = todo.status === "in_progress" && todo.active_form ? todo.active_form : todo.content;
      li.append(el("span", "feed-todo-text", text));
      li.append(el("span", "wmux-visually-hidden", ", " + t("feed.todos.status." + todo.status)));
      ul.append(li);
    }
    card.append(ul);
  }

  /** Accessible label of a card: kind, source, title. */
  function cardLabel(item, card) {
    const title = card.querySelector(".feed-card-title");
    const parts = [t("feed.kind." + item.kind), sourceDisplayName(item.source)];
    if (title) parts.push(title.textContent);
    const badge = card.querySelector(".feed-badge");
    if (badge) parts.push(badge.textContent);
    return parts.join(", ");
  }

  /**
   * One card.
   * @param {object} item normalized item
   * @param {object} ui per-card UI state (newUiState())
   */
  function buildCard(item, ui) {
    const card = el("article", "feed-card");
    card.dataset.id = item.id;
    card.dataset.kind = item.kind;
    card.dataset.status = item.status;
    card.setAttribute("role", "listitem");
    card.tabIndex = -1;
    if (isActionable(item)) card.classList.add("feed-actionable");
    card.append(head(item));
    summary(item, card);
    switch (item.kind) {
      case "permissionRequest":
        permissionBody(item, ui, card);
        break;
      case "exitPlan":
        planBody(item, ui, card);
        break;
      case "question":
        questionBody(item, ui, card);
        break;
      case "stop":
        stopBody(item, ui, card);
        break;
      case "todos":
        todosBody(item, ui, card);
        break;
      default:
        break;
    }
    if (ui.sending) card.append(el("div", "feed-caption", t("feed.sending")));
    if (ui.error) {
      const err = el("div", "feed-card-error", ui.error);
      err.setAttribute("role", "alert");
      card.append(err);
    }
    card.setAttribute("aria-label", cardLabel(item, card));
    return card;
  }

  return { buildCard, questionsAnswered, answerOf };
}
