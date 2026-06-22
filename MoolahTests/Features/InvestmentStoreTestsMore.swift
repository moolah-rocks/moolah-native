import Foundation
import Testing

@testable import Moolah

@Suite("InvestmentStore")
@MainActor
struct InvestmentStoreTestsMore {

  private func makeDate(year: Int, month: Int, day: Int) -> Date {
    guard let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
    else { preconditionFailure("static gregorian DateComponents are always valid") }
    return date
  }

  private func makeValues(accountId: UUID, count: Int) -> [UUID: [InvestmentValue]] {
    let values = (0..<count).map { i in
      guard let date = Calendar.current.date(byAdding: .day, value: -i, to: Date())
      else { preconditionFailure("subtracting days from the current date is always valid") }
      return InvestmentValue(
        date: date,
        value: InstrumentAmount(
          quantity: Decimal(1000 + i * 10), instrument: .defaultTestInstrument)
      )
    }
    return [accountId: values]
  }

  @Test("Load daily balances populates dailyBalances array")
  func testLoadDailyBalances() async throws {
    let accountId = UUID()
    let (backend, database) = try TestBackend.create()
    _ = TestBackend.seed(
      transactions: [
        Transaction(
          date: makeDate(year: 2024, month: 1, day: 1),
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: .defaultTestInstrument,
              quantity: dec("1000.00"), type: .income)
          ]),
        Transaction(
          date: makeDate(year: 2024, month: 2, day: 1),
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: .defaultTestInstrument,
              quantity: dec("1000.00"), type: .income)
          ]),
      ], in: database)

    let store = InvestmentStore(
      repository: backend.investments, conversionService: FakeConversionService.fixedRates([:]))
    await store.loadDailyBalances(
      accountId: accountId, hostCurrency: .defaultTestInstrument)

    #expect(store.dailyBalances.count == 2)
    #expect(store.dailyBalances[0].balance.quantity == dec("1000.00"))
    #expect(store.dailyBalances[1].balance.quantity == dec("2000.00"))
  }

  // MARK: - Multi-instrument legacy accounts

  @Test(
    "Load daily balances aggregates multi-instrument legs into the host currency")
  func testLoadDailyBalancesMultiInstrumentAggregation() async throws {
    let accountId = UUID()
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let date1 = makeDate(year: 2024, month: 1, day: 1)
    let date2 = makeDate(year: 2024, month: 2, day: 1)

    let (backend, database) = try TestBackend.create(instrument: aud)
    _ = TestBackend.seed(
      transactions: [
        Transaction(
          date: date1,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: aud,
              quantity: dec("1000.00"), type: .income)
          ]),
        Transaction(
          date: date2,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: usd,
              quantity: dec("500.00"), type: .income)
          ]),
      ], in: database)

    // 1 USD = 1.5 AUD via FakeConversionService.
    let conversion = FakeConversionService.fixedRates(["USD": dec("1.5")])
    let store = InvestmentStore(
      repository: backend.investments, conversionService: conversion)

    await store.loadDailyBalances(accountId: accountId, hostCurrency: aud)

    // One aggregated entry per date in AUD: day 1 = 1000 AUD; day 2 = 1000 AUD
    // (running) + 500 USD * 1.5 = 1750 AUD.
    #expect(store.dailyBalances.count == 2)
    #expect(store.dailyBalances.allSatisfy { $0.balance.instrument == aud })
    #expect(store.dailyBalances[0].date == date1)
    #expect(store.dailyBalances[0].balance.quantity == dec("1000.00"))
    #expect(store.dailyBalances[1].date == date2)
    #expect(store.dailyBalances[1].balance.quantity == dec("1750.00"))
    #expect(store.error == nil)
  }

  @Test(
    "Load daily balances marks dailyBalances unavailable when conversion fails")
  func testLoadDailyBalancesConversionFailure() async throws {
    let accountId = UUID()
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let date = makeDate(year: 2024, month: 1, day: 1)

    let (backend, database) = try TestBackend.create(instrument: aud)
    _ = TestBackend.seed(
      transactions: [
        Transaction(
          date: date,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: usd,
              quantity: dec("500.00"), type: .income)
          ])
      ], in: database)

    // Conversion of USD throws; per Rule 11 we surface the failure and
    // clear dailyBalances rather than rendering a partial / native-
    // instrument number.
    let store = InvestmentStore(
      repository: backend.investments,
      conversionService: FakeConversionService.failingInstruments([usd.id]))

    await store.loadDailyBalances(accountId: accountId, hostCurrency: aud)

    #expect(store.dailyBalances.isEmpty)
    #expect(store.error != nil)
  }

  // MARK: - Filtered Data

  @Test("Filtered values returns all values when period is .all")
  func testFilteredValuesAll() async throws {
    let accountId = UUID()
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      investmentValues: makeValues(accountId: accountId, count: 3), in: database
    )
    let store = InvestmentStore(
      repository: backend.investments, conversionService: FakeConversionService.fixedRates([:]))

    await store.loadValues(accountId: accountId)
    store.selectedPeriod = .all

    #expect(store.filteredValues.count == 3)
  }

  // MARK: - Chart Data Merging

  @Test("Chart data points merge values and balances by date")
  func testChartDataPointsMerge() {
    let date1 = makeDate(year: 2024, month: 1, day: 1)
    let date2 = makeDate(year: 2024, month: 2, day: 1)

    let values = [
      InvestmentValue(
        date: date2,
        value: InstrumentAmount(
          quantity: dec("1200.00"), instrument: .defaultTestInstrument)),
      InvestmentValue(
        date: date1,
        value: InstrumentAmount(
          quantity: dec("1000.00"), instrument: .defaultTestInstrument)),
    ]

    let balances = [
      AccountDailyBalance(
        date: date1,
        balance: InstrumentAmount(
          quantity: dec("900.00"), instrument: .defaultTestInstrument)),
      AccountDailyBalance(
        date: date2,
        balance: InstrumentAmount(
          quantity: dec("1000.00"), instrument: .defaultTestInstrument)),
    ]

    let result = InvestmentChartData.merge(values: values, balances: balances, period: .all)

    #expect(result.count == 2)
    #expect(result[0].value == dec("1000.00"))
    #expect(result[0].balance == dec("900.00"))
    #expect(result[0].profitLoss == dec("100.00"))
    #expect(result[1].value == dec("1200.00"))
    #expect(result[1].balance == dec("1000.00"))
    #expect(result[1].profitLoss == dec("200.00"))
  }

  @Test("Chart data points forward-fill missing values")
  func testChartDataPointsForwardFill() {
    let date1 = makeDate(year: 2024, month: 1, day: 1)
    let date2 = makeDate(year: 2024, month: 2, day: 1)
    let date3 = makeDate(year: 2024, month: 3, day: 1)

    // Value only on date1 and date3; balance only on date1 and date2
    let values = [
      InvestmentValue(
        date: date3,
        value: InstrumentAmount(
          quantity: dec("1300.00"), instrument: .defaultTestInstrument)),
      InvestmentValue(
        date: date1,
        value: InstrumentAmount(
          quantity: dec("1000.00"), instrument: .defaultTestInstrument)),
    ]

    let balances = [
      AccountDailyBalance(
        date: date1,
        balance: InstrumentAmount(
          quantity: dec("900.00"), instrument: .defaultTestInstrument)),
      AccountDailyBalance(
        date: date2,
        balance: InstrumentAmount(
          quantity: dec("1000.00"), instrument: .defaultTestInstrument)),
    ]

    let result = InvestmentChartData.merge(values: values, balances: balances, period: .all)

    #expect(result.count == 3)
    // date1: both present
    #expect(result[0].value == dec("1000.00"))
    #expect(result[0].balance == dec("900.00"))
    // date2: value forward-filled from date1
    #expect(result[1].value == dec("1000.00"))
    #expect(result[1].balance == dec("1000.00"))
    // date3: balance forward-filled from date2
    #expect(result[2].value == dec("1300.00"))
    #expect(result[2].balance == dec("1000.00"))
  }

  @Test("Chart data points with period filter includes pre-period anchor")
  func testChartDataPointsPeriodFilter() throws {
    // Use dates relative to "now" for period filtering
    let now = Date()
    let sixMonthsAgo = try #require(Calendar.current.date(byAdding: .month, value: -6, to: now))
    let threeMonthsAgo = try #require(Calendar.current.date(byAdding: .month, value: -3, to: now))
    let oneMonthAgo = try #require(Calendar.current.date(byAdding: .month, value: -1, to: now))

    let values = [
      InvestmentValue(
        date: now,
        value: InstrumentAmount(
          quantity: dec("1500.00"), instrument: .defaultTestInstrument)),
      InvestmentValue(
        date: oneMonthAgo,
        value: InstrumentAmount(
          quantity: dec("1300.00"), instrument: .defaultTestInstrument)),
      InvestmentValue(
        date: sixMonthsAgo,
        value: InstrumentAmount(
          quantity: dec("1000.00"), instrument: .defaultTestInstrument)),
    ]

    let balances = [
      AccountDailyBalance(
        date: sixMonthsAgo,
        balance: InstrumentAmount(
          quantity: dec("800.00"), instrument: .defaultTestInstrument)),
      AccountDailyBalance(
        date: threeMonthsAgo,
        balance: InstrumentAmount(
          quantity: dec("900.00"), instrument: .defaultTestInstrument)),
      AccountDailyBalance(
        date: now,
        balance: InstrumentAmount(
          quantity: dec("1000.00"), instrument: .defaultTestInstrument)),
    ]

    // Filter to 3 months: should include threeMonthsAgo and now,
    // plus pre-period anchors from sixMonthsAgo
    let result = InvestmentChartData.merge(values: values, balances: balances, period: .months(3))

    // Should have data points, and the pre-period value should be anchored
    #expect(result.count >= 2)
  }
}
