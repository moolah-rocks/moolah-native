import Foundation
import GRDB
import Testing

@testable import Moolah

// MARK: - Shared Test Account IDs
//
// Stable UUIDs shared between fixture builders and test assertions. The
// originals lived as `private let` constants at file scope in
// `TransactionRepositoryContractTests.swift`; widened to `internal` here so
// the split test files can reuse them.

enum TransactionContractTestFixtures {
  static let paginationAccountId = UUID()
  static let transferSourceAccountId = UUID()
  static let transferDestAccountId = UUID()
}

// MARK: - Leg Builder

func makeContractTestLeg(
  accountId: UUID?,
  quantity: Decimal,
  type: TransactionType,
  categoryId: UUID? = nil,
  earmarkId: UUID? = nil
) -> TransactionLeg {
  TransactionLeg(
    accountId: accountId,
    instrument: .defaultTestInstrument,
    quantity: quantity,
    type: type,
    categoryId: categoryId,
    earmarkId: earmarkId
  )
}

// MARK: - Helpers

private func contractTestDate(year: Int, month: Int, day: Int) throws -> Date {
  try #require(Calendar.current.date(from: DateComponents(year: year, month: month, day: day)))
}

private func contractTestDecimal(_ literal: String) throws -> Decimal {
  try #require(Decimal(string: literal))
}

// MARK: - Mixed Fixtures

/// Mixed fixtures used by filter / sort / earmark / general tests.
/// Contains: two grocery expenses, one transport expense, one income, one
/// earmarked expense — all on the same synthetic account.
func makeContractTestTransactions() throws -> [Transaction] {
  let accountId = UUID()
  let groceryCategoryId = UUID()
  let transportCategoryId = UUID()
  let earmarkId = UUID()
  return [
    try makeMixedExpenseTxn(
      date: contractTestDate(year: 2024, month: 6, day: 15),
      payee: "Woolworths", accountId: accountId,
      quantityLiteral: "-50.23", categoryId: groceryCategoryId),
    try makeMixedExpenseTxn(
      date: contractTestDate(year: 2024, month: 7, day: 10),
      payee: "Metro Transport", accountId: accountId,
      quantityLiteral: "-35.00", categoryId: transportCategoryId),
    try makeMixedIncomeTxn(
      date: contractTestDate(year: 2024, month: 5, day: 30),
      payee: "Employer Pty Ltd", accountId: accountId,
      quantityLiteral: "3500.00"),
    try makeMixedExpenseTxn(
      date: contractTestDate(year: 2024, month: 4, day: 20),
      payee: "Coles", accountId: accountId,
      quantityLiteral: "-42.00", categoryId: groceryCategoryId),
    try makeMixedExpenseTxn(
      date: contractTestDate(year: 2024, month: 6, day: 20),
      payee: "Electronics Store", accountId: accountId,
      quantityLiteral: "-100.00", categoryId: transportCategoryId, earmarkId: earmarkId),
  ]
}

private func makeMixedExpenseTxn(
  date: Date,
  payee: String,
  accountId: UUID,
  quantityLiteral: String,
  categoryId: UUID,
  earmarkId: UUID? = nil
) throws -> Transaction {
  Transaction(
    date: date, payee: payee,
    legs: [
      makeContractTestLeg(
        accountId: accountId, quantity: try contractTestDecimal(quantityLiteral),
        type: .expense, categoryId: categoryId, earmarkId: earmarkId)
    ]
  )
}

private func makeMixedIncomeTxn(
  date: Date, payee: String, accountId: UUID, quantityLiteral: String
) throws -> Transaction {
  Transaction(
    date: date, payee: payee,
    legs: [
      makeContractTestLeg(
        accountId: accountId, quantity: try contractTestDecimal(quantityLiteral),
        type: .income)
    ]
  )
}

// MARK: - Pagination Fixtures

/// Fixtures driving the priorBalance pagination tests. Four mixed-sign
/// transactions on `paginationAccountId`, one per month Jan–Apr 2024.
func makePaginationContractTestTransactions() throws -> [Transaction] {
  let accountId = TransactionContractTestFixtures.paginationAccountId
  return [
    try makeMixedIncomeTxn(
      date: contractTestDate(year: 2024, month: 1, day: 1),
      payee: "Jan Income", accountId: accountId, quantityLiteral: "10.00"),
    try makePaginationExpense(
      date: contractTestDate(year: 2024, month: 2, day: 1),
      payee: "Feb Expense", accountId: accountId, quantityLiteral: "-3.00"),
    try makeMixedIncomeTxn(
      date: contractTestDate(year: 2024, month: 3, day: 1),
      payee: "Mar Income", accountId: accountId, quantityLiteral: "20.00"),
    try makePaginationExpense(
      date: contractTestDate(year: 2024, month: 4, day: 1),
      payee: "Apr Expense", accountId: accountId, quantityLiteral: "-5.00"),
  ]
}

