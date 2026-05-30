# Import Plugin Guide

How to add or maintain a per-bank parser for Moolah's Safari Action
Extension. Each plugin is one JS file plus one manifest row plus one
sanitised fixture plus one expected-output file. End-to-end build and
test runs locally without Safari.

## What a plugin is

A plugin is a JavaScript class that extracts transaction rows from a
bank's logged-in web page. Safari injects all plugins into the page
when the user taps **Share → Import to Moolah**; the dispatcher
(`MoolahImportExtension_Shared/Resources/extension-entry.js`) picks
the right plugin by hostname and calls its `run(args)` method. The
plugin reads the DOM, builds an `ImportPayload`, and hands it back via
`args.completionFunction(payload)`. The extension serialises the
payload to JSON in the App Group inbox; the main app's deep-link
handler consumes it through the same review pipeline that handles
CSV imports.

There is no network access, no keychain access, no DOM mutation, no
remote code. Every plugin ships through TestFlight + App Store review.

## File layout per plugin

```
Plugins/
├── plugins.json                    # manifest index — one row per page
├── _shared/conventions.js          # shared helpers (MoolahConventions)
└── <host>/
    └── parser.js                   # the plugin class

tools/test-plugin/
└── fixtures/<host>/
    ├── <scenario>.sanitise.yml     # redaction config (committed)
    ├── <scenario>.html             # synthetic fixture (committed)
    └── <scenario>.expected.json    # expected ImportPayload (committed)
```

The `host` in the manifest is the parent domain (e.g.
`commbank.com.au`, not `www.commbank.com.au`). The framework's
dotted-suffix activation rule matches the parent and any subdomain,
which both keeps class names readable and lets one plugin handle
`www.commbank.com.au`, `online.commbank.com.au`, etc.

## The payload contract

Defined in
`Modules/ImportExtensionKit/Sources/ImportExtensionKit/ImportPayload.swift`.
At a glance:

```ts
type ImportPayload = {
  schemaVersion: 1,
  sourceHost: string,         // location.host
  sourceURL: string,          // location.href — query/fragment stripped by the framework
  capturedAt: string,         // new Date().toISOString()
  accountHint: string | null, // free-form mask / last-4 — used to match an account
  currencyHint: string | null,// "AUD", "USD", … — picked by the parser
  rows: ImportPayloadRow[],
}

type ImportPayloadRow = {
  date: string,           // "YYYY-MM-DD"
  amount: string,         // signed magnitude, e.g. "-12.50" or "200.00"
  description: string,
  balance: string | null,
  reference: string | null,
}
```

Notes:

- **`date`** is a STRING in `YYYY-MM-DD` form, not a `Date`. The
  framework parses it on the Swift side. Use
  `MoolahConventions.inferYearForDayMonth(...)` if the page only
  shows day + month.
- **`amount`** is a STRING with the on-page sign — outflows negative,
  inflows positive (a checkbook view). The Swift import pipeline does
  any per-account-type adjustment.
- **`balance`** is the running balance after the transaction, when the
  page shows it. `null` is fine. Currency context isn't included; the
  parser's `currencyHint` describes both.
- **`reference`** is a stable per-row id when the page exposes one
  (`data-txn-id`, `data-transaction-ref`, etc.) — used as a dedup
  hint by the import pipeline. `null` is fine.

## Shared helpers — `MoolahConventions`

`Plugins/_shared/conventions.js` exposes a small set of pure helpers
on `window.MoolahConventions`. Every parser should use these instead
of hand-rolling its own logic:

| Helper | Use |
|---|---|
| `parseAmount(text)` | Strip currency / commas / whitespace → `"-1234.56"` |
| `signedAmount(text, { isCredit })` | Same, but prefix `-` when `isCredit` and no on-page sign |
| `inferYearForDayMonth(dayMonth, statementPeriod)` | `"30 May"` + optional `"Since … 2026"` → `"2026-05-30"` |
| `parseDayMonthYear(text)` | Handles `YYYY-MM-DD`, `DD/MM/YYYY`, `DD Mon YYYY`, `DD Mon` |
| `canonicaliseDescription(text)` | Trim, collapse whitespace, drop trailing `Pending`/`Credit` badges |
| `last4(text)` | Trailing 4-digit group, for `accountHint` |
| `findRowsAcrossSameOriginFrames(root, selector)` | Falls through to same-origin iframes when the top frame has no rows |

Adding a new helper goes in `conventions.js`; codegen rebuilds the JS
bundle automatically so the runtime extension picks it up.

## Authoring checklist

1. Save the bank page to `~/Downloads/Moolah Sites/<host>.webarchive`.
   Sanitised HTML lives in the repo; raw webarchives never do.
2. `python3 tools/test-plugin/extract_webarchive.py
   ~/Downloads/Moolah\ Sites/<host>.webarchive
   ~/Downloads/Moolah\ Sites/<host>.html`.
3. Write `tools/test-plugin/fixtures/<host>/recent.sanitise.yml`:
   - `source:` → the local HTML path (use `~` for `$HOME`).
   - `synthetic_url:` → the synthetic URL the harness uses for
     `location.href` (e.g. `https://<host>/dashboard`).
   - `keep_classes:` → every CSS class the parser depends on (these
     survive the CSS-in-JS-hash sweep).
   - `merchant_selectors`, `amount_selectors`, `date_selectors`,
     `account_hint_selectors` → selectors that the synthesiser
     replaces with deterministic fake data.
   - `strip_selectors:` → tags or classes whose subtree is dropped
     (account banners, scheduled-payment lists, avatars, chrome).
