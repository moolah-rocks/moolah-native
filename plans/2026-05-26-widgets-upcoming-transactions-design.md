# Widgets — Upcoming Transactions (first widget set) — Design

**Date:** 2026-05-26
**Status:** Design — pending plan
**Author:** Adrian Sutton (with Claude)
**Related:** [`Automation/Intents/OpenAccountIntent.swift`](../Automation/Intents/OpenAccountIntent.swift) (the AppIntent navigation pattern this widget set reuses), [`Automation/Navigation/NavigationBridge.swift`](../Automation/Navigation/NavigationBridge.swift), [`Automation/Navigation/NavigationDestination.swift`](../Automation/Navigation/NavigationDestination.swift), `Features/Transactions/TransactionStore+ScheduledViews.swift` (existing in-app upcoming logic), [`Shared/URL+MoolahStorage.swift`](../Shared/URL+MoolahStorage.swift) (storage-path resolution to be refactored), [plans/2026-05-25-handoff-design.md](2026-05-25-handoff-design.md) (concurrent change owning `NavigationDestination` evolution).

## Summary

Add a Home Screen / Desktop WidgetKit bundle to the Moolah project containing two widgets, both centred on scheduled transactions the user needs to act on:

- **`UpcomingTransactionsListWidget`** (`.systemMedium`) — flat list of up to five rows covering **overdue + next 7 days**, with relative-date column, payee, and sign-coloured amount. Tapping a row deep-links to that transaction in the configured profile via an `AppIntent`. The widget is display-only.
- **`UpcomingTransactionsCountWidget`** (`.systemSmall`) — a single big number: the count of scheduled transactions that are **overdue or due today**, with the sum of those amounts beneath. Tapping opens the Upcoming list for the configured profile.

Both widgets are bound to one profile per widget instance via a `WidgetConfigurationIntent` that lists the user's profiles. Both ship on iOS 26 and macOS 26 simultaneously.

The widget extension is a separate process and so cannot reach the host's in-memory stores. To satisfy the chosen architecture (direct, always-fresh SQLite read — no snapshot file), the per-profile `data.sqlite` and the profile-index database move from `~/Library/Application Support/<env>/…` into a new **App Group container** (`group.rocks.moolah.app.{test,v2}`) shared by the host targets and the widget extension. The widget extension opens those databases read-only via GRDB on every timeline rebuild and never writes.

## Goals

- A user can pin a "Upcoming" widget to their iPhone Home Screen, iPad Home Screen, or Mac desktop / Notification Centre, bind it to a specific profile, and see what's overdue and due soon at a glance without opening the app.
- Tapping a transaction row on the medium widget jumps straight to that transaction in the host app — same in-process route as `OpenAccountIntent`, no `moolah://` URL scheme.
- Tapping the small widget jumps to the Upcoming list for the bound profile.
- Widget data is read directly from the per-profile SQLite store, so it is always fresh with the last sync — no separate snapshot file to invalidate.
- Each widget instance is bound to one profile via a standard configuration intent surfaced by the system; users with multiple profiles can pin one widget per profile.
- The infrastructure introduced (App Group container, read-only widget query layer, widget-side `ProfileEntity` / configuration intent, `WidgetCenter.reloadAllTimelines()` hooks) is reusable by future widgets (net worth, recent transactions, earmark gauges) without further migration work.
- The on-disk move (Application Support → App Group container) is safe under crash and is reversible until the cleanup-pass release lands.

## Non-goals

- **Interactive widgets** — no "mark as paid", "snooze", or other write actions inside the widget surface. Display-only on first cut. Adding interactivity is a follow-up.
- **iOS Lock Screen accessory family** — explicitly dropped. No `.accessoryRectangular` / `.accessoryInline` widgets in this round.
- **Apple Watch complications** — would require a watchOS target; out of scope.
- **`.systemLarge` and `.systemExtraLarge`** — not in the first cut. The layout work is meaningfully different from a stretched medium and would dilute the focus on shipping the small + medium pair well.
- **Reviving the `moolah://` URL scheme.** Per the handoff design's non-goals, issue [#386](https://github.com/moolah-rocks/moolah-native/issues/386) stays closed. Widget tap targets use `AppIntent` with `openAppWhenRun = true` and `NavigationBridge`, identical to `OpenAccountIntent`.
- **A snapshot-file fallback path.** Architecture choice **A** (direct DB read) was selected; we are not building a hybrid that also writes JSON snapshots. If the direct read proves wrong in production, that is a future-architecture decision, not v1 scope.
- **Aggregate-across-profiles widgets** — a widget instance shows exactly one profile. Users with N profiles add N widgets.
- **Per-row "snooze N days" or context menus** — `widgetURL` / per-row `Link` mapping to a single deep-link AppIntent is the entire interaction model.
- **Widget-level currency conversion across instruments.** Each row renders the transaction's own instrument exactly. The small widget's "sum of due-today amounts" is per-currency (see *Multi-currency handling* below) — no FX in the extension.
- **Backfilling the old Application Support location after migration in v1.** The old per-profile directories are left in place after the copy as a rollback safety net for at least one release. A delayed cleanup migration is tracked as a new GitHub issue and called out in the plan.

