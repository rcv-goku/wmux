# `src/web/notifications`: notifications popover and pane

PanelKind `notifications` (ARCHITECTURE ADR-6.11, ADR-7.7), entry
`https://notifications.wmux.example/notifications/index.html`. One page serves
both placements: the popover (owned popup anchored to the sidebar bell,
`showNotifications`) and the Notifications pane tab (one per workspace,
open-or-focus). It lists notification records grouped by workspace with
unread state, and offers open (jump), mark read/unread, dismiss, Clear All,
Jump to Latest (Unread), Copy, a context menu, keyboard navigation, the empty
and markers-only states and live updates.

Covers: `notifications-popover`, `notifications-panel-pane-tab`,
`notifications-copy` (page side; the popup window, its size persistence, the
pane kind and session entry are native).

| File | Purpose |
|---|---|
| `index.html` | page shell: header (count capsule, Jump, Clear All), list, empty state, context menu |
| `notifications.js` | entry module: theme sync + app start |
| `app.js` | the application: bridge, loading, live updates, rendering, actions, keys, menu |
| `model.js` | pure helpers: record normalization, grouping, copy text, time format, shortcut labels |
| `strings.js` | user-visible strings (`tr()` keys) |
| `notifications.css` | popover rows and pane cards on the `--wmux-*` tokens |

No libraries: everything is text, so the page has no HTML sink and its CSP
adds `require-trusted-types-for 'script'; trusted-types 'none'`.

## Native contract

Names follow ADR-6.5: cmux method names where cmux has them (ADR-7.8,
Appendix B). Methods and events that cmux does not name live under the
panel's own namespace, `panel.notifications.*` (handled by the kind's
`on_message`, like `panel.markdown.*`), and are documented here. The kind's
allowlist therefore needs only `notification.*` and `workspace.list`
(`panel.*` is implicit), with the event categories `notification`,
`workspace` and `wmux`.

### `panel.init`

| Key | Used for |
|---|---|
| `params.placement` | `"popover"` or `"tab"` (default). `params.popover: true` also selects the popover |
| `params.group_by` | `"workspace"` (default) or `"none"`: the flat cmux list (popover rows lead with the workspace title) |
| `params.payload` | optional initial snapshot (same shape as `notification.list`), rendered before the first call returns |
| `state` | `{v: 1, focused_id}` restores the focused row |
| `keymap` | effective bindings; `jumpToUnread` feeds the shortcut chip of the Jump button |

A later `panel.init` (the warm popover host re-shown with other params) is
applied in place. The page sets the title with `panel.set_title
{title: "Notifications"}` and subscribes with `panel.subscribe
{categories: ["notification", "workspace", "wmux"]}`.

### Methods called by the page

| Method | Params -> result | When |
|---|---|---|
| `notification.list` | `{}` -> `{notifications: [record], marker_count?}` | start and after every relevant event (debounced 40 ms; only the newest reply applies). A bare array is accepted too |
| `workspace.list` | `{}` -> `{workspaces: [{id, title}]}` | live workspace titles; reloaded on the workspace events that change titles or order |
| `notification.open` | `{id}` | row click, Enter, menu Open. In the popover the page then calls `panel.notifications.close_popover` |
| `notification.mark_read` | `{id}` | menu Mark as Read, Space on an unread row |
| `panel.notifications.mark_unread` | `{id}` -> `{}` | menu Mark as Unread, Space on a read row. Native: `Store.markUnread(id)` (record-level, not the workspace `toggleUnread`) |
| `notification.dismiss` | `{id}` | hover X, Delete/Backspace, menu Dismiss |
| `notification.clear` | `{}` | Clear All |
| `notification.jump_to_unread` | `{}` | Jump to Latest (Unread), `jumpToUnread` key handler; popover closes after |
| `panel.notifications.close_popover` | `{}` -> `{}` | after open/jump from the popover, and Escape in the popover. Native hides the popup (keeps the warm host) |
| `panel.clipboard_write` | `{text}` | Copy (Ctrl+C on a row, menu Copy) |
| `panel.state_changed` | `{state: {v: 1, focused_id}}` | focus changes, debounced 400 ms |

The record selector is `id`, as in cmux's `notification.open {id}`,
`notification.mark_read {id}` and `notification.dismiss {id}`.

