import Foundation
import Testing

@testable import Moolah

@Suite("Additional insights (follow-up ideas)")
struct AdditionalInsightTests {
  private let context = InsightTestSupport.context()
  private let calendar = InsightTestSupport.calendar

  // MARK: - Data quality

  @Test
  func uncategorizedBacklogNudge() throws {
    let input = InsightInput(context: context, uncategorizedTransactionCount: 30)
    let insights = DataQualityInsights.uncategorizedBacklog(input)
    let nudge = try #require(insights.first)
    #expect(nudge.kind == .uncategorizedBacklog)
    #expect(nudge.title == "30 transactions need a category")
  }

  @Test
  func uncategorizedBacklogSingularReadsGrammatically() throws {
    let input = InsightInput(context: context, uncategorizedTransactionCount: 1)
    let nudge = try #require(
      DataQualityInsights.uncategorizedBacklog(input, minimumCount: 1).first)
    #expect(nudge.title == "1 transaction needs a category")
  }

  @Test
  func uncategorizedBacklogQuietBelowThreshold() {
    let input = InsightInput(context: context, uncategorizedTransactionCount: 3)
    #expect(DataQualityInsights.uncategorizedBacklog(input).isEmpty)
  }

  @Test
  func unreconciledTransfersBacklog() throws {
    let input = InsightInput(
      context: context, pendingTransferCount: 5,
      oldestPendingTransferDate: InsightTestSupport.daysAgo(20))
    let insight = try #require(DataQualityInsights.unreconciledTransfers(input).first)
    #expect(insight.kind == .unreconciledTransfers)
    #expect(insight.actionability == .act)
    #expect(insight.title == "5 transfers to review and merge")
  }

  @Test
  func unreconciledTransfersSingularReadsGrammatically() throws {
    let input = InsightInput(
      context: context, pendingTransferCount: 1,
      oldestPendingTransferDate: InsightTestSupport.daysAgo(20))
    let insight = try #require(
      DataQualityInsights.unreconciledTransfers(input, minimumCount: 1).first)
    #expect(insight.title == "1 transfer to review and merge")
  }

  // MARK: - Account groups

  @Test
  func groupSpendConcentration() throws {
    let accountA = UUID()
    let accountB = UUID()
    let groupA = InsightAccountGroup(id: UUID(), name: "Daily Spending")
    let groupB = InsightAccountGroup(id: UUID(), name: "Bills")
    var legs: [InsightTransaction] = []
    for index in 0..<8 {
      legs.append(
        InsightTestSupport.expense(100, payee: "Shop", daysAgo: index + 1, accountId: accountA))
    }
    legs.append(
      InsightTestSupport.expense(50, payee: "Utility", daysAgo: 2, accountId: accountB))
    let input = InsightInput(
      context: context,
      accountSpend: InsightTestSupport.accountSpend(from: legs),
      accountGroups: [groupA, groupB],
      accountGroupMembership: [accountA: groupA.id, accountB: groupB.id])
    let insight = try #require(AccountGroupInsights.groupSpendConcentration(input).first)
    #expect(insight.kind == .groupSpendConcentration)
    #expect(insight.references.groupIds == [groupA.id])
  }

  // MARK: - Income extensions

  @Test
  func windfallFlagsSpikeAgainstItsOwnSourceHistory() throws {
    // A source that usually pays ~$500 suddenly pays $12,000. The candidate is
    // part of its own source's sample set (as it is in production).
    let samples = [
      IncomeSourceSamples(
        normalizedPayee: "client", magnitudes: [12000, 500, 480, 520, 510, 490, 505])
    ]
    let spike = InsightTestSupport.income(12000, payee: "Client", daysAgo: 3)
    let insight = try #require(
      IncomeExtraInsights.windfall(
        recentCandidates: [spike], incomeSourceSamples: samples, context: context
      ).first)
    #expect(insight.kind == .windfallIncome)
    #expect(insight.framing == .positive)
    // "Typical" is this source's own median (~$500), never a global pool.
    let typical = try #require(insight.facts.first { $0.label == "Typical income" }?.value)
    #expect(typical.contains("505"))
  }

  @Test
  func windfallIgnoresRegularSalaryEvenWhenItDwarfsOtherIncome() throws {
    // Regression for the reported bug: a regular ~$35k salary was flagged
    // "well above your typical $1,111" because it was scored against the median
    // of ALL income (salary + many small deposits) pooled together. Scoring the
    // deposit against its OWN source's history — where a paycheck with normal
    // month-to-month variation is unremarkable — must not flag it, even though
    // it dwarfs the small deposits from every other source.
    let samples = [
      IncomeSourceSamples(
        normalizedPayee: "op labs",
        magnitudes: [35275, 34000, 36000, 33500, 35500, 34800, 35200]),
      // The small, frequent income that used to drag the global median down.
      IncomeSourceSamples(normalizedPayee: "interest", magnitudes: [50, 45, 55, 48, 52, 49]),
    ]
    let paycheck = InsightTestSupport.income(35275, payee: "OP Labs", daysAgo: 2)
    #expect(
      IncomeExtraInsights.windfall(
        recentCandidates: [paycheck], incomeSourceSamples: samples, context: context
      ).isEmpty)
  }

  @Test
  func windfallIgnoresLargeDepositFromSourceWithoutEnoughHistory() throws {
    // A brand-new source has no baseline to call a deposit unusual *for that
    // source* — skipped, mirroring the large-transaction detector's
    // sparse-category rule. A first-ever windfall is the accepted trade-off.
    let samples = [
      IncomeSourceSamples(
        normalizedPayee: "employer", magnitudes: [3000, 3050, 2980, 3020, 3000, 2990])
    ]
    let oneOff = InsightTestSupport.income(50000, payee: "Lottery", daysAgo: 1)
    #expect(
      IncomeExtraInsights.windfall(
        recentCandidates: [oneOff], incomeSourceSamples: samples, context: context
      ).isEmpty)
  }

  @Test
  func payRiseDetected() throws {
    let legs = [
      InsightTestSupport.income(3000, payee: "ACME", daysAgo: 42),
      InsightTestSupport.income(3000, payee: "ACME", daysAgo: 28),
      InsightTestSupport.income(3000, payee: "ACME", daysAgo: 14),
      InsightTestSupport.income(3300, payee: "ACME", daysAgo: 0),
    ]
    let streams = SubscriptionDetector.detect(
      payees: InsightTestSupport.payees(from: legs), incomeStreams: true, calendar: calendar)
    let insight = try #require(
      IncomeExtraInsights.payRateChange(incomeStreams: streams, context: context).first)
    #expect(insight.kind == .payRateChange)
    #expect(insight.framing == .positive)
    let chart = try #require(insight.chart)
    #expect(chart.kind == .line)
    #expect(chart.unit == .currency(InsightTestSupport.currency))
    #expect(chart.series.first?.points.count == 4)
    // The latest (raised) paycheck is highlighted at its positive amount.
    #expect(chart.highlight?.value == 3300)
  }

  // MARK: - Spend habits

  @Test
  func lapsedMerchantSurfacesStoppedRegular() throws {
    var legs: [InsightTransaction] = []
    // Five monthly charges, the most recent 130 days ago (lapsed).
    for index in 0..<5 {
      legs.append(
        InsightTestSupport.expense(40, payee: "OldGym", daysAgo: 130 + index * 30))
    }
    let insight = try #require(
      SpendHabitInsights.lapsedMerchant(
        payees: InsightTestSupport.payees(from: legs), context: context
      ).first)
    #expect(insight.kind == .lapsedMerchant)
  }

  @Test
  func weekendSkewDetected() throws {
    var legs: [InsightTransaction] = []
    for daysAgo in 1...42 {
      let date = InsightTestSupport.daysAgo(daysAgo)
      let weekday = calendar.component(.weekday, from: date)
      let magnitude: Decimal = (weekday == 1 || weekday == 7) ? 120 : 20
      legs.append(
        InsightTestSupport.expense(magnitude, payee: "Spend", daysAgo: daysAgo))
    }
    let insight = try #require(
      SpendHabitInsights.weekendSkew(
        dailyTotals: InsightTestSupport.dailyTotals(from: legs), context: context
      ).first)
    #expect(insight.kind == .weekendSpendSkew)
  }

  // MARK: - Budget coverage

  @Test
  func unbudgetedCategorySpotlight() throws {
    let budgeted = UUID()
    let unbudgeted = UUID()
    var legs: [InsightTransaction] = []
    legs.append(
      InsightTestSupport.expense(50, payee: "A", daysAgo: 5, categoryId: budgeted))
    for index in 0..<5 {
      legs.append(
        InsightTestSupport.expense(200, payee: "B", daysAgo: index + 1, categoryId: unbudgeted))
    }
    let input = InsightInput(
      context: context,
      unbudgetedCategorySpend: InsightTestSupport.categorySpend(from: legs),
      budgetedCategoryIds: [budgeted])
    let insight = try #require(BudgetCoverageInsights.unbudgetedCategory(input).first)
    #expect(insight.kind == .unbudgetedCategory)
    #expect(insight.references.categoryIds == [unbudgeted])
  }

  @Test
  func unbudgetedCategoryQuietWithoutBudgets() {
    let category = UUID()
    let legs = [
      InsightTestSupport.expense(200, payee: "B", daysAgo: 1, categoryId: category)
    ]
    let input = InsightInput(
      context: context,
      unbudgetedCategorySpend: InsightTestSupport.categorySpend(from: legs))
    #expect(BudgetCoverageInsights.unbudgetedCategory(input).isEmpty)
  }
}
