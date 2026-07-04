# Pre-listing crypto $0 valuation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Value a `priced` crypto token at $0 (`.knownZero`) for any date strictly before its confirmed first-trade date, instead of throwing and dropping the whole net-worth day.

**Architecture:** The discriminated `CryptoPriceService.priceLookup(for:on:)` seam already returns `.priced(rate)` / `.knownZero`, and the conversion service already folds `.knownZero` to `.zero(target)`. We add a per-token confirmed first-trade date (`crypto_token_meta.first_traded_on`), set it when the existing contiguous backward backfill exhausts every provider with no *transient* failure, and make the price path resolve pre-first-trade dates to `.knownZero` rather than throwing.

**Tech Stack:** Swift 6, GRDB (SQLite), Swift Testing, `just` build/test targets, macOS/iOS 26.

**Design doc:** `plans/2026-06-18-crypto-pre-listing-zero-valuation-design.md`

## Global Constraints

- All changes land via a worktree + PR; `main` is protected. Worktree is `crypto-prelisting-zero` (already created).
- Build/format/test only via `just` targets (`just build-mac`, `just test-mac <Suite>`, `just format-check`). Never raw `swift`/`xcodebuild`/`swift-format`.
- Capture test output to `.agent-tmp/` (gitignored); `just test` filters need the **exact suite TYPE name**.
- Tests are Swift Testing (`@Suite`/`@Test`/`#expect`), one extension per protocol conformance, no `swiftlint:disable`/baseline. Run `just format-check` after every task.
- Rate caches (`crypto_price`, `crypto_token_meta`) live in the env-global `profile-index.sqlite` via `ProfileIndexSchema`; migration IDs are frozen once shipped.
- UTC-day keys throughout: dates compare as ISO `YYYY-MM-DD` strings (chronological == lexical), via `Calendar.utc` / the service's `dateFormatter`.
- `.knownZero` is reserved for *intentional* zero; a real/transient failure must still throw (never silently zero a held position) — `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11.

---

## File map

- `Backends/GRDB/ProfileIndexSchema.swift` — register `v8`, bump `version` to 8, migration-history comment.
- `Backends/GRDB/ProfileIndexSchema+CryptoFirstTradedOn.swift` — **new** v8 migration body.
- `MoolahTests/Backends/GRDB/ProfileIndexSchemaV3Tests.swift` — version assertion 7 → 8.
- `MoolahTests/Backends/CryptoFirstTradedOnMigrationTests.swift` — **new** migration test.
- `Backends/GRDB/Records/CryptoTokenMetaRecord.swift` — add `firstTradedOn` column/coding key/field.
- `Shared/CryptoPriceCache.swift` (CryptoPriceCache struct; confirm path) — add `firstTradedOn: String?`.
- `Shared/CryptoPriceService+Persistence.swift` — round-trip `firstTradedOn` in `loadCache`/`persistDelta`.
- `Shared/CryptoPriceService+FetchRange.swift` — structural-vs-operational error handling; set `first_traded_on` on clean no-progress; `beforeFirstTrade` in `resolveAfterExtension`.
- `Shared/CryptoPriceService.swift` — fast-path short-circuit in `price(for:mapping:on:)`.
- `Domain/Repositories/CryptoPriceClient.swift` — add `CryptoPriceError.beforeFirstTrade`.
- `Shared/ConversionFailureClassifier.swift` — classify `beforeFirstTrade` (structural).
- `Shared/CryptoPriceService+PriceLookup.swift` — map `beforeFirstTrade` → `.knownZero`.
- `MoolahTests/Shared/...` — service/classifier/seam/integration tests (per task).

---

## Task 1: Schema migration `v8_crypto_first_traded_on`

**Files:**
- Modify: `Backends/GRDB/ProfileIndexSchema.swift`
- Create: `Backends/GRDB/ProfileIndexSchema+CryptoFirstTradedOn.swift`
- Modify: `MoolahTests/Backends/GRDB/ProfileIndexSchemaV3Tests.swift:18-22`
- Create: `MoolahTests/Backends/CryptoFirstTradedOnMigrationTests.swift`

**Interfaces:**
- Produces: column `crypto_token_meta.first_traded_on TEXT` (nullable); `ProfileIndexSchema.version == 8`; migration id `"v8_crypto_first_traded_on"`.

- [ ] **Step 1: Write the failing migration test**

Create `MoolahTests/Backends/CryptoFirstTradedOnMigrationTests.swift`:

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("v8_crypto_first_traded_on migration")
struct CryptoFirstTradedOnMigrationTests {
  @Test("v8 adds nullable first_traded_on and preserves existing rows")
  func addsColumnPreservingRows() throws {
    let dbQueue = try DatabaseQueue()
    try ProfileIndexSchema.migrator.migrate(dbQueue, upTo: "v7_purge_crypto_price_cache")
    try dbQueue.write { db in
      try db.execute(sql: """
        INSERT INTO crypto_token_meta (token_id, symbol, earliest_date, latest_date)
        VALUES ('1:native', 'ETH', '2021-01-01', '2026-06-01');
        """)
    }
    try ProfileIndexSchema.migrator.migrate(dbQueue)  // applies v8
    let (count, firstTraded): (Int, String?) = try dbQueue.read { db in
      let c = try Table("crypto_token_meta").fetchCount(db)
      let f = try String.fetchOne(
        db, sql: "SELECT first_traded_on FROM crypto_token_meta WHERE token_id = '1:native'")
      return (c, f)
    }
    #expect(count == 1)        // row preserved
    #expect(firstTraded == nil)  // new column defaults NULL
  }

  @Test("first_traded_on is writable after v8")
  func columnIsWritable() throws {
    let dbQueue = try DatabaseQueue()
    try ProfileIndexSchema.migrator.migrate(dbQueue)
    try dbQueue.write { db in
      try db.execute(sql: """
        INSERT INTO crypto_token_meta (token_id, symbol, earliest_date, latest_date, first_traded_on)
        VALUES ('1:native', 'ETH', '2024-10-01', '2026-06-01', '2024-10-01');
        """)
    }
    let f: String? = try dbQueue.read { db in
      try String.fetchOne(db, sql: "SELECT first_traded_on FROM crypto_token_meta")
    }
    #expect(f == "2024-10-01")
  }
}
```

