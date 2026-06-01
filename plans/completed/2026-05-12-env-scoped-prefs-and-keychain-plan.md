# Env-Scoped UserDefaults & Keychain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a Development build of Moolah from being able to read or write any `UserDefaults` value or any `KeychainStore` row that a Production build also touches.

**Architecture:** Add two tiny helpers — `UserDefaults.moolahShared` and `KeychainServices.apiKeys` — that suffix the resolved `CloudKitEnvironment` onto a base name (suite name / service string). Replace every production-side default of `.standard` and every literal `"com.moolah.api-keys"` service string with these helpers. No migration of existing prefs / keychain content (clean break per design).

**Tech Stack:** Swift 6, Swift Testing (`@Suite` / `@Test`), `UserDefaults`, `Security` framework (`SecItem` via `KeychainStore`), GRDB, CloudKit. Builds and tests run via `just` targets.

**Spec:** `plans/2026-05-12-env-scoped-prefs-and-keychain-design.md`.

---

## File Structure

### New

| File | Responsibility |
|---|---|
| `Shared/UserDefaults+MoolahShared.swift` | Static `UserDefaults.moolahShared` returning a suite scoped to the resolved CloudKit env, plus `makeSharedSuite(for:)` factory so tests can verify both env cases without process-level Info.plist swapping. |
| `Shared/KeychainServices.swift` | `enum KeychainServices` with `apiKeys` (env-scoped service string for the CoinGecko / Alchemy keychain rows) and `makeApiKeysService(for:)` for tests. |
| `MoolahTests/Shared/UserDefaultsMoolahSharedTests.swift` | Verifies suite-name format (`rocks.moolah.app.development` / `rocks.moolah.app.production`) and that `moolahShared` is not `.standard`. |
| `MoolahTests/Shared/KeychainServicesTests.swift` | Verifies service-string format for both env values. |

### Modified

Defaults swap (`= .standard` → `= .moolahShared`):

| File | Symbol |
|---|---|
| `App/MoolahApp+Setup.swift` | `cleanupLegacyRateCachesOnce(defaults:)`, `runProfileIndexMigrationIfNeeded(setup:defaults:)`. |
| `App/SharedRegistryUnionRunner.swift` | `run(...defaults:)` parameter. |
| `App/ValuationModeMigration.swift` | `resetGateFlags(in:)` is callable from any defaults; no production default to swap (callers always pass an explicit `userDefaults` field assigned at construction time — verified in Task 5). |
| `Backends/CloudKit/Sync/SyncCoordinator.swift` | `init(...userDefaults:)` parameter. |
| `Backends/CloudKit/Sync/SyncProgress.swift` | `init(userDefaults:)` parameter. |
| `Backends/CloudKit/Sync/LegacyZoneCleanup.swift` | `performIfNeeded(defaults:)` parameter. |
| `Backends/GRDB/Migration/SwiftDataToGRDBMigrator.swift` | `migrateIfNeeded(...defaults:)`, `resetMigrationFlags(in:)`. |
| `Backends/GRDB/Migration/SwiftDataToGRDBMigrator+CoreFinancialGraph.swift` | Every `defaults: UserDefaults` parameter that defaults to `.standard`. |
| `Backends/GRDB/Migration/SwiftDataToGRDBMigrator+Earmarks.swift` | Same. |
| `Backends/GRDB/Migration/SwiftDataToGRDBMigrator+Transactions.swift` | Same. |
| `Backends/GRDB/Migration/SwiftDataToGRDBMigrator+ProfileIndex.swift` | Same. |
| `Features/Analysis/AnalysisStore.swift` | `init(...defaults:)` parameter. |
| `Features/Import/FolderScanService.swift` | `init(...defaults:)` parameter. |
| `Features/Profiles/ProfileStore.swift` | `init(...defaults:)` parameter — persists `activeProfileID`. |
| `Shared/Views/ResizableVSplit.swift` | `init(...defaults:)` parameter (UI split-pane proportion). |

Keychain swap (`service: "com.moolah.api-keys"` → `service: KeychainServices.apiKeys`):

| File | Sites |
|---|---|
| `App/ProfileSession+CryptoSync.swift` | `resolveAlchemyApiKey()` |
| `App/ProfileSession+Factories.swift` | `makeMarketDataServices(database:)` |
| `Features/Settings/CryptoTokenStore.swift` | `convenience init(...)` (two `KeychainStore(...)` constructions) |

