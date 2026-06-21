import Foundation
import Testing

@testable import Moolah

/// Contract tests for the **available-funds base** of
/// `fetchIncomeAndExpense` — the `income` / `expense` figures shown with
/// the "Include Investments" toggle off. Earmark reserve movements are
/// *always* folded in (there is no earmark toggle).
///
/// Per leg the base is `(current-account amount) − (earmark amount)`:
/// - a leg on a current account counts in full;
/// - any earmark leg subtracts its amount, so a leg that is *both* on a
///   current account and earmarked nets to zero (cash arrived but is
///   reserved), and an account-less earmark leg flips sign (setting money
///   aside reads as a reduction, releasing it as a gain).
///
/// `income`/`trade` legs land in the Income column, `expense`/`transfer`
/// in the Expense column; `openingBalance` is excluded.
@Suite("AnalysisRepository Contract Tests — Available-Funds Base")
struct AnalysisIncomeExpenseServerParityTests {

  @Test("earmarked legs on a current account net to zero within the base")
  func earmarkedWithAccountIdNetsToZero() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(id: UUID(), name: "Holiday", instrument: .defaultTestInstrument)
    _ = try await backend.earmarks.create(earmark)

    try await record(backend, account.id, 100, .income)
    // Income on a current account, also earmarked: the +30 current and the
    // −30 earmark cancel, so it doesn't change available funds.
    try await record(backend, account.id, 30, .income, earmarkId: earmark.id)
    try await record(backend, account.id, -50, .expense)
    // Expense on a current account, also earmarked: −20 current, +20
    // earmark → nets to zero.
    try await record(backend, account.id, -20, .expense, earmarkId: earmark.id)

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]

    // Only the non-earmarked salary (100) and groceries (-50) move available funds.
    #expect(month.income.quantity == 100)
    #expect(month.expense.quantity == -50)
    #expect(month.profit.quantity == 50)

    // No investment activity, so the investment layer is empty and the
    // toggle-on totals match the base.
    #expect(month.investmentIncome.quantity == 0)
    #expect(month.investmentExpense.quantity == 0)
    #expect(month.investmentProfit.quantity == 0)
    #expect(month.totalIncome.quantity == 100)
    #expect(month.totalExpense.quantity == -50)
    #expect(month.totalProfit.quantity == 50)
  }

  @Test("account-less earmark expense frees money: excluded from spending, negated into the base")
  func accountLessEarmarkExpenseNegated() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(id: UUID(), name: "Gift Fund", instrument: .defaultTestInstrument)
    _ = try await backend.earmarks.create(earmark)

    try await record(backend, account.id, -80, .expense)
    // Account-less earmark expense -25 reduces the earmark reserve, which
    // frees money — it raises available funds by 25 (−(−25)).
    try await record(backend, nil, -25, .expense, earmarkId: earmark.id)

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]

    #expect(month.expense.quantity == -55)  // -80 + 25
    #expect(month.investmentExpense.quantity == 0)
    #expect(month.totalExpense.quantity == -55)
  }

  @Test("openingBalance excluded from income/expense reports")
  func openingBalanceExcluded() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    try await record(backend, account.id, 500, .openingBalance)
    try await record(backend, account.id, 100, .income)

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]

    // openingBalance is excluded; only the income leg counts.
    #expect(month.income.quantity == 100)
    #expect(month.expense.quantity == 0)
    #expect(month.investmentIncome.quantity == 0)
  }

  @Test("mixed earmark legs: available funds nets every earmark reserve movement")
  func mixedEarmarkedAccountIdSemantics() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(id: UUID(), name: "Savings", instrument: .defaultTestInstrument)
    _ = try await backend.earmarks.create(earmark)

    try await seedMixedEarmarkedLegs(backend: backend, account: account, earmark: earmark)

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]

    // Income: 200 current − (200 + 50) earmark = −50 (more set aside than
    // landed in cash). Expense: −80 current − (−80 + −30) earmark = +30
    // (reserve drawdowns freed more than was spent from cash).
    #expect(month.income.quantity == -50)
    #expect(month.expense.quantity == 30)
    #expect(month.profit.quantity == -20)

    #expect(month.investmentIncome.quantity == 0)
    #expect(month.investmentExpense.quantity == 0)
    #expect(month.totalProfit.quantity == -20)
  }

  // MARK: - Helpers

  /// Create a single-leg transaction dated today, in `defaultTestInstrument`.
  /// Keeps the test bodies focused on the amounts and account/earmark
  /// placement that drive the split.
  private func record(
    _ backend: CloudKitAnalysisTestBackend,
    _ accountId: UUID?,
    _ quantity: Decimal,
    _ type: TransactionType,
    earmarkId: UUID? = nil
  ) async throws {
    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: nil,
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .defaultTestInstrument,
            quantity: quantity, type: type, earmarkId: earmarkId)
        ]))
  }

  private func seedMixedEarmarkedLegs(
    backend: CloudKitAnalysisTestBackend,
    account: Account,
    earmark: Earmark
  ) async throws {
    try await record(backend, account.id, 200, .income, earmarkId: earmark.id)
    try await record(backend, nil, 50, .income, earmarkId: earmark.id)
    try await record(backend, account.id, -80, .expense, earmarkId: earmark.id)
    try await record(backend, nil, -30, .expense, earmarkId: earmark.id)
  }
}
