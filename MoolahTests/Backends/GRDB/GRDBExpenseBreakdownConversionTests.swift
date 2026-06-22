import Foundation
import GRDB
import Testing

@testable import Moolah

/// Date-sensitive conversion tests for `GRDBAnalysisRepository.fetchExpenseBreakdown`.
///
/// The SQL aggregation groups by `(DATE(t.date), category_id, instrument_id)`
/// so per-day grouping is rate-equivalent to the per-leg conversion
/// the SwiftData implementation performed. These tests pin that the
/// right calendar day is fed into the `InstrumentConversionService` per
/// row — a regression that drops the `DATE(t.date)` projection
/// (collapsing to per-month or per-range grouping) would silently pass
/// against constant-rate fixtures.
///
/// Uses `FakeConversionService.dateRates`, which returns a different rate
/// per calendar day, to detect such regressions.
@Suite("GRDBAnalysisRepository expense breakdown — date-sensitive conversion")
struct GRDBExpenseBreakdownConversionTests {

  @Test("expense breakdown converts each day's USD legs at that day's rate")
  func expenseBreakdownConvertsPerDayRate() async throws {
    // Two consecutive UTC days with different USD→AUD rates. The legs are
    // identical USD expenses; if SQL grouping collapses days into a single
    // bucket, both legs would convert at the same rate and the totals
    // would diverge from the per-day truth.
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

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    // Both transactions land in the same financial month (June, monthEnd
    // 25), so they collapse into one breakdown row. The total uses each
    // day's own rate: -100 * 1.5 + -100 * 2.0 = -350.
    #expect(breakdown.count == 1)
    #expect(breakdown[0].categoryId == category.id)
    #expect(breakdown[0].totalExpenses.quantity == -350)
    #expect(breakdown[0].totalExpenses.instrument == .defaultTestInstrument)
  }

  @Test("expense breakdown groups same-day legs into one conversion")
  func expenseBreakdownSameDaySingleConversion() async throws {
    // Three legs on the same day — the SQL `GROUP BY (day, category, instrument)`
    // sums their quantities into one bucket so the conversion runs once per
    // (day, category, instrument) tuple, not once per leg. Functionally
    // identical to per-leg conversion at this rate (same day = same rate).
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 7, day: 5, hour: 12)
    let rate = try AnalysisTestHelpers.decimal("1.5")
    let conversion = FakeConversionService.dateRates([
      try AnalysisTestHelpers.utcDate(year: 2025, month: 7, day: 5, hour: 0): [
        "USD": rate
      ]
    ])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let account = Account(
      id: UUID(), name: "USD Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    let usd = Instrument.fiat(code: "USD")

    for index in 0..<3 {
      _ = try await backend.transactions.create(
        Transaction(
          date: day, payee: "Store \(index)",
          legs: [
            TransactionLeg(
              accountId: account.id, instrument: usd,
              quantity: -50, type: .expense, categoryId: category.id)
          ]))
    }

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    #expect(breakdown.count == 1)
    #expect(breakdown[0].categoryId == category.id)
    // Three -50 USD legs summed to -150 USD; converted at 1.5x = -225 AUD.
    #expect(breakdown[0].totalExpenses.quantity == -225)
  }

  @Test("expense breakdown includes categorised legs without an account")
  func expenseBreakdownIncludesAccountlessCategorisedLegs() async throws {
    // The expense breakdown only filters
    // `leg.type == .expense && leg.categoryId != nil` — it does NOT
    // filter on `accountId`. An expense leg with a category but no
    // `accountId` must surface in the breakdown. Locks the
    // semantic-parity contract documented on
    // `fetchExpenseBreakdownAggregation`'s doc comment so a future
    // refactor that re-introduces `account_id IS NOT NULL` to the
    // WHERE clause breaks this test instead of silently dropping rows.
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 8, day: 12, hour: 12)
    let conversion = FakeConversionService.dateRates([:])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

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

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(
      monthEnd: 25, after: nil)

    #expect(breakdown.count == 1)
    #expect(breakdown[0].categoryId == category.id)
    #expect(breakdown[0].totalExpenses.quantity == -250)
    #expect(breakdown[0].totalExpenses.instrument == .defaultTestInstrument)
  }

  @Test("expense breakdown applies different month rates to different months")
  func expenseBreakdownAppliesDifferentMonthRates() async throws {
    // Two transactions in different months with different rate dicts.
    // Catches a regression where `convertedQuantity` is invoked with
    // `Date()` (collapsing to today's rate for every row) or where
    // `parseDayString` loses the per-row UTC midnight (collapsing to a
    // single rate-as-of-now lookup).
    let janRate = try AnalysisTestHelpers.decimal("2.0")
    let junRate = try AnalysisTestHelpers.decimal("3.0")
    let janTxnDay = try AnalysisTestHelpers.utcDate(
      year: 2025, month: 1, day: 15, hour: 12)
    let junTxnDay = try AnalysisTestHelpers.utcDate(
      year: 2025, month: 6, day: 15, hour: 12)
    let janRateKey = try AnalysisTestHelpers.utcDate(
      year: 2025, month: 1, day: 15, hour: 0)
    let junRateKey = try AnalysisTestHelpers.utcDate(
      year: 2025, month: 6, day: 15, hour: 0)
    let conversion = FakeConversionService.dateRates([
      janRateKey: ["USD": janRate],
      junRateKey: ["USD": junRate],
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
        date: janTxnDay, payee: "January Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: -100, type: .expense, categoryId: category.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: junTxnDay, payee: "June Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: -100, type: .expense, categoryId: category.id)
        ]))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    let january = try #require(breakdown.first { $0.month == "202501" })
    let june = try #require(breakdown.first { $0.month == "202506" })
    #expect(january.totalExpenses.quantity == -200)
    #expect(june.totalExpenses.quantity == -300)
  }
}
