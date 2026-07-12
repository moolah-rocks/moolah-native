import Foundation
import GRDB

/// SQL-side helpers for the `fetchDailyBalances` aggregation. Holds
/// the four query strings, the row decoders, scheduled-transaction
/// loader, accounts/instrument-map fetch, and the `database.read`
/// entry point. The Swift assembly path (the per-day position-book
/// walk + forecast fold) lives in `+DailyBalances.swift`.
extension GRDBAnalysisRepository {

  // MARK: - Public read entry point

  /// Loads every input the assembly walk needs in a single
  /// `database.read` snapshot:
  /// - per-`(day, account, instrument, type)` SUMs split on the
  ///   `:after` cutoff (the post-cutoff rows drive the day-by-day
  ///   walk; the pre-cutoff rows seed the `PositionBook`);
  /// - per-`(day, earmark, instrument, type)` SUMs split the same
  ///   way;
  /// - the scheduled `[Transaction]` for forecast extrapolation;
  /// - the accounts table (so every investment-like account can be
  ///   valued from positions);
  /// - the instrument map.
  ///
  /// One snapshot keeps the four leg-side reads and the scheduled
  /// transactions consistent — three independent reads under WAL
  /// could surface a leg referencing a transaction that hasn't yet
  /// appeared in the transaction list.
  static func fetchDailyBalancesAggregation(
    database: any DatabaseReader,
    instruments: [String: Instrument],
    after: Date?,
    forecastUntil: Date?
  ) async throws -> DailyBalancesAggregation {
    try await database.read { database -> DailyBalancesAggregation in
      try Self.readDailyBalancesAggregation(
        database: database,
        instruments: instruments,
        after: after,
        forecastUntil: forecastUntil)
    }
  }

  /// Synchronous read body for `fetchDailyBalancesAggregation`. Lifted
  /// out of the `database.read` closure so the closure body stays
  /// under the SwiftLint `closure_body_length` budget. `instruments` is
  /// resolved via the injected `InstrumentMapResolving` before this
  /// snapshot opens (the canonical registry is a separate database) and
  /// threaded in rather than re-read here.
  private static func readDailyBalancesAggregation(
    database: Database,
    instruments: [String: Instrument],
    after: Date?,
    forecastUntil: Date?
  ) throws -> DailyBalancesAggregation {
    let accountRows = try Self.fetchAccountDeltaRowsPostCutoff(
      database: database, after: after)
    let earmarkRows = try Self.fetchEarmarkDeltaRowsPostCutoff(
      database: database, after: after)
    let (priorAccountRows, priorEarmarkRows) = try Self.fetchPriorDeltaRows(
      database: database, after: after)
    let investmentAccountIds = try Self.fetchInvestmentAccountIds(
      database: database)
    let instrumentMap = instruments
    let scheduled =
      forecastUntil != nil
      ? try Self.fetchScheduledTransactions(
        database: database, instruments: instrumentMap) : []
    // Pre-filter investment-position rows out of the already-fetched arrays.
    // Doing the filter inside the read closure (not later) keeps every
    // input the assembly walk needs inside one MVCC snapshot and saves
    // re-checking membership inside the per-day fold.
    let priorInvestmentAccountRows = priorAccountRows.filter {
      investmentAccountIds.contains($0.accountId)
    }
    let investmentAccountRows = accountRows.filter {
      investmentAccountIds.contains($0.accountId)
    }
    return DailyBalancesAggregation(
      priorAccountRows: priorAccountRows,
      priorEarmarkRows: priorEarmarkRows,
      accountRows: accountRows,
      earmarkRows: earmarkRows,
      investmentAccountIds: investmentAccountIds,
      priorInvestmentAccountRows: priorInvestmentAccountRows,
      investmentAccountRows: investmentAccountRows,
      scheduled: scheduled,
      instrumentMap: instrumentMap,
      forecastUntil: forecastUntil)
  }

