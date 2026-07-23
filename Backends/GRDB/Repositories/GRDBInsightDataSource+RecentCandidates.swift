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

  struct PayeeAvailabilityKey: Sendable, Hashable {
    let normalizedPayee: String
    let isExpense: Bool
  }

  struct CandidateProjection: Sendable {
    let items: [InsightTransaction]
    let dropped: Int
    let unavailablePayees: Set<PayeeAvailabilityKey>
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
  ) async throws -> CandidateProjection {
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
  ) async throws -> CandidateProjection {
    var items: [InsightTransaction] = []
    var dropped = 0
    var unavailablePayees: Set<PayeeAvailabilityKey> = []
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
        Self.recordUnavailablePayee(for: row, type: type, in: &unavailablePayees)
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
    return CandidateProjection(
      items: items, dropped: dropped, unavailablePayees: unavailablePayees)
  }

  private static func recordUnavailablePayee(
    for row: CandidateRow,
    type: TransactionType,
    in unavailablePayees: inout Set<PayeeAvailabilityKey>
  ) {
    let normalizedPayee = PayeeNormalizer.normalize(row.payee)
    guard !normalizedPayee.isEmpty else { return }
    unavailablePayees.insert(
      PayeeAvailabilityKey(
        normalizedPayee: normalizedPayee,
        isExpense: type == .expense))
  }

  // MARK: - assemble

  func assemble(
    window: InsightDataWindow,
    categories: Categories,
    context: InsightContext
  ) async throws -> InsightDataSummary {
    async let dailyResult = dailyTotalsWithDrops(context: context)
    async let categorySpendResult = categorySpendWithDrops(
      windowDays: window.categorySpendDays, categories: categories, context: context)
    async let unbudgetedSpendResult = categorySpendWithDrops(
      windowDays: window.unbudgetedSpendDays, categories: categories, context: context)
    async let accountSpendResult = accountSpendWithDrops(
      windowDays: window.accountSpendDays, context: context)
    async let payeesResult = payeeSummariesWithDrops(
      windowDays: window.payeeCadenceDays, context: context)
    async let samplesResult = categorySamplesWithDrops(
      windowDays: window.sampleDays,
      maxPerCategory: window.maxSamplesPerCategory,
      context: context)
    async let incomeSamplesResult = incomeSourceSamplesWithDrops(
      windowDays: window.sampleDays,
      maxCount: window.maxIncomeSamples,
      context: context)
    async let candidatesResult = recentCandidatesWithDrops(
      windowDays: window.recentCandidateDays, categories: categories, context: context)
    let daily = try await dailyResult
    let categorySpendSummaries = try await categorySpendResult
    let unbudgetedSpendSummaries = try await unbudgetedSpendResult
    let accountSpendSummaries = try await accountSpendResult
    let payeeResult = try await payeesResult
    let samples = try await samplesResult
    let incomeSamples = try await incomeSamplesResult
    let candidates = try await candidatesResult
    return InsightDataSummary(
      dailyTotals: daily.items,
      categorySpend: categorySpendSummaries.items,
      unbudgetedCategorySpend: unbudgetedSpendSummaries.items,
      accountSpend: accountSpendSummaries.items,
      payees: payeeResult.payees,
      categorySamples: samples.items,
      incomeSourceSamples: incomeSamples.items,
      recentCandidates: candidates.items,
      availability: InsightDataSummary.Availability(
        dailyTotals: daily.dropped == 0,
        categorySpend: categorySpendSummaries.dropped == 0,
        unbudgetedCategorySpend: unbudgetedSpendSummaries.dropped == 0,
        accountSpend: accountSpendSummaries.dropped == 0,
        payees: payeeResult.dropped == 0,
        categorySamples: samples.dropped == 0,
        incomeSourceSamples: incomeSamples.dropped == 0,
        recentCandidates: candidates.dropped == 0))
  }
}