---

## Idempotency Pre-Audit (Background Reading)

The clean break means each migration-gate UserDefaults flag resets to absent on the new Production build's first launch. Before swapping, verify each runner is safe to re-run from a fresh-state defaults. No code changes expected — this is a sign-off step embedded in Task 4.

| Runner | Why safe to re-run |
|---|---|
| `cleanupLegacyRateCachesOnce` | Wraps `removeItem` in a `NSFileNoSuchFileError` swallow; second run finds nothing and no-ops. |
| `LegacyZoneCleanup.performIfNeeded` | Re-attempts `deleteRecordZone`; the zone-not-found path marks the flag done immediately. |
| `SwiftDataToGRDBMigrator.migrateIfNeeded` | Each per-type migrator uses `insert(onConflict: .ignore)` and `defer { committed ? flag = true : () }` (see file header). For an existing Production user the SwiftData source store is empty by this version, so every per-type fetch returns zero rows and the flag is set with no DB writes. |
| `SwiftDataToGRDBMigrator.migrateProfileIndexIfNeeded` | Same idempotency pattern as above. |
| `SharedRegistryUnionRunner.run` | Body-row inserts use `INSERT OR IGNORE`; meta-row inserts use `ON CONFLICT(pk) DO UPDATE SET earliest_date = MIN(...), latest_date = MAX(...)` — both idempotent under repeated application of the same source rows. The instrument-apply path delegates to `GRDBInstrumentRegistryRepository.applyRemoteChangesSync`, which is the production sync apply path and is idempotent by construction. |
| `ValuationModeMigration.run` | Calls `accountRepository.backfillValuationModeForUnsnapshotInvestmentAccounts()`, which only writes to investment accounts where `valuationMode` is unset; already-migrated accounts are untouched. |
| `SyncProgress.lastSettledAt` | A purely cosmetic timestamp surfaced in the sidebar footer; missing → empty footer until next round-trip. No correctness impact. |
| `AnalysisStore` last-used filters | Cosmetic (drop-down defaults). No correctness impact. |

**Note on `SyncCoordinator` engine state.** The CKSyncEngine state token is persisted to a JSON file under `URL.moolahScopedApplicationSupport`, not to UserDefaults (see `SyncCoordinator.swift:151`, `SyncCoordinator+Lifecycle.swift:120–122`, `SyncCoordinator+StatePersistence.swift:19`). Because `URL.moolahScopedApplicationSupport` is already env-scoped, the Task 4 UserDefaults swap has no effect on engine state — Development and Production builds already write to separate state files.

If the implementer finds any runner that does not match this analysis (e.g. file evolved since this plan was written), stop and update the plan / design before swapping.

---

## Task 1: `UserDefaults.moolahShared` Helper

**Files:**
- Create: `Shared/UserDefaults+MoolahShared.swift`
- Test: `MoolahTests/Shared/UserDefaultsMoolahSharedTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Shared/UserDefaultsMoolahSharedTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("UserDefaults+MoolahShared")
struct UserDefaultsMoolahSharedTests {
  @Test("makeSharedSuite(for: .development) is not UserDefaults.standard")
  func testMakeSharedSuiteDevelopmentIsNotStandard() {
    #expect(UserDefaults.makeSharedSuite(for: .development) !== UserDefaults.standard)
  }

  @Test("makeSharedSuite(for: .development) uses dotted lowercase env suffix")
  func testMakeSharedSuiteDevelopmentSuiteName() {
    let suite = UserDefaults.makeSharedSuite(for: .development)
    let key = "moolah.test.\(UUID().uuidString)"
    defer { suite.removeObject(forKey: key) }
    suite.set("dev", forKey: key)
    let mirror = UserDefaults(suiteName: "rocks.moolah.app.development")
    #expect(mirror?.string(forKey: key) == "dev")
  }

  @Test("makeSharedSuite(for: .production) is not UserDefaults.standard")
  func testMakeSharedSuiteProductionIsNotStandard() {
    #expect(UserDefaults.makeSharedSuite(for: .production) !== UserDefaults.standard)
  }

  @Test("makeSharedSuite(for: .production) uses dotted lowercase env suffix")
  func testMakeSharedSuiteProductionSuiteName() {
    let suite = UserDefaults.makeSharedSuite(for: .production)
    let key = "moolah.test.\(UUID().uuidString)"
    defer { suite.removeObject(forKey: key) }
    suite.set("prod", forKey: key)
    let mirror = UserDefaults(suiteName: "rocks.moolah.app.production")
    #expect(mirror?.string(forKey: key) == "prod")
  }

  @Test("dev and prod suites are isolated from each other")
  func testDevAndProdAreIsolated() {
    let dev = UserDefaults.makeSharedSuite(for: .development)
    let prod = UserDefaults.makeSharedSuite(for: .production)
    let key = "moolah.test.\(UUID().uuidString)"
    defer {
      dev.removeObject(forKey: key)
      prod.removeObject(forKey: key)
    }
    dev.set("dev-value", forKey: key)
    #expect(prod.string(forKey: key) == nil)
  }

  @Test("moolahShared resolves to a suite, never .standard")
  func testMoolahSharedIsNotStandard() {
    #expect(UserDefaults.moolahShared !== UserDefaults.standard)
  }
}
```

