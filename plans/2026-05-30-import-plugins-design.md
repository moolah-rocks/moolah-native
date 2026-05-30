# Bank Import Plugins — Design

**Date:** 2026-05-30
**Status:** Design (active)
**Depends on:** PR #1014 — Web import Safari Action Extension framework
**Scope:** Per-bank `Plugins/<host>/parser.js` parsers for the first wave of supported sites, plus the authoring infrastructure (fixture-test harness, sanitisation, guide) that future plugins reuse.

---

## Goal

Convert the user's saved bank-page webarchives into shipping plugins for the Safari Action Extension framework. Each plugin is one JS file that extracts the on-page transaction list into an `ImportPayload` for the existing review pipeline. Authoring a new bank stays small (one parser + one fixture + one manifest row).

## Non-goals

- Changing the framework wire shape (`ImportPayload`, deep link, inbox layout) — uses the contract from PR #1014 as-is.
- Multi-step automation (login → date-range → export). Plugins parse what's currently rendered.
- Supporting SPAs where the transaction list is not in the saved DOM. Revolut is **explicitly deferred** until a post-render archive is captured.
- A general parser. Each bank has its own selectors; the harness provides scaffolding, not abstraction.

---

## Banks in scope

| Bank | Host | Pages | Plugin / fixtures |
|---|---|---|---|
| Macquarie | `macquarie.com.au` | `/io` (transactions list) | `MacquarieImporter` — 1 fixture |
| HSBC | `hsbc.com.au` | `/gpib` (dashboard transaction widget) | `HsbcImporter` — 1 fixture |
| CommBank | `commbank.com.au` | `/retail/netbank` (account detail) | `CommbankImporter` — 1 fixture |
| Amex | `americanexpress.com` | `/dashboard` + `/activity` | `AmericanexpressImporter` — 2 fixtures, 2 manifest rows |
| Revolut | — | — | **Out of scope this batch** (SPA shell only; needs post-render archive) |

Host names use the **parent domain** so the framework's existing dotted-suffix match maps `www.commbank.com.au`, `global.americanexpress.com`, etc., to the right plugin. This also makes the generated class names readable (`MacquarieImporter`, not `OnlineImporter`).

---

## PR sequence

| # | Title | Contents |
|---|---|---|
| 1 | `feat(import-ext): plugin authoring foundation + Macquarie reference` | Test harness, sanitisation, guide, framework tweaks, Macquarie plugin |
| 2 | `feat(import-ext): HSBC plugin` | Parser + fixture + manifest |
| 3 | `feat(import-ext): CommBank plugin` | Parser + fixture + manifest |
| 4 | `feat(import-ext): Amex plugin (dashboard + activity)` | Parser + 2 fixtures + 2 manifest rows |

