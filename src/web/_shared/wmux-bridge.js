/**
 * wmux web panel bridge (ARCHITECTURE ADR-6.5).
 *
 * Speaks the v2 envelope with the native host over
 * window.chrome.webview.postMessage and the webview "message" event:
 *
 *   page -> native  {"v":1,"id":"c17","method":"workspace.list","params":{}}
 *                   (no "id" = fire-and-forget; native sends no reply)
 *   native -> page  {"v":1,"id":"c17","ok":true,"result":{...}}
 *                   {"v":1,"id":"c17","ok":false,"error":{"code":"...","message":"...","data":{...}}}
 *                   {"v":1,"event":"panel.init","payload":{...}}
 *
 * Usage:
 *
 *   import { wmux } from "../_shared/wmux-bridge.js";
 *   const ctx = await wmux.ready();              // panel.init payload
 *   const list = await wmux.call("workspace.list");
 *   const off = wmux.on("theme", (theme) => {}); // returns an unsubscribe function
 *
 * Pages always post plain objects, so native reads them with
 * ICoreWebView2WebMessageReceivedEventArgs::get_WebMessageAsJson.
 * Native identifies the sender by the controller that raised the event; nothing
 * the page sends is trusted as identity. See README.md for the full contract.
 *
 * Plain ES2020 module: no build step, no dependencies.
 */

/** Envelope version carried in every message ("v"). */
export const PROTOCOL_VERSION = 1;

/** Default bridge-side deadline for call(); native UI-lane methods time out after 10 s. */
export const DEFAULT_TIMEOUT_MS = 30000;

/** How long ready() waits for panel.init. */
export const READY_TIMEOUT_MS = 10000;

/** Upper bound for panel.state_changed payloads (ADR-6.5). */
export const MAX_STATE_BYTES = 65536;

const MAX_TIMER_MS = 2147483647;
const SINGLETON_KEY = Symbol.for("wmux.bridge.v1");

/** Error codes of the v2 protocol (ARCHITECTURE ADR-3.5). */
export const ErrorCode = Object.freeze({
  PARSE_ERROR: "parse_error",
  INVALID_UTF8: "invalid_utf8",
  INVALID_REQUEST: "invalid_request",
  METHOD_NOT_FOUND: "method_not_found",
  INVALID_PARAMS: "invalid_params",
  NOT_FOUND: "not_found",
  SURFACE_UNAVAILABLE: "surface_unavailable",
  UNAVAILABLE: "unavailable",
  INVALID_STATE: "invalid_state",
  NOT_SUPPORTED: "not_supported",
  BUSY: "busy",
  CANCELLED: "cancelled",
  TIMEOUT: "timeout",
  OVERLOADED: "overloaded",
  RATE_LIMITED: "rate_limited",
  INPUT_QUEUE_FULL: "input_queue_full",
  FORBIDDEN: "forbidden",
  CONFIRMATION_REQUIRED: "confirmation_required",
  AUTH_REQUIRED: "auth_required",
  AUTH_FAILED: "auth_failed",
  AUTH_UNCONFIGURED: "auth_unconfigured",
  DISABLED: "disabled",
  CAPABILITY_DISABLED: "capability_disabled",
  BROWSER_DISABLED: "browser_disabled",
  PERMISSION_DENIED: "permission_denied",
  JS_ERROR: "js_error",
  FILE_NOT_FOUND: "file_not_found",
  STALE_STATE: "stale_state",
  INTERNAL_ERROR: "internal_error",
  ENCODE_ERROR: "encode_error",
  SLOW_CONSUMER: "slow_consumer",
  REMOTE_RELAY_DENIED: "remote_relay_denied",
});

/**
 * Error raised for failed calls. Mirrors the wire error object
 * {code, message, data?, reason?, action?, details?}; `method` names the call.
 */
class BridgeError extends Error {
  /**
   * @param {string} code
   * @param {string} message
   * @param {{data?: unknown, reason?: unknown, action?: unknown, details?: unknown, method?: string}} [extra]
   */
  constructor(code, message, extra) {
    super(message);
    const x = extra || {};
    this.name = "WmuxError";
    this.code = code;
    this.data = x.data;
    if (x.reason !== undefined) this.reason = x.reason;
    if (x.action !== undefined) this.action = x.action;
    if (x.details !== undefined) this.details = x.details;
    this.method = x.method;
  }

