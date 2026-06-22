import Foundation
import Testing

@testable import Moolah

@Suite("TradeEventClassifier")
struct TradeEventClassifierTests {
  let aud = Instrument.AUD
  let usd = Instrument.USD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let btc = Instrument.crypto(
    chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
  // November 2023. Past-date precondition for `buyFoldsFXFee` — that test
  // straddles `date` and `date + 1 day` with two FX rates and relies on
  // wall-clock `Date()` being later than `date + 1 day` so a buggy
  // `Date()`-instead-of-`date` implementation picks the wrong rate.
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  let account = UUID()

  private func tradeLeg(_ instr: Instrument, _ qty: Decimal) -> TransactionLeg {
    TransactionLeg(accountId: account, instrument: instr, quantity: qty, type: .trade)
  }

  private func feeLeg(_ instr: Instrument, _ qty: Decimal) -> TransactionLeg {
    TransactionLeg(accountId: account, instrument: instr, quantity: qty, type: .expense)
  }

  @Test("buy: positive trade leg + negative trade leg")
  func buy() async throws {
    let legs = [tradeLeg(aud, -4_000), tradeLeg(bhp, 100)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]))
    #expect(result.buys.count == 1)
    #expect(result.buys[0].instrument == bhp)
    #expect(result.buys[0].quantity == 100)
    #expect(result.buys[0].costPerUnit == 40)
    #expect(result.sells.isEmpty)
  }

  @Test("sell: positive fiat + negative non-fiat")
  func sell() async throws {
    let legs = [tradeLeg(aud, 2_500), tradeLeg(bhp, -50)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]))
    #expect(result.sells.count == 1)
    #expect(result.sells[0].instrument == bhp)
    #expect(result.sells[0].quantity == 50)
    #expect(result.sells[0].proceedsPerUnit == 50)
  }

  @Test("non-fiat swap is priced via host-currency conversion")
  func swap() async throws {
    let legs = [tradeLeg(eth, -2), tradeLeg(btc, 0.1)]
    let service = FakeConversionService.fixedRates([
      eth.id: Decimal(3_000),
      btc.id: Decimal(60_000),
    ])
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud, conversionService: service)
    #expect(result.buys.count == 1)
    #expect(result.buys[0].instrument == btc)
    #expect(result.buys[0].quantity == Decimal(string: "0.1"))
    #expect(result.buys[0].costPerUnit == Decimal(60_000))
    #expect(result.sells.count == 1)
    #expect(result.sells[0].instrument == eth)
    #expect(result.sells[0].quantity == 2)
    #expect(result.sells[0].proceedsPerUnit == Decimal(3_000))
  }

  @Test("non-trade-typed legs are ignored entirely (older custom shapes)")
  func nonTradeLegsIgnored() async throws {
    let legs = [
      TransactionLeg(
        accountId: account, instrument: aud,
        quantity: -4_000, type: .expense),
      TransactionLeg(
        accountId: account, instrument: bhp,
        quantity: 100, type: .income),
    ]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]))
    #expect(result.buys.isEmpty)
    #expect(result.sells.isEmpty)
  }

  @Test("zero-quantity trade leg is skipped (no divide-by-zero)")
  func zeroQuantityTradeLeg() async throws {
    let legs = [tradeLeg(aud, -4_000), tradeLeg(bhp, 0)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]))
    #expect(result.buys.isEmpty)
    #expect(result.sells.isEmpty)
  }

  @Test("fewer than two .trade legs returns empty")
  func fewerThanTwo() async throws {
    let result = try await TradeEventClassifier.classify(
      legs: [tradeLeg(aud, -100)], on: date, hostCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]))
    #expect(result.buys.isEmpty)
    #expect(result.sells.isEmpty)
  }

  // MARK: - Fee folding

  @Test("buy: AUD fee on AUD-host trade folds into per-unit cost")
  func buyFoldsAUDFee() async throws {
    let legs = [tradeLeg(aud, -4_000), tradeLeg(bhp, 100), feeLeg(aud, -10)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]))
    try #require(result.buys.count == 1)
    #expect(result.buys[0].costPerUnit == Decimal(40) + Decimal(10) / Decimal(100))
    #expect(result.sells.isEmpty)
  }

  @Test("sell: fee reduces per-unit proceeds")
  func sellReducesProceedsByFee() async throws {
    let legs = [tradeLeg(aud, 2_500), tradeLeg(bhp, -50), feeLeg(aud, -10)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]))
    try #require(result.sells.count == 1)
    #expect(result.sells[0].proceedsPerUnit == Decimal(50) - Decimal(10) / Decimal(50))
    #expect(result.buys.isEmpty)
  }

  @Test("buy: multiple AUD fee legs sum")
  func buyFoldsMultipleFees() async throws {
    let legs = [
      tradeLeg(aud, -4_000), tradeLeg(bhp, 100),
      feeLeg(aud, -10), feeLeg(aud, -3),
    ]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]))
    try #require(result.buys.count == 1)
    #expect(result.buys[0].costPerUnit == Decimal(40) + Decimal(13) / Decimal(100))
  }

  @Test("buy: fee debit and equal refund credit cancel to zero")
  func feeContributionsCancelToZero() async throws {
    let legs = [
      tradeLeg(aud, -4_000), tradeLeg(bhp, 100),
      feeLeg(aud, -10), feeLeg(aud, 10),
    ]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]))
    try #require(result.buys.count == 1)
    #expect(result.buys[0].costPerUnit == Decimal(40))
  }

  @Test("buy: FX fee converts at the trade date")
  func buyFoldsFXFee() async throws {
    // Two rate entries straddling the trade date. If the implementation
    // accidentally passes Date() instead of `date`, the lookup picks the
    // 2.0 rate and the assertion below fails — making the wrong-date bug
    // detectable rather than silent. (Wall-clock Date() at test-run time
    // > nextDay because `date` is a past fixture; see comment above.)
    let nextDay = date.addingTimeInterval(86_400)
    let service = FakeConversionService.dateRates([
      date: [usd.id: dec("1.5")],
      nextDay: [usd.id: Decimal(2)],
    ])
    let legs = [tradeLeg(aud, -4_000), tradeLeg(bhp, 100), feeLeg(usd, -5)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud, conversionService: service)
    try #require(result.buys.count == 1)
    // -5 USD * 1.5 = -7.5 AUD; negate → +7.5; / 100 BHP → 0.075 per unit.
    #expect(
      result.buys[0].costPerUnit
        == Decimal(40) + dec("7.5") / Decimal(100))
  }

  @Test("swap: fee splits evenly across both capital events")
  func swapSplitsFeeEvenlyAcrossEvents() async throws {
    let service = FakeConversionService.fixedRates([
      eth.id: Decimal(3_000),
      btc.id: Decimal(60_000),
    ])
    let legs = [
      tradeLeg(eth, -2),
      tradeLeg(btc, dec("0.1")),
      feeLeg(aud, -50),
    ]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud, conversionService: service)
    try #require(result.buys.count == 1)
    try #require(result.sells.count == 1)
    // 50 / 2 events = 25 AUD per event.
    #expect(result.buys[0].instrument == btc)
    #expect(
      result.buys[0].costPerUnit
        == Decimal(60_000) + Decimal(25) / dec("0.1"))
    #expect(result.sells[0].instrument == eth)
    #expect(
      result.sells[0].proceedsPerUnit
        == Decimal(3_000) - Decimal(25) / Decimal(2))
  }

  @Test("buy: host-currency fee skips the conversion service")
  func hostCurrencyFeeNeedsNoConversionLookup() async throws {
    // FakeConversionService records every convert() call that reaches its
    // outcome closure. The pair-leg conversion (AUD→AUD, for the BHP
    // capital leg) goes through the service — the classifier does not
    // fast-path the *pair* leg today — so the recorder sees that one
    // call. The fee leg (also AUD on AUD-host) MUST be fast-pathed inside
    // the classifier so the recorder sees exactly one call total. If the
    // fast path is missing, the recorder sees two calls and `count == 1`
    // catches it.
    let service = FakeConversionService.passthrough
    let legs = [tradeLeg(aud, -4_000), tradeLeg(bhp, 100), feeLeg(aud, -10)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud, conversionService: service)
    try #require(result.buys.count == 1)
    #expect(result.buys[0].costPerUnit == Decimal(40) + Decimal(10) / Decimal(100))
    // passthrough returns input unchanged (1:1), so the
    // pair-leg conversion still produces -4 000.
    #expect(service.recordedCalls.count == 1)
    #expect(service.recordedCalls.first?.quantity == -4_000)
  }
}
