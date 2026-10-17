/**
 * Tiny test framework for the real-browser harness (test/web/run.ps1).
 *
 *   import { test, assertEqual, waitFor, run } from "../lib/assert.js";
 *   test("bridge: call resolves", async () => { ... });
 *   run({ suite: "bridge" });
 *
 * Tests run sequentially in registration order. When they are done, run()
 * writes machine-readable results into <pre id="wmux-test-results"> (created if
 * missing), which run.ps1 reads from the --dump-dom output:
 *
 *   {"format":"wmux-web-test/1","suite","status":"passed"|"failed","total","passed",
 *    "failed","skipped","durationMs","userAgent","tests":[{"name","status","durationMs","error"?}],
 *    "errors":[{"kind","message",...}]}
 *
 * The JSON is ASCII-only (<, >, & and non-ASCII are \u-escaped), so it survives
 * HTML serialization unchanged.
 *
 * Uncaught errors, unhandled rejections and securitypolicyviolation events (CSP
 * and Trusted Types) of this window and of every window passed to watchWindow()
 * are failures: they fail the running test, or the suite when no test runs.
 * Wrap code that is expected to produce them in captureErrors().
 */

export const RESULTS_ID = "wmux-test-results";
export const RESULTS_FORMAT = "wmux-web-test/1";
export const DEFAULT_TEST_TIMEOUT_MS = 15000;

const tests = [];
const suiteErrors = [];
const captures = [];
let current = null;
let started = false;

/** Thrown by the assert* helpers. */
export class AssertionError extends Error {
  constructor(message, details) {
    super(message);
    this.name = "AssertionError";
    if (details) Object.assign(this, details);
  }
}

/**
 * Register a test.
 * @param {string} name "unit: <feature-or-layer>: <behavior>" style names are encouraged
 * @param {() => any | Promise<any>} fn
 * @param {{timeoutMs?: number, skip?: boolean}} [options]
 */
export function test(name, fn, options) {
  if (started) throw new Error("test() called after run(): " + name);
  if (typeof name !== "string" || name === "") throw new TypeError("test name must be a non-empty string");
  if (typeof fn !== "function") throw new TypeError("test body must be a function");
  if (tests.some((t) => t.name === name)) throw new Error("duplicate test name: " + name);
  tests.push({ name, fn, options: options || {} });
}

/** Register a test that is reported as skipped. */
test.skip = function skip(name, fn, options) {
  test(name, fn, Object.assign({}, options, { skip: true }));
};

/* ------------------------------------------------------------------------ */
/* Assertions                                                                 */
/* ------------------------------------------------------------------------ */

/** Object.is equality. */
export function assertEqual(actual, expected, message) {
  if (!Object.is(actual, expected)) {
    throw new AssertionError(
      (message ? message + ": " : "") + "expected " + show(expected) + ", got " + show(actual),
      { actual: show(actual), expected: show(expected) },
    );
  }
}

/** Structural equality of JSON-like values (plain objects, arrays, Date, RegExp, Map, Set), across realms. */
export function assertDeepEqual(actual, expected, message) {
  const path = deepDiff(actual, expected, "$", new Set());
  if (path !== null) {
    throw new AssertionError(
      (message ? message + ": " : "") + "values differ at " + path + ": expected " +
        show(expected) + ", got " + show(actual),
      { actual: show(actual), expected: show(expected), path },
    );
  }
}

/** `value` is a string matching `pattern` (RegExp or substring). */
export function assertMatch(value, pattern, message) {
  const ok = typeof value === "string" &&
    (pattern instanceof RegExp ? new RegExp(pattern.source, pattern.flags.replace("g", "")).test(value) : value.includes(String(pattern)));
  if (!ok) {
    throw new AssertionError(
      (message ? message + ": " : "") + show(value) + " does not match " + String(pattern),
      { actual: show(value), expected: String(pattern) },
    );
  }
}

/** Truthiness check. */
export function assertTrue(value, message) {
  if (!value) throw new AssertionError((message || "expected a truthy value") + ", got " + show(value));
}

/**
 * `fn` throws (or, when it returns a promise, rejects). Returns the error
 * (a promise of it for async functions). `expected` filters the error:
 * a constructor (instanceof or same name), a RegExp for the message,
 * an object whose keys must deep-equal the error's properties, or a predicate.
 */
