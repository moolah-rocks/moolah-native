# GRDB Migration: Replacing SwiftData for Local Storage

**Status:** Step 1, Step 2, Slice 0, Slice 1, Slice 4 shipped (on `main`). Slice 3 (Stragglers + SwiftData teardown) is the only remaining slice — see roadmap §6.
**Decision date:** 2026-04-28
**Sync mechanism:** CKSyncEngine (unchanged). GRDB replaces SwiftData as the local persistence layer; sync remains storage-agnostic.

---

## 1. Why

SwiftData (and Core Data underneath) lacks aggregate functions — no `SUM`, `GROUP BY`, window functions, or correlated subqueries on the storage path. Today, every analysis query loads all relevant rows into memory and aggregates in Swift:

- `CloudKitAnalysisRepository+IncomeExpense.swift` walks every leg and accumulates into nested dictionaries.
- `+DailyBalances.swift` runs a Swift loop to compute running balances.
- Sidebar totals fan out per account.

Moving to GRDB on SQLite enables SQL aggregates, joins on indexed columns, partial / covering indexes, recursive CTEs, and `EXPLAIN QUERY PLAN` as a verification tool. The expected wins are most pronounced on Analysis hot paths but spread across every screen that reads aggregated data.

CKSyncEngine is already storage-agnostic by design — switching the local store does not touch the sync layer.

## 2. What stays the same

- **CKSyncEngine** for sync. The `Backends/CloudKit/Sync/` boundary is preserved.
- **Repository protocols** in `Domain/Repositories/`. Backends swap; protocols don't.
- **`encoded_system_fields`** semantics — bit-for-bit copies of CloudKit-issued bytes, never decoded outside the sync boundary.
- **`InstrumentAmount`** as the source of truth for monetary values (integer cents).
- **Conversion service shape**: `ExchangeRateService` / `StockPriceService` / `CryptoPriceService` / `FullConversionService` / `FiatConversionService` continue to perform conversion lookups in Swift. Multi-step conversion paths (e.g. GBP stock → GBP fiat → USD → AUD) stay in Swift; SQL conversion is deferred indefinitely.
- **Profile boundary**: one DB file per profile.

## 3. What changes

- **Local storage**: SwiftData (`@Model` classes under `Backends/CloudKit/Models/`) → GRDB-backed records under `Backends/GRDB/Records/` with `Sendable` struct types.
- **Records**: `@Model` classes → `Sendable` structs conforming to `FetchableRecord, PersistableRecord`.
- **Schema**: `@Model` macros → one `*Schema.swift` per database with a `DatabaseMigrator`.
- **Repository implementations**: `Backends/CloudKit/Repositories/CloudKit*Repository.swift` → `Backends/GRDB/Repositories/GRDB*Repository.swift`.
- **Rate caches**: per-base / per-ticker / per-token gzipped JSON files → SQLite tables in the per-profile DB.
- **Conversion service ownership**: app-scoped → per-profile, constructed in `ProfileSession+Factories.swift`.
- **DB file location**: `Application Support/moolah/profiles/<profile-id>/data.sqlite`.

## 4. Decisions made

These decisions are settled. New code follows them; future review revisits them only with explicit user authorisation.

### Architecture

- **GRDB as a SwiftPM dependency**, not vendored. Rationale: GRDB is infrastructure (storage layer), not feature code; vendoring 50k LOC of someone else's code into the repo costs more than the network dependency on `swift-package-resolved`.
- **`DatabaseQueue`, not `DatabasePool`.** Reads serialise; the read profile is sub-millisecond; pool parallelism is unused. `DatabaseQueue()` (no path) gives in-memory test parity. WAL is still on (WAL ≠ Pool).
- **One DB per data domain. Never split a single profile across files.** A new SQLite file is justified only when the data has materially different access patterns / durability / lifetime to existing per-profile data.
- **`encoded_system_fields BLOB` column on every synced record table.** UNIQUE on the record-name column is mandatory.
- **`ValueObservation` not adopted.** Stores reload on explicit triggers (init, store actions, post-CKSyncEngine notifications). Re-evaluate after Slice 1 ships.

### Schema