  // MARK: - Private SQL fetches

  /// Fetch the pre-`after` baseline rows. Returns a tuple of
  /// `(priorAccountRows, priorEarmarkRows)` so the caller can split
  /// the seed step into its own assignment without re-running the
  /// `after != nil` branch.
  private static func fetchPriorDeltaRows(
    database: Database, after: Date?
  ) throws -> ([DailyBalanceAccountRow], [DailyBalanceEarmarkRow]) {
    guard after != nil else { return ([], []) }
    let priorAccountRows = try Self.fetchAccountDeltaRowsPreCutoff(
      database: database, after: after)
    let priorEarmarkRows = try Self.fetchEarmarkDeltaRowsPreCutoff(
      database: database, after: after)
    return (priorAccountRows, priorEarmarkRows)
  }

  /// Runs the per-`(day, account, instrument, type)` SUM aggregation
  /// for the post-cutoff window pinned by
  /// `DailyBalancesPlanPinningTests.fetchDailyBalancesAccountDimensionAvoidsScan`.
  /// Restricted to non-scheduled legs with a non-null `account_id` —
  /// the earmark dimension is fetched by a sibling query so the leg-
  /// side index can stay covering on `leg_analysis_by_earmark_type`
  /// for that read.
  ///
  /// `MIN(t.date)` carries the earliest raw `t.date` instant inside
  /// each UTC-day group. Swift uses it as the `date:` argument to
  /// `PositionBook.dailyBalance(...)`, whose `dayKey` falls out of
  /// `Calendar.current.startOfDay(for:)` — i.e. the user's *local*
  /// day. Without the sample date the only fallback would be the
  /// UTC day-string, which `Calendar.current.startOfDay` interprets
  /// as a different local-day on every non-UTC runner and breaks
  /// every contract test that anchors on
  /// `Calendar.current.startOfDay(for: today)`.
  ///
  /// The plan typically resolves through `leg_by_account` (planner's
  /// preferred index for the `account_id IS NOT NULL` predicate) or
  /// the covering composite `leg_analysis_by_type_account`; either is
  /// acceptable because both keep the read off a full table scan.
  private static func fetchAccountDeltaRowsPostCutoff(
    database: Database, after: Date?
  ) throws -> [DailyBalanceAccountRow] {
    let sql = """
      SELECT DATE(t.date)        AS day,
             MIN(t.date)         AS sample_date,
             leg.account_id      AS account_id,
             leg.instrument_id   AS instrument_id,
             leg.type            AS type,
             SUM(leg.quantity)   AS qty
      FROM transaction_leg leg
      JOIN "transaction"    t ON leg.transaction_id = t.id
      WHERE t.recur_period IS NULL
        AND (:after IS NULL OR t.date >= :after)
        AND leg.account_id IS NOT NULL
      GROUP BY day, leg.account_id, leg.instrument_id, leg.type
      ORDER BY day ASC
      """
    let arguments: StatementArguments = ["after": after]
    let sqlRows = try Row.fetchAll(database, sql: sql, arguments: arguments)
    return Self.decodeAccountDeltaRows(sqlRows)
  }

