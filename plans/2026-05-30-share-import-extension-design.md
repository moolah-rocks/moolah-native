# Web Import — Safari Action Extension Framework — Design

**Date:** 2026-05-30
**Status:** Design (no plan yet; no implementation)
**Scope:** The reusable framework for importing transactions from a logged-in bank web page via a Safari Action Extension. Per-bank plugins are explicitly **out of scope** — this design exists so the first plugin can be slotted in as a near-mechanical exercise.

---

## Goal

Let a user, while logged in to their bank in Safari (iOS or macOS), tap **Share → "Import to Moolah"** and have the transactions visible on that page extracted, reviewed in the existing Import UI, and merged via the existing import pipeline. No credentials, no remote code, no servers. Per-bank scraping logic is pluggable so adding a new bank is "drop one JS file + one manifest row + rebuild."

## Non-goals

- A general-purpose web-scraping framework. This is for transaction lists on banks/exchanges, period.
- Multi-step automation across pages (login → set date range → export → parse). Plugins read what's on the current page; the platform allows same-origin fetches but in practice plugins will not use them.
- Replacing CSV import. Web import is *additive* — it feeds the same review/merge pipeline the CSV path already uses.
- A Safari Web Extension (toolbar button, persistent background). Action extensions are the v1 shape.

---

## Architecture overview

```
┌──────────────────┐    1. tap Share → "Import to Moolah"
│ Safari (iOS/mac) │       (action only visible on hosts in plugins.json)
└────────┬─────────┘
         │  2. Safari injects extension-entry.js, calls dispatch.run()
         ▼
┌──────────────────┐    3. dispatch picks plugin by location.host,
│ parser.js in     │       plugin scrapes DOM, calls completionFunction({payload})
│ page context     │
└────────┬─────────┘
         │  4. NSItemProvider hands JSON to extension principal class
         ▼
┌──────────────────────────────────────────────┐
│ ImportExtensionViewController                │
│   • PluginRunner decodes ImportPayload       │
│   • Validates schemaVersion                  │
│   • InboxWriter → <group>/Import/Inbox/      │
│                   <uuid>.json (atomic)       │
│   • Confirmation sheet:                      │
│       [Cancel] [Review Later] [Open Moolah]  │
└────────┬─────────────────────────────────────┘
         │  5. (Open Moolah only) moolah://import?inbox=<uuid>
         ▼
┌──────────────────┐    6. Main app deep-link handler:
│ Moolah app       │       - Reads inbox file
│   Features/      │       - Deletes inbox file (consume-once)
│   Import/        │       - importStore.startWebReview(payload:)
│                  │       - Existing review UI takes over
└──────────────────┘
```

---

## Targets & package layout

Two new Xcode targets plus one shared Swift package; plugins ship as a bundled resource.

```
project.yml
├── Moolah                                      (existing app)
├── MoolahImportExtension_iOS                   (NEW: action extension, iOS)
├── MoolahImportExtension_macOS                 (NEW: action extension, macOS)
└── Modules/
    └── ImportExtensionKit/                     (NEW: Swift package)
        ├── Sources/ImportExtensionKit/
        │   ├── PluginRegistry.swift            host→plugin manifest lookup
        │   ├── PluginRunner.swift              JS → ext bridge, decode validation
        │   ├── ImportPayload.swift             wire shape (Codable, Sendable)
        │   ├── InboxWriter.swift               App Group container I/O
        │   └── DeepLink.swift                  moolah://import?inbox=<id>
        └── Tests/ImportExtensionKitTests/
            └── (pure-Swift; no extension host needed)

Plugins/                                        (NEW: bundled with extensions)
├── plugins.json                                manifest index (host → file)
└── (per-bank parser.js files added later)
```

**Why a Swift package, not file-shared targets:** the two extensions must run exactly the same parsing/inbox/deep-link code. A package gives one compile unit, simpler dependency graph, pure-Swift unit tests, no risk of platform drift. `ImportExtensionKit` is consumed by both extension targets and by the main app (which reads the inbox).

