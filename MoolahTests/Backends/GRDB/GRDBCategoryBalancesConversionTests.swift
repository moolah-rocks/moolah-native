import Foundation
import GRDB
import Testing

@testable import Moolah

/// Date-sensitive and semantic-parity tests for
/// `GRDBAnalysisRepository.fetchCategoryBalances`.
///
/// The SQL aggregation groups by `(DATE(t.date), category_id,
/// instrument_id)` so per-day grouping is rate-equivalent to the per-leg
/// conversion the SwiftData implementation performed. These tests pin
/// the per-day calendar boundary fed into the
/// `InstrumentConversionService`, mirroring
/// `GRDBExpenseBreakdownConversionTests`.
///
/// Investment-account inclusion, account-less leg inclusion, and the
/// `categoryIds` filter are also pinned here — semantic include rules
/// that the SQL aggregation must continue to honour.
@Suite("GRDBAnalysisRepository fetchCategoryBalances — date-sensitive conversion")
struct GRDBCategoryBalancesConversionTests {

  @Test("category balances convert each day's USD legs at that day's rate")
  func categoryBalancesConvertPerDayRate() async throws {
    // Two consecutive UTC days with different USD→AUD rates. The legs
    // are identical USD expenses; if SQL grouping collapses days into a
    // single bucket, both legs would convert at the same rate and the
    // total would diverge from the per-day truth.
    let dayOne = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayTwo = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 11, hour: 12)
    let rateOne = try AnalysisTestHelpers.decimal("1.5")
    let rateTwo = try AnalysisTestHelpers.decimal("2.0")

