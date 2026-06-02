import Foundation

/// Per-normalized-payee cadence summaries over the bounded cadence window.
///
/// Reuses the recent-candidate projection (the accepted ~13-month bounded
/// window of projected columns) and folds it by `(normalizedPayee,
/// direction)` in Swift — payee normalisation (`PayeeNormalizer`) can't run
/// in SQL, so the clustering happens here. Memory stays `O(payees +
/// windowed occurrences)`.
extension GRDBInsightDataSource {
  func payeeSummaries(
    windowDays: Int,
    context: InsightContext
  ) async throws -> [PayeeSummary] {
    try await payeeSummariesWithDrops(windowDays: windowDays, context: context).payees
  }

  /// Drop-aware variant used by `assemble`: also reports the legs dropped
  /// for a failed conversion (Rule 11).
  func payeeSummariesWithDrops(
    windowDays: Int,
    context: InsightContext
  ) async throws -> (payees: [PayeeSummary], dropped: Int) {
    // Project the cadence window through the same converter as the recent
    // candidates; categories are irrelevant to a payee summary, so pass an
    // empty lookup (the projected `categoryPath` goes unused here).
    let projected = try await recentCandidatesWithDrops(
      windowDays: windowDays, categories: Categories(from: []), context: context)
    return (foldPayees(projected.items, context: context), projected.dropped)
  }

  /// Group projected legs by `(normalizedPayee, isExpense)` into cadence
  /// summaries, ascending by date. Legs with no payee can't cluster and are
  /// skipped.
  private func foldPayees(
    _ transactions: [InsightTransaction],
    context: InsightContext
  ) -> [PayeeSummary] {
    struct Key: Hashable {
      let payee: String
      let isExpense: Bool
    }
    var groups: [Key: [InsightTransaction]] = [:]
    for transaction in transactions where !transaction.normalizedPayee.isEmpty {
      let key = Key(payee: transaction.normalizedPayee, isExpense: transaction.isExpense)
      groups[key, default: []].append(transaction)
    }
    return
      groups
      .map { key, legs in
        payeeSummary(payee: key.payee, isExpense: key.isExpense, legs: legs, context: context)
      }
      .sorted { $0.normalizedPayee < $1.normalizedPayee }
  }

  /// Build one `PayeeSummary` from a payee's projected legs.
  private func payeeSummary(
    payee: String,
    isExpense: Bool,
    legs: [InsightTransaction],
    context: InsightContext
  ) -> PayeeSummary {
    let ascending = legs.sorted { $0.date < $1.date }
    let currency = context.reportingCurrency
    var total = context.zero
    var occurrences: [PayeeOccurrence] = []
    occurrences.reserveCapacity(ascending.count)
    for leg in ascending {
      let amount = InstrumentAmount(quantity: leg.amount, instrument: currency)
      total += amount
      occurrences.append(
        PayeeOccurrence(
          date: leg.date,
          amount: amount,
          categoryId: leg.categoryId,
          accountId: leg.accountId))
    }
    return PayeeSummary(
      normalizedPayee: payee,
      displayPayee: Self.representativePayee(in: ascending, fallback: payee),
      isExpense: isExpense,
      occurrenceCount: ascending.count,
      firstSeen: ascending.first?.date ?? context.now,
      lastSeen: ascending.last?.date ?? context.now,
      windowedTotal: total,
      occurrences: occurrences)
  }

  /// The most frequent raw payee spelling in the group, for narration;
  /// falls back to the normalized key when no raw payee is present.
  private static func representativePayee(
    in legs: [InsightTransaction], fallback: String
  ) -> String {
    var counts: [String: Int] = [:]
    for case let raw? in legs.map(\.rawPayee) where !raw.isEmpty {
      counts[raw, default: 0] += 1
    }
    return counts.max { $0.value < $1.value }?.key ?? fallback
  }
}
