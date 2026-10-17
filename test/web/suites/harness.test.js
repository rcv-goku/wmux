// Self-tests of the harness: lib/assert.js and mock-host.js in a real browser.
import { createMockHost, reply, MockHostError } from "../mock-host.js";
import {
  test, run, assertEqual, assertDeepEqual, assertMatch, assertTrue, assertThrows, assertRejects,
  waitFor, sleep, captureErrors, asciiJson, AssertionError, show,
} from "../lib/assert.js";
import { loadFrame, loadApp, isVisible, metaCsp } from "../lib/harness.js";

test("harness: assertEqual uses Object.is", () => {
  assertEqual(NaN, NaN);
  assertThrows(() => assertEqual(0, -0), AssertionError);
  assertThrows(() => assertEqual("1", 1), /expected 1, got "1"/);
});

test("harness: assertDeepEqual compares structure across realms", async () => {
  const page = await loadFrame(null);
  const foreign = page.window.JSON.parse('{"a":[1,{"b":"ü"}],"c":null}');
  assertDeepEqual(foreign, { a: [1, { b: "ü" }], c: null });
  assertDeepEqual({ a: 1, u: undefined }, { a: 1 }, "undefined members are ignored");
  assertDeepEqual(new Map([["k", [1]]]), new Map([["k", [1]]]));
  assertDeepEqual(new Set([1, 2]), new Set([1, 2]));
  assertDeepEqual(new Date(5), new Date(5));
  const cyc = { n: 1 };
  cyc.self = cyc;
  const cyc2 = { n: 1 };
  cyc2.self = cyc2;
  assertDeepEqual(cyc, cyc2);
  const err = assertThrows(() => assertDeepEqual({ a: [1, 2] }, { a: [1, 3] }));
  assertEqual(err.path, "$.a[1]");
  assertThrows(() => assertDeepEqual({ a: 1 }, { a: 1, b: 2 }), /\$\.b \(missing\)/);
  assertThrows(() => assertDeepEqual([1], { 0: 1 }));
  page.remove();
});

test("harness: assertMatch, assertThrows and assertRejects", async () => {
  assertMatch("hello world", /wor/);
  assertMatch("hello world", "lo w");
  assertMatch("abc", /b/g);
  assertThrows(() => assertMatch(42, /4/), AssertionError);
  assertThrows(() => assertThrows(() => {}), /none was thrown/);
  const e = assertThrows(() => { throw new RangeError("r"); }, RangeError);
  assertEqual(e.message, "r");
  assertThrows(() => assertThrows(() => { throw new TypeError("t"); }, RangeError), /expected RangeError/);
  const coded = Object.assign(new Error("m"), { code: "x", data: { n: 1 } });
  assertThrows(() => { throw coded; }, { code: "x", data: { n: 1 } });
  assertThrows(() => { throw coded; }, (err) => err.code === "x");
  await assertThrows(async () => { throw new Error("async"); }, /async/);
  await assertRejects(Promise.reject(new Error("p")), /p/);
  await assertRejects(() => Promise.reject(new Error("f")), /f/);
  await assertRejects(assertRejects(Promise.resolve(1)), /promise resolved/);
});

test("harness: waitFor returns the value and times out with a message", async () => {
  let n = 0;
  assertEqual(await waitFor(() => (++n >= 3 ? "ready" : null), { intervalMs: 5 }), "ready");
  const err = await assertRejects(waitFor(() => false, { timeoutMs: 50, message: "never true" }), AssertionError);
  assertMatch(err.message, "never true");
  const err2 = await assertRejects(waitFor(() => { throw new Error("inner"); }, { timeoutMs: 30 }));
  assertMatch(err2.message, "last error: Error: inner");
});

