// Settings window app: navigation, deep links, search, typed controls,
// sources and locks, per-key reset and Reset All, driven through the mock host.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { $, $$, createStore, edit, flush, host, hostError, keydown, rowEl, startSettings, window } from "./helpers.mjs";

const doc = window.document;
const navCurrent = () => $(".set-nav-item[aria-current='page']").dataset.section;
const sectionShown = () => $(".set-section").dataset.section;

describe("unit: persistence-settings-window: navigation", () => {
  test("unit: persistence-settings-window: `settings shortcuts` target opens Keyboard Shortcuts", async () => {
    const { started } = await startSettings({ init: { params: { target: "shortcuts" } } });
    assert.equal(started, true);
    assert.equal(sectionShown(), "keyboardShortcuts");
    assert.equal(navCurrent(), "keyboardShortcuts");
    assert.equal($("#set-section-title").textContent, "Keyboard Shortcuts");
    assert.deepEqual(
      host.calls("panel.set_title").map((m) => m.params.title),
      ["Settings"],
    );
  });

  test("unit: persistence-settings-window: nav lists the wmux sections in order without cloud/account ones", async () => {
    await startSettings();
    const ids = $$(".set-nav-item").map((b) => b.dataset.section);
    assert.deepEqual(ids, [
      "app",
      "themes",
      "terminal",
      "textBox",
      "sidebarAppearance",
      "automation",
      "browser",
      "browserImport",
      "globalHotkey",
      "keyboardShortcuts",
      "workspaceColors",
      "settingsJSON",
      "reset",
      "windows",
    ]);
    assert.equal(sectionShown(), "app");
    $(".set-nav-item[data-section='terminal']").click();
    assert.equal(sectionShown(), "terminal");
    assert.deepEqual(host.calls("panel.state_changed").at(-1).params, { state: { v: 1, section: "terminal" } });
  });

  test("unit: persistence-settings-window: navigate event, saved state and unknown targets", async () => {
    const { app } = await startSettings({ init: { state: { section: "browser" } } });
    assert.equal(sectionShown(), "browser");
    host.emit("wmux.settings.navigate", { target: "hotkey" });
    assert.equal(sectionShown(), "globalHotkey");
    assert.equal(app.navigate("account"), "globalHotkey");
    assert.equal($("#set-status").textContent, "“account” is not available on Windows.");
    host.emit("wmux.settings.navigate", { target: 42 });
    assert.equal(sectionShown(), "globalHotkey");
  });

  test("unit: persistence-settings-window: arrow keys move through the nav", async () => {
    await startSettings();
    const items = $$(".set-nav-item");
    items[0].focus();
    keydown({ key: "ArrowDown" });
    assert.equal(doc.activeElement, items[1]);
    keydown({ key: "ArrowUp" });
    keydown({ key: "ArrowUp" });
    assert.equal(doc.activeElement, items[items.length - 1]);
    keydown({ key: "Home" });
    assert.equal(doc.activeElement, items[0]);
  });

  test("unit: persistence-settings-window: empty sections say so; empty schema still renders", async () => {
    const store = createStore();
    store.schema = { properties: {} };
    await startSettings({ store });
    assert.equal($(".set-empty").textContent, "This section has no settings yet.");
    $(".set-nav-item[data-section='reset']").click();
    assert.ok($("#set-reset-all"));
    assert.equal($(".set-empty"), null);
  });

  test("unit: persistence-settings-window: load failure shows an error with Retry", async () => {
    let fail = true;
    await startSettings({
      handlers: {
        "wmux.settings.get_effective": () => {
          if (fail) throw hostError("internal_error", "disk on fire");
          return { values: {} };
        },
      },
    });
    assert.equal($(".set-load-error").textContent, "Could not load settings: disk on fire");
    fail = false;
    $(".set-content button").click();
    await flush();
    assert.equal(sectionShown(), "app");
  });
});

