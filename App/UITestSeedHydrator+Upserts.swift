import Foundation
import GRDB

// Upsert helpers for `UITestSeedHydrator`. Every helper is idempotent:
// re-running the same seed (e.g. after a UI-testing re-launch) doesn't
// double-insert records.
//
// Per-profile data (accounts, transactions, categories, instruments) and
// the profile index itself both live in GRDB. All upserts route through
// the GRDB row types.
extension UITestSeedHydrator {
  // MARK: - Specs
  //
  // Struct wrappers bundle the per-record fields callers provide,
  // keeping the upsert call sites self-documenting.

  struct AccountSpec {
    let id: UUID
    let name: String
    let type: AccountType
    let instrumentId: String
    let position: Int
    /// Defaults to `.recordedValue` to preserve the historic seed
    /// behaviour. Pass `.calculatedFromTrades` for accounts seeded for
    /// the EditAccountView visibility tests.
    let valuationMode: ValuationMode
    /// Optional back-reference into `account_group.id`. `nil` for a
    /// standalone account; set to the owning group's id to make the
    /// account a member (drives the group-scope filter test).
    let groupId: UUID?
    /// `0x…` lowercased wallet address. Required when `type == .crypto`.
    let walletAddress: String?
    /// EVM chain ID (1 = Ethereum). Required when `type == .crypto`.
    let chainId: Int?

    init(
      id: UUID,
      name: String,
      type: AccountType,
      instrumentId: String,
      position: Int,
      valuationMode: ValuationMode = .recordedValue,
      groupId: UUID? = nil,
      walletAddress: String? = nil,
      chainId: Int? = nil
    ) {
      self.id = id
      self.name = name
      self.type = type
      self.instrumentId = instrumentId
      self.position = position
      self.valuationMode = valuationMode
      self.groupId = groupId
      self.walletAddress = walletAddress
      self.chainId = chainId
    }
  }

  struct TradeSpec {
    let id: UUID
    let payee: String
    let date: Date
    let amount: InstrumentAmount
    let fromAccountId: UUID
    let toAccountId: UUID
  }

  struct HistoricalExpenseSpec {
    let id: UUID
    let payee: String
    let date: Date
    let amount: InstrumentAmount
    let accountId: UUID
    let categoryId: UUID?
  }

  struct CustomExpenseSplitSpec {
    let id: UUID
    let payee: String
    let date: Date
    let legAAmount: InstrumentAmount
    let legBAmount: InstrumentAmount
    let accountId: UUID
  }

  /// One imported single-account side of a detected transfer pair. The
  /// transaction has a single value leg and a `.single` import origin
  /// (so it shows in Recently Added). The passive pill is driven by a
  /// separate synced `TransferSuggestion` record seeded once per pair
  /// (via `upsertSuggestedTransferRecord`) over `id` and
  /// `counterpartId` — no detection-timing dependency.
  struct SuggestedTransferSpec {
    let id: UUID
    let payee: String
    let date: Date
    let accountId: UUID
    /// Signed amount in the profile instrument (negative = outflow).
    let amount: InstrumentAmount
    let type: TransactionType
    let counterpartId: UUID
    let suggestedAt: Date
    let importedAt: Date
    let importSessionId: UUID
  }

  // MARK: - Profile (GRDB profile-index DB)

  /// Writes a `ProfileRow` into `profile-index.sqlite`. Idempotent —
  /// `upsert` matches on the primary key, so a re-hydrated seed simply
  /// overwrites with the same values.
  ///
  /// Synchronous because `MoolahApp.init` (the only caller chain) is
  /// not `async`. Goes directly through the manager's
  /// `profileIndexDatabase` queue with the GRDB sync write API rather
  /// than the repository's `async upsert` so the call site stays
  /// synchronous.
  ///
  /// SAFETY: this is a synchronous GRDB write invoked from `@MainActor`
  /// (via `MoolahApp.init`). It is test-only and the profile-index DB
  /// is small (a single row per profile, single-digit row count in
  /// practice), so the main-thread block is sub-millisecond and the
  /// calling-thread block is acceptable here. Production code must not
  /// adopt this pattern.
  static func upsertProfile(
    _ profile: Profile,
    into manager: ProfileContainerManager
  ) throws {
    try manager.profileIndexDatabase.write { database in
      try ProfileRow(domain: profile).upsert(database)
    }
  }

  // MARK: - Per-profile graph (GRDB)

  static func upsertInstrument(_ instrument: Instrument, in database: Database) throws {
    try InstrumentRow(domain: instrument).upsert(database)
  }

  static func upsertAccount(_ spec: AccountSpec, in database: Database) throws {
    let row = AccountRow(
      id: spec.id,
      recordName: AccountRow.recordName(for: spec.id),
      name: spec.name,
      type: spec.type.rawValue,
      instrumentId: spec.instrumentId,
      position: spec.position,
      isHidden: false,
      encodedSystemFields: nil,
      valuationMode: spec.valuationMode.rawValue,
      walletAddress: spec.walletAddress,
      chainId: spec.chainId,
      groupId: spec.groupId)
    try row.upsert(database)
  }