The file contains 6 `@Test` methods total:

1. `testMakeSharedSuiteDevelopmentIsNotStandard`
2. `testMakeSharedSuiteDevelopmentSuiteName`
3. `testMakeSharedSuiteProductionIsNotStandard`
4. `testMakeSharedSuiteProductionSuiteName`
5. `testDevAndProdAreIsolated`
6. `testMoolahSharedIsNotStandard`

- [ ] **Step 2: Run the test and confirm it fails**

```bash
just test UserDefaultsMoolahSharedTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build failure ("no member 'makeSharedSuite' / 'moolahShared'") or compile error referring to the missing extension.

- [ ] **Step 3: Implement the helper**

Create `Shared/UserDefaults+MoolahShared.swift`:

```swift
import Foundation

extension UserDefaults {
  /// Defaults suite scoped to the current CloudKit environment so a
  /// Development build cannot read or write state owned by a Production
  /// build (and vice versa). Production code paths inject this in place
  /// of `.standard`. Tests continue to inject their own
  /// `UserDefaults(suiteName:)` for isolation.
  ///
  /// `nonisolated(unsafe)` because `UserDefaults` itself is not declared
  /// `Sendable` by Foundation but is documented as thread-safe. The
  /// instance is initialised once at first access and never reassigned,
  /// so concurrent access is sound.
  nonisolated(unsafe) static let moolahShared: UserDefaults = makeSharedSuite(for: .resolved())

  /// Factory used by `moolahShared`. Exposed so tests can verify the
  /// suite-name format for both environments without process-level
  /// Info.plist swapping. Mirrors the `CloudKitEnvironment.resolve(from:)`
  /// pattern that `CloudKitEnvironmentTests` uses.
  static func makeSharedSuite(for env: CloudKitEnvironment) -> UserDefaults {
    let suiteName = "rocks.moolah.app.\(env.storageSubdirectory.lowercased())"
    // `UserDefaults(suiteName:)` returns `nil` only for reserved suite
    // names (e.g. literal `"Apple Global Domain"`). Neither of our
    // env-suffixed names is reserved, so the fallback is unreachable in
    // practice but keeps the return type non-optional.
    return UserDefaults(suiteName: suiteName) ?? .standard
  }
}
```

- [ ] **Step 4: Run the test and confirm it passes**

```bash
just test UserDefaultsMoolahSharedTests 2>&1 | tee .agent-tmp/test-output.txt
grep -E "Test Suite|passed|failed" .agent-tmp/test-output.txt | tail
```

Expected: all six tests pass.

- [ ] **Step 5: Commit**

```bash
git -C "$(pwd)" add Shared/UserDefaults+MoolahShared.swift MoolahTests/Shared/UserDefaultsMoolahSharedTests.swift
git -C "$(pwd)" commit -m "$(cat <<'EOF'
shared: add UserDefaults.moolahShared scoped to CloudKit env

Suite name is `rocks.moolah.app.<env>` (lowercased) so Development and
Production builds back to physically separate plists under
~/Library/Preferences/. `makeSharedSuite(for:)` factory exposed for tests.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `KeychainServices` Helper

