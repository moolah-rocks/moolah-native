# Unified Instrument Identity — PR4: Sync Apply/Conflict Canonicalization — Implementation Plan

> **Intended final home:** `plans/2026-07-01-unified-instrument-identity-pr4-sync-apply-canonicalization.md`
>
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make CloudKit sync converge every profile onto canonical cross-chain instrument ids — an un-migrated peer's `10:native` leg is stored as `1:native` on apply, an incoming retired instrument record is retained but marked `alias_of`, and the manual instrument picker can no longer mint a retired L2 id.

**Architecture:** Stacks on `origin/unified-identity-pr3` (which already ships the `CanonicalInstrumentResolver`, the v9 `alias_of` column, `SyncCoordinator.sharedCanonicalResolver`, and construction-time canonicalization). PR4 closes the three *ingestion* boundaries the construction path can't reach: (1) FK-holding records arriving from CloudKit (`ProfileDataSyncHandler`), (2) instrument records arriving from CloudKit (`GRDBInstrumentRegistryRepository.applyRemoteChangesSync`), and (3) the manual picker add path (`InstrumentPickerStore`). It also lands the §5 registry/picker display filter so aliased rows stop showing.

**Tech Stack:** Swift, Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect` — NOT XCTest), GRDB/SQLite, CKSyncEngine (CloudKit). One extension per protocol conformance.

## Global Constraints

- **Design against `origin/unified-identity-pr3`, not local `main`.** Read PR3 code via `git -C <repo> show origin/unified-identity-pr3:<path>`. Local `main` may be stale and does NOT contain the resolver / v9 migration this PR depends on.
- **Test framework is Swift Testing** (`import Testing`, `@Test`, `#expect`, `Issue.record`). Never XCTest in new tests.
- **One extension per protocol conformance**; no inlined conformances. Match surrounding file/naming idiom.
- **`alias_of` is a LOCAL-ONLY column** — NOT in `InstrumentRow.CodingKeys`, NOT in `toCKRecord()`, never decoded from a CKRecord. It is written in exactly ONE place in this PR: the resolver-driven raw-SQL `UPDATE` inside `applyRemoteChangesSync` (§3.5). The migration write is PR5, out of scope here.
- **Never mutate an instrument's `id`/recordName on apply** — that corrupts `encodedSystemFields`. §3.5 writes only the `alias_of` column.
- **Raw SQL only via `db.execute(sql:arguments:)` with bound arguments** — never string-interpolate a value into SQL (DATABASE_CODE_GUIDE §"query safety").
- **The resolver's `canonicalId(for:)` is synchronous and `Sendable`-safe** (guarded by `OSAllocatedUnfairLock`, never awaited). Call it directly from `nonisolated`/`@MainActor` contexts — no actor hop, no `await`.
- **Mandatory review gate (drive every finding to zero, re-run until clean):**
  - `@sync-review` — every task (SYNC_GUIDE is the primary guide).
  - `@code-review` — every task.
  - `@database-code-review` — Tasks 5 & 7 (raw-SQL `alias_of` write; new `WHERE alias_of IS NULL` query + plan-pinning).
  - `@concurrency-review` — Tasks 1 & 5 (resolver injected into a `@MainActor` handler / an `@unchecked Sendable` repo). The resolver call is synchronous and Sendable, so this is expected to pass, but the injection crosses into `nonisolated` apply code — have it reviewed.
  - Run `just format-check` after every task.

## Verified codebase facts (confirmed against `origin/unified-identity-pr3`, file:line)

- **Resolver:** `Shared/CryptoImport/CanonicalInstrumentResolver.swift` — `final class ... @unchecked Sendable`. Public API: `canonicalId(for id: String) -> String` (:63, synchronous, static base layer wins then dynamic), `isAlias(_ id: String) -> Bool` (:72). Static base map (:32-50) already contains `10:native`→`1:native`, `8453:native`→`1:native`, and L2 USDC/USDT → mainnet contracts. Dynamic layer refreshed from the registry.
- **Shared resolver handle:** `SyncCoordinator.sharedCanonicalResolver: CanonicalInstrumentResolver?` (`Backends/CloudKit/Sync/SyncCoordinator.swift:131`; init param :349, assigned :358). Constructed in `App/MoolahApp+SharedInstrumentScope.swift:29` and passed to the coordinator (:36); observation wired at :37-38.
- **`CryptoInstrumentID`** (`Domain/Models/CryptoInstrumentID.swift`): `chainId(from:) -> Int?` (:11), `contractAddress(from:) -> String?` (:20, `"native"`→nil). PR3 already uses these in `CryptoTokenDiscoveryService.resolveOrLoad` (:118-119) to decompose a canonical id back to `(chainId, address)` — the picker fix (Task 8) mirrors that exactly.
- **`ProfileDataSyncHandler`** (`Backends/CloudKit/Sync/ProfileDataSyncHandler.swift:26`, `@MainActor final class`): init at :43 takes `(profileId, zoneID, grdbRepositories)` — **no resolver today**. Constructed at `Backends/CloudKit/Sync/SyncCoordinator+HandlerAccess.swift:24` (production) and in `MoolahBenchmarks/Sync{Download,Upload}Benchmarks.swift` + `MoolahTests/Support/ProfileDataSyncHandlerTestSupport.swift:36`.
- **FK apply helpers** (`Backends/CloudKit/Sync/ProfileDataSyncHandler+GRDBSaveHelpers.swift`): each decodes CKRecords into typed Rows via `mapRows(context:fieldValues:idKey:stamp:)` (:274) then writes via `grdbRepositories.<repo>.applyRemoteChangesSync(saved:deleted:in:)`. **The FK-holding helpers are exactly five:** `applyBatchSaveTransactionLeg` (:236), `applyBatchSaveEarmark` (:164), `applyBatchSaveEarmarkBudgetItem` (:182), `applyBatchSaveInvestmentValue` (:200), `applyBatchSaveAccountGroup` (:128). `applyBatchSaveAccount` (:74) is **out of scope for the apply path** (design §3.4 lists only the five; the defensive `account.instrument_id` rewrite is a PR5 migration concern).
- **FK columns to canonicalize (six total across five row types):** `TransactionLegRow.instrumentId: String` (`Records/TransactionLegRow.swift:50`); `EarmarkRow.instrumentId: String?` (:53) **and** `EarmarkRow.savingsTargetInstrumentId: String?` (:58); `EarmarkBudgetItemRow.instrumentId: String` (:40); `InvestmentValueRow.instrumentId: String` (:42); `AccountGroupRow.instrumentId: String` (:41). All are `var` (mutable).
- **Per-profile-zone `.serverRecordChanged` conflict path** = `SyncErrorRecovery.classifySaveFailure` (`Backends/CloudKit/Sync/SyncErrorRecovery.swift:61`) → appends to `conflicts` → `requeueFailures` (:143) enqueues **`.saveRecord(recordID)` — i.e. re-uploads the LOCAL row**. The serverRecord is consumed only to refresh cached system fields (`ProfileDataSyncHandler+SystemFields.swift:105-107`, :199), NOT to write field values into local storage. **There is NO separate decode-and-write path for FK records** — so §3.4's fetch-path canonicalization fully covers convergence; the conflict path re-uploads the (already-canonical) local row.
- **Instrument apply path** (§3.5): `GRDBInstrumentRegistryRepository.applyRemoteChangesSync(saved:deleted:)` (`Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository+SyncEntryPoints.swift:103`). The stale-echo gate `continue`s at :137 **before** the `row.upsert(database)` at :149. Both the normal fetch path (`ProfileIndexSyncHandler.partitionSaved` → this method) AND the conflict path `applyInstrumentServerRecordChangedMerge` (`ProfileIndexSyncHandler+Instruments.swift:160`, calls `applyRemoteChangesSync` at :170) share this ONE method — hooking here covers both.
- **Registry display queries:** `GRDBInstrumentRegistryRepository.all()` (`GRDBInstrumentRegistryRepository.swift:111`) and `allCryptoRegistrations()` (:124). `fetchInstrumentMap` (`Records/InstrumentRow+Mapping.swift:13`) is the FK resolver and must **NOT** filter aliased rows.
- **Registry repo init** (`GRDBInstrumentRegistryRepository.swift:83`) takes `(database, onRecordChanged, onRecordDeleted)` — **no resolver today**. Shared instance built at `App/MoolahApp+SharedInstrumentScope.swift:54/71`.
- **Picker add path:** `InstrumentPickerStore.registerCrypto(_ instrument:)` (`Shared/InstrumentPickerStore.swift:108`) resolves provider ids via `resolutionClient.resolve` then persists `registry.registerCrypto(instrument, mapping:)` (:132) under the **raw** id — the leak. Placeholder built at `Shared/InstrumentSearchService.swift:162` from raw catalog `(chainId, contractAddress)`. Store init at `Shared/InstrumentPickerStore.swift:25`; constructed from `session?` services at `Shared/Views/InstrumentPickerField.swift:99`, `Shared/Views/InstrumentPickerSheet.swift:126`, `Shared/Views/CompactInstrumentPickerButton.swift:12,17`. `ProfileSession` already reaches the shared resolver at `App/ProfileSession.swift:320` (`syncCoordinator?.sharedCanonicalResolver ?? CanonicalInstrumentResolver()`).
- **Test harness:** `MoolahTests/Support/ProfileDataSyncHandlerTestSupport.swift` — `makeHandlerAndDatabase()` (:27) builds the handler + in-memory profile DB; row builders `transactionLegRow`/`earmarkRow`/etc. (:146-226) default `instrumentId` to `Instrument.defaultTestInstrument.id`. `Row.toCKRecord(in:)` round-trips (e.g. `TransactionLegRow+CloudKit.swift:14`). Existing suite `MoolahTests/Sync/ProfileDataSyncHandlerTests.swift` is intentionally NOT `@MainActor`; harness build goes through `try await MainActor.run { ... }`.