private func makePaginationExpense(
  date: Date, payee: String, accountId: UUID, quantityLiteral: String
) throws -> Transaction {
  Transaction(
    date: date, payee: payee,
    legs: [
      makeContractTestLeg(
        accountId: accountId, quantity: try contractTestDecimal(quantityLiteral),
        type: .expense)
    ]
  )
}

// MARK: - Scheduled Fixtures

/// Fixtures driving the scheduled-filter tests: two non-scheduled and one
/// scheduled (`recurPeriod: .month`) transaction.
func makeScheduledContractTestTransactions() throws -> [Transaction] {
  let accountId = UUID()
  let june15 = try contractTestDate(year: 2024, month: 6, day: 15)
  let june1 = try contractTestDate(year: 2024, month: 6, day: 1)
  let july1 = try contractTestDate(year: 2024, month: 7, day: 1)
  return [
    try makePaginationExpense(
      date: june15, payee: "Store", accountId: accountId, quantityLiteral: "-50.00"),
    try makeMixedIncomeTxn(
      date: june1, payee: "Salary", accountId: accountId, quantityLiteral: "1000.00"),
    try makeScheduledNetflix(date: july1, accountId: accountId),
  ]
}

private func makeScheduledNetflix(date: Date, accountId: UUID) throws -> Transaction {
  Transaction(
    date: date, payee: "Netflix", recurPeriod: .month, recurEvery: 1,
    legs: [
      makeContractTestLeg(
        accountId: accountId, quantity: try contractTestDecimal("-20.00"),
        type: .expense)
    ]
  )
}

// MARK: - Transfer Fixtures

/// Fixtures driving the accountId-filter test: a transfer between
/// `transferSourceAccountId` and `transferDestAccountId` plus an expense only
/// on the source account.
func makeTransferContractTestTransactions() throws -> [Transaction] {
  let sourceAccountId = TransactionContractTestFixtures.transferSourceAccountId
  let destAccountId = TransactionContractTestFixtures.transferDestAccountId
  let june15 = try contractTestDate(year: 2024, month: 6, day: 15)
  let june10 = try contractTestDate(year: 2024, month: 6, day: 10)
  let negHundred = try contractTestDecimal("-100.00")
  let hundred = try contractTestDecimal("100.00")
  return [
    Transaction(
      date: june15, payee: "Transfer",
      legs: [
        makeContractTestLeg(
          accountId: sourceAccountId, quantity: negHundred, type: .transfer),
        makeContractTestLeg(
          accountId: destAccountId, quantity: hundred, type: .transfer),
      ]
    ),
    try makePaginationExpense(
      date: june10, payee: "Coffee", accountId: sourceAccountId,
      quantityLiteral: "-50.00"),
  ]
}

// MARK: - Payee Suggestion Fixtures

/// Fixtures driving payee-suggestion tests. Frequency: Coles ×3, Woolworths ×1,
/// Coffee Shop ×1.
func makePayeeSuggestionContractTestTransactions() throws -> [Transaction] {
  let accountId = UUID()
  return [
    try makePaginationExpense(
      date: contractTestDate(year: 2024, month: 6, day: 1),
      payee: "Woolworths", accountId: accountId, quantityLiteral: "-10.00"),
    try makePaginationExpense(
      date: contractTestDate(year: 2024, month: 6, day: 2),
      payee: "Coles", accountId: accountId, quantityLiteral: "-20.00"),
    try makePaginationExpense(
      date: contractTestDate(year: 2024, month: 6, day: 3),
      payee: "Coles", accountId: accountId, quantityLiteral: "-30.00"),
    try makePaginationExpense(
      date: contractTestDate(year: 2024, month: 6, day: 4),
      payee: "Coles", accountId: accountId, quantityLiteral: "-15.00"),
    try makePaginationExpense(
      date: contractTestDate(year: 2024, month: 6, day: 5),
      payee: "Coffee Shop", accountId: accountId, quantityLiteral: "-5.00"),
  ]
}

// MARK: - Repository Factory

func makeContractCloudKitTransactionRepository(
  initialTransactions: [Transaction] = [],
  instrument: Instrument = .defaultTestInstrument,
  exchangeRates: [String: [String: Decimal]] = [:]
) throws -> any TransactionRepository {
  let pair = try TestBackend.create(instrument: instrument, exchangeRates: exchangeRates)
  if !initialTransactions.isEmpty {
    TestBackend.seed(transactions: initialTransactions, in: pair.database)
  }
  return pair.backend.transactions
}