- [ ] **Step 2: Run it; verify it fails**

Run: `just test-mac CryptoFirstTradedOnMigrationTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: FAIL — `migrate(upTo: "v7…")` errors (no such migration yet only if v7 unmerged; v7 is in flight on `main`) or the v8 migration/column is missing so `first_traded_on` selects error / version mismatch.

- [ ] **Step 3: Add the migration body**

Create `Backends/GRDB/ProfileIndexSchema+CryptoFirstTradedOn.swift`:

```swift
// Backends/GRDB/ProfileIndexSchema+CryptoFirstTradedOn.swift

import Foundation
import GRDB

// MARK: - v8 migration body
//
// Adds `crypto_token_meta.first_traded_on` (nullable ISO YYYY-MM-DD): the
// confirmed cross-provider first-trade date for a token. NULL means "not yet
// confirmed". The crypto price path values any date strictly before this as
// $0 (.knownZero) instead of throwing — see
// `plans/2026-06-18-crypto-pre-listing-zero-valuation-design.md`.

extension ProfileIndexSchema {
  /// Body of the `v8_crypto_first_traded_on` migration.
  static func addCryptoFirstTradedOn(_ database: Database) throws {
    try database.execute(
      sql: "ALTER TABLE crypto_token_meta ADD COLUMN first_traded_on TEXT;")
  }
}
```

- [ ] **Step 4: Register the migration and bump the version**

In `Backends/GRDB/ProfileIndexSchema.swift`: add to the migration-history doc comment a `v8_crypto_first_traded_on` line; change `static let version = 7` to `static let version = 8`; register after v7:

```swift
    migrator.registerMigration(
      "v8_crypto_first_traded_on", migrate: addCryptoFirstTradedOn)
