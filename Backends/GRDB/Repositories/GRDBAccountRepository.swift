// Backends/GRDB/Repositories/GRDBAccountRepository.swift

import Foundation
import GRDB

/// GRDB-backed implementation of `AccountRepository`. Replaces the
/// SwiftData-backed `CloudKitAccountRepository` for the `account` table.
///
/// **Position computation.** `fetchAll()` returns accounts with their
/// per-instrument `positions` populated. Positions are summed from
/// non-scheduled `transaction_leg` rows grouped by
/// `(account_id, instrument_id)` and resolved against the `instrument`
/// registry (with ambient ISO fiat as a fallback). Matches
/// `CloudKitAccountRepository.computePositions`.
///
/// **Opening balance.** `create(_:openingBalance:)` performs the account
/// insert and the optional opening-balance transaction (one
/// `TransactionRow` + one `TransactionLegRow`) inside a single
/// `database.write { … }`. Hook fan-out happens after the transaction
/// commits — emitting hooks inside the write would publish changes that
/// haven't yet been made durable.
///
/// **Instrument resolution.** Positions resolve their `instrument` via
/// the injected `instrumentResolver`. The instrument map is fetched
/// once, *before* opening the per-profile read/write snapshot, because
/// the canonical registry lives on a different (profile-index)
/// database — a cross-database transaction is impossible. Instrument
/// identity is immutable lookup data, so a read that is not atomic with
/// the account/leg-row snapshot is safe and intended. Mirrors
/// `GRDBTransactionRepository`.
///
/// **`@unchecked Sendable` justification.** All stored properties are
/// `let`. `database` (`any DatabaseWriter`) is itself `Sendable` (GRDB
/// protocol guarantee — the queue's serial executor mediates concurrent
/// access). `instrumentResolver` is a `Sendable` protocol
/// (`InstrumentMapResolving`) and immutable post-init.
/// `instrumentRegistrar` is a `Sendable` protocol
/// (`InstrumentRegistering`) and immutable post-init. `onRecordChanged`
/// and `onRecordDeleted` are `@Sendable` closures
/// captured at init. Nothing mutates post-init, so the reference can be shared across
/// actor boundaries without a data race; `@unchecked` only waives
/// Swift's structural check that `final class` types meet `Sendable`'s
/// requirements automatically.
/// See `guides/CONCURRENCY_GUIDE.md` §2 "False Positives to Avoid",
/// Carve-out 3 (GRDB repositories).
final class GRDBAccountRepository: AccountRepository, @unchecked Sendable {
  // `database`, `instrumentResolver`, and `errorChannel` are
  // deliberately not `private` so the sibling `+Observation.swift`
  // extension can reach them. Treat them as private-by-convention from
  // elsewhere in the module.
  let database: any DatabaseWriter
  /// Resolves the `[String: Instrument]` lookup table from the
  /// canonical instrument registry. Fetched once per read/write
  /// operation *before* the per-profile snapshot opens — the registry
  /// lives on a separate (profile-index) database, so a cross-database
  /// transaction is impossible. Instrument identity is immutable lookup
  /// data. Every caller — production, preview, test, and the sync
  /// apply path — injects the shared `GRDBInstrumentRegistryRepository`
  /// (the profile-index registry). Nothing reads the per-profile
  /// `instrument` table any more; `v10_drop_shared_instrument_legacy`
  /// removed it.
  let instrumentResolver: any InstrumentMapResolving
  /// Registers a non-fiat account denomination so it becomes resolvable
  /// by `instrumentResolver` before `create` returns. Awaited *before*
  /// the per-profile `database.write` that inserts the account row (the
  /// registry lives on a separate database — a cross-database
  /// transaction is impossible, and the registration must be durable
  /// before a reader can observe the new account). Replaces the old
  /// per-profile placeholder `instrument` insert. Every caller —
  /// production, preview, test, and the sync apply path — injects the
  /// shared `GRDBInstrumentRegistryRepository`, so registration always
  /// lands on the profile-index registry, never the per-profile
  /// `instrument` table `v10_drop_shared_instrument_legacy` removed.
  private let instrumentRegistrar: any InstrumentRegistering
  /// Receives `(recordType, id)` so the opening-balance create path can
  /// tag its txn and leg writes with `TransactionRow.recordType` /
  /// `TransactionLegRow.recordType` instead of the account's own type —
  /// see `RepositoryHookRecordTypeTests`.
  private let onRecordChanged: @Sendable (String, UUID) -> Void
  private let onRecordDeleted: @Sendable (String, UUID) -> Void
  /// Single shared error channel for every `observeAll()` subscription
  /// returned by this repo instance. The bridge in
  /// `Backends/GRDB/Observation/AsyncValueObservation+AsyncStream.swift`
  /// is single-shot, so once `surfaceAndFinish(_:)` is called the
  /// channel terminates — subsequent observations from the same repo
  /// share that fate. This matches the design's "repository instance
  /// owns the channel" rule.
  let errorChannel = ObservationErrorChannel()