test("harness: captureErrors collects frame errors, rejections and CSP violations", async () => {
  const page = await loadFrame(createMockHost());
  const errors = await captureErrors(async () => {
    page.window.reportError(new page.window.Error("frame boom")); // reported to the frame global
    page.window.Promise.reject(new page.window.Error("frame rejection"));
    const img = page.document.createElement("img");
    img.src = "https://example.org/blocked.png";
    page.document.body.append(img);
    assertThrows(() => { page.document.body.innerHTML = "<i>x</i>"; }, (err) => err.name === "TypeError");
    await sleep(50);
  });
  const kinds = errors.map((e) => e.kind + ":" + (e.effectiveDirective || ""));
  assertTrue(kinds.includes("error:"), "uncaught error recorded: " + kinds);
  assertTrue(kinds.includes("unhandledrejection:"), "rejection recorded: " + kinds);
  assertTrue(kinds.includes("securitypolicyviolation:img-src"), "img-src violation recorded: " + kinds);
  assertTrue(kinds.includes("securitypolicyviolation:require-trusted-types-for"), "Trusted Types violation recorded: " + kinds);
  assertTrue(errors.every((e) => e.window === "frame"), "records name the frame: " + JSON.stringify(errors.map((e) => [e.window, e.kind, e.effectiveDirective])));
  page.remove();
});

test("harness: results JSON is ASCII-only and HTML-safe", () => {
  const text = asciiJson({ s: "<pre>&</pre> ü 👋  " });
  assertTrue(/^[\x20-\x7e\n]*$/.test(text), "ASCII only");
  assertTrue(!/[<>&]/.test(text), "no markup characters");
  assertDeepEqual(JSON.parse(text), { s: "<pre>&</pre> ü 👋  " });
  assertEqual(show("x".repeat(400)).length, 300);
});

test("harness: mock host scripts once-replies, functions, thrown errors and latency", async () => {
  const host = createMockHost({ latencyMs: 30 });
  host.respond("m", (params) => ({ got: params.v }));
  host.respondOnce("m", reply.error("busy", "try again"));
  host.respond("thrower", () => { throw new MockHostError("not_found", "nothing", { data: { id: 1 } }); });
  host.respond("generic", () => { throw new Error("oops"); });
  host.respond("fn-result", reply.ok(() => 1));
  const page = await loadFrame(host);
  const { wmux } = await page.import("../../../src/web/_shared/wmux-bridge.js");
  const begin = Date.now();
  await assertRejects(wmux.call("m", { v: 1 }), { code: "busy" });
  assertTrue(Date.now() - begin >= 25, "latency applied");
  assertDeepEqual(await wmux.call("m", { v: 2 }), { got: 2 });
  const err = await assertRejects(wmux.call("thrower"), { code: "not_found", message: "nothing" });
  assertDeepEqual(err.data, { id: 1 });
  await assertRejects(wmux.call("generic"), { code: "internal_error", message: "oops" });
  assertEqual(await wmux.call("fn-result"), null, "functions do not survive JSON");
  await assertRejects(wmux.call("unknown.method"), { code: "method_not_found" });
  host.unrespond("m");
  await assertRejects(wmux.call("m"), { code: "method_not_found" });
  assertEqual(host.listenerCount, 1, "the bridge registered one listener");
  page.remove();
});

test("harness: waitForCall sees past and future calls and times out", async () => {
  const host = createMockHost({ unhandled: "never" });
  const page = await loadFrame(host);
  const { wmux } = await page.import("../../../src/web/_shared/wmux-bridge.js");
  wmux.send("first.call", { n: 1 });
  assertEqual((await host.waitForCall("first.call")).params.n, 1, "already recorded");
  const later = host.waitForCall((r) => r.method === "second.call" && r.params.n === 2);
  setTimeout(() => wmux.send("second.call", { n: 2 }), 20);
  assertEqual((await later).method, "second.call");
  await assertRejects(host.waitForCall("never.called", { timeoutMs: 30 }), /no call to "never.called"/);
  const seq = host.lastCall("first.call").seq;
  wmux.send("first.call", { n: 3 });
  assertEqual((await host.waitForCall("first.call", { after: seq })).params.n, 3, "after filters older calls");
  host.clearCalls();
  assertEqual(host.calls.length, 0);
  page.remove();
});

test("harness: loadApp reports layout and the app's meta CSP", async () => {
  const page = await loadApp("about", createMockHost({ responses: { "panel.about.info": { version: "9" }, "panel.set_title": null } }));
  await waitFor(() => page.$("#about-version").textContent === "Version 9");
  assertTrue(isVisible(page.$("#about-version")), "visible");
  assertTrue(!isVisible(page.$("#about-license-text")), "hidden region is not visible");
  assertMatch(metaCsp(page.document), "trusted-types 'none'");
  page.remove();
});

run({ suite: "harness" });