Record fields mirror `features/notifications/logic/store.zig`: `id`,
`workspace`, `surface`, `title`, `subtitle`, `body`, `created_at_ms`, `read`,
`agent {kind, category}`; optional display extras `workspace_title` (used when
`workspace.list` does not know the workspace) and `surface_title` (caption).
The page also accepts cmux's payload spellings: `notification_id`,
`workspace_id`, `surface_id`, `is_read`, `tab_title` (cmux's name for the
workspace title, so it is the `workspace_title` fallback) and `created_at` /
`timestamp` in seconds, milliseconds or ISO text. `marker_count` (or a
`markers` array) counts workspace/surface unread markers (manual or restored)
so the markers-only state can show "N unread notifications".

Actions are optimistic: the row changes at once; a failed call shows "Could
not complete the action: <message>" and reloads the list. A
`notification.list` reply that was in flight when an action started is
dropped (it predates the action), and the list reloads after the action.

### Events pushed by native

| Event | Payload | Effect |
|---|---|---|
| `cmux.event` | events frame `{name, ...}` | `notification.*`, `wmux.notification.unread_count.changed`, `wmux.attention.changed` reload the list; `workspace.created`, `.renamed`, `.reordered`, `.moved` and `.closed` reload the titles (`workspace.selected` and `workspace.prompt.submitted` are ignored). Payloads are redacted on the stream, so the page never reads record text from frames. Re-renders keep the scroll position; only moving the focus scrolls a row into view |
| `panel.notifications.snapshot` | `notification.list` result, optionally with `workspaces` | replaces the list without a round trip |
| `panel.notifications.command` | `{action}` | `jumpToUnread`, `clearAllNotifications`, `focus` (focus the list), `refresh` |
| `panel.init`, `theme`, `keymap`, `panel.key_sequence` | shared | handled here and by `_shared/` |

## Behavior notes

- **Header.** "Notifications", an accent capsule with the global unread count
  as cmux counts it: unread records plus `marker_count` (hidden at 0, "99+"
  above 99), "Jump to Latest" (popover) / "Jump to Latest Unread"
  (pane) with the `jumpToUnread` shortcut chip, disabled without unread records
  or markers, and "Clear All", disabled when the list is empty. The cmux
  "Forward notifications to my iPhone" row is not shown (no mobile companion
  on Windows).
- **Grouping.** Records are grouped by workspace (live title, unread count in
  the group header); groups follow their newest record, rows stay newest
  first. Rows then lead with the record title and show the surface title (or
  "Workspace" for surface-less records) as the caption. With `group_by:
  "none"` the popover row is cmux's: workspace title bold + short time, the
  record title, the body (2 lines); the pane card is title + time, body (3
  lines) and the workspace caption.
- **Unread state.** Popover rows show a 3 px accent bar; pane cards a filled
  dot (outlined when read).
- **Rows.** Click opens. The hover-only X dismisses. Right click (or
  Shift+F10 / the Menu key) opens Open / Copy / Mark as Read|Mark as Unread /
  Dismiss; the menu is keyboard navigable (arrows, Home/End, Enter, Escape).
  Every render rebuilds the rows, so while a primary pointer button is held,
  renders wait for its release (at most 2 s): a live update must not replace
  the row under a click, which the browser would then drop.
- **Keyboard.** The list is a listbox with a roving tab stop. ArrowUp/Down or
  `k`/`j`, Home/End, PgUp/PgDn move; Enter opens; Space toggles read; Delete
  or Backspace dismisses; Ctrl+C copies. When the page gets focus (pane shown
  or focused) the last focused row, else the first, takes focus, so Return
  opens the newest notification. That does not scroll the list: focus usually
  comes back with a click, which must land on the row under the pointer.
  Escape in the popover closes it.
- **Copy.** Workspace title (if known), title, then the body (or the subtitle
  when the body is empty); each trimmed, empty lines dropped, the detail
  dropped when equal to the title; joined with `\n`.
- **Empty states.** "No notifications yet" + "Desktop notifications will
  appear here." (popover) / "… here for quick review." (pane); with only
  markers: "N unread notifications" with a badged bell.
- **Time.** Time of day for today, else a short date; full timestamp in the
  tooltip; refreshed every minute.
- **Limits.** At most 1000 records are kept (native caps history at 500);
  text fields are clipped at 8192 UTF-16 units without splitting a surrogate
  pair.

## CSP

```
default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; font-src 'self'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; require-trusted-types-for 'script'; trusted-types 'none'
```

## Tests

`test/web-node/notifications/notifications.test.mjs` (node:test + jsdom, mock
`window.chrome.webview` from `harness.mjs`):

```sh
npm install --prefix /tmp/wmux-web-test-deps --ignore-scripts jsdom@26
WMUX_WEB_TEST_DEPS=/tmp/wmux-web-test-deps node --test 'test/web-node/**/*.test.mjs'
```
