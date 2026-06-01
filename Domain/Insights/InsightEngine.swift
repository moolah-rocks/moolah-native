import Foundation

/// Runs every deterministic detector over an `InsightInput`, collects the
/// candidates, and ranks them. The single entry point the wiring layer (and
/// a future "For You" store) calls each surface refresh.
///
/// Pure and synchronous — all async currency conversion happens upstream
/// when `InsightInput` is assembled (see `InsightTransaction` /
/// `EarmarkSnapshot`). Detection over a few thousand transactions is
/// microseconds-to-milliseconds; callers still run it off-main and publish
/// to a `@MainActor` store per `guides/CONCURRENCY_GUIDE.md`.
struct InsightEngine: Sendable {
  var ranker: InsightRanker

  init(ranker: InsightRanker = InsightRanker()) {
    self.ranker = ranker
  }

  /// All detected candidates, unranked. Useful for category-scoped surfaces
  /// that filter by `InsightKind.category` themselves, and for tests.
  func detectAll(_ input: InsightInput) -> [Insight] {
    let context = input.context
    let calendar = context.calendar
    let expenseSubscriptions = SubscriptionDetector.detect(
      in: input.transactions, incomeStreams: false, calendar: calendar)
    let incomeStreams = SubscriptionDetector.detect(
      in: input.transactions, incomeStreams: true, calendar: calendar)

    var insights: [Insight] = []
    insights += subscriptionInsights(input, subscriptions: expenseSubscriptions)
    insights += anomalyInsights(input)
    insights += trendInsights(input)
    insights += cashFlowInsights(input)
    insights += budgetInsights(input)
    insights += investmentInsights(input)
    insights += incomeInsights(input, incomeStreams: incomeStreams)
    insights += habitInsights(input)
    insights += structuralInsights(input)
    return insights
  }

  /// Detect, score, and cap the insights for a surface.
  func generate(
    _ input: InsightInput,
    dismissals: [InsightKind: Int] = [:],
    interests: InsightRanker.DeclaredInterests = InsightRanker.DeclaredInterests(),
    displayCap: Int = 5,
    guaranteePositive: Bool = true
  ) -> [ScoredInsight] {
    ranker.rank(
      detectAll(input),
      now: input.context.now,
      dismissals: dismissals,
      interests: interests,
      displayCap: displayCap,
      guaranteePositive: guaranteePositive)
  }

  // MARK: - Detector groups

  private func subscriptionInsights(
    _ input: InsightInput, subscriptions: [DetectedSubscription]
  ) -> [Insight] {
    let context = input.context
    let income = InsightAggregates.averageMonthlyIncome(input.monthly, context: context)
    var insights: [Insight] = []
    insights += SubscriptionInsights.newRecurring(subscriptions, context: context)
    insights += SubscriptionInsights.priceHikes(subscriptions, context: context)
    insights += SubscriptionInsights.duplicates(
      subscriptions, categories: input.categories, context: context)
    insights += SubscriptionInsights.cancellationCandidates(subscriptions, context: context)
    insights += SavingsOpportunityInsights.subscriptionOverspend(
      subscriptions: subscriptions, averageMonthlyIncome: income, context: context)
    return insights
  }

  private func anomalyInsights(_ input: InsightInput) -> [Insight] {
    let context = input.context
    var insights: [Insight] = []
    insights += LargeTransactionInsight.detect(
      transactions: input.transactions, categories: input.categories, context: context)
    insights += NewMerchantInsight.detect(transactions: input.transactions, context: context)
    insights += UnusualDayInsight.detect(transactions: input.transactions, context: context)
    insights += CategoryAnomalyInsight.detect(
      breakdown: input.expenseBreakdown, categories: input.categories, context: context)
    insights += SavingsOpportunityInsights.feeSpend(
      transactions: input.transactions, context: context)
    return insights
  }

  private func trendInsights(_ input: InsightInput) -> [Insight] {
    let context = input.context
    var insights: [Insight] = []
    insights += CategoryTrendInsight.detect(
      breakdown: input.expenseBreakdown, categories: input.categories, context: context)
    insights += PeriodComparisonInsights.detect(monthly: input.monthly, context: context)
    insights += CategoryMixShiftInsight.detect(
      breakdown: input.expenseBreakdown, categories: input.categories, context: context)
    return insights
  }

  private func cashFlowInsights(_ input: InsightInput) -> [Insight] {
    let context = input.context
    var insights: [Insight] = []
    insights += CashFlowForecastInsights.upcomingBillWarning(
      dailyBalances: input.dailyBalances, scheduledBills: input.scheduledBills, context: context)
    insights += CashFlowForecastInsights.projectedMonthEnd(
      dailyBalances: input.dailyBalances, context: context)
    insights += LiquidityInsights.runway(
      dailyBalances: input.dailyBalances, monthly: input.monthly, context: context)
    insights += LiquidityInsights.idleCash(
      dailyBalances: input.dailyBalances, monthly: input.monthly, context: context)
    insights += SavingsRateInsight.detect(monthly: input.monthly, context: context)
    return insights
  }

  private func budgetInsights(_ input: InsightInput) -> [Insight] {
    let context = input.context
    var insights: [Insight] = []
    insights += EarmarkBudgetInsights.detect(earmarks: input.earmarks, context: context)
    insights += SavingsGoalInsight.detect(earmarks: input.earmarks, context: context)
    return insights
  }

  private func investmentInsights(_ input: InsightInput) -> [Insight] {
    var insights: [Insight] = []
    insights += NetWorthInsights.detect(dailyBalances: input.dailyBalances, context: input.context)
    insights += InvestmentInsights.detect(
      profitLoss: input.profitLoss, capitalGains: input.capitalGains, context: input.context)
    return insights
  }

  private func incomeInsights(
    _ input: InsightInput, incomeStreams: [DetectedSubscription]
  ) -> [Insight] {
    let context = input.context
    var insights: [Insight] = []
    insights += IncomeInsights.detect(incomeStreams: incomeStreams, context: context)
    insights += IncomeExtraInsights.windfall(transactions: input.transactions, context: context)
    insights += IncomeExtraInsights.payRateChange(incomeStreams: incomeStreams, context: context)
    return insights
  }

  private func habitInsights(_ input: InsightInput) -> [Insight] {
    let context = input.context
    var insights: [Insight] = []
    insights += SpendHabitInsights.lapsedMerchant(
      transactions: input.transactions, context: context)
    insights += SpendHabitInsights.weekendSkew(transactions: input.transactions, context: context)
    return insights
  }

  /// Account-structure and data-quality insights (post-design-doc features).
  private func structuralInsights(_ input: InsightInput) -> [Insight] {
    var insights: [Insight] = []
    insights += AccountGroupInsights.groupSpendConcentration(input)
    insights += BudgetCoverageInsights.unbudgetedCategory(input)
    insights += DataQualityInsights.uncategorizedBacklog(input)
    insights += DataQualityInsights.unreconciledTransfers(input)
    return insights
  }
}