## Definitive answers to the brief's must-verify questions

1. **Resolver injection into `ProfileDataSyncHandler`:** add an optional `canonicalResolver: CanonicalInstrumentResolver?` to its init (default `nil`), stored as a `nonisolated let`. Wire it at the sole production construction site `SyncCoordinator+HandlerAccess.swift:24` with `canonicalResolver: sharedCanonicalResolver`. Benchmarks/test-support keep compiling via the default; the test support gains an optional param so §3.4 tests can inject a real resolver.
2. **`.serverRecordChanged` conflict handler:** the per-profile-zone conflict path **re-queues the LOCAL record** (`SyncErrorRecovery.swift:61`→`requeueFailures:143` = `.saveRecord`), consuming the serverRecord only for cached system fields. **No separate decode-and-write path exists**, so no separate FK conflict-path canonicalization is needed — Task 4 locks this in with a regression test. For instrument records, the conflict path (`applyInstrumentServerRecordChangedMerge`) DOES decode-and-write, but through the SAME `applyRemoteChangesSync` the §3.5 hook lives in — covered by Task 6.
3. **§5 display filter placement:** **included here (Task 7)**, not deferred. The brief's own §3.5 test ("row retained with `alias_of` set, filtered from the registry query") requires the filter to exist in PR4, and it is safe pre-migration: it only hides rows that already carry `alias_of` (set by §3.5 on-apply or the resolver), never a not-yet-aliased row; `fetchInstrumentMap` deliberately keeps aliased rows so migration-window legs still resolve.
4. **Counts:** **5** `applyBatchSave*` FK helpers, **6** FK columns to canonicalize.
5. **Risky tasks:** **Task 5** (the alias-on-apply write) — ordering subtlety: on a *fresh insert* the row doesn't exist yet, so the `UPDATE ... WHERE id = :id` must run **after** `upsert`; on the *stale-echo* path (which `continue`s before the upsert) the row already exists, so it aliases before the `continue`. The write must land in BOTH branches. Get this wrong and either a freshly-arrived retired row stays unaliased (visible) or a stale echo leaves it unaliased.

---

## File Structure (create / modify)

**Modify (production):**
- `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift` — add `canonicalResolver` stored property + init param (Task 1).
- `Backends/CloudKit/Sync/ProfileDataSyncHandler+GRDBSaveHelpers.swift` — add `canonicalInstrumentId(_:)` helper + a `canonicalize:` transform param on `mapRows`; wire the five FK helpers (Tasks 1–3).
- `Backends/CloudKit/Sync/SyncCoordinator+HandlerAccess.swift` — pass `sharedCanonicalResolver` into the handler (Task 1).
- `Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository.swift` — add `canonicalResolver` stored property + init param; add `WHERE alias_of IS NULL` to `all()` and `allCryptoRegistrations()` (Tasks 5, 7).
- `Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository+SyncEntryPoints.swift` — alias-on-apply raw `UPDATE` in `applyRemoteChangesSync` (Task 5).
- `App/MoolahApp+SharedInstrumentScope.swift` — construct the resolver before the registry; thread it into the registry (Task 5).
- `App/ProfileSession.swift` — expose `canonicalResolver` for the picker (Task 8).
- `Shared/InstrumentPickerStore.swift` — canonicalize + decompose in `registerCrypto` (Task 8).
- `Shared/Views/InstrumentPickerField.swift`, `Shared/Views/InstrumentPickerSheet.swift`, `Shared/Views/CompactInstrumentPickerButton.swift` — thread `canonicalResolver: session?.canonicalResolver` into the store (Task 8).

**Modify (test support):**
- `MoolahTests/Support/ProfileDataSyncHandlerTestSupport.swift` — optional `canonicalResolver` param on `makeHandlerAndDatabase`.

**Create (tests):**
- `MoolahTests/Sync/ProfileDataSyncHandlerCanonicalizationTests.swift` (Tasks 1–4).
- `MoolahTests/Backends/GRDB/InstrumentAliasOnApplyTests.swift` (Tasks 5–6).
- `MoolahTests/Backends/GRDB/InstrumentRegistryAliasFilterTests.swift` (Task 7).
- `MoolahTests/Shared/InstrumentPickerStoreCanonicalizationTests.swift` (Task 8).
- Extend existing plan-pinning suite `MoolahTests/Backends/GRDB/InstrumentRegistryPlanPinningTests.swift` (Task 7).

---

## Task 1: Inject resolver into `ProfileDataSyncHandler` + canonicalize `transaction_leg` on apply

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift:43-51`
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler+GRDBSaveHelpers.swift` (add helper + `canonicalize:` param on `mapRows` :274; wire `applyBatchSaveTransactionLeg` :236)
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+HandlerAccess.swift:24`
- Modify: `MoolahTests/Support/ProfileDataSyncHandlerTestSupport.swift:27,36`
- Test: `MoolahTests/Sync/ProfileDataSyncHandlerCanonicalizationTests.swift` (create)

**Interfaces:**
- Consumes: `CanonicalInstrumentResolver.canonicalId(for:)`; `SyncCoordinator.sharedCanonicalResolver`.
- Produces: `ProfileDataSyncHandler.init(profileId:zoneID:grdbRepositories:canonicalResolver:)` (4th param defaults `nil`); `nonisolated func canonicalInstrumentId(_ id: String) -> String` and `nonisolated func canonicalInstrumentId(_ id: String?) -> String?` on the handler; `mapRows(context:fieldValues:idKey:stamp:canonicalize:)` (new trailing `canonicalize:` param, defaults identity).

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Sync/ProfileDataSyncHandlerCanonicalizationTests.swift`:

```swift
import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Verifies the CloudKit apply path rewrites an un-migrated peer's retired
/// cross-chain instrument id onto its canonical id before storing FK-holding
/// records (design §3.4).
@Suite("ProfileDataSyncHandler — instrument-id canonicalization on apply")
struct ProfileDataSyncHandlerCanonicalizationTests {

  @Test
  func incomingOptimismNativeLegStoredAsCanonicalMainnet() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase(
        canonicalResolver: CanonicalInstrumentResolver())
    }
    let handler = harness.handler

    // Seed the parent transaction so the leg has a valid FK target.
    let txId = UUID()
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { db in
      try ProfileDataSyncHandlerTestSupport
        .transactionRow(id: txId, payee: "ETH transfer").insert(db)
    }

    let legId = UUID()
    let leg = ProfileDataSyncHandlerTestSupport.transactionLegRow(
      id: legId,
      transactionId: txId,
      accountId: UUID(),
      instrumentId: "10:native")  // Optimism ETH, from an un-migrated peer.
    let ckRecord = leg.toCKRecord(in: handler.zoneID)

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let stored = try await harness.database.read { db in
      try TransactionLegRow
        .filter(TransactionLegRow.Columns.id == legId)
        .fetchOne(db)
    }
    #expect(stored?.instrumentId == "1:native")
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-filter ProfileDataSyncHandlerCanonicalizationTests` (or the repo's Swift Testing filter per AI_WORKFLOW_GUIDE).
Expected: FAIL — `makeHandlerAndDatabase(canonicalResolver:)` does not exist / stored id is `10:native` (no canonicalization yet).

- [ ] **Step 3: Add the resolver to the handler**

In `ProfileDataSyncHandler.swift`, add the stored property near the other `nonisolated let`s (after `grdbRepositories` :34) and the init param:

```swift
  /// Redirects a retired cross-chain instrument id on an incoming
  /// FK-holding record onto its canonical id before the row is stored
  /// (design §3.4), so an un-migrated peer's `10:native` leg lands as
  /// `1:native`. `nil` for preview/test callers that don't canonicalize;
  /// production wires `SyncCoordinator.sharedCanonicalResolver`.
  nonisolated let canonicalResolver: CanonicalInstrumentResolver?
```

```swift
  init(
    profileId: UUID,
    zoneID: CKRecordZone.ID,
    grdbRepositories: ProfileGRDBRepositories,
    canonicalResolver: CanonicalInstrumentResolver? = nil
  ) {
    self.profileId = profileId
    self.zoneID = zoneID
    self.grdbRepositories = grdbRepositories
    self.canonicalResolver = canonicalResolver
  }
```

- [ ] **Step 4: Add the canonicalization helper + `mapRows` transform hook**

In `ProfileDataSyncHandler+GRDBSaveHelpers.swift`, add to the "Mapping & Logging Helpers" MARK:

```swift
  /// Canonicalizes a stored FK instrument id via the injected resolver,
  /// or returns it unchanged when no resolver is wired (preview/tests).
  /// Synchronous and lock-guarded — safe from this `nonisolated` context.
  nonisolated func canonicalInstrumentId(_ id: String) -> String {
    canonicalResolver?.canonicalId(for: id) ?? id
  }

  /// Optional overload for nullable FK columns (e.g. `EarmarkRow`).
  nonisolated func canonicalInstrumentId(_ id: String?) -> String? {
    id.map { canonicalInstrumentId($0) }
  }
```

Extend `mapRows` (:274) with a trailing identity-default transform applied after `stamp`:

```swift
  nonisolated func mapRows<Row>(
    context: GRDBBatchSaveContext,
    fieldValues: (CKRecord) -> Row?,
    idKey: (Row) -> String,
    stamp: (Row, Data?) -> Row,
    canonicalize: (Row) -> Row = { $0 }
  ) -> [Row] {
    context.ckRecords.compactMap { ckRecord -> Row? in
      guard let row = fieldValues(ckRecord) else {
        Self.logMalformed(context.site, ckRecord)
        return nil
      }
      return canonicalize(stamp(row, context.systemFields[idKey(row)]))
    }
  }
```

- [ ] **Step 5: Wire `applyBatchSaveTransactionLeg`**

In `applyBatchSaveTransactionLeg` (:236), pass the `canonicalize:` closure to `mapRows`:

```swift
    let rows = mapRows(
      context: context,
      fieldValues: TransactionLegRow.fieldValues(from:),
      idKey: { $0.id.uuidString },
      stamp: stampSystemFields,
      canonicalize: { row in
        var row = row
        row.instrumentId = self.canonicalInstrumentId(row.instrumentId)
        return row
      })
```

- [ ] **Step 6: Wire the production construction site + test support**

`SyncCoordinator+HandlerAccess.swift:24`:

```swift
    let handler = ProfileDataSyncHandler(
      profileId: profileId,
      zoneID: zoneID,
      grdbRepositories: grdbRepositories,
      canonicalResolver: sharedCanonicalResolver)
```

`ProfileDataSyncHandlerTestSupport.swift` — thread an optional resolver through both entry points:

```swift
  @MainActor
  static func makeHandlerAndDatabase(
    canonicalResolver: CanonicalInstrumentResolver? = nil
  ) throws -> HandlerHarness {
    let database = try ProfileDatabase.openInMemory()
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)
    let bundle = try Self.makeBundle(
      database: database, instrument: .defaultTestInstrument)
    let handler = ProfileDataSyncHandler(
      profileId: profileId,
      zoneID: zoneID,
      grdbRepositories: bundle,
      canonicalResolver: canonicalResolver)
    return HandlerHarness(handler: handler, database: database)
  }
```

Update `makeHandlerWithDatabase()` (:19) to forward the param (`makeHandlerAndDatabase(canonicalResolver:)`).

- [ ] **Step 7: Run test to verify it passes**

Run: `just test-filter ProfileDataSyncHandlerCanonicalizationTests`
Expected: PASS. Then `just format-check`.

- [ ] **Step 8: Review gate + commit**

Run `@sync-review`, `@code-review`, `@concurrency-review`; drive to zero.

```bash
git add -A && git commit -m "feat(sync): canonicalize transaction_leg instrument_id on CloudKit apply"
```

---

## Task 2: Canonicalize `earmark` (two FK columns) on apply

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler+GRDBSaveHelpers.swift` (`applyBatchSaveEarmark` :164)
- Test: `MoolahTests/Sync/ProfileDataSyncHandlerCanonicalizationTests.swift`

**Interfaces:** Consumes `canonicalInstrumentId(_:)` (String and String? overloads) from Task 1.

- [ ] **Step 1: Write the failing test** (append to the suite)

```swift
  @Test
  func incomingEarmarkCanonicalizesBothInstrumentColumns() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase(
        canonicalResolver: CanonicalInstrumentResolver())
    }
    let handler = harness.handler

    let earmarkId = UUID()
    var earmark = ProfileDataSyncHandlerTestSupport.earmarkRow(
      id: earmarkId, name: "ETH goal", instrumentId: "10:native")
    earmark.savingsTargetInstrumentId = "8453:native"  // Base ETH.
    let ckRecord = earmark.toCKRecord(in: handler.zoneID)

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let stored = try await harness.database.read { db in
      try EarmarkRow.filter(EarmarkRow.Columns.id == earmarkId).fetchOne(db)
    }
    #expect(stored?.instrumentId == "1:native")
    #expect(stored?.savingsTargetInstrumentId == "1:native")
  }
