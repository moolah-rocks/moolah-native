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
