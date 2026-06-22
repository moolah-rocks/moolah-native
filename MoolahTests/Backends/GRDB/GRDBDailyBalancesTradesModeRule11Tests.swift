import Foundation
import Testing

@testable import Moolah

/// Multi-day, Rule 11 failure-scoping, carry-forward, priors-seed, and
/// end-to-end pipeline tests for
/// `GRDBAnalysisRepository.applyTradesModePositionValuations`. Same
/// fold and helpers (`TradesModeFoldTestSupport`) as
/// `GRDBDailyBalancesTradesModeTests`, partitioned by topic.
@Suite("GRDBAnalysisRepository applyTradesModePositionValuations — Rule 11 / cross-day")
struct GRDBDailyBalancesTradesModeRule11Tests {

  @Test("case 4: per-day conversion failure drops day from dailyBalances")
  func ruleEleven_perDayFailureScopedToDay() async throws {
    // `Calendar.current.startOfDay` is the production fold's day-key
    // function (Rule 10). Build the test's seed key the same way so a
    // calendar mismatch can't make the test pass vacuously.
    let dayOne = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayTwo = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 11, hour: 12)
    let keyOne = Calendar.current.startOfDay(for: dayOne)
    let keyTwo = Calendar.current.startOfDay(for: dayTwo)
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()
    let rowOne = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: dayOne,
      accountId: accountId, instrumentId: "USD", type: "trade", qty: 1_000_000_000)
    // Rate available on day two only; day one fails.
    let conversion = FakeConversionService.dateRates(
      [
        try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 1, hour: 0): [
          "USD": try AnalysisTestHelpers.decimal("1.5")
        ]
      ],
      failingDates: [keyOne])
    var balances: [Date: DailyBalance] = [
      keyOne: TradesModeFoldTestSupport.placeholderBalance(at: keyOne),
      keyTwo: TradesModeFoldTestSupport.placeholderBalance(at: keyTwo),
    ]
    let context = TradesModeFoldTestSupport.makeContext(
      tradesIds: [accountId],
      instrumentMap: ["USD": usd],
      conversionService: conversion)
    let captured = InvestmentValueFailureLog()
    let handlers = TradesModeFoldTestSupport.makeHandlers { error, date in
      captured.append(error, date)
    }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [rowOne],
      to: &balances, context: context, handlers: handlers)

    // Day one dropped (failed conversion); day two retained
    // (cumulative position 10 USD * 1.5 = 15).
    #expect(balances[keyOne] == nil)
    let value = try #require(balances[keyTwo]?.investmentValue)
    let expected = try AnalysisTestHelpers.decimal("15")
    #expect(value.quantity == expected)
    let snapshot = captured.snapshot()
    #expect(snapshot.count == 1)
    #expect(snapshot.first?.1 == keyOne)
  }

  @Test("case 6: trades-fold failure on day D after snapshot-fold success drops day")
  func mixedFoldFailureDropsDay() async throws {
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayKey = Calendar.current.startOfDay(for: day)
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()
    let row = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: accountId, instrumentId: "USD", type: "trade", qty: 1_000_000_000)
    let conversion = FakeConversionService.dateRates([:], failingDates: [dayKey])
    // Pre-seed the day as if applyInvestmentValues had succeeded with
    // a recorded-value snapshot total of 100.
    var balances: [Date: DailyBalance] = [
      dayKey: TradesModeFoldTestSupport.preSeededDailyBalance(on: dayKey)
    ]
    let context = TradesModeFoldTestSupport.makeContext(
      tradesIds: [accountId],
      instrumentMap: ["USD": usd],
      conversionService: conversion)
    let captured = InvestmentValueFailureLog()
    let handlers = TradesModeFoldTestSupport.makeHandlers { error, date in
      captured.append(error, date)
    }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [row],
      to: &balances, context: context, handlers: handlers)

    #expect(balances[dayKey] == nil)
    let snapshot = captured.snapshot()
    #expect(snapshot.count == 1)
    #expect(snapshot.first?.1 == dayKey)
  }

  @Test("case 12: carry-forward across a dropped day stays correct")
  func carryForwardAcrossDroppedDay() async throws {
    let dayOne = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayTwo = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 11, hour: 12)
    let keyTwo = Calendar.current.startOfDay(for: dayTwo)
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()
    let rowOne = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: dayOne,
      accountId: accountId, instrumentId: "USD", type: "trade", qty: 1_000_000_000)
    let conversion = FakeConversionService.dateRates([
      try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 1, hour: 0): [
        "USD": try AnalysisTestHelpers.decimal("1.5")
      ]
    ])
    // Simulate a snapshot-fold dropout on day 1: dailyBalances has
    // entries only for day 2 (day 1 was removed by an earlier fold).
    var balances: [Date: DailyBalance] = [
      keyTwo: TradesModeFoldTestSupport.placeholderBalance(at: keyTwo)
    ]
    let context = TradesModeFoldTestSupport.makeContext(
      tradesIds: [accountId],
      instrumentMap: ["USD": usd],
      conversionService: conversion)
    let handlers = TradesModeFoldTestSupport.makeHandlers { _, _ in }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [rowOne],
      to: &balances, context: context, handlers: handlers)

    // Day 2 must valuate the cumulative position from day 1's buy
    // even though day 1 itself isn't in dailyBalances.
    let value = try #require(balances[keyTwo]?.investmentValue)
    let expected = try AnalysisTestHelpers.decimal("15")
    #expect(value.quantity == expected)
  }

  @Test("case 13: priorRows seed contributes to first in-window day")
  func priorRowsSeedSeenOnFirstWindowDay() async throws {
    // priorRows simulates pre-cutoff legs the user holds going into
    // the window. The fold's pre-fold seed (§4 step 2) must apply
    // them so the first in-window dayKey valuates the carried
    // position.
    let priorDay = try AnalysisTestHelpers.utcDate(year: 2025, month: 5, day: 1, hour: 12)
    let windowDay = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayKey = Calendar.current.startOfDay(for: windowDay)
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()
    let prior = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-05-01", sampleDate: priorDay,
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
      priorRows: [prior], postRows: [],
      to: &balances, context: context, handlers: handlers)

    // Pre-fold seed applied 1_000_000_000 storage units = 10 USD;
    // converted at 1.5 = 15 AUD on `dayKey`.
    let value = try #require(balances[dayKey]?.investmentValue)
    let expected = try AnalysisTestHelpers.decimal("15")
    #expect(value.quantity == expected)
  }

  @Test("case 14: end-to-end pipeline does not double-count trades-mode positions in netWorth")
  func endToEndNetWorthSingleCount() async throws {
    // Round-trip through the real fetchDailyBalances pipeline: a
    // trades-mode account with one trade leg on day D. After
    // walkDays, `existing.balance` would normally include the trade
    // position (because trades-mode accounts aren't in the
    // recorded-value `investmentAccountIds` set used by
    // PositionBook.dailyBalance). The fix in Task 6 step 3 unions
    // trades-mode ids into BalanceContext.investmentAccountIds so
    // those positions are excluded from balance and contribute only
    // via investmentValue. This test pins that fix.
    let conversion = FakeConversionService.dateRates([
      try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 1, hour: 0): [
        "USD": try AnalysisTestHelpers.decimal("1.5")
      ]
    ])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)
    let aud = Instrument.defaultTestInstrument
    let usd = Instrument.fiat(code: "USD")
    let tradesAccount = Account(
      id: UUID(), name: "Trades", type: .investment, instrument: aud,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(tradesAccount)

    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    _ = try await backend.transactions.create(
      Transaction(
        date: day, payee: "Buy",
        legs: [
          TransactionLeg(
            accountId: tradesAccount.id, instrument: usd,
            quantity: 10, type: .trade)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(
      after: nil, forecastUntil: nil)

    let dayKey = Calendar.current.startOfDay(for: day)
    let dayBalance = try #require(balances.first { $0.date == dayKey })

    // 10 USD * 1.5 = 15 AUD on day D. Critically:
    // - investmentValue == 15 AUD (from the new fold).
    // - balance == 0 AUD (the trades-mode account's USD position is
    //   excluded from bankTotal because it's now in
    //   BalanceContext.investmentAccountIds — the double-count fix).
    // - netWorth == 15 AUD (single count, not 30).
    let expected = try AnalysisTestHelpers.decimal("15")
    let value = try #require(dayBalance.investmentValue)
    #expect(value.quantity == expected)
    #expect(dayBalance.balance.quantity == 0)
    #expect(dayBalance.netWorth.quantity == expected)
  }

  @Test("CancellationError from Task.checkCancellation rethrows immediately")
  func cancellationRethrown() async throws {
    // All-fast-path scenario: a profile-instrument position means
    // `sumTradesModePositions` never `await`s, so without an explicit
    // `try Task.checkCancellation()` at the top of the per-day loop
    // the runtime would never get a chance to surface cancellation.
    // This test pins that the cancellation check is wired and rethrows
    // directly (Rule 11 contract: never via the failure callback).
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayKey = Calendar.current.startOfDay(for: day)
    let aud = Instrument.defaultTestInstrument
    let accountId = UUID()
    // Profile-instrument position — all-fast-path, no service calls.
    let row = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: accountId, instrumentId: aud.id, type: "trade",
      qty: 1_000_000_000)
    let task = Task {
      var balances: [Date: DailyBalance] = [
        dayKey: TradesModeFoldTestSupport.placeholderBalance(at: dayKey)
      ]
      let context = TradesModeFoldTestSupport.makeContext(
        tradesIds: [accountId],
        instrumentMap: [aud.id: aud],
        conversionService: FakeConversionService.dateRates([:]))
      let handlers = TradesModeFoldTestSupport.makeHandlers { _, _ in }
      try await GRDBAnalysisRepository.applyTradesModePositionValuations(
        priorRows: [], postRows: [row],
        to: &balances, context: context, handlers: handlers)
    }
    task.cancel()
    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }
}