**App Group:** one new identifier — `group.rocks.moolah.shared` — granted to `Moolah`, `MoolahImportExtension_iOS`, `MoolahImportExtension_macOS`. Entitlements live in `project.yml` per-target stanzas so xcodegen keeps them in sync.

**No principal storyboard.** SwiftUI in the extension principal view controller.

---

## JS preprocessor contract

Every per-bank plugin is one JS file. Authoring a new bank = one `.js` + one row in `plugins.json` + `just generate`. There is no Swift component per plugin.

### Per-plugin file

```javascript
// Plugins/chase.com/parser.js
class ChaseImporter {
  run(args) {
    const rows = [...document.querySelectorAll('tr.transaction')].map(tr => ({
      date:        tr.dataset.postedDate,                       // "YYYY-MM-DD"
      amount:      tr.querySelector('.amount').textContent,     // free-form
      description: tr.querySelector('.merchant').textContent.trim(),
      balance:     tr.querySelector('.balance')?.textContent ?? null,
      reference:   tr.dataset.txnId ?? null
    }));

    args.completionFunction({
      schemaVersion: 1,
      sourceHost:    location.host,
      sourceURL:     location.href,
      capturedAt:    new Date().toISOString(),
      accountHint:   document.querySelector('[data-account-number]')?.dataset.accountNumber ?? null,
      currencyHint:  "USD",
      rows
    });
  }
  finalize(args) { /* unused in v1 — no page mutation */ }
}
```

### Dispatcher file (hand-maintained, one entry point)

```javascript
// MoolahImportExtension_*/Resources/extension-entry.js
class MoolahDispatch {
  run(args) {
    const host = location.host;
    // The build step appends each parser class and inlines this map.
    const plugins = { /* GENERATED: "chase.com": ChaseImporter, ... */ };
    // Exact host or dotted-suffix only — must mirror the NSExtensionActivationRule.
    const match = Object.entries(plugins).find(([h]) => host === h || host.endsWith("." + h));
    if (!match) { args.completionFunction({ error: "no-plugin", host }); return; }
    new match[1]().run(args);
  }
  finalize(args) { /* no-op */ }
}
var ExtensionPreprocessingJS = new MoolahDispatch();
```

Safari's `NSExtensionJavaScriptPreprocessingFile` is a single file. The build step concatenates `extension-entry.js` + every `Plugins/*/parser.js` and inlines the generated dispatch map.

### Wire payload (Swift mirror)

```swift
public struct ImportPayload: Codable, Sendable {
  public let schemaVersion: Int                 // forward-compat hinge
  public let sourceHost: String
  public let sourceURL: String
  public let capturedAt: Date
  public let accountHint: String?               // free-form mask/last-4
  public let currencyHint: String?              // ISO 4217, may be nil
  public let rows: [ImportPayloadRow]
}

public struct ImportPayloadRow: Codable, Sendable {
  public let date: String                       // "YYYY-MM-DD" — framework parses
  public let amount: String                     // free-form — framework parses to cents
  public let description: String
  public let balance: String?
  public let reference: String?                 // plugin-stable id, used as dedup hint
}
```

