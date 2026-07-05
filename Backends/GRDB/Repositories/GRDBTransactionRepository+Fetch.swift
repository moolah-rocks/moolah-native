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
    let request = filteredTransactionRequest(filter: filter)

    let resolvedTarget = try resolveTargetInstrument(
      database: database,
      filter: filter,
      instruments: instruments,
      defaultInstrument: input.defaultInstrument)

    // `fetchCount` pushes the count into SQL (`SELECT COUNT(*) …`) over the
    // same filtered request, replacing the old `filteredRows.count` on a
    // fully materialised table.
    let totalCount = try request.fetchCount(database)
    let offset = input.page * input.pageSize
    // Running balance / after-page subtotals apply to any account-scoped
    // view: a single account (`accountId`) or the member set of an account
    // group (`accountIds`). Both render a running-balance column that must
    // tie out to the account / group sidebar total, so the subtotal is
    // computed over the union of member accounts. A global / scheduled
    // filter has no account scope, so it is skipped and `hasAccountFilter`
    // is reported false (it gates the running-balance computation).
    var memberAccountIds = filter.accountIds
    if let accountId = filter.accountId { memberAccountIds.insert(accountId) }
    let hasAccountScope = !memberAccountIds.isEmpty
    guard offset < totalCount else {
      return FetchSnapshot(
        pageTransactions: [],
        resolvedTarget: resolvedTarget,
        totalCount: totalCount,
        hasAccountFilter: hasAccountScope,
        isPastEnd: true,
        afterPageSubtotals: [])
    }

    // Page only the requested window through SQL `LIMIT/OFFSET` over the
    // `date DESC, id ASC` ordering (index-backed by `transaction_by_date_id`).
    let orderedRequest = orderedFilteredRequest(filter: filter)
    let pageRows =
      try orderedRequest
      .limit(input.pageSize, offset: offset)
      .fetchAll(database)
    let pageLegs = try fetchLegs(
      database: database,
      transactionIds: pageRows.map(\.id),
      instruments: instruments)
    let pageTransactions = try pageRows.map { row in
      try row.toDomain(legs: pageLegs[row.id] ?? [])
    }

    let afterPageEntries = try subtotalsAfterPage(
      database: database,
      orderedRequest: orderedRequest,
      afterPageOffset: offset + pageRows.count,
      accountIds: memberAccountIds,
      instruments: instruments)

    return FetchSnapshot(
      pageTransactions: pageTransactions,
      resolvedTarget: resolvedTarget,
      totalCount: totalCount,
      hasAccountFilter: hasAccountScope,
      isPastEnd: false,
      afterPageSubtotals: afterPageEntries)
  }

  /// Builds the filtered transaction request (NOT fetched) shared by the
  /// page, count, after-page, and `fetchAll` paths. Applies the
  /// `"transaction"`-table filters directly (`scheduled`, `dateRange`,
  /// case-insensitive `payee` substring) and the leg-driven filters
  /// (`accountId` ∪ `accountIds`, `earmarkId`, `categoryIds`,
  /// `uncategorizedLegType`) as
  /// intersecting `id IN (SELECT transaction_id FROM transaction_leg …)`
  /// subqueries, so every predicate constrains the paginated query in SQL
  /// instead of being re-applied to a fully materialised table. All UUIDs
  /// bind as parameters. No ordering is applied here — see
  /// `orderedFilteredRequest(filter:)`.
  static func filteredTransactionRequest(
    filter: TransactionFilter
  ) -> QueryInterfaceRequest<TransactionRow> {
    var request = TransactionRow.all()

    // Mirrors `CloudKitTransactionRepository`'s `loadAndFilter`: `.all`
    // and `.nonScheduledOnly` both exclude scheduled rows from the
    // page; only `.scheduledOnly` flips the predicate. Production page
    // views never want scheduled rows interleaved with their booked
    // counterparts, so the default filter (`.all`) keeps the
    // non-scheduled view shape.
    switch filter.scheduled {
    case .all, .nonScheduledOnly:
      request = request.filter(TransactionRow.Columns.recurPeriod == nil)
    case .scheduledOnly:
      request = request.filter(TransactionRow.Columns.recurPeriod != nil)
    }

    if let dateRange = filter.dateRange {
      let start = dateRange.lowerBound
      let end = dateRange.upperBound
      request = request.filter(
        TransactionRow.Columns.date >= start
          && TransactionRow.Columns.date <= end)
    }

    if let payee = filter.payee, !payee.isEmpty {
      let pattern = "%" + payee.lowercased() + "%"
      request = request.filter(
        sql: "lower(payee) LIKE ?", arguments: [pattern])
    }

    // Build the union of account ids the caller is filtering by: a single
    // `accountId` (single-account view) and / or an `accountIds` set
    // (composite group view). Empty union → no account filter. The `IN`
    // / `==` leg predicates only match non-NULL leg columns, preserving the
    // partial-index coverage on `transaction_leg`.
    var unionAccountIds: Set<UUID> = filter.accountIds
    if let accountId = filter.accountId { unionAccountIds.insert(accountId) }
    if !unionAccountIds.isEmpty {
      request = request.filter(
        legTransactionIds(
          where: unionAccountIds.contains(TransactionLegRow.Columns.accountId)
        ).contains(TransactionRow.Columns.id))
    }

    if let earmarkId = filter.earmarkId {
      request = request.filter(
        legTransactionIds(
          where: TransactionLegRow.Columns.earmarkId == earmarkId
        ).contains(TransactionRow.Columns.id))
    }

    if !filter.categoryIds.isEmpty {
      request = request.filter(
        legTransactionIds(
          where: filter.categoryIds.contains(TransactionLegRow.Columns.categoryId)
        ).contains(TransactionRow.Columns.id))
    }

    if let legType = filter.uncategorizedLegType {
      request = request.filter(
        legTransactionIds(
          where: TransactionLegRow.Columns.categoryId == nil
            && TransactionLegRow.Columns.type == legType.rawValue
        ).contains(TransactionRow.Columns.id))
    }

    return request
  }

  /// The filtered request ordered `date DESC, id ASC` — the deterministic
  /// tiebreaker pinned by `TransactionRepositoryOrderingTests` that makes
  /// `LIMIT/OFFSET` paging stable. Index-backed by `transaction_by_date_id`.
  static func orderedFilteredRequest(
    filter: TransactionFilter
  ) -> QueryInterfaceRequest<TransactionRow> {
    filteredTransactionRequest(filter: filter)
      .order(
        TransactionRow.Columns.date.desc,
        TransactionRow.Columns.id.asc)
  }

  /// A `transaction_leg` subquery selecting `transaction_id` for legs
  /// matching `predicate`, used as `id IN (…)` against the `"transaction"`
  /// table. Kept as a request (not fetched) so the predicate constrains the
  /// outer paginated query in SQL.
  private static func legTransactionIds(
    where predicate: some SQLSpecificExpressible
  ) -> QueryInterfaceRequest<UUID> {
    TransactionLegRow
      .filter(predicate)
      .select(TransactionLegRow.Columns.transactionId, as: UUID.self)
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

  /// Per-instrument subtotals for the transactions sorting AFTER the page
  /// (older rows, since the order is `date DESC`). Computes
  /// `SUM(quantity)` per instrument in a single SQL aggregate over the
  /// member-account legs whose transaction falls in the after-page
  /// window — expressed as `transaction_id IN (<ordered filtered request
  /// LIMIT -1 OFFSET afterPageOffset>)` so the after-page id list never
  /// round-trips into Swift. Sums only legs whose `account_id` is in
  /// `accountIds` — a single account for a single-account view, or the
  /// member set for an account-group view — so a transfer's non-member
  /// leg is excluded. The `account_id IN (…)` predicate never matches a
  /// NULL `account_id`, preserving the `leg_by_account` partial-index
  /// coverage; all UUIDs bind as parameters through the query interface.
  /// Returns empty when there is no account scope (and an empty result
  /// when the page is the last one, since the subquery then selects no
  /// ids), so the caller needs no explicit branch. Mirrors
  /// `CloudKitTransactionRepository.subtotalsAfterPage`.
  static func subtotalsAfterPage(
    database: Database,
    orderedRequest: QueryInterfaceRequest<TransactionRow>,
    afterPageOffset: Int,
    accountIds: Set<UUID>,
    instruments: [String: Instrument]
  ) throws -> [SubtotalEntry] {
    guard !accountIds.isEmpty else { return [] }

    // The after-page transaction ids as a GRDB subquery (NOT fetched):
    // the ordered filtered request windowed past the page via
    // `LIMIT -1 OFFSET afterPageOffset`, selecting only `id`. Passing it
    // straight into `transaction_id IN (…)` keeps the subtotal a single
    // SQL statement.
    let afterPageIds =
      orderedRequest
      .select(TransactionRow.Columns.id, as: UUID.self)
      .limit(-1, offset: afterPageOffset)

    let rows =
      try TransactionLegRow
      .filter(accountIds.contains(TransactionLegRow.Columns.accountId))
      .filter(afterPageIds.contains(TransactionLegRow.Columns.transactionId))
      .group(TransactionLegRow.Columns.instrumentId)
      .select(
        TransactionLegRow.Columns.instrumentId,
        sum(TransactionLegRow.Columns.quantity).forKey("quantity")
      )
      .asRequest(of: Row.self)
      .fetchAll(database)

    return rows.compactMap { row in
      guard
        let instrumentId: String = row["instrument_id"],
        let storage: Int64 = row["quantity"]
      else { return nil }
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
