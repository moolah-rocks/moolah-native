# Unified Cross-Chain Instrument Identity — PR6: physical deletion + CloudKit tombstoning

> **Intended home:** `plans/2026-07-02-unified-instrument-identity-pr6-deletion-tombstoning.md`.
> **Execute via** `superpowers:subagent-driven-development` (like PR2–PR5).

**Goal:** The deferred final step. After PR5 aliased the retired per-chain crypto `instrument` rows (`alias_of IS NOT NULL`) and rewrote every FK reference to the canonical id, PR6 **physically deletes** those aliased rows from the shared registry and **tombstones** them in CloudKit (via a `DeletionJournal` write in the same transaction) so other devices delete rather than resurrect them. Unattended startup code, gated so it never runs before it's safe.

## Design decisions (locked with the user)
- **Convergence gate = RELEASE-TIMING (user decision 2026-07-02).** PR6 is unattended startup code with its OWN completion flag, additionally guarded by PR5's `didMigrateUnifiedInstrumentIdentity` flag being set on THIS device. The code cannot detect cross-device convergence; the user controls it by shipping the PR6 RC only after all devices ran PR5. **No time-delay heuristic, no manual UI trigger.**
- **Why the PR5-flag guard matters:** the retired `instrument` rows are real synced CloudKit records. Deleting+tombstoning one propagates the delete to every device. If a device hadn't finished PR5's FK rewrite, its legs could still reference the now-deleted retired id → dangling references. The per-device PR5-flag guard ensures THIS device rewrote its FKs; the release-timing gate ensures ALL devices did.
- **Mechanism (design §4):** mirror `GRDBInstrumentRegistryRepository.remove(id:)` — for each aliased row, `InstrumentRow.deleteOne` + `DeletionJournal.record(zoneName: DeletionJournal.profileIndexZoneName, recordName: InstrumentRow.recordName(for: id), recordType: InstrumentRow.recordType, at: Date(), in: db)` in the SAME `write`. `InstrumentRow.recordName(for: id)` returns the id itself; `recordType = "InstrumentRecord"`.
- **Shared-DB only.** PR6 touches only `profileIndexDatabase` (the `instrument` table). Per-profile FK rewrite already happened in PR5.
- **Propagation:** the existing start-time `replayDeletionJournal()` re-enqueues each journaled delete as a `.deleteRecord`. Since PR6 runs AFTER `replayDeletionJournal()` in the lifecycle, its new journal entries replay+push on the NEXT launch (design-sanctioned; the journal is durable). **OPEN for @sync-review:** whether to also propagate THIS launch (e.g. re-invoke `replayDeletionJournal()` after PR6, or enqueue the deletes directly). Default: next-launch replay.

