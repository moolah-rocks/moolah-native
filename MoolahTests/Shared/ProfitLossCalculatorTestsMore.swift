import Foundation
import Testing

@testable import Moolah

@Suite("ProfitLossCalculator — Part 2")
struct ProfitLossCalculatorTestsMore {
  let aud = Instrument.fiat(code: "AUD")

  @Test
  func multipleStocks_eachGetsOwnRow() async throws {
    let bhp = stockInstrument("BHP")
    let cba = stockInstrument("CBA")
    let accountId = UUID()

    let buyBHP = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])
    let buyCBA = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -5000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: cba, quantity: 50, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    // BHP $50/share (100 * 50 = 5000). CBA $120/share (50 * 120 = 6000).
    let service = FakeConversionService.fixedRates(["ASX:BHP.AX": 50, "ASX:CBA.AX": 120])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyBHP, buyCBA],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(365)
    )

    #expect(results.count == 2)
    let bhpPL = results.first { $0.instrument.id == "ASX:BHP.AX" }
    let cbaPL = results.first { $0.instrument.id == "ASX:CBA.AX" }
    #expect(bhpPL?.unrealizedGain == 1000)
    #expect(cbaPL?.unrealizedGain == 1000)
  }

  @Test
  func portfolioMixesStockAndCrypto() async throws {
    let bhp = stockInstrument("BHP")
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let accountId = UUID()

    let buyBHP = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])
    let buyETH = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -2000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: eth,
          quantity: dec("1.0"), type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let service = FakeConversionService.fixedRates(["ASX:BHP.AX": 50, eth.id: 2500])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyBHP, buyETH],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(365)
    )

    #expect(results.count == 2)
    let kinds = Set(results.map { $0.instrument.kind })
    #expect(kinds == [.stock, .cryptoToken])
    // Each row is independent; gains aggregate separately.
    let bhpPL = results.first { $0.instrument.kind == .stock }
    let ethPL = results.first { $0.instrument.kind == .cryptoToken }
    #expect(bhpPL?.unrealizedGain == 1000)
    #expect(ethPL?.unrealizedGain == 500)
  }

  /// A multi-currency purchase (USD 2000 + AUD 100 brokerage fee) where
  /// the fee is modelled as an `.expense` leg. The classifier converts
  /// the USD trade leg to AUD on the trade date and folds the AUD 100
  /// fee in via the host-currency fast path, giving total invested =
  /// AUD 3100.
  @Test
  func mixedFiatLegs_totalInvestedConvertsEachLegToProfileCurrency() async throws {
    let bhp = stockInstrument("BHP")
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: -2000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -100, type: .expense,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    // 1 USD = 1.5 AUD, BHP now worth AUD 50/share.
    let service = FakeConversionService.fixedRates([
      "USD": dec("1.5"),
      "ASX:BHP.AX": 50,
    ])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyTx],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(365)
    )

    #expect(results.count == 1)
    // totalInvested: USD 2000×1.5 + AUD 100 fee = AUD 3100.
    // currentValue: 100 × AUD 50 = AUD 5000.
    // unrealizedGain: 5000 − 3100 = 1900.
    #expect(results[0].totalInvested == 3100)
    #expect(results[0].currentValue == 5000)
    #expect(results[0].unrealizedGain == 1900)
  }

  // MARK: - Date-sensitive routing
  //
  // These tests use `DateBasedFixedConversionService` to verify that
  // `compute` routes its two conversion calls to the correct dates:
  // historic cost basis (`transaction.date`, Rule 5) and current valuation
  // (`asOfDate`, Rule 6). The rate-ignoring `FixedConversionService`
  // would pass even if production code swapped the dates.

  /// Cost basis must convert each fiat outflow leg on `transaction.date` while
  /// `currentValue` must convert the open position on `asOfDate`. The
  /// rate schedule below makes both choices observable: swapping the
  /// dates would yield different totals.
  @Test
  func datesRouteCorrectly_costBasisOnTxDate_currentValueOnAsOfDate() async throws {
    let bhp = stockInstrument("BHP")
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: -2000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    // date(0):   USD→AUD 1.5,  BHP→AUD 30   (cost basis must use these)
    // date(365): USD→AUD 2.0,  BHP→AUD 50   (current valuation must use these)
    //
    // Correct routing: totalInvested = 2000 × 1.5 = 3000; currentValue = 100 × 50 = 5000.
    // If dates were swapped: totalInvested = 2000 × 2.0 = 4000; currentValue = 100 × 30 = 3000.
    let service = FakeConversionService.dateRates([
      date(0): ["USD": dec("1.5"), "ASX:BHP.AX": 30],
      date(365): ["USD": dec("2.0"), "ASX:BHP.AX": 50],
    ])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyTx],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(365)
    )

    #expect(results.count == 1)
    let result = results[0]
    #expect(result.totalInvested == 3000)
    #expect(result.currentValue == 5000)
    #expect(result.unrealizedGain == 2000)
  }

  /// Buy with an attached AUD fee leg: `totalInvested` must include the
  /// fee, otherwise it diverges from the FIFO `remainingCostBasis` and
  /// `returnPercentage` over-states returns.
  @Test
  func buyWithHostCurrencyFeeIncreasesTotalInvested() async throws {
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
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -10, type: .expense,
          categoryId: nil, earmarkId: nil),
      ])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyTx],
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      asOfDate: date(0)
    )
    try #require(results.count == 1)
    #expect(results[0].totalInvested == 4010)
  }

  /// FX fee leg on a buy: `accumulateInvested` must convert the fee on
  /// `transaction.date`, not `Date()`. Two rate entries straddle the
  /// trade date so a wrong-date implementation picks the 2.0 rate at
  /// `nextDay` and the assertion fails (wall-clock today > `nextDay`
  /// because the `date(_)` helper bases on 2024-01-01).
  @Test
  func buyWithFXFeeConvertsAtTransactionDate() async throws {
    let bhp = stockInstrument("BHP")
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()
    let tradeDate = date(0)
    let nextDay = date(1)
    let service = FakeConversionService.dateRates([
      tradeDate: ["USD": dec("1.5")],
      nextDay: ["USD": Decimal(2)],
    ])
    let buyTx = LegTransaction(
      date: tradeDate,
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: -10, type: .expense,
          categoryId: nil, earmarkId: nil),
      ])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyTx],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: nextDay
    )
    try #require(results.count == 1)
    // -10 USD * 1.5 = -15 AUD fee → +15 cost contribution. 4000 + 15 = 4015.
    #expect(results[0].totalInvested == 4015)
  }

  // MARK: - Helpers

  private func stockInstrument(_ name: String) -> Instrument {
    Instrument.stock(ticker: "\(name).AX", exchange: "ASX", name: name)
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
}
