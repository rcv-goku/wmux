# `src/web/feed`: agent Feed panel

PanelKind `feed` (ARCHITECTURE ADR-6.11; right-sidebar mode "Feed",
`switchRightSidebarToFeed`, ADR-11), entry
`https://feed.wmux.example/feed/index.html`. Shows agent decision requests and
activity, latest first, with the **Actionable** and **All Activity** tabs:
permission, plan and question cards with their decision buttons, stop cards
with a reply box, todo snapshots, activity rows, a Resolved divider with mode
badges, "Load older activity", workstream chips, jump to the agent's surface,
in-panel banners for new pending decisions, and live updates.

Covers: `notifications-feed-panel`, `notifications-feed-permission-decisions`,
`notifications-feed-exit-plan`, `notifications-feed-ask-user-question`,
`notifications-feed-stop-reply`, `notifications-feed-todos`,
`notifications-feed-jump`, `notifications-feed-actionable-banners` (page
side; the store, the waiting hooks, the "Needs input" overlay and the native
toasts are native).

| File | Purpose |
|---|---|
| `index.html` | page shell: tabs, banners, workstream chips, list, Load older, empty state |
| `feed.js` | entry module: loads markdown-it and DOMPurify, theme sync, app start |
| `app.js` | the application: bridge, loading, paging, live updates, banners, decisions, keys |
| `cards.js` | card DOM per kind (decision buttons, plan, questions, stop reply, todos) |
| `model.js` | pure helpers: item normalization, partition, badges, modes, banners, workstreams, selections |
| `render.js` | plan markdown -> sanitized fragment (markdown-it, raw HTML off, then DOMPurify) |
| `strings.js` | user-visible strings (`tr()` keys) |
| `feed.css` | layout and cards on the `--wmux-*` tokens |

Libraries (from `../_vendor/`, already vendored for the markdown panel):
markdown-it 15.0.2 and DOMPurify 3.4.17, for plan text only.

## Native contract

Names follow ADR-6.5: cmux method names where cmux has them (Appendix B,
`feed.*`). Methods and events that cmux does not name live under the panel's
own namespace, `panel.feed.*` (handled by the kind's `on_message`, like
`panel.markdown.*`), and are documented here. The kind's allowlist therefore
needs only `feed.list`, `feed.jump`, `feed.permission.reply`,
`feed.exit_plan.reply` and `feed.question.reply` (`panel.*` is implicit),
with the event category `feed`.

### `panel.init`

| Key | Used for |
|---|---|
| `params.filter` | `"actionable"` (default) or `"activity"`: the initial tab (overrides `state`) |
| `params.placement` | `"right_sidebar"` (default) or `"tab"`; sets `html[data-placement]` |
| `params.payload` | optional initial `feed.list` result, rendered before the first call returns |
| `state` | `{v: 1, filter}` restores the tab |

A later `panel.init` is applied in place. The page sets the title with
`panel.set_title {title: "Feed"}` and subscribes with `panel.subscribe
{categories: ["feed"]}`.

### Methods called by the page

| Method | Params -> result | When |
|---|---|---|
| `feed.list` | `{limit: 200}` -> `{items, has_more}` | start, and after every `feed.*` event (debounced 40 ms; only the newest reply applies) |
| `feed.list` | `{before: <oldest id>, limit: 200}` -> `{items, has_more}` | "Load older activity" (pages stay loaded across reloads) |
| `feed.permission.reply` | `{request_id, mode: once\|always\|all\|bypass\|deny}` -> `{delivered}` | permission buttons |
| `feed.exit_plan.reply` | `{request_id, mode: ultraplan\|bypassPermissions\|autoAccept\|manual\|deny, feedback?}` | plan buttons; "Send feedback" sends `mode: "deny"` with the trimmed `feedback` (badge "refined") |
| `feed.question.reply` | `{request_id, selections: [string], answers?: [[string]]}` | option click (one single-choice question) or Submit / Submit All Answers. `answers` (wmux extension, only with several questions) keeps the per-question split that the flat `selections` loses |
| `panel.feed.stop_reply` | `{id, text, request_id?, session_id?, workspace_id?, surface_id?, source?}` -> `{delivered?}` | "Send to <Agent>" on a stop card. Native looks the item up by `id` (a stop item without a reply), resolves the agent's surface from the item's own ids or the hook session map, and sends `text` as input with Enter (`ipcSendText(reply, true)`, or agent messages), then records `Resolution.reply` so the item reports `resolution {text, badge: "Sent"}`. The other keys are informational: the page renders agent-supplied markdown, so native never routes the text by ids the page sends |
| `feed.jump` | `{id, workspace_id?, surface_id?, session_id?, source?}` -> `{}` | double click on a card, the ↗ button, Enter on a focused card, a workstream chip. `not_found` = the agent is not in a wmux terminal (the page says so) |
| `panel.open_in_browser` | `{url}` | http(s) links inside a rendered plan |
| `panel.open_external` | `{url}` | mailto: links inside a rendered plan |
| `panel.state_changed` | `{state: {v: 1, filter}}` | tab changes, debounced 400 ms |

Item fields are exactly what `query.zig writeListItem` writes: `id`, `kind`
(`permissionRequest`, `exitPlan`, `question`, `stop`, `todos`, `notification`,
`message`, `prompt`, `toolUse`, `toolResult`, `sessionStart`, `sessionEnd`),
`status` (`pending`, `resolved`, `timedOut`, `expired`, `info`), `source`,
`hook_event_name`, `title`, `detail`, `created_at` (Unix seconds),
`request_id`, `session_id`, `workspace_id`, `surface_id`, `tool_name`, `text`,
`questions [{question, header, multi_select, options [{label,
description}]}]`, `plan {text, file_path, allowed_prompts}`, `todos [{content,
status, active_form}]`, `todo_summary`, `is_error`, `options` (selectable
modes, or the question option labels), `resolution {mode?, feedback?,
selections?, text?, badge}`, `resolved_at`. Unknown kinds are skipped.

