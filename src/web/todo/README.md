# `src/web/todo`: Workspace Todos pane

PanelKind `todo` (ARCHITECTURE ADR-6.11), entry
`https://todo.wmux.example/todo/index.html`, tab title `Todos`. Shows one
workspace's full checklist (no clamping): header with the status glyph, title,
lane and progress; items with unchecked first; a pinned, always-armed add row;
keyboard highlight and toggle; click to edit; a context menu; image
attachments; drag reorder within a completion group; live updates; and the
"workspace is gone" state.

Covers: `sidebar-todo-pane` (page side), `sidebar-todo-checklist-attachments`
(Todos pane part; the file picker, storage and viewer are native).

| File | Purpose |
|---|---|
| `index.html` | page shell: header, list, empty and unavailable states, add row, menu, confirm dialog |
| `todo.js` | entry module: theme sync and app start |
| `app.js` | the application: bridge, rendering, mutations, keyboard, menus, drag and drop |
| `model.js` | pure checklist rules mirrored from `src/apprt/win32/features/todo/logic/checklist.zig` |
| `strings.js` | user-visible strings (`tr()` keys) |
| `todo.css` | layout on the `--wmux-*` tokens |

No vendored libraries: the page has no HTML sinks (all text goes through
`textContent`), so its CSP also enforces Trusted Types.

## Model (mirrors the native checklist)

- Item: `{id, text, state, origin, attachments?}`; `state` is `pending`,
  `in-progress` or `completed`; `origin` is `user` or `agent` (agent items show an
  `agent` badge; in-progress items show `In progress` and an indeterminate
  checkbox). Unknown states read as `pending`, unknown origins as `user`. Items
  with a repeated id keep the first one.
- At most 50 items. Text is trimmed (ASCII and Unicode spaces, same set as
  `isSpace`), must not be empty or contain lone surrogates, and is capped at
  500 code points. The page checks these before calling native. Native stays
  authoritative.
- Display order: items that are not completed come first, then completed ones,
  each in storage order. Storage order is never rewritten by the page except
  through `workspace.todo.move`.
- Toggle (Return, Ctrl+Enter, checkbox): `completed` -> `pending`, anything else
  -> `completed`.
- Reorder: drag and drop or Alt+Up / Alt+Down (wmux addition for keyboard
  users) only within the item's completion group, clamped like
  `Checklist.move`. A drop that leaves the shown order unchanged sends
  nothing (with completed items between open ones in storage it would only
  renumber `todo list`).

## Native contract

Checklist methods are cmux's `workspace.todo.*` (Appendix B.1, owner W5a
`todo`); they must be in the kind's allowlist together with
`workspace.status.get`. cmux does not document the v2 parameter names, so the
page sends these. The native handlers should accept them, and they are easy to
adapt in one place (`mutate` callers in `app.js`):

| Method | Params (page -> native) | Result |
|---|---|---|
| `workspace.todo.list` | `{workspace_id}` | checklist `{items, completed, total}` (the `Checklist.jsonStringify` shape) |
| `workspace.todo.add` | `{workspace_id, text}` | checklist (or anything: the page then re-reads) |
| `workspace.todo.set_state` | `{workspace_id, item, state}` | checklist |
| `workspace.todo.edit` | `{workspace_id, item, text}` | checklist |
| `workspace.todo.remove` | `{workspace_id, item}` | checklist |
| `workspace.todo.move` | `{workspace_id, item, index}` | checklist; `index` is the 0-based **storage** index, already clamped to the group |
| `workspace.todo.clear` | `{workspace_id}` | checklist |
| `workspace.status.get` | `{workspace_id}` | `{lane, lane_name?, pinned?}` (optional; errors leave the glyph neutral) |

`item` is always the item UUID (native `Checklist.resolve` accepts it).
`workspace_id` comes from `panel.init.params.workspace_id`; when absent the page
omits it and native should use the panel's own workspace. A reply carrying a
checklist is applied directly, anything else triggers `workspace.todo.list`.
Mutations update the page first (optimistic); on an error the page shows
"Could not update the checklist: <message>" and re-reads the list.
`not_found` / `workspace_not_found` from `workspace.todo.list` switch to the
unavailable state. A mutation failing with them only triggers that re-read,
because `not_found` can also name an item that an agent or the CLI removed
meanwhile.

Panel-local methods (`panel.todo.*`, handled by the kind's `on_message`; cmux
has no names for these):

