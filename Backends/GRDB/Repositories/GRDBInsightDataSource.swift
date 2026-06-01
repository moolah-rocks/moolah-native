import Foundation
import GRDB
import OSLog

/// GRDB-backed `InsightDataSource`. Produces the pre-aggregated insight
/// summaries + a bounded recent-candidate window directly from
/// `data.sqlite`, never materialising the full transaction history.
///
/// Each method drives a SQL `GROUP BY` (or a bounded, capped projection)
/// and converts the summed / projected rows to the profile instrument on
/// each row's own `(day, instrument)` bucket — reusing
/// `GRDBAnalysisRepository.convertedQuantity` / `.parseDayString` so the
/// per-day rate-cache equivalence required by
/// `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 5 is preserved and a
/// single-currency profile pays ~nothing.
///
/// **Concurrency.** `final class` + `@unchecked Sendable`, mirroring
/// `GRDBAnalysisRepository`: all stored properties are `let`, `database`
/// and `conversionService` are `Sendable`, and `logger` is a `Sendable`
/// value type. Nothing mutates post-init.
final class GRDBInsightDataSource: InsightDataSource, @unchecked Sendable {
  // Cross-extension internals. Sibling files reach these `internal`
  // members rather than the `private` storage:
  //   `+CategorySpend.swift` — categorySpend / accountSpend / categorySamples
  //   `+Payees.swift`        — payeeSummaries + the normalize-and-fold
  //   `+RecentCandidates.swift` — recentCandidates + assemble
  // The day-parse and `(qty, instrument) → InstrumentAmount` conversion
  // helpers are shared from `GRDBAnalysisRepository` (same module).
  private let database: any DatabaseWriter
  private let instrument: Instrument
  private let conversionService: any InstrumentConversionService
  /// Resolves the canonical instrument lookup table. Fetched once per
  /// method *before* the per-profile read snapshot opens — the registry
  /// lives on a separate database, so it cannot be joined into the
  /// snapshot. Mirrors `GRDBAnalysisRepository`.
  private let instrumentResolver: any InstrumentMapResolving
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "GRDBInsightDataSource")

  init(
    database: any DatabaseWriter,
    instrument: Instrument,
    conversionService: any InstrumentConversionService,
    instrumentResolver: any InstrumentMapResolving
  ) {
    self.database = database
    self.instrument = instrument
    self.conversionService = conversionService
    self.instrumentResolver = instrumentResolver
  }

  // MARK: - Shared access for sibling extensions

  /// The profile (reporting) instrument every summary is reduced to.
  var profileInstrument: Instrument { instrument }

  /// The conversion service, exposed for the projecting sibling methods.
  var converter: any InstrumentConversionService { conversionService }

  /// The shared diagnostics logger, exposed for sibling methods.
  var log: Logger { logger }

  /// Resolve the instrument lookup table outside any read snapshot.
  func resolveInstruments() async throws -> [String: Instrument] {
    try await instrumentResolver.instrumentMap()
  }

  /// The per-profile database, exposed so sibling extensions can open a
  /// read snapshot without reaching into `private` storage.
  var profileDatabase: any DatabaseWriter { database }

  /// The inclusive lower bound for a trailing window of `windowDays`,
  /// computed from the injected `context.now` so summaries stay
  /// deterministic in tests.
  func cutoff(windowDays: Int, context: InsightContext) -> Date? {
    context.calendar.date(byAdding: .day, value: -windowDays, to: context.now)
  }

  /// Resolve a SQL `instrument_id` to an `Instrument`, falling back to a
  /// fiat registration for ids absent from the canonical map — the same
  /// fallback `GRDBAnalysisRepository` uses.
  func instrument(
    forId id: String, in map: [String: Instrument]
  ) -> Instrument {
    map[id] ?? Instrument.fiat(code: id)
  }

  // MARK: - dailyTotals

  /// One `(day, instrument)` bucket of summed income / expense quantities.
  struct DailyTotalsRow: Sendable {
    let day: String
    let instrumentId: String
    let incomeQty: Int64
    let expenseQty: Int64
  }

  func dailyTotals(context: InsightContext) async throws -> [DailySpendSummary] {
    let instruments = try await resolveInstruments()
    let rows = try await profileDatabase.read { database -> [DailyTotalsRow] in
      let sql = """
        SELECT DATE(t.date)      AS day,
               leg.instrument_id AS instrument_id,
               SUM(CASE WHEN leg.type = 'income'  THEN leg.quantity ELSE 0 END) AS income_qty,
               SUM(CASE WHEN leg.type = 'expense' THEN leg.quantity ELSE 0 END) AS expense_qty
        FROM transaction_leg leg
        JOIN "transaction"    t ON leg.transaction_id = t.id
        WHERE t.recur_period IS NULL
          AND leg.type IN ('income', 'expense')
        GROUP BY day, leg.instrument_id
        ORDER BY day ASC
        """
      return try Row.fetchAll(database, sql: sql).compactMap { row in
        guard let day: String = row["day"],
          let instrumentId: String = row["instrument_id"]
        else { return nil }
        return DailyTotalsRow(
          day: day,
          instrumentId: instrumentId,
          incomeQty: row["income_qty"] ?? 0,
          expenseQty: row["expense_qty"] ?? 0)
      }
    }
    return try await foldDailyTotals(rows, instruments: instruments, context: context)
  }

  /// Convert each `(day, instrument)` bucket on its own day and fold into
  /// one `DailySpendSummary` per calendar day. A bucket whose conversion
  /// fails is skipped (Rule 11) and logged; sibling days still render.
  private func foldDailyTotals(
    _ rows: [DailyTotalsRow],
    instruments: [String: Instrument],
    context: InsightContext
  ) async throws -> [DailySpendSummary] {
    var income: [Date: InstrumentAmount] = [:]
    var expense: [Date: InstrumentAmount] = [:]
    let zero = context.zero
    for row in rows {
      guard let day = GRDBAnalysisRepository.parseDayString(row.day) else {
        logger.error("dailyTotals: unparseable day '\(row.day, privacy: .public)'")
        continue
      }
      let source = instrument(forId: row.instrumentId, in: instruments)
      do {
        let incomeAmount = try await GRDBAnalysisRepository.convertedQuantity(
          storageValue: row.incomeQty,
          instrument: source,
          to: instrument,
          on: day,
          conversionService: conversionService)
        let expenseAmount = try await GRDBAnalysisRepository.convertedQuantity(
          storageValue: row.expenseQty,
          instrument: source,
          to: instrument,
          on: day,
          conversionService: conversionService)
        income[day] = (income[day] ?? zero) + incomeAmount
        expense[day] = (expense[day] ?? zero) + expenseAmount
      } catch let cancel as CancellationError {
        throw cancel
      } catch {
        logger.warning(
          """
          dailyTotals: skipping day=\(row.day, privacy: .public) \
          instrument=\(row.instrumentId, privacy: .public) — conversion failed: \
          \(error.localizedDescription, privacy: .public)
          """)
      }
    }
    let days = Set(income.keys).union(expense.keys)
    return
      days
      .map { day in
        DailySpendSummary(
          day: day,
          expense: expense[day] ?? zero,
          income: income[day] ?? zero)
      }
      .sorted { $0.day < $1.day }
  }
}
