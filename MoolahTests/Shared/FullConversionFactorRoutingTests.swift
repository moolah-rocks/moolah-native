import Foundation
import GRDB
import Testing

@testable import Moolah

/// Routing tests for the generic `factor` / `priceIn` algorithm: each kind
/// pair must select the correct common quote and reproduce the precision-safe
/// `(multiplier, divisor)` form. In particular, fiat→fiat must use the direct
/// Frankfurter pair — never a USD-triangulated product — and fiat↔crypto must
/// bridge through the fiat operand so the exact-round-trip property holds.
@Suite("FullConversionService — factor routing")
struct FullConversionFactorRoutingTests {
  private let usd = Instrument.USD
  private let aud = Instrument.fiat(code: "AUD")
  private let gbp = Instrument.fiat(code: "GBP")
  private let jpy = Instrument.fiat(code: "JPY")
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  private let btc = Instrument.crypto(
    chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
  private let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(
      formatter.date(from: string),
      "Could not parse ISO8601 full-date string: \(string)")
  }

  /// Builds a `FullConversionService` against fixed fiat / stock / crypto
  /// feeds, injecting the crypto registrations into `CryptoPriceService` via
  /// `metadataLookup` (the final post-Task-4 construction shape).
  private func makeService(
    cryptoPrices: [String: [String: Decimal]] = [:],
    stockPrices: [String: StockPriceResponse] = [:],
    exchangeRates: [String: [String: Decimal]] = [:],
    providerMappings: [CryptoProviderMapping] = []
  ) throws -> FullConversionService {
    let database = try ProfileIndexDatabase.openInMemory()
    let utc = try #require(TimeZone(identifier: "UTC"))
    let registrations = providerMappings.map { mapping in
      CryptoRegistration(
        instrument: Self.instrument(forMappingId: mapping.instrumentId),
        mapping: mapping)
    }
    let registrationsById = Dictionary(
      uniqueKeysWithValues: registrations.map { ($0.id, $0) })
    let cryptoService = CryptoPriceService(
      clients: [FixedCryptoPriceClient(prices: cryptoPrices)],
      database: database,
      metadataLookup: { registrationsById[$0] },
      timeZone: utc)
    let exchangeService = ExchangeRateService(
      client: FixedRateClient(rates: exchangeRates), database: database, timeZone: utc)
    let stockService = StockPriceService(
      client: FixedStockPriceClient(responses: stockPrices), database: database, timeZone: utc)
    return FullConversionService(
      exchangeRates: exchangeService,
      stockPrices: stockService,
      cryptoPrices: cryptoService)
  }

  private static func instrument(forMappingId id: String) -> Instrument {
    let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
    let chainId = Int(parts.first ?? "") ?? 0
    let contract = parts.count > 1 ? parts[1] : "native"
    let isNative = contract == "native"
    return .crypto(
      chainId: chainId,
      contractAddress: isNative ? nil : contract,
      symbol: isNative ? "NATIVE" : contract,
      name: isNative ? "NATIVE" : contract,
      decimals: 18)
  }

