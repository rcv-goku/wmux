// Settings panel pure logic: schema flattening, validation, search, sources,
// section targets, shortcut validation and the theme gallery.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { committedSchema, goldenSchema, importWeb } from "./helpers.mjs";

const schemaMod = await importWeb("settings/schema.js");
const { flattenSchema, validateValue, parseInput, formatInput, deepEqual, humanize, kindOf } = schemaMod;
const { queryTokens, fieldHaystack, matchesTokens, highlightRanges } = schemaMod;
const { normalizeEffective, rowState, normalizeSource } = await importWeb("settings/effective.js");
const { resolveTarget, SECTION_IDS, sectionTitle } = await importWeb("settings/sections.js");

const byPath = (fields) => new Map(fields.map((f) => [f.path, f]));

describe("unit: settings-schema: flatten", () => {
  test("unit: settings-schema: committed schema has only file meta keys and yields no rows", () => {
    assert.deepEqual(flattenSchema(committedSchema()), []);
  });

  test("unit: settings-schema: golden schema yields one typed field per leaf", () => {
    const fields = byPath(flattenSchema(goldenSchema()));
    const kinds = Object.fromEntries([...fields].map(([p, f]) => [p, f.kind]));
    assert.deepEqual(kinds, {
      activePaneBorderColor: "color",
      "app.appearance": "enum",
      "automation.autoNamingAgent": "string",
      "automation.claudeBinaryPath": "path",
      "automation.socketControlMode": "enum",
      "browser.urlAllowlist": "list",
      "fileEditor.wordWrap": "bool",
      "notifications.hooks": "object",
      "sidebar.showPorts": "bool",
      "terminal.copyOnSelect": "bool",
      "terminal.scrollSpeed": "number",
      "wmux.quickTerminal.hotkey": "strokes",
      "wmux.sidebar.width": "integer",
    });
  });

  test("unit: settings-schema: hints are carried into fields", () => {
    const f = byPath(flattenSchema(goldenSchema()));
    assert.equal(f.get("automation.socketControlMode").apply, "restart");
    assert.equal(f.get("automation.claudeBinaryPath").policyLockable, false);
    assert.deepEqual(f.get("notifications.hooks").scopes, ["global", "project"]);
    assert.deepEqual(f.get("sidebar.showPorts").keywords, ["ports"]);
    assert.equal(f.get("terminal.copyOnSelect").ghosttyOverride, "copy-on-select");
    assert.equal(f.get("wmux.sidebar.width").min, 120);
    assert.equal(f.get("wmux.sidebar.width").step, 1);
    assert.equal(f.get("terminal.scrollSpeed").max, 3);
    assert.equal(f.get("app.appearance").title, "Theme");
    assert.equal(f.get("wmux.quickTerminal.hotkey").default, "ctrl+`");
  });

  test("unit: settings-schema: fields are ordered by section, then schema order", () => {
    const sections = flattenSchema(goldenSchema()).map((f) => f.section);
    const ranks = sections.map((s) => SECTION_IDS.indexOf(s));
    assert.deepEqual(
      ranks,
      [...ranks].sort((a, b) => a - b),
    );
    assert.equal(sections[0], "app");
    assert.equal(sections[sections.length - 1], "windows");
  });

  test("unit: settings-schema: malformed input never throws", () => {
    for (const bad of [null, undefined, 42, "x", [], {}, { properties: null }, { properties: [] }]) {
      assert.deepEqual(flattenSchema(bad), []);
    }
    const weird = {
      properties: { a: null, "": { type: "string" }, b: { properties: { c: 5, d: { type: "boolean" } } } },
    };
    assert.deepEqual(
      flattenSchema(weird).map((f) => [f.path, f.kind, f.section]),
      [["b.d", "bool", "app"]],
    );
  });

  test("unit: settings-schema: schemas without hints fall back by path, title and kind", () => {
    const fields = flattenSchema({
      properties: {
        terminal: { type: "object", properties: { showScrollBar: { type: "boolean", default: true } } },
        sidebar: {
          properties: { selectionColor: { type: ["string", "null"], pattern: schemaMod.COLOR_PATTERN, default: null } },
        },
        shortcuts: { properties: { bindings: { type: "object", default: {} } } },
        x: {
          properties: {
            mixed: { enum: [true, false, "off"], default: true },
            arr: { type: "array", items: { type: "integer" } },
          },
        },
      },
    });
    const f = byPath(fields);
    assert.equal(f.get("terminal.showScrollBar").section, "terminal");
    assert.equal(f.get("terminal.showScrollBar").title, "Show scroll bar");
    assert.equal(f.get("sidebar.selectionColor").kind, "color");
    assert.equal(f.get("sidebar.selectionColor").nullable, true);
    assert.equal(f.get("shortcuts.bindings").section, "keyboardShortcuts");
    assert.equal(f.get("x.mixed").kind, "enum");
    assert.equal(f.get("x.arr").kind, "json");
  });

  test("unit: settings-schema: deep nesting is bounded", () => {
    let node = { type: "boolean", default: false };
    for (let i = 0; i < 100; i += 1) node = { properties: { n: node } };
    assert.deepEqual(flattenSchema({ properties: { root: node } }), []);
  });

  test("unit: settings-schema: humanize and kindOf edge cases", () => {
    assert.equal(humanize("showURLInTitle"), "Show url in title");
    assert.equal(humanize("hidden-web_view"), "Hidden web view");
    assert.equal(humanize(""), "");
    assert.equal(kindOf({ "x-wmux-kind": "color", type: "string" }), "color");
    assert.equal(kindOf({}), "json");
    assert.equal(kindOf({ type: ["integer", "string"] }), "json");
  });
});