describe("unit: persistence-settings-window: search", () => {
  test("unit: persistence-settings-window: searching scrollback reveals the Terminal rows", async () => {
    const { app } = await startSettings();
    edit($("#set-search"), "scrollback");
    const groups = $$(".set-result-group").map((g) => g.dataset.section);
    assert.deepEqual(groups, ["terminal"]);
    assert.ok(rowEl("terminal.showScrollBar"));
    assert.ok(rowEl("terminal.scrollSpeed"));
    assert.deepEqual(
      $$(".set-mark").map((m) => m.textContent),
      ["scrollback"],
    );
    assert.equal($(".set-nav-item[data-section='terminal'] .set-nav-count").textContent, "3");
    assert.ok($(".set-nav-item[data-section='app']").classList.contains("set-nav-dim"));
    assert.equal(app.state.query, "scrollback");
  });

  test("unit: persistence-settings-window: titles, keys and keywords highlight; custom sections link", async () => {
    await startSettings();
    edit($("#set-search"), "PORTS");
    assert.deepEqual(
      $$(".set-result-group").map((g) => g.dataset.section),
      ["sidebarAppearance"],
    );
    assert.ok($$(".set-mark").some((m) => m.textContent === "ports"));
    edit($("#set-search"), "keybindings");
    const link = $(".set-result-group[data-section='keyboardShortcuts'] .set-result-section");
    assert.ok(link);
    link.click();
    assert.equal(sectionShown(), "keyboardShortcuts");
    assert.equal($("#set-search").value, "");
  });

  test("unit: persistence-settings-window: no results, Escape clears, Ctrl+F focuses search", async () => {
    await startSettings();
    edit($("#set-search"), "  zzzz-<b>nothing</b>  ");
    assert.equal($(".set-empty").textContent, "No settings match “zzzz-<b>nothing</b>”.");
    assert.equal($("b"), null);
    $("#set-search").focus();
    keydown({ key: "Escape" });
    assert.equal($("#set-search").value, "");
    assert.equal(sectionShown(), "app");
    doc.body.focus();
    keydown({ key: "f", ctrlKey: true }, doc.body);
    assert.equal(doc.activeElement, $("#set-search"));
  });

  test("unit: persistence-settings-window: shortcuts.bindings is never a generic row, even in search", async () => {
    // cmux.json strokes are macOS syntax: saving the merged object would copy them into wmux.json.
    await startSettings({ store: createStore({ cmux: { "shortcuts.bindings": { splitRight: "cmd+d" } } }) });
    edit($("#set-search"), "shortcuts");
    assert.equal(rowEl("shortcuts.bindings"), null);
    assert.ok(rowEl("shortcuts.showModifierHoldHints"));
    edit($("#set-search"), "bindings");
    assert.equal(rowEl("shortcuts.bindings"), null);
    // Only the other key of the section matches (through the section keyword "keybindings").
    assert.deepEqual(
      $$(".set-search-results .set-row").map((r) => r.dataset.path),
      ["shortcuts.showModifierHoldHints"],
    );
    const link = $(".set-result-group[data-section='keyboardShortcuts'] .set-result-section");
    assert.ok(link, "the Keyboard Shortcuts page is offered instead");
    link.click();
    assert.equal(sectionShown(), "keyboardShortcuts");
    assert.equal(rowEl("shortcuts.bindings"), null);
  });

  test("unit: persistence-settings-window: huge and unicode queries do not break", async () => {
    const { app } = await startSettings();
    app.setQuery("x".repeat(10000));
    assert.equal(app.state.query.length, 256);
    app.setQuery("Ｃｏｐｙ");
    assert.ok(rowEl("terminal.copyOnSelect"));
    app.setQuery("😀");
    assert.ok($(".set-empty"));
  });
});

const control = (p) =>
  rowEl(p).querySelector(".set-row-control input, .set-row-control select, .set-row-control textarea");
const badges = (p) => Array.from(rowEl(p).querySelectorAll(".set-badge")).map((b) => b.textContent);
const errorText = (p) => {
  const e = rowEl(p).querySelector(".set-row-error");
  return e.hidden ? "" : e.textContent;
};