export function assertThrows(fn, expected, message) {
  let result;
  try {
    result = fn();
  } catch (err) {
    return checkThrown(err, expected, message);
  }
  if (result && typeof result.then === "function") {
    return Promise.resolve(result).then(
      () => {
        throw new AssertionError((message ? message + ": " : "") + "expected a rejection, but the promise resolved");
      },
      (err) => checkThrown(err, expected, message),
    );
  }
  throw new AssertionError((message ? message + ": " : "") + "expected an exception, but none was thrown");
}

/** Async form of assertThrows (always returns a promise). */
export async function assertRejects(promiseOrFn, expected, message) {
  const promise = typeof promiseOrFn === "function" ? Promise.resolve().then(promiseOrFn) : promiseOrFn;
  return assertThrows(() => promise, expected, message);
}

function checkThrown(err, expected, message) {
  const prefix = message ? message + ": " : "";
  if (expected === undefined || expected === null) return err;
  if (expected instanceof RegExp) {
    assertMatch(err && err.message, expected, prefix + "error message");
  } else if (typeof expected === "function" && expected.prototype && (expected === Error || expected.prototype instanceof Error)) {
    const ok = err instanceof expected || (err && err.name === expected.name);
    if (!ok) throw new AssertionError(prefix + "expected " + expected.name + ", got " + show(err));
  } else if (typeof expected === "function") {
    if (!expected(err)) throw new AssertionError(prefix + "thrown error did not satisfy the predicate: " + show(err));
  } else if (typeof expected === "object") {
    for (const key of Object.keys(expected)) {
      assertDeepEqual(err ? err[key] : undefined, expected[key], prefix + "error." + key);
    }
  }
  return err;
}

function tagOf(value) {
  return Object.prototype.toString.call(value);
}

function deepDiff(a, b, path, seen) {
  if (Object.is(a, b)) return null;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return path;
  const ta = tagOf(a);
  if (ta !== tagOf(b)) return path;
  if (seen.has(a)) return null;
  seen.add(a);
  if (ta === "[object Date]") return a.getTime() === b.getTime() ? null : path;
  if (ta === "[object RegExp]") return String(a) === String(b) ? null : path;
  if (ta === "[object Map]" || ta === "[object Set]") {
    if (a.size !== b.size) return path + ".size";
    const ea = Array.from(a.entries());
    const eb = Array.from(b.entries());
    for (let i = 0; i < ea.length; i += 1) {
      const d = deepDiff(ea[i], eb[i], path + "[entry " + i + "]", seen);
      if (d !== null) return d;
    }
    return null;
  }
  if (Array.isArray(a)) {
    if (a.length !== b.length) return path + ".length";
    for (let i = 0; i < a.length; i += 1) {
      const d = deepDiff(a[i], b[i], path + "[" + i + "]", seen);
      if (d !== null) return d;
    }
    return null;
  }
  const ka = Object.keys(a).filter((k) => a[k] !== undefined).sort();
  const kb = Object.keys(b).filter((k) => b[k] !== undefined).sort();
  if (ka.length !== kb.length || ka.some((k, i) => k !== kb[i])) {
    const missing = kb.find((k) => !ka.includes(k));
    const extra = ka.find((k) => !kb.includes(k));
    return path + (missing !== undefined ? "." + missing + " (missing)" : "." + extra + " (unexpected)");
  }
  for (const k of ka) {
    const d = deepDiff(a[k], b[k], path + "." + k, seen);
    if (d !== null) return d;
  }
  return null;
}

/** Short, JSON-ish rendering of a value for messages (capped at 300 chars). */
export function show(value) {
  let text;
  if (typeof value === "string") text = JSON.stringify(value);
  else if (typeof value === "function") text = "[function " + (value.name || "anonymous") + "]";
  else if (typeof value === "bigint") text = value + "n";
  else if (value === undefined) text = "undefined";
  else if (value && typeof value === "object" && typeof value.message === "string" && "stack" in value) {
    text = (value.name || "Error") + ": " + value.message + (value.code !== undefined ? " (code " + JSON.stringify(value.code) + ")" : "");
  } else {
    try {
      text = JSON.stringify(value);
    } catch {
      text = String(value);
    }
    if (text === undefined) text = String(value);
  }
  return text.length > 300 ? text.slice(0, 297) + "..." : text;
}

