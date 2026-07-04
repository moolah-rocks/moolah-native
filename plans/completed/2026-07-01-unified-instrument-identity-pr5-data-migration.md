# Unified Cross-Chain Instrument Identity — PR5: One-Shot Data Migration Implementation Plan

> **Intended final home:** `plans/2026-07-01-unified-instrument-identity-pr5-data-migration.md`
> (currently drafted in scratchpad; move on acceptance).

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the app-side one-shot data migration that rewrites every stored `instrument_id` FK from a retired per-chain crypto id to its canonical id, aliases the retired shared-registry rows, purges + re-warms the retired price caches, re-pushes rewritten rows to CloudKit, and gates the capital-gains surface while a profile is mid-rewrite.

**Architecture:** An **async app-side migration struct** (`UnifiedInstrumentIdentityMigration`) modelled on `App/ValuationModeMigration.swift`. It is NOT a `DatabaseMigrator` step — a migrator closure gets one `Database` handle, but this migration needs the **shared** `profile-index.sqlite` (for the alias map + price caches) AND **each profile's** `data.sqlite` (for the FK rewrite) at once, plus the injected `CanonicalInstrumentResolver`. It is invoked once at startup (from `SyncCoordinator` lifecycle, after the shared DB is migrated and before the backfill scan), gated by a global `UserDefaults` completion flag. Every step is individually idempotent; the retired shared rows survive to the end (aliased, not deleted — physical deletion is deferred to PR6), so the retired→canonical mapping is always re-derivable after a mid-run kill.

**Tech Stack:** Swift 6, GRDB/SQLite (`DatabaseQueue`), CKSyncEngine, Swift Testing (`@Suite`/`@Test`), `UserDefaults(.moolahShared)`.

---

## 🚨 UNATTENDED-ON-PRODUCTION — THE CODE'S ROBUSTNESS IS THE SAFETY MECHANISM 🚨

**This migration runs UNATTENDED on real financial data when the released RC first launches on the production profile. There is no human-in-the-loop at prod-run time — the code's robustness IS the safety mechanism.**

Nobody — not Claude, not a script, not the user — ever runs this migration against the production profile by hand. It is app-startup code (the app-side migration struct, gated by a `UserDefaults` completion flag) that executes automatically on whatever profile the app opens. Production rollout is the user's normal **release-candidate** process: after this PR merges and is dev-validated, the user cuts an RC and releases it; when the released app launches on the production profile, **it** runs the migration itself, silently, with no confirmation prompt.

Because there is no safety net at run time, the code MUST have these properties, and each is heavily tested in this plan:

1. **Idempotent** — safe to re-run start-to-finish any number of times. A completed run re-invoked is a no-op (flag short-circuit); a partially-applied run re-invoked converges to the same correct end state (canonical ids are never mapping keys, so rewrite UPDATEs match nothing on a second pass; `alias_of` writes are value-identical). *(Tests: Task 2, Task 8.)*
2. **Per-profile atomic AND cross-profile resumable** — each profile's FK rewrite is ONE `data.sqlite` transaction, so a crash mid-profile leaves that profile byte-identical to its pre-run state (never half-rewritten). Across profiles, a crash after some profiles are done leaves the completion flag unset; the next launch re-derives the mapping (retired rows still present, aliased) and re-applies — finished profiles no-op, unfinished profiles get rewritten. *(Tests: Task 4 atomicity, Task 8 kill-mid-run resumability.)*
3. **Completion-flag gated** — the flag is written **last**, only after ALL steps succeed for ALL profiles. It is never set on a partial run. *(Test: Task 8.)*
4. **Capital-gains / cost-basis view gated** — while the flag is unset (any profile possibly mid-rewrite, mixed retired+canonical lots), the capital-gains surface renders "updating…" rather than a wrong figure. *(Test: Task 10.)*

**What happens if the app is killed mid-migration (spelled out):** the completion flag stays `false`. The shared alias step and the price-cache step are each single transactions (all-or-nothing). Each per-profile rewrite is a single transaction (all-or-nothing per profile). So at any kill point the on-disk state is a consistent prefix of the work: zero or more profiles fully rewritten, the rest untouched, retired rows still present and (partly) aliased, price caches either fully folded or not. The next launch re-runs `run()` from the top: re-derives the identical mapping, re-applies every step idempotently, and only then sets the flag. No state is corruptible by a kill.

**Validation before release** is a single manual step: launch the app in **DEVELOPMENT** and confirm the migration runs correctly on the dev profile (Task 13). Shipping to production is the user's RC/release process and is **outside this PR's tasks**.

---

## Global Constraints

Copied verbatim from the design (`design.md`) and the repo guides — every task's requirements implicitly include this section.