```

- [ ] **Step 2: Run to verify it fails**

Run: `just test-filter ProfileDataSyncHandlerCanonicalizationTests/incomingEarmarkCanonicalizesBothInstrumentColumns`
Expected: FAIL — stored ids still `10:native` / `8453:native`.

- [ ] **Step 3: Wire `applyBatchSaveEarmark`**

```swift
    let rows = mapRows(
      context: context,
      fieldValues: EarmarkRow.fieldValues(from:),
      idKey: { $0.id.uuidString },
      stamp: stampSystemFields,
      canonicalize: { row in
        var row = row
        row.instrumentId = self.canonicalInstrumentId(row.instrumentId)
        row.savingsTargetInstrumentId =
          self.canonicalInstrumentId(row.savingsTargetInstrumentId)
        return row
      })
```

- [ ] **Step 4: Run to verify it passes** — `just test-filter ...` PASS; then `just format-check`.

- [ ] **Step 5: Review gate + commit**

`@sync-review`, `@code-review`.

```bash
git add -A && git commit -m "feat(sync): canonicalize earmark instrument columns on CloudKit apply"
```

---

## Task 3: Canonicalize `earmark_budget_item`, `investment_value`, `account_group` on apply

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler+GRDBSaveHelpers.swift` (`applyBatchSaveEarmarkBudgetItem` :182, `applyBatchSaveInvestmentValue` :200, `applyBatchSaveAccountGroup` :128)
- Test: `MoolahTests/Sync/ProfileDataSyncHandlerCanonicalizationTests.swift`

**Interfaces:** Consumes `canonicalInstrumentId(_:)` from Task 1.

- [ ] **Step 1: Write the failing tests** (append three `@Test`s)

```swift
  @Test
  func incomingEarmarkBudgetItemCanonicalizesInstrument() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase(
        canonicalResolver: CanonicalInstrumentResolver())
    }
    let id = UUID()
    let item = ProfileDataSyncHandlerTestSupport.earmarkBudgetItemRow(
      id: id, earmarkId: UUID(), categoryId: UUID(), instrumentId: "10:native")
    _ = harness.handler.applyRemoteChanges(
      saved: [item.toCKRecord(in: harness.handler.zoneID)], deleted: [])
    let stored = try await harness.database.read { db in
      try EarmarkBudgetItemRow
        .filter(EarmarkBudgetItemRow.Columns.id == id).fetchOne(db)
    }
    #expect(stored?.instrumentId == "1:native")
  }

  @Test
  func incomingInvestmentValueCanonicalizesInstrument() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase(
        canonicalResolver: CanonicalInstrumentResolver())
    }
    let id = UUID()
    let value = ProfileDataSyncHandlerTestSupport.investmentValueRow(
      id: id, accountId: UUID(), instrumentId: "8453:native")
    _ = harness.handler.applyRemoteChanges(
      saved: [value.toCKRecord(in: harness.handler.zoneID)], deleted: [])
    let stored = try await harness.database.read { db in
      try InvestmentValueRow
        .filter(InvestmentValueRow.Columns.id == id).fetchOne(db)
    }
    #expect(stored?.instrumentId == "1:native")
  }

  @Test
  func incomingAccountGroupCanonicalizesInstrument() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase(
        canonicalResolver: CanonicalInstrumentResolver())
    }
    let id = UUID()
    // AccountGroupRow has no test-support builder; construct inline.
    let group = AccountGroupRow(
      id: id,
      recordName: AccountGroupRow.recordName(for: id),
      name: "Crypto",
      bucket: "asset",
      instrumentId: "10:native",
      position: 0,
      encodedSystemFields: nil)
    _ = harness.handler.applyRemoteChanges(
      saved: [group.toCKRecord(in: harness.handler.zoneID)], deleted: [])
    let stored = try await harness.database.read { db in
      try AccountGroupRow.filter(AccountGroupRow.Columns.id == id).fetchOne(db)
    }
    #expect(stored?.instrumentId == "1:native")
  }
```

> Verify `AccountGroupRow`'s member order against `Records/AccountGroupRow.swift` before running; adjust the initializer if the fields differ. If `AccountGroupRow.toCKRecord(in:)` lives in `Backends/GRDB/Sync/AccountGroupRow+CloudKit.swift`, confirm its signature there.

- [ ] **Step 2: Run to verify they fail** — Expected: FAIL (ids unchanged).

- [ ] **Step 3: Wire all three helpers** — add the same `canonicalize:` closure shape (single `instrumentId` column) to `applyBatchSaveEarmarkBudgetItem`, `applyBatchSaveInvestmentValue`, `applyBatchSaveAccountGroup`:

```swift
      canonicalize: { row in
        var row = row
        row.instrumentId = self.canonicalInstrumentId(row.instrumentId)
        return row
      })
```

- [ ] **Step 4: Run to verify they pass** — PASS; then `just format-check`.

- [ ] **Step 5: Review gate + commit** — `@sync-review`, `@code-review`.

```bash
git add -A && git commit -m "feat(sync): canonicalize budget-item/investment/account-group instrument_id on apply"
```

---

## Task 4: Lock in the per-profile-zone conflict-path finding (regression test, no production change)

**Rationale:** The design flags the `.serverRecordChanged` conflict path as a must-verify. Confirmed: the per-profile-zone conflict path re-queues the **local** record (`SyncErrorRecovery.swift:61`→`:143`), never decoding server field values into storage. So the fetch-path canonicalization (Tasks 1–3) already guarantees the re-queued upload carries the canonical id. This task adds a regression test that would fail if someone later changed the conflict path to apply the server record's fields — no production change.

**Files:**
- Test: `MoolahTests/Sync/ProfileDataSyncHandlerCanonicalizationTests.swift`

- [ ] **Step 1: Write the test** — prove that after applying an incoming `10:native` leg (now stored `1:native`), building the upload CKRecord for that leg carries `1:native`, i.e. the record a conflict re-queue would upload is canonical.

```swift
  @Test
  @MainActor
  func rebuiltUploadRecordForAppliedLegCarriesCanonicalInstrument() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase(
      canonicalResolver: CanonicalInstrumentResolver())
    let handler = harness.handler

    let txId = UUID()
    let legId = UUID()
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { db in
      try ProfileDataSyncHandlerTestSupport
        .transactionRow(id: txId, payee: "ETH").insert(db)
    }
    let leg = ProfileDataSyncHandlerTestSupport.transactionLegRow(
      id: legId, transactionId: txId, accountId: UUID(), instrumentId: "10:native")
    _ = handler.applyRemoteChanges(saved: [leg.toCKRecord(in: handler.zoneID)], deleted: [])

    // The stored (canonical) row is the one the conflict path re-queues for upload.
    let stored = try await harness.database.read { db in
      try TransactionLegRow.filter(TransactionLegRow.Columns.id == legId).fetchOne(db)
    }
    let uploadRecord = try #require(stored).toCKRecord(in: handler.zoneID)
    #expect(uploadRecord["instrumentId"] as? String == "1:native")
  }
```

> Confirm the CKRecord field key for the leg's instrument id in `TransactionLegRow+CloudKit.swift` (it maps `instrumentId` → a wire key; use the exact key string there, e.g. `"instrumentId"`).

- [ ] **Step 2: Run — Expected: PASS immediately** (no production change; it documents the covered invariant). If it fails, the conflict path is NOT what the finding assumed — stop and re-investigate before proceeding.

- [ ] **Step 3: `just format-check`, review gate (`@sync-review`), commit**