/**
 * Poll `predicate` until it returns a truthy value (which is returned).
 * Rejects with an AssertionError after `timeoutMs` (default 5000).
 * @param {() => any | Promise<any>} predicate
 * @param {{timeoutMs?: number, intervalMs?: number, message?: string}} [options]
 */
export async function waitFor(predicate, options) {
  const o = options || {};
  const timeoutMs = o.timeoutMs === undefined ? 5000 : o.timeoutMs;
  const intervalMs = o.intervalMs === undefined ? 10 : Math.max(1, o.intervalMs);
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  for (;;) {
    try {
      const value = await predicate();
      if (value) return value;
      lastError = null;
    } catch (err) {
      lastError = err;
    }
    if (Date.now() >= deadline) {
      throw new AssertionError(
        "waitFor timed out after " + timeoutMs + " ms" + (o.message ? ": " + o.message : "") +
          (lastError ? " (last error: " + show(lastError) + ")" : ""),
      );
    }
    await sleep(intervalMs);
  }
}

/** Promise that resolves after `ms` milliseconds. */
export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/* ------------------------------------------------------------------------ */
/* Uncaught errors, rejections and policy violations                          */
/* ------------------------------------------------------------------------ */

const watched = new WeakSet();

/**
 * Record uncaught errors, unhandled rejections and securitypolicyviolation
 * events of `win` (this window is watched automatically). For an iframe, call
 * it right after inserting the frame: the listeners stay on the Window that the
 * first same-origin navigation reuses. Returns a function that stops watching.
 * @param {Window} win
 * @param {string} [label] names the window in failure records
 */
export function watchWindow(win, label) {
  if (!win || watched.has(win)) return () => {};
  watched.add(win);
  const where = label || "page";
  const onError = (event) => {
    record({
      kind: "error",
      window: where,
      message: event.message || show(event.error),
      source: event.filename || "",
      line: event.lineno || 0,
      column: event.colno || 0,
      stack: event.error && event.error.stack ? String(event.error.stack).slice(0, 2000) : "",
    });
  };
  const onRejection = (event) => {
    const reason = event.reason;
    record({
      kind: "unhandledrejection",
      window: where,
      message: show(reason),
      stack: reason && reason.stack ? String(reason.stack).slice(0, 2000) : "",
    });
  };
  const onViolation = (event) => {
    record({
      kind: "securitypolicyviolation",
      window: where,
      message: "CSP violation: " + event.effectiveDirective + " blocked " + (event.blockedURI || "(inline)"),
      violatedDirective: event.violatedDirective,
      effectiveDirective: event.effectiveDirective,
      blockedURI: event.blockedURI,
      disposition: event.disposition,
      sample: event.sample || "",
      source: event.sourceFile || "",
      line: event.lineNumber || 0,
      column: event.columnNumber || 0,
    });
  };
  win.addEventListener("error", onError);
  win.addEventListener("unhandledrejection", onRejection);
  win.addEventListener("securitypolicyviolation", onViolation);
  return () => {
    watched.delete(win);
    win.removeEventListener("error", onError);
    win.removeEventListener("unhandledrejection", onRejection);
    win.removeEventListener("securitypolicyviolation", onViolation);
  };
}

function record(entry) {
  if (captures.length > 0) {
    captures[captures.length - 1].push(entry);
    return;
  }
  if (current) {
    entry.test = current.name;
    current.errors.push(entry);
  } else {
    suiteErrors.push(entry);
  }
}

/**
 * Run `fn` and return the error records it produced instead of failing.
 * Waits `settleMs` (default 50) after `fn` so late events are included.
 * @returns {Promise<object[]>}
 */
export async function captureErrors(fn, settleMs) {
  const bucket = [];
  captures.push(bucket);
  try {
    await fn();
    await sleep(settleMs === undefined ? 50 : settleMs);
  } finally {
    const i = captures.lastIndexOf(bucket);
    if (i >= 0) captures.splice(i, 1);
  }
  return bucket;
}

/** Errors recorded so far for the running test (or the suite), for assertions. */
export function recordedErrors() {
  return (current ? current.errors : suiteErrors).slice();
}

if (typeof window !== "undefined") watchWindow(window, "suite");