## Background

### Project context the widget set inherits

- **Targets:** iOS 26+ and macOS 26+ universal SwiftUI app. The Xcode project is regenerated from `project.yml` by `xcodegen` — every new target / entitlement / app-group lands in `project.yml`, never in a hand-edited `project.pbxproj`.
- **Per-profile storage:** each profile owns a GRDB SQLite database at `URL.moolahScopedApplicationSupport/profiles/<UUID>/data.sqlite`. `URL.moolahScopedApplicationSupport` is env-scoped (Debug / Debug-Tests → `app.test`, Release → `app.v2`) via [`CloudKitEnvironment.resolved().storageSubdirectory`](../Shared/URL+MoolahStorage.swift).
- **Profile-index DB:** a separate, smaller SQLite catalogue lists the user's profiles (id, label, currency) — referenced under that env-scoped root by `ProfileContainerManager`.
- **CloudKit sync:** per-profile sync via `CKSyncEngine`. The on-disk SQLite is the always-up-to-date local cache that CloudKit pushes into. Reading it from the widget is the same shape as the in-app stores.
- **Scheduled / upcoming logic already exists** in `Features/Transactions/TransactionStore+ScheduledViews.swift`: `scheduledUpcomingTransactions`, `scheduledOverdueTransactions`, `scheduledShortTermTransactions(daysAhead:)`. The widget does **not** import these; it issues a small focused SQL query against `data.sqlite` directly. The in-app logic stays where it is.
- **`Domain/`** has no SwiftUI / SwiftData / URLSession dependencies. The widget extension may link a minimal slice of `Domain/Models/` (`Instrument`, `InstrumentAmount`, `MonetaryAmount`, `Transaction` and its supporting types if needed for decoding rows).
- **AppIntents are already wired up** under `Automation/Intents/`. `OpenAccountIntent` is the canonical pattern: `static let openAppWhenRun = true`, `@MainActor func perform()` calls `NavigationBridge.openProfile` (with macOS-side `ProfileWindowLocator.activateExistingWindow` first) and `NavigationBridge.setPendingNavigation(PendingNavigation(...))`. The widget set uses two new intents in the same shape.
- **`NavigationDestination` already models `.upcoming` and `.transaction(id)`** — the two destinations the widget needs. No new cases required.

### Two constraints that shape the design

