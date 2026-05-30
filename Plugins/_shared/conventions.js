// Plugins/_shared/conventions.js
//
// Single source of truth for cross-plugin helpers.
//
// PluginManifestGen prepends every `.js` file under `Plugins/_shared/`
// (sorted by filename, deterministic) to the Safari Action Extension's JS
// bundle, between the dispatcher and the per-plugin parser sources. The
// `tools/test-plugin` Node harness loads the same file into jsdom before
// it evaluates a plugin. So everything declared here is available to
// every plugin at both runtime and test time as `window.MoolahConventions`.
//
// Keep this file small and defensive. A bug here breaks every bank.
//
// Conventions:
//
//   • Returned amounts are STRINGS shaped like `"-1234.56"` (no currency
//     symbol, no thousands separator). Parsers should not pre-flip the
//     sign for account-type semantics — the Swift import pipeline does
//     that once the user picks a Moolah account.
//
//   • Returned dates are STRINGS shaped like `"YYYY-MM-DD"`.
//
//   • All helpers are pure functions. No I/O, no globals, no Date.now()
//     other than via the value passed in (year inference takes `now`
//     explicitly so tests can pin it).

(function (global) {
  "use strict";

  const MONTHS_SHORT = {
    jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6,
    jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12,
  };

  const MONTHS_LONG = {
    january: 1, february: 2, march: 3, april: 4, may: 5, june: 6,
    july: 7, august: 8, september: 9, october: 10, november: 11, december: 12,
  };

  /** Trim whitespace including non-breaking-space (U+00A0). */
  function trim(text) {
    if (text == null) return "";
    return String(text).replace(/[\s ]+/g, " ").trim();
  }

  /** Collapse internal whitespace runs to a single space, trim ends, drop
   * trailing "Pending" / "Credit" badges if they're isolated tokens. */
  function canonicaliseDescription(text) {
    const collapsed = trim(text);
    return collapsed.replace(/\s+(Pending|Credit|Posted)$/i, "").trim();
  }

  /** Extract a trailing 4-digit group. Returns null if none present. */
  function last4(text) {
    if (text == null) return null;
    const m = String(text).match(/(\d{4})(?!.*\d)/);
    return m ? m[1] : null;
  }

  /** Parse an amount string into the canonical form, preserving the
   * on-page sign. Strips currency symbols, thousands separators, and
   * incidental whitespace. Returns null if no parseable number was
   * found. */
  function parseAmount(text) {
    if (text == null) return null;
    const t = trim(text);
    if (!t) return null;
    // Strip currency symbols and letters; keep digits, sign, dot, comma.
    const m = t.match(/-?\d[\d,]*\.?\d*/);
    if (!m) return null;
    const sign = /[−-]/.test(t.slice(0, t.indexOf(m[0]))) || m[0].startsWith("-")
      ? "-"
      : "";
    const cleaned = m[0].replace(/[-,]/g, "");
    if (!cleaned) return null;
    return sign + cleaned;
  }

  /** Parse an amount, applying sign-flipping when the caller knows the
   * row represents an inflow (refund, payment received on a card). If
   * `isCredit` is true and the parsed amount has no explicit sign, a
   * leading `-` is added so the import pipeline sees the row as a
   * negative-on-card / positive-on-deposit value. */
  function signedAmount(text, { isCredit = false } = {}) {
    const raw = parseAmount(text);
    if (raw == null) return null;
    if (raw.startsWith("-")) return raw;
    return isCredit ? "-" + raw : raw;
  }

  /** Resolve a partial date like "30 May" to a full ISO date.
   *
   * - statementPeriod: optional text containing a YYYY anchor
   *   ("Since 23 May 2026. Closing 22 Jun 2026"). If present and a year
   *   is found, that year is used.
   * - now: a Date used for the "fall back to current year, rolling back
   *   one year if the result is in the future" rule. Defaults to
   *   `new Date()`.
   */
  function inferYearForDayMonth(dayMonth, statementPeriod, now) {
    const dm = parseDayMonth(dayMonth);
    if (!dm) return null;
    const year = extractYear(statementPeriod) ?? rollbackYear(dm.month, dm.day, now);
    return isoDate(year, dm.month, dm.day);
  }

  /** Parse any of: YYYY-MM-DD | DD/MM/YYYY | D Mon YYYY | D Mon. Returns
   * an ISO date string or null. For partial inputs (no year), uses
   * `now`-based rollback rule. */
  function parseDayMonthYear(text, now) {
    if (text == null) return null;
    const t = trim(text);
    let m = t.match(/(\d{4})-(\d{1,2})-(\d{1,2})/);
    if (m) return isoDate(+m[1], +m[2], +m[3]);
    m = t.match(/(\d{1,2})\/(\d{1,2})\/(\d{4})/);
    if (m) return isoDate(+m[3], +m[2], +m[1]);
    m = t.match(/(\d{1,2})\s+([A-Za-z]+)\s+(\d{4})/);
    if (m) {
      const mon = monthNumber(m[2]);
      if (mon) return isoDate(+m[3], mon, +m[1]);
    }
    m = t.match(/(\d{1,2})\s+([A-Za-z]+)/);
    if (m) {
      const mon = monthNumber(m[2]);
      if (mon) return isoDate(rollbackYear(mon, +m[1], now), mon, +m[1]);
    }
    return null;
  }

  /** Search the descendants of `root` (and its same-origin iframes) for
   * elements matching `selector`. Returns the first non-empty result
   * set. Used by parsers for banks whose transaction list lives in an
   * iframe (same-origin only — cross-origin iframes throw on
   * contentDocument access and are silently skipped). */
  function findRowsAcrossSameOriginFrames(root, selector) {
    const top = [...root.querySelectorAll(selector)];
    if (top.length > 0) return top;
    const iframes = [...root.querySelectorAll("iframe")];
    for (const frame of iframes) {
      let doc;
      try {
        doc = frame.contentDocument;
      } catch (_err) {
        continue;
      }
      if (!doc) continue;
      const rows = [...doc.querySelectorAll(selector)];
      if (rows.length > 0) return rows;
    }
    return [];
  }

  // --- internals -----------------------------------------------------

  function parseDayMonth(text) {
    if (text == null) return null;
    const t = trim(text);
    const m = t.match(/(\d{1,2})\s+([A-Za-z]+)/);
    if (!m) return null;
    const month = monthNumber(m[2]);
    if (!month) return null;
    return { day: +m[1], month };
  }

  function monthNumber(name) {
    if (!name) return null;
    const key = String(name).toLowerCase();
    return MONTHS_SHORT[key.slice(0, 3)] ?? MONTHS_LONG[key] ?? null;
  }

  function extractYear(statementPeriod) {
    if (!statementPeriod) return null;
    const matches = String(statementPeriod).match(/\b(20\d{2})\b/g);
    if (!matches || matches.length === 0) return null;
    // Prefer the FIRST year that appears — that's the "Since YYYY"
    // anchor (start of the statement period). The closing-date year
    // can roll into the next calendar year.
    return +matches[0];
  }

  function rollbackYear(month, day, now) {
    const today = now ?? new Date();
    const guess = today.getFullYear();
    const candidate = new Date(Date.UTC(guess, month - 1, day));
    const utcToday = new Date(Date.UTC(
      today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate()));
    return candidate > utcToday ? guess - 1 : guess;
  }

  function isoDate(year, month, day) {
    if (!year || !month || !day) return null;
    return `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
  }

  global.MoolahConventions = {
    trim,
    canonicaliseDescription,
    last4,
    parseAmount,
    signedAmount,
    inferYearForDayMonth,
    parseDayMonthYear,
    findRowsAcrossSameOriginFrames,
  };
})(typeof window !== "undefined" ? window : globalThis);