describe("unit: settings-schema: validation", () => {
  const f = byPath(flattenSchema(goldenSchema()));

  test("unit: settings-schema: number ranges and integers", () => {
    const w = f.get("wmux.sidebar.width");
    assert.equal(validateValue(w, 120), null);
    assert.equal(validateValue(w, 600), null);
    assert.equal(validateValue(w, 119), "Must be between 120 and 600.");
    assert.equal(validateValue(w, 601), "Must be between 120 and 600.");
    assert.equal(validateValue(w, 200.5), "Enter a whole number.");
    assert.equal(validateValue(w, Number.NaN), "Enter a number.");
    assert.equal(validateValue(w, "200"), "Enter a number.");
    assert.equal(validateValue(w, null), "A value is required.");
    const s = f.get("terminal.scrollSpeed");
    assert.equal(validateValue(s, 0.1), null);
    assert.equal(validateValue(s, 0.05), "Must be between 0.1 and 3.");
    assert.equal(validateValue(s, Infinity), "Enter a number.");
  });

  test("unit: settings-schema: enums, colors, patterns, lists, objects, strokes", () => {
    assert.equal(validateValue(f.get("app.appearance"), "dark"), null);
    assert.match(validateValue(f.get("app.appearance"), "sepia"), /^Must be one of: system, light, dark\.$/);
    const c = f.get("activePaneBorderColor");
    for (const ok of ["#000000", "#abcdef", "#ABCDEF80"]) assert.equal(validateValue(c, ok), null);
    for (const bad of ["#abc", "abcdef", "#ggg000", "#1234567", ""])
      assert.equal(validateValue(c, bad), "Use #RRGGBB or #RRGGBBAA.");
    const slug = f.get("automation.autoNamingAgent");
    assert.equal(validateValue(slug, "claude-code"), null);
    assert.match(validateValue(slug, "Claude Code"), /expected format/);
    assert.match(validateValue(slug, "日本"), /expected format/);
    assert.equal(validateValue(f.get("browser.urlAllowlist"), ["a.com", "*.b.com"]), null);
    assert.equal(validateValue(f.get("browser.urlAllowlist"), ["a", 1]), "Must be a list of text entries.");
    assert.equal(validateValue(f.get("notifications.hooks"), { a: 1 }), null);
    assert.equal(validateValue(f.get("notifications.hooks"), [1]), "Must be a JSON object.");
    const hk = f.get("wmux.quickTerminal.hotkey");
    assert.equal(validateValue(hk, "ctrl+`"), null);
    assert.equal(validateValue(hk, ["ctrl+b", "c"]), null);
    assert.equal(validateValue(hk, "none"), null);
    assert.equal(validateValue(hk, "cmd+k"), "Not a valid shortcut.");
    assert.equal(validateValue(hk, ["a", "b", "c"]), "Not a valid shortcut.");
  });

  test("unit: settings-schema: parseInput and formatInput round-trip", () => {
    const w = f.get("wmux.sidebar.width");
    assert.deepEqual(parseInput(w, " 250 "), { ok: true, value: 250 });
    assert.equal(parseInput(w, "").ok, false);
    assert.equal(parseInput(w, "1e999").ok, false);
    assert.equal(parseInput(w, "abc").ok, false);
    const list = f.get("browser.urlAllowlist");
    assert.deepEqual(parseInput(list, "a.com\r\n\n  b.com  \r*.ü.de\n"), {
      ok: true,
      value: ["a.com", "b.com", "*.ü.de"],
    });
    assert.equal(formatInput(list, ["x", "y"]), "x\ny");
    const obj = f.get("notifications.hooks");
    assert.deepEqual(parseInput(obj, '{"a": [1]}'), { ok: true, value: { a: [1] } });
    assert.deepEqual(parseInput(obj, "   "), { ok: true, value: {} });
    assert.match(parseInput(obj, "{oops").error, /^Invalid JSON: /);
    const hk = f.get("wmux.quickTerminal.hotkey");
    assert.deepEqual(parseInput(hk, "ctrl+b  c"), { ok: true, value: ["ctrl+b", "c"] });
    assert.equal(formatInput(hk, ["ctrl+b", "c"]), "ctrl+b c");
    assert.equal(formatInput(w, null), "");
  });

  test("unit: settings-schema: deepEqual ignores key order", () => {
    assert.ok(deepEqual({ a: [1, { b: 2 }], c: null }, { c: null, a: [1, { b: 2 }] }));
    assert.ok(!deepEqual([1, 2], [2, 1]));
    assert.ok(!deepEqual({ a: 1 }, { a: 1, b: undefined }));
    assert.ok(!deepEqual(null, {}));
    assert.ok(!deepEqual([], {}));
  });
});

