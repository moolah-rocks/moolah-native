import Foundation
import Testing

@testable import Moolah

/// Contract tests pinning that `.income` and `.expense` legs recorded on
/// **investment-like** accounts (investment brokerages, crypto wallets,
/// and centralised exchanges — every `AccountType.isInvestmentLike`
/// case) are routed to the *investment layer* rather than the
/// available-funds base `income` / `expense` figures.
///
/// The base figures answer "is my spendable money growing?", so
/// investment activity (dividends, brokerage fees, staking rewards) is
/// gated behind the "Include Investments" toggle. A backend that counted
/// investment-account income/expense in the base would conflate
/// portfolio activity with available-funds cashflow.
@Suite("AnalysisRepository Contract Tests — Income/Expense on Investment Accounts")
struct AnalysisIncomeExpenseInvestmentTests {
  @Test("income legs on investment accounts go to the investment layer, not the base")
  func incomeOnInvestmentAccountRoutedToInvestmentLayer() async throws {
    try await assertInvestmentIncomeRoutedToLayer(accountType: .investment, quantity: 50)
  }

  @Test("income legs on crypto accounts go to the investment layer, not the base")
  func incomeOnCryptoAccountRoutedToInvestmentLayer() async throws {
    try await assertInvestmentIncomeRoutedToLayer(accountType: .crypto, quantity: 40)
  }

  @Test("income legs on exchange accounts go to the investment layer, not the base")
  func incomeOnExchangeAccountRoutedToInvestmentLayer() async throws {
    try await assertInvestmentIncomeRoutedToLayer(accountType: .exchange, quantity: 30)
  }

  @Test("expense legs on investment accounts go to the investment layer, not the base")
  func expenseOnInvestmentAccountRoutedToInvestmentLayer() async throws {
    try await assertInvestmentExpenseRoutedToLayer(accountType: .investment, quantity: -25)
  }

  @Test("expense legs on crypto accounts go to the investment layer, not the base")
  func expenseOnCryptoAccountRoutedToInvestmentLayer() async throws {
    try await assertInvestmentExpenseRoutedToLayer(accountType: .crypto, quantity: -15)
  }

  @Test("expense legs on exchange accounts go to the investment layer, not the base")
  func expenseOnExchangeAccountRoutedToInvestmentLayer() async throws {
    try await assertInvestmentExpenseRoutedToLayer(accountType: .exchange, quantity: -10)
  }

  @Test("contributions into crypto accounts net to zero across base and investment layer")
  func transferIntoCryptoNetsToZero() async throws {
    try await assertContributionNetsToZero(accountType: .crypto)
  }

  @Test("contributions into exchange accounts net to zero across base and investment layer")
  func transferIntoExchangeNetsToZero() async throws {
    try await assertContributionNetsToZero(accountType: .exchange)
  }

  // MARK: - Helpers

  /// Bank -> investment-like transfer. Transfers go to the expense column,
  /// so the bank-side leg (-5) reduces the available-funds base expense
  /// and the investment-side leg (+5) lands in the investment layer. With
  /// investments included they net to zero (you moved money you still
  /// own); exercises crypto and exchange — not just `.investment`.
  private func assertContributionNetsToZero(
    accountType: AccountType
  ) async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let bank = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(
      bank,
      openingBalance: InstrumentAmount(quantity: 10, instrument: .defaultTestInstrument))
    let investment = Account(
      id: UUID(), name: "Portfolio", type: accountType, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(investment)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Contribution",
        legs: [
          TransactionLeg(
            accountId: bank.id, instrument: .defaultTestInstrument,
            quantity: -5, type: .transfer),
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: 5, type: .transfer),
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    let month = try #require(data.first)
    // Base (investments excluded): money left available funds.
    #expect(month.expense.quantity == -5)
    #expect(month.income.quantity == 0)
    // Investment layer holds the destination side.
    #expect(
      month.investmentExpense.quantity == 5,
      "Transfer into a \(accountType.rawValue) account must land in the investment layer")
    // Whole picture: moving money you still own nets to zero.
    #expect(month.totalExpense.quantity == 0)
  }

  private func assertInvestmentIncomeRoutedToLayer(
    accountType: AccountType,
    quantity: Decimal
  ) async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Brokerage", type: accountType, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Dividend",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: quantity, type: .income)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    let month = try #require(data.first)
    #expect(
      month.income.quantity == 0,
      "Investment-account income must be excluded from the headline income total")
    #expect(
      month.investmentIncome.quantity == quantity,
      "Investment-account income must go to the investment layer, not the base")
  }

  private func assertInvestmentExpenseRoutedToLayer(
    accountType: AccountType,
    quantity: Decimal
  ) async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Brokerage", type: accountType, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Brokerage Fee",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: quantity, type: .expense)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    let month = try #require(data.first)
    #expect(
      month.expense.quantity == 0,
      "Investment-account expense must be excluded from the headline expense total")
    #expect(
      month.investmentExpense.quantity == quantity,
      "Investment-account expense must go to the investment layer, not the base")
  }
}