## Verified codebase facts (worktree = origin/main + PR5)
1. `DeletionJournal.record(zoneName:recordName:recordType:at:in:)` — `Backends/GRDB/Records/DeletionJournalRow.swift:80`. `profileIndexZoneName = "profile-index"` (:57). PK `(zone_name, record_name)`, re-record is idempotent (`.replace`).
2. `remove(id:)` pattern to mirror — `Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository.swift:202-237` (delete + journal in one write).
3. `InstrumentRow.recordType = "InstrumentRecord"`, `recordName(for id) = id` — `Backends/GRDB/Records/InstrumentRow+Mapping.swift:48,53`.
4. `alias_of` is NOT in `InstrumentRow.CodingKeys` → query via raw SQL / `Column("alias_of")`. The `instrument_by_alias` partial index covers `WHERE alias_of IS NOT NULL` → the delete is index-backed (no SCAN; NO plan-pinning needed, unlike PR5).
5. PR5 migration struct to model the shape on — `App/UnifiedInstrumentIdentityMigration.swift` (`@MainActor struct`, `nonisolated static let gateKey`, `isComplete`/`resetGateFlag`, `run()`, private `Logger`).
6. Lifecycle call site — `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift:214-216`: `replayDeletionJournal()` (:214) → `runUnifiedIdentityMigration()` (:216, guarded by `Task.isCancelled`) → backfill (:236). PR6 goes immediately AFTER :216 (after PR5's migration, before backfill), with its own `Task.isCancelled` guard.
7. PR5 wiring — `SyncCoordinator+UnifiedIdentityMigration.swift` (`runUnifiedIdentityMigration()`, guards `sharedInstrumentRegistry`). Mirror for PR6.
8. UI-test reset — PR5's `resetGateFlag` is called in the `--ui-testing` reset path at `App/MoolahApp+Setup.swift` (next to `ValuationModeMigration.resetGateFlags`). Add PR6's reset alongside.
9. Test DB opener: `ProfileIndexDatabase.openInMemory()` (fully migrated in-memory `DatabaseQueue`).

## Global constraints
- Swift Testing (`@Suite`/`@Test`), not XCTest. One protocol conformance per extension file.
- Every multi-statement write in ONE `database.write { }` (one transaction, one rollback boundary) — DATABASE_CODE_GUIDE §5. All deletes + journal writes for the whole run in ONE `write`, so a mid-run throw rolls back to byte-identical (no half-deleted state).
- Raw SQL for the `alias_of IS NOT NULL` read (column absent from CodingKeys); SQL-injection safe (no interpolated values — the predicate is a literal).
- Idempotent: re-run finds no `alias_of IS NOT NULL` rows → deletes nothing; flag short-circuits anyway.
- `Date()` for the journal `queuedAt` is correct (a local clock value, never crosses the wire — matches `remove(id:)`).
- NO new `DatabaseMigrator` step. NO new CloudKit schema. `deletion_journal` table already exists.
- Test wait timeouts default to 10s.

## File structure
**New production:**
- `App/UnifiedInstrumentIdentityAliasCleanup.swift` — the `@MainActor struct`: injected `profileIndexDatabase` + `userDefaults`, own `gateKey`/`isComplete`/`resetGateFlag`, `run()`, test fault seam.
- `Backends/CloudKit/Sync/SyncCoordinator+UnifiedIdentityAliasCleanup.swift` — `runUnifiedIdentityAliasCleanup()` construction + invocation + test hook (mirrors PR5's wiring file; keeps `+Lifecycle.swift` under 400 lines).

**Modified production:**
- `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift` — call `await runUnifiedIdentityAliasCleanup()` immediately after `runUnifiedIdentityMigration()` (:216), with a `Task.isCancelled` guard. (Watch the 400-line cap — the call is one line + guard; the method body lives in the new file.)
- `App/MoolahApp+Setup.swift` — reset PR6's flag alongside PR5's in the `--ui-testing` branch.

**New tests (Swift Testing, one suite each):**
- `MoolahTests/App/UnifiedIdentityAliasCleanupTests.swift` — deletes aliased rows + writes journal entries (correct zone/recordName/type); leaves `alias_of IS NULL` rows; idempotent; gated OFF when PR5 flag unset; own-flag short-circuit; empty-aliased case still sets the flag.
- `MoolahTests/App/UnifiedIdentityAliasCleanupRollbackTests.swift` — fault seam mid-run → whole write rolls back byte-identical (no rows deleted, no journal entries).
- Wiring assertion appended to a SyncCoordinator gate-test suite (mirror PR5's `coordinatorRunsMigration`).

---

## Task 1: The cleanup struct + gated `run()` (delete aliased rows + journal, one txn, flag last)
**Files:** Create `App/UnifiedInstrumentIdentityAliasCleanup.swift`; Test `MoolahTests/App/UnifiedIdentityAliasCleanupTests.swift`.

**Interface:**
```swift
@MainActor
struct UnifiedInstrumentIdentityAliasCleanup {
  let profileIndexDatabase: DatabaseQueue
  let userDefaults: UserDefaults
  var faultAfterFirstDeleteForTesting: (@Sendable (Database) throws -> Void)?  // nil in prod

  nonisolated static let gateKey = "didDeleteUnifiedInstrumentIdentityAliases"
  static func isComplete(in defaults: UserDefaults = .moolahShared) -> Bool
  static func resetGateFlag(in defaults: UserDefaults)   // --ui-testing only
  func run() async throws
}
```
`run()`:
1. `guard !Self.isComplete(in: userDefaults) else { return }` (own-flag short-circuit).
2. `guard UnifiedInstrumentIdentityMigration.isComplete(in: userDefaults) else { return }` — **do NOT set the flag** in this case (PR5 hasn't run on this device yet; re-check next launch).
3. `guard !Task.isCancelled else { return }`.
4. ONE `try await profileIndexDatabase.write { db in ... }`: `SELECT id FROM instrument WHERE alias_of IS NOT NULL`; for each id, `InstrumentRow.deleteOne(db, key: id)` and, if it deleted, `DeletionJournal.record(...)` (profileIndexZoneName / `InstrumentRow.recordName(for: id)` / `InstrumentRow.recordType` / `Date()`); call `try faultAfterFirstDeleteForTesting?(db)` once after the first delete (guarded, nil in prod).
5. `guard !Task.isCancelled else { return }`; then `userDefaults.set(true, forKey: Self.gateKey)` (flag LAST). The empty-aliased case (nothing to delete) still reaches here → flag set (a converged/no-crypto device cleans up in one no-op pass).
Log a completion line (count deleted) via a private `Logger` (subsystem `com.moolah.app`, category `UnifiedInstrumentIdentityAliasCleanup`), `privacy: .public` on the count only.

**Tests (TDD, RED first):** seed the shared registry with (a) two aliased rows (`alias_of = "1:native"`, e.g. `10:native`, `8453:native`) and (b) one canonical row (`1:native`, `alias_of NULL`), with PR5's flag SET in an isolated `UserDefaults` suite. Assert after `run()`: the two aliased rows are GONE, `1:native` remains, two `deletion_journal` rows exist with `zone_name = "profile-index"`, `record_name` = the retired ids, `record_type = "InstrumentRecord"`, and PR6's flag is set. Separate tests: idempotent re-run (no error, still gone, flag stays); PR5-flag-UNSET → run() is a no-op AND PR6 flag NOT set; own-flag-set → immediate no-op; empty-aliased (only canonical rows) → flag set, no journal rows.

## Task 2: Rollback atomicity (fault mid-run leaves the shared DB byte-identical)
**Files:** Test `MoolahTests/App/UnifiedIdentityAliasCleanupRollbackTests.swift`. (No prod change if Task 1 wraps everything in one `write` — this PROVES it.)
Seed ≥2 aliased rows + PR5 flag set; snapshot the `instrument` + `deletion_journal` tables; set `faultAfterFirstDeleteForTesting = { _ in throw ... }`; `await #expect(throws:) { try await cleanup.run() }`; assert the snapshot is unchanged (no row deleted, no journal entry) AND PR6's flag is NOT set.

## Task 3: Wire into the SyncCoordinator lifecycle (after PR5's migration, before backfill)
**Files:** Create `Backends/CloudKit/Sync/SyncCoordinator+UnifiedIdentityAliasCleanup.swift`; Modify `SyncCoordinator+Lifecycle.swift`; Test: append a wiring assertion.
Add `runUnifiedIdentityAliasCleanup()` (mirror `runUnifiedIdentityMigration()`): guard `sharedInstrumentRegistry` present (or just construct from `containerManager.profileIndexDatabase` + `userDefaults` — no registry needed, so gate on whatever the sibling gates on for consistency; simplest: no dep guard needed, but keep the preview/test skip consistent with PR5). Construct `UnifiedInstrumentIdentityAliasCleanup(profileIndexDatabase: containerManager.profileIndexDatabase, userDefaults: userDefaults)`; `do { try await cleanup.run() } catch { logger.error(...) }` (non-fatal). Call `await runUnifiedIdentityAliasCleanup()` in `runZoneSetup` immediately after `await runUnifiedIdentityMigration()` (:216) + a `guard !Task.isCancelled`. Add a `runUnifiedIdentityAliasCleanupForTesting()` hook. **Ordering rationale in the method doc:** after PR5's migration (so rows are aliased first) and after `replayDeletionJournal` (its own journal entries replay next launch); before the backfill scan. **@sync-review adjudicates same-launch propagation.** Wiring test: seed shared registry (aliased rows) + PR5 flag; `runUnifiedIdentityAliasCleanupForTesting()`; assert aliased rows deleted + journal rows written + PR6 flag set.

## Task 4: UI-test reset hook
**Files:** Modify `App/MoolahApp+Setup.swift`. Add `UnifiedInstrumentIdentityAliasCleanup.resetGateFlag(in: .moolahShared)` beside PR5's reset in the `--ui-testing` branch. Test: one-liner assertion that `resetGateFlag` clears a set flag (mirror PR5 Task 11; RED impossible since resetGateFlag is trivial — assert the clear behavior honestly).

## Task 5: Mandatory AI review gate — drive to ZERO findings
Run in parallel on the working tree, fix EVERY finding (Critical/Important/Minor — user's zero-findings policy):
- `@database-code-review` (raw-SQL safety, one-write transaction, delete+journal pairing per remove(id:), rollback proof).
- `@database-schema-review` (deletion mechanics, `instrument_by_alias` index usage, no new migrator/schema, `deletion_journal` write pattern).
- `@sync-review` (the DeletionJournal tombstone + replay propagation, ordering vs replayDeletionJournal + backfill, adjudicate same-launch vs next-launch propagation, no resurrection).
- `@concurrency-review` (`@MainActor` struct + GRDB `write` hop + the test `@Sendable` fault seam).
- `@code-review` (naming, struct shape vs PR5's migration, extension organisation, 400-line cap, thin views N/A).
Then a final **opus whole-branch review**. Fix to zero. `just build-mac` + `just test-mac` + `just format-check` all green.

## DO NOT MERGE (user directive 2026-07-02)
Open the PR with base=main, but DO NOT enable automerge / DO NOT land it. PR6 lands only after the user confirms cross-device convergence of PR5 (which ships in v1.1.0-rc.44). Leave the PR open for the user to land later. Do NOT run the `landing-prs` skill for this PR.

## Self-review
Deletion + journal in one txn (§4) ✓; gated by own flag + PR5 flag ✓; index-backed delete (no SCAN, no plan-pin) ✓; idempotent + rollback-atomic ✓; shared-DB only ✓; unattended, flag-last ✓; convergence via release-timing (user) ✓; no new migrator/schema ✓. Propagation (this-launch vs next-launch) flagged for @sync-review.
