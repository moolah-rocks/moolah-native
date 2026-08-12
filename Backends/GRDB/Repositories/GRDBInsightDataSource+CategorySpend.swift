import Foundation
import GRDB

/// Windowed per-category / per-account spend sums and the per-category MAD
/// baseline samples. Pure SQL `GROUP BY` aggregations (and one capped
/// projection) mirroring `GRDBAnalysisRepository+ExpenseBreakdown` — the
/// summed rows convert on their own `(day, instrument)` bucket.
extension GRDBInsightDataSource {
  /// One `(day, key, instrument)` bucket of summed expense quantity, where
  /// `key` is the category id (category spend) or account id (account
  /// spend).
  struct SpendBucketRow: Sendable {
    let day: String
    let key: UUID?
    let instrumentId: String
    let qty: Int64
    let legCount: Int
  }

  struct FoldedSpendBuckets: Sendable {
    let values: [UUID?: (total: InstrumentAmount, count: Int)]
    let dropped: Int
    let unavailableKeys: Set<UUID?>
  }

  func categorySpend(
    windowDays: Int,
    categories: Categories,
    context: InsightContext
  ) async throws -> [CategorySpendSummary] {
    try await categorySpendWithDrops(
      windowDays: windowDays, categories: categories, context: context
    ).items
  }

  func categorySpendWithDrops(
    windowDays: Int,
    categories: Categories,
    context: InsightContext
  ) async throws -> (items: [CategorySpendSummary], dropped: Int) {
    let window = trailingWindow(windowDays: windowDays, context: context)
    let instruments = try await resolveInstruments()
    let rows = try await profileDatabase.read { database in
      // The two spend aggregations differ only in their grouping column;
      // each is its own string-literal SQL (no column-name splicing) so no
      // dynamic SQL is composed — see `guides/DATABASE_CODE_GUIDE.md` §4.
      let sqlRows = try Row.fetchAll(
        database,
        sql: """
          SELECT DATE(t.date)      AS day,
                 leg.category_id   AS dim,
                 leg.instrument_id AS instrument_id,
                 SUM(leg.quantity) AS qty,
                 COUNT(*)          AS n
          FROM transaction_leg leg
          JOIN "transaction"    t ON leg.transaction_id = t.id
          WHERE t.recur_period IS NULL
            AND leg.type = 'expense'
            AND leg.category_id IS NOT NULL
            AND (:after IS NULL OR t.date >= :after)
            AND (:through IS NULL OR t.date <= :through)
          GROUP BY day, dim, instrument_id
          ORDER BY day ASC
          """,
        arguments: ["after": window?.lowerBound, "through": window?.upperBound])
      return sqlRows.compactMap(Self.decodeSpendBucket(_:))
    }
    let folded = try await foldSpendBuckets(rows, instruments: instruments, context: context)
    let items =
      folded.values
      .map { key, value in
        let path = key.flatMap { categories.by(id: $0) }.map { categories.path(for: $0) }
        return CategorySpendSummary(
          categoryId: key,
          categoryPath: path,
          total: value.total,
          legCount: value.count,
          hasUnavailableData: folded.unavailableKeys.contains(key))
      }
      .sorted { lhs, rhs in lhs.total.quantity < rhs.total.quantity }
    return (items, folded.dropped)
  }

  func accountSpend(
    windowDays: Int,
    context: InsightContext
  ) async throws -> [AccountSpendSummary] {
    try await accountSpendWithDrops(windowDays: windowDays, context: context).items
  }

  func accountSpendWithDrops(
    windowDays: Int,
    context: InsightContext
  ) async throws -> (items: [AccountSpendSummary], dropped: Int) {
    let window = trailingWindow(windowDays: windowDays, context: context)
    let instruments = try await resolveInstruments()
    let rows = try await profileDatabase.read { database in
      let sqlRows = try Row.fetchAll(
        database,
        sql: """
          SELECT DATE(t.date)      AS day,
                 leg.account_id    AS dim,
                 leg.instrument_id AS instrument_id,
                 SUM(leg.quantity) AS qty,
                 COUNT(*)          AS n
          FROM transaction_leg leg
          JOIN "transaction"    t ON leg.transaction_id = t.id
          WHERE t.recur_period IS NULL
            AND leg.type = 'expense'
            AND leg.account_id IS NOT NULL
            AND (:after IS NULL OR t.date >= :after)
            AND (:through IS NULL OR t.date <= :through)
          GROUP BY day, dim, instrument_id
          ORDER BY day ASC
          """,
        arguments: ["after": window?.lowerBound, "through": window?.upperBound])
      return sqlRows.compactMap(Self.decodeSpendBucket(_:))
    }
    let folded = try await foldSpendBuckets(rows, instruments: instruments, context: context)
    let items =
      folded.values
      .map { key, value in
        AccountSpendSummary(accountId: key, total: value.total, legCount: value.count)
      }
      .sorted { lhs, rhs in lhs.total.quantity < rhs.total.quantity }
    return (items, folded.dropped)
  }

  /// Decode one `(day, dim, instrument, qty, n)` aggregation row shared by
  /// the category and account spend queries (their `dim` is `category_id`
  /// / `account_id` respectively). The shapes are plan-pinned in
  /// `InsightDataSourcePlanPinningTests` against the
  /// `leg_analysis_by_type_category` / `leg_analysis_by_type_account`
  /// covering composites.
  private static func decodeSpendBucket(_ row: Row) -> SpendBucketRow? {
    guard let day: String = row["day"],
      let instrumentId: String = row["instrument_id"]
    else { return nil }
    return SpendBucketRow(
      day: day,
      key: row["dim"],
      instrumentId: instrumentId,
      qty: row["qty"] ?? 0,
      legCount: row["n"] ?? 0)
  }

  /// Convert each bucket on its own day and accumulate per key. A bucket
  /// whose conversion fails is skipped (Rule 11) and logged.
  private func foldSpendBuckets(
    _ rows: [SpendBucketRow],
    instruments: [String: Instrument],
    context: InsightContext
  ) async throws -> FoldedSpendBuckets {
    var totals: [UUID?: InstrumentAmount] = [:]
    var counts: [UUID?: Int] = [:]
    let zero = context.zero
    var dropped = 0
    var unavailableKeys: Set<UUID?> = []
    for row in rows {
      guard let day = GRDBAnalysisRepository.parseDayString(row.day) else {
        log.error("spendBuckets: unparseable day '\(row.day, privacy: .public)'")
        continue
      }
      let source = instrument(forId: row.instrumentId, in: instruments)
      do {
        let amount = try await GRDBAnalysisRepository.convertedQuantity(
          storageValue: row.qty,
          instrument: source,
          to: profileInstrument,
          on: day,
          conversionService: converter)
        totals[row.key] = (totals[row.key] ?? zero) + amount
        counts[row.key, default: 0] += row.legCount
      } catch let cancel as CancellationError {
        throw cancel
      } catch {
        dropped += 1
        totals[row.key] = totals[row.key] ?? zero
        unavailableKeys.insert(row.key)
        log.warning(
          """
          spendBuckets: skipping day=\(row.day, privacy: .public) \
          instrument=\(row.instrumentId, privacy: .public) — conversion failed: \
          \(error.localizedDescription, privacy: .public)
          """)
      }
    }
    let values = totals.reduce(into: [:]) { result, entry in
      result[entry.key] = (entry.value, counts[entry.key] ?? 0)
    }
    return FoldedSpendBuckets(
      values: values, dropped: dropped, unavailableKeys: unavailableKeys)
  }
}
