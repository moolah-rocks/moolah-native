import Foundation
import os

private let logger = Logger(subsystem: "com.moolah.app", category: "InsightInputBuilder")

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

    async let recentCandidates = source.recentCandidates(
      windowDays: window.recentCandidateDays, categories: categories, context: context)
    async let dailyTotals = source.dailyTotals(context: context)
    async let payees = source.payeeSummaries(
      windowDays: window.payeeCadenceDays, context: context)
    async let categorySamples = source.categorySamples(
      windowDays: window.sampleDays,
      maxPerCategory: window.maxSamplesPerCategory,
      context: context)
    async let incomeSamples = source.incomeSamples(
      windowDays: window.sampleDays, maxCount: window.maxIncomeSamples, context: context)
    async let feeCategorySpend = source.categorySpend(
      windowDays: window.categorySpendDays, categories: categories, context: context)
    async let unbudgetedCategorySpend = source.categorySpend(
      windowDays: window.unbudgetedSpendDays, categories: categories, context: context)
    async let accountSpend = source.accountSpend(
      windowDays: window.accountSpendDays, context: context)

    async let scheduledBills = scheduledBills(context: context)
    async let budgetedCategoryIds = budgetedCategoryIds()
    async let uncategorizedTransactionCount = backend.transactions.countNeedsReview()
    async let pendingTransfers = backend.transferSuggestions.fetchAll()

    let pendingTransfersList = try await pendingTransfers
    return InsightInput(
      context: context,
      recentCandidates: try await recentCandidates,
      dailyTotals: try await dailyTotals,
      payees: try await payees,
      categorySamples: try await categorySamples,
      incomeSamples: try await incomeSamples,
      feeCategorySpend: try await feeCategorySpend,
      unbudgetedCategorySpend: try await unbudgetedCategorySpend,
      accountSpend: try await accountSpend,
      monthly: snapshot.monthly,
      expenseBreakdown: snapshot.expenseBreakdown,
      dailyBalances: snapshot.dailyBalances,
      scheduledBills: try await scheduledBills,
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

  /// Future-dated scheduled transactions reduced to the reporting currency.
  ///
  /// Each scheduled transaction contributes its first income/expense leg,
  /// converted to `context.reportingCurrency`. A leg whose conversion fails is
  /// dropped, never guessed (`INSTRUMENT_CONVERSION_GUIDE.md` Rule 11); the
  /// original sign is preserved (a bill is a negative outflow — never
  /// `abs()`). Transactions with no income/expense leg are skipped.
  private func scheduledBills(context: InsightContext) async throws -> [ScheduledBill] {
    let filter = TransactionFilter(scheduled: .scheduledOnly)
    let scheduled = try await backend.transactions.fetchAll(filter: filter)
    let reportingCurrency = context.reportingCurrency
    let now = context.now  // gate: is this bill in the future, relative to the injected now?
    let conversionDate = Date()  // convert a future obligation at the CURRENT wall-clock rate (Rule 6)

    var bills: [ScheduledBill] = []
    for transaction in scheduled {
      guard transaction.date >= now else { continue }
      guard let leg = transaction.legs.first(where: { $0.type == .income || $0.type == .expense })
      else { continue }
      let amount: InstrumentAmount
      do {
        amount = try await backend.conversionService.convertAmount(
          leg.amount, to: reportingCurrency, on: conversionDate)
      } catch {
        // Rule 11: a leg whose conversion fails is dropped, never guessed.
        logger.error(
          "Dropping scheduled bill \(transaction.id, privacy: .public): conversion failed: \(error)"
        )
        continue
      }
      bills.append(
        ScheduledBill(
          id: transaction.id,
          date: transaction.date,
          payee: transaction.payee,
          amount: amount,
          accountId: leg.accountId))
    }
    return bills
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
