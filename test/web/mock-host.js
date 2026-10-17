/**
 * Mock of the WebView2 host side of a wmux web panel (ARCHITECTURE ADR-6.5),
 * for the real-browser harness in test/web/.
 *
 * It implements the page-facing half of window.chrome.webview
 * (postMessage / addEventListener / removeEventListener) so that
 * src/web/_shared/wmux-bridge.js runs unmodified, and plays native:
 *
 *   const host = createMockHost({ init: { kind: "about" } });
 *   host.respond("panel.about.info", { product: "wmux", version: "1.2.3" });
 *   host.respond("workspace.list", (params, call) => ({ workspaces: [] }));
 *   host.respond("panel.notify", reply.error("forbidden", "not allowed"));
 *   host.respond("slow.method", reply.delay(500, { ok: 1 }));
 *   host.respondOnce("flaky", reply.error("busy", "try again"));
 *   host.install(frame.contentWindow);   // before the page's scripts run
 *   host.emit("cmux.event", frame);       // inject a host event
 *   host.setTheme({ background: "#101010" });
 *   host.calls                            // every message the page posted
 *
 * Delivery mirrors PostWebMessageAsJson: every host message is serialized to
 * JSON and parsed in the page's realm, then dispatched asynchronously as a
 * MessageEvent whose `data` is the parsed object. Page messages are copied
 * through JSON too (get_WebMessageAsJson), so the record never aliases page
 * objects.
 *
 * Ready handshake: an unscripted panel.ready replies {ok: true, result: null}
 * and then posts the panel.init event (readyMode "event", the default).
 * readyMode "result" returns the init payload as the panel.ready result,
 * "none" leaves panel.ready unanswered (to test the bridge's ready timeout).
 *
 * Plain ES module, no dependencies.
 */

/** Envelope version (mirrors wmux-bridge.js PROTOCOL_VERSION). */
export const PROTOCOL_VERSION = 1;

const REPLY = Symbol("wmux.mock.reply");

/** Default theme posted with panel.init: a dark terminal theme. */
export const DEFAULT_THEME = Object.freeze({
  background: "#1e1e2e",
  foreground: "#cdd6f4",
  palette: [
    "#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
    "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8",
  ],
  cursor: "#f5e0dc",
  selection: "#585b70",
  accent: "#89b4fa",
  font_family: "Cascadia Mono",
  font_size_px: 14,
  background_opacity: 1,
  scheme: "dark",
  high_contrast: false,
});

/**
 * Scripted reply constructors. A reply spec given to respond() is one of:
 * a plain value (the result), a function (params, call) => spec | Promise,
 * or one of these tagged objects.
 */
export const reply = Object.freeze({
  /** ok reply with `result` (use for results that are functions or tagged-looking). */
  ok(result) {
    return tag({ type: "ok", result });
  },
  /** error reply {code, message, data?, reason?, action?, details?} */
  error(code, message, extra) {
    const error = Object.assign({ code: String(code), message: String(message ?? code) }, extra || {});
    return tag({ type: "error", error });
  },
  /** answer after `ms` milliseconds with `spec` (default: null result) */
  delay(ms, spec) {
    return tag({ type: "delay", ms: Math.max(0, Number(ms) || 0), spec: spec === undefined ? null : spec });
  },
  /** never answer (the bridge's own timeout or AbortSignal must settle the call) */
  never() {
    return tag({ type: "never" });
  },
  /** post this exact message instead of a normal reply (object or JSON/garbage string) */
  raw(message) {
    return tag({ type: "raw", message });
  },
});

function tag(obj) {
  Object.defineProperty(obj, REPLY, { value: true });
  return Object.freeze(obj);
}

function isReply(value) {
  return Boolean(value) && typeof value === "object" && value[REPLY] === true;
}

/** Error class a reply function may throw to produce an error reply. */
export class MockHostError extends Error {
  constructor(code, message, extra) {
    super(message ?? code);
    this.name = "MockHostError";
    this.code = code;
    this.extra = extra || {};
  }
}

