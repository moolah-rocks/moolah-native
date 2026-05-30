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