- **No `DatabaseMigrator` step for the FK rewrite.** It is an async app-side struct. The only migrator change in the whole feature was `v9_add_instrument_alias_of` (shipped in PR2, already at `ProfileIndexSchema.version == 9`). PR5 adds **no** new migrator registrations.
- **Aliasing, not deleting.** Retired `instrument` rows are kept and marked `alias_of`. Physical deletion + CloudKit tombstoning is **deferred to PR6**. Retired rows MUST survive PR5 so the mapping stays derivable on re-run.
- **`alias_of` is a LOCAL-ONLY column** — not in `InstrumentRow.CodingKeys`, never in `toCKRecord()`. Written only via raw SQL. (Established PR2/PR4.)
- **FK enforcement is OFF** (`v5_drop_foreign_keys`). The rewrite is a plain `UPDATE`, **NOT** a table rebuild. Do not rebuild any table.
- **Every multi-statement write is inside ONE `database.write { }` closure** (one transaction, one rollback boundary) — `DATABASE_CODE_GUIDE §5`. Each per-profile rewrite is atomic: a thrown error rolls the whole profile back.
- **Two files, no cross-file transaction.** Correctness rests on: ordering (alias + rewrite before any delete; retired rows survive), per-step idempotency, completion flag written last.
- **Unattended on production.** The migration runs automatically when the released RC first launches on the prod profile — no human confirmation at run time. Idempotency, per-profile atomicity, cross-profile resumability, and the flag-last discipline ARE the safety net; treat their tests as release-blocking.
- **`needs_push = 1` on every rewritten row** — set via raw SQL (`needsPush` is absent from these records' `CodingKeys`). It is NOT the re-push trigger; it protects the rewritten row from echo-clobber via the apply-path dirty guard (`ProfileDataSyncHandler+ApplyGuard.swift`, issue #1081).
- **Re-push is `SyncCoordinator.queueAllRecordsAfterImport(for:)`** — NOT `needs_push`, NOT the backfill scan (both are blind to already-synced rewritten rows; see Verified Fact 3).
- **Swift Testing** (`@Suite`/`@Test`, `#expect`/`#require`), not XCTest. One protocol conformance per extension file. Reference `guides/CODE_GUIDE.md`, `CONCURRENCY_GUIDE.md`, `DATABASE_CODE_GUIDE.md`, `DATABASE_SCHEMA_GUIDE.md`, `SYNC_GUIDE.md`.
- **Test wait timeouts default to 10s** — never pass short timeouts to match-wait helpers (memory: `feedback_test_wait_timeouts_10s`).
- **Money/instrument rule:** never `abs()` a `.trade` leg or auto-sign by leg position — the migration only rewrites `instrument_id`, never `quantity` or `type` (memory: `feedback_no_abs_on_trade_legs`).

---

## Verified codebase facts (file:line confirmed against `origin/main` + `origin/unified-identity-pr4`)

1. **`ValuationModeMigration` startup wiring** — `App/ValuationModeMigration.swift:11-57` is a `@MainActor struct` with `let profileId`, injected `accountRepository`, `userDefaults`, and `run() async throws` gated by `userDefaults.bool(forKey: gateKey)`. It is invoked from `App/ProfileSession+ValuationMigration.swift:20-31` (`runValuationModeMigration()`), which is called from `App/ProfileSession.swift:392` inside `setUp()`. PR5's migration mirrors the struct shape (injected dependencies + `run()` + UserDefaults gate) but is invoked **once globally** (not per-profile-session), because it needs both DB handles + all profiles at once.

2. **Both DB handles + all profiles are reachable from `SyncCoordinator`** via its `let containerManager: ProfileContainerManager` (`SyncCoordinator.swift:99`):
   - `ProfileContainerManager.profileIndexDatabase: DatabaseQueue` (`Shared/ProfileContainerManager.swift:42`) — the shared DB.
   - `ProfileContainerManager.database(for: UUID) throws -> DatabaseQueue` (`Shared/ProfileContainerManager.swift:68`) — a profile's `data.sqlite`.
   - `ProfileContainerManager.allProfileIds() async -> [UUID]` (`:186`).
   - `SyncCoordinator.sharedCanonicalResolver` (built in `App/MoolahApp+SharedInstrumentScope.swift:20`, passed to `SyncCoordinator.init`, kept on the coordinator).

3. **Re-push API confirmed = `queueAllRecordsAfterImport`.** `SyncCoordinator+Backfill.swift:26`:
   ```swift
   @discardableResult
   func queueAllRecordsAfterImport(for profileId: UUID) async -> [CKRecord.ID]
   ```
   It ensures the zone exists, gets the profile handler, calls `handler.queueAllExistingRecords()` (queues **every** row regardless of `encoded_system_fields` state), adds them to `syncEngine.state`, and calls `markBackfillScanComplete(for:)`. This is the correct mechanism: the startup backfill scan (`queueUnsyncedRecordsForAllProfiles`, `:65`) only queues rows where `encodedSystemFields == nil` (`handler.queueUnsyncedRecords()`), so already-synced rewritten rows are **invisible** to it; and `hasCompletedBackfillScan(for:)` (`:74`) would skip the profile entirely. `needs_push` is likewise irrelevant to both scans. Only `queueAllRecordsAfterImport` re-uploads an already-synced-but-locally-rewritten row.

4. **The six FK columns confirmed** (`Backends/GRDB/ProfileSchema+CoreFinancialGraph.swift` + `ProfileSchema+AccountGroups.swift`), all `instrument_id TEXT`:
   - `transaction_leg.instrument_id` (`:207`, `NOT NULL`)
   - `earmark.instrument_id` (`:129`, nullable) + `earmark.savings_target_instrument_id` (`:131`, nullable, legacy — `toDomain()` ignores it today)
   - `earmark_budget_item.instrument_id` (`:150`, `NOT NULL`, legacy — `toDomain()` ignores it today)
   - `account_group.instrument_id` (`ProfileSchema+AccountGroups.swift:27`, `NOT NULL`)
   - `investment_value.instrument_id` (`:251`, `NOT NULL`)
   - **PLUS the defensive `account.instrument_id`** (`:109`, `NOT NULL`, normally a fiat denomination but the schema does not enforce it).

5. **⚠️ NONE of these tables has a leading `instrument_id` index.** Confirmed by reading every `CREATE INDEX` in the profile schema:
   - `transaction_leg`: `instrument_id` appears only as the **3rd** column of composite covering indexes (`leg_analysis_by_type_account` `(type, account_id, instrument_id, …)`, `:231`) — not seekable by `WHERE instrument_id = ?`.
   - `investment_value`: `instrument_id` is the **4th** column of `iv_by_account_date_value` (`:260`) — not seekable.
   - `earmark` / `earmark_budget_item` / `account_group` / `account`: no index mentions `instrument_id` at all.
   **Decision (flagged for reviewers):** this is a **one-shot** migration UPDATE. A full-table SCAN per table happens once per install and costs milliseconds even at ~20k legs. Adding six permanent indexes to every user's DB forever, to speed a one-time UPDATE, is not warranted, and `instrument_id` is not an enforced FK (so `DATABASE_SCHEMA_GUIDE §4`'s "FK child index mandatory" rule does not apply). **This plan does NOT add indexes.** The plan-pinning tests (Task 6) assert the UPDATE plan is a **stable, intentional SCAN** and document why. `@database-schema-review` gets final say; if it insists, adding six `CREATE INDEX ... instrument_id` bodies would be a separate ProfileSchema migrator bump (v19), out of PR5's current "no new migrator step" constraint — escalate to the controller before doing so.

6. **`allCryptoRegistrations()` filters out the retired rows** (`GRDBInstrumentRegistryRepository.swift:149`, `.filter(Column("alias_of") == nil)`) — so the migration **CANNOT** derive its mapping from it (that method hides exactly the rows to be mapped). The migration MUST read the **unfiltered** crypto instrument set (Task 2 adds `allCryptoRegistrationsIncludingAliased()`).

7. **`CanonicalInstrumentResolver` API** (`Shared/CryptoImport/CanonicalInstrumentResolver.swift`): `func canonicalId(for: String) -> String`, `func isAlias(_: String) -> Bool`, `static func derive(from: [CryptoRegistration]) -> [String: String]`, `func refresh(with: [CryptoRegistration])`. `canonicalId` composes the static base map (`10:native`/`8453:native` → `1:native`; L2 USDC/USDT → mainnet contract) with the dynamic map (grouped by `assetKey`). The migration refreshes the resolver from the unfiltered registrations, then computes each id's canonical.

8. **Price-cache tables** (`ProfileIndexSchema+SharedInstrumentRegistry.swift:134-142`): `crypto_price(token_id TEXT, date, …, PRIMARY KEY(token_id, date))`; `crypto_token_meta(token_id TEXT PRIMARY KEY, …, first_traded_on TEXT)` (`first_traded_on` added by `v8`, `ProfileIndexSchema+CryptoFirstTradedOn.swift:16`). Purge precedent: `ProfileIndexSchema+PurgeCryptoPriceCache.swift` (`v7`) `DELETE FROM crypto_price; DELETE FROM crypto_token_meta;`.