**Files:**
- Create: `Shared/KeychainServices.swift`
- Test: `MoolahTests/Shared/KeychainServicesTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Shared/KeychainServicesTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("KeychainServices")
struct KeychainServicesTests {
  @Test("makeApiKeysService(for: .development) returns dotted lowercase env suffix")
  func testDevelopmentServiceStringFormat() {
    #expect(
      KeychainServices.makeApiKeysService(for: .development)
        == "com.moolah.api-keys.development")
  }

  @Test("makeApiKeysService(for: .production) returns dotted lowercase env suffix")
  func testProductionServiceStringFormat() {
    #expect(
      KeychainServices.makeApiKeysService(for: .production)
        == "com.moolah.api-keys.production")
  }

  @Test("apiKeys uses the resolved environment")
  func testApiKeysUsesResolvedEnvironment() {
    let resolved = CloudKitEnvironment.resolved()
    #expect(
      KeychainServices.apiKeys
        == KeychainServices.makeApiKeysService(for: resolved))
  }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

```bash
just test KeychainServicesTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build failure (`KeychainServices` undefined).

- [ ] **Step 3: Implement the helper**

Create `Shared/KeychainServices.swift`:

```swift
import Foundation

/// Env-scoped keychain service strings. A Development build targets
/// `com.moolah.api-keys.development`; a Production build targets
/// `com.moolah.api-keys.production`. Splitting the service string per
/// CloudKit env stops a Development build from overwriting a Production
/// build's iCloud-Keychain-synced API key on every device.
enum KeychainServices {
  /// Service string for API-key keychain rows (CoinGecko, Alchemy)
  /// scoped to the resolved CloudKit environment. Production code uses
  /// this in place of the previous `"com.moolah.api-keys"` literal.
  static let apiKeys: String = makeApiKeysService(for: .resolved())

  /// Factory used by `apiKeys`. Exposed so tests can verify the
  /// service-string format for both environments without process-level
  /// Info.plist swapping. Mirrors `CloudKitEnvironment.resolve(from:)`
  /// and the `makeSharedSuite(for:)` factory on `UserDefaults`.
  static func makeApiKeysService(for env: CloudKitEnvironment) -> String {
    "com.moolah.api-keys.\(env.storageSubdirectory.lowercased())"
  }
}
```

- [ ] **Step 4: Run the test and confirm it passes**

```bash
just test KeychainServicesTests 2>&1 | tee .agent-tmp/test-output.txt
grep -E "Test Suite|passed|failed" .agent-tmp/test-output.txt | tail
```

Expected: all three tests pass.

- [ ] **Step 5: Commit**

```bash
git -C "$(pwd)" add Shared/KeychainServices.swift MoolahTests/Shared/KeychainServicesTests.swift
git -C "$(pwd)" commit -m "$(cat <<'EOF'
shared: add KeychainServices.apiKeys scoped to CloudKit env

Service string is `com.moolah.api-keys.<env>` so Development and
Production builds write to separate keychain rows. The
`synchronizable: true` flag is preserved at the call sites in a
follow-up — only the service-string namespace lands in this commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Pre-swap Idempotency Sign-off

**Files:** None (read-only audit).

- [ ] **Step 1: Re-read each runner against the audit table**

For each row in the *Idempotency Pre-Audit* table above, open the named file and confirm the cited mechanism still exists and matches the description. The five runners that need confirmation:

- `App/MoolahApp+Setup.swift` — `cleanupLegacyRateCachesOnce` (NSFileNoSuchFileError swallow at the `removeItem` site).
- `Backends/CloudKit/Sync/LegacyZoneCleanup.swift` — `deleteLegacyZone` (zone-not-found marks done; thrown errors leave the flag unset).
- `Backends/GRDB/Migration/SwiftDataToGRDBMigrator.swift` and the four extensions — every per-type migrator uses `insert(onConflict: .ignore)` and a `committed` deferred flag set.
- `App/SharedRegistryUnionRunner.swift` — `mergeBodyRows` (`INSERT OR IGNORE`) and `mergeMetaRows` (`ON CONFLICT(pk) DO UPDATE SET earliest_date = MIN(...), latest_date = MAX(...)`).
- `App/ValuationModeMigration.swift` — `accountRepository.backfillValuationModeForUnsnapshotInvestmentAccounts()` only touches accounts where `valuationMode` is unset.

- [ ] **Step 2: If any runner has drifted from the audit, stop**

If a runner no longer matches, do NOT proceed to Task 4. Update this plan's audit table (and the design doc) and either fix the runner's idempotency *first* or escalate to the user. Do not paper over with a defensive guard inside the swap task.

- [ ] **Step 3: If everything matches, mark this task complete and proceed**

No commit — this is a read-only sign-off.

---

## Task 4: Defaults Swap (production callers)

**Files:**
- Modify: `App/MoolahApp.swift` — production branch of `MoolahApp.init` previously assigned `storeDefaults = .standard` explicitly; flip to `.moolahShared`. (Caught by the sharpened Task 6 grep, not the parameter-default form.)
- Modify: `App/MoolahApp+Setup.swift`
- Modify: `App/SharedRegistryUnionRunner.swift`
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift`
- Modify: `Backends/CloudKit/Sync/SyncProgress.swift`
- Modify: `Backends/CloudKit/Sync/LegacyZoneCleanup.swift`
- Modify: `Backends/GRDB/Migration/SwiftDataToGRDBMigrator.swift`
- Modify: `Backends/GRDB/Migration/SwiftDataToGRDBMigrator+CoreFinancialGraph.swift`
- Modify: `Backends/GRDB/Migration/SwiftDataToGRDBMigrator+Earmarks.swift`
- Modify: `Backends/GRDB/Migration/SwiftDataToGRDBMigrator+Transactions.swift`
- Modify: `Backends/GRDB/Migration/SwiftDataToGRDBMigrator+ProfileIndex.swift`
- Modify: `Features/Analysis/AnalysisStore.swift`

