# Exchange Accounts (Coinstash) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new `AccountType.exchange` for centralised exchange accounts (crypto or stock brokers), with Coinstash as the first provider, syncing trade/deposit/withdrawal history via Coinstash's authenticated GraphQL API using a per-account read-only access token.

**Architecture:** Exchange accounts are investment-like: valuation is derived from positions (transaction legs), exactly like `.investment`. A new `ExchangeProvider` enum on `Account` selects the provider. The read-only access token is stored per-account in the iCloud keychain (never in the DB/CloudKit).

**De-duplication is a hard requirement.** Crypto-wallet sync and exchange sync share one pipeline, not two:
- One **`AccountSyncSource`** protocol abstracts "produce `WalletSyncBuildResult` for this account". Conformances: `WalletSyncSource` (wraps the *existing* `WalletSyncEngine` + chain lookup) and **one source per exchange** — `CoinstashSyncSource` for v1, wrapping `CoinstashClient` + the shared `ExchangeSyncEngine` + token store. Each future exchange has a *different API*, so each gets its own `<Provider>SyncSource` + `<Provider>Client` pair; only the provider-specific transport/source is per-exchange. The neutral pieces (`ExchangeClient` protocol, `ExchangeImportedTransaction`, `ExchangeSyncEngine`, `ExchangeInstrumentResolver`, `ExchangeTokenStore`) are shared across all exchanges and keep the `Exchange` prefix.
- `CryptoSyncStore` is **generalised and renamed `SyncedAccountStore`** — one staleness loop, one in-flight set, one `WalletSyncState` persistence path, one error model — driven by the registered sources. No parallel store.
- The sync control is the **account-detail header**, not a list. `CryptoSettingsView` currently *also* lists crypto accounts via `CryptoAccountsListSection` (`CryptoSettingsView.swift:43-46`) — that list is **deleted** (the per-account sync control already lives in the account view). `WalletAccountHeaderView` / `WalletAccountHeaderLogic` (the existing crypto account-detail header: last-synced caption + "Sync now" button + error/missing-key hints) is **generalised** into one shared synced-account header used by both crypto and exchange detail views, plus a small `SyncableAccountPresentation` seam supplying the per-type account identifier and "open externally" target (crypto → block explorer; exchange → exchange website). `CryptoSettingsView` keeps only global config (Alchemy key, CoinGecko key, token inbox/list).

The only genuinely new external API is `ExchangeClient`/`CoinstashClient` (the Coinstash GraphQL transport). Everything else reuses `WalletApplyEngine`, `WalletSyncState`, `BuiltTransaction`, and the shared UI/formatters.

**Tech Stack:** Swift 6, SwiftUI (macOS), GRDB (SQLite), CloudKit (CKSyncEngine), Swift Testing (`@Test`/`#expect`), `just` task runner.

**Scope note:** This is one cohesive feature but spans 6 subsystems. The phases below are ordered so each ends at a green, committable state. Execute and review **phase by phase**; do not batch across phases.

**Assumptions baked in (redirect now if wrong):**
- v1 imports **transaction history only** (trades/deposits/withdrawals/fees → derived positions). Balance reconciliation is out of scope.
- Provider abstraction is a **thin seam** (`ExchangeClient` protocol + concrete `CoinstashClient`); no generic multi-exchange registry/config yet. Crypto and exchange share the sync store and the account-detail header UI via `AccountSyncSource` + `SyncableAccountPresentation`; the redundant Settings list is removed — duplication of orchestration/UI is explicitly disallowed.
- Exchange sync does a **full history re-fetch + dedup** each cycle (Coinstash accounts are small; the existing `(account_id, external_id)` partial-unique leg index makes this idempotent). No incremental cursor in v1; `WalletSyncState.lastSyncedBlockNumber` is unused (sentinel `0`).
- The Coinstash GraphQL contract is the one validated live on 2026-05-16: endpoint `https://graph.coinstash.com.au/graphql`, header `Authorization: Bearer <token>`, flow `userProfile{userId}` → `getUserAccounts(userId){accounts{accountId}}` → paginate `accountTransactions(accountId, {pageIndex,pageSize})` until `totalRecordsFound`.

---

## Coinstash transaction → Moolah mapping (reference for Phase 4–5)

`accountTransactions.result[]` fields used: `transactionId`, `transactedOn` (ISO8601), `category` (`TRADE|TRADEFEE|DEPOSIT|WITHDRAW|AWARD`), `type` (`CREDIT|DEBIT`), `assetSymbol`, `amount`, `amountType` (`FIAT|ASSET`), `quoteBuyPrice`, `quoteSellPrice`, `orderId`, `orderType` (`BUY|SELL`), `transactionStatus`.

Mapping rules (v1):
- Only `transactionStatus == "COMPLETED"` rows are imported.
- Each row → one `TransactionLeg` with `externalId = transactionId` (dedup key), `accountId = exchange account id`.
- Instrument: `amountType == "ASSET"` → crypto instrument resolved from `assetSymbol`; `amountType == "FIAT"` → AUD.
- Quantity sign: `type == "CREDIT"` → positive; `type == "DEBIT"` → negative.
- Rows sharing a non-nil `orderId` are grouped into one `Transaction` (a trade: asset leg + fiat leg + optional `TRADEFEE` leg). Rows with nil `orderId` (`DEPOSIT`/`WITHDRAW`/`AWARD`) become single-leg `Transaction`s.
- Transaction date = earliest `transactedOn` in the group.

---

## File Structure

**Domain / model**
- Modify `Domain/Models/Account.swift` — add `AccountType.exchange`, `ExchangeProvider` enum, `Account.exchangeProvider` field.
- Create `Domain/Models/ExchangeProvider.swift` — provider enum (if Account.swift grows too large, otherwise inline; see Task 1).

**Persistence (GRDB)**
- Modify `Backends/GRDB/Records/AccountRow.swift` — add `exchangeProvider` column.
- Modify `Backends/GRDB/Records/AccountRow+Mapping.swift` — map field both directions.
- Create `Backends/GRDB/ProfileSchema+ExchangeAccountFields.swift` — v11 migration (widen `type` CHECK, add `exchange_provider`).
- Modify `Backends/GRDB/ProfileSchema.swift` — register v11.

**CloudKit**
- Modify `CloudKit/schema.ckdb` — add `exchangeProvider` field to `AccountRecord`.
- Modify `Backends/CloudKit/Sync/Generated/AccountRecordCloudKitFields.swift` — add field (regenerated via modifying-cloudkit-schema skill).
- Modify `Backends/GRDB/Sync/AccountRow+CloudKit.swift` — encode/decode `exchangeProvider`; add `"exchange"` to the safe account-type allowlist.

**Credential**
- Create `Shared/Exchange/ExchangeTokenStore.swift` — per-account keychain read/write.

**Exchange client**
- Create `Shared/Exchange/ExchangeClient.swift` (protocol), `ExchangeClientError.swift`, `ExchangeDirection.swift`, `ExchangeImportedTransaction.swift` — one primary type per file.
- Create `Shared/Exchange/CoinstashClient.swift` — GraphQL implementation.
- Create `Shared/Exchange/CoinstashGraphQL.swift` — query strings + Codable response models.

**Mapping + build**
- Create `Shared/Exchange/ExchangeInstrumentResolver.swift` — symbol → `Instrument`.
- Create `Shared/Exchange/ExchangeSyncEngine.swift` — `build(account:imported:) -> WalletSyncBuildResult` (reuses `BuiltTransaction`).

**Shared sync abstraction (de-dup)**
- Create `Shared/Sync/AccountSyncSource.swift` — protocol both crypto + exchange conform to.
- Create `Shared/Sync/WalletSyncSource.swift` — conformance wrapping the *existing* `WalletSyncEngine` + `ChainConfig` lookup.
- Create `Shared/Exchange/CoinstashSyncSource.swift` — the **Coinstash-specific** `AccountSyncSource`, wrapping `ExchangeTokenStore` + `CoinstashClient` + the shared `ExchangeSyncEngine`. (Each future exchange adds a sibling `<Provider>SyncSource.swift` + `<Provider>Client.swift`; the protocol and neutral pieces are not duplicated.)
- Rename + generalise `Features/Crypto/CryptoSyncStore.swift` → `Features/Sync/SyncedAccountStore.swift` (source-driven; mechanical call-site rename).

**Shared UI (de-dup)**
- Create `Features/Sync/SyncableAccountPresentation.swift` — pure per-account view model: identifier text, external-open URL + title, missing-credential hint.
- Modify `Features/Settings/CryptoSettingsView.swift` — remove the embedded crypto-accounts list (keep global config sections).
- Delete `Features/Crypto/CryptoAccountsListSection.swift` — redundant; the sync control lives in the account-detail header.
- Rename + generalise `Features/Crypto/WalletAccountHeaderView.swift` → `Features/Sync/SyncedAccountHeaderView.swift` and `WalletAccountHeaderLogic.swift` → `Features/Sync/SyncedAccountHeaderLogic.swift` — the one shared sync control (caption + Sync now + identifier + open-externally) for crypto and exchange.
- Modify `App/ContentView.swift` — add the `.exchange` account-detail route.
- Create `Features/Exchange/ExchangeAccountView.swift` — shared header over the (reused) investment-like positions body.

**Exchange-specific UI**
- Create `Features/Exchange/ExchangeAccountCreationView.swift` — view + `ExchangeAccountCreationLogic`.
- Create `Features/Exchange/EditExchangeTokenLogic.swift` — token-replace helper (own file).
- Create `Features/Exchange/JSONValue.swift` — GraphQL body encoding (only if no existing `JSONValue`).
- Modify `Features/Accounts/Views/CreateAccountView.swift` — branch to exchange fields.
- Modify `Features/Accounts/Views/EditAccountView.swift` — exchange-specific section (re-enter token).

**Tests** — under `MoolahTests/` mirroring source paths, Swift Testing.

---

## Phase 1 — Account model + persistence + CloudKit (no behaviour yet)

### Task 1: Add `AccountType.exchange` + `ExchangeProvider` + `Account.exchangeProvider`

**Files:**
- Modify: `Domain/Models/Account.swift:4-31` (enum), `:33-70` (struct + init), `:78-88` (CodingKeys)
- Test: `MoolahTests/Domain/ExchangeAccountModelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Moolah

struct ExchangeAccountModelTests {
  @Test func exchangeTypeIsInvestmentLikeNotCurrent() {
    #expect(AccountType.exchange.isInvestmentLike)
    #expect(!AccountType.exchange.isCurrent)
    #expect(AccountType.exchange.rawValue == "exchange")
    #expect(AccountType.exchange.displayName == "Exchange")
    #expect(AccountType.allCases.contains(.exchange))
  }

  @Test func accountCarriesExchangeProvider() {
    let account = Account(
      name: "Coinstash", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    #expect(account.exchangeProvider == .coinstash)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test ExchangeAccountModelTests`
Expected: FAIL — `.exchange` / `exchangeProvider` not found (compile error).

> **Plan-wide conventions (apply to EVERY code sample below):**
> 1. AUD accessor is `Instrument.AUD` (`static let AUD = Instrument.fiat(code: "AUD")`) — `.AUD`, never `.aud`. `.AUD` is correct for **test fixtures** and the **resolver fiat default**, but production `ExchangeAccountCreationLogic` uses the **profile's** instrument, not hardcoded `.AUD` (Task 10).
> 2. There is **no `Instrument.eth` / `Instrument.opStub`**. `Instrument` exposes only `.AUD`/`.USD` (fiat) plus `Instrument.crypto(chainId:contractAddress:symbol:name:decimals:)`. Every test code sample that writes `instrument: .eth` must instead build a real crypto instrument, e.g. `let eth = Instrument.crypto(chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)` (per the existing pattern in `GRDBCreatePathRegistersInstrumentTests`), declared once per test suite and reused. Reconcile the argument list against the real `Domain/Models/Instrument.swift`.
> 3. There is **no `StubRegistry`** — reuse the existing `StubInstrumentRegistry` (`MoolahTests/Support/StubInstrumentRegistry.swift`, `init(instruments:)`; `all()` returns them). Every `StubRegistry(...)` / `StubRegistry(op:)` in a sample becomes `StubInstrumentRegistry(instruments: [...])`.

- [ ] **Step 3: Add the enum case and provider type**

In `Domain/Models/Account.swift`, add to `enum AccountType` (after `case crypto`):

```swift
  case exchange
```

Update `isInvestmentLike`:

```swift
  var isInvestmentLike: Bool {
    self == .investment || self == .crypto || self == .exchange
  }
```

Update `displayName` switch — add:

```swift
    case .exchange: return "Exchange"
```

Add a new file `Domain/Models/ExchangeProvider.swift`:

```swift
import Foundation

// SyncBoundary — adding a case requires bumping DataFormatVersion.current.
//
// File-scope, bare `//`, immediately above the doc comment — matching the
// exact placement on `Account.swift`/`TransactionType.swift`/`RecurPeriod.swift`
// so the review tooling's `rg -l 'SyncBoundary' Domain/` + diff-context pass
// detects a new `case`. (`exchangeProvider` is a synced field; older builds
// decode unknown values as nil and never sync the account.)
/// Centralised exchange a `.exchange` account syncs from. String-backed so it
/// round-trips through GRDB and CloudKit as a stable token.
enum ExchangeProvider: String, Codable, Sendable, CaseIterable {
  case coinstash

  var displayName: String {
    switch self {
    case .coinstash: return "Coinstash"
    }
  }

  /// Help article for creating a read-only key (used by the creation UI).
  var helpURL: URL {
    switch self {
    case .coinstash: Self.Links.coinstashHelp
    }
  }

  /// Provider website (used by the synced-account header "open externally").
  var website: URL {
    switch self {
    case .coinstash: Self.Links.coinstashHome
    }
  }

  // String-literal URLs: a parse failure is a programming error, not runtime
  // input (same pattern as AppStoreURL.swift).
  private enum Links {
    // Compile-time-constant HTTPS URL.
    // swiftlint:disable:next force_unwrapping
    static let coinstashHelp = URL(string:
      "https://help.coinstash.com.au/en/articles/13481155-how-do-i-use-the-coinstash-api")!
    // Compile-time-constant HTTPS URL.
    // swiftlint:disable:next force_unwrapping
    static let coinstashHome = URL(string: "https://coinstash.com.au")!
  }
}
```

> Verify the exact `force_unwrapping` rule id and disable-comment style against `.swiftlint.yml` + an existing precedent (`AppStoreURL.swift`); the reason line must precede the `disable` line per CODE_GUIDE §3.

- [ ] **Step 4: Add the stored property**

In `Account` struct (after `var chainId: Int?`):

```swift
  /// Provider for a centralised-exchange account. Required when
  /// `type == .exchange`; nil otherwise.
  var exchangeProvider: ExchangeProvider?
```

Add to the initialiser parameter list (after `chainId: Int? = nil`):

```swift
    exchangeProvider: ExchangeProvider? = nil
```

and in the body:

```swift
    self.exchangeProvider = exchangeProvider
```

`Account` has **custom** `Codable`, `Equatable`, and `Hashable` implementations (not synthesised) — `CodingKeys` alone is insufficient. Add `exchangeProvider` to **all four**:
- `enum CodingKeys`: `case exchangeProvider`
- `init(from:)`: `exchangeProvider = try container.decodeIfPresent(ExchangeProvider.self, forKey: .exchangeProvider)` (mirror how `chainId`/`walletAddress` are decoded — `decodeIfPresent` so older payloads round-trip nil)
- `encode(to:)`: `try container.encodeIfPresent(exchangeProvider, forKey: .exchangeProvider)` (mirror `chainId`)
- `static func == `: add `&& lhs.exchangeProvider == rhs.exchangeProvider`
- `func hash(into:)`: add `hasher.combine(exchangeProvider)`

Reconcile each against the real `Account.swift` custom-conformance bodies (the exact decode/encode/`==`/`hash` style for `walletAddress`/`chainId` is the template). Omitting `==`/`hash` makes two accounts differing only by provider compare equal — invisible to change detection / `Set<Account>`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `just test ExchangeAccountModelTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Bump the profile data-format version (forward-incompatibility gate)**

`.exchange` is a new case on the `// SyncBoundary —`-marked `AccountType` enum where older builds fall back unknown → `.asset` (rubric rule 3 in `Domain/Models/DataFormatVersion.swift`), and Task 3 adds the synced `exchangeProvider` field (rule 2). Both require bumping the gate so a profile that has been written by this build is fenced off from older builds (`SessionManager` flags `profile.dataFormatVersion > DataFormatVersion.current` as incompatible).

In `Domain/Models/DataFormatVersion.swift`:

```swift
enum DataFormatVersion {
  static let current: Int = 2
}
```

Prepend to the `History (newest first):` doc comment, above the `- 1:` entry:

```
/// - 2: `AccountType.exchange` (centralised-exchange accounts) +
///      `Account.exchangeProvider` synced field (`exchangeProvider` on
///      `AccountRecord`). Older builds decode `.exchange` as `.asset`
///      (defensive fallback) and drop the provider on round-trip; the
///      bump fences those downgrades off from this build forward.
```

Add an assertion to the existing model test:

```swift
@Test func dataFormatVersionBumpedForExchange() {
  // Pin the exact value at the point of the bump (a future bump updates
  // this deliberately, same as the golden-schema gate principle).
  #expect(DataFormatVersion.current == 2)
}
```

> The version-relative `DataFormatVersionBumpTests`/`DataFormatVersionTests` (`MoolahTests/App/`, `/Domain/`) reference `DataFormatVersion.current` rather than a literal, so they keep passing across the bump — run them to confirm.

- [ ] **Step 7: Run the version + bump tests**

Run: `just test ExchangeAccountModelTests` then `just test DataFormatVersion`
Expected: PASS (model tests incl. the new assertion; `DataFormatVersionTests` + `DataFormatVersionBumpTests` still green).

- [ ] **Step 8: Commit**

```bash
git add Domain/Models/Account.swift Domain/Models/ExchangeProvider.swift Domain/Models/DataFormatVersion.swift MoolahTests/Domain/ExchangeAccountModelTests.swift
git commit -m "feat: add AccountType.exchange + ExchangeProvider model; bump DataFormatVersion to 2"
```

---

### Task 2: GRDB migration v11 (widen CHECK + add `exchange_provider`)

**Files:**
- Create: `Backends/GRDB/ProfileSchema+ExchangeAccountFields.swift`
- Modify: `Backends/GRDB/ProfileSchema.swift` — register v11, bump `static let version = 10` → `11`, prepend the `v11_…` doc-comment history entry (lines 8–65 block)
- Modify: `Backends/GRDB/Records/AccountRow.swift` (column **and** `CodingKeys`), `Backends/GRDB/Records/AccountRow+Mapping.swift`
- Test: `MoolahTests/Backends/GRDB/ExchangeAccountMigrationTests.swift`

SQLite cannot ALTER a CHECK constraint, so v11 rebuilds `account` the same way v8 (`ProfileSchema+CryptoWalletFields.swift` → `rebuildAccountForCrypto`) does. The DDL below is the **exact** v8 `account` shape with `'exchange'` added to the type CHECK, `exchange_provider` added (with its own CHECK), and **all** existing constraints/indexes reproduced verbatim — do not hand-diff at execution time.

- [ ] **Step 1: Write the failing tests (happy path + rollback)**