```

- [ ] **Step 5: Update the version assertion**

In `MoolahTests/Backends/GRDB/ProfileIndexSchemaV3Tests.swift`:

```swift
    // Bumped to 8 by `v8_crypto_first_traded_on`.
    #expect(ProfileIndexSchema.version == 8)
```

- [ ] **Step 6: Run tests; verify pass**

Run: `just test-mac CryptoFirstTradedOnMigrationTests ProfileIndexSchemaV3Tests 2>&1 | tee .agent-tmp/t1.txt`
Expected: PASS (all suites).

- [ ] **Step 7: format-check + commit**

Run: `just format-check`
```bash
git add Backends/GRDB/ProfileIndexSchema.swift Backends/GRDB/ProfileIndexSchema+CryptoFirstTradedOn.swift MoolahTests/Backends/GRDB/ProfileIndexSchemaV3Tests.swift MoolahTests/Backends/CryptoFirstTradedOnMigrationTests.swift
git commit -m "feat(crypto): add crypto_token_meta.first_traded_on (v8)"
```

---

## Task 2: Round-trip `firstTradedOn` through the record + cache

**Files:**
- Modify: `Backends/GRDB/Records/CryptoTokenMetaRecord.swift`
- Modify: `Shared/CryptoPriceCache.swift` (the `CryptoPriceCache` struct — confirm exact path via `grep -rl "struct CryptoPriceCache" Shared Domain`)
- Modify: `Shared/CryptoPriceService+Persistence.swift:17-90`
- Create: `MoolahTests/Shared/CryptoFirstTradedOnPersistenceTests.swift`

**Interfaces:**
- Consumes: `crypto_token_meta.first_traded_on` (Task 1).
- Produces: `CryptoTokenMetaRecord.firstTradedOn: String?`; `CryptoPriceCache.firstTradedOn: String?`; `loadCache`/`persistDelta` persist it.

- [ ] **Step 1: Write the failing persistence test**

Create `MoolahTests/Shared/CryptoFirstTradedOnPersistenceTests.swift`. Use the same in-memory price-service harness other `CryptoPriceService` persistence tests use (find one with `grep -rl "CryptoPriceService(" MoolahTests | head`; mirror its setup). Assert that after seeding a `crypto_token_meta` row with `first_traded_on = '2024-10-01'` and calling `loadCache(tokenId:)`, the in-memory cache exposes `firstTradedOn == "2024-10-01"`; and that a `persistDelta` round-trip preserves a non-nil `firstTradedOn`.

```swift
// Skeleton — match the existing CryptoPriceService persistence harness for DB setup.
@Test("loadCache hydrates first_traded_on from crypto_token_meta")
func loadsFirstTradedOn() async throws {
  // seed crypto_token_meta with first_traded_on, then loadCache, then assert
  // service.caches[tokenId]?.firstTradedOn == "2024-10-01"
}
```

- [ ] **Step 2: Run it; verify it fails to compile / fails**

Run: `just test-mac CryptoFirstTradedOnPersistenceTests 2>&1 | tee .agent-tmp/t2.txt`
Expected: FAIL — `firstTradedOn` not a member.

- [ ] **Step 3: Add the field to the record**

In `CryptoTokenMetaRecord.swift`: add `case firstTradedOn = "first_traded_on"` to **both** `Columns` and `CodingKeys`, and add the stored property `var firstTradedOn: String?` after `latestDate`. (Codable-derived conformance handles bind/decode.)

- [ ] **Step 4: Add the field to the cache struct**

In the `CryptoPriceCache` struct add `var firstTradedOn: String?` and thread it through its initializer (default `nil`).

- [ ] **Step 5: Persist it**

In `CryptoPriceService+Persistence.swift`:
- `loadCache`: pass `firstTradedOn: metaRecord.firstTradedOn` into the `CryptoPriceCache(...)` initializer.
- `persistDelta`: build `CryptoTokenMetaRecord(..., firstTradedOn: cache.firstTradedOn)` so writes don't clobber it to nil.

- [ ] **Step 6: Run tests; verify pass**

Run: `just test-mac CryptoFirstTradedOnPersistenceTests 2>&1 | tee .agent-tmp/t2.txt`
Expected: PASS.

- [ ] **Step 7: format-check + commit**

```bash
just format-check
git add -A && git commit -m "feat(crypto): persist firstTradedOn on the token meta cache"
```

---

## Task 3: Preserve structural-vs-operational provider failures in `fetchRange`

**Files:**
- Modify: `Shared/CryptoPriceService+FetchRange.swift:228-267` (`fetchRange`)
- Create: `MoolahTests/Shared/CryptoFetchRangeErrorClassificationTests.swift`

**Background:** `fetchRange` currently wraps **every** provider error into `WalletSyncError(.network …)`, so a missing/invalid API key reads as transient. We must preserve structural failures (`missingApiKey`/`invalidApiKey`) as structural so Task 4's confirmation gate can tell "provider couldn't possibly help" (OK to confirm $0) from "provider was rate-limited/offline" (must not confirm).

**Interfaces:**
- Produces: `fetchRange` throws a `WalletSyncError` whose `kind` is **preserved** (`.missingApiKey`/`.invalidApiKey` stay structural; `.network`/`.rateLimited` stay operational), classifiable by `ConversionFailureClassifier.isTransient`. A window where the *only* failures are structural (or `noProviderMapping`) and all reachable providers returned empty does **not** throw.

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Shared/CryptoFetchRangeErrorClassificationTests.swift`. Build a `CryptoPriceService` with stub clients (mirror `GatedCryptoPriceClient`/existing client doubles — `grep -rl "CryptoPriceClient" MoolahTests/Support`). Cases:

