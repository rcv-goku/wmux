// Themes section: gallery with swatches, search, dark/light split, summary,
// picking, Revert and Open in Terminal, plus the schema rows of the section.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { $, $$, createStore, flush, host, hostError, rowEl, startSettings, window } from "./helpers.mjs";

const THEMES = [
  {
    name: "Nord",
    background: "#2e3440",
    foreground: "#d8dee9",
    palette: ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0", "#4c566a"],
  },
  { name: "Dracula", scheme: "dark", background: "#282a36", foreground: "#f8f8f2" },
  { name: "Solarized Light", background: "#fdf6e3", foreground: "#657b83" },
  { name: "GitHub Light <img src=x>", background: "#ffffff", foreground: "#24292f" },
];

function themeHandlers(current) {
  const s = { current, sets: [] };
  s.handlers = {
    "wmux.settings.list_themes": () => ({ themes: THEMES, current: s.current }),
    "wmux.settings.set_theme": ({ theme }) => {
      s.sets.push(theme);
      s.current = theme;
      return {};
    },
    "wmux.settings.open_theme_picker": () => ({}),
  };
  return s;
}

async function open(current = "light:Solarized Light,dark:Nord", store) {
  const th = themeHandlers(current);
  const started = await startSettings({ store, handlers: th.handlers, init: { params: { target: "appearance" } } });
  await flush();
  return { ...started, th };
}

const names = (scheme) =>
  $$(`.set-theme-group:nth-of-type(${scheme === "dark" ? 1 : 2}) .set-theme-name`).map((n) => n.textContent);
const pressed = () =>
  $$(".set-theme[aria-pressed='true']")
    .map((b) => b.dataset.theme)
    .sort();

describe("unit: persistence-settings-themes-section: gallery", () => {
  test("unit: persistence-settings-themes-section: dark and light lists with swatches and a summary", async () => {
    await open();
    assert.equal($(".set-section").dataset.section, "themes");
    assert.deepEqual(
      $$(".set-theme-group h3").map((h) => h.textContent),
      ["Dark Themes", "Light Themes"],
    );
    assert.deepEqual(names("dark"), ["Dracula", "Nord"]);
    assert.deepEqual(names("light"), ["GitHub Light <img src=x>", "Solarized Light"]);
    assert.equal($("img"), null, "theme names are text, never markup");
    assert.equal($("#set-theme-summary").textContent, "Light: Solarized Light · Dark: Nord");
    assert.deepEqual(pressed(), ["Nord", "Solarized Light"]);
    const sw = $(".set-theme[data-theme='Nord'] .set-swatch");
    assert.equal(sw.style.getPropertyValue("background-color"), "rgb(46, 52, 64)");
    assert.equal($$(".set-swatch-chip", sw).length, 8);
    assert.equal($("#set-theme-revert").disabled, true);
  });

  test("unit: persistence-settings-themes-section: search all themes", async () => {
    await open();
    const search = $("#set-theme-search");
    assert.equal(search.placeholder, "Search all themes");
    search.value = "sol";
    search.dispatchEvent(new window.Event("input"));
    assert.deepEqual(names("dark"), []);
    assert.equal($(".set-theme-group .wmux-muted").textContent, "No themes match.");
    assert.deepEqual(names("light"), ["Solarized Light"]);
  });

  test("unit: persistence-settings-themes-section: picking a dark theme writes the pair; Revert restores it", async () => {
    const { th } = await open();
    $(".set-theme[data-theme='Dracula']").click();
    await flush();
    assert.deepEqual(th.sets, ["light:Solarized Light,dark:Dracula"]);
    assert.equal($("#set-theme-summary").textContent, "Light: Solarized Light · Dark: Dracula");
    assert.deepEqual(pressed(), ["Dracula", "Solarized Light"]);
    assert.equal($("#set-theme-revert").disabled, false);
    $("#set-theme-revert").click();
    await flush();
    assert.deepEqual(th.sets, ["light:Solarized Light,dark:Dracula", "light:Solarized Light,dark:Nord"]);
    assert.equal($("#set-theme-revert").disabled, true);
  });

  test("unit: persistence-settings-themes-section: picking and Revert keep keyboard focus in the gallery", async () => {
    await open();
    const doc = window.document;
    const button = (name) => $$(".set-theme").find((b) => b.dataset.theme === name);
    button("Dracula").focus();
    button("Dracula").click();
    await flush();
    assert.equal(button("Dracula").getAttribute("aria-pressed"), "true");
    assert.equal(doc.activeElement, button("Dracula"), "the repainted theme button keeps focus");
    $("#set-theme-revert").focus();
    $("#set-theme-revert").click();
    await flush();
    assert.equal($("#set-theme-revert").disabled, true);
    assert.equal(doc.activeElement, $("#set-theme-open"), "Revert disables itself; focus stays in the header");
  });

  test("unit: persistence-settings-themes-section: Ghostty default colors, then a first pick sets both halves", async () => {
    const { th } = await open(null);
    assert.equal($("#set-theme-summary").textContent, "Ghostty default colors");
    $(".set-theme[data-theme='Nord']").click();
    await flush();
    assert.deepEqual(th.sets, ["Nord"]);
    $("#set-theme-revert").click();
    await flush();
    assert.deepEqual(th.sets, ["Nord", null]);
  });

  test("unit: persistence-settings-themes-section: a failed write rolls back and reports", async () => {
    const { th } = await open();
    th.handlers["wmux.settings.set_theme"] = null;
    host.handlers.set("wmux.settings.set_theme", () => {
      throw hostError("io_error", "read-only overlay");
    });
    $(".set-theme[data-theme='Dracula']").click();
    await flush();
    assert.equal($("#set-theme-summary").textContent, "Light: Solarized Light · Dark: Nord");
    assert.equal($("#set-status").textContent, "Could not apply the theme: read-only overlay");
  });

  test("unit: persistence-settings-themes-section: Open in Terminal and unavailable lists", async () => {
    await open();
    $("#set-theme-open").click();
    await flush();
    assert.equal(host.calls("wmux.settings.open_theme_picker").length, 1);
    await startSettings({ init: { params: { target: "themes" } } });
    await flush();
    assert.equal($(".set-themes .set-row-error").textContent, "Themes are not available: Unknown method");
  });

  test("unit: persistence-settings-themes-section: section schema rows render next to the gallery", async () => {
    const store = createStore();
    store.schema.properties.terminal.properties.adaptiveDefaultTheme = {
      title: "Adapt Default Theme to Appearance",
      type: "boolean",
      default: true,
      "x-wmux-section": "themes",
    };
    await open(null, store);
    assert.ok(rowEl("terminal.adaptiveDefaultTheme"));
  });
});
