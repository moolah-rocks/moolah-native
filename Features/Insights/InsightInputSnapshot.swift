import Foundation

/// The main-actor-gathered half of `InsightInput`.
///
/// `InsightInput` is assembled from two sources: aggregates already computed
/// by `@MainActor` feature stores (`AnalysisStore`, `EarmarkStore`,
/// `ReportingStore`, `AccountGroupStore`, `CategoryStore`), and bounded
/// summaries produced off-main from the SQL-backed `InsightDataSource`. This
/// struct carries exactly the former — the store-derived fields the builder
/// passes through unchanged — as a `Sendable` value the caller gathers on the
/// main actor and hands to `InsightInputBuilder.build(snapshot:context:window:)`,
/// which joins it with the data-source half off the main actor.
struct InsightInputSnapshot: Sendable {
  let monthly: [MonthlyIncomeExpense]
  let expenseBreakdown: [ExpenseBreakdown]
  let dailyBalances: [DailyBalance]
  let earmarks: [EarmarkSnapshot]
  let profitLoss: [InstrumentProfitLoss]
  let capitalGains: [CapitalGainEvent]
  let categories: Categories
  let accountGroups: [InsightAccountGroup]
  let accountGroupMembership: [UUID: UUID]

  init(
    monthly: [MonthlyIncomeExpense] = [],
    expenseBreakdown: [ExpenseBreakdown] = [],
    dailyBalances: [DailyBalance] = [],
    earmarks: [EarmarkSnapshot] = [],
    profitLoss: [InstrumentProfitLoss] = [],
    capitalGains: [CapitalGainEvent] = [],
    categories: Categories = Categories(from: []),
    accountGroups: [InsightAccountGroup] = [],
    accountGroupMembership: [UUID: UUID] = [:]
  ) {
    self.monthly = monthly
    self.expenseBreakdown = expenseBreakdown
    self.dailyBalances = dailyBalances
    self.earmarks = earmarks
    self.profitLoss = profitLoss
    self.capitalGains = capitalGains
    self.categories = categories
    self.accountGroups = accountGroups
    self.accountGroupMembership = accountGroupMembership
  }
}
