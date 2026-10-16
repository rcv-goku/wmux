/**
 * Themes section: terminal theme gallery (DOM). Lists themes from
 * `wmux.settings.list_themes`, writes with `wmux.settings.set_theme`, offers
 * Revert (to the value when the gallery was first loaded) and
 * "Open in Terminal…" (`wmux.settings.open_theme_picker`, runs `wmux themes`
 * in a new tab). The other Themes rows (app.appearance, app.accentColor,
 * terminal.adaptiveDefaultTheme, browser.theme) are schema rows.
 */
import { el } from "./controls.js";
import { formatThemeValue, groupThemes, normalizeThemes, selectTheme, themeSummary } from "./themes.js";
import { t } from "./strings.js";

const MAX_RENDERED = 2000;

function message(err) {
  return err && typeof err.message === "string" && err.message ? err.message : String(err);
}

export function createThemesView({ document: doc, call, setStatus }) {
  const model = { loaded: false, loading: null, error: "", themes: [], current: null, original: null, query: "" };
  let root = null;

  async function load() {
    if (model.loading) return model.loading;
    model.loading = (async () => {
      try {
        const data = normalizeThemes(await call("wmux.settings.list_themes", {}));
        model.themes = data.themes;
        model.current = data.current;
        if (!model.loaded) model.original = data.current;
        model.loaded = true;
        model.error = "";
      } catch (err) {
        model.error = message(err);
      } finally {
        model.loading = null;
      }
      paint();
    })();
    return model.loading;
  }

  async function apply(pair) {
    const previous = model.current;
    model.current = pair;
    paint();
    try {
      await call("wmux.settings.set_theme", { theme: formatThemeValue(pair) });
      return true;
    } catch (err) {
      model.current = previous;
      paint();
      setStatus(t("settings.themes.failed", { message: message(err) }), "error");
      return false;
    }
  }

  function pick(theme) {
    return apply(selectTheme(model.current, theme, model.themes));
  }

  function revert() {
    return apply(model.original);
  }

  function swatch(theme) {
    const box = el(doc, "span", { class: "set-swatch", "aria-hidden": "true" });
    box.style.setProperty("background-color", theme.background);
    box.style.setProperty("color", theme.foreground);
    box.append(el(doc, "span", { class: "set-swatch-text", text: "Aa" }));
    const chips = el(doc, "span", { class: "set-swatch-chips" });
    for (const color of theme.palette.slice(0, 8)) {
      const chip = el(doc, "span", { class: "set-swatch-chip" });
      chip.style.setProperty("background-color", color);
      chips.append(chip);
    }
    box.append(chips);
    return box;
  }

  function group(title, list) {
    const wrap = el(doc, "div", { class: "set-theme-group" });
    wrap.append(el(doc, "h3", { class: "set-subheading", text: title }));
    if (list.length === 0) {
      wrap.append(el(doc, "p", { class: "wmux-muted", text: t("settings.themes.none") }));
      return wrap;
    }
    const grid = el(doc, "ul", { class: "set-theme-grid" });
    for (const theme of list.slice(0, MAX_RENDERED)) {
      const half = theme.scheme === "dark" ? "dark" : "light";
      const selected = Boolean(model.current && model.current[half] === theme.name);
      const button = el(doc, "button", {
        type: "button",
        class: "set-theme",
        "data-theme": theme.name,
        "aria-pressed": selected ? "true" : "false",
      });
      button.append(swatch(theme), el(doc, "span", { class: "set-theme-name", text: theme.name }));
      button.addEventListener("click", () => pick(theme));
      grid.append(el(doc, "li", null, [button]));
    }
    wrap.append(grid);
    return wrap;
  }

  function paint() {
    if (!root) return;
    root.replaceChildren();
    const head = el(doc, "div", { class: "set-theme-head" });
    head.append(el(doc, "h2", { class: "set-subheading", text: t("settings.themes.title") }));
    const summary = el(doc, "p", {
      class: "set-theme-summary",
      id: "set-theme-summary",
      role: "status",
      text: themeSummary(model.current),
    });
    const actions = el(doc, "div", { class: "set-actions" });
    const revertBtn = el(doc, "button", { type: "button", id: "set-theme-revert", text: t("settings.themes.revert") });
    revertBtn.disabled = JSON.stringify(model.current) === JSON.stringify(model.original);
    revertBtn.addEventListener("click", () => revert());
    const open = el(doc, "button", { type: "button", id: "set-theme-open", text: t("settings.themes.openTerminal") });
    open.addEventListener("click", () => {
      call("wmux.settings.open_theme_picker", {}).catch((err) =>
        setStatus(t("settings.themes.failed", { message: message(err) }), "error"),
      );
    });
    actions.append(revertBtn, open);
    head.append(summary, actions);
    root.append(head);
    if (model.error) {
      root.append(
        el(doc, "p", {
          class: "set-row-error",
          role: "alert",
          text: t("settings.themes.unavailable", { message: model.error }),
        }),
      );
      return;
    }
    if (!model.loaded) {
      root.append(el(doc, "p", { class: "wmux-muted", text: t("settings.loading") }));
      return;
    }
    const search = el(doc, "input", {
      type: "search",
      id: "set-theme-search",
      class: "set-input",
      placeholder: t("settings.themes.search"),
      "aria-label": t("settings.themes.search"),
      autocomplete: "off",
      spellcheck: "false",
    });
    search.value = model.query;
    const lists = el(doc, "div", { class: "set-theme-lists" });
    const fill = () => {
      const g = groupThemes(model.themes, model.query);
      lists.replaceChildren(group(t("settings.themes.dark"), g.dark), group(t("settings.themes.light"), g.light));
    };
    search.addEventListener("input", () => {
      model.query = search.value.slice(0, 256);
      fill();
    });
    fill();
    root.append(search, lists);
  }

  return {
    model,
    render() {
      root = el(doc, "div", { class: "set-themes" });
      paint();
      if (!model.loaded && !model.loading) load();
      return root;
    },
    reload: load,
    pick,
    revert,
  };
}
