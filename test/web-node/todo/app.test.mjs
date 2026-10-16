// Todos pane tests: node:test + jsdom driving src/web/todo/app.js against a
// mock host that implements workspace.todo.* like the native checklist.
import { test, describe, afterEach, after } from "node:test";
import assert from "node:assert/strict";
import { setupPage, hostError, settle, key, click, mouse, cspOf } from "./harness.mjs";

const page = await setupPage("todo");
const { window, doc, host, importWeb, pristineBody } = page;
const { createApp } = await importWeb("todo/app.js");

const WS = "8F0C3C1E-0000-4000-8000-00000000000A";
let app = null;
let store = null;
let nextId = 1;

function item(text, extra = {}) {
  return { id: `id-${nextId++}`, text, state: "pending", origin: "user", ...extra };
}

function listReply() {
  const completed = store.items.filter((i) => i.state === "completed").length;
  return { items: store.items.map((i) => ({ ...i })), completed, total: store.items.length };
}

function find(id) {
  const i = store.items.findIndex((x) => x.id === id);
  if (i < 0) throw hostError("invalid_params", `Invalid todo item: ${id}`);
  return i;
}

/** Start a fresh app on a fresh body with `items` in the mock store. */
async function startApp({ items = [], init = {}, handlers = {} } = {}) {
  if (app) app.destroy();
  doc.body.innerHTML = pristineBody;
  host.reset();
  store = { items: items.map((i) => ({ ...i })), status: { lane: "todo", pinned: false } };
  const base = {
    "panel.ready": () => ({}),
    "panel.set_title": () => ({}),
    "panel.subscribe": () => ({}),
    "panel.todo.open_status": () => ({}),
    "workspace.status.get": () => store.status,
    "workspace.todo.list": () => listReply(),
    "workspace.todo.add": ({ text }) => {
      if (store.items.length >= 50) throw hostError("invalid_params", "Too many items");
      store.items.push(item(text));
      return listReply();
    },
    "workspace.todo.set_state": ({ item: id, state }) => {
      store.items[find(id)].state = state;
      return listReply();
    },
    "workspace.todo.edit": ({ item: id, text }) => {
      store.items[find(id)].text = text;
      return listReply();
    },
    "workspace.todo.remove": ({ item: id }) => {
      store.items.splice(find(id), 1);
      return listReply();
    },
    "workspace.todo.clear": () => {
      store.items = [];
      return listReply();
    },
    "workspace.todo.move": ({ item: id, index }) => {
      const [moving] = store.items.splice(find(id), 1);
      store.items.splice(index, 0, moving);
      return listReply();
    },
    "panel.todo.attach_images": ({ item: id }) => {
      const it = store.items[find(id)];
      it.attachments = [
        ...(it.attachments || []),
        { id: "a1", name: "one.png" },
        { id: "a2", name: "two.png" },
      ];
      return listReply();
    },
    "panel.todo.open_attachment": () => ({}),
    "panel.todo.remove_attachment": ({ item: id, attachment }) => {
      const it = store.items[find(id)];
      it.attachments = it.attachments.filter((a) => a.id !== attachment);
      return {};
    },
    ...handlers,
  };
  for (const [method, fn] of Object.entries(base)) host.handlers.set(method, fn);
  host.emit("panel.init", {
    kind: "todo",
    surface_id: "5B1D2C9E-0000-4000-8000-000000000002",
    params: { workspace_id: WS },
    state: null,
    theme: { background: "#1e1e1e", foreground: "#d4d4d4" },
    settings: {},
    ...init,
  });
  app = createApp({ document: doc });
  await app.start();
  await settle();
  return app;
}

const $ = (id) => doc.getElementById(id);
const rows = () => Array.from(doc.querySelectorAll("#todo-list .todo-item"));
const texts = () =>
  rows().map(
    (li) =>
      li.querySelector(".todo-text, .todo-editor").textContent || li.querySelector(".todo-editor")?.value,
  );
const rowOf = (text) => rows().find((li) => li.querySelector(".todo-text")?.textContent === text);

after(() => window.close());
afterEach(() => {
  if (app) {
    app.destroy();
    app = null;
  }
});