  /// Pre-cutoff sibling of `fetchAccountDeltaRowsPostCutoff` — same
  /// SUM aggregation but selecting the legs strictly *before*
  /// `:after`. The result seeds the `PositionBook` under
  /// `asStartingBalance: true` semantics. Pinned by
  /// `DailyBalancesPlanPinningTests.fetchDailyBalancesAccountDimensionPreCutoffAvoidsScan`.
  ///
  /// Plain string-literal SQL — the only reason this is a separate
  /// function (rather than a parameterised cutoff fragment) is that
  /// `guides/DATABASE_CODE_GUIDE.md` §4 forbids dynamically composed
  /// `sql:` arguments. Splitting the function gives each variant a
  /// fully literal query string.
  private static func fetchAccountDeltaRowsPreCutoff(
    database: Database, after: Date?
  ) throws -> [DailyBalanceAccountRow] {
    let sql = """
      SELECT DATE(t.date)        AS day,
             MIN(t.date)         AS sample_date,
             leg.account_id      AS account_id,
             leg.instrument_id   AS instrument_id,
             leg.type            AS type,
             SUM(leg.quantity)   AS qty
      FROM transaction_leg leg
      JOIN "transaction"    t ON leg.transaction_id = t.id
      WHERE t.recur_period IS NULL
        AND :after IS NOT NULL AND t.date < :after
        AND leg.account_id IS NOT NULL
      GROUP BY day, leg.account_id, leg.instrument_id, leg.type
      ORDER BY day ASC
      """
    let arguments: StatementArguments = ["after": after]
    let sqlRows = try Row.fetchAll(database, sql: sql, arguments: arguments)
    return Self.decodeAccountDeltaRows(sqlRows)
  }

  /// Runs the per-`(day, earmark, instrument, type)` SUM aggregation
  /// for the post-cutoff window pinned by
  /// `DailyBalancesPlanPinningTests.fetchDailyBalancesEarmarkDimensionUsesEarmarkIndex`.
  /// Restricted to non-scheduled legs with a non-null `earmark_id` —
  /// the partial composite `leg_analysis_by_earmark_type` covers
  /// `(earmark_id, type, instrument_id, transaction_id, quantity)` so
  /// the planner emits `USING COVERING INDEX`.
  ///
  /// See the account-dimension query for the rationale on
  /// `MIN(t.date) AS sample_date` — same local-day mapping concern.
  private static func fetchEarmarkDeltaRowsPostCutoff(
    database: Database, after: Date?
  ) throws -> [DailyBalanceEarmarkRow] {
    let sql = """
      SELECT DATE(t.date)        AS day,
             MIN(t.date)         AS sample_date,
             leg.earmark_id      AS earmark_id,
             leg.instrument_id   AS instrument_id,
             leg.type            AS type,
             SUM(leg.quantity)   AS qty
      FROM transaction_leg leg
      JOIN "transaction"    t ON leg.transaction_id = t.id
      WHERE t.recur_period IS NULL
        AND (:after IS NULL OR t.date >= :after)
        AND leg.earmark_id IS NOT NULL
      GROUP BY day, leg.earmark_id, leg.instrument_id, leg.type
      ORDER BY day ASC
      """
    let arguments: StatementArguments = ["after": after]
    let sqlRows = try Row.fetchAll(database, sql: sql, arguments: arguments)
    return Self.decodeEarmarkDeltaRows(sqlRows)
  }

  /// Pre-cutoff sibling of `fetchEarmarkDeltaRowsPostCutoff` — same
  /// SUM aggregation but selecting the legs strictly *before*
  /// `:after`. Pinned by
  /// `DailyBalancesPlanPinningTests.fetchDailyBalancesEarmarkDimensionPreCutoffUsesEarmarkIndex`.
  ///
  /// Plain string-literal SQL for the same `guides/DATABASE_CODE_GUIDE.md`
  /// §4 reason as the account-dimension pre-cutoff variant.
  private static func fetchEarmarkDeltaRowsPreCutoff(
    database: Database, after: Date?
  ) throws -> [DailyBalanceEarmarkRow] {
    let sql = """
      SELECT DATE(t.date)        AS day,
             MIN(t.date)         AS sample_date,
             leg.earmark_id      AS earmark_id,
             leg.instrument_id   AS instrument_id,
             leg.type            AS type,
             SUM(leg.quantity)   AS qty
      FROM transaction_leg leg
      JOIN "transaction"    t ON leg.transaction_id = t.id
      WHERE t.recur_period IS NULL
        AND :after IS NOT NULL AND t.date < :after
        AND leg.earmark_id IS NOT NULL
      GROUP BY day, leg.earmark_id, leg.instrument_id, leg.type
      ORDER BY day ASC
      """
    let arguments: StatementArguments = ["after": after]
    let sqlRows = try Row.fetchAll(database, sql: sql, arguments: arguments)
    return Self.decodeEarmarkDeltaRows(sqlRows)
  }

