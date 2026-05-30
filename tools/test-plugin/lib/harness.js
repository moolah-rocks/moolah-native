// Harness for Moolah import plugins. Loads `Plugins/_shared/*.js` and a single
// plugin's `Plugins/<host>/parser.js` into a fresh jsdom window, evaluates the
// plugin class, and invokes its `run(args)` method with a mock
// `completionFunction`. Resolves with whatever payload the plugin emits (or
// rejects if the plugin throws / never completes within a timeout).

import { readFileSync, readdirSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "../../..");
const SHARED_DIR = path.join(REPO, "Plugins", "_shared");

const DEFAULT_TIMEOUT_MS = 5000;
const FROZEN_CAPTURED_AT = "2026-05-30T08:00:00.000Z";

function readSharedScripts() {
  if (!existsSync(SHARED_DIR)) return [];
  return readdirSync(SHARED_DIR)
    .filter((f) => f.endsWith(".js"))
    .sort()
    .map((f) => readFileSync(path.join(SHARED_DIR, f), "utf8"));
}

function deriveClassName(file) {
  // Mirrors PluginManifestGen.JSBundleEmitter.className(for:).
  const host = path.dirname(file);
  const firstSegment = host.split(".")[0] ?? "Plugin";
  const cleaned = firstSegment.replace(/[^A-Za-z0-9]/g, "");
  if (!cleaned) return "PluginImporter";
  return cleaned[0].toUpperCase() + cleaned.slice(1) + "Importer";
}

/**
 * Run a plugin against an HTML fixture.
 * @param {object} options
 * @param {string} options.html        HTML to load into jsdom.
 * @param {string} options.parserSource  JS source of the plugin (the
 *   `class XImporter { ... }` block).
 * @param {string} options.className   Class name to instantiate (e.g.
 *   "MacquarieImporter"). Use `deriveClassName(file)`.
 * @param {string} options.sourceURL   URL the page is served from (jsdom
 *   uses this for `location.host` / `location.href`).
 * @param {number} [options.timeoutMs] Max time to wait for
 *   `completionFunction`. Defaults to 5 s.
 * @returns {Promise<object>} Resolves to the payload (or `{error: ...}`
 *   if the plugin signals one).
 */
export async function runPlugin({
  html,
  parserSource,
  className,
  sourceURL,
  timeoutMs = DEFAULT_TIMEOUT_MS,
}) {
  const dom = new JSDOM(html, {
    url: sourceURL,
    runScripts: "outside-only",
    pretendToBeVisual: true,
  });

  // Freeze Date so `capturedAt: new Date().toISOString()` is reproducible.
  // Plugins should not rely on Date arithmetic against `Date.now()`; we
  // freeze the wall clock but leave `Date.now()` itself returning the
  // frozen timestamp, which is enough for "current year" inference.
  const frozenMs = Date.parse(FROZEN_CAPTURED_AT);
  dom.window.eval(`
    (function () {
      const Real = Date;
      function FrozenDate(...args) {
        if (args.length === 0) return new Real(${frozenMs});
        return new Real(...args);
      }
      FrozenDate.now = () => ${frozenMs};
      FrozenDate.parse = Real.parse;
      FrozenDate.UTC = Real.UTC;
      FrozenDate.prototype = Real.prototype;
      Object.setPrototypeOf(FrozenDate, Real);
      globalThis.Date = FrozenDate;
    })();
  `);

  // Shared scripts may attach themselves to `window` (e.g. via an IIFE
  // setting `window.MoolahConventions`). They're safe to eval one at a
  // time.
  for (const src of readSharedScripts()) {
    dom.window.eval(src);
  }

  // `class X {}` at top level of an eval() creates a lexically-scoped
  // class that does NOT become a property of `window`. To make the
  // plugin's class callable from a subsequent eval, we evaluate the
  // parser source PLUS a small expose snippet in a single eval — the
  // snippet runs within the same lexical scope as the class declaration
  // and assigns it to globalThis. Mirrors how the production Safari
  // bundle concatenates everything into one script so the dispatcher
  // can reference plugin classes by bare identifier.
  const expose = `try { globalThis.${className} = ${className}; } catch (e) { throw new Error("class ${className} not defined: " + e.message); }`;
  dom.window.eval(`${parserSource}\n;${expose}`);

  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`plugin ${className}.run did not call completionFunction within ${timeoutMs}ms`));
    }, timeoutMs);

    const args = {
      completionFunction: (payload) => {
        clearTimeout(timer);
        // Round-trip through JSON so we resolve a plain object (jsdom
        // sometimes returns proxies).
        try {
          resolve(JSON.parse(JSON.stringify(payload)));
        } catch (err) {
          reject(err);
        }
      },
    };

    try {
      const Importer = dom.window[className];
      if (typeof Importer !== "function") {
        throw new Error(`plugin class ${className} not defined in parser source`);
      }
      new Importer().run(args);
    } catch (err) {
      clearTimeout(timer);
      reject(err);
    }
  });
}

export { deriveClassName, FROZEN_CAPTURED_AT };
