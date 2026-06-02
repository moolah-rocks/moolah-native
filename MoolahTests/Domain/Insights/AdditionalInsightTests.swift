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
    #expect(nudge.title.contains("30"))
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
  func windfallFlagsLargeDeposit() throws {
    // Slightly varying paychecks (realistic) so the MAD is non-zero.
    let incomeSamples: [Decimal] = [3000, 3050, 2980, 3020, 3000, 2990, 3010, 3030]
    let bonus = InsightTestSupport.income(12000, payee: "Bonus", daysAgo: 3)
    let insight = try #require(
      IncomeExtraInsights.windfall(
        recentCandidates: [bonus], incomeSamples: incomeSamples, context: context
      ).first)
    #expect(insight.kind == .windfallIncome)
    #expect(insight.framing == .positive)
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