**Why strings for `date` and `amount`** — keeps the JS contract trivial (no locale/format reasoning in plugin authors' heads) and centralises canonical parsing in `ImportExtensionKit` where it's testable. Reuses `MonetaryAmount.parseCents(from:)`.

**`schemaVersion` rule:** explicit forward-compat hinge. v1 ships as `1`. If a future framework changes the row shape, the main app reads the version and adapts.

---

## Plugin registry & build-time activation predicate

### The plugin index

```json
// Plugins/plugins.json
{
  "plugins": [
    { "host": "chase.com",       "pathPrefix": "/web/auth/dashboard", "file": "chase.com/parser.js",       "displayName": "Chase" },
    { "host": "commbank.com.au", "pathPrefix": "/netbank",            "file": "commbank.com.au/parser.js", "displayName": "CommBank" }
  ]
}
```

### Code generation

A small Swift CLI under `tools/PluginManifestGen` reads `plugins.json` and emits:

- `Modules/ImportExtensionKit/Generated/PluginRegistry+Bundled.swift` — `BundledPlugins.all: [PluginManifest]`.
- `MoolahImportExtension_iOS/Generated/Info.plist.activation.plist` — the `NSExtensionActivationRule` predicate fragment.
- `MoolahImportExtension_macOS/Generated/Info.plist.activation.plist` — same shape, macOS-targeted.

`just generate` runs `xcodegen generate` then `swift run --package-path tools/PluginManifestGen Plugins/plugins.json`. `project.yml` references the generated Info.plist fragments as partials xcodegen merges with the static target Info.plist.

Generated files are committed to git (predictable diffs in PRs).

### The activation predicate (generated)

```xml
<key>NSExtensionAttributes</key>
<dict>
  <key>NSExtensionActivationRule</key>
  <string>
    SUBQUERY(extensionItems, $item,
      SUBQUERY($item.attachments, $att,
        ANY $att.registeredTypeIdentifiers UTI-CONFORMS-TO "public.url"
        AND (
          (   $att.URL.host == "chase.com"
           OR $att.URL.host ENDSWITH ".chase.com" )
          AND $att.URL.path BEGINSWITH "/web/auth/dashboard"
          OR
          (   $att.URL.host == "commbank.com.au"
           OR $att.URL.host ENDSWITH ".commbank.com.au" )
          AND $att.URL.path BEGINSWITH "/netbank"
        )
      ).@count > 0
    ).@count > 0
  </string>
  <key>NSExtensionJavaScriptPreprocessingFile</key>
  <string>extension-entry</string>
</dict>
```

**Why the `host ==` OR `host ENDSWITH ".x"` pair** — a naked `ENDSWITH "chase.com"` would also match `x-chase.com` (string-suffix match has no awareness of domain segments), which is a phishing-site footgun. The exact-or-dotted-suffix form matches `chase.com` and any subdomain (`secure.chase.com`) but rejects look-alikes. `PluginRegistry.match(host:path:)` applies the same rule in Swift.

### Runtime registry

```swift
@MainActor
final class PluginRegistry {
  static let shared = PluginRegistry(manifests: BundledPlugins.all)
  // host == manifest.host || host.hasSuffix("." + manifest.host),
  // AND path.hasPrefix(manifest.pathPrefix).
  func match(host: String, path: String) -> PluginManifest? { /* … */ }
}
```

The runtime registry is mostly defensive — Safari has already filtered by activation rule. The extension uses it to render the bank's `displayName` ("Found 24 transactions from Chase") and to choose error copy if Safari hands us an off-host payload (shouldn't happen).

---

## Extension UI, deep-link, and main-app handoff

### Confirmation sheet (SwiftUI, both platforms)

```
┌──────────────────────────────────────────────────┐
│  Import to Moolah                                │
├──────────────────────────────────────────────────┤
│                                                  │
│  ✓ Found 24 transactions from Chase              │
│                                                  │
│  From statement page • 2026-05-30                │
│                                                  │
│  Open Moolah now to review and import, or save   │
│  for later — Moolah will pick it up next time    │
│  you open the app.                               │
│                                                  │
├──────────────────────────────────────────────────┤
│   [ Cancel ]   [ Review Later ]   [ Open Moolah ]│
└──────────────────────────────────────────────────┘
```

Default button: **Open Moolah** (most likely intent — user just scraped a page).

### Button behaviour

| Button | Inbox file | Deep-link | Sheet dismissal |
|---|---|---|---|
| **Cancel** | not written | none | `extensionContext.cancelRequest(withError:)` |
| **Review Later** | written to `<group>/Import/Inbox/<uuid>.json` | none | `extensionContext.completeRequest(returningItems: nil)` |
| **Open Moolah** | written | `moolah://import?inbox=<uuid>` via `extensionContext.open(_:)` | `completeRequest` |