describe("unit: persistence-settings-window: sources and locks", () => {
  test("unit: persistence-settings-window: a key set in cmux.json is read-only until overridden", async () => {
    const store = createStore({ cmux: { "terminal.copyOnSelect": true } });
    const { app } = await startSettings({ store });
    app.navigate("terminal");
    const input = control("terminal.copyOnSelect");
    assert.equal(input.checked, true);
    assert.equal(input.disabled, true);
    assert.deepEqual(badges("terminal.copyOnSelect"), ["cmux.json", "Modified"]);
    assert.match(rowEl("terminal.copyOnSelect").querySelector(".set-row-managed").textContent, /^Set in cmux\.json/);
    rowEl("terminal.copyOnSelect").querySelector(".set-override").click();
    assert.equal(control("terminal.copyOnSelect").disabled, false);
    control("terminal.copyOnSelect").click();
    await flush();
    assert.deepEqual(
      host.calls("wmux.settings.set").map((m) => m.params),
      [{ path: "terminal.copyOnSelect", value: false }],
    );
    assert.deepEqual(badges("terminal.copyOnSelect"), ["wmux.json"]);
    assert.equal(store.wmux["terminal.copyOnSelect"], false);
  });

  test("unit: persistence-settings-window: policy-locked keys are read-only with no override or reset", async () => {
    const store = createStore({ policy: { "sidebar.showPorts": false }, wmux: { "sidebar.showPorts": true } });
    const { app } = await startSettings({ store });
    app.navigate("sidebar");
    const row = rowEl("sidebar.showPorts");
    assert.equal(control("sidebar.showPorts").disabled, true);
    assert.equal(row.querySelector(".set-row-managed span").textContent, "Managed by your organization");
    assert.equal(row.querySelector(".set-override").hidden, true);
    assert.equal(row.querySelector(".set-reset").hidden, true);
    assert.deepEqual(badges("sidebar.showPorts"), ["Policy", "Modified"]);
  });

  test("unit: persistence-settings-window: restart and project hints", async () => {
    const store = createStore();
    const { app } = await startSettings({ store });
    host.handlers.set("wmux.settings.get_effective", () => ({
      values: { ...store.effective(), "notifications.hooks": { value: { a: "b" }, source: "project" } },
    }));
    await app.refreshEffective();
    app.navigate("automation");
    assert.ok(badges("automation.socketControlMode").includes("Restart to apply"));
    assert.equal(rowEl("notifications.hooks").querySelector(".set-row-note").hidden, false);
  });

  test("unit: persistence-settings-window: changed events update rows in place", async () => {
    const { app } = await startSettings();
    app.navigate("terminal");
    host.emit("wmux.settings.changed", { values: { "terminal.scrollSpeed": { value: 2.5, source: "wmux.json" } } });
    assert.equal(control("terminal.scrollSpeed").value, "2.5");
    assert.deepEqual(badges("terminal.scrollSpeed"), ["wmux.json", "Modified"]);
    host.handlers.set("wmux.settings.get_effective", () => ({ values: {} }));
    host.emit("wmux.settings.changed", {});
    await flush();
    assert.equal(control("terminal.scrollSpeed").value, "1");
  });
});

