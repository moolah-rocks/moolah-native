import Foundation
import Testing

@testable import Moolah

/// Multi-instrument `PositionBook` coverage for holding revaluation — the
/// USD->AUD rate shifts across days and the daily balance must track the
/// effective rate. Also covers USD-denominated investment accounts with and
/// without market-value overrides.
@Suite("AnalysisRepository Contract Tests — Multi-Instrument Holding")
struct AnalysisMultiInstrumentHoldingTests {

  @Test("holding revalues daily as exchange rate changes")
  func holdingRevaluesDailyAsRateChanges() async throws {
    // Profile is AUD. A USD bank account holds 100 USD from day 1 onward.
    // The USD->AUD rate steps up across days; each day's balance.quantity
    // must reflect the rate effective on that day.
    let day1 = try AnalysisTestHelpers.date(year: 2025, month: 6, day: 1)
    let day2 = try AnalysisTestHelpers.date(year: 2025, month: 6, day: 2)
    let day3 = try AnalysisTestHelpers.date(year: 2025, month: 6, day: 3)
    let rate1 = try AnalysisTestHelpers.decimal("1.50")
    let rate2 = try AnalysisTestHelpers.decimal("1.60")
    let rate3 = try AnalysisTestHelpers.decimal("1.40")
    let tick = try AnalysisTestHelpers.decimal("0.01")

    let conversion = FakeConversionService.dateRates([
      day1: ["USD": rate1],
      day2: ["USD": rate2],
      day3: ["USD": rate3],
    ])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let usd = Instrument.fiat(code: "USD")
    let usdAccount = Account(id: UUID(), name: "USD Cash", type: .bank, instrument: usd)
    _ = try await backend.accounts.create(usdAccount)

    // Open the position on day1 and add small AUD-only legs on later days so
    // each day produces a daily balance entry. The USD position is unchanged
    // across days; only the rate moves.
    _ = try await backend.transactions.create(
      Transaction(
        date: day1, payee: "Open USD",
        legs: [
          TransactionLeg(
            accountId: usdAccount.id, instrument: usd,
            quantity: 100, type: .openingBalance)
        ]))

    let audAccount = Account(
      id: UUID(), name: "AUD Tip Jar", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(audAccount)

    for date in [day2, day3] {
      _ = try await backend.transactions.create(
        Transaction(
          date: date, payee: "Tick",
          legs: [
            TransactionLeg(
              accountId: audAccount.id, instrument: .defaultTestInstrument,
              quantity: tick, type: .income)
          ]))
    }

    let balances = try await backend.analysis.fetchDailyBalances(
      after: nil, forecastUntil: nil)

    let day1Balance = try #require(
      balances.first { $0.date == AnalysisTestHelpers.calendar.startOfDay(for: day1) })
    let day2Balance = try #require(
      balances.first { $0.date == AnalysisTestHelpers.calendar.startOfDay(for: day2) })
    let day3Balance = try #require(
      balances.first { $0.date == AnalysisTestHelpers.calendar.startOfDay(for: day3) })

    // Day1: 100 USD * 1.50 = 150 AUD (no AUD leg yet)
    #expect(day1Balance.balance.quantity == 150)
    // Day2: 100 USD * 1.60 + 0.01 AUD = 160.01 AUD
    #expect(day2Balance.balance.quantity == (try AnalysisTestHelpers.decimal("160.01")))
    // Day3: 100 USD * 1.40 + 0.02 AUD (cumulative) = 140.02 AUD
    #expect(day3Balance.balance.quantity == (try AnalysisTestHelpers.decimal("140.02")))

    // Profile instrument throughout
    #expect(day1Balance.balance.instrument == .defaultTestInstrument)
  }

  @Test("multi-currency investment account with no market value record")
  func multiCurrencyInvestmentNoMarketValue() async throws {
    // USD-denominated investment account with deposits in USD; no market value
    // overrides. Verify investmentValue == nil and `investments` reflects the
    // position-tracking total (snapshot+transfer-deltas under Option A).
    let usd = Instrument.fiat(code: "USD")
    let day1 = try AnalysisTestHelpers.date(year: 2025, month: 7, day: 1)
    let day2 = try AnalysisTestHelpers.date(year: 2025, month: 7, day: 2)
    let day3 = try AnalysisTestHelpers.date(year: 2025, month: 7, day: 3)
    let rate1 = try AnalysisTestHelpers.decimal("1.5")
    let rate2 = try AnalysisTestHelpers.decimal("1.6")
    let rate3 = try AnalysisTestHelpers.decimal("1.7")
    let tick = try AnalysisTestHelpers.decimal("0.01")

    let conversion = FakeConversionService.dateRates([
      day1: ["USD": rate1],
      day2: ["USD": rate2],
      day3: ["USD": rate3],
    ])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let bank = Account(
      id: UUID(), name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(bank)
    let investment = Account(
      id: UUID(), name: "USD Brokerage", type: .investment, instrument: usd)
    _ = try await backend.accounts.create(investment)

    try await seedDepositLegs(
      backend: backend,
      fixture: DepositLegsFixture(
        bank: bank, investment: investment, usd: usd, day1: day1, day2: day2))

    // Day3: tiny AUD income to ensure a daily-balance entry on day3.
    _ = try await backend.transactions.create(
      Transaction(
        date: day3, payee: "Tick",
        legs: [
          TransactionLeg(
            accountId: bank.id, instrument: .defaultTestInstrument,
            quantity: tick, type: .income)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(
      after: nil, forecastUntil: nil)

    let day1Balance = try #require(
      balances.first { $0.date == AnalysisTestHelpers.calendar.startOfDay(for: day1) })
    let day2Balance = try #require(
      balances.first { $0.date == AnalysisTestHelpers.calendar.startOfDay(for: day2) })
    let day3Balance = try #require(
      balances.first { $0.date == AnalysisTestHelpers.calendar.startOfDay(for: day3) })
    #expect(day1Balance.investmentValue == nil)
    #expect(day2Balance.investmentValue == nil)
    #expect(day3Balance.investmentValue == nil)

    // Day1: 100 USD * 1.5 = 150; Day2: 150 USD * 1.6 = 240; Day3: 150 USD * 1.7 = 255.
    #expect(day1Balance.investments.quantity == 150)
    #expect(day2Balance.investments.quantity == 240)
    #expect(day3Balance.investments.quantity == 255)

    // netWorth uses `investments` (no override) — bank + investments.
    // Day1: -100 AUD bank + 150 AUD investments = 50 AUD
    #expect(day1Balance.netWorth.quantity == 50)
  }

  @Test("applyInvestmentValues override still wins on multi-currency investments")
  func investmentValueOverrideWinsMultiCurrency() async throws {
    // USD investment account with a USD market-value override. The override
    // (converted to profile) must take precedence in netWorth over the
    // position-tracking total.
    let usd = Instrument.fiat(code: "USD")
    let rate = try AnalysisTestHelpers.decimal("1.5")
    let conversion = FakeConversionService.fixedRates(["USD": rate])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let bank = Account(
      id: UUID(), name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    let investment = Account(
      id: UUID(), name: "USD Stocks", type: .investment, instrument: usd)
    _ = try await backend.accounts.create(bank)
    _ = try await backend.accounts.create(investment)

    let day1 = try AnalysisTestHelpers.date(year: 2025, month: 11, day: 1)
    let day2 = try AnalysisTestHelpers.date(year: 2025, month: 11, day: 2)
    let tick = try AnalysisTestHelpers.decimal("0.01")

    // Day1 transfer -100 AUD bank -> 100 USD investment (positionTracking total
    // for investments = 100 USD * 1.5 = 150 AUD).
    _ = try await backend.transactions.create(
      Transaction(
        date: day1, payee: "Buy",
        legs: [
          TransactionLeg(
            accountId: bank.id, instrument: .defaultTestInstrument,
            quantity: -100, type: .transfer),
          TransactionLeg(
            accountId: investment.id, instrument: usd,
            quantity: 100, type: .transfer),
        ]))
    // Day2: market value = 200 USD on investment account. Bank tick to ensure
    // a daily-balance entry is emitted on day2.
    try await backend.investments.setValue(
      accountId: investment.id, date: day2,
      value: InstrumentAmount(quantity: 200, instrument: usd))
    _ = try await backend.transactions.create(
      Transaction(
        date: day2, payee: "Tick",
        legs: [
          TransactionLeg(
            accountId: bank.id, instrument: .defaultTestInstrument,
            quantity: tick, type: .income)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(
      after: nil, forecastUntil: nil)

    let day2Balance = try #require(
      balances.first { $0.date == AnalysisTestHelpers.calendar.startOfDay(for: day2) })
    let override = try #require(day2Balance.investmentValue)
    // investmentValue override = 200 USD * 1.5 = 300 AUD.
    #expect(override.quantity == 300)
    #expect(override.instrument == .defaultTestInstrument)
    // netWorth uses the override, NOT the position-tracking total.
    // bank = -100 + 0.01 = -99.99 AUD; netWorth = -99.99 + 300 = 200.01 AUD.
    #expect(day2Balance.netWorth.quantity == (try AnalysisTestHelpers.decimal("200.01")))
    // The position-tracking total is also exposed via `investments`.
    #expect(day2Balance.investments.quantity == 150)
  }

  // MARK: - Helpers

  private struct DepositLegsFixture {
    let bank: Account
    let investment: Account
    let usd: Instrument
    let day1: Date
    let day2: Date
  }

  private func seedDepositLegs(
    backend: CloudKitAnalysisTestBackend,
    fixture: DepositLegsFixture
  ) async throws {
    let bank = fixture.bank
    let investment = fixture.investment
    let usd = fixture.usd
    let day1 = fixture.day1
    let day2 = fixture.day2
    // Day1: transfer 100 AUD bank -> 100 USD investment.
    _ = try await backend.transactions.create(
      Transaction(
        date: day1, payee: "Initial deposit",
        legs: [
          TransactionLeg(
            accountId: bank.id, instrument: .defaultTestInstrument,
            quantity: -100, type: .transfer),
          TransactionLeg(
            accountId: investment.id, instrument: usd,
            quantity: 100, type: .transfer),
        ]))
    // Day2: transfer another 50 USD into the investment account.
    _ = try await backend.transactions.create(
      Transaction(
        date: day2, payee: "Top up",
        legs: [
          TransactionLeg(
            accountId: bank.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .transfer),
          TransactionLeg(
            accountId: investment.id, instrument: usd,
            quantity: 50, type: .transfer),
        ]))
  }
}