  /// Upserts a `wallet_sync_state` row (`lastErrorJson` must be valid
  /// JSON per the `json_valid` CHECK, or `nil`). Uses `save`, NOT
  /// `upsert`: this table is `WITHOUT ROWID`, and GRDB's `upsert`
  /// appends `RETURNING "rowid"` to fire `didInsert` — SQLite rejects
  /// that on a rowid-less table (`no such column: "rowid"`), which
  /// crashed the app at launch during seed hydration. `save` is the same
  /// idempotent update-or-insert sans `RETURNING`, matching production's
  /// `GRDBWalletSyncStateRepository.save`. SAFETY: sync GRDB write.
  static func upsertWalletSyncState(
    accountId: UUID,
    lastErrorJson: String?,
    in database: Database
  ) throws {
    let row = WalletSyncStateRow(
      accountId: accountId,
      lastSyncedBlockNumber: 0,
      lastSyncedAt: .distantPast,
      lastErrorJson: lastErrorJson)
    try row.save(database)
  }

  struct EarmarkSpec {
    let id: UUID
    let name: String
    let instrumentId: String
    var position: Int = 0
  }

  static func upsertEarmark(_ spec: EarmarkSpec, in database: Database) throws {
    let row = EarmarkRow(
      id: spec.id,
      recordName: EarmarkRow.recordName(for: spec.id),
      name: spec.name,
      position: spec.position,
      isHidden: false,
      instrumentId: spec.instrumentId,
      savingsTarget: nil,
      savingsTargetInstrumentId: nil,
      savingsStartDate: nil,
      savingsEndDate: nil,
      encodedSystemFields: nil)
    try row.upsert(database)
  }

  struct AccountGroupSpec {
    let id: UUID
    let name: String
    /// `AccountBucket.rawValue` — `"current"` or `"investments"`. Stored
    /// raw to mirror the row shape (the v14 migration pinned the column
    /// with a CHECK constraint, see `AccountGroupRow`).
    let bucketRawValue: String
    let instrumentId: String
    let position: Int
  }

  static func upsertAccountGroup(
    _ spec: AccountGroupSpec, in database: Database
  ) throws {
    let row = AccountGroupRow(
      id: spec.id,
      recordName: AccountGroupRow.recordName(for: spec.id),
      name: spec.name,
      bucket: spec.bucketRawValue,
      instrumentId: spec.instrumentId,
      position: spec.position,
      encodedSystemFields: nil)
    try row.upsert(database)
  }

  /// Inserts a single `InvestmentValue` snapshot for an investment
  /// account. Idempotent — if a row with the same id already exists
  /// (e.g. on re-hydration), `upsert` overwrites with the same values.
  /// Synchronous for the same reason as the rest of this file:
  /// `UITestSeedHydrator.hydrate` runs synchronously during
  /// `MoolahApp.init`, before any actor or `Task` is in scope.
  static func upsertInvestmentValue(
    _ spec: UITestInvestmentValueSeed,
    in database: Database
  ) throws {
    let row = InvestmentValueRow(
      id: spec.id,
      recordName: InvestmentValueRow.recordName(for: spec.id),
      accountId: spec.accountId,
      date: spec.date,
      // Cents are quantity × 10^2; `InstrumentAmount.storageValue` is
      // quantity × 10^8 — so multiply by 10^6 (1_000_000) to convert.
      value: Int64(spec.cents) * 1_000_000,
      instrumentId: spec.instrumentId,
      encodedSystemFields: nil)
    try row.upsert(database)
  }

  static func upsertCategory(id: UUID, name: String, in database: Database) throws {
    try CategoryRow(domain: Moolah.Category(id: id, name: name)).upsert(database)
  }

  /// Inserts a two-leg `.transfer` transaction. Both legs are `.transfer`
  /// so the transaction satisfies `Transaction.isSimple` (same type,
  /// amounts negate, distinct accounts, no category/earmark on the second
  /// leg). That triggers the simple-mode path in `TransactionDetailView`,
  /// which is what the focus, autocomplete, and cross-currency tests
  /// exercise. Mixed `.expense`/`.income` would render the custom
  /// multi-leg view, where the `defaultFocus(_:_:)` modifier on the simple
  /// section never fires.
  ///
  /// Idempotency comes from the parent-existence guard: if the transaction
  /// already exists in this database (e.g. a re-hydration call), the
  /// helper returns and leg inserts are skipped. The whole seed runs in a
  /// single `database.write { ... }` transaction at the call site, so
  /// partial commits aren't possible.
  static func upsertTrade(_ spec: TradeSpec, in database: Database) throws {
    if try TransactionRow.fetchOne(database, key: spec.id) != nil { return }

    try TransactionRow(domain: emptyTransaction(from: spec)).insert(database)

    let outgoing = TransactionLeg(
      accountId: spec.fromAccountId,
      instrument: spec.amount.instrument,
      quantity: -spec.amount.quantity,
      type: .transfer)
    let incoming = TransactionLeg(
      accountId: spec.toAccountId,
      instrument: spec.amount.instrument,
      quantity: spec.amount.quantity,
      type: .transfer)
    try TransactionLegRow(domain: outgoing, transactionId: spec.id, sortOrder: 0)
      .insert(database)
    try TransactionLegRow(domain: incoming, transactionId: spec.id, sortOrder: 1)
      .insert(database)
  }