  /** Wire-shaped copy, handy for logging and for panel.state_changed. */
  toJSON() {
    const out = { code: this.code, message: this.message };
    if (this.data !== undefined) out.data = this.data;
    if (this.reason !== undefined) out.reason = this.reason;
    if (this.action !== undefined) out.action = this.action;
    if (this.details !== undefined) out.details = this.details;
    if (this.method !== undefined) out.method = this.method;
    return out;
  }
}

const existing = globalThis[SINGLETON_KEY];

/** The bridge object (one per page, shared by every module that imports this file). */
export const wmux = existing || createBridge();

/** Constructor of the errors the bridge rejects with (`err instanceof WmuxError`). */
export const WmuxError = wmux.WmuxError;

/** cmux-compatible alias: cmux(method, params) === wmux.call(method, params). */
export const cmux = wmux.cmux;

export default wmux;

if (!existing) {
  Object.defineProperty(globalThis, SINGLETON_KEY, { value: wmux });
  defineGlobal("wmux", wmux);
  defineGlobal("cmux", wmux.cmux);
}

function defineGlobal(name, value) {
  if (Object.prototype.hasOwnProperty.call(globalThis, name)) return;
  try {
    Object.defineProperty(globalThis, name, {
      value,
      writable: false,
      configurable: false,
      enumerable: false,
    });
  } catch {
    // A frozen or exotic global object: the module exports still work.
  }
}

