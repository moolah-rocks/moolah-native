import Foundation
import Testing

@testable import Moolah

/// Rule 11 scoping: a single day's conversion failure must not truncate the
/// balance history. The failing day is omitted (not silently dropped with
/// zeroed input) and surrounding days are returned intact.
@Suite("AnalysisRepository Contract Tests — Rule 11 Scoping")
struct AnalysisRule11ScopingTests {

  @Test("a single day's conversion failure does not truncate the balance history")
  func dailyBalanceConversionFailureIsScopedPerDay() async throws {
    let days = try scopingDays()
    let backend = try scopingBackend(days: days)
    try await seedScopingFixture(backend: backend, days: days)

    // Must not throw: day2's failure is scoped; remaining days returned intact.
    let balances = try await backend.analysis.fetchDailyBalances(
      after: nil, forecastUntil: nil)

    let day1Balance = try #require(
      balances.first { $0.date == AnalysisTestHelpers.calendar.startOfDay(for: days.day1) })
    let day2Balance = balances.first {
      $0.date == AnalysisTestHelpers.calendar.startOfDay(for: days.day2)
    }
    let day3Balance = try #require(
      balances.first { $0.date == AnalysisTestHelpers.calendar.startOfDay(for: days.day3) })

    // day1 rendered with its converted total (100 USD * 1.50 = 150 AUD).
    #expect(day1Balance.balance.quantity == 150)
    #expect(day1Balance.balance.instrument == .defaultTestInstrument)
    // day2 is absent — conversion failed and the total is unavailable.
    #expect(day2Balance == nil)
    // day3 still rendered: 100 USD * 1.40 + 0.02 AUD (cumulative ticks) = 140.02.
    #expect(day3Balance.balance.quantity == (try AnalysisTestHelpers.decimal("140.02")))
  }

  // MARK: - Helpers

  private struct ScopingDays {
    let day1: Date
    let day2: Date
    let day3: Date
  }

  private func scopingDays() throws -> ScopingDays {
    ScopingDays(
      day1: try AnalysisTestHelpers.date(year: 2025, month: 7, day: 1),
      day2: try AnalysisTestHelpers.date(year: 2025, month: 7, day: 2),
      day3: try AnalysisTestHelpers.date(year: 2025, month: 7, day: 3))
  }

  private func scopingBackend(days: ScopingDays) throws -> CloudKitAnalysisTestBackend {
    let rate1 = try AnalysisTestHelpers.decimal("1.50")
    let rate3 = try AnalysisTestHelpers.decimal("1.40")
    // Rate available on day1 and day3; absent (throws) on day2.
    let conversion = FakeConversionService.dateRates(
      [
        days.day1: ["USD": rate1],
        days.day3: ["USD": rate3],
      ],
      failingDates: [AnalysisTestHelpers.calendar.startOfDay(for: days.day2)])
    return try CloudKitAnalysisTestBackend(conversionService: conversion)
  }

  private func seedScopingFixture(
    backend: CloudKitAnalysisTestBackend, days: ScopingDays
  ) async throws {
    let tick = try AnalysisTestHelpers.decimal("0.01")
    let usd = Instrument.fiat(code: "USD")
    let usdAccount = Account(
      id: UUID(), name: "USD Cash", type: .bank, instrument: usd)
    _ = try await backend.accounts.create(usdAccount)

    _ = try await backend.transactions.create(
      Transaction(
        date: days.day1, payee: "Open USD",
        legs: [
          TransactionLeg(
            accountId: usdAccount.id, instrument: usd,
            quantity: 100, type: .openingBalance)
        ]))

    let audAccount = Account(
      id: UUID(), name: "AUD Tip Jar", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(audAccount)

    for date in [days.day2, days.day3] {
      _ = try await backend.transactions.create(
        Transaction(
          date: date, payee: "Tick",
          legs: [
            TransactionLeg(
              accountId: audAccount.id, instrument: .defaultTestInstrument,
              quantity: tick, type: .income)
          ]))
    }
  }
}