```swift
@Test("a missing-API-key-only window surfaces a structural failure (not transient)")
func missingKeyIsStructural() async throws {
  // single client that throws WalletSyncError(.missingApiKey); others none/empty
  // expect: thrown error classifies ConversionFailureClassifier.isTransient(error) == false
}

@Test("a rate-limited window surfaces a transient failure")
func rateLimitIsTransient() async throws {
  // client throws WalletSyncError(.rateLimited) (or URLError)
  // expect: ConversionFailureClassifier.isTransient(error) == true
}
```

- [ ] **Step 2: Run it; verify it fails**

Run: `just test-mac CryptoFetchRangeErrorClassificationTests 2>&1 | tee .agent-tmp/t3.txt`
Expected: FAIL — missing-key currently classifies transient (wrapped as `.network`).

- [ ] **Step 3: Preserve the structural kind**

In `fetchRange`, replace the catch-all re-wrap. Instead of always throwing `WalletSyncError(.network …)`:
- If the captured `lastError` is already a `WalletSyncError`, **rethrow it unchanged** (preserves `.missingApiKey`/`.invalidApiKey`/`.rateLimited`).
- Treat `missingApiKey`/`invalidApiKey` like `noProviderMapping` for routing — i.e. they should *not* be the thing that forces a transient outage when other providers merely returned empty. Concretely: track structural failures separately from operational ones; only wrap-as-`.network` when an operational (network/URL/rate-limit/malformed) error occurred. If every failure was structural and the rest returned empty, return normally (no throw) — the window genuinely has no data from any usable provider.

```swift
// Sketch — adapt to the existing loop variables:
var operationalError: (any Error)?
var lastProvider: SyncProvider?
for client in clients {
  do {
    let fetched = try await client.dailyPrices(for: mapping, in: from...to)
    if !fetched.isEmpty { /* merge + persist + return (unchanged) */ }
  } catch is CancellationError {
    throw CancellationError()
  } catch CryptoPriceError.noProviderMapping {
    continue  // structural: provider doesn't carry this token
  } catch let e as WalletSyncError where !ConversionFailureClassifier.isTransient(e) {
    continue  // structural: provider unusable (e.g. missing/invalid key)
  } catch {
    operationalError = error; lastProvider = client.syncProvider; continue
  }
}
if let operationalError {
  throw WalletSyncError(
    provider: lastProvider,
    kind: .network(underlyingDescription: String(describing: operationalError)))
}
```