describe("unit: persistence-settings-window: typed controls", () => {
  test("unit: persistence-settings-window: number ranges validate before saving; native errors show", async () => {
    const { app } = await startSettings();
    app.navigate("windows");
    const input = control("wmux.sidebar.width");
    assert.equal(input.type, "number");
    assert.equal(input.min, "120");
    assert.equal(input.max, "600");
    edit(input, "1000");
    await flush();
    assert.equal(errorText("wmux.sidebar.width"), "Must be between 120 and 600.");
    edit(input, "abc");
    assert.equal(errorText("wmux.sidebar.width"), "Enter a number.");
    assert.equal(host.calls("wmux.settings.set").length, 0);
    host.handlers.set("wmux.settings.set", () => {
      throw hostError("invalid_params", "wmux.sidebar.width: value out of range");
    });
    edit(input, "300");
    await flush();
    assert.equal(errorText("wmux.sidebar.width"), "wmux.sidebar.width: value out of range");
    assert.equal(control("wmux.sidebar.width").value, "220");
  });

  test("unit: persistence-settings-window: per-key reset removes the wmux.json value", async () => {
    const store = createStore({ wmux: { "terminal.scrollSpeed": 2 } });
    const { app } = await startSettings({ store });
    app.navigate("terminal");
    const reset = rowEl("terminal.scrollSpeed").querySelector(".set-reset");
    assert.equal(reset.hidden, false);
    assert.equal(reset.getAttribute("aria-label"), "Reset Scroll speed to its default");
    reset.click();
    await flush();
    assert.deepEqual(
      host.calls("wmux.settings.unset").map((m) => m.params),
      [{ path: "terminal.scrollSpeed" }],
    );
    assert.equal(control("terminal.scrollSpeed").value, "1");
    assert.deepEqual(badges("terminal.scrollSpeed"), []);
    assert.equal(rowEl("terminal.scrollSpeed").querySelector(".set-reset").hidden, true);
  });

  test("unit: persistence-settings-window: enum, string pattern, path and list controls", async () => {
    const { app, store } = await startSettings();
    app.navigate("automation");
    const select = control("automation.socketControlMode");
    assert.deepEqual(
      Array.from(select.options).map((o) => o.textContent),
      ["off", "cmuxOnly", "automation", "password", "allowAll", "readOnly"],
    );
    select.value = "4";
    select.dispatchEvent(new window.Event("change", { bubbles: true }));
    await flush();
    assert.equal(store.wmux["automation.socketControlMode"], "allowAll");
    edit(control("automation.autoNamingAgent"), "Bad Slug");
    assert.match(errorText("automation.autoNamingAgent"), /expected format/);
    edit(control("automation.claudeBinaryPath"), "C:\\Tools\\claude.exe");
    await flush();
    assert.equal(store.wmux["automation.claudeBinaryPath"], "C:\\Tools\\claude.exe");
    app.navigate("browser");
    edit(control("browser.urlAllowlist"), "example.com\n\n *.example.org \n");
    await flush();
    assert.deepEqual(store.wmux["browser.urlAllowlist"], ["example.com", "*.example.org"]);
    assert.equal(control("browser.urlAllowlist").value, "example.com\n*.example.org");
  });

  test("unit: persistence-settings-window: out-of-enum file values show but cannot be re-chosen", async () => {
    const { app } = await startSettings({ store: createStore({ wmux: { "app.appearance": "sepia" } }) });
    app.navigate("app");
    const select = control("app.appearance");
    assert.equal(select.selectedOptions[0].textContent, '"sepia"');
    assert.equal(select.selectedOptions[0].disabled, true);
  });

  test("unit: persistence-settings-window: color controls keep alpha, validate text and clear nullables", async () => {
    const { app, store } = await startSettings({
      store: createStore({ wmux: { activePaneBorderColor: "#11223380" } }),
    });
    app.navigate("app");
    const row = rowEl("activePaneBorderColor");
    const swatch = row.querySelector("input[type=color]");
    assert.equal(swatch.value, "#112233");
    swatch.value = "#aabbcc";
    swatch.dispatchEvent(new window.Event("change", { bubbles: true }));
    await flush();
    assert.equal(store.wmux.activePaneBorderColor, "#AABBCC80");
    edit(row.querySelector(".set-color-text"), "blue");
    assert.equal(errorText("activePaneBorderColor"), "Use #RRGGBB or #RRGGBBAA.");
    assert.equal(row.querySelector(".set-color button"), null); // not nullable
    app.navigate("sidebar");
    const sel = rowEl("sidebar.selectionColor");
    assert.equal(sel.querySelector(".set-color-text").placeholder, "Not set");
    edit(sel.querySelector(".set-color-text"), "#00ff00");
    await flush();
    assert.equal(store.wmux["sidebar.selectionColor"], "#00ff00");
    rowEl("sidebar.selectionColor").querySelector(".set-color button").click();
    await flush();
    assert.equal(store.wmux["sidebar.selectionColor"], null);
  });

  test("unit: persistence-settings-window: key-value editor adds, edits, removes and rejects duplicates", async () => {
    const { app, store } = await startSettings({
      store: createStore({ wmux: { "notifications.hooks": { a: "1", b: true } } }),
    });
    app.navigate("automation");
    const row = () => rowEl("notifications.hooks");
    const inputs = () => Array.from(row().querySelectorAll(".set-kv-row input"));
    assert.deepEqual(
      inputs().map((i) => i.value),
      ["a", '"1"', "b", "true"],
    );
    row().querySelector(".set-kv > button").click();
    const [, , , , k, v] = inputs();
    k.value = "ü-ключ";
    v.value = "plain text";
    v.dispatchEvent(new window.Event("change", { bubbles: true }));
    await flush();
    assert.deepEqual(store.wmux["notifications.hooks"], { a: "1", b: true, "ü-ключ": "plain text" });
    const dup = inputs()[4];
    dup.value = "a";
    dup.dispatchEvent(new window.Event("change", { bubbles: true }));
    assert.equal(errorText("notifications.hooks"), "Duplicate key “a”.");
    row().querySelector(".set-kv-row .set-icon").click();
    await flush();
    assert.deepEqual(Object.keys(store.wmux["notifications.hooks"]), ["b", "ü-ключ"]);
  });

  test("unit: persistence-settings-window: nested objects fall back to a JSON editor", async () => {
    const { app, store } = await startSettings({
      store: createStore({ wmux: { "notifications.hooks": { h: { command: "x" } } } }),
    });
    app.navigate("automation");
    const area = rowEl("notifications.hooks").querySelector("textarea");
    assert.equal(area.hidden, false);
    assert.deepEqual(JSON.parse(area.value), { h: { command: "x" } });
    edit(area, "{bad json");
    assert.match(errorText("notifications.hooks"), /^Invalid JSON: /);
    edit(area, '{"h": {"command": "y", "timeoutSeconds": 5}}');
    await flush();
    assert.deepEqual(store.wmux["notifications.hooks"], { h: { command: "y", timeoutSeconds: 5 } });
  });

  test("unit: persistence-settings-window: strokes control records a hotkey with key capture", async () => {
    const { app, store } = await startSettings();
    app.navigate("globalHotkey");
    const row = rowEl("wmux.quickTerminal.hotkey");
    assert.equal(row.querySelector("input").value, "ctrl+`");
    row.querySelector(".set-strokes button").click();
    assert.deepEqual(host.calls("panel.key_capture").at(-1).params, { on: true });
    keydown({ key: "Control", code: "ControlLeft", ctrlKey: true });
    keydown({ key: "Q", code: "KeyQ", keyCode: 81, ctrlKey: true, shiftKey: true });
    await flush();
    assert.equal(store.wmux["wmux.quickTerminal.hotkey"], "ctrl+shift+q");
    assert.deepEqual(host.calls("panel.key_capture").at(-1).params, { on: false });
    edit(rowEl("wmux.quickTerminal.hotkey").querySelector("input"), "ctrl+b  c");
    await flush();
    assert.deepEqual(store.wmux["wmux.quickTerminal.hotkey"], ["ctrl+b", "c"]);
    edit(rowEl("wmux.quickTerminal.hotkey").querySelector("input"), "cmd+k");
    assert.equal(errorText("wmux.quickTerminal.hotkey"), "Not a valid shortcut.");
  });

  test("unit: persistence-settings-window: the hotkey recorder stops on outside clicks and re-renders", async () => {
    const { app, store } = await startSettings();
    app.navigate("globalHotkey");
    const button = () => rowEl("wmux.quickTerminal.hotkey").querySelector(".set-strokes button");
    button().click();
    assert.equal(button().textContent, "Listening…");
    $("#set-search").dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true }));
    assert.equal(button().textContent, "Press shortcut…");
    assert.equal(button().hasAttribute("aria-pressed"), false);
    assert.deepEqual(host.calls("panel.key_capture").at(-1).params, { on: false });
    const typed = keydown({ key: "s", code: "KeyS", keyCode: 83 }, $("#set-search"));
    assert.equal(typed.defaultPrevented, false, "typing reaches the search field");
    await flush();
    assert.equal(host.calls("wmux.settings.set").length, 0);
    // A deep link while listening (`wmux settings terminal`) re-renders: the recorder ends.
    button().click();
    assert.deepEqual(host.calls("panel.key_capture").at(-1).params, { on: true });
    host.emit("wmux.settings.navigate", { target: "terminal" });
    assert.deepEqual(host.calls("panel.key_capture").at(-1).params, { on: false });
    assert.equal(keydown({ key: "s", code: "KeyS", keyCode: 83 }, doc.body).defaultPrevented, false);
    await flush();
    assert.equal(host.calls("wmux.settings.set").length, 0);
    assert.equal(store.wmux["wmux.quickTerminal.hotkey"], undefined);
  });
});