  static func upsertHistoricalExpense(
    _ spec: HistoricalExpenseSpec,
    in database: Database
  ) throws {
    if try TransactionRow.fetchOne(database, key: spec.id) != nil { return }

    let txn = Transaction(id: spec.id, date: spec.date, payee: spec.payee, legs: [])
    try TransactionRow(domain: txn).insert(database)

    let leg = TransactionLeg(
      accountId: spec.accountId,
      instrument: spec.amount.instrument,
      quantity: -spec.amount.quantity,
      type: .expense,
      categoryId: spec.categoryId)
    try TransactionLegRow(domain: leg, transactionId: spec.id, sortOrder: 0)
      .insert(database)
  }

  /// Inserts a two-leg expense split on the same account. Both legs share
  /// `accountId`, which makes `Transaction.isSimple` false (it requires
  /// `a.accountId != b.accountId`) and flips `TransactionDraft.isCustom`
  /// to true. Categories are left nil on both legs so the test can type
  /// into an empty category field and observe autocomplete behaviour.
  static func upsertCustomExpenseSplit(
    _ spec: CustomExpenseSplitSpec,
    in database: Database
  ) throws {
    if try TransactionRow.fetchOne(database, key: spec.id) != nil { return }

    let txn = Transaction(id: spec.id, date: spec.date, payee: spec.payee, legs: [])
    try TransactionRow(domain: txn).insert(database)

    let legA = TransactionLeg(
      accountId: spec.accountId,
      instrument: spec.legAAmount.instrument,
      quantity: -spec.legAAmount.quantity,
      type: .expense)
    let legB = TransactionLeg(
      accountId: spec.accountId,
      instrument: spec.legBAmount.instrument,
      quantity: -spec.legBAmount.quantity,
      type: .expense)
    try TransactionLegRow(domain: legA, transactionId: spec.id, sortOrder: 0)
      .insert(database)
    try TransactionLegRow(domain: legB, transactionId: spec.id, sortOrder: 1)
      .insert(database)
  }

  /// Inserts one imported single-account side of a detected transfer
  /// pair: a single value leg and a `.single` import origin (so the row
  /// surfaces in Recently Added's window). The "possible transfer" pill
  /// is driven by a separate synced `TransferSuggestion` record seeded
  /// once per pair via `upsertSuggestedTransferRecord`, not a
  /// denormalised field on the transaction. Idempotent via the
  /// parent-existence guard, matching the other transaction upserts.
  static func upsertSuggestedTransfer(
    _ spec: SuggestedTransferSpec,
    in database: Database
  ) throws {
    if try TransactionRow.fetchOne(database, key: spec.id) != nil { return }

    let origin = ImportOrigin(
      rawDescription: spec.payee,
      rawAmount: spec.amount.quantity,
      importedAt: spec.importedAt,
      importSessionId: spec.importSessionId,
      sourceFilename: UITestFixtures.TransferDetection.sourceFilename,
      parserIdentifier: UITestFixtures.TransferDetection.parserIdentifier)
    let txn = Transaction(
      id: spec.id,
      date: spec.date,
      payee: spec.payee,
      legs: [],
      importOrigin: .single(origin))
    try TransactionRow(domain: txn).insert(database)

    let leg = TransactionLeg(
      accountId: spec.accountId,
      instrument: spec.amount.instrument,
      quantity: spec.amount.quantity,
      type: spec.type)
    try TransactionLegRow(domain: leg, transactionId: spec.id, sortOrder: 0)
      .insert(database)
  }

  /// Seeds the synced `TransferSuggestion` record over a detected pair
  /// so the passive "possible transfer" pill renders for both rows at
  /// first launch with no detection-timing dependency. The record id is
  /// content-addressed from the unordered transaction-id pair, so a
  /// later detection pass on any device upserts the same row.
  /// Idempotent via the row-existence guard.
  static func upsertSuggestedTransferRecord(
    transactionId: UUID,
    counterpartId: UUID,
    suggestedAt: Date,
    in database: Database
  ) throws {
    let suggestion = TransferSuggestion(
      transactionIds: [transactionId, counterpartId],
      suggestedAt: suggestedAt)
    if try TransferSuggestionRow.fetchOne(database, key: suggestion.id) != nil {
      return
    }
    try TransferSuggestionRow(domain: suggestion).insert(database)
  }

  /// Builds a legless `Transaction` whose only role is to seed
  /// `TransactionRow(domain:)`. The legs are inserted separately into
  /// `transaction_leg` and aren't part of the row mapping.
  private static func emptyTransaction(from spec: TradeSpec) -> Transaction {
    Transaction(id: spec.id, date: spec.date, payee: spec.payee, legs: [])
  }
}