Reply errors use the v2 codes of ADR-3.5 (`wmux_proto/errors.zig`):
`not_found` (unknown request id) and `invalid_state` or `stale_state` (the
request is no longer pending: answered elsewhere, timed out or expired) show
"This request was already resolved."; others "Could not send the decision:
<message>". Either way the list reloads.

### Events pushed by native

| Event | Payload | Effect |
|---|---|---|
| `cmux.event` | events frame `{name, ...}` | `feed.item.received`, `feed.item.completed`, `feed.item.resolved` (any `feed.*`) reload the newest page. Payloads are redacted on the stream, so the page never reads item text from frames |
| `panel.feed.item` | `{item}` (or the item itself) | insert or replace one item without a round trip |
| `panel.feed.snapshot` | `feed.list` result | replaces the newest page |
| `panel.feed.command` | `{action, id?}` | `showActionable`, `showActivity`, `focus`, `refresh`, `review` (with `id`: show and focus that card, e.g. after a toast click) |
| `panel.init`, `theme`, `keymap`, `panel.key_sequence` | shared | handled here and by `_shared/` |

## Behavior notes

- **Tabs.** Actionable = pending decisions, latest first, then a "Resolved"
  divider with the decisions that are no longer pending (resolved, timed
  out, expired) and their badges (`once`, `always`, `all tools`, `bypass`,
  `denied`; `ultraplan`, `manual`, `auto`, `bypass`, `denied`, `refined`;
  `Submitted`; `timed out`, `expired`). All Activity = every item. The
  Actionable tab shows the pending count. Empty states: "No pending
  decisions" / "Permission, plan, and question requests from AI agents will
  appear here." and "No activity yet" / "Agent decisions and todo-list
  updates will appear here."
- **Cards.** Kind label, agent name, tool, relative time ("now", "5m", "2h",
  "3d", "1w"), badge, ↗ jump. Prompt rows read "You: <first line>"; resolved
  plans read "Plan: <first line>"; tool results show ok/error.
- **Permission.** Buttons only for the modes in `options`, in cmux order:
  Allow Once, Always Allow, All tools, Bypass, Deny. Items without a
  `request_id` (telemetry-only sources such as Codex) show no buttons.
- **Plan.** The plan is markdown rendered without raw HTML and sanitized by
  DOMPurify (no images, forms, media, styles, ids or classes; links only
  http(s), opened in a wmux browser tab, and mailto, opened by the OS
  handler, on click and on middle click; the page itself never navigates
  and never asks the host for a new window). Plan file and allowed
  prompts are listed. Ultraplan / Manual / Auto / Bypass / Deny as offered,
  and "Revise…" opens a feedback box ("Send feedback", Ctrl+Enter).
- **Question.** Options are buttons; with one single-choice question a click
  answers at once. Multi-select questions toggle options. Each question has an
  "Other…" field ("Type something..."; for single choice the text replaces
  the option). Several questions use "Submit All Answers", enabled when every
  question has an answer. No options: "Agent provided no options." plus the
  text field. "Skip + plan immediately" arrives as a regular option label.
- **Stop.** "<Agent> finished — reply to continue", a "Reply to <Agent>…"
  box and "Send to <Agent>" (Ctrl+Enter). The sent text stays on the card.
- **Todos.** "Tasks" with "<n> open, <n> in progress, <n> done" (zero parts
  omitted, empty = "0 open") and a "Show tasks" / "Collapse" toggle.
- **Answering.** The card shows "Sending…", then the resolved badge at once;
  native's resolution event (reload) confirms it. Typed text, selections,
  the focused field (with its caret) and the scroll position of plans and
  text boxes survive live re-renders. Every render rebuilds the cards, so
  while a primary pointer button is held renders wait for its release (at
  most 2 s): a busy feed must not replace the button under a click, which
  the browser would then drop.
- **Banners.** A pending decision that arrives after the panel loaded gets a
  banner above the list with the native toast wording ("<Agent> permission"
  / "<tool> needs approval" or "Decision needed", "<Agent> plan ready" /
  "Review and approve the plan", "<Agent> question" / "Agent is asking a
  question"), Review (switches to Actionable and focuses the card) and a
  dismiss button; at most 3. A banner is withdrawn when its item is no longer
  pending (answered here, in a toast or elsewhere).
- **Workstreams.** With two or more agent contexts (source + session) that
  have a surface, chips list them (pending count badge); a chip jumps to its
  agent.
- **Keyboard.** Cards use a roving tab stop: ArrowUp/Down or `k`/`j`,
  Home/End move, Enter jumps, Tab reaches the card's buttons. Tabs follow the
  ARIA tabs pattern (Left/Right, Home/End).
- **Limits.** At most 2000 items are kept; plans above 200000 characters
  render as plain text.

## CSP

```
default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; font-src 'self'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'
```

No trusted-types directive: DOMPurify uses an HTML sink for plan text.

## Tests

`test/web-node/feed/feed.test.mjs` (node:test + jsdom, mock
`window.chrome.webview` from `../notifications/harness.mjs`):

```sh
npm install --prefix /tmp/wmux-web-test-deps --ignore-scripts jsdom@26
WMUX_WEB_TEST_DEPS=/tmp/wmux-web-test-deps node --test 'test/web-node/**/*.test.mjs'
```