9. **`needs_push` apply-path dirty guard exists** — `ProfileDataSyncHandler+ApplyGuard.swift` (issue #1081): an incoming echo is refused from overwriting the field values of a row whose `needs_push = 1`. Setting `needs_push = 1` on rewritten rows is what protects them until the re-push round-trips.

10. **Startup lifecycle insertion point** — `SyncCoordinator+Lifecycle.swift:200-236`: after `reconcilePendingAgainstLiveProfiles()` + `replayDeletionJournal()`, before `queueUnsyncedRecordsForAllProfiles()` (the backfill scan). The migration must run **here**, after the shared DB is migrated (the coordinator already holds a migrated `profileIndexDatabase`) and before the backfill scan, so re-pushed records aren't double-handled.

11. **Capital-gains surface** — `CostBasisEngine` (`Shared/CostBasisEngine.swift:9`) keys FIFO lots by `instrument.id` (`lots[instrument.id]`), so mixed retired+canonical ids split one asset into two FIFO queues. It is driven by `CapitalGainsCalculator.computeWithConversion` (`Shared/CapitalGainsCalculator.swift:43`), surfaced via `ReportingStore.loadCapitalGains(financialYear:)` → `capitalGainsResult`/`capitalGainsSummary` (`Features/Reports/ReportingStore.swift:97-124`), and consumed by `InsightStore+Snapshot.makeSnapshot()` (`Features/Insights/InsightStore+Snapshot.swift:14`, `capitalGains: sources.reporting.capitalGainsResult?.events ?? []`). Gate both entry points on the completion flag.

12. **Test DB openers**: `ProfileIndexDatabase.openInMemory()` (`Shared/ProfileContainerManager.swift:210`), `ProfileDatabase.openInMemory()` (`Backends/GRDB/ProfileDatabase.swift:37`) — both return a fully-migrated in-memory `DatabaseQueue`.

---

## File Structure

**New production files:**
- `App/UnifiedInstrumentIdentityMigration.swift` — the `@MainActor struct`: injected dependencies, `run()` orchestration, completion-flag / gate-key statics, mapping derivation.
- `App/UnifiedInstrumentIdentityMigration+SharedDB.swift` — the alias step + the price-cache step (both operate on `profileIndexDatabase`).
- `App/UnifiedInstrumentIdentityMigration+ProfileRewrite.swift` — the per-profile atomic FK rewrite (all seven UPDATEs in one `write`).

**Modified production files:**
- `Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository.swift` — add `allCryptoRegistrationsIncludingAliased()` (unfiltered variant of `allCryptoRegistrations()`); declare it on the `InstrumentRegistryRepository` protocol.
- `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift` — invoke the migration between `replayDeletionJournal()` and `queueUnsyncedRecordsForAllProfiles()`.
- `Features/Reports/ReportingStore.swift` — expose `isMigratingCrossChainIdentity`; short-circuit `loadCapitalGains` while migrating.
- `Features/Insights/InsightStore+Snapshot.swift` — pass empty `capitalGains` while migrating (no insight from mixed-id lots).
- `Features/Reports/Views/ReportsView.swift` (and/or the capital-gains card view surfaced by the implementer) — render an "Updating cross-chain holdings…" placeholder while `isMigratingCrossChainIdentity`.

**New test files (Swift Testing, one suite each):**
- `MoolahTests/App/UnifiedInstrumentIdentityMigrationMappingTests.swift`
- `MoolahTests/App/UnifiedInstrumentIdentityMigrationAliasStepTests.swift`
- `MoolahTests/App/UnifiedInstrumentIdentityMigrationProfileRewriteTests.swift`
- `MoolahTests/App/UnifiedInstrumentIdentityMigrationRollbackTests.swift`
- `MoolahTests/App/UnifiedInstrumentIdentityMigrationPlanPinningTests.swift`
- `MoolahTests/App/UnifiedInstrumentIdentityMigrationPriceCacheTests.swift`
- `MoolahTests/App/UnifiedInstrumentIdentityMigrationRePushTests.swift`
- `MoolahTests/App/UnifiedInstrumentIdentityMigrationEndToEndTests.swift`
- `MoolahTests/App/UnifiedInstrumentIdentityMigrationGateTests.swift`
- `MoolahTests/App/UnifiedInstrumentIdentityMigrationTestSupport.swift` — shared seed helpers (NOT a suite; `@testable` seed builders for both DBs).

---

## Task 1: Migration scaffold — dependencies, completion flag, mapping derivation

**Files:**
- Create: `App/UnifiedInstrumentIdentityMigration.swift`
- Modify: `Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository.swift` (add `allCryptoRegistrationsIncludingAliased()` + protocol decl)
- Test: `MoolahTests/App/UnifiedInstrumentIdentityMigrationMappingTests.swift`, `MoolahTests/App/UnifiedInstrumentIdentityMigrationTestSupport.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor
  struct UnifiedInstrumentIdentityMigration {
    let profileIndexDatabase: DatabaseQueue
    let dataDatabaseProvider: @Sendable (UUID) throws -> DatabaseQueue
    let allProfileIds: @Sendable () async -> [UUID]
    let registry: any InstrumentRegistryRepository
    let resolver: CanonicalInstrumentResolver
    let rePush: @MainActor (UUID) async -> Void
    let userDefaults: UserDefaults

    static let gateKey = "didMigrateUnifiedInstrumentIdentity"
    static func isComplete(in defaults: UserDefaults = .moolahShared) -> Bool
    static func resetGateFlag(in defaults: UserDefaults)   // --ui-testing only

    func run() async throws
    func deriveMapping() async throws -> [String: String]  // retired id -> canonical id
  }
  ```
- Consumes: `CanonicalInstrumentResolver` (PR2/PR4), `InstrumentRegistryRepository.allCryptoRegistrationsIncludingAliased()` (added here).

- [ ] **Step 1: Write the failing mapping test**

In `UnifiedInstrumentIdentityMigrationMappingTests.swift`:
```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@MainActor
@Suite struct UnifiedInstrumentIdentityMigrationMappingTests {
  @Test("deriveMapping maps every retired per-chain id to its canonical id")
  func mapsRetiredToCanonical() async throws {
    let harness = try await MigrationTestHarness.make()
    // Seed the shared registry with ETH on mainnet + OP + Base (all coingeckoId "ethereum"),
    // and OP-USDC alongside mainnet-USDC. Retired rows are still present (aliased or not).
    try await harness.seedSharedRegistry([
      .ethMainnet, .ethOptimism, .ethBase, .usdcMainnet, .usdcOptimism,
      .noKeyToken(chainId: 10, address: "0xdead"),  // no provider key -> its own canonical
    ])
    let mapping = try await harness.migration.deriveMapping()

    #expect(mapping["10:native"] == "1:native")
    #expect(mapping["8453:native"] == "1:native")
    #expect(mapping["10:0x0b2c639c533813f4aa9d7837caf62653d097ff85"]
      == "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
    #expect(mapping["1:native"] == nil)  // canonical is never a key
    #expect(mapping["10:0xdead"] == nil)  // no-key token stays chain-scoped
  }
}
```
`MigrationTestHarness` lives in `UnifiedInstrumentIdentityMigrationTestSupport.swift` — build it minimally here: opens `ProfileIndexDatabase.openInMemory()`, constructs a real `GRDBInstrumentRegistryRepository` + `CanonicalInstrumentResolver`, exposes `seedSharedRegistry(_:)` (raw upsert of `InstrumentRow`s including retired ids) and a `migration` whose `dataDatabaseProvider`/`allProfileIds`/`rePush` are no-op stubs for this task. The `.ethMainnet`/`.usdcOptimism` factories are static `Instrument` fixtures.

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-filter UnifiedInstrumentIdentityMigrationMappingTests`
Expected: FAIL — `allCryptoRegistrationsIncludingAliased` / `deriveMapping` not defined.

- [ ] **Step 3: Add the unfiltered registry read**

In `GRDBInstrumentRegistryRepository.swift`, beside `allCryptoRegistrations()` (`:137`), add the alias-inclusive variant (identical body minus the `.filter(Column("alias_of") == nil)`):
```swift
/// Every crypto registration INCLUDING aliased (retired) rows. The one-shot
/// identity migration needs the retired rows to derive the retired -> canonical
/// mapping, so it must NOT use `allCryptoRegistrations()` (which filters them
/// out via `alias_of IS NULL`). Read-only; no alias predicate.
func allCryptoRegistrationsIncludingAliased() async throws -> [CryptoRegistration] {
  try await database.read { db in
    try InstrumentRow
      .filter(Column("kind") == Instrument.Kind.cryptoToken.rawValue)
      .fetchAll(db)
      .compactMap { $0.toCryptoRegistration() }
  }
}
```
Add the method to the `InstrumentRegistryRepository` protocol. (`toCryptoRegistration()` is the existing `InstrumentRow` → `CryptoRegistration` mapper used by `allCryptoRegistrations()`; reuse it — confirm its exact name during implementation and match.)

- [ ] **Step 4: Implement the migration scaffold + `deriveMapping`**

Create `App/UnifiedInstrumentIdentityMigration.swift`:
```swift
import Foundation
import GRDB
import OSLog

/// One-shot app-side migration collapsing retired per-chain crypto identities
/// onto their canonical id across the shared registry AND every profile's data.
/// See plans/2026-07-01-unified-instrument-identity-pr5-data-migration.md.
///
/// NOT a `DatabaseMigrator` step: it needs `profile-index.sqlite` and each
/// profile's `data.sqlite` at once plus the `CanonicalInstrumentResolver`.
@MainActor
struct UnifiedInstrumentIdentityMigration {
  let profileIndexDatabase: DatabaseQueue
  let dataDatabaseProvider: @Sendable (UUID) throws -> DatabaseQueue
  let allProfileIds: @Sendable () async -> [UUID]
  let registry: any InstrumentRegistryRepository
  let resolver: CanonicalInstrumentResolver
  let rePush: @MainActor (UUID) async -> Void
  let userDefaults: UserDefaults

  static let gateKey = "didMigrateUnifiedInstrumentIdentity"
  static func isComplete(in defaults: UserDefaults = .moolahShared) -> Bool {
    defaults.bool(forKey: gateKey)
  }
  /// `--ui-testing` only — each UI-test launch is a fresh in-memory container.
  static func resetGateFlag(in defaults: UserDefaults) {
    defaults.removeObject(forKey: gateKey)
  }

  static let logger = Logger(
    subsystem: "com.moolah.app", category: "UnifiedInstrumentIdentityMigration")

  /// Retired id -> canonical id, composing the resolver's static + dynamic
  /// layers over the UNFILTERED crypto registration set. Only ids that resolve
  /// to a different id appear.
  func deriveMapping() async throws -> [String: String] {
    let registrations = try await registry.allCryptoRegistrationsIncludingAliased()
    resolver.refresh(with: registrations)  // populate dynamic layer from full set
    var mapping: [String: String] = [:]
    for registration in registrations {
      let id = registration.instrument.id
      let canonical = resolver.canonicalId(for: id)
      if canonical != id { mapping[id] = canonical }
    }
    return mapping
  }
}
```
(Add `run()` as a `throw`ing stub returning early on `Self.isComplete` for now — filled in Task 8.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `just test-filter UnifiedInstrumentIdentityMigrationMappingTests`
Expected: PASS.

- [ ] **Step 6: `just format-check` then commit**

```bash
just format-check
git add App/UnifiedInstrumentIdentityMigration.swift \
  Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository.swift \
  MoolahTests/App/UnifiedInstrumentIdentityMigrationMappingTests.swift \
  MoolahTests/App/UnifiedInstrumentIdentityMigrationTestSupport.swift
git commit -m "feat(migration): PR5 scaffold + unfiltered mapping derivation"
```

---

## Task 2: Alias step (shared DB) — mark retired rows `alias_of`, idempotent

**Files:**
- Create: `App/UnifiedInstrumentIdentityMigration+SharedDB.swift`
- Test: `MoolahTests/App/UnifiedInstrumentIdentityMigrationAliasStepTests.swift`

**Interfaces:**
- Produces: `func applyAliasStep(mapping: [String: String]) async throws` (writes `alias_of` on `profileIndexDatabase`).
- Consumes: `deriveMapping()` (Task 1).

- [ ] **Step 1: Write the failing test**
```swift
@Test("alias step sets alias_of on retired rows, canonical rows untouched, idempotent")
func aliasesRetiredRows() async throws {
  let harness = try await MigrationTestHarness.make()
  try await harness.seedSharedRegistry([.ethMainnet, .ethOptimism, .ethBase])
  let mapping = try await harness.migration.deriveMapping()

  try await harness.migration.applyAliasStep(mapping: mapping)

  #expect(try await harness.aliasOf("10:native") == "1:native")
  #expect(try await harness.aliasOf("8453:native") == "1:native")
  #expect(try await harness.aliasOf("1:native") == nil)  // canonical stays NULL

  // Idempotent: second run leaves the same values.
  try await harness.migration.applyAliasStep(mapping: mapping)
  #expect(try await harness.aliasOf("10:native") == "1:native")
}
```
Add `aliasOf(_:)` to the harness (raw `SELECT alias_of FROM instrument WHERE id = ?`).

- [ ] **Step 2: Run to verify it fails** — `just test-filter UnifiedInstrumentIdentityMigrationAliasStepTests` → FAIL (`applyAliasStep` undefined).

- [ ] **Step 3: Implement the alias step**

`App/UnifiedInstrumentIdentityMigration+SharedDB.swift`:
```swift
import Foundation
import GRDB

extension UnifiedInstrumentIdentityMigration {
  /// Step 1 (design §4): set `alias_of` on every retired shared-registry row.
  /// Raw SQL — `alias_of` is a local-only column outside `InstrumentRow.CodingKeys`.
  /// Idempotent: writing the same value twice is a no-op. All writes share one
  /// transaction so a mid-step throw rolls the shared DB back unchanged.
  func applyAliasStep(mapping: [String: String]) async throws {
    guard !mapping.isEmpty else { return }
    try await profileIndexDatabase.write { db in
      for (retired, canonical) in mapping {
        try db.execute(
          sql: "UPDATE instrument SET alias_of = ? WHERE id = ?",
          arguments: [canonical, retired])
      }
    }
  }
}
```

- [ ] **Step 4: Run to verify it passes** — Expected: PASS.
- [ ] **Step 5: `just format-check` then commit** — `git commit -m "feat(migration): PR5 alias step (shared DB, idempotent)"`

---

## Task 3: Per-profile FK rewrite — six columns + defensive account, one atomic write

**Files:**
- Create: `App/UnifiedInstrumentIdentityMigration+ProfileRewrite.swift`
- Test: `MoolahTests/App/UnifiedInstrumentIdentityMigrationProfileRewriteTests.swift`

**Interfaces:**
- Produces: `func rewriteProfile(_ profileId: UUID, mapping: [String: String]) async throws` (one `data.sqlite` `write` per profile).
- Consumes: `deriveMapping()` (Task 1), `dataDatabaseProvider`.

- [ ] **Step 1: Write the failing test**

Seed one profile's `data.sqlite` (via the harness) with: a `transaction_leg` on `10:native`; an `earmark` with `instrument_id = 10:native` and `savings_target_instrument_id = 8453:native`; an `earmark_budget_item.instrument_id = 10:native`; an `account_group.instrument_id = 10:native`; an `investment_value.instrument_id = 10:native`; and an `account.instrument_id = 10:native` (defensive — a retired crypto id where a fiat denomination is expected). Then:
```swift
@Test("rewriteProfile points every FK column at the canonical id and sets needs_push")
func rewritesAllFkColumns() async throws {
  let harness = try await MigrationTestHarness.make()
  let profileId = UUID()
  try await harness.seedProfileWithRetiredLegs(profileId)  // all six + account, all 10:native
  let mapping = ["10:native": "1:native", "8453:native": "1:native"]

  try await harness.migration.rewriteProfile(profileId, mapping: mapping)

  let db = try harness.dataDatabase(profileId)
  #expect(try harness.column(db, "transaction_leg", "instrument_id") == ["1:native"])
  #expect(try harness.column(db, "earmark", "instrument_id") == ["1:native"])
  #expect(try harness.column(db, "earmark", "savings_target_instrument_id") == ["1:native"])
  #expect(try harness.column(db, "earmark_budget_item", "instrument_id") == ["1:native"])
  #expect(try harness.column(db, "account_group", "instrument_id") == ["1:native"])
  #expect(try harness.column(db, "investment_value", "instrument_id") == ["1:native"])
  #expect(try harness.column(db, "account", "instrument_id") == ["1:native"])
  // needs_push set on every rewritten row.
  #expect(try harness.needsPushCount(db, "transaction_leg") == 1)
  #expect(try harness.needsPushCount(db, "investment_value") == 1)
  #expect(try harness.needsPushCount(db, "account") == 1)
}
```

- [ ] **Step 2: Run to verify it fails** — FAIL (`rewriteProfile` undefined).

- [ ] **Step 3: Implement the rewrite**

`App/UnifiedInstrumentIdentityMigration+ProfileRewrite.swift`:
```swift
import Foundation
import GRDB

extension UnifiedInstrumentIdentityMigration {
  /// Step 2 (design §4): rewrite every stored `instrument_id` FK from a retired
  /// id to its canonical, marking each rewritten row `needs_push = 1`. FK
  /// enforcement is OFF (`v5_drop_foreign_keys`), so a plain UPDATE — never a
  /// rebuild. All statements share ONE `write` transaction: a throw rolls the
  /// whole profile back byte-identical to its pre-run state (DATABASE_CODE_GUIDE §5).
  /// Idempotent: canonical rows are not in `mapping` keys, so a re-run's
  /// `WHERE instrument_id = :retired` matches nothing.
  func rewriteProfile(_ profileId: UUID, mapping: [String: String]) async throws {
    guard !mapping.isEmpty else { return }
    let database = try dataDatabaseProvider(profileId)
    try await database.write { db in
      for (retired, canonical) in mapping {
        for statement in Self.rewriteStatements {
          try db.execute(sql: statement, arguments: [canonical, retired])
        }
      }
    }
  }

  /// One UPDATE per FK column. `needs_push` set via raw SQL (absent from these
  /// records' CodingKeys). Order is irrelevant — each targets a distinct table
  /// or column. `"transaction"` is quoted (reserved word); the FK columns live
  /// on `transaction_leg`, not `"transaction"`.
  static let rewriteStatements: [String] = [
    "UPDATE transaction_leg      SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?",
    "UPDATE earmark              SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?",
    "UPDATE earmark              SET savings_target_instrument_id = ?, needs_push = 1 WHERE savings_target_instrument_id = ?",
    "UPDATE earmark_budget_item  SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?",
    "UPDATE account_group        SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?",
    "UPDATE investment_value     SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?",
    // Defensive: account.instrument_id is normally a fiat denomination, but the
    // schema does not enforce it — rewrite a retired crypto id if present.
    "UPDATE account              SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?",
  ]
}
```
Note: the `earmark` legacy-column UPDATE is a separate statement from the `earmark.instrument_id` UPDATE because they filter different columns; both set `needs_push`. If both columns on the same row are retired, the two UPDATEs touch the row twice within the same transaction — harmless.

- [ ] **Step 4: Run to verify it passes** — Expected: PASS.
- [ ] **Step 5: `just format-check` then commit** — `git commit -m "feat(migration): PR5 per-profile FK rewrite (7 columns, atomic, needs_push)"`

---

## Task 4: Rollback atomicity — a mid-run throw leaves the profile byte-identical

**Files:**
- Test: `MoolahTests/App/UnifiedInstrumentIdentityMigrationRollbackTests.swift`
- (No production change if Task 3 already wraps all statements in one `write` — this task PROVES it.)

**Interfaces:** Consumes `rewriteProfile` (Task 3).

- [ ] **Step 1: Write the failing rollback test**

Force a throw partway through the single `write` closure. The cleanest injection without a production seam: seed the profile, snapshot each affected table, then invoke `rewriteProfile` with a **poison mapping** that makes one statement throw — e.g. bind a value that violates a `STRICT`/`CHECK` constraint is hard here, so instead add a **test-only fault hook** to the migration:
```swift
// In UnifiedInstrumentIdentityMigration: optional injected fault for tests.
var faultAfterFirstStatement: (@Sendable (Database) throws -> Void)? = nil
```
and call `try faultAfterFirstStatement?(db)` once inside the `write` loop (guarded, default nil in production). The test sets it to `{ _ in throw MigrationTestError.injected }`:
```swift
@Test("a throw inside the profile write rolls every table back byte-identical")
func rollbackLeavesProfileUnchanged() async throws {
  let harness = try await MigrationTestHarness.make()
  let profileId = UUID()
  try await harness.seedProfileWithRetiredLegs(profileId)
  let before = try harness.snapshotAllTables(profileId)  // ordered rows per FK table

  var migration = harness.migration
  migration.faultAfterFirstStatement = { _ in throw MigrationTestError.injected }
  await #expect(throws: MigrationTestError.self) {
    try await migration.rewriteProfile(profileId, mapping: ["10:native": "1:native"])
  }

  let after = try harness.snapshotAllTables(profileId)
  #expect(after == before)  // no partial rewrite survived
}
```

- [ ] **Step 2: Run to verify it fails** — FAIL (`faultAfterFirstStatement` undefined).

- [ ] **Step 3: Add the guarded fault hook to `rewriteProfile`**

Insert `try faultAfterFirstStatement?(db)` after the first `db.execute` in the loop (inside the `write` closure). Document it as test-only, default nil. Because it throws inside the `write`, GRDB rolls the `IMMEDIATE` transaction back.

- [ ] **Step 4: Run to verify it passes** — Expected: PASS (snapshots equal).
- [ ] **Step 5: `just format-check` then commit** — `git commit -m "test(migration): PR5 rollback atomicity — mid-run throw leaves profile unchanged"`

---

## Task 5 skipped — folded into Task 3/4 (kept numbering; see Task 6 for plan-pinning)

*(Intentionally no Task 5: setup for the rewrite lives in Task 3; rollback in Task 4.)*

---

## Task 6: Plan-pinning tests for each of the seven UPDATEs (+ index decision doc)

**Files:**
- Test: `MoolahTests/App/UnifiedInstrumentIdentityMigrationPlanPinningTests.swift`

**Interfaces:** Consumes the seven `rewriteStatements` (Task 3).

- [ ] **Step 1: Write the plan-pinning test**

Per `DATABASE_CODE_GUIDE §6`, assert each UPDATE's `EXPLAIN QUERY PLAN` is a stable, intentional full SCAN (no leading `instrument_id` index exists — Verified Fact 5). Pinning the plan documents the decision and fails loudly if a future index silently changes it.
```swift
@Test("each rewrite UPDATE uses the documented full-table SCAN (no instrument_id index)")
func rewriteStatementsScanIntentionally() async throws {
  let harness = try await MigrationTestHarness.make()
  let db = try harness.dataDatabase(UUID())  // fresh migrated data.sqlite
  for statement in UnifiedInstrumentIdentityMigration.rewriteStatements {
    let plan = try harness.explainQueryPlan(db, statement, args: ["1:native", "10:native"])
    // One-shot migration: SCAN is acceptable and expected. Assert it is NOT
    // accidentally SEARCHing a wrong/partial index, and is a single scan.
    #expect(plan.contains("SCAN"), "unexpected plan for: \(statement)\n\(plan)")
    #expect(!plan.contains("USING INDEX instrument"),
      "no instrument_id index should exist yet: \(statement)\n\(plan)")
  }
}
```
Add `explainQueryPlan(_:_:args:)` to the harness (`EXPLAIN QUERY PLAN <sql>` via `Row.fetchAll`, joined `detail` column).

- [ ] **Step 2: Run to verify it fails** — FAIL (`explainQueryPlan` undefined).
- [ ] **Step 3: Implement the harness helper** — no production change.
- [ ] **Step 4: Run to verify it passes** — Expected: PASS.
- [ ] **Step 5: `just format-check` then commit** — `git commit -m "test(migration): PR5 plan-pin the seven rewrite UPDATEs (intentional SCAN)"`

> **Reviewer note baked into the test comment:** if `@database-schema-review` requires seek indexes, that is a separate v19 ProfileSchema migration adding `CREATE INDEX ... (instrument_id)` on all six tables — escalate to the controller (breaks PR5's "no new migrator step" constraint).

---

## Task 7: Price-cache step (shared DB) — `first_traded_on = MIN`, then purge retired rows

**Files:**
- Modify: `App/UnifiedInstrumentIdentityMigration+SharedDB.swift`
- Test: `MoolahTests/App/UnifiedInstrumentIdentityMigrationPriceCacheTests.swift`

**Interfaces:**
- Produces: `func applyPriceCacheStep(mapping: [String: String]) async throws`.

- [ ] **Step 1: Write the failing test**

Seed `crypto_token_meta` with `1:native first_traded_on = 2022-01-01`, `10:native first_traded_on = 2021-06-01`, `8453:native first_traded_on = NULL`; seed `crypto_price` rows for all three. After the step:
```swift
@Test("price cache: canonical first_traded_on = MIN(canonical, retired); retired caches purged")
func priceCacheMinAndPurge() async throws {
  let harness = try await MigrationTestHarness.make()
  try await harness.seedCryptoMeta([
    ("1:native", "2022-01-01"), ("10:native", "2021-06-01"), ("8453:native", nil)])
  try await harness.seedCryptoPrice(["1:native", "10:native", "8453:native"])
  let mapping = ["10:native": "1:native", "8453:native": "1:native"]

  try await harness.migration.applyPriceCacheStep(mapping: mapping)

  #expect(try await harness.firstTradedOn("1:native") == "2021-06-01")  // earlier retired wins
  #expect(try await harness.cryptoMetaExists("10:native") == false)
  #expect(try await harness.cryptoPriceCount("10:native") == 0)
  #expect(try await harness.cryptoPriceCount("1:native") > 0)          // canonical retained
}
```

- [ ] **Step 2: Run to verify it fails** — FAIL (`applyPriceCacheStep` undefined).

- [ ] **Step 3: Implement the step**

Append to `+SharedDB.swift`:
```swift
extension UnifiedInstrumentIdentityMigration {
  /// Step 4 (design §4): fold the retired price caches into the canonical's.
  /// First push `first_traded_on` back to MIN(canonical, all retireds) so the
  /// canonical never loses an earlier trade date; THEN delete the retired
  /// `crypto_price` + `crypto_token_meta` rows (order matters — MIN reads the
  /// retired meta rows before they are deleted). Re-fetch is cheap
  /// (precedent: v7_purge_crypto_price_cache). One transaction.
  func applyPriceCacheStep(mapping: [String: String]) async throws {
    guard !mapping.isEmpty else { return }
    // Group retired ids by canonical.
    var retiredByCanonical: [String: [String]] = [:]
    for (retired, canonical) in mapping {
      retiredByCanonical[canonical, default: []].append(retired)
    }
    try await profileIndexDatabase.write { db in
      for (canonical, retireds) in retiredByCanonical {
        let ids = [canonical] + retireds
        let placeholders = databaseQuestionMarks(count: ids.count)
        // MIN ignores NULLs; if all are NULL the SELECT yields NULL -> no-op set.
        try db.execute(
          sql: """
            UPDATE crypto_token_meta
               SET first_traded_on = (
                 SELECT MIN(first_traded_on) FROM crypto_token_meta
                  WHERE token_id IN (\(placeholders)) AND first_traded_on IS NOT NULL)
             WHERE token_id = ?
               AND EXISTS (
                 SELECT 1 FROM crypto_token_meta
                  WHERE token_id IN (\(placeholders)) AND first_traded_on IS NOT NULL)
            """,
          arguments: StatementArguments(ids + [canonical] + ids))
        let retiredPlaceholders = databaseQuestionMarks(count: retireds.count)
        try db.execute(
          sql: "DELETE FROM crypto_price WHERE token_id IN (\(retiredPlaceholders))",
          arguments: StatementArguments(retireds))
        try db.execute(
          sql: "DELETE FROM crypto_token_meta WHERE token_id IN (\(retiredPlaceholders))",
          arguments: StatementArguments(retireds))
      }
    }
  }
}
```
`databaseQuestionMarks(count:)` is GRDB's helper for `?,?,…`. Confirm the exact spelling during implementation (GRDB ships `databaseQuestionMarks(count:)`); if unavailable, build the string locally. Guard against empty `retireds` (skip the DELETEs) — though `mapping` non-empty and grouping guarantee ≥1.

- [ ] **Step 4: Run to verify it passes** — Expected: PASS.
- [ ] **Step 5: `just format-check` then commit** — `git commit -m "feat(migration): PR5 price-cache fold (first_traded_on MIN + purge retired)"`

---

## Task 8: `run()` orchestration + re-push, end-to-end, idempotent

**Files:**
- Modify: `App/UnifiedInstrumentIdentityMigration.swift` (`run()`)
- Test: `MoolahTests/App/UnifiedInstrumentIdentityMigrationRePushTests.swift`, `MoolahTests/App/UnifiedInstrumentIdentityMigrationEndToEndTests.swift`

**Interfaces:**
- Produces final `run()`:
  ```swift
  // Order (design §4): alias (shared) -> per profile { rewrite; re-push } -> price cache (shared) -> flag.
  func run() async throws
  ```
- Consumes: `applyAliasStep`, `rewriteProfile`, `rePush`, `applyPriceCacheStep`.

- [ ] **Step 1: Write the failing re-push test**

Record `rePush` invocations via a stub closure capturing profile ids:
```swift
@Test("run re-pushes each rewritten profile via queueAllRecordsAfterImport")
func rePushesRewrittenProfiles() async throws {
  let harness = try await MigrationTestHarness.make()
  let profileA = UUID()
  try await harness.seedSharedRegistry([.ethMainnet, .ethOptimism])
  try await harness.seedProfileWithRetiredLegs(profileA)
  let rePushed = harness.rePushRecorder  // actor/box capturing ids

  try await harness.migration(profileIds: [profileA]).run()

  #expect(await rePushed.ids == [profileA])
}
```

- [ ] **Step 2: Write the failing end-to-end test** (separate file)
```swift
@Test("end-to-end: every FK canonical, retired rows aliased, OP->Coinstash reconciles, idempotent")
func endToEnd() async throws {
  let harness = try await MigrationTestHarness.make()
  let profileId = UUID()
  try await harness.seedSharedRegistry([.ethMainnet, .ethOptimism, .ethBase, .usdcMainnet, .usdcOptimism])
  // Seed: per-chain ETH legs, earmarks incl. legacy cols, account groups,
  // investment values, AND a Coinstash "ETH" leg already on 1:native, plus a
  // transfer pair OP-wallet(10:native) -> Coinstash(1:native).
  try await harness.seedFullProfile(profileId)

  try await harness.migration(profileIds: [profileId]).run()

  // Every FK canonical.
  #expect(try await harness.allInstrumentIds(profileId, "transaction_leg").allSatisfy { !$0.hasPrefix("10:") && !$0.hasPrefix("8453:") })
  // Retired shared rows aliased (survive, not deleted).
  #expect(try await harness.aliasOf("10:native") == "1:native")
  #expect(try await harness.rowExists("instrument", id: "10:native"))  // NOT deleted (PR6)
  // OP->Coinstash transfer now reconciles: both legs reference 1:native.
  #expect(try await harness.transferLegsShareInstrument(profileId) == "1:native")
  // Completion flag set.
  #expect(UnifiedInstrumentIdentityMigration.isComplete(in: harness.userDefaults))

  // Idempotent re-run: no change, flag short-circuits.
  let before = try harness.snapshotAllTables(profileId)
  try await harness.migration(profileIds: [profileId]).run()
  #expect(try harness.snapshotAllTables(profileId) == before)
}
```

- [ ] **Step 2b: Write the failing kill-mid-run resumability test** (same end-to-end file)

This is a **release-blocking** test — it proves the unattended-on-prod safety property. Simulate a crash after the FIRST profile is rewritten but before the flag is set (two profiles, a fault injected on the second profile's rewrite), then re-run cleanly and assert convergence:
```swift
@Test("a crash mid-run leaves a consistent prefix; the next launch converges (resumable)")
func killMidRunIsResumable() async throws {
  let harness = try await MigrationTestHarness.make()
  let profileA = UUID(), profileB = UUID()
  try await harness.seedSharedRegistry([.ethMainnet, .ethOptimism])
  try await harness.seedProfileWithRetiredLegs(profileA)
  try await harness.seedProfileWithRetiredLegs(profileB)
  let snapshotBbefore = try harness.snapshotAllTables(profileB)

  // First run crashes on profile B's rewrite (profile A already committed).
  var crashing = harness.migration(profileIds: [profileA, profileB])
  crashing.faultOnProfile = profileB   // test-only hook: throw inside B's write
  await #expect(throws: MigrationTestError.self) { try await crashing.run() }

  // Consistent prefix: A fully rewritten, B byte-identical (atomic per profile),
  // flag NOT set.
  #expect(try await harness.allInstrumentIds(profileA, "transaction_leg").allSatisfy { $0 == "1:native" })
  #expect(try harness.snapshotAllTables(profileB) == snapshotBbefore)
  #expect(!UnifiedInstrumentIdentityMigration.isComplete(in: harness.userDefaults))

  // Clean re-run converges: A no-ops, B rewritten, flag set.
  try await harness.migration(profileIds: [profileA, profileB]).run()
  #expect(try await harness.allInstrumentIds(profileB, "transaction_leg").allSatisfy { $0 == "1:native" })
  #expect(UnifiedInstrumentIdentityMigration.isComplete(in: harness.userDefaults))
}
```
Reuse/extend the Task 4 `faultAfterFirstStatement` seam into a per-profile `faultOnProfile: UUID?` that throws inside the matching profile's `write` (keeping the throw INSIDE the transaction so the per-profile rollback still holds).

- [ ] **Step 3: Run all three to verify they fail** — FAIL (`run()` is still the early-return stub; `faultOnProfile` undefined).

- [ ] **Step 4: Implement `run()`**
```swift
func run() async throws {
  if Self.isComplete(in: userDefaults) { return }
  guard !Task.isCancelled else { return }

  let mapping = try await deriveMapping()
  // Empty mapping (fresh install, nothing retired) still flows to the flag.
  try await applyAliasStep(mapping: mapping)          // shared DB, step 1

  for profileId in await allProfileIds() {
    guard !Task.isCancelled else { return }           // partial progress is safe: re-run resumes
    try await rewriteProfile(profileId, mapping: mapping)  // data.sqlite, step 2 (atomic)
    await rePush(profileId)                            // step 3: queueAllRecordsAfterImport
  }

  try await applyPriceCacheStep(mapping: mapping)      // shared DB, step 4
  guard !Task.isCancelled else { return }
  userDefaults.set(true, forKey: Self.gateKey)         // step 5: flag LAST
  Self.logger.info(
    "Unified identity migration complete: \(mapping.count, privacy: .public) retired ids")
}
```
Note the flag is set only after **all** profiles + both shared steps succeed. A kill mid-loop leaves the flag unset; the next launch re-derives the mapping (retired rows still present + aliased) and re-applies — rewritten profiles are no-ops (canonical ids aren't mapping keys), remaining profiles get rewritten. Add the test-only `faultOnProfile: UUID?` seam to `rewriteProfile` (throw inside the matching profile's `write`, alongside the Task 4 `faultAfterFirstStatement` hook) so the kill-mid-run test can crash on a chosen profile without a production seam.

- [ ] **Step 5: Run all three to verify they pass** — Expected: PASS (re-push, end-to-end, kill-mid-run resumability).
- [ ] **Step 6: `just format-check` then commit** — `git commit -m "feat(migration): PR5 run() orchestration + re-push; idempotent + kill-mid-run resumable"`

---

## Task 9: Startup wiring — invoke the migration in the sync lifecycle before backfill

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift` (between `replayDeletionJournal()` and `queueUnsyncedRecordsForAllProfiles()`, `:214`–`:235`)
- Test: `MoolahTests/App/UnifiedInstrumentIdentityMigrationGateTests.swift` (ordering + gate behaviour via the coordinator's test hooks)

**Interfaces:**
- Consumes: `SyncCoordinator.{containerManager, sharedCanonicalResolver, sharedInstrumentRegistry}` + `queueAllRecordsAfterImport`.

- [ ] **Step 1: Write the failing wiring test**

Add a `SyncCoordinator` test hook `runUnifiedIdentityMigrationForTesting()` that constructs and runs the migration exactly as the lifecycle does, so the ordering/wiring is asserted without dispatching a real CKSyncEngine start:
```swift
@Test("coordinator runs the identity migration against the shared + profile DBs")
func coordinatorRunsMigration() async throws {
  let env = try await SyncCoordinatorTestEnvironment.make(profiles: [profileId])
  try await env.seedRetiredData(profileId)  // shared registry + one profile

  await env.coordinator.runUnifiedIdentityMigrationForTesting()

  #expect(UnifiedInstrumentIdentityMigration.isComplete(in: env.userDefaults))
  #expect(try await env.aliasOf("10:native") == "1:native")
}
```

- [ ] **Step 2: Run to verify it fails** — FAIL (hook undefined).

- [ ] **Step 3: Wire the migration into the lifecycle**

In `SyncCoordinator+Lifecycle.swift`, add a `@MainActor` helper and call it after `replayDeletionJournal()` (`:214`), before the first-launch queue / backfill:
```swift
// PR5: one-shot unified cross-chain instrument identity migration. Runs after
// the shared DB is migrated and BEFORE the backfill scan so re-pushed records
// are not double-handled. Gated internally by its UserDefaults completion flag;
// a no-op once complete. Non-fatal: a throw is logged, next launch retries
// (apply-time canonicalization from PR4 backstops correctness meanwhile).
func runUnifiedIdentityMigration() async {
  let migration = UnifiedInstrumentIdentityMigration(
    profileIndexDatabase: containerManager.profileIndexDatabase,
    dataDatabaseProvider: { [containerManager] in try containerManager.database(for: $0) },
    allProfileIds: { [containerManager] in await containerManager.allProfileIds() },
    registry: sharedInstrumentRegistry,
    resolver: sharedCanonicalResolver,
    rePush: { [weak self] in await self?.queueAllRecordsAfterImport(for: $0) },
    userDefaults: userDefaults)
  do { try await migration.run() }
  catch { logger.error("Unified identity migration failed: \(error, privacy: .public)") }
}
```
Call `await runUnifiedIdentityMigration()` at `:215` (after `replayDeletionJournal()`, before `if runFirstLaunchQueue`). Add `runUnifiedIdentityMigrationForTesting() async { await runUnifiedIdentityMigration() }` to the test-hooks section. Confirm `sharedInstrumentRegistry` / `sharedCanonicalResolver` / `userDefaults` property names on `SyncCoordinator` during implementation and match them.

- [ ] **Step 4: Run to verify it passes** — Expected: PASS.
- [ ] **Step 5: `just format-check` then commit** — `git commit -m "feat(migration): PR5 wire identity migration into sync lifecycle (pre-backfill)"`

> **Concurrency check for `@concurrency-review`:** the migration is `@MainActor`; each `try await db.write` hops to GRDB's serial executor (does not block the main thread for the duration), and `queueAllRecordsAfterImport` is already `@MainActor`. The captured `containerManager` closures are `@Sendable`; `ProfileContainerManager.database(for:)`/`allProfileIds()` are the existing thread-safe accessors.

---

## Task 10: Capital-gains UX gate — render "updating…" while mid-migration

**Files:**
- Modify: `Features/Reports/ReportingStore.swift` (expose `isMigratingCrossChainIdentity`; short-circuit `loadCapitalGains`)
- Modify: `Features/Insights/InsightStore+Snapshot.swift` (empty `capitalGains` while migrating)
- Modify: `Features/Reports/Views/ReportsView.swift` (or the implementer-confirmed capital-gains card view) — placeholder
- Test: append to `MoolahTests/App/UnifiedInstrumentIdentityMigrationGateTests.swift`

**Interfaces:**
- Consumes: `UnifiedInstrumentIdentityMigration.isComplete(in:)` (Task 1).

- [ ] **Step 1: Write the failing gate + FIFO-merge tests**
```swift
@Test("capital gains are gated while migration incomplete")
func capitalGainsGatedWhileMigrating() async throws {
  let defaults = UserDefaults.makeEphemeral()
  let store = makeReportingStore(userDefaults: defaults)  // flag unset
  #expect(store.isMigratingCrossChainIdentity)            // reads the flag

  await store.loadCapitalGains(financialYear: 2023)
  #expect(store.capitalGainsSummary == nil)               // NOT computed from mixed-id lots

  UnifiedInstrumentIdentityMigration.setCompleteForTesting(in: defaults)
  #expect(!store.isMigratingCrossChainIdentity)
}

@Test("post-migration a single FIFO queue consumes the OP-ETH lot before the mainnet-ETH lot")
func fifoMergesAfterCanonicalization() async throws {
  // Both buys now carry the canonical instrument (1:native) after the rewrite,
  // so CostBasisEngine keys them into ONE queue: 2021 OP lot consumed first.
  var engine = CostBasisEngine()
  let eth = Instrument.ethCanonical  // 1:native fixture
  engine.processBuy(instrument: eth, quantity: 1, costPerUnit: 100, date: date("2021-06-01"))
  engine.processBuy(instrument: eth, quantity: 1, costPerUnit: 200, date: date("2022-06-01"))
  let events = engine.processSell(instrument: eth, quantity: 1, proceedsPerUnit: 300, date: date("2023-06-01"))
  #expect(events.first?.acquiredDate == date("2021-06-01"))  // 2021 lot first
  #expect(events.first?.costBasis == 100)
}
```

- [ ] **Step 2: Run to verify they fail** — FAIL (`isMigratingCrossChainIdentity` undefined).

- [ ] **Step 3: Implement the gate**

In `ReportingStore.swift` add:
```swift
/// While the one-shot cross-chain identity migration is in flight, the
/// capital-gains FIFO is split across retired + canonical ids (CostBasisEngine
/// keys by instrument.id), so any figure would be wrong. Gate on the completion
/// flag and surface "updating…" instead.
var isMigratingCrossChainIdentity: Bool {
  !UnifiedInstrumentIdentityMigration.isComplete(in: userDefaults)
}
```
(Inject `userDefaults` into `ReportingStore` with a `.moolahShared` default, mirroring `AnalysisStore` at `Features/Analysis/AnalysisStore.swift:100`.) In `loadCapitalGains(financialYear:)`, early-return leaving `capitalGainsSummary`/`capitalGainsResult` nil while `isMigratingCrossChainIdentity`. In `InsightStore+Snapshot.makeSnapshot()` (`:14`), pass `capitalGains: []` when migrating so no capital-gains insight is built from mixed lots. In the capital-gains view surface, render `ContentUnavailableView`/`ProgressView("Updating cross-chain holdings…")` while `reportingStore.isMigratingCrossChainIdentity`. Add `setCompleteForTesting(in:)` (sets the flag) beside `resetGateFlag`.

- [ ] **Step 4: Run to verify they pass** — Expected: PASS.
- [ ] **Step 5: `just format-check` then commit** — `git commit -m "feat(migration): PR5 gate capital-gains surface while mid-migration"`

---

## Task 11: UI-test reset hook (fresh in-memory profiles must re-run)

**Files:**
- Modify: wherever `ValuationModeMigration.resetGateFlags(in:)` is invoked on `--ui-testing` launch (find via `grep -rn "resetGateFlags" App`), add `UnifiedInstrumentIdentityMigration.resetGateFlag(in:)` alongside.
- Test: append a one-liner assertion to `UnifiedInstrumentIdentityMigrationGateTests`.

- [ ] **Step 1: Failing test** — assert `resetGateFlag` clears a set flag.
- [ ] **Step 2–4:** implement `resetGateFlag` call in the `--ui-testing` reset path; run; PASS.
- [ ] **Step 5: `just format-check` then commit** — `git commit -m "chore(migration): PR5 reset identity-migration flag on --ui-testing launch"`

---

## Task 12: Mandatory AI review gate — drive to zero findings

**Files:** none (review + fixes only).

- [ ] **Step 1:** Run the required reviewers on the working tree, in parallel:
  - `@database-schema-review` (price-cache purge, the index decision, schema-lifecycle)
  - `@database-code-review` (raw-SQL safety, one-transaction-per-write, plan-pinning, rollback pairing per `DATABASE_CODE_GUIDE §5`)
  - `@code-review` (naming, thin views, extension organisation, struct shape vs `ValuationModeMigration`)
  - `@sync-review` (the `queueAllRecordsAfterImport` re-push step, `needs_push` interaction, backfill ordering per `SYNC_GUIDE`)
  - `@instrument-conversion-review` (capital-gains gate correctness; no `InstrumentAmount` mismatch; FIFO merge)
  - `@concurrency-review` (the `@MainActor` migration + GRDB `write` hops + `@Sendable` closures)
- [ ] **Step 2:** Fix EVERY finding immediately. Re-run the relevant reviewers. Repeat until zero findings across all six.
- [ ] **Step 3: `just format-check && just build-mac && just test`** — capture output; confirm green.
- [ ] **Step 4: Commit** any review fixes — `git commit -m "fix(migration): PR5 address review findings"`. Open the PR; land via the `landing-prs` skill per CLAUDE.md.

---

## Task 13: Validate via a DEVELOPMENT app launch

**This task is NOT a production run.** The migration reaches production only through the user's normal RC/release process (cut an RC → release → the released app runs the migration itself, unattended, on the prod profile). That release is **outside this PR's tasks**. This task is the single manual pre-release confirmation that the unattended code behaves.

- [ ] **Step 1:** Launch the app in **DEVELOPMENT** on a dev profile that has been seeded with retired per-chain crypto data (per-chain ETH legs, an OP↔Coinstash transfer pair, earmarks incl. legacy cols, account groups, investment values). Use the `run-mac-app-with-logs` skill so the migration's `os_log` output is captured.
- [ ] **Step 2:** From the logs + app state, confirm on the dev profile:
  - Every FK now points at the canonical id; retired rows are **aliased, not deleted** (PR6 defers deletion).
  - The OP↔Coinstash transfer reconciles (both legs share `1:native`); ETH shows once in the picker/registry.
  - Price caches for retired ids were purged and re-warm; `first_traded_on` preserved the earliest date.
  - The capital-gains surface showed "updating…" during the run and returns real figures once complete.
  - Sync re-pushed the rewritten rows (`queueAllRecordsAfterImport` log line / pending-uploads count).
  - A **second** dev launch is a clean no-op (flag short-circuit) — no further writes, no re-push.
- [ ] **Step 3:** Report the dev-validation result (log excerpts + the observed per-table rewrite counts) to the user. Shipping to production is the user's RC/release decision from here — do **not** attempt any production run from this PR.

---

## Self-Review (completed against `design.md` §4 + testing strategy)

- **Alias step (shared, idempotent):** Task 2. **Per-profile FK rewrite (6 + defensive account, needs_push, atomic):** Task 3. **Legacy columns rewritten:** Task 3 (`earmark.savings_target_instrument_id`, `earmark_budget_item.instrument_id`). **Re-push via `queueAllRecordsAfterImport`:** Tasks 8–9. **Price cache MIN + purge:** Task 7. **Completion flag last:** Task 8. **Capital-gains gate:** Task 10. ✅ every §4 sub-step has a task.
- **Testing strategy coverage:** both-DB seed + FK→canonical + needs_push + alias + OP→Coinstash reconcile (Task 8); idempotent re-run (Task 8); rollback byte-identical (Task 4); `account.instrument_id` retired-crypto rewrite (Task 3); `first_traded_on = MIN` (Task 7); re-push queues the rewritten leg (Task 8); plan-pinning ×7 + index verification (Task 6); capital-gains gate + FIFO merge (Task 10). ✅
- **Placeholder scan:** the only deliberately-deferred concretes are (a) the exact `toCryptoRegistration()` / `databaseQuestionMarks` / `SyncCoordinator` property spellings — flagged "confirm during implementation" because they are pre-existing symbols the implementer reads directly; (b) the exact capital-gains card view file — the data path is verified (Fact 11), the implementer confirms the leaf view. No behavioural TBDs.
- **Type consistency:** `deriveMapping`/`applyAliasStep`/`rewriteProfile`/`applyPriceCacheStep`/`run`/`isComplete`/`gateKey`/`isMigratingCrossChainIdentity` used identically across tasks. ✅

**TDD task count:** 11 implementation/test tasks (Tasks 1–11; Task 5 intentionally folded) + 1 review-gate task (12) + 1 dev-validation task (13). No production-run task exists: production is reached only by the user's unattended RC/release process, so the release-blocking safety net is the idempotency (Tasks 2, 8), per-profile atomicity (Task 4), and kill-mid-run resumability (Task 8) tests, not a human confirmation step.
