import Foundation
import Testing

@testable import Moolah

/// Fold-contract tests for
/// `GRDBAnalysisRepository.applyTradesModePositionValuations` —
/// happy-path, single-day, and no-op cases. Multi-day failure
/// scoping, cumulative carry-forward, priors-seeding, and the
/// end-to-end pipeline pin live in `GRDBDailyBalancesTradesModeRule11Tests`
/// (shared helpers are in `TradesModeFoldTestSupport`).
///
/// Tests construct `DailyBalancesAggregation` directly and seed
/// `dailyBalances` with placeholder entries so the fold can be
/// exercised in isolation, mirroring the
/// `GRDBDailyBalancesAssembleTests` style.
@Suite("GRDBAnalysisRepository applyTradesModePositionValuations")
struct GRDBDailyBalancesTradesModeTests {

  @Test("case 1: single buy on day D values at day D's price")
  func singleBuyOnDay() async throws {
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayKey = Calendar.current.startOfDay(for: day)
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()
    let row = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: accountId, instrumentId: "USD", type: "trade", qty: 1_000_000_000)
    let conversion = FakeConversionService.dateRates([
      try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 1, hour: 0): [
        "USD": try AnalysisTestHelpers.decimal("1.5")
      ]
    ])
    var balances: [Date: DailyBalance] = [
      dayKey: TradesModeFoldTestSupport.placeholderBalance(at: dayKey)
    ]
    let context = TradesModeFoldTestSupport.makeContext(
      tradesIds: [accountId],
      instrumentMap: ["USD": usd],
      conversionService: conversion)
    let handlers = TradesModeFoldTestSupport.makeHandlers { _, _ in }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [row],
      to: &balances, context: context, handlers: handlers)

    let dayBalance = try #require(balances[dayKey])
    // qty 1_000_000_000 storage units (scale 10^8) = 10 USD; * 1.5 rate = 15 AUD.
    let expected = try AnalysisTestHelpers.decimal("15")
    let value = try #require(dayBalance.investmentValue)
    #expect(value.quantity == expected)
    #expect(value.instrument == .defaultTestInstrument)
    #expect(dayBalance.netWorth.quantity == expected)
  }

  @Test("case 2: two trades-mode accounts both contribute on day D")
  func twoTradesModeAccountsSameDay() async throws {
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayKey = Calendar.current.startOfDay(for: day)
    let usd = Instrument.fiat(code: "USD")
    let aId = UUID()
    let bId = UUID()
    let rowA = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: aId, instrumentId: "USD", type: "trade", qty: 1_000_000_000)
    let rowB = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: bId, instrumentId: "USD", type: "trade", qty: 2_000_000_000)
    let conversion = FakeConversionService.dateRates([
      try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 1, hour: 0): [
        "USD": try AnalysisTestHelpers.decimal("1.5")
      ]
    ])
    var balances: [Date: DailyBalance] = [
      dayKey: TradesModeFoldTestSupport.placeholderBalance(at: dayKey)
    ]
    let context = TradesModeFoldTestSupport.makeContext(
      tradesIds: [aId, bId],
      instrumentMap: ["USD": usd],
      conversionService: conversion)
    let handlers = TradesModeFoldTestSupport.makeHandlers { _, _ in }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [rowA, rowB],
      to: &balances, context: context, handlers: handlers)

    // (10 + 20) * 1.5 = 45.
    let value = try #require(balances[dayKey]?.investmentValue)
    let expected = try AnalysisTestHelpers.decimal("45")
    #expect(value.quantity == expected)
  }

  @Test("case 3: trades-mode + recorded-value account totals add into one investmentValue")
  func tradesModePlusRecordedValueSum() async throws {
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayKey = Calendar.current.startOfDay(for: day)
    let usd = Instrument.fiat(code: "USD")
    let tradesId = UUID()
    let row = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: tradesId, instrumentId: "USD", type: "trade", qty: 1_000_000_000)
    let conversion = FakeConversionService.dateRates([
      try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 1, hour: 0): [
        "USD": try AnalysisTestHelpers.decimal("1.5")
      ]
    ])
    // Pre-seed the day with a snapshot-fold contribution so the new
    // fold's add-not-overwrite contract is visible.
    var balances: [Date: DailyBalance] = [
      dayKey: TradesModeFoldTestSupport.preSeededDailyBalance(on: dayKey)
    ]
    let context = TradesModeFoldTestSupport.makeContext(
      tradesIds: [tradesId],
      instrumentMap: ["USD": usd],
      conversionService: conversion)
    let handlers = TradesModeFoldTestSupport.makeHandlers { _, _ in }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [row],
      to: &balances, context: context, handlers: handlers)

    // Snapshot 100 + trades (10 USD * 1.5) = 115.
    let dayBalance = try #require(balances[dayKey])
    let value = try #require(dayBalance.investmentValue)
    let expectedValue = try AnalysisTestHelpers.decimal("115")
    let expectedNetWorth = try AnalysisTestHelpers.decimal("125")
    #expect(value.quantity == expectedValue)
    // netWorth = balance (10) + investmentValue (115) = 125.
    #expect(dayBalance.netWorth.quantity == expectedNetWorth)
  }

  @Test("case 7: startOfDay normalization keys days correctly across local boundary")
  func rule10StartOfDayNormalization() async throws {
    // Use the local-calendar `localDate(year:month:day:hour:)` helper
    // (added by Task 0) so the test agrees with the production
    // fold's `Calendar.current.startOfDay` math.
    let dayMorning = try AnalysisTestHelpers.localDate(
      year: 2025, month: 6, day: 10, hour: 9)
    let dayEvening = try AnalysisTestHelpers.localDate(
      year: 2025, month: 6, day: 10, hour: 23)
    let dayKey = Calendar.current.startOfDay(for: dayMorning)
    #expect(Calendar.current.startOfDay(for: dayEvening) == dayKey)

    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()
    let rowMorning = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: dayMorning,
      accountId: accountId, instrumentId: "USD", type: "trade", qty: 500_000_000)
    let rowEvening = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: dayEvening,
      accountId: accountId, instrumentId: "USD", type: "trade", qty: 500_000_000)
    // Two rate buckets that distinguish dayKey from sampleDate:
    //   - dayKey (00:00 local) → 1.5
    //   - 06:00 local → 99.99
    // ratesAsOf walks descending and returns the first bucket with
    // date <= requested. A request on dayKey (00:00) finds 1.5
    // because 06:00 is in the future relative to 00:00. A regression
    // that passed `row.sampleDate` (a 09:00 or 23:00 local instant)
    // would walk past 06:00 and pick up 99.99 instead, yielding a
    // far larger total. Both rows would then mis-rate identically,
    // turning the assertion below into a sharp signal.
    let midDay = try AnalysisTestHelpers.localDate(
      year: 2025, month: 6, day: 10, hour: 6)
    let conversion = FakeConversionService.dateRates([
      dayKey: ["USD": try AnalysisTestHelpers.decimal("1.5")],
      midDay: ["USD": try AnalysisTestHelpers.decimal("99.99")],
    ])
    var balances: [Date: DailyBalance] = [
      dayKey: TradesModeFoldTestSupport.placeholderBalance(at: dayKey)
    ]
    let context = TradesModeFoldTestSupport.makeContext(
      tradesIds: [accountId],
      instrumentMap: ["USD": usd],
      conversionService: conversion)
    let handlers = TradesModeFoldTestSupport.makeHandlers { _, _ in }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [rowMorning, rowEvening],
      to: &balances, context: context, handlers: handlers)

    // Both rows applied on the same dayKey; total = 10 USD * 1.5 = 15.
    // A regression that passed `row.sampleDate` to the conversion
    // service would resolve to the 99.99 bucket (since the row
    // timestamps fall after midDay 06:00) and yield 999. The
    // assertion catches that.
    let value = try #require(balances[dayKey]?.investmentValue)
    let expected = try AnalysisTestHelpers.decimal("15")
    #expect(value.quantity == expected)
  }

  @Test("case 8: no trades-mode accounts — fold is a no-op")
  func noTradesModeAccounts() async throws {
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayKey = Calendar.current.startOfDay(for: day)
    var balances: [Date: DailyBalance] = [
      dayKey: TradesModeFoldTestSupport.placeholderBalance(at: dayKey)
    ]
    let originalBalance = balances[dayKey]
    let conversion = FakeConversionService.dateRates([:])
    let context = TradesModeFoldTestSupport.makeContext(
      tradesIds: [], instrumentMap: [:], conversionService: conversion)
    let handlers = TradesModeFoldTestSupport.makeHandlers { _, _ in }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [],
      to: &balances, context: context, handlers: handlers)

    #expect(balances[dayKey] == originalBalance)
  }

  @Test("case 9: empty dailyBalances — no callback fires")
  func emptyDailyBalances() async throws {
    let accountId = UUID()
    var balances: [Date: DailyBalance] = [:]
    let usd = Instrument.fiat(code: "USD")
    let conversion = FakeConversionService.dateRates([:])
    let context = TradesModeFoldTestSupport.makeContext(
      tradesIds: [accountId],
      instrumentMap: ["USD": usd],
      conversionService: conversion)
    let captured = InvestmentValueFailureLog()
    let handlers = TradesModeFoldTestSupport.makeHandlers { error, date in
      captured.append(error, date)
    }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [],
      to: &balances, context: context, handlers: handlers)

    #expect(balances.isEmpty)
    #expect(captured.snapshot().isEmpty)
  }

  @Test("case 10: CSV-imported transfer cash leg + trade position leg both contribute")
  func csvImportedTransferPlusTrade() async throws {
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayKey = Calendar.current.startOfDay(for: day)
    let usd = Instrument.fiat(code: "USD")
    let aud = Instrument.defaultTestInstrument
    let accountId = UUID()
    // .transfer cash leg in profile instrument (AUD) — Rule 8 fast path.
    let cashRow = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: accountId, instrumentId: aud.id, type: "transfer", qty: 5_000_000_000)
    // .trade position leg in USD.
    let tradeRow = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: accountId, instrumentId: "USD", type: "trade", qty: 1_000_000_000)
    let conversion = FakeConversionService.dateRates([
      try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 1, hour: 0): [
        "USD": try AnalysisTestHelpers.decimal("1.5")
      ]
    ])
    var balances: [Date: DailyBalance] = [
      dayKey: TradesModeFoldTestSupport.placeholderBalance(at: dayKey)
    ]
    let context = TradesModeFoldTestSupport.makeContext(
      tradesIds: [accountId],
      instrumentMap: [aud.id: aud, "USD": usd],
      conversionService: conversion)
    let handlers = TradesModeFoldTestSupport.makeHandlers { _, _ in }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [cashRow, tradeRow],
      to: &balances, context: context, handlers: handlers)

    // Cash 50 (AUD identity) + position 10 USD * 1.5 = 65.
    let value = try #require(balances[dayKey]?.investmentValue)
    let expected = try AnalysisTestHelpers.decimal("65")
    #expect(value.quantity == expected)
  }

  @Test("case 11: same-day BUY + SELL netting produces zero contribution")
  func sameDayBuyAndSellNetZero() async throws {
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayKey = Calendar.current.startOfDay(for: day)
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()
    let buy = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: accountId, instrumentId: "USD", type: "trade", qty: 1_000_000_000)
    let sell = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: accountId, instrumentId: "USD", type: "trade", qty: -1_000_000_000)
    let conversion = FakeConversionService.dateRates([
      try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 1, hour: 0): [
        "USD": try AnalysisTestHelpers.decimal("1.5")
      ]
    ])
    var balances: [Date: DailyBalance] = [
      dayKey: TradesModeFoldTestSupport.placeholderBalance(at: dayKey)
    ]
    let context = TradesModeFoldTestSupport.makeContext(
      tradesIds: [accountId],
      instrumentMap: ["USD": usd],
      conversionService: conversion)
    let handlers = TradesModeFoldTestSupport.makeHandlers { _, _ in }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [buy, sell],
      to: &balances, context: context, handlers: handlers)

    // After the cursor advance, positions[accountId][USD] = 0 — the
    // outer dict key is still present, so positions.isEmpty is false
    // and `sumTradesModePositions` is invoked. The new
    // `quantity == 0` guard inside the helper skips the zero
    // position before the Rule 8 fast-path / convert decision —
    // total stays 0. existing.investmentValue is nil, so
    // `(nil ?? .zero(AUD)) + .zero(AUD) == .zero(AUD)`. The day's
    // investmentValue is .zero(AUD) — non-nil, but quantity == 0.
    let value = try #require(balances[dayKey]?.investmentValue)
    #expect(value.quantity == 0)
  }
}