(If a test needs to assert a *structural* error is surfaced rather than swallowed, surface the last structural error when there was no data AND no operational error AND no provider had a mapping — choose per the test in Step 1; the load-bearing requirement is that structural failures never read as transient.)

- [ ] **Step 4: Run tests; verify pass**

Run: `just test-mac CryptoFetchRangeErrorClassificationTests CryptoPriceServiceTests CryptoPriceServiceCoalescingTests 2>&1 | tee .agent-tmp/t3.txt`
Expected: PASS (and no regression in existing price-service suites).

- [ ] **Step 5: format-check + commit**

```bash
just format-check
git add -A && git commit -m "fix(crypto): preserve structural vs operational provider failures in fetchRange"
```

---

## Task 4: Confirm first-trade on clean no-progress backward backfill

**Files:**
- Modify: `Shared/CryptoPriceService+FetchRange.swift:14-133` (`extendContiguously`, `coverRangeContiguously`)
- Create: `MoolahTests/Shared/CryptoFirstTradeConfirmationTests.swift`

**Interfaces:**
- Consumes: structural-vs-operational distinction (Task 3); `boundsKeys`, `caches[tokenId].earliestDate`.
- Produces: after a **backward** window walk terminates on no-progress with **no operational failure**, `caches[tokenId].firstTradedOn` is set to the cache's current `earliestDate` and persisted; on an operational-failure termination it is left unchanged (nil stays nil).

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Shared/CryptoFirstTradeConfirmationTests.swift`. Use gated/stub clients that return data only on/after a fixed date `F` and empty before it:

```swift
@Test("backward walk that exhausts all providers sets firstTradedOn to the earliest served date")
func confirmsFirstTrade() async throws {
  // clients serve prices only for dates >= F; empty before F, no errors.
  // request a date < F via price(...) (expect it to fail to find a price — see Task 5),
  // then assert service.caches[tokenId]?.firstTradedOn == isoString(F)
}

@Test("a transient failure during the backward walk does NOT set firstTradedOn")
func transientLeavesUnconfirmed() async throws {
  // a provider throws a rate-limit below F; expect firstTradedOn stays nil
}
```

(For Step 1 the `price(...)` call may currently throw `noPriceAvailable`; assert on `firstTradedOn` state regardless, wrapping the call in `try? `.)

- [ ] **Step 2: Run it; verify it fails**

Run: `just test-mac CryptoFirstTradeConfirmationTests 2>&1 | tee .agent-tmp/t4.txt`
Expected: FAIL — `firstTradedOn` never set.

- [ ] **Step 3: Track break reason + set the marker**

In `extendContiguously` and `coverRangeContiguously`, distinguish the no-progress break from the error/in-range breaks. On the **no-progress** break of a backward window (`window.lowerBound < bounds.earliest`, i.e. we were walking back) when `lastFetchError == nil`, set and persist the marker:

```swift
// after the loop, when terminated by no-progress with no operational error
if lastFetchError == nil, var cache = caches[tokenId], cache.firstTradedOn == nil {
  cache.firstTradedOn = cache.earliestDate   // earliest any provider served
  caches[tokenId] = cache
  try await persistFirstTradedOn(tokenId: tokenId, date: cache.earliestDate)
}
```

Add a small persistence helper (in `+Persistence.swift`) that writes only the meta row's `first_traded_on` (re-using `persistDelta`'s meta-write shape with an empty delta), and `notifyRateCacheChange(.cryptoPrice)`.

Only set when the walk actually attempted to go *below* the current earliest and found nothing (guard against setting it on a forward-only or in-range exit).

- [ ] **Step 4: Run tests; verify pass**

Run: `just test-mac CryptoFirstTradeConfirmationTests CryptoPriceServiceTests 2>&1 | tee .agent-tmp/t4.txt`
Expected: PASS.

- [ ] **Step 5: format-check + commit**

```bash
just format-check
git add -A && git commit -m "feat(crypto): confirm first-trade date on exhausted backward backfill"
```

---

## Task 5: Resolve pre-first-trade dates to `.knownZero`

**Files:**
- Modify: `Domain/Repositories/CryptoPriceClient.swift:4-8` (add error case)
- Modify: `Shared/ConversionFailureClassifier.swift:38-45`
- Modify: `Shared/CryptoPriceService.swift:133-164` (`price`, fast-path)
- Modify: `Shared/CryptoPriceService+FetchRange.swift` (`resolveAfterExtension`)
- Modify: `Shared/CryptoPriceService+PriceLookup.swift`
- Create: `MoolahTests/Shared/CryptoPreListingZeroTests.swift`

**Interfaces:**
- Consumes: `caches[tokenId].firstTradedOn` (Task 4).
- Produces: `CryptoPriceError.beforeFirstTrade(tokenId: String, date: String)`; `price(...)` throws it for dates strictly before a set `firstTradedOn`; `priceLookup(...)` returns `.knownZero` for that case.

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Shared/CryptoPreListingZeroTests.swift`:

```swift
@Test("priceLookup returns knownZero for a date before the confirmed first-trade date")
func preListingIsKnownZero() async throws {
  // seed cache: firstTradedOn = "2024-10-01", earliest/latest covering Oct 2024
  // priced registration; lookup on 2024-09-25
  let result = try await service.priceLookup(for: registration, on: day("2024-09-25"))
  #expect(result == .knownZero)
}

@Test("priceLookup still throws for an uncached gap on/after first trade")
func postFirstTradeGapThrows() async throws {
  // firstTradedOn = "2024-10-01"; a date >= floor with no price and a transient
  // provider failure must throw, not zero.
  await #expect(throws: (any Error).self) {
    _ = try await service.priceLookup(for: registration, on: day("2024-10-05"))
  }
}
```

- [ ] **Step 2: Run it; verify it fails**

Run: `just test-mac CryptoPreListingZeroTests 2>&1 | tee .agent-tmp/t5.txt`
Expected: FAIL — pre-listing currently throws `noPriceAvailable` (not `.knownZero`).

- [ ] **Step 3: Add the error case + classify it**

In `CryptoPriceClient.swift` add to `CryptoPriceError`:
```swift
  case beforeFirstTrade(tokenId: String, date: String)
```
Add its `errorDescription`. In `ConversionFailureClassifier.isTransient(_ CryptoPriceError)` add the case (structural — definitive, not transient):
```swift
    case .beforeFirstTrade:
      return false
```

- [ ] **Step 4: Fast-path + resolve to beforeFirstTrade**

In `CryptoPriceService.price(for:mapping:on:)`, after `loadCache`/cache hydration and before/around the extension call, short-circuit:
```swift
if let cache = caches[tokenId], let floor = cache.firstTradedOn, dateString < floor {
  throw CryptoPriceError.beforeFirstTrade(tokenId: tokenId, date: dateString)
}
```
In `resolveAfterExtension` (after the backward walk just set `firstTradedOn` in Task 4): if no price resolved and `dateString < caches[tokenId]?.firstTradedOn`, throw `beforeFirstTrade` instead of `noPriceAvailable`/the fetch error.

- [ ] **Step 5: Map to knownZero at the lookup seam**

In `CryptoPriceService+PriceLookup.swift`, wrap the `.priced` branch:
```swift
    case .priced:
      do {
        let rate = try await price(
          for: registration.instrument, mapping: registration.mapping, on: date)
        return .priced(rate)
      } catch CryptoPriceError.beforeFirstTrade {
        return .knownZero
      }
```

- [ ] **Step 6: Run tests; verify pass**

