// Keyboard Shortcuts section: list, recorder, validation messages, unbind and
// restore, per-action reset, Reset Default Shortcuts, presets, find by keys.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { $, $$, createStore, flush, host, hostError, keydown, rowEl, startSettings, window } from "./helpers.mjs";

const doc = window.document;

const CATALOG = [
  { id: "splitRight", title: "Split Right", category: "pane", keys: ["ctrl+shift+d"] },
  { id: "newSurface", title: "New Surface", category: "surface", keys: ["ctrl+shift+t"] },
  {
    id: "selectWorkspaceByNumber",
    title: "Select Workspace 1…9",
    category: "workspace",
    keys: ["ctrl+alt+1"],
    numbered: true,
  },
  { id: "browserReload", title: "Reload Page", category: "browser", keys: ["f5", "ctrl+r"], when: "browserFocus" },
  { id: "toggleSidebar", title: "Toggle Sidebar", category: "sidebar", keys: ["ctrl+shift+b"] },
  { id: "openSettings", title: "Settings…", category: "app", keys: ["ctrl+,"] },
  { id: "diffViewerScrollDown", title: "Scroll Down", category: "viewer", keys: ["j"], when: "diffViewerFocus" },
];

/** Fake native shortcut store: catalog defaults < cmux.json < wmux.json. */
function shortcutHandlers({ wmux = {}, cmux = {} } = {}) {
  const s = { wmux: { ...wmux }, cmux: { ...cmux }, validate: null, preset: "cmux" };
  s.list = () => ({
    actions: CATALOG.map((a) => {
      let keys = a.keys;
      let source = "default";
      if (a.id in s.cmux) [keys, source] = [s.cmux[a.id], "cmux.json"];
      if (a.id in s.wmux) [keys, source] = [s.wmux[a.id], "wmux.json"];
      return { ...a, keys, default_keys: a.keys, source };
    }),
    presets: [
      { name: "cmux", title: "wmux (Default)" },
      {
        name: "tmux",
        title: "tmux-style (Ctrl-B prefix)",
        description: "Ctrl+B prefix chords.",
        warning: "Ctrl+B will no longer reach the shell.",
      },
    ],
    preset: s.preset,
  });
  s.handlers = {
    "wmux.shortcuts.list": () => s.list(),
    "wmux.shortcuts.validate": (p) => (s.validate ? s.validate(p) : { ok: true }),
    "wmux.shortcuts.set": ({ id, keys }) => {
      s.wmux[id] = keys;
      return {};
    },
    "wmux.settings.reset_shortcuts": () => {
      s.wmux = {};
      return {};
    },
    "wmux.settings.apply_preset": ({ name }) => {
      s.preset = name;
      if (name !== "tmux") return { changes: [] };
      s.wmux.newSurface = ["ctrl+b c"];
      return {
        changes: [{ id: "newSurface", old: ["ctrl+shift+t"], new: [["ctrl+b", "c"]] }],
        kept: ["toggleSidebar"],
        warnings: ["Ctrl+B will no longer reach the shell."],
      };
    },
  };
  return s;
}

async function open(opts = {}) {
  const sc = shortcutHandlers(opts);
  const store = createStore();
  const unset = store.install;
  store.install = () => {
    unset();
    host.handlers.set("wmux.settings.unset", ({ path }) => {
      const id = path.replace(/^shortcuts\.bindings\./, "");
      delete sc.wmux[id];
      return {};
    });
  };
  const started = await startSettings({
    store,
    handlers: sc.handlers,
    init: { params: { target: "keyboard-shortcuts" } },
  });
  await flush();
  return { ...started, sc };
}

const row = (id) => $(`.set-sc-row[data-action="${id}"]`);
const keysOf = (id) => $$(".set-kbd", row(id)).map((k) => k.textContent);
const errorsOf = (id) => $$(".set-row-error", row(id)).map((e) => e.textContent);