- Every table is `STRICT`.
- `WITHOUT ROWID` is per-table, not blanket. See `guides/DATABASE_SCHEMA_GUIDE.md` §3.
- Money: `INTEGER NOT NULL` cents. Never `REAL`.
- Rates: `REAL NOT NULL` (double-precision is sufficient at moolah scale; aggregations are bounded; conversion arithmetic happens in Swift after lookup).
- Dates: ISO-8601 TEXT (GRDB Codable default). Existing `SQLiteCoinGeckoCatalog`'s Unix-epoch REAL stays — it's a separate DB.
- UUIDs: 16-byte BLOB (GRDB default).

### Rate storage shape

- **Mirrors the existing in-memory `*Cache` structs.** No anchor-instrument trick for FX / stocks. Crypto is always priced in USD.
- Tables: `exchange_rate(base, quote, date)`, `stock_price(ticker, date)` + `stock_ticker_meta(ticker, instrument_id, …)`, `crypto_price(token_id, date)` + `crypto_token_meta(token_id, symbol, …)`, plus per-base / per-ticker / per-token meta rows for `earliest_date` / `latest_date`.
- **Rate data does not sync via CloudKit.** Per-device cache.
- **Rate retention is forever.** Historical conversions of old transactions must remain reproducible.
- No manual rate overrides at this stage.

### Migration handling

- **The migration is local-to-local on the same device.** No network, no CloudKit interaction.
- Legacy JSON caches (`Caches/exchange-rates/`, `Caches/stock-prices/`, `Caches/crypto-prices/`) are deleted on first launch and re-warmed from the network. No JSON-to-SQLite copying.
- A SwiftData → GRDB migrator runs once at app launch after a future GRDB-deployed release, gated by a `UserDefaults` flag. (Designed in detail per slice.)

## 5. Slicing strategy

A slice only delivers the SQL win when every table its hot queries touch lives in GRDB. So slices follow the join graph, not the repository protocols.

```
                 ┌─ Instrument ────────┐
TransactionLeg ──┼─ Account ───────────┤
                 ├─ Category           │
                 ├─ Earmark            │
Transaction ─────┘                     │
InvestmentValue ── Account ────────────┤
Rate (FX / stock / crypto, local-only)─┘
```

The dense centre — `transaction × leg × account × category × earmark × instrument × investment_value × rate` — is the slice that unlocks `AnalysisRepository`. It cannot be split smaller without leaving joins blocked.

**Order of work (matches the Roadmap below):**

