# Env-Scoped UserDefaults & Keychain

## Goal

A Development build of Moolah must be physically incapable of mutating any
state that a Production build reads. Today on-disk SQL / SwiftData state is
already scoped (under `Application Support/Development/` vs `…/Production/`)
via `URL.moolahScopedApplicationSupport`, and the CloudKit container is split
per build config (`iCloud.rocks.moolah.app.test` vs `…app.v2`). Two leak
vectors remain:

1. **`UserDefaults.standard`** — both builds use bundle id
   `rocks.moolah.app`, so they share one prefs plist. A Dev build that toggles
   any flag (sync state, migration gate, AnalysisStore last-used range) clobbers
   the value the user's Production build will read on next launch.
2. **`KeychainStore` API-key rows** — service `com.moolah.api-keys` is
   hard-coded in four places, and both rows (`account: "alchemy"`,
   `account: "coingecko"`) are `synchronizable: true`. A Dev build that writes
   a test key overwrites the user's iCloud-Keychain-replicated production key
   on every device.

This design closes both vectors using the same lever as the file-system split:
`CloudKitEnvironment.resolved()`.

## Non-Goals

- No migration of existing prefs / keychain content. Production users will
  see settings reset on the upgrade and must re-enter API keys (see
  *Consequences* below). This was an explicit user choice during brainstorming
  to keep the change simple and deterministic.
- No cleanup of legacy `.standard` plist entries or legacy
  `com.moolah.api-keys` keychain rows. They are abandoned in place; both
  builds stop reading and writing them on this version. A future release may
  add a one-shot cleanup runner once we're confident no one downgrades.
- Out of scope: `URLCache`, `HTTPCookieStorage` (no persistent cookies wired
  up despite the doc comment in `KeychainStore.swift`), App Groups (none
  configured), and anything already covered by
  `URL.moolahScopedApplicationSupport`.

## Mechanism

### Env-scoped UserDefaults

Add `Shared/UserDefaults+MoolahShared.swift`:

```swift
extension UserDefaults {
  /// Defaults suite scoped to the current CloudKit environment so a
  /// Development build cannot read or write state owned by a Production
  /// build (and vice versa). Production code paths use this in place of
  /// `.standard`. Tests continue to inject their own
  /// `UserDefaults(suiteName:)` for isolation.
  static let moolahShared: UserDefaults = {
    let env = CloudKitEnvironment.resolved()
    let suiteName = "rocks.moolah.app.\(env.storageSubdirectory.lowercased())"
    return UserDefaults(suiteName: suiteName) ?? .standard
  }()
}
```

Suite names:

- Production: `rocks.moolah.app.production`
- Development: `rocks.moolah.app.development`

These materialise as separate plists under `~/Library/Preferences/` on macOS,
so OS-level isolation is enforced.

The fallback to `.standard` exists only to preserve the type as
non-optional; `UserDefaults(suiteName:)` returns `nil` only for reserved
suite names (e.g. literal `"Apple Global Domain"`), which neither of our
strings is. The fallback is unreachable in practice.

### Defaults swap (production callers)

Every call site that currently defaults a `UserDefaults` parameter to
`.standard` is rerouted to `.moolahShared`. The full list is in *Affected
Files* below. Test sites that already inject a per-test `UserDefaults` are
unchanged. The UI-testing branch in `MoolahApp.init` (which builds a per-launch
`moolah.uitests.<UUID>` suite) is also unchanged.

### Env-scoped Keychain services

Add `Shared/KeychainServices.swift`:

```swift
enum KeychainServices {
  /// Service string for API-key keychain rows (CoinGecko, Alchemy).
  /// Scoped to the current CloudKit environment so a Development build's
  /// writes never replace a Production build's iCloud-Keychain-synced
  /// row on any of the user's devices.
  static var apiKeys: String {
    let env = CloudKitEnvironment.resolved()
    return "com.moolah.api-keys.\(env.storageSubdirectory.lowercased())"
  }
}
```

Service strings:

- Production: `com.moolah.api-keys.production`
- Development: `com.moolah.api-keys.development`