Run: `just test-mac CryptoPreListingZeroTests ConversionFailureClassifierTests CryptoPriceServiceTests 2>&1 | tee .agent-tmp/t5.txt`
Expected: PASS.

- [ ] **Step 7: format-check + commit**

```bash
just format-check
git add -A && git commit -m "feat(crypto): value pre-first-trade dates as knownZero"
```

---

## Task 6: End-to-end scenario + zone-invariance

**Files:**
- Create: `MoolahTests/Backends/GRDB/PreListingDailyBalanceTests.swift`

**Interfaces:**
- Consumes: the full path (Tasks 1–5) via `TestBackend`/the analysis repository conversion seam.

- [ ] **Step 1: Write the failing/again-green scenario test**

Create `MoolahTests/Backends/GRDB/PreListingDailyBalanceTests.swift`. Using `TestBackend` (CloudKitBackend + in-memory GRDB) and a stub/gated crypto price client serving prices only on/after `F = 2024-10-01`:
- Seed an account holding a `priced` token received (income leg) on `2024-09-25`, plus another normally-priced holding.
- Drive the daily-balances aggregation across `2024-09-25…2024-10-02`.
- Assert: every day in the window is present (none dropped); the pre-`F` days value the airdrop token at $0 while the other holding still contributes; the income leg for the airdrop on `2024-09-25` converts to $0; on/after `F` the token values at the served market price.

```swift
@Test("a token held before its first trade values at $0 without dropping the day")
func preListingDayRenders() async throws {
  // ...seed, run fetchDailyBalances, assert per-day presence + $0 contribution
}
```

- [ ] **Step 2: Add a zone-invariance assertion**

Add a second `@Test` that runs the same assertion under a UTC-negative test timezone (mirror the harness used in the date-seam tests — `grep -rl "Calendar.utc\|TimeZone(identifier:" MoolahTests | head`) and confirms the first-trade boundary (2024-09-30 → $0, 2024-10-01 → priced) does not shift by a day.

- [ ] **Step 3: Run it; verify pass**

Run: `just test-mac PreListingDailyBalanceTests 2>&1 | tee .agent-tmp/t6.txt`
Expected: PASS.

- [ ] **Step 4: Full crypto + analysis regression**

Run: `just test-mac CryptoPriceServiceTests CryptoPriceServiceCoalescingTests DefiLlamaClientTests DailyBalancesPlanPinningTests 2>&1 | tee .agent-tmp/t6-regress.txt`
Expected: PASS.

- [ ] **Step 5: format-check + commit**

```bash
just format-check
git add -A && git commit -m "test(crypto): pre-listing $0 valuation end-to-end + zone-invariance"
```

---

## Final verification

- [ ] `just format-check` clean.
- [ ] `just build-mac` succeeds (no warnings — `SWIFT_TREAT_WARNINGS_AS_ERRORS`).
- [ ] Run the broad crypto/analysis suites once more (Task 6 Step 4 set) to confirm no regressions.
- [ ] Push branch + open PR; enable automerge via the landing-prs skill.

## Self-review notes (coverage vs spec)

- Rule (price-on-date, $0 before first trade) → Tasks 4+5. ✓
- Confirmed first-trade via DefiLlama floor + backward cross-check → Task 4 (floor is the existing `defillama_support.earliest_date` seeding where the backward walk starts; no `/chart` re-probe, per design). ✓
- Structural-vs-operational gate (no-key/no-mapping OK; rate-limit blocks) → Task 3 + classifier in Task 5. ✓
- `fetchRange` flatten-to-`.network` fix → Task 3. ✓
- `crypto_token_meta.first_traded_on` + migration v8 + version assertion → Tasks 1+2. ✓
- knownZero propagation (graph, income/expense, income leg) → reuses existing `.knownZero` fold; verified end-to-end in Task 6. ✓
- Edge cases: transient never zeroes (Task 3/4/5 tests); zone-invariance (Task 6). ✓
- Out of scope: CGT, UI affordance, charts range path — not in plan, per design.
