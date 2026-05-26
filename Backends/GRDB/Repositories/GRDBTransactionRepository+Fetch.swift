// Backends/GRDB/Repositories/GRDBTransactionRepository+Fetch.swift

import Foundation
import GRDB

extension GRDBTransactionRepository {
  // MARK: - Fetch pipeline

  /// Aggregates the synchronous portion of `fetch(filter:page:pageSize:)`
  /// — every read happens inside a single `database.read { … }` so the
  /// page, total count, and after-page subtotals come from the same
  /// snapshot. Conversion of the after-page subtotals to a single
  /// `priorBalance` happens on the caller's actor (the conversion
  /// service is async).
  struct FetchSnapshot: Sendable {
    let pageTransactions: [Transaction]
    let resolvedTarget: Instrument
    let totalCount: Int?
    let hasAccountFilter: Bool
    /// `true` when the requested page was past the end of the result
    /// set; `pageTransactions` is empty and no prior-balance
    /// computation is needed.
    let isPastEnd: Bool
    let afterPageSubtotals: [SubtotalEntry]
  }

  /// Per-instrument subtotal carried out of the `database.read` block
  /// for conversion on the caller's actor. Mirrors
  /// `CloudKitTransactionRepository.SubtotalEntry`.
  struct SubtotalEntry: Sendable {
    let instrument: Instrument
    let amount: InstrumentAmount
  }

  /// Query-side inputs for `buildFetchSnapshot`. Bundled (rather than
  /// passed as positional parameters) so the builder stays at
  /// SwiftLint's `function_parameter_count` ceiling now that the
  /// instrument map is resolved by the caller and threaded in.
  /// `database` stays a separate argument — it is the live GRDB
  /// connection for the read transaction, not a query parameter.
  struct FetchSnapshotInput: Sendable {
    let filter: TransactionFilter
    let page: Int
    let pageSize: Int
    let defaultInstrument: Instrument
    let instruments: [String: Instrument]
  }

  static func buildFetchSnapshot(
    database: Database,
    input: FetchSnapshotInput
  ) throws -> FetchSnapshot {
    let filter = input.filter
    let instruments = input.instruments
    let candidateRows = try candidateTransactionRows(
      database: database, filter: filter)
    let filteredRows = try applyLegFilters(
      rows: candidateRows, filter: filter, database: database)

    let resolvedTarget = try resolveTargetInstrument(
      database: database,
      filter: filter,
      instruments: instruments,
      defaultInstrument: input.defaultInstrument)

    let totalCount = filteredRows.count
    let offset = input.page * input.pageSize
    // Running balance / after-page subtotals only make sense for a
    // single-account view. A multi-account (group) filter renders a
    // merged list with no running balance, so the subtotal computation
    // is skipped and `hasAccountFilter` is reported as false to the
    // caller (it gates running-balance UI).
    let isSingleAccount = filter.accountId != nil && filter.accountIds.isEmpty
    guard offset < totalCount else {
      return FetchSnapshot(
        pageTransactions: [],
        resolvedTarget: resolvedTarget,
        totalCount: totalCount,
        hasAccountFilter: isSingleAccount,
        isPastEnd: true,
        afterPageSubtotals: [])
    }
    let end = min(offset + input.pageSize, totalCount)
    let pageRows = Array(filteredRows[offset..<end])
    let pageLegs = try fetchLegs(
      database: database,
      transactionIds: pageRows.map(\.id),
      instruments: instruments)
    let pageTransactions = try pageRows.map { row in
      try row.toDomain(legs: pageLegs[row.id] ?? [])
    }

    let afterPageSubtotals: [SubtotalEntry]
    if let accountId = filter.accountId, isSingleAccount {
      let afterPageIds = Array(filteredRows[end...].map(\.id))
      afterPageSubtotals = try subtotalsAfterPage(
        database: database,
        accountId: accountId,
        afterPageTransactionIds: afterPageIds,
        instruments: instruments)
    } else {
      afterPageSubtotals = []
    }

    return FetchSnapshot(
      pageTransactions: pageTransactions,
      resolvedTarget: resolvedTarget,
      totalCount: totalCount,
      hasAccountFilter: isSingleAccount,
      isPastEnd: false,
      afterPageSubtotals: afterPageSubtotals)
  }

  /// Runs the filters that can be expressed against the `"transaction"`
  /// table directly: `scheduled`, `dateRange`, and a case-insensitive
  /// `payee` substring match. Returns rows ordered `date DESC, id ASC`
  /// — the deterministic tiebreaker pinned by
  /// `TransactionRepositoryOrderingTests` on the CloudKit side.
  static func candidateTransactionRows(
    database: Database,
    filter: TransactionFilter
  ) throws -> [TransactionRow] {
    var query = TransactionRow.all()

    // Mirrors `CloudKitTransactionRepository`'s `loadAndFilter`: `.all`
    // and `.nonScheduledOnly` both exclude scheduled rows from the
    // page; only `.scheduledOnly` flips the predicate. Production page
    // views never want scheduled rows interleaved with their booked
    // counterparts, so the default filter (`.all`) keeps the
    // non-scheduled view shape.
    switch filter.scheduled {
    case .all, .nonScheduledOnly:
      query = query.filter(TransactionRow.Columns.recurPeriod == nil)
    case .scheduledOnly:
      query = query.filter(TransactionRow.Columns.recurPeriod != nil)
    }

    if let dateRange = filter.dateRange {
      let start = dateRange.lowerBound
      let end = dateRange.upperBound
      query = query.filter(
        TransactionRow.Columns.date >= start
          && TransactionRow.Columns.date <= end)
    }

    if let payee = filter.payee, !payee.isEmpty {
      let pattern = "%" + payee.lowercased() + "%"
      query = query.filter(
        sql: "lower(payee) LIKE ?", arguments: [pattern])
    }

    return
      try query
      .order(
        TransactionRow.Columns.date.desc,
        TransactionRow.Columns.id.asc
      )
      .fetchAll(database)
  }

