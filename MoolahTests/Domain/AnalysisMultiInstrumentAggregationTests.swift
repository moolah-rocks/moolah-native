import Foundation
import Testing

@testable import Moolah

/// Multi-instrument aggregation tests — expense breakdown / income and expense /
/// category balances / earmark totals must sum cleanly across instruments at
/// the per-day rate.
@Suite("AnalysisRepository Contract Tests — Multi-Instrument Aggregation")
struct AnalysisMultiInstrumentAggregationTests {

  @Test("multi-currency earmark clamping")
  func multiCurrencyEarmarkClamping() async throws {
    // Two earmarks. A: AUD +200, USD -100 -> per-earmark total 50 AUD (positive).
    // B: USD -50 -> -75 AUD (clamps to 0). Total = 50 (per-earmark, not global).
    let usd = Instrument.fiat(code: "USD")
    let rate = try AnalysisTestHelpers.decimal("1.5")
    let conversion = FakeConversionService.fixedRates(["USD": rate])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let bank = Account(
      id: UUID(), name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(bank)

    let earmarkA = Earmark(id: UUID(), name: "A", instrument: .defaultTestInstrument)
    let earmarkB = Earmark(id: UUID(), name: "B", instrument: .defaultTestInstrument)
    _ = try await backend.earmarks.create(earmarkA)
    _ = try await backend.earmarks.create(earmarkB)

    let date = try AnalysisTestHelpers.date(year: 2025, month: 8, day: 1)
    try await AnalysisMultiInstrumentAggregationSeeds.seedEarmarkClampingLegs(
      backend: backend,
      fixture: EarmarkClampingFixture(
        bank: bank, usd: usd, earmarkA: earmarkA, earmarkB: earmarkB, date: date))

    let balances = try await backend.analysis.fetchDailyBalances(
      after: nil, forecastUntil: nil)
    let day = try #require(
      balances.first { $0.date == AnalysisTestHelpers.calendar.startOfDay(for: date) })
    // Per-earmark clamping: A contributes 50, B clamps to 0. Total = 50.
    #expect(day.earmarked.quantity == 50)
    #expect(day.earmarked.instrument == .defaultTestInstrument)
  }

