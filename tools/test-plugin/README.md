# `tools/test-plugin` — Moolah Import Plugin Test Harness

Pure JS / Python tooling for authoring and testing
`Plugins/<host>/parser.js` — the per-bank parsers used by Moolah's
Safari Action Extension.

## Layout

```
tools/test-plugin/
├── package.json
├── run.js                          # CLI test runner
├── lib/harness.js                  # jsdom load + capture harness
├── sanitise.py                     # Source-HTML → fixture regeneration
└── fixtures/<host>/
    ├── <scenario>.sanitise.yml     # Redaction config + synthetic URL
    ├── <scenario>.html             # Regenerated fixture (committed)
    └── <scenario>.expected.json    # Expected ImportPayload (committed)
```

## Running the tests

```sh
just plugin-test                    # full suite
node tools/test-plugin/run.js       # same thing
node tools/test-plugin/run.js macquarie.com.au   # one host
```

CI runs `just plugin-test` as part of `just test`. Any drift between
fixture output and `expected.json` fails the build.

## Privacy

Sanitised fixtures are **regenerations**, not redactions. We never
commit (or store anywhere outside the contributor's local machine)
real bank-page bytes. Source webarchives live in
`~/Downloads/Moolah Sites/` per project convention; they're gitignored
by virtue of being outside the repo.

The `sanitise.py` script does the heavy work. For every fixture:

- Strips all `<script>`, `<style>`, `<svg>`, `<img>`, `<iframe>`, etc.
- Strips `id`, `name`, `style`, `srcset`, `onclick`, etc.
- Drops CSS-in-JS class hashes (Angular `ng-tns-*`, JSS, emotion, …),
  keeping only classes the parser depends on (see `keep_classes` in
  each fixture's `.sanitise.yml`).
- Replaces all merchant / payee text with `MERCHANT ALPHA` … `LIMA`
  (rotating through a fixed list, deterministic per seed).
- Replaces amounts with synthetic values from a fixed pool.
- Replaces dates with values in a fixed `2026-01-05 .. 2026-01-15`
  window.
- Replaces account numbers / card-last-4 with `XXXX####`.
- Baseline catch-all sweeps any remaining 4+-digit run, any
  $X.XX-shaped numbers, and HTML comments.

The result is committed to `fixtures/<host>/<scenario>.html`.

## Adding a new bank

Walk-through is in `guides/IMPORT_PLUGIN_GUIDE.md`. The short version:

1. Save a page from the bank to your local machine
   (`~/Downloads/Moolah Sites/<host>.webarchive`).
2. Extract the main HTML
   (`python3 tools/test-plugin/extract_webarchive.py <archive> <out>`).
3. Write `tools/test-plugin/fixtures/<host>/recent.sanitise.yml` declaring
   the selectors your parser will use and where the source HTML is on
   disk.
4. Run `python3 tools/test-plugin/sanitise.py
   tools/test-plugin/fixtures/<host>/recent.sanitise.yml`. The script
   writes `recent.html` next to the YAML.
5. Hand-craft `recent.expected.json` describing what the parser should
   emit (you can `node tools/test-plugin/run.js <host>` first and use
   the output as a starting point, then audit each row).
6. Write `Plugins/<host>/parser.js` and add a row to
   `Plugins/plugins.json`.
7. `just plugin-test` until green; `just generate` to rebuild the
   bundle.

## Why Node + jsdom

The Safari Action Extension framework loads each plugin into the page
as a `NSExtensionJavaScriptPreprocessingFile`. A faithful test
environment is a JS DOM with the plugin's code evaluated against a
real(ish) `document`. `jsdom` is the only mature pure-JS DOM
implementation; Node ships with macOS dev tools and CI runners; the
whole suite runs in well under a second.

We deliberately don't pull in a JS test framework — `run.js` is a
~150-line script. Asserting the parser's output against a canonical
JSON file is sufficient; the parsers themselves are small (~50 LOC).
