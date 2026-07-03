import Foundation
import GRDB

/// Per-category recent expense-magnitude samples — the baseline
/// distribution the large-transaction MAD detector scores a recent
/// candidate against. A SQLite window function caps the projection at
/// `maxPerCategory` rows per category, so memory stays
/// `O(categories × cap)` rather than scaling with the window's leg count.
extension GRDBInsightDataSource {
  /// One sampled leg: the day it posted, its instrument, the raw signed
  /// quantity (converted in Swift), and — for income samples — the owning
  /// transaction's payee (`nil` for category samples, which group by
  /// `categoryId` instead).
  struct SampleRow: Sendable {
    let categoryId: UUID?
    let day: String
    let instrumentId: String
    let qty: Int64
    let payee: String?
  }

  func categorySamples(
    windowDays: Int,
    maxPerCategory: Int,
    context: InsightContext
  ) async throws -> [CategorySpendSamples] {
    let after = cutoff(windowDays: windowDays, context: context)
    let instruments = try await resolveInstruments()
    let cap = max(1, maxPerCategory)
    let rows = try await profileDatabase.read { database -> [SampleRow] in
      // `:after` / `:cap` are bound parameters; the SQL is a compile-time
      // string literal — safe per `guides/DATABASE_CODE_GUIDE.md` §4. The
      // `ROW_NUMBER()` window caps each category's sample set in SQL.
      let sql = """
        SELECT category_id, day, instrument_id, quantity
        FROM (
          SELECT leg.category_id    AS category_id,
                 DATE(t.date)       AS day,
                 leg.instrument_id  AS instrument_id,
                 leg.quantity       AS quantity,
                 ROW_NUMBER() OVER (
                   PARTITION BY leg.category_id
                   ORDER BY t.date DESC, leg.transaction_id DESC
                 ) AS rn
          FROM transaction_leg leg
          JOIN "transaction"    t ON leg.transaction_id = t.id
          WHERE t.recur_period IS NULL
            AND leg.type = 'expense'
            AND leg.category_id IS NOT NULL
            AND (:after IS NULL OR t.date >= :after)
        )
        WHERE rn <= :cap
        ORDER BY category_id ASC, rn ASC
        """
      let arguments: StatementArguments = ["after": after, "cap": cap]
      return try Row.fetchAll(database, sql: sql, arguments: arguments)
        .compactMap(Self.decodeSampleRow(_:))
    }
    return try await foldSamples(rows, instruments: instruments, context: context)
  }

  func incomeSourceSamples(
    windowDays: Int,
    maxCount: Int,
    context: InsightContext
  ) async throws -> [IncomeSourceSamples] {
    let after = cutoff(windowDays: windowDays, context: context)
    let instruments = try await resolveInstruments()
    let cap = max(1, maxCount)
    let rows = try await profileDatabase.read { database -> [SampleRow] in
      // `:after` / `:cap` are bound parameters; the SQL is a compile-time
      // string literal — safe per `guides/DATABASE_CODE_GUIDE.md` §4. The
      // `ROW_NUMBER()` window caps the global income sample set in SQL; the
      // per-source split happens in Swift (`foldIncomeSamples`) so the pinned
      // leg-index plan is preserved (partitioning by the transaction's payee
      // would force a sort the leg indexes can't satisfy).
      let sql = """
        SELECT day, instrument_id, quantity, payee
        FROM (
          SELECT DATE(t.date)       AS day,
                 leg.instrument_id  AS instrument_id,
                 leg.quantity       AS quantity,
                 t.payee            AS payee,
                 ROW_NUMBER() OVER (
                   ORDER BY t.date DESC, leg.transaction_id DESC
                 ) AS rn
          FROM transaction_leg leg
          JOIN "transaction"    t ON leg.transaction_id = t.id
          WHERE t.recur_period IS NULL
            AND leg.type = 'income'
            AND (:after IS NULL OR t.date >= :after)
        )
        WHERE rn <= :cap
        ORDER BY rn ASC
        """
      let arguments: StatementArguments = ["after": after, "cap": cap]
      return try Row.fetchAll(database, sql: sql, arguments: arguments)
        .compactMap(Self.decodeIncomeSampleRow(_:))
    }
    return try await foldIncomeSamples(rows, instruments: instruments, context: context)
  }