  @Test("multi-currency expense breakdown across months")
  func multiCurrencyExpenseBreakdownAcrossMonths() async throws {
    let usd = Instrument.fiat(code: "USD")
    let rate = try AnalysisTestHelpers.decimal("1.5")
    let conversion = FakeConversionService.fixedRates(["USD": rate])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let account = Account(
      id: UUID(), name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let groceries = Category(id: UUID(), name: "Groceries")
    let transport = Category(id: UUID(), name: "Transport")
    _ = try await backend.categories.create(groceries)
    _ = try await backend.categories.create(transport)

    let mayDate = try AnalysisTestHelpers.date(year: 2025, month: 5, day: 10)
    let juneDate = try AnalysisTestHelpers.date(year: 2025, month: 6, day: 10)
    try await AnalysisMultiInstrumentAggregationSeeds.seedExpenseBreakdownAcrossMonthsLegs(
      backend: backend,
      fixture: ExpenseBreakdownAcrossMonthsFixture(
        account: account, usd: usd, groceries: groceries, transport: transport,
        mayDate: mayDate, juneDate: juneDate))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    #expect(breakdown.count == 4)

    func find(_ category: Moolah.Category, _ month: String) -> ExpenseBreakdown? {
      breakdown.first { $0.categoryId == category.id && $0.month == month }
    }

    #expect(find(groceries, "202505")?.totalExpenses.quantity == -150)
    #expect(find(transport, "202505")?.totalExpenses.quantity == -20)
    #expect(find(groceries, "202506")?.totalExpenses.quantity == -40)
    #expect(find(transport, "202506")?.totalExpenses.quantity == -45)
    for entry in breakdown {
      #expect(entry.totalExpenses.instrument == .defaultTestInstrument)
    }
  }

  @Test("multi-currency income/expense with rate changes across months")
  func multiCurrencyIncomeExpenseRateChangesAcrossMonths() async throws {
    let usd = Instrument.fiat(code: "USD")
    // UTC-anchored dates: the GRDB analysis path extracts each
    // transaction's UTC calendar day via SQLite's `DATE()` and re-parses
    // it as UTC midnight before asking the conversion service for the
    // rate. Local-timezone dates would drift on positive-UTC runners
    // (AEST: `2025-05-10 00:00 local` is `2025-05-09 14:00 UTC`,
    // SQLite returns `2025-05-09`, the parsed UTC midnight is BEFORE
    // the rate key and `FakeConversionService.dateRates` falls back to
    // 1:1).
    let mayDate = try AnalysisTestHelpers.utcDate(year: 2025, month: 5, day: 10, hour: 12)
    let juneDate = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let mayRateKey = try AnalysisTestHelpers.utcDate(year: 2025, month: 5, day: 10, hour: 0)
    let juneRateKey = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 0)
    let mayRate = try AnalysisTestHelpers.decimal("1.5")
    let juneRate = try AnalysisTestHelpers.decimal("2.0")

    let conversion = FakeConversionService.dateRates([
      mayRateKey: ["USD": mayRate],
      juneRateKey: ["USD": juneRate],
    ])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let account = Account(
      id: UUID(), name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    _ = try await backend.transactions.create(
      Transaction(
        date: mayDate, payee: "May Pay USD",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: 100, type: .income)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: juneDate, payee: "June Pay USD",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: 100, type: .income)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    let may = try #require(data.first { $0.month == "202505" })
    let june = try #require(data.first { $0.month == "202506" })
    #expect(may.income.quantity == 150)
    #expect(june.income.quantity == 200)
    #expect(may.income.instrument == .defaultTestInstrument)
    #expect(june.income.instrument == .defaultTestInstrument)
  }

  @Test("category balances multi-currency")
  func categoryBalancesMultiCurrencyExtended() async throws {
    let usd = Instrument.fiat(code: "USD")
    let eur = Instrument.fiat(code: "EUR")
    // UTC-anchored fixture dates. The GRDB analysis path extracts each
    // transaction's UTC calendar day via SQLite's `DATE()` and
    // re-parses it as UTC midnight before asking the conversion
    // service for the rate; using a local-timezone `date(...)` here
    // would shift the parsed-day Date earlier than the rate-key Date
    // in any timezone east of UTC, so the lookup would miss the
    // intended rate dict and fall through to the 1:1 default.
    let day1 = try AnalysisTestHelpers.utcDate(year: 2025, month: 9, day: 1, hour: 12)
    let day5 = try AnalysisTestHelpers.utcDate(year: 2025, month: 9, day: 5, hour: 12)
    let day10 = try AnalysisTestHelpers.utcDate(year: 2025, month: 9, day: 10, hour: 12)
    let day1RateKey = try AnalysisTestHelpers.utcDate(
      year: 2025, month: 9, day: 1, hour: 0)
    let day5RateKey = try AnalysisTestHelpers.utcDate(
      year: 2025, month: 9, day: 5, hour: 0)
    let day10RateKey = try AnalysisTestHelpers.utcDate(
      year: 2025, month: 9, day: 10, hour: 0)

    let conversion = try FakeConversionService.dateRates([
      day1RateKey: [
        "USD": AnalysisTestHelpers.decimal("1.4"),
        "EUR": AnalysisTestHelpers.decimal("1.6"),
      ],
      day5RateKey: [
        "USD": AnalysisTestHelpers.decimal("1.5"),
        "EUR": AnalysisTestHelpers.decimal("1.7"),
      ],
      day10RateKey: [
        "USD": AnalysisTestHelpers.decimal("1.6"),
        "EUR": AnalysisTestHelpers.decimal("1.8"),
      ],
    ])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let account = Account(
      id: UUID(), name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let food = Category(id: UUID(), name: "Food")
    let travel = Category(id: UUID(), name: "Travel")
    _ = try await backend.categories.create(food)
    _ = try await backend.categories.create(travel)

    try await AnalysisMultiInstrumentAggregationSeeds.seedCategoryBalancesExtendedLegs(
      backend: backend,
      fixture: CategoryBalancesExtendedFixture(
        account: account, usd: usd, eur: eur,
        food: food, travel: travel, day1: day1, day5: day5, day10: day10))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: day1...day10, transactionType: .expense,
      filters: nil, targetInstrument: .defaultTestInstrument)

    #expect(balances[food.id]?.quantity == -190)
    #expect(balances[travel.id]?.quantity == -52)
    #expect(balances[food.id]?.instrument == .defaultTestInstrument)
  }

  @Test("category balances convert to the requested target instrument")
  func categoryBalancesHonourTargetInstrument() async throws {
    let usd = Instrument.fiat(code: "USD")
    let audRate = try AnalysisTestHelpers.decimal("0.5")
    let conversion = FakeConversionService.fixedRates(["AUD": audRate])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)
    let account = Account(
      id: UUID(), name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Food")
    _ = try await backend.categories.create(category)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "AUD Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -40, type: .expense, categoryId: category.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "US Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: -30, type: .expense, categoryId: category.id)
        ]))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: today...today, transactionType: .expense,
      filters: nil, targetInstrument: usd)

    // -40 AUD * 0.5 = -20 USD; -30 USD passes through. Sum = -50 USD.
    #expect(balances[category.id] == InstrumentAmount(quantity: -50, instrument: usd))
  }

}