describe("unit: settings-search: matching and highlights", () => {
  const fields = flattenSchema(goldenSchema());
  const hay = (fld) => fieldHaystack(fld, sectionTitle(fld.section), []);

  test("unit: settings-search: tokens match titles, descriptions, keys, keywords and enum values", () => {
    const find = (q) => fields.filter((fld) => matchesTokens(hay(fld), queryTokens(q))).map((fld) => fld.path);
    assert.deepEqual(find("scroll"), ["terminal.scrollSpeed"]);
    assert.deepEqual(find("ports"), ["sidebar.showPorts"]);
    assert.deepEqual(find("readOnly"), ["automation.socketControlMode"]);
    assert.deepEqual(find("COPY select"), ["terminal.copyOnSelect"]);
    assert.deepEqual(find("copy nomatch"), []);
    assert.equal(find("").length, fields.length);
    assert.deepEqual(find("ｓｃｒｏｌｌ"), ["terminal.scrollSpeed"]); // NFKC folds full-width
  });

  test("unit: settings-search: query tokens are capped", () => {
    assert.equal(queryTokens("a ".repeat(100)).length, 16);
    assert.deepEqual(queryTokens("   "), []);
    assert.deepEqual(queryTokens(null), []);
  });

  test("unit: settings-search: highlight ranges merge overlaps", () => {
    assert.deepEqual(highlightRanges("Scroll speed scroll", ["scroll"]), [
      [0, 6],
      [13, 19],
    ]);
    assert.deepEqual(highlightRanges("abcd", ["abc", "bcd"]), [[0, 4]]);
    assert.deepEqual(highlightRanges("abc", []), []);
    assert.deepEqual(highlightRanges("İstanbul", ["stan"]), []); // length-changing case fold: no marks
    assert.ok(highlightRanges("a".repeat(5000), ["a"]).length <= 1000);
  });
});