  private static func decodeIncomeSampleRow(_ row: Row) -> SampleRow? {
    guard let day: String = row["day"],
      let instrumentId: String = row["instrument_id"]
    else { return nil }
    return SampleRow(
      categoryId: nil,
      day: day,
      instrumentId: instrumentId,
      qty: row["quantity"] ?? 0,
      payee: row["payee"])
  }

  /// Convert each sampled income leg on its own day and group the positive
  /// magnitudes per normalized source (payee), preserving the SQL's
  /// most-recent-first order both across and within sources. Rows are dropped
  /// (creating gaps in coverage) when conversion fails (Rule 11) or when the
  /// converted quantity is non-positive (income refunds). Callers must not
  /// assume contiguous date coverage.
  private func foldIncomeSamples(
    _ rows: [SampleRow],
    instruments: [String: Instrument],
    context: InsightContext
  ) async throws -> [IncomeSourceSamples] {
    var magnitudes: [String: [Decimal]] = [:]
    var order: [String] = []
    for row in rows {
      guard let day = GRDBAnalysisRepository.parseDayString(row.day) else {
        log.error("incomeSourceSamples: unparseable day '\(row.day, privacy: .public)'")
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
        guard amount.quantity > 0 else { continue }
        let key = PayeeNormalizer.normalize(row.payee)
        if magnitudes[key] == nil { order.append(key) }
        magnitudes[key, default: []].append(amount.quantity)
      } catch let cancel as CancellationError {
        throw cancel
      } catch {
        log.warning(
          """
          incomeSourceSamples: dropping sample day=\(row.day, privacy: .public) \
          instrument=\(row.instrumentId, privacy: .public) — conversion failed: \
          \(error.localizedDescription, privacy: .public)
          """)
      }
    }
    return order.map { IncomeSourceSamples(normalizedPayee: $0, magnitudes: magnitudes[$0] ?? []) }
  }

  private static func decodeSampleRow(_ row: Row) -> SampleRow? {
    guard let day: String = row["day"],
      let instrumentId: String = row["instrument_id"]
    else { return nil }
    return SampleRow(
      categoryId: row["category_id"],
      day: day,
      instrumentId: instrumentId,
      qty: row["quantity"] ?? 0,
      payee: nil)
  }

  /// Convert each sampled leg on its own day and group the positive spend
  /// magnitudes per category, preserving the SQL's most-recent-first order.
  /// A leg whose conversion fails is dropped from the baseline and logged
  /// (Rule 11) — a thinner sample, never a guessed one.
  private func foldSamples(
    _ rows: [SampleRow],
    instruments: [String: Instrument],
    context: InsightContext
  ) async throws -> [CategorySpendSamples] {
    var magnitudes: [UUID?: [Decimal]] = [:]
    var order: [UUID?] = []
    for row in rows {
      guard let day = GRDBAnalysisRepository.parseDayString(row.day) else {
        log.error("categorySamples: unparseable day '\(row.day, privacy: .public)'")
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
        let magnitude = amount.quantity < 0 ? -amount.quantity : 0
        if magnitudes[row.categoryId] == nil { order.append(row.categoryId) }
        magnitudes[row.categoryId, default: []].append(magnitude)
      } catch let cancel as CancellationError {
        throw cancel
      } catch {
        log.warning(
          """
          categorySamples: dropping sample day=\(row.day, privacy: .public) \
          instrument=\(row.instrumentId, privacy: .public) — conversion failed: \
          \(error.localizedDescription, privacy: .public)
          """)
      }
    }
    return order.map { CategorySpendSamples(categoryId: $0, magnitudes: magnitudes[$0] ?? []) }
  }
}