async function recordFor(id, init) {
  row(id).querySelector(".set-sc-keys").click();
  keydown({ bubbles: true, ...init }, doc.body);
  await flush();
}

describe("unit: persistence-settings-keyboard-shortcuts-section: list", () => {
  test("unit: persistence-settings-keyboard-shortcuts-section: groups actions by category with when labels", async () => {
    await open();
    assert.deepEqual(
      $$(".set-sc-group").map((g) => g.dataset.category),
      ["app", "workspace", "surface", "pane", "browser", "viewer", "sidebar"],
    );
    assert.deepEqual(keysOf("browserReload"), ["F5", "Ctrl+R"]);
    assert.equal(
      row("browserReload").querySelector(".set-sc-when").textContent,
      "Only while a browser pane is focused",
    );
    assert.ok(rowEl("app.paneResizeStepPixels"), "Pane Resize Step row");
    assert.ok(rowEl("shortcuts.showModifierHoldHints"));
    assert.equal(rowEl("shortcuts.bindings"), null);
    assert.equal($(".set-sc-chords .set-subheading").textContent, "Shortcut Chords");
  });

  test("unit: core-shortcuts-settings-ui: search filters and reports no match", async () => {
    await open();
    const search = $("#set-sc-search");
    search.value = "split";
    search.dispatchEvent(new window.Event("input"));
    assert.deepEqual(
      $$(".set-sc-row").map((r) => r.dataset.action),
      ["splitRight"],
    );
    search.value = "nothing-like-this";
    search.dispatchEvent(new window.Event("input"));
    assert.equal($("#set-sc-groups .set-empty").textContent, "No shortcuts match");
  });

  test("unit: core-shortcuts-settings-ui: cmux.json rows are read-only", async () => {
    await open({ cmux: { toggleSidebar: ["ctrl+shift+alt+b"] } });
    assert.equal(row("toggleSidebar").querySelector(".set-sc-keys").disabled, true);
    assert.equal(row("toggleSidebar").querySelector(".set-row-managed").textContent, "Managed by cmux.json");
    assert.equal(row("toggleSidebar").querySelector(".set-sc-unbind"), null);
  });

  test("unit: core-shortcuts-settings-ui: list failure shows the error and the chord help", async () => {
    await startSettings({
      handlers: {
        "wmux.shortcuts.list": () => {
          throw hostError("internal_error", "nope");
        },
      },
      init: { params: { target: "keys" } },
    });
    await flush();
    assert.equal($(".set-shortcuts > .set-row-error").textContent, "Shortcuts are not available: nope");
    assert.ok($(".set-sc-chords"));
  });
});