| Method | Params -> result | Notes |
|---|---|---|
| `panel.todo.open_status` | `{workspace_id, anchor: {x, y, width, height}}` -> `{}` | the status glyph: open the shared status popover anchored at the glyph (CSS px relative to the panel's viewport, from `getBoundingClientRect`; native scales by the DPI) |
| `panel.todo.attach_images` | `{workspace_id, item}` -> checklist or `{}` | "Attach Images…": native file picker (image filters), copies the files into its attachment store, persists them with the item. Called without a timeout (the picker is modal) |
| `panel.todo.open_attachment` | `{workspace_id, item, attachment}` -> `{}` | "Open": default viewer or a preview |
| `panel.todo.remove_attachment` | `{workspace_id, item, attachment}` -> checklist or `{}` | "Remove Attachment" |

Attachments arrive on items as `attachments: [{id, name}]` (a bare string is
both). The page never sees file paths. The count shows on the paperclip
(tooltip `Manage images`; a11y text `No images attached. Attach images.`,
`1 image attached`, `N images attached`).

### `panel.init`

| Key | Used for |
|---|---|
| `params.workspace_id` | the workspace whose checklist is shown |
| `params.focus_add` | `false` keeps focus off the add row on open (default: armed) |
| `params.workspace_missing` | `true` opens straight into "This workspace is no longer available." |
| `keymap` | effective bindings; the default is `{toggleChecklistItemComplete: ["ctrl+enter"]}` |

The page sets the tab title with `panel.set_title {title: "Todos"}` and calls
`panel.subscribe {categories: ["workspace"]}`.

### Events pushed by native

| Event | Payload | Effect |
|---|---|---|
| `panel.todo.changed` | checklist plus `workspace_id`, or just `{workspace_id}` | live update from the CLI, socket, popover or agents: apply, or re-read when there are no `items`. The highlight follows its item id |
| `panel.todo.status` | `{workspace_id, lane, lane_name?, pinned?}` | header lane and glyph (`data-lane`); the lane is hidden when it is `todo` and not pinned |
| `panel.todo.focus_add` | `{workspace_id}` | `todo open` / `workspace.todo.open` on an existing pane: focus the add row |
| `panel.todo.command` | `{action}` | `toggleChecklistItemComplete` (native KeyRouter consumed Ctrl+Enter under `todoFocus`, or the palette) and `wmux.todoFocusAdd` |
| `panel.todo.workspace_closed` | `{workspace_id}` | unavailable state |
| `cmux.event` | frame named `workspace.closed` with this `workspace_id` | unavailable state |

Payloads whose `workspace_id` names another workspace are ignored.

## Behavior notes

- **Keyboard** (list focused, not editing): Up/Down move the highlight
  (clamped), Home/End jump, Return toggles (Return on a row's paperclip button
  opens its menu instead), F2 edits, Shift+F10 or the menu key opens the
  context menu, Alt+Up/Down reorder. Up/Down in the add row move the
  highlight too, and focus stays in the add row. `toggleChecklistItemComplete`
  (Ctrl+Enter) toggles the highlighted item, also from the add row. While
  editing it commits first, then toggles the edited item. Rows carry
  `aria-checked` (completed or not) for screen readers.
- **Mouse**: click selects, clicking the selected item starts editing, and
  clicking while editing focuses the editor. Return commits, Escape discards,
  and leaving the pane commits. Clicking another item commits the edit and
  selects that item. An open editor and its draft survive live updates.
- **Context menu**: Edit, Mark In Progress (Mark as Pending on in-progress
  items), Remove. The paperclip menu: Attach Images…, then per attachment its
  name with Open and Remove Attachment. Menus close on Escape or an outside
  click; Up/Down/Home/End move inside them.
- **Clear**: the header `Clear` button (shown when there are items) asks
  "Remove all N checklist items?" first; Escape cancels. The dialog is modal
  (the page behind it is `inert`); Cancel returns focus to what opened it, and
  after clearing focus moves to the add row.
- **Background**: opaque window color (`--wmux-surface`).

## CSP

```
default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; font-src 'self'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; require-trusted-types-for 'script'; trusted-types 'none'
```

## Tests

`test/web-node/todo/` (node:test + jsdom, mock `window.chrome.webview` from
`harness.mjs`):

```sh
npm install --prefix /tmp/wmux-web-test-deps --ignore-scripts jsdom@26
WMUX_WEB_TEST_DEPS=/tmp/wmux-web-test-deps node --test 'test/web-node/todo/*.test.mjs'
```