This is a mechanical refactor: every production-side `defaults: UserDefaults = .standard` parameter becomes `defaults: UserDefaults = .moolahShared` (and the equivalent for `userDefaults:`). Test sites that *pass an explicit value* are unaffected; test sites that *rely on the default* are not expected (verified in Step 2 below).

`ValuationModeMigration` is intentionally excluded: its `userDefaults` is a non-optional stored field (no production default) populated by the call site in `ProfileSession`. Update that call site instead — see Step 6.

`MoolahApp.init`'s UI-testing branch that constructs `UserDefaults(suiteName: "moolah.uitests.<UUID>")` is preserved unchanged.

- [ ] **Step 1: Audit existing test callers that rely on the production default**

```bash
grep -rn "performIfNeeded\b\|cleanupLegacyRateCachesOnce\b\|migrateIfNeeded\b\|SharedRegistryUnionRunner.run\b\|migrateProfileIndexIfNeeded\b\|AnalysisStore(\|SyncProgress(\|SyncCoordinator(" \
  --include="*.swift" MoolahTests MoolahUITests_macOS UITestSupport 2>/dev/null
```

For each match, check that the call site passes its own `defaults:` / `userDefaults:` argument. If a test relies on the production default (i.e. hits `.standard`), flag it before continuing — flipping the default to `.moolahShared` would silently change which suite that test reads from. Expected: every existing test injects its own; this step is a guard against drift.

- [ ] **Step 2: Apply the swap to every production parameter**

For each file listed above, change `= .standard` to `= .moolahShared` for every `defaults:` / `userDefaults:` parameter. The full list of edits:

`App/MoolahApp+Setup.swift`:

```diff
-  static func cleanupLegacyRateCachesOnce(defaults: UserDefaults = .standard) {
+  static func cleanupLegacyRateCachesOnce(defaults: UserDefaults = .moolahShared) {
```

```diff
   static func runProfileIndexMigrationIfNeeded(
     setup: ContainerSetup,
-    defaults: UserDefaults = .standard
+    defaults: UserDefaults = .moolahShared
   ) async {
```

`App/SharedRegistryUnionRunner.swift`:

```diff
     fileManager: FileManager = .default,
-    defaults: UserDefaults = .standard
+    defaults: UserDefaults = .moolahShared
   ) async {
```

`Backends/CloudKit/Sync/SyncCoordinator.swift` (around line 345):

```diff
-    userDefaults: UserDefaults = .standard,
+    userDefaults: UserDefaults = .moolahShared,
```

`Backends/CloudKit/Sync/SyncProgress.swift`:

```diff
-  init(userDefaults: UserDefaults = .standard) {
+  init(userDefaults: UserDefaults = .moolahShared) {
```

`Backends/CloudKit/Sync/LegacyZoneCleanup.swift`:

```diff
-  static func performIfNeeded(defaults: UserDefaults = .standard) {
+  static func performIfNeeded(defaults: UserDefaults = .moolahShared) {
```

`Backends/GRDB/Migration/SwiftDataToGRDBMigrator.swift`:

```diff
-  static func resetMigrationFlags(in defaults: UserDefaults = .standard) {
+  static func resetMigrationFlags(in defaults: UserDefaults = .moolahShared) {
```