    // Seed at UTC midnight for each transaction's UTC calendar day so
    // `ratesAsOf`'s descending `<=` scan lands on the right rate per
    // parsed-day Date.
    let conversion = FakeConversionService.dateRates([
      try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 0): [
        "USD": rateOne
      ],
      try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 11, hour: 0): [
        "USD": rateTwo
      ],
    ])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let account = Account(
      id: UUID(), name: "USD Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    let usd = Instrument.fiat(code: "USD")

    _ = try await backend.transactions.create(
      Transaction(
        date: dayOne, payee: "US Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: -100, type: .expense, categoryId: category.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: dayTwo, payee: "US Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: -100, type: .expense, categoryId: category.id)
        ]))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: dayOne...dayTwo,
      transactionType: .expense,
      filters: nil,
      targetInstrument: .defaultTestInstrument
    )

    // Each day uses its own rate: -100 * 1.5 + -100 * 2.0 = -350.
    #expect(balances.count == 1)
    #expect(
      balances[category.id]
        == InstrumentAmount(quantity: -350, instrument: .defaultTestInstrument))
  }

  @Test("category balances include expense legs from investment accounts")
  func categoryBalancesIncludeInvestmentAccountExpenseLegs() async throws {
    // A categorised expense leg posted against an investment account
    // (e.g. a brokerage fee) lands in the breakdown alongside a leg of
    // the same category posted against a regular bank account. This
    // matches the contract on `fetchIncomeAndExpense`'s `expense_qty`
    // sum, which also keeps investment-account expense legs.
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 7, day: 5, hour: 12)
    let backend = try CloudKitAnalysisTestBackend()

    let bank = Account(
      id: UUID(), name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(bank)
    let investment = Account(
      id: UUID(), name: "Brokerage", type: .investment,
      instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(investment)

    let category = Category(id: UUID(), name: "Fees")
    _ = try await backend.categories.create(category)

    _ = try await backend.transactions.create(
      Transaction(
        date: day, payee: "Bank Fee",
        legs: [
          TransactionLeg(
            accountId: bank.id, instrument: .defaultTestInstrument,
            quantity: -25, type: .expense, categoryId: category.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: day, payee: "Brokerage Fee",
        legs: [
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: -100, type: .expense, categoryId: category.id)
        ]))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: day...day,
      transactionType: .expense,
      filters: nil,
      targetInstrument: .defaultTestInstrument
    )

    // Both legs count: -25 + -100 = -125.
    #expect(
      balances[category.id]
        == InstrumentAmount(quantity: -125, instrument: .defaultTestInstrument))
  }

  @Test("category balances include income legs from investment accounts")
  func categoryBalancesIncludeInvestmentAccountIncomeLegs() async throws {
    // A categorised income leg posted against an investment account
    // (e.g. a dividend) lands in the income breakdown. Mirrors
    // `categoryBalancesIncludeInvestmentAccountExpenseLegs` for the
    // income side and matches `fetchIncomeAndExpense`'s `income_qty`
    // contract.
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 7, day: 6, hour: 12)
    let backend = try CloudKitAnalysisTestBackend()

    let investment = Account(
      id: UUID(), name: "Brokerage", type: .investment,
      instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(investment)

    let dividends = Category(id: UUID(), name: "Dividends")
    _ = try await backend.categories.create(dividends)

    _ = try await backend.transactions.create(
      Transaction(
        date: day, payee: "Brokerage",
        legs: [
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: 75, type: .income, categoryId: dividends.id)
        ]))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: day...day,
      transactionType: .income,
      filters: nil,
      targetInstrument: .defaultTestInstrument
    )

    #expect(
      balances[dividends.id]
        == InstrumentAmount(quantity: 75, instrument: .defaultTestInstrument))
  }

  @Test("category balances include categorised legs without an account")
  func categoryBalancesIncludeAccountlessCategorisedLegs() async throws {
    // A categorised expense leg with `accountId == nil` is included.
    // The SQL aggregation does not join to `account`, so account-less
    // legs naturally fall through the `leg.category_id IS NOT NULL`
    // guard and contribute to the breakdown.
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 8, day: 12, hour: 12)
    let backend = try CloudKitAnalysisTestBackend()

    let category = Category(id: UUID(), name: "Travel")
    _ = try await backend.categories.create(category)

    _ = try await backend.transactions.create(
      Transaction(
        date: day, payee: "Bookings",
        legs: [
          TransactionLeg(
            accountId: nil,
            instrument: .defaultTestInstrument,
            quantity: -250,
            type: .expense,
            categoryId: category.id)
        ]))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: day...day,
      transactionType: .expense,
      filters: nil,
      targetInstrument: .defaultTestInstrument
    )

    #expect(
      balances[category.id]
        == InstrumentAmount(quantity: -250, instrument: .defaultTestInstrument))
  }

  @Test("category balances categoryIds filter accepts variable-length sets")
  func categoryBalancesCategoryIdsFilterCounts() async throws {
    // SQLite cannot bind a variable-length array to a single named
    // parameter, so the SQL must compose the `IN (...)` placeholder
    // list dynamically (or bypass via `(:count = 0 OR ...)` shape with
    // GRDB-side parameterisation). Pin three set sizes — 0 (filter off),
    // 1, and 3+ — so a regression that hard-codes a single placeholder
    // breaks the test instead of failing at runtime against a real
    // database.
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 9, day: 1, hour: 12)
    let backend = try CloudKitAnalysisTestBackend()

    let account = Account(
      id: UUID(), name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let cat1 = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(cat1)
    let cat2 = Category(id: UUID(), name: "Restaurants")
    _ = try await backend.categories.create(cat2)
    let cat3 = Category(id: UUID(), name: "Travel")
    _ = try await backend.categories.create(cat3)
    let cat4 = Category(id: UUID(), name: "Other")
    _ = try await backend.categories.create(cat4)

    for category in [cat1, cat2, cat3, cat4] {
      _ = try await backend.transactions.create(
        Transaction(
          date: day, payee: "Store \(category.name)",
          legs: [
            TransactionLeg(
              accountId: account.id, instrument: .defaultTestInstrument,
              quantity: -10, type: .expense, categoryId: category.id)
          ]))
    }

    // Empty set: filter is off — every category's leg is included.
    let unfiltered = try await backend.analysis.fetchCategoryBalances(
      dateRange: day...day,
      transactionType: .expense,
      filters: TransactionFilter(categoryIds: []),
      targetInstrument: .defaultTestInstrument)
    #expect(unfiltered.count == 4)

    // Single-id set: only that category appears.
    let single = try await backend.analysis.fetchCategoryBalances(
      dateRange: day...day,
      transactionType: .expense,
      filters: TransactionFilter(categoryIds: [cat1.id]),
      targetInstrument: .defaultTestInstrument)
    #expect(single.count == 1)
    #expect(
      single[cat1.id]
        == InstrumentAmount(quantity: -10, instrument: .defaultTestInstrument))

    // Three-id set: only those three appear, the fourth is excluded.
    let triple = try await backend.analysis.fetchCategoryBalances(
      dateRange: day...day,
      transactionType: .expense,
      filters: TransactionFilter(categoryIds: [cat1.id, cat2.id, cat3.id]),
      targetInstrument: .defaultTestInstrument)
    #expect(triple.count == 3)
    #expect(triple[cat4.id] == nil)
  }
}