/* ------------------------------------------------------------------------ */
/* Runner                                                                     */
/* ------------------------------------------------------------------------ */

/** If run() was not called this long after "load" (a suite module failed to load), report failure. */
export const RUN_WATCHDOG_MS = 20000;

/**
 * Run the registered tests and publish the results block.
 * @param {{suite?: string, settleMs?: number}} [options]
 *   suite: name in the results (default: page file name without ".test.html")
 *   settleMs: wait after the last test for late errors (default 50)
 * @returns {Promise<object>} the results object
 */
export async function run(options) {
  if (started) throw new Error("run() called twice");
  started = true;
  const o = options || {};
  const suite = o.suite || suiteNameFromLocation();
  const begin = Date.now();
  const results = [];
  for (const t of tests) {
    results.push(await runOne(t));
  }
  await sleep(o.settleMs === undefined ? 50 : o.settleMs);
  return publish(suite, results, Date.now() - begin);
}

async function runOne(t) {
  if (t.options.skip) return { name: t.name, status: "skipped", durationMs: 0 };
  const entry = { name: t.name, errors: [] };
  current = entry;
  const begin = Date.now();
  const timeoutMs = t.options.timeoutMs || DEFAULT_TEST_TIMEOUT_MS;
  let failure = null;
  let timer = 0;
  try {
    await Promise.race([
      Promise.resolve().then(t.fn),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new AssertionError("test timed out after " + timeoutMs + " ms")), timeoutMs);
      }),
    ]);
    await sleep(0); // let events queued by the test's last step fire while it is current
  } catch (err) {
    failure = err;
  } finally {
    clearTimeout(timer);
    current = null;
  }
  const out = { name: t.name, status: "passed", durationMs: Date.now() - begin };
  if (failure || entry.errors.length > 0) {
    out.status = "failed";
    out.error = failure
      ? { name: failure.name || "Error", message: failure.message !== undefined ? String(failure.message) : show(failure), stack: failure.stack ? String(failure.stack).slice(0, 2000) : "" }
      : { name: "UncaughtError", message: entry.errors[0].message };
    if (entry.errors.length > 0) out.errors = entry.errors;
  }
  return out;
}

function publish(suite, results, durationMs) {
  const count = (status) => results.filter((r) => r.status === status).length;
  const failed = count("failed");
  const doc = {
    format: RESULTS_FORMAT,
    suite,
    status: failed === 0 && suiteErrors.length === 0 && results.length > 0 ? "passed" : "failed",
    total: results.length,
    passed: count("passed"),
    failed,
    skipped: count("skipped"),
    durationMs,
    userAgent: typeof navigator !== "undefined" ? navigator.userAgent : "",
    tests: results,
    errors: suiteErrors.slice(),
  };
  if (results.length === 0) doc.errors.push({ kind: "harness", message: "the suite registered no tests" });
  writeResults(doc);
  return doc;
}

/** JSON with <, >, & and every non-ASCII code unit \u-escaped. */
export function asciiJson(value) {
  return JSON.stringify(value, null, 1).replace(/[\u007f-\uffff<>&]/g, (c) => "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0"));
}

function writeResults(doc) {
  if (typeof document === "undefined") return;
  let pre = document.getElementById(RESULTS_ID);
  if (!pre) {
    pre = document.createElement("pre");
    pre.id = RESULTS_ID;
    (document.body || document.documentElement).appendChild(pre);
  }
  pre.textContent = asciiJson(doc);
  pre.setAttribute("data-status", doc.status);
  document.documentElement.setAttribute("data-wmux-test-status", doc.status);
}

function suiteNameFromLocation() {
  if (typeof location === "undefined") return "suite";
  const file = location.pathname.split("/").pop() || "suite";
  return decodeURIComponent(file).replace(/\.test\.html$/i, "").replace(/\.html$/i, "");
}

if (typeof window !== "undefined") {
  window.addEventListener("load", () => {
    setTimeout(() => {
      if (started) return;
      started = true;
      suiteErrors.push({ kind: "harness", message: "run() was not called within " + RUN_WATCHDOG_MS + " ms of load (did a suite module fail to load?)" });
      publish(suiteNameFromLocation(), [], 0);
    }, RUN_WATCHDOG_MS);
  });
}