```diff
   func migrateIfNeeded(
     modelContainer: ModelContainer,
     database: any DatabaseWriter,
-    defaults: UserDefaults = .standard
+    defaults: UserDefaults = .moolahShared
   ) async throws {
```

`Backends/GRDB/Migration/SwiftDataToGRDBMigrator+CoreFinancialGraph.swift`,
`Backends/GRDB/Migration/SwiftDataToGRDBMigrator+Earmarks.swift`,
`Backends/GRDB/Migration/SwiftDataToGRDBMigrator+Transactions.swift`,
`Backends/GRDB/Migration/SwiftDataToGRDBMigrator+ProfileIndex.swift`:

For each file, replace every `defaults: UserDefaults` parameter that defaults to `.standard` with `.moolahShared`. Use:

```bash
grep -n "defaults: UserDefaults = .standard" Backends/GRDB/Migration/SwiftDataToGRDBMigrator+*.swift
```

to enumerate exact lines, then edit each one. Some files use `defaults: UserDefaults` without a default at all (parameter is *forwarded* from the top-level call) — leave those alone.

`Features/Analysis/AnalysisStore.swift` (around line 57):

```diff
   init(
     repository: AnalysisRepository,
-    defaults: UserDefaults = .standard,
+    defaults: UserDefaults = .moolahShared,
     monthEnd: Int = Calendar.current.component(.day, from: Date())
   ) {
```

`Features/Import/FolderScanService.swift` (around line 27):

```diff
   init(
     profileId: UUID,
     importStore: ImportStore,
     preferences: ImportPreferences,
-    defaults: UserDefaults = .standard,
+    defaults: UserDefaults = .moolahShared,
     fileManager: FileManager = .default
   ) {
```

`Features/Profiles/ProfileStore.swift` (around line 92):

```diff
   init(
-    defaults: UserDefaults = .standard,
+    defaults: UserDefaults = .moolahShared,
     containerManager: ProfileContainerManager? = nil,
     syncCoordinator: SyncCoordinator? = nil
   ) {
```

`Shared/Views/ResizableVSplit.swift` (around line 45):

```diff
     init(
       autosaveName: String,
       initialTopHeight: CGFloat,
       minTopHeight: CGFloat = 80,
       minBottomHeight: CGFloat = 200,
-      defaults: UserDefaults = .standard,
+      defaults: UserDefaults = .moolahShared,
       @ViewBuilder top: @escaping () -> Top,
       @ViewBuilder bottom: @escaping () -> Bottom
     ) {
```

- [ ] **Step 3: Wire `ValuationModeMigration.userDefaults` from `.moolahShared`**

`ValuationModeMigration` has no production default — its `userDefaults` is a stored property assigned at call site. Find the construction site and pass `.moolahShared`:

```bash
grep -n "ValuationModeMigration(" --include="*.swift" -r App Backends Features
```

Expected hit: a single production construction (in `ProfileSession`-related code). For that site:

```diff
   ValuationModeMigration(
     profileId: ...,
     accountRepository: ...,
-    userDefaults: .standard
+    userDefaults: .moolahShared
   )
```

If the existing call site already passes a non-`.standard` value (e.g. an injected suite from a test fixture), do not change it — the swap targets only the production call.

- [ ] **Step 4: Build and run the full test suite**

```bash
mkdir -p .agent-tmp
just build-mac 2>&1 | tee .agent-tmp/build-output.txt
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -iE "failed|error:" .agent-tmp/test-output.txt | head -40 || echo "no failures"
```

Expected: clean build, full test pass. The swap is a refactor — it changes the default value of a parameter that all test sites were already injecting. Any test that relied on the production default will now read from `rocks.moolah.app.development` instead of `.standard` — Step 1 should have caught this.

- [ ] **Step 5: Format and lint**

```bash
just format
just format-check
```

Expected: no diffs after `format`; clean exit from `format-check`.

- [ ] **Step 6: Commit**

