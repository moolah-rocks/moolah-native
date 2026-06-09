// Backends/GRDB/Repositories/GRDBTransactionRepository.swift

import Foundation
import GRDB
import OSLog

/// GRDB-backed implementation of `TransactionRepository`. Replaces the
/// SwiftData-backed `CloudKitTransactionRepository` for the
/// `"transaction"` and `transaction_leg` tables.
///
/// **Header + legs together.** Every write path (`create`, `update`,
/// `delete`) inserts/deletes the `TransactionRow` and its
/// `TransactionLegRow`s inside a single `database.write { … }`. On any
/// throw the entire mutation rolls back. The schema does not enforce
/// FK CASCADE on `transaction_leg.transaction_id`; `delete(id:)` and
/// the sync `applyRemoteChangesSync` in `+Sync.swift` therefore delete
/// legs explicitly before the parent, in the same write transaction,
/// so a partially committed header cannot leave orphaned legs. Rollback
/// test mandatory; see `guides/DATABASE_CODE_GUIDE.md`.
///
/// **Instrument resolution.** Each leg's `instrument` is resolved via
/// the injected `instrumentResolver`. The instrument map is fetched
/// once, *before* opening the per-profile read snapshot, because the
/// canonical registry lives on a different (profile-index) database —
/// a cross-database transaction is impossible. Instrument identity is
/// immutable lookup data, so a read that is not atomic with the
/// transaction-row snapshot is safe and intended. Stored rows win over
/// ambient fiat synthesised from `Locale.Currency.isoCurrencies`.
/// Mirrors `CloudKitTransactionRepository.resolveInstrument(id:)`.
///
/// **Running balance.** The repository does not compute running balances —
/// `TransactionPage.withRunningBalances(...)` is the domain helper the
/// store calls after the fetch returns. The `priorBalance` field on the
/// page is the account-scoped subtotal of every leg _after_ the page
/// (newer pages have already been read), converted to the target
/// instrument by `InstrumentConversionService`. Returns `nil` on any
/// conversion failure (Rule 11 of `guides/INSTRUMENT_CONVERSION_GUIDE.md`).
///
/// **`@unchecked Sendable` justification.** All stored properties are
/// `let`. `database` (`any DatabaseWriter`) is itself `Sendable` (GRDB
/// protocol guarantee — the queue's serial executor mediates concurrent
/// access). `defaultInstrument` is a value type. `conversionService` is
/// a `Sendable` protocol. `instrumentResolver` is a `Sendable`
/// protocol (`InstrumentMapResolving`) and immutable post-init.
/// `instrumentRegistrar` is a `Sendable` protocol
/// (`InstrumentRegistering`) and immutable post-init.
/// `onRecordChanged` and `onRecordDeleted` are
/// `@Sendable` closures captured at init. Nothing mutates post-init, so
/// the reference can be shared across actor boundaries without a data
/// race; `@unchecked` only waives Swift's structural check that
/// `final class` types meet `Sendable`'s requirements automatically.
/// See `guides/CONCURRENCY_GUIDE.md` §2 "False Positives to Avoid",
/// Carve-out 3 (GRDB repositories).
final class GRDBTransactionRepository: TransactionRepository, @unchecked Sendable {
  // `database`, `defaultInstrument`, `conversionService`,
  // `instrumentResolver`, `errorChannel`, `instrumentRegistrar`,
  // `onRecordChanged`, and `onRecordDeleted` are deliberately not
  // `private` so the sibling `+Observation.swift` /
  // `+ExternalIdLookup.swift` / `+Replace.swift` extensions can reach
  // them. Treat them as private-by-convention from elsewhere in the
  // module.
  let database: any DatabaseWriter
  /// Profile instrument used to label the running balance for global
  /// (non-account-scoped) fetches. Mirrors
  /// `CloudKitTransactionRepository.instrument`.
  let defaultInstrument: Instrument
  let conversionService: any InstrumentConversionService
  /// Resolves the `[String: Instrument]` lookup table from the
  /// canonical instrument registry. Fetched once per read operation
  /// *before* the per-profile `database.read` snapshot opens — the
  /// registry lives on a separate (profile-index) database, so a
  /// cross-database transaction is impossible. Instrument identity is
  /// immutable lookup data; a read that is not atomic with the
  /// transaction-row snapshot is safe and intended. Every caller —
  /// production, preview, test, and the sync apply path — injects the
  /// shared `GRDBInstrumentRegistryRepository`; nothing reads the
  /// per-profile `instrument` table
  /// `v10_drop_shared_instrument_legacy` removed.
  let instrumentResolver: any InstrumentMapResolving
  /// Registers a non-fiat leg instrument so it becomes resolvable by
  /// `instrumentResolver` before `create` / `createMany` / `update`
  /// returns. Awaited *before* the per-profile `database.write` (the
  /// registry lives on a separate database — a cross-database
  /// transaction is impossible, and the registration must be durable
  /// before a reader can observe the new txn / legs). Replaces the old
  /// per-profile placeholder `instrument` insert. Every caller —
  /// production, preview, test, and the sync apply path — injects the
  /// shared `GRDBInstrumentRegistryRepository` (so the row reaches the
  /// canonical registry and CloudKit); nothing writes the
  /// per-profile `instrument` table
  /// `v10_drop_shared_instrument_legacy` removed.
  let instrumentRegistrar: any InstrumentRegistering
  /// Single shared error channel for every observation subscription
  /// returned by this repo instance. The bridge in
  /// `Backends/GRDB/Observation/AsyncValueObservation+AsyncStream.swift`
  /// is single-shot, so once `surfaceAndFinish(_:)` is called the
  /// channel terminates — subsequent observations from the same repo
  /// share that fate. This matches the design's "repository instance
  /// owns the channel" rule.
  let errorChannel = ObservationErrorChannel()
  /// Receives `(recordType, id)` so legs and parent transactions tag
  /// their own CloudKit `recordName` correctly. The transaction repo
  /// emits both `TransactionRow.recordType` (parent) and
  /// `TransactionLegRow.recordType` (per leg) ids from the same
  /// mutation, so the callback must carry the type — see
  /// `RepositoryHookRecordTypeTests`.
  let onRecordChanged: @Sendable (String, UUID) -> Void
  let onRecordDeleted: @Sendable (String, UUID) -> Void

