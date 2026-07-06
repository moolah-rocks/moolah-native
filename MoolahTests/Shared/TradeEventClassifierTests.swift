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
  let spam = Instrument.crypto(
    chainId: 1, contractAddress: "0xSpam", symbol: "SPAM", name: "Spam", decimals: 18)
  let spam2 = Instrument.crypto(
    chainId: 1, contractAddress: "0xSpam2", symbol: "SPAM2", name: "Spam Two", decimals: 18)
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
    // `callCount` counts only conversions that reach the rate outcome
    // closure (same-instrument requests fast-path before it). Both the AUD
    // pair leg and the AUD fee leg are host currency, so `hostValue`
    // fast-paths both and neither touches rate logic — `callCount` stays 0.
    // (Migrated from the old `recordedCalls`-based proxy: the pair leg now
    // resolves via `convertResult`, whose same-instrument fast path returns
    // before recording, so a host-currency trade records nothing.)
    let service = FakeConversionService.passthrough
    let legs = [tradeLeg(aud, -4_000), tradeLeg(bhp, 100), feeLeg(aud, -10)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud, conversionService: service)
    try #require(result.buys.count == 1)
    #expect(result.buys[0].costPerUnit == Decimal(40) + Decimal(10) / Decimal(100))
    #expect(service.callCount == 0)
  }

  // MARK: - ATO fallback valuation for unpriced / spam trade legs (#1255)

  @Test("swap: dispose spam / acquire ETH values both legs from the ETH side")
  func spamForEth_valuesFromEthSide() async throws {
    // Dispose 100 SPAM (unpriceable) for 1 ETH @ 3000 AUD. The ETH buy's
    // paired price-carrier (SPAM) is `.knownZero`, so it falls back to ETH's
    // own value; the SPAM sell's paired carrier (ETH) prices directly. Both
    // ride the ETH value — no throw.
    let service = FakeConversionService.fixedRates(
      [eth.id: 3_000], knownZero: [spam.id])
    let legs = [tradeLeg(spam, -100), tradeLeg(eth, 1)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud, conversionService: service)
    try #require(result.buys.count == 1)
    #expect(result.buys[0].instrument == eth)
    #expect(result.buys[0].costPerUnit == Decimal(3_000))  // ETH's own value
    try #require(result.sells.count == 1)
    #expect(result.sells[0].instrument == spam)
    #expect(result.sells[0].quantity == 100)
    // 3000 AUD of ETH received / 100 SPAM given up = 30 AUD per SPAM.
    #expect(result.sells[0].proceedsPerUnit == Decimal(30))
  }

  @Test("swap: dispose ETH / acquire spam falls back to ETH's own value")
  func ethForSpam_fallsBackToEthOwnValue() async throws {
    // Dispose 1 ETH @ 3000 for 100 SPAM (unpriceable). The ETH sell's paired
    // price-carrier is SPAM → `.knownZero`, so its proceeds fall back to
    // ETH's OWN market value (3000), NOT a 0-valued ETH and NOT a throw. The
    // SPAM buy's cost = the ETH value given up.
    let service = FakeConversionService.fixedRates(
      [eth.id: 3_000], knownZero: [spam.id])
    let legs = [tradeLeg(eth, -1), tradeLeg(spam, 100)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud, conversionService: service)
    try #require(result.sells.count == 1)
    #expect(result.sells[0].instrument == eth)
    #expect(result.sells[0].proceedsPerUnit == Decimal(3_000))  // ETH's own value
    try #require(result.buys.count == 1)
    #expect(result.buys[0].instrument == spam)
    // 3000 AUD of ETH given up / 100 SPAM received = 30 AUD per SPAM.
    #expect(result.buys[0].costPerUnit == Decimal(30))
  }

  @Test("spam fee on a real ETH/AUD trade contributes 0 and the trade still values")
  func spamFeeContributesZero_tradeStillValued() async throws {
    // Buy 1 ETH for 4000 AUD with a spam-token gas fee attached. A worthless
    // `.knownZero` fee token is a 0 incidental cost, so the ETH cost stays at
    // its raw 4000 with no fee fold-in.
    let service = FakeConversionService.fixedRates(
      [eth.id: 4_000], knownZero: [spam.id])
    let legs = [tradeLeg(aud, -4_000), tradeLeg(eth, 1), feeLeg(spam, dec("-0.5"))]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud, conversionService: service)
    try #require(result.buys.count == 1)
    #expect(result.buys[0].instrument == eth)
    #expect(result.buys[0].costPerUnit == Decimal(4_000))
    #expect(result.sells.isEmpty)
  }

  @Test("swap: both legs unpriced is genuinely unavailable and throws")
  func bothLegsUnpriced_throws() async throws {
    let service = FakeConversionService.fixedRates(
      [:], knownZero: [spam.id, spam2.id])
    let legs = [tradeLeg(spam, -100), tradeLeg(spam2, 50)]
    await #expect(throws: (any Error).self) {
      try await TradeEventClassifier.classify(
        legs: legs, on: date, hostCurrency: aud, conversionService: service)
    }
  }
}
