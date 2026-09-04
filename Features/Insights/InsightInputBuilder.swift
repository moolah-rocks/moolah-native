import Foundation
import os

private let logger = Logger(subsystem: "com.moolah.app", category: "InsightInputBuilder")

private struct ScheduledBillProjection: Sendable {
  let items: [ScheduledBill]
  let unavailable: [UnavailableScheduledBill]

  var hasUnavailableData: Bool { !unavailable.isEmpty }
}

/// Assembles a fully-populated `InsightInput` off the main actor.
///
/// The `@MainActor` store-derived half arrives pre-gathered as an
/// `InsightInputSnapshot`; the builder performs the async repository and
/// `InsightDataSource` work itself (off-main) and joins the two. Errors
/// propagate to the caller, which decides how to degrade — the builder never
/// swallows a failure. See `guides/CONCURRENCY_GUIDE.md` and
/// `guides/INSTRUMENT_CONVERSION_GUIDE.md`.
struct InsightInputBuilder: Sendable {
  let backend: any BackendProvider

  /// Build the complete `InsightInput` for `context`, joining the
  /// store-derived `snapshot` with freshly-fetched data-source summaries and
  /// repository aggregates.
  ///
  /// The independent reads run concurrently via `async let` — each is a
  /// read-only fetch against a concurrency-safe GRDB read snapshot with no
  /// shared mutable state, so they can overlap and are awaited together.
  func build(
    snapshot: InsightInputSnapshot,
    context: InsightContext,
    window: InsightDataWindow = InsightDataWindow()
  ) async throws -> InsightInput {
    let source = backend.insightDataSource
    let categories = snapshot.categories

    async let summary = source.assemble(
      window: window, categories: categories, context: context)

    async let scheduledBillsResult = scheduledBills(context: context)
    async let budgetedCategoryIds = budgetedCategoryIds()
    async let uncategorizedTransactionCount = uncategorizedTransactionCount()
    async let pendingTransfers = backend.transferSuggestions.fetchAll()

    let pendingTransfersList = try await pendingTransfers
    let bills = try await scheduledBillsResult
    let insightSummary = try await summary
    return InsightInput(
      context: context,
      dataWindow: window,
      dataAvailability: insightSummary.availability,
      recentCandidates: insightSummary.recentCandidates,
      dailyTotals: insightSummary.dailyTotals,
      payees: insightSummary.payees,
      categorySamples: insightSummary.categorySamples,
      incomeSourceSamples: insightSummary.incomeSourceSamples,
      feeCategorySpend: insightSummary.categorySpend,
      unbudgetedCategorySpend: insightSummary.unbudgetedCategorySpend,
      accountSpend: insightSummary.accountSpend,
      monthly: snapshot.monthly,
      expenseBreakdown: snapshot.expenseBreakdown,
      dailyBalances: snapshot.dailyBalances,
      scheduledBills: bills.items,
      scheduledBillsHaveUnavailableData: bills.hasUnavailableData,
      unavailableScheduledBills: bills.unavailable,
      earmarks: snapshot.earmarks,
      profitLoss: snapshot.profitLoss,
      capitalGains: snapshot.capitalGains,
      categories: categories,
      accountGroups: snapshot.accountGroups,
      accountGroupMembership: snapshot.accountGroupMembership,
      budgetedCategoryIds: try await budgetedCategoryIds,
      uncategorizedTransactionCount: try await uncategorizedTransactionCount,
      pendingTransferCount: pendingTransfersList.count,
      oldestPendingTransferDate: pendingTransfersList.map(\.suggestedAt).min())
  }
}

extension InsightInputBuilder {
  /// Counts the actionable category backlog while excluding transactions
  /// made entirely of instruments the user has classified as spam.
  private func uncategorizedTransactionCount() async throws -> Int {
    let registrations = try await backend.instrumentRegistry?.allCryptoRegistrations() ?? []
    let spamInstrumentIds = Set(
      registrations.lazy
        .filter { $0.pricingStatus == .spam }
        .map(\.instrument.id))
    return try await backend.transactions.countNeedsReview(
      excludingInstrumentIds: spamInstrumentIds)
  }

