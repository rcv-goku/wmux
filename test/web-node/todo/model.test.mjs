// Todos pane model tests (pure, no DOM): src/web/todo/model.js against the
// native checklist rules in src/apprt/win32/features/todo/logic/checklist.zig.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const web = path.resolve(here, "../../../src/web");
const m = await import(pathToFileURL(path.join(web, "todo/model.js")).href);

const it = (id, state = "pending", extra = {}) => ({
  id,
  text: id,
  state,
  origin: "user",
  attachments: [],
  ...extra,
});

describe("unit: todo model", () => {
  test("unit: todo: text is trimmed, capped at 500 code points, empty rejected", () => {
    assert.deepEqual(m.normalizeText("  \t write test \r\n"), { ok: true, text: "write test" });
    assert.deepEqual(m.normalizeText(""), { ok: false, error: "empty" });
    assert.deepEqual(m.normalizeText(" \n\t "), { ok: false, error: "empty" });
    assert.deepEqual(m.normalizeText("\u3000\u00a0\ufeff"), { ok: false, error: "empty" });
    assert.equal(m.normalizeText("x".repeat(600)).text.length, 500);
    assert.equal(Array.from(m.normalizeText("é".repeat(600)).text).length, 500);
    // Astral code points count once and are never split.
    const rockets = m.normalizeText("🚀".repeat(501)).text;
    assert.equal(Array.from(rockets).length, 500);
    assert.ok(m.isWellFormedText(rockets));
    // Exactly 500 kept whole; truncation exposing whitespace is re-trimmed.
    assert.equal(m.normalizeText("\u2003" + "y".repeat(500) + "\u3000").text.length, 500);
    assert.equal(m.normalizeText("z".repeat(499) + "   tail").text.length, 499);
    assert.equal(m.normalizeText(" 🚀 デプロイ ").text, "🚀 デプロイ");
    // Inner whitespace stays; zero-width space is not whitespace.
    assert.equal(m.normalizeText("\u2028 a\t b \u0085").text, "a\t b");
    assert.equal(m.normalizeText("\u200b").text, "\u200b");
  });

  test("unit: todo: malformed text (lone surrogates, non-strings) is rejected", () => {
    assert.deepEqual(m.normalizeText("a\ud800b"), { ok: false, error: "invalid" });
    assert.deepEqual(m.normalizeText("\udc00"), { ok: false, error: "invalid" });
    assert.deepEqual(m.normalizeText(null), { ok: false, error: "invalid" });
    assert.deepEqual(m.normalizeText(42), { ok: false, error: "invalid" });
    assert.equal(m.isWellFormedText("ok 😀"), true);
  });

  test("unit: todo: list payloads normalize items, states, origins and attachments", () => {
    const list = m.normalizeList({
      items: [
        {
          id: "a",
          text: "one",
          state: "in-progress",
          origin: "agent",
          attachments: [{ id: "x", name: "shot.png" }, "y.png", {}, null],
        },
        { id: "b", text: "two", state: "done", origin: "bot" },
        { id: "a", text: "dup" },
        { id: "", text: "no id" },
        { id: "c" },
        "junk",
        { id: "d", text: "three", state: "completed" },
      ],
      completed: 99,
      total: 99,
    });
    assert.equal(list.total, 3);
    assert.equal(list.completed, 1);
    assert.deepEqual(list.items[0], {
      id: "a",
      text: "one",
      state: "in-progress",
      origin: "agent",
      attachments: [
        { id: "x", name: "shot.png" },
        { id: "y.png", name: "y.png" },
      ],
    });
    assert.equal(list.items[1].state, "pending");
    assert.equal(list.items[1].origin, "user");
    assert.deepEqual(
      m.normalizeList([it("q")]).items.map((x) => x.id),
      ["q"],
    );
    assert.deepEqual(m.normalizeList({ checklist: { items: [] } }), { items: [], completed: 0, total: 0 });
    assert.equal(m.normalizeList({}), null);
    assert.equal(m.normalizeList(null), null);
    assert.equal(m.normalizeList("[]"), null);
  });

  test("unit: todo: display order puts not-completed first, each group in storage order", () => {
    const items = [it("a", "completed"), it("b"), it("c", "in-progress"), it("d", "completed"), it("e")];
    assert.deepEqual(m.displayOrder(items), [1, 2, 4, 0, 3]);
    assert.deepEqual(m.displayOrder([]), []);
    assert.equal(m.progressText(m.progress(items)), "2/5");
  });

  test("unit: todo: toggle maps completed to pending and anything else to completed", () => {
    assert.equal(m.toggledState("pending"), "completed");
    assert.equal(m.toggledState("in-progress"), "completed");
    assert.equal(m.toggledState("completed"), "pending");
  });

  test("unit: todo: move clamps to the item's completion group like Checklist.move", () => {
    const items = [it("a"), it("b", "completed"), it("c"), it("d", "completed"), it("e")];
    assert.equal(m.clampMove(items, 4, 0), 0);
    assert.equal(m.clampMove(items, 1, 0), 1);
    assert.equal(m.clampMove(items, 1, 4), 3);
    assert.equal(m.clampMove(items, 0, 100), 4);
    assert.deepEqual(
      m.applyMove(items, 4, 0).map((x) => x.id),
      ["e", "a", "b", "c", "d"],
    );
    assert.deepEqual(
      m.applyMove(items, 0, 2).map((x) => x.id),
      ["b", "c", "a", "d", "e"],
    );
  });

  test("unit: todo: drop targets stay within a group and skip no-op drops", () => {
    const items = [it("1"), it("2"), it("3"), it("x", "completed")];
    assert.equal(m.dropTarget(items, "3", "1", false), 0);
    assert.equal(m.dropTarget(items, "1", "3", true), 2);
    assert.equal(m.dropTarget(items, "1", "3", false), 1);
    assert.equal(m.dropTarget(items, "1", "2", false), null);
    assert.equal(m.dropTarget(items, "1", "1", true), null);
    assert.equal(m.dropTarget(items, "1", "x", false), null);
    assert.equal(m.dropTarget(items, "nope", "1", false), null);
  });

  test("unit: todo: a drop that keeps the shown order is skipped when completed items sit between", () => {
    // Storage 1(p) 2(c) 3(p): the pane shows 1, 3 | 2. Dropping 1 just before
    // 3 (or 3 just after 1) shows the same order; moving would only renumber
    // `todo list` (2 would become item 1).
    const items = [it("1"), it("2", "completed"), it("3")];
    assert.equal(m.dropTarget(items, "1", "3", false), null);
    assert.equal(m.dropTarget(items, "3", "1", true), null);
    // Real reorders across the completed item still go through.
    assert.equal(m.dropTarget(items, "1", "3", true), 2);
    assert.equal(m.dropTarget(items, "3", "1", false), 0);
    // X(c) a(p) Y(c) b(p): a before b and b after a change nothing visible.
    const mixed = [it("X", "completed"), it("a"), it("Y", "completed"), it("b")];
    assert.equal(m.dropTarget(mixed, "a", "b", false), null);
    assert.equal(m.dropTarget(mixed, "b", "a", true), null);
    assert.equal(m.dropTarget(mixed, "Y", "X", true), null);
    const dest = m.dropTarget(mixed, "b", "a", false);
    assert.equal(dest, 1);
    const moved = m.applyMove(mixed, 3, dest);
    assert.deepEqual(
      m.displayOrder(moved).map((i) => moved[i].id),
      ["b", "a", "X", "Y"],
    );
  });

  test("unit: todo: Alt+arrow steps stop at the group boundary", () => {
    const items = [it("a"), it("b", "completed"), it("c")];
    assert.equal(m.stepTarget(items, "c", -1), 0);
    assert.equal(m.stepTarget(items, "a", 1), 2);
    assert.equal(m.stepTarget(items, "c", 1), null);
    assert.equal(m.stepTarget(items, "a", -1), null);
    assert.equal(m.stepTarget(items, "b", -1), null);
    assert.equal(m.stepTarget(items, "zzz", 1), null);
  });

  test("unit: todo: lane label is hidden for the unpinned todo lane", () => {
    assert.equal(m.laneLabel(null), "");
    assert.equal(m.laneLabel({ lane: "todo" }), "");
    assert.equal(m.laneLabel({ lane: "todo", pinned: true }), "todo");
    assert.equal(m.laneLabel({ lane: "in_progress", lane_name: "In Progress" }), "In Progress");
    assert.equal(m.laneLabel({ status: "review" }), "review");
    assert.equal(m.laneLabel({ lane: 3 }), "");
  });

  test("unit: todo: highlight follows the id, else keeps the row position", () => {
    const items = [it("a"), it("b"), it("c")];
    assert.equal(m.keepHighlight(items, "b", 1), "b");
    assert.equal(m.keepHighlight(items, "gone", 1), "b");
    assert.equal(m.keepHighlight(items, "gone", 10), "c");
    assert.equal(m.keepHighlight(items, null, null), null);
    assert.equal(m.keepHighlight([], "a", 0), null);
  });
});