  init(
    database: any DatabaseWriter,
    instrumentResolver: any InstrumentMapResolving,
    instrumentRegistrar: any InstrumentRegistering,
    onRecordChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onRecordDeleted: @escaping @Sendable (String, UUID) -> Void = { _, _ in }
  ) {
    self.database = database
    self.instrumentResolver = instrumentResolver
    self.instrumentRegistrar = instrumentRegistrar
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
  }

  // MARK: - AccountRepository conformance

  func fetchAll() async throws -> [Account] {
    // Resolve the instrument lookup table before opening the
    // per-profile snapshot: the canonical registry is a separate
    // database, so the map cannot be joined into this transaction.
    // Instrument identity is immutable lookup data — a read not atomic
    // with the row snapshot is safe and intended. Mirrors
    // `GRDBTransactionRepository.fetchAll(filter:)`.
    let instruments = try await instrumentResolver.instrumentMap()
    return try await database.read { database in
      let rows =
        try AccountRow
        .order(AccountRow.Columns.position.asc)
        .fetchAll(database)
      let positionsByAccount = try Self.computePositions(
        database: database, instruments: instruments)
      return try rows.map { row in
        try row.toDomain(
          instruments: instruments,
          positions: positionsByAccount[row.id] ?? [])
      }
    }
  }

  func create(
    _ account: Account,
    openingBalance: InstrumentAmount? = nil
  ) async throws -> Account {
    guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw BackendError.validationFailed("Account name cannot be empty")
    }

    // Register a non-fiat account denomination so a read issued
    // immediately after this method returns resolves it. Awaited
    // *before* the per-profile write: the registry lives on a separate
    // database (a cross-database transaction is impossible) and the
    // registration must be durable before the account becomes
    // observable. Replaces the old per-profile placeholder insert.
    try await instrumentRegistrar.registerResolvable(account.instrument)

    // Capture the wall clock outside the write block so the closure body
    // doesn't read `Date()` while holding the GRDB queue's serial
    // executor.
    let openingBalanceDate = Date()
    let inserts = try await database.write { database -> OpeningBalanceInserts in
      try Self.performAccountInsert(
        database: database,
        account: account,
        openingBalance: openingBalance,
        openingBalanceDate: openingBalanceDate)
    }