```bash
git -C "$(pwd)" add -A
git -C "$(pwd)" commit -m "$(cat <<'EOF'
prefs: route production callers to UserDefaults.moolahShared

Mechanical refactor of the `defaults: UserDefaults = .standard` /
`userDefaults: UserDefaults = .standard` defaults across stores,
sync coordinator, migration runners, and one-shot cleanup runners.
Test sites already inject their own defaults and are unaffected.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Keychain Service Swap

**Files:**
- Modify: `App/ProfileSession+CryptoSync.swift`
- Modify: `App/ProfileSession+Factories.swift`
- Modify: `Features/Settings/CryptoTokenStore.swift`

Four hard-coded `service: "com.moolah.api-keys"` literals become `service: KeychainServices.apiKeys`. The `synchronizable: true` flag stays.

- [ ] **Step 1: Audit existing tests that wire keychain stores explicitly**

```bash
grep -rn "com.moolah.api-keys" --include="*.swift" .
```

Expected: four production hits (the ones we're swapping) plus zero or more test hits. Test hits — `MoolahTests/Features/Settings/CryptoSettingsAPIKeyTests.swift` builds its own `KeychainStore(service: "com.moolah.test...")` per the existing `KeychainStoreTests` pattern, not against `com.moolah.api-keys`, so it is unaffected. Any test that *does* use `com.moolah.api-keys` directly should be flagged before continuing — flipping production to the env-scoped service would silently break it.

- [ ] **Step 2: Apply the swap**

`App/ProfileSession+CryptoSync.swift`:

```diff
   nonisolated static func resolveAlchemyApiKey() -> String? {
     let store = KeychainStore(
-      service: "com.moolah.api-keys", account: "alchemy", synchronizable: true)
+      service: KeychainServices.apiKeys, account: "alchemy", synchronizable: true)
     return try? store.restoreString()
   }
```

`App/ProfileSession+Factories.swift` (in `makeMarketDataServices`):

```diff
     let yahooClient = YahooFinanceClient()
     let apiKeyStore = KeychainStore(
-      service: "com.moolah.api-keys", account: "coingecko", synchronizable: true
+      service: KeychainServices.apiKeys, account: "coingecko", synchronizable: true
     )
```

`Features/Settings/CryptoTokenStore.swift` (in the production `convenience init`):

```diff
       apiKeyStore: KeychainStore(
-        service: "com.moolah.api-keys", account: "coingecko", synchronizable: true),
+        service: KeychainServices.apiKeys, account: "coingecko", synchronizable: true),
       alchemyKeyStore: KeychainStore(
-        service: "com.moolah.api-keys", account: "alchemy", synchronizable: true),
+        service: KeychainServices.apiKeys, account: "alchemy", synchronizable: true),
```

- [ ] **Step 3: Re-run the audit grep to verify zero remaining production literals**

```bash
grep -rn "com.moolah.api-keys" --include="*.swift" App Features Backends
```

Expected: no hits.

- [ ] **Step 4: Build and run the full test suite**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-output.txt
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -iE "failed|error:" .agent-tmp/test-output.txt | head -40 || echo "no failures"
```

Expected: clean build, full test pass.

- [ ] **Step 5: Format and lint**

```bash
just format
just format-check
```

Expected: no diffs after `format`; clean exit from `format-check`.

- [ ] **Step 6: Commit**

```bash
git -C "$(pwd)" add -A
git -C "$(pwd)" commit -m "$(cat <<'EOF'
keychain: route api-key rows to KeychainServices.apiKeys

Replaces the four hard-coded `service: "com.moolah.api-keys"` literals
with the env-scoped `KeychainServices.apiKeys`. Production builds now
read/write `com.moolah.api-keys.production`; Development builds use
`com.moolah.api-keys.development`. iCloud-Keychain `synchronizable: true`
flag is preserved on both rows.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: End-to-end Verification

**Files:** None (verification only).

- [ ] **Step 1: Confirm no `.standard` defaults survive in production code**

```bash
# Catches both parameter-default form (`defaults: UserDefaults = .standard`)
# and the assignment form (`storeDefaults = .standard`). The original review
# round of this plan only had the first pattern, which silently missed
# `App/MoolahApp.swift`'s explicit `storeDefaults = .standard` assignment in
# the production branch of `MoolahApp.init` — re-introducing that exact bug
# would slip past Step 1 if we kept the original pattern.
grep -rn '= \.standard\|= UserDefaults\.standard' --include="*.swift" App Backends Features Shared \
  | grep -v 'UserDefaults(suiteName: suiteName) ?? .standard'