function createBridge() {
  /** @type {Map<string, {method: string, resolve: Function, reject: Function, cleanup: Function}>} */
  const pending = new Map();
  /** @type {Map<string, Set<Function>>} */
  const listeners = new Map();
  const readyWaiters = new Set();
  const webview = findWebview();
  const encoder = typeof TextEncoder === "function" ? new TextEncoder() : null;

  let seq = 0;
  let context = null;
  let theme = null;
  let readyPromise = null;
  let debugEnabled = false;
  let warnedVersion = false;
  let warnedMissingVersion = false;

  function debug(...args) {
    if (debugEnabled) console.debug("[wmux-bridge]", ...args);
  }

  function warn(...args) {
    console.warn("[wmux-bridge]", ...args);
  }

  function post(envelope) {
    debug("->", envelope);
    webview.postMessage(envelope);
  }

  function normalizeMethod(method) {
    if (typeof method !== "string" || method.trim() === "") {
      throw new BridgeError(ErrorCode.INVALID_REQUEST, "Missing method");
    }
    return method.trim();
  }

  function normalizeParams(params, method) {
    if (params === undefined || params === null) return {};
    if (typeof params !== "object" || Array.isArray(params)) {
      throw new BridgeError(
        ErrorCode.INVALID_PARAMS,
        "params must be a JSON object",
        { method },
      );
    }
    return params;
  }

  function encode(value, method) {
    let json;
    try {
      json = JSON.stringify(value);
    } catch (err) {
      throw new BridgeError(ErrorCode.ENCODE_ERROR, "Failed to encode JSON", {
        method,
        data: { reason: errorText(err) },
      });
    }
    if (json === undefined) {
      throw new BridgeError(ErrorCode.ENCODE_ERROR, "Failed to encode JSON", {
        method,
        data: { reason: "value is not JSON-serializable" },
      });
    }
    return json;
  }

  /**
   * Send a request and wait for its reply.
   *
   * @param {string} method v2 method name ("workspace.list", "panel.set_title", ...)
   * @param {object} [params] JSON object; omitted or null means {}
   * @param {{timeoutMs?: number, signal?: AbortSignal}} [options]
   *   timeoutMs: bridge-side deadline (default 30000; 0 or Infinity = none)
   *   signal: AbortSignal; aborting rejects with code "cancelled"
   * @returns {Promise<any>} the reply's `result` (null when absent)
   */
  function call(method, params, options) {
    return new Promise((resolve, reject) => {
      let name;
      let envelope;
      try {
        name = normalizeMethod(method);
        const body = normalizeParams(params, name);
        if (!webview) throw unavailableError(name);
        seq += 1;
        envelope = { v: PROTOCOL_VERSION, id: "c" + seq, method: name, params: body };
        encode(envelope, name);
      } catch (err) {
        reject(err);
        return;
      }

      const id = envelope.id;
      const opts = options || {};
      const signal = opts.signal || null;
      if (signal && signal.aborted) {
        reject(cancelledError(name));
        return;
      }

      const timeoutMs = resolveTimeout(opts.timeoutMs, DEFAULT_TIMEOUT_MS);
      let timer = 0;
      const onAbort = () => fail(id, cancelledError(name));
      const entry = {
        method: name,
        resolve,
        reject,
        cleanup() {
          if (timer) clearTimeout(timer);
          if (signal) signal.removeEventListener("abort", onAbort);
        },
      };
      if (timeoutMs > 0) {
        timer = setTimeout(() => fail(id, timeoutError(name, timeoutMs)), timeoutMs);
      }
      if (signal) signal.addEventListener("abort", onAbort, { once: true });
      pending.set(id, entry);

      try {
        post(envelope);
      } catch (err) {
        fail(
          id,
          new BridgeError(
            ErrorCode.UNAVAILABLE,
            "Failed to post a message to the wmux host",
            { method: name, data: { reason: errorText(err) } },
          ),
        );
      }
    });
  }

  function fail(id, error) {
    const entry = pending.get(id);
    if (!entry) return;
    pending.delete(id);
    entry.cleanup();
    entry.reject(error);
  }

  /**
   * Fire-and-forget: post a request without an id. Native never replies.
   * Best effort by design: returns false (and logs) instead of throwing.
   *
   * @param {string} method
   * @param {object} [params]
   * @returns {boolean} whether the message was handed to the host
   */
  function send(method, params) {
    try {
      const name = normalizeMethod(method);
      const body = normalizeParams(params, name);
      if (!webview) throw unavailableError(name);
      const envelope = { v: PROTOCOL_VERSION, method: name, params: body };
      encode(envelope, name);
      post(envelope);
      return true;
    } catch (err) {
      if (webview) warn("send failed:", errorText(err));
      else debug("send skipped:", errorText(err));
      return false;
    }
  }

  function onMessage(event) {
    let msg = event ? event.data : undefined;
    if (typeof msg === "string") {
      try {
        msg = JSON.parse(msg);
      } catch {
        warn("ignoring a host message that is not JSON");
        return;
      }
    }
    if (!msg || typeof msg !== "object" || Array.isArray(msg)) return;

    if (msg.v === undefined) {
      if (!warnedMissingVersion) {
        warnedMissingVersion = true;
        warn('host message without "v"; assuming protocol', PROTOCOL_VERSION);
      }
    } else if (msg.v !== PROTOCOL_VERSION) {
      if (!warnedVersion) {
        warnedVersion = true;
        warn("ignoring host messages with unsupported protocol version", msg.v);
      }
      return;
    }

    debug("<-", msg);
    if (typeof msg.event === "string" && msg.event !== "") {
      dispatch(msg.event, msg.payload);
    } else if (msg.id !== undefined && msg.id !== null && typeof msg.ok === "boolean") {
      settle(msg);
    } else {
      debug("ignoring an unrecognized host message");
    }
  }

  function settle(msg) {
    const id = String(msg.id);
    const entry = pending.get(id);
    if (!entry) {
      debug("dropping a reply for an unknown or expired request", id);
      return;
    }
    pending.delete(id);
    entry.cleanup();
    if (msg.ok) {
      entry.resolve(msg.result === undefined ? null : msg.result);
    } else {
      entry.reject(errorFromWire(msg.error, entry.method));
    }
  }

  function dispatch(name, payload) {
    let value = payload;
    if (name === "panel.init") {
      if (!acceptInit(payload)) return;
      value = context;
    } else if (name === "theme" && payload && typeof payload === "object") {
      theme = payload;
      if (context) context.theme = payload;
    }
    emit(name, value);
  }

  function acceptInit(payload) {
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      warn("ignoring a malformed panel.init payload");
      return false;
    }
    context = Object.assign({}, payload);
    if (context.theme && typeof context.theme === "object") theme = context.theme;
    for (const waiter of Array.from(readyWaiters)) waiter.resolve(context);
    return true;
  }

  function emit(name, payload) {
    const direct = listeners.get(name);
    if (direct) for (const fn of Array.from(direct)) invoke(fn, payload, name);
    const wildcard = listeners.get("*");
    if (wildcard) for (const fn of Array.from(wildcard)) invoke(fn, payload, name);
  }

  function invoke(fn, payload, name) {
    try {
      fn(payload, name);
    } catch (err) {
      console.error('[wmux-bridge] listener for "' + name + '" threw', err);
    }
  }

  /**
   * Subscribe to a host event ("panel.init", "theme", "cmux.event", ...).
   * "*" receives every event. Listeners are called as listener(payload, eventName).
   *
   * @param {string} name
   * @param {(payload: any, name: string) => void} listener
   * @returns {() => void} unsubscribe
   */
  function on(name, listener) {
    if (typeof name !== "string" || name === "") {
      throw new TypeError("event name must be a non-empty string");
    }
    if (typeof listener !== "function") throw new TypeError("listener must be a function");
    let set = listeners.get(name);
    if (!set) {
      set = new Set();
      listeners.set(name, set);
    }
    set.add(listener);
    return () => off(name, listener);
  }

  /** Like on(), but the listener runs at most once. Use the returned function to cancel. */
  function once(name, listener) {
    if (typeof listener !== "function") throw new TypeError("listener must be a function");
    const wrapper = (payload, eventName) => {
      off(name, wrapper);
      listener(payload, eventName);
    };
    return on(name, wrapper);
  }

  /** Remove a listener added with on(). */
  function off(name, listener) {
    const set = listeners.get(name);
    if (!set) return;
    set.delete(listener);
    if (set.size === 0) listeners.delete(name);
  }

  /**
   * Ready handshake: sends panel.ready (once per page load) and resolves with the
   * panel.init payload {kind, surface_id, params, state, theme, keymap, settings}.
   * Native may deliver the payload as a panel.init event or as the panel.ready result.
   * A failed attempt (timeout, error) can be retried by calling ready() again.
   *
   * @param {{timeoutMs?: number}} [options] default 10000; 0 = wait forever
   * @returns {Promise<object>}
   */
  function ready(options) {
    if (readyPromise) return readyPromise;
    const opts = options || {};
    const timeoutMs = resolveTimeout(opts.timeoutMs, READY_TIMEOUT_MS);
    const attempt = new Promise((resolve, reject) => {
      let timer = 0;
      const waiter = {
        done: false,
        resolve(value) {
          if (waiter.done) return;
          waiter.done = true;
          if (timer) clearTimeout(timer);
          readyWaiters.delete(waiter);
          resolve(value);
        },
        reject(error) {
          if (waiter.done) return;
          waiter.done = true;
          if (timer) clearTimeout(timer);
          readyWaiters.delete(waiter);
          reject(error);
        },
      };

      if (!webview) {
        waiter.reject(unavailableError("panel.ready"));
        return;
      }
      readyWaiters.add(waiter);
      if (context) waiter.resolve(context);
      if (timeoutMs > 0 && !waiter.done) {
        timer = setTimeout(() => {
          waiter.reject(
            new BridgeError(ErrorCode.TIMEOUT, "Timed out waiting for panel.init", {
              method: "panel.ready",
              data: { stage: "bridge", deadline_ms: timeoutMs, retryable: true },
            }),
          );
        }, timeoutMs);
      }

      // Native learns that the page listens; it answers with panel.init.
      call("panel.ready", {}, { timeoutMs }).then(
        (result) => {
          if (!waiter.done && isInitPayload(result)) dispatch("panel.init", result);
        },
        (error) => waiter.reject(error),
      );
    });
    readyPromise = attempt;
    attempt.catch(() => {
      if (readyPromise === attempt) readyPromise = null;
    });
    return attempt;
  }

  const panel = Object.freeze({
    /** panel.set_title {title} */
    setTitle(title) {
      return call("panel.set_title", { title: String(title) });
    },
    /** panel.set_dirty {dirty} */
    setDirty(dirty) {
      return call("panel.set_dirty", { dirty: Boolean(dirty) });
    },
    /**
     * panel.state_changed {state}: native keeps the latest state for the session
     * snapshot and "recently closed". Rejects with invalid_params above 64 KiB.
     */
    setState(state) {
      const value = state === undefined ? null : state;
      let json;
      try {
        json = encode(value, "panel.state_changed");
      } catch (err) {
        return Promise.reject(err);
      }
      const bytes = encoder ? encoder.encode(json).length : json.length * 3;
      if (bytes > MAX_STATE_BYTES) {
        return Promise.reject(
          new BridgeError(ErrorCode.INVALID_PARAMS, "Panel state exceeds 64 KiB", {
            method: "panel.state_changed",
            data: { bytes, limit: MAX_STATE_BYTES },
          }),
        );
      }
      if (context) context.state = value;
      return call("panel.state_changed", { state: value });
    },
    /** panel.open_external {url}: OS default browser (native applies its URL policy). */
    openExternal(url) {
      return call("panel.open_external", { url: String(url) });
    },
    /** panel.open_in_browser {url}: a wmux browser tab. */
    openInBrowser(url) {
      return call("panel.open_in_browser", { url: String(url) });
    },
    /** panel.open_file {path}: the file-open router. */
    openFile(path) {
      return call("panel.open_file", { path: String(path) });
    },
    /** panel.clipboard_write {text, html?}: only honored within 2 s of a user gesture. */
    clipboardWrite(text, html) {
      const params = { text: String(text) };
      if (html !== undefined && html !== null) params.html = String(html);
      return call("panel.clipboard_write", params);
    },
    /** panel.request_focus */
    requestFocus() {
      return call("panel.request_focus", {});
    },
    /** panel.key_capture {on}: the KeyRouter skips this panel while on (shortcut recorders). */
    keyCapture(on) {
      return call("panel.key_capture", { on: Boolean(on) });
    },
    /** panel.subscribe {categories}: event categories delivered as "cmux.event". */
    subscribe(categories) {
      const list = Array.isArray(categories) ? categories : [categories];
      return call("panel.subscribe", { categories: list.map(String) });
    },
    /** panel.notify {title, body?} */
    notify(title, body) {
      const params = { title: String(title) };
      if (body !== undefined && body !== null) params.body = String(body);
      return call("panel.notify", params);
    },
  });

  const bridge = {
    PROTOCOL_VERSION,
    ErrorCode,
    WmuxError: BridgeError,
    ready,
    call,
    send,
    on,
    once,
    off,
    panel,
    cmux(method, params, options) {
      return call(method, params, options);
    },
    /** Log traffic to the console (console.debug). */
    setDebug(enabled) {
      debugEnabled = Boolean(enabled);
    },
  };
  Object.defineProperties(bridge, {
    /** True when the page runs inside a WebView2 host (window.chrome.webview exists). */
    available: { enumerable: true, get: () => webview !== null },
    /** The panel.init payload, or null before it arrives. Treat as read-only. */
    context: { enumerable: true, get: () => context },
    /** The latest theme payload (from panel.init or a "theme" event), or null. */
    theme: { enumerable: true, get: () => theme },
    /** Number of calls waiting for a reply (diagnostics). */
    pendingCount: { enumerable: true, get: () => pending.size },
  });

  if (webview) webview.addEventListener("message", onMessage);
  return Object.freeze(bridge);
}