    onRecordChanged(AccountRow.recordType, account.id)
    if let txnId = inserts.transactionId {
      onRecordChanged(TransactionRow.recordType, txnId)
    }
    if let legId = inserts.legId {
      onRecordChanged(TransactionLegRow.recordType, legId)
    }
    return account
  }

  // `performAccountInsert` and `OpeningBalanceInserts` live in
  // `GRDBAccountRepository+Create.swift`.

  func update(_ account: Account) async throws -> Account {
    guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw BackendError.validationFailed("Account name cannot be empty")
    }

    // Combine the row update and the post-update position read into a
    // single `database.write` so the returned `Account` reflects the
    // exact same database state as the row mutation. A separate
    // follow-up `database.read` would race with concurrent writers and
    // could observe positions from after the update commit, or — worse
    // — emit `onRecordChanged` before the second read settled.
    // Hoisted ahead of the write snapshot for the same cross-database
    // reason as `fetchAll()`.
    let instruments = try await instrumentResolver.instrumentMap()
    let resolved = try await database.write { database -> Account in
      guard
        var existing =
          try AccountRow
          .filter(AccountRow.Columns.id == account.id)
          .fetchOne(database)
      else {
        throw BackendError.notFound("Account not found")
      }
      existing.name = account.name
      existing.type = account.type.rawValue
      existing.instrumentId = account.instrument.id
      existing.position = account.position
      existing.isHidden = account.isHidden
      existing.valuationMode = account.valuationMode.rawValue
      existing.groupId = account.groupId
      try existing.update(database)

      let positions = try Self.computePositions(
        database: database, instruments: instruments, accountId: account.id)
      return try existing.toDomain(instruments: instruments, positions: positions)
    }
    onRecordChanged(AccountRow.recordType, account.id)
    return resolved
  }

  /// Single-statement bootstrap migration: flips every investment
  /// account without an `InvestmentValue` snapshot to
  /// `valuationMode = .calculatedFromTrades`. Runs inside one
  /// `database.write { … }` so the whole pass is one transaction / one
  /// fsync — replaces the historic per-account loop driven by
  /// `ValuationModeMigration.run()`.
  ///
  /// Idempotency lives one level up — `ValuationModeMigration` gates
  /// the call on a per-profile `UserDefaults` flag and never invokes
  /// this method twice for the same install.
  ///
  /// Hooks are deliberately not fired: this runs at bootstrap before
  /// any sync subscriber is attached, and the new value is locally
  /// derived state (CKSyncEngine treats `valuation_mode` like any
  /// other field — the next remote upload will surface the change via
  /// the regular store path).
  func backfillValuationModeForUnsnapshotInvestmentAccounts() async throws -> Int {
    try await database.write { database in
      try database.execute(
        literal: """
          UPDATE account
          SET valuation_mode = \(ValuationMode.calculatedFromTrades.rawValue)
          WHERE type = \(AccountType.investment.rawValue)
            AND id NOT IN (SELECT DISTINCT account_id FROM investment_value)
          """)
      return database.changesCount
    }
  }

  func delete(id: UUID) async throws {
    // Soft-delete: flip `is_hidden = true` on the matching row.
    // Rejects deletes against an account with non-zero positions —
    // mirrors the contract enforced by
    // `CloudKitAccountRepository.delete(id:)`.
    // Hoisted ahead of the write snapshot for the same cross-database
    // reason as `fetchAll()`.
    let instruments = try await instrumentResolver.instrumentMap()
    try await database.write { database in
      guard
        var existing =
          try AccountRow
          .filter(AccountRow.Columns.id == id)
          .fetchOne(database)
      else {
        throw BackendError.notFound("Account not found")
      }
      let positions = try Self.computePositions(
        database: database, instruments: instruments, accountId: id)
      if positions.contains(where: { $0.quantity != 0 }) {
        throw BackendError.validationFailed(
          "Cannot delete account with non-zero balance")
      }
      existing.isHidden = true
      try existing.update(database)
    }
    onRecordChanged(AccountRow.recordType, id)
  }

  // MARK: - Sync entry points
  //
  // The synchronous, GRDB-queue-blocking sync entry points
  // (`applyRemoteChangesSync`, `setEncodedSystemFieldsSync` and
  // siblings) live in `GRDBAccountRepository+Sync.swift`, mirroring
  // `GRDBTransactionRepository+Sync.swift`.
}
