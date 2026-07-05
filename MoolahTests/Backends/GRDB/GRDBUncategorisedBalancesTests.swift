import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for the "Uncategorised" Reports-row aggregation:
/// `GRDBAnalysisRepository.fetchCategoryBalancesByType`'s
/// `incomeUncategorised` / `expenseUncategorised` fields, backed by
/// `+UncategorisedBalances.swift`.
///
/// Mirrors `GRDBCategoryBalancesConversionTests`'s style — the per-day
/// rate-sensitive test pins the same conversion contract
/// (`INSTRUMENT_CONVERSION_GUIDE.md` Rule 5) as the category-balances
/// aggregation, just summed to a single total instead of per-category
/// buckets.
@Suite("GRDBAnalysisRepository fetchCategoryBalancesByType — uncategorised totals")
struct GRDBUncategorisedBalancesTests {

  @Test("uncategorised income and expense legs sum into their own totals")
  func uncategorisedLegsSumCorrectly() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    let dateRange = today...today

    // Two uncategorised expense legs and one uncategorised income leg —
    // no `categoryId` on any of them.
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Unknown Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -40, type: .expense)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Unknown Store 2",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -10, type: .expense)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Mystery Deposit",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 100, type: .income)
        ]))

    let result = try await backend.analysis.fetchCategoryBalancesByType(
      dateRange: dateRange,
      filters: nil,
      targetInstrument: .defaultTestInstrument)

    #expect(
      result.expenseUncategorised
        == InstrumentAmount(quantity: -50, instrument: .defaultTestInstrument))
    #expect(
      result.incomeUncategorised
        == InstrumentAmount(quantity: 100, instrument: .defaultTestInstrument))
  }

  @Test("categorised totals are unaffected by presence of uncategorised legs")
  func categorisedTotalsUnaffectedByUncategorisedLegs() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    let dateRange = today...today

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -70, type: .expense, categoryId: category.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Unknown Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -30, type: .expense)
        ]))

    let result = try await backend.analysis.fetchCategoryBalancesByType(
      dateRange: dateRange,
      filters: nil,
      targetInstrument: .defaultTestInstrument)

    // The categorised bucket keeps its old total — unaffected by the
    // uncategorised leg sitting alongside it.
    #expect(
      result.expense[category.id]
        == InstrumentAmount(quantity: -70, instrument: .defaultTestInstrument))
    #expect(
      result.expenseUncategorised
        == InstrumentAmount(quantity: -30, instrument: .defaultTestInstrument))
  }

  @Test("uncategorised totals are nil when there are no uncategorised legs")
  func uncategorisedNilWhenNone() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    let dateRange = today...today

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -70, type: .expense, categoryId: category.id)
        ]))

    let result = try await backend.analysis.fetchCategoryBalancesByType(
      dateRange: dateRange,
      filters: nil,
      targetInstrument: .defaultTestInstrument)

    #expect(result.expenseUncategorised == nil)
    #expect(result.incomeUncategorised == nil)
  }

  @Test("uncategorised balances convert each day's USD legs at that day's rate")
  func uncategorisedBalancesConvertPerDayRate() async throws {
    // Same rate-pinning shape as
    // `GRDBCategoryBalancesConversionTests.categoryBalancesConvertPerDayRate`:
    // two consecutive UTC days with different USD→AUD rates and
    // identical USD legs. If the SQL grouping collapsed both days into a
    // single bucket, both legs would convert at the same rate and the
    // total would diverge from the per-day truth.
    let dayOne = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayTwo = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 11, hour: 12)
    let rateOne = try AnalysisTestHelpers.decimal("1.5")
    let rateTwo = try AnalysisTestHelpers.decimal("2.0")

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

    let usd = Instrument.fiat(code: "USD")

    // Both legs uncategorised — no `categoryId`.
    _ = try await backend.transactions.create(
      Transaction(
        date: dayOne, payee: "US Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: -100, type: .expense)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: dayTwo, payee: "US Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: -100, type: .expense)
        ]))

    let result = try await backend.analysis.fetchCategoryBalancesByType(
      dateRange: dayOne...dayTwo,
      filters: nil,
      targetInstrument: .defaultTestInstrument)

    // Each day uses its own rate: -100 * 1.5 + -100 * 2.0 = -350.
    #expect(
      result.expenseUncategorised
        == InstrumentAmount(quantity: -350, instrument: .defaultTestInstrument))
  }
}