### Error states (same screen, different copy)

| Condition | Copy |
|---|---|
| `rows.isEmpty` | "Couldn't find any transactions on this page. Make sure you're on Chase's *Account activity* page and try again." Per-plugin `emptyHint` field overrides the generic phrasing. |
| JS returned `{ error: "no-plugin" }` | Defensive — activation rule should prevent this. "Moolah doesn't recognise this page." Cancel only. |
| Decode failure (schema mismatch) | "This page returned data Moolah doesn't understand. Update Moolah and try again." Encourages app update if extension is newer than main app. |
| Inbox write failure | "Couldn't save the import. Reinstall Moolah from the App Store." Entitlement misconfiguration shouldn't happen in shipped builds, but be honest. |

### Inbox file format

Plain JSON, atomic write (`FileManager` `.atomicWrite` option):

```
<group>/Import/Inbox/<uuid>.json    (newly captured, awaiting review)
<group>/Import/Quarantine/<uuid>.json (decode failure on read, kept for diagnostics)
```

One file per scrape. Multiple files accumulate if the user "Review Later"s several times.

### Main-app URL scheme & deep-link handler

The `moolah://` URL scheme is **not yet registered** in the main app. This design introduces it. Specifically:

- Register `moolah` under `CFBundleURLTypes` in the main app's Info.plist (via `project.yml`).
- Introduce a `DeepLinkRouter` in the main app that handles `onOpenURL` and dispatches by host. The router starts with one route — `import` — but is intentionally a routing point rather than a one-off, so future deep links share it.

Route shape: `moolah://import?inbox=<uuid>`. UUIDs are validated as v4 before any disk access; an invalid id is silently dropped (no inbox file is read).

```swift
case .importInbox(let id):
  Task { @MainActor in
    let payload = try await InboxWriter.shared.read(id: id)   // App Group
    try await InboxWriter.shared.delete(id: id)               // consume-once
    importStore.startWebReview(payload: payload)
  }
```

`ImportStore.startWebReview(payload:)` is the **single integration seam** into the existing `Features/Import/` pipeline. It translates `ImportPayload` → the internal candidate-transactions shape the CSV path already produces, then routes into the same review UI. From the user's perspective after the deep link, the experience is identical to a CSV import — same review screen, same account picker, same dedup, same rule engine.

**All business logic** (account matching, category suggestions, duplicate detection, rule-based auto-categorisation, currency handling) **is reused**. The extension framework contributes zero domain logic — it is a transport.

### Cold-start case (Moolah not running, or not signed in)

The deep-link arrives at app launch. App launches normally, including any sign-in / profile-pick flow. Inbox files are durable on disk in the App Group; the deep-link handler stores the inbox id in app state during launch and consumes it after `ProfileStore` signals ready.

### "Review Later" surfacing in the main app

- On every launch, after `ProfileStore` is ready, scan `<group>/Import/Inbox/`.
- If one or more files exist, show a non-blocking banner in the main window: **"1 pending import from Chase — Review now"** (clickable, routes to review for that file). Multiple files: **"N pending imports — Review"**.
- Banner persists across restarts until consumed.
- 30-day GC on stale files.

Platform UX notes:

- **iOS:** local notifications are possible at extension-write time but **deferred** — banner-on-launch is enough for v1.
- **macOS:** banner at top of main window. No system notification (too noisy).

### Sandbox & networking

- Extension **does not** request `com.apple.security.network.client`. The Swift side never touches the network.
- Extension **does not** access the keychain or CloudKit.
- The JS plugin operates in the page's origin with the user's existing cookies; that traffic is the page's, not Moolah's.

---

## Privacy & App Store review posture

### Privacy

- Zero outbound network from the extension's Swift code.
- No analytics, no logging of payload contents. `os_log` may record structural facts only — `"import_extension.invoked host=chase.com rows=24"` — never amounts, descriptions, account numbers, or full URLs.
- App Group inbox is local-only; never synced. Once consumed by the main app, the data follows existing CloudKit/GRDB paths.
- `PrivacyInfo.xcprivacy` for each extension target: data uses = "Other financial info — App functionality — Not linked to user". No tracking. Required API reasons covered if/when file timestamps or user defaults are read.

