import Foundation
import GRDB

/// The bounded recent-candidate projection (the only place insights
/// materialise individual rows for display) and the `assemble` bundler.
///
/// The window is small by construction (`recentCandidateDays`, ~30 days),
/// so this is `O(window)` regardless of total history. These are the rows
/// the detectors that must cite a specific `transactionId` read.
extension GRDBInsightDataSource {
  /// One projected income / expense leg in the recent window.
  struct CandidateRow: Sendable {
    let transactionId: UUID
    let date: Date
    let day: String
    let payee: String?
    let qty: Int64
    let categoryId: UUID?
    let accountId: UUID?
    let instrumentId: String
    let type: String
  }

  func recentCandidates(
    windowDays: Int,
    categories: Categories,
    context: InsightContext
  ) async throws -> [InsightTransaction] {
    try await recentCandidatesWithDrops(
      windowDays: windowDays, categories: categories, context: context
    ).items
  }

  /// Drop-aware variant: also reports how many legs were dropped because
  /// their conversion failed, so `assemble` can surface a "data
  /// incomplete" signal.
  func recentCandidatesWithDrops(
    windowDays: Int,
    categories: Categories,
    context: InsightContext
  ) async throws -> (items: [InsightTransaction], dropped: Int) {
    let after = cutoff(windowDays: windowDays, context: context)
    let instruments = try await resolveInstruments()
    let rows = try await profileDatabase.read { database -> [CandidateRow] in
      let sql = """
        SELECT t.id              AS txn_id,
               t.date            AS txn_date,
               DATE(t.date)      AS day,
               t.payee           AS payee,
               leg.quantity      AS quantity,
               leg.category_id   AS category_id,
               leg.account_id    AS account_id,
               leg.instrument_id AS instrument_id,
               leg.type          AS type
        FROM transaction_leg leg
        JOIN "transaction"    t ON leg.transaction_id = t.id
        WHERE t.recur_period IS NULL
          AND leg.type IN ('income', 'expense')
          AND (:after IS NULL OR t.date >= :after)
        ORDER BY t.date DESC
        """
      let arguments: StatementArguments = ["after": after]
      return try Row.fetchAll(database, sql: sql, arguments: arguments)
        .compactMap(Self.decodeCandidateRow(_:))
    }
    return try await projectCandidates(rows, instruments: instruments, categories: categories)
  }

  private static func decodeCandidateRow(_ row: Row) -> CandidateRow? {
    guard let transactionId: UUID = row["txn_id"],
      let date: Date = row["txn_date"],
      let day: String = row["day"],
      let instrumentId: String = row["instrument_id"],
      let type: String = row["type"]
    else { return nil }
    return CandidateRow(
      transactionId: transactionId,
      date: date,
      day: day,
      payee: row["payee"],
      qty: row["quantity"] ?? 0,
      categoryId: row["category_id"],
      accountId: row["account_id"],
      instrumentId: instrumentId,
      type: type)
  }

  /// Convert each projected leg on its own day into an `InsightTransaction`
  /// in the reporting currency. A leg whose conversion fails is dropped
  /// (Rule 11) and counted — never guessed; the sign is preserved.
  private func projectCandidates(
    _ rows: [CandidateRow],
    instruments: [String: Instrument],
    categories: Categories
  ) async throws -> (items: [InsightTransaction], dropped: Int) {
    var items: [InsightTransaction] = []
    var dropped = 0
    for row in rows {
      guard let day = GRDBAnalysisRepository.parseDayString(row.day),
        let type = TransactionType(rawValue: row.type)
      else {
        log.error("recentCandidates: unparseable row day='\(row.day, privacy: .public)'")
        continue
      }
      let source = instrument(forId: row.instrumentId, in: instruments)
      let amount: InstrumentAmount
      do {
        amount = try await GRDBAnalysisRepository.convertedQuantity(
          storageValue: row.qty,
          instrument: source,
          to: profileInstrument,
          on: day,
          conversionService: converter)
      } catch let cancel as CancellationError {
        throw cancel
      } catch {
        dropped += 1
        log.warning(
          """
          recentCandidates: dropping leg txn=\(row.transactionId, privacy: .public) \
          instrument=\(row.instrumentId, privacy: .public) — conversion failed: \
          \(error.localizedDescription, privacy: .public)
          """)
        continue
      }
      let path = row.categoryId
        .flatMap { categories.by(id: $0) }
        .map { categories.path(for: $0) }
      items.append(
        InsightTransaction(
          id: row.transactionId,
          date: row.date,
          rawPayee: row.payee,
          normalizedPayee: PayeeNormalizer.normalize(row.payee),
          amount: amount.quantity,
          categoryId: row.categoryId,
          categoryPath: path,
          type: type,
          accountId: row.accountId))
    }
    return (items, dropped)
  }

  // MARK: - assemble

  func assemble(
    window: InsightDataWindow,
    categories: Categories,
    context: InsightContext
  ) async throws -> InsightDataSummary {
    let daily = try await dailyTotals(context: context)
    let categorySpendSummaries = try await categorySpend(
      windowDays: window.categorySpendDays, categories: categories, context: context)
    let accountSpendSummaries = try await accountSpend(
      windowDays: window.accountSpendDays, context: context)
    let payeeResult = try await payeeSummariesWithDrops(
      windowDays: window.payeeCadenceDays, context: context)
    let samples = try await categorySamples(
      windowDays: window.sampleDays,
      maxPerCategory: window.maxSamplesPerCategory,
      context: context)
    let candidates = try await recentCandidatesWithDrops(
      windowDays: window.recentCandidateDays, categories: categories, context: context)
    return InsightDataSummary(
      dailyTotals: daily,
      categorySpend: categorySpendSummaries,
      accountSpend: accountSpendSummaries,
      payees: payeeResult.payees,
      categorySamples: samples,
      recentCandidates: candidates.items,
      droppedLegCount: payeeResult.dropped + candidates.dropped)
  }
}