  private let logger = Logger(
    subsystem: "com.moolah.app", category: "GRDBTransactionRepository")

  init(
    database: any DatabaseWriter,
    defaultInstrument: Instrument,
    conversionService: any InstrumentConversionService,
    instrumentResolver: any InstrumentMapResolving,
    instrumentRegistrar: any InstrumentRegistering,
    onRecordChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onRecordDeleted: @escaping @Sendable (String, UUID) -> Void = { _, _ in }
  ) {
    self.database = database
    self.defaultInstrument = defaultInstrument
    self.conversionService = conversionService
    self.instrumentResolver = instrumentResolver
    self.instrumentRegistrar = instrumentRegistrar
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
  }

  // MARK: - TransactionRepository conformance

  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    // Resolve the instrument lookup table before opening the per-profile
    // snapshot: the canonical registry is a separate database, so the
    // map cannot be joined into this transaction. Instrument identity is
    // immutable lookup data — a read not atomic with the row snapshot is
    // safe and intended.
    let instruments = try await instrumentResolver.instrumentMap()
    let snapshot = try await database.read { database -> FetchSnapshot in
      try Self.buildFetchSnapshot(
        database: database,
        input: FetchSnapshotInput(
          filter: filter,
          page: page,
          pageSize: pageSize,
          defaultInstrument: self.defaultInstrument,
          instruments: instruments))
    }
    let priorBalance = await resolvePriorBalance(snapshot: snapshot)
    return TransactionPage(
      transactions: snapshot.pageTransactions,
      targetInstrument: snapshot.resolvedTarget,
      priorBalance: priorBalance,
      totalCount: snapshot.totalCount)
  }

  func fetchAll(filter: TransactionFilter) async throws -> [Transaction] {
    // Hoisted ahead of the snapshot for the same cross-database reason
    // as `fetch(filter:page:pageSize:)`.
    let instruments = try await instrumentResolver.instrumentMap()
    return try await database.read { database in
      let candidateRows = try Self.candidateTransactionRows(
        database: database, filter: filter)
      let filteredRows = try Self.applyLegFilters(
        rows: candidateRows, filter: filter, database: database)
      let legsByTxnId = try Self.fetchLegs(
        database: database,
        transactionIds: filteredRows.map(\.id),
        instruments: instruments)
      return try filteredRows.map { row in
        try row.toDomain(legs: legsByTxnId[row.id] ?? [])
      }
    }
  }

  func create(_ transaction: Transaction) async throws -> Transaction {
    // Register every distinct non-fiat leg instrument so a read issued
    // immediately after this method returns resolves it. Awaited
    // *before* the per-profile write: the registry lives on a separate
    // database (a cross-database transaction is impossible) and the
    // registration must be durable before the txn / legs become
    // observable. Replaces the old per-profile placeholder insert.
    try await Self.registerNonFiatLegInstruments(
      transaction.legs, using: instrumentRegistrar)

    let legIds = try await database.write { database -> [UUID] in
      let txnRow = TransactionRow(domain: transaction)
      try txnRow.insert(database)
      try markNeedsPushSync(id: transaction.id, in: database)

      var legIds: [UUID] = []
      legIds.reserveCapacity(transaction.legs.count)
      for (index, leg) in transaction.legs.enumerated() {
        let legRow = TransactionLegRow(
          id: leg.id,
          domain: leg,
          transactionId: transaction.id,
          sortOrder: index)
        try legRow.insert(database)
        try Self.markLegNeedsPush(id: leg.id, in: database)
        legIds.append(leg.id)
      }
      return legIds
    }

    onRecordChanged(TransactionRow.recordType, transaction.id)
    for legId in legIds {
      onRecordChanged(TransactionLegRow.recordType, legId)
    }
    return transaction
  }

  func createMany(_ transactions: [Transaction]) async throws -> [Transaction] {
    guard !transactions.isEmpty else { return [] }
    // Register every distinct non-fiat instrument across the whole
    // batch before the per-profile write (see `create`).
    try await Self.registerNonFiatLegInstruments(
      transactions.flatMap(\.legs), using: instrumentRegistrar)

    let legIds = try await database.write { database -> [UUID] in
      try Self.performCreateMany(database: database, transactions: transactions)
    }
    for transaction in transactions {
      onRecordChanged(TransactionRow.recordType, transaction.id)
    }
    for legId in legIds {
      onRecordChanged(TransactionLegRow.recordType, legId)
    }
    return transactions
  }

  func update(_ transaction: Transaction) async throws -> Transaction {
    // Register every distinct non-fiat leg instrument before the
    // per-profile write (see `create`).
    try await Self.registerNonFiatLegInstruments(
      transaction.legs, using: instrumentRegistrar)

    let outcome = try await database.write { database -> UpdateOutcome in
      try Self.performUpdate(
        database: database,
        transaction: transaction)
    }

    onRecordChanged(TransactionRow.recordType, transaction.id)
    for legId in outcome.upsertedLegIds {
      onRecordChanged(TransactionLegRow.recordType, legId)
    }
    for legId in outcome.deletedLegIds {
      onRecordDeleted(TransactionLegRow.recordType, legId)
    }
    return transaction
  }

  func delete(id: UUID) async throws {
    // Explicit delete of legs before the parent, replacing the v3-era
    // ON DELETE CASCADE on `transaction_leg.transaction_id` that v5
    // dropped (`v5_drop_foreign_keys`). The `fetchAll(...).map(\.id)`
    // for hook fan-out MUST precede `deleteAll(...)` — after the delete
    // the fetch returns empty and per-leg `onRecordDeleted` hooks
    // silently stop firing. Both deletes share the same write
    // transaction so the parent + children disappear atomically.
    let outcome = try await database.write { database -> (didDelete: Bool, legIds: [UUID]) in
      let legIds =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.transactionId == id)
        .fetchAll(database)
        .map(\.id)
      _ =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.transactionId == id)
        .deleteAll(database)
      let didDelete = try TransactionRow.deleteOne(database, id: id)
      return (didDelete, legIds)
    }
    guard outcome.didDelete else {
      throw BackendError.notFound("Transaction not found")
    }
    onRecordDeleted(TransactionRow.recordType, id)
    for legId in outcome.legIds {
      onRecordDeleted(TransactionLegRow.recordType, legId)
    }
  }

  func fetchPayeeSuggestions(
    prefix: String, excludingTransactionId: UUID?
  ) async throws -> [String] {
    guard !prefix.isEmpty else { return [] }
    return try await database.read { database in
      // `LIKE ? || '%'` keeps the wildcard out of the bound argument so
      // a payee containing literal `%` cannot inject a wildcard into
      // the match. Lowercasing is symmetric on both sides. Ordering by
      // frequency (descending) puts most-used payees at the top, with
      // the payee string as a stable tie-breaker for deterministic
      // pagination.
      //
      // `excludingTransactionId` removes the editing row from both the
      // GROUP BY count and the visible list (#538) so a payee that only
      // exists on the row being edited disappears, and one that exists
      // on N rows is counted as N-1 from that row's perspective.
      if let excludingTransactionId {
        let sql = """
          SELECT payee
          FROM "transaction"
          WHERE payee IS NOT NULL
            AND id != ?
            AND lower(payee) LIKE lower(?) || '%'
          GROUP BY payee
          ORDER BY COUNT(*) DESC, payee ASC
          LIMIT 20
          """
        return try String.fetchAll(
          database, sql: sql, arguments: [excludingTransactionId, prefix])
      }
      let sql = """
        SELECT payee
        FROM "transaction"
        WHERE payee IS NOT NULL
          AND lower(payee) LIKE lower(?) || '%'
        GROUP BY payee
        ORDER BY COUNT(*) DESC, payee ASC
        LIMIT 20
        """
      return try String.fetchAll(database, sql: sql, arguments: [prefix])
    }
  }

  // MARK: - Private helpers

  /// Converts the snapshot's per-instrument after-page subtotals to a
  /// single `priorBalance` on the target instrument. Returns `nil` on
  /// any conversion failure so callers can mark the running-balance
  /// column unavailable (Rule 11 of `INSTRUMENT_CONVERSION_GUIDE.md`).
  private func resolvePriorBalance(snapshot: FetchSnapshot) async -> InstrumentAmount? {
    if snapshot.isPastEnd || !snapshot.hasAccountFilter {
      return InstrumentAmount.zero(instrument: snapshot.resolvedTarget)
    }

    let target = snapshot.resolvedTarget
    var total = InstrumentAmount.zero(instrument: target)
    let today = Date()
    for entry in snapshot.afterPageSubtotals {
      if entry.instrument == target {
        total += entry.amount
        continue
      }
      do {
        let converted = try await conversionService.convertAmount(
          entry.amount, to: target, on: today)
        if Task.isCancelled { return nil }
        total += converted
      } catch {
        logger.warning(
          """
          priorBalance conversion failed for \
          \(entry.instrument.id, privacy: .public) → \
          \(target.id, privacy: .public): \
          \(String(describing: error), privacy: .public)
          """)
        return nil
      }
    }
    return total
  }

  // MARK: - Cross-extension internals
  //
  // The following types and helpers are defined in peer extension files
  // and consumed by methods in this file:
  //   `UpdateOutcome`, `performUpdate(database:transaction:)` →
  //     `GRDBTransactionRepository+Update.swift`
  //   `FetchSnapshot`, `buildFetchSnapshot(...)`,
  //   `candidateTransactionRows(...)`, `applyLegFilters(...)`,
  //   `fetchLegs(...)` →
  //     `GRDBTransactionRepository+Fetch.swift`
  //   `registerNonFiatLegInstruments(_:using:)` →
  //     `GRDBTransactionRepository+CreateMany.swift`
  //   `ReplaceOutcome`, `replace(deletingIds:creating:)` →
  //     `GRDBTransactionRepository+Replace.swift`
}