describe("unit: settings-sources: effective values", () => {
  test("unit: settings-sources: normalizes map and list replies", () => {
    const m = normalizeEffective({
      values: { "a.b": { value: 1, source: "wmux" }, c: { value: true, source: "MDM" }, "": { value: 1 }, bad: 5 },
    });
    assert.deepEqual([...m.keys()], ["a.b", "c"]);
    assert.equal(m.get("a.b").source, "wmux.json");
    assert.equal(m.get("c").locked, true);
    const l = normalizeEffective({ values: [{ path: "x", value: "y", source: "cmux.json" }, { value: 2 }, null] });
    assert.deepEqual([...l.keys()], ["x"]);
    assert.equal(normalizeEffective(null).size, 0);
    assert.equal(normalizeEffective("nope").size, 0);
    assert.equal(normalizeSource("weird"), "default");
  });

  test("unit: settings-sources: row state for each source", () => {
    const field = { default: false, hasDefault: true };
    assert.deepEqual(rowState(field, undefined), {
      value: false,
      source: "default",
      readOnly: false,
      managed: null,
      canReset: false,
      modified: false,
      error: null,
    });
    const w = rowState(field, { value: true, source: "wmux.json", locked: false, error: null });
    assert.equal(w.canReset, true);
    assert.equal(w.modified, true);
    const c = rowState(field, { value: true, source: "cmux.json", locked: false, error: null });
    assert.equal(c.readOnly, true);
    assert.equal(c.managed, "cmux.json");
    assert.equal(
      rowState(field, { value: true, source: "cmux.json", locked: false }, { overridden: true }).readOnly,
      false,
    );
    const p = rowState(field, { value: false, source: "policy", locked: true, error: null }, { overridden: true });
    assert.equal(p.readOnly, true);
    assert.equal(p.managed, "policy");
    assert.equal(p.canReset, false);
    const projectOnly = rowState(
      { default: [], hasDefault: true, scopes: ["project"] },
      { value: [1], source: "wmux.json" },
    );
    assert.equal(projectOnly.managed, "project");
    assert.equal(projectOnly.readOnly, true);
    assert.equal(projectOnly.canReset, false);
    assert.equal(rowState({ default: 1, hasDefault: true, scopes: ["global", "project"] }, undefined).readOnly, false);
  });
});

describe("unit: settings-window: targets", () => {
  test("unit: settings-window: cmux CLI aliases resolve to raw section ids", () => {
    const cases = {
      shortcuts: "keyboardShortcuts",
      keys: "keyboardShortcuts",
      keybindings: "keyboardShortcuts",
      "keyboard-shortcuts": "keyboardShortcuts",
      general: "app",
      appearance: "themes",
      theme: "themes",
      sidebar: "sidebarAppearance",
      hotkey: "globalHotkey",
      "import-browser-data": "browserImport",
      colors: "workspaceColors",
      json: "settingsJSON",
      "cmux-json": "settingsJSON",
      "settings-file": "settingsJSON",
      reset: "reset",
      KEYBOARDSHORTCUTS: "keyboardShortcuts",
      " Terminal ": "terminal",
      textBox: "textBox",
    };
    for (const [target, id] of Object.entries(cases)) assert.equal(resolveTarget(target), id, target);
  });

  test("unit: settings-window: omitted, empty and unknown targets resolve to null", () => {
    for (const target of ["account", "devices", "networking", "", "  ", null, 7, "constructor", "__proto__"]) {
      assert.equal(resolveTarget(target), null, String(target));
    }
  });
});

const sc = await importWeb("settings/shortcuts.js");
const th = await importWeb("settings/themes.js");

const LIST = {
  actions: [
    {
      id: "splitRight",
      title: "Split Right",
      category: "pane",
      keys: ["ctrl+shift+d"],
      default_keys: ["ctrl+shift+d"],
    },
    { id: "newSurface", title: "New Surface", category: "surface", keys: ["ctrl+shift+t"] },
    {
      id: "selectWorkspaceByNumber",
      title: "Select Workspace 1…9",
      category: "workspace",
      keys: ["ctrl+alt+1"],
      numbered: true,
    },
    { id: "browserReload", title: "Reload Page", category: "browser", keys: ["f5", "ctrl+r"], when: "browserFocus" },
    { id: "markdownReload", title: "Reload Markdown", category: "viewer", keys: ["ctrl+r"], when: "markdownFocus" },
    { id: "newTab", title: "New Tab", category: "surface", keys: [["ctrl+b", "c"]], source: "cmux.json" },
    { id: "diffViewerScrollDown", title: "Scroll Down", category: "viewer", keys: "j" },
    { id: "locked", title: "Locked", category: "app", keys: [], source: "policy" },
    { id: "splitRight", title: "Duplicate", category: "pane" },
    { title: "no id" },
    null,
  ],
};

