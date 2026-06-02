import Foundation
import GRDB
import Testing

@testable import Moolah

/// Per-day conversion correctness tests for `GRDBInsightDataSource`.
///
/// Each aggregation method converts foreign-instrument legs using that leg's
/// own calendar day — so two legs with the same nominal quantity but posted
/// on different days with different rates must yield different magnitudes.
/// Rule 11 (drop-don't-guess on conversion failure) is the companion test in
/// `GRDBInsightDataSourceTests`.
@Suite("GRDBInsightDataSource per-day conversion")
struct GRDBInsightDataSourceConversionTests {
  private let aud = Instrument.defaultTestInstrument

  private func context(now: Date) -> InsightContext {
    InsightContext(now: now, reportingCurrency: aud)
  }

  private func leg(
    _ quantity: Decimal,
    type: TransactionType,
    instrument: Instrument
  ) -> TransactionLeg {
    TransactionLeg(
      accountId: nil, instrument: instrument, quantity: quantity,
      type: type, categoryId: nil)
  }

  // MARK: - dailyTotals

  @Test("dailyTotals converts each day's foreign legs at that day's rate")
  func dailyTotalsConvertsPerDay() async throws {
    let dayOne = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 10)
    let dayTwo = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 11)
    let conversion = DateBasedFixedConversionService(
      rates: [
        try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 10, hour: 0): ["USD": 1.5],
        try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 11, hour: 0): ["USD": 2.0],
      ])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)
    let usd = Instrument.fiat(code: "USD")
    _ = try await backend.transactions.create(
      Transaction(date: dayOne, payee: "A", legs: [leg(-100, type: .expense, instrument: usd)]))
    _ = try await backend.transactions.create(
      Transaction(date: dayTwo, payee: "B", legs: [leg(-100, type: .expense, instrument: usd)]))

    let totals = try await backend.insightDataSource.dailyTotals(
      context: context(now: try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)))

    #expect(try #require(totals.first).spendMagnitude == 150)
    #expect(try #require(totals.last).spendMagnitude == 200)
  }

  // MARK: - incomeSamples

  @Test("incomeSamples converts each leg at its own day's rate")
  func incomeSamplesConvertsPerDay() async throws {
    let dayOne = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 10)
    let dayTwo = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 11)
    // dayOne rate: 1 USD → 1.5 AUD; dayTwo rate: 1 USD → 2.0 AUD.
    let conversion = DateBasedFixedConversionService(
      rates: [
        try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 10, hour: 0): ["USD": 1.5],
        try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 11, hour: 0): ["USD": 2.0],
      ])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)
    let usd = Instrument.fiat(code: "USD")
    // Each leg is 100 USD; the converted AUD magnitude must reflect each day's rate.
    _ = try await backend.transactions.create(
      Transaction(
        date: dayOne, payee: "DayOneSalary",
        legs: [leg(100, type: .income, instrument: usd)]))
    _ = try await backend.transactions.create(
      Transaction(
        date: dayTwo, payee: "DayTwoBonus",
        legs: [leg(100, type: .income, instrument: usd)]))

    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let samples = try await backend.insightDataSource.incomeSamples(
      windowDays: 365, maxCount: 50, context: context(now: now))

    // SQL orders most-recent first (dayTwo rn=1, dayOne rn=2).
    // dayTwo: 100 USD × 2.0 = 200 AUD; dayOne: 100 USD × 1.5 = 150 AUD.
    #expect(samples == [200, 150])
    #expect(samples.allSatisfy { $0 > 0 })
  }
}
