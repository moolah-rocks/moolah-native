// Single NSExtensionJavaScriptPreprocessingFile loaded by Safari for the
// Moolah action extension. PluginManifestGen concatenates each plugin's
// `parser.js` after this file and rewrites the `const plugins = {};`
// declaration below to map host strings to plugin classes.
//
// DO NOT rename the marker comments — `JSBundleEmitter` matches them
// literally.

class MoolahDispatch {
  run(args) {
    const host = location.host;
    // The build step appends each plugin class and replaces this map.
    /* GENERATED-PLUGIN-MAP-START */
    const plugins = { "macquarie.com.au": MacquarieImporter, "hsbc.com.au": HsbcImporter, "commbank.com.au": CommbankImporter, "americanexpress.com": AmericanexpressImporter };
    /* GENERATED-PLUGIN-MAP-END */
    const match = Object.entries(plugins).find(
      ([h]) => host === h || host.endsWith("." + h));
    if (!match) { args.completionFunction({ error: "no-plugin", host }); return; }
    new match[1]().run(args);
  }
  finalize(args) { /* unused */ }
}
var ExtensionPreprocessingJS = new MoolahDispatch();


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


// Plugins/macquarie.com.au/parser.js
//
// Macquarie Bank (online.macquarie.com.au) transaction-list importer.
//
// Scrapes the visible transaction rows under `<pb-transaction-list>`
// (the real-transactions component — `<pb-scheduled-transaction-list>`
// uses the same row class but represents future-dated scheduled
// payments which should NOT be imported). The Angular markup is
// verbose but stable: each row is one
// `<tr class="mq-table-basic__body-row">` with five cells:
// checkbox, date ("D MMM"), description, amount, balance.
//
// Sign convention: this is a deposit account. Outflows have an explicit
// `<span class="minus">` wrapper on the amount; inflows do not. We emit
// outflows as negative, inflows as positive — the user's checkbook
// view. The Swift import pipeline propagates the sign as-is.

class MacquarieImporter {
  run(args) {
    const list = document.querySelector("pb-transaction-list");
    const rowEls = list
      ? [...list.querySelectorAll("tr.mq-table-basic__body-row")]
      : [];

    const rows = rowEls.map(parseRow).filter((row) => row !== null);

    args.completionFunction({
      schemaVersion: 1,
      sourceHost: location.host,
      sourceURL: location.href,
      capturedAt: new Date().toISOString(),
      accountHint: extractAccountHint(),
      currencyHint: "AUD",
      rows,
    });

    function parseRow(tr) {
      const cells = tr.querySelectorAll("td");
      if (cells.length < 5) return null;

      const date = MoolahConventions.inferYearForDayMonth(
        cells[1].textContent, null);
      if (!date) return null;

      const descNode = cells[2].querySelector(".txn-list-component__fading-overflow");
      const description = descNode
        ? MoolahConventions.canonicaliseDescription(descNode.textContent)
        : "";

      const amountSpan = cells[3].querySelector("span");
      if (!amountSpan) return null;
      const magnitude = MoolahConventions.parseAmount(amountSpan.textContent);
      if (magnitude == null) return null;
      const isOutflow = amountSpan.classList.contains("minus");
      const amount = isOutflow && !magnitude.startsWith("-")
        ? "-" + magnitude
        : magnitude;

      const balanceNode = cells[4].querySelector(".balance");
      const balance = balanceNode
        ? MoolahConventions.parseAmount(balanceNode.textContent)
        : null;

      return { date, amount, description, balance, reference: null };
    }

    function extractAccountHint() {
      const cardEnding = document.querySelector(
        "[data-testid='account-banner-personal-account-card-ending']");
      return MoolahConventions.last4(cardEnding?.textContent ?? null);
    }
  }

  finalize(args) {
    /* unused — Macquarie plugin does not mutate the page */
  }
}


// Plugins/hsbc.com.au/parser.js — DRAFT for PR 2
//
// HSBC Australia Internet Banking — credit card transactions list.
//
// The page uses the dojo `gridx` widget: each row is a
// `<div class="gridxRow" role="row" rowid="N">` wrapping a single-row
// `<table class="gridxRowTable">` whose cells carry `colid="..."`. We
// pick by `colid`:
//   colDate       — transaction (purchase) date — blank until posting
//   colDate1      — posting date (e.g. "30 May 2026") — what we use
//   colPayees     — `payeeItem0` spans with merchant text
//   colAmount     — unsigned charge or "-..." credit
//
// Sign convention: HSBC is a credit-card view.
//   - Bare positive amount → a charge (outflow on the card) → emit as
//     negative for the checkbook view.
//   - Text-negative amount → a payment / credit (inflow) → emit positive.
// (The Swift import pipeline propagates the sign — it does not know the
// account type at parse time.)