```swift
import Testing
import GRDB
@testable import Moolah

// Synchronous `throws` + bound `Data(repeating:count:)` ids, matching every
// existing migration test in the project (CryptoWalletFieldsMigrationTests,
// AccountValuationModeMigrationTests, ProfileSchemaV10DropLegacyTests). Do
// NOT use `async throws`/`try await dbQueue.write` or inline `randomblob(16)`
// — both diverge from the settled convention; reconcile against a real
// neighbour test before writing.
struct ExchangeAccountMigrationTests {
  private let id = Data(repeating: 1, count: 16)   // 16-byte UUID-shaped blob

  // v1..v10-only migrator (a fresh DatabaseMigrator — `ProfileSchema.migrator`
  // includes v11 and cannot be truncated by assignment). Function names/ids
  // are verbatim from ProfileSchema.swift's registration list; reconcile if
  // they differ. Mirrors ProfileSchemaV10DropLegacyTests' partial-migrator.
  private func migratorThroughV10() -> DatabaseMigrator {
    var m = DatabaseMigrator()
    m.registerMigration("v1_initial", migrate: ProfileSchema.createInitialTables)
    m.registerMigration("v2_csv_import_and_rules",
      migrate: ProfileSchema.createCSVImportAndRulesTables)
    m.registerMigration("v3_core_financial_graph",
      migrate: ProfileSchema.createCoreFinancialGraphTables)
    m.registerMigration("v4_rate_cache_without_rowid",
      migrate: ProfileSchema.rebuildRateCacheMetaWithoutRowid)
    m.registerMigration("v5_drop_foreign_keys", migrate: ProfileSchema.dropForeignKeys)
    m.registerMigration("v6_account_valuation_mode",
      migrate: ProfileSchema.addAccountValuationMode)
    m.registerMigration("v7_purge_intraday_cached_prices",
      migrate: ProfileSchema.purgeIntradayCachedPrices)
    m.registerMigration("v8_add_crypto_wallet_fields",
      migrate: ProfileSchema.addCryptoWalletFields)
    m.registerMigration("v9_add_counterparty_address",
      migrate: ProfileSchema.addCounterpartyAddressToTransactionLeg)
    m.registerMigration("v10_drop_shared_instrument_legacy",
      migrate: ProfileSchema.dropSharedInstrumentLegacy)
    return m
  }

  @Test func v11AllowsExchangeTypeAndStoresProvider() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO account (id, record_name, name, type, instrument_id,
            position, is_hidden, valuation_mode, exchange_provider)
          VALUES (?, 'rec', 'Coinstash', 'exchange', 'AUD', 0, 0,
            'calculatedFromTrades', 'coinstash')
          """,
        arguments: [id])
    }
    let provider = try queue.read { db in
      try String.fetchOne(
        db, sql: "SELECT exchange_provider FROM account WHERE type = 'exchange'")
    }
    #expect(provider == "coinstash")
  }

  @Test func v11RejectsUnknownExchangeProvider() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    // Assert the SPECIFIC CHECK failure (matching CryptoWalletFieldsMigration
    // Tests' do/catch pattern), not just "any error".
    do {
      try queue.write { db in
        try db.execute(
          sql: """
            INSERT INTO account (id, record_name, name, type, instrument_id,
              position, is_hidden, valuation_mode, exchange_provider)
            VALUES (?, 'rec2', 'X', 'exchange', 'AUD', 0, 0,
              'calculatedFromTrades', 'not-a-provider')
            """,
          arguments: [Data(repeating: 2, count: 16)])
      }
      Issue.record("Expected CHECK constraint failure")
    } catch let error as DatabaseError {
      #expect(error.resultCode == .SQLITE_CONSTRAINT)
    }
  }

  @Test func v11RollsBackOnFailureLeavingSchemaIntact() throws {
    let queue = try DatabaseQueue()
    try migratorThroughV10().migrate(queue)
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO account (id, record_name, name, type, instrument_id,
            position, is_hidden, valuation_mode)
          VALUES (?, 'keep', 'Keep', 'bank', 'AUD', 0, 0, 'recordedValue')
          """,
        arguments: [id])
    }
    // GRDB wraps the closure in one BEGIN/ROLLBACK txn; a throw after the
    // multi-statement DDL must roll the whole rebuild back.
    #expect(throws: (any Error).self) {
      try queue.write { db in
        try ProfileSchema.addExchangeAccountFields(db)
        throw CancellationError()
      }
    }
    try queue.read { db in
      // Row + original schema survive; intermediate table and new column gone.
      #expect(try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM account WHERE record_name = 'keep'") == 1)
      #expect(try Bool.fetchOne(
        db, sql: "SELECT 1 FROM sqlite_master WHERE name = 'account_new'") == nil)
      #expect(!(try db.columns(in: "account").map(\.name).contains("exchange_provider")))
    }
  }
}
```

> The `migratorThroughV10()` helper above hand-registers v1..v10 (there is **no** `ProfileSchema.migratorThroughV10` accessor — do not reference one). Reconcile each `registerMigration` id + function name against the real `ProfileSchema.swift` registration list and `ProfileSchemaV10DropLegacyTests`' partial-migrator (it builds through v9; extend by one). Variable is `queue` (not `dbQueue`) and tests are synchronous `throws` — both match every existing migration test. The reject test asserts `DatabaseError.resultCode == .SQLITE_CONSTRAINT` (not "any error"). **Task ordering:** Task 2 depends on Task 1 (`Account.exchangeProvider` + `ExchangeProvider` must exist before `AccountRow+Mapping.toDomain` compiles) — keep the phase order.

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test ExchangeAccountMigrationTests`
Expected: FAIL — CHECK rejects `'exchange'` / no `exchange_provider` column / `addExchangeAccountFields` undefined.

- [ ] **Step 3: Write the migration (exact v8 shape + exchange additions)**

Create `Backends/GRDB/ProfileSchema+ExchangeAccountFields.swift`. This DDL is the verbatim v8 `account_new` definition (`ProfileSchema+CryptoWalletFields.swift` → `rebuildAccountForCrypto`) with three additions only: `'exchange'` in the type CHECK, the `exchange_provider` column **with its own CHECK**, and that column carried through nowhere in the `INSERT … SELECT` (it defaults NULL for existing rows). `STRICT`, `record_name … UNIQUE`, `CHECK (position >= 0)`, `CHECK (is_hidden IN (0, 1))`, the `valuation_mode` CHECK, column order, and **both** index recreations are reproduced exactly.

```swift
import Foundation
import GRDB