describe("unit: core-shortcuts-settings-ui: recorder", () => {
  test("unit: core-shortcuts-settings-ui: recording Ctrl+Shift+D for New Surface reports a conflict and is not saved", async () => {
    const { sc } = await open();
    row("newSurface").querySelector(".set-sc-keys").click();
    assert.equal(row("newSurface").querySelector(".set-sc-keys").textContent, "Listening…");
    assert.deepEqual(host.calls("panel.key_capture").at(-1).params, { on: true });
    keydown({ key: "D", code: "KeyD", keyCode: 68, ctrlKey: true, shiftKey: true }, doc.body);
    await flush();
    assert.deepEqual(errorsOf("newSurface"), ["This shortcut conflicts with Split Right (Ctrl+Shift+D)"]);
    assert.equal(host.calls("wmux.shortcuts.set").length, 0);
    assert.equal(sc.wmux.newSurface, undefined);
    assert.deepEqual(host.calls("panel.key_capture").at(-1).params, { on: false });
  });

  test("unit: persistence-settings-keyboard-shortcuts-section: recording a free shortcut validates natively and saves", async () => {
    const { sc } = await open();
    await recordFor("newSurface", { key: "N", code: "KeyN", keyCode: 78, ctrlKey: true, shiftKey: true, altKey: true });
    assert.deepEqual(
      host.calls("wmux.shortcuts.validate").map((m) => m.params),
      [{ id: "newSurface", keys: ["ctrl+shift+alt+n"] }],
    );
    assert.deepEqual(sc.wmux.newSurface, ["ctrl+shift+alt+n"]);
    assert.deepEqual(keysOf("newSurface"), ["Ctrl+Shift+Alt+N"]);
    assert.equal($("#set-status").textContent, "Saved Ctrl+Shift+Alt+N for New Surface.");
    assert.ok(row("newSurface").querySelector(".set-sc-reset"), "customized rows get a reset button");
  });

  test("unit: core-shortcuts-settings-ui: native conflicts, errors and warnings are shown", async () => {
    const { sc } = await open();
    sc.validate = () => ({
      ok: false,
      conflicts: [{ id: "splitRight", keys: ["ctrl+shift+alt+m"] }],
      warnings: ["Shadowed on this layout"],
    });
    await recordFor("newSurface", { key: "M", code: "KeyM", keyCode: 77, ctrlKey: true, shiftKey: true, altKey: true });
    assert.deepEqual(errorsOf("newSurface"), ["This shortcut conflicts with Split Right (Ctrl+Shift+Alt+M)"]);
    assert.equal(row("newSurface").querySelector(".set-row-warning").textContent, "Shadowed on this layout");
    sc.validate = () => {
      throw hostError("method_not_found", "x");
    };
    await recordFor("newSurface", { key: "M", code: "KeyM", keyCode: 77, ctrlKey: true, shiftKey: true, altKey: true });
    assert.deepEqual(sc.wmux.newSurface, ["ctrl+shift+alt+m"]);
  });

  test("unit: core-shortcuts-settings-ui: bare keys, reserved keys and numbered actions", async () => {
    const { sc } = await open();
    await recordFor("newSurface", { key: "k", code: "KeyK", keyCode: 75 });
    assert.deepEqual(errorsOf("newSurface"), ["Shortcuts must include Ctrl, Alt or Shift"]);
    await recordFor("newSurface", { key: "Tab", code: "Tab", keyCode: 9, altKey: true });
    assert.deepEqual(errorsOf("newSurface"), ["This keystroke is reserved by Windows."]);
    await recordFor("selectWorkspaceByNumber", { key: "x", code: "KeyX", keyCode: 88, ctrlKey: true, shiftKey: true });
    assert.deepEqual(errorsOf("selectWorkspaceByNumber"), ["Use a digit from 1 through 9."]);
    await recordFor("selectWorkspaceByNumber", {
      key: "&",
      code: "Digit7",
      keyCode: 55,
      ctrlKey: true,
      shiftKey: true,
    });
    assert.deepEqual(sc.wmux.selectWorkspaceByNumber, ["ctrl+shift+1"]);
    await recordFor("diffViewerScrollDown", { key: "n", code: "KeyN", keyCode: 78 });
    assert.deepEqual(sc.wmux.diffViewerScrollDown, ["n"]);
  });

  test("unit: core-shortcuts-settings-ui: Escape cancels; modifier-only presses are ignored", async () => {
    await open();
    row("newSurface").querySelector(".set-sc-keys").click();
    keydown({ key: "Shift", code: "ShiftLeft", shiftKey: true }, doc.body);
    assert.equal(row("newSurface").querySelector(".set-sc-keys").textContent, "Listening…");
    keydown({ key: "Escape", code: "Escape", keyCode: 27 }, doc.body);
    await flush();
    assert.deepEqual(keysOf("newSurface"), ["Ctrl+Shift+T"]);
    assert.equal(host.calls("wmux.shortcuts.validate").length, 0);
    assert.deepEqual(host.calls("panel.key_capture").at(-1).params, { on: false });
  });

  test("unit: core-shortcuts-settings-ui: unbind turns into Restore; restore brings the shortcut back", async () => {
    const { sc } = await open();
    row("splitRight").querySelector(".set-sc-unbind").click();
    await flush();
    assert.deepEqual(sc.wmux.splitRight, []);
    assert.equal(row("splitRight").querySelector(".set-sc-keys").textContent, "None");
    const restore = row("splitRight").querySelector(".set-sc-restore");
    assert.equal(restore.getAttribute("aria-label"), "Restore previous shortcut");
    restore.click();
    await flush();
    assert.deepEqual(sc.wmux.splitRight, ["ctrl+shift+d"]);
    assert.deepEqual(keysOf("splitRight"), ["Ctrl+Shift+D"]);
  });

  test("unit: core-shortcuts-settings-ui: save failures are shown on the row", async () => {
    await open();
    host.handlers.set("wmux.shortcuts.set", () => {
      throw hostError("io_error", "locked file");
    });
    await recordFor("newSurface", { key: "N", code: "KeyN", keyCode: 78, ctrlKey: true, shiftKey: true, altKey: true });
    assert.deepEqual(errorsOf("newSurface"), ["Could not save the shortcut: locked file"]);
  });
});