class HsbcImporter {
  run(args) {
    const rowEls = [...document.querySelectorAll(".gridxRow[role='row']")];
    const rows = rowEls.map(parseRow).filter((row) => row !== null);

    args.completionFunction({
      schemaVersion: 1,
      sourceHost: location.host,
      sourceURL: location.href,
      capturedAt: new Date().toISOString(),
      accountHint: extractAccountHint(),
      currencyHint: "AUD",
      rows,
    });

    function parseRow(div) {
      const cells = div.querySelectorAll("td[colid]");
      if (cells.length === 0) return null;

      const dateCell = pickCell(cells, ["colDate1", "colDate"]);
      const dateText = dateCell ? MoolahConventions.trim(dateCell.textContent) : "";
      const date = MoolahConventions.parseDayMonthYear(dateText);
      if (!date) return null;

      const payeeCell = pickCell(cells, ["colPayees"]);
      const payeeItems = payeeCell
        ? [...payeeCell.querySelectorAll(".payeeItem0")].map((s) => s.textContent)
        : [];
      const description = MoolahConventions.canonicaliseDescription(payeeItems.join(" "));

      const amountCell = pickCell(cells, ["colAmount"]);
      const raw = amountCell
        ? MoolahConventions.parseAmount(amountCell.textContent)
        : null;
      if (raw == null) return null;
      // Invert sign: page-positive = charge → checkbook-negative; page-negative
      // = credit → checkbook-positive.
      const amount = raw.startsWith("-") ? raw.slice(1) : "-" + raw;

      return { date, amount, description, balance: null, reference: null };
    }

    function pickCell(cells, colids) {
      for (const colid of colids) {
        for (const cell of cells) {
          if (cell.getAttribute("colid") === colid) return cell;
        }
      }
      return null;
    }

    function extractAccountHint() {
      const node = document.querySelector("[data-account-number]");
      if (!node) return null;
      return MoolahConventions.last4(node.getAttribute("data-account-number"));
    }
  }

  finalize(args) {
    /* unused — HSBC plugin does not mutate the page */
  }
}


// Plugins/commbank.com.au/parser.js — DRAFT for PR 3
//
// Commonwealth Bank Netbank — account transactions list. Deposit
// account.
//
// Each row is `<tr class="transaction-item">` with:
//   <th class="transaction-item__date">      "Sat 25 Apr 2026"
//   <td class="transaction-item__short-details">
//     <div class="transaction-item__description">  free-text payee
//   <td class="transaction-item__amounts">
//     <span class="transaction-item__amounts__debit">  ← present for outflow
//       <span class="transaction-item__amounts__debit__text">-$20,441.38
//     <span class="transaction-item__amounts__credit">  ← present for inflow
//       <span class="transaction-item__amounts__credit__text">+$245.00
//     <span class="transaction-item__amounts__balance">balance: $705.89
//
// CommBank renders one of debit/credit per row (the other is empty).
// Debits are text-negative; credits are text-positive with a "+"
// prefix. We preserve the on-page sign for the checkbook view.

class CommbankImporter {
  run(args) {
    const rowEls = [...document.querySelectorAll("tr.transaction-item")];
    const rows = rowEls.map(parseRow).filter((row) => row !== null);

    args.completionFunction({
      schemaVersion: 1,
      sourceHost: location.host,
      sourceURL: location.href,
      capturedAt: new Date().toISOString(),
      accountHint: null,
      currencyHint: "AUD",
      rows,
    });

    function parseRow(tr) {
      const dateNode = tr.querySelector(".transaction-item__date");
      if (!dateNode) return null;
      const date = MoolahConventions.parseDayMonthYear(dateNode.textContent);
      if (!date) return null;

      const descNode = tr.querySelector(".transaction-item__description");
      const description = descNode
        ? MoolahConventions.canonicaliseDescription(descNode.textContent)
        : "";

      // Pick whichever of debit / credit has content.
      const debitText = textOrNull(tr.querySelector(".transaction-item__amounts__debit__text"));
      const creditText = textOrNull(tr.querySelector(".transaction-item__amounts__credit__text"));
      const amountText = debitText ?? creditText;
      if (amountText == null) return null;
      const amount = MoolahConventions.parseAmount(amountText);
      if (amount == null) return null;

      const balanceNode = tr.querySelector(".transaction-item__amounts__balance");
      const balanceText = balanceNode
        ? balanceNode.textContent.replace(/^.*?balance[:\s]*/i, "")
        : null;
      const balance = balanceText ? MoolahConventions.parseAmount(balanceText) : null;

      return { date, amount, description, balance, reference: null };
    }

    function textOrNull(node) {
      if (!node) return null;
      const text = node.textContent.trim();
      return text ? text : null;
    }
  }