extension ProfileSchema {
  /// v11 migration body. Rebuilds `account` to widen the `type` CHECK to
  /// include `'exchange'` and add the nullable `exchange_provider` column
  /// (CHECK-pinned to the `ExchangeProvider` raw values). SQLite cannot
  /// alter a CHECK in place — same table-rebuild pattern as v5/v8.
  ///
  /// Retention: an `.exchange` account's read-only token lives only in the
  /// keychain (`ExchangeTokenStore`), never in this table. `AccountRepository`
  /// delete must also clear that keychain entry and the `wallet_sync_state`
  /// row (see Task 12 final-verification item).
  static func addExchangeAccountFields(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE account_new (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            name                   TEXT    NOT NULL,
            type                   TEXT    NOT NULL
                CHECK (type IN ('bank', 'cc', 'asset', 'investment', 'crypto', 'exchange')),
            instrument_id          TEXT    NOT NULL,
            position               INTEGER NOT NULL CHECK (position >= 0),
            is_hidden              INTEGER NOT NULL CHECK (is_hidden IN (0, 1)),
            valuation_mode         TEXT    NOT NULL DEFAULT 'recordedValue'
                CHECK (valuation_mode IN ('recordedValue', 'calculatedFromTrades')),
            wallet_address         TEXT,
            chain_id               INTEGER,
            exchange_provider      TEXT
                CHECK (exchange_provider IS NULL OR exchange_provider IN ('coinstash')),
            encoded_system_fields  BLOB
        ) STRICT;

        INSERT INTO account_new
          (id, record_name, name, type, instrument_id, position, is_hidden,
           valuation_mode, wallet_address, chain_id, encoded_system_fields)
        SELECT
          id, record_name, name, type, instrument_id, position, is_hidden,
          valuation_mode, wallet_address, chain_id, encoded_system_fields
        FROM account;

        DROP TABLE account;
        ALTER TABLE account_new RENAME TO account;

        CREATE INDEX account_by_position ON account(position);
        CREATE INDEX account_by_type     ON account(type);
        """)
  }
}
```

> Verification (not remediation): diff this `account_new` block against `ProfileSchema+CryptoWalletFields.swift`'s `rebuildAccountForCrypto`. The only permitted differences are the added `'exchange'` CHECK value, the `exchange_provider` column + its CHECK, and (deliberately) carrying `wallet_address`/`chain_id` through the `SELECT` (v8 wrote NULL because it was *introducing* those columns; v11 must preserve existing values). A future provider widens the `exchange_provider` CHECK in its own migration.

- [ ] **Step 4: Register the migration + bump version + doc header**

In `Backends/GRDB/ProfileSchema.swift`:

1. After the v10 `registerMigration` line:

```swift
    migrator.registerMigration(
      "v11_add_exchange_account_fields", migrate: addExchangeAccountFields)
```

2. Bump the version constant:

```swift
  static let version = 11   // was 10
```

3. Prepend a `v11_add_exchange_account_fields` entry to the migration-history doc comment (the `///` block, lines ~8–65), matching the existing per-migration one-line style, e.g.:

```
/// `v11_add_exchange_account_fields` — rebuilds `account` to widen the
/// type CHECK to include `'exchange'` and adds the CHECK-pinned
/// `exchange_provider` column. See `ProfileSchema+ExchangeAccountFields.swift`.
```

- [ ] **Step 5: Add the GRDB column, `CodingKeys`, and mapping (both directions)**

`AccountRow.swift`:
- `enum Columns` — add after `case chainId = "chain_id"`: `case exchangeProvider = "exchange_provider"`
- `enum CodingKeys` — add the matching `case exchangeProvider = "exchange_provider"` (GRDB Codable decoding ignores columns absent from `CodingKeys`; the existing file keeps `Columns` and `CodingKeys` in lock-step — verify both enums)
- add the stored `var exchangeProvider: String?` property mirroring the exact declaration style of `walletAddress`/`chainId`, and add `exchangeProvider` to `AccountRow.init` in the same relative position.

`AccountRow+Mapping.swift`:
- `init(domain:)` (from-domain): add `exchangeProvider: domain.exchangeProvider?.rawValue,`
- `toDomain` (to-domain): bind the row value and pass it through, e.g. add `let exchangeProvider = self.exchangeProvider` near the other local bindings and `exchangeProvider: exchangeProvider.flatMap(ExchangeProvider.init(rawValue:)),` to the `Account(...)` construction. (`toDomain` currently has no `exchangeProvider` binding — add it; don't assume one exists.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `just test ExchangeAccountMigrationTests`
Expected: PASS (3 tests incl. rollback + unknown-provider rejection).
Then: `just test GRDB`
Expected: PASS (migration-order + plan-pin tests green).
Also explicitly confirm `ProfileSchemaV10DropLegacyTests.fullMigrationSchemaIsGolden` still passes — it enumerates the exact post-migrator table/index set. v11 adds no new table or named index (it rebuilds `account` in place and recreates the same two indexes), so the expected sets need **no** update; this is a confirmation-only step (and a guard that the rebuild didn't accidentally drop/rename an index).

- [ ] **Step 7: Add the leg-dedup plan-pin test (unconditional)**

The exchange sync path reuses `WalletApplyEngine`'s dedup. The existing `CrossDeviceLegDeduperPlanPinningTests` pins the **`external_id IN (?)`** shape (the `transactions(touchingExternalIds:)` skip-scan) — it does **not** cover the `WHERE account_id = ? AND external_id = ?` two-column-equality shape used by `legExists(accountId:externalId:)` in `WalletApplyEngine.survivingLegs(for:)`, which runs once per candidate leg on every sync cycle. This is a real gap (independent of this feature, but the exchange path multiplies its call volume). **Add the test below regardless of what the grep finds** (the prior "if present, no action" guidance was wrong — the existing test covers a different query shape):

Use the project's shared plan-pin helpers (NOT a hand-rolled `EXPLAIN` with `$0[3]` positional access — every existing plan-pin test goes through `PlanPinningTestHelpers`, which reads the `"detail"` named column and provides `planHasFullTableScanOf` to avoid the `SCAN ... USING INDEX` false-negative). Mirror `CrossDeviceLegDeduperPlanPinningTests.touchedExternalIdLookupUsesPartialIndex` exactly:

```swift
@Test func legDedupByAccountExternalUsesIndex() throws {
  let database = try PlanPinningTestHelpers.makeDatabase()
  let detail = try PlanPinningTestHelpers.planDetail(
    database,
    query: """
      SELECT id FROM transaction_leg
      WHERE account_id = ? AND external_id = ?
      """,
    arguments: [Data(repeating: 1, count: 16), "0xabc"])
  #expect(detail.contains("leg_dedup_by_account_external"))
  #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(
    detail, alias: "transaction_leg"))
}
```

Reconcile `PlanPinningTestHelpers.makeDatabase()` / `planDetail(_:query:arguments:)` / `planHasFullTableScanOf(_:alias:)` signatures against the real `MoolahTests/Backends/GRDB/PlanPinningTestHelpers.swift`. This pins the `legExists(accountId:externalId:)` two-column-equality shape (`GRDBTransactionRepository+ExternalIdLookup.swift`) which the existing `external_id IN (?)` test does NOT cover.

- [ ] **Step 8: Commit**

```bash
git add Backends/GRDB/ProfileSchema+ExchangeAccountFields.swift Backends/GRDB/ProfileSchema.swift Backends/GRDB/Records/AccountRow.swift Backends/GRDB/Records/AccountRow+Mapping.swift MoolahTests/Backends/GRDB/ExchangeAccountMigrationTests.swift
git commit -m "feat: GRDB v11 migration for exchange accounts (version 11)"
```

---

### Task 3: CloudKit field + safe-type allowlist

**REQUIRED SUB-SKILL:** Use the `modifying-cloudkit-schema` skill for this task — it owns `CloudKit/schema.ckdb`, `cktool`, and the generated wire structs. Do not hand-edit the generated file without it.

**Files:**
- Modify: `CloudKit/schema.ckdb:3-21` (AccountRecord)
- Modify: `Backends/CloudKit/Sync/Generated/AccountRecordCloudKitFields.swift` (via skill)
- Modify: `Backends/GRDB/Sync/AccountRow+CloudKit.swift:28,42,61-71`
- Test: `MoolahTests/Backends/CloudKit/ExchangeAccountCloudKitTests.swift`

The new account *type value* `"exchange"` needs **no** ckdb change (the `type` field is already `STRING`). Only the new `exchangeProvider` field requires a schema change, and the safe-type allowlist must learn `"exchange"`.

- [ ] **Step 1: Write the failing tests (allowlist + encode/decode round-trip)**

```swift
import Testing
import CloudKit
@testable import Moolah

struct ExchangeAccountCloudKitTests {
  @Test func exchangeTypeSurvivesRoundTrip() {
    #expect(AccountRow.safeAccountTypeRaw("exchange") == "exchange")
  }

  @Test func unknownTypeStillFallsBackToAsset() {
    #expect(AccountRow.safeAccountTypeRaw("nonsense") == "asset")
  }

  // A CloudKit round-trip must preserve exchangeProvider, or a second
  // device would decode it nil and CoinstashSyncSource would throw
  // .missingApiKey for an account it didn't create.
  @Test func exchangeProviderSurvivesCloudKitRoundTrip() throws {
    let row = AccountRow(
      /* reconcile arg order with the real AccountRow.init */
      id: UUID(), recordName: "rec", name: "Coinstash", type: "exchange",
      instrumentId: "AUD", position: 0, isHidden: false,
      valuationMode: "calculatedFromTrades", walletAddress: nil,
      chainId: nil, exchangeProvider: "coinstash", encodedSystemFields: nil)
    let zoneID = CKRecordZone.ID(
      zoneName: "test", ownerName: CKCurrentUserDefaultName)
    let restored = AccountRow.fieldValues(from: row.toCKRecord(in: zoneID))
    #expect(restored?.exchangeProvider == "coinstash")
  }

  @Test func unknownFutureProviderPassesThroughRaw() throws {
    let row = AccountRow(
      id: UUID(), recordName: "r2", name: "X", type: "exchange",
      instrumentId: "AUD", position: 0, isHidden: false,
      valuationMode: "calculatedFromTrades", walletAddress: nil,
      chainId: nil, exchangeProvider: "future-exchange", encodedSystemFields: nil)
    let zoneID = CKRecordZone.ID(
      zoneName: "test", ownerName: CKCurrentUserDefaultName)
    let restored = AccountRow.fieldValues(from: row.toCKRecord(in: zoneID))
    // Raw String passes through at the row layer; the domain layer maps an
    // unknown raw value to exchangeProvider == nil (ExchangeProvider(rawValue:)).
    #expect(restored?.exchangeProvider == "future-exchange")
  }

  // Explicit encode-direction guard: the CKRecord produced by toCKRecord
  // must carry the field (cheap, unambiguous; complements the round-trip).
  @Test func toCKRecordEncodesExchangeProvider() throws {
    let row = AccountRow(
      id: UUID(), recordName: "r3", name: "C", type: "exchange",
      instrumentId: "AUD", position: 0, isHidden: false,
      valuationMode: "calculatedFromTrades", walletAddress: nil,
      chainId: nil, exchangeProvider: "coinstash", encodedSystemFields: nil)
    let zoneID = CKRecordZone.ID(
      zoneName: "test", ownerName: CKCurrentUserDefaultName)
    let record = row.toCKRecord(in: zoneID)
    #expect(record["exchangeProvider"] as? String == "coinstash")
  }
}
```

> Reconcile `AccountRow.init` argument order and the exact `toCKRecord`/`fieldValues(from:)` signatures with the real `AccountRow+CloudKit.swift`. Confirm `safeAccountTypeRaw` visibility; if `private`, lift to `internal` (internal-only logic, no API concern).

- [ ] **Step 2: Run test to verify it fails**

Run: `just test ExchangeAccountCloudKitTests`
Expected: `exchangeTypeSurvivesRoundTrip` FAILS (returns `"asset"`).

- [ ] **Step 3: Extend the safe allowlist**

In `AccountRow+CloudKit.swift:61-71`, add `"exchange"` to the known-types set used by `safeAccountTypeRaw` (it currently lists `["bank","cc","asset","investment","crypto"]`).

- [ ] **Step 4: Add `exchangeProvider` to CloudKit (via skill)**

Invoke `modifying-cloudkit-schema`. Add `exchangeProvider` to `CloudKit/schema.ckdb` `RECORD TYPE AccountRecord` **between `chainId` and `instrumentId`** (fields are alphabetically ordered). **Mandatory:** open the real `schema.ckdb`, find the `walletAddress` line, and copy its attribute set **character-for-character** (it is `STRING QUERYABLE SEARCHABLE SORTABLE`). Do **not** copy the alphabetically-adjacent `chainId` line — it is `INT64 QUERYABLE SORTABLE` (no `SEARCHABLE`); `exchangeProvider` is a `STRING` and must carry `SEARCHABLE` like every other string field. A narrower set is a silent schema deficiency the round-trip test will not catch:

```
    exchangeProvider  STRING QUERYABLE SEARCHABLE SORTABLE,
```

Let the skill regenerate `AccountRecordCloudKitFields.swift`. Then wire **both** directions in `AccountRow+CloudKit.swift` by splicing `exchangeProvider` into the existing `AccountRecordCloudKitFields(...)` call in `toCKRecord` and the `AccountRow(...)` call in `fieldValues(from:)`, in the same relative position as `walletAddress`/`chainId`.

> Do NOT add an `encodedSystemFields`/cached-`CKRecord` path to `toCKRecord`. By design `toCKRecord` returns a fresh `CKRecord`; system-field (change-tag) preservation is handled one layer up by `ProfileDataSyncHandler.buildCKRecord` (it rebuilds from cached `encodedSystemFields` and copies fresh field values on). Adding it inside `toCKRecord` would double-handle and break that contract. The illustrative blocks below match the real file's shape (`chainId: chainId.map(Int64.init)`, `isHidden ? 1 : 0`, etc.) — reconcile arg order/transforms against the real `AccountRow+CloudKit.swift`; the only change is the added `exchangeProvider`:

```swift
// toCKRecord(...) — the AccountRecordCloudKitFields(...) construction:
let fields = AccountRecordCloudKitFields(
  chainId: chainId,
  exchangeProvider: exchangeProvider,        // NEW (raw String?)
  instrumentId: instrumentId,
  isHidden: isHidden,
  name: name,
  position: position,
  type: type,
  valuationMode: valuationMode,
  walletAddress: walletAddress)
// … rest of toCKRecord unchanged …

// fieldValues(from:) — the AccountRow(...) construction:
return AccountRow(
  id: …,
  recordName: …,
  name: fields.name,
  type: Self.safeAccountTypeRaw(fields.type ?? "bank"),
  instrumentId: …,
  position: …,
  isHidden: …,
  valuationMode: …,
  walletAddress: fields.walletAddress,
  chainId: fields.chainId,
  exchangeProvider: fields.exchangeProvider, // NEW (raw String?, no mapping)
  encodedSystemFields: …)
```

> The argument labels/order above are illustrative — reconcile against the **real** `AccountRecordCloudKitFields.init` and `AccountRow.init` (the generated struct's parameters are alphabetical; `AccountRow.init` order is whatever Task 2 established). The point is: both the encode `AccountRecordCloudKitFields(...)` and the decode `AccountRow(...)` calls must list `exchangeProvider`. The Step-1 round-trip test fails if either is omitted; the explicit `toCKRecordEncodesExchangeProvider` test pins the encode side specifically.

- [ ] **Step 5: Verify schema is additive AND the attribute set is correct**

Run: `just check-schema-additive`
Expected: PASS (new field is additive; no removed/retyped fields).

`check-schema-additive` does **not** verify index attributes — a too-narrow set (e.g. accidentally copying `chainId`'s `INT64 QUERYABLE SORTABLE`) passes it but is a silent prod deficiency. Add this gate (CI step or manual, before Step 6):

```bash
grep -E '^\s*exchangeProvider\s' CloudKit/schema.ckdb \
  | grep -q 'STRING' \
  && grep -E '^\s*exchangeProvider\s' CloudKit/schema.ckdb | grep -q 'QUERYABLE' \
  && grep -E '^\s*exchangeProvider\s' CloudKit/schema.ckdb | grep -q 'SEARCHABLE' \
  && grep -E '^\s*exchangeProvider\s' CloudKit/schema.ckdb | grep -q 'SORTABLE' \
  || { echo 'exchangeProvider must be STRING QUERYABLE SEARCHABLE SORTABLE'; exit 1; }
```

- [ ] **Step 6: Run tests**

Run: `just test ExchangeAccountCloudKitTests` then `just test CloudKit`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add CloudKit/schema.ckdb Backends/CloudKit/Sync/Generated/AccountRecordCloudKitFields.swift Backends/GRDB/Sync/AccountRow+CloudKit.swift MoolahTests/Backends/CloudKit/ExchangeAccountCloudKitTests.swift
git commit -m "feat: CloudKit exchangeProvider field + exchange type allowlist"
```

**Phase 1 checkpoint:** `just build-mac` is green; `.exchange` accounts persist locally and round-trip through CloudKit mapping. No UI/sync yet.

---

## Phase 2 — Per-account credential storage

### Task 4: `ExchangeTokenStore`

**Files:**
- Create: `Shared/Exchange/ExchangeTokenStore.swift`
- Test: `MoolahTests/Shared/Exchange/ExchangeTokenStoreTests.swift`

Mirrors the Alchemy keychain pattern (`KeychainStore(service: KeychainServices.apiKeys, account: ..., synchronizable: true)`) but **keys the keychain account string by the Moolah account UUID** so each exchange account has its own token. This is the codebase's first dynamically-keyed keychain entry — intentional.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import Moolah

struct ExchangeTokenStoreTests {
  @Test func saveReadDeleteRoundTrip() throws {
    let id = UUID()
    // Non-synchronizable in tests: CI cannot write the iCloud keychain
    // (mirrors CryptoTokenStore's test wiring).
    let store = ExchangeTokenStore(synchronizable: false)
    try store.save(token: "TOKEN123", for: id)
    #expect(try store.token(for: id) == "TOKEN123")
    store.delete(for: id)
    #expect(try store.token(for: id) == nil)
  }

  @Test func tokensAreIsolatedPerAccount() throws {
    let store = ExchangeTokenStore(synchronizable: false)
    let a = UUID(); let b = UUID()
    try store.save(token: "A", for: a)
    try store.save(token: "B", for: b)
    #expect(try store.token(for: a) == "A")
    #expect(try store.token(for: b) == "B")
    store.delete(for: a); store.delete(for: b)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test ExchangeTokenStoreTests`
Expected: FAIL — `ExchangeTokenStore` undefined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Per-account keychain storage for an exchange account's read-only access
/// token. Each Moolah account gets its own keychain row keyed by account id,
/// in the same env-scoped `apiKeys` service the Alchemy/CoinGecko keys use.
/// Production uses the iCloud-synced keychain so the token follows the user
/// across devices (the token is a secret and must never enter the DB/CloudKit).
struct ExchangeTokenStore: Sendable {
  private let synchronizable: Bool

  init(synchronizable: Bool = true) {
    self.synchronizable = synchronizable
  }

  private func store(for accountId: UUID) -> KeychainStore {
    KeychainStore(
      service: KeychainServices.apiKeys,
      account: "exchange-token-\(accountId.uuidString)",
      synchronizable: synchronizable)
  }

  func save(token: String, for accountId: UUID) throws {
    try store(for: accountId).saveString(token)
  }

  func token(for accountId: UUID) throws -> String? {
    try store(for: accountId).restoreString()
  }

  func delete(for accountId: UUID) {
    store(for: accountId).clear()
  }
}
```

- [ ] **Step 4: Run tests**

Run: `just test ExchangeTokenStoreTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Shared/Exchange/ExchangeTokenStore.swift MoolahTests/Shared/Exchange/ExchangeTokenStoreTests.swift
git commit -m "feat: per-account exchange token keychain store"
```

---

## Phase 3 — Coinstash GraphQL client

### Task 5: GraphQL models + query strings

**Files:**
- Create: `Shared/Exchange/CoinstashGraphQL.swift`
- Test: `MoolahTests/Shared/Exchange/CoinstashGraphQLTests.swift`

- [ ] **Step 1: Write the failing test (decode a captured response)**

```swift
import Testing
import Foundation
@testable import Moolah

struct CoinstashGraphQLTests {
  @Test func decodesTransactionsPage() throws {
    let json = """
    {"data":{"accountTransactions":{"isSuccessful":true,
      "totalRecordsFound":2,"result":[
      {"transactionId":"t1","transactedOn":"2026-03-01T05:38:19.186Z",
       "category":"TRADE","type":"CREDIT","assetSymbol":"OP",
       "amount":3518.46,"amountType":"FIAT","orderId":"o1",
       "orderType":"SELL","transactionStatus":"COMPLETED"},
      {"transactionId":"t2","transactedOn":"2026-03-01T05:38:19.186Z",
       "category":"TRADEFEE","type":"DEBIT","assetSymbol":"OP",
       "amount":21.11,"amountType":"FIAT","orderId":"o1",
       "orderType":"SELL","transactionStatus":"COMPLETED"}]}}}
    """.data(using: .utf8)!
    let resp = try JSONDecoder().decode(
      CoinstashGraphQLResponse<CoinstashTransactionsData>.self, from: json)
    let page = try #require(resp.data?.accountTransactions)
    #expect(page.totalRecordsFound == 2)
    #expect(page.result.count == 2)
    #expect(page.result[0].transactionId == "t1")
    #expect(page.result[0].orderId == "o1")
    // Exact-value assertions: prove the Decimal type annotation actually
    // prevents Double-precision corruption (3518.46 → 3518.4599999999998
    // if amount were Double). Decimal(string:) — NOT Decimal(3518.46),
    // which would round-trip through Double and defeat the test.
    #expect(page.result[0].amount == Decimal(string: "3518.46"))
    #expect(page.result[1].amount == Decimal(string: "21.11"))
  }

  @Test func surfacesGraphQLErrors() throws {
    let json = """
    {"errors":[{"message":"Unauthorized"}]}
    """.data(using: .utf8)!
    let resp = try JSONDecoder().decode(
      CoinstashGraphQLResponse<CoinstashTransactionsData>.self, from: json)
    #expect(resp.data == nil)
    #expect(resp.errors?.first?.message == "Unauthorized")
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test CoinstashGraphQLTests`
Expected: FAIL — types undefined.

- [ ] **Step 3: Implement models + queries**

```swift
import Foundation

enum CoinstashGraphQL {
  // Compile-time-constant HTTPS URL: parse failure is a programming error.
  // swiftlint:disable:next force_unwrapping
  static let endpoint = URL(string: "https://graph.coinstash.com.au/graphql")!

  static let userProfileQuery = """
  query { userProfile { userId } }
  """

  static let userAccountsQuery = """
  query Q($userId: ID!) {
    getUserAccounts(userId: $userId) { accounts { accountId accountType } }
  }
  """

  static let transactionsQuery = """
  query Q($a: ID!, $p: SearchAccountTransactionsPayloadInput) {
    accountTransactions(accountId: $a, searchAccountTransactionsPayloadInput: $p) {
      isSuccessful errorMessage totalRecordsFound
      result { transactionId transactedOn category type assetSymbol
               amount amountType quoteBuyPrice quoteSellPrice
               orderId orderType transactionStatus }
    }
  }
  """
}

struct CoinstashGraphQLError: Decodable, Sendable { let message: String }

struct CoinstashGraphQLResponse<T: Decodable & Sendable>: Decodable, Sendable {
  let data: T?
  let errors: [CoinstashGraphQLError]?
}

struct CoinstashUserProfileData: Decodable, Sendable {
  struct Profile: Decodable, Sendable { let userId: String }
  let userProfile: Profile
}

// Types nested at most one level (SwiftLint `nesting` = 1).
struct CoinstashUserAccountsData: Decodable, Sendable {
  struct AccountSummary: Decodable, Sendable {
    let accountId: String
    let accountType: String
  }
  struct GetUserAccountsResult: Decodable, Sendable {
    let accounts: [AccountSummary]
  }
  let getUserAccounts: GetUserAccountsResult
}

struct CoinstashTransaction: Decodable, Sendable, Hashable {
  let transactionId: String
  let transactedOn: String
  let category: String
  let type: String
  let assetSymbol: String?
  // Decimal (not Double): JSONDecoder decodes a bare JSON number into
  // Decimal losslessly. Double would corrupt amounts (3518.46 →
  // 3518.4599999999998) before they ever reach a TransactionLeg.
  let amount: Decimal
  let amountType: String
  let quoteBuyPrice: Decimal?
  let quoteSellPrice: Decimal?
  let orderId: String?
  let orderType: String?
  let transactionStatus: String
}

struct CoinstashTransactionsData: Decodable, Sendable {
  struct Page: Decodable, Sendable {
    let isSuccessful: Bool
    let errorMessage: String?
    let totalRecordsFound: Int
    let result: [CoinstashTransaction]
  }
  let accountTransactions: Page
}
```

- [ ] **Step 4: Run tests**

Run: `just test CoinstashGraphQLTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Shared/Exchange/CoinstashGraphQL.swift MoolahTests/Shared/Exchange/CoinstashGraphQLTests.swift
git commit -m "feat: Coinstash GraphQL query + response models"
```

---

### Task 6: `ExchangeClient` protocol + `CoinstashClient`

**Files:**
- Create: `Shared/Exchange/ExchangeClient.swift` (protocol), `ExchangeClientError.swift`, `ExchangeDirection.swift`, `ExchangeImportedTransaction.swift`
- Create: `Shared/Exchange/CoinstashClient.swift`
- Test: `MoolahTests/Shared/Exchange/CoinstashClientTests.swift`

`CoinstashClient` performs the 3-step flow and paginates. The HTTP layer is injected (a `(URLRequest) async throws -> (Data, URLResponse)` closure) so tests run offline. Conforms to `Sendable`; no mutable state (matches `LiveAlchemyClient`).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import Moolah

struct CoinstashClientTests {
  @Test func fetchesAllPagesAndReturnsTransactions() async throws {
    let profile = #"{"data":{"userProfile":{"userId":"u1"}}}"#
    let accounts = #"{"data":{"getUserAccounts":{"accounts":[{"accountId":"a1","accountType":"TRADING"}]}}}"#
    let page = #"{"data":{"accountTransactions":{"isSuccessful":true,"totalRecordsFound":1,"result":[{"transactionId":"t1","transactedOn":"2026-03-01T05:38:19.186Z","category":"DEPOSIT","type":"CREDIT","assetSymbol":null,"amount":100.0,"amountType":"FIAT","quoteBuyPrice":null,"quoteSellPrice":null,"orderId":null,"orderType":null,"transactionStatus":"COMPLETED"}]}}}"#
    var bodies: [String] = []
    let client = CoinstashClient(transport: { req in
      let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
      bodies.append(body)
      let json: String
      if body.contains("userProfile") { json = profile }
      else if body.contains("getUserAccounts") { json = accounts }
      else { json = page }
      let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
        httpVersion: nil, headerFields: nil)!
      return (json.data(using: .utf8)!, resp)
    })
    let txns = try await client.fetchTransactions(token: "TOK")
    #expect(txns.count == 1)
    #expect(txns[0].transactionId == "t1")
    // Bearer token forwarded
    #expect(bodies.count == 3)
  }

  @Test func mapsUnauthorizedToError() async throws {
    let client = CoinstashClient(transport: { req in
      let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
        httpVersion: nil, headerFields: nil)!
      return (#"{"errors":[{"message":"Unauthorized"}]}"#.data(using: .utf8)!, resp)
    })
    await #expect(throws: ExchangeClientError.self) {
      _ = try await client.fetchTransactions(token: "BAD")
    }
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test CoinstashClientTests`
Expected: FAIL — undefined types.

- [ ] **Step 3: Define the protocol + error + DTO (one primary type per file)**

Split into four files — the project keeps a protocol, its error, and its DTOs in separate files (precedent: `AlchemyClient.swift` is the protocol only; `AlchemyTransfer.swift`, `TransferDirection.swift` are separate). Create: `Shared/Exchange/ExchangeClientError.swift` (the error enum), `Shared/Exchange/ExchangeDirection.swift` (the direction enum), `Shared/Exchange/ExchangeImportedTransaction.swift` (the DTO), `Shared/Exchange/ExchangeClient.swift` (the protocol only). The combined listing below is shown together for readability — place each type in its named file:

```swift
import Foundation

enum ExchangeClientError: Error, Sendable, Equatable {
  case unauthorized
  case rateLimited(retryAfter: Date?)
  case http(Int)
  case malformedResponse
  case providerError(String)
}

/// Credit/debit sign for an imported leg. A closed enum (not a bare Int)
/// so an unrecognised provider value is a compile-time impossibility, not
/// a silent zero-quantity leg.
enum ExchangeDirection: Int, Sendable, Hashable {
  case credit = 1
  case debit = -1

  /// Sign multiplier for `Decimal` quantity math — keeps the `Int` backing
  /// out of business-logic call sites (`direction.multiplier * amount`).
  var multiplier: Decimal {
    switch self {
    case .credit: return 1
    case .debit: return -1
    }
  }
}

/// One imported exchange transaction in provider-neutral form. Phase 4 maps
/// these into `Transaction`/`TransactionLeg` candidates.
struct ExchangeImportedTransaction: Sendable, Hashable {
  let externalId: String
  let occurredAt: Date
  let category: String      // TRADE | TRADEFEE | DEPOSIT | WITHDRAW | AWARD
  let direction: ExchangeDirection
  let assetSymbol: String?
  let amount: Decimal
  let isFiat: Bool
  let orderId: String?
}

protocol ExchangeClient: Sendable {
  func fetchTransactions(token: String) async throws -> [ExchangeImportedTransaction]
}
```

- [ ] **Step 4: Implement `CoinstashClient`**

`Shared/Exchange/CoinstashClient.swift`:

First resolve `JSONValue`. **Mandatory step (not conditional):** grep the module for `enum JSONValue`. If it exists, reuse it. If it does not, create it in its own file `Shared/Exchange/JSONValue.swift` (one primary type per file — do not inline it in `CoinstashClient.swift`):

`Shared/Exchange/JSONValue.swift` (only if grep finds none):

```swift
import Foundation

/// Minimal JSON value for encoding GraphQL request bodies / variables.
indirect enum JSONValue: Codable, Sendable {
  case string(String), int(Int), double(Double), bool(Bool)
  case object([String: JSONValue]), array([JSONValue]), null

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let v): try c.encode(v)
    case .int(let v): try c.encode(v)
    case .double(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .null: try c.encodeNil()
    }
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null; return }
    // Deliberate type-probe: a SingleValueDecodingContainer cannot be
    // inspected without attempting a decode, so `try?` here is the
    // intended control flow, not a swallowed error.
    if let v = try? c.decode(Bool.self) { self = .bool(v); return }
    if let v = try? c.decode(Int.self) { self = .int(v); return }
    if let v = try? c.decode(Double.self) { self = .double(v); return }
    if let v = try? c.decode(String.self) { self = .string(v); return }
    if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
    if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
    self = .null
  }
}
```

> The project's `.swiftlint.yml` has no `try?`/`optional_try` rule (only `force_try` for `try!`), so these `try?` probes need **no** SwiftLint suppression. Keep the in-code explanatory comment (already present) documenting the deliberate type-probe; do **not** add a `swiftlint:disable` for a non-existent rule (that would itself trip `superfluous_disable_command`). If `just format-check` ever flags this after a future rule addition, address it then.

`Shared/Exchange/CoinstashClient.swift`:

```swift
import Foundation
import OSLog

struct CoinstashClient: ExchangeClient, Sendable {
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
  private let transport: Transport
  private static let pageSize = 100   // compile-time constant, not per-instance
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "CoinstashClient")

  init(transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
    self.transport = transport
  }

  func fetchTransactions(token: String) async throws -> [ExchangeImportedTransaction] {
    let userId = try await query(
      CoinstashGraphQL.userProfileQuery, variables: nil,
      token: token, as: CoinstashUserProfileData.self).userProfile.userId
    try Task.checkCancellation()

    let accounts = try await query(
      CoinstashGraphQL.userAccountsQuery, variables: ["userId": .string(userId)],
      token: token, as: CoinstashUserAccountsData.self).getUserAccounts.accounts
    try Task.checkCancellation()
    if accounts.count > 1 {
      // v1 imports the first account only. Log so a multi-account user
      // report is diagnosable; revisit if this is hit in practice.
      Self.logger.warning(
        "Coinstash returned \(accounts.count) accounts; importing the first only")
    }
    guard let accountId = accounts.first?.accountId else { return [] }

    var all: [CoinstashTransaction] = []
    var pageIndex = 0
    while true {
      try Task.checkCancellation()
      let page = try await query(
        CoinstashGraphQL.transactionsQuery,
        variables: ["a": .string(accountId),
                    "p": .object(["pageIndex": .int(pageIndex),
                                  "pageSize": .int(Self.pageSize)])],
        token: token, as: CoinstashTransactionsData.self).accountTransactions
      all.append(contentsOf: page.result)
      if all.count >= page.totalRecordsFound || page.result.isEmpty { break }
      pageIndex += 1
    }
    return all.compactMap(Self.map(_:))
  }

  // MARK: - Mapping

  static func map(_ t: CoinstashTransaction) -> ExchangeImportedTransaction? {
    guard t.transactionStatus == "COMPLETED" else { return nil }
    // Stack-allocated formatter — ISO8601DateFormatter (an NSObject
    // subclass) is not safe to share across the concurrent build tasks.
    // Do NOT promote this to a static/shared `let`: it is not Sendable
    // and is mutated (formatOptions) before use.
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    // Drop (don't .distantPast) an unparseable required date — a sentinel
    // year-0001 row would sort to the top of the user's history.
    guard let occurredAt = formatter.date(from: t.transactedOn) else {
      Self.logger.warning(
        "Dropping tx \(t.transactionId, privacy: .public): unparseable date '\(t.transactedOn, privacy: .public)'")
      return nil
    }
    // Closed mapping — an unrecognised `type` is dropped+logged, never
    // silently signed as a debit.
    let direction: ExchangeDirection
    switch t.type {
    case "CREDIT": direction = .credit
    case "DEBIT": direction = .debit
    default:
      Self.logger.warning(
        "Dropping tx \(t.transactionId, privacy: .public): unrecognised type '\(t.type, privacy: .public)'")
      return nil
    }
    return ExchangeImportedTransaction(
      externalId: t.transactionId,
      occurredAt: occurredAt,
      category: t.category,
      direction: direction,
      assetSymbol: t.assetSymbol,
      amount: t.amount,                       // already Decimal — exact
      isFiat: t.amountType == "FIAT",
      orderId: t.orderId)
  }

  // MARK: - GraphQL transport

  private func query<T: Decodable & Sendable>(
    _ q: String, variables: [String: JSONValue]?, token: String, as: T.Type
  ) async throws -> T {
    var req = URLRequest(url: CoinstashGraphQL.endpoint)
    req.httpMethod = "POST"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var body: [String: JSONValue] = ["query": .string(q)]
    if let variables { body["variables"] = .object(variables) }
    req.httpBody = try JSONEncoder().encode(JSONValue.object(body))

    let (data, response) = try await transport(req)
    guard let http = response as? HTTPURLResponse else {
      throw ExchangeClientError.malformedResponse
    }
    switch http.statusCode {
    case 200: break
    case 401: throw ExchangeClientError.unauthorized
    case 429:
      // No proactive client-side rate limiter: Coinstash publishes no
      // limits and an account's history is 1–3 pages. Handle 429
      // reactively; the store retries on the next cycle.
      throw ExchangeClientError.rateLimited(retryAfter: nil)
    default: throw ExchangeClientError.http(http.statusCode)
    }
    let decoded = try JSONDecoder().decode(
      CoinstashGraphQLResponse<T>.self, from: data)
    if let err = decoded.errors?.first {
      if err.message.localizedCaseInsensitiveContains("unauthor") {
        throw ExchangeClientError.unauthorized
      }
      throw ExchangeClientError.providerError(err.message)
    }
    guard let payload = decoded.data else {
      throw ExchangeClientError.malformedResponse
    }
    return payload
  }
}
```

> `userAccountsQuery`'s `userId` variable is passed as `.string(userId)` (the GraphQL var is `ID!`). The `CoinstashGraphQL.userAccountsQuery` string in Task 5 takes `$userId: ID!`; reconcile the variable wrapping accordingly.

- [ ] **Step 5: Run tests**

Run: `just test CoinstashClientTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Shared/Exchange/ExchangeClient.swift Shared/Exchange/ExchangeClientError.swift Shared/Exchange/ExchangeDirection.swift Shared/Exchange/ExchangeImportedTransaction.swift Shared/Exchange/CoinstashClient.swift Shared/Exchange/JSONValue.swift MoolahTests/Shared/Exchange/CoinstashClientTests.swift
git commit -m "feat: CoinstashClient GraphQL fetch + paginate"
```

---

## Phase 4 — Mapping to transactions + build engine

### Task 7: `ExchangeInstrumentResolver`

**Files:**
- Create: `Shared/Exchange/ExchangeInstrumentResolver.swift`
- Test: `MoolahTests/Shared/Exchange/ExchangeInstrumentResolverTests.swift`

Resolves a Coinstash `assetSymbol` (e.g. `"OP"`) to a Moolah `Instrument`, or a fiat leg to the **injected** fiat instrument (Coinstash is AUD-denominated, but the resolver must not hardcode AUD — a future fiat-denominated exchange, or a non-AUD Coinstash leg, would otherwise silently land in the AUD bucket).

**`InstrumentRegistryRepository` has NO `instrument(forSymbol:)` method** (verified — it exposes `all() async throws -> [Instrument]`, `allCryptoRegistrations()`, `cryptoRegistration(byId:)`, `registerCrypto`, …; there is no by-ticker lookup). v1 resolves a crypto symbol by scanning `all()` for a crypto-kind instrument whose `ticker` matches case-insensitively. `Instrument` has `kind: Instrument.Kind` (`.cryptoToken`) and `ticker: String?`. An exchange import only carries a ticker (no contract address), so if the registry has no matching row the symbol is genuinely unresolvable — the engine already drops the whole `orderId` group and logs (acceptable v1 behaviour; do not add network discovery here). Reconcile `kind`/`ticker` accessors against the real `Domain/Models/Instrument.swift`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Moolah

struct ExchangeInstrumentResolverTests {
  // Use the EXISTING StubInstrumentRegistry (MoolahTests/Support/) — do not
  // create a new StubRegistry (would duplicate it). `.all()` returns its
  // `instruments`. OP is a real crypto Instrument (no `.eth`/`.opStub`
  // accessor exists — only Instrument.AUD/.USD and Instrument.crypto(...)).
  private let op = Instrument.crypto(
    chainId: 10, contractAddress: "0x4200000000000000000000000000000000000042",
    symbol: "OP", name: "Optimism", decimals: 18)

  @Test func fiatResolvesToInjectedFiatInstrument() async throws {
    let resolver = ExchangeInstrumentResolver(
      registry: StubInstrumentRegistry(), fiatInstrument: .AUD)
    #expect(try await resolver.instrument(forSymbol: nil, isFiat: true) == .AUD)
  }

  @Test func assetResolvesViaRegistry() async throws {
    let resolver = ExchangeInstrumentResolver(
      registry: StubInstrumentRegistry(instruments: [op]), fiatInstrument: .AUD)
    #expect(try await resolver.instrument(forSymbol: "OP", isFiat: false) == op)
  }

  @Test func unknownAssetReturnsNil() async throws {
    let resolver = ExchangeInstrumentResolver(
      registry: StubInstrumentRegistry(), fiatInstrument: .AUD)
    #expect(try await resolver.instrument(forSymbol: "ZZZ", isFiat: false) == nil)
  }
}
```

> Reuse `StubInstrumentRegistry` (`MoolahTests/Support/StubInstrumentRegistry.swift`, `init(instruments:)`, returns them from `all()`) — do **not** introduce a second stub. Reconcile the `Instrument.crypto(...)` argument list against the real `Domain/Models/Instrument.swift` (`chainId/contractAddress/symbol/name/decimals`). There is no `Instrument.eth`/`.opStub` — every test that needs ETH/OP constructs a real `Instrument.crypto(...)`.

- [ ] **Step 2: Run test to verify it fails**

Run: `just test ExchangeInstrumentResolverTests`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Resolves exchange symbols to Moolah `Instrument`s. The fiat denomination
/// is injected (not hardcoded) so the resolver is reusable for a future
/// non-AUD exchange; asset legs go through the instrument registry's symbol
/// lookup. `any InstrumentRegistryRepository` is intentional: v1 has a single
/// concrete registry and the existential keeps construction simple; revisit
/// with a generic only if a second registry implementation appears.
import OSLog

struct ExchangeInstrumentResolver: Sendable {
  private let registry: any InstrumentRegistryRepository
  private let fiatInstrument: Instrument
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "ExchangeInstrumentResolver")

  init(registry: any InstrumentRegistryRepository, fiatInstrument: Instrument) {
    self.registry = registry
    self.fiatInstrument = fiatInstrument
  }

  /// `throws` (NOT `try?`): a registry failure (DB unavailable) must
  /// propagate so the sync fails with a transient error and retries —
  /// silently returning nil would misdiagnose a DB outage as "every
  /// instrument unknown" and permanently drop every imported transaction.
  /// `nil` means genuinely not found (engine drops that group).
  func instrument(forSymbol symbol: String?, isFiat: Bool) async throws
    -> Instrument? {
    if isFiat { return fiatInstrument }
    guard let symbol else { return nil }
    // No registry by-ticker API exists; scan all() (acceptable: called per
    // unresolved leg during a background sync, not a hot UI path).
    do {
      return try await registry.all().first {
        $0.kind == .cryptoToken
          && $0.ticker?.caseInsensitiveCompare(symbol) == .orderedSame
      }
    } catch {
      Self.logger.error(
        "Registry scan failed resolving '\(symbol, privacy: .public)': \(error, privacy: .public)")
      throw error   // transient → CoinstashSyncSource maps to WalletSyncError.network
    }
  }
}
```

> Reconcile `Instrument.Kind.cryptoToken` and `Instrument.ticker` against the real `Domain/Models/Instrument.swift`. The method is `instrument(forSymbol:isFiat:)` (preposition label). If a future need arises to avoid the per-leg `all()` scan, add a real `instrument(byTicker:)` to the protocol, or cache `all()` once per `ExchangeSyncEngine.build` — out of scope for v1; noted in Open Risk.

- [ ] **Step 4: Run tests**

Run: `just test ExchangeInstrumentResolverTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Shared/Exchange/ExchangeInstrumentResolver.swift MoolahTests/Shared/Exchange/ExchangeInstrumentResolverTests.swift
git commit -m "feat: exchange symbol -> instrument resolver"
```

---

### Task 8: `ExchangeSyncEngine.build` (→ `BuiltTransaction`)

**Files:**
- Create: `Shared/Exchange/ExchangeSyncEngine.swift`
- Test: `MoolahTests/Shared/Exchange/ExchangeSyncEngineTests.swift`

Produces a `WalletSyncBuildResult` (reusing the existing struct from `WalletSyncEngine.swift:21-24`: `{ candidates: [BuiltTransaction], headBlockNumber: UInt64 }`) so it can flow straight into `WalletApplyEngine.apply(perAccount:)`. `headBlockNumber` is `0` (unused for exchanges).

**Before writing:** open `Shared/CryptoImport/BuiltTransaction.swift` and `Domain/Models/Transaction.swift` + `Domain/Models/TransactionLeg.swift` and reconcile the `Transaction`/`TransactionLeg` initialisers below with the real ones (the research gave `BuiltTransaction { originAccountId: UUID; transaction: Transaction }` and `TransactionLeg { accountId, instrument, quantity, externalId, counterpartyAddress, ... }`). Replace constructor calls to match exactly.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import Moolah

struct ExchangeSyncEngineTests {
  private static let op = Instrument.crypto(
    chainId: 10, contractAddress: "0x4200000000000000000000000000000000000042",
    symbol: "OP", name: "Optimism", decimals: 18)

  private func resolver(includeOP: Bool = false) -> ExchangeInstrumentResolver {
    ExchangeInstrumentResolver(
      registry: StubInstrumentRegistry(instruments: includeOP ? [Self.op] : []),
      fiatInstrument: .AUD)
  }

  @Test func groupsTradeLegsByOrderId() async throws {
    let acct = Account(name: "Coinstash", type: .exchange,
      instrument: .AUD, exchangeProvider: .coinstash)
    let imported = [
      ExchangeImportedTransaction(externalId: "t1", occurredAt: Date(timeIntervalSince1970: 100),
        category: "TRADE", direction: .credit, assetSymbol: "OP", amount: 50, isFiat: false, orderId: "o1"),
      ExchangeImportedTransaction(externalId: "t2", occurredAt: Date(timeIntervalSince1970: 100),
        category: "TRADE", direction: .debit, assetSymbol: nil, amount: 100, isFiat: true, orderId: "o1"),
      ExchangeImportedTransaction(externalId: "t3", occurredAt: Date(timeIntervalSince1970: 200),
        category: "DEPOSIT", direction: .credit, assetSymbol: nil, amount: 500, isFiat: true, orderId: nil),
    ]
    let engine = ExchangeSyncEngine(resolver: resolver(includeOP: true))
    let result = try await engine.build(account: acct, imported: imported)
    #expect(result.headBlockNumber == 0)
    // One grouped trade (2 legs) + one deposit (1 leg) = 2 transactions
    #expect(result.candidates.count == 2)
    #expect(result.candidates.contains { $0.transaction.legs.count == 2 })
  }

  @Test func dropsEntireGroupWhenAnyLegUnresolvable() async throws {
    let acct = Account(name: "X", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    // A TRADE group whose asset leg can't resolve must NOT emit a partial
    // (fiat-only) transaction — the whole orderId group is dropped.
    let imported = [
      ExchangeImportedTransaction(externalId: "t1", occurredAt: Date(),
        category: "TRADE", direction: .credit, assetSymbol: "UNKNOWNCOIN",
        amount: 1, isFiat: false, orderId: "o1"),
      ExchangeImportedTransaction(externalId: "t2", occurredAt: Date(),
        category: "TRADE", direction: .debit, assetSymbol: nil,
        amount: 100, isFiat: true, orderId: "o1"),
    ]
    let engine = ExchangeSyncEngine(resolver: resolver())  // no OP mapping
    let result = try await engine.build(account: acct, imported: imported)
    #expect(result.candidates.isEmpty)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test ExchangeSyncEngineTests`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement**

```swift
import Foundation
import OSLog

/// Builds `BuiltTransaction` candidates from imported exchange transactions,
/// for the existing `WalletApplyEngine`. Trades (shared `orderId`) become one
/// multi-leg `Transaction`; deposits/withdrawals/awards become single-leg
/// transactions. If ANY leg in a group has an unresolvable instrument the
/// WHOLE group is dropped (a partial, unbalanced trade is worse than no
/// trade) and the drop is logged for diagnosis.
struct ExchangeSyncEngine: Sendable {
  private let resolver: ExchangeInstrumentResolver
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "ExchangeSyncEngine")

  init(resolver: ExchangeInstrumentResolver) {
    self.resolver = resolver
  }

  // Coinstash category → Moolah leg type. Mirrors the wallet importer's
  // inbound→.income / outbound→.expense / swap→.trade convention
  // (`TransferEventBuilder.legType(for:)`): TRADE/TRADEFEE are the legs of
  // a swap (.trade); DEPOSIT/AWARD are inbound (.income); WITHDRAW is
  // outbound (.expense). Default to .trade for any unmapped category (the
  // signed quantity already encodes direction; this only sets the type
  // bucket the UI groups by). `TransactionType` cases: income, expense,
  // transfer, openingBalance, trade.
  static func legType(for category: String) -> TransactionType {
    switch category {
    case "DEPOSIT", "AWARD": return .income
    case "WITHDRAW": return .expense
    default: return .trade   // TRADE, TRADEFEE, anything else
    }
  }

  func build(
    account: Account, imported: [ExchangeImportedTransaction]
  ) async throws -> WalletSyncBuildResult {
    let groups = Dictionary(grouping: imported) { tx -> String in
      tx.orderId ?? tx.externalId  // ungrouped rows are their own group
    }

    var candidates: [BuiltTransaction] = []
    for (groupKey, rows) in groups {
      try Task.checkCancellation()   // cooperative cancel between groups
      var legs: [TransactionLeg] = []
      var groupResolvable = true
      for row in rows {
        try Task.checkCancellation() // …and after each resolver suspension
        // `try`: a thrown registry error propagates (transient — sync fails
        // & retries); `nil` means genuinely not found → drop the group.
        guard let instrument = try await resolver.instrument(
          forSymbol: row.assetSymbol, isFiat: row.isFiat) else {
          Self.logger.warning(
            """
            Dropping group \(groupKey, privacy: .public): unresolvable \
            instrument externalId=\(row.externalId, privacy: .public) \
            symbol=\(row.assetSymbol ?? "nil", privacy: .public) \
            isFiat=\(row.isFiat, privacy: .public)
            """)
          groupResolvable = false
          break
        }
        let qty = row.direction.multiplier * row.amount
        legs.append(TransactionLeg(
          accountId: account.id,
          instrument: instrument,
          quantity: qty,
          externalId: row.externalId,
          type: Self.legType(for: row.category)))   // reconcile param order
      }
      guard groupResolvable, !legs.isEmpty else { continue }
      // A group always has ≥1 row by construction, so `min()` is non-nil;
      // no `Date()` fallback (would couple this to the system clock).
      guard let date = rows.map(\.occurredAt).min() else { continue }
      let transaction = Transaction(
        date: date,
        legs: legs)                      // reconcile with real Transaction init
      candidates.append(BuiltTransaction(
        originAccountId: account.id, transaction: transaction))
    }
    Self.logger.info(
      "Built \(candidates.count) candidates from \(imported.count) imported rows")
    return WalletSyncBuildResult(candidates: candidates, headBlockNumber: 0)
  }
}
```

- [ ] **Step 4: Run tests**

Run: `just test ExchangeSyncEngineTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Shared/Exchange/ExchangeSyncEngine.swift MoolahTests/Shared/Exchange/ExchangeSyncEngineTests.swift
git commit -m "feat: exchange transaction build engine (order grouping + dedup ids)"
```

**Phase 4 checkpoint:** end-to-end data path exists in isolation: token → Coinstash → imported txns → `BuiltTransaction`s. Not yet wired to persistence or UI.

---

## Phase 5 — Unified sync orchestration (de-dup)

### Task 9: `AccountSyncSource` + generalise `CryptoSyncStore` → `SyncedAccountStore`

This task **does not add a parallel store**. It (A) introduces a provider-neutral `AccountSyncSource` protocol, (B) refactors the existing `CryptoSyncStore` so its orchestration is source-driven and renames it `SyncedAccountStore`, with the existing crypto path moved behind a `WalletSyncSource` conformance (existing crypto tests must stay green — this is a characterisation refactor), then (C) adds `CoinstashSyncSource` and registers it. One staleness loop, one error model, one state path for both account kinds.

**Files:**
- Create: `Shared/Sync/AccountSyncSource.swift`
- Create: `Shared/Sync/WalletSyncSource.swift`
- Create: `Shared/Exchange/CoinstashSyncSource.swift`
- Rename: `Features/Crypto/CryptoSyncStore.swift` (+`+Internals.swift`) → `Features/Sync/SyncedAccountStore.swift` (+`+Internals.swift`)
- Modify: every `CryptoSyncStore` reference (grep `CryptoSyncStore` — call sites in `App/`, views, tests)
- Test: `MoolahTests/Shared/Sync/WalletSyncSourceTests.swift`, `MoolahTests/Shared/Exchange/CoinstashSyncSourceTests.swift`, `MoolahTests/Features/Sync/SyncedAccountStoreExchangeTests.swift`

---

#### 9A — `AccountSyncSource` protocol

- [ ] **Step 1: Write the protocol (no test yet — pure declaration)**

`Shared/Sync/AccountSyncSource.swift`:

```swift
import Foundation

/// Provider-neutral sync source. Both on-chain wallets and centralised
/// exchanges conform; `SyncedAccountStore` owns the orchestration (staleness,
/// in-flight set, state persistence) and never branches on account type.
protocol AccountSyncSource: Sendable {
  /// True if this source can sync the given account (type + required config).
  func handles(_ account: Account) -> Bool
  /// Fetch + build candidates. Throw `WalletSyncError` for typed failures
  /// (missing/invalid credential, network, malformed) so the store maps one
  /// error model for all providers.
  func build(account: Account) async throws -> WalletSyncBuildResult
}
```

- [ ] **Step 2: Commit**

```bash
git add Shared/Sync/AccountSyncSource.swift
git commit -m "feat: AccountSyncSource protocol"
```

---

#### 9B — `WalletSyncSource` (existing crypto path, behind the protocol)

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Moolah

struct WalletSyncSourceTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)

  @Test func handlesCryptoWithChainAndAddress() {
    let src = WalletSyncSource(engine: StubWalletEngine(), chains: ChainConfig.all)
    let ok = Account(name: "W", type: .crypto, instrument: eth,
      walletAddress: "0x" + String(repeating: "a", count: 40), chainId: 1)
    let noChain = Account(name: "W", type: .crypto, instrument: eth,
      walletAddress: "0x" + String(repeating: "a", count: 40), chainId: nil)
    let exchange = Account(name: "C", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    #expect(src.handles(ok))
    #expect(!src.handles(noChain))
    #expect(!src.handles(exchange))
  }
}
```

> `StubWalletEngine` returns a fixed `WalletSyncBuildResult`. Reconcile `WalletSyncEngine`'s real protocol/type (`WalletSyncEngine.swift:76-78`) — if it is a concrete struct not a protocol, wrap it behind a small `WalletSyncBuilding` protocol you introduce here and conform the existing engine to it (one-line extension), so the source is testable without Alchemy.

- [ ] **Step 2: Run test to verify it fails**

Run: `just test WalletSyncSourceTests`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement**

`Shared/Sync/WalletSyncSource.swift`:

```swift
import Foundation

/// `AccountSyncSource` for on-chain wallet accounts. Wraps the existing
/// `WalletSyncEngine` + `ChainConfig` lookup — no behaviour change, just the
/// crypto path expressed through the shared protocol.
struct WalletSyncSource: AccountSyncSource, Sendable {
  private let engine: any WalletSyncBuilding
  private let chains: [ChainConfig]

  init(engine: any WalletSyncBuilding, chains: [ChainConfig] = ChainConfig.all) {
    self.engine = engine
    self.chains = chains
  }

  func handles(_ account: Account) -> Bool {
    account.type == .crypto
      && account.walletAddress?.isEmpty == false
      && chain(for: account) != nil
  }

  func build(account: Account) async throws -> WalletSyncBuildResult {
    guard let chain = chain(for: account) else {
      throw WalletSyncError.providerMalformedResponse(stage: "chain-lookup")
    }
    return try await engine.build(account: account, chain: chain)
  }

  // Resolve from the INJECTED chains (not the global `ChainConfig.config`),
  // so the source is testable with stubbed chains and `chains` is real DI.
  private func chain(for account: Account) -> ChainConfig? {
    guard let chainId = account.chainId else { return nil }
    return chains.first { $0.chainId == chainId }
  }
}
```

> Match `WalletSyncError` case names verbatim (`Domain/Models/WalletSyncError.swift`). Reconcile the `ChainConfig` id accessor (`ChainConfig.swift:9-44` — use the real property, e.g. `chainId`). Add `protocol WalletSyncBuilding: Sendable { func build(account: Account, chain: ChainConfig) async throws -> WalletSyncBuildResult }` (the `: Sendable` is required — `WalletSyncSource: Sendable` stores `any WalletSyncBuilding`; without it Swift 6 strict concurrency rejects the conformance) and conform the existing `WalletSyncEngine` (already `Sendable`) via a one-line extension (one-extension-per-protocol per project convention). Also confirm `ChainConfig: Sendable` (it is a value type with `let` fields, so it should synthesise `Sendable` — `WalletSyncSource: Sendable` stores `[ChainConfig]`; if it does not conform, add `extension ChainConfig: Sendable {}`).

- [ ] **Step 4: Run tests**

Run: `just test WalletSyncSourceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Shared/Sync/WalletSyncSource.swift Shared/CryptoImport/ MoolahTests/Shared/Sync/WalletSyncSourceTests.swift
git commit -m "feat: WalletSyncSource wrapping existing wallet engine"
```

---

#### 9C — Generalise + rename `CryptoSyncStore` → `SyncedAccountStore`

The store keeps its **exact existing public surface and call stack** — only the rename and the source-aware filter change. **Before writing anything, grep the real `CryptoSyncStore` (+`+Internals.swift`) for the actual method names** (the research suggested `loadInitialState()`, `syncAccounts(_:)`, `runParallelBuilds`, `runApplyPass`, `refreshStateFromRepository`, `updateGlobalError(from:)`, `scheduleInitialSync(for:)`, `initialSyncTasks`); use the real names verbatim — do not invent `loadStates()`. This is a **characterisation-safe refactor**, not a rewrite of `syncAccount`.

- [ ] **Step 1: Rename files + symbol (mechanical)**

`git mv Features/Crypto/CryptoSyncStore.swift Features/Sync/SyncedAccountStore.swift` (and the `+Internals.swift`). Rename the type `CryptoSyncStore` → `SyncedAccountStore` and update every reference (grep `CryptoSyncStore`). Build to confirm the rename compiles before changing behaviour:

Run: `just build-mac`
Expected: green (pure rename).

- [ ] **Step 2: Run existing crypto tests (characterisation baseline)**

Run: `just test SyncedAccountStore` (the renamed crypto sync tests)
Expected: PASS — establishes the behaviour the refactor must preserve.

- [ ] **Step 3: Make orchestration source-driven (minimal, in-place edits)**

**Do not rewrite the concurrency model or error handling** of `syncAccount(_:)` → `syncAccounts(_:)` → `runParallelBuilds` → `runApplyPass` → `refreshStateFromRepository` (with `updateGlobalError(from:)`, `scheduleInitialSync(for:)`/`initialSyncTasks`, and the `persistError` save-with-logging helper). **But you MUST replace every hard-coded `account.type == .crypto` gate** — leaving them makes the refactor compile and pass crypto characterisation tests while exchange accounts silently never sync. Make exactly these surgical changes:

1. **Constructor (concrete):** delete the `let walletSyncEngine: WalletSyncEngine` stored property; add `private let sources: [any AccountSyncSource]` (it is `Sendable` since the protocol is). In `init`, replace the `walletSyncEngine:` parameter with `sources:`. Update every capture/use of `self.walletSyncEngine` — notably the `let walletSyncEngine = self.walletSyncEngine` line in `runParallelBuilds` becomes `let sources = self.sources` (passed into `buildOne`). Grep `walletSyncEngine` across the store + `+Internals.swift` and convert every occurrence. Keep `applyEngine`, `syncStateRepo`, `accounts`, `clock`, `staleThreshold`, etc. exactly as they were. Also rename the type/files per 9C (`CryptoSyncStore`→`SyncedAccountStore`) — and **update `CryptoSettingsView`'s `let cryptoSyncStore: CryptoSyncStore?` property type to `SyncedAccountStore?`** and every call site passing it (the rename is a compile-break otherwise; the Alchemy badge still reads `.globalError`, so the property is kept, just retyped).

2. **The two entry guards** (real locations ≈ `CryptoSyncStore.swift`: `syncAccount(_:)` `guard account.type == .crypto else { return }`, and `syncAccounts(_:)`'s `accountList.filter { guard account.type == .crypto else { return false } }`): replace **both** `account.type == .crypto` checks with `sources.contains(where: { $0.handles(account) })`. Grep `account.type == .crypto` across the store + `+Internals.swift` and convert *every* occurrence — none may remain.

3. **`accountsToSync` filter** (≈ `CryptoSyncStore+Internals.swift`): the real predicate is `account.type == .crypto && account.walletAddress?.isEmpty == false && account.chainId != nil` followed by the staleness check. Replace **all three** crypto-field guards (type, walletAddress, chainId) with the single `sources.contains(where: { $0.handles(account) })` — `WalletSyncSource.handles` already enforces walletAddress/chainId for crypto, and exchange accounts have neither, so leaving any of the three excludes exchange accounts from the stale-timer/scene-active syncs entirely (only user-initiated `syncAccount` would ever fire). The resulting filter is exactly: `guard sources.contains(where: { $0.handles(account) }) else { return false }` then the **unchanged** `lastSyncedAt`/`staleThreshold` comparison.

4. **The per-account build step** (`buildOne`/`runParallelBuilds` child-task body that calls `walletSyncEngine.build(account:chain:)`): if `buildOne` is a `static func` taking `engine: WalletSyncEngine`, replace **only** the `engine:` parameter with `sources: [any AccountSyncSource]`. **Keep `priorState: WalletSyncState?`** — it is NOT unused: `buildOne` passes it to `persistError`, which on failure preserves `priorState?.lastSyncedBlockNumber` so a transient error doesn't reset a wallet's watermark to 0 (genesis re-fetch regression for large histories). Keep every other `buildOne` parameter (`walletSyncState` repo, `priorState`) and the whole `do/catch` → `persistError` → `PerAccountBuildResult` structure intact; swap *only* the `engine.build(account:chain:)` call for the source lookup. Pass `sources` explicitly from `runParallelBuilds` (do not inline into the `group.addTask` closure — that loses the `buildOne` test surface). The build call becomes:

```swift
guard let source = sources.first(where: { $0.handles(account) }) else {
  return .skipped   // match the existing skipped-result sentinel
}
let built = try await source.build(account: account)
// AccountInput construction is IDENTICAL to today (same for crypto and
// exchange) — keep it; do not drop it when trimming to "unchanged path":
let input = WalletApplyEngine.AccountInput(
  account: account,
  headBlockNumber: built.headBlockNumber,
  candidates: built.candidates)
return .success(input)
// The surrounding do/catch + persistError(_, priorState:, walletSyncState:)
// + PerAccountBuildResult path is unchanged — priorState still flows to
// persistError exactly as before. For exchange accounts priorState is nil
// or has lastSyncedBlockNumber 0 (full re-fetch), which persistError
// preserves correctly.
```

`WalletSyncSource.build` fills `headBlockNumber` from the wallet engine; `CoinstashSyncSource.build` sets it to `0`. Everything after the build (apply, `WalletSyncState` persistence via the existing `persistError`/save-with-logging helper, `updateGlobalError(from:)`, `refreshStateFromRepository`) is **unchanged** — do not introduce a new `try? await syncStateRepo.save(...)`.

5. **`scheduleInitialSync(for:)` / `initialSyncTasks`:** leave the body intact — it calls `syncAccount(_:)`, which is now source-aware via change 2, so it works for exchange accounts (this is the path `ExchangeAccountCreationLogic` uses; without change 2 it early-returns and the new account never syncs).

6. **`globalError`:** keep the existing `updateGlobalError(from:)` batch scan, but **scope it to crypto accounts**. `globalError` is read by `CryptoSettingsView.alchemyStatusBadge` (`CryptoSettingsView.swift:66-73,138`) to render the **Alchemy** key status — it is Alchemy-specific. Without scoping, a Coinstash account with a bad token throws `WalletSyncError.invalidApiKey`, `updateGlobalError` sets `globalError = .invalidApiKey`, and Settings → Crypto shows the Alchemy key as "Invalid" (red) even though the Alchemy key is fine — sending the user to fix the wrong thing. Fix (concrete): `PerAccountBuildResult.failed` currently carries only `(UUID, WalletSyncError)` — it has no account type, so the scope cannot be expressed without a change. Change the case to `case failed(UUID, WalletSyncError, AccountType)` (or add `accountType`), update `buildOne` to pass `account.type` into it, and in `updateGlobalError(from:)` (`CryptoSyncStore+Internals.swift:218`) only fold `.missingApiKey`/`.invalidApiKey` into `globalError` when `accountType == .crypto`. Update the `.skipped`/`.success` arms and any exhaustive switches accordingly. Add a test: an exchange `.invalidApiKey` result must NOT set `globalError`; a crypto one still does. Do not add a per-call `globalError =` assignment elsewhere.

> Net effect: the source abstraction replaces the wallet-only type guards (changes 2–4); `globalError` stays Alchemy/crypto-scoped (change 6); the concurrency model, error handling, and state persistence are otherwise untouched. If real method/field names differ, grep and use the real ones.

- [ ] **Step 3b: Make the sync-checkpoint docs account-type-neutral**

After this task `WalletSyncState`/its repository back exchange accounts too. Update **all three** stale doc comments to account-type-neutral wording (drop "wallet"/"Alchemy-fetch progress"; "on-chain wallet or exchange"):
- `Domain/Models/WalletSyncState.swift` type doc comment, **and** add a `///` doc comment directly on the `lastSyncedBlockNumber` property (not only the type-level comment): "Always `0` for exchange accounts (block-window re-fetch is wallet-only)."
- `Domain/Repositories/WalletSyncStateRepository.swift` protocol doc comment, the `loadAll` inline comment ("`CryptoSyncStore` calls this at launch" → `SyncedAccountStore`), **and** the `load(accountId:)` method comment (it currently says "`WalletSyncEngine` calls this per sync cycle to derive the reorg window's `fromBlock = lastSyncedBlockNumber - 32`" — keep the wallet mechanics but add that for exchange accounts `lastSyncedBlockNumber` is always 0 / full re-fetch).
- `Backends/GRDB/Repositories/GRDBWalletSyncStateRepository.swift` header comment ("crypto wallet accounts" → neutral).

- [ ] **Step 4: Re-run the characterisation tests**

Run: `just test SyncedAccountStore`
Expected: PASS — crypto behaviour unchanged through the refactor.

- [ ] **Step 5: Commit**

```bash
git add Features/Sync/ Features/Crypto/ App/ MoolahTests/
git commit -m "refactor: source-driven SyncedAccountStore (was CryptoSyncStore)"
```

---

#### 9D — `CoinstashSyncSource` (new provider behind the same protocol)

**Files:** Create `Shared/Exchange/CoinstashSyncSource.swift`; Test `MoolahTests/Shared/Exchange/CoinstashSyncSourceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import Moolah

struct CoinstashSyncSourceTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)

  private func makeSource(
    client: any ExchangeClient, store: ExchangeTokenStore
  ) -> CoinstashSyncSource {
    CoinstashSyncSource(
      tokenStore: store, client: client,
      engine: ExchangeSyncEngine(resolver:
        ExchangeInstrumentResolver(
          registry: StubInstrumentRegistry(), fiatInstrument: .AUD)))
  }

  @Test func handlesOnlyCoinstashExchange() {
    let src = makeSource(
      client: StubExchangeClient(), store: ExchangeTokenStore(synchronizable: false))
    let ex = Account(name: "C", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    let crypto = Account(name: "W", type: .crypto, instrument: eth,
      walletAddress: "0x" + String(repeating: "a", count: 40), chainId: 1)
    // nil-provider exchange account (e.g. decoded from an older device):
    // the == .coinstash check is load-bearing for multi-provider correctness.
    // When a 2nd ExchangeProvider case is added, extend this with a
    // handles==false assertion for that provider.
    let nilProvider = Account(name: "X", type: .exchange, instrument: .AUD,
      exchangeProvider: nil)
    #expect(src.handles(ex))
    #expect(!src.handles(crypto))
    #expect(!src.handles(nilProvider))
  }

  @Test func missingTokenThrowsMissingApiKey() async throws {
    let src = makeSource(
      client: StubExchangeClient(), store: ExchangeTokenStore(synchronizable: false))
    let ex = Account(name: "C", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    let error = await #expect(throws: WalletSyncError.self) {
      _ = try await src.build(account: ex)
    }
    #expect(error == .missingApiKey)
  }

  @Test func unauthorizedMapsToInvalidApiKey() async throws {
    let store = ExchangeTokenStore(synchronizable: false)
    let ex = Account(name: "C", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    try store.save(token: "TOK", for: ex.id)
    let src = makeSource(
      client: StubExchangeClient(error: ExchangeClientError.unauthorized),
      store: store)
    let error = await #expect(throws: WalletSyncError.self) {
      _ = try await src.build(account: ex)
    }
    #expect(error == .invalidApiKey)
  }
}
```

> `StubExchangeClient` conforms to `ExchangeClient`, returning a fixed array or throwing the injected error. Reconcile `WalletSyncError` case names verbatim. (`#expect(throws:)` returns the thrown error for the follow-up assertion — the project's Swift Testing idiom; no `do/catch`+`Issue.record`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `just test CoinstashSyncSourceTests`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement `CoinstashSyncSource`**

```swift
import Foundation
import OSLog

/// `AccountSyncSource` for Coinstash exchange accounts. Resolves the
/// per-account token, fetches via `CoinstashClient`, and builds candidates.
/// Maps provider errors into the shared `WalletSyncError` model so
/// `SyncedAccountStore` stays provider-agnostic. A future exchange gets its
/// own `<Provider>SyncSource` — this one handles `.coinstash` only.
struct CoinstashSyncSource: AccountSyncSource, Sendable {
  private let tokenStore: ExchangeTokenStore
  private let client: any ExchangeClient
  private let engine: ExchangeSyncEngine
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "CoinstashSyncSource")

  init(tokenStore: ExchangeTokenStore, client: any ExchangeClient,
       engine: ExchangeSyncEngine) {
    self.tokenStore = tokenStore
    self.client = client
    self.engine = engine
  }

  // Concrete provider check (not `!= nil`): with a second exchange's
  // source registered, both must not claim the same account.
  func handles(_ account: Account) -> Bool {
    account.type == .exchange && account.exchangeProvider == .coinstash
  }

  func build(account: Account) async throws -> WalletSyncBuildResult {
    // SAFETY: synchronous Security-framework read on the build task. The
    // token is per-account (not shared) so this is the natural call site;
    // matches the existing Alchemy-key per-request keychain read pattern.
    // Distinguish a genuine "no token" (→ missingApiKey, actionable) from
    // a transient keychain failure (e.g. device locked → treat as network)
    // so the user isn't wrongly told to re-enter a token that exists.
    let token: String?
    do {
      token = try tokenStore.token(for: account.id)
    } catch {
      Self.logger.error(
        "Keychain read failed for \(account.id, privacy: .public): \(error, privacy: .public)")
      throw WalletSyncError.network(
        underlyingDescription: "Keychain read failed: \(error)")
    }
    guard let token, !token.isEmpty else {
      throw WalletSyncError.missingApiKey
    }
    do {
      let imported = try await client.fetchTransactions(token: token)
      return try await engine.build(account: account, imported: imported)
    } catch ExchangeClientError.unauthorized {
      throw WalletSyncError.invalidApiKey
    } catch let e as ExchangeClientError {
      throw WalletSyncError.network(underlyingDescription: String(describing: e))
    }
  }
}
```

> Reconcile `WalletSyncError` cases verbatim (`Domain/Models/WalletSyncError.swift`). If `.network(underlyingDescription:)`/`.invalidApiKey`/`.missingApiKey` aren't the exact spellings, use the real cases the crypto path already uses for the same conditions (transient vs missing-credential vs invalid-credential).

- [ ] **Step 4: Run tests**

Run: `just test CoinstashSyncSourceTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Shared/Exchange/CoinstashSyncSource.swift MoolahTests/Shared/Exchange/CoinstashSyncSourceTests.swift
git commit -m "feat: CoinstashSyncSource behind AccountSyncSource"
```

---

#### 9E — Register both sources + wire profile session

- [ ] **Step 1: Write the failing integration test**

```swift
import Testing
import Foundation
@testable import Moolah

@MainActor
struct SyncedAccountStoreExchangeTests {
  @Test func storeSyncsExchangeAccountThroughSharedPipeline() async throws {
    // Build the harness first, THEN register a source that uses harness-owned
    // collaborators (you cannot reference `harness` inside its own init —
    // that is a use-before-initialization compile error). The harness exposes
    // `addSource(_:)` for post-construction registration.
    let harness = try SyncedAccountStoreTestHarness()
    harness.addSource(CoinstashSyncSource(
      tokenStore: harness.tokenStore,
      client: StubExchangeClient(deposit: 100),
      engine: ExchangeSyncEngine(resolver:
        ExchangeInstrumentResolver(
          registry: harness.registry, fiatInstrument: .AUD))))
    let account = try await harness.makeExchangeAccount(token: "TOK")
    await harness.store.syncAccount(account)
    let state = try await harness.syncStateRepo.load(accountId: account.id)
    #expect(state?.lastError == nil)
    let txns = try await harness.transactions.fetchAll()
    #expect(txns.contains { $0.legs.contains { $0.externalId != nil } })
  }
}
```

> Extend the renamed crypto `SyncedAccountStoreTestHarness` with `addSource(_:)` + `makeExchangeAccount(token:)`. For `addSource` to work, `SyncedAccountStore.sources` must be a `private(set) var` (not `let`) — appended to only on `@MainActor` (the store is `@MainActor`), which keeps it `Sendable`-safe; the harness's `addSource` calls a small `@MainActor` store method (e.g. `store.appendSourceForTesting(_:)` gated `#if DEBUG`/test-only) rather than mutating the array across actors. Do not fork a new harness or reference `harness` inside its own initializer.

- [ ] **Step 2: Run test to verify it fails**

Run: `just test SyncedAccountStoreExchangeTests`
Expected: FAIL — harness/source not registered.

- [ ] **Step 3: Register sources in the profile session**

Grep `SyncedAccountStore(` (post-rename) under `App/`. At the construction site, build the sources array:

```swift
let walletSource = WalletSyncSource(engine: liveWalletEngine)   // existing engine
let coinstashSource = CoinstashSyncSource(
  tokenStore: ExchangeTokenStore(synchronizable: true),
  client: CoinstashClient(),
  engine: ExchangeSyncEngine(resolver:
    ExchangeInstrumentResolver(
      registry: instrumentRegistry,
      // The profile's own currency, NOT a hardcoded .AUD — grep the real
      // construction site for the profile-instrument accessor (e.g.
      // profileSession.profile.instrument) and thread it in.
      fiatInstrument: profileSession.profile.instrument)))
// Future exchanges append their own <Provider>SyncSource here.
let syncStore = SyncedAccountStore(
  /* existing repos/applyEngine */ sources: [walletSource, coinstashSource])
```

The store's existing lifecycle calls (the real initial-state loader — `loadInitialState()` per the research; grep to confirm — plus `syncStaleAccounts()`) are unchanged; they now cover exchange accounts for free via the source-aware filter.

- [ ] **Step 4: Run tests + build**

Run: `just build-mac` then `just test SyncedAccountStore`
Expected: build green; full crypto + exchange store suite PASS.

- [ ] **Step 5: Commit**

```bash
git add App/ MoolahTests/Features/Sync/SyncedAccountStoreExchangeTests.swift
git commit -m "feat: register wallet + exchange sync sources in profile session"
```

**Phase 5 checkpoint:** one `SyncedAccountStore` syncs both `.crypto` and `.exchange` via `AccountSyncSource`. No duplicated orchestration; crypto behaviour unchanged (characterisation tests green).

---

## Phase 6 — UI

### Task 10: Exchange account creation (view + logic)

**Files:**
- Create: `Features/Exchange/ExchangeAccountCreationLogic.swift`
- Create: `Features/Exchange/ExchangeAccountCreationView.swift`
- Modify: `Features/Accounts/Views/CreateAccountView.swift:129-194` (branch + `isValid`/`isSubmitting`)
- Test: `MoolahTests/Features/Exchange/ExchangeAccountCreationLogicTests.swift`

Mirrors `CryptoAccountCreationView` + `CryptoAccountCreationLogic` (`Features/Crypto/CryptoAccountCreationView.swift:87-139`). Fields: name, provider picker (`ExchangeProvider.allCases`, currently just Coinstash), `SecureField` for the token, and a help `Link` (same style as `CryptoSettingsView.swift:83-86`). On submit: create the account (`type: .exchange`, `valuationMode: .calculatedFromTrades`, `instrument: .AUD`, `exchangeProvider:`), save the token to `ExchangeTokenStore`, then trigger the shared `SyncedAccountStore.syncAccount(created)` (no exchange-specific store).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Moolah

// `ExchangeCreationHarness` is plan-authored scaffolding (no existing
// equivalent): build it by copying `CryptoAccountCreationLogicTests`'
// harness shape (grep MoolahTests for that file) — an in-memory backend
// giving an `AccountStore` + `repository`, an `ExchangeTokenStore(
// synchronizable: false)` (with a `failingTokenStore: Bool` init that
// injects a save-throwing token store), and an optional `SyncedAccountStore`.
@MainActor
struct ExchangeAccountCreationLogicTests {
  @Test func createsExchangeAccountAndStoresToken() async throws {
    let harness = try ExchangeCreationHarness()  // see note above
    let logic = ExchangeAccountCreationLogic(
      accountStore: harness.accountStore,
      tokenStore: harness.tokenStore,
      syncStore: harness.syncStore, profileInstrument: .AUD)
    let outcome = await logic.submit(
      name: "My Coinstash", provider: .coinstash, token: "TOK123")
    guard case .created(let account) = outcome else {
      Issue.record("expected .created, got \(outcome)"); return
    }
    #expect(account.type == .exchange)
    #expect(account.exchangeProvider == .coinstash)
    #expect(try harness.tokenStore.token(for: account.id) == "TOK123")
  }

  @Test func rejectsEmptyToken() async throws {
    let harness = try ExchangeCreationHarness()
    let logic = ExchangeAccountCreationLogic(
      accountStore: harness.accountStore,
      tokenStore: harness.tokenStore,
      syncStore: harness.syncStore, profileInstrument: .AUD)
    let outcome = await logic.submit(name: "X", provider: .coinstash, token: "  ")
    guard case .invalidInput = outcome else {
      Issue.record("expected .invalidInput"); return
    }
  }

  @Test func tokenSaveFailureRollsBackTheCreatedAccount() async throws {
    // Inject a token store that throws on save; assert the account is NOT
    // left behind (no orphan "missing token" account).
    let harness = try ExchangeCreationHarness(failingTokenStore: true)
    let logic = ExchangeAccountCreationLogic(
      accountStore: harness.accountStore,
      tokenStore: harness.tokenStore,
      syncStore: harness.syncStore, profileInstrument: .AUD)
    let outcome = await logic.submit(
      name: "C", provider: .coinstash, token: "TOK")
    guard case .failure = outcome else {
      Issue.record("expected .failure"); return
    }
    let accounts = try await harness.accountStore.repository.fetchAll()
    #expect(!accounts.contains { $0.type == .exchange })
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test ExchangeAccountCreationLogicTests`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement view + logic**

`Features/Exchange/ExchangeAccountCreationView.swift`:

Help URL/label are provider-derived via `provider.helpURL` / `provider.displayName` (both already on `ExchangeProvider` from Task 1) — a hardcoded "Coinstash" label/URL would contradict the picker the moment a second provider exists.

`Features/Exchange/ExchangeAccountCreationLogic.swift` (own file — one primary type per file; the view file below imports it, no SwiftUI in the logic):

```swift
import Foundation
import OSLog

@MainActor
struct ExchangeAccountCreationLogic {
  private let accountStore: AccountStore
  private let tokenStore: ExchangeTokenStore
  private let syncStore: SyncedAccountStore?
  /// The profile's currency — the new account is denominated in it, NOT a
  /// hardcoded `.AUD` (a non-AUD profile would otherwise mis-denominate).
  private let profileInstrument: Instrument
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "ExchangeAccountCreation")

  init(accountStore: AccountStore, tokenStore: ExchangeTokenStore,
       syncStore: SyncedAccountStore?, profileInstrument: Instrument) {
    self.accountStore = accountStore
    self.tokenStore = tokenStore
    self.syncStore = syncStore
    self.profileInstrument = profileInstrument
  }

  enum Outcome: Sendable {
    case created(Account)
    case invalidInput
    case failure(Error)
  }

  func submit(
    name: String, provider: ExchangeProvider, token: String
  ) async -> Outcome {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty, !trimmedToken.isEmpty else { return .invalidInput }
    let account = Account(
      name: trimmedName,
      type: .exchange,
      instrument: profileInstrument,
      valuationMode: .calculatedFromTrades,
      exchangeProvider: provider)
    let created: Account
    do {
      created = try await accountStore.create(account)
    } catch {
      return .failure(error)
    }
    do {
      try tokenStore.save(token: trimmedToken, for: created.id)
    } catch {
      // Roll back the just-created account: an account with no token is
      // stuck in "missing token" forever and can't be fixed from this sheet.
      do {
        try await accountStore.delete(created)
      } catch let rollbackError {
        Self.logger.error(
          "Rollback delete failed for \(created.id, privacy: .public): \(rollbackError, privacy: .public)")
      }
      return .failure(error)
    }
    // Tracked + cancellable, like CryptoAccountCreationLogic — not a bare
    // Task{} (which would orphan on sheet dismiss / profile teardown).
    syncStore?.scheduleInitialSync(for: created)
    return .created(created)
  }
}
```

`Features/Exchange/ExchangeAccountCreationView.swift` — renders only the exchange Section (picker + token + help). It does NOT own submission: `name` is rendered by `CreateAccountView`'s shared fields, and `CreateAccountView.submitExchange()` invokes the logic. So the view holds no `logic`/`onResult`/`name` (dead params would be an API lie):

```swift
import SwiftUI

struct ExchangeAccountCreationView: View {
  @Binding var provider: ExchangeProvider     // owned by CreateAccountView
  @Binding var token: String                  // owned by CreateAccountView

  var body: some View {
    Section {
      Picker("Exchange", selection: $provider) {
        ForEach(ExchangeProvider.allCases, id: \.self) {
          Text($0.displayName).tag($0)
        }
      }
      .accessibilityIdentifier(
        UITestIdentifiers.ExchangeAccountCreation.providerPicker)
      // Plain SecureField (NOT wrapped in LabeledContent — that double-labels
      // on macOS grouped Form: row label + the field's own prompt). First arg
      // is the row label; `prompt:` is the placeholder. Matches every other
      // SecureField in the codebase (e.g. CryptoSettingsView).
      SecureField(
        "API Token", text: $token,
        prompt: Text("Paste your read-only token"))
        .textContentType(.password)
        .accessibilityLabel("API Token")
        .accessibilityIdentifier(
          UITestIdentifiers.ExchangeAccountCreation.accessTokenField)
      Link("How to create your \(provider.displayName) API key",
           destination: provider.helpURL)
        .font(.caption)
        .frame(minHeight: 44)   // ≥44pt hit target (padding 8 only gives 28pt)
    } footer: {
      // Provider-neutral: the help Link already points at the exact article,
      // so don't bake one provider's UI path ("Settings, API Keys") into copy
      // shown for every provider. Lead with the user's real concern (safety).
      Text("Moolah only ever reads your transaction history. "
        + "A read-only token keeps your funds safe — it can't trade or withdraw.")
    }
  }
}

#Preview {
  // @Previewable @State for live interactivity (typing into the token field,
  // changing the picker) — matches CryptoAccountCreationView's #Preview.
  // .constant(...) bindings make the canvas non-interactive and hide the
  // non-empty-token layout.
  @Previewable @State var provider: ExchangeProvider = .coinstash
  @Previewable @State var token = ""
  Form {
    ExchangeAccountCreationView(provider: $provider, token: $token)
  }
  .formStyle(.grouped)
  .frame(width: 500, height: 320)   // matches CryptoAccountCreationView preview
}
```

> The view has no `submit()`/`logic`/`onResult`/`name` (a SwiftUI value type can't expose submission agency, and dead params are an API lie). `CreateAccountView.submitExchange()` constructs `ExchangeAccountCreationLogic(accountStore:tokenStore:syncStore:profileInstrument:)` — passing the **profile's** instrument (grep the `CreateAccountView`/`submitCrypto()` site for how the profile currency is reached, e.g. `session.profile.instrument`) — and calls `.submit(...)` with the shell's bound state, mirroring `submitCrypto()`. Match `Account(...)`/`AccountStore.create`/`AccountStore.delete`/`scheduleInitialSync(for:)` to the verbatim signatures (grep `AccountStore+Mutations.swift` for the real `delete` — if it has a different signature, use it; if there is **no** account delete, surface as a blocker rather than leaving an orphan); add `UITestIdentifiers.ExchangeAccountCreation.accessTokenField`; reconcile `ExchangeCreationHarness(failingTokenStore:)` with the real test-harness helper. If `scheduleInitialSync` is named differently on `SyncedAccountStore`, use the real name (Task 9C kept it intact).

- [ ] **Step 4: Branch in `CreateAccountView` (lift exchange state to the shell)**

`CreateAccountView` holds the shared form state across account types (per its own doc comment). Mirror how `cryptoChain`/`cryptoWalletAddress` are declared at the shell level:
- Add `@State private var exchangeProvider: ExchangeProvider = .coinstash` and `@State private var exchangeToken = ""` to `CreateAccountView`. The file **does** have a `Field` focus enum — add `case exchangeToken` (mandatory, not "if it has one"), wire `SecureField(...).focused($focusedField, equals: .exchangeToken)`, and add a `.exchange` branch to the `namePrompt` computed property (e.g. `case .exchange: return "e.g. Coinstash"`) so the name placeholder isn't the bank default. Add `static let providerPicker = "ExchangeAccountCreation.providerPicker"` (and the existing `accessTokenField`) to the `UITestIdentifiers.ExchangeAccountCreation` namespace.
- Add an `if type == .exchange` branch rendering `ExchangeAccountCreationView(provider: $exchangeProvider, token: $exchangeToken)` parallel to the crypto fork (`:129-132`). (No `logic`/`name`/`onResult` — the view renders only its Section; `name` is the shared field; submission is `submitExchange()`.)
- **Extend `isValid`**: add an `.exchange` branch requiring `!exchangeToken.trimmingCharacters(in: .whitespaces).isEmpty` (so the Create button is disabled with an empty token, exactly as the `.crypto` branch validates the address). Without this the button enables, submit returns `.invalidInput`, and the spinner can appear stuck.
- Add `submitExchange()` mirroring `submitCrypto()` (`:157-194`): construct `ExchangeAccountCreationLogic(accountStore:…, tokenStore:…, syncStore:…, profileInstrument: <profile currency>)` (reach the profile instrument the same way `submitCrypto`/the shell reaches `session` — do not hardcode), call `.submit(name: name, provider: exchangeProvider, token: exchangeToken)`, switch the `Outcome` (`.created` → dismiss; `.invalidInput` → inline message; `.failure` → `error.localizedDescription`), and **reset `isSubmitting = false` on `.invalidInput`/`.failure`** exactly as `submitCrypto()` does on its `.invalidAddress` path (mirror the existing `isSubmitting = false` reset — do not leave the spinner spinning). The `AccountType` picker lists `.exchange` automatically via `AccountType.allCases`.

- [ ] **Step 5: Run tests + build**

Run: `just test ExchangeAccountCreationLogicTests` then `just build-mac`
Expected: tests PASS; build green.

- [ ] **Step 6: Commit**

```bash
git add Features/Exchange/ExchangeAccountCreationLogic.swift Features/Exchange/ExchangeAccountCreationView.swift Features/Accounts/Views/CreateAccountView.swift MoolahTests/Features/Exchange/ExchangeAccountCreationLogicTests.swift
git commit -m "feat: exchange account creation UI"
```

---

### Task 11: De-dup the sync control — delete the settings list, generalise the account-detail header

**No list, no parallel section.** The per-account sync control already lives in the crypto account-detail header (`WalletAccountHeaderView`). This task (A) adds the `SyncableAccountPresentation` seam, (B) **deletes** the redundant crypto-accounts list from the Settings panel and removes `CryptoAccountsListSection`, (C) generalises `WalletAccountHeaderView`/`WalletAccountHeaderLogic` into one shared synced-account header serving both crypto and exchange, and (D) routes `.exchange` accounts to a detail view that composes that shared header over the investment-like positions body. Crypto behaviour is protected by characterisation (before/after the 11C refactor).

**Files:**
- Create: `Features/Sync/SyncableAccountPresentation.swift`
- Modify: `Features/Settings/CryptoSettingsView.swift:43-46` (remove the embedded list)
- Delete: `Features/Crypto/CryptoAccountsListSection.swift` (+ its tests, if any)
- Rename + generalise: `Features/Crypto/WalletAccountHeaderView.swift` → `Features/Sync/SyncedAccountHeaderView.swift` and `WalletAccountHeaderLogic.swift` → `Features/Sync/SyncedAccountHeaderLogic.swift`
- Modify: `Features/Crypto/CryptoWalletAccountView.swift:56-67` (use the renamed header)
- Modify: `App/ContentView.swift:346-378` (add `.exchange` route)
- Create: `Features/Exchange/ExchangeAccountView.swift` (shared header + positions body)
- Test: `MoolahTests/Features/Sync/SyncableAccountPresentationTests.swift`

---

#### 11A — `SyncableAccountPresentation` (the per-type seam)

- [ ] **Step 1: Write the failing test**

`ExchangeProvider.website` already exists (added in Task 1, force-unwrap-suppressed in the private `Links` enum). The presentation needs to know whether the account's credential exists (Alchemy key for crypto, token for exchange) — that can't be derived from `Account` alone, so it's passed in. It owns ALL synced-account-UI branching: identifier, external-open, identifier selectability, and the missing-credential hint.

```swift
import Testing
@testable import Moolah

struct SyncableAccountPresentationTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)

  @Test func cryptoShowsTruncatedSelectableAddressAndExplorer() {
    let addr = "0x" + String(repeating: "a", count: 40)
    let account = Account(name: "W", type: .crypto, instrument: eth,
      walletAddress: addr, chainId: 1)
    let p = SyncableAccountPresentation(account: account, hasCredential: true)
    #expect(p.identifier.hasPrefix("0xaa"))
    #expect(p.identifier.contains("…"))
    #expect(p.isSelectableIdentifier)                   // address is copyable
    #expect(p.externalActionTitle == "Open in block explorer")
    #expect(p.externalURL?.absoluteString.contains(addr) == true)
    #expect(p.missingCredentialHint == nil)             // credential present
    #expect(p.secondaryIdentifier == "Ethereum")        // chainId 1 → chain name
  }

  @Test func exchangeShowsProviderWebsiteAndNonSelectableID() {
    let account = Account(name: "C", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    let p = SyncableAccountPresentation(account: account, hasCredential: false)
    #expect(p.identifier == "Coinstash")
    #expect(!p.isSelectableIdentifier)                  // a name, not an address
    #expect(p.externalActionTitle == "Open Coinstash")
    #expect(p.externalURL?.host?.contains("coinstash") == true)
    #expect(p.secondaryIdentifier == nil)               // no chain for exchange
    #expect(p.missingCredentialHint != nil)             // token absent
  }

  @Test func nonSyncableHasNoExternalTargetOrTitle() {
    let account = Account(name: "B", type: .bank, instrument: .AUD)
    let p = SyncableAccountPresentation(account: account, hasCredential: true)
    #expect(p.externalURL == nil)
    #expect(p.externalActionTitle == nil)               // optional, not ""
  }

  @Test func exchangeWithNilProviderHasNoDanglingTitle() {
    let account = Account(name: "X", type: .exchange, instrument: .AUD,
      exchangeProvider: nil)
    let p = SyncableAccountPresentation(account: account, hasCredential: false)
    #expect(p.externalURL == nil)
    #expect(p.externalActionTitle == nil)               // not "Open exchange"
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test SyncableAccountPresentationTests`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement**

`Features/Sync/SyncableAccountPresentation.swift`:

```swift
import Foundation

/// Per-account view data shared by `SyncedAccountHeaderView`. The ONLY
/// place account-type branching is allowed for synced-account UI — the
/// header stays provider-agnostic. `hasCredential` is injected because
/// credential presence (Alchemy key / exchange token) is not derivable
/// from `Account`.
struct SyncableAccountPresentation: Sendable {
  let identifier: String
  /// Secondary line (crypto: chain name, e.g. "Ethereum" — preserves the
  /// context the removed `Text(chain.displayName)` row gave; exchange: nil).
  let secondaryIdentifier: String?
  /// Crypto addresses are copyable (security-critical); a provider name is not.
  let isSelectableIdentifier: Bool
  let externalURL: URL?
  /// `nil` when there is no external action (no empty-string sentinel).
  let externalActionTitle: String?
  /// Non-nil when the account can't sync because its credential is absent.
  let missingCredentialHint: String?
  /// Drives the header's sync-button enabled state for any account kind.
  let hasCredential: Bool

  init(account: Account, hasCredential: Bool) {
    self.hasCredential = hasCredential
    switch account.type {
    case .crypto:
      let addr = account.walletAddress ?? ""
      identifier = addr.count > 12
        ? "\(addr.prefix(6))…\(addr.suffix(4))" : addr
      secondaryIdentifier = account.chainId
        .flatMap(ChainConfig.config(for:))?.displayName
      isSelectableIdentifier = true
      externalActionTitle = "Open in block explorer"
      if let chainId = account.chainId, !addr.isEmpty {
        // Reuse the existing helper (handles isDirectory:false / trailing
        // slash correctly) instead of hand-building the path.
        externalURL = BlockExplorerLink.addressURL(
          chainId: chainId, address: addr)
      } else {
        externalURL = nil
      }
      missingCredentialHint = hasCredential ? nil
        : "Add your Alchemy API key in Settings to auto-import on-chain activity."
    case .exchange:
      secondaryIdentifier = nil
      isSelectableIdentifier = false
      if let provider = account.exchangeProvider {
        identifier = provider.displayName
        externalActionTitle = "Open \(provider.displayName)"
        externalURL = provider.website
      } else {
        // Defensive: well-formed exchange accounts always have a provider.
        identifier = "Exchange"
        externalActionTitle = nil   // no URL ⇒ no title (no dangling label)
        externalURL = nil
      }
      missingCredentialHint = hasCredential ? nil
        : "Add your read-only API token in account settings to sync."
    default:
      identifier = ""
      secondaryIdentifier = nil
      isSelectableIdentifier = false
      externalActionTitle = nil
      externalURL = nil
      missingCredentialHint = nil
    }
  }
}
```

> Use `BlockExplorerLink.addressURL(chainId:address:)` (`Shared/CryptoImport/BlockExplorerLink.swift`) — reconcile its exact signature. The crypto `missingCredentialHint` string must be the **verbatim** existing copy from `WalletAccountHeaderView` (the missing-Alchemy-key hint, ≈`:138`) so the crypto hint is byte-identical to today — replace the placeholder string above with the real one when reconciling (and if the existing copy is reworded, update `CryptoSettingsView` + `WalletAccountHeaderView` together).

- [ ] **Step 4: Run tests**

Run: `just test SyncableAccountPresentationTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Features/Sync/SyncableAccountPresentation.swift MoolahTests/Features/Sync/SyncableAccountPresentationTests.swift
git commit -m "feat: SyncableAccountPresentation (identifier + open-externally seam)"
```

---

#### 11B — Delete the crypto-accounts list from Settings

The Settings → Crypto panel embeds a per-account list that duplicates the account-detail header. Remove it; keep all global config sections.

- [ ] **Step 1: Remove the embedded list**

In `Features/Settings/CryptoSettingsView.swift`, delete the list block (currently `:43-46`):

```swift
if let accountStore, let cryptoSyncStore {
  CryptoAccountsListSection(
    accountStore: accountStore, syncStore: cryptoSyncStore)
}
```

Leave `alchemyApiKeySection`, `tokenInboxNavigationSection`, `tokenListSection`, `coinGeckoApiKeySection` untouched. Remove any now-unused `accountStore`/`cryptoSyncStore` parameters/properties from `CryptoSettingsView` **only if** nothing else in the file uses them (grep within the file first; the Alchemy section may still need `cryptoSyncStore` for its status badge — if so, keep the property and only delete the list block).

- [ ] **Step 2: Delete `CryptoAccountsListSection`**

`git rm Features/Crypto/CryptoAccountsListSection.swift` and any dedicated test file. Grep `CryptoAccountsListSection` to confirm no remaining references.

- [ ] **Step 3: Build**

Run: `just build-mac`
Expected: green (the only consumer was the settings panel).

- [ ] **Step 4: Commit**

```bash
git add Features/Settings/CryptoSettingsView.swift Features/Crypto/ MoolahTests/
git commit -m "refactor: remove crypto-accounts list from Settings (control lives in account view)"
```

---

#### 11C — Generalise `WalletAccountHeaderView` → `SyncedAccountHeaderView`

The crypto account-detail header (`WalletAccountHeaderView` + `WalletAccountHeaderLogic`, used by `CryptoWalletAccountView.swift:56-67`) already renders the last-synced caption, "Sync now" button, error caption and missing-key hint. Generalise it to serve both crypto and exchange — this is *the* shared sync control.

- [ ] **Step 1: Rename (mechanical) + characterisation baseline**

`WalletAccountHeaderLogic` is **not** a separate file — it is an `enum` defined inside `WalletAccountHeaderView.swift` (≈ line 267). First **extract** it: create `Features/Sync/SyncedAccountHeaderLogic.swift`, move the `WalletAccountHeaderLogic` enum into it renamed `SyncedAccountHeaderLogic`. Then `git mv Features/Crypto/WalletAccountHeaderView.swift Features/Sync/SyncedAccountHeaderView.swift` and rename the view type `WalletAccountHeaderView` → `SyncedAccountHeaderView`. (Do **not** `git mv` a non-existent `WalletAccountHeaderLogic.swift` — that command fails.) Update references (grep both type names). Build:

Run: `just build-mac`
Expected: green (pure rename).

- [ ] **Step 2: Run existing crypto header tests (baseline)**

Run: `just test SyncedAccountHeaderLogic` (renamed crypto header tests)
Expected: PASS — this is the behaviour the refactor must preserve.

- [ ] **Step 3: Make the header provider-agnostic**

In `SyncedAccountHeaderView`:
- **Compute `hasCredential` via a concrete synchronous helper on `SyncedAccountHeaderLogic`** (NOT `async`; NOT a bare `try?`). `SyncedAccountHeaderLogic` (renamed from `WalletAccountHeaderLogic`, an `enum`) has no logger today — **add** `private static let logger = Logger(subsystem: "com.moolah.app", category: "SyncedAccountHeaderLogic")` (referenced below). The view must NOT call this in `var body` (keychain read on every render/scroll frame); call it once via `.task(id: account.id)` into `@State private var hasCredential = true` (default `true` avoids a "missing token" flash before the task runs and matches the optimistic-on-error intent):

```swift
// SyncedAccountHeaderView:
@State private var hasCredential = true
// … body uses `presentation` built with `hasCredential` …
.task(id: account.id) {
  hasCredential = SyncedAccountHeaderLogic.hasCredential(
    for: account, tokenStore: tokenStore)
}

// On SyncedAccountHeaderLogic — synchronous; invoked from .task, not body.
static func hasCredential(
  for account: Account, tokenStore: ExchangeTokenStore
) -> Bool {
  switch account.type {
  case .crypto:
    return hasAlchemyApiKey   // reconcile with the real existing check
  case .exchange:
    // Keychain read is synchronous. Return true on error: a locked/
    // unavailable keychain must not nag the user with a "missing token"
    // hint or disable Sync for a token that may well exist.
    do { return (try tokenStore.token(for: account.id)) != nil }
    catch {
      Self.logger.warning(
        "Keychain unavailable for \(account.id, privacy: .public): \(error, privacy: .public)")
      return true
    }
  default:
    return true
  }
}
```

`body` builds `let presentation = SyncableAccountPresentation(account: account, hasCredential: hasCredential)` from the `@State` (refreshed by the `.task` above), NOT by calling the keychain inline. Reconcile the crypto Alchemy-key check + `tokenStore` injection (the header receives `ExchangeTokenStore` the same way it receives `syncStore` — via the session environment).
- Replace every `account.type == .crypto` branch and direct `chainId`/`walletAddress` read with `presentation`.
- **Gate `addressSection` on crypto:** the existing full-address + copy-button section (`WalletAccountHeaderView.swift:169-189`) is correct for crypto and must be **kept unchanged for crypto**, but for an exchange account `walletAddress` is nil and it would render a blank monospaced row with a disabled copy button. Wrap it: `if account.type == .crypto { addressSection }` (exchange's short identifier is the new presentation row below; it has no full address to copy).
- **Remove the `chain: ChainConfig` stored property** from the header (`:30`) — it has no meaning for exchange. Update the one call site `CryptoWalletAccountView` (≈`:56-67`) to stop passing `chain:`. **Do not silently drop the chain name** (`Text(chain.displayName)` `:95`) — that is an information regression for crypto users (someone with both an Ethereum and a Polygon wallet must still distinguish them). Preserve it via `SyncableAccountPresentation`: add a `secondaryIdentifier: String?` field — for crypto it is `ChainConfig.config(for: chainId)?.displayName` (resolve from `chainId`, not the removed stored `chain`), for exchange it is `nil`. Render it in the header's identifier `HStack` (e.g. `if let s = presentation.secondaryIdentifier { Text(s)… }`). Add the field + a crypto/exchange test to `SyncableAccountPresentationTests` (Task 11A).
- **Remove (do not leave duplicated) the `overflowMenu`** (`WalletAccountHeaderView.swift:212-232`). Its only item is "View on block explorer", which the new presentation-driven inline `Link("Open in block explorer", …)` now renders for crypto — keeping the overflow menu would show two controls with the identical destination. Remove `overflowMenu` and its slot in the header `HStack` (`:107`). (Exchange never had it.) If the implementer believes a future menu item justifies keeping the ellipsis, that is a separate decision — for this task the single-item menu is redundant and must go.
- Keep the **last-synced caption and "Sync now" button code verbatim** — they already read `syncStore.statePerAccount`/`inProgressAccountIds` and call `syncStore.syncAccount`, which now cover exchange too.
- The existing sync-enabled predicate (`WalletAccountHeaderLogic.isSyncEnabled(...)` took a crypto-only `hasApiKey: Bool`) must take `presentation.hasCredential` instead — rename the parameter to `hasCredential`, update both call sites and the renamed `SyncedAccountHeaderLogic` tests. Sync button stays disabled when `!hasCredential`.
- **Generalise the sync button's `.help()` and `.accessibilityLabel`** — the existing `"Sync wallet now"` / `"Add an Alchemy API key to enable sync"` are crypto-only. Use: `.accessibilityLabel("Sync account now")` and `.help(presentation.hasCredential ? "Sync account now" : (presentation.missingCredentialHint ?? "Configure this account to enable sync"))`.
- Replace the crypto-only "missing API key" hint row with `presentation.missingCredentialHint` (nil ⇒ no row). **Preserve the crypto deep-link:** the existing hint has a macOS `SettingsLink { Text("Open preferences") }` (`:134-156`) — keep that affordance for `.crypto` accounts (a crypto user fixes the missing key in Preferences). For `.exchange` there is no `SettingsLink` (the fix is editing the account, surfaced elsewhere). Gate the `SettingsLink` with `if account.type == .crypto` next to the hint `Text` — the hint string comes from `presentation.missingCredentialHint`; only the crypto-specific `SettingsLink` is account-type-gated.
- **Generalise `errorCaption(for:)`** (`SyncedAccountHeaderLogic`, was `WalletAccountHeaderLogic` ≈`:317-337`). It currently returns Alchemy-specific strings for `.invalidApiKey` ("Alchemy rejected the API key.") and `.missingApiKey` ("Add an Alchemy API key to enable sync."). After this task an exchange account persists those same errors, so a Coinstash user with a bad token would see "Alchemy rejected the API key." Make `errorCaption` account-type-aware: pass the `Account` (or `AccountType` + provider display name) and return provider-appropriate copy for the two key cases (crypto → existing Alchemy strings unchanged; exchange → e.g. "\(provider.displayName) rejected the API token." / "Add your read-only API token to sync." — interpolate `ExchangeProvider.displayName`, never the raw enum). Update its call site and the renamed `SyncedAccountHeaderLogic` tests. The generic non-key `WalletSyncState.lastError` captions are unchanged.
- Add `.keyboardShortcut("r", modifiers: .command)` to the "Sync now" button — but **first grep `TransactionListView` (and the other toolbar items in the same detail leaf) for an existing `Cmd+R`/`.keyboardShortcut("r"`** binding. If one exists (the leaf's `NavigationStack` would make them conflict), use `.command` + `.shift` (Cmd+Shift+R) instead, or omit the shortcut and note it deferred. Do not introduce a duplicate `Cmd+R` in the same responder chain.
- Add the identifier + "open externally" row (gate `textSelection` with the bool — no `_ConditionalContent` on a pre-bound `let`, which does not compile):

```swift
// existing header title / last-synced caption (UNCHANGED) …
// Guard the whole row: identifier is "" for non-sync types (the
// `default` SyncableAccountPresentation case is a tested reachable state)
// — an empty Text would still occupy layout.
if !presentation.identifier.isEmpty {
  HStack {
    Text(presentation.identifier)
      .font(.caption).foregroundStyle(.secondary)
      // crypto address copyable (security); provider name not — single Text,
      // bool-gated modifier (NOT a let-bound view across an if/else).
      .textSelection(presentation.isSelectableIdentifier ? .enabled : .disabled)
    if let secondary = presentation.secondaryIdentifier {
      Text(secondary)                       // crypto chain name (e.g. "Ethereum")
        .font(.caption).foregroundStyle(.secondary)
    }
    if let url = presentation.externalURL, let title = presentation.externalActionTitle {
      Link(title, destination: url).font(.caption)
    }
  }
  // One VoiceOver stop for identifier + chain (the external Link stays a
  // separate focusable action). Compose a sensible label; do NOT combine
  // the Link into the element (it must remain individually actionable).
  .accessibilityElement(children: .combine)
}
// existing "Sync now" button (UNCHANGED apart from .keyboardShortcut + generalised help/label) …
```

Add a concrete exchange `#Preview` alongside the existing crypto one:

Provide **concrete** preview wiring (a comment placeholder makes the header render as an empty/`nil`-store view and hides bugs). Mirror `CryptoWalletAccountView.swift:91-103` verbatim — create the preview session, inject it, wrap in `NavigationStack`:

```swift
#Preview("Exchange — missing token") {
  let session = try! ProfileSession.preview()        // real preview helper
  return NavigationStack {
    SyncedAccountHeaderView(
      account: Account(name: "Coinstash", type: .exchange, instrument: .AUD,
        exchangeProvider: .coinstash))
  }
  .previewProfileEnvironment(session: session)        // real env helper
}
#Preview("Exchange — synced") {
  let account = Account(name: "Coinstash", type: .exchange,
    instrument: .AUD, exchangeProvider: .coinstash)
  let session = try! ProfileSession.preview()
  // Concrete seed (no placeholder): store a token + a recent sync state so
  // the header renders the credentialled/synced layout, not "missing token".
  try? ExchangeTokenStore(synchronizable: false).save(token: "PREVIEW", for: account.id)
  session.syncStore.statePerAccount[account.id] = WalletSyncState(
    id: account.id, lastSyncedBlockNumber: 0,
    lastSyncedAt: .now, lastError: nil)
  return NavigationStack {
    SyncedAccountHeaderView(account: account)
  }
  .previewProfileEnvironment(session: session)
}
```

> Reconcile `ProfileSession.preview()` / `.previewProfileEnvironment(session:)` / `session.syncStore` / the preview token-store wiring with the exact helpers `CryptoWalletAccountView.swift:91-103` uses (these names are illustrative — match the real preview API). The point: the "synced" preview must actually seed a token + non-`distantPast` `lastSyncedAt`, not a comment.

> Reconcile against the real `SyncedAccountHeaderView` body (was `WalletAccountHeaderView.swift:11-125`, sync button `:191-210`, `.help`/`.accessibilityLabel` `:207-208`, lastSynced `:77-100`, error caption `:114-118`, missing-key hint `:134-156`, `chain` property `:30` + `Text(chain.displayName)` `:95`). Wrap previews in `NavigationStack` exactly as `CryptoWalletAccountView.swift:92-103` does (with the project's preview profile-environment helper), so toolbar/searchable layout is exercised in canvas. Do not rewrite the caption/button.

- [ ] **Step 4: Re-run characterisation + presentation tests**

Run: `just test SyncedAccountHeaderLogic` then `just test SyncableAccountPresentationTests`
Expected: PASS — crypto header unchanged; presentation covers both types incl. `missingCredentialHint`.

- [ ] **Step 5: Commit**

```bash
git add Features/Sync/ Features/Crypto/ MoolahTests/
git commit -m "refactor: SyncedAccountHeaderView (generalised from WalletAccountHeaderView)"
```

---

#### 11D — Route `.exchange` accounts to a detail view using the shared header

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Moolah

@MainActor
struct ExchangeAccountViewRoutingTests {
  @Test func contentViewRoutesExchangeToExchangeAccountView() {
    // Mirror existing ContentView.accountDetail routing tests (grep for the
    // crypto-route test) and assert the .exchange case resolves to
    // ExchangeAccountView. If routing has no unit test, assert instead that
    // ExchangeAccountView builds with an exchange account + the shared header.
    let account = Account(name: "Coinstash", type: .exchange,
      instrument: .AUD, exchangeProvider: .coinstash)
    #expect(account.type == .exchange)  // placeholder until routing harness reconciled
    _ = ExchangeAccountView(account: account /* + injected stores per real init */)
  }
}
```

> Reconcile with how `ContentView.accountDetail(id:)` is tested today (it switches at `ContentView.swift:348`). If there is no routing unit test, keep this as a build/compile guard and rely on Step 5 manual verification. `ExchangeAccountView` takes the stores its siblings take — reconcile the init.

- [ ] **Step 2: Run test to verify it fails**

Run: `just test ExchangeAccountViewRoutingTests`
Expected: FAIL — `ExchangeAccountView` undefined / no `.exchange` route.

- [ ] **Step 3: Create `ExchangeAccountView`**

Exchange is investment-like: compose the shared header over the same positions/valuation body the investment account uses. Open `Features/.../InvestmentAccountView.swift` and `Features/Crypto/CryptoWalletAccountView.swift:34-67` (it stacks `SyncedAccountHeaderView` above the transaction/positions list in a `VStack(spacing: 0)`); mirror that structure exactly.

```swift
import SwiftUI

/// Detail view for a `.exchange` account. Investment-like body + the shared
/// synced-account header. NOTE: this view must NOT contain its own
/// `NavigationStack` — the enclosing `NavigationStack` is provided by
/// `ContentView.detail` (`.id(selection)`-wrapped). A nested NavigationStack
/// here fires the duplicate-toolbar assertion. (Same contract as
/// `CryptoWalletAccountView`'s doc comment.)
struct ExchangeAccountView: View {
  let account: Account
  // inject the same stores CryptoWalletAccountView/InvestmentAccountView use
  var body: some View {
    VStack(spacing: 0) {
      SyncedAccountHeaderView(account: account /* + syncStore binding */)
      // reuse the investment-like positions/transactions body for this account
      // (the same subview InvestmentAccountView renders; do not fork it)
    }
  }
}

#Preview {
  // Concrete wiring (NOT a comment placeholder — a store-less preview
  // renders empty and hides layout/toolbar bugs). Mirror
  // CryptoWalletAccountView.swift:91-103 verbatim. The runtime
  // NavigationStack comes from ContentView.detail; the view must not embed
  // one — the wrapper here is preview-only.
  let session = try! ProfileSession.preview()
  return NavigationStack {
    ExchangeAccountView(account: Account(
      name: "Coinstash", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash))
  }
  .previewProfileEnvironment(session: session)
}
```

> Reconcile `ProfileSession.preview()` and `.previewProfileEnvironment(session:)` (and how `ExchangeAccountView` receives its stores — via the session environment, like `CryptoWalletAccountView`) with the exact helpers at `CryptoWalletAccountView.swift:91-103`.

> Do not duplicate the investment body — render the same positions/transactions subview `InvestmentAccountView` uses. If that body is not already an extractable subview, extract it once and have both `InvestmentAccountView` and `ExchangeAccountView` consume it (de-dup, not copy). Add the `.exchange` `case` at the **same `@ViewBuilder` level** as `case .crypto:`/`.investment:` in `accountDetail(id:)` (Step 4) — never inside a new wrapping `NavigationStack`.
>
> Valuation note (Rule 6): reusing the investment body means exchange valuation flows through `InvestmentStore.loadTradesBranch`, which calls `valuatePositions(profileCurrency:, on: Date())` — current-date conversion, correct per the instrument-conversion guide. This plan adds **no new conversion call site**, so no new `DateBasedFixedConversionService` test is required; date correctness is inherited from `InvestmentStore`'s existing tests. Stated explicitly so a future `loadTradesBranch` refactor doesn't silently change the exchange path's conversion date.

- [ ] **Step 4: Add the route**

In `App/ContentView.swift` `accountDetail(id:)` switch (`:348`), add before `default`:

```swift
    case .exchange:
      ExchangeAccountView(account: account /* + stores, matching siblings */)
```

- [ ] **Step 5: Build + tests + manual verification**

Run: `just build-mac` then `just test ExchangeAccountViewRoutingTests`
Expected: build green; PASS.

REQUIRED SUB-SKILL: `run-mac-app-with-logs`. Verify in the running app:
- Settings → Crypto: no account list, Alchemy/CoinGecko config still present and working.
- Existing crypto account detail: header identifier = truncated address, "Open in block explorer" works, caption + "Sync now" + error/missing-key hint unchanged.
- New Coinstash exchange account detail: same shared header (identifier = "Coinstash", "Open Coinstash" → website, "Sync now" works), investment-like valuation derived from positions, transactions imported.
(UI/feature correctness cannot be asserted by unit tests — verify in the running app.)

- [ ] **Step 6: Commit**

```bash
git add App/ContentView.swift Features/Exchange/ExchangeAccountView.swift Features/ MoolahTests/
git commit -m "feat: exchange account detail view via shared synced-account header"
```

---

### Task 12: Edit account — exchange section (re-enter token)

**Files:**
- Create: `Features/Exchange/EditExchangeTokenLogic.swift`
- Modify: `Features/Accounts/Views/EditAccountView.swift:194-244`
- Test: `MoolahTests/Features/Exchange/EditExchangeAccountTests.swift`

`EditAccountView` already conditionally renders type-specific sections (`valuationSection` shows only for `.investment`, `:194-216`). Add an `exchangeSection` shown only for `.exchange`: read-only provider label + a `SecureField` to **replace** the token (empty = leave unchanged), saved via `ExchangeTokenStore` on save. Do not surface the token value (write-only field).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Moolah

@MainActor
struct EditExchangeAccountTests {
  @Test func replacingTokenUpdatesKeychainOnly() async throws {
    let harness = try ExchangeCreationHarness()
    let logic = ExchangeAccountCreationLogic(
      accountStore: harness.accountStore, tokenStore: harness.tokenStore,
      syncStore: nil, profileInstrument: .AUD)
    guard case .created(let acct) = await logic.submit(
      name: "C", provider: .coinstash, token: "OLD") else {
      Issue.record("setup failed"); return
    }
    try EditExchangeTokenLogic.applyTokenChange(
      newToken: "NEW", accountId: acct.id, tokenStore: harness.tokenStore)
    #expect(try harness.tokenStore.token(for: acct.id) == "NEW")
  }

  @Test func emptyTokenLeavesExistingUnchanged() throws {
    let harness = try ExchangeCreationHarness()
    let id = UUID()
    try harness.tokenStore.save(token: "KEEP", for: id)
    try EditExchangeTokenLogic.applyTokenChange(
      newToken: "  ", accountId: id, tokenStore: harness.tokenStore)
    #expect(try harness.tokenStore.token(for: id) == "KEEP")
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test EditExchangeAccountTests`
Expected: FAIL — `EditExchangeTokenLogic` undefined.

- [ ] **Step 3: Implement the small logic helper + view section**

Create `Features/Exchange/EditExchangeTokenLogic.swift` (own file — one primary type per file; it is not a DTO family or single-consumer delegate, so it does not belong inside the creation-view file):

```swift
import Foundation

// No @MainActor: this is a pure synchronous keychain call with no
// main-actor state; isolating it would force non-main callers to await
// a synchronous function for no reason. ExchangeTokenStore is Sendable.
enum EditExchangeTokenLogic {
  /// Empty/whitespace token = leave the stored token untouched.
  static func applyTokenChange(
    newToken: String, accountId: UUID, tokenStore: ExchangeTokenStore
  ) throws {
    let trimmed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    try tokenStore.save(token: trimmed, for: accountId)
  }
}
```

In `EditAccountView.swift`, add (mirroring `valuationSection`'s `@ViewBuilder` + `if type == ...` pattern at `:194-216`):

```swift
  @ViewBuilder private var exchangeSection: some View {
    if type == .exchange {
      Section {
        LabeledContent("Exchange",
          value: account.exchangeProvider?.displayName ?? "—")
        SecureField("New token", text: $replacementToken)
          .accessibilityLabel("Replace API token")
          .accessibilityIdentifier(
            UITestIdentifiers.EditAccount.exchangeAccessTokenField)
      } footer: {
        // Plain Text (every other footer in the codebase is Text; no icon).
        // No .foregroundStyle(.secondary) — footers are already secondary.
        // State the non-obvious empty-means-keep behaviour at the field.
        Text("Enter a new read-only token to replace the stored one. "
          + "Leave blank to keep the existing token.")
      }
    }
  }
```

Add `@State private var replacementToken = ""`, render `exchangeSection` next to `valuationSection`. In the save path (`:224-244`) call `try EditExchangeTokenLogic.applyTokenChange(newToken: replacementToken, accountId: account.id, tokenStore: tokenStore)` **before** `accountStore.update(updated)`, inside the existing `do`/`catch` (so a token-save failure aborts the save and surfaces via `errorMessage` *before* the account row is mutated — no partially-applied save where the name changed but the token didn't). **Token-store injection:** grep how `EditAccountView` reaches session-owned stores today — if it uses `@Environment(ProfileSession.self)` (like the other stores in that file), read `ExchangeTokenStore` from the session/environment and add **no** new `init` parameter (adding one breaks every `EditAccountView(account:accountStore:)` call site). Only thread a new parameter if the file's established pattern is constructor injection; in that case, update all call sites and say so explicitly. Add `UITestIdentifiers.EditAccount.exchangeAccessTokenField` to the `UITestIdentifiers` namespace — **distinct** from `UITestIdentifiers.ExchangeAccountCreation.accessTokenField` (duplicate identifiers break XCUITest matching). Add an exchange-account variant to `EditAccountView`'s existing `#Preview`.

- [ ] **Step 4: Run tests + build**

Run: `just test EditExchangeAccountTests` then `just build-mac`
Expected: PASS; green.

- [ ] **Step 5: Commit**

```bash
git add Features/Accounts/Views/EditAccountView.swift Features/Exchange/EditExchangeTokenLogic.swift MoolahTests/Features/Exchange/EditExchangeAccountTests.swift
git commit -m "feat: edit exchange account token"
```

---

## Final verification (before PR)

- [ ] `just build-mac` — green
- [ ] `just test` — full suite green (esp. GRDB plan-pin + CloudKit mapping)
- [ ] `just check-schema-additive` — additive
- [ ] `DataFormatVersion.current == 2` with the v2 History entry present (Task 1 Step 6); `DataFormatVersionTests` + `DataFormatVersionBumpTests` green
- [ ] `just format-check` — clean (if it fails, use the `fixing-format-check` skill; never re-baseline)
- [ ] Manual: create a real Coinstash exchange account end-to-end via `run-mac-app-with-logs`; confirm derived valuation, sync caption, "Sync now", and that deleting the account also clears its keychain token and `wallet_sync_state` row (add token cleanup to the account-delete path if the crypto delete path does the analogous `WalletSyncStateRepository.delete` — grep the account deletion code and mirror it; add a Task + test if missing).
- [ ] Code review against `guides/CODE_GUIDE.md`, `CONCURRENCY_GUIDE.md`, `DATABASE_*`, `SYNC_GUIDE.md` (use the matching review subagents).

---

## Self-Review Notes

- **Spec coverage:** new `.exchange` type + `DataFormatVersion` 1→2 forward-incompat gate with History entry (T1), persistence (T2), CloudKit (T3), per-account token (T4), Coinstash API (T5–T6), mapping (T7–T8), **unified** sync orchestration via `AccountSyncSource` + `SyncedAccountStore` (T9, no parallel store), **unified** sync control: Settings list deleted + `WalletAccountHeaderView` generalised to `SyncedAccountHeaderView` + `SyncableAccountPresentation`, shared by crypto + exchange detail views, with `.exchange` routed in `ContentView` (T11), investment-like valuation (reuses existing `.isInvestmentLike` + positions path, no new code — verified via T1 + manual), creation UI with help link (T10), edit (T12). All covered.
- **De-dup verification:** the only net-new external API is `ExchangeClient`/`CoinstashClient`. `WalletApplyEngine`, `WalletSyncState`, `WalletSyncStateRepository`, `BuiltTransaction`, the last-synced formatter, the "Sync now" button, the staleness loop, and the investment positions body are reused, not reimplemented. Crypto behaviour is protected by characterisation tests run before/after the T9C (store) and T11C (header) refactors.
- **Known reconciliations the implementer MUST do** (flagged inline, not placeholders — they are "match the verbatim signature" instructions): real `Instrument` AUD accessor; `InstrumentRegistryRepository` symbol-lookup method; `Transaction`/`TransactionLeg` initialisers; `WalletApplyEngine.AccountInput` namespacing; `WalletSyncError` case names; `WalletSyncEngine` concrete-vs-protocol (introduce `WalletSyncBuilding` if concrete); original `CryptoSyncStore` `globalError`/`scheduleInitialSync` semantics; `ChainConfig` block-explorer URL helper; `AccountRepository`/`TransactionRepository` protocol names; account-delete cleanup parity (token + `wallet_sync_state`). Each names the exact source file:line to copy from.
- **Type consistency:** `AccountSyncSource`, `WalletSyncSource`, `CoinstashSyncSource`, `SyncedAccountStore` (renamed from `CryptoSyncStore`), `SyncedAccountHeaderView`/`SyncedAccountHeaderLogic` (renamed from `WalletAccountHeaderView`/`WalletAccountHeaderLogic`), `SyncableAccountPresentation`, `ExchangeAccountView`, `ExchangeImportedTransaction`, `ExchangeClient`, `ExchangeSyncEngine`, `ExchangeTokenStore`, `ExchangeAccountCreationLogic` (param `syncStore: SyncedAccountStore?`) used consistently across all tasks; `WalletSyncBuildResult`/`BuiltTransaction`/`WalletApplyEngine.AccountInput` reused exactly as the research reported them. No `ExchangeSyncStore`/`ExchangeAccountsListSection` (the rejected parallel types) remain.
- **Five reviewer passes applied.** Pass 5 fixed: `TransactionLeg.init` missing required `type:` (added a `category→legType` map: DEPOSIT/AWARD→.income, WITHDRAW→.expense, else .trade); `ExchangeInstrumentResolver` now `throws` + logs (was `try?`-swallowing registry errors → misdiagnosed every symbol as unknown) and is `instrument(forSymbol:isFiat:)`; `ExchangeDirection.multiplier` (no `.rawValue` in business logic); plan-wide convention added that there is no `Instrument.eth`/`.opStub`/`StubRegistry` — all test samples now use `Instrument.crypto(...)` + the existing `StubInstrumentRegistry`; leg-dedup plan-pin rewritten to use `PlanPinningTestHelpers`; Task 9C made concrete (delete `walletSyncEngine` prop+capture; `accountsToSync` drops all three crypto-field guards; `buildOne` shows the retained `AccountInput`; `PerAccountBuildResult.failed` gains `AccountType` so `globalError` is genuinely crypto-scoped); `Account`'s custom `Codable`/`Equatable`/`Hashable` bodies updated for `exchangeProvider` (not just `CodingKeys`); `SyncedAccountHeaderLogic` gains a `logger` and `hasCredential` is read via `.task(id:)`+`@State` (not the keychain in `body`); `CryptoSettingsView.cryptoSyncStore` retyped to `SyncedAccountStore?`; `BlockExplorerLink.addressURL` reused; `errorCaption` interpolates `provider.displayName`; crypto `missingCredentialHint` pinned verbatim; help-link `frame(minHeight:44)`; provider Picker + `Field.exchangeToken` + `namePrompt` `.exchange` branch; identifier-row `accessibilityElement(.combine)`; `ExchangeCreationHarness`/`addSource` scaffolding clarified.
- **Four reviewer passes applied.** Pass 4 fixed: `Instrument.aud`→`.AUD` (17 sites, compile errors) + creation logic now takes the profile's `instrument` not hardcoded; `InstrumentRegistryRepository` has no `instrument(forSymbol:)` — resolver now scans `all()` by `ticker`/`kind`; `buildOne` keeps `priorState` (dropping it reset crypto watermarks → genesis re-fetch regression); `globalError` scoped to crypto so the Settings Alchemy badge isn't contaminated by exchange token errors; `errorCaption(for:)` generalised (was showing "Alchemy rejected the API key" for Coinstash); `overflowMenu` removed (duplicated the new inline explorer link); chain name preserved via `SyncableAccountPresentation.secondaryIdentifier` (was an info regression); `// SyncBoundary` marker moved to file scope; `SecureField` un-wrapped from `LabeledContent` (double-label); previews use `@Previewable @State` + concrete synced seed; `hasCredential` given a concrete synchronous helper; `WalletSyncBuilding: Sendable` + `ChainConfig: Sendable` check; `DataFormatVersion` test pinned `== 2`; golden-schema confirmation step; leg-dedup plan-pin made unconditional (existing test covers a different query shape); schema.ckdb `SEARCHABLE` CI gate; `Cmd+R` conflict check; ISO-formatter no-static note. One pass-4 "Critical" (`toCKRecord` ignoring `encodedSystemFields`) was verified a **false positive** — `ProfileDataSyncHandler.buildCKRecord` handles system fields by design; documented in the plan so it isn't wrongly "fixed".
- **Three reviewer passes applied.** Pass 3 caught real defects introduced by pass-2 edits: the non-existent `ProfileSchema.migratorThroughV10` (replaced with an inline `migratorThroughV10()` helper registering v1..v10 by their real ids); `WalletAccountHeaderLogic` is an enum *inside* `WalletAccountHeaderView.swift`, not a separate file (extract-then-mv, not a `git mv` of a non-existent file); `ExchangeAccountCreationView` carried dead `logic`/`onResult`/`name` params (removed — view renders only its Section); `addressSection` not gated for crypto (would show a blank row for exchange — now `if account.type == .crypto`); the crypto `SettingsLink` was being dropped when the missing-credential hint was generalised (now preserved, gated to crypto); `WalletSyncBuilding` needed `: Sendable`; `ExchangeClient.swift` split into 4 one-type files; `@MainActor` removed from `EditExchangeTokenLogic`; rollback-delete failure now logged; token-save ordered before `accountStore.update` in edit; concrete preview wiring (no comment placeholders); empty-identifier header row guarded; private lets / static `pageSize`; `Task.checkCancellation` between the two pre-loop queries; migration tests use `queue` + `DatabaseError.resultCode` assertion; leg-dedup plan-pin test body supplied; sync doc-comment scope extended to `load(accountId:)`; exact-`Decimal` assertion added; mandatory schema-attribute verification; Task 11D Date()-inheritance note. Remaining reviewer items are explicitly-optional style suggestions the reviewers said not to mandate (one-field DTO mirrors the wire shape; `Section`-rooted view matches the existing `CryptoAccountCreationView` convention).
- **Two reviewer passes applied.** Pass 2 additionally fixed: the hard-coded `account.type == .crypto` guards in `syncAccount`/`syncAccounts` + `buildOne` signature (exchange would never sync otherwise); Task 9E use-before-init harness + missing `fiatInstrument` (live wiring uses `profileSession.profile.instrument`, not hardcoded AUD); full encode/decode code blocks + encode test for the CloudKit field; `ExchangeProvider` `// SyncBoundary` marker + force-unwrap-suppressed URL constants; `map` drops (not `.distantPast`/silent `.debit`) on bad date / unknown type with logging; flattened `CoinstashUserAccountsData` nesting; migration tests synchronous + bound `Data` ids + correct partial-migrator + stronger rollback asserts; `WalletSyncSource.chains` actually used; explicit `, Sendable`; `Task.checkCancellation` in the engine loops; UI: compiling `textSelection` ternary, `NavigationStack`-wrapped previews, `SecureField` `.accessibilityLabel`, generalised sync-button help/label, `chain` removal from the header, `isValid`/`isSubmitting` exchange branches, token-save rollback, provider-neutral footer copy, repo doc comments neutralised, removed the bogus JSONValue swiftlint note.
- **Reviewer pass 1 applied:** schema/GRDB (full v8-exact DDL with STRICT/UNIQUE/CHECKs/indexes, `ProfileSchema.version`→11, `CodingKeys`, rollback test, 16-byte blobs), money precision (`amount: Decimal`, not `Double`), `ExchangeDirection` enum, no-`try?`-swallow on keychain/save, source-driven store via in-place edits (no `syncAccount` rewrite; `scheduleInitialSync`/`updateGlobalError` preserved), `loadInitialState` naming, per-call ISO formatter, 429 handling, `Task.checkCancellation` in pagination, `os.Logger` + whole-group drop in `ExchangeSyncEngine`, injected `fiatInstrument`, `JSONValue`/`EditExchangeTokenLogic` own files, provider-driven help link, `SecureField` labelled, no `NavigationStack` in `ExchangeAccountView`, `hasCredential`/`isSelectableIdentifier`/`missingCredentialHint` on the presentation, distinct UITest identifiers, `#Preview`s, Cmd+R, footer copy/voice. All Critical/Important/Minor from the seven reviewers addressed.
- **Open risk:** Symbol→instrument resolution depends on registry capabilities not fully verified — Task 7 explicitly gates on a grep before coding. The T9C store refactor is the highest-risk step (touches the live crypto sync path) — gated by characterisation tests before/after. No proactive client-side rate limiter (Coinstash publishes no limits; 1–3 pages/account); 429 handled reactively (documented in `CoinstashClient`).