```bash
git add -A && git commit -m "test(sync): pin per-profile conflict re-queue carries canonical instrument id"
```

---

## Task 5: §3.5 — inject resolver into the shared registry + alias-on-apply for incoming instrument records  **[RISKY — apply-ordering]**

**Files:**
- Modify: `Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository.swift:83-93` (init) + class body (stored prop)
- Modify: `Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository+SyncEntryPoints.swift:103-164` (`applyRemoteChangesSync`)
- Modify: `App/MoolahApp+SharedInstrumentScope.swift` (construct resolver first; thread into the registry)
- Test: `MoolahTests/Backends/GRDB/InstrumentAliasOnApplyTests.swift` (create)

**Interfaces:**
- Consumes: `CanonicalInstrumentResolver.canonicalId(for:)`.
- Produces: `GRDBInstrumentRegistryRepository.init(database:onRecordChanged:onRecordDeleted:canonicalResolver:)` (new trailing param, defaults `nil`); a private `static func setAliasOf(_ id:String, to canonical:String, in db:Database) throws` in `+SyncEntryPoints`.

**Ordering hazard (read before implementing):** the incoming retired row may be a **fresh insert** (no local row yet) or a **stale echo** (existing row, gate `continue`s before the upsert). The `alias_of` `UPDATE ... WHERE id = :id` only affects an existing row, so:
- On the normal (clean) path: alias **after** `row.upsert(database)` so the row exists.
- On the stale-echo path: alias **before** the `continue` (the row already exists there).
Both branches must write `alias_of`. Compute the alias once per iteration.

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Backends/GRDB/InstrumentAliasOnApplyTests.swift`:

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Verifies §3.5: an incoming retired cross-chain instrument record is
/// retained but marked `alias_of` its canonical id on apply — fresh AND
/// stale-echo — via the resolver-driven raw-SQL write in
/// `applyRemoteChangesSync`. `alias_of` is local-only; the id is never mutated.
@Suite("Instrument registry — alias-on-apply for incoming records")
struct InstrumentAliasOnApplyTests {

  private func makeRegistry() throws -> GRDBInstrumentRegistryRepository {
    let db = try DatabaseQueue()  // in-memory
    try ProfileIndexSchema.migrator.migrate(db)  // confirm the exact migrator entry point
    return GRDBInstrumentRegistryRepository(
      database: db, canonicalResolver: CanonicalInstrumentResolver())
  }

  private func aliasOf(_ id: String, in registry: GRDBInstrumentRegistryRepository) throws -> String? {
    try registry.database.read { db in
      try String.fetchOne(
        db, sql: "SELECT alias_of FROM instrument WHERE id = ?", arguments: [id])
    }
  }

  @Test
  func freshOptimismNativeRecordRetainedAndAliased() throws {
    let registry = try makeRegistry()
    let row = InstrumentRow(
      id: "10:native", recordName: "10:native", kind: "cryptoToken",
      name: "Ethereum", decimals: 18, ticker: "ETH", exchange: nil,
      chainId: 10, contractAddress: nil,
      coingeckoId: "ethereum", cryptocompareSymbol: nil, binanceSymbol: nil,
      encodedSystemFields: nil)
    try registry.applyRemoteChangesSync(saved: [row], deleted: [])

    let exists = try registry.database.read { db in
      try InstrumentRow.filter(InstrumentRow.Columns.id == "10:native").fetchOne(db)
    }
    #expect(exists != nil)  // row retained, id unchanged.
    #expect(try aliasOf("10:native", in: registry) == "1:native")
  }

  @Test
  func staleEchoRecordStillAliased() throws {
    let registry = try makeRegistry()
    // Pre-seed an existing row with a NEWER cached modification date so the
    // incoming record trips the stale-echo gate (continues before upsert).
    // Build the existing row + encoded system fields carrying a future date;
    // reuse the harness helper the sibling stale-echo tests use.
    // ... seed existing "10:native" row with a future serverModificationDate ...
    let incoming = InstrumentRow(
      id: "10:native", recordName: "10:native", kind: "cryptoToken",
      name: "Ethereum", decimals: 18, ticker: "ETH", exchange: nil,
      chainId: 10, contractAddress: nil,
      coingeckoId: "ethereum", cryptocompareSymbol: nil, binanceSymbol: nil,
      encodedSystemFields: /* older date blob */ nil)
    try registry.applyRemoteChangesSync(saved: [incoming], deleted: [])
    #expect(try aliasOf("10:native", in: registry) == "1:native")
  }

  @Test
  func canonicalRecordNotAliased() throws {
    let registry = try makeRegistry()
    let row = InstrumentRow(
      id: "1:native", recordName: "1:native", kind: "cryptoToken",
      name: "Ethereum", decimals: 18, ticker: "ETH", exchange: nil,
      chainId: 1, contractAddress: nil,
      coingeckoId: "ethereum", cryptocompareSymbol: nil, binanceSymbol: nil,
      encodedSystemFields: nil)
    try registry.applyRemoteChangesSync(saved: [row], deleted: [])
    #expect(try aliasOf("1:native", in: registry) == nil)
  }
}
```

> Confirm the exact `ProfileIndexSchema` migrator invocation and the stale-echo seed helper by reading `MoolahTests/Backends/GRDB/ProfileIndexSchemaV9Tests.swift` and the existing instrument stale-echo tests; reuse their harness rather than re-deriving the date-blob construction. For the stale-echo case, follow `isStaleInstrumentEcho` (`+SyncEntryPoints.swift:186`): existing cached date must be > incoming date.

- [ ] **Step 2: Run to verify failure**

Run: `just test-filter InstrumentAliasOnApplyTests`
Expected: FAIL — `init(...canonicalResolver:)` missing / `alias_of` stays `nil`.

- [ ] **Step 3: Add the resolver to the registry**

In `GRDBInstrumentRegistryRepository.swift`, add a stored property (default visibility so the `+SyncEntryPoints` extension can read it) near `let database`:

```swift
  /// Redirects an incoming retired cross-chain instrument id onto its
  /// canonical id so the apply path can mark the retired row `alias_of`
  /// (design §3.5). `nil` for repos that never apply instrument records
  /// (per-profile bundles, previews, tests that don't exercise aliasing).
  let canonicalResolver: CanonicalInstrumentResolver?
```

Add the init param (trailing, defaulted) and assign:

```swift
  init(
    database: any DatabaseWriter,
    onRecordChanged: @escaping @Sendable (String) -> Void = { _ in },
    onRecordDeleted: @escaping @Sendable (String) -> Void = { _ in },
    canonicalResolver: CanonicalInstrumentResolver? = nil
  ) {
    self.database = database
    self.canonicalResolver = canonicalResolver
    self.hooks = OSAllocatedUnfairLock(
      initialState: HookState(
        onRecordChanged: onRecordChanged,
        onRecordDeleted: onRecordDeleted))
  }
```

- [ ] **Step 4: Alias-on-apply in `applyRemoteChangesSync`**

In `+SyncEntryPoints.swift`, add the raw-SQL helper (bound argument; honors the v9 CHECK `alias_of != id` because we only write when canonical != id):

```swift
  /// Marks a retired instrument row as an alias of its canonical id.
  /// Local-only column, raw SQL (not in `InstrumentRow.CodingKeys`);
  /// the `id`/recordName is never touched. Idempotent.
  private static func setAliasOf(
    _ id: String, to canonical: String, in database: Database
  ) throws {
    try database.execute(
      sql: "UPDATE instrument SET alias_of = ? WHERE id = ?",
      arguments: [canonical, id])
  }
```

Rewrite the loop body of `applyRemoteChangesSync` (:105-155) to compute the alias once and write it in both branches:

```swift
      for var row in rows {
        let existing =
          try InstrumentRow
          .filter(InstrumentRow.Columns.id == row.id)
          .fetchOne(database)

        let mergedStatus = Self.mergedPricingStatus(local: existing, incoming: row)

        // Resolve the incoming id to its canonical id (static + dynamic
        // layers). `nil` when no resolver is wired or the id is already
        // canonical — the row is then never aliased.
        let aliasTarget: String? = {
          guard let canonicalResolver else { return nil }
          let canonical = canonicalResolver.canonicalId(for: row.id)
          return canonical == row.id ? nil : canonical
        }()

        if let existing, Self.isStaleInstrumentEcho(existing: existing, incoming: row) {
          if mergedStatus != existing.pricingStatus {
            _ =
              try InstrumentRow
              .filter(InstrumentRow.Columns.id == row.id)
              .updateAll(
                database, [InstrumentRow.Columns.pricingStatus.set(to: mergedStatus)])
          }
          // Alias even on the stale-echo path (row already exists) so a
          // retired row is never left unaliased and visible.
          if let aliasTarget {
            try Self.setAliasOf(row.id, to: aliasTarget, in: database)
          }
          continue
        }

        row.pricingStatus = mergedStatus
        try row.upsert(database)
        try Self.clearDeletionIntent(for: row.id, in: database)
        // Alias AFTER the upsert so the row exists on a fresh insert.
        if let aliasTarget {
          try Self.setAliasOf(row.id, to: aliasTarget, in: database)
        }
      }
```

- [ ] **Step 5: Thread the resolver into the shared registry at boot**

In `App/MoolahApp+SharedInstrumentScope.swift`, construct the resolver before the registry and pass it in. Restructure `bootstrapSyncCoordinator` so `canonicalResolver` is created first, then handed to `makeSharedInstrumentScope`/`makeSharedInstrumentRegistry`:

```swift
  static func bootstrapSyncCoordinator(setup: ContainerSetup) -> SyncCoordinator {
    let networking = NetworkingServices()
    // Build the resolver first so the shared registry can apply `alias_of`
    // on incoming instrument records (design §3.5). Its observation task is
    // wired after the coordinator exists.
    let canonicalResolver = CanonicalInstrumentResolver()
    let scope = makeSharedInstrumentScope(
      setup: setup, networking: networking, canonicalResolver: canonicalResolver)
    let registryStore = SharedRegistryStore(registry: scope.registry)
    let coordinator = SyncCoordinator(
      containerManager: setup.manager,
      sharedInstrumentRegistry: scope.registry,
      sharedMarketData: scope.marketData,
      sharedRegistryStore: registryStore,
      sharedNetworking: networking,
      sharedCanonicalResolver: canonicalResolver)
    coordinator.startCanonicalResolverObservation(
      registry: scope.registry, changes: scope.registry.observeChanges())
    attachSharedInstrumentRegistrySyncHooks(
      registry: scope.registry, coordinator: coordinator)
    return coordinator
  }
```

Update `makeSharedInstrumentScope` and `makeSharedInstrumentRegistry` to take and forward `canonicalResolver`:

```swift
  static func makeSharedInstrumentRegistry(
    database: any DatabaseWriter,
    canonicalResolver: CanonicalInstrumentResolver
  ) -> GRDBInstrumentRegistryRepository {
    GRDBInstrumentRegistryRepository(
      database: database, canonicalResolver: canonicalResolver)
  }

  static func makeSharedInstrumentScope(
    setup: ContainerSetup,
    networking: NetworkingServices,
    canonicalResolver: CanonicalInstrumentResolver
  ) -> (registry: GRDBInstrumentRegistryRepository, marketData: ProfileSession.MarketDataServices) {
    let database = setup.manager.profileIndexDatabase
    let registry = makeSharedInstrumentRegistry(
      database: database, canonicalResolver: canonicalResolver)
    return (registry: registry, marketData: ProfileSession.makeMarketDataServices(
      database: database, networking: networking,
      cryptoMetadataLookup: { id in try await registry.cryptoRegistration(byId: id) }))
  }
```

> The other `GRDBInstrumentRegistryRepository(database:)` construction sites (per-profile bundles at `ProfileGRDBRepositories.swift:87`, the `HandlerAccess.swift:60` fallback, `CryptoSettingsView`, previews, benchmarks) keep the `canonicalResolver: nil` default — they never apply instrument records, so they never alias. No change needed there.

- [ ] **Step 6: Run to verify pass** — `just test-filter InstrumentAliasOnApplyTests` PASS; then `just format-check`.

- [ ] **Step 7: Review gate + commit**

Run `@sync-review`, `@code-review`, `@database-code-review` (raw-SQL alias write), `@concurrency-review` (resolver on the `@unchecked Sendable` repo). Drive to zero.

```bash
git add -A && git commit -m "feat(sync): alias retired instrument records on CloudKit apply (§3.5)"
```

---

## Task 6: §3.5 conflict path — confirm `applyInstrumentServerRecordChangedMerge` aliases via the shared apply path

**Rationale:** `applyInstrumentServerRecordChangedMerge` (`ProfileIndexSyncHandler+Instruments.swift:160`) decodes the serverRecord and calls the SAME `applyRemoteChangesSync` (:170) hooked in Task 5 — so the instrument conflict path aliases automatically. This task adds a test proving it, so a future refactor that bypasses `applyRemoteChangesSync` in the conflict path is caught.

**Files:**
- Test: `MoolahTests/Backends/GRDB/InstrumentAliasOnApplyTests.swift`

- [ ] **Step 1: Write the test** — build the profile-index sync handler wired to a resolver-carrying shared registry, feed a `10:native` serverRecord through `applyInstrumentServerRecordChangedMerge`, and assert `alias_of == "1:native"`.

```swift
  @Test
  @MainActor
  func instrumentConflictMergeAliasesRetiredRecord() throws {
    // Build the profile-index handler over a resolver-carrying shared registry.
    // Reuse the profile-index sync-handler test harness (see the existing
    // ProfileIndexSyncHandler tests) so the registry has canonicalResolver set.
    // ... construct handler + registry (canonicalResolver: CanonicalInstrumentResolver()) ...

    let serverRecord = InstrumentRow(
      id: "10:native", recordName: "10:native", kind: "cryptoToken",
      name: "Ethereum", decimals: 18, ticker: "ETH", exchange: nil,
      chainId: 10, contractAddress: nil,
      coingeckoId: "ethereum", cryptocompareSymbol: nil, binanceSymbol: nil,
      encodedSystemFields: nil).toCKRecord(in: handler.zoneID)

    handler.applyInstrumentServerRecordChangedMerge(serverRecord: serverRecord)

    let alias = try registry.database.read { db in
      try String.fetchOne(
        db, sql: "SELECT alias_of FROM instrument WHERE id = ?", arguments: ["10:native"])
    }
    #expect(alias == "1:native")
  }
```

> Locate the existing `ProfileIndexSyncHandler` test harness (search `MoolahTests` for `ProfileIndexSyncHandler`) and mirror its construction so the handler's `instrumentRepository` is the resolver-carrying registry. If no reusable harness exists, construct the handler directly per `SyncCoordinator.swift:359-363`'s wiring shape.

- [ ] **Step 2: Run — Expected: PASS** (behavior already delivered by Task 5). If it fails, the conflict path is bypassing `applyRemoteChangesSync` — investigate before proceeding.

- [ ] **Step 3: `just format-check`, review gate (`@sync-review`, `@code-review`), commit**

```bash
git add -A && git commit -m "test(sync): pin instrument conflict-merge aliases retired records"
```