  /// Future-dated scheduled transactions reduced to the reporting currency.
  ///
  /// Each scheduled transaction contributes its first income/expense leg,
  /// converted to `context.reportingCurrency`. A leg whose conversion fails is
  /// dropped, never guessed (`INSTRUMENT_CONVERSION_GUIDE.md` Rule 11); the
  /// original sign is preserved (a bill is a negative outflow — never
  /// `abs()`). Transactions with no income/expense leg are skipped.
  ///
  /// The conversions run in a single `convertResultBatch(...)` hop. Each
  /// candidate's contributing leg becomes one request (index-aligned to
  /// `candidates`); a `.failure`/`.knownZero` outcome drops the bill (Rule
  /// 11) — an unpriced or spam token has no meaningful reporting-currency
  /// value, so surfacing a "$0" future bill would mislead. Cancellation
  /// surfaces as a throw from `convertResultBatch` and propagates to the
  /// caller.
  private func scheduledBills(
    context: InsightContext
  ) async throws -> ScheduledBillProjection {
    let filter = TransactionFilter(scheduled: .scheduledOnly)
    let scheduled = try await backend.transactions.fetchAll(filter: filter)
    let reportingCurrency = context.reportingCurrency
    // Gate against the injected clock; price future obligations at the current
    // wall-clock rate (Rule 6).
    let now = context.now
    let conversionDate = Date()

    // Phase 1 — gather each future candidate's contributing leg and build one
    // request per candidate, index-aligned so each outcome maps back.
    let candidates =
      scheduled
      .filter { $0.date >= now }
      .compactMap { transaction -> (transaction: Transaction, leg: TransactionLeg)? in
        guard
          let leg = transaction.legs.first(where: { $0.type == .income || $0.type == .expense })
        else { return nil }
        return (transaction, leg)
      }
    let requests = candidates.map { candidate in
      BatchConversionRequest(
        amount: candidate.leg.amount, target: reportingCurrency, date: conversionDate)
    }

    // Phase 2 — one batched conversion. Cancellation throws here.
    let outcomes = try await backend.conversionService.convertResultBatch(requests)

    // Phase 3 — build a bill per candidate from its outcome, dropping the
    // ones whose conversion failed (Rule 11).
    var bills: [ScheduledBill] = []
    var unavailable: [UnavailableScheduledBill] = []
    bills.reserveCapacity(candidates.count)
    for (candidate, outcome) in zip(candidates, outcomes) {
      let amount: InstrumentAmount
      switch outcome {
      case .value(let converted):
        amount = converted
      case .knownZero:
        unavailable.append(
          unavailableBill(candidate, reason: "conversion resolved to a known zero"))
        continue
      case .failure(let error):
        unavailable.append(
          unavailableBill(
            candidate,
            reason: "conversion failed: \(error)"
          )
        )
        continue
      }
      bills.append(
        ScheduledBill(
          id: candidate.transaction.id,
          date: candidate.transaction.date,
          payee: candidate.transaction.payee,
          amount: amount,
          accountId: candidate.leg.accountId))
    }
    return ScheduledBillProjection(items: bills, unavailable: unavailable)
  }

  private func unavailableBill(
    _ candidate: (transaction: Transaction, leg: TransactionLeg),
    reason: String
  ) -> UnavailableScheduledBill {
    logger.error(
      "Dropping scheduled bill \(candidate.transaction.id, privacy: .public): \(reason)"
    )
    return UnavailableScheduledBill(
      date: candidate.transaction.date,
      isOutflow: candidate.leg.amount.quantity < 0)
  }

  /// The set of category ids that carry a budget line item in some earmark.
  private func budgetedCategoryIds() async throws -> Set<UUID> {
    let earmarks = try await backend.earmarks.fetchAll()
    let perEarmark = try await withThrowingTaskGroup(of: [EarmarkBudgetItem].self) { group in
      for earmark in earmarks {
        group.addTask { try await self.backend.earmarks.fetchBudget(earmarkId: earmark.id) }
      }
      var collected: [[EarmarkBudgetItem]] = []
      for try await items in group { collected.append(items) }
      return collected
    }
    return Set(perEarmark.flatMap { $0.map(\.categoryId) })
  }
}
