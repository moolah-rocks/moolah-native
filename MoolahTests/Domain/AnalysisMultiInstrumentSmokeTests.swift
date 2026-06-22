import Foundation
import Testing

@testable import Moolah

/// End-to-end multi-instrument smoke tests — starting balances across an
/// `after` cutoff, whole-portfolio combinations (bank + investment + earmark +
/// USD + rate-varying), forecast continuation from multi-currency actuals, and
/// the Option A single-currency starting-balance pin.
@Suite("AnalysisRepository Contract Tests — Multi-Instrument Smoke")
struct AnalysisMultiInstrumentSmokeTests {

  @Test("multi-currency starting balance before 'after' cutoff")
  func multiCurrencyStartingBalanceBeforeAfter() async throws {
    let usd = Instrument.fiat(code: "USD")
    let eur = Instrument.fiat(code: "EUR")
    let usdRate = try AnalysisTestHelpers.decimal("1.5")
    let eurRate = try AnalysisTestHelpers.decimal("1.7")

    let conversion = FakeConversionService.fixedRates(["USD": usdRate, "EUR": eurRate])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let day1 = try AnalysisTestHelpers.date(year: 2025, month: 5, day: 1)
    let day5 = try AnalysisTestHelpers.date(year: 2025, month: 5, day: 5)
    let day10 = try AnalysisTestHelpers.date(year: 2025, month: 5, day: 10)
    let day15 = try AnalysisTestHelpers.date(year: 2025, month: 5, day: 15)
    let after = try AnalysisTestHelpers.date(year: 2025, month: 5, day: 30)
    let postCutoff = try AnalysisTestHelpers.date(year: 2025, month: 5, day: 31)
    let tick = try AnalysisTestHelpers.decimal("0.01")

    let bank = Account(
      id: UUID(), name: "Multi Bank", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(bank)
    let investment = Account(
      id: UUID(), name: "Multi Investment", type: .investment, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(investment)

    try await AnalysisMultiInstrumentSmokeSeeds.seedStartingBalancePriors(
      backend: backend,
      fixture: StartingBalancePriorsFixture(
        bank: bank, investment: investment, usd: usd, eur: eur,
        day1: day1, day5: day5, day10: day10, day15: day15))

    // Single post-`after` AUD leg so a daily balance is emitted.
    _ = try await backend.transactions.create(
      Transaction(
        date: postCutoff, payee: "Tick",
        legs: [
          TransactionLeg(
            accountId: bank.id, instrument: .defaultTestInstrument,
            quantity: tick, type: .income)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(
      after: after, forecastUntil: nil)

    let postKey = AnalysisTestHelpers.calendar.startOfDay(for: postCutoff)
    let post = try #require(balances.first { $0.date == postKey })
    // bank: 200 AUD + 50 EUR * 1.7 + 40 USD * 1.5 + 0.01 = 345.01 AUD
    #expect(post.balance.quantity == (try AnalysisTestHelpers.decimal("345.01")))
    // investments (Option A): 100 USD * 1.5 = 150 AUD
    #expect(post.investments.quantity == 150)
    #expect(post.balance.instrument == .defaultTestInstrument)
  }

  @Test("mixed bank + investment + earmark + multi-currency + rate-varying")
  func mixedSmokeMultiCurrencyRateVarying() async throws {
    let usd = Instrument.fiat(code: "USD")
    let day1 = try AnalysisTestHelpers.date(year: 2025, month: 10, day: 1)
    let day2 = try AnalysisTestHelpers.date(year: 2025, month: 10, day: 2)
    let day3 = try AnalysisTestHelpers.date(year: 2025, month: 10, day: 3)
    let rate1 = try AnalysisTestHelpers.decimal("1.4")
    let rate2 = try AnalysisTestHelpers.decimal("1.5")
    let rate3 = try AnalysisTestHelpers.decimal("1.6")

    let conversion = FakeConversionService.dateRates([
      day1: ["USD": rate1],
      day2: ["USD": rate2],
      day3: ["USD": rate3],
    ])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let bank = Account(
      id: UUID(), name: "Bank AUD", type: .bank, instrument: .defaultTestInstrument)
    let investment = Account(
      id: UUID(), name: "USD Stocks", type: .investment, instrument: usd)
    _ = try await backend.accounts.create(bank)
    _ = try await backend.accounts.create(investment)

    let earmark = Earmark(id: UUID(), name: "Holiday", instrument: .defaultTestInstrument)
    _ = try await backend.earmarks.create(earmark)

    try await AnalysisMultiInstrumentSmokeSeeds.seedSmokeLegs(
      backend: backend,
      fixture: SmokeLegsFixture(
        bank: bank, investment: investment, usd: usd,
        earmark: earmark, day1: day1, day2: day2, day3: day3))

    let balances = try await backend.analysis.fetchDailyBalances(
      after: nil, forecastUntil: nil)
    #expect(balances.count >= 3)

    for entry in balances {
      let expectedNet = entry.balance + (entry.investmentValue ?? entry.investments)
      #expect(entry.netWorth == expectedNet, "netWorth invariant failed on \(entry.date)")
      #expect(
        entry.availableFunds == entry.balance - entry.earmarked,
        "availableFunds invariant failed on \(entry.date)")
      #expect(entry.balance.instrument == .defaultTestInstrument)
    }

    // Spot-check day3: bank = 1000+100-200 AUD + (-50 USD * 1.6 = -80) = 820 AUD
    // investments (transfers-only) = 200 USD * 1.6 = 320 AUD
    let day3Balance = try #require(
      balances.first { $0.date == AnalysisTestHelpers.calendar.startOfDay(for: day3) })
    #expect(day3Balance.balance.quantity == 820)
    #expect(day3Balance.investments.quantity == 320)
    #expect(day3Balance.earmarked.quantity == 100)
  }

  @Test("forecast starting from multi-currency actuals")
  func forecastFromMultiCurrencyActuals() async throws {
    let usd = Instrument.fiat(code: "USD")
    let rate = try AnalysisTestHelpers.decimal("1.5")
    let conversion = FakeConversionService.fixedRates(["USD": rate])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let today = AnalysisTestHelpers.calendar.startOfDay(for: Date())
    let yesterday = try AnalysisTestHelpers.addingDays(-1, to: today)
    let tomorrow = try AnalysisTestHelpers.addingDays(1, to: today)
    let nextWeek = try AnalysisTestHelpers.addingDays(7, to: today)

    let bank = Account(
      id: UUID(), name: "Bank AUD", type: .bank, instrument: .defaultTestInstrument)
    let investment = Account(
      id: UUID(), name: "USD Brokerage", type: .investment, instrument: usd)
    _ = try await backend.accounts.create(bank)
    _ = try await backend.accounts.create(investment)

    try await AnalysisMultiInstrumentSmokeSeeds.seedForecastActuals(
      backend: backend,
      fixture: ForecastActualsFixture(
        bank: bank, investment: investment, usd: usd,
        yesterday: yesterday, tomorrow: tomorrow))

    let balances = try await backend.analysis.fetchDailyBalances(
      after: nil, forecastUntil: nextWeek)

    let forecastEntry = try #require(balances.first { $0.date == tomorrow && $0.isForecast })
    // Bank starts at 500 AUD; scheduled -50 USD pre-converted at Date() (rate 1.5) = -75 AUD.
    #expect(forecastEntry.balance.quantity == 425)
    // Investments carry the 200 USD opening: 200 USD * 1.5 = 300 AUD.
    #expect(forecastEntry.investments.quantity == 300)
  }

  @Test(
    "single-currency starting balance includes pre-after non-transfer investment legs (Option A)")
  func singleCurrencyOptionAStartingBalance() async throws {
    let backend = try CloudKitAnalysisTestBackend()

    let bank = Account(
      id: UUID(), name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    let investment = Account(
      id: UUID(), name: "Investment", type: .investment, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(bank)
    _ = try await backend.accounts.create(investment)

    let day1 = try AnalysisTestHelpers.date(year: 2025, month: 12, day: 1)
    let day5 = try AnalysisTestHelpers.date(year: 2025, month: 12, day: 5)
    let after = try AnalysisTestHelpers.date(year: 2025, month: 12, day: 10)
    let day12 = try AnalysisTestHelpers.date(year: 2025, month: 12, day: 12)

    _ = try await backend.transactions.create(
      Transaction(
        date: day1, payee: "Investment opening",
        legs: [
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: 500, type: .openingBalance)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: day5, payee: "Investment dividend",
        legs: [
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: 100, type: .income)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: day12, payee: "Tick",
        legs: [
          TransactionLeg(
            accountId: bank.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .income)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(
      after: after, forecastUntil: nil)

    let day = try #require(
      balances.first { $0.date == AnalysisTestHelpers.calendar.startOfDay(for: day12) })
    // Option A: pre-after openingBalance + income on investment account contribute
    // to the transfers-only baseline (snapshot at `after`).
    #expect(day.investments.quantity == 600)
    #expect(day.balance.quantity == 10)
  }

}

// MARK: - Fixtures

private struct StartingBalancePriorsFixture {
  let bank: Account
  let investment: Account
  let usd: Instrument
  let eur: Instrument
  let day1: Date
  let day5: Date
  let day10: Date
  let day15: Date
}

private struct SmokeLegsFixture {
  let bank: Account
  let investment: Account
  let usd: Instrument
  let earmark: Earmark
  let day1: Date
  let day2: Date
  let day3: Date
}

private struct ForecastActualsFixture {
  let bank: Account
  let investment: Account
  let usd: Instrument
  let yesterday: Date
  let tomorrow: Date
}

// MARK: - Helpers

private enum AnalysisMultiInstrumentSmokeSeeds {
  static func seedStartingBalancePriors(
    backend: CloudKitAnalysisTestBackend,
    fixture: StartingBalancePriorsFixture
  ) async throws {
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.day1, payee: "AUD opening",
        legs: [
          TransactionLeg(
            accountId: fixture.bank.id, instrument: .defaultTestInstrument,
            quantity: 200, type: .openingBalance)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.day5, payee: "USD investment opening",
        legs: [
          TransactionLeg(
            accountId: fixture.investment.id, instrument: fixture.usd,
            quantity: 100, type: .openingBalance)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.day10, payee: "EUR side",
        legs: [
          TransactionLeg(
            accountId: fixture.bank.id, instrument: fixture.eur,
            quantity: 50, type: .income)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.day15, payee: "USD side income",
        legs: [
          TransactionLeg(
            accountId: fixture.bank.id, instrument: fixture.usd,
            quantity: 40, type: .income)
        ]))
  }

  static func seedSmokeLegs(
    backend: CloudKitAnalysisTestBackend,
    fixture: SmokeLegsFixture
  ) async throws {
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.day1, payee: "Open Bank",
        legs: [
          TransactionLeg(
            accountId: fixture.bank.id, instrument: .defaultTestInstrument,
            quantity: 1000, type: .openingBalance)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.day1, payee: "Holiday savings",
        legs: [
          TransactionLeg(
            accountId: fixture.bank.id, instrument: .defaultTestInstrument,
            quantity: 100, type: .income, earmarkId: fixture.earmark.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.day2, payee: "Buy USD stocks",
        legs: [
          TransactionLeg(
            accountId: fixture.bank.id, instrument: .defaultTestInstrument,
            quantity: -200, type: .transfer),
          TransactionLeg(
            accountId: fixture.investment.id, instrument: fixture.usd,
            quantity: 200, type: .transfer),
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.day3, payee: "USD spend",
        legs: [
          TransactionLeg(
            accountId: fixture.bank.id, instrument: fixture.usd,
            quantity: -50, type: .expense)
        ]))
  }

  static func seedForecastActuals(
    backend: CloudKitAnalysisTestBackend,
    fixture: ForecastActualsFixture
  ) async throws {
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.yesterday, payee: "AUD opening",
        legs: [
          TransactionLeg(
            accountId: fixture.bank.id, instrument: .defaultTestInstrument,
            quantity: 800, type: .openingBalance)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: fixture.yesterday, payee: "Buy USD",
        legs: [
          TransactionLeg(
            accountId: fixture.bank.id, instrument: .defaultTestInstrument,
            quantity: -300, type: .transfer),
          TransactionLeg(
            accountId: fixture.investment.id, instrument: fixture.usd,
            quantity: 200, type: .transfer),
        ]))

    // Scheduled (one-off): -50 USD expense tomorrow on the bank account.
    _ = try await backend.transactions.create(
      Transaction(
        id: UUID(), date: fixture.tomorrow, payee: "USD scheduled",
        recurPeriod: .once,
        legs: [
          TransactionLeg(
            accountId: fixture.bank.id, instrument: fixture.usd,
            quantity: -50, type: .expense)
        ]))
  }
}
