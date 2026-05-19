import Foundation
import GRDB
import Testing

@testable import Moolah

/// Wrapped-native (WETH/WMATIC/…) pricing: a canonical wrapped-native
/// contract has no price feed of its own but is 1:1 redeemable for the
/// chain's native asset, so it must price via the native registration.
/// A spoofed look-alike contract must NOT inherit that price.
///
/// Split into its own suite (rather than living in
/// `InstrumentConversionServiceCryptoTests`) so neither type exceeds
/// the body-length budget — the wrapped-native rule is a self-contained
/// concern with its own harness.
@Suite("InstrumentConversionService — Wrapped-native")
struct WrappedNativeConversionTests {
  private let usd = Instrument.USD

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(
      formatter.date(from: string),
      "Could not parse ISO8601 full-date string: \(string)")
  }

  /// Minimal `FullConversionService` wired with a fixed crypto price
  /// feed and a registration set. No exchange-rate client is needed —
  /// both tests convert to USD.
  private func makeService(
    cryptoPrices: [String: [String: Decimal]],
    providerMappings: [CryptoProviderMapping]
  ) throws -> FullConversionService {
    let database = try ProfileIndexDatabase.openInMemory()
    let cryptoService = CryptoPriceService(
      clients: [FixedCryptoPriceClient(prices: cryptoPrices)],
      database: database)
    let exchangeService = ExchangeRateService(
      client: FixedRateClient(rates: [:]), database: database)
    let stockService = StockPriceService(
      client: FixedStockPriceClient(), database: database)
    let registrations = providerMappings.map { mapping in
      CryptoRegistration(
        instrument: Self.instrument(forMappingId: mapping.instrumentId),
        mapping: mapping)
    }
    return FullConversionService(
      exchangeRates: exchangeService,
      stockPrices: stockService,
      cryptoPrices: cryptoService,
      cryptoRegistrations: { registrations })
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

  private func nativeEthRegistration() -> CryptoProviderMapping {
    CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT")
  }

  /// Canonical Ethereum WETH has no price feed of its own but is 1:1
  /// redeemable for ETH, so it must price via the `1:native`
  /// registration. Regression: previously this failed with a
  /// `noProviderMapping`-wrapped sync error and broke the Analysis page.
  @Test("Canonical WETH prices via the native ETH registration")
  func canonicalWrappedEthPricesAsNative() async throws {
    let weth = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
      symbol: "WETH", name: "Wrapped Ether", decimals: 18)
    let service = try makeService(
      cryptoPrices: ["1:native": ["2026-04-10": dec("1623.45")]],
      // NOTE: no mapping registered for the WETH contract id itself.
      providerMappings: [nativeEthRegistration()])
    let result = try await service.convert(
      dec("2"), from: weth, to: usd, on: try date("2026-04-10"))
    #expect(result == dec("2") * dec("1623.45"))
  }

  /// A non-canonical contract that merely calls itself "WETH" must NOT
  /// inherit ETH's price — it could be a malicious look-alike. With no
  /// registration of its own it fails to price (anti-spoof).
  @Test("A look-alike WETH contract is not priced as native")
  func lookAlikeWrappedEthIsNotPricedAsNative() async throws {
    let fakeWeth = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
      symbol: "WETH", name: "Wrapped Ether", decimals: 18)
    let service = try makeService(
      cryptoPrices: ["1:native": ["2026-04-10": dec("1623.45")]],
      providerMappings: [nativeEthRegistration()])
    await #expect(throws: (any Error).self) {
      _ = try await service.convert(
        dec("2"), from: fakeWeth, to: usd, on: try date("2026-04-10"))
    }
  }

  /// A wrapped-native rate is memoised under the *wrapper's* id, but the
  /// price comes from the native asset. Invalidating the native asset
  /// must therefore also evict the wrapper's cached factor — otherwise
  /// WETH keeps converting at the pre-update ETH rate.
  @Test("invalidateCache(for: native) evicts the wrapped-native cached rate")
  func invalidateCacheForNativeEvictsWrappedEntry() async throws {
    let weth = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
      symbol: "WETH", name: "Wrapped Ether", decimals: 18)
    let ethNative = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let service = try makeService(
      cryptoPrices: ["1:native": ["2026-04-10": dec("1623.45")]],
      providerMappings: [nativeEthRegistration()])

    _ = try await service.convert(
      dec("1"), from: weth, to: usd, on: try date("2026-04-10"))
    let warmedCount = await service.cachedRateCountForTesting
    #expect(warmedCount == 1)

    await service.invalidateCache(for: ethNative)
    let evictedCount = await service.cachedRateCountForTesting
    #expect(evictedCount == 0)
  }
}