  finalize(args) {
    /* unused — CommBank plugin does not mutate the page */
  }
}


// Plugins/americanexpress.com/parser.js
//
// American Express (`global.americanexpress.com`) transaction importer.
// Handles both the Dashboard's recent-activity widget (`/dashboard`)
// and the full account-activity page (`/activity`). One parser, two
// manifest rows.
//
// Both pages render rows as `<tr>` whose class contains `_dataRow_`
// (the obfuscated class name varies between the two views but always
// has the `_dataRow_` prefix). Within each row the parser picks:
//
//   • Date — the first `<td>` text, formatted "DD Mon" (no year). We
//     resolve the year from the visible statement-period banner when
//     present, falling back to "current year, rolling back one if
//     the date would be in the future".
//   • Status — optional badge ("Pending" / "Credit") in the second
//     cell. Used as a tie-breaker for the sign convention.
//   • Description — the row's `<a>` text.
//   • Amount — the row's final `<p>` text in the form `$X.XX` for
//     charges and `-$X.XX` for credits.
//
// Sign convention: Amex is a credit-card account. Charges show
// page-positive; the parser emits negative (outflow). Credits /
// payments-received show page-negative; the parser emits positive
// (inflow). Both transformations are achieved by inverting the
// on-page sign.

class AmericanexpressImporter {
  run(args) {
    const rowEls = [...document.querySelectorAll("tr")].filter(
      (tr) => /(^|\s)_dataRow_/.test(tr.className));

    const statementPeriod = document.body
      ? document.body.textContent.match(/Since\s+\d{1,2}\s+\w+\s+(20\d{2})/)?.[0] ?? null
      : null;

    const rows = rowEls.map((tr) => parseRow(tr, statementPeriod)).filter((r) => r !== null);

    args.completionFunction({
      schemaVersion: 1,
      sourceHost: location.host,
      sourceURL: location.href,
      capturedAt: new Date().toISOString(),
      accountHint: extractAccountHint(),
      currencyHint: "AUD",
      rows,
    });

    function parseRow(tr, statementPeriod) {
      // Date — first td's body text, e.g. "30 May" (may have a
      // sibling "Pending" / "Credit" badge cell).
      const cells = tr.querySelectorAll("td");
      if (cells.length < 2) return null;
      const dateText = firstTextMatching(
        cells[0], /\b\d{1,2}\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\b/);
      const date = dateText
        ? MoolahConventions.inferYearForDayMonth(dateText, statementPeriod)
        : null;
      if (!date) return null;

      const anchor = tr.querySelector("a");
      const description = anchor
        ? MoolahConventions.canonicaliseDescription(anchor.textContent)
        : "";

      // Amount — the row's <p> whose text matches a currency shape.
      // Activity page wraps it in a <p>; dashboard also uses <p>.
      const amountNode = [...tr.querySelectorAll("p")].find((p) =>
        /-?\$[\d,]+\.\d{2}/.test(p.textContent));
      if (!amountNode) return null;
      const raw = MoolahConventions.parseAmount(amountNode.textContent);
      if (raw == null) return null;
      // Invert sign: page-positive (charge) → negative; page-negative
      // (credit / payment received) → positive.
      const amount = raw.startsWith("-") ? raw.slice(1) : "-" + raw;

      // Reference — `data-testid` carries a stable id on the activity
      // page (`transaction-row-<id>`). Strip the prefix.
      const testid = tr.getAttribute("data-testid");
      const reference = testid && testid.startsWith("transaction-row-")
        ? testid.slice("transaction-row-".length)
        : null;

      return { date, amount, description, balance: null, reference };
    }

    function extractAccountHint() {
      // Dashboard / activity both show a card-ending suffix in the
      // header area, e.g. "-43002". Search the document for that
      // shape and return the digits.
      const text = document.body ? document.body.textContent : "";
      const m = text.match(/-(\d{4,6})\b/);
      return m ? m[1].slice(-4) : null;
    }

    function firstTextMatching(root, regex) {
      // Walk text nodes in order until one matches `regex`; return the
      // matched substring.
      const walker = (root.ownerDocument || document)
        .createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
      let node = walker.nextNode();
      while (node) {
        const m = node.textContent.match(regex);
        if (m) return m[0];
        node = walker.nextNode();
      }
      return null;
    }
  }

  finalize(args) {
    /* unused — Amex plugin does not mutate the page */
  }
}