  /// Applies the leg-driven filters (`accountId`, `earmarkId`,
  /// `categoryIds`) against the candidate rows. Each filter is
  /// translated into a `transaction_leg` lookup and intersected with
  /// the candidate set.
  static func applyLegFilters(
    rows: [TransactionRow],
    filter: TransactionFilter,
    database: Database
  ) throws -> [TransactionRow] {
    var rows = rows

    // Build the union of account ids the caller is filtering by: a
    // single `accountId` (single-account view) and / or a `accountIds`
    // set (composite group view). Empty union → no account filter.
    var unionAccountIds: Set<UUID> = filter.accountIds
    if let accountId = filter.accountId { unionAccountIds.insert(accountId) }
    if !unionAccountIds.isEmpty {
      let allowedIds =
        try TransactionLegRow
        .filter(unionAccountIds.contains(TransactionLegRow.Columns.accountId))
        .select(TransactionLegRow.Columns.transactionId, as: UUID.self)
        .fetchAll(database)
      let allowedSet = Set(allowedIds)
      rows = rows.filter { allowedSet.contains($0.id) }
    }

    if let earmarkId = filter.earmarkId {
      let allowedIds =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.earmarkId == earmarkId)
        .select(TransactionLegRow.Columns.transactionId, as: UUID.self)
        .fetchAll(database)
      let allowedSet = Set(allowedIds)
      rows = rows.filter { allowedSet.contains($0.id) }
    }

    if !filter.categoryIds.isEmpty {
      let allowedIds =
        try TransactionLegRow
        .filter(filter.categoryIds.contains(TransactionLegRow.Columns.categoryId))
        .select(TransactionLegRow.Columns.transactionId, as: UUID.self)
        .fetchAll(database)
      let allowedSet = Set(allowedIds)
      rows = rows.filter { allowedSet.contains($0.id) }
    }

    return rows
  }

  /// Bulk-fetches legs for the given transaction ids, mapping each
  /// to a domain `TransactionLeg` via the supplied instrument lookup.
  /// Mirrors `CloudKitTransactionRepository.fetchLegs(for:)`.
  static func fetchLegs(
    database: Database,
    transactionIds: [UUID],
    instruments: [String: Instrument]
  ) throws -> [UUID: [TransactionLeg]] {
    guard !transactionIds.isEmpty else { return [:] }
    let idSet = Set(transactionIds)
    let legRows =
      try TransactionLegRow
      .filter(idSet.contains(TransactionLegRow.Columns.transactionId))
      .order(TransactionLegRow.Columns.sortOrder.asc)
      .fetchAll(database)

    var grouped: [UUID: [TransactionLeg]] = [:]
    grouped.reserveCapacity(transactionIds.count)
    for legRow in legRows {
      let instrument =
        instruments[legRow.instrumentId]
        ?? Instrument.fiat(code: legRow.instrumentId)
      grouped[legRow.transactionId, default: []].append(
        try legRow.toDomain(instrument: instrument))
    }
    return grouped
  }

  /// Groups raw leg storage values by instrument for the given
  /// `afterPageTransactionIds` so the caller can compute a running
  /// balance for the page. Mirrors
  /// `CloudKitTransactionRepository.subtotalsAfterPage`.
  static func subtotalsAfterPage(
    database: Database,
    accountId: UUID,
    afterPageTransactionIds: [UUID],
    instruments: [String: Instrument]
  ) throws -> [SubtotalEntry] {
    guard !afterPageTransactionIds.isEmpty else { return [] }
    let txnIdSet = Set(afterPageTransactionIds)
    let legs =
      try TransactionLegRow
      .filter(TransactionLegRow.Columns.accountId == accountId)
      .filter(txnIdSet.contains(TransactionLegRow.Columns.transactionId))
      .fetchAll(database)

    var subtotalsById: [String: Int64] = [:]
    for leg in legs {
      subtotalsById[leg.instrumentId, default: 0] += leg.quantity
    }
    return subtotalsById.map { instrumentId, storage in
      let instrument =
        instruments[instrumentId] ?? Instrument.fiat(code: instrumentId)
      return SubtotalEntry(
        instrument: instrument,
        amount: InstrumentAmount(
          storageValue: storage, instrument: instrument))
    }
  }

  /// Resolves the running-balance label instrument for the page.
  /// Single-account fetches use the account's own instrument; global
  /// and multi-account (group) fetches use `defaultInstrument` (no
  /// running balance in the merged list). Mirrors
  /// `CloudKitTransactionRepository.accountInstrument(id:)`. If the
  /// account row is missing (deleted concurrently) we fall back to
  /// `defaultInstrument` rather than failing the read.
  static func resolveTargetInstrument(
    database: Database,
    filter: TransactionFilter,
    instruments: [String: Instrument],
    defaultInstrument: Instrument
  ) throws -> Instrument {
    // Multi-account (group) filter — no single per-account instrument
    // applies, so use the profile default.
    if !filter.accountIds.isEmpty { return defaultInstrument }
    guard let accountId = filter.accountId else { return defaultInstrument }
    guard
      let accountRow =
        try AccountRow
        .filter(AccountRow.Columns.id == accountId)
        .fetchOne(database)
    else {
      return defaultInstrument
    }
    return
      instruments[accountRow.instrumentId]
      ?? Instrument.fiat(code: accountRow.instrumentId)
  }
}