  private func ethMapping() -> CryptoProviderMapping {
    CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: "ethereum",
      binanceSymbol: "ETHUSDT")
  }

  private func btcMapping() -> CryptoProviderMapping {
    CryptoProviderMapping(
      instrumentId: "0:native", coingeckoId: "bitcoin",
      binanceSymbol: "BTCUSDT")
  }

  // MARK: - fiat → fiat (direct pair, not USD-bridged)

  @Test
  func audToGbpUsesDirectPair() async throws {
    let day = try date("2026-04-10")
    // Seed ONLY the direct AUD→GBP pair. No USD rates exist, so any
    // USD-triangulated routing would throw rather than return a value.
    let service = try makeService(exchangeRates: ["2026-04-10": ["GBP": dec("0.52")]])

    let result = try await service.convert(Decimal(100), from: aud, to: gbp, on: day)
    #expect(result == dec("52"))
    // A USD bridge would be rate(AUD→USD)·rate(USD→GBP); neither is seeded,
    // so the direct value proves the direct pair was used.
    #expect(result != dec("0"))
  }

  // MARK: - stock → fiat (via listing currency)

  @Test
  func stockToFiatViaListing() async throws {
    let day = try date("2026-04-10")
    // BHP listed in AUD, converting to USD: stockPrice · rate(AUD→USD).
    let service = try makeService(
      stockPrices: [
        "BHP.AX": StockPriceResponse(
          instrument: aud, prices: ["2026-04-10": dec("42.30")])
      ],
      exchangeRates: ["2026-04-10": ["USD": dec("0.65")]])

    let result = try await service.convert(Decimal(10), from: bhp, to: usd, on: day)
    // 10 · 42.30 AUD · 0.65 USD/AUD
    #expect(result == dec("10") * dec("42.30") * dec("0.65"))
  }

  // MARK: - crypto → fiat (via USD)

  @Test
  func cryptoToFiatViaUsd() async throws {
    let day = try date("2026-04-10")
    // ETH→AUD: cryptoUsd · rate(USD→AUD).
    let service = try makeService(
      cryptoPrices: ["1:native": ["2026-04-10": dec("1623.45")]],
      exchangeRates: ["2026-04-10": ["AUD": dec("1.55")]],
      providerMappings: [ethMapping()])

    let result = try await service.convert(dec("2.5"), from: eth, to: aud, on: day)
    #expect(result == dec("2.5") * dec("1623.45") * dec("1.55"))
  }

  // MARK: - crypto → crypto (via USD)

  @Test
  func cryptoToCryptoViaUsd() async throws {
    let day = try date("2026-04-10")
    // ETH→BTC: ethUsd / btcUsd.
    let service = try makeService(
      cryptoPrices: [
        "1:native": ["2026-04-10": dec("1623.45")],
        "0:native": ["2026-04-10": dec("64500.00")],
      ],
      providerMappings: [ethMapping(), btcMapping()])

    let result = try await service.convert(Decimal(3), from: eth, to: btc, on: day)
    #expect(result == (Decimal(3) * dec("1623.45")) / dec("64500.00"))
  }

  // MARK: - fiat → crypto (bridges through fiat operand; exact round trip)

  @Test
  func fiatToCryptoExactRoundTrip() async throws {
    let day = try date("2026-04-10")
    // 1 ETH = 300_000 JPY (via USD price 300_000 and rate USD→JPY = 1).
    // Converting 300_000 JPY → ETH must yield exactly 1, not 0.999….
    let service = try makeService(
      cryptoPrices: ["1:native": ["2026-04-10": dec("300000")]],
      exchangeRates: ["2026-04-10": ["JPY": dec("1")]],
      providerMappings: [ethMapping()])

    let result = try await service.convert(dec("300000"), from: jpy, to: eth, on: day)
    #expect(result == Decimal(1))
  }

  // MARK: - stock → crypto (via USD)

  @Test
  func stockToCryptoViaUsd() async throws {
    let day = try date("2026-04-10")
    // BHP listed in USD (stockUsd), ETH priced in USD: stockUsd / cryptoUsd.
    let service = try makeService(
      cryptoPrices: ["1:native": ["2026-04-10": dec("1623.45")]],
      stockPrices: [
        "BHP.AX": StockPriceResponse(
          instrument: usd, prices: ["2026-04-10": dec("84.00")])
      ],
      providerMappings: [ethMapping()])

    let result = try await service.convert(Decimal(5), from: bhp, to: eth, on: day)
    #expect(result == (Decimal(5) * dec("84.00")) / dec("1623.45"))
  }

  // MARK: - any → stock (unsupported)

  @Test
  func toStockTargetIsUnsupported() async throws {
    let day = try date("2026-04-10")
    // Converting *into* a stock has no defined route — `computeUnitFactor`
    // rejects it up front regardless of the source kind.
    let service = try makeService(
      exchangeRates: ["2026-04-10": ["USD": dec("0.65")]])

    await #expect(
      throws: ConversionError.unsupportedConversion(from: aud.id, to: bhp.id)
    ) {
      _ = try await service.convert(Decimal(100), from: aud, to: bhp, on: day)
    }
  }

  // MARK: - non-USD fiat → crypto (common quote is the source fiat, not USD)

  @Test
  func nonUsdFiatToCryptoRoutesThroughSourceFiat() async throws {
    let day = try date("2026-04-10")
    // AUD→ETH: target is crypto, source is fiat, so the common quote is the
    // *source* fiat (AUD), never USD. The source leg is then `rate(AUD→AUD)=1`
    // — no USD triangulation of the fiat operand — and the ETH leg is priced
    // as cryptoUsd · rate(USD→AUD). Seed only USD→AUD (the ETH leg's FX hop);
    // an AUD→USD bridge of the fiat operand would need USD→USD/AUD→USD rates
    // that are absent, so the value below proves the fiat leg was the identity.
    let service = try makeService(
      cryptoPrices: ["1:native": ["2026-04-10": dec("1623.45")]],
      exchangeRates: ["2026-04-10": ["AUD": dec("1.55")]],
      providerMappings: [ethMapping()])

    let result = try await service.convert(dec("3100"), from: aud, to: eth, on: day)
    // factor = (1, cryptoUsd · rate(USD→AUD)); convert = 3100 / (1623.45 · 1.55).
    #expect(result == dec("3100") / (dec("1623.45") * dec("1.55")))
  }
}