describe("unit: core-shortcuts-settings-ui: list and display", () => {
  test("unit: core-shortcuts-settings-ui: normalizes actions, chords, sources and presets", () => {
    const { actions, presets, preset } = sc.normalizeShortcutList(LIST);
    assert.equal(actions.length, 8);
    assert.deepEqual(
      actions.map((a) => a.category),
      ["app", "workspace", "surface", "surface", "pane", "browser", "viewer", "viewer"],
    );
    const byId = new Map(actions.map((a) => [a.id, a]));
    assert.deepEqual(byId.get("newTab").keys, ["ctrl+b c"]);
    assert.equal(byId.get("newTab").managed, "cmux.json");
    assert.equal(byId.get("locked").locked, true);
    assert.equal(byId.get("diffViewerScrollDown").bareOk, true);
    assert.deepEqual(byId.get("diffViewerScrollDown").keys, ["j"]);
    assert.equal(byId.get("browserReload").whenLabel, "Only while a browser pane is focused");
    assert.equal(byId.get("splitRight").title, "Split Right");
    assert.equal(presets.length, 5);
    assert.equal(preset, null);
    assert.deepEqual(sc.normalizeShortcutList(null).actions, []);
    assert.deepEqual(sc.normalizeShortcutList([{ id: "x", keys: "ctrl+shift+x" }]).actions[0].keys, ["ctrl+shift+x"]);
  });

  test("unit: core-shortcuts-settings-ui: display strings", () => {
    assert.equal(sc.displayStroke("ctrl+shift+pgup"), "Ctrl+Shift+PgUp");
    assert.equal(sc.displayStroke("Shift+Ctrl+A"), "Ctrl+Shift+A");
    assert.equal(sc.displayStroke("f11"), "F11");
    assert.equal(sc.displayStroke("ctrl+alt+["), "Ctrl+Alt+[");
    assert.equal(sc.displayStroke("cmd+k"), "cmd+k");
    assert.equal(sc.displayBinding(["ctrl+b", "c"]), "Ctrl+B C");
    assert.equal(sc.displayBinding("ctrl+b shift+5"), "Ctrl+B Shift+5");
    assert.equal(sc.canonicalBinding("none"), null);
    assert.equal(sc.whenLabel("paneCount > 1"), "When: paneCount > 1");
    assert.equal(sc.whenLabel("terminalFocus", "Custom"), "Custom");
    assert.equal(sc.whenLabel(null), "");
  });

  test("unit: core-shortcuts-settings-ui: keyList drops unbind values and duplicates", () => {
    assert.deepEqual(sc.keyList(["Ctrl+Shift+D", "ctrl+shift+d", "none", "", "weird+thing"]), [
      "ctrl+shift+d",
      "weird+thing",
    ]);
    assert.deepEqual(sc.keyList(null), []);
    assert.deepEqual(sc.keyList("disabled"), []);
  });
});