function findWebview() {
  const chromeObj = globalThis.chrome;
  const webview = chromeObj ? chromeObj.webview : null;
  if (
    webview &&
    typeof webview.postMessage === "function" &&
    typeof webview.addEventListener === "function"
  ) {
    return webview;
  }
  return null;
}

function isInitPayload(value) {
  return Boolean(value) && typeof value === "object" && typeof value.kind === "string";
}

function resolveTimeout(value, fallback) {
  if (value === undefined || value === null) return fallback;
  if (value === 0 || value === Infinity) return 0;
  if (typeof value !== "number" || !(value > 0)) return fallback;
  return Math.min(Math.ceil(value), MAX_TIMER_MS);
}

function errorText(err) {
  if (err && typeof err.message === "string") return err.message;
  return String(err);
}

function errorFromWire(error, method) {
  if (!error || typeof error !== "object") {
    return new BridgeError(
      ErrorCode.INTERNAL_ERROR,
      "Malformed error reply from the wmux host",
      { method },
    );
  }
  const code =
    typeof error.code === "string" && error.code !== ""
      ? error.code
      : ErrorCode.INTERNAL_ERROR;
  const message =
    typeof error.message === "string" && error.message !== "" ? error.message : code;
  return new BridgeError(code, message, {
    data: error.data,
    reason: error.reason,
    action: error.action,
    details: error.details,
    method,
  });
}

function unavailableError(method) {
  return new BridgeError(
    ErrorCode.UNAVAILABLE,
    "The wmux bridge is not available (the page is not hosted in a wmux web panel)",
    { method },
  );
}

function cancelledError(method) {
  return new BridgeError(ErrorCode.CANCELLED, "Request cancelled", { method });
}

function timeoutError(method, deadlineMs) {
  return new BridgeError(
    ErrorCode.TIMEOUT,
    "Timed out waiting for a reply to " + method,
    { method, data: { stage: "bridge", deadline_ms: deadlineMs, retryable: false } },
  );
}