  /// Loads the scheduled `[Transaction]` set used by the forecast
  /// extrapolator. Mirrors the existing per-leg materialisation —
  /// scheduled transactions stay Swift-side because SQL can't
  /// extrapolate recurring patterns. Filters to `recur_period IS NOT
  /// NULL` via the partial `transaction_scheduled` index so the read
  /// stays off a full scan.
  private static func fetchScheduledTransactions(
    database: Database, instruments: [String: Instrument]
  ) throws -> [Transaction] {
    let txnRows =
      try TransactionRow
      .filter(TransactionRow.Columns.recurPeriod != nil)
      .fetchAll(database)
    guard !txnRows.isEmpty else { return [] }
    let txnIds = Set(txnRows.map(\.id))
    let legRows =
      try TransactionLegRow
      .filter(txnIds.contains(TransactionLegRow.Columns.transactionId))
      .fetchAll(database)
    let legsByTxnId = Dictionary(grouping: legRows, by: \.transactionId)
    return try txnRows.map { row -> Transaction in
      let legs =
        try (legsByTxnId[row.id] ?? [])
        .sorted { $0.sortOrder < $1.sortOrder }
        .map { legRow -> TransactionLeg in
          let legInstrument =
            instruments[legRow.instrumentId]
            ?? Instrument.fiat(code: legRow.instrumentId)
          return try legRow.toDomain(instrument: legInstrument)
        }
      return try row.toDomain(legs: legs)
    }
  }

  // MARK: - Row decoders

  /// Shared decoder for the per-`(day, account, instrument, type)` SUM
  /// rows. Used by both the post-cutoff and pre-cutoff variants of
  /// `fetchAccountDeltaRows*` — the two queries differ only in their
  /// WHERE clause, the projected columns and decoded shape are
  /// identical.
  private static func decodeAccountDeltaRows(_ sqlRows: [Row]) -> [DailyBalanceAccountRow] {
    var rows: [DailyBalanceAccountRow] = []
    rows.reserveCapacity(sqlRows.count)
    for row in sqlRows {
      guard let day: String = row["day"] else { continue }
      guard let sampleDate: Date = row["sample_date"] else { continue }
      guard let accountId: UUID = row["account_id"] else { continue }
      guard let instrumentId: String = row["instrument_id"] else { continue }
      guard let type: String = row["type"] else { continue }
      guard let qty: Int64 = row["qty"] else { continue }
      rows.append(
        DailyBalanceAccountRow(
          day: day,
          sampleDate: sampleDate,
          accountId: accountId,
          instrumentId: instrumentId,
          type: type,
          qty: qty))
    }
    return rows
  }

  /// Shared decoder for the per-`(day, earmark, instrument, type)` SUM
  /// rows. Sister of `decodeAccountDeltaRows`.
  private static func decodeEarmarkDeltaRows(_ sqlRows: [Row]) -> [DailyBalanceEarmarkRow] {
    var rows: [DailyBalanceEarmarkRow] = []
    rows.reserveCapacity(sqlRows.count)
    for row in sqlRows {
      guard let day: String = row["day"] else { continue }
      guard let sampleDate: Date = row["sample_date"] else { continue }
      guard let earmarkId: UUID = row["earmark_id"] else { continue }
      guard let instrumentId: String = row["instrument_id"] else { continue }
      guard let type: String = row["type"] else { continue }
      guard let qty: Int64 = row["qty"] else { continue }
      rows.append(
        DailyBalanceEarmarkRow(
          day: day,
          sampleDate: sampleDate,
          earmarkId: earmarkId,
          instrumentId: instrumentId,
          type: type,
          qty: qty))
    }
    return rows
  }
}