### Anticipated review questions and ready answers

| Likely question | Answer |
|---|---|
| Does the extension transmit user financial data to a server? | No. Local App Group JSON, consumed in-process by main app. |
| Is the parser code downloaded at runtime? | No. Bundled at build time. Every parser ships through TestFlight + App Store review. |
| Why does it run on bank websites? | User-initiated only — action appears in Share menu, user must tap it. Single round-trip. No background access. |
| Does it have credentials to log in for the user? | No. The user is already logged in to the bank in Safari; the extension reads what is rendered. |
| What if the bank changes its site? | Either parses nothing (clear empty-state copy) or activation rule no longer matches. No crashes; no broken user state. |

A short user-facing **"How web import works"** help page is recommended alongside shipping the first plugin — out of scope for this design.

---

## Testing strategy

### `ImportExtensionKitTests` (pure Swift, no extension host)

- `ImportPayload` round-trips JSON (Codable contract).
- `PluginRegistry.match(host:path:)` — exact-host-or-dotted-suffix rule (`chase.com` and `secure.chase.com` match `chase.com`; `x-chase.com` does **not**), plus path-prefix edge cases (root path, trailing slash, query string ignored).
- `InboxWriter` write/read/delete; concurrent-writer safety; corrupt-file handling (truncated JSON → throws, file quarantined to `Import/Quarantine/`).
- `ImportStore.startWebReview(payload:)` translates payload → candidate shape; downstream covered by existing `TestBackend`-based tests.

### Plugin-level JS tests (deferred to first plugin)

Out of scope for the framework. When the first plugin lands, a `tools/test-plugin` CLI loads `Plugins/<host>/parser.js` against saved HTML fixtures via Node and asserts JSON output. Fixture-test discipline is the substitute for runtime replay/audit.

### UI tests (existing macOS XCUITest infra)

XCUITest cannot drive Safari. Instead: a `MoolahImportExtensionHarness_macOS` test target seeds `ImportPayload` fixtures into the App Group inbox, deep-links the main app, and asserts the review screen appears and renders the right counts. Covers the seam without needing Safari.

### No extension-target XCTest in v1

All meaningful logic is in `ImportExtensionKit`. The extension target is view-controller glue.

---

## Performance budget

- Extension cold-launch to confirmation screen: **<500ms** on the slowest supported device. Bulk of that is Safari's extension-host setup, not Moolah code.
- Our share: JSON decode + atomic inbox write + SwiftUI render. Easy.
- Watched via one `os_signpost` interval `import-extension.parse-to-screen`, following existing `guides/BENCHMARKING_GUIDE.md` patterns.
- `InboxWriter` uses `FileManager` atomic writes — no GRDB, no CloudKit — keeps the extension binary small and entitlement surface tight.

---

## Open questions & deferred work

1. **Authoring guide for plugins.** `guides/IMPORT_PLUGIN_GUIDE.md` documenting the JS contract, fixture-test workflow, and a per-bank checklist. Produced alongside the first real plugin.
2. **Help content.** "How web import works" article + per-bank "How to use" microcontent, via existing `Features/Help/`. Produced when the first plugin lands.
3. **iOS local notification for "Review Later".** Punted — banner-on-launch is the v1 surface on both platforms.
4. **Structured `AccountHint`.** Today it's a freeform string. With multiple plugins we'll likely want `last4`, `mask`, `displayName`. Defer until the second plugin proves the need.
5. **Inbox cap.** Only 30-day GC in v1. If users accumulate hundreds of unreviewed inboxes the banner UX gets weird. Revisit if observed.
6. **Replay/audit.** Deliberately omitted. Keeping source HTML for debugging would negate the privacy posture. Fixture-test discipline at plugin-merge time substitutes.