1. **Step 1 — Add GRDB via SwiftPM.** Pure dependency addition. No runtime change. ✅ Shipped.
2. **Step 2 — Migrate rate storage.** Sets up GRDB infrastructure (DatabaseQueue lifecycle, schema migrator) without exercising CKSyncEngine glue. ✅ Shipped.
3. **Slice 0 — `CSVImportProfile` + `ImportRule`.** Exercises CKSyncEngine ↔ GRDB on isolated leaf records. Proves the migration mechanics, the `encoded_system_fields` handling, and the schema-generator integration. ✅ Shipped via PR [#567](https://github.com/ajsutton/moolah-native/pull/567).
4. **Slice 1 — Core financial graph.** Single coordinated cut that migrates `Transaction`, `TransactionLeg`, `Account`, `Category`, `Earmark`, `EarmarkBudgetItem`, `Instrument`, `InvestmentValue`. Largest PR; mechanical migrator code; well-bounded. ✅ Shipped via PR [#573](https://github.com/ajsutton/moolah-native/pull/573). **NB:** the SQL `GROUP BY` rewrite of `AnalysisRepository` was deliberately deferred — see Slice 4 below.
5. **Slice 3 — Stragglers + SwiftData teardown.** Migrate the last synced record type (`ProfileRecord`, the profile-index entry) to GRDB; then delete every `@Model` class, the `SwiftDataToGRDBMigrator`, and every `import SwiftData` from production. Detailed plan: `plans/grdb-slice-3-stragglers.md`.
6. **Slice 4 — `AnalysisRepository` SQL aggregation.** ✅ Shipped via PR [#594](https://github.com/ajsutton/moolah-native/pull/594). Pushed the per-instrument `GROUP BY` aggregation into SQL for the four hot analysis methods, cashing in the speedup the Slice 1 covering indexes were sized for. As a side effect, the `Backends/CloudKit/Repositories/CloudKitAnalysis*` files were deleted in the same PR (rather than in Slice 3 Phase B as originally planned).

## 6. Roadmap

> **Granularity.** This roadmap captures per-step / per-slice ordering and scope only. Each step or slice gets its own detailed plan in `plans/grdb-step-*.md` or `plans/grdb-slice-*.md` before execution; the bullets below are not enough on their own to pick up cold and execute. Currently fleshed out: `plans/grdb-step-2-rate-storage.md`.

### Step 1 — Add GRDB via SwiftPM

**Branch:** `build/add-grdb-spm`. **Size:** small.

- Add `groue/GRDB.swift` to `project.yml`'s SwiftPM dependencies, pinned to a tagged release (latest stable).
- Add `Package.resolved` to source control.
- Enable `InferSendableFromCaptures` upcoming feature on the relevant target(s) so `writer.read(Type.fetchAll)` shorthand compiles without `@Sendable` ceremony.
- Run `just generate`.
- Verify the project builds (no new code uses GRDB yet).
- License attribution noted in any place existing third-party attributions live.

**Acceptance:** `just build-mac` and `just build-ios` succeed; `import GRDB` resolves; no runtime behaviour change.

### Step 2 — Migrate rate storage to GRDB

**Branch:** `refactor/rate-storage-grdb`. **Size:** medium.

- Per-profile `data.sqlite` lifecycle owned by `ProfileSession`. New `Backends/GRDB/ProfileDatabase.swift` (or similar) constructs the `DatabaseQueue` with the project's PRAGMA defaults from `guides/DATABASE_SCHEMA_GUIDE.md` §5.
- New schema file `Backends/GRDB/ProfileSchema.swift` with a `DatabaseMigrator`. Initial migration creates rate tables only (slice 0 / 1 add user-data tables in later migrations).
- Tables per the rate schema decisions (§4 above).
- `ExchangeRateService` / `StockPriceService` / `CryptoPriceService` rewrite their persistence layer:
  - Constructor change from `cacheDirectory: URL?` to `database: any DatabaseWriter`.
  - Save: `INSERT OR REPLACE` into the price/rate table inside one transaction, plus upsert into the meta table.
  - Load: `SELECT … WHERE base/ticker/token_id = ? ORDER BY date` plus the meta row.
  - Public protocols (`ExchangeRateClient` etc.) and async API surface unchanged.
- Conversion services (`FullConversionService`, `FiatConversionService`) move to per-profile construction in `ProfileSession+Factories.swift`. App-scoped construction sites are removed.
- One-shot cleanup on first launch: delete legacy `Caches/exchange-rates/`, `Caches/stock-prices/`, `Caches/crypto-prices/` directories; gate via a `UserDefaults` flag (`v2.rates.cache.cleared`).
- Tests:
  - Unit tests against in-memory `DatabaseQueue()` for save/load round-trip per service.
  - Rollback test for the multi-statement save path.
  - Service-level tests against `TestBackend` to verify the conversion path still works end-to-end.
- Reviewers: `database-schema-review` for the schema; `database-code-review` for the Swift; `concurrency-review` for the per-profile lifecycle change.

**Acceptance:** Rate caches persist to SQLite; legacy JSON directories are cleared on first launch; conversion-using tests still pass; no behaviour change visible to the rest of the app.

### Slice 0 — `CSVImportProfile` + `ImportRule`

**Branch:** `feat/grdb-slice-0-csv-import`. **Size:** medium.

- Add migrations for `csv_import_profile` and `import_rule` tables to `ProfileSchema`. Both synced via CKSyncEngine.
- `CSVImportProfileRecord`, `ImportRuleRecord` under `Backends/GRDB/Records/` with mapping extensions.
- `GRDBCSVImportProfileRepository`, `GRDBImportRuleRepository` under `Backends/GRDB/Repositories/`. They implement the existing `Domain/Repositories/CSVImportProfileRepository` and `ImportRuleRepository` protocols.
- CKSyncEngine glue: extend `Backends/CloudKit/Sync/` to wire these record types to the GRDB tables (apply-remote-changes batches, queue-and-delete paths, system-fields writeback).
- `BackendProvider` swaps the SwiftData implementations for the GRDB ones for these two types only.
- One-shot SwiftData → GRDB migrator runs at app launch after upgrade, copies these record types' rows + their `encodedSystemFields` bit-for-bit, sets a flag.
- Tests: contract tests for both repositories against in-memory `DatabaseQueue`; sync round-trip test through the existing `TestBackend` shape; migrator test that seeds SwiftData, runs migrator, asserts GRDB state.
- Reviewers: all three database / sync / concurrency reviewers, plus `code-review`.

**Acceptance:** CSV import + import rules continue to work end-to-end; their data syncs via CloudKit; migrator preserves all existing user data including system-fields.

### Slice 1 — Core financial graph

**Branch:** `feat/grdb-slice-1-core`. **Size:** large.

Migrate in one coordinated PR:

- `Account`, `Transaction`, `TransactionLeg`, `Category`, `Earmark`, `EarmarkBudgetItem`, `Instrument`, `InvestmentValue`.
- Schemas with appropriate indexes (covering indexes for the analysis hot paths; FK child indexes everywhere).
- All 8 repositories (`AccountRepository`, `TransactionRepository`, `CategoryRepository`, `EarmarkRepository`, `InvestmentRepository`, `AnalysisRepository`, `InstrumentRegistryRepository`, plus any I missed in the audit).
- **`AnalysisRepository` is rewritten to use SQL aggregates** rather than Swift loops. This is where the perf win lands. Plan-pinning unit tests are mandatory for every aggregate query.
- Migrator extends to copy these record types from SwiftData, including all FK references and `encodedSystemFields`.
- Reviewers: all four (database / sync / concurrency / code), plus `instrument-conversion-review` for any analysis change touching conversion.

**Acceptance:** Full app functionality preserved; all existing tests pass; analysis-heavy screens noticeably faster (benchmark required); CKSyncEngine round-trip continues to work.

### Slice 3 — Stragglers + SwiftData teardown

**Branches:** `feat/grdb-slice-3-profile-index` (Phase A), `chore/grdb-slice-3-swiftdata-teardown` (Phase B). **Detailed plan:** `plans/grdb-slice-3-stragglers.md`.

After Slice 1, the only remaining synced `@Model` class is `ProfileRecord` (the profile-index entry, one per CloudKit profile, lives in the shared `profile-index` zone — separate lifecycle from the per-profile `data.sqlite`). Slice 3 migrates it, then deletes the SwiftData layer wholesale.

**Phase A — ProfileRecord migration to GRDB.**

- New app-scoped `Application Support/Moolah/profile-index.sqlite` (separate from per-profile `data.sqlite` per §4: ProfileRecord is shared across profiles, must be readable before any profile is selected). Owned by `ProfileContainerManager`. Schema: single `profile` table, STRICT, `record_name TEXT NOT NULL UNIQUE`, `encoded_system_fields BLOB`.
- `ProfileRow` + mapping + `CloudKitRecordConvertible`. Wire `recordType = "ProfileRecord"` frozen.
- `GRDBProfileIndexRepository` covering both the app-side mutation surface (`ProfileStore`) and the sync-side dispatch surface (`ProfileIndexSyncHandler`).
- `ProfileIndexSyncHandler` rewrite: same external API, GRDB-backed internals.
- `ProfileStore` rewrite: `loadCloudProfiles` becomes async-driven; `addProfile` / `updateProfile` / `removeProfile` route through `profileIndexRepository`.
- `SwiftDataToGRDBMigrator` extension: per-type migrator gated by `v4.profileIndex.grdbMigrated` flag, runs once at app launch before `ProfileStore.init` (not per-profile-session).
- `ProfileDataDeleter.swift` deleted (single call site inlines the repository call).
- Reviewers: `database-schema-review`, `database-code-review`, `concurrency-review`, `sync-review`, `code-review`.

**Acceptance (Phase A):** ProfileRecord round-trips through GRDB; sync round-trip works; migrator runs once and is no-op thereafter; SwiftData store stays in place for Phase B.

**Phase B — SwiftData teardown.** Gated by Phase A having shipped a release the user has run on every active device.

- Delete every `@Model` class (eleven files under `Backends/CloudKit/Models/`).
- Delete `SwiftDataToGRDBMigrator.swift` (and its four extensions) — every device has by definition been migrated.
- Strip `import SwiftData` from every production file.
- Shrink `ProfileContainerManager`: drop `indexContainer`, `containers`, `dataSchema`. Keep `profileIndexRepository` and per-profile `databases`.
- One-shot cleanup of legacy `Moolah-v2.store` and `Moolah-{UUID}.store` files at app launch (gated by `v4.swiftDataStores.cleared` flag, mirroring `cleanupLegacyRateCachesOnce`).
- New CI check: `just no-swiftdata` — fails if any production file imports SwiftData.
- Reviewers: `code-review`, `concurrency-review`, `sync-review`.

**Acceptance (Phase B):** Zero `import SwiftData` in production; all UI surfaces work; CKSyncEngine continues to round-trip records; `Moolah-v2.store` and per-profile `.store` files removed from disk.

### Slice 4 — `AnalysisRepository` SQL aggregation rewrite

✅ **Shipped via PR [#594](https://github.com/ajsutton/moolah-native/pull/594) on 2026-04-29.**

Pushed the per-instrument `GROUP BY` aggregation into SQL for the four hot `AnalysisRepository` methods (`fetchDailyBalances`, `fetchExpenseBreakdown`, `fetchIncomeAndExpense`, `fetchCategoryBalances`) — the rewrite Slice 1 deliberately deferred. Per-day grouping (`DATE(t.date) AS day`) preserves per-leg conversion semantics under `INSTRUMENT_CONVERSION_GUIDE.md` Rule 5; conversion stays Swift-side, SQL emits per-`(day, instrument)` SUMs.

Plan-pinning tests (`AnalysisAggregationPlanPinningTests`, `DailyBalancesPlanPinningTests`) assert the covering indexes (`leg_analysis_by_type_account`, `leg_analysis_by_type_category`, `leg_analysis_by_earmark_type`, `iv_by_account_date_value`) participate; date-sensitive conversion regression tests using `MoolahTests/Support/DateBasedFixedConversionService.swift` pin the per-day invariant.

**Side-effects vs. original plan:** the PR also deleted the entire `Backends/CloudKit/Repositories/` directory (the `CloudKitAnalysis*` static-helper files Slice 1 had kept around) and lifted `financialMonth` to `Shared/FinancialMonth.swift`. Slice 3 Phase B's "move the analysis helpers" task is therefore already done.

## 7. Risks & mitigations

- **Migrator data loss.** The SwiftData → GRDB migrator is the highest-risk component. `encodedSystemFields` must be preserved bit-for-bit or sync gets confused. **Mitigation:** explicit migrator tests with realistic SwiftData fixtures; a reversible `UserDefaults` flag so migrator can be re-run if it errors mid-way; a one-time backup of the SwiftData store before migration runs.
- **Schema drift between `CloudKit/schema.ckdb` and the GRDB SQL schema.** Today the `@Model`s and CKDB are kept consistent by hand; GRDB adds a third schema. **Mitigation:** extend `tools/CKDBSchemaGen` to emit GRDB DDL alongside the existing CKDB outputs. Owner: assigned in the Slice 1 PR.
- **Per-profile rate cache duplication.** Two profiles both reporting in AUD will fetch FX rates twice. Storage cost ~5–10 MB per profile. Bandwidth wasted is invisible to one-or-two-profile users. **Mitigation:** none yet. Revisit if multi-profile becomes a primary use case.
- **GRDB version updates.** New dependency to keep current. **Mitigation:** `Package.resolved` checked in; updates are explicit; CI catches breakage.
- **SwiftPM resolution at fresh checkout.** First clone needs network. **Mitigation:** standard for SwiftPM projects; CI caches.

## 8. Open questions

None at this time. All architectural decisions in §4 are settled.