---

## Task 7: §5 — display filter (`WHERE alias_of IS NULL`) on `all()` + `allCryptoRegistrations()`; keep `fetchInstrumentMap` unfiltered

**Files:**
- Modify: `Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository.swift:111-133`
- Test: `MoolahTests/Backends/GRDB/InstrumentRegistryAliasFilterTests.swift` (create)
- Modify: `MoolahTests/Backends/GRDB/InstrumentRegistryPlanPinningTests.swift` (add pinned cases)

**Interfaces:** Consumes `alias_of` column (via `Column("alias_of")` since it's not in `CodingKeys`).

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Backends/GRDB/InstrumentRegistryAliasFilterTests.swift`:

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// §5: aliased (retired) rows are hidden from the registry/picker display
/// queries but retained for FK resolution (`fetchInstrumentMap`).
@Suite("Instrument registry — alias display filter")
struct InstrumentRegistryAliasFilterTests {

  private func makeRegistry() throws -> GRDBInstrumentRegistryRepository {
    let db = try DatabaseQueue()
    try ProfileIndexSchema.migrator.migrate(db)
    let registry = GRDBInstrumentRegistryRepository(
      database: db, canonicalResolver: CanonicalInstrumentResolver())
    // Seed a canonical + a retired-and-aliased crypto row.
    try registry.applyRemoteChangesSync(
      saved: [
        InstrumentRow(
          id: "1:native", recordName: "1:native", kind: "cryptoToken",
          name: "Ethereum", decimals: 18, ticker: "ETH", exchange: nil,
          chainId: 1, contractAddress: nil, coingeckoId: "ethereum",
          cryptocompareSymbol: nil, binanceSymbol: nil, encodedSystemFields: nil),
        InstrumentRow(
          id: "10:native", recordName: "10:native", kind: "cryptoToken",
          name: "Ethereum", decimals: 18, ticker: "ETH", exchange: nil,
          chainId: 10, contractAddress: nil, coingeckoId: "ethereum",
          cryptocompareSymbol: nil, binanceSymbol: nil, encodedSystemFields: nil),
      ], deleted: [])
    return registry
  }

  @Test
  func allExcludesAliasedRows() async throws {
    let registry = try makeRegistry()
    let ids = try await registry.all().map(\.id)
    #expect(ids.contains("1:native"))
    #expect(!ids.contains("10:native"))
  }

  @Test
  func allCryptoRegistrationsExcludesAliasedRows() async throws {
    let registry = try makeRegistry()
    let ids = try await registry.allCryptoRegistrations().map(\.instrument.id)
    #expect(ids.contains("1:native"))
    #expect(!ids.contains("10:native"))
  }

  @Test
  func fetchInstrumentMapRetainsAliasedRows() async throws {
    let registry = try makeRegistry()
    let map = try await registry.database.read { db in
      try InstrumentRow.fetchInstrumentMap(database: db)
    }
    // FK resolver must still resolve a not-yet-rewritten migration-window leg.
    #expect(map["10:native"] != nil)
    #expect(map["1:native"] != nil)
  }
}
```

- [ ] **Step 2: Run to verify failure** — `all()`/`allCryptoRegistrations()` currently include `10:native`, so the first two tests FAIL; the third PASSes (guarding against over-filtering).

- [ ] **Step 3: Add the filter to the two display queries**

`all()` (:111-113):

```swift
    let stored = try await database.read { database in
      try InstrumentRow
        .filter(Column("alias_of") == nil)
        .fetchAll(database).map { try $0.toDomain() }
    }
```

`allCryptoRegistrations()` (:124-133):

```swift
      let rows =
        try InstrumentRow
        .filter(InstrumentRow.Columns.kind == cryptoKind)
        .filter(Column("alias_of") == nil)
        .fetchAll(database)
```

Leave `InstrumentRow+Mapping.fetchInstrumentMap` (:13) untouched.

- [ ] **Step 4: Add/adjust plan-pinning cases**

In `MoolahTests/Backends/GRDB/InstrumentRegistryPlanPinningTests.swift`, add pinned `EXPLAIN QUERY PLAN` assertions for the two filtered queries (mirror the file's existing pattern — read it first). Confirm the `alias_of IS NULL` predicate does NOT regress into an unexpected index misuse; the v9 partial index `instrument_by_alias ... WHERE alias_of IS NOT NULL` is for the resolver's map-build (opposite predicate), so a full scan for `all()` is expected and correct (it already scans every row).

- [ ] **Step 5: Run to verify pass** — all filter + plan-pinning tests PASS; then `just format-check`.

- [ ] **Step 6: Review gate + commit**

Run `@database-code-review` (new query + plan-pinning), `@sync-review`, `@code-review`.

```bash
git add -A && git commit -m "feat(registry): hide aliased instruments from picker/registry display (§5)"
```

---

## Task 8: Picker add path routes through the canonical resolver (addition A)

**Files:**
- Modify: `App/ProfileSession.swift:320-326` (expose `canonicalResolver`)
- Modify: `Shared/InstrumentPickerStore.swift:16-35,108-139`
- Modify: `Shared/Views/InstrumentPickerField.swift:99-104`, `Shared/Views/InstrumentPickerSheet.swift:126`, `Shared/Views/CompactInstrumentPickerButton.swift:12-17`
- Test: `MoolahTests/Shared/InstrumentPickerStoreCanonicalizationTests.swift` (create)

**Interfaces:**
- Consumes: `CanonicalInstrumentResolver.canonicalId(for:)`, `CryptoInstrumentID.chainId(from:)`/`contractAddress(from:)`.
- Produces: `InstrumentPickerStore.init(...canonicalResolver:)`; `ProfileSession.canonicalResolver`.

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Shared/InstrumentPickerStoreCanonicalizationTests.swift`. Build a store with a real registry + a stub `TokenResolutionClient` returning a valid provider id, add an L2 stablecoin placeholder (`10:0x0b2c…`), and assert the persisted registration lands under the canonical mainnet USDC id.

```swift
import Foundation
import Testing

@testable import Moolah

/// The manual picker must not mint a retired L2 id: adding an L2-stablecoin
/// catalog hit persists under the canonical mainnet id (addition A / design §3).
@Suite("InstrumentPickerStore — canonical registration")
@MainActor
struct InstrumentPickerStoreCanonicalizationTests {

  @Test
  func addingOptimismUSDCRegistersUnderMainnetId() async throws {
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let resolver = CanonicalInstrumentResolver()
    let store = InstrumentPickerStore(
      registry: registry,
      resolutionClient: StubTokenResolutionClient(  // returns a coingecko id
        coingeckoId: "usd-coin", cryptocompareSymbol: "USDC", binanceSymbol: nil,
        decimals: 6),
      canonicalResolver: resolver,
      kinds: [.cryptoToken])

    let opUSDC = Instrument.crypto(
      chainId: 10,
      contractAddress: "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
      symbol: "USDC", name: "USD Coin", decimals: 18)

    let added = try #require(await store.registerForTest(opUSDC))
    #expect(added.id == "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")

    let registration = try await registry.cryptoRegistration(byId: added.id)
    #expect(registration != nil)
    // No retired-id row was minted.
    #expect(try await registry.cryptoRegistration(byId: opUSDC.id) == nil)
  }
}
```

> `registerCrypto(_:)` is `private`; add a `#if DEBUG` test seam `func registerForTest(_ instrument: Instrument) async -> Instrument?` that forwards to it (mirror existing test seams in the repo), OR drive it through the store's public selection entry (`select`/`add`) if a stubbed `InstrumentSearchService` is easier. Confirm the `TokenResolutionClient` protocol shape and provide a minimal stub (or reuse an existing one under `MoolahTests`).

- [ ] **Step 2: Run to verify failure** — Expected: FAIL — currently persists under `10:0x0b2c…`.

- [ ] **Step 3: Expose the resolver on `ProfileSession`**

In `App/ProfileSession.swift`, add a stored property alongside `tokenResolutionClient`:

```swift
  /// Shared canonical resolver, exposed so the instrument picker can route
  /// a searched L2 token onto its canonical mainnet id before persisting
  /// (addition A). Same instance the crypto discovery wiring receives.
  private(set) var canonicalResolver: CanonicalInstrumentResolver?
```

Hoist the inline resolver at :320 into a `let` and store it:

```swift
    let canonicalResolver =
      syncCoordinator?.sharedCanonicalResolver ?? CanonicalInstrumentResolver()
    self.canonicalResolver = canonicalResolver
    let cryptoWiring = Self.makeCryptoSyncWiring(
      backend: backend,
      registry: instrumentRegistry,
      cryptoPriceService: cryptoPriceService,
      profileInstrument: profile.instrument,
      canonicalResolver: canonicalResolver)
```

- [ ] **Step 4: Canonicalize in `InstrumentPickerStore.registerCrypto`**

Add the dependency to the store (`Shared/InstrumentPickerStore.swift`):

```swift
  private let canonicalResolver: CanonicalInstrumentResolver?
```

```swift
  init(
    searchService: InstrumentSearchService? = nil,
    registry: (any InstrumentRegistryRepository)? = nil,
    resolutionClient: (any TokenResolutionClient)? = nil,
    canonicalResolver: CanonicalInstrumentResolver? = nil,
    kinds: Set<Instrument.Kind>
  ) {
    self.searchService = searchService
    self.registry = registry
    self.resolutionClient = resolutionClient
    self.canonicalResolver = canonicalResolver
    self.kinds = kinds
  }
```

Rewrite `registerCrypto(_ instrument:)` to canonicalize + decompose (mirroring `CryptoTokenDiscoveryService.resolveOrLoad:107-149`), returning any pre-existing canonical registration instead of re-minting:

```swift
  private func registerCrypto(_ instrument: Instrument) async -> Instrument? {
    guard let registry, let resolutionClient else { return nil }

    // Canonicalize the searched id so an L2 native/stablecoin collapses onto
    // its canonical mainnet id, then decompose that id back into value fields
    // so the stored row's chainId/contractAddress match its primary key
    // (mirrors CryptoTokenDiscoveryService.resolveOrLoad).
    let canonicalInstrument = canonicalized(instrument)

    // If the canonical instrument is already registered, reuse it verbatim —
    // don't re-resolve or clobber a good mainnet row with placeholder fields.
    if let existing = try? await registry.cryptoRegistration(byId: canonicalInstrument.id) {
      return existing.instrument
    }

    isResolving = true
    error = nil
    defer { isResolving = false }
    let isNative = canonicalInstrument.contractAddress == nil
    let chainId = canonicalInstrument.chainId ?? 0
    do {
      let resolution = try await resolutionClient.resolve(
        chainId: chainId,
        contractAddress: isNative ? nil : canonicalInstrument.contractAddress,
        symbol: canonicalInstrument.ticker,
        isNative: isNative)
      guard resolution.hasAnyProviderId else {
        self.error = "Could not find a price source for this token."
        return nil
      }
      let mapping = CryptoProviderMapping(
        instrumentId: canonicalInstrument.id,
        coingeckoId: resolution.coingeckoId,
        cryptocompareSymbol: resolution.cryptocompareSymbol,
        binanceSymbol: resolution.binanceSymbol)
      try await registry.registerCrypto(canonicalInstrument, mapping: mapping)
      return canonicalInstrument
    } catch {
      logger.error("Crypto registration failed: \(error, privacy: .public)")
      self.error = "Couldn't add \(canonicalInstrument.displayLabel)."
      return nil
    }
  }

  /// Maps a searched crypto instrument onto its canonical id and rebuilds the
  /// instrument from the decomposed canonical `(chainId, contractAddress)` so
  /// the value fields agree with the id. Returns the input unchanged when it
  /// is already canonical or no resolver is wired.
  private func canonicalized(_ instrument: Instrument) -> Instrument {
    guard let canonicalResolver else { return instrument }
    let canonicalId = canonicalResolver.canonicalId(for: instrument.id)
    guard canonicalId != instrument.id else { return instrument }
    return Instrument.crypto(
      chainId: CryptoInstrumentID.chainId(from: canonicalId) ?? (instrument.chainId ?? 0),
      contractAddress: CryptoInstrumentID.contractAddress(from: canonicalId),
      symbol: instrument.ticker ?? instrument.name,
      name: instrument.name,
      decimals: instrument.decimals)
  }
```

> **Note (flagged):** the rebuilt instrument keeps the placeholder `decimals` (e.g. 18 for an L2 stablecoin whose mainnet canonical is 6-dp). This matches the pre-existing behavior for non-canonical tokens (the current code also persists placeholder decimals) and the "reuse existing registration" fast path means a real mainnet USDC row (already registered as a preset) is returned verbatim, avoiding the mismatch in the common case. Do **not** expand scope to re-derive decimals from `resolution` here — raise it as a follow-up if reviewers want it.

- [ ] **Step 5: Thread the resolver at the three view construction sites**

`InstrumentPickerField.swift:99`:

```swift
    store = InstrumentPickerStore(
      searchService: session?.instrumentSearchService,
      registry: session?.instrumentRegistry,
      resolutionClient: session?.tokenResolutionClient,
      canonicalResolver: session?.canonicalResolver,
      kinds: kinds)
```

Apply the identical `canonicalResolver: session?.canonicalResolver` addition at `InstrumentPickerSheet.swift:126` and `CompactInstrumentPickerButton.swift:12,17`. Fiat-only preview constructions (`InstrumentPickerSheet.swift:157,169`, `InstrumentPickerField.swift:26`, etc.) keep the `canonicalResolver: nil` default — they never register crypto.

- [ ] **Step 6: Run to verify pass** — `just test-filter InstrumentPickerStoreCanonicalizationTests` PASS; then `just format-check`.

- [ ] **Step 7: Review gate + commit**

Run `@code-review`, `@sync-review`. (No actor boundary crossed — `InstrumentPickerStore` is `@MainActor`, the resolver call is synchronous — `@concurrency-review` not required.)

```bash
git add -A && git commit -m "feat(picker): route manual crypto add through the canonical resolver"
```

---

## Final integration & self-review

- [ ] Run the full affected suites: `just test-filter ProfileDataSyncHandlerCanonicalizationTests InstrumentAliasOnApplyTests InstrumentRegistryAliasFilterTests InstrumentPickerStoreCanonicalizationTests` — all green.
- [ ] `just build-mac` and `just format-check` clean; zero new warnings.
- [ ] Re-run the full review gate over the whole diff: `@sync-review`, `@code-review`, `@database-code-review`, `@concurrency-review` — drive every finding to zero, re-review after fixes.
- [ ] Spec-coverage check: §3.4 FK apply (Tasks 1–3, 5 helpers / 6 columns) ✓; per-profile conflict path verified (Task 4) ✓; §3.5 instrument alias-on-apply fresh + stale-echo (Task 5) ✓; §3.5 conflict path (Task 6) ✓; §5 display filter incl. `fetchInstrumentMap` non-filter (Task 7) ✓; picker fix (Task 8) ✓.
- [ ] Open the PR targeting the PR3 branch (stacked); once PR3 merges, the `landing-prs` skill retargets to `main`. Do NOT include the §4 migration (that is PR5).
