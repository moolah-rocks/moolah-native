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