- **The widget extension is a separate sandboxed process.** It cannot reach `AutomationServiceLocator.shared`, cannot open files in the host's Application Support container, and cannot call into host-app code at all. Anything the extension needs at read time must either be in its own bundle or in an App Group container it has the entitlement for.
- **The `moolah://` URL scheme remains rejected** ([#386](https://github.com/moolah-rocks/moolah-native/issues/386), reaffirmed by the handoff design). The only viable widget→host navigation mechanism on iOS 17+ / macOS 14+ that does not need a URL scheme is `Button(intent:)` / `Link(destination:)` with an `AppIntent` whose `openAppWhenRun = true`. That is the pattern used here.

## Architecture

### New Xcode targets and shared modules

The widget bundle is **one extension target** that ships on both platforms. WidgetKit lets a single source set vend widgets that work on iOS Home Screen, iPad Home Screen, and macOS desktop / Notification Centre simultaneously; we do not need parallel `_iOS` / `_macOS` widget targets the way the host has parallel app targets.

```
project.yml additions (skeleton — exact YAML in the plan):

  MoolahWidgets:
    type: app-extension
    platform: [iOS, macOS]
    supportedDestinations: [iOS, macOS]
    sources:
      - path: MoolahWidgets
      - path: Shared/Widgets        # new — shared between host targets and widget bundle
      - path: Domain/Models         # narrow slice; see "Linker scope" below
    dependencies:
      - sdk: WidgetKit.framework
      - sdk: SwiftUI.framework
      - sdk: AppIntents.framework
      - package: GRDB
    settings:
      base:
        APP_GROUP_ID: group.rocks.moolah.app.test   # overridden per-config to .v2 for Release
        INFOPLIST_KEY_NSExtensionPointIdentifier: com.apple.widgetkit-extension
    entitlements:
      - com.apple.security.application-groups: [$(APP_GROUP_ID)]
```

The host targets (`Moolah_iOS`, `Moolah_macOS`) gain the same App Group entitlement and the new `Shared/Widgets/` source path. They also embed the widget bundle in their `Plug-Ins` extension copy phase.

### New filesystem layout

```
MoolahWidgets/                          # new target
├── MoolahWidgetsBundle.swift           # @main WidgetBundle of both widgets
├── UpcomingTransactionsListWidget.swift # .systemMedium widget + entry + provider
├── UpcomingTransactionsCountWidget.swift # .systemSmall widget + entry + provider
├── Views/
│   ├── UpcomingListView.swift          # medium content
│   ├── UpcomingCountView.swift         # small content
│   ├── UpcomingRowView.swift           # one row for the medium list
│   └── WidgetEmptyStateView.swift      # shared empty-state view
└── Intents/
    ├── WidgetProfileSelectionIntent.swift   # AppIntent — configuration parameter
    ├── WidgetProfileEntity.swift            # extension-local AppEntity + EntityQuery
    ├── OpenUpcomingFromWidgetIntent.swift   # tap target for the small widget + .accessoryInline taps
    └── OpenTransactionFromWidgetIntent.swift # tap target for medium rows
Shared/Widgets/                         # new — linked by host + widget extension
├── WidgetDataPath.swift                # App Group container URL + per-profile DB paths
├── UpcomingWidgetSnapshot.swift        # Sendable value type returned to the timeline provider
├── UpcomingWidgetQuery.swift           # opens data.sqlite read-only and runs the query
├── WidgetProfileSummary.swift          # Sendable {id, label, currency} read from profile-index DB
├── WidgetProfileDirectory.swift        # opens profile-index DB read-only and lists profiles
└── WidgetReloadCoordinator.swift       # host-side helper that calls WidgetCenter.reloadAllTimelines()
```

`Shared/Widgets/` has **no** dependency on `Backends/CloudKit/`, on `Features/`, or on any repository protocol implementation. It depends only on `GRDB` and on a small slice of `Domain/Models/` (`Instrument`, `InstrumentAmount`, `MonetaryAmount`). The widget extension binary stays small.

### Two widgets, two layouts

**Medium — `UpcomingTransactionsListWidget` (variant A "flat list with relative dates"):**

- Header: bold "Upcoming" on the left, small profile name on the right.
- Up to **five rows**, ordered chronologically (most overdue first). Each row is `[relative-date | payee | amount]`:
  - Overdue rows: date rendered in red as `"N days late"`.
  - Today rows: date rendered in amber as `"Today"`.
  - Future rows: date rendered in the default secondary colour as a short weekday (`Wed`, `Fri`, …) for dates within the next 7 days.
- Amount column right-aligned, `monospacedDigit()`, sign-coloured (expense = red, income = green). The sign of the underlying `Transaction` leg total is preserved verbatim — a refund (positive expense) still displays positive.
- Footer (subtitle, beneath the header): nothing in v1 — the row count itself is the indicator; if scope expands later we can add "5 of 12 due in next 14 days" type text.
- Empty state: centred `WidgetEmptyStateView` with secondary text "Nothing due in the next 7 days".

**Small — `UpcomingTransactionsCountWidget` (variant A "big number + total"):**

- Big number = **count of scheduled transactions that are overdue or due today**.
- Underneath: total amount of those transactions, rendered in red (since the expectation is they are expenses; income rows still count but the colour communicates "money about to leave" — see *Multi-currency handling* for the per-instrument fallback).
- Profile name as a chip in the corner.
- Empty state when count is 0: dimmed "0" plus secondary text "Nothing due today".

### Tap targets — AppIntent, not URL

Both widgets use `Link(destination: URL)` only insofar as `widgetURL(_:)` accepts one, but the URL we install is a **container** for a `Button(intent:)`-equivalent path: more concretely, **iOS 17+ `Button(intent:)` and `Link(intent:)` patterns** route directly through `AppIntent` without ever crossing the URL boundary. The widget set uses these patterns exclusively:

- **Medium row** → wrapped in `Button(intent: OpenTransactionFromWidgetIntent(profile: profile, transactionID: row.id.uuidString))`. The intent has `openAppWhenRun = true`. Its `perform()` runs in the host process and is the same shape as `OpenAccountIntent.perform()`:
  1. macOS: try `ProfileWindowLocator.activateExistingWindow(for: profile.id)` first.
  2. If no window: call `NavigationBridge.openProfile?(profile.id)`.
  3. Call `NavigationBridge.setPendingNavigation?(PendingNavigation(profileId: profile.id, destination: .transaction(transactionID)))`.
- **Small widget body** → wrapped in `Button(intent: OpenUpcomingFromWidgetIntent(profile: profile))`. Same shape, destination is `.upcoming`.

No URL scheme is involved at any layer. Both intents declare `openAppWhenRun = true` and `isDiscoverable = false` (they are not user-discoverable Shortcuts — they exist only to be invoked from the widget surface).

### Timeline strategy

Both widgets use **`AppIntentTimelineProvider`** so the `WidgetConfigurationIntent` parameter (the chosen profile) is available in `timeline(for:configuration:)`. Each provider:

1. Resolves the configured profile via `WidgetProfileSummary` (App Group profile-index DB read).
2. If no profile (user hasn't configured the widget yet, or the bound profile has been deleted), emits a single-entry timeline at "configure me" / "profile not found" placeholder.
3. Otherwise opens the profile's `data.sqlite` read-only via `UpcomingWidgetQuery.read(profile:asOf:)`.
4. **Returns a multi-entry timeline:**
   - Entry 0: now → next "midnight" boundary in the user's calendar.
   - Entry 1: next midnight → midnight after.
   - Up to **five entries**, each recomputed at the boundary so "Today" / "N days late" / weekday labels stay current without a refresh from the host.
   - Final entry's reload policy: `.atEnd` (so iOS rebuilds the timeline again on its own once the last entry expires).
5. Returns `Timeline(entries:, policy: .atEnd)`. No `policy: .after(…)` overrides — the timeline already covers five midnight rollovers, which is more than enough headroom for a typical reload from `WidgetCenter`.

**Host-driven reloads** — the host calls `WidgetCenter.shared.reloadAllTimelines()` (wrapped in `WidgetReloadCoordinator.reload()`) on the following hooks, all already-existing pinch points:

- `TransactionStore` mutation completion (create / update / delete / pay-scheduled / mark-as-spam).
- CloudKit sync completion (CKSyncEngine "fetched + applied" boundary).
- Scene phase → `background` on iOS and `app willResignActive` on macOS (covers the case where the user just closed the app after editing a scheduled transaction).
- Profile mutation in `ProfileContainerManager` (rename / add / delete) — so the small widget's profile chip stays in sync.

These hooks live in host-only code (`Features/Transactions/`, `App/`, `Backends/CloudKit/Sync/`). The widget extension never calls `WidgetCenter` — that API is for the host.

### Configuration intent: per-instance profile binding

```swift
struct WidgetProfileSelectionIntent: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "Pick a profile"
  static let description = IntentDescription(
    "Choose which Moolah profile this widget shows.")

  @Parameter(title: "Profile") var profile: WidgetProfileEntity?
}
```

`WidgetProfileEntity` is an extension-local `AppEntity` whose `EntityQuery` opens the profile-index DB through `WidgetProfileDirectory` (read-only, App Group container). It is **separate from** the existing `Automation/Intents/Entities/ProfileEntity` which routes through `AutomationServiceLocator.shared.service`. Trying to share one type would force `AutomationServiceLocator` into the extension or push GRDB + App Group resolution into the host's `Automation/` namespace; both widen the blast radius beyond what's helpful. Two thin, parallel entity types with a small mapping seam at the host boundary is cleaner.

If the configured profile UUID is no longer present in the profile-index DB (the user deleted it, or sync hasn't pulled it onto the device yet), the timeline provider returns a placeholder entry with the secondary text "Profile not available — open Moolah to fix" and a tap that simply opens the host (via an `OpenUpcomingFromWidgetIntent` whose profile resolves to `nil` → host opens to the profile picker).

## Data layer

### App Group container migration

A single one-shot migration moves the user's per-profile data from `URL.applicationSupport/<env>/…` to `groupContainer/<env>/…`. The host owns the migration; the widget never runs while the migration is in-flight (the App Group is empty, so the timeline provider's "no profiles" branch covers the gap).

The current path resolver:

```swift
// Shared/URL+MoolahStorage.swift (existing)
static var moolahScopedApplicationSupport: URL {
  let root = moolahApplicationSupportOverride ?? URL.applicationSupportDirectory
  let scoped = root.appending(path: CloudKitEnvironment.resolved().storageSubdirectory)
  try? FileManager.default.createDirectory(at: scoped, withIntermediateDirectories: true)
  return scoped
}
```

is replaced by:

```swift
// Shared/URL+MoolahStorage.swift (new shape)
static var moolahScopedApplicationSupport: URL {
  let root = moolahApplicationSupportOverride ?? WidgetDataPath.appGroupRoot()
  let scoped = root.appending(path: CloudKitEnvironment.resolved().storageSubdirectory)
  try? FileManager.default.createDirectory(at: scoped, withIntermediateDirectories: true)
  return scoped
}
```

`WidgetDataPath.appGroupRoot()` returns `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupConfig.identifier)`, where `AppGroupConfig.identifier` is read from the host's Info.plist (env-scoped) the same way `MoolahCloudKitContainer` is today. `moolahApplicationSupportOverride` continues to win for tests — the host-side override key keeps every existing unit/UI test pointing at a temp directory.

**Migration algorithm** (runs once, in `ProfileContainerManager.bootstrap()` before any profile session opens):

1. Compute `oldRoot = URL.applicationSupportDirectory.appending(path: CloudKitEnvironment.resolved().storageSubdirectory)`.
2. Compute `newRoot = WidgetDataPath.appGroupRoot().appending(path: CloudKitEnvironment.resolved().storageSubdirectory)`.
3. If `newRoot/migrated-from-application-support-v1.flag` exists → migration is already complete; return.
4. Ensure `newRoot` exists (`createDirectory(withIntermediateDirectories: true)`).
5. For each entry under `oldRoot`:
   - If it is a `profiles/` directory: recursively **copy** every per-profile subdirectory and every file inside (including `data.sqlite`, `data.sqlite-wal`, `data.sqlite-shm`, the import-staging subdirectory) to `newRoot/profiles/`. Skip if the destination already exists.
   - If it is the profile-index DB file (and any sidecars): copy.
   - If it is a CKSyncEngine state file or backup directory under the conventions used by `ProfileSession+SyncCleanup` / `StoreBackupManager`: copy.
6. For every copied `*.sqlite`, open it via GRDB and run `PRAGMA integrity_check;` against the copy. If any returns anything other than `"ok"`, **abort** — log a `Logger.fault`, delete the partially-copied destination, surface a recoverable error to the user via the existing `IncompatibleProfileInfo` machinery, and leave the old data in place.
7. Atomically write `migrated-from-application-support-v1.flag` (a zero-byte marker) to `newRoot` using `Data().write(to:, options: [.atomic])`.
8. **Do not delete** the old data. A subsequent release will land a cleanup migration after we have telemetric confidence the new path works. The cleanup migration is tracked as a new GitHub issue, referenced as `TODO(#NEW)` next to the migration code.

**Properties of the migration:**

- **Copy, not move.** Mid-migration crash leaves the old data complete and the flag absent → next launch retries.
- **Idempotent.** Per-profile subdirectory existence check skips already-migrated profiles. Re-running is a no-op.
- **Integrity-checked.** The flag is only written after every SQLite file passes `integrity_check`.
- **Recoverable.** If integrity check fails, `IncompatibleProfileInfo` shows the affected profile in the existing profile-picker error UI; the user can choose to keep using the un-migrated data (host falls back to `oldRoot` via the override; widgets stay empty until resolved).
- **Backup semantics preserved.** Per-profile directories continue to set `URLResourceValues.isExcludedFromBackup = false` (current behaviour) inside the App Group container. iCloud Backup semantics are unchanged because the App Group container is included in backup by default for both iOS and macOS.

**Test backends:**

- `moolahApplicationSupportOverride` continues to win. Tests set it to a temp directory; no App Group container is touched, no migration runs (the migration helper checks the override and bails when it is set).
- UI tests inherit the same override via `UITestSeedHydrator`'s existing wiring.

### The query

```swift
// Shared/Widgets/UpcomingWidgetSnapshot.swift
struct UpcomingWidgetSnapshot: Sendable, Equatable {
  struct Row: Sendable, Equatable, Identifiable {
    let id: UUID                  // Transaction.id
    let payee: String
    let dueDate: Date             // start-of-day, in user's calendar
    let amount: Decimal           // signed; positive = inflow, negative = outflow
    let instrument: Instrument    // for InstrumentAmount.formatted
  }

  let profileID: UUID
  let profileLabel: String
  let profileCurrency: String

  let asOf: Date                  // start-of-day snapshot time
  let dueNowCount: Int            // overdue + today
  let dueNowTotal: [Instrument: Decimal]   // per-instrument; widget formats first instrument + indicator if >1
  let upcomingRows: [Row]         // overdue + next 7 days, max 5, sorted ascending by dueDate
  let upcomingTotalInRange: Int   // total count in overdue+next-7 days range (may exceed 5)
}

// Shared/Widgets/UpcomingWidgetQuery.swift
enum UpcomingWidgetQuery {
  @WidgetActor
  static func read(
    profile: WidgetProfileSummary,
    asOf now: Date = Date(),
    calendar: Calendar = .current,
    maxRows: Int = 5
  ) throws -> UpcomingWidgetSnapshot { … }
}
```

`UpcomingWidgetQuery.read(...)`:

1. Opens `WidgetDataPath.profileDatabaseURL(for: profile.id)` via `DatabaseQueue` with `configuration.readonly = true` and a short busy timeout (200 ms).
2. Runs **two** focused queries inside one `db.read` block:
   - **Snapshot SELECT** — picks scheduled transactions whose `date BETWEEN ? AND ?` where the lower bound is `Date.distantPast` (overdue) and the upper bound is `startOfDay(now) + 7 days`. Selects `id`, `date`, `payee`, the summed leg quantity and the leg `instrument` for the row. `ORDER BY date ASC LIMIT 5`.
   - **Count SELECT** — `COUNT(*)` and `GROUP BY instrument, SUM(quantity)` for the same predicate restricted to `date <= startOfDay(now) + 1 day - 1 sec` (overdue + today) for `dueNowCount` / `dueNowTotal`. (Implementation detail: a single query with conditional aggregates is equivalent; whichever is simpler to plan-pin in tests.)
3. Closes the queue and returns the snapshot. No long-lived handle.
4. Throws `WidgetQueryError.profileDatabaseUnavailable` if the file is missing, locked beyond the timeout, or `integrity_check` fails on open. Timeline provider maps this to the placeholder entry.

Both queries are added to the existing GRDB plan-pinning tests under `MoolahTests` (per `guides/DATABASE_CODE_GUIDE.md`).

`@WidgetActor` is a new global actor declared in `Shared/Widgets/` to ensure no widget-side query runs concurrently against the same profile (overlapping read-only opens are technically safe in WAL mode but pointless and surprising in profiling traces).

### Multi-currency handling on the small widget

A profile can have transactions in multiple instruments. The small widget shows a single "total" beneath the count. To keep the extension free of conversion logic (per `guides/INSTRUMENT_CONVERSION_GUIDE.md`, which the widget does not link), the small widget displays:

- If `dueNowTotal.count == 1` → render the sole `InstrumentAmount` formatted (e.g. `−$224.19`).
- If `dueNowTotal.count > 1` → render the profile-currency instrument's amount if present (e.g. `−$224.19`) with a small `…` suffix; or, if no profile-currency entry is present, render `"Multiple currencies"` (`.caption2`, secondary colour).
- If `dueNowTotal.isEmpty` (i.e. `dueNowCount == 0`) → render `"Nothing due today"` (the empty-state case).

No FX conversion is performed in the widget extension. Conversion stays a host-app concern.

### What the widget extension links

| Module | Linked by widget? | Notes |
|---|---|---|
| `Shared/Widgets/` | Yes | New, narrow. |
| `Domain/Models/Instrument`, `InstrumentAmount`, `MonetaryAmount` | Yes | Pure value types, no SwiftUI / no SwiftData / no URLSession. |
| `Domain/Models/Transaction` (and its supporting enums / nested types) | Yes — only the parts the row decoder needs. If pulling the whole `Transaction` type pulls too much, the widget defines its own narrow `WidgetTransactionRow` row type that decodes the required columns. The plan picks one approach during implementation. | |
| `GRDB` (SPM package) | Yes | Same exact version pin as host. |
| `Backends/CloudKit/` | **No** | Widget never talks to CloudKit. |
| `Backends/GRDB/` | **No** | Widget runs its own focused SELECT; does not reuse repository implementations. |
| `Features/` | **No** | Widget defines its own views. |
| `Automation/` | **No** | Widget's intents live under `MoolahWidgets/Intents/`; host intents stay in `Automation/Intents/`. |

This is the explicit "do not bloat the extension" boundary.

## Routing — widget tap → host app

The two intents under `MoolahWidgets/Intents/` are the only navigation entry points.

```swift
// MoolahWidgets/Intents/OpenTransactionFromWidgetIntent.swift
struct OpenTransactionFromWidgetIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Transaction"
  static let openAppWhenRun = true
  static let isDiscoverable = false

  @Parameter(title: "Profile") var profile: WidgetProfileEntity
  @Parameter(title: "Transaction ID") var transactionID: String

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let transactionUUID = UUID(uuidString: transactionID) else {
      return .result()
    }
    #if os(macOS)
      let alreadyOpen = ProfileWindowLocator.activateExistingWindow(for: profile.id)
    #else
      let alreadyOpen = false
    #endif
    if !alreadyOpen {
      NavigationBridge.openProfile?(profile.id)
    }
    NavigationBridge.setPendingNavigation?(
      PendingNavigation(profileId: profile.id, destination: .transaction(transactionUUID)))
    return .result()
  }
}
```

`OpenUpcomingFromWidgetIntent` is identical in shape, destination `.upcoming`, no transaction parameter, profile parameter is **optional** so it can also be invoked with `nil` from the "profile not available" placeholder tap.

Both intents call `NavigationBridge` directly. They do not depend on `AutomationServiceLocator` (unlike the existing `OpenAccountIntent` which gates on `service != nil` for the diagnostic ordering): the system's `openAppWhenRun = true` guarantees the host is launched first, and `NavigationBridge.openProfile` is a `(UUID) -> Void` closure populated by `ProfileRootView` / `ProfileWindowView` early in the launch sequence. If the closure is `nil` because the host hasn't reached the point of installing it yet, `PendingNavigation` survives in `NavigationBridge.setPendingNavigation` — the relevant scene reads and clears it on first render. (We add a one-line assertion guard in `perform()` so we get a `Logger.fault` if both closures are unexpectedly `nil`.)

Coordination with the in-flight handoff design (`plans/2026-05-25-handoff-design.md`):

- The handoff design depends on `NavigationDestination` being `Codable` (it isn't today). The widget design does **not** require `NavigationDestination: Codable` — the widget only ever passes the profile UUID and a transaction UUID string across the process boundary, and reconstructs `.transaction(id)` / `.upcoming` on the host side. Either landing order works.
- The handoff design adds `.handlesExternalEvents(matching: [])` to `WindowGroup`. That is compatible with widget tap targets (which are not external events — `openAppWhenRun = true` invokes the host the same way Shortcuts do, going through the AppIntents framework and not through URL routing).
- Both designs share `NavigationBridge.openProfile`, `setPendingNavigation`, and `ProfileWindowLocator.activateExistingWindow`. Neither introduces conflicting changes to those types.

## Error handling and edge cases

| Situation | Behaviour | Where handled |
|---|---|---|
| Widget extension launches before migration has run (e.g. host hasn't been opened since the update) | Configuration intent's `WidgetProfileQuery` returns an empty list. Widgets show "Add Moolah widget — open the app first" placeholder. | `WidgetProfileDirectory.list()` returns `[]` if the profile-index DB doesn't exist in the App Group container. |
| Configured profile UUID was deleted in the app | Configuration intent dropdown no longer offers it. If the existing widget instance binds to a missing UUID, `UpcomingWidgetQuery.read(...)` throws `profileDatabaseUnavailable` → provider emits the "Profile not available — open Moolah to fix" placeholder. Tap opens host to profile picker via `OpenUpcomingFromWidgetIntent(profile: nil)`. | `UpcomingTransactionsListWidget.Provider.timeline(for:configuration:)`, `UpcomingTransactionsCountWidget.Provider.timeline(for:configuration:)`. |
| `data.sqlite` is locked beyond the 200 ms busy timeout (the host is mid-write) | `UpcomingWidgetQuery.read(...)` throws. Provider returns the previous-good snapshot encoded as a 5-minute `.after(...)` policy entry (a single retry attempt) — falling back to the placeholder only if the next attempt also fails. | `UpcomingWidgetQuery` + provider. |
| `PRAGMA integrity_check` fails when opening read-only | Throw and surface the placeholder; logger.fault from the extension. Widget keeps trying on next system-driven rebuild. | `UpcomingWidgetQuery`. |
| App Group container URL is `nil` (entitlement missing / device hasn't synced entitlements) | `WidgetDataPath.appGroupRoot()` throws; host migration aborts with a clear error in `IncompatibleProfileInfo` and the widget extension's queries throw `profileDatabaseUnavailable`. | `WidgetDataPath` + host bootstrap. |
| User has hidden a transaction (`Transaction.isHidden`) | Hidden transactions are excluded from the widget query. Same predicate the in-app "Upcoming & Overdue" card uses. | SQL `WHERE isHidden = 0` (matches existing convention). |
| Recurring template transaction's `date` is in the past but a `paidCopy` exists for today | The scheduled template still shows as "overdue" until the template's `date` is advanced — matches in-app behaviour. The widget doesn't need to know about `paidCopy` and does not deduplicate. | SQL only reads scheduled rows; no join. |
| Multi-currency profile, small widget cannot reduce to one instrument | Renders `"Multiple currencies"` text in `.caption2`. | `UpcomingCountView`. |
| `WidgetReloadCoordinator.reload()` invoked from background thread | `WidgetCenter.shared.reloadAllTimelines()` is thread-safe per Apple's docs; helper wraps it with a `Task { @MainActor in … }` only for symmetry with other host-side reload sites. | `Shared/Widgets/WidgetReloadCoordinator.swift`. |
| Migration crashes mid-copy | Flag file isn't written; partial destination directory is left in place. Next launch re-enters the migration which is idempotent at the per-profile-directory level (skip-if-exists). For safety, on re-entry, any per-profile subdirectory in `newRoot` that fails `integrity_check` is deleted before re-copying. | `ProfileContainerManager.bootstrap()` migration helper. |

## Telemetry

A new logger category `Widgets` under the existing `com.moolah.app` subsystem. The extension logs:

- Query start / end with profile UUID and row count (debug).
- `profileDatabaseUnavailable` paths (warning).
- `integrity_check` failures (fault).
- Configuration intent `suggestedEntities()` return size (debug).

The host's `WidgetReloadCoordinator.reload(reason:)` logs the reason string at debug level so we can correlate widget refreshes with host events when diagnosing staleness.

`os_signpost` instrumentation around `UpcomingWidgetQuery.read(...)` per `guides/BENCHMARKING_GUIDE.md` (intervals: query open, query exec, query close). Enables Instruments traces of widget refresh cost on real devices.

## Testing

### Unit tests (`MoolahTests_macOS` + `MoolahTests_iOS`)

- **`WidgetDataPathTests`** — App Group container URL resolution with mocked `AppGroupConfig.identifier`; env-scoped subdirectory math; profile DB path composition.
- **`UpcomingWidgetQueryTests`** — runs against `TestBackend` (in-memory GRDB DB seeded by the existing test harness) so we have full control over scheduled rows:
  - Empty profile → snapshot with `dueNowCount == 0`, `upcomingRows.isEmpty`.
  - Only overdue rows → snapshot rows are sorted ascending by date; `dueNowCount` includes them; counts and totals correct.
  - Only future rows within 7 days → no overdue, today=0, future rows sorted.
  - Rows beyond 7 days → excluded.
  - Mixed instruments → `dueNowTotal` keyed by instrument; row-level instrument preserved.
  - Hidden transactions → excluded.
  - Capped at `maxRows: 5` → returns first five chronologically, `upcomingTotalInRange` reflects the larger count.
  - Sign preservation — a positive-amount expense (refund) keeps its positive sign in the snapshot row.
- **`UpcomingWidgetQueryPlanPinningTests`** — `EXPLAIN QUERY PLAN` for both SELECTs uses the expected index (per `guides/DATABASE_CODE_GUIDE.md`).
- **`WidgetProfileDirectoryTests`** — opens a seeded profile-index DB and returns `WidgetProfileSummary` list; returns empty list when the DB doesn't exist; integrity check failure surfaces as `directoryUnavailable`.
- **`UpcomingWidgetSnapshotFormatTests`** — `dueNowTotal` aggregation, `Multiple currencies` fallback string, empty-state copy.
- **`OpenTransactionFromWidgetIntentTests`** — install fakes on `NavigationBridge.openProfile` / `setPendingNavigation` (same pattern as the handoff tests); macOS existing-window path skips `openProfile`; no-window path calls `openProfile` before `setPendingNavigation`; invalid `transactionID` string → no calls, returns `.result()`.
- **`OpenUpcomingFromWidgetIntentTests`** — same shape; nil-profile path opens to profile picker.
- **`ApplicationSupportToAppGroupMigrationTests`** — fixtures simulate the old `applicationSupportDirectory/<env>/profiles/<uuid>/data.sqlite` layout in a temp directory; the migration copies into a parallel temp App Group root; verifies flag file written last, integrity-check called, idempotent re-entry, abort-on-integrity-failure leaves the partial destination cleaned up and the old data untouched.
- **`WidgetReloadCoordinatorTests`** — stubs `WidgetCenter` (the helper takes an injected reload closure for testability); asserts the helper is invoked from each named host hook (transaction store mutations, sync completion, scene phase) — wired up where each hook lives.

### Integration tests

- **`WidgetExtensionSmokeTests`** (new test target if needed, or a runtime smoke check inside `MoolahTests_macOS`) — instantiate `UpcomingTransactionsListWidget.Provider` and `UpcomingTransactionsCountWidget.Provider`, hand them a real configuration intent with a seeded profile, drive `timeline(for:configuration:)`, and assert the returned `Timeline` contains the expected entry shape. This exercises the seam between `Shared/Widgets/` and `MoolahWidgets/` without needing an actual widget host.

### UI tests (`MoolahUITests_macOS`)

- No XCUITest coverage for the widget surfaces themselves — Apple does not expose the widget host to XCUITest. The host-side deep-link landing is covered: a UI test triggers `OpenTransactionFromWidgetIntent.perform()` directly via the existing AppleScript / AppIntents bridge and asserts that the resulting `ProfileWindowView` ends up on `.transaction(id)` for the right profile.

### Manual verification checklist

1. Add a medium "Upcoming" widget to the iPhone Home Screen, bind it to a profile with overdue + future scheduled transactions, observe correct rows.
2. Same on iPad.
3. Same on macOS desktop. Add it to Notification Centre too.
4. Add the small "Due" widget; verify count includes overdue + today; verify total in profile currency.
5. Tap a medium row → host opens to that transaction in the correct profile (re-focuses existing window on macOS, no second window).
6. Tap the small widget → host opens to Upcoming list in the correct profile.
7. Delete a profile in the app → widget that was bound to it shows the "Profile not available" placeholder within one timeline refresh.
8. With the widget pinned, edit a scheduled transaction in the app → widget reflects the change within ~5 s (driven by the `WidgetCenter.reloadAllTimelines()` hook on store mutation).
9. With the widget pinned, complete a CloudKit sync that brings in a new scheduled transaction → widget reflects within ~5 s.
10. Force-quit the app, leave the widget pinned, wait until the next midnight boundary on-device → "Today" rows flip to "1 day late" without a host-app refresh (multi-entry timeline).
11. Install over an existing v1.x build: launch host, observe migration runs once, second launch is a no-op, old `Application Support` data still present on disk.

## Open questions

None at this time. Architecture, data layer, layouts, error handling, and testing have been reviewed; the design is ready to plan.

## Plan deliverables

A subsequent implementation plan (`plans/2026-05-26-widgets-upcoming-transactions-plan.md`) will break the work into landable PRs. Anticipated slicing:

1. **App Group plumbing & migration** — entitlement files, `project.yml` knobs, `scripts/inject-entitlements.sh` parity, `WidgetDataPath`, `URL+MoolahStorage` refactor, `ProfileContainerManager` migration step, full migration tests. Ships behind the existing CloudKit env split; no widget yet. Smallest landable step that unblocks the rest.
2. **`Shared/Widgets/` query layer** — `UpcomingWidgetSnapshot`, `UpcomingWidgetQuery`, `WidgetProfileSummary`, `WidgetProfileDirectory`, plan-pinning tests, `os_signpost` instrumentation. No extension target yet.
3. **`MoolahWidgets` extension target** — empty bundle, configuration intent, `WidgetProfileEntity`, scaffolding, `xcodegen` regen, embed in both host apps.
4. **`UpcomingTransactionsListWidget`** — medium widget, `UpcomingListView`, `UpcomingRowView`, `WidgetEmptyStateView`, timeline provider, `OpenTransactionFromWidgetIntent`, intent tests.
5. **`UpcomingTransactionsCountWidget`** — small widget, `UpcomingCountView`, timeline provider, `OpenUpcomingFromWidgetIntent`, intent tests, multi-currency fallback.
6. **`WidgetReloadCoordinator` + host hooks** — wire `WidgetCenter.shared.reloadAllTimelines()` at every named pinch point (transaction store, sync completion, scene phase, profile mutation).
7. **Manual smoke + telemetry polish** — verify checklist, tune logger levels, document the new extension in `guides/` where appropriate.