```

Expected: zero hits. The allow-listed pattern (`UserDefaults(suiteName: suiteName) ?? .standard`) is the unreachable fallback inside `MoolahApp.swift`'s UI-testing branch and inside `Shared/UserDefaults+MoolahShared.swift` itself — both are intentional. Hits inside `MoolahTests/`, `MoolahUITests_macOS/`, `UITestSupport/` are fine.

- [ ] **Step 2: Confirm no remaining `com.moolah.api-keys` literal**

```bash
grep -rn "com.moolah.api-keys" --include="*.swift" App Backends Features Shared
```

Expected: zero hits.

- [ ] **Step 3: Run the full test suite for both platforms**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -iE "failed|error:" .agent-tmp/test-output.txt | head -40 || echo "no failures"
```

Expected: clean pass on both `MoolahTests_iOS` and `MoolahTests_macOS`.

- [ ] **Step 4: Manual smoke against a built app (Development build)**

```bash
just run-mac
```

Sanity checks once the app launches:

1. The app boots into the welcome / profile screen without crashing.
2. Add a profile, open it, and confirm sidebar / accounts render. (UserDefaults is empty for this env on first launch — `AnalysisStore` filter defaults, `SyncProgress.lastSettledAt` empty.)
3. In Settings → Crypto, paste a dummy CoinGecko / Alchemy key and confirm it persists across app relaunch — read by the new `KeychainServices.apiKeys` service, account `coingecko` / `alchemy`. Use `Keychain Access.app` if you want visual confirmation: search for `com.moolah.api-keys.development`; the row should appear, and the legacy `com.moolah.api-keys` row (if you used the app pre-swap) should be untouched.

Quit the app cleanly. There is no production-build smoke step in this plan — the production build cannot run without distribution signing.

- [ ] **Step 5: Delete temp files**

```bash
rm -f .agent-tmp/test-output.txt .agent-tmp/build-output.txt
```

- [ ] **Step 6: Open the PR**

```bash
git -C "$(pwd)" log --oneline origin/main..HEAD
git -C "$(pwd)" push -u origin worktree-env-scoped-prefs-and-keychain
gh pr create --title "Scope UserDefaults & Keychain to CloudKit env" --body "$(cat <<'EOF'
## Summary
- Adds `UserDefaults.moolahShared` and `KeychainServices.apiKeys`, both env-scoped via `CloudKitEnvironment.resolved()`.
- Swaps every production `defaults: UserDefaults = .standard` to `.moolahShared` and every `service: "com.moolah.api-keys"` literal to `KeychainServices.apiKeys`.
- Closes the two remaining vectors that let a Development build mutate state a Production build reads. Mirrors the existing file-system split under `Application Support/<env>/`.

Spec: `plans/2026-05-12-env-scoped-prefs-and-keychain-design.md`.
Plan: `plans/2026-05-12-env-scoped-prefs-and-keychain-plan.md`.

Clean-break: existing Production users will reset cosmetic prefs (last analysis filters, sync progress timestamps) and re-enter API keys on first launch of the new build. All migration-gate flags re-run idempotently per the audit in the plan.

## Test plan
- [ ] `just test` clean on both `MoolahTests_iOS` and `MoolahTests_macOS`.
- [ ] `just format-check` clean.
- [ ] Manual Development-build smoke: app launches, profile creation works, API-key entry round-trips through the new env-scoped keychain row.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

After the PR opens, follow the project's merge-queue convention — add it to the queue rather than merging manually.

---

## Self-Review Notes (in-plan)

**Spec coverage:**

| Spec section | Covered by |
|---|---|
| `UserDefaults.moolahShared` helper | Task 1 |
| `KeychainServices.apiKeys` helper | Task 2 |
| Defaults swap (8 files) | Task 4 |
| Keychain swap (3 files, 4 sites) | Task 5 |
| Idempotency audit per migration runner | Task 3 (sign-off) + plan-level audit table |
| New tests for both helpers | Task 1 + Task 2 |
| `ValuationModeMigration` call-site rewire | Task 4 Step 3 |
| Verify legacy plist / keychain rows are abandoned (no cleanup runner) | Task 6 Step 1 + Step 2 grep guards |
| Clean-break consequences for Production users | Task 6 Step 4 manual smoke |

**Placeholder scan:** No "TBD", "implement later", or unspecified test bodies — every code step has full code or a precise diff.

**Type consistency:** `moolahShared` (let) and `makeSharedSuite(for:)` (func) match across all references; `apiKeys` (let) and `makeApiKeysService(for:)` (func) match across all five references. Factory methods use `make` per `guides/CODE_GUIDE.md` §4.