Replace each of the four hard-coded `service: "com.moolah.api-keys"` literals
(`App/ProfileSession+CryptoSync.swift`, `App/ProfileSession+Factories.swift`,
two in `Features/Settings/CryptoTokenStore.swift`'s `makeProduction(...)`)
with `service: KeychainServices.apiKeys`. The `synchronizable: true` flag is
preserved on the API-key rows — a Production user's API key still
replicates across their devices, just to a different service-keyed entry.

## Consequences for Existing Production Users

On first launch of the new Production build:

| What was lost | Effect |
|---|---|
| `AnalysisStore` last-used `selectedDateRange`, `selectedAccount`, `selectedCurrency` | Dropdowns return to their first-launch defaults (cosmetic). |
| `SyncProgress` "last received" timestamp + counters | Sidebar footer shows empty progress until the next sync round-trip completes. |
| `SyncCoordinator` state (`v2.sync.engine.serializedState`, etc.) | `CKSyncEngine` reinitialises from a fresh state token; first launch fetches change tags but no extra payload. |
| `LegacyZoneCleanup` "deleted" flag | Cleanup runner re-attempts the legacy-zone delete; idempotent. |
| `SwiftDataToGRDBMigrator` per-record-type flags | Migrator re-runs; SwiftData source store is empty in Production by this point so each step no-ops. |
| `SharedRegistryUnionRunner` flag | Re-runs against the live profile-index; produces the same union; idempotent. |
| `ValuationModeMigration` per-profile gate flags | Re-runs the per-profile migration; safe because the migration writes idempotent values. |
| `v2.rates.cache.cleared` flag | Re-attempts the legacy gzipped JSON rate cache delete; idempotent. |
| API keys (CoinGecko, Alchemy) | Settings panes show empty fields; user must paste keys once. No background calls fail until the first crypto refresh attempt. |

The implementation plan must include a one-pass audit of each migration-gate
runner with an explicit "safe to re-run from a clean Production-scoped state"
note. If any runner is *not* safely idempotent, the audit must fix it before
the swap lands.

## Tests

- `MoolahTests/Shared/UserDefaultsMoolahSharedTests.swift` — verify the
  suite name interpolates the resolved env's `storageSubdirectory` exactly
  (analogous to `URLMoolahStorageTests`).
- `MoolahTests/Shared/KeychainServicesTests.swift` — verify the
  `apiKeys` service string format produces
  `com.moolah.api-keys.development` / `com.moolah.api-keys.production` for
  the two `CloudKitEnvironment` cases.
- Per-runner audit: confirm each migration gate is idempotent under a
  fresh-state UserDefaults. Add a test for any runner that lacks one.
- Existing tests for `SyncProgress`, `AnalysisStore`,
  `SwiftDataToGRDBMigrator`, `SharedRegistryUnionRunner`,
  `LegacyZoneCleanup`, `ValuationModeMigration`,
  `cleanupLegacyRateCachesOnce`, and `CryptoSettingsAPIKeyTests` already
  inject their own `UserDefaults` / `KeychainStore` and need no change.

## Affected Files

### New

- `Shared/UserDefaults+MoolahShared.swift`
- `Shared/KeychainServices.swift`
- `MoolahTests/Shared/UserDefaultsMoolahSharedTests.swift`
- `MoolahTests/Shared/KeychainServicesTests.swift`

### Edited (defaults swap: `= .standard` → `= .moolahShared`)

- `App/MoolahApp+Setup.swift` — `cleanupLegacyRateCachesOnce`,
  `runProfileIndexMigrationIfNeeded`.
- `App/SharedRegistryUnionRunner.swift` — runner default.
- `App/ValuationModeMigration.swift` — `userDefaults` field default and
  `resetGateFlags(in:)` callers in production.
- `Backends/CloudKit/Sync/SyncCoordinator.swift` — `userDefaults` init
  default.
- `Backends/CloudKit/Sync/SyncProgress.swift` — `userDefaults` init
  default.
- `Backends/CloudKit/Sync/LegacyZoneCleanup.swift` — `performIfNeeded`
  default.
- `Backends/GRDB/Migration/SwiftDataToGRDBMigrator.swift` and the four
  `SwiftDataToGRDBMigrator+*.swift` extensions — every `defaults:
  UserDefaults = .standard` parameter.
- `Features/Analysis/AnalysisStore.swift` — `defaults: UserDefaults =
  .standard` parameter.

### Edited (keychain service)

- `App/ProfileSession+CryptoSync.swift` — `service: "com.moolah.api-keys"`
  → `service: KeychainServices.apiKeys`.
- `App/ProfileSession+Factories.swift` — same.
- `Features/Settings/CryptoTokenStore.swift` — both hard-coded service
  literals in `makeProduction(...)` switch to `KeychainServices.apiKeys`.

## Out of Scope (Verified)

- `URL.moolahScopedApplicationSupport` consumers (SQL DBs, sync state,
  backups) — already env-scoped.
- CloudKit container — already env-scoped.
- `URLCache`, `HTTPCookieStorage` — no persistent custom cache or cookie
  storage wired up.
- App Groups — none configured.
- The UI-testing branch in `MoolahApp.init` that builds a
  `moolah.uitests.<UUID>` suite — already isolated per launch and
  preserved unchanged.