describe("unit: core-shortcuts-settings-ui: validation", () => {
  const { actions } = sc.normalizeShortcutList(LIST);
  const get = (id) => actions.find((a) => a.id === id);

  test("unit: core-shortcuts-settings-ui: recording Split Right's keys for New Surface is a conflict", () => {
    const v = sc.validateBinding(actions, get("newSurface"), ["ctrl+shift+d"]);
    assert.deepEqual(v.errors, ["This shortcut conflicts with Split Right (Ctrl+Shift+D)"]);
    assert.equal(v.conflicts[0].id, "splitRight");
  });

  test("unit: core-shortcuts-settings-ui: bare keys need a modifier except viewer actions and F-keys", () => {
    assert.deepEqual(sc.validateBinding(actions, get("newSurface"), ["k"]).errors, [
      "Shortcuts must include Ctrl, Alt or Shift",
    ]);
    assert.deepEqual(sc.validateBinding(actions, get("newSurface"), ["enter"]).errors, [
      "Shortcuts must include Ctrl, Alt or Shift",
    ]);
    assert.deepEqual(sc.validateBinding(actions, get("diffViewerScrollDown"), ["k"]).errors, []);
    assert.deepEqual(sc.validateBinding(actions, get("newSurface"), ["f9"]).errors, []);
    assert.deepEqual(sc.validateBinding(actions, get("newSurface"), ["shift+f9"]).errors, []);
  });

  test("unit: core-shortcuts-settings-ui: Shift alone only with keys that type no text (ADR-8.2)", () => {
    for (const s of ["shift+a", "Shift+7", "shift+/", "shift+space"]) {
      assert.deepEqual(
        sc.validateBinding(actions, get("newSurface"), [s]).errors,
        [`${sc.displayStroke(s)} types text; add Ctrl or Alt.`],
        s,
      );
    }
    for (const s of ["shift+f9", "shift+tab", "shift+enter", "shift+pgdn", "ctrl+shift+a", "alt+shift+a"]) {
      assert.deepEqual(sc.validateBinding(actions, get("newSurface"), [s]).errors, [], s);
    }
    assert.deepEqual(sc.validateBinding(actions, get("diffViewerScrollDown"), ["shift+g"]).errors, []);
    // Numbered actions name the key that was pressed, not the stored digit 1.
    assert.deepEqual(sc.validateBinding(actions, get("selectWorkspaceByNumber"), ["shift+7"]).errors, [
      "Shift+7 types text; add Ctrl or Alt.",
    ]);
  });

  test("unit: core-shortcuts-settings-ui: numbered actions need a digit and store digit 1", () => {
    const ok = sc.validateBinding(actions, get("selectWorkspaceByNumber"), ["ctrl+shift+7"]);
    assert.equal(ok.binding, "ctrl+shift+1");
    assert.deepEqual(ok.errors, []);
    assert.deepEqual(sc.validateBinding(actions, get("selectWorkspaceByNumber"), ["ctrl+shift+0"]).errors, [
      "Use a digit from 1 through 9.",
    ]);
    assert.deepEqual(sc.validateBinding(actions, get("selectWorkspaceByNumber"), ["ctrl+shift+k"]).errors, [
      "Use a digit from 1 through 9.",
    ]);
  });

  test("unit: core-shortcuts-settings-ui: Windows-reserved and Windows shortcuts", () => {
    for (const s of ["win+e", "ctrl+win+left", "alt+tab", "ctrl+alt+delete", "ctrl+shift+escape", "ctrl+escape"]) {
      assert.ok(
        sc.validateBinding(actions, get("newSurface"), [s]).errors.includes("This keystroke is reserved by Windows."),
        s,
      );
    }
    const w = sc.validateBinding(actions, get("newSurface"), ["alt+space"]);
    assert.deepEqual(w.errors, []);
    assert.deepEqual(w.warnings, [
      "Alt+Space is also a Windows shortcut (Window menu). Windows may handle it before wmux.",
    ]);
  });

  test("unit: core-shortcuts-settings-ui: contexts and chord prefixes", () => {
    // ctrl+r is used by browserReload (browserFocus) and markdownReload (markdownFocus): no overlap.
    assert.deepEqual(sc.findConflicts(actions, "markdownReload", "ctrl+r"), []);
    // A global action overlaps every context.
    assert.equal(sc.findConflicts(actions, "newSurface", "ctrl+r").length, 2);
    // ctrl+b alone collides with the ctrl+b c chord prefix.
    assert.deepEqual(
      sc.findConflicts(actions, "newSurface", "ctrl+b").map((c) => c.id),
      ["newTab"],
    );
    assert.ok(sc.bindingsCollide("ctrl+b c", "ctrl+b"));
    assert.ok(!sc.bindingsCollide("ctrl+b c", "ctrl+b x"));
    assert.ok(sc.contextsOverlap("a && b", "a&&b"));
    assert.deepEqual(sc.validateBinding(actions, get("newSurface"), ["nonsense+q"]).errors, ["Not a valid shortcut."]);
    assert.deepEqual(sc.validateBinding(actions, get("newSurface"), []).errors, ["Not a valid shortcut."]);
  });

  test("unit: core-shortcuts-settings-ui: search and detect by keys", () => {
    assert.deepEqual(
      sc.filterActions(actions, "split").map((a) => a.id),
      ["splitRight"],
    );
    assert.deepEqual(
      sc.filterActions(actions, "Ctrl+Shift+D").map((a) => a.id),
      ["splitRight"],
    );
    assert.deepEqual(
      sc.filterActions(actions, "browser pane").map((a) => a.id),
      ["browserReload"],
    );
    assert.equal(sc.filterActions(actions, "").length, actions.length);
    assert.deepEqual(sc.filterActions(actions, "zzz"), []);
    assert.deepEqual(
      sc.actionsUsingStroke(actions, "ctrl+r").map((a) => a.id),
      ["browserReload", "markdownReload"],
    );
    assert.deepEqual(
      sc.actionsUsingStroke(actions, "ctrl+b").map((a) => a.id),
      ["newTab"],
    );
    assert.deepEqual(sc.actionsUsingStroke(actions, "bogus+x"), []);
    assert.ok(!sc.isCustomized(get("splitRight")));
  });
});