describe("unit: persistence-settings-reset-all: Reset All", () => {
  test("unit: persistence-settings-reset-all: cancel keeps values; confirm resets wmux.json but cmux.json stays", async () => {
    const store = createStore({ wmux: { "terminal.scrollSpeed": 2 }, cmux: { "sidebar.showPorts": false } });
    const { app } = await startSettings({ store });
    app.navigate("reset");
    $("#set-reset-all").click();
    assert.equal($("#set-confirm").hidden, false);
    assert.equal(doc.activeElement, $("#set-confirm-cancel"));
    assert.equal($("#set-confirm-ok").textContent, "Reset All");
    keydown({ key: "Escape" });
    await flush();
    assert.equal($("#set-confirm").hidden, true);
    assert.equal(host.calls("wmux.settings.reset_all").length, 0);
    $("#set-reset-all").click();
    $("#set-confirm-ok").click();
    await flush();
    assert.equal(host.calls("wmux.settings.reset_all").length, 1);
    assert.equal($("#set-status").textContent, "Settings were reset to their defaults.");
    assert.equal(app.state.effective.get("terminal.scrollSpeed").source, "default");
    assert.equal(app.state.effective.get("sidebar.showPorts").source, "cmux.json");
  });

  test("unit: persistence-settings-reset-all: falls back to per-key unset when reset_all is missing", async () => {
    const store = createStore({
      wmux: { "terminal.scrollSpeed": 2, "sidebar.showPorts": false },
      policy: { "fileEditor.wordWrap": false },
    });
    const { app } = await startSettings({ store });
    host.handlers.delete("wmux.settings.reset_all");
    const done = app.resetAll();
    await flush(1);
    keydown({ key: "Tab" }, $("#set-confirm-cancel"));
    assert.equal(doc.activeElement, $("#set-confirm-ok"));
    $("#set-confirm-ok").click();
    assert.equal(await done, true);
    assert.deepEqual(
      host
        .calls("wmux.settings.unset")
        .map((m) => m.params.path)
        .sort(),
      ["sidebar.showPorts", "terminal.scrollSpeed"],
    );
    assert.deepEqual(store.wmux, {});
  });

  test("unit: persistence-settings-reset-all: a failing reset reports the error", async () => {
    const { app } = await startSettings({
      handlers: {
        "wmux.settings.reset_all": () => {
          throw hostError("io_error", "file is locked");
        },
      },
    });
    const done = app.resetAll();
    await flush(1);
    $("#set-confirm-ok").click();
    assert.equal(await done, false);
    assert.equal($("#set-status").textContent, "Could not reset settings: file is locked");
  });
});

describe("unit: persistence-settings-window: settings JSON section", () => {
  test("unit: persistence-settings-window: Open, Open cmux.json and Open Docs call native", async () => {
    await startSettings({ init: { params: { target: "json" } } });
    assert.equal($(".set-file-path").textContent, "C:\\Users\\me\\.config\\wmux\\wmux.json");
    $("#set-open-json").click();
    $("#set-open-cmux").click();
    $("#set-open-docs").click();
    await flush();
    assert.deepEqual(
      host.calls("wmux.settings.open_file").map((m) => m.params.file),
      ["wmux", "cmux"],
    );
    assert.deepEqual(
      host.calls("wmux.settings.open_docs").map((m) => m.params.topic),
      ["settings"],
    );
    host.handlers.set("wmux.settings.open_file", () => {
      throw hostError("not_found", "missing");
    });
    $("#set-open-json").click();
    await flush();
    assert.equal($("#set-status").textContent, "Could not open the file: missing");
  });
});