describe("unit: todo pane basics", () => {
  test("unit: todo: page has a strict CSP and no inline script or style", () => {
    const csp = cspOf(page.html);
    assert.match(csp, /default-src 'self'/);
    assert.match(csp, /script-src 'self'/);
    assert.match(csp, /object-src 'none'/);
    assert.match(csp, /trusted-types 'none'/);
    assert.doesNotMatch(csp, /unsafe-inline|unsafe-eval|https?:\/\/(?!\*\.wmux)/);
    assert.doesNotMatch(page.html, /<script(?![^>]*src=)|style="|<style|\son[a-z]+=/i);
  });

  test("unit: todo: every data-i18n key in index.html is in strings.js with the same text", async () => {
    const { STRINGS } = await importWeb("todo/strings.js");
    const tpl = new window.DOMParser().parseFromString(page.html, "text/html");
    const keyed = tpl.querySelectorAll("[data-i18n]");
    assert.ok(keyed.length > 0);
    for (const el of keyed) {
      assert.equal(el.textContent.trim(), STRINGS[el.dataset.i18n], el.dataset.i18n);
    }
    for (const el of tpl.querySelectorAll("[data-i18n-attr]")) {
      for (const pair of el.dataset.i18nAttr.split(";")) {
        const [attr, k] = pair.split(":").map((s) => s.trim());
        assert.equal(el.getAttribute(attr), STRINGS[k], `${attr}:${k}`);
      }
    }
  });

  test("unit: todo: start lists the workspace, sets the title and arms the add field", async () => {
    await startApp({
      items: [item("write test"), item("lint", { state: "completed" }), item("build", { origin: "agent" })],
    });
    assert.deepEqual(host.calls("panel.set_title")[0].params, { title: "Todos" });
    assert.deepEqual(host.calls("workspace.todo.list")[0].params, { workspace_id: WS });
    assert.deepEqual(host.calls("panel.subscribe")[0].params, { categories: ["workspace"] });
    // Unchecked first, completed last.
    assert.deepEqual(texts(), ["write test", "build", "lint"]);
    assert.equal($("todo-progress").textContent, "1/3");
    assert.equal(doc.activeElement, $("todo-add-input"));
    assert.ok(rowOf("build").querySelector(".todo-badge-agent"));
    assert.ok(!rowOf("write test").querySelector(".todo-badge-agent"));
    assert.ok(rowOf("lint").classList.contains("is-completed"));
    assert.equal(rowOf("lint").querySelector(".todo-check").checked, true);
    assert.equal(rowOf("lint").querySelector(".todo-check").title, "Mark as pending");
    assert.equal(rowOf("build").querySelector(".todo-check").title, "Mark as completed");
    assert.equal($("todo-empty").hidden, true);
    assert.equal($("todo-lane").hidden, true);
  });

  test("unit: todo: empty state and lane label", async () => {
    await startApp();
    assert.equal($("todo-empty").hidden, false);
    assert.equal($("todo-empty").textContent, "No checklist items yet.");
    assert.equal($("todo-progress").textContent, "");
    assert.equal($("todo-clear").hidden, true);
    host.emit("panel.todo.status", { workspace_id: WS, lane: "in_progress", lane_name: "In Progress" });
    assert.equal($("todo-lane").hidden, false);
    assert.equal($("todo-lane").textContent, "In Progress");
    assert.equal($("todo-status").dataset.lane, "in_progress");
    click(window, $("todo-status"));
    await settle();
    assert.equal(host.calls("panel.todo.open_status").length, 1);
    assert.equal(host.calls("panel.todo.open_status")[0].params.workspace_id, WS);
  });

  test("unit: todo: item text is rendered as text, never as markup", async () => {
    await startApp({ items: [item('<img src=x onerror="alert(1)"><b>bold</b>')] });
    const li = rows()[0];
    assert.equal(li.querySelector("img"), null);
    assert.equal(li.querySelector("b"), null);
    assert.equal(li.querySelector(".todo-text").textContent, '<img src=x onerror="alert(1)"><b>bold</b>');
  });
});

describe("unit: todo pane interaction", () => {
  test("unit: todo: Return in the add row adds an item, clears and stays armed", async () => {
    await startApp();
    const input = $("todo-add-input");
    input.value = "  ship it  ";
    key(window, input, { key: "Enter" });
    await settle();
    assert.deepEqual(host.calls("workspace.todo.add")[0].params, { workspace_id: WS, text: "ship it" });
    assert.deepEqual(texts(), ["ship it"]);
    assert.equal(input.value, "");
    assert.equal(doc.activeElement, input);
    // Blank text never reaches native.
    input.value = "   ";
    key(window, input, { key: "Enter" });
    await settle();
    assert.equal(host.calls("workspace.todo.add").length, 1);
    assert.equal($("todo-error").textContent, "Enter some text first.");
    assert.equal(input.value, "   ");
    // IME composition Enter does not add.
    input.value = "kana";
    key(window, input, { key: "Enter", isComposing: true });
    await settle();
    assert.equal(host.calls("workspace.todo.add").length, 1);
  });

  test("unit: todo: a full checklist (50 items) refuses new items client-side", async () => {
    const many = Array.from({ length: 50 }, (_, i) => item(`n${i}`));
    await startApp({ items: many });
    $("todo-add-input").value = "one more";
    key(window, $("todo-add-input"), { key: "Enter" });
    await settle();
    assert.equal(host.calls("workspace.todo.add").length, 0);
    assert.equal($("todo-error").textContent, "The checklist is full (50 items).");
    assert.equal($("todo-add-input").value, "one more");
  });

  test("unit: todo: Down then Ctrl+Enter completes the highlighted item", async () => {
    await startApp({ items: [item("a"), item("b"), item("c")] });
    const list = $("todo-list");
    list.focus();
    key(window, list, { key: "ArrowDown" });
    assert.equal(app.highlightId, store.items[0].id);
    key(window, list, { key: "ArrowDown" });
    assert.equal(app.highlightId, store.items[1].id);
    assert.equal(list.getAttribute("aria-activedescendant"), rowOf("b").id);
    key(window, list, { key: "Enter", ctrlKey: true });
    await settle();
    assert.deepEqual(host.calls("workspace.todo.set_state")[0].params, {
      workspace_id: WS,
      item: store.items[1].id,
      state: "completed",
    });
    assert.deepEqual(texts(), ["a", "c", "b"]);
    assert.equal($("todo-progress").textContent, "1/3");
    // The highlight follows the item; plain Return toggles it back.
    key(window, list, { key: "Enter" });
    await settle();
    assert.equal(store.items[1].state, "pending");
    // Clamped at the ends.
    key(window, list, { key: "Home" });
    key(window, list, { key: "ArrowUp" });
    assert.equal(app.highlightId, store.items[0].id);
    key(window, list, { key: "End" });
    key(window, list, { key: "ArrowDown" });
    assert.equal(app.highlightId, rows().at(-1).dataset.id);
  });

  test("unit: todo: native command events toggle like the shortcut", async () => {
    await startApp({ items: [item("a")] });
    host.emit("panel.todo.command", { action: "toggleChecklistItemComplete" });
    await settle();
    assert.equal(host.calls("workspace.todo.set_state").length, 0, "nothing highlighted yet");
    key(window, $("todo-list"), { key: "ArrowDown" });
    host.emit("panel.todo.command", { action: "toggleChecklistItemComplete" });
    await settle();
    assert.equal(store.items[0].state, "completed");
  });

  test("unit: todo: checkbox click toggles; in-progress completes", async () => {
    await startApp({ items: [item("a", { state: "in-progress" })] });
    assert.ok(rows()[0].querySelector(".todo-badge-progress"));
    assert.equal(rows()[0].querySelector(".todo-check").indeterminate, true);
    click(window, rows()[0].querySelector(".todo-check"));
    await settle();
    assert.equal(store.items[0].state, "completed");
    click(window, rows()[0].querySelector(".todo-check"));
    await settle();
    assert.equal(store.items[0].state, "pending");
  });

  test("unit: todo: focus stays on the list when a re-render removes the focused child", async () => {
    await startApp({ items: [item("a"), item("b")] });
    const list = $("todo-list");
    // WebView2 focuses a checkbox on mouse click (tabindex -1 only keeps it out of Tab order).
    const box = rows()[0].querySelector(".todo-check");
    box.focus();
    assert.equal(doc.activeElement, box);
    click(window, box);
    await settle();
    assert.equal(store.items[0].state, "completed");
    assert.equal(doc.activeElement, list, "focus did not fall to <body>");
    key(window, list, { key: "ArrowDown" });
    assert.equal(app.highlightId, store.items[1].id);
    // Same when a live update removes the item being edited.
    app.startEdit(store.items[1].id);
    assert.equal(doc.activeElement, doc.querySelector(".todo-editor"));
    store.items.splice(1, 1);
    host.emit("panel.todo.changed", { workspace_id: WS, ...listReply() });
    await settle();
    assert.equal(app.editingId, null);
    assert.equal(doc.activeElement, list);
  });

  test("unit: todo: click selects, click again edits, Return commits, Escape cancels", async () => {
    await startApp({ items: [item("first"), item("second")] });
    click(window, rowOf("first").querySelector(".todo-text"));
    assert.equal(app.highlightId, store.items[0].id);
    assert.equal(app.editingId, null);
    click(window, rowOf("first").querySelector(".todo-text"));
    assert.equal(app.editingId, store.items[0].id);
    const editor = doc.querySelector(".todo-editor");
    assert.equal(doc.activeElement, editor);
    editor.value = "  first, edited ";
    key(window, editor, { key: "Enter" });
    await settle();
    assert.deepEqual(host.calls("workspace.todo.edit")[0].params, {
      workspace_id: WS,
      item: store.items[0].id,
      text: "first, edited",
    });
    assert.equal(app.editingId, null);
    assert.deepEqual(texts(), ["first, edited", "second"]);
    // Escape discards.
    app.startEdit(store.items[1].id);
    doc.querySelector(".todo-editor").value = "nope";
    key(window, doc.querySelector(".todo-editor"), { key: "Escape" });
    await settle();
    assert.equal(host.calls("workspace.todo.edit").length, 1);
    assert.deepEqual(texts(), ["first, edited", "second"]);
    // Empty edits are refused, the text stays.
    app.startEdit(store.items[1].id);
    doc.querySelector(".todo-editor").value = "  ";
    key(window, doc.querySelector(".todo-editor"), { key: "Enter" });
    await settle();
    assert.equal(host.calls("workspace.todo.edit").length, 1);
    assert.equal(store.items[1].text, "second");
  });

  test("unit: todo: an open editor survives a live update", async () => {
    await startApp({ items: [item("a"), item("b")] });
    app.startEdit(store.items[0].id);
    doc.querySelector(".todo-editor").value = "draft";
    store.items.push(item("c"));
    host.emit("panel.todo.changed", { workspace_id: WS, ...listReply() });
    await settle();
    assert.equal(rows().length, 3);
    assert.equal(doc.querySelector(".todo-editor").value, "draft");
    assert.equal(doc.activeElement, doc.querySelector(".todo-editor"));
  });

  test("unit: todo: a re-render that reports the editor's removal as focusout keeps the draft", async () => {
    await startApp({ items: [item("a"), item("b")] });
    const focusout = () => new window.FocusEvent("focusout", { bubbles: true, relatedTarget: null });
    const list = $("todo-list");
    // Chromium (WebView2) fires focusout, relatedTarget null, when
    // replaceChildren() removes the focused editor; jsdom does not.
    list.replaceChildren = function (...nodes) {
      const active = doc.activeElement;
      if (active && active !== this && this.contains(active)) active.dispatchEvent(focusout());
      return window.Element.prototype.replaceChildren.apply(this, nodes);
    };
    app.startEdit(store.items[0].id);
    doc.querySelector(".todo-editor").value = "draft";
    store.items.push(item("c"));
    host.emit("panel.todo.changed", { workspace_id: WS, ...listReply() });
    await settle();
    assert.equal(host.calls("workspace.todo.edit").length, 0, "a live update never commits the draft");
    assert.equal(app.editingId, store.items[0].id);
    assert.equal(doc.querySelector(".todo-editor").value, "draft");
    assert.equal(doc.activeElement, doc.querySelector(".todo-editor"));
    // Really leaving the editor still commits it.
    doc.querySelector(".todo-editor").dispatchEvent(focusout());
    await settle();
    assert.deepEqual(
      host.calls("workspace.todo.edit").map((c) => c.params.text),
      ["draft"],
    );
    assert.equal(app.editingId, null);
    assert.equal(store.items[0].text, "draft");
  });

  test("unit: todo: context menu offers Edit, Mark In Progress and Remove", async () => {
    await startApp({ items: [item("a"), item("b")] });
    mouse(window, rowOf("b"), "contextmenu", { clientX: 10, clientY: 10 });
    const menu = $("todo-menu");
    assert.equal(menu.hidden, false);
    const labels = Array.from(menu.querySelectorAll(".todo-menu-item")).map((b) => b.textContent);
    assert.deepEqual(labels, ["Edit", "Mark In Progress", "Remove"]);
    assert.equal(doc.activeElement, menu.querySelector(".todo-menu-item"));
    key(window, doc.activeElement, { key: "ArrowDown" });
    assert.equal(doc.activeElement.textContent, "Mark In Progress");
    click(window, doc.activeElement);
    await settle();
    assert.equal(menu.hidden, true);
    assert.equal(store.items[1].state, "in-progress");
    // In-progress items offer Mark as Pending instead.
    mouse(window, rowOf("b"), "contextmenu");
    assert.ok(
      Array.from(menu.querySelectorAll(".todo-menu-item")).some((b) => b.textContent === "Mark as Pending"),
    );
    key(window, doc.activeElement, { key: "Escape" });
    assert.equal(menu.hidden, true);
    // Remove.
    mouse(window, rowOf("a"), "contextmenu");
    click(
      window,
      Array.from(menu.querySelectorAll(".todo-menu-item")).find((b) => b.textContent === "Remove"),
    );
    await settle();
    assert.deepEqual(texts(), ["b"]);
    assert.equal(host.calls("workspace.todo.remove").length, 1);
    // Edit from the keyboard menu (Shift+F10).
    key(window, $("todo-list"), { key: "ArrowDown" });
    key(window, $("todo-list"), { key: "F10", shiftKey: true });
    click(window, menu.querySelector('[data-action="edit"]'));
    assert.equal(app.editingId, store.items[0].id);
  });

  test("unit: todo: dragging item 3 above item 1 reorders it", async () => {
    await startApp({ items: [item("1"), item("2"), item("3"), item("done", { state: "completed" })] });
    const fire = (type, el) => {
      const ev = new window.Event(type, { bubbles: true, cancelable: true });
      el.dispatchEvent(ev);
      return ev;
    };
    fire("dragstart", rowOf("3"));
    // Not into the completed group.
    assert.equal(fire("dragover", rowOf("done")).defaultPrevented, false);
    assert.equal(fire("dragover", rowOf("1")).defaultPrevented, true);
    assert.ok(rowOf("1").classList.contains("drop-before"));
    fire("drop", rowOf("1"));
    await settle();
    assert.deepEqual(host.calls("workspace.todo.move")[0].params, {
      workspace_id: WS,
      item: store.items[0].id,
      index: 0,
    });
    assert.deepEqual(texts(), ["3", "1", "2", "done"]);
    assert.equal(doc.querySelectorAll(".drop-before, .drop-after, .is-dragging").length, 0);
  });

  test("unit: todo: Alt+Up / Alt+Down reorder within the group", async () => {
    await startApp({ items: [item("a"), item("b"), item("x", { state: "completed" })] });
    key(window, $("todo-list"), { key: "ArrowDown" });
    key(window, $("todo-list"), { key: "ArrowDown", altKey: true });
    await settle();
    assert.deepEqual(texts(), ["b", "a", "x"]);
    key(window, $("todo-list"), { key: "ArrowDown", altKey: true });
    await settle();
    assert.equal(host.calls("workspace.todo.move").length, 1, "the completed group is a wall");
  });
});

describe("unit: todo pane attachments, live updates and states", () => {
  test("unit: todo: attach two images shows 2, Open and Remove Attachment work", async () => {
    await startApp({ items: [item("shot")] });
    const btn = () => rows()[0].querySelector(".todo-attach");
    assert.equal(btn().title, "Manage images");
    assert.equal(btn().getAttribute("aria-label"), "No images attached. Attach images.");
    click(window, btn());
    const menu = $("todo-menu");
    assert.deepEqual(
      Array.from(menu.querySelectorAll(".todo-menu-item")).map((b) => b.textContent),
      ["Attach Images…"],
    );
    click(window, menu.querySelector('[data-action="attach"]'));
    await settle();
    assert.equal(btn().querySelector(".todo-attach-count").textContent, "2");
    assert.equal(btn().getAttribute("aria-label"), "2 images attached");
    click(window, btn());
    const labels = Array.from(menu.querySelectorAll(".todo-menu-label")).map((l) => l.textContent);
    assert.deepEqual(labels, ["one.png", "two.png"]);
    click(window, menu.querySelector('[data-action="open-attachment"][data-attachment="a1"]'));
    await settle();
    assert.deepEqual(host.calls("panel.todo.open_attachment")[0].params, {
      workspace_id: WS,
      item: store.items[0].id,
      attachment: "a1",
    });
    click(window, btn());
    click(window, menu.querySelector('[data-action="remove-attachment"][data-attachment="a2"]'));
    await settle();
    assert.equal(btn().getAttribute("aria-label"), "1 image attached");
    assert.equal(store.items[0].attachments.length, 1);
  });

  test("unit: todo: Return on a row's paperclip activates it instead of toggling the item", async () => {
    await startApp({ items: [item("shot"), item("other")] });
    const list = $("todo-list");
    list.focus();
    key(window, list, { key: "ArrowDown" });
    const clip = rows()[0].querySelector(".todo-attach");
    clip.focus();
    const ev = key(window, clip, { key: "Enter" });
    await settle();
    assert.equal(ev.defaultPrevented, false, "the button keeps its Return activation");
    assert.equal(host.calls("workspace.todo.set_state").length, 0);
    assert.equal(store.items[0].state, "pending");
    // Return on the list itself still toggles.
    list.focus();
    key(window, list, { key: "Enter" });
    await settle();
    assert.equal(store.items[0].state, "completed");
  });

  test("unit: todo: live updates apply pushed lists and re-read on bare change events", async () => {
    await startApp({ items: [item("a")] });
    store.items.push(item("from agent", { origin: "agent" }));
    host.emit("panel.todo.changed", { workspace_id: WS, ...listReply() });
    await settle();
    assert.deepEqual(texts(), ["a", "from agent"]);
    const before = host.calls("workspace.todo.list").length;
    store.items[0].state = "completed";
    host.emit("panel.todo.changed", { workspace_id: WS });
    await settle();
    assert.equal(host.calls("workspace.todo.list").length, before + 1);
    assert.deepEqual(texts(), ["from agent", "a"]);
    // Another workspace's change is ignored.
    host.emit("panel.todo.changed", { workspace_id: "other", items: [] });
    await settle();
    assert.equal(rows().length, 2);
  });

  test("unit: todo: focus_add re-arms the add field", async () => {
    await startApp({ items: [item("a")] });
    $("todo-list").focus();
    host.emit("panel.todo.focus_add", { workspace_id: WS });
    assert.equal(doc.activeElement, $("todo-add-input"));
  });

  test("unit: todo: a closed workspace shows the unavailable state", async () => {
    await startApp({ items: [item("a")] });
    host.emit("cmux.event", { name: "workspace.closed", workspace_id: "someone-else" });
    assert.equal(app.available, true);
    host.emit("cmux.event", { name: "workspace.closed", payload: { workspace_id: WS } });
    assert.equal(app.available, false);
    assert.equal($("todo-unavailable").hidden, false);
    assert.equal($("todo-unavailable").textContent.trim(), "This workspace is no longer available.");
    assert.equal($("todo-main").hidden, true);
    assert.equal($("todo-add").hidden, true);
    assert.equal($("todo-progress").textContent, "");
    await app.addItem("x");
    assert.equal(host.calls("workspace.todo.add").length, 0);
  });

  test("unit: todo: not_found on load shows the unavailable state", async () => {
    await startApp({
      handlers: {
        "workspace.todo.list": () => {
          throw hostError("not_found", "Workspace not found");
        },
      },
    });
    assert.equal(app.available, false);
    assert.equal($("todo-unavailable").hidden, false);
  });

  test("unit: todo: Clear asks first and Escape cancels", async () => {
    await startApp({ items: [item("a"), item("b")] });
    click(window, $("todo-clear"));
    assert.equal($("todo-confirm").hidden, false);
    assert.equal($("todo-confirm-text").textContent, "Remove all 2 checklist items?");
    key(window, $("todo-confirm-cancel"), { key: "Escape" });
    await settle();
    assert.equal($("todo-confirm").hidden, true);
    assert.equal(host.calls("workspace.todo.clear").length, 0);
    click(window, $("todo-clear"));
    click(window, $("todo-confirm-ok"));
    await settle();
    assert.equal(host.calls("workspace.todo.clear").length, 1);
    assert.equal(rows().length, 0);
    assert.equal($("todo-empty").hidden, false);
  });

  test("unit: todo: the Clear confirmation is modal and gives focus back", async () => {
    await startApp({ items: [item("a"), item("b")] });
    $("todo-clear").focus();
    click(window, $("todo-clear"));
    assert.equal(doc.activeElement, $("todo-confirm-cancel"));
    const others = Array.from(doc.body.children).filter((el) => el !== $("todo-confirm"));
    assert.ok(
      others.every((el) => el.hasAttribute("inert")),
      "the page behind the dialog is inert",
    );
    key(window, $("todo-confirm-cancel"), { key: "Escape" });
    await settle();
    assert.equal(doc.querySelectorAll("[inert]").length, 0);
    assert.equal(doc.activeElement, $("todo-clear"), "Cancel returns to the Clear button");
    click(window, $("todo-clear"));
    click(window, $("todo-confirm-ok"));
    await settle();
    assert.equal(rows().length, 0);
    assert.equal($("todo-clear").hidden, true);
    assert.equal(doc.activeElement, $("todo-add-input"), "after clearing, the add row has focus");
  });

  test("unit: todo: not_found for an item removed meanwhile keeps the pane", async () => {
    let workspaceGone = false;
    await startApp({
      items: [item("a"), item("b")],
      handlers: {
        // An agent removed the item a moment ago.
        "workspace.todo.set_state": () => {
          throw hostError("not_found", "Invalid todo item");
        },
        "workspace.todo.list": () => {
          if (workspaceGone) throw hostError("not_found", "Workspace not found");
          return listReply();
        },
      },
    });
    store.items.splice(0, 1);
    const before = host.calls("workspace.todo.list").length;
    await app.toggleItem(rows()[0].dataset.id);
    await settle();
    assert.equal(app.available, true, "the workspace is still there");
    assert.equal(host.calls("workspace.todo.list").length, before + 1, "the list is re-read");
    assert.deepEqual(texts(), ["b"]);
    assert.equal($("todo-error").textContent, "Could not update the checklist: Invalid todo item");
    // When the re-read confirms the workspace is gone, the pane says so.
    workspaceGone = true;
    await app.toggleItem(rows()[0].dataset.id);
    await settle();
    assert.equal(app.available, false);
    assert.equal($("todo-unavailable").hidden, false);
  });

  test("unit: todo: a failed mutation reports the error and re-reads the list", async () => {
    await startApp({
      items: [item("a")],
      handlers: {
        "workspace.todo.set_state": () => {
          throw hostError("internal_error", "disk full");
        },
      },
    });
    await app.toggleItem(store.items[0].id);
    await settle();
    assert.equal($("todo-error").textContent, "Could not update the checklist: disk full");
    assert.equal(rows()[0].classList.contains("is-completed"), false, "optimistic change rolled back");
  });

  test("unit: todo: replies without a checklist trigger a re-read", async () => {
    await startApp({
      items: [item("a")],
      handlers: {
        "workspace.todo.add": ({ text }) => {
          store.items.push(item(text));
          return { ok: true };
        },
      },
    });
    const before = host.calls("workspace.todo.list").length;
    await app.addItem("b");
    await settle();
    assert.equal(host.calls("workspace.todo.list").length, before + 1);
    assert.deepEqual(texts(), ["a", "b"]);
  });

  test("unit: todo: huge and unicode text round-trips through the pane", async () => {
    await startApp();
    await app.addItem("🚀 デプロイ " + "x".repeat(700));
    await settle();
    const sent = host.calls("workspace.todo.add")[0].params.text;
    assert.equal(Array.from(sent).length, 500);
    assert.ok(sent.startsWith("🚀 デプロイ "));
    assert.equal(rows()[0].querySelector(".todo-text").textContent, sent);
  });
});

test("unit: todo: outside wmux it shows a notice and an empty list", async () => {
  if (app) app.destroy();
  doc.body.innerHTML = pristineBody;
  const offline = {
    available: false,
    context: null,
    on: () => () => {},
    call: () => Promise.reject(new Error("x")),
  };
  app = createApp({
    document: doc,
    bridge: offline,
    installKeys: () => ({ setKeymap() {}, handle: () => () => {} }),
  });
  await app.start();
  assert.equal($("todo-error").textContent, "Not running inside wmux.");
  assert.equal($("todo-empty").hidden, false);
});