describe("unit: persistence-settings-themes-section: gallery", () => {
  const data = th.normalizeThemes({
    themes: [
      { name: "Nord", background: "#2e3440", foreground: "#d8dee9", palette: ["#3b4252", "nope"] },
      { name: "Solarized Light", background: "#fdf6e3", foreground: "#657b83" },
      { name: "Forced", scheme: "light", background: "#000" },
      { name: "Nord", background: "#fff" },
      { name: "bad,name" },
      { name: "  " },
      { name: "東京 Night", background: "rgb(26, 27, 38)", foreground: "#c0caf5" },
      null,
    ],
    current: "light:Solarized Light,dark:Nord",
  });

  test("unit: persistence-settings-themes-section: normalizes and splits by scheme", () => {
    assert.deepEqual(
      data.themes.map((x) => x.name),
      ["Forced", "Nord", "Solarized Light", "東京 Night"],
    );
    assert.deepEqual(data.current, { light: "Solarized Light", dark: "Nord" });
    const nord = data.themes.find((x) => x.name === "Nord");
    assert.equal(nord.scheme, "dark");
    assert.deepEqual(nord.palette, ["#3b4252", "#d8dee9"]);
    const g = th.groupThemes(data.themes, "");
    assert.deepEqual(
      g.dark.map((x) => x.name),
      ["Nord", "東京 Night"],
    );
    assert.deepEqual(
      g.light.map((x) => x.name),
      ["Forced", "Solarized Light"],
    );
    assert.deepEqual(
      th.groupThemes(data.themes, "東京").dark.map((x) => x.name),
      ["東京 Night"],
    );
    assert.deepEqual(th.groupThemes(data.themes, "zzz"), { dark: [], light: [] });
  });

  test("unit: persistence-settings-themes-section: theme values parse and format", () => {
    assert.deepEqual(th.parseThemeValue("Nord"), { light: "Nord", dark: "Nord" });
    assert.deepEqual(th.parseThemeValue("dark:Nord"), { light: "Nord", dark: "Nord" });
    assert.deepEqual(th.parseThemeValue(" light: A , dark: B "), { light: "A", dark: "B" });
    assert.deepEqual(th.parseThemeValue({ light: "A" }), { light: "A", dark: "A" });
    for (const v of [null, "", "light:,dark:", {}, 5, "x".repeat(300)]) assert.equal(th.parseThemeValue(v), null);
    assert.equal(th.formatThemeValue({ light: "A", dark: "B" }), "light:A,dark:B");
    assert.equal(th.formatThemeValue({ light: "A", dark: "A" }), "A");
    assert.equal(th.formatThemeValue(null), null);
    assert.equal(th.themeSummary({ light: "A", dark: "B" }), "Light: A · Dark: B");
    assert.equal(th.themeSummary(null), "Ghostty default colors");
  });

  test("unit: persistence-settings-themes-section: picking replaces the half of its scheme", () => {
    const nord = data.themes.find((x) => x.name === "Nord");
    const sol = data.themes.find((x) => x.name === "Solarized Light");
    const tokyo = data.themes.find((x) => x.name === "東京 Night");
    assert.deepEqual(th.selectTheme(null, nord, data.themes), { light: "Nord", dark: "Nord" });
    assert.deepEqual(th.selectTheme({ light: "Nord", dark: "Nord" }, sol, data.themes), {
      light: "Solarized Light",
      dark: "Nord",
    });
    assert.deepEqual(th.selectTheme({ light: "Nord", dark: "Nord" }, tokyo, data.themes), {
      light: "東京 Night",
      dark: "東京 Night",
    });
    assert.deepEqual(th.selectTheme(data.current, tokyo, data.themes), {
      light: "Solarized Light",
      dark: "東京 Night",
    });
    assert.deepEqual(th.selectTheme(data.current, null, data.themes), data.current);
  });
});