// MARK: - Fixtures

private struct EarmarkClampingFixture {
  let bank: Account
  let usd: Instrument
  let earmarkA: Earmark
  let earmarkB: Earmark
  let date: Date
}

private struct ExpenseBreakdownAcrossMonthsFixture {
  let account: Account
  let usd: Instrument
  let groceries: Moolah.Category
  let transport: Moolah.Category
  let mayDate: Date
  let juneDate: Date
}

private struct CategoryBalancesExtendedFixture {
  let account: Account
  let usd: Instrument
  let eur: Instrument
  let food: Moolah.Category
  let travel: Moolah.Category
  let day1: Date
  let day5: Date
  let day10: Date
}

// MARK: - Helpers

private enum AnalysisMultiInstrumentAggregationSeeds {
  static func seedEarmarkClampingLegs(
    backend: CloudKitAnalysisTestBackend,
    fixture: EarmarkClampingFixture
  ) async throws {
    // Earmark A: AUD income 200 and USD expense -100.
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.date, payee: "A: AUD income",
        legs: [
          TransactionLeg(
            accountId: fixture.bank.id, instrument: .defaultTestInstrument,
            quantity: 200, type: .income, earmarkId: fixture.earmarkA.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.date, payee: "A: USD expense",
        legs: [
          TransactionLeg(
            accountId: fixture.bank.id, instrument: fixture.usd,
            quantity: -100, type: .expense, earmarkId: fixture.earmarkA.id)
        ]))
    // Earmark B: USD expense only; clamps per-earmark to 0.
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.date, payee: "B: USD expense",
        legs: [
          TransactionLeg(
            accountId: fixture.bank.id, instrument: fixture.usd,
            quantity: -50, type: .expense, earmarkId: fixture.earmarkB.id)
        ]))
  }

  static func seedExpenseBreakdownAcrossMonthsLegs(
    backend: CloudKitAnalysisTestBackend,
    fixture: ExpenseBreakdownAcrossMonthsFixture
  ) async throws {
    // May: groceries -100 USD => -150 AUD; transport -20 AUD.
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.mayDate, payee: "May groc USD",
        legs: [
          TransactionLeg(
            accountId: fixture.account.id, instrument: fixture.usd,
            quantity: -100, type: .expense, categoryId: fixture.groceries.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.mayDate, payee: "May transit",
        legs: [
          TransactionLeg(
            accountId: fixture.account.id, instrument: .defaultTestInstrument,
            quantity: -20, type: .expense, categoryId: fixture.transport.id)
        ]))
    // June: groceries -40 AUD; transport -30 USD => -45 AUD.
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.juneDate, payee: "June groc",
        legs: [
          TransactionLeg(
            accountId: fixture.account.id, instrument: .defaultTestInstrument,
            quantity: -40, type: .expense, categoryId: fixture.groceries.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.juneDate, payee: "June transit USD",
        legs: [
          TransactionLeg(
            accountId: fixture.account.id, instrument: fixture.usd,
            quantity: -30, type: .expense, categoryId: fixture.transport.id)
        ]))
  }

  static func seedCategoryBalancesExtendedLegs(
    backend: CloudKitAnalysisTestBackend,
    fixture: CategoryBalancesExtendedFixture
  ) async throws {
    // Food: -100 USD on day1 (=> -140 AUD) + -50 AUD on day5 = -190 AUD.
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.day1, payee: "Food USD",
        legs: [
          TransactionLeg(
            accountId: fixture.account.id, instrument: fixture.usd,
            quantity: -100, type: .expense, categoryId: fixture.food.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.day5, payee: "Food AUD",
        legs: [
          TransactionLeg(
            accountId: fixture.account.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .expense, categoryId: fixture.food.id)
        ]))
    // Travel: -20 EUR on day5 (=> -34) + -10 EUR on day10 (=> -18) = -52 AUD.
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.day5, payee: "Travel EUR",
        legs: [
          TransactionLeg(
            accountId: fixture.account.id, instrument: fixture.eur,
            quantity: -20, type: .expense, categoryId: fixture.travel.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.day10, payee: "Travel EUR",
        legs: [
          TransactionLeg(
            accountId: fixture.account.id, instrument: fixture.eur,
            quantity: -10, type: .expense, categoryId: fixture.travel.id)
        ]))
  }
}
