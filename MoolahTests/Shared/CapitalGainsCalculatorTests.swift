import Foundation
import Testing

@testable import Moolah

@Suite("CapitalGainsCalculator")
struct CapitalGainsCalculatorTests {
  let aud = Instrument.fiat(code: "AUD")

  private func stockInstrument(_ name: String) -> Instrument {
    Instrument.stock(ticker: "\(name).AX", exchange: "ASX", name: name)
  }

  private func cryptoInstrument(_ symbol: String) -> Instrument {
    Instrument(
      id: "1:\(symbol.lowercased())", kind: .cryptoToken, name: symbol, decimals: 8,
      ticker: nil, exchange: nil, chainId: 1, contractAddress: nil)
  }

  private func date(_ daysFromBase: Int) -> Date {
    let calendar = Calendar(identifier: .gregorian)
    guard
      let base = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)),
      let result = calendar.date(byAdding: .day, value: daysFromBase, to: base)
    else {
      fatalError("Could not construct date \(daysFromBase) days from 2024-01-01")
    }
    return result
  }

  @Test
  func stockPurchase_thenSale_producesGainEvent() async throws {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    // Buy: transfer AUD out, BHP in
    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    // Sell: BHP out, AUD in
    let sellTx = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 5000, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:])
    )

    #expect(result.events.count == 1)
    #expect(result.events[0].gain == 1000)
    #expect(result.events[0].isLongTerm == true)
    #expect(result.totalRealizedGain == 1000)
  }

  @Test
  func noSales_noGainEvents() async throws {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx],
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:])
    )

    #expect(result.events.isEmpty)
    #expect(result.openLots.count == 1)
    #expect(result.openLots[0].remainingQuantity == 100)
  }

  @Test
  func cryptoSwap_tracksGainOnSoldToken() async throws {
    let eth = cryptoInstrument("ETH")
    let uni = cryptoInstrument("UNI")
    let accountId = UUID()

    // Buy ETH with AUD
    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -3000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: eth, quantity: 1, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    // Swap ETH for UNI
    let swapTx = LegTransaction(
      date: date(200),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: eth, quantity: -1, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: uni, quantity: 500, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let service = FakeConversionService.fixedRates([eth.id: 4000, uni.id: 8])
    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, swapTx],
      profileCurrency: aud,
      conversionService: service
    )

    // ETH sold: cost basis 3000, proceeds 4000 (1 ETH at AUD 4000 on swap date)
    #expect(result.events.count == 1)
    #expect(result.events[0].instrument.id == eth.id)
    #expect(result.events[0].gain == 1000)
  }

  @Test
  func financialYearFilter_onlyIncludesEventsInRange() async throws {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let sellTx = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 5000, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let allResult = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:])
    )
    #expect(allResult.events.count == 1)

    let earlyResult = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      sellDateRange: date(0)...date(100)
    )
    // Sale on day 400 is outside the range
    #expect(earlyResult.events.isEmpty)
  }

  // MARK: - Multi-instrument scenarios

  @Test
  func multipleStocks_produceIndependentGainEvents() async throws {
    let bhp = stockInstrument("BHP")
    let cba = stockInstrument("CBA")
    let accountId = UUID()

    let buyBHP = buyTrade(on: 0, cash: -4000, qty: 100, of: bhp, accountId: accountId)
    let sellBHP = sellTrade(on: 400, qty: -100, of: bhp, proceeds: 5000, accountId: accountId)
    let buyCBA = buyTrade(on: 50, cash: -5000, qty: 50, of: cba, accountId: accountId)
    let sellCBA = sellTrade(on: 500, qty: -50, of: cba, proceeds: 7000, accountId: accountId)

    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyBHP, buyCBA, sellBHP, sellCBA],
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:])
    )

    #expect(result.events.count == 2)
    let bhpGain = result.events.first { $0.instrument.id == "ASX:BHP.AX" }?.gain
    let cbaGain = result.events.first { $0.instrument.id == "ASX:CBA.AX" }?.gain
    #expect(bhpGain == 1000)
    #expect(cbaGain == 2000)
    #expect(result.totalRealizedGain == 3000)
  }

  /// Helper: buy `qty` of `instrument` on day `day`, funded by `cash` (negative)
  /// from `accountId`.
  private func buyTrade(
    on day: Int, cash: Decimal, qty: Decimal, of instrument: Instrument, accountId: UUID
  ) -> LegTransaction {
    LegTransaction(
      date: date(day),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: cash, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: instrument, quantity: qty, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])
  }

  /// Helper: sell `qty` (negative) of `instrument` on day `day`, receiving
  /// `proceeds` (positive) into `accountId`.
  private func sellTrade(
    on day: Int, qty: Decimal, of instrument: Instrument, proceeds: Decimal, accountId: UUID
  ) -> LegTransaction {
    LegTransaction(
      date: date(day),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: instrument, quantity: qty, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: proceeds, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])
  }

  // MARK: - Date-sensitive conversion regression guard

  /// Pins the contract that `computeWithConversion` looks up FX rates at
  /// each transaction's date — not at `Date()`. Uses
  /// `FakeConversionService.dateRates` with two rate entries straddling
  /// the buy and sell dates so a wrong-date regression (e.g. passing
  /// `Date()` instead of `transaction.date` into `TradeEventClassifier`)
  /// converts both legs at the same rate and produces a zero gain — the
  /// assertion below fails. Mirrors the `TradeEventClassifierTests.buyFoldsFXFee`
  /// pattern, extended end-to-end through the calculator.
  @Test
  func usdBuyAudSell_usesTradeDateForFXLookup() async throws {
    let usd = Instrument.fiat(code: "USD")
    let bhp = stockInstrument("BHP")
    let accountId = UUID()
    let buyDate = date(0)
    let sellDate = date(400)

    // 1.5 AUD/USD at buy, 2.0 AUD/USD at sell. Different rates ⇒ a real
    // (non-zero) gain only when each leg converts at its own date.
    let conversion = FakeConversionService.dateRates([
      buyDate: ["USD": dec("1.5")],
      sellDate: ["USD": Decimal(2)],
    ])

    let buyTx = LegTransaction(
      date: buyDate,
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: -1_500, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])
    let sellTx = LegTransaction(
      date: sellDate,
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: 1_500, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: conversion)

    // Cost basis: 1500 USD * 1.5 = 2250 AUD ⇒ 22.5 AUD/unit
    // Proceeds:   1500 USD * 2.0 = 3000 AUD ⇒ 30 AUD/unit
    // Gain on 100 units = (30 - 22.5) * 100 = 750 AUD
    #expect(result.events.count == 1)
    #expect(result.events[0].gain == Decimal(750))
  }
}
