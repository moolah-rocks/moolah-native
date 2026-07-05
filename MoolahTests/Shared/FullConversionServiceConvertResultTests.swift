import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("FullConversionService.convertResult")
struct FullConversionServiceConvertResultTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let usd = Instrument.USD
  private let aud = Instrument.AUD

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  private struct Bundle {
    let service: FullConversionService
  }

  /// Build a service whose `CryptoPriceService` resolves the supplied
  /// registrations via its keyed `metadataLookup` plug — carrying
  /// `pricingStatus` per registration so `convertResult` can dispatch
  /// `.priced` / `.knownZero` correctly.
  private func makeService(
    cryptoPrices: [String: [String: Decimal]] = [:],
    exchangeRates: [String: [String: Decimal]] = [:],
    shouldFail: Bool = false,
    registrations: [CryptoRegistration] = []
  ) throws -> Bundle {
    let database = try ProfileIndexDatabase.openInMemory()
    let registrationsById = Dictionary(
      uniqueKeysWithValues: registrations.map { ($0.id, $0) })
    let cryptoService = CryptoPriceService(
      clients: [FixedCryptoPriceClient(prices: cryptoPrices, shouldFail: shouldFail)],
      database: database,
      metadataLookup: { registrationsById[$0] }
    )
    let exchangeService = ExchangeRateService(
      client: FixedRateClient(rates: exchangeRates),
      database: database
    )
    let stockService = StockPriceService(client: FixedStockPriceClient(), database: database)
    let service = FullConversionService(
      exchangeRates: exchangeService,
      stockPrices: stockService,
      cryptoPrices: cryptoService
    )
    return Bundle(service: service)
  }

  private func ethRegistration(status: TokenPricingStatus) -> CryptoRegistration {
    CryptoRegistration(
      instrument: eth,
      mapping: CryptoProviderMapping(
        instrumentId: "1:native", coingeckoId: "ethereum",
        binanceSymbol: "ETHUSDT"
      ),
      pricingStatus: status
    )
  }

  // MARK: - .priced source -> .value

  @Test
  func pricedCryptoSourceProducesValue() async throws {
    let bundle = try makeService(
      cryptoPrices: ["1:native": ["2026-04-10": dec("1623.45")]],
      registrations: [ethRegistration(status: .priced)]
    )
    let amount = InstrumentAmount(quantity: dec("2.5"), instrument: eth)

    let result = try await bundle.service.convertResult(
      amount, to: usd, on: try date("2026-04-10"))

    #expect(
      result == .value(InstrumentAmount(quantity: dec("2.5") * dec("1623.45"), instrument: usd)))
  }

  // MARK: - .unpriced source -> .knownZero(target)

  /// `.unpriced` must short-circuit to `.knownZero(targetInstrument: to)`
  /// without consulting the underlying price provider — `shouldFail =
  /// true` would throw if the call reached the client.
  @Test
  func unpricedCryptoSourceProducesKnownZeroAndSkipsProvider() async throws {
    let bundle = try makeService(
      cryptoPrices: [:],
      shouldFail: true,
      registrations: [ethRegistration(status: .unpriced)]
    )
    let amount = InstrumentAmount(quantity: dec("2.5"), instrument: eth)

    let result = try await bundle.service.convertResult(
      amount, to: usd, on: try date("2026-04-10"))

    #expect(result == .knownZero(targetInstrument: usd))
  }

  // MARK: - .spam source -> .knownZero(target)

  @Test
  func spamCryptoSourceProducesKnownZeroAndSkipsProvider() async throws {
    let bundle = try makeService(
      cryptoPrices: [:],
      shouldFail: true,
      registrations: [ethRegistration(status: .spam)]
    )
    let amount = InstrumentAmount(quantity: dec("100"), instrument: eth)

    let result = try await bundle.service.convertResult(
      amount, to: aud, on: try date("2026-04-10"))

    #expect(result == .knownZero(targetInstrument: aud))
  }

  // MARK: - .priced source, provider fails -> throws (never .knownZero)

  /// Per `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11 — a real provider
  /// failure for a `.priced` registration must throw, never collapse to
  /// `.knownZero`. This is the load-bearing distinction `convertResult`
  /// adds.
  @Test
  func pricedSourceProviderFailureThrowsAndDoesNotReturnKnownZero() async throws {
    let bundle = try makeService(
      cryptoPrices: [:],
      shouldFail: true,
      registrations: [ethRegistration(status: .priced)]
    )
    let amount = InstrumentAmount(quantity: dec("1"), instrument: eth)

    await #expect(throws: (any Error).self) {
      _ = try await bundle.service.convertResult(amount, to: usd, on: try date("2026-04-10"))
    }
  }

  // MARK: - Same-instrument identity fast path

  /// `.unpriced` source converted to itself must NOT collapse to
  /// `.knownZero`: the position list still renders the native quantity
  /// of an `.unpriced` token (the token's fiat aggregation contribution
  /// is zero — its native quantity is its native quantity).
  @Test
  func unpricedSourceConvertedToSameInstrumentReturnsValue() async throws {
    let bundle = try makeService(
      cryptoPrices: [:],
      shouldFail: true,
      registrations: [ethRegistration(status: .unpriced)]
    )
    let amount = InstrumentAmount(quantity: dec("2.5"), instrument: eth)

    let result = try await bundle.service.convertResult(
      amount, to: eth, on: try date("2026-04-10"))

    #expect(result == .value(amount))
  }

  // MARK: - Fiat source -> .value (no .knownZero concept)

  @Test
  func fiatSourceProducesValue() async throws {
    let bundle = try makeService(
      exchangeRates: ["2026-04-10": ["AUD": dec("1.58")]]
    )
    let amount = InstrumentAmount(quantity: dec("100"), instrument: usd)

    let result = try await bundle.service.convertResult(
      amount, to: aud, on: try date("2026-04-10"))

    #expect(result == .value(InstrumentAmount(quantity: dec("100") * dec("1.58"), instrument: aud)))
  }

  // MARK: - Native gas instruments — issue #791

  /// Pins the `(.cryptoToken, .fiatCurrency)` dispatch for an Optimism
  /// native ETH (`10:native`) → AUD conversion through `convertResult`,
  /// covering the full `.priced` branch — `convertResult` is the
  /// aggregation entry point on which downstream callers depend per
  /// `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11.
  ///
  /// The bug in #791 surfaced because wallet sync inserted a
  /// `10:native` row without a provider mapping (`hasMapping=false`,
  /// default `pricingStatus=.priced`), which `allCryptoRegistrations()`
  /// projects to nil — so `cryptoUsdPrice` then threw
  /// `ConversionError.noProviderMapping`. The fix lives in
  /// `TransferEventBuilder.build(...)`; this test pins the
  /// FullConversionService side of the contract.
  @Test
  func nativeGasInstrumentConvertsToFiat() async throws {
    let optimismEth = Instrument.crypto(
      chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let registration = CryptoRegistration(
      instrument: optimismEth,
      mapping: CryptoProviderMapping(
        instrumentId: "10:native",
        coingeckoId: nil,
        binanceSymbol: "ETHUSDT"),
      pricingStatus: .priced)
    let bundle = try makeService(
      cryptoPrices: ["10:native": ["2026-04-10": dec("1623.45")]],
      exchangeRates: ["2026-04-10": ["AUD": dec("1.58")]],
      registrations: [registration]
    )
    let amount = InstrumentAmount(quantity: dec("0.5"), instrument: optimismEth)

    let result = try await bundle.service.convertResult(
      amount, to: aud, on: try date("2026-04-10"))

    // 0.5 ETH * 1623.45 USD/ETH * 1.58 AUD/USD
    #expect(
      result
        == .value(
          InstrumentAmount(
            quantity: dec("0.5") * dec("1623.45") * dec("1.58"), instrument: aud)))
  }
}
