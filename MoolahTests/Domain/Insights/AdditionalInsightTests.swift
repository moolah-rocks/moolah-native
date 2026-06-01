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
    var transactions: [InsightTransaction] = []
    for index in 0..<8 {
      transactions.append(
        InsightTestSupport.expense(100, payee: "Shop", daysAgo: index + 1, accountId: accountA))
    }
    transactions.append(
      InsightTestSupport.expense(50, payee: "Utility", daysAgo: 2, accountId: accountB))
    let input = InsightInput(
      context: context,
      transactions: transactions,
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
    let payAmounts: [Decimal] = [3000, 3050, 2980, 3020, 3000, 2990, 3010, 3030]
    var transactions: [InsightTransaction] = []
    for (index, amount) in payAmounts.enumerated() {
      transactions.append(
        InsightTestSupport.income(amount, payee: "Payroll", daysAgo: index * 14 + 40))
    }
    transactions.append(InsightTestSupport.income(12000, payee: "Bonus", daysAgo: 3))
    let insight = try #require(
      IncomeExtraInsights.windfall(transactions: transactions, context: context).first)
    #expect(insight.kind == .windfallIncome)
    #expect(insight.framing == .positive)
  }

  @Test
  func payRiseDetected() throws {
    let transactions = [
      InsightTestSupport.income(3000, payee: "ACME", daysAgo: 42),
      InsightTestSupport.income(3000, payee: "ACME", daysAgo: 28),
      InsightTestSupport.income(3000, payee: "ACME", daysAgo: 14),
      InsightTestSupport.income(3300, payee: "ACME", daysAgo: 0),
    ]
    let streams = SubscriptionDetector.detect(
      in: transactions, incomeStreams: true, calendar: calendar)
    let insight = try #require(
      IncomeExtraInsights.payRateChange(incomeStreams: streams, context: context).first)
    #expect(insight.kind == .payRateChange)
    #expect(insight.framing == .positive)
  }

  // MARK: - Spend habits

  @Test
  func lapsedMerchantSurfacesStoppedRegular() throws {
    var transactions: [InsightTransaction] = []
    // Five monthly charges, the most recent 130 days ago (lapsed).
    for index in 0..<5 {
      transactions.append(
        InsightTestSupport.expense(40, payee: "OldGym", daysAgo: 130 + index * 30))
    }
    let insight = try #require(
      SpendHabitInsights.lapsedMerchant(transactions: transactions, context: context).first)
    #expect(insight.kind == .lapsedMerchant)
  }

  @Test
  func weekendSkewDetected() throws {
    var transactions: [InsightTransaction] = []
    for daysAgo in 1...42 {
      let date = InsightTestSupport.daysAgo(daysAgo)
      let weekday = calendar.component(.weekday, from: date)
      let magnitude: Decimal = (weekday == 1 || weekday == 7) ? 120 : 20
      transactions.append(
        InsightTestSupport.expense(magnitude, payee: "Spend", daysAgo: daysAgo))
    }
    let insight = try #require(
      SpendHabitInsights.weekendSkew(transactions: transactions, context: context).first)
    #expect(insight.kind == .weekendSpendSkew)
  }

  // MARK: - Budget coverage

  @Test
  func unbudgetedCategorySpotlight() throws {
    let budgeted = UUID()
    let unbudgeted = UUID()
    var transactions: [InsightTransaction] = []
    transactions.append(
      InsightTestSupport.expense(50, payee: "A", daysAgo: 5, categoryId: budgeted))
    for index in 0..<5 {
      transactions.append(
        InsightTestSupport.expense(200, payee: "B", daysAgo: index + 1, categoryId: unbudgeted))
    }
    let input = InsightInput(
      context: context, transactions: transactions, budgetedCategoryIds: [budgeted])
    let insight = try #require(BudgetCoverageInsights.unbudgetedCategory(input).first)
    #expect(insight.kind == .unbudgetedCategory)
    #expect(insight.references.categoryIds == [unbudgeted])
  }

  @Test
  func unbudgetedCategoryQuietWithoutBudgets() {
    let category = UUID()
    let transactions = [
      InsightTestSupport.expense(200, payee: "B", daysAgo: 1, categoryId: category)
    ]
    let input = InsightInput(context: context, transactions: transactions)
    #expect(BudgetCoverageInsights.unbudgetedCategory(input).isEmpty)
  }
}