PR 1 stacks on `share-import-extension-design` (PR #1014). PRs 2–4 stack on PR 1 (or branch off `main` once #1014 lands). Each PR enables auto-merge.

---

## Foundation PR — architecture

### `tools/test-plugin/` (Node + jsdom, npm-managed)

```
tools/test-plugin/
├── package.json                 # jsdom + js-yaml + ajv
├── run.js                       # CLI: node run.js [<host>...]
├── lib/
│   ├── harness.js               # Loads parser.js into a jsdom window, awaits completionFunction
│   └── payload-schema.json      # JSON Schema for ImportPayload
├── fixtures/
│   └── <host>/
│       ├── <scenario>.html      # Sanitised HTML
│       ├── <scenario>.expected.json  # Expected ImportPayload
│       └── <scenario>.sanitise.yml   # Sanitise config (selectors, salts)
├── sanitise.py                  # Stand-alone redactor; reads .sanitise.yml + source HTML
└── README.md
```

Shared parser helpers (year inference, amount parsing, etc.) live in
`Plugins/_shared/conventions.js` — single source of truth, used by both
the runtime bundle (via codegen — see framework tweaks) and the test
harness (which loads it into jsdom before the parser).

**Why Node + jsdom (not Bun / Deno / native):** jsdom is the only mature pure-JS DOM; Node ships with macOS dev tools; CI runners already have Node; harness runs each parser in `<200 ms`, no Safari needed. Dependencies pinned in `package-lock.json`.

**`run.js` exit behaviour:** zero exit code only when every fixture's harness output matches its `.expected.json` byte-for-byte (after canonical JSON serialisation). Diff is printed to stderr on mismatch.

### `tools/test-plugin/sanitise.py` (heavy regeneration)

The fixtures committed to the repo are **regenerated synthesisations** of the source pages, not redactions. The source webarchives never enter the repo, not even via git history.

Per-fixture `<scenario>.sanitise.yml`:

```yaml
source: "/path/to/source.html"     # ~/Downloads/Moolah Sites/...
seed: 42                            # deterministic synthesis
keep_classes:                       # CSS classes the parser depends on (kept verbatim)
  - "transaction-row"
  - "amount"
  - "merchant"
merchant_selectors:                 # text → fake-merchant from a fixed list
  - ".merchant"
amount_selectors:                   # text → synthetic signed amount
  - ".amount"
date_selectors:                     # text → re-stamped date in the synthetic window
  - ".posted-date"
account_hint_selectors:             # text → synthetic last-4 / mask
  - ".account-number"
strip_selectors:                    # remove these subtrees entirely
  - "script"
  - "style"
  - "noscript"
  - "svg"
  - "img"
  - "iframe"
  - "[aria-hidden=true]"
```

**Sanitisation rules applied to *every* fixture**, on top of the config:
- Strip all `<script>`, `<style>`, `<noscript>`, `<svg>`, `<img>`, `<iframe>`, `<object>`, `<embed>`, `<link>`, `<meta>`.
- Strip all `id`, `name`, opaque `data-*` (token-like long random strings), `style`, `srcset`, `formaction`, `background`.
- Strip CSS-in-JS class hashes (`/^[a-z]{2,4}-?\d+$/i` and `_jss\d+`, `_emotion-\d+`, etc.); keep only classes listed in `keep_classes` or matching `/^[a-z][-a-z0-9_]{2,40}$/i` after normalisation.
- Strip all HTML comments.
- Replace `href`, `src`, `action` with `#`.
- Replace any remaining text containing `\d{4,}` not handled by a selector rule with `XXXX0000`.
- Replace any remaining text matching the amount regex with synthetic amount.
- Replace any text matching ARIA-style "Transaction $X.XX MERCHANT NAME" with synthetic equivalents.
- Drop all elements whose visible content is empty after sanitisation (keeps fixture small).
- Output: HTML5-serialised, minified, deterministic byte-stable.

Fake-merchant list (cycled deterministically by seed):

```
MERCHANT ALPHA, MERCHANT BRAVO, MERCHANT CHARLIE, MERCHANT DELTA,
MERCHANT ECHO, MERCHANT FOXTROT, MERCHANT GOLF, MERCHANT HOTEL,
MERCHANT INDIA, MERCHANT JULIET, MERCHANT KILO, MERCHANT LIMA
```

Synthetic amounts: drawn from a fixed pool `[12.50, 7.20, 130.00, 42.85, 9.99, 88.30, 5.40, 250.00, 33.15, 18.95]`, signed per row context (debit/credit detected from `amount_selectors` config: a per-config `credit_class: "credit"` flips sign).

Synthetic dates: re-stamped to `[2026-01-05 .. 2026-01-15]`, deterministic by row index + seed.

Synthetic account numbers: `XXXX9999` (8 chars, last 4 randomised by seed); cards: `-99999`.

**Validation:** after sanitising, the script re-parses with the plugin and compares output to a "shape oracle" derived from the source (number of rows, presence of `accountHint`, etc., but not the contents). If shape diverges, the sanitisation is wrong and the script exits non-zero.

### `Plugins/_shared/conventions.js` — shared helpers

Single source of truth for cross-plugin helpers, included in both the
runtime extension JS bundle (via codegen) and the jsdom test harness:

- `MoolahConventions.parseAmount(text)` — returns the amount string as it appears on the page (digits and sign), stripping currency symbols / thousands separators. Negative for outflows when the on-page text has a `-`; positive otherwise. Sign convention for the matched account type is applied later by the Swift import pipeline.
- `MoolahConventions.signedAmount(text, { isCredit })` — same as `parseAmount` but if `isCredit` is true *and* the text has no explicit sign, prefixes `-` to mark the row as inbound (refund / payment-received on a card account).
- `MoolahConventions.inferYearForDayMonth(dayMonth, statementPeriodText)` — given `"30 May"` and the optional statement-period string (`"Since 23 May 2026. Closing 22 Jun 2026"`), returns `"2026-05-30"`. Falls back to current year, rolling back one if the date would be in the future.
- `MoolahConventions.parseDayMonthYear(text)` — handles `DD/MM/YYYY`, `DD Mon YYYY`, `YYYY-MM-DD` inputs and returns `YYYY-MM-DD`.
- `MoolahConventions.canonicaliseDescription(text)` — collapses whitespace, trims, strips trailing badges like `"Pending"`.
- `MoolahConventions.last4(text)` — extracts a trailing 4-digit group for `accountHint`.
- `MoolahConventions.findRowsAcrossSameOriginFrames(selector)` — returns rows matching `selector` in the top frame, falling back to same-origin iframes if the top frame has none (cross-origin frames are skipped silently).

These ship as a single file (`Plugins/_shared/conventions.js`) and are
loaded onto `window.MoolahConventions` at both build and test time. See
"Framework tweaks" §3 for how the runtime bundle picks them up.

### `just plugin-test` target

```just
plugin-test:
    @cd tools/test-plugin && npm install --no-audit --no-fund --silent
    node tools/test-plugin/run.js
```

Wired into the main `just test` recipe so CI fails on plugin regressions.

### `guides/IMPORT_PLUGIN_GUIDE.md`

Audience: future-me (or a contributor) adding a new bank. Sections:

1. **What a plugin is** — JS class with `run(args)` calling `args.completionFunction(payload)`.
2. **`ImportPayload` contract** — schemaVersion, sourceHost, rows shape; link to `ImportPayload.swift`.
3. **Authoring checklist** — save a webarchive; extract HTML; write `sanitise.yml`; run `sanitise.py`; write `expected.json`; write `parser.js`; add manifest row; run `just plugin-test`.
4. **Sign convention** — debits negative, credits positive (liability) / inverted on assets; per-bank choice in parser, helpers in `MoolahConventions`.
5. **Date convention** — `YYYY-MM-DD`; year inference helper.
6. **`accountHint`, `currencyHint`, `emptyHint`** — what they're for, when nil is fine.
7. **Empty-page handling** — return `rows: []`; the extension UI uses the manifest's `emptyHint` for the prompt.
8. **Phishing / safety reminder** — host matching is parent-domain only; never invoke `eval`, never load remote scripts, never write to the page.
9. **Per-bank reference** — a tiny worked example based on Macquarie.

---

## Framework tweaks (foundation PR)

PR #1014's framework is reused as-is except for three small additions:

### 1. `JSBundleEmitter` dedupes the dispatch map by host+className

Two manifest rows can share the same `file` (Amex needs `/dashboard` and `/activity`). The current emitter would produce `{ "americanexpress.com": AmericanexpressImporter, "americanexpress.com": AmericanexpressImporter }` — duplicate key, undefined behaviour. The fix: dedupe by `host` before joining. Test added to `JSBundleEmitterTests`.

The `PlistEmitter` already produces one OR-clause per row, which is correct — both pathPrefixes need to match. No change there.

The `SwiftEmitter` keeps both rows in `BundledPlugins.all` — `PluginRegistry.match(host:path:)` looks up by pathPrefix, so duplicates matter.

### 2. `Manifest` gains optional `emptyHint: String?`

Adds one optional field to the wire struct and the emitters. When set, surfaces in the extension's `ImportConfirmationView` empty state ("Couldn't find any transactions on this page. _Open one of your accounts to see transactions before importing._"). When nil, current generic copy is used. Backward-compatible with existing manifest rows (none have it).

### 3. `PluginManifestGen` includes `Plugins/_shared/*.js` in the bundle

`tools/PluginManifestGen/Sources/PluginManifestGen/main.swift` is
extended to read every `.js` file under `Plugins/_shared/` (sorted by
filename for determinism) and prepend them to
`extension-entry.bundle.js` between the dispatcher source and the
plugin sources. `JSBundleEmitter.emit` gains a `sharedScripts: [String]`
parameter that is inserted just after the dispatcher. If
`Plugins/_shared/` is absent the emitter behaves exactly as before
(`sharedScripts: []` is the safe default).

This gives per-bank parsers a single source of truth for cross-plugin
helpers (`MoolahConventions`) shared between the test harness (which
reads the same file) and the production extension bundle. New helpers
get added by editing one file.

Test: `JSBundleEmitterTests` covers the empty / non-empty
`sharedScripts` cases.

---

## Per-bank parser shape

Reference shape used by every plugin:

```js
class MacquarieImporter {
  run(args) {
    const rows = [...document.querySelectorAll("table.txn-list tr.txn-row")].map((tr, i) => ({
      date:        MoolahConventions.inferYearForDayMonth(
                       tr.querySelector(".txn-date").textContent,
                       document.querySelector(".statement-period")?.textContent),
      amount:      MoolahConventions.parseAmountToSigned(
                       tr.querySelector(".txn-amount").textContent,
                       { creditIndicator: tr.classList.contains("credit") }),
      description: MoolahConventions.canonicaliseDescription(
                       tr.querySelector(".txn-desc").textContent),
      balance:     tr.querySelector(".txn-balance")?.textContent ?? null,
      reference:   tr.dataset.txnId ?? null,
    }));

    args.completionFunction({
      schemaVersion: 1,
      sourceHost:    location.host,
      sourceURL:     location.href,
      capturedAt:    new Date().toISOString(),
      accountHint:   MoolahConventions.last4(
                         document.querySelector(".account-number")?.textContent),
      currencyHint:  "AUD",
      rows,
    });
  }
  finalize(args) { /* unused */ }
}
```

Each per-bank PR's plan documents the actual selectors after fixture sanitisation.

---

## Per-bank notes

### Macquarie (foundation PR — reference plugin)

- Source: `online.macquarie.com.au/io/` (433 KB, ~100 `<tr>` rows in a subframe).
- **Subframe handling:** Safari's `NSExtensionJavaScriptPreprocessingFile` runs in the top frame. The actual Macquarie app may be in an iframe. The parser MUST first try the top-frame DOM; if no rows, iterate same-origin iframes (`document.querySelectorAll('iframe')`, check `frame.contentDocument`, swallow cross-origin errors) and parse the first that produces rows.
- **Fixture:** the saved page IS the iframe content (Safari saves all subframes); the sanitised fixture is the iframe document.
- Currency: `AUD`. accountHint: last-4 of the account selector.

### HSBC

- Source: `services.online-banking.hsbc.com.au/.../default.html?uid=dashboard` (264 KB).
- Structure: `role="row"` / `role="grid"` accessibility roles, ~33 rows.
- Dates: "DD Mon" format (58 matches), no year on row — use the statement-period header.
- Currency: `AUD`. accountHint: last-4.

### CommBank

- Source: `www.commbank.com.au/retail/netbank/accounts/?account=...` (284 KB).
- Structure: `<tr>` + `<td>`-heavy, ~100 rows.
- Dates: "DD/MM/YYYY" (4 matches) plus "DD Mon" (70 matches).
- The `?account=...` query string carries a session-bound account key; the framework strips query+fragment from `sourceURL` before persisting, so no leakage to disk. `accountHint` is the visible last-4.
- Currency: `AUD`.

### Amex (two pages, one parser)

- Sources: `global.americanexpress.com/dashboard` (recent-activity widget, ~7 rows) and `global.americanexpress.com/activity/recent?account_key=...` (full list).
- One parser handles both. The dashboard fixture exercises the "small recent list" path; the activity fixture exercises "full list".
- Statement-period string `"(Since 23 May 2026. Closing 22 Jun 2026)"` resolves "30 May" → "2026-05-30".
- Amount sign: dashboard shows `-$2,381.02` for a Credit row (payment received). The parser preserves the on-page sign and emits it raw — the framework's Swift side handles project-convention sign flipping per-account-type.
- accountHint: card-ending `-43002` extracted from `.account-number`. (Synthetic in fixture.)
- Currency: `AUD`. (Amex Australia.)
- Manifest: two rows, same `file: "americanexpress.com/parser.js"`, same `host: "americanexpress.com"`, different `pathPrefix` (`/dashboard`, `/activity`).
- `emptyHint`: *"This page should show recent transactions. Try refreshing."*

---

## Testing strategy

### Per-fixture test (in `tools/test-plugin/run.js`)

For each `tools/test-plugin/fixtures/<host>/<scenario>.html`:
1. Load HTML into a fresh jsdom `JSDOM` instance.
2. Inject `MoolahConventions` onto `window`.
3. Evaluate the plugin's `parser.js` so the class becomes globally defined.
4. Instantiate the class, call `.run({ completionFunction: capture })`.
5. Compare captured payload to `<scenario>.expected.json` after canonical JSON normalisation (`{ sortedKeys: true }`).
6. `capturedAt` is mocked to a fixed `Date('2026-05-30T08:00:00Z')` by overriding `Date` in the jsdom window before plugin evaluation.
7. `sourceURL` is set via `JSDOM`'s `url:` option to a synthetic URL appropriate for the fixture (e.g. `https://www.example.com/`).

### Sanitisation round-trip test

`run.js` also verifies: for any fixture whose `.sanitise.yml` references a source HTML present on the local machine, re-running `sanitise.py` produces a byte-identical fixture. Skipped on CI (where source HTMLs are absent) but enforced locally before commit.

### CI integration

`just plugin-test` runs in CI (added to `just test` recipe). Failures block PR merge.

### What is *not* tested

- The extension's runtime behaviour against a live bank page. Manually verified, not automated.
- The Swift side of the inbox / deep-link flow — already covered by PR #1014's XCUITest.

---

## Privacy / security posture

- Repo never contains source HTML, screenshots, or webarchives from any user's bank session.
- All fixtures are synthetic. Sanitisation is deterministic and reproducible from `.sanitise.yml` + a source path (which is user-local).
- Parser code is reviewed in PR; no `eval`, no `Function(...)`, no remote script loading, no DOM mutation. Plugin reads, sends JSON, exits.
- Activation predicate is generated from parent-domain hosts — phishing-site lookalikes (`x-commbank.com.au`) are rejected.

---

## Open questions / deferred work

1. **Revolut.** Defer until you save a post-render archive. The SPA shell (60 KB) doesn't contain transactions. A future plugin may need a small `await waitForRows()` loop using `MutationObserver`. Out of scope here.
2. **Subframe handling pattern.** Macquarie's iframe pattern is implemented in `MacquarieImporter` directly. If a second bank needs the same pattern, factor into `MoolahConventions.findRowsAcrossSameOriginFrames(selector)`.
3. **Currency detection.** Hardcoded `AUD`/`USD` per plugin. A future enhancement may extract the currency symbol from page text.
4. **Pagination.** Plugins parse what's on the visible page. If the user wants more, they scroll/page first. Future: optional `requestMoreRows` callback.
5. **`displayName` in `Manifest`.** Already there (used in the extension UI: "Found 24 transactions from Macquarie"). Each manifest row sets it.

---

## Acceptance criteria — foundation PR

- [ ] `tools/test-plugin/` exists with `run.js`, `harness.js`, `sanitise.py`, `package.json`, `README.md`.
- [ ] `guides/IMPORT_PLUGIN_GUIDE.md` exists and is referenced from `CLAUDE.md`.
- [ ] `JSBundleEmitter` dedupes by host+className; `JSBundleEmitterTests` proves it.
- [ ] `Manifest.emptyHint` is plumbed end-to-end (emitter, registry, extension UI).
- [ ] `conventions.js` is shared between harness and runtime bundle.
- [ ] `Plugins/macquarie.com.au/parser.js` + manifest row + sanitised fixture + expected.json.
- [ ] `just plugin-test` runs green locally and in CI.
- [ ] `just format-check` passes.
- [ ] `just build-mac` and `just build-ios` warning-free.
- [ ] `just test` passes on both platforms (no regression from emptyHint / dedupe changes).
- [ ] PR description includes manual-test steps (load a Macquarie page in Safari → tap Share → "Import to Moolah" → verify the confirmation sheet shows row count > 0).
- [ ] PR description names Revolut as deferred and links this design doc.