4. Run `python3 tools/test-plugin/sanitise.py
   tools/test-plugin/fixtures/<host>/recent.sanitise.yml`. Output is
   `recent.html` next to the YAML.
5. Write `Plugins/<host>/parser.js`. The class name is derived from
   the host's first segment — `commbank.com.au` →
   `CommbankImporter`. Mirror the reference implementation at
   `Plugins/macquarie.com.au/parser.js`.
6. Add a manifest row to `Plugins/plugins.json`:
   ```jsonc
   {
     "host": "commbank.com.au",
     "pathPrefix": "/retail/netbank",
     "file": "commbank.com.au/parser.js",
     "displayName": "CommBank",
     "emptyHint": "Open one of your accounts to see transactions before importing."
   }
   ```
7. `just plugin-test`. On the first run there's no `expected.json`
   yet — capture the harness output and commit it as the expected:
   ```sh
   node tools/test-plugin/run.js <host> > /tmp/actual.txt   # see what comes out
   # ...audit the rows, then:
   node --input-type=module -e "<small inline script>" \
     > tools/test-plugin/fixtures/<host>/recent.expected.json
   ```
   Then `just plugin-test` again until green.
8. `just generate` to rebuild the JS bundle and the
   `BundledPlugins.all` Swift table.
9. `just format` and `just test`.

## Multiple pages per bank

A single parser can serve more than one URL — give it two manifest
rows that share `file` and `host` but differ in `pathPrefix`:

```jsonc
{
  "host": "americanexpress.com",
  "pathPrefix": "/dashboard",
  "file": "americanexpress.com/parser.js",
  "displayName": "Amex",
  "emptyHint": "This page should show recent transactions. Try refreshing."
},
{
  "host": "americanexpress.com",
  "pathPrefix": "/activity",
  "file": "americanexpress.com/parser.js",
  "displayName": "Amex"
}
```

`JSBundleEmitter` dedupes the dispatch map (one entry per
host+className) and the parser source (appended once). The activation
predicate ORs the two clauses so Safari offers the action on both
pages.

## Sign convention — checkbook style

Each plugin emits amounts as the user mentally records them:

- Outflow (purchase on card, withdrawal from deposit) → **negative**.
- Inflow (payment received on card, deposit) → **positive**.

The Swift side passes the sign through verbatim. The user's chosen
Moolah account during import dictates how the sign maps to debit /
credit at the storage layer — the parser does **not** need to know
the account type.

For pages that don't make the sign explicit:

- **CSS class indicates outflow** (Macquarie's `.minus`): prefix `-`
  in the parser when the class is present.
- **CSS class indicates inflow** (`.credit`, `.deposit`): leave the
  amount positive. (The class is informational; never trust just
  colour.)
- **`-` already in the text** (Amex `-$2,381.02` for a payment
  received): keep it as-is — `parseAmount` preserves the sign.
- **Nothing indicates direction**: the parser is on the wrong
  selector; pick one that scopes to a single direction.

## Date convention

`YYYY-MM-DD` strings, period. If the page omits the year:

- Use the statement period (`"Since 23 May 2026. Closing 22 Jun
  2026"`) when present — pass it to
  `MoolahConventions.inferYearForDayMonth(dayMonth, statementText)`.
- Otherwise fall back to "current year, rolled back one if that puts
  the date in the future" — also handled by the helper when you pass
  `null` for `statementPeriod`.

## Empty-state copy — `emptyHint`

When the parser returns `rows: []`, the extension's confirmation
sheet shows the plugin's `emptyHint` instead of the generic message.
Make it specific: tell the user *what they need to do* to get rows.
Examples:

- "Open one of your accounts to see transactions before importing."
- "Make sure you're on the Account Activity page (not the dashboard)."
- "Clear the date filter — this view only shows pending transactions."

If `emptyHint` is omitted, the framework's default applies.

## Privacy

- Repo never contains real bank-page bytes. Source webarchives stay
  in `~/Downloads/Moolah Sites/` (or wherever the contributor keeps
  them) — outside the repo.
- Fixtures are **regenerations** (synthetic merchants, synthetic
  amounts, synthetic dates), not redactions. Even the sanitised HTML
  carries no real data.
- The extension's `os_log` records structural facts only
  (`host=commbank.com.au rows=24`), never amounts or descriptions.

## When the bank changes its site

Two failure modes:

- **Selector misses, returns zero rows.** Activation rule still
  matches; user sees the empty-state copy (which is why `emptyHint`
  matters). Fix: re-save the page, re-run sanitise, update selectors
  in the parser, push a PR.
- **URL pattern changes.** Activation rule stops matching; the
  extension simply doesn't appear in Share. Fix: update `pathPrefix`
  in `plugins.json`.

In both cases the user's existing data is untouched and the regular
CSV import path remains available.

## Reference plugin

`Plugins/macquarie.com.au/parser.js`. Copy and adapt.
