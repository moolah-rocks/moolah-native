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