/**
 * Create a mock host.
 *
 * @param {object} [options]
 * @param {object} [options.init] panel.init payload fields (merged over defaults:
 *   kind "test", a fixed surface_id, params {}, state null, DEFAULT_THEME, keymap {}, settings {})
 * @param {"event"|"result"|"none"} [options.readyMode] how panel.ready is answered
 * @param {number} [options.latencyMs] delay before every reply and event (default 0)
 * @param {Record<string, any>} [options.responses] initial respond() table
 * @param {"method_not_found"|"never"|((params: object, call: object) => any)} [options.unhandled]
 *   reply for methods without a script (default method_not_found)
 */
export function createMockHost(options) {
  const opts = options || {};
  const listeners = [];
  const scripted = new Map();
  const queued = new Map();
  const calls = [];
  const callWaiters = [];
  let readyMode = opts.readyMode || "event";
  let latencyMs = Math.max(0, Number(opts.latencyMs) || 0);
  let pageWindow = null;
  let closed = false;
  let seq = 0;

  const init = Object.assign(
    {
      kind: "test",
      surface_id: "00000000-0000-4000-8000-000000000001",
      params: {},
      state: null,
      theme: clone(DEFAULT_THEME),
      keymap: {},
      settings: {},
    },
    clone(opts.init || {}),
  );

  const webview = {
    postMessage(message) {
      if (closed) throw new Error("mock host is closed");
      // get_WebMessageAsJson: the page's object as JSON (throws like WebView2 on cycles).
      const json = JSON.stringify(message);
      if (json === undefined) throw new TypeError("message is not JSON-serializable");
      receive(JSON.parse(json));
    },
    addEventListener(type, listener, listenerOptions) {
      if (type !== "message" || !listener) return;
      if (listeners.some((l) => l.listener === listener)) return;
      const once = Boolean(listenerOptions && typeof listenerOptions === "object" && listenerOptions.once);
      listeners.push({ listener, once });
    },
    removeEventListener(type, listener) {
      if (type !== "message") return;
      const i = listeners.findIndex((l) => l.listener === listener);
      if (i >= 0) listeners.splice(i, 1);
    },
  };

  function receive(msg) {
    seq += 1;
    const record = {
      seq,
      time: Date.now(),
      id: msg && msg.id !== undefined ? msg.id : null,
      method: msg && typeof msg.method === "string" ? msg.method : null,
      params: msg && msg.params !== undefined ? msg.params : null,
      fireAndForget: !msg || msg.id === undefined,
      message: msg,
      reply: null,
    };
    calls.push(record);
    for (const waiter of callWaiters.slice()) {
      if (waiter.match(record)) waiter.resolve(record);
    }
    if (record.fireAndForget || record.method === null) return;
    const spec = specFor(record.method);
    later(latencyMs, () => answer(record, spec));
  }

  function specFor(method) {
    const queue = queued.get(method);
    if (queue && queue.length > 0) return queue.shift();
    if (scripted.has(method)) return scripted.get(method);
    if (method === "panel.ready") return readyReply;
    if (typeof opts.unhandled === "function") return opts.unhandled;
    if (opts.unhandled === "never") return reply.never();
    return reply.error("method_not_found", "Unknown method: " + method);
  }

  // Native answers panel.ready, then pushes panel.init (never before panel.ready).
  function readyReply() {
    if (readyMode === "none") return reply.never();
    if (readyMode === "result") return reply.ok(clone(init));
    return tag({ type: "ok", result: null, after: () => emit("panel.init", init) });
  }

  async function resolveSpec(spec, record) {
    let value = spec;
    for (let depth = 0; depth < 32; depth += 1) {
      if (typeof value === "function") {
        try {
          value = await value(clone(record.params || {}), record);
        } catch (err) {
          if (err instanceof MockHostError || (err && typeof err.code === "string")) {
            return reply.error(err.code, err.message, err.extra);
          }
          return reply.error("internal_error", err && err.message ? err.message : String(err));
        }
        continue;
      }
      if (isReply(value) && value.type === "delay") {
        await new Promise((resolve) => later(value.ms, resolve));
        value = value.spec;
        continue;
      }
      return isReply(value) ? value : reply.ok(value === undefined ? null : value);
    }
    return reply.error("internal_error", "mock reply nesting too deep");
  }

  async function answer(record, spec) {
    const r = await resolveSpec(spec, record);
    if (closed || r.type === "never") return;
    if (r.type === "raw") {
      record.reply = r.message;
      deliver(r.message);
      return;
    }
    const message =
      r.type === "error"
        ? { v: PROTOCOL_VERSION, id: record.id, ok: false, error: r.error }
        : { v: PROTOCOL_VERSION, id: record.id, ok: true, result: r.result };
    record.reply = clone(message);
    deliver(message);
    if (typeof r.after === "function") r.after();
  }

  /** Serialize like PostWebMessageAsJson and dispatch asynchronously in the page realm. */
  function deliver(message) {
    if (closed) return;
    const json = typeof message === "string" ? null : JSON.stringify(message);
    setTimeout(() => {
      if (closed) return;
      let data = message;
      if (json !== null) {
        const realmJSON = pageWindow && pageWindow.JSON ? pageWindow.JSON : JSON;
        data = realmJSON.parse(json);
      }
      const event = makeEvent(data);
      for (const entry of listeners.slice()) {
        if (entry.once) webview.removeEventListener("message", entry.listener);
        try {
          if (typeof entry.listener === "function") entry.listener.call(webview, event);
          else if (typeof entry.listener.handleEvent === "function") entry.listener.handleEvent(event);
        } catch (err) {
          // A throwing page listener is the page's uncaught error, not the host's.
          reportListenerError(err);
        }
      }
    }, 0);
  }

  function makeEvent(data) {
    const Ctor = pageWindow && typeof pageWindow.MessageEvent === "function" ? pageWindow.MessageEvent : null;
    if (Ctor) {
      try {
        return new Ctor("message", { data });
      } catch {
        // fall through to a plain object
      }
    }
    return { type: "message", data, source: null };
  }

  function reportListenerError(err) {
    const win = pageWindow || globalThis;
    if (typeof win.reportError === "function") win.reportError(err);
    else setTimeout(() => { throw err; }, 0);
  }

  function emit(event, payload) {
    deliver({ v: PROTOCOL_VERSION, event: String(event), payload: payload === undefined ? null : clone(payload) });
  }

  function later(ms, fn) {
    if (ms > 0) setTimeout(fn, ms);
    else Promise.resolve().then(fn);
  }

  const host = {
    /** The object installed as window.chrome.webview. */
    webview,
    /** The panel.init payload sent on panel.ready (mutable; also see setInit). */
    get init() {
      return init;
    },
    /** Every message the page posted, oldest first: {seq, time, id, method, params, fireAndForget, message, reply}. */
    get calls() {
      return calls.slice();
    },
    /** Number of registered "message" listeners (the bridge registers one). */
    get listenerCount() {
      return listeners.length;
    },
    /** The window the mock was installed into, or null. */
    get window() {
      return pageWindow;
    },

    /**
     * Install as win.chrome.webview. For an iframe, call this right after inserting
     * the frame: Chromium keeps the initial about:blank Window for the first
     * same-origin navigation, so the page's scripts find the mock.
     */
    install(win) {
      const target = win || globalThis;
      let chromeObj = target.chrome;
      if (!chromeObj || (typeof chromeObj !== "object" && typeof chromeObj !== "function")) {
        chromeObj = {};
        Object.defineProperty(target, "chrome", { value: chromeObj, configurable: true, writable: true });
      }
      Object.defineProperty(chromeObj, "webview", { value: webview, configurable: true, writable: false });
      pageWindow = target;
      return host;
    },
    /** Script the reply for `method` (replaces an earlier script). */
    respond(method, spec) {
      scripted.set(String(method), spec);
      return host;
    },
    /** Queue a one-shot reply for `method`, used before the respond() script. */
    respondOnce(method, spec) {
      const name = String(method);
      if (!queued.has(name)) queued.set(name, []);
      queued.get(name).push(spec);
      return host;
    },
    /** Remove scripts for `method` (it falls back to the unhandled reply). */
    unrespond(method) {
      scripted.delete(String(method));
      queued.delete(String(method));
      return host;
    },
    /** Push a host event {v, event, payload} ("theme", "cmux.event", "keymap", ...). */
    emit(event, payload) {
      emit(event, payload);
      return host;
    },
    /** Post a raw message: an object as-is (JSON round trip) or a string verbatim. */
    post(message) {
      deliver(message);
      return host;
    },
    /** Push the panel.init event now (normally sent after panel.ready). */
    sendInit(patch) {
      if (patch) Object.assign(init, clone(patch));
      emit("panel.init", init);
      return host;
    },
    /** Merge fields into the panel.init payload for later handshakes. */
    setInit(patch) {
      Object.assign(init, clone(patch || {}));
      return host;
    },
    /** Theme sync: store the theme for later panel.init payloads and push a "theme" event. */
    setTheme(theme) {
      init.theme = clone(theme);
      emit("theme", theme);
      return host;
    },
    setReadyMode(mode) {
      readyMode = mode;
      return host;
    },
    setLatency(ms) {
      latencyMs = Math.max(0, Number(ms) || 0);
      return host;
    },
    /** Calls to one method (or all calls matching a predicate). */
    callsTo(method) {
      return calls.filter(matcher(method));
    },
    /** The most recent call to `method`, or null. */
    lastCall(method) {
      const list = calls.filter(matcher(method));
      return list.length > 0 ? list[list.length - 1] : null;
    },
    /**
     * Resolve with the first call (already recorded or future) to `method`.
     * @param {string | ((record: object) => boolean)} method
     * @param {{timeoutMs?: number, after?: number}} [waitOptions] after: only calls with seq > after
     */
    waitForCall(method, waitOptions) {
      const o = waitOptions || {};
      const base = matcher(method);
      const match = (r) => r.seq > (o.after || 0) && base(r);
      const found = calls.find(match);
      if (found) return Promise.resolve(found);
      return new Promise((resolve, reject) => {
        const waiter = {
          match,
          resolve(record) {
            remove();
            resolve(record);
          },
        };
        const timeoutMs = o.timeoutMs === undefined ? 5000 : o.timeoutMs;
        const timer = timeoutMs > 0
          ? setTimeout(() => {
            remove();
            reject(new Error("mock host: no call to " + describe(method) + " within " + timeoutMs + " ms"));
          }, timeoutMs)
          : 0;
        function remove() {
          if (timer) clearTimeout(timer);
          const i = callWaiters.indexOf(waiter);
          if (i >= 0) callWaiters.splice(i, 1);
        }
        callWaiters.push(waiter);
      });
    },
    /** Forget recorded calls (scripts stay). */
    clearCalls() {
      calls.length = 0;
      return host;
    },
    /** Stop delivering anything; later postMessage calls throw (like a torn-down host). */
    close() {
      closed = true;
      listeners.length = 0;
    },
  };

  for (const [method, spec] of Object.entries(opts.responses || {})) host.respond(method, spec);
  return host;
}

function matcher(method) {
  if (typeof method === "function") return method;
  return (record) => record.method === method;
}

function describe(method) {
  return typeof method === "function" ? "a matching method" : JSON.stringify(method);
}

function clone(value) {
  if (value === undefined) return undefined;
  return JSON.parse(JSON.stringify(value));
}