describe("unit: persistence-settings-keyboard-shortcuts-section: resets and presets", () => {
  test("unit: persistence-settings-keyboard-shortcuts-section: per-action reset unsets the binding", async () => {
    const { sc } = await open({ wmux: { splitRight: ["ctrl+shift+alt+d"] } });
    assert.deepEqual(keysOf("splitRight"), ["Ctrl+Shift+Alt+D"]);
    row("splitRight").querySelector(".set-sc-reset").click();
    await flush();
    assert.deepEqual(
      host.calls("wmux.settings.unset").map((m) => m.params.path),
      ["shortcuts.bindings.splitRight"],
    );
    assert.equal(sc.wmux.splitRight, undefined);
    assert.deepEqual(keysOf("splitRight"), ["Ctrl+Shift+D"]);
  });

  test("unit: persistence-settings-keyboard-shortcuts-section: Reset Default Shortcuts confirms and keeps cmux.json rows", async () => {
    const { sc } = await open({
      wmux: { splitRight: ["ctrl+shift+alt+d"] },
      cmux: { toggleSidebar: ["ctrl+shift+alt+b"] },
    });
    $("#set-sc-reset-defaults").click();
    assert.match($("#set-confirm-body").textContent, /^Restore the built-in shortcuts\?/);
    $("#set-confirm-cancel").click();
    await flush();
    assert.equal(host.calls("wmux.settings.reset_shortcuts").length, 0);
    $("#set-sc-reset-defaults").click();
    $("#set-confirm-ok").click();
    await flush();
    assert.equal(host.calls("wmux.settings.reset_shortcuts").length, 1);
    assert.deepEqual(keysOf("splitRight"), ["Ctrl+Shift+D"]);
    assert.deepEqual(keysOf("toggleSidebar"), ["Ctrl+Shift+Alt+B"]);
    assert.equal($("#set-status").textContent, "Default shortcuts restored.");
    assert.deepEqual(sc.cmux, { toggleSidebar: ["ctrl+shift+alt+b"] });
  });

  test("unit: persistence-settings-keyboard-shortcuts-section: reset falls back to unset per wmux.json row", async () => {
    const { sc } = await open({ wmux: { splitRight: ["ctrl+shift+alt+d"], newSurface: ["ctrl+shift+alt+t"] } });
    host.handlers.delete("wmux.settings.reset_shortcuts");
    $("#set-sc-reset-defaults").click();
    $("#set-confirm-ok").click();
    await flush(10);
    assert.deepEqual(
      host
        .calls("wmux.settings.unset")
        .map((m) => m.params.path)
        .sort(),
      ["shortcuts.bindings.newSurface", "shortcuts.bindings.splitRight"],
    );
    assert.deepEqual(sc.wmux, {});
  });

  test("unit: persistence-settings-keyboard-shortcuts-section: applying the tmux preset installs Ctrl-B chords and reports changes", async () => {
    await open();
    const select = $("#set-sc-preset");
    assert.deepEqual(
      Array.from(select.options).map((o) => o.textContent),
      ["wmux (Default)", "tmux-style (Ctrl-B prefix)"],
    );
    assert.equal(select.value, "cmux");
    select.value = "tmux";
    $("#set-sc-preset-apply").click();
    assert.match($("#set-confirm-body").textContent, /Ctrl\+B will no longer reach the shell\./);
    $("#set-confirm-ok").click();
    await flush();
    assert.deepEqual(
      host.calls("wmux.settings.apply_preset").map((m) => m.params),
      [{ name: "tmux" }],
    );
    assert.deepEqual(
      $$(".set-sc-report li").map((li) => li.textContent),
      [
        "New Surface: Ctrl+Shift+T -> Ctrl+B C",
        "Kept your own shortcut for Toggle Sidebar.",
        "Ctrl+B will no longer reach the shell.",
      ],
    );
    assert.deepEqual(keysOf("newSurface"), ["Ctrl+B C"]);
    assert.equal($("#set-sc-preset").value, "tmux");
  });

  test("unit: persistence-settings-keyboard-shortcuts-section: preset failures and empty reports", async () => {
    const { app } = await open();
    await Promise.all([app.shortcuts.applyPreset("cmux"), flush(1).then(() => $("#set-confirm-ok").click())]);
    assert.deepEqual(
      $$(".set-sc-report li").map((li) => li.textContent),
      ["No shortcuts changed."],
    );
    host.handlers.set("wmux.settings.apply_preset", () => {
      throw hostError("invalid_params", "Unknown preset");
    });
    await Promise.all([app.shortcuts.applyPreset("tmux"), flush(1).then(() => $("#set-confirm-ok").click())]);
    assert.deepEqual(
      $$(".set-sc-report li").map((li) => li.textContent),
      ["Could not apply the preset: Unknown preset"],
    );
    assert.equal(await app.shortcuts.applyPreset("missing"), false);
  });

  test("unit: core-shortcuts-settings-ui: find shortcut by keys", async () => {
    await open();
    $("#set-sc-detect").click();
    assert.equal($(".set-sc-detect span").textContent, "Press keys to see which shortcut uses them");
    keydown({ key: "r", code: "KeyR", keyCode: 82, ctrlKey: true }, doc.body);
    await flush();
    assert.equal($(".set-sc-detect span").textContent, "Shortcuts using Ctrl+R");
    assert.deepEqual(
      $$(".set-sc-row").map((r) => r.dataset.action),
      ["browserReload"],
    );
    $("#set-sc-detect-stop").click();
    assert.equal($(".set-sc-detect"), null);
    $("#set-sc-detect").click();
    keydown({ key: "q", code: "KeyQ", keyCode: 81, ctrlKey: true, altKey: true, shiftKey: true }, doc.body);
    await flush();
    assert.equal($("#set-sc-groups .set-empty").textContent, "No shortcut uses Ctrl+Shift+Alt+Q.");
  });

  test("unit: core-shortcuts-settings-ui: navigating away stops a running recorder", async () => {
    const { app } = await open();
    row("newSurface").querySelector(".set-sc-keys").click();
    assert.equal(app.shortcuts.isRecording(), true);
    app.navigate("app");
    assert.equal(app.shortcuts.isRecording(), false);
    assert.deepEqual(host.calls("panel.key_capture").at(-1).params, { on: false });
  });

  test("unit: core-shortcuts-settings-ui: chord docs and Open wmux.json", async () => {
    await open();
    $("#set-sc-chord-docs").click();
    $("#set-sc-open-json").click();
    await flush();
    assert.deepEqual(
      host.calls("wmux.settings.open_docs").map((m) => m.params.topic),
      ["shortcut-chords"],
    );
    assert.deepEqual(
      host.calls("wmux.settings.open_file").map((m) => m.params.file),
      ["wmux"],
    );
  });
});
